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
import { Engine, tradeAmount, type EngineConfig, type EngineEvent, type Trade } from "../../engine/src/engine";
import type { Agent } from "./agents";
import { DEFAULT_LOAD_PARAMS, householdDay, type LoadParams } from "./household";
import type { DayProfile } from "./pvgis";
import { shuffleInPlace, type Rng } from "./rng";

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

const clamp01 = (v: number): number => Math.min(1, Math.max(0, v));

export function simulateDay(
  agentsIn: readonly Agent[],
  day: DayProfile,
  cfg: MarketConfig,
  rng: Rng,
  loadParams: LoadParams = DEFAULT_LOAD_PARAMS,
): DayResult {
  validateMarket(cfg);
  // Learning state is private to this run: the caller's agents are never modified.
  const agents = agentsIn.map((a) => ({ ...a, buyer: { ...a.buyer }, seller: { ...a.seller } }));
  const n = agents.length;
  const households = agents.map((a) => householdDay(a.spec, day, loadParams));
  const idToIndex = new Map(agents.map((a, i) => [a.id, i] as const));
  const r = cfg.tariff.retail;
  const e = cfg.tariff.export;
  const trading = new Set(cfg.tradingHours);
  const outageHours = new Set(cfg.outage?.hours ?? []);
  const hiOutage = Math.round((r * (cfg.outage?.ceilingMultiplierPermille ?? 1000)) / 1000);

  const acc: Acc[] = agents.map(() => ({ costA: 0, costB: 0, costC: 0, boughtWh: 0, soldWh: 0, paid: 0, received: 0 }));
  const hours: HourLog[] = [];
  let sumQ = 0;
  let sumPQ = 0;
  let sumP2Q = 0;
  let gridImportWh = 0;
  let gridExportWh = 0;
  let gridImportWhB = 0;
  let gridExportWhB = 0;
  let unservedWh = 0;

  for (let h = 0; h < 24; h++) {
    const gridUp = !outageHours.has(h);
    const buyPrice = gridUp ? r : hiOutage;
    const exportPrice = gridUp ? e : 0;
    const lo = gridUp ? e : 1;
    const hi = gridUp ? r : hiOutage;

    const boughtH: number[] = new Array<number>(n).fill(0);
    const soldH: number[] = new Array<number>(n).fill(0);
    const paidH: number[] = new Array<number>(n).fill(0);
    const receivedH: number[] = new Array<number>(n).fill(0);

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
      log.surplusWh += households[i]!.surplusWh[h]!;
      if (agents[i]!.canBuy) log.buyerDemandWh += households[i]!.deficitWh[h]!;
    }

    if (trading.has(h)) {
      const sellCaps: Record<string, number> = {};
      const buyCaps: Record<string, number> = {};
      const active: number[] = [];
      for (let i = 0; i < n; i++) {
        const a = agents[i]!;
        const s = households[i]!.surplusWh[h]!;
        const d = households[i]!.deficitWh[h]!;
        if (s > 0) {
          const offer = s - Math.floor(s * a.seller.holdBackShare);
          if (offer > 0) {
            sellCaps[a.id] = offer;
            active.push(i);
          }
        }
        if (a.canBuy && d > 0) {
          buyCaps[a.id] = d;
          active.push(i);
        }
      }

      const engineConfig: EngineConfig = { sellCapsWh: sellCaps, buyCapsWh: buyCaps };
      const engine = new Engine(engineConfig);
      const events: EngineEvent[] = [];
      const record = cfg.recordEvents === true;
      const openOrder = new Map<number, { orderId: string; price: number }>();
      const doneWh = new Map<number, number>();
      let orderCounter = 0;

      for (let tick = 0; tick < cfg.ticksPerHour; tick++) {
        const order = active.slice();
        shuffleInPlace(rng, order);
        const filled = new Set<number>();

        for (const i of order) {
          const a = agents[i]!;
          const isSeller = sellCaps[a.id] !== undefined;
          const cap = isSeller ? sellCaps[a.id]! : buyCaps[a.id]!;
          const remaining = cap - (doneWh.get(i) ?? 0);
          if (remaining <= 0) continue;
          const price = Math.round(isSeller ? lo + a.seller.m * (hi - lo) : hi - a.buyer.mu * (hi - lo));
          const open = openOrder.get(i);
          if (open !== undefined && open.price === price) continue; // keep time priority
          if (open !== undefined) {
            const ev: EngineEvent = { type: "cancel", orderId: open.orderId, participantId: a.id };
            if (record) events.push(ev);
            const c = engine.apply(ev);
            if (!c.ok) throw new Error(`unexpected cancel failure: ${JSON.stringify(c)}`);
          }
          const orderId = `h${h}-${++orderCounter}`;
          const ev: EngineEvent = {
            type: "submit",
            order: { orderId, participantId: a.id, side: isSeller ? "sell" : "buy", price, qtyWh: remaining },
          };
          if (record) events.push(ev);
          const res = engine.apply(ev);
          if (!("trades" in res)) throw new Error(`unexpected submit failure: ${JSON.stringify(res)}`);
          openOrder.set(i, { orderId, price });
          for (const t of res.trades) {
            const bi = idToIndex.get(t.buyerId)!;
            const si = idToIndex.get(t.sellerId)!;
            doneWh.set(bi, (doneWh.get(bi) ?? 0) + t.qtyWh);
            doneWh.set(si, (doneWh.get(si) ?? 0) + t.qtyWh);
            filled.add(bi);
            filled.add(si);
            boughtH[bi]! += t.qtyWh;
            paidH[bi]! += t.amount;
            soldH[si]! += t.qtyWh;
            receivedH[si]! += t.amount;
            log.tradedWh += t.qtyWh;
            log.amount += t.amount;
            log.tradeCount += 1;
            log.minPrice = log.minPrice === null ? t.price : Math.min(log.minPrice, t.price);
            log.maxPrice = log.maxPrice === null ? t.price : Math.max(log.maxPrice, t.price);
            sumQ += t.qtyWh;
            sumPQ += t.price * t.qtyWh;
            sumP2Q += t.price * t.price * t.qtyWh;
            if (cfg.collectTrades) (log.trades ??= []).push(t);
          }
        }

        // Learning: shade more after a fill, improve the price after a miss.
        for (const i of order) {
          const a = agents[i]!;
          const isSeller = sellCaps[a.id] !== undefined;
          const cap = isSeller ? sellCaps[a.id]! : buyCaps[a.id]!;
          const remaining = cap - (doneWh.get(i) ?? 0);
          const didFill = filled.has(i);
          if (!didFill && remaining <= 0) continue;
          const step = (isSeller ? a.seller.beta : a.buyer.beta) * (1 + cfg.learningNoise * (2 * rng() - 1));
          if (isSeller) a.seller.m = clamp01(a.seller.m + (didFill ? step : -step));
          else a.buyer.mu = clamp01(a.buyer.mu + (didFill ? step : -step));
        }
      }

      const closeEvent: EngineEvent = { type: "close" };
      if (record) events.push(closeEvent);
      engine.apply(closeEvent);
      if (record) {
        log.engineConfig = engineConfig;
        log.events = events;
      }
    }

    // Settlement for this hour.
    for (let i = 0; i < n; i++) {
      const hh = households[i]!;
      const a = acc[i]!;
      const deficit = hh.deficitWh[h]!;
      const surplus = hh.surplusWh[h]!;
      a.costA += tradeAmount(hh.loadWh[h]!, buyPrice);
      a.costB += tradeAmount(deficit, buyPrice) - tradeAmount(surplus, exportPrice);
      const buyLeft = deficit - boughtH[i]!;
      const exportLeft = surplus - soldH[i]!;
      a.costC += tradeAmount(buyLeft, buyPrice) - tradeAmount(exportLeft, exportPrice) + paidH[i]! - receivedH[i]!;
      a.boughtWh += boughtH[i]!;
      a.soldWh += soldH[i]!;
      a.paid += paidH[i]!;
      a.received += receivedH[i]!;
      if (gridUp) {
        log.gridImportWh += buyLeft;
        log.gridExportWh += exportLeft;
        gridImportWhB += deficit;
        gridExportWhB += surplus;
      } else {
        log.unservedWh += buyLeft;
        log.curtailedWh += exportLeft;
      }
    }
    gridImportWh += log.gridImportWh;
    gridExportWh += log.gridExportWh;
    unservedWh += log.unservedWh;
    hours.push(log);
  }

  const agentResults: AgentResult[] = agents.map((a, i) => ({
    id: a.id,
    kind: a.kind,
    pvKwp: a.spec.pvKwp,
    generationWh: households[i]!.totals.generationWh,
    surplusWh: households[i]!.totals.surplusWh,
    deficitWh: households[i]!.totals.deficitWh,
    boughtWh: acc[i]!.boughtWh,
    soldWh: acc[i]!.soldWh,
    paid: acc[i]!.paid,
    received: acc[i]!.received,
    costA: acc[i]!.costA,
    costB: acc[i]!.costB,
    costC: acc[i]!.costC,
    premium: acc[i]!.costB - acc[i]!.costC,
  }));

  let surplusTrading = 0;
  let demandTrading = 0;
  let tradedWh = 0;
  let amount = 0;
  let tradeCount = 0;
  for (const l of hours) {
    tradedWh += l.tradedWh;
    amount += l.amount;
    tradeCount += l.tradeCount;
    if (trading.has(l.hour)) {
      surplusTrading += l.surplusWh;
      demandTrading += l.buyerDemandWh;
    }
  }
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
    gridImportWh,
    gridExportWh,
    gridImportWhB,
    gridExportWhB,
    unservedWh,
  };

  return { date: day.date, agents: agentResults, hours, metrics };
}
