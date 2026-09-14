// Daily read-only reconciliation: turns one ReportSource read into one DailyReport.
//
// Pure. No I/O, no clock (generatedAt is the source's own asOf), and `source` is never written
// to: the transaction objects are carried into the report by reference.
//
// Division of labour. ReportData owns every judgement about a single record - shape, posting
// arithmetic, per currency balance, number safety, identity (txId against epoch:seq, repeated
// txId) - and publishes it as `valid`, leaving an unusable record at status "unknown". Nothing
// here re-judges any of that. This module owns only what one record cannot show:
//   * the balance chain across transactions: each wallet's `before` against the previous
//     confirmed posting's `after`, both buckets (ledger.anomaly chain_gap);
//   * the confirmed tail of the wallets that moved today against the ModData snapshot read
//     with them, and only where that comparison is possible at all;
//   * requestId clues, which are clues and never a verdict;
//   * the day's money, counted only from valid durable transactions.
//
// Order across epochs comes from source.epochOrder and nowhere else: a file name is a day, not
// a sequence, and a backwards clock or a missing middle day would forge one. Inside one epoch
// order comes from seq. Whatever cannot be ordered cannot produce a definite finding.
//
// Everything the source could not show lands in coverage.issues or limits. Absence is never
// read as zero, and "the snapshot does not have it" is not the same as "it is not there".
import type { Watermark } from "./bin.ts";
import { isSystemAccount, walletKey, type ReportIssue, type ReportPosting, type ReportSource, type ReportStatus, type ReportTransaction } from "./report-data.ts";

/**
 * Money moved in one currency on one day, seen from the player (non system) side; the system
 * accounts are its exact mirror. A money field is null when the exact sum cannot be carried by
 * a JSON number - the report says so instead of printing a rounded figure.
 */
export interface CurrencyTotal {
  currency: string;
  /** Counted transactions with at least one posting in this currency. */
  transactions: number;
  /** Posting flow into player wallets, both buckets. Flow, not revenue: a bid reserve shows up
   *  in grossIn and grossOut alike, and a player to player trade counts the same coins twice. */
  grossIn: number | null;
  /** Posting flow out of player wallets, absolute value. */
  grossOut: number | null;
  /** Net change of the players' spendable bucket. */
  availableDelta: number | null;
  /** Net change of the players' reserved bucket. */
  reservedDelta: number | null;
  /** Sum of the per transaction increases of total player holdings: new money. Moving money
   *  between the buckets of one wallet changes no holding, so it contributes 0. */
  issued: number | null;
  /** Sum of the per transaction decreases of total player holdings: money retired. */
  retired: number | null;
}

export interface DailyReport {
  schemaVersion: 1;
  /** Calendar day in `timeZone`, as handed in. */
  date: string;
  timeZone: string;
  /** Half open [fromMs, toMs). */
  period: { fromMs: number; toMs: number };
  /** The moment the source was read: the report is a function of that read alone. */
  generatedAt: number;
  realmId: string | null;
  watermark: Watermark | null;
  /** `complete` is true only when nothing was found that the source could not show. It is not
   *  a statement that the ledger is correct, and never a verdict on cheating. */
  coverage: { complete: boolean; issues: ReportIssue[]; files: string[] };
  statusCounts: Record<ReportStatus, number>;
  totals: CurrencyTotal[];
  transactions: ReportTransaction[];
  /** What was seen and looks wrong. What could not be seen is in coverage.issues. */
  issues: ReportIssue[];
  /** What this report does and does not claim, in the report's own language. */
  limits: string[];
}

export interface DailyReportOptions {
  date: string;
  timeZone: string;
  fromMs: number;
  toMs: number;
}


const DAY_MS = 86400000;


function txIssue(
  tx: ReportTransaction,
  code: string,
  message: string,
  account?: string,
  currency?: string,
): ReportIssue {
  return { code, message, file: tx.file, line: tx.line, txId: tx.txId, account, currency };
}

/**
 * Is `from` known to come no later than `to`? Only source.epochOrder can say so: it holds the
 * startup order that could be proved, and an epoch it does not name has no proven place at all.
 */
