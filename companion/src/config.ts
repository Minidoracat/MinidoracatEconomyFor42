// Runtime configuration from environment variables (PM2 env block on the production host).
import path from "node:path";
import os from "node:os";

export interface CompanionConfig {
  zomboidDir: string;
  serverName: string;
  /** Written by the mod (getFileWriter is rooted at {cachedir}/Lua) */
  economyDir: string;
  /** Global ModData snapshot: durable watermark source (GlobalModData.java:290-299) */
  modDataBin: string;
  /** Player <-> Steam mapping (read with zero locks: copy-then-open) */
  playersDb: string;
  whitelistDb: string;
  /** Companion state (checkpoint, temp copies) */
  stateDir: string;
  bind: string;
  port: number;
  /** HMAC-SHA256 shared with Watchcord. Empty secret is only tolerated on loopback (local dev). */
  hmacSecret: string;
  pollMs: number;
  accountsRefreshMs: number;
  modDataTag: string;
  maxEventsInMemory: number;
}

function env(name: string, fallback: string): string {
  const v = process.env[name];
  return v === undefined || v === "" ? fallback : v;
}

function envNumber(name: string, fallback: number): number {
  const n = Number(env(name, String(fallback)));
  if (!Number.isFinite(n)) throw new Error(`${name} must be a number`);
  return n;
}

const zomboidDir = env("ZOMBOID_DIR", path.join(os.homedir(), "Zomboid"));
const serverName = env("SERVER_NAME", "servertest");

export const config: CompanionConfig = {
  zomboidDir,
  serverName,
  economyDir: path.join(zomboidDir, "Lua", "MinidoracatEconomy"),
  modDataBin: path.join(zomboidDir, "Saves", "Multiplayer", serverName, "global_mod_data.bin"),
  playersDb: path.join(zomboidDir, "Saves", "Multiplayer", serverName, "players.db"),
  whitelistDb: path.join(zomboidDir, "db", `${serverName}.db`),
  stateDir: env("COMPANION_STATE_DIR", path.join(zomboidDir, "Lua", "MinidoracatEconomy", "companion-state")),
  bind: env("BIND", "127.0.0.1"),
  port: envNumber("PORT", 8477),
  hmacSecret: env("HMAC_SECRET", ""),
  pollMs: envNumber("POLL_MS", 2000),
  accountsRefreshMs: envNumber("ACCOUNTS_REFRESH_MS", 60000),
  modDataTag: "MinidoracatEconomy",
  maxEventsInMemory: envNumber("MAX_EVENTS_IN_MEMORY", 200000),
};
