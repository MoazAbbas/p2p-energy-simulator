#!/usr/bin/env bash
# Adds the Hyperledger Fabric chaincode (the on-chain double auction) to your repo and runs its tests.
# Creates blockchain/chaincode/energy-market/. Needs engine/ (setup-engine.sh); sim/ is optional but, when present,
# an extra test replays a whole simulated day through the chaincode and compares it with the simulator.
# Run from the repo root:  cd ~/projects/p2p-energy && bash setup-chaincode.sh
# It does not need Docker or the Fabric network: it only installs packages and runs unit tests.
set -euo pipefail

CC=blockchain/chaincode/energy-market
[ -f engine/src/engine.ts ] || { echo "engine/src/engine.ts not found - run setup-engine.sh first (and run this from the repo root)."; exit 1; }
if [ -e "$CC" ]; then echo "$CC already exists - stopping so nothing is overwritten."; exit 1; fi
command -v node >/dev/null || { echo "node not found"; exit 1; }
command -v openssl >/dev/null || { echo "openssl not found (the tests use it to make throw-away test certificates): sudo apt install openssl"; exit 1; }
NODE_MAJOR=$(node -p "process.versions.node.split('.')[0]")
[ "$NODE_MAJOR" -ge 20 ] || { echo "Node 20 or newer is needed (found $(node -v))."; exit 1; }

mkdir -p "$CC/src" "$CC/test"
# The chaincode carries its own copy of the engine (a chaincode package must be self-contained).
# A test fails if the copy ever differs from engine/src/engine.ts.
cp engine/src/engine.ts "$CC/src/engine.ts"

cat > "$CC/package.json" <<'P2P_EOF'
{
  "name": "energy-market",
  "version": "0.1.0",
  "description": "Simulated P2P energy double auction as Hyperledger Fabric chaincode (rules cda-resting-price-v1)",
  "main": "dist/index.js",
  "typings": "dist/index.d.ts",
  "engines": {
    "node": ">=20"
  },
  "scripts": {
    "start": "set -x && fabric-chaincode-node start",
    "build": "tsc -p tsconfig.build.json",
    "typecheck": "tsc --noEmit",
    "test": "npm run build && vitest run",
    "prepublishOnly": "npm run build"
  },
  "engineStrict": true,
  "license": "Apache-2.0",
  "dependencies": {
    "fabric-contract-api": "~2.5",
    "fabric-shim": "~2.5"
  },
  "devDependencies": {
    "@types/node": "^20.19.0",
    "typescript": "~5.8",
    "vitest": "^2.1.9"
  }
}
P2P_EOF

cat > "$CC/tsconfig.json" <<'P2P_EOF'
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "commonjs",
    "moduleResolution": "node",
    "lib": ["ES2022"],
    "types": ["node"],
    "strict": true,
    "noUnusedLocals": true,
    "noImplicitReturns": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true,
    "experimentalDecorators": true,
    "emitDecoratorMetadata": true,
    "noEmit": true
  },
  "include": ["src", "test"]
}
P2P_EOF

cat > "$CC/tsconfig.build.json" <<'P2P_EOF'
{
  "extends": "./tsconfig.json",
  "compilerOptions": {
    "noEmit": false,
    "outDir": "dist",
    "rootDir": "src",
    "declaration": true,
    "sourceMap": true
  },
  "include": ["src"]
}
P2P_EOF

cat > "$CC/src/logic.ts" <<'P2P_EOF'
/**
 * Market logic of the energy-market chaincode, independent of the Fabric SDK so it can be unit-tested
 * against a fake ledger. contract.ts is a thin wrapper that turns Fabric calls into calls to these functions.
 *
 * How the auction runs on the ledger (design option B):
 *   - every order and cancel of an hour is appended to that hour's record, in the order the ledger commits them
 *   - matching is done by the shared, deterministic Engine: each transaction rebuilds the hour's book by replaying
 *     the stored events, applies the new events, and writes the resulting trades
 *   - trades are stored one key each; closing an hour writes a summary whose hash is chained to the previous hour
 *
 * Determinism rules for chaincode: no clock, no randomness, no outside calls. The only time source is the
 * transaction timestamp passed in by the caller.
 */
import { createHash } from "crypto";
import { Engine, RULES_VERSION, type EngineEvent, type Trade } from "./engine";

export interface Store {
  key(objectType: string, attrs: readonly string[]): string;
  get(key: string): Promise<string | null>;
  put(key: string, value: string): Promise<void>;
  /** values (JSON text) of all keys that start with the given composite key, in key order */
  listByPrefix(objectType: string, attrs: readonly string[]): Promise<string[]>;
}

export interface CallContext {
  store: Store;
  /** identity of the caller, as reported by the Fabric client identity */
  callerId: string;
  /** ISO time of the transaction (taken from the transaction, identical on every peer) */
  txTimestamp: string;
}

export interface ParticipantReg {
  participantId: string;
  /** Fabric identity that may act for this participant besides the operator; null = operator only */
  ownerId: string | null;
}

export interface SessionRecord {
  sessionId: string;
  rulesVersion: string;
  /** sha-256 (hex) of the scenario and weather inputs, fixed at session start */
  scenarioHash: string;
  operatorId: string;
  participants: ParticipantReg[];
  status: "open" | "closed";
  openHour: number | null;
  lastClosedHour: number;
  lastClosedHash: string;
  createdAt: string;
}

export interface HourRecord {
  sessionId: string;
  hour: number;
  status: "open" | "closed";
  sellCapsWh: Record<string, number>;
  buyCapsWh: Record<string, number>;
  events: EngineEvent[];
}

export interface HourSummary {
  sessionId: string;
  hour: number;
  rulesVersion: string;
  eventCount: number;
  tradeCount: number;
  volumeWh: number;
  amount: number;
  cancelledOrders: number;
  cancelledWh: number;
  eventsHash: string;
  tradesHash: string;
  prevHash: string;
}

export interface StoredHourSummary extends HourSummary {
  summaryHash: string;
}

export interface StoredTrade extends Trade {
  sessionId: string;
  hour: number;
}

export const MAX_EVENTS_PER_BATCH = 500;
export const MAX_EVENTS_PER_HOUR = 20000;

const ID_RE = /^[A-Za-z0-9_-]{1,64}$/;
const ORDER_ID_RE = /^[A-Za-z0-9_.:-]{1,64}$/;
const HEX64_RE = /^[0-9a-f]{64}$/;

function fail(message: string): never {
  throw new Error(`EnergyMarket: ${message}`);
}

export function sha256(text: string): string {
  return createHash("sha256").update(text, "utf8").digest("hex");
}

function parseJson(text: string, what: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return fail(`${what} is not valid JSON`);
  }
}

function checkId(value: unknown, what: string): string {
  if (typeof value !== "string" || !ID_RE.test(value) || value === "__proto__") {
    return fail(`${what} must be 1-64 characters from A-Z a-z 0-9 _ -`);
  }
  return value;
}

export function parseHour(value: unknown): number {
  const n = typeof value === "string" && /^\d+$/.test(value) ? Number(value) : value;
  if (typeof n !== "number" || !Number.isInteger(n) || n < 0 || n > 23) return fail("hour must be an integer 0..23");
  return n;
}

const hh = (h: number): string => String(h).padStart(2, "0");
const seqKey = (n: number): string => String(n).padStart(6, "0");

async function loadSession(c: CallContext, sessionId: string): Promise<SessionRecord> {
  checkId(sessionId, "sessionId");
  const text = await c.store.get(c.store.key("session", [sessionId]));
  if (text === null) return fail(`session ${sessionId} does not exist`);
  return JSON.parse(text) as SessionRecord;
}