function orderProven(order: string[] | undefined, from: string, to: string): boolean {
  if (from === to) return true;
  if (order === undefined) return false;
  const a = order.indexOf(from);
  const b = order.indexOf(to);
  return a >= 0 && b >= 0 && a <= b;
}

/** The confirmed state a wallet was last left in, and where in the ledger that was. */
interface Anchor {
  account: string;
  currency: string;
  epoch: string;
  seq: number;
  available: bigint;
  reserved: bigint;
  txId: string;
  file: string;
  line: number;
}

/** Where an issue goes, or null when the transaction is outside the reported day. */
interface Sink {
  /** Seen and wrong. */
  issues: ReportIssue[];
  /** Could not be seen, or could not be judged. */
  coverage: ReportIssue[];
}

interface Chain {
  /** walletKey -> last confirmed posting. */
  anchors: Map<string, Anchor>;
  /** walletKey moved by a transaction that is not confirmed, since its last confirmed one. */
  unproven: Set<string>;
  /** walletKey that moved inside the reported day. */
  touched: Set<string>;
  order: string[] | undefined;
}

interface Acc {
  currency: string;
  transactions: number;
  grossIn: bigint;
  grossOut: bigint;
  availableDelta: bigint;
  reservedDelta: bigint;
  issued: bigint;
  retired: bigint;
}

function accFor(totals: Map<string, Acc>, currency: string): Acc {
  let acc = totals.get(currency);
  if (acc === undefined) {
    acc = {
      currency, transactions: 0, grossIn: 0n, grossOut: 0n,
      availableDelta: 0n, reservedDelta: 0n, issued: 0n, retired: 0n,
    };
    totals.set(currency, acc);
  }
  return acc;
}

/** What one transaction did to one wallet: where it started and where it left it. */
interface Move {
  account: string;
  currency: string;
  first: ReportPosting;
  last: ReportPosting;
}

/**
 * One entry per wallet the transaction touched, in the order the postings appear. A wallet may
 * carry two postings (the available and reserved legs of a reserve or a release); the ledger
 * applies them in that order, so the first `before` and the last `after` are this
 * transaction's opening and closing state for that wallet.
 */
function walletMoves(tx: ReportTransaction): Move[] {
  const moves = new Map<string, Move>();
  for (const p of tx.postings) {
    const key = walletKey(p.account, p.currency);
    const move = moves.get(key);
    if (move === undefined) moves.set(key, { account: p.account, currency: p.currency, first: p, last: p });
    else move.last = p;
  }
  return [...moves.values()];
}

/**
 * Continues each touched wallet's balance chain. Only confirmed transactions anchor it: a
 * rolled back run lived in a timeline the save discarded, and a pending or unknown one is not
 * proven - so neither may anchor the chain, and neither may break it either. A posting that
 * disagrees with the anchor is reported once and then becomes the new anchor, so one real
 * break does not cascade into a break per later transaction.
 */
