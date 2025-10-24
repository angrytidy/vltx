// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title VAULTEX (VLTX)
 * @notice BEP-20 style token for GemPad presale launches.
 * - 0% fees at TGE (fees are togglable later, but hard-capped and lockable)
 * - First-hour launch guards: maxTx, maxWallet (skip AMM), cooldown, sniperBlocks
 * - No base liquidity required; GemPad finalization creates/locks LP
 * - Auto-exclude AMM pair from fees/limits
 * - One-way locks for fees and guards to calm investors
 */
contract VLTX is ERC20, Ownable {
    // ====== Constants / Config ======
    uint256 public constant MAX_SUPPLY = 1_000_000_000 ether; // 1B * 1e18
    uint256 public constant FEE_DENOMINATOR = 10_000; // basis points denominator
    uint256 public constant MAX_TOTAL_FEE_BPS = 300; // 3.00% hard cap per side

    // ====== Trading / Launch State ======
    bool public tradingEnabled;
    uint256 public launchBlock; // set at enableTrading()
    uint8 public sniperBlocks; // e.g., 2–5 blocks
    uint16 public cooldownSeconds; // e.g., 45 seconds

    // Limits (absolute token amounts)
    uint256 public maxTxAmount; // e.g., 2% of supply
    uint256 public maxWalletAmount; // e.g., 3% of supply

    // ====== Fees ======
    uint256 public buyFeeBps; // default 0
    uint256 public sellFeeBps; // default 0
    address public feeRecipient; // treasury/multisig

    // ====== Governance locks ======
    bool public feesLocked; // once true, setFees can’t change
    bool public guardsLocked; // once true, limits/cooldown/sniper can’t change

    // ====== Mappings ======
    mapping(address => bool) public isExcludedFromFees; // e.g., treasury, vesting, owner
    mapping(address => bool) public isExcludedFromLimits; // gate/maxTx/maxWallet/cooldown bypass
    mapping(address => bool) public automatedMarketMakerPairs; // AMM pairs for buy/sell detection
    mapping(address => uint256) private _lastTransferTimestamp; // cooldown tracker

    // ====== Events ======
    event TradingEnabled(uint256 indexed blockNumber);
    event SniperBlocksUpdated(uint8 oldValue, uint8 newValue);
    event CooldownUpdated(uint16 oldValue, uint16 newValue);
    event LimitsUpdated(
        uint256 oldMaxTx,
        uint256 newMaxTx,
        uint256 oldMaxWallet,
        uint256 newMaxWallet
    );
    event AMMPairSet(address indexed pair, bool isPair);
    event FeeRecipientUpdated(
        address indexed oldRecipient,
        address indexed newRecipient
    );
    event FeesUpdated(
        uint256 oldBuyBps,
        uint256 newBuyBps,
        uint256 oldSellBps,
        uint256 newSellBps
    );
    event ExcludedFromFees(address indexed account, bool excluded);
    event ExcludedFromLimits(address indexed account, bool excluded);
    event FeesLocked();
    event GuardsLocked();

    // ====== Constructor ======
    constructor(
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) Ownable(msg.sender) {
        _mint(msg.sender, MAX_SUPPLY);

        // sane defaults
        feeRecipient = msg.sender;

        // Exclude key ops by default
        isExcludedFromFees[msg.sender] = true;
        isExcludedFromLimits[msg.sender] = true;
        isExcludedFromFees[address(this)] = true;
        isExcludedFromLimits[address(this)] = true;

        // Initial limits (can be tuned before TGE)
        _setLimits(_percentOfTotal(200), _percentOfTotal(300)); // 2% tx, 3% wallet
        _setCooldown(45);
        _setSniperBlocks(3);

        // Fees start at 0% for TGE (explicitly)
        buyFeeBps = 0;
        sellFeeBps = 0;
    }

    // ====== Owner Setters ======

    /// @notice One-way switch. Records launch block for sniper window.
    function enableTrading() external onlyOwner {
        require(!tradingEnabled, "VLTX: already enabled");
        tradingEnabled = true;
        launchBlock = block.number;
        emit TradingEnabled(launchBlock);
    }

    /// @notice Lock fee configuration permanently (cannot be undone).
    function lockFeesForever() external onlyOwner {
        require(!feesLocked, "VLTX: fees already locked");
        feesLocked = true;
        emit FeesLocked();
    }

    /// @notice Lock guard parameters permanently (limits/cooldown/sniper).
    function lockGuardsForever() external onlyOwner {
        require(!guardsLocked, "VLTX: guards already locked");
        guardsLocked = true;
        emit GuardsLocked();
    }

    /// @notice Set sniper blocks (e.g., 2-5) for initial blocks after enableTrading.
    function setSniperBlocks(uint8 _blocks) external onlyOwner {
        require(!guardsLocked, "VLTX: guards locked");
        _setSniperBlocks(_blocks);
    }

    function _setSniperBlocks(uint8 _blocks) internal {
        uint8 old = sniperBlocks;
        sniperBlocks = _blocks;
        emit SniperBlocksUpdated(old, _blocks);
    }

    /// @notice Set per-address cooldown in seconds (e.g., 45). 0 disables cooldown.
    function setCooldown(uint16 secs) external onlyOwner {
        require(!guardsLocked, "VLTX: guards locked");
        _setCooldown(secs);
    }

    function _setCooldown(uint16 secs) internal {
        uint16 old = cooldownSeconds;
        cooldownSeconds = secs;
        emit CooldownUpdated(old, secs);
    }

    /// @notice Set absolute limits (in wei). Use helpers to compute from % of supply if desired.
    function setLimits(
        uint256 newMaxTxAmount,
        uint256 newMaxWalletAmount
    ) external onlyOwner {
        require(!guardsLocked, "VLTX: guards locked");
        _setLimits(newMaxTxAmount, newMaxWalletAmount);
    }

    function _setLimits(
        uint256 newMaxTxAmount,
        uint256 newMaxWalletAmount
    ) internal {
        require(
            newMaxTxAmount > 0 && newMaxWalletAmount > 0,
            "VLTX: zero limit"
        );
        uint256 oldTx = maxTxAmount;
        uint256 oldWallet = maxWalletAmount;
        maxTxAmount = newMaxTxAmount;
        maxWalletAmount = newMaxWalletAmount;
        emit LimitsUpdated(
            oldTx,
            newMaxTxAmount,
            oldWallet,
            newMaxWalletAmount
        );
    }

    /// @notice Helper: returns X basis points of total supply (e.g., 200 → 2%).
    function percentOfTotal(uint256 bps) external view returns (uint256) {
        return _percentOfTotal(bps);
    }

    function _percentOfTotal(uint256 bps) internal view returns (uint256) {
        require(bps <= 10_000, "VLTX: bps > 100%");
        return (MAX_SUPPLY * bps) / 10_000;
    }

    /// @notice Configure which addresses are AMM pairs (used to detect buy/sell).
    /// Also auto-excludes the pair from fees/limits (best practice).
    function setAutomatedMarketMakerPair(
        address pair,
        bool isPair
    ) external onlyOwner {
        automatedMarketMakerPairs[pair] = isPair;
        emit AMMPairSet(pair, isPair);

        // Auto-exclude AMM pair to avoid maxWallet/cooldown/fees interfering with trades
        isExcludedFromLimits[pair] = true;
        isExcludedFromFees[pair] = true;
        emit ExcludedFromLimits(pair, true);
        emit ExcludedFromFees(pair, true);
    }

    /// @notice Update fee recipient (treasury / multisig).
    function setFeeRecipient(address newRecipient) external onlyOwner {
        require(
            newRecipient != address(0) && newRecipient != address(this),
            "VLTX: invalid recipient"
        );
        address old = feeRecipient;
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(old, newRecipient);
    }

    /// @notice Update buy/sell fees (BPS). Each must be <= MAX_TOTAL_FEE_BPS.
    function setFees(uint256 _buyBps, uint256 _sellBps) external onlyOwner {
        require(!feesLocked, "VLTX: fees locked");
        require(_buyBps <= MAX_TOTAL_FEE_BPS, "VLTX: buy fee too high");
        require(_sellBps <= MAX_TOTAL_FEE_BPS, "VLTX: sell fee too high");
        uint256 oldBuy = buyFeeBps;
        uint256 oldSell = sellFeeBps;
        buyFeeBps = _buyBps;
        sellFeeBps = _sellBps;
        emit FeesUpdated(oldBuy, _buyBps, oldSell, _sellBps);
    }

    /// @notice Exclude/Include from fees.
    function setExcludedFromFees(
        address account,
        bool excluded
    ) external onlyOwner {
        isExcludedFromFees[account] = excluded;
        emit ExcludedFromFees(account, excluded);
    }

    /// @notice Exclude/Include from limits (trading gate, maxTx, maxWallet, cooldown).
    function setExcludedFromLimits(
        address account,
        bool excluded
    ) external onlyOwner {
        isExcludedFromLimits[account] = excluded;
        emit ExcludedFromLimits(account, excluded);
    }

    /// @notice Batch helpers (quality of life for setup)
    function setExcludedFromFeesBatch(
        address[] calldata accts,
        bool excluded
    ) external onlyOwner {
        for (uint256 i; i < accts.length; i++) {
            isExcludedFromFees[accts[i]] = excluded;
            emit ExcludedFromFees(accts[i], excluded);
        }
    }
    function setExcludedFromLimitsBatch(
        address[] calldata accts,
        bool excluded
    ) external onlyOwner {
        for (uint256 i; i < accts.length; i++) {
            isExcludedFromLimits[accts[i]] = excluded;
            emit ExcludedFromLimits(accts[i], excluded);
        }
    }

    // ====== Transfer rules / fees ======
    function _update(
        address from,
        address to,
        uint256 amount
    ) internal override {
        // Pre-trading gate: only setup ops by excluded accounts (e.g., add liquidity, treasury allocs).
        if (!tradingEnabled) {
            require(
                isExcludedFromLimits[from] || isExcludedFromLimits[to],
                "VLTX: trading not enabled"
            );
            super._update(from, to, amount);
            return;
        }

        // Apply limits/guards unless excluded
        bool limitsOn = !(isExcludedFromLimits[from] ||
            isExcludedFromLimits[to]);

        if (limitsOn) {
            // Sniper window marker (available for custom rules if needed)
            bool inSniperWindow = block.number <= (launchBlock + sniperBlocks);
            inSniperWindow; // silence unused var (kept for future use)

            // MaxTx (skip if amount==0)
            if (amount > 0) {
                require(amount <= maxTxAmount, "VLTX: > maxTx");
            }

            // DO NOT enforce maxWallet on AMM pair (prevents sells from failing)
            if (to != address(0) && !automatedMarketMakerPairs[to]) {
                require(
                    balanceOf(to) + amount <= maxWalletAmount,
                    "VLTX: > maxWallet"
                );
            }

            // Cooldown (apply to buys & transfers; sells throttle 'from')
            if (cooldownSeconds > 0) {
                if (automatedMarketMakerPairs[from]) {
                    // BUY: throttle recipient
                    _requireCooldownOk(to);
                    _lastTransferTimestamp[to] = block.timestamp;
                } else if (automatedMarketMakerPairs[to]) {
                    // SELL: throttle sender
                    _requireCooldownOk(from);
                    _lastTransferTimestamp[from] = block.timestamp;
                } else {
                    // TRANSFER: throttle both sides
                    _requireCooldownOk(from);
                    _requireCooldownOk(to);
                    _lastTransferTimestamp[from] = block.timestamp;
                    _lastTransferTimestamp[to] = block.timestamp;
                }
            }
        }

        // ===== Fee logic =====
        uint256 feeAmount = 0;
        bool takeFee = !(isExcludedFromFees[from] || isExcludedFromFees[to]);

        if (takeFee && amount > 0) {
            if (automatedMarketMakerPairs[from] && buyFeeBps > 0) {
                // BUY: from AMM → user
                feeAmount = (amount * buyFeeBps) / FEE_DENOMINATOR;
            } else if (automatedMarketMakerPairs[to] && sellFeeBps > 0) {
                // SELL: user → AMM
                feeAmount = (amount * sellFeeBps) / FEE_DENOMINATOR;
            }
        }

        if (feeAmount > 0) {
            super._update(from, feeRecipient, feeAmount);
            amount -= feeAmount;
        }

        super._update(from, to, amount);
    }

    function _requireCooldownOk(address account) private view {
        uint256 lastTs = _lastTransferTimestamp[account];
        require(block.timestamp >= lastTs + cooldownSeconds, "VLTX: cooldown");
    }

    // ====== Owner helpers ======

    /// @notice Convenience setters for percentages of total supply (e.g., 200 = 2%).
    function setLimitsBps(
        uint256 maxTxBps,
        uint256 maxWalletBps
    ) external onlyOwner {
        require(!guardsLocked, "VLTX: guards locked");
        _setLimits(_percentOfTotal(maxTxBps), _percentOfTotal(maxWalletBps));
    }

    /// @notice Rescue tokens sent by mistake.
    function sweepERC20(
        address token,
        address to,
        uint256 amt
    ) external onlyOwner {
        require(to != address(0), "VLTX: zero to");
        require(token != address(this), "VLTX: cannot sweep VLTX");
        ERC20(token).transfer(to, amt);
    }
}
