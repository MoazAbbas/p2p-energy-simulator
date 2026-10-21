import { describe, expect, it } from "vitest";
import {
  Engine,
  MAX_PRICE,
  MAX_QTY_WH,
  runEvents,
  tradeAmount,
  type EngineConfig,
  type EngineEvent,
  type OrderInput,
  type Side,
} from "../src/engine";

const cfg: EngineConfig = {
  sellCapsWh: { S1: 10000, S2: 10000, S3: 10000, P: 5000 },
  buyCapsWh: { B1: 10000, B2: 10000, P: 5000 },
};

function ord(orderId: string, participantId: string, side: Side, price: number, qtyWh: number): OrderInput {
  return { orderId, participantId, side, price, qtyWh };
}

function ok<T extends { ok: boolean }>(r: T): Extract<T, { ok: true }> {
  expect(r.ok).toBe(true);
  return r as Extract<T, { ok: true }>;
}

describe("matching: price and quantity", () => {
  it("incoming buy hits a resting ask and trades at the ask price", () => {
    const e = new Engine(cfg);
    ok(e.submit(ord("o1", "S1", "sell", 100, 5000)));
    const r = ok(e.submit(ord("o2", "B1", "buy", 120, 3000)));
    expect(r.trades).toEqual([
      {
        seq: 1,
        buyOrderId: "o2",
        sellOrderId: "o1",
        buyerId: "B1",
        sellerId: "S1",
        qtyWh: 3000,
        price: 100,
        amount: 300,
        restingSide: "sell",
      },
    ]);
    expect(r.restingWh).toBe(0);
    expect(e.getBook().asks.map((o) => [o.orderId, o.remainingWh])).toEqual([["o1", 2000]]);
  });

  it("incoming sell hits a resting bid and trades at the bid price", () => {
    const e = new Engine(cfg);
    ok(e.submit(ord("o1", "B1", "buy", 120, 4000)));
    const r = ok(e.submit(ord("o2", "S1", "sell", 100, 1500)));
    expect(r.trades).toHaveLength(1);
    expect(r.trades[0]).toMatchObject({ price: 120, qtyWh: 1500, amount: 180, restingSide: "buy" });
  });

  it("does not trade when prices do not cross; both orders rest", () => {
    const e = new Engine(cfg);
    ok(e.submit(ord("o1", "S1", "sell", 100, 1000)));
    const r = ok(e.submit(ord("o2", "B1", "buy", 99, 1000)));
    expect(r.trades).toEqual([]);
    expect(r.restingWh).toBe(1000);
    const book = e.getBook();
    expect(book.asks).toHaveLength(1);
    expect(book.bids).toHaveLength(1);
  });

  it("trades when bid equals ask", () => {
    const e = new Engine(cfg);
    ok(e.submit(ord("o1", "S1", "sell", 100, 1000)));
    const r = ok(e.submit(ord("o2", "B1", "buy", 100, 1000)));
    expect(r.trades).toHaveLength(1);
    expect(r.trades[0]).toMatchObject({ price: 100, amount: 100 });
  });

  it("walks several price levels, best price first, and rests the remainder", () => {
    const e = new Engine(cfg);
    ok(e.submit(ord("a1", "S1", "sell", 100, 1000)));
    ok(e.submit(ord("a2", "S2", "sell", 110, 1000)));
    ok(e.submit(ord("a3", "S3", "sell", 120, 1000)));
    const r = ok(e.submit(ord("b1", "B1", "buy", 115, 2500)));
    expect(r.trades.map((t) => [t.sellOrderId, t.qtyWh, t.price, t.amount])).toEqual([
      ["a1", 1000, 100, 100],
      ["a2", 1000, 110, 110],
    ]);
    expect(r.restingWh).toBe(500);
    const book = e.getBook();
    expect(book.asks.map((o) => o.orderId)).toEqual(["a3"]);
    expect(book.bids.map((o) => [o.orderId, o.price, o.remainingWh])).toEqual([["b1", 115, 500]]);
    const s = e.summary();
    expect(s.volumeWh).toBe(2000);
    expect(s.amount).toBe(210);
  });

  it("insufficient supply: the buyer gets what exists, the rest rests unmatched", () => {
    const e = new Engine(cfg);
    ok(e.submit(ord("a1", "S1", "sell", 100, 800)));
    const r = ok(e.submit(ord("b1", "B1", "buy", 130, 3000)));
    expect(r.trades).toHaveLength(1);
    expect(r.trades[0]!.qtyWh).toBe(800);
    expect(r.restingWh).toBe(2200);
  });
});

