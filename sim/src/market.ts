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