async function saveSession(c: CallContext, s: SessionRecord): Promise<void> {
  await c.store.put(c.store.key("session", [s.sessionId]), JSON.stringify(s));
}

async function loadHour(c: CallContext, sessionId: string, hour: number): Promise<HourRecord> {
  const text = await c.store.get(c.store.key("hour", [sessionId, hh(hour)]));
  if (text === null) return fail(`hour ${hour} of session ${sessionId} does not exist`);
  return JSON.parse(text) as HourRecord;
}

function requireOperator(s: SessionRecord, c: CallContext): void {
  if (c.callerId !== s.operatorId) fail("only the session operator may do this");
}

function requireOpen(s: SessionRecord): void {
  if (s.status !== "open") fail(`session ${s.sessionId} is closed`);
}

function authorize(s: SessionRecord, participantId: string, c: CallContext): void {
  const reg = s.participants.find((p) => p.participantId === participantId);
  if (reg === undefined) return fail(`participant ${participantId} is not registered in this session`);
  if (c.callerId !== s.operatorId && reg.ownerId !== c.callerId) {
    fail(`caller may not act for participant ${participantId}`);
  }
}

function buildEngine(h: HourRecord): Engine {
  const engine = new Engine({ sellCapsWh: h.sellCapsWh, buyCapsWh: h.buyCapsWh });
  for (const ev of h.events) engine.apply(ev);
  return engine;
}

/** Fixed field order, so the stored (and hashed) JSON is identical on every peer. */
function normalizeEvent(raw: unknown): EngineEvent {
  if (typeof raw !== "object" || raw === null) return fail("every event must be an object");
  const e = raw as Record<string, unknown>;
  if (e.type === "submit") {
    const o = e.order as Record<string, unknown> | null;
    if (typeof o !== "object" || o === null) return fail("submit event needs an 'order' object");
    if (typeof o.orderId !== "string" || !ORDER_ID_RE.test(o.orderId)) return fail("orderId must be 1-64 characters from A-Z a-z 0-9 _ . : -");
    if (typeof o.participantId !== "string") return fail("participantId must be a string");
    return {
      type: "submit",
      order: {
        orderId: o.orderId,
        participantId: o.participantId,
        side: o.side as "buy" | "sell",
        price: o.price as number,
        qtyWh: o.qtyWh as number,
      },
    };
  }
  if (e.type === "cancel") {
    if (typeof e.orderId !== "string" || typeof e.participantId !== "string") return fail("cancel event needs orderId and participantId strings");
    return { type: "cancel", orderId: e.orderId, participantId: e.participantId };
  }
  return fail("event type must be 'submit' or 'cancel' (closing an hour has its own transaction)");
}

export async function openSession(
  c: CallContext,
  sessionId: string,
  rulesVersion: string,
  scenarioHash: string,
  participantsJson: string,
): Promise<SessionRecord> {
  checkId(sessionId, "sessionId");
  if (rulesVersion !== RULES_VERSION) fail(`rulesVersion must be ${RULES_VERSION}`);
  if (!HEX64_RE.test(scenarioHash)) fail("scenarioHash must be 64 lowercase hex characters (sha-256)");
  const raw = parseJson(participantsJson, "participants");
  if (!Array.isArray(raw) || raw.length === 0 || raw.length > 2000) fail("participants must be a non-empty array (max 2000)");
  const seen = new Set<string>();
  const participants: ParticipantReg[] = [];
  for (const p of raw as Array<Record<string, unknown>>) {
    const id = checkId(p?.participantId, "participantId");
    if (seen.has(id)) fail(`participant ${id} listed twice`);
    seen.add(id);
    const owner = p.ownerId;
    if (owner !== undefined && owner !== null && (typeof owner !== "string" || owner.length === 0 || owner.length > 1024)) {
      fail("ownerId must be a non-empty string or omitted");
    }
    participants.push({ participantId: id, ownerId: typeof owner === "string" ? owner : null });
  }
  const key = c.store.key("session", [sessionId]);
  if ((await c.store.get(key)) !== null) fail(`session ${sessionId} already exists`);
  const session: SessionRecord = {
    sessionId,
    rulesVersion,
    scenarioHash,
    operatorId: c.callerId,
    participants,
    status: "open",
    openHour: null,
    lastClosedHour: -1,
    lastClosedHash: scenarioHash,
    createdAt: c.txTimestamp,
  };
  await saveSession(c, session);
  return session;
}

export async function openHour(c: CallContext, sessionId: string, hourValue: unknown, capsJson: string): Promise<{ sessionId: string; hour: number; status: "open" }> {
  const s = await loadSession(c, sessionId);
  requireOpen(s);
  requireOperator(s, c);
  const hour = parseHour(hourValue);
  if (s.openHour !== null) fail(`hour ${s.openHour} is still open; close it first`);
  if (hour <= s.lastClosedHour) fail(`hours must increase: hour ${s.lastClosedHour} is already closed`);
  const raw = parseJson(capsJson, "caps") as { sellCapsWh?: unknown; buyCapsWh?: unknown };
  const sell = raw?.sellCapsWh;
  const buy = raw?.buyCapsWh;
  if (typeof sell !== "object" || sell === null || typeof buy !== "object" || buy === null) {
    fail("caps must be an object with sellCapsWh and buyCapsWh objects");
  }
  for (const id of [...Object.keys(sell), ...Object.keys(buy)]) {
    if (!s.participants.some((p) => p.participantId === id)) fail(`cap given for unregistered participant ${id}`);
  }
  // The Engine constructor validates the cap values (non-negative integers); it throws otherwise.
  new Engine({ sellCapsWh: sell as Record<string, number>, buyCapsWh: buy as Record<string, number> });
  const hourKey = c.store.key("hour", [sessionId, hh(hour)]);
  if ((await c.store.get(hourKey)) !== null) fail(`hour ${hour} already exists`);
  const record: HourRecord = {
    sessionId,
    hour,
    status: "open",
    sellCapsWh: sell as Record<string, number>,
    buyCapsWh: buy as Record<string, number>,
    events: [],
  };
  s.openHour = hour;
  await c.store.put(hourKey, JSON.stringify(record));
  await saveSession(c, s);
  return { sessionId, hour, status: "open" };
}

export interface EventOutcome {
  ok: boolean;
  seq?: number;
  restingWh?: number;
  tradeSeqs?: number[];
  cancelledWh?: number;
  reason?: string;
  message?: string;
}

export async function submitOrders(
  c: CallContext,
  sessionId: string,
  hourValue: unknown,
  eventsJson: string,
): Promise<{ results: EventOutcome[]; trades: StoredTrade[]; eventCount: number }> {
  const s = await loadSession(c, sessionId);
  requireOpen(s);
  const hour = parseHour(hourValue);
  if (s.openHour !== hour) fail(`hour ${hour} is not the open hour`);
  const raw = parseJson(eventsJson, "events");
  if (!Array.isArray(raw) || raw.length === 0 || raw.length > MAX_EVENTS_PER_BATCH) {
    fail(`events must be a non-empty array of at most ${MAX_EVENTS_PER_BATCH}`);
  }
  const events = raw.map(normalizeEvent);
  for (const e of events) authorize(s, e.type === "submit" ? e.order.participantId : (e as { participantId: string }).participantId, c);

  const h = await loadHour(c, sessionId, hour);
  if (h.status !== "open") fail(`hour ${hour} is closed`);
  if (h.events.length + events.length > MAX_EVENTS_PER_HOUR) fail("too many events in this hour");

  const engine = buildEngine(h);
  const before = engine.getTrades().length;
  const results: EventOutcome[] = events.map((e) => {
    const r = engine.apply(e);
    if (!r.ok) return { ok: false, reason: (r as { reason: string }).reason, message: (r as { message: string }).message };
    if ("trades" in r) return { ok: true, seq: r.seq, restingWh: r.restingWh, tradeSeqs: r.trades.map((t) => t.seq) };
    if ("cancelledWh" in r) return { ok: true, cancelledWh: r.cancelledWh };
    return { ok: true };
  });
  const trades: StoredTrade[] = engine.getTrades().slice(before).map((t) => ({ sessionId, hour, ...t }));
  h.events.push(...events);
  await c.store.put(c.store.key("hour", [sessionId, hh(hour)]), JSON.stringify(h));
  for (const t of trades) await c.store.put(c.store.key("trade", [sessionId, hh(hour), seqKey(t.seq)]), JSON.stringify(t));
  return { results, trades, eventCount: h.events.length };
}

