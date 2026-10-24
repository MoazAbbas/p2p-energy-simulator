#!/usr/bin/env bash
# Adds the LIVE SESSION to sim/: a simulated clock, the human seller among the bots, orders going to the ledger,
# and a check after every submit that the ledger and the in-process engine agree.
# It also upgrades sim/src/market.ts (the bot loop moves into src/hourmarket.ts so it can run one round at a time).
# The old market.ts is kept as sim/src/market.ts.bak. A regression test proves the experiment results are unchanged.
#
# Needs: setup-engine.sh, setup-sim.sh, setup-bots.sh, setup-experiment.sh and setup-chaincode.sh already run.
# Run from the repo root:  cd ~/projects/p2p-energy && bash setup-live.sh
set -euo pipefail

[ -f sim/src/market.ts ] || { echo "sim/src/market.ts not found - run the earlier setup scripts first (and run this from the repo root)."; exit 1; }
[ -d sim/node_modules ] || { echo "sim/ is not set up - run setup-sim.sh first."; exit 1; }
[ -f blockchain/chaincode/energy-market/src/logic.ts ] || { echo "The chaincode is missing - run setup-chaincode.sh first."; exit 1; }
for f in src/hourmarket.ts src/live test/regression.test.ts test/live.test.ts; do
  if [ -e "sim/$f" ]; then echo "sim/$f already exists - stopping so nothing is overwritten."; exit 1; fi
done
if grep -q "class DaySim" sim/src/market.ts; then echo "sim/src/market.ts already has DaySim - already upgraded."; exit 1; fi
HASH=$(sha256sum sim/src/market.ts | cut -d' ' -f1)
if [ "$HASH" != "bf61dd551e6b25183bd10f5a150af2f1ffaf887e18d43022c20ff5d7ffa0bd33" ]; then
  echo "sim/src/market.ts is not the version this script upgrades (it was edited, or is from another step)."
  echo "Nothing was changed. Send me the file and I will adapt the upgrade."
  exit 1
fi

cp sim/src/market.ts sim/src/market.ts.bak
mkdir -p sim/src/live sim/test

cat > sim/src/market.ts <<'P2P_EOF'
/**
 * Runs one simulated day for a community of households.
 *
 * In trading hours, every hour is a continuous double auction (the Engine) played in `ticksPerHour` rounds.
 * Each round every active bot posts a resting order (replacing its old one if its price changed), then adapts
 * its margin: it shades more after a fill and improves its price after a miss (ZIP-like).
 * Outside trading hours, and for anything left unmatched, households use the utility:
 *   buy at the retail tariff, export at the export rate.
 *
 * Outage hours (optional): the utility is unavailable. Unmet demand is "unserved" (costed at the ceiling price so
 * runs stay comparable), unsold surplus is curtailed (no revenue), and the price band becomes [1, retail x multiplier].
 *
 * Every household gets three costs for the day (piastres, positive = pays):
 *   A  no solar:              buys all its load from the utility
 *   B  solar, always export:  self-consumes, exports all surplus at the export rate
 *   C  solar + P2P market:    what actually happened in this simulation
 * premium = B - C is the benefit of the P2P market over simply exporting.
 *
 * Tariff defaults are PLACEHOLDERS until the official Egyptian figures are looked up.
 */
import { Engine, tradeAmount, type CancelResult, type EngineConfig, type EngineEvent, type SubmitResult, type Trade } from "../../engine/src/engine";
import type { Agent } from "./agents";
import { DEFAULT_LOAD_PARAMS, householdDay, type HouseholdDay, type LoadParams } from "./household";
import { HourMarket } from "./hourmarket";
import type { DayProfile } from "./pvgis";
import type { Rng } from "./rng";

export interface Tariff {
  /** piastres per kWh paid when buying from the utility (the price ceiling) */
  retail: number;
  /** piastres per kWh received when exporting to the utility (the price floor) */
  export: number;
}

export interface Outage {
  /** local hours (0..23) during which the utility is unavailable */
  hours: readonly number[];
  /** buyer ceiling = retail x this / 1000 (2000 = double) */
  ceilingMultiplierPermille: number;
}

export interface MarketConfig {
  tariff: Tariff;
  /** local hours with a market, e.g. [12,13,14,15,16,17] */
  tradingHours: readonly number[];
  ticksPerHour: number;
  /** 0..1: random variation of the learning step */
  learningNoise: number;
  outage?: Outage;
  /** keep every trade in the result (more memory) */
  collectTrades?: boolean;
  /** keep the engine event log of every hour (for replay / chain equivalence checks) */
  recordEvents?: boolean;
}

export const DEFAULT_MARKET: MarketConfig = {
  tariff: { retail: 200, export: 100 }, // PLACEHOLDER: 2.00 and 1.00 EGP per kWh
  tradingHours: [12, 13, 14, 15, 16, 17],
  ticksPerHour: 12,
  learningNoise: 0.5,
};

export interface HourLog {
  hour: number;
  gridUp: boolean;
  tradedWh: number;
  amount: number;
  tradeCount: number;
  minPrice: number | null;
  maxPrice: number | null;
  /** all surplus of all households in this hour */
  surplusWh: number;
  /** all deficit of households that may buy */
  buyerDemandWh: number;
  gridImportWh: number;
  gridExportWh: number;
  unservedWh: number;
  curtailedWh: number;
  trades?: Trade[];
  engineConfig?: EngineConfig;
  events?: EngineEvent[];
}

export interface AgentResult {
  id: string;
  kind: Agent["kind"];
  pvKwp: number;
  generationWh: number;
  surplusWh: number;
  deficitWh: number;
  boughtWh: number;
  soldWh: number;
  paid: number;
  received: number;
  costA: number;
  costB: number;
  costC: number;
  /** costB - costC */
  premium: number;
}

