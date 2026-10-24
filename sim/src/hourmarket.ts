/**
 * The bot side of one trading hour, as a small state machine that can be stepped one round ("tick") at a time.
 *
 * simulateDay (experiments, annual replay) runs all rounds of an hour back to back against an in-process Engine.
 * The live session runs one round per clock step, interleaved with the human's orders, against a shadow Engine
 * whose events are also sent to the ledger. Both use this class, so the bots behave identically in both.
 *
 * Each round every active bot posts a resting order (replacing its old one if the price changed), then adapts its
 * margin: it shades more after a fill and improves its price after a miss (ZIP-like).
 *
 * Trades made by anyone (including orders entered from outside, such as the human's) must be reported with
 * noteTrades(); trades returned by the bots' own submits are noted automatically.
 */
import type { CancelResult, EngineConfig, EngineEvent, SubmitResult, Trade } from "../../engine/src/engine";
import type { Agent } from "./agents";
import type { HouseholdDay } from "./household";
import { shuffleInPlace, type Rng } from "./rng";

export interface HourMarketInit {
  /** the community; the objects' learning state (buyer.mu, seller.m) is updated in place */
  agents: Agent[];
  households: readonly HouseholdDay[];
  hour: number;
  /** price band: bots bid and ask inside [lo, hi] (piastres per kWh) */
  lo: number;
  hi: number;
  learningNoise: number;
  /** agents that are not driven by bots (the live human): they get caps but never act here */
  externalIds?: ReadonlySet<string>;
  collectTrades?: boolean;
}

export interface HourStats {
  tradedWh: number;
  amount: number;
  tradeCount: number;
  minPrice: number | null;
  maxPrice: number | null;
  /** sums over trades, for day-level volume-weighted statistics (integers, so order does not matter) */
  sumQ: number;
  sumPQ: number;
  sumP2Q: number;
  trades?: Trade[];
}

export type ApplyFn = (event: EngineEvent) => SubmitResult | CancelResult;

const clamp01 = (x: number): number => Math.min(1, Math.max(0, x));

export class HourMarket {
  readonly engineConfig: EngineConfig;
  readonly boughtWh: number[];
  readonly soldWh: number[];
  readonly paid: number[];
  readonly received: number[];
  readonly stats: HourStats;

  private readonly agents: Agent[];
  private readonly h: number;
  private readonly lo: number;
  private readonly hi: number;
  private readonly learningNoise: number;
  private readonly sellCaps: Record<string, number> = {};
  private readonly buyCaps: Record<string, number> = {};
  private readonly active: number[] = [];
  private readonly idToIndex: Map<string, number>;
  private readonly openOrder = new Map<number, { orderId: string; price: number }>();
  private readonly doneWh = new Map<number, number>();
  private filled = new Set<number>();
  private orderCounter = 0;
  private readonly collect: boolean;

  constructor(init: HourMarketInit) {
    this.agents = init.agents;
    this.h = init.hour;
    this.lo = init.lo;
    this.hi = init.hi;
    this.learningNoise = init.learningNoise;
    this.collect = init.collectTrades === true;
    const n = init.agents.length;
    this.idToIndex = new Map(init.agents.map((a, i) => [a.id, i] as const));
    this.boughtWh = new Array<number>(n).fill(0);
    this.soldWh = new Array<number>(n).fill(0);
    this.paid = new Array<number>(n).fill(0);
    this.received = new Array<number>(n).fill(0);
    this.stats = { tradedWh: 0, amount: 0, tradeCount: 0, minPrice: null, maxPrice: null, sumQ: 0, sumPQ: 0, sumP2Q: 0 };

    const external = init.externalIds ?? new Set<string>();
    for (let i = 0; i < n; i++) {
      const a = init.agents[i]!;
      const s = init.households[i]!.surplusWh[this.h]!;
      const d = init.households[i]!.deficitWh[this.h]!;
      const bot = !external.has(a.id);
      if (s > 0) {
        const offer = s - Math.floor(s * a.seller.holdBackShare);
        if (offer > 0) {
          this.sellCaps[a.id] = offer;
          if (bot) this.active.push(i);
        }
      }
      if (a.canBuy && d > 0) {
        this.buyCaps[a.id] = d;
        if (bot) this.active.push(i);
      }
    }
    this.engineConfig = { sellCapsWh: this.sellCaps, buyCapsWh: this.buyCaps };
  }

