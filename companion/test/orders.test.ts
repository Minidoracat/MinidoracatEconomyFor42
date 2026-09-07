import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { EventStore, type Logger } from "../src/events.ts";
import { Orders } from "../src/orders.ts";
import { createServer, sign, type AccountSource, type WatermarkState } from "../src/server.ts";
import type { AccountRecord } from "../src/accounts.ts";

const silent: Logger = { info() {}, warn() {}, error() {} };
const noWatermark = (): WatermarkState => ({ durable: null, mtime: null, parsedAt: null, error: null, sizeBytes: null });

function tmpdir(): string {
  return fs.mkdtempSync(path.join(os.tmpdir(), "eco-orders-"));
}

function writeLines(dir: string, name: string, lines: string[]): void {
  fs.appendFileSync(path.join(dir, name), lines.join("\r\n") + "\r\n");
}

const E1 = "1000";
const catConfig = (rateVersion: number, pointsPerCoin: number, enabled = true) => ({
  type: "exchange.config", epoch: E1, seq: 0, ts: 1,
  currencies: [
    { id: "survivor", enabled: true, marketUnit: true, balanceMax: 10000000, exchange: null },
    { id: "cat", enabled, marketUnit: false, balanceMax: 10000000, exchange: { pointsPerCoin, perOrderMin: 10, perOrderMax: 5000, perAccountDaily: 5000, serverDaily: 50000, rateVersion } },
  ],
});

const alice: AccountRecord = { username: "alice", steamid: "76561198000000001", lastConnection: null, characters: [] };
const accounts: AccountSource = {
  refreshedAt: 0,
  stats: () => ({}),
  forSteam: (id) => (id === alice.steamid ? [alice] : []),
  forUsername: () => null,
};

function setup(): { dir: string; store: EventStore; orders: Orders; inbox: string } {
  const dir = tmpdir();
  const store = new EventStore({ economyDir: dir, stateDir: path.join(dir, "state"), log: silent });
  const inbox = path.join(dir, "inbox");
  const orders = new Orders({ inboxDir: inbox, stateDir: path.join(dir, "state"), store, accounts, log: silent });
  return { dir, store, orders, inbox };
}

const good = { orderId: "ord-1", steamId64: alice.steamid, username: "alice", currency: "cat", points: 200, amount: 100, rateSnapshot: 2, rateVersion: 1 };

