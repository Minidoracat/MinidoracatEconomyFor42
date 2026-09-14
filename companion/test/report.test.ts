import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";
import { encodeGlobalModData, type LuaTable } from "../src/bin.ts";
import { readReportSource, type ReportPosting } from "../src/report-data.ts";
import { buildDailyReport } from "../src/report-audit.ts";
import { dateInZone, shiftDate, reportPeriod } from "../src/report-time.ts";

const day = "2025-01-01";
const at = Date.parse(`${day}T04:00:00Z`);
const cli = fileURLToPath(new URL("../src/report-cli.ts", import.meta.url));
function posting(account: string, amount: number, before: number, after: number, reservedBefore = 0, reservedAfter = 0, bucket: ReportPosting["bucket"] = "available"): ReportPosting {
  return { account, currency: "survivor", amount, bucket, availableBefore: before, availableAfter: after, reservedBefore, reservedAfter };
}
function tx(epoch: string, seq: number, postings: ReportPosting[], kind = "reward") {
  return { type: "tx.committed", realmId: "realm-test", epoch, seq, txId: `${epoch}:${seq}`, ts: at + seq, kind, reasonCode: kind, requestId: `${epoch}:${seq}`, postings };
}
function fixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "economy-report-"));
  const zomboid = path.join(root, "Zomboid");
  const economyDir = path.join(zomboid, "Lua", "MinidoracatEconomy");
  const modDataBin = path.join(zomboid, "Saves", "Multiplayer", "servertest", "global_mod_data.bin");
  fs.mkdirSync(economyDir, { recursive: true });
  fs.mkdirSync(path.dirname(modDataBin), { recursive: true });
  const writeEvents = (events: unknown[], date = day) => fs.writeFileSync(path.join(economyDir, `events-${date.replaceAll("-", "")}.json`), events.map((e) => JSON.stringify(e)).join("\r\n") + "\r\n");
  const save = (seq: number, available: number, reserved = 0, epoch = "1000", history: LuaTable = {}, burned = 0) => {
    fs.writeFileSync(modDataBin, encodeGlobalModData(226, new Map<string, LuaTable>([["MinidoracatEconomy", {
      meta: { realmId: "realm-test", epoch, seq, loadedSeq: 0, history },
      wallets: { alice: { survivor: { available, reserved } }, SYSTEM_MINT: { survivor: { available: -100, reserved: 0 } }, SYSTEM_BURN: { survivor: { available: burned, reserved: 0 } } },
    }]])));
  };
  const start = { type: "server.started", realmId: "realm-test", epoch: "1000", seq: 0, loadedSeq: 0, ts: at - 100 };
  const mint = tx("1000", 1, [posting("SYSTEM_MINT", -100, 0, -100), posting("alice", 100, 0, 100)]);
  fs.writeFileSync(path.join(economyDir, "epochs.json"), JSON.stringify({ epoch: "1000", loadedSeq: 0 }) + "\n");
  return { root, zomboid, economyDir, modDataBin, writeEvents, save, start, mint,
    options: { economyDir, modDataBin, modDataTag: "MinidoracatEconomy", settleMs: 1, maxEvents: 1000 } };
}

 test("report date: local midnight, yesterday, DST and skipped calendar days", () => {
  assert.deepEqual(reportPeriod(day, "Asia/Taipei"), { fromMs: Date.parse("2024-12-31T16:00:00Z"), toMs: Date.parse("2025-01-01T16:00:00Z") });
  assert.equal(dateInZone(Date.parse("2025-01-01T16:01:00Z"), "Asia/Taipei"), "2025-01-02");
  assert.equal(shiftDate("2024-03-01", -1), "2024-02-29");
  const spring = reportPeriod("2025-03-09", "America/New_York");
  const fall = reportPeriod("2025-11-02", "America/New_York");
  assert.equal(spring.toMs - spring.fromMs, 23 * 3600000);
  assert.equal(fall.toMs - fall.fromMs, 25 * 3600000);
  assert.throws(() => reportPeriod("2025-02-29", "UTC"));
  assert.throws(() => reportPeriod(day, "Not/AZone"));
  assert.throws(() => reportPeriod("2011-12-30", "Pacific/Apia"));
  assert.equal(dateInZone(Date.parse("2009-11-01T02:30:30Z"), "America/St_Johns"), "2009-11-01");
  assert.equal(dateInZone(Date.parse("2009-11-01T02:31:00Z"), "America/St_Johns"), "2009-10-31");
  assert.throws(() => reportPeriod("2009-11-01", "America/St_Johns"), /跨日回撥/);
  assert.throws(() => reportPeriod("2009-10-31", "America/St_Johns"), /跨日回撥/);
});

