// Steam <-> username <-> character mapping.
//
// Sources: db/<server>.db `whitelist` (username unique, steamid TEXT; ServerWorldDatabase.java)
// and Saves/Multiplayer/<server>/players.db `networkPlayers` (ServerPlayerDB.java:304). Both are
// written by the game server, and the player save has NO retry on SQLITE_BUSY
// (ServerPlayerDB.java:187-190; stage A10): an external lock silently loses a player save.
// Therefore this module never opens the live files: it copies them to the companion state dir
// (only when no hot journal is present) and opens the copy read-only.
//
// The same whitelist copy also feeds the identity export {economyDir}/identity/whitelist.json, which
// Economy's Lua side imports on its own (NDJSON: header, one {id,u,s} row per whitelist id, end line).
// `copyIfQuiet` only looks at the rollback journal and cannot rule out a page torn mid-copy, so a copy
// is exported only after it passes `PRAGMA quick_check` AND two consecutive reads returned the same
// rows, and only when those rows differ from the last export. `ownerid` is never read: it holds the
// Steam Family Sharing owner, while logins are authorised by the account's own SteamID
// (LoginPacket.java:66-73; ServerWorldDatabase.java:1191 writes ownerid keyed by steamid).
import fs from "node:fs";
import path from "node:path";
import { DatabaseSync, type SQLOutputValue } from "node:sqlite";
import { errorCode, errorMessage, type Logger } from "./events.ts";

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
  /** {economyDir}/identity/whitelist.json */
  identityFile: string;
  /** SERVER_NAME, copied into the export header. */
  serverName: string;
  log?: Logger;
}

/**
 * ok: the file matches the last stable read; waiting_stable: rows changed (or the db was mid-transaction)
 * and need a second identical read; quick_check_failed: the copy was corrupt or unreadable;
 * write_failed: the previous file is kept and the write is retried next refresh; no_source: no whitelist db.
 */
export type IdentityExportStatus = "ok" | "waiting_stable" | "quick_check_failed" | "write_failed" | "no_source";

export interface IdentityExportState {
  status: IdentityExportStatus;
  /** Header of the file this process last wrote; null until the first write. */
  generatedAt: number | null;
  count: number | null;
  invalidSteamIds: number | null;
  /** Most recent failure; cleared once the export is up to date. */
  lastError: string | null;
  /** Unix ms of the last successful write. */
  writtenAt: number | null;
}

interface IdentityRows {
  /** NDJSON row lines joined by "\n": the compared "row set". */
  lines: string;
  count: number;
  invalidSteamIds: number;
}

const STEAM_ID64 = /^7656119\d{10}$/;

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

/** Export rows of a whitelist copy; throws when the copy fails quick_check or cannot be read. */
function readIdentityRows(file: string): IdentityRows {
  const db = new DatabaseSync(file, { readOnly: true });
  try {
    const check = db.prepare("PRAGMA quick_check").all();
    if (check.length !== 1 || check[0]?.quick_check !== "ok") {
      throw new Error(`quick_check: ${check.map((r) => text(r.quick_check ?? null)).join("; ")}`);
    }
    const lines: string[] = [];
    let invalidSteamIds = 0;
    for (const row of db.prepare("SELECT id, username, CAST(steamid AS TEXT) AS steamid FROM whitelist ORDER BY id").all()) {
      const id = num(row.id ?? null);
      const u = text(row.username ?? null);
      if (id === null || !Number.isSafeInteger(id) || u === null) continue;   // not representable in the contract
      let s = text(row.steamid ?? null) ?? "";
      if (s !== "" && !STEAM_ID64.test(s)) {
        s = "";
        invalidSteamIds++;
      }
      lines.push(JSON.stringify({ id, u, s }));
    }
    return { lines: lines.join("\n"), count: lines.length, invalidSteamIds };
  } finally {
    db.close();
  }
}

function writeAtomic(file: string, content: string): void {
  const tmp = `${file}.tmp`;
  fs.writeFileSync(tmp, content);
  fs.renameSync(tmp, file);
}

