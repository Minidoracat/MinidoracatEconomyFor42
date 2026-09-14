// Read-only source snapshot for the daily reconciliation report.
//
// Sources, opened read-only and never advanced:
//   {economyDir}/events-YYYYMMDD.json   NDJSON transaction record (ECExport.onCommitted writes
//                                       tx.committed; X.emit writes server.started /
//                                       epoch.rolledback / ledger.anomaly / file.header)
//   {economyDir}/epochs.json            one {epoch, loadedSeq, flagged?} line per server start,
//                                       appended in startup order (ECServer.S.EPOCHS_FILE).
//                                       Carries no realmId.
//   global_mod_data.bin                 the save: meta{epoch, seq, realmId} is the durable
//                                       watermark, meta.history{[i]={epoch, loadedSeq}} the
//                                       rollback point of every epoch that reached a save
//                                       (ECServer.initModData), wallets{} the saved balances.
//
// Untouched on purpose: players.db, whitelist db, inbox/, receipts/, companion-state/ and
// durable.json. EventStore.poll() is not used either - it writes a checkpoint and evicts events.
//
// Durability is asserted from evidence only, mirroring ECServer.epochVerdict: inside an epoch,
// seq <= that epoch's loadedSeq survived into the save the next start loaded, seq above it did
// not. A cutoff may only come from
//   * meta.history in the save (realm-proven through meta.realmId),
//   * an epoch.rolledback{crashedEpoch, fromSeq} line of this realm,
//   * two truly adjacent epochs.json lines whose loadedSeq both match the loadedSeq the
//     same-realm server.started of that epoch reported.
// Event file names are NEVER used to order epochs: a missing day file or a clock that went
// backwards would make two unrelated starts look adjacent and forge durability. One damaged line
// anywhere in epochs.json disables the whole journal order, because two lines that are no longer
// provably adjacent may not be connected.
import fs from "node:fs";
import path from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { economyWatermark, parseGlobalModData, type LuaTable, type LuaValue, type ParsedModData, type Watermark } from "./bin.ts";
import { errorCode, errorMessage } from "./events.ts";

export type { Watermark } from "./bin.ts";

export type ReportStatus = "durable" | "rolled_back" | "pending" | "unknown";

export interface ReportIssue {
  code: string;
  message: string;
  file?: string;
  line?: number;
  txId?: string;
  account?: string;
  currency?: string;
}

export interface ReportPosting {
  account: string;
  currency: string;
  amount: number;
  bucket: "available" | "reserved";
  availableBefore: number;
  availableAfter: number;
  reservedBefore: number;
  reservedAfter: number;
}

export interface ReportTransaction {
  txId: string;
  epoch: string;
  seq: number;
  ts: number;
  kind: string;
  actor?: string;
  reasonCode?: string;
  reasonText?: string;
  requestId?: string;
  payload?: unknown;
  status: ReportStatus;
  /** false when a ledger invariant failed, the realm is foreign, or the txId is not unique. */
  valid: boolean;
  postings: ReportPosting[];
  file: string;
  line: number;
}

export interface ReportWalletBalance {
  available: number;
  reserved: number;
}

export interface ReportSource {
  asOf: number;
  realmId: string | null;
  watermark: Watermark | null;
  transactions: ReportTransaction[];
  issues: ReportIssue[];
  files: { name: string; size: number }[];
  /** Saved balances from the .bin: account -> currency -> balance (system accounts included). */
  wallets: Map<string, Map<string, ReportWalletBalance>>;
  /**
   * Startup order that the intact epochs.json journal proves, earliest first. Absent when the
   * journal is damaged or contradicts the event stream: there is then no proven epoch order at
   * all, and none is guessed from timestamps or file names.
   */
  epochOrder?: string[];
}

export interface ReadReportSourceOptions {
  economyDir: string;
  modDataBin: string;
  modDataTag: string;
  /** The .bin is copied over, not renamed: it must be byte-identical across this window. */
  settleMs: number;
  /** Hard ceiling on ingested records. Reaching it aborts the scan instead of dropping records. */
  maxEvents: number;
}

const EVENT_FILE = /^events-(\d{8})\.json$/;                // ECExport.eventsPath
const EPOCHS_FILE = "epochs.json";                          // ECServer.S.EPOCHS_FILE
const SYSTEM_PREFIXES = ["SYSTEM_", "EXTERNAL_", "MOD:"];   // ECLedger.L.SYSTEM_PREFIXES
const SCHEMA_VERSION = 1;                                   // EC.SCHEMA_VERSION
const READ_CHUNK = 64 * 1024;
/** A record the mod writes is a few hundred bytes; past this the line is treated as damage. */
const MAX_LINE_BYTES = 256 * 1024;
/** Fatal: a damaged byte must surface as a refused line, never as U+FFFD inside valid JSON. */
const DECODER = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });

export function isSystemAccount(account: string): boolean {
  return SYSTEM_PREFIXES.some((prefix) => account.startsWith(prefix));
}

// Length framing avoids collisions even when external identifiers contain separators.
export function walletKey(account: string, currency: string): string {
  return `${account.length}:${account}${currency}`;
}

type Where = Pick<ReportIssue, "file" | "line" | "txId" | "account" | "currency">;

function issue(code: string, message: string, where: Partial<Where> = {}): ReportIssue {
  return { code, message, ...where };
}

/** The value as a plain object to read fields off, or null. No copy is made. */
function objectOf(value: unknown): object | null {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return null;
  return value;
}

/** A non-empty string field, or null. */
function text(source: object, key: string): string | null {
  const value: unknown = Reflect.get(source, key);
  return typeof value === "string" && value !== "" ? value : null;
}

