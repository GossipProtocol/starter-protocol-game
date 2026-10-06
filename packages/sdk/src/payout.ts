import { FEE_UNIT, WAD } from "./constants.js";

/** PredictionMigrator.claim: floor(tokens * totalPot / claimableSupply). */
export function claimAmount(tokens: bigint, totalPot: bigint, claimableSupply: bigint): bigint {
  if (claimableSupply === 0n) return 0n;
  return (tokens * totalPot) / claimableSupply;
}

/**
 * Pool price as numeraire-wei per asset-wei, from a v4 sqrtPriceX96. Returned as a ratio to stay exact.
 * price(token1 per token0) = (sqrtPriceX96 / 2^96)^2.
 */
export function priceFromSqrtX96(sqrtPriceX96: bigint, assetIsToken0: boolean): { num: bigint; den: bigint } {
  const q192 = 2n ** 192n;
  const p = sqrtPriceX96 * sqrtPriceX96;
  return assetIsToken0 ? { num: p, den: q192 } : { num: q192, den: p };
}

export interface QuoteInput {
  usdcIn: bigint;
  lpFeePpm: bigint;
  /** Numeraire-wei per asset-wei at the current tick. */
  price: { num: bigint; den: bigint };
  multiplier: bigint;
}

/**
 * Tokens a buy of `usdcIn` returns after the LP fee and the clock multiplier, ignoring price impact. The beeef curve is
 * near-flat (~22% across the whole supply), so for any realistic bet the error is a fraction of a percent. The
 * API's /quote route can refine it with the on-chain v4 quoter.
 */
export function quoteBuy(q: QuoteInput): { tokensGross: bigint; tokensToBuyer: bigint; withheld: bigint } {
  const net = (q.usdcIn * (FEE_UNIT - q.lpFeePpm)) / FEE_UNIT;
  const tokensGross = (net * q.price.den) / q.price.num;
  const tokensToBuyer = (tokensGross * q.multiplier) / WAD;
  return { tokensGross, tokensToBuyer, withheld: tokensGross - tokensToBuyer };
}

export interface EstimateInput {
  usdcIn: bigint;
  tokensToBuyer: bigint;
  /** Winning-side supply in players' hands before this bet. */
  sideSupply: bigint;
  /** Both sides' USD so far, after LP fees. */
  pot: bigint;
  lpFeePpm: bigint;
}

/** "If NVDA wins you get about X": your share of the pot if nothing else changes. An estimate: the pot keeps growing
 * until the lock, and later bets on your side dilute you less than earlier ones did (they count less). */
export function estimatePayout(e: EstimateInput): bigint {
  const potAfter = e.pot + (e.usdcIn * (FEE_UNIT - e.lpFeePpm)) / FEE_UNIT;
  return claimAmount(e.tokensToBuyer, potAfter, e.sideSupply + e.tokensToBuyer);
}
