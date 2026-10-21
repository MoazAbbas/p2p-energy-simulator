/**
 * Simulated households ("bots") and the population generator.
 *
 * Prices are positioned inside the hour's price band [lo, hi] (lo = export rate, hi = retail tariff):
 *   buyer bid  = hi - mu * (hi - lo)    mu in [0,1]: 0 = pay the ceiling, 1 = bid the floor
 *   seller ask = lo + m  * (hi - lo)    m  in [0,1]: 0 = ask the floor,   1 = ask the ceiling
 * Bots adapt mu / m every tick in a ZIP-like way (see market.ts). No machine learning.
 *
 * ALL PARAMETER DEFAULTS BELOW ARE PLACEHOLDERS. Results depend on them, so list them in the report.
 */
import type { HouseholdSpec } from "./household";
import { mulberry32, pick, uniform } from "./rng";

export type AgentKind = "consumer" | "prosumer" | "human-proxy";

export interface Agent {
  id: string;
  kind: AgentKind;
  spec: HouseholdSpec;
  /** the real human is a seller only; bots with a deficit bid like consumers */
  canBuy: boolean;
  buyer: { mu: number; beta: number };
  seller: { type: string; m: number; beta: number; holdBackShare: number };
}

export interface SellerType {
  name: string;
  /** share of prosumers of this type; all shares must sum to 1 */
  share: number;
  /** initial seller margin range */
  m0Range: readonly [number, number];
  /** learning rate per tick */
  beta: number;
}

export interface PopulationConfig {
  n: number;
  /** fraction of households with PV, 0..1 */
  prosumerShare: number;
  seed: number;
  pvKwpChoices: readonly number[];
  loadScaleRange: readonly [number, number];
  coolingScaleRange: readonly [number, number];
  buyer: { muRange: readonly [number, number]; beta: number };
  sellerTypes: readonly SellerType[];
}

export const DEFAULT_POPULATION = {
  pvKwpChoices: [2, 3, 4, 5, 6],
  loadScaleRange: [0.6, 1.6],
  coolingScaleRange: [0.5, 1.5],
  buyer: { muRange: [0.3, 0.9], beta: 0.05 },
  sellerTypes: [
    { name: "patient", share: 0.3, m0Range: [0.7, 0.95], beta: 0.02 },
    { name: "balanced", share: 0.4, m0Range: [0.4, 0.7], beta: 0.05 },
    { name: "aggressive", share: 0.3, m0Range: [0.1, 0.4], beta: 0.1 },
  ],
} as const satisfies Omit<PopulationConfig, "n" | "prosumerShare" | "seed">;

function checkRange(name: string, r: readonly [number, number], lo: number, hi: number): void {
  if (!(r[0] >= lo && r[1] <= hi && r[0] <= r[1])) throw new Error(`${name} must be an ordered range within ${lo}..${hi}`);
}

export function makePopulation(cfg: PopulationConfig): Agent[] {
  if (!Number.isInteger(cfg.n) || cfg.n < 1) throw new Error("n must be a positive integer");
  if (!(cfg.prosumerShare >= 0 && cfg.prosumerShare <= 1)) throw new Error("prosumerShare must be within 0..1");
  if (!Number.isInteger(cfg.seed)) throw new Error("seed must be an integer");
  if (cfg.pvKwpChoices.length === 0 || cfg.pvKwpChoices.some((v) => !(v > 0))) throw new Error("pvKwpChoices must be positive");
  checkRange("loadScaleRange", cfg.loadScaleRange, 0, 100);
  checkRange("coolingScaleRange", cfg.coolingScaleRange, 0, 100);
  checkRange("buyer.muRange", cfg.buyer.muRange, 0, 1);
  const shareSum = cfg.sellerTypes.reduce((s, t) => s + t.share, 0);
  if (cfg.sellerTypes.length === 0 || Math.abs(shareSum - 1) > 1e-9) throw new Error("sellerTypes shares must sum to 1");
  for (const t of cfg.sellerTypes) checkRange(`sellerTypes.${t.name}.m0Range`, t.m0Range, 0, 1);

  const rng = mulberry32(cfg.seed);
  const prosumers = Math.round(cfg.n * cfg.prosumerShare);
  const pad = String(cfg.n).length;
  const agents: Agent[] = [];
  for (let i = 0; i < cfg.n; i++) {
    const isProsumer = i < prosumers;
    const id = `${isProsumer ? "P" : "C"}${String(i + 1).padStart(Math.max(3, pad), "0")}`;
    const loadScale = uniform(rng, cfg.loadScaleRange[0], cfg.loadScaleRange[1]);
    const coolingScale = uniform(rng, cfg.coolingScaleRange[0], cfg.coolingScaleRange[1]);
    const mu = uniform(rng, cfg.buyer.muRange[0], cfg.buyer.muRange[1]);
    let pvKwp = 0;
    let sellerType = cfg.sellerTypes[0]!;
    let m0 = 0.5;
    if (isProsumer) {
      pvKwp = pick(rng, cfg.pvKwpChoices);
      const roll = rng();
      let acc = 0;
      sellerType = cfg.sellerTypes[cfg.sellerTypes.length - 1]!;
      for (const t of cfg.sellerTypes) {
        acc += t.share;
        if (roll < acc) {
          sellerType = t;
          break;
        }
      }
      m0 = uniform(rng, sellerType.m0Range[0], sellerType.m0Range[1]);
    }
    agents.push({
      id,
      kind: isProsumer ? "prosumer" : "consumer",
      spec: { id, pvKwp, loadScale, coolingScale },
      canBuy: true,
      buyer: { mu, beta: cfg.buyer.beta },
      seller: { type: isProsumer ? sellerType.name : "none", m: m0, beta: sellerType.beta, holdBackShare: 0 },
    });
  }
  return agents;
}

/**
 * The real participant, modelled as a fixed strategy (used for the annual replay and for tests):
 * sells only, never adapts, asks at margin m, keeps holdBackShare of each hour's surplus.
 */
export function humanProxy(opts: {
  id?: string;
  pvKwp: number;
  m: number;
  holdBackShare?: number;
  loadScale?: number;
  coolingScale?: number;
}): Agent {
  const id = opts.id ?? "HUMAN";
  const holdBackShare = opts.holdBackShare ?? 0;
  if (!(opts.m >= 0 && opts.m <= 1)) throw new Error("m must be within 0..1");
  if (!(holdBackShare >= 0 && holdBackShare <= 1)) throw new Error("holdBackShare must be within 0..1");
  return {
    id,
    kind: "human-proxy",
    spec: { id, pvKwp: opts.pvKwp, loadScale: opts.loadScale ?? 1, coolingScale: opts.coolingScale ?? 1 },
    canBuy: false,
    buyer: { mu: 1, beta: 0 },
    seller: { type: "human", m: opts.m, beta: 0, holdBackShare },
  };
}