export interface DayMetrics {
  tradedWh: number;
  /** piastres moved between households */
  amount: number;
  tradeCount: number;
  /** share of all surplus (trading hours) that was sold P2P */
  surplusSoldShare: number | null;
  /** share of buyer demand (trading hours) that was met P2P */
  demandCoveredShare: number | null;
  /** sum of premium over all households, piastres */
  totalGain: number;
  /** volume-weighted average trade price, piastres per kWh */
  vwap: number | null;
  /** (vwap - export) / (retail - export): 0 = sellers get only the export rate, 1 = buyers pay full retail */
  pricePosition: number | null;
  /** volume-weighted standard deviation of trade prices */
  priceStdDev: number | null;
  gridImportWh: number;
  gridExportWh: number;
  gridImportWhB: number;
  gridExportWhB: number;
  unservedWh: number;
}

export interface DayResult {
  date: string;
  agents: AgentResult[];
  hours: HourLog[];
  metrics: DayMetrics;
}

export function validateMarket(cfg: MarketConfig): void {
  const { retail, export: exp } = cfg.tariff;
  if (!Number.isInteger(retail) || !Number.isInteger(exp) || exp < 1 || retail < exp) {
    throw new Error("tariff: retail and export must be integers (piastres/kWh) with 1 <= export <= retail");
  }
  if (!Number.isInteger(cfg.ticksPerHour) || cfg.ticksPerHour < 1) throw new Error("ticksPerHour must be a positive integer");
  if (!(cfg.learningNoise >= 0 && cfg.learningNoise <= 1)) throw new Error("learningNoise must be within 0..1");
  for (const h of [...cfg.tradingHours, ...(cfg.outage?.hours ?? [])]) {
    if (!Number.isInteger(h) || h < 0 || h > 23) throw new Error("hours must be integers 0..23");
  }
  if (cfg.outage && !(cfg.outage.ceilingMultiplierPermille >= 1000)) {
    throw new Error("outage ceilingMultiplierPermille must be at least 1000");
  }
}

interface Acc {
  costA: number;
  costB: number;
  costC: number;
  boughtWh: number;
  soldWh: number;
  paid: number;
  received: number;
}

export interface HourBand {
  gridUp: boolean;
  /** what a household pays the utility per kWh this hour (the outage ceiling when the grid is down) */
  buyPrice: number;
  /** what the utility pays for exported energy per kWh (0 when the grid is down) */
  exportPrice: number;
  /** price band for bots: [lo, hi] */
  lo: number;
  hi: number;
}

/**
 * The accounting of one simulated day: households, the three baselines, per-hour logs and day totals.
 * simulateDay drives it hour by hour with in-process engines; the live session drives it with a real-time clock.
 */
export class DaySim {
  readonly cfg: MarketConfig;
  readonly date: string;
  readonly agents: Agent[];
  readonly households: HouseholdDay[];
  readonly hours: HourLog[] = [];
  private readonly acc: Acc[];
  private readonly trading: Set<number>;
  private readonly outageHours: Set<number>;
  private readonly hiOutage: number;
  private sumQ = 0;
  private sumPQ = 0;
  private sumP2Q = 0;
  private gridImportWh = 0;
  private gridExportWh = 0;
  private gridImportWhB = 0;
  private gridExportWhB = 0;
  private unservedWh = 0;

  constructor(agentsIn: readonly Agent[], day: DayProfile, cfg: MarketConfig, loadParams: LoadParams = DEFAULT_LOAD_PARAMS) {
    validateMarket(cfg);
    this.cfg = cfg;
    this.date = day.date;
    // Learning state is private to this run: the caller's agents are never modified.
    this.agents = agentsIn.map((a) => ({ ...a, buyer: { ...a.buyer }, seller: { ...a.seller } }));
    this.households = this.agents.map((a) => householdDay(a.spec, day, loadParams));
    this.trading = new Set(cfg.tradingHours);
    this.outageHours = new Set(cfg.outage?.hours ?? []);
    this.hiOutage = Math.round((cfg.tariff.retail * (cfg.outage?.ceilingMultiplierPermille ?? 1000)) / 1000);
    this.acc = this.agents.map(() => ({ costA: 0, costB: 0, costC: 0, boughtWh: 0, soldWh: 0, paid: 0, received: 0 }));
  }

  isTrading(h: number): boolean {
    return this.trading.has(h);
  }

  band(h: number): HourBand {
    const gridUp = !this.outageHours.has(h);
    const r = this.cfg.tariff.retail;
    const e = this.cfg.tariff.export;
    return {
      gridUp,
      buyPrice: gridUp ? r : this.hiOutage,
      exportPrice: gridUp ? e : 0,
      lo: gridUp ? e : 1,
      hi: gridUp ? r : this.hiOutage,
    };
  }

  /** Bots for a trading hour. `externalIds` are agents that act from outside (the live human). */
  openMarket(h: number, externalIds?: ReadonlySet<string>): HourMarket {
    const b = this.band(h);
    return new HourMarket({
      agents: this.agents,
      households: this.households,
      hour: h,
      lo: b.lo,
      hi: b.hi,
      learningNoise: this.cfg.learningNoise,
      externalIds,
      collectTrades: this.cfg.collectTrades === true,
    });
  }

