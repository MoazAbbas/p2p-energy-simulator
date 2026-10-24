import { describe, expect, it } from "vitest";
import { RULES_VERSION } from "../src/engine";
import * as L from "../src/logic";
import { FakeStore, SCENARIO_HASH, as } from "./fakeStore";

const OP = "operator";
const ALICE = "x509::alice";
const BOB = "x509::bob";

const participants = JSON.stringify([
  { participantId: "S1", ownerId: ALICE },
  { participantId: "B1", ownerId: BOB },
  { participantId: "B2", ownerId: null },
]);
const caps = JSON.stringify({ sellCapsWh: { S1: 1000 }, buyCapsWh: { B1: 1000, B2: 1000 } });

const sell = (orderId: string, participantId: string, price: number, qtyWh: number) => ({
  type: "submit",
  order: { orderId, participantId, side: "sell", price, qtyWh },
});
const buy = (orderId: string, participantId: string, price: number, qtyWh: number) => ({
  type: "submit",
  order: { orderId, participantId, side: "buy", price, qtyWh },
});

async function started(): Promise<FakeStore> {
  const st = new FakeStore();
  await L.openSession(as(st, OP), "S", RULES_VERSION, SCENARIO_HASH, participants);
  return st;
}
async function withHour(h = 12): Promise<FakeStore> {
  const st = await started();
  await L.openHour(as(st, OP), "S", h, caps);
  return st;
}

describe("opening a session", () => {
  it("stores the session with the operator, scenario hash and registered participants", async () => {
    const st = await started();
    const s = await L.getSession(as(st, "anyone"), "S");
    expect(s).toMatchObject({ status: "open", operatorId: OP, scenarioHash: SCENARIO_HASH, lastClosedHour: -1, lastClosedHash: SCENARIO_HASH });
    expect(s.participants.map((p) => p.participantId)).toEqual(["S1", "B1", "B2"]);
    expect(s.participants[2]!.ownerId).toBeNull();
  });

  it("rejects bad input", async () => {
    const st = new FakeStore();
    const c = as(st, OP);
    await expect(L.openSession(c, "S", "other-rules", SCENARIO_HASH, participants)).rejects.toThrow(/rulesVersion/);
    await expect(L.openSession(c, "S", RULES_VERSION, "ABC", participants)).rejects.toThrow(/scenarioHash/);
    await expect(L.openSession(c, "bad id!", RULES_VERSION, SCENARIO_HASH, participants)).rejects.toThrow(/sessionId/);
    await expect(L.openSession(c, "S", RULES_VERSION, SCENARIO_HASH, "not json")).rejects.toThrow(/valid JSON/);
    await expect(L.openSession(c, "S", RULES_VERSION, SCENARIO_HASH, "[]")).rejects.toThrow(/non-empty/);
    await expect(L.openSession(c, "S", RULES_VERSION, SCENARIO_HASH, JSON.stringify([{ participantId: "A" }, { participantId: "A" }]))).rejects.toThrow(/twice/);
    await expect(L.openSession(c, "S", RULES_VERSION, SCENARIO_HASH, JSON.stringify([{ participantId: "__proto__" }]))).rejects.toThrow(/participantId/);
    expect(st.data.size).toBe(0);
  });

  it("refuses to reuse a session id", async () => {
    const st = await started();
    await expect(L.openSession(as(st, OP), "S", RULES_VERSION, SCENARIO_HASH, participants)).rejects.toThrow(/already exists/);
  });
});

