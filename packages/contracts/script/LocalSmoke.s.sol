// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console } from "forge-std/Script.sol";

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";

import { BeeefRoundFactory } from "src/BeeefRoundFactory.sol";

interface IERC20Like {
    function approve(address, uint256) external returns (bool);
}

/// @notice Seeds a local fork with activity for the indexer and UI: a recurring NVDA vs AMD series (10 min rounds),
/// a one-off TSLA vs AAPL, and bets from anvil wallets #1 and #2.
contract LocalSmoke is Script {
    uint256 constant K0 = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 constant K1 = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 constant K2 = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;

    function run() external {
        string memory d = vm.readFile("../../deployments/local.json");
        BeeefRoundFactory factory = BeeefRoundFactory(vm.parseJsonAddress(d, ".factory"));
        PoolSwapTest router = PoolSwapTest(vm.parseJsonAddress(d, ".devRouter"));
        address usd = vm.parseJsonAddress(d, ".numeraire");
        address nvda = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
        address amd = 0x86923f96303D656E4aa86D9d42D1e57ad2023fdC;
        address tsla = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
        address aapl = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;

        BeeefRoundFactory.FeeSplit memory fees;
        fees.recipients = new address[](1);
        fees.recipients[0] = vm.addr(K0);
        fees.bps = new uint16[](1);
        fees.bps[0] = 10_000;

        vm.startBroadcast(K0);
        IERC20Like(usd).approve(address(factory), type(uint256).max);
        (, uint256 r0) =
            factory.createSeries(nvda, amd, 10 minutes, fees, BeeefRoundFactory.SeriesEnd(50, 0), 2e6, 20e6);
        (, uint256 r1) = factory.createOneOff(tsla, aapl, 30 minutes, fees, 2e6);
        vm.stopBroadcast();

        _bet(K1, router, factory, usd, factory.getRound(r0).entryA, 25e6);
        _bet(K2, router, factory, usd, factory.getRound(r0).entryB, 40e6);
        _bet(K1, router, factory, usd, factory.getRound(r1).entryB, 10e6);
        console.log("series round", r0, "one-off round", r1);
    }

    function _bet(
        uint256 key,
        PoolSwapTest router,
        BeeefRoundFactory factory,
        address usd,
        address entry,
        uint256 amt
    ) internal {
        PoolKey memory k = factory.poolKeyOf(entry);
        bool zeroForOne = address(uint160(k.currency0.toId())) == usd;
        vm.startBroadcast(key);
        IERC20Like(usd).approve(address(router), amt);
        router.swap(
            k,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amt),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            ""
        );
        vm.stopBroadcast();
    }
}
