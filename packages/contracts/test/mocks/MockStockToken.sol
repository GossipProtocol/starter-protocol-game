// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Stand-in for a Robinhood stock token's ERC-8056 multiplier and oracle pause flag.
contract MockStockToken {
    uint256 public uiMultiplier = 1e18;
    bool public oraclePaused;

    function setMultiplier(uint256 m) external {
        uiMultiplier = m;
    }

    function setOraclePaused(bool p) external {
        oraclePaused = p;
    }
}
