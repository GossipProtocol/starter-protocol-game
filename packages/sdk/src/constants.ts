export const WAD = 10n ** 18n;
/** Uniswap v4 LP fee unit: 1_000_000 = 100%. */
export const FEE_UNIT = 1_000_000n;
export const NO_ROUND = 2n ** 256n - 1n;

/** Oracle.Outcome enum, in contract order. */
export const Outcome = {
  Pending: 0,
  WinnerA: 1,
  WinnerB: 2,
  VoidTie: 3,
  VoidStartMissed: 4,
  VoidEndMissed: 5,
} as const;
export type Outcome = (typeof Outcome)[keyof typeof Outcome];

export const isVoidOutcome = (o: Outcome) => o >= Outcome.VoidTie;
