--[[
煙霧測試：用假的 PZ 全域載入**真正的** MOD Lua，跑行為情境並斷言結果。

    lua scripts/smoke_harness.lua        （repo 根目錄執行；標準 Lua 5.x 即可；verify_mod.py 第 14 項自動跑）

為什麼需要（兩類 luac -p 抓不到的錯誤，皆為正式服實際事故）：
- 改函式簽章漏改呼叫點：語法完全合法，要等該路徑真的執行才炸
- 邏輯回歸：安全把關（範圍／阻隔／保護規則）被改壞時，「執行到並斷言」是唯一防線

限制（必須誠實面對）：這是標準 Lua，不是遊戲的 Kahlua。
- 標準 Lua 有 next/assert/xpcall，Kahlua 沒有——本 harness **測不出**誤用，
  那由 scripts/verify_mod.py 的靜態掃描負責（發版前兩者都要跑）
- Kahlua 專屬行為（Java instance field 不暴露、rawget 呼叫形式、非 ASCII 字面值截斷、
  每個 table 都是 LinkedHashMap 的記憶體成本）只能靠反編譯查證與實機測試

寫情境的原則：
- 情境要「執行到會炸的路徑」——刪除後的收尾、跨 tick 的第二輪、聚合輸出，都是重災區
- 安全邊界要有**反面**斷言（範圍外／被阻隔／受保護的對象必須存活），不是只測 happy path
- 新防線寫完先「植入違規證明它會抓」再信任它——測不出來的測試等於沒有測試
- 不得用「無條件記錄的 command stub」製造假綠：假 sendServerCommand 只記錄，斷言要看內容
]]

local MEDIA = "MOD/MinidoracatEconomyFor42/Contents/mods/MinidoracatEconomyFor42/42/media/lua"

-- ===== 假的 PZ 全域 =====
local nowMs = 5000000            -- 起始要夠大：節流邏輯常寫 now - last < interval
local logLines = {}
local sentCommands = {}          -- sendServerCommand 紀錄：{ player=, module=, command=, args= }
local modDataStore = {}          -- ModData.getOrCreate 的持久表（跨「重啟」保留＝模擬已存檔）