export class Accounts {
  readonly whitelistDb: string;
  readonly playersDb: string;
  readonly stateDir: string;
  readonly identityFile: string;
  readonly serverName: string;
  readonly log: Logger;
  /** steamid -> usernames */
  private bySteam = new Map<string, string[]>();
  private byUsername = new Map<string, AccountRecord>();
  refreshedAt = 0;
  sources: { whitelist: number | null; players: number | null } = { whitelist: null, players: null };
  lastError: string | null = null;
  identity: IdentityExportState = { status: "waiting_stable", generatedAt: null, count: null, invalidSteamIds: null, lastError: null, writtenAt: null };
  /** Rows of the previous successful read; a write needs the next read to match. */
  private exportPrev: string | null = null;
  /** Rows this process last wrote. */
  private exportWritten: string | null = null;

  constructor({ whitelistDb, playersDb, stateDir, identityFile, serverName, log = console }: AccountsOptions) {
    this.whitelistDb = whitelistDb;
    this.playersDb = playersDb;
    this.stateDir = stateDir;
    this.identityFile = identityFile;
    this.serverName = serverName;
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
      if (!fs.existsSync(this.whitelistDb)) {
        this.exportPrev = null;
        this.holdExport("no_source", null);
      } else if (!copyIfQuiet(this.whitelistDb, wl)) {
        this.holdExport("waiting_stable", null);
      } else {
        this.exportIdentity(wl);
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

  /** Exports the copy when it is intact, read the same twice in a row, and differs from the last export. */
  private exportIdentity(copy: string): void {
    let rows: IdentityRows;
    try {
      rows = readIdentityRows(copy);
    } catch (err) {
      this.exportPrev = null;   // a bad read breaks the run of identical reads
      this.holdExport("quick_check_failed", errorMessage(err));
      return;
    }
    if (rows.lines !== this.exportPrev) {
      this.exportPrev = rows.lines;
      this.holdExport("waiting_stable", null);
      return;
    }
    if (rows.lines === this.exportWritten) {
      this.identity.status = "ok";
      this.identity.lastError = null;
      return;
    }
    let generatedAt: number;
    try {
      generatedAt = this.nextGeneratedAt();
      const header = { type: "whitelist", v: 1, serverName: this.serverName, generatedAt, count: rows.count, invalidSteamIds: rows.invalidSteamIds };
      const body = rows.count === 0 ? "" : `${rows.lines}\n`;
      fs.mkdirSync(path.dirname(this.identityFile), { recursive: true });
      writeAtomic(this.identityFile, `${JSON.stringify(header)}\n${body}${JSON.stringify({ type: "end", count: rows.count })}\n`);
    } catch (err) {
      this.holdExport("write_failed", `${errorMessage(err)} (previous file kept, retrying every refresh)`);
      return;
    }
    this.exportWritten = rows.lines;
    this.identity = { status: "ok", generatedAt, count: rows.count, invalidSteamIds: rows.invalidSteamIds, lastError: null, writtenAt: Date.now() };
    this.log.info(`identity export written: ${rows.count} rows, ${rows.invalidSteamIds} invalid SteamIDs, generatedAt=${generatedAt}`);
  }

  /**
   * max(now, last + 1), persisted before the export is renamed into place so a restart never reuses or
   * lowers it (Lua treats a lower generatedAt as stale). An unreadable state file fails the write
   * instead of silently restarting from zero.
   */
  private nextGeneratedAt(): number {
    const stateFile = path.join(this.stateDir, "identity-export.json");
    let last = this.identity.generatedAt ?? 0;
    try {
      const saved: unknown = JSON.parse(fs.readFileSync(stateFile, "utf8"));
      if (typeof saved !== "object" || saved === null || !("generatedAt" in saved) || typeof saved.generatedAt !== "number" || !Number.isSafeInteger(saved.generatedAt)) {
        throw new Error(`${stateFile}: generatedAt missing`);
      }
      last = Math.max(last, saved.generatedAt);
    } catch (err) {
      if (errorCode(err) !== "ENOENT") throw err;
    }
    const next = Math.max(Date.now(), last + 1);
    writeAtomic(stateFile, `${JSON.stringify({ generatedAt: next })}\n`);
    return next;
  }

  private holdExport(status: IdentityExportStatus, failure: string | null): void {
    if (failure !== null && failure !== this.identity.lastError) this.log.warn(`identity export ${status}: ${failure}`);
    this.identity.status = status;
    if (failure !== null) this.identity.lastError = failure;
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
    return {
      usernames: this.byUsername.size, steamIds: this.bySteam.size, refreshedAt: this.refreshedAt, sources: this.sources, lastError: this.lastError,
      identityExport: { ...this.identity },
    };
  }
}
