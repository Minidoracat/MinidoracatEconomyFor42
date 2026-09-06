// Entry point: node src/index.js  (see config.js for environment variables)
import fs from "node:fs";
import { config } from "./config.js";
import { EventStore } from "./events.js";
import { Accounts } from "./accounts.js";
import { parseGlobalModData, economyWatermark } from "./bin.js";
import { createServer } from "./server.js";

const log = {
  info: (m) => console.log(`[companion] ${m}`),
  warn: (m) => console.warn(`[companion] WARN ${m}`),
  error: (m) => console.error(`[companion] ERROR ${m}`),
};

const store = new EventStore({ economyDir: config.economyDir, stateDir: config.stateDir, maxEvents: config.maxEventsInMemory, log });
const accounts = new Accounts({ whitelistDb: config.whitelistDb, playersDb: config.playersDb, stateDir: config.stateDir, log });

// ---- durable watermark from global_mod_data.bin ----
// The engine writes global_mod_data.tmp and then copies it over the .bin (GlobalModData.java:258-266):
// wait until the mtime has been stable for one poll before parsing, and never lower the watermark.
const wm = { durable: null, mtime: null, seenMtime: null, parsedAt: null, error: null, sizeBytes: null };

function pollModData(force = false) {
  let st;
  try {
    st = fs.statSync(config.modDataBin);
  } catch (err) {
    if (err.code !== "ENOENT") wm.error = err.message;
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
    if (!mark) {
      log.warn(`table ${config.modDataTag} not present in global_mod_data.bin yet`);
      return;
    }
    if (wm.durable && wm.durable.epoch === mark.epoch && mark.seq < wm.durable.seq) {
      log.warn(`watermark went backwards within epoch ${mark.epoch}: ${mark.seq} < ${wm.durable.seq}; keeping the higher value`);
      return;
    }
    wm.durable = mark;
    store.setDurable(mark);
    log.info(`durable watermark epoch=${mark.epoch} seq=${mark.seq} (${st.size} bytes)`);
  } catch (err) {
    wm.error = err.message;
    log.warn(`global_mod_data.bin parse failed (keeping previous watermark): ${err.message}`);
  }
}

// ---- main ----
fs.mkdirSync(config.stateDir, { recursive: true });
store.loadCheckpoint();
log.info(`economyDir=${config.economyDir}`);
log.info(`modData=${config.modDataBin}`);
log.info(`checkpoint file=${store.file ?? "-"} offset=${store.offset} nextIndex=${store.nextIndex}`);

const first = store.poll();
log.info(`ingested ${first} events on start (${store.events.length} in memory)`);
pollModData(true);
accounts.refresh();

setInterval(() => {
  try { store.poll(); } catch (err) { log.error(`poll failed: ${err.message}`); }
  try { pollModData(); } catch (err) { log.error(`moddata poll failed: ${err.message}`); }
}, config.pollMs).unref();
setInterval(() => accounts.refresh(), config.accountsRefreshMs).unref();

const server = createServer({ config, store, accounts, watermark: () => wm, log });
server.listen(config.port, config.bind, () => {
  log.info(`listening on http://${config.bind}:${config.port}`);
});

function shutdown() {
  log.info("shutting down");
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 2000).unref();
}
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