describe("hour lifecycle", () => {
  it("only the operator opens and closes hours; one hour at a time; hours increase", async () => {
    const st = await started();
    await expect(L.openHour(as(st, ALICE), "S", 12, caps)).rejects.toThrow(/only the session operator/);
    await L.openHour(as(st, OP), "S", 12, caps);
    await expect(L.openHour(as(st, OP), "S", 13, caps)).rejects.toThrow(/still open/);
    await expect(L.closeHour(as(st, ALICE), "S", 12)).rejects.toThrow(/only the session operator/);
    await expect(L.closeHour(as(st, OP), "S", 13)).rejects.toThrow(/not the open hour/);
    await L.closeHour(as(st, OP), "S", 12);
    await expect(L.openHour(as(st, OP), "S", 12, caps)).rejects.toThrow(/must increase/);
    await expect(L.openHour(as(st, OP), "S", 11, caps)).rejects.toThrow(/must increase/);
    await L.openHour(as(st, OP), "S", 14, caps);
  });

  it("validates hour numbers and caps", async () => {
    const st = await started();
    await expect(L.openHour(as(st, OP), "S", 24, caps)).rejects.toThrow(/0..23/);
    await expect(L.openHour(as(st, OP), "S", "x", caps)).rejects.toThrow(/0..23/);
    await expect(L.openHour(as(st, OP), "S", 12, JSON.stringify({ sellCapsWh: { NOBODY: 5 }, buyCapsWh: {} }))).rejects.toThrow(/unregistered/);
    await expect(L.openHour(as(st, OP), "S", 12, JSON.stringify({ sellCapsWh: { S1: -5 }, buyCapsWh: {} }))).rejects.toThrow();
    await expect(L.openHour(as(st, OP), "S", 12, "{}")).rejects.toThrow(/caps/);
    await L.openHour(as(st, OP), "S", "12", caps); // digit strings are what Fabric passes
  });

  it("a closed session accepts nothing more", async () => {
    const st = await withHour();
    await expect(L.closeSession(as(st, OP), "S")).rejects.toThrow(/still open/);
    await L.closeHour(as(st, OP), "S", 12);
    await expect(L.closeSession(as(st, ALICE), "S")).rejects.toThrow(/only the session operator/);
    await L.closeSession(as(st, OP), "S");
    await expect(L.openHour(as(st, OP), "S", 13, caps)).rejects.toThrow(/closed/);
    await expect(L.submitOrders(as(st, OP), "S", 12, JSON.stringify([buy("o1", "B1", 100, 10)]))).rejects.toThrow(/closed/);
  });
});

