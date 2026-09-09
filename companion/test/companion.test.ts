import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { parseGlobalModData, economyWatermark, encodeGlobalModData, type LuaTable } from "../src/bin.ts";
import { EventStore, type Logger } from "../src/events.ts";
import { createServer, sign, type AccountSource, type WatermarkState } from "../src/server.ts";
import type { AccountRecord } from "../src/accounts.ts";

const silent: Logger = { info() {}, warn() {}, error() {} };
const noWatermark = (): WatermarkState => ({ durable: null, mtime: null, parsedAt: null, error: null, sizeBytes: null });

function tmpdir(): string {
  return fs.mkdtempSync(path.join(os.tmpdir(), "eco-companion-"));
}

test("bin: round-trips the engine layout and yields the economy watermark", () => {
  const tables = new Map<string, LuaTable>([
    ["OtherMod", { a: 1, list: { 1: "x", 2: "y" }, flag: true }],
    ["MinidoracatEconomy", { schemaVersion: 1, meta: { epoch: "1788700279858", seq: 42, loadedSeq: 40, realmId: "realm-1" }, wallets: { alice: { survivor: { available: 30, reserved: 0, rev: 1 } } } }],
  ]);
  const buf = encodeGlobalModData(226, tables);
  const parsed = parseGlobalModData(buf);
  assert.equal(parsed.worldVersion, 226);
  assert.equal(JSON.stringify(parsed.tables.get("OtherMod")), JSON.stringify(tables.get("OtherMod")));
  assert.deepEqual(economyWatermark(parsed, "MinidoracatEconomy"), { epoch: "1788700279858", seq: 42, realmId: "realm-1" });
  assert.equal(economyWatermark(parsed, "Missing"), null);
  assert.throws(() => parseGlobalModData(buf.subarray(0, buf.length - 5)), RangeError);
  assert.throws(() => parseGlobalModData(Buffer.from([0, 0, 0, 10, 0, 0, 0, 0])), RangeError);
});

test("bin: prototype-shaped keys remain data and cannot forge a savepoint", () => {
  const data: LuaTable = Object.create(null);
  data["__proto__"] = { meta: { epoch: "forged", seq: 1 } };
  data["constructor"] = "preserved";
  const parsed = parseGlobalModData(encodeGlobalModData(226, new Map([["MinidoracatEconomy", data]])));
  assert.equal(economyWatermark(parsed, "MinidoracatEconomy"), null);
  assert.equal(JSON.stringify(parsed.tables.get("MinidoracatEconomy")), JSON.stringify(data));
});

function writeLines(dir: string, name: string, lines: string[], eol = "\r\n"): void {
  fs.appendFileSync(path.join(dir, name), lines.join(eol) + eol);
}

test("events: tail with CRLF, checkpoint, day rotation, rolled_back and durable flags, cursors", () => {
  const dir = tmpdir();
  const stateDir = path.join(dir, "state");
  const e1 = "1000";
  writeLines(dir, "events-20260906.json", [
    JSON.stringify({ type: "file.header", epoch: e1, realmId: "r", startedSeq: 0 }),
    JSON.stringify({ type: "server.started", epoch: e1, seq: 0, loadedSeq: 0, realmId: "r", ts: 1 }),
    JSON.stringify({ type: "tx.committed", epoch: e1, seq: 1, txId: `${e1}:1`, ts: 2 }),
    JSON.stringify({ type: "tx.committed", epoch: e1, seq: 2, txId: `${e1}:2`, ts: 3 }),
    JSON.stringify({ type: "tx.committed", epoch: e1, seq: 3, txId: `${e1}:3`, ts: 4 }),
  ]);
  let store = new EventStore({ economyDir: dir, stateDir, log: silent });
  store.loadCheckpoint();
  assert.equal(store.poll(), 5);
  assert.equal(store.events.length, 4, "file.header is not exposed");
  assert.equal(store.currentEpoch, e1);

  // Nothing durable yet: no watermark.
  let page = store.ledger("", 10);
  assert.ok(page);
  assert.equal(page.events.length, 4);
  assert.ok(page.events.every((ev) => ev.durable === false));
  assert.equal(page.next, "idx:3");

  // Watermark from the .bin: seq 2 saved -> seq 1,2 durable, seq 3 live.
  store.setDurable({ epoch: e1, seq: 2, realmId: "r" });
  page = store.ledger("", 10);
  assert.ok(page);
  assert.deepEqual(page.events.map((ev) => ev.durable), [true, true, true, false]);

  // Crash before the next save; restart loads seq 2 -> seq 3 rolled back; new epoch continues at 3.
  const e2 = "2000";
  writeLines(dir, "events-20260907.json", [
    JSON.stringify({ type: "file.header", epoch: e2, realmId: "r", startedSeq: 2 }),
    JSON.stringify({ type: "server.started", epoch: e2, seq: 2, loadedSeq: 2, realmId: "r", ts: 5 }),
    JSON.stringify({ type: "tx.committed", epoch: e2, seq: 3, txId: `${e2}:3`, ts: 6 }),
  ], "\n");
  assert.equal(store.poll(), 3);
  page = store.ledger("", 10);
  assert.ok(page);
  const seq3old = page.events.find((ev) => ev.txId === `${e1}:3`);
  assert.ok(seq3old);
  assert.equal(seq3old.rolledBack, true);
  assert.equal(seq3old.durable, false);
  assert.equal(page.events.find((ev) => ev.txId === `${e1}:2`)?.durable, true, "superseded epoch, not rolled back -> durable");
  const seq3new = page.events.find((ev) => ev.txId === `${e2}:3`);
  assert.ok(seq3new);
  assert.equal(seq3new.rolledBack, false);
  assert.equal(seq3new.durable, false, "new epoch: not durable until the next .bin watermark");
  store.setDurable({ epoch: e2, seq: 3, realmId: "r" });
  assert.equal(store.ledger("", 10)?.events.find((ev) => ev.txId === `${e2}:3`)?.durable, true);

  // Cursor paging by arrival index and by (epoch, seq) of an event.
  const p1 = store.ledger("", 2);
  assert.ok(p1 && p1.next !== null);
  const p2 = store.ledger(p1.next, 2);
  assert.ok(p2);
  assert.equal(p1.events.length, 2);
  assert.equal(p2.events[0]?.cursor, "idx:2");
  assert.equal(store.ledger(`${e1}:3`, 10)?.events[0]?.type, "server.started");
  assert.equal(store.ledger("idx:999", 10)?.events.length, 0);
  assert.equal(store.ledger("bogus:1", 10), null);

  // Checkpoint survives a companion restart: no re-ingest, indices continue.
  store = new EventStore({ economyDir: dir, stateDir, log: silent });
  store.loadCheckpoint();
  assert.equal(store.poll(), 0);
  assert.equal(store.nextIndex, 6);
  writeLines(dir, "events-20260907.json", [JSON.stringify({ type: "tx.committed", epoch: e2, seq: 4, txId: `${e2}:4`, ts: 7 })], "\n");
  assert.equal(store.poll(), 1);
  assert.equal(store.events[0]?._idx, 6, "after restart only new events are in memory, indices continue");

  // A partial trailing line is held back until its newline arrives.
  fs.appendFileSync(path.join(dir, "events-20260907.json"), '{"type":"tx.committed","epoch":"2000","seq":5');
  assert.equal(store.poll(), 0);
  fs.appendFileSync(path.join(dir, "events-20260907.json"), ',"txId":"2000:5","ts":8}\r\n');
  assert.equal(store.poll(), 1);
  assert.equal(store.events.at(-1)?.txId, "2000:5");
});

