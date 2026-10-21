#!/usr/bin/env bash
# Creates the sim/ package (PVGIS reader, household energy model, PVGIS download script) and runs its tests.
# Run it from the repo root:  cd ~/projects/p2p-energy && bash setup-sim.sh
set -euo pipefail

if [ -e sim ]; then
  echo "sim/ already exists - stopping so nothing is overwritten."
  exit 1
fi

mkdir -p sim/src sim/test sim/scripts data/pvgis

cat > sim/src/pvgis.ts <<'P2P_EOF'
/**
 * Reads PVGIS hourly series (the "seriescalc" API, outputformat=json) and extracts one
 * local day of 24 hourly values.
 *
 * PVGIS values are MODEL ESTIMATES for a hypothetical PV system, not meter readings.
 * We request peakpower=1 (kW), so "P" is the output in W of a 1 kWp system, i.e. Wh per hour per kWp.
 * PVGIS timestamps are UTC (e.g. "20200715:1010" = 15 July 2020, 10:10 UTC; the :10 is how PVGIS labels the hour).
 */

export interface HourlyPoint {
  /** Wh produced in this hour by a 1 kWp system (rounded to an integer) */
  whPerKwp: number;
  /** air temperature at 2 m, degrees C */
  t2m: number;
}

export interface PvgisSeries {
  /** key = UTC hour as "YYYY-MM-DDTHH" */
  points: Map<string, HourlyPoint>;
  /** calendar year of the data */
  year: number;
}

export interface DayProfile {
  /** local calendar date, "YYYY-MM-DD" */
  date: string;
  utcOffsetHours: number;
  /** index = LOCAL hour 0..23 */
  whPerKwp: number[];
  t2m: number[];
}

/** Local standard time of Egypt is UTC+2. Daylight saving time is ignored (stated limitation). */
export const DEFAULT_UTC_OFFSET_HOURS = 2;

function fail(msg: string): never {
  throw new Error(`PVGIS data: ${msg}`);
}

export function parsePvgis(json: unknown, opts: { peakPowerKw?: number } = {}): PvgisSeries {
  const peak = opts.peakPowerKw ?? 1;
  if (!(peak > 0)) fail("peakPowerKw must be positive");
  if (typeof json !== "object" || json === null) fail("response is not an object");
  const outputs = (json as { outputs?: unknown }).outputs;
  if (typeof outputs !== "object" || outputs === null) fail("missing 'outputs'");
  const hourly = (outputs as { hourly?: unknown }).hourly;
  if (!Array.isArray(hourly) || hourly.length === 0) fail("missing or empty 'outputs.hourly'");

  const points = new Map<string, HourlyPoint>();
  const years = new Set<number>();
  hourly.forEach((row: unknown, i: number) => {
    if (typeof row !== "object" || row === null) fail(`row ${i} is not an object`);
    const r = row as Record<string, unknown>;
    const time = r.time;
    if (typeof time !== "string" || !/^\d{8}:\d{4}$/.test(time)) fail(`row ${i}: bad 'time' (${String(time)})`);
    const P = r.P;
    const T = r.T2m;
    if (typeof P !== "number" || !Number.isFinite(P) || P < 0) fail(`row ${i}: bad 'P' (${String(P)})`);
    if (typeof T !== "number" || !Number.isFinite(T)) fail(`row ${i}: bad 'T2m' (${String(T)})`);
    const key = `${time.slice(0, 4)}-${time.slice(4, 6)}-${time.slice(6, 8)}T${time.slice(9, 11)}`;
    if (points.has(key)) fail(`duplicate hour ${key}`);
    points.set(key, { whPerKwp: Math.round(P / peak), t2m: T });
    years.add(Number(time.slice(0, 4)));
  });
  if (years.size !== 1) fail(`expected one calendar year, found ${[...years].join(", ")}`);
  return { points, year: [...years][0]! };
}

/** Extracts the 24 local hours of one calendar day. Throws if any hour is missing from the series. */
export function extractDay(
  series: PvgisSeries,
  day: { month: number; day: number },
  utcOffsetHours: number = DEFAULT_UTC_OFFSET_HOURS,
): DayProfile {
  const whPerKwp: number[] = [];
  const t2m: number[] = [];
  for (let h = 0; h < 24; h++) {
    const d = new Date(Date.UTC(series.year, day.month - 1, day.day, h - utcOffsetHours));
    const key = d.toISOString().slice(0, 13); // "YYYY-MM-DDTHH"
    const p = series.points.get(key);
    if (p === undefined) {
      fail(`no data for local hour ${h} of ${series.year}-${day.month}-${day.day} (UTC key ${key}); pick a day away from the year boundary`);
    }
    whPerKwp.push(p.whPerKwp);
    t2m.push(p.t2m);
  }
  const mm = String(day.month).padStart(2, "0");
  const dd = String(day.day).padStart(2, "0");
  return { date: `${series.year}-${mm}-${dd}`, utcOffsetHours, whPerKwp, t2m };
}

