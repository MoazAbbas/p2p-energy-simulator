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
