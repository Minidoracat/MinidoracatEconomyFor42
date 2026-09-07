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
-- 假目錄列舉：listFilesInZomboidLuaDirectory(dir) 回該目錄直屬檔名（不含子目錄、不遞迴；LuaManager.java:6057-6068）
function listFilesInZomboidLuaDirectory(dir)
    local names, prefix = {}, dir .. "/"
    for path in pairs(files) do
        if string.sub(path, 1, #prefix) == prefix then
            local rest = string.sub(path, #prefix + 1)
            if not string.find(rest, "/", 1, true) then names[#names + 1] = rest end
        end
    end
    table.sort(names)
    return javaList(names)
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

-- 假物品／背包（階段 C／D：信箱 claim-in、收斂、白名單 codec）。全域：主函式已逼近 200 個 local。
-- knownItems[fullType] = { w=重量, cat=DisplayCategory, main=主類別, rots=daysTotallyRotten, fluid=bool, weapon=bool,
--                          itemType=ItemType 名（省略時由 main 推） }
knownItems = {
    ["Base.Bandage"] = { w = 0.1, cat = "FirstAid", main = "Normal" }, ["Base.Antibiotics"] = { w = 0.1, cat = "FirstAid", main = "Normal" },
    ["Base.RippedSheets"] = { w = 0.1, cat = "FirstAid", main = "Normal" }, ["Base.CannedCorn"] = { w = 0.5, cat = "Food", main = "Food" },
    ["Base.Nails"] = { w = 0.01, cat = "Material", main = "Normal" }, ["Base.Screws"] = { w = 0.01, cat = "Material", main = "Normal" },
    ["Base.Plank"] = { w = 3, cat = "MaterialWeapon", main = "Weapon" }, ["Base.Rope"] = { w = 0.5, cat = "Material", main = "Normal" },
    ["Base.Twine"] = { w = 0.1, cat = "Material", main = "Normal" }, ["Base.Lighter"] = { w = 0.1, cat = "LightSource", main = "Drainable" },
    ["Base.Hammer"] = { w = 1.5, cat = "Tool", main = "Weapon" }, ["Base.Saw"] = { w = 1.5, cat = "Tool", main = "Normal" },
    ["Base.Axe"] = { w = 3, cat = "ToolWeapon", main = "Weapon", weapon = true }, ["Base.Heavy"] = { w = 30, cat = "Material", main = "Normal" },
    ["Base.Apple"] = { w = 0.2, cat = "Food", main = "Food", rots = 8 }, ["Base.Bag_ALICEpack"] = { w = 1, cat = "Bag", main = "Container" },
    ["Base.PetrolCan"] = { w = 1.5, cat = "VehicleMaintenance", main = "Normal", fluid = true },
    ["Base.x2Scope"] = { w = 0.3, cat = "WeaponPart", main = "Normal" }, ["Base.BookCarpentry1"] = { w = 0.8, cat = "SkillBook", main = "Literature" },
    ["Base.RadioRed"] = { w = 1, cat = "Communications", main = "Item", itemType = "RADIO", device = true },
    ["Base.Mov_Chair"] = { w = 5, cat = "Furniture", main = "Item", itemType = "MOVEABLE" },
}
-- ItemType 是暴露給 Lua 的 Java 類別（靜態欄位 CONTAINER…；LuaManager.java:2311）：這裡用哨兵表代替
ItemType = {}
for _, n in ipairs({ "NORMAL", "FOOD", "WEAPON", "LITERATURE", "DRAINABLE", "CONTAINER", "CLOTHING", "KEY", "KEY_RING", "MOVEABLE", "RADIO", "MAP", "ALARM_CLOCK", "ALARM_CLOCK_CLOTHING", "ANIMAL", "WEAPON_PART" }) do
    ItemType[n] = { name = n }
end
local MAIN_TO_TYPE = { Normal = "NORMAL", Food = "FOOD", Weapon = "WEAPON", Literature = "LITERATURE", Drainable = "DRAINABLE", Container = "CONTAINER", Item = "NORMAL" }
ScriptManager = { instance = { FindItem = function(_, name)
    local k = knownItems[name]
    if not k then return nil end
    local itemType = ItemType[k.itemType or MAIN_TO_TYPE[k.main] or "NORMAL"]
    return { name = name, getDisplayName = function() return name end, getDisplayCategory = function() return k.cat end,
        getDaysTotallyRotten = function() return k.rots or 1000000000 end, isItemType = function(_, t) return t == itemType end }
end } }
Fluid = { Get = function(name) return { name = name } end }
-- 假電台：記錄每次 SendTransmission 與頻道登錄（getZomboidRadio 在 dedicated 上非 nil，A14）
radioSent, radioChannels = {}, {}
function getZomboidRadio()
    return {
        SendTransmission = function(_, x, y, channel, msg, guid, codes, r, g, b, strength, isTV)
            radioSent[#radioSent + 1] = { x = x, y = y, channel = channel, msg = msg, strength = strength, isTV = isTV }
        end,
        addChannelName = function(_, name, freq, category) radioChannels[#radioChannels + 1] = { name = name, freq = freq, category = category } end,
    }
end
function getModFileReader(modId, path, create)
    local f = io.open("MOD/" .. modId .. "/Contents/mods/" .. modId .. "/42/" .. path, "rb")
    if not f then return nil end
    local data = f:read("*a"); f:close()
    local pos = 1
    return { readLine = function()
        if pos > #data then return nil end
        local nl = string.find(data, "\n", pos, true) or (#data + 1)
        local line = string.sub(data, pos, nl - 1); pos = nl + 1
        return (string.gsub(line, "\r$", ""))
    end, close = function() end }
end
worldHours = 1000                -- getGameTime():getWorldAgeHours() 的假值（全域：主函式已逼近 200 個 local）
function getGameTime() return { getWorldAgeHours = function() return worldHours end } end
Capability = { AddItem = "AddItem", SaveWorld = "SaveWorld" }
nextItemId = 1
function instanceItem(fullType)
    local k = knownItems[fullType]
    if not k then return nil end
    local id = nextItemId
    nextItemId = nextItemId + 1
    local it = { fullType = fullType, id = id, modData = {}, condition = 10, uses = 1, age = 0, repaired = 0, readPages = 0,
        equipped = false, favorite = false, broken = false, parts = {} }
    it.getFullType = function() return fullType end
    it.getID = function() return id end
    it.getModData = function() return it.modData end
    it.getUnequippedWeight = function() return k.w end
    it.getActualWeight = function() return k.w end
    it.getCategory = function() return k.main end
    it.getDisplayCategory = function() return k.cat end
    it.getScriptItem = function() return ScriptManager.instance:FindItem(fullType) end
    it.isEquipped = function() return it.equipped end
    it.isFavorite = function() return it.favorite end
    it.isBroken = function() return it.broken end
    it.getCondition = function() return it.condition end
    it.setCondition = function(_, v) it.condition = v end
    it.getCurrentUses = function() return it.uses end
    it.setCurrentUses = function(_, v) it.uses = v end
    if k.main == "Food" then
        it.rotten, it.hunger, it.thirst, it.cooked, it.burnt, it.frozen, it.freezing = false, -10, 0, false, false, false, 0
        it.isRotten = function() return it.rotten end
        it.getHungChange = function() return it.hunger end
        it.setHungChange = function(_, v) it.hunger = v end
        it.getThirstChange = function() return it.thirst end
        it.setThirstChange = function(_, v) it.thirst = v end
        it.isCooked = function() return it.cooked end
        it.setCooked = function(_, v) it.cooked = v end
        it.isBurnt = function() return it.burnt end
        it.setBurnt = function(_, v) it.burnt = v end
        it.isFrozen = function() return it.frozen end
        it.setFrozen = function(_, v) it.frozen = v end
        it.getFreezingTime = function() return it.freezing end
        it.setFreezingTime = function(_, v) it.freezing = v end
    end
    if k.device then
        local dev = { channel = 88000, power = 1, on = false, volume = 0.5, headphones = -1, muted = false, battery = true, mediaType = -1, mediaIndex = -1 }
        it.dev = dev
        it.getDeviceData = function() return {
            getChannel = function() return dev.channel end, setChannelRaw = function(_, v) dev.channel = v end,
            getPower = function() return dev.power end, setPower = function(_, v) dev.power = v end,
            getIsTurnedOn = function() return dev.on end, setTurnedOnRaw = function(_, v) dev.on = v end,
            getDeviceVolume = function() return dev.volume end, setDeviceVolumeRaw = function(_, v) dev.volume = v end,
            getHeadphoneType = function() return dev.headphones end, setHeadphoneType = function(_, v) dev.headphones = v end,
            getMicIsMuted = function() return dev.muted end, setMicIsMuted = function(_, v) dev.muted = v end,
            getHasBattery = function() return dev.battery end, setHasBattery = function(_, v) dev.battery = v end,
            getMediaType = function() return dev.mediaType end, setMediaType = function(_, v) dev.mediaType = v end,
            getMediaIndex = function() return dev.mediaIndex end, setMediaIndex = function(_, v) dev.mediaIndex = v end,
        } end
    end
    it.name, it.customName = fullType, false
    it.getName = function() return it.name end
    it.setName = function(_, v) it.name = v end
    it.isCustomName = function() return it.customName end
    it.setCustomName = function(_, v) it.customName = v; it.modData.customName = it.name end
    it.getAge = function() return it.age end
    it.setAge = function(_, v) it.age = v end
    it.getHaveBeenRepaired = function() return it.repaired end
    it.setHaveBeenRepaired = function(_, v) it.repaired = v end
    if k.main == "Literature" then
        it.getAlreadyReadPages = function() return it.readPages end
        it.setAlreadyReadPages = function(_, v) it.readPages = v end
    end
    if k.fluid then
        it.fluidName, it.fluidAmount = "", 0
        it.getFluidContainer = function()
            return { Empty = function() it.fluidName, it.fluidAmount = "", 0 end,
                addFluid = function(_, fl, amount) it.fluidName, it.fluidAmount = fl.name, amount end,
                getAmount = function() return it.fluidAmount end,
                getPrimaryFluid = function() if it.fluidName == "" then return nil end; return { getFluidTypeString = function() return it.fluidName end } end }
        end
    end
    if k.weapon then
        it.getAllWeaponParts = function() return javaList(it.parts) end
        it.attachWeaponPart = function(_, part) it.parts[#it.parts + 1] = part end
        it.detachWeaponPart = function(_, part) for i = #it.parts, 1, -1 do if it.parts[i] == part then table.remove(it.parts, i) end end end
    end
    return it
end
ArrayList = { new = function() local items = {}; return { add = function(_, it) items[#items + 1] = it end, size = function() return #items end, get = function(_, i) return items[i + 1] end, items = items } end }
sentItemPackets = {}
function sendAddItemsToContainer(container, list) sentItemPackets[#sentItemPackets + 1] = { container = container, add = list.items } end
function sendAddItemToContainer(container, item) sentItemPackets[#sentItemPackets + 1] = { container = container, add = { item } } end
function sendRemoveItemFromContainer(container, item) sentItemPackets[#sentItemPackets + 1] = { container = container, remove = item } end
function fakeInventory(maxWeight)
    local inv = { items = {}, maxWeight = maxWeight or 20 }
    inv.weight = function() local w = 0; for _, it in ipairs(inv.items) do w = w + it:getUnequippedWeight() end; return w end
    inv.hasRoomFor = function(_, _, w) return inv.weight() + w <= inv.maxWeight end
    inv.AddItem = function(_, it) inv.items[#inv.items + 1] = it; return it end
    inv.Remove = function(_, it) for i = #inv.items, 1, -1 do if inv.items[i] == it then table.remove(inv.items, i) end end end
    inv.getItems = function() return javaList(inv.items) end
    inv.getItemWithID = function(_, id) for _, it in ipairs(inv.items) do if it.id == id then return it end end; return nil end
    inv.count = function(fullType) local n = 0; for _, it in ipairs(inv.items) do if not fullType or it.fullType == fullType then n = n + 1 end end; return n end
    return inv
end
worldSprites = {}                -- "x,y,z" -> sprite name（getCell():getGridSquare 的假物件）
function getCell()
    return { getGridSquare = function(_, x, y, z)
        local key = x .. "," .. y .. "," .. z
        local name = worldSprites[key]
        if not name then return nil end
        local obj = { getSprite = function() return { getName = function() return name end } end }
        return { getObjects = function() return javaList({ obj }) end,
            transmitRemoveItemFromSquare = function(_, o) if o == obj then worldSprites[key] = nil end end }
    end }
end

local function fakePlayer(username)
    local p = { username = username, x = 100, y = 200, z = 0, hours = 0, modData = {}, inventory = fakeInventory(20), caps = {} }
    p.getUsername = function() return username end
    p.getX = function() return p.x end
    p.getY = function() return p.y end
    p.getZ = function() return p.z end
    p.getHoursSurvived = function() return p.hours end
    p.getInventory = function() return p.inventory end
    p.getModData = function() return p.modData end
    p.transmitModData = function() p.transmitted = (p.transmitted or 0) + 1 end
    p.role = "user"
    p.getRole = function() return { getName = function() return p.role end, hasCapability = function(_, cap) return p.role == "admin" or p.caps[cap] == true end } end
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
require("MinidoracatEconomy/ECTerminal")
require("MinidoracatEconomy/ECMailbox")
require("MinidoracatEconomy/ECShop")
require("MinidoracatEconomy/ECCodec")
require("MinidoracatEconomy/ECMarket")
require("MinidoracatEconomy/ECRadio")
require("MinidoracatEconomy/ECAuction")
require("MinidoracatEconomy/ECExchange")
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
local EXPECTED_ASSERTIONS = 567     -- 家族慣例：條數守門，防整段被註解仍全綠
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
do
    local txLine = nil
    for _, l in ipairs(ev.lines) do if string.find(l, '"type":"tx.committed"', 1, true) then txLine = l end end
    check(#ev.lines == 4 and txLine ~= nil and string.find(txLine, '"txId":"' .. rc.txId .. '"', 1, true) and string.find(txLine, '"availableAfter":30', 1, true)
        and string.find(ev.lines[3], '"type":"exchange.config"', 1, true) ~= nil, "tick writes the exchange.config projection queued at start and the tx.committed line with postings")
end
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
check(adjust(boss, { username = "joe", currency = "survivor", delta = 10, reason = "", requestId = "r1", expectedRev = 1 }).error == "reason_blank", "an empty reason is refused (any non-empty reason is accepted)")
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
-- 兩邊都必須把「中」算成一個字：1000 個中文字（3000 bytes）要過上限、1001 個要被拒
local cjk1000 = string.rep("\228\184\173", A.REASON_MAX)
local cjk1001 = string.rep("\228\184\173", A.REASON_MAX + 1)
local okCjk = adjust(boss, { username = "joe", currency = "survivor", delta = 10, reason = cjk1000, requestId = "t9", expectedRev = rev0 })
local longCjk = adjust(boss, { username = "joe", currency = "survivor", delta = 10, reason = cjk1001, requestId = "t10", expectedRev = rev0 + 1 })
check(okCjk.ok == true and longCjk.error == "reason_too_long" and jbal() == bal0 + 10,
    "reason length counts characters: 1000 Chinese characters pass the cap, 1001 do not")
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

-- ===== 情境二十三：崩潰前沒存檔的 epoch，靠 epochs.json 判定回滾 =====
io.write("scenario 23: crashed-before-save epoch is flagged from epochs.json\n")
;(function()
local function deepCopy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = deepCopy(v) end
    return out
end
modDataStore[EC.MODDATA_KEY] = nil
files = {}
sentCommands = {}
nowMs = nowMs + 61000
fire("OnServerStarted")                       -- E1: fresh world
local e1 = S.modData().meta.epoch
L.credit("zed", "survivor", 10, "SYSTEM_MINT", { requestId = "z1", reasonCode = "t" })
L.credit("zed", "survivor", 10, "SYSTEM_MINT", { requestId = "z2", reasonCode = "t" })
fire("OnTickEvenPaused")                      -- receipt lines reach the files
local saved = deepCopy(modDataStore[EC.MODDATA_KEY])   -- world save at seq 2
nowMs = nowMs + 1000
fire("OnServerStarted")                       -- E2 loads the save (seq 2)
local e2 = S.modData().meta.epoch
L.credit("zed", "survivor", 10, "SYSTEM_MINT", { requestId = "z3", reasonCode = "t" })   -- seq 3, never saved
fire("OnTickEvenPaused")
check(S.modData().meta.seq == 3 and e2 ~= e1, "E2 posted seq 3 without a save")
modDataStore[EC.MODDATA_KEY] = deepCopy(saved)        -- SIGKILL: the next start loads the E1 save again
nowMs = nowMs + 1000
fire("OnServerStarted")                       -- E3
local meta = S.modData().meta
check(meta.loadedSeq == 2 and meta.epoch ~= e2, "E3 loads seq 2 under a new epoch")
check(S.isRolledBack(e2, 3) == true, "E2's seq 3 is flagged rolled back although the save never heard of E2")
check(S.isRolledBack(e1, 2) == false and S.isRolledBack(e1, 1) == false, "E1's saved rows stay valid")
check(S.isRolledBack(e2, 2) == false, "E2's inherited rows (seq <= loadedSeq) are not rolled back")
local ef = files["MinidoracatEconomy/epochs.json"]
check(ef and #ef.lines == 3, "epochs.json holds one line per start")
-- a saved epoch that the bounded ModData history has forgotten must not be mistaken for a crash
local h = S.modData().meta.history
local forgotten = nil
for _, x in ipairs(h) do if x.epoch == e1 then forgotten = x end end
check(forgotten ~= nil and forgotten.loadedSeq == 2, "history keeps E1 with the seq its successor loaded (2), not its own loadedSeq (0)")

-- 啟動時 journal 自己交代崩潰邊界；稽核檔視圖把崩潰班次的管理操作標成回滾
local rbLine = nil
for _, f in pairs(files) do
    for _, l in ipairs(f.lines) do
        if string.find(l, '"type":"epoch.rolledback"', 1, true) then rbLine = EC.jsonDecode(l) end
    end
end
check(rbLine ~= nil and rbLine.crashedEpoch == e2 and rbLine.fromSeq == 3 and rbLine.epoch == meta.epoch,
    "start writes epoch.rolledback{crashedEpoch, fromSeq} under the current epoch")
-- E4: another restart before any save (the live dev pattern) must not repeat E2's rolledback line
-- although E2 is still rolled back and still unknown to the save
modDataStore[EC.MODDATA_KEY] = deepCopy(saved)
nowMs = nowMs + 1000
fire("OnServerStarted")                       -- E4
local rbPer = {}
for _, f in pairs(files) do
    for _, l in ipairs(f.lines) do
        if string.find(l, '"type":"epoch.rolledback"', 1, true) then
            local rec = EC.jsonDecode(l)
            rbPer[rec.crashedEpoch] = (rbPer[rec.crashedEpoch] or 0) + 1
        end
    end
end
ef = files["MinidoracatEconomy/epochs.json"]
local e3Line = ef and EC.jsonDecode(ef.lines[3]) or nil
check(rbPer[e2] == 1 and rbPer[meta.epoch] == 1 and S.isRolledBack(e2, 3) == true and S.isRolledBack(meta.epoch, 3) == true
    and e3Line ~= nil and e3Line.flagged ~= nil and e3Line.flagged[1] == e2 and #ef.lines == 4,
    "a restart before a save flags E3 once and does not repeat E2's line (E3's record remembers it flagged E2); both stay rolled back")
meta = S.modData().meta
-- 崩潰班次裡的一筆管理操作（稽核檔還在、稽核環已回滾）
local admin3 = fakePlayer("boss"); admin3.role = "admin"
onlinePlayers = { admin3 }
X.audit({ action = "adjust", target = "zed", currency = "survivor", delta = 7, admin = "boss", reason = "before the crash", seq = 3, epoch = e2 })
fire("OnTickEvenPaused")                      -- the queued audit line reaches the file
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.auditFile", admin3, {})
for _ = 1, 5 do fire("OnTickEvenPaused") end
local af = lastSent("admin.auditFile")
check(af ~= nil and af.args.entries ~= nil and #af.args.entries >= 1 and af.args.months ~= nil, "admin.auditFile replies the audit file entries with the months it read")
local flagged, unflagged = 0, 0
for _, e in ipairs(af.args.entries) do
    if e.epoch == e2 and e.seq == 3 then
        if e.rolledBack then flagged = flagged + 1 else unflagged = unflagged + 1 end
    end
end
check(flagged == 1 and unflagged == 0, "an audit line stamped with the crashed epoch above its loadedSeq is marked rolledBack")
onlinePlayers = {}

-- 「最近」＝兩個月收據檔；管理頁收據檔；凍結即時推送給玩家
local zedP = fakePlayer("zed")
onlinePlayers = { admin3, zedP }
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "wallet.history", zedP, { month = "recent" })
for _ = 1, 5 do fire("OnTickEvenPaused") end
local hist = lastSent("wallet.history").args
local rolledRows, liveRows = 0, 0
for _, e in ipairs(hist.entries or {}) do if e.rolledBack then rolledRows = rolledRows + 1 else liveRows = liveRows + 1 end end
check(hist.month == "recent" and rolledRows == 1 and liveRows == 2, "wallet.history recent reads the receipt files and flags the crashed line")
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.receipts", admin3, { username = "zed" })
for _ = 1, 5 do fire("OnTickEvenPaused") end
local ar = lastSent("admin.receipts").args
rolledRows = 0
for _, e in ipairs(ar.entries or {}) do if e.rolledBack then rolledRows = rolledRows + 1 end end
check(ar.username == "zed" and #ar.entries == 3 and rolledRows == 1, "admin.receipts serves the target's receipt files with rolledBack")
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.freeze", admin3, { username = "zed", frozen = true, reason = "test", requestId = "fz-1" })
local pushed = nil
for i = #sentCommands, 1, -1 do
    local c = sentCommands[i]
    if c.command == "wallet.changed" and c.player == zedP then pushed = c.args break end
end
check(pushed ~= nil and pushed.frozen == true, "freezing pushes wallet.changed{frozen=true} to the online target")
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "wallet.state", zedP, {})
check(lastSent("wallet.state").args.frozen == true, "wallet.state carries the frozen flag")
S.modData().frozen["zed"] = nil

-- admin.players：候選清單（線上優先、子字串、不分大小寫、空查詢只列線上）
local boss2 = fakePlayer("boss"); boss2.role = "admin"
local zed = fakePlayer("zed")
local ann = fakePlayer("Anna")
onlinePlayers = { boss2, zed, ann }
L.credit("Zack", "survivor", 5, "SYSTEM_MINT", { requestId = "zk", reasonCode = "t" })
L.credit("bob", "survivor", 5, "SYSTEM_MINT", { requestId = "bb", reasonCode = "t" })
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.players", boss2, { query = "" })
local pl = lastSent("admin.players").args
local names = {}
for _, p in ipairs(pl.players) do names[#names + 1] = p.username .. (p.online and "*" or "") end
check(pl.ok and table.concat(names, ",") == "Anna*,boss*,zed*", "empty query lists online players only, alphabetical")
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.players", boss2, { query = "  Z " })
pl = lastSent("admin.players").args
names = {}
for _, p in ipairs(pl.players) do names[#names + 1] = p.username .. (p.online and "*" or "") end
check(table.concat(names, ",") == "zed*,Zack" and pl.query == "z", "substring match is trimmed, case-insensitive, online first")
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.players", zed, { query = "b" })
check(lastSent("admin.players").args.error == "forbidden", "a plain player cannot list accounts")
onlinePlayers = {}
end)()

-- ===== 情境二十四：設定頁的 runtime 選項覆寫 =====
io.write("scenario 24: runtime option overrides\n")
;(function()
modDataStore[EC.MODDATA_KEY] = nil
files = {}
sentCommands = {}
SandboxVars.MinidoracatEconomy.CheckinAmount = 30
SandboxVars.MinidoracatEconomy.RemoteReadOnly = true
nowMs = nowMs + 61000
fire("OnServerStarted")
local boss = fakePlayer("boss"); boss.role = "admin"
local mod = fakePlayer("mod"); mod.role = "moderator"
onlinePlayers = { boss, mod }
local function setOpt(who, key, value, extra)
    nowMs = nowMs + 600
    local args = { key = key, value = value, requestId = "opt-" .. key .. "-" .. tostring(nowMs) }
    for k, v in pairs(extra or {}) do args[k] = v end
    fire("OnClientCommand", EC.COMMAND_MODULE, "admin.option", who, args)
    return lastSent("admin.option").args
end
local snap = Cfg.options()
check(snap.CheckinAmount.value == 30 and snap.CheckinAmount.default == 30 and snap.CheckinAmount.override == false and snap.AdminRoles.locked == true,
    "options() reports effective value, sandbox default, override flag and lock")
check(setOpt(mod, "CheckinAmount", 50).error == "forbidden", "a moderator cannot change options")
local r = setOpt(boss, "CheckinAmount", 50)
check(r.ok == true and r.options.CheckinAmount.value == 50 and r.options.CheckinAmount.override == true and EC.sandbox("CheckinAmount", 30) == 50,
    "an admin override wins over the sandbox file for every EC.sandbox read")
local pushed = nil
for i = #sentCommands, 1, -1 do
    local s = sentCommands[i]
    if s.command == "rewards.state" and s.player == mod then pushed = s.args; break end
end
check(pushed ~= nil and pushed.amount == 50, "a rewards option change pushes rewards.state to every online player at once")
check(setOpt(boss, "CheckinAmount", -1).error == "invalid_args" and setOpt(boss, "CheckinAmount", 1.5).error == "invalid_args"
    and setOpt(boss, "CheckinAmount", "50").error == "invalid_args", "range, integer and type are enforced")
check(setOpt(boss, "AdminAdjustMaxPerTx", 99999).error == "locked" and setOpt(boss, "AdminRoles", "user").error == "locked",
    "locked options (admin caps, role lists) are refused from the panel")
check(setOpt(boss, "Nope", 1).error == "unknown_option", "unknown keys are refused")
check(setOpt(boss, "RewardTimezoneUTC", 5.5).ok == true and setOpt(boss, "RewardTimezoneUTC", 5.3).error == "invalid_args",
    "half-hour timezone steps are accepted, others refused")
check(setOpt(boss, "MilestoneDays", " 1; 3 ;7").ok == true and Cfg.options().MilestoneDays.value == "1;3;7"
    and setOpt(boss, "MilestoneDays", "1;x").error == "invalid_args" and setOpt(boss, "MilestoneDays", "").error == "invalid_args",
    "integer lists are normalised and validated")
local rro = setOpt(boss, "RemoteReadOnly", false)
check(rro.ok == true and lastSent("config").args.remoteReadOnly == false,
    "a boolean option is broadcast with the config push (remoteReadOnly)")
-- Cat* keys route to the currency exchange block (single source of truth for the rate)
local rc = setOpt(boss, "CatRatePointsPerCoin", 3)
check(rc.ok == true and Cfg.currency("cat").exchange.pointsPerCoin == 3 and rc.options.CatRatePointsPerCoin.value == 3 and rc.options.CatRatePointsPerCoin.override == true,
    "exchange keys are applied to config.currencies.cat.exchange")
-- clearing an override
local cl = setOpt(boss, "CheckinAmount", nil)
check(cl.ok == true and cl.options.CheckinAmount.override == false and EC.sandbox("CheckinAmount", 30) == 30, "value=nil clears the override")
local au = X.auditEntries(50)
local optAudit = 0
for _, e in ipairs(au) do if e.action == "config" and e.currency == "options" then optAudit = optAudit + 1 end end
check(optAudit >= 4, "every option change is audited (currency=options, field=key)")
SandboxVars.MinidoracatEconomy.RemoteReadOnly = nil
SandboxVars.MinidoracatEconomy.CheckinAmount = nil
onlinePlayers = {}
end)()

-- ===== 情境二十五：終端登錄與距離閘門 =====
io.write("scenario 25: terminals\n")
;(function()
local T = S.Terminal
modDataStore[EC.MODDATA_KEY] = nil
files = {}
sentCommands = {}
worldSprites = {}
nowMs = nowMs + 61000
fire("OnServerStarted")
local boss = fakePlayer("boss"); boss.role = "admin"
local zed = fakePlayer("zed")
onlinePlayers = { boss, zed }
local function reg(who, x, y, z, extra)
    nowMs = nowMs + 600
    local args = { x = x, y = y, z = z, kind = "atm", requestId = "t" .. nowMs }
    for k, v in pairs(extra or {}) do args[k] = v end
    fire("OnClientCommand", EC.COMMAND_MODULE, "terminal.register", who, args)
    return lastSent("terminal.register").args
end
check(reg(zed, 100, 200, 0).error == "forbidden", "a player cannot register a terminal")
check(reg(boss, 100, 200, 0).error == "no_terminal_object", "an admin cannot register a bare square")
worldSprites["100,200,0"] = "MinidoracatEconomy_terminal_0"
local r = reg(boss, 100, 200, 0)
check(r.ok == true and T.count() == 1 and lastSent("terminals").args.list[1].x == 100, "registering a square with a terminal tile broadcasts the list")
check(reg(boss, 100, 200, 0).error == "already_registered", "the same square is refused twice")
check(reg(boss, 100, 200, 0, { kind = "bank" }).error == "invalid_args", "unknown terminal kinds are refused")
zed.x, zed.y, zed.z = 101.4, 201.2, 0
check(T.near(zed) == true, "1.4 tiles away on the same level is near")
zed.x = 103
check(T.near(zed) == false, "3 tiles away is not near")
zed.x, zed.z = 101, 1
check(T.near(zed) == false, "one level up is not near")
zed.z = 0
SandboxVars.MinidoracatEconomy.RemoteReadOnly = false
zed.x = 500
check(T.near(zed) == false, "RemoteReadOnly only governs opening the window: writes always need a terminal")
SandboxVars.MinidoracatEconomy.RemoteReadOnly = true
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "hello", zed, {})
local ack = lastSent("hello.ack").args
check(ack.terminals ~= nil and #ack.terminals == 1 and ack.terminals[1].id == r.id and ack.terminalRange == 2, "hello.ack carries the terminal list and range")
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "terminal.unregister", boss, { id = "nope" })
check(lastSent("terminal.unregister").args.error == "unknown_terminal", "unregistering an unknown id is refused")
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "terminal.unregister", zed, { id = r.id })
check(lastSent("terminal.unregister").args.error == "forbidden" and T.count() == 1, "a player cannot unregister")
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "terminal.unregister", boss, { id = r.id })
check(lastSent("terminal.unregister").args.ok == true and T.count() == 0 and #lastSent("terminals").args.list == 0, "an admin unregisters and everyone gets the empty list")
-- demolish: admin only; removes the world object and any registration on that square
reg(boss, 100, 200, 0)
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "terminal.demolish", zed, { x = 100, y = 200, z = 0 })
check(lastSent("terminal.demolish").args.error == "forbidden" and worldSprites["100,200,0"] ~= nil, "a player cannot demolish a terminal")
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "terminal.demolish", boss, { x = 100, y = 200, z = 0 })
check(lastSent("terminal.demolish").args.ok == true and worldSprites["100,200,0"] == nil and T.count() == 0, "an admin demolish removes the object and the registration")
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "terminal.demolish", boss, { x = 100, y = 200, z = 0 })
check(lastSent("terminal.demolish").args.error == "no_terminal_object", "demolishing an empty square is refused")
onlinePlayers = {}
end)()

-- ===== 情境二十六：商店目錄、購買、信箱交付 =====
io.write("scenario 26: system shop\n")
;(function()
local T, M, Shop = S.Terminal, S.Mailbox, S.Shop
modDataStore[EC.MODDATA_KEY] = nil
files = {}
sentCommands = {}
sentItemPackets = {}
worldSprites = { ["100,200,0"] = "MinidoracatEconomy_terminal_0" }
nowMs = nowMs + 61000
fire("OnServerStarted")
local boss = fakePlayer("boss"); boss.role = "admin"
local mod = fakePlayer("mod"); mod.role = "moderator"
local zed = fakePlayer("zed")
onlinePlayers = { boss, mod, zed }
local catalogFile = files["MinidoracatEconomy/catalog.json"]
check(catalogFile ~= nil and Shop.fileStatus().count == 13 and Shop.fileStatus().error == nil, "first start writes the default catalog.json and loads it")
local function cmd(who, name, args)
    nowMs = nowMs + 600
    args = args or {}
    args.requestId = args.requestId or (name .. nowMs)
    fire("OnClientCommand", EC.COMMAND_MODULE, name, who, args)
    return lastSent(name).args
end
local list = cmd(zed, "shop.list")
check(#list.items == 13 and list.items[1].category <= list.items[2].category and list.currency == "survivor" and list.atTerminal == false
    and type(list.revision) == "string" and list.items[1].remaining ~= nil, "shop.list returns the sorted catalog, the market currency and per-player remaining caps")
local rev = list.revision
L.credit("zed", "survivor", 100, "SYSTEM_MINT", { requestId = "seed-zed", reasonCode = "t" })
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "terminal.register", boss, { x = 100, y = 200, z = 0, kind = "atm", requestId = "t1" })
zed.x, zed.y = 150, 200
check(cmd(zed, "shop.buy", { id = "bandage", count = 2, revision = "0:stale" }).error == "catalog_changed", "a stale catalog revision is refused")
check(cmd(zed, "shop.buy", { id = "bandage", count = 2, revision = rev }).error == "not_at_terminal"
    and L.getBalance("zed", "survivor").available == 100, "buying away from a terminal is refused with zero debit")
zed.x = 101
local buy = cmd(zed, "shop.buy", { id = "bandage", count = 2, revision = rev, requestId = "b1" })
check(buy.ok == true and buy.total == 24 and buy.delivered == true and buy.balance == 76 and buy.remaining == 3
    and zed.inventory.count("Base.Bandage") == 2 and M.unclaimed("zed") == 0, "a purchase burns 24, delivers 2 bandages straight into the backpack and counts against the cap")
local stamp = zed.inventory.items[1]:getModData()[EC.PLAYER_MODDATA_KEY]
local witness = zed.modData[EC.PLAYER_MODDATA_KEY].claims[buy.mailId]
check(stamp ~= nil and stamp.mailId == buy.mailId and stamp.txId == buy.txId and stamp.epoch == S.modData().meta.epoch
    and witness ~= nil and witness.seq == stamp.seq and zed.transmitted == 1, "delivered items are stamped and the player modData holds the claim witness")
local pk = sentItemPackets[#sentItemPackets]
check(pk ~= nil and pk.container == zed.inventory and #pk.add == 2, "one sendAddItemsToContainer packet carries both items")
local dup = cmd(zed, "shop.buy", { id = "bandage", count = 2, revision = rev, requestId = "b1" })
check(dup.duplicate == true and dup.txId == buy.txId and L.getBalance("zed", "survivor").available == 76, "resending the same requestId returns the first result without a second debit")
check(cmd(zed, "shop.buy", { id = "bandage", count = 4, revision = rev }).error == "daily_cap", "exceeding the per-account daily cap is refused")
check(cmd(zed, "shop.buy", { id = "bandage", count = 3, revision = rev }).ok == true and Shop.boughtToday("zed", "bandage", nowMs) == 5, "buying up to the cap is fine")
check(cmd(zed, "shop.buy", { id = "axe", revision = rev }).error == "insufficient_funds" and L.getBalance("zed", "survivor").available == 40, "insufficient funds refuse with zero debit")
check(cmd(zed, "shop.buy", { id = "nails", count = 6, revision = rev }).error == "too_many_items", "more than 100 items per purchase is refused")
local rc = L.receipts("zed")
check(rc[#rc].kind == "shop_buy" and rc[#rc].amount == -36 and rc[#rc].counterparty == "SYSTEM_BURN" and rc[#rc].item == "Base.Bandage" and rc[#rc].qty == 3,
    "the receipt ring shows the burn with what was bought")
-- admin edits are written into catalog.json and pushed to everyone online
check(cmd(mod, "admin.catalog", { action = "set", id = "bandage", enabled = false }).error == "forbidden", "a moderator cannot change the catalog")
sentCommands = {}
local set = cmd(boss, "admin.catalog", { action = "set", id = "bandage", enabled = false, price = 99 })
local bandage = nil
for _, it in ipairs(set.items) do if it.id == "bandage" then bandage = it end end
local fileText = table.concat(files["MinidoracatEconomy/catalog.json"].lines, "\n")
check(set.ok == true and bandage.enabled == false and bandage.price == 99 and set.revision ~= rev
    and string.find(fileText, '"price":99', 1, true) ~= nil and string.find(fileText, '"enabled":false', 1, true) ~= nil
    and Shop.fileStatus().count == 13, "an admin edit disables and reprices a SKU in catalog.json itself and bumps the revision")
local pushed = nil
for _, s in ipairs(sentCommands) do if s.command == "shop.list" and s.player == zed then pushed = s.args end end
check(pushed ~= nil and pushed.revision == set.revision, "the change is pushed to every online player as a fresh shop.list")
check(cmd(zed, "shop.buy", { id = "bandage", revision = set.revision }).error == "unknown_sku", "a disabled SKU cannot be bought")
check(cmd(boss, "admin.catalog", { action = "set", id = "bandage", enabled = true, price = 12 }).ok == true and Shop.sku("bandage").enabled == true
    and Shop.sku("bandage").price == 12, "editing back restores the row")
check(cmd(boss, "admin.catalog", { action = "set", id = "nope", enabled = false }).error == "unknown_sku", "unknown SKUs cannot be edited")
check(cmd(boss, "admin.catalog", { action = "set", id = "bandage", price = 0 }).error == "invalid_args", "out-of-range values are refused")
-- a hand edit on disk since the last load must not be overwritten by the panel
files["MinidoracatEconomy/catalog.json"].lines[1] = files["MinidoracatEconomy/catalog.json"].lines[1] .. " "
check(cmd(boss, "admin.catalog", { action = "set", id = "bandage", price = 13 }).error == "catalog_stale" and Shop.sku("bandage").price == 12,
    "a file changed outside the panel is refused as stale until reloaded")
check(cmd(boss, "admin.catalog", { action = "reload" }).ok == true and cmd(boss, "admin.catalog", { action = "set", id = "bandage", price = 13 }).ok == true
    and Shop.sku("bandage").price == 13, "after a reload the edit goes through")
cmd(boss, "admin.catalog", { action = "set", id = "bandage", price = 12 })
local au = X.auditEntries(20)
local catalogAudit = 0
for _, e in ipairs(au) do if e.action == "catalog" then catalogAudit = catalogAudit + 1 end end
check(catalogAudit >= 5, "catalog edits are audited per field")
rev = cmd(zed, "shop.list").revision
-- backpack full -> stays in the mailbox until claimed at a terminal
zed.inventory.maxWeight = 0.5
rev = cmd(zed, "shop.list").revision
local plank = cmd(zed, "shop.buy", { id = "plank", revision = rev })
check(plank.ok == true and plank.delivered == false and plank.deliveryError == "backpack_full" and M.unclaimed("zed") == 1
    and L.getBalance("zed", "survivor").available == 10, "a purchase that does not fit is paid and parked in the mailbox")
local ml = cmd(zed, "mail.list")
check(#ml.entries == 1 and ml.entries[1].item == "Base.Plank" and ml.entries[1].qty == 5 and ml.unclaimed == 1, "mail.list shows the parked entry")
zed.x = 150
check(cmd(zed, "mail.claim", { mailId = plank.mailId }).error == "not_at_terminal", "claiming away from a terminal is refused")
zed.x = 101
check(cmd(zed, "mail.claim", { mailId = plank.mailId }).error == "backpack_full" and M.unclaimed("zed") == 1, "claiming with a full backpack keeps the entry ready")
zed.inventory.maxWeight = 50
local cl = cmd(zed, "mail.claim", { mailId = plank.mailId })
check(cl.ok == true and zed.inventory.count("Base.Plank") == 5 and M.unclaimed("zed") == 0 and #cl.entries == 0, "claiming at a terminal delivers the planks")
check(cmd(zed, "mail.claim", { mailId = plank.mailId }).error == "already_claimed", "an entry cannot be claimed twice")
-- mailbox cap
L.credit("zed", "survivor", 1000, "SYSTEM_MINT", { requestId = "seed-zed-2", reasonCode = "t" })
zed.inventory.maxWeight = 0
SandboxVars.MinidoracatEconomy.MailboxPerAccount = 2
cmd(zed, "shop.buy", { id = "rope", revision = rev })
cmd(zed, "shop.buy", { id = "rope", revision = rev })
check(cmd(zed, "shop.buy", { id = "rope", revision = rev }).error == "mailbox_full" and M.unclaimed("zed") == 2, "a full mailbox refuses new purchases before any debit")
check(M.capacity() == 2 and M.usage("zed").unclaimed == 2 and M.usage("zed").capacity == 2, "the sandbox option is the capacity and the usage reply carries it")
SandboxVars.MinidoracatEconomy.MailboxPerAccount = nil
-- reload: broken file keeps the previous catalog, a fixed file replaces it
files["MinidoracatEconomy/catalog.json"] = { lines = { "{ \"items\": [ { \"id\": \"x\" " }, opens = 0 }
local bad = cmd(boss, "admin.catalog", { action = "reload" })
check(bad.ok == false and bad.error == "catalog_invalid" and bad.count == 13 and bad.file.error ~= nil, "a broken catalog.json is rejected and the previous catalog stays")
files["MinidoracatEconomy/catalog.json"] = { lines = { '{"items":[{"id":"ghost","item":"Base.Nope","price":5}]}' }, opens = 0 }
local ghost = cmd(boss, "admin.catalog", { action = "reload" })
check(ghost.ok == false and string.find(ghost.detail, "ghost", 1, true) ~= nil and Shop.fileStatus().count == 13, "an unknown item type names the offending SKU and keeps the previous catalog")
files["MinidoracatEconomy/catalog.json"] = { lines = { '{"items":[{"id":"only","item":"Base.Twine","qty":2,"price":7,"dailyCap":0,"category":"z"}]}' }, opens = 0 }
local good = cmd(boss, "admin.catalog", { action = "reload" })
check(good.ok == true and good.count == 1 and good.items[1].id == "only" and good.items[1].remaining == nil and good.revision ~= rev, "a valid file replaces the catalog and bumps the revision")
check(cmd(mod, "admin.catalog", { action = "reload" }).error == "forbidden" and cmd(mod, "admin.catalog", { action = "list" }).ok == true, "reload needs the write gate, list only the read gate")
onlinePlayers = {}
end)()

-- ===== 情境二十七：登入收斂（規則三）與死亡封存（規則五） =====
io.write("scenario 27: mailbox reconciliation\n")
;(function()
local function deepCopy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = deepCopy(v) end
    return out
end
local M, Shop = S.Mailbox, S.Shop
local KEY = EC.PLAYER_MODDATA_KEY
modDataStore[EC.MODDATA_KEY] = nil
files = {}
sentCommands = {}
sentItemPackets = {}
worldSprites = { ["100,200,0"] = "MinidoracatEconomy_terminal_0" }
nowMs = nowMs + 61000
fire("OnServerStarted")
local boss = fakePlayer("boss"); boss.role = "admin"
local zed = fakePlayer("zed")
zed.x, zed.y = 101, 200
onlinePlayers = { boss, zed }
local function cmd(who, name, args)
    nowMs = nowMs + 600
    args = args or {}
    args.requestId = args.requestId or (name .. nowMs)
    fire("OnClientCommand", EC.COMMAND_MODULE, name, who, args)
    local s = lastSent(name)
    return s and s.args or {}
end
local function anomalies(resolution)
    fire("OnTickEvenPaused")                  -- events are queued; the tick writes them out
    local n = 0
    for _, f in pairs(files) do
        for _, l in ipairs(f.lines) do
            if string.find(l, '"type":"ledger.anomaly"', 1, true) and string.find(l, '"resolution":"' .. resolution .. '"', 1, true) then n = n + 1 end
        end
    end
    return n
end
cmd(boss, "terminal.register", { x = 100, y = 200, z = 0, kind = "atm" })
L.credit("zed", "survivor", 1000, "SYSTEM_MINT", { requestId = "seed", reasonCode = "t" })
local rev = cmd(zed, "shop.list").revision
local b1 = cmd(zed, "shop.buy", { id = "bandage", revision = rev })
check(b1.delivered == true and zed.inventory.count("Base.Bandage") == 1, "setup: one bandage delivered")
-- rule three (1): player save older than the claim = no witness and no item -> redeliver
zed.inventory.items = {}
zed.modData[KEY].claims = {}
cmd(zed, "hello")
check(zed.inventory.count("Base.Bandage") == 1 and zed.modData[KEY].claims[b1.mailId] ~= nil and anomalies("redelivered") == 1,
    "claimed entry without witness or item is redelivered and re-witnessed")
-- normal consumption: witness present, item gone -> nothing
zed.inventory.items = {}
cmd(zed, "hello")
check(zed.inventory.count("Base.Bandage") == 0 and anomalies("redelivered") == 1, "a witnessed claim whose item was used is not redelivered")
-- rule three (2): world save older than the player save = entry ready but the item is there
local b2 = cmd(zed, "shop.buy", { id = "twine", revision = rev })
local o = S.modData().mailbox.byOwner.zed
o.entries[b2.mailId].state = "ready"; o.unclaimed = o.unclaimed + 1; S.modData().mailbox.unclaimed = S.modData().mailbox.unclaimed + 1
cmd(zed, "hello")
check(o.entries[b2.mailId].state == "claimed" and M.unclaimed("zed") == 0 and anomalies("mark-claimed") == 1, "a ready entry whose item is already in the backpack is marked claimed")
-- rule three (3): the claim rolled back with the world (money is back) -> stamped item is taken back
fire("OnTickEvenPaused")
local saved = deepCopy(modDataStore[EC.MODDATA_KEY])
local balanceBefore = L.getBalance("zed", "survivor").available
local b3 = cmd(zed, "shop.buy", { id = "lighter", count = 2, revision = rev })
check(b3.delivered == true and zed.inventory.count("Base.Lighter") == 2, "setup: two lighters delivered after the save point")
modDataStore[EC.MODDATA_KEY] = deepCopy(saved)
nowMs = nowMs + 1000
fire("OnServerStarted")
onlinePlayers = { boss, zed }
sentItemPackets = {}
cmd(zed, "hello")
local removed = 0
for _, pk in ipairs(sentItemPackets) do if pk.remove ~= nil then removed = removed + 1 end end
check(zed.inventory.count("Base.Lighter") == 0 and L.getBalance("zed", "survivor").available == balanceBefore and removed == 2
    and zed.modData[KEY].claims[b3.mailId] == nil and anomalies("removed-rolled-back") == 1,
    "every item of a claim that rolled back with the world is removed (the money came back) and its witness dropped")
-- a durable claim whose entry was pruned after the TTL is left alone
rev = cmd(zed, "shop.list").revision
local b4 = cmd(zed, "shop.buy", { id = "twine", revision = rev })
nowMs = nowMs + M.CLAIMED_TTL_MS + M.PRUNE_EVERY_MS + 1000
fire("OnTickEvenPaused")
check(S.modData().mailbox.byOwner.zed == nil or S.modData().mailbox.byOwner.zed.entries[b4.mailId] == nil, "claimed entries are pruned after the TTL")
cmd(zed, "hello")
check(zed.inventory.count("Base.Twine") >= 1 and anomalies("removed-rolled-back") == 1, "a durable stamped item without an entry is kept")
-- rule five (1): death settles claimed entries; the new character gets nothing again
local b5 = cmd(zed, "shop.buy", { id = "bandage", revision = rev })
check(b5.delivered == true, "setup: bandage delivered before death")
fire("OnCharacterDeath", zed)
check(S.modData().mailbox.byOwner.zed.entries[b5.mailId].state == "settled", "death marks claimed entries settled")
zed.inventory = fakeInventory(20)
zed.modData = {}
cmd(zed, "hello")
check(zed.inventory.count("Base.Bandage") == 0 and anomalies("redelivered") == 1, "a settled entry is never redelivered to the new character")
-- a ready entry survives death and can still be claimed by the new character
zed.inventory.maxWeight = 0
local b6 = cmd(zed, "shop.buy", { id = "plank", revision = rev })
check(b6.delivered == false and M.unclaimed("zed") == 1, "setup: parked entry")
fire("OnCharacterDeath", zed)
zed.inventory = fakeInventory(50)
zed.modData = {}
cmd(zed, "hello")
check(M.unclaimed("zed") == 1 and cmd(zed, "mail.claim", { mailId = b6.mailId }).ok == true and zed.inventory.count("Base.Plank") == 5, "ready entries stay claimable after death")
onlinePlayers = {}
end)()

-- ===== 情境二十七之二：客戶端分頁／篩選 helper（shared） =====
io.write("scenario 27b: filterPage / parseDay\n")
;(function()
check(EC.parseDay("2026-09-07", 0) == 1788739200000 and EC.parseDay("2026/9/7", 480) == 1788739200000 - 480 * 60000, "parseDay gives the civil day start in ms, shifted by the clock offset")
check(EC.parseDay("2026-13-01", 0) == nil and EC.parseDay("nope", 0) == nil and EC.parseDay(nil, 0) == nil, "malformed dates are nil")
local rows = {}
for i = 1, 60 do rows[i] = { kind = (i % 3 == 0) and "sold" or "listed", ts = 1788739200000 + i * 3600000, price = (i * 7) % 50, name = "n" .. (61 - i) } end
local page, p, pages, total = EC.filterPage(rows, { perPage = 25, page = 3 })
check(#page == 10 and p == 3 and pages == 3 and total == 60 and page[1] == rows[51], "paging keeps input order and clamps the last page")
page, p = EC.filterPage(rows, { perPage = 25, page = 9 })
check(p == 3 and #page == 10, "a page past the end clamps to the last page")
page, p, pages, total = EC.filterPage(rows, { kinds = { sold = true }, perPage = 100 })
check(total == 20 and page[1].kind == "sold" and page[20] == rows[60], "kind filter")
page, p, pages, total = EC.filterPage(rows, { fromMs = 1788739200000 + 10 * 3600000, toMs = 1788739200000 + 20 * 3600000, perPage = 100 })
check(total == 10 and page[1] == rows[10] and page[10] == rows[19], "date window is [from, to)")
page = EC.filterPage(rows, { sortKey = "price", desc = true, perPage = 100 })
check(page[1].price >= page[2].price and page[99 - 40].price >= page[60].price, "sort by a numeric field, descending")
page = EC.filterPage(rows, { sortKey = "name", perPage = 100 })
check(page[1].name == "n1" and page[2].name == "n10", "string sort is case-insensitive lexical")
page = EC.filterPage(rows, { sortKey = function(e) return e.ts end, perPage = 100 })
check(page[1] == rows[1] and page[60] == rows[60], "a function sort key works")
end)()

-- ===== 情境二十八：白名單與快照 codec =====
io.write("scenario 28: whitelist + codec\n")
;(function()
local Codec = S.Codec
modDataStore[EC.MODDATA_KEY] = nil
files = {}
sentCommands = {}
nowMs = nowMs + 61000
fire("OnServerStarted")
check(files["MinidoracatEconomy/whitelist.json"] ~= nil and Codec.status().error == nil and Codec.status().counts.categories >= 20, "first start writes the default whitelist.json")
local axe = instanceItem("Base.Axe"); axe.condition = 3; axe.repaired = 2
check(Codec.check(axe) == true, "a tool weapon is whitelisted")
local bag = instanceItem("Base.Bag_ALICEpack")
local okB, whyB = Codec.check(bag)
check(okB == false and whyB == "not_whitelisted", "containers are refused whatever the file says")
local apple = instanceItem("Base.Apple")
check(Codec.check(apple) == true, "perishable food is listable (it keeps ageing in escrow, see below)")
apple.rotten = true
local okA, whyA = Codec.check(apple)
check(okA == false and whyA == "perishable", "rotten food is refused")
local corn = instanceItem("Base.CannedCorn")
check(Codec.check(corn) == true, "non-perishable food passes")
local book = instanceItem("Base.BookCarpentry1"); book.readPages = 3
check(Codec.check(book) == true and Codec.rebuild(Codec.snapshot(book)).readPages == 3, "a read book is listable and keeps its page count")
axe.equipped = true
local okE, whyE = Codec.check(axe)
check(okE == false and whyE == "equipped", "an equipped item is refused")
axe.equipped = false
-- modData travels with the snapshot (vanilla writes customName / condition:* there, InventoryItem.java:3255, 3268)
axe.modData.SomeModState = 1
axe.modData.nested = { a = "x", b = { c = true } }
axe:setName("Old Reliable"); axe:setCustomName(true)
check(Codec.check(axe) == true, "mod data is never a reason by itself")
local axeSnap = Codec.snapshot(axe)
check(axeSnap.name == "Old Reliable" and axeSnap.modData.SomeModState == 1 and axeSnap.modData.nested.b.c == true and axeSnap.modData.customName == "Old Reliable",
    "the snapshot carries the custom name and nested modData")
local axeBack = Codec.rebuild(axeSnap)
check(axeBack.name == "Old Reliable" and axeBack.customName == true and axeBack.modData.SomeModState == 1 and axeBack.modData.nested.b.c == true, "rebuild restores name, custom flag and modData")
axe.modData.deep = { a = { b = { c = 1 } } }
local okD, whyD = Codec.check(axe)
check(okD == false and whyD == "moddata_too_big", "modData nested deeper than the snapshot may carry is refused")
axe.modData.deep = nil
axe.modData.big = string.rep("x", 200)
local okS, whyS = Codec.check(axe)
check(okS == false and whyS == "moddata_too_big", "an oversized modData string is refused")
axe.modData.big = nil
axe.modData.SomeModState = nil; axe.modData.nested = nil
axe.modData[EC.PLAYER_MODDATA_KEY] = { mailId = "old" }
check(Codec.check(axe) == true and Codec.snapshot(axe).modData[EC.PLAYER_MODDATA_KEY] == nil, "our own claim stamp never blocks a listing and is not carried")
-- perishable food: state round-trips and the hours spent in escrow age it (Food.java:774)
worldHours = 1000
apple.rotten = false; apple.age = 2; apple.hunger = -4; apple.cooked = true
local appleSnap = Codec.snapshot(apple)
check(appleSnap.food.listedHours == 1000 and appleSnap.food.hunger == -4 and appleSnap.food.cooked == true, "the food snapshot keeps hunger, cooked state and the listing hour")
worldHours = 1048
local appleBack = Codec.rebuild(appleSnap)
check(appleBack.age == 4 and appleBack.hunger == -4 and appleBack.cooked == true, "48 world hours in escrow add two days of age (rot speed 1)")
worldHours = 1000
check(Codec.rebuild(appleSnap).age == 2, "no elapsed time, no extra age")
-- snapshot / rebuild round trip incl. fluid + allowed modData
files["MinidoracatEconomy/whitelist.json"] = { lines = { '{"categories":["ToolWeapon","VehicleMaintenance"],"types":["Base.Nails"],"excludeTypes":["Base.Saw"]}' }, opens = 0 }
check(Codec.load() == true and Codec.status().counts.types == 1, "a hand-edited whitelist loads")
check(Codec.check(instanceItem("Base.Nails")) == true and Codec.check(instanceItem("Base.Saw")) == false and Codec.check(instanceItem("Base.Bandage")) == false,
    "types / excludeTypes / categories from the file are honoured")
local can = instanceItem("Base.PetrolCan"); can:getFluidContainer():addFluid(Fluid.Get("Petrol"), 3.5); can.condition = 7; can.modData.Keep = "yes"; can.modData[EC.PLAYER_MODDATA_KEY] = { mailId = "x" }
local snap = Codec.snapshot(can)
check(snap.type == "Base.PetrolCan" and snap.condition == 7 and snap.fluid.name == "Petrol" and snap.fluid.amount == 3.5 and snap.modData.Keep == "yes" and snap.modData[EC.PLAYER_MODDATA_KEY] == nil,
    "the snapshot keeps condition, fluid and modData and drops the claim stamp")
local back = Codec.rebuild(snap)
check(back ~= nil and back.condition == 7 and back.fluidName == "Petrol" and back.fluidAmount == 3.5 and back.modData.Keep == "yes", "rebuild restores the same fields")
local weapon = instanceItem("Base.Axe"); local scope = instanceItem("Base.x2Scope"); weapon:attachWeaponPart(scope)
local inv = fakeInventory(50)
check(Codec.detachParts(weapon, inv) == 1 and #weapon.parts == 0 and inv.count("Base.x2Scope") == 1, "weapon parts are detached back into the backpack")
files["MinidoracatEconomy/whitelist.json"] = { lines = { '{"categories": 5}' }, opens = 0 }
local okL, errL = Codec.load()
check(okL == false and Codec.status().error ~= nil and Codec.check(instanceItem("Base.Nails")) == true, "a broken file is rejected and the previous whitelist stays")
-- 固定類別走 ItemType（Moveable 的 getCategory 是 "Item"，主類別字串擋不住）：分類允許也不能上架
files["MinidoracatEconomy/whitelist.json"] = { lines = { '{"categories":["Furniture","Communications","Tool"],"types":[],"excludeTypes":[]}' }, opens = 0 }
check(Codec.load() == true and Codec.check(instanceItem("Base.Mov_Chair")) == false and Codec.check(instanceItem("Base.Saw")) == true,
    "furniture is refused by item class even when its display category is whitelisted")
-- 無線電：DeviceData 隨快照走（頻道、電量、開關、音量、耳機、靜音、電池、媒體）
local radio = instanceItem("Base.RadioRed"); radio.dev.channel = 93200; radio.dev.power = 0.4; radio.dev.on = true; radio.dev.volume = 0.8; radio.dev.headphones = 2; radio.dev.battery = false
check(Codec.check(radio) == true, "a radio is listable when its category is on")
local radioSnap = Codec.snapshot(radio)
check(radioSnap.device.channel == 93200 and radioSnap.device.on == true and radioSnap.device.battery == false, "the snapshot keeps the tuned state")
local radioBack = Codec.rebuild(radioSnap)
check(radioBack.dev.channel == 93200 and radioBack.dev.power == 0.4 and radioBack.dev.on == true and radioBack.dev.volume == 0.8 and radioBack.dev.headphones == 2 and radioBack.dev.battery == false,
    "rebuild restores channel, power, switch, volume, headphones and battery")
-- 面板寫回：一次一個分類或一件物品，寫進檔案、重讀、稽核；手改過的檔案先擋 stale
local boss = fakePlayer("boss"); boss.role = "admin"
local mod = fakePlayer("mod"); mod.role = "moderator"
local function wcmd(who, args)
    nowMs = nowMs + 700
    args.requestId = "w" .. nowMs
    fire("OnClientCommand", EC.COMMAND_MODULE, "admin.whitelist", who, args)
    return lastSent("admin.whitelist").args
end
local st = wcmd(mod, { action = "status" })
check(st.ok == true and #st.whitelist.categories == 3 and st.whitelist.categories[1] == "Furniture" and st.perms.write == false, "status carries the lists and the read-only role sees them")
check(wcmd(mod, { action = "set", category = "Tool", allowed = false }).error == "forbidden", "a moderator cannot edit the whitelist")
local off = wcmd(boss, { action = "set", category = "Tool", allowed = false })
local wlText = table.concat(files["MinidoracatEconomy/whitelist.json"].lines, "\n")
check(off.ok == true and #off.whitelist.categories == 2 and string.find(wlText, '"categories": ["Furniture","Communications"]', 1, true) ~= nil
    and Codec.check(instanceItem("Base.Saw")) == false, "turning a category off rewrites the file and takes effect at once")
check(wcmd(boss, { action = "set", category = "Tool", allowed = true }).whitelist.categories[3] == "Tool" and Codec.check(instanceItem("Base.Saw")) == true, "turning it back on appends it")
check(wcmd(boss, { action = "set", category = "Tool", allowed = true }).ok == true and #files["MinidoracatEconomy/whitelist.json"].lines == 5, "a no-op edit does not rewrite the file")
local ex = wcmd(boss, { action = "set", fullType = "Base.Saw", mode = "exclude" })
check(ex.ok == true and ex.whitelist.excludeTypes[1] == "Base.Saw" and Codec.check(instanceItem("Base.Saw")) == false, "an item exclusion beats its allowed category")
local al = wcmd(boss, { action = "set", fullType = "Base.Saw", mode = "allow" })
check(al.ok == true and #al.whitelist.excludeTypes == 0 and al.whitelist.types[1] == "Base.Saw", "switching to allow moves the item between the two lists")
check(wcmd(boss, { action = "set", fullType = "Base.Nails", mode = "allow" }).ok == true and Codec.check(instanceItem("Base.Nails")) == true, "an explicit allow lists an item whose category is off")
local inh = wcmd(boss, { action = "set", fullType = "Base.Nails", mode = "inherit" })
check(inh.ok == true and #inh.whitelist.types == 1 and Codec.check(instanceItem("Base.Nails")) == false, "inherit clears the override")
check(wcmd(boss, { action = "set", fullType = "Base.Nope", mode = "allow" }).error == "unknown_item", "unknown item types are refused")
check(wcmd(boss, { action = "set", category = "bad cat", allowed = true }).error == "invalid_args" and wcmd(boss, { action = "set", fullType = "Base.Saw", mode = "maybe" }).error == "invalid_args", "malformed edits are refused")
files["MinidoracatEconomy/whitelist.json"].lines[1] = files["MinidoracatEconomy/whitelist.json"].lines[1] .. " "
check(wcmd(boss, { action = "set", category = "Communications", allowed = false }).error == "whitelist_stale" and Codec.check(instanceItem("Base.RadioRed")) == true and Codec.status().counts.categories == 3,
    "a file changed outside the panel is refused as stale until reloaded")
check(wcmd(boss, { action = "reload" }).ok == true and wcmd(boss, { action = "set", category = "Communications", allowed = false }).ok == true
    and Codec.check(instanceItem("Base.RadioRed")) == false and Codec.status().counts.categories == 2, "after a reload the edit goes through and the radio category is off")
local wlAudit = 0
for _, e in ipairs(X.auditEntries(30)) do if e.action == "whitelist" then wlAudit = wlAudit + 1 end end
check(wlAudit == 8, "every applied edit and the reload are audited once (no-ops and refusals are not)")
onlinePlayers = {}
end)()

-- ===== 情境二十九：市場全流程（上架、瀏覽、購買、取消、到期、費稅守恆） =====
io.write("scenario 29: market\n")
;(function()
local Mk, M, T = S.Market, S.Mailbox, S.Terminal
modDataStore[EC.MODDATA_KEY] = nil
files = {}
sentCommands = {}
sentItemPackets = {}
worldSprites = { ["100,200,0"] = "MinidoracatEconomy_terminal_0" }
SandboxVars.MinidoracatEconomy.MarketListingFeePercent = 2
SandboxVars.MinidoracatEconomy.MarketSalesTaxPercent = 5
SandboxVars.MinidoracatEconomy.MarketMaxListings = 2
nowMs = nowMs + 61000
fire("OnServerStarted")
local boss = fakePlayer("boss"); boss.role = "admin"
local ann = fakePlayer("ann"); ann.x, ann.y = 101, 200; ann.inventory = fakeInventory(50)
local bob = fakePlayer("bob"); bob.x, bob.y = 101, 201; bob.inventory = fakeInventory(50)
local cat = fakePlayer("cat"); cat.x, cat.y = 101, 199; cat.inventory = fakeInventory(50)
onlinePlayers = { boss, ann, bob, cat }
local function cmd(who, name, args)
    nowMs = nowMs + 600
    args = args or {}
    args.requestId = args.requestId or (name .. nowMs)
    fire("OnClientCommand", EC.COMMAND_MODULE, name, who, args)
    local s = lastSent(name)
    return s and s.args or {}
end
cmd(boss, "terminal.register", { x = 100, y = 200, z = 0, kind = "atm" })
L.credit("ann", "survivor", 100, "SYSTEM_MINT", { requestId = "s-ann", reasonCode = "t" })
L.credit("bob", "survivor", 500, "SYSTEM_MINT", { requestId = "s-bob", reasonCode = "t" })
L.credit("cat", "survivor", 500, "SYSTEM_MINT", { requestId = "s-cat", reasonCode = "t" })
local axe = instanceItem("Base.Axe"); axe.condition = 4; ann.inventory:AddItem(axe)
local bag = instanceItem("Base.Bag_ALICEpack"); ann.inventory:AddItem(bag)
local cands = cmd(ann, "market.candidates")
local okRows, badRows = 0, 0
for _, r in ipairs(cands.items) do if r.ok then okRows = okRows + 1 else badRows = badRows + 1 end end
check(okRows == 1 and badRows == 1 and cands.feePercent == 2 and cands.priceMin == 1, "candidates list every backpack item with its verdict")
check(cmd(ann, "market.list", { itemId = axe.id, price = 0 }).error == "price_range", "a price outside the sandbox range is refused")
ann.x = 150
check(cmd(ann, "market.list", { itemId = axe.id, price = 200 }).error == "not_at_terminal" and ann.inventory.count("Base.Axe") == 1, "listing away from a terminal is refused and the item stays")
ann.x = 101
check(cmd(ann, "market.list", { itemId = bag.id, price = 50 }).error == "not_whitelisted", "a container cannot be listed")
local listed = cmd(ann, "market.list", { itemId = axe.id, price = 200, requestId = "l1" })
check(listed.ok == true and listed.fee == 4 and ann.inventory.count("Base.Axe") == 0 and L.getBalance("ann", "survivor").available == 96
    and Mk.hasListing(listed.listingId) and #listed.mine == 1, "listing removes the item, burns the 2 percent fee and creates the listing")
local pend = ann.modData[EC.PLAYER_MODDATA_KEY].pendingOuts[listed.listingId]
check(pend ~= nil and pend.itemId == axe.id and pend.snapshot.condition == 4 and pend.price == 200 and ann.transmitted >= 1, "the seller's own modData keeps the pending list-out record with the snapshot")
check(cmd(ann, "market.list", { itemId = axe.id, price = 200, requestId = "l1" }).duplicate == true and #Mk.mine("ann") == 1, "resending the same listing request is idempotent")
-- browse
local page = cmd(bob, "market.browse", { sort = "time" })
check(page.total == 1 and page.items[1].id == listed.listingId and page.items[1].seller == "ann" and page.items[1].condition == 4 and page.categories[1] == "ToolWeapon" and page.currency == "survivor",
    "browse lists the listing with its snapshot summary and category")
check(cmd(bob, "market.browse", { query = "axe" }).total == 1 and cmd(bob, "market.browse", { query = "hammer" }).total == 0 and cmd(bob, "market.browse", { category = "Food" }).total == 0,
    "browse filters by query and category")
-- max listings
local n1 = instanceItem("Base.Nails"); ann.inventory:AddItem(n1)
local n2 = instanceItem("Base.Nails"); ann.inventory:AddItem(n2)
check(cmd(ann, "market.list", { itemId = n1.id, price = 5 }).ok == true and cmd(ann, "market.list", { itemId = n2.id, price = 5 }).error == "too_many_listings",
    "the per-player listing cap is enforced")
-- buy: own listing refused, wrong price refused, two buyers race
check(cmd(ann, "market.buy", { listingId = listed.listingId }).error == "own_listing", "a seller cannot buy their own listing")
check(cmd(bob, "market.buy", { listingId = listed.listingId, price = 150 }).error == "price_changed", "a confirmation price that differs is refused")
local bought = cmd(bob, "market.buy", { listingId = listed.listingId, price = 200, requestId = "b1" })
check(bought.ok == true and bought.tax == 10 and bought.delivered == true and bob.inventory.count("Base.Axe") == 1 and bob.inventory.items[#bob.inventory.items].condition == 4
    and L.getBalance("bob", "survivor").available == 300 and L.getBalance("ann", "survivor").available == 285 and not Mk.hasListing(listed.listingId),
    "a sale moves 200 from the buyer, 190 to the seller (96 - 1 nails fee + 190), burns 10 tax and delivers the rebuilt item")
check(cmd(cat, "market.buy", { listingId = listed.listingId, price = 200 }).error == "unknown_listing" and L.getBalance("cat", "survivor").available == 500,
    "the second buyer of the same listing is refused with zero debit")
check(cmd(bob, "market.buy", { listingId = listed.listingId, price = 200, requestId = "b1" }).duplicate == true and L.getBalance("bob", "survivor").available == 300,
    "resending the purchase is idempotent")
check(L.conservation("survivor") == 0, "fee and tax burns keep the currency conserved")
local rc = L.receipts("ann")
check(rc[#rc].kind == "market_buy" and rc[#rc].amount == 190 and rc[#rc].item == "Base.Axe", "the seller's receipt shows the net proceeds and the item")
-- cancel: back to the seller through the mailbox
local mine = Mk.mine("ann")
local nailsId = mine[1].id
check(cmd(bob, "market.cancel", { listingId = nailsId }).error == "not_owner", "only the seller can cancel")
local cancelled = cmd(ann, "market.cancel", { listingId = nailsId })
check(cancelled.ok == true and cancelled.delivered == true and ann.inventory.count("Base.Nails") == 2 and not Mk.hasListing(nailsId) and L.getBalance("ann", "survivor").available == 285,
    "cancel returns the item through the mailbox; the fee is not refunded")
-- a listing occupies a mailbox slot: with the capacity at the current usage nothing new can be
-- listed or bought, while a return (expiry here) just converts the slot and never fails
local n3 = cmd(ann, "market.list", { itemId = n2.id, price = 5 })
check(n3.ok == true and M.used("ann") == Mk.ownerCount("ann") + M.unclaimed("ann") and Mk.ownerCount("ann") >= 1, "an active listing counts against the mailbox slots")
SandboxVars.MinidoracatEconomy.MailboxPerAccount = M.used("ann")
local n4 = instanceItem("Base.Nails"); ann.inventory:AddItem(n4)
check(cmd(ann, "market.list", { itemId = n4.id, price = 5 }).error == "mailbox_full" and ann.inventory.count("Base.Nails") >= 1, "a full mailbox refuses a new listing and the item stays")
nowMs = nowMs + 8 * 86400000
fire("OnTickEvenPaused")
check(not Mk.hasListing(n3.listingId) and M.unclaimed("ann") == 1 and M.used("ann") <= M.capacity(), "an expired listing goes back to the seller's mailbox even when it is full, without overshooting")
SandboxVars.MinidoracatEconomy.MailboxPerAccount = nil
local expired = 0
fire("OnTickEvenPaused")
for _, f in pairs(files) do for _, l in ipairs(f.lines) do if string.find(l, '"type":"market.expired"', 1, true) then expired = expired + 1 end end end
check(expired == 1, "expiry is journaled")
-- admin delist
local h1 = instanceItem("Base.Hammer"); cat.inventory:AddItem(h1)
local lh = cmd(cat, "market.list", { itemId = h1.id, price = 80 })
check(cmd(bob, "admin.listings", { action = "delist", listingId = lh.listingId }).error == "forbidden", "a player cannot delist")
local dl = cmd(boss, "admin.listings", { action = "delist", listingId = lh.listingId, reason = "spam" })
check(dl.ok == true and not Mk.hasListing(lh.listingId) and M.unclaimed("cat") == 1 and dl.total == 0, "an admin delist returns the item to the seller mailbox and is audited")
local au = X.auditEntries(5)
check(au[1].action == "delist" and au[1].target == "cat", "delist audit row")
-- lots: identical copies fold into one candidate row and list as one listing with qty
sentCommands = {}
local p1, p2, p3 = instanceItem("Base.Plank"), instanceItem("Base.Plank"), instanceItem("Base.Plank")
local s1 = instanceItem("Base.Saw"); s1.condition = 4
for _, it in ipairs({ p1, p2, p3, s1 }) do cat.inventory:AddItem(it) end
local cands = cmd(cat, "market.candidates").items
local plankRow, sawRow = nil, nil
for _, r in ipairs(cands) do
    if r.item == "Base.Plank" then plankRow = r elseif r.item == "Base.Saw" then sawRow = r end
end
check(plankRow and plankRow.count == 3 and #plankRow.itemIds == 3 and sawRow and sawRow.count == 1, "three identical planks are one candidate row with three itemIds")
check(cmd(cat, "market.list", { itemIds = { p1.id, s1.id }, price = 30 }).error == "mixed_items", "a lot must be interchangeable copies")
check(cmd(cat, "market.list", { itemIds = { p1.id, p1.id }, price = 30 }).error == "invalid_args", "the same item twice is refused")
local lot = cmd(cat, "market.list", { itemIds = { p1.id, p2.id, p3.id }, price = 30 })
check(lot.ok == true and lot.qty == 3 and cat.inventory.count("Base.Plank") == 0 and Mk.mine("cat")[1].qty == 3 and lot.fee == 1,
    "the lot leaves the backpack as one listing of three at one price and one fee")
local pendLot = cat.modData[EC.PLAYER_MODDATA_KEY].pendingOuts[lot.listingId]
check(pendLot and pendLot.qty == 3 and #pendLot.itemIds == 3, "the pending record keeps every itemId of the lot")
local browsed = cmd(bob, "market.browse", {})
local lotRow = nil
for _, r in ipairs(browsed.items) do if r.id == lot.listingId then lotRow = r end end
check(lotRow and lotRow.qty == 3, "the browse row carries the quantity")
local function monotonic(sort, field, desc)
    local rows = Mk.browse("bob", { sort = sort }).items
    for i = 2, #rows do
        local a, b = rows[i - 1][field], rows[i][field]
        if type(a) == "string" then a, b = string.lower(a), string.lower(b) end
        if (desc and a < b) or (not desc and a > b) then return false end
    end
    return #rows >= 2
end
local h0 = instanceItem("Base.Hammer"); ann.inventory:AddItem(h0)
cmd(ann, "market.list", { itemId = h0.id, price = 7 })
check(monotonic("name", "name", false) and monotonic("name_desc", "name", true) and monotonic("seller_desc", "seller", true) and monotonic("expires", "expiresAt", false) and monotonic("price_desc", "price", true),
    "column sorts order the page by name, seller, expiry and price in both directions")
check(Mk.browse("bob", { sort = "bogus" }).sort == "time", "an unknown sort falls back to newest first")
onlinePlayers = { boss, ann, bob, cat }
sentCommands = {}
local lotBuy = cmd(bob, "market.buy", { listingId = lot.listingId, price = 30 })
check(lotBuy.ok == true and lotBuy.qty == 3 and bob.inventory.count("Base.Plank") == 3, "buying the lot delivers three rebuilt planks")
local notice = nil
for i = #sentCommands, 1, -1 do
    local c = sentCommands[i]
    if c.command == "market.notice" and c.player == cat then notice = c.args break end
end
check(notice and notice.kind == "sold" and notice.qty == 3 and notice.price == 30 and notice.buyer == "bob" and notice.unclaimed == M.unclaimed("cat"),
    "the online seller is told about the sale with the mailbox count")
-- delist notice and the market history file
local h2 = instanceItem("Base.Hammer"); cat.inventory:AddItem(h2)
local lh2 = cmd(cat, "market.list", { itemId = h2.id, price = 80 })
sentCommands = {}
cmd(boss, "admin.listings", { action = "delist", listingId = lh2.listingId, reason = "dup" })
notice = nil
for i = #sentCommands, 1, -1 do
    local c = sentCommands[i]
    if c.command == "market.notice" and c.player == cat then notice = c.args break end
end
check(notice and notice.kind == "delisted" and notice.reason == "dup" and notice.item == "Base.Hammer", "the online seller is told about a forced delist with the reason")
for _ = 1, 4 do fire("OnTickEvenPaused") end
local mpath = "MinidoracatEconomy/market/cat/" .. EC.monthKey(nowMs) .. ".json"
local kinds = {}
for _, line in ipairs((files[mpath] or { lines = {} }).lines) do
    local rec = EC.jsonDecode(line)
    if type(rec) == "table" then kinds[#kinds + 1] = rec.kind end
end
check(table.concat(kinds, ",") == "listed,delisted,listed,sold,listed,delisted", "the seller's market file journals every listing event in order: " .. table.concat(kinds, ","))
local bpath = "MinidoracatEconomy/market/bob/" .. EC.monthKey(nowMs) .. ".json"
check(files[bpath] and #files[bpath].lines == 2 and string.find(files[bpath].lines[2], '"kind":"bought"', 1, true) ~= nil, "the buyer's market file has the bought lines")
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "market.history", cat, {})
for _ = 1, 3 do fire("OnTickEvenPaused") end
local hist = lastSent("market.history").args
check(hist.username == "cat" and hist.total == 6 and hist.entries[#hist.entries].kind == "delisted" and hist.entries[#hist.entries].reason == "dup" and hist.entries[1].rolledBack == false,
    "market.history tails the player's own file")
sentCommands = {}
cmd(bob, "admin.marketHistory", { username = "cat" })
check(lastSent("admin.marketHistory") == nil or lastSent("admin.marketHistory").args.error == "forbidden", "a player cannot read another player's market history")
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.marketHistory", boss, { username = "cat" })
for _ = 1, 3 do fire("OnTickEvenPaused") end
check(lastSent("admin.marketHistory").args.total == 6, "an admin reads any player's market history")
-- a whitelist edit is broadcast so open pickers refresh
sentCommands = {}
nowMs = nowMs + 700
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.whitelist", boss, { action = "set", fullType = "Base.Hammer", mode = "exclude", requestId = "wl-x" })
local wlPush = 0
for _, c in ipairs(sentCommands) do if c.command == "market.whitelist" then wlPush = wlPush + 1 end end
check(wlPush == #onlinePlayers, "a whitelist change is pushed to every online player")
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.whitelist", boss, { action = "set", fullType = "Base.Hammer", mode = "inherit", requestId = "wl-y" })
onlinePlayers = {}
SandboxVars.MinidoracatEconomy.MarketMaxListings = nil
end)()

-- ===== 情境三十：list-out 的崩潰收斂（規則三第 4-6 列）與死亡 carryOver（規則五第 2 條） =====
io.write("scenario 30: list-out reconciliation\n")
;(function()
local function deepCopy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = deepCopy(v) end
    return out
end
local Mk, M = S.Market, S.Mailbox
local KEY = EC.PLAYER_MODDATA_KEY
modDataStore[EC.MODDATA_KEY] = nil
files = {}
sentCommands = {}
sentItemPackets = {}
worldSprites = { ["100,200,0"] = "MinidoracatEconomy_terminal_0" }
nowMs = nowMs + 61000
fire("OnServerStarted")
local boss = fakePlayer("boss"); boss.role = "admin"
local ann = fakePlayer("ann"); ann.x, ann.y = 101, 200; ann.inventory = fakeInventory(50)
onlinePlayers = { boss, ann }
local function cmd(who, name, args)
    nowMs = nowMs + 600
    args = args or {}
    args.requestId = args.requestId or (name .. nowMs)
    fire("OnClientCommand", EC.COMMAND_MODULE, name, who, args)
    local s = lastSent(name)
    return s and s.args or {}
end
local function anomalies(resolution)
    fire("OnTickEvenPaused")
    local n = 0
    for _, f in pairs(files) do for _, l in ipairs(f.lines) do
        if string.find(l, '"type":"ledger.anomaly"', 1, true) and string.find(l, '"resolution":"' .. resolution .. '"', 1, true) then n = n + 1 end
    end end
    return n
end
cmd(boss, "terminal.register", { x = 100, y = 200, z = 0, kind = "atm" })
L.credit("ann", "survivor", 100, "SYSTEM_MINT", { requestId = "s-ann", reasonCode = "t" })
fire("OnTickEvenPaused")
local saved = deepCopy(modDataStore[EC.MODDATA_KEY])           -- world save point (no listing yet)
local axe = instanceItem("Base.Axe"); axe.condition = 5; ann.inventory:AddItem(axe)
local listed = cmd(ann, "market.list", { itemId = axe.id, price = 120 })
check(listed.ok == true and ann.inventory.count("Base.Axe") == 0, "setup: listed after the save point")
local playerSave = { inv = deepCopy(ann.inventory.items), md = deepCopy(ann.modData) }  -- player save AFTER the listing (item gone, pending present)
-- row 4: world rolls back below the listing, player save is newer -> listing rebuilt from the pending snapshot
modDataStore[EC.MODDATA_KEY] = deepCopy(saved)
nowMs = nowMs + 1000
fire("OnServerStarted")
onlinePlayers = { boss, ann }
cmd(ann, "hello")
check(Mk.hasListing(listed.listingId) and anomalies("listing-restored") == 1 and ann.modData[KEY].pendingOuts[listed.listingId] ~= nil,
    "row 4: a rolled-back listing is rebuilt from the seller's pending record (pending kept until durable)")
local restored = Mk.mine("ann")[1]
check(restored.price == 120 and restored.condition == 5 and S.modData().meta.seq >= (select(2, EC.parseId(listed.listingId))), "the rebuilt listing keeps price and snapshot and the seq never goes backwards")
local restoredPend = deepCopy(ann.modData[KEY].pendingOuts[listed.listingId])
check(restoredPend.epoch == S.modData().meta.epoch, "the pending record now points at the rebuild point")
-- durable listing: after the next epoch the pending is cleared on login
fire("OnTickEvenPaused")
local saved2 = deepCopy(modDataStore[EC.MODDATA_KEY])
nowMs = nowMs + 1000
fire("OnServerStarted")
onlinePlayers = { boss, ann }
cmd(ann, "hello")
check(Mk.hasListing(listed.listingId) and ann.modData[KEY].pendingOuts[listed.listingId] == nil, "a listing that survived into a save clears the pending record at the next login")
-- row 6: the listing is durable but the player's save is older (item still there) -> the original is removed
local ghost = instanceItem("Base.Axe"); ghost.id = axe.id; ann.inventory:AddItem(ghost)
ann.modData[KEY].pendingOuts[listed.listingId] = deepCopy(restoredPend)
sentItemPackets = {}
cmd(ann, "hello")
check(ann.inventory.count("Base.Axe") == 0 and anomalies("removed-listed-original") == 1 and ann.modData[KEY].pendingOuts[listed.listingId] == nil,
    "row 6: an original that is still in an older player save is removed because the listing is authoritative")
-- row 5: crashed before the removal (pending present, item present, no listing) -> pending cleared, item stays
local hammer = instanceItem("Base.Hammer"); ann.inventory:AddItem(hammer)
ann.modData[KEY].pendingOuts["9999:1"] = { itemId = hammer.id, snapshot = { type = "Base.Hammer" }, price = 10, seq = 1, epoch = "9999" }
cmd(ann, "hello")
check(ann.inventory.count("Base.Hammer") == 1 and ann.modData[KEY].pendingOuts["9999:1"] == nil and anomalies("pending-cleared-item-present") == 1,
    "row 5: a pending op whose item never left the backpack is simply forgotten")
-- sold then durable: pending gone, no rebuild
ann.modData[KEY].pendingOuts["oldsold"] = { itemId = 424242, snapshot = { type = "Base.Nails" }, price = 3, seq = 1, epoch = "1000" }
cmd(ann, "hello")
check(ann.modData[KEY].pendingOuts["oldsold"] == nil and not Mk.hasListing("oldsold"), "a durable op whose listing is gone (sold / cancelled) clears without rebuilding")
-- rule five part two: death carries pendingOuts to the next character
local saw = instanceItem("Base.Saw"); ann.inventory:AddItem(saw)
local ls = cmd(ann, "market.list", { itemId = saw.id, price = 30 })
check(ann.modData[KEY].pendingOuts[ls.listingId] ~= nil, "setup: fresh pending on the character that is about to die")
fire("OnCharacterDeath", ann)
ann.inventory = fakeInventory(50)
ann.modData = {}
fire("OnNewGame", ann, nil)
check(ann.modData[KEY] ~= nil and ann.modData[KEY].pendingOuts[ls.listingId] ~= nil, "the new character inherits the dead one's pendingOuts")
onlinePlayers = {}
end)()

-- ===== 情境三十一：市場電台（交易站定時廣播） =====
io.write("scenario 31: market radio\n")
;(function()
local Mk, Rd = S.Market, S.Radio
modDataStore[EC.MODDATA_KEY] = nil
files = {}
sentCommands = {}
radioSent, radioChannels = {}, {}
nowMs = nowMs + 61000
SandboxVars.MinidoracatEconomy.RadioIntervalMinutes = 10
SandboxVars.MinidoracatEconomy.RadioFrequency = 101100
SandboxVars.MinidoracatEconomy.RadioRange = 500
SandboxVars.MinidoracatEconomy.RadioLanguage = "auto"
fire("OnServerStarted")
check(#radioChannels == 1 and radioChannels[1].freq == 101100 and radioChannels[1].category == "Economy", "boot registers the channel name on the server radio")
local boss = fakePlayer("boss"); boss.role = "admin"
local ann = fakePlayer("ann"); ann.x, ann.y = 101, 200; ann.inventory = fakeInventory(50)
onlinePlayers = { boss, ann }
local function cmd(who, name, args)
    nowMs = nowMs + 600
    args = args or {}
    args.requestId = args.requestId or (name .. nowMs)
    fire("OnClientCommand", EC.COMMAND_MODULE, name, who, args)
    local s = lastSent(name)
    return s and s.args or {}
end
worldSprites = { ["100,200,0"] = "MinidoracatEconomy_terminal_0", ["300,400,0"] = "MinidoracatEconomy_catgirl_1", ["500,600,1"] = "appliances_com_01_52" }
check(cmd(boss, "terminal.register", { x = 100, y = 200, z = 0, kind = "atm" }).ok == true, "setup: ATM registered")
check(cmd(boss, "terminal.register", { x = 300, y = 400, z = 0, kind = "trade" }).ok == true and cmd(boss, "terminal.register", { x = 500, y = 600, z = 1, kind = "trade" }).ok == true, "setup: two trade terminals (a catgirl tile and a vanilla console)")
cmd(ann, "hello")
local ack = lastSent("hello.ack").args
check(ack.radio and ack.radio.frequency == 101100 and ack.radio.enabled == true, "hello.ack tells the client the frequency so it can name the channel")
-- the first interval starts at boot: nothing goes out before 10 real minutes
fire("OnTickEvenPaused")
nowMs = nowMs + 5 * 60000
fire("OnTickEvenPaused")
check(#radioSent == 0, "nothing is broadcast before the first interval elapsed")
nowMs = nowMs + 5 * 60000 + 1
fire("OnTickEvenPaused")
check(#radioSent == 2, "one transmission per trade terminal, none from the ATM: " .. tostring(#radioSent))
check(radioSent[1].x == 300 and radioSent[1].y == 400 and radioSent[2].x == 500 and radioSent[2].channel == 101100 and radioSent[1].strength == 500 and radioSent[1].isTV == false,
    "the trade terminal squares are the sources, on the sandbox frequency and range")
check(radioSent[1].msg == "IGUI_MinidoracatEconomy_Radio_Empty", "an empty market says so (server-language template via getText)")
-- listings appear in the summary: count, sellers, newest first with qty and price
L.credit("ann", "survivor", 100, "SYSTEM_MINT", { requestId = "s-ann-r", reasonCode = "t" })
local axe = instanceItem("Base.Axe"); ann.inventory:AddItem(axe)
cmd(ann, "market.list", { itemId = axe.id, price = 120 })
local p1, p2 = instanceItem("Base.Plank"), instanceItem("Base.Plank")
ann.inventory:AddItem(p1); ann.inventory:AddItem(p2)
cmd(ann, "market.list", { itemIds = { p1.id, p2.id }, price = 30 })
SandboxVars.MinidoracatEconomy.RadioLanguage = "CH"
radioSent = {}
nowMs = nowMs + 10 * 60000 + 1
fire("OnTickEvenPaused")
check(#radioSent == 2 and string.find(radioSent[1].msg, "目前 2 筆刊登、1 位賣家", 1, true) ~= nil, "RadioLanguage=CH uses the mod's own CH templates: " .. tostring(radioSent[1] and radioSent[1].msg))
check(string.find(radioSent[1].msg, "最新上架：Base.Plank ×2 30 幣、Base.Axe 120 幣", 1, true) ~= nil, "newest listings first, with quantity and price: " .. tostring(radioSent[1].msg))
check(#radioSent[1].msg <= Rd.MESSAGE_MAX, "a broadcast never exceeds the message budget")
local journaled = 0
fire("OnTickEvenPaused")
for _, f in pairs(files) do for _, l in ipairs(f.lines) do if string.find(l, '"type":"radio.broadcast"', 1, true) then journaled = journaled + 1 end end end
check(journaled == 2, "every broadcast round is journaled once")
-- range 0 = everyone (engine: strength < 0 passes every player); interval 0 = off
SandboxVars.MinidoracatEconomy.RadioRange = 0
radioSent = {}
nowMs = nowMs + 10 * 60000 + 1
fire("OnTickEvenPaused")
check(#radioSent == 2 and radioSent[1].strength == -1, "range 0 becomes strength -1 (everyone)")
SandboxVars.MinidoracatEconomy.RadioIntervalMinutes = 0
radioSent = {}
nowMs = nowMs + 30 * 60000
fire("OnTickEvenPaused")
check(#radioSent == 0 and Rd.enabled() == false, "interval 0 turns the radio off")
SandboxVars.MinidoracatEconomy.RadioIntervalMinutes = nil
SandboxVars.MinidoracatEconomy.RadioFrequency = nil
SandboxVars.MinidoracatEconomy.RadioRange = nil
SandboxVars.MinidoracatEconomy.RadioLanguage = nil
onlinePlayers = {}
end)()

-- ===== 情境三十二：拍賣 =====
io.write("scenario 32: auctions\n")
;(function()
local Au, Mk, M, Rd = S.Auction, S.Market, S.Mailbox, S.Radio
local KEY = EC.PLAYER_MODDATA_KEY
local function deepCopyTable(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = deepCopyTable(v) end
    return out
end
modDataStore[EC.MODDATA_KEY] = nil
files = {}
sentCommands = {}
radioSent = {}
nowMs = nowMs + 61000
fire("OnServerStarted")
local boss = fakePlayer("boss"); boss.role = "admin"
local ann = fakePlayer("ann"); ann.x, ann.y = 101, 200; ann.inventory = fakeInventory(50)
local bob = fakePlayer("bob"); bob.x, bob.y = 101, 201; bob.inventory = fakeInventory(50)
local cat = fakePlayer("cat"); cat.x, cat.y = 101, 199; cat.inventory = fakeInventory(50)
onlinePlayers = { boss, ann, bob, cat }
local function cmd(who, name, args)
    nowMs = nowMs + 600
    args = args or {}
    args.requestId = args.requestId or (name .. nowMs)
    fire("OnClientCommand", EC.COMMAND_MODULE, name, who, args)
    local s = lastSent(name)
    return s and s.args or {}
end
local function bal(u) return L.getBalance(u, "survivor") end
local function notices(who, kind)
    local n = 0
    for _, c in ipairs(sentCommands) do if c.command == "market.notice" and c.player == who and c.args.kind == kind then n = n + 1 end end
    return n
end
worldSprites = { ["100,200,0"] = "MinidoracatEconomy_catgirl_0" }
cmd(boss, "terminal.register", { x = 100, y = 200, z = 0, kind = "trade" })
for _, u in ipairs({ "ann", "bob", "cat" }) do L.credit(u, "survivor", 500, "SYSTEM_MINT", { requestId = "au-seed-" .. u, reasonCode = "t" }) end
-- create: validation, fee, escrow, slot
local axe = instanceItem("Base.Axe"); axe.condition = 6; ann.inventory:AddItem(axe)
check(cmd(ann, "auction.create", { itemId = axe.id, startPrice = 100, hours = 2 }).error == "hours_range", "duration below the sandbox minimum is refused")
check(cmd(ann, "auction.create", { itemId = axe.id, startPrice = 0, hours = 24 }).error == "price_range", "start price must be in the market range")
local created = cmd(ann, "auction.create", { itemId = axe.id, startPrice = 100, hours = 24 })
check(created.ok == true and created.fee == 2 and ann.inventory.count("Base.Axe") == 0 and Au.hasAuction(created.auctionId) and bal("ann").available == 498,
    "creating an auction escrows the item and burns the listing fee on the start price")
check(ann.modData[KEY].pendingOuts[created.auctionId].kind == "auction" and ann.modData[KEY].pendingOuts[created.auctionId].hours == 24, "the pending record is an auction with its duration")
check(M.used("ann") == 1 and M.usage("ann").listings == 1, "an auction occupies a mailbox slot like a listing")
local browse = cmd(bob, "auction.browse", {})
check(browse.total == 1 and browse.items[1].startPrice == 100 and browse.items[1].bid == nil and browse.items[1].minNext == 100 and browse.items[1].bids == 0 and browse.minHours == 6,
    "browse shows the auction with the start price as the first acceptable bid")
-- bids: seller refused, too low refused, reserve moves the bucket, outbid releases in the same tick
local id = created.auctionId
check(cmd(ann, "auction.bid", { auctionId = id, amount = 150 }).error == "own_auction", "the seller cannot bid")
check(cmd(bob, "auction.bid", { auctionId = id, amount = 99 }).error == "bid_too_low", "a bid under the start price is refused")
sentCommands = {}
local b1 = cmd(bob, "auction.bid", { auctionId = id, amount = 100 })
check(b1.ok == true and b1.reserved == 100 and bal("bob").available == 400 and bal("bob").reserved == 100, "a bid moves the amount from available to reserved")
check(notices(ann, "auction_bid") == 1, "the seller hears about the bid")
check(cmd(cat, "auction.bid", { auctionId = id, amount = 104 }).error == "bid_too_low", "the next bid must beat the high bid by the increment (5% -> 105)")
sentCommands = {}
local b2 = cmd(cat, "auction.bid", { auctionId = id, amount = 120 })
check(b2.ok == true and bal("cat").reserved == 120 and bal("cat").available == 380, "the new high bidder reserves the full amount")
check(bal("bob").reserved == 0 and bal("bob").available == 500, "the outbid player is released in the same tick")
check(notices(bob, "auction_outbid") == 1, "the outbid player is told")
local b3 = cmd(cat, "auction.bid", { auctionId = id, amount = 150 })
check(b3.ok == true and bal("cat").reserved == 150 and bal("cat").available == 350, "raising your own bid only reserves the difference")
check(L.conservation("survivor") == 0, "reserves keep the currency conserved")
check(cmd(ann, "auction.cancel", { auctionId = id }).error == "has_bids", "a seller cannot cancel once someone has bid")
local mine = cmd(cat, "auction.mine", {})
check(#mine.bidding == 1 and mine.bidding[1].leading == true and #mine.selling == 0, "auction.mine lists the auctions I am bidding on")
check(#cmd(bob, "auction.mine", {}).bidding == 1 and cmd(bob, "auction.mine", {}).bidding[1].leading == false, "an outbid player still sees the auction under bidding, not leading")
-- radio: an auction ending within the interval is announced
SandboxVars.MinidoracatEconomy.RadioIntervalMinutes = 10
nowMs = nowMs + 24 * 3600000 - 5 * 60000     -- 5 minutes before expiry
check(string.find(Rd.compose(), "IGUI_MinidoracatEconomy_Radio_Auctions", 1, true) ~= nil, "the radio summary mentions an auction ending within the next interval")
SandboxVars.MinidoracatEconomy.RadioIntervalMinutes = nil
-- settlement: expiry sweep pays the seller minus tax from the winner's reserve, item to the winner
sentCommands = {}
nowMs = nowMs + 6 * 60000
fire("OnTickEvenPaused")
check(not Au.hasAuction(id), "the auction is gone after settlement")
check(bal("cat").reserved == 0 and bal("cat").available == 350 and bal("ann").available == 498 + 150 - 8, "the winner's reserve pays the seller 150 minus 8 tax")
check(cat.inventory.count("Base.Axe") == 1 and cat.inventory.items[#cat.inventory.items].condition == 6, "the winner standing at the terminal receives the rebuilt item at once")
check(notices(ann, "auction_sold") == 1 and notices(cat, "auction_won") == 1, "seller and winner are told")
check(L.conservation("survivor") == 0, "settlement keeps the currency conserved")
check(M.used("ann") == 0, "the seller's slot is free again")
-- unsold: back to the seller through the mailbox
local saw = instanceItem("Base.Saw"); ann.inventory:AddItem(saw)
local c2 = cmd(ann, "auction.create", { itemId = saw.id, startPrice = 50, hours = 6 })
sentCommands = {}
nowMs = nowMs + 6 * 3600000 + 60000
fire("OnTickEvenPaused")
check(not Au.hasAuction(c2.auctionId) and M.unclaimed("ann") == 1 and notices(ann, "auction_unsold") == 1, "an unsold auction returns to the seller's mailbox")
cmd(ann, "mail.list")
local entries = lastSent("mail.list").args.entries
check(#entries == 1 and entries[1].kind == "return" and entries[1].item == "Base.Saw", "the return entry is claimable")
cmd(ann, "mail.claim", { mailId = entries[1].id })
check(ann.inventory.count("Base.Saw") == 1, "claiming brings the saw back")
-- seller cancel without bids; admin cancel with a bid releases the reserve
local h1 = instanceItem("Base.Hammer"); ann.inventory:AddItem(h1)
local c3 = cmd(ann, "auction.create", { itemId = h1.id, startPrice = 20, hours = 6 })
local cx = cmd(ann, "auction.cancel", { auctionId = c3.auctionId })
check(cx.ok == true and cx.delivered == true and ann.inventory.count("Base.Hammer") == 1 and not Au.hasAuction(c3.auctionId), "a seller cancels an unbid auction and gets the item back at once")
local h2 = instanceItem("Base.Hammer"); ann.inventory:AddItem(h2)
local c4 = cmd(ann, "auction.create", { itemId = h2.id, startPrice = 20, hours = 6 })
cmd(bob, "auction.bid", { auctionId = c4.auctionId, amount = 30 })
check(bal("bob").reserved == 30, "setup: bob holds a reserve")
check(cmd(bob, "admin.auctions", { action = "cancel", auctionId = c4.auctionId, reason = "x" }).error == "forbidden", "a player cannot admin-cancel")
sentCommands = {}
local ac = cmd(boss, "admin.auctions", { action = "cancel", auctionId = c4.auctionId, reason = "dup" })
check(ac.ok == true and ac.total == 0 and bal("bob").reserved == 0 and bal("bob").available == 500 and M.unclaimed("ann") == 1 and notices(ann, "auction_cancelled") == 1 and notices(bob, "auction_refund") == 1,
    "an admin cancel releases the bid and returns the items to the seller's mailbox")
check(X.auditEntries(1)[1].action == "auction" and X.auditEntries(1)[1].target == "ann", "the admin cancel is audited")
-- market history lines
for _ = 1, 4 do fire("OnTickEvenPaused") end
local kinds = {}
for _, line in ipairs((files["MinidoracatEconomy/market/ann/" .. EC.monthKey(nowMs) .. ".json"] or { lines = {} }).lines) do
    local rec = EC.jsonDecode(line)
    if type(rec) == "table" and string.find(rec.kind, "auction", 1, true) then kinds[#kinds + 1] = rec.kind end
end
check(table.concat(kinds, ",") == "auction_created,auction_sold,auction_created,auction_unsold,auction_created,auction_cancelled,auction_created,auction_cancelled", "the seller's market file journals the auction lifecycle: " .. table.concat(kinds, ","))
-- rollback: an auction created after the save point is rebuilt from the player save (row 4)
fire("OnTickEvenPaused")
local saved = deepCopyTable(modDataStore[EC.MODDATA_KEY])
local n1 = instanceItem("Base.Nails"); ann.inventory:AddItem(n1)
local c5 = cmd(ann, "auction.create", { itemId = n1.id, startPrice = 10, hours = 12 })
local playerInv, playerMd = deepCopyTable(ann.inventory.items), deepCopyTable(ann.modData)
modDataStore[EC.MODDATA_KEY] = saved
fire("OnServerStarted")
check(not S.Auction.hasAuction(c5.auctionId), "setup: the world rolled back below the auction")
ann.inventory.items = playerInv; ann.modData = playerMd
cmd(ann, "hello")
check(S.Auction.hasAuction(c5.auctionId) and ann.inventory.count("Base.Nails") == 0, "a pending auction is rebuilt from the player save after a rollback")
-- downtime policy: 6 h of downtime extends every active auction; 25 h cancels them
local before = modDataStore[EC.MODDATA_KEY].auctions.items[c5.auctionId].expiresAt
local action, downtime = S.Auction.applyDowntime(nowMs + 6 * 3600000, nowMs)
check(action == "extended" and modDataStore[EC.MODDATA_KEY].auctions.items[c5.auctionId].expiresAt == before + 6 * 3600000, "a 6 h downtime extends the auction by 6 h")
check(S.Auction.applyDowntime(nowMs + 3 * 60000, nowMs) == "ignored", "a 3 min downtime changes nothing")
local action2 = S.Auction.applyDowntime(nowMs + 25 * 3600000, nowMs)
check(action2 == "cancelled" and not S.Auction.hasAuction(c5.auctionId) and M.unclaimed("ann") >= 1, "a 25 h downtime cancels every auction and returns the items")
onlinePlayers = {}
end)()

-- ===== 情境三十三：系統收購（mint） =====
io.write("scenario 33: system buyback\n")
;(function()
local M, Shop, Codec = S.Mailbox, S.Shop, S.Codec
local KEY = EC.PLAYER_MODDATA_KEY
local function deepCopyTable(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = deepCopyTable(v) end
    return out
end
modDataStore[EC.MODDATA_KEY] = nil
files = {}
sentCommands = {}
nowMs = nowMs + 61000
fire("OnServerStarted")
local boss = fakePlayer("boss"); boss.role = "admin"
local zed = fakePlayer("zed"); zed.x, zed.y = 101, 200; zed.inventory = fakeInventory(50)
onlinePlayers = { boss, zed }
local function cmd(who, name, args)
    nowMs = nowMs + 600
    args = args or {}
    args.requestId = args.requestId or (name .. nowMs)
    fire("OnClientCommand", EC.COMMAND_MODULE, name, who, args)
    local sent = lastSent(name)
    return sent and sent.args or {}
end
local function bal() return L.getBalance("zed", "survivor").available end
worldSprites = { ["100,200,0"] = "MinidoracatEconomy_terminal_0" }
cmd(boss, "terminal.register", { x = 100, y = 200, z = 0, kind = "atm" })
-- catalog: the default file has no buyback; the panel turns it on for two SKUs
local list = cmd(zed, "shop.list")
check(list.buyback.enabled == false and list.items[1].buyback == false and list.items[1].bidPrice == 0, "the default catalog buys nothing and the faucet is closed")
check(cmd(boss, "admin.catalog", { action = "set", id = "axe", bidPrice = 150 }).error == "invalid_args", "bidPrice must stay below the price")
check(cmd(boss, "admin.catalog", { action = "set", id = "axe", buyback = true }).error == "invalid_args", "buyback needs a bidPrice first")
local set = cmd(boss, "admin.catalog", { action = "set", id = "axe", bidPrice = 60, buyback = true, buybackCap = 2 })
local fileText = table.concat(files["MinidoracatEconomy/catalog.json"].lines, "\n")
check(set.ok == true and Shop.sku("axe").bidPrice == 60 and Shop.sku("axe").buyback == true and Shop.sku("axe").buybackCap == 2
    and string.find(fileText, '"bidPrice":60', 1, true) ~= nil and string.find(fileText, '"buyback":true', 1, true) ~= nil, "buyback fields are written into catalog.json")
check(cmd(boss, "admin.catalog", { action = "set", id = "nails", bidPrice = 10, buyback = true }).ok == true, "setup: nails (qty 20) are bought at 10 per 20")
local rev = Shop.revision()
local axe = instanceItem("Base.Axe"); zed.inventory:AddItem(axe)
check(cmd(zed, "shop.sell", { id = "axe", itemIds = { axe.id }, revision = rev }).error == "buyback_disabled", "the faucet is closed until the sandbox switch is on")
SandboxVars.MinidoracatEconomy.ShopBuybackEnabled = true
SandboxVars.MinidoracatEconomy.ShopBuybackPerAccountDaily = 200
SandboxVars.MinidoracatEconomy.ShopBuybackServerDaily = 250
check(cmd(zed, "shop.list").buyback.enabled == true and cmd(zed, "shop.list").buyback.accountRemaining == 200, "shop.list shows the open faucet and the remaining room")
check(cmd(zed, "shop.sell", { id = "bandage", itemIds = { axe.id }, revision = rev }).error == "unknown_sku", "a SKU without buyback cannot be sold")
check(cmd(zed, "shop.sell", { id = "axe", itemIds = { axe.id }, revision = "0:stale" }).error == "catalog_changed", "a stale revision is refused")
zed.x = 150
check(cmd(zed, "shop.sell", { id = "axe", itemIds = { axe.id }, revision = rev }).error == "not_at_terminal" and bal() == 0, "selling away from a terminal is refused with zero mint")
zed.x = 101
axe.condition = 6
check(cmd(zed, "shop.sell", { id = "axe", itemIds = { axe.id }, revision = rev }).error == "not_canonical" and zed.inventory.count("Base.Axe") == 1, "a worn axe is not canonical: refused, nothing destroyed")
axe.condition = 10
local saw = instanceItem("Base.Saw"); zed.inventory:AddItem(saw)
check(cmd(zed, "shop.sell", { id = "axe", itemIds = { saw.id }, revision = rev }).error == "not_canonical", "an item of another type is refused")
axe.equipped = true
check(cmd(zed, "shop.sell", { id = "axe", itemIds = { axe.id }, revision = rev }).error == "equipped", "an equipped item is refused")
axe.equipped = false
sentItemPackets = {}
local sale = cmd(zed, "shop.sell", { id = "axe", itemIds = { axe.id }, revision = rev, requestId = "s1" })
check(sale.ok == true and sale.total == 60 and sale.balance == 60 and bal() == 60 and zed.inventory.count("Base.Axe") == 0
    and sentItemPackets[#sentItemPackets].remove == axe, "a canonical axe is destroyed and 60 coins are minted in the same tick")
check(sale.buyback.accountRemaining == 140 and sale.buyback.skuRemaining == 1, "the reply carries the remaining room")
check(zed.modData[KEY].pendingOuts[next(zed.modData[KEY].pendingOuts)].kind == "buyback", "the pending record is a buyback")
local dup = cmd(zed, "shop.sell", { id = "axe", itemIds = { axe.id }, revision = rev, requestId = "s1" })
check(dup.duplicate == true and dup.txId == sale.txId and bal() == 60, "resending the same requestId returns the first result without a second mint")
local rc = L.receipts("zed")
check(rc[#rc].kind == "shop_sell" and rc[#rc].amount == 60 and rc[#rc].counterparty == "SYSTEM_MINT" and rc[#rc].item == "Base.Axe", "the receipt shows the mint")
check(L.conservation("survivor") == 0, "the mint is conserved through SYSTEM_MINT")
-- caps: per SKU units, per account coins, server coins; a partial sale is never made
local a2, a3 = instanceItem("Base.Axe"), instanceItem("Base.Axe")
zed.inventory:AddItem(a2); zed.inventory:AddItem(a3)
check(cmd(zed, "shop.sell", { id = "axe", itemIds = { a2.id, a3.id }, revision = rev }).error == "buyback_cap_sku" and zed.inventory.count("Base.Axe") == 2,
    "two more axes exceed the SKU's daily cap of 2: refused whole")
check(cmd(zed, "shop.sell", { id = "axe", itemIds = { a2.id }, revision = rev }).ok == true and bal() == 120, "one more fits the SKU cap")
local nails = {}
for i = 1, 40 do nails[i] = instanceItem("Base.Nails"); zed.inventory:AddItem(nails[i]) end
local nailIds = {}
for i = 1, 40 do nailIds[i] = nails[i].id end
check(cmd(zed, "shop.sell", { id = "nails", itemIds = { nails[1].id, nails[2].id }, revision = rev }).error == "invalid_args", "a partial SKU unit (2 of 20 nails) is refused")
check(cmd(zed, "shop.sell", { id = "nails", itemIds = nailIds, revision = rev }).ok == true and bal() == 140 and zed.inventory.count("Base.Nails") == 0, "two units of nails (40) pay 20")
for i = 1, 40 do nails[i] = instanceItem("Base.Nails"); zed.inventory:AddItem(nails[i]); nailIds[i] = nails[i].id end
SandboxVars.MinidoracatEconomy.ShopBuybackPerAccountDaily = 150
check(cmd(zed, "shop.sell", { id = "nails", itemIds = nailIds, revision = rev }).error == "buyback_cap_account" and bal() == 140, "the per-account daily cap refuses the whole sale")
SandboxVars.MinidoracatEconomy.ShopBuybackPerAccountDaily = 200
SandboxVars.MinidoracatEconomy.ShopBuybackServerDaily = 150
check(cmd(zed, "shop.sell", { id = "nails", itemIds = nailIds, revision = rev }).error == "buyback_cap_server", "the server-wide daily cap refuses the whole sale")
SandboxVars.MinidoracatEconomy.ShopBuybackServerDaily = 250
check(Shop.buybackStatus(nowMs).mintedToday == 140, "buybackStatus reports today's gross mint")
-- the kill switch closes at once
SandboxVars.MinidoracatEconomy.ShopBuybackEnabled = false
check(cmd(zed, "shop.sell", { id = "nails", itemIds = nailIds, revision = rev }).error == "buyback_disabled", "closing the switch stops sales immediately")
SandboxVars.MinidoracatEconomy.ShopBuybackEnabled = true
-- dashboard rollups: mint / buyback / burn by day
L.credit("zed", "survivor", 100, "SYSTEM_MINT", { requestId = "au-seed-zed33", reasonCode = "t" })
cmd(zed, "shop.buy", { id = "bandage", count = 1, revision = rev })
local sys = cmd(boss, "admin.system")
check(sys.issued.today.buyback == 140 and sys.issued.today.mint == 240 and sys.issued.today.burn == 12 and sys.buyback.enabled == true and sys.buyback.mintedToday == 140,
    "admin.system reports today's mint, buyback share and burn: " .. tostring(sys.issued.today.mint) .. "/" .. tostring(sys.issued.today.buyback) .. "/" .. tostring(sys.issued.today.burn))
-- rollback: a sale after the save point is paid again from the player save (row 4)
fire("OnTickEvenPaused")
local saved = deepCopyTable(modDataStore[EC.MODDATA_KEY])
local before = bal()
local s2 = cmd(zed, "shop.sell", { id = "nails", itemIds = nailIds, revision = rev })
check(s2.ok == true and bal() == before + 20, "setup: a sale after the save point")
local playerInv, playerMd = deepCopyTable(zed.inventory.items), deepCopyTable(zed.modData)
modDataStore[EC.MODDATA_KEY] = saved
fire("OnServerStarted")
check(bal() == before, "setup: the world rolled back below the sale")
zed.inventory.items = playerInv; zed.modData = playerMd
cmd(zed, "hello")
check(bal() == before + 20 and zed.inventory.count("Base.Nails") == 0, "after a rollback the sale is paid again from the pending record")
check(L.conservation("survivor") == 0, "the repaid mint is conserved")
check(Shop.buybackRoom("zed", "nails", nowMs).account == 200 - 140 - 20 and Shop.buybackStatus(nowMs).mintedToday == 160, "the repaid mint counts against today's caps (the day buckets rolled back too)")
-- rollback with the balance cap in the way: the items come back through the mailbox instead
fire("OnTickEvenPaused")
saved = deepCopyTable(modDataStore[EC.MODDATA_KEY])
local a4 = instanceItem("Base.Axe"); zed.inventory:AddItem(a4)
nowMs = nowMs + 86400000        -- next reward day: fresh caps
local s3 = cmd(zed, "shop.sell", { id = "axe", itemIds = { a4.id }, revision = rev })
check(s3.ok == true, "setup: an axe sold on the next day")
playerInv, playerMd = deepCopyTable(zed.inventory.items), deepCopyTable(zed.modData)
modDataStore[EC.MODDATA_KEY] = saved
fire("OnServerStarted")
zed.inventory.items = playerInv; zed.modData = playerMd
SandboxVars.MinidoracatEconomy.BalanceMax = 1000
L.credit("zed", "survivor", 1000 - bal(), "SYSTEM_MINT", { requestId = "fill-zed33", reasonCode = "t" })
cmd(zed, "hello")
check(bal() == 1000 and M.unclaimed("zed") == 1, "when the repayment would break the balance cap the axe is returned through the mailbox")
SandboxVars.MinidoracatEconomy.BalanceMax = nil
cmd(zed, "mail.list")
local entries = lastSent("mail.list").args.entries
check(#entries == 1 and entries[1].item == "Base.Axe" and entries[1].kind == "return", "the return entry is the axe")
SandboxVars.MinidoracatEconomy.ShopBuybackEnabled = nil
SandboxVars.MinidoracatEconomy.ShopBuybackPerAccountDaily = nil
SandboxVars.MinidoracatEconomy.ShopBuybackServerDaily = nil
onlinePlayers = {}
end)()


-- ===== 情境三十四：Discord 存入（inbox → EXTERNAL_DISCORD_cat → 玩家） =====
io.write("scenario 34: discord deposits\n")
;(function()
local Ex, Cfg = S.Exchange, S.Config
local INBOX = "MinidoracatEconomy/inbox/"
local function deepCopyTable(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = deepCopyTable(v) end
    return out
end
local function order(fields)
    files[INBOX .. fields.orderId .. ".json"] = { lines = { EC.jsonEncode(fields) } }
end
-- one poll, then a second tick so the export queue (flushed before the poll in registration order) lands
local function tick() nowMs = nowMs + Ex.POLL_MS + 1; fire("OnTickEvenPaused"); fire("OnTickEvenPaused") end
local function bal(u) return L.getBalance(u, "cat").available end
local function events(kind)
    local out = {}
    for _, f in pairs(files) do
        for _, line in ipairs(f.lines or {}) do
            if string.find(line, '"type":"' .. kind .. '"', 1, true) then out[#out + 1] = EC.jsonDecode(line) end
        end
    end
    return out
end
modDataStore[EC.MODDATA_KEY] = nil
files = {}
sentCommands = {}
SandboxVars.MinidoracatEconomy.CatRatePointsPerCoin = 2
SandboxVars.MinidoracatEconomy.CatPerOrderMin = 10
SandboxVars.MinidoracatEconomy.CatPerOrderMax = 5000
SandboxVars.MinidoracatEconomy.CatPerAccountDaily = 300
SandboxVars.MinidoracatEconomy.CatServerDaily = 350
nowMs = nowMs + 61000
fire("OnServerStarted")
local boss = fakePlayer("boss"); boss.role = "admin"
local zed = fakePlayer("zed")
onlinePlayers = { boss, zed }
fire("OnTickEvenPaused")
local cfgEv = events("exchange.config")
check(#cfgEv == 1 and cfgEv[1].currencies[2].id == "cat" and cfgEv[1].currencies[2].exchange.pointsPerCoin == 2 and cfgEv[1].currencies[2].exchange.rateVersion == 1
    and cfgEv[1].currencies[1].exchange == nil, "start emits the exchange.config projection (cat exchangeable at 2 points per coin, survivor not)")
check(Ex.stats().tombstones == 0 and Ex.stats().inboxFiles == 0, "an empty inbox: nothing seen, no tombstones")
-- deposit
sentCommands = {}
order({ orderId = "o1", username = "zed", currency = "cat", points = 200, amount = 100, rateSnapshot = 2, rateVersion = 1 })
tick()
check(bal("zed") == 100 and L.getBalance("EXTERNAL_DISCORD_cat", "cat").available == -100, "a valid order credits the player from EXTERNAL_DISCORD_cat")
check(Ex.order("o1").status == "deposited" and Ex.order("o1").txId ~= nil, "the order is tombstoned as deposited")
check(#events("exchange.deposited") == 1 and events("exchange.deposited")[1].orderId == "o1" and events("exchange.deposited")[1].creditSeq ~= nil, "exchange.deposited is emitted")
check(lastSent("exchange.notice") ~= nil and lastSent("exchange.notice").player == zed and lastSent("exchange.notice").args.amount == 100, "the online player is told")
check(lastSent("wallet.changed") ~= nil and lastSent("wallet.changed").args.balances.cat.available == 100, "and the wallet is pushed")
local rc = L.receipts("zed")
check(rc[#rc].kind == "exchange_deposit" and rc[#rc].amount == 100 and rc[#rc].counterparty == "EXTERNAL_DISCORD_cat", "the receipt names the external account")
tick()
check(bal("zed") == 100 and Ex.stats().inboxFiles == 1, "the file still on disk is not credited twice")
-- refusals: each one is final for its orderId, nothing moves
order({ orderId = "o2", username = "zed", currency = "cat", points = 200, amount = 100, rateSnapshot = 3, rateVersion = 1 })
order({ orderId = "o3", username = "zed", currency = "cat", points = 200, amount = 150, rateSnapshot = 2, rateVersion = 1 })
order({ orderId = "o4", username = "zed", currency = "cat", points = 10, amount = 5, rateSnapshot = 2, rateVersion = 1 })
order({ orderId = "o5", username = "", currency = "cat", points = 20, amount = 10, rateSnapshot = 2, rateVersion = 1 })
order({ orderId = "o6", username = "zed", currency = "survivor", points = 20, amount = 10, rateSnapshot = 2, rateVersion = 1 })
order({ orderId = "o7", username = "zed", currency = "cat", points = 500, amount = 250, rateSnapshot = 2, rateVersion = 1 })
order({ orderId = "o8", username = "SYSTEM_MINT", currency = "cat", points = 20, amount = 10, rateSnapshot = 2, rateVersion = 1 })
tick()
local reasons = {}
for _, e in ipairs(events("exchange.failed")) do reasons[e.orderId] = e.reason end
check(reasons.o2 == "rate_mismatch" and reasons.o3 == "amount_mismatch" and reasons.o4 == "order_range" and reasons.o5 == "invalid_order"
    and reasons.o6 == "not_exchangeable" and reasons.o7 == "daily_cap" and reasons.o8 == "invalid_order",
    "each bad order fails with its reason: " .. EC.jsonEncode(reasons))
check(bal("zed") == 100 and Ex.order("o7").status == "failed", "refused orders move nothing and are tombstoned as failed")
-- the server-wide daily cap
order({ orderId = "oa", username = "bob", currency = "cat", points = 500, amount = 250, rateSnapshot = 2, rateVersion = 1 })
order({ orderId = "ob", username = "cid", currency = "cat", points = 20, amount = 10, rateSnapshot = 2, rateVersion = 1 })
tick()
for _, e in ipairs(events("exchange.failed")) do reasons[e.orderId] = e.reason end
check(bal("bob") == 250 and reasons.ob == "daily_cap" and bal("cid") == 0, "the server-wide cap refuses the order that would cross it (files are polled in name order: oa then ob)")
check(Ex.stats().depositedToday.cat == 350, "stats report today's gross deposits per currency")
check(L.conservation("cat") == 0, "deposits are conserved against the external account")
-- a rate change: the superseded version stays accepted for orders already pinned to it
files = { [INBOX .. "keep.json"] = files[INBOX .. "keep.json"] }
for k in pairs(files) do if k ~= INBOX .. "keep.json" then files[k] = nil end end
files[INBOX .. "keep.json"] = nil
nowMs = nowMs + 86400000     -- next day: caps reset
check(Cfg.setExchange("cat", { pointsPerCoin = 4 }, "boss", "r") == true and Cfg.currency("cat").exchange.rateVersion == 2, "setup: rate 2 -> 4, version 2")
fire("OnTickEvenPaused")
cfgEv = events("exchange.config")
check(#cfgEv == 1 and cfgEv[1].currencies[2].exchange.rateVersion == 2 and cfgEv[1].currencies[2].exchange.ring == nil, "the change re-emits the projection without the version ring")
order({ orderId = "p1", username = "zed", currency = "cat", points = 200, amount = 100, rateSnapshot = 2, rateVersion = 1 })
order({ orderId = "p2", username = "zed", currency = "cat", points = 200, amount = 50, rateSnapshot = 4, rateVersion = 2 })
order({ orderId = "p3", username = "zed", currency = "cat", points = 200, amount = 100, rateSnapshot = 3, rateVersion = 1 })
order({ orderId = "p4", username = "zed", currency = "cat", points = 200, amount = 40, rateSnapshot = 5, rateVersion = 3 })
tick()
reasons = {}
for _, e in ipairs(events("exchange.failed")) do reasons[e.orderId] = e.reason end
check(bal("zed") == 250 and Ex.order("p1").status == "deposited" and Ex.order("p2").status == "deposited" and reasons.p3 == "rate_mismatch" and reasons.p4 == "rate_mismatch",
    "old-version orders at the old rate and current-version orders pass; a wrong snapshot or an unknown version fail")
-- disabled currency
check(Cfg.setEnabled("cat", false, "boss", "r") == true, "setup: cat disabled")
order({ orderId = "p5", username = "zed", currency = "cat", points = 40, amount = 10, rateSnapshot = 4, rateVersion = 2 })
tick()
for _, e in ipairs(events("exchange.failed")) do reasons[e.orderId] = e.reason end
check(reasons.p5 == "currency_disabled" and bal("zed") == 250, "a disabled currency refuses deposits")
Cfg.setEnabled("cat", true, "boss", "r")
-- pruning: tombstones whose file is gone are dropped
local before = Ex.stats().tombstones
files[INBOX .. "p1.json"] = nil
files[INBOX .. "p3.json"] = nil
nowMs = nowMs + Ex.PRUNE_EVERY_MS
tick()
check(Ex.stats().tombstones == before - 2 and Ex.order("p1") == nil and Ex.order("p2") ~= nil, "tombstones without a file are pruned on the minute scan")
-- a failed directory listing is not an empty inbox: nothing is pruned, nothing replayed
do
    local real = listFilesInZomboidLuaDirectory
    listFilesInZomboidLuaDirectory = function() error("disk") end
    local n = Ex.stats().tombstones
    nowMs = nowMs + Ex.PRUNE_EVERY_MS
    tick()
    check(Ex.stats().tombstones == n and Ex.order("p2") ~= nil, "a listing failure skips the poll and keeps every tombstone")
    listFilesInZomboidLuaDirectory = real
end
-- crash before the save: ModData rolls back, the inbox file is still there, replay credits exactly once
fire("OnTickEvenPaused")
local saved = deepCopyTable(modDataStore[EC.MODDATA_KEY])
local pre = bal("zed")
order({ orderId = "q1", username = "zed", currency = "cat", points = 80, amount = 20, rateSnapshot = 4, rateVersion = 2 })
tick()
check(bal("zed") == pre + 20, "setup: deposited after the save point")
modDataStore[EC.MODDATA_KEY] = saved
fire("OnServerStarted")
check(bal("zed") == pre and Ex.order("q1") == nil, "setup: the world rolled back below the deposit")
onlinePlayers = { boss, zed }
tick()
check(bal("zed") == pre + 20 and Ex.order("q1").status == "deposited", "the inbox replay credits the rolled-back deposit exactly once")
tick()
check(bal("zed") == pre + 20, "and not again")
-- tombstone cap: fail closed, the file waits
local cap = Ex.TOMBSTONE_MAX
Ex.TOMBSTONE_MAX = Ex.stats().tombstones
order({ orderId = "q2", username = "zed", currency = "cat", points = 80, amount = 20, rateSnapshot = 4, rateVersion = 2 })
tick()
check(bal("zed") == pre + 20 and Ex.order("q2") == nil, "at the tombstone cap a new order is deferred without a tombstone")
Ex.TOMBSTONE_MAX = cap
tick()
check(bal("zed") == pre + 40 and Ex.order("q2").status == "deposited", "once there is room the same file is taken")
-- unreadable file: logged, left alone, no tombstone
files[INBOX .. "bad.json"] = { lines = { "{not json" } }
tick()
check(Ex.order("bad") == nil and Ex.stats().inboxFiles >= 1, "an unreadable file is neither credited nor tombstoned")
-- admin.system carries the exchange stats
sentCommands = {}
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.system", boss, { requestId = "sys34" })
local sys = lastSent("admin.system").args
check(type(sys.exchange) == "table" and sys.exchange.tombstones == Ex.stats().tombstones and sys.exchange.tombstoneMax == Ex.TOMBSTONE_MAX, "admin.system reports the exchange stats")
SandboxVars.MinidoracatEconomy.CatRatePointsPerCoin = nil
SandboxVars.MinidoracatEconomy.CatPerOrderMin = nil
SandboxVars.MinidoracatEconomy.CatPerOrderMax = nil
SandboxVars.MinidoracatEconomy.CatPerAccountDaily = nil
SandboxVars.MinidoracatEconomy.CatServerDaily = nil
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
