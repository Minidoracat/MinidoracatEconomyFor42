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
local EC = MinidoracatEconomy
local S = EC.Server

-- ===== 測試工具 =====
local failures, assertions = 0, 0
local EXPECTED_ASSERTIONS = 25     -- 家族慣例：條數守門，防整段被註解仍全綠
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