test("report: reservations are not issuance; pending does not break the saved wallet chain", async () => {
  const f = fixture();
  try {
    const reserve = tx("1000", 2, [posting("alice", -30, 100, 70), posting("alice", 30, 70, 70, 0, 30, "reserved")], "auction_bid");
    const pending = tx("1000", 3, [posting("alice", -10, 70, 60, 30, 30), posting("alice", 10, 60, 60, 30, 40, "reserved")], "auction_bid");
    f.writeEvents([f.start, f.mint, reserve, pending]);f.save(2, 70, 30);
    const before = fs.readFileSync(f.modDataBin);
    const source = await readReportSource(f.options);
    const report = buildDailyReport(source, { date: day, timeZone: "UTC", ...reportPeriod(day, "UTC") });
    assert.equal(report.statusCounts.durable, 2);
    assert.equal(report.statusCounts.pending, 1);
    assert.deepEqual(report.totals.map((t) => [t.currency, t.issued, t.retired, t.availableDelta, t.reservedDelta]), [["survivor", 100, 0, 70, 30]]);
    assert.equal(report.issues.length, 0, JSON.stringify(report.issues));
    assert.deepEqual(fs.readFileSync(f.modDataBin), before);
    assert.equal(fs.existsSync(path.join(f.economyDir, "companion-state")), false);
  } finally { fs.rmSync(f.root, { recursive: true, force: true }); }
});

test("report: rolled-back spending is excluded from totals and the next epoch chain", async () => {
  const f = fixture();
  try {
    const lost = tx("1000", 2, [posting("alice", -20, 100, 80), posting("SYSTEM_BURN", 20, 0, 20)], "shop_buy");
    const next = { type: "server.started", realmId: "realm-test", epoch: "2000", seq: 1, loadedSeq: 1, ts: at + 3 };
    const paid = tx("2000", 2, [posting("alice", -10, 100, 90), posting("SYSTEM_BURN", 10, 0, 10)], "shop_buy");
    paid.ts = at + 4;
    f.writeEvents([f.start, f.mint, lost, next, paid]);
    fs.appendFileSync(path.join(f.economyDir, "epochs.json"), JSON.stringify({ epoch: "2000", loadedSeq: 1 }) + "\n");
    f.save(2, 90, 0, "2000", { 1: { epoch: "1000", loadedSeq: 1 } }, 10);
    const report = buildDailyReport(await readReportSource(f.options), { date: day, timeZone: "UTC", ...reportPeriod(day, "UTC") });
    assert.equal(report.transactions.find((t) => t.txId === "1000:2")?.status, "rolled_back");
    assert.equal(report.totals[0]?.retired, 10);
    assert.equal(report.issues.length, 0, JSON.stringify(report.issues));
  } finally { fs.rmSync(f.root, { recursive: true, force: true }); }
});

test("report: duplicate IDs, broken lines and foreign records cannot become clean totals", async () => {
  const f = fixture();
  try {
    f.writeEvents([f.start, f.mint, f.mint, { ...f.mint, txId: "1000:01" }, { ...tx("1000", 2, []), realmId: "foreign" }]);f.save(1, 100);
    fs.appendFileSync(path.join(f.economyDir, "events-20250101.json"), "{broken}\n{\"type\":");
    const report = buildDailyReport(await readReportSource(f.options), { date: day, timeZone: "UTC", ...reportPeriod(day, "UTC") });
    assert.equal(report.coverage.complete, false);
    assert.ok([...report.coverage.issues, ...report.issues].some((i) => i.txId === "1000:1"));
    assert.deepEqual(report.totals, []);
  } finally { fs.rmSync(f.root, { recursive: true, force: true }); }
});

test("report: unknown history is not declared durable merely because its epoch differs", async () => {
  const f = fixture();
  try {
    f.writeEvents([tx("50", 1, [posting("SYSTEM_MINT", -100, 0, -100), posting("alice", 100, 0, 100)]), f.start]);f.save(0, 0);
    const source = await readReportSource(f.options);
    assert.equal(source.transactions.find((t) => t.txId === "50:1")?.status, "unknown");
  } finally { fs.rmSync(f.root, { recursive: true, force: true }); }
});