function chainTransaction(tx: ReportTransaction, chain: Chain, sink: Sink | null, inDay: boolean): void {
  const confirmed = tx.status === "durable" && tx.valid;
  for (const move of walletMoves(tx)) {
    const wallet = walletKey(move.account, move.currency);
    if (inDay) chain.touched.add(wallet);
    if (!confirmed) {
      // Not proven to be in the save. It is not chained, and it is remembered: a later
      // difference on this wallet may be exactly this transaction, so it cannot be called a
      // break. A rolled back transaction is proven absent and leaves the chain untouched.
      if (tx.status !== "rolled_back") chain.unproven.add(wallet);
      continue;
    }

    const prev = chain.anchors.get(wallet);
    if (prev !== undefined && isOlderThanAnchor(tx, prev, chain.order)) {
      // Records arrive in file order, which a backwards clock can put out of ledger order.
      // Reading this as the wallet's newer state would both invent a break and leave a stale
      // anchor behind, so it is stated and skipped.
      sink?.coverage.push(txIssue(
        tx,
        "chain_out_of_order",
        `到達順序與帳本順序不一致：本交易（epoch=${tx.epoch} seq=${tx.seq}）排在已確認的 `
        + `txId=${prev.txId}（${prev.file}:${prev.line}，epoch=${prev.epoch} seq=${prev.seq}）之後，`
        + `但帳本順序在它之前，這筆不納入餘額鏈`,
        move.account,
        move.currency,
      ));
      continue;
    }

    const fromAvailable = BigInt(move.first.availableBefore);
    const fromReserved = BigInt(move.first.reservedBefore);
    if (prev === undefined) {
      // Nothing before it in the source: the transaction's own `before` is the only opening
      // evidence there is. A non-zero opening with no history behind it is said out loud,
      // never assumed to be zero.
      if (fromAvailable !== 0n || fromReserved !== 0n) {
        sink?.coverage.push(txIssue(
          tx,
          "opening_unverified",
          `期初餘額無法驗證：${move.account} 的 ${move.currency} 在來源裡第一次出現就已有餘額`
          + `（available=${move.first.availableBefore} reserved=${move.first.reservedBefore}），`
          + `前一筆已確認分錄不在讀取範圍內`,
          move.account,
          move.currency,
        ));
      }
    } else if (prev.available !== fromAvailable || prev.reserved !== fromReserved) {
      const detail = `前一筆已確認分錄 txId=${prev.txId}（${prev.file}:${prev.line}，epoch=${prev.epoch} seq=${prev.seq}）`
        + `結束於 available=${prev.available} reserved=${prev.reserved}，`
        + `本交易卻從 available=${move.first.availableBefore} reserved=${move.first.reservedBefore} 起算`;
      if (chain.unproven.has(wallet)) {
        sink?.coverage.push(txIssue(
          tx,
          "chain_gap_unverifiable",
          `餘額鏈落差無法判定：${detail}；其間有未確認或無證據的交易，差額可能就是它們`,
          move.account,
          move.currency,
        ));
      } else if (!orderProven(chain.order, prev.epoch, tx.epoch)) {
        sink?.coverage.push(txIssue(
          tx,
          "chain_gap_unordered",
          `餘額鏈落差無法判定：${detail}；epoch ${prev.epoch} 與 ${tx.epoch} 的先後沒有可信證據，無法斷定哪一邊在前`,
          move.account,
          move.currency,
        ));
      } else {
        sink?.issues.push(txIssue(tx, "chain_gap", `餘額鏈斷裂：${detail}`, move.account, move.currency));
      }
    }

    chain.anchors.set(wallet, {
      account: move.account, currency: move.currency, epoch: tx.epoch, seq: tx.seq,
      available: BigInt(move.last.availableAfter), reserved: BigInt(move.last.reservedAfter),
      txId: tx.txId, file: tx.file, line: tx.line,
    });
    chain.unproven.delete(wallet);
  }
}

/**
 * Does this transaction sit before the wallet's current anchor in the ledger's own order? Only
 * a proven order can say so: inside one epoch seq decides (it never decreases as the ledger
 * appends), across epochs only source.epochOrder does.
 */
function isOlderThanAnchor(tx: ReportTransaction, anchor: Anchor, order: string[] | undefined): boolean {
  if (tx.epoch === anchor.epoch) return tx.seq < anchor.seq;
  return orderProven(order, tx.epoch, anchor.epoch);
}

