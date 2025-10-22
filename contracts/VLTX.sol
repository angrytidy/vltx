// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract VLTX is ERC20, Ownable {
    // ====== Constants / Config ======
    uint256 public constant MAX_SUPPLY = 1_000_000_000 ether; // 1B * 1e18
    uint256 public constant FEE_DENOMINATOR = 10_000; // BPS denominator
    uint256 public constant MAX_TOTAL_FEE_BPS = 300; // 3.00% hard cap (buy + sell each must be <= cap)

    // ====== Trading / Launch State ======
    bool public tradingEnabled;
    uint256 public launchBlock; // set at enableTrading()
    uint8 public sniperBlocks; // 0..255 (e.g., 2-5)
    uint16 public cooldownSeconds; // per-address cooldown window (e.g., 45)

    // Limits (set as absolute token amounts)
    uint256 public maxTxAmount; // e.g., 2% of supply
    uint256 public maxWalletAmount; // e.g., 3% of supply

    // ====== Fees ======
    uint256 public buyFeeBps; // default 0
    uint256 public sellFeeBps; // default 0
    address public feeRecipient; // treasury/multisig

    // ====== Mappings ======
    mapping(address => bool) public isExcludedFromFees; // e.g., treasury, vesting, owner
    mapping(address => bool) public isExcludedFromLimits; // bypass maxTx/maxWallet/cooldown/trading gate
    mapping(address => bool) public automatedMarketMakerPairs; // AMM pairs for buy/sell detection
    mapping(address => uint256) private _lastTransferTimestamp; // address → last tx time (for cooldown)

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
    }

    // ====== Owner Setters ======

    /// @notice One-way switch. Records launch block for sniper window.
    function enableTrading() external onlyOwner {
        require(!tradingEnabled, "VLTX: already enabled");
        tradingEnabled = true;
        launchBlock = block.number;
        emit TradingEnabled(launchBlock);
    }

    /// @notice Set sniper blocks (e.g., 2-5) for initial blocks after enableTrading.
    function setSniperBlocks(uint8 _blocks) external onlyOwner {
        _setSniperBlocks(_blocks);
    }

    function _setSniperBlocks(uint8 _blocks) internal {
        uint8 old = sniperBlocks;
        sniperBlocks = _blocks;
        emit SniperBlocksUpdated(old, _blocks);
    }

    /// @notice Set per-address cooldown in seconds (e.g., 45). 0 disables cooldown.
    function setCooldown(uint16 secs) external onlyOwner {
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
    function setAutomatedMarketMakerPair(
        address pair,
        bool isPair
    ) external onlyOwner {
        automatedMarketMakerPairs[pair] = isPair;
        emit AMMPairSet(pair, isPair);
    }

    /// @notice Update fee recipient (treasury / multisig).
    function setFeeRecipient(address newRecipient) external onlyOwner {
        require(newRecipient != address(0), "VLTX: zero addr");
        address old = feeRecipient;
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(old, newRecipient);
    }

    /// @notice Update buy/sell fees (BPS). Each must be <= MAX_TOTAL_FEE_BPS.
    function setFees(uint256 _buyBps, uint256 _sellBps) external onlyOwner {
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
            // Sniper window can be used for stricter policies if desired.
            bool inSniperWindow = block.number <= (launchBlock + sniperBlocks);

            // MaxTx (skip if amount==0)
            if (amount > 0) {
                require(amount <= maxTxAmount, "VLTX: > maxTx");
            }

            // MaxWallet on recipient (post-fee incoming amount is <= amount, so using 'amount' is safe)
            if (to != address(0)) {
                require(
                    balanceOf(to) + amount <= maxWalletAmount,
                    "VLTX: > maxWallet"
                );
            }

            // Cooldown (basic anti-bot pacing). Apply to buys and transfers; sells can be exempted if desired.
            if (cooldownSeconds > 0) {
                // For buys (from AMM) throttle 'to'; for transfers throttle both; for sells throttle 'from'
                if (automatedMarketMakerPairs[from]) {
                    _requireCooldownOk(to);
                    _lastTransferTimestamp[to] = block.timestamp;
                } else if (automatedMarketMakerPairs[to]) {
                    _requireCooldownOk(from);
                    _lastTransferTimestamp[from] = block.timestamp;
                } else {
                    _requireCooldownOk(from);
                    _requireCooldownOk(to);
                    _lastTransferTimestamp[from] = block.timestamp;
                    _lastTransferTimestamp[to] = block.timestamp;
                }
            }

            // Example stricter rule during sniper window (optional):
            // require(!isContract(to), "VLTX: contracts blocked in sniper window");
            // (Left commented to keep behavior predictable; add if required.)
            inSniperWindow; // silence unused var if not used
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
            // send fee to recipient, then transfer remainder to 'to'
            super._update(from, feeRecipient, feeAmount);
            amount -= feeAmount;
        }

        super._update(from, to, amount);
    }

    function _requireCooldownOk(address account) private view {
        // Excluded handles were filtered earlier; here we assume we only call for non-excluded
        uint256 lastTs = _lastTransferTimestamp[account];
        require(block.timestamp >= lastTs + cooldownSeconds, "VLTX: cooldown");
    }

    // ====== Owner helpers ======

    /// @notice Convenience setters for percentages of total supply (e.g., 200 = 2%).
    function setLimitsBps(
        uint256 maxTxBps,
        uint256 maxWalletBps
    ) external onlyOwner {
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