test("report CLI: native .env, read-only inputs, late confirmation and timezone isolation", () => {
  const f = fixture();
  try {
    const pending = tx("1000", 2, [posting("alice", -10, 100, 90), posting("SYSTEM_BURN", 10, 0, 10)], "shop_buy");
    f.writeEvents([f.start, f.mint, pending]);f.save(1, 100);
    fs.mkdirSync(path.join(f.economyDir, "companion-state"));
    fs.writeFileSync(path.join(f.economyDir, "companion-state", "checkpoint.json"), "DO NOT TOUCH");
    fs.writeFileSync(path.join(f.root, ".env"), `ZOMBOID_DIR=${f.zomboid.replaceAll("\\", "/")}\nSERVER_NAME=servertest\nREPORT_TIME_ZONE=UTC\nREPORT_OUTPUT_DIR=./reports\nPOLL_MS=1\n`);
    const env = { ...process.env };
    for (const key of ["ZOMBOID_DIR", "SERVER_NAME", "REPORT_TIME_ZONE", "REPORT_OUTPUT_DIR", "POLL_MS", "COMPANION_STATE_DIR"]) delete env[key];
    const run = (date: string, extra: NodeJS.ProcessEnv = {}) => spawnSync(process.execPath, ["--env-file=.env", cli, "--date", date], { cwd: f.root, env: { ...env, ...extra }, encoding: "utf8", timeout: 20000 });
    const first = run(day);
    assert.equal(first.status, 2, first.stderr);
    const readReport = (date: string): unknown => JSON.parse(fs.readFileSync(path.join(f.root, "reports", `${date}.json`), "utf8"));
    const old = readReport(day);
    assert.ok(typeof old === "object" && old !== null && "statusCounts" in old);
    assert.deepEqual(old.statusCounts, { durable: 1, rolled_back: 0, pending: 1, unknown: 0 });
    const savedReport = fs.readFileSync(path.join(f.root, "reports", `${day}.json`));
    const reportFile = path.join(f.root, "reports", `${day}.json`);
    const brokenReport = Buffer.from(savedReport);
    brokenReport[brokenReport.indexOf(Buffer.from("reward"))] = 0xff;
    fs.writeFileSync(reportFile, brokenReport);
    assert.equal(run("2025-01-02").status, 1, "invalid UTF-8 in prior report is not silently repaired");
    assert.deepEqual(fs.readFileSync(reportFile), brokenReport);
    fs.writeFileSync(reportFile, savedReport);
    fs.renameSync(reportFile, `${reportFile}.held`);
    assert.equal(run("2025-01-02").status, 1, "orphan Markdown must expose lost prior-report state");
    fs.renameSync(`${reportFile}.held`, reportFile);
    const savedBin = fs.readFileSync(f.modDataBin);
    fs.unlinkSync(f.modDataBin);
    f.writeEvents([f.start, f.mint, pending, { ...f.mint, realmId: "other-world" }]);
    assert.equal(run("2025-01-02").status, 1, "unknown realm cannot erase a previously known realm");
    assert.deepEqual(fs.readFileSync(reportFile), savedReport);
    fs.writeFileSync(f.modDataBin, savedBin);
    f.writeEvents([f.start]);
    assert.equal(run("2025-01-02").status, 1, "lost source rows must not retire earlier pending records");
    assert.deepEqual(fs.readFileSync(path.join(f.root, "reports", `${day}.json`)), savedReport);
    f.writeEvents([f.start, f.mint, pending]);
    f.save(2, 90, 0, "1000", {}, 10);
    f.writeEvents([{ type: "file.header", schemaVersion: 1, realmId: "realm-test", epoch: "1000", ts: Date.parse("2025-01-02T00:00:00Z") }], "2025-01-02");
    const fault = path.join(f.root, "fail-markdown.mjs");
    fs.writeFileSync(fault, `import fs from "node:fs"; import path from "node:path";
const rename = fs.renameSync;
fs.renameSync = (from, to) => { if (path.basename(String(to)) === "${day}.md") throw new Error("injected output failure"); return rename(from, to); };`);
    assert.equal(run("2025-01-02", { NODE_OPTIONS: `--import=${pathToFileURL(fault).href}` }).status, 1);
    assert.deepEqual(fs.readFileSync(reportFile), savedReport, "failed Markdown must not retire pending JSON");
    const second = run("2025-01-02");
    assert.equal(second.status, 0, second.stderr + second.stdout);
    const latest = readReport("2025-01-02");
    assert.ok(typeof latest === "object" && latest !== null && "rechecks" in latest && Array.isArray(latest.rechecks));
    assert.ok(latest.rechecks.some((r: unknown) => typeof r === "object" && r !== null && "txId" in r && r.txId === "1000:2" && "after" in r && r.after === "durable"));
    assert.equal(run("2025-01-02").status, 0);
    const repeated = readReport("2025-01-02");
    assert.ok(typeof repeated === "object" && repeated !== null && "rechecks" in repeated);
    assert.deepEqual(repeated.rechecks, latest.rechecks, "rerunning a day preserves its earlier corrections without duplicating them");
    const markdownFile = path.join(f.root, "reports", `${day}.md`);
    fs.writeFileSync(markdownFile, "stale output");
    assert.equal(run("2025-01-02").status, 0, "damaged output pairing is repaired even after confirmation");
    assert.notEqual(fs.readFileSync(markdownFile, "utf8"), "stale output");
    fs.writeFileSync(fault, `import fs from "node:fs"; import path from "node:path";
const rename = fs.renameSync;
fs.renameSync = (from, to) => { if (path.basename(String(to)) === "2025-01-03.json") throw new Error("injected JSON failure"); return rename(from, to); };`);
    assert.equal(run("2025-01-03", { NODE_OPTIONS: `--import=${pathToFileURL(fault).href}` }).status, 1);
    assert.equal(fs.existsSync(path.join(f.root, "reports", "2025-01-03.md")), false, "failed new JSON publication must not leave orphan Markdown");
    assert.equal(fs.existsSync(path.join(f.root, "reports", "2025-01-03.json")), false);
    assert.equal(fs.readFileSync(path.join(f.economyDir, "companion-state", "checkpoint.json"), "utf8"), "DO NOT TOUCH");
    assert.equal(fs.existsSync(path.join(f.economyDir, "durable.json")), false);
    assert.equal(fs.existsSync(path.join(f.root, "reports", ".report.lock")), false);
    assert.equal(run(day, { REPORT_TIME_ZONE: "Asia/Taipei" }).status, 1);
    assert.equal(run(day, { REPORT_OUTPUT_DIR: f.economyDir }).status, 1);
  } finally { fs.rmSync(f.root, { recursive: true, force: true }); }
});