/** The player side money of one counted transaction, per currency. */
function accumulate(totals: Map<string, Acc>, tx: ReportTransaction): void {
  const moved = new Map<string, { grossIn: bigint; grossOut: bigint; available: bigint; reserved: bigint }>();
  const touched = new Set<string>();
  for (const p of tx.postings) {
    touched.add(p.currency);
    if (isSystemAccount(p.account)) continue;
    let m = moved.get(p.currency);
    if (m === undefined) {
      m = { grossIn: 0n, grossOut: 0n, available: 0n, reserved: 0n };
      moved.set(p.currency, m);
    }
    const amount = BigInt(p.amount);
    if (amount > 0n) m.grossIn += amount;
    else m.grossOut -= amount;
    if (p.bucket === "reserved") m.reserved += amount;
    else m.available += amount;
  }
  for (const currency of touched) {
    const acc = accFor(totals, currency);
    acc.transactions += 1;
    const m = moved.get(currency);
    if (m === undefined) continue;        // only system accounts moved in this currency
    acc.grossIn += m.grossIn;
    acc.grossOut += m.grossOut;
    acc.availableDelta += m.available;
    acc.reservedDelta += m.reserved;
    const net = m.available + m.reserved;
    if (net > 0n) acc.issued += net;
    else if (net < 0n) acc.retired -= net;
  }
}

/** A sum past 2^53 is reported as unavailable, never as a rounded figure. */
function money(value: bigint, label: string, currency: string, issues: ReportIssue[]): number | null {
  const n = Number(value);
  if (Number.isSafeInteger(n)) return n;
  issues.push({
    code: "precision_loss",
    message: `${currency} 的 ${label} 合計為 ${value.toString()}，超出 JSON number 可精確表示的範圍，輸出為 null`,
    currency,
  });
  return null;
}

/** Player accounts of one transaction, sorted: the business identity a requestId alone is not. */
function playerAccounts(tx: ReportTransaction): string {
  const names = new Set<string>();
  for (const p of tx.postings) {
    if (!isSystemAccount(p.account)) names.add(p.account);
  }
  return JSON.stringify([...names].sort());
}

/** The exact player side effect, sorted: two identical ones are one operation done twice. */
function playerEffect(tx: ReportTransaction): string {
  const parts: string[] = [];
  for (const p of tx.postings) {
    if (!isSystemAccount(p.account)) parts.push(JSON.stringify([p.account, p.currency, p.bucket, p.amount]));
  }
  return JSON.stringify(parts.sort());
}

/**
 * requestId clues. A requestId is named by whichever caller built it, so the string alone is
 * not proof of one operation: a group whose player accounts differ is reported as a possible
 * collision, not as a duplicate payment. A rolled back transaction and its replay legitimately
 * share a requestId (the idempotency record died with the rollback), so they are left out.
 * Nothing here is a verdict; every line asks for a human check against the business source.
 */
function requestIdClues(
  source: ReportSource,
  inDay: (tx: ReportTransaction) => boolean,
  issues: ReportIssue[],
): void {
  const groups = new Map<string, ReportTransaction[]>();
  for (const tx of source.transactions) {
    if (tx.requestId === undefined || tx.requestId === "") continue;
    if (!tx.valid) continue;
    if (tx.status !== "durable" && tx.status !== "pending") continue;
    const group = groups.get(tx.requestId);
    if (group === undefined) groups.set(tx.requestId, [tx]);
    else group.push(tx);
  }
  for (const [requestId, group] of groups) {
    if (group.length < 2) continue;
    const here = group.find(inDay);
    if (here === undefined) continue;
    const where = group
      .map((t) => `txId=${t.txId} epoch=${t.epoch} seq=${t.seq} ${t.kind} (${t.file}:${t.line})`)
      .join("；");
    if (new Set(group.map(playerAccounts)).size > 1) {
      issues.push(txIssue(
        here,
        "request_id_collision",
        `requestId 撞名線索：${requestId} 出現在帳戶不同的多筆交易上。requestId 由各呼叫端自行命名，`
        + `這比較可能是不同操作而不是重複付款，需人工以業務來源確認。相關交易：${where}`,
      ));
    } else if (new Set(group.map(playerEffect)).size === 1) {
      issues.push(txIssue(
        here,
        "duplicate_request_id",
        `可能重複執行線索：${requestId} 對同一帳戶產生完全相同的分錄卻有不同 txId，`
        + `可能是冪等視窗淘汰後重送，跨 epoch 則另可能是回滾後重做，需人工以業務來源確認。相關交易：${where}`,
      ));
    } else {
      issues.push(txIssue(
        here,
        "request_id_reused",
        `requestId 重用線索：${requestId} 在同一帳戶上對應到不同的操作，需人工確認哪一筆才是預期的。`
        + `相關交易：${where}`,
      ));
    }
  }
}

