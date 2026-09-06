// Intranet HTTP API consumed by Watchcord (spec: economy-persistence-and-integration.md §6).
// Zero dependencies: node:http + node:crypto. Requests are authenticated with
//   X-Timestamp: unix seconds (±300 s)
//   X-Signature: hex HMAC-SHA256(secret, `${timestamp}\n${METHOD}\n${path+query}\n${body}`)
// An empty secret is accepted only when bound to loopback (local development).
import http from "node:http";
import crypto from "node:crypto";

const SKEW_SECONDS = 300;

export function sign(secret, timestamp, method, pathWithQuery, body = "") {
  return crypto.createHmac("sha256", secret).update(`${timestamp}\n${method}\n${pathWithQuery}\n${body}`).digest("hex");
}

function isLoopback(bind) {
  return bind === "127.0.0.1" || bind === "::1" || bind === "localhost";
}

function verify(req, url, body, secret) {
  const ts = Number(req.headers["x-timestamp"]);
  const sig = String(req.headers["x-signature"] ?? "");
  if (!Number.isFinite(ts) || Math.abs(Date.now() / 1000 - ts) > SKEW_SECONDS) return false;
  const expected = sign(secret, ts, req.method, url.pathname + url.search, body);
  return sig.length === expected.length && crypto.timingSafeEqual(Buffer.from(sig, "hex"), Buffer.from(expected, "hex"));
}

function json(res, status, payload) {
  const text = JSON.stringify(payload);
  res.writeHead(status, { "content-type": "application/json; charset=utf-8", "content-length": Buffer.byteLength(text) });
  res.end(text);
}

/**
 * @param {object} deps  { config, store, accounts, watermark: () => object, log }
 */
export function createServer({ config, store, accounts, watermark, log = console }) {
  const authOptional = config.hmacSecret === "" && isLoopback(config.bind);
  if (authOptional) log.warn("HMAC_SECRET is empty: requests are unauthenticated (loopback only)");
  if (config.hmacSecret === "" && !isLoopback(config.bind)) {
    throw new Error("HMAC_SECRET is required when BIND is not loopback");
  }

  const startedAt = Date.now();

  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      const body = Buffer.concat(chunks).toString("utf8");
      const url = new URL(req.url, "http://companion");
      if (!authOptional && !verify(req, url, body, config.hmacSecret)) {
        return json(res, 401, { error: "unauthorized" });
      }
      try {
        route(req, url, body, res);
      } catch (err) {
        log.error(`request failed: ${err.stack || err.message}`);
        json(res, 500, { error: "internal" });
      }
    });
  });

  function route(req, url, body, res) {
    if (req.method === "GET" && url.pathname === "/health") {
      const wm = watermark();
      return json(res, 200, {
        ok: true,
        uptimeMs: Date.now() - startedAt,
        events: store.stats(),
        durable: wm.durable,
        modData: { mtime: wm.mtime, parsedAt: wm.parsedAt, error: wm.error, sizeBytes: wm.sizeBytes },
        accounts: accounts.stats(),
      });
    }
    if (req.method === "GET" && url.pathname === "/ledger") {
      const after = url.searchParams.get("after") ?? "";
      const limit = Math.min(Math.max(Number(url.searchParams.get("limit") ?? 500) || 500, 1), 5000);
      const page = store.ledger(after, limit);
      if (!page) return json(res, 400, { error: "unknown_cursor" });
      return json(res, 200, { ...page, durable: store.durable, currentEpoch: store.currentEpoch, loadedSeq: store.loadedSeq, realmId: store.realmId });
    }
    if (req.method === "GET" && url.pathname === "/accounts") {
      const steamId64 = url.searchParams.get("steamId64");
      const username = url.searchParams.get("username");
      if (!steamId64 && !username) return json(res, 400, { error: "steamId64 or username required" });
      const list = steamId64 ? accounts.forSteam(steamId64) : [accounts.forUsername(username)].filter(Boolean);
      return json(res, 200, { accounts: list, refreshedAt: accounts.refreshedAt, durable: store.durable });
    }
    return json(res, 404, { error: "not_found" });
  }

  return server;
}
