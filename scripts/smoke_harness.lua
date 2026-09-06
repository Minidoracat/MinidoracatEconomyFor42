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

-- getMyDocumentFolder：專用伺服器上是 cachedir 絕對路徑（LuaManager.java:8835-8837）。
-- docFolder = nil 用來模擬「引擎沒給路徑」，受測碼不得改用相對路徑假裝絕對路徑。
local docFolder = "C:/fake/Zomboid"
function getMyDocumentFolder() return docFolder end

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

-- java 風格清單（size()/get(i)，0-based）——PZ 回傳的容器幾乎都是這個形狀
local function javaList(items)
    return { size = function() return #items end, get = function(_, i) return items[i + 1] end }
end
local onlinePlayers = {}
function getOnlinePlayers() return javaList(onlinePlayers) end

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
function getFileReader(path, createIfNull)
    local f = files[path]
    if not f then return nil end
    local i = 0
    return {
        readLine = function() i = i + 1; return f.lines[i] end,
        close = function() end,
    }
end
-- 假二進位檔：getFileInput(path) 回 DataInputStream 形狀（available／read／close）
binFiles = {}                    -- path -> byte string（全域：主函式已逼近 200 個 local）
function getFileInput(path)
    local data = binFiles[path]
    if not data then return nil end
    local pos = 0
    return {
        available = function() return #data - pos end,
        read = function()
            if pos >= #data then return -1 end
            pos = pos + 1
            return string.byte(data, pos)
        end,
        close = function() end,
    }
end

local function fire(name, ...)
    for _, fn in ipairs(events[name] or {}) do fn(...) end
end

local function fakePlayer(username)
    local p = { username = username, x = 100, y = 200, hours = 0 }
    p.getUsername = function() return username end
    p.getX = function() return p.x end
    p.getY = function() return p.y end
    p.getHoursSurvived = function() return p.hours end
    p.role = "user"
    p.getRole = function() return { getName = function() return p.role end } end
    return p
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
require("MinidoracatEconomy/ECConfig")
require("MinidoracatEconomy/ECRewards")
require("MinidoracatEconomy/ECWallet")
require("MinidoracatEconomy/ECIcons")
require("MinidoracatEconomy/ECIntegration")
require("MinidoracatEconomy/ECAdmin")
local EC = MinidoracatEconomy
local S = EC.Server
local L = EC.Ledger
local X = EC.Export
local Cfg = EC.Config
local R = EC.Rewards
local W = EC.Wallet
local A = EC.Admin

-- ===== 測試工具 =====
local failures, assertions = 0, 0
local EXPECTED_ASSERTIONS = 250     -- 家族慣例：條數守門，防整段被註解仍全綠
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


-- ===== 情境十五：貨幣 config（覆寫、停用、匯率版本、廣播、事件）=====
io.write("scenario 15: currency config\n")
modDataStore[EC.MODDATA_KEY] = nil
files = {}
sentCommands = {}
SandboxVars.MinidoracatEconomy.CatRatePointsPerCoin = 2
SandboxVars.MinidoracatEconomy.CatPerOrderMax = 7000
fire("OnServerStarted")
local cat = Cfg.currency("cat")
check(cat.exchange.pointsPerCoin == 2 and cat.exchange.perOrderMax == 7000 and cat.exchange.perOrderMin == 10 and cat.exchange.rateVersion == 1, "first boot seeds the exchange block from sandbox (missing keys use defaults)")
check(Cfg.currency("survivor").exchange == nil and Cfg.currency("survivor").enabled and Cfg.currency("nope") == nil, "market unit has no exchange block; unknown id is nil")
local snapshot = Cfg.snapshot()
check(#snapshot == 2 and snapshot[1].id == "survivor" and snapshot[2].id == "cat" and snapshot[2].balanceMax == Cfg.DEFAULT_BALANCE_MAX, "snapshot lists currencies in registry order with balanceMax")

onlinePlayers = { fakePlayer("alice"), fakePlayer("bob") }
fire("OnClientCommand", EC.COMMAND_MODULE, "hello", onlinePlayers[1], {})
local ack2 = lastSent("hello.ack")
check(ack2 and #ack2.args.currencies == 2 and ack2.args.currencies[2].exchange.pointsPerCoin == 2, "hello.ack carries the currency snapshot")

local ok1, e1 = Cfg.setNameOverride("cat", "Nyan", "root", "rename")
local pushes = 0
for _, s in ipairs(sentCommands) do if s.command == "config" then pushes = pushes + 1 end end
check(ok1 and Cfg.currency("cat").nameOverride == "Nyan" and pushes == 2, "name override applied and pushed to both online players")
fire("OnTickEvenPaused")
local evf = files[X.eventsPath(nowMs)]
local lastEv = evf.lines[#evf.lines]
check(string.find(lastEv, '"type":"audit"', 1, true) and string.find(lastEv, '"field":"nameOverride"', 1, true) and string.find(evf.lines[#evf.lines - 1], '"type":"admin.config"', 1, true), "config change writes admin.config + audit")
check(Cfg.setNameOverride("cat", string.rep("x", 25)) == false and Cfg.setNameOverride("cat", "bad\nname") == false and Cfg.setNameOverride("nope", "x") == false, "name override rejects too long / control chars / unknown currency")
check(Cfg.setNameOverride("cat", "Nyan") == true and Cfg.setNameOverride("cat", "") and Cfg.currency("cat").nameOverride == nil, "same value is a no-op; empty clears the override")

check(Cfg.setEnabled("cat", false, "root", "pause") and L.currency("cat").enabled == false, "disable propagates to the ledger view")
local dis = L.credit("alice", "cat", 5, "EXTERNAL_DISCORD_cat", { requestId = "cfg-1", reasonCode = "t" })
check(dis.error == "currency_disabled" and Cfg.setEnabled("cat", true, "root", "resume"), "disabled currency refuses mint; re-enable works")
check(Cfg.setEnabled("cat", "yes") == false, "enabled must be boolean")

local okx = Cfg.setExchange("cat", { perOrderMax = 9000 }, "root", "raise cap")
check(okx and Cfg.currency("cat").exchange.perOrderMax == 9000 and Cfg.currency("cat").exchange.rateVersion == 2 and Cfg.currency("cat").exchange.pointsPerCoin == 2, "partial exchange update keeps other fields and bumps rateVersion")
check(Cfg.setExchange("cat", { perOrderMax = 9000 }) == true and Cfg.currency("cat").exchange.rateVersion == 2, "no-op exchange update does not bump rateVersion")
check(Cfg.setExchange("cat", { perOrderMin = 10000 }) == false and Cfg.setExchange("cat", { pointsPerCoin = 0 }) == false and Cfg.setExchange("survivor", { pointsPerCoin = 1 }) == false, "exchange rejects min>max, non-positive, and non-exchangeable currency")

root = S.modData()
root.config.currencies.survivor.balanceMax = 100
local capd = L.credit("carol", "survivor", 101, "SYSTEM_MINT", { requestId = "cap-1", reasonCode = "t" })
check(capd.error == "balance_cap" and L.credit("carol", "survivor", 100, "SYSTEM_MINT", { requestId = "cap-2", reasonCode = "t" }).ok, "balanceMax caps player balances (system side unaffected)")
root.config.currencies.survivor.balanceMax = nil

-- 餘額上限：沙盒值是即時讀取的預設，setBalanceMax 是每幣別覆寫；清除回沙盒；壞值拒絕
SandboxVars.MinidoracatEconomy.BalanceMax = 1500
check(Cfg.currency("survivor").balanceMax == 1500 and Cfg.currency("survivor").balanceMaxOverride == nil
    and L.credit("carol", "survivor", 1401, "SYSTEM_MINT", { requestId = "cap-3", reasonCode = "t" }).error == "balance_cap",
    "without an override the ledger reads the sandbox BalanceMax live")
check(Cfg.setBalanceMax("survivor", 999) == false and Cfg.setBalanceMax("survivor", 2000.5) == false
    and Cfg.setBalanceMax("survivor", "2000") == false and Cfg.setBalanceMax("nope", 2000) == false,
    "setBalanceMax refuses below-minimum, fractional, string and unknown-currency values")
check(Cfg.setBalanceMax("survivor", 2000, "root", "raise the fuse") == true and Cfg.currency("survivor").balanceMaxOverride == 2000
    and L.credit("carol", "survivor", 1401, "SYSTEM_MINT", { requestId = "cap-4", reasonCode = "t" }).ok == true,
    "an admin override raises the fuse and is reported as an override in the snapshot")
check(Cfg.setBalanceMax("survivor", nil, "root", "back to default") == true and Cfg.currency("survivor").balanceMax == 1500
    and Cfg.currency("survivor").balanceMaxOverride == nil, "clearing the override falls back to the sandbox default")
SandboxVars.MinidoracatEconomy.BalanceMax = nil

nowMs = nowMs + 1000
fire("OnServerStarted")
check(Cfg.currency("cat").exchange.rateVersion == 2 and Cfg.currency("cat").exchange.perOrderMax == 9000, "restart keeps runtime exchange overrides (sandbox only seeds the first boot)")
onlinePlayers = {}


-- ===== 情境十六：獎勵日與簽到 =====
io.write("scenario 16: reward day, playtime, check-in\n")
modDataStore[EC.MODDATA_KEY] = nil
files = {}
sentCommands = {}
SandboxVars.MinidoracatEconomy.RewardDayResetHour = 4          -- 台灣 04:00 = UTC 20，日鍵是當地日期
SandboxVars.MinidoracatEconomy.RewardTimezoneUTC = 8
SandboxVars.MinidoracatEconomy.CheckinAmount = 30
SandboxVars.MinidoracatEconomy.CheckinMinPlaytimeMinutes = 2
SandboxVars.MinidoracatEconomy.CheckinServerDailyCap = 0
nowMs = 1788699986478                      -- 2026-09-06 ~05:46 UTC = 台灣 13:46 -> reward day 20260906 (換日 台灣 04:00 = 20:00 UTC)
fire("OnServerStarted")
check(R.dayKey(nowMs) == "20260906" and R.dayKey(nowMs + 15 * 3600000) == "20260907", "reward day key is the local date and flips at the configured local hour, not at UTC midnight")
check(R.nextResetMs(nowMs) == 1788724800000, "nextResetMs is the next 20:00 UTC")

local dave = fakePlayer("dave")
onlinePlayers = { dave }
fire("OnClientCommand", EC.COMMAND_MODULE, "rewards.checkin", dave, {})
local r0 = lastSent("rewards.checkin")
check(r0 and r0.args.ok == false and r0.args.error == "not_enough_playtime" and r0.args.playedMs == 0, "check-in before any playtime is refused")

-- 三個 tick，每 60 s 一次；第一個 tick 只取樣位置
for i = 1, 3 do nowMs = nowMs + 60000; dave.x = dave.x + 1; fire("OnTickEvenPaused") end
local st = R.state("dave", nowMs)
check(st.playedMs == 120000 and st.claimed == false, "moving players accrue playtime (first sample excluded)")
nowMs = nowMs + 60000; fire("OnTickEvenPaused")     -- 沒移動：不計
check(R.state("dave", nowMs).playedMs == 120000, "AFK interval (no movement) is not counted")

nowMs = nowMs + 1000
fire("OnClientCommand", EC.COMMAND_MODULE, "rewards.checkin", dave, {})
local r1 = lastSent("rewards.checkin")
check(r1.args.ok == true and r1.args.amount == 30 and r1.args.balance == 30 and L.getBalance("SYSTEM_MINT", "survivor").available == -30, "check-in pays the sandbox amount from SYSTEM_MINT")
nowMs = nowMs + 1000
fire("OnClientCommand", EC.COMMAND_MODULE, "rewards.checkin", dave, {})
check(lastSent("rewards.checkin").args.error == "already_claimed" and L.getBalance("dave", "survivor").available == 30, "second check-in the same reward day is refused")
fire("OnClientCommand", EC.COMMAND_MODULE, "rewards.state", dave, {})
local stc = lastSent("rewards.state").args
check(stc.claimed == true and stc.day == "20260906" and stc.nextResetMs == 1788724800000 and #stc.milestoneList == 5, "rewards.state reports claimed/day/next reset/milestone list")

-- 跨獎勵日：playtime 歸零、可再簽到
nowMs = 1788724800000 + 1000
fire("OnClientCommand", EC.COMMAND_MODULE, "rewards.checkin", dave, {})
check(lastSent("rewards.checkin").args.error == "not_enough_playtime" and R.state("dave", nowMs).playedMs == 0, "new reward day resets playtime; check-in needs playtime again")
for i = 1, 3 do nowMs = nowMs + 60000; dave.x = dave.x + 1; fire("OnTickEvenPaused") end
nowMs = nowMs + 1000
fire("OnClientCommand", EC.COMMAND_MODULE, "rewards.checkin", dave, {})
check(lastSent("rewards.checkin").args.ok == true and L.getBalance("dave", "survivor").available == 60, "check-in works again on the new day")
-- 日鍵回訪（實機踩到：重置時刻 20→0→20 讓同一 requestId 再次出現）：
-- claim 記錄掉了但帳本冪等快取還在 → 必須回 already_claimed、不動錢、不重複計數
local rollBefore = ModData.getOrCreate(EC.MODDATA_KEY).rollups[R.dayKey(nowMs)].checkinCount
ModData.getOrCreate(EC.MODDATA_KEY).claims["dave"].checkinDay = nil
nowMs = nowMs + 1000
fire("OnClientCommand", EC.COMMAND_MODULE, "rewards.checkin", dave, {})
local replay = lastSent("rewards.checkin").args
check(replay.ok == false and replay.error == "already_claimed" and L.getBalance("dave", "survivor").available == 60
    and ModData.getOrCreate(EC.MODDATA_KEY).rollups[R.dayKey(nowMs)].checkinCount == rollBefore
    and R.state("dave", nowMs).claimed == true, "idempotent replay of a paid reward day is reported as already_claimed (no double count, claim mark restored)")

-- 全服保險絲
SandboxVars.MinidoracatEconomy.CheckinServerDailyCap = 40
local erin = fakePlayer("erin")
onlinePlayers = { dave, erin }
for i = 1, 3 do nowMs = nowMs + 60000; erin.x = erin.x + 1; dave.x = dave.x + 1; fire("OnTickEvenPaused") end
nowMs = nowMs + 1000
fire("OnClientCommand", EC.COMMAND_MODULE, "rewards.checkin", erin, {})
check(lastSent("rewards.checkin").args.error == "cap_exceeded" and L.getBalance("erin", "survivor").available == 0, "server daily fuse refuses once the day's total would exceed the cap (claim not consumed)")
SandboxVars.MinidoracatEconomy.CheckinServerDailyCap = 0
nowMs = nowMs + 1000
fire("OnClientCommand", EC.COMMAND_MODULE, "rewards.checkin", erin, {})
check(lastSent("rewards.checkin").args.ok == true, "with the fuse off the same claim succeeds")

-- ===== 情境十七：生存里程碑 =====
io.write("scenario 17: survival milestones\n")
local evCount = function(kind)
    local n = 0
    for _, f in pairs(files) do
        for _, line in ipairs(f.lines) do
            if string.find(line, '"kind":"' .. kind .. '"', 1, true) and string.find(line, '"type":"tx.committed"', 1, true) then n = n + 1 end
        end
    end
    return n
end
dave.hours = 24 * 3 + 1                    -- 3 days survived -> milestones 1 (1d) and 2 (3d)
onlinePlayers = { dave }
nowMs = nowMs + 60000; dave.x = dave.x + 1; fire("OnTickEvenPaused")
fire("OnTickEvenPaused"); fire("OnTickEvenPaused")
check(L.getBalance("dave", "survivor").available == 60 + 100 + 150, "milestones 1 and 3 days paid once (100 + 150)")
local grants = 0
for _, s in ipairs(sentCommands) do if s.command == "milestone.granted" and s.player == dave then grants = grants + 1 end end
check(grants == 2, "player notified once per milestone")
nowMs = nowMs + 60000; dave.x = dave.x + 1; fire("OnTickEvenPaused")
check(L.getBalance("dave", "survivor").available == 310, "already granted milestones are not repeated on later scans")
check(evCount("milestone") == 2 and evCount("checkin") == 3, "events: 2 milestone + 3 checkin tx.committed lines written")

-- 死亡重建：hoursSurvived 歸零，不重發；再活到 7 天只發第 3 個
dave.hours = 0
nowMs = nowMs + 60000; dave.x = dave.x + 1; fire("OnTickEvenPaused")
dave.hours = 24 * 7
nowMs = nowMs + 60000; dave.x = dave.x + 1; fire("OnTickEvenPaused")
check(L.getBalance("dave", "survivor").available == 310 + 250, "new life: only the 7-day milestone is new; 1d/3d are not paid again")

-- 賽季重置：里程碑可重領
S.modData().config.season = "2"
dave.hours = 24 * 2
nowMs = nowMs + 60000; dave.x = dave.x + 1; fire("OnTickEvenPaused")
check(L.getBalance("dave", "survivor").available == 560 + 100, "a new season resets milestone claims (1d paid again under season 2)")

-- 重啟後狀態保留
nowMs = nowMs + 1000
fire("OnServerStarted")
local st2 = R.state("dave", nowMs)
check(st2.claimed == true and st2.milestones > 0 and S.modData().claims.dave.season == "2", "claims survive a restart")
check(L.conservation("survivor") == 0, "conservation still holds after rewards")
onlinePlayers = {}


-- ===== 情境十八：錢包狀態、變動推送、歷史分批讀取、回滾標記 =====
io.write("scenario 18: wallet state, push, history, rolledBack\n")
modDataStore[EC.MODDATA_KEY] = nil
files = {}
sentCommands = {}
nowMs = 1788699986478
fire("OnServerStarted")
local frank = fakePlayer("frank")
onlinePlayers = { frank }
L.credit("frank", "survivor", 40, "SYSTEM_MINT", { requestId = "w-1", reasonCode = "t", kind = "checkin" })
local push = lastSent("wallet.changed")
check(push and push.player == frank and push.args.balances.survivor.available == 40 and push.args.kind == "checkin", "wallet.changed pushed to the online player after a tx")
L.credit("ghost", "survivor", 5, "SYSTEM_MINT", { requestId = "w-2", reasonCode = "t" })
check(lastSent("wallet.changed").player == frank, "offline accounts get no push")
fire("OnClientCommand", EC.COMMAND_MODULE, "wallet.state", frank, {})
local ws = lastSent("wallet.state").args
check(ws.balances.survivor.available == 40 and ws.balances.cat.available == 0 and #ws.receipts == 1 and ws.receipts[1].after == 40 and ws.receipts[1].rolledBack == false and ws.currencies[2] == "cat", "wallet.state has all currencies, receipts with rolledBack=false")

-- 歷史：先把 250 筆寫進當月收據檔（透過真實交易＋tick 沖到檔案）
for i = 1, 250 do L.credit("frank", "survivor", 1, "SYSTEM_MINT", { requestId = "h-" .. i, reasonCode = "t" }) end
for _ = 1, 12 do fire("OnTickEvenPaused") end
local rpath = X.receiptsPath("frank", nowMs)
check(#files[rpath].lines == 251, "251 receipt lines on disk")
fire("OnClientCommand", EC.COMMAND_MODULE, "wallet.history", frank, { month = EC.monthKey(nowMs) })
check(lastSent("wallet.history") == nil or lastSent("wallet.history").args.month ~= EC.monthKey(nowMs), "history is not answered synchronously (batched over ticks)")
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "wallet.history", frank, { month = EC.monthKey(nowMs) })
check(lastSent("wallet.history").args.error == "busy", "a second request while one is running is refused as busy")
fire("OnTickEvenPaused")
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "wallet.history", frank, { month = EC.monthKey(nowMs) })
local h1 = lastSent("wallet.history")
check(h1.args.error == "busy", "after one tick (200 lines) the job is still running")
fire("OnTickEvenPaused")
local h2 = lastSent("wallet.history")
check(h2.args.month == EC.monthKey(nowMs) and h2.args.total == 251 and #h2.args.entries == 200 and h2.args.truncated == true, "second tick finishes: newest 200 of 251 entries, truncated flag")
check(h2.args.entries[1].delta == 1 and h2.args.entries[200].availableAfter == 290 and h2.args.entries[200].rolledBack == false, "entries are oldest-first among the kept window, decoded from JSON")
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "wallet.history", frank, { month = "bad" })
check(lastSent("wallet.history").args.error == "invalid_args", "invalid month rejected")
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "wallet.history", frank, { month = "199001" })
check(lastSent("wallet.history").args.total == 0 and #lastSent("wallet.history").args.entries == 0, "missing month file answers empty immediately")

-- 回滾標記：模擬「世界回到 seq 100 的存檔」後重啟，環裡 seq>100 的收據標 rolledBack
local oldEpoch = S.modData().meta.epoch
S.modData().meta.seq = 100
nowMs = nowMs + 1000
fire("OnServerStarted")
check(S.isRolledBack(oldEpoch, 101) == true and S.isRolledBack(oldEpoch, 100) == false and S.isRolledBack(S.modData().meta.epoch, 5) == false and S.isRolledBack("unknown", 999) == false, "isRolledBack uses the epoch history (seq > loadedSeq of that epoch)")
fire("OnClientCommand", EC.COMMAND_MODULE, "wallet.state", frank, {})
local ws2 = lastSent("wallet.state").args
local flagged = 0
for _, r in ipairs(ws2.receipts) do if r.rolledBack then flagged = flagged + 1 end end
check(#ws2.receipts == 5 and flagged == 5, "receipt ring entries beyond the rollback point are flagged")
onlinePlayers = {}

-- ===== 情境十九：管理員（角色閘門、調帳規則、凍結、設定、稽核環、系統） =====
io.write("scenario 19: admin gate, adjust limits, freeze, config, audit ring, system\n")
modDataStore[EC.MODDATA_KEY] = nil
files = {}
sentCommands = {}
nowMs = 1788699986478
SandboxVars.MinidoracatEconomy.AdminRoles = "admin"
SandboxVars.MinidoracatEconomy.ReadOnlyRoles = "moderator"
SandboxVars.MinidoracatEconomy.AdminAdjustMaxPerTx = 5000
SandboxVars.MinidoracatEconomy.AdminAdjustDailyPerAdmin = 10000
SandboxVars.MinidoracatEconomy.AdminAdjustServerDaily = 12000
SandboxVars.MinidoracatEconomy.AdminReasonMinChars = 10
fire("OnServerStarted")
local boss = fakePlayer("boss"); boss.role = "admin"
local mod = fakePlayer("mod"); mod.role = "moderator"
local joe = fakePlayer("joe")
onlinePlayers = { boss, mod, joe }
L.credit("joe", "survivor", 100, "SYSTEM_MINT", { requestId = "a-seed", reasonCode = "t" })

-- 閘門：一般玩家全拒、moderator 只讀、admin 可寫；server 依角色名重驗，不看 client
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.lookup", joe, { username = "boss" })
check(lastSent("admin.lookup").args.error == "forbidden", "a plain player cannot use admin commands")
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.lookup", mod, { username = "joe" })
local lk = lastSent("admin.lookup").args
check(lk.ok == true and lk.found == true and lk.online == true and lk.balances.survivor.available == 100 and #lk.receipts == 1 and lk.adminToday.cap == 10000 and lk.maxPerTx == 5000, "moderator can look up an account (balances, receipts, limits)")
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.adjust", mod, { username = "joe", currency = "survivor", delta = 10, reason = "moderators cannot write", requestId = "m1" })
check(lastSent("admin.adjust").args.error == "forbidden", "moderator is read-only")

-- 調帳規則：原因長度、自己、系統帳戶、單筆上限、負餘額、rev 不符
-- expectedRev 現在是必填（server 不再用 tonumber 把 nil 當「不檢查」），所以每筆都要帶當下錢包版本
local function adjust(who, args) nowMs = nowMs + 600; fire("OnClientCommand", EC.COMMAND_MODULE, "admin.adjust", who, args); return lastSent("admin.adjust").args end
check(adjust(boss, { username = "joe", currency = "survivor", delta = 10, reason = "short", requestId = "r1", expectedRev = 1 }).error == "reason_too_short", "reason below AdminReasonMinChars is refused")
check(adjust(boss, { username = "boss", currency = "survivor", delta = 10, reason = "paying myself is not allowed", requestId = "r2", expectedRev = 0 }).error == "self_target", "admins cannot adjust their own account")
check(adjust(boss, { username = "SYSTEM_MINT", currency = "survivor", delta = 10, reason = "system accounts are off limits", requestId = "r3", expectedRev = 0 }).error == "invalid_args", "system accounts cannot be targeted")
check(adjust(boss, { username = "nobody", currency = "survivor", delta = 10, reason = "unknown account should fail", requestId = "r4", expectedRev = 0 }).error == "unknown_account", "unknown accounts are refused")
check(adjust(boss, { username = "joe", currency = "survivor", delta = 5001, reason = "over the per-transaction cap", requestId = "r5", expectedRev = 1 }).error == "over_max_per_tx", "per-transaction cap enforced")
check(adjust(boss, { username = "joe", currency = "survivor", delta = -101, reason = "would drive the balance negative", requestId = "r6", expectedRev = 1 }).error == "insufficient_funds", "adjustment cannot make a balance negative")
check(adjust(boss, { username = "joe", currency = "survivor", delta = 10, reason = "stale wallet revision check", requestId = "r7", expectedRev = 99 }).error == "revision_mismatch", "expectedRev mismatch is refused")
local okAdj = adjust(boss, { username = "joe", currency = "survivor", delta = 500, reason = "compensation for lost order", requestId = "r8", expectedRev = 1 })
check(okAdj.ok == true and okAdj.balance == 600 and L.getBalance("SYSTEM_ADJUST", "survivor").available == -500, "a valid adjustment posts SYSTEM_ADJUST <-> player and reports the new balance")
local again = adjust(boss, { username = "joe", currency = "survivor", delta = 500, reason = "compensation for lost order", requestId = "r8", expectedRev = 1 })
check(again.ok == true and again.duplicate == true and L.getBalance("joe", "survivor").available == 600, "same requestId is idempotent (no double payment)")
check(lastSent("wallet.changed") ~= nil and lastSent("wallet.changed").player == joe and lastSent("wallet.changed").args.kind == "admin_adjust", "target player receives wallet.changed for the adjustment")

-- 每管理員每日加／減各自上限＋全服上限
check(adjust(boss, { username = "joe", currency = "survivor", delta = 5000, reason = "big correction number one", requestId = "r9", expectedRev = 2 }).ok == true, "5,000 fits the admin daily add cap (500 + 5000 <= 10000)")
check(adjust(boss, { username = "joe", currency = "survivor", delta = 4501, reason = "this would exceed the admin daily add cap", requestId = "r10", expectedRev = 3 }).error == "over_admin_daily", "admin daily add cap enforced (add and sub are separate)")
check(adjust(boss, { username = "joe", currency = "survivor", delta = -4501, reason = "subtractions have their own daily cap", requestId = "r11", expectedRev = 3 }).ok == true, "sub side is not consumed by the add side")
local boss2 = fakePlayer("boss2"); boss2.role = "admin"; onlinePlayers = { boss, boss2, mod, joe }
check(adjust(boss2, { username = "joe", currency = "survivor", delta = 5000, reason = "server-wide daily total blocks this", requestId = "r12", expectedRev = 4 }).ok == true, "second admin still within the server daily add cap (10500 of 12000)")
check(adjust(boss2, { username = "joe", currency = "survivor", delta = 2000, reason = "server-wide daily total blocks this", requestId = "r13", expectedRev = 5 }).error == "over_server_daily", "server daily add cap enforced across admins")

-- 凍結：帳本拒新交易、管理員仍可調帳（allowFrozen）、解凍恢復
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.freeze", boss, { username = "joe", frozen = true, reason = "suspected duplication exploit" })
check(lastSent("admin.freeze").args.ok == true and L.isFrozen("joe") == true, "freeze marks the account")
check(L.credit("joe", "survivor", 1, "SYSTEM_MINT", { requestId = "frozen-1", reasonCode = "t" }).error == "account_frozen", "frozen accounts refuse ordinary transactions")
check(adjust(boss, { username = "joe", currency = "survivor", delta = -100, reason = "clawback while frozen is allowed", requestId = "r14", expectedRev = 5 }).ok == true, "admin adjustments bypass the freeze (allowFrozen)")
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.freeze", boss, { username = "joe", frozen = false, reason = "investigation finished, cleared" })
check(L.isFrozen("joe") == false and L.credit("joe", "survivor", 1, "SYSTEM_MINT", { requestId = "frozen-2", reasonCode = "t" }).ok == true, "unfreeze restores normal transactions")

-- 設定：改名／停用經由 ECConfig（廣播 config）
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.config", boss, { currency = "cat", field = "name", value = "Meow", reason = "rename for the season event" })
local cfgReply = lastSent("admin.config").args
local catSnap = nil
for _, c in ipairs(cfgReply.currencies or {}) do if c.id == "cat" then catSnap = c end end
check(cfgReply.ok == true and catSnap and catSnap.nameOverride == "Meow" and lastSent("config").args.currencies ~= nil, "admin.config name override goes through ECConfig and broadcasts config")
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.config", boss, { currency = "cat", field = "bogus", value = 1, reason = "unknown field must be rejected" })
check(lastSent("admin.config").args.error == "invalid_args", "unknown config field rejected")
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.config", boss, { currency = "survivor", field = "balanceMax", value = 250000, reason = "season cap for survivor coin" })
local capReply = lastSent("admin.config").args
local capSnap = nil
for _, c in ipairs(capReply.currencies or {}) do if c.id == "survivor" then capSnap = c end end
check(capReply.ok == true and capSnap and capSnap.balanceMax == 250000 and capSnap.balanceMaxOverride == 250000
    and lastSent("config").args.currencies[1].balanceMaxOverride == 250000, "admin.config balanceMax sets a per-currency override and broadcasts it")
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.config", boss, { currency = "survivor", field = "balanceMax", value = "250000", reason = "a string cap must be refused" })
local capStr = lastSent("admin.config").args
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.config", boss, { currency = "survivor", field = "balanceMax", reason = "clear the override again" })
check(capStr.error == "invalid_args" and lastSent("admin.config").args.ok == true and Cfg.currency("survivor").balanceMaxOverride == nil,
    "a string cap is refused and omitting the value clears the override")

-- 稽核環：最新在前、reason 截 40 字、含 config／freeze／adjust
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.audit", mod, { limit = 50 })
local audit = lastSent("admin.audit").args
check(audit.ok == true and #audit.entries >= 8 and audit.entries[1].action == "config" and audit.entries[1].field == "balanceMax"
    and audit.entries[3].field == "nameOverride" and audit.entries[4].action == "unfreeze" and audit.entries[5].action == "adjust",
    "audit ring is newest-first and covers adjust/freeze/config (including the two balanceMax changes)")
local longReason = string.rep("x", 60)
adjust(boss, { username = "joe", currency = "cat", delta = 1, reason = longReason, requestId = "r15", expectedRev = 0 })
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.audit", mod, { limit = 1 })
check(#lastSent("admin.audit").args.entries[1].reason == 40, "ring keeps only a 40-char reason prefix (full text only in files)")

-- 系統：供給、前幾名持有者、路徑、發行統計
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.system", mod, {})
local sys = lastSent("admin.system").args
check(sys.ok == true and sys.supply.survivor.players == L.getBalance("joe", "survivor").available and sys.supply.survivor.top[1].account == "joe" and sys.accounts == 1 and sys.seq == S.modData().meta.seq, "admin.system reports supply, top holders and seq")
check(sys.pathsResolved == true and sys.paths.root == "C:/fake/Zomboid/Lua/MinidoracatEconomy" and sys.paths.audit == "C:/fake/Zomboid/Lua/MinidoracatEconomy/audit/" .. EC.monthKey(nowMs) .. ".json", "data paths are the server cachedir absolute paths the copy button needs")

-- ===== 情境二十：管理端信任邊界（偽造欄位、重送、失權、每幣別上限、環滾動） =====
io.write("scenario 20: admin trust boundary, replay, per-currency caps, ring rollover\n")
nowMs = nowMs + 61000                       -- 新的一分鐘：情境十九用掉的速率額度歸零
onlinePlayers = { boss, boss2, mod, joe }
local function jbal(cur) return L.getBalance("joe", cur or "survivor").available end
local function jrev(cur) return L.getBalance("joe", cur or "survivor").rev end
local bal0, rev0 = jbal(), jrev()

-- expectedRev 必填，且不得用 tonumber 把字串／nil 當成「不檢查」
local noRev = adjust(boss, { username = "joe", currency = "survivor", delta = 10, reason = "missing expected revision", requestId = "t1" })
local strRev = adjust(boss, { username = "joe", currency = "survivor", delta = 10, reason = "a string revision is not a number", requestId = "t2", expectedRev = "1" })
local negRev = adjust(boss, { username = "joe", currency = "survivor", delta = 10, reason = "a negative revision is nonsense", requestId = "t3", expectedRev = -1 })
check(noRev.error == "expected_rev_required" and strRev.error == "expected_rev_required" and negRev.error == "expected_rev_required" and jbal() == bal0,
    "expectedRev is mandatory and never coerced (missing / string / negative all refused, no money moved)")

-- 金額必須是有限非零整數
local infDelta = adjust(boss, { username = "joe", currency = "survivor", delta = 1 / 0, reason = "an infinite delta must not pass", requestId = "t4", expectedRev = rev0 })
local fracDelta = adjust(boss, { username = "joe", currency = "survivor", delta = 2.5, reason = "a fractional delta must not pass", requestId = "t5", expectedRev = rev0 })
local strDelta = adjust(boss, { username = "joe", currency = "survivor", delta = "10", reason = "a string delta must not pass", requestId = "t6", expectedRev = rev0 })
check(infDelta.error == "invalid_args" and fracDelta.error == "invalid_args" and strDelta.error == "invalid_args" and jbal() == bal0 and jrev() == rev0,
    "delta must be a finite non-zero integer and a string is not coerced into one")

-- 封包被亂塞（args 不是 table）：handler 不得炸掉，也要有明確回覆
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.adjust", boss, 42)
local junkAdjust = lastSent("admin.adjust").args
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.lookup", boss, "not a table")
check(junkAdjust.error == "invalid_args" and lastSent("admin.lookup").args.error == "invalid_args",
    "a non-table args packet is answered with invalid_args instead of dying inside the handler")

-- 原因：純空白（含全形空白）不是原因；長度以「字」計，中文有效；控制字元拒收
local blanks = adjust(boss, { username = "joe", currency = "survivor", delta = 10, reason = "              ", requestId = "t7", expectedRev = rev0 })
local ideoBlanks = adjust(boss, { username = "joe", currency = "survivor", delta = 10, reason = string.rep("\227\128\128", 12), requestId = "t8", expectedRev = rev0 })
check(blanks.error == "reason_blank" and ideoBlanks.error == "reason_blank" and jbal() == bal0,
    "a reason made of spaces only (ASCII or ideographic) is refused")
-- standard Lua 的字串是 UTF-8 位元組、Kahlua 是 UTF-16 字元（StringLib.java:760-768）：
-- 兩邊都必須把「中」算成一個字，所以 30 bytes 的十個字要過、12 bytes 的四個字要被拒
local cjk10 = string.rep("\228\184\173", 10)
local cjk4 = string.rep("\228\184\173", 4)
local okCjk = adjust(boss, { username = "joe", currency = "survivor", delta = 10, reason = cjk10, requestId = "t9", expectedRev = rev0 })
local shortCjk = adjust(boss, { username = "joe", currency = "survivor", delta = 10, reason = cjk4, requestId = "t10", expectedRev = rev0 + 1 })
check(okCjk.ok == true and shortCjk.error == "reason_too_short" and jbal() == bal0 + 10,
    "reason length counts characters: a 10-character Chinese reason passes, a 4-character one does not")
local ctrlReason = adjust(boss, { username = "joe", currency = "survivor", delta = 10, reason = "line\nbreak inside the reason", requestId = "t11", expectedRev = rev0 + 1 })
check(ctrlReason.error == "reason_invalid" and jbal() == bal0 + 10, "control characters in a reason are refused")

-- 重送：額度已滿也要回原結果，且不再吃額度、不再寫稽核
local boss3 = fakePlayer("boss3"); boss3.role = "admin"; onlinePlayers = { boss, boss2, boss3, mod, joe }
local catRev = jrev("cat")
local p1 = adjust(boss3, { username = "joe", currency = "cat", delta = 5000, reason = "first half of the cat correction", requestId = "p1", expectedRev = catRev })
local p2 = adjust(boss3, { username = "joe", currency = "cat", delta = 4999, reason = "second half of the cat correction", requestId = "p2", expectedRev = catRev + 1 })
local p3 = adjust(boss3, { username = "joe", currency = "cat", delta = 2, reason = "this one is over the daily add cap", requestId = "p3", expectedRev = catRev + 2 })
check(p1.ok and p2.ok and p3.error == "over_admin_daily", "the per-currency admin daily add cap fills up on cat")
local function auditEntries(who)
    nowMs = nowMs + 600
    fire("OnClientCommand", EC.COMMAND_MODULE, "admin.audit", who, {})
    return lastSent("admin.audit").args.entries
end
local auditBefore = #auditEntries(mod)
local catBal = jbal("cat")
local replay = adjust(boss3, { username = "joe", currency = "cat", delta = 5000, reason = "first half of the cat correction", requestId = "p1", expectedRev = catRev })
check(replay.ok == true and replay.duplicate == true and replay.txId == p1.txId
    and replay.requestId == "p1" and jbal("cat") == catBal,
    "a resend of a committed request returns the original txId (and echoes the requestId) although the daily cap is now full")
check(#auditEntries(mod) == auditBefore, "the resend writes no second audit entry")
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.lookup", boss3, { username = "joe" })
local look3 = lastSent("admin.lookup").args
check(look3.adminToday.currencies.cat.add == 9999 and look3.adminToday.currencies.survivor.add == 0
    and look3.adminToday.cap == 10000 and look3.adminToday.serverDaily.currencies.cat.add == 10000,
    "the resend consumed no cap: this admin's cat total is unchanged and the survivor side was never touched")

-- 舊格式資料升級：舊聚合每日額度必須計入所有幣別，舊 200 格稽核環要保留時序
local legacyRoot = ModData.getOrCreate(EC.MODDATA_KEY)
local legacyMs = nowMs + 86400000 * 3
local legacyDay = R.dayKey(legacyMs)
legacyRoot.adminDaily[legacyDay] = { server = { add = 9000, sub = 0 }, admins = { boss3 = { add = 9000, sub = 0 } } }
local legacyItems = {}
for i = 1, 200 do legacyItems[i] = { action = "legacy", seqNo = i } end
legacyItems[1] = { action = "legacy", seqNo = 201 }
legacyRoot.audit = { items = legacyItems, head = 2, count = 200 }
local resumeMs = nowMs
nowMs = legacyMs
fire("OnServerStarted")
onlinePlayers = { boss, boss2, boss3, mod, joe, mia }
local afterUpgrade = adjust(boss3, { username = "joe", currency = "survivor", delta = 1500, reason = "legacy totals must still count", requestId = "legacy-1", expectedRev = jrev() })
check(afterUpgrade.error == "over_admin_daily", "an aggregate daily total from the previous save is charged to every currency instead of resetting the cap")
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.audit", mod, { limit = 3 })
local upgraded = lastSent("admin.audit").args.entries
check(#upgraded == 3 and upgraded[1].seqNo == 201 and upgraded[2].seqNo == 200 and upgraded[3].seqNo == 199,
    "an older 200-slot audit ring keeps its newest-first order after the ring grows to 500")
legacyRoot.adminDaily[legacyDay] = nil
nowMs = resumeMs + 2000
fire("OnServerStarted")
onlinePlayers = { boss, boss2, boss3, mod, joe, mia }

-- 同 requestId 換金額／換帳號＝衝突：不得二次入帳，也不得誤入別的帳戶
local mia = fakePlayer("mia"); onlinePlayers = { boss, boss2, boss3, mod, joe, mia }
L.credit("mia", "survivor", 50, "SYSTEM_MINT", { requestId = "mia-seed", reasonCode = "t" })
local conflictAmount = adjust(boss3, { username = "joe", currency = "cat", delta = 7, reason = "same request id, different amount", requestId = "p1", expectedRev = catRev })
local conflictTarget = adjust(boss3, { username = "mia", currency = "cat", delta = 5000, reason = "same request id, different account", requestId = "p1", expectedRev = 0 })
check(conflictAmount.error == "request_conflict" and conflictTarget.error == "request_conflict"
    and jbal("cat") == catBal and L.getBalance("mia", "cat").available == 0,
    "one requestId reused with a different amount or account is a conflict: no second posting and nothing lands on the other account")

-- actor 綁定：使用者名稱含 ':' 也不得與別的管理員撞到同一把 idempotency 鑰匙
local colonAdmin = fakePlayer("root:1"); colonAdmin.role = "admin"
local plainAdmin = fakePlayer("root"); plainAdmin.role = "admin"
onlinePlayers = { colonAdmin, plainAdmin, mod, joe }
local k1 = adjust(colonAdmin, { username = "joe", currency = "survivor", delta = 3, reason = "actor binding first request", requestId = "9", expectedRev = jrev() })
local k2 = adjust(plainAdmin, { username = "joe", currency = "survivor", delta = 4, reason = "actor binding second request", requestId = "1:9", expectedRev = jrev() })
check(k1.ok and k2.ok and k1.txId ~= k2.txId and jbal() == bal0 + 17,
    "requestIds are bound to the actor without collisions: 'root:1' + '9' and 'root' + '1:9' are two different transactions")

-- 失權：角色被降級後同一位管理員立刻不能寫（server 每次重讀角色名，不看 client）
onlinePlayers = { boss, mod, joe }
boss.role = "moderator"
local demoted = adjust(boss, { username = "joe", currency = "survivor", delta = 10, reason = "the role was revoked before this call", requestId = "t20", expectedRev = jrev() })
check(demoted.error == "forbidden" and jbal() == bal0 + 17, "a demoted admin loses write access immediately")
boss.role = "admin"

-- 唯讀指令不得建立任何狀態
local root20 = S.modData()
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.lookup", mod, { username = "phantom" })
local phantom = lastSent("admin.lookup").args
check(phantom.ok == true and phantom.found == false and root20.wallets["phantom"] == nil and root20.claims["phantom"] == nil,
    "a lookup for a name that never had an account creates no wallet and no claim record")
R.state("joe", nowMs)                       -- 讓 joe 有一筆真實的 claim 紀錄
root20.claims.joe.milestones = 3
root20.claims.joe.playedMs = 120000
root20.config.season = "9"                  -- 換季：R.state 會清里程碑，查帳不可以
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.lookup", mod, { username = "joe" })
local lookJoe = lastSent("admin.lookup").args
check(root20.claims.joe.milestones == 3 and root20.claims.joe.playedMs == 120000
    and lookJoe.rewards.milestones == 0 and lookJoe.rewards.season == "9" and lookJoe.rewards.playedMs == 120000,
    "a moderator lookup projects the new season without rewriting the claim record (milestone mask and playtime survive)")
local day20 = R.dayKey(nowMs)
local boss4 = fakePlayer("boss4"); boss4.role = "admin"; onlinePlayers = { boss4, mod, joe }
-- 一筆在讀上限前就被拒（單筆上限），一筆是讀完當日上限才被拒（全服上限）：
-- 後者會走到讀取路徑，讀取路徑若建表就會留下這位管理員的空額度列
local deniedEarly = adjust(boss4, { username = "joe", currency = "survivor", delta = 5001, reason = "over the per transaction cap again", requestId = "t21", expectedRev = jrev() })
local deniedLate = adjust(boss4, { username = "joe", currency = "cat", delta = 5000, reason = "the server daily cat total blocks this", requestId = "t22", expectedRev = jrev("cat") })
check(deniedEarly.error == "over_max_per_tx" and deniedLate.error == "over_server_daily"
    and root20.adminDaily[day20].admins["boss4"] == nil,
    "a refused adjustment leaves no daily-total row behind, including when the refusal came from reading the totals")

-- 布林與型別：亂塞不得被當成「解凍」或「設定成功」
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.freeze", boss, { username = "joe", frozen = true, reason = "freeze for the boolean test" })
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.freeze", boss, { username = "joe", frozen = "false", reason = "a string is not a boolean here" })
check(lastSent("admin.freeze").args.error == "invalid_args" and L.isFrozen("joe") == true,
    "freeze needs a real boolean: a string does not silently unfreeze the account")
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.freeze", boss, { username = "joe", frozen = false, reason = "cleared after the boolean test" })
local enabledBefore = Cfg.currency("cat").enabled
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.config", boss, { currency = "cat", field = "enabled", value = "yes", reason = "a string is not a boolean either" })
check(lastSent("admin.config").args.error == "invalid_args" and Cfg.currency("cat").enabled == enabledBefore,
    "config enabled needs a boolean; a string does not change the currency")
local rateBefore = Cfg.currency("cat").exchange.rateVersion
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.config", boss, { currency = "cat", field = "exchange", value = 5, reason = "a malformed exchange payload" })
check(lastSent("admin.config").args.error == "invalid_args" and Cfg.currency("cat").exchange.rateVersion == rateBefore,
    "a malformed exchange value is refused instead of being coerced to an empty no-op reported as success")

-- 稽核環：滾動到上限、limit 有界、回傳是複本、帶 rolledBack
for i = 1, X.AUDIT_RING + 20 do X.audit({ action = "bulk", seqNo = i, reason = "bulk audit entry " .. i }) end
local ring20 = root20.audit
check(ring20.count == X.AUDIT_RING and X.AUDIT_RING == 500, "the audit ring stops growing at 500 entries")
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.audit", mod, { limit = 9999 })
local aud20 = lastSent("admin.audit").args
check(#aud20.entries == 500 and aud20.entries[1].seqNo == X.AUDIT_RING + 20 and aud20.entries[500].seqNo == 21 and aud20.max == 500,
    "a limit beyond the ring is clamped to it: newest first, and the rollover dropped the oldest entries")
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.audit", mod, { limit = 0 })
local zeroLimit = #lastSent("admin.audit").args.entries
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.audit", mod, { limit = "many" })
check(zeroLimit == 500 and #lastSent("admin.audit").args.entries == 500, "a non-positive or non-numeric limit falls back to the ring default")
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.audit", mod, { limit = 3 })
local three = lastSent("admin.audit").args.entries
three[1].action = "tampered"
check(#three == 3 and ring20.items[ring20.head - 1].action == "bulk",
    "the reply carries copies: mutating a returned entry does not reach the ModData ring")
local epoch20 = root20.meta.epoch
root20.meta.seq = 1
nowMs = nowMs + 1000
fire("OnServerStarted")                     -- 模擬回到 seq 1 的存檔
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.audit", mod, { limit = 5 })
local rolled = lastSent("admin.audit").args.entries
check(rolled[1].epoch == epoch20 and rolled[1].rolledBack == true,
    "audit entries stamped beyond the rollback point come back flagged rolledBack")

-- 系統：估算含管理資料、供給守恆看得到系統保留款、沒有 cachedir 就沒有路徑
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.system", mod, {})
local sys20 = lastSent("admin.system").args
check(sys20.auditCount == 500 and sys20.sizeParts.admin > 500 * 200
    and sys20.sizeEstimate == sys20.sizeParts.admin + sys20.sizeParts.ledger,
    "the size estimate counts the admin tables (audit ring, freeze marks, daily totals, request fingerprints), not only the ledger")
root20.wallets["SYSTEM_ADJUST"].survivor.reserved = 25
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.system", mod, {})
local sysRes = lastSent("admin.system").args
check(sysRes.supply.survivor.systemReserved == 25 and sysRes.supply.survivor.net == 25
    and sysRes.supply.survivor.net == L.conservation("survivor"),
    "a reserve parked on a system account shows up in the supply block and in its conservation sum (ignoring it would report a conserved 0 and hide the drift)")
root20.wallets["SYSTEM_ADJUST"].survivor.reserved = 0
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.system", mod, {})
check(lastSent("admin.system").args.supply.survivor.net == 0 and lastSent("admin.system").args.supply.cat.net == 0,
    "with the reserve cleared every currency sums back to zero")
docFolder = nil
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.system", mod, {})
local noPaths = lastSent("admin.system").args
check(noPaths.pathsResolved == false and noPaths.paths == nil,
    "without a cachedir from the engine there are no paths at all, not a relative string dressed up as an absolute one")
docFolder = "C:/fake/Zomboid"

-- 權限與「沒有的資料不要編」：回覆自己說明 server 端的判定
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.lookup", mod, { username = "joe" })
local modLook = lastSent("admin.lookup").args
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.lookup", boss, { username = "joe" })
check(modLook.perms.read == true and modLook.perms.write == false and lastSent("admin.lookup").args.perms.write == true,
    "each reply carries the server's own verdict on write permission instead of leaving it to the client role")
check(modLook.statsAvailable == false and modLook.stats == nil,
    "season totals are reported as unavailable rather than invented from the 5-entry receipt ring")

-- 每分鐘 10 筆
local racer = fakePlayer("racer"); racer.role = "admin"; onlinePlayers = { racer, mod, joe }
local balR = jbal()
local rateErr = nil
for i = 1, 12 do
    local res = adjust(racer, { username = "joe", currency = "survivor", delta = 1, reason = "rate limit probe number " .. i, requestId = "rl-" .. i, expectedRev = jrev() })
    if not res.ok then rateErr = res.error end
end
check(rateErr == "rate_limited" and jbal() == balR + A.RATE_PER_MINUTE,
    "an admin is limited to RATE_PER_MINUTE adjustments per minute and the refused ones move no money")
onlinePlayers = {}

-- ===== 情境二十一：貨幣圖示（掃描、分 tick 讀取、hash、分塊回覆、上限、移除、閘門） =====
io.write("scenario 21: currency icons scan, chunked reply, cap, removal, gate\n")
;(function() -- own function: locals in a do-block still count toward the main chunk's 200 limit
local I = EC.Icons
modDataStore[EC.MODDATA_KEY] = nil
files = {}
sentCommands = {}
onlinePlayers = { boss, mod, joe, alice }
local catPath = X.ROOT .. "/icons/cat.png"
local iconBytes = {}
local seed = 7
for i = 1, 10000 do
    seed = (seed * 1103515245 + 12345) % 2147483648
    iconBytes[i] = string.char(seed % 256)
end
local catData = table.concat(iconBytes)
binFiles[catPath] = catData
nowMs = nowMs + 61000
fire("OnServerStarted")
check(Cfg.currency("cat").iconHash == nil and I.busy(), "start only queues the read; nothing is hashed synchronously")
local ticks = 0
while I.busy() and ticks < 20 do fire("OnTickEvenPaused"); ticks = ticks + 1 end
local expectHash = 5381
for i = 1, #catData do expectHash = (expectHash * 33 + string.byte(catData, i)) % 4294967296 end
local catCfg = Cfg.currency("cat")
check(ticks == 4 and EC.isIconHash(catCfg.iconHash) and catCfg.iconHash == EC.hashHex(expectHash) and catCfg.iconBytes == 10000,
    "10000 bytes take 3 read ticks + 1 open tick; hash is DJB2 over the bytes and the byte count is published")
check(Cfg.currency("survivor").iconHash == nil and I.status().survivor.error == nil and I.status().survivor.hash == nil,
    "a currency without a file keeps the shipped icon and reports no error")
local cfgPush = lastSent("config")
check(cfgPush and cfgPush.args.currencies[2].iconHash == catCfg.iconHash and cfgPush.args.currencies[2].iconBytes == 10000,
    "the new hash is broadcast through config")
check(EC.hashHex(0) == "00000000" and EC.hashHex(4294967295) == "ffffffff" and EC.hashHex(EC.hashUpdate(EC.hashInit(), "a")) == "0002b606",
    "hashHex pads to 8 lower-case hex digits and djb2('a') = 0x0002b606")

-- 分塊回覆
sentCommands = {}
fire("OnClientCommand", EC.COMMAND_MODULE, "icon.get", alice, { currency = "cat" })
local parts, got = {}, {}
for _, c in ipairs(sentCommands) do
    if c.command == "icon.data" then
        got[#got + 1] = c.args
        parts[c.args.i] = c.args.text
    end
end
check(#got == 2 and got[1].n == 2 and got[1].i == 1 and got[2].i == 2 and got[1].hash == catCfg.iconHash and got[1].bytes == 10000,
    "icon.get replies one icon.data per chunk with hash, byte count and chunk index")
check(#parts[1] == EC.ICON_CHUNK_CHARS and #parts[2] == 10000 - EC.ICON_CHUNK_CHARS and table.concat(parts) == catData,
    "chunks are ICON_CHUNK_CHARS long and concatenate back to the exact bytes")
sentCommands = {}
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "icon.get", alice, { currency = "cat", from = 2 })
check(#sentCommands == 1 and sentCommands[1].args.i == 2, "from=N resumes at chunk N")
sentCommands = {}
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "icon.get", alice, { currency = "survivor" })
check(#sentCommands == 1 and sentCommands[1].args.hash == nil and sentCommands[1].args.text == nil,
    "asking for a currency without an override replies hash=nil and no bytes")

-- 超過上限：拒絕、不動已載入的貓幣、稽核只記真正的變更
binFiles[X.ROOT .. "/icons/survivor.png"] = string.rep("x", EC.ICON_MAX_BYTES + 1)
local auditBefore = #X.auditEntries(500)
sentCommands = {}
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.icons", boss, { action = "reload" })
local rl = lastSent("admin.icons").args
check(rl.ok and rl.started == true and rl.busy == true, "admin reload starts a rescan and reports busy")
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.icons", boss, { action = "reload" })
check(lastSent("admin.icons").args.started == false, "a reload while one is in flight is refused, not queued twice")
ticks = 0
while I.busy() and ticks < 20 do fire("OnTickEvenPaused"); ticks = ticks + 1 end
check(Cfg.currency("survivor").iconHash == nil and I.status().survivor.error == "too_large",
    "an oversized file is refused and the shipped icon stays")
check(Cfg.currency("cat").iconHash == catCfg.iconHash and #X.auditEntries(500) == auditBefore,
    "re-reading an unchanged icon writes no audit line and keeps the hash")

-- 移除檔案 -> 回內建圖示，且有稽核
binFiles[catPath] = nil
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.icons", boss, { action = "reload" })
ticks = 0
while I.busy() and ticks < 20 do fire("OnTickEvenPaused"); ticks = ticks + 1 end
local removedAudit = X.auditEntries(1)[1]
check(Cfg.currency("cat").iconHash == nil and Cfg.currency("cat").iconBytes == nil
    and removedAudit.action == "config" and removedAudit.field == "iconHash" and removedAudit.after == nil and removedAudit.admin == "boss",
    "removing the file clears the override and audits who reloaded")
sentCommands = {}
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "icon.get", alice, { currency = "cat" })
check(sentCommands[1].args.hash == nil, "chunks of a removed icon are no longer served")

-- 閘門：一般玩家全拒、唯讀角色只能查狀態
sentCommands = {}
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.icons", joe, { action = "status" })
check(lastSent("admin.icons").args.error == "forbidden", "a plain player cannot query icon status")
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.icons", mod, { action = "reload" })
check(lastSent("admin.icons").args.error == "forbidden", "a moderator cannot reload")
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.icons", mod, { action = "status" })
local st = lastSent("admin.icons").args
check(st.ok and st.started == false and st.perms.write == false and st.icons.survivor.error == "too_large",
    "a moderator can read icon status and sees the last outcome")
onlinePlayers = {}
end)()

-- ===== 情境二十二：整合 API（來源註冊、額度、冪等、rate limit、閘門、稽核） =====
io.write("scenario 22: integration facade\n")
;(function()
local G = EC.Integration
local V = EC.v1
modDataStore[EC.MODDATA_KEY] = nil
files = {}
sentCommands = {}
onlinePlayers = { boss, mod, joe }
nowMs = nowMs + 61000
check(V and V.API_MAJOR == 1 and V.API_REVISION >= 1 and V.CAPABILITIES.post == true and V.CAPABILITIES.transfer == false,
    "facade is versioned like UIFor42 and declares its capabilities")

-- 未初始化：註冊可以，記帳回 not_ready
local src, regErr = V.registerSource({ modId = "MinidoracatMiniMapFor42", displayName = { CH = "\229\176\143\229\156\176\229\156\150", EN = "MiniMap" },
    currencies = { "survivor" }, reasonCodes = { "gps_subscription", "nav_route" } })
check(src ~= nil and src.modId == "MinidoracatMiniMapFor42" and type(src.debit) == "function", "registerSource returns a bound handle")
check(select(2, V.registerSource({ modId = "bad id", currencies = { "survivor" }, reasonCodes = { "x" } })) == "invalid_args"
    and select(2, V.registerSource({ modId = "Ok", currencies = { "gold" }, reasonCodes = { "x" } })) == "unknown_currency"
    and select(2, V.registerSource({ modId = "Ok", currencies = { "survivor" }, reasonCodes = { "Bad-Code" } })) == "invalid_args",
    "registration validates modId, currencies and reason codes")

fire("OnServerStarted")
local root = S.modData()
check(root.config.sources["MinidoracatMiniMapFor42"] and root.config.sources["MinidoracatMiniMapFor42"].dailyMintCap == 0
    and root.config.sources["MinidoracatMiniMapFor42"].enabled == true, "init creates the source config with mint cap 0 (debit-only by default)")
L.credit("joe", "survivor", 500, "SYSTEM_MINT", { requestId = "seed-joe", reasonCode = "t" })

-- 未註冊來源
local res = V.debit("joe", "survivor", 10, { modId = "Nobody", requestId = "n1", reasonCode = "gps_subscription" })
check(res.ok == false and res.error == "unknown_source" and L.getBalance("joe", "survivor").available == 500,
    "an unregistered modId is refused with zero change")
local rejLines = 0
for _, f in pairs(files) do for _, l in ipairs(f.lines) do if string.find(l, '"type":"integration.rejected"', 1, true) then rejLines = rejLines + 1 end end end
fire("OnTickEvenPaused")
rejLines = 0
for _, f in pairs(files) do for _, l in ipairs(f.lines) do if string.find(l, '"type":"integration.rejected"', 1, true) then rejLines = rejLines + 1 end end end
check(rejLines >= 1, "refusals are exported as integration.rejected events")

-- debit 成功：MOD 帳戶收到、玩家扣款、收據帶 sourceMod／reasonText、事件 kind=mod
sentCommands = {}
res = src.debit("joe", "survivor", 120, { requestId = "gps-joe-202609", reasonCode = "gps_subscription", reasonText = "GPS 2026-09",
    ref = { type = "subscription", id = "gps:joe" }, meta = { plan = "monthly" } })
check(res.ok == true and type(res.txId) == "string" and res.duplicate == false, "debit posts a balanced player -> MOD:<modId> transaction")
check(L.getBalance("joe", "survivor").available == 380 and L.getBalance("MOD:MinidoracatMiniMapFor42", "survivor").available == 120,
    "the MOD account holds what the mod burned")
local rc = L.receipts("joe")
local last = rc[#rc]
check(last.kind == "mod" and last.sourceMod == "MinidoracatMiniMapFor42" and last.reasonText == "GPS 2026-09" and last.amount == -120,
    "the receipt ring names the mod and its wording")
local push = lastSent("wallet.changed")
check(push == nil or push.player ~= joe or push.args.balances.survivor.available == 380, "wallet push (when online) reflects the debit")

-- 冪等：同 requestId 回原結果；同 id 不同金額 -> request_conflict
local again = src.debit("joe", "survivor", 120, { requestId = "gps-joe-202609", reasonCode = "gps_subscription" })
check(again.ok == true and again.duplicate == true and again.txId == res.txId and L.getBalance("joe", "survivor").available == 380,
    "a resend of the same requestId returns the first result and moves no money")
check(src.debit("joe", "survivor", 121, { requestId = "gps-joe-202609", reasonCode = "gps_subscription" }).error == "request_conflict",
    "the same requestId with a different amount is a conflict, not a second posting")

-- 驗證：幣別不在註冊集合、reasonCode 不在集合、非整數、系統帳戶、超長欄位
check(src.debit("joe", "cat", 1, { requestId = "c1", reasonCode = "gps_subscription" }).error == "currency_not_allowed", "currency outside the registration is refused")
check(src.debit("joe", "survivor", 1, { requestId = "c2", reasonCode = "steal" }).error == "invalid_args", "reason code outside the registration is refused")
check(src.debit("joe", "survivor", 1.5, { requestId = "c3", reasonCode = "nav_route" }).error == "invalid_args", "non-integer amounts are refused")
check(src.debit("SYSTEM_MINT", "survivor", 1, { requestId = "c4", reasonCode = "nav_route" }).error == "invalid_args", "system accounts cannot be targeted")
check(src.debit("joe", "survivor", 1, { requestId = "c5", reasonCode = "nav_route", reasonText = string.rep("x", 65) }).error == "invalid_args", "reasonText over 64 chars is refused")
check(src.debit("joe", "survivor", 1, { requestId = "c6", reasonCode = "nav_route", meta = { a = 1, b = 2, c = 3, d = 4, e = 5, f = 6, g = 7, h = 8, i = 9 } }).error == "invalid_args", "meta with more than 8 keys is refused")
check(src.debit("joe", "survivor", 1000, { requestId = "c7", reasonCode = "nav_route" }).error == "insufficient_funds" and L.getBalance("joe", "survivor").available == 380,
    "insufficient funds: zero change, consumer degrades on its own")

-- mint 額度：預設 0 -> cap_exceeded；管理員給額度後可發，超過再拒
check(src.credit("joe", "survivor", 50, { requestId = "m1", reasonCode = "nav_route" }).error == "cap_exceeded", "mint is refused until the host grants a daily cap")
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.sources", mod, { action = "set", modId = "MinidoracatMiniMapFor42", dailyMintCap = 100, reason = "moderator tries to grant" })
check(lastSent("admin.sources").args.error == "forbidden", "a moderator cannot change source caps")
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.sources", boss, { action = "set", modId = "MinidoracatMiniMapFor42", dailyMintCap = 100, reason = "grant minimap a daily mint cap" })
local setRes = lastSent("admin.sources").args
check(setRes.ok == true and setRes.sources[1].dailyMintCap == 100 and setRes.sources[1].loaded == true and setRes.sources[1].today.burn == 120,
    "an admin grants a mint cap; the reply lists sources with today's usage")
local au = X.auditEntries(1)[1]
check(au.action == "source" and au.target == "MinidoracatMiniMapFor42" and au.field == "dailyMintCap" and au.after == 100 and au.admin == "boss",
    "cap changes are audited")
check(src.credit("joe", "survivor", 60, { requestId = "m2", reasonCode = "nav_route" }).ok == true, "mint within the cap succeeds")
check(src.credit("joe", "survivor", 41, { requestId = "m3", reasonCode = "nav_route" }).error == "cap_exceeded"
    and src.credit("joe", "survivor", 40, { requestId = "m4", reasonCode = "nav_route" }).ok == true,
    "the daily mint cap is enforced on the running total")
check(L.getBalance("MOD:MinidoracatMiniMapFor42", "survivor").available == 20, "MOD account = burned 120 - minted 100")

-- burn 額度（預設無上限）與停用
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.sources", boss, { action = "set", modId = "MinidoracatMiniMapFor42", dailyBurnCap = 130, reason = "cap the burn for the test" })
check(src.debit("joe", "survivor", 11, { requestId = "b1", reasonCode = "nav_route" }).error == "cap_exceeded"
    and src.debit("joe", "survivor", 10, { requestId = "b2", reasonCode = "nav_route" }).ok == true,
    "a burn cap counts today's 120 already burned")
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.sources", boss, { action = "set", modId = "MinidoracatMiniMapFor42", dailyBurnCap = false, enabled = false, reason = "disable the source for now" })
check(src.debit("joe", "survivor", 1, { requestId = "d1", reasonCode = "nav_route" }).error == "source_disabled", "a disabled source is refused")
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.sources", boss, { action = "set", modId = "MinidoracatMiniMapFor42", enabled = true, reason = "re-enable the source again" })
check(S.modData().config.sources["MinidoracatMiniMapFor42"].dailyBurnCap == nil, "dailyBurnCap=false clears the cap (unlimited)")

-- 凍結帳號：拒絕；解凍後同 requestId 重送成功
S.modData().frozen["joe"] = { by = "boss", at = nowMs }
check(src.debit("joe", "survivor", 1, { requestId = "f1", reasonCode = "nav_route" }).error == "account_frozen", "frozen accounts are refused")
S.modData().frozen["joe"] = nil
check(src.debit("joe", "survivor", 1, { requestId = "f1", reasonCode = "nav_route" }).ok == true, "after unfreezing, the same requestId succeeds (refusals are not cached)")

-- post：多條 postings 只能碰玩家與自己的 MOD 帳戶
check(src.post({ requestId = "p1", reasonCode = "nav_route", postings = { { account = "joe", currency = "survivor", amount = -5 }, { account = "MOD:Other", currency = "survivor", amount = 5 } } }).error == "invalid_args",
    "post cannot touch another mod's account")
check(src.post({ requestId = "p2", reasonCode = "nav_route", postings = { { account = "joe", currency = "survivor", amount = -5 }, { account = "MOD:MinidoracatMiniMapFor42", currency = "survivor", amount = 4 } } }).error == "unbalanced",
    "post must balance per currency")

-- rate limit：每 tick 20 次
local limited = 0
for i = 1, 25 do
    local r = src.debit("joe", "survivor", 1, { requestId = "rl-" .. i, reasonCode = "nav_route" })
    if r.error == "rate_limited" then limited = limited + 1 end
end
check(limited > 0, "calls beyond CALLS_PER_TICK in one tick are rate limited")
fire("OnTickEvenPaused")
check(src.debit("joe", "survivor", 1, { requestId = "rl-next", reasonCode = "nav_route" }).ok == true, "the budget refills on the next tick")

-- 讀取
check(V.getBalance("joe", "survivor").available == L.getBalance("joe", "survivor").available and V.getBalance("nobody", "survivor").available == 0
    and S.modData().wallets["nobody"] == nil, "getBalance is read-only and creates no wallet")
check(#V.currencies() == 2 and V.currencies()[1].id == "survivor", "currencies() is the config snapshot")

-- 守恆
check(L.conservation("survivor") == 0, "integration postings keep the conservation sum at zero")
onlinePlayers = {}
end)()

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
