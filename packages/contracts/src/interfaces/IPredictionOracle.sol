// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Oracle interface consumed by Doppler's PredictionMigrator (MIT upstream, redeclared here so `src/`
/// never imports Doppler source).
interface IPredictionOracle {
    event WinnerDeclared(address indexed oracle, address indexed winningToken);

    function getWinner(address oracle) external view returns (address winningToken, bool isFinalized);
}