  /**
   * Settles hour h for every household (market trades, then the utility for the rest) and logs it.
   * Hours must be finished in order 0..23. `market` is null for hours without a market.
   */
  finishHour(h: number, market: HourMarket | null, record?: { engineConfig: EngineConfig; events: EngineEvent[] }): HourLog {
    if (this.hours.length !== h) throw new Error(`hours must be finished in order: expected ${this.hours.length}, got ${h}`);
    const n = this.agents.length;
    const { gridUp, buyPrice, exportPrice } = this.band(h);
    const log: HourLog = {
      hour: h,
      gridUp,
      tradedWh: 0,
      amount: 0,
      tradeCount: 0,
      minPrice: null,
      maxPrice: null,
      surplusWh: 0,
      buyerDemandWh: 0,
      gridImportWh: 0,
      gridExportWh: 0,
      unservedWh: 0,
      curtailedWh: 0,
    };
    for (let i = 0; i < n; i++) {
      log.surplusWh += this.households[i]!.surplusWh[h]!;
      if (this.agents[i]!.canBuy) log.buyerDemandWh += this.households[i]!.deficitWh[h]!;
    }
    if (market !== null) {
      const st = market.stats;
      log.tradedWh = st.tradedWh;
      log.amount = st.amount;
      log.tradeCount = st.tradeCount;
      log.minPrice = st.minPrice;
      log.maxPrice = st.maxPrice;
      if (st.trades !== undefined) log.trades = st.trades;
      if (record !== undefined) {
        log.engineConfig = record.engineConfig;
        log.events = record.events;
      }
      this.sumQ += st.sumQ;
      this.sumPQ += st.sumPQ;
      this.sumP2Q += st.sumP2Q;
    }

    for (let i = 0; i < n; i++) {
      const hh = this.households[i]!;
      const a = this.acc[i]!;
      const deficit = hh.deficitWh[h]!;
      const surplus = hh.surplusWh[h]!;
      const bought = market?.boughtWh[i] ?? 0;
      const sold = market?.soldWh[i] ?? 0;
      const paid = market?.paid[i] ?? 0;
      const received = market?.received[i] ?? 0;
      a.costA += tradeAmount(hh.loadWh[h]!, buyPrice);
      a.costB += tradeAmount(deficit, buyPrice) - tradeAmount(surplus, exportPrice);
      const buyLeft = deficit - bought;
      const exportLeft = surplus - sold;
      a.costC += tradeAmount(buyLeft, buyPrice) - tradeAmount(exportLeft, exportPrice) + paid - received;
      a.boughtWh += bought;
      a.soldWh += sold;
      a.paid += paid;
      a.received += received;
      if (gridUp) {
        log.gridImportWh += buyLeft;
        log.gridExportWh += exportLeft;
        this.gridImportWhB += deficit;
        this.gridExportWhB += surplus;
      } else {
        log.unservedWh += buyLeft;
        log.curtailedWh += exportLeft;
      }
    }
    this.gridImportWh += log.gridImportWh;
    this.gridExportWh += log.gridExportWh;
    this.unservedWh += log.unservedWh;
    this.hours.push(log);
    return log;
  }

  /** Per-household results so far (final once all 24 hours are finished). */
  agentResults(): AgentResult[] {
    return this.agents.map((a, i) => ({
      id: a.id,
      kind: a.kind,
      pvKwp: a.spec.pvKwp,
      generationWh: this.households[i]!.totals.generationWh,
      surplusWh: this.households[i]!.totals.surplusWh,
      deficitWh: this.households[i]!.totals.deficitWh,
      boughtWh: this.acc[i]!.boughtWh,
      soldWh: this.acc[i]!.soldWh,
      paid: this.acc[i]!.paid,
      received: this.acc[i]!.received,
      costA: this.acc[i]!.costA,
      costB: this.acc[i]!.costB,
      costC: this.acc[i]!.costC,
      premium: this.acc[i]!.costB - this.acc[i]!.costC,
    }));
  }

  result(): DayResult {
    if (this.hours.length !== 24) throw new Error("the day is not finished");
    const r = this.cfg.tariff.retail;
    const e = this.cfg.tariff.export;
    const agentResults = this.agentResults();
    let surplusTrading = 0;
    let demandTrading = 0;
    let tradedWh = 0;
    let amount = 0;
    let tradeCount = 0;
    for (const l of this.hours) {
      tradedWh += l.tradedWh;
      amount += l.amount;
      tradeCount += l.tradeCount;
      if (this.trading.has(l.hour)) {
        surplusTrading += l.surplusWh;
        demandTrading += l.buyerDemandWh;
      }
    }
    const { sumQ, sumPQ, sumP2Q } = this;
    const vwap = sumQ > 0 ? sumPQ / sumQ : null;
    const metrics: DayMetrics = {
      tradedWh,
      amount,
      tradeCount,
      surplusSoldShare: surplusTrading > 0 ? tradedWh / surplusTrading : null,
      demandCoveredShare: demandTrading > 0 ? tradedWh / demandTrading : null,
      totalGain: agentResults.reduce((s, a) => s + a.premium, 0),
      vwap,
      pricePosition: vwap !== null && r > e ? (vwap - e) / (r - e) : null,
      priceStdDev: vwap !== null ? Math.sqrt(Math.max(0, sumP2Q / sumQ - vwap * vwap)) : null,
      gridImportWh: this.gridImportWh,
      gridExportWh: this.gridExportWh,
      gridImportWhB: this.gridImportWhB,
      gridExportWhB: this.gridExportWhB,
      unservedWh: this.unservedWh,
    };
    return { date: this.date, agents: agentResults, hours: this.hours, metrics };
  }
}