test("orders: projection, validation, inbox write, idempotency", () => {
  const { dir, store, orders, inbox } = setup();
  assert.equal(orders.currencies(), null, "no config yet");
  assert.equal(orders.create(good).status, 503, "no config -> unavailable");

  writeLines(dir, "events-20260908.json", [
    JSON.stringify({ type: "file.header", epoch: E1, realmId: "r", startedSeq: 0 }),
    JSON.stringify({ type: "server.started", epoch: E1, seq: 0, loadedSeq: 0, realmId: "r", ts: 1 }),
    JSON.stringify(catConfig(1, 2)),
  ]);
  store.poll();
  const cur = orders.currencies();
  assert.ok(cur !== null);
  assert.equal(cur.length, 2);
  assert.equal(cur[0]?.exchange, null, "survivor is not exchangeable");
  assert.deepEqual(cur[1]?.exchange, { pointsPerCoin: 2, perOrderMin: 10, perOrderMax: 5000, perAccountDaily: 5000, serverDaily: 50000, rateVersion: 1 });

  // refusals, each without touching the inbox
  assert.equal(orders.create("nope").status, 400);
  assert.equal(orders.create({ ...good, orderId: "bad id!" }).body.error, "invalid_orderId");
  assert.equal(orders.create({ ...good, steamId64: "x" }).body.error, "invalid_steamId64");
  assert.equal(orders.create({ ...good, username: "bob" }).status, 403, "username not bound to the steam id");
  assert.equal(orders.create({ ...good, currency: "gold" }).body.error, "unknown_currency");
  assert.equal(orders.create({ ...good, currency: "survivor" }).body.error, "unknown_currency", "not exchangeable counts as unknown");
  const stale = orders.create({ ...good, rateVersion: 7 });
  assert.equal(stale.status, 409);
  assert.equal(stale.body.error, "rate_changed");
  assert.ok(Array.isArray(stale.body.currencies), "the current projection travels with rate_changed");
  assert.equal(orders.create({ ...good, rateSnapshot: 3 }).body.error, "rate_changed");
  assert.equal(orders.create({ ...good, amount: 99 }).body.error, "amount_mismatch");
  assert.equal(orders.create({ ...good, points: 10, amount: 5 }).body.error, "order_range");
  assert.equal(orders.create({ ...good, points: 1.5, amount: 0 }).body.error, "invalid_amount");
  assert.equal(fs.existsSync(inbox), false, "nothing was written");

  // the good one
  const ok = orders.create(good);
  assert.equal(ok.status, 202);
  assert.equal(ok.body.status, "pending");
  const file = path.join(inbox, "ord-1.json");
  assert.ok(fs.existsSync(file));
  assert.equal(fs.readdirSync(inbox).filter((n) => n.endsWith(".tmp")).length, 0, "no tmp left behind");
  const written: unknown = JSON.parse(fs.readFileSync(file, "utf8"));
  assert.ok(typeof written === "object" && written !== null);
  const rec = written as Record<string, unknown>;
  assert.equal(rec.orderId, "ord-1");
  assert.equal(rec.username, "alice");
  assert.equal(rec.amount, 100);
  assert.equal(rec.rateSnapshot, 2);
  assert.equal(typeof rec.payloadHash, "string");
  assert.equal(orders.status("ord-1").status, "pending");

  // resend: same payload -> same answer, another payload -> conflict
  const again = orders.create(good);
  assert.equal(again.status, 202);
  assert.equal(again.body.duplicate, true);
  assert.equal(orders.create({ ...good, amount: 50, points: 100 }).body.error, "order_conflict");
  assert.equal(fs.readdirSync(inbox).length, 1);

  // the index survives a restart of the companion
  const orders2 = new Orders({ inboxDir: inbox, stateDir: path.join(dir, "state"), store, accounts, log: silent });
  orders2.loadIndex();
  assert.equal(orders2.create({ ...good, amount: 50, points: 100 }).body.error, "order_conflict", "the persisted index still knows the order");
});

test("orders: outcome events, durable sweep, rollback keeps the file", () => {
  const { dir, store, orders, inbox } = setup();
  writeLines(dir, "events-20260908.json", [
    JSON.stringify({ type: "file.header", epoch: E1, realmId: "r", startedSeq: 0 }),
    JSON.stringify({ type: "server.started", epoch: E1, seq: 0, loadedSeq: 0, realmId: "r", ts: 1 }),
    JSON.stringify(catConfig(1, 2)),
  ]);
  store.poll();
  assert.equal(orders.create(good).status, 202);
  assert.equal(orders.create({ ...good, orderId: "ord-2" }).status, 202);
  const f1 = path.join(inbox, "ord-1.json");
  const f2 = path.join(inbox, "ord-2.json");

  // Lua answers: ord-1 deposited at seq 5, ord-2 failed at seq 6
  writeLines(dir, "events-20260908.json", [
    JSON.stringify({ type: "exchange.deposited", epoch: E1, seq: 5, ts: 2, orderId: "ord-1", username: "alice", currency: "cat", amount: 100, points: 200, txId: `${E1}:5` }),
    JSON.stringify({ type: "exchange.failed", epoch: E1, seq: 6, ts: 3, orderId: "ord-2", reason: "daily_cap" }),
  ]);
  store.poll();
  let v = orders.status("ord-1");
  assert.equal(v.status, "deposited");
  assert.equal(v.durable, false);
  assert.equal(v.inbox, true);
  assert.equal(orders.status("ord-2").status, "failed");
  assert.equal(orders.sweep(), 0, "not durable yet: files stay");
  assert.ok(fs.existsSync(f1) && fs.existsSync(f2));

  // the save reaches seq 5: ord-1 durable, ord-2 not
  store.setDurable({ epoch: E1, seq: 5, realmId: "r" });
  assert.equal(orders.sweep(), 1);
  assert.equal(fs.existsSync(f1), false, "durable outcome: file removed");
  assert.ok(fs.existsSync(f2), "failed at seq 6 is not durable yet");
  v = orders.status("ord-1");
  assert.equal(v.status, "deposited");
  assert.equal(v.durable, true);
  assert.equal(v.inbox, false);
  const resend = orders.create(good);
  assert.equal(resend.status, 200, "a resend after settlement answers with the outcome, never a new file");
  assert.equal(resend.body.status, "deposited");
  assert.equal(fs.existsSync(f1), false);

  // a crash before the save rolled ord-2's failure back: the outcome is void, the file stays
  const E2 = "2000";
  writeLines(dir, "events-20260908.json", [
    JSON.stringify({ type: "server.started", epoch: E2, seq: 5, loadedSeq: 5, realmId: "r", ts: 4 }),
    JSON.stringify(catConfig(1, 2)),
  ]);
  store.poll();
  v = orders.status("ord-2");
  assert.equal(v.status, "pending", "the rolled-back failure no longer counts");
  assert.equal(v.inbox, true);
  assert.equal(orders.sweep(), 0);
  assert.ok(fs.existsSync(f2), "Lua will replay the file after the restart");

  // the outcome left memory (index remembers it) -> still answered from the index
  const orders2 = new Orders({ inboxDir: inbox, stateDir: path.join(dir, "state"), store: { events: [], isDurable: () => false }, accounts, log: silent });
  orders2.loadIndex();
  const late = orders2.status("ord-1");
  assert.equal(late.status, "deposited");
  assert.equal(late.durable, true);
  assert.equal(orders2.status("nobody").status, "unknown");
});