/** A safe-integer field, or null: a JSON double outside that range is not money. */
function integer(source: object, key: string): number | null {
  const value: unknown = Reflect.get(source, key);
  return typeof value === "number" && Number.isSafeInteger(value) ? value : null;
}

/** The same rule for a Lua table value (every number in the .bin is a double). */
function luaInteger(value: LuaValue | undefined): number | null {
  return typeof value === "number" && Number.isSafeInteger(value) ? value : null;
}

// ---------------------------------------------------------------- streaming line reader

type LineFailure = "invalid_utf8" | "overlong";

interface LineScan {
  /** fstat before and after the read disagree: the file moved while being read. */
  changed: boolean;
  /** The file ended without a newline: the last line is a torn write. */
  unterminated: boolean;
  /** 1-based number of that torn tail. */
  tailLine: number;
  /** Size the file had when it was opened. */
  size: number;
  /** The handler stopped the scan (record ceiling). */
  stopped: boolean;
}

/**
 * Streams one NDJSON file through a fixed buffer, splitting on LF at byte level (0x0A cannot
 * occur inside a UTF-8 sequence) and decoding each complete line on its own. Nothing larger than
 * one chunk plus one line is ever held. `onLine` returns false to stop the scan.
 */
function scanLines(
  fullPath: string,
  onLine: (lineNo: number, lineText: string | null, failure: LineFailure | null) => boolean,
): LineScan {
  const fd = fs.openSync(fullPath, "r");
  try {
    const before = fs.fstatSync(fd);
    const buffer = Buffer.allocUnsafe(READ_CHUNK);
    let position = 0;
    let lineNo = 0;
    /** Bytes of a line that spans chunks. */
    let carry: Buffer | null = null;
    let overlong = false;
    let stopped = false;
    while (!stopped) {
      const n = fs.readSync(fd, buffer, 0, buffer.length, position);
      if (n === 0) break;
      position += n;
      const chunk = buffer.subarray(0, n);
      let start = 0;
      while (start < n) {
        const nl = chunk.indexOf(0x0a, start);
        const piece = chunk.subarray(start, nl < 0 ? n : nl);
        if (nl < 0) {
          // The line continues in the next chunk; the buffer is reused, so this must be copied.
          if (!overlong) {
            if ((carry === null ? 0 : carry.length) + piece.length > MAX_LINE_BYTES) {
              overlong = true;
              carry = null;
            } else {
              carry = carry === null ? Buffer.from(piece) : Buffer.concat([carry, piece]);
            }
          }
          start = n;
          break;
        }
        lineNo++;
        const body = carry === null ? piece : Buffer.concat([carry, piece]);
        const tooLong = overlong || body.length > MAX_LINE_BYTES;
        carry = null;
        overlong = false;
        start = nl + 1;
        if (tooLong) {
          if (!onLine(lineNo, null, "overlong")) stopped = true;
        } else {
          const end = body.length > 0 && body[body.length - 1] === 0x0d ? body.length - 1 : body.length;
          let decoded: string | null = null;
          let failure: LineFailure | null = null;
          try {
            decoded = DECODER.decode(body.subarray(0, end));
          } catch {
            failure = "invalid_utf8";
          }
          if (!onLine(lineNo, decoded, failure)) stopped = true;
        }
        if (stopped) break;
      }
    }
    const after = fs.fstatSync(fd);
    return {
      changed: after.size !== before.size || after.mtimeMs !== before.mtimeMs,
      unterminated: !stopped && (carry !== null || overlong),
      tailLine: lineNo + 1,
      size: before.size,
      stopped,
    };
  } finally {
    fs.closeSync(fd);
  }
}

function failureIssue(failure: LineFailure, file: string, line: number, prefix: string): ReportIssue {
  return failure === "overlong"
    ? issue("line_overlong", `${prefix}該行超過 ${MAX_LINE_BYTES} bytes 的界線，視為損毀，已拒絕解析`, { file, line })
    : issue("line_invalid_utf8", `${prefix}該行不是合法 UTF-8，已拒絕解析（不以替換字元帶過）`, { file, line });
}

// ---------------------------------------------------------------- global_mod_data.bin

interface EpochStart {
  epoch: string;
  loadedSeq: number;
}

interface BinBytes {
  bytes: Buffer;
  size: number;
  mtimeMs: number;
}

interface BinSnapshot {
  watermark: Watermark | null;
  history: EpochStart[];
  wallets: Map<string, Map<string, ReportWalletBalance>>;
}

/** One fd, fstat before and after: a snapshot that moved under the read is refused. */
function readSnapshot(file: string): BinBytes {
  const fd = fs.openSync(file, "r");
  try {
    const before = fs.fstatSync(fd);
    const bytes = Buffer.allocUnsafe(before.size);
    let read = 0;
    while (read < bytes.length) {
      const n = fs.readSync(fd, bytes, read, bytes.length - read, read);
      if (n === 0) break;
      read += n;
    }
    const after = fs.fstatSync(fd);
    if (read !== bytes.length || after.size !== before.size || after.mtimeMs !== before.mtimeMs) {
      throw new Error("snapshot_changed");
    }
    return { bytes, size: before.size, mtimeMs: before.mtimeMs };
  } finally {
    fs.closeSync(fd);
  }
}

