// Runtime configuration from environment variables (PM2 env block on the production host).
import path from "node:path";
import os from "node:os";

function env(name, fallback) {
  const v = process.env[name];
  return v === undefined || v === "" ? fallback : v;
}

const zomboidDir = env("ZOMBOID_DIR", path.join(os.homedir(), "Zomboid"));
const serverName = env("SERVER_NAME", "servertest");

export const config = {
  zomboidDir,
  serverName,
  // Written by the mod (getFileWriter is rooted at {cachedir}/Lua)
  economyDir: path.join(zomboidDir, "Lua", "MinidoracatEconomy"),
  // Global ModData snapshot: durable watermark source (GlobalModData.java:290-299)
  modDataBin: path.join(zomboidDir, "Saves", "Multiplayer", serverName, "global_mod_data.bin"),
  // Player <-> Steam mapping (read with zero locks: copy-then-open)
  playersDb: path.join(zomboidDir, "Saves", "Multiplayer", serverName, "players.db"),
  whitelistDb: path.join(zomboidDir, "db", `${serverName}.db`),
  // Companion state (checkpoint, temp copies)
  stateDir: env("COMPANION_STATE_DIR", path.join(zomboidDir, "Lua", "MinidoracatEconomy", "companion-state")),
  bind: env("BIND", "127.0.0.1"),
  port: Number(env("PORT", "8477")),
  // HMAC-SHA256 shared with Watchcord. Empty secret is only tolerated on loopback (local dev).
  hmacSecret: env("HMAC_SECRET", ""),
  pollMs: Number(env("POLL_MS", "2000")),
  accountsRefreshMs: Number(env("ACCOUNTS_REFRESH_MS", "60000")),
  modDataTag: "MinidoracatEconomy",
  maxEventsInMemory: Number(env("MAX_EVENTS_IN_MEMORY", "200000")),
};