export async function closeHour(c: CallContext, sessionId: string, hourValue: unknown): Promise<StoredHourSummary> {
  const s = await loadSession(c, sessionId);
  requireOpen(s);
  requireOperator(s, c);
  const hour = parseHour(hourValue);
  if (s.openHour !== hour) fail(`hour ${hour} is not the open hour`);
  const h = await loadHour(c, sessionId, hour);
  const engine = buildEngine(h);
  const trades = engine.getTrades();
  const closed = engine.closeHour();
  const summary: HourSummary = {
    sessionId,
    hour,
    rulesVersion: s.rulesVersion,
    eventCount: h.events.length,
    tradeCount: trades.length,
    volumeWh: trades.reduce((a, t) => a + t.qtyWh, 0),
    amount: trades.reduce((a, t) => a + t.amount, 0),
    cancelledOrders: closed.cancelled.length,
    cancelledWh: closed.cancelled.reduce((a, o) => a + o.remainingWh, 0),
    eventsHash: sha256(JSON.stringify(h.events)),
    tradesHash: sha256(JSON.stringify(trades)),
    prevHash: s.lastClosedHash,
  };
  const stored: StoredHourSummary = { ...summary, summaryHash: sha256(JSON.stringify(summary)) };
  h.status = "closed";
  s.openHour = null;
  s.lastClosedHour = hour;
  s.lastClosedHash = stored.summaryHash;
  await c.store.put(c.store.key("hour", [sessionId, hh(hour)]), JSON.stringify(h));
  await c.store.put(c.store.key("summary", [sessionId, hh(hour)]), JSON.stringify(stored));
  await saveSession(c, s);
  return stored;
}

export async function closeSession(c: CallContext, sessionId: string): Promise<SessionRecord> {
  const s = await loadSession(c, sessionId);
  requireOpen(s);
  requireOperator(s, c);
  if (s.openHour !== null) fail(`hour ${s.openHour} is still open; close it first`);
  s.status = "closed";
  await saveSession(c, s);
  return s;
}

export interface Settlement {
  sessionId: string;
  participantId: string;
  boughtWh: number;
  soldWh: number;
  paid: number;
  received: number;
  costA: number;
  costB: number;
  costC: number;
  premium: number;
  recordedAt: string;
}

const nonNegInt = (v: unknown, what: string): number => {
  if (typeof v !== "number" || !Number.isSafeInteger(v) || v < 0) return fail(`${what} must be a non-negative integer`);
  return v;
};

/**
 * Stores a participant's end-of-session result. The market figures (bought, sold, paid, received) are checked
 * against the trades on the ledger; the three costs come from the backend's tariff model and are stored as given.
 */
export async function recordSettlement(c: CallContext, sessionId: string, participantId: string, settlementJson: string): Promise<Settlement> {
  const s = await loadSession(c, sessionId);
  requireOperator(s, c);
  if (s.status !== "closed") fail("close the session before recording settlements");
  if (!s.participants.some((p) => p.participantId === participantId)) fail(`participant ${participantId} is not registered`);
  const raw = parseJson(settlementJson, "settlement") as Record<string, unknown>;
  const claimed = {
    boughtWh: nonNegInt(raw?.boughtWh, "boughtWh"),
    soldWh: nonNegInt(raw?.soldWh, "soldWh"),
    paid: nonNegInt(raw?.paid, "paid"),
    received: nonNegInt(raw?.received, "received"),
  };
  const costA = raw.costA as number;
  const costB = raw.costB as number;
  const costC = raw.costC as number;
  for (const [name, v] of [["costA", costA], ["costB", costB], ["costC", costC]] as const) {
    if (typeof v !== "number" || !Number.isSafeInteger(v)) fail(`${name} must be an integer (piastres)`);
  }
  const key = c.store.key("settlement", [sessionId, participantId]);
  if ((await c.store.get(key)) !== null) fail(`settlement for ${participantId} already recorded`);

  const ledger = { boughtWh: 0, soldWh: 0, paid: 0, received: 0 };
  for (const text of await c.store.listByPrefix("trade", [sessionId])) {
    const t = JSON.parse(text) as StoredTrade;
    if (t.buyerId === participantId) {
      ledger.boughtWh += t.qtyWh;
      ledger.paid += t.amount;
    }
    if (t.sellerId === participantId) {
      ledger.soldWh += t.qtyWh;
      ledger.received += t.amount;
    }
  }
  for (const k of ["boughtWh", "soldWh", "paid", "received"] as const) {
    if (claimed[k] !== ledger[k]) fail(`${k} claimed ${claimed[k]} but the ledger has ${ledger[k]}`);
  }
  const settlement: Settlement = { sessionId, participantId, ...claimed, costA, costB, costC, premium: costB - costC, recordedAt: c.txTimestamp };
  await c.store.put(key, JSON.stringify(settlement));
  return settlement;
}

export async function getSession(c: CallContext, sessionId: string): Promise<SessionRecord> {
  return loadSession(c, sessionId);
}

export async function getOrderBook(c: CallContext, sessionId: string, hourValue: unknown) {
  await loadSession(c, sessionId);
  const hour = parseHour(hourValue);
  const h = await loadHour(c, sessionId, hour);
  if (h.status === "closed") return { sessionId, hour, status: "closed" as const, bids: [], asks: [] };
  return { sessionId, hour, status: "open" as const, ...buildEngine(h).getBook() };
}

export async function getEventLog(c: CallContext, sessionId: string, hourValue: unknown): Promise<EngineEvent[]> {
  await loadSession(c, sessionId);
  return (await loadHour(c, sessionId, parseHour(hourValue))).events;
}

export async function getTradesForHour(c: CallContext, sessionId: string, hourValue: unknown): Promise<StoredTrade[]> {
  await loadSession(c, sessionId);
  const hour = parseHour(hourValue);
  return (await c.store.listByPrefix("trade", [sessionId, hh(hour)])).map((t) => JSON.parse(t) as StoredTrade);
}

export async function getHourSummary(c: CallContext, sessionId: string, hourValue: unknown): Promise<StoredHourSummary> {
  await loadSession(c, sessionId);
  const hour = parseHour(hourValue);
  const text = await c.store.get(c.store.key("summary", [sessionId, hh(hour)]));
  if (text === null) return fail(`hour ${hour} has no summary (not closed yet)`);
  return JSON.parse(text) as StoredHourSummary;
}

