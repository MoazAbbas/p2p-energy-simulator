import { describe, expect, it } from "vitest";
import { runEvents } from "../../engine/src/engine";
import { DEFAULT_POPULATION, humanProxy, makePopulation, type Agent } from "../src/agents";
import { DEFAULT_MARKET, simulateDay, validateMarket, type DayResult, type MarketConfig } from "../src/market";
import type { DayProfile } from "../src/pvgis";
import { mulberry32 } from "../src/rng";

/** Sun from 07:00 to 17:59 at 800 Wh per kWp, 20 C all day (no cooling load), so numbers stay easy to reason about. */
function flatDay(): DayProfile {
  return {
    date: "2020-07-15",
    utcOffsetHours: 2,
    whPerKwp: Array.from({ length: 24 }, (_, h) => (h >= 7 && h <= 17 ? 800 : 0)),
    t2m: Array<number>(24).fill(20),
  };
}

function population(p: number, seed: number, n = 100): Agent[] {
  return makePopulation({ n, prosumerShare: p, seed, ...DEFAULT_POPULATION });
}

function run(p: number, seed: number, cfg: Partial<MarketConfig> = {}, extra: Agent[] = []): DayResult {
  return simulateDay([...population(p, seed), ...extra], flatDay(), { ...DEFAULT_MARKET, ...cfg }, mulberry32(seed + 1000));
}

function mean(values: Array<number | null>): number {
  const v = values.filter((x): x is number => x !== null);
  return v.reduce((a, b) => a + b, 0) / v.length;
}

describe("population", () => {
  it("creates the requested number of prosumers and consumers with unique ids", () => {
    const pop = population(0.3, 7);
    expect(pop).toHaveLength(100);
    expect(pop.filter((a) => a.kind === "prosumer")).toHaveLength(30);
    expect(pop.filter((a) => a.kind === "consumer")).toHaveLength(70);
    expect(new Set(pop.map((a) => a.id)).size).toBe(100);
    for (const a of pop) {
      expect(a.canBuy).toBe(true);
      if (a.kind === "prosumer") expect(a.spec.pvKwp).toBeGreaterThan(0);
      else expect(a.spec.pvKwp).toBe(0);
    }
  });

  it("is reproducible from the seed and differs between seeds", () => {
    expect(population(0.3, 7)).toEqual(population(0.3, 7));
    expect(population(0.3, 7)).not.toEqual(population(0.3, 8));
  });

  it("keeps every random parameter inside its configured range", () => {
    for (const a of population(0.5, 3, 200)) {
      expect(a.buyer.mu).toBeGreaterThanOrEqual(0.3);
      expect(a.buyer.mu).toBeLessThanOrEqual(0.9);
      expect(a.spec.loadScale).toBeGreaterThanOrEqual(0.6);
      expect(a.spec.loadScale).toBeLessThanOrEqual(1.6);
      if (a.kind === "prosumer") {
        const t = DEFAULT_POPULATION.sellerTypes.find((s) => s.name === a.seller.type)!;
        expect(a.seller.m).toBeGreaterThanOrEqual(t.m0Range[0]);
        expect(a.seller.m).toBeLessThanOrEqual(t.m0Range[1]);
      }
    }
  });

  it("rejects invalid configurations", () => {
    const base = { n: 10, prosumerShare: 0.5, seed: 1, ...DEFAULT_POPULATION };
    expect(() => makePopulation({ ...base, n: 0 })).toThrow();
    expect(() => makePopulation({ ...base, prosumerShare: 1.2 })).toThrow();
    expect(() => makePopulation({ ...base, seed: 1.5 })).toThrow();
    expect(() =>
      makePopulation({ ...base, sellerTypes: [{ name: "x", share: 0.5, m0Range: [0, 1], beta: 0.1 }] }),
    ).toThrow(/sum to 1/);
  });
});

