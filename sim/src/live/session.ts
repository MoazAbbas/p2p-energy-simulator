/**
 * A live session: one simulated day with a human seller among bot households.
 *
 * Every state change goes through one serial queue, so the order book, the shadow engine and the ledger always
 * see the same sequence of events:
 *
 *   - the BOTS' orders of one round (tick) are computed against a shadow Engine and sent to the ledger as ONE batch
 *   - the HUMAN's orders and cancels are sent one at a time, under the human's own identity
 *   - after every submit the ledger's answer (accepted/rejected, trades, prices) is compared with the shadow
 *     Engine's answer; any difference halts the session (IntegrityError) instead of letting the two drift apart
 *
 * The session does not read the wall clock. `advance()` performs the next step of the day; a driver (driver.ts)
 * calls it on a timer, tests call it in a loop.
 */
import { createHash } from "node:crypto";
import { Engine, RULES_VERSION, type BookSnapshot, type CancelResult, type EngineEvent, type SubmitResult, type Trade } from "../../../engine/src/engine";
import type { Agent } from "../agents";
import { DaySim, type DayResult, type HourLog, type MarketConfig } from "../market";
import type { HourMarket } from "../hourmarket";
import { DEFAULT_LOAD_PARAMS, type LoadParams } from "../household";
import type { DayProfile } from "../pvgis";
import { mulberry32, type Rng } from "../rng";
import type { Ledger, LedgerEventResult, LedgerHourSummary, LedgerSubmitOutcome } from "./ledger";

export type Phase = "planning" | "morning" | "trading" | "evening" | "finished" | "halted";

export class IntegrityError extends Error {
  constructor(message: string, readonly detail: unknown) {
    super(message);
    this.name = "IntegrityError";
  }
}

export interface LiveConfig {
  sessionId: string;
  /** the whole community including the human's household */
  agents: readonly Agent[];
  /** id of the agent that is played by the human (must exist in `agents`) */
  humanId: string;
  day: DayProfile;
  market: MarketConfig;
  seed: number;
  loadParams?: LoadParams;
}

export interface HumanPlan {
  hours: Array<{ hour: number; generationWh: number; loadWh: number; surplusWh: number; deficitWh: number; trading: boolean; gridUp: boolean }>;
  /** price band the human can expect per trading hour: [floor, ceiling] in piastres per kWh */
  bands: Array<{ hour: number; floor: number; ceiling: number }>;
}

export type StepKind = "fastForward" | "openHour" | "tick" | "closeHour" | "settle";

export interface StepInfo {
  kind: StepKind;
  phase: Phase;
  hour: number;
  /** 1-based round number within the hour, for kind "tick" */
  tick?: number;
  /** bot orders and cancels sent in this step */
  events?: number;
  trades?: number;
}

export interface OrderRequest {
  price: number;
  qtyWh: number;
}

export interface PlaceResult {
  accepted: boolean;
  orderId?: string;
  reason?: string;
  message?: string;
  /** Wh of the order that did not trade and now rests in the book */
  restingWh?: number;
  trades: Trade[];
}

export interface LiveState {
  phase: Phase;
  /** the hour being played or just finished; 0..23 */
  hour: number;
  tick: number;
  ticksPerHour: number;
  /** simulated clock, "HH:MM" */
  clock: string;
  gridUp: boolean;
  /** order book of the open hour (empty when no hour is open) */
  book: BookSnapshot;
  human: {
    id: string;
    availableToSellWh: number;
    openOrders: Array<{ orderId: string; price: number; remainingWh: number }>;
    soldWhThisHour: number;
    receivedThisHour: number;
  };
  lastTrades: Trade[];
  finishedHours: HourLog[];
  halted: { reason: string; detail: unknown } | null;
}

/** Fixed field order, so the shadow's and the ledger's answers can be compared as text. */
function normalizeResult(r: LedgerEventResult): string {
  return JSON.stringify([r.ok, r.seq ?? null, r.restingWh ?? null, r.tradeSeqs ?? null, r.cancelledWh ?? null, r.ok ? null : (r.reason ?? null)]);
}

function shadowToLedgerResult(r: SubmitResult | CancelResult): LedgerEventResult {
  if (!r.ok) return { ok: false, reason: r.reason, message: r.message };
  if ("trades" in r) return { ok: true, seq: r.seq, restingWh: r.restingWh, tradeSeqs: r.trades.map((t) => t.seq) };
  return { ok: true, cancelledWh: r.cancelledWh };
}