test("http: /currencies, POST /orders, GET /orders/{id} with HMAC", async () => {
  const { dir, store, orders } = setup();
  writeLines(dir, "events-20260908.json", [
    JSON.stringify({ type: "file.header", epoch: E1, realmId: "r", startedSeq: 0 }),
    JSON.stringify({ type: "server.started", epoch: E1, seq: 0, loadedSeq: 0, realmId: "r", ts: 1 }),
    JSON.stringify(catConfig(1, 2)),
  ]);
  store.poll();
  const secret = "s3cret";
  const server = createServer({ config: { hmacSecret: secret, bind: "127.0.0.1" }, store, accounts, watermark: noWatermark, orders, log: silent });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const address = server.address();
  assert.ok(address !== null && typeof address === "object");
  const port = address.port;
  const call = async (method: string, pathWithQuery: string, body = ""): Promise<{ status: number; body: Record<string, unknown> }> => {
    const ts = Math.floor(Date.now() / 1000);
    const headers: Record<string, string> = { "x-timestamp": String(ts), "x-signature": sign(secret, ts, method, pathWithQuery, body) };
    if (body !== "") headers["content-type"] = "application/json";
    const res = await fetch(`http://127.0.0.1:${port}${pathWithQuery}`, { method, headers, body: body === "" ? undefined : body });
    const parsed: unknown = await res.json();
    assert.ok(typeof parsed === "object" && parsed !== null);
    return { status: res.status, body: parsed as Record<string, unknown> };
  };
  try {
    const c = await call("GET", "/currencies");
    assert.equal(c.status, 200);
    assert.ok(Array.isArray(c.body.currencies) && c.body.currencies.length === 2);
    const bad = await call("POST", "/orders", "{not json");
    assert.equal(bad.status, 400);
    const created = await call("POST", "/orders", JSON.stringify(good));
    assert.equal(created.status, 202);
    assert.equal(created.body.orderId, "ord-1");
    const st = await call("GET", "/orders/ord-1");
    assert.equal(st.status, 200);
    assert.equal(st.body.status, "pending");
    assert.equal((await call("GET", "/orders/nope")).status, 404);
    assert.equal((await call("GET", "/orders/bad%20id")).status, 400);
    const h = await call("GET", "/health");
    assert.deepEqual(h.body.orders, { inboxFiles: 1, indexed: 1 });
  } finally {
    server.close();
  }
});
