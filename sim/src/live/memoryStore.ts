import type { Store } from "../../../blockchain/chaincode/energy-market/src/logic";

const SEP = "\u0000";

/** In-memory ledger state with the key shape and ordering of Fabric composite keys. */
export class MemoryStore implements Store {
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
}
