// Intranet HTTP API consumed by Watchcord (spec: economy-persistence-and-integration.md §6).
// Zero dependencies: node:http + node:crypto. Requests are authenticated with
//   X-Timestamp: unix seconds (±300 s)
//   X-Signature: hex HMAC-SHA256(secret, `${timestamp}\n${METHOD}\n${path+query}\n${body}`)
// An empty secret is accepted only when bound to loopback (local development).
import http from "node:http";
import crypto from "node:crypto";
import type { Watermark } from "./bin.ts";
import type { LedgerPage, Logger } from "./events.ts";
import type { AccountRecord } from "./accounts.ts";
import type { Orders } from "./orders.ts";

const SKEW_SECONDS = 300;

/** What the API reads from the event store (EventStore satisfies it structurally). */
export interface LedgerSource {
  durable: Watermark | null;
  currentEpoch: string | null;
  loadedSeq: number;
  realmId: string | null;
  ledger(after: string, limit: number): LedgerPage | null;
  stats(): Record<string, unknown>;
}

export interface AccountSource {
  refreshedAt: number;
  forSteam(steamId64: string): AccountRecord[];
  forUsername(username: string): AccountRecord | null;
  stats(): Record<string, unknown>;
}

/** One line of {economyDir}/durable.json: the watermark Lua may trust during this uptime. */
export interface DurableRecord {
  realmId: string;
  epoch: string;
  seq: number;
  /** Unix ms of the write. */
  ts: number;
}

/** A parsed watermark that is not on disk yet (waiting for a stable snapshot, or a failed write). */
export interface PendingPublish {
  realmId: string;
  epoch: string;
  seq: number;
  /** mtime/size of the .bin the watermark came from; the write only happens while they still match. */
  mtime: number;
  size: number;
}

/** Live view of the .bin watermark poller (index.ts owns the state). */
export interface WatermarkState {
  durable: Watermark | null;
  mtime: number | null;
  parsedAt: number | null;
  error: string | null;
  sizeBytes: number | null;
  /** Last record written to {economyDir}/durable.json; absent on a stub, null until one is published. */
  published?: DurableRecord | null;
  /** Watermark parsed but not on disk yet (unsettled snapshot, or a write that failed and is retried). */
  pending?: PendingPublish | null;
  /** Why the last publish attempt did not land; null when the file is up to date. */
  publishError?: string | null;
}

export interface ServerDeps {
  config: { hmacSecret: string; bind: string };
  store: LedgerSource;
  accounts: AccountSource;
  watermark: () => WatermarkState;
  /** Deposit orders (spec 5.2). Optional so a read-only deployment can leave it out. */
  orders?: Orders;
  log?: Logger;
}

export function sign(secret: string, timestamp: number, method: string, pathWithQuery: string, body = ""): string {
  return crypto.createHmac("sha256", secret).update(`${timestamp}\n${method}\n${pathWithQuery}\n${body}`).digest("hex");
}

function header(req: http.IncomingMessage, name: string): string {
  const raw = req.headers[name];
  return Array.isArray(raw) ? (raw[0] ?? "") : (raw ?? "");
}

function verify(req: http.IncomingMessage, url: URL, body: string, secret: string): boolean {
  const ts = Number(header(req, "x-timestamp"));
  const sig = header(req, "x-signature");
  if (!Number.isFinite(ts) || Math.abs(Date.now() / 1000 - ts) > SKEW_SECONDS) return false;
  const expected = sign(secret, ts, req.method ?? "GET", url.pathname + url.search, body);
  return sig.length === expected.length && crypto.timingSafeEqual(Buffer.from(sig, "hex"), Buffer.from(expected, "hex"));
}

function json(res: http.ServerResponse, status: number, payload: unknown): void {
  const text = JSON.stringify(payload);
  res.writeHead(status, { "content-type": "application/json; charset=utf-8", "content-length": Buffer.byteLength(text) });
  res.end(text);
}