function readWallets(table: LuaTable, file: string, issues: ReportIssue[]): Map<string, Map<string, ReportWalletBalance>> {
  const out = new Map<string, Map<string, ReportWalletBalance>>();
  const wallets = table.wallets;
  if (wallets === undefined) {
    issues.push(issue("wallets_missing", "存檔的 wallets 區塊不存在，無法與帳本結果對帳", { file }));
    return out;
  }
  if (typeof wallets !== "object") {
    issues.push(issue("wallets_invalid", "存檔的 wallets 區塊型別不是表，已整塊忽略", { file }));
    return out;
  }
  for (const [account, byCurrency] of Object.entries(wallets)) {
    if (typeof byCurrency !== "object") {
      issues.push(issue("wallet_account_invalid", `存檔錢包 ${account} 的內容不是表，已忽略`, { file, account }));
      continue;
    }
    const balances = new Map<string, ReportWalletBalance>();
    for (const [currency, wallet] of Object.entries(byCurrency)) {
      const available = typeof wallet === "object" ? luaInteger(wallet.available) : null;
      const reserved = typeof wallet === "object" ? luaInteger(wallet.reserved) : null;
      if (available === null || reserved === null) {
        issues.push(issue("wallet_balance_invalid",
          `存檔錢包 ${account}/${currency} 的 available/reserved 不是安全整數，已忽略`, { file, account, currency }));
        continue;
      }
      balances.set(currency, { available, reserved });
    }
    if (balances.size > 0) out.set(account, balances);
  }
  return out;
}

/** meta.history: the rollback point of every epoch that reached a save. A Lua array. */
function readHistory(table: LuaTable, file: string, issues: ReportIssue[]): EpochStart[] {
  const out: EpochStart[] = [];
  const meta = table.meta;
  if (typeof meta !== "object") return out;
  const history = meta.history;
  if (history === undefined) {
    issues.push(issue("history_missing", "存檔 meta.history 不存在：舊 epoch 的回滾點沒有存檔證據", { file }));
    return out;
  }
  if (typeof history !== "object") {
    issues.push(issue("history_invalid", "存檔 meta.history 型別不是表，已整塊忽略", { file }));
    return out;
  }
  for (const key of Object.keys(history)) {
    const entry = history[key];
    const epoch = entry !== undefined && typeof entry === "object" ? entry.epoch : undefined;
    const loadedSeq = entry !== undefined && typeof entry === "object" ? luaInteger(entry.loadedSeq) : null;
    if (typeof epoch !== "string" || epoch === "" || loadedSeq === null || loadedSeq < 0) {
      issues.push(issue("history_entry_invalid", `存檔 meta.history[${key}] 的 epoch/loadedSeq 不可用，已忽略該筆`, { file }));
      continue;
    }
    out.push({ epoch, loadedSeq });
  }
  return out;
}

async function readBin(
  options: ReadReportSourceOptions,
  files: { name: string; size: number }[],
  issues: ReportIssue[],
): Promise<BinSnapshot | null> {
  const file = path.basename(options.modDataBin);
  let first: BinBytes;
  try {
    first = readSnapshot(options.modDataBin);
  } catch (err) {
    const missing = errorCode(err) === "ENOENT";
    issues.push(issue(missing ? "modData_missing" : "modData_unreadable",
      `讀不到存檔快照（沒有耐久性證據，交易一律無法確認已落盤）: ${errorMessage(err)}`, { file }));
    return null;
  }
  await delay(Math.max(0, options.settleMs));
  let second: BinBytes;
  try {
    second = readSnapshot(options.modDataBin);
  } catch (err) {
    issues.push(issue("modData_unstable", `存檔快照在觀察窗內被改寫: ${errorMessage(err)}`, { file }));
    return null;
  }
  if (first.size !== second.size || first.mtimeMs !== second.mtimeMs || !first.bytes.equals(second.bytes)) {
    issues.push(issue("modData_unstable",
      `存檔快照在 ${options.settleMs}ms 觀察窗前後不一致（遊戲正在寫檔），本次不採用其水位`, { file }));
    return null;
  }
  files.push({ name: file, size: second.size });

  let parsed: ParsedModData;
  try {
    parsed = parseGlobalModData(second.bytes);
  } catch (err) {
    issues.push(issue("modData_parse_failed", `存檔快照解析失敗（不採用任何水位）: ${errorMessage(err)}`, { file }));
    return null;
  }
  const table = parsed.tables.get(options.modDataTag);
  if (table === undefined) {
    issues.push(issue("economy_table_missing",
      `存檔快照裡沒有 ${options.modDataTag} 區塊（此存檔尚未寫入經濟資料）`, { file }));
    return null;
  }
  const wallets = readWallets(table, file, issues);
  const history = readHistory(table, file, issues);

  let watermark = economyWatermark(parsed, options.modDataTag);
  if (watermark === null) {
    issues.push(issue("watermark_missing", "存檔快照沒有可用的 meta{epoch, seq}，無法判定任何交易已落盤", { file }));
  } else if (!Number.isSafeInteger(watermark.seq) || watermark.seq < 0) {
    issues.push(issue("watermark_invalid", `存檔水位 seq=${watermark.seq} 不是安全的非負整數，不予採用`, { file }));
    watermark = null;
  } else if (watermark.realmId === null) {
    issues.push(issue("watermark_realm_missing",
      "存檔水位沒有 realmId，無法證明它與事件流屬於同一世界，因此不採用其耐久性證據", { file }));
  }
  return { watermark, history, wallets };
}

// ---------------------------------------------------------------- epochs.json

interface Journal {
  entries: EpochStart[];
  /** false when any line was unusable: two lines are then no longer provably adjacent. */
  intact: boolean;
}

