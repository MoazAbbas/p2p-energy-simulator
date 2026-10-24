/**
 * Fabric wrapper around logic.ts. It only translates between the Fabric SDK (stub, client identity,
 * string arguments) and the SDK-free market logic; all rules live in logic.ts and engine.ts.
 *
 * Every method takes and returns strings, as Fabric requires. Results are JSON text.
 */
import { Context, Contract, Info, Returns, Transaction } from "fabric-contract-api";
import * as logic from "./logic";
import type { CallContext, Store } from "./logic";

class FabricStore implements Store {
  constructor(private readonly ctx: Context) {}

  key(objectType: string, attrs: readonly string[]): string {
    return this.ctx.stub.createCompositeKey(objectType, [...attrs]);
  }

  async get(key: string): Promise<string | null> {
    const bytes = await this.ctx.stub.getState(key);
    return bytes === undefined || bytes.length === 0 ? null : Buffer.from(bytes).toString("utf8");
  }

  async put(key: string, value: string): Promise<void> {
    await this.ctx.stub.putState(key, Buffer.from(value, "utf8"));
  }

  async listByPrefix(objectType: string, attrs: readonly string[]): Promise<string[]> {
    const out: string[] = [];
    const iterator = await this.ctx.stub.getStateByPartialCompositeKey(objectType, [...attrs]);
    try {
      for (;;) {
        const next = await iterator.next();
        if (next.value !== undefined && next.value.value !== undefined && next.value.value.length > 0) {
          out.push(Buffer.from(next.value.value).toString("utf8"));
        }
        if (next.done) break;
      }
    } finally {
      await iterator.close();
    }
    return out;
  }
}

function callContext(ctx: Context): CallContext {
  const ts = ctx.stub.getTxTimestamp();
  // seconds is a protobuf Long; its string form is exact. Whole seconds are enough here and identical on every peer.
  const seconds = Number(ts.seconds.toString());
  return {
    store: new FabricStore(ctx),
    callerId: ctx.clientIdentity.getID(),
    txTimestamp: new Date(seconds * 1000).toISOString(),
  };
}

const json = (value: unknown): string => JSON.stringify(value);

@Info({ title: "EnergyMarket", description: "Simulated peer-to-peer energy double auction (rules cda-resting-price-v1)" })
export class EnergyMarketContract extends Contract {
  constructor() {
    super("EnergyMarket");
  }

  /** Operator: creates a session. participantsJson = [{"participantId":"h1","ownerId":null}, ...] */
  @Transaction()
  @Returns("string")
  public async OpenSession(ctx: Context, sessionId: string, rulesVersion: string, scenarioHash: string, participantsJson: string): Promise<string> {
    return json(await logic.openSession(callContext(ctx), sessionId, rulesVersion, scenarioHash, participantsJson));
  }

  /** Operator: opens an hour with per-participant caps. capsJson = {"sellCapsWh":{...},"buyCapsWh":{...}} */
  @Transaction()
  @Returns("string")
  public async OpenHour(ctx: Context, sessionId: string, hour: string, capsJson: string): Promise<string> {
    return json(await logic.openHour(callContext(ctx), sessionId, hour, capsJson));
  }

  /** Participant or operator: a batch of submit/cancel events, applied in order. */
  @Transaction()
  @Returns("string")
  public async SubmitOrders(ctx: Context, sessionId: string, hour: string, eventsJson: string): Promise<string> {
    return json(await logic.submitOrders(callContext(ctx), sessionId, hour, eventsJson));
  }

  /** Operator: closes the hour, cancels open orders, writes the chained summary. */
  @Transaction()
  @Returns("string")
  public async CloseHour(ctx: Context, sessionId: string, hour: string): Promise<string> {
    return json(await logic.closeHour(callContext(ctx), sessionId, hour));
  }

  /** Operator: closes the session (no more hours). */
  @Transaction()
  @Returns("string")
  public async CloseSession(ctx: Context, sessionId: string): Promise<string> {
    return json(await logic.closeSession(callContext(ctx), sessionId));
  }

  /** Operator: stores a participant's final result after checking the market figures against the ledger. */
  @Transaction()
  @Returns("string")
  public async RecordSettlement(ctx: Context, sessionId: string, participantId: string, settlementJson: string): Promise<string> {
    return json(await logic.recordSettlement(callContext(ctx), sessionId, participantId, settlementJson));
  }

  @Transaction(false)
  @Returns("string")
  public async GetSession(ctx: Context, sessionId: string): Promise<string> {
    return json(await logic.getSession(callContext(ctx), sessionId));
  }

  @Transaction(false)
  @Returns("string")
  public async GetOrderBook(ctx: Context, sessionId: string, hour: string): Promise<string> {
    return json(await logic.getOrderBook(callContext(ctx), sessionId, hour));
  }

  @Transaction(false)
  @Returns("string")
  public async GetEventLog(ctx: Context, sessionId: string, hour: string): Promise<string> {
    return json(await logic.getEventLog(callContext(ctx), sessionId, hour));
  }

  @Transaction(false)
  @Returns("string")
  public async GetTrades(ctx: Context, sessionId: string, hour: string): Promise<string> {
    return json(await logic.getTradesForHour(callContext(ctx), sessionId, hour));
  }

  @Transaction(false)
  @Returns("string")
  public async GetHourSummary(ctx: Context, sessionId: string, hour: string): Promise<string> {
    return json(await logic.getHourSummary(callContext(ctx), sessionId, hour));
  }

  /** Recomputes an hour's hashes from its stored events and compares with the stored summary. */
  @Transaction(false)
  @Returns("string")
  public async VerifyHour(ctx: Context, sessionId: string, hour: string): Promise<string> {
    return json(await logic.verifyHour(callContext(ctx), sessionId, hour));
  }
}
