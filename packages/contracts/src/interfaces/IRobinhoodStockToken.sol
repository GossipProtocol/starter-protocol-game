// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Robinhood Stock Token extensions (ERC-8056 scaled UI amount + oracle pause flag).
interface IRobinhoodStockToken {
    /// @notice Shares per token, 1e18 = 1.0.
    function uiMultiplier() external view returns (uint256);

    /// @notice True while a corporate action is being processed and the Chainlink feed is frozen.
    function oraclePaused() external view returns (bool);
}