/** Recomputes the hashes of a stored hour and checks the chain link; used by auditors and by the tests. */
export async function verifyHour(c: CallContext, sessionId: string, hourValue: unknown): Promise<{ ok: boolean; problems: string[] }> {
  const hour = parseHour(hourValue);
  const h = await loadHour(c, sessionId, hour);
  const stored = await getHourSummary(c, sessionId, hour);
  const problems: string[] = [];
  const engine = buildEngine(h);
  const trades = engine.getTrades();
  if (sha256(JSON.stringify(h.events)) !== stored.eventsHash) problems.push("eventsHash does not match the stored events");
  if (sha256(JSON.stringify(trades)) !== stored.tradesHash) problems.push("tradesHash does not match a replay of the events");
  const { summaryHash, ...rest } = stored;
  if (sha256(JSON.stringify(rest)) !== summaryHash) problems.push("summaryHash does not match the summary");
  const onLedger = (await getTradesForHour(c, sessionId, hour)).map(({ sessionId: _s, hour: _h, ...t }) => t);
  if (JSON.stringify(onLedger) !== JSON.stringify(trades)) problems.push("trade records differ from a replay of the events");
  return { ok: problems.length === 0, problems };
}
P2P_EOF

cat > "$CC/src/contract.ts" <<'P2P_EOF'
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
P2P_EOF

cat > "$CC/src/index.ts" <<'P2P_EOF'
import { EnergyMarketContract } from "./contract";

export { EnergyMarketContract };
export const contracts: unknown[] = [EnergyMarketContract];
P2P_EOF

cat > "$CC/test/fakeStore.ts" <<'P2P_EOF'
import type { CallContext, Store } from "../src/logic";

const SEP = "\u0000";

/** In-memory ledger with the same key shape and ordering as Fabric composite keys. */
export class FakeStore implements Store {
  readonly data = new Map<string, string>();

  key(objectType: string, attrs: readonly string[]): string {
    return SEP + objectType + SEP + attrs.join(SEP) + SEP;
  }

  async get(key: string): Promise<string | null> {
    return this.data.get(key) ?? null;
  }

  async put(key: string, value: string): Promise<void> {
    this.data.set(key, value);
  }

  async listByPrefix(objectType: string, attrs: readonly string[]): Promise<string[]> {
    const prefix = SEP + objectType + SEP + attrs.map((a) => a + SEP).join("");
    return [...this.data.keys()]
      .filter((k) => k.startsWith(prefix))
      .sort()
      .map((k) => this.data.get(k)!);
  }

  snapshot(): string {
    return JSON.stringify([...this.data.entries()].sort());
  }
}

export const SCENARIO_HASH = "a".repeat(64);

/** Context factory: the same ledger, a different caller (and a fixed, increasing transaction time). */
export function as(store: FakeStore, callerId: string): CallContext {
  return { store, callerId, txTimestamp: "2026-10-21T12:00:00.000Z" };
}
P2P_EOF

cat > "$CC/test/logic.test.ts" <<'P2P_EOF'
import { describe, expect, it } from "vitest";
import { RULES_VERSION } from "../src/engine";
import * as L from "../src/logic";
import { FakeStore, SCENARIO_HASH, as } from "./fakeStore";

const OP = "operator";
const ALICE = "x509::alice";
const BOB = "x509::bob";

const participants = JSON.stringify([
  { participantId: "S1", ownerId: ALICE },
  { participantId: "B1", ownerId: BOB },
  { participantId: "B2", ownerId: null },
]);
const caps = JSON.stringify({ sellCapsWh: { S1: 1000 }, buyCapsWh: { B1: 1000, B2: 1000 } });

const sell = (orderId: string, participantId: string, price: number, qtyWh: number) => ({
  type: "submit",
  order: { orderId, participantId, side: "sell", price, qtyWh },
});
const buy = (orderId: string, participantId: string, price: number, qtyWh: number) => ({
  type: "submit",
  order: { orderId, participantId, side: "buy", price, qtyWh },
});

async function started(): Promise<FakeStore> {
  const st = new FakeStore();
  await L.openSession(as(st, OP), "S", RULES_VERSION, SCENARIO_HASH, participants);
  return st;
}
async function withHour(h = 12): Promise<FakeStore> {
  const st = await started();
  await L.openHour(as(st, OP), "S", h, caps);
  return st;
}

describe("opening a session", () => {
  it("stores the session with the operator, scenario hash and registered participants", async () => {
    const st = await started();
    const s = await L.getSession(as(st, "anyone"), "S");
    expect(s).toMatchObject({ status: "open", operatorId: OP, scenarioHash: SCENARIO_HASH, lastClosedHour: -1, lastClosedHash: SCENARIO_HASH });
    expect(s.participants.map((p) => p.participantId)).toEqual(["S1", "B1", "B2"]);
    expect(s.participants[2]!.ownerId).toBeNull();
  });

  it("rejects bad input", async () => {
    const st = new FakeStore();
    const c = as(st, OP);
    await expect(L.openSession(c, "S", "other-rules", SCENARIO_HASH, participants)).rejects.toThrow(/rulesVersion/);
    await expect(L.openSession(c, "S", RULES_VERSION, "ABC", participants)).rejects.toThrow(/scenarioHash/);
    await expect(L.openSession(c, "bad id!", RULES_VERSION, SCENARIO_HASH, participants)).rejects.toThrow(/sessionId/);
    await expect(L.openSession(c, "S", RULES_VERSION, SCENARIO_HASH, "not json")).rejects.toThrow(/valid JSON/);
    await expect(L.openSession(c, "S", RULES_VERSION, SCENARIO_HASH, "[]")).rejects.toThrow(/non-empty/);
    await expect(L.openSession(c, "S", RULES_VERSION, SCENARIO_HASH, JSON.stringify([{ participantId: "A" }, { participantId: "A" }]))).rejects.toThrow(/twice/);
    await expect(L.openSession(c, "S", RULES_VERSION, SCENARIO_HASH, JSON.stringify([{ participantId: "__proto__" }]))).rejects.toThrow(/participantId/);
    expect(st.data.size).toBe(0);
  });

  it("refuses to reuse a session id", async () => {
    const st = await started();
    await expect(L.openSession(as(st, OP), "S", RULES_VERSION, SCENARIO_HASH, participants)).rejects.toThrow(/already exists/);
  });
});

describe("hour lifecycle", () => {
  it("only the operator opens and closes hours; one hour at a time; hours increase", async () => {
    const st = await started();
    await expect(L.openHour(as(st, ALICE), "S", 12, caps)).rejects.toThrow(/only the session operator/);
    await L.openHour(as(st, OP), "S", 12, caps);
    await expect(L.openHour(as(st, OP), "S", 13, caps)).rejects.toThrow(/still open/);
    await expect(L.closeHour(as(st, ALICE), "S", 12)).rejects.toThrow(/only the session operator/);
    await expect(L.closeHour(as(st, OP), "S", 13)).rejects.toThrow(/not the open hour/);
    await L.closeHour(as(st, OP), "S", 12);
    await expect(L.openHour(as(st, OP), "S", 12, caps)).rejects.toThrow(/must increase/);
    await expect(L.openHour(as(st, OP), "S", 11, caps)).rejects.toThrow(/must increase/);
    await L.openHour(as(st, OP), "S", 14, caps);
  });

  it("validates hour numbers and caps", async () => {
    const st = await started();
    await expect(L.openHour(as(st, OP), "S", 24, caps)).rejects.toThrow(/0..23/);
    await expect(L.openHour(as(st, OP), "S", "x", caps)).rejects.toThrow(/0..23/);
    await expect(L.openHour(as(st, OP), "S", 12, JSON.stringify({ sellCapsWh: { NOBODY: 5 }, buyCapsWh: {} }))).rejects.toThrow(/unregistered/);
    await expect(L.openHour(as(st, OP), "S", 12, JSON.stringify({ sellCapsWh: { S1: -5 }, buyCapsWh: {} }))).rejects.toThrow();
    await expect(L.openHour(as(st, OP), "S", 12, "{}")).rejects.toThrow(/caps/);
    await L.openHour(as(st, OP), "S", "12", caps); // digit strings are what Fabric passes
  });

  it("a closed session accepts nothing more", async () => {
    const st = await withHour();
    await expect(L.closeSession(as(st, OP), "S")).rejects.toThrow(/still open/);
    await L.closeHour(as(st, OP), "S", 12);
    await expect(L.closeSession(as(st, ALICE), "S")).rejects.toThrow(/only the session operator/);
    await L.closeSession(as(st, OP), "S");
    await expect(L.openHour(as(st, OP), "S", 13, caps)).rejects.toThrow(/closed/);
    await expect(L.submitOrders(as(st, OP), "S", 12, JSON.stringify([buy("o1", "B1", 100, 10)]))).rejects.toThrow(/closed/);
  });
});