function readJournal(economyDir: string, files: { name: string; size: number }[], issues: ReportIssue[]): Journal {
  const file = EPOCHS_FILE;
  const full = path.join(economyDir, EPOCHS_FILE);
  const entries: EpochStart[] = [];
  let intact = true;
  let scan: LineScan;
  try {
    scan = scanLines(full, (line, lineText, failure) => {
      if (failure !== null) {
        issues.push(failureIssue(failure, file, line, "epochs.json "));
        intact = false;
        return true;
      }
      if (lineText === null || lineText.trim() === "") return true;
      let doc: unknown;
      try {
        doc = JSON.parse(lineText);
      } catch (err) {
        issues.push(issue("epochs_line_unparseable", `epochs.json 該行不是合法 JSON: ${errorMessage(err)}`, { file, line }));
        intact = false;
        return true;
      }
      const record = objectOf(doc);
      const epoch = record === null ? null : text(record, "epoch");
      const loadedSeq = record === null ? null : integer(record, "loadedSeq");
      if (epoch === null || loadedSeq === null || loadedSeq < 0) {
        issues.push(issue("epochs_line_invalid", "epochs.json 該行缺少可用的 epoch/loadedSeq", { file, line }));
        intact = false;
        return true;
      }
      entries.push({ epoch, loadedSeq });
      return true;
    });
  } catch (err) {
    const missing = errorCode(err) === "ENOENT";
    issues.push(issue(missing ? "epochs_file_missing" : "epochs_file_unreadable",
      `讀不到啟動紀錄 epochs.json（沒有可信的 epoch 先後順序）: ${errorMessage(err)}`, { file }));
    return { entries: [], intact: false };
  }
  files.push({ name: file, size: scan.size });
  if (scan.unterminated) {
    // writeln always ends the line: a missing newline is a torn write.
    issues.push(issue("epochs_line_unterminated",
      "epochs.json 最後一行沒有換行結尾（寫入未完成）", { file, line: scan.tailLine }));
    intact = false;
  }
  if (scan.changed) {
    issues.push(issue("epochs_file_changed", "epochs.json 在讀取期間被改寫，本次讀到的順序不可信", { file }));
    intact = false;
  }
  return { entries, intact };
}

// ---------------------------------------------------------------- event stream

interface Startup extends EpochStart {
  realmId: string | null;
}

interface Rollback {
  epoch: string;
  fromSeq: number;
  realmId: string | null;
}

interface EventStream {
  transactions: ReportTransaction[];
  startups: Startup[];
  rollbacks: Rollback[];
  /** Every realmId seen on any record. */
  realms: Set<string>;
  /** The realm each transaction claims (null when the line carried none). */
  realmOf: Map<ReportTransaction, string | null>;
}