test("report: a missing startup cannot make a previous unsaved epoch durable", async () => {
  const f = fixture();
  try {
    f.writeEvents([f.start, f.mint, { type: "server.started", realmId: "realm-test", epoch: "3000", seq: 5, loadedSeq: 5, ts: at + 10 }]);
    fs.writeFileSync(path.join(f.economyDir, "epochs.json"), JSON.stringify({ epoch: "1000", loadedSeq: 0 }) + "\n{broken}\n" + JSON.stringify({ epoch: "3000", loadedSeq: 5 }) + "\n");
    f.save(5, 100, 0, "3000");
    const source = await readReportSource(f.options);
    assert.equal(source.transactions.find((t) => t.txId === "1000:1")?.status, "unknown");
    assert.ok(source.issues.some((i) => i.file === "epochs.json"));
  } finally { fs.rmSync(f.root, { recursive: true, force: true }); }
});

test("report: invalid UTF-8 is not repaired into an accepted transaction", async () => {
  const f = fixture();
  try {
    f.writeEvents([f.start]);f.save(1, 100);
    const text = JSON.stringify({ ...f.mint, reasonText: "REPLACE" });
    const [prefix, suffix] = text.split("REPLACE");
    assert.ok(prefix !== undefined && suffix !== undefined);
    fs.appendFileSync(path.join(f.economyDir, "events-20250101.json"), Buffer.concat([Buffer.from(prefix), Buffer.from([0xff]), Buffer.from(suffix + "\n")]));
    const source = await readReportSource(f.options);
    assert.equal(source.transactions.length, 0);
    assert.ok(source.issues.some((i) => i.file === "events-20250101.json" && i.line === 2));
  } finally { fs.rmSync(f.root, { recursive: true, force: true }); }
});

test("report: Taipei coverage requires both UTC event files", async () => {
  const f = fixture();
  try {
    f.writeEvents([f.start, f.mint]);f.save(1, 100);
    const report = buildDailyReport(await readReportSource(f.options), { date: day, timeZone: "Asia/Taipei", ...reportPeriod(day, "Asia/Taipei") });
    assert.equal(report.coverage.complete, false);
    assert.ok(report.coverage.issues.some((i) => i.file === "events-20241231.json" || i.message.includes("events-20241231.json")));
  } finally { fs.rmSync(f.root, { recursive: true, force: true }); }
});