export function simulateDay(
  agentsIn: readonly Agent[],
  day: DayProfile,
  cfg: MarketConfig,
  rng: Rng,
  loadParams: LoadParams = DEFAULT_LOAD_PARAMS,
): DayResult {
  const sim = new DaySim(agentsIn, day, cfg, loadParams);
  for (let h = 0; h < 24; h++) {
    if (!sim.isTrading(h)) {
      sim.finishHour(h, null);
      continue;
    }
    const market = sim.openMarket(h);
    const engine = new Engine(market.engineConfig);
    const events: EngineEvent[] = [];
    const record = cfg.recordEvents === true;
    for (let tick = 0; tick < cfg.ticksPerHour; tick++) {
      const tickEvents = market.runTick(rng, (ev) => engine.apply(ev) as SubmitResult | CancelResult);
      if (record) events.push(...tickEvents);
    }
    const closeEvent: EngineEvent = { type: "close" };
    if (record) events.push(closeEvent);
    engine.apply(closeEvent);
    sim.finishHour(h, market, record ? { engineConfig: market.engineConfig, events } : undefined);
  }
  return sim.result();
}
P2P_EOF

cat > sim/src/hourmarket.ts <<'P2P_EOF'
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
P2P_EOF

cat > sim/src/live/ledger.ts <<'P2P_EOF'
/**
 * What the live session needs from the "book of record". Two implementations:
 *   LocalLedger  - the chaincode logic running in memory (tests, offline demos, no Docker)
 *   FabricLedger - the same calls sent to the Hyperledger Fabric network (added after the network is verified)
 * Both must give the same answers, because both run the same chaincode logic.
 */
import type { EngineConfig, EngineEvent, Trade } from "../../../engine/src/engine";

/** Who is submitting: the platform operator (bots, hour handling) or the human participant (own identity). */
export type Actor = "operator" | "human";

export interface LedgerParticipant {
  participantId: string;
  /** the human's participant is owned by the human identity; bots have no owner (the operator acts for them) */
  owner: Actor | null;
}

export interface LedgerEventResult {
  ok: boolean;
  seq?: number;
  restingWh?: number;
  tradeSeqs?: number[];
  cancelledWh?: number;
  reason?: string;
  message?: string;
}

export interface LedgerSubmitOutcome {
  results: LedgerEventResult[];
  trades: Trade[];
}

export interface LedgerHourSummary {
  hour: number;
  tradeCount: number;
  volumeWh: number;
  amount: number;
  summaryHash: string;
  prevHash: string;
}

export interface SettlementFigures {
  boughtWh: number;
  soldWh: number;
  paid: number;
  received: number;
  costA: number;
  costB: number;
  costC: number;
}

export interface Ledger {
  openSession(args: { scenarioHash: string; participants: LedgerParticipant[] }): Promise<void>;
  openHour(hour: number, caps: EngineConfig): Promise<void>;
  submit(hour: number, events: EngineEvent[], actor: Actor): Promise<LedgerSubmitOutcome>;
  closeHour(hour: number): Promise<LedgerHourSummary>;
  closeSession(): Promise<void>;
  recordSettlement(participantId: string, figures: SettlementFigures): Promise<void>;
}
P2P_EOF

cat > sim/src/live/memoryStore.ts <<'P2P_EOF'
import type { Store } from "../../../blockchain/chaincode/energy-market/src/logic";

const SEP = "\u0000";

/** In-memory ledger state with the key shape and ordering of Fabric composite keys. */
export class MemoryStore implements Store {
  readonly data = new Map<string, string>();

  key(objectType: string, attrs: readonly string[]): string {
    return SEP + objectType + SEP + attrs.join(SEP) + SEP;
  }

  async get(key: string): Promise<string | null> {
    return this.data.get(key) ?? null;
  }

  async put(key: string, value: string): Promise<void> {
    this.data.set(key, value);
  }

  async listByPrefix(objectType: string, attrs: readonly string[]): Promise<string[]> {
    const prefix = SEP + objectType + SEP + attrs.map((a) => a + SEP).join("");
    return [...this.data.keys()]
      .filter((k) => k.startsWith(prefix))
      .sort()
      .map((k) => this.data.get(k)!);
  }
}
P2P_EOF

cat > sim/src/live/localLedger.ts <<'P2P_EOF'
import * as chaincode from "../../../blockchain/chaincode/energy-market/src/logic";
import type { CallContext } from "../../../blockchain/chaincode/energy-market/src/logic";
import { RULES_VERSION, type EngineConfig, type EngineEvent, type Trade } from "../../../engine/src/engine";
import type { Actor, Ledger, LedgerEventResult, LedgerHourSummary, LedgerParticipant, LedgerSubmitOutcome, SettlementFigures } from "./ledger";
import { MemoryStore } from "./memoryStore";

export const OPERATOR_IDENTITY = "x509::local-operator";
export const HUMAN_IDENTITY = "x509::local-human";

/** The chaincode logic executed in memory: same rules, same hashes, no network. */
export class LocalLedger implements Ledger {
  readonly store = new MemoryStore();
  private txCounter = 0;

  constructor(readonly sessionId: string) {}

  private ctx(actor: Actor): CallContext {
    // A fixed, increasing transaction time: the chaincode only stores it, it never affects the market.
    const t = new Date(Date.UTC(2026, 0, 1) + this.txCounter++ * 1000).toISOString();
    return { store: this.store, callerId: actor === "operator" ? OPERATOR_IDENTITY : HUMAN_IDENTITY, txTimestamp: t };
  }

  async openSession(args: { scenarioHash: string; participants: LedgerParticipant[] }): Promise<void> {
    const participants = args.participants.map((p) => ({
      participantId: p.participantId,
      ownerId: p.owner === "human" ? HUMAN_IDENTITY : null,
    }));
    await chaincode.openSession(this.ctx("operator"), this.sessionId, RULES_VERSION, args.scenarioHash, JSON.stringify(participants));
  }

  async openHour(hour: number, caps: EngineConfig): Promise<void> {
    await chaincode.openHour(this.ctx("operator"), this.sessionId, hour, JSON.stringify(caps));
  }