/** One tx.committed line, or null when it carries no usable identity. */
function parseTransaction(record: object, file: string, line: number, issues: ReportIssue[]): ReportTransaction | null {
  const txId = text(record, "txId");
  const epoch = text(record, "epoch");
  const seq = integer(record, "seq");
  const ts = integer(record, "ts");
  const kind = text(record, "kind");
  if (txId === null || epoch === null || seq === null || seq <= 0 || ts === null || ts <= 0 || kind === null) {
    issues.push(issue("tx_identity_invalid",
      "tx.committed 缺少可用身份（txId/epoch/seq/ts/kind 之一不合法），這一行無法納入任何統計",
      txId === null ? { file, line } : { file, line, txId }));
    return null;
  }
  const tx: ReportTransaction = { txId, epoch, seq, ts, kind, status: "unknown", valid: true, postings: [], file, line };

  // EC.makeId uses the canonical integer spelling; accepting aliases would bypass duplicate IDs.
  if (txId !== `${epoch}:${seq}`) {
    tx.valid = false;
    issues.push(issue("tx_id_mismatch",
      `txId 與 epoch:seq 不一致（epoch=${epoch} seq=${seq}），身份不可信，已排除於統計`, { file, line, txId }));
  }

  const actor = text(record, "actor");
  if (actor !== null) tx.actor = actor;
  const reasonText = text(record, "reasonText");
  if (reasonText !== null) tx.reasonText = reasonText;
  const payload: unknown = Reflect.get(record, "payload");
  if (payload !== undefined) tx.payload = payload;

  // ECLedger.validate refuses a commit without these two, so a line missing them is corrupt.
  const reasonCode = text(record, "reasonCode");
  if (reasonCode === null) {
    tx.valid = false;
    issues.push(issue("tx_reason_code_missing", "tx.committed 沒有 reasonCode（帳本不可能這樣提交）", { file, line, txId }));
  } else {
    tx.reasonCode = reasonCode;
  }
  const requestId = text(record, "requestId");
  if (requestId === null) {
    tx.valid = false;
    issues.push(issue("tx_request_id_missing", "tx.committed 沒有 requestId（帳本不可能這樣提交）", { file, line, txId }));
  } else {
    tx.requestId = requestId;
  }

  const rawPostings: unknown = Reflect.get(record, "postings");
  if (!Array.isArray(rawPostings) || rawPostings.length === 0) {
    tx.valid = false;
    issues.push(issue("tx_postings_missing", "tx.committed 沒有 postings 陣列，無法核對任何金額", { file, line, txId }));
    return tx;
  }
  const postings: unknown[] = rawPostings;

  // Sums and the before/after arithmetic run in BigInt: every field is a safe integer on its own,
  // but their sums are not bounded by that, and a float carry would silently pass or fail.
  const sums = new Map<string, bigint>();
  const seen = new Set<string>();
  /** The wallet as it stands after the previous posting of this same transaction. */
  const running = new Map<string, ReportWalletBalance>();
  for (let i = 0; i < postings.length; i++) {
    const entry = objectOf(postings[i]);
    if (entry === null) {
      tx.valid = false;
      issues.push(issue("posting_invalid", `postings[${i}] 不是物件，已略過該筆分錄`, { file, line, txId }));
      continue;
    }
    const account = text(entry, "account");
    const currency = text(entry, "currency");
    const amount = integer(entry, "amount");
    const availableBefore = integer(entry, "availableBefore");
    const availableAfter = integer(entry, "availableAfter");
    const reservedBefore = integer(entry, "reservedBefore");
    const reservedAfter = integer(entry, "reservedAfter");
    if (account === null || currency === null || amount === null || amount === 0
      || availableBefore === null || availableAfter === null || reservedBefore === null || reservedAfter === null) {
      tx.valid = false;
      issues.push(issue("posting_invalid",
        `postings[${i}] 的 account/currency/amount 或前後餘額不是合法值（金額須為非零安全整數），已略過該筆分錄`,
        { file, line, txId, ...(account === null ? {} : { account }), ...(currency === null ? {} : { currency }) }));
      continue;
    }
    // ECLedger only writes `bucket` on the reserved leg: an absent field means "available".
    const rawBucket: unknown = Reflect.get(entry, "bucket");
    let bucket: "available" | "reserved" | null = null;
    if (rawBucket === undefined || rawBucket === "available") bucket = "available";
    else if (rawBucket === "reserved") bucket = "reserved";
    if (bucket === null) {
      tx.valid = false;
      issues.push(issue("posting_bucket_invalid", `postings[${i}] 的 bucket 不是 available/reserved，已略過該筆分錄`,
        { file, line, txId, account, currency }));
      continue;
    }
    tx.postings.push({ account, currency, amount, bucket, availableBefore, availableAfter, reservedBefore, reservedAfter });

    const system = isSystemAccount(account);
    if (bucket === "reserved" && system) {
      tx.valid = false;
      issues.push(issue("posting_reserved_system", `系統帳 ${account} 不得有 reserved 分錄`, { file, line, txId, account, currency }));
    }
    const key = `${bucket}:${walletKey(account, currency)}`;
    if (seen.has(key)) {
      tx.valid = false;
      issues.push(issue("posting_duplicate", `同一交易對 ${account}/${currency}/${bucket} 有兩筆分錄`, { file, line, txId, account, currency }));
    }
    seen.add(key);

    // ECLedger.post applies the postings of one transaction to the wallet one after another, so a
    // wallet's second posting (the reserved leg of a bid) starts from the first one's result.
    const wallet = walletKey(account, currency);
    const previous = running.get(wallet);
    if (previous !== undefined && (previous.available !== availableBefore || previous.reserved !== reservedBefore)) {
      tx.valid = false;
      issues.push(issue("posting_chain_broken",
        `${account}/${currency} 的分錄前值與同交易前一筆的後值不接（前一筆後值 ${previous.available}/${previous.reserved}，本筆前值 ${availableBefore}/${reservedBefore}）`,
        { file, line, txId, account, currency }));
    }
    const delta = BigInt(amount);
    const expectedAvailable = bucket === "available" ? BigInt(availableBefore) + delta : BigInt(availableBefore);
    const expectedReserved = bucket === "reserved" ? BigInt(reservedBefore) + delta : BigInt(reservedBefore);
    if (BigInt(availableAfter) !== expectedAvailable || BigInt(reservedAfter) !== expectedReserved) {
      tx.valid = false;
      issues.push(issue("posting_arithmetic_broken",
        `${account}/${currency} 的 ${bucket} 分錄前後餘額與金額不符（應為 ${expectedAvailable}/${expectedReserved}，實為 ${availableAfter}/${reservedAfter}）`,
        { file, line, txId, account, currency }));
    }
    running.set(wallet, { available: availableAfter, reserved: reservedAfter });
    // A system account may go negative (it is the issuer); a player wallet may not.
    if (!system && (availableAfter < 0 || reservedAfter < 0)) {
      tx.valid = false;
      issues.push(issue("posting_negative_balance",
        `玩家帳 ${account}/${currency} 的餘額在此分錄後為負（${availableAfter}/${reservedAfter}），帳本不允許`,
        { file, line, txId, account, currency }));
    }
    sums.set(currency, (sums.get(currency) ?? 0n) + delta);
  }
  for (const [currency, sum] of sums) {
    if (sum !== 0n) {
      tx.valid = false;
      issues.push(issue("tx_unbalanced", `此交易在 ${currency} 的分錄總和為 ${sum}（必須為 0）`, { file, line, txId, currency }));
    }
  }
  return tx;
}

function readEvents(options: ReadReportSourceOptions, files: { name: string; size: number }[], issues: ReportIssue[]): EventStream {
  const stream: EventStream = { transactions: [], startups: [], rollbacks: [], realms: new Set(), realmOf: new Map() };
  let names: string[];
  try {
    names = fs.readdirSync(options.economyDir).filter((name) => EVENT_FILE.test(name)).sort();
  } catch (err) {
    issues.push(issue("events_dir_unreadable", `讀不到事件目錄，這份報告沒有任何交易來源: ${errorMessage(err)}`));
    return stream;
  }
  if (names.length === 0) {
    issues.push(issue("events_missing", "事件目錄裡沒有任何 events-YYYYMMDD.json；不得因此推論交易為零"));
    return stream;
  }
  let records = 0;
  for (const file of names) {
    const full = path.join(options.economyDir, file);
    let scan: LineScan;
    try {
      scan = scanLines(full, (line, lineText, failure) => {
        if (failure !== null) {
          issues.push(failureIssue(failure, file, line, "事件檔 "));
          return true;
        }
        if (lineText === null || lineText.trim() === "") return true;
        // The ceiling is checked before any parsing or allocation for this line.
        if (records >= options.maxEvents) {
          issues.push(issue("events_limit_reached",
            `已讀取 ${records} 筆紀錄達到 maxEvents 上限，掃描在此中止：本次來源不完整，未讀的紀錄既未被丟棄也不得當成不存在`,
            { file, line }));
          return false;
        }
        records++;
        let doc: unknown;
        try {
          doc = JSON.parse(lineText);
        } catch (err) {
          issues.push(issue("events_line_unparseable", `事件行不是合法 JSON: ${errorMessage(err)}`, { file, line }));
          return true;
        }
        const record = objectOf(doc);
        if (record === null) {
          issues.push(issue("events_line_not_object", "事件行不是 JSON 物件", { file, line }));
          return true;
        }
        ingest(record, file, line, stream, issues);
        return true;
      });
    } catch (err) {
      issues.push(issue("events_file_unreadable", `事件檔讀取失敗，這一天的紀錄不完整: ${errorMessage(err)}`, { file }));
      continue;
    }
    files.push({ name: file, size: scan.size });
    if (scan.unterminated) {
      issues.push(issue("events_line_unterminated",
        "事件檔最後一行沒有換行結尾（寫入尚未完成），該行未解析", { file, line: scan.tailLine }));
    }
    if (scan.changed) {
      issues.push(issue("events_file_changed",
        "事件檔在讀取期間被改寫或增長，本次讀到的內容不保證是完整的一天", { file }));
    }
    if (scan.stopped) return stream;
  }
  return stream;
}