/** One representative day per month (the 15th): used for seasonal comparison. */
export function representativeDay(month: number): { month: number; day: number } {
  if (!Number.isInteger(month) || month < 1 || month > 12) throw new Error("month must be 1..12");
  return { month, day: 15 };
}
P2P_EOF

cat > sim/src/household.ts <<'P2P_EOF'
/**
 * Household energy model for one simulated day (24 local hours).
 *
 *   generation  = PVGIS Wh per kWp x installed kWp            (PVGIS ESTIMATE x user input)
 *   load        = base profile + cooling that grows with temperature   (SIMULATED, assumptions below)
 *   self-use    = min(generation, load)
 *   surplus     = max(generation - load, 0)   -> can be sold or exported
 *   deficit     = max(load - generation, 0)   -> must be bought (P2P or utility)
 *
 * ALL LOAD NUMBERS BELOW ARE PLACEHOLDER ASSUMPTIONS, not measured Egyptian data.
 * They must be calibrated (or cited) before results go into the thesis.
 * Humidity is not modelled. Daylight saving time is not modelled.
 * Everything returned is an integer number of Wh.
 */

import type { DayProfile } from "./pvgis";

export interface LoadParams {
  /** Wh per day of non-cooling load for a household with loadScale = 1 */
  baseDailyWh: number;
  /** 24 weights (per mille) of how the base load is spread over local hours; must sum to 1000 */
  shapePermille: readonly number[];
  /** Wh added per hour for every degree C above the setpoint, for coolingScale = 1 */
  coolingWhPerDegC: number;
  /** temperature above which cooling starts, degrees C */
  setpointC: number;
}

/** PLACEHOLDERS. Morning peak 07-09, evening peak 18-22. */
export const DEFAULT_LOAD_PARAMS: LoadParams = {
  baseDailyWh: 8000,
  shapePermille: [
    30, 26, 24, 22, 22, 26, // 00-05
    40, 60, 55, 40, // 06-09
    30, 28, 30, 32, 34, 34, // 10-15
    38, 45, 60, 80, 85, 80, // 16-21
    45, 34, // 22-23
  ],
  coolingWhPerDegC: 60,
  setpointC: 26,
};

export interface HouseholdSpec {
  id: string;
  /** installed PV size in kWp; 0 = no PV (a pure consumer) */
  pvKwp: number;
  /** multiplies the base load (1 = default household) */
  loadScale: number;
  /** multiplies the cooling load (1 = default sensitivity) */
  coolingScale: number;
}

export interface HouseholdDay {
  id: string;
  generationWh: number[];
  loadWh: number[];
  selfUseWh: number[];
  surplusWh: number[];
  deficitWh: number[];
  totals: {
    generationWh: number;
    loadWh: number;
    selfUseWh: number;
    surplusWh: number;
    deficitWh: number;
  };
}

export function checkLoadParams(p: LoadParams): void {
  if (p.shapePermille.length !== 24) throw new Error("shapePermille needs 24 values");
  if (p.shapePermille.reduce((a, b) => a + b, 0) !== 1000) throw new Error("shapePermille must sum to 1000");
  if (!(p.baseDailyWh >= 0) || !(p.coolingWhPerDegC >= 0)) throw new Error("load parameters must be non-negative");
}

export function hourlyLoadWh(
  spec: Pick<HouseholdSpec, "loadScale" | "coolingScale">,
  params: LoadParams,
  hour: number,
  t2m: number,
): number {
  const base = (spec.loadScale * params.baseDailyWh * params.shapePermille[hour]!) / 1000;
  const cooling = spec.coolingScale * params.coolingWhPerDegC * Math.max(0, t2m - params.setpointC);
  return Math.round(base + cooling);
}

