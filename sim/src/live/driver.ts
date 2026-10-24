/**
 * Plays a session in real time. The session itself never looks at a clock; this driver decides how long to wait
 * after each step, so the same session runs instantly in tests and at human speed in the app.
 *
 * Defaults follow the design: morning about 20 s, one simulated trading hour about 70 s (12 rounds, so a round
 * about every 5.8 s), evening about 20 s. `speed` multiplies everything (2 = twice as fast).
 */
import type { LiveSession, StepInfo } from "./session";

export interface Timing {
  /** real milliseconds for the fast-forward before the market opens */
  morningMs: number;
  /** real milliseconds for one simulated trading hour */
  hourMs: number;
  /** real milliseconds for the fast-forward after the market closes */
  eveningMs: number;
}

export const DEFAULT_TIMING: Timing = { morningMs: 20_000, hourMs: 70_000, eveningMs: 20_000 };

export type Sleep = (ms: number) => Promise<void>;
const realSleep: Sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export class RealtimeDriver {
  private running = false;
  private stopRequested = false;
  private paused = false;
  private resumeWaiters: Array<() => void> = [];
  speed = 1;

  constructor(
    private readonly session: LiveSession,
    private readonly ticksPerHour: number,
    private readonly timing: Timing = DEFAULT_TIMING,
    private readonly sleep: Sleep = realSleep,
    private readonly onStep?: (step: StepInfo) => void,
  ) {}

  /** How long to wait AFTER a step, in simulated-real milliseconds. Exposed for tests. */
  delayAfter(step: StepInfo): number {
    switch (step.kind) {
      case "fastForward":
        return step.phase === "morning" ? this.timing.morningMs : this.timing.eveningMs;
      case "tick":
        return this.timing.hourMs / this.ticksPerHour;
      default:
        return 0;
    }
  }

  pause(): void {
    this.paused = true;
  }

  resume(): void {
    this.paused = false;
    for (const w of this.resumeWaiters.splice(0)) w();
  }

  stop(): void {
    this.stopRequested = true;
    this.resume();
  }

  /** Runs until the session is finished, stopped, or an error (including an IntegrityError) occurs. */
  async run(): Promise<void> {
    if (this.running) throw new Error("already running");
    this.running = true;
    this.stopRequested = false;
    try {
      for (;;) {
        while (this.paused && !this.stopRequested) await new Promise<void>((r) => this.resumeWaiters.push(r));
        if (this.stopRequested) return;
        const step = await this.session.advance();
        this.onStep?.(step);
        if (step.kind === "settle") return;
        const ms = this.delayAfter(step) / this.speed;
        if (ms > 0) await this.sleep(ms);
      }
    } finally {
      this.running = false;
    }
  }
}
