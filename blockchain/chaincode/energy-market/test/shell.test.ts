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