describe("trading", () => {
  it("matches at the resting order's price and stores the trade", async () => {
    const st = await withHour();
    const r1 = await L.submitOrders(as(st, ALICE), "S", 12, JSON.stringify([sell("a1", "S1", 120, 1000)]));
    expect(r1.results).toEqual([{ ok: true, seq: 1, restingWh: 1000, tradeSeqs: [] }]);
    expect(r1.trades).toEqual([]);

    const r2 = await L.submitOrders(as(st, BOB), "S", 12, JSON.stringify([buy("b1", "B1", 150, 600)]));
    expect(r2.results[0]).toMatchObject({ ok: true, restingWh: 0, tradeSeqs: [1] });
    expect(r2.trades).toEqual([
      { sessionId: "S", hour: 12, seq: 1, buyOrderId: "b1", sellOrderId: "a1", buyerId: "B1", sellerId: "S1", qtyWh: 600, price: 120, amount: 72, restingSide: "sell" },
    ]);

    const book = await L.getOrderBook(as(st, "anyone"), "S", 12);
    expect(book.status).toBe("open");
    if (book.status === "open") {
      expect(book.asks).toHaveLength(1);
      expect(book.asks[0]).toMatchObject({ orderId: "a1", remainingWh: 400 });
      expect(book.bids).toHaveLength(0);
    }
    expect(await L.getTradesForHour(as(st, "anyone"), "S", 12)).toHaveLength(1);
  });

  it("records rejected events instead of failing the transaction, and replays them identically", async () => {
    const st = await withHour();
    const r = await L.submitOrders(
      as(st, OP),
      "S",
      12,
      JSON.stringify([sell("a1", "S1", 120, 900), sell("a2", "S1", 120, 900), buy("b1", "B1", 0, 10), { type: "cancel", orderId: "zzz", participantId: "S1" }]),
    );
    expect(r.results.map((x) => x.ok)).toEqual([true, false, false, false]);
    expect(r.results.map((x) => x.reason)).toEqual([undefined, "CAP_EXCEEDED", "INVALID_ORDER", "NOT_FOUND"]);
    expect(r.eventCount).toBe(4);
    // the first order still rests exactly as before
    const book = await L.getOrderBook(as(st, OP), "S", 12);
    if (book.status === "open") expect(book.asks.map((o) => o.orderId)).toEqual(["a1"]);
    // a second batch sees the same state
    const r2 = await L.submitOrders(as(st, OP), "S", 12, JSON.stringify([buy("b2", "B1", 130, 100)]));
    expect(r2.trades[0]).toMatchObject({ sellOrderId: "a1", price: 120, qtyWh: 100 });
  });

  it("a cancel frees the cap and removes the order from the book", async () => {
    const st = await withHour();
    await L.submitOrders(as(st, ALICE), "S", 12, JSON.stringify([sell("a1", "S1", 120, 1000)]));
    const r = await L.submitOrders(as(st, ALICE), "S", 12, JSON.stringify([{ type: "cancel", orderId: "a1", participantId: "S1" }, sell("a2", "S1", 110, 1000)]));
    expect(r.results[0]).toEqual({ ok: true, cancelledWh: 1000 });
    expect(r.results[1]!.ok).toBe(true);
    const book = await L.getOrderBook(as(st, OP), "S", 12);
    if (book.status === "open") expect(book.asks.map((o) => o.orderId)).toEqual(["a2"]);
  });

  it("enforces who may act for whom", async () => {
    const st = await withHour();
    const sub = (caller: string, ev: unknown) => L.submitOrders(as(st, caller), "S", 12, JSON.stringify([ev]));
    await expect(sub(BOB, sell("a1", "S1", 120, 100))).rejects.toThrow(/may not act/);
    await expect(sub("stranger", buy("b1", "B1", 120, 100))).rejects.toThrow(/may not act/);
    await expect(sub(ALICE, { type: "cancel", orderId: "x", participantId: "B1" })).rejects.toThrow(/may not act/);
    await expect(sub(OP, buy("b1", "NOBODY", 120, 100))).rejects.toThrow(/not registered/);
    await expect(sub(BOB, buy("b2", "B2", 120, 100))).rejects.toThrow(/may not act/); // B2 has no owner: operator only
    await sub(OP, buy("b2", "B2", 120, 100)); // the operator may act for any participant (bots)
    await sub(ALICE, sell("a1", "S1", 120, 100));
  });

  it("is all-or-nothing: one unauthorized event in a batch changes nothing", async () => {
    const st = await withHour();
    const before = st.snapshot();
    await expect(L.submitOrders(as(st, ALICE), "S", 12, JSON.stringify([sell("a1", "S1", 120, 100), buy("b1", "B1", 120, 100)]))).rejects.toThrow(/may not act/);
    expect(st.snapshot()).toBe(before);
  });

  it("rejects malformed batches", async () => {
    const st = await withHour();
    const sub = (events: string) => L.submitOrders(as(st, OP), "S", 12, events);
    await expect(sub("nope")).rejects.toThrow(/valid JSON/);
    await expect(sub("[]")).rejects.toThrow(/non-empty/);
    await expect(sub("{}")).rejects.toThrow(/non-empty/);
    await expect(sub(JSON.stringify([{ type: "close" }]))).rejects.toThrow(/event type/);
    await expect(sub(JSON.stringify([null]))).rejects.toThrow(/object/);
    await expect(sub(JSON.stringify([{ type: "submit" }]))).rejects.toThrow(/order/);
    await expect(sub(JSON.stringify([buy("bad id", "B1", 100, 1)]))).rejects.toThrow(/orderId/);
    const many = Array.from({ length: L.MAX_EVENTS_PER_BATCH + 1 }, (_, i) => buy(`o${i}`, "B1", 100, 1));
    await expect(sub(JSON.stringify(many))).rejects.toThrow(/at most/);
    await expect(L.submitOrders(as(st, OP), "S", 13, JSON.stringify([buy("o1", "B1", 100, 1)]))).rejects.toThrow(/not the open hour/);
  });

  it("normalises extra fields away so stored events are identical on every peer", async () => {
    const st = await withHour();
    const ev = { type: "submit", extra: 1, order: { qtyWh: 10, price: 100, side: "buy", participantId: "B1", orderId: "o1", junk: true } };
    await L.submitOrders(as(st, OP), "S", 12, JSON.stringify([ev]));
    const log = await L.getEventLog(as(st, OP), "S", 12);
    expect(JSON.stringify(log)).toBe('[{"type":"submit","order":{"orderId":"o1","participantId":"B1","side":"buy","price":100,"qtyWh":10}}]');
  });
});

async function playTwoHours(): Promise<FakeStore> {
  const st = await started();
  await L.openHour(as(st, OP), "S", 12, caps);
  await L.submitOrders(as(st, ALICE), "S", 12, JSON.stringify([sell("a1", "S1", 120, 1000)]));
  await L.submitOrders(as(st, BOB), "S", 12, JSON.stringify([buy("b1", "B1", 150, 600)]));
  await L.submitOrders(as(st, OP), "S", 12, JSON.stringify([buy("b2", "B2", 110, 600)]));
  await L.closeHour(as(st, OP), "S", 12);
  await L.openHour(as(st, OP), "S", 13, caps);
  await L.submitOrders(as(st, BOB), "S", 13, JSON.stringify([buy("b1", "B1", 140, 300)]));
  await L.submitOrders(as(st, ALICE), "S", 13, JSON.stringify([sell("a1", "S1", 100, 300)]));
  await L.closeHour(as(st, OP), "S", 13);
  return st;
}

