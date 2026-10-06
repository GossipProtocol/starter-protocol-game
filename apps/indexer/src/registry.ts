import { ponder } from "ponder:registry";
import { stocks } from "ponder:schema";

import { lc } from "./lib";

ponder.on("BeeefRegistry:StockSet", async ({ event, context }) => {
  const { stock, feed, symbol } = event.args;
  await context.db
    .insert(stocks)
    .values({ address: lc(stock), feed: lc(feed), symbol })
    .onConflictDoUpdate({ feed: lc(feed), symbol });
});
