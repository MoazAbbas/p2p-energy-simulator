import { describe, expect, it } from "vitest";
import type { EngineConfig, EngineEvent } from "../../engine/src/engine";
import { DEFAULT_POPULATION, humanProxy, makePopulation, type Agent } from "../src/agents";
import { DEFAULT_MARKET, simulateDay, type MarketConfig } from "../src/market";
import { mulberry32 } from "../src/rng";
import { syntheticDay } from "../src/synthetic";
import { RealtimeDriver, DEFAULT_TIMING } from "../src/live/driver";
import type { Actor, Ledger, LedgerHourSummary, LedgerParticipant, LedgerSubmitOutcome, SettlementFigures } from "../src/live/ledger";
import { LocalLedger } from "../src/live/localLedger";
import { IntegrityError, LiveSession, scenarioHash, type LiveConfig } from "../src/live/session";

const day = syntheticDay(30.04, 31.24, 7);
const bots = makePopulation({ n: 30, prosumerShare: 0.4, seed: 5, ...DEFAULT_POPULATION });
const human = (): Agent => humanProxy({ id: "HUMAN", pvKwp: 5, m: 0.5 });

function config(over: Partial<LiveConfig> = {}, market: Partial<MarketConfig> = {}): LiveConfig {
  return {
    sessionId: "LIVE1",
    agents: [...bots, human()], // the human is appended, so bot indices (and random draws) match a run without a human
    humanId: "HUMAN",
    day,
    market: { ...DEFAULT_MARKET, collectTrades: true, ...market },
    seed: 77,
    ...over,
  };
}

async function runToEnd(s: LiveSession): Promise<void> {
  while (s.getState().phase !== "finished") await s.advance();
}

/** Steps until the given hour is open and `ticks` rounds of it have been played. */
async function playUntil(s: LiveSession, hour: number, ticks: number): Promise<void> {
  for (;;) {
    const st = s.getState();
    if (st.phase === "trading" && st.hour === hour && st.tick >= ticks && st.ticksPerHour > 0) return;
    await s.advance();
  }
}

describe("planning", () => {
  it("shows the human's forecast and the price band per trading hour", async () => {
    const s = new LiveSession(config(), new LocalLedger("LIVE1"));
    const p = s.plan();
    expect(p.hours).toHaveLength(24);
    expect(p.hours.filter((h) => h.trading).map((h) => h.hour)).toEqual([12, 13, 14, 15, 16, 17]);
    expect(p.hours[12]!.generationWh).toBeGreaterThan(p.hours[12]!.loadWh);
    expect(p.hours[12]!.surplusWh).toBeGreaterThan(0);
    expect(p.hours[3]!.generationWh).toBe(0);
    expect(p.bands).toHaveLength(6);
    expect(p.bands[0]).toEqual({ hour: 12, floor: 100, ceiling: 200 });
  });

  it("uses the outage band in outage hours", () => {
    const s = new LiveSession(config({}, { outage: { hours: [14], ceilingMultiplierPermille: 2000 } }), new LocalLedger("LIVE1"));
    expect(s.plan().bands.find((b) => b.hour === 14)).toEqual({ hour: 14, floor: 1, ceiling: 400 });
    expect(s.plan().hours[14]!.gridUp).toBe(false);
  });

  it("rejects an unusable setup", () => {
    expect(() => new LiveSession(config({ humanId: "NOBODY" }), new LocalLedger("x"))).toThrow(/not one of the agents/);
    expect(() => new LiveSession(config({ agents: [...bots, { ...human(), canBuy: true }] }), new LocalLedger("x"))).toThrow(/seller only/);
    expect(() => new LiveSession(config({ agents: [...bots, human(), human()] }), new LocalLedger("x"))).toThrow(/unique/);
    expect(() => new LiveSession(config({}, { tradingHours: [] }), new LocalLedger("x"))).toThrow(/tradingHours/);
  });
});