describe("closing an hour", () => {
  it("writes a summary of the hour and cancels what is left", async () => {
    const st = await playTwoHours();
    const s12 = await L.getHourSummary(as(st, OP), "S", 12);
    expect(s12).toMatchObject({ hour: 12, eventCount: 3, tradeCount: 1, volumeWh: 600, amount: 72, cancelledOrders: 2, cancelledWh: 400 + 600 });
    const book = await L.getOrderBook(as(st, OP), "S", 12);
    expect(book).toMatchObject({ status: "closed", bids: [], asks: [] });
    // resting buy at 140 met the later ask at 100: the resting (buy) price 140 is the trade price
    const t13 = await L.getTradesForHour(as(st, OP), "S", 13);
    expect(t13).toHaveLength(1);
    expect(t13[0]).toMatchObject({ price: 140, qtyWh: 300, amount: 42, restingSide: "buy" });
  });

  it("chains each hour's hash to the one before, starting from the scenario hash", async () => {
    const st = await playTwoHours();
    const s12 = await L.getHourSummary(as(st, OP), "S", 12);
    const s13 = await L.getHourSummary(as(st, OP), "S", 13);
    expect(s12.prevHash).toBe(SCENARIO_HASH);
    expect(s13.prevHash).toBe(s12.summaryHash);
    expect((await L.getSession(as(st, OP), "S")).lastClosedHash).toBe(s13.summaryHash);
    expect(s12.summaryHash).toMatch(/^[0-9a-f]{64}$/);
    expect(s12.summaryHash).not.toBe(s13.summaryHash);
    expect(await L.verifyHour(as(st, OP), "S", 12)).toEqual({ ok: true, problems: [] });
    expect(await L.verifyHour(as(st, OP), "S", 13)).toEqual({ ok: true, problems: [] });
  });

  it("the same inputs always give the same hashes", async () => {
    const a = await L.getHourSummary(as(await playTwoHours(), OP), "S", 13);
    const b = await L.getHourSummary(as(await playTwoHours(), OP), "S", 13);
    expect(a.summaryHash).toBe(b.summaryHash);
  });

  it("detects tampering with stored events, trades or the summary", async () => {
    const hourKey = (st: FakeStore) => st.key("hour", ["S", "12"]);

    // 1. an order removed from the stored event log
    let st = await playTwoHours();
    let rec = JSON.parse(st.data.get(hourKey(st))!);
    rec.events.splice(1, 1);
    st.data.set(hourKey(st), JSON.stringify(rec));
    let v = await L.verifyHour(as(st, OP), "S", 12);
    expect(v.ok).toBe(false);
    expect(v.problems.join(" ")).toMatch(/eventsHash/);

    // 2. a price edited in the stored event log
    st = await playTwoHours();
    rec = JSON.parse(st.data.get(hourKey(st))!);
    rec.events[0].order.price = 1;
    st.data.set(hourKey(st), JSON.stringify(rec));
    expect((await L.verifyHour(as(st, OP), "S", 12)).ok).toBe(false);

    // 3. a trade record edited
    st = await playTwoHours();
    const tradeKey = st.key("trade", ["S", "12", "000001"]);
    const t = JSON.parse(st.data.get(tradeKey)!);
    t.amount += 1;
    st.data.set(tradeKey, JSON.stringify(t));
    v = await L.verifyHour(as(st, OP), "S", 12);
    expect(v.ok).toBe(false);
    expect(v.problems.join(" ")).toMatch(/trade records/);

    // 4. the summary edited
    st = await playTwoHours();
    const sumKey = st.key("summary", ["S", "12"]);
    const s = JSON.parse(st.data.get(sumKey)!);
    s.amount += 1;
    st.data.set(sumKey, JSON.stringify(s));
    v = await L.verifyHour(as(st, OP), "S", 12);
    expect(v.ok).toBe(false);
    expect(v.problems.join(" ")).toMatch(/summaryHash/);
  });

  it("the next hour's prevHash exposes a rewritten earlier summary", async () => {
    const st = await playTwoHours();
    const sumKey = st.key("summary", ["S", "12"]);
    const s12 = JSON.parse(st.data.get(sumKey)!);
    const s13 = await L.getHourSummary(as(st, OP), "S", 13);
    // an attacker who rewrites hour 12 and recomputes its hash still cannot match hour 13's prevHash
    const forged = { ...s12, amount: s12.amount + 100 };
    const { summaryHash: _drop, ...body } = forged;
    forged.summaryHash = L.sha256(JSON.stringify(body));
    st.data.set(sumKey, JSON.stringify(forged));
    expect(forged.summaryHash).not.toBe(s13.prevHash);
  });
});

describe("settlement", () => {
  const good = { boughtWh: 600, soldWh: 0, paid: 72 + 0, received: 0, costA: 1000, costB: 900, costC: 850 };

  async function closed(): Promise<FakeStore> {
    const st = await started();
    await L.openHour(as(st, OP), "S", 12, caps);
    await L.submitOrders(as(st, ALICE), "S", 12, JSON.stringify([sell("a1", "S1", 120, 1000)]));
    await L.submitOrders(as(st, BOB), "S", 12, JSON.stringify([buy("b1", "B1", 150, 600)]));
    await L.closeHour(as(st, OP), "S", 12);
    await L.closeSession(as(st, OP), "S");
    return st;
  }

  it("stores a settlement whose market figures match the ledger", async () => {
    const st = await closed();
    const s = await L.recordSettlement(as(st, OP), "S", "B1", JSON.stringify(good));
    expect(s).toMatchObject({ participantId: "B1", boughtWh: 600, paid: 72, premium: 50 });
    const seller = await L.recordSettlement(as(st, OP), "S", "S1", JSON.stringify({ boughtWh: 0, soldWh: 600, paid: 0, received: 72, costA: 0, costB: 10, costC: 20 }));
    expect(seller.premium).toBe(-10);
  });

  it("rejects figures that disagree with the ledger", async () => {
    const st = await closed();
    for (const bad of [{ ...good, paid: 71 }, { ...good, boughtWh: 601 }, { ...good, soldWh: 5 }, { ...good, received: 1 }]) {
      await expect(L.recordSettlement(as(st, OP), "S", "B1", JSON.stringify(bad))).rejects.toThrow(/ledger has/);
    }
  });

  it("allows one settlement per participant, only by the operator, only after the session is closed", async () => {
    const st = await closed();
    await expect(L.recordSettlement(as(st, ALICE), "S", "B1", JSON.stringify(good))).rejects.toThrow(/only the session operator/);
    await expect(L.recordSettlement(as(st, OP), "S", "NOBODY", JSON.stringify(good))).rejects.toThrow(/not registered/);
    await L.recordSettlement(as(st, OP), "S", "B1", JSON.stringify(good));
    await expect(L.recordSettlement(as(st, OP), "S", "B1", JSON.stringify(good))).rejects.toThrow(/already recorded/);
    await expect(L.recordSettlement(as(st, OP), "S", "B2", JSON.stringify({ ...good, boughtWh: 0, paid: 0, costA: 1.5 }))).rejects.toThrow(/integer/);
    await expect(L.recordSettlement(as(st, OP), "S", "B2", JSON.stringify({ ...good, boughtWh: -1 }))).rejects.toThrow(/non-negative/);

    const open = await withHour();
    await expect(L.recordSettlement(as(open, OP), "S", "B1", JSON.stringify(good))).rejects.toThrow(/close the session/);
  });

  it("only counts the trades of its own session", async () => {
    const st = await closed();
    await L.openSession(as(st, OP), "S2", RULES_VERSION, SCENARIO_HASH, participants);
    await L.openHour(as(st, OP), "S2", 12, caps);
    await L.submitOrders(as(st, ALICE), "S2", 12, JSON.stringify([sell("a1", "S1", 120, 1000)]));
    await L.submitOrders(as(st, BOB), "S2", 12, JSON.stringify([buy("b1", "B1", 150, 1000)]));
    await L.closeHour(as(st, OP), "S2", 12);
    await L.closeSession(as(st, OP), "S2");
    await L.recordSettlement(as(st, OP), "S", "B1", JSON.stringify(good)); // still 600 Wh, not 1600
  });

  it("a session id that is a prefix of another does not see its trades", async () => {
    const st = await closed(); // session "S", 1 trade
    await L.openSession(as(st, OP), "SS", RULES_VERSION, SCENARIO_HASH, participants);
    await L.openHour(as(st, OP), "SS", 12, caps);
    await L.submitOrders(as(st, ALICE), "SS", 12, JSON.stringify([sell("a1", "S1", 120, 1000)]));
    await L.submitOrders(as(st, BOB), "SS", 12, JSON.stringify([buy("b1", "B1", 150, 1000)]));
    expect(await L.getTradesForHour(as(st, OP), "S", 12)).toHaveLength(1);
    expect(await L.getTradesForHour(as(st, OP), "SS", 12)).toHaveLength(1);
    await L.recordSettlement(as(st, OP), "S", "B1", JSON.stringify(good));
  });
});
P2P_EOF