describe("priority", () => {
  it("equal price: the earlier ask is filled first", () => {
    const e = new Engine(cfg);
    ok(e.submit(ord("o1", "S1", "sell", 100, 1000)));
    ok(e.submit(ord("o2", "S2", "sell", 100, 1000)));
    const r = ok(e.submit(ord("b", "B1", "buy", 100, 1500)));
    expect(r.trades.map((t) => [t.sellOrderId, t.qtyWh])).toEqual([
      ["o1", 1000],
      ["o2", 500],
    ]);
  });

  it("equal price: the earlier bid is filled first", () => {
    const e = new Engine(cfg);
    ok(e.submit(ord("o1", "B1", "buy", 100, 1000)));
    ok(e.submit(ord("o2", "B2", "buy", 100, 1000)));
    const r = ok(e.submit(ord("s", "S1", "sell", 90, 1500)));
    expect(r.trades.map((t) => [t.buyOrderId, t.qtyWh, t.price])).toEqual([
      ["o1", 1000, 100],
      ["o2", 500, 100],
    ]);
  });

  it("price beats time: a later, cheaper ask is filled before an earlier, dearer one", () => {
    const e = new Engine(cfg);
    ok(e.submit(ord("early", "S1", "sell", 110, 1000)));
    ok(e.submit(ord("late", "S2", "sell", 100, 1000)));
    const r = ok(e.submit(ord("b", "B1", "buy", 120, 1000)));
    expect(r.trades.map((t) => [t.sellOrderId, t.price])).toEqual([["late", 100]]);
  });
});

describe("self-trade prevention", () => {
  it("skips the participant's own resting order and matches the next one", () => {
    const e = new Engine(cfg);
    ok(e.submit(ord("own", "P", "sell", 100, 1000)));
    ok(e.submit(ord("other", "S2", "sell", 105, 1000)));
    const r = ok(e.submit(ord("b", "P", "buy", 110, 1000)));
    expect(r.trades.map((t) => [t.sellOrderId, t.sellerId, t.price])).toEqual([["other", "S2", 105]]);
    expect(e.getBook().asks.map((o) => o.orderId)).toEqual(["own"]);
  });

  it("with no other counterparty, the bid rests next to the participant's own ask", () => {
    const e = new Engine(cfg);
    ok(e.submit(ord("own", "P", "sell", 100, 1000)));
    const r = ok(e.submit(ord("b", "P", "buy", 110, 1000)));
    expect(r.trades).toEqual([]);
    expect(r.restingWh).toBe(1000);
  });
});

describe("validation", () => {
  const bad: Array<[string, unknown]> = [
    ["negative quantity", ord("x", "S1", "sell", 100, -5)],
    ["zero quantity", ord("x", "S1", "sell", 100, 0)],
    ["fractional quantity", ord("x", "S1", "sell", 100, 1.5)],
    ["NaN quantity", ord("x", "S1", "sell", 100, NaN)],
    ["Infinity quantity", ord("x", "S1", "sell", 100, Infinity)],
    ["quantity over the maximum", ord("x", "S1", "sell", 100, MAX_QTY_WH + 1)],
    ["string quantity", { ...ord("x", "S1", "sell", 100, 10), qtyWh: "10" }],
    ["zero price", ord("x", "S1", "sell", 0, 10)],
    ["negative price", ord("x", "S1", "sell", -1, 10)],
    ["fractional price", ord("x", "S1", "sell", 2.5, 10)],
    ["price over the maximum", ord("x", "S1", "sell", MAX_PRICE + 1, 10)],
    ["unknown side", { ...ord("x", "S1", "sell", 100, 10), side: "hold" }],
    ["empty orderId", ord("", "S1", "sell", 100, 10)],
    ["empty participantId", ord("x", "", "sell", 100, 10)],
    ["null order", null],
  ];
  for (const [name, input] of bad) {
    it(`rejects ${name}`, () => {
      const e = new Engine(cfg);
      const r = e.submit(input as OrderInput);
      expect(r.ok).toBe(false);
      if (!r.ok) expect(r.reason).toBe("INVALID_ORDER");
      expect(e.getBook()).toEqual({ bids: [], asks: [] });
    });
  }

  it("rejects a duplicate orderId", () => {
    const e = new Engine(cfg);
    ok(e.submit(ord("o1", "S1", "sell", 100, 1000)));
    const r = e.submit(ord("o1", "S2", "sell", 100, 1000));
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.reason).toBe("DUPLICATE_ORDER_ID");
  });

  it("rejects an invalid cap in the config", () => {
    expect(() => new Engine({ sellCapsWh: { S1: -1 }, buyCapsWh: {} })).toThrow();
    expect(() => new Engine({ sellCapsWh: { S1: 1.5 }, buyCapsWh: {} })).toThrow();
  });
});