describe("trading", () => {
  it("matches at the resting order's price and stores the trade", async () => {
    const st = await withHour();
    const r1 = await L.submitOrders(as(st, ALICE), "S", 12, JSON.stringify([sell("a1", "S1", 120, 1000)]));
    expect(r1.results).toEqual([{ ok: true, seq: 1, restingWh: 1000, tradeSeqs: [] }]);
    expect(r1.trades).toEqual([]);

    const r2 = await L.submitOrders(as(st, BOB), "S", 12, JSON.stringify([buy("b1", "B1", 150, 600)]));
    expect(r2.results[0]).toMatchObject({ ok: true, restingWh: 0, tradeSeqs: [1] });
    expect(r2.trades).toEqual([
      { sessionId: "S", hour: 12, seq: 1, buyOrderId: "b1", sellOrderId: "a1", buyerId: "B1", sellerId: "S1", qtyWh: 600, price: 120, amount: 72, restingSide: "sell" },
    ]);

    const book = await L.getOrderBook(as(st, "anyone"), "S", 12);
    expect(book.status).toBe("open");
    if (book.status === "open") {
      expect(book.asks).toHaveLength(1);
      expect(book.asks[0]).toMatchObject({ orderId: "a1", remainingWh: 400 });
      expect(book.bids).toHaveLength(0);
    }
    expect(await L.getTradesForHour(as(st, "anyone"), "S", 12)).toHaveLength(1);
  });

  it("records rejected events instead of failing the transaction, and replays them identically", async () => {
    const st = await withHour();
    const r = await L.submitOrders(
      as(st, OP),
      "S",
      12,
      JSON.stringify([sell("a1", "S1", 120, 900), sell("a2", "S1", 120, 900), buy("b1", "B1", 0, 10), { type: "cancel", orderId: "zzz", participantId: "S1" }]),
    );
    expect(r.results.map((x) => x.ok)).toEqual([true, false, false, false]);
    expect(r.results.map((x) => x.reason)).toEqual([undefined, "CAP_EXCEEDED", "INVALID_ORDER", "NOT_FOUND"]);
    expect(r.eventCount).toBe(4);
    // the first order still rests exactly as before
    const book = await L.getOrderBook(as(st, OP), "S", 12);
    if (book.status === "open") expect(book.asks.map((o) => o.orderId)).toEqual(["a1"]);
    // a second batch sees the same state
    const r2 = await L.submitOrders(as(st, OP), "S", 12, JSON.stringify([buy("b2", "B1", 130, 100)]));
    expect(r2.trades[0]).toMatchObject({ sellOrderId: "a1", price: 120, qtyWh: 100 });
  });

  it("a cancel frees the cap and removes the order from the book", async () => {
    const st = await withHour();
    await L.submitOrders(as(st, ALICE), "S", 12, JSON.stringify([sell("a1", "S1", 120, 1000)]));
    const r = await L.submitOrders(as(st, ALICE), "S", 12, JSON.stringify([{ type: "cancel", orderId: "a1", participantId: "S1" }, sell("a2", "S1", 110, 1000)]));
    expect(r.results[0]).toEqual({ ok: true, cancelledWh: 1000 });
    expect(r.results[1]!.ok).toBe(true);
    const book = await L.getOrderBook(as(st, OP), "S", 12);
    if (book.status === "open") expect(book.asks.map((o) => o.orderId)).toEqual(["a2"]);
  });

  it("enforces who may act for whom", async () => {
    const st = await withHour();
    const sub = (caller: string, ev: unknown) => L.submitOrders(as(st, caller), "S", 12, JSON.stringify([ev]));
    await expect(sub(BOB, sell("a1", "S1", 120, 100))).rejects.toThrow(/may not act/);
    await expect(sub("stranger", buy("b1", "B1", 120, 100))).rejects.toThrow(/may not act/);
    await expect(sub(ALICE, { type: "cancel", orderId: "x", participantId: "B1" })).rejects.toThrow(/may not act/);
    await expect(sub(OP, buy("b1", "NOBODY", 120, 100))).rejects.toThrow(/not registered/);
    await expect(sub(BOB, buy("b2", "B2", 120, 100))).rejects.toThrow(/may not act/); // B2 has no owner: operator only
    await sub(OP, buy("b2", "B2", 120, 100)); // the operator may act for any participant (bots)
    await sub(ALICE, sell("a1", "S1", 120, 100));
  });

  it("is all-or-nothing: one unauthorized event in a batch changes nothing", async () => {
    const st = await withHour();
    const before = st.snapshot();
    await expect(L.submitOrders(as(st, ALICE), "S", 12, JSON.stringify([sell("a1", "S1", 120, 100), buy("b1", "B1", 120, 100)]))).rejects.toThrow(/may not act/);
    expect(st.snapshot()).toBe(before);
  });

  it("rejects malformed batches", async () => {
    const st = await withHour();
    const sub = (events: string) => L.submitOrders(as(st, OP), "S", 12, events);
    await expect(sub("nope")).rejects.toThrow(/valid JSON/);
    await expect(sub("[]")).rejects.toThrow(/non-empty/);
    await expect(sub("{}")).rejects.toThrow(/non-empty/);
    await expect(sub(JSON.stringify([{ type: "close" }]))).rejects.toThrow(/event type/);
    await expect(sub(JSON.stringify([null]))).rejects.toThrow(/object/);
    await expect(sub(JSON.stringify([{ type: "submit" }]))).rejects.toThrow(/order/);
    await expect(sub(JSON.stringify([buy("bad id", "B1", 100, 1)]))).rejects.toThrow(/orderId/);
    const many = Array.from({ length: L.MAX_EVENTS_PER_BATCH + 1 }, (_, i) => buy(`o${i}`, "B1", 100, 1));
    await expect(sub(JSON.stringify(many))).rejects.toThrow(/at most/);
    await expect(L.submitOrders(as(st, OP), "S", 13, JSON.stringify([buy("o1", "B1", 100, 1)]))).rejects.toThrow(/not the open hour/);
  });

  it("normalises extra fields away so stored events are identical on every peer", async () => {
    const st = await withHour();
    const ev = { type: "submit", extra: 1, order: { qtyWh: 10, price: 100, side: "buy", participantId: "B1", orderId: "o1", junk: true } };
    await L.submitOrders(as(st, OP), "S", 12, JSON.stringify([ev]));
    const log = await L.getEventLog(as(st, OP), "S", 12);
    expect(JSON.stringify(log)).toBe('[{"type":"submit","order":{"orderId":"o1","participantId":"B1","side":"buy","price":100,"qtyWh":10}}]');
  });
});

async function playTwoHours(): Promise<FakeStore> {
  const st = await started();
  await L.openHour(as(st, OP), "S", 12, caps);
  await L.submitOrders(as(st, ALICE), "S", 12, JSON.stringify([sell("a1", "S1", 120, 1000)]));
  await L.submitOrders(as(st, BOB), "S", 12, JSON.stringify([buy("b1", "B1", 150, 600)]));
  await L.submitOrders(as(st, OP), "S", 12, JSON.stringify([buy("b2", "B2", 110, 600)]));
  await L.closeHour(as(st, OP), "S", 12);
  await L.openHour(as(st, OP), "S", 13, caps);
  await L.submitOrders(as(st, BOB), "S", 13, JSON.stringify([buy("b1", "B1", 140, 300)]));
  await L.submitOrders(as(st, ALICE), "S", 13, JSON.stringify([sell("a1", "S1", 100, 300)]));
  await L.closeHour(as(st, OP), "S", 13);
  return st;
}