describe("a session where the human does nothing", () => {
  it("gives exactly the bots' market of the plain simulator, and the ledger agrees hour by hour", async () => {
    const cfg = config();
    const ledger = new LocalLedger("LIVE1");
    const s = new LiveSession(cfg, ledger);
    await s.start();
    await runToEnd(s);
    const live = s.result();

    const plain = simulateDay(bots, day, { ...DEFAULT_MARKET, collectTrades: true }, mulberry32(cfg.seed));
    for (const h of DEFAULT_MARKET.tradingHours) {
      expect(live.hours[h]!.trades ?? []).toEqual(plain.hours[h]!.trades ?? []);
      expect(live.hours[h]!.tradeCount).toBe(plain.hours[h]!.tradeCount);
    }
    for (const a of plain.agents) expect(live.agents.find((x) => x.id === a.id)).toEqual(a);
    expect(plain.metrics.tradeCount).toBeGreaterThan(20);

    for (const h of DEFAULT_MARKET.tradingHours) {
      expect(await ledger.verifyHour(h)).toEqual({ ok: true, problems: [] });
      const sum = await ledger.getHourSummary(h);
      expect(sum.tradeCount).toBe(live.hours[h]!.tradeCount);
    }
    expect(s.hourSummaries).toHaveLength(6);
    expect(s.hourSummaries[0]!.prevHash).toBe((await ledger.getSession()).scenarioHash);
    expect(s.hourSummaries[1]!.prevHash).toBe(s.hourSummaries[0]!.summaryHash);
  });

  it("walks through the phases in order and keeps a sensible clock", async () => {
    const s = new LiveSession(config(), new LocalLedger("LIVE1"));
    expect(s.getState().phase).toBe("planning");
    await s.start();
    expect(s.getState().phase).toBe("morning");
    const kinds: string[] = [];
    let sawMidHourClock = false;
    while (s.getState().phase !== "finished") {
      const step = await s.advance();
      kinds.push(`${step.kind}:${step.phase}`);
      const st = s.getState();
      if (st.phase === "trading" && st.hour === 12 && st.tick === 6) {
        expect(st.clock).toBe("12:30");
        sawMidHourClock = true;
      }
    }
    expect(sawMidHourClock).toBe(true);
    expect(kinds[0]).toBe("fastForward:morning");
    expect(kinds.filter((k) => k.startsWith("openHour"))).toHaveLength(6);
    expect(kinds.filter((k) => k.startsWith("tick"))).toHaveLength(6 * DEFAULT_MARKET.ticksPerHour);
    expect(kinds.filter((k) => k.startsWith("closeHour"))).toHaveLength(6);
    expect(kinds[kinds.length - 2]).toBe("fastForward:evening");
    expect(kinds[kinds.length - 1]).toBe("settle:finished");
    await expect(s.advance()).rejects.toThrow(/finished/);
  });

  it("records a settlement for every household, matching the ledger's trades", async () => {
    const ledger = new LocalLedger("LIVE1");
    const s = new LiveSession(config(), ledger);
    await s.start();
    await runToEnd(s);
    // 31 participants were registered and all settled; RecordSettlement checks each figure against the trades
    const keys = [...ledger.store.data.keys()].filter((k) => k.includes("settlement"));
    expect(keys).toHaveLength(31);
  });
});