/**
 * Can this wallet's confirmed tail be compared with the snapshot at all? Returns null when it
 * can, otherwise why not. The snapshot is the state at the watermark, and a transaction can be
 * confirmed by startup evidence read after that .bin: same epoch with a higher seq means the
 * snapshot is simply older than the anchor, not that money is missing.
 */
function uncomparable(chain: Chain, wallet: string, anchor: Anchor, watermark: Watermark): string | null {
  if (chain.unproven.has(wallet)) return "其後有未確認或無證據的交易，差額可能就是它們";
  if (anchor.epoch === watermark.epoch) {
    if (anchor.seq <= watermark.seq) return null;
    return `這份存檔停在 ${watermark.epoch}:${watermark.seq}，最後一筆已確認分錄卻是 ${anchor.epoch}:${anchor.seq}`
      + "：它是靠之後的啟動證據才被確認的，本來就還沒寫進這份存檔";
  }
  if (!orderProven(chain.order, anchor.epoch, watermark.epoch)) {
    return `epoch ${anchor.epoch} 與水位 epoch ${watermark.epoch} 的先後沒有可信證據`;
  }
  return null;
}

/**
 * The confirmed tail of the wallets that moved today against the wallet snapshot read from the
 * same .bin. Wallets that did not move today are not this day's business and are left alone.
 * A missing wallet and a different amount take the same path: both are only called a finding
 * when the comparison is possible, and both are downgraded by the same rule when it is not -
 * a wallet created after this .bin was written is absent from it for a good reason.
 */
function reconcileSnapshot(source: ReportSource, chain: Chain, sink: Sink): void {
  const watermark = source.watermark;
  if (watermark === null || source.wallets.size === 0) {
    sink.coverage.push({
      code: "snapshot_unavailable",
      message: watermark === null
        ? "沒有存檔水位可用，未執行「最後一筆已確認餘額 vs 存檔快照」對帳"
        : "存檔沒有可讀的錢包快照，未執行「最後一筆已確認餘額 vs 存檔快照」對帳",
    });
    return;
  }
  if (watermark.realmId === null || source.realmId === null || watermark.realmId !== source.realmId) {
    // A snapshot that cannot be shown to belong to this realm can disagree with this realm's
    // ledger for entirely innocent reasons.
    sink.coverage.push({
      code: "snapshot_realm_unproven",
      message: `無法證明存檔快照屬於這個 realm（存檔 realmId=${watermark.realmId ?? "無"}、`
        + `事件流 realmId=${source.realmId ?? "無"}），未執行餘額對帳`,
    });
    return;
  }
  for (const wallet of chain.touched) {
    const anchor = chain.anchors.get(wallet);
    if (anchor === undefined) continue;     // moved today, but never by a confirmed transaction
    const snap = source.wallets.get(anchor.account)?.get(anchor.currency);
    let detail: string;
    if (snap === undefined) {
      if (anchor.available === 0n && anchor.reserved === 0n) continue;
      detail = `存檔快照裡沒有這個錢包，但最後一筆已確認分錄留下 available=${anchor.available} reserved=${anchor.reserved}`;
    } else {
      const available = BigInt(snap.available);
      const reserved = BigInt(snap.reserved);
      if (available === anchor.available && reserved === anchor.reserved) continue;
      detail = `最後一筆已確認分錄結束於 available=${anchor.available} reserved=${anchor.reserved}，`
        + `存檔快照為 available=${available} reserved=${reserved}`;
    }
    const at = {
      file: anchor.file, line: anchor.line, txId: anchor.txId,
      account: anchor.account, currency: anchor.currency,
    };
    const why = uncomparable(chain, wallet, anchor, watermark);
    if (why !== null) {
      sink.coverage.push({
        ...at,
        code: "snapshot_mismatch_unverifiable",
        message: `餘額與存檔快照不同但無法判定：${detail}；${why}`,
      });
    } else {
      sink.issues.push({
        ...at,
        code: snap === undefined ? "snapshot_missing_wallet" : "snapshot_mismatch",
        message: `餘額與存檔快照不符：${detail}（可能是事件檔有缺，也可能是繞過帳本的改動，需人工確認）`,
      });
    }
  }
}

