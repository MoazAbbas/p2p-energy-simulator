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
