// Tails {economyDir}/events-YYYYMMDD.json (NDJSON written by ECExport.lua) and keeps an
// in-memory projection with a persisted checkpoint.
//
// Identity: every line carries {epoch, seq}. seq is monotonic inside an epoch and restarts from
// loadedSeq after a rollback, so (epoch, seq) is NOT unique across event types (server.started,
// ledger.anomaly and tx.committed may share a seq). Cursors handed to Watchcord are therefore the
// companion's own arrival index, persisted in the checkpoint so they survive companion restarts.
//
// Durability (spec 4.2):
//   * current epoch: durable iff the parsed .bin watermark has the same epoch and seq >= ev.seq;
//   * superseded epoch: a later server.started{epoch E2, loadedSeq L} marks every event of the
//     immediately preceding epoch with seq > L as rolled_back; the rest survived into the save
//     the new epoch loaded from, hence durable.
import fs from "node:fs";
import path from "node:path";
import type { Watermark } from "./bin.ts";

export interface Logger {
  info(message: string): void;
  warn(message: string): void;
  error(message: string): void;
}

/** One NDJSON line as ingested. Fields beyond the identity are whatever ECExport wrote. */
export interface LedgerEvent {
  type: string;
  epoch?: string;
  seq?: number;
  ts?: number;
  realmId?: string;
  loadedSeq?: number;
  txId?: string;
  /** Marked when a later epoch loaded a save that predates this event. */
  rolledBack: boolean;
  /** Arrival index: the cursor unit handed to Watchcord. */
  _idx: number;
  [field: string]: unknown;
}

export interface LedgerEntry extends Omit<LedgerEvent, "_idx"> {
  cursor: string;
  durable: boolean;
}

export interface LedgerPage {
  events: LedgerEntry[];
  next: string | null;
  exhausted: boolean;
}

export interface EventStoreOptions {
  economyDir: string;
  stateDir: string;
  maxEvents?: number;
  log?: Logger;
}

interface Checkpoint {
  file: string;
  offset: number;
  nextIndex: number;
  currentEpoch: string | null;
  loadedSeq: number;
  realmId: string | null;
}

const EVENT_FILE = /^events-(\d{8})\.json$/;

/** `err.code` of a Node system error, when there is one. */
export function errorCode(err: unknown): string | undefined {
  if (typeof err === "object" && err !== null && "code" in err && typeof err.code === "string") return err.code;
  return undefined;
}

export function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

/** A parsed NDJSON line before the companion adds its own bookkeeping. */
interface RawEvent {
  type: string;
  [field: string]: unknown;
}

function isRawEvent(v: unknown): v is RawEvent {
  return typeof v === "object" && v !== null && "type" in v && typeof v.type === "string";
}

function isCheckpoint(v: unknown): v is Checkpoint {
  return typeof v === "object" && v !== null
    && "file" in v && typeof v.file === "string"
    && "offset" in v && Number.isInteger(v.offset)
    && "nextIndex" in v && Number.isInteger(v.nextIndex);
}

export class EventStore {
  readonly economyDir: string;
  readonly stateDir: string;
  readonly maxEvents: number;
  readonly log: Logger;
  readonly checkpointPath: string;
  /** Arrival order; each carries _idx. */
  events: LedgerEvent[] = [];
  /** Events evicted from memory (oldest). */
  dropped = 0;
  nextIndex = 0;
  /** Current file name. */
  file: string | null = null;
  /** Bytes consumed in the current file. */
  offset = 0;
  currentEpoch: string | null = null;
  loadedSeq = 0;
  realmId: string | null = null;
  /** Watermark parsed from the .bin. */
  durable: Watermark | null = null;
  lastEventTs: number | null = null;
  parseErrors = 0;

  constructor({ economyDir, stateDir, maxEvents = 200000, log = console }: EventStoreOptions) {
    this.economyDir = economyDir;
    this.stateDir = stateDir;
    this.maxEvents = maxEvents;
    this.log = log;
    this.checkpointPath = path.join(stateDir, "checkpoint.json");
  }