describe("market configuration", () => {
  it("rejects invalid settings", () => {
    const ok = DEFAULT_MARKET;
    expect(() => validateMarket(ok)).not.toThrow();
    expect(() => validateMarket({ ...ok, tariff: { retail: 100, export: 200 } })).toThrow();
    expect(() => validateMarket({ ...ok, tariff: { retail: 200, export: 0 } })).toThrow();
    expect(() => validateMarket({ ...ok, ticksPerHour: 0 })).toThrow();
    expect(() => validateMarket({ ...ok, tradingHours: [24] })).toThrow();
    expect(() => validateMarket({ ...ok, outage: { hours: [14], ceilingMultiplierPermille: 500 } })).toThrow();
  });
});

describe("a simulated day keeps the accounting consistent", () => {
  for (const seed of [1, 2, 3]) {
    it(`seed ${seed}`, () => {
      const human = humanProxy({ pvKwp: 5, m: 0 }); // asks the floor, so it trades even in a crowded market
      const res = run(0.3, seed, { collectTrades: true, recordEvents: true }, [human]);
      const { retail, export: exp } = DEFAULT_MARKET.tariff;

      // Energy and money are conserved between buyers and sellers.
      const sold = res.agents.reduce((s, a) => s + a.soldWh, 0);
      const bought = res.agents.reduce((s, a) => s + a.boughtWh, 0);
      const paid = res.agents.reduce((s, a) => s + a.paid, 0);
      const received = res.agents.reduce((s, a) => s + a.received, 0);
      expect(sold).toBe(bought);
      expect(sold).toBe(res.metrics.tradedWh);
      expect(paid).toBe(received);
      expect(paid).toBe(res.metrics.amount);
      expect(res.metrics.tradedWh).toBeGreaterThan(0);

      for (const a of res.agents) {
        expect(a.soldWh).toBeLessThanOrEqual(a.surplusWh);
        expect(a.boughtWh).toBeLessThanOrEqual(a.deficitWh);
        // A trade never leaves anyone worse off than the utility would (up to rounding to whole piastres).
        expect(a.premium).toBeGreaterThanOrEqual(-30);
        if (a.kind === "consumer") expect(a.costA).toBe(a.costB);
      }
      expect(res.metrics.totalGain).toBeGreaterThan(0);

      // The real participant is a seller only.
      const h = res.agents.find((a) => a.id === "HUMAN")!;
      expect(h.boughtWh).toBe(0);
      expect(h.soldWh).toBeGreaterThan(0);

      // Trades stay inside the price band and happen only in trading hours.
      for (const log of res.hours) {
        if (!DEFAULT_MARKET.tradingHours.includes(log.hour)) expect(log.tradeCount).toBe(0);
        for (const t of log.trades ?? []) {
          expect(t.price).toBeGreaterThanOrEqual(exp);
          expect(t.price).toBeLessThanOrEqual(retail);
        }
      }

      // Replaying the recorded orders through a fresh engine gives exactly the same trades.
      for (const log of res.hours) {
        if (log.events === undefined) continue;
        const replay = runEvents(log.engineConfig!, log.events);
        expect(replay.trades).toEqual(log.trades ?? []);
      }
    });
  }

  it("is deterministic for the same seeds", () => {
    expect(JSON.stringify(run(0.3, 5))).toBe(JSON.stringify(run(0.3, 5)));
    expect(JSON.stringify(run(0.3, 5))).not.toBe(JSON.stringify(run(0.3, 6)));
  });

  it("does not modify the agents it is given", () => {
    const pop = population(0.3, 4);
    const before = JSON.stringify(pop);
    simulateDay(pop, flatDay(), DEFAULT_MARKET, mulberry32(1));
    expect(JSON.stringify(pop)).toBe(before);
  });

  it("with no trading hours everyone just uses the utility", () => {
    const res = run(0.3, 2, { tradingHours: [] });
    expect(res.metrics.tradedWh).toBe(0);
    expect(res.metrics.surplusSoldShare).toBeNull();
    for (const a of res.agents) expect(a.costC).toBe(a.costB);
  });
});

