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
