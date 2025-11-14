// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IKYCRegistry} from "./KYCRegistry.sol";

contract VLTX is ERC20, Ownable2Step, Pausable {
    IKYCRegistry public kyc;
    bool public kycGuardEnabled;
    mapping(address => bool) public kycGuardExempt;

    event KycRegistryUpdated(address indexed registry);
    event KycGuardToggled(bool enabled);
    event KycGuardExemptSet(address indexed account, bool isExempt);

    // ====== Trading/AMM ======
    bool public tradingEnabled;
    uint256 public tradingEnabledAt; // timestamp
    uint256 public tradingEnabledBlock; // block
    mapping(address => bool) public isAMMPair; // pair addresses

    event TradingEnabled(uint256 atTimestamp, uint256 atBlock);
    event AMMPairSet(address indexed pair, bool isPair);

    // ====== Fees ======
    uint16 public constant MAX_TOTAL_FEE_BPS = 500; // 5% total cap (buy + sell)
    uint16 public buyFeeBps; // in basis points
    uint16 public sellFeeBps; // in basis points
    address public feeReceiver; // treasury multisig
    uint64 public earliestFeeEnableAt; // cannot set non-zero fees before this time

    mapping(address => bool) public isExcludedFromFees;

    event FeesUpdated(uint16 buyFeeBps, uint16 sellFeeBps);
    event FeeReceiverChanged(
        address indexed oldReceiver,
        address indexed newReceiver
    );
    event EarliestFeeEnableAtSet(uint64 timestamp);
    event FeeExclusionSet(address indexed account, bool isExcluded);

    // ====== Launch guards (limits) ======
    // Values are in BPS of total supply for maxTx/maxWallet (e.g., 200 = 2%)
    uint16 public maxTxBps; // e.g., 150  (1.5%)
    uint16 public maxWalletBps; // e.g., 250  (2.5%)
    uint32 public cooldownSeconds; // e.g., 10
    uint8 public sniperBlocks; // e.g., 4 (EOA-only buys for first 4 blocks)

    mapping(address => bool) public isExcludedFromLimits;
    mapping(address => uint64) public lastTradeAt; // wallet cooldown

    event LaunchParamsSet(
        uint16 maxTxBps,
        uint16 maxWalletBps,
        uint32 cooldownSeconds,
        uint8 sniperBlocks
    );
    event LimitsExclusionSet(address indexed account, bool isExcluded);

    // ====== Governance Locks (one-way) ======
    bool public feesLocked; // blocks setFees / setEarliestFeeEnableAt / setFeeReceiver
    bool public feeExclusionsLocked; // blocks setFeeExclusion
    bool public limitsLocked; // blocks setLaunchParams / setLimitsExclusion
    bool public kycLocked; // blocks setKycGuard / setKycRegistry
    bool public ammPairsLocked; // blocks setAMMPair

    event GovernanceLocked(string what);

    // ====== Optional sunsets ======
    // Auto-disable launch limits after this timestamp (if set)
    uint64 public guardsSunsetAt;
    event GuardsSunsetSet(uint64 when);

    // After this timestamp, KYC guard cannot be enabled again (if set)
    uint64 public kycSunsetAt;
    event KycSunsetSet(uint64 when);

    // ====== Blacklist (last-resort) ======
    mapping(address => bool) public isBlacklisted;
    bool public blacklistLocked; // optional governance lock
    event BlacklistSet(address indexed account, bool isBlacklisted_);

    event Rescue(address indexed token, address indexed to, uint256 amount);

    constructor(
        address initialOwner
    ) ERC20("run-vltx", "run-VLTX") Ownable(initialOwner) {
        uint256 supply = 1000 * 10 ** decimals();
        _mint(initialOwner, supply);

        // Sensible defaults (you can override via setters)
        feeReceiver = initialOwner;
        isExcludedFromFees[initialOwner] = true;
        isExcludedFromLimits[initialOwner] = true;

        // === Launch-guard defaults (Phase 1) ===
        maxTxBps = 150; // 1.5% max per transaction
        maxWalletBps = 250; // 2.5% max per wallet
        cooldownSeconds = 10; // 10s cooldown between trades per wallet
        sniperBlocks = 4; // first 4 blocks EOA-only buys
    }

    // ========= Admin: one-way locks =========
    function lockFeesForever() external onlyOwner {
        feesLocked = true;
        emit GovernanceLocked("fees");
    }

    function lockFeeExclusionsForever() external onlyOwner {
        feeExclusionsLocked = true;
        emit GovernanceLocked("feeExclusions");
    }

    function lockLimitsForever() external onlyOwner {
        limitsLocked = true;
        emit GovernanceLocked("limits");
    }

    function lockKycForever() external onlyOwner {
        kycLocked = true;
        emit GovernanceLocked("kyc");
    }

    function lockAMMPairsForever() external onlyOwner {
        ammPairsLocked = true;
        emit GovernanceLocked("ammPairs");
    }

    function lockBlacklistForever() external onlyOwner {
        blacklistLocked = true;
        emit GovernanceLocked("blacklist");
    }

    // ========= Admin: optional sunsets =========
    function setGuardsSunset(uint64 when) external onlyOwner {
        require(!limitsLocked, "LIMITS_LOCKED");
        guardsSunsetAt = when;
        emit GuardsSunsetSet(when);
    }

    function setKycSunset(uint64 when) external onlyOwner {
        require(!kycLocked, "KYC_LOCKED");
        kycSunsetAt = when;
        emit KycSunsetSet(when);
    }

    // ========= Admin: Pause switch (emergency) =========
    function pause() external onlyOwner {
        _pause();
    } // emits Paused(address)

    function unpause() external onlyOwner {
        _unpause();
    } // emits Unpaused(address)

    // ========= Admin: Blacklist (last-resort; emits event) =========
    function setBlacklisted(
        address account,
        bool blacklisted
    ) external onlyOwner {
        require(!blacklistLocked, "BLACKLIST_LOCKED");
        isBlacklisted[account] = blacklisted;
        emit BlacklistSet(account, blacklisted);
    }

    // ========= Admin: KYC Guard =========
    function setKycRegistry(address reg) external onlyOwner {
        require(!kycLocked, "KYC_LOCKED");
        kyc = IKYCRegistry(reg);
        emit KycRegistryUpdated(reg);
    }

    function setKycGuard(bool on) external onlyOwner {
        require(!kycLocked, "KYC_LOCKED");
        if (on) {
            // disallow re-enabling after kycSunsetAt (if set)
            require(
                kycSunsetAt == 0 || block.timestamp < kycSunsetAt,
                "KYC_SUNSET"
            );
        }
        kycGuardEnabled = on;
        emit KycGuardToggled(on);
    }

    function setKycGuardExempt(address a, bool on) external onlyOwner {
        // Intentionally not locked; exemptions may be needed for routers/bridges/treasury
        kycGuardExempt[a] = on;
        emit KycGuardExemptSet(a, on);
    }

    // ========= Admin: AMM & Trading =========
    function setAMMPair(address pair, bool isPair_) external onlyOwner {
        require(!ammPairsLocked, "AMM_LOCKED");
        isAMMPair[pair] = isPair_;
        isExcludedFromLimits[pair] = true;
        // isExcludedFromFees[pair] = true;  // intentionally NOT auto-excluding from fees
        emit AMMPairSet(pair, isPair_);
    }

    // One-way switch
    function enableTrading() external onlyOwner {
        require(!tradingEnabled, "Already enabled");
        tradingEnabled = true;
        tradingEnabledAt = block.timestamp;
        tradingEnabledBlock = block.number;
        emit TradingEnabled(tradingEnabledAt, tradingEnabledBlock);

        // If no custom sunset was set before, auto-schedule Phase 1 to last 1 hour
        if (guardsSunsetAt == 0) {
            guardsSunsetAt = uint64(block.timestamp + 1 hours);
            emit GuardsSunsetSet(guardsSunsetAt);
        }
    }

    // ========= Admin: Fees =========
    function setFeeReceiver(address receiver) external onlyOwner {
        require(!feesLocked, "FEES_LOCKED");
        require(receiver != address(0), "Receiver=0");
        address old = feeReceiver;
        feeReceiver = receiver;
        // treasury/feeReceiver should typically be excluded from fees/limits
        isExcludedFromFees[receiver] = true;
        isExcludedFromLimits[receiver] = true;
        emit FeeReceiverChanged(old, receiver);
    }

    /// @notice Set buy/sell fees (BPS). Sum must not exceed MAX_TOTAL_FEE_BPS.
    /// If setting a non-zero fee, requires block.timestamp >= earliestFeeEnableAt.
    function setFees(uint16 buyBps, uint16 sellBps) external onlyOwner {
        require(!feesLocked, "FEES_LOCKED");
        require(
            uint256(buyBps) + uint256(sellBps) <= MAX_TOTAL_FEE_BPS,
            "Fee cap"
        );
        if (buyBps > 0 || sellBps > 0) {
            require(block.timestamp >= earliestFeeEnableAt, "Too early");
            require(feeReceiver != address(0), "No feeReceiver");
        }
        buyFeeBps = buyBps;
        sellFeeBps = sellBps;
        emit FeesUpdated(buyFeeBps, sellFeeBps);
    }

    /// @notice Optional investor-friendly guard: set a time before which fees must stay 0/0.
    function setEarliestFeeEnableAt(uint64 ts) external onlyOwner {
        require(!feesLocked, "FEES_LOCKED");
        earliestFeeEnableAt = ts;
        emit EarliestFeeEnableAtSet(ts);
    }

    function setFeeExclusion(
        address account,
        bool excluded
    ) external onlyOwner {
        require(!feeExclusionsLocked, "FEEEXCL_LOCKED");
        isExcludedFromFees[account] = excluded;
        emit FeeExclusionSet(account, excluded);
    }

    // ========= Admin: Launch guards (limits) =========
    function setLaunchParams(
        uint16 _maxTxBps,
        uint16 _maxWalletBps,
        uint32 _cooldownSeconds,
        uint8 _sniperBlocks
    ) external onlyOwner {
        require(!limitsLocked, "LIMITS_LOCKED");
        require(_maxTxBps <= 10_000 && _maxWalletBps <= 10_000, "Bad BPS");
        maxTxBps = _maxTxBps;
        maxWalletBps = _maxWalletBps;
        cooldownSeconds = _cooldownSeconds;
        sniperBlocks = _sniperBlocks;
        emit LaunchParamsSet(
            maxTxBps,
            maxWalletBps,
            cooldownSeconds,
            sniperBlocks
        );
    }

    function setLimitsExclusion(
        address account,
        bool excluded
    ) external onlyOwner {
        require(!limitsLocked, "LIMITS_LOCKED");
        isExcludedFromLimits[account] = excluded;
        emit LimitsExclusionSet(account, excluded);
    }

    // ========= Rescue (timelock/multisig should own) =========
    function rescueERC20(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner {
        require(to != address(0), "to=0");
        require(token != address(this), "no self");
        IERC20(token).transfer(to, amount);
        emit Rescue(token, to, amount);
    }

    // ========= Internals =========
    function _isBuy(address from, address to) internal view returns (bool) {
        return isAMMPair[from] && !isAMMPair[to];
    }

    function _isSell(address from, address to) internal view returns (bool) {
        return isAMMPair[to] && !isAMMPair[from];
    }

    function _applyFees(
        address from,
        address to,
        uint256 amount
    ) internal returns (uint256) {
        if (amount == 0) return 0;
        if (from == address(0) || to == address(0)) return amount; // no fee on mint/burn
        if (isExcludedFromFees[from] || isExcludedFromFees[to]) return amount;

        uint256 fee;
        if (_isBuy(from, to) && buyFeeBps > 0) {
            fee = (amount * buyFeeBps) / 10_000;
        } else if (_isSell(from, to) && sellFeeBps > 0) {
            fee = (amount * sellFeeBps) / 10_000;
        }

        if (fee > 0) {
            super._update(from, feeReceiver, fee);
            return amount - fee;
        }
        return amount;
    }

    function _checkTradingOpen(address from, address to) internal view {
        if (tradingEnabled) return;
        if (from == address(0) || to == address(0)) return; // mint/burn
        require(isExcludedFromLimits[from], "Trading not enabled");
    }

    function _enforceLaunchLimits(
        address from,
        address to,
        uint256 amount
    ) internal {
        if (!tradingEnabled) return;
        if (from == address(0) || to == address(0)) return;

        // Auto-sunset: if guardsSunsetAt reached, skip limits
        if (guardsSunsetAt != 0 && block.timestamp >= guardsSunsetAt) return;

        // --- Sniper blocks BEFORE exclusions ---
        if (
            sniperBlocks > 0 &&
            block.number < tradingEnabledBlock + sniperBlocks
        ) {
            if (_isBuy(from, to)) {
                // receiver must be an EOA (no code)
                require(to.code.length == 0, "EOA-only in sniperBlocks");
            }
        }

        // Then apply the usual exclusion short-circuit
        if (isExcludedFromLimits[from] || isExcludedFromLimits[to]) return;

        // MaxTx
        if (maxTxBps > 0) {
            uint256 maxTx = (totalSupply() * maxTxBps) / 10_000;
            require(amount <= maxTx, "maxTx");
        }

        // Cooldown (actor = buyer on buy, seller on sell)
        if (cooldownSeconds > 0) {
            address actor = _isBuy(from, to) ? to : from;
            uint64 last = lastTradeAt[actor];
            require(
                uint64(block.timestamp) >= last + cooldownSeconds,
                "cooldown"
            );
            lastTradeAt[actor] = uint64(block.timestamp);
        }

        // Max Wallet (skip sells to AMM)
        if (maxWalletBps > 0 && !_isSell(from, to)) {
            uint256 afterBalance = balanceOf(to) + amount;
            uint256 maxWallet = (totalSupply() * maxWalletBps) / 10_000;
            require(afterBalance <= maxWallet, "maxWallet");
        }
    }

    // ========= Transfer hook (OZ v5) =========
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        // 0) Emergency pause (allow mint/burn; allow ops via limits-exempt)
        if (paused()) {
            bool isMintOrBurn = (from == address(0) || to == address(0));
            bool opsExempt = isExcludedFromLimits[from] ||
                isExcludedFromLimits[to];
            require(isMintOrBurn || opsExempt, "PAUSED");
        }

        // 0.1) Blacklist (both sides)
        require(!isBlacklisted[from] && !isBlacklisted[to], "BLACKLISTED");

        // 1) KYC guard (recipient) if enabled (skip for exempt/zero address)
        if (kycGuardEnabled) {
            if (to != address(0) && !kycGuardExempt[to]) {
                require(address(kyc) != address(0), "KYC_REG_UNSET");
                require(kyc.isKYCApproved(to), "RECIPIENT_NEEDS_KYC");
            }
        }

        // 2) Trading gate (allow owner/ops before launch)
        _checkTradingOpen(from, to);

        // 3) Launch limits (maxTx, maxWallet, cooldown, sniperBlocks)
        _enforceLaunchLimits(from, to, value);

        // 4) Fees (buy/sell only; normal transfers 0 unless set)
        uint256 sendAmount = _applyFees(from, to, value);

        // 5) Move the net amount
        super._update(from, to, sendAmount);
    }
}