function canonicalJson(value: unknown): string {
  return JSON.stringify(value, (_k, v) =>
    v && typeof v === "object" && !Array.isArray(v) ? Object.fromEntries(Object.entries(v as Record<string, unknown>).sort(([a], [b]) => (a < b ? -1 : 1))) : v,
  );
}

/** sha-256 of everything that determines a session's outcome, fixed on the ledger when the session opens. */
export function scenarioHash(cfg: LiveConfig): string {
  return createHash("sha256")
    .update(
      canonicalJson({
        rulesVersion: RULES_VERSION,
        sessionId: cfg.sessionId,
        humanId: cfg.humanId,
        seed: cfg.seed,
        day: cfg.day,
        market: { ...cfg.market, collectTrades: undefined, recordEvents: undefined },
        loadParams: cfg.loadParams ?? DEFAULT_LOAD_PARAMS,
        agents: cfg.agents,
      }),
    )
    .digest("hex");
}

export class LiveSession {
  private readonly sim: DaySim;
  private readonly rng: Rng;
  private readonly humanIndex: number;
  private readonly externalIds: ReadonlySet<string>;
  private phase: Phase = "planning";
  private nextHour = 0;
  private market: HourMarket | null = null;
  private shadow: Engine | null = null;
  private tick = 0;
  private humanOrderCounter = 0;
  private lastTrades: Trade[] = [];
  private halted: { reason: string; detail: unknown } | null = null;
  private queue: Promise<unknown> = Promise.resolve();
  private started = false;
  readonly hourSummaries: LedgerHourSummary[] = [];

  constructor(private readonly cfg: LiveConfig, private readonly ledger: Ledger) {
    this.sim = new DaySim(cfg.agents, cfg.day, cfg.market, cfg.loadParams);
    this.rng = mulberry32(cfg.seed);
    this.humanIndex = this.sim.agents.findIndex((a) => a.id === cfg.humanId);
    if (this.humanIndex < 0) throw new Error(`humanId ${cfg.humanId} is not one of the agents`);
    if (this.sim.agents[this.humanIndex]!.canBuy) throw new Error("the human is a seller only (canBuy must be false)");
    if (new Set(cfg.agents.map((a) => a.id)).size !== cfg.agents.length) throw new Error("agent ids must be unique");
    if (cfg.market.tradingHours.length === 0) throw new Error("tradingHours must not be empty");
    this.externalIds = new Set([cfg.humanId]);
  }

  /** Forecast for the planning screen: the human household's generation, load and expected surplus. */
  plan(): HumanPlan {
    const hh = this.sim.households[this.humanIndex]!;
    const hours = [];
    const bands = [];
    for (let h = 0; h < 24; h++) {
      const b = this.sim.band(h);
      hours.push({
        hour: h,
        generationWh: hh.generationWh[h]!,
        loadWh: hh.loadWh[h]!,
        surplusWh: hh.surplusWh[h]!,
        deficitWh: hh.deficitWh[h]!,
        trading: this.sim.isTrading(h),
        gridUp: b.gridUp,
      });
      if (this.sim.isTrading(h)) bands.push({ hour: h, floor: b.lo, ceiling: b.hi });
    }
    return { hours, bands };
  }

  /** Serializes work: each job starts when the previous one has finished, whether it succeeded or not. */
  private enqueue<T>(job: () => Promise<T>): Promise<T> {
    const run = this.queue.then(job, job);
    this.queue = run.catch(() => undefined);
    return run;
  }

  private assertRunning(): void {
    if (this.halted !== null) throw new IntegrityError(`session halted: ${this.halted.reason}`, this.halted.detail);
    if (!this.started) throw new Error("the session has not been started");
    if (this.phase === "finished") throw new Error("the session is finished");
  }

  private halt(reason: string, detail: unknown): never {
    this.halted = { reason, detail };
    this.phase = "halted";
    throw new IntegrityError(reason, detail);
  }

  /** Registers the session and all participants on the ledger. Call once, before the first advance(). */
  start(): Promise<void> {
    return this.enqueue(async () => {
      if (this.started) throw new Error("already started");
      await this.ledger.openSession({
        scenarioHash: scenarioHash(this.cfg),
        participants: this.sim.agents.map((a) => ({ participantId: a.id, owner: a.id === this.cfg.humanId ? ("human" as const) : null })),
      });
      this.started = true;
      this.phase = "morning";
    });
  }

