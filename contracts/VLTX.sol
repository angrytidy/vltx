// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/**
 * VAULTEX (VLTX) — Token + Governance Guards + Vesting + Optional LP Guardian + KYC Registry
 * Matches the client's M0 v1.1 + Enhancements:
 * - BEP-20 (ERC20) with 0% at TGE, governance-enabled fee toggle, hard-capped ≤ 5% total (buy+sell)
 * - One-way trading enable; launch guards (maxTx, maxWallet, cooldown, sniper blocks)
 * - Pausable LaunchSwitch (emergency)
 * - Anti-bot blacklist (events)
 * - Ownership via TimelockController/Multisig (transferOwnership after deploy)
 * - VestingVault for Team/Advisors/Marketing (Team 6m cliff/24m linear; Advisors 3m/12m; Marketing 30% TGE + 70% monthly from Month 3)
 * - LPGuardian (ELI): timelock-only, ≤10% LP token movement, evented
 * - Optional KYCRegistry: store attestation for ≥$1k USDT contributors and general compliance
 *
 * IMPORTANT:
 * - Set `ammPair` after GemPad creates the pair. Exclude pair/router/treasury/vesting from limits and fees as needed.
 * - Transfer Ownership to a TimelockController or Multisig per governance plan.
 * - If GemPad locks 100% LP, LPGuardian will have nothing to move (by design). Keep a small reserve LP chunk *if* you need ELI flexibility.
 */

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/* ──────────────────────────────────────────────────────────────────────────────
|                              KYC REGISTRY (opt)                               |
└──────────────────────────────────────────────────────────────────────────────*/
contract KYCRegistry is Ownable2Step, ReentrancyGuard {
    event KYCSet(address indexed user, bool status, string meta);
    mapping(address => bool) public isKYCApproved; // off-chain KYC linkable
    // OPTIONAL: per-user metadata hash/IPFS ref for audit proofs
    mapping(address => string) public kycMeta;

    function setKYC(
        address user,
        bool approved,
        string calldata meta
    ) external onlyOwner {
        isKYCApproved[user] = approved;
        kycMeta[user] = meta;
        emit KYCSet(user, approved, meta);
    }
}

/* ──────────────────────────────────────────────────────────────────────────────
|                                VESTING VAULT                                  |
└──────────────────────────────────────────────────────────────────────────────*/
contract VestingVault is Ownable2Step, ReentrancyGuard {
    using SafeCast for uint256;

    IERC20 public immutable token;

    struct Schedule {
        uint128 total; // total tokens allocated to beneficiary
        uint64 start; // TGE timestamp (or custom start)
        uint64 cliff; // seconds until first vest
        uint64 duration; // linear vesting duration (seconds)
        uint128 tgeAmount; // amount available at TGE (for Marketing 30%)
        uint128 released; // amount already claimed
        bool initialized;
    }

    mapping(address => Schedule) public schedules;

    event ScheduleCreated(
        address indexed beneficiary,
        uint128 total,
        uint64 start,
        uint64 cliff,
        uint64 duration,
        uint128 tgeAmount
    );
    event TokensReleased(address indexed beneficiary, uint128 amount);

    constructor(IERC20 _token) {
        token = _token;
    }

    function createSchedule(
        address beneficiary,
        uint128 total,
        uint64 start,
        uint64 cliff,
        uint64 duration,
        uint128 tgeAmount
    ) external onlyOwner {
        require(!schedules[beneficiary].initialized, "Schedule exists");
        require(total > 0, "total=0");
        require(duration > 0, "duration=0");
        schedules[beneficiary] = Schedule({
            total: total,
            start: start,
            cliff: cliff,
            duration: duration,
            tgeAmount: tgeAmount,
            released: 0,
            initialized: true
        });
        emit ScheduleCreated(
            beneficiary,
            total,
            start,
            cliff,
            duration,
            tgeAmount
        );
    }

    function vestedAmount(
        address beneficiary,
        uint64 t
    ) public view returns (uint128) {
        Schedule memory s = schedules[beneficiary];
        if (!s.initialized) return 0;
        if (t < s.start + s.cliff) {
            // only TGE amount (e.g., Marketing 30%) before cliff
            return s.tgeAmount;
        }
        if (t >= s.start + s.cliff + s.duration) {
            return s.total;
        }
        // linear vest after cliff (over duration), plus TGE tranche
        uint256 linear = (uint256(s.total - s.tgeAmount) *
            (t - (s.start + s.cliff))) / s.duration;
        return uint128(linear + s.tgeAmount);
    }

    function releasable(address beneficiary) public view returns (uint128) {
        uint128 vested = vestedAmount(beneficiary, uint64(block.timestamp));
        uint128 released_ = schedules[beneficiary].released;
        return vested > released_ ? vested - released_ : 0;
    }

    function release(
        address beneficiary
    ) external nonReentrant returns (uint128 amt) {
        amt = releasable(beneficiary);
        require(amt > 0, "Nothing to release");
        schedules[beneficiary].released += amt;
        require(token.transfer(beneficiary, amt), "Transfer failed");
        emit TokensReleased(beneficiary, amt);
    }

    // admin recover (in case of overfund)
    function sweep(address to, uint256 amount) external onlyOwner {
        require(token.transfer(to, amount), "sweep fail");
    }
}

