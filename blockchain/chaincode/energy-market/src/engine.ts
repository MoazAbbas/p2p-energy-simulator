/**
 * Continuous double auction (CDA) engine for ONE trading hour.
 * Rules version: cda-resting-price-v1 (see docs/DESIGN.md, section 5).
 *
 * Design constraints (so the same file can run in the backend, in experiments
 * and later inside Fabric chaincode):
 *   - pure and deterministic: no clock, no randomness, no I/O, no imports
 *   - integers only: energy in Wh, price in piastres per kWh, money in piastres
 *
 * Rules:
 *   - bids sorted by price descending, asks by price ascending, ties by sequence number
 *   - an incoming order matches while it crosses the best opposite order
 *   - TRADE PRICE = price of the RESTING order (the one already in the book)
 *   - trade quantity = min(remaining incoming, remaining resting); partial fills allowed
 *   - the unfilled remainder of an order rests in the book
 *   - a participant never trades with itself (its own resting orders are skipped)
 *   - a participant may not offer more than its sell cap (unsold surplus) or bid for
 *     more than its buy cap (deficit) for the hour; cancelling frees the cap again
 *   - closeHour() cancels everything still open; the hour is then finished
 */

export const RULES_VERSION = "cda-resting-price-v1";

/** Largest accepted quantity (1 GWh) and price (10,000 EGP/kWh). Keeps qty*price a safe integer. */
export const MAX_QTY_WH = 1_000_000_000;
export const MAX_PRICE = 1_000_000;

export type Side = "buy" | "sell";

export interface EngineConfig {
  /** Max Wh each participant may SELL this hour (its unsold surplus). Missing = 0. */
  sellCapsWh: Readonly<Record<string, number>>;
  /** Max Wh each participant may BUY this hour (its deficit). Missing = 0. */
  buyCapsWh: Readonly<Record<string, number>>;
}

export interface OrderInput {
  orderId: string;
  participantId: string;
  side: Side;
  /** piastres per kWh, positive integer */
  price: number;
  /** Wh, positive integer */
  qtyWh: number;
}

export interface BookOrder {
  seq: number;
  orderId: string;
  participantId: string;
  side: Side;
  price: number;
  qtyWh: number;
  remainingWh: number;
}

export interface Trade {
  /** 1-based position of the trade within the hour */
  seq: number;
  buyOrderId: string;
  sellOrderId: string;
  buyerId: string;
  sellerId: string;
  qtyWh: number;
  /** piastres per kWh: the price of the resting order */
  price: number;
  /** piastres: round-half-up(qtyWh * price / 1000). Buyer pays exactly this; seller receives exactly this. */
  amount: number;
  /** which side was already in the book */
  restingSide: Side;
}

export type RejectReason =
  | "HOUR_CLOSED"
  | "INVALID_ORDER"
  | "DUPLICATE_ORDER_ID"
  | "CAP_EXCEEDED"
  | "NOT_FOUND"
  | "NOT_OWNER"
  | "NOT_OPEN";

export interface Rejected {
  ok: false;
  reason: RejectReason;
  message: string;
}

export type SubmitResult =
  | { ok: true; seq: number; trades: Trade[]; restingWh: number }
  | Rejected;

export type CancelResult = { ok: true; cancelledWh: number } | Rejected;

export interface CancelledOrder {
  orderId: string;
  participantId: string;
  side: Side;
  remainingWh: number;
}

export interface CloseResult {
  ok: true;
  cancelled: CancelledOrder[];
}

export type EngineEvent =
  | { type: "submit"; order: OrderInput }
  | { type: "cancel"; orderId: string; participantId: string }
  | { type: "close" };

export interface ParticipantTotals {
  soldWh: number;
  boughtWh: number;
  /** piastres received as seller */
  received: number;
  /** piastres paid as buyer */
  paid: number;
}

export interface Summary {
  tradeCount: number;
  volumeWh: number;
  amount: number;
  perParticipant: Record<string, ParticipantTotals>;
}

export interface BookSnapshot {
  bids: BookOrder[];
  asks: BookOrder[];
}

/** round-half-up(qtyWh * price / 1000), integers only. */
export function tradeAmount(qtyWh: number, price: number): number {
  return Math.floor((qtyWh * price + 500) / 1000);
}

interface InternalOrder extends BookOrder {
  open: boolean;
}

function isPosInt(v: unknown, max: number): v is number {
  return typeof v === "number" && Number.isSafeInteger(v) && v > 0 && v <= max;
}

