// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Chainlink L2 sequencer uptime feed mock. answer 0 = up, 1 = down.
contract MockSequencerFeed {
    int256 public status;
    uint256 public startedAt;

    constructor(uint256 startedAt_) {
        startedAt = startedAt_;
    }

    function set(int256 status_, uint256 startedAt_) external {
        status = status_;
        startedAt = startedAt_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, status, startedAt, startedAt, 1);
    }
}
