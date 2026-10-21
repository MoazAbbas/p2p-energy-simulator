#!/usr/bin/env bash
# Adds the bot households, market-day runner and location checks to your existing sim/ folder, then runs all tests.
# Needs engine/ and sim/ (from setup-engine.sh and setup-sim.sh).
# Run it from the repo root:  cd ~/projects/p2p-energy && bash setup-bots.sh
set -euo pipefail

[ -f engine/src/engine.ts ] || { echo "engine/src/engine.ts not found - run setup-engine.sh first."; exit 1; }
[ -d sim/node_modules ] || { echo "sim/ not set up - run setup-sim.sh first."; exit 1; }
for f in src/rng.ts src/location.ts src/agents.ts src/market.ts test/market.test.ts test/location.test.ts; do
  if [ -e "sim/$f" ]; then echo "sim/$f already exists - stopping so nothing is overwritten."; exit 1; fi
done

cat > sim/src/rng.ts <<'P2P_EOF'
/** Small seeded random generator so every simulation run is reproducible from its seed. */
export type Rng = () => number;

/** mulberry32: integer arithmetic only, so it gives the same numbers on every machine. */
export function mulberry32(seed: number): Rng {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export function uniform(rng: Rng, lo: number, hi: number): number {
  return lo + (hi - lo) * rng();
}

export function pick<T>(rng: Rng, items: readonly T[]): T {
  if (items.length === 0) throw new Error("pick: empty list");
  return items[Math.floor(rng() * items.length)]!;
}

/** Fisher-Yates shuffle, in place. */
export function shuffleInPlace<T>(rng: Rng, items: T[]): void {
  for (let i = items.length - 1; i > 0; i--) {
    const j = Math.floor(rng() * (i + 1));
    const tmp = items[i]!;
    items[i] = items[j]!;
    items[j] = tmp;
  }
}
P2P_EOF

cat > sim/src/location.ts <<'P2P_EOF'
/**
 * User-entered locations. The user types latitude and longitude; we only accept points inside
 * Egypt's bounding box (a rectangle around the country, so a few border points outside Egypt pass).
 * Results are cached per coordinates rounded to 2 decimals (about 1 km).
 */
import { PVGIS_SETTINGS } from "./locations";

export const EGYPT_BOUNDS = { latMin: 21.9, latMax: 31.7, lonMin: 24.6, lonMax: 37.0 } as const;

export interface Coordinates {
  lat: number;
  lon: number;
}

export function validateCoordinates(lat: unknown, lon: unknown): Coordinates {
  if (typeof lat !== "number" || typeof lon !== "number" || !Number.isFinite(lat) || !Number.isFinite(lon)) {
    throw new Error("latitude and longitude must be numbers");
  }
  const b = EGYPT_BOUNDS;
  if (lat < b.latMin || lat > b.latMax || lon < b.lonMin || lon > b.lonMax) {
    throw new Error(
      `location is outside Egypt (latitude ${b.latMin} to ${b.latMax}, longitude ${b.lonMin} to ${b.lonMax})`,
    );
  }
  return { lat, lon };
}

export function roundCoordinates(c: Coordinates): Coordinates {
  return { lat: Math.round(c.lat * 100) / 100, lon: Math.round(c.lon * 100) / 100 };
}

/** Stable cache key, e.g. "30.04_31.24". Nearby points (about 1 km) share a key. */
export function locationCacheKey(c: Coordinates): string {
  const r = roundCoordinates(c);
  return `${r.lat.toFixed(2)}_${r.lon.toFixed(2)}`;
}

export function buildPvgisUrl(version: string, c: Coordinates, s: typeof PVGIS_SETTINGS = PVGIS_SETTINGS): string {
  const r = roundCoordinates(c);
  return (
    `https://re.jrc.ec.europa.eu/api/${version}/seriescalc?lat=${r.lat}&lon=${r.lon}` +
    `&peakpower=${s.peakPowerKw}&loss=${s.lossPercent}&angle=${s.tiltDeg}&aspect=${s.aspectDeg}` +
    `&startyear=${s.year}&endyear=${s.year}&pvcalculation=1&outputformat=json`
  );
}
P2P_EOF

cat > sim/src/agents.ts <<'P2P_EOF'
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
P2P_EOF

cat > sim/src/market.ts <<'P2P_EOF'
/**
 * Runs one simulated day for a community of households.
 *
 * In trading hours, every hour is a continuous double auction (the Engine) played in `ticksPerHour` rounds.
 * Each round every active bot posts a resting order (replacing its old one if its price changed), then adapts
 * its margin: it shades more after a fill and improves its price after a miss (ZIP-like).
 * Outside trading hours, and for anything left unmatched, households use the utility:
 *   buy at the retail tariff, export at the export rate.
 *
 * Outage hours (optional): the utility is unavailable. Unmet demand is "unserved" (costed at the ceiling price so
 * runs stay comparable), unsold surplus is curtailed (no revenue), and the price band becomes [1, retail x multiplier].
 *
 * Every household gets three costs for the day (piastres, positive = pays):
 *   A  no solar:              buys all its load from the utility
 *   B  solar, always export:  self-consumes, exports all surplus at the export rate
 *   C  solar + P2P market:    what actually happened in this simulation
 * premium = B - C is the benefit of the P2P market over simply exporting.
 *
 * Tariff defaults are PLACEHOLDERS until the official Egyptian figures are looked up.
 */
import { Engine, tradeAmount, type EngineConfig, type EngineEvent, type Trade } from "../../engine/src/engine";
import type { Agent } from "./agents";
import { DEFAULT_LOAD_PARAMS, householdDay, type LoadParams } from "./household";
import type { DayProfile } from "./pvgis";
import { shuffleInPlace, type Rng } from "./rng";

export interface Tariff {
  /** piastres per kWh paid when buying from the utility (the price ceiling) */
  retail: number;
  /** piastres per kWh received when exporting to the utility (the price floor) */
  export: number;
}

export interface Outage {
  /** local hours (0..23) during which the utility is unavailable */
  hours: readonly number[];
  /** buyer ceiling = retail x this / 1000 (2000 = double) */
  ceilingMultiplierPermille: number;
}

export interface MarketConfig {
  tariff: Tariff;
  /** local hours with a market, e.g. [12,13,14,15,16,17] */
  tradingHours: readonly number[];
  ticksPerHour: number;
  /** 0..1: random variation of the learning step */
  learningNoise: number;
  outage?: Outage;
  /** keep every trade in the result (more memory) */
  collectTrades?: boolean;
  /** keep the engine event log of every hour (for replay / chain equivalence checks) */
  recordEvents?: boolean;
}

export const DEFAULT_MARKET: MarketConfig = {
  tariff: { retail: 200, export: 100 }, // PLACEHOLDER: 2.00 and 1.00 EGP per kWh
  tradingHours: [12, 13, 14, 15, 16, 17],
  ticksPerHour: 12,
  learningNoise: 0.5,
};

export interface HourLog {
  hour: number;
  gridUp: boolean;
  tradedWh: number;
  amount: number;
  tradeCount: number;
  minPrice: number | null;
  maxPrice: number | null;
  /** all surplus of all households in this hour */
  surplusWh: number;
  /** all deficit of households that may buy */
  buyerDemandWh: number;
  gridImportWh: number;
  gridExportWh: number;
  unservedWh: number;
  curtailedWh: number;
  trades?: Trade[];
  engineConfig?: EngineConfig;
  events?: EngineEvent[];
}

export interface AgentResult {
  id: string;
  kind: Agent["kind"];
  pvKwp: number;
  generationWh: number;
  surplusWh: number;
  deficitWh: number;
  boughtWh: number;
  soldWh: number;
  paid: number;
  received: number;
  costA: number;
  costB: number;
  costC: number;
  /** costB - costC */
  premium: number;
}

export interface DayMetrics {
  tradedWh: number;
  /** piastres moved between households */
  amount: number;
  tradeCount: number;
  /** share of all surplus (trading hours) that was sold P2P */
  surplusSoldShare: number | null;
  /** share of buyer demand (trading hours) that was met P2P */
  demandCoveredShare: number | null;
  /** sum of premium over all households, piastres */
  totalGain: number;
  /** volume-weighted average trade price, piastres per kWh */
  vwap: number | null;
  /** (vwap - export) / (retail - export): 0 = sellers get only the export rate, 1 = buyers pay full retail */
  pricePosition: number | null;
  /** volume-weighted standard deviation of trade prices */
  priceStdDev: number | null;
  gridImportWh: number;
  gridExportWh: number;
  gridImportWhB: number;
  gridExportWhB: number;
  unservedWh: number;
}

export interface DayResult {
  date: string;
  agents: AgentResult[];
  hours: HourLog[];
  metrics: DayMetrics;
}

export function validateMarket(cfg: MarketConfig): void {
  const { retail, export: exp } = cfg.tariff;
  if (!Number.isInteger(retail) || !Number.isInteger(exp) || exp < 1 || retail < exp) {
    throw new Error("tariff: retail and export must be integers (piastres/kWh) with 1 <= export <= retail");
  }
  if (!Number.isInteger(cfg.ticksPerHour) || cfg.ticksPerHour < 1) throw new Error("ticksPerHour must be a positive integer");
  if (!(cfg.learningNoise >= 0 && cfg.learningNoise <= 1)) throw new Error("learningNoise must be within 0..1");
  for (const h of [...cfg.tradingHours, ...(cfg.outage?.hours ?? [])]) {
    if (!Number.isInteger(h) || h < 0 || h > 23) throw new Error("hours must be integers 0..23");
  }
  if (cfg.outage && !(cfg.outage.ceilingMultiplierPermille >= 1000)) {
    throw new Error("outage ceilingMultiplierPermille must be at least 1000");
  }
}

interface Acc {
  costA: number;
  costB: number;
  costC: number;
  boughtWh: number;
  soldWh: number;
  paid: number;
  received: number;
}

const clamp01 = (v: number): number => Math.min(1, Math.max(0, v));

export function simulateDay(
  agentsIn: readonly Agent[],
  day: DayProfile,
  cfg: MarketConfig,
  rng: Rng,
  loadParams: LoadParams = DEFAULT_LOAD_PARAMS,
): DayResult {
  validateMarket(cfg);
  // Learning state is private to this run: the caller's agents are never modified.
  const agents = agentsIn.map((a) => ({ ...a, buyer: { ...a.buyer }, seller: { ...a.seller } }));
  const n = agents.length;
  const households = agents.map((a) => householdDay(a.spec, day, loadParams));
  const idToIndex = new Map(agents.map((a, i) => [a.id, i] as const));
  const r = cfg.tariff.retail;
  const e = cfg.tariff.export;
  const trading = new Set(cfg.tradingHours);
  const outageHours = new Set(cfg.outage?.hours ?? []);
  const hiOutage = Math.round((r * (cfg.outage?.ceilingMultiplierPermille ?? 1000)) / 1000);

  const acc: Acc[] = agents.map(() => ({ costA: 0, costB: 0, costC: 0, boughtWh: 0, soldWh: 0, paid: 0, received: 0 }));
  const hours: HourLog[] = [];
  let sumQ = 0;
  let sumPQ = 0;
  let sumP2Q = 0;
  let gridImportWh = 0;
  let gridExportWh = 0;
  let gridImportWhB = 0;
  let gridExportWhB = 0;
  let unservedWh = 0;

  for (let h = 0; h < 24; h++) {
    const gridUp = !outageHours.has(h);
    const buyPrice = gridUp ? r : hiOutage;
    const exportPrice = gridUp ? e : 0;
    const lo = gridUp ? e : 1;
    const hi = gridUp ? r : hiOutage;

    const boughtH: number[] = new Array<number>(n).fill(0);
    const soldH: number[] = new Array<number>(n).fill(0);
    const paidH: number[] = new Array<number>(n).fill(0);
    const receivedH: number[] = new Array<number>(n).fill(0);

    const log: HourLog = {
      hour: h,
      gridUp,
      tradedWh: 0,
      amount: 0,
      tradeCount: 0,
      minPrice: null,
      maxPrice: null,
      surplusWh: 0,
      buyerDemandWh: 0,
      gridImportWh: 0,
      gridExportWh: 0,
      unservedWh: 0,
      curtailedWh: 0,
    };
    for (let i = 0; i < n; i++) {
      log.surplusWh += households[i]!.surplusWh[h]!;
      if (agents[i]!.canBuy) log.buyerDemandWh += households[i]!.deficitWh[h]!;
    }

    if (trading.has(h)) {
      const sellCaps: Record<string, number> = {};
      const buyCaps: Record<string, number> = {};
      const active: number[] = [];
      for (let i = 0; i < n; i++) {
        const a = agents[i]!;
        const s = households[i]!.surplusWh[h]!;
        const d = households[i]!.deficitWh[h]!;
        if (s > 0) {
          const offer = s - Math.floor(s * a.seller.holdBackShare);
          if (offer > 0) {
            sellCaps[a.id] = offer;
            active.push(i);
          }
        }
        if (a.canBuy && d > 0) {
          buyCaps[a.id] = d;
          active.push(i);
        }
      }

      const engineConfig: EngineConfig = { sellCapsWh: sellCaps, buyCapsWh: buyCaps };
      const engine = new Engine(engineConfig);
      const events: EngineEvent[] = [];
      const record = cfg.recordEvents === true;
      const openOrder = new Map<number, { orderId: string; price: number }>();
      const doneWh = new Map<number, number>();
      let orderCounter = 0;

      for (let tick = 0; tick < cfg.ticksPerHour; tick++) {
        const order = active.slice();
        shuffleInPlace(rng, order);
        const filled = new Set<number>();

        for (const i of order) {
          const a = agents[i]!;
          const isSeller = sellCaps[a.id] !== undefined;
          const cap = isSeller ? sellCaps[a.id]! : buyCaps[a.id]!;
          const remaining = cap - (doneWh.get(i) ?? 0);
          if (remaining <= 0) continue;
          const price = Math.round(isSeller ? lo + a.seller.m * (hi - lo) : hi - a.buyer.mu * (hi - lo));
          const open = openOrder.get(i);
          if (open !== undefined && open.price === price) continue; // keep time priority
          if (open !== undefined) {
            const ev: EngineEvent = { type: "cancel", orderId: open.orderId, participantId: a.id };
            if (record) events.push(ev);
            const c = engine.apply(ev);
            if (!c.ok) throw new Error(`unexpected cancel failure: ${JSON.stringify(c)}`);
          }
          const orderId = `h${h}-${++orderCounter}`;
          const ev: EngineEvent = {
            type: "submit",
            order: { orderId, participantId: a.id, side: isSeller ? "sell" : "buy", price, qtyWh: remaining },
          };
          if (record) events.push(ev);
          const res = engine.apply(ev);
          if (!("trades" in res)) throw new Error(`unexpected submit failure: ${JSON.stringify(res)}`);
          openOrder.set(i, { orderId, price });
          for (const t of res.trades) {
            const bi = idToIndex.get(t.buyerId)!;
            const si = idToIndex.get(t.sellerId)!;
            doneWh.set(bi, (doneWh.get(bi) ?? 0) + t.qtyWh);
            doneWh.set(si, (doneWh.get(si) ?? 0) + t.qtyWh);
            filled.add(bi);
            filled.add(si);
            boughtH[bi]! += t.qtyWh;
            paidH[bi]! += t.amount;
            soldH[si]! += t.qtyWh;
            receivedH[si]! += t.amount;
            log.tradedWh += t.qtyWh;
            log.amount += t.amount;
            log.tradeCount += 1;
            log.minPrice = log.minPrice === null ? t.price : Math.min(log.minPrice, t.price);
            log.maxPrice = log.maxPrice === null ? t.price : Math.max(log.maxPrice, t.price);
            sumQ += t.qtyWh;
            sumPQ += t.price * t.qtyWh;
            sumP2Q += t.price * t.price * t.qtyWh;
            if (cfg.collectTrades) (log.trades ??= []).push(t);
          }
        }

        // Learning: shade more after a fill, improve the price after a miss.
        for (const i of order) {
          const a = agents[i]!;
          const isSeller = sellCaps[a.id] !== undefined;
          const cap = isSeller ? sellCaps[a.id]! : buyCaps[a.id]!;
          const remaining = cap - (doneWh.get(i) ?? 0);
          const didFill = filled.has(i);
          if (!didFill && remaining <= 0) continue;
          const step = (isSeller ? a.seller.beta : a.buyer.beta) * (1 + cfg.learningNoise * (2 * rng() - 1));
          if (isSeller) a.seller.m = clamp01(a.seller.m + (didFill ? step : -step));
          else a.buyer.mu = clamp01(a.buyer.mu + (didFill ? step : -step));
        }
      }

      const closeEvent: EngineEvent = { type: "close" };
      if (record) events.push(closeEvent);
      engine.apply(closeEvent);
      if (record) {
        log.engineConfig = engineConfig;
        log.events = events;
      }
    }

    // Settlement for this hour.
    for (let i = 0; i < n; i++) {
      const hh = households[i]!;
      const a = acc[i]!;
      const deficit = hh.deficitWh[h]!;
      const surplus = hh.surplusWh[h]!;
      a.costA += tradeAmount(hh.loadWh[h]!, buyPrice);
      a.costB += tradeAmount(deficit, buyPrice) - tradeAmount(surplus, exportPrice);
      const buyLeft = deficit - boughtH[i]!;
      const exportLeft = surplus - soldH[i]!;
      a.costC += tradeAmount(buyLeft, buyPrice) - tradeAmount(exportLeft, exportPrice) + paidH[i]! - receivedH[i]!;
      a.boughtWh += boughtH[i]!;
      a.soldWh += soldH[i]!;
      a.paid += paidH[i]!;
      a.received += receivedH[i]!;
      if (gridUp) {
        log.gridImportWh += buyLeft;
        log.gridExportWh += exportLeft;
        gridImportWhB += deficit;
        gridExportWhB += surplus;
      } else {
        log.unservedWh += buyLeft;
        log.curtailedWh += exportLeft;
      }
    }
    gridImportWh += log.gridImportWh;
    gridExportWh += log.gridExportWh;
    unservedWh += log.unservedWh;
    hours.push(log);
  }

  const agentResults: AgentResult[] = agents.map((a, i) => ({
    id: a.id,
    kind: a.kind,
    pvKwp: a.spec.pvKwp,
    generationWh: households[i]!.totals.generationWh,
    surplusWh: households[i]!.totals.surplusWh,
    deficitWh: households[i]!.totals.deficitWh,
    boughtWh: acc[i]!.boughtWh,
    soldWh: acc[i]!.soldWh,
    paid: acc[i]!.paid,
    received: acc[i]!.received,
    costA: acc[i]!.costA,
    costB: acc[i]!.costB,
    costC: acc[i]!.costC,
    premium: acc[i]!.costB - acc[i]!.costC,
  }));

  let surplusTrading = 0;
  let demandTrading = 0;
  let tradedWh = 0;
  let amount = 0;
  let tradeCount = 0;
  for (const l of hours) {
    tradedWh += l.tradedWh;
    amount += l.amount;
    tradeCount += l.tradeCount;
    if (trading.has(l.hour)) {
      surplusTrading += l.surplusWh;
      demandTrading += l.buyerDemandWh;
    }
  }
  const vwap = sumQ > 0 ? sumPQ / sumQ : null;
  const metrics: DayMetrics = {
    tradedWh,
    amount,
    tradeCount,
    surplusSoldShare: surplusTrading > 0 ? tradedWh / surplusTrading : null,
    demandCoveredShare: demandTrading > 0 ? tradedWh / demandTrading : null,
    totalGain: agentResults.reduce((s, a) => s + a.premium, 0),
    vwap,
    pricePosition: vwap !== null && r > e ? (vwap - e) / (r - e) : null,
    priceStdDev: vwap !== null ? Math.sqrt(Math.max(0, sumP2Q / sumQ - vwap * vwap)) : null,
    gridImportWh,
    gridExportWh,
    gridImportWhB,
    gridExportWhB,
    unservedWh,
  };

  return { date: day.date, agents: agentResults, hours, metrics };
}
P2P_EOF

cat > sim/test/market.test.ts <<'P2P_EOF'
import { describe, expect, it } from "vitest";
import { runEvents } from "../../engine/src/engine";
import { DEFAULT_POPULATION, humanProxy, makePopulation, type Agent } from "../src/agents";
import { DEFAULT_MARKET, simulateDay, validateMarket, type DayResult, type MarketConfig } from "../src/market";
import type { DayProfile } from "../src/pvgis";
import { mulberry32 } from "../src/rng";

/** Sun from 07:00 to 17:59 at 800 Wh per kWp, 20 C all day (no cooling load), so numbers stay easy to reason about. */
function flatDay(): DayProfile {
  return {
    date: "2020-07-15",
    utcOffsetHours: 2,
    whPerKwp: Array.from({ length: 24 }, (_, h) => (h >= 7 && h <= 17 ? 800 : 0)),
    t2m: Array<number>(24).fill(20),
  };
}

function population(p: number, seed: number, n = 100): Agent[] {
  return makePopulation({ n, prosumerShare: p, seed, ...DEFAULT_POPULATION });
}

function run(p: number, seed: number, cfg: Partial<MarketConfig> = {}, extra: Agent[] = []): DayResult {
  return simulateDay([...population(p, seed), ...extra], flatDay(), { ...DEFAULT_MARKET, ...cfg }, mulberry32(seed + 1000));
}

function mean(values: Array<number | null>): number {
  const v = values.filter((x): x is number => x !== null);
  return v.reduce((a, b) => a + b, 0) / v.length;
}

describe("population", () => {
  it("creates the requested number of prosumers and consumers with unique ids", () => {
    const pop = population(0.3, 7);
    expect(pop).toHaveLength(100);
    expect(pop.filter((a) => a.kind === "prosumer")).toHaveLength(30);
    expect(pop.filter((a) => a.kind === "consumer")).toHaveLength(70);
    expect(new Set(pop.map((a) => a.id)).size).toBe(100);
    for (const a of pop) {
      expect(a.canBuy).toBe(true);
      if (a.kind === "prosumer") expect(a.spec.pvKwp).toBeGreaterThan(0);
      else expect(a.spec.pvKwp).toBe(0);
    }
  });

  it("is reproducible from the seed and differs between seeds", () => {
    expect(population(0.3, 7)).toEqual(population(0.3, 7));
    expect(population(0.3, 7)).not.toEqual(population(0.3, 8));
  });

  it("keeps every random parameter inside its configured range", () => {
    for (const a of population(0.5, 3, 200)) {
      expect(a.buyer.mu).toBeGreaterThanOrEqual(0.3);
      expect(a.buyer.mu).toBeLessThanOrEqual(0.9);
      expect(a.spec.loadScale).toBeGreaterThanOrEqual(0.6);
      expect(a.spec.loadScale).toBeLessThanOrEqual(1.6);
      if (a.kind === "prosumer") {
        const t = DEFAULT_POPULATION.sellerTypes.find((s) => s.name === a.seller.type)!;
        expect(a.seller.m).toBeGreaterThanOrEqual(t.m0Range[0]);
        expect(a.seller.m).toBeLessThanOrEqual(t.m0Range[1]);
      }
    }
  });

  it("rejects invalid configurations", () => {
    const base = { n: 10, prosumerShare: 0.5, seed: 1, ...DEFAULT_POPULATION };
    expect(() => makePopulation({ ...base, n: 0 })).toThrow();
    expect(() => makePopulation({ ...base, prosumerShare: 1.2 })).toThrow();
    expect(() => makePopulation({ ...base, seed: 1.5 })).toThrow();
    expect(() =>
      makePopulation({ ...base, sellerTypes: [{ name: "x", share: 0.5, m0Range: [0, 1], beta: 0.1 }] }),
    ).toThrow(/sum to 1/);
  });
});

describe("market configuration", () => {
  it("rejects invalid settings", () => {
    const ok = DEFAULT_MARKET;
    expect(() => validateMarket(ok)).not.toThrow();
    expect(() => validateMarket({ ...ok, tariff: { retail: 100, export: 200 } })).toThrow();
    expect(() => validateMarket({ ...ok, tariff: { retail: 200, export: 0 } })).toThrow();
    expect(() => validateMarket({ ...ok, ticksPerHour: 0 })).toThrow();
    expect(() => validateMarket({ ...ok, tradingHours: [24] })).toThrow();
    expect(() => validateMarket({ ...ok, outage: { hours: [14], ceilingMultiplierPermille: 500 } })).toThrow();
  });
});

describe("a simulated day keeps the accounting consistent", () => {
  for (const seed of [1, 2, 3]) {
    it(`seed ${seed}`, () => {
      const human = humanProxy({ pvKwp: 5, m: 0 }); // asks the floor, so it trades even in a crowded market
      const res = run(0.3, seed, { collectTrades: true, recordEvents: true }, [human]);
      const { retail, export: exp } = DEFAULT_MARKET.tariff;

      // Energy and money are conserved between buyers and sellers.
      const sold = res.agents.reduce((s, a) => s + a.soldWh, 0);
      const bought = res.agents.reduce((s, a) => s + a.boughtWh, 0);
      const paid = res.agents.reduce((s, a) => s + a.paid, 0);
      const received = res.agents.reduce((s, a) => s + a.received, 0);
      expect(sold).toBe(bought);
      expect(sold).toBe(res.metrics.tradedWh);
      expect(paid).toBe(received);
      expect(paid).toBe(res.metrics.amount);
      expect(res.metrics.tradedWh).toBeGreaterThan(0);

      for (const a of res.agents) {
        expect(a.soldWh).toBeLessThanOrEqual(a.surplusWh);
        expect(a.boughtWh).toBeLessThanOrEqual(a.deficitWh);
        // A trade never leaves anyone worse off than the utility would (up to rounding to whole piastres).
        expect(a.premium).toBeGreaterThanOrEqual(-30);
        if (a.kind === "consumer") expect(a.costA).toBe(a.costB);
      }
      expect(res.metrics.totalGain).toBeGreaterThan(0);

      // The real participant is a seller only.
      const h = res.agents.find((a) => a.id === "HUMAN")!;
      expect(h.boughtWh).toBe(0);
      expect(h.soldWh).toBeGreaterThan(0);

      // Trades stay inside the price band and happen only in trading hours.
      for (const log of res.hours) {
        if (!DEFAULT_MARKET.tradingHours.includes(log.hour)) expect(log.tradeCount).toBe(0);
        for (const t of log.trades ?? []) {
          expect(t.price).toBeGreaterThanOrEqual(exp);
          expect(t.price).toBeLessThanOrEqual(retail);
        }
      }

      // Replaying the recorded orders through a fresh engine gives exactly the same trades.
      for (const log of res.hours) {
        if (log.events === undefined) continue;
        const replay = runEvents(log.engineConfig!, log.events);
        expect(replay.trades).toEqual(log.trades ?? []);
      }
    });
  }

  it("is deterministic for the same seeds", () => {
    expect(JSON.stringify(run(0.3, 5))).toBe(JSON.stringify(run(0.3, 5)));
    expect(JSON.stringify(run(0.3, 5))).not.toBe(JSON.stringify(run(0.3, 6)));
  });

  it("does not modify the agents it is given", () => {
    const pop = population(0.3, 4);
    const before = JSON.stringify(pop);
    simulateDay(pop, flatDay(), DEFAULT_MARKET, mulberry32(1));
    expect(JSON.stringify(pop)).toBe(before);
  });

  it("with no trading hours everyone just uses the utility", () => {
    const res = run(0.3, 2, { tradingHours: [] });
    expect(res.metrics.tradedWh).toBe(0);
    expect(res.metrics.surplusSoldShare).toBeNull();
    for (const a of res.agents) expect(a.costC).toBe(a.costB);
  });
});

describe("what the market does as the prosumer share changes", () => {
  const seeds = [1, 2, 3];
  const at = (p: number) => seeds.map((s) => run(p, s).metrics);

  it("scarce supply sells out at high prices; abundant supply is cheap and mostly unsold", () => {
    const scarce = at(0.02);
    const abundant = at(0.5);
    expect(mean(scarce.map((m) => m.surplusSoldShare))).toBeGreaterThan(mean(abundant.map((m) => m.surplusSoldShare)));
    expect(mean(abundant.map((m) => m.demandCoveredShare))).toBeGreaterThan(mean(scarce.map((m) => m.demandCoveredShare)));
    expect(mean(scarce.map((m) => m.pricePosition))).toBeGreaterThan(mean(abundant.map((m) => m.pricePosition)));
  });

  it("total gain is highest when supply and demand are close, not at the extremes", () => {
    const gain = (p: number) => mean(at(p).map((m) => m.totalGain));
    expect(gain(0.1)).toBeGreaterThan(gain(0.02));
    expect(gain(0.1)).toBeGreaterThan(gain(0.8));
  });

  it("P2P trading reduces utility imports compared with always exporting", () => {
    for (const m of at(0.2)) {
      expect(m.gridImportWh).toBeLessThan(m.gridImportWhB);
      expect(m.gridExportWh).toBeLessThan(m.gridExportWhB);
    }
  });
});

describe("outage hours", () => {
  const outage = { hours: [14], ceilingMultiplierPermille: 2000 };

  it("with scarce supply, prices can exceed the retail tariff and demand goes unserved", () => {
    const res = run(0.02, 1, { outage, collectTrades: true });
    const log = res.hours[14]!;
    expect(log.gridUp).toBe(false);
    expect(log.gridImportWh).toBe(0);
    expect(log.gridExportWh).toBe(0);
    expect(log.unservedWh).toBeGreaterThan(0);
    expect(log.maxPrice!).toBeGreaterThan(DEFAULT_MARKET.tariff.retail);
    expect(log.maxPrice!).toBeLessThanOrEqual(400);
    for (const t of log.trades ?? []) expect(t.price).toBeGreaterThanOrEqual(1);
  });

  it("with abundant supply, unsold surplus is curtailed and prices collapse towards zero", () => {
    const res = run(0.5, 1, { outage });
    const log = res.hours[14]!;
    expect(log.curtailedWh).toBeGreaterThan(0);
    expect(log.maxPrice!).toBeLessThan(DEFAULT_MARKET.tariff.export);
  });

  it("hours without an outage are unaffected by the outage setting", () => {
    const res = run(0.3, 2, { outage });
    expect(res.hours[13]!.gridUp).toBe(true);
    expect(res.hours[14]!.gridUp).toBe(false);
  });
});

describe("the real participant as a fixed strategy", () => {
  const consumersOnly = (extra: Agent[]) =>
    simulateDay([...population(0, 5, 50), ...extra], flatDay(), DEFAULT_MARKET, mulberry32(9));

  it("keeping all surplus means nothing is sold and costs equal always-export", () => {
    const res = consumersOnly([humanProxy({ pvKwp: 5, m: 0.2, holdBackShare: 1 })]);
    const h = res.agents.find((a) => a.id === "HUMAN")!;
    expect(h.soldWh).toBe(0);
    expect(h.costC).toBe(h.costB);
  });

  it("selling to a community of consumers earns more than exporting", () => {
    const res = consumersOnly([humanProxy({ pvKwp: 5, m: 0.5 })]);
    const h = res.agents.find((a) => a.id === "HUMAN")!;
    expect(h.soldWh).toBeGreaterThan(0);
    expect(h.premium).toBeGreaterThan(0);
  });

  it("in a glut of sellers a fixed high ask is priced out, but with scarce supply it sells everything", () => {
    const sold = (p: number, m: number) =>
      run(p, 1, {}, [humanProxy({ pvKwp: 5, m })]).agents.find((a) => a.id === "HUMAN")!.soldWh;
    expect(sold(0.3, 0.5)).toBeLessThan(sold(0.3, 0));
    expect(sold(0.3, 0.5)).toBe(0);
    expect(sold(0.05, 0.5)).toBeGreaterThan(0);
  });

  it("a higher ask never earns less per kWh sold when the human is the only seller", () => {
    const perKwh = (m: number) => {
      const h = consumersOnly([humanProxy({ pvKwp: 5, m })]).agents.find((a) => a.id === "HUMAN")!;
      return h.received / h.soldWh;
    };
    expect(perKwh(1)).toBeGreaterThanOrEqual(perKwh(0));
  });
});
P2P_EOF

cat > sim/test/location.test.ts <<'P2P_EOF'
import { describe, expect, it } from "vitest";
import { buildPvgisUrl, locationCacheKey, roundCoordinates, validateCoordinates } from "../src/location";

describe("user-entered location", () => {
  it("accepts points inside Egypt", () => {
    expect(validateCoordinates(30.04, 31.24)).toEqual({ lat: 30.04, lon: 31.24 }); // Cairo
    expect(validateCoordinates(25.45, 30.55)).toEqual({ lat: 25.45, lon: 30.55 }); // El Kharga
  });

  it("rejects points outside Egypt and non-numbers", () => {
    expect(() => validateCoordinates(48.85, 2.35)).toThrow(/outside Egypt/); // Paris
    expect(() => validateCoordinates(0, 0)).toThrow(/outside Egypt/);
    expect(() => validateCoordinates("30", 31)).toThrow(/numbers/);
    expect(() => validateCoordinates(NaN, 31)).toThrow(/numbers/);
    expect(() => validateCoordinates(30, undefined)).toThrow(/numbers/);
  });

  it("nearby points share a cache key and distant ones do not", () => {
    expect(locationCacheKey({ lat: 30.041, lon: 31.238 })).toBe(locationCacheKey({ lat: 30.044, lon: 31.242 }));
    expect(locationCacheKey({ lat: 30.04, lon: 31.24 })).toBe("30.04_31.24");
    expect(locationCacheKey({ lat: 25.45, lon: 30.55 })).not.toBe(locationCacheKey({ lat: 30.04, lon: 31.24 }));
    expect(roundCoordinates({ lat: 25.456, lon: 30.554 })).toEqual({ lat: 25.46, lon: 30.55 });
  });

  it("builds the PVGIS request from the rounded coordinates and the fixed system assumptions", () => {
    const url = buildPvgisUrl("v5_3", { lat: 25.4567, lon: 30.5512 });
    expect(url).toContain("/api/v5_3/seriescalc?");
    expect(url).toContain("lat=25.46&lon=30.55");
    expect(url).toContain("peakpower=1");
    expect(url).toContain("angle=25&aspect=0");
    expect(url).toContain("startyear=2020&endyear=2020");
    expect(url).toContain("outputformat=json");
  });
});
P2P_EOF

cd sim
echo "Type check..."
npm run typecheck
echo "Running all tests (energy model, location, bots and market day)..."
npm test
echo "Done."
