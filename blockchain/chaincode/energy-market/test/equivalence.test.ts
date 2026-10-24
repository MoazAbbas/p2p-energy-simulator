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