function getTimestampMs() return nowMs end
function isClient() return false end
function isServer() return true end
function writeLog(_, text) logLines[#logLines + 1] = text end
function getText(key) return key end
function print(...) end          -- 受測碼的 log 走 print；harness 靜音，需要時改回

ModData = {
    getOrCreate = function(key)
        modDataStore[key] = modDataStore[key] or {}
        return modDataStore[key]
    end,
    exists = function(key) return modDataStore[key] ~= nil end,
}

SandboxVars = { MinidoracatEconomy = { RemoteReadOnly = true, AdminRoles = "admin;gm", ReadOnlyRoles = "moderator" } }

function sendServerCommand(player, module, command, args)
    sentCommands[#sentCommands + 1] = { player = player, module = module, command = command, args = args }
end

local events = {}
Events = setmetatable({}, {
    __index = function(_, name)
        events[name] = events[name] or {}
        return {
            Add = function(fn) table.insert(events[name], fn) end,
            Remove = function(fn)
                for i = #events[name], 1, -1 do
                    if events[name][i] == fn then table.remove(events[name], i) end
                end
            end,
        }
    end,
})

-- 假檔案系統：getFileWriter(path, createIfNull, append)；append=false 即截斷
local files = {}
local writerDeny = {}            -- path -> true 時回 nil（模擬開檔失敗）
function getFileWriter(path, createIfNull, append)
    if writerDeny[path] then return nil end
    local f = files[path]
    if not f or not append then
        f = { lines = {}, opens = (f and f.opens or 0) }
        files[path] = f
    end
    f.opens = f.opens + 1
    return {
        writeln = function(_, line) f.lines[#f.lines + 1] = line end,
        write = function(_, s) f.lines[#f.lines + 1] = s end,
        close = function() end,
    }
end
local function fire(name, ...)
    for _, fn in ipairs(events[name] or {}) do fn(...) end
end

local function fakePlayer(username)
    return { getUsername = function() return username end }
end

-- ===== 載入受測程式碼（shared → server；client 檔不在 server 端載入）=====
local loaded = {}
function require(name)
    if loaded[name] then return true end
    loaded[name] = true
    for _, dir in ipairs({ "shared", "server", "client" }) do
        local chunk = loadfile(MEDIA .. "/" .. dir .. "/" .. name .. ".lua")
        if chunk then chunk() return true end
    end
    error("require not found: " .. name)
end
require("MinidoracatEconomy/ECCore")
require("MinidoracatEconomy/ECServer")
require("MinidoracatEconomy/ECLedger")
require("MinidoracatEconomy/ECExport")
local EC = MinidoracatEconomy
local S = EC.Server
local L = EC.Ledger
local X = EC.Export

-- ===== 測試工具 =====
local failures, assertions = 0, 0
local EXPECTED_ASSERTIONS = 77     -- 家族慣例：條數守門，防整段被註解仍全綠
local function check(ok, label)
    assertions = assertions + 1
    if ok then io.write("  PASS  ", label, "\n")
    else failures = failures + 1; io.write("  FAIL  ", label, "\n") end
end
local function lastSent(command)
    for i = #sentCommands, 1, -1 do
        if sentCommands[i].command == command then return sentCommands[i] end
    end
    return nil
end

-- ===== 情境一：啟動、握手、meta =====
io.write("scenario 1: server start + hello handshake\n")
fire("OnServerStarted")
local md = S.modData()
check(md ~= nil and md.schemaVersion == EC.SCHEMA_VERSION, "ModData root created with schemaVersion")
check(type(md.meta.epoch) == "string" and md.meta.seq == 0 and md.meta.loadedSeq == 0, "fresh meta: epoch string, seq=0, loadedSeq=0")
local epoch1 = md.meta.epoch

local alice = fakePlayer("alice")
fire("OnClientCommand", EC.COMMAND_MODULE, "hello", alice, {})
local ack = lastSent("hello.ack")
check(ack ~= nil and ack.player == alice and ack.module == EC.COMMAND_MODULE, "hello -> hello.ack sent to the same player on our module")
check(ack and ack.args.epoch == epoch1 and ack.args.loadedSeq == 0 and ack.args.schemaVersion == EC.SCHEMA_VERSION, "hello.ack carries epoch/loadedSeq/schemaVersion")
check(ack and ack.args.remoteReadOnly == true, "hello.ack reflects sandbox RemoteReadOnly")

-- 其他 module 的指令不得被處理；未知指令不得回覆
local before = #sentCommands
fire("OnClientCommand", "SomeOtherMod", "hello", alice, {})
fire("OnClientCommand", EC.COMMAND_MODULE, "no.such.command", alice, {})
check(#sentCommands == before, "foreign module / unknown command produce no reply")

-- ===== 情境二：節流（同人同指令 500 ms 內第二次被丟棄；不同人不受影響）=====
io.write("scenario 2: per-player command throttle\n")
before = #sentCommands
fire("OnClientCommand", EC.COMMAND_MODULE, "hello", alice, {})
check(#sentCommands == before, "second hello within cooldown is dropped")
local bob = fakePlayer("bob")
fire("OnClientCommand", EC.COMMAND_MODULE, "hello", bob, {})
check(#sentCommands == before + 1 and lastSent("hello.ack").player == bob, "another player is not throttled by alice")
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "hello", alice, {})
check(#sentCommands == before + 2, "after cooldown the same player is served again")

-- handler 拋錯不得讓 dispatch 炸掉、也不得回覆
S.handlers["boom"] = function() error("handler exploded") end
before = #sentCommands
local okDispatch = pcall(fire, "OnClientCommand", EC.COMMAND_MODULE, "boom", bob, {})
check(okDispatch and #sentCommands == before, "handler error is contained (pcall) and produces no reply")
S.handlers["boom"] = nil

-- ===== 情境三：seq 單調、重啟後 epoch 換新而 seq 延續（模擬已存檔）=====
io.write("scenario 3: seq across restart (saved state)\n")
local id1 = S.newId()
local id2 = S.newId()
local e1, s1 = EC.parseId(id1)
local e2, s2 = EC.parseId(id2)
check(e1 == epoch1 and s1 == 1 and e2 == epoch1 and s2 == 2, "newId yields <epoch>:<seq> with monotonic seq")
check(md.meta.seq == 2, "meta.seq advanced to 2")
S.bumpSeq(5)
check(md.meta.seq == 5, "bumpSeq raises seq to a higher pending seq (rule four)")
S.bumpSeq(3)
check(md.meta.seq == 5, "bumpSeq never lowers seq")

nowMs = nowMs + 1000
fire("OnServerStarted")                       -- 同一份 modDataStore ＝ 世界已存檔後重啟
local md2 = S.modData()
check(md2 == md, "restart reuses the persisted ModData table")
check(md2.meta.epoch ~= epoch1, "restart gets a new epoch")
check(md2.meta.seq == 5 and md2.meta.loadedSeq == 5, "restart keeps seq and sets loadedSeq to it (rollback point)")
local id3 = S.newId()
local e3, s3 = EC.parseId(id3)
check(e3 == md2.meta.epoch and s3 == 6, "ids after restart continue from loadedSeq under the new epoch")
check(id3 ~= id1 and EC.parseId("bad") == nil and EC.parseId("x:") == nil, "parseId rejects malformed ids")

-- ===== 情境四：回滾分支（未存檔就崩潰：ModData 回到舊快照）=====
io.write("scenario 4: rollback branch never collides on ids\n")
modDataStore[EC.MODDATA_KEY] = { schemaVersion = 1, meta = { epoch = "old", seq = 2, loadedSeq = 0 } }
nowMs = nowMs + 1000
fire("OnServerStarted")
local md3 = S.modData()
check(md3.meta.loadedSeq == 2 and md3.meta.seq == 2, "after rollback loadedSeq equals the saved seq")
local idAfterRollback = S.newId()
check(idAfterRollback ~= id3 and select(2, EC.parseId(idAfterRollback)) == 3, "seq restarts from the saved point but the epoch differs, so the id cannot collide")

-- ===== 情境五：核心工具 =====
io.write("scenario 5: core helpers\n")
local list = { 5, 3, 9, 1, 3 }
EC.sortSafe(list, function(a, b) return a < b end)
check(table.concat(list, ",") == "1,3,3,5,9", "sortSafe sorts (stable insertion sort, no table.sort)")
local roles = EC.roleSet(" Admin; gm ;;")
check(roles.admin and roles.gm and not roles.moderator, "roleSet parses ';'-separated names case-insensitively")
check(EC.sandbox("AdminRoles", "admin") == "admin;gm" and EC.sandbox("NoSuchKey", 7) == 7 and EC.sandbox("RemoteReadOnly", "x") == "x", "sandbox returns value, default when missing, default when wrong type")
check(EC.countKeys({ a = 1, b = 2 }) == 2 and EC.CURRENCIES.survivor.marketUnit == true and EC.CURRENCIES.cat.marketUnit == false, "currency registry static half")

-- ===== 情境六：帳本 post／守恆／餘額鏈 =====
io.write("scenario 6: ledger post, conservation, balance chain\n")
modDataStore[EC.MODDATA_KEY] = nil          -- 全新世界
fire("OnServerStarted")
local root = S.modData()
check(root.wallets ~= nil and root.idempotency ~= nil and root.receipts ~= nil, "ledger init created wallets/idempotency/receipts tables")
local events = {}
L.onCommitted(function(ev) events[#events + 1] = ev end)

local r1 = L.credit("alice", "survivor", 30, "SYSTEM_MINT", { requestId = "checkin-1", reasonCode = "daily_checkin", kind = "checkin" })
check(r1.ok and r1.duplicate == false and select(2, EC.parseId(r1.txId)) == r1.seq, "credit returns ok with a <epoch>:<seq> txId")
check(L.getBalance("alice", "survivor").available == 30 and L.getBalance("SYSTEM_MINT", "survivor").available == -30, "player +30, SYSTEM_MINT -30")
check(L.conservation("survivor") == 0, "conservation: sum over all accounts is 0")
check(#events == 1 and events[1].txId == r1.txId and #events[1].postings == 2 and events[1].postings[1].availableBefore == 0 and events[1].postings[1].availableAfter == 30, "committed event carries postings with before/after")

local r2 = L.credit("alice", "survivor", 30, "SYSTEM_MINT", { requestId = "checkin-1", reasonCode = "daily_checkin", kind = "checkin" })
check(r2.ok and r2.duplicate == true and r2.txId == r1.txId and L.getBalance("alice", "survivor").available == 30, "same requestId is idempotent: same txId, no double credit")
check(#events == 1, "duplicate does not emit a second event")

local r3 = L.debit("alice", "survivor", 50, "SYSTEM_TAX", { requestId = "tax-1", reasonCode = "test" })
check(not r3.ok and r3.error == "insufficient_funds" and L.getBalance("alice", "survivor").available == 30, "debit beyond balance is rejected with zero change")
local r4 = L.debit("alice", "survivor", 10, "SYSTEM_TAX", { requestId = "tax-2", reasonCode = "test" })
check(r4.ok and L.getBalance("alice", "survivor").available == 20 and L.getBalance("alice", "survivor").rev == 2, "debit succeeds and wallet rev increments per posting")

local rec = L.receipts("alice")
check(#rec == 2 and rec[1].before == 0 and rec[1].after == 30 and rec[2].before == 30 and rec[2].after == 20, "receipts are oldest-first with a continuous before/after chain")
check(rec[1].counterparty == "SYSTEM_MINT" and rec[2].counterparty == "SYSTEM_TAX", "receipt counterparty is the other side of the same currency")
check(L.receipts("SYSTEM_MINT")[1] == nil, "system accounts keep no receipt ring")

-- ===== 情境七：驗證拒絕（零變動）=====
io.write("scenario 7: validation rejects with zero change\n")
local function balanceSnapshot()
    return L.getBalance("alice", "survivor").available .. "/" .. L.getBalance("SYSTEM_MINT", "survivor").available
end
local snap = balanceSnapshot()
local bad = {}
bad[#bad + 1] = L.post({ kind = "x", requestId = "u-1", reasonCode = "t", postings = { { account = "alice", currency = "survivor", amount = 5 } } })
bad[#bad + 1] = L.post({ kind = "x", requestId = "u-2", reasonCode = "t", postings = { { account = "alice", currency = "nope", amount = 5 }, { account = "SYSTEM_MINT", currency = "nope", amount = -5 } } })
bad[#bad + 1] = L.post({ kind = "x", requestId = "u-3", reasonCode = "t", postings = { { account = "alice", currency = "survivor", amount = 1.5 }, { account = "SYSTEM_MINT", currency = "survivor", amount = -1.5 } } })
bad[#bad + 1] = L.post({ kind = "x", requestId = "u-4", reasonCode = "t", postings = { { account = "alice", currency = "survivor", amount = 0 }, { account = "SYSTEM_MINT", currency = "survivor", amount = 0 } } })
bad[#bad + 1] = L.post({ kind = "x", reasonCode = "t", postings = { { account = "alice", currency = "survivor", amount = 5 }, { account = "SYSTEM_MINT", currency = "survivor", amount = -5 } } })
bad[#bad + 1] = L.post({ kind = "x", requestId = "u-6", reasonCode = "t", postings = { { account = "alice", currency = "survivor", amount = 5 }, { account = "alice", currency = "survivor", amount = -5 } } })
check(bad[1].error == "unbalanced", "unbalanced postings rejected")
check(bad[2].error == "unknown_currency", "unknown currency rejected")
check(bad[3].error == "invalid_args" and bad[4].error == "invalid_args", "non-integer and zero amounts rejected")
check(bad[5].error == "invalid_args", "missing requestId rejected")
check(bad[6].error == "invalid_args", "two postings on the same account+currency rejected")
check(balanceSnapshot() == snap and #events == 2, "no balance change and no event from any rejected post")

root.config.currencies.cat = { enabled = false }
local d1 = L.credit("alice", "cat", 5, "EXTERNAL_DISCORD_cat", { requestId = "cat-1", reasonCode = "t" })
check(d1.error == "currency_disabled", "disabled currency cannot be credited to a player")
root.config.currencies.cat = nil
local d2 = L.credit("alice", "cat", 5, "EXTERNAL_DISCORD_cat", { requestId = "cat-1", reasonCode = "t" })
check(d2.ok, "failed requestId was not cached: the retry after enabling succeeds")
root.config.currencies.cat = { enabled = false }
local d3 = L.debit("alice", "cat", 5, "SYSTEM_TAX", { requestId = "cat-2", reasonCode = "t" })
check(d3.ok and L.getBalance("alice", "cat").available == 0, "disabled currency can still be debited (spend/refund allowed)")
root.config.currencies.cat = nil

root.frozen["alice"] = { by = "admin", at = nowMs }
local f1 = L.credit("alice", "survivor", 5, "SYSTEM_MINT", { requestId = "fz-1", reasonCode = "t" })
local f2 = L.credit("alice", "survivor", 5, "SYSTEM_MINT", { requestId = "fz-2", reasonCode = "t", allowFrozen = true })
check(f1.error == "account_frozen" and f2.ok, "frozen account rejects new transactions unless allowFrozen (existing obligations)")
root.frozen["alice"] = nil

local rv = L.credit("alice", "survivor", 5, "SYSTEM_MINT", { requestId = "rev-1", reasonCode = "t", expectedRev = 1 })
check(rv.error == "revision_mismatch", "expectedRev mismatch rejected (admin adjust safety)")
local cur = L.getBalance("alice", "survivor").rev
local rv2 = L.credit("alice", "survivor", 5, "SYSTEM_MINT", { requestId = "rev-2", reasonCode = "t", expectedRev = cur })
check(rv2.ok, "expectedRev matching current rev succeeds")

-- ===== 情境八：收據環與冪等 LRU 上界 =====
io.write("scenario 8: bounded rings\n")
for i = 1, 8 do
    L.credit("bob", "survivor", i, "SYSTEM_MINT", { requestId = "bob-" .. i, reasonCode = "t" })
end
local bobRec = L.receipts("bob")
check(#bobRec == L.RECEIPT_RING and bobRec[1].amount == 4 and bobRec[5].amount == 8, "receipt ring keeps only the newest RECEIPT_RING entries, oldest first")
check(L.getBalance("bob", "survivor").available == 36, "bob balance is the sum of all 8 credits")

local saveMax = L.IDEMPOTENCY_MAX
L.IDEMPOTENCY_MAX = 3
root.idempotency = { keys = {}, head = 1, count = 0, map = {} }
for i = 1, 5 do
    L.credit("carol", "survivor", 1, "SYSTEM_MINT", { requestId = "c-" .. i, reasonCode = "t" })
end
check(root.idempotency.count == 3 and root.idempotency.map["c-1"] == nil and root.idempotency.map["c-5"] ~= nil, "idempotency LRU evicts the oldest beyond IDEMPOTENCY_MAX")
local again = L.credit("carol", "survivor", 1, "SYSTEM_MINT", { requestId = "c-1", reasonCode = "t" })
check(again.ok and again.duplicate == false and L.getBalance("carol", "survivor").available == 6, "an evicted requestId is no longer deduplicated (documented window; requestId carries a timestamp upstream)")
L.IDEMPOTENCY_MAX = saveMax

-- ===== 情境九：跨重啟保留＋守恆 =====
io.write("scenario 9: ledger state survives restart and stays conserved\n")
nowMs = nowMs + 1000
fire("OnServerStarted")
check(L.getBalance("alice", "survivor").available == 30 and L.getBalance("bob", "survivor").available == 36, "balances persist across restart (same saved table)")
check(L.conservation("survivor") == 0 and L.conservation("cat") == 0, "conservation holds for every currency after all scenarios")
check(L.sizeEstimate() > 0, "size estimate is computed from counts")

-- listener 例外不得影響 commit
L.onCommitted(function() error("listener boom") end)
local lb = L.credit("alice", "survivor", 1, "SYSTEM_MINT", { requestId = "lb-1", reasonCode = "t" })
check(lb.ok and L.getBalance("alice", "survivor").available == 31, "a throwing listener does not roll back or block the commit")

-- ===== 情境十：啟動即寫 header／server.started／heartbeat =====
io.write("scenario 10: export on start\n")
modDataStore[EC.MODDATA_KEY] = nil
files = {}
nowMs = 1788699986478                      -- 2026-09-06 UTC
fire("OnServerStarted")
local root2 = S.modData()
local evPath = X.eventsPath(nowMs)
check(evPath == "MinidoracatEconomy/events-20260906.json", "events file is named by UTC day under the mod root")
local ev = files[evPath]
check(ev and #ev.lines == 2 and string.find(ev.lines[1], '"type":"file.header"', 1, true) and string.find(ev.lines[1], '"startedSeq":0', 1, true), "first line is file.header with startedSeq")
check(ev and string.find(ev.lines[2], '"type":"server.started"', 1, true) and string.find(ev.lines[2], '"epoch":"' .. root2.meta.epoch .. '"', 1, true), "second line is server.started carrying the epoch")
local hb = files["MinidoracatEconomy/heartbeat.json"]
check(hb and #hb.lines == 1 and string.find(hb.lines[1], '"realmId":"' .. root2.meta.realmId .. '"', 1, true), "heartbeat.json has one line with the realmId")
check(string.find(ev.lines[1], '"realmId":"realm-', 1, true) ~= nil, "realmId is generated once and stamped on file lines")

-- ===== 情境十一：交易 → 事件行＋收據行 =====
io.write("scenario 11: tx.committed event and receipt lines\n")
local rc = L.credit("Mini doracat[1]", "survivor", 30, "SYSTEM_MINT", { requestId = "x-1", reasonCode = "daily_checkin", kind = "checkin" })
check(rc.ok and #ev.lines == 2, "commit only queues; nothing is written before the tick")
fire("OnTickEvenPaused")
check(#ev.lines == 3 and string.find(ev.lines[3], '"type":"tx.committed"', 1, true) and string.find(ev.lines[3], '"txId":"' .. rc.txId .. '"', 1, true) and string.find(ev.lines[3], '"availableAfter":30', 1, true), "tick writes the tx.committed line with postings")
local rp = X.receiptsPath("Mini doracat[1]", nowMs)
check(rp == "MinidoracatEconomy/receipts/Mini_x0020_doracat_x005b_1_x005d_/202609.json", "receipt path uses the safe account name and UTC month")
local rf = files[rp]
check(rf and #rf.lines == 1 and string.find(rf.lines[1], '"availableBefore":0', 1, true) and string.find(rf.lines[1], '"counterparty":"SYSTEM_MINT"', 1, true) and string.find(rf.lines[1], '"delta":30', 1, true), "receipt line carries before/after/counterparty")
check(files[X.receiptsPath("SYSTEM_MINT", nowMs)] == nil, "system accounts get no receipt file")
check(X.queuedLines() == 0, "queue drained")

-- ===== 情境十二：每 tick 行數上限 =====
io.write("scenario 12: per-tick line budget\n")
for i = 1, 60 do
    L.credit("bulk", "survivor", 1, "SYSTEM_MINT", { requestId = "bulk-" .. i, reasonCode = "t" })
end
check(X.queuedLines() == 120, "60 credits queue 120 lines (event + receipt each)")
local beforeLines = #ev.lines
fire("OnTickEvenPaused")
check(X.queuedLines() == 70 and #ev.lines == beforeLines + 50, "one tick writes exactly MAX_LINES_PER_TICK lines, oldest file first")
fire("OnTickEvenPaused"); fire("OnTickEvenPaused")
check(X.queuedLines() == 0 and #files[X.receiptsPath("bulk", nowMs)].lines == 60, "queue drains over the following ticks; every receipt landed")

-- ===== 情境十三：日切、心跳、寫檔失敗不卡佇列 =====
io.write("scenario 13: day rollover, heartbeat, writer failure\n")
nowMs = nowMs + 86400000
fire("OnTickEvenPaused")
local ev2 = files[X.eventsPath(nowMs)]
check(X.eventsPath(nowMs) == "MinidoracatEconomy/events-20260907.json" and ev2 and #ev2.lines == 1 and string.find(ev2.lines[1], '"type":"file.header"', 1, true), "day change opens the next file with a header")
check(#hb.lines == 1 and string.find(files["MinidoracatEconomy/heartbeat.json"].lines[1], '"ts":' .. string.format("%.0f", nowMs), 1, true) and files["MinidoracatEconomy/heartbeat.json"].opens >= 2, "heartbeat rewritten (truncate) once the interval passed")

writerDeny[X.eventsPath(nowMs)] = true
local bulkBefore = #files[X.receiptsPath("bulk", nowMs)].lines
L.credit("bulk", "survivor", 1, "SYSTEM_MINT", { requestId = "deny-1", reasonCode = "t" })
fire("OnTickEvenPaused")
check(X.queuedLines() == 0 and #files[X.receiptsPath("bulk", nowMs)].lines == bulkBefore + 1 and #ev2.lines == 1, "a failing target is dropped and logged, the receipt file is still written")
writerDeny[X.eventsPath(nowMs)] = nil

X.emit("ledger.anomaly", { account = "bulk", kind = "test" })
X.audit({ action = "adjust", admin = "root", target = "bulk", reason = "unit test reason" })
fire("OnTickEvenPaused")
local au = files[X.auditPath(nowMs)]
check(au and #au.lines == 1 and string.find(au.lines[1], '"type":"audit"', 1, true) and string.find(ev2.lines[#ev2.lines], '"type":"audit"', 1, true), "audit goes to audit/YYYYMM.json and to the event stream")
check(string.find(ev2.lines[#ev2.lines - 1], '"type":"ledger.anomaly"', 1, true) ~= nil, "emit writes a generic event line")

-- ===== 情境十四：重啟後同日續寫（再一個 header）=====
io.write("scenario 14: restart on the same day appends a new header\n")
nowMs = nowMs + 1000
fire("OnServerStarted")
local n2 = #ev2.lines
check(string.find(ev2.lines[n2 - 1], '"type":"file.header"', 1, true) and string.find(ev2.lines[n2], '"type":"server.started"', 1, true) and string.find(ev2.lines[n2], '"loadedSeq":' .. string.format("%.0f", S.modData().meta.loadedSeq), 1, true), "restart appends file.header + server.started with loadedSeq")

io.write("\n")
if assertions ~= EXPECTED_ASSERTIONS then
    io.write("assertion count ", assertions, " != expected ", EXPECTED_ASSERTIONS, " (update EXPECTED_ASSERTIONS deliberately)\n")
    failures = failures + 1
end
if failures > 0 then
    io.write(failures, " failure(s)\n")
    os.exit(1)
end
io.write("all ", assertions, " assertions passed\n")
