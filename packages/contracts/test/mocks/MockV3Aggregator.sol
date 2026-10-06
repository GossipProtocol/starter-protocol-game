// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal Chainlink aggregator mock with full control over round data.
contract MockV3Aggregator {
    uint8 public immutable decimals;

    uint80 public roundId;
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;
    uint80 public answeredInRound;

    mapping(uint80 => int256) public answers;
    mapping(uint80 => uint256) public timestamps;

    constructor(uint8 decimals_, int256 initialAnswer) {
        decimals = decimals_;
        updateAnswer(initialAnswer);
    }

    /// @notice New round with `updatedAt = block.timestamp`.
    function updateAnswer(int256 answer_) public {
        _push(answer_, block.timestamp);
    }

    function updateAnswerAt(int256 answer_, uint256 timestamp) external {
        _push(answer_, timestamp);
    }

    function setRoundData(uint80 roundId_, int256 answer_, uint256 updatedAt_, uint80 answeredInRound_) external {
        roundId = roundId_;
        answer = answer_;
        startedAt = updatedAt_;
        updatedAt = updatedAt_;
        answeredInRound = answeredInRound_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }

    function getRoundData(uint80 id) external view returns (uint80, int256, uint256, uint256, uint80) {
        return (id, answers[id], timestamps[id], timestamps[id], id);
    }

    function _push(int256 answer_, uint256 timestamp) internal {
        roundId++;
        answer = answer_;
        startedAt = timestamp;
        updatedAt = timestamp;
        answeredInRound = roundId;
        answers[roundId] = answer_;
        timestamps[roundId] = timestamp;
    }
}
