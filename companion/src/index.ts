// Entry point: node src/index.ts  (Node >= 24 strips the types itself; see config.ts for env vars)
import fs from "node:fs";
import { config } from "./config.ts";
import { EventStore, errorCode, errorMessage, type Logger } from "./events.ts";
import { Accounts } from "./accounts.ts";
import { parseGlobalModData, economyWatermark } from "./bin.ts";
import { createServer, type WatermarkState } from "./server.ts";
import { Orders } from "./orders.ts";
import path from "node:path";

const log: Logger = {
  info: (m) => console.log(`[companion] ${m}`),
  warn: (m) => console.warn(`[companion] WARN ${m}`),
  error: (m) => console.error(`[companion] ERROR ${m}`),
};

const store = new EventStore({ economyDir: config.economyDir, stateDir: config.stateDir, maxEvents: config.maxEventsInMemory, log });
const accounts = new Accounts({ whitelistDb: config.whitelistDb, playersDb: config.playersDb, stateDir: config.stateDir, log });
const orders = new Orders({ inboxDir: path.join(config.economyDir, "inbox"), stateDir: config.stateDir, store, accounts, log });

// ---- durable watermark from global_mod_data.bin ----
// The engine writes global_mod_data.tmp and then copies it over the .bin (GlobalModData.java:258-266):
// wait until the mtime has been stable for one poll before parsing, and never lower the watermark.
const wm: WatermarkState & { seenMtime: number | null } = { durable: null, mtime: null, seenMtime: null, parsedAt: null, error: null, sizeBytes: null };

function pollModData(force = false): void {
  let st: fs.Stats;
  try {
    st = fs.statSync(config.modDataBin);
  } catch (err) {
    if (errorCode(err) !== "ENOENT") wm.error = errorMessage(err);
    return;
  }
  if (st.mtimeMs === wm.mtime) return;                 // already parsed this version
  if (!force && st.mtimeMs !== wm.seenMtime) { wm.seenMtime = st.mtimeMs; return; }   // let the copy settle
  try {
    const parsed = parseGlobalModData(fs.readFileSync(config.modDataBin));
    const mark = economyWatermark(parsed, config.modDataTag);
    wm.mtime = st.mtimeMs;
    wm.parsedAt = Date.now();
    wm.sizeBytes = st.size;
    wm.error = null;
    if (mark === null) {
      log.warn(`table ${config.modDataTag} not present in global_mod_data.bin yet`);
      return;
    }
    if (wm.durable !== null && wm.durable.epoch === mark.epoch && mark.seq < wm.durable.seq) {
      log.warn(`watermark went backwards within epoch ${mark.epoch}: ${mark.seq} < ${wm.durable.seq}; keeping the higher value`);
      return;
    }
    wm.durable = mark;
    store.setDurable(mark);
    log.info(`durable watermark epoch=${mark.epoch} seq=${mark.seq} (${st.size} bytes)`);
  } catch (err) {
    wm.error = errorMessage(err);
    log.warn(`global_mod_data.bin parse failed (keeping previous watermark): ${wm.error}`);
  }
}

// ---- main ----
fs.mkdirSync(config.stateDir, { recursive: true });
store.loadCheckpoint();
orders.loadIndex();
log.info(`economyDir=${config.economyDir}`);
log.info(`modData=${config.modDataBin}`);
log.info(`checkpoint file=${store.file ?? "-"} offset=${store.offset} nextIndex=${store.nextIndex}`);

const first = store.poll();
log.info(`ingested ${first} events on start (${store.events.length} in memory)`);
pollModData(true);
accounts.refresh();

setInterval(() => {
  try { store.poll(); } catch (err) { log.error(`poll failed: ${errorMessage(err)}`); }
  try { pollModData(); } catch (err) { log.error(`moddata poll failed: ${errorMessage(err)}`); }
  // inbox files whose outcome is durable are done: delete them so Lua stops seeing them
  try { orders.sweep(); } catch (err) { log.error(`inbox sweep failed: ${errorMessage(err)}`); }
}, config.pollMs).unref();
setInterval(() => accounts.refresh(), config.accountsRefreshMs).unref();

const server = createServer({ config, store, accounts, watermark: () => wm, orders, log });
server.listen(config.port, config.bind, () => {
  log.info(`listening on http://${config.bind}:${config.port}`);
});

function shutdown(): void {
  log.info("shutting down");
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 2000).unref();
}
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