describe("what the market does as the prosumer share changes", () => {
  const seeds = [1, 2, 3];
  const at = (p: number) => seeds.map((s) => run(p, s).metrics);

  it("scarce supply sells out at high prices; abundant supply is cheap and mostly unsold", () => {
    const scarce = at(0.02);
    const abundant = at(0.5);
    expect(mean(scarce.map((m) => m.surplusSoldShare))).toBeGreaterThan(mean(abundant.map((m) => m.surplusSoldShare)));
    expect(mean(abundant.map((m) => m.demandCoveredShare))).toBeGreaterThan(mean(scarce.map((m) => m.demandCoveredShare)));
    expect(mean(scarce.map((m) => m.pricePosition))).toBeGreaterThan(mean(abundant.map((m) => m.pricePosition)));
  });

  it("total gain is highest when supply and demand are close, not at the extremes", () => {
    const gain = (p: number) => mean(at(p).map((m) => m.totalGain));
    expect(gain(0.1)).toBeGreaterThan(gain(0.02));
    expect(gain(0.1)).toBeGreaterThan(gain(0.8));
  });

  it("P2P trading reduces utility imports compared with always exporting", () => {
    for (const m of at(0.2)) {
      expect(m.gridImportWh).toBeLessThan(m.gridImportWhB);
      expect(m.gridExportWh).toBeLessThan(m.gridExportWhB);
    }
  });
});

describe("outage hours", () => {
  const outage = { hours: [14], ceilingMultiplierPermille: 2000 };

  it("with scarce supply, prices can exceed the retail tariff and demand goes unserved", () => {
    const res = run(0.02, 1, { outage, collectTrades: true });
    const log = res.hours[14]!;
    expect(log.gridUp).toBe(false);
    expect(log.gridImportWh).toBe(0);
    expect(log.gridExportWh).toBe(0);
    expect(log.unservedWh).toBeGreaterThan(0);
    expect(log.maxPrice!).toBeGreaterThan(DEFAULT_MARKET.tariff.retail);
    expect(log.maxPrice!).toBeLessThanOrEqual(400);
    for (const t of log.trades ?? []) expect(t.price).toBeGreaterThanOrEqual(1);
  });

  it("with abundant supply, unsold surplus is curtailed and prices collapse towards zero", () => {
    const res = run(0.5, 1, { outage });
    const log = res.hours[14]!;
    expect(log.curtailedWh).toBeGreaterThan(0);
    expect(log.maxPrice!).toBeLessThan(DEFAULT_MARKET.tariff.export);
  });

  it("hours without an outage are unaffected by the outage setting", () => {
    const res = run(0.3, 2, { outage });
    expect(res.hours[13]!.gridUp).toBe(true);
    expect(res.hours[14]!.gridUp).toBe(false);
  });
});

describe("the real participant as a fixed strategy", () => {
  const consumersOnly = (extra: Agent[]) =>
    simulateDay([...population(0, 5, 50), ...extra], flatDay(), DEFAULT_MARKET, mulberry32(9));

  it("keeping all surplus means nothing is sold and costs equal always-export", () => {
    const res = consumersOnly([humanProxy({ pvKwp: 5, m: 0.2, holdBackShare: 1 })]);
    const h = res.agents.find((a) => a.id === "HUMAN")!;
    expect(h.soldWh).toBe(0);
    expect(h.costC).toBe(h.costB);
  });

  it("selling to a community of consumers earns more than exporting", () => {
    const res = consumersOnly([humanProxy({ pvKwp: 5, m: 0.5 })]);
    const h = res.agents.find((a) => a.id === "HUMAN")!;
    expect(h.soldWh).toBeGreaterThan(0);
    expect(h.premium).toBeGreaterThan(0);
  });

  it("in a glut of sellers a fixed high ask is priced out, but with scarce supply it sells everything", () => {
    const sold = (p: number, m: number) =>
      run(p, 1, {}, [humanProxy({ pvKwp: 5, m })]).agents.find((a) => a.id === "HUMAN")!.soldWh;
    expect(sold(0.3, 0.5)).toBeLessThan(sold(0.3, 0));
    expect(sold(0.3, 0.5)).toBe(0);
    expect(sold(0.05, 0.5)).toBeGreaterThan(0);
  });

  it("a higher ask never earns less per kWh sold when the human is the only seller", () => {
    const perKwh = (m: number) => {
      const h = consumersOnly([humanProxy({ pvKwp: 5, m })]).agents.find((a) => a.id === "HUMAN")!;
      return h.received / h.soldWh;
    };
    expect(perKwh(1)).toBeGreaterThanOrEqual(perKwh(0));
  });
});