describe("energy caps", () => {
  it("rejects selling more than the unsold surplus, and cancelling frees it", () => {
    const e = new Engine({ sellCapsWh: { S1: 5000 }, buyCapsWh: {} });
    ok(e.submit(ord("o1", "S1", "sell", 100, 3000)));
    const r = e.submit(ord("o2", "S1", "sell", 100, 3000));
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.reason).toBe("CAP_EXCEEDED");
    expect(ok(e.cancel("o1", "S1")).cancelledWh).toBe(3000);
    ok(e.submit(ord("o3", "S1", "sell", 100, 3000)));
  });

  it("energy already traded still counts against the cap", () => {
    const e = new Engine({ sellCapsWh: { S1: 5000 }, buyCapsWh: { B1: 10000 } });
    ok(e.submit(ord("a", "S1", "sell", 100, 3000)));
    ok(e.submit(ord("b", "B1", "buy", 100, 3000)));
    expect(e.availableToSell("S1")).toBe(2000);
    const tooMuch = e.submit(ord("c", "S1", "sell", 100, 2500));
    expect(tooMuch.ok).toBe(false);
    ok(e.submit(ord("d", "S1", "sell", 100, 2000)));
  });

  it("a participant without a cap cannot trade that side", () => {
    const e = new Engine({ sellCapsWh: { S1: 5000 }, buyCapsWh: {} });
    const noSell = e.submit(ord("x", "X", "sell", 100, 10));
    const noBuy = e.submit(ord("y", "S1", "buy", 100, 10));
    expect(noSell.ok).toBe(false);
    expect(noBuy.ok).toBe(false);
    if (!noSell.ok) expect(noSell.reason).toBe("CAP_EXCEEDED");
    if (!noBuy.ok) expect(noBuy.reason).toBe("CAP_EXCEEDED");
  });

  it("buy and sell caps are tracked separately", () => {
    const e = new Engine(cfg);
    ok(e.submit(ord("s", "P", "sell", 100, 5000)));
    expect(e.availableToBuy("P")).toBe(5000);
  });
});

describe("cancel", () => {
  it("reports unknown, foreign and no-longer-open orders", () => {
    const e = new Engine(cfg);
    ok(e.submit(ord("o1", "S1", "sell", 100, 1000)));
    ok(e.submit(ord("o2", "B1", "buy", 100, 1000))); // fills o1 completely
    const unknown = e.cancel("nope", "S1");
    const foreign = e.cancel("o1", "S2");
    const filled = e.cancel("o1", "S1");
    expect(unknown.ok === false && unknown.reason).toBe("NOT_FOUND");
    expect(foreign.ok === false && foreign.reason).toBe("NOT_OWNER");
    expect(filled.ok === false && filled.reason).toBe("NOT_OPEN");
  });

  it("cancelling a partly filled order cancels only the remainder", () => {
    const e = new Engine(cfg);
    ok(e.submit(ord("o1", "S1", "sell", 100, 3000)));
    ok(e.submit(ord("o2", "B1", "buy", 100, 1000)));
    expect(ok(e.cancel("o1", "S1")).cancelledWh).toBe(2000);
    const again = e.cancel("o1", "S1");
    expect(again.ok === false && again.reason).toBe("NOT_OPEN");
  });
});