test("http: health/ledger/accounts with HMAC", async () => {
  const dir = tmpdir();
  const store = new EventStore({ economyDir: dir, stateDir: path.join(dir, "state"), log: silent });
  const alice: AccountRecord = { username: "alice", steamid: "76561198000000001", lastConnection: null, characters: [] };
  const accounts: AccountSource = {
    refreshedAt: 0,
    stats: () => ({}),
    forSteam: (id) => (id === alice.steamid ? [alice] : []),
    forUsername: () => null,
  };
  const secret = "s3cret";
  const server = createServer({ config: { hmacSecret: secret, bind: "127.0.0.1" }, store, accounts, watermark: noWatermark, log: silent });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const address = server.address();
  assert.ok(address !== null && typeof address === "object");
  const port = address.port;
  const get = async (pathWithQuery: string, signed = true, skew = 0): Promise<{ status: number; body: Record<string, unknown> }> => {
    const ts = Math.floor(Date.now() / 1000) + skew;
    const headers = signed ? { "x-timestamp": String(ts), "x-signature": sign(secret, ts, "GET", pathWithQuery) } : {};
    const res = await fetch(`http://127.0.0.1:${port}${pathWithQuery}`, { headers });
    const body: unknown = await res.json();
    assert.ok(typeof body === "object" && body !== null);
    return { status: res.status, body: body as Record<string, unknown> };
  };
  try {
    assert.equal((await get("/health", false)).status, 401);
    assert.equal((await get("/health", true, 1000)).status, 401, "stale timestamp rejected");
    const h = await get("/health");
    assert.equal(h.status, 200);
    assert.equal(h.body.ok, true);
    const l = await get("/ledger?after=&limit=10");
    assert.equal(l.status, 200);
    assert.deepEqual(l.body.events, []);
    const a = await get("/accounts?steamId64=76561198000000001");
    assert.deepEqual(a.body.accounts, [alice]);
    assert.equal((await get("/accounts")).status, 400);
    assert.equal((await get("/nope")).status, 404);
  } finally {
    server.close();
  }
});

test("http: empty secret is refused off-loopback and tolerated on loopback", () => {
  const dir = tmpdir();
  const store = new EventStore({ economyDir: dir, stateDir: path.join(dir, "state"), log: silent });
  const accounts: AccountSource = { refreshedAt: 0, stats: () => ({}), forSteam: () => [], forUsername: () => null };
  assert.throws(() => createServer({ config: { hmacSecret: "", bind: "0.0.0.0" }, store, accounts, watermark: noWatermark, log: silent }));
  const s = createServer({ config: { hmacSecret: "", bind: "127.0.0.1" }, store, accounts, watermark: noWatermark, log: silent });
  assert.ok(s);
});