/**
 * Every day file the period can touch. ECExport names them by the server's own day key, so a
 * report day in another time zone reaches into the neighbouring day: all of them are required,
 * and a missing one is a gap, never a day without transactions.
 */
function missingDayFiles(source: ReportSource, fromMs: number, toMs: number): string[] {
  if (!Number.isFinite(fromMs) || !Number.isFinite(toMs) || toMs <= fromMs) return [];
  const have = new Set(source.files.map((f) => f.name));
  const missing: string[] = [];
  for (let t = Math.floor(fromMs / DAY_MS) * DAY_MS; t < toMs; t += DAY_MS) {
    const name = `events-${new Date(t).toISOString().slice(0, 10).replaceAll("-", "")}.json`;
    if (!have.has(name)) missing.push(name);
  }
  return missing;
}

/**
 * Builds the day's report from one source read. Pure: the same source and the same options
 * always give the same report.
 */
export function buildDailyReport(source: ReportSource, options: DailyReportOptions): DailyReport {
  const { date, timeZone, fromMs, toMs } = options;
  const issues: ReportIssue[] = [];
  const coverage: ReportIssue[] = [...source.issues];
  const sink: Sink = { issues, coverage };
  const limits: string[] = [];

  const inDay = (tx: ReportTransaction): boolean =>
    Number.isFinite(tx.ts) && tx.ts >= fromMs && tx.ts < toMs;

  const chain: Chain = {
    anchors: new Map(), unproven: new Set(), touched: new Set(), order: source.epochOrder,
  };
  const statusCounts: Record<ReportStatus, number> = { durable: 0, rolled_back: 0, pending: 0, unknown: 0 };
  const transactions: ReportTransaction[] = [];
  const totals = new Map<string, Acc>();

  // One walk over everything the source read, in its arrival order, so a chain that crosses
  // midnight is anchored on the previous confirmed posting even when that posting belongs to
  // another day. Findings are recorded only for transactions inside this day: the rest are
  // another day's report to make.
  for (const tx of source.transactions) {
    const today = inDay(tx);
    chainTransaction(tx, chain, today ? sink : null, today);
    if (!Number.isFinite(tx.ts)) {
      coverage.push(txIssue(tx, "ts_unusable", `交易時間戳無法使用（ts=${tx.ts}），這筆交易不會被歸入任何一天的日報`));
      continue;
    }
    if (!today) continue;
    transactions.push(tx);
    statusCounts[tx.status] += 1;
    if (tx.valid && tx.status === "durable") accumulate(totals, tx);
  }

  requestIdClues(source, inDay, issues);
  reconcileSnapshot(source, chain, sink);

  for (const name of missingDayFiles(source, fromMs, toMs)) {
    coverage.push({
      code: "day_file_missing",
      message: `來源沒有讀到 ${name}：這段期間會用到的事件檔缺漏，不能當成「這段時間沒有交易」`,
      file: name,
    });
  }
  if (toMs > source.asOf) {
    coverage.push({
      code: "period_incomplete",
      message: `報表期間到 ${toMs} 為止，但來源只觀察到 ${source.asOf}，這一天還沒有被完整讀到`,
    });
  }
  if (statusCounts.pending > 0) {
    coverage.push({
      code: "status_pending",
      message: `有 ${statusCounts.pending} 筆交易還沒有被證明寫入存檔（pending）；若之後發生崩潰，它們可能被回滾`,
    });
  }
  if (statusCounts.unknown > 0) {
    coverage.push({
      code: "status_unknown",
      message: `有 ${statusCounts.unknown} 筆交易無法證明是否已寫入存檔（unknown：epoch 沒有可佐證的證據，或來源判定這筆紀錄不可採信）`,
    });
  }
  if (statusCounts.rolled_back > 0) {
    limits.push(
      `本日有 ${statusCounts.rolled_back} 筆交易已確認被回滾，不計入金額合計，也不參與已確認餘額鏈；這是崩潰後的正常結果，不是斷鏈。`,
    );
  }

  const out: CurrencyTotal[] = [];
  const sorted = [...totals.values()].sort((a, b) => (a.currency < b.currency ? -1 : a.currency > b.currency ? 1 : 0));
  for (const acc of sorted) {
    out.push({
      currency: acc.currency,
      transactions: acc.transactions,
      grossIn: money(acc.grossIn, "grossIn", acc.currency, issues),
      grossOut: money(acc.grossOut, "grossOut", acc.currency, issues),
      availableDelta: money(acc.availableDelta, "availableDelta", acc.currency, issues),
      reservedDelta: money(acc.reservedDelta, "reservedDelta", acc.currency, issues),
      issued: money(acc.issued, "issued", acc.currency, issues),
      retired: money(acc.retired, "retired", acc.currency, issues),
    });
  }

  limits.push(
    "這份日報只核對「單筆紀錄看不出來」的事：跨交易的錢包餘額鏈（available 與 reserved 兩個 bucket 都算）、本日有異動的錢包最後餘額與存檔快照是否相符、requestId 線索，以及當日金額合計。單筆紀錄本身的格式、算式、平衡、數值安全與身分由來源負責，這裡完全採信它的 valid 判定，不做第二次裁決。",
    "coverage.complete 為 true 只表示沒有發現來源看不到的缺口，不代表帳本正確，也不是任何作弊與否的認定。",
    "金額一律從玩家（非系統）帳戶側觀察，系統帳戶是它的鏡像且餘額允許為負。grossIn／grossOut 是玩家側的分錄流量而不是營收：保留款移轉與玩家之間的交易會讓同一筆錢重複計入；issued／retired 是每筆交易玩家持有總額的淨增／淨減，同一錢包內的保留款移轉為 0。",
    "金額欄位為 null 代表精確值超出 JSON number 能表示的範圍，報表拒絕輸出四捨五入後的數字，實際值見同一份報表的 precision_loss 訊息。",
    "只有 status=durable 且 valid=true 的交易進入金額合計與已確認餘額鏈；pending／unknown／rolled_back 不當錨點，也不會被當成斷鏈。",
    "順序只採信可證明的：同一個 epoch 內看 seq，跨 epoch 只看 source.epochOrder。無法證明先後時，餘額鏈落差與快照差額一律降級為「無法判定」，不會報成確定的斷鏈或不符。",
    "快照對帳必須先可比才會下定論：存檔要能證明與事件流屬於同一個 realm、水位要已涵蓋該錢包最後一筆已確認分錄（同 epoch 比 seq、跨 epoch 比 epochOrder），且其後沒有未確認交易。任一條不成立就只報「無法判定」；「存檔快照裡沒有這個錢包」與「金額不同」走同一套降級，比這份存檔更晚才出現的錢包不會被說成存檔少了錢包。",
    "沒有前一筆已確認分錄可當錨點時，期初餘額只採用事件自述的 before，既不假設為 0 也不代為推算；這種情況列在 coverage.issues 的 opening_unverified。",
    "requestId 重複一律只當線索：requestId 由各呼叫端自行命名，不同帳戶撞名是可能的，是否真的重複付款要以業務來源人工佐證。",
    "本報表不偵測繞過帳本的改動：外部備份還原、直接改存檔或 ModData 都不會產生事件，只有在餘額鏈或存檔快照對帳出現落差時才可能顯現；報表也不會自動修正任何金額。",
  );

  return {
    schemaVersion: 1,
    date,
    timeZone,
    period: { fromMs, toMs },
    generatedAt: source.asOf,
    realmId: source.realmId,
    watermark: source.watermark,
    coverage: { complete: coverage.length === 0, issues: coverage, files: source.files.map((f) => f.name) },
    statusCounts,
    totals: out,
    transactions,
    issues,
    limits,
  };
}
