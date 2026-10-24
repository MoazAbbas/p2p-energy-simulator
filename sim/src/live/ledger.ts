/**
 * What the live session needs from the "book of record". Two implementations:
 *   LocalLedger  - the chaincode logic running in memory (tests, offline demos, no Docker)
 *   FabricLedger - the same calls sent to the Hyperledger Fabric network (added after the network is verified)
 * Both must give the same answers, because both run the same chaincode logic.
 */
import type { EngineConfig, EngineEvent, Trade } from "../../../engine/src/engine";

/** Who is submitting: the platform operator (bots, hour handling) or the human participant (own identity). */
export type Actor = "operator" | "human";

export interface LedgerParticipant {
  participantId: string;
  /** the human's participant is owned by the human identity; bots have no owner (the operator acts for them) */
  owner: Actor | null;
}

export interface LedgerEventResult {
  ok: boolean;
  seq?: number;
  restingWh?: number;
  tradeSeqs?: number[];
  cancelledWh?: number;
  reason?: string;
  message?: string;
}

export interface LedgerSubmitOutcome {
  results: LedgerEventResult[];
  trades: Trade[];
}

export interface LedgerHourSummary {
  hour: number;
  tradeCount: number;
  volumeWh: number;
  amount: number;
  summaryHash: string;
  prevHash: string;
}

export interface SettlementFigures {
  boughtWh: number;
  soldWh: number;
  paid: number;
  received: number;
  costA: number;
  costB: number;
  costC: number;
}

export interface Ledger {
  openSession(args: { scenarioHash: string; participants: LedgerParticipant[] }): Promise<void>;
  openHour(hour: number, caps: EngineConfig): Promise<void>;
  submit(hour: number, events: EngineEvent[], actor: Actor): Promise<LedgerSubmitOutcome>;
  closeHour(hour: number): Promise<LedgerHourSummary>;
  closeSession(): Promise<void>;
  recordSettlement(participantId: string, figures: SettlementFigures): Promise<void>;
}