function ingest(record: object, file: string, line: number, stream: EventStream, issues: ReportIssue[]): void {
  const type = text(record, "type");
  if (type === null) {
    issues.push(issue("events_line_type_missing", "事件行沒有 type 欄位", { file, line }));
    return;
  }
  const realmId = text(record, "realmId");
  if (realmId === null) {
    issues.push(issue("record_realm_missing", `${type} 行沒有 realmId，無法證明它屬於本世界`, { file, line }));
  } else {
    stream.realms.add(realmId);
  }
  switch (type) {
    case "file.header": {
      const schemaVersion = integer(record, "schemaVersion");
      if (schemaVersion !== SCHEMA_VERSION) {
        issues.push(issue("schema_version_unsupported",
          `事件檔標頭的 schemaVersion 為 ${schemaVersion ?? "缺漏"}，本讀取器只認得 ${SCHEMA_VERSION}`, { file, line }));
      }
      if (text(record, "epoch") === null) {
        issues.push(issue("header_epoch_missing", "事件檔標頭沒有 epoch", { file, line }));
      }
      return;
    }
    case "server.started": {
      const epoch = text(record, "epoch");
      const loadedSeq = integer(record, "loadedSeq");
      if (epoch === null || loadedSeq === null || loadedSeq < 0) {
        issues.push(issue("startup_record_invalid",
          "server.started 缺少可用的 epoch/loadedSeq，這次啟動無法佐證任何回滾點", { file, line }));
        return;
      }
      stream.startups.push({ epoch, loadedSeq, realmId });
      return;
    }
    case "epoch.rolledback": {
      const epoch = text(record, "crashedEpoch");
      const fromSeq = integer(record, "fromSeq");
      if (epoch === null || fromSeq === null || fromSeq < 1) {
        issues.push(issue("rollback_record_invalid",
          "epoch.rolledback 缺少可用的 crashedEpoch/fromSeq，無法據此判定回滾範圍", { file, line }));
        return;
      }
      stream.rollbacks.push({ epoch, fromSeq, realmId });
      return;
    }
    case "ledger.anomaly": {
      issues.push(issue("ledger_anomaly",
        `帳本異常紀錄 kind=${text(record, "kind") ?? "-"} resolution=${text(record, "resolution") ?? "-"}（由遊戲端寫下，需人工查核）`,
        { file, line }));
      return;
    }
    case "tx.committed": {
      const tx = parseTransaction(record, file, line, issues);
      if (tx === null) return;
      stream.transactions.push(tx);
      stream.realmOf.set(tx, realmId);
      return;
    }
    default:
      return;
  }
}

// ---------------------------------------------------------------- durability verdicts

interface EpochVerdict {
  /** Highest seq of this epoch that survived into a save; above it the epoch was rolled back. */
  cutoff: number | null;
  /** Highest seq of this epoch proven to be in the save that is on disk now. */
  durableTo: number | null;
  /** Proven by the journal order to have started after the saved epoch. */
  afterSave: boolean;
  /** Evidence contradicts itself: no verdict may be given. */
  unresolved: boolean;
}

interface Evidence {
  verdicts: Map<string, EpochVerdict>;
  epochOrder: string[] | null;
}

