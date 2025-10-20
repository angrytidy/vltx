// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract VLTX is ERC20, Ownable {
    bool public tradingEnabled;
    uint256 public immutable MAX_SUPPLY = 1_000_000_000 ether;
    mapping(address => bool) public isExcluded;

    constructor(
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) {
        _mint(msg.sender, MAX_SUPPLY);
        isExcluded[msg.sender] = true;
    }

    function enableTrading() external onlyOwner {
        require(!tradingEnabled, "Already enabled");
        tradingEnabled = true;
    }

    function setExcluded(address account, bool excluded) external onlyOwner {
        isExcluded[account] = excluded;
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        if (!tradingEnabled) {
            require(isExcluded[from] || isExcluded[to], "Trading not enabled");
        }
        super._update(from, to, value);
    }
}
