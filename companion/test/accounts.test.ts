import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import { Accounts } from "../src/accounts.ts";
import type { Logger } from "../src/events.ts";

const silent: Logger = { info() {}, warn() {}, error() {} };

test("accounts preserve INTEGER and TEXT SteamIDs across both SQLite sources", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "economy-steamid-"));
  const whitelistDb = path.join(dir, "whitelist.db"), playersDb = path.join(dir, "players.db");
  const first = "76561198097932712", second = "76561198097932713";
  try {
    const wl = new DatabaseSync(whitelistDb);
    wl.exec("CREATE TABLE whitelist (username TEXT, steamid, lastConnection TEXT)");
    wl.prepare("INSERT INTO whitelist VALUES (?, ?, ?)").run("alice", BigInt(first), "2026-09-14");
    wl.prepare("INSERT INTO whitelist VALUES (?, ?, ?)").run("text-account", second, null);
    wl.close();
    const pl = new DatabaseSync(playersDb);
    pl.exec("CREATE TABLE networkPlayers (username TEXT, steamid, playerIndex INTEGER, name TEXT, isDead INTEGER, worldversion INTEGER)");
    const insert = pl.prepare("INSERT INTO networkPlayers VALUES (?, ?, ?, ?, ?, ?)");
    insert.run("alice", BigInt(first), 0, "Alice", 0, 249);
    insert.run("player-only", BigInt(second), 0, "Bob", 1, 249);
    insert.run("unlinked", null, 0, "Unlinked", 0, 249);
    pl.close();
    const before = [fs.readFileSync(whitelistDb), fs.readFileSync(playersDb)];
    const accounts = new Accounts({ whitelistDb, playersDb, stateDir: path.join(dir, "state"), identityFile: path.join(dir, "identity", "whitelist.json"), serverName: "pzserver", log: silent });
    accounts.refresh();
    assert.equal(accounts.lastError, null);
    assert.deepEqual(accounts.forSteam(first).map((a) => a.username), ["alice"]);
    assert.deepEqual(accounts.forSteam(second).map((a) => a.username).sort(), ["player-only", "text-account"]);
    assert.equal(accounts.forUsername("player-only")?.steamid, second);
    assert.deepEqual(accounts.forUsername("player-only")?.characters, [{ playerIndex: 0, name: "Bob", isDead: true, worldVersion: 249 }]);
    assert.equal(accounts.forUsername("unlinked")?.steamid, null);
    assert.equal(JSON.parse(JSON.stringify(accounts.forSteam(first)))[0].steamid, first);
    assert.deepEqual([fs.readFileSync(whitelistDb), fs.readFileSync(playersDb)], before);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

type WhitelistRow = [id: number, username: string, steamid: string | bigint | null, ownerid: string | null];

/** Recreates the whitelist db with the engine's schema (ServerWorldDatabase.java:453). */
function writeWhitelist(file: string, rows: WhitelistRow[]): void {
  fs.rmSync(file, { force: true });
  const db = new DatabaseSync(file);
  db.exec("CREATE TABLE [whitelist] ([id] INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,[world] TEXT DEFAULT '' NULL,[username] TEXT  NULL, [password] TEXT  NULL, [lastConnection] TEXT NULL, [role] INTEGER NOT NULL, [authType] INTEGER NULL DEFAULT 1, [googleKey] TEXT NULL, [steamid] TEXT NULL, [ownerid] TEXT NULL, [displayName] TEXT NULL)");
  const insert = db.prepare("INSERT INTO whitelist (id, username, role, steamid, ownerid) VALUES (?, ?, 2, ?, ?)");
  for (const [id, username, steamid, ownerid] of rows) insert.run(id, username, steamid, ownerid);
  db.close();
}

function exportFixture(log: Logger = silent) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "economy-identity-"));
  const whitelistDb = path.join(dir, "pzserver.db");
  const stateDir = path.join(dir, "state");
  const identityFile = path.join(dir, "economy", "identity", "whitelist.json");
  const open = (): Accounts => new Accounts({ whitelistDb, playersDb: path.join(dir, "players.db"), stateDir, identityFile, serverName: "pzserver", log });
  const lines = (): Array<Record<string, unknown>> => fs.readFileSync(identityFile, "utf8").trimEnd().split("\n").map((l) => JSON.parse(l));
  return { dir, whitelistDb, identityFile, open, lines };
}