describe("the human trades", () => {
  it("hitting a bid trades at the bid's price, is verified by the ledger, and shows up in the summary", async () => {
    const ledger = new LocalLedger("LIVE1");
    const s = new LiveSession(config(), ledger);
    await s.start();
    await playUntil(s, 12, 3);
    const before = s.getState();
    expect(before.human.availableToSellWh).toBeGreaterThan(0);
    expect(before.book.bids.length).toBeGreaterThan(0);

    const qty = Math.min(1000, before.human.availableToSellWh);
    const r = await s.placeHumanOrder({ price: 100, qtyWh: qty });
    expect(r.accepted).toBe(true);
    expect(r.trades.length).toBeGreaterThan(0);
    for (const t of r.trades) {
      expect(t.sellerId).toBe("HUMAN");
      expect(t.restingSide).toBe("buy");
      expect(t.price).toBeGreaterThanOrEqual(100);
    }
    const sold = r.trades.reduce((a, t) => a + t.qtyWh, 0);
    const st = s.getState();
    expect(st.human.soldWhThisHour).toBe(sold);
    expect(st.human.receivedThisHour).toBe(r.trades.reduce((a, t) => a + t.amount, 0));
    expect(st.human.availableToSellWh).toBe(before.human.availableToSellWh - qty);

    await runToEnd(s);
    const me = s.humanSummary();
    expect(me.soldWh).toBeGreaterThanOrEqual(sold);
    expect(me.received).toBeGreaterThanOrEqual(r.trades.reduce((a, t) => a + t.amount, 0));
    // selling above the export rate must beat always exporting for the energy that was sold
    expect(me.premium).toBeGreaterThan(0);
    for (const h of DEFAULT_MARKET.tradingHours) expect((await ledger.verifyHour(h)).ok).toBe(true);
  });

  it("an ask that nobody meets rests in the book and can be withdrawn", async () => {
    const ledger = new LocalLedger("LIVE1");
    const s = new LiveSession(config(), ledger);
    await s.start();
    await playUntil(s, 12, 2);
    const r = await s.placeHumanOrder({ price: 200, qtyWh: 500 });
    expect(r.accepted).toBe(true);
    expect(r.trades).toEqual([]);
    expect(r.restingWh).toBe(500);
    expect(s.getState().human.openOrders).toEqual([{ orderId: r.orderId, price: 200, remainingWh: 500 }]);

    const c = await s.cancelHumanOrder(r.orderId!);
    expect(c).toEqual({ cancelled: true, cancelledWh: 500 });
    expect(s.getState().human.openOrders).toEqual([]);
    const again = await s.cancelHumanOrder(r.orderId!);
    expect(again.cancelled).toBe(false);
    expect(again.reason).toBe("NOT_OPEN");
    const unknown = await s.cancelHumanOrder("nope");
    expect(unknown.reason).toBe("NOT_FOUND");

    await runToEnd(s);
    for (const h of DEFAULT_MARKET.tradingHours) expect((await ledger.verifyHour(h)).ok).toBe(true);
  });

  it("a resting ask is cancelled when the hour closes, and the energy goes to the utility", async () => {
    const s = new LiveSession(config(), new LocalLedger("LIVE1"));
    await s.start();
    await playUntil(s, 12, 1);
    await s.placeHumanOrder({ price: 200, qtyWh: 400 });
    await runToEnd(s);
    const me = s.humanSummary();
    expect(me.soldWh).toBe(0);
    expect(me.premium).toBe(0); // nothing sold: same as always exporting
  });

  it("refuses bad orders without touching the ledger", async () => {
    const ledger = new LocalLedger("LIVE1");
    const s = new LiveSession(config(), ledger);
    await s.start();
    const early = await s.placeHumanOrder({ price: 150, qtyWh: 100 });
    expect(early).toMatchObject({ accepted: false, reason: "HOUR_CLOSED" });
    await playUntil(s, 12, 1);
    const cap = s.getState().human.availableToSellWh;
    expect(await s.placeHumanOrder({ price: 0, qtyWh: 100 })).toMatchObject({ accepted: false, reason: "INVALID_ORDER" });
    expect(await s.placeHumanOrder({ price: 150, qtyWh: 0 })).toMatchObject({ accepted: false, reason: "INVALID_ORDER" });
    expect(await s.placeHumanOrder({ price: 150.5, qtyWh: 10 })).toMatchObject({ accepted: false, reason: "INVALID_ORDER" });
    expect(await s.placeHumanOrder({ price: 150, qtyWh: cap + 1 })).toMatchObject({ accepted: false, reason: "CAP_EXCEEDED" });
    expect(s.getState().halted).toBeNull();
    expect(s.getState().human.availableToSellWh).toBe(cap);
    await runToEnd(s);
    expect((await ledger.verifyHour(12)).ok).toBe(true);
  });

  it("commands sent at the same time are carried out in the order they were sent", async () => {
    const ledger = new LocalLedger("LIVE1");
    const s = new LiveSession(config(), ledger);
    await s.start();
    await playUntil(s, 12, 4);
    const a = s.advance();
    const o1 = s.placeHumanOrder({ price: 100, qtyWh: 300 });
    const b = s.advance();
    const o2 = s.placeHumanOrder({ price: 200, qtyWh: 200 });
    const c = s.cancelHumanOrder("H12-2");
    const [sa, r1, sb, r2, rc] = await Promise.all([a, o1, b, o2, c]);
    expect(sa.tick).toBe(5);
    expect(sb.tick).toBe(6);
    expect(r1.accepted && r2.accepted).toBe(true);
    expect(r1.orderId).toBe("H12-1");
    expect(r2.orderId).toBe("H12-2");
    expect(rc.cancelled || r2.trades.length > 0).toBe(true); // cancelled if it rested, otherwise it had already traded
    await runToEnd(s);
    expect((await ledger.verifyHour(12)).ok).toBe(true);
  });
});

/** A ledger that can be told to misbehave once. */
class FaultyLedger implements Ledger {
  mode: "none" | "dropLast" | "changePrice" | "throw" | "badSummary" = "none";
  constructor(private readonly inner: LocalLedger) {}
  openSession(a: { scenarioHash: string; participants: LedgerParticipant[] }) {
    return this.inner.openSession(a);
  }
  openHour(h: number, caps: EngineConfig) {
    return this.inner.openHour(h, caps);
  }
  async submit(h: number, events: EngineEvent[], actor: Actor): Promise<LedgerSubmitOutcome> {
    if (this.mode === "throw") throw new Error("peer unreachable");
    if (this.mode === "dropLast" && events.length > 1) {
      this.mode = "none";
      return this.inner.submit(h, events.slice(0, -1), actor);
    }
    const out = await this.inner.submit(h, events, actor);
    if (this.mode === "changePrice" && out.trades.length > 0) {
      this.mode = "none";
      return { ...out, trades: out.trades.map((t, i) => (i === 0 ? { ...t, price: t.price + 1 } : t)) };
    }
    return out;
  }
  async closeHour(h: number): Promise<LedgerHourSummary> {
    const s = await this.inner.closeHour(h);
    return this.mode === "badSummary" ? { ...s, amount: s.amount + 1 } : s;
  }
  closeSession() {
    return this.inner.closeSession();
  }
  recordSettlement(id: string, f: SettlementFigures) {
    return this.inner.recordSettlement(id, f);
  }
}

