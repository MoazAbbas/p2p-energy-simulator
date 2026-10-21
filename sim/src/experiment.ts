/**
 * The prosumer:consumer ratio experiment.
 * For every location x month x prosumer share x random seed, one simulated day is run on a fresh
 * community, and a row of market metrics is recorded. Rows are then summarised across seeds.
 * This runs the Engine in-process (not through Fabric), so thousands of days take seconds.
 *
 * "Best" depends on the objective, so several are computed; see analyze().
 */
import { makePopulation, DEFAULT_POPULATION, type PopulationConfig } from "./agents";
import { DEFAULT_LOAD_PARAMS, type LoadParams } from "./household";
import { simulateDay, validateMarket, type DayResult, type MarketConfig } from "./market";
import type { DayProfile } from "./pvgis";
import { mulberry32 } from "./rng";

export const METRICS = [
  "tradedKwh",
  "surplusSoldShare",
  "demandCoveredShare",
  "gainPerHouseholdEgp",
  "vwap",
  "pricePosition",
  "priceStdDev",
  "gridImportReduction",
  "gridExportReduction",
  "sellerRevenueGini",
  "prosumerPremiumMean",
  "consumerPremiumMean",
  "surplusToDemand",
] as const;
export type MetricKey = (typeof METRICS)[number];
export type MetricValues = Record<MetricKey, number | null>;

/** What each metric means (also used in the report). */
export const METRIC_INFO: Record<MetricKey, string> = {
  tradedKwh: "Energy traded between households, kWh per day",
  surplusSoldShare: "Share of all surplus in trading hours that was sold P2P (rest is exported)",
  demandCoveredShare: "Share of buyer demand in trading hours that was met P2P (rest is bought from the utility)",
  gainPerHouseholdEgp: "Total benefit over exporting/buying from the utility, EGP per household per day",
  vwap: "Volume-weighted average trade price, piastres per kWh",
  pricePosition: "(average price - export rate) / (retail - export rate): 0 = sellers get only the export rate, 1 = buyers pay full retail",
  priceStdDev: "Volume-weighted standard deviation of trade prices, piastres per kWh",
  gridImportReduction: "1 - utility imports with P2P / utility imports without P2P",
  gridExportReduction: "1 - utility exports with P2P / utility exports without P2P",
  sellerRevenueGini: "Inequality of P2P revenue per kWp among prosumers (0 = equal, 1 = one seller takes all)",
  prosumerPremiumMean: "Mean benefit per prosumer over always-export, piastres per day",
  consumerPremiumMean: "Mean benefit per consumer over buying from the utility, piastres per day",
  surplusToDemand: "Energy ratio: all surplus / all buyer demand in trading hours (above 1 = more supply than demand)",
};

export interface ExperimentConfig {
  n: number;
  /** prosumer shares to test, each 0..1 */
  shares: readonly number[];
  /** seeds 1..seeds are used for every cell */
  seeds: number;
  locations: readonly string[];
  /** months 1..12; the 15th is the representative day */
  months: readonly number[];
  market: MarketConfig;
  population?: Partial<Omit<PopulationConfig, "n" | "prosumerShare" | "seed">>;
  loadParams?: LoadParams;
}

export type DayProvider = (location: string, month: number) => DayProfile;

export interface RunRow {
  location: string;
  month: number;
  date: string;
  share: number;
  seed: number;
  n: number;
  prosumers: number;
  values: MetricValues;
}

export interface SummaryRow {
  location: string;
  month: number;
  share: number;
  /** number of seeds */
  k: number;
  mean: MetricValues;
  sd: MetricValues;
}

export interface BestRow {
  location: string;
  month: number;
  /** share with the highest mean total gain */
  bestShareByGain: number;
  gainAtBest: number;
  /** shares where both surplus sold and demand covered reach the threshold */
  balancedShares: number[];
  /**
   * Prosumer share at which the sold share and the covered share are equal (linear interpolation between
   * tested shares); null if the curves never cross. Both shares at that point equal `crossoverLevel`.
   */
  crossoverShare: number | null;
  crossoverLevel: number | null;
}