cat > "$CC/test/equivalence.test.ts" <<'P2P_EOF'
/**
 * Replays a whole simulated day, recorded by the simulation runner, through the chaincode logic and
 * checks that the ledger ends up with exactly the trades the simulator produced.
 * Skipped automatically when the sim/ and engine/ folders are not next to blockchain/.
 */
import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { describe, expect, it } from "vitest";
import * as L from "../src/logic";
import { RULES_VERSION } from "../src/engine";
import { FakeStore, SCENARIO_HASH, as } from "./fakeStore";

const repo = resolve(__dirname, "../../../..");
const simDir = resolve(repo, "sim/src");
const engineFile = resolve(repo, "engine/src/engine.ts");
const have = existsSync(resolve(simDir, "market.ts")) && existsSync(engineFile);

async function load(file: string): Promise<any> {
  return import(/* @vite-ignore */ pathToFileURL(resolve(simDir, file)).href);
}

describe.skipIf(!have)("chaincode logic gives the same market as the simulation runner", () => {
  it("engine.ts in the chaincode is byte-identical to engine/src/engine.ts", () => {
    const a = readFileSync(resolve(__dirname, "../src/engine.ts"), "utf8");
    const b = readFileSync(engineFile, "utf8");
    expect(a === b, "chaincode engine.ts is out of date: copy engine/src/engine.ts over it").toBe(true);
  });

  it("replays every trading hour of a day and ends with identical trades", async () => {
    const { simulateDay, DEFAULT_MARKET } = await load("market.ts");
    const { makePopulation, DEFAULT_POPULATION } = await load("agents.ts");
    const { syntheticDay } = await load("synthetic.ts");
    const { mulberry32 } = await load("rng.ts");

    const agents = makePopulation({ n: 40, prosumerShare: 0.4, seed: 5, ...DEFAULT_POPULATION });
    const day = syntheticDay(30.04, 31.24, 7);
    const result = simulateDay(agents, day, { ...DEFAULT_MARKET, collectTrades: true, recordEvents: true }, mulberry32(1005));

    const st = new FakeStore();
    const OP = "operator";
    await L.openSession(as(st, OP), "DAY", RULES_VERSION, SCENARIO_HASH, JSON.stringify(agents.map((a: { id: string }) => ({ participantId: a.id }))));

    let hoursChecked = 0;
    let totalTrades = 0;
    let prevHash = SCENARIO_HASH;
    for (const log of result.hours) {
      if (log.events === undefined) continue; // not a trading hour
      await L.openHour(as(st, OP), "DAY", log.hour, JSON.stringify(log.engineConfig));
      const events = log.events.filter((e: { type: string }) => e.type !== "close");
      expect(log.events[log.events.length - 1].type).toBe("close");
      for (let i = 0; i < events.length; i += L.MAX_EVENTS_PER_BATCH) {
        const r = await L.submitOrders(as(st, OP), "DAY", log.hour, JSON.stringify(events.slice(i, i + L.MAX_EVENTS_PER_BATCH)));
        for (const x of r.results) expect(x.ok).toBe(true); // the simulator never produces rejected events
      }
      const summary = await L.closeHour(as(st, OP), "DAY", log.hour);

      const onChain = (await L.getTradesForHour(as(st, OP), "DAY", log.hour)).map(({ sessionId: _s, hour: _h, ...t }) => t);
      expect(onChain).toEqual(log.trades ?? []);
      expect(summary.tradeCount).toBe(log.tradeCount);
      expect(summary.volumeWh).toBe(log.tradedWh);
      expect(summary.amount).toBe(log.amount);
      expect(summary.prevHash).toBe(prevHash);
      prevHash = summary.summaryHash;
      expect((await L.verifyHour(as(st, OP), "DAY", log.hour)).ok).toBe(true);
      hoursChecked++;
      totalTrades += summary.tradeCount;
    }
    expect(hoursChecked).toBe(DEFAULT_MARKET.tradingHours.length);
    expect(totalTrades).toBe(result.metrics.tradeCount);
    expect(totalTrades).toBeGreaterThan(20); // a real market happened, not an empty comparison

    // settlements for every household match what the simulator computed
    await L.closeSession(as(st, OP), "DAY");
    for (const a of result.agents) {
      const s = await L.recordSettlement(
        as(st, OP),
        "DAY",
        a.id,
        JSON.stringify({ boughtWh: a.boughtWh, soldWh: a.soldWh, paid: a.paid, received: a.received, costA: a.costA, costB: a.costB, costC: a.costC }),
      );
      expect(s.premium).toBe(a.premium);
    }
  });
});
P2P_EOF

cat > "$CC/test/shell.test.ts" <<'P2P_EOF'
/**
 * Tests the compiled contract (dist/) through fabric-shim's own dispatcher (ChaincodeFromContract.Invoke),
 * with a fake stub standing in for the peer. This is the closest check possible without a running network:
 * it exercises the decorators, the function-name routing, argument handling, the client identity and the
 * mapping from Fabric state calls to the market logic.
 *
 * Needs `npm run build` first (npm test does that).
 */
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { beforeAll, describe, expect, it } from "vitest";
import { RULES_VERSION } from "../src/engine";
import { SCENARIO_HASH } from "./fakeStore";

const root = resolve(__dirname, "..");
const dist = join(root, "dist/index.js");
const SEP = "\u0000";

interface Response {
  status: number;
  message?: string;
  payload?: Buffer;
}

function makeCert(dir: string, cn: string): Buffer {
  const key = join(dir, `${cn}.key`);
  const crt = join(dir, `${cn}.crt`);
  execFileSync("openssl", ["req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes", "-keyout", key, "-out", crt, "-days", "2", "-subj", `/O=Org1/CN=${cn}`], {
    stdio: "ignore",
  });
  return readFileSync(crt);
}

class FakeLedger {
  readonly data = new Map<string, Buffer>();
}