  loadCheckpoint(): void {
    try {
      const cp: unknown = JSON.parse(fs.readFileSync(this.checkpointPath, "utf8"));
      if (isCheckpoint(cp)) {
        this.file = cp.file;
        this.offset = cp.offset;
        this.nextIndex = cp.nextIndex;
        this.currentEpoch = cp.currentEpoch ?? null;
        this.loadedSeq = cp.loadedSeq ?? 0;
        this.realmId = cp.realmId ?? null;
      }
    } catch (err) {
      if (errorCode(err) !== "ENOENT") this.log.warn(`checkpoint unreadable, starting from scratch: ${errorMessage(err)}`);
    }
  }

  saveCheckpoint(): void {
    fs.mkdirSync(this.stateDir, { recursive: true });
    const tmp = this.checkpointPath + ".tmp";
    const cp: Checkpoint = {
      file: this.file ?? "", offset: this.offset, nextIndex: this.nextIndex,
      currentEpoch: this.currentEpoch, loadedSeq: this.loadedSeq, realmId: this.realmId,
    };
    fs.writeFileSync(tmp, JSON.stringify(cp));
    fs.renameSync(tmp, this.checkpointPath);
  }

  listFiles(): string[] {
    let names: string[];
    try {
      names = fs.readdirSync(this.economyDir);
    } catch (err) {
      if (errorCode(err) === "ENOENT") return [];
      throw err;
    }
    return names.filter((n) => EVENT_FILE.test(n)).sort();
  }

  /** Reads everything new. Returns the number of events ingested. */
  poll(): number {
    const files = this.listFiles();
    const oldest = files[0];
    if (oldest === undefined) return 0;
    const checkpointed = this.file;
    let idx = checkpointed === null ? -1 : files.indexOf(checkpointed);
    if (idx < 0) {
      // Fresh start: oldest file. Checkpointed file rotated away: first file newer than it.
      idx = checkpointed === null ? 0 : Math.max(0, files.findIndex((f) => f > checkpointed));
      this.file = files[idx] ?? oldest;
      this.offset = 0;
    }
    let ingested = 0;
    for (;;) {
      ingested += this.readCurrentFile();
      const next = files[idx + 1];
      if (next === undefined) break;
      // A newer day file exists: the current one is complete (read to EOF above); move on.
      idx++;
      this.file = next;
      this.offset = 0;
    }
    if (ingested > 0) this.saveCheckpoint();
    return ingested;
  }

  private readCurrentFile(): number {
    if (this.file === null) return 0;
    const full = path.join(this.economyDir, this.file);
    let fd: number;
    try {
      fd = fs.openSync(full, "r");
    } catch (err) {
      if (errorCode(err) === "ENOENT") return 0;
      throw err;
    }
    let count = 0;
    try {
      const size = fs.fstatSync(fd).size;
      if (size < this.offset) {
        // Files are append-only; a shrink means it was replaced. Re-read from the start.
        this.log.warn(`${this.file} shrank from ${this.offset} to ${size}; re-reading`);
        this.offset = 0;
      }
      if (size === this.offset) return 0;
      const buf = Buffer.alloc(size - this.offset);
      const n = fs.readSync(fd, buf, 0, buf.length, this.offset);
      // Consume only up to the last newline; an unterminated tail is re-read next poll
      // (the writer closes after writeln, so this is rare and short-lived).
      const lastNl = buf.lastIndexOf(0x0a, n - 1);
      if (lastNl < 0) return 0;
      const text = buf.toString("utf8", 0, lastNl);
      for (const raw of text.split("\n")) {
        const line = raw.endsWith("\r") ? raw.slice(0, -1) : raw;
        if (line.trim() === "") continue;
        this.ingestLine(line);
        count++;
      }
      this.offset += lastNl + 1;
    } finally {
      fs.closeSync(fd);
    }
    return count;
  }