export function mean(values: readonly number[]): number | null {
  return values.length === 0 ? null : values.reduce((a, b) => a + b, 0) / values.length;
}

export function sampleSd(values: readonly number[]): number | null {
  if (values.length === 0) return null;
  if (values.length === 1) return 0;
  const m = values.reduce((a, b) => a + b, 0) / values.length;
  return Math.sqrt(values.reduce((s, v) => s + (v - m) * (v - m), 0) / (values.length - 1));
}

/** Gini coefficient of non-negative values; null when undefined (no values, or all zero). */
export function gini(values: readonly number[]): number | null {
  const n = values.length;
  if (n === 0) return null;
  const sorted = [...values].sort((a, b) => a - b);
  if (sorted[0]! < 0) throw new Error("gini needs non-negative values");
  const sum = sorted.reduce((a, b) => a + b, 0);
  if (sum === 0) return null;
  let weighted = 0;
  sorted.forEach((v, i) => (weighted += (i + 1) * v));
  return (2 * weighted) / (n * sum) - (n + 1) / n;
}

export function validateExperiment(cfg: ExperimentConfig): void {
  if (!Number.isInteger(cfg.n) || cfg.n < 2) throw new Error("n must be an integer of at least 2");
  if (!Number.isInteger(cfg.seeds) || cfg.seeds < 1) throw new Error("seeds must be a positive integer");
  if (cfg.shares.length === 0 || cfg.shares.some((s) => !(s >= 0 && s <= 1))) throw new Error("shares must be within 0..1");
  if (cfg.locations.length === 0) throw new Error("at least one location is needed");
  if (cfg.months.length === 0 || cfg.months.some((m) => !Number.isInteger(m) || m < 1 || m > 12)) {
    throw new Error("months must be integers 1..12");
  }
  validateMarket(cfg.market);
}

export function metricsOf(result: DayResult, n: number, tradingHours: ReadonlySet<number>): MetricValues {
  const m = result.metrics;
  const prosumers = result.agents.filter((a) => a.kind === "prosumer");
  const consumers = result.agents.filter((a) => a.kind === "consumer");
  let surplus = 0;
  let demand = 0;
  for (const l of result.hours) {
    if (tradingHours.has(l.hour)) {
      surplus += l.surplusWh;
      demand += l.buyerDemandWh;
    }
  }
  const revenuePerKwp = prosumers.map((a) => a.received / a.pvKwp);
  return {
    tradedKwh: m.tradedWh / 1000,
    surplusSoldShare: m.surplusSoldShare,
    demandCoveredShare: m.demandCoveredShare,
    gainPerHouseholdEgp: m.totalGain / n / 100,
    vwap: m.vwap,
    pricePosition: m.pricePosition,
    priceStdDev: m.priceStdDev,
    gridImportReduction: m.gridImportWhB > 0 ? 1 - m.gridImportWh / m.gridImportWhB : null,
    gridExportReduction: m.gridExportWhB > 0 ? 1 - m.gridExportWh / m.gridExportWhB : null,
    sellerRevenueGini: gini(revenuePerKwp),
    prosumerPremiumMean: mean(prosumers.map((a) => a.premium)),
    consumerPremiumMean: mean(consumers.map((a) => a.premium)),
    surplusToDemand: demand > 0 ? surplus / demand : null,
  };
}