  /** Wh this agent can still trade in this hour (cap minus what it has already traded). */
  remainingWh(agentId: string): number {
    const i = this.idToIndex.get(agentId);
    if (i === undefined) return 0;
    const cap = this.sellCaps[agentId] ?? this.buyCaps[agentId] ?? 0;
    return cap - (this.doneWh.get(i) ?? 0);
  }

  /** Records trades (made by the bots' own orders or by outside orders). */
  noteTrades(trades: readonly Trade[]): void {
    const st = this.stats;
    for (const t of trades) {
      const bi = this.idToIndex.get(t.buyerId)!;
      const si = this.idToIndex.get(t.sellerId)!;
      this.doneWh.set(bi, (this.doneWh.get(bi) ?? 0) + t.qtyWh);
      this.doneWh.set(si, (this.doneWh.get(si) ?? 0) + t.qtyWh);
      this.filled.add(bi);
      this.filled.add(si);
      this.boughtWh[bi]! += t.qtyWh;
      this.paid[bi]! += t.amount;
      this.soldWh[si]! += t.qtyWh;
      this.received[si]! += t.amount;
      st.tradedWh += t.qtyWh;
      st.amount += t.amount;
      st.tradeCount += 1;
      st.minPrice = st.minPrice === null ? t.price : Math.min(st.minPrice, t.price);
      st.maxPrice = st.maxPrice === null ? t.price : Math.max(st.maxPrice, t.price);
      st.sumQ += t.qtyWh;
      st.sumPQ += t.price * t.qtyWh;
      st.sumP2Q += t.price * t.price * t.qtyWh;
      if (this.collect) (st.trades ??= []).push(t);
    }
  }

  /**
   * One round: every active bot, in a random order, posts or replaces its order; then all of them adapt.
   * `apply` must execute the event against the hour's order book and return the Engine's result.
   * Returns the events in the order they were applied (cancels included).
   */
  runTick(rng: Rng, apply: ApplyFn): EngineEvent[] {
    const events: EngineEvent[] = [];
    const order = this.active.slice();
    shuffleInPlace(rng, order);

    for (const i of order) {
      const a = this.agents[i]!;
      const isSeller = this.sellCaps[a.id] !== undefined;
      const cap = isSeller ? this.sellCaps[a.id]! : this.buyCaps[a.id]!;
      const remaining = cap - (this.doneWh.get(i) ?? 0);
      if (remaining <= 0) continue;
      const price = Math.round(isSeller ? this.lo + a.seller.m * (this.hi - this.lo) : this.hi - a.buyer.mu * (this.hi - this.lo));
      const open = this.openOrder.get(i);
      if (open !== undefined && open.price === price) continue; // keep time priority
      if (open !== undefined) {
        const ev: EngineEvent = { type: "cancel", orderId: open.orderId, participantId: a.id };
        events.push(ev);
        const c = apply(ev);
        if (!c.ok) throw new Error(`unexpected cancel failure: ${JSON.stringify(c)}`);
      }
      const orderId = `h${this.h}-${++this.orderCounter}`;
      const ev: EngineEvent = {
        type: "submit",
        order: { orderId, participantId: a.id, side: isSeller ? "sell" : "buy", price, qtyWh: remaining },
      };
      events.push(ev);
      const res = apply(ev);
      if (!("trades" in res)) throw new Error(`unexpected submit failure: ${JSON.stringify(res)}`);
      this.openOrder.set(i, { orderId, price });
      this.noteTrades(res.trades);
    }

    // Learning: shade more after a fill, improve the price after a miss.
    for (const i of order) {
      const a = this.agents[i]!;
      const isSeller = this.sellCaps[a.id] !== undefined;
      const cap = isSeller ? this.sellCaps[a.id]! : this.buyCaps[a.id]!;
      const remaining = cap - (this.doneWh.get(i) ?? 0);
      const didFill = this.filled.has(i);
      if (!didFill && remaining <= 0) continue;
      const step = (isSeller ? a.seller.beta : a.buyer.beta) * (1 + this.learningNoise * (2 * rng() - 1));
      if (isSeller) a.seller.m = clamp01(a.seller.m + (didFill ? step : -step));
      else a.buyer.mu = clamp01(a.buyer.mu + (didFill ? step : -step));
    }
    this.filled = new Set<number>();
    return events;
  }
}