describe("closing an hour", () => {
  it("writes a summary of the hour and cancels what is left", async () => {
    const st = await playTwoHours();
    const s12 = await L.getHourSummary(as(st, OP), "S", 12);
    expect(s12).toMatchObject({ hour: 12, eventCount: 3, tradeCount: 1, volumeWh: 600, amount: 72, cancelledOrders: 2, cancelledWh: 400 + 600 });
    const book = await L.getOrderBook(as(st, OP), "S", 12);
    expect(book).toMatchObject({ status: "closed", bids: [], asks: [] });
    // resting buy at 140 met the later ask at 100: the resting (buy) price 140 is the trade price
    const t13 = await L.getTradesForHour(as(st, OP), "S", 13);
    expect(t13).toHaveLength(1);
    expect(t13[0]).toMatchObject({ price: 140, qtyWh: 300, amount: 42, restingSide: "buy" });
  });

  it("chains each hour's hash to the one before, starting from the scenario hash", async () => {
    const st = await playTwoHours();
    const s12 = await L.getHourSummary(as(st, OP), "S", 12);
    const s13 = await L.getHourSummary(as(st, OP), "S", 13);
    expect(s12.prevHash).toBe(SCENARIO_HASH);
    expect(s13.prevHash).toBe(s12.summaryHash);
    expect((await L.getSession(as(st, OP), "S")).lastClosedHash).toBe(s13.summaryHash);
    expect(s12.summaryHash).toMatch(/^[0-9a-f]{64}$/);
    expect(s12.summaryHash).not.toBe(s13.summaryHash);
    expect(await L.verifyHour(as(st, OP), "S", 12)).toEqual({ ok: true, problems: [] });
    expect(await L.verifyHour(as(st, OP), "S", 13)).toEqual({ ok: true, problems: [] });
  });

  it("the same inputs always give the same hashes", async () => {
    const a = await L.getHourSummary(as(await playTwoHours(), OP), "S", 13);
    const b = await L.getHourSummary(as(await playTwoHours(), OP), "S", 13);
    expect(a.summaryHash).toBe(b.summaryHash);
  });

  it("detects tampering with stored events, trades or the summary", async () => {
    const hourKey = (st: FakeStore) => st.key("hour", ["S", "12"]);

    // 1. an order removed from the stored event log
    let st = await playTwoHours();
    let rec = JSON.parse(st.data.get(hourKey(st))!);
    rec.events.splice(1, 1);
    st.data.set(hourKey(st), JSON.stringify(rec));
    let v = await L.verifyHour(as(st, OP), "S", 12);
    expect(v.ok).toBe(false);
    expect(v.problems.join(" ")).toMatch(/eventsHash/);

    // 2. a price edited in the stored event log
    st = await playTwoHours();
    rec = JSON.parse(st.data.get(hourKey(st))!);
    rec.events[0].order.price = 1;
    st.data.set(hourKey(st), JSON.stringify(rec));
    expect((await L.verifyHour(as(st, OP), "S", 12)).ok).toBe(false);

    // 3. a trade record edited
    st = await playTwoHours();
    const tradeKey = st.key("trade", ["S", "12", "000001"]);
    const t = JSON.parse(st.data.get(tradeKey)!);
    t.amount += 1;
    st.data.set(tradeKey, JSON.stringify(t));
    v = await L.verifyHour(as(st, OP), "S", 12);
    expect(v.ok).toBe(false);
    expect(v.problems.join(" ")).toMatch(/trade records/);

    // 4. the summary edited
    st = await playTwoHours();
    const sumKey = st.key("summary", ["S", "12"]);
    const s = JSON.parse(st.data.get(sumKey)!);
    s.amount += 1;
    st.data.set(sumKey, JSON.stringify(s));
    v = await L.verifyHour(as(st, OP), "S", 12);
    expect(v.ok).toBe(false);
    expect(v.problems.join(" ")).toMatch(/summaryHash/);
  });

  it("the next hour's prevHash exposes a rewritten earlier summary", async () => {
    const st = await playTwoHours();
    const sumKey = st.key("summary", ["S", "12"]);
    const s12 = JSON.parse(st.data.get(sumKey)!);
    const s13 = await L.getHourSummary(as(st, OP), "S", 13);
    // an attacker who rewrites hour 12 and recomputes its hash still cannot match hour 13's prevHash
    const forged = { ...s12, amount: s12.amount + 100 };
    const { summaryHash: _drop, ...body } = forged;
    forged.summaryHash = L.sha256(JSON.stringify(body));
    st.data.set(sumKey, JSON.stringify(forged));
    expect(forged.summaryHash).not.toBe(s13.prevHash);
  });
});

