// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console } from "forge-std/Script.sol";

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";

// Dev only: the local fork deploys its own PredictionMigrator (BUSL-1.1, imported from the submodule) so the whole
// stack runs without any live whitelisting. On a live chain, point the factory at the migrator Doppler publishes
// for that chain. Never import Doppler into src/.
import { PredictionMigrator } from "doppler/migrators/PredictionMigrator.sol";

import { BeeefClockHook } from "src/BeeefClockHook.sol";
import { BeeefFeeSplitter } from "src/BeeefFeeSplitter.sol";
import { BeeefOracle } from "src/BeeefOracle.sol";
import { BeeefRegistry } from "src/BeeefRegistry.sol";
import { BeeefRoundFactory } from "src/BeeefRoundFactory.sol";
import { CourseFee } from "src/CourseFee.sol";
import { IAggregatorV3 } from "src/interfaces/IAggregatorV3.sol";
import { Curve } from "src/interfaces/IDoppler.sol";

import { MockV3Aggregator } from "test/mocks/MockV3Aggregator.sol";

/// @notice Deploys beeef onto an anvil fork of Robinhood Chain and writes deployments/local.json.
/// Whitelisting the migrator and registering the hook need the Airlock owner; scripts/local-fork.sh does that with
/// anvil impersonation after this script. Refuses to run anywhere but a local fork while the course fee recipient in
/// `src/CourseFee.sol` is still the placeholder.
contract DeployLocal is Script {
    uint256 constant LOCAL_CHAIN_ID = 31_337;

    error CourseFeeRecipientUnset();

    address constant AIRLOCK = 0xeb7C034704eF8Dcd2D32324c1545f62fB4aD0862;
    address constant INITIALIZER = 0x4e3468951D49f2EEa976eD0D6e75fFCb44a9a544;
    address constant TOKEN_FACTORY = 0x1B37D3a72082029c44B35B604Ea473617580b69a;
    address constant GOV_FACTORY = 0x85f37f74Ef2478A770318bc810177a9835911aD7;
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    struct Deployed {
        address migrator;
        address hook;
        address oracleImpl;
        address splitterImpl;
        address registry;
        address factory;
        address router;
    }

    address[5] internal tokens = [
        0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC,
        0x86923f96303D656E4aa86D9d42D1e57ad2023fdC,
        0x322F0929c4625eD5bAd873c95208D54E1c003b2d,
        0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9,
        0xe93237C50D904957Cf27E7B1133b510C669c2e74
    ];
    address[5] internal realFeeds = [
        0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15,
        0x943A29E7ae51A4798823ca9eEd2ed533B2A22C72,
        0x4A1166a659A55625345e9515b32adECea5547C38,
        0x6B22A786bAa607d76728168703a39Ea9C99f2cD0,
        0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E
    ];
    string[5] internal symbols = ["NVDA", "AMD", "TSLA", "AAPL", "MSFT"];

    function run() external {
        require(block.chainid == LOCAL_CHAIN_ID || CourseFee.configured(), CourseFeeRecipientUnset());
        uint256 startBlock = block.number;
        vm.startBroadcast();
        Deployed memory d = _deployCore(msg.sender);
        address[5] memory usedFeeds = _registerStocks(BeeefRegistry(d.registry));
        // Dev router for bets until the web app's router lands.
        d.router = address(new PoolSwapTest(IPoolManager(POOL_MANAGER)));
        vm.stopBroadcast();
        _write(d, usedFeeds, startBlock);
        console.log("factory", d.factory);
    }

    function _deployCore(address deployer) internal returns (Deployed memory d) {
        d.migrator = address(new PredictionMigrator(AIRLOCK));
        d.hook = address(new BeeefClockHook(INITIALIZER, IPoolManager(POOL_MANAGER), d.migrator));
        d.oracleImpl = address(new BeeefOracle());
        d.splitterImpl = address(new BeeefFeeSplitter());

        Curve[] memory curves = new Curve[](1);
        curves[0] = Curve({ tickLower: -322_376, tickUpper: -320_376, numPositions: 20, shares: 1e18 });
        d.registry = address(
            new BeeefRegistry(
                deployer,
                BeeefRegistry.PoolConfig({ fee: 10_000, tickSpacing: 8, supply: 1_000_000_000 ether, curves: curves }),
                BeeefRegistry.OracleSettings({
                    snapshotWindow: 5 minutes,
                    maxStaleness: 25 hours,
                    sequencerFeed: address(0),
                    sequencerGracePeriod: 0,
                    applyMultiplier: false
                }),
                BeeefRegistry.ClockSettings({ lockWindow: 60, lockBps: 1000, floorWad: 0.1e18 }),
                1e6
            )
        );
        d.factory = address(
            new BeeefRoundFactory(
                deployer,
                BeeefRoundFactory.Modules({
                    airlock: AIRLOCK,
                    poolManager: POOL_MANAGER,
                    poolInitializer: INITIALIZER,
                    migrator: d.migrator,
                    dopplerHook: d.hook,
                    tokenFactory: TOKEN_FACTORY,
                    tokenFactoryKind: BeeefRoundFactory.TokenFactoryKind.DopplerERC20V1,
                    governanceFactory: GOV_FACTORY,
                    numeraire: USDG,
                    oracleImplementation: d.oracleImpl,
                    feeSplitterImplementation: d.splitterImpl
                }),
                BeeefRegistry(d.registry)
            )
        );
    }

    /// @dev On a fork the real Chainlink feeds never update, so every round would tie. With DEV_FEEDS (default on),
    /// each stock gets a mock feed seeded with the real current price; the price service moves them locally.
    function _registerStocks(BeeefRegistry registry) internal returns (address[5] memory usedFeeds) {
        bool devFeeds = vm.envOr("DEV_FEEDS", true);
        for (uint256 i; i < 5; ++i) {
            address feed = realFeeds[i];
            if (devFeeds) {
                (, int256 answer,,,) = IAggregatorV3(realFeeds[i]).latestRoundData();
                feed = address(new MockV3Aggregator(8, answer));
            }
            usedFeeds[i] = feed;
            registry.setStock(tokens[i], feed, symbols[i]);
        }
    }

    function _write(Deployed memory d, address[5] memory usedFeeds, uint256 startBlock) internal {
        string memory f = "feeds";
        for (uint256 i; i < 4; ++i) {
            vm.serializeAddress(f, symbols[i], usedFeeds[i]);
        }
        string memory feedsJson = vm.serializeAddress(f, symbols[4], usedFeeds[4]);
        string memory o = "deployment";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeUint(o, "startBlock", startBlock);
        vm.serializeAddress(o, "factory", d.factory);
        vm.serializeAddress(o, "registry", d.registry);
        vm.serializeAddress(o, "clockHook", d.hook);
        vm.serializeAddress(o, "predictionMigrator", d.migrator);
        vm.serializeAddress(o, "oracleImplementation", d.oracleImpl);
        vm.serializeAddress(o, "feeSplitterImplementation", d.splitterImpl);
        vm.serializeAddress(o, "devRouter", d.router);
        vm.serializeAddress(o, "numeraire", USDG);
        vm.serializeBool(o, "devFeeds", vm.envOr("DEV_FEEDS", true));
        vm.serializeString(o, "feeds", feedsJson);
        string memory json = vm.serializeAddress(o, "airlock", AIRLOCK);
        vm.writeJson(json, "../../deployments/local.json");
    }
}
