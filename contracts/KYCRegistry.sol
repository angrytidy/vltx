// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/**
 * @title KYCRegistry
 * @notice On-chain source of truth for wallet KYC status.
 * - Stores only a boolean and a metadata pointer per wallet (NO PII on-chain).
 * - DEFAULT_ADMIN_ROLE controls operators and policy.
 * - KYC_OPERATOR_ROLE can set/revoke KYC for users (single or batch).
 */

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract KYCRegistry is AccessControl, ReentrancyGuard {
    bytes32 public constant KYC_OPERATOR_ROLE = keccak256("KYC_OPERATOR_ROLE");

    event KYCSet(address indexed user, bool status, string meta);
    event KYCBatchSet(uint256 count, bool status, string meta);
    event KYCMetaUpdated(address indexed user, string meta);

    mapping(address => bool) public isKYCApproved; // true if wallet is KYC'd
    mapping(address => string) public kycMeta; // IPFS CID / provider case ID / note (NO PII)

    /**
     * @param initialAdmin    Multisig or owner with DEFAULT_ADMIN_ROLE.
     * @param initialOperator Optional operator EOA; set address(0) to skip.
     */
    constructor(address initialAdmin, address initialOperator) {
        require(initialAdmin != address(0), "ADMIN_ZERO");
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        if (initialOperator != address(0)) {
            _grantRole(KYC_OPERATOR_ROLE, initialOperator);
        }
    }

    // ---- Role helpers
    function addOperator(address op) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(KYC_OPERATOR_ROLE, op);
    }

    function removeOperator(address op) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(KYC_OPERATOR_ROLE, op);
    }

    // ---- KYC setters
    function setKYC(
        address user,
        bool approved,
        string calldata meta
    ) external nonReentrant onlyRole(KYC_OPERATOR_ROLE) {
        require(user != address(0), "USER_ZERO");
        isKYCApproved[user] = approved;
        kycMeta[user] = meta; // store only a reference, not PII
        emit KYCSet(user, approved, meta);
    }

    function setKYCBatch(
        address[] calldata users,
        bool approved,
        string calldata meta
    ) external nonReentrant onlyRole(KYC_OPERATOR_ROLE) {
        uint256 n = users.length;
        require(n > 0, "EMPTY");
        for (uint256 i = 0; i < n; i++) {
            address u = users[i];
            require(u != address(0), "USER_ZERO");
            isKYCApproved[u] = approved;
            kycMeta[u] = meta;
        }
        emit KYCBatchSet(n, approved, meta);
    }

    function updateMeta(
        address user,
        string calldata meta
    ) external nonReentrant onlyRole(KYC_OPERATOR_ROLE) {
        require(user != address(0), "USER_ZERO");
        kycMeta[user] = meta;
        emit KYCMetaUpdated(user, meta);
    }

    // ---- View helper
    function status(
        address user
    ) external view returns (bool approved, string memory meta) {
        return (isKYCApproved[user], kycMeta[user]);
    }
}

// Lightweight interface for other contracts
interface IKYCRegistry {
    function isKYCApproved(address a) external view returns (bool);
}