function resolveEvidence(
  stream: EventStream,
  foreign: Set<ReportTransaction>,
  history: EpochStart[],
  saved: Watermark | null,
  journal: Journal,
  realm: string | null,
  issues: ReportIssue[],
): Evidence {
  // The loadedSeq each epoch of this realm reported on its own start. This is what makes a
  // journal line trustworthy: the line and the event stream must say the same thing.
  const observed = new Map<string, number>();
  const contested = new Set<string>();
  for (const startup of stream.startups) {
    if (realm === null || startup.realmId !== realm) continue;
    const previous = observed.get(startup.epoch);
    if (previous === undefined) observed.set(startup.epoch, startup.loadedSeq);
    else if (previous !== startup.loadedSeq) contested.add(startup.epoch);
  }
  for (const epoch of contested) {
    issues.push(issue("startup_loaded_seq_conflict",
      `epoch ${epoch} 有兩筆 server.started 說出不同的 loadedSeq，這個 epoch 的啟動證據不予採用`));
  }
  const corroborated = (entry: EpochStart): boolean =>
    !contested.has(entry.epoch) && observed.get(entry.epoch) === entry.loadedSeq;

  // The journal is the only proof of epoch order, and it only counts when nothing in it was
  // damaged, every line it holds is confirmed by a same-realm server.started, and it holds a
  // line for every start we saw. A line that vanished would leave two unrelated epochs looking
  // adjacent - journal A,C while the stream shows A,B,C must never yield "A survived to C".
  let orderTrusted = journal.intact;
  if (!journal.intact) {
    issues.push(issue("epoch_order_unproven",
      "epochs.json 有損毀、未完成或讀取中被改寫的行：兩側的 epoch 不再可證明相鄰，整段啟動順序停用"));
  }
  const listed = new Set<string>();
  for (const entry of journal.entries) {
    listed.add(entry.epoch);
    if (corroborated(entry)) continue;
    orderTrusted = false;
    const seen = observed.get(entry.epoch);
    issues.push(issue("epoch_order_unproven",
      `epochs.json 的 ${entry.epoch} loadedSeq=${entry.loadedSeq} 沒有同 realm server.started 佐證`
      + `（事件流觀察到的是 ${contested.has(entry.epoch) ? "互相矛盾的值" : seen ?? "無"}），啟動順序不予採用`));
  }
  for (const epoch of observed.keys()) {
    if (listed.has(epoch)) continue;
    orderTrusted = false;
    issues.push(issue("epoch_order_unproven",
      `事件流觀察到 epoch ${epoch} 的 server.started，epochs.json 卻沒有這一行：可能整行遺失，`
      + "其餘行的相鄰關係不可信，啟動順序整段停用（存檔 history 與明確 epoch.rolledback 仍然有效）"));
  }
  const ordered = orderTrusted ? [...new Set(journal.entries.map((entry) => entry.epoch))] : [];
  const epochOrder = ordered.length > 0 ? ordered : null;

  // cutoff candidates: epoch -> value -> the sources that state it
  const cutoffs = new Map<string, Map<number, Set<string>>>();
  const addCutoff = (epoch: string, value: number, source: string): void => {
    let byValue = cutoffs.get(epoch);
    if (byValue === undefined) {
      byValue = new Map<number, Set<string>>();
      cutoffs.set(epoch, byValue);
    }
    const sources = byValue.get(value);
    if (sources === undefined) byValue.set(value, new Set([source]));
    else sources.add(source);
  };
  for (const entry of history) addCutoff(entry.epoch, entry.loadedSeq, "modData.history");
  for (const rollback of stream.rollbacks) {
    if (realm === null || rollback.realmId !== realm) continue;
    addCutoff(rollback.epoch, rollback.fromSeq - 1, "epoch.rolledback");
  }
  if (orderTrusted) {
    for (let i = 0; i + 1 < journal.entries.length; i++) {
      const current = journal.entries[i];
      const next = journal.entries[i + 1];
      if (current === undefined || next === undefined || current.epoch === next.epoch) continue;
      if (!corroborated(current) || !corroborated(next)) continue;
      // The next start loaded a save ending at its loadedSeq: the previous epoch survived to it.
      addCutoff(current.epoch, next.loadedSeq, "epochs.json");
    }
  }

  const savedRank = saved === null || epochOrder === null ? -1 : epochOrder.indexOf(saved.epoch);
  const verdicts = new Map<string, EpochVerdict>();
  for (const tx of stream.transactions) {
    if (foreign.has(tx) || verdicts.has(tx.epoch)) continue;
    const byValue = cutoffs.get(tx.epoch);
    const values = byValue === undefined ? [] : [...byValue.keys()];
    const durableTo = saved !== null && saved.epoch === tx.epoch ? saved.seq : null;
    const ownRank = epochOrder === null ? -1 : epochOrder.indexOf(tx.epoch);
    const afterSave = savedRank >= 0 && ownRank >= 0 && ownRank > savedRank;
    if (values.length > 1) {
      const detail = values.map((value) => `${value}(${[...(byValue?.get(value) ?? [])].join(",")})`).sort().join(" / ");
      issues.push(issue("epoch_cutoff_conflict",
        `epoch ${tx.epoch} 的回滾點有互相衝突的證據：${detail}；此 epoch 的交易一律標為無法判斷`));
      verdicts.set(tx.epoch, { cutoff: null, durableTo, afterSave, unresolved: true });
      continue;
    }
    const cutoff = values[0] ?? null;
    if (cutoff !== null && durableTo !== null && durableTo > cutoff) {
      issues.push(issue("epoch_evidence_conflict",
        `epoch ${tx.epoch} 的存檔水位 seq=${durableTo} 高於其回滾點 ${cutoff}，兩份證據矛盾；此 epoch 的交易一律標為無法判斷`));
      verdicts.set(tx.epoch, { cutoff: null, durableTo: null, afterSave, unresolved: true });
      continue;
    }
    if (cutoff === null && durableTo === null && !afterSave) {
      issues.push(issue("epoch_evidence_missing",
        `epoch ${tx.epoch} 不在存檔 meta/history 內，也沒有可信的回滾點或啟動順序證據：此 epoch 的交易只能標為無法判斷`));
    }
    verdicts.set(tx.epoch, { cutoff, durableTo, afterSave, unresolved: false });
  }
  return { verdicts, epochOrder };
}

function statusOf(verdict: EpochVerdict | undefined, seq: number): ReportStatus {
  if (verdict === undefined || verdict.unresolved) return "unknown";
  if (verdict.cutoff !== null) return seq <= verdict.cutoff ? "durable" : "rolled_back";
  if (verdict.durableTo !== null) return seq <= verdict.durableTo ? "durable" : "pending";
  if (verdict.afterSave) return "pending";
  return "unknown";
}

/**
 * seq is monotonic inside an epoch, so a group may always be ordered by it. Epoch groups are
 * reordered only when the caller passes a proven order covering every epoch present; otherwise
 * they keep the order they were physically recorded in, and nothing is inferred from timestamps.
 */