describe("closing the hour", () => {
  it("cancels open orders in sequence order and rejects anything afterwards", () => {
    const e = new Engine(cfg);
    ok(e.submit(ord("o1", "S1", "sell", 100, 1000)));
    ok(e.submit(ord("o2", "B1", "buy", 50, 500)));
    const closed = e.closeHour();
    expect(closed.cancelled).toEqual([
      { orderId: "o1", participantId: "S1", side: "sell", remainingWh: 1000 },
      { orderId: "o2", participantId: "B1", side: "buy", remainingWh: 500 },
    ]);
    expect(e.getBook()).toEqual({ bids: [], asks: [] });
    const s = e.submit(ord("o3", "S1", "sell", 100, 10));
    const c = e.cancel("o1", "S1");
    expect(s.ok === false && s.reason).toBe("HOUR_CLOSED");
    expect(c.ok === false && c.reason).toBe("HOUR_CLOSED");
  });
});

describe("money", () => {
  it("rounds half up to whole piastres", () => {
    expect(tradeAmount(1, 500)).toBe(1); // 0.5 -> 1
    expect(tradeAmount(1, 499)).toBe(0); // 0.499 -> 0
    expect(tradeAmount(3, 500)).toBe(2); // 1.5 -> 2
    expect(tradeAmount(1000, 123)).toBe(123);
    expect(tradeAmount(2500, 100)).toBe(250);
  });

  it("buyer pays exactly what the seller receives", () => {
    const e = new Engine(cfg);
    ok(e.submit(ord("a", "S1", "sell", 137, 1234)));
    ok(e.submit(ord("b", "B1", "buy", 200, 1234)));
    const s = e.summary();
    expect(s.perParticipant.S1!.received).toBe(s.perParticipant.B1!.paid);
    expect(s.amount).toBe(tradeAmount(1234, 137));
  });
});

describe("golden scenario (the chaincode must later reproduce this exactly)", () => {
  const golden: EngineConfig = {
    sellCapsWh: { S1: 5000, S2: 5000, S3: 5000 },
    buyCapsWh: { B1: 5000, B2: 5000 },
  };
  const events: EngineEvent[] = [
    { type: "submit", order: ord("o1", "S1", "sell", 100, 2000) },
    { type: "submit", order: ord("o2", "S2", "sell", 100, 1000) },
    { type: "submit", order: ord("o3", "S3", "sell", 90, 1500) },
    { type: "submit", order: ord("o4", "B1", "buy", 95, 1000) },
    { type: "submit", order: ord("o5", "B2", "buy", 100, 3000) },
    { type: "submit", order: ord("o6", "B1", "buy", 80, 500) },
    { type: "submit", order: ord("o7", "S1", "sell", 70, 400) },
    { type: "cancel", orderId: "o2", participantId: "S2" },
    { type: "close" },
  ];

  it("produces exactly these trades, cancellations and totals", () => {
    const { results, trades, summary } = runEvents(golden, events);
    expect(trades).toEqual([
      { seq: 1, buyOrderId: "o4", sellOrderId: "o3", buyerId: "B1", sellerId: "S3", qtyWh: 1000, price: 90, amount: 90, restingSide: "sell" },
      { seq: 2, buyOrderId: "o5", sellOrderId: "o3", buyerId: "B2", sellerId: "S3", qtyWh: 500, price: 90, amount: 45, restingSide: "sell" },
      { seq: 3, buyOrderId: "o5", sellOrderId: "o1", buyerId: "B2", sellerId: "S1", qtyWh: 2000, price: 100, amount: 200, restingSide: "sell" },
      { seq: 4, buyOrderId: "o5", sellOrderId: "o2", buyerId: "B2", sellerId: "S2", qtyWh: 500, price: 100, amount: 50, restingSide: "sell" },
      { seq: 5, buyOrderId: "o6", sellOrderId: "o7", buyerId: "B1", sellerId: "S1", qtyWh: 400, price: 80, amount: 32, restingSide: "buy" },
    ]);
    expect(results[7]).toEqual({ ok: true, cancelledWh: 500 });
    expect(results[8]).toEqual({
      ok: true,
      cancelled: [{ orderId: "o6", participantId: "B1", side: "buy", remainingWh: 100 }],
    });
    expect(summary.tradeCount).toBe(5);
    expect(summary.volumeWh).toBe(4400);
    expect(summary.amount).toBe(417);
    expect(summary.perParticipant.S1).toEqual({ soldWh: 2400, boughtWh: 0, received: 232, paid: 0 });
    expect(summary.perParticipant.B2).toEqual({ soldWh: 0, boughtWh: 3000, received: 0, paid: 295 });
  });
});

