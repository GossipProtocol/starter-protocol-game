// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Robinhood Chain mainnet (4663) addresses, checked on-chain on 2026-09-23.
/// Sources: whetstoneresearch/doppler main `deployments/4663.md`, docs.robinhood.com/chain/contracts,
/// api.robinhood.com/rhj/assets, Chainlink reference data `feeds-robinhood-mainnet.json`.
library RobinhoodAddresses {
    // Doppler (see whetstoneresearch/doppler `deployments/4663.md`; ABI-compatible with the pinned submodule for the
    // calls beeef makes)
    address internal constant AIRLOCK = 0xeb7C034704eF8Dcd2D32324c1545f62fB4aD0862;
    address internal constant DOPPLER_HOOK_INITIALIZER = 0x4e3468951D49f2EEa976eD0D6e75fFCb44a9a544;
    address internal constant DOPPLER_ERC20_V1_FACTORY = 0x1B37D3a72082029c44B35B604Ea473617580b69a;
    address internal constant NO_OP_GOVERNANCE_FACTORY = 0x85f37f74Ef2478A770318bc810177a9835911aD7;
    address internal constant BUNDLER = 0xf45588E8e0B1df9dB9ae7E20eCE5726AE931357c;
    // Uniswap v4 PoolManager used by the initializer (initializer.poolManager())
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    // Canonical stablecoin on Robinhood Chain (6 decimals). No canonical USDC is listed.
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    // Robinhood stock tokens (18 decimals, ERC-8056 uiMultiplier)
    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address internal constant AMD = 0x86923f96303D656E4aa86D9d42D1e57ad2023fdC;
    address internal constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address internal constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address internal constant MSFT = 0xe93237C50D904957Cf27E7B1133b510C669c2e74;

    // Chainlink feed proxies (8 decimals, 0.5% deviation, 24h heartbeat, multiplier already applied)
    address internal constant NVDA_USD_FEED = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;
    address internal constant AMD_USD_FEED = 0x943A29E7ae51A4798823ca9eEd2ed533B2A22C72;
    address internal constant AAPL_USD_FEED = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0;
    address internal constant TSLA_USD_FEED = 0x4A1166a659A55625345e9515b32adECea5547C38;
    address internal constant MSFT_USD_FEED = 0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E;
}
