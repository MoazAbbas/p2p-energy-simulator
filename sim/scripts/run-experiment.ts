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