function fakeStub(ledger: FakeLedger, cert: Buffer, fn: string, args: string[], txId: string) {
  return {
    getBufferArgs: () => [fn, ...args].map((a) => Buffer.from(a)),
    getTxID: () => txId,
    getChannelID: () => "mychannel",
    getCreator: () => ({ mspid: "Org1MSP", idBytes: cert }),
    getTxTimestamp: () => ({ seconds: { toString: () => "1790000000" }, nanos: 0 }),
    createCompositeKey: (type: string, attrs: string[]) => SEP + type + SEP + attrs.join(SEP) + SEP,
    getState: async (key: string) => ledger.data.get(key) ?? Buffer.alloc(0),
    putState: async (key: string, value: Buffer) => {
      ledger.data.set(key, Buffer.from(value));
    },
    getStateByPartialCompositeKey: async (type: string, attrs: string[]) => {
      const prefix = SEP + type + SEP + attrs.map((a) => a + SEP).join("");
      const entries = [...ledger.data.entries()].filter(([k]) => k.startsWith(prefix)).sort(([a], [b]) => (a < b ? -1 : 1));
      let i = 0;
      return {
        next: async () => (i < entries.length ? { value: { key: entries[i]![0], value: entries[i++]![1] }, done: false } : { value: undefined, done: true }),
        close: async () => undefined,
      };
    },
  };
}

describe("compiled contract through fabric-shim", () => {
  let cc: { Invoke(stub: unknown): Promise<Response>; metadata: any };
  let operator: Buffer;
  let alice: Buffer;
  const ledger = new FakeLedger();
  let n = 0;

  const call = async (cert: Buffer, fn: string, ...args: Array<string | number | object>): Promise<Response> =>
    cc.Invoke(fakeStub(ledger, cert, `EnergyMarket:${fn}`, args.map((a) => (typeof a === "object" ? JSON.stringify(a) : String(a))), `tx${++n}`));
  const ok = (r: Response): any => {
    expect(r.status, r.message).toBe(200);
    return JSON.parse(r.payload!.toString());
  };

  beforeAll(() => {
    expect(existsSync(dist), "dist/ is missing: run `npm run build` (or `npm test`, which builds first)").toBe(true);
    const dir = mkdtempSync(join(tmpdir(), "em-certs-"));
    operator = makeCert(dir, "operator");
    alice = makeCert(dir, "alice");
    const { JSONSerializer } = require("fabric-contract-api");
    const ChaincodeFromContract = require("fabric-shim/lib/contract-spi/chaincodefromcontract");
    const mod = require(dist);
    cc = new ChaincodeFromContract(mod.contracts, { transaction: "jsonSerializer", serializers: { jsonSerializer: JSONSerializer } }, {}, "energy-market", "0.1.0");
  });

  it("registers exactly the intended transactions, with queries marked as evaluate-only", () => {
    const tx = cc.metadata.contracts.EnergyMarket.transactions as Array<{ name: string; tag: string[] }>;
    const submits = tx.filter((t) => t.tag.includes("SUBMIT")).map((t) => t.name).sort();
    const evals = tx.filter((t) => t.tag.includes("EVALUATE")).map((t) => t.name).sort();
    expect(submits).toEqual(["CloseHour", "CloseSession", "OpenHour", "OpenSession", "RecordSettlement", "SubmitOrders"]);
    expect(evals).toEqual(["GetEventLog", "GetHourSummary", "GetOrderBook", "GetSession", "GetTrades", "VerifyHour"]);
  });

  it("plays a full session: open, trade, close, verify, settle", async () => {
    // the operator of a session is whoever opened it, identified by the certificate Fabric reports
    const opened = ok(await call(operator, "OpenSession", "SH", RULES_VERSION, SCENARIO_HASH, [{ participantId: "S1" }, { participantId: "B1" }]));
    expect(opened.operatorId).toMatch(/^x509::/);

    // Alice owns S1 in a second session; her identity string is what Fabric reports for her certificate
    const { ClientIdentity } = require("fabric-shim");
    const aliceFullId: string = new ClientIdentity(fakeStub(ledger, alice, "x", [], "t")).getID();
    expect(aliceFullId).not.toBe(opened.operatorId);
    ok(await call(operator, "OpenSession", "SH2", RULES_VERSION, SCENARIO_HASH, [{ participantId: "S1", ownerId: aliceFullId }, { participantId: "B1" }]));

    ok(await call(operator, "OpenHour", "SH2", 12, { sellCapsWh: { S1: 1000 }, buyCapsWh: { B1: 1000 } }));
    const sellEv = [{ type: "submit", order: { orderId: "a1", participantId: "S1", side: "sell", price: 120, qtyWh: 1000 } }];
    const buyEv = [{ type: "submit", order: { orderId: "b1", participantId: "B1", side: "buy", price: 150, qtyWh: 600 } }];

    // Alice may sell for S1 but not buy for B1; the operator may do both
    ok(await call(alice, "SubmitOrders", "SH2", 12, sellEv));
    const denied = await call(alice, "SubmitOrders", "SH2", 12, buyEv);
    expect(denied.status).toBe(500);
    expect(denied.message).toMatch(/may not act/);
    const placed = ok(await call(operator, "SubmitOrders", "SH2", 12, buyEv));
    expect(placed.trades).toHaveLength(1);
    expect(placed.trades[0]).toMatchObject({ price: 120, qtyWh: 600, amount: 72 });

    expect(ok(await call(alice, "GetOrderBook", "SH2", 12)).asks[0].remainingWh).toBe(400);
    expect(ok(await call(alice, "GetTrades", "SH2", 12))).toHaveLength(1);

    const closed = ok(await call(operator, "CloseHour", "SH2", 12));
    expect(closed).toMatchObject({ tradeCount: 1, volumeWh: 600, amount: 72, prevHash: SCENARIO_HASH });
    expect(ok(await call(alice, "VerifyHour", "SH2", 12))).toEqual({ ok: true, problems: [] });
    expect(ok(await call(alice, "GetHourSummary", "SH2", 12)).summaryHash).toBe(closed.summaryHash);

    ok(await call(operator, "CloseSession", "SH2"));
    ok(await call(operator, "RecordSettlement", "SH2", "B1", { boughtWh: 600, soldWh: 0, paid: 72, received: 0, costA: 100, costB: 90, costC: 80 }));
    const bad = await call(operator, "RecordSettlement", "SH2", "S1", { boughtWh: 0, soldWh: 600, paid: 0, received: 73, costA: 0, costB: 0, costC: 0 });
    expect(bad.status).toBe(500);
    expect(bad.message).toMatch(/ledger has/);
  });

  it("reports failures as error responses, not crashes", async () => {
    const r = await call(operator, "GetSession", "NOPE");
    expect(r.status).toBe(500);
    expect(r.message).toMatch(/does not exist/);
    const unknown = await call(operator, "NoSuchFunction");
    expect(unknown.status).toBe(500);
  });

  it("an unauthorized call is refused before anything is written", async () => {
    const before = [...ledger.data.keys()].sort().join("|");
    const r = await call(alice, "OpenHour", "SH", 13, { sellCapsWh: {}, buyCapsWh: {} }); // SH is open, Alice is not its operator
    expect(r.status).toBe(500);
    expect(r.message).toMatch(/only the session operator/);
    expect([...ledger.data.keys()].sort().join("|")).toBe(before);
  });
});
P2P_EOF

cat > "$CC/.gitignore" <<'P2P_EOF'
node_modules/
dist/
P2P_EOF

cd "$CC"
echo "Installing packages (takes about a minute)..."
npm install --no-audit --no-fund
echo "Type check..."
npm run typecheck
echo "Building and running the tests..."
npm test
echo
echo "Done. The chaincode is in $CC"
echo "Next: deploy it to the test network (we do this once the smoke test has passed)."