function validateOrder(order: unknown): string | null {
  if (typeof order !== "object" || order === null) return "order must be an object";
  const o = order as Record<string, unknown>;
  if (typeof o.orderId !== "string" || o.orderId.length === 0) return "orderId must be a non-empty string";
  if (typeof o.participantId !== "string" || o.participantId.length === 0)
    return "participantId must be a non-empty string";
  if (o.side !== "buy" && o.side !== "sell") return "side must be 'buy' or 'sell'";
  if (!isPosInt(o.price, MAX_PRICE)) return `price must be an integer in 1..${MAX_PRICE} (piastres per kWh)`;
  if (!isPosInt(o.qtyWh, MAX_QTY_WH)) return `qtyWh must be an integer in 1..${MAX_QTY_WH} (Wh)`;
  return null;
}

function reject(reason: RejectReason, message: string): Rejected {
  return { ok: false, reason, message };
}

function toCaps(caps: Readonly<Record<string, number>>, name: string): Map<string, number> {
  const m = new Map<string, number>();
  for (const [id, v] of Object.entries(caps)) {
    if (typeof v !== "number" || !Number.isSafeInteger(v) || v < 0) {
      throw new Error(`${name}[${id}] must be a non-negative integer (Wh)`);
    }
    m.set(id, v);
  }
  return m;
}

export class Engine {
  private readonly sellCaps: Map<string, number>;
  private readonly buyCaps: Map<string, number>;
  /** Best first. Bids: price desc, seq asc. */
  private bids: InternalOrder[] = [];
  /** Best first. Asks: price asc, seq asc. */
  private asks: InternalOrder[] = [];
  private readonly orders = new Map<string, InternalOrder>();
  /** Wh already committed per (side, participant): traded + still open. */
  private readonly used = new Map<string, number>();
  private readonly trades: Trade[] = [];
  private nextSeq = 1;
  private closed = false;

  constructor(config: EngineConfig) {
    this.sellCaps = toCaps(config.sellCapsWh, "sellCapsWh");
    this.buyCaps = toCaps(config.buyCapsWh, "buyCapsWh");
  }

  /** Wh the participant can still offer for sale this hour. */
  availableToSell(participantId: string): number {
    return Math.max(0, (this.sellCaps.get(participantId) ?? 0) - (this.used.get(`sell|${participantId}`) ?? 0));
  }

  /** Wh the participant can still bid for this hour. */
  availableToBuy(participantId: string): number {
    return Math.max(0, (this.buyCaps.get(participantId) ?? 0) - (this.used.get(`buy|${participantId}`) ?? 0));
  }

  submit(order: OrderInput): SubmitResult {
    if (this.closed) return reject("HOUR_CLOSED", "the hour is closed");
    const err = validateOrder(order);
    if (err !== null) return reject("INVALID_ORDER", err);
    if (this.orders.has(order.orderId)) return reject("DUPLICATE_ORDER_ID", `orderId ${order.orderId} already used`);

    const available =
      order.side === "sell" ? this.availableToSell(order.participantId) : this.availableToBuy(order.participantId);
    if (order.qtyWh > available) {
      return reject("CAP_EXCEEDED", `requested ${order.qtyWh} Wh but only ${available} Wh available to ${order.side}`);
    }

    const incoming: InternalOrder = {
      seq: this.nextSeq++,
      orderId: order.orderId,
      participantId: order.participantId,
      side: order.side,
      price: order.price,
      qtyWh: order.qtyWh,
      remainingWh: order.qtyWh,
      open: false,
    };
    this.orders.set(incoming.orderId, incoming);
    const usedKey = `${incoming.side}|${incoming.participantId}`;
    this.used.set(usedKey, (this.used.get(usedKey) ?? 0) + incoming.qtyWh);

    const newTrades = this.match(incoming);

    if (incoming.remainingWh > 0) {
      incoming.open = true;
      this.insert(incoming);
    }
    return { ok: true, seq: incoming.seq, trades: newTrades, restingWh: incoming.remainingWh };
  }

  cancel(orderId: string, participantId: string): CancelResult {
    if (this.closed) return reject("HOUR_CLOSED", "the hour is closed");
    const o = this.orders.get(orderId);
    if (o === undefined) return reject("NOT_FOUND", `unknown orderId ${orderId}`);
    if (o.participantId !== participantId) return reject("NOT_OWNER", "order belongs to another participant");
    if (!o.open) return reject("NOT_OPEN", "order is already filled or cancelled");
    const cancelledWh = o.remainingWh;
    this.removeFromBook(o);
    o.open = false;
    o.remainingWh = 0;
    const usedKey = `${o.side}|${o.participantId}`;
    this.used.set(usedKey, (this.used.get(usedKey) ?? 0) - cancelledWh);
    return { ok: true, cancelledWh };
  }

