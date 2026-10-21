#!/usr/bin/env bash
# Adds the prosumer-share experiment (sweep, CSV files, HTML report) to your existing sim/ folder, then runs all tests.
# Needs engine/ and sim/ with the bots step (setup-engine.sh, setup-sim.sh, setup-bots.sh).
# Run it from the repo root:  cd ~/projects/p2p-energy && bash setup-experiment.sh
set -euo pipefail

[ -f sim/src/market.ts ] || { echo "sim/src/market.ts not found - run setup-bots.sh first."; exit 1; }
[ -d sim/node_modules ] || { echo "sim/ not set up - run setup-sim.sh first."; exit 1; }
for f in src/synthetic.ts src/experiment.ts src/report.ts scripts/run-experiment.ts test/experiment.test.ts; do
  if [ -e "sim/$f" ]; then echo "sim/$f already exists - stopping so nothing is overwritten."; exit 1; fi
done

cat > sim/src/synthetic.ts <<'P2P_EOF'
/**
 * SYNTHETIC day profiles: a crude clear-sky solar model and a made-up temperature curve.
 * ONLY for testing the pipeline and for demos when PVGIS data has not been downloaded.
 * Results produced from this are NOT thesis results. Every output file says so.
 */
import type { DayProfile } from "./pvgis";

const CUMULATIVE_DAYS = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334];

export function syntheticDay(lat: number, lon: number, month: number): DayProfile {
  if (!Number.isInteger(month) || month < 1 || month > 12) throw new Error("month must be 1..12");
  const doy = CUMULATIVE_DAYS[month - 1]! + 15;
  const rad = Math.PI / 180;
  const decl = 23.44 * rad * Math.sin((2 * Math.PI * (284 + doy)) / 365);
  const meanTemp = 21 + 9 * Math.sin((2 * Math.PI * (doy - 105)) / 365) + (30 - lat) * 0.4;
  const whPerKwp: number[] = [];
  const t2m: number[] = [];
  for (let h = 0; h < 24; h++) {
    // Clock time is UTC+2 (meridian 30 E); solar time shifts 4 minutes per degree of longitude.
    const solarTime = h + 0.5 + (lon - 30) / 15;
    const hourAngle = 15 * rad * (solarTime - 12);
    const sinElev = Math.sin(lat * rad) * Math.sin(decl) + Math.cos(lat * rad) * Math.cos(decl) * Math.cos(hourAngle);
    whPerKwp.push(sinElev > 0 ? Math.round(800 * Math.pow(sinElev, 1.2)) : 0);
    t2m.push(Math.round((meanTemp + 7 * Math.cos((2 * Math.PI * (h - 15)) / 24)) * 10) / 10);
  }
  return { date: `2020-${String(month).padStart(2, "0")}-15`, utcOffsetHours: 2, whPerKwp, t2m };
}
P2P_EOF

cat > sim/src/experiment.ts <<'P2P_EOF'
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
P2P_EOF

cat > sim/src/report.ts <<'P2P_EOF'
/** CSV files and the self-contained HTML report (inline SVG charts, no external libraries). */
import {
  METRICS,
  METRIC_INFO,
  type BestRow,
  type ExperimentConfig,
  type MetricKey,
  type RunRow,
  type SummaryRow,
} from "./experiment";

export type DataSource = "pvgis" | "synthetic";

export interface ReportMeta {
  dataSource: DataSource;
  /** passed in by the caller so this module stays free of clocks */
  generatedAt: string;
  config: ExperimentConfig;
  locationNames: Readonly<Record<string, string>>;
}

const MONTH_NAMES = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

