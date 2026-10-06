import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import { type BeeefDeployment, robinhood } from "@beeef/config";
import type { Address } from "viem";

// Addresses come from the deploy scripts' output (deployments/local.json for the anvil fork, deployments/4663.json for
// mainnet). PONDER_RPC_URL points at the matching node.
const path = resolve(process.env.BEEEF_DEPLOYMENT ?? "../../deployments/local.json");

export const deployment = JSON.parse(readFileSync(path, "utf8")) as BeeefDeployment;

const lower = (a: Address) => a.toLowerCase() as Address;

/** Lowercased addresses the handlers compare against event args. */
export const known = {
  factory: lower(deployment.factory),
  migrator: lower(deployment.predictionMigrator),
  poolManager: lower(robinhood.poolManager),
};
