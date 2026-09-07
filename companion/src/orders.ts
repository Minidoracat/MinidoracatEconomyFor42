// Discord deposit orders (persistence spec 5.2, 5.4, 5.5): the companion is the only writer of
// {economyDir}/inbox/<orderId>.json. Watchcord POSTs an order pinned to the rate it showed the
// player; the companion re-checks the account binding and the pinned rate against the latest
// exchange.config projection, writes the file (tmp + rename) and answers 202. ECExchange.lua
// reads the file and reports exchange.deposited / exchange.failed on the event stream; once
// that event is durable the file is deleted here. A rolled-back outcome is never durable, so
// its file stays and Lua replays it after the restart (deposits self-heal, spec 5.5).
//
// Idempotency: the same orderId with the same payload returns the first answer; a different
// payload is a conflict. The index of accepted orders is persisted (orders.json in stateDir,
// pruned after INDEX_KEEP_MS) so a late resend of an order whose file is already gone cannot
// be taken as new and credited twice. Watchcord's own database is the first line of defence.
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import type { LedgerEvent, Logger } from "./events.ts";
import type { AccountSource } from "./server.ts";
import { errorCode, errorMessage } from "./events.ts";

export interface ExchangeBlock {
  pointsPerCoin: number;
  perOrderMin: number;
  perOrderMax: number;
  perAccountDaily: number;
  serverDaily: number;
  rateVersion: number;
}

export interface ExchangeCurrency {
  id: string;
  enabled: boolean;
  nameOverride?: string;
  marketUnit?: boolean;
  balanceMax?: number;
  exchange: ExchangeBlock | null;
}

export interface OrderRequest {
  orderId: string;
  steamId64: string;
  username: string;
  currency: string;
  points: number;
  amount: number;
  rateSnapshot: number;
  rateVersion: number;
  reason?: string;
}

export type OrderStatus = "pending" | "deposited" | "failed" | "unknown";

export interface OrderView {
  orderId: string;
  status: OrderStatus;
  durable: boolean;
  inbox: boolean;
  event?: Record<string, unknown>;
  submittedAt?: number;
}

interface IndexEntry {
  hash: string;
  at: number;
  /** Terminal outcome once seen durable (the inbox file is gone by then). */
  outcome?: "deposited" | "failed";
}

interface EventSource {
  events: LedgerEvent[];
  isDurable(ev: LedgerEvent): boolean;
}

export interface OrdersOptions {
  inboxDir: string;
  stateDir: string;
  store: EventSource;
  accounts: Pick<AccountSource, "forSteam">;
  log?: Logger;
  now?: () => number;
}

export interface Reply {
  status: number;
  body: Record<string, unknown>;
}

const ORDER_ID = /^[A-Za-z0-9_-]{1,64}$/;
const STEAM_ID = /^\d{1,20}$/;
export const INDEX_KEEP_MS = 30 * 24 * 3600 * 1000;
const REASON_MAX = 200;

function isInt(v: unknown, lo: number, hi: number): v is number {
  return typeof v === "number" && Number.isInteger(v) && v >= lo && v <= hi;
}

/** Field of an unknown object, or undefined when the value is not an object. */
function field(v: unknown, key: string): unknown {
  return typeof v === "object" && v !== null && key in v ? (v as { [k: string]: unknown })[key] : undefined;
}

function parseExchange(v: unknown): ExchangeBlock | null {
  const pointsPerCoin = field(v, "pointsPerCoin");
  const perOrderMin = field(v, "perOrderMin");
  const perOrderMax = field(v, "perOrderMax");
  const perAccountDaily = field(v, "perAccountDaily");
  const serverDaily = field(v, "serverDaily");
  const rateVersion = field(v, "rateVersion");
  const max = Number.MAX_SAFE_INTEGER;
  if (!isInt(pointsPerCoin, 1, max) || !isInt(perOrderMin, 1, max) || !isInt(perOrderMax, 1, max)
    || !isInt(perAccountDaily, 1, max) || !isInt(serverDaily, 1, max) || !isInt(rateVersion, 1, max)) return null;
  return { pointsPerCoin, perOrderMin, perOrderMax, perAccountDaily, serverDaily, rateVersion };
}

/** Parses the persisted orders.json (orderId -> entry); anything malformed is dropped. */
function parseIndex(raw: unknown): Map<string, IndexEntry> {
  const out = new Map<string, IndexEntry>();
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) return out;
  for (const [id, v] of Object.entries(raw)) {
    const hash = field(v, "hash");
    const at = field(v, "at");
    const outcome = field(v, "outcome");
    if (typeof hash !== "string" || typeof at !== "number") continue;
    const entry: IndexEntry = { hash, at };
    if (outcome === "deposited" || outcome === "failed") entry.outcome = outcome;
    out.set(id, entry);
  }
  return out;
}