  private ingestLine(line: string): void {
    let parsed: unknown;
    try {
      parsed = JSON.parse(line);
    } catch {
      this.parseErrors++;
      this.log.warn(`unparseable line in ${this.file}: ${line.slice(0, 120)}`);
      return;
    }
    if (!isRawEvent(parsed)) {
      this.parseErrors++;
      return;
    }
    if (typeof parsed.ts === "number") this.lastEventTs = parsed.ts;
    if (parsed.type === "file.header") {
      // Marker only; not exposed through the ledger and does not consume a cursor index.
      if (typeof parsed.realmId === "string") this.realmId = parsed.realmId;
      return;
    }
    const ev: LedgerEvent = { ...parsed, rolledBack: false, _idx: this.nextIndex++ };
    if (ev.type === "server.started") {
      this.onServerStarted(ev);
    }
    this.events.push(ev);
    if (this.events.length > this.maxEvents) {
      this.events.shift();
      this.dropped++;
    }
  }

  private onServerStarted(ev: LedgerEvent): void {
    const newEpoch = typeof ev.epoch === "string" ? ev.epoch : null;
    const loadedSeq = typeof ev.loadedSeq === "number" ? ev.loadedSeq : 0;
    if (this.currentEpoch !== null && this.currentEpoch !== newEpoch) {
      // Walk back through the previous epoch only.
      for (let i = this.events.length - 1; i >= 0; i--) {
        const prev = this.events[i];
        if (prev === undefined || prev.epoch === newEpoch) continue;
        if (prev.epoch !== this.currentEpoch) break;
        if (typeof prev.seq === "number" && prev.seq > loadedSeq) prev.rolledBack = true;
      }
    }
    this.currentEpoch = newEpoch;
    this.loadedSeq = loadedSeq;
    if (typeof ev.realmId === "string") this.realmId = ev.realmId;
  }

  setDurable(watermark: Watermark | null): void {
    this.durable = watermark;
  }

  isDurable(ev: LedgerEvent): boolean {
    if (ev.rolledBack) return false;
    if (ev.epoch !== this.currentEpoch) return true;       // survived into a later save
    return this.durable !== null && this.durable.epoch === ev.epoch && typeof ev.seq === "number" && ev.seq <= this.durable.seq;
  }

  cursorOf(ev: LedgerEvent): string {
    return `idx:${ev._idx}`;
  }

  /** Resolve an `after` cursor to an arrival index (exclusive). -1 = from the start, null = unknown. */
  resolveCursor(after: string): number | null {
    if (after === "") return -1;
    const m = /^idx:(\d+)$/.exec(after);
    if (m !== null) return Number(m[1]);
    const colon = after.lastIndexOf(":");
    if (colon > 0) {
      const epoch = after.slice(0, colon);
      const seq = Number(after.slice(colon + 1));
      for (let i = this.events.length - 1; i >= 0; i--) {
        const ev = this.events[i];
        if (ev !== undefined && ev.epoch === epoch && ev.seq === seq) return ev._idx;
      }
    }
    return null;
  }

  ledger(after: string, limit = 500): LedgerPage | null {
    const from = this.resolveCursor(after);
    if (from === null) return null;
    const out: LedgerEntry[] = [];
    for (const ev of this.events) {
      if (ev._idx <= from) continue;
      const { _idx: _skip, ...rest } = ev;
      out.push({ ...rest, cursor: this.cursorOf(ev), durable: this.isDurable(ev) });
      if (out.length >= limit) break;
    }
    const last = out[out.length - 1];
    const next = last !== undefined ? last.cursor : (from >= 0 ? `idx:${from}` : null);
    return { events: out, next, exhausted: out.length < limit };
  }

  stats(): Record<string, unknown> {
    return {
      events: this.events.length, dropped: this.dropped, nextIndex: this.nextIndex,
      file: this.file, offset: this.offset, parseErrors: this.parseErrors,
      currentEpoch: this.currentEpoch, loadedSeq: this.loadedSeq, realmId: this.realmId,
      durable: this.durable, lastEventTs: this.lastEventTs,
    };
  }
}
