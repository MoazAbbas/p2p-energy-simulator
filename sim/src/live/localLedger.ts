import * as chaincode from "../../../blockchain/chaincode/energy-market/src/logic";
import type { CallContext } from "../../../blockchain/chaincode/energy-market/src/logic";
import { RULES_VERSION, type EngineConfig, type EngineEvent, type Trade } from "../../../engine/src/engine";
import type { Actor, Ledger, LedgerEventResult, LedgerHourSummary, LedgerParticipant, LedgerSubmitOutcome, SettlementFigures } from "./ledger";
import { MemoryStore } from "./memoryStore";

export const OPERATOR_IDENTITY = "x509::local-operator";
export const HUMAN_IDENTITY = "x509::local-human";

/** The chaincode logic executed in memory: same rules, same hashes, no network. */
export class LocalLedger implements Ledger {
  readonly store = new MemoryStore();
  private txCounter = 0;

  constructor(readonly sessionId: string) {}

  private ctx(actor: Actor): CallContext {
    // A fixed, increasing transaction time: the chaincode only stores it, it never affects the market.
    const t = new Date(Date.UTC(2026, 0, 1) + this.txCounter++ * 1000).toISOString();
    return { store: this.store, callerId: actor === "operator" ? OPERATOR_IDENTITY : HUMAN_IDENTITY, txTimestamp: t };
  }

  async openSession(args: { scenarioHash: string; participants: LedgerParticipant[] }): Promise<void> {
    const participants = args.participants.map((p) => ({
      participantId: p.participantId,
      ownerId: p.owner === "human" ? HUMAN_IDENTITY : null,
    }));
    await chaincode.openSession(this.ctx("operator"), this.sessionId, RULES_VERSION, args.scenarioHash, JSON.stringify(participants));
  }

  async openHour(hour: number, caps: EngineConfig): Promise<void> {
    await chaincode.openHour(this.ctx("operator"), this.sessionId, hour, JSON.stringify(caps));
  }

  async submit(hour: number, events: EngineEvent[], actor: Actor): Promise<LedgerSubmitOutcome> {
    const results: LedgerEventResult[] = [];
    const trades: Trade[] = [];
    for (let i = 0; i < events.length; i += chaincode.MAX_EVENTS_PER_BATCH) {
      const chunk = events.slice(i, i + chaincode.MAX_EVENTS_PER_BATCH);
      const out = await chaincode.submitOrders(this.ctx(actor), this.sessionId, hour, JSON.stringify(chunk));
      results.push(...out.results);
      for (const { sessionId: _s, hour: _h, ...t } of out.trades) trades.push(t);
    }
    return { results, trades };
  }

  async closeHour(hour: number): Promise<LedgerHourSummary> {
    const s = await chaincode.closeHour(this.ctx("operator"), this.sessionId, hour);
    return { hour, tradeCount: s.tradeCount, volumeWh: s.volumeWh, amount: s.amount, summaryHash: s.summaryHash, prevHash: s.prevHash };
  }

  async closeSession(): Promise<void> {
    await chaincode.closeSession(this.ctx("operator"), this.sessionId);
  }

  async recordSettlement(participantId: string, figures: SettlementFigures): Promise<void> {
    await chaincode.recordSettlement(this.ctx("operator"), this.sessionId, participantId, JSON.stringify(figures));
  }

  /** Recomputes an hour's hashes from the stored events (what an auditor would do). */
  verifyHour(hour: number): Promise<{ ok: boolean; problems: string[] }> {
    return chaincode.verifyHour(this.ctx("operator"), this.sessionId, hour);
  }

  getSession() {
    return chaincode.getSession(this.ctx("operator"), this.sessionId);
  }

  getHourSummary(hour: number) {
    return chaincode.getHourSummary(this.ctx("operator"), this.sessionId, hour);
  }
}