/** Body of POST /orders -> the typed request, with every field coerced to its expected type. */
function parseOrderRequest(raw: unknown): OrderRequest | null {
  const orderId = field(raw, "orderId");
  if (typeof orderId !== "string") return null;
  const str = (k: string): string => { const v = field(raw, k); return typeof v === "string" ? v : ""; };
  const num = (k: string): number => { const v = field(raw, k); return typeof v === "number" ? v : NaN; };
  const req: OrderRequest = {
    orderId, steamId64: str("steamId64"), username: str("username"), currency: str("currency"),
    points: num("points"), amount: num("amount"), rateSnapshot: num("rateSnapshot"), rateVersion: num("rateVersion"),
  };
  const reason = str("reason");
  if (reason !== "") req.reason = reason.slice(0, REASON_MAX);
  return req;
}

export function payloadHash(o: OrderRequest): string {
  const canonical = [o.orderId, o.steamId64, o.username, o.currency, o.points, o.amount, o.rateSnapshot, o.rateVersion].join("\n");
  return crypto.createHash("sha256").update(canonical).digest("hex");
}

export class Orders {
  readonly inboxDir: string;
  readonly indexPath: string;
  readonly store: EventSource;
  readonly accounts: Pick<AccountSource, "forSteam">;
  readonly log: Logger;
  readonly now: () => number;
  private index = new Map<string, IndexEntry>();
  private indexDirty = false;

  constructor({ inboxDir, stateDir, store, accounts, log = console, now = Date.now }: OrdersOptions) {
    this.inboxDir = inboxDir;
    this.indexPath = path.join(stateDir, "orders.json");
    this.store = store;
    this.accounts = accounts;
    this.log = log;
    this.now = now;
  }

  // ---------- persisted index ----------

  loadIndex(): void {
    try {
      this.index = parseIndex(JSON.parse(fs.readFileSync(this.indexPath, "utf8")));
    } catch (err) {
      if (errorCode(err) !== "ENOENT") this.log.warn(`orders index unreadable, starting empty: ${errorMessage(err)}`);
    }
  }

  saveIndex(): void {
    if (!this.indexDirty) return;
    const cutoff = this.now() - INDEX_KEEP_MS;
    for (const [id, e] of this.index) if (e.at < cutoff) this.index.delete(id);
    fs.mkdirSync(path.dirname(this.indexPath), { recursive: true });
    const tmp = this.indexPath + ".tmp";
    fs.writeFileSync(tmp, JSON.stringify(Object.fromEntries(this.index)));
    fs.renameSync(tmp, this.indexPath);
    this.indexDirty = false;
  }

  // ---------- projections ----------

  /** The newest exchange.config the server emitted (start and every change); null before the first. */
  currencies(): ExchangeCurrency[] | null {
    const events = this.store.events;
    for (let i = events.length - 1; i >= 0; i--) {
      const ev = events[i];
      if (ev === undefined || ev.type !== "exchange.config" || ev.rolledBack) continue;
      const list = ev.currencies;
      if (!Array.isArray(list)) continue;
      const out: ExchangeCurrency[] = [];
      for (const c of list) {
        const id = field(c, "id");
        if (typeof id !== "string") continue;
        const cur: ExchangeCurrency = { id, enabled: field(c, "enabled") !== false, exchange: parseExchange(field(c, "exchange")) };
        const nameOverride = field(c, "nameOverride");
        const marketUnit = field(c, "marketUnit");
        const balanceMax = field(c, "balanceMax");
        if (typeof nameOverride === "string") cur.nameOverride = nameOverride;
        if (typeof marketUnit === "boolean") cur.marketUnit = marketUnit;
        if (typeof balanceMax === "number") cur.balanceMax = balanceMax;
        out.push(cur);
      }
      return out;
    }
    return null;
  }

  /** Latest non-rolled-back outcome event for an order, if any. */
  private outcome(orderId: string): LedgerEvent | null {
    const events = this.store.events;
    for (let i = events.length - 1; i >= 0; i--) {
      const ev = events[i];
      if (ev === undefined || ev.rolledBack || ev.orderId !== orderId) continue;
      if (ev.type === "exchange.deposited" || ev.type === "exchange.failed") return ev;
    }
    return null;
  }

  private inboxPath(orderId: string): string {
    return path.join(this.inboxDir, `${orderId}.json`);
  }

  private inboxExists(orderId: string): boolean {
    return fs.existsSync(this.inboxPath(orderId));
  }

  status(orderId: string): OrderView {
    const inbox = this.inboxExists(orderId);
    const ev = this.outcome(orderId);
    const idx = this.index.get(orderId);
    const view: OrderView = { orderId, status: "unknown", durable: false, inbox };
    if (idx !== undefined) view.submittedAt = idx.at;
    if (ev !== null) {
      view.status = ev.type === "exchange.deposited" ? "deposited" : "failed";
      view.durable = this.store.isDurable(ev);
      const { _idx: _skip, ...rest } = ev;
      view.event = rest;
    } else if (idx?.outcome !== undefined) {
      // the event left memory but the file was deleted only after it was durable
      view.status = idx.outcome;
      view.durable = true;
    } else if (inbox || idx !== undefined) {
      view.status = "pending";
    }
    return view;
  }

