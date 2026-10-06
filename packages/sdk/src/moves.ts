import { WAD } from "./constants.js";

export type Side = "A" | "B";

/** Total-return move in WAD (1e18 = unchanged), as BeeefOracle stores moveA/moveB. */
export function moveWad(start: bigint, end: bigint): bigint {
  if (start <= 0n) throw new Error("start price must be positive");
  return (end * WAD) / start;
}

/** Winner by exact cross multiplication, like BeeefOracle.finalize: endA/startA vs endB/startB. */
export function leader(startA: bigint, endA: bigint, startB: bigint, endB: bigint): Side | "TIE" {
  const lhs = endA * startB;
  const rhs = endB * startA;
  return lhs > rhs ? "A" : rhs > lhs ? "B" : "TIE";
}

/** % move as a display number (e.g. 1.84 for +1.84%). Display only; results use `leader`. */
export function pctMove(start: bigint, end: bigint): number {
  return Number(((end - start) * 1_000_000n) / start) / 10_000;
}

/** "▲ 1.84%" / "▼ 0.35%". Never renders a placeholder: callers must only show it once a start price exists. */
export function formatMove(pct: number): string {
  return `${pct >= 0 ? "▲" : "▼"} ${Math.abs(pct).toFixed(2)}%`;
}