const ALICE = "76561198000000001", BOB = "76561198000000002", OWNER = "76561198999999999";

test("identity export: written only on the second identical read, ordered by id, ownerid ignored, no .tmp left", () => {
  const f = exportFixture();
  try {
    writeWhitelist(f.whitelistDb, [[5, "bob", BOB, OWNER], [2, "alice", BigInt(ALICE), OWNER], [9, "nosteam", null, null]]);
    const accounts = f.open();
    accounts.refresh();
    assert.equal(fs.existsSync(f.identityFile), false, "a single read is never exported");
    assert.equal(accounts.identity.status, "waiting_stable");
    accounts.refresh();
    const [header, ...rest] = f.lines();
    assert.deepEqual(Object.keys(header ?? {}), ["type", "v", "serverName", "generatedAt", "count", "invalidSteamIds"]);
    assert.equal(header?.type, "whitelist");
    assert.equal(header?.serverName, "pzserver");
    assert.equal(header?.count, 3);
    assert.equal(header?.invalidSteamIds, 0, "a missing steamid is not an invalid one");
    assert.deepEqual(rest, [
      { id: 2, u: "alice", s: ALICE },
      { id: 5, u: "bob", s: BOB },
      { id: 9, u: "nosteam", s: "" },
      { type: "end", count: 3 },
    ]);
    assert.deepEqual(fs.readdirSync(path.dirname(f.identityFile)), ["whitelist.json"]);
    const stats = accounts.stats().identityExport;
    assert.deepEqual({ ...(stats as object), writtenAt: null }, { status: "ok", generatedAt: header?.generatedAt, count: 3, invalidSteamIds: 0, lastError: null, writtenAt: null });
    const written = fs.readFileSync(f.identityFile, "utf8");
    accounts.refresh();
    assert.equal(fs.readFileSync(f.identityFile, "utf8"), written, "unchanged rows are not rewritten");
    assert.equal(accounts.identity.status, "ok");
  } finally { fs.rmSync(f.dir, { recursive: true, force: true }); }
});

test("identity export: changed rows wait for two identical reads again", () => {
  const f = exportFixture();
  try {
    writeWhitelist(f.whitelistDb, [[1, "alice", ALICE, null]]);
    const accounts = f.open();
    accounts.refresh();
    accounts.refresh();
    const first = f.lines();
    writeWhitelist(f.whitelistDb, [[1, "alice", ALICE, null], [2, "bob", BOB, null]]);
    accounts.refresh();
    assert.deepEqual(f.lines(), first, "the first read of new rows is not exported");
    assert.equal(accounts.identity.status, "waiting_stable");
    accounts.refresh();
    const second = f.lines();
    assert.equal(second[0]?.count, 2);
    assert.ok(Number(second[0]?.generatedAt) > Number(first[0]?.generatedAt));
  } finally { fs.rmSync(f.dir, { recursive: true, force: true }); }
});

test("identity export: malformed SteamIDs are written as empty and counted", () => {
  const f = exportFixture();
  try {
    writeWhitelist(f.whitelistDb, [[1, "alice", ALICE, null], [2, "short", "7656119800000000", null], [3, "other", "12345678901234567", null], [4, "blank", "", null]]);
    const accounts = f.open();
    accounts.refresh();
    accounts.refresh();
    const [header, ...rest] = f.lines();
    assert.equal(header?.invalidSteamIds, 2);
    assert.deepEqual(rest.map((r) => r.s), [ALICE, "", "", "", undefined]);
    assert.equal(accounts.identity.invalidSteamIds, 2);
  } finally { fs.rmSync(f.dir, { recursive: true, force: true }); }
});

