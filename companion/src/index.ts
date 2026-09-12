// Entry point: node src/index.ts  (Node >= 24 strips the types itself; see config.ts for env vars)
import fs from "node:fs";
import { config } from "./config.ts";
import { EventStore, errorCode, errorMessage, type Logger } from "./events.ts";
import { Accounts } from "./accounts.ts";
import { parseGlobalModData, economyWatermark, type Watermark } from "./bin.ts";
import { createServer, type WatermarkState, type DurableRecord, type PendingPublish } from "./server.ts";
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
//
// The parsed watermark is also published to {economyDir}/durable.json (tmp + rename) so Lua can tell
// which of its pending writes this uptime really made durable. Only a snapshot that settled across a
// poll and carries a complete {realmId, epoch, seq} is published: the startup poll (force) skips the
// settle wait, so it only stages the record and the next poll confirms the mtime before writing.
// A failed write keeps the previous file and is retried by the next poll, .bin unchanged or not.
const durableFile = path.join(config.economyDir, "durable.json");
const wm: Required<WatermarkState> & { seenMtime: number | null } = {
  durable: null, mtime: null, seenMtime: null, parsedAt: null, error: null, sizeBytes: null,
  published: null, pending: null, publishError: null,
};

/** The watermark as a publishable record, or null when the snapshot does not carry a complete one. */
function publishable(mark: Watermark, st: fs.Stats): PendingPublish | null {
  if (mark.realmId === null || mark.realmId === "" || mark.epoch === "") return null;
  if (!Number.isSafeInteger(mark.seq) || mark.seq < 0) return null;
  return { realmId: mark.realmId, epoch: mark.epoch, seq: mark.seq, mtime: st.mtimeMs, size: st.size };
}

/** Writes wm.pending to durable.json, once the .bin it came from is still the one on disk. */
function publishPending(st: fs.Stats): void {
  const next = wm.pending;
  if (next === null) return;
  if (st.mtimeMs !== next.mtime || st.size !== next.size) {
    wm.pending = null;   // the snapshot we parsed never settled: publish nothing for it
    return;
  }
  const prev = wm.published;
  if (prev !== null && prev.realmId === next.realmId && prev.epoch === next.epoch && next.seq <= prev.seq) {
    wm.pending = null;   // already on disk, and the marker never goes down inside an epoch
    wm.publishError = null;
    return;
  }
  const record: DurableRecord = { realmId: next.realmId, epoch: next.epoch, seq: next.seq, ts: Date.now() };
  const tmp = `${durableFile}.tmp`;
  try {
    fs.writeFileSync(tmp, JSON.stringify(record) + "\n");
    fs.renameSync(tmp, durableFile);
  } catch (err) {
    const failure = errorMessage(err);
    if (failure !== wm.publishError) log.warn(`durable.json write failed (previous file kept, retrying every poll): ${failure}`);
    wm.publishError = failure;
    return;
  }
  wm.pending = null;
  wm.published = record;
  wm.publishError = null;
  log.info(`published durable.json realm=${record.realmId} epoch=${record.epoch} seq=${record.seq}`);
}

function pollModData(force = false): void {
  let st: fs.Stats;
  try {
    st = fs.statSync(config.modDataBin);
  } catch (err) {
    wm.error = errorCode(err) === "ENOENT" ? "snapshot_missing" : errorMessage(err);
    return;
  }
  publishPending(st);   // confirm/retry a watermark that is not on disk yet, .bin changed or not
  if (st.mtimeMs === wm.mtime && st.size === wm.sizeBytes && wm.error === null) return;
  if (!force && st.mtimeMs !== wm.seenMtime) { wm.seenMtime = st.mtimeMs; return; }   // let the copy settle
  let mark: Watermark | null;
  try {
    const bytes = fs.readFileSync(config.modDataBin);
    const after = fs.statSync(config.modDataBin);
    if (after.size !== st.size || after.mtimeMs !== st.mtimeMs || bytes.length !== st.size) throw new Error("snapshot_changed");
    mark = economyWatermark(parseGlobalModData(bytes), config.modDataTag);
  } catch (err) {
    wm.error = errorMessage(err);
    log.warn(`global_mod_data.bin parse failed (keeping previous watermark): ${wm.error}`);
    return;
  }
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
  const next = publishable(mark, st);
  if (next === null) {
    wm.publishError = "incomplete_watermark";
    log.warn(`durable.json not published: realmId/epoch/seq incomplete (realm=${mark.realmId ?? "-"} epoch=${mark.epoch} seq=${mark.seq})`);
    return;
  }
  wm.pending = next;
  if (!force) publishPending(st);   // this snapshot already settled, the startup one has not
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

const pollTimer = setInterval(() => {
  try { store.poll(); } catch (err) { log.error(`poll failed: ${errorMessage(err)}`); }
  try { pollModData(); } catch (err) { log.error(`moddata poll failed: ${errorMessage(err)}`); }
  // inbox files whose outcome is durable are done: delete them so Lua stops seeing them
  try { orders.sweep(); } catch (err) { log.error(`inbox sweep failed: ${errorMessage(err)}`); }
}, config.pollMs).unref();
const accountsTimer = setInterval(() => accounts.refresh(), config.accountsRefreshMs).unref();

const server = createServer({ config, store, accounts, watermark: () => wm, orders, log });
server.listen(config.port, config.bind, () => {
  log.info(`listening on http://${config.bind}:${config.port}`);
});

let stopping = false;
function shutdown(): void {
  if (stopping) return;
  stopping = true;
  log.info("shutting down");
  clearInterval(pollTimer);
  clearInterval(accountsTimer);
  server.close(() => process.exit(0));
  try {
    store.saveCheckpoint();
    orders.saveIndex();
    setTimeout(() => process.exit(0), 2000).unref();
  } catch (err) {
    log.error(`shutdown failed: ${errorMessage(err)}`);
    process.exit(1);
  }
}
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
