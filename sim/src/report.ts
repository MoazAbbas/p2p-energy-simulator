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
