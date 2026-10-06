import { defineChain } from "viem";

/** Robinhood Chain mainnet (Arbitrum Orbit L2). */
export const robinhoodChain = defineChain({
  id: 4663,
  name: "Robinhood Chain",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.mainnet.chain.robinhood.com"] } },
  blockExplorers: { default: { name: "Blockscout", url: "https://robinhoodchain.blockscout.com" } },
});

/** Local anvil fork of Robinhood Chain (same chain id is kept by `anvil --fork-url`, we override to 31337). */
export const robinhoodFork = defineChain({
  ...robinhoodChain,
  id: 31337,
  name: "Robinhood Chain (local fork)",
  rpcUrls: { default: { http: ["http://127.0.0.1:8545"] } },
});
