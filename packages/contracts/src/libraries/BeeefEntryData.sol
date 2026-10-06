// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { LibClone } from "@solady/utils/LibClone.sol";
import { LibString } from "@solady/utils/LibString.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";

import { BeeefOracle } from "src/BeeefOracle.sol";
import { BeeefRegistry } from "src/BeeefRegistry.sol";
import { BeneficiaryData, CreateParams, Curve, InitData } from "src/interfaces/IDoppler.sol";

/// @dev DopplerERC20V1 vesting schedule, only needed to ABI-encode an empty array.
struct VestingSchedule {
    uint64 cliff;
    uint64 duration;
}

/**
 * @title BeeefEntryData
 * @notice Builds the Airlock.create params for one round entry. A linked library so the factory stays under 24KB.
 * Pool config: empty beneficiaries and farTick = starting tick (migratable immediately, gated only by the oracle),
 * BeeefClockHook with the round's clock as its init calldata.
 */
library BeeefEntryData {
    struct Args {
        uint256 roundId;
        bytes32 entryId;
        address oracle;
        string title;
        string side;
        address integrator;
        bytes clock;
        uint256 supply;
        address numeraire;
        address tokenFactory;
        bool cloneErc20Factory;
        address governanceFactory;
        address poolInitializer;
        address migrator;
        address dopplerHook;
        uint24 fee;
        int24 tickSpacing;
        Curve[] curves;
    }

    /// @notice Clones and initializes the round's oracle with the registry's current oracle settings. Runs via
    /// delegatecall, so the factory (address(this)) becomes the oracle's registrar.
    struct OracleArgs {
        address feedA;
        address feedB;
        address stockA;
        address stockB;
        uint64 start;
        uint64 end;
    }

    function startOracle(
        address implementation,
        BeeefRegistry registry,
        OracleArgs memory o
    ) public returns (address oracle) {
        oracle = LibClone.clone(implementation);
        BeeefOracle(oracle).initialize(_oracleConfig(registry.oracleSettings(), o), address(this));
    }

    function _oracleConfig(
        BeeefRegistry.OracleSettings memory s,
        OracleArgs memory o
    ) private pure returns (BeeefOracle.Config memory c) {
        c.feedA = o.feedA;
        c.feedB = o.feedB;
        c.stockA = o.stockA;
        c.stockB = o.stockB;
        c.startTime = o.start;
        c.endTime = o.end;
        c.snapshotWindow = s.snapshotWindow;
        c.maxStaleness = s.maxStaleness;
        c.sequencerFeed = s.sequencerFeed;
        c.sequencerGracePeriod = s.sequencerGracePeriod;
        c.applyMultiplier = s.applyMultiplier;
    }

    function title(uint256 roundId, string memory symbolA, string memory symbolB) public pure returns (string memory) {
        return string.concat("beeef #", LibString.toString(roundId), " ", symbolA, " vs ", symbolB);
    }

    function build(Args memory a) public view returns (CreateParams memory) {
        string memory name = string.concat(a.title, ": ", a.side);
        string memory symbol = string.concat("b", a.side, "-", LibString.toString(a.roundId));
        return CreateParams({
            initialSupply: a.supply,
            numTokensToSell: a.supply,
            numeraire: a.numeraire,
            tokenFactory: a.tokenFactory,
            tokenFactoryData: _tokenFactoryData(a.cloneErc20Factory, name, symbol),
            governanceFactory: a.governanceFactory,
            governanceFactoryData: "",
            poolInitializer: a.poolInitializer,
            poolInitializerData: abi.encode(
                InitData({
                    fee: a.fee,
                    tickSpacing: a.tickSpacing,
                    farTick: _startingTick(a.curves),
                    curves: a.curves,
                    // Must be empty: beneficiaries lock the pool and exitLiquidity (migrate) would revert.
                    beneficiaries: new BeneficiaryData[](0),
                    dopplerHook: a.dopplerHook,
                    // BeeefClockHook: abi.encode(uint64 startTime, uint64 lockTime, uint64 floorWad)
                    onInitializationDopplerHookCalldata: a.clock,
                    graduationDopplerHookCalldata: ""
                })
            ),
            liquidityMigrator: a.migrator,
            liquidityMigratorData: abi.encode(a.oracle, a.entryId),
            integrator: a.integrator,
            salt: keccak256(abi.encode(msg.sender, a.roundId, a.entryId))
        });
    }

    function _tokenFactoryData(
        bool clone,
        string memory name,
        string memory symbol
    ) private pure returns (bytes memory) {
        if (clone) {
            // CloneERC20Factory: (name, symbol, yearlyMintRate, vestingDuration, recipients, amounts, tokenURI)
            return abi.encode(name, symbol, uint256(0), uint256(0), new address[](0), new uint256[](0), "");
        }
        // DopplerERC20V1Factory: (name, symbol, schedules, beneficiaries, scheduleIds, amounts, tokenURI,
        //  maxBalanceLimit, balanceLimitEnd, controller, excludedFromBalanceLimit)
        return abi.encode(
            name,
            symbol,
            new VestingSchedule[](0),
            new address[](0),
            new uint256[](0),
            new uint256[](0),
            "",
            uint256(0),
            uint48(0),
            address(0),
            new address[](0)
        );
    }

    /// @dev Lowest curve tick in "asset is token0" orientation. DopplerHookInitializer starts the pool there (and
    /// flips it when the asset is token1), so passing it as farTick makes the entry migratable immediately.
    function _startingTick(Curve[] memory curves) private pure returns (int24 tick) {
        tick = TickMath.MAX_TICK;
        for (uint256 i; i < curves.length; ++i) {
            if (curves[i].tickLower < tick) tick = curves[i].tickLower;
        }
    }
}