  async submit(hour: number, events: EngineEvent[], actor: Actor): Promise<LedgerSubmitOutcome> {
    const results: LedgerEventResult[] = [];
    const trades: Trade[] = [];
    for (let i = 0; i < events.length; i += chaincode.MAX_EVENTS_PER_BATCH) {
      const chunk = events.slice(i, i + chaincode.MAX_EVENTS_PER_BATCH);
      const out = await chaincode.submitOrders(this.ctx(actor), this.sessionId, hour, JSON.stringify(chunk));
      results.push(...out.results);
      for (const { sessionId: _s, hour: _h, ...t } of out.trades) trades.push(t);
    }
    return { results, trades };
  }

  async closeHour(hour: number): Promise<LedgerHourSummary> {
    const s = await chaincode.closeHour(this.ctx("operator"), this.sessionId, hour);
    return { hour, tradeCount: s.tradeCount, volumeWh: s.volumeWh, amount: s.amount, summaryHash: s.summaryHash, prevHash: s.prevHash };
  }

  async closeSession(): Promise<void> {
    await chaincode.closeSession(this.ctx("operator"), this.sessionId);
  }

  async recordSettlement(participantId: string, figures: SettlementFigures): Promise<void> {
    await chaincode.recordSettlement(this.ctx("operator"), this.sessionId, participantId, JSON.stringify(figures));
  }

  /** Recomputes an hour's hashes from the stored events (what an auditor would do). */
  verifyHour(hour: number): Promise<{ ok: boolean; problems: string[] }> {
    return chaincode.verifyHour(this.ctx("operator"), this.sessionId, hour);
  }

  getSession() {
    return chaincode.getSession(this.ctx("operator"), this.sessionId);
  }

  getHourSummary(hour: number) {
    return chaincode.getHourSummary(this.ctx("operator"), this.sessionId, hour);
  }
}
P2P_EOF

cat > sim/src/live/session.ts <<'P2P_EOF'
/**
 * A live session: one simulated day with a human seller among bot households.
 *
 * Every state change goes through one serial queue, so the order book, the shadow engine and the ledger always
 * see the same sequence of events:
 *
 *   - the BOTS' orders of one round (tick) are computed against a shadow Engine and sent to the ledger as ONE batch
 *   - the HUMAN's orders and cancels are sent one at a time, under the human's own identity
 *   - after every submit the ledger's answer (accepted/rejected, trades, prices) is compared with the shadow
 *     Engine's answer; any difference halts the session (IntegrityError) instead of letting the two drift apart
 *
 * The session does not read the wall clock. `advance()` performs the next step of the day; a driver (driver.ts)
 * calls it on a timer, tests call it in a loop.
 */
import { createHash } from "node:crypto";
import { Engine, RULES_VERSION, type BookSnapshot, type CancelResult, type EngineEvent, type SubmitResult, type Trade } from "../../../engine/src/engine";
import type { Agent } from "../agents";
import { DaySim, type DayResult, type HourLog, type MarketConfig } from "../market";
import type { HourMarket } from "../hourmarket";
import { DEFAULT_LOAD_PARAMS, type LoadParams } from "../household";
import type { DayProfile } from "../pvgis";
import { mulberry32, type Rng } from "../rng";
import type { Ledger, LedgerEventResult, LedgerHourSummary, LedgerSubmitOutcome } from "./ledger";

export type Phase = "planning" | "morning" | "trading" | "evening" | "finished" | "halted";

export class IntegrityError extends Error {
  constructor(message: string, readonly detail: unknown) {
    super(message);
    this.name = "IntegrityError";
  }
}

export interface LiveConfig {
  sessionId: string;
  /** the whole community including the human's household */
  agents: readonly Agent[];
  /** id of the agent that is played by the human (must exist in `agents`) */
  humanId: string;
  day: DayProfile;
  market: MarketConfig;
  seed: number;
  loadParams?: LoadParams;
}

export interface HumanPlan {
  hours: Array<{ hour: number; generationWh: number; loadWh: number; surplusWh: number; deficitWh: number; trading: boolean; gridUp: boolean }>;
  /** price band the human can expect per trading hour: [floor, ceiling] in piastres per kWh */
  bands: Array<{ hour: number; floor: number; ceiling: number }>;
}

export type StepKind = "fastForward" | "openHour" | "tick" | "closeHour" | "settle";

export interface StepInfo {
  kind: StepKind;
  phase: Phase;
  hour: number;
  /** 1-based round number within the hour, for kind "tick" */
  tick?: number;
  /** bot orders and cancels sent in this step */
  events?: number;
  trades?: number;
}

export interface OrderRequest {
  price: number;
  qtyWh: number;
}

export interface PlaceResult {
  accepted: boolean;
  orderId?: string;
  reason?: string;
  message?: string;
  /** Wh of the order that did not trade and now rests in the book */
  restingWh?: number;
  trades: Trade[];
}

export interface LiveState {
  phase: Phase;
  /** the hour being played or just finished; 0..23 */
  hour: number;
  tick: number;
  ticksPerHour: number;
  /** simulated clock, "HH:MM" */
  clock: string;
  gridUp: boolean;
  /** order book of the open hour (empty when no hour is open) */
  book: BookSnapshot;
  human: {
    id: string;
    availableToSellWh: number;
    openOrders: Array<{ orderId: string; price: number; remainingWh: number }>;
    soldWhThisHour: number;
    receivedThisHour: number;
  };
  lastTrades: Trade[];
  finishedHours: HourLog[];
  halted: { reason: string; detail: unknown } | null;
}

