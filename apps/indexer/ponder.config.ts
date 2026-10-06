import {
  beeefClockHookAbi,
  beeefFeeSplitterAbi,
  beeefOracleAbi,
  beeefRegistryAbi,
  beeefRoundFactoryAbi,
  predictionMigratorAbi,
} from "@beeef/sdk";
import { createConfig, factory } from "ponder";
import { erc20Abi, getAbiItem } from "viem";

import { deployment } from "./src/deployment";

const chain = deployment.chainId === 4663 ? "robinhood" : "local";
const startBlock = deployment.startBlock;
const roundCreated = getAbiItem({ abi: beeefRoundFactoryAbi, name: "RoundCreated" });

export default createConfig({
  database: process.env.DATABASE_URL
    ? { kind: "postgres", connectionString: process.env.DATABASE_URL }
    : { kind: "pglite" },
  chains: {
    [chain]: {
      id: deployment.chainId,
      rpc: process.env.PONDER_RPC_URL ?? "http://127.0.0.1:8545",
      // Local anvil mines a block per second; mainnet Orbit blocks are ~250ms.
      pollingInterval: 1_000,
    },
  },
  contracts: {
    BeeefRegistry: { chain, abi: beeefRegistryAbi, address: deployment.registry, startBlock },
    BeeefRoundFactory: { chain, abi: beeefRoundFactoryAbi, address: deployment.factory, startBlock },
    BeeefClockHook: { chain, abi: beeefClockHookAbi, address: deployment.clockHook, startBlock },
    PredictionMigrator: { chain, abi: predictionMigratorAbi, address: deployment.predictionMigrator, startBlock },
    BeeefOracle: {
      chain,
      abi: beeefOracleAbi,
      address: factory({ address: deployment.factory, event: roundCreated, parameter: "oracle" }),
      startBlock,
    },
    BeeefFeeSplitter: {
      chain,
      abi: beeefFeeSplitterAbi,
      address: factory({
        address: deployment.factory,
        event: getAbiItem({ abi: beeefRoundFactoryAbi, name: "SeriesCreated" }),
        parameter: "feeSplitter",
      }),
      startBlock,
    },
    // Entry tokens, one source per side (a factory source takes a single parameter). Transfers attribute bets.
    EntryA: {
      chain,
      abi: erc20Abi,
      address: factory({ address: deployment.factory, event: roundCreated, parameter: "entryA" }),
      startBlock,
    },
    EntryB: {
      chain,
      abi: erc20Abi,
      address: factory({ address: deployment.factory, event: roundCreated, parameter: "entryB" }),
      startBlock,
    },
  },
});
