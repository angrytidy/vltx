// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/**
 * @title KycPresale
 * @notice Presale that requires KYC for buy/claim, with min/max per wallet and hard cap.
 * - Accepts native coin (e.g., BNB on BSC). Switch to stablecoin easily if needed.
 * - Owner deposits sale tokens, then enables "claim".
 * - Over-cap contributions are partially accepted and auto-refunded.
 */

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IKYCRegistry} from "./KYCRegistry.sol";

contract KycPresale is Ownable2Step, ReentrancyGuard, Pausable {
    // ---- Config
    IKYCRegistry public immutable kyc;
    IERC20 public immutable token; // token being sold
    uint256 public rate; // tokens per 1 BNB; 1e18-based
    uint256 public startTime;
    uint256 public endTime;
    uint256 public hardCapBNB; // total raise cap (wei)
    uint256 public minContribution; // per wallet, wei (first buy)
    uint256 public maxContribution; // per wallet, cumulative wei (0 = unlimited)

    // ---- Accounting
    uint256 public totalRaised;
    mapping(address => uint256) public contributedBNB;
    mapping(address => uint256) public purchasedTokens;

    // ---- Claim
    bool public claimEnabled;
    uint256 public totalTokensDeposited;

    event Bought(
        address indexed buyer,
        uint256 bnbIn,
        uint256 tokensOut,
        uint256 refunded
    );
    event TokensDeposited(uint256 amount);
    event ClaimEnabled();
    event Claimed(address indexed user, uint256 amount);
    event Refunded(address indexed to, uint256 amount);

    constructor(
        address initialOwner,
        address kycRegistry,
        address token_,
        uint256 rate_, // e.g. 100_000e18 => 1 BNB = 100,000 tokens
        uint256 startTime_,
        uint256 endTime_,
        uint256 hardCapBNB_,
        uint256 minContribution_,
        uint256 maxContribution_
    )
        Ownable(initialOwner) // OZ v5: pass initial owner to Ownable base
    {
        require(kycRegistry != address(0) && token_ != address(0), "ZERO_ADDR");
        require(rate_ > 0, "BAD_RATE");
        require(startTime_ < endTime_, "BAD_WINDOW");
        require(hardCapBNB_ > 0, "BAD_HARDCAP");
        require(
            maxContribution_ == 0 || maxContribution_ >= minContribution_,
            "BAD_LIMITS"
        );

        kyc = IKYCRegistry(kycRegistry);
        token = IERC20(token_);
        rate = rate_;
        startTime = startTime_;
        endTime = endTime_;
        hardCapBNB = hardCapBNB_;
        minContribution = minContribution_;
        maxContribution = maxContribution_;
    }

    // ---- Admin
    function pause() external onlyOwner {
        _pause();
    }
    function unpause() external onlyOwner {
        _unpause();
    }

    function setRate(uint256 newRate) external onlyOwner whenPaused {
        require(newRate > 0, "BAD_RATE");
        rate = newRate;
    }

    function setWindow(
        uint256 newStart,
        uint256 newEnd
    ) external onlyOwner whenPaused {
        require(newStart < newEnd, "BAD_WINDOW");
        startTime = newStart;
        endTime = newEnd;
    }

    function setMinMax(
        uint256 min_,
        uint256 max_
    ) external onlyOwner whenPaused {
        require(max_ == 0 || max_ >= min_, "BAD_LIMITS");
        minContribution = min_;
        maxContribution = max_;
    }

    function setHardCap(uint256 newCap) external onlyOwner whenPaused {
        require(newCap >= totalRaised, "CAP_LT_RAISED");
        hardCapBNB = newCap;
    }

    // Deposit tokens for claims (do this before enabling claims)
    function depositTokens(uint256 amount) external onlyOwner {
        require(amount > 0, "ZERO");
        require(
            token.transferFrom(msg.sender, address(this), amount),
            "TRANSFER_FAIL"
        );
        totalTokensDeposited += amount;
        emit TokensDeposited(amount);
    }

    function enableClaim(bool on) external onlyOwner {
        claimEnabled = on;
        if (on) emit ClaimEnabled();
    }

    // Withdraw raised BNB (after presale or periodically if desired)
    function withdrawBNB(
        address payable to,
        uint256 amount
    ) external onlyOwner {
        require(to != address(0), "ZERO");
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "WITHDRAW_FAIL");
    }

    // Emergency / leftover: withdraw tokens (e.g., unsold or after claim period)
    function withdrawTokens(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "ZERO");
        require(token.transfer(to, amount), "TOKEN_WITHDRAW_FAIL");
    }

    // ---- Buying
    receive() external payable {
        revert("DIRECT_SEND_DISABLED");
    }

    modifier onlyWhileOpen() {
        require(
            block.timestamp >= startTime && block.timestamp <= endTime,
            "NOT_OPEN"
        );
        _;
    }

    function buy() external payable nonReentrant whenNotPaused onlyWhileOpen {
        require(kyc.isKYCApproved(msg.sender), "KYC_REQUIRED");
        require(msg.value > 0, "NO_VALUE");

        // Hard cap handling (accept-partial + refund overflow)
        uint256 room = hardCapBNB - totalRaised;
        require(room > 0, "HARDCAP_REACHED");
        uint256 accept = msg.value <= room ? msg.value : room;
        uint256 refund = msg.value - accept;

        // Per-wallet limits (cumulative max; min on first buy)
        uint256 prev = contributedBNB[msg.sender];
        if (prev == 0 && minContribution > 0) {
            require(accept >= minContribution, "MIN_NOT_MET");
        }
        if (maxContribution > 0) {
            require(prev + accept <= maxContribution, "MAX_WALLET");
        }

        // Effects
        contributedBNB[msg.sender] = prev + accept;
        totalRaised += accept;

        // Tokens purchased: tokens = accept * rate / 1e18
        uint256 tokensOut = (accept * rate) / 1e18;
        purchasedTokens[msg.sender] += tokensOut;

        // Refund overflow
        if (refund > 0) {
            (bool ok2, ) = msg.sender.call{value: refund}("");
            require(ok2, "REFUND_FAIL");
            emit Refunded(msg.sender, refund);
        }

        emit Bought(msg.sender, accept, tokensOut, refund);
    }

    // ---- Claim
    function claim() external nonReentrant {
        require(claimEnabled, "CLAIM_OFF");
        uint256 amt = purchasedTokens[msg.sender];
        require(amt > 0, "NOTHING");
        purchasedTokens[msg.sender] = 0;
        require(token.transfer(msg.sender, amt), "CLAIM_TRANSFER_FAIL");
        emit Claimed(msg.sender, amt);
    }
}
