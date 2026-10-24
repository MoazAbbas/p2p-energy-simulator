import { createHash } from "node:crypto";
import { describe, expect, it } from "vitest";
import { DEFAULT_POPULATION, makePopulation } from "../src/agents";
import { DEFAULT_MARKET, simulateDay } from "../src/market";
import { mulberry32 } from "../src/rng";
import { syntheticDay } from "../src/synthetic";

/**
 * Fingerprints of full simulated days, taken before the bot loop was moved into HourMarket.
 * If one of these fails, the bots (or the market runner) no longer behave as they did when the experiment
 * results were produced. Change them only on purpose, and say so when you report results.
 * Field order is ignored; only values count.
 */
const canonical = (v: unknown): string =>
  JSON.stringify(v, (_k, x) =>
    x && typeof x === "object" && !Array.isArray(x) ? Object.fromEntries(Object.entries(x).sort(([a], [b]) => (a < b ? -1 : 1))) : x,
  );
const fingerprint = (v: unknown): string => createHash("sha256").update(canonical(v)).digest("hex");

const cases = [
  { n: 30, p: 0.4, seed: 5, month: 7, outage: false, hash: "97ef65e2f1089ec26a104be05388e7f488666bfca8047490d5cf889e26020fb5" },
  { n: 60, p: 0.2, seed: 9, month: 1, outage: false, hash: "119802e5157e68db858de2aebda9ec485c7c3eef65df45d8e1e234f7f6d158fe" },
  { n: 50, p: 0.7, seed: 3, month: 4, outage: true, hash: "8e90672ba85d514f26c1f3a238f5a26b655ed24f746c60a09ac6f053628beccb" },
  { n: 20, p: 0.05, seed: 1, month: 10, outage: false, hash: "a48456dc16767659a888a05fff2800378cd829e72b5bb5ee2c44d21a550bc235" },
];

describe("market runner regression", () => {
  for (const c of cases) {
    it(`n=${c.n} share=${c.p} seed=${c.seed} month=${c.month}${c.outage ? " with outage" : ""}`, () => {
      const agents = makePopulation({ n: c.n, prosumerShare: c.p, seed: c.seed, ...DEFAULT_POPULATION });
      const cfg = {
        ...DEFAULT_MARKET,
        collectTrades: true,
        recordEvents: true,
        ...(c.outage ? { outage: { hours: [14, 15], ceilingMultiplierPermille: 2000 } } : {}),
      };
      const r = simulateDay(agents, syntheticDay(30.04, 31.24, c.month), cfg, mulberry32(c.seed + 1000));
      expect(r.metrics.tradeCount).toBeGreaterThan(0);
      expect(fingerprint(r)).toBe(c.hash);
    });
  }
});