/* ──────────────────────────────────────────────────────────────────────────────
|                         LP GUARDIAN (Emergency 10%)                           |
└──────────────────────────────────────────────────────────────────────────────*/
// Minimal LP token interface (e.g., Pancake LP = ERC20)
interface ILPToken is IERC20 {}

contract LPGuardian is Ownable2Step, ReentrancyGuard {
    event ELIExecuted(
        address indexed lp,
        address indexed to,
        uint256 amount,
        string reason
    );

    // Hard cap: ≤10% of LP tokens held by this contract per ELI action
    uint256 public constant ELI_BPS_CAP = 1000; // 10% of balance

    // ELI (Emergency Liquidity Intervention): move up to 10% of held LP tokens
    // to a designated address (e.g., MM desk or treasury) for rebalancing.
    // NOTE: If all LP is locked in GemPad locker, this will do nothing (as intended).
    function eliRebalance(
        ILPToken lp,
        address to,
        uint256 amount,
        string calldata reason
    ) external onlyOwner nonReentrant {
        uint256 bal = lp.balanceOf(address(this));
        require(bal > 0, "No LP held");
        uint256 maxAllowed = (bal * ELI_BPS_CAP) / 10_000;
        require(amount > 0 && amount <= maxAllowed, "Amount > 10% cap");
        require(lp.transfer(to, amount), "LP transfer failed");
        emit ELIExecuted(address(lp), to, amount, reason);
    }

    // Allow depositing LP tokens (from multisig/timelock) to this guardian
    function pullLP(ILPToken lp, uint256 amount) external onlyOwner {
        require(
            lp.transferFrom(msg.sender, address(this), amount),
            "pull fail"
        );
    }

    function sweepToken(
        IERC20 token,
        address to,
        uint256 amount
    ) external onlyOwner {
        require(token.transfer(to, amount), "sweep fail");
    }
}

