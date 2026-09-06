// Steam <-> username <-> character mapping.
//
// Sources: db/<server>.db `whitelist` (username unique, steamid TEXT; ServerWorldDatabase.java)
// and Saves/Multiplayer/<server>/players.db `networkPlayers` (ServerPlayerDB.java:304). Both are
// written by the game server, and the player save has NO retry on SQLITE_BUSY
// (ServerPlayerDB.java:187-190; stage A10): an external lock silently loses a player save.
// Therefore this module never opens the live files: it copies them to the companion state dir
// (only when no hot journal is present) and opens the copy read-only.
import fs from "node:fs";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";

function copyIfQuiet(src, dst) {
  // A `-journal` next to the db means a rollback-journal transaction is in flight.
  if (fs.existsSync(src + "-journal") && fs.statSync(src + "-journal").size > 0) return false;
  fs.copyFileSync(src, dst);
  return true;
}

function readRows(file, sql) {
  const db = new DatabaseSync(file, { readOnly: true });
  try {
    return db.prepare(sql).all();
  } finally {
    db.close();
  }
}

export class Accounts {
  constructor({ whitelistDb, playersDb, stateDir, log = console }) {
    this.whitelistDb = whitelistDb;
    this.playersDb = playersDb;
    this.stateDir = stateDir;
    this.log = log;
    this.bySteam = new Map();      // steamid -> [username]
    this.byUsername = new Map();   // username -> { username, steamid, lastConnection, characters: [] }
    this.refreshedAt = 0;
    this.sources = { whitelist: null, players: null };
    this.lastError = null;
  }

  refresh() {
    fs.mkdirSync(this.stateDir, { recursive: true });
    const byUsername = new Map();
    const bySteam = new Map();
    try {
      const wl = path.join(this.stateDir, "whitelist.copy.db");
      if (fs.existsSync(this.whitelistDb) && copyIfQuiet(this.whitelistDb, wl)) {
        for (const row of readRows(wl, "SELECT username, steamid, lastConnection FROM whitelist")) {
          const rec = { username: row.username, steamid: row.steamid ? String(row.steamid) : null, lastConnection: row.lastConnection ?? null, characters: [] };
          byUsername.set(row.username, rec);
          if (rec.steamid) {
            if (!bySteam.has(rec.steamid)) bySteam.set(rec.steamid, []);
            bySteam.get(rec.steamid).push(row.username);
          }
        }
        this.sources.whitelist = fs.statSync(this.whitelistDb).mtimeMs;
      }
      const pl = path.join(this.stateDir, "players.copy.db");
      if (fs.existsSync(this.playersDb) && copyIfQuiet(this.playersDb, pl)) {
        // Never select the `data` blob (the whole character save).
        for (const row of readRows(pl, "SELECT username, steamid, playerIndex, name, isDead, worldversion FROM networkPlayers")) {
          let rec = byUsername.get(row.username);
          if (!rec) {
            rec = { username: row.username, steamid: row.steamid ? String(row.steamid) : null, lastConnection: null, characters: [] };
            byUsername.set(row.username, rec);
            if (rec.steamid) {
              if (!bySteam.has(rec.steamid)) bySteam.set(rec.steamid, []);
              bySteam.get(rec.steamid).push(row.username);
            }
          }
          rec.characters.push({ playerIndex: row.playerIndex, name: row.name, isDead: !!row.isDead, worldVersion: row.worldversion });
        }
        this.sources.players = fs.statSync(this.playersDb).mtimeMs;
      }
      this.byUsername = byUsername;
      this.bySteam = bySteam;
      this.refreshedAt = Date.now();
      this.lastError = null;
    } catch (err) {
      // Keep the previous snapshot; a torn copy or a busy journal is retried next cycle.
      this.lastError = err.message;
      this.log.warn(`accounts refresh failed: ${err.message}`);
    }
  }

  forSteam(steamId64) {
    const names = this.bySteam.get(String(steamId64)) ?? [];
    return names.map((n) => this.byUsername.get(n));
  }

  forUsername(username) {
    return this.byUsername.get(username) ?? null;
  }

  stats() {
    return { usernames: this.byUsername.size, steamIds: this.bySteam.size, refreshedAt: this.refreshedAt, sources: this.sources, lastError: this.lastError };
  }
}