export function householdDay(
  spec: HouseholdSpec,
  day: DayProfile,
  params: LoadParams = DEFAULT_LOAD_PARAMS,
): HouseholdDay {
  if (!(spec.pvKwp >= 0) || !(spec.loadScale >= 0) || !(spec.coolingScale >= 0)) {
    throw new Error(`household ${spec.id}: pvKwp, loadScale and coolingScale must be non-negative`);
  }
  checkLoadParams(params);
  const out: HouseholdDay = {
    id: spec.id,
    generationWh: [],
    loadWh: [],
    selfUseWh: [],
    surplusWh: [],
    deficitWh: [],
    totals: { generationWh: 0, loadWh: 0, selfUseWh: 0, surplusWh: 0, deficitWh: 0 },
  };
  for (let h = 0; h < 24; h++) {
    const gen = Math.round(spec.pvKwp * day.whPerKwp[h]!);
    const load = hourlyLoadWh(spec, params, h, day.t2m[h]!);
    const self = Math.min(gen, load);
    out.generationWh.push(gen);
    out.loadWh.push(load);
    out.selfUseWh.push(self);
    out.surplusWh.push(gen - self);
    out.deficitWh.push(load - self);
    out.totals.generationWh += gen;
    out.totals.loadWh += load;
    out.totals.selfUseWh += self;
    out.totals.surplusWh += gen - self;
    out.totals.deficitWh += load - self;
  }
  return out;
}
P2P_EOF

cat > sim/src/locations.ts <<'P2P_EOF'
/** Locations offered in the app. Coordinates are approximate city centres. */
export interface Location {
  key: string;
  name: string;
  lat: number;
  lon: number;
}

export const LOCATIONS: readonly Location[] = [
  { key: "alexandria", name: "Alexandria", lat: 31.2, lon: 29.92 },
  { key: "cairo", name: "Cairo", lat: 30.04, lon: 31.24 },
  // New Valley governorate (Wadi El Gedeed), represented by its capital El Kharga.
  { key: "new-valley", name: "New Valley (Wadi El Gedeed)", lat: 25.45, lon: 30.55 },
];

/** PVGIS system assumptions used for every request (documented in the thesis). */
export const PVGIS_SETTINGS = {
  year: 2020,
  peakPowerKw: 1,
  /** system losses in percent */
  lossPercent: 14,
  /** panel tilt from horizontal, degrees (fixed simplification) */
  tiltDeg: 25,
  /** 0 = facing south */
  aspectDeg: 0,
} as const;
P2P_EOF

cat > sim/test/energy.test.ts <<'P2P_EOF'
import { describe, expect, it } from "vitest";
import { extractDay, parsePvgis, representativeDay } from "../src/pvgis";
import {
  DEFAULT_LOAD_PARAMS,
  checkLoadParams,
  hourlyLoadWh,
  householdDay,
  type HouseholdSpec,
} from "../src/household";

/** Builds a PVGIS-shaped document for a whole year where P and T2m encode the UTC hour, so mapping errors are visible. */
function syntheticPvgis(year = 2020, tempBase = 20) {
  const hourly: Array<Record<string, unknown>> = [];
  const start = Date.UTC(year, 0, 1, 0);
  const end = Date.UTC(year + 1, 0, 1, 0);
  for (let t = start; t < end; t += 3600_000) {
    const d = new Date(t);
    const iso = d.toISOString(); // 2020-07-15T10:00:00.000Z
    const time = `${iso.slice(0, 4)}${iso.slice(5, 7)}${iso.slice(8, 10)}:${iso.slice(11, 13)}10`;
    const hour = d.getUTCHours();
    hourly.push({ time, P: hour * 10 + 0.4, "G(i)": 0, H_sun: 0, T2m: tempBase + hour / 2, WS10m: 1, Int: 0 });
  }
  return { inputs: {}, outputs: { hourly, totals: {} }, meta: {} };
}

