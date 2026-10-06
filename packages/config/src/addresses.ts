import type { Address } from "viem";

/** Live Robinhood Chain (4663) contracts beeef builds on. Checked on-chain 2026-09-23. */
export const robinhood = {
  airlock: "0xeb7C034704eF8Dcd2D32324c1545f62fB4aD0862",
  dopplerHookInitializer: "0x4e3468951D49f2EEa976eD0D6e75fFCb44a9a544",
  dopplerErc20V1Factory: "0x1B37D3a72082029c44B35B604Ea473617580b69a",
  noOpGovernanceFactory: "0x85f37f74Ef2478A770318bc810177a9835911aD7",
  poolManager: "0x8366a39CC670B4001A1121B8F6A443A643e40951",
  /** Canonical stablecoin on Robinhood Chain (6 decimals). Shown to users as dollars. */
  usdg: "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168",
  dataStreamsVerifierProxy: "0xcE73c8ad08CBDEaCa6078BF0627C8fe0a9a536E7",
} as const satisfies Record<string, Address>;

/** Addresses of the beeef deployment on a given chain. Written by the deploy scripts to deployments/<chainId>.json. */
export interface BeeefDeployment {
  chainId: number;
  startBlock: number;
  factory: Address;
  registry: Address;
  clockHook: Address;
  predictionMigrator: Address;
  oracleImplementation: Address;
  feeSplitterImplementation: Address;
  numeraire: Address;
  airlock: Address;
}