  /** Cancels all open orders and finishes the hour. Unsold surplus is the caller's to export. */
  closeHour(): CloseResult {
    const cancelled: CancelledOrder[] = [...this.bids, ...this.asks]
      .sort((a, b) => a.seq - b.seq)
      .map((o) => ({ orderId: o.orderId, participantId: o.participantId, side: o.side, remainingWh: o.remainingWh }));
    for (const o of [...this.bids, ...this.asks]) o.open = false;
    this.bids = [];
    this.asks = [];
    this.closed = true;
    return { ok: true, cancelled };
  }

  apply(event: EngineEvent): SubmitResult | CancelResult | CloseResult {
    switch (event.type) {
      case "submit":
        return this.submit(event.order);
      case "cancel":
        return this.cancel(event.orderId, event.participantId);
      case "close":
        return this.closeHour();
    }
  }

  getTrades(): Trade[] {
    return this.trades.map((t) => ({ ...t }));
  }

  getBook(): BookSnapshot {
    const strip = (o: InternalOrder): BookOrder => ({
      seq: o.seq,
      orderId: o.orderId,
      participantId: o.participantId,
      side: o.side,
      price: o.price,
      qtyWh: o.qtyWh,
      remainingWh: o.remainingWh,
    });
    return { bids: this.bids.map(strip), asks: this.asks.map(strip) };
  }

  summary(): Summary {
    const perParticipant: Record<string, ParticipantTotals> = {};
    const get = (id: string): ParticipantTotals => {
      let t = perParticipant[id];
      if (t === undefined) {
        t = { soldWh: 0, boughtWh: 0, received: 0, paid: 0 };
        perParticipant[id] = t;
      }
      return t;
    };
    let volumeWh = 0;
    let amount = 0;
    for (const tr of this.trades) {
      volumeWh += tr.qtyWh;
      amount += tr.amount;
      const s = get(tr.sellerId);
      s.soldWh += tr.qtyWh;
      s.received += tr.amount;
      const b = get(tr.buyerId);
      b.boughtWh += tr.qtyWh;
      b.paid += tr.amount;
    }
    return { tradeCount: this.trades.length, volumeWh, amount, perParticipant };
  }

  private match(incoming: InternalOrder): Trade[] {
    const out: Trade[] = [];
    const book = incoming.side === "buy" ? this.asks : this.bids;
    let i = 0;
    while (incoming.remainingWh > 0 && i < book.length) {
      const resting = book[i]!;
      const crosses = incoming.side === "buy" ? resting.price <= incoming.price : resting.price >= incoming.price;
      if (!crosses) break; // book is sorted best-first, so nothing further can cross either
      if (resting.participantId === incoming.participantId) {
        i++; // never trade with yourself; keep the order resting
        continue;
      }
      const qtyWh = Math.min(incoming.remainingWh, resting.remainingWh);
      const price = resting.price;
      const buy = incoming.side === "buy" ? incoming : resting;
      const sell = incoming.side === "buy" ? resting : incoming;
      const trade: Trade = {
        seq: this.trades.length + 1,
        buyOrderId: buy.orderId,
        sellOrderId: sell.orderId,
        buyerId: buy.participantId,
        sellerId: sell.participantId,
        qtyWh,
        price,
        amount: tradeAmount(qtyWh, price),
        restingSide: resting.side,
      };
      this.trades.push(trade);
      out.push({ ...trade });
      incoming.remainingWh -= qtyWh;
      resting.remainingWh -= qtyWh;
      if (resting.remainingWh === 0) {
        resting.open = false;
        book.splice(i, 1); // do not advance: the next order slid into position i
      }
    }
    return out;
  }

  private insert(o: InternalOrder): void {
    const book = o.side === "buy" ? this.bids : this.asks;
    // New order goes after every order that is better or equal in price (earlier seq wins ties).
    let idx = 0;
    while (idx < book.length && (o.side === "buy" ? book[idx]!.price >= o.price : book[idx]!.price <= o.price)) idx++;
    book.splice(idx, 0, o);
  }

  private removeFromBook(o: InternalOrder): void {
    const book = o.side === "buy" ? this.bids : this.asks;
    const idx = book.indexOf(o);
    if (idx >= 0) book.splice(idx, 1);
  }
}

/**
 * Replays an ordered event list on a fresh engine. Used for experiments and, later, to check
 * that the chaincode produces exactly the same trades as the backend for the same events.
 */
export function runEvents(
  config: EngineConfig,
  events: readonly EngineEvent[],
): { results: Array<SubmitResult | CancelResult | CloseResult>; trades: Trade[]; summary: Summary } {
  const engine = new Engine(config);
  const results = events.map((e) => engine.apply(e));
  return { results, trades: engine.getTrades(), summary: engine.summary() };
}