test("identity export: a copy failing quick_check or unreadable is never exported", () => {
  const warns: string[] = [];
  const f = exportFixture({ info() {}, warn: (m) => warns.push(m), error() {} });
  try {
    writeWhitelist(f.whitelistDb, [[1, "alice", ALICE, null]]);
    const bytes = fs.readFileSync(f.whitelistDb);
    bytes.writeUInt32BE(5, 36);   // header freelist count with no freelist: rows still readable, quick_check fails
    fs.writeFileSync(f.whitelistDb, bytes);
    const accounts = f.open();
    accounts.refresh();
    accounts.refresh();
    assert.equal(fs.existsSync(f.identityFile), false);
    assert.equal(accounts.identity.status, "quick_check_failed");
    assert.match(accounts.identity.lastError ?? "", /quick_check: .*Freelist/s);
    assert.equal(warns.filter((m) => m.startsWith("identity export")).length, 1, "the same failure is logged once");
    fs.writeFileSync(f.whitelistDb, "not a database, not even close");
    accounts.refresh();
    accounts.refresh();
    assert.equal(fs.existsSync(f.identityFile), false);
    assert.equal(accounts.identity.status, "quick_check_failed");
    writeWhitelist(f.whitelistDb, [[1, "alice", ALICE, null]]);
    accounts.refresh();
    assert.equal(fs.existsSync(f.identityFile), false, "a bad read breaks the run of identical reads");
    accounts.refresh();
    assert.equal(accounts.identity.status, "ok");
    assert.equal(accounts.identity.lastError, null);
  } finally { fs.rmSync(f.dir, { recursive: true, force: true }); }
});

test("identity export: generatedAt stays strictly increasing across a restart", (t) => {
  const f = exportFixture();
  try {
    let now = 1_790_000_000_000;
    t.mock.method(Date, "now", () => now);
    writeWhitelist(f.whitelistDb, [[1, "alice", ALICE, null]]);
    const before = f.open();
    before.refresh();
    before.refresh();
    assert.equal(f.lines()[0]?.generatedAt, now);
    now -= 60_000;   // host clock stepped back while the companion was down
    const after = f.open();
    after.refresh();
    after.refresh();
    assert.equal(f.lines()[0]?.generatedAt, 1_790_000_000_001);
  } finally { fs.rmSync(f.dir, { recursive: true, force: true }); }
});

test("identity export: a failed write keeps the previous file and is retried next refresh", () => {
  const warns: string[] = [];
  const f = exportFixture({ info() {}, warn: (m) => warns.push(m), error() {} });
  try {
    writeWhitelist(f.whitelistDb, [[1, "alice", ALICE, null]]);
    const accounts = f.open();
    accounts.refresh();
    accounts.refresh();
    const previous = fs.readFileSync(f.identityFile, "utf8");
    fs.mkdirSync(`${f.identityFile}.tmp`);   // the tmp path is taken: writeFileSync fails
    writeWhitelist(f.whitelistDb, [[1, "alice", ALICE, null], [2, "bob", BOB, null]]);
    accounts.refresh();
    accounts.refresh();
    accounts.refresh();
    assert.equal(accounts.identity.status, "write_failed");
    assert.equal(fs.readFileSync(f.identityFile, "utf8"), previous);
    assert.equal(warns.filter((m) => m.startsWith("identity export write_failed")).length, 1);
    fs.rmdirSync(`${f.identityFile}.tmp`);
    accounts.refresh();
    assert.equal(accounts.identity.status, "ok");
    assert.equal(f.lines()[0]?.count, 2);
  } finally { fs.rmSync(f.dir, { recursive: true, force: true }); }
});