describe("parsePvgis", () => {
  it("parses a PVGIS-shaped document and rounds Wh to integers", () => {
    const s = parsePvgis(syntheticPvgis());
    expect(s.year).toBe(2020);
    expect(s.points.size).toBe(8784); // 2020 is a leap year
    expect(s.points.get("2020-07-15T10")).toEqual({ whPerKwp: 100, t2m: 25 });
  });

  it("scales by peak power when the request was not for 1 kWp", () => {
    const s = parsePvgis(syntheticPvgis(), { peakPowerKw: 2 });
    expect(s.points.get("2020-07-15T10")!.whPerKwp).toBe(50);
  });

  const good = () => syntheticPvgis();
  const cases: Array<[string, (d: any) => void]> = [
    ["no outputs", (d) => delete d.outputs],
    ["empty hourly", (d) => (d.outputs.hourly = [])],
    ["bad time format", (d) => (d.outputs.hourly[0].time = "2020-01-01")],
    ["negative P", (d) => (d.outputs.hourly[3].P = -1)],
    ["NaN T2m", (d) => (d.outputs.hourly[3].T2m = NaN)],
    ["missing P", (d) => delete d.outputs.hourly[5].P],
    ["duplicate hour", (d) => (d.outputs.hourly[1].time = d.outputs.hourly[0].time)],
  ];
  for (const [name, mutate] of cases) {
    it(`rejects: ${name}`, () => {
      const d = good();
      mutate(d);
      expect(() => parsePvgis(d)).toThrow(/PVGIS data/);
    });
  }

  it("rejects a series that spans two calendar years", () => {
    const d = good();
    d.outputs.hourly[10]!.time = "20210101:0010";
    expect(() => parsePvgis(d)).toThrow(/one calendar year/);
  });
});

describe("extractDay", () => {
  const series = parsePvgis(syntheticPvgis());

  it("maps local hours to UTC hours using the offset (UTC+2)", () => {
    const day = extractDay(series, { month: 7, day: 15 }, 2);
    expect(day.date).toBe("2020-07-15");
    // local hour h = UTC hour (h - 2) mod 24, and P encodes the UTC hour as hour*10
    for (let h = 0; h < 24; h++) {
      expect(day.whPerKwp[h]).toBe(((h - 2 + 24) % 24) * 10);
    }
    expect(day.t2m[12]).toBe(20 + 10 / 2);
  });

  it("works across a month boundary", () => {
    const day = extractDay(series, { month: 3, day: 1 }, 2);
    expect(day.whPerKwp[0]).toBe(220); // local 00:00 on 1 March = 22:00 UTC on 29 Feb (leap year)
  });

  it("throws if the day needs hours outside the series", () => {
    expect(() => extractDay(series, { month: 1, day: 1 }, 2)).toThrow(/no data for local hour 0/);
  });

  it("offers the 15th as the representative day", () => {
    expect(representativeDay(7)).toEqual({ month: 7, day: 15 });
    expect(() => representativeDay(13)).toThrow();
  });
});

describe("household model", () => {
  const cool = extractDay(parsePvgis(syntheticPvgis(2020, 10)), { month: 7, day: 15 });
  const hot = extractDay(parsePvgis(syntheticPvgis(2020, 28)), { month: 7, day: 15 });
  const house: HouseholdSpec = { id: "h", pvKwp: 3, loadScale: 1, coolingScale: 1 };

  it("default load shape sums to 1000", () => {
    expect(() => checkLoadParams(DEFAULT_LOAD_PARAMS)).not.toThrow();
    expect(() => checkLoadParams({ ...DEFAULT_LOAD_PARAMS, shapePermille: [1000] })).toThrow();
  });

  it("no cooling load at or below the setpoint", () => {
    const base = hourlyLoadWh({ loadScale: 1, coolingScale: 1 }, DEFAULT_LOAD_PARAMS, 8, 26);
    const colder = hourlyLoadWh({ loadScale: 1, coolingScale: 1 }, DEFAULT_LOAD_PARAMS, 8, 5);
    expect(base).toBe(colder);
    expect(base).toBe(440); // 8000 Wh x 55/1000
  });

  it("cooling load grows with temperature, so hotter places have higher load", () => {
    const a = householdDay(house, cool);
    const b = householdDay(house, hot);
    expect(b.totals.loadWh).toBeGreaterThan(a.totals.loadWh);
    expect(hourlyLoadWh(house, DEFAULT_LOAD_PARAMS, 14, 36)).toBe(Math.round(8000 * 0.034 + 60 * 10));
  });

  it("energy balance is consistent every hour and in total, in integers", () => {
    const d = householdDay(house, hot);
    for (let h = 0; h < 24; h++) {
      expect(d.generationWh[h]).toBe(d.selfUseWh[h]! + d.surplusWh[h]!);
      expect(d.loadWh[h]).toBe(d.selfUseWh[h]! + d.deficitWh[h]!);
      expect(d.surplusWh[h]! * d.deficitWh[h]!).toBe(0); // never both surplus and deficit in one hour
      for (const v of [d.generationWh[h]!, d.loadWh[h]!, d.surplusWh[h]!, d.deficitWh[h]!]) {
        expect(Number.isInteger(v)).toBe(true);
      }
    }
    expect(d.totals.generationWh).toBe(d.totals.selfUseWh + d.totals.surplusWh);
    expect(d.totals.loadWh).toBe(d.totals.selfUseWh + d.totals.deficitWh);
  });

  it("a household without PV has no generation and no surplus", () => {
    const d = householdDay({ ...house, pvKwp: 0 }, hot);
    expect(d.totals.generationWh).toBe(0);
    expect(d.totals.surplusWh).toBe(0);
    expect(d.totals.deficitWh).toBe(d.totals.loadWh);
  });

  it("scales generation with installed kWp", () => {
    const small = householdDay({ ...house, pvKwp: 1 }, hot);
    const big = householdDay({ ...house, pvKwp: 4 }, hot);
    expect(big.totals.generationWh).toBe(4 * small.totals.generationWh);
  });

  it("rejects negative inputs", () => {
    expect(() => householdDay({ ...house, pvKwp: -1 }, hot)).toThrow();
  });
});
P2P_EOF

