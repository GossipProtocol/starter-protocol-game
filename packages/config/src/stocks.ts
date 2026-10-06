import type { Address } from "viem";

export type Sector = "chips" | "big-tech" | "auto" | "crypto" | "etf" | "meme";

export interface StockSeed {
  symbol: string;
  name: string;
  token: Address;
  /** Chainlink feed proxy (8 decimals, 0.5% deviation, 24h heartbeat, uiMultiplier already applied). */
  feed: Address;
  sector: Sector;
  feedHeartbeatS: number;
  feedDeviationBps: number;
}

/** Allowlist seed for /admin/pairs and the factory's setStock. Sources: api.robinhood.com/rhj/assets and
 * Chainlink's feeds-robinhood-mainnet.json. Meme coins are not here: Robinhood Chain has no push feeds for them. */
export const stockSeed: StockSeed[] = [
  { symbol: "NVDA", name: "NVIDIA", token: "0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC", feed: "0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15", sector: "chips", feedHeartbeatS: 86400, feedDeviationBps: 50 },
  { symbol: "AMD", name: "AMD", token: "0x86923f96303D656E4aa86D9d42D1e57ad2023fdC", feed: "0x943A29E7ae51A4798823ca9eEd2ed533B2A22C72", sector: "chips", feedHeartbeatS: 86400, feedDeviationBps: 50 },
  { symbol: "TSLA", name: "Tesla", token: "0x322F0929c4625eD5bAd873c95208D54E1c003b2d", feed: "0x4A1166a659A55625345e9515b32adECea5547C38", sector: "auto", feedHeartbeatS: 86400, feedDeviationBps: 50 },
  { symbol: "AAPL", name: "Apple", token: "0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9", feed: "0x6B22A786bAa607d76728168703a39Ea9C99f2cD0", sector: "big-tech", feedHeartbeatS: 86400, feedDeviationBps: 50 },
  { symbol: "MSFT", name: "Microsoft", token: "0xe93237C50D904957Cf27E7B1133b510C669c2e74", feed: "0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E", sector: "big-tech", feedHeartbeatS: 86400, feedDeviationBps: 50 },
];