  /** Performs the next step of the day. */
  advance(): Promise<StepInfo> {
    return this.enqueue(() => this.doAdvance());
  }

  private async doAdvance(): Promise<StepInfo> {
    this.assertRunning();
    const T = this.cfg.market.ticksPerHour;

    if (this.market !== null) {
      const h = this.nextHour;
      if (this.tick < T) return this.doTick(h);
      return this.doCloseHour(h);
    }

    if (this.nextHour >= 24) return this.doSettle();

    const h = this.nextHour;
    if (!this.sim.isTrading(h)) {
      const donePhase: Phase = this.sim.hours.some((l) => this.sim.isTrading(l.hour)) ? "evening" : "morning";
      this.phase = donePhase;
      const first = h;
      while (this.nextHour < 24 && !this.sim.isTrading(this.nextHour)) {
        this.sim.finishHour(this.nextHour, null);
        this.nextHour++;
      }
      return { kind: "fastForward", phase: donePhase, hour: first };
    }

    // open a trading hour
    this.market = this.sim.openMarket(h, this.externalIds);
    this.shadow = new Engine(this.market.engineConfig);
    this.tick = 0;
    await this.ledger.openHour(h, this.market.engineConfig);
    this.phase = "trading";
    this.lastTrades = [];
    return { kind: "openHour", phase: "trading", hour: h };
  }

  private async sendAndCheck(h: number, events: EngineEvent[], who: "operator" | "human", expected: { results: LedgerEventResult[]; trades: Trade[] }): Promise<LedgerSubmitOutcome> {
    let outcome: LedgerSubmitOutcome;
    try {
      outcome = await this.ledger.submit(h, events, who);
    } catch (err) {
      return this.halt("the ledger refused or failed a submit", { hour: h, error: String(err), events: events.length });
    }
    const a = expected.results.map(normalizeResult);
    const b = outcome.results.map(normalizeResult);
    if (a.length !== b.length || a.some((x, i) => x !== b[i])) {
      return this.halt("the ledger's answer differs from the shadow engine's", { hour: h, expected: expected.results, got: outcome.results });
    }
    if (JSON.stringify(expected.trades) !== JSON.stringify(outcome.trades)) {
      return this.halt("the ledger's trades differ from the shadow engine's", { hour: h, expected: expected.trades, got: outcome.trades });
    }
    return outcome;
  }

  private async doTick(h: number): Promise<StepInfo> {
    const market = this.market!;
    const collected: EngineEvent[] = [];
    const botResults: LedgerEventResult[] = [];
    const botTrades: Trade[] = [];
    // The bots decide against the shadow engine; every event it applies is collected for the ledger batch.
    market.runTick(this.rng, (ev) => {
      const r = this.shadow!.apply(ev) as SubmitResult | CancelResult;
      collected.push(ev);
      botResults.push(shadowToLedgerResult(r));
      if (r.ok && "trades" in r) botTrades.push(...r.trades);
      return r;
    });
    this.tick++;
    if (collected.length > 0) {
      const outcome = await this.sendAndCheck(h, collected, "operator", { results: botResults, trades: botTrades });
      if (outcome.trades.length > 0) this.lastTrades.push(...outcome.trades);
    }
    return { kind: "tick", phase: "trading", hour: h, tick: this.tick, events: collected.length, trades: botTrades.length };
  }

  private async doCloseHour(h: number): Promise<StepInfo> {
    const market = this.market!;
    const shadow = this.shadow!;
    const summary = await (async () => {
      try {
        return await this.ledger.closeHour(h);
      } catch (err) {
        return this.halt("the ledger failed to close the hour", { hour: h, error: String(err) });
      }
    })();
    shadow.apply({ type: "close" });
    const shadowTrades = shadow.getTrades();
    const volume = shadowTrades.reduce((s, t) => s + t.qtyWh, 0);
    const amount = shadowTrades.reduce((s, t) => s + t.amount, 0);
    if (summary.tradeCount !== shadowTrades.length || summary.volumeWh !== volume || summary.amount !== amount) {
      this.halt("the ledger's hour summary differs from the shadow engine's", { hour: h, ledger: summary, shadow: { tradeCount: shadowTrades.length, volumeWh: volume, amount } });
    }
    this.hourSummaries.push(summary);
    this.sim.finishHour(h, market);
    this.market = null;
    this.shadow = null;
    this.nextHour = h + 1;
    return { kind: "closeHour", phase: "trading", hour: h, trades: shadowTrades.length };
  }