test("report: money beyond JSON safe integers is unavailable, never a rounded zero", async () => {
  const f = fixture();
  try {
    const max = Number.MAX_SAFE_INTEGER;
    f.writeEvents([f.start,
      tx("1000", 1, [posting("MOD:a", -max, 0, -max), posting("alice", max, 0, max)]),
      tx("1000", 2, [posting("MOD:b", -max, 0, -max), posting("bob", max, 0, max)]),
    ]);
    fs.writeFileSync(f.modDataBin, encodeGlobalModData(226, new Map<string, LuaTable>([["MinidoracatEconomy", {
      meta: { realmId: "realm-test", epoch: "1000", seq: 2, history: {} },
      wallets: { alice: { survivor: { available: max, reserved: 0 } }, bob: { survivor: { available: max, reserved: 0 } },
        "MOD:a": { survivor: { available: -max, reserved: 0 } }, "MOD:b": { survivor: { available: -max, reserved: 0 } } },
    }]])));
    const report = buildDailyReport(await readReportSource(f.options), { date: day, timeZone: "UTC", ...reportPeriod(day, "UTC") });
    assert.equal(report.totals[0]?.issued, null);
    assert.ok(report.issues.some((i) => i.currency === "survivor"));
  } finally { fs.rmSync(f.root, { recursive: true, force: true }); }
});

test("report: corrupt UTF-8 in the save cannot supply a trusted watermark", async () => {
  const f = fixture();
  try {
    f.writeEvents([f.start, f.mint]);f.save(1, 100);
    const bytes = fs.readFileSync(f.modDataBin);
    const offset = bytes.indexOf(Buffer.from("alice"));
    assert.ok(offset >= 0);
    bytes[offset] = 0xff;
    fs.writeFileSync(f.modDataBin, bytes);
    const source = await readReportSource(f.options);
    assert.equal(source.watermark, null);
    assert.ok(source.issues.some((i) => i.file === "global_mod_data.bin"));
  } finally { fs.rmSync(f.root, { recursive: true, force: true }); }
});

test("report: account and currency separators cannot merge distinct wallets", async () => {
  const f = fixture();
  try {
    const rows = [
      { ...posting("a\u0000b", 5, 0, 5), currency: "c" },
      { ...posting("MOD:x", -5, 0, -5), currency: "c" },
      { ...posting("a", 7, 0, 7), currency: "b\u0000c" },
      { ...posting("MOD:y", -7, 0, -7), currency: "b\u0000c" },
    ];
    f.writeEvents([f.start, tx("1000", 1, rows)]);
    fs.writeFileSync(f.modDataBin, encodeGlobalModData(226, new Map<string, LuaTable>([["MinidoracatEconomy", {
      meta: { realmId: "realm-test", epoch: "1000", seq: 1, history: {} },
      wallets: { ["a\u0000b"]: { c: { available: 5, reserved: 0 } }, a: { ["b\u0000c"]: { available: 7, reserved: 0 } },
        "MOD:x": { c: { available: -5, reserved: 0 } }, "MOD:y": { ["b\u0000c"]: { available: -7, reserved: 0 } } },
    }]])));
    const source = await readReportSource(f.options);
    const report = buildDailyReport(source, { date: day, timeZone: "UTC", ...reportPeriod(day, "UTC") });
    assert.equal(source.transactions[0]?.valid, true);
    assert.deepEqual(report.totals.map((t) => [t.currency, t.issued]).sort(), [["b\u0000c", 7], ["c", 5]]);
    assert.deepEqual(report.issues, []);
  } finally { fs.rmSync(f.root, { recursive: true, force: true }); }
});