function cell(v: number | string | null): string {
  if (v === null) return "";
  if (typeof v === "number") return String(Number(v.toFixed(6)));
  return /[",\n]/.test(v) ? `"${v.replace(/"/g, '""')}"` : v;
}

function csv(header: readonly string[], rows: ReadonlyArray<ReadonlyArray<number | string | null>>): string {
  return [header.join(","), ...rows.map((r) => r.map(cell).join(","))].join("\n") + "\n";
}

export function runsCsv(rows: readonly RunRow[], source: DataSource): string {
  return csv(
    ["data_source", "location", "month", "date", "prosumer_share", "seed", "n", "prosumers", ...METRICS],
    rows.map((r) => [source, r.location, r.month, r.date, r.share, r.seed, r.n, r.prosumers, ...METRICS.map((k) => r.values[k])]),
  );
}

export function summaryCsv(rows: readonly SummaryRow[], source: DataSource): string {
  const sorted = [...rows].sort((a, b) => a.location.localeCompare(b.location) || a.month - b.month || a.share - b.share);
  return csv(
    ["data_source", "location", "month", "prosumer_share", "seeds", ...METRICS.flatMap((k) => [`${k}_mean`, `${k}_sd`])],
    sorted.map((r) => [source, r.location, r.month, r.share, r.k, ...METRICS.flatMap((k) => [r.mean[k], r.sd[k]])]),
  );
}

export function bestCsv(rows: readonly BestRow[], source: DataSource): string {
  return csv(
    [
      "data_source",
      "location",
      "month",
      "best_share_by_gain",
      "gain_egp_per_household_at_best",
      "balanced_shares",
      "crossover_share",
      "crossover_level",
    ],
    rows.map((r) => [
      source,
      r.location,
      r.month,
      r.bestShareByGain,
      r.gainAtBest,
      r.balancedShares.join(" "),
      r.crossoverShare,
      r.crossoverLevel,
    ]),
  );
}

function esc(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

interface ChartSeries {
  label: string;
  cls: string;
  dash: string;
  ys: Array<number | null>;
}

function chartSvg(title: string, xs: readonly number[], series: ChartSeries[], yMin: number, yMax: number, yFmt: (v: number) => string): string {
  const W = 360;
  const H = 230;
  const L = 48;
  const R = 12;
  const T = 30;
  const B = 34;
  const px = (x: number) => L + x * (W - L - R);
  const py = (y: number) => T + (1 - (y - yMin) / (yMax - yMin || 1)) * (H - T - B);
  const parts: string[] = [];
  parts.push(`<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="${esc(title)}">`);
  parts.push(`<text x="${L}" y="16" class="ct">${esc(title)}</text>`);
  for (let i = 0; i <= 4; i++) {
    const v = yMin + ((yMax - yMin) * i) / 4;
    parts.push(`<line x1="${L}" x2="${W - R}" y1="${py(v).toFixed(1)}" y2="${py(v).toFixed(1)}" class="grid"/>`);
    parts.push(`<text x="${L - 6}" y="${(py(v) + 3).toFixed(1)}" class="tick" text-anchor="end">${esc(yFmt(v))}</text>`);
  }
  for (const x of [0, 0.2, 0.4, 0.6, 0.8, 1]) {
    parts.push(`<text x="${px(x).toFixed(1)}" y="${H - 18}" class="tick" text-anchor="middle">${Math.round(x * 100)}%</text>`);
  }
  parts.push(`<text x="${(L + (W - L - R) / 2).toFixed(1)}" y="${H - 4}" class="tick" text-anchor="middle">households with PV</text>`);
  for (const s of series) {
    let path = "";
    let pen = false;
    s.ys.forEach((y, i) => {
      if (y === null) {
        pen = false;
        return;
      }
      path += `${pen ? "L" : "M"}${px(xs[i]!).toFixed(1)},${py(y).toFixed(1)} `;
      pen = true;
    });
    parts.push(`<path d="${path.trim()}" class="line ${s.cls}" stroke-dasharray="${s.dash}"/>`);
  }
  parts.push("</svg>");
  return parts.join("");
}

const CHARTS: Array<{ key: MetricKey; title: string; fixed01: boolean; fmt: (v: number) => string }> = [
  { key: "gainPerHouseholdEgp", title: "Total gain (EGP per household per day)", fixed01: false, fmt: (v) => v.toFixed(2) },
  { key: "surplusSoldShare", title: "Share of surplus sold P2P", fixed01: true, fmt: (v) => `${Math.round(v * 100)}%` },
  { key: "demandCoveredShare", title: "Share of demand covered P2P", fixed01: true, fmt: (v) => `${Math.round(v * 100)}%` },
  { key: "pricePosition", title: "Price position (0 = export rate, 1 = retail)", fixed01: true, fmt: (v) => v.toFixed(2) },
];

const SERIES_STYLE = [
  { cls: "s1", dash: "none" },
  { cls: "s2", dash: "6 3" },
  { cls: "s3", dash: "2 3" },
  { cls: "s4", dash: "8 3 2 3" },
  { cls: "s5", dash: "none" },
  { cls: "s6", dash: "6 3" },
];

export function renderReportHtml(
  summary: readonly SummaryRow[],
  best: readonly BestRow[],
  meta: ReportMeta,
): string {
  const cfg = meta.config;
  const t = cfg.market.tariff;
  const shares = [...new Set(summary.map((s) => s.share))].sort((a, b) => a - b);
  const synthetic = meta.dataSource === "synthetic";
  const name = (k: string) => meta.locationNames[k] ?? k;
  const out: string[] = [];

  out.push(`<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Ratio experiment</title>
<style>
:root{--bg:#fff;--fg:#1c1f23;--muted:#5b6470;--line:#d9dde3;--warn-bg:#fff3cd;--warn-fg:#664d03;--c1:#1f6feb;--c2:#d9480f;--c3:#2b8a3e;--c4:#8e44ad;--c5:#0b7285;--c6:#a61e4d}
@media (prefers-color-scheme:dark){:root{--bg:#14171a;--fg:#e6e8eb;--muted:#9aa4af;--line:#2d333b;--warn-bg:#3d3200;--warn-fg:#ffe08a;--c1:#58a6ff;--c2:#ff9b5e;--c3:#69db7c;--c4:#cc9bf0;--c5:#66d9e8;--c6:#faa2c1}}
body{margin:0;padding:16px;background:var(--bg);color:var(--fg);font:15px/1.5 system-ui,sans-serif;max-width:1100px;margin-inline:auto}
h1{font-size:1.4rem;margin:.2em 0}h2{font-size:1.15rem;margin:1.6em 0 .4em}h3{font-size:1rem;margin:1.2em 0 .3em}
.warn{background:var(--warn-bg);color:var(--warn-fg);padding:10px 14px;border-radius:8px;margin:12px 0}
.muted{color:var(--muted)}.scroll{overflow-x:auto}table{border-collapse:collapse;margin:8px 0;font-size:.9rem}td,th{border:1px solid var(--line);padding:4px 8px;text-align:left}
.grid-charts{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:12px}
svg{width:100%;height:auto}.ct{font-size:11px;fill:var(--fg);font-weight:600}.tick{font-size:10px;fill:var(--muted)}.grid{stroke:var(--line);stroke-width:1}
.line{fill:none;stroke-width:2}.s1{stroke:var(--c1)}.s2{stroke:var(--c2)}.s3{stroke:var(--c3)}.s4{stroke:var(--c4)}.s5{stroke:var(--c5)}.s6{stroke:var(--c6)}
.legend span{display:inline-block;margin-right:14px}.legend svg{width:34px;height:10px;vertical-align:middle}
</style></head><body>
<h1>Prosumer share experiment</h1>
<p class="muted">Generated ${esc(meta.generatedAt)}. Simulation only: energy and money are virtual.</p>`);

  out.push(
    synthetic
      ? `<div class="warn"><b>SYNTHETIC DATA.</b> These curves come from a crude made-up solar and temperature model, not from PVGIS. They only demonstrate the pipeline and are not results.</div>`
      : `<div class="warn"><b>Assumptions are placeholders.</b> PVGIS generation is a model estimate, not meter data. Household load shapes, cooling sensitivity, tariffs and bot parameters are placeholder values until calibrated. Treat the numbers as the behaviour of this model, not as predictions for Egypt.</div>`,
  );

  out.push(`<h2>Setup</h2><div class="scroll"><table>
<tr><th>Households per community</th><td>${cfg.n}</td></tr>
<tr><th>Prosumer shares tested</th><td>${shares.map((s) => `${Math.round(s * 100)}%`).join(", ")}</td></tr>
<tr><th>Random seeds per cell</th><td>${cfg.seeds}</td></tr>
<tr><th>Representative days</th><td>the 15th of ${cfg.months.map((m) => MONTH_NAMES[m - 1]).join(", ")}</td></tr>
<tr><th>Trading hours</th><td>${cfg.market.tradingHours.map((h) => `${String(h).padStart(2, "0")}:00`).join(", ")} (${cfg.market.ticksPerHour} rounds per hour)</td></tr>
<tr><th>Retail tariff / export rate</th><td>${t.retail} / ${t.export} piastres per kWh (placeholders)</td></tr>
<tr><th>Market rule</th><td>continuous double auction, trades at the resting order's price</td></tr>
<tr><th>Outage</th><td>${cfg.market.outage ? `hours ${cfg.market.outage.hours.join(", ")}, ceiling x${cfg.market.outage.ceilingMultiplierPermille / 1000}` : "none"}</td></tr>
</table></div>`);

  out.push(`<h2>Best share by location and month</h2>
<p class="muted">"Best by gain" is the prosumer share with the highest mean total gain. "Crossover" is the share where the fraction of surplus sold equals the fraction of demand covered (a balance point), with that common level in brackets. "80/80 band" lists shares where both fractions reach 80%; without storage, afternoon demand can often not reach that level at any share. Other objectives can be read from the charts and the CSV files.</p>
<div class="scroll"><table><tr><th>Location</th><th>Month</th><th>Best share by gain</th><th>Gain at best (EGP/household/day)</th><th>Crossover share (level)</th><th>80/80 band</th></tr>`);
  for (const b of [...best].sort((x, y) => x.location.localeCompare(y.location) || x.month - y.month)) {
    const cross =
      b.crossoverShare !== null && b.crossoverLevel !== null
        ? `${Math.round(b.crossoverShare * 100)}% (${Math.round(b.crossoverLevel * 100)}%)`
        : "no crossing";
    out.push(
      `<tr><td>${esc(name(b.location))}</td><td>${MONTH_NAMES[b.month - 1]}</td><td>${Math.round(b.bestShareByGain * 100)}%</td><td>${b.gainAtBest.toFixed(2)}</td><td>${cross}</td><td>${b.balancedShares.length ? b.balancedShares.map((s) => `${Math.round(s * 100)}%`).join(", ") : "none"}</td></tr>`,
    );
  }
  out.push("</table></div>");

  out.push(`<h2>Charts</h2><p class="legend muted">`);
  cfg.months.forEach((m, i) => {
    const st = SERIES_STYLE[i % SERIES_STYLE.length]!;
    out.push(`<span><svg viewBox="0 0 34 10"><path d="M0,5 L34,5" class="line ${st.cls}" stroke-dasharray="${st.dash}"/></svg> ${MONTH_NAMES[m - 1]}</span>`);
  });
  out.push(`</p>`);

  for (const loc of cfg.locations) {
    out.push(`<h3>${esc(name(loc))}</h3><div class="grid-charts">`);
    for (const ch of CHARTS) {
      const series: ChartSeries[] = cfg.months.map((m, i) => {
        const st = SERIES_STYLE[i % SERIES_STYLE.length]!;
        const ys = shares.map((sh) => summary.find((s) => s.location === loc && s.month === m && s.share === sh)?.mean[ch.key] ?? null);
        return { label: MONTH_NAMES[m - 1]!, cls: st.cls, dash: st.dash, ys };
      });
      const all = series.flatMap((s) => s.ys).filter((v): v is number => v !== null);
      const top = Math.max(...all, 0);
      const yMax = ch.fixed01 ? Math.max(1, top) : top > 0 ? top * 1.1 : 1;
      out.push(`<div>${chartSvg(ch.title, shares, series, 0, yMax, ch.fmt)}</div>`);
    }
    out.push("</div>");
  }

  out.push(`<h2>Metric definitions</h2><div class="scroll"><table>`);
  for (const k of METRICS) out.push(`<tr><th>${k}</th><td>${esc(METRIC_INFO[k])}</td></tr>`);
  out.push(`</table></div></body></html>`);
  return out.join("\n");
}
P2P_EOF

cat > sim/scripts/run-experiment.ts <<'P2P_EOF'
/**
 * Runs the prosumer-share experiment and writes runs.csv, summary.csv, best.csv and report.html.
 *
 *   npm run experiment                      uses the PVGIS files in data/pvgis (run npm run fetch-pvgis first)
 *   npm run experiment -- --synthetic       pipeline demo on made-up weather (NOT real results)
 *
 * Options (all optional):
 *   --n 100                 households per community
 *   --seeds 20              random seeds per cell
 *   --months 1,4,7,10       representative days (the 15th of each month)
 *   --locations alexandria,cairo,new-valley
 *   --shares 0.02,0.05,...  prosumer shares to test
 *   --retail 200 --export 100   tariff in piastres per kWh (PLACEHOLDERS until official figures are used)
 *   --ticks 12              auction rounds per trading hour
 *   --out <folder>          default <repo>/results (or results-synthetic with --synthetic)
 */
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { analyze, runExperiment, summarize, type ExperimentConfig } from "../src/experiment";
import { LOCATIONS, PVGIS_SETTINGS } from "../src/locations";
import { DEFAULT_MARKET } from "../src/market";
import { extractDay, parsePvgis, representativeDay, type DayProfile } from "../src/pvgis";
import { bestCsv, renderReportHtml, runsCsv, summaryCsv, type DataSource } from "../src/report";
import { syntheticDay } from "../src/synthetic";

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, "../..");

function parseArgs(argv: string[]): Map<string, string> {
  const m = new Map<string, string>();
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]!;
    if (!a.startsWith("--")) throw new Error(`unexpected argument: ${a}`);
    const key = a.slice(2);
    const next = argv[i + 1];
    if (next === undefined || next.startsWith("--")) m.set(key, "true");
    else {
      m.set(key, next);
      i++;
    }
  }
  return m;
}

const args = parseArgs(process.argv.slice(2));
const num = (k: string, d: number): number => {
  const v = args.get(k);
  if (v === undefined) return d;
  const x = Number(v);
  if (!Number.isFinite(x)) throw new Error(`--${k} must be a number`);
  return x;
};
const list = (k: string): string[] | undefined => args.get(k)?.split(",").map((s) => s.trim()).filter(Boolean);

const synthetic = args.get("synthetic") === "true";
const source: DataSource = synthetic ? "synthetic" : "pvgis";
const locKeys = list("locations") ?? LOCATIONS.map((l) => l.key);
for (const k of locKeys) {
  if (!LOCATIONS.some((l) => l.key === k)) throw new Error(`unknown location "${k}" (known: ${LOCATIONS.map((l) => l.key).join(", ")})`);
}

const config: ExperimentConfig = {
  n: num("n", 100),
  seeds: num("seeds", 20),
  months: (list("months") ?? ["1", "4", "7", "10"]).map(Number),
  locations: locKeys,
  shares: (list("shares") ?? ["0.02", "0.05", "0.1", "0.15", "0.2", "0.3", "0.4", "0.5", "0.6", "0.8", "0.95"]).map(Number),
  market: {
    ...DEFAULT_MARKET,
    tariff: { retail: num("retail", DEFAULT_MARKET.tariff.retail), export: num("export", DEFAULT_MARKET.tariff.export) },
    ticksPerHour: num("ticks", DEFAULT_MARKET.ticksPerHour),
  },
};

async function loadDays(): Promise<(location: string, month: number) => DayProfile> {
  const days = new Map<string, DayProfile>();
  for (const key of locKeys) {
    const loc = LOCATIONS.find((l) => l.key === key)!;
    if (synthetic) {
      for (const month of config.months) days.set(`${key}|${month}`, syntheticDay(loc.lat, loc.lon, month));
      continue;
    }
    const file = path.join(repoRoot, "data", "pvgis", `${key}_${PVGIS_SETTINGS.year}.json`);
    let text: string;
    try {
      text = await readFile(file, "utf8");
    } catch {
      throw new Error(
        `Missing ${file}\nRun "npm run fetch-pvgis" first (needs internet), or add --synthetic for a pipeline demo that is NOT real data.`,
      );
    }
    const series = parsePvgis(JSON.parse(text), { peakPowerKw: PVGIS_SETTINGS.peakPowerKw });
    for (const month of config.months) days.set(`${key}|${month}`, extractDay(series, representativeDay(month)));
  }
  return (location, month) => {
    const d = days.get(`${location}|${month}`);
    if (!d) throw new Error(`no day for ${location} month ${month}`);
    return d;
  };
}

const dayFor = await loadDays();
if (synthetic) console.log("*** SYNTHETIC DATA: made-up weather, for testing the pipeline only. Not thesis results. ***");
const total = config.locations.length * config.months.length * config.shares.length * config.seeds;
console.log(`Running ${total} simulated days...`);
const started = Date.now();
const rows = runExperiment(config, dayFor, (done) => process.stdout.write(`\r${done}/${total}`));
console.log(`\rDone: ${rows.length} days in ${((Date.now() - started) / 1000).toFixed(1)} s`);

const summary = summarize(rows);
const best = analyze(summary);
const outDir = path.resolve(args.get("out") ?? path.join(repoRoot, synthetic ? "results-synthetic" : "results"));
await mkdir(outDir, { recursive: true });
const names = Object.fromEntries(LOCATIONS.map((l) => [l.key, l.name]));
await writeFile(path.join(outDir, "runs.csv"), runsCsv(rows, source));
await writeFile(path.join(outDir, "summary.csv"), summaryCsv(summary, source));
await writeFile(path.join(outDir, "best.csv"), bestCsv(best, source));
await writeFile(
  path.join(outDir, "report.html"),
  renderReportHtml(summary, best, { dataSource: source, generatedAt: new Date().toISOString(), config, locationNames: names }),
);

console.log("\nBest prosumer share by mean total gain (and the balanced band):");
for (const b of [...best].sort((x, y) => x.location.localeCompare(y.location) || x.month - y.month)) {
  console.log(
    `  ${(names[b.location] ?? b.location).padEnd(30)} month ${String(b.month).padStart(2)}: best ${String(Math.round(b.bestShareByGain * 100)).padStart(3)}%  ` +
      `gain ${b.gainAtBest.toFixed(2)} EGP/household/day  ` +
      `crossover ${b.crossoverShare === null ? "none" : `${Math.round(b.crossoverShare * 100)}% (level ${Math.round((b.crossoverLevel ?? 0) * 100)}%)`}`,
  );
}
console.log(`\nFiles written to ${outDir}: runs.csv, summary.csv, best.csv, report.html`);
P2P_EOF

cat > sim/test/experiment.test.ts <<'P2P_EOF'
import { describe, expect, it } from "vitest";
import {
  METRICS,
  analyze,
  gini,
  mean,
  runExperiment,
  sampleSd,
  summarize,
  validateExperiment,
  type ExperimentConfig,
  type MetricValues,
  type SummaryRow,
} from "../src/experiment";
import { DEFAULT_MARKET } from "../src/market";
import { bestCsv, renderReportHtml, runsCsv, summaryCsv } from "../src/report";
import { syntheticDay } from "../src/synthetic";

const COORDS: Record<string, [number, number]> = { cairo: [30.04, 31.24], valley: [25.45, 30.55] };
const dayFor = (loc: string, month: number) => syntheticDay(COORDS[loc]![0], COORDS[loc]![1], month);

const small: ExperimentConfig = {
  n: 40,
  shares: [0.05, 0.5],
  seeds: 3,
  locations: ["cairo", "valley"],
  months: [1, 7],
  market: DEFAULT_MARKET,
};

describe("synthetic weather (for pipeline tests only)", () => {
  it("has no sun at night, a midday peak, and more yield in summer than winter", () => {
    const jul = syntheticDay(30.04, 31.24, 7);
    const jan = syntheticDay(30.04, 31.24, 1);
    expect(jul.whPerKwp[0]).toBe(0);
    expect(jul.whPerKwp[23]).toBe(0);
    const peakHour = jul.whPerKwp.indexOf(Math.max(...jul.whPerKwp));
    expect(peakHour).toBeGreaterThanOrEqual(11);
    expect(peakHour).toBeLessThanOrEqual(13);
    const sum = (d: { whPerKwp: number[] }) => d.whPerKwp.reduce((a, b) => a + b, 0);
    expect(sum(jul)).toBeGreaterThan(sum(jan));
  });

  it("is hotter in the south than on the coast in July", () => {
    const south = syntheticDay(25.45, 30.55, 7);
    const coast = syntheticDay(31.2, 29.92, 7);
    expect(Math.max(...south.t2m)).toBeGreaterThan(Math.max(...coast.t2m));
  });
});

describe("statistics helpers", () => {
  it("mean and sample standard deviation", () => {
    expect(mean([])).toBeNull();
    expect(mean([1, 2, 3])).toBe(2);
    expect(sampleSd([5])).toBe(0);
    expect(sampleSd([2, 4, 4, 4, 5, 5, 7, 9])).toBeCloseTo(2.138, 3);
  });

  it("gini coefficient", () => {
    expect(gini([1, 1, 1, 1])).toBeCloseTo(0, 12);
    expect(gini([0, 0, 0, 4])).toBeCloseTo(0.75, 12);
    expect(gini([])).toBeNull();
    expect(gini([0, 0])).toBeNull();
    expect(() => gini([-1, 2])).toThrow();
  });
});

describe("experiment configuration", () => {
  it("rejects invalid settings", () => {
    expect(() => validateExperiment(small)).not.toThrow();
    expect(() => validateExperiment({ ...small, n: 1 })).toThrow();
    expect(() => validateExperiment({ ...small, seeds: 0 })).toThrow();
    expect(() => validateExperiment({ ...small, shares: [1.5] })).toThrow();
    expect(() => validateExperiment({ ...small, months: [13] })).toThrow();
    expect(() => validateExperiment({ ...small, locations: [] })).toThrow();
  });
});

describe("running a sweep", () => {
  const rows = runExperiment(small, dayFor);

  it("produces one row per location x month x share x seed", () => {
    expect(rows).toHaveLength(2 * 2 * 2 * 3);
    expect(new Set(rows.map((r) => `${r.location}|${r.month}|${r.share}|${r.seed}`)).size).toBe(rows.length);
    for (const r of rows) {
      expect(r.prosumers).toBe(Math.round(r.n * r.share));
      for (const k of METRICS) expect(Object.prototype.hasOwnProperty.call(r.values, k)).toBe(true);
    }
  });

  it("is reproducible", () => {
    expect(JSON.stringify(runExperiment(small, dayFor))).toBe(JSON.stringify(rows));
  });

  it("reports sensible metric ranges", () => {
    for (const r of rows) {
      const v = r.values;
      for (const k of ["surplusSoldShare", "demandCoveredShare", "gridImportReduction", "gridExportReduction"] as const) {
        if (v[k] !== null) {
          expect(v[k]!).toBeGreaterThanOrEqual(-1e-9);
          expect(v[k]!).toBeLessThanOrEqual(1 + 1e-9);
        }
      }
      expect(v.gainPerHouseholdEgp!).toBeGreaterThanOrEqual(-0.01);
      if (v.vwap !== null) {
        expect(v.vwap).toBeGreaterThanOrEqual(DEFAULT_MARKET.tariff.export);
        expect(v.vwap).toBeLessThanOrEqual(DEFAULT_MARKET.tariff.retail);
      }
    }
  });

  it("summarises across seeds", () => {
    const sum = summarize(rows);
    expect(sum).toHaveLength(2 * 2 * 2);
    const cell = sum.find((s) => s.location === "cairo" && s.month === 7 && s.share === 0.5)!;
    expect(cell.k).toBe(3);
    const manual = mean(
      rows.filter((r) => r.location === "cairo" && r.month === 7 && r.share === 0.5).map((r) => r.values.tradedKwh!),
    );
    expect(cell.mean.tradedKwh).toBeCloseTo(manual!, 9);
  });

  it("more prosumers means more supply per unit of demand and cheaper prices", () => {
    const sum = summarize(rows);
    const at = (share: number) => sum.find((s) => s.location === "cairo" && s.month === 7 && s.share === share)!;
    expect(at(0.5).mean.surplusToDemand!).toBeGreaterThan(at(0.05).mean.surplusToDemand!);
    expect(at(0.5).mean.pricePosition!).toBeLessThan(at(0.05).mean.pricePosition!);
    expect(at(0.5).mean.surplusSoldShare!).toBeLessThan(at(0.05).mean.surplusSoldShare!);
  });
});

describe("the gain has an interior optimum over the prosumer share", () => {
  it("is neither at the lowest nor the highest share tested", () => {
    const cfg: ExperimentConfig = { ...small, shares: [0.02, 0.1, 0.5, 0.95], locations: ["cairo"], months: [7], seeds: 5 };
    const best = analyze(summarize(runExperiment(cfg, dayFor)));
    expect(best).toHaveLength(1);
    expect(best[0]!.bestShareByGain).toBeGreaterThan(0.02);
    expect(best[0]!.bestShareByGain).toBeLessThan(0.95);
  });
});

describe("analyze", () => {
  const mk = (share: number, gain: number, sold: number, covered: number): SummaryRow => {
    const empty = Object.fromEntries(METRICS.map((k) => [k, null])) as MetricValues;
    return {
      location: "x",
      month: 7,
      share,
      k: 1,
      mean: { ...empty, gainPerHouseholdEgp: gain, surplusSoldShare: sold, demandCoveredShare: covered },
      sd: empty,
    };
  };

  it("picks the highest gain and lists balanced shares", () => {
    const rows = [mk(0.5, 3, 0.3, 1), mk(0.1, 5, 0.9, 0.85), mk(0.05, 2, 1, 0.3), mk(0.2, 4, 0.82, 0.95)];
    const [b] = analyze(rows);
    expect(b!.bestShareByGain).toBe(0.1);
    expect(b!.gainAtBest).toBe(5);
    expect(b!.balancedShares).toEqual([0.1, 0.2]);
  });

  it("reports no balanced share when none reaches the threshold", () => {
    expect(analyze([mk(0.1, 1, 0.5, 0.5)])[0]!.balancedShares).toEqual([]);
  });

  it("finds where the sold share and the covered share cross, by interpolation", () => {
    // d = sold - covered: +0.4 at 10%, -0.2 at 20%  ->  crosses 2/3 of the way: 10% + 10% * 0.4/0.6
    const [b] = analyze([mk(0.1, 1, 0.9, 0.5), mk(0.2, 1, 0.5, 0.7)]);
    expect(b!.crossoverShare).toBeCloseTo(0.1 + (0.1 * 0.4) / 0.6, 9);
    expect(b!.crossoverLevel).toBeCloseTo(0.9 + (0.5 - 0.9) * (0.4 / 0.6), 9);
  });

  it("has no crossover when the curves never cross", () => {
    const [b] = analyze([mk(0.1, 1, 0.9, 0.2), mk(0.2, 1, 0.8, 0.3)]);
    expect(b!.crossoverShare).toBeNull();
    expect(b!.crossoverLevel).toBeNull();
  });
});

describe("output files", () => {
  const rows = runExperiment(small, dayFor);
  const summary = summarize(rows);
  const best = analyze(summary);
  const meta = {
    dataSource: "synthetic" as const,
    generatedAt: "2026-01-01T00:00:00Z",
    config: small,
    locationNames: { cairo: "Cairo", valley: "New <Valley> & co" },
  };

  it("CSV rows all have as many cells as the header and carry the data source", () => {
    for (const text of [runsCsv(rows, "synthetic"), summaryCsv(summary, "synthetic"), bestCsv(best, "synthetic")]) {
      const lines = text.trim().split("\n");
      const width = lines[0]!.split(",").length;
      expect(lines.length).toBeGreaterThan(1);
      for (const l of lines) expect(l.split(",").length).toBe(width);
      expect(lines[1]!.startsWith("synthetic,")).toBe(true);
      expect(text).not.toMatch(/NaN|undefined|Infinity/);
    }
  });

  it("the report warns about synthetic data, has charts, and escapes text", () => {
    const html = renderReportHtml(summary, best, meta);
    expect(html).toContain("SYNTHETIC DATA");
    expect(html).toContain("New &lt;Valley&gt; &amp; co");
    expect(html).not.toContain("New <Valley>");
    expect((html.match(/role="img"/g) ?? []).length).toBe(2 * 4); // 2 locations x 4 charts
    expect(html).not.toMatch(/NaN|undefined|Infinity/);
  });

  it("the report for PVGIS data states that assumptions are placeholders instead", () => {
    const html = renderReportHtml(summary, best, { ...meta, dataSource: "pvgis" });
    expect(html).not.toContain("SYNTHETIC DATA");
    expect(html).toContain("placeholder");
  });
});
P2P_EOF

cd sim
npm pkg set scripts.experiment="tsx scripts/run-experiment.ts"
echo "Type check..."
npm run typecheck
echo "Running all tests..."
npm test
echo "Done. Try:  cd sim && npm run experiment -- --synthetic --seeds 3   (demo on made-up weather)"
echo "Real run (after npm run fetch-pvgis):  npm run experiment"
