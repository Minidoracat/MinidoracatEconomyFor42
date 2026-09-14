import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import { Accounts } from "../src/accounts.ts";

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
    const accounts = new Accounts({ whitelistDb, playersDb, stateDir: path.join(dir, "state"), log: { info() {}, warn() {}, error() {} } });
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
