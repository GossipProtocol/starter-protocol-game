// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20 } from "@solady/tokens/ERC20.sol";

/// @notice Mintable ERC20 with configurable decimals (stands in for USDG, 6 decimals).
contract MockERC20 is ERC20 {
    string internal _name;
    string internal _symbol;
    uint8 internal immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        _name = name_;
        _symbol = symbol_;
        _decimals = decimals_;
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