describe("settlement", () => {
  const good = { boughtWh: 600, soldWh: 0, paid: 72 + 0, received: 0, costA: 1000, costB: 900, costC: 850 };

  async function closed(): Promise<FakeStore> {
    const st = await started();
    await L.openHour(as(st, OP), "S", 12, caps);
    await L.submitOrders(as(st, ALICE), "S", 12, JSON.stringify([sell("a1", "S1", 120, 1000)]));
    await L.submitOrders(as(st, BOB), "S", 12, JSON.stringify([buy("b1", "B1", 150, 600)]));
    await L.closeHour(as(st, OP), "S", 12);
    await L.closeSession(as(st, OP), "S");
    return st;
  }

  it("stores a settlement whose market figures match the ledger", async () => {
    const st = await closed();
    const s = await L.recordSettlement(as(st, OP), "S", "B1", JSON.stringify(good));
    expect(s).toMatchObject({ participantId: "B1", boughtWh: 600, paid: 72, premium: 50 });
    const seller = await L.recordSettlement(as(st, OP), "S", "S1", JSON.stringify({ boughtWh: 0, soldWh: 600, paid: 0, received: 72, costA: 0, costB: 10, costC: 20 }));
    expect(seller.premium).toBe(-10);
  });

  it("rejects figures that disagree with the ledger", async () => {
    const st = await closed();
    for (const bad of [{ ...good, paid: 71 }, { ...good, boughtWh: 601 }, { ...good, soldWh: 5 }, { ...good, received: 1 }]) {
      await expect(L.recordSettlement(as(st, OP), "S", "B1", JSON.stringify(bad))).rejects.toThrow(/ledger has/);
    }
  });

  it("allows one settlement per participant, only by the operator, only after the session is closed", async () => {
    const st = await closed();
    await expect(L.recordSettlement(as(st, ALICE), "S", "B1", JSON.stringify(good))).rejects.toThrow(/only the session operator/);
    await expect(L.recordSettlement(as(st, OP), "S", "NOBODY", JSON.stringify(good))).rejects.toThrow(/not registered/);
    await L.recordSettlement(as(st, OP), "S", "B1", JSON.stringify(good));
    await expect(L.recordSettlement(as(st, OP), "S", "B1", JSON.stringify(good))).rejects.toThrow(/already recorded/);
    await expect(L.recordSettlement(as(st, OP), "S", "B2", JSON.stringify({ ...good, boughtWh: 0, paid: 0, costA: 1.5 }))).rejects.toThrow(/integer/);
    await expect(L.recordSettlement(as(st, OP), "S", "B2", JSON.stringify({ ...good, boughtWh: -1 }))).rejects.toThrow(/non-negative/);

    const open = await withHour();
    await expect(L.recordSettlement(as(open, OP), "S", "B1", JSON.stringify(good))).rejects.toThrow(/close the session/);
  });

  it("only counts the trades of its own session", async () => {
    const st = await closed();
    await L.openSession(as(st, OP), "S2", RULES_VERSION, SCENARIO_HASH, participants);
    await L.openHour(as(st, OP), "S2", 12, caps);
    await L.submitOrders(as(st, ALICE), "S2", 12, JSON.stringify([sell("a1", "S1", 120, 1000)]));
    await L.submitOrders(as(st, BOB), "S2", 12, JSON.stringify([buy("b1", "B1", 150, 1000)]));
    await L.closeHour(as(st, OP), "S2", 12);
    await L.closeSession(as(st, OP), "S2");
    await L.recordSettlement(as(st, OP), "S", "B1", JSON.stringify(good)); // still 600 Wh, not 1600
  });

  it("a session id that is a prefix of another does not see its trades", async () => {
    const st = await closed(); // session "S", 1 trade
    await L.openSession(as(st, OP), "SS", RULES_VERSION, SCENARIO_HASH, participants);
    await L.openHour(as(st, OP), "SS", 12, caps);
    await L.submitOrders(as(st, ALICE), "SS", 12, JSON.stringify([sell("a1", "S1", 120, 1000)]));
    await L.submitOrders(as(st, BOB), "SS", 12, JSON.stringify([buy("b1", "B1", 150, 1000)]));
    expect(await L.getTradesForHour(as(st, OP), "S", 12)).toHaveLength(1);
    expect(await L.getTradesForHour(as(st, OP), "SS", 12)).toHaveLength(1);
    await L.recordSettlement(as(st, OP), "S", "B1", JSON.stringify(good));
  });
});