  private async doSettle(): Promise<StepInfo> {
    try {
      await this.ledger.closeSession();
      for (const a of this.sim.agentResults()) {
        await this.ledger.recordSettlement(a.id, {
          boughtWh: a.boughtWh,
          soldWh: a.soldWh,
          paid: a.paid,
          received: a.received,
          costA: a.costA,
          costB: a.costB,
          costC: a.costC,
        });
      }
    } catch (err) {
      this.halt("the ledger failed to settle the session", { error: String(err) });
    }
    this.phase = "finished";
    return { kind: "settle", phase: "finished", hour: 23 };
  }

  /** The human offers energy for sale. Executes immediately against any bid that crosses. */
  placeHumanOrder(req: OrderRequest): Promise<PlaceResult> {
    return this.enqueue(async () => {
      this.assertRunning();
      if (this.market === null || this.shadow === null) {
        return { accepted: false, reason: "HOUR_CLOSED", message: "no hour is open for trading", trades: [] };
      }
      const h = this.nextHour;
      const orderId = `H${h}-${this.humanOrderCounter + 1}`;
      const ev: EngineEvent = { type: "submit", order: { orderId, participantId: this.cfg.humanId, side: "sell", price: req.price, qtyWh: req.qtyWh } };
      const r = this.shadow.apply(ev) as SubmitResult;
      if (!r.ok) return { accepted: false, reason: r.reason, message: r.message, trades: [] };
      this.humanOrderCounter++;
      const expected = { results: [shadowToLedgerResult(r)], trades: r.trades };
      await this.sendAndCheck(h, [ev], "human", expected);
      this.market.noteTrades(r.trades);
      this.lastTrades.push(...r.trades);
      return { accepted: true, orderId, restingWh: r.restingWh, trades: r.trades };
    });
  }

  /** The human withdraws a resting order. */
  cancelHumanOrder(orderId: string): Promise<{ cancelled: boolean; cancelledWh?: number; reason?: string; message?: string }> {
    return this.enqueue(async () => {
      this.assertRunning();
      if (this.market === null || this.shadow === null) return { cancelled: false, reason: "HOUR_CLOSED", message: "no hour is open for trading" };
      const h = this.nextHour;
      const ev: EngineEvent = { type: "cancel", orderId, participantId: this.cfg.humanId };
      const r = this.shadow.apply(ev) as CancelResult;
      if (!r.ok) return { cancelled: false, reason: r.reason, message: r.message };
      await this.sendAndCheck(h, [ev], "human", { results: [shadowToLedgerResult(r)], trades: [] });
      return { cancelled: true, cancelledWh: r.cancelledWh };
    });
  }

  private clockText(): string {
    const T = this.cfg.market.ticksPerHour;
    const h = this.market !== null ? this.nextHour : Math.min(this.nextHour, 23);
    const minutes = this.market !== null ? Math.floor((this.tick * 60) / T) : 0;
    return `${String(h).padStart(2, "0")}:${String(minutes).padStart(2, "0")}`;
  }

  getState(): LiveState {
    const book = this.shadow !== null ? this.shadow.getBook() : { bids: [], asks: [] };
    const hid = this.cfg.humanId;
    const mine = book.asks.filter((o) => o.participantId === hid);
    const hi = this.humanIndex;
    const h = Math.min(this.nextHour, 23);
    return {
      phase: this.phase,
      hour: h,
      tick: this.tick,
      ticksPerHour: this.cfg.market.ticksPerHour,
      clock: this.clockText(),
      gridUp: this.sim.band(h).gridUp,
      book,
      human: {
        id: hid,
        availableToSellWh: this.shadow !== null ? this.shadow.availableToSell(hid) : 0,
        openOrders: mine.map((o) => ({ orderId: o.orderId, price: o.price, remainingWh: o.remainingWh })),
        soldWhThisHour: this.market?.soldWh[hi] ?? 0,
        receivedThisHour: this.market?.received[hi] ?? 0,
      },
      lastTrades: this.lastTrades.slice(-20),
      finishedHours: [...this.sim.hours],
      halted: this.halted,
    };
  }

  /** Final per-household results; only after the session is finished. */
  result(): DayResult {
    if (this.phase !== "finished") throw new Error("the session is not finished");
    return this.sim.result();
  }

  /** The human's three baselines for the summary screen: A no solar, B solar + always export, C solar + P2P. */
  humanSummary() {
    const r = this.result();
    return r.agents.find((a) => a.id === this.cfg.humanId)!;
  }
}
