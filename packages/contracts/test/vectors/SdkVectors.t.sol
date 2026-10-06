// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BeeefOracle } from "src/BeeefOracle.sol";
import { BeeefRoundFactory } from "src/BeeefRoundFactory.sol";

import { MockERC20 } from "test/mocks/MockERC20.sol";
import { LocalDopplerSetup } from "test/utils/LocalDopplerSetup.sol";

/// @notice Writes packages/sdk/test/vectors.json from the real contracts, so the TypeScript sdk (multiplier, lock time,
/// market calendar, payout maths) is tested against on-chain results instead of re-derived expectations.
contract SdkVectors is LocalDopplerSetup {
    string internal constant OUT = "../sdk/test/vectors.json";

    function _u(uint256 v) internal pure returns (string memory) {
        return string.concat('"', vm.toString(v), '"'); // strings: JSON numbers lose precision past 2^53
    }

    function test_writeVectors() public {
        (, uint256 roundId, BeeefOracle oracle, address entryA, address entryB) = _createPair(30 minutes);
        BeeefRoundFactory.Round memory r = factory.getRound(roundId);

        // ---- multiplier ----
        string memory mult = "[";
        uint256 span = r.lockTime - r.startTime;
        uint256[9] memory offsets =
            [uint256(0), 1, span / 7, span / 3, span / 2, (span * 9) / 10, span - 1, span, span + 30];
        for (uint256 i; i < offsets.length; ++i) {
            uint256 t = r.startTime + offsets[i];
            mult = string.concat(
                mult, i == 0 ? "" : ",", '{"t":', _u(t), ',"m":', _u(clockHook.multiplierAt(entryA, t)), "}"
            );
        }
        mult = string.concat(mult, "]");

        // ---- lock times ----
        string memory locks = "[";
        uint256[5] memory durs = [uint256(5 minutes), 10 minutes, 30 minutes, 1 hours, 1 days];
        for (uint256 i; i < durs.length; ++i) {
            locks = string.concat(
                locks,
                i == 0 ? "" : ",",
                '{"start":"1000","duration":',
                _u(durs[i]),
                ',"lock":',
                _u(registry.lockTimeFor(1000, durs[i])),
                "}"
            );
        }
        locks = string.concat(locks, "]");

        // ---- market calendar ----
        uint256 monday = 1_789_948_800;
        uint256[10] memory ts = [
            monday + 14 hours,
            monday + 30 minutes,
            monday + 1 hours,
            monday + 4 days + 22 hours,
            monday + 4 days + 23 hours + 30 minutes,
            monday + 5 days + 12 hours,
            monday + 6 days + 22 hours,
            monday + 6 days + 23 hours + 30 minutes,
            monday + 7 days + 1 hours,
            monday + 2 days + 23 hours + 55 minutes
        ];
        string memory cal = "[";
        for (uint256 i; i < ts.length; ++i) {
            cal = string.concat(
                cal,
                i == 0 ? "" : ",",
                '{"t":',
                _u(ts[i]),
                ',"open1h":',
                registry.isMarketOpen(ts[i], ts[i] + 1 hours) ? "true" : "false",
                ',"next10m":',
                _u(registry.nextStart(ts[i], 10 minutes)),
                ',"next1d":',
                _u(registry.nextStart(ts[i], 1 days)),
                "}"
            );
        }
        cal = string.concat(cal, "]");

        // ---- a real round: two bets on A at different times, one on B, A wins ----
        _fund(alice, 40e6);
        _fund(bob, 40e6);
        _fund(carol, 30e6);
        uint256 aliceTokens = _buy(entryA, alice, 40e6);
        vm.warp(r.startTime + span * 3 / 4);
        uint256 bobTokens = _buy(entryA, bob, 40e6);
        uint256 carolTokens = _buy(entryB, carol, 30e6);
        vm.warp(r.endTime);
        _setPrice(feedA, oracle.startSnapshot().priceA * 101 / 100);
        _setPrice(feedB, oracle.startSnapshot().priceB);
        oracle.finalize();
        factory.settle(roundId);
        uint256 pot = migrator.getMarket(address(oracle)).totalPot;
        uint256 claimable = migrator.getEntry(address(oracle), factory.ENTRY_ID_A()).claimableSupply;
        uint256 aliceOut = _claim(address(oracle), entryA, alice, aliceTokens);
        uint256 bobOut = _claim(address(oracle), entryA, bob, bobTokens);

        string memory round = string.concat(
            '{"pot":',
            _u(pot),
            ',"claimableSupply":',
            _u(claimable),
            ',"claims":[{"tokens":',
            _u(aliceTokens),
            ',"out":',
            _u(aliceOut),
            '},{"tokens":',
            _u(bobTokens),
            ',"out":',
            _u(bobOut),
            '}],"loserTokens":',
            _u(carolTokens),
            "}"
        );

        string memory json = string.concat(
            '{"clock":{"start":',
            _u(r.startTime),
            ',"lock":',
            _u(r.lockTime),
            ',"floor":',
            _u(r.floorWad),
            '},"multiplier":',
            mult,
            ',"lockTimes":',
            locks,
            ',"snapshotWindow":',
            _u(SNAPSHOT_WINDOW),
            ',"calendar":',
            cal,
            ',"round":',
            round,
            "}"
        );
        vm.writeFile(OUT, json);
        assertGt(MockERC20(usd).balanceOf(alice), 0);
    }
}