describe("integrity: the ledger and the shadow engine must agree", () => {
  async function stepUntilError(s: LiveSession): Promise<unknown> {
    try {
      for (let i = 0; i < 500; i++) await s.advance();
    } catch (e) {
      return e;
    }
    return null;
  }

  it.each([
    ["dropLast", /differs from the shadow/],
    ["changePrice", /trades differ/],
    ["throw", /refused or failed/],
    ["badSummary", /hour summary differs/],
  ] as const)("halts when the ledger misbehaves (%s)", async (mode, message) => {
    const ledger = new FaultyLedger(new LocalLedger("LIVE1"));
    const s = new LiveSession(config(), ledger);
    await s.start();
    await playUntil(s, 12, 0);
    ledger.mode = mode;
    const err = await stepUntilError(s);
    expect(err).toBeInstanceOf(IntegrityError);
    expect((err as Error).message).toMatch(message);
    expect(s.getState().phase).toBe("halted");
    expect(s.getState().halted).not.toBeNull();
    await expect(s.advance()).rejects.toThrow(/halted/);
    await expect(s.placeHumanOrder({ price: 150, qtyWh: 10 })).rejects.toThrow(/halted/);
  });
});

describe("scenario hash", () => {
  it("is stored on the ledger and changes when anything about the scenario changes", async () => {
    const ledger = new LocalLedger("LIVE1");
    const cfg = config();
    const s = new LiveSession(cfg, ledger);
    await s.start();
    expect((await ledger.getSession()).scenarioHash).toBe(scenarioHash(cfg));
    expect(scenarioHash(cfg)).toBe(scenarioHash(config()));
    expect(scenarioHash(cfg)).not.toBe(scenarioHash(config({ seed: 78 })));
    expect(scenarioHash(cfg)).not.toBe(scenarioHash(config({ day: syntheticDay(30.04, 31.24, 1) })));
    expect(scenarioHash(cfg)).not.toBe(scenarioHash(config({}, { tariff: { retail: 210, export: 100 } })));
    expect(scenarioHash(cfg)).toMatch(/^[0-9a-f]{64}$/);
  });
});

describe("outage", () => {
  it("plays a day with an outage hour end to end", async () => {
    const ledger = new LocalLedger("LIVE1");
    const s = new LiveSession(config({}, { outage: { hours: [14, 15], ceilingMultiplierPermille: 2000 } }), ledger);
    await s.start();
    await playUntil(s, 14, 1);
    expect(s.getState().gridUp).toBe(false);
    await runToEnd(s);
    const r = s.result();
    expect(r.hours[14]!.gridUp).toBe(false);
    expect(r.hours[14]!.minPrice === null || r.hours[14]!.minPrice! >= 1).toBe(true);
    expect(r.hours[14]!.maxPrice === null || r.hours[14]!.maxPrice! <= 400).toBe(true);
    for (const h of DEFAULT_MARKET.tradingHours) expect((await ledger.verifyHour(h)).ok).toBe(true);
  });
});

describe("real-time driver", () => {
  it("spends the designed time: about 20 s morning, 70 s per trading hour, 20 s evening", async () => {
    const delays: number[] = [];
    const s = new LiveSession(config(), new LocalLedger("LIVE1"));
    await s.start();
    const d = new RealtimeDriver(s, DEFAULT_MARKET.ticksPerHour, DEFAULT_TIMING, async (ms) => void delays.push(ms));
    await d.run();
    expect(s.getState().phase).toBe("finished");
    const total = delays.reduce((a, b) => a + b, 0);
    expect(total).toBeCloseTo(20_000 + 6 * 70_000 + 20_000, 3);
    expect(Math.max(...delays)).toBe(20_000);
  });

  it("speed shortens the waits, pause holds, stop ends the run", async () => {
    const delays: number[] = [];
    const s = new LiveSession(config(), new LocalLedger("LIVE1"));
    await s.start();
    let steps = 0;
    const d = new RealtimeDriver(s, 12, DEFAULT_TIMING, async (ms) => void delays.push(ms), () => {
      steps++;
      if (steps === 5) d.stop();
    });
    d.speed = 4;
    await d.run();
    expect(steps).toBe(5);
    expect(delays[0]).toBe(5_000);
    expect(s.getState().phase).not.toBe("finished");

    d.pause();
    const running = d.run();
    await new Promise((r) => setTimeout(r, 20));
    expect(steps).toBe(5); // held while paused
    d.stop();
    await running;
  });
});
