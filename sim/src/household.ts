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
