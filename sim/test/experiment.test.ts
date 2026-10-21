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