export function runExperiment(
  cfg: ExperimentConfig,
  dayFor: DayProvider,
  onProgress?: (done: number, total: number) => void,
): RunRow[] {
  validateExperiment(cfg);
  const tradingHours = new Set(cfg.market.tradingHours);
  const total = cfg.locations.length * cfg.months.length * cfg.shares.length * cfg.seeds;
  const rows: RunRow[] = [];
  let done = 0;
  for (const location of cfg.locations) {
    for (const month of cfg.months) {
      const day = dayFor(location, month);
      for (const share of cfg.shares) {
        for (let seed = 1; seed <= cfg.seeds; seed++) {
          const pop = makePopulation({
            n: cfg.n,
            prosumerShare: share,
            seed,
            ...DEFAULT_POPULATION,
            ...cfg.population,
          });
          const result = simulateDay(pop, day, cfg.market, mulberry32(seed + 1000), cfg.loadParams ?? DEFAULT_LOAD_PARAMS);
          rows.push({
            location,
            month,
            date: day.date,
            share,
            seed,
            n: cfg.n,
            prosumers: pop.filter((a) => a.kind === "prosumer").length,
            values: metricsOf(result, cfg.n, tradingHours),
          });
          done++;
          if (onProgress && done % 100 === 0) onProgress(done, total);
        }
      }
    }
  }
  return rows;
}

export function summarize(rows: readonly RunRow[]): SummaryRow[] {
  const groups = new Map<string, RunRow[]>();
  for (const r of rows) {
    const key = `${r.location}|${r.month}|${r.share}`;
    const g = groups.get(key);
    if (g) g.push(r);
    else groups.set(key, [r]);
  }
  const out: SummaryRow[] = [];
  for (const g of groups.values()) {
    const first = g[0]!;
    const meanV = {} as MetricValues;
    const sdV = {} as MetricValues;
    for (const key of METRICS) {
      const vals = g.map((r) => r.values[key]).filter((v): v is number => v !== null);
      meanV[key] = mean(vals);
      sdV[key] = sampleSd(vals);
    }
    out.push({ location: first.location, month: first.month, share: first.share, k: g.length, mean: meanV, sd: sdV });
  }
  return out;
}

/**
 * Per location and month: the share that maximises mean total gain, and the shares where the market
 * is "balanced" (both sold and covered shares reach `threshold`).
 */
export function analyze(summary: readonly SummaryRow[], threshold = 0.8): BestRow[] {
  const groups = new Map<string, SummaryRow[]>();
  for (const s of summary) {
    const key = `${s.location}|${s.month}`;
    const g = groups.get(key);
    if (g) g.push(s);
    else groups.set(key, [s]);
  }
  const out: BestRow[] = [];
  for (const g of groups.values()) {
    const sorted = [...g].sort((a, b) => a.share - b.share);
    let best = sorted[0]!;
    for (const s of sorted) {
      if ((s.mean.gainPerHouseholdEgp ?? -Infinity) > (best.mean.gainPerHouseholdEgp ?? -Infinity)) best = s;
    }
    let crossoverShare: number | null = null;
    let crossoverLevel: number | null = null;
    for (let i = 0; i + 1 < sorted.length; i++) {
      const a = sorted[i]!;
      const b = sorted[i + 1]!;
      const sa = a.mean.surplusSoldShare;
      const ca = a.mean.demandCoveredShare;
      const sb = b.mean.surplusSoldShare;
      const cb = b.mean.demandCoveredShare;
      if (sa === null || ca === null || sb === null || cb === null) continue;
      const da = sa - ca;
      const db = sb - cb;
      if (da >= 0 && db < 0) {
        const t = da / (da - db);
        crossoverShare = a.share + (b.share - a.share) * t;
        crossoverLevel = sa + (sb - sa) * t;
        break;
      }
    }
    out.push({
      location: best.location,
      month: best.month,
      bestShareByGain: best.share,
      gainAtBest: best.mean.gainPerHouseholdEgp ?? 0,
      balancedShares: sorted
        .filter((s) => (s.mean.surplusSoldShare ?? 0) >= threshold && (s.mean.demandCoveredShare ?? 0) >= threshold)
        .map((s) => s.share),
      crossoverShare,
      crossoverLevel,
    });
  }
  return out;
}
