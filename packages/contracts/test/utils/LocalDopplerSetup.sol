// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { PoolManager } from "@v4-core/PoolManager.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";

import { Airlock, ModuleState } from "doppler/Airlock.sol";
import { NoOpGovernanceFactory } from "doppler/governance/NoOpGovernanceFactory.sol";
import { DopplerHookInitializer } from "doppler/initializers/DopplerHookInitializer.sol";
import { CloneERC20Factory } from "doppler/tokens/CloneERC20Factory.sol";

import { BeeefRoundFactory } from "src/BeeefRoundFactory.sol";

import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockStockToken } from "test/mocks/MockStockToken.sol";
import { MockV3Aggregator } from "test/mocks/MockV3Aggregator.sol";
import { BeeefRoundHelpers } from "test/utils/BeeefRoundHelpers.sol";

/// @notice Fresh local Doppler deployment (the pinned `lib/doppler` submodule) with mock USDG, feeds and stock tokens.
abstract contract LocalDopplerSetup is BeeefRoundHelpers {
    function setUp() public virtual {
        vm.warp(1_790_000_000); // Monday 14:13 UTC, market open
        address owner = makeAddr("AIRLOCK_OWNER");
        airlock = new Airlock(owner);
        manager = IPoolManager(address(new PoolManager(address(this))));

        initializer = DopplerHookInitializer(payable(_hookFlagsAddress()));
        deployCodeTo(
            "DopplerHookInitializer.sol:DopplerHookInitializer",
            abi.encode(address(airlock), address(manager)),
            address(initializer)
        );
        _whitelist(address(initializer), ModuleState.PoolInitializer);

        tokenFactory = address(new CloneERC20Factory(address(airlock)));
        tokenFactoryKind = BeeefRoundFactory.TokenFactoryKind.CloneERC20;
        _whitelist(tokenFactory, ModuleState.TokenFactory);
        governanceFactory = address(new NoOpGovernanceFactory());
        _whitelist(governanceFactory, ModuleState.GovernanceFactory);

        _deployPredictionModules();

        usd = address(new MockERC20("Global Dollar", "USDG", 6));
        _deployFactory();

        stockA = address(new MockStockToken());
        stockB = address(new MockStockToken());
        feedA = address(new MockV3Aggregator(8, 180e8));
        feedB = address(new MockV3Aggregator(8, 160e8));
        _registerStocks();
    }

    function _fund(address who, uint256 amount) internal override {
        MockERC20(usd).mint(who, amount);
    }

    function _setPrice(address feed, int256 answer) internal override {
        MockV3Aggregator(feed).updateAnswer(answer);
    }

    function _price(address feed) internal view override returns (int256) {
        return MockV3Aggregator(feed).answer();
    }
}