  // ---------- create ----------

  create(raw: unknown): Reply {
    const req = parseOrderRequest(raw);
    if (req === null) return { status: 400, body: { error: "invalid_body" } };
    const orderId = req.orderId;
    if (!ORDER_ID.test(orderId)) return { status: 400, body: { error: "invalid_orderId" } };
    const hash = payloadHash(req);

    // a resend: same payload -> the same answer; another payload under the same id -> conflict
    const known = this.index.get(orderId);
    if (known !== undefined) {
      if (known.hash !== hash) return { status: 409, body: { error: "order_conflict", orderId } };
      const view = this.status(orderId);
      return { status: view.status === "pending" ? 202 : 200, body: { ...view, duplicate: true } };
    }

    if (!STEAM_ID.test(req.steamId64)) return { status: 400, body: { error: "invalid_steamId64" } };
    if (req.username === "" || req.username.length > 64 || /[\u0000-\u001f]/.test(req.username)) return { status: 400, body: { error: "invalid_username" } };
    if (!isInt(req.points, 1, Number.MAX_SAFE_INTEGER) || !isInt(req.amount, 1, Number.MAX_SAFE_INTEGER)) return { status: 400, body: { error: "invalid_amount" } };
    if (!isInt(req.rateSnapshot, 1, Number.MAX_SAFE_INTEGER) || !isInt(req.rateVersion, 1, Number.MAX_SAFE_INTEGER)) return { status: 400, body: { error: "invalid_rate" } };

    const bound = this.accounts.forSteam(req.steamId64).some((a) => a.username === req.username);
    if (!bound) return { status: 403, body: { error: "account_not_bound", orderId } };

    const currencies = this.currencies();
    if (currencies === null) return { status: 503, body: { error: "config_unavailable" } };
    const cur = currencies.find((c) => c.id === req.currency);
    if (cur === undefined || cur.exchange === null) return { status: 400, body: { error: "unknown_currency", orderId } };
    if (!cur.enabled) return { status: 409, body: { error: "currency_disabled", orderId } };
    const ex = cur.exchange;
    if (req.rateVersion !== ex.rateVersion || req.rateSnapshot !== ex.pointsPerCoin) {
      return { status: 409, body: { error: "rate_changed", orderId, currencies } };
    }
    if (req.amount !== Math.floor(req.points / ex.pointsPerCoin)) return { status: 400, body: { error: "amount_mismatch", orderId } };
    if (req.amount < ex.perOrderMin || req.amount > ex.perOrderMax) {
      return { status: 400, body: { error: "order_range", orderId, min: ex.perOrderMin, max: ex.perOrderMax } };
    }

    // the file: one JSON object, tmp + rename so Lua never sees a half-written order
    const record = { ...req, payloadHash: hash, createdAt: this.now() };
    try {
      fs.mkdirSync(this.inboxDir, { recursive: true });
      const target = this.inboxPath(orderId);
      const tmp = `${target}.tmp`;
      fs.writeFileSync(tmp, JSON.stringify(record) + "\n");
      fs.renameSync(tmp, target);
    } catch (err) {
      this.log.error(`inbox write failed for ${orderId}: ${errorMessage(err)}`);
      return { status: 503, body: { error: "inbox_unavailable", orderId } };
    }
    this.index.set(orderId, { hash, at: record.createdAt });
    this.indexDirty = true;
    this.saveIndex();
    this.log.info(`order ${orderId}: ${req.username} +${req.amount} ${req.currency} (${req.points} points @${req.rateSnapshot}) queued`);
    return { status: 202, body: { orderId, status: "pending", durable: false, inbox: true } };
  }

  // ---------- sweep ----------

  listInbox(): string[] {
    let names: string[];
    try {
      names = fs.readdirSync(this.inboxDir);
    } catch (err) {
      if (errorCode(err) === "ENOENT") return [];
      throw err;
    }
    return names.filter((n) => n.endsWith(".json")).map((n) => n.slice(0, -5)).filter((id) => ORDER_ID.test(id)).sort();
  }

  /** Deletes the inbox files whose outcome is durable. Returns how many were removed. */
  sweep(): number {
    let removed = 0;
    for (const orderId of this.listInbox()) {
      const ev = this.outcome(orderId);
      if (ev === null || !this.store.isDurable(ev)) continue;
      try {
        fs.unlinkSync(this.inboxPath(orderId));
      } catch (err) {
        if (errorCode(err) !== "ENOENT") this.log.warn(`inbox delete failed for ${orderId}: ${errorMessage(err)}`);
        continue;
      }
      removed++;
      const entry = this.index.get(orderId) ?? { hash: "", at: this.now() };
      entry.outcome = ev.type === "exchange.deposited" ? "deposited" : "failed";
      this.index.set(orderId, entry);
      this.indexDirty = true;
    }
    if (removed > 0) this.saveIndex();
    return removed;
  }

  stats(): Record<string, unknown> {
    const files = this.listInbox();
    return { inboxFiles: files.length, indexed: this.index.size };
  }
}