/** Fixed field order, so the shadow's and the ledger's answers can be compared as text. */
function normalizeResult(r: LedgerEventResult): string {
  return JSON.stringify([r.ok, r.seq ?? null, r.restingWh ?? null, r.tradeSeqs ?? null, r.cancelledWh ?? null, r.ok ? null : (r.reason ?? null)]);
}

function shadowToLedgerResult(r: SubmitResult | CancelResult): LedgerEventResult {
  if (!r.ok) return { ok: false, reason: r.reason, message: r.message };
  if ("trades" in r) return { ok: true, seq: r.seq, restingWh: r.restingWh, tradeSeqs: r.trades.map((t) => t.seq) };
  return { ok: true, cancelledWh: r.cancelledWh };
}

function canonicalJson(value: unknown): string {
  return JSON.stringify(value, (_k, v) =>
    v && typeof v === "object" && !Array.isArray(v) ? Object.fromEntries(Object.entries(v as Record<string, unknown>).sort(([a], [b]) => (a < b ? -1 : 1))) : v,
  );
}

/** sha-256 of everything that determines a session's outcome, fixed on the ledger when the session opens. */
export function scenarioHash(cfg: LiveConfig): string {
  return createHash("sha256")
    .update(
      canonicalJson({
        rulesVersion: RULES_VERSION,
        sessionId: cfg.sessionId,
        humanId: cfg.humanId,
        seed: cfg.seed,
        day: cfg.day,
        market: { ...cfg.market, collectTrades: undefined, recordEvents: undefined },
        loadParams: cfg.loadParams ?? DEFAULT_LOAD_PARAMS,
        agents: cfg.agents,
      }),
    )
    .digest("hex");
}

export class LiveSession {
  private readonly sim: DaySim;
  private readonly rng: Rng;
  private readonly humanIndex: number;
  private readonly externalIds: ReadonlySet<string>;
  private phase: Phase = "planning";
  private nextHour = 0;
  private market: HourMarket | null = null;
  private shadow: Engine | null = null;
  private tick = 0;
  private humanOrderCounter = 0;
  private lastTrades: Trade[] = [];
  private halted: { reason: string; detail: unknown } | null = null;
  private queue: Promise<unknown> = Promise.resolve();
  private started = false;
  readonly hourSummaries: LedgerHourSummary[] = [];

  constructor(private readonly cfg: LiveConfig, private readonly ledger: Ledger) {
    this.sim = new DaySim(cfg.agents, cfg.day, cfg.market, cfg.loadParams);
    this.rng = mulberry32(cfg.seed);
    this.humanIndex = this.sim.agents.findIndex((a) => a.id === cfg.humanId);
    if (this.humanIndex < 0) throw new Error(`humanId ${cfg.humanId} is not one of the agents`);
    if (this.sim.agents[this.humanIndex]!.canBuy) throw new Error("the human is a seller only (canBuy must be false)");
    if (new Set(cfg.agents.map((a) => a.id)).size !== cfg.agents.length) throw new Error("agent ids must be unique");
    if (cfg.market.tradingHours.length === 0) throw new Error("tradingHours must not be empty");
    this.externalIds = new Set([cfg.humanId]);
  }

  /** Forecast for the planning screen: the human household's generation, load and expected surplus. */
  plan(): HumanPlan {
    const hh = this.sim.households[this.humanIndex]!;
    const hours = [];
    const bands = [];
    for (let h = 0; h < 24; h++) {
      const b = this.sim.band(h);
      hours.push({
        hour: h,
        generationWh: hh.generationWh[h]!,
        loadWh: hh.loadWh[h]!,
        surplusWh: hh.surplusWh[h]!,
        deficitWh: hh.deficitWh[h]!,
        trading: this.sim.isTrading(h),
        gridUp: b.gridUp,
      });
      if (this.sim.isTrading(h)) bands.push({ hour: h, floor: b.lo, ceiling: b.hi });
    }
    return { hours, bands };
  }

  /** Serializes work: each job starts when the previous one has finished, whether it succeeded or not. */
  private enqueue<T>(job: () => Promise<T>): Promise<T> {
    const run = this.queue.then(job, job);
    this.queue = run.catch(() => undefined);
    return run;
  }

  private assertRunning(): void {
    if (this.halted !== null) throw new IntegrityError(`session halted: ${this.halted.reason}`, this.halted.detail);
    if (!this.started) throw new Error("the session has not been started");
    if (this.phase === "finished") throw new Error("the session is finished");
  }

  private halt(reason: string, detail: unknown): never {
    this.halted = { reason, detail };
    this.phase = "halted";
    throw new IntegrityError(reason, detail);
  }

  /** Registers the session and all participants on the ledger. Call once, before the first advance(). */
  start(): Promise<void> {
    return this.enqueue(async () => {
      if (this.started) throw new Error("already started");
      await this.ledger.openSession({
        scenarioHash: scenarioHash(this.cfg),
        participants: this.sim.agents.map((a) => ({ participantId: a.id, owner: a.id === this.cfg.humanId ? ("human" as const) : null })),
      });
      this.started = true;
      this.phase = "morning";
    });
  }

  /** Performs the next step of the day. */
  advance(): Promise<StepInfo> {
    return this.enqueue(() => this.doAdvance());
  }