cat > sim/scripts/fetch-pvgis.ts <<'P2P_EOF'
/**
 * Downloads one year of hourly PVGIS data for each location and saves it in <repo>/data/pvgis/.
 * Run from the sim/ folder:  npm run fetch-pvgis
 * Needs internet access. After it runs, the app works offline from the saved files.
 */
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { LOCATIONS, PVGIS_SETTINGS } from "../src/locations";
import { parsePvgis } from "../src/pvgis";

const here = path.dirname(fileURLToPath(import.meta.url));
const outDir = path.resolve(here, "../../data/pvgis");
const VERSIONS = ["v5_3", "v5_2"]; // try the newer API first

async function fetchOne(lat: number, lon: number): Promise<{ text: string; version: string }> {
  const s = PVGIS_SETTINGS;
  const query =
    `lat=${lat}&lon=${lon}&peakpower=${s.peakPowerKw}&loss=${s.lossPercent}` +
    `&angle=${s.tiltDeg}&aspect=${s.aspectDeg}&startyear=${s.year}&endyear=${s.year}` +
    `&pvcalculation=1&outputformat=json`;
  let lastError = "";
  for (const version of VERSIONS) {
    const url = `https://re.jrc.ec.europa.eu/api/${version}/seriescalc?${query}`;
    const res = await fetch(url);
    const text = await res.text();
    if (res.ok) return { text, version };
    lastError = `${version}: HTTP ${res.status} ${text.slice(0, 200)}`;
  }
  throw new Error(lastError);
}

await mkdir(outDir, { recursive: true });
for (const loc of LOCATIONS) {
  process.stdout.write(`${loc.name} ... `);
  const { text, version } = await fetchOne(loc.lat, loc.lon);
  const series = parsePvgis(JSON.parse(text), { peakPowerKw: PVGIS_SETTINGS.peakPowerKw });
  let annualWh = 0;
  let tSum = 0;
  let tMax = -Infinity;
  for (const p of series.points.values()) {
    annualWh += p.whPerKwp;
    tSum += p.t2m;
    tMax = Math.max(tMax, p.t2m);
  }
  const file = path.join(outDir, `${loc.key}_${series.year}.json`);
  await writeFile(file, text);
  console.log(
    `ok (${version}) rows=${series.points.size} year=${series.year} ` +
      `yield=${(annualWh / 1000).toFixed(0)} kWh/kWp mean T=${(tSum / series.points.size).toFixed(1)}C max T=${tMax.toFixed(1)}C`,
  );
}
console.log(`Saved to ${outDir}`);
P2P_EOF

cat > sim/tsconfig.json <<'P2P_EOF'
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "skipLibCheck": true,
    "noEmit": true,
    "types": ["node"]
  },
  "include": ["src", "test", "scripts"]
}
P2P_EOF

cat > sim/package.json <<'P2P_EOF'
{
  "name": "p2p-sim",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "description": "Energy model, PVGIS data and bot households for the P2P simulator",
  "scripts": {
    "test": "vitest run",
    "typecheck": "tsc --noEmit",
    "fetch-pvgis": "tsx scripts/fetch-pvgis.ts"
  }
}
P2P_EOF

cd sim
echo "Installing dev tools (TypeScript, Vitest, tsx)..."
npm install -D typescript vitest tsx @types/node
echo "Type check..."
npm run typecheck
echo "Running tests..."
npm test
echo "Done. Next: cd sim && npm run fetch-pvgis"