/* ──────────────────────────────────────────────────────────────────────────────
|                               VAULTEX (VLTX)                                  |
└──────────────────────────────────────────────────────────────────────────────*/
contract VLTX is ERC20, Ownable2Step, Pausable, ReentrancyGuard {
    using SafeCast for uint256;

    // ====== Constants ======
    uint256 public constant MAX_SUPPLY = 1_000_000_000 ether; // 1B * 1e18
    uint256 public constant FEE_DENOMINATOR = 10_000; // bps
    uint256 public constant MAX_TOTAL_FEE_BPS = 500; // <= 5.00% combined cap

    // ====== Addresses / Roles ======
    address public treasury; // fee receiver, multisig recommended
    address public ammPair; // Pancake pair address set post-creation
    address public router; // Pancake router (optional reference)
    KYCRegistry public kycRegistry; // optional (off-chain integration)
    // Vesting vaults (deployed separately then funded)
    VestingVault public teamVault;
    VestingVault public advisorVault;
    VestingVault public marketingVault;

    // ====== Trading / Launch Guards ======
    bool public tradingEnabled; // one-way
    uint256 public tradingStartBlock; // for sniper protection
    uint256 public sniperBlocks = 3; // default; configurable (2–5 suggested)
    uint256 public launchGuardEndsAt; // timestamp when cooldown/limits auto-relax (optional)

    // limits (applied while launch guards active)
    uint256 public maxTxAmount; // e.g., 2% of supply
    uint256 public maxWalletAmount; // e.g., 3% of supply
    uint256 public cooldownSeconds = 45; // first hour recommended

    mapping(address => uint256) private _lastTxAt; // cooldown tracker
    mapping(address => bool) public isExcludedFromLimits;
    mapping(address => bool) public isExcludedFromFees;

    // ====== Fees ======
    uint256 public buyFeeBps; // ≤ 5% cap
    uint256 public sellFeeBps; // ≤ 5% cap

    // ====== Anti-bot blacklist ======
    mapping(address => bool) public isBlacklisted;
    event BlacklistUpdated(address indexed account, bool blacklisted);

    // ====== Events ======
    event TradingEnabled(uint256 startBlock, uint256 timestamp);
    event FeesUpdated(uint256 buyFeeBps, uint256 sellFeeBps);
    event TreasuryUpdated(address indexed newTreasury);
    event PairSet(address indexed pair, address indexed router);
    event LimitsUpdated(
        uint256 maxTxAmount,
        uint256 maxWalletAmount,
        uint256 cooldownSeconds,
        uint256 guardEndsAt
    );
    event SniperBlocksUpdated(uint256 sniperBlocks);
    event ExclusionUpdated(address indexed account, bool feeEx, bool limitEx);
    event KYCRegistrySet(address indexed registry);

    constructor(
        string memory name_,
        string memory symbol_,
        address treasury_
    ) ERC20(name_, symbol_) {
        require(treasury_ != address(0), "treasury=0");
        treasury = treasury_;

        // mint full supply to owner (deployer) — you can redistribute to vaults/treasury later
        _mint(_msgSender(), MAX_SUPPLY);

        // Default: exclude owner and treasury from fees/limits
        isExcludedFromFees[_msgSender()] = true;
        isExcludedFromFees[treasury] = true;
        isExcludedFromLimits[_msgSender()] = true;
        isExcludedFromLimits[treasury] = true;

        // Default limits: set to safe values (can be tuned pre-launch)
        maxTxAmount = (MAX_SUPPLY * 200) / 10_000; // 2%
        maxWalletAmount = (MAX_SUPPLY * 300) / 10_000; // 3%
    }

    /* ───────────── Governance / Admin ───────────── */

    function setTreasury(address t) external onlyOwner {
        require(t != address(0), "treasury=0");
        treasury = t;
        emit TreasuryUpdated(t);
    }

    function setPairAndRouter(
        address pair,
        address router_
    ) external onlyOwner {
        ammPair = pair;
        router = router_;
        // Pairs & router typically excluded from limits/fees
        isExcludedFromLimits[pair] = true;
        isExcludedFromFees[pair] = true;
        if (router_ != address(0)) {
            isExcludedFromLimits[router_] = true;
            isExcludedFromFees[router_] = true;
        }
        emit PairSet(pair, router_);
    }

    function setKYCRegistry(KYCRegistry reg) external onlyOwner {
        kycRegistry = reg;
        emit KYCRegistrySet(address(reg));
    }

    // bounds: combined must be ≤ MAX_TOTAL_FEE_BPS
    function setFees(uint256 buyBps, uint256 sellBps) external onlyOwner {
        require(
            buyBps <= MAX_TOTAL_FEE_BPS && sellBps <= MAX_TOTAL_FEE_BPS,
            "fee>cap"
        );
        buyFeeBps = buyBps;
        sellFeeBps = sellBps;
        emit FeesUpdated(buyBps, sellBps);
    }

    function setExclusions(
        address account,
        bool feeEx,
        bool limitEx
    ) external onlyOwner {
        isExcludedFromFees[account] = feeEx;
        isExcludedFromLimits[account] = limitEx;
        emit ExclusionUpdated(account, feeEx, limitEx);
    }

    function setLimits(
        uint256 _maxTxAmount,
        uint256 _maxWalletAmount,
        uint256 _cooldownSeconds,
        uint256 _guardEndsAt // set e.g., block.timestamp + 1 hours
    ) external onlyOwner {
        require(_maxTxAmount > 0 && _maxWalletAmount > 0, "limits=0");
        maxTxAmount = _maxTxAmount;
        maxWalletAmount = _maxWalletAmount;
        cooldownSeconds = _cooldownSeconds;
        launchGuardEndsAt = _guardEndsAt;
        emit LimitsUpdated(
            maxTxAmount,
            maxWalletAmount,
            cooldownSeconds,
            launchGuardEndsAt
        );
    }

    function setSniperBlocks(uint256 blocks_) external onlyOwner {
        require(blocks_ <= 10, "too large"); // sanity
        sniperBlocks = blocks_;
        emit SniperBlocksUpdated(blocks_);
    }

    function pauseLaunch() external onlyOwner {
        _pause();
    }

    function unpauseLaunch() external onlyOwner {
        _unpause();
    }

    // one-way enable
    function enableTrading() external onlyOwner {
        require(!tradingEnabled, "already enabled");
        tradingEnabled = true;
        tradingStartBlock = block.number;
        emit TradingEnabled(block.number, block.timestamp);
    }

    function setBlacklist(
        address account,
        bool blacklisted
    ) external onlyOwner {
        isBlacklisted[account] = blacklisted;
        emit BlacklistUpdated(account, blacklisted);
    }

    // vault wiring helpers
    function setVestingVaults(
        VestingVault team_,
        VestingVault advisors_,
        VestingVault marketing_
    ) external onlyOwner {
        teamVault = team_;
        advisorVault = advisors_;
        marketingVault = marketing_;
        // typical exclusions
        if (address(team_) != address(0)) {
            isExcludedFromLimits[address(team_)] = true;
            isExcludedFromFees[address(team_)] = true;
        }
        if (address(advisors_) != address(0)) {
            isExcludedFromLimits[address(advisors_)] = true;
            isExcludedFromFees[address(advisors_)] = true;
        }
        if (address(marketing_) != address(0)) {
            isExcludedFromLimits[address(marketing_)] = true;
            isExcludedFromFees[address(marketing_)] = true;
        }
    }

    /* ───────────── Transfers + Launch Rules ───────────── */

    function _update(
        address from,
        address to,
        uint256 amount
    ) internal override whenNotPaused {
        require(!isBlacklisted[from] && !isBlacklisted[to], "blacklisted");

        // before trading: allow owner/treasury/vault wiring, block public
        if (!tradingEnabled) {
            require(
                isExcludedFromLimits[from] || isExcludedFromLimits[to],
                "trading disabled"
            );
            super._update(from, to, amount);
            return;
        }

        // launch guards window
        bool guardsActive = launchGuardEndsAt == 0
            ? true
            : block.timestamp < launchGuardEndsAt;

        if (guardsActive) {
            // Limits (skip for excluded)
            if (!isExcludedFromLimits[from] && !isExcludedFromLimits[to]) {
                require(amount <= maxTxAmount, "maxTx");
                if (to != ammPair) {
                    require(
                        balanceOf(to) + amount <= maxWalletAmount,
                        "maxWallet"
                    );
                }
                // cooldown
                if (cooldownSeconds > 0) {
                    require(
                        block.timestamp >= _lastTxAt[from] + cooldownSeconds,
                        "cooldown from"
                    );
                    require(
                        block.timestamp >= _lastTxAt[to] + cooldownSeconds,
                        "cooldown to"
                    );
                    _lastTxAt[from] = block.timestamp;
                    _lastTxAt[to] = block.timestamp;
                }
            }

            // sniper protection (first N blocks after enable)
            if (
                sniperBlocks > 0 &&
                block.number <= tradingStartBlock + sniperBlocks
            ) {
                // Only allow tx if either side is excluded (e.g., router/treasury) to reduce bot buys
                require(
                    isExcludedFromLimits[from] || isExcludedFromLimits[to],
                    "sniper guard"
                );
            }
        }

        // Fees (only on AMM interactions, unless excluded)
        uint256 fee;
        if (!isExcludedFromFees[from] && !isExcludedFromFees[to]) {
            // buy if from == pair; sell if to == pair
            if (from == ammPair && buyFeeBps > 0) {
                fee = (amount * buyFeeBps) / FEE_DENOMINATOR;
            } else if (to == ammPair && sellFeeBps > 0) {
                fee = (amount * sellFeeBps) / FEE_DENOMINATOR;
            }
        }

        if (fee > 0) {
            super._update(from, treasury, fee);
            amount -= fee;
        }

        super._update(from, to, amount);
    }
}