  private async doAdvance(): Promise<StepInfo> {
    this.assertRunning();
    const T = this.cfg.market.ticksPerHour;

    if (this.market !== null) {
      const h = this.nextHour;
      if (this.tick < T) return this.doTick(h);
      return this.doCloseHour(h);
    }

    if (this.nextHour >= 24) return this.doSettle();

    const h = this.nextHour;
    if (!this.sim.isTrading(h)) {
      const donePhase: Phase = this.sim.hours.some((l) => this.sim.isTrading(l.hour)) ? "evening" : "morning";
      this.phase = donePhase;
      const first = h;
      while (this.nextHour < 24 && !this.sim.isTrading(this.nextHour)) {
        this.sim.finishHour(this.nextHour, null);
        this.nextHour++;
      }
      return { kind: "fastForward", phase: donePhase, hour: first };
    }

    // open a trading hour
    this.market = this.sim.openMarket(h, this.externalIds);
    this.shadow = new Engine(this.market.engineConfig);
    this.tick = 0;
    await this.ledger.openHour(h, this.market.engineConfig);
    this.phase = "trading";
    this.lastTrades = [];
    return { kind: "openHour", phase: "trading", hour: h };
  }

  private async sendAndCheck(h: number, events: EngineEvent[], who: "operator" | "human", expected: { results: LedgerEventResult[]; trades: Trade[] }): Promise<LedgerSubmitOutcome> {
    let outcome: LedgerSubmitOutcome;
    try {
      outcome = await this.ledger.submit(h, events, who);
    } catch (err) {
      return this.halt("the ledger refused or failed a submit", { hour: h, error: String(err), events: events.length });
    }
    const a = expected.results.map(normalizeResult);
    const b = outcome.results.map(normalizeResult);
    if (a.length !== b.length || a.some((x, i) => x !== b[i])) {
      return this.halt("the ledger's answer differs from the shadow engine's", { hour: h, expected: expected.results, got: outcome.results });
    }
    if (JSON.stringify(expected.trades) !== JSON.stringify(outcome.trades)) {
      return this.halt("the ledger's trades differ from the shadow engine's", { hour: h, expected: expected.trades, got: outcome.trades });
    }
    return outcome;
  }

  private async doTick(h: number): Promise<StepInfo> {
    const market = this.market!;
    const collected: EngineEvent[] = [];
    const botResults: LedgerEventResult[] = [];
    const botTrades: Trade[] = [];
    // The bots decide against the shadow engine; every event it applies is collected for the ledger batch.
    market.runTick(this.rng, (ev) => {
      const r = this.shadow!.apply(ev) as SubmitResult | CancelResult;
      collected.push(ev);
      botResults.push(shadowToLedgerResult(r));
      if (r.ok && "trades" in r) botTrades.push(...r.trades);
      return r;
    });
    this.tick++;
    if (collected.length > 0) {
      const outcome = await this.sendAndCheck(h, collected, "operator", { results: botResults, trades: botTrades });
      if (outcome.trades.length > 0) this.lastTrades.push(...outcome.trades);
    }
    return { kind: "tick", phase: "trading", hour: h, tick: this.tick, events: collected.length, trades: botTrades.length };
  }

  private async doCloseHour(h: number): Promise<StepInfo> {
    const market = this.market!;
    const shadow = this.shadow!;
    const summary = await (async () => {
      try {
        return await this.ledger.closeHour(h);
      } catch (err) {
        return this.halt("the ledger failed to close the hour", { hour: h, error: String(err) });
      }
    })();
    shadow.apply({ type: "close" });
    const shadowTrades = shadow.getTrades();
    const volume = shadowTrades.reduce((s, t) => s + t.qtyWh, 0);
    const amount = shadowTrades.reduce((s, t) => s + t.amount, 0);
    if (summary.tradeCount !== shadowTrades.length || summary.volumeWh !== volume || summary.amount !== amount) {
      this.halt("the ledger's hour summary differs from the shadow engine's", { hour: h, ledger: summary, shadow: { tradeCount: shadowTrades.length, volumeWh: volume, amount } });
    }
    this.hourSummaries.push(summary);
    this.sim.finishHour(h, market);
    this.market = null;
    this.shadow = null;
    this.nextHour = h + 1;
    return { kind: "closeHour", phase: "trading", hour: h, trades: shadowTrades.length };
  }

  private async doSettle(): Promise<StepInfo> {
    try {
      await this.ledger.closeSession();
      for (const a of this.sim.agentResults()) {
        await this.ledger.recordSettlement(a.id, {
          boughtWh: a.boughtWh,
          soldWh: a.soldWh,
          paid: a.paid,
          received: a.received,
          costA: a.costA,
          costB: a.costB,
          costC: a.costC,
        });
      }
    } catch (err) {
      this.halt("the ledger failed to settle the session", { error: String(err) });
    }
    this.phase = "finished";
    return { kind: "settle", phase: "finished", hour: 23 };
  }

  /** The human offers energy for sale. Executes immediately against any bid that crosses. */
  placeHumanOrder(req: OrderRequest): Promise<PlaceResult> {
    return this.enqueue(async () => {
      this.assertRunning();
      if (this.market === null || this.shadow === null) {
        return { accepted: false, reason: "HOUR_CLOSED", message: "no hour is open for trading", trades: [] };
      }
      const h = this.nextHour;
      const orderId = `H${h}-${this.humanOrderCounter + 1}`;
      const ev: EngineEvent = { type: "submit", order: { orderId, participantId: this.cfg.humanId, side: "sell", price: req.price, qtyWh: req.qtyWh } };
      const r = this.shadow.apply(ev) as SubmitResult;
      if (!r.ok) return { accepted: false, reason: r.reason, message: r.message, trades: [] };
      this.humanOrderCounter++;
      const expected = { results: [shadowToLedgerResult(r)], trades: r.trades };
      await this.sendAndCheck(h, [ev], "human", expected);
      this.market.noteTrades(r.trades);
      this.lastTrades.push(...r.trades);
      return { accepted: true, orderId, restingWh: r.restingWh, trades: r.trades };
    });
  }

