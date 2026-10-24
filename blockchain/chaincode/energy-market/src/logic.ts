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