function inRecordOrder(transactions: ReportTransaction[], epochOrder: string[] | null): ReportTransaction[] {
  const groups = new Map<string, ReportTransaction[]>();
  for (const tx of transactions) {
    const group = groups.get(tx.epoch);
    if (group === undefined) groups.set(tx.epoch, [tx]);
    else group.push(tx);
  }
  const epochs = [...groups.keys()];
  if (epochOrder !== null) {
    epochs.sort((a, b) => epochOrder.indexOf(a) - epochOrder.indexOf(b));
  }
  const out: ReportTransaction[] = [];
  for (const epoch of epochs) {
    const group = groups.get(epoch);
    if (group === undefined) continue;
    group.sort((a, b) => a.seq - b.seq);
    for (const tx of group) out.push(tx);
  }
  return out;
}

// ---------------------------------------------------------------- entry point

export async function readReportSource(options: ReadReportSourceOptions): Promise<ReportSource> {
  const issues: ReportIssue[] = [];
  const files: { name: string; size: number }[] = [];

  // The save is read first on purpose: a save landing after this read can only make the verdicts
  // more conservative (pending instead of durable), never the other way round.
  const bin = await readBin(options, files, issues);
  const journal = readJournal(options.economyDir, files, issues);
  const stream = readEvents(options, files, issues);

  const watermark = bin === null ? null : bin.watermark;
  const realm = watermark?.realmId ?? (stream.realms.size === 1 ? [...stream.realms][0] ?? null : null);
  if (realm === null) {
    issues.push(issue("realm_undetermined", stream.realms.size > 1
      ? `事件流同時出現 ${stream.realms.size} 個 realmId 且沒有存檔可裁決，無法判定本報告屬於哪個世界`
      : "沒有任何可用的 realmId（存檔與事件流都沒提供），無法證明任何交易屬於本世界"));
  }
  for (const other of stream.realms) {
    if (realm !== null && other !== realm) {
      issues.push(issue("realm_mismatch", `事件流含有其他世界的紀錄（realmId=${other}，本報告為 ${realm}），該部分已全數排除`));
    }
  }
  // Without a realmId on the save, nothing proves it describes the same world as these events.
  const binUsable = watermark !== null && watermark.realmId !== null && watermark.realmId === realm;

  // Foreign or unattributable records can never be confirmed, whatever the save says.
  const foreign = new Set<ReportTransaction>();
  for (const tx of stream.transactions) {
    const claimed = stream.realmOf.get(tx) ?? null;
    if (realm !== null && claimed === realm) continue;
    foreign.add(tx);
    tx.valid = false;
    if (claimed !== null && realm !== null) {
      issues.push(issue("tx_foreign_realm", `此交易屬於其他世界（realmId=${claimed}），已排除於統計`,
        { file: tx.file, line: tx.line, txId: tx.txId }));
    }
  }

  const evidence = resolveEvidence(stream, foreign,
    binUsable && bin !== null ? bin.history : [], binUsable ? watermark : null,
    journal, realm, issues);
  for (const tx of stream.transactions) {
    if (!foreign.has(tx)) tx.status = statusOf(evidence.verdicts.get(tx.epoch), tx.seq);
  }

  // A txId is one transaction (EC.makeId = epoch:seq). Two lines carrying the same one are a
  // resend or a corruption: neither may be counted, and neither is dropped - both stay for the
  // diagnosis. Only this realm's records are compared, so a foreign line cannot make one of ours
  // look like a duplicate.
  const byTxId = new Map<string, ReportTransaction[]>();
  for (const tx of stream.transactions) {
    if (foreign.has(tx)) continue;
    const group = byTxId.get(tx.txId);
    if (group === undefined) byTxId.set(tx.txId, [tx]);
    else group.push(tx);
  }
  for (const [txId, group] of byTxId) {
    if (group.length < 2) continue;
    for (const tx of group) {
      tx.valid = false;
      issues.push(issue("duplicate_tx_id",
        `txId ${txId} 在紀錄中出現 ${group.length} 次（重送或損毀），全部排除於統計，不得當成多筆交易`,
        { file: tx.file, line: tx.line, txId }));
    }
  }

  // An identity that cannot be trusted cannot carry a durability verdict either.
  for (const tx of stream.transactions) {
    if (!tx.valid) tx.status = "unknown";
  }

  // An epoch the proven order does not cover means the records cannot be laid out in a proven
  // order at all. Publishing the order anyway would let a consumer treat the last row it walks
  // as the newest one, so the proof is withdrawn together with the sorting.
  const proven = evidence.epochOrder;
  const covers = proven !== null && stream.transactions.every((tx) => proven.includes(tx.epoch));
  if (proven !== null && !covers) {
    issues.push(issue("epoch_order_unproven",
      "有交易的 epoch 不在可信啟動順序內（未知或屬於其他世界），交易退回實體紀錄順序，"
      + "本次不輸出 epochOrder：跨 epoch 的先後一律視為未證明"));
  }
  const epochOrder = covers ? proven : null;

  // The same trust boundary as durability: a snapshot that cannot be proven to describe this
  // world is not handed out for reconciliation either.
  if (bin !== null && !binUsable) {
    issues.push(issue("snapshot_unprovable",
      "存檔快照無法證明屬於本世界，本次不輸出其水位與錢包快照，不得用於對帳", { file: path.basename(options.modDataBin) }));
  }

  const source: ReportSource = {
    asOf: Date.now(),
    realmId: realm,
    watermark: binUsable ? watermark : null,
    transactions: inRecordOrder(stream.transactions, epochOrder),
    issues,
    files,
    wallets: binUsable && bin !== null ? bin.wallets : new Map(),
  };
  if (epochOrder !== null) source.epochOrder = epochOrder;
  return source;
}