  /** The human withdraws a resting order. */
  cancelHumanOrder(orderId: string): Promise<{ cancelled: boolean; cancelledWh?: number; reason?: string; message?: string }> {
    return this.enqueue(async () => {
      this.assertRunning();
      if (this.market === null || this.shadow === null) return { cancelled: false, reason: "HOUR_CLOSED", message: "no hour is open for trading" };
      const h = this.nextHour;
      const ev: EngineEvent = { type: "cancel", orderId, participantId: this.cfg.humanId };
      const r = this.shadow.apply(ev) as CancelResult;
      if (!r.ok) return { cancelled: false, reason: r.reason, message: r.message };
      await this.sendAndCheck(h, [ev], "human", { results: [shadowToLedgerResult(r)], trades: [] });
      return { cancelled: true, cancelledWh: r.cancelledWh };
    });
  }

  private clockText(): string {
    const T = this.cfg.market.ticksPerHour;
    const h = this.market !== null ? this.nextHour : Math.min(this.nextHour, 23);
    const minutes = this.market !== null ? Math.floor((this.tick * 60) / T) : 0;
    return `${String(h).padStart(2, "0")}:${String(minutes).padStart(2, "0")}`;
  }

  getState(): LiveState {
    const book = this.shadow !== null ? this.shadow.getBook() : { bids: [], asks: [] };
    const hid = this.cfg.humanId;
    const mine = book.asks.filter((o) => o.participantId === hid);
    const hi = this.humanIndex;
    const h = Math.min(this.nextHour, 23);
    return {
      phase: this.phase,
      hour: h,
      tick: this.tick,
      ticksPerHour: this.cfg.market.ticksPerHour,
      clock: this.clockText(),
      gridUp: this.sim.band(h).gridUp,
      book,
      human: {
        id: hid,
        availableToSellWh: this.shadow !== null ? this.shadow.availableToSell(hid) : 0,
        openOrders: mine.map((o) => ({ orderId: o.orderId, price: o.price, remainingWh: o.remainingWh })),
        soldWhThisHour: this.market?.soldWh[hi] ?? 0,
        receivedThisHour: this.market?.received[hi] ?? 0,
      },
      lastTrades: this.lastTrades.slice(-20),
      finishedHours: [...this.sim.hours],
      halted: this.halted,
    };
  }

  /** Final per-household results; only after the session is finished. */
  result(): DayResult {
    if (this.phase !== "finished") throw new Error("the session is not finished");
    return this.sim.result();
  }

  /** The human's three baselines for the summary screen: A no solar, B solar + always export, C solar + P2P. */
  humanSummary() {
    const r = this.result();
    return r.agents.find((a) => a.id === this.cfg.humanId)!;
  }
}
P2P_EOF

cat > sim/src/live/driver.ts <<'P2P_EOF'
/**
 * Plays a session in real time. The session itself never looks at a clock; this driver decides how long to wait
 * after each step, so the same session runs instantly in tests and at human speed in the app.
 *
 * Defaults follow the design: morning about 20 s, one simulated trading hour about 70 s (12 rounds, so a round
 * about every 5.8 s), evening about 20 s. `speed` multiplies everything (2 = twice as fast).
 */
import type { LiveSession, StepInfo } from "./session";

export interface Timing {
  /** real milliseconds for the fast-forward before the market opens */
  morningMs: number;
  /** real milliseconds for one simulated trading hour */
  hourMs: number;
  /** real milliseconds for the fast-forward after the market closes */
  eveningMs: number;
}

export const DEFAULT_TIMING: Timing = { morningMs: 20_000, hourMs: 70_000, eveningMs: 20_000 };

export type Sleep = (ms: number) => Promise<void>;
const realSleep: Sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export class RealtimeDriver {
  private running = false;
  private stopRequested = false;
  private paused = false;
  private resumeWaiters: Array<() => void> = [];
  speed = 1;

  constructor(
    private readonly session: LiveSession,
    private readonly ticksPerHour: number,
    private readonly timing: Timing = DEFAULT_TIMING,
    private readonly sleep: Sleep = realSleep,
    private readonly onStep?: (step: StepInfo) => void,
  ) {}

  /** How long to wait AFTER a step, in simulated-real milliseconds. Exposed for tests. */
  delayAfter(step: StepInfo): number {
    switch (step.kind) {
      case "fastForward":
        return step.phase === "morning" ? this.timing.morningMs : this.timing.eveningMs;
      case "tick":
        return this.timing.hourMs / this.ticksPerHour;
      default:
        return 0;
    }
  }

  pause(): void {
    this.paused = true;
  }

  resume(): void {
    this.paused = false;
    for (const w of this.resumeWaiters.splice(0)) w();
  }

  stop(): void {
    this.stopRequested = true;
    this.resume();
  }

  /** Runs until the session is finished, stopped, or an error (including an IntegrityError) occurs. */
  async run(): Promise<void> {
    if (this.running) throw new Error("already running");
    this.running = true;
    this.stopRequested = false;
    try {
      for (;;) {
        while (this.paused && !this.stopRequested) await new Promise<void>((r) => this.resumeWaiters.push(r));
        if (this.stopRequested) return;
        const step = await this.session.advance();
        this.onStep?.(step);
        if (step.kind === "settle") return;
        const ms = this.delayAfter(step) / this.speed;
        if (ms > 0) await this.sleep(ms);
      }
    } finally {
      this.running = false;
    }
  }
}
P2P_EOF

cat > sim/test/regression.test.ts <<'P2P_EOF'
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
P2P_EOF

cat > sim/test/live.test.ts <<'P2P_EOF'
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
P2P_EOF

cd sim
echo "Type check..."
npm run typecheck
echo "Running all tests..."
npm test
echo
echo "Done. The live session is in sim/src/live/ (session.ts, driver.ts, localLedger.ts)."
echo "The old market.ts is sim/src/market.ts.bak - delete it once you have committed."