/** Small seeded PRNG so the random test is reproducible. */
function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

describe("random event streams keep the market invariants", () => {
  for (const seed of [1, 2, 3, 42, 2026]) {
    it(`seed ${seed}`, () => {
      const rnd = mulberry32(seed);
      const int = (lo: number, hi: number) => lo + Math.floor(rnd() * (hi - lo + 1));
      const ids = ["S0", "S1", "S2", "S3", "B0", "B1", "B2", "B3", "P0", "P1"];
      const sellCapsWh: Record<string, number> = {};
      const buyCapsWh: Record<string, number> = {};
      for (const id of ids) {
        if (id[0] !== "B") sellCapsWh[id] = int(2000, 20000);
        if (id[0] !== "S") buyCapsWh[id] = int(2000, 20000);
      }
      const config: EngineConfig = { sellCapsWh, buyCapsWh };
      const e = new Engine(config);
      const accepted = new Map<string, { input: OrderInput; index: number }>();
      const events: EngineEvent[] = [];
      let n = 0;

      for (let step = 0; step < 600; step++) {
        let ev: EngineEvent;
        if (rnd() < 0.82 || accepted.size === 0) {
          const pid = ids[int(0, ids.length - 1)]!;
          const side: Side = rnd() < 0.5 ? "buy" : "sell";
          ev = { type: "submit", order: ord(`o${n++}`, pid, side, int(60, 140), int(100, 3000)) };
        } else {
          const keys = [...accepted.keys()];
          const id = keys[int(0, keys.length - 1)]!;
          const owner = rnd() < 0.8 ? accepted.get(id)!.input.participantId : "S0";
          ev = { type: "cancel", orderId: id, participantId: owner };
        }
        events.push(ev);
        const res = e.apply(ev);
        if (ev.type === "submit" && res.ok) accepted.set(ev.order.orderId, { input: ev.order, index: accepted.size });

        // The book never stays crossed, except between orders of the same participant.
        const book = e.getBook();
        for (const b of book.bids) {
          expect(b.remainingWh).toBeGreaterThan(0);
          expect(b.remainingWh).toBeLessThanOrEqual(b.qtyWh);
          for (const a of book.asks) {
            if (b.price >= a.price) expect(b.participantId).toBe(a.participantId);
          }
        }
        for (const a of book.asks) {
          expect(a.remainingWh).toBeGreaterThan(0);
          expect(a.remainingWh).toBeLessThanOrEqual(a.qtyWh);
        }
      }

      const trades = e.getTrades();
      const sum = e.summary();
      for (const t of trades) {
        const buy = accepted.get(t.buyOrderId)!;
        const sell = accepted.get(t.sellOrderId)!;
        expect(t.buyerId).not.toBe(t.sellerId);
        expect(buy.input.price).toBeGreaterThanOrEqual(t.price);
        expect(sell.input.price).toBeLessThanOrEqual(t.price);
        const restingIsBuy = buy.index < sell.index;
        expect(t.price).toBe(restingIsBuy ? buy.input.price : sell.input.price);
        expect(t.restingSide).toBe(restingIsBuy ? "buy" : "sell");
        expect(t.amount).toBe(tradeAmount(t.qtyWh, t.price));
      }
      let sold = 0;
      let bought = 0;
      let received = 0;
      let paid = 0;
      for (const [id, tot] of Object.entries(sum.perParticipant)) {
        expect(tot.soldWh).toBeLessThanOrEqual(sellCapsWh[id] ?? 0);
        expect(tot.boughtWh).toBeLessThanOrEqual(buyCapsWh[id] ?? 0);
        sold += tot.soldWh;
        bought += tot.boughtWh;
        received += tot.received;
        paid += tot.paid;
      }
      expect(sold).toBe(bought);
      expect(sold).toBe(sum.volumeWh);
      expect(received).toBe(paid);
      expect(received).toBe(sum.amount);

      // Same events on a fresh engine give identical trades (determinism).
      const replay = runEvents(config, events);
      expect(replay.trades).toEqual(trades);
      expect(replay.summary).toEqual(sum);
    });
  }
});