test("report: valid JSON does not hide a missing or uncorroborated journal startup", async () => {
  const f = fixture();
  try {
    const b = { ...f.start, epoch: "2000", ts: at + 5 };
    const c = { ...f.start, epoch: "3000", seq: 5, loadedSeq: 5, ts: at + 10 };
    f.save(5, 100, 0, "3000");
    f.writeEvents([f.start, f.mint, b, c]);
    fs.writeFileSync(path.join(f.economyDir, "epochs.json"), '{"epoch":"1000","loadedSeq":0}\n{"epoch":"3000","loadedSeq":5}\n');
    const missing = await readReportSource(f.options);
    assert.equal(missing.transactions.find((t) => t.txId === "1000:1")?.status, "unknown");
    assert.equal(missing.epochOrder, undefined);
    f.writeEvents([f.start, f.mint, c]);
    fs.writeFileSync(path.join(f.economyDir, "epochs.json"), '{"epoch":"1000","loadedSeq":0}\n{"epoch":"2000","loadedSeq":0}\n{"epoch":"3000","loadedSeq":5}\n');
    const unseen = await readReportSource(f.options);
    assert.equal(unseen.transactions.find((t) => t.txId === "1000:1")?.status, "unknown");
    assert.equal(unseen.epochOrder, undefined);
  } finally { fs.rmSync(f.root, { recursive: true, force: true }); }
});

test("report: unknown epoch order cannot turn an older wallet into a claimed latest snapshot", async () => {
  const f = fixture();
  try {
    f.writeEvents([f.start, f.mint]);
    const priorDate = Date.parse("2024-12-31T04:00:00Z");
    const paid = { ...tx("2000", 2, [posting("alice", -10, 100, 90), posting("SYSTEM_BURN", 10, 0, 10)]), ts: priorDate + 2 };
    const foreign = { ...tx("50", 1, [posting("MOD:x", -5, 0, -5), posting("other", 5, 0, 5)]), realmId: "foreign", ts: priorDate + 3 };
    f.writeEvents([{ ...f.start, epoch: "2000", seq: 1, loadedSeq: 1, ts: priorDate }, paid, foreign], "2024-12-31");
    fs.appendFileSync(path.join(f.economyDir, "epochs.json"), '{"epoch":"2000","loadedSeq":1}\n');
    f.save(2, 90, 0, "2000", { 1: { epoch: "1000", loadedSeq: 1 } }, 10);
    const source = await readReportSource(f.options);
    assert.equal(source.epochOrder, undefined);
    const report = buildDailyReport(source, { date: day, timeZone: "UTC", ...reportPeriod(day, "UTC") });
    assert.equal(report.issues.some((i) => i.code === "snapshot_mismatch"), false);
    assert.equal(report.coverage.complete, false);
  } finally { fs.rmSync(f.root, { recursive: true, force: true }); }
});

test("report: a parseable save without proven realm is not a wallet comparison source", async () => {
  const f = fixture();
  try {
    f.writeEvents([f.start, f.mint, { ...f.start, epoch: "2000", seq: 1, loadedSeq: 1, ts: at + 5 }]);
    fs.appendFileSync(path.join(f.economyDir, "epochs.json"), '{"epoch":"2000","loadedSeq":1}\n');
    fs.writeFileSync(f.modDataBin, encodeGlobalModData(226, new Map<string, LuaTable>([["MinidoracatEconomy", {
      meta: { epoch: "2000", seq: 1, history: {} }, wallets: { alice: { survivor: { available: 999, reserved: 0 } } },
    }]])));
    const source = await readReportSource(f.options);
    assert.equal(source.watermark, null);
    assert.equal(source.wallets.size, 0);
    const report = buildDailyReport(source, { date: day, timeZone: "UTC", ...reportPeriod(day, "UTC") });
    assert.equal(report.issues.some((i) => i.code.startsWith("snapshot_")), false);
    assert.equal(report.coverage.complete, false);
  } finally { fs.rmSync(f.root, { recursive: true, force: true }); }
});

test("report: later startup proof cannot make an earlier bin contain a newer wallet", async () => {
  const f = fixture();
  try {
    const newWallet = tx("1000", 2, [posting("SYSTEM_ADJUST", -50, 0, -50), posting("bob", 50, 0, 50)], "admin_adjust");
    f.writeEvents([f.start, f.mint, newWallet, { ...f.start, epoch: "2000", seq: 2, loadedSeq: 2, ts: at + 5 }]);
    fs.appendFileSync(path.join(f.economyDir, "epochs.json"), '{"epoch":"2000","loadedSeq":2}\n');
    f.save(1, 100);
    const report = buildDailyReport(await readReportSource(f.options), { date: day, timeZone: "UTC", ...reportPeriod(day, "UTC") });
    assert.equal(report.statusCounts.durable, 2);
    assert.equal(report.issues.some((i) => i.code.startsWith("snapshot_")), false);
    assert.ok(report.coverage.issues.some((i) => i.account === "bob" && i.code.startsWith("snapshot_")));
  } finally { fs.rmSync(f.root, { recursive: true, force: true }); }
});
