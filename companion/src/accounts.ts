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
import { DatabaseSync, type SQLOutputValue } from "node:sqlite";
import { errorMessage, type Logger } from "./events.ts";

export interface Character {
  playerIndex: number | null;
  name: string | null;
  isDead: boolean;
  worldVersion: number | null;
}

export interface AccountRecord {
  username: string;
  steamid: string | null;
  lastConnection: string | number | null;
  characters: Character[];
}

export interface AccountsOptions {
  whitelistDb: string;
  playersDb: string;
  stateDir: string;
  log?: Logger;
}

type Row = Record<string, SQLOutputValue>;

function copyIfQuiet(src: string, dst: string): boolean {
  // A `-journal` next to the db means a rollback-journal transaction is in flight.
  if (fs.existsSync(src + "-journal") && fs.statSync(src + "-journal").size > 0) return false;
  fs.copyFileSync(src, dst);
  return true;
}

function readRows(file: string, sql: string): Row[] {
  const db = new DatabaseSync(file, { readOnly: true });
  try {
    return db.prepare(sql).all();
  } finally {
    db.close();
  }
}

// SQLite cells are null | number | bigint | string | Uint8Array; the API returns JSON, so
// anything that JSON.stringify cannot carry is normalised here.
function text(v: SQLOutputValue): string | null {
  return v === null || v instanceof Uint8Array ? null : String(v);
}

function num(v: SQLOutputValue): number | null {
  if (typeof v === "number") return v;
  if (typeof v === "bigint") return Number(v);
  return null;
}

export class Accounts {
  readonly whitelistDb: string;
  readonly playersDb: string;
  readonly stateDir: string;
  readonly log: Logger;
  /** steamid -> usernames */
  private bySteam = new Map<string, string[]>();
  private byUsername = new Map<string, AccountRecord>();
  refreshedAt = 0;
  sources: { whitelist: number | null; players: number | null } = { whitelist: null, players: null };
  lastError: string | null = null;

  constructor({ whitelistDb, playersDb, stateDir, log = console }: AccountsOptions) {
    this.whitelistDb = whitelistDb;
    this.playersDb = playersDb;
    this.stateDir = stateDir;
    this.log = log;
  }

  refresh(): void {
    fs.mkdirSync(this.stateDir, { recursive: true });
    const byUsername = new Map<string, AccountRecord>();
    const bySteam = new Map<string, string[]>();
    const link = (rec: AccountRecord): void => {
      byUsername.set(rec.username, rec);
      if (rec.steamid === null) return;
      const names = bySteam.get(rec.steamid);
      if (names === undefined) bySteam.set(rec.steamid, [rec.username]);
      else names.push(rec.username);
    };
    try {
      const wl = path.join(this.stateDir, "whitelist.copy.db");
      if (fs.existsSync(this.whitelistDb) && copyIfQuiet(this.whitelistDb, wl)) {
        for (const row of readRows(wl, "SELECT username, CAST(steamid AS TEXT) AS steamid, lastConnection FROM whitelist")) {
          const username = text(row.username ?? null);
          if (username === null) continue;
          const lastConnection = row.lastConnection ?? null;
          link({
            username,
            steamid: text(row.steamid ?? null),
            lastConnection: typeof lastConnection === "number" ? lastConnection : text(lastConnection),
            characters: [],
          });
        }
        this.sources.whitelist = fs.statSync(this.whitelistDb).mtimeMs;
      }
      const pl = path.join(this.stateDir, "players.copy.db");
      if (fs.existsSync(this.playersDb) && copyIfQuiet(this.playersDb, pl)) {
        // Never select the `data` blob (the whole character save).
        for (const row of readRows(pl, "SELECT username, CAST(steamid AS TEXT) AS steamid, playerIndex, name, isDead, worldversion FROM networkPlayers")) {
          const username = text(row.username ?? null);
          if (username === null) continue;
          let rec = byUsername.get(username);
          if (rec === undefined) {
            rec = { username, steamid: text(row.steamid ?? null), lastConnection: null, characters: [] };
            link(rec);
          }
          rec.characters.push({
            playerIndex: num(row.playerIndex ?? null),
            name: text(row.name ?? null),
            isDead: (num(row.isDead ?? null) ?? 0) !== 0,
            worldVersion: num(row.worldversion ?? null),
          });
        }
        this.sources.players = fs.statSync(this.playersDb).mtimeMs;
      }
      this.byUsername = byUsername;
      this.bySteam = bySteam;
      this.refreshedAt = Date.now();
      this.lastError = null;
    } catch (err) {
      // Keep the previous snapshot; a torn copy or a busy journal is retried next cycle.
      this.lastError = errorMessage(err);
      this.log.warn(`accounts refresh failed: ${this.lastError}`);
    }
  }

  forSteam(steamId64: string): AccountRecord[] {
    const names = this.bySteam.get(steamId64) ?? [];
    const out: AccountRecord[] = [];
    for (const name of names) {
      const rec = this.byUsername.get(name);
      if (rec !== undefined) out.push(rec);
    }
    return out;
  }

  forUsername(username: string): AccountRecord | null {
    return this.byUsername.get(username) ?? null;
  }

  stats(): Record<string, unknown> {
    return { usernames: this.byUsername.size, steamIds: this.bySteam.size, refreshedAt: this.refreshedAt, sources: this.sources, lastError: this.lastError };
  }
}