export function createServer({ config, store, accounts, watermark, orders, log = console }: ServerDeps): http.Server {
  const loopback = config.bind === "127.0.0.1" || config.bind === "::1" || config.bind === "localhost";
  const authOptional = config.hmacSecret === "" && loopback;
  if (authOptional) log.warn("HMAC_SECRET is empty: requests are unauthenticated (loopback only)");
  if (config.hmacSecret === "" && !loopback) {
    throw new Error("HMAC_SECRET is required when BIND is not loopback");
  }

  const startedAt = Date.now();

  function route(req: http.IncomingMessage, url: URL, res: http.ServerResponse, body: string): void {
    if (req.method === "GET" && url.pathname === "/health") {
      const wm = watermark();
      json(res, 200, {
        ok: true,
        uptimeMs: Date.now() - startedAt,
        events: store.stats(),
        durable: wm.durable,
        modData: { mtime: wm.mtime, parsedAt: wm.parsedAt, error: wm.error, sizeBytes: wm.sizeBytes },
        publish: { published: wm.published ?? null, pending: wm.pending ?? null, error: wm.publishError ?? null },
        accounts: accounts.stats(),
        orders: orders?.stats() ?? null,
      });
      return;
    }
    if (orders !== undefined && req.method === "GET" && url.pathname === "/currencies") {
      const currencies = orders.currencies();
      if (currencies === null) {
        json(res, 503, { error: "config_unavailable" });
        return;
      }
      json(res, 200, { currencies, durable: store.durable, currentEpoch: store.currentEpoch });
      return;
    }
    if (orders !== undefined && req.method === "POST" && url.pathname === "/orders") {
      let parsed: unknown;
      try {
        parsed = JSON.parse(body);
      } catch {
        json(res, 400, { error: "invalid_json" });
        return;
      }
      const reply = orders.create(parsed);
      json(res, reply.status, reply.body);
      return;
    }
    if (orders !== undefined && req.method === "GET" && url.pathname.startsWith("/orders/")) {
      const orderId = decodeURIComponent(url.pathname.slice("/orders/".length));
      if (!/^[A-Za-z0-9_-]{1,64}$/.test(orderId)) {
        json(res, 400, { error: "invalid_orderId" });
        return;
      }
      const view = orders.status(orderId);
      json(res, view.status === "unknown" ? 404 : 200, view);
      return;
    }
    if (req.method === "GET" && url.pathname === "/ledger") {
      const after = url.searchParams.get("after") ?? "";
      const limit = Math.min(Math.max(Number(url.searchParams.get("limit") ?? 500) || 500, 1), 5000);
      const page = store.ledger(after, limit);
      if (page === null) {
        json(res, 400, { error: "unknown_cursor" });
        return;
      }
      json(res, 200, { ...page, durable: store.durable, currentEpoch: store.currentEpoch, loadedSeq: store.loadedSeq, realmId: store.realmId });
      return;
    }
    if (req.method === "GET" && url.pathname === "/accounts") {
      const steamId64 = url.searchParams.get("steamId64");
      const username = url.searchParams.get("username");
      let list: AccountRecord[];
      if (steamId64 !== null && steamId64 !== "") {
        list = accounts.forSteam(steamId64);
      } else if (username !== null && username !== "") {
        const rec = accounts.forUsername(username);
        list = rec === null ? [] : [rec];
      } else {
        json(res, 400, { error: "steamId64 or username required" });
        return;
      }
      json(res, 200, { accounts: list, refreshedAt: accounts.refreshedAt, durable: store.durable });
      return;
    }
    json(res, 404, { error: "not_found" });
  }

  return http.createServer((req, res) => {
    const chunks: Buffer[] = [];
    req.on("data", (c: Buffer) => chunks.push(c));
    req.on("end", () => {
      const body = Buffer.concat(chunks).toString("utf8");
      const url = new URL(req.url ?? "/", "http://companion");
      if (!authOptional && !verify(req, url, body, config.hmacSecret)) {
        json(res, 401, { error: "unauthorized" });
        return;
      }
      try {
        route(req, url, res, body);
      } catch (err) {
        log.error(`request failed: ${err instanceof Error ? (err.stack ?? err.message) : String(err)}`);
        json(res, 500, { error: "internal" });
      }
    });
  });
}
