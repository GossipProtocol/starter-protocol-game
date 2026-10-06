/**
 * Market-hours rules, ported 1:1 from BeeefRoundFactory (isMarketOpen, nextStart). The factory is the source of truth
 * for when rounds may run; this port powers /api/market/session, the keeper's pause/resume and the create flow's
 * "queued for the open" message. All times are unix seconds (UTC).
 */
export interface MarketCalendar {
  /** Seconds from Sunday 00:00 UTC. Wraps when end < start. */
  weeklyCloseStart: number;
  weeklyCloseEnd: number;
  /** UTC day indexes (timestamp / 86400) flagged as holidays. */
  closedDays: ReadonlySet<number>;
}

const DAY = 86_400;
const WEEK = 7 * DAY;

/** Factory defaults: closed Saturday 00:00 UTC to Monday 01:00 UTC. */
export const defaultCalendar: MarketCalendar = { weeklyCloseStart: 6 * DAY, weeklyCloseEnd: DAY + 3600, closedDays: new Set() };

function closeLen(c: MarketCalendar) {
  return c.weeklyCloseEnd > c.weeklyCloseStart
    ? c.weeklyCloseEnd - c.weeklyCloseStart
    : WEEK - c.weeklyCloseStart + c.weeklyCloseEnd;
}

function weekStartOf(t: number) {
  return t - ((Math.floor(t / DAY) + 4) % 7) * DAY - (t % DAY);
}

export function isMarketOpen(start: number, end: number, c: MarketCalendar = defaultCalendar): boolean {
  for (let day = Math.floor(start / DAY); day <= Math.floor(end / DAY); day++) {
    if (c.closedDays.has(day)) return false;
  }
  const ws = weekStartOf(start);
  const len = closeLen(c);
  for (let i = 0; i < 3; i++) {
    if (ws + i * WEEK < WEEK) continue;
    const closeStart = ws + i * WEEK - WEEK + c.weeklyCloseStart;
    if (start < closeStart + len && closeStart < end) return false;
  }
  return true;
}

function nextBoundary(t: number, end: number, c: MarketCalendar): number {
  for (let day = Math.floor(t / DAY); day <= Math.floor(end / DAY); day++) {
    if (c.closedDays.has(day)) return (day + 1) * DAY;
  }
  const ws = weekStartOf(t);
  const len = closeLen(c);
  for (let i = 0; i < 3; i++) {
    if (ws + i * WEEK < WEEK) continue;
    const closeStart = ws + i * WEEK - WEEK + c.weeklyCloseStart;
    if (t < closeStart + len && closeStart < end) return closeStart + len;
  }
  return t + 3600;
}

/** Earliest time >= t at which a round of `duration` (plus the end-snapshot window) fits the session. */
export function nextStart(t: number, duration: number, snapshotWindow: number, c: MarketCalendar = defaultCalendar): number {
  for (let i = 0; i < 32; i++) {
    const end = t + duration + snapshotWindow;
    if (isMarketOpen(t, end, c)) return t;
    t = nextBoundary(t, end, c);
  }
  throw new Error("market closed for the foreseeable future");
}

/** For /api/market/session. "Open" means a 10-minute round started now would fit. */
export function marketSession(now: number, snapshotWindow: number, c: MarketCalendar = defaultCalendar) {
  const open = isMarketOpen(now, now + 600 + snapshotWindow, c);
  return { open, nextOpen: open ? now : nextStart(now, 600, snapshotWindow, c) };
}
