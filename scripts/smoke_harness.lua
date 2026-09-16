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

local MEDIA = os.getenv("EC_LUA_ROOT") or "MOD/MinidoracatEconomyFor42/Contents/mods/MinidoracatEconomyFor42/42/media/lua"

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

-- AdminSelfAdjustRoles 預設空字串＝沒有人可以自己調自己的帳（sandbox 檔與程式碼預設同值，
-- 檔案端若解析不到這個鍵，EC.sandboxDefault 會落回同樣的空字串，仍然是「不授權」）
SandboxVars = { MinidoracatEconomy = { RemoteReadOnly = true, AdminRoles = "admin;gm",
    ReadOnlyRoles = "moderator", AdminSelfAdjustRoles = "" } }

function sendServerCommand(player, module, command, args)
    sentCommands[#sentCommands + 1] = { player = player, module = module, command = command, args = args }
end

-- java 風格清單（size()/get(i)，0-based）——PZ 回傳的容器幾乎都是這個形狀
local function javaList(items)
    return { size = function() return #items end, get = function(_, i) return items[i + 1] end }
end
local onlinePlayers = {}
function getOnlinePlayers() return javaList(onlinePlayers) end

-- getRoles()：原生角色清單（LuaManager.java:3359-3365 -> Roles.getRoles，專用伺服器上也回得出來），
-- size()/get(i) 0-based，每個 Role 有 getName()／getPosition()（原版 ISRolesList.lua:74-79 的用法）。
-- serverRoles = nil 模擬「引擎不給清單」：受測碼必須 fail closed，不得自行假造預設角色。
-- 全域（不是 local）：主函式的 local 額度已接近 Lua 的 200 上限。
serverRoles = {
    { name = "admin", position = 32 }, { name = "moderator", position = 16 },
    { name = "gm", position = 24 }, { name = "user", position = 1 },
}
function getRoles()
    if serverRoles == nil then return nil end
    local roles = {}
    for i, r in ipairs(serverRoles) do
        roles[i] = { getName = function() return r.name end, getPosition = function() return r.position end }
    end
    return javaList(roles)
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
function getFileReader(path, createIfNull)
    local f = files[path]
    if not f then return nil end
    local i = 0
    return {
        readLine = function() i = i + 1; return f.lines[i] end,
        close = function() end,
    }
end
function cacheFileExists(path) return files[path] ~= nil end
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

-- 幣別遷移（契約 5/6）：shop/market/auction 的寫入指令現在一律必須帶 currency。既有情境驗的是別的
-- 事（節流、信箱、對帳、回滾），所以由各情境的 cmd/request helper 統一補上 survivor；currency 本身
-- 的每一條拒絕分支在情境五十二之後明確測。全域：主函式已逼近 200 個 local。
CURRENCY_COMMANDS = { ["shop.buy"] = true, ["shop.sell"] = true, ["shop.candidates"] = true,
    ["market.list"] = true, ["market.buy"] = true, ["market.browse"] = true,
    ["auction.create"] = true, ["auction.bid"] = true }
function withCurrency(name, args)
    if CURRENCY_COMMANDS[name] and type(args) == "table" and args.currency == nil then args.currency = "survivor" end
    return args
end

-- 簽到 wire（契約：day / rewardIndex / requestId 三欄必填，server 只接受「當日 + 下一序號」）。
-- 既有情境驗的是別的事，這裡依 server 當下狀態組出一個合法請求；缺欄位、舊序號重送與舊日
-- 的拒絕在情境十六與情境五十九明確測。全域：主函式已逼近 200 個 local。
function checkinArgs(username, ms, tag)
    local st = MinidoracatEconomy.Rewards.state(username, ms)
    return { day = st.day, rewardIndex = (st.claimedCount or 0) + 1, requestId = tag }
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
    -- 非 Base 模組物品：伺服器的 ScriptManager 認得就算數（目錄新增不是 Base-only）
    ["MiniFarm.CatSnack"] = { w = 0.2, cat = "Food", main = "Normal" },
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
    return { readLine = function() local line = f:read("*l"); return line and (line:gsub("\r$", "")) end,
        close = function() f:close() end }
end
worldHours = 1000                -- getGameTime():getWorldAgeHours() 的假值（全域：主函式已逼近 200 個 local）
function getGameTime() return { getWorldAgeHours = function() return worldHours end } end
-- RolesWrite 是原版角色編輯器自己的閘門（ISRolesList.lua:20/110、RolesEditPacket.java:19）
Capability = { AddItem = "AddItem", SaveWorld = "SaveWorld", RolesWrite = "RolesWrite" }
nextItemId = 1
function instanceItem(fullType)
    local k = knownItems[fullType]
    if not k then return nil end
    local id = nextItemId
    nextItemId = nextItemId + 1
    local it = { fullType = fullType, id = id, modData = {}, condition = 10, uses = 1, age = 0, repaired = 0, readPages = 0,
        equipped = false, favorite = false, broken = false, parts = {} }
    it.getFullType = function() return fullType end
    it.getID = function() return it.id end
    it.getModData = function() return it.modData end
    it.getUnequippedWeight = function() return k.w end
    it.getActualWeight = function() return k.w end
    it.getCategory = function() return k.main end
    it.getDisplayCategory = function() return k.cat end
    it.getScriptItem = function() return ScriptManager.instance:FindItem(fullType) end
    it.isEquipped = function() return it.equipped end
    it.getAttachedSlot = function() return it.attachedSlot or -1 end
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
-- syncItemModData(player, item)：LuaManager.java:12262-12269 -> SyncItemModDataPacket.java:32-60。
-- 只把該物件的 modData 推到 client 端同一個 item，不移除也不新增容器內容；server 端的寫入本來就
-- 隨 player blob 存檔（ServerPlayerDB.java:348-364）。無效的 player／item 在這裡就丟，受測碼不得
-- 用空參數假裝同步成功。
syncedItemModData = {}           -- 全域：主函式已逼近 200 個 local
function syncItemModData(player, item)
    if type(player) ~= "table" or type(player.getUsername) ~= "function" then error("syncItemModData: no player") end
    if type(item) ~= "table" or type(item.getID) ~= "function" or type(item.getModData) ~= "function" then
        error("syncItemModData: no item")
    end
    syncedItemModData[#syncedItemModData + 1] = { username = player:getUsername(), id = item:getID() }
end
function fakeInventory(maxWeight)
    local inv = { items = {}, maxWeight = maxWeight or 20 }
    inv.weight = function() local w = 0; for _, it in ipairs(inv.items) do w = w + it:getUnequippedWeight() end; return w end
    inv.hasRoomFor = function(_, _, w) return inv.weight() + w <= inv.maxWeight end
    inv.AddItem = function(_, it)
        if not it then return nil end
        for _, old in ipairs(inv.items) do if old.id ~= nil and old.id == it.id then return old end end
        inv.items[#inv.items + 1] = it
        return it
    end
    inv.Remove = function(_, it) for i = #inv.items, 1, -1 do if inv.items[i] == it then table.remove(inv.items, i) end end end
    inv.getItems = function() return javaList(inv.items) end
    inv.contains = function(_, item)
        for _, present in ipairs(inv.items) do if present == item then return true end end
        return false
    end
    inv.getItemWithID = function(_, id) for _, it in ipairs(inv.items) do if it.id == id then return it end end; return nil end
    inv.count = function(fullType) local n = 0; for _, it in ipairs(inv.items) do if not fullType or it.fullType == fullType then n = n + 1 end end; return n end
    return inv
end
-- ===== 假世界（格子與物件）=====
-- 全域（不是 local）：主函式的 local 額度已接近 Lua 的 200 上限。
-- worldSprites 維持原語意：一格一個「終端 tile」物件；worldObjects 是該格其他 IsoObject
-- （relay 放的 IsoRadio、原版世界收音機）；worldLoaded 讓「已載入但沒有終端 tile」的格子
-- 也回得出 square——實體終端消失的反面情境需要它。三者皆空＝chunk 未載入（getGridSquare 回 nil，
-- IsoCell.java:3189）。
worldSprites = {}                -- "x,y,z" -> 終端 tile sprite 名
worldObjects = {}                -- "x,y,z" -> 其他物件陣列
worldLoaded = {}                 -- "x,y,z" -> true：已載入的格（即使沒有終端 tile）
worldSpriteDeny = {}             -- sprite 名 -> true：getSprite 回 nil（tile 未載入，建立必須失敗）
worldRemoveRefuses = {}          -- 物件 -> true：引擎什麼都沒刪、回 -1（非例外的失敗）
worldRemoveRefuseAll = false     -- 同上，但對這一格的每個物件都成立
-- 故障注入：把注入點設成錯誤字串，對應的原生呼叫就拋一次（用完即清）。原生 getter 與集合存取
-- 真的會拋（Kahlua 綁定、索引），而「拋一次、下一次正常」才測得出「同一個讀取失敗被轉成
-- false／空清單／不存在」所造成的錯誤決策。
worldFault = {}                  -- getGridSquare | getObjects | addSpecialObject | removeItem | transmit | clone
function faultCheck(name)
    local f = worldFault[name]
    if f == nil then return false end
    worldFault[name] = nil
    error(f, 0)
end
-- 多格 sprite（SpriteGrid）。原生預設的刪除會按 sprite 把整組的物件一起刪掉，而且只比 sprite，
-- 不看 IsoRadio、也不看 deviceName（IsoGridSquare.java:6339-6357 → IsoObjectUtils:115-158）。
function gridSprite(name, members, incomplete)
    local grid = { members = {}, incomplete = incomplete == true }
    for _, m in ipairs(members) do grid.members[m] = true end
    return { getName = function() return name end, getSpriteGrid = function() return grid end }
end
function spriteGridOf(o)
    local s = o and o.getSprite and o:getSprite()
    return s and s.getSpriteGrid and s:getSpriteGrid() or nil
end
function worldKey(x, y, z) return x .. "," .. y .. "," .. z end
function worldObjectList(key)
    local out = {}
    local name = worldSprites[key]
    if name then
        out[1] = { __class = "IsoObject", ecTerminal = true,
            getName = function() return nil end,
            getSprite = function() return { getName = function() return name end } end }
    end
    for _, o in ipairs(worldObjects[key] or {}) do out[#out + 1] = o end
    return out
end
function getCell()
    return { getGridSquare = function(_, x, y, z)
        faultCheck("getGridSquare")
        local key = worldKey(x, y, z)
        if not worldSprites[key] and not worldLoaded[key] and #(worldObjects[key] or {}) == 0 then return nil end
        local sq = {}
        sq.__class = "IsoGridSquare"
        sq.getX = function() return x end
        sq.getY = function() return y end
        sq.getZ = function() return z end
        sq.getObjects = function() faultCheck("getObjects") return javaList(worldObjectList(key)) end
        -- AddSpecialObject 先把物件放進 objects／specialObjects，之後才 addToWorld（也就是
        -- ZomboidRadio.RegisterDevice 的入口）與重算（IsoGridSquare.java:6189-6224）。注入點
        -- 刻意在「已經加進去之後」：那正是引擎會留下一個沒註冊、沒發送的真物件的地方。
        sq.AddSpecialObject = function(_, o)
            worldObjects[key] = worldObjects[key] or {}
            worldObjects[key][#worldObjects[key] + 1] = o
            faultCheck("addSpecialObject")
        end
        -- transmitRemoveItemFromSquare(obj[, safelyRemove])：safelyRemove 預設 true，回被刪物件
        -- 的 index，物件不在清單裡或多格展開失敗回 -1（IsoGridSquare.java:6315-6363）。
        -- safelyRemove 為 true 且 sprite 有 SpriteGrid 時，同組成員一起刪——只比 sprite。
        sq.transmitRemoveItemFromSquare = function(_, o, safelyRemove)
            if o == nil then return -1 end
            if safelyRemove == nil then safelyRemove = true end
            faultCheck("removeItem")
            if o.ecTerminal then worldSprites[key] = nil return 0 end
            local list = worldObjects[key] or {}
            local function indexOf(target)
                for i = 1, #list do if list[i] == target then return i end end
                return nil
            end
            local at = indexOf(o)
            if at == nil then return -1 end
            if worldRemoveRefuseAll or worldRemoveRefuses[o] then return -1 end
            local victims = { o }
            local grid = safelyRemove and spriteGridOf(o) or nil
            if grid then
                if grid.incomplete then return -1 end
                for _, other in ipairs(list) do
                    local s = other ~= o and other.getSprite and other:getSprite() or nil
                    local n = s and s.getName and s:getName()
                    if n and grid.members[n] then victims[#victims + 1] = other end
                end
            end
            for _, v in ipairs(victims) do
                local i = indexOf(v)
                if i then table.remove(list, i); v.removed = true end
            end
            return at - 1
        end
        sq.RecalcProperties = function() end
        sq.RecalcAllWithNeighbours = function() end
        return sq
    end }
end

-- instanceof 是原生 Java 類別判定（LuaManager 曝露）；假物件用 __class 標記自己的類別。
function instanceof(obj, class)
    if type(obj) ~= "table" then return false end
    return obj.__class == class
end
function getSprite(name)
    -- IsoSpriteManager.getSprite(String) creates a non-nil placeholder for an unknown name.
    -- Only the real tiledef supplies these properties; missing art cannot be tested with nil alone.
    local props = {}
    if not worldSpriteDeny[name] and string.find(name, "^MinidoracatEconomy_speaker_") then
        props.GroupName, props.CustomName = "Economy", "Economy Speaker"
    end
    return {
        getName = function() return name end,
        getProperties = function() return { get = function(_, key) return props[key] end } end,
    }
end

-- 所有權標記字串寫死在情境裡（不是從受測模組讀來的），偽造情境才真的偽造得到同一個字串。
EC_TRADE_RADIO_TAG = "MinidoracatEconomyTradeRadio"

-- DeviceData 假件按真 setter 語意：setUseDelta 存 f/60、setPower 夾 0..1、setChannelRaw 不受
-- min/max 限制（DeviceData.java:502-511, 576-598）。預設值刻意是「HamRadio1 clone 後又被
-- 建構子亂數化」的樣子（沒開機、亂頻率、會耗電、有電池），所以斷言最終值就證明了覆寫真的發生。
function fakeDeviceData(parent)
    local d = { parent = parent, deviceName = "WaveSignalDevice", twoWay = true, portable = false,
        tv = false, noTransmit = false,
        channel = 92700, minCh = 88000, maxCh = 108000, transmitRange = 1250, micRange = 12,
        micMuted = true, batteryPowered = true, hasBattery = true, power = 0.4, useDelta = 0.1,
        volume = 0.8, on = false, mediaType = -1, media = false }
    d.getParent = function() return d.parent end
    d.getIsTwoWay = function() return d.twoWay end
    d.setIsTwoWay = function(_, v) d.twoWay = v end
    d.getIsPortable = function() return d.portable end
    d.setIsPortable = function(_, v) d.portable = v end
    d.getIsTelevision = function() return d.tv end
    d.setIsTelevision = function(_, v) d.tv = v end
    d.isNoTransmit = function() return d.noTransmit end
    d.setNoTransmit = function(_, v) d.noTransmit = v end
    d.getChannel = function() return d.channel end
    d.setChannelRaw = function(_, v) d.channel = v end
    d.setChannel = function(_, v) if v >= d.minCh and v <= d.maxCh then d.channel = v end end
    d.getMinChannelRange = function() return d.minCh end
    d.setMinChannelRange = function(_, v) d.minCh = v end
    d.getMaxChannelRange = function() return d.maxCh end
    d.setMaxChannelRange = function(_, v) d.maxCh = v end
    d.getTransmitRange = function() return d.transmitRange end
    d.setTransmitRange = function(_, v) d.transmitRange = v end
    d.getMicRange = function() return d.micRange end
    d.setMicRange = function(_, v) d.micRange = v end
    d.getMicIsMuted = function() return d.micMuted end
    d.setMicIsMuted = function(_, v) d.micMuted = v end
    d.getIsBatteryPowered = function() return d.batteryPowered end
    d.setIsBatteryPowered = function(_, v) d.batteryPowered = v end
    d.getHasBattery = function() return d.hasBattery end
    d.setHasBattery = function(_, v) d.hasBattery = v end
    d.getPower = function() return d.power end
    d.setPower = function(_, v) d.power = math.max(0, math.min(1, v)) end
    d.getUseDelta = function() return d.useDelta end
    d.setUseDelta = function(_, v) d.useDelta = v / 60 end
    d.getDeviceVolume = function() return d.volume end
    d.setDeviceVolumeRaw = function(_, v) d.volume = v end
    d.getIsTurnedOn = function() return d.on end
    d.setTurnedOnRaw = function(_, v) d.on = v end
    d.hasMedia = function() return d.media end
    d.getMediaType = function() return d.mediaType end
    -- deviceName 是所有權標記本身（DeviceData.java:55, 435-441；隨物件存檔 :1237/:1278）。
    -- 預設值就是原版的 "WaveSignalDevice"，不是我們的名字。
    d.getDeviceName = function() return d.deviceName end
    d.setDeviceName = function(_, v) d.deviceName = v end
    return d
end

-- IsoRadio.new(cell, square, sprite)（IsoRadio.java:14-16；原版用例
-- ISMoveableSpriteProps.lua:2133）。sprite / name / modData 三樣都刻意保留可改：這三樣都是
-- client 端動得到的（modData 走 ObjectModDataPacket、name 走原版放置流程
-- ISMoveableSpriteProps.lua:2273-2281、sprite 走旋轉的 transmitUpdatedSpriteToServer），
-- 所以情境要能真的改它們，證明所有權判定不受影響。
radioSerial = 0
IsoRadio = { new = function(_cell, _square, sprite)
    radioSerial = radioSerial + 1
    local o = { __class = "IsoRadio", serial = radioSerial, modData = {}, sprite = sprite }
    o.getName = function() return o.name end
    o.setName = function(_, v) o.name = v end
    o.getObjectName = function() return "Radio" end
    o.getSprite = function() return o.sprite end
    o.setSprite = function(_, v) o.sprite = v end
    o.getModData = function() return o.modData end
    o.deviceData = fakeDeviceData(o)
    -- cloneDeviceDataFromItem 回 nil 是真失敗（IsoWaveSignal.java:98-115 找不到該 script item
    -- 的裝置資料就是這樣）：契約要的是真正的 Base.HamRadio1 裝置，不是建構子留下的亂數化資料。
    o.cloneDeviceDataFromItem = function(_, full)
        if worldFault.clone ~= nil then worldFault.clone = nil return nil end
        return fakeDeviceData(o)
    end
    o.getDeviceData = function() return o.deviceData end
    o.setDeviceData = function(_, d) o.deviceData = d; d.parent = o end
    o.transmitCompleteItemToClients = function()
        faultCheck("transmit")
    end
    return o
end }

-- 一台「別人的」世界收音機：同 sprite、可偽造 modData 標記、甚至用原版放置路徑把 IsoObject 的
-- name 寫成我們的標記字串——DeviceData 的 deviceName 不是我們的，就一律不是我們的。
function fakeWorldRadio(spriteName, forgeMode)
    local o = IsoRadio.new(nil, nil, { getName = function() return spriteName end })
    if forgeMode == "modData" or forgeMode == "both" then
        o.modData.MinidoracatEconomyTradeRadio = true
    end
    if forgeMode == "objectName" or forgeMode == "both" then
        o:setName(EC_TRADE_RADIO_TAG)
    end
    return o
end

-- 原版 moveable／device 入口的最小真 contract 假件：簽章同 42.20.4 的
-- shared/Moveables/ISMoveableSpriteProps.lua 與 shared/TimedActions/ISDevice*Action.lua，
-- 並且真的做「原版會做的破壞」（生成物品、把物件移出格子），否則防線測不出來。
movCalls = {}
ISMoveableSpriteProps = {
    canPickUpMoveable = function(_self, _chr, _sq, _obj) movCalls[#movCalls + 1] = "canPickUp"; return true end,
    pickUpMoveableInternal = function(_self, _chr, _sq, _obj, _sprInstance, _spriteName, _createItem, _rotating)
        movCalls[#movCalls + 1] = "pickUpInternal"
        if _createItem and _chr then
            local item = instanceItem("Base.RadioRed")
            _chr:getInventory():AddItem(item)
        end
        if _sq and _obj then _sq:transmitRemoveItemFromSquare(_obj) end
        return { picked = true }
    end,
    -- 外層 rotateMoveable 只拿到原 sprite 名，真正的目標物件是在格子上解析出來的
    findOnSquare = function(_self, _sq, _spriteName)
        local objects = _sq and _sq:getObjects() or nil
        if objects == nil then return nil end
        for i = 0, objects:size() - 1 do
            local o = objects:get(i)
            local s = o and o.getSprite and o:getSprite() or nil
            local n = s and s.getName and s:getName()
            if n == _spriteName then return o end
        end
        return nil
    end,
    -- 真正的旋轉執行入口：server transaction 與共享 timed action 都走這裡
    -- （TransactionProcessor.lua:16-25、ISMoveablesAction.lua:236-245 →
    -- ISMoveableSpriteProps.lua:2705-2727）。原版先用 _forceAllow 把物件撿起來（略過選單
    -- gate），再無條件 place：place 會從背包挑一件同 worldSprite 的既有物品放下並消耗它。
    -- 所以「只擋 canRotateMoveable」不是沒有副作用的拒絕——它會挪用玩家另一台普通 HAM。
    rotateMoveable = function(self, _chr, _sq, _origSpriteName)
        movCalls[#movCalls + 1] = "rotateMoveable"
        local obj = ISMoveableSpriteProps.findOnSquare(self, _sq, _origSpriteName)
        ISMoveableSpriteProps.pickUpMoveableInternal(self, _chr, _sq, obj, nil, _origSpriteName, true, true)
        local inv = _chr and _chr:getInventory() or nil
        for _, item in ipairs(inv and inv.items or {}) do
            if item.worldSprite == _origSpriteName then
                inv:Remove(item)
                local placed = IsoRadio.new(nil, _sq, { getName = function() return _origSpriteName end })
                _sq:AddSpecialObject(placed)
                return true
            end
        end
        return false
    end,
    canRotateMoveable = function(_self, _sq, _obj, _origProps) movCalls[#movCalls + 1] = "canRotate"; return true end,
    canScrapObject = function(_self, _chr) movCalls[#movCalls + 1] = "canScrap"; return { canScrap = true }, 100, "Electrical" end,
    scrapObjectInternal = function(_self, _chr, _def, _sq, _obj, _res, _chance, _perk)
        movCalls[#movCalls + 1] = "scrapInternal"
        if _sq and _obj then _sq:transmitRemoveItemFromSquare(_obj) end
        return 3
    end,
}
ISDeviceBatteryAction = { isValid = function(self)
    return self.deviceData:getIsBatteryPowered() and self.deviceData:getHasBattery() == self.isRemove
end }
ISDeviceMediaAction = { isValid = function(self)
    if self.isRemove then return self.deviceData:hasMedia() end
    return (not self.deviceData:hasMedia()) and self.deviceData:getMediaType() == self.secondaryItem:getMediaType()
end }
ISDestroyStuffAction = {
    isValid = function(self) return self.item ~= nil end,
    complete = function(self)
        self.item:getSquare():transmitRemoveItemFromSquare(self.item)
        return true
    end,
}

-- 每個假玩家一個固定的 slot 與一個生死旗標：伺服器是按 getPlayerNum() 分槽去讀自己那份生存
-- 時數的，而一具屍體的時數還會繼續往上跑，所以 isDead 必須答得出來——否則「還在活的這條命」
-- 就會被一個已經死掉的角色一路灌大。
local function fakePlayer(username)
    local p = { __class = "IsoPlayer", username = username, x = 100, y = 200, z = 0, hours = 0, dead = false,
        playerNum = 0, modData = {}, inventory = fakeInventory(20), caps = {} }
    p.getUsername = function() return username end
    p.getX = function() return p.x end
    p.getY = function() return p.y end
    p.getZ = function() return p.z end
    p.getHoursSurvived = function() return p.hours end
    p.getPlayerNum = function() return p.playerNum end
    p.isDead = function() return p.dead == true end
    p.getInventory = function() return p.inventory end
    p.getModData = function() return p.modData end
    p.transmitModData = function() p.transmitted = (p.transmitted or 0) + 1 end
    p.role = "user"
    p.getRole = function() return { getName = function() return p.role end, hasCapability = function(_, cap)
        if p.caps[cap] ~= nil then return p.caps[cap] == true end
        return p.role == "admin"
    end } end
    return p
end

-- ===== 載入受測程式碼（shared → server；client 檔不在 server 端載入）=====
-- Native contracts above are already loaded; do not pretend their failed MOD lookup succeeded.
local loaded = {
    ["Moveables/ISMoveableSpriteProps"] = true,
    ["TimedActions/ISDeviceBatteryAction"] = true,
    ["TimedActions/ISDeviceMediaAction"] = true,
    ["TimedActions/ISDestroyStuffAction"] = true,
}
function require(name)
    if loaded[name] then return true end
    for _, dir in ipairs({ "shared", "server", "client" }) do
        local chunk = loadfile(MEDIA .. "/" .. dir .. "/" .. name .. ".lua")
        if chunk then
            loaded[name] = true
            chunk()
            return true
        end
    end
    error("require not found: " .. name)
end
require("MinidoracatEconomy/ECCore")
require("MinidoracatEconomy/ECAtmProtection")
require("MinidoracatEconomy/ECServer")
require("MinidoracatEconomy/ECLedger")
require("MinidoracatEconomy/ECExport")
require("MinidoracatEconomy/ECConfig")
require("MinidoracatEconomy/ECRewards")
require("MinidoracatEconomy/ECWallet")
require("MinidoracatEconomy/ECIcons")
require("MinidoracatEconomy/ECIntegration")
require("MinidoracatEconomy/ECTerminal")
require("MinidoracatEconomy/ECRecovery")
require("MinidoracatEconomy/ECRecoveryJournal")
require("MinidoracatEconomy/ECMailbox")
require("MinidoracatEconomy/ECShop")
require("MinidoracatEconomy/ECCodec")
require("MinidoracatEconomy/ECMarket")
require("MinidoracatEconomy/ECRadio")
require("MinidoracatEconomy/ECTradeRadioRelay")
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
local EXPECTED_ASSERTIONS = 1458   -- +17: cumulative check-in thresholds and live settings.
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

-- ============================================================================
-- SECTION A — 權威 journal 測試工具（全域；貼在 harness 第 408 行 lastSent 之後）
-- ============================================================================

-- 契約路徑：X.ROOT/recovery/<safeName>/<YYYYMM>.json，內文 NDJSON，每次 R.finishOut 一行。
-- producer 走 X.enqueue（非同步），所以「落盤」必須經過 tick；沒有 tick 就重啟等於崩潰未落盤
-- （X.init 會把整個 queue 清掉）。
--
-- 月份**只由 server 的 opId 決定**（contract「Journal schema and producer」）：
-- EC.parseId(id) 的 epoch 轉月份。同一個 op 的所有後繼永遠落在同一個檔，玩家提供的
-- at/epoch/journalAt 不再能選檔（journalAt 欄位已取消）。手工鋪行一律用 proofJournalPathForOp／
-- proofJournalAppend；proofJournalPath 只留給「刻意鋪到錯的月檔」這類反例。
function proofJournalPath(username, ms)
    return X.ROOT .. "/recovery/" .. EC.safeName(username) .. "/" .. EC.monthKey(ms or nowMs) .. ".json"
end

function proofJournalPathForOp(username, opId)
    local idEpoch = EC.parseId(opId)
    return proofJournalPath(username, tonumber(idEpoch))
end

-- 該帳號某個檔「目前真的在假檔案系統裡」的行，解碼後，順序同檔案。
-- 省略 ms 時讀「現在這個月」的檔；要讀某個 op 的固定檔請用 proofJournalChain。
function proofJournalRows(username, ms)
    local out = {}
    local f = files[proofJournalPath(username, ms)]
    for _, line in ipairs(f and f.lines or {}) do
        local row = EC.jsonDecode(line)
        if type(row) == "table" then out[#out + 1] = row end
    end
    return out
end

-- 某個 op 在它固定檔裡的完整合法鏈，順序同檔案（最後一筆就是後繼）。
function proofJournalChain(username, opId)
    local out = {}
    local f = files[proofJournalPathForOp(username, opId)]
    for _, line in ipairs(f and f.lines or {}) do
        local row = EC.jsonDecode(line)
        if type(row) == "table" and row.opId == opId then out[#out + 1] = row end
    end
    return out
end

function proofJournalSuccessor(username, opId)
    local chain = proofJournalChain(username, opId)
    return chain[#chain]
end

-- 「真操作 → 落盤 → 回滾 → 重啟」這一套的可重用半邊（ServerTests 情境 80/82/83 手寫的那段）。
-- 玩家存檔**不隨世界回滾**，所以只處理世界那一半；玩家存檔要不要一起換由呼叫者決定。
function proofSnapshot()
    local function deep(v)
        if type(v) ~= "table" then return v end
        local out = {}
        for k, value in pairs(v) do out[k] = deep(value) end
        return out
    end
    return deep(modDataStore[EC.MODDATA_KEY])
end

function proofRestartFrom(snapshot)
    local function deep(v)
        if type(v) ~= "table" then return v end
        local out = {}
        for k, value in pairs(v) do out[k] = deep(value) end
        return out
    end
    modDataStore[EC.MODDATA_KEY] = deep(snapshot)
    nowMs = nowMs + 1000
    fire("OnServerStarted")
end

function proofJournalRowOf(username, opId, ms)
    for _, row in ipairs(proofJournalRows(username, ms)) do
        if row.opId == opId then return row end
    end
    return nil
end

-- 把 export queue 真的寫進假檔案系統。有界，不假設一個 tick 就清空；回傳剩餘行數。
function proofSettle(limit)
    for _ = 1, limit or 40 do
        if X.queuedLines() == 0 then break end
        fire("OnTickEvenPaused")
    end
    return X.queuedLines()
end

-- 非同步證據讀取的有界收斂：pump 到該帳號不再等待證據，再多跑幾個 tick 讓 onReady 排的
-- 重判真的執行完。永遠有界，永遠不會永久等待。
function proofPump(username, limit)
    for _ = 1, limit or 200 do
        fire("OnTickEvenPaused")
        local J = S.RecoveryJournal
        if type(J) == "table" and type(J.status) == "function" then
            local st = J.status(username)
            if type(st) == "table" and (st.wanted or 0) == 0 and st.reading ~= true then
                fire("OnTickEvenPaused"); fire("OnTickEvenPaused"); fire("OnTickEvenPaused")
                return
            end
        end
    end
end

-- 合法鏈的行一律走**真的 producer**（Main 指示：不得偽造完美欄位繞過 J.record）。
-- 這裡只組 receipt 這個 server 端輸入，wire 格式與檔名派生都交給 J.record 自己做，
-- 再 proofSettle() 讓它真的落盤。回傳 ok, error（沿用 J.record 的三個錯誤字面值）。
-- 刻意損壞的行（缺 opId、半行、同提交點異內容、seq 倒退）才用 proofJournalWrite／
-- proofJournalRecord 直接寫 —— 那些行的重點正是 producer 不會產生它們。
function proofJournalEmit(username, opId, epoch, seq, replay, kind, ref)
    local J = S.RecoveryJournal
    if type(J) ~= "table" or type(J.record) ~= "function" then return false, "journal_unavailable" end
    local receipt = { id = opId, owner = username, kind = kind or (replay and replay.kind) or "listing",
        ref = ref or opId, epoch = epoch, seq = seq, at = nowMs }
    local ok, err = J.record(username, opId, receipt, replay)
    if ok then proofSettle() end
    return ok, err
end

-- 手工造行：竄改／壞行／身份不符的反例用。text 原樣寫進月檔（可以是非 JSON 的半行）。
function proofJournalWrite(username, ms, text)
    local path = proofJournalPath(username, ms)
    local f = files[path]
    if not f then f = { lines = {}, opens = 0 }; files[path] = f end
    f.lines[#f.lines + 1] = text
    return path
end

-- 真 wire 的 version：**以模組常數 J.VERSION 為準**，不 hardcode。
-- Main 實跑抓到的假綠就是這個：helper 原本寫死 version=1，而 reader 是
-- `if tonumber(entry.version) ~= J.VERSION then return nil, "version" end`，
-- 所以每一行「本意合法」或「只壞某一項」的手造行都先在版本這關被判 journal_malformed
-- （detail.field == "version"），根本走不到想測的那道閘 —— 碰到哪個拒絕都算綠。
-- ServerTests 情境 80 的 foreign 行就是真例（實測 proofField == "version"，owner gate 沒被碰到）。
-- 特別注意 proofJournalPad：它在真行之前就灌 500 行，所以不能靠「從已落盤的行推回 version」，
-- 那時候還沒有任何真行可推。預設必須合法，刻意才壞。
function proofWireVersion(username, opId)
    local J = S.RecoveryJournal
    if type(J) == "table" and tonumber(J.VERSION) then return tonumber(J.VERSION) end
    local seen = nil
    local function scan(path)
        for _, line in ipairs((files[path] or { lines = {} }).lines) do
            local row = EC.jsonDecode(line)
            if type(row) == "table" and type(row.version) == "number" then seen = row.version end
        end
    end
    if opId then scan(proofJournalPathForOp(username, opId)) end
    if seen == nil then scan(proofJournalPath(username)) end
    return seen
end

-- 一行合法形狀的 journal 記錄（頂層欄位依契約固定；不再有 journalAt）。fields 可覆寫頂層欄位。
-- version 預設用真 wire 的值；只有「就是要測錯 version」的案例才在 fields 裡明確指定別的值。
function proofJournalRecord(username, opId, epoch, seq, replay, fields)
    local row = { type = "recovery.journal", version = proofWireVersion(username, opId) or 1,
        opId = opId, owner = username, kind = (replay and replay.kind) or "listing", ref = opId,
        outAt = nowMs, epoch = epoch, seq = seq, replay = replay }
    for k, v in pairs(fields or {}) do row[k] = v end
    return EC.jsonEncode(row)
end

-- 直接寫檔：只給**完全 raw 的壞行**（半行、非 JSON、缺 opId、owner 換人這種無 producer 對應物）。
function proofJournalAppend(username, opId, epoch, seq, replay, fields)
    local path = proofJournalPathForOp(username, opId)
    local f = files[path]
    if not f then f = { lines = {}, opens = 0 }; files[path] = f end
    f.lines[#f.lines + 1] = proofJournalRecord(username, opId, epoch, seq, replay, fields)
    return path
end

-- 故意損壞但**正向基底必須是真的**：先讓真 J.record 產一行（真 version、真 pack 的 snapshot），
-- 落盤後只改想壞的那個欄位。J.record 不驗完整 replay，所以仍可造出「缺 origins」這類行。
-- 絕不自行複製 pack/unpack。mutate(row) 就地改那一行的頂層／replay 欄位。
function proofJournalCorrupt(username, opId, epoch, seq, replay, mutate, kind, ref)
    local ok, err = proofJournalEmit(username, opId, epoch, seq, replay, kind, ref)
    if not ok then return nil, err end
    local path = proofJournalPathForOp(username, opId)
    local lines = files[path].lines
    for i = #lines, 1, -1 do
        local row = EC.jsonDecode(lines[i])
        if type(row) == "table" and row.opId == opId then
            mutate(row)
            lines[i] = EC.jsonEncode(row)
            return path
        end
    end
    return nil, "no_line"
end
-- 把月檔灌大到單一 tick 讀不完（bytesPerTick=65536 / HISTORY_LINES_PER_TICK=200 先到先停）。
-- 灌的行是**別的 op** 的合法行，必須在真正那筆 op 之前灌，否則 reader 提早結束就測不到預算。
-- opId 必須是真正可解析的 `<epoch ms>:<正整數 seq>` —— 依 FR-10，任何無法歸屬的行都會讓整檔
-- unreadable，所以帶假 id（例如 "pad:1"）的 padding 本身就是損壞行，會讓預算那幾格量錯東西。
-- 產品不該為了容忍 noise id 而放寬，是 fixture 要產生合法的鄰居行。
function proofJournalPad(username, ms, count)
    local filler = string.rep("p", 300)
    local epoch = tostring(math.floor(ms or nowMs))
    for i = 1, count or 500 do
        proofJournalWrite(username, ms, proofJournalRecord(username, epoch .. ":" .. i, epoch, i,
            { kind = "listing", padding = filler }))
    end
end

-- ===== 情境一：啟動、握手、meta =====
io.write("scenario 1: server start + hello handshake\n")
fire("OnServerStarted")
local md = S.modData()
check(md ~= nil and md.schemaVersion == EC.SCHEMA_VERSION, "ModData root created with schemaVersion")
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
ack = lastSent("hello.ack")
fire("OnClientCommand", EC.COMMAND_MODULE, "hello", bob, {})
check(lastSent("hello.ack") ~= ack and lastSent("hello.ack").player == bob, "another player is not throttled by alice")
nowMs = nowMs + 600
ack = lastSent("hello.ack")
fire("OnClientCommand", EC.COMMAND_MODULE, "hello", alice, {})
check(lastSent("hello.ack") ~= ack and lastSent("hello.ack").player == alice, "after cooldown the same player is served again")

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
check(e1 == epoch1 and e2 == epoch1 and s2 == s1 + 1,
    "newId yields unique ids in the current epoch with strictly increasing sequence numbers")
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
check(md3.meta.loadedSeq == 2, "after rollback the saved sequence remains the loaded watermark")
local idAfterRollback = S.newId()
check(idAfterRollback ~= id3 and select(1, EC.parseId(idAfterRollback)) == md3.meta.epoch
    and select(2, EC.parseId(idAfterRollback)) > md3.meta.loadedSeq,
    "a rollback issues a new epoch id beyond the saved watermark, never an id from the abandoned branch")

-- ===== 情境五：核心工具 =====
io.write("scenario 5: core helpers\n")
local list = { 5, 3, 9, 1, 3 }
EC.sortSafe(list, function(a, b) return a < b end)
check(table.concat(list, ",") == "1,3,3,5,9", "sortSafe sorts (stable insertion sort, no table.sort)")
local roles = EC.roleSet(" Admin; gm ;;Head Admin;")
check(roles["Admin"] and roles.gm and roles["Head Admin"] and not roles.admin and not roles.moderator,
    "roleSet splits a sandbox string on ';' only: names keep their case and their inner spaces")
roles = EC.roleSet({ "Admin", "gm" })
check(roles["Admin"] and roles.gm and not roles.admin and EC.countKeys(roles) == 2,
    "roleSet also reads the runtime array form, and 'admin' never authorises the role named 'Admin'")
check(EC.sandbox("AdminRoles", "admin") == "admin;gm" and EC.sandbox("NoSuchKey", 7) == 7 and EC.sandbox("RemoteReadOnly", "x") == "x", "sandbox returns value, default when missing, default when wrong type")
check(EC.countKeys({ a = 1, b = 2 }) == 2 and EC.CURRENCIES.survivor.marketUnit == true and EC.CURRENCIES.cat.marketUnit == true, "both registry currencies are tradable units (nothing may pick the first marketUnit as the settlement currency)")

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
fire("OnClientCommand", EC.COMMAND_MODULE, "rewards.checkin", dave, checkinArgs("dave", nowMs, "s16-early"))
local r0 = lastSent("rewards.checkin")
check(r0 and r0.args.ok == false and r0.args.error == "not_enough_playtime" and r0.args.playedMs == 0, "check-in before any playtime is refused")

-- 在線時間 = 真的連在世界裡的牆鐘時間（契約：移除位置 AFK 猜測）。上一行的 rewards.checkin 已經
-- 在 T0 建立了起點，所以接下來三個 tick 整段都算得到，不是舊的「第一個取樣不計入」。
for i = 1, 3 do nowMs = nowMs + 60000; dave.x = dave.x + 1; fire("OnTickEvenPaused") end
local st = R.state("dave", nowMs)
check(st.playedMs == 180000 and st.claimedCount == 0, "an online player accrues connected time from the moment the server first saw them, not from the tick after that")
nowMs = nowMs + 60000; fire("OnTickEvenPaused")     -- 完全沒移動
check(R.state("dave", nowMs).playedMs == st.playedMs + 60000, "standing still is still being online: presence counts, position does not")

nowMs = nowMs + 1000
fire("OnClientCommand", EC.COMMAND_MODULE, "rewards.checkin", dave, { day = R.dayKey(nowMs), rewardIndex = 1, requestId = "s16-first" })
local r1 = lastSent("rewards.checkin")
check(r1.args.ok == true and r1.args.amount == 30 and r1.args.balance == 30 and L.getBalance("SYSTEM_MINT", "survivor").available == -30, "check-in pays the sandbox amount from SYSTEM_MINT")
nowMs = nowMs + 1000
fire("OnClientCommand", EC.COMMAND_MODULE, "rewards.checkin", dave, { day = R.dayKey(nowMs), rewardIndex = 1, requestId = "s16-first" })
check(lastSent("rewards.checkin").args.error == "stale_request" and L.getBalance("dave", "survivor").available == 30, "resending the claim that was already paid is a stale request, not a second payment")
fire("OnClientCommand", EC.COMMAND_MODULE, "rewards.state", dave, {})
local stc = lastSent("rewards.state").args
check(stc.claimedCount == 1 and stc.remainingClaims == 0 and stc.dailyLimit == 1 and stc.day == "20260906" and stc.nextResetMs == 1788724800000 and #stc.milestoneList == 5, "rewards.state reports the claim counter, the day, the next reset and the milestone list")

-- 跨獎勵日：playtime 歸零、可再簽到
nowMs = 1788724800000 + 1000
fire("OnClientCommand", EC.COMMAND_MODULE, "rewards.checkin", dave, checkinArgs("dave", nowMs, "s16-newday-early"))
check(lastSent("rewards.checkin").args.error == "not_enough_playtime" and R.state("dave", nowMs).playedMs < 60000, "a new reward day counts only the part of the session that falls inside it; check-in needs playtime again")
for i = 1, 3 do nowMs = nowMs + 60000; dave.x = dave.x + 1; fire("OnTickEvenPaused") end
nowMs = nowMs + 1000
fire("OnClientCommand", EC.COMMAND_MODULE, "rewards.checkin", dave, checkinArgs("dave", nowMs, "s16-newday"))
check(lastSent("rewards.checkin").args.ok == true and L.getBalance("dave", "survivor").available == 60, "check-in works again on the new day")
-- 日鍵回訪（實機踩到：重置時刻 20→0→20 讓同一 requestId 再次出現）：
-- claim 記錄掉了但帳本冪等快取還在 → 必須回 already_claimed、不動錢、不重複計數
local rollBefore = ModData.getOrCreate(EC.MODDATA_KEY).rollups[R.dayKey(nowMs)].checkinCount
ModData.getOrCreate(EC.MODDATA_KEY).claims["dave"].claimedCount = 0
ModData.getOrCreate(EC.MODDATA_KEY).claims["dave"].checkinDay = nil
nowMs = nowMs + 1000
fire("OnClientCommand", EC.COMMAND_MODULE, "rewards.checkin", dave, checkinArgs("dave", nowMs, "s16-replay"))
local replay = lastSent("rewards.checkin").args
check(replay.ok == false and replay.error == "already_claimed" and L.getBalance("dave", "survivor").available == 60
    and ModData.getOrCreate(EC.MODDATA_KEY).rollups[R.dayKey(nowMs)].checkinCount == rollBefore
    and R.state("dave", nowMs).claimedCount == 1, "idempotent replay of a paid reward day is reported as already_claimed (no double count, claim counter restored)")

-- 全服保險絲
SandboxVars.MinidoracatEconomy.CheckinServerDailyCap = 40
local erin = fakePlayer("erin")
onlinePlayers = { dave, erin }
for i = 1, 3 do nowMs = nowMs + 60000; erin.x = erin.x + 1; dave.x = dave.x + 1; fire("OnTickEvenPaused") end
nowMs = nowMs + 1000
fire("OnClientCommand", EC.COMMAND_MODULE, "rewards.checkin", erin, checkinArgs("erin", nowMs, "s16-cap"))
check(lastSent("rewards.checkin").args.error == "cap_exceeded" and L.getBalance("erin", "survivor").available == 0, "server daily fuse refuses once the day's total would exceed the cap (claim not consumed)")
SandboxVars.MinidoracatEconomy.CheckinServerDailyCap = 0
nowMs = nowMs + 1000
fire("OnClientCommand", EC.COMMAND_MODULE, "rewards.checkin", erin, checkinArgs("erin", nowMs, "s16-cap-off"))
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

-- 換季：本季從 0 開始算。一個已經活了七天、還活著的老角色，不得因為換季就把所有門檻再領一次；
-- 要等這一季自己真的活滿一天，第一個門檻才會再發。換季走真正的換季路徑，不是手改欄位。
;(function()
local Se = S.Seasons
local before = L.getBalance("dave", "survivor").available
local first = Se.currentId()
local rot = Se.start(first, "s17-rot", "boss", "scenario 17 rotation", nowMs)
nowMs = nowMs + 60000; dave.x = dave.x + 1; fire("OnTickEvenPaused")
check(rot.ok == true and Se.currentId() ~= first
    and L.getBalance("dave", "survivor").available == before,
    "a new season starts everybody at day 0: a character who is already seven days old is paid nothing for the life it brought with it")
dave.hours = dave.hours + 25
nowMs = nowMs + 60000; dave.x = dave.x + 1; fire("OnTickEvenPaused")
check(L.getBalance("dave", "survivor").available == before + 100,
    "the first milestone is paid again once a day has actually been survived inside the new season")
end)()

-- 重啟後狀態保留
nowMs = nowMs + 1000
fire("OnServerStarted")
local st2 = R.state("dave", nowMs)
check(st2.claimedCount == 1 and st2.milestones > 0 and S.modData().claims.dave.season == S.Seasons.currentId(), "claims survive a restart")
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
fire("OnTickEvenPaused")
check(lastSent("wallet.history").args.total == 0 and #lastSent("wallet.history").args.entries == 0, "missing month file answers empty after the write fence")

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
-- 換季走真正的換季路徑（不是手改欄位）。換季本來就會為**線上**玩家合法地重錨新季進度，
-- 所以要證明「查帳只投影、不改紀錄」，被查的人就不能同時是那個合法被改的人：joe 在換季
-- 當下離線，他的紀錄仍停在舊季，查帳必須照新季報 0 而不是就地把已領的位元清掉。
onlinePlayers = { boss, mod }
S.Seasons.start(S.Seasons.currentId(), "s20-rot", "boss", "scenario 20 rotation", nowMs)
onlinePlayers = { boss, mod, joe }
;(function()
local joeSeason = root20.claims.joe.season
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.lookup", mod, { username = "joe" })
local lookJoe = lastSent("admin.lookup").args
check(joeSeason ~= S.Seasons.currentId() and root20.claims.joe.season == joeSeason
    and root20.claims.joe.milestones == 3 and root20.claims.joe.playedMs == 120000
    and lookJoe.rewards.milestones == 0 and lookJoe.rewards.season == S.Seasons.currentId() and lookJoe.rewards.playedMs == 120000,
    "a moderator lookup projects the new season without rewriting the claim record (milestone mask and playtime survive)")
end)()
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
local saved = deepCopy(modDataStore[EC.MODDATA_KEY])   -- the world save, at whatever seq it really reached
local savedSeq = saved.meta.seq
nowMs = nowMs + 1000
fire("OnServerStarted")                       -- E2 loads that save
local e2 = S.modData().meta.epoch
local lost = L.credit("zed", "survivor", 10, "SYSTEM_MINT", { requestId = "z3", reasonCode = "t" })  -- never saved
fire("OnTickEvenPaused")
local lostSeq = lost.seq
check(lost.ok == true and lostSeq == savedSeq + 1 and S.modData().meta.seq == lostSeq and e2 ~= e1,
    "E2 posted the seq right after the saved one, and that posting was never saved")
modDataStore[EC.MODDATA_KEY] = deepCopy(saved)        -- SIGKILL: the next start loads the E1 save again
nowMs = nowMs + 1000
fire("OnServerStarted")                       -- E3
local meta = S.modData().meta
check(meta.loadedSeq == savedSeq and meta.epoch ~= e2, "E3 loads the saved seq under a new epoch")
check(S.isRolledBack(e2, lostSeq) == true, "E2's unsaved row is flagged rolled back although the save never heard of E2")
check(S.isRolledBack(e1, savedSeq) == false and S.isRolledBack(e1, 1) == false, "E1's saved rows stay valid")
check(S.isRolledBack(e2, savedSeq) == false, "E2's inherited rows (seq <= loadedSeq) are not rolled back")
local ef = files["MinidoracatEconomy/epochs.json"]
check(ef and #ef.lines == 3, "epochs.json holds one line per start")
-- a saved epoch that the bounded ModData history has forgotten must not be mistaken for a crash
local h = S.modData().meta.history
local forgotten = nil
for _, x in ipairs(h) do if x.epoch == e1 then forgotten = x end end
check(forgotten ~= nil and forgotten.loadedSeq == savedSeq,
    "history keeps E1 with the seq its successor loaded, not its own loadedSeq (0)")

-- 啟動時 journal 自己交代崩潰邊界；稽核檔視圖把崩潰班次的管理操作標成回滾
local rbLine = nil
for _, f in pairs(files) do
    for _, l in ipairs(f.lines) do
        if string.find(l, '"type":"epoch.rolledback"', 1, true) then rbLine = EC.jsonDecode(l) end
    end
end
check(rbLine ~= nil and rbLine.crashedEpoch == e2 and rbLine.fromSeq == lostSeq and rbLine.epoch == meta.epoch,
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
check(rbPer[e2] == 1 and rbPer[meta.epoch] == 1 and S.isRolledBack(e2, lostSeq) == true and S.isRolledBack(meta.epoch, lostSeq) == true
    and e3Line ~= nil and e3Line.flagged ~= nil and e3Line.flagged[1] == e2 and #ef.lines == 4,
    "a restart before a save flags E3 once and does not repeat E2's line (E3's record remembers it flagged E2); both stay rolled back")
meta = S.modData().meta
-- 崩潰班次裡的一筆管理操作（稽核檔還在、稽核環已回滾）
local admin3 = fakePlayer("boss"); admin3.role = "admin"
onlinePlayers = { admin3 }
X.audit({ action = "adjust", target = "zed", currency = "survivor", delta = 7, admin = "boss", reason = "before the crash", seq = lostSeq, epoch = e2 })
fire("OnTickEvenPaused")                      -- the queued audit line reaches the file
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.auditFile", admin3, {})
for _ = 1, 5 do fire("OnTickEvenPaused") end
local af = lastSent("admin.auditFile")
check(af ~= nil and af.args.entries ~= nil and #af.args.entries >= 1 and af.args.months ~= nil, "admin.auditFile replies the audit file entries with the months it read")
local flagged, unflagged = 0, 0
for _, e in ipairs(af.args.entries) do
    if e.epoch == e2 and e.seq == lostSeq then
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
check(snap.CheckinAmount.value == 30 and snap.CheckinAmount.default == 30 and snap.CheckinAmount.override == false
    and snap.AdminRoles.manageOnly == true and snap.CheckinAmount.manageOnly == false,
    "options() reports effective value, sandbox default, override flag and the manage-only mark")
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
check(setOpt(boss, "AdminAdjustMaxPerTx", 99999).ok == true and EC.sandbox("AdminAdjustMaxPerTx", 5000) == 99999
    and setOpt(mod, "AdminRoles", { "admin" }).error == "manage_settings_required",
    "an admin-limit option is editable in-game, but only by whoever holds the native role capability")
Cfg.setOption("AdminAdjustMaxPerTx", nil, boss:getUsername())
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

-- ===== 情境二十四之二：管理限制的線上修改（原生角色能力閘門）＋自行調帳授權 =====
--
-- 守的是「誰可以改『誰是管理員』」：manageOnly 選項只認原生 Capability.RolesWrite（原版角色編輯器
-- 自己的閘門），經濟 write 角色不得放寬限制自己的那條線；角色名一律精確比對（Roles.java:302-305
-- 區分大小寫，自訂角色名可含空白甚至分號）；自行調帳要 AdminRoles ＋ AdminSelfAdjustRoles 兩張票。
-- 以反例為主：每個拒絕分支都要證明「零變更」，不是只看 error 字串。
io.write("scenario 24b: manage-only options, exact role lists, self adjustment grant\n")
;(function()
modDataStore[EC.MODDATA_KEY] = nil
files = {}
sentCommands = {}
local savedRoles = serverRoles
-- 同名不同大小寫（gm／GM）、含空白（Head Admin）、含分號（role;semi）都是這台伺服器真有的角色
local scenarioRoles = {
    { name = "Head Admin", position = 40 }, { name = "admin", position = 32 },
    { name = "gm", position = 24 }, { name = "GM", position = 23 },
    { name = "moderator", position = 16 }, { name = "role;semi", position = 8 },
}
serverRoles = scenarioRoles
SandboxVars.MinidoracatEconomy.AdminRoles = "admin;gm"
SandboxVars.MinidoracatEconomy.ReadOnlyRoles = "moderator"
SandboxVars.MinidoracatEconomy.AdminAdjustMaxPerTx = 5000
nowMs = nowMs + 61000
fire("OnServerStarted")
-- boss  ：role=="admin"，假 player 對它全能力放行 ＝ 同時握有經濟 write 與原生 RolesWrite
-- gmx   ：經濟 write 角色，但沒有任何原生能力 ← 不得改 manageOnly
-- mod   ：唯讀角色（真伺服器的 moderator 也沒有 RolesWrite，Roles.java:448-461）
-- owner ：只有原生 RolesWrite，完全不在經濟角色清單內 ← 仍須進得了面板、改得了 manageOnly
local boss = fakePlayer("boss"); boss.role = "admin"
local gmx = fakePlayer("gmx"); gmx.role = "gm"
local mod = fakePlayer("mod"); mod.role = "moderator"
local owner = fakePlayer("owner"); owner.role = "Head Admin"; owner.caps.RolesWrite = true
local semi = fakePlayer("semi"); semi.role = "role;semi"
local joe = fakePlayer("joe")
onlinePlayers = { boss, gmx, mod, owner, semi, joe }
local function setOpt(who, key, value)
    nowMs = nowMs + 600
    local args = { key = key, requestId = "m24b-" .. key .. "-" .. tostring(nowMs) }
    if value ~= nil then args.value = value end
    fire("OnClientCommand", EC.COMMAND_MODULE, "admin.option", who, args)
    return lastSent("admin.option").args
end
local function adjust(who, args)
    nowMs = nowMs + 600
    fire("OnClientCommand", EC.COMMAND_MODULE, "admin.adjust", who, args)
    return lastSent("admin.adjust").args
end
local function selfPerm(who)
    nowMs = nowMs + 600
    fire("OnClientCommand", EC.COMMAND_MODULE, "admin.lookup", who, { username = who:getUsername() })
    return lastSent("admin.lookup").args.perms
end

-- 角色清單來源與管理能力本身
local choices = EC.roleChoices()
check(choices ~= nil and #choices == 6 and choices[1].name == "Head Admin" and choices[1].position == 40
    and choices[2].name == "admin" and choices[6].name == "role;semi",
    "roleChoices lists every native role of this server, highest position first, custom names included")
serverRoles = nil
check(EC.roleChoices() == nil,
    "an unreadable native role list is nil, never an invented set of vanilla defaults")
serverRoles = scenarioRoles
check(EC.canManageSettings(owner) == true and EC.canManageSettings(gmx) == false
    and EC.canManageSettings(mod) == false and EC.canManageSettings(joe) == false
    and EC.canManageSettings(nil) == false and EC.canManageSettings({}) == false,
    "canManageSettings answers the native RolesWrite capability alone and fails closed without one")

-- manageOnly 閘門：經濟 write 不夠，原生角色能力才算
local plainWrite = setOpt(gmx, "AdminAdjustMaxPerTx", 9999)
check(plainWrite.error == "manage_settings_required" and plainWrite.perms.write == true
    and plainWrite.perms.manage ~= true and EC.sandbox("AdminAdjustMaxPerTx", 1) == 5000,
    "an economy write role cannot raise the cap that limits it: the reply says write-but-not-manage and the option is unchanged")
check(setOpt(gmx, "CheckinAmount", 44).ok == true and Cfg.options().CheckinAmount.value == 44,
    "that same role still edits ordinary options: the manage gate is per key, not a second admin level")
local modTry = setOpt(mod, "AdminRoles", { "admin" })
check(modTry.error == "manage_settings_required" and modTry.perms.write ~= true
    and Cfg.options().AdminRoles.override == false,
    "a read-only role gets no extra reach either, and nothing is stored")
check(setOpt(joe, "AdminRoles", { "admin" }).error == "forbidden",
    "someone who cannot even read the panel is answered forbidden, not the manage error")
local capped = setOpt(owner, "AdminAdjustMaxPerTx", 9999)
check(capped.ok == true and capped.perms.manage == true and capped.perms.write ~= true
    and EC.sandbox("AdminAdjustMaxPerTx", 1) == 9999,
    "the native role owner changes a manage-only cap from the panel while holding no economy role at all")

-- 把 AdminRoles 清空不能鎖死伺服器
local emptied = setOpt(owner, "AdminRoles", {})
check(emptied.ok == true and A.isAdmin(boss) == false and A.isAdmin(gmx) == false
    and Cfg.options().AdminRoles.override == true and #Cfg.options().AdminRoles.value == 0,
    "an empty role array is a real answer stored as an override: it means nobody, not 'unset'")
check(A.canRead(owner) == true and A.isAdmin(owner) == false and A.canRead(gmx) == false,
    "a list that names nobody still leaves the native role owner a read path in, and that capability is not a write role")
local restored = setOpt(owner, "AdminRoles", { "admin", "gm" })
check(restored.ok == true and A.isAdmin(boss) == true and A.isAdmin(gmx) == true,
    "and that path is enough to name the admins again")

-- 精確比對：大小寫、空白、分號
local pickedCase = setOpt(owner, "AdminRoles", { "GM", "Head Admin" })
check(pickedCase.ok == true and A.isAdmin(gmx) == false and A.isAdmin(owner) == true,
    "role names match exactly: authorising 'GM' never authorises the role named 'gm'")
local picked = setOpt(owner, "AdminRoles", { "role;semi" })
check(picked.ok == true and A.isAdmin(semi) == true and A.isAdmin(owner) == false,
    "a role whose own name contains ';' is authorised exactly, because the array form is never re-split")
nowMs = nowMs + 700
fire("OnClientCommand", EC.COMMAND_MODULE, "hello", semi, {})
local loginRoles = lastSent("hello.ack").args
check(type(loginRoles.options) == "table"
    and EC.roleSet(loginRoles.options.AdminRoles.value)["role;semi"] == true,
    "the initial hello carries runtime grants, so a reconnecting custom role need not wait for another config change")

-- 壞清單：未知名稱、重複、空洞、鍵值、非字串、根本不是陣列 → 一律零變更
local before = Cfg.options().AdminRoles.value
local bad = { { "no-such-role" }, { "admin", "admin" }, { "admin", [3] = "gm" },
    { admin = true }, { "admin", 7 }, "admin;gm" }
local codes = {}
for i, v in ipairs(bad) do codes[i] = setOpt(owner, "AdminRoles", v).error or "ok" end
check(table.concat(codes, ",") == "unknown_role,invalid_roles,invalid_roles,invalid_roles,invalid_roles,invalid_roles"
    and #Cfg.options().AdminRoles.value == #before and Cfg.options().AdminRoles.value[1] == before[1]
    and A.isAdmin(semi) == true,
    "an unknown name, a duplicate, a hole, a keyed entry, a non-string or no array at all changes nothing")

-- 讀不到原生清單：不能憑客戶端給的名字寫入，但「全部移除」不需要查名
serverRoles = nil
local blind = setOpt(owner, "AdminRoles", { "admin" })
local clearBlind = setOpt(owner, "ReadOnlyRoles", {})
serverRoles = scenarioRoles
check(blind.error == "roles_unavailable" and Cfg.options().AdminRoles.value[1] == "role;semi"
    and clearBlind.ok == true and #Cfg.options().ReadOnlyRoles.value == 0 and A.canRead(mod) == false,
    "with the engine role list unreadable a name cannot be verified and is refused, while taking every name off a list needs no lookup")

-- 每次快照都是自己的副本：客戶端改回覆不能改到伺服器的清單
local mine = Cfg.options().AdminRoles.value
local other = Cfg.options().AdminRoles.value
mine[1] = "tampered"
check(other[1] == "role;semi" and A.isAdmin(semi) == true,
    "each snapshot hands out its own copy of a role array, so a reply a client edits cannot re-point the server's list")

-- 不帶 value ＝ 撤掉 override，回到 sandbox 檔
local resetRoles = setOpt(owner, "AdminRoles")
local resetRead = setOpt(owner, "ReadOnlyRoles")
local resetCap = setOpt(owner, "AdminAdjustMaxPerTx")
check(resetRoles.ok == true and resetRead.ok == true and resetCap.ok == true
    and Cfg.options().AdminRoles.override == false and Cfg.options().AdminRoles.value == "admin;gm"
    and A.isAdmin(gmx) == true and A.canRead(mod) == true and EC.sandbox("AdminAdjustMaxPerTx", 1) == 5000,
    "omitting the value drops the override, so the sandbox file's own string and cap rule again")
local snap = Cfg.options()

-- 自行調帳：預設不允許
L.credit("boss", "survivor", 100, "SYSTEM_MINT", { requestId = "m24b-seed", reasonCode = "t" })
local denied = adjust(boss, { username = "boss", currency = "survivor", delta = 10,
    reason = "paying myself without the grant", requestId = "self-1",
    expectedRev = L.getBalance("boss", "survivor").rev })
check(denied.error == "self_target" and L.getBalance("boss", "survivor").available == 100
    and snap.AdminSelfAdjustRoles.value == "" and selfPerm(boss).selfAdjust ~= true,
    "self adjustment is refused while the grant list is empty, nothing is posted, and the panel is told so")
local granted = setOpt(owner, "AdminSelfAdjustRoles", { "admin" })
check(granted.ok == true and A.canAdjustSelf(boss) == true and A.canAdjustSelf(gmx) == false
    and selfPerm(boss).selfAdjust == true,
    "the grant is exact and per role: 'admin' may now pay itself, the other write role still may not")
local rev = L.getBalance("boss", "survivor").rev
local paid = adjust(boss, { username = "boss", currency = "survivor", delta = 10,
    reason = "self correction with the grant in place", requestId = "self-2", expectedRev = rev })
check(paid.ok == true and L.getBalance("boss", "survivor").available == 110
    and L.getBalance("SYSTEM_ADJUST", "survivor").available == -10,
    "a granted self adjustment posts through SYSTEM_ADJUST like any other, with no private ledger path")
local overCap = adjust(boss, { username = "boss", currency = "survivor", delta = 5001,
    reason = "the per-transaction cap still applies to me", requestId = "self-3", expectedRev = rev + 1 })
local noReason = adjust(boss, { username = "boss", currency = "survivor", delta = 5,
    reason = "   ", requestId = "self-4", expectedRev = rev + 1 })
local noRev = adjust(boss, { username = "boss", currency = "survivor", delta = 5,
    reason = "expectedRev stays mandatory for me too", requestId = "self-5" })
check(overCap.error == "over_max_per_tx" and noReason.error == "reason_blank"
    and noRev.error == "expected_rev_required" and L.getBalance("boss", "survivor").available == 110,
    "the grant relaxes nothing else: the per-tx cap, the reason and expectedRev are still enforced on a self adjustment")
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.freeze", boss, { username = "boss", frozen = true,
    reason = "freezing my own account must stay impossible" })
check(lastSent("admin.freeze").args.error == "self_target" and L.isFrozen("boss") == false,
    "the grant is about money only: freezing your own account is still refused outright")
local revoked = setOpt(owner, "AdminSelfAdjustRoles", {})
local blockedNow = adjust(boss, { username = "boss", currency = "survivor", delta = 7,
    reason = "the grant was taken away before this call", requestId = "self-6",
    expectedRev = L.getBalance("boss", "survivor").rev })
local replay = adjust(boss, { username = "boss", currency = "survivor", delta = 10,
    reason = "self correction with the grant in place", requestId = "self-2", expectedRev = rev })
check(revoked.ok == true and blockedNow.error == "self_target" and selfPerm(boss).selfAdjust ~= true
    and replay.ok == true and replay.duplicate == true and replay.txId == paid.txId
    and L.getBalance("boss", "survivor").available == 110,
    "revoking the grant stops the next self adjustment at once, while a resend of the one already paid still answers with its original result")

-- 賽季天數走的是同一個 admin.option（沒有第二個 setter），而且站在 manageOnly 那一側：經濟
-- 寫入權改不動它，原生角色權才行。寫進去就是現在生效：正在跑的這一季當下重算期限（同一季
-- ID、同一個開始時間），封存過的季不跟著動。
local Se24 = S.Seasons
local before24 = Se24.state()
local writeTry = setOpt(gmx, "SeasonDays", 7)
check(writeTry.error == "manage_settings_required" and Cfg.options().SeasonDays.manageOnly == true
    and EC.sandbox("SeasonDays", 0) == before24.configuredDays
    and Se24.state().seasons[1].durationDays == before24.seasons[1].durationDays,
    "the season length is an ordinary option on the manage-only side: an economy write role cannot set it and nothing is stored")
local setDays = setOpt(owner, "SeasonDays", 7)
local live24 = Se24.state()
check(setDays.ok == true and live24.configuredDays == 7
    and live24.currentId == before24.currentId
    and live24.seasons[1].number == before24.seasons[1].number
    and live24.seasons[1].startedAt == before24.seasons[1].startedAt
    and live24.seasons[1].durationDays == 7
    and live24.seasons[1].endsAt == before24.seasons[1].startedAt + 7 * 86400000,
    "the native role owner sets the length and the season already running takes it at once: same season, same start, a deadline recomputed from that start")
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.seasons", owner,
    { action = "start", expectedSeason = live24.currentId, reason = "apply the new length", requestId = "m24b-season" })
local rotated24 = lastSent("admin.seasons").args
local after24 = Se24.state()
check(rotated24.ok == true and after24.currentId ~= live24.currentId
    and after24.seasons[1].durationDays == 7
    and after24.seasons[1].endsAt == after24.seasons[1].startedAt + 7 * 86400000
    and after24.seasons[2].id == live24.currentId
    and after24.seasons[2].durationDays == 7
    and after24.seasons[2].endsAt == live24.seasons[1].endsAt,
    "the season opened afterwards starts its own seven days, and the one it closed keeps the deadline it was archived with")
local zeroDays = setOpt(owner, "SeasonDays", 0)
local manual24 = Se24.state()
check(zeroDays.ok == true and manual24.configuredDays == 0
    and manual24.currentId == after24.currentId
    and manual24.seasons[1].durationDays == 0
    and manual24.seasons[1].endsAt == nil
    and manual24.seasons[2].endsAt == after24.seasons[2].endsAt,
    "a length of zero lifts the running season's deadline instead of closing it, and the archived season keeps its own")

SandboxVars.MinidoracatEconomy.AdminRoles = "admin"
SandboxVars.MinidoracatEconomy.ReadOnlyRoles = "moderator"
serverRoles = savedRoles
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
;(function()
    local Shop = S.Shop
    zed.x, zed.y, zed.z = 102, 200, 0
    L.credit("zed", "survivor", 200, "SYSTEM_MINT", { requestId = "atm-seed", reasonCode = "t" })
    for i = 64, 67 do
        worldSprites["100,200,0"] = "location_business_bank_01_" .. i
        nowMs = nowMs + 650
        fire("OnClientCommand", EC.COMMAND_MODULE, "shop.buy", zed,
            { id = "bandage", count = 1, currency = "survivor", revision = Shop.revision(), requestId = "native-atm-" .. i })
        check(lastSent("shop.buy").args.ok == true and zed.inventory.count("Base.Bandage") == i - 63,
            "vanilla ATM facing " .. i .. " permits a real purchase without registration")
    end
    zed.x = 102.01
    check(not T.near(zed), "automatic ATM access stops beyond the exact two-tile range")
    zed.x, zed.z = 101, 1
    check(not T.near(zed), "automatic ATM access never crosses floors")
    zed.z = 0
    worldSprites["100,200,0"] = nil
    local balance = L.getBalance("zed", "survivor").available
    nowMs = nowMs + 650
    fire("OnClientCommand", EC.COMMAND_MODULE, "shop.buy", zed,
        { id = "bandage", currency = "survivor", revision = Shop.revision(), requestId = "atm-removed" })
    check(lastSent("shop.buy").args.error == "not_at_terminal" and L.getBalance("zed", "survivor").available == balance,
        "removing an automatic ATM immediately prevents purchase without debiting")
    worldSprites["100,200,0"] = "appliances_com_01_52"
    check(not T.near(zed), "an unregistered computer cabinet is not an automatic ATM")
    worldSprites["100,200,0"] = nil
    check(T.count() == 0, "automatic ATMs create no persistent terminals or radio registrations")
end)()
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
    withCurrency(name, args)
    fire("OnClientCommand", EC.COMMAND_MODULE, name, who, args)
    return lastSent(name).args
end
local list = cmd(zed, "shop.list")
check(#list.items == 13 and list.items[1].category <= list.items[2].category and list.currency == nil and list.atTerminal == false
    and type(list.revision) == "string" and list.items[1].remaining ~= nil and list.items[1].prices.survivor.price > 0,
    "shop.list returns the sorted catalog with per-currency quotes and per-player remaining caps, and no page-wide currency")
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
check(cmd(zed, "shop.buy", { id = "bandage", count = 3, revision = rev }).ok == true and Shop.used("zed", "bandage", nowMs) == 5, "buying up to the cap is fine")
check(cmd(zed, "shop.buy", { id = "axe", revision = rev }).error == "insufficient_funds" and L.getBalance("zed", "survivor").available == 40, "insufficient funds refuse with zero debit")
check(cmd(zed, "shop.buy", { id = "nails", count = 6, revision = rev }).error == "too_many_items", "more than 100 items per purchase is refused")
local rc = L.receipts("zed")
check(rc[#rc].kind == "shop_buy" and rc[#rc].amount == -36 and rc[#rc].counterparty == "SYSTEM_BURN" and rc[#rc].item == "Base.Bandage" and rc[#rc].qty == 3,
    "the receipt ring shows the burn with what was bought")
-- admin edits are written into catalog.json and pushed to everyone online
check(cmd(mod, "admin.catalog", { action = "set", id = "bandage", enabled = false }).error == "forbidden", "a moderator cannot change the catalog")
sentCommands = {}
local set = cmd(boss, "admin.catalog", { action = "set", id = "bandage", enabled = false, prices = { survivor = { price = 99 } } })
local bandage = nil
for _, it in ipairs(set.items) do if it.id == "bandage" then bandage = it end end
local fileText = table.concat(files["MinidoracatEconomy/catalog.json"].lines, "\n")
check(set.ok == true and bandage.enabled == false and bandage.prices.survivor.price == 99 and set.revision ~= rev
    and string.find(fileText, '"price":99', 1, true) ~= nil and string.find(fileText, '"enabled":false', 1, true) ~= nil
    and Shop.fileStatus().count == 13, "an admin edit disables and reprices a SKU in catalog.json itself and bumps the revision")
local pushed = nil
for _, s in ipairs(sentCommands) do if s.command == "shop.list" and s.player == zed then pushed = s.args end end
check(pushed ~= nil and pushed.revision == set.revision, "the change is pushed to every online player as a fresh shop.list")
check(cmd(zed, "shop.buy", { id = "bandage", revision = set.revision }).error == "unknown_sku", "a disabled SKU cannot be bought")
check(cmd(boss, "admin.catalog", { action = "set", id = "bandage", enabled = true, prices = { survivor = { price = 12 } } }).ok == true and Shop.sku("bandage").enabled == true
    and Shop.sku("bandage").prices.survivor.price == 12, "editing back restores the row")
check(cmd(boss, "admin.catalog", { action = "set", id = "nope", enabled = false }).error == "unknown_sku", "unknown SKUs cannot be edited")
check(cmd(boss, "admin.catalog", { action = "set", id = "bandage", prices = { survivor = { price = 0 } } }).error == "invalid_args", "out-of-range values are refused")
-- a hand edit on disk since the last load must not be overwritten by the panel
files["MinidoracatEconomy/catalog.json"].lines[1] = files["MinidoracatEconomy/catalog.json"].lines[1] .. " "
check(cmd(boss, "admin.catalog", { action = "set", id = "bandage", prices = { survivor = { price = 13 } } }).error == "catalog_stale" and Shop.sku("bandage").prices.survivor.price == 12,
    "a file changed outside the panel is refused as stale until reloaded")
check(cmd(boss, "admin.catalog", { action = "reload" }).ok == true and cmd(boss, "admin.catalog", { action = "set", id = "bandage", prices = { survivor = { price = 13 } } }).ok == true
    and Shop.sku("bandage").prices.survivor.price == 13, "after a reload the edit goes through")
cmd(boss, "admin.catalog", { action = "set", id = "bandage", prices = { survivor = { price = 12 } } })
local setRev = Shop.revision()
check(cmd(boss, "admin.catalog", { action = "set", id = "bandage", prices = { survivor = { price = 11 } }, revision = setRev }).ok == true
    and cmd(boss, "admin.catalog", { action = "set", id = "bandage", prices = { survivor = { price = 10 } }, revision = setRev }).error == "catalog_stale"
    and Shop.sku("bandage").prices.survivor.price == 11, "an edit carrying the revision it was built on is refused once another edit moved the file")
cmd(boss, "admin.catalog", { action = "set", id = "bandage", prices = { survivor = { price = 12 } } })
local au = X.auditEntries(20)
local catalogAudit = 0
for _, e in ipairs(au) do if e.action == "catalog" then catalogAudit = catalogAudit + 1 end end
check(catalogAudit >= 5, "catalog edits are audited per field")
rev = cmd(zed, "shop.list").revision
-- backpack full -> stays in the mailbox until claimed at a terminal
zed.inventory.maxWeight = 0.5
rev = cmd(zed, "shop.list").revision
local plank = cmd(zed, "shop.buy", { id = "plank", revision = rev, acceptMail = true })
check(plank.ok == true and plank.delivered == false and plank.mailed == true and M.unclaimed("zed") == 1
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
cmd(zed, "shop.buy", { id = "rope", revision = rev, acceptMail = true })
cmd(zed, "shop.buy", { id = "rope", revision = rev, acceptMail = true })
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
-- admin.catalog{action="add"}: a new row appended to the file itself
check(cmd(mod, "admin.catalog", { action = "add", id = "cat_snack", item = "MiniFarm.CatSnack", prices = { survivor = { price = 20 } } }).error == "forbidden"
    and Shop.sku("cat_snack") == nil, "a moderator cannot add a SKU")
local baseRev = Shop.revision()
sentCommands = {}
local added = cmd(boss, "admin.catalog", { action = "add", id = "cat_snack", item = "MiniFarm.CatSnack", qty = 2,
    dailyCap = 3, category = "food", prices = { survivor = { price = 20, bidPrice = 8 } }, revision = baseRev })
local addedRow, addedPush = nil, nil
for _, it in ipairs(added.items) do if it.id == "cat_snack" then addedRow = it end end
for _, s in ipairs(sentCommands) do if s.command == "shop.list" and s.player == zed then addedPush = s.args end end
local addText = table.concat(files["MinidoracatEconomy/catalog.json"].lines, "\n")
check(added.ok == true and added.count == 2 and addedRow ~= nil and addedRow.item == "MiniFarm.CatSnack" and addedRow.qty == 2
    and addedRow.prices.survivor.price == 20 and addedRow.enabled == true and addedRow.prices.survivor.buyback == false and addedRow.prices.survivor.bidPrice == 8
    and string.find(addText, "MiniFarm.CatSnack", 1, true) ~= nil and added.revision ~= baseRev
    and addedPush ~= nil and addedPush.revision == added.revision,
    "an admin adds a mod item as a new SKU: written into catalog.json with buyback off and pushed to everyone online")
zed.inventory.maxWeight = 50
local snack = cmd(zed, "shop.buy", { id = "cat_snack", revision = added.revision })
check(snack.ok == true and snack.total == 20 and snack.delivered == true and zed.inventory.count("MiniFarm.CatSnack") == 2
    and Shop.used("zed", "cat_snack", nowMs) == 1, "the SKU the admin just added is on sale straight away")
check(cmd(boss, "admin.catalog", { action = "add", id = "cat_snack", item = "Base.Twine", prices = { survivor = { price = 5 } } }).error == "duplicate_sku"
    and Shop.sku("cat_snack").item == "MiniFarm.CatSnack", "an id already in the catalog is refused and the existing row is untouched")
check(cmd(boss, "admin.catalog", { action = "add", id = "ghost", item = "NoSuchMod.Ghost", prices = { survivor = { price = 5 } } }).error == "unknown_item"
    and cmd(boss, "admin.catalog", { action = "add", id = "bad id", item = "Base.Twine", prices = { survivor = { price = 5 } } }).error == "invalid_args"
    and cmd(boss, "admin.catalog", { action = "add", id = "no_price", item = "Base.Twine", prices = { survivor = { price = 0 } } }).error == "invalid_args"
    and cmd(boss, "admin.catalog", { action = "add", id = "bad_bid", item = "Base.Twine", prices = { survivor = { price = 5, bidPrice = 5, buyback = true } } }).error == "invalid_args"
    and Shop.fileStatus().count == 2, "an item the server does not know, a bad id and out-of-range fields are all refused without touching the catalog")
check(cmd(boss, "admin.catalog", { action = "add", id = "stale_row", item = "Base.Twine", prices = { survivor = { price = 5 } }, revision = baseRev }).error == "catalog_stale"
    and Shop.sku("stale_row") == nil, "an add built on an older snapshot revision is refused instead of overwriting the newer file")
writerDeny["MinidoracatEconomy/catalog.json"] = true
local denied = cmd(boss, "admin.catalog", { action = "add", id = "no_write", item = "Base.Twine", prices = { survivor = { price = 5 } } })
writerDeny["MinidoracatEconomy/catalog.json"] = nil
check(denied.error == "file_write_failed" and Shop.sku("no_write") == nil and Shop.fileStatus().count == 2
    and string.find(table.concat(files["MinidoracatEconomy/catalog.json"].lines, "\n"), "no_write", 1, true) == nil,
    "a catalog the server cannot write keeps the new SKU out of both the file and the loaded catalog")
do
    local savedFile = files[Shop.FILE]
    local realWriter, realReader = getFileWriter, getFileReader
    local auditBefore = #X.auditEntries(500)
    getFileWriter = function(path, create, append)
        local writer = realWriter(path, create, append)
        if path == Shop.FILE and writer then
            writer.close = function() files[path].lines = { "{" } end
        end
        return writer
    end
    sentCommands = {}
    local unreadable = cmd(boss, "admin.catalog", { action = "add", id = "bad_readback", item = "Base.Twine", prices = { survivor = { price = 5 } } })
    getFileWriter = realWriter
    local pushed = false
    for _, s in ipairs(sentCommands) do if s.command == "shop.list" then pushed = true end end
    check(unreadable.error == "file_write_failed" and Shop.sku("bad_readback") == nil
        and Shop.fileStatus().count == 2 and not pushed and #X.auditEntries(500) == auditBefore,
        "a malformed read-back keeps the candidate out of the live catalog and emits no success")
    files[Shop.FILE] = savedFile
    Shop.load()

    local reads = 0
    getFileReader = function(path, create)
        if path == Shop.FILE then
            reads = reads + 1
            if reads == 2 then return nil end
        end
        return realReader(path, create)
    end
    local nilRead = cmd(boss, "admin.catalog", { action = "add", id = "nil_readback", item = "Base.Twine", prices = { survivor = { price = 5 } } })
    getFileReader = realReader
    check(nilRead.error == "file_write_failed" and Shop.sku("nil_readback") == nil
        and Shop.fileStatus().count == 2
        and string.find(table.concat(files[Shop.FILE].lines, "\n"), "nil_readback", 1, true) ~= nil,
        "an unreadable write-back never replaces the written catalog with default items")
    files[Shop.FILE] = savedFile
    Shop.load()
    getFileReader = function(path, create)
        if path == Shop.FILE then return nil end
        return realReader(path, create)
    end
    local readOk = Shop.load()
    getFileReader = realReader
    check(readOk == false and table.concat(files[Shop.FILE].lines, "\n") == table.concat(savedFile.lines, "\n")
        and Shop.fileStatus().count == 2,
        "an existing catalog that cannot be opened is not mistaken for a missing first-run file")
    Shop.load()
end
local bulk = {}
for i = 1, Shop.MAX_SKUS do bulk[#bulk + 1] = '{"id":"bulk' .. i .. '","item":"Base.Twine","qty":1,"price":7}' end
files["MinidoracatEconomy/catalog.json"] = { lines = { '{"items":[' .. table.concat(bulk, ",") .. ']}' }, opens = 0 }
check(cmd(boss, "admin.catalog", { action = "reload" }).count == Shop.MAX_SKUS
    and cmd(boss, "admin.catalog", { action = "add", id = "one_too_many", item = "Base.Twine", prices = { survivor = { price = 7 } } }).error == "catalog_full"
    and Shop.sku("one_too_many") == nil, "a catalog already at the 200-SKU ceiling refuses one more")
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
    withCurrency(name, args)
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
local b6 = cmd(zed, "shop.buy", { id = "plank", revision = rev, acceptMail = true })
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
check(EC.parseDay("2026-02-29", 0) == nil and EC.parseDay("2024-02-30", 0) == nil,
    "invalid February dates never roll into March")
check(EC.parseDay("2026-04-31", 0) == nil and EC.parseDay("2026-04-30", 0) ~= nil,
    "short months reject day 31 while retaining their last day")
check(EC.parseDay("2100-02-29", 0) == nil and EC.parseDay("2000-02-29", 0) ==
    EC.parseDay("2000-03-01", 0) - 86400000,
    "leap days follow the Gregorian century rule")
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
-- 卸載 MOD 後留下的 explicit 規則：inherit 不需要 ScriptManager 認得那個 fullType 才能移除
files["MinidoracatEconomy/whitelist.json"] = { lines = { '{"categories":["Tool"],"types":["GoneMod.Relic"],"excludeTypes":["GoneMod.Relic"],"modDataKeys":[]}' }, opens = 0 }
local orphanLoad = wcmd(boss, { action = "reload" })
check(orphanLoad.ok == true and orphanLoad.whitelist.types[1] == "GoneMod.Relic" and orphanLoad.whitelist.excludeTypes[1] == "GoneMod.Relic",
    "an explicit rule whose mod is gone is kept by the load instead of being dropped")
local orphan = wcmd(boss, { action = "set", fullType = "GoneMod.Relic", mode = "inherit" })
check(orphan.ok == true and #orphan.whitelist.types == 0 and #orphan.whitelist.excludeTypes == 0
    and string.find(table.concat(files["MinidoracatEconomy/whitelist.json"].lines, "\n"), "GoneMod.Relic", 1, true) == nil,
    "inherit removes an orphan rule from both lists without asking the item registry")
local wlText = table.concat(files["MinidoracatEconomy/whitelist.json"].lines, "\n")
check(wcmd(boss, { action = "set", fullType = "GoneMod.Relic", mode = "allow" }).error == "unknown_item"
    and wcmd(boss, { action = "set", fullType = 5, mode = "inherit" }).error == "invalid_args"
    and table.concat(files["MinidoracatEconomy/whitelist.json"].lines, "\n") == wlText,
    "an unknown item still cannot be allowed and a fullType that is not a string is refused without rewriting the file")
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
    withCurrency(name, args)
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
check(cmd(ann, "market.buy", { listingId = listed.listingId, price = 200 }).error == "own_listing", "a seller cannot buy their own listing")
check(cmd(bob, "market.buy", { listingId = listed.listingId, price = 150 }).error == "price_changed", "a confirmation price that differs is refused")
local bought = cmd(bob, "market.buy", { listingId = listed.listingId, price = 200, requestId = "b1" })
check(bought.ok == true and bought.tax == 10 and bought.delivered == true and bob.inventory.count("Base.Axe") == 1 and bob.inventory.items[#bob.inventory.items].condition == 4
    and L.getBalance("bob", "survivor").available == 300 and L.getBalance("ann", "survivor").available == 285 and not Mk.listingExists(listed.listingId),
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
check(cancelled.ok == true and cancelled.delivered == true and ann.inventory.count("Base.Nails") == 2 and not Mk.listingExists(nailsId) and L.getBalance("ann", "survivor").available == 285,
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
check(not Mk.listingExists(n3.listingId) and M.unclaimed("ann") == 1 and M.used("ann") <= M.capacity(), "an expired listing goes back to the seller's mailbox even when it is full, without overshooting")
SandboxVars.MinidoracatEconomy.MailboxPerAccount = nil
local expired = 0
fire("OnTickEvenPaused")
for _, f in pairs(files) do for _, l in ipairs(f.lines) do if string.find(l, '"type":"market.expired"', 1, true) then expired = expired + 1 end end end
check(expired == 1, "expiry is journaled")
-- admin delist
local h1 = instanceItem("Base.Hammer"); cat.inventory:AddItem(h1)
local lh = cmd(cat, "market.list", { itemId = h1.id, price = 80 })
check(cmd(bob, "admin.listings", { action = "delist", listingId = lh.listingId }).error == "forbidden", "a player cannot delist")
local ghostDelist = cmd(boss, "admin.listings", { action = "delist", listingId = "no-such-listing", reason = "typo" })
check(ghostDelist.ok == false and type(ghostDelist.error) == "string" and ghostDelist.items ~= nil
    and ghostDelist.total ~= nil and Mk.listingExists(lh.listingId),
    "a refused delist stays refused: the browse snapshot flattened into the same reply carries the list back without turning the failure into a success")
local dl = cmd(boss, "admin.listings", { action = "delist", listingId = lh.listingId, reason = "spam" })
check(dl.ok == true and not Mk.listingExists(lh.listingId) and M.unclaimed("cat") == 1 and dl.total == 0, "an admin delist returns the item to the seller mailbox and is audited")
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
    local rows = Mk.browse("bob", { sort = sort, currency = "survivor" }).items
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
    withCurrency(name, args)
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
proofSettle()              -- 證據要先真的落盤：journal 在檔案層，不隨 ModData 回滾
local playerSave = { inv = deepCopy(ann.inventory.items), md = deepCopy(ann.modData) }  -- player save AFTER the listing (item gone, pending present)
-- row 4: world rolls back below the listing, player save is newer -> listing rebuilt from the pending snapshot
modDataStore[EC.MODDATA_KEY] = deepCopy(saved)
nowMs = nowMs + 1000
fire("OnServerStarted")
onlinePlayers = { boss, ann }
cmd(ann, "hello")
proofPump("ann")           -- journal 查詢是非同步的：有界 pump 到該帳號讀取收斂
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
-- A native-id collision alone cannot prove identity; retain the unverified object for review.
local ghost = instanceItem("Base.Axe"); ghost.id = axe.id; ann.inventory:AddItem(ghost)
ann.modData[KEY].pendingOuts[listed.listingId] = deepCopy(restoredPend)
sentItemPackets = {}
cmd(ann, "hello")
check(ann.inventory.count("Base.Axe") == 1 and M.recoveryStatus("ann").held > 0
    and ann.modData[KEY].pendingOuts[listed.listingId] ~= nil and Mk.listingExists(listed.listingId),
    "an unverified native-id match is held without destroying a potentially different object")
local disputed = cmd(ann, "market.list", { itemId = ghost.id, price = 120 })
check(disputed.ok == false and ann.inventory.count("Base.Axe") == 1 and Mk.ownerCount("ann") == 1,
    "the retained native-id conflict cannot be relisted as another asset")
-- row 5: crashed before the removal (pending present, item present, no listing) -> pending cleared, item stays
local hammer = instanceItem("Base.Hammer"); ann.inventory:AddItem(hammer)
ann.modData[KEY].pendingOuts["9999:1"] = { itemId = hammer.id, snapshot = { type = "Base.Hammer" }, price = 10, seq = 1, epoch = "9999" }
cmd(ann, "hello")
check(ann.inventory.count("Base.Hammer") == 1 and ann.modData[KEY].pendingOuts["9999:1"] == nil and anomalies("pending-cleared-item-present") == 1,
    "row 5: a pending op whose item never left the backpack is simply forgotten")
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
    withCurrency(name, args)
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
check(string.find(radioSent[1].msg, "最新上架：Base.Plank ×2 30 倖存幣、Base.Axe 120 倖存幣", 1, true) ~= nil, "newest listings first, with quantity, price and the currency each one is priced in: " .. tostring(radioSent[1].msg))
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
    withCurrency(name, args)
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
check(M.used("ann") == 1 and M.usage("ann").auctions == 1 and M.usage("ann").marketListings == 0, "an auction occupies a named auction slot")
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
check(#entries == 1 and entries[1].kind == "return" and entries[1].item == "Base.Saw" and entries[1].seller == nil, "the return entry is claimable and names no third party")
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
proofSettle()              -- 證據要先真的落盤：journal 在檔案層，不隨 ModData 回滾
local playerInv, playerMd = deepCopyTable(ann.inventory.items), deepCopyTable(ann.modData)
modDataStore[EC.MODDATA_KEY] = saved
fire("OnServerStarted")
check(not S.Auction.hasAuction(c5.auctionId), "setup: the world rolled back below the auction")
ann.inventory.items = playerInv; ann.modData = playerMd
cmd(ann, "hello")
proofPump("ann")           -- journal 查詢是非同步的：有界 pump 到該帳號讀取收斂
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
    withCurrency(name, args)
    fire("OnClientCommand", EC.COMMAND_MODULE, name, who, args)
    local sent = lastSent(name)
    return sent and sent.args or {}
end
local function bal() return L.getBalance("zed", "survivor").available end
worldSprites = { ["100,200,0"] = "MinidoracatEconomy_terminal_0" }
cmd(boss, "terminal.register", { x = 100, y = 200, z = 0, kind = "atm" })
-- catalog: the default file has no buyback; the panel turns it on for two SKUs
local list = cmd(zed, "shop.list")
check(list.buyback.enabled == false and list.items[1].prices.survivor.buyback == false and list.items[1].prices.survivor.bidPrice > 0, "the default catalog carries bid prices but buys nothing; the faucet is closed")
check(cmd(boss, "admin.catalog", { action = "set", id = "axe", prices = { survivor = { bidPrice = 150 } } }).error == "invalid_args", "bidPrice must stay below the price")
check(cmd(boss, "admin.catalog", { action = "set", id = "axe", prices = { survivor = { bidPrice = 0, buyback = true } } }).error == "invalid_args", "buyback needs a bidPrice of at least 1")
local set = cmd(boss, "admin.catalog", { action = "set", id = "axe", buybackCap = 2, prices = { survivor = { bidPrice = 60, buyback = true } } })
local fileText = table.concat(files["MinidoracatEconomy/catalog.json"].lines, "\n")
check(set.ok == true and Shop.sku("axe").prices.survivor.bidPrice == 60 and Shop.sku("axe").prices.survivor.buyback == true and Shop.sku("axe").buybackCap == 2
    and string.find(fileText, '"bidPrice":60', 1, true) ~= nil and string.find(fileText, '"buyback":true', 1, true) ~= nil, "buyback fields are written into catalog.json")
check(cmd(boss, "admin.catalog", { action = "set", id = "nails", prices = { survivor = { bidPrice = 10, buyback = true } } }).ok == true, "setup: nails (qty 20) are bought at 10 per 20")
local rev = Shop.revision()
local axe = instanceItem("Base.Axe"); zed.inventory:AddItem(axe)
check(cmd(zed, "shop.sell", { id = "axe", itemIds = { axe.id }, revision = rev }).error == "buyback_disabled", "the faucet is closed until the sandbox switch is on")
SandboxVars.MinidoracatEconomy.ShopBuybackEnabled = true
SandboxVars.MinidoracatEconomy.ShopBuybackPerAccountDaily = 200
SandboxVars.MinidoracatEconomy.ShopBuybackServerDaily = 250
check(cmd(zed, "shop.list").buyback.enabled == true and cmd(zed, "shop.list").buyback.byCurrency.survivor.accountRemaining == 200, "shop.list shows the open faucet and the remaining room per currency")
check(cmd(zed, "shop.sell", { id = "bandage", itemIds = { axe.id }, revision = rev }).error == "currency_closed", "a SKU whose buyback direction is closed in that currency cannot be sold into it")
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
check(sale.buyback.byCurrency.survivor.accountRemaining == 140 and sale.buyback.skuRemaining == 1, "the reply carries the remaining room (coins per currency, shares shared)")
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
check(Shop.buybackStatus(nowMs).byCurrency.survivor.mintedToday == 140, "buybackStatus reports today's gross mint per currency")
-- the kill switch closes at once
SandboxVars.MinidoracatEconomy.ShopBuybackEnabled = false
check(cmd(zed, "shop.sell", { id = "nails", itemIds = nailIds, revision = rev }).error == "buyback_disabled", "closing the switch stops sales immediately")
SandboxVars.MinidoracatEconomy.ShopBuybackEnabled = true
-- dashboard rollups: mint / buyback / burn by day
L.credit("zed", "survivor", 100, "SYSTEM_MINT", { requestId = "au-seed-zed33", reasonCode = "t" })
cmd(zed, "shop.buy", { id = "bandage", count = 1, revision = rev })
local sys = cmd(boss, "admin.system")
local issuedSur = sys.issued.today.byCurrency.survivor
check(issuedSur.buyback == 140 and issuedSur.mint == 240 and issuedSur.burn == 12
    and issuedSur.unknownDays == 0 and sys.issued.today.byCurrency.cat.mint == 0
    and sys.buyback.enabled == true and sys.buyback.byCurrency.survivor.mintedToday == 140,
    "admin.system reports today's mint, buyback share and burn per currency, and a currency with no flow is a real zero rather than a missing block: "
        .. tostring(issuedSur.mint) .. "/" .. tostring(issuedSur.buyback) .. "/" .. tostring(issuedSur.burn))
-- rollback: a sale after the save point is paid again from the player save (row 4)
fire("OnTickEvenPaused")
local saved = deepCopyTable(modDataStore[EC.MODDATA_KEY])
local before = bal()
local s2 = cmd(zed, "shop.sell", { id = "nails", itemIds = nailIds, revision = rev })
check(s2.ok == true and bal() == before + 20, "setup: a sale after the save point")
proofSettle()              -- 證據要先真的落盤：journal 在檔案層，不隨 ModData 回滾
local playerInv, playerMd = deepCopyTable(zed.inventory.items), deepCopyTable(zed.modData)
modDataStore[EC.MODDATA_KEY] = saved
fire("OnServerStarted")
check(bal() == before, "setup: the world rolled back below the sale")
zed.inventory.items = playerInv; zed.modData = playerMd
cmd(zed, "hello")
proofPump("zed")           -- journal 查詢是非同步的：有界 pump 到該帳號讀取收斂
check(bal() == before + 20 and zed.inventory.count("Base.Nails") == 0, "after a rollback the sale is paid again from the pending record")
check(L.conservation("survivor") == 0, "the repaid mint is conserved")
check(Shop.buybackRoom("zed", "nails", nowMs, "survivor").account == 200 - 140 - 20 and Shop.buybackStatus(nowMs).byCurrency.survivor.mintedToday == 160, "the repaid mint counts against today's caps (the day buckets rolled back too)")
-- rollback with the balance cap in the way: the items come back through the mailbox instead
fire("OnTickEvenPaused")
saved = deepCopyTable(modDataStore[EC.MODDATA_KEY])
local a4 = instanceItem("Base.Axe"); zed.inventory:AddItem(a4)
nowMs = nowMs + 86400000        -- next reward day: fresh caps
local s3 = cmd(zed, "shop.sell", { id = "axe", itemIds = { a4.id }, revision = rev })
check(s3.ok == true, "setup: an axe sold on the next day")
proofSettle()              -- 證據要先真的落盤：journal 在檔案層，不隨 ModData 回滾
playerInv, playerMd = deepCopyTable(zed.inventory.items), deepCopyTable(zed.modData)
modDataStore[EC.MODDATA_KEY] = saved
fire("OnServerStarted")
zed.inventory.items = playerInv; zed.modData = playerMd
SandboxVars.MinidoracatEconomy.BalanceMax = 1000
L.credit("zed", "survivor", 1000 - bal(), "SYSTEM_MINT", { requestId = "fill-zed33", reasonCode = "t" })
cmd(zed, "hello")
proofPump("zed")           -- journal 查詢是非同步的：有界 pump 到該帳號讀取收斂
check(bal() == 1000 and M.unclaimed("zed") == 1, "when the repayment would break the balance cap the axe is returned through the mailbox")
SandboxVars.MinidoracatEconomy.BalanceMax = nil
cmd(zed, "mail.list")
local entries = lastSent("mail.list").args.entries
check(#entries == 1 and entries[1].item == "Base.Axe" and entries[1].kind == "return", "the return entry is the axe")
-- 寫入失敗的東西不是證據：伺服器知道自己沒寫成功，就不能宣稱從來沒這筆，也不能靠玩家那份付款
local proofPath = "MinidoracatEconomy/recovery/" .. EC.safeName("zed") .. "/" .. EC.monthKey(nowMs) .. ".json"
writerDeny[proofPath] = true
fire("OnTickEvenPaused")
saved = deepCopyTable(modDataStore[EC.MODDATA_KEY])
local a5 = instanceItem("Base.Axe"); zed.inventory:AddItem(a5)
local seenPends = {}
for k in pairs(zed.modData[KEY].pendingOuts) do seenPends[k] = true end
local s4 = cmd(zed, "shop.sell", { id = "axe", itemIds = { a5.id }, revision = rev })
fire("OnTickEvenPaused")          -- 佇列排空，但這個目標寫不進去：那一行永遠沒有落盤
writerDeny[proofPath] = nil
local lostOp = nil
for k in pairs(zed.modData[KEY].pendingOuts) do if not seenPends[k] then lostOp = k end end
-- (a) 同一個 process 內：這台伺服器還記得自己剛剛寫失敗過，所以答案是「讀不動」，不是「沒有」
local balSameProcess, axesSameProcess = bal(), zed.inventory.count("Base.Axe")
S.RecoveryJournal.lookup("zed", lostOp, zed.modData[KEY].pendingOuts[lostOp])
proofPump("zed")
local _, sameProcessReason = S.RecoveryJournal.lookup("zed", lostOp, zed.modData[KEY].pendingOuts[lostOp])
check(s4.ok == true and lostOp ~= nil and sameProcessReason == "journal_unreadable"
    and bal() == balSameProcess and zed.inventory.count("Base.Axe") == axesSameProcess,
    "while the process still remembers its own failed write the answer is that the proof cannot be read, not that it never existed - and nothing is paid either way")
-- (b) 重啟之後：失敗記號是 process-local，檔案裡就是沒有那一行，伺服器誠實地說查無此筆
playerInv, playerMd = deepCopyTable(zed.inventory.items), deepCopyTable(zed.modData)
modDataStore[EC.MODDATA_KEY] = saved
fire("OnServerStarted")
zed.inventory.items = playerInv; zed.modData = playerMd
local beforeHold = bal()
local axesBefore = zed.inventory.count("Base.Axe")
cmd(zed, "hello")
proofPump("zed")
local lostHold = lostOp and S.Recovery.heldRecord("zed", "pend:" .. lostOp) or nil
check(bal() == beforeHold and zed.inventory.count("Base.Axe") == axesBefore
    and lostHold ~= nil and lostHold.reason == "journal_missing" and lostHold.resolvedAt == nil,
    "a restart takes the memory of the failed write with it: the record is held as one nobody can find, never repaid from the player's own copy, and no axe is conjured back")
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

-- ===== 情境三十五：收購總開關同步與拍賣紀錄 =====
io.write("scenario 35: buyback state and auction history\n")
;(function()
    local Shop, Cfg = S.Shop, S.Config
    modDataStore[EC.MODDATA_KEY] = nil
    files, sentCommands = {}, {}
    nowMs = 1788825600000 -- 2026-09-08 00:00 UTC
    fire("OnServerStarted")
    local boss = fakePlayer("history-admin"); boss.role = "admin"
    local seller = fakePlayer("history-seller")
    local bidder = fakePlayer("history-bidder")
    local reader = fakePlayer("history-reader"); reader.role = "moderator"
    onlinePlayers = { seller, boss }
    local function cmd(who, name, args)
        nowMs = nowMs + 700
        sentCommands = {}
        args = withCurrency(name, args or {})
        fire("OnClientCommand", EC.COMMAND_MODULE, name, who, args)
        local reply = lastSent(name)
        return reply and reply.args
    end
    local function pushedTo(who)
        for _, rec in ipairs(sentCommands) do
            if rec.command == "shop.list" and rec.player == who then return rec.args end
        end
    end
    Shop.update("axe", { prices = { survivor = { bidPrice = 60, buyback = true } } }, boss:getUsername())
    local enabled = cmd(boss, "admin.option", { key = "ShopBuybackEnabled", value = true, requestId = "master-on" })
    local pushed = pushedTo(seller)
    check(enabled and enabled.ok and pushed and pushed.buyback.enabled == true,
        "changing the master switch pushes a sellable shop snapshot to an already-open shop")
    local disabled = cmd(boss, "admin.option", { key = "ShopBuybackEnabled", value = false, requestId = "master-off" })
    pushed = pushedTo(seller)
    check(disabled and disabled.ok and pushed and pushed.buyback.enabled == false and Shop.sku("axe").prices.survivor.buyback == true,
        "closing the master switch pushes paused state without erasing the item's buyback configuration")
    local denied = cmd(seller, "admin.option", { key = "ShopBuybackEnabled", value = true, requestId = "master-spoof" })
    check(denied and denied.error == "forbidden" and not Shop.buybackEnabled(), "a player cannot bypass the master switch")
    Cfg.setOption("ShopBuybackEnabled", nil, boss:getUsername())

    -- Existing event files, including records predating the history UI; no second journal.
    local root = S.modData()
    root.meta.history[#root.meta.history + 1] = { epoch = "history-crash", loadedSeq = 0 }
    local function event(id, kind, fields)
        local e = { type = "auction." .. kind, epoch = "history-crash", seq = 1,
            auctionId = id, ts = nowMs, seller = "history-seller", item = "Base.Axe" }
        for k, v in pairs(fields or {}) do e[k] = v end
        return EC.jsonEncode(e)
    end
    files[X.ROOT .. "/events-20260801.json"] = { opens = 0, lines = {
        event("older-auction", "bid", { bidder = "NeedleAccount", amount = 17 }),
    } }
    local currentPath = X.ROOT .. "/events-20260908.json"
    files[currentPath] = { opens = 0, lines = {
        event("auction-1", "created", { startPrice = 10, qty = 1 }),
        event("auction-1", "bid", { bidder = "history-bidder", amount = 10, private = "must-not-leak" }),
        event("auction-1", "bid", { bidder = "other-bidder", amount = 11, previous = "history-bidder", previousAmount = 10 }),
    } }
    for i = 1, 220 do
        files[currentPath].lines[#files[currentPath].lines + 1] =
            event("unrelated-" .. i, "bid", { seller = "unrelated-seller", bidder = "unrelated-bidder", amount = i })
    end
    local function history(who, command, args)
        cmd(who, command, args)
        for _ = 1, 20 do fire("OnTickEvenPaused") end
        local reply = lastSent(command)
        return reply and reply.args
    end
    local own = history(seller, "auction.history", {})
    check(own and not own.error and #own.entries == 4 and own.entries[1].auctionId == "older-auction",
        "a seller sees every bid on their auctions, including the first day of last month")
    local his = history(bidder, "auction.history", { username = "unrelated-seller" })
    check(his and #his.entries == 2 and his.entries[1].bidder == "history-bidder"
        and his.entries[2].bidder == "other-bidder",
        "own history includes being outbid and ignores a client-supplied username")
    local timeline = history(bidder, "auction.history", { auctionId = "auction-1", requestId = "history-exact" })
    check(timeline and #timeline.entries == 3 and timeline.entries[2].price == 10 and timeline.entries[3].price == 11
        and timeline.auctionId == "auction-1" and timeline.requestId == "history-exact",
        "one auction's public timeline preserves both bid amounts and echoes the exact request")
    check(timeline and timeline.entries[2].private == nil and timeline.entries[2].postings == nil
        and timeline.entries[2].rolledBack == true, "public history strips private fields and flags rolled-back bids")
    local adminDenied = history(bidder, "admin.auctions", { action = "history" })
    check(adminDenied and adminDenied.error == "forbidden", "global auction history still requires the admin read gate")
    local global = history(reader, "admin.auctions", { action = "history" })
    check(global and not global.error and global.truncated == true and #global.entries == 200
        and global.total == 224, "a read-only moderator can search global history with an explicit 200-match limit")
    local match = history(reader, "admin.auctions", { action = "history", query = "NeedleAccount" })
    check(match and #match.entries == 1 and match.entries[1].auctionId == "older-auction" and not match.truncated,
        "search happens before the tail limit so newer unrelated records do not hide an old matching bid")
    local invalid = history(reader, "admin.auctions", { action = "history", query = string.rep("x", 129) })
    check(invalid and invalid.error == "invalid_args", "oversized history searches fail closed")
    local readonly = history(reader, "admin.auctions", { action = "cancel", auctionId = "auction-1", reason = "no" })
    check(readonly and readonly.error == "forbidden", "adding read-only history does not enable moderator cancellation")

    local originalReader = getFileReader
    getFileReader = function(path, create)
        if path == currentPath then
            return { readLine = function() error("read failed") end, close = function() end }
        end
        return originalReader(path, create)
    end
    local broken = history(seller, "auction.history", { auctionId = "auction-1" })
    check(broken and broken.error == "read_failed", "file I/O failure is reported rather than disguised as empty history")
    getFileReader = function(path, create)
        if path == currentPath then return nil end
        return originalReader(path, create)
    end
    broken = history(seller, "auction.history", {})
    check(broken and broken.error == "read_failed" and #broken.entries == 0,
        "an existing later file that returns a nil reader invalidates the earlier partial matches")
    getFileReader = function(path, create)
        if path == X.ROOT .. "/events-20260801.json" then return nil end
        return originalReader(path, create)
    end
    broken = history(seller, "auction.history", {})
    check(broken and broken.error == "read_failed" and #broken.entries == 0,
        "an existing first file that cannot be opened reports an error, not empty history")
    getFileReader = originalReader
    onlinePlayers = {}
end)()

-- ===== 情境三十六：全服金流（只讀原帳本，不重算業務事件） =====
io.write("scenario 36: administrator transaction ledger\n")
;(function()
    modDataStore[EC.MODDATA_KEY] = nil
    files, sentCommands = {}, {}
    nowMs = 1788825600000
    fire("OnServerStarted")
    local admin = fakePlayer("ledger-admin"); admin.role = "admin"
    local reader = fakePlayer("ledger-reader"); reader.role = "moderator"
    local buyer = fakePlayer("ledger-buyer")
    onlinePlayers = { admin, reader, buyer }
    worldSprites = { ["100,200,0"] = "MinidoracatEconomy_terminal_0" }
    local function cmd(who, name, args)
        nowMs = nowMs + 700
        sentCommands = {}
        args = withCurrency(name, args or {})
        fire("OnClientCommand", EC.COMMAND_MODULE, name, who, args)
        for _ = 1, 20 do fire("OnTickEvenPaused") end
        local reply = lastSent(name)
        return reply and reply.args
    end
    cmd(admin, "terminal.register", { x = 100, y = 200, z = 0, kind = "atm" })
    L.credit("ledger-buyer", "survivor", 1000, "SYSTEM_MINT", { requestId = "ledger-seed", reasonCode = "seed" })
    local purchase = S.Shop.buy(buyer, { id = "bandage", count = 2, currency = "survivor", revision = S.Shop.revision(), requestId = "ledger-purchase" })
    S.Config.setOption("ShopBuybackEnabled", true, admin:getUsername())
    S.Shop.update("bandage", { prices = { survivor = { bidPrice = 5, buyback = true } } }, admin:getUsername())
    local buyback = S.Shop.sell(buyer, { id = "bandage", itemIds = { buyer.inventory.items[1].id }, currency = "survivor",
        revision = S.Shop.revision(), requestId = "ledger-buyback" })
    local trade = L.post({
        kind = "market_buy", requestId = "ledger-market", reasonCode = "market_buy", actor = "ledger-buyer",
        payload = { item = "Base.Axe", qty = 1, listingId = "listing-ledger", tax = 5 },
        postings = {
            { account = "ledger-buyer", currency = "survivor", amount = -100 },
            { account = "ledger-seller", currency = "survivor", amount = 95 },
            { account = "SYSTEM_BURN", currency = "survivor", amount = 5 },
        },
    })
    local reserve = L.post({
        kind = "auction_bid", requestId = "ledger-reserve", reasonCode = "auction_bid", actor = "ledger-buyer",
        payload = { item = "Base.Axe", qty = 1, auctionId = "auction-ledger", bid = 50 },
        postings = {
            { account = "ledger-buyer", currency = "survivor", amount = -50 },
            { account = "ledger-buyer", currency = "survivor", amount = 50, bucket = "reserved" },
        },
    })
    local integration = L.post({
        kind = "mod", requestId = "ledger-integration", reasonCode = "subscription", reasonText = "needle-reason",
        actor = "IntegrationExample",
        payload = { sourceMod = "IntegrationExample", ref = { type = "subscription", id = "needle-ref" },
            meta = { secret = "not-returned" } },
        postings = {
            { account = "ledger-buyer", currency = "survivor", amount = -7 },
            { account = "MOD:IntegrationExample", currency = "survivor", amount = 7 },
            { account = "ledger-buyer", currency = "cat", amount = 3 },
            { account = "MOD:IntegrationExample", currency = "cat", amount = -3 },
        },
    })
    local fullReason = string.rep("測試原因", 200)
    local adjustment = L.credit("ledger-buyer", "survivor", 9, "SYSTEM_ADJUST",
        { kind = "admin_adjust", requestId = "ledger-adjust", reasonCode = "admin_adjust", actor = "ledger-admin", reasonText = fullReason })
    L.credit("ledger-buyer", "survivor", 30, "SYSTEM_MINT",
        { kind = "checkin", requestId = "ledger-reward", reasonCode = "daily_checkin" })
    local deposit = L.credit("ledger-buyer", "cat", 10, "EXTERNAL_DISCORD_cat",
        { kind = "exchange_deposit", requestId = "ledger-discord", reasonCode = "exchange_deposit", payload = { orderId = "deposit-ledger" } })
    for i = 1, 221 do
        L.credit("unrelated-account", "survivor", 1, "SYSTEM_MINT", { requestId = "ledger-noise-" .. i, reasonCode = "seed" })
    end
    for _ = 1, 20 do fire("OnTickEvenPaused") end
    local balancesBefore = EC.jsonEncode(S.modData().wallets)

    local sales = cmd(reader, "admin.transactions", { group = "shop_buy" })
    check(purchase.ok and sales and not sales.error and #sales.entries == 1 and sales.entries[1].txId == purchase.txId
        and sales.entries[1].amounts.survivor == 24 and sales.entries[1].qty == 2,
        "shop sales use one committed transaction, not the business event or both receipt copies")
    local buys = cmd(reader, "admin.transactions", { group = "shop_sell" })
    check(buyback.ok and buys and #buys.entries == 1 and buys.entries[1].txId == buyback.txId
        and buys.entries[1].amounts.survivor == 5, "system buybacks appear separately from shop sales")
    local market = cmd(reader, "admin.transactions", { group = "market" })
    check(trade.ok and market and #market.entries == 1 and market.entries[1].amounts.survivor == 100
        and market.entries[1].postingCount == 3, "a seller payment plus tax is one 100-coin movement, not 195 or zero")
    local auction = cmd(reader, "admin.transactions", { group = "auction" })
    check(reserve.ok and auction and #auction.entries == 1 and auction.entries[1].amounts.survivor == 50,
        "a reserve movement remains visible instead of disappearing into the zero-sum ledger")
    local detail = cmd(reader, "admin.transaction", { txId = reserve.txId })
    local posting = detail and detail.entries and detail.entries[1] and detail.entries[1].postings
    check(posting and #posting == 2 and posting[1].bucket == "available" and posting[1].amount == -50
        and posting[1].availableBefore - posting[1].availableAfter == 50
        and posting[2].bucket == "reserved" and posting[2].amount == 50
        and posting[2].reservedAfter - posting[2].reservedBefore == 50,
        "details preserve signed postings and both available/reserved before-after balances")
    local multi = cmd(reader, "admin.transactions", { currency = "cat", group = "mod" })
    check(integration.ok and multi and #multi.entries == 1 and multi.entries[1].amounts.cat == 3
        and multi.entries[1].amounts.survivor == 7,
        "a currency filter selects the whole transaction without adding or dropping other currencies")
    detail = cmd(reader, "admin.transaction", { txId = integration.txId })
    local rec = detail and detail.entries and detail.entries[1]
    check(rec and #rec.postings == 4 and rec.reasonText == "needle-reason" and rec.ref.id == "needle-ref"
        and rec.meta == nil and rec.payload == nil, "detail exposes the full postings and relevant reference, not arbitrary integration metadata")
    check(multi and multi.entries[1].postings == nil and multi.entries[1].reasonText == nil,
        "list responses carry bounded summaries rather than hundreds of full posting sets")
    local all = cmd(reader, "admin.transactions", {})
    check(all and not all.error and all.truncated and all.total == 230 and #all.entries == 200,
        "global history exposes a matching total and retains the latest 200 financial transactions")
    local query = cmd(reader, "admin.transactions", { query = "NEEDLE-REF" })
    check(query and #query.entries == 1 and query.entries[1].txId == integration.txId and not query.truncated,
        "searching old references happens before the 200-entry bound, not after unrelated newer rows")
    local rewards = cmd(reader, "admin.transactions", { group = "rewards" })
    local adjustments = cmd(reader, "admin.transactions", { group = "admin" })
    local deposits = cmd(reader, "admin.transactions", { group = "exchange" })
    check(rewards and #rewards.entries == 1 and adjustments and #adjustments.entries == 1
        and deposits and #deposits.entries == 1, "rewards, adjustments and Discord deposits share the same global ledger")
    detail = cmd(reader, "admin.transaction", { txId = adjustment.txId })
    check(detail and detail.entries[1].reasonText == fullReason,
        "a long Unicode adjustment reason is not cut in the middle of an encoded character")

    local oldEpoch = "1700000000000"
    S.modData().meta.history[#S.modData().meta.history + 1] = { epoch = oldEpoch, loadedSeq = 0 }
    local oldTs = EC.parseDay("2026-06-01", 0)
    files[X.ROOT .. "/events-20260601.json"] = { opens = 0, lines = { EC.jsonEncode({
        type = "tx.committed", txId = oldEpoch .. ":1", epoch = oldEpoch, seq = 1, ts = oldTs,
        kind = "shop_buy", requestId = "historical-purchase", reasonCode = "shop_buy",
        postings = { { account = "historical-buyer", currency = "survivor", amount = -9 },
            { account = "SYSTEM_BURN", currency = "survivor", amount = 9 } },
    }) } }
    local historical = cmd(reader, "admin.transactions", { fromMs = oldTs, toMs = oldTs + 86400000 })
    check(historical and #historical.entries == 1 and historical.entries[1].rolledBack,
        "an explicit past date range can read older files and still flags rolled-back transactions")
    local laterPath = X.ROOT .. "/events-20260602.json"
    files[laterPath] = { opens = 0, lines = {} }
    local originalReader = getFileReader
    getFileReader = function(path, create)
        if path == laterPath then return nil end
        return originalReader(path, create)
    end
    detail = cmd(reader, "admin.transaction", { txId = oldEpoch .. ":1", fromMs = oldTs, toMs = oldTs + 2 * 86400000 })
    check(detail and not detail.error and #detail.entries == 1,
        "an exact transaction lookup finishes once found and does not depend on unrelated later files")
    getFileReader = originalReader
    local deniedList = cmd(buyer, "admin.transactions", {})
    local deniedDetail = cmd(buyer, "admin.transaction", { txId = integration.txId })
    check(deniedList and deniedList.error == "forbidden" and deniedDetail and deniedDetail.error == "forbidden",
        "ordinary players cannot read either global summaries or another account's posting details")
    local invalidRange = cmd(reader, "admin.transactions", { fromMs = oldTs, toMs = oldTs + 63 * 86400000 })
    local invalidCurrency = cmd(reader, "admin.transactions", { currency = "not-registered" })
    local invalidQuery = cmd(reader, "admin.transactions", { query = string.rep("x", 129) })
    check(invalidRange and invalidRange.error == "invalid_range" and invalidCurrency and invalidCurrency.error
        and invalidQuery and invalidQuery.error == "invalid_args", "range, currency and search bounds are enforced by the server")
    local unsafeTime = cmd(reader, "admin.transactions", { fromMs = 1e24, toMs = 1e24 + 1e9 })
    check(unsafeTime and unsafeTime.error == "invalid_args",
        "timestamps beyond exact integer precision are rejected before the daily-file loop")
    local noMatch = cmd(reader, "admin.transactions", { query = ".*" })
    check(noMatch and not noMatch.error and #noMatch.entries == 0, "free text search is literal, not a Lua pattern")
    check(EC.jsonEncode(S.modData().wallets) == balancesBefore and L.conservation("survivor") == 0 and L.conservation("cat") == 0,
        "listing and expanding global transactions never changes wallets or conservation")

    -- 帳戶分類篩選（accountClass）：分類由帳戶名推導，與來源 group 正交
    check(EC.accountClass(nil) == nil and EC.accountClass("") == nil and EC.accountClass(12) == nil
        and EC.accountClass("MOD:") == "mod" and EC.accountClass("MOD") == "player"
        and EC.accountClass("EXTERNAL_DISCORD_") == "discord" and EC.accountClass("EXTERNAL_STEAM_1") == "system",
        "missing account names stay unknown and only complete reserved prefixes are classified")
    local escrow = L.post({
        kind = "other_escrow", requestId = "ledger-escrow", reasonCode = "escrow_hold", actor = "ledger-buyer",
        postings = {
            { account = "ledger-buyer", currency = "survivor", amount = -11 },
            { account = "SYSTEM_ESCROW", currency = "survivor", amount = 11 },
        },
    })
    local lookalike = L.post({
        kind = "other_lookalike", requestId = "ledger-lookalike", reasonCode = "escrow_hold", actor = "ledger-buyer",
        postings = {
            { account = "ledger-buyer", currency = "cat", amount = -4 },
            { account = "SYSTEM_MINT_extra", currency = "cat", amount = 4 },
        },
    })
    local lowercase = L.post({
        kind = "other_lowercase", requestId = "ledger-lowercase", reasonCode = "escrow_hold", actor = "ledger-buyer",
        postings = {
            { account = "ledger-buyer", currency = "survivor", amount = -2 },
            { account = "system_mint", currency = "survivor", amount = 2 },
        },
    })
    local sweep = L.post({
        kind = "other_sweep", requestId = "ledger-sweep", reasonCode = "escrow_hold",
        postings = {
            { account = "SYSTEM_MINT", currency = "survivor", amount = -6 },
            { account = "SYSTEM_BURN", currency = "survivor", amount = 6 },
        },
    })
    check(escrow.ok and lookalike.ok and lowercase.ok and sweep.ok, "the account-class fixtures commit through the normal ledger")
    for _ = 1, 20 do fire("OnTickEvenPaused") end

    local mintRows = cmd(reader, "admin.transactions", { accountClass = "mint" })
    local burnRows = cmd(reader, "admin.transactions", { accountClass = "burn" })
    check(mintRows and not mintRows.error and mintRows.total == 225 and #mintRows.entries == 200 and mintRows.truncated
        and burnRows and burnRows.total == 3 and #burnRows.entries == 3 and not burnRows.truncated
        and burnRows.entries[1].txId == purchase.txId and burnRows.entries[3].txId == sweep.txId,
        "the class filter runs before the 200-row bound: the oldest burn survives 221 newer unrelated mints")
    local adjustRows = cmd(reader, "admin.transactions", { accountClass = "adjust" })
    local discordRows = cmd(reader, "admin.transactions", { accountClass = "discord" })
    check(adjustRows and adjustRows.total == 1 and adjustRows.entries[1].txId == adjustment.txId
        and adjustRows.accountClass == "adjust"
        and discordRows and discordRows.total == 1 and discordRows.entries[1].txId == deposit.txId
        and discordRows.accountClass == "discord",
        "SYSTEM_ADJUST and EXTERNAL_DISCORD_<currency> are separate classes and each reply echoes the one asked for")
    local modRows = cmd(reader, "admin.transactions", { accountClass = "mod" })
    check(modRows and modRows.total == 1 and modRows.entries[1].txId == integration.txId
        and modRows.entries[1].postingCount == 4 and modRows.entries[1].amounts.survivor == 7
        and modRows.entries[1].amounts.cat == 3,
        "matching one account keeps the whole transaction: all four postings and both currencies stay")
    local systemRows = cmd(reader, "admin.transactions", { accountClass = "system" })
    local lookalikeMint = cmd(reader, "admin.transactions", { accountClass = "mint", query = "ledger-lookalike" })
    check(systemRows and systemRows.total == 2 and systemRows.entries[1].txId == escrow.txId
        and systemRows.entries[2].txId == lookalike.txId
        and lookalikeMint and not lookalikeMint.error and #lookalikeMint.entries == 0,
        "an unknown SYSTEM_ account is its own class and SYSTEM_MINT_extra is never folded into the faucet")
    local lowerMint = cmd(reader, "admin.transactions", { accountClass = "mint", query = "ledger-lowercase" })
    local lowerPlayer = cmd(reader, "admin.transactions", { accountClass = "player", query = "ledger-lowercase" })
    check(lowerMint and not lowerMint.error and #lowerMint.entries == 0
        and lowerPlayer and lowerPlayer.total == 1 and lowerPlayer.entries[1].txId == lowercase.txId,
        "classes are case-sensitive: a player who named himself system_mint is not the faucet")
    local narrowed = cmd(reader, "admin.transactions", { accountClass = "mint", group = "rewards", currency = "survivor" })
    local wrongCurrency = cmd(reader, "admin.transactions", { accountClass = "mint", group = "rewards", currency = "cat" })
    local wrongGroup = cmd(reader, "admin.transactions", { accountClass = "discord", group = "rewards" })
    check(narrowed and narrowed.total == 1 and narrowed.entries[1].amounts.survivor == 30
        and wrongCurrency and not wrongCurrency.error and #wrongCurrency.entries == 0
        and wrongGroup and not wrongGroup.error and #wrongGroup.entries == 0,
        "class, group and currency intersect instead of widening one another")
    local players = cmd(reader, "admin.transactions", { accountClass = "player" })
    local everything = cmd(reader, "admin.transactions", {})
    local explicitAll = cmd(reader, "admin.transactions", { accountClass = "all" })
    check(players and players.total == 233 and everything and everything.total == 234
        and everything.accountClass == "all" and explicitAll and explicitAll.total == 234
        and explicitAll.accountClass == "all",
        "the system-to-system sweep is the one row with no player account; omitting the filter still means every class")
    local badClass = cmd(reader, "admin.transactions", { accountClass = "faucet" })
    local numberClass = cmd(reader, "admin.transactions", { accountClass = 3 })
    local translatedClass = cmd(reader, "admin.transactions", { accountClass = "系統鑄幣" })
    local emptyClass = cmd(reader, "admin.transactions", { accountClass = "" })
    check(badClass and badClass.error == "invalid_args" and #badClass.entries == 0
        and numberClass and numberClass.error == "invalid_args"
        and translatedClass and translatedClass.error == "invalid_args"
        and emptyClass and emptyClass.error == "invalid_args",
        "an unknown, non-string or translated class is refused instead of quietly listing every account")
    local deniedClass = cmd(buyer, "admin.transactions", { accountClass = "mint" })
    check(deniedClass and deniedClass.error == "forbidden" and deniedClass.entries == nil,
        "the class filter sits behind the same read gate and leaks no rows to an ordinary player")
    local currentFile = files[X.eventsPath(nowMs)]
    currentFile.lines[#currentFile.lines + 1] = EC.jsonEncode({
        type = "tx.committed", txId = S.modData().meta.epoch .. ":99999", ts = nowMs, kind = "shop_buy",
        postings = { { account = "ledger-buyer", currency = "survivor", amount = "invalid" },
            { account = "SYSTEM_BURN", currency = "survivor", amount = 5 } },
    })
    local corrupt = cmd(reader, "admin.transactions", { group = "shop_buy" })
    check(corrupt and corrupt.error == "read_failed" and #corrupt.entries == 0,
        "a corrupt posting fails the read rather than showing an incomplete amount as a valid transaction")
    currentFile.lines[#currentFile.lines] = '{"type":"tx.committed","txId":'
    corrupt = cmd(reader, "admin.transactions", {})
    check(corrupt and corrupt.error == "read_failed" and #corrupt.entries == 0,
        "a truncated JSON event makes the financial read fail instead of hiding a transaction")
    currentFile.lines[#currentFile.lines] = EC.jsonEncode({
        type = "tx.committed", txId = S.modData().meta.epoch .. ":99999", ts = "invalid", kind = "shop_buy",
        postings = { { account = "ledger-buyer", currency = "survivor", amount = -5 },
            { account = "SYSTEM_BURN", currency = "survivor", amount = 5 } },
    })
    corrupt = cmd(reader, "admin.transaction", { txId = S.modData().meta.epoch .. ":99999" })
    check(corrupt and corrupt.error == "read_failed",
        "a found transaction with a broken timestamp is not reported as transaction not found")
    currentFile.lines[#currentFile.lines] = EC.jsonEncode({
        type = "tx.committed", ts = nowMs, kind = "shop_buy",
        postings = { { account = "ledger-buyer", currency = "survivor", amount = -5 },
            { account = "SYSTEM_BURN", currency = "survivor", amount = 5 } },
    })
    corrupt = cmd(reader, "admin.transaction", { txId = S.modData().meta.epoch .. ":88888" })
    check(corrupt and corrupt.error == "read_failed",
        "a transaction with missing identity cannot be silently skipped by an exact lookup")
    onlinePlayers = {}
end)()

io.write("scenario 37: accepted history and financial boundaries\n")
;(function()
    local W = S.Wallet
    modDataStore[EC.MODDATA_KEY] = nil
    files, sentCommands, writerDeny = {}, {}, {}
    nowMs = 1738281600000 -- January 31, not a thirty-day approximation of a calendar month.
    fire("OnServerStarted")
    local admin, a, b = fakePlayer("accept-admin"), fakePlayer("accept-a"), fakePlayer("accept-b")
    admin.role = "admin"
    onlinePlayers = { admin, a, b }
    local counter = 0
    local function request(player, command, args)
        nowMs, counter = nowMs + 700, counter + 1
        args = args or {}
        args.requestId = args.requestId or ("accept-record-" .. counter)
        withCurrency(command, args)
        local before = #sentCommands
        fire("OnClientCommand", EC.COMMAND_MODULE, command, player, args)
        for _ = 1, 500 do
            for i = before + 1, #sentCommands do
                local reply = sentCommands[i]
                if reply.player == player and reply.command == command then return reply.args end
            end
            fire("OnTickEvenPaused")
        end
        error("no reply: " .. command)
    end
    local months = W.recentMonths(nowMs)
    check(months[1] == "202412" and months[2] == "202501", "recent means previous calendar month even on January 31")
    local alpha = L.credit("accept-a", "survivor", 20, "SYSTEM_MINT", { requestId = "alpha-receipt", reasonCode = "t", kind = "mod", payload = { item = "Base.Bandage", qty = 2 } })
    check(alpha.ok and files[X.receiptsPath("accept-a", nowMs)] == nil, "the first receipt can still be queued when its owner queries")
    local history = request(a, "wallet.history", { month = "recent", requestId = "first-receipt" })
    check(history.requestId == "first-receipt" and history.error == nil and #history.entries == 1 and history.entries[1].txId == alpha.txId,
        "first-file history crosses the write fence and echoes its request identity")
    local state = request(a, "wallet.state", { requestId = "wallet-snapshot" })
    local receipt = state.receipts[#state.receipts]
    check(state.requestId == "wallet-snapshot" and receipt.item == "Base.Bandage" and receipt.qty == 2 and receipt.txId == alpha.txId,
        "wallet snapshot preserves the receipt's usable detail and correlation id")
    local beta = L.credit("accept-b", "survivor", 7, "SYSTEM_MINT", { requestId = "beta-receipt", reasonCode = "t", kind = "mod", actor = "accept-a", reasonText = "mention accept-a", payload = { item = "Base.Axe" } })
    local exact = request(admin, "admin.transactions", { account = "accept-a" })
    check(exact.total == 1 and exact.entries[1].txId == alpha.txId and #exact.entries[1].accounts == 2,
        "exact account checks all postings, not an actor or a name mentioned in a reason")
    check(request(admin, "admin.transactions", { account = "ACCEPT-A" }).total == 0,
        "account identity is case-sensitive")
    local fuzzy = request(admin, "admin.transactions", { query = "accept-a" })
    local prefix = request(admin, "admin.transactions", { query = "accept-", matchMode = "exact" })
    check(fuzzy.total == 2 and prefix.total == 0, "contains and exact keywords have different field-wise semantics")
    local types = request(admin, "admin.transactions", { query = "alpha-receipt", itemTypes = { "Base.Axe" } })
    check(types.total == 2, "resolved item types are ORed with the keyword before the result ring")
    check(request(admin, "admin.transactions", { item = "Base.Bandage", itemTypes = { "Base.Axe" } }).total == 0,
        "the explicitly selected fullType remains an independent exact condition")
    local refused = request(admin, "admin.transactions", { account = "accept-a", item = "Base.Axe", matchMode = "exact", currency = "not-a-currency" })
    check(refused.error == "invalid_args" and refused.account == "accept-a" and refused.item == "Base.Axe" and refused.matchMode == "exact",
        "a rejected criterion does not erase the other criteria from the reply")
    local wide = {}
    for i = 1, 257 do wide[i] = "Base.Type" .. i end
    check(request(admin, "admin.transactions", { itemTypes = wide }).error == "invalid_args"
        and request(admin, "admin.transactions", { itemTypes = { [1] = "Base.Axe", [3] = "Base.Bandage" } }).error == "invalid_args",
        "oversized and sparse resolved type sets cannot silently narrow a financial query")
    local forbidden = request(a, "admin.players", { context = "transactions", requestId = "revoked-reader" })
    check(forbidden.error == "forbidden" and forbidden.context == "transactions" and forbidden.requestId == "revoked-reader",
        "revoked access replies still identify the picker that owns the pending command")
    local reason = string.rep("full audit reason ", 20)
    X.audit({ action = "freeze", admin = "accept-admin", target = "accept-a", reason = reason })
    local ring = X.auditEntries(1)[1]
    check(ring.full == false and ring.source == "ring" and ring.reasonTruncated and #ring.reason < #reason,
        "the bounded audit copy never claims to be the original full reason")
    local detail = request(admin, "admin.auditDetail", { key = ring.key, month = ring.month })
    check(detail.error == nil and #detail.entries == 1 and detail.entries[1].reason == reason and detail.entries[1].full,
        "a ring row can retrieve its entire file record after the write fence")
    local missing = request(admin, "admin.auditDetail", { key = "no-such-audit", month = "199001" })
    check(missing.error == "missing" and #missing.entries == 0, "a missing audit file is explicit, not a claimed full record")
    local path = X.auditPath(nowMs)
    local legacy = { type = "audit", epoch = S.modData().meta.epoch, seq = 123, ts = nowMs, action = "freeze", admin = "legacy", target = "target", reason = "first" }
    local key = X.auditKey(legacy)
    files[path].lines[#files[path].lines + 1] = EC.jsonEncode(legacy)
    legacy.reason = "different"
    files[path].lines[#files[path].lines + 1] = EC.jsonEncode(legacy)
    local ambiguous = request(admin, "admin.auditDetail", { key = key, month = EC.monthKey(nowMs) })
    check(ambiguous.error == "ambiguous_record" and #ambiguous.entries == 2,
        "a legacy locator matching different records never guesses the first one")
    files[path].lines[#files[path].lines + 1] = "{broken"
    local corrupt = request(admin, "admin.auditFile", {})
    check(corrupt.error == "read_failed" and #corrupt.entries == 0, "a broken audit line invalidates the list instead of silently dropping an operation")
    files[path].lines[#files[path].lines] = nil
    local public, own, other = false, false, false
    sentCommands = {}
    X.changed("market")
    X.changed("wallet", "accept-a")
    X.changed("transactions")
    fire("OnTickEvenPaused")
    for _, reply in ipairs(sentCommands) do
        if reply.command == "views.changed" then
            local scopes = {}
            for _, scope in ipairs(reply.args.scopes) do scopes[scope] = true end
            if reply.player == admin then public = scopes.market and scopes.transactions end
            if reply.player == a then own = scopes.market and scopes.wallet and not scopes.transactions end
            if reply.player == b then other = scopes.market and not scopes.wallet and not scopes.transactions end
        end
    end
    check(public and own and other, "view invalidations expose only public, owner and authorized admin scope names")
    onlinePlayers = {}
end)()

io.write("scenario 38: bounded write fences and strict Unicode\n")
;(function()
    modDataStore[EC.MODDATA_KEY] = nil
    files, sentCommands, writerDeny = {}, {}, {}
    nowMs = nowMs + 61000
    fire("OnServerStarted")
    local eventPath, receiptPath = "MinidoracatEconomy/fence-events.json", "MinidoracatEconomy/fence-receipt.json"
    for i = 1, 120 do X.enqueue(eventPath, tostring(i)) end
    X.enqueue(receiptPath, "own write")
    local fence = X.readFence({ receiptPath })
    X.flush(50)
    local firstReady = X.fenceStatus(fence)
    X.enqueue(eventPath, "later event")
    X.flush(50)
    check(not firstReady and X.fenceStatus(fence) and files[receiptPath].lines[1] == "own write",
        "continuous event traffic cannot starve a queued receipt behind the per-tick write budget")
    local fixedPath = "MinidoracatEconomy/fixed-fence.json"
    X.enqueue(fixedPath, "before query")
    local fixed = X.readFence({ fixedPath })
    for i = 1, 90 do X.enqueue(fixedPath, "after query " .. i) end
    for _ = 1, 6 do X.flush(1) end
    check(X.fenceStatus(fixed) and X.queuedLines() > 0, "later arrivals do not extend an existing query's write fence")
    local deniedPath = "MinidoracatEconomy/denied-fence.json"
    writerDeny[deniedPath] = true
    X.enqueue(deniedPath, "must not disappear as success")
    local denied = X.readFence({ deniedPath })
    for _ = 1, 8 do X.flush() end
    local ready, err = X.fenceStatus(denied)
    check(not ready and err == "read_failed", "a dropped export path fails its waiting read explicitly")
    local oldMax = X.MAX_QUEUE_LINES
    X.MAX_QUEUE_LINES = 2
    local lost = "MinidoracatEconomy/overflow-fence.json"
    X.enqueue(lost, "old")
    local overflow = X.readFence({ lost })
    X.enqueue("MinidoracatEconomy/another-a.json", "a")
    X.enqueue("MinidoracatEconomy/another-b.json", "b")
    X.enqueue("MinidoracatEconomy/another-c.json", "c")
    local overflowReady, overflowError = X.fenceStatus(overflow)
    check(X.queuedLines() <= 2 and not overflowReady and overflowError == "read_failed",
        "overflow keeps the queue bounded even when a one-line path becomes empty")
    X.MAX_QUEUE_LINES = oldMax
    local json = EC.jsonDecode([[{"\u4e2d":"A\u2019s \uD840\uDC00"}]])
    check(json and json[utf8.char(20013)] == "A" .. utf8.char(8217) .. "s " .. utf8.char(131072),
        "JSON names preserve BMP, astral characters and escaped object keys")
    local valid = true
    for _, raw in ipairs({ [["\q"]], [["\u+001"]], [["\uD840"]], [["\uDC00"]], [["\uD840\u0041"]] }) do
        if EC.jsonDecode(raw) ~= nil then valid = false end
    end
    check(valid, "invalid escape and surrogate sequences never become successful substituted names")
end)()
io.write("scenario 39: quotas, consent and bounded batch attempts\n")
;(function()
    local M, Shop, Mk = S.Mailbox, S.Shop, S.Market
    modDataStore[EC.MODDATA_KEY] = nil
    files, writerDeny, sentCommands = {}, {}, {}
    files[Shop.FILE] = { lines = { EC.jsonEncode({ items = {
        { id = "small", item = "Base.Bandage", qty = 2, price = 10, dailyCap = 5, bidPrice = 1 },
        { id = "heavy", item = "Base.Plank", qty = 3, price = 30, dailyCap = 0, bidPrice = 1 },
        { id = "tools", item = "Base.Axe", qty = 1, price = 40, dailyCap = 0, bidPrice = 1 },
    } }) }, opens = 0 }
    nowMs = nowMs + 61000
    fire("OnServerStarted")
    local admin, a, b = fakePlayer("quota-admin"), fakePlayer("quota-a"), fakePlayer("quota-b")
    admin.role = "admin"
    a.x, b.x = 101, 101
    a.inventory, b.inventory = fakeInventory(100), fakeInventory(100)
    onlinePlayers = { admin, a, b }
    worldSprites = { ["100,200,0"] = "MinidoracatEconomy_terminal_0" }
    local counter = 0
    local function request(player, command, args)
        nowMs, counter = nowMs + 700, counter + 1
        args = args or {}
        args.requestId = args.requestId or ("accept-commerce-" .. counter)
        withCurrency(command, args)
        local before = #sentCommands
        fire("OnClientCommand", EC.COMMAND_MODULE, command, player, args)
        for i = before + 1, #sentCommands do
            local reply = sentCommands[i]
            if reply.player == player and reply.command == command then return reply.args end
        end
        error("no synchronous reply: " .. command)
    end
    request(admin, "terminal.register", { x = 100, y = 200, z = 0 })
    L.credit("quota-a", "survivor", 10000, "SYSTEM_MINT", { requestId = "qa-seed", reasonCode = "t" })
    L.credit("quota-b", "survivor", 10000, "SYSTEM_MINT", { requestId = "qb-seed", reasonCode = "t" })
    local before, rev = L.getBalance("quota-a", "survivor").available, Shop.revision()
    a.inventory.maxWeight = 0
    local refused = request(a, "shop.buy", { id = "heavy", revision = rev, requestId = "consent-intent" })
    check(refused.error == "mail_confirmation_required" and L.getBalance("quota-a", "survivor").available == before and M.unclaimed("quota-a") == 0,
        "no capacity consent means no debit and no new mailbox obligation")
    local parked = request(a, "shop.buy", { id = "heavy", revision = rev, requestId = "consent-intent", acceptMail = true })
    local duplicate = request(a, "shop.buy", { id = "heavy", revision = rev, requestId = "consent-intent", acceptMail = true })
    check(parked.ok and parked.mailed and duplicate.duplicate and L.getBalance("quota-a", "survivor").available == before - 30 and M.unclaimed("quota-a") == 1,
        "explicit consent reuses the refused intent and successful replay never charges twice")
    a.inventory.maxWeight = 100
    check(request(a, "mail.claim", { mailId = parked.mailId }).ok and a.inventory.count("Base.Plank") == 3,
        "a parked purchase is later delivered as one complete envelope")
    request(a, "shop.buy", { id = "small", count = 2, revision = rev })
    request(b, "shop.buy", { id = "small", count = 1, revision = rev })
    local scoped = request(admin, "admin.catalog", { action = "batch", ids = { "small" }, fields = { dailyCapScope = "global" }, revision = rev })
    check(scoped.ok and Shop.used("quota-a", "small", nowMs) == 3 and Shop.used("quota-b", "small", nowMs) == 3,
        "switching to a global cap includes purchases made while the SKU was per-player")
    local final = request(b, "shop.buy", { id = "small", count = 2, revision = Shop.revision() })
    local capped = request(a, "shop.buy", { id = "small", revision = Shop.revision() })
    check(final.ok and final.remaining == 0 and capped.error == "daily_cap" and a.inventory.count("Base.Bandage") == 4 and b.inventory.count("Base.Bandage") == 6,
        "five shares of two items means ten items across the whole server, not five items")
    local delta
    for _, reply in ipairs(sentCommands) do
        if reply.player == a and reply.command == "shop.stock" then delta = reply.args end
    end
    check(delta and delta.id == "small" and delta.remaining == 0 and delta.used == 5 and delta.revision == Shop.revision(),
        "other buyers receive the shared row's remaining and used shares without a whole-catalog refresh")
    local switched = request(admin, "admin.catalog", { action = "batch", ids = { "small" }, fields = { dailyCapScope = "player" }, revision = Shop.revision() })
    check(switched.ok and Shop.used("quota-a", "small", nowMs) == 2 and Shop.used("quota-b", "small", nowMs) == 3,
        "switching back to per-player limits preserves both players' own usage")
    request(admin, "admin.catalog", { action = "batch", ids = { "small" }, fields = { dailyCapScope = "global" }, revision = Shop.revision() })
    nowMs = nowMs + 1000
    fire("OnServerStarted")
    check(Shop.used("quota-a", "small", nowMs) == 5, "restart rebuilds the volatile total from the persisted per-player day rows")
    nowMs = nowMs + 86400000
    check(Shop.used("quota-a", "small", nowMs) == 0, "the next reward day starts a fresh shared quota")
    local first = request(a, "shop.buy", { id = "small", revision = Shop.revision() })
    check(first.ok and first.remaining == 4 and Shop.used("quota-b", "small", nowMs) == 1,
        "the first purchase after building a new-day total is not counted twice")
    local text = table.concat(files[Shop.FILE].lines, "\n")
    local bad = request(admin, "admin.catalog", { action = "batch", ids = { "small", "tools" }, fields = { prices = { survivor = { price = 1 } } }, revision = Shop.revision() })
    check(not bad.ok and bad.error == "invalid_args" and table.concat(files[Shop.FILE].lines, "\n") == text and Shop.sku("small").prices.survivor.price == 10,
        "one invalid final SKU rejects every row of the batch without writing")
    local noOpRevision = Shop.revision()
    local noOp = request(admin, "admin.catalog", { action = "batch", ids = { "small" }, fields = { prices = { survivor = { price = 10 } } }, revision = "outdated" })
    check(noOp.error == "catalog_stale", "a no-op cannot bypass the editor's revision guard")
    files[Shop.FILE].lines[#files[Shop.FILE].lines] = files[Shop.FILE].lines[#files[Shop.FILE].lines] .. " "
    local diskNoOp = request(admin, "admin.catalog", { action = "batch", ids = { "small" }, fields = { prices = { survivor = { price = 10 } } }, revision = noOpRevision })
    check(diskNoOp.error == "catalog_stale", "a no-op also detects an out-of-band file edit")
    request(admin, "admin.catalog", { action = "reload" })
    local openCount = files[Shop.FILE].opens
    local changed = request(admin, "admin.catalog", { action = "batch", ids = { "small", "tools" }, fields = { prices = { survivor = { price = 20 } } }, revision = Shop.revision() })
    check(changed.ok and files[Shop.FILE].opens == openCount + 1 and Shop.sku("small").prices.survivor.price == 20 and Shop.sku("tools").prices.survivor.price == 20
        and Shop.sku("small").qty == 2 and Shop.sku("tools").qty == 1,
        "a valid batch writes once and does not copy unselected fields from one SKU into another")
    local large = {}
    for i = 1, 3 do large[i] = M.add("quota-a", { item = "Base.Nails", qty = 100, kind = "shop" }).id end
    a.inventory = fakeInventory(0)
    local realCreate, created = instanceItem, 0
    instanceItem = function(fullType) created = created + 1; return realCreate(fullType) end
    local batch = request(a, "mail.claimAll", { mailIds = large })
    instanceItem = realCreate
    check(batch.more and #batch.results == 2 and created == 200 and batch.results[1].error == "backpack_full" and batch.results[2].error == "backpack_full",
        "failed capacity checks still consume the two-hundred-item construction budget")
    local small = M.add("quota-b", { item = "Base.Bandage", qty = 1, kind = "shop" })
    local heavy = M.add("quota-b", { item = "Base.Plank", qty = 3, kind = "shop" })
    b.inventory = fakeInventory(1)
    local mixed = request(b, "mail.claimAll", { mailIds = { heavy.id, small.id } })
    check(mixed.results[1].error == "backpack_full" and mixed.results[2].ok and b.inventory.count("Base.Bandage") == 1,
        "a heavy envelope stays parked while a later lighter envelope is still claimed")
    local broken = M.add("quota-b", { item = "Base.Axe", qty = 1, kind = "shop" })
    local nextGood = M.add("quota-b", { item = "Base.Bandage", qty = 1, kind = "shop" })
    instanceItem = function(fullType) if fullType == "Base.Axe" then error("constructor failed") end; return realCreate(fullType) end
    local fault = request(b, "mail.claimAll", { mailIds = { broken.id, nextGood.id } })
    instanceItem = realCreate
    check(fault.results[1].error == "item_unavailable" and fault.results[2].ok and b.inventory.count("Base.Bandage") == 2,
        "a constructor exception produces its own result and does not discard or stop the rest of the batch")
    onlinePlayers = {}
end)()
io.write("scenario ES-1: a hand-over is what the container says it is\n")
;(function()
local M, Shop = S.Mailbox, S.Shop
local realInstance, realPacket = instanceItem, sendAddItemsToContainer
modDataStore[EC.MODDATA_KEY] = nil
files = {}
sentCommands = {}
sentItemPackets = {}
worldSprites = { ["100,200,0"] = "MinidoracatEconomy_terminal_0" }
nowMs = nowMs + 61000
fire("OnServerStarted")
local boss = fakePlayer("boss"); boss.role = "admin"
local zed = fakePlayer("zed"); zed.x = 101; zed.inventory = fakeInventory(500)
onlinePlayers = { boss, zed }
local function cmd(who, name, args)
    nowMs = nowMs + 600
    args = args or {}
    args.requestId = args.requestId or (name .. nowMs)
    withCurrency(name, args)
    fire("OnClientCommand", EC.COMMAND_MODULE, name, who, args)
    local s = lastSent(name)
    return s and s.args or {}
end
local function rowOf(list, id)
    for _, e in ipairs(list or {}) do if e.id == id then return e end end
    return nil
end
local function stampOf(item)
    return item:getModData()[EC.PLAYER_MODDATA_KEY]
end
local function witnessOf(id)
    local p = zed.modData[EC.PLAYER_MODDATA_KEY]
    return p and p.claims and p.claims[id] or nil
end
local function bandages()
    return zed.inventory.count("Base.Bandage")
end
local realAdd, realRemove = zed.inventory.AddItem, zed.inventory.Remove
cmd(boss, "terminal.register", { x = 100, y = 200, z = 0, kind = "atm" })

-- ---- 1. a throw after AddItem already took an item: everything of that attempt comes back ----
local one = M.add("zed", { kind = "shop", item = "Base.Bandage", qty = 3 }).id
local base = bandages()
local addCount = 0
zed.inventory.AddItem = function(self, it)
    addCount = addCount + 1
    realAdd(self, it)                                   -- mutate first, then throw
    if addCount == 2 then error("engine blew up mid-letter") end
    return it
end
local failed = cmd(zed, "mail.claim", { mailId = one })
zed.inventory.AddItem = realAdd
check(failed.ok == false and failed.error == "delivery_failed" and failed.deliveredQty == 0
    and failed.remainingQty == 3 and bandages() == base and M.unclaimed("zed") == 1
    and rowOf(M.list("zed"), one).qty == 3 and rowOf(M.list("zed"), one).claimable == true,
    "a throw after AddItem mutated an item takes every object of the attempt back: nothing delivered, the whole letter still ready")
check(witnessOf(one) == nil, "a letter that delivered nothing writes no claim witness")

-- ---- 2. AddItem that hands back another object is a failure, not a delivery ----
zed.inventory.AddItem = function(self, it) realAdd(self, it) return realInstance("Base.Bandage") end
local swapped = cmd(zed, "mail.claim", { mailId = one })
zed.inventory.AddItem = realAdd
check(swapped.ok == false and swapped.error == "delivery_failed" and swapped.deliveredQty == 0
    and bandages() == base and rowOf(M.list("zed"), one).qty == 3,
    "AddItem returning an object other than the one it was given is not trusted as an add")

-- ---- 3. a Remove that silently does nothing is not a Remove: everything is still there ----
zed.inventory.Remove = function() end                   -- no throw, no effect
sendAddItemsToContainer = function() error("packet blew up after every item landed") end
local allKept = cmd(zed, "mail.claim", { mailId = one })
zed.inventory.Remove, sendAddItemsToContainer = realRemove, realPacket
check(allKept.ok == true and allKept.deliveredQty == 3 and allKept.remainingQty == 0
    and bandages() == base + 3 and M.unclaimed("zed") == 0 and rowOf(M.list("zed"), one) == nil,
    "when the identity re-read finds every object of the attempt in the backpack the letter is a plain claimed one, whatever the calls answered")
check(witnessOf(one) ~= nil and stampOf(zed.inventory.items[#zed.inventory.items]).mailId == one,
    "the kept letter is witnessed and stamped exactly like a clean hand-over")
check(cmd(zed, "mail.claim", { mailId = one }).error == "already_claimed" and bandages() == base + 3,
    "a letter settled that way is never handed over a second time")

-- ---- 4. a take-back that only partly works: the confirmed subset becomes its own letter ----
local two = M.add("zed", { kind = "market", item = "Base.Bandage", qty = 3, txId = "tx-split" }).id
local base2 = bandages()
local removeCount = 0
zed.inventory.Remove = function(self, it)
    removeCount = removeCount + 1
    if removeCount == 1 then error("cannot take that one back") end
    realRemove(self, it)
end
sendAddItemsToContainer = function() error("packet blew up after every item landed") end
local part = cmd(zed, "mail.claim", { mailId = two })
zed.inventory.Remove, sendAddItemsToContainer = realRemove, realPacket
local child = part.childMailId
check(part.ok == false and part.error == "delivery_partial" and part.deliveredQty == 1
    and part.remainingQty == 2 and type(child) == "string" and child ~= two
    and bandages() == base2 + 1,
    "one object that could not be taken back is one delivered item, and the reply says how many of each")
check(rowOf(M.list("zed"), two).qty == 2 and rowOf(M.list("zed"), two).claimable == true
    and rowOf(M.list("zed"), child) == nil and M.unclaimed("zed") == 1,
    "the parent keeps the remainder and stays claimable; the claimed child holds no slot of its own")
local keptItem = zed.inventory.items[#zed.inventory.items]
check(stampOf(keptItem).mailId == child and stampOf(keptItem).txId == "tx-split"
    and witnessOf(child) ~= nil and witnessOf(child).seq == stampOf(keptItem).seq and witnessOf(two) == nil,
    "the delivered subset is re-stamped onto the child, witnessed under the same claim seq, and the parent gets no witness of its own")

-- ---- 5. the delivered subset moved into a carried bag, then a login: nothing changes ----
local bagInv = fakeInventory(500)
local bag = { fullType = "Base.Bag_ALICEpack", id = -991, modData = {} }
bag.getModData = function() return bag.modData end
bag.getUnequippedWeight = function() return 1 end
bag.getActualWeight = function() return 1 end
bag.getFullType = function() return bag.fullType end
bag.getInventory = function() return bagInv end
realRemove(zed.inventory, keptItem)
bagInv:AddItem(keptItem)
realAdd(zed.inventory, bag)
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "hello", zed, {})
check(rowOf(M.list("zed"), two).qty == 2 and M.unclaimed("zed") == 1 and bagInv.count("Base.Bandage") == 1
    and witnessOf(child) ~= nil and bandages() == base2,
    "a login after a split leaves both halves exactly where they are, wherever the delivered items are carried")

-- ---- 6. death after a split: the child settles, the remainder of the letter survives ----
fire("OnCharacterDeath", zed)
check(rowOf(M.list("zed"), two).qty == 2 and rowOf(M.list("zed"), two).claimable == true
    and M.unclaimed("zed") == 1,
    "death settles the claimed child and never swallows the remainder of the letter it came from")
zed.inventory = fakeInventory(500)
zed.modData[EC.PLAYER_MODDATA_KEY] = nil
realAdd, realRemove = zed.inventory.AddItem, zed.inventory.Remove
local heir = cmd(zed, "mail.claim", { mailId = two })
check(heir.ok == true and heir.deliveredQty == 2 and heir.remainingQty == 0
    and bandages() == 2 and M.unclaimed("zed") == 0,
    "the remainder of a split letter is handed over whole, exactly once, to the next character")

-- ---- 7. the world comes back from a save older than the claim ----
local three = M.add("zed", { kind = "shop", item = "Base.Bandage", qty = 2, txId = "tx-roll" }).id
local seqBeforeRoll = S.modData().meta.seq
check(cmd(zed, "mail.claim", { mailId = three }).ok == true and bandages() == 4,
    "a clean claim first: two more bandages and one more witness")
local held = S.modData().mailbox.byOwner["zed"]
held.entries[three].state = "ready"                     -- the older world save has it unclaimed
held.entries[three].claimedAt = nil
held.entries[three].claimSeq = nil
held.unclaimed = 1
S.modData().mailbox.unclaimed = 1
S.modData().meta.seq = seqBeforeRoll                    -- the claim's seq never reached that save
nowMs = nowMs + 1000
fire("OnServerStarted")
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "hello", zed, {})
check(rowOf(M.list("zed"), three) == nil and M.unclaimed("zed") == 0 and bandages() == 4,
    "a player save newer than the world save is marked claimed from its witness, never handed over again")

-- ---- 8. a player save older than the claim, then a rollback below the purchase itself ----
local four = M.add("zed", { kind = "shop", item = "Base.Bandage", qty = 2, txId = "tx-older" }).id
check(cmd(zed, "mail.claim", { mailId = four }).ok == true and bandages() == 6,
    "the fourth letter is claimed cleanly")
-- the older player save saw neither this claim's witness nor its items (every other claimed
-- letter of this account keeps its own witness, so only this one looks older than the world)
zed.modData[EC.PLAYER_MODDATA_KEY].claims[four] = nil
for i = #zed.inventory.items, 1, -1 do
    local st = stampOf(zed.inventory.items[i])
    if st and st.mailId == four then realRemove(zed.inventory, zed.inventory.items[i]) end
end
check(bandages() == 4, "the two items of that claim are gone from the older save")
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "hello", zed, {})
check(bandages() == 6 and witnessOf(four) ~= nil and rowOf(M.list("zed"), four) == nil,
    "a player save older than the claim gets that letter handed over again, once, and is witnessed for it")
local orphanSeq = witnessOf(four).seq
local orphanEpoch = S.modData().meta.epoch
S.modData().mailbox.byOwner["zed"].entries[four] = nil  -- the world rolled back below the purchase
S.modData().meta.seq = orphanSeq - 1
nowMs = nowMs + 1000
fire("OnServerStarted")
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "hello", zed, {})
check(S.isRolledBack(orphanEpoch, orphanSeq) == true and bandages() == 4 and witnessOf(four) == nil,
    "items stamped by a claim the world rolled back below are taken back and their witness is dropped")

-- ---- 9. nothing is paid for on a weight, or a room answer, this server cannot read ----
local rev = Shop.revision()
L.credit("zed", "survivor", 500, "SYSTEM_MINT", { requestId = "es-zed", reasonCode = "t" })
local purse = L.getBalance("zed", "survivor").available
instanceItem = function(fullType)
    local it = realInstance(fullType)
    if it and fullType == "Base.Bandage" then
        it.getUnequippedWeight = function() error("no weight") end
        it.getActualWeight = function() return 0 / 0 end
    end
    return it
end
local noWeight = cmd(zed, "shop.buy", { id = "bandage", count = 1, revision = rev })
instanceItem = realInstance
check(noWeight.ok == false and noWeight.error == "item_unavailable"
    and L.getBalance("zed", "survivor").available == purse and M.unclaimed("zed") == 0,
    "an object whose weight is NaN or unreadable is refused before the debit, never weighed as zero")
local realRoom = zed.inventory.hasRoomFor
zed.inventory.hasRoomFor = function() error("the container has no answer") end
local noRoom = cmd(zed, "shop.buy", { id = "bandage", count = 1, revision = rev, acceptMail = true })
zed.inventory.hasRoomFor = realRoom
check(noRoom.ok == false and noRoom.error == "item_unavailable"
    and L.getBalance("zed", "survivor").available == purse and M.unclaimed("zed") == 0,
    "a room test the container refuses to answer is refused before the debit too, with no letter written")

-- ---- 10. a batch walks past a split and keeps its fixed ids ----
zed.inventory = fakeInventory(500)                      -- a clean backpack: the counts below are absolute
realAdd, realRemove = zed.inventory.AddItem, zed.inventory.Remove
local a1 = M.add("zed", { kind = "shop", item = "Base.Bandage", qty = 2 }).id
local a2 = M.add("zed", { kind = "shop", item = "Base.Bandage", qty = 2 }).id
local a3 = M.add("zed", { kind = "shop", item = "Base.Bandage", qty = 1 }).id
local touched, splitOnce = 0, false
zed.inventory.Remove = function(self, it)
    touched = touched + 1
    if touched == 1 then error("cannot take that one back") end
    realRemove(self, it)
end
sendAddItemsToContainer = function(container, list)
    if not splitOnce then splitOnce = true error("packet blew up on the first letter") end
    realPacket(container, list)
end
local batch = cmd(zed, "mail.claimAll", { mailIds = { a1, a2, a3 } })
zed.inventory.Remove, sendAddItemsToContainer = realRemove, realPacket
local byId = {}
for _, r in ipairs(batch.results or {}) do byId[r.mailId] = r end
check(batch.ok == true and #batch.results == 3 and batch.more == false
    and byId[a1].error == "delivery_partial" and byId[a1].deliveredQty == 1 and byId[a1].remainingQty == 1
    and byId[a2].ok == true and byId[a3].ok == true,
    "a letter that ends in the partial exception does not stop the batch: the other fixed ids are still claimed")
check(rowOf(M.list("zed"), a1).qty == 1 and rowOf(M.list("zed"), a2) == nil and rowOf(M.list("zed"), a3) == nil
    and M.unclaimed("zed") == 1 and bandages() == 4,
    "the split letter keeps its remainder, the whole ones are gone, and no item was handed over twice")
local again = cmd(zed, "mail.claimAll", { mailIds = { a1, a2, a3 } })
local byId2 = {}
for _, r in ipairs(again.results or {}) do byId2[r.mailId] = r end
check(byId2[a1].ok == true and byId2[a1].deliveredQty == 1 and byId2[a2].error == "already_claimed"
    and byId2[a3].error == "already_claimed" and bandages() == 5 and M.unclaimed("zed") == 0,
    "resending the same fixed ids hands over only what is still in the letter - never the settled subset again - and answers already_claimed for the rest")
onlinePlayers = {}
instanceItem, sendAddItemsToContainer = realInstance, realPacket
end)()
io.write("scenario 41: partial claims across independent saves\n")
;(function()
    local M = S.Mailbox
    local function copy(value)
        if type(value) ~= "table" then return value end
        local out = {}
        for key, child in pairs(value) do out[key] = copy(child) end
        return out
    end
    for _, rollback in ipairs({ "world-before-claim", "player-before-claim", "world-before-mail" }) do
        modDataStore[EC.MODDATA_KEY] = nil
        files, writerDeny, sentCommands = {}, {}, {}
        nowMs = nowMs + 61000
        fire("OnServerStarted")
        local p = fakePlayer("partial-save")
        p.inventory = fakeInventory(100)
        onlinePlayers = { p }
        local beforeMail = copy(S.modData())
        local parent = M.add(p:getUsername(), { item = "Base.Bandage", qty = 3, kind = "shop" })
        local beforeClaim = copy(S.modData())
        local beforePlayer = copy(p.modData)
        local realAdd, realRemove = p.inventory.AddItem, p.inventory.Remove
        local adds, removes = 0, 0
        p.inventory.AddItem = function(inv, item)
            adds = adds + 1
            realAdd(inv, item)
            if adds == 2 then error("second add changed the inventory before throwing") end
            return item
        end
        p.inventory.Remove = function(inv, item)
            removes = removes + 1
            if removes == 1 then error("first item could not be removed") end
            realRemove(inv, item)
        end
        local result = M.claim(p, parent.id)
        p.inventory.AddItem, p.inventory.Remove = realAdd, realRemove
        check(result.error == "delivery_partial" and result.deliveredQty == 1 and parent.qty == 2 and p.inventory.count("Base.Bandage") == 1,
            "partial setup: only the confirmed item is settled before " .. rollback)
        if rollback == "player-before-claim" then
            p.inventory, p.modData = fakeInventory(100), beforePlayer
        else
            modDataStore[EC.MODDATA_KEY] = rollback == "world-before-claim" and beforeClaim or beforeMail
            nowMs = nowMs + 1000
            fire("OnServerStarted")
        end
        M.reconcile(p)
        if rollback == "world-before-mail" then
            check(p.inventory.count("Base.Bandage") == 0 and M.unclaimed(p:getUsername()) == 0,
                "a partial child below the purchase rollback is reclaimed without inventing another mailbox obligation")
        else
            local remaining = M.list(p:getUsername())[1]
            local claim = remaining and M.claim(p, remaining.id)
            check(claim and claim.ok and p.inventory.count("Base.Bandage") == 3 and M.unclaimed(p:getUsername()) == 0,
                "the two halves converge to exactly three items after " .. rollback)
        end
    end
    modDataStore[EC.MODDATA_KEY] = nil
    files, writerDeny, sentCommands = {}, {}, {}
    nowMs = nowMs + 61000
    fire("OnServerStarted")
    local p = fakePlayer("identity-collision")
    p.inventory = fakeInventory(100)
    local existing = instanceItem("Base.Bandage")
    p.inventory:AddItem(existing)
    local mail = M.add(p:getUsername(), { item = "Base.Bandage", qty = 1, kind = "shop" })
    local realInstance = instanceItem
    instanceItem = function(fullType)
        local item = realInstance(fullType)
        item.id = existing.id
        return item
    end
    local rejected = M.claim(p, mail.id)
    instanceItem = realInstance
    check(rejected.error == "delivery_failed" and p.inventory.count("Base.Bandage") == 1
        and p.inventory.items[1] == existing and existing:getModData()[EC.PLAYER_MODDATA_KEY] == nil and mail.state == "ready",
        "an AddItem id collision never destroys or stamps the older legitimate object")
    local realAdd, realRemove = p.inventory.AddItem, p.inventory.Remove
    p.inventory.AddItem = function(inv, item) realAdd(inv, item); error("add hook failed after mutation") end
    p.inventory.Remove = function(inv, item) realRemove(inv, item); error("remove hook failed after mutation") end
    local removed = M.claim(p, mail.id)
    p.inventory.AddItem, p.inventory.Remove = realAdd, realRemove
    check(removed.error == "delivery_failed" and removed.deliveredQty == 0 and mail.state == "ready" and p.inventory.count("Base.Bandage") == 1,
        "a throwing Remove that really removed the new object is not mistaken for a partial delivery")
    onlinePlayers = {}
end)()
io.write("scenario 42: provenance across escrow and independent saves\n")
;(function()
    local M, Mk, Au, Shop = S.Mailbox, S.Market, S.Auction, S.Shop
    local KEY = EC.PLAYER_MODDATA_KEY
    local serial = 0
    local function copy(v)
        if type(v) ~= "table" then return v end
        local out = {}
        for k, value in pairs(v) do out[k] = copy(value) end
        return out
    end
    local function cmd(p, name, args)
        serial, nowMs = serial + 1, nowMs + 700
        args = args or {}
        args.requestId = args.requestId or ("provenance-" .. serial)
        withCurrency(name, args)
        local first = #sentCommands + 1
        fire("OnClientCommand", EC.COMMAND_MODULE, name, p, args)
        for i = first, #sentCommands do
            local reply = sentCommands[i]
            if reply.player == p and reply.command == name then return reply.args end
        end
        error("missing reply: " .. name)
    end
    local function fresh()
        modDataStore[EC.MODDATA_KEY] = nil
        files, writerDeny, sentCommands, sentItemPackets = {}, {}, {}, {}
        worldSprites = { ["100,200,0"] = "MinidoracatEconomy_terminal_0" }
        SandboxVars.MinidoracatEconomy.MarketMaxListings = 5
        SandboxVars.MinidoracatEconomy.ShopBuybackEnabled = true
        SandboxVars.MinidoracatEconomy.ShopBuybackPerAccountDaily = 10000
        SandboxVars.MinidoracatEconomy.ShopBuybackServerDaily = 100000
        files[Shop.FILE] = { lines = { EC.jsonEncode({ items = {
            { id = "corn", item = "Base.CannedCorn", qty = 1, price = 20, dailyCap = 0,
                buyback = true, bidPrice = 3, buybackCap = 0 },
        } }) }, opens = 0 }
        nowMs = nowMs + 61000
        fire("OnServerStarted")
        local admin, seller, buyer = fakePlayer("provenance-admin"), fakePlayer("provenance-seller"), fakePlayer("provenance-buyer")
        admin.role = "admin"
        seller.inventory, buyer.inventory = fakeInventory(100), fakeInventory(100)
        onlinePlayers = { admin, seller, buyer }
        assert(cmd(admin, "terminal.register", { x = 100, y = 200, z = 0, kind = "atm" }).ok)
        assert(L.credit(seller:getUsername(), "survivor", 10000, "SYSTEM_MINT", { requestId = "seed-seller", reasonCode = "test" }).ok)
        assert(L.credit(buyer:getUsername(), "survivor", 10000, "SYSTEM_MINT", { requestId = "seed-buyer", reasonCode = "test" }).ok)
        return admin, seller, buyer
    end
    local function native(p, fullType)
        local item = instanceItem(fullType)
        assert(item and p.inventory:AddItem(item) == item)
        return item
    end
    local function list(p, item)
        local res = cmd(p, "market.list", { itemId = item:getID(), price = 10 })
        assert(res.ok, tostring(res.error))
        return res.listingId
    end
    -- 模擬崩潰重啟：世界狀態回到快照，但檔案層不會跟著回滾。所以先把 export queue 真的寫進
    -- 假檔案系統（伺服器每個 tick 本來就在做這件事），權威 journal 才會像真的一樣活過回滾。
    local function restart(saved)
        proofSettle()
        modDataStore[EC.MODDATA_KEY] = copy(saved)
        nowMs = nowMs + 1000
        fire("OnServerStarted")
    end
    -- 收斂現在要等非同步的證據讀取；有界 pump 到該帳號讀完再回來。
    local function reconcileNow(p)
        M.reconcile(p)
        proofPump(p:getUsername())
    end
    local function tally(p, fullType)
        local total = p.inventory.count(fullType)
        for _, row in ipairs(Mk.mine(p:getUsername())) do
            if row.item == fullType then total = total + row.qty end
        end
        for _, row in ipairs(M.list(p:getUsername())) do
            if row.item == fullType then total = total + row.qty end
        end
        for _, row in ipairs(Au.browse(p:getUsername(), { seller = p:getUsername() }).items) do
            if row.item == fullType then total = total + row.qty end
        end
        return total
    end

    -- The two visually identical cases have different ownership, so snapshot deduplication is wrong.
    for _, unrelated in ipairs({ false, true }) do
        local _, seller = fresh()
        local oldId = list(seller, native(seller, "Base.CannedCorn"))
        for _ = 1, 4 do list(seller, native(seller, "Base.Bandage")) end
        local saved = copy(S.modData())
        assert(cmd(seller, "market.cancel", { listingId = oldId }).ok)
        local item = unrelated and native(seller, "Base.CannedCorn") or seller.inventory.items[1]
        local newId = list(seller, item)
        restart(saved)
        reconcileNow(seller)
        local expected = unrelated and 2 or 1
        check(tally(seller, "Base.CannedCorn") == expected and Mk.listingExists(oldId),
            unrelated and "a separately obtained identical item is preserved, not merged into the old corn"
                or "cancel-claim-relist cannot create a second copy when its source return rolled back")
        check(Mk.ownerCount(seller:getUsername()) == (unrelated and 6 or 5)
            and Mk.listingExists(newId) == unrelated and M.recoveryStatus(seller:getUsername()).held == 0,
            "recovery counts real assets rather than forcing the live listing quota")
        restart(saved)
        reconcileNow(seller)
        check(tally(seller, "Base.CannedCorn") == expected, "a second unsaved restart does not multiply the recovered assets")
    end

    -- Distinguish the mail's birth from the later claim. Both cut points leave one valid asset.
    for _, afterClaim in ipairs({ false, true }) do
        local admin, seller = fresh()
        local oldId = list(seller, native(seller, "Base.CannedCorn"))
        assert(cmd(admin, "admin.listings", { action = "delist", listingId = oldId, reason = "return for checkpoint" }).ok)
        local mailId = M.list(seller:getUsername())[1].id
        local saved = copy(S.modData())
        assert(cmd(seller, "mail.claim", { mailId = mailId }).ok)
        if afterClaim then saved = copy(S.modData()) end
        local newId = list(seller, seller.inventory.items[1])
        restart(saved)
        reconcileNow(seller)
        check(tally(seller, "Base.CannedCorn") == 1 and Mk.listingExists(newId)
            and M.unclaimed(seller:getUsername()) == 0,
            afterClaim and "a durable claim permits restoring only the later lost listing"
                or "a durable mail and rolled-back claim transfer the same unit, without discarding or duplicating it")
        local again = cmd(seller, "mail.claim", { mailId = mailId })
        check(not again.ok and seller.inventory.count("Base.CannedCorn") == 0,
            "the source mail cannot also deliver units already restored into a listing")
    end

    -- The world knows the outflow even when the older player save has no pending record at all.
    for _, oldHasItem in ipairs({ false, true }) do
        local admin, seller = fresh()
        local oldId = list(seller, native(seller, "Base.CannedCorn"))
        assert(cmd(admin, "admin.listings", { action = "delist", listingId = oldId, reason = "independent save" }).ok)
        local mailId = M.list(seller:getUsername())[1].id
        local oldPlayer = copy(seller.modData)
        assert(cmd(seller, "mail.claim", { mailId = mailId }).ok)
        local returned, oldItemData = seller.inventory.items[1], nil
        if oldHasItem then oldPlayer, oldItemData = copy(seller.modData), copy(returned:getModData()) end
        local newId = list(seller, returned)
        local saved = copy(S.modData())
        seller.modData, seller.inventory.items = oldPlayer, {}
        if oldHasItem then returned.modData = oldItemData; seller.inventory.items = { returned } end
        restart(saved)
        reconcileNow(seller)
        check(Mk.listingExists(newId) and tally(seller, "Base.CannedCorn") == 1 and seller.inventory.count("Base.CannedCorn") == 0,
            oldHasItem and "world outflow receipts reclaim the stale physical copy without relying on player pending"
                or "world outflow receipts prevent redelivery when the older player has no claim witness or pending")
    end

    do
        local _, seller, buyer = fresh()
        local original = native(seller, "Base.CannedCorn")
        local saved = copy(S.modData())
        local id = list(seller, original)
        local oldPlayer = copy(seller.modData)
        restart(saved)
        reconcileNow(seller)
        assert(Mk.listingExists(id))
        assert(cmd(buyer, "market.buy", { listingId = id, price = 10 }).ok)
        saved = copy(S.modData())
        seller.modData = oldPlayer
        restart(saved)
        reconcileNow(seller)
        check(not Mk.listingExists(id) and tally(seller, "Base.CannedCorn") == 0 and tally(buyer, "Base.CannedCorn") == 1,
            "an old pending cannot revive a restored listing after its sale was saved")
        check(L.conservation("survivor") == 0, "recovery and sale preserve the ledger's currency conservation")
    end

    do
        local _, seller, buyer = fresh()
        local id = list(seller, native(seller, "Base.CannedCorn"))
        local saved = copy(S.modData())
        local balance = L.getBalance(buyer:getUsername(), "survivor").available
        assert(cmd(buyer, "market.buy", { listingId = id, price = 10 }).ok)
        list(buyer, buyer.inventory.items[1])
        restart(saved)
        reconcileNow(buyer)
        check(tally(seller, "Base.CannedCorn") == 1 and tally(buyer, "Base.CannedCorn") == 0
            and L.getBalance(buyer:getUsername(), "survivor").available == balance,
            "purchase rollback restores the seller and buyer balance, but never a free buyer relisting")
    end

    do
        local _, seller = fresh()
        local oldId = list(seller, native(seller, "Base.CannedCorn"))
        local saved = copy(S.modData())
        assert(cmd(seller, "market.cancel", { listingId = oldId }).ok)
        local fromMail = seller.inventory.items[1]
        local separate = native(seller, "Base.CannedCorn")
        local mixed = cmd(seller, "market.list", { itemIds = { fromMail:getID(), separate:getID() }, price = 30 })
        assert(mixed.ok, tostring(mixed.error))
        local oldPlayer = copy(seller.modData)
        restart(saved)
        reconcileNow(seller)
        local returns = M.list(seller:getUsername())
        check(tally(seller, "Base.CannedCorn") == 2 and not Mk.listingExists(mixed.listingId)
            and #returns == 1 and returns[1].qty == 1 and returns[1].kind == "return",
            "mixed-source rollback returns only the valid remainder instead of silently repricing a smaller listing")
        saved = copy(S.modData())
        seller.modData = oldPlayer
        restart(saved)
        reconcileNow(seller)
        check(tally(seller, "Base.CannedCorn") == 2 and #M.list(seller:getUsername()) == 1,
            "the mixed-lot return has an idempotent resolution receipt")
    end

    do
        local _, seller = fresh()
        local parent = M.add(seller:getUsername(), { item = "Base.Bandage", qty = 3, kind = "shop" })
        local saved = copy(S.modData())
        local realAdd, realRemove = seller.inventory.AddItem, seller.inventory.Remove
        local adds, removes = 0, 0
        seller.inventory.AddItem = function(inv, item)
            adds = adds + 1
            realAdd(inv, item)
            if adds == 2 then error("second addition failed after changing inventory") end
            return item
        end
        seller.inventory.Remove = function(inv, item)
            removes = removes + 1
            if removes == 1 then error("confirmed subset could not be taken back") end
            realRemove(inv, item)
        end
        local claim = M.claim(seller, parent.id)
        seller.inventory.AddItem, seller.inventory.Remove = realAdd, realRemove
        assert(claim.error == "delivery_partial" and claim.deliveredQty == 1)
        local id = list(seller, seller.inventory.items[1])
        restart(saved)
        reconcileNow(seller)
        check(tally(seller, "Base.Bandage") == 3 and not Mk.listingExists(id),
            "a child-mail relisting is not rebuilt on top of the restored parent quantity")
    end

    do
        local _, seller = fresh()
        local oldId = list(seller, native(seller, "Base.CannedCorn"))
        local saved = copy(S.modData())
        assert(cmd(seller, "market.cancel", { listingId = oldId }).ok)
        local auction = cmd(seller, "auction.create", { itemId = seller.inventory.items[1]:getID(), startPrice = 10, hours = 12 })
        assert(auction.ok, tostring(auction.error))
        restart(saved)
        reconcileNow(seller)
        check(Mk.listingExists(oldId) and not Au.hasAuction(auction.auctionId) and tally(seller, "Base.CannedCorn") == 1,
            "the same source guard covers a returned item re-entering through auction")
    end

    do
        local _, seller = fresh()
        local saved = copy(S.modData())
        local balance = L.getBalance(seller:getUsername(), "survivor").available
        assert(cmd(seller, "shop.buy", { id = "corn", count = 1, revision = Shop.revision() }).ok)
        local sale = cmd(seller, "shop.sell", { id = "corn", itemIds = { seller.inventory.items[1]:getID() }, revision = Shop.revision() })
        assert(sale.ok, tostring(sale.error))
        restart(saved)
        reconcileNow(seller)
        check(L.getBalance(seller:getUsername(), "survivor").available == balance and tally(seller, "Base.CannedCorn") == 0,
            "a rolled-back shop purchase cannot also earn a recovered buyback payment")
    end

    do
        local _, seller = fresh()
        seller.modData[KEY] = { claims = {}, pendingOuts = {
            ["1000000:900"] = { kind = "listing", qty = 1, price = 10, itemId = -700,
                epoch = "1000000", seq = 900, snapshot = S.Codec.snapshot(instanceItem("Base.Bandage")) },
        } }
        reconcileNow(seller)
        check(M.recoveryStatus(seller:getUsername()).held == 1 and seller.modData[KEY].pendingOuts["1000000:900"] ~= nil
            and tally(seller, "Base.Bandage") == 0,
            "legacy source-less pending remains visible for reconciliation, neither discarded nor minted")
        reconcileNow(seller)
        check(M.recoveryStatus(seller:getUsername()).held == 1 and tally(seller, "Base.Bandage") == 0,
            "repeated login does not turn an unverified legacy claim into a new asset")
    end
    local function confirmWorld()
        local meta = S.modData().meta
        files[S.DURABLE_FILE] = { lines = { EC.jsonEncode({ realmId = meta.realmId, epoch = meta.epoch, seq = meta.seq, ts = nowMs }) } }
        S.pollDurable(true)
    end
    do
        local _, seller = fresh()
        local a, b = native(seller, "Base.Bandage"), native(seller, "Base.Bandage")
        local saved = copy(S.modData())
        local out = cmd(seller, "market.list", { itemIds = { a.id, b.id }, price = 20 })
        assert(out.ok)
        local originalPlayer = copy(seller.modData)
        restart(saved)
        seller.inventory.items = { a }
        reconcileNow(seller)
        check(tally(seller, "Base.Bandage") == 2 and seller.inventory.count("Base.Bandage") == 1,
            "partial rollback keeps the item already present and returns only its missing peer")
        local partialWorld = copy(S.modData())
        local partialPlayer = copy(seller.modData)
        seller.modData = copy(originalPlayer)
        restart(partialWorld)
        reconcileNow(seller)
        check(tally(seller, "Base.Bandage") == 2 and seller.inventory:contains(a),
            "a partial receipt never authorizes deleting an unconsumed origin from an older pending")
        seller.modData = copy(partialPlayer) -- separate branch: the return never reached a world save
        restart(saved)
        reconcileNow(seller)
        check(tally(seller, "Base.Bandage") == 2,
            "an unsaved partial return retains a player guard through another world rollback")
    end
    do
        local _, seller = fresh()
        local beforeClaim = copy(seller.modData)
        local parcel = M.add(seller:getUsername(), { item = "Base.Bandage", qty = 5, kind = "shop" })
        assert(M.claim(seller, parcel.id).ok)
        local originalPlayer, originalItems, originalData = copy(seller.modData), {}, {}
        for i, item in ipairs(seller.inventory.items) do originalItems[i], originalData[i] = item, copy(item:getModData()) end
        assert(cmd(seller, "market.list", { itemIds = { originalItems[1].id, originalItems[2].id }, price = 20 }).ok)
        local confirmed = copy(S.modData())
        confirmWorld()
        seller.modData, seller.inventory.items = copy(beforeClaim), {}
        reconcileNow(seller)
        assert(seller.inventory.count("Base.Bandage") == 3)
        assert(cmd(seller, "market.list", { itemIds = { seller.inventory.items[1].id, seller.inventory.items[2].id }, price = 20 }).ok)
        seller.modData, seller.inventory.items = copy(originalPlayer), {}
        for i, item in ipairs(originalItems) do item.modData = copy(originalData[i]); seller.inventory:AddItem(item) end
        reconcileNow(seller)
        check(seller.inventory.count("Base.Bandage") == 1 and tally(seller, "Base.Bandage") == 5,
            "stable tokens remove four consumed units even after redelivery changed native ids")
        restart(confirmed)
        reconcileNow(seller)
        check(seller.inventory.count("Base.Bandage") == 1 and tally(seller, "Base.Bandage") == 5,
            "current-receipt insurance preserves units when the world later loses that commitment")
    end
    do
        local _, seller, buyer = fresh()
        local mail = M.add(seller:getUsername(), { item = "Base.Bandage", qty = 1, kind = "shop" })
        assert(M.claim(seller, mail.id).ok)
        local item, oldPlayer = seller.inventory.items[1], copy(seller.modData)
        seller.inventory:Remove(item)
        buyer.inventory:AddItem(item)
        list(buyer, item)
        confirmWorld()
        seller.modData = oldPlayer
        seller.inventory:AddItem(item)
        local refused = cmd(seller, "market.list", { itemId = item.id, price = 10 })
        check(refused.error == "recovery_conflict" and seller.inventory:contains(item),
            "source-owner consumption rejects a stale token before it can be transferred a second time")
        reconcileNow(seller)
        check(tally(seller, "Base.Bandage") == 0 and tally(buyer, "Base.Bandage") == 1,
            "reconciliation follows a consumed token across different account owners")
    end
    do
        local _, seller = fresh()
        local item = native(seller, "Base.Bandage")
        local saved = copy(S.modData())
        local id = list(seller, item)
        restart(saved)
        local cap = S.Recovery.OPS_MAX
        S.Recovery.OPS_MAX = 0
        reconcileNow(seller)
        check(not Mk.listingExists(id) and tally(seller, "Base.Bandage") == 0
            and seller.modData[KEY].pendingOuts[id] ~= nil and M.recoveryStatus(seller:getUsername()).held > 0,
            "recovery reserves receipt capacity before creating any asset")
        S.Recovery.OPS_MAX = cap
        reconcileNow(seller)
        check(Mk.listingExists(id) and tally(seller, "Base.Bandage") == 1,
            "a capacity-held operation recovers exactly once when admission becomes available")
    end
    do
        local _, seller = fresh()
        local item = native(seller, "Base.Bandage")
        local balance = L.getBalance(seller:getUsername(), "survivor").available
        local realAdd, realRemove = seller.inventory.AddItem, seller.inventory.Remove
        seller.inventory.Remove = function(inv, object) realRemove(inv, object); error("remove hook failed after mutation") end
        seller.inventory.AddItem = function() return nil end
        local failed = cmd(seller, "market.list", { itemId = item.id, price = 10 })
        seller.inventory.AddItem, seller.inventory.Remove = realAdd, realRemove
        check(failed.error == "recovery_pending" and seller.inventory.count("Base.Bandage") == 0
            and L.getBalance(seller:getUsername(), "survivor").available == balance,
            "an incomplete abort is reported as unresolved rather than an ordinary harmless refusal")
        local saved = copy(S.modData())
        restart(saved)
        reconcileNow(seller)
        check(M.recoveryStatus(seller:getUsername()).held > 0
            and EC.countKeys(seller.modData[KEY].pendingOuts) == 1 and tally(seller, "Base.Bandage") == 0,
            "saving the begin sequence does not erase an aborted operation's recovery evidence")
    end
    do
        local _, seller = fresh()
        local parcel = M.add(seller:getUsername(), { item = "Base.Bandage", qty = 1, kind = "shop" })
        assert(M.claim(seller, parcel.id).ok)
        local item, older = seller.inventory.items[1], copy(seller.modData)
        list(seller, item)
        confirmWorld()
        seller.modData = older
        seller.inventory:AddItem(item)
        local realRemove = seller.inventory.Remove
        seller.inventory.Remove = function() error("removal rejected before mutation") end
        reconcileNow(seller)
        check(seller.inventory:contains(item) and M.recoveryStatus(seller:getUsername()).held > 0,
            "a failed physical removal stays visible and is never recorded as gone")
        seller.inventory.Remove = realRemove
        reconcileNow(seller)
        check(not seller.inventory:contains(item) and M.recoveryStatus(seller:getUsername()).held == 0,
            "a later confirmed removal resolves the exact held record")
    end
    do
        local _, seller = fresh()
        for _ = 1, S.Recovery.PENDING_MAX do
            local item = native(seller, "Base.CannedCorn")
            assert(cmd(seller, "shop.sell", { id = "corn", itemIds = { item.id }, revision = Shop.revision() }).ok)
        end
        local item = native(seller, "Base.CannedCorn")
        local full = cmd(seller, "shop.sell", { id = "corn", itemIds = { item.id }, revision = Shop.revision() })
        check(full.error == "recovery_pending" and seller.inventory:contains(item)
            and EC.countKeys(seller.modData[KEY].pendingOuts) == S.Recovery.PENDING_MAX,
            "unconfirmed transfers stop at the bound instead of evicting rollback evidence")
        local epoch = S.modData().meta.epoch
        confirmWorld()
        local resumed = cmd(seller, "shop.sell", { id = "corn", itemIds = { item.id }, revision = Shop.revision() })
        check(resumed.ok and S.modData().meta.epoch == epoch and seller.inventory.count("Base.CannedCorn") == 0
            and EC.countKeys(seller.modData[KEY].pendingOuts) == 1,
            "a real durable watermark releases completed guards without restarting the server")
    end
    -- FINAL-REC-A: a redelivery that cannot fit requeues the letter for the units it still owes,
    -- not for the quantity it was born with.
    do
        local _, seller = fresh()
        local beforeClaim = copy(seller.modData)
        local parcel = M.add(seller:getUsername(), { item = "Base.Bandage", qty = 5, kind = "shop" })
        assert(M.claim(seller, parcel.id).ok)
        assert(cmd(seller, "market.list", { itemIds = { seller.inventory.items[1].id, seller.inventory.items[2].id }, price = 20 }).ok)
        confirmWorld()
        local function mailRow()
            for _, row in ipairs(M.list(seller:getUsername())) do
                if row.id == parcel.id then return row end
            end
            return nil
        end
        seller.modData, seller.inventory.items = copy(beforeClaim), {}
        seller.inventory.maxWeight = 0            -- the older save logs in with no room at all
        reconcileNow(seller)
        local requeued = mailRow()
        check(requeued ~= nil and requeued.qty == 3 and seller.inventory.count("Base.Bandage") == 0
            and tally(seller, "Base.Bandage") == 5,
            "a redelivery with no room requeues the letter for the three unconsumed units, not the original five")
        seller.inventory.maxWeight = 100
        local rest = M.claim(seller, parcel.id)
        check(rest.ok and rest.deliveredQty == 3 and seller.inventory.count("Base.Bandage") == 3
            and tally(seller, "Base.Bandage") == 5,
            "the requeued letter hands over exactly its remainder instead of failing to confirm five objects")
        local exhausted = M.claim(seller, parcel.id)
        check(not exhausted.ok and mailRow() == nil and seller.inventory.count("Base.Bandage") == 3
            and tally(seller, "Base.Bandage") == 5,
            "the claimable remainder plus the consumed tokens stay at the five units the letter was born with")
    end

    -- FINAL-REC-B: the claimed letter is pruned after a day. A unit this server proved is still
    -- tradable; one it never proved is refused, and neither is invented or destroyed.
    do
        local _, seller, buyer = fresh()
        local sellerMail = M.add(seller:getUsername(), { item = "Base.Bandage", qty = 2, kind = "shop" })
        local buyerMail = M.add(buyer:getUsername(), { item = "Base.Bandage", qty = 2, kind = "shop" })
        assert(M.claim(seller, sellerMail.id).ok)
        assert(M.claim(buyer, buyerMail.id).ok)
        local stamp = buyer.inventory.items[1]:getModData()[KEY]
        local claimEpoch, claimSeq = stamp.epoch, stamp.seq
        restart(copy(S.modData()))
        reconcileNow(seller)                       -- only the seller logs in while the claim epoch is readable
        nowMs = nowMs + M.CLAIMED_TTL_MS + 60000
        fire("OnTickEvenPaused")
        local proven = cmd(seller, "market.list", { itemId = seller.inventory.items[1].id, price = 10 })
        check(M.entryOf(seller:getUsername(), sellerMail.id) == nil
            and M.entryOf(buyer:getUsername(), buyerMail.id) == nil
            and proven.ok and Mk.listingExists(proven.listingId),
            "a source letter pruned after its day does not retire a unit whose claim the history still proves")
        local beforeBuyerOut = copy(S.modData())
        local buyerOut = cmd(buyer, "market.list", { itemId = buyer.inventory.items[1].id, price = 10 })
        assert(buyerOut.ok, tostring(buyerOut.error))
        restart(beforeBuyerOut)                   -- that list-out never reached a world save
        local starts = 0
        while S.epochVerdict(claimEpoch, claimSeq) ~= "unknown" and starts < 40 do
            starts = starts + 1
            nowMs = nowMs + 1000
            fire("OnServerStarted")
        end
        assert(S.epochVerdict(claimEpoch, claimSeq) == "unknown")
        local certified = cmd(seller, "market.list", { itemId = seller.inventory.items[1].id, price = 10 })
        check(certified.ok and Mk.listingExists(certified.listingId) and tally(seller, "Base.Bandage") == 2,
            "a verdict this server wrote onto the unit when it was still readable survives twenty later starts")
        local unproven = cmd(buyer, "market.list", { itemId = buyer.inventory.items[1].id, price = 10 })
        check(unproven.error == "recovery_unverified" and buyer.inventory.count("Base.Bandage") == 1,
            "a unit whose holder never logged in before its epoch was forgotten is refused, not waved through")
        reconcileNow(buyer)
        check(M.recoveryStatus(buyer:getUsername()).held > 0
            and buyer.modData[KEY].pendingOuts[buyerOut.listingId] ~= nil
            and not Mk.listingExists(buyerOut.listingId) and buyer.inventory.count("Base.Bandage") == 1,
            "an unprovable origin holds the rolled-back operation instead of rebuilding a listing from it")
    end

    -- FINAL-REC-B, same uptime: no restart ever happened, so the letter's absence is this very
    -- process having delivered it. Trading is allowed; a later rollback still must not mint.
    do
        local _, seller = fresh()
        local mail = M.add(seller:getUsername(), { item = "Base.Bandage", qty = 1, kind = "shop" })
        local beforeClaim = copy(S.modData())
        assert(M.claim(seller, mail.id).ok)
        nowMs = nowMs + M.CLAIMED_TTL_MS + 60000
        fire("OnTickEvenPaused")
        local out = cmd(seller, "market.list", { itemId = seller.inventory.items[1].id, price = 10 })
        check(M.entryOf(seller:getUsername(), mail.id) == nil and out.ok
            and S.durableStatus().source == "none",
            "a letter pruned inside one uptime, with no watermark at all, still lets this process's own delivery trade")
        restart(beforeClaim)
        reconcileNow(seller)
        check(tally(seller, "Base.Bandage") == 1 and seller.inventory.count("Base.Bandage") == 0,
            "rolling the world below that claim leaves exactly one unit, never a second copy of it")
    end

    -- FINAL-REC-C: a partial child, then the parent claimed to the end, then a rollback below both.
    do
        local _, seller = fresh()
        local parent = M.add(seller:getUsername(), { item = "Base.Bandage", qty = 3, kind = "shop" })
        local saved = copy(S.modData())
        local realAdd, realRemove = seller.inventory.AddItem, seller.inventory.Remove
        local adds, removes = 0, 0
        seller.inventory.AddItem = function(inv, item)
            adds = adds + 1
            realAdd(inv, item)
            if adds == 2 then error("second addition failed after changing inventory") end
            return item
        end
        seller.inventory.Remove = function(inv, item)
            removes = removes + 1
            if removes == 1 then error("confirmed subset could not be taken back") end
            realRemove(inv, item)
        end
        local partial = M.claim(seller, parent.id)
        seller.inventory.AddItem, seller.inventory.Remove = realAdd, realRemove
        assert(partial.error == "delivery_partial" and partial.deliveredQty == 1)
        local finished = M.claim(seller, parent.id)
        assert(finished.ok and finished.deliveredQty == 2, tostring(finished.error))
        assert(seller.inventory.count("Base.Bandage") == 3)
        for pass = 1, 2 do
            restart(saved)                        -- the world is back at the ready parent, with no child
            reconcileNow(seller)
            check(seller.inventory.count("Base.Bandage") == 3 and tally(seller, "Base.Bandage") == 3,
                pass == 1 and "a rollback below a partial child and its finished parent keeps all three units"
                    or "repeating that rollback and login neither eats nor mints one of them either")
        end
    end

    -- FINAL-REC-D: a 32-bit id that came back on a different item is not the missing asset.
    do
        local _, seller = fresh()
        local saved = copy(S.modData())
        local sent = native(seller, "Base.CannedCorn")
        local id = list(seller, sent)
        local nextId = nextItemId
        nextItemId = sent:getID()
        local twin = native(seller, "Base.Bandage")   -- same id, different item (asset-id-reuse-evidence)
        nextItemId = nextId
        assert(twin:getID() == sent:getID())
        restart(saved)                                -- the world never saved the listing or its receipt
        reconcileNow(seller)
        check(Mk.listingExists(id) and seller.inventory:contains(twin)
            and tally(seller, "Base.CannedCorn") == 1 and tally(seller, "Base.Bandage") == 1,
            "a locator collision on another item type neither closes the lost unit's pending nor deletes the collider")
        reconcileNow(seller)
        check(seller.inventory:contains(twin) and tally(seller, "Base.Bandage") == 1
            and M.recoveryStatus(seller:getUsername()).held == 0,
            "the restored receipt does not accuse the colliding item of being a stale copy on the next login")
    end

    -- FINAL-REC-D, native unit tokens (1 and 2): an untokened item of the same type and id is
    -- ambiguity, not identity; once it is out of the way the lost unit is restored exactly once.
    do
        local _, seller = fresh()
        local saved = copy(S.modData())
        local sent = native(seller, "Base.CannedCorn")
        local id = list(seller, sent)
        local nextId = nextItemId
        nextItemId = sent:getID()
        local twin = native(seller, "Base.CannedCorn")   -- a second real item, same type, same id, no token
        nextItemId = nextId
        assert(twin ~= sent and twin:getID() == sent:getID())
        restart(saved)                                   -- the world never saved the listing or its receipt
        reconcileNow(seller)
        check(not Mk.listingExists(id) and seller.inventory:contains(twin)
            and seller.modData[KEY].pendingOuts[id] ~= nil and tally(seller, "Base.CannedCorn") == 1
            and M.recoveryStatus(seller:getUsername()).held > 0,
            "an untokened item of the same type and id holds the lost unit instead of settling or rebuilding it")
        seller.inventory:Remove(twin)
        reconcileNow(seller)
        check(Mk.listingExists(id) and seller.inventory.count("Base.CannedCorn") == 0
            and tally(seller, "Base.CannedCorn") == 1
            and M.recoveryStatus(seller:getUsername()).held == 0,
            "with the collider gone the named unit is restored exactly once and its hold is resolved")
        reconcileNow(seller)
        check(Mk.listingExists(id) and tally(seller, "Base.CannedCorn") == 1,
            "a later login does not restore that unit a second time")
    end
    -- FINAL-REC-D (3): the world saved the t+n receipt, the player save predates both the stamp
    -- and the pending.
    do
        local _, seller = fresh()
        local item = native(seller, "Base.CannedCorn")
        local oldPlayer, beforeStamp = copy(seller.modData), copy(item:getModData())
        local id = list(seller, item)
        confirmWorld()
        seller.modData = oldPlayer                       -- no pending at all, and older than the stamp
        item.modData = beforeStamp
        seller.inventory:AddItem(item)
        reconcileNow(seller)
        check(Mk.listingExists(id) and seller.inventory:contains(item)
            and M.recoveryStatus(seller:getUsername()).held == 1,
            "a saved receipt plus a save older than the stamp holds the stale copy, neither spending nor deleting it")
        local refused = cmd(seller, "market.list", { itemId = item.id, price = 10 })
        reconcileNow(seller)
        check(refused.error == "recovery_conflict" and seller.inventory:contains(item)
            and item:getModData()[KEY] == nil and M.recoveryStatus(seller:getUsername()).held == 1,
            "that held stale copy cannot be listed as a fresh asset, and the hold stays one record")
    end
    -- FINAL-REC-D (4): a complete abort keeps the unit tradable under its own token; wiping that
    -- token while the operation is still open must not buy a new one.
    do
        local _, seller = fresh()
        local item = native(seller, "Base.CannedCorn")
        local realRemove = seller.inventory.Remove
        seller.inventory.Remove = function() error("removal rejected before mutation") end
        local aborted = cmd(seller, "market.list", { itemId = item.id, price = 10 })
        seller.inventory.Remove = realRemove
        local stamp = item:getModData()[KEY]
        local token = type(stamp) == "table" and stamp.unit or nil
        check(aborted.error == "delivery_failed" and seller.inventory:contains(item) and type(token) == "string"
            and EC.countKeys(seller.modData[KEY].pendingOuts) == 0
            and M.recoveryStatus(seller:getUsername()).held == 0,
            "a list-out aborted before anything moved hands the named object back and leaves no evidence open")
        local again = cmd(seller, "market.list", { itemId = item.id, price = 10 })
        check(again.ok and item:getModData()[KEY].unit == token and tally(seller, "Base.CannedCorn") == 1
            and M.recoveryStatus(seller:getUsername()).held == 0,
            "the same unit token trades again after a complete abort, and is never minted a second name")
        local other = native(seller, "Base.CannedCorn")
        local otherBefore = copy(other:getModData())
        local otherId = list(seller, other)
        other.modData = otherBefore                      -- the stamp is gone; the open operation is not
        seller.inventory:AddItem(other)
        local bypass = cmd(seller, "market.list", { itemId = other.id, price = 10 })
        check(bypass.error == "recovery_conflict" and other:getModData()[KEY] == nil
            and seller.inventory:contains(other) and Mk.listingExists(otherId)
            and seller.inventory.count("Base.CannedCorn") == 1,
            "wiping the token off an object whose operation is still open cannot mint a fresh one past the guard")
    end

    -- FINAL-REC-E: a closed receipt whose own epoch left the bounded history is still reclaimable.
    do
        local _, seller = fresh()
        local opsMax, pruneAt, pruneTo = S.Recovery.OPS_MAX, S.Recovery.OPS_PRUNE_AT, S.Recovery.OPS_PRUNE_TO
        S.Recovery.OPS_MAX, S.Recovery.OPS_PRUNE_AT, S.Recovery.OPS_PRUNE_TO = 3, 3, 1
        local function sell()
            local item = native(seller, "Base.CannedCorn")
            return cmd(seller, "shop.sell", { id = "corn", itemIds = { item.id }, revision = Shop.revision() })
        end
        for _ = 1, 3 do assert(sell().ok) end
        confirmWorld()
        reconcileNow(seller)
        check(S.modData().recovery.count == 3 and EC.countKeys(seller.modData[KEY].pendingOuts) == 0
            and M.recoveryStatus(seller:getUsername()).held == 0,
            "a converged transfer closes its receipt in place; the record itself is still there")
        local epoch = S.modData().meta.epoch
        local starts = 0
        while S.epochVerdict(epoch, 1) ~= "unknown" and starts < 40 do
            starts = starts + 1
            nowMs = nowMs + 1000
            fire("OnServerStarted")
        end
        check(S.epochVerdict(epoch, 1) == "unknown" and S.modData().recovery.count == 3,
            "twenty ordinary restarts make that epoch unreadable while its receipts are still carried")
        local resumed = sell()
        check(resumed.ok and S.modData().recovery.count <= 2,
            "a closed receipt the loaded save itself proves is reclaimed instead of holding the global quota for ever")
        local blocked = nil
        for _ = 1, 4 do
            local res = sell()
            if not res.ok then blocked = res; break end
        end
        check(blocked ~= nil and blocked.error == "recovery_capacity" and S.modData().recovery.count == 3
            and EC.countKeys(seller.modData[KEY].pendingOuts) >= 2 and seller.inventory.count("Base.CannedCorn") == 1,
            "receipts that never converged are refused admission rather than pruned to make room")
        S.Recovery.OPS_MAX, S.Recovery.OPS_PRUNE_AT, S.Recovery.OPS_PRUNE_TO = opsMax, pruneAt, pruneTo
    end

    -- 刻意同一個 tick 內崩潰：證據還在 export queue 裡就沒了。這一格**不能**用上面的 restart
    -- helper，因為那支會先 proofSettle() 把證據寫出去，等於偷偷把這個反例變成正向案例。
    do
        local _, seller = fresh()
        local saved = copy(S.modData())
        local id = list(seller, native(seller, "Base.CannedCorn"))
        local oldPlayer = copy(seller.modData)
        modDataStore[EC.MODDATA_KEY] = copy(saved)   -- 沒有 proofSettle：這就是「同 tick 崩潰」
        nowMs = nowMs + 1000
        fire("OnServerStarted")
        seller.modData = oldPlayer
        reconcileNow(seller)
        check(not Mk.listingExists(id) and tally(seller, "Base.CannedCorn") == 0
            and M.recoveryStatus(seller:getUsername()).held > 0,
            "a crash in the same tick as the operation loses the proof with the queue: the listing is not rebuilt from the player's own file, it is held for a human")
    end

    SandboxVars.MinidoracatEconomy.ShopBuybackEnabled = nil
    SandboxVars.MinidoracatEconomy.ShopBuybackPerAccountDaily = nil
    SandboxVars.MinidoracatEconomy.ShopBuybackServerDaily = nil
    onlinePlayers = {}
end)()

io.write("scenario 43: exact historical actor filters precede result bounds\n")
;(function()
    modDataStore[EC.MODDATA_KEY] = nil
    files, writerDeny, sentCommands = {}, {}, {}
    nowMs = 1700000000000
    fire("OnServerStarted")
    local admin, outsider = fakePlayer("query-admin"), fakePlayer("query-outsider")
    admin.role = "admin"
    onlinePlayers = { admin, outsider }
    local from = nowMs
    X.audit({ admin = "retired-admin", action = "freeze", target = "old-account" })
    nowMs = nowMs + 1
    X.audit({ admin = "retired-admin-extra", action = "freeze", target = "different-account" })
    for i = 1, 450 do
        nowMs = nowMs + 1
        X.audit({ admin = "current-admin", action = "freeze", target = "noise-" .. i })
    end
    local untilMs = nowMs + 1
    local serial = 0
    local function request(p, command, args)
        serial, nowMs = serial + 1, nowMs + 700
        args.requestId = "actor-filter-" .. serial
        local first = #sentCommands + 1
        fire("OnClientCommand", EC.COMMAND_MODULE, command, p, args)
        for _ = 1, 100 do
            for i = first, #sentCommands do
                local reply = sentCommands[i]
                if reply.player == p and reply.command == command and reply.args.requestId == args.requestId then return reply.args end
            end
            fire("OnTickEvenPaused")
        end
        error("missing historical actor reply: " .. command)
    end
    local args = { actor = "retired-admin", fromMs = from, toMs = untilMs, limit = 1 }
    local ring = request(admin, "admin.audit", args)
    check(ring.ok and ring.total == 1 and #ring.entries == 1 and ring.entries[1].admin == "retired-admin",
        "the ring exact actor filter runs before its requested one-row limit")
    local file = request(admin, "admin.auditFile", { actor = "retired-admin", fromMs = from, toMs = untilMs })
    check(file.error == nil and file.total == 1 and #file.entries == 1 and file.entries[1].target == "old-account",
        "an old exact actor match survives more than 200 newer unrelated file rows")
    local actors = {}
    for _, name in ipairs(file.actors or {}) do actors[name] = true end
    check(actors["retired-admin"] and actors["retired-admin-extra"] and actors["current-admin"]
        and S.modData().wallets["retired-admin"] == nil,
        "actor candidates come from history, including former admins without accounts, before exact filtering")
    local range = request(admin, "admin.auditFile", { actor = "retired-admin", fromMs = from + 1, toMs = untilMs })
    check(range.error == nil and range.total == 0 and #range.entries == 0,
        "the actor predicate and inclusive/exclusive date bounds both apply")
    local invalid = request(admin, "admin.auditFile", { actor = {}, fromMs = from, toMs = untilMs })
    check(invalid.error == "invalid_args", "an actor must be bounded text, not an arbitrary command-table value")
    local denied = request(outsider, "admin.auditFile", { actor = "retired-admin", fromMs = from, toMs = untilMs })
    check(denied.error == "forbidden" and denied.actors == nil, "a player cannot obtain historical staff names without read permission")
    local path = X.ROOT .. "/audit/" .. EC.monthKey(from) .. ".json"
    files[path].lines[#files[path].lines + 1] = "{bad-json"
    local broken = request(admin, "admin.auditFile", { actor = "retired-admin", fromMs = from, toMs = untilMs })
    check(broken.error == "read_failed" and #broken.entries == 0,
        "a broken filtered file is not delivered as a complete successful audit list")
    onlinePlayers = {}
end)()

io.write("scenario 44: durable watermark trust boundary\n")
;(function()
    modDataStore[EC.MODDATA_KEY] = nil
    files, writerDeny, sentCommands = {}, {}, {}
    nowMs = nowMs + 61000
    fire("OnServerStarted")
    -- The boundaries are the seqs this world really issued, not constants: whatever else the
    -- start-up did with the counter, `confirmed` is a posted row and `beyond` is the next one.
    local issued = {}
    for i = 1, 3 do local _, seq = EC.parseId(S.newId()); issued[i] = seq end
    local confirmed, beyond = issued[2], issued[3]
    local meta = S.modData().meta
    local function marker(realm, epoch, seq)
        files[S.DURABLE_FILE] = { lines = { EC.jsonEncode({ realmId = realm, epoch = epoch, seq = seq, ts = nowMs }) } }
        return S.pollDurable(true)
    end
    check(S.durableStatus().source == "none" and S.epochVerdict(meta.epoch, confirmed) == "current",
        "a new process never invents a current-epoch save watermark")
    local rejected = true
    for _, invalid in ipairs({
        { "foreign-realm", meta.epoch, confirmed }, { meta.realmId, "other-epoch", confirmed },
        { meta.realmId, meta.epoch, beyond + 1 }, { meta.realmId, meta.epoch, tostring(confirmed) },
        { meta.realmId, meta.epoch, confirmed + 0.5 }, { meta.realmId, meta.epoch, -1 },
    }) do
        local result = marker(invalid[1], invalid[2], invalid[3])
        if result.source ~= "none" or S.epochVerdict(meta.epoch, confirmed) ~= "current" then rejected = false end
    end
    check(rejected, "foreign, future, coerced and non-integer watermarks never retire a live guard")
    local valid = marker(meta.realmId, meta.epoch, confirmed)
    check(valid.source == "companion" and valid.seq == confirmed and S.epochVerdict(meta.epoch, confirmed) == "survived"
        and S.epochVerdict(meta.epoch, beyond) == "current", "only the confirmed prefix becomes durable")
    local backward = marker(meta.realmId, meta.epoch, confirmed - 1)
    check(backward.status == "regressed" and backward.seq == confirmed, "a stale marker cannot lower the last confirmed watermark")
    local reader = getFileReader
    getFileReader = function(path, create) if path == S.DURABLE_FILE then return nil end; return reader(path, create) end
    local unreadable = S.pollDurable(true)
    getFileReader = reader
    check(unreadable.status == "unreadable" and unreadable.seq == confirmed,
        "an existing file whose native reader returns nil is not mistaken for a missing or new watermark")
    files[S.DURABLE_FILE] = { lines = { string.rep("x", S.DURABLE_MAX_CHARS + 1) } }
    check(S.pollDurable(true).seq == confirmed, "oversized or broken JSON cannot replace a proven watermark")
    marker(meta.realmId, meta.epoch, confirmed)
    nowMs = nowMs + 1000
    fire("OnServerStarted")
    check(S.durableStatus().source == "none" and S.durableStatus().status == "other_epoch",
        "a restarted process rejects the preceding process's leftover marker")
end)()

-- ===== 情境四十五：Gen0 舊資產綁定與管理對帳（回報 #2／#4）=====
io.write("scenario 45: generation zero binding + admin reconciliation\n")
;(function()
local function deepCopy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = deepCopy(v) end
    return out
end
local M, Mk, Rec, Au = S.Mailbox, S.Market, S.Recovery, S.Auction
local KEY = EC.PLAYER_MODDATA_KEY
modDataStore[EC.MODDATA_KEY] = nil
files = {}
sentCommands = {}
sentItemPackets = {}
worldSprites = { ["100,200,0"] = "MinidoracatEconomy_terminal_0" }
nowMs = nowMs + 61000
fire("OnServerStarted")
local boss = fakePlayer("boss"); boss.role = "admin"
local mod = fakePlayer("mod"); mod.role = "moderator"
local zed = fakePlayer("zed"); zed.x, zed.y = 101, 200; zed.inventory = fakeInventory(200)
onlinePlayers = { boss, mod, zed }
local function cmd(who, name, args)
    nowMs = nowMs + 600
    args = args or {}
    args.requestId = args.requestId or (name .. nowMs)
    withCurrency(name, args)
    fire("OnClientCommand", EC.COMMAND_MODULE, name, who, args)
    local s = lastSent(name)
    return s and s.args or {}
end
local function itemsOf(fullType)
    local out = {}
    for _, it in ipairs(zed.inventory.items) do if it.fullType == fullType then out[#out + 1] = it end end
    return out
end
local function entryOf(mailId) return S.modData().mailbox.byOwner.zed.entries[mailId] end
local function heldOf(key)
    for _, rec in ipairs(Rec.heldRecords("zed")) do if rec.key == key then return rec end end
    return nil
end
local function rowOf(reply, key)
    for _, row in ipairs(reply.records or {}) do if row.key == key then return row end end
    return nil
end
-- 把一封已領取的信件與其實體退化成 Gen0：信件完全沒有 units，物品戳記只有 mailId/txId/epoch/seq
local function degrade(mailId, fullType, epochOverride)
    local entry = entryOf(mailId)
    local n = 0
    for _, it in ipairs(itemsOf(fullType)) do
        local stamp = it.modData[KEY]
        if type(stamp) == "table" and stamp.mailId == mailId then
            it.modData[KEY] = { mailId = entry.id, txId = entry.txId,
                epoch = epochOverride or S.modData().meta.epoch, seq = entry.claimSeq }
            n = n + 1
        end
    end
    entry.units, entry.gen0, entry.outUnits, entry.outQty = nil, nil, nil, nil
    return entry, n
end
cmd(boss, "terminal.register", { x = 100, y = 200, z = 0, kind = "atm" })
L.credit("zed", "survivor", 4000, "SYSTEM_MINT", { requestId = "seed-g0", reasonCode = "t" })
local rev = cmd(zed, "shop.list").revision

-- ---- #4: the source letter is still in the world, claimed, and inside a save ----
local corn = cmd(zed, "shop.buy", { id = "canned_corn", revision = rev })
check(corn.delivered == true and zed.inventory.count("Base.CannedCorn") == 2, "setup: two canned corn delivered normally")
local cornEntry, degraded = degrade(corn.mailId, "Base.CannedCorn")
local claimEpoch, claimSeq = S.modData().meta.epoch, cornEntry.claimSeq
check(degraded == 2 and cornEntry.units == nil and Rec.gen0Stamp(itemsOf("Base.CannedCorn")[1].modData[KEY]),
    "setup: the letter and both objects carry the exact generation zero shape")
check(Rec.gen0Stamp({ mailId = corn.mailId, epoch = claimEpoch, seq = claimSeq, unit = "x" }) == false
    and Rec.gen0Stamp({ mailId = corn.mailId, epoch = claimEpoch, seq = claimSeq, proto = 2 }) == false
    and Rec.gen0Stamp({ mailId = "nope", epoch = claimEpoch, seq = claimSeq }) == false,
    "a stamp carrying a unit, a protocol or an unparseable letter id is never read as generation zero")
nowMs = nowMs + 1000
fire("OnServerStarted")                       -- clean restart: everything above is inside the save
onlinePlayers = { boss, mod, zed }
check(cornEntry.gen0 == true and #cornEntry.units == 2 and cornEntry.units[1] == corn.mailId .. "#1",
    "M.init marks a letter that never had unit tokens and mints its placeholders")
local preBind = deepCopy(modDataStore[EC.MODDATA_KEY])
local cornIds = { itemsOf("Base.CannedCorn")[1].id, itemsOf("Base.CannedCorn")[2].id }
cmd(zed, "hello")
local cornItems = itemsOf("Base.CannedCorn")
local s1, s2 = cornItems[1].modData[KEY], cornItems[2].modData[KEY]
check(s1.proto == Rec.PROTOCOL and s1.owner == "zed" and s1.epoch == claimEpoch and s1.seq == claimSeq
    and s1.unit == corn.mailId .. "#L" .. tostring(cornItems[1].id) and s1.durable == true,
    "#4: an object whose letter is still in the world is named <mailId>#L<nativeId>, keeping the original claim epoch/seq")
check(#cornEntry.units == 2 and cornEntry.qty == 2 and cornEntry.units[1] ~= cornEntry.units[2],
    "binding replaces placeholder slots and never inflates the letter's quantity")
check(M.recoveryStatus("zed").held == 0, "a letter that bound cleanly leaves no held record behind")
local listed = cmd(zed, "market.list", { itemIds = { cornItems[1].id }, price = 50 })
check(listed.ok == true and zed.inventory.count("Base.CannedCorn") == 1,
    "#4: a named generation zero unit can be listed on the market")
check(cornEntry.outUnits[s1.unit] == listed.listingId and cornEntry.outQty == 1,
    "the listing consumes exactly that unit out of its own letter")
local auctioned = cmd(zed, "auction.create", { itemId = cornItems[2].id, startPrice = 30, hours = 24 })
check(auctioned.ok == true and zed.inventory.count("Base.CannedCorn") == 0 and Au.hasAuction(auctioned.auctionId)
    and cornEntry.outUnits[s2.unit] == auctioned.auctionId and cornEntry.outQty == 2,
    "#4: the second named unit can be auctioned, and each unit is consumed exactly once")
nowMs = nowMs + 1000
fire("OnServerStarted")
onlinePlayers = { boss, mod, zed }
cmd(zed, "hello")
check(Mk.hasListing(listed.listingId) and Au.hasAuction(auctioned.auctionId)
    and #entryOf(corn.mailId).units == 2 and entryOf(corn.mailId).outQty == 2,
    "#4: the binding, the listing, the auction and the consumption all survive a restart")

-- ---- both saves roll apart: the world loses the binding, the player keeps the named objects ----
local carried = instanceItem("Base.CannedCorn")
carried.id = 770001                                     -- a rebuild mints a new engine id
carried.modData[KEY] = deepCopy(s1)
zed.inventory:AddItem(carried)
modDataStore[EC.MODDATA_KEY] = deepCopy(preBind)
nowMs = nowMs + 1000
fire("OnServerStarted")
onlinePlayers = { boss, mod, zed }
cmd(zed, "hello")
local rolled = entryOf(corn.mailId)
local member = false
for _, t in ipairs(rolled.units) do if t == s1.unit then member = true end end
check(member and s1.unit == corn.mailId .. "#L" .. tostring(cornIds[1]) and carried.modData[KEY].unit == s1.unit,
    "a world rollback below the binding re-binds the very same token, never one recomputed from the rebuilt object's new id")
check(#rolled.units == 2 and rolled.qty == 2,
    "re-binding puts the token back into a slot the letter already had, at the same slot count")
-- A missing membership is repaired only through the same proof used by login reconciliation.
local stripped = {}
for i, t in ipairs(rolled.units) do stripped[i] = (t == s1.unit) and (corn.mailId .. "#" .. tostring(i)) or t end
rolled.units = stripped
local reListed = cmd(zed, "market.list", { itemIds = { carried.id }, price = 45 })
check(reListed.ok == true and zed.inventory.count("Base.CannedCorn") == 0,
    "an existing claim with an available original slot can rebind safely during listing")
cmd(zed, "hello")
local after = entryOf(corn.mailId)
check(after.outUnits[s1.unit] == reListed.listingId and Mk.ownerCount("zed") == 1,
    "reconciliation after the immediate rebind keeps exactly one listing and one consumed unit")
local available = 0
for _, t in ipairs(after.units) do if (after.outUnits or {})[t] == nil then available = available + 1 end end
check(#after.units == 2 and available == 2 - EC.countKeys(after.outUnits),
    "source.units minus outUnits really is short by the number of units that were transferred out")

-- ---- #2: the claim rolled back with the world - one record per letter, never one per nail ----
modDataStore[EC.MODDATA_KEY] = nil
files = {}
nowMs = nowMs + 61000
fire("OnServerStarted")
zed.inventory = fakeInventory(200)
zed.modData = {}
onlinePlayers = { boss, mod, zed }
cmd(boss, "terminal.register", { x = 100, y = 200, z = 0, kind = "atm" })
L.credit("zed", "survivor", 4000, "SYSTEM_MINT", { requestId = "seed-g1", reasonCode = "t" })
rev = cmd(zed, "shop.list").revision
local nails = cmd(zed, "shop.buy", { id = "nails", revision = rev })
check(nails.delivered == true and zed.inventory.count("Base.Nails") == 20, "setup: twenty nails delivered normally")
local futureEpoch = tostring(tonumber(S.modData().meta.epoch) + 5000)
local nailEntry = degrade(nails.mailId, "Base.Nails", futureEpoch)
S.modData().mailbox.byOwner.zed.entries[nails.mailId] = nil      -- the rolled-back branch took the letter too
zed.modData[KEY].claims[nails.mailId] = { epoch = futureEpoch, seq = nailEntry.claimSeq }
S.modData().meta.history[#S.modData().meta.history + 1] = { epoch = futureEpoch, loadedSeq = nailEntry.claimSeq - 1 }
local moneyBefore = L.getBalance("zed", "survivor").available
local refused = cmd(zed, "market.list", { itemIds = { itemsOf("Base.Nails")[1].id }, price = 40 })
check(refused.ok == false and refused.error == "recovery_unverified" and zed.inventory.count("Base.Nails") == 20
    and L.getBalance("zed", "survivor").available == moneyBefore,
    "#2: a rolled-back generation zero source is still refused, and the refusal moves no object and no coin")
local nailHold = heldOf("legacy:" .. nails.mailId)
check(nailHold ~= nil and nailHold.reason == "legacy_claim_rolledback" and M.recoveryStatus("zed").held == 1,
    "#2: the refusal records one reasoned record for the whole letter, not one per nail")
cmd(zed, "market.list", { itemIds = { itemsOf("Base.Nails")[2].id }, price = 40 })
cmd(zed, "hello")
check(M.recoveryStatus("zed").held == 1 and heldOf("legacy:" .. nails.mailId).at == nailHold.at,
    "repeating the refusal and relogging update the same record instead of stacking new ones")

-- ---- the reconciliation page: who may read, who may act, and on what evidence ----
check(cmd(zed, "admin.recovery", { action = "list", username = "zed" }).error == "forbidden",
    "an ordinary player cannot read anyone's reconciliation records, not even their own account's")
local modView = cmd(mod, "admin.recovery", { action = "list", username = "zed" })
check(modView.ok == true and modView.perms.write == false and modView.total == 1 and modView.page == 1
    and modView.username == "zed" and modView.online == true,
    "a read-only role sees the records, the page and the account, and is told it may not write")
check(cmd(mod, "admin.recovery", { action = "recheck", username = "zed" }).error == "forbidden"
    and cmd(mod, "admin.recovery", { action = "resolve", username = "zed", key = "legacy:" .. nails.mailId,
        decision = "remove", note = "not allowed" }).error == "forbidden",
    "a read-only role may neither recheck nor resolve")
local view = cmd(boss, "admin.recovery", { action = "list", username = "zed" })
local nailRow = rowOf(view, "legacy:" .. nails.mailId)
check(nailRow ~= nil and nailRow.reason == "legacy_claim_rolledback" and nailRow.sourceState == "rolledback"
    and nailRow.presentQty == 20 and #nailRow.nativeIds == 20 and nailRow.item == "Base.Nails",
    "#2: the row names the reason, the source state, the exact object count and the exact engine ids")
check(nailRow.actions.remove == true and nailRow.actions.approve == false
    and nailRow.actions.restore == false and nailRow.actions.discard == false,
    "#2: a rolled-back source may only be removed - it is never approvable at any quantity")
check(type(nailRow.revision) == "string" and string.find(nailRow.revision, "rolledback", 1, true) ~= nil
    and string.find(nailRow.revision, tostring(nailRow.nativeIds[1]), 1, true) ~= nil,
    "the revision is a fingerprint of the evidence itself - the state and the ids, not a quantity")
check(cmd(boss, "admin.recovery", { action = "resolve", username = "zed", key = "legacy:" .. nails.mailId,
        decision = "remove", revision = nailRow.revision }).error == "recovery_reason_required"
    and cmd(boss, "admin.recovery", { action = "resolve", username = "zed", key = "legacy:" .. nails.mailId,
        decision = "remove", revision = nailRow.revision, note = "   " }).error == "recovery_reason_required"
    and zed.inventory.count("Base.Nails") == 20,
    "a decision without a real written reason is refused before anything is touched")
check(cmd(boss, "admin.recovery", { action = "resolve", username = "zed", key = "legacy:" .. nails.mailId,
        decision = "remove", revision = "{}", note = "stale page" }).error == "recovery_stale"
    and zed.inventory.count("Base.Nails") == 20,
    "a decision taken against a stale page is refused and removes nothing")
check(cmd(boss, "admin.recovery", { action = "resolve", username = "zed", key = "legacy:" .. nails.mailId,
        decision = "approve", revision = nailRow.revision, note = "let it through" }).error == "recovery_not_actionable"
    and zed.inventory.count("Base.Nails") == 20,
    "#2: approve is refused for a rolled-back source however the request is shaped")
-- one object is equipped: it is never taken out from under the character
itemsOf("Base.Nails")[1].equipped = true
local guarded = rowOf(cmd(boss, "admin.recovery", { action = "list", username = "zed" }), "legacy:" .. nails.mailId)
check(guarded.actions.remove == false and guarded.blocked == "legacy_item_equipped",
    "an equipped object blocks the removal and the row says which limit it hit")
itemsOf("Base.Nails")[1].equipped = false
-- partial failure: one container refuses to give the object up
local realRemove = zed.inventory.Remove
local spared = itemsOf("Base.Nails")[3]
zed.inventory.Remove = function(self, it) if it ~= spared then realRemove(self, it) end end
local fresh = rowOf(cmd(boss, "admin.recovery", { action = "list", username = "zed" }), "legacy:" .. nails.mailId)
local partial = cmd(boss, "admin.recovery", { action = "resolve", username = "zed", key = "legacy:" .. nails.mailId,
    decision = "remove", revision = fresh.revision, note = "rolled back purchase, reclaiming" })
zed.inventory.Remove = realRemove
check(partial.ok == false and partial.error == "recovery_remove_failed" and partial.stuck == 1 and partial.removed == 19
    and zed.inventory.count("Base.Nails") == 1,
    "a partial removal reports what it actually did and never claims the whole decision succeeded")
local reopened = heldOf("legacy:" .. nails.mailId)
check(reopened ~= nil and reopened.reason == "legacy_claim_rolledback"
    and string.find(tostring(reopened.detail), "1 refused", 1, true) ~= nil,
    "a partly removed record stays open under its own reason, carrying what the attempt actually did")
local again = rowOf(cmd(boss, "admin.recovery", { action = "list", username = "zed" }), "legacy:" .. nails.mailId)
local done = cmd(boss, "admin.recovery", { action = "resolve", username = "zed", key = "legacy:" .. nails.mailId,
    decision = "remove", revision = again.revision, note = "rolled back purchase, reclaiming" })
check(done.ok == true and done.removed == 1 and zed.inventory.count("Base.Nails") == 0
    and M.recoveryStatus("zed").held == 0,
    "#2: the administrator can reclaim the remainder once, and only then is the record closed")
local resend = cmd(boss, "admin.recovery", { action = "resolve", username = "zed", key = "legacy:" .. nails.mailId,
    decision = "remove", revision = again.revision, note = "rolled back purchase, reclaiming" })
check(resend.ok == true and resend.duplicate == true and zed.inventory.count("Base.Nails") == 0,
    "a resend of the decision that already closed the record is a duplicate and costs nothing twice")
check(cmd(boss, "admin.recovery", { action = "resolve", username = "zed", key = "legacy:" .. nails.mailId,
        decision = "approve", revision = again.revision, note = "rolled back purchase, reclaiming" }).error == "recovery_not_actionable",
    "a different decision on a closed record is never quietly accepted as a duplicate")

-- ---- the source is simply gone: no quantity and no owner are ever inferred ----
local twine = cmd(zed, "shop.buy", { id = "twine", revision = rev })
local twineEntry = degrade(twine.mailId, "Base.Twine")
local twineSeq = twineEntry.claimSeq
S.modData().mailbox.byOwner.zed.entries[twine.mailId] = nil
cmd(zed, "hello")
local prunedRow = rowOf(cmd(boss, "admin.recovery", { action = "list", username = "zed" }), "legacy:" .. twine.mailId)
check(prunedRow ~= nil and prunedRow.reason == "legacy_source_pruned" and prunedRow.sourceState == "pruned"
    and prunedRow.presentQty == 1 and prunedRow.qty == 1,
    "a pruned source is reported as pruned with the objects that are actually there, and nothing is guessed")
check(prunedRow.actions.approve == true and prunedRow.actions.remove == false,
    "a pruned source is the one an administrator may accept in writing, and it is never removable on that evidence")
local twineItem = itemsOf("Base.Twine")[1]
local twineId = twineItem.id
local expectedToken = twine.mailId .. "#L" .. tostring(twineId)
local cashBefore, itemsBefore = L.getBalance("zed", "survivor").available, #zed.inventory.items
local approved = cmd(boss, "admin.recovery", { action = "resolve", username = "zed", key = "legacy:" .. twine.mailId,
    decision = "approve", revision = prunedRow.revision, note = "old purchase confirmed in the receipts" })
check(approved.ok == true and approved.approvalToken == expectedToken
    and twineItem.modData[KEY].unit == expectedToken and twineItem.modData[KEY].durable == true
    and twineItem.id == twineId,
    "approve names the object with the deterministic token and never changes its engine id")
check(L.getBalance("zed", "survivor").available == cashBefore and #zed.inventory.items == itemsBefore,
    "approve creates no item and pays out no money")
-- the very same original, resent later under its old stamp, lands back on the same token
twineItem.modData[KEY] = { mailId = twine.mailId, txId = twineEntry.txId, epoch = S.modData().meta.epoch, seq = twineSeq }
cmd(zed, "hello")
local reRow = rowOf(cmd(boss, "admin.recovery", { action = "list", username = "zed" }), "legacy:" .. twine.mailId)
check(reRow ~= nil and reRow.reason == "legacy_source_pruned",
    "an older save resending the original stamp is held for review again, never auto-approved")
local reApproved = cmd(boss, "admin.recovery", { action = "resolve", username = "zed", key = "legacy:" .. twine.mailId,
    decision = "approve", revision = reRow.revision, note = "same old purchase, already confirmed" })
check(reApproved.ok == true and reApproved.approvalToken == expectedToken,
    "the second acceptance of the same original produces the very same token, not a fresh source")
local sold = cmd(zed, "market.list", { itemIds = { twineItem.id }, price = 15 })
check(sold.ok == true and zed.inventory.count("Base.Twine") == 0,
    "an accepted object can be listed, because the acceptance is what makes its unit provable")
local ghost = instanceItem("Base.Twine")
ghost.id = twineItem.id
ghost.modData[KEY] = { mailId = twine.mailId, txId = twineEntry.txId, epoch = S.modData().meta.epoch, seq = twineSeq }
zed.inventory:AddItem(ghost)
cmd(zed, "hello")
local ghostRow = rowOf(cmd(boss, "admin.recovery", { action = "list", username = "zed" }), "legacy:" .. twine.mailId)
local minted = cmd(boss, "admin.recovery", { action = "resolve", username = "zed", key = "legacy:" .. twine.mailId,
    decision = "approve", revision = ghostRow and ghostRow.revision or "", note = "second copy of the same original" })
check(minted.ok == false and ghost.modData[KEY].proto == nil,
    "the same original resent after its unit was transferred out cannot be washed into a new source")
zed.inventory:Remove(ghost)

-- ---- legacy pending records: located, or held with enough detail to act on ----
local hammer = instanceItem("Base.Hammer")
hammer.modData[KEY] = { mailId = corn.mailId, txId = "t:1", epoch = S.modData().meta.epoch, seq = 1 }
zed.inventory:AddItem(hammer)
zed.modData[KEY].pendingOuts["9000:5"] = { itemId = hammer.id, itemIds = { hammer.id }, qty = 1,
    snapshot = { type = "Base.Hammer", condition = 10, uses = 1, age = 0, repaired = 0 },
    kind = "listing", price = 10, seq = 5, epoch = "9000", at = nowMs }
cmd(zed, "hello")
check(zed.modData[KEY].pendingOuts["9000:5"] == nil and zed.inventory.count("Base.Hammer") == 1,
    "a legacy pending whose original still wears its generation zero stamp is located and cleared, not rebuilt into a second copy")
local twin = instanceItem("Base.Hammer")
zed.inventory:AddItem(twin)
twin.id = hammer.id
twin.modData[KEY] = { proto = Rec.PROTOCOL, mailId = corn.mailId, unit = corn.mailId .. "#9",
    owner = "zed", epoch = S.modData().meta.epoch, seq = 1 }
zed.modData[KEY].pendingOuts["9000:7"] = { itemId = hammer.id, itemIds = { hammer.id }, qty = 1,
    snapshot = { type = "Base.Hammer", condition = 10, uses = 1, age = 0, repaired = 0 },
    kind = "listing", price = 10, seq = 7, epoch = "9000", at = nowMs }
cmd(zed, "hello")
check(zed.modData[KEY].pendingOuts["9000:7"] ~= nil and heldOf("pend:9000:7") ~= nil
    and heldOf("pend:9000:7").reason == "native_identity_unverified" and zed.inventory.count("Base.Hammer") == 2,
    "a rebuilt protocol 2 object standing on the original's engine id is an ambiguity, never a licence to clear the record")
zed.inventory:Remove(twin)
zed.inventory:Remove(hammer)
zed.modData[KEY].pendingOuts["9000:7"] = nil
S.modData().meta.history[#S.modData().meta.history + 1] = { epoch = "9000", loadedSeq = 0 }
zed.modData[KEY].pendingOuts["9000:9"] = { itemId = 880001, itemIds = { 880001, 880003 }, qty = 2,
    snapshot = { type = "Base.Plank", condition = 10, uses = 1, age = 0, repaired = 0 },
    kind = "listing", price = 30, seq = 9, epoch = "9000", at = nowMs }
zed.modData[KEY].pendingOuts["9000:11"] = { itemId = 880002, itemIds = { 880002 }, qty = 1,
    snapshot = { type = "Base.Saw", condition = 10, uses = 1, age = 0, repaired = 0 },
    kind = "buyback", price = 35, seq = 11, epoch = "9000", at = nowMs }
cmd(zed, "hello")
local pendRow = rowOf(cmd(boss, "admin.recovery", { action = "list", username = "zed" }), "pend:9000:9")
check(pendRow ~= nil and pendRow.reason == "pending_legacy" and pendRow.item == "Base.Plank" and pendRow.qty == 2
    and pendRow.kind == "listing" and pendRow.presentQty == 0 and pendRow.epoch == "9000" and pendRow.seq == 9
    and #pendRow.nativeIds == 2 and pendRow.nativeIds[1] == 880001 and pendRow.nativeIds[2] == 880003,
    "a legacy pending is reported with its item, quantity, kind, stamp and the ids it looked for - not a bare count")
check(pendRow.actions.restore == true and pendRow.actions.discard == true and pendRow.actions.approve == false
    and pendRow.unproven == true and pendRow.source == "player_claim",
    "a legacy pending that is still missing its origins is the one an administrator may restore or void, and the row says plainly that the only thing vouching for it is the player's own file")
local buybackRow = rowOf(cmd(boss, "admin.recovery", { action = "list", username = "zed" }), "pend:9000:11")
check(buybackRow ~= nil and buybackRow.actions.restore == false and buybackRow.blocked == "legacy_kind_unsafe"
    and buybackRow.actions.discard == true,
    "a buyback already paid for its items, so restoring them is refused outright and the row says why")
local unproved = cmd(boss, "admin.recovery", { action = "resolve", username = "zed", key = "pend:9000:9",
    decision = "restore", revision = pendRow.revision, note = "restoring a legacy pending without saying so" })
check(unproved.ok ~= true and unproved.error == "recovery_unproven_source"
    and M.hasOut("9000:9") == false and M.unclaimed("zed") == 0
    and zed.modData[KEY].pendingOuts["9000:9"] ~= nil,
    "a record from before the journal existed is still only the player's word: the ordinary restore is refused and nothing at all is written")
local restored = cmd(boss, "admin.recovery", { action = "resolve", username = "zed", key = "pend:9000:9",
    decision = "restore", revision = rowOf(cmd(boss, "admin.recovery", { action = "list", username = "zed" }), "pend:9000:9").revision,
    acceptUnproven = true, note = "confirmed lost listing, accepted on the player's word, returning to mailbox" })
check(restored.ok == true and restored.qty == 2 and M.entryOf("zed", restored.mailId) ~= nil
    and M.hasOut("9000:9") == true
    and string.find(tostring(X.auditEntries(5)[1].after), "player_claim/pending_legacy", 1, true) ~= nil,
    "said out loud, the restore goes back through the mailbox return path, leaves the world a deduplicating receipt, and the audit line records whose word it was")
local letters = M.unclaimed("zed")
zed.modData[KEY].pendingOuts["9000:9"] = { itemId = 880001, itemIds = { 880001, 880003 }, qty = 2,
    snapshot = { type = "Base.Plank", condition = 10, uses = 1, age = 0, repaired = 0 },
    kind = "listing", price = 30, seq = 9, epoch = "9000", at = nowMs }
cmd(zed, "hello")
check(M.unclaimed("zed") == letters,
    "an older player save resending the restored pending finds the receipt and never produces a second letter")
local voidRow = rowOf(cmd(boss, "admin.recovery", { action = "list", username = "zed" }), "pend:9000:11")
local voidRefused = cmd(boss, "admin.recovery", { action = "resolve", username = "zed", key = "pend:9000:11",
    decision = "discard", revision = voidRow.revision, note = "voiding a legacy operation without saying so" })
check(voidRefused.ok ~= true and voidRefused.error == "recovery_unproven_source"
    and M.hasOut("9000:11") == false and zed.modData[KEY].pendingOuts["9000:11"] ~= nil,
    "writing a record off is a decision too: without the server's own proof it also has to be said out loud, and until it is nothing is written")
local voided = cmd(boss, "admin.recovery", { action = "resolve", username = "zed", key = "pend:9000:11",
    decision = "discard", acceptUnproven = true,
    revision = rowOf(cmd(boss, "admin.recovery", { action = "list", username = "zed" }), "pend:9000:11").revision,
    note = "operation confirmed void on the player's word, no items to return" })
check(voided.ok == true and zed.modData[KEY].pendingOuts["9000:11"] ~= nil and M.hasOut("9000:11") == true,
    "discard is a decision against the world, not a deletion from one player save")
zed.modData[KEY].pendingOuts["9000:11"] = { itemId = 880002, itemIds = { 880002 }, qty = 1,
    snapshot = { type = "Base.Saw", condition = 10, uses = 1, age = 0, repaired = 0 },
    kind = "buyback", price = 35, seq = 11, epoch = "9000", at = nowMs }
local beforeVoid = M.unclaimed("zed")
cmd(zed, "hello")
nowMs = nowMs + 1000
fire("OnServerStarted")
cmd(zed, "hello")
check(zed.modData[KEY].pendingOuts["9000:11"] == nil and M.unclaimed("zed") == beforeVoid
    and zed.inventory.count("Base.Saw") == 0,
    "a discarded operation stays void at the next login instead of resurrecting itself")

-- ---- retention: the one record a binding reads from is not pruned out from under it ----
local held = cmd(zed, "shop.buy", { id = "ripped_sheets", revision = rev })
local heldEntry = degrade(held.mailId, "Base.RippedSheets")
nowMs = nowMs + 1000
fire("OnServerStarted")
onlinePlayers = { boss, mod, zed }
nowMs = nowMs + M.CLAIMED_TTL_MS + M.PRUNE_EVERY_MS + 1000
fire("OnTickEvenPaused")
check(entryOf(held.mailId) ~= nil and entryOf(held.mailId).gen0 == true,
    "a generation zero letter that still owes an unnamed slot outlives the claimed TTL")
cmd(zed, "hello")
local sheetTokens = 0
for _, it in ipairs(itemsOf("Base.RippedSheets")) do
    if type(it.modData[KEY]) == "table" and it.modData[KEY].proto == Rec.PROTOCOL
        and string.find(tostring(it.modData[KEY].unit), held.mailId .. "#L", 1, true) == 1 then
        sheetTokens = sheetTokens + 1
    end
end
check(#itemsOf("Base.RippedSheets") == 5 and sheetTokens == 5,
    "the retained letter is what lets every one of its objects be named at the next login")
nowMs = nowMs + M.CLAIMED_TTL_MS + M.PRUNE_EVERY_MS + 1000
fire("OnTickEvenPaused")
check(S.modData().mailbox.byOwner.zed == nil or S.modData().mailbox.byOwner.zed.entries[held.mailId] == nil,
    "once every slot is named the letter prunes like any other claimed letter")
check(cmd(boss, "admin.recovery", { action = "resolve", username = "zed" }).error == "invalid_args"
    and cmd(boss, "admin.recovery", { action = "bogus", username = "zed" }).error == "invalid_args",
    "a resolve without a key or a decision is invalid_args, not a guessed action")
onlinePlayers = { boss, mod }
check(cmd(boss, "admin.recovery", { action = "recheck", username = "zed" }).error == "player_offline"
    and cmd(boss, "admin.recovery", { action = "list", username = "zed" }).ok == true,
    "an offline account can still be read, but never rechecked or acted on")
onlinePlayers = {}
end)()

-- ===== 情境四十六：Gen0 綁定的六條反例 =====
io.write("scenario 46: generation zero counter-examples\n")
;(function()
local function deepCopy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = deepCopy(v) end
    return out
end
local M, Mk, Rec = S.Mailbox, S.Market, S.Recovery
local KEY = EC.PLAYER_MODDATA_KEY
modDataStore[EC.MODDATA_KEY] = nil
files = {}
sentCommands = {}
sentItemPackets = {}
worldSprites = { ["100,200,0"] = "MinidoracatEconomy_terminal_0" }
nowMs = nowMs + 61000
fire("OnServerStarted")
local boss = fakePlayer("boss"); boss.role = "admin"
local zed = fakePlayer("zed"); zed.x, zed.y = 101, 200; zed.inventory = fakeInventory(200)
onlinePlayers = { boss, zed }
local function cmd(who, name, args)
    nowMs = nowMs + 600
    args = args or {}
    args.requestId = args.requestId or (name .. nowMs)
    withCurrency(name, args)
    fire("OnClientCommand", EC.COMMAND_MODULE, name, who, args)
    local s = lastSent(name)
    return s and s.args or {}
end
local function itemsOf(fullType, inv)
    local out = {}
    for _, it in ipairs((inv or zed.inventory).items) do
        if it.fullType == fullType then out[#out + 1] = it end
    end
    return out
end
local function entryOf(mailId)
    local o = S.modData().mailbox.byOwner.zed
    return o and o.entries[mailId] or nil
end
local function heldOf(key)
    for _, rec in ipairs(Rec.heldRecords("zed")) do if rec.key == key then return rec end end
    return nil
end
local function heldCount(prefix)
    local n = 0
    for _, rec in ipairs(Rec.heldRecords("zed")) do
        if string.sub(rec.key, 1, #prefix) == prefix then n = n + 1 end
    end
    return n
end
-- 把一封已領取的信件與其實體退化成 Gen0：信件完全沒有 units，戳記只有 mailId/txId/epoch/seq
local function degrade(mailId, fullType, epochOverride)
    local entry = entryOf(mailId)
    local n = 0
    for _, it in ipairs(itemsOf(fullType)) do
        local stamp = it.modData[KEY]
        if type(stamp) == "table" and stamp.mailId == mailId then
            it.modData[KEY] = { mailId = entry.id, txId = entry.txId,
                epoch = epochOverride or S.modData().meta.epoch, seq = entry.claimSeq }
            n = n + 1
        end
    end
    entry.units, entry.gen0, entry.outUnits, entry.outQty = nil, nil, nil, nil
    return entry, n
end
cmd(boss, "terminal.register", { x = 100, y = 200, z = 0, kind = "atm" })
L.credit("zed", "survivor", 6000, "SYSTEM_MINT", { requestId = "seed-g46", reasonCode = "t" })
local rev = cmd(zed, "shop.list").revision

-- ---- 1. 同一封信的兩件實體共用一個原生 id：整封 hold，一件都不改名 ----
-- 根背包一件、袋子裡一件，兩件都是真的資產。如果只看 token，兩件會拿到同一個 #L17，
-- 第二件被當成「已經綁過了」而不占 slot；之後第一件正常上架，下一次登入就會把第二件
-- 當成殘留副本刪掉——兩件合法資產只剩一件。
local corn = cmd(zed, "shop.buy", { id = "canned_corn", revision = rev })
check(corn.delivered == true and zed.inventory.count("Base.CannedCorn") == 2, "setup: two canned corn delivered normally")
local dupEntry = degrade(corn.mailId, "Base.CannedCorn")
local cornPair = itemsOf("Base.CannedCorn")
local bag = instanceItem("Base.Bag_ALICEpack")
bag.inner = fakeInventory(50)
bag.getInventory = function() return bag.inner end
zed.inventory:AddItem(bag)
zed.inventory:Remove(cornPair[2])
bag.inner:AddItem(cornPair[2])
cornPair[2].id = cornPair[1].id                      -- 兩件真物、同一個引擎 id（子袋 + 根背包）
nowMs = nowMs + 1000
fire("OnServerStarted")
onlinePlayers = { boss, zed }
cmd(zed, "hello")
check(zed.inventory.count("Base.CannedCorn") == 1 and #itemsOf("Base.CannedCorn", bag.inner) == 1,
    "two real objects sharing one engine id both survive the login untouched")
check(cornPair[1].modData[KEY].proto == nil and cornPair[2].modData[KEY].proto == nil,
    "neither of them is named: one token cannot stand for two objects")
local dupHold = heldOf("legacy:" .. corn.mailId)
check(dupHold ~= nil and dupHold.reason == "legacy_duplicate_locator" and heldCount("legacy:") == 1,
    "the whole letter is held once, with the reason that its objects cannot be told apart")
check(Rec.gen0Group(Rec.scanUnits(zed.inventory), corn.mailId) == "legacy_duplicate_locator",
    "the group check is what refuses it, and it refuses before any stamp or unit array is touched")
check(cmd(zed, "market.list", { itemIds = { cornPair[1].id }, price = 40 }).error == "recovery_unverified"
    and zed.inventory.count("Base.CannedCorn") == 1,
    "an ambiguous letter cannot be traded out of either, and the refusal moves nothing")
bag.inner.items = {}
zed.inventory:Remove(bag)
zed.inventory.items = {}

-- ---- 2. 信件之後又被領取過一次：#L 不得改名新交付的份額 ----
-- 世界回滾到綁定之前、玩家還帶著 #L 的物件時，只比對 token 前綴就重新綁定，會把「後來那次
-- 領取發出去的現代 #i 份額」改名成這個 #L，等於把別人手上的份額搬走。
local nails = cmd(zed, "shop.buy", { id = "nails", revision = rev })
check(zed.inventory.count("Base.Nails") == 20, "setup: twenty nails delivered normally")
local nailEntry = degrade(nails.mailId, "Base.Nails")
local nailSeq = nailEntry.claimSeq
nowMs = nowMs + 1000
fire("OnServerStarted")
onlinePlayers = { boss, zed }
cmd(zed, "hello")
local firstNail = itemsOf("Base.Nails")[1]
local nailToken = firstNail.modData[KEY].unit
check(type(nailToken) == "string" and nailToken == nails.mailId .. "#L" .. tostring(firstNail.id),
    "setup: the nails are named from their own letter")
local preClaim = deepCopy(modDataStore[EC.MODDATA_KEY])
nailEntry.claimSeq = nailSeq + 7                      -- 這封信之後又被領取過一次
nailEntry.units[1] = nails.mailId .. "#1"             -- 該 slot 已重新發成現代份額
check(Rec.gen0Admit(nailEntry, nailToken, nailSeq, nil, false) == nil,
    "a letter claimed again since refuses the re-binding: the slot belongs to that newer delivery")
cmd(zed, "hello")
local stillThere = false
for _, t in ipairs(nailEntry.units) do if t == nailToken then stillThere = true end end
check(stillThere == false and nailEntry.units[1] == nails.mailId .. "#1",
    "the login does not rename the newer delivery's placeholder into the old token")
check(cmd(zed, "market.list", { itemIds = { firstNail.id }, price = 40 }).error == "recovery_unverified",
    "and the unit whose membership could not be proved is refused rather than traded")
modDataStore[EC.MODDATA_KEY] = deepCopy(preClaim)
nowMs = nowMs + 1000
fire("OnServerStarted")
onlinePlayers = { boss, zed }

-- ---- 3. 唯一 slot 已被別的轉出消耗：帶 #L 的 pending 只能 hold ----
-- 舊 player save 先拿到重送並把該 slot 上架（outUnits 已記），另一個更舊的 save 帶著 #L 的
-- pending 登入。若只因為「信件還在且不是 ready」就判 valid 去 replay，同一份會變成兩份。
local single = cmd(zed, "shop.buy", { id = "twine", revision = rev })
local singleEntry = degrade(single.mailId, "Base.Twine")
nowMs = nowMs + 1000
fire("OnServerStarted")
onlinePlayers = { boss, zed }
cmd(zed, "hello")
local twineItem = itemsOf("Base.Twine")[1]
local twineToken = twineItem.modData[KEY].unit
local sold = cmd(zed, "market.list", { itemIds = { twineItem.id }, price = 20 })
check(sold.ok == true and singleEntry.outUnits[twineToken] == sold.listingId,
    "setup: the letter's only unit is named and then transferred out")
-- 更舊的 save：實體不在背包，pending 帶著另一個 #L（原生 id 不同，所以不是已消耗的那一個）
local ghostToken = single.mailId .. "#L" .. tostring(twineItem.id + 1)
local ghostOrigin = { src = "mail", nativeId = twineItem.id + 1, unit = ghostToken,
    mailId = single.mailId, owner = "zed", epoch = singleEntry.claimSeq and S.modData().meta.epoch or nil,
    seq = singleEntry.claimSeq }
check(Rec.originState(ghostOrigin, "zed") == "unknown",
    "a generation zero token the letter cannot account for is unknown, never valid")
local before = Mk.ownerCount("zed")
zed.modData[KEY].pendingOuts["7000:3"] = { protocol = Rec.PROTOCOL, origins = { ghostOrigin },
    qty = 1, lotQty = 1, snapshot = { type = "Base.Twine", condition = 10, uses = 1, age = 0, repaired = 0 },
    kind = "listing", price = 20, seq = 3, epoch = "7000", at = nowMs }
cmd(zed, "hello")
check(Mk.ownerCount("zed") == before and M.hasOut("7000:3") == false,
    "that pending is never replayed into a second listing or a second receipt")
check(heldOf("pend:7000:3") ~= nil and zed.modData[KEY].pendingOuts["7000:3"] ~= nil,
    "it is held with its record intact instead of being cleared or rebuilt")

-- ---- 4. 來源信仍在世界（錢已付且沒回來）：只有 claim 回滾不等於購買回滾 ----
-- 世界存到「信件已建立、還沒領取」，玩家存到「已領取」。claim 那段回滾了，但購買沒有：
-- 信件就在世界裡。這時把實體當回滾殘留刪掉，錢不會回來，玩家淨損失。
modDataStore[EC.MODDATA_KEY] = nil
files = {}
nowMs = nowMs + 61000
fire("OnServerStarted")
zed.inventory = fakeInventory(200)
zed.modData = {}
onlinePlayers = { boss, zed }
cmd(boss, "terminal.register", { x = 100, y = 200, z = 0, kind = "atm" })
L.credit("zed", "survivor", 6000, "SYSTEM_MINT", { requestId = "seed-g46b", reasonCode = "t" })
rev = cmd(zed, "shop.list").revision
local paid = cmd(zed, "shop.buy", { id = "ripped_sheets", revision = rev })
local paidEntry = degrade(paid.mailId, "Base.RippedSheets")
local paidSeq = paidEntry.claimSeq
-- 世界回到「信件已建立、尚未領取」：claim 沒進存檔，但信件（＝付款證據）進了
paidEntry.state, paidEntry.claimSeq, paidEntry.claimedAt = "ready", nil, nil
S.modData().mailbox.byOwner.zed.unclaimed = S.modData().mailbox.byOwner.zed.unclaimed + 1
S.modData().mailbox.unclaimed = S.modData().mailbox.unclaimed + 1
S.modData().meta.seq = paidSeq - 1
nowMs = nowMs + 1000
fire("OnServerStarted")
onlinePlayers = { boss, zed }
local cashBefore = L.getBalance("zed", "survivor").available
cmd(zed, "hello")
check(zed.inventory.count("Base.RippedSheets") == 5 and L.getBalance("zed", "survivor").available == cashBefore,
    "a claim that rolled back while its paid-for letter is still in the world destroys nothing")
check(entryOf(paid.mailId).state == "claimed" and itemsOf("Base.RippedSheets")[1].modData[KEY].proto == Rec.PROTOCOL,
    "the letter converges to claimed and its objects are named, which is the reconciliation, not a deletion")
check(heldOf("legacy:" .. paid.mailId) == nil,
    "no rolled-back record is raised against a source that is demonstrably still there")

-- ---- 5. 來源信真的沒了、claim 真的回滾：整封一筆，不是每件一筆 ----
local gone = cmd(zed, "shop.buy", { id = "screws", revision = rev })
check(zed.inventory.count("Base.Screws") == 20, "setup: twenty screws delivered normally")
local goneEntry = degrade(gone.mailId, "Base.Screws")
local goneSeq = goneEntry.claimSeq
local rolledEpoch = S.modData().meta.epoch
nowMs = nowMs + 1000
fire("OnServerStarted")                               -- rolledEpoch 進入 history
onlinePlayers = { boss, zed }
local history = S.modData().meta.history
for _, saved in ipairs(history) do
    if saved.epoch == rolledEpoch then saved.loadedSeq = goneSeq - 1 end
end
S.modData().mailbox.byOwner.zed.entries[gone.mailId] = nil
check(S.epochVerdict(rolledEpoch, goneSeq) == "rolledback",
    "setup: the epoch history itself says that claim did not survive")
cmd(zed, "hello")
check(zed.inventory.count("Base.Screws") == 20,
    "a rolled-back generation zero object is never deleted by a login: removing one is a decision, not a side effect")
check(heldCount("legacy:") == 1 and heldCount("unit:") == 0
    and heldOf("legacy:" .. gone.mailId).reason == "legacy_claim_rolledback",
    "twenty objects leave one reasoned record for the whole letter, never one record per object")
cmd(zed, "hello")
check(heldCount("legacy:") == 1 and heldCount("unit:") == 0,
    "relogging keeps it at one record instead of stacking another twenty")

-- ---- 6. 舊 pending 的判讀順序：完成就不能人工退，作廢要落盤才算數 ----
-- 6a 收據裡以 legacy 壓縮過的單位（unit.l）必須還原成 legacy，否則還戴著舊戳記、就在背包裡的
--    原件會被當成 missing，記錄被清掉之後就多出一份。
local sheet = instanceItem("Base.RippedSheets")
zed.inventory:AddItem(sheet)
sheet.modData[KEY] = { mailId = gone.mailId, txId = "t:9", epoch = rolledEpoch, seq = goneSeq }
local compactPend = { itemId = sheet.id, itemIds = { sheet.id }, qty = 1,
    snapshot = { type = "Base.RippedSheets", condition = 10, uses = 1, age = 0, repaired = 0 },
    kind = "listing", price = 10, seq = 4, epoch = "7100", at = nowMs }
S.modData().recovery.ops["7100:4"] = { id = "7100:4", owner = "zed", kind = "listing",
    epoch = S.modData().meta.epoch, seq = S.nextSeq(), at = nowMs, qty = 1, item = "Base.RippedSheets",
    units = { { n = sheet.id, l = true, m = gone.mailId } } }
local compactVerdict = Rec.judgePending("zed", "7100:4", compactPend, Rec.scanUnits(zed.inventory))
check(#compactVerdict.present == 1 and compactVerdict.action == "hold",
    "a legacy receipt locates its stamped original but requires manual review, never automatically deleting a locator match")
S.modData().recovery.ops["7100:4"] = nil
-- 6b 作廢決定尚未落盤時不得清掉玩家端 pending：世界回滾會把決定帶走，紀錄必須還在。
local voidPend = { itemId = 990001, itemIds = { 990001 }, qty = 1,
    snapshot = { type = "Base.Saw", condition = 10, uses = 1, age = 0, repaired = 0 },
    kind = "buyback", price = 35, seq = 6, epoch = "7200", at = nowMs }
Rec.reserveOut("zed", "7200:6")
check(Rec.finishOut("zed", "7200:6", Rec.copyReplay(voidPend), "discard", "7200:6") == true,
    "setup: the void decision is written against the world")
local unsaved = Rec.judgePending("zed", "7200:6", voidPend, Rec.scanUnits(zed.inventory))
check(unsaved.action == "hold" and unsaved.reason == "legacy_discard_unsaved",
    "a void decision that has not reached a save yet holds the player's record instead of clearing it")
nowMs = nowMs + 1000
fire("OnServerStarted")
onlinePlayers = { boss, zed }
local saved = Rec.judgePending("zed", "7200:6", voidPend, Rec.scanUnits(zed.inventory))
check(saved.action == "clear" and saved.reason == "admin_discarded",
    "once that decision is inside a save it is what closes the record, and no login resurrects it")
-- 6c 世界確認沒有這筆刊登、而紀錄本身已落盤 = 當初已售出／已結束，不可人工退回。
local soldPend = { itemId = 990002, itemIds = { 990002 }, qty = 1,
    snapshot = { type = "Base.Saw", condition = 10, uses = 1, age = 0, repaired = 0 },
    kind = "listing", price = 40, seq = goneSeq - 2, epoch = rolledEpoch, at = nowMs }
check(S.epochVerdict(rolledEpoch, soldPend.seq) == "survived",
    "setup: that old record itself did reach a save")
local done = Rec.judgePending("zed", "7300:8", soldPend, Rec.scanUnits(zed.inventory))
check(done.action == "clear" and done.reason == "legacy_completed",
    "a completed old listing is closed, never offered back as a manual return of items that were already sold")
onlinePlayers = {}
end)()
-- 回報 #5/#6：公開候選只列有效賣家，超過200人仍精確計數，且一般玩家可用。
;(function()
    local data = S.modData()
    local marketOwners, auctionOwners, online = data.market.byOwner, data.auctions.byOwner, onlinePlayers
    local privateName = "r8-private-account"
    local privateWallet = data.wallets[privateName]
    data.market.byOwner, data.auctions.byOwner = {}, {}
    data.wallets[privateName] = { survivor = { available = 777, reserved = 0 } }
    for i = 1, 230 do
        data.market.byOwner[string.format("vendor%03d", i)] = { ["listing-" .. i] = true }
    end
    data.auctions.byOwner["auction-vendor"] = { ["auction-one"] = true }
    local reader = fakePlayer("r8-candidate-reader")
    onlinePlayers = { reader, fakePlayer("vendor230"), fakePlayer("vendor005") }
    local function ask(query, context, requestId)
        nowMs = nowMs + 700
        fire("OnClientCommand", EC.COMMAND_MODULE, "market.sellers", reader,
            { query = query, context = context or "market", requestId = requestId or "r8-seller-query" })
        return lastSent("market.sellers").args
    end
    local all = ask("vendor")
    check(all.ok and all.total == 230 and all.truncated == false and #all.players == 30,
        "public seller candidates count every active seller, returning only the bounded display page")
    check(all.players[1].username == "vendor005" and all.players[2].username == "vendor230",
        "online sellers outside the old 200-match prefix still take their correct ordered places")
    local exact = ask("VENDOR230")
    check(exact.ok and exact.total == 1 and exact.players[1].username == "vendor230",
        "ordinary players can find a matching seller anywhere in the active owner set")
    local private = ask("private")
    check(private.ok and private.total == 0 and #private.players == 0,
        "public candidate search does not enumerate accounts from the private wallet table")
    local auctions = ask("vendor", "auction")
    check(auctions.ok and auctions.total == 1 and auctions.players[1].username == "auction-vendor",
        "auction candidates are drawn only from active auction sellers")
    local invalid = ask("vendor", "transactions")
    check(invalid.ok == false and invalid.error == "invalid_args",
        "public seller candidates reject private account-search contexts")
    data.market.byOwner, data.auctions.byOwner, onlinePlayers = marketOwners, auctionOwners, online
    data.wallets[privateName] = privateWallet
end)()
-- ===== 情境四十八：逐筆管理處置的安全邊界 =====
io.write("scenario 48: reconciliation administrative safety boundaries\n")
;(function()
    local M, Mk, Rec = S.Mailbox, S.Market, S.Recovery
    local KEY = EC.PLAYER_MODDATA_KEY
    local serial = 0
    local function fresh()
        modDataStore[EC.MODDATA_KEY], files, sentCommands = nil, {}, {}
        nowMs = nowMs + 61000
        fire("OnServerStarted")
        local boss, p = fakePlayer("r8-boss"), fakePlayer("r8-owner")
        boss.role = "admin"
        p.inventory = fakeInventory(200)
        onlinePlayers = { boss, p }
        return boss, p
    end
    local function cmd(who, command, args)
        nowMs = nowMs + 700; serial = serial + 1
        args = args or {}; args.requestId = args.requestId or "r8-admin-" .. serial
        withCurrency(command, args)
        fire("OnClientCommand", EC.COMMAND_MODULE, command, who, args)
        local answer = lastSent(command)
        assert(answer and answer.args.requestId == args.requestId, "the command must reply to this request")
        return answer.args
    end
    local function record(boss, p, key)
        local res = cmd(boss, "admin.recovery", { action = "list", username = p.username })
        assert(res.ok, "a complete reconciliation snapshot must be available")
        for _, row in ipairs(res.records) do if row.key == key then return row end end
        error("missing record " .. key)
    end
    -- 無證據的申訴（pre-journal 的 pending_legacy）依契約必須明示採納；這裡照那一列自己說的
    -- unproven 決定要不要帶旗標，「不明示就不動」本身另有專條在守，不會因此漏測。
    local function resolve(boss, p, row, decision)
        return cmd(boss, "admin.recovery", { action = "resolve", username = p.username,
            key = row.key, revision = row.revision, decision = decision, note = "reviewed",
            acceptUnproven = row.unproven == true or nil })
    end
    local function oldItem(p, kind, mailId, epoch, seq)
        local item = instanceItem(kind)
        item.modData[KEY] = { mailId = mailId, epoch = epoch, seq = seq }
        p.inventory:AddItem(item)
        return item
    end
    local function hold(p, mailId, epoch, seq, reason)
        Rec.holdGen0(p.username, { mailId = mailId, epoch = epoch, seq = seq,
            reason = reason or "legacy_claim_rolledback", sourceState = "rolledback" })
    end
    local function rollback(epoch)
        local history = S.modData().meta.history
        history[#history + 1] = { epoch = epoch, loadedSeq = 0 }
    end

    do
        local boss, p = fresh()
        rollback("1000")
        local old = oldItem(p, "Base.Axe", "1000:1", "1000", 2)
        local good = instanceItem("Base.Axe")
        good.modData[KEY] = { proto = 2, unit = "1000:1#1", owner = p.username,
            mailId = "1000:1", epoch = S.modData().meta.epoch, seq = S.nextSeq() }
        p.inventory:AddItem(good)
        hold(p, "1000:1", "1000", 2)
        M.reconcile(p)
        local row = record(boss, p, "legacy:1000:1")
        check(row.presentQty == 1 and #row.nativeIds == 1 and row.nativeIds[1] == old.id,
            "a rollback removal targets only the old claim, not a valid new claim sharing its mail id")
        local res = resolve(boss, p, row, "remove")
        check(res.ok and not p.inventory:contains(old) and p.inventory:contains(good),
            "removing the old claim leaves the newer legitimate object untouched")
    end
    do
        local boss, p = fresh()
        rollback("1100")
        local axe = oldItem(p, "Base.Axe", "1100:1", "1100", 2)
        axe.attachedSlot = 0
        hold(p, "1100:1", "1100", 2)
        local row = record(boss, p, "legacy:1100:1")
        check(not row.actions.remove and row.blocked == "legacy_item_equipped",
            "a hotbar-attached object cannot be removed behind its attachment reference")
        check(not resolve(boss, p, row, "remove").ok and p.inventory:contains(axe),
            "a forged remove request cannot bypass the hotbar preflight")
        axe.attachedSlot = -1
        row = record(boss, p, "legacy:1100:1")
        check(resolve(boss, p, row, "remove").ok and not p.inventory:contains(axe),
            "after detaching, the same invalid object can be explicitly reclaimed")
    end
    do
        local boss, p = fresh()
        rollback("1200")
        local bag = oldItem(p, "Base.Bag_ALICEpack", "1200:1", "1200", 2)
        bag.inner = fakeInventory(50); bag.getInventory = function() return bag.inner end
        local keep = instanceItem("Base.Axe"); bag.inner:AddItem(keep)
        hold(p, "1200:1", "1200", 2)
        local row = record(boss, p, "legacy:1200:1")
        check(not row.actions.remove and row.blocked == "legacy_container_not_empty",
            "a nonempty container exposes the reason removal is unavailable")
        check(not resolve(boss, p, row, "remove").ok and bag.inner:contains(keep) and p.inventory:contains(bag),
            "reclaiming a rolled-back bag never deletes unrelated contents")
    end
    do
        local boss, p = fresh()
        local broken = instanceItem("Base.Axe")
        broken.getModData = function() error("unreadable item metadata") end
        p.inventory:AddItem(broken)
        local listed = cmd(boss, "admin.recovery", { action = "list", username = p.username })
        local rechecked = cmd(boss, "admin.recovery", { action = "recheck", username = p.username })
        check(not listed.ok and listed.error == "read_failed" and not rechecked.ok and rechecked.error == "read_failed",
            "an incomplete inventory scan is reported as failed, never as a successful empty recheck")
    end
    do
        local boss, p = fresh()
        local a = oldItem(p, "Base.Axe", "1300:1", "1300", 2)
        local b = oldItem(p, "Base.Axe", "1300:1", "1300", 2)
        hold(p, "1300:1", "1300", 2, "legacy_source_unknown")
        local row = record(boss, p, "legacy:1300:1")
        local data = b.modData
        local readonly = setmetatable({}, { __index = data,
            __newindex = function() error("metadata write unavailable") end })
        b.getModData = function() return readonly end
        b.hasModData = function() return true end
        -- A refused member during approval must not be reported as a whole-group success.
        local res = resolve(boss, p, row, "approve")
        check(res.ok == false and res.error == "recovery_approve_failed"
            and a.modData[KEY].proto == 2 and b.modData[KEY].proto == nil
            and Rec.heldRecord(p.username, row.key).resolvedAt == nil,
            "a partial approval is visibly failed and leaves the remainder unresolved")
    end
    do
        local boss, p = fresh()
        rollback("1400")
        local a = oldItem(p, "Base.Plank", "1400:1", "1400", 2)
        local b = oldItem(p, "Base.Plank", "1400:1", "1400", 2)
        p.inventory:Remove(a); p.inventory:Remove(b)
        Rec.playerData(p).pendingOuts["1400:3"] = { itemId = a.id, itemIds = { a.id, b.id }, qty = 2,
            kind = "listing", price = 20, epoch = "1400", seq = 3, at = nowMs,
            snapshot = { type = "Base.Plank", condition = 10, uses = 1, age = 0, repaired = 0 } }
        M.reconcile(p)
        local row = record(boss, p, "pend:1400:3")
        check(row.actions.restore, "a wholly missing, proven rolled-back old transfer is eligible for reviewed compensation")
        p.inventory:AddItem(a)
        local res = resolve(boss, p, row, "restore")
        check(not res.ok and M.unclaimed(p.username) == 0 and p.inventory:contains(a),
            "a recovered original invalidates the old restore decision before any compensation is issued")
        p.inventory:Remove(a)
        row = record(boss, p, "pend:1400:3")
        res = resolve(boss, p, row, "restore")
        check(res.ok and M.entryOf(p.username, res.mailId).qty == 2,
            "reviewed compensation returns exactly the missing quantity once")
        p.inventory:AddItem(a)
        local other = fakePlayer("r8-other"); other.inventory = fakeInventory(50)
        onlinePlayers[#onlinePlayers + 1] = other
        p.inventory:Remove(a); other.inventory:AddItem(a)
        M.reconcile(other)
        local consumed = Rec.consumer(Rec.originOf(a))
        check(consumed == "1400:3" and other.inventory:contains(a),
            "an original that resurfaces under another owner is held by the compensation receipt, not automatically deleted")
        check(Rec.originState(Rec.originOf(a), other.username) == "unknown",
            "a legacy locator match cannot silently cancel or delete a potentially colliding asset")
        check(not M.beginOut(other, "1400:5", { a }, { kind = "listing", qty = 1, seq = 5, epoch = "1400" }),
            "the resurfaced original cannot be moved into a second listing after compensation")
        a.modData[KEY] = nil
        local nativeOrigin = Rec.originOf(a)
        check(Rec.consumer(nativeOrigin) == "1400:3" and Rec.originState(nativeOrigin, other.username) == "unknown",
            "an unstamped original under another owner is still held by its legacy compensation receipt")
        check(not M.beginOut(other, "1400:7", { a }, { kind = "listing", qty = 1, seq = 7, epoch = "1400" })
            and other.inventory:contains(a),
            "an unstamped resurfaced original cannot be sold twice and is never deleted on its locator alone")
        local wrongType = oldItem(other, "Base.Axe", "1500:1", "1500", 2)
        wrongType.id = a.id
        check(Rec.consumer(Rec.originOf(wrongType)) == nil,
            "a different item type with the same native id is not mistaken for the compensated original")
    end
    do
        local boss, p = fresh()
        worldSprites = { ["100,200,0"] = "MinidoracatEconomy_terminal_0" }
        cmd(boss, "terminal.register", { x = 100, y = 200, z = 0, kind = "atm" })
        L.credit(p.username, "survivor", 100, "SYSTEM_MINT", { requestId = "r8-split-seed", reasonCode = "t" })
        local parent = M.add(p.username, { kind = "return", item = "Base.Bandage", qty = 2,
            units = { "1800:1#L17", "1800:1#L18" } })
        local add, remove, calls = p.inventory.AddItem, p.inventory.Remove, 0
        p.inventory.AddItem = function(inv, item)
            calls = calls + 1
            if calls == 2 then return nil end
            return add(inv, item)
        end
        p.inventory.Remove = function() error("partial delivery rollback failed") end
        local claimed = M.claim(p, parent.id)
        p.inventory.AddItem, p.inventory.Remove = add, remove
        check(claimed.error == "delivery_partial" and p.inventory.count("Base.Bandage") == 1,
            "an inherited legacy token can be delivered as a confirmed partial child")
        local item = p.inventory.items[1]
        local child = M.entryOf(p.username, claimed.childMailId)
        check(child ~= nil and child.units[1] == item.modData[KEY].unit
            and Rec.originState(Rec.originOf(item), p.username) == "valid",
            "exact child membership proves an inherited token without pretending the child is the original Gen0 letter")
        local listed = cmd(p, "market.list", { itemId = item.id, price = 10 })
        check(listed.ok == true and child.outUnits[item.modData[KEY].unit] == listed.listingId
            and p.inventory.count("Base.Bandage") == 0,
            "a legitimate partial child can be listed and consumes exactly its inherited unit")
    end
    do
        local boss, p = fresh()
        local modern = { protocol = Rec.PROTOCOL, origins = { { src = "native", nativeId = 99009 } },
            itemIds = { 99009 }, qty = 1, snapshot = { type = "Base.Plank" }, kind = "listing",
            epoch = "1900", seq = 2, at = nowMs - 1000 }
        Rec.playerData(p).pendingOuts["1900:2"] = modern
        S.modData().recovery.floorAt = nowMs
        Rec.hold(p.username, "pend:1900:2", "receipt_forgotten", { opId = "1900:2" })
        local row = record(boss, p, "pend:1900:2")
        check(not row.actions.restore and not row.actions.discard,
            "modern transfers with missing receipts remain outside the legacy manual override path")
    end
end)()
-- ===== 情境四十九：來源拒絕說得出是哪一件、哪一個判斷 =====
--
-- 貼法：整段（含 io.write 那行）貼進 scripts/smoke_harness.lua 任一情境之後、下一個
-- `-- ===== 情境 ... =====` 之前即可；只用 harness 既有的全域 helper（check / fakePlayer /
-- instanceItem / fakeInventory / lastSent / fire / nowMs / L / S / EC / modDataStore /
-- worldSprites / SandboxVars），不新增 harness 本體的任何函式。
-- 本段新增 21 個 check，EXPECTED_ASSERTIONS 由 Main 統一調整。
--
-- 反例是刻意有限的：每個 beginOut 拒絕分支各一個，加上「成功不留 detail」與「同一個 error
-- code 的不同根因分得開」。要證的事情只有一件：同一句 recovery_unverified 底下的四種問題，
-- 回覆裡要能看出是哪一件實體、哪一封信／哪一筆作業、目前的存檔判斷是什麼、下一步是什麼。
io.write("scenario 49: refusal detail on list-out refusals\n")
;(function()
local Mk, Au, M, Shop, R = S.Market, S.Auction, S.Mailbox, S.Shop, S.Recovery
local KEY = EC.PLAYER_MODDATA_KEY
modDataStore[EC.MODDATA_KEY] = nil
files, sentCommands, sentItemPackets = {}, {}, {}
worldSprites = { ["100,200,0"] = "MinidoracatEconomy_terminal_0" }
nowMs = nowMs + 61000
fire("OnServerStarted")
local boss = fakePlayer("boss"); boss.role = "admin"
local ann = fakePlayer("ann"); ann.x, ann.y = 101, 200; ann.inventory = fakeInventory(200)
onlinePlayers = { boss, ann }
local function cmd(who, name, args)
    nowMs = nowMs + 600
    args = args or {}
    args.requestId = args.requestId or (name .. nowMs)
    withCurrency(name, args)
    fire("OnClientCommand", EC.COMMAND_MODULE, name, who, args)
    local s = lastSent(name)
    return s and s.args or {}
end
local function native(fullType)
    local it = instanceItem(fullType)
    ann.inventory:AddItem(it)
    return it
end
local function put(item, t) item:getModData()[KEY] = t end
local function det(res) return type(res.recoveryDetail) == "table" and res.recoveryDetail or {} end
local function bal() return L.getBalance("ann", "survivor").available end
local function axes() return ann.inventory.count("Base.Axe") end
local function list(item, price) return cmd(ann, "market.list", { itemId = item.id, price = price or 100 }) end
local function rec1() return { qty = 1, seq = 1, epoch = S.modData().meta.epoch, at = nowMs } end
cmd(boss, "terminal.register", { x = 100, y = 200, z = 0, kind = "atm" })
L.credit("ann", "survivor", 1000, "SYSTEM_MINT", { requestId = "s-ann-39", reasonCode = "t" })

-- 0. 成功的上架完全不帶 detail：拒絕用的欄位不能污染正常回覆
local axe0 = native("Base.Axe")
local ok0 = list(axe0, 100)
check(ok0.ok == true and ok0.recoveryDetail == nil, "a listing that succeeds carries no refusal detail")

-- 1. 收據已經消耗掉的 unit：說出是哪一筆作業消耗的、哪一件實體
local axe1 = native("Base.Axe")
put(axe1, { proto = 2, src = "native", unit = ok0.listingId .. "#1", owner = "ann",
    epoch = S.modData().meta.epoch, seq = 1 })
local coins1, count1 = bal(), axes()
local r1 = list(axe1)
local d1 = det(r1)
check(r1.ok == false and r1.error == "recovery_conflict" and d1.reason == "unit_already_consumed"
    and d1.opId == ok0.listingId and d1.item == "Base.Axe" and d1.itemId == axe1.id and d1.index == 1
    and d1.action == "admin_review",
    "a unit an existing receipt consumed names that operation and the very object it was refused on")
check(bal() == coins1 and axes() == count1 and ann.inventory:contains(axe1),
    "the refused listing moved no item and charged no fee")

-- 2. 另一筆未完成的轉出已經指向這件實體：等存檔判定，不是丟給管理員
local axe2 = native("Base.Axe")
local p = ann.modData[KEY]
p.pendingOuts["9999:7"] = { kind = "listing", qty = 1, price = 10, seq = 7, epoch = "9999", at = nowMs,
    origins = { { src = "native", nativeId = axe2.id, unit = "9999:7#1", owner = "ann",
        epoch = "9999", seq = 7, item = "Base.Axe" } } }
local d2 = det(list(axe2))
check(d2.reason == "unit_in_pending_operation" and d2.opId == "9999:7" and d2.index == 1
    and d2.itemId == axe2.id and d2.action == "wait_save",
    "an object another unfinished operation already claims names that operation and waits for a save")

-- 3. 待確認作業達到上限：說出還有幾筆在等，而且一筆證據都沒有被擠掉
p.pendingOuts["9999:7"].origins[1].nativeId = -12345      -- 不再與手上的物品衝突
local savedMax = R.PENDING_MAX
R.PENDING_MAX = 1
local openBefore = EC.countKeys(p.pendingOuts)
local r3 = list(axe2)
R.PENDING_MAX = savedMax
local d3 = det(r3)
check(r3.error == "recovery_pending" and d3.reason == "pending_cap_unconfirmed" and d3.qty == openBefore
    and d3.action == "wait_save" and EC.countKeys(p.pendingOuts) == openBefore,
    "the pending bound reports how many operations are still unconfirmed and evicts none of them")

-- 4. 待人工對帳的紀錄達到上限：和上面那個「上限」不是同一句話
R.hold("ann", "n5:fixture", "inventory_unreadable", { detail = "fixture" })
local savedHeld = R.HELD_LIMIT
R.HELD_LIMIT = 1
local d4 = det(list(axe2))
R.HELD_LIMIT = savedHeld
R.resolveHold("ann", "n5:fixture", "fixture removed")
check(d4.reason == "held_limit_reached" and d4.qty == 1 and d4.action == "admin_review"
    and d4.reason ~= d3.reason,
    "the held-record bound is its own reason with its own count, not the pending bound's sentence")

-- 5. 讀不全的戳記：壞的是這個 mod 寫上去的資料，不是物品種類
local axe5 = native("Base.Axe")
put(axe5, { proto = 2, mailId = "1:1", unit = "1:1#1" })   -- 缺 owner/epoch/seq，也不是 gen0 形狀
local r5 = list(axe5)
local d5 = det(r5)
check(r5.error == "recovery_unverified" and d5.reason == "item_stamp_malformed" and d5.item == "Base.Axe"
    and d5.itemId == axe5.id and d5.action == "admin_review" and d5.verdict == nil,
    "a protocol 2 stamp that cannot be read in full is named as the stamp, never as a broken item type")

-- 6. 來源信件還在，但它已經不欠這一件
local parcel = M.add("ann", { item = "Base.Bandage", qty = 2, kind = "shop" })
local claimed = M.claim(ann, parcel.id)
local band = nil
for _, it in ipairs(ann.inventory.items) do
    if band == nil and it.fullType == "Base.Bandage" then band = it end
end
check(claimed.ok == true and band ~= nil and type(band:getModData()[KEY]) == "table",
    "setup: a claimed letter stamped its bandages with unit tokens")
local st = band:getModData()[KEY]
local realUnit = st.unit
st.unit = parcel.id .. "#99"
local r6 = list(band, 20)
st.unit = realUnit
local d6 = det(r6)
check(r6.error == "recovery_unverified" and d6.reason == "source_membership_missing"
    and d6.mailId == parcel.id and d6.item == "Base.Bandage" and d6.index == 1
    and d6.action == "admin_review",
    "a letter that no longer owes this unit is named as that letter, not as an unverifiable source")

-- 7. 來源信件還在領取流程中：這是玩家自己走得完的下一步
local entry = M.entryOf("ann", parcel.id)
entry.state = "ready"
local r7 = list(band, 20)
entry.state = "claimed"
local d7 = det(r7)
check(r7.error == "recovery_pending" and d7.reason == "source_claim_pending" and d7.mailId == parcel.id
    and d7.action == "retry",
    "a letter still being claimed is a retry the player can finish, not an administrator's problem")
local other = fakePlayer("source-owner")
local foreign = M.add(other.username, { item = "Base.Bandage", qty = 1, kind = "shop" })
assert(M.claim(other, foreign.id).ok)
local shared = other.inventory.items[1]
other.inventory:Remove(shared); ann.inventory:AddItem(shared)
local savedStamp = shared.modData[KEY]
foreign.state = "ready"
local foreignReply = list(shared, 20)
check(det(foreignReply).reason == "source_claim_pending" and det(foreignReply).action == "admin_review"
    and det(foreignReply).owner == nil,
    "a holder cannot be told to claim another player's mailbox or receive that player's identity")
put(shared, { mailId = foreign.id, epoch = savedStamp.epoch, seq = savedStamp.seq, txId = savedStamp.txId })
local foreignLegacy = list(shared, 20)
check(det(foreignLegacy).reason == "legacy_source_unclaimed" and det(foreignLegacy).action == "admin_review",
    "an older shared item also routes its inaccessible source claim to administrative review")
put(shared, { proto = R.PROTOCOL, mailId = foreign.id, unit = foreign.id .. "#L" .. tostring(shared.id),
    owner = other.username, epoch = savedStamp.epoch, seq = savedStamp.seq })
local foreignAdopted = list(shared, 20)
check(det(foreignAdopted).reason == "legacy_source_unclaimed" and det(foreignAdopted).action == "admin_review",
    "a shared adopted token with missing membership cannot tell its holder to claim the source owner's mailbox")
foreign.state = "claimed"; shared.modData[KEY] = savedStamp

-- 8. 來源信件不在了，領取的 epoch 也超出歷史：判斷是「無法判斷」
local axe8 = native("Base.Axe")
put(axe8, { proto = 2, mailId = "9999:1", unit = "9999:1#1", owner = "ann", epoch = "9999", seq = 1 })
local r8 = list(axe8)
local d8 = det(r8)
check(r8.error == "recovery_unverified" and d8.reason == "source_outcome_unknown" and d8.verdict == "unknown"
    and d8.epoch == "9999" and d8.seq == 1 and d8.mailId == "9999:1" and d8.action == "admin_review",
    "a source that is gone with an epoch past the history answers unknown and carries the claim it read")

-- 9. 一樣是來源信件不在，但這次那次領取確實被回滾過
local meta = S.modData().meta
if type(meta.history) ~= "table" then meta.history = {} end
meta.history[#meta.history + 1] = { epoch = "n5rolled", loadedSeq = 0 }
local axe9 = native("Base.Axe")
put(axe9, { proto = 2, mailId = "n5rolled:5", unit = "n5rolled:5#1", owner = "ann", epoch = "n5rolled", seq = 5 })
local r9 = list(axe9)
local d9 = det(r9)
check(r9.error == "recovery_unverified" and d9.reason == "source_claim_rolledback" and d9.verdict == "rolledback"
    and d9.seq == 5 and d9.action == "admin_review",
    "a rolled-back claim is its own answer instead of the same sentence as an unknown one")

-- 10. 同一個 error code、四種根因：分得開，而且沒有一種被說成「物品 ID 壞掉」
check(d5.reason ~= d6.reason and d6.reason ~= d8.reason and d8.reason ~= d9.reason
    and d8.verdict ~= d9.verdict and d8.reason ~= "item_stamp_malformed" and d9.reason ~= "item_stamp_malformed",
    "four root causes behind one recovery_unverified code stay distinguishable")
check(d7.action == "retry" and d2.action == "wait_save" and d8.action == "admin_review"
    and d9.action ~= "retry" and d8.action ~= "retry",
    "the three next steps stay apart: retry, wait for a save and manual review are never swapped")

-- 11. 引擎 id 讀不到 vs modData 讀不到：兩種不同的讀取失敗，都還說得出是哪一件
local axeA = native("Base.Axe")
local realGetID = axeA.getID
axeA.getID = function() error("engine id unreadable") end
local okA, errA, dA = M.beginOut(ann, "n5:1", { axeA }, rec1())
axeA.getID = realGetID
check(okA == false and errA == "recovery_unverified" and dA.reason == "item_locator_unreadable"
    and dA.item == "Base.Axe" and dA.index == 1 and dA.itemId == nil and dA.action == "retry",
    "an unreadable engine id still names the item and never claims the item type is broken")
local axeB = native("Base.Axe")
local realGetModData = axeB.getModData
axeB.getModData = function() error("mod data unreadable") end
local okB, errB, dB = M.beginOut(ann, "n5:2", { axeB }, rec1())
axeB.getModData = realGetModData
check(okB == false and errB == "recovery_unverified" and dB.reason == "item_stamp_unreadable"
    and dB.action == "retry" and dB.reason ~= dA.reason,
    "an unreadable stamp is a different refusal from an unreadable engine id")

-- 12. 同一個作業 id 還在進行中
local axeC = native("Base.Axe")
local okC, errC, dC = M.beginOut(ann, ok0.listingId, { axeC }, rec1())
check(okC == false and errC == "recovery_pending" and dC.reason == "operation_in_flight"
    and dC.opId == ok0.listingId and dC.action == "retry",
    "a second begin on an operation the player save already carries names that operation")

-- 13. 兩件實體戴同一個 unit token：這是重複，不是來源不明
local axeD, axeE = native("Base.Axe"), native("Base.Axe")
local dupToken = "n5dup:1#1"
put(axeD, { proto = 2, src = "native", unit = dupToken, owner = "ann", epoch = S.modData().meta.epoch, seq = 1 })
put(axeE, { proto = 2, src = "native", unit = dupToken, owner = "ann", epoch = S.modData().meta.epoch, seq = 1 })
local okD, errD, dD = M.beginOut(ann, "n5:3", { axeD, axeE },
    { qty = 2, seq = 1, epoch = S.modData().meta.epoch, at = nowMs })
check(okD == false and errD == "recovery_conflict" and dD.reason == "duplicate_unit" and dD.index == 2
    and dD.itemId == axeE.id and dD.action == "retry",
    "two objects wearing one token are refused as a duplicate, naming the second object")

-- 14. auction.create 與 shop.sell 帶同一份 detail，而且物品與錢都沒動
local axeF = native("Base.Axe")
put(axeF, { proto = 2, mailId = "9999:2", unit = "9999:2#1", owner = "ann", epoch = "9999", seq = 2 })
local coinsF, axesF = bal(), axes()
local rAu = cmd(ann, "auction.create", { itemId = axeF.id, startPrice = 100, hours = 24 })
local dAu = det(rAu)
check(rAu.ok == false and dAu.reason == "source_outcome_unknown" and dAu.itemId == axeF.id
    and dAu.action == "admin_review" and bal() == coinsF and axes() == axesF,
    "auction.create reports the same refusal detail and charges no listing fee")
SandboxVars.MinidoracatEconomy.ShopBuybackEnabled = true
SandboxVars.MinidoracatEconomy.ShopBuybackPerAccountDaily = 200
SandboxVars.MinidoracatEconomy.ShopBuybackServerDaily = 250
cmd(boss, "admin.catalog", { action = "set", id = "axe", buybackCap = 4, prices = { survivor = { bidPrice = 60, buyback = true } } })
local rSell = cmd(ann, "shop.sell", { id = "axe", itemIds = { axeF.id }, revision = Shop.revision() })
local dS = det(rSell)
check(rSell.ok == false and dS.reason == "source_outcome_unknown" and dS.mailId == "9999:2"
    and bal() == coinsF and ann.inventory:contains(axeF),
    "shop.sell refuses the same object with the same detail and mints nothing")
SandboxVars.MinidoracatEconomy.ShopBuybackEnabled = nil
SandboxVars.MinidoracatEconomy.ShopBuybackPerAccountDaily = nil
SandboxVars.MinidoracatEconomy.ShopBuybackServerDaily = nil

-- 15. 這一長串拒絕之後，正常請求照樣成功，而且回覆是乾淨的
local axeG = native("Base.Axe")
local okG = list(axeG, 110)
check(okG.ok == true and okG.error == nil and okG.recoveryDetail == nil,
    "after every refusal above, an ordinary listing still succeeds with nothing attached to it")
onlinePlayers = {}
end)()
-- ===== 情境五十：來源建立回滾後的安全自動結案 =====
io.write("scenario 50: source creation rollback convergence\n")
;(function()
    local M, Mk, Rec = S.Mailbox, S.Market, S.Recovery
    local KEY = EC.PLAYER_MODDATA_KEY
    local function copy(value)
        if type(value) ~= "table" then return value end
        local out = {}; for k, v in pairs(value) do out[k] = copy(v) end
        return out
    end
    local function fresh()
        modDataStore[EC.MODDATA_KEY], files, sentCommands = nil, {}, {}
        nowMs = nowMs + 61000; fire("OnServerStarted")
        local boss, p = fakePlayer("n5-boss"), fakePlayer("n5-player")
        boss.role = "admin"; p.inventory = fakeInventory(100)
        onlinePlayers = { boss, p }
        worldSprites = { ["100,200,0"] = "MinidoracatEconomy_terminal_0" }
        nowMs = nowMs + 700
        fire("OnClientCommand", EC.COMMAND_MODULE, "terminal.register", boss, { x = 100, y = 200, z = 0, kind = "atm" })
        return p
    end
    local function cmd(p, name, args)
        nowMs = nowMs + 700; args = args or {}; args.requestId = name .. nowMs
        withCurrency(name, args)
        fire("OnClientCommand", EC.COMMAND_MODULE, name, p, args)
        local result = lastSent(name)
        assert(result and result.args.requestId == args.requestId, "this request must receive its own answer")
        return result.args
    end
    do
        local p = fresh()
        L.credit(p.username, "survivor", 100, "SYSTEM_MINT", { requestId = "n5-seed", reasonCode = "t" })
        local saved = copy(S.modData())
        local revision = S.Shop.revision()
        local bought = cmd(p, "shop.buy", { id = "canned_corn", revision = revision })
        assert(bought.ok and p.inventory.count("Base.CannedCorn") == 2, "two new corn items were delivered")
        local ids = {}; for _, item in ipairs(p.inventory.items) do ids[#ids + 1] = item.id end
        local listed = cmd(p, "market.list", { itemIds = ids, price = 10 })
        assert(listed.ok and p.inventory.count("Base.CannedCorn") == 0, "the delivery was transferred to a listing")
        proofSettle()                       -- 證據要真的落盤：journal 在檔案層，不隨 ModData 回滾
        modDataStore[EC.MODDATA_KEY] = saved
        nowMs = nowMs + 1000; fire("OnServerStarted"); onlinePlayers = { p }
        Rec.hold(p.username, "pend:" .. listed.listingId, "origin_unverified", { opId = listed.listingId })
        M.reconcile(p)
        proofPump(p.username)               -- 證據查詢是非同步的：有界 pump 到這個帳號讀取收斂
        check(p.modData[KEY].pendingOuts[listed.listingId] == nil and M.recoveryStatus(p.username).held == 0,
            "when creation, claim and listing all rolled back, the missing derived transfer closes automatically")
        check(not Mk.listingExists(listed.listingId) and p.inventory.count("Base.CannedCorn") == 0
            and M.unclaimed(p.username) == 0 and L.getBalance(p.username, "survivor").available == 100,
            "automatic closure creates no item, listing or refund: the saved balance is already authoritative")
        M.reconcile(p)
        proofPump(p.username)
        check(M.recoveryStatus(p.username).held == 0 and p.inventory.count("Base.CannedCorn") == 0,
            "repeated reconciliation does not resurrect the void source chain")
    end
    -- 這一組要測的是「來源那一端到底有沒有活下來」，所以待處理作業本身必須是**有證據的**：
    -- 伺服器手上要有一行自己寫過的、內容與 pending 一致的紀錄，判定才會走到來源那一關。
    -- 沒有這一行的話，測到的是「玩家自己說的事沒有任何佐證」，那是另一回事，而且新契約下
    -- 光憑玩家那份就取消一筆作業本來就是禁止的。作業 id 用得出得來的 epoch:seq，讓真的
    -- producer 派生得出檔名；來源那一端是否算「創建於存檔水位之前」仍由 meta.history 決定。
    local oldEpoch = tostring(nowMs - 86400000)
    local goneEpoch = tostring(nowMs - 172800000)   -- 不在 history 裡：根本查不到的根
    local oldOp = oldEpoch .. ":200"
    local function oldId(seq) return oldEpoch .. ":" .. seq end
    local function pendingCase(origin, prepare)
        local p = fresh()
        S.modData().meta.history[#S.modData().meta.history + 1] = { epoch = oldEpoch, loadedSeq = 117 }
        local pend = { protocol = Rec.PROTOCOL, origins = { origin }, qty = 1, lotQty = 1,
            snapshot = { type = "Base.Bandage", condition = 10, uses = 1, age = 0, repaired = 0 },
            kind = "listing", price = 10, epoch = oldEpoch, seq = 200, at = nowMs }
        Rec.playerData(p).pendingOuts[oldOp] = pend
        assert(proofJournalEmit(p.username, oldOp, oldEpoch, 200, pend))
        if prepare then prepare(p) end
        M.reconcile(p)
        proofPump(p.username)
        return p
    end
    local function origin(mailId, token, parent, reference)
        return { src = "mail", owner = "n5-player", mailId = mailId, unit = token,
            parentMailId = parent, srcRef = reference, epoch = oldEpoch, seq = 190 }
    end
    local p = pendingCase(origin(oldId(116), oldId(116) .. "#1"))
    check(p.modData[KEY].pendingOuts[oldOp] ~= nil and M.recoveryStatus(p.username).held > 0,
        "a claim rollback alone cannot cancel a source created before the save watermark")
    p = pendingCase(origin(oldId(132), goneEpoch .. ":10#1", oldId(130)))
    check(p.modData[KEY].pendingOuts[oldOp] ~= nil,
        "a nested split with an unknown root is held instead of treated as wholly rolled back")
    p = pendingCase(origin(oldId(132), oldId(116) .. "#1", oldId(130)))
    check(p.modData[KEY].pendingOuts[oldOp] ~= nil,
        "a split whose root creation survived cannot be voided by the newer child's rollback")
    p = pendingCase(origin(oldId(132), oldId(132) .. "#1", nil, oldId(99)))
    check(p.modData[KEY].pendingOuts[oldOp] ~= nil,
        "return-mail ids are excluded because recovery may reuse their original identifiers")
    p = pendingCase(origin(oldId(132), oldId(128) .. "#1", oldId(130)))
    check(p.modData[KEY].pendingOuts[oldOp] == nil and M.unclaimed(p.username) == 0,
        "a fully absent nested split closes only when every source creation is proven rolled back")
    p = pendingCase(origin(oldId(132), oldId(128) .. "#1", oldId(130)), function(who)
        M.add(who.username, { item = "Base.Bandage", qty = 1, kind = "return" }, oldId(128))
    end)
    check(p.modData[KEY].pendingOuts[oldOp] ~= nil and M.entryOf(p.username, oldId(128)) ~= nil,
        "an extant root letter wins over an old creation watermark and remains claimable")
    p = pendingCase(origin(oldId(132), oldId(132) .. "#L17"))
    check(p.modData[KEY].pendingOuts[oldOp] ~= nil,
        "adopted legacy locator tokens are not treated as proven original delivery creation chains")
    p = pendingCase(origin(oldId(132), nil))
    check(p.modData[KEY].pendingOuts[oldOp] ~= nil,
        "a malformed source with no stable token is never automatically closed")
end)()
-- ===== 情境五十一：全服待對帳總覽（admin.recovery action = overview） =====
io.write("scenario 51: server-wide reconciliation overview\n")
;(function()
    local Rec = S.Recovery
    local KEY = EC.PLAYER_MODDATA_KEY
    modDataStore[EC.MODDATA_KEY], files, sentCommands = nil, {}, {}
    nowMs = nowMs + 61000
    fire("OnServerStarted")
    local serial = 0
    local function cmd(who, command, args)
        nowMs = nowMs + 700; serial = serial + 1
        args = args or {}; args.requestId = args.requestId or "ov-" .. serial
        withCurrency(command, args)
        fire("OnClientCommand", EC.COMMAND_MODULE, command, who, args)
        local answer = lastSent(command)
        assert(answer and answer.args.requestId == args.requestId, "the command must reply to this request")
        return answer.args
    end
    local function accountOf(res, name)
        for _, account in ipairs(res.accounts or {}) do
            if account.username == name then return account end
        end
        return nil
    end
    local function rowOf(res, key)
        for _, row in ipairs(res.records or {}) do if row.key == key then return row end end
        return nil
    end
    local function noAction(row)
        return row ~= nil and row.actions.approve == false and row.actions.remove == false
            and row.actions.restore == false and row.actions.discard == false
    end

    local boss = fakePlayer("ov-boss"); boss.role = "admin"
    local reader = fakePlayer("ov-reader"); reader.role = "moderator"
    local plain = fakePlayer("ov-plain")
    local live = fakePlayer("ov-live"); live.inventory = fakeInventory(50)
    local broken = fakePlayer("ov-broken"); broken.inventory = fakeInventory(50)
    local busy = fakePlayer("ov-busy"); busy.inventory = fakeInventory(50)
    onlinePlayers = { boss, reader, plain, live, broken, busy }

    -- ov-live: one generation zero object whose claim rolled back (the one row with a real
    -- decision on it) plus two records of an operation this server cannot judge.
    local history = S.modData().meta.history
    history[#history + 1] = { epoch = "5100", loadedSeq = 0 }
    local axe = instanceItem("Base.Axe")
    axe.modData[KEY] = { mailId = "5100:9", epoch = "5100", seq = 2 }
    live.inventory:AddItem(axe)
    Rec.holdGen0("ov-live", { mailId = "5100:9", epoch = "5100", seq = 2,
        reason = "legacy_claim_rolledback", sourceState = "rolledback" })
    Rec.hold("ov-live", "pend:5300:1", "pending_legacy", { opId = "5300:1" })
    Rec.hold("ov-live", "pend:5300:2", "pending_legacy", { opId = "5300:2" })
    -- ov-broken: online, one record, and an object whose metadata cannot be read.
    Rec.hold("ov-broken", "pend:5100:1", "receipt_forgotten", { opId = "5100:1" })
    local unreadable = instanceItem("Base.Axe")
    unreadable.getModData = function() error("unreadable item metadata") end
    broken.inventory:AddItem(unreadable)
    -- ov-gone: offline with two records. ov-many: offline with a page and a bit of them.
    Rec.hold("ov-gone", "pend:5100:2", "pending_legacy", { opId = "5100:2" })
    Rec.hold("ov-gone", "pend:5100:3", "pending_legacy", { opId = "5100:3" })
    for i = 1, 22 do
        local key = i < 10 and ("pend:5200:0" .. i) or ("pend:5200:" .. i)
        Rec.hold("ov-many", key, "pending_legacy", { opId = "5200:" .. i })
    end
    -- ov-busy: nothing held, but two transfers of its own save are still open.
    busy.modData[KEY] = { claims = {}, pendingOuts = { ["5400:1"] = { qty = 1 }, ["5400:2"] = { qty = 1 } } }

    -- ---- who may ask, and what an unauthorised caller learns (nothing) ----
    local refused = cmd(plain, "admin.recovery", { action = "overview" })
    check(refused.ok == false and refused.error == "forbidden" and refused.scope == "all"
        and refused.records == nil and refused.accounts == nil and refused.summary == nil,
        "an ordinary player cannot read the server-wide overview, and the refusal names no account")
    local readOnly = cmd(reader, "admin.recovery", { action = "overview" })
    check(readOnly.ok == true and readOnly.scope == "all" and readOnly.perms.read == true
        and readOnly.perms.write == false and readOnly.summary.held == 28,
        "a read-only role sees the whole server's backlog and is told it may not write")
    local page1 = cmd(boss, "admin.recovery", { action = "overview" })

    -- ---- the summary is the whole server, one entry per account ----
    check(page1.summary.accounts == 5 and page1.summary.held == 28 and page1.summary.onlineAccounts == 3
        and page1.summary.offlineAccounts == 2 and page1.summary.open == 2 and #page1.accounts == 5,
        "the summary counts every account with something waiting, online and offline alike")
    local gone = accountOf(page1, "ov-gone")
    check(gone ~= nil and gone.online == false and gone.held == 2 and gone.open == nil,
        "an offline account's open transfers are unknown, not reported as none")
    local busyRow = accountOf(page1, "ov-busy")
    check(busyRow ~= nil and busyRow.online == true and busyRow.held == 0 and busyRow.open == 2,
        "an online account with unconfirmed transfers is listed even with no record held yet")

    -- ---- one page of rows, in (username, key) order across accounts ----
    check(#page1.records == 20 and page1.page == 1 and page1.pages == 2 and page1.total == 28
        and page1.records[1].username == "ov-broken" and page1.records[2].username == "ov-gone"
        and page1.records[4].key == "legacy:5100:9" and page1.records[7].key == "pend:5200:01"
        and page1.records[20].key == "pend:5200:14",
        "one reply is 20 rows of every account in turn, ordered by account and then by record key")
    local page2 = cmd(boss, "admin.recovery", { action = "overview", page = 2 })
    check(#page2.records == 8 and page2.page == 2 and page2.pages == 2 and page2.total == 28
        and page2.records[1].key == "pend:5200:15" and page2.records[8].key == "pend:5200:22",
        "the next page continues where the first ended, with nothing repeated and nothing lost")

    -- ---- the cost: one backpack walk per account on the page, and not one more ----
    local walks, realScan = 0, Rec.scanUnits
    Rec.scanUnits = function(inv) walks = walks + 1; return realScan(inv) end
    local counted = cmd(boss, "admin.recovery", { action = "overview" })
    local firstPageWalks = walks
    walks = 0
    cmd(boss, "admin.recovery", { action = "overview", page = 2 })
    local secondPageWalks = walks
    Rec.scanUnits = realScan
    check(#counted.records == 20 and firstPageWalks == 2 and secondPageWalks == 0,
        "20 rows of four accounts cost one walk per online account on the page - never one per row, and never the whole server")

    -- ---- offline is a limit, a broken read is a fact, and neither empties the page ----
    local offlineRow = rowOf(page1, "pend:5100:2")
    check(offlineRow ~= nil and offlineRow.online == false and offlineRow.reason == "pending_legacy"
        and offlineRow.readError == nil and noAction(offlineRow),
        "an offline account still shows the reason it is waiting, with nothing to press")
    local failedRow = rowOf(page1, "pend:5100:1")
    check(failedRow ~= nil and failedRow.online == true and failedRow.readError == "read_failed"
        and failedRow.reason == "receipt_forgotten" and noAction(failedRow)
        and rowOf(page1, "legacy:5100:9") ~= nil,
        "an account whose backpack cannot be read keeps its rows, marked and disabled, and takes no other account down with it")

    -- ---- the query narrows the rows, never the server's own totals ----
    local filtered = cmd(boss, "admin.recovery", { action = "overview", query = "many" })
    check(filtered.total == 22 and filtered.pages == 2 and #filtered.records == 20
        and filtered.records[1].username == "ov-many" and filtered.summary.held == 28
        and filtered.summary.accounts == 5 and #filtered.accounts == 5,
        "a query narrows the records and the total, while the accounts and the summary stay server-wide")
    local upper = cmd(boss, "admin.recovery", { action = "overview", query = "  OV-LIVE  " })
    check(upper.total == 3 and upper.query == "ov-live" and upper.records[1].username == "ov-live",
        "the account filter is trimmed, case-insensitive, and echoed back as it was applied")
    local clamped = cmd(boss, "admin.recovery", { action = "overview", page = 99 })
    check(clamped.page == 2 and clamped.pages == 2 and #clamped.records == 8,
        "a page past the end answers with the last page instead of an empty success")
    local tooLong = cmd(boss, "admin.recovery", { action = "overview", query = string.rep("a", 65) })
    local badPage = cmd(boss, "admin.recovery", { action = "overview", page = 0 })
    local fractional = cmd(boss, "admin.recovery", { action = "overview", page = 1.5 })
    local wrongType = cmd(boss, "admin.recovery", { action = "overview", page = {} })
    check(tooLong.error == "invalid_args" and tooLong.scope == "all" and tooLong.records == nil
        and badPage.error == "invalid_args" and badPage.scope == "all"
        and fractional.error == "invalid_args" and wrongType.error == "invalid_args",
        "a query or a page this server will not read is refused by scope, never widened to everything")

    -- ---- what the overview hands out is what a decision is taken against ----
    local overviewRow = rowOf(page1, "legacy:5100:9")
    local decided = cmd(boss, "admin.recovery", { action = "resolve", username = "ov-live",
        key = "legacy:5100:9", revision = overviewRow.revision, decision = "remove",
        note = "reviewed from the overview" })
    check(decided.ok == true and decided.removed == 1 and decided.username == "ov-live"
        and decided.scope == nil and not live.inventory:contains(axe),
        "a decision taken from the overview goes through the existing per-record write, one account at a time")
    local after = cmd(boss, "admin.recovery", { action = "overview" })
    check(after.total == 27 and after.summary.held == 27 and accountOf(after, "ov-live").held == 2
        and rowOf(after, "legacy:5100:9") == nil and rowOf(after, "pend:5300:1") ~= nil,
        "closing one record removes that record from the overview and nothing else")
    check(live.modData[KEY] == nil,
        "browsing and resolving an old item never manufacture a player's pending or claim records")
    onlinePlayers = {}
end)()

-- ===== 情境五十二：調降上限與停用幣別都不得吞掉已經被扣住的錢 =====
io.write("scenario 52: a lowered cap and a paused currency never swallow money that is already held\n")
;(function()
local Au = S.Auction
modDataStore[EC.MODDATA_KEY] = nil
files, sentCommands = {}, {}
nowMs = nowMs + 61000
fire("OnServerStarted")
worldSprites = { ["100,200,0"] = "MinidoracatEconomy_terminal_0" }
local boss = fakePlayer("cap-admin"); boss.role = "admin"
local ann = fakePlayer("cap-ann"); ann.x, ann.y = 101, 200
local bob = fakePlayer("cap-bob"); bob.x, bob.y = 101, 200
local cid = fakePlayer("cap-cid"); cid.x, cid.y = 101, 200
onlinePlayers = { boss, ann, bob, cid }
local function cmd(who, name, args)
    nowMs = nowMs + 600
    args = args or {}
    args.requestId = args.requestId or (name .. nowMs)
    withCurrency(name, args)
    fire("OnClientCommand", EC.COMMAND_MODULE, name, who, args)
    local s = lastSent(name)
    return s and s.args or {}
end
cmd(boss, "terminal.register", { x = 100, y = 200, z = 0, kind = "atm" })
L.credit("cap-ann", "survivor", 500, "SYSTEM_MINT", { requestId = "cap-ann-seed", reasonCode = "t" })
L.credit("cap-bob", "survivor", 5000, "SYSTEM_MINT", { requestId = "cap-bob-seed", reasonCode = "t" })
L.credit("cap-cid", "survivor", 5000, "SYSTEM_MINT", { requestId = "cap-cid-seed", reasonCode = "t" })
local axe = instanceItem("Base.Axe"); ann.inventory:AddItem(axe)
local created = cmd(ann, "auction.create", { itemId = axe.id, startPrice = 100, hours = 24, currency = "survivor" })
local aid = created.auctionId
local firstBid = cmd(bob, "auction.bid", { auctionId = aid, amount = 1000, currency = "survivor" })
check(firstBid.ok == true and L.getBalance("cap-bob", "survivor").reserved == 1000, "setup: an auction with 1000 held in reserve")
-- 上限是「能發多少」的閘門，不是「能花多少」的閘門
check(Cfg.setBalanceMax("survivor", 1000, "cap-admin", "lower the fuse below existing balances") == true,
    "setup: the per-account cap is lowered far below balances that already exist")
local spend = L.debit("cap-bob", "survivor", 10, "SYSTEM_TAX", { requestId = "cap-spend", reasonCode = "t" })
check(spend.ok == true and L.getBalance("cap-bob", "survivor").available == 3990,
    "an ordinary debit still goes through while the balance sits above the newly lowered cap")
-- 被超越：整筆保留必須回到可用，即使回去以後仍遠高於上限
local outbid = cmd(cid, "auction.bid", { auctionId = aid, amount = 1100, currency = "survivor" })
local bobBal = L.getBalance("cap-bob", "survivor")
check(outbid.ok == true and bobBal.reserved == 0 and bobBal.available == 4990,
    "an outbid reservation moves back to available in full: a bucket move on one wallet is not new issuance")
-- 釋回失敗時，唯一指向那筆錢的紀錄不得被覆蓋，也不得只 log 就繼續
S.modData().wallets["cap-cid"].survivor.reserved = 0
local broken = cmd(bob, "auction.bid", { auctionId = aid, amount = 1200, currency = "survivor" })
local held = S.modData().auctions.items[aid]
check(broken.error == "insufficient_reserved" and held ~= nil and held.highest ~= nil and held.highest.bidder == "cap-cid"
    and held.highest.amount == 1100 and L.getBalance("cap-bob", "survivor").reserved == 0,
    "a refund that cannot be made refuses the new bid and leaves both the old pointer and the new bidder's money alone")
S.modData().wallets["cap-cid"].survivor.reserved = 1100
-- 停用幣別：新發行擋下，既有義務的釋回仍要走完
check(Cfg.setEnabled("survivor", false, "cap-admin", "pause the currency") == true
    and L.credit("cap-ann", "survivor", 1, "SYSTEM_MINT", { requestId = "cap-mint-blocked", reasonCode = "t" }).error == "currency_disabled",
    "a paused currency still refuses fresh issuance")
local okCancel = Au.adminCancel("cap-admin", aid, "cancelled while the currency was paused")
local cidBal = L.getBalance("cap-cid", "survivor")
check(okCancel == true and cidBal.reserved == 0 and cidBal.available == 5000,
    "cancelling while the currency is paused still hands the bidder the whole reservation back")
check(L.conservation("survivor") == 0,
    "no coin was lost or invented by releasing under a lowered cap and a paused currency")
Cfg.setEnabled("survivor", true, "cap-admin", "resume")
Cfg.setBalanceMax("survivor", nil, "cap-admin", "back to the default")
onlinePlayers = {}
end)()

-- ===== 情境五十三：一個貨架兩種幣，紀錄留住真正付掉的那一種 =====
io.write("scenario 53: two currencies on one shelf, and the record keeps the one that was paid\n")
;(function()
local Shop = S.Shop
modDataStore[EC.MODDATA_KEY] = nil
files, sentCommands = {}, {}
nowMs = nowMs + 61000
fire("OnServerStarted")
worldSprites = { ["100,200,0"] = "MinidoracatEconomy_terminal_0" }
local boss = fakePlayer("dual-admin"); boss.role = "admin"
local zed = fakePlayer("dual-zed"); zed.x, zed.y = 101, 200; zed.inventory = fakeInventory(50)
onlinePlayers = { boss, zed }
local function cmd(who, name, args)
    nowMs = nowMs + 600
    args = args or {}
    args.requestId = args.requestId or (name .. nowMs)
    withCurrency(name, args)
    fire("OnClientCommand", EC.COMMAND_MODULE, name, who, args)
    local s = lastSent(name)
    return s and s.args or {}
end
cmd(boss, "terminal.register", { x = 100, y = 200, z = 0, kind = "atm" })
local set = cmd(boss, "admin.catalog", { action = "set", id = "bandage",
    prices = { survivor = { price = 10, bidPrice = 4, buyback = true }, cat = { price = 4, bidPrice = 2, buyback = false } } })
check(set.ok == true and Shop.sku("bandage").prices.survivor.price == 10 and Shop.sku("bandage").prices.cat.price == 4
    and Shop.sku("bandage").prices.cat.buyback == false,
    "one SKU carries an independent quote per currency, each with its own two direction switches")
check(cmd(boss, "admin.catalog", { action = "set", id = "bandage", price = 7 }).error == "unknown_field"
    and Shop.sku("bandage").prices.survivor.price == 10,
    "the flat price field is gone for good: an old-shaped patch is named as an unknown field instead of quietly repricing survivor")
-- 信任邊界：不認得的欄位和合法欄位同一次送進來，整份必須被擋，不能先寫合法的那一半。
-- 擋的判準是「這個欄位不在寫入者認得的名單裡」，不是「它剛好是三個退場的舊名之一」。
local qtyBefore, revBefore = Shop.sku("bandage").qty, Shop.revision()
local diskBefore = table.concat(files[S.Shop.FILE].lines, "\n")
local mixed = cmd(boss, "admin.catalog", { action = "set", id = "bandage", qty = 3, foo = "whatever" })
check(mixed.ok ~= true and mixed.error == "unknown_field" and mixed.extra ~= nil and mixed.extra.field == "foo"
    and Shop.sku("bandage").qty == qtyBefore and Shop.revision() == revBefore
    and table.concat(files[S.Shop.FILE].lines, "\n") == diskBefore,
    "a field the writer does not recognise poisons the whole patch: the legal qty sent alongside it is not written either, and neither the revision nor a byte of the file moves")
local rev = Shop.revision()
L.credit("dual-zed", "survivor", 100, "SYSTEM_MINT", { requestId = "dual-seed-s", reasonCode = "t" })
L.credit("dual-zed", "cat", 100, "SYSTEM_MINT", { requestId = "dual-seed-c", reasonCode = "t" })
local byCat = cmd(zed, "shop.buy", { id = "bandage", count = 2, currency = "cat", revision = rev, requestId = "dual-buy" })
check(byCat.ok == true and byCat.currency == "cat" and byCat.total == 8
    and L.getBalance("dual-zed", "cat").available == 92 and L.getBalance("dual-zed", "survivor").available == 100,
    "a purchase settles in the currency the player picked and never touches the other wallet")
local rc = L.receipts("dual-zed")
check(rc[#rc].currency == "cat" and rc[#rc].amount == -8,
    "the receipt records the currency that was actually paid, not the shop's first currency")
local swapped = cmd(zed, "shop.buy", { id = "bandage", count = 2, currency = "survivor", revision = rev, requestId = "dual-buy" })
check(swapped.error == "request_conflict" and L.getBalance("dual-zed", "survivor").available == 100
    and L.getBalance("dual-zed", "cat").available == 92,
    "the same requestId with another currency is a conflict, not a duplicate: nothing is charged on either wallet")
local replay = cmd(zed, "shop.buy", { id = "bandage", count = 2, currency = "cat", revision = rev, requestId = "dual-buy" })
check(replay.duplicate == true and replay.currency == "cat" and replay.txId == byCat.txId,
    "a genuine resend answers with the currency on record instead of echoing what the client asked for")
check(cmd(zed, "shop.buy", { id = "axe", currency = "cat", revision = rev }).error == "currency_unavailable"
    and L.getBalance("dual-zed", "cat").available == 92,
    "a SKU with no quote in that currency is not free and not converted: it is simply not on sale there")
check(cmd(zed, "shop.buy", { id = "bandage", currency = "nope", revision = rev }).error == "unknown_currency"
    and Shop.buy(zed, { id = "bandage", revision = rev, requestId = "dual-no-currency" }).error == "invalid_args",
    "an unregistered currency is refused and an omitted currency is refused: neither falls back to survivor")
SandboxVars.MinidoracatEconomy.ShopBuybackEnabled = true
local b1 = instanceItem("Base.Bandage"); zed.inventory:AddItem(b1)
local b2 = instanceItem("Base.Bandage"); zed.inventory:AddItem(b2)
local bandagesBefore = zed.inventory.count("Base.Bandage")
check(cmd(zed, "shop.sell", { id = "bandage", itemIds = { b1.id }, currency = "cat", revision = rev }).error == "currency_closed"
    and zed.inventory.count("Base.Bandage") == bandagesBefore,
    "a quote that exists with its buyback switch off does not sell into that currency, and destroys nothing")
local sellSur = cmd(zed, "shop.sell", { id = "bandage", itemIds = { b2.id }, currency = "survivor", revision = rev })
check(sellSur.ok == true and sellSur.currency == "survivor" and L.getBalance("dual-zed", "survivor").available == 104
    and L.getBalance("dual-zed", "cat").available == 92,
    "the open direction mints into its own currency only")
SandboxVars.MinidoracatEconomy.ShopBuybackEnabled = nil
onlinePlayers = {}
end)()

-- ===== 情境五十四：份數跨幣共用，錢的上限各幣分開 =====
io.write("scenario 54: buyback shares are shared across currencies, the coin caps are not\n")
;(function()
local Shop = S.Shop
modDataStore[EC.MODDATA_KEY] = nil
files, sentCommands = {}, {}
nowMs = nowMs + 61000
fire("OnServerStarted")
worldSprites = { ["100,200,0"] = "MinidoracatEconomy_terminal_0" }
local boss = fakePlayer("cap2-admin"); boss.role = "admin"
local zed = fakePlayer("cap2-zed"); zed.x, zed.y = 101, 200; zed.inventory = fakeInventory(80)
onlinePlayers = { boss, zed }
local function cmd(who, name, args)
    nowMs = nowMs + 600
    args = args or {}
    args.requestId = args.requestId or (name .. nowMs)
    withCurrency(name, args)
    fire("OnClientCommand", EC.COMMAND_MODULE, name, who, args)
    local s = lastSent(name)
    return s and s.args or {}
end
cmd(boss, "terminal.register", { x = 100, y = 200, z = 0, kind = "atm" })
check(EC.BUYBACK_OPTIONS.survivor.account == "ShopBuybackPerAccountDaily"
    and EC.BUYBACK_OPTIONS.survivor.server == "ShopBuybackServerDaily"
    and EC.BUYBACK_OPTIONS.cat.account == "ShopCatBuybackPerAccountDaily"
    and EC.BUYBACK_OPTIONS.cat.server == "ShopCatBuybackServerDaily",
    "every currency names its own pair of buyback options instead of sharing one server-wide fuse")
check(Cfg.currency("cat").buybackCaps.account == 0 and Cfg.currency("cat").buybackCaps.server == 0
    and Cfg.currency("survivor").buybackCaps.account > 0,
    "the second currency starts closed: its caps default to zero, which is off and not unlimited")
local setRes = cmd(boss, "admin.catalog", { action = "set", id = "axe", buybackCap = 3,
    prices = { survivor = { bidPrice = 60, buyback = true }, cat = { price = 120, bidPrice = 30, buyback = true } } })
local rev = Shop.revision()
SandboxVars.MinidoracatEconomy.ShopBuybackEnabled = true
SandboxVars.MinidoracatEconomy.ShopBuybackPerAccountDaily = 60
SandboxVars.MinidoracatEconomy.ShopBuybackServerDaily = 1000
local axes = {}
for i = 1, 4 do axes[i] = instanceItem("Base.Axe"); zed.inventory:AddItem(axes[i]) end
check(setRes.ok == true and cmd(zed, "shop.sell", { id = "axe", itemIds = { axes[1].id }, currency = "cat", revision = rev }).error == "currency_closed"
    and zed.inventory.count("Base.Axe") == 4,
    "a zero cap closes that currency's faucet even when the SKU itself offers the quote")
SandboxVars.MinidoracatEconomy.ShopCatBuybackPerAccountDaily = 100
SandboxVars.MinidoracatEconomy.ShopCatBuybackServerDaily = 100
local s1 = cmd(zed, "shop.sell", { id = "axe", itemIds = { axes[1].id }, currency = "survivor", revision = rev })
check(s1.ok == true and L.getBalance("cap2-zed", "survivor").available == 60
    and cmd(zed, "shop.sell", { id = "axe", itemIds = { axes[2].id }, currency = "survivor", revision = rev }).error == "buyback_cap_account",
    "the survivor coin cap fills up on survivor sales alone")
local s2 = cmd(zed, "shop.sell", { id = "axe", itemIds = { axes[2].id }, currency = "cat", revision = rev })
check(s2.ok == true and s2.currency == "cat" and L.getBalance("cap2-zed", "cat").available == 30
    and L.getBalance("cap2-zed", "survivor").available == 60,
    "a full survivor coin cap does not close the cat faucet: the coin caps are counted per currency")
local s3 = cmd(zed, "shop.sell", { id = "axe", itemIds = { axes[3].id }, currency = "cat", revision = rev })
local s4 = cmd(zed, "shop.sell", { id = "axe", itemIds = { axes[4].id }, currency = "cat", revision = rev })
check(s3.ok == true and s4.error == "buyback_cap_sku" and L.getBalance("cap2-zed", "cat").available == 60
    and zed.inventory.count("Base.Axe") == 1,
    "three shares is three items in total: two cat sales and one survivor sale use them up and the fourth axe is refused with cat coins still on the table")
check(L.conservation("survivor") == 0 and L.conservation("cat") == 0,
    "both currencies stay conserved through a mixed-currency buyback day")
SandboxVars.MinidoracatEconomy.ShopBuybackEnabled = nil
SandboxVars.MinidoracatEconomy.ShopBuybackPerAccountDaily = nil
SandboxVars.MinidoracatEconomy.ShopBuybackServerDaily = nil
SandboxVars.MinidoracatEconomy.ShopCatBuybackPerAccountDaily = nil
SandboxVars.MinidoracatEconomy.ShopCatBuybackServerDaily = nil
onlinePlayers = {}
end)()

-- ===== 情境五十五：跨 SKU 與跨幣的套利迴圈 =====
io.write("scenario 55: a price list that pays you to go round in a circle is refused\n")
;(function()
local Shop = S.Shop
modDataStore[EC.MODDATA_KEY] = nil
files, sentCommands = {}, {}
nowMs = nowMs + 61000
files[S.Shop.FILE] = { lines = { EC.jsonEncode({ items = {
    { id = "twine_one", item = "Base.Twine", qty = 1, price = 10, bidPrice = 1 },
} }) }, opens = 0 }
fire("OnServerStarted")
local boss = fakePlayer("arb-admin"); boss.role = "admin"
onlinePlayers = { boss }
local function cmd(who, name, args)
    nowMs = nowMs + 600
    args = args or {}
    args.requestId = args.requestId or (name .. nowMs)
    withCurrency(name, args)
    fire("OnClientCommand", EC.COMMAND_MODULE, name, who, args)
    local s = lastSent(name)
    return s and s.args or {}
end
-- 同一個 fullType、不同每份件數：每件價格才是要比的東西
cmd(boss, "admin.catalog", { action = "set", id = "twine_one",
    prices = { survivor = { price = 10, bidPrice = 9, buyback = true } } })
local bulk = cmd(boss, "admin.catalog", { action = "add", id = "twine_ten", item = "Base.Twine", qty = 10,
    prices = { survivor = { price = 80 } } })
check(bulk.error == "arbitrage_rejected" and bulk.extra ~= nil and bulk.extra.field == "prices"
    and ((bulk.extra.id == "twine_ten" and bulk.extra.otherId == "twine_one") or (bulk.extra.id == "twine_one" and bulk.extra.otherId == "twine_ten"))
    and bulk.extra.currency == "survivor" and bulk.extra.otherCurrency == "survivor"
    and Shop.sku("twine_ten") == nil,
    "ten pieces for 80 next to one piece bought back at 9 is a per-piece profit: the pair is refused and named, although each row on its own has bid below ask")
-- 只算已啟用的方向
cmd(boss, "admin.catalog", { action = "set", id = "twine_one", prices = { survivor = { buyback = false } } })
local allowed = cmd(boss, "admin.catalog", { action = "add", id = "twine_ten", item = "Base.Twine", qty = 10,
    prices = { survivor = { price = 80 } } })
check(allowed.ok == true and Shop.sku("twine_ten").qty == 10,
    "with the buyback direction closed there is no circle to walk, so the same two rows are accepted")
-- 被拒的 patch 一個位元組都不能落地
local safeRev = Shop.revision()
local safeText = table.concat(files[S.Shop.FILE].lines, "\n")
local reopened = cmd(boss, "admin.catalog", { action = "set", id = "twine_one",
    prices = { survivor = { bidPrice = 9, buyback = true } } })
check(reopened.error == "arbitrage_rejected" and Shop.revision() == safeRev
    and table.concat(files[S.Shop.FILE].lines, "\n") == safeText
    and Shop.sku("twine_one").prices.survivor.buyback == false,
    "a patch that would open the circle is refused whole: the revision, the file and the loaded row all stay exactly as they were")
-- 兩幣循環必須用兩種不同物品：單一物品的兩幣循環數學上必然隱含同幣套利（兩條腿共用同一組
-- ask/bid），檢查會先報同幣那一格，就測不到 cycle 分支。
-- A：只有 survivor 買得到、只有 cat 收購；B：只有 cat 買得到、只有 survivor 收購。
-- 「只收購不販售」的正確寫法是「有價但不賣」（price 必填、enabled=false），不是省略 price：
-- bidPrice 的上限是 price - 1，那是同幣套利的第一道結構性防線，省掉 price 等於拿掉它。
-- 同幣兩邊都沒有 ask，所以湊不成一組，檢查只能走 cycle 分支：sur->cat 0.9 × cat->sur 3.0 > 1。
cmd(boss, "admin.catalog", { action = "set", id = "twine_one",
    prices = { survivor = { price = 10, buyback = false },
               cat = { price = 1000, enabled = false, bidPrice = 9, buyback = true } } })
local ring = cmd(boss, "admin.catalog", { action = "add", id = "nail_ring", item = "Base.Nails", qty = 1,
    prices = { cat = { price = 4 },
               survivor = { price = 1000, enabled = false, bidPrice = 12, buyback = true } } })
check(ring.error == "arbitrage_rejected" and ring.extra ~= nil
    and ring.extra.cycle == true and ring.extra.currency ~= ring.extra.otherCurrency
    and Shop.sku("nail_ring") == nil,
    "a loop that runs through two currencies and comes back with more of both is refused, and the refusal names both sides of the loop")
-- 載入路徑同樣適用：手改的檔案不能繞過
local previous = Shop.revision()
files[S.Shop.FILE] = { lines = { EC.jsonEncode({ items = {
    { id = "ring_a", item = "Base.Twine", qty = 1, prices = { survivor = { price = 10 },
        cat = { price = 1000, enabled = false, bidPrice = 9, buyback = true } } },
    { id = "ring_b", item = "Base.Nails", qty = 1, prices = { cat = { price = 4 },
        survivor = { price = 1000, enabled = false, bidPrice = 12, buyback = true } } },
} }) }, opens = 0 }
local reloaded = cmd(boss, "admin.catalog", { action = "reload" })
check(reloaded.ok == false and reloaded.error == "arbitrage_rejected" and Shop.sku("ring_a") == nil
    and Shop.revision() == previous,
    "the same circle written straight into catalog.json is refused on load and the previous catalog stays live")
onlinePlayers = {}
end)()

-- ===== 情境五十六：市場與拍賣的幣別由賣家固化，買家只能核對 =====
io.write("scenario 56: a listing settles in the currency its seller fixed, and nobody else may move it\n")
;(function()
local Mk = S.Market
modDataStore[EC.MODDATA_KEY] = nil
files, sentCommands = {}, {}
nowMs = nowMs + 61000
fire("OnServerStarted")
worldSprites = { ["100,200,0"] = "MinidoracatEconomy_terminal_0" }
local ann = fakePlayer("mkc-ann"); ann.x, ann.y = 101, 200; ann.inventory = fakeInventory(80)
local bob = fakePlayer("mkc-bob"); bob.x, bob.y = 101, 200; bob.inventory = fakeInventory(80)
local boss = fakePlayer("mkc-admin"); boss.role = "admin"
onlinePlayers = { boss, ann, bob }
local function cmd(who, name, args)
    nowMs = nowMs + 600
    args = args or {}
    args.requestId = args.requestId or (name .. nowMs)
    withCurrency(name, args)
    fire("OnClientCommand", EC.COMMAND_MODULE, name, who, args)
    local s = lastSent(name)
    return s and s.args or {}
end
cmd(boss, "terminal.register", { x = 100, y = 200, z = 0, kind = "atm" })
for _, who in ipairs({ "mkc-ann", "mkc-bob" }) do
    L.credit(who, "survivor", 500, "SYSTEM_MINT", { requestId = "mkc-s-" .. who, reasonCode = "t" })
    L.credit(who, "cat", 100, "SYSTEM_MINT", { requestId = "mkc-c-" .. who, reasonCode = "t" })
end
local twine = instanceItem("Base.Twine"); ann.inventory:AddItem(twine)
local catListing = cmd(ann, "market.list", { itemId = twine.id, price = 40, currency = "cat", requestId = "mkc-list-cat" })
check(catListing.ok == true and L.getBalance("mkc-ann", "cat").available == 99
    and L.getBalance("mkc-ann", "survivor").available == 500,
    "the listing fee is taken in the currency the seller chose for the listing, not in the shop's first currency")
local catPage = cmd(ann, "market.browse", { currency = "cat" })
check(catPage.currency == "cat" and catPage.total == 1 and catPage.items[1].currency == "cat",
    "the currency filter answers with the value that was asked for and every row says what it is priced in")
local mixed = cmd(ann, "market.browse", { currency = "all" })
check(mixed.currency == "all" and mixed.total == 1 and mixed.items[1].currency == "cat",
    "the mixed view still names each row's currency instead of showing bare numbers")
check(cmd(ann, "market.browse", { currency = "all", sort = "price" }).error == "currency_required"
    and cmd(ann, "market.browse", { currency = "all", sort = "price_desc" }).error == "currency_required",
    "prices from two currencies cannot be put in one order: the mixed view refuses a price sort instead of comparing them")
local wrong = cmd(bob, "market.buy", { listingId = catListing.listingId, price = 40, currency = "survivor", requestId = "mkc-wrong" })
check(wrong.error == "currency_mismatch" and wrong.currency == "cat"
    and L.getBalance("mkc-bob", "survivor").available == 500 and L.getBalance("mkc-bob", "cat").available == 100,
    "the currency a buyer sends is only a confirmation: a mismatch is refused and the reply says which currency the listing is in")
local bought = cmd(bob, "market.buy", { listingId = catListing.listingId, price = 40, currency = "cat", requestId = "mkc-buy" })
check(bought.ok == true and bought.currency == "cat" and L.getBalance("mkc-bob", "cat").available == 60
    and L.getBalance("mkc-bob", "survivor").available == 500 and L.getBalance("mkc-ann", "cat").available == 99 + 40 - 2,
    "the sale moves the listing's own currency on both sides, tax included, and leaves the other wallet alone")
-- 舊紀錄：可證明的單幣結構在讀邊界正規化；不能證明的維持不動並拒絕結算
local t2 = instanceItem("Base.Twine"); ann.inventory:AddItem(t2)
local legacy = cmd(ann, "market.list", { itemId = t2.id, price = 30, currency = "survivor", requestId = "mkc-legacy" })
local t3 = instanceItem("Base.Twine"); ann.inventory:AddItem(t3)
local disputed = cmd(ann, "market.list", { itemId = t3.id, price = 30, currency = "survivor", requestId = "mkc-disputed" })
-- 真正的 pre-currency 舊列：連 tradeSchema 都還不存在。只清 currency 而留著 tradeSchema=2
-- 是「宣稱新 schema 卻說不出幣別」，那是必須 fail-closed 的另一格，不是可正規化的舊資料。
S.modData().market.listings[legacy.listingId].currency = nil
S.modData().market.listings[legacy.listingId].tradeSchema = nil
S.modData().market.listings[disputed.listingId].currency = "nope"
nowMs = nowMs + 1000
fire("OnServerStarted")
check(S.modData().market.listings[legacy.listingId].currency == "survivor",
    "a listing written before currencies existed is normalised once at the read boundary and written back")
local bobCat, bobSur = L.getBalance("mkc-bob", "cat").available, L.getBalance("mkc-bob", "survivor").available
local refused = cmd(bob, "market.buy", { listingId = disputed.listingId, price = 30, currency = "survivor", requestId = "mkc-bad" })
check(refused.error == "currency_unknown" and S.modData().market.listings[disputed.listingId].currency == "nope"
    and L.getBalance("mkc-bob", "survivor").available == bobSur and L.getBalance("mkc-bob", "cat").available == bobCat,
    "a record whose currency cannot be proved is held as it is rather than settled as survivor")
local okLegacy = cmd(bob, "market.buy", { listingId = legacy.listingId, price = 30, currency = "survivor", requestId = "mkc-legacy-buy" })
check(okLegacy.ok == true and okLegacy.currency == "survivor" and L.getBalance("mkc-bob", "survivor").available == bobSur - 30,
    "the rebuilt listing trades in the currency it was rebuilt with")
-- 拍賣：幣別在建立時固化，出價只能核對
local axe = instanceItem("Base.Axe"); ann.inventory:AddItem(axe)
local auction = cmd(ann, "auction.create", { itemId = axe.id, startPrice = 20, hours = 24, currency = "cat", requestId = "mkc-auction" })
local aid = auction.auctionId
check(auction.ok == true and cmd(bob, "auction.bid", { auctionId = aid, amount = 30, currency = "survivor", requestId = "mkc-bid-wrong" }).error == "currency_mismatch"
    and L.getBalance("mkc-bob", "survivor").reserved == 0,
    "a bid in the wrong currency reserves nothing: the auction's currency was fixed when the seller created it")
local bid = cmd(bob, "auction.bid", { auctionId = aid, amount = 30, currency = "cat", requestId = "mkc-bid" })
check(bid.ok == true and L.getBalance("mkc-bob", "cat").reserved == 30
    and S.modData().auctions.items[aid].highest.currency == "cat",
    "the accepted bid is held in the auction's currency and the high bid records it")
S.modData().auctions.items[aid].highest.currency = "survivor"
local conflict = cmd(bob, "auction.bid", { auctionId = aid, amount = 50, currency = "cat", requestId = "mkc-bid-conflict" })
local stillHeld = S.modData().auctions.items[aid].highest
check(conflict.ok ~= true and conflict.error == "currency_conflict" and stillHeld.bidder == "mkc-bob"
    and stillHeld.amount == 30 and L.getBalance("mkc-bob", "cat").reserved == 30,
    "a high bid whose currency disagrees with the auction stops the next bid instead of being guessed away")
S.modData().auctions.items[aid].highest.currency = "cat"
check(L.conservation("cat") == 0 and L.conservation("survivor") == 0,
    "both currencies are still conserved after a mixed-currency market and auction run")
onlinePlayers = {}
end)()

-- ===== 情境五十七：份數／分類的整批編輯不得改到已經發生的事 =====
io.write("scenario 57: qty and category edits land as one piece and never rewrite what is already in the post\n")
;(function()
local Shop, M = S.Shop, S.Mailbox
modDataStore[EC.MODDATA_KEY] = nil
files, sentCommands = {}, {}
nowMs = nowMs + 61000
files[S.Shop.FILE] = { lines = { EC.jsonEncode({ items = {
    { id = "pack", item = "Base.Twine", qty = 2, price = 10, dailyCap = 5, category = "tools" },
    { id = "roll", item = "Base.Nails", qty = 1, price = 5, dailyCap = 5, category = "tools" },
} }) }, opens = 0 }
fire("OnServerStarted")
worldSprites = { ["100,200,0"] = "MinidoracatEconomy_terminal_0" }
local boss = fakePlayer("qty-admin"); boss.role = "admin"
local zed = fakePlayer("qty-zed"); zed.x, zed.y = 101, 200; zed.inventory = fakeInventory(50)
onlinePlayers = { boss, zed }
local function cmd(who, name, args)
    nowMs = nowMs + 600
    args = args or {}
    args.requestId = args.requestId or (name .. nowMs)
    withCurrency(name, args)
    fire("OnClientCommand", EC.COMMAND_MODULE, name, who, args)
    local s = lastSent(name)
    return s and s.args or {}
end
cmd(boss, "terminal.register", { x = 100, y = 200, z = 0, kind = "atm" })
L.credit("qty-zed", "survivor", 500, "SYSTEM_MINT", { requestId = "qty-seed", reasonCode = "t" })
check(Shop.sku("pack").prices.survivor.price == 10 and Shop.sku("pack").qty == 2,
    "an old single-currency catalog on disk is loaded as a survivor quote instead of being rejected")
local rev = Shop.revision()
cmd(zed, "shop.buy", { id = "pack", count = 1, currency = "survivor", revision = rev })
zed.inventory.maxWeight = 0
local parked = cmd(zed, "shop.buy", { id = "pack", count = 1, currency = "survivor", revision = rev, acceptMail = true })
zed.inventory.maxWeight = 50
check(parked.ok == true and parked.mailed == true and cmd(zed, "mail.list").entries[1].qty == 2
    and Shop.used("qty-zed", "pack", nowMs) == 2,
    "setup: two shares bought today, one of them still sitting in the mailbox as two pieces")
local batch = cmd(boss, "admin.catalog", { action = "batch", ids = { "pack", "roll" },
    fields = { qty = 5, category = "food" }, revision = Shop.revision() })
check(batch.ok == true and Shop.sku("pack").qty == 5 and Shop.sku("roll").qty == 5
    and Shop.sku("pack").category == "food" and Shop.sku("roll").category == "food"
    and Shop.sku("pack").prices.survivor.price == 10 and Shop.sku("roll").prices.survivor.price == 5,
    "a batch writes only the two fields it was given to every selected row and leaves each row's own prices alone")
check(Shop.used("qty-zed", "pack", nowMs) == 2 and cmd(zed, "mail.list").entries[1].qty == 2,
    "changing how many pieces a share is does not reset today's shares and does not rewrite a letter already posted")
local before = table.concat(files[S.Shop.FILE].lines, "\n")
local bad = cmd(boss, "admin.catalog", { action = "batch", ids = { "pack", "roll" },
    fields = { qty = 51 }, revision = Shop.revision() })
check(bad.ok ~= true and bad.error == "invalid_args" and Shop.sku("pack").qty == 5 and Shop.sku("roll").qty == 5
    and table.concat(files[S.Shop.FILE].lines, "\n") == before,
    "one out-of-range value rejects the whole batch: neither row and neither byte of the file changes")
local stale = cmd(zed, "shop.buy", { id = "pack", count = 1, currency = "survivor", revision = rev })
check(stale.error == "catalog_changed" and L.getBalance("qty-zed", "survivor").available == 480,
    "a purchase still holding the revision from before the edit is refused with no debit rather than served at the new share size")
onlinePlayers = {}
end)()

-- ===== 情境五十八：完整帳號清單與公開榜不得說的話 =====
io.write("scenario 58: the whole account list, and what the public board may never say\n")
;(function()
modDataStore[EC.MODDATA_KEY] = nil
files, sentCommands = {}, {}
nowMs = nowMs + 61000
fire("OnServerStarted")
local boss = fakePlayer("acct-admin"); boss.role = "admin"
local mod = fakePlayer("acct-mod"); mod.role = "moderator"
local joe = fakePlayer("acct-joe")
onlinePlayers = { boss, mod, joe }
local function cmd(who, name, args)
    nowMs = nowMs + 600
    args = args or {}
    args.requestId = args.requestId or (name .. nowMs)
    fire("OnClientCommand", EC.COMMAND_MODULE, name, who, args)
    local s = lastSent(name)
    return s and s.args or {}
end
for i = 1, 240 do
    local name = string.format("p%03d", i)
    L.credit(name, "survivor", i, "SYSTEM_MINT", { requestId = "acct-seed-" .. i, reasonCode = "t" })
end
L.credit("tie-b", "survivor", 500, "SYSTEM_MINT", { requestId = "acct-tie-b", reasonCode = "t" })
L.credit("tie-a", "survivor", 500, "SYSTEM_MINT", { requestId = "acct-tie-a", reasonCode = "t" })
L.credit("acct-zero", "survivor", 5, "SYSTEM_MINT", { requestId = "acct-zero-in", reasonCode = "t" })
L.debit("acct-zero", "survivor", 5, "SYSTEM_TAX", { requestId = "acct-zero-out", reasonCode = "t" })
L.credit("acct-cold", "survivor", 7, "SYSTEM_MINT", { requestId = "acct-cold", reasonCode = "t" })
cmd(boss, "admin.freeze", { username = "acct-cold", frozen = true, reason = "frozen for the offline filter check" })
local first = cmd(mod, "admin.accounts", { page = 1, sort = "survivor", descending = true })
local pageCount = tonumber(first.pages) or 0
local seen, rows, duplicated = {}, 0, false
for p = 1, pageCount do
    local pg = cmd(mod, "admin.accounts", { page = p, sort = "survivor", descending = true })
    for _, it in ipairs(pg.items or {}) do
        if seen[it.username] then duplicated = true end
        seen[it.username] = true
        rows = rows + 1
    end
end
local top = first.items or {}
check(first.ok == true and #top == 20 and first.total >= 244 and rows == first.total and not duplicated
    and seen["p001"] and seen["p240"] and seen["acct-zero"] and seen["acct-joe"] and not seen["SYSTEM_MINT"],
    "paging walks the whole population exactly once: 240 accounts are not cut off at 200, a zero balance is still an account, and system accounts are not")
check((top[1] or {}).username == "tie-a" and (top[2] or {}).username == "tie-b" and (top[3] or {}).username == "p240"
    and top[1] ~= nil and top[1].balances.survivor.total == 500,
    "the sort runs over everyone before the page is cut, and two equal balances keep a stable account order")
local frozen = cmd(mod, "admin.accounts", { status = "frozen", sort = "username" })
local coldRow = nil
for _, it in ipairs(frozen.items or {}) do if it.username == "acct-cold" then coldRow = it end end
check(frozen.ok == true and coldRow ~= nil and coldRow.online == false and coldRow.frozen == true,
    "an account that is frozen and offline is still in the frozen list: the filter is not a list of who happens to be connected")
local last = cmd(mod, "admin.accounts", { page = pageCount + 99, sort = "survivor", descending = true })
check(last.ok == true and last.page == pageCount and #(last.items or {}) > 0
    and cmd(mod, "admin.accounts", { page = 0 }).error == "invalid_args"
    and cmd(mod, "admin.accounts", { sort = "wealth" }).error == "invalid_args",
    "a page beyond the end clamps to the last page, while a nonsense page or sort key is refused outright")
check(cmd(joe, "admin.accounts", { page = 1 }).error == "forbidden",
    "the account list stays behind the read gate")
L.credit("acct-joe", "survivor", 3, "SYSTEM_MINT", { requestId = "acct-joe-seed", reasonCode = "t" })
local board = cmd(joe, "leaderboard", { kind = "wealth", currency = "survivor", page = 1 })
local ranked = board.entries or {}
local row = ranked[1] or {}
local leaked = false
for _, field in ipairs({ "online", "frozen", "available", "reserved", "balances", "total" }) do
    if row[field] ~= nil then leaked = true end
end
check(board.ok == true and board.showAmounts == false and row.amount == nil and not leaked
    and board.self ~= nil and board.self.amount == 3,
    "the public board tells a player their own amount and nobody else's, and carries no online, frozen or reserved field at all")
check(row.rank == 1 and (ranked[2] or {}).rank == 1 and (ranked[3] or {}).rank == 3
    and row.username == "tie-a" and (ranked[2] or {}).username == "tie-b",
    "equal totals share a rank and the next rank skips, with a stable account order inside the tie")
local onBoard = {}
for _, it in ipairs(ranked) do onBoard[it.username] = true end
check(not onBoard["acct-zero"] and not onBoard["SYSTEM_MINT"] and board.total >= 243,
    "only accounts that actually hold something are ranked, and system accounts never are")
SandboxVars.MinidoracatEconomy.LeaderboardShowAmounts = true
local open = cmd(joe, "leaderboard", { kind = "wealth", currency = "survivor", page = 1 })
check(open.showAmounts == true and ((open.entries or {})[1] or {}).amount == 500,
    "an administrator who opens the amounts is what makes other players' totals public, not the client")
SandboxVars.MinidoracatEconomy.LeaderboardShowAmounts = nil
SandboxVars.MinidoracatEconomy.LeaderboardEnabled = false
check(cmd(joe, "leaderboard", { kind = "wealth", currency = "survivor" }).error == "leaderboard_disabled"
    and cmd(joe, "leaderboard", { kind = "wealth", currency = "nope" }).error == "unknown_currency",
    "the board can be switched off server-side, and an unregistered currency is answered as unknown rather than hidden behind the off switch")
SandboxVars.MinidoracatEconomy.LeaderboardEnabled = nil
onlinePlayers = {}
end)()

-- ===== 情境五十九：一天領好幾次，次數從真正在線的時間算起 =====
io.write("scenario 59: several check-ins a day, counted from time really spent connected\n")
;(function()
modDataStore[EC.MODDATA_KEY] = nil
files, sentCommands = {}, {}
SandboxVars.MinidoracatEconomy.RewardDayResetHour = 4
SandboxVars.MinidoracatEconomy.RewardTimezoneUTC = 8
SandboxVars.MinidoracatEconomy.CheckinAmount = 10
SandboxVars.MinidoracatEconomy.CheckinMinPlaytimeMinutes = 2
SandboxVars.MinidoracatEconomy.CheckinDailyLimit = 3
SandboxVars.MinidoracatEconomy.CheckinIntervalMinutes = 30
SandboxVars.MinidoracatEconomy.CheckinServerDailyCap = 0
nowMs = 1788699986478
fire("OnServerStarted")
local dan = fakePlayer("multi-dan")
onlinePlayers = { dan }
local function tick(minutes)
    for _ = 1, minutes do nowMs = nowMs + 60000; fire("OnTickEvenPaused") end
end
local function bal() return L.getBalance("multi-dan", "survivor").available end
local function state() return R.state("multi-dan", nowMs) end
local function claim(args)
    nowMs = nowMs + 600
    fire("OnClientCommand", EC.COMMAND_MODULE, "rewards.checkin", dan, args or {})
    return lastSent("rewards.checkin").args
end
local function nextArgs(tag)
    local s = state()
    return { day = s.day, rewardIndex = (s.claimedCount or 0) + 1, requestId = tag }
end
tick(4)
local first = claim({ day = state().day, rewardIndex = 1, requestId = "multi-1" })
check(first.ok == true and first.rewardIndex == 1 and first.dailyLimit == 3 and first.currency == "survivor"
    and first.requestId == "multi-1" and first.state.claimedCount == 1 and first.state.remainingClaims == 2 and bal() == 10,
    "the first claim of the day says which claim it was, how many are left and hands back the fresh state")
local missingDay = claim({ rewardIndex = 2, requestId = "multi-no-day" })
local badIndex = claim({ day = state().day, rewardIndex = 0, requestId = "multi-bad-index" })
local noRequestId = claim({ day = state().day, rewardIndex = 2 })
check(missingDay.error == "invalid_args" and badIndex.error == "invalid_args" and noRequestId.error == "invalid_args"
    and bal() == 10 and state().claimedCount == 1,
    "all three wire fields are mandatory: a missing day, a non-positive index or a missing requestId is refused outright and consumes no claim")
local tooSoon = claim(nextArgs("multi-toosoon"))
check(tooSoon.ok ~= true and bal() == 10 and tooSoon.state.blockedReason == "interval_not_elapsed"
    and tooSoon.state.claimedCount == 1,
    "the next claim is refused until its cumulative connected-time threshold is reached")
local st = state()
check(st.canClaim == false and st.requiredOnlineMs == st.playedMs + st.remainingOnlineMs and st.remainingOnlineMs > 0
    and st.dailyLimit == 3 and st.remainingClaims == 2,
    "the snapshot says exactly how much longer this player has to stay online, without waiting for a tick to find out")
local connected = st.playedMs
onlinePlayers = {}
tick(40)
onlinePlayers = { dan }
tick(1)
check(state().playedMs <= connected + 120000,
    "forty minutes with the player gone add nothing: only time actually spent in the world counts")
-- 重登：同一 tick 內換成新的 player 物件，中間那段不得被算成在線
local beforeRelog = state().playedMs
onlinePlayers = {}
nowMs = nowMs + 300000
dan = fakePlayer("multi-dan")
onlinePlayers = { dan }
tick(1)
check(state().playedMs == beforeRelog,
    "logging back in as a new character in the same tick starts a fresh anchor: the gap in between is never paid for")
tick(35)
local wrongIndex = claim({ day = state().day, rewardIndex = 1, requestId = "multi-replay" })
check(wrongIndex.ok ~= true and wrongIndex.error == "stale_request" and wrongIndex.rewardIndex == 2
    and bal() == 10 and state().claimedCount == 1,
    "resending the first claim once the interval has passed is a stale request, never the second payment, and it consumes nothing")
local wrongDay = claim({ day = "19700101", rewardIndex = 2, requestId = "multi-oldday" })
check(wrongDay.ok ~= true and wrongDay.error == "stale_request" and wrongDay.day == state().day and bal() == 10,
    "a claim aimed at another reward day is refused and answered with the day the server is actually on")
local second = claim({ day = state().day, rewardIndex = 2, requestId = "multi-2" })
check(second.ok == true and second.rewardIndex == 2 and bal() == 20 and second.state.remainingClaims == 1,
    "once today's connected time reaches the second threshold the second claim goes through")
dan.hours = 0
tick(35)
local third = claim({ day = state().day, rewardIndex = 3, requestId = "multi-3" })
check(third.ok == true and third.rewardIndex == 3 and bal() == 30,
    "a death or a new character does not give the account its daily claims back")
tick(35)
local fourth = claim(nextArgs("multi-4"))
check(fourth.ok ~= true and bal() == 30 and fourth.state.blockedReason == "daily_limit_reached"
    and fourth.state.remainingClaims == 0,
    "the fourth claim of a three-claim day is refused rather than paid, however long the player stays online")
SandboxVars.MinidoracatEconomy.CheckinDailyLimit = 1
check(bal() == 30 and state().dailyLimit == 1 and state().remainingClaims == 0,
    "lowering the daily limit after three payments claws nothing back and hands out nothing extra")
nowMs = R.nextResetMs(nowMs) + 1000
local fresh = state()
check(fresh.claimedCount == 0 and fresh.dailyLimit == 1 and fresh.playedMs < 120000 and fresh.day ~= first.state.day,
    "the next reward day starts from zero under the new limit, counting only the part of the session that falls in it")
local data = S.modData()
data.claims["multi-dan"] = { day = fresh.day, playedMs = 600000, checkinDay = fresh.day, milestones = 0 }
local migrated = state()
local afterMigration = claim(nextArgs("multi-legacy"))
check(migrated.claimedCount == 1 and migrated.remainingClaims == 0 and afterMigration.ok ~= true
    and afterMigration.state.blockedReason == "daily_limit_reached" and bal() == 30,
    "an old save that only knows checkinDay counts as one claim already taken today and is never paid a second time")
SandboxVars.MinidoracatEconomy.CheckinDailyLimit = nil
SandboxVars.MinidoracatEconomy.CheckinIntervalMinutes = nil
SandboxVars.MinidoracatEconomy.CheckinAmount = nil
SandboxVars.MinidoracatEconomy.CheckinMinPlaytimeMinutes = nil
onlinePlayers = {}
end)()

-- ===== 情境六十：簽到金額 0 就是關掉，不是發 0 元 =====
io.write("scenario 60: a check-in amount of zero switches the reward off instead of paying nothing\n")
;(function()
modDataStore[EC.MODDATA_KEY] = nil
files, sentCommands = {}, {}
SandboxVars.MinidoracatEconomy.RewardDayResetHour = 4
SandboxVars.MinidoracatEconomy.RewardTimezoneUTC = 8
SandboxVars.MinidoracatEconomy.CheckinAmount = 0
SandboxVars.MinidoracatEconomy.CheckinMinPlaytimeMinutes = 2
SandboxVars.MinidoracatEconomy.CheckinServerDailyCap = 0
nowMs = 1788699986478
fire("OnServerStarted")
local zoe = fakePlayer("zero-zoe")
onlinePlayers = { zoe }
for _ = 1, 4 do nowMs = nowMs + 60000; fire("OnTickEvenPaused") end
local st = R.state("zero-zoe", nowMs)
check(st.amount == 0 and st.canClaim == false and st.blockedReason == "checkin_disabled" and st.playedMs >= 120000,
    "an amount of zero is reported as a reward that is switched off, not as a claimable zero")
local keysBefore = S.modData().idempotency.count
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "rewards.checkin", zoe, { day = st.day, rewardIndex = 1, requestId = "zero-1" })
local refused = lastSent("rewards.checkin").args
check(refused.ok == false and refused.error == "checkin_disabled"
    and L.getBalance("zero-zoe", "survivor").available == 0
    and S.modData().idempotency.count == keysBefore
    and S.modData().idempotency.map["checkin:zero-zoe:" .. st.day .. ":1"] == nil
    and R.state("zero-zoe", nowMs).claimedCount == 0,
    "the refusal never reaches the ledger: no zero posting, no idempotency key burned and no claim consumed")
check(S.modData().rollups[st.day] == nil or S.modData().rollups[st.day].checkinCount == 0,
    "a switched-off check-in writes nothing into the day's rollup")
zoe.hours = 24 * 3 + 1
nowMs = nowMs + 60000; fire("OnTickEvenPaused")
check(L.getBalance("zero-zoe", "survivor").available == 250,
    "survival milestones keep their own amounts: switching the daily check-in off does not switch them off as well")
SandboxVars.MinidoracatEconomy.CheckinAmount = 25
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "rewards.checkin", zoe, checkinArgs("zero-zoe", nowMs, "zero-back"))
local paid = lastSent("rewards.checkin").args
check(paid.ok == true and paid.rewardIndex == 1 and paid.amount == 25
    and L.getBalance("zero-zoe", "survivor").available == 275,
    "turning the amount back up makes it claimable in the same tick, still as the day's first claim because nothing was consumed")
SandboxVars.MinidoracatEconomy.CheckinAmount = nil
SandboxVars.MinidoracatEconomy.CheckinMinPlaytimeMinutes = nil
onlinePlayers = {}
end)()

-- ===== 情境六十一：剩下的錢流反例（讀邊界、退款失敗、指紋、回收） =====
io.write("scenario 61: the remaining money counter-examples: read boundary, failed refund, fingerprint, restore\n")
;(function()
local Shop, Au, Rec = S.Shop, S.Auction, S.Recovery
modDataStore[EC.MODDATA_KEY] = nil
files, sentCommands = {}, {}
nowMs = nowMs + 61000
fire("OnServerStarted")
worldSprites = { ["100,200,0"] = "MinidoracatEconomy_terminal_0" }
local boss = fakePlayer("rest-admin"); boss.role = "admin"
local ann = fakePlayer("rest-ann"); ann.x, ann.y = 101, 200; ann.inventory = fakeInventory(80)
local bob = fakePlayer("rest-bob"); bob.x, bob.y = 101, 200; bob.inventory = fakeInventory(80)
local cid = fakePlayer("rest-cid"); cid.x, cid.y = 101, 200; cid.inventory = fakeInventory(80)
onlinePlayers = { boss, ann, bob, cid }
local function cmd(who, name, args)
    nowMs = nowMs + 600
    args = args or {}
    args.requestId = args.requestId or (name .. nowMs)
    withCurrency(name, args)
    fire("OnClientCommand", EC.COMMAND_MODULE, name, who, args)
    local s = lastSent(name)
    return s and s.args or {}
end
cmd(boss, "terminal.register", { x = 100, y = 200, z = 0, kind = "atm" })
for _, who in ipairs({ "rest-ann", "rest-bob", "rest-cid" }) do
    L.credit(who, "survivor", 4900, "SYSTEM_MINT", { requestId = "rest-s-" .. who, reasonCode = "t" })
    L.credit(who, "cat", 400, "SYSTEM_MINT", { requestId = "rest-c-" .. who, reasonCode = "t" })
end
-- 降 cap 的豁免只給扣款與精確釋回，不得滑到一般 credit
Cfg.setBalanceMax("survivor", 1000, "rest-admin", "lower the fuse under every balance")
local spend = L.debit("rest-ann", "survivor", 100, "SYSTEM_TAX", { requestId = "rest-debit", reasonCode = "t" })
local mint = L.credit("rest-ann", "survivor", 10, "SYSTEM_MINT", { requestId = "rest-mint", reasonCode = "t" })
check(spend.ok == true and mint.error == "balance_cap" and L.getBalance("rest-ann", "survivor").available == 4800,
    "the lowered cap stops new issuance but never stops spending: the exemption is for debits and exact releases, not for credit in general")
Cfg.setBalanceMax("survivor", nil, "rest-admin", "back to the default")
-- 退款失敗的管理取消：拍賣不得消失，highest 不得消失
local axe = instanceItem("Base.Axe"); ann.inventory:AddItem(axe)
local auction = cmd(ann, "auction.create", { itemId = axe.id, startPrice = 100, hours = 24, currency = "survivor", requestId = "rest-auction" })
local aid = auction.auctionId
cmd(bob, "auction.bid", { auctionId = aid, amount = 200, currency = "survivor", requestId = "rest-bid-1" })
S.modData().wallets["rest-bob"].survivor.reserved = 0
local cancelOk, cancelErr = Au.adminCancel("rest-admin", aid, "a cancel whose refund cannot be made")
local stuck = S.modData().auctions.items[aid]
check(cancelOk == false and cancelErr == "refund_failed" and stuck ~= nil and stuck.highest ~= nil
    and stuck.highest.bidder == "rest-bob" and stuck.blocked == "refund_failed",
    "a cancel whose refund is refused leaves the auction standing with its high bid and says so, instead of deleting the only pointer to the money")
S.modData().wallets["rest-bob"].survivor.reserved = 200
local recovered = cmd(cid, "auction.bid", { auctionId = aid, amount = 300, currency = "survivor", requestId = "rest-bid-2" })
check(recovered.ok == true and S.modData().auctions.items[aid].blocked == nil
    and L.getBalance("rest-bob", "survivor").reserved == 0,
    "the next successful bid is what actually releases the stuck reservation, and the block is cleared by that transaction rather than by a flag reset")
-- 同 requestId 換幣是衝突，完全相同才是重送
local swapped = cmd(cid, "auction.bid", { auctionId = aid, amount = 300, currency = "cat", requestId = "rest-bid-2" })
local resent = cmd(cid, "auction.bid", { auctionId = aid, amount = 300, currency = "survivor", requestId = "rest-bid-2" })
check(swapped.error == "request_conflict" and swapped.currency == "survivor"
    and resent.duplicate == true and resent.currency == "survivor"
    and L.getBalance("rest-cid", "cat").available == 400,
    "the fingerprint of a request includes its currency: reusing the id with another currency is a conflict, and both answers name the currency on record")
-- 拍賣讀邊界：能證明的舊紀錄採用 highest 的幣，矛盾的新紀錄 fail-closed
local t2 = instanceItem("Base.Axe"); ann.inventory:AddItem(t2)
local second = cmd(ann, "auction.create", { itemId = t2.id, startPrice = 100, hours = 24, currency = "survivor", requestId = "rest-auction-2" })
cmd(bob, "auction.bid", { auctionId = second.auctionId, amount = 150, currency = "survivor", requestId = "rest-bid-3" })
local legacy = S.modData().auctions.items[aid]
legacy.currency, legacy.tradeSchema = nil, nil
legacy.highest.currency = "cat"
local conflicted = S.modData().auctions.items[second.auctionId]
conflicted.tradeSchema, conflicted.currency = 2, "survivor"
conflicted.highest.currency = "cat"
nowMs = nowMs + 1000
fire("OnServerStarted")
check(S.modData().auctions.items[aid].currency == "cat" and S.modData().auctions.items[aid].blocked == nil,
    "an auction written before currencies existed takes the currency its own high bid was recorded in, because that is provable")
local blockedBid = cmd(cid, "auction.bid", { auctionId = second.auctionId, amount = 300, currency = "survivor", requestId = "rest-bid-4" })
local heldAuction = S.modData().auctions.items[second.auctionId]
check(heldAuction.blocked == "currency_conflict" and blockedBid.error == "currency_conflict"
    and heldAuction.highest.bidder == "rest-bob" and heldAuction.highest.amount == 150,
    "a record that already claims the new schema and still disagrees with its own high bid is held, not guessed: the next bid is refused and the high bid stays")
-- 市場：被標記的列不該出現在單幣頁，all 頁才看得到
local rope = instanceItem("Base.Rope"); ann.inventory:AddItem(rope)
local bad = cmd(ann, "market.list", { itemId = rope.id, price = 40, currency = "survivor", requestId = "rest-list" })
S.modData().market.listings[bad.listingId].currency = "nope"
nowMs = nowMs + 1000
fire("OnServerStarted")
local onePage = cmd(ann, "market.browse", { currency = "survivor" })
local allPage = cmd(ann, "market.browse", { currency = "all" })
local inOne, inAll = false, false
for _, it in ipairs(onePage.items or {}) do if it.id == bad.listingId then inOne = true end end
for _, it in ipairs(allPage.items or {}) do if it.id == bad.listingId then inAll = true end end
check(inOne == false and inAll == true and S.modData().market.listings[bad.listingId].blocked == "currency_unknown",
    "a row nobody can price is kept out of every single-currency page but stays visible in the mixed view, so it is held rather than hidden")
-- 份數跨幣共用、幣量各自分開，同一次檢查兩邊
cmd(boss, "admin.catalog", { action = "set", id = "axe", buybackCap = 4,
    prices = { survivor = { bidPrice = 60, buyback = true }, cat = { price = 200, bidPrice = 30, buyback = true } } })
SandboxVars.MinidoracatEconomy.ShopBuybackEnabled = true
SandboxVars.MinidoracatEconomy.ShopBuybackPerAccountDaily = 500
SandboxVars.MinidoracatEconomy.ShopBuybackServerDaily = 5000
SandboxVars.MinidoracatEconomy.ShopCatBuybackPerAccountDaily = 300
SandboxVars.MinidoracatEconomy.ShopCatBuybackServerDaily = 3000
local sellRev = Shop.revision()
local sold = {}
for i = 1, 2 do sold[i] = instanceItem("Base.Axe"); bob.inventory:AddItem(sold[i]) end
cmd(bob, "shop.sell", { id = "axe", itemIds = { sold[1].id }, currency = "survivor", revision = sellRev })
local afterTwo = cmd(bob, "shop.sell", { id = "axe", itemIds = { sold[2].id }, currency = "survivor", revision = sellRev })
local catRoom = Shop.buybackRoom("rest-bob", "axe", nowMs, "cat")
check(afterTwo.ok == true and afterTwo.buyback.byCurrency.cat.accountRemaining == 300
    and afterTwo.buyback.skuRemaining == 2 and catRoom.sku == 2,
    "two survivor sales leave the cat coin allowance untouched and still take two of the four shares: coins are per currency, shares are not")
-- 先守大門：沒有經過伺服器證明的 pending，restoreFromPending 一律不付款。這條才是 CORE-H1
-- 的閘門本身；下面兩條是「拿到權威記錄之後」那個函式自己的單元測試，不代表證據已驗證。
local catBefore = L.getBalance("rest-cid", "cat").available
local survBefore = L.getBalance("rest-cid", "survivor").available
local okRaw, infoRaw = Shop.restoreFromPending("rest-cid", "rest-pend-0", { kind = "buyback", sku = "axe",
    qty = 1, lotQty = 1, unitPrice = 60, unitQty = 1, price = 60, tradeSchema = 2, currency = "survivor",
    txRequestId = "sell:rest-cid:restore-0", snapshot = { type = "Base.Axe" } })
check(okRaw == false and infoRaw ~= nil and infoRaw.reason == "proof_required"
    and L.getBalance("rest-cid", "survivor").available == survBefore
    and L.getBalance("rest-cid", "cat").available == catBefore,
    "a pending nobody vouched for buys nothing at all: without the server's own record the restore refuses before it looks at the currency, and neither wallet moves")
-- 以下兩條：已被標記為權威記錄之後，該函式選幣的行為（單元層級，不是 journal 已驗證）
local okNoCur, infoNoCur = Shop.restoreFromPending("rest-cid", "rest-pend-1", Rec.markProven({ kind = "buyback", sku = "axe",
    qty = 1, lotQty = 1, unitPrice = 60, unitQty = 1, price = 60, tradeSchema = 2,
    txRequestId = "sell:rest-cid:restore-1", snapshot = { type = "Base.Axe" } }))
check(okNoCur == false and infoNoCur ~= nil and infoNoCur.reason == "currency_unknown"
    and L.getBalance("rest-cid", "survivor").available == survBefore
    and L.getBalance("rest-cid", "cat").available == catBefore,
    "even a record the server vouches for is not repaid when it cannot say which currency it was: no fallback to survivor")
local okCat, infoCat = Shop.restoreFromPending("rest-cid", "rest-pend-2", Rec.markProven({ kind = "buyback", sku = "axe",
    qty = 1, lotQty = 1, unitPrice = 30, unitQty = 1, price = 30, tradeSchema = 2, currency = "cat",
    txRequestId = "sell:rest-cid:restore-2", snapshot = { type = "Base.Axe" } }))
check(okCat == true and infoCat.reason == "buyback_paid"
    and L.getBalance("rest-cid", "cat").available == catBefore + 30
    and L.getBalance("rest-cid", "survivor").available == survBefore,
    "a vouched record that names its currency is repaid in that currency, not in the shop's first one")
SandboxVars.MinidoracatEconomy.ShopBuybackEnabled = nil
SandboxVars.MinidoracatEconomy.ShopBuybackPerAccountDaily = nil
SandboxVars.MinidoracatEconomy.ShopBuybackServerDaily = nil
SandboxVars.MinidoracatEconomy.ShopCatBuybackPerAccountDaily = nil
SandboxVars.MinidoracatEconomy.ShopCatBuybackServerDaily = nil
onlinePlayers = {}
end)()

-- ===== 情境六十二：舊的收購日桶只遷到 survivor，而且只遷一次 =====
io.write("scenario 62: an old buyback day bucket migrates to survivor once, and to nobody else\n")
;(function()
local Shop = S.Shop
modDataStore[EC.MODDATA_KEY] = nil
files, sentCommands = {}, {}
nowMs = nowMs + 61000
fire("OnServerStarted")
local boss = fakePlayer("leg-admin"); boss.role = "admin"
onlinePlayers = { boss }
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.catalog", boss, { action = "set", id = "nails", buybackCap = 5,
    prices = { survivor = { bidPrice = 10, buyback = true }, cat = { price = 40, bidPrice = 5, buyback = true } },
    requestId = "leg-catalog" })
SandboxVars.MinidoracatEconomy.ShopBuybackEnabled = true
SandboxVars.MinidoracatEconomy.ShopBuybackPerAccountDaily = 500
SandboxVars.MinidoracatEconomy.ShopBuybackServerDaily = 20000
SandboxVars.MinidoracatEconomy.ShopCatBuybackPerAccountDaily = 300
SandboxVars.MinidoracatEconomy.ShopCatBuybackServerDaily = 3000
-- 舊存檔的裸數字日桶：total / accounts 都還沒有幣別這個概念
S.modData().shopBuyback[R.dayKey(nowMs)] = { total = 120, accounts = { ["leg-bob"] = 120 }, skus = { nails = 2 } }
nowMs = nowMs + 1000
fire("OnServerStarted")
local status = Shop.buybackStatus(nowMs)
check(status.byCurrency.survivor.mintedToday == 120 and status.byCurrency.cat.mintedToday == 0,
    "the old total lands on survivor only: money that was minted once is not counted again under the second currency")
local sur = Shop.buybackRoom("leg-bob", "nails", nowMs, "survivor")
local cat = Shop.buybackRoom("leg-bob", "nails", nowMs, "cat")
local other = Shop.buybackRoom("leg-zoe", "nails", nowMs, "survivor")
check(sur.account == 500 - 120 and sur.server == 20000 - 120 and cat.account == 300 and cat.server == 3000
    and sur.sku == 5 - 2 and cat.sku == sur.sku and other.account == 500,
    "the migrated coins bite only survivor and only this account, while the two shares it used are gone from both currencies")
SandboxVars.MinidoracatEconomy.ShopBuybackEnabled = nil
SandboxVars.MinidoracatEconomy.ShopBuybackPerAccountDaily = nil
SandboxVars.MinidoracatEconomy.ShopBuybackServerDaily = nil
SandboxVars.MinidoracatEconomy.ShopCatBuybackPerAccountDaily = nil
SandboxVars.MinidoracatEconomy.ShopCatBuybackServerDaily = nil
onlinePlayers = {}
end)()

-- ===== 情境六十三：獎勵日往回跳，不得靠帳本冪等當唯一防線 =====
io.write("scenario 63: a reward day that goes backwards is not paid twice, even with the ledger cache gone\n")
;(function()
modDataStore[EC.MODDATA_KEY] = nil
files, sentCommands = {}, {}
SandboxVars.MinidoracatEconomy.RewardDayResetHour = 4
SandboxVars.MinidoracatEconomy.RewardTimezoneUTC = 8
SandboxVars.MinidoracatEconomy.CheckinAmount = 10
SandboxVars.MinidoracatEconomy.CheckinMinPlaytimeMinutes = 2
SandboxVars.MinidoracatEconomy.CheckinDailyLimit = 2
SandboxVars.MinidoracatEconomy.CheckinIntervalMinutes = 30
SandboxVars.MinidoracatEconomy.CheckinServerDailyCap = 0
nowMs = 1788699986478
fire("OnServerStarted")
local rev = fakePlayer("rev-dan")
onlinePlayers = { rev }
local function tick(minutes)
    for _ = 1, minutes do nowMs = nowMs + 60000; fire("OnTickEvenPaused") end
end
local function bal() return L.getBalance("rev-dan", "survivor").available end
local function state() return R.state("rev-dan", nowMs) end
local function claim(args)
    nowMs = nowMs + 600
    fire("OnClientCommand", EC.COMMAND_MODULE, "rewards.checkin", rev, args)
    return lastSent("rewards.checkin").args
end
tick(4)
local dayD = state().day
local first = claim({ day = dayD, rewardIndex = 1, requestId = "rev-1" })
local paidMs = nowMs
check(first.ok == true and bal() == 10, "setup: the first claim of that day is paid")
nowMs = R.nextResetMs(nowMs) + 60000
tick(4)
-- 帳本冪等快取整個不見了（LRU 逐出／回滾）：耐久的 claim 紀錄必須自己擋住
S.modData().idempotency = { keys = {}, head = 1, count = 0, map = {} }
nowMs = paidMs
local back = state()
local retried = claim({ day = dayD, rewardIndex = 1, requestId = "rev-retry" })
check(back.day == dayD and back.claimedCount == 1 and retried.error == "stale_request" and bal() == 10,
    "with the ledger cache gone the durable claim record still knows that day's first reward was paid, so the retry is stale instead of a second payment")
-- 回到的那一天已經滑出保存窗口：無法證明就不付。這裡只釘安全不變量，不釘「先撞到序號檢查
-- 還是先撞到回跳保險絲」——兩種拒絕都沒有付錢，優先序是實作的自由。
S.modData().claims["rev-dan"].paid = {}
S.modData().claims["rev-dan"].paidDay = R.dayKey(paidMs + 5 * 86400000)
local outside = state()
local refused = claim({ day = dayD, rewardIndex = 1, requestId = "rev-outside" })
check(outside.canClaim == false and outside.blockedReason == "day_reverted"
    and refused.ok ~= true and bal() == 10,
    "a day older than the payment watermark with no record left is refused outright rather than treated as a fresh day")
-- 時鐘回到最新的一天就恢復正常
S.modData().claims["rev-dan"].paid = { [dayD] = 1 }
S.modData().claims["rev-dan"].paidDay = dayD
nowMs = R.nextResetMs(paidMs) + 60000
tick(8)                              -- 跨日會把 playedMs 歸零，這裡要重新累積過首領門檻
local resumed = state()
check(resumed.day ~= dayD and resumed.claimedCount == 0 and resumed.canClaim == true
    and resumed.blockedReason == nil,
    "once the clock is back on the newest day the reward works normally again: the fuse guards the past, it does not latch")
SandboxVars.MinidoracatEconomy.CheckinDailyLimit = nil
SandboxVars.MinidoracatEconomy.CheckinIntervalMinutes = nil
SandboxVars.MinidoracatEconomy.CheckinAmount = nil
SandboxVars.MinidoracatEconomy.CheckinMinPlaytimeMinutes = nil
onlinePlayers = {}
end)()

-- ===== 情境六十四：升級後第一次讀就已經跨日，昨天的付款證據不得被清掉 =====
io.write("scenario 64: an old claim record first read on a later day keeps yesterday's proof of payment\n")
;(function()
modDataStore[EC.MODDATA_KEY] = nil
files, sentCommands = {}, {}
SandboxVars.MinidoracatEconomy.RewardDayResetHour = 4
SandboxVars.MinidoracatEconomy.RewardTimezoneUTC = 8
SandboxVars.MinidoracatEconomy.CheckinAmount = 10
SandboxVars.MinidoracatEconomy.CheckinMinPlaytimeMinutes = 2
SandboxVars.MinidoracatEconomy.CheckinDailyLimit = 2
SandboxVars.MinidoracatEconomy.CheckinIntervalMinutes = 30
SandboxVars.MinidoracatEconomy.CheckinServerDailyCap = 0
local dayMs = 1788699986478
nowMs = dayMs
fire("OnServerStarted")
local mia = fakePlayer("mig-mia")
local nia = fakePlayer("mig-nia")
onlinePlayers = { mia, nia }
local dayD = R.dayKey(nowMs)
local data = S.modData()
-- 兩份還沒被讀過的存檔：一份是舊的單次格式，一份是新的 N 次格式，兩份都還沒有水位
data.claims["mig-mia"] = { day = dayD, playedMs = 300000, checkinDay = dayD, milestones = 0, season = "1" }
data.claims["mig-nia"] = { day = dayD, playedMs = 300000, claimedCount = 2, claimBasePlayedMs = 300000, milestones = 0, season = "1" }
-- 升級後的第一次讀邊界發生在隔天
nowMs = R.nextResetMs(nowMs) + 60000
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "rewards.state", mia, {})
local miaState = lastSent("rewards.state").args
local miaRec = data.claims["mig-mia"]
check(miaRec.paid ~= nil and miaRec.paid[dayD] == 1 and miaRec.paidDay == dayD and miaRec.checkinDay == nil
    and miaState.day ~= dayD and miaState.claimedCount == 0,
    "the only proof that yesterday was paid is moved into the watermark before the day rolls over and before the old field is cleared")
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "rewards.state", nia, {})
local niaRec = data.claims["mig-nia"]
check(niaRec.paid ~= nil and niaRec.paid[dayD] == 2 and niaRec.paidDay == dayD,
    "a record that already counts claims is seeded at the number it reached, not at one and not at zero")
-- 帳本冪等快取整個不見，時鐘又回到那一天
S.modData().idempotency = { keys = {}, head = 1, count = 0, map = {} }
nowMs = dayMs + 1000
local backMia = R.state("mig-mia", nowMs)
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "rewards.checkin", mia, { day = dayD, rewardIndex = 1, requestId = "mig-retry" })
local retried = lastSent("rewards.checkin").args
check(backMia.day == dayD and backMia.claimedCount == 1 and retried.error == "stale_request"
    and L.getBalance("mig-mia", "survivor").available == 0,
    "revisiting that day with the ledger cache gone still knows the first reward was handed out, so the upgrade did not turn one payment into two")
check(R.state("mig-nia", nowMs).claimedCount == 2 and L.getBalance("mig-nia", "survivor").available == 0,
    "the counted record comes back at two as well: the watermark is what survives, not the day field that was about to be reset")
SandboxVars.MinidoracatEconomy.CheckinDailyLimit = nil
SandboxVars.MinidoracatEconomy.CheckinIntervalMinutes = nil
SandboxVars.MinidoracatEconomy.CheckinAmount = nil
SandboxVars.MinidoracatEconomy.CheckinMinPlaytimeMinutes = nil
onlinePlayers = {}
end)()

-- ===== 情境六十五：同一個 requestId 換掉批次內容，是衝突不是重送 =====
io.write("scenario 65: swapping the items behind a request id is a conflict, not a resend\n")
;(function()
local Shop, Mk, Au = S.Shop, S.Market, S.Auction
modDataStore[EC.MODDATA_KEY] = nil
files, sentCommands = {}, {}
nowMs = nowMs + 61000
fire("OnServerStarted")
worldSprites = { ["100,200,0"] = "MinidoracatEconomy_terminal_0" }
local boss = fakePlayer("fp-admin"); boss.role = "admin"
local zed = fakePlayer("fp-zed"); zed.x, zed.y = 101, 200; zed.inventory = fakeInventory(120)
local ann = fakePlayer("fp-ann"); ann.x, ann.y = 101, 200; ann.inventory = fakeInventory(120)
onlinePlayers = { boss, zed, ann }
local function cmd(who, name, args)
    nowMs = nowMs + 600
    args = args or {}
    args.requestId = args.requestId or (name .. nowMs)
    withCurrency(name, args)
    fire("OnClientCommand", EC.COMMAND_MODULE, name, who, args)
    local s = lastSent(name)
    return s and s.args or {}
end
cmd(boss, "terminal.register", { x = 100, y = 200, z = 0, kind = "atm" })
L.credit("fp-ann", "survivor", 1000, "SYSTEM_MINT", { requestId = "fp-ann-seed", reasonCode = "t" })
-- 批次鍵本身：同一批任何順序同名，不同批不同名，形狀不合就沒有鍵
check(L.batchKey({ 7, 4, 11 }, 10) == "3:4,7,11"
    and L.batchKey({ 11, 7, 4 }, 10) == L.batchKey({ 4, 7, 11 }, 10)
    and L.batchKey({ 4, 7 }, 10) ~= L.batchKey({ 4, 7, 11 }, 10)
    and L.batchKey({ 1, 2.5 }, 10) == nil and L.batchKey({ 1, 2, 3 }, 2) == nil and L.batchKey("nope", 10) == nil,
    "the batch key is the sorted lot itself: it ignores the order the client sent, tells a subset from a superset, and refuses a malformed or oversized list outright")
-- 收購：同 SKU、同幣、同件數，但換成另外兩支斧頭
cmd(boss, "admin.catalog", { action = "set", id = "axe", buybackCap = 10,
    prices = { survivor = { bidPrice = 60, buyback = true } } })
SandboxVars.MinidoracatEconomy.ShopBuybackEnabled = true
SandboxVars.MinidoracatEconomy.ShopBuybackPerAccountDaily = 5000
SandboxVars.MinidoracatEconomy.ShopBuybackServerDaily = 50000
local rev = Shop.revision()
local axes = {}
for i = 1, 4 do axes[i] = instanceItem("Base.Axe"); zed.inventory:AddItem(axes[i]) end
local sold = cmd(zed, "shop.sell", { id = "axe", itemIds = { axes[1].id, axes[2].id }, currency = "survivor", revision = rev, requestId = "fp-sell" })
local reordered = cmd(zed, "shop.sell", { id = "axe", itemIds = { axes[2].id, axes[1].id }, currency = "survivor", revision = rev, requestId = "fp-sell" })
check(sold.ok == true and L.getBalance("fp-zed", "survivor").available == 120
    and reordered.duplicate == true and reordered.txId == sold.txId
    and L.getBalance("fp-zed", "survivor").available == 120,
    "the same two items sent back in the other order is the same sale: it answers with the original transaction and mints nothing more")
local swapped = cmd(zed, "shop.sell", { id = "axe", itemIds = { axes[3].id, axes[4].id }, currency = "survivor", revision = rev, requestId = "fp-sell" })
check(swapped.error == "request_conflict" and L.getBalance("fp-zed", "survivor").available == 120
    and zed.inventory.count("Base.Axe") == 2,
    "two different axes under the same request id is a conflict: nothing is minted a second time and the other two axes are still in the backpack")
-- 上架：同幣同件數換價格，以及同價格換物品
local nails = {}
for i = 1, 4 do nails[i] = instanceItem("Base.Nails"); ann.inventory:AddItem(nails[i]) end
local listed = cmd(ann, "market.list", { itemIds = { nails[1].id, nails[2].id }, price = 40, currency = "survivor", requestId = "fp-list" })
local repriced = cmd(ann, "market.list", { itemIds = { nails[1].id, nails[2].id }, price = 50, currency = "survivor", requestId = "fp-list" })
local restocked = cmd(ann, "market.list", { itemIds = { nails[3].id, nails[4].id }, price = 40, currency = "survivor", requestId = "fp-list" })
check(listed.ok == true and repriced.error == "request_conflict" and restocked.error == "request_conflict"
    and #Mk.mine("fp-ann") == 1 and ann.inventory.count("Base.Nails") == 2,
    "a listing request id is tied to its price and to the exact lot behind it: changing either one is refused and no second listing appears")
local sameList = cmd(ann, "market.list", { itemIds = { nails[2].id, nails[1].id }, price = 40, currency = "survivor", requestId = "fp-list" })
check(sameList.duplicate == true and #Mk.mine("fp-ann") == 1,
    "the identical lot in the other order is still the same listing request")
-- 拍賣：同幣同起標價換時數
local logs = {}
for i = 1, 4 do logs[i] = instanceItem("Base.Twine"); ann.inventory:AddItem(logs[i]) end
local auctioned = cmd(ann, "auction.create", { itemIds = { logs[1].id, logs[2].id }, startPrice = 100, hours = 24, currency = "survivor", requestId = "fp-auction" })
local rehoured = cmd(ann, "auction.create", { itemIds = { logs[1].id, logs[2].id }, startPrice = 100, hours = 48, currency = "survivor", requestId = "fp-auction" })
local sameAuction = cmd(ann, "auction.create", { itemIds = { logs[2].id, logs[1].id }, startPrice = 100, hours = 24, currency = "survivor", requestId = "fp-auction" })
check(auctioned.ok == true and rehoured.error == "request_conflict" and sameAuction.duplicate == true
    and Au.ownerCount("fp-ann") == 1 and ann.inventory.count("Base.Twine") == 2,
    "a different duration under the same request id is a conflict while the identical order is a resend: one auction either way")
SandboxVars.MinidoracatEconomy.ShopBuybackEnabled = nil
SandboxVars.MinidoracatEconomy.ShopBuybackPerAccountDaily = nil
SandboxVars.MinidoracatEconomy.ShopBuybackServerDaily = nil
-- fee 0 也要防重：沒有金流不代表可以重複建單
SandboxVars.MinidoracatEconomy.MarketListingFeePercent = 0
local free = {}
for i = 1, 4 do free[i] = instanceItem("Base.Nails"); ann.inventory:AddItem(free[i]) end
local annBal = L.getBalance("fp-ann", "survivor").available
local listedFree = cmd(ann, "market.list", { itemIds = { free[1].id, free[2].id }, price = 40, currency = "survivor", requestId = "fp-free" })
local freeAgain = cmd(ann, "market.list", { itemIds = { free[2].id, free[1].id }, price = 40, currency = "survivor", requestId = "fp-free" })
check(listedFree.ok == true and L.getBalance("fp-ann", "survivor").available == annBal
    and freeAgain.duplicate == true and freeAgain.listingId == listedFree.listingId
    and #Mk.mine("fp-ann") == 2,
    "a listing that costs nothing is still remembered: the resend answers with the same listing instead of opening a second one, and neither call moved money")
local freeSwap = cmd(ann, "market.list", { itemIds = { free[3].id, free[4].id }, price = 40, currency = "survivor", requestId = "fp-free" })
local freePrice = cmd(ann, "market.list", { itemIds = { free[1].id, free[2].id }, price = 55, currency = "survivor", requestId = "fp-free" })
check(freeSwap.error == "request_conflict" and freePrice.error == "request_conflict"
    and #Mk.mine("fp-ann") == 2 and ann.inventory.count("Base.Nails") == 4,
    "with no fee to charge the conflict check still holds: another lot or another price under the same id creates nothing")
SandboxVars.MinidoracatEconomy.MarketListingFeePercent = nil
onlinePlayers = {}
end)()

-- ===== 情境六十六：讀不出來的錢包列算未知，不算 0 =====
io.write("scenario 66: a wallet row nobody can read is counted as unknown, never as zero\n")
;(function()
modDataStore[EC.MODDATA_KEY] = nil
files, sentCommands = {}, {}
nowMs = nowMs + 61000
fire("OnServerStarted")
local boss = fakePlayer("unr-admin"); boss.role = "admin"
local mod = fakePlayer("unr-mod"); mod.role = "moderator"
onlinePlayers = { boss, mod }
local function cmd(who, name, args)
    nowMs = nowMs + 600
    args = args or {}
    args.requestId = args.requestId or (name .. nowMs)
    fire("OnClientCommand", EC.COMMAND_MODULE, name, who, args)
    local s = lastSent(name)
    return s and s.args or {}
end
L.credit("unr-good", "survivor", 300, "SYSTEM_MINT", { requestId = "unr-good-seed", reasonCode = "t" })
L.credit("unr-zero", "survivor", 5, "SYSTEM_MINT", { requestId = "unr-zero-in", reasonCode = "t" })
L.debit("unr-zero", "survivor", 5, "SYSTEM_TAX", { requestId = "unr-zero-out", reasonCode = "t" })
local data = S.modData()
data.wallets["unr-broken"] = { survivor = { available = 7 } }                 -- 缺 reserved
data.wallets["unr-junk"] = { survivor = { available = 0 / 0, reserved = 0 } } -- NaN
L.credit("unr-good", "survivor", 1, "SYSTEM_MINT", { requestId = "unr-good-top", reasonCode = "t" })
local sys = cmd(mod, "admin.system")
local supply = sys.supply.survivor
local inTop = false
for _, row in ipairs(supply.top or {}) do
    if row.account == "unr-broken" or row.account == "unr-junk" or row.account == "unr-zero" then inTop = true end
end
check(supply.unreadable == 2 and supply.complete == false and supply.players == 301 and supply.holders == 1
    and not inTop,
    "two rows nobody can read are reported as unreadable instead of being silently treated as zero, and neither they nor an empty account are named among the top holders")
local desc = cmd(mod, "admin.accounts", { page = 1, sort = "survivor", descending = true })
local asc = cmd(mod, "admin.accounts", { page = 1, sort = "survivor" })
local function placeOf(reply, username)
    for i, row in ipairs(reply.items or {}) do if row.username == username then return i, row end end
end
local descBroken, brokenRow = placeOf(desc, "unr-broken")
local descJunk = placeOf(desc, "unr-junk")
local ascBroken = placeOf(asc, "unr-broken")
local _, zeroRow = placeOf(desc, "unr-zero")
check(brokenRow ~= nil and descJunk ~= nil and ascBroken ~= nil
    and brokenRow.balances.survivor.unknown == true and brokenRow.balances.survivor.total == nil
    and descBroken >= #desc.items - 1 and descJunk >= #desc.items - 1 and ascBroken >= #asc.items - 1
    and zeroRow ~= nil and zeroRow.balances.survivor.total == 0,
    "an unreadable row still appears in the list, says so instead of claiming a number, and sinks to the bottom whichever way the column is sorted; a real empty wallet is still a real zero")
-- 公開榜寧可不說話，也不在資料不完整時給一份看起來權威的名次
local dirty = cmd(mod, "leaderboard", { kind = "wealth", currency = "survivor", page = 1 })
check(dirty.ok == false and dirty.error == "data_unreadable" and dirty.currency == "survivor"
    and dirty.entries == nil and dirty.self == nil and dirty.total == nil,
    "a ranking built on rows nobody can read is refused outright, and the refusal names neither the accounts nor a partial total")
-- 整個錢包根壞掉：每一個幣都算未知，不得被當成零初始化
S.modData().wallets["unr-root"] = "this is not a wallet"
L.credit("unr-good", "survivor", 1, "SYSTEM_MINT", { requestId = "unr-root-bump", reasonCode = "t" })
local withRoot = cmd(mod, "admin.accounts", { page = 1, sort = "username" })
local _, rootRow = placeOf(withRoot, "unr-root")
check(rootRow ~= nil and rootRow.balances.survivor.unknown == true and rootRow.balances.cat.unknown == true
    and rootRow.balances.survivor.total == nil and rootRow.balances.cat.total == nil,
    "an account whose whole wallet is unreadable is still listed, and every currency says unknown instead of being initialised to zero")
-- 清乾淨之後榜就回來了：那是閘門，不是永久關閉
S.modData().wallets["unr-root"] = nil
S.modData().wallets["unr-broken"] = nil
S.modData().wallets["unr-junk"] = nil
L.credit("unr-good", "survivor", 1, "SYSTEM_MINT", { requestId = "unr-clean-bump", reasonCode = "t" })
local clean = cmd(mod, "leaderboard", { kind = "wealth", currency = "survivor", page = 1 })
check(clean.ok == true and clean.entries ~= nil and clean.entries[1] ~= nil
    and clean.entries[1].username == "unr-good" and clean.entries[1].rank == 1
    and clean.self ~= nil and clean.self.amount == 0,
    "once the unreadable rows are gone the board answers again: the refusal is a gate on the data, not a latch on the feature")
onlinePlayers = {}
end)()

-- ===== 情境六十七：連線時間從進門開始算，不是從下一個 tick =====
io.write("scenario 67: connected time starts at the door, not at the next tick\n")
;(function()
modDataStore[EC.MODDATA_KEY] = nil
files, sentCommands = {}, {}
SandboxVars.MinidoracatEconomy.RewardDayResetHour = 4
SandboxVars.MinidoracatEconomy.RewardTimezoneUTC = 8
SandboxVars.MinidoracatEconomy.CheckinMinPlaytimeMinutes = 2
nowMs = 1788699986478
fire("OnServerStarted")
local gus = fakePlayer("door-gus")
onlinePlayers = { gus }
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "hello", gus, {})
nowMs = nowMs + 90600
fire("OnClientCommand", EC.COMMAND_MODULE, "rewards.state", gus, {})
check(lastSent("rewards.state").args.playedMs == 90600,
    "the handshake is what starts the clock: ninety seconds later the whole stretch is already there, without waiting for a tick")
local before = R.state("door-gus", nowMs).playedMs
onlinePlayers = {}
nowMs = nowMs + 600000
gus = fakePlayer("door-gus")
onlinePlayers = { gus }
fire("OnNewGame", gus, nil)
nowMs = nowMs + 30600
fire("OnClientCommand", EC.COMMAND_MODULE, "rewards.state", gus, {})
check(lastSent("rewards.state").args.playedMs == before + 30600,
    "a respawn opens its own stretch at once: the ten minutes between the two characters are never paid for")
SandboxVars.MinidoracatEconomy.CheckinMinPlaytimeMinutes = nil
onlinePlayers = {}
end)()

-- ===== 情境六十八：第三輪審查的六條邊界 =====
io.write("scenario 68: request keys, resend fingerprints, a shelf switch and an unprovable high bid\n")
;(function()
local Shop = S.Shop
modDataStore[EC.MODDATA_KEY] = nil
files, sentCommands = {}, {}
nowMs = nowMs + 61000
files[S.Shop.FILE] = { lines = { EC.jsonEncode({ items = {
    { id = "pack", item = "Base.Twine", qty = 2, prices = { survivor = { price = 20, bidPrice = 8, buyback = true } } },
} }) }, opens = 0 }
fire("OnServerStarted")
worldSprites = { ["100,200,0"] = "MinidoracatEconomy_terminal_0" }
local boss = fakePlayer("r3-admin"); boss.role = "admin"
local zed = fakePlayer("r3-zed"); zed.x, zed.y = 101, 200; zed.inventory = fakeInventory(80)
local ann = fakePlayer("r3-ann"); ann.x, ann.y = 101, 200; ann.inventory = fakeInventory(80)
local bob = fakePlayer("r3-bob"); bob.x, bob.y = 101, 200; bob.inventory = fakeInventory(80)
local longName = string.rep("q", 40)
local qq = fakePlayer(longName); qq.x, qq.y = 101, 200; qq.inventory = fakeInventory(80)
onlinePlayers = { boss, zed, ann, bob, qq }
local function cmd(who, name, args)
    nowMs = nowMs + 600
    args = args or {}
    args.requestId = args.requestId or (name .. nowMs)
    withCurrency(name, args)
    fire("OnClientCommand", EC.COMMAND_MODULE, name, who, args)
    local s = lastSent(name)
    return s and s.args or {}
end
cmd(boss, "terminal.register", { x = 100, y = 200, z = 0, kind = "atm" })
for _, who in ipairs({ "r3-zed", "r3-ann", "r3-bob", longName }) do
    L.credit(who, "survivor", 900, "SYSTEM_MINT", { requestId = "r3-s-" .. who, reasonCode = "t" })
    L.credit(who, "cat", 400, "SYSTEM_MINT", { requestId = "r3-c-" .. who, reasonCode = "t" })
end
SandboxVars.MinidoracatEconomy.ShopBuybackEnabled = true
SandboxVars.MinidoracatEconomy.ShopBuybackPerAccountDaily = 900
SandboxVars.MinidoracatEconomy.ShopBuybackServerDaily = 9000
-- 太長的完整鍵在任何東西移動之前就被擋下
local tooLong = cmd(qq, "shop.buy", { id = "pack", currency = "survivor", revision = Shop.revision(), requestId = string.rep("r", 96) })
check(tooLong.error == "request_too_long" and L.getBalance(longName, "survivor").available == 900
    and qq.inventory.count("Base.Twine") == 0,
    "a request id that only becomes too long once the account name is prefixed is refused before anything moves, not truncated into somebody else's key")
-- 重送認的是玩家當時確認過的那份報價，不是現在的份數
local twine = {}
for i = 1, 4 do twine[i] = instanceItem("Base.Twine"); zed.inventory:AddItem(twine[i]) end
local sellRev = Shop.revision()
local sale = cmd(zed, "shop.sell", { id = "pack", itemIds = { twine[1].id, twine[2].id }, currency = "survivor", revision = sellRev, requestId = "r3-sell" })
local balAfterSale = L.getBalance("r3-zed", "survivor").available
cmd(boss, "admin.catalog", { action = "set", id = "pack", qty = 1 })
local resent = cmd(zed, "shop.sell", { id = "pack", itemIds = { twine[1].id, twine[2].id }, currency = "survivor", revision = sellRev, requestId = "r3-sell" })
check(sale.ok == true and sale.count == 1 and resent.duplicate == true and resent.count == 1
    and L.getBalance("r3-zed", "survivor").available == balAfterSale,
    "an administrator changing how many pieces a share is does not turn a resend into a different order: the original sale answers again and mints nothing")
local reRevision = cmd(zed, "shop.sell", { id = "pack", itemIds = { twine[1].id, twine[2].id }, currency = "survivor", revision = Shop.revision(), requestId = "r3-sell" })
check(reRevision.error == "request_conflict" and L.getBalance("r3-zed", "survivor").available == balAfterSale,
    "the quote the player confirmed is part of the request: the same id sent against a newer catalog is a conflict")
local firstBuy = cmd(zed, "shop.buy", { id = "pack", currency = "survivor", revision = Shop.revision(), requestId = "r3-buy" })
cmd(boss, "admin.catalog", { action = "set", id = "pack", qty = 2 })
local secondBuy = cmd(zed, "shop.buy", { id = "pack", currency = "survivor", revision = Shop.revision(), requestId = "r3-buy" })
check(firstBuy.ok == true and secondBuy.error == "request_conflict",
    "a purchase carries the revision it was priced against, so the same id against a newer catalog is a conflict rather than a silent repeat")
-- 下架只停止販售，收購照舊
cmd(boss, "admin.catalog", { action = "set", id = "pack", enabled = false })
local offRev = Shop.revision()
local t5, t6 = instanceItem("Base.Twine"), instanceItem("Base.Twine")
zed.inventory:AddItem(t5); zed.inventory:AddItem(t6)
local beforeOffSale = L.getBalance("r3-zed", "survivor").available
local offSale = cmd(zed, "shop.sell", { id = "pack", itemIds = { t5.id, t6.id }, currency = "survivor", revision = offRev, requestId = "r3-off-sell" })
local offBuy = cmd(zed, "shop.buy", { id = "pack", currency = "survivor", revision = offRev, requestId = "r3-off-buy" })
check(offSale.ok == true and offBuy.error == "unknown_sku"
    and L.getBalance("r3-zed", "survivor").available > beforeOffSale,
    "taking a product off the shelf stops selling it to players; it does not quietly stop buying it back from them")
-- 下架列的收購價仍然算進套利檢查
cmd(boss, "admin.catalog", { action = "add", id = "plank1", item = "Base.Plank", qty = 1, prices = { survivor = { price = 10 } } })
local arb = cmd(boss, "admin.catalog", { action = "add", id = "plank5", item = "Base.Plank", qty = 5, enabled = false,
    prices = { survivor = { price = 100, bidPrice = 60, buyback = true } } })
check(arb.error == "arbitrage_rejected" and Shop.sku("plank5") == nil,
    "a row that is off the shelf still buys back, so its bid still closes the circle and the pair is refused")
-- shop.candidates 讀不到背包時說讀不到，不回一份空清單
zed.inventory = nil
local blind = cmd(zed, "shop.candidates", { id = "pack", currency = "survivor" })
zed.inventory = fakeInventory(80)
check(blind.ok == false and blind.error == "read_failed" and blind.id == "pack" and blind.currency == "survivor",
    "a backpack the server cannot read is reported as unreadable instead of being offered as an empty list of nothing to sell")
-- 已宣告新 schema 的拍賣，缺幣的 highest 不得被補上
local axe = instanceItem("Base.Axe"); ann.inventory:AddItem(axe)
local auction = cmd(ann, "auction.create", { itemId = axe.id, startPrice = 20, hours = 24, currency = "cat", requestId = "r3-auction" })
cmd(bob, "auction.bid", { auctionId = auction.auctionId, amount = 30, currency = "cat", requestId = "r3-bid" })
local record = S.modData().auctions.items[auction.auctionId]
record.tradeSchema, record.currency = 2, "cat"
record.highest.currency = nil
nowMs = nowMs + 1000
fire("OnServerStarted")
local held = S.modData().auctions.items[auction.auctionId]
local refusedBid = cmd(zed, "auction.bid", { auctionId = auction.auctionId, amount = 60, currency = "cat", requestId = "r3-bid-2" })
check(held.blocked == "currency_unknown" and held.highest.currency == nil and held.highest.bidder == "r3-bob"
    and held.highest.amount == 30 and refusedBid.error == "currency_unknown",
    "a record that already claims the new schema does not get a currency written into its high bid: the gap is held and the next bid is refused")
SandboxVars.MinidoracatEconomy.ShopBuybackEnabled = nil
SandboxVars.MinidoracatEconomy.ShopBuybackPerAccountDaily = nil
SandboxVars.MinidoracatEconomy.ShopBuybackServerDaily = nil
onlinePlayers = {}
end)()

-- ===== 情境六十九：來源是死是活答不出來時，不能當成死的結案 =====
io.write("scenario 69: when the source cannot be looked up the receipt is held, not closed\n")
;(function()
local Rec = S.Recovery
modDataStore[EC.MODDATA_KEY] = nil
files, sentCommands = {}, {}
nowMs = nowMs + 61000
fire("OnServerStarted")
worldSprites = { ["100,200,0"] = "MinidoracatEconomy_terminal_0" }
local boss = fakePlayer("r4-admin"); boss.role = "admin"
local ann = fakePlayer("r4-ann"); ann.x, ann.y = 101, 200; ann.inventory = fakeInventory(80)
local bob = fakePlayer("r4-bob"); bob.x, bob.y = 101, 200; bob.inventory = fakeInventory(80)
onlinePlayers = { boss, ann, bob }
local function cmd(who, name, args)
    nowMs = nowMs + 600
    args = args or {}
    args.requestId = args.requestId or (name .. nowMs)
    withCurrency(name, args)
    fire("OnClientCommand", EC.COMMAND_MODULE, name, who, args)
    local s = lastSent(name)
    return s and s.args or {}
end
cmd(boss, "terminal.register", { x = 100, y = 200, z = 0, kind = "atm" })
L.credit("r4-ann", "survivor", 500, "SYSTEM_MINT", { requestId = "r4-ann-seed", reasonCode = "t" })
L.credit("r4-bob", "survivor", 500, "SYSTEM_MINT", { requestId = "r4-bob-seed", reasonCode = "t" })
local n1, n2 = instanceItem("Base.Nails"), instanceItem("Base.Nails")
ann.inventory:AddItem(n1); ann.inventory:AddItem(n2)
local listed = cmd(ann, "market.list", { itemIds = { n1.id, n2.id }, price = 40, currency = "survivor", requestId = "r4-list" })
local ref = listed.listingId
cmd(bob, "market.buy", { listingId = ref, price = 40, currency = "survivor", requestId = "r4-buy" })
-- 代理只換掉 S.Market 的一個查表函式；ECMarket 自己的 handler 走 local upvalue，不受影響
local realMarket = S.Market
local proxy = {}
for k, v in pairs(realMarket) do proxy[k] = v end
proxy.listingExists = function() error("probe: lookup failed") end
S.Market = proxy
local thrown = Rec.sourceAlive(ref)
proxy.listingExists = nil
local missing = Rec.sourceAlive(ref)
S.Market = realMarket
local readable = Rec.sourceAlive(ref)
check(thrown == nil and missing == nil and readable == false,
    "a lookup that throws and a lookup that is not there both answer unknown, and only a lookup that really ran may answer that the source is gone")
-- 收斂時答不出來：既不結案，也不裝作沒事
proxy.listingExists = function() error("probe: lookup failed") end
S.Market = proxy
cmd(ann, "hello")
S.Market = realMarket
local receipt = Rec.receipt(ref)
local heldRow = Rec.heldRecord("r4-ann", "receipt:" .. ref)
check(receipt ~= nil and receipt.closed == nil
    and heldRow ~= nil and heldRow.reason == "source_state_unknown" and heldRow.resolvedAt == nil,
    "a reconcile that cannot see whether the source is still there leaves the receipt open and writes down that it does not know, instead of filing it as finished")
-- 保留證據不等於永久卡住：探針恢復可讀後，下一次收斂自己結案，不必管理員介入。
-- 先翻頁再收斂：同 epoch 的 receipt 每輪都會被重新保險成 pending，那是規則三要的行為，
-- 不是這條在測的東西。
nowMs = nowMs + 1000
fire("OnServerStarted")
cmd(ann, "hello")
local healed = Rec.heldRecord("r4-ann", "receipt:" .. ref)
check(healed ~= nil and healed.resolvedAt ~= nil and healed.note == "source_readable"
    and Rec.receipt(ref).closed ~= nil,
    "once the lookup works again the next reconcile retires its own doubt and files the receipt: holding evidence is not the same as jamming the account open forever")
-- 來源持續讀不動：重複收斂不會把「不知道」磨成「知道」。這裡不用手動塞一個收斂無從回答的
-- reason 去硬碰不可達狀態，而是讓探針一直壞著，看那筆保留會不會被反覆的收斂消磨掉。
local n3, n4 = instanceItem("Base.Nails"), instanceItem("Base.Nails")
ann.inventory:AddItem(n3); ann.inventory:AddItem(n4)
local second = cmd(ann, "market.list", { itemIds = { n3.id, n4.id }, price = 40, currency = "survivor", requestId = "r4-list-2" })
local ref2 = second.listingId
cmd(bob, "market.buy", { listingId = ref2, price = 40, currency = "survivor", requestId = "r4-buy-2" })
proxy.listingExists = function() error("probe: lookup failed") end
S.Market = proxy
cmd(ann, "hello")
nowMs = nowMs + 1000
fire("OnServerStarted")
cmd(ann, "hello")
S.Market = realMarket
local stubborn = Rec.heldRecord("r4-ann", "receipt:" .. ref2)
check(stubborn ~= nil and stubborn.reason == "source_state_unknown" and stubborn.resolvedAt == nil
    and Rec.receipt(ref2).closed == nil,
    "a source that stays unreadable stays held: running the reconcile again and again never wears the doubt down into a decision")
onlinePlayers = {}
end)()

-- ===== 情境八十：管理端對帳面對「誰說的」四種答案 =====
io.write("scenario 80: what the reconciliation page may do when the server cannot vouch for the claim\n")
;(function()
local M, Rec = S.Mailbox, S.Recovery
local KEY = EC.PLAYER_MODDATA_KEY
local function deepCopy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = deepCopy(v) end
    return out
end
modDataStore[EC.MODDATA_KEY] = nil
files, sentCommands, writerDeny = {}, {}, {}
nowMs = nowMs + 61000
fire("OnServerStarted")
worldSprites = { ["100,200,0"] = "MinidoracatEconomy_terminal_0" }
local boss = fakePlayer("r5-admin"); boss.role = "admin"
local ann = fakePlayer("r5-ann"); ann.x, ann.y = 101, 200; ann.inventory = fakeInventory(80)
local zed = fakePlayer("r5-zed"); zed.x, zed.y = 101, 200; zed.inventory = fakeInventory(80)
onlinePlayers = { boss, ann, zed }
local function cmd(who, name, args)
    nowMs = nowMs + 600
    args = args or {}
    args.requestId = args.requestId or (name .. nowMs)
    withCurrency(name, args)
    fire("OnClientCommand", EC.COMMAND_MODULE, name, who, args)
    local s = lastSent(name)
    return s and s.args or {}
end
local function rowOf(reply, key)
    for _, row in ipairs(reply.records or {}) do
        if row.key == key then return row end
    end
end
local function pump(who)
    proofPump(who)
end
cmd(boss, "terminal.register", { x = 100, y = 200, z = 0, kind = "atm" })
-- journalAt 不再是權威，連複製都不該把它帶出去：否則偽造的時間戳會搭著副本流進判定
local copied = Rec.copyReplay({ kind = "listing", qty = 2, price = 30, currency = "survivor",
    snapshot = { type = "Base.Plank" }, journalAt = 4102444800000, at = nowMs })
check(type(copied) == "table" and copied.journalAt == nil
    and copied.price == 30 and copied.qty == 2 and copied.currency == "survivor",
    "the replay copy carries the economics and leaves the timestamp hint behind: a forged journalAt cannot ride into a judgement on the back of a copy")
SandboxVars.MinidoracatEconomy.MarketListingFeePercent = 0
L.credit("r5-ann", "survivor", 500, "SYSTEM_MINT", { requestId = "r5-ann-seed", reasonCode = "t" })
-- (1) 憑空的 pending：伺服器手上完全沒有這筆操作的紀錄。
-- 提交點必須來自**一筆真的、已落盤、然後被回滾的作業**（沿用 ProofTests 情境 71 驗過的作法）：
-- 當前 epoch 的 pending 是「這一輪自己的在途工作」，判定是 keep 而不是申訴；手鑄的 id 也造不出
-- 一份形狀正確的 origins。所以先做真的、再從它複製出一個伺服器從未提交過的 opId。
cmd(zed, "hello")
local groundSave = deepCopy(modDataStore[EC.MODDATA_KEY])
local groundPlank = instanceItem("Base.Plank"); zed.inventory:AddItem(groundPlank)
local groundList = cmd(zed, "market.list", { itemId = groundPlank.id, price = 30, currency = "survivor", requestId = "r5-zed-real" })
proofSettle()
local zedInv, zedMd = deepCopy(zed.inventory.items), deepCopy(zed.modData)
modDataStore[EC.MODDATA_KEY] = groundSave
nowMs = nowMs + 1000
fire("OnServerStarted")
zed.inventory.items = zedInv; zed.modData = zedMd
local realPend = zed.modData[KEY].pendingOuts[groundList.listingId]
local ghostEpoch = realPend.epoch
local ghostId = ghostEpoch .. ":9901"
local ghost = deepCopy(realPend)
ghost.origins = { { src = "native", nativeId = 880001 } }
ghost.itemIds, ghost.itemId = { 880001 }, 880001
ghost.snapshot = { type = "Base.Plank", condition = 10, uses = 1, age = 0, repaired = 0 }
ghost.price, ghost.qty, ghost.lotQty = 30, 1, 1
ghost.seq = 9901
zed.modData[KEY].pendingOuts[ghostId] = ghost
cmd(zed, "hello")
pump("r5-zed")
local claimList = cmd(boss, "admin.recovery", { action = "list", username = "r5-zed" })
local claimRow = rowOf(claimList, "pend:" .. ghostId)
check(claimList.ok == true and claimRow ~= nil and claimRow.source == "player_claim" and claimRow.unproven == true
    and claimRow.actions.restore == true and claimRow.actions.discard == true,
    "a pending the server has no record of is labelled as the player's own claim and still offers a human way out, instead of becoming a row nobody can ever act on")
local receiptsBefore = #L.receipts("r5-zed")
local refused = cmd(boss, "admin.recovery", { action = "resolve", username = "r5-zed", key = "pend:" .. ghostId,
    decision = "restore", revision = claimRow and claimRow.revision or "x", note = "restoring without any server proof at all" })
check(refused.ok ~= true and refused.error == "recovery_unproven_source"
    and zed.modData[KEY].pendingOuts[ghostId] ~= nil and M.unclaimed("r5-zed") == 0,
    "taking the player's word is a deliberate act: the ordinary restore is refused and neither the pending nor the mailbox changes")
local accepted = cmd(boss, "admin.recovery", { action = "resolve", username = "r5-zed", key = "pend:" .. ghostId,
    decision = "restore", revision = (rowOf(cmd(boss, "admin.recovery", { action = "list", username = "r5-zed" }), "pend:" .. ghostId) or {}).revision,
    acceptUnproven = true, note = "accepted on the player's word, no server proof exists" })
check(accepted.ok == true and accepted.mailId ~= nil and M.entryOf("r5-zed", accepted.mailId) ~= nil
    and #L.receipts("r5-zed") == receiptsBefore and L.getBalance("r5-zed", "survivor").available == 0,
    "an accepted claim hands the goods back through the mailbox and posts nothing at all: no mint, no adjustment, no way around the admin daily cap")
local auditRow = X.auditEntries(5)[1]
check(auditRow ~= nil and type(auditRow.after) == "string"
    and string.find(auditRow.after, "player_claim/journal_missing", 1, true) ~= nil
    and string.find(auditRow.after, "mail", 1, true) ~= nil,
    "the audit line says whose word this was: an entry taken on the player's claim can never be mistaken later for one the server proved")
-- (2) 伺服器有原始記錄，但玩家那份自稱的提交點對不上
local saveB = deepCopy(modDataStore[EC.MODDATA_KEY])
local plank = instanceItem("Base.Plank"); ann.inventory:AddItem(plank)
local listed = cmd(ann, "market.list", { itemId = plank.id, price = 50, currency = "survivor", requestId = "r5-list" })
proofSettle()                                              -- 權威證據真的落盤（有界，不假設一個 tick 就夠）
-- 竄改的是經濟內容（幣、價、件數、物品），不是提交點：新契約下改 seq 本身已經不算竄改
local annInv, annMd = deepCopy(ann.inventory.items), deepCopy(ann.modData)
modDataStore[EC.MODDATA_KEY] = saveB
nowMs = nowMs + 1000
fire("OnServerStarted")
ann.inventory.items = annInv; ann.modData = annMd
local pend = ann.modData[KEY].pendingOuts[listed.listingId]
pend.snapshot.type, pend.qty, pend.lotQty = "Base.Axe", 5, 5
pend.price, pend.currency = 999999, "cat"
cmd(ann, "hello")
pump("r5-ann")
local mrow = rowOf(cmd(boss, "admin.recovery", { action = "list", username = "r5-ann" }), "pend:" .. listed.listingId)
check(mrow ~= nil and mrow.source == "journal" and mrow.unproven == nil and mrow.actions.restore == true
    and mrow.item == "Base.Plank" and mrow.qty == 1,
    "a player file that rewrites its own economics does not get to describe the row: the page is sourced from the journal, shows what the server wrote down, and still offers the ordinary restore")
local proved = cmd(boss, "admin.recovery", { action = "resolve", username = "r5-ann", key = "pend:" .. listed.listingId,
    decision = "restore", revision = mrow.revision, note = "restoring from the server's own record of this operation" })
local returned = proved.mailId and M.entryOf("r5-ann", proved.mailId) or nil
check(proved.ok == true and returned ~= nil and returned.item == "Base.Plank" and returned.qty == 1,
    "the goods that come back are the ones the server wrote down: the axe and the five copies the player's own file claims are not what the record says")
-- 人工重建本身是一筆「現在發生」的新操作：它的提交點必須排在它據以重建的後繼之後，
-- 絕不能被它預覽的那個 previous 的舊序號取代，否則下一次回滾會挑到錯的一行。
proofSettle()
-- 鏈要從**這個 op 自己的固定檔**讀（檔名由 opId 派生），不能掃「路徑裡有這個帳號」的任一檔：
-- 同一個帳號同時有好幾筆作業，掃到哪一份是 pairs 的順序決定的，那會讓這一格量到別人的鏈。
local opChain = proofJournalChain("r5-ann", listed.listingId)
local chainTail, chainPrev = opChain[#opChain], opChain[#opChain - 1]
check(chainTail ~= nil and chainPrev ~= nil
    and tonumber(chainTail.seq) ~= nil and tonumber(chainPrev.seq) ~= nil
    and tonumber(chainTail.seq) > tonumber(chainPrev.seq)
    and chainTail.epoch == S.modData().meta.epoch and chainTail.kind ~= "discard"
    and chainTail.replay ~= nil and chainTail.replay.protocol == Rec.PROTOCOL,
    "the restore an administrator performed writes its own commit point at today's epoch, after the successor it was built from: a rebuild never re-enters the chain wearing the older sequence it previewed")
-- (3) 記錄找得到，但它自己的下場無法證明；以及還在讀取中的那一格
local saveC = deepCopy(modDataStore[EC.MODDATA_KEY])
local saw = instanceItem("Base.Saw"); ann.inventory:AddItem(saw)
local second = cmd(ann, "market.list", { itemId = saw.id, price = 60, currency = "survivor", requestId = "r5-list-2" })
proofSettle()
local lostEpoch = S.modData().meta.epoch
annInv, annMd = deepCopy(ann.inventory.items), deepCopy(ann.modData)
modDataStore[EC.MODDATA_KEY] = saveC
nowMs = nowMs + 1000
fire("OnServerStarted")
ann.inventory.items = annInv; ann.modData = annMd
cmd(ann, "hello")
local reading = rowOf(cmd(boss, "admin.recovery", { action = "list", username = "r5-ann" }), "pend:" .. second.listingId)
check(reading ~= nil and reading.blocked == "journal_pending" and reading.unproven == nil
    and reading.actions.restore == false and reading.actions.discard == false,
    "while the proof is still being read the page offers nothing at all: a row in the middle of a lookup is not a row an administrator may act on")
local hist = S.modData().meta.history
for i = #hist, 1, -1 do if hist[i].epoch == lostEpoch then table.remove(hist, i) end end
pump("r5-ann")
local unverified = rowOf(cmd(boss, "admin.recovery", { action = "list", username = "r5-ann" }), "pend:" .. second.listingId)
local stubborn = cmd(boss, "admin.recovery", { action = "resolve", username = "r5-ann", key = "pend:" .. second.listingId,
    decision = "restore", revision = unverified and unverified.revision or "x", acceptUnproven = true,
    note = "trying to force a record whose own outcome is unknown" })
check(unverified ~= nil and unverified.blocked == "legacy_outcome_unverified" and unverified.outcome == "unknown"
    and unverified.actions.restore == false and unverified.actions.discard == false
    and stubborn.ok ~= true and stubborn.error == "legacy_outcome_unverified"
    and ann.modData[KEY].pendingOuts[second.listingId] ~= nil,
    "a record whose own fate cannot be established is not rescued by the human override: acceptUnproven answers for a missing record, never for an unreadable outcome")
-- (3c) 證據壞了形狀、(3d) 證據讀不動：兩者都只能重查，沒有「採納反證」的旁路
local saveD = deepCopy(modDataStore[EC.MODDATA_KEY])
local twine = instanceItem("Base.Twine"); ann.inventory:AddItem(twine)
local third = cmd(ann, "market.list", { itemId = twine.id, price = 70, currency = "survivor", requestId = "r5-list-3" })
proofSettle()
-- 要損壞的是**這一筆作業自己的檔**：檔名由 opId 派生，掃帳號名會掃到同帳號其他作業的檔。
local proofFile = proofJournalPathForOp("r5-ann", third.listingId)
local goodLines = {}
for i, line in ipairs((files[proofFile] or { lines = {} }).lines) do goodLines[i] = line end
annInv, annMd = deepCopy(ann.inventory.items), deepCopy(ann.modData)
modDataStore[EC.MODDATA_KEY] = saveD
nowMs = nowMs + 1000
fire("OnServerStarted")
ann.inventory.items = annInv; ann.modData = annMd
-- 同一個提交點兩行、內容不同：鏈本身讀不懂。reader 會連同一份 record 一起把拒絕交回來，
-- 那份 record 不得因此變成可預覽、可重建的素材 —— 讀不懂的證據不是可預覽的證據。
local duplicated = EC.jsonDecode(files[proofFile].lines[#files[proofFile].lines])
duplicated.replay.price = 4242
files[proofFile].lines[#files[proofFile].lines + 1] = EC.jsonEncode(duplicated)
cmd(ann, "hello")
pump("r5-ann")
local brokenRow = rowOf(cmd(boss, "admin.recovery", { action = "list", username = "r5-ann" }), "pend:" .. third.listingId)
local forcedBroken = cmd(boss, "admin.recovery", { action = "resolve", username = "r5-ann", key = "pend:" .. third.listingId,
    decision = "restore", revision = brokenRow and brokenRow.revision or "x", acceptUnproven = true,
    note = "trying to accept a record whose shape the server cannot read" })
check(brokenRow ~= nil and brokenRow.blocked == "journal_malformed" and brokenRow.unproven ~= true
    and brokenRow.preview == nil and brokenRow.source == nil
    and brokenRow.actions.restore == false and brokenRow.actions.discard == false
    and forcedBroken.ok ~= true and forcedBroken.error == "journal_malformed"
    and ann.modData[KEY].pendingOuts[third.listingId] ~= nil,
    "damaged evidence is not previewable evidence: the refusal may carry a record for diagnosis, but the page shows no preview, describes no goods, and offers no action - only a re-check")
-- 半行：連字都讀不完整
files[proofFile].lines = goodLines
files[proofFile].lines[#files[proofFile].lines] = '{"type":"recovery.journal","opId":'
nowMs = nowMs + 30000                      -- 讓上一次的讀取結果快取過期
cmd(ann, "hello")
pump("r5-ann")
local tornRow = rowOf(cmd(boss, "admin.recovery", { action = "list", username = "r5-ann" }), "pend:" .. third.listingId)
local forcedTorn = cmd(boss, "admin.recovery", { action = "resolve", username = "r5-ann", key = "pend:" .. third.listingId,
    decision = "restore", revision = tornRow and tornRow.revision or "x", acceptUnproven = true,
    note = "trying to accept a record that was only half written" })
check(tornRow ~= nil and tornRow.blocked == "journal_unreadable" and tornRow.unproven ~= true
    and tornRow.actions.restore == false and tornRow.actions.discard == false
    and forcedTorn.ok ~= true and forcedTorn.error == "journal_unreadable"
    and ann.modData[KEY].pendingOuts[third.listingId] ~= nil,
    "a half-written line is a read failure, not a licence to take the player's word: the override is refused here too and nothing moves")
-- (3b) 行是別人的：那不是這個帳號的證據，也不許把別人的內容端出來
-- 同樣沿用那一筆真作業的提交點：只換 opId 與內容，形狀來自伺服器自己寫過的 pending
local foreignId = ghostEpoch .. ":9902"
local foreign = deepCopy(ghost)
foreign.origins = { { src = "native", nativeId = 880021 } }
foreign.itemIds, foreign.itemId = { 880021 }, 880021
foreign.snapshot = { type = "Base.Twine", condition = 10, uses = 1, age = 0, repaired = 0 }
foreign.price, foreign.qty, foreign.lotQty, foreign.seq = 25, 1, 1, 9902
zed.modData[KEY].pendingOuts[foreignId] = foreign
-- 這一行要壞在**歸屬**上，其他一切必須合法：envelope 版本寫死 1 的話 reader 會先在版本這關
-- 擋下來（journal_malformed/field=version），根本走不到歸屬那道閘，測到的就不是這件事。
proofJournalAppend("r5-zed", foreignId, ghostEpoch, 9902,
    { kind = "listing", qty = 77, price = 1234567, currency = "cat",
      snapshot = { type = "Base.Axe", condition = 10 } },
    { owner = "r5-somebody-else", version = S.RecoveryJournal.VERSION })
cmd(zed, "hello")
pump("r5-zed")
local foreignRow = rowOf(cmd(boss, "admin.recovery", { action = "list", username = "r5-zed" }), "pend:" .. foreignId)
local shown = EC.jsonEncode(foreignRow or {})
check(foreignRow ~= nil and foreignRow.foreign == true and foreignRow.unproven ~= true
    and foreignRow.actions.restore == false and foreignRow.actions.discard == false
    and string.find(shown, "r5-somebody-else", 1, true) == nil
    and string.find(shown, "1234567", 1, true) == nil,
    "a journal line belonging to somebody else is not this account's proof: every action closes, the human override cannot move it, and neither the other account's name nor its numbers appear anywhere in the reply")
local lettersBefore = M.unclaimed("r5-zed")
local pushed = cmd(boss, "admin.recovery", { action = "resolve", username = "r5-zed", key = "pend:" .. foreignId,
    decision = "restore", revision = foreignRow and foreignRow.revision or "x", acceptUnproven = true,
    note = "trying to force a line that belongs to another account" })
local refusal = EC.jsonEncode(pushed or {})
check(pushed.ok ~= true and pushed.foreign == true
    and string.find(refusal, "r5-somebody-else", 1, true) == nil
    and string.find(refusal, "1234567", 1, true) == nil
    and zed.modData[KEY].pendingOuts[foreignId] ~= nil and M.unclaimed("r5-zed") == lettersBefore,
    "the refusal says plainly that the line belongs to someone else, moves nothing, and leaks no more than the listing did: an administrator cannot read another account through a rejected override")
-- (4) Journal 模組整個不在：不能因此改用玩家那份
local blindId = ghostEpoch .. ":9903"
local blindPend = deepCopy(ghost)
blindPend.origins = { { src = "native", nativeId = 880011 } }
blindPend.itemIds, blindPend.itemId = { 880011 }, 880011
blindPend.snapshot = { type = "Base.Saw", condition = 10, uses = 1, age = 0, repaired = 0 }
blindPend.price, blindPend.qty, blindPend.lotQty, blindPend.seq = 15, 1, 1, 9903
zed.modData[KEY].pendingOuts[blindId] = blindPend
S.RecoveryJournal = nil
cmd(zed, "hello")
pump("r5-zed")
local blind = rowOf(cmd(boss, "admin.recovery", { action = "list", username = "r5-zed" }), "pend:" .. blindId)
S.RecoveryJournal = EC.RecoveryJournal
check(blind ~= nil and blind.blocked == "journal_unavailable" and blind.unproven == nil
    and blind.actions.restore == false and blind.actions.discard == false
    and zed.modData[KEY].pendingOuts[blindId] ~= nil,
    "with the evidence module absent the page says it cannot tell rather than falling back on the copy the player brought")
SandboxVars.MinidoracatEconomy.MarketListingFeePercent = nil
onlinePlayers = {}
end)()


-- ============================================================================
-- SECTION B — 情境 70-74（貼在 harness 尾端總結之前）
-- ============================================================================

-- ===== 情境七十：提交點寫下證據，而且只有證據能重建 =====
--
-- CORE-H1 的核心：世界回滾後，「這筆交易是什麼幣、多少錢、幾件、什麼物品、來源是誰」只能由
-- server 在提交點寫下的那一行決定。玩家存檔是唯一會被玩家改到的東西，所以它只能當「有一筆
-- 作業待處理」的指標，不能當帳。下面每一條竄改都是玩家真的改得到的欄位。
io.write("scenario 70: the commit point writes the proof, and only the proof rebuilds\n")
;(function()
local M, Mk, Rec, Au, Shop = S.Mailbox, S.Market, S.Recovery, S.Auction, S.Shop
local J = S.RecoveryJournal or {}      -- 模組沒載時第一個 check 要「失敗」，不是讓 harness 炸掉
local KEY = EC.PLAYER_MODDATA_KEY
local serial = 0
local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, value in pairs(v) do out[k] = copy(value) end
    return out
end
local function cmd(p, name, args)
    serial, nowMs = serial + 1, nowMs + 700
    args = args or {}
    args.requestId = args.requestId or ("proof70-" .. serial)
    withCurrency(name, args)
    local first = #sentCommands + 1
    fire("OnClientCommand", EC.COMMAND_MODULE, name, p, args)
    for i = first, #sentCommands do
        local reply = sentCommands[i]
        if reply.player == p and reply.command == name then return reply.args end
    end
    error("missing reply: " .. name)
end
local function fresh(tag)
    modDataStore[EC.MODDATA_KEY] = nil
    files, writerDeny, sentCommands, sentItemPackets = {}, {}, {}, {}
    worldSprites = { ["100,200,0"] = "MinidoracatEconomy_terminal_0" }
    SandboxVars.MinidoracatEconomy.MarketListingFeePercent = 0
    SandboxVars.MinidoracatEconomy.MarketSalesTaxPercent = 0
    SandboxVars.MinidoracatEconomy.MarketMaxListings = 8
    files[Shop.FILE] = { lines = { EC.jsonEncode({ items = {
        { id = "corn", item = "Base.CannedCorn", qty = 1,
            prices = { survivor = { price = 20, bidPrice = 8, buyback = true } } },
    } }) }, opens = 0 }
    nowMs = nowMs + 61000
    fire("OnServerStarted")
    local admin, seller = fakePlayer(tag .. "-admin"), fakePlayer(tag .. "-seller")
    admin.role = "admin"
    seller.inventory = fakeInventory(200)
    onlinePlayers = { admin, seller }
    assert(cmd(admin, "terminal.register", { x = 100, y = 200, z = 0, kind = "atm" }).ok)
    assert(L.credit(seller:getUsername(), "survivor", 5000, "SYSTEM_MINT",
        { requestId = tag .. "-seed", reasonCode = "test" }).ok)
    return admin, seller
end
local function native(p, fullType)
    local item = instanceItem(fullType)
    assert(item and p.inventory:AddItem(item) == item)
    return item
end
local function restart(saved)
    modDataStore[EC.MODDATA_KEY] = copy(saved)
    nowMs = nowMs + 1000
    fire("OnServerStarted")
end
local function listingOf(id) return S.modData().market.listings[id] end
local function tally(p, fullType)
    local total = p.inventory.count(fullType)
    for _, row in ipairs(Mk.mine(p:getUsername())) do
        if row.item == fullType then total = total + (row.qty or 1) end
    end
    for _, row in ipairs(M.list(p:getUsername())) do
        if row.item == fullType then total = total + (row.qty or 1) end
    end
    return total
end
local function reason(user, id)
    local rec = Rec.heldRecord(user, "pend:" .. id)
    return rec and rec.resolvedAt == nil and rec.reason or nil
end

-- ---- 模組本身：沒有 producer/reader/通知就沒有這整套防線 ----
check(type(J) == "table" and type(J.record) == "function" and type(J.lookup) == "function"
    and type(J.onReady) == "function" and type(J.journalPath) == "function"
    and J.MAX_READERS == 2 and J.BYTES_PER_TICK == 65536 and J.MAX_PATHS == 4
    and J.MAX_MONTHS == nil,
    "the recovery journal is a loaded server module with a producer, a bounded reader, a completion hook and an operation-derived path")

-- 檔名只由 opId 決定（新契約）：epoch 部分當毫秒轉月份，一個 op 永遠只有一個檔。
check(J.journalPath and J.journalPath("proof-path", "1788699986478:7")
        == proofJournalPathForOp("proof-path", "1788699986478:7")
    and proofJournalPathForOp("proof-path", "1788699986478:7")
        == X.ROOT .. "/recovery/proof-path/" .. EC.monthKey(1788699986478) .. ".json",
    "the journal path is derived from the operation id alone: no timestamp a player controls can choose the file")

-- ---- 生產者：在唯一 commit 點非同步寫下一行，且 envelope 的身分欄位對得上 receipt ----
--
-- 這裡**只釘 envelope metadata**（type/version/owner/opId/kind/提交點）與「沒有 tick 就沒有檔」。
-- replay 的經濟內容**不在這裡驗**：wire 上的 replay 是 VERSION2 的表示（snapshot.modData 是
-- typed flat 葉子），釘它等於把測試綁在表示法上。經濟內容一律由 consumer 側證明 —— 也就是
-- 下面「未竄改的 pending 依後繼還原」那格，看真正被重建出來的資產。
do
    local _, seller = fresh("p70a")
    local user = seller:getUsername()
    local axe = native(seller, "Base.Axe")
    axe.condition = 5
    local listed = cmd(seller, "market.list", { itemId = axe:getID(), price = 100 })
    assert(listed.ok, tostring(listed.error))
    local beforeTick = files[proofJournalPath(user)]
    assert(proofSettle() == 0)
    local row = proofJournalRowOf(user, listed.listingId)
    local receipt = S.modData().recovery.ops[listed.listingId]
    check(beforeTick == nil and row ~= nil and row.type == "recovery.journal"
        and type(row.version) == "number" and row.version >= 1
        and row.owner == user and row.opId == listed.listingId and row.kind ~= nil
        and row.epoch == receipt.epoch and row.seq == receipt.seq
        and type(row.outAt) == "number" and row.replay ~= nil,
        "a listing is journaled only after a tick, and the line's envelope names this account, this operation and the commit point the receipt recorded")

    -- 零費也有證據：費率 0 不是「不算交易」
    local corn = native(seller, "Base.CannedCorn")
    local auction = cmd(seller, "auction.create", { itemId = corn:getID(), startPrice = 40, hours = 12 })
    assert(auction.ok, tostring(auction.error))
    assert(proofSettle() == 0)
    local aRow = proofJournalRowOf(user, auction.auctionId)
    check(listingOf(listed.listingId).fee == 0 and aRow ~= nil and aRow.kind == "auction"
        and aRow.opId == auction.auctionId and aRow.owner == user
        and aRow.replay ~= nil and #proofJournalRows(user) == 2,
        "a fee-free listing and a fee-free auction are both journaled: the faucet is the operation, not the fee")
end

-- ---- 未竄改的 pending：依 server 後繼還原，經濟內容全部來自 journal ----
do
    local _, seller = fresh("p70b")
    local user = seller:getUsername()
    local axe = native(seller, "Base.Axe")
    axe.condition = 5
    local saved = copy(S.modData())                     -- 世界存檔點：還沒有這筆刊登
    local listed = cmd(seller, "market.list", { itemId = axe:getID(), price = 100 })
    assert(listed.ok and proofSettle() == 0)
    local id = listed.listingId
    local coinBefore = L.getBalance(user, "survivor").available
    restart(saved)                                      -- 世界回到刊登之前，玩家存檔還帶 pending
    -- 只動 epoch/seq：新契約的 identity 排除這兩個欄位（存檔快照可能在 finishOut 覆寫前後），
    -- 所以這仍是合法的同一筆，必須能還原。
    local pend = seller.modData[KEY].pendingOuts[id]
    pend.seq = (tonumber(pend.seq) or 0) + 1000
    M.reconcile(seller)
    proofPump(user)
    local live = listingOf(id)
    check(live ~= nil and live.price == 100 and live.currency == "survivor" and live.item == "Base.Axe"
        and live.snapshot.condition == 5 and live.qty == 1 and reason(user, id) == nil,
        "an untampered pending is rebuilt from the server's successor, and a differing commit point alone is a save snapshot difference, not a conflict")
    M.reconcile(seller)
    proofPump(user)
    check(tally(seller, "Base.Axe") == 1 and listingOf(id) ~= nil and Mk.ownerCount(user) == 1
        and listingOf(id).price == 100
        and L.getBalance(user, "survivor").available == coinBefore,
        "a second login does not restore the same operation twice, nor reprice the listing it already rebuilt")
end

-- ---- 竄改經濟內容：回 mismatch，且不自動動錢物（contract 第 62 行）----
--
-- identity 現在比對完整經濟內容（排除 epoch/seq）。玩家改得到的每一個經濟欄位都在比對範圍內，
-- 所以竄改不會「被權威值覆蓋後照樣還原」—— 它會被認出來是另一筆內容，自動路徑直接停手。
-- 人工也只能採用 server 後繼，不能憑玩家自述生物。
do
    local _, seller = fresh("p70b2")
    local user = seller:getUsername()
    local axe = native(seller, "Base.Axe")
    axe.condition = 5
    local saved = copy(S.modData())
    local listed = cmd(seller, "market.list", { itemId = axe:getID(), price = 100 })
    assert(listed.ok and proofSettle() == 0)
    local id = listed.listingId
    local catBefore = L.getBalance(user, "cat").available
    local coinBefore = L.getBalance(user, "survivor").available
    restart(saved)
    local pend = seller.modData[KEY].pendingOuts[id]
    pend.price, pend.currency, pend.unitPrice = 999999, "cat", 1
    pend.snapshot.type, pend.snapshot.condition = "Base.Heavy", 10
    M.reconcile(seller)
    proofPump(user)
    check(reason(user, id) == "journal_mismatch" and not Mk.listingExists(id)
        and seller.modData[KEY].pendingOuts[id] ~= nil and M.unclaimed(user) == 0,
        "a pending whose economic content was tampered with is a mismatch against the server's own line, and nothing is rebuilt from it")
    check(L.getBalance(user, "cat").available == catBefore
        and L.getBalance(user, "survivor").available == coinBefore
        and L.conservation("survivor") == 0 and L.conservation("cat") == 0
        and seller.inventory.count("Base.Heavy") == 0 and seller.inventory.count("Base.Axe") == 0
        and tally(seller, "Base.Axe") == 0,
        "and the tampered currency moved no coin in either wallet while the tampered item type minted nothing")
end

-- ---- 竄改 origins／qty：同樣是經濟內容，同樣 mismatch，且絕不生出第二件 ----
--
-- origins[].src == "native" 在 R.originState 裡是 "valid"，所以憑空加的那一筆在舊規則下會讓
-- 「用玩家存檔算」的版本認為有兩件要還；durable=true 更是直接繞過 epoch 判定。
-- 新規則下這整份內容根本對不上 server 的行，所以自動路徑停手，一件都不會生出來。
do
    local _, seller = fresh("p70c")
    local user = seller:getUsername()
    local corn = native(seller, "Base.CannedCorn")
    local saved = copy(S.modData())
    local listed = cmd(seller, "market.list", { itemId = corn:getID(), price = 55 })
    assert(listed.ok and proofSettle() == 0)
    local id = listed.listingId
    local coinBefore = L.getBalance(user, "survivor").available
    restart(saved)
    local pend = seller.modData[KEY].pendingOuts[id]
    pend.qty, pend.lotQty = 2, 2
    pend.origins[1].durable = true
    pend.origins[2] = { src = "native", nativeId = 987654, durable = true }
    pend.itemIds = { pend.origins[1].nativeId, 987654 }
    M.reconcile(seller)
    proofPump(user)
    check(reason(user, id) == "journal_mismatch" and not Mk.listingExists(id)
        and tally(seller, "Base.CannedCorn") == 0
        and L.getBalance(user, "survivor").available == coinBefore
        and L.conservation("survivor") == 0,
        "an inflated quantity and a fabricated extra origin are refused as a mismatch: no listing, no second unit, no coin")
end
onlinePlayers = {}
SandboxVars.MinidoracatEconomy.MarketListingFeePercent = nil
SandboxVars.MinidoracatEconomy.MarketSalesTaxPercent = nil
SandboxVars.MinidoracatEconomy.MarketMaxListings = nil
end)()

-- ===== 情境七十一：沒有耐久證據就沒有款物 =====
--
-- 兩種「沒有證據」必須分得開，但結果一樣：憑空寫進存檔的 pending（server 從來沒有這筆作業），
-- 以及真的有作業但那行還在 queue 裡就崩潰（X.init 會清掉 queue，等於從未落盤）。兩者都 hold，
-- 不得降級去信 pending。
io.write("scenario 71: without a durable line there is no asset and no coin\n")
;(function()
local M, Mk, Rec, Shop = S.Mailbox, S.Market, S.Recovery, S.Shop
local KEY = EC.PLAYER_MODDATA_KEY
local serial = 0
local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, value in pairs(v) do out[k] = copy(value) end
    return out
end
local function cmd(p, name, args)
    serial, nowMs = serial + 1, nowMs + 700
    args = args or {}
    args.requestId = args.requestId or ("proof71-" .. serial)
    withCurrency(name, args)
    local first = #sentCommands + 1
    fire("OnClientCommand", EC.COMMAND_MODULE, name, p, args)
    for i = first, #sentCommands do
        local reply = sentCommands[i]
        if reply.player == p and reply.command == name then return reply.args end
    end
    error("missing reply: " .. name)
end
local function fresh(tag)
    modDataStore[EC.MODDATA_KEY] = nil
    files, writerDeny, sentCommands, sentItemPackets = {}, {}, {}, {}
    worldSprites = { ["100,200,0"] = "MinidoracatEconomy_terminal_0" }
    SandboxVars.MinidoracatEconomy.MarketListingFeePercent = 0
    SandboxVars.MinidoracatEconomy.MarketMaxListings = 8
    files[Shop.FILE] = { lines = { EC.jsonEncode({ items = {
        { id = "corn", item = "Base.CannedCorn", qty = 1,
            prices = { survivor = { price = 20, bidPrice = 8, buyback = true } } },
    } }) }, opens = 0 }
    nowMs = nowMs + 61000
    fire("OnServerStarted")
    local admin, seller = fakePlayer(tag .. "-admin"), fakePlayer(tag .. "-seller")
    admin.role = "admin"
    seller.inventory = fakeInventory(200)
    onlinePlayers = { admin, seller }
    assert(cmd(admin, "terminal.register", { x = 100, y = 200, z = 0, kind = "atm" }).ok)
    assert(L.credit(seller:getUsername(), "survivor", 5000, "SYSTEM_MINT",
        { requestId = tag .. "-seed", reasonCode = "test" }).ok)
    return admin, seller
end
local function native(p, fullType)
    local item = instanceItem(fullType)
    assert(item and p.inventory:AddItem(item) == item)
    return item
end
local function restart(saved)
    modDataStore[EC.MODDATA_KEY] = copy(saved)
    nowMs = nowMs + 1000
    fire("OnServerStarted")
end
local function reason(user, id)
    local rec = Rec.heldRecord(user, "pend:" .. id)
    return rec and rec.resolvedAt == nil and rec.reason or nil
end

-- ---- 憑空的 pending：真的有一筆回滾的作業（拿它的提交點），但這個 opId 從來不存在 ----
do
    local _, seller = fresh("p71a")
    local user = seller:getUsername()
    local corn = native(seller, "Base.CannedCorn")
    local saved = copy(S.modData())
    local listed = cmd(seller, "market.list", { itemId = corn:getID(), price = 30 })
    assert(listed.ok and proofSettle() == 0)
    restart(saved)
    local real = seller.modData[KEY].pendingOuts[listed.listingId]
    local ghostId = real.epoch .. ":9901"
    local ghost = copy(real)
    ghost.origins = { { src = "native", nativeId = 778899 } }
    ghost.itemIds, ghost.itemId = { 778899 }, 778899
    ghost.snapshot = { type = "Base.Axe", condition = 10, uses = 1, age = 0, repaired = 0 }
    ghost.price, ghost.qty, ghost.lotQty = 900, 1, 1
    seller.modData[KEY].pendingOuts[ghostId] = ghost
    local coinBefore, items = L.getBalance(user, "survivor").available, #seller.inventory.items
    M.reconcile(seller)
    proofPump(user)
    check(reason(user, ghostId) == "journal_missing"
        and seller.modData[KEY].pendingOuts[ghostId] ~= nil
        and not Mk.listingExists(ghostId) and M.unclaimed(user) == 0
        and seller.inventory.count("Base.Axe") == 0 and #seller.inventory.items == items
        and L.getBalance(user, "survivor").available == coinBefore,
        "a pending the server never committed is held as journal_missing and produces no item and no coin")
    check(Mk.listingExists(listed.listingId) and proofJournalRowOf(user, listed.listingId) ~= nil,
        "the account's real operation, whose line is on disk, is still restored beside the unprovable one")
    M.reconcile(seller)
    proofPump(user)
    check(reason(user, ghostId) == "journal_missing" and Rec.heldCount(user) == 1
        and seller.inventory.count("Base.Axe") == 0 and L.conservation("survivor") == 0,
        "repeated logins keep one reasoned record for it and never turn the claim into an asset")
end

-- ---- 同一 tick 崩潰：行還在 queue 裡，X.init 清掉它，等於從未落盤 ----
do
    local _, seller = fresh("p71b")
    local user = seller:getUsername()
    local corn = native(seller, "Base.CannedCorn")
    local saved = copy(S.modData())
    local listed = cmd(seller, "market.list", { itemId = corn:getID(), price = 70 })
    assert(listed.ok)
    local id = listed.listingId
    assert(X.queuedLines() > 0 and files[proofJournalPath(user)] == nil)
    local coinBefore = L.getBalance(user, "survivor").available
    restart(saved)                                       -- 崩潰：queue 與 ModData 一起回到存檔點
    M.reconcile(seller)
    proofPump(user)
    check(files[proofJournalPath(user)] == nil and reason(user, id) == "journal_missing"
        and not Mk.listingExists(id) and seller.modData[KEY].pendingOuts[id] ~= nil
        and seller.inventory.count("Base.CannedCorn") == 0 and M.unclaimed(user) == 0
        and L.getBalance(user, "survivor").available == coinBefore,
        "an operation whose journal line never left the queue is held, not rebuilt from the player save")
end

-- ---- 同一筆但已落盤：可以還原，而且只還原一次 ----
do
    local _, seller = fresh("p71c")
    local user = seller:getUsername()
    local corn = native(seller, "Base.CannedCorn")
    local saved = copy(S.modData())
    local listed = cmd(seller, "market.list", { itemId = corn:getID(), price = 70 })
    assert(listed.ok)
    local id = listed.listingId
    assert(proofSettle() == 0)                           -- 這次證據真的落盤了
    local coinBefore = L.getBalance(user, "survivor").available
    restart(saved)
    M.reconcile(seller)
    proofPump(user)
    local live = S.modData().market.listings[id]
    check(live ~= nil and live.price == 70 and live.currency == "survivor"
        and reason(user, id) == nil and Mk.ownerCount(user) == 1,
        "the very same operation, flushed before the crash, is restored from its own line and its hold is closed")
    M.reconcile(seller)
    proofPump(user)
    check(Mk.ownerCount(user) == 1 and seller.inventory.count("Base.CannedCorn") == 0
        and L.getBalance(user, "survivor").available == coinBefore
        and L.conservation("survivor") == 0,
        "a second reconcile neither relists it nor pays anything: one unit stays one unit")
end
onlinePlayers = {}
SandboxVars.MinidoracatEconomy.MarketListingFeePercent = nil
SandboxVars.MinidoracatEconomy.MarketMaxListings = nil
end)()

-- ===== 情境七十二：對得上的是提交點的身份，不是「檔案裡有這個字串」 =====
--
-- 五個拒絕碼各有不同的根因與不同的下一步，全部都不是「挑一份最像的來用」。
io.write("scenario 72: the identity of the commit point is what matches, never a text hit\n")
;(function()
local M, Mk, Rec, Shop = S.Mailbox, S.Market, S.Recovery, S.Shop
local KEY = EC.PLAYER_MODDATA_KEY
local serial = 0
local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, value in pairs(v) do out[k] = copy(value) end
    return out
end
local function cmd(p, name, args)
    serial, nowMs = serial + 1, nowMs + 700
    args = args or {}
    args.requestId = args.requestId or ("proof72-" .. serial)
    withCurrency(name, args)
    local first = #sentCommands + 1
    fire("OnClientCommand", EC.COMMAND_MODULE, name, p, args)
    for i = first, #sentCommands do
        local reply = sentCommands[i]
        if reply.player == p and reply.command == name then return reply.args end
    end
    error("missing reply: " .. name)
end
local function fresh(tag)
    modDataStore[EC.MODDATA_KEY] = nil
    files, writerDeny, sentCommands, sentItemPackets = {}, {}, {}, {}
    worldSprites = { ["100,200,0"] = "MinidoracatEconomy_terminal_0" }
    SandboxVars.MinidoracatEconomy.MarketListingFeePercent = 0
    SandboxVars.MinidoracatEconomy.MarketMaxListings = 8
    files[Shop.FILE] = { lines = { EC.jsonEncode({ items = {
        { id = "corn", item = "Base.CannedCorn", qty = 1,
            prices = { survivor = { price = 20, bidPrice = 8, buyback = true } } },
    } }) }, opens = 0 }
    nowMs = nowMs + 61000
    fire("OnServerStarted")
    local admin, seller = fakePlayer(tag .. "-admin"), fakePlayer(tag .. "-seller")
    admin.role = "admin"
    seller.inventory = fakeInventory(200)
    onlinePlayers = { admin, seller }
    assert(cmd(admin, "terminal.register", { x = 100, y = 200, z = 0, kind = "atm" }).ok)
    assert(L.credit(seller:getUsername(), "survivor", 5000, "SYSTEM_MINT",
        { requestId = tag .. "-seed", reasonCode = "test" }).ok)
    return admin, seller
end
local function native(p, fullType)
    local item = instanceItem(fullType)
    assert(item and p.inventory:AddItem(item) == item)
    return item
end
local function restart(saved)
    modDataStore[EC.MODDATA_KEY] = copy(saved)
    nowMs = nowMs + 1000
    fire("OnServerStarted")
end
local function reason(user, id)
    local rec = Rec.heldRecord(user, "pend:" .. id)
    return rec and rec.resolvedAt == nil and rec.reason or nil
end
-- 一筆真的、已落盤、世界已回滾的作業；回傳 seller、opId 與月檔路徑。
local function rolledBack(tag, price)
    local _, seller = fresh(tag)
    local corn = native(seller, "Base.CannedCorn")
    local saved = copy(S.modData())
    local listed = cmd(seller, "market.list", { itemId = corn:getID(), price = price or 60 })
    assert(listed.ok and proofSettle() == 0)
    local path = proofJournalPathForOp(seller:getUsername(), listed.listingId)
    assert(files[path] ~= nil and proofJournalSuccessor(seller:getUsername(), listed.listingId) ~= nil,
        "fixture: the journal line for " .. listed.listingId .. " must be on disk before the rollback")
    restart(saved)
    return seller, listed.listingId, path
end

-- ---- 鏈的 seq 倒退：那不是追加歷史，是壞鏈 ----
--
-- 合法的鏈是 server seq **嚴格遞增**。倒序的行無法界定誰是後繼，所以 fail closed。
-- （單純「pending 的 epoch/seq 與行不同」已不再是矛盾 —— identity 比對的是經濟內容，
-- 那條正向案例在情境 70。）
do
    local seller, id, path = rolledBack("p72a")
    local user = seller:getUsername()
    local base = proofJournalSuccessor(user, id)
    -- 正向基底要真的能被讀：先讓真 producer 寫一行合法後繼（真 version、真 pack），
    -- 落盤後只把提交點改成倒退 —— 這樣紅的原因一定是 chain.order，不是撞到 version 或 pack。
    local older = copy(seller.modData[KEY].pendingOuts[id])
    local backwards = tonumber(base.seq) - 1
    assert(proofJournalCorrupt(user, id, base.epoch, tonumber(base.seq) + 2, older,
        function(row) row.seq = backwards; if type(row.replay) == "table" then row.replay.seq = backwards end end,
        base.kind, base.ref), "fixture: the backwards line must start from a real producer line")
    local itemsBefore, coinBefore = #seller.inventory.items, L.getBalance(user, "survivor").available
    M.reconcile(seller)
    proofPump(user)
    check(reason(user, id) == "journal_malformed" and not Mk.listingExists(id)
        and seller.modData[KEY].pendingOuts[id] ~= nil and M.unclaimed(user) == 0
        and #seller.inventory.items == itemsBefore
        and L.getBalance(user, "survivor").available == coinBefore,
        "a chain whose commit points run backwards has no definable successor, so it is refused instead of guessed at")
end

-- ---- 後繼在檔案很後面：讀取不得在命中第一份證據時提早結束 ----
--
-- 舊版 reader 找到該 op 的第一行就停，於是永遠看不到 restore 寫下的後繼。新契約要求把該 op
-- 的固定檔讀到底。祖先在第 1 行、後繼在第 50 行，只有真的讀完才會用到後繼的價格。
do
    local seller, id, path = rolledBack("p72a2", 60)
    local user = seller:getUsername()
    local ancestor = proofJournalSuccessor(user, id)
    for i = 1, 48 do
        proofJournalWrite(user, tonumber(EC.parseId(id)),
            proofJournalRecord(user, tostring(EC.parseId(id)) .. ":" .. (9000 + i),
                tostring(EC.parseId(id)), 9000 + i, { kind = "listing" }))
    end
    -- 後繼的 replay 必須取**live** 形狀（玩家存檔那筆），不能拿 wire 行的 replay 回頭再餵
    -- J.record —— VERSION2 的 snapshot.modData 在 wire 上是 typed flat 葉子，再 pack 一次就雙重打包。
    local successor = copy(seller.modData[KEY].pendingOuts[id])
    successor.seq = tonumber(ancestor.seq) + 3
    successor.price = 77                                  -- 只有讀到底才會看到這個價格
    assert(proofJournalEmit(user, id, ancestor.epoch, tonumber(ancestor.seq) + 3, successor,
        ancestor.kind, ancestor.ref), "fixture: the successor must be written by the real producer")
    local chain = proofJournalChain(user, id)
    assert(#chain == 2 and #files[proofJournalPathForOp(user, id)].lines == 50,
        "fixture: the successor must sit at the end of a 50-line file")
    M.reconcile(seller)
    proofPump(user)
    local live = S.modData().market.listings[id]
    check(live ~= nil and live.price == 77 and reason(user, id) == nil
        and Mk.ownerCount(user) == 1,
        "the operation's own file is read to the end: a successor written far behind the first hit is the decision that counts")
end

-- ---- 同一個 opId 掛在別的帳號名下：身份衝突，不是「沒有這筆」 ----
do
    local seller, id, path = rolledBack("p72b")
    local user = seller:getUsername()
    local row = EC.jsonDecode(files[path].lines[#files[path].lines])
    files[path].lines = {}                                  -- 只留一行：owner 是別人
    row.owner = "p72b-someone-else"
    files[path].lines[1] = EC.jsonEncode(row)
    M.reconcile(seller)
    proofPump(user)
    check(reason(user, id) == "journal_mismatch" and not Mk.listingExists(id)
        and seller.inventory.count("Base.CannedCorn") == 0 and M.unclaimed(user) == 0,
        "a line carrying this operation id under another account is an identity conflict, never this account's proof")
end

-- ---- 同一個提交點、兩行內容不同：真正無法判讀，fail closed ----
--
-- 新契約（Main 裁定）：同 opId 的多行是**合法追加歷史**（restore／人工 return／discard 各自
-- 是一個新提交點），所以「不同提交點」不再是矛盾。真正矛盾的是**同一個 epoch/seq 卻兩份
-- 不同內容** —— 那是同一個決定有兩個版本，沒有任何規則能決定哪個是真的，只能拒絕。
-- （同提交點且內容相同的冪等重寫則必須被忽略，見下一格。）
do
    local seller, id, path = rolledBack("p72c")
    local user = seller:getUsername()
    local row = EC.jsonDecode(files[path].lines[#files[path].lines])
    local twin = copy(row)
    twin.replay.price = 1                                  -- 同 epoch/seq，內容不同
    files[path].lines[#files[path].lines + 1] = EC.jsonEncode(twin)
    M.reconcile(seller)
    proofPump(user)
    check(reason(user, id) == "journal_malformed" and not Mk.listingExists(id)
        and seller.inventory.count("Base.CannedCorn") == 0 and M.unclaimed(user) == 0,
        "one commit point carrying two different contents is refused outright: nothing can decide which version is the real decision")
end

-- ---- 行缺了 outAt：保留下限沒有可信的時間可讀，只能 fail closed ----
--
-- retention floor 現在**只讀 detail.outAt**（CommerceServer 已刪掉 replay.at / pend.at 這兩個
-- 玩家碰得到的 fallback）。這一格就是那個刪除的回歸看守：一旦有人把 fallback 加回來，
-- 缺 outAt 的行就會拿玩家時間去比 floor，這條會變綠得出來的地方就從 malformed 變成「照樣還原」。
do
    local seller, id, path = rolledBack("p72f2", 60)
    local user = seller:getUsername()
    local lines = files[path].lines
    for i = 1, #lines do
        local row = EC.jsonDecode(lines[i])
        if type(row) == "table" and row.opId == id then
            row.outAt = nil
            lines[i] = EC.jsonEncode(row)
        end
    end
    local coinBefore = L.getBalance(user, "survivor").available
    M.reconcile(seller)
    proofPump(user)
    check(reason(user, id) == "journal_malformed" and not Mk.listingExists(id)
        and seller.modData[KEY].pendingOuts[id] ~= nil and M.unclaimed(user) == 0
        and seller.inventory.count("Base.CannedCorn") == 0
        and L.getBalance(user, "survivor").available == coinBefore,
        "a line with no commit timestamp leaves the retention floor nothing trustworthy to read, so it is refused rather than measured against a time the player controls")
end

-- ---- 同提交點、內容完全相同的冪等重寫：必須被忽略，不得當成矛盾 ----
do
    local seller, id, path = rolledBack("p72c2", 60)
    local user = seller:getUsername()
    local row = EC.jsonDecode(files[path].lines[#files[path].lines])
    files[path].lines[#files[path].lines + 1] = EC.jsonEncode(row)   -- 逐位元組相同
    M.reconcile(seller)
    proofPump(user)
    local live = S.modData().market.listings[id]
    check(live ~= nil and live.price == 60 and reason(user, id) == nil
        and Mk.ownerCount(user) == 1 and seller.inventory.count("Base.CannedCorn") == 0,
        "an idempotent rewrite of the same commit point with identical content is ignored, not mistaken for a contradiction")
end

-- ---- 形狀不合：replay 掉了 origins ----
do
    local seller, id, path = rolledBack("p72d")
    local user = seller:getUsername()
    local row = EC.jsonDecode(files[path].lines[#files[path].lines])
    row.replay.origins = nil
    files[path].lines[#files[path].lines] = EC.jsonEncode(row)
    M.reconcile(seller)
    proofPump(user)
    check(reason(user, id) == "journal_malformed" and not Mk.listingExists(id)
        and seller.inventory.count("Base.CannedCorn") == 0,
        "a line whose replay lost its origins is malformed: the operation is held, never partly rebuilt")
end

-- ---- 半行：字串命中不是證明 ----
do
    local seller, id, path = rolledBack("p72e")
    local user = seller:getUsername()
    local full = files[path].lines[#files[path].lines]
    files[path].lines[#files[path].lines] = string.sub(full, 1, math.floor(#full / 2))
    assert(string.find(files[path].lines[#files[path].lines], id, 1, true) ~= nil)
    M.reconcile(seller)
    proofPump(user)
    check(reason(user, id) == "journal_unreadable" and reason(user, id) ~= "journal_missing"
        and not Mk.listingExists(id) and seller.inventory.count("Base.CannedCorn") == 0,
        "a truncated line that still contains the operation id as text is a broken read, never a decoded proof and never a clean absence")
end

-- ---- 檔在但開不起來：不是缺行 ----
do
    local seller, id, path = rolledBack("p72f")
    local user = seller:getUsername()
    local realReader = getFileReader
    getFileReader = function(p, create)
        if p == path then return nil end
        return realReader(p, create)
    end
    M.reconcile(seller)
    proofPump(user)
    getFileReader = realReader
    check(cacheFileExists(path) and reason(user, id) == "journal_unreadable"
        and not Mk.listingExists(id) and seller.inventory.count("Base.CannedCorn") == 0,
        "a month file that exists but cannot be opened is unreadable, which is a different answer from missing")
end

-- ---- 讀到一半壞掉：不得把已讀到的部分當完整 ----
--
-- 填充行必須在真行之前：真行若排在第一行，reader 可以合法提早結束，就測不到中途壞掉。
do
    local _, seller = fresh("p72g")
    local user = seller:getUsername()
    local corn = native(seller, "Base.CannedCorn")
    local saved = copy(S.modData())
    proofJournalPad(user, nil, 8)
    local listed = cmd(seller, "market.list", { itemId = corn:getID(), price = 60 })
    assert(listed.ok and proofSettle() == 0)
    local id, path = listed.listingId, proofJournalPath(user)
    assert(#proofJournalRows(user) == 9,
        "fixture: the real line must sit behind 8 padding lines so the read cannot finish early")
    restart(saved)
    local realReader = getFileReader
    getFileReader = function(p, create)
        local reader = realReader(p, create)
        if p ~= path or reader == nil then return reader end
        local seen = 0
        return { close = reader.close, readLine = function()
            seen = seen + 1
            if seen > 3 then error("journal read broke midway") end
            return reader.readLine()
        end }
    end
    M.reconcile(seller)
    proofPump(user)
    getFileReader = realReader
    check(reason(user, id) == "journal_unreadable" and not Mk.listingExists(id)
        and seller.modData[KEY].pendingOuts[id] ~= nil
        and seller.inventory.count("Base.CannedCorn") == 0 and M.unclaimed(user) == 0,
        "a read that breaks partway through answers unreadable and leaves the operation exactly as it was")
    check(L.conservation("survivor") == 0 and L.getBalance(user, "survivor").available == 5000
        and L.getBalance("SYSTEM_MINT", "survivor").available == -5000,
        "none of the seven refusals above created a coin: the mint account still owes exactly what it seeded")
end
onlinePlayers = {}
SandboxVars.MinidoracatEconomy.MarketListingFeePercent = nil
SandboxVars.MinidoracatEconomy.MarketMaxListings = nil
end)()

-- ===== 情境七十三：讀取有界，而且一定會前進 =====
--
-- 「不阻塞主執行緒」不能變成「永遠掛在 pending」。四件事要同時成立：一個帳號的多筆待證據
-- 合併成一次讀、每 tick 有位元組/行數預算、reader pool 滿了只是等而不是失敗、斷線與完成後
-- 狀態改變都要重判而不是照用舊結論。
io.write("scenario 73: the proof read is bounded, coalesced, and always makes progress\n")
;(function()
local M, Mk, Rec, Shop = S.Mailbox, S.Market, S.Recovery, S.Shop
local J = S.RecoveryJournal or {}
local KEY = EC.PLAYER_MODDATA_KEY
local serial = 0
local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, value in pairs(v) do out[k] = copy(value) end
    return out
end
local function cmd(p, name, args)
    serial, nowMs = serial + 1, nowMs + 700
    args = args or {}
    args.requestId = args.requestId or ("proof73-" .. serial)
    withCurrency(name, args)
    local first = #sentCommands + 1
    fire("OnClientCommand", EC.COMMAND_MODULE, name, p, args)
    for i = first, #sentCommands do
        local reply = sentCommands[i]
        if reply.player == p and reply.command == name then return reply.args end
    end
    error("missing reply: " .. name)
end
local function world(tag, sellerCount)
    modDataStore[EC.MODDATA_KEY] = nil
    files, writerDeny, sentCommands, sentItemPackets = {}, {}, {}, {}
    worldSprites = { ["100,200,0"] = "MinidoracatEconomy_terminal_0" }
    SandboxVars.MinidoracatEconomy.MarketListingFeePercent = 0
    SandboxVars.MinidoracatEconomy.MarketMaxListings = 8
    files[Shop.FILE] = { lines = { EC.jsonEncode({ items = {
        { id = "corn", item = "Base.CannedCorn", qty = 1,
            prices = { survivor = { price = 20, bidPrice = 8, buyback = true } } },
    } }) }, opens = 0 }
    nowMs = nowMs + 61000
    fire("OnServerStarted")
    local admin = fakePlayer(tag .. "-admin")
    admin.role = "admin"
    local sellers = {}
    for i = 1, sellerCount do
        local s = fakePlayer(tag .. "-s" .. i)
        s.inventory = fakeInventory(200)
        sellers[i] = s
    end
    onlinePlayers = { admin }
    for i = 1, sellerCount do onlinePlayers[#onlinePlayers + 1] = sellers[i] end
    assert(cmd(admin, "terminal.register", { x = 100, y = 200, z = 0, kind = "atm" }).ok)
    for i = 1, sellerCount do
        assert(L.credit(sellers[i]:getUsername(), "survivor", 5000, "SYSTEM_MINT",
            { requestId = tag .. "-seed-" .. i, reasonCode = "test" }).ok)
    end
    return admin, sellers
end
local function native(p, fullType)
    local item = instanceItem(fullType)
    assert(item and p.inventory:AddItem(item) == item)
    return item
end
local function restart(saved)
    modDataStore[EC.MODDATA_KEY] = copy(saved)
    nowMs = nowMs + 1000
    fire("OnServerStarted")
end
local function reason(user, id)
    local rec = Rec.heldRecord(user, "pend:" .. id)
    return rec and rec.resolvedAt == nil and rec.reason or nil
end
-- J.status 的唯讀讀取。模組沒載時回空表，讓每一個斷言「失敗」而不是讓整份 harness 中斷；
-- 沒有放寬任何斷言：欄位是 nil 就對不上要求的數值。
local function jstat(user)
    if type(J.status) ~= "function" then return {} end
    local st = J.status(user)
    return type(st) == "table" and st or {}
end
-- 一個 seller 的 n 筆刊登，落盤後世界回滾；回傳 opId 清單。整段收斂中月檔被開幾次由呼叫者數。
local function rolledBackLot(tag, n)
    local _, sellers = world(tag, 1)
    local seller = sellers[1]
    local saved = copy(S.modData())
    local ids = {}
    for i = 1, n do
        local res = cmd(seller, "market.list", { itemId = native(seller, "Base.CannedCorn"):getID(), price = 10 + i })
        assert(res.ok, tostring(res.error))
        ids[i] = res.listingId
    end
    assert(proofSettle() == 0)
    restart(saved)
    return seller, ids
end
local function countingOpens(path, fn)
    local realReader, opens = getFileReader, 0
    getFileReader = function(p, create)
        if p == path then opens = opens + 1 end
        return realReader(p, create)
    end
    fn()
    getFileReader = realReader
    return opens
end

-- ---- 合併讀：open 次數是候選月檔數，與待證據的筆數無關 ----
local opensOne, opensThree, restoredThree, oneRestored = 0, 0, 0, false
do
    local seller, ids = rolledBackLot("p73a", 1)
    local path = proofJournalPath(seller:getUsername())
    opensOne = countingOpens(path, function()
        M.reconcile(seller)
        proofPump(seller:getUsername())
    end)
    oneRestored = Mk.listingExists(ids[1])
end
do
    local seller, ids = rolledBackLot("p73b", 3)
    local user = seller:getUsername()
    local path = proofJournalPath(user)
    M.reconcile(seller)
    check(reason(user, ids[1]) == "journal_pending" and reason(user, ids[3]) == "journal_pending"
        and seller.modData[KEY].pendingOuts[ids[1]] ~= nil
        and not Mk.listingExists(ids[1]) and not Mk.listingExists(ids[3])
        and jstat(user).wanted == 3 and Mk.ownerCount(user) == 0,
        "the first pass answers journal_pending for every record, rebuilds nothing and registers what it wants")
    opensThree = countingOpens(path, function() proofPump(user) end)
    for _, id in ipairs(ids) do
        if Mk.listingExists(id) then restoredThree = restoredThree + 1 end
    end
    check(restoredThree == 3 and reason(user, ids[1]) == nil and reason(user, ids[3]) == nil
        and S.modData().market.listings[ids[1]].price == 11
        and S.modData().market.listings[ids[3]].price == 13
        and seller.inventory.count("Base.CannedCorn") == 0,
        "all three converge and each comes back at its own journalled price, not the first line's")
    check(opensThree == opensOne and opensOne >= 1 and opensOne <= J.MAX_PATHS and oneRestored,
        "three records of one account cost the same file opens as one: the read is coalesced, not per record")
end

-- ---- 每 tick 預算 + reader pool 飽和 + 飽和之後仍然前進 ----
do
    local _, sellers = world("p73c", 3)
    local saved = copy(S.modData())
    local ids, users = {}, {}
    for i = 1, 3 do
        users[i] = sellers[i]:getUsername()
        proofJournalPad(users[i], nil, 500)            -- 灌在真行之前，reader 不能提早結束
        local res = cmd(sellers[i], "market.list",
            { itemId = native(sellers[i], "Base.CannedCorn"):getID(), price = 20 + i })
        assert(res.ok, tostring(res.error))
        ids[i] = res.listingId
    end
    assert(proofSettle() == 0)
    restart(saved)
    for i = 1, 3 do M.reconcile(sellers[i]) end
    fire("OnTickEvenPaused")
    local reading = 0
    for i = 1, 3 do
        if jstat(users[i]).reading == true then reading = reading + 1 end
    end
    check(reading == J.MAX_READERS and J.MAX_READERS == 2 and jstat(users[1]).readers == J.MAX_READERS
        and not Mk.listingExists(ids[1]) and not Mk.listingExists(ids[2]) and not Mk.listingExists(ids[3]),
        "one tick starts only as many proof readers as the pool allows; the rest wait instead of failing")
    check(reason(users[1], ids[1]) == "journal_pending" and reason(users[2], ids[2]) == "journal_pending"
        and reason(users[3], ids[3]) == "journal_pending" and #proofJournalRows(users[1]) == 501
        and jstat(users[1]).wanted == 1 and jstat(users[3]).wanted == 1,
        "a month file too large for one tick leaves every waiting account pending, never unreadable and never dropped")
    for i = 1, 3 do proofPump(users[i], 400) end
    local restored = 0
    for i = 1, 3 do
        if S.modData().market.listings[ids[i]] ~= nil
            and S.modData().market.listings[ids[i]].price == 20 + i then restored = restored + 1 end
    end
    check(restored == 3 and reason(users[3], ids[3]) == nil
        and jstat(users[3]).wanted == 0 and L.conservation("survivor") == 0,
        "once the pool drains every account gets its turn: the bounded read finishes the backlog, it does not drop it")
end

-- ---- 斷線：清掉工作與結果，絕不寫回一個已經不在線的玩家 ----
do
    local _, sellers = world("p73d", 1)
    local seller = sellers[1]
    local user = seller:getUsername()
    local admin = onlinePlayers[1]
    local saved = copy(S.modData())
    proofJournalPad(user, nil, 500)
    local listed = cmd(seller, "market.list", { itemId = native(seller, "Base.CannedCorn"):getID(), price = 45 })
    assert(listed.ok and proofSettle() == 0)
    local id = listed.listingId
    restart(saved)
    M.reconcile(seller)
    fire("OnTickEvenPaused")
    local wasReading = jstat(user).reading == true
    onlinePlayers = { admin }                              -- 斷線
    local coinBefore, items = L.getBalance(user, "survivor").available, #seller.inventory.items
    nowMs = nowMs + 1500                                   -- 過離線清理的掃描窗（J.SWEEP_MS）
    proofPump(user, 400)
    check(wasReading and jstat(user).wanted == 0 and jstat(user).reading ~= true
        and not Mk.listingExists(id) and M.unclaimed(user) == 0
        and #seller.inventory.items == items and L.getBalance(user, "survivor").available == coinBefore
        and seller.modData[KEY].pendingOuts[id] ~= nil,
        "a disconnect during the read drops the work and the result: nothing is written back to an absent player")
    onlinePlayers = { admin, seller }                      -- 重新上線
    M.reconcile(seller)
    proofPump(user, 400)
    check(S.modData().market.listings[id] ~= nil and S.modData().market.listings[id].price == 45
        and reason(user, id) == nil,
        "logging back in re-reads the evidence and only then restores the operation")
end

-- ---- 完成時世界已經變了：重判，不得套用讀取開始時的結論 ----
do
    local _, sellers = world("p73e", 1)
    local seller = sellers[1]
    local user = seller:getUsername()
    local saved = copy(S.modData())
    proofJournalPad(user, nil, 500)
    local corn = native(seller, "Base.CannedCorn")
    local listed = cmd(seller, "market.list", { itemId = corn:getID(), price = 90 })
    assert(listed.ok and proofSettle() == 0)
    local id = listed.listingId
    restart(saved)
    M.reconcile(seller)
    fire("OnTickEvenPaused")
    local wasReading = jstat(user).reading == true and not Mk.listingExists(id)
    seller.inventory:AddItem(corn)                         -- 讀到一半，那件實體又出現在背包裡
    proofPump(user, 400)
    check(wasReading and not Mk.listingExists(id) and Mk.ownerCount(user) == 0
        and seller.inventory.count("Base.CannedCorn") == 1
        and seller.modData[KEY].pendingOuts[id] == nil
        and L.conservation("survivor") == 0,
        "a world that changed while the proof was being read is judged again on completion: the unit is not duplicated into a listing")
end
onlinePlayers = {}
SandboxVars.MinidoracatEconomy.MarketListingFeePercent = nil
SandboxVars.MinidoracatEconomy.MarketMaxListings = nil
end)()

-- ===== 情境七十四：完全缺證據時的人工出口 =====
--
-- 契約：缺 journal 只能有「明確的人工接受玩家自述」的退物／捨棄，畫面要標明來源未經伺服器
-- 證明，而且不得自動 mint、不得繞過調帳額度。所以拒絕碼要在，接受之後也不能生出一枚硬幣。
io.write("scenario 74: the manual exit names an unproven source and never mints\n")
;(function()
local M, Mk, Rec, Shop = S.Mailbox, S.Market, S.Recovery, S.Shop
local KEY = EC.PLAYER_MODDATA_KEY
local serial = 0
local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, value in pairs(v) do out[k] = copy(value) end
    return out
end
local function cmd(p, name, args)
    serial, nowMs = serial + 1, nowMs + 700
    args = args or {}
    args.requestId = args.requestId or ("proof74-" .. serial)
    withCurrency(name, args)
    local first = #sentCommands + 1
    fire("OnClientCommand", EC.COMMAND_MODULE, name, p, args)
    for i = first, #sentCommands do
        local reply = sentCommands[i]
        if reply.player == p and reply.command == name then return reply.args end
    end
    error("missing reply: " .. name)
end
local function rowOf(reply, key)
    for _, row in ipairs(reply.records or {}) do if row.key == key then return row end end
    return nil
end
local function record(boss, user, key)
    local res = cmd(boss, "admin.recovery", { action = "list", username = user })
    assert(res.ok, tostring(res.error))
    return rowOf(res, key)
end

modDataStore[EC.MODDATA_KEY] = nil
files, writerDeny, sentCommands, sentItemPackets = {}, {}, {}, {}
worldSprites = { ["100,200,0"] = "MinidoracatEconomy_terminal_0" }
SandboxVars.MinidoracatEconomy.MarketListingFeePercent = 0
SandboxVars.MinidoracatEconomy.MarketMaxListings = 8
files[Shop.FILE] = { lines = { EC.jsonEncode({ items = {
    { id = "corn", item = "Base.CannedCorn", qty = 1,
        prices = { survivor = { price = 20, bidPrice = 8, buyback = true } } },
} }) }, opens = 0 }
nowMs = nowMs + 61000
fire("OnServerStarted")
local boss, seller = fakePlayer("p74-admin"), fakePlayer("p74-seller")
boss.role = "admin"
seller.inventory = fakeInventory(200)
local user = seller:getUsername()
onlinePlayers = { boss, seller }
assert(cmd(boss, "terminal.register", { x = 100, y = 200, z = 0, kind = "atm" }).ok)
assert(L.credit(user, "survivor", 5000, "SYSTEM_MINT", { requestId = "p74-seed", reasonCode = "test" }).ok)

-- 一筆真的、回滾的作業，但證據還在 queue 裡就崩潰：完全缺 journal 的人工出口案例
local corn = instanceItem("Base.CannedCorn")
assert(seller.inventory:AddItem(corn) == corn)
local saved = copy(S.modData())
local listed = cmd(seller, "market.list", { itemId = corn:getID(), price = 120 })
assert(listed.ok and X.queuedLines() > 0)
local id = listed.listingId
modDataStore[EC.MODDATA_KEY] = copy(saved)
nowMs = nowMs + 1000
fire("OnServerStarted")
onlinePlayers = { boss, seller }
M.reconcile(seller)
proofPump(user)
assert(Rec.heldRecord(user, "pend:" .. id) ~= nil)
assert(files[proofJournalPath(user)] == nil)

local mintBefore = L.getBalance("SYSTEM_MINT", "survivor").available
local coinBefore = L.getBalance(user, "survivor").available
local row = record(boss, user, "pend:" .. id)
-- Main 的定義：action 只管自動路徑，manual 由 restorable 決定。ServerAdminStats 目前把 manual
-- 出口表達在 row.actions 上（row 上沒有 restorable 欄位），所以這裡釘 actions.restore：
-- 純 journal_missing、沒有任何反證，人工出口必須是開的，只是要明示接受。
check(row ~= nil and row.reason == "journal_missing" and row.proofState == "journal_missing"
    and row.unproven == true and row.source == "player_claim" and row.verdict == "rolledback"
    and type(row.actions) == "table" and row.actions.restore == true and row.restorable ~= false
    and row.qty == 1 and row.item == "Base.CannedCorn" and type(row.revision) == "string",
    "a pure journal_missing record is unproven but still manually restorable, and says its numbers come from the player's claim")

local refused = cmd(boss, "admin.recovery", { action = "resolve", username = user, key = "pend:" .. id,
    revision = row.revision, decision = "restore", note = "player says the listing vanished" })
check(refused.ok == false and refused.error == "recovery_unproven_source"
    and M.unclaimed(user) == 0 and not Mk.listingExists(id)
    and L.getBalance(user, "survivor").available == coinBefore,
    "restoring an unproven record without the explicit acceptance is refused before anything is created")

local accepted = cmd(boss, "admin.recovery", { action = "resolve", username = user, key = "pend:" .. id,
    revision = record(boss, user, "pend:" .. id).revision, decision = "restore", acceptUnproven = true,
    note = "accepting the player's account of a lost listing" })
local letter = nil
for _, entry in ipairs(M.list(user)) do
    if entry.item == "Base.CannedCorn" then letter = entry end
end
check(accepted.ok == true and letter ~= nil and letter.qty == 1
    and not Mk.listingExists(id) and seller.inventory.count("Base.CannedCorn") == 0,
    "the explicit acceptance returns the goods through the mailbox instead of relisting them from an unproven price")
check(L.getBalance(user, "survivor").available == coinBefore
    and L.getBalance("SYSTEM_MINT", "survivor").available == mintBefore
    and L.conservation("survivor") == 0,
    "accepting an unproven source creates no coin at all: the mint account and every balance are untouched")

-- 捨棄同樣要明示接受，而且同樣不產生任何東西
local secondCorn = instanceItem("Base.CannedCorn")
assert(seller.inventory:AddItem(secondCorn) == secondCorn)
local savedTwo = copy(S.modData())
local secondListed = cmd(seller, "market.list", { itemId = secondCorn:getID(), price = 77 })
assert(secondListed.ok and X.queuedLines() > 0)
local secondId = secondListed.listingId
modDataStore[EC.MODDATA_KEY] = copy(savedTwo)
nowMs = nowMs + 1000
fire("OnServerStarted")
onlinePlayers = { boss, seller }
M.reconcile(seller)
proofPump(user)
local secondRow = record(boss, user, "pend:" .. secondId)
local plainDiscard = cmd(boss, "admin.recovery", { action = "resolve", username = user,
    key = "pend:" .. secondId, revision = secondRow.revision, decision = "discard",
    note = "voiding an operation nobody can prove" })
local mailedBefore = M.unclaimed(user)
local okDiscard = cmd(boss, "admin.recovery", { action = "resolve", username = user,
    key = "pend:" .. secondId, revision = record(boss, user, "pend:" .. secondId).revision,
    decision = "discard", acceptUnproven = true, note = "voiding an operation nobody can prove" })
check(plainDiscard.error == "recovery_unproven_source" and okDiscard.ok == true
    and M.unclaimed(user) == mailedBefore and not Mk.listingExists(secondId)
    and seller.inventory.count("Base.CannedCorn") == 0
    and L.getBalance(user, "survivor").available == coinBefore
    and L.getBalance("SYSTEM_MINT", "survivor").available == mintBefore,
    "discarding an unproven record needs the same acceptance and hands out neither goods nor money")

-- ---- restorable=false：讀不到證據不是「玩家自述可以接受」，acceptUnproven 也推不動 ----
--
-- 這一條與上面兩條必須同時成立才算對齊：只要有人把 restorable=false 當成「關掉整個人工出口」，
-- 上面的 journal_missing 就會失去出口；只要有人讓 acceptUnproven 蓋過 restorable=false，
-- 一次 IO 失敗就變成可以憑玩家自述發物。
local thirdCorn = instanceItem("Base.CannedCorn")
assert(seller.inventory:AddItem(thirdCorn) == thirdCorn)
local savedThree = copy(S.modData())
local thirdListed = cmd(seller, "market.list", { itemId = thirdCorn:getID(), price = 64 })
assert(thirdListed.ok and proofSettle() == 0)
local thirdId = thirdListed.listingId
local thirdPath = proofJournalPath(user)
assert(files[thirdPath] ~= nil, "fixture: the third operation's line must be on disk")
modDataStore[EC.MODDATA_KEY] = copy(savedThree)
nowMs = nowMs + 1000
fire("OnServerStarted")
onlinePlayers = { boss, seller }
local realReader = getFileReader
getFileReader = function(p, create)
    if p == thirdPath then return nil end
    return realReader(p, create)
end
M.reconcile(seller)
proofPump(user)
local thirdRow = record(boss, user, "pend:" .. thirdId)
check(thirdRow ~= nil and thirdRow.proofState == "journal_unreadable"
    and thirdRow.blocked == "journal_unreadable" and thirdRow.actions.restore == false
    and thirdRow.unproven ~= true and thirdRow.restorable ~= true and type(thirdRow.revision) == "string",
    "a record whose evidence could not be read is not manually restorable: an IO failure is not the player's word")
local forced = cmd(boss, "admin.recovery", { action = "resolve", username = user,
    key = "pend:" .. thirdId, revision = thirdRow.revision, decision = "restore",
    acceptUnproven = true, note = "trying to force a record whose evidence never opened" })
getFileReader = realReader
check(forced.ok == false and forced.error == thirdRow.blocked and forced.error == "journal_unreadable"
    and not Mk.listingExists(thirdId) and M.unclaimed(user) == mailedBefore
    and seller.modData[KEY].pendingOuts[thirdId] ~= nil
    and seller.inventory.count("Base.CannedCorn") == 0
    and L.getBalance(user, "survivor").available == coinBefore
    and L.getBalance("SYSTEM_MINT", "survivor").available == mintBefore,
    "the explicit acceptance cannot force a non-restorable record, and the refusal names that row's own blocked reason")
onlinePlayers = {}
SandboxVars.MinidoracatEconomy.MarketListingFeePercent = nil
SandboxVars.MinidoracatEconomy.MarketMaxListings = nil
end)()

-- ===== 情境七十五：提交點與保留下限都由 journal 自己說，不由玩家說 =====
--
-- 這是 journal 帶來的**新信任邊界**，不是重測舊的 if：以前 rollback 判定與 retention floor 讀的
-- 是 pending 的 epoch/seq/at（玩家存檔裡的欄位），現在必須讀 journal 行自己記的提交點與時間。
-- 三條反例分別對應三種「玩家說了不算」：
--   a. 行說這筆已經進過存檔（survived）——玩家宣稱 rolledback 也不還原，人工也不能接受
--   b. 行的提交點落在這台伺服器已經不認識的 epoch（unknown）——而且**絕不可以**因為身份對不上
--      就掉進「查無我方紀錄 → 可接受玩家自述」那條路
--   c. 行的時間在保留下限之下——玩家把 pending 的 at/journalAt 改成現在也繞不過去
io.write("scenario 75: the journal's own commit point and retention floor outrank the player's claim\n")
;(function()
local M, Mk, Rec, Shop = S.Mailbox, S.Market, S.Recovery, S.Shop
local KEY = EC.PLAYER_MODDATA_KEY
local serial = 0
local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, value in pairs(v) do out[k] = copy(value) end
    return out
end
local function cmd(p, name, args)
    serial, nowMs = serial + 1, nowMs + 700
    args = args or {}
    args.requestId = args.requestId or ("proof75-" .. serial)
    withCurrency(name, args)
    local first = #sentCommands + 1
    fire("OnClientCommand", EC.COMMAND_MODULE, name, p, args)
    for i = first, #sentCommands do
        local reply = sentCommands[i]
        if reply.player == p and reply.command == name then return reply.args end
    end
    error("missing reply: " .. name)
end
local function reason(user, id)
    local rec = Rec.heldRecord(user, "pend:" .. id)
    return rec and rec.resolvedAt == nil and rec.reason or nil
end
local function rowOf(reply, key)
    for _, row in ipairs(reply.records or {}) do if row.key == key then return row end end
    return nil
end
-- 一筆真的、已落盤、世界已回滾的刊登。回傳 boss / seller / opId / 月檔路徑 / 那一行的表。
local function rolledBack(tag)
    modDataStore[EC.MODDATA_KEY] = nil
    files, writerDeny, sentCommands, sentItemPackets = {}, {}, {}, {}
    worldSprites = { ["100,200,0"] = "MinidoracatEconomy_terminal_0" }
    SandboxVars.MinidoracatEconomy.MarketListingFeePercent = 0
    SandboxVars.MinidoracatEconomy.MarketMaxListings = 8
    files[Shop.FILE] = { lines = { EC.jsonEncode({ items = {
        { id = "corn", item = "Base.CannedCorn", qty = 1,
            prices = { survivor = { price = 20, bidPrice = 8, buyback = true } } },
    } }) }, opens = 0 }
    nowMs = nowMs + 61000
    fire("OnServerStarted")
    local boss, seller = fakePlayer(tag .. "-admin"), fakePlayer(tag .. "-seller")
    boss.role = "admin"
    seller.inventory = fakeInventory(200)
    local user = seller:getUsername()
    onlinePlayers = { boss, seller }
    assert(cmd(boss, "terminal.register", { x = 100, y = 200, z = 0, kind = "atm" }).ok)
    assert(L.credit(user, "survivor", 5000, "SYSTEM_MINT",
        { requestId = tag .. "-seed", reasonCode = "test" }).ok)
    local corn = instanceItem("Base.CannedCorn")
    assert(seller.inventory:AddItem(corn) == corn)
    local saved = copy(S.modData())
    local listed = cmd(seller, "market.list", { itemId = corn:getID(), price = 88 })
    assert(listed.ok and proofSettle() == 0)
    local path = proofJournalPath(user)
    assert(files[path] ~= nil, "fixture: the journal line must be on disk before the rollback")
    modDataStore[EC.MODDATA_KEY] = copy(saved)
    nowMs = nowMs + 1000
    fire("OnServerStarted")
    onlinePlayers = { boss, seller }
    return boss, seller, listed.listingId, path
end
-- ---- a. 鏈的後繼決定 verdict：不得退回 pending 剛好匹配到的那個 rolledback 祖先 ----
--
-- 新契約：後繼 = 檔內最後一筆合法行，server seq **嚴格遞增**；pending 命中祖先算通過
-- （identity 只比經濟內容），但 replay／verdict／floor 一律取後繼。
-- 這裡祖先判 rolledback（可還原），後繼的提交點落在這台伺服器已經不認識的 epoch（unknown）。
-- 取祖先就會還原一筆結局不明的操作；取後繼才是對的，而 unknown 不是可以人工採納的反證。
-- 注意 seq 必須遞增：用比祖先更小的 seq 會變成 chain.order 壞鏈，那測到的是別的東西。
do
    local boss, seller, id, path = rolledBack("p75a")
    local user = seller:getUsername()
    local ancestor = proofJournalSuccessor(user, id)
    assert(ancestor ~= nil and Rec.verdict(ancestor.epoch, tonumber(ancestor.seq)) == "rolledback",
        "fixture: the ancestor line must read as rolled back")
    local successor = copy(seller.modData[KEY].pendingOuts[id])   -- live 形狀，避免 wire 雙重打包
    successor.epoch, successor.seq = "1", tonumber(ancestor.seq) + 3
    assert(proofJournalEmit(user, id, "1", tonumber(ancestor.seq) + 3, successor,
        ancestor.kind, ancestor.ref), "fixture: the successor must be written by the real producer")
    assert(#proofJournalChain(user, id) == 2, "fixture: the chain must carry an ancestor and a successor")
    assert(Rec.verdict("1", tonumber(ancestor.seq) + 3) == "unknown",
        "fixture: the successor's own commit point must be one this server no longer knows")
    local coinBefore, mintBefore = L.getBalance(user, "survivor").available,
        L.getBalance("SYSTEM_MINT", "survivor").available
    M.reconcile(seller)
    proofPump(user)
    local row = rowOf(cmd(boss, "admin.recovery", { action = "list", username = user }), "pend:" .. id)
    check(reason(user, id) == "outcome_unverified" and row ~= nil
        and row.proofState == "outcome_unverified" and row.outcome == "unknown"
        and row.actions.restore == false and row.unproven ~= true and row.restorable ~= true
        and not Mk.listingExists(id) and seller.inventory.count("Base.CannedCorn") == 0,
        "the newest legal decision in the chain is what decides the outcome, and a found line stays evidence even when its commit point is unknown: never downgraded to no record at all")
    local forced = cmd(boss, "admin.recovery", { action = "resolve", username = user, key = "pend:" .. id,
        revision = row.revision, decision = "restore", acceptUnproven = true,
        note = "player insists this listing was lost" })
    check(forced.ok == false and forced.error == row.blocked
        and not Mk.listingExists(id) and M.unclaimed(user) == 0
        and seller.modData[KEY].pendingOuts[id] ~= nil
        and L.getBalance(user, "survivor").available == coinBefore
        and L.getBalance("SYSTEM_MINT", "survivor").available == mintBefore,
        "an unanswered outcome cannot be accepted by hand either: unanswered is not a licence, so no letter, no item, no coin")
end

-- ---- c. 玩家改寫 at 想繞過保留下限：先被 retention floor 擋住，繞不過去 ----
--
-- 單一 judge 的拒絕順序是 floor 優先：後繼行的 outAt 已經在保留下限之下，所以不管玩家把
-- pending 的時間戳改成什麼，結論都是 receipt_forgotten —— 那個時間戳從頭到尾決定不了任何事。
-- （`at` 同時也屬於 identity 比對範圍，但這一格看不到那一層，因為 floor 先回答了。）
do
    local boss, seller, id, path = rolledBack("p75c")
    local user = seller:getUsername()
    local line = nil
    for _, row in ipairs(proofJournalRows(user)) do if row.opId == id then line = row end end
    assert(line ~= nil and type(line.outAt) == "number", "fixture: the line must carry its own outAt")
    S.modData().recovery.floorAt = line.outAt + 1     -- 這一行已經在保留下限之下
    local pend = seller.modData[KEY].pendingOuts[id]
    pend.at, pend.journalAt = line.outAt + 60000, line.outAt + 60000
    local coinBefore, mintBefore = L.getBalance(user, "survivor").available,
        L.getBalance("SYSTEM_MINT", "survivor").available
    assert(not Rec.forgotten(pend.at), "fixture: the rewritten player timestamp must clear the floor")
    M.reconcile(seller)
    proofPump(user)
    local row = rowOf(cmd(boss, "admin.recovery", { action = "list", username = user }), "pend:" .. id)
    check(reason(user, id) == "receipt_forgotten" and row ~= nil
        and row.proofState == "receipt_forgotten" and row.actions.restore == false
        and row.unproven ~= true and row.restorable ~= true and not Mk.listingExists(id)
        and seller.modData[KEY].pendingOuts[id] ~= nil
        and seller.inventory.count("Base.CannedCorn") == 0,
        "rewriting the record's own timestamp cannot clear the retention floor: the floor is measured against the server's own successor and answers first, so the player's timestamp decides nothing")
    local forced = cmd(boss, "admin.recovery", { action = "resolve", username = user, key = "pend:" .. id,
        revision = row.revision, decision = "restore", acceptUnproven = true,
        note = "trying to revive an operation older than the retention floor" })
    check(forced.ok == false and forced.error == row.blocked
        and not Mk.listingExists(id) and M.unclaimed(user) == 0
        and L.getBalance(user, "survivor").available == coinBefore
        and L.getBalance("SYSTEM_MINT", "survivor").available == mintBefore,
        "and it cannot be forced through by hand either: the refusal names that row's own blocked reason")
end
onlinePlayers = {}
SandboxVars.MinidoracatEconomy.MarketListingFeePercent = nil
SandboxVars.MinidoracatEconomy.MarketMaxListings = nil
end)()

-- ===== 情境七十六：連續兩輪「回滾 → 依 journal 恢復 → 再回滾 → 再恢復」的真路徑 =====
--
-- 為什麼必須整條真跑：restore 自己也是一次 R.finishOut。世界回滾會把 md.recovery.ops 一起帶走，
-- 所以回滾後同一個 opId 會拿到**新的 commit point**，並且真的寫出一行後繼 journal。兩輪之後
-- 同 opId 就有多行、提交點不同 —— 這不是誰 stub 出來的假設，是生產者與消費者接起來才看得到的
-- 事實，所以第一條 check 專門把「後繼寫入確實發生、pending 也確實換成新提交點」釘住。
-- 第二輪的結果由 Main 定調（fail-closed 判 malformed 或允許取最新），所以這裡**不釘**是哪一種，
-- 只釘兩件與定調無關、但一旦壞掉就是事故的事：錢物不得增減，狀態必須可診斷、不得被靜默關掉。
io.write("scenario 76: two consecutive rollback-and-rebuild rounds on the real path\n")
;(function()
local M, Mk, Rec, Shop = S.Mailbox, S.Market, S.Recovery, S.Shop
local KEY = EC.PLAYER_MODDATA_KEY
local serial = 0
local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, value in pairs(v) do out[k] = copy(value) end
    return out
end
local function cmd(p, name, args)
    serial, nowMs = serial + 1, nowMs + 700
    args = args or {}
    args.requestId = args.requestId or ("proof76-" .. serial)
    withCurrency(name, args)
    local first = #sentCommands + 1
    fire("OnClientCommand", EC.COMMAND_MODULE, name, p, args)
    for i = first, #sentCommands do
        local reply = sentCommands[i]
        if reply.player == p and reply.command == name then return reply.args end
    end
    error("missing reply: " .. name)
end
local function rowsFor(user, id)
    return proofJournalChain(user, id)
end
local function tally(p, fullType)
    local total = p.inventory.count(fullType)
    for _, row in ipairs(Mk.mine(p:getUsername())) do
        if row.item == fullType then total = total + (row.qty or 1) end
    end
    for _, row in ipairs(M.list(p:getUsername())) do
        if row.item == fullType then total = total + (row.qty or 1) end
    end
    return total
end

modDataStore[EC.MODDATA_KEY] = nil
files, writerDeny, sentCommands, sentItemPackets = {}, {}, {}, {}
worldSprites = { ["100,200,0"] = "MinidoracatEconomy_terminal_0" }
SandboxVars.MinidoracatEconomy.MarketListingFeePercent = 0
SandboxVars.MinidoracatEconomy.MarketMaxListings = 8
files[Shop.FILE] = { lines = { EC.jsonEncode({ items = {
    { id = "corn", item = "Base.CannedCorn", qty = 1,
        prices = { survivor = { price = 20, bidPrice = 8, buyback = true } } },
} }) }, opens = 0 }
nowMs = nowMs + 61000
fire("OnServerStarted")
local boss, seller = fakePlayer("p76-admin"), fakePlayer("p76-seller")
boss.role = "admin"
seller.inventory = fakeInventory(200)
local user = seller:getUsername()
onlinePlayers = { boss, seller }
assert(cmd(boss, "terminal.register", { x = 100, y = 200, z = 0, kind = "atm" }).ok)
assert(L.credit(user, "survivor", 5000, "SYSTEM_MINT", { requestId = "p76-seed", reasonCode = "test" }).ok)
local corn = instanceItem("Base.CannedCorn")
assert(seller.inventory:AddItem(corn) == corn)
local saved = copy(S.modData())                       -- 這一份存檔在刊登之前，兩輪都回滾到它
local listed = cmd(seller, "market.list", { itemId = corn:getID(), price = 88 })
assert(listed.ok and proofSettle() == 0)
local id = listed.listingId
local firstPoint = copy(S.modData().recovery.ops[id])
assert(#rowsFor(user, id) == 1, "fixture: the original operation wrote exactly one line")

-- ---- 第一輪：回滾 → 依 journal 恢復 → 恢復自己的提交點也要落盤 ----
modDataStore[EC.MODDATA_KEY] = copy(saved)
nowMs = nowMs + 1000
fire("OnServerStarted")
onlinePlayers = { boss, seller }
M.reconcile(seller)
proofPump(user)
local rebuilt = S.modData().market.listings[id]
local secondPoint = S.modData().recovery.ops[id]
assert(proofSettle() == 0)                            -- 讓 restore 自己那一行真的寫出去
local rows = rowsFor(user, id)
local pend = seller.modData[KEY].pendingOuts[id]
check(rebuilt ~= nil and rebuilt.price == 88 and secondPoint ~= nil
    and secondPoint.epoch ~= firstPoint.epoch and #rows == 2
    and rows[2].epoch == secondPoint.epoch and rows[2].seq == secondPoint.seq
    and pend ~= nil and pend.epoch == secondPoint.epoch and tonumber(pend.seq) == secondPoint.seq,
    "the first rollback is rebuilt from the journal, and that rebuild's own commit point is really written as a successor line and carried by the pending record")

-- ---- 第二輪：再回滾到同一份存檔，同 opId 現在有兩個提交點 ----
local coinBefore = L.getBalance(user, "survivor").available
modDataStore[EC.MODDATA_KEY] = copy(saved)
nowMs = nowMs + 1000
fire("OnServerStarted")
onlinePlayers = { boss, seller }
M.reconcile(seller)
proofPump(user)
check(tally(seller, "Base.CannedCorn") <= 1 and Mk.ownerCount(user) <= 1
    and seller.inventory.count("Base.CannedCorn") == 0
    and L.getBalance(user, "survivor").available == coinBefore
    and L.conservation("survivor") == 0,
    "a second rollback of the same operation never duplicates the unit and moves no coin either way")
-- Main 的裁定：連續 restore 產生的第二個提交點是**合法歷史**，不是互相矛盾的證據，所以第二輪
-- 根本不該落到 journal_malformed。因此這裡直接釘正確結局（重建恰好一次、用 journal 的價），
-- 不再提供「掛起但留人工出口」這個替代分支 —— 依裁定，真正內容矛盾／壞檔在遊戲內只能重查，
-- 契約第 50 行的人工出口只適用於「確實無證據」（journal_missing），不適用於損壞或矛盾的證據。
local held = Rec.heldRecord(user, "pend:" .. id)
local openHold = held ~= nil and held.resolvedAt == nil and held.reason or nil
check(Mk.listingExists(id) and Mk.ownerCount(user) == 1 and openHold == nil
    and S.modData().market.listings[id].price == 88
    and S.modData().market.listings[id].currency == "survivor"
    and tally(seller, "Base.CannedCorn") == 1,
    "the second rollback rebuilds the operation exactly once from its newest commit point: a restore's own successor line is legitimate history, not evidence that contradicts itself")

-- ---- 跨月：op 的檔由 opId 的 epoch 決定，所以第二輪落在別的月份也找得到同一條鏈 ----
--
-- 舊設計用時間 hint 猜月檔，跨月的第二輪就會找不到後繼。新契約把檔名固定在 opId 的 epoch 月，
-- 所以把世界時間推到下個月再回滾，仍然必須讀到同一條鏈並合法重建。
do
    local before = nowMs
    nowMs = nowMs + 32 * 86400000                      -- 推到下個月再回滾第三輪
    modDataStore[EC.MODDATA_KEY] = copy(saved)
    fire("OnServerStarted")
    onlinePlayers = { boss, seller }
    local coinNow = L.getBalance(user, "survivor").available
    M.reconcile(seller)
    proofPump(user)
    local live = S.modData().market.listings[id]
    local crossHeld = Rec.heldRecord(user, "pend:" .. id)
    check(EC.monthKey(nowMs) ~= EC.monthKey(before)
        and proofJournalPathForOp(user, id) == proofJournalPath(user, before)
        and live ~= nil and live.price == 88 and Mk.ownerCount(user) == 1
        and (crossHeld == nil or crossHeld.resolvedAt ~= nil)
        and tally(seller, "Base.CannedCorn") == 1
        and L.getBalance(user, "survivor").available == coinNow,
        "a rollback in a later month still finds the operation's chain: the file is fixed by the operation id, so crossing a month boundary cannot hide the successor")
end

-- ---- 偽造的時間欄位不能把後繼藏起來 ----
--
-- journalAt 已經取消，outAt 只是紀錄。這裡把 pending 的 at 與後繼那一行的 outAt 都改指到
-- 別的月份，並在那個月份的檔裡放一份「看起來可以還原」的舊內容。選檔既然只看 opId，
-- 那份假檔就必須完全不影響判定。
do
    modDataStore[EC.MODDATA_KEY] = copy(saved)
    nowMs = nowMs + 1000
    fire("OnServerStarted")
    onlinePlayers = { boss, seller }
    local decoyMs = nowMs + 64 * 86400000
    local chain = proofJournalChain(user, id)
    local decoy = copy(chain[#chain].replay)
    decoy.price = 999999
    proofJournalWrite(user, decoyMs,
        proofJournalRecord(user, id, chain[#chain].epoch, chain[#chain].seq, decoy,
            { outAt = decoyMs }))
    local pend = seller.modData[KEY].pendingOuts[id]
    local realAt, realJournalAt = pend.at, pend.journalAt
    pend.at, pend.journalAt = decoyMs, decoyMs
    local coinNow = L.getBalance(user, "survivor").available
    M.reconcile(seller)
    proofPump(user)
    local live = S.modData().market.listings[id]
    check(proofJournalPath(user, decoyMs) ~= proofJournalPathForOp(user, id)
        and (live == nil or live.price == 88)
        and L.getBalance(user, "survivor").available == coinNow
        and L.conservation("survivor") == 0
        and tally(seller, "Base.CannedCorn") <= 1,
        "a forged timestamp pointing at another month's file changes nothing: the decoy is never read and its price never reaches the world")
    -- 玩家存檔不隨世界回滾，所以這裡竄改的欄位必須還原，否則會汙染後面的案例
    pend.at, pend.journalAt = realAt, realJournalAt
end

-- ---- discard 後繼：不自動重建，人工重審只能用 previous ----
do
    modDataStore[EC.MODDATA_KEY] = copy(saved)
    nowMs = nowMs + 1000
    fire("OnServerStarted")
    onlinePlayers = { boss, seller }
    local chain = proofJournalChain(user, id)
    local last = chain[#chain]
    -- 一筆合法的 discard 後繼：contract 允許 qty=0 與空 origins，且不得污染合法鏈
    assert(proofJournalEmit(user, id, last.epoch, tonumber(last.seq) + 5,
        { kind = "discard", qty = 0, origins = {}, protocol = 2, tradeSchema = 2,
          snapshot = copy(seller.modData[KEY].pendingOuts[id].snapshot), currency = "survivor",
          epoch = last.epoch, seq = tonumber(last.seq) + 5 }, "discard"),
        "fixture: the discard successor must be written by the real producer")
    local coinNow = L.getBalance(user, "survivor").available
    M.reconcile(seller)
    proofPump(user)
    local discardHeld = Rec.heldRecord(user, "pend:" .. id)
    local discardRow = nil
    for _, r in ipairs(cmd(boss, "admin.recovery", { action = "list", username = user }).records or {}) do
        if r.opId == id then discardRow = r end
    end
    check(not Mk.listingExists(id) and M.unclaimed(user) == 0
        and discardHeld ~= nil and discardHeld.resolvedAt == nil
        and discardHeld.reason == "admin_discard_rolledback"
        and seller.inventory.count("Base.CannedCorn") == 0
        and L.getBalance(user, "survivor").available == coinNow
        and L.conservation("survivor") == 0,
        "a discard successor is the newest decision: the operation is never rebuilt automatically and nothing is handed back")
    -- 契約允許人工**重審**（用 previous），所以這裡不要求 actions.restore 關閉 —— 要求的是
    -- 這一列說得出它是一個已作廢的決定，而不是被當成「無證據、可採納玩家自述」的申訴。
    -- CommerceServer 的形狀：discardable 恆真（結案），restorable 才管「能不能生成資產」。
    -- discard 那一行本身是 qty=0 ＋空 origins，而且必須在 malformed 檢查之前就被認出來。
    check(discardRow ~= nil and discardRow.reason == "admin_discard_rolledback"
        and discardRow.proofState == "admin_discard_rolledback"
        and discardRow.unproven ~= true and discardRow.actions.discard == true
        and discardRow.actions.restore == true,
        "a discard line with no quantity and no origins is recognised as the decision it is, never as a malformed record, and the review it allows is the server's previous replay")
end

-- ---- 鏈上只剩 discard（原始那一行遺失）：identity 先擋，結果是 mismatch ----
--
-- CommerceServer 要求釘「無 previous 時 restore 關但 discard 仍開」。實測發現那個狀態**走
-- pending 這條路到不了**：identity 比對在 discard 分類之前，而 discard 那一行是 qty=0＋空
-- origins，任何真實 pending 的經濟內容都對不上它，所以先回 journal_mismatch（兩個動作都關）。
-- 換句話說「有 discard 後繼但沒有可建 previous」只可能發生在原始行已遺失時，而那時擋住它的
-- 是 identity，不是 discard 規則。這裡釘實際成立的那件事：資料殘缺不會動錢物、狀態可診斷。
-- 「兩個門都關住一筆沒人能重建的作廢決定」這個 working set 風險已回報給 CommerceServer／Main。
do
    modDataStore[EC.MODDATA_KEY] = copy(saved)
    nowMs = nowMs + 1000
    fire("OnServerStarted")
    onlinePlayers = { boss, seller }
    local chain = proofJournalChain(user, id)
    local last = chain[#chain]
    local path = proofJournalPathForOp(user, id)
    files[path].lines = {}                               -- 原始行遺失，鏈上只剩一筆 discard
    assert(proofJournalEmit(user, id, last.epoch, tonumber(last.seq) + 9,
        { kind = "discard", qty = 0, origins = {}, protocol = 2, tradeSchema = 2,
          currency = "survivor", epoch = last.epoch, seq = tonumber(last.seq) + 9 }, "discard"),
        "fixture: the discard successor must be written by the real producer")
    local coinNow = L.getBalance(user, "survivor").available
    M.reconcile(seller)
    proofPump(user)
    local row = nil
    for _, r in ipairs(cmd(boss, "admin.recovery", { action = "list", username = user }).records or {}) do
        if r.opId == id then row = r end
    end
    check(row ~= nil and row.reason == "admin_discard_rolledback" and row.preview == nil
        and row.actions.restore == false and row.actions.discard == true
        and row.unproven ~= true and not Mk.listingExists(id) and M.unclaimed(user) == 0
        and seller.modData[KEY].pendingOuts[id] ~= nil
        and seller.inventory.count("Base.CannedCorn") == 0
        and L.getBalance(user, "survivor").available == coinNow
        and L.conservation("survivor") == 0,
        "a chain that lost its original line leaves the claim matching nothing: the record stays open and diagnosable, and no goods or coin move on partial data")
end
onlinePlayers = {}
SandboxVars.MinidoracatEconomy.MarketListingFeePercent = nil
SandboxVars.MinidoracatEconomy.MarketMaxListings = nil
end)()

-- ===== 情境七十七：查證期間背包變了，不得把「一開始在」當成「這筆作業已經移出」 =====
--
-- 兩件單位的刊登回滾後，其中一件實體還在背包裡（世界回滾會把它帶回來），另一件不見了 ——
-- 這是 partial 候選，所以會去查 journal。查證還在跑的時候，那件還在背包的被移出了背包。
-- 危險的寫法是拿「讀取開始時的那份 scan」下結論：那一件會被當成「作業已經把它移出」。
--
-- 計數的陷阱（Main 指出）：**把實物移出背包不等於銷毀**。它掉在地上／進了別的容器，
-- 伺服器看不到，但它還在這個世界上。所以只算「背包 + 市場 + 信箱」會把「多還一件」
-- 誤讀成守恆 —— 那是假綠。下面用一個獨立的 ground 集合代表那件實物，tally 必須把它算進去，
-- 結束時「背包 + 市場 + 信箱 + ground」不得大於 2。
-- 也就是說：伺服器分不出「掉在地上（還存在）」與「真的沒了」，所以它可以 partial、可以 hold，
-- 但**不可以**把那件當成已消耗而免費再補一件同樣效用的東西。
io.write("scenario 77: a backpack that changed during the proof read is observed again, not remembered\n")
;(function()
local M, Mk, Rec, Shop = S.Mailbox, S.Market, S.Recovery, S.Shop
local J = S.RecoveryJournal or {}
local KEY = EC.PLAYER_MODDATA_KEY
local serial = 0
local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, value in pairs(v) do out[k] = copy(value) end
    return out
end
local function cmd(p, name, args)
    serial, nowMs = serial + 1, nowMs + 700
    args = args or {}
    args.requestId = args.requestId or ("proof77-" .. serial)
    withCurrency(name, args)
    local first = #sentCommands + 1
    fire("OnClientCommand", EC.COMMAND_MODULE, name, p, args)
    for i = first, #sentCommands do
        local reply = sentCommands[i]
        if reply.player == p and reply.command == name then return reply.args end
    end
    error("missing reply: " .. name)
end
local function jstat(u)
    if type(J.status) ~= "function" then return {} end
    local st = J.status(u)
    return type(st) == "table" and st or {}
end
-- ground：已經離開背包、伺服器看不到、但確實還存在於世界上的實物。
local ground = {}
local function tally(p, fullType)
    local total = p.inventory.count(fullType)
    for item in pairs(ground) do
        if item.fullType == fullType then total = total + 1 end
    end
    for _, row in ipairs(Mk.mine(p:getUsername())) do
        if row.item == fullType then total = total + (row.qty or 1) end
    end
    for _, row in ipairs(M.list(p:getUsername())) do
        if row.item == fullType then total = total + (row.qty or 1) end
    end
    return total
end

modDataStore[EC.MODDATA_KEY] = nil
files, writerDeny, sentCommands, sentItemPackets = {}, {}, {}, {}
worldSprites = { ["100,200,0"] = "MinidoracatEconomy_terminal_0" }
SandboxVars.MinidoracatEconomy.MarketListingFeePercent = 0
SandboxVars.MinidoracatEconomy.MarketMaxListings = 8
files[Shop.FILE] = { lines = { EC.jsonEncode({ items = {
    { id = "corn", item = "Base.CannedCorn", qty = 1,
        prices = { survivor = { price = 20, bidPrice = 8, buyback = true } } },
} }) }, opens = 0 }
nowMs = nowMs + 61000
fire("OnServerStarted")
local boss, seller = fakePlayer("p77-admin"), fakePlayer("p77-seller")
boss.role = "admin"
seller.inventory = fakeInventory(200)
local user = seller:getUsername()
onlinePlayers = { boss, seller }
assert(cmd(boss, "terminal.register", { x = 100, y = 200, z = 0, kind = "atm" }).ok)
assert(L.credit(user, "survivor", 5000, "SYSTEM_MINT", { requestId = "p77-seed", reasonCode = "test" }).ok)
local first, second = instanceItem("Base.CannedCorn"), instanceItem("Base.CannedCorn")
assert(seller.inventory:AddItem(first) == first and seller.inventory:AddItem(second) == second)
local saved = copy(S.modData())
proofJournalPad(user, nil, 500)                        -- 讀取要跨 tick，才有「查證期間」可言
local listed = cmd(seller, "market.list", { itemIds = { first:getID(), second:getID() }, price = 45 })
assert(listed.ok and proofSettle() == 0)
local id = listed.listingId
assert(seller.inventory.count("Base.CannedCorn") == 0, "fixture: both units left the backpack")
modDataStore[EC.MODDATA_KEY] = copy(saved)
nowMs = nowMs + 1000
fire("OnServerStarted")
onlinePlayers = { boss, seller }
assert(seller.inventory:AddItem(first) == first)       -- 回滾把其中一件實體留在背包裡
local coinBefore = L.getBalance(user, "survivor").available
M.reconcile(seller)
fire("OnTickEvenPaused")
local wasReading = jstat(user).reading == true
seller.inventory:Remove(first)                         -- 查證期間那一件被移出背包
ground[first] = true                                   -- 移出背包不是銷毀：它還在世界上
proofPump(user, 400)
local total = tally(seller, "Base.CannedCorn")
check(wasReading and total <= 2 and total >= 1
    and L.getBalance(user, "survivor").available == coinBefore
    and L.conservation("survivor") == 0,
    "a unit that left the backpack while the proof was being read is still a unit that exists: counting the backpack, the market, the mailbox and that object together never exceeds the two the journal recorded")
check(not (seller.modData[KEY].pendingOuts[id] == nil and not Mk.listingExists(id)
        and M.unclaimed(user) == 0),
    "and the operation is never closed as already-moved-out on the strength of an observation taken before the read")

-- Main 追加：這道防線不能只擋 callback 那一次。票被消費掉之後，重登與管理員唯讀查看都必須
-- 仍然得到同一個判斷 —— 否則玩家只要再登入一次就能把那一件補出來。
local heldAfter = Rec.heldRecord(user, "pend:" .. id)
local marketBefore = tally(seller, "Base.CannedCorn")
M.reconcile(seller)
proofPump(user, 400)
local heldAgain = Rec.heldRecord(user, "pend:" .. id)
local adminRow = nil
for _, r in ipairs(cmd(boss, "admin.recovery", { action = "list", username = user }).records or {}) do
    if r.opId == id then adminRow = r end
end
check(heldAfter ~= nil and heldAfter.reason == "source_state_changed"
    and heldAgain ~= nil and heldAgain.resolvedAt == nil and heldAgain.reason == "source_state_changed"
    and adminRow ~= nil and adminRow.reason == "source_state_changed"
    and adminRow.restorable ~= true and adminRow.actions.restore == false
    and tally(seller, "Base.CannedCorn") == marketBefore
    and L.getBalance(user, "survivor").available == coinBefore,
    "the same judgement survives the spent ticket: a later login and an administrator's read both still see a world that moved, and neither of them conjures the unit back")

-- contract 57 行：source_state_changed 也在「不提供採納反證旁路」那一串裡（ServerTests 的
-- 情境 80 守其餘各碼，這一碼的前置整套在這裡，所以由這段釘）。
local forcedMoved = cmd(boss, "admin.recovery", { action = "resolve", username = user,
    key = "pend:" .. id, revision = adminRow and adminRow.revision, decision = "restore",
    acceptUnproven = true, note = "trying to accept a claim whose world moved under the read" })
check(forcedMoved.ok == false and forcedMoved.error == adminRow.blocked
    and tally(seller, "Base.CannedCorn") == marketBefore
    and seller.modData[KEY].pendingOuts[id] ~= nil and M.unclaimed(user) == 0
    and L.getBalance(user, "survivor").available == coinBefore,
    "and the explicit acceptance is no bypass for it either: a world that moved is counter-evidence, so the refusal names that row's own blocked reason and writes nothing")

-- 自癒：玩家把地上那件撿回背包，判定就不再被卡住，而且總數仍然是 2（沒有多出來的那一件）。
assert(seller.inventory:AddItem(first) == first)
ground[first] = nil
M.reconcile(seller)
proofPump(user, 400)
local healed = Rec.heldRecord(user, "pend:" .. id)
local openHealed = healed ~= nil and healed.resolvedAt == nil and healed.reason or nil
-- 契約第 69 行：「原物放回後可繼續正常 partial 收斂」—— 一件回到背包、另一件確實不見了，
-- 所以正確結局是只把**缺的那一件**還回來，總數仍然是 2。
check(openHealed ~= "source_state_changed"
    and seller.inventory.count("Base.CannedCorn") == 1
    and tally(seller, "Base.CannedCorn") == 2
    and L.getBalance(user, "survivor").available == coinBefore
    and L.conservation("survivor") == 0,
    "and it heals on its own: once that object is visible again the operation converges as an ordinary partial, returning only the unit that is really gone")
onlinePlayers = {}
SandboxVars.MinidoracatEconomy.MarketListingFeePercent = nil
SandboxVars.MinidoracatEconomy.MarketMaxListings = nil
end)()

-- ===== 情境七十八：同 opId 掛在別的帳戶名下是反證，不是「查無紀錄」 =====
--
-- Main 定案：opId 是 server 鑄的全域唯一值，所以同一個 opId 出現在別的帳戶名下是**反證**，
-- 不是證據缺席。它不可以走 journal_missing 那條「沒有任何反證 → 可由管理員明示接受」的路：
-- unproven / restorable 都不成立，acceptUnproven 連 restore 與 discard 都推不動，不得寫任何
-- receipt，也不得把對方帳戶的任何內容帶進回覆。
io.write("scenario 78: the same operation id under another account is counter-evidence, not an absence of records\n")
;(function()
local M, Mk, Rec, Shop = S.Mailbox, S.Market, S.Recovery, S.Shop
local KEY = EC.PLAYER_MODDATA_KEY
local serial = 0
local FOREIGN = "p78-unrelated-account"
local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, value in pairs(v) do out[k] = copy(value) end
    return out
end
local function cmd(p, name, args)
    serial, nowMs = serial + 1, nowMs + 700
    args = args or {}
    args.requestId = args.requestId or ("proof78-" .. serial)
    withCurrency(name, args)
    local first = #sentCommands + 1
    fire("OnClientCommand", EC.COMMAND_MODULE, name, p, args)
    for i = first, #sentCommands do
        local reply = sentCommands[i]
        if reply.player == p and reply.command == name then return reply.args end
    end
    error("missing reply: " .. name)
end
local function rowOf(reply, key)
    for _, row in ipairs(reply.records or {}) do if row.key == key then return row end end
    return nil
end

modDataStore[EC.MODDATA_KEY] = nil
files, writerDeny, sentCommands, sentItemPackets = {}, {}, {}, {}
worldSprites = { ["100,200,0"] = "MinidoracatEconomy_terminal_0" }
SandboxVars.MinidoracatEconomy.MarketListingFeePercent = 0
SandboxVars.MinidoracatEconomy.MarketMaxListings = 8
files[Shop.FILE] = { lines = { EC.jsonEncode({ items = {
    { id = "corn", item = "Base.CannedCorn", qty = 1,
        prices = { survivor = { price = 20, bidPrice = 8, buyback = true } } },
} }) }, opens = 0 }
nowMs = nowMs + 61000
fire("OnServerStarted")
local boss, seller = fakePlayer("p78-admin"), fakePlayer("p78-seller")
boss.role = "admin"
seller.inventory = fakeInventory(200)
local user = seller:getUsername()
onlinePlayers = { boss, seller }
assert(cmd(boss, "terminal.register", { x = 100, y = 200, z = 0, kind = "atm" }).ok)
assert(L.credit(user, "survivor", 5000, "SYSTEM_MINT", { requestId = "p78-seed", reasonCode = "test" }).ok)
local corn = instanceItem("Base.CannedCorn")
assert(seller.inventory:AddItem(corn) == corn)
local saved = copy(S.modData())
local listed = cmd(seller, "market.list", { itemId = corn:getID(), price = 99 })
assert(listed.ok and proofSettle() == 0)
local id, path = listed.listingId, proofJournalPath(user)
-- 這一行的 opId / 提交點 / replay 全部保持原樣，只把 owner 換成別的帳戶
do
    local lines = files[path].lines
    local rewritten = false
    for i = 1, #lines do
        local row = EC.jsonDecode(lines[i])
        if type(row) == "table" and row.opId == id then
            row.owner = FOREIGN
            lines[i] = EC.jsonEncode(row)
            rewritten = true
        end
    end
    assert(rewritten, "fixture: the line to re-own must exist")
end
modDataStore[EC.MODDATA_KEY] = copy(saved)
nowMs = nowMs + 1000
fire("OnServerStarted")
onlinePlayers = { boss, seller }
local coinBefore = L.getBalance(user, "survivor").available
local mintBefore = L.getBalance("SYSTEM_MINT", "survivor").available
M.reconcile(seller)
proofPump(user)
local listReply = cmd(boss, "admin.recovery", { action = "list", username = user })
local row = rowOf(listReply, "pend:" .. id)
-- row 上 unproven 為假時是「不帶這個欄位」，所以釘 ~= true（不得是 true），不強求字面 false。
check(row ~= nil and row.proofState == "journal_mismatch" and row.foreign == true
    and row.unproven ~= true and row.restorable ~= true and type(row.actions) == "table"
    and row.actions.restore == false and row.actions.discard == false
    and row.preview == nil and row.replay == nil
    and S.modData().recovery.ops[id] == nil and not Mk.listingExists(id),
    "a line for this operation owned by another account closes the manual exit instead of reading as no record at all, and writes no receipt")
local encoded, text = pcall(EC.jsonEncode, listReply)
check(encoded and type(text) == "string" and #text > 0
    and string.find(text, FOREIGN, 1, true) == nil,
    "and the reply carries nothing at all from the other account it collided with")
local forcedRestore = cmd(boss, "admin.recovery", { action = "resolve", username = user,
    key = "pend:" .. id, revision = row.revision, decision = "restore", acceptUnproven = true,
    note = "trying to accept a claim that collides with another account's record" })
local forcedDiscard = cmd(boss, "admin.recovery", { action = "resolve", username = user,
    key = "pend:" .. id, revision = rowOf(cmd(boss, "admin.recovery", { action = "list", username = user }),
        "pend:" .. id).revision, decision = "discard", acceptUnproven = true,
    note = "trying to void a claim that collides with another account's record" })
check(forcedRestore.ok == false and forcedRestore.error == row.blocked
    and forcedDiscard.ok == false and not Mk.listingExists(id)
    and M.unclaimed(user) == 0 and S.modData().recovery.ops[id] == nil
    and seller.modData[KEY].pendingOuts[id] ~= nil
    and seller.inventory.count("Base.CannedCorn") == 0
    and L.getBalance(user, "survivor").available == coinBefore
    and L.getBalance("SYSTEM_MINT", "survivor").available == mintBefore,
    "neither restore nor discard can be forced through with the explicit acceptance: counter-evidence is not a licence to act on the player's word")

-- ---- 同一條規則的世界分支：偽造的 opId 指向別人還活著的刊登（pre-journal 形狀）----
--
-- 舊路徑只問「這個 opId 在世界上還有沒有對應的刊登」，有就把持有者背包裡的同型物當成
-- 「這筆作業已經把它移出」而回收。若那筆刊登其實是別人的，回收的就是無辜的資產。
do
    modDataStore[EC.MODDATA_KEY] = nil
    files, writerDeny, sentCommands, sentItemPackets = {}, {}, {}, {}
    worldSprites = { ["100,200,0"] = "MinidoracatEconomy_terminal_0" }
    nowMs = nowMs + 61000
    fire("OnServerStarted")
    local admin, ann, bob = fakePlayer("p78w-admin"), fakePlayer("p78w-ann"), fakePlayer("p78w-bob")
    admin.role = "admin"
    ann.inventory, bob.inventory = fakeInventory(200), fakeInventory(200)
    onlinePlayers = { admin, ann, bob }
    assert(cmd(admin, "terminal.register", { x = 100, y = 200, z = 0, kind = "atm" }).ok)
    assert(L.credit(ann:getUsername(), "survivor", 5000, "SYSTEM_MINT",
        { requestId = "p78w-a", reasonCode = "test" }).ok)
    assert(L.credit(bob:getUsername(), "survivor", 5000, "SYSTEM_MINT",
        { requestId = "p78w-b", reasonCode = "test" }).ok)
    local bobItem = instanceItem("Base.CannedCorn")
    assert(bob.inventory:AddItem(bobItem) == bobItem)
    local bobListed = cmd(bob, "market.list", { itemId = bobItem:getID(), price = 150 })
    assert(bobListed.ok and proofSettle() == 0)
    local bobId = bobListed.listingId
    -- pre-journal 形狀：沒有 receipt、沒有 origins，只有引擎 id；opId 借用 bob 還活著的刊登
    S.modData().recovery.ops[bobId] = nil
    local annItem = instanceItem("Base.CannedCorn")
    assert(ann.inventory:AddItem(annItem) == annItem)
    Rec.playerData(ann).pendingOuts[bobId] = { protocol = 2, tradeSchema = 2,
        origins = { { src = "native", nativeId = annItem:getID(), item = "Base.CannedCorn" } },
        itemIds = { annItem:getID() }, itemId = annItem:getID(),
        qty = 1, lotQty = 1, kind = "listing", price = 10, currency = "survivor",
        snapshot = { type = "Base.CannedCorn", condition = 10, uses = 1, age = 0, repaired = 0 },
        epoch = select(1, EC.parseId(bobId)), seq = tonumber(select(2, EC.parseId(bobId))), at = nowMs }
    local annCoin = L.getBalance(ann:getUsername(), "survivor").available
    local bobCoin = L.getBalance(bob:getUsername(), "survivor").available
    M.reconcile(ann)
    proofPump(ann:getUsername())
    local annReply = cmd(admin, "admin.recovery", { action = "list", username = ann:getUsername() })
    -- 不假設 hold 用哪一把 key（removeOriginal 失敗走 "unit:"、判定 hold 走 "pend:"），一律按
    -- opId 找：這條要證的是「這筆作業被認定為別人的」，不是它被記在哪個 key 底下。
    local annRow, annHeld = nil, nil
    for _, r in ipairs(annReply.records or {}) do
        if r.opId == bobId then annRow = r end
    end
    for _, rec in ipairs(Rec.heldRecords(ann:getUsername())) do
        if rec.opId == bobId then annHeld = rec end
    end
    local okEncode, annText = pcall(EC.jsonEncode, annReply)
    check(annRow ~= nil and annHeld ~= nil and annHeld.reason == "world_owner"
        and annRow.reason == "world_owner" and annRow.foreign == true
        and annRow.unproven ~= true and annRow.restorable ~= true
        and annRow.actions.restore == false and annRow.actions.discard == false
        and annRow.presentQty == 0 and okEncode
        and string.find(annText, bob:getUsername(), 1, true) == nil,
        "a forged operation id pointing at another account's live listing is refused as a foreign owner, and names nothing about that account")
    check(ann.inventory:contains(annItem) and ann.inventory.count("Base.CannedCorn") == 1
        and Mk.listingExists(bobId) and S.modData().market.listings[bobId].price == 150
        and S.modData().market.listings[bobId].seller == bob:getUsername()
        and S.modData().recovery.ops[bobId] == nil
        and L.getBalance(ann:getUsername(), "survivor").available == annCoin
        and L.getBalance(bob:getUsername(), "survivor").available == bobCoin
        and L.conservation("survivor") == 0,
        "and it takes nothing from the forger's backpack, writes no receipt and leaves the other account's listing exactly as it was")

    -- 真正的 pre-journal 形狀（沒有 protocol、沒有 origins，只有引擎 id）走的是舊的
    -- 「世界上還有這個刊登 → 背包裡同型物是這筆作業留下的舊影本」路徑。那條路徑在這裡
    -- 不該給出「回收」這個動作：這筆作業是別人的，回收掉的會是 ann 合法的資產。
    Rec.playerData(ann).pendingOuts = {}
    for _, rec in ipairs(Rec.heldRecords(ann:getUsername())) do
        Rec.resolveHold(ann:getUsername(), rec.key, "fixture reset")
    end
    Rec.playerData(ann).pendingOuts[bobId] = { itemId = annItem:getID(), itemIds = { annItem:getID() },
        qty = 1, lotQty = 1, kind = "listing", price = 10, currency = "survivor",
        snapshot = { type = "Base.CannedCorn", condition = 10, uses = 1, age = 0, repaired = 0 },
        epoch = select(1, EC.parseId(bobId)), seq = tonumber(select(2, EC.parseId(bobId))), at = nowMs }
    M.reconcile(ann)
    proofPump(ann:getUsername())
    local legacyRow = nil
    for _, r in ipairs(cmd(admin, "admin.recovery", { action = "list", username = ann:getUsername() }).records or {}) do
        if r.opId == bobId then legacyRow = r end
    end
    check(legacyRow ~= nil
        and (legacyRow.foreign == true or legacyRow.actions.remove == false)
        and ann.inventory:contains(annItem) and ann.inventory.count("Base.CannedCorn") == 1
        and Mk.listingExists(bobId) and S.modData().recovery.ops[bobId] == nil
        and L.conservation("survivor") == 0,
        "the same forgery in the pre-journal record shape never offers an operator the reclaim of the forger's own item for somebody else's operation")
end
onlinePlayers = {}
SandboxVars.MinidoracatEconomy.MarketListingFeePercent = nil
SandboxVars.MinidoracatEconomy.MarketMaxListings = nil
end)()

-- ===== 情境七十九：FinalRecoveryReview-3 的 R/J 端反例（FR-03/04/05/06/08/09/10/11/12）=====
--
-- 這一段全部走真的 J/callback/admin 路徑，不 stub 判斷旗標；守恆一律計「背包 + 市場 + 信箱
-- + ground」的全物量（ground = 已離開背包、伺服器看不到、但確實還在世界上的實物）。
-- 人工端的 FR-01/02/07/08 由 ServerTests 的情境 83 負責，這裡只做自動路徑那一半。
io.write("scenario 79: the R/J side counterexamples from the final recovery review\n")
;(function()
local M, Mk, Rec, Shop = S.Mailbox, S.Market, S.Recovery, S.Shop
local J = S.RecoveryJournal or {}
local KEY = EC.PLAYER_MODDATA_KEY
local serial = 0
local ground = {}
local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, value in pairs(v) do out[k] = copy(value) end
    return out
end
local function cmd(p, name, args)
    serial, nowMs = serial + 1, nowMs + 700
    args = args or {}
    args.requestId = args.requestId or ("proof79-" .. serial)
    withCurrency(name, args)
    local first = #sentCommands + 1
    fire("OnClientCommand", EC.COMMAND_MODULE, name, p, args)
    for i = first, #sentCommands do
        local reply = sentCommands[i]
        if reply.player == p and reply.command == name then return reply.args end
    end
    error("missing reply: " .. name)
end
local function jstat(u)
    if type(J.status) ~= "function" then return {} end
    local st = J.status(u)
    return type(st) == "table" and st or {}
end
local function reason(user, id)
    local rec = Rec.heldRecord(user, "pend:" .. id)
    return rec and rec.resolvedAt == nil and rec.reason or nil
end
-- 全物量：背包 + 市場 + 信箱 + ground。少算 ground 會把複製讀成守恆（前幾輪踩過的假綠）。
local function tally(p, fullType)
    local total = p.inventory.count(fullType)
    for item in pairs(ground) do
        if item.fullType == fullType then total = total + 1 end
    end
    for _, row in ipairs(Mk.mine(p:getUsername())) do
        if row.item == fullType then total = total + (row.qty or 1) end
    end
    for _, row in ipairs(M.list(p:getUsername())) do
        if row.item == fullType then total = total + (row.qty or 1) end
    end
    return total
end
local function drop(seller, item)
    seller.inventory:Remove(item)
    ground[item] = true
end
local function pick(seller, item)
    ground[item] = nil
    seller.inventory:AddItem(item)
end
local function world(tag)
    -- ground 是跨 block 共用的 upvalue：每個 block 都是新世界，不清掉會把前一個世界的實體
    -- 算進這個世界的守恆總數（計數母體過寬，方向與漏算相反，但一樣是假的）。
    for item in pairs(ground) do ground[item] = nil end
    modDataStore[EC.MODDATA_KEY] = nil
    files, writerDeny, sentCommands, sentItemPackets = {}, {}, {}, {}
    worldSprites = { ["100,200,0"] = "MinidoracatEconomy_terminal_0" }
    SandboxVars.MinidoracatEconomy.MarketListingFeePercent = 0
    SandboxVars.MinidoracatEconomy.MarketMaxListings = 8
    files[Shop.FILE] = { lines = { EC.jsonEncode({ items = {
        { id = "corn", item = "Base.CannedCorn", qty = 1,
            prices = { survivor = { price = 20, bidPrice = 8, buyback = true } } },
    } }) }, opens = 0 }
    nowMs = nowMs + 61000
    fire("OnServerStarted")
    local boss, seller = fakePlayer(tag .. "-admin"), fakePlayer(tag .. "-seller")
    boss.role = "admin"
    seller.inventory = fakeInventory(400)
    onlinePlayers = { boss, seller }
    assert(cmd(boss, "terminal.register", { x = 100, y = 200, z = 0, kind = "atm" }).ok)
    assert(L.credit(seller:getUsername(), "survivor", 5000, "SYSTEM_MINT",
        { requestId = tag .. "-seed", reasonCode = "test" }).ok)
    return boss, seller
end
-- n 件單位的刊登、落盤、世界回滾；回傳 opId、那些實體、以及回滾前的世界快照。
-- keepVisible 指定回滾後要放回背包的件數（回滾會把實體帶回來）。padded=true 時灌大月檔讓讀取跨 tick。
local function rolledBackLot(tag, n, keepVisible, padded)
    local boss, seller = world(tag)
    local user = seller:getUsername()
    local items, ids = {}, {}
    for i = 1, n do
        local it = instanceItem("Base.CannedCorn")
        assert(seller.inventory:AddItem(it) == it)
        items[i] = it
        ids[i] = it:getID()
    end
    local saved = proofSnapshot()
    if padded then proofJournalPad(user, nil, 500) end
    local listed = cmd(seller, "market.list", { itemIds = ids, price = 45 })
    assert(listed.ok, tostring(listed.error))
    assert(proofSettle() == 0)
    proofRestartFrom(saved)
    onlinePlayers = { boss, seller }
    for i = 1, keepVisible or 0 do assert(seller.inventory:AddItem(items[i]) == items[i]) end
    return boss, seller, listed.listingId, items, saved
end

-- ---- FR-03：cache 過期／重啟後，sticky 的消失反證不得被 journal_pending 覆寫 ----
do
    local boss, seller, id, items = rolledBackLot("p79fr03", 2, 1, true)
    local user = seller:getUsername()
    M.reconcile(seller)
    fire("OnTickEvenPaused")
    drop(seller, items[1])                                 -- T0 看見、讀取中移到地上
    proofPump(user, 400)
    assert(reason(user, id) == "source_state_changed",
        "fixture: the first pass must record the disappearing unit")
    nowMs = nowMs + J.RESULT_TTL_MS + 5000                 -- 等 cache 過期，下一輪必回 journal_pending
    M.reconcile(seller)
    proofPump(user, 400)
    -- 保守 hold 的正確結果是「實體 1 件（在地上）＋ pending 義務仍留著」，不是總量 2：
    -- 那 2 件裡有一件本來就不在世界上，正等著被證明。所以釘的是「不得再生」＋義務不被清掉。
    check(reason(user, id) == "source_state_changed" and tally(seller, "Base.CannedCorn") <= 2
        and seller.modData[KEY].pendingOuts[id] ~= nil
        and Mk.ownerCount(user) == 0 and M.unclaimed(user) == 0
        and L.conservation("survivor") == 0,
        "a recorded disappearance outlives the proof cache: a later cold read answering pending neither overwrites the counter-evidence nor regenerates the unit, and the obligation stays open")
end

-- ---- FR-04：同一張未消費的票，第二次 hello 不得用新的 scan 覆寫 T0 ----
do
    local boss, seller, id, items = rolledBackLot("p79fr04", 2, 1, true)
    local user = seller:getUsername()
    M.reconcile(seller)
    fire("OnTickEvenPaused")
    drop(seller, items[1])                                 -- 讀取還沒完成就移出背包
    M.reconcile(seller)                                    -- 第二次 hello：不得覆寫 T0
    fire("OnTickEvenPaused")
    proofPump(user, 400)
    check(reason(user, id) == "source_state_changed" and tally(seller, "Base.CannedCorn") <= 2
        and seller.modData[KEY].pendingOuts[id] ~= nil
        and Mk.ownerCount(user) == 0 and M.unclaimed(user) == 0
        and L.conservation("survivor") == 0,
        "a second login while the same proof is still reading adds to the first observation instead of replacing it: nothing is regenerated and the obligation stays open")
end

-- ---- FR-05：消失單位的證據不得被截斷，否則被截掉的那些永遠失去反證 ----
do
    local boss, seller, id, items = rolledBackLot("p79fr05", 34, 33, true)
    local user = seller:getUsername()
    M.reconcile(seller)
    fire("OnTickEvenPaused")
    for i = 1, 33 do drop(seller, items[i]) end             -- 33 件全部移到地上
    proofPump(user, 400)
    local held = Rec.heldRecord(user, "pend:" .. id)
    assert(held ~= nil and held.reason == "source_state_changed",
        "fixture: the disappearance of 33 units must be recorded")
    -- 把「被記下來的那些」放回背包；沒被記下的那件留在地上，正是漏洞要用的那一件
    local remembered = {}
    for token in string.gmatch(tostring(held.ids or ""), "[^,]+") do remembered[token] = true end
    for i = 1, 33 do
        local it = items[i]
        local stamp = it:getModData()[KEY]
        local token = stamp and stamp.unit or ("n:" .. tostring(it:getID()))
        if remembered[token] or remembered[tostring(it:getID())] then pick(seller, it) end
    end
    M.reconcile(seller)
    proofPump(user, 400)
    check(tally(seller, "Base.CannedCorn") <= 34 and L.conservation("survivor") == 0,
        "the record of what disappeared is never truncated: returning only the units that were written down cannot conjure a thirty-fifth unit out of the ones that were not")
end

-- ---- FR-06：來源讀不出來不等於「上游持有」，不可據此 cancel 並刪掉 pending ----
do
    local boss, seller = world("p79fr06")
    local user = seller:getUsername()
    local corn = instanceItem("Base.CannedCorn")
    assert(seller.inventory:AddItem(corn) == corn)
    local saved = proofSnapshot()
    -- mail 來源的 pending：沒有 receipt、沒有 world operation，來源狀態要靠 Mailbox.entryOf 回答
    local epoch = S.modData().meta.epoch
    local opId = epoch .. ":9501"
    Rec.playerData(seller).pendingOuts[opId] = { protocol = 2, tradeSchema = 2, kind = "listing",
        origins = { { src = "mail", unit = "7000:3#1", mailId = "7000:3", owner = user,
            epoch = "7000", seq = 3 } },
        itemIds = { corn:getID() }, itemId = corn:getID(), qty = 1, lotQty = 1, price = 45,
        currency = "survivor", snapshot = { type = "Base.CannedCorn", condition = 10, uses = 1,
            age = 0, repaired = 0 }, epoch = epoch, seq = 9501, at = nowMs }
    proofRestartFrom(saved)
    onlinePlayers = { boss, seller }
    local realEntryOf = M.entryOf
    M.entryOf = function() error("mailbox entry unreadable") end
    local coinBefore = L.getBalance(user, "survivor").available
    M.reconcile(seller)
    proofPump(user, 400)
    M.entryOf = realEntryOf
    check(seller.modData[KEY].pendingOuts[opId] ~= nil and reason(user, opId) ~= nil
        and not Mk.listingExists(opId) and M.unclaimed(user) == 0
        and seller.inventory:contains(corn)
        and L.getBalance(user, "survivor").available == coinBefore
        and L.conservation("survivor") == 0,
        "a source this server could not read is not a source that is proven held upstream: the operation is held with a reason instead of being cancelled and its evidence deleted")
end

-- ---- FR-08：祖先的 unknown epoch 與舊 at 不得在取到後繼之前就否決查找 ----
do
    local boss, seller, id, items = rolledBackLot("p79fr08", 1, 0, false)
    local user = seller:getUsername()
    local ancestor = proofJournalSuccessor(user, id)
    -- 合法後繼：提交點仍判 rolledback、outAt 比祖先新
    local successor = copy(seller.modData[KEY].pendingOuts[id])   -- live 形狀，避免 wire 雙重打包
    successor.seq = tonumber(ancestor.seq) + 4
    nowMs = nowMs + 120000                               -- 後繼的 outAt 由 producer 用當下時間寫
    assert(proofJournalEmit(user, id, ancestor.epoch, tonumber(ancestor.seq) + 4, successor,
        ancestor.kind, ancestor.ref), "fixture: the successor must be written by the real producer")
    -- 玩家帶的是初始祖先：epoch 已離開 bounded history（unknown），at 也在 floor 之下
    local pend = seller.modData[KEY].pendingOuts[id]
    pend.epoch = "1"
    S.modData().recovery.floorAt = ancestor.outAt + 1
    assert(Rec.verdict("1", tonumber(pend.seq) or 0) == "unknown",
        "fixture: the ancestor the player carries must be unprovable on its own")
    M.reconcile(seller)
    proofPump(user, 400)
    local live = S.modData().market.listings[id]
    check(live ~= nil and live.price == 45 and reason(user, id) == nil
        and Mk.ownerCount(user) == 1 and tally(seller, "Base.CannedCorn") == 1
        and L.conservation("survivor") == 0,
        "an ancestor whose own epoch and timestamp are unprovable must not veto the lookup: the verdict and the retention floor are read from the successor the server actually wrote")
end

-- ---- FR-09：world operation 讀不出來不得被當成「那一定是 buyback」 ----
do
    local boss, seller = world("p79fr09")
    local user = seller:getUsername()
    local corn = instanceItem("Base.CannedCorn")
    assert(seller.inventory:AddItem(corn) == corn)
    local stale = instanceItem("Base.CannedCorn")
    assert(seller.inventory:AddItem(stale) == stale)
    local listed = cmd(seller, "market.list", { itemIds = { corn:getID() }, price = 45 })
    assert(listed.ok and proofSettle() == 0)
    local liveId = listed.listingId
    -- 世界仍持有這筆刊登，但它的 receipt 不在（pre-journal／收據被 prune 的形狀），
    -- 所以來源狀態只能靠 worldOperation 回答 —— 接著把那個讀取弄壞。
    S.modData().recovery.ops[liveId] = nil
    Rec.playerData(seller).pendingOuts[liveId] = { protocol = 2, tradeSchema = 2, kind = "listing",
        origins = { { src = "native", nativeId = stale:getID(), item = "Base.CannedCorn" } },
        itemIds = { stale:getID() }, itemId = stale:getID(), qty = 1, lotQty = 1, price = 45,
        currency = "survivor", snapshot = { type = "Base.CannedCorn", condition = 10, uses = 1,
            age = 0, repaired = 0 },
        epoch = select(1, EC.parseId(liveId)), seq = tonumber(select(2, EC.parseId(liveId))),
        at = nowMs }
    local realInfo = Mk.operationInfo
    Mk.operationInfo = function() error("operation info unreadable") end
    local coinBefore = L.getBalance(user, "survivor").available
    M.reconcile(seller)
    proofPump(user, 400)
    Mk.operationInfo = realInfo
    check(Mk.listingExists(liveId) and seller.inventory:contains(stale)
        and seller.modData[KEY].pendingOuts[liveId] ~= nil
        and reason(user, liveId) ~= nil and M.unclaimed(user) == 0
        and L.getBalance(user, "survivor").available == coinBefore
        and L.conservation("survivor") == 0,
        "a world operation this server could not read is never downgraded into the buyback assumption: the held object stays, the record stays, and nothing is cleared on an unproven business outcome")
end

-- ---- FR-10：語法合法但沒有 opId 的行，不得被靜默略過成「查無證據」或退回較舊的祖先 ----
do
    local boss, seller, id, items = rolledBackLot("p79fr10", 1, 0, false)
    local user = seller:getUsername()
    local ancestor = proofJournalSuccessor(user, id)
    local path = proofJournalPathForOp(user, id)
    files[path].lines[#files[path].lines + 1] = "{}"        -- 合法 JSON、沒有 opId
    local coinBefore = L.getBalance(user, "survivor").available
    M.reconcile(seller)
    proofPump(user, 400)
    local row = nil
    for _, r in ipairs(cmd(boss, "admin.recovery", { action = "list", username = user }).records or {}) do
        if r.opId == id then row = r end
    end
    check(reason(user, id) ~= nil and reason(user, id) ~= "journal_missing"
        and row ~= nil and row.unproven ~= true and row.actions.restore == false
        and not Mk.listingExists(id) and tally(seller, "Base.CannedCorn") == 0
        and L.getBalance(user, "survivor").available == coinBefore,
        "a syntactically valid row that cannot be identified is broken evidence, never an absence of evidence: it opens no unproven acceptance and rebuilds nothing")
end

-- ---- FR-10b：後繼行的 opId 非空但無法解析，不得被當成「別的 op」略過而退回祖先 ----
--
-- 這是 FR-10 唯一還沒閉合的那一路：`opId = "broken"` 不是空值也不是缺欄位，所以「先過濾掉
-- 不是我要的 op」那一步會把它當別人的行放過去，於是祖先被當成最後決定。envelope 驗證必須
-- 在 wanted 過濾**之前**就要求 opId 可解析（journalPath 可導出、seq 是正整數）。
-- 「完全缺 ID」那一路由上面的 {} 那格代表，不再重複鋪同型參數案例。
do
    local boss, seller, id, items = rolledBackLot("p79fr10b", 1, 0, false)
    local user = seller:getUsername()
    local ancestor = proofJournalSuccessor(user, id)
    local successor = copy(seller.modData[KEY].pendingOuts[id])   -- live 形狀，避免 wire 雙重打包
    successor.seq = tonumber(ancestor.seq) + 6
    successor.price = 77
    assert(proofJournalEmit(user, id, ancestor.epoch, tonumber(ancestor.seq) + 6, successor,
        ancestor.kind, ancestor.ref), "fixture: the successor must be written by the real producer")
    local path = proofJournalPathForOp(user, id)
    local lines = files[path].lines
    local last = EC.jsonDecode(lines[#lines])
    last.opId = "broken"                                   -- 合法 JSON、非空字串，但不是可解析的 opId
    lines[#lines] = EC.jsonEncode(last)
    M.reconcile(seller)
    proofPump(user, 400)
    local live = S.modData().market.listings[id]
    check(live == nil and reason(user, id) ~= nil and reason(user, id) ~= "journal_missing"
        and tally(seller, "Base.CannedCorn") == 0 and L.conservation("survivor") == 0,
        "a successor whose operation id cannot be parsed is not somebody else's row to skip: the read fails instead of promoting the older ancestor to newest decision")
end

-- ---- FR-11：snapshot 的 modData 必須無損 —— key 型別、帶號零、與數字精度 ----
--
-- **從 consumer 側看**：journal 的 wire 表示是 VERSION2 的 typed flat 葉子，所以這裡不讀 raw
-- 行、也不手寫解包 —— 而是讓真的 rollback → J.lookup → 重建跑完，看被重建出來的資產身上
-- 那份 snapshot。它是不是無損，只有這個出口說得準，而且這樣釘不會綁在任何表示法上。
--
-- 三件事擠在同一筆物品上（Main 交代不要另開同路徑的獨立案例）：
--   * 數字 key 0 與字串 key "0" 是兩個不同的 key，不得互相吃掉；
--   * **帶號零 -0.0**：Main 在真 Kahlua 量到 tostring/tonumber 的 BoxedStaticValues 會丟符號，
--     所以兩端已加 explicit '-0.0' 字面值。這裡不比 `== 0`（那對 +0 也成立），而是比
--     `1/zero == -math.huge` —— 那是唯一能分辨 -0.0 與 0.0 的觀察方式；
--   * **精度 0.123456789123**：14 位以內在 Lua 5.4 可精確往返，舊的 %.6f 會直接截掉。
-- 標準 Lua 只守得住表示層；真 Kahlua 的數字行為以 Main 的實測證據為準。
do
    local boss, seller = world("p79fr11")
    local user = seller:getUsername()
    local corn = instanceItem("Base.CannedCorn")
    corn.modData[0] = "numeric"
    corn.modData["0"] = "text"
    corn.modData.plain = "kept"
    corn.modData.signedZero = -0.0
    corn.modData.precision = 0.123456789123
    assert(seller.inventory:AddItem(corn) == corn)
    local saved = proofSnapshot()
    local listed = cmd(seller, "market.list", { itemIds = { corn:getID() }, price = 45 })
    assert(listed.ok and proofSettle() == 0)
    local id = listed.listingId
    proofRestartFrom(saved)
    onlinePlayers = { boss, seller }
    M.reconcile(seller)
    proofPump(user, 400)
    local live = S.modData().market.listings[id]
    local md = live and type(live.snapshot) == "table" and live.snapshot.modData or nil
    local zero = type(md) == "table" and md.signedZero or nil
    check(live ~= nil and type(md) == "table" and md.plain == "kept"
        and md[0] == "numeric" and md["0"] == "text"
        and zero == 0 and 1 / zero == -math.huge
        and md.precision == 0.123456789123,
        "an operation rebuilt from the journal carries its mod data exactly as the world held it: the two same-looking keys stay distinct, a negative zero keeps its sign, and a fourteen-digit number survives the round trip")
end

-- ---- FR-12：斷線必須把該帳號的票與 raw row 參照一起回收 ----
do
    local boss, seller, id, items = rolledBackLot("p79fr12", 2, 1, true)
    local user = seller:getUsername()
    M.reconcile(seller)
    fire("OnTickEvenPaused")
    assert(jstat(user).reading == true and Rec.hasProofTicket(user) == true,
        "fixture: a cold read must be in flight and must hold a ticket")
    onlinePlayers = { boss }                               -- 斷線
    nowMs = nowMs + (J.SWEEP_MS or 1000) + 1500
    proofPump(user, 400)
    check(Rec.hasProofTicket(user) == false and jstat(user).wanted == 0
        and jstat(user).reading ~= true
        and not Mk.listingExists(id) and M.unclaimed(user) == 0
        and L.conservation("survivor") == 0,
        "a disconnect retires the whole job: the proof ticket and its inventory row references are released instead of holding a slot nobody can ever complete")
end
onlinePlayers = {}
SandboxVars.MinidoracatEconomy.MarketListingFeePercent = nil
SandboxVars.MinidoracatEconomy.MarketMaxListings = nil
end)()

-- ===== 情境八十一：凍結當下就該看得到領不了，解凍當下就該看得到能領 =====
io.write("scenario 81: freezing an account tells that player at once, and nobody else\n")
;(function()
modDataStore[EC.MODDATA_KEY] = nil
files, sentCommands = {}, {}
SandboxVars.MinidoracatEconomy.RewardDayResetHour = 4
SandboxVars.MinidoracatEconomy.RewardTimezoneUTC = 8
SandboxVars.MinidoracatEconomy.CheckinAmount = 10
SandboxVars.MinidoracatEconomy.CheckinMinPlaytimeMinutes = 2
SandboxVars.MinidoracatEconomy.CheckinServerDailyCap = 0
SandboxVars.MinidoracatEconomy.AdminRoles = "admin"
nowMs = 1788699986478
fire("OnServerStarted")
local boss = fakePlayer("frz-admin"); boss.role = "admin"
local dan = fakePlayer("frz-dan")
local eve = fakePlayer("frz-eve")
onlinePlayers = { boss, dan, eve }
L.credit("frz-dan", "survivor", 50, "SYSTEM_MINT", { requestId = "frz-dan-seed", reasonCode = "t" })
L.credit("frz-eve", "survivor", 50, "SYSTEM_MINT", { requestId = "frz-eve-seed", reasonCode = "t" })
for _ = 1, 4 do nowMs = nowMs + 60000; fire("OnTickEvenPaused") end
local function pushedState(who)
    local found = nil
    for _, rec in ipairs(sentCommands) do
        if rec.command == "rewards.state" and rec.player == who then found = rec.args end
    end
    return found
end
local function freeze(frozen, reason)
    nowMs = nowMs + 600
    sentCommands = {}
    fire("OnClientCommand", EC.COMMAND_MODULE, "admin.freeze", boss,
        { username = "frz-dan", frozen = frozen, reason = reason, requestId = "frz-" .. tostring(frozen) .. nowMs })
    return lastSent("admin.freeze").args
end
local frozenReply = freeze(true, "frozen while an exploit report is investigated")
local frozenState = pushedState(dan)
check(frozenReply.ok == true and L.isFrozen("frz-dan") == true
    and frozenState ~= nil and frozenState.canClaim == false and frozenState.blockedReason == "account_frozen"
    and pushedState(eve) == nil,
    "a freeze reaches that player's reward page in the same breath, so the button is gone before it is pressed - and no other account is told anything at all")
local thawedReply = freeze(false, "investigation finished, account cleared")
local thawedState = pushedState(dan)
check(thawedReply.ok == true and L.isFrozen("frz-dan") == false
    and thawedState ~= nil and thawedState.canClaim == true and thawedState.blockedReason == nil
    and pushedState(eve) == nil,
    "unfreezing is just as immediate: with the playtime already earned the reward becomes claimable again without waiting for a poll, and still nobody else is pushed")
-- 離線帳號被凍結：沒有人可以推，就誰也不推，更不許替離線者先造一包
L.credit("frz-off", "survivor", 50, "SYSTEM_MINT", { requestId = "frz-off-seed", reasonCode = "t" })
nowMs = nowMs + 600
sentCommands = {}
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.freeze", boss,
    { username = "frz-off", frozen = true, reason = "freezing an account that is not connected", requestId = "frz-off-cmd" })
local offlineStates = 0
for _, rec in ipairs(sentCommands) do
    if rec.command == "rewards.state" then offlineStates = offlineStates + 1 end
end
check(lastSent("admin.freeze").args.ok == true and L.isFrozen("frz-off") == true and offlineStates == 0,
    "freezing somebody who is not connected pushes nothing to anyone: there is no state to deliver, and the other players online are not collateral for it")
SandboxVars.MinidoracatEconomy.CheckinAmount = nil
SandboxVars.MinidoracatEconomy.CheckinMinPlaytimeMinutes = nil
onlinePlayers = {}
end)()

-- ===== 情境八十二：不認得的欄位一律不寫；已成交的請求不因世界改變而改答案 =====
io.write("scenario 82: unknown fields never land, and a settled request keeps its answer when the world moves on\n")
;(function()
local M, Shop, Mk = S.Mailbox, S.Shop, S.Market
modDataStore[EC.MODDATA_KEY] = nil
files, sentCommands, writerDeny = {}, {}, {}
nowMs = nowMs + 61000
files[S.Shop.FILE] = { lines = { EC.jsonEncode({ items = {
    { id = "pack", item = "Base.Twine", qty = 1,
        prices = { survivor = { price = 20, bidPrice = 8, buyback = true } } },
} }) }, opens = 0 }
fire("OnServerStarted")
worldSprites = { ["100,200,0"] = "MinidoracatEconomy_terminal_0" }
local boss = fakePlayer("wr-admin"); boss.role = "admin"
local ann = fakePlayer("wr-ann"); ann.x, ann.y = 101, 200; ann.inventory = fakeInventory(80)
local bob = fakePlayer("wr-bob"); bob.x, bob.y = 101, 200; bob.inventory = fakeInventory(80)
onlinePlayers = { boss, ann, bob }
local function cmd(who, name, args)
    nowMs = nowMs + 600
    args = args or {}
    args.requestId = args.requestId or (name .. nowMs)
    withCurrency(name, args)
    fire("OnClientCommand", EC.COMMAND_MODULE, name, who, args)
    local s = lastSent(name)
    return s and s.args or {}
end
cmd(boss, "terminal.register", { x = 100, y = 200, z = 0, kind = "atm" })
for _, who in ipairs({ "wr-ann", "wr-bob" }) do
    L.credit(who, "survivor", 2000, "SYSTEM_MINT", { requestId = "wr-seed-" .. who, reasonCode = "t" })
    L.credit(who, "cat", 500, "SYSTEM_MINT", { requestId = "wr-seed-c-" .. who, reasonCode = "t" })
end
-- add 的三種不認得欄位：根層、quote 葉層、已退場的 flat 名，一律整份拒絕且不留半個 SKU
local diskBefore, revBefore = table.concat(files[S.Shop.FILE].lines, "\n"), Shop.revision()
local badRoot = cmd(boss, "admin.catalog", { action = "add", id = "wr_root", item = "Base.Nails", qty = 1,
    nonsense = 1, prices = { survivor = { price = 10 } } })
local badLeaf = cmd(boss, "admin.catalog", { action = "add", id = "wr_leaf", item = "Base.Nails", qty = 1,
    prices = { cat = { price = 100, nonsense = 1 }, survivor = { price = 10 } } })
local badFlat = cmd(boss, "admin.catalog", { action = "add", id = "wr_flat", item = "Base.Nails", qty = 1,
    price = 10, prices = { survivor = { price = 10 } } })
check(badRoot.error == "unknown_field" and badLeaf.error == "unknown_field" and badFlat.error == "unknown_field"
    and Shop.sku("wr_root") == nil and Shop.sku("wr_leaf") == nil and Shop.sku("wr_flat") == nil
    and Shop.revision() == revBefore and table.concat(files[S.Shop.FILE].lines, "\n") == diskBefore,
    "a field the writer does not recognise is refused wherever it sits - root, inside a quote, or an old flat name - and none of the three leaves a SKU, a revision bump or a byte behind")
-- extra.field 是機器讀的定位器，不是給人看的句子：管理頁靠解析它把對應欄位標紅。
-- 形狀變了（改成兩個欄位、或換分隔符）管理頁會安靜地標不到欄位，而那不會讓任何測試變紅。
check(badLeaf.extra ~= nil and badLeaf.extra.field == "prices.cat.nonsense" and badLeaf.extra.currency == "cat"
    and badRoot.extra ~= nil and badRoot.extra.field == "nonsense",
    "the refusal points at the offending field with a path the admin page can parse: a quote leaf is named by currency and leaf, a root field by itself")
-- 上架成功之後，世界怎麼變都不改變那個請求的答案
local rope = instanceItem("Base.Rope"); ann.inventory:AddItem(rope)
local listed = cmd(ann, "market.list", { itemIds = { rope.id }, price = 40, currency = "survivor", requestId = "wr-list" })
Cfg.setEnabled("cat", false, "wr-admin", "pause the other currency")
SandboxVars.MinidoracatEconomy.MarketPriceMax = 30
local listAgain = cmd(ann, "market.list", { itemIds = { rope.id }, price = 40, currency = "survivor", requestId = "wr-list" })
SandboxVars.MinidoracatEconomy.MarketPriceMax = nil
Cfg.setEnabled("cat", true, "wr-admin", "resume")
check(listed.ok == true and listAgain.duplicate == true and listAgain.listingId == listed.listingId
    and #Mk.mine("wr-ann") == 1,
    "a listing that already happened answers with itself even after the price range shrank under it and another currency was paused: a resend is a question about the past, not a new attempt")
-- 收購成功之後，SKU 被刪掉、目錄重載，同一個請求仍然回原來那一筆
SandboxVars.MinidoracatEconomy.ShopBuybackEnabled = true
SandboxVars.MinidoracatEconomy.ShopBuybackPerAccountDaily = 500
SandboxVars.MinidoracatEconomy.ShopBuybackServerDaily = 5000
local twine = instanceItem("Base.Twine"); bob.inventory:AddItem(twine)
-- 重送就是「同一個請求再問一次」：它帶的目錄版本必須是當初確認的那一個。
-- 換成重載後的新版本就是另一個請求，那樣測到的是指紋比對，不是重送。
local sellRev = Shop.revision()
local sold = cmd(bob, "shop.sell", { id = "pack", itemIds = { twine.id }, currency = "survivor",
    revision = sellRev, requestId = "wr-sell" })
local balAfterSale = L.getBalance("wr-bob", "survivor").available
files[S.Shop.FILE] = { lines = { EC.jsonEncode({ items = {
    { id = "other", item = "Base.Nails", qty = 1, prices = { survivor = { price = 5 } } },
} }) }, opens = 0 }
cmd(boss, "admin.catalog", { action = "reload" })
local soldAgain = cmd(bob, "shop.sell", { id = "pack", itemIds = { twine.id }, currency = "survivor",
    revision = sellRev, requestId = "wr-sell" })
check(sold.ok == true and Shop.sku("pack") == nil and soldAgain.duplicate == true
    and soldAgain.txId == sold.txId and L.getBalance("wr-bob", "survivor").available == balAfterSale,
    "a sale that already minted answers with its own transaction after the product was deleted from the catalogue: the resend mints nothing and does not become an unknown SKU")
-- 市場成交之後，同一個 requestId 換價格是衝突，不是第二次成交
local pan = instanceItem("Base.Twine"); ann.inventory:AddItem(pan)
local forSale = cmd(ann, "market.list", { itemIds = { pan.id }, price = 50, currency = "survivor", requestId = "wr-list-2" })
local bought = cmd(bob, "market.buy", { listingId = forSale.listingId, price = 50, currency = "survivor", requestId = "wr-buy" })
local bobAfter, annAfter = L.getBalance("wr-bob", "survivor").available, L.getBalance("wr-ann", "survivor").available
local lettersAfter = M.unclaimed("wr-bob")
local repriced = cmd(bob, "market.buy", { listingId = forSale.listingId, price = 70, currency = "survivor", requestId = "wr-buy" })
check(bought.ok == true and repriced.ok ~= true and repriced.error == "request_conflict"
    and repriced.price == 50
    and L.getBalance("wr-bob", "survivor").available == bobAfter
    and L.getBalance("wr-ann", "survivor").available == annAfter
    and M.unclaimed("wr-bob") == lettersAfter and L.conservation("survivor") == 0,
    "the same purchase id sent back with a different price is a conflict, never a second settlement: the reply quotes the price on record, no coin moves on either side, and no second delivery is made")
-- 確認價格是請求的一部分：沒帶價格的購買在任何東西移動之前就被擋下
local nail = instanceItem("Base.Nails"); ann.inventory:AddItem(nail)
local cheap = cmd(ann, "market.list", { itemIds = { nail.id }, price = 15, currency = "survivor", requestId = "wr-list-3" })
local bobBare, annBare = L.getBalance("wr-bob", "survivor").available, L.getBalance("wr-ann", "survivor").available
local bare = cmd(bob, "market.buy", { listingId = cheap.listingId, currency = "survivor", requestId = "wr-buy-bare" })
check(bare.ok ~= true and bare.error == "invalid_args" and Mk.listingExists(cheap.listingId)
    and L.getBalance("wr-bob", "survivor").available == bobBare
    and L.getBalance("wr-ann", "survivor").available == annBare
    and M.unclaimed("wr-bob") == lettersAfter,
    "a purchase that does not say what it expects to pay is refused before anything moves: the listing is still there and neither wallet was touched")
SandboxVars.MinidoracatEconomy.ShopBuybackEnabled = nil
SandboxVars.MinidoracatEconomy.ShopBuybackPerAccountDaily = nil
SandboxVars.MinidoracatEconomy.ShopBuybackServerDaily = nil
onlinePlayers = {}
end)()

-- ===== 情境八十三：人工出口不得留下伺服器自己讀不懂的痕跡 =====
io.write("scenario 83: what an administrator's manual exit may not leave behind\n")
;(function()
local M, Rec, Mk = S.Mailbox, S.Recovery, S.Market
local KEY = EC.PLAYER_MODDATA_KEY
local function deepCopy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = deepCopy(v) end
    return out
end
modDataStore[EC.MODDATA_KEY] = nil
files, sentCommands, writerDeny = {}, {}, {}
nowMs = nowMs + 61000
fire("OnServerStarted")
worldSprites = { ["100,200,0"] = "MinidoracatEconomy_terminal_0" }
local boss = fakePlayer("r7-admin"); boss.role = "admin"
local pat = fakePlayer("r7-pat"); pat.x, pat.y = 101, 200; pat.inventory = fakeInventory(80)
onlinePlayers = { boss, pat }
local function cmd(who, name, args)
    nowMs = nowMs + 600
    args = args or {}
    args.requestId = args.requestId or (name .. nowMs)
    withCurrency(name, args)
    fire("OnClientCommand", EC.COMMAND_MODULE, name, who, args)
    local s = lastSent(name)
    return s and s.args or {}
end
local function rowOf(reply, key)
    for _, row in ipairs(reply.records or {}) do
        if row.key == key then return row end
    end
end
cmd(boss, "terminal.register", { x = 100, y = 200, z = 0, kind = "atm" })
SandboxVars.MinidoracatEconomy.MarketListingFeePercent = 0
cmd(pat, "hello")
-- 先做一筆真的、已落盤的上架，再把世界回滾到上架之前：證據在檔案層，不隨 ModData 回滾
local saveBeforeList = deepCopy(modDataStore[EC.MODDATA_KEY])
local plank = instanceItem("Base.Plank"); pat.inventory:AddItem(plank)
local listed = cmd(pat, "market.list", { itemId = plank.id, price = 30, currency = "survivor", requestId = "r7-list" })
proofSettle()
local invAfterList, mdAfterList = deepCopy(pat.inventory.items), deepCopy(pat.modData)
modDataStore[EC.MODDATA_KEY] = saveBeforeList
nowMs = nowMs + 1000
fire("OnServerStarted")
pat.inventory.items = invAfterList; pat.modData = mdAfterList
-- 玩家那份自稱的價格和記錄對不上：證據齊全的話會自動補回去，就沒有需要人工處理的列
pat.modData[KEY].pendingOuts[listed.listingId].price = 31
cmd(pat, "hello")
proofPump("r7-pat")
local opKey = "pend:" .. listed.listingId
local row = rowOf(cmd(boss, "admin.recovery", { action = "list", username = "r7-pat" }), opKey)
local balBeforeDiscard = L.getBalance("r7-pat", "survivor").available
-- discard 之前的世界快照，以及玩家手上仍帶著那筆 pending 的存檔
local saveAtDiscard = deepCopy(modDataStore[EC.MODDATA_KEY])
local invAtDiscard, mdAtDiscard = deepCopy(pat.inventory.items), deepCopy(pat.modData)
local discarded = cmd(boss, "admin.recovery", { action = "resolve", username = "r7-pat", key = opKey,
    decision = "discard", revision = row and row.revision or "x",
    note = "discarding a claim whose numbers do not match the record" })
-- discard 是對**世界**宣告作廢，不是從某一份玩家存檔裡刪掉一行：它寫下一筆空的出場記錄，
-- 從此 hasOut 為真，帶著同一筆 pending 登入的舊存檔會讀到「已結案」而不是每次登入都復活。
check(discarded.ok == true and M.hasOut(listed.listingId) == true
    and M.unclaimed("r7-pat") == 0 and pat.inventory.count("Base.Plank") == 0
    and not Mk.listingExists(listed.listingId)
    and L.getBalance("r7-pat", "survivor").available == balBeforeDiscard,
    "an administrator who discards a claim that does not match the record closes it against the world and hands nothing back: a receipt with nothing in it, no item, no letter and no coin")
-- discard 的結案也是一筆出場記錄，要先真的落盤，否則後面讀不到那條後繼
proofSettle()
-- 世界回滾到按下 discard 之前，玩家帶著同一筆 pending 回來：檔案裡的結案還在
modDataStore[EC.MODDATA_KEY] = saveAtDiscard
nowMs = nowMs + 1000
fire("OnServerStarted")
pat.inventory.items = invAtDiscard; pat.modData = mdAtDiscard
cmd(pat, "hello")
proofPump("r7-pat")
local held = Rec.heldRecord("r7-pat", opKey)
check(held ~= nil and held.reason == "admin_discard_rolledback" and held.resolvedAt == nil
    and pat.inventory.count("Base.Plank") == 0 and M.unclaimed("r7-pat") == 0
    and not Mk.listingExists(listed.listingId)
    and L.getBalance("r7-pat", "survivor").available == balBeforeDiscard,
    "a discard the world later rolled back is recognised as a decision already taken, not as evidence the server cannot parse: the record is held for a human, and the rollback conjures back neither the plank nor the money")
-- 一個帳號手上「還算數」的同型物品：背包裡的、信箱裡還能領的、以及還掛在市場上的。
-- 只數未領信件會把「已經送進背包」的那一件藏起來，母體必須把三處都算進去。
local function holding(who, fullType)
    local total = who.inventory.count(fullType)
    for _, e in ipairs(cmd(who, "mail.list").entries or {}) do
        if e.item == fullType then total = total + (e.qty or 1) end
    end
    for _, row in ipairs(Mk.mine(who:getUsername()) or {}) do
        if row.item == fullType then total = total + (row.qty or 1) end
    end
    return total
end
-- FR-01：人工恢復要補幾件，只能由伺服器自己的記錄重判。玩家那份的缺口不是補發數量。
local saveTwo = deepCopy(modDataStore[EC.MODDATA_KEY])
local n1 = instanceItem("Base.Nails"); pat.inventory:AddItem(n1)
local n2 = instanceItem("Base.Nails"); pat.inventory:AddItem(n2)
local pair = cmd(pat, "market.list", { itemIds = { n1.id, n2.id }, price = 40, currency = "survivor", requestId = "r7-pair" })
proofSettle()
pat.inventory:AddItem(n1)          -- 玩家那份比世界新：其中一件（同一個物件）從來沒離開過背包
local invPair, mdPair = deepCopy(pat.inventory.items), deepCopy(pat.modData)
modDataStore[EC.MODDATA_KEY] = saveTwo
nowMs = nowMs + 1000
fire("OnServerStarted")
pat.inventory.items = invPair; pat.modData = mdPair
pat.modData[KEY].pendingOuts[pair.listingId].price = 41   -- 數字對不上，才會落到人工那條路
cmd(pat, "hello")
proofPump("r7-pat")
local pairKey = "pend:" .. pair.listingId
local pairRow = rowOf(cmd(boss, "admin.recovery", { action = "list", username = "r7-pat" }), pairKey)
local nailsBefore = holding(pat, "Base.Nails")
cmd(boss, "admin.recovery", { action = "resolve", username = "r7-pat", key = pairKey,
    decision = "restore", revision = pairRow and pairRow.revision or "x",
    note = "restoring the nails the record says were taken" })
check(pairRow ~= nil and nailsBefore == 1 and pairRow.presentQty == 1
    and pairRow.preview ~= nil and pairRow.preview.qty == 1
    and holding(pat, "Base.Nails") == 2,
    "when one of the two nails never left the backpack the page counts the one that is still there and offers to hand back only the one that is missing: the account ends up holding exactly the two the record says were ever taken, not three")
-- FR-08：祖先很舊、後繼還在保存期內。能不能人工處理，看的是後繼那一筆的時間。
local saveOld = deepCopy(modDataStore[EC.MODDATA_KEY])
local rope = instanceItem("Base.Rope"); pat.inventory:AddItem(rope)
local old = cmd(pat, "market.list", { itemId = rope.id, price = 20, currency = "survivor", requestId = "r7-old" })
proofSettle()
local invOld, mdOld = deepCopy(pat.inventory.items), deepCopy(pat.modData)
local ancestorAt = nowMs
nowMs = nowMs + 3456000000        -- 四十天之後才有人發現世界被回滾過
modDataStore[EC.MODDATA_KEY] = saveOld
fire("OnServerStarted")
pat.inventory.items = deepCopy(invOld); pat.modData = deepCopy(mdOld)
cmd(pat, "hello")
proofPump("r7-pat")               -- 證據完整：這一輪合法重建，並寫下一筆新的結案
proofSettle()
local successor = proofJournalSuccessor("r7-pat", old.listingId)
modDataStore[EC.MODDATA_KEY] = saveOld
nowMs = nowMs + 1000
fire("OnServerStarted")
S.modData().recovery.floorAt = ancestorAt + 1728000000   -- 地板落在祖先之後、後繼之前
pat.inventory.items = deepCopy(invOld); pat.modData = deepCopy(mdOld)
cmd(pat, "hello")
proofPump("r7-pat")
local oldKey = "pend:" .. old.listingId
-- 證據完整又沒被竄改的作業不會停在管理頁上等人 —— 它就該被這一輪的 reconcile 自己收掉。
-- 所以這一格要看的是「有沒有被收掉」：地板抬到祖先之後、後繼之前時，作業仍然辦得完，
-- 而不是因為祖先太舊被當成已遺忘、留下一筆誰也處理不了的滯留紀錄。
local oldHeld = Rec.heldRecord("r7-pat", oldKey)
check(successor ~= nil and (oldHeld == nil or oldHeld.resolvedAt ~= nil)
    and pat.inventory.count("Base.Rope") == 0 and holding(pat, "Base.Rope") == 1,
    "a chain whose latest entry is still well inside the retention window is still workable: the rope comes back exactly once instead of being written off as forgotten because the operation started long ago")
-- FR-02：人工採用了記錄的說法之後，玩家把更舊的存檔帶回來，不能讓來源那封信再投一次
local kim = fakePlayer("r7-kim"); kim.x, kim.y = 101, 200; kim.inventory = fakeInventory(80)
onlinePlayers = { boss, pat, kim }
L.credit("r7-kim", "survivor", 500, "SYSTEM_MINT", { requestId = "r7-kim-seed", reasonCode = "t" })
cmd(kim, "hello")
local hammer = instanceItem("Base.Hammer"); pat.inventory:AddItem(hammer)
local forKim = cmd(pat, "market.list", { itemId = hammer.id, price = 10, currency = "survivor", requestId = "r7-kim-list" })
-- 買在終端旁邊會直接送進背包（deliveredQty=1，信件同時成立並消耗），所以這裡沒有第二次
-- 領取可言：「來源被用掉之前」的那份玩家存檔必須取在**買之前**。
local beforePurchase = deepCopy(kim.modData)
local bought = cmd(kim, "market.buy", { listingId = forKim.listingId, price = 10, currency = "survivor", requestId = "r7-kim-buy" })
local saveBeforeRelist = deepCopy(modDataStore[EC.MODDATA_KEY])
local hammerId = nil
for _, it in ipairs(kim.inventory.items) do if it.fullType == "Base.Hammer" then hammerId = it.id end end
local relist = cmd(kim, "market.list", { itemId = hammerId, price = 12, currency = "survivor", requestId = "r7-kim-relist" })
proofSettle()
local invK, mdK = deepCopy(kim.inventory.items), deepCopy(kim.modData)
modDataStore[EC.MODDATA_KEY] = saveBeforeRelist
nowMs = nowMs + 1000
fire("OnServerStarted")
kim.inventory.items = invK; kim.modData = mdK
kim.modData[KEY].pendingOuts[relist.listingId].price = 13
cmd(kim, "hello")
proofPump("r7-kim")
local kimKey = "pend:" .. relist.listingId
local kimRow = rowOf(cmd(boss, "admin.recovery", { action = "list", username = "r7-kim" }), kimKey)
local returned = cmd(boss, "admin.recovery", { action = "resolve", username = "r7-kim", key = kimKey,
    decision = "restore", revision = kimRow and kimRow.revision or "x",
    note = "returning the hammer on the line the server wrote at the commit point" })
proofSettle()
check(bought.ok == true and bought.mailId ~= nil and kimRow ~= nil
    and holding(kim, "Base.Hammer") <= 1,
    "a hammer that was bought, delivered and then listed again comes back exactly once when an administrator settles it from the record")
local kimUnclaimed, kimHammers = M.unclaimed("r7-kim"), holding(kim, "Base.Hammer")
kim.modData = beforePurchase       -- 玩家帶著「來源還沒被用掉」的那份存檔回來
cmd(kim, "hello")
proofPump("r7-kim")
check(M.unclaimed("r7-kim") <= kimUnclaimed and holding(kim, "Base.Hammer") <= kimHammers
    and holding(kim, "Base.Hammer") <= 1,
    "an older copy of the player's own save cannot make the source letter deliver a second time: the letter was spent once and the account still holds exactly the one hammer it bought")
SandboxVars.MinidoracatEconomy.MarketListingFeePercent = nil
onlinePlayers = {}
end)()
-- ===== 情境八十四：成交信說得出貨是跟誰買的，沒有第三方就不編一個 =====
--
-- 來源人只能由伺服器自己手上的成交資料寫入：市場那筆讀 listing 的 seller，拍賣那筆讀
-- auction 的 seller，兩者都在該筆記錄被移除的同一 tick 內寫進信件。信件是世界狀態，所以
-- 存檔重載、部分領取拆信之後都還要在；商店、退件與這個欄位出現以前的舊信則一律沒有來源人，
-- 不得從已經消失的 listing 或歷史檔回填一個出來。
io.write("scenario 84: a letter from a real trade names the account it came from\n")
;(function()
local M = S.Mailbox
modDataStore[EC.MODDATA_KEY] = nil
files, sentCommands = {}, {}
nowMs = nowMs + 61000
fire("OnServerStarted")
worldSprites = { ["100,200,0"] = "MinidoracatEconomy_terminal_0" }
SandboxVars.MinidoracatEconomy.MarketListingFeePercent = 0
SandboxVars.MinidoracatEconomy.MarketSalesTaxPercent = 0
local boss = fakePlayer("s84-boss"); boss.role = "admin"
local sel = fakePlayer("s84-sel"); sel.x, sel.y = 101, 200; sel.inventory = fakeInventory(80)
local win = fakePlayer("s84-win"); win.x, win.y = 101, 201; win.inventory = fakeInventory(80)
onlinePlayers = { boss, sel, win }
local function cmd(who, name, args)
    nowMs = nowMs + 600
    args = args or {}
    args.requestId = args.requestId or (name .. nowMs)
    withCurrency(name, args)
    fire("OnClientCommand", EC.COMMAND_MODULE, name, who, args)
    local s = lastSent(name)
    return s and s.args or {}
end
-- 一律走真的 mail.list 回覆，不讀伺服器內部表：玩家看得到的就是這一份
local function rowOf(who, id)
    for _, e in ipairs(cmd(who, "mail.list").entries or {}) do
        if e.id == id then return e end
    end
end
local function rowKind(who, kind)
    local found = nil
    for _, e in ipairs(cmd(who, "mail.list").entries or {}) do
        if e.kind == kind then found = e end
    end
    return found
end
cmd(boss, "terminal.register", { x = 100, y = 200, z = 0, kind = "atm" })
L.credit("s84-win", "survivor", 500, "SYSTEM_MINT", { requestId = "s84-seed", reasonCode = "t" })
-- 買方背包塞不下，明示收進信箱：這封信留在列表上，而且說得出貨是跟誰買的
local p1 = instanceItem("Base.Plank"); sel.inventory:AddItem(p1)
local p2 = instanceItem("Base.Plank"); sel.inventory:AddItem(p2)
local listed = cmd(sel, "market.list", { itemIds = { p1.id, p2.id }, price = 10 })
win.inventory.maxWeight = 0
local bought = cmd(win, "market.buy", { listingId = listed.listingId, price = 10, acceptMail = true })
win.inventory.maxWeight = 80
local mailed = rowOf(win, bought.mailId)
check(bought.ok == true and bought.mailed == true and mailed ~= nil and mailed.kind == "market"
    and mailed.qty == 2 and mailed.seller == "s84-sel",
    "a market purchase parked in the mailbox lists the account it was bought from")
-- 世界存檔重載：來源人跟著信件留在世界狀態裡，不是回覆裡的一次性欄位
nowMs = nowMs + 1000
fire("OnServerStarted")
check((rowOf(win, bought.mailId) or {}).seller == "s84-sel",
    "the letter still names that account after the world is saved and loaded again")
-- 部分領取：伺服器真的確認到手的那一件成為自己的子信，母信留下其餘的一件，兩邊都帶著來源人
local realPacket = sendAddItemsToContainer
local realRemove = win.inventory.Remove
local removals = 0
win.inventory.Remove = function(self, it)
    removals = removals + 1
    if removals == 1 then error("cannot take that one back") end
    realRemove(self, it)
end
sendAddItemsToContainer = function() error("packet blew up after every item landed") end
local part = cmd(win, "mail.claim", { mailId = bought.mailId })
win.inventory.Remove, sendAddItemsToContainer = realRemove, realPacket
local childEntry = type(part.childMailId) == "string" and M.entryOf("s84-win", part.childMailId) or nil
check(part.error == "delivery_partial" and childEntry ~= nil and childEntry.seller == "s84-sel"
    and (rowOf(win, bought.mailId) or {}).seller == "s84-sel",
    "a split carries the seller into the delivered child and keeps it on the remainder")
-- 拍賣結算時得標者不在終端旁：信件留在信箱，一樣說得出是跟誰標來的
local saw = instanceItem("Base.Saw"); sel.inventory:AddItem(saw)
local created = cmd(sel, "auction.create", { itemId = saw.id, startPrice = 10, hours = 6 })
cmd(win, "auction.bid", { auctionId = created.auctionId, amount = 10 })
win.x = 150
nowMs = nowMs + 6 * 3600000 + 60000
fire("OnTickEvenPaused")
win.x = 101
local won = rowKind(win, "auction")
check(created.ok == true and won ~= nil and won.item == "Base.Saw" and won.seller == "s84-sel",
    "an auction won away from a terminal waits in the mailbox naming the account it was won from")
-- 自己的刊登退回來不是跟誰買的：不得無中生有一個來源人
local rope = instanceItem("Base.Rope"); sel.inventory:AddItem(rope)
local own = cmd(sel, "market.list", { itemId = rope.id, price = 10 })
sel.inventory.maxWeight = 0
local cancelled = cmd(sel, "market.cancel", { listingId = own.listingId })
sel.inventory.maxWeight = 80
local back = rowKind(sel, "return")
check(cancelled.ok == true and back ~= nil and back.item == "Base.Rope" and back.seller == nil,
    "a listing that comes back to its own owner names no third party at all")
-- 這個欄位出現以前寫下的市場成交信沒有來源人：照樣看得到、照樣領得走，也不會長出一個
local legacy = M.add("s84-win", { kind = "market", item = "Base.Bandage", qty = 1, txId = "s84-legacy" })
local legacyRow = rowOf(win, legacy.id)
local claimed = cmd(win, "mail.claim", { mailId = legacy.id })
check(legacyRow ~= nil and legacyRow.seller == nil and claimed.ok == true
    and win.inventory.count("Base.Bandage") == 1,
    "a letter written before the field has none, is listed all the same and is still handed over")
SandboxVars.MinidoracatEconomy.MarketListingFeePercent = nil
SandboxVars.MinidoracatEconomy.MarketSalesTaxPercent = nil
onlinePlayers = {}
end)()

-- ===== 情境八十五：換季不是經濟管理員按得動的按鈕 =====
-- 換季會把全服的成績封存、讓下一季從 0 開始，所以它要的不是經濟寫入權，而是原生的角色編輯
-- 權（跟改「誰是管理員」同一張票）。每一條拒絕都要證明「零換季」，不是只看 error 字串；
-- 同一個 requestId 重送最多只換一季，超時重送不得多轉一季。
io.write("scenario 85: rotating a season takes the native role capability, and one request rotates once\n")
;(function()
local Se = S.Seasons
modDataStore[EC.MODDATA_KEY] = nil
files, sentCommands = {}, {}
SandboxVars.MinidoracatEconomy.AdminRoles = "admin;gm"
SandboxVars.MinidoracatEconomy.ReadOnlyRoles = "moderator"
nowMs = nowMs + 1000
fire("OnServerStarted")
local boss = fakePlayer("s85-boss"); boss.role = "admin"
local gm = fakePlayer("s85-gm"); gm.role = "gm"             -- AdminRoles 裡，但沒有原生角色權
local mod = fakePlayer("s85-mod"); mod.role = "moderator"   -- 只讀角色
local joe = fakePlayer("s85-joe")
onlinePlayers = { boss, gm, mod, joe }
local serial = 0
local function cmd(who, args)
    serial, nowMs = serial + 1, nowMs + 600
    args.requestId = args.requestId or ("s85-" .. serial)
    fire("OnClientCommand", EC.COMMAND_MODULE, "admin.seasons", who, args)
    local sent = lastSent("admin.seasons")
    return sent and sent.args or {}
end
local first = Se.currentId()
local listed = cmd(mod, { action = "list" })
check(listed.ok == true and listed.action == "list" and listed.perms.read == true
    and listed.perms.manage ~= true and type(listed.seasonState) == "table"
    and listed.seasonState.currentId == first,
    "a read-only role may look at the seasons: the list carries the state and says plainly that this caller may not rotate them")
local modStart = cmd(mod, { action = "start", expectedSeason = first, reason = "let me" })
local gmStart = cmd(gm, { action = "start", expectedSeason = first, reason = "let me" })
check(modStart.error == "manage_settings_required" and gmStart.error == "manage_settings_required"
    and gmStart.perms.write == true and gmStart.perms.manage ~= true and Se.currentId() == first,
    "neither the read-only role nor the economy write role rotates a season: the reply says write-but-not-manage and the running season is untouched")
local outsider = cmd(joe, { action = "start", expectedSeason = first, reason = "let me" })
check(outsider.error == "forbidden" and outsider.seasonState == nil and Se.currentId() == first,
    "a player who is not past the admin read gate is not even told which seasons exist")
local noReason = cmd(boss, { action = "start", expectedSeason = first, reason = "   " })
local noExpect = cmd(boss, { action = "start", reason = "no expectation at all" })
local nonsense = cmd(boss, { action = "burn-it-down", reason = "why not" })
check(noReason.error == "reason_blank" and noExpect.error == "invalid_args"
    and nonsense.error == "invalid_args" and nonsense.action == nil and Se.currentId() == first,
    "a blank reason, a missing expectation and an action nobody implements are each refused before anything rotates")
local stale = cmd(boss, { action = "start", expectedSeason = EC.makeId("1", 1), reason = "racing the schedule" })
check(stale.error == "season_changed" and stale.seasonState.currentId == first and Se.currentId() == first,
    "an administrator who was looking at another season is refused instead of rotating the one nobody asked about")
local rotated = cmd(boss, { action = "start", expectedSeason = first, reason = "scheduled rotation", requestId = "s85-rotate" })
local second = Se.currentId()
local resent = cmd(boss, { action = "start", expectedSeason = first, reason = "scheduled rotation", requestId = "s85-rotate" })
check(rotated.ok == true and second ~= first and resent.duplicate == true
    and Se.currentId() == second,
    "the rotation happens once: resending the same request is reported as a duplicate and never costs a second season")
local history = rotated.seasonState.seasons
check(#history >= 2 and history[1].id == second and history[2].id == first
    and history[2].endedAt ~= nil and history[1].endedAt == nil
    and history[2].number + 1 == history[1].number and history[1].actor == nil and history[1].reason == nil,
    "the reply carries the history newest first: the season that just closed has an end and the new one has a number, and neither of them names who pressed the button")
-- 「讀不出來」與「還沒起來」是兩件不同的事故，頁面要照原樣轉述：損毀的資料叫人去看檔，
-- 模組還沒初始化叫人等；把前者講成後者，等於叫管理員什麼都不要做。
local realState = Se.state
Se.state = function() return nil, "data_unreadable" end
local broken = cmd(mod, { action = "list" })
Se.state = function() return nil, "not_ready" end
local early = cmd(mod, { action = "list" })
Se.state = realState
check(broken.ok ~= true and broken.error == "data_unreadable" and broken.seasonState == nil
    and broken.perms.read == true,
    "a season page whose data cannot be read is told exactly that: an ok reply with nothing attached would read as a server that never had one")
check(early.ok ~= true and early.error == "not_ready" and early.seasonState == nil,
    "and a season module that has not come up yet is reported as not ready, which is a different instruction to whoever is looking")
onlinePlayers = {}
end)()

-- ===== 情境八十六：生存榜只說本季活多久，不說別的 =====
-- 公開榜是「對所有人的一句話」：同分同名次、全部排序後才分頁、沒有紀錄就是沒有紀錄（不是 0），
-- 讀不出來就明講。封存過的季不得被之後的生存資料改寫；金額隱私開關與生存時間無關。
io.write("scenario 86: the survival board ranks this season's longest lives and says nothing else\n")
;(function()
local Se = S.Seasons
modDataStore[EC.MODDATA_KEY] = nil
files, sentCommands = {}, {}
nowMs = nowMs + 1000
fire("OnServerStarted")
local ann = fakePlayer("s86-ann")
local bob = fakePlayer("s86-bob")
local cid = fakePlayer("s86-cid")
local out = fakePlayer("s86-out")
onlinePlayers = { ann, bob, cid }
local serial = 0
local function cmd(who, args)
    serial, nowMs = serial + 1, nowMs + 600
    args.requestId = args.requestId or ("s86-" .. serial)
    fire("OnClientCommand", EC.COMMAND_MODULE, "leaderboard", who, args)
    local sent = lastSent("leaderboard")
    return sent and sent.args or {}
end
local function tick()
    nowMs = nowMs + 60000
    for _, p in ipairs(onlinePlayers) do p.x = p.x + 1 end
    fire("OnTickEvenPaused")
end
tick()                                       -- 本季第一次看到這三個人
ann.hours, bob.hours, cid.hours = 10, 4, 4   -- bob 與 cid 同分
tick()
local board = cmd(ann, { kind = "survival", page = 1 })
local e = board.entries or {}
check(board.ok == true and board.kind == "survival" and board.season == "current" and #e == 3
    and e[1].username == "s86-ann" and e[1].rank == 1
    and e[2].username == "s86-bob" and e[2].rank == 2 and e[3].username == "s86-cid" and e[3].rank == 2
    and e[2].survivalMinutes == e[3].survivalMinutes
    and e[1].survivalMinutes > e[2].survivalMinutes
    and e[1].survivalMinutes == math.floor(e[1].survivalMinutes),
    "the board ranks this season's longest lives in whole minutes, and two identical times share a rank instead of being put in an order the server invented")
local leaked = nil
for _, r in ipairs(e) do
    for key in pairs(r) do
        if key ~= "rank" and key ~= "username" and key ~= "survivalMinutes" then leaked = key end
    end
end
check(leaked == nil and board.self.rank == 1 and board.self.survivalMinutes == e[1].survivalMinutes
    and board.self.currentMinutes ~= nil and board.selectedSeason.id == Se.currentId()
    and board.seasonState.currentId == Se.currentId() and board.showAmounts == nil,
    "a survival row is a rank, a name and a time - no balance, no freeze, no session - and the reply names the season it is about")
onlinePlayers = { ann, bob, cid, out }
local stranger = cmd(out, { kind = "survival" })
check(stranger.ok == true and #(stranger.entries or {}) == 3 and stranger.self ~= nil
    and stranger.self.survivalMinutes == nil and stranger.self.rank == nil
    and stranger.self.currentMinutes == nil and S.modData().claims["s86-out"] == nil,
    "a player with nothing recorded is not a zero on the board: their own line is empty and asking created nothing")
local noKind = cmd(ann, {})
local bogus = cmd(ann, { kind = "money" })
check(noKind.error == "invalid_args" and noKind.kind == nil and noKind.entries == nil
    and bogus.error == "invalid_args",
    "there is no default board: a request that does not say which ranking it wants is refused instead of answered with the other one")
local unknown = cmd(ann, { kind = "survival", season = "season-that-never-ran" })
check(unknown.ok == false and unknown.error == "unknown_season" and unknown.entries == nil
    and unknown.total == nil,
    "a season nobody ever ran is answered as unknown, never as an empty board")
local far = cmd(ann, { kind = "survival", page = 99 })
check(far.ok == true and far.page == far.pages and far.page == 1 and #(far.entries or {}) == 3,
    "a page past the end is answered with the last page that exists, not with nothing")
SandboxVars.MinidoracatEconomy.LeaderboardShowAmounts = true
local shown = cmd(ann, { kind = "survival" })
local money = cmd(ann, { kind = "wealth", currency = "survivor" })
SandboxVars.MinidoracatEconomy.LeaderboardShowAmounts = nil
check(((shown.entries or {})[1] or {}).amount == nil and shown.showAmounts == nil
    and money.kind == "wealth" and money.showAmounts == true,
    "the switch that publishes other people's money has nothing to say about how long they survived")
SandboxVars.MinidoracatEconomy.LeaderboardEnabled = false
local offSurvival = cmd(ann, { kind = "survival" })
local offWealth = cmd(ann, { kind = "wealth", currency = "survivor" })
SandboxVars.MinidoracatEconomy.LeaderboardEnabled = nil
check(offSurvival.error == "leaderboard_disabled" and offWealth.error == "leaderboard_disabled"
    and offSurvival.entries == nil and offSurvival.seasonState == nil,
    "the server-wide off switch covers both boards, and a switched-off board reads no data at all")
-- 封存不可改寫：換季之後再活一百小時，改變的是新季的榜，不是已經結束的那一季
local annBest = e[1].survivalMinutes
local closed = Se.currentId()
Se.start(closed, "s86-rot", "s85-boss", "close the season", nowMs)
ann.hours = ann.hours + 100
tick(); tick()
local archived = cmd(ann, { kind = "survival", season = closed })
local running = cmd(ann, { kind = "survival", season = "current" })
check(archived.ok == true and archived.season == closed and archived.selectedSeason.id == closed
    and archived.selectedSeason.endedAt ~= nil and archived.total == 3
    and archived.entries[1].survivalMinutes == annBest and archived.self.currentMinutes == nil
    and running.selectedSeason.id ~= closed,
    "a closed season keeps the figures it closed with: living another hundred hours moves the running board and never the archived one")
-- 讀不出來的不是空榜（只換掉季模組的讀取答案，受測的是公開榜怎麼處理）：壞掉的紀錄、
-- 不是時間的時間，以及連「現在是哪一季」都答不出來，三種都不得包成一份 ok 的名次。
local realRecords, realState = Se.records, Se.state
Se.records = function() return nil, nil, "data_unreadable" end
local broken = cmd(ann, { kind = "survival" })
Se.records = function() return { ["s86-ann"] = "not a number" }, { id = Se.currentId(), number = 2 } end
local rotten = cmd(ann, { kind = "survival" })
Se.records = realRecords
Se.state = function() return nil, "data_unreadable" end
local stateless = cmd(ann, { kind = "survival" })
Se.state = realState
check(broken.ok == false and broken.error == "data_unreadable" and broken.entries == nil
    and rotten.ok == false and rotten.error == "data_unreadable" and rotten.total == nil
    and stateless.ok ~= true and stateless.seasonState == nil and stateless.entries == nil,
    "a record the server cannot read, a time that is not a time, and a season list it cannot read at all are refused outright instead of published as a ranking with a hole in it")
onlinePlayers = {}
end)()

-- ===== 情境八十七：本季生存是伺服器自己看到的，不是別人說的 =====
-- 獎勵快照與查帳都要分得清「這個角色一生的時數」與「本季這條命活了多久」；查詢不得建立資料；
-- 而兩個引擎事實必須擋住：OnNewGame 會為一個從沒進線上名單的孤兒實例觸發（那不是新生命），
-- 屍體的時數還會繼續往上跑（那不是還在活的命）。
io.write("scenario 87: the season's hours are what the server saw, not what anything else claims\n")
;(function()
local Se = S.Seasons
modDataStore[EC.MODDATA_KEY] = nil
files, sentCommands = {}, {}
nowMs = nowMs + 1000
fire("OnServerStarted")
local boss = fakePlayer("s87-boss"); boss.role = "admin"
local zed = fakePlayer("s87-zed")
onlinePlayers = { boss, zed }
local function tick()
    nowMs = nowMs + 60000
    for _, p in ipairs(onlinePlayers) do p.x = p.x + 1 end
    fire("OnTickEvenPaused")
end
tick()
zed.hours = 30
tick()
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "rewards.state", zed, {})
local st = lastSent("rewards.state").args
check(st.survivalKnown == true and type(st.survivalHours) == "number"
    and type(st.bestSurvivalHours) == "number" and st.season == Se.currentId()
    and type(st.seasonNumber) == "number" and st.seasonNumber >= 1,
    "the reward snapshot carries the season's own figures: the number a page shows, the life being lived and the best this account managed")
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.lookup", boss, { username = "s87-zed" })
local look = lastSent("admin.lookup").args
check(look.hoursSurvived == 30 and type(look.rewards.survivalHours) == "number"
    and look.rewards.survivalHours <= look.hoursSurvived
    and look.rewards.seasonNumber == st.seasonNumber and look.rewards.survivalKnown == true,
    "the lookup keeps the character's lifetime total and this season's hours apart instead of printing one of them twice")
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.lookup", boss, { username = "s87-nobody" })
local none = lastSent("admin.lookup").args
check(S.modData().claims["s87-nobody"] == nil and none.rewards.survivalKnown == false
    and none.rewards.survivalHours == nil and none.rewards.bestSurvivalHours == nil,
    "looking a stranger up creates no record and reports their season as unknown rather than as zero")
-- 孤兒 OnNewGame：同一個帳號的另一個實例，從來沒有進過線上名單
local best = Se.progress("s87-zed").bestHours
local paid = L.getBalance("s87-zed", "survivor").available
local twin = fakePlayer("s87-zed"); twin.hours = 0
fire("OnNewGame", twin, nil)
tick()
check(Se.progress("s87-zed").bestHours == best and Se.progress("s87-zed").known == true,
    "an OnNewGame for an instance that never joined the online list proves nothing: this season's best is not thrown away by it")
-- 屍體的時數還在往上跑
zed.dead = true
zed.hours = zed.hours + 24 * 10
tick(); tick()
check(L.getBalance("s87-zed", "survivor").available == paid
    and Se.progress("s87-zed").bestHours == best,
    "a dead character whose lifetime counter keeps climbing earns nothing more: the season stops at the life that ended")
nowMs = nowMs + 1000
fire("OnServerStarted")
check(Se.currentId() == st.season and Se.progress("s87-zed").bestHours == best,
    "a restart loses neither the running season nor the times recorded in it")
onlinePlayers = {}
end)()

-- ===== 情境八十八：賽季走現實日曆，封存過的季是定稿 =====
-- 賽季期限是牆上的時鐘，生存時間是遊戲小時：把遊戲時數加速一萬倍也換不了季，現實日子到了
-- 才換。停服跨過好幾個期限，回來只補開一季（不是把錯過的季一口氣跑完，也不是造一堆空季），
-- 而且那一季從回來的時刻起算自己的天數。設定改長改短都只對「下一季」有效。
io.write("scenario 88: a season ends on the real calendar, and a closed one is a finished record\n")
;(function()
local Se = S.Seasons
local DAY = 86400000
modDataStore[EC.MODDATA_KEY] = nil
files, sentCommands = {}, {}
SandboxVars.MinidoracatEconomy.SeasonDays = 2
nowMs = nowMs + 1000
fire("OnServerStarted")
local ann = fakePlayer("s88-ann")
local bob = fakePlayer("s88-bob")
onlinePlayers = { ann, bob }
local function tick()
    nowMs = nowMs + 60000
    fire("OnTickEvenPaused")
end
local first = Se.state()
check(first ~= nil and first.configuredDays == 2 and first.seasons[1].durationDays == 2
    and first.seasons[1].endsAt == first.seasons[1].startedAt + 2 * DAY
    and first.seasons[1].partial == true and #first.seasons == 1,
    "a season opened while two real days are configured carries that deadline, and the very first one recorded is marked partial")
tick()                                       -- 本季第一次看到這兩個人
ann.hours, bob.hours = 5000, 20
for _ = 1, 5 do tick() end
check(Se.currentId() == first.currentId and #Se.state().seasons == 1
    and Se.progress("s88-ann").bestHours == 5000,
    "five thousand game hours inside a few real minutes do not end the season: the deadline is wall clock, the survival time is game hours")
-- 停服跨過好幾個期限
local closedId = Se.currentId()
nowMs = nowMs + 10 * DAY
fire("OnServerStarted")
tick()
local afterDown = Se.state()
check(#afterDown.seasons == 2 and afterDown.currentId ~= closedId
    and afterDown.seasons[2].id == closedId and afterDown.seasons[2].endedAt ~= nil
    and afterDown.seasons[1].number == afterDown.seasons[2].number + 1
    and afterDown.seasons[1].endsAt == afterDown.seasons[1].startedAt + 2 * DAY,
    "a shutdown spanning several deadlines opens exactly one season when the server comes back, and that season starts its own two days then")
-- 封存的一季是定稿：新季怎麼活、誰又進來都不動它
local archived, archivedMeta = Se.records(closedId)
local annClosed = archived and archived["s88-ann"] or nil
ann.hours = ann.hours + 300
local cid = fakePlayer("s88-cid"); cid.hours = 7
onlinePlayers = { ann, bob, cid }
for _ = 1, 3 do tick() end
local again, againMeta = Se.records(closedId)
check(annClosed ~= nil and again ~= nil and again["s88-ann"] == annClosed
    and again["s88-cid"] == nil and Se.records("current")["s88-ann"] ~= annClosed
    and againMeta.participants == archivedMeta.participants
    and againMeta.endedAt == archivedMeta.endedAt,
    "the closed season keeps its own figures and its own head count while the running one moves on")
archived["s88-ann"] = 999999
check(Se.records(closedId)["s88-ann"] == annClosed,
    "the map a reader is handed is that reader's own copy: editing it cannot rewrite the archived season")
-- 設定改長：檔案自己被改動不會憑空搬動任何期限（沒有人從設定頁寫進來），但重開之後正在跑
-- 的這一季就按它自己的開始時間重算期限，而且那個期限是真的期限。
local running = Se.state().seasons[1]
SandboxVars.MinidoracatEconomy.SeasonDays = 30
tick()
local untouched = Se.state()
check(untouched.configuredDays == 30 and untouched.seasons[1].id == running.id
    and untouched.seasons[1].durationDays == 2 and untouched.seasons[1].endsAt == running.endsAt,
    "editing the sandbox file itself moves no deadline on its own: nothing was written through the option path, so the running season still carries the two days it was told about")
nowMs = nowMs + 1000
fire("OnServerStarted")
local aligned = Se.state()
check(aligned.currentId == running.id and #aligned.seasons == 2
    and aligned.seasons[1].number == running.number
    and aligned.seasons[1].startedAt == running.startedAt
    and aligned.seasons[1].participants == running.participants
    and aligned.seasons[1].durationDays == 30
    and aligned.seasons[1].endsAt == running.startedAt + 30 * DAY
    and aligned.seasons[2].id == closedId and aligned.seasons[2].durationDays == 2,
    "the restart applies the stored length to the season already running: same season, same start, same head count, a deadline recomputed from that start, and the closed one untouched")
nowMs = aligned.seasons[1].endsAt + 1
fire("OnTickEvenPaused")
local grown = Se.state()
check(grown.currentId ~= running.id and #grown.seasons == 3
    and grown.seasons[2].id == running.id
    and grown.seasons[2].durationDays == 30
    and grown.seasons[2].endsAt == aligned.seasons[1].endsAt
    and grown.seasons[2].endedAt >= aligned.seasons[1].endsAt
    and grown.seasons[1].durationDays == 30
    and grown.seasons[1].endsAt == grown.seasons[1].startedAt + 30 * DAY,
    "the deadline it was given is a real one: reaching it closes that season once, with the length it actually ran on, and opens exactly one more")
SandboxVars.MinidoracatEconomy.SeasonDays = nil
onlinePlayers = {}
end)()

-- ===== 情境八十九：什麼算「同一條命」：槽位、重連、較舊的存檔與一具屍體 =====
-- 伺服器按 getPlayerNum() 分槽讀自己那份時數：每個槽各有基準，帳號成績取單槽最大值而不是
-- 相加。重連是同一個槽接續，不是重新出生；比基準還舊的存檔快照不是新命；屍體只收一次尾。
io.write("scenario 89: what counts as one life: slots, reconnects, an older save and a body\n")
;(function()
local Se = S.Seasons
modDataStore[EC.MODDATA_KEY] = nil
files, sentCommands = {}, {}
nowMs = nowMs + 1000
fire("OnServerStarted")
local function tick()
    nowMs = nowMs + 60000
    fire("OnTickEvenPaused")
end
local zoe = fakePlayer("s89-zoe"); zoe.hours = 50
onlinePlayers = { zoe }
tick()
local opened = Se.progress("s89-zoe")
check(opened.known == true and opened.currentHours == 0 and opened.bestHours == 0,
    "the first sample of an account whose character already carries fifty hours starts this season's life at zero, not at fifty")
zoe.hours = 60
tick()
check(Se.progress("s89-zoe").currentHours == 10 and Se.progress("s89-zoe").bestHours == 10,
    "ten more hours on the same instance are ten hours of this life")
onlinePlayers = {}
tick(); tick()                               -- 離線久到追蹤表被清掉
local back = fakePlayer("s89-zoe"); back.hours = 75
onlinePlayers = { back }
tick()
check(Se.progress("s89-zoe").currentHours == 25 and Se.progress("s89-zoe").bestHours == 25,
    "a reconnect on the same slot keeps the base it was anchored with: the life carries on instead of restarting at zero")
local split = fakePlayer("s89-zoe"); split.hours = 4; split.playerNum = 1
onlinePlayers = { split }
tick()
local afterSplit = Se.progress("s89-zoe")
split.hours = 9
tick()
local grown = Se.progress("s89-zoe")
check(afterSplit.currentHours == 0 and afterSplit.bestHours == 25
    and grown.currentHours == 5 and grown.bestHours == 25,
    "a second slot on the same account is a second life with its own base: its five hours are never added to the twenty-five the first slot recorded")
split.hours = 40
tick()
onlinePlayers = { back }
tick()
local mixed = Se.progress("s89-zoe")
check(mixed.bestHours == 36 and mixed.currentHours == 25,
    "the account's best is the longest single life on one slot, never the sum, and the first slot still finds its own base waiting")
local older = fakePlayer("s89-zoe"); older.hours = 20
onlinePlayers = { older }
tick()
local rewound = Se.progress("s89-zoe")
check(rewound.currentHours == 0 and rewound.bestHours == 36,
    "a character that comes back with fewer hours than its base is not a fresh life worth twenty hours: this life reads zero and the season's best is kept")
local dying = fakePlayer("s89-dan"); dying.hours = 100
onlinePlayers = { dying }
tick()
dying.hours = 107
dying.dead = true
fire("OnCharacterDeath", dying)
local atDeath = Se.progress("s89-dan")
dying.hours = 400
fire("OnCharacterDeath", dying)                -- 同一具屍體的第二次事件
tick(); tick()
check(atDeath.bestHours == 7 and Se.progress("s89-dan").bestHours == 7
    and Se.progress("s89-dan").currentHours == 7,
    "a body is closed exactly once: the second death event for that instance and the hours its corpse keeps collecting add nothing")
;(function()
    local reads = 0
    local nonPlayer = setmetatable({ __class = "IsoZombie" }, {
        __index = function(_, key)
            reads = reads + 1
            error("non-player method accessed: " .. key)
        end,
    })
    fire("OnCharacterDeath", nonPlayer)
    nonPlayer.__class = "IsoAnimal"
    fire("OnCharacterDeath", nonPlayer)
    check(reads == 0 and Se.progress("s89-dan").bestHours == 7,
        "zombie and animal deaths never call player APIs or change the closed player life")
end)()
local live = fakePlayer("s89-eve"); live.hours = 12
onlinePlayers = { live }
tick()
live.hours = 30
tick()
local before = Se.progress("s89-eve")
local orphan = fakePlayer("s89-eve"); orphan.hours = 0
fire("OnNewGame", orphan, nil)                 -- 從沒進線上名單的孤兒實例，同帳號同槽
live.hours = 40
tick()
local after = Se.progress("s89-eve")
check(before.bestHours == 18 and after.bestHours == 28 and after.currentHours == 28,
    "an OnNewGame orphan on the slot a live character is using resets nothing: that life keeps counting from its own base")
onlinePlayers = {}
end)()

-- ===== 情境九十：第一次導入，以及讀不出來的資料永遠不准回 ok =====
-- 升級前的存檔沒有季資料：導入要開始記錄，但不得推算未知的舊史，也不得把已經發過的里程碑
-- 再發一次。之後每一種缺損（整列不見、樣本不見、封存少了成績表、歷史 meta 壞掉）都必須是
-- 「讀不出來」，不是一份少幾個人的成功名次，也不是再開一季把它埋掉。
io.write("scenario 90: the first season import, and data nobody can read never answers ok\n")
;(function()
local Se = S.Seasons
local function deepCopy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = deepCopy(v) end
    return out
end
modDataStore[EC.MODDATA_KEY] = nil
files, sentCommands = {}, {}
SandboxVars.MinidoracatEconomy.CheckinAmount = 10
SandboxVars.MinidoracatEconomy.CheckinMinPlaytimeMinutes = 2
SandboxVars.MinidoracatEconomy.CheckinServerDailyCap = 0
nowMs = nowMs + 1000
fire("OnServerStarted")
local function tick(gapMs)
    nowMs = nowMs + (gapMs or 60000)
    fire("OnTickEvenPaused")
end
local boss90 = fakePlayer("s90-boss"); boss90.role = "admin"
local ken = fakePlayer("s90-ken")
onlinePlayers = { ken }
tick()
ken.hours = 200
tick()
local paidBefore = L.getBalance("s90-ken", "survivor").available
local maskBefore = S.modData().claims["s90-ken"].milestones
-- 升級前的存檔：只有純數字的舊季號與 claims，沒有季資料表
local legacy = deepCopy(modDataStore[EC.MODDATA_KEY])
legacy.seasons = nil
legacy.config.season = "1"
local legacyKen = legacy.claims["s90-ken"]
legacyKen.season = "1"
legacyKen.survivalBase, legacyKen.survivalBest, legacyKen.survivalLife = nil, nil, nil
modDataStore[EC.MODDATA_KEY] = legacy
onlinePlayers = {}
nowMs = nowMs + 1000
fire("OnServerStarted")
local imported = Se.state()
local kenClaim = S.modData().claims["s90-ken"]
check(imported ~= nil and paidBefore > 0 and maskBefore > 0
    and imported.seasons[1].number == 1 and imported.seasons[1].partial == true
    and EC.parseId(imported.currentId) ~= nil and imported.currentId ~= "1"
    and kenClaim.season == imported.currentId and kenClaim.milestones == maskBefore
    and L.getBalance("s90-ken", "survivor").available == paidBefore,
    "the first import starts recording a season and carries over what this account was already paid: the claimed milestone mask is kept rather than granted again")
local unseen = Se.progress("s90-ken")
check(unseen.known == false and unseen.currentHours == nil and unseen.bestHours == nil
    and unseen.incomplete == true,
    "the import invents no history: until the server sees this character itself the season reports unknown instead of the two hundred hours sitting in the save")
ken.hours = 201
onlinePlayers = { ken }
tick()
check(Se.progress("s90-ken").known == true and Se.progress("s90-ken").bestHours == 0
    and L.getBalance("s90-ken", "survivor").available == paidBefore,
    "the new base is the first live observation after the import, so a two-hundred-hour character collects none of this season's milestones for a life it did not live here")
-- 缺損一：本季的參與人數與紀錄表必須對得上
local ada = fakePlayer("s90-ada"); ada.hours = 10
local ben = fakePlayer("s90-ben"); ben.hours = 4
onlinePlayers = { boss90, ada, ben }
tick()
ada.hours, ben.hours = 40, 20
tick()
local root90 = S.modData()
local healthy, meta90 = Se.records("current")
check(healthy ~= nil and healthy["s90-ada"] ~= nil and healthy["s90-ben"] ~= nil
    and meta90.participants == EC.countKeys(healthy),
    "while nothing is broken the running season's record map and the head count it kept agree")
local keptRow = root90.claims["s90-ben"]
root90.claims["s90-ben"] = nil
local missingRow = { Se.records("current") }
root90.claims["s90-ben"] = keptRow
local keptLife = keptRow.survivalLife
keptRow.survivalLife = nil
local missingSample = { Se.records("current") }
keptRow.survivalLife = keptLife
check(missingRow[1] == nil and missingRow[3] == "data_unreadable"
    and missingSample[1] == nil and missingSample[3] == "data_unreadable"
    and Se.records("current")["s90-ben"] == healthy["s90-ben"],
    "a participant whose row or whose sample has gone missing makes the season unreadable, not shorter: the count it was recorded with refuses to publish a board without them")
root90.claims["s90-ben"] = nil
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "leaderboard", ada, { kind = "survival", page = 1, requestId = "s90-board" })
local shortBoard = lastSent("leaderboard").args
root90.claims["s90-ben"] = keptRow
check(shortBoard.ok == false and shortBoard.error == "data_unreadable"
    and shortBoard.entries == nil and shortBoard.total == nil,
    "the public board refuses a season whose records do not add up instead of ranking whoever is left")
-- 缺損二：封存的季少了成績表，或少了當初記到的人
SandboxVars.MinidoracatEconomy.SeasonDays = 1
local closed90 = Se.currentId()
Se.start(closed90, "s90-rot", "s90-boss", "archive this season", nowMs)
local arch = root90.seasons.history[closed90]
local savedBest, savedNumber = arch.best, arch.number
arch.best = nil
local noBest = { Se.records(closed90) }
arch.best = { ["s90-ada"] = savedBest["s90-ada"] }
local shortBest = { Se.records(closed90) }
arch.best = savedBest
check(noBest[1] == nil and noBest[3] == "data_unreadable"
    and shortBest[1] == nil and shortBest[3] == "data_unreadable"
    and Se.records(closed90)["s90-ben"] == savedBest["s90-ben"],
    "an archived season without its score table, or with fewer names than the head count it closed with, is unreadable rather than a season nobody survived")
-- 缺損三：壞掉的歷史不得被自動換季埋掉
local running90 = Se.currentId()
arch.number = savedNumber * -1
nowMs = nowMs + 2 * 86400000
fire("OnTickEvenPaused")
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.seasons", boss90, { action = "list", requestId = "s90-list" })
local blindPage = lastSent("admin.seasons").args
check(Se.currentId() == running90 and EC.countKeys(root90.seasons.history) == 1
    and Se.state() == nil and blindPage.ok == false and blindPage.error == "data_unreadable"
    and blindPage.seasonState == nil,
    "an overdue deadline on top of a history nobody can read rotates nothing: the page is told the data is unreadable instead of being handed a fresh season over the damage")
arch.number = savedNumber
nowMs = nowMs + 1000
fire("OnTickEvenPaused")
check(Se.currentId() ~= running90 and EC.countKeys(root90.seasons.history) == 2
    and Se.state() ~= nil and Se.state().seasons[2].id == running90,
    "once the history reads again the overdue deadline rotates, exactly once")
SandboxVars.MinidoracatEconomy.SeasonDays = nil
-- 原生 getter 讀不出來：本季生存說「不知道」並交代原因，日常簽到照常運作
local gus = fakePlayer("s90-gus")
gus.getHoursSurvived = function() error("native getHoursSurvived unavailable") end
onlinePlayers = { boss90, gus }
tick()
tick(3 * 60000)
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "rewards.state", gus, {})
local blindRewards = lastSent("rewards.state").args
check(blindRewards.survivalKnown == false and blindRewards.survivalHours == nil
    and blindRewards.bestSurvivalHours == nil and blindRewards.survivalError ~= nil
    and blindRewards.season == Se.currentId(),
    "a character whose hours the engine will not hand over is reported unknown with the reason attached, never as a zero-hour life")
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "rewards.checkin", gus, checkinArgs("s90-gus", nowMs, "s90-checkin"))
check(lastSent("rewards.checkin").args.ok == true
    and L.getBalance("s90-gus", "survivor").available == 10,
    "and the daily check-in, which counts connected time rather than game hours, still pays while that read is broken")
-- 真正壞掉的是那一列 claim：必須明確報錯，不能靜默換一列新的把已領紀錄蓋掉
onlinePlayers = { boss90, gus, ken }
local kenRow = root90.claims["s90-ken"]
local kenPaid = L.getBalance("s90-ken", "survivor").available
root90.claims["s90-ken"] = "not a claim record at all"
local mark = #sentCommands
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "rewards.state", ken, {})
local brokenState = nil
for i = mark + 1, #sentCommands do
    local c = sentCommands[i]
    if c.command == "rewards.state" and c.player == ken then brokenState = c.args end
end
local stillCorrupt = root90.claims["s90-ken"] == "not a claim record at all"
root90.claims["s90-ken"] = kenRow
check(brokenState ~= nil and brokenState.error ~= nil and stillCorrupt
    and L.getBalance("s90-ken", "survivor").available == kenPaid,
    "a claim row nobody can read is answered with an error and left exactly as it was: it is never quietly replaced by a fresh record that forgets what was already paid")
-- 壞在「本季是哪一季」這一層：本季生存只能說不知道，但每日簽到是另一條算法，不該一起死
nowMs = R.nextResetMs(nowMs) + 3600000          -- 留足同一獎勵日的在線區間，不把日切誤當季故障
local hal = fakePlayer("s90-hal")
onlinePlayers = { boss90, hal }
tick()
tick(3 * 60000)                                -- 連線時間在季資料還好的時候就已經累積
local realNumber = root90.seasons.current.number
root90.seasons.current.number = -1
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "rewards.state", hal, {})
local seasonless = lastSent("rewards.state").args
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "rewards.checkin", hal,
    { day = seasonless.day, rewardIndex = 1, requestId = "s90-hal-checkin" })
local halPaid = lastSent("rewards.checkin").args
root90.seasons.current.number = realNumber
check(seasonless.survivalKnown == false and seasonless.survivalError ~= nil
    and seasonless.day ~= nil and seasonless.dailyLimit ~= nil
    and halPaid.ok == true and L.getBalance("s90-hal", "survivor").available == 10,
    "a season nobody can read takes the season figures away and nothing else: the daily check-in, a different calculation entirely, still pays")
SandboxVars.MinidoracatEconomy.CheckinAmount = nil
SandboxVars.MinidoracatEconomy.CheckinMinPlaytimeMinutes = nil
onlinePlayers = {}
end)()

;(function()
local Se = S.Seasons
modDataStore[EC.MODDATA_KEY] = nil
files, sentCommands, onlinePlayers = {}, {}, {}
nowMs = nowMs + 61000
fire("OnServerStarted")
local first = fakePlayer("s91-first")
local second = fakePlayer("s91-second")
onlinePlayers = { first, second }
local previous = Se.currentId()
local originalEmit = X.emit
X.emit = function(kind, fields)
    if kind == "season.started" then error("season event unavailable") end
    return originalEmit(kind, fields)
end
local changed = Se.start(previous, "s91-event", "operator", "publication failure", nowMs)
X.emit = originalEmit
check(changed.ok == true and changed.warning == "publication_failed" and Se.currentId() ~= previous
    and changed.seasonState.currentId == Se.currentId(),
    "a committed rotation with a failed event reports the real new season and the publication failure")
local same = Se.start(previous, "s91-event", "operator", "publication failure", nowMs)
check(same.ok == true and same.duplicate == true and same.warning == "publication_failed"
    and same.seasonState.currentId == changed.seasonState.currentId,
    "resending that request neither retries the rotation nor erases its recorded publication warning")
local originalReply = S.reply
S.reply = function(player, command, args)
    if player == first and command == "seasons.changed" then error("recipient unavailable") end
    return originalReply(player, command, args)
end
local before = #sentCommands
local notified = Se.start(Se.currentId(), "s91-notice", "operator", "recipient failure", nowMs)
S.reply = originalReply
local reachedSecond = false
for i = before + 1, #sentCommands do
    local sent = sentCommands[i]
    if sent.player == second and sent.command == "seasons.changed"
        and sent.args.seasonState.currentId == Se.currentId() then reachedSecond = true end
end
check(notified.ok == true and notified.warning == "publication_failed" and reachedSecond,
    "one failed recipient does not stop other players receiving the actual new season")
onlinePlayers = {}
end)()

-- ===== 情境九十二：天數改了就是現在改，縮到過去的寧可被拒 =====
-- 天數不再只對下一季生效：正數寫入當下重算正在跑的這一季（同一季 ID、同一個號碼、同一個
-- 開始時間，已領的里程碑與成績都不動），而且線上每一個人——普通小號跟管理者一樣——立刻收到
-- 新的季狀態與獎勵頁資料。縮短到已經過去的時刻是明確拒絕，不是偷偷幫它換一季；封存過的季
-- 永遠不被改寫；同一個值重送不再廣播第二次。
io.write("scenario 92: the season length applies to the season that is running\n")
;(function()
local Se = S.Seasons
local DAY = 86400000
modDataStore[EC.MODDATA_KEY] = nil
files, sentCommands = {}, {}
SandboxVars.MinidoracatEconomy.SeasonDays = nil
nowMs = nowMs + 61000
fire("OnServerStarted")
local boss = fakePlayer("s92-boss"); boss.role = "admin"
local ann = fakePlayer("s92-ann")
onlinePlayers = { boss, ann }
local function tick()
    nowMs = nowMs + 60000
    fire("OnTickEvenPaused")
end
local function setOpt(who, value)
    nowMs = nowMs + 600
    local args = { key = "SeasonDays", requestId = "s92-days-" .. tostring(nowMs) }
    if value ~= nil then args.value = value end
    fire("OnClientCommand", EC.COMMAND_MODULE, "admin.option", who, args)
    return lastSent("admin.option").args
end
-- 某個時點之後，某個玩家收到的某個指令（沒收到就是 nil）
local function sentTo(from, player, command)
    local found = nil
    for i = from + 1, #sentCommands do
        local c = sentCommands[i]
        if c.player == player and c.command == command then found = c.args end
    end
    return found
end
-- 升級前的存檔：設定早就寫著 30 天，但本季還是 0（當初只對下一季生效），而這個帳號已經有
-- 成績也已經領過里程碑
ann.hours = 12
tick()
ann.hours = 60
tick(); tick()
local opened = Se.state().seasons[1]
local maskBefore = S.modData().claims["s92-ann"].milestones
local bestBefore = Se.progress("s92-ann").bestHours
local paidBefore = L.getBalance("s92-ann", "survivor").available
SandboxVars.MinidoracatEconomy.SeasonDays = 30
nowMs = nowMs + 1000
fire("OnServerStarted")
local aligned = Se.state()
check(opened.durationDays == 0 and opened.endsAt == nil
    and maskBefore > 0 and paidBefore > 0 and bestBefore == 48
    and aligned.currentId == opened.id and #aligned.seasons == 1
    and aligned.seasons[1].number == opened.number
    and aligned.seasons[1].startedAt == opened.startedAt
    and aligned.seasons[1].durationDays == 30
    and aligned.seasons[1].endsAt == opened.startedAt + 30 * DAY
    and S.modData().claims["s92-ann"].milestones == maskBefore
    and Se.progress("s92-ann").bestHours == bestBefore
    and L.getBalance("s92-ann", "survivor").available == paidBefore,
    "a save whose setting already says thirty days while the running season still says zero is aligned on restart: that same season takes the deadline, and nobody is reset or paid again for it")
-- 值跟本季現在跑的完全一樣：設定紀錄照存照廣播，但沒有發生的季變更不會被宣布
local markSame = #sentCommands
local sameValue = setOpt(boss, 30)
local afterSame = Se.state()
check(sameValue.ok == true and sameValue.options.SeasonDays.override == true
    and sentTo(markSame, ann, "config") ~= nil
    and sentTo(markSame, ann, "seasons.changed") == nil
    and sentTo(markSame, boss, "seasons.changed") == nil
    and sentTo(markSame, ann, "rewards.state") == nil
    and afterSame.seasons[1].durationDays == 30
    and afterSame.seasons[1].endsAt == aligned.seasons[1].endsAt,
    "storing the very length the season already runs on records the override and pushes the settings change, and announces no season change because none happened")
-- 縮短到還在前面的期限：當下就動，而且不是換季
local markShort = #sentCommands
local shorter = setOpt(boss, 7)
local shortened = Se.state()
local annShort = sentTo(markShort, ann, "seasons.changed")
check(shorter.ok == true and shortened.currentId == aligned.currentId
    and #shortened.seasons == 1
    and shortened.seasons[1].startedAt == aligned.seasons[1].startedAt
    and shortened.seasons[1].durationDays == 7
    and shortened.seasons[1].endsAt == aligned.seasons[1].startedAt + 7 * DAY
    and annShort ~= nil
    and annShort.seasonState.seasons[1].endsAt == shortened.seasons[1].endsAt,
    "shortening to a deadline that is still ahead moves the running season's deadline at once, without closing it")
-- 7 天延長成 30 天：開始時間不動，線上所有人當下收到季狀態與獎勵頁
local markLong = #sentCommands
local longer = setOpt(boss, 30)
local extended = Se.state()
local annLong = sentTo(markLong, ann, "seasons.changed")
local bossLong = sentTo(markLong, boss, "seasons.changed")
check(longer.ok == true and longer.warning == nil
    and extended.currentId == aligned.currentId
    and extended.seasons[1].number == aligned.seasons[1].number
    and extended.seasons[1].startedAt == aligned.seasons[1].startedAt
    and extended.seasons[1].durationDays == 30
    and extended.seasons[1].endsAt == aligned.seasons[1].endsAt
    and annLong ~= nil and annLong.warning == nil
    and annLong.seasonState.currentId == extended.currentId
    and annLong.seasonState.seasons[1].endsAt == extended.seasons[1].endsAt
    and bossLong ~= nil
    and bossLong.seasonState.seasons[1].endsAt == extended.seasons[1].endsAt
    and sentTo(markLong, ann, "rewards.state") ~= nil
    and sentTo(markLong, boss, "rewards.state") ~= nil
    and S.modData().claims["s92-ann"].milestones == maskBefore,
    "extending the running season keeps its id, its number and its start, and every online player -- the ordinary account as much as the admin -- is handed the new state and a fresh reward page without asking")
-- 同一個值重送：連設定廣播都不該再來一次
local markNoop = #sentCommands
local noop = setOpt(boss, 30)
check(noop.ok == true and #sentCommands > markNoop
    and sentTo(markNoop, ann, "seasons.changed") == nil
    and sentTo(markNoop, ann, "config") == nil
    and sentTo(markNoop, ann, "rewards.state") == nil
    and Se.state().seasons[1].endsAt == extended.seasons[1].endsAt,
    "resending the length that is already stored answers ok and broadcasts nothing at all: no second season notice and no second config push")
-- 封存過的季的期限永不被之後的設定改寫
nowMs = nowMs + 600
local closed92 = Se.currentId()
local closedEndsAt = Se.state().seasons[1].endsAt
local rotated92 = Se.start(closed92, "s92-rot", "s92-boss", "close this one by hand", nowMs)
local opened2 = Se.state().seasons[1]
local stretch = setOpt(boss, 60)
local after2 = Se.state()
check(rotated92.ok == true and stretch.ok == true
    and after2.currentId == opened2.id and #after2.seasons == 2
    and after2.seasons[1].durationDays == 60
    and after2.seasons[1].endsAt == opened2.startedAt + 60 * DAY
    and after2.seasons[2].id == closed92
    and after2.seasons[2].durationDays == 30
    and after2.seasons[2].endsAt == closedEndsAt
    and after2.seasons[2].endedAt ~= nil,
    "a later setting never rewrites an archived season: the closed one keeps the length and the deadline it closed with while the running one takes the new length")
-- 縮短到已經過去的時刻：拒絕，而且什麼都沒動
nowMs = nowMs + 10 * DAY
fire("OnTickEvenPaused")
local markRefuse = #sentCommands
local refused = setOpt(boss, 3)
local kept = Se.state()
check(refused.ok == false and refused.error == "season_duration_elapsed"
    and refused.options.SeasonDays.value == 60
    and S.modData().config.options.SeasonDays == 60
    and kept.configuredDays == 60 and kept.currentId == after2.currentId
    and #kept.seasons == 2
    and kept.seasons[1].durationDays == 60
    and kept.seasons[1].endsAt == after2.seasons[1].endsAt
    and sentTo(markRefuse, ann, "seasons.changed") == nil
    and sentTo(markRefuse, ann, "config") == nil,
    "shortening a season into a deadline that has already passed is refused outright: the stored length, the season and everyone's view of it stay exactly as they were, and nothing is rotated to make the number fit")
-- 新期限照的是牆上的時鐘，不是遊戲時數，而且真的會到
nowMs = nowMs + 600
local closed92b = Se.currentId()
Se.start(closed92b, "s92-rot2", "s92-boss", "start a short one", nowMs)
local short = Se.state().seasons[1]
local shortSet = setOpt(boss, 2)
local timed = Se.state().seasons[1]
ann.hours = ann.hours + 100000
tick(); tick()
local stillRunning = Se.state()
check(shortSet.ok == true and timed.id == short.id and timed.durationDays == 2
    and timed.endsAt == short.startedAt + 2 * DAY
    and stillRunning.currentId == short.id and #stillRunning.seasons == 3
    and Se.progress("s92-ann").bestHours >= 100000,
    "the deadline a live change gives a season is wall clock and nothing else: a hundred thousand game hours inside two real minutes do not reach it")
nowMs = timed.endsAt + 1
fire("OnTickEvenPaused")
local expired = Se.state()
check(expired.currentId ~= short.id and #expired.seasons == 4
    and expired.seasons[2].id == short.id
    and expired.seasons[2].durationDays == 2
    and expired.seasons[2].endsAt == timed.endsAt
    and expired.seasons[1].durationDays == 2
    and expired.seasons[1].endsAt == expired.seasons[1].startedAt + 2 * DAY,
    "and when the real clock reaches it the season closes exactly once, on the deadline that live change gave it")
-- 0：解除本季的自動截止，不是把它關掉
local markZero = #sentCommands
local zero = setOpt(boss, 0)
local manual = Se.state()
local annZero = sentTo(markZero, ann, "seasons.changed")
nowMs = nowMs + 400 * DAY
fire("OnTickEvenPaused")
local later = Se.state()
check(zero.ok == true and manual.seasons[1].durationDays == 0
    and manual.seasons[1].endsAt == nil
    and annZero ~= nil and annZero.seasonState.seasons[1].endsAt == nil
    and later.currentId == manual.currentId and #later.seasons == 4,
    "zero lifts the running season's automatic deadline instead of closing it: the season stays open, is handed out as manual, and four hundred real days later it is still that same season")
-- 群組重設（value = nil）走的是同一個寫入路徑，也被同一個閘門攔下
local markClear = #sentCommands
local cleared = setOpt(boss, nil)
check(cleared.ok == false and cleared.error == "season_duration_elapsed"
    and S.modData().config.options.SeasonDays == 0
    and cleared.options.SeasonDays.value == 0
    and Se.state().seasons[1].endsAt == nil
    and sentTo(markClear, ann, "config") == nil
    and sentTo(markClear, ann, "seasons.changed") == nil,
    "clearing the override is the same write through the same gate: falling back to the file's thirty days would put this season's deadline four hundred days in the past, so it is refused and the stored zero stays")
SandboxVars.MinidoracatEconomy.SeasonDays = nil
onlinePlayers = {}
end)()

;(function()
local Se = S.Seasons
modDataStore[EC.MODDATA_KEY] = nil
files, sentCommands, onlinePlayers = {}, {}, {}
nowMs = nowMs + 61000
fire("OnServerStarted")
local boss = fakePlayer("live-setting-boss"); boss.role = "admin"
local player = fakePlayer("live-setting-player")
onlinePlayers = { boss, player }
local id = Se.currentId()
S.Seasons = nil
local ok, err = Cfg.setOption("SeasonDays", 30, boss:getUsername())
S.Seasons = Se
check(ok == false and err == "not_ready" and S.modData().config.options.SeasonDays == nil
    and Se.currentId() == id and Se.state().seasons[1].endsAt == nil,
    "a season module that is unavailable cannot leave a saved thirty-day option over an unchanged manual season")
Se.start(id, "live-history", boss:getUsername(), "closed season for validation", nowMs)
local root = S.modData()
local archive = root.seasons.history[id]
local number = archive.number
archive.number = -1
local before = root.seasons.current.endsAt
ok, err = Cfg.setOption("SeasonDays", 30, boss:getUsername())
archive.number = number
check(ok == false and err == "data_unreadable" and root.config.options.SeasonDays == nil
    and root.seasons.current.endsAt == before,
    "an unreadable season snapshot refuses the setting without changing either its stored value or deadline")
archive.number = -1
ok, err = Cfg.setOption("SeasonDays", 0, boss:getUsername())
archive.number = number
check(ok == false and err == "data_unreadable" and root.config.options.SeasonDays == nil,
    "storing the same effective manual value still validates the complete season state before reporting success")
S.Seasons = nil
ok, err = Cfg.setOption("SeasonDays", nil, boss:getUsername())
S.Seasons = Se
check(ok == false and err == "not_ready" and root.config.options.SeasonDays == nil,
    "even an identical setting cannot claim success while its season module is unavailable")
local reply = S.reply
S.reply = function(who, command, args)
    if who == player and command == "seasons.changed" then error("recipient failed") end
    return reply(who, command, args)
end
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.option", boss,
    { key = "SeasonDays", value = 30, requestId = "live-publish-warning" })
S.reply = reply
local result = lastSent("admin.option").args
check(result.ok == true and result.warning == "publication_failed" and result.requestId == "live-publish-warning"
    and Se.state().seasons[1].durationDays == 30 and root.config.options.SeasonDays == 30,
    "a deadline that applied but could not notify one player returns its actual applied value and a publication warning")
local engineSend = sendServerCommand
sendServerCommand = function(who, module, command, args)
    if command == "config" then error("config publication failed") end
    return engineSend(who, module, command, args)
end
nowMs = nowMs + 600
fire("OnClientCommand", EC.COMMAND_MODULE, "admin.option", boss,
    { key = "SeasonDays", value = 31, requestId = "live-config-publication" })
sendServerCommand = engineSend
result = lastSent("admin.option").args
check(result.requestId == "live-config-publication" and result.ok == true
    and result.warning == "publication_failed" and root.config.options.SeasonDays == 31
    and Se.state().seasons[1].durationDays == 31,
    "a post-commit config publication error still answers the matching request with its applied deadline and warning")
onlinePlayers = {}
end)()

;(function()
local inv = fakeInventory()
local top, nested = { id = 1 }, { id = 2 }
inv:AddItem(top)
check(EC.Mailbox.findTopLevel(inv, top.id) == top,
    "shared inventory lookup returns the actual top-level item")
inv.getItemWithID = function() return nested end
check(EC.Mailbox.findTopLevel(inv, nested.id) == nil,
    "an item found by ID but absent from the top-level list cannot enter escrow")
end)()

-- ===== 情境：交易站雙向電台（原生 IsoRadio 附屬、所有權、生命週期、原生操作防線）=====
-- 只測「真的不確定」的邊界：偽造標記、重複、被關機、節流、設定同步、卸載、實體終端消失、
-- 孤兒、登錄失敗警告、原生 moveable／device 入口。不測字串內容，不靠「有被呼叫」當綠燈——
-- 每條防線都先讓原版假件真的做破壞（生成物品、移出格子），再證明防線攔得住。
io.write("scenario: trade terminal two-way radio\n")
;(function()
local Rd, Rl, TR = S.Radio, S.TradeRadio, EC.TradeRadio
modDataStore[EC.MODDATA_KEY] = nil
files = {}
sentCommands = {}
radioSent, radioChannels = {}, {}
worldSprites, worldObjects, worldLoaded, worldSpriteDeny = {}, {}, {}, {}
worldRemoveRefuses, worldFault, worldRemoveRefuseAll = {}, {}, false
movCalls = {}
nowMs = nowMs + 61000
SandboxVars.MinidoracatEconomy.RadioIntervalMinutes = 10
SandboxVars.MinidoracatEconomy.RadioFrequency = 101100
SandboxVars.MinidoracatEconomy.RadioRange = 500
SandboxVars.MinidoracatEconomy.RadioRelayEnabled = true
worldSprites["100,200,0"] = "MinidoracatEconomy_terminal_2"   -- trade；朝向索引 2
worldSprites["300,400,0"] = "MinidoracatEconomy_terminal_0"   -- ATM
worldSprites["500,600,1"] = "appliances_com_01_53"            -- trade；原版主控台，53 % 4 = 1
fire("OnServerStarted")
local root = ModData.getOrCreate(EC.MODDATA_KEY)
local boss = fakePlayer("boss"); boss.role = "admin"; boss.inventory = fakeInventory(50)
onlinePlayers = { boss }
local function cmd(who, name, args)
    nowMs = nowMs + 600
    args = args or {}
    args.requestId = args.requestId or (name .. nowMs)
    fire("OnClientCommand", EC.COMMAND_MODULE, name, who, args)
    local s = lastSent(name)
    return s and s.args or {}
end
local function option(key, value)
    return cmd(boss, "admin.option", { key = key, value = value, requestId = key })
end
local function square(x, y, z) return getCell():getGridSquare(x, y, z) end
local function owned(x, y, z) return TR.ownedOnSquare(square(x, y, z)) end
local function place(x, y, z, obj)
    local k = worldKey(x, y, z)
    worldObjects[k] = worldObjects[k] or {}
    worldObjects[k][#worldObjects[k] + 1] = obj
    return obj
end
-- 一台「冒牌 owned」：deviceName 是我們的，但不是 relay 放的（重複／孤兒情境用）
local function ownedRadio(spriteName)
    local o = IsoRadio.new(nil, nil, { getName = function() return spriteName end })
    o:getDeviceData():setDeviceName(EC_TRADE_RADIO_TAG)
    return o
end
local function sweep(ms)
    nowMs = nowMs + (ms or 31000)
    fire("OnTickEvenPaused")
end

local reg = cmd(boss, "terminal.register", { x = 100, y = 200, z = 0, kind = "trade" })
local device = owned(100, 200, 0)[1]
check(reg.ok == true and reg.warning == nil and #owned(100, 200, 0) == 1
    and device:getObjectName() == "Radio"
    and device:getSprite():getName() == "MinidoracatEconomy_speaker_terminal_2",
    "registering a trade terminal attaches exactly one speaker facing the terminal")
local dd = device:getDeviceData()
check(cmd(boss, "terminal.register", { x = 300, y = 400, z = 0, kind = "atm" }).ok == true
    and #owned(300, 400, 0) == 0, "an ATM never gets a device")
local byKind = {}
for _, e in ipairs(lastSent("terminals").args.list) do byKind[e.kind .. e.x] = e end
check(byKind["trade100"].radioState == "active" and byKind["atm300"].radioState == nil,
    "the pushed terminal list carries radioState for trade terminals only")
check(cmd(boss, "terminal.register", { x = 500, y = 600, z = 1, kind = "trade" }).ok == true
    and #owned(500, 600, 1) == 1
    and owned(500, 600, 1)[1]:getSprite():getName() == "MinidoracatEconomy_speaker_terminal_1",
    "a vanilla console terminal gets the machine speaker facing the same way (sprite index modulo four)")

-- 偽造：同 sprite、偽造 modData 鍵、並用原版放置路徑把 IsoObject 的 name 寫成我們的標記
local forged = place(100, 200, 0, fakeWorldRadio("appliances_com_01_2", "both"))
sweep()
check(#owned(100, 200, 0) == 1 and forged.removed == nil and TR.isOwned(forged) == false,
    "a vanilla radio with a forged ModData key and a forged object name is not owned and is never removed")
check(owned(100, 200, 0)[1].serial == device.serial,
    "a device that is already correct is not rebuilt on every sweep")
local dupe = place(100, 200, 0, ownedRadio("appliances_com_01_2"))
sweep()
check(#owned(100, 200, 0) == 1 and dupe.removed == true and owned(100, 200, 0)[1].serial == device.serial,
    "a duplicate device on the same square is removed and the standing one is kept")

dd:setTurnedOnRaw(false)
sweep()
local rebuilt = owned(100, 200, 0)[1]
check(#owned(100, 200, 0) == 1 and rebuilt.serial ~= device.serial and device.removed == true
    and rebuilt:getDeviceData():getIsTurnedOn() == true,
    "a device switched off by a client packet comes back as a remove + add, not a resent add packet")
rebuilt:getDeviceData():setChannelRaw(88000)
sweep(5000)
check(owned(100, 200, 0)[1].serial == rebuilt.serial and Rl.state(100, 200, 0) == "waiting",
    "a second tamper inside the repair window is not rebuilt every tick, and is reported as not ready")
sweep()
check(owned(100, 200, 0)[1]:getDeviceData():getChannel() == 101100 and Rl.state(100, 200, 0) == "active",
    "once the repair window passed the tampered device is put back on the market frequency")
-- Raw IEEE floats arrive in native device packets. A NaN must not pass the usable-state gate.
for _, field in ipairs({ "power", "volume" }) do
    local bad = owned(100, 200, 0)[1]
    bad:getDeviceData()[field] = 0 / 0
    sweep()
    local repaired = owned(100, 200, 0)[1]
    check(bad.removed == true and #owned(100, 200, 0) == 1
        and repaired:getDeviceData()[field] > 0 and Rl.state(100, 200, 0) == "active",
        "a native NaN " .. field .. " cannot leave an unusable device permanently active")
end

check(option("RadioFrequency", 104200).ok == true
    and owned(100, 200, 0)[1]:getDeviceData():getChannel() == 104200
    and owned(100, 200, 0)[1]:getDeviceData():getMinChannelRange() == 104200
    and owned(100, 200, 0)[1]:getDeviceData():getMaxChannelRange() == 104200
    and lastSent("config").args.radio.frequency == 104200
    and lastSent("config").args.radio.relayEnabled == true,
    "an admin frequency change retunes the standing devices at once and rides along in the config push")
check(option("RadioRange", 0).ok == true and Rd.nativeRange() == 100000 and Rd.strength() == -1
    and owned(100, 200, 0)[1]:getDeviceData():getTransmitRange() == 100000
    and lastSent("config").args.radio.range == 100000,
    "range 0 stays strength -1 for the summary and becomes the named unlimited native range on the device")

SandboxVars.MinidoracatEconomy.RadioRelayEnabled = false
local bystander = place(100, 200, 0, fakeWorldRadio("appliances_com_01_2", "modData"))
sweep()
check(#owned(100, 200, 0) == 0 and #owned(500, 600, 1) == 0 and bystander.removed == nil
    and Rl.state(100, 200, 0) == "disabled",
    "switching the relay off takes every loaded device away and leaves vanilla radios standing")
local info = Rd.clientInfo()
check(info.relayEnabled == false and info.summaryEnabled == true and info.enabled == true
    and info.frequency == 104200 and info.range == 100000 and info.category == "Economy",
    "radioInfo reports the two halves separately and enabled when either one is on")
SandboxVars.MinidoracatEconomy.RadioRelayEnabled = true
check(option("RadioIntervalMinutes", 0).ok == true and Rd.clientInfo().summaryEnabled == false
    and Rd.clientInfo().relayEnabled == true and Rd.clientInfo().enabled == true
    and #owned(100, 200, 0) == 1,
    "the market summary can be off while the relay is on: the device is still placed")

worldSprites["100,200,0"] = nil
worldLoaded["100,200,0"] = true            -- 格子還在，只是實體終端不在了
sweep()
check(#owned(100, 200, 0) == 0 and Rl.state(100, 200, 0) == "waiting"
    and EC.countKeys(root.terminals) == 3,
    "a registration whose physical terminal is gone loses its device and reports not ready, keeping the registration")
worldSprites["500,600,1"], worldObjects["500,600,1"], worldLoaded["500,600,1"] = nil, nil, nil
sweep()
check(Rl.state(500, 600, 1) == "waiting" and worldObjects["500,600,1"] == nil
    and EC.countKeys(root.terminals) == 3,
    "an unloaded chunk is reported as not ready: nothing created, nothing dropped, no square held")

worldLoaded["900,900,0"] = true
local orphan = place(900, 900, 0, ownedRadio("appliances_com_01_0"))
local neighbour = place(900, 900, 0, fakeWorldRadio("appliances_com_01_0", "objectName"))
fire("LoadGridsquare", square(900, 900, 0))
check(#owned(900, 900, 0) == 0 and orphan.removed == true and neighbour.removed == nil,
    "an owned device on a square nobody registered is deleted on chunk load, the vanilla radio beside it is not")
worldSprites["500,600,1"] = "appliances_com_01_53"
worldLoaded["500,600,1"] = true
fire("LoadGridsquare", square(500, 600, 1))
check(#owned(500, 600, 1) == 1 and Rl.state(500, 600, 1) == "active",
    "a registered trade terminal gets its device back as soon as its chunk is loaded again")
local id500 = nil
for tid, t in pairs(root.terminals) do if t.x == 500 then id500 = tid end end
check(cmd(boss, "terminal.unregister", { id = id500 }).ok == true and #owned(500, 600, 1) == 0,
    "unregistering a trade terminal takes its device away with it")

worldSpriteDeny["MinidoracatEconomy_speaker_terminal_1"] = true
local failed = cmd(boss, "terminal.register", { x = 500, y = 600, z = 1, kind = "trade" })
check(failed.ok == true and failed.id ~= nil and failed.warning == "radio_unavailable"
    and #owned(500, 600, 1) == 0 and Rl.state(500, 600, 1) == "error"
    and EC.countKeys(root.terminals) == 3,
    "a native attachment failure keeps the real registration result and warns instead of faking success")
worldSpriteDeny["MinidoracatEconomy_speaker_terminal_1"] = nil
sweep()
check(#owned(500, 600, 1) == 1 and Rl.state(500, 600, 1) == "active",
    "the bounded sweep picks a failed attachment up later, with no journal and no retry store")

-- 原生操作防線：owned 一律擋，原版 radio 一律走原路徑
local sq = square(500, 600, 1)
local guarded = owned(500, 600, 1)[1]
movCalls = {}
check(ISMoveableSpriteProps.canPickUpMoveable({}, boss, sq, guarded) == false and #movCalls == 0,
    "the moveable menu refuses to pick an owned device up")
check(ISMoveableSpriteProps.pickUpMoveableInternal({}, boss, sq, guarded, nil, "MinidoracatEconomy_speaker_terminal_1", true, false) == nil
    and #movCalls == 0 and boss.inventory.count("Base.RadioRed") == 0 and #owned(500, 600, 1) == 1,
    "the pickup execution point refuses too: no free ham radio item and the device stays on the square")
local plain = place(500, 600, 1, fakeWorldRadio("appliances_com_01_1"))
check(ISMoveableSpriteProps.canPickUpMoveable({}, boss, sq, plain) == true
    and ISMoveableSpriteProps.pickUpMoveableInternal({}, boss, sq, plain, nil, "appliances_com_01_1", true, false) ~= nil
    and plain.removed == true and boss.inventory.count("Base.RadioRed") == 1 and #movCalls == 2,
    "a vanilla radio still goes through the original pickup path and really is picked up")
movCalls = {}
local scrap = ISMoveableSpriteProps.canScrapObject({ object = guarded }, boss)
check(scrap.canScrap == false
    and ISMoveableSpriteProps.scrapObjectInternal({ object = guarded }, boss, {}, sq, guarded, scrap, 0, nil) == 0
    and #movCalls == 1 and #owned(500, 600, 1) == 1,
    "an owned device cannot be scrapped, and the execution point refuses even a forced call")
local plain2 = place(500, 600, 1, fakeWorldRadio("appliances_com_01_1"))
check(ISMoveableSpriteProps.canScrapObject({ object = plain2 }, boss).canScrap == true
    and ISMoveableSpriteProps.scrapObjectInternal({ object = plain2 }, boss, {}, sq, plain2, {}, 100, nil) == 3
    and plain2.removed == true, "a vanilla radio can still be scrapped")
check(ISMoveableSpriteProps.canRotateMoveable({}, sq, guarded) == false
    and ISMoveableSpriteProps.canRotateMoveable({}, sq, plain2) == true,
    "an owned device cannot be rotated, a vanilla one can")
check(ISDeviceBatteryAction.isValid({ deviceData = guarded:getDeviceData(), isRemove = false }) == false
    and ISDeviceMediaAction.isValid({ deviceData = guarded:getDeviceData(), isRemove = false,
        secondaryItem = { getMediaType = function() return -1 end } }) == false,
    "device options cannot feed an owned device a battery or a tape")
check(ISDeviceBatteryAction.isValid({ deviceData = fakeDeviceData(fakeWorldRadio("appliances_com_01_1")), isRemove = true }) == true,
    "the same battery action still works on a vanilla device")
check(TR.guardsInstalled() == true and TR.isOwned(guarded) == true and TR.isOwned(plain2) == false
    and TR.isOwned(nil) == false,
    "the guards are installed and ownership is decided by the device name alone")

-- 第一層：client 真的動得到的東西——物件 modData 被清空、原生 object name 被抹掉又被改成我方標記
-- 字串、sprite 被換掉。這些都不得影響 owned 判定，尤其不得讓伺服器每次掃描都「以為裝置不見了」
-- 而再補一台（那會是可由 client 觸發的無限生成 DoS）。外觀遭改可重建，但數量恆為一。
guarded.modData = {}
guarded:setName(nil)
sweep()
check(#owned(500, 600, 1) == 1 and owned(500, 600, 1)[1].serial == guarded.serial
    and TR.isOwned(guarded) == true,
    "wiping the object ModData and the native object name keeps the device ours and places no second one")
guarded:setName(EC_TRADE_RADIO_TAG)
guarded.modData.MinidoracatEconomyTradeRadio = true
guarded:setSprite({ getName = function() return "" end })
sweep()
check(#owned(500, 600, 1) == 1 and TR.isOwned(guarded) == true and guarded.removed == true
    and owned(500, 600, 1)[1]:getSprite():getName() == "MinidoracatEconomy_speaker_terminal_1",
    "a hidden owned radio is replaced with one visible speaker without losing ownership or duplicating devices")
guarded = owned(500, 600, 1)[1]

-- 第二層：deviceName 本身被改掉。那是伺服器才寫得到的欄位（client 封包寫不到，見 ECTradeRadio
-- 檔頭出處），所以這才是「不再是我們的」的唯一判準：不刪那台別人的收音機，另外補一台我方裝置。
-- 這不是 modData wipe 的預期行為，兩層必須分開看。
guarded:getDeviceData():setDeviceName("WaveSignalDevice")
sweep()
check(#owned(500, 600, 1) == 1 and owned(500, 600, 1)[1].serial ~= guarded.serial
    and guarded.removed == nil and Rl.state(500, 600, 1) == "active",
    "only a server-written deviceName change ends ownership: the old device is left alone and a new one is placed")

-- ---------- 原生失敗邊界：「呼叫回來了」不等於「世界照做了」 ----------

-- 多格刪除。client 改得到世界物件的 sprite（GameServer.java:1879-1907），而原生預設的刪除會
-- 按 sprite 展開整組格子成員、只比 sprite，不看 IsoRadio 也不看 deviceName，所以預設 overload
-- 會連旁邊那台別人的收音機一起刪掉。Main 已在真 jar 上重現（native-removal-proof.json）。
local dev = owned(500, 600, 1)[1]
dev:setSprite(gridSprite("MinidoracatEconomy_speaker_terminal_1", { "MinidoracatEconomy_speaker_terminal_1" }))
dev:getDeviceData():setTurnedOnRaw(false)
sweep()
check(#owned(500, 600, 1) == 1 and owned(500, 600, 1)[1].serial ~= dev.serial
    and dev.removed == true and guarded.removed == nil and Rl.state(500, 600, 1) == "active",
    "removing an owned device takes only that object: the plain radio sharing its sprite grid is left standing")

-- 非例外的失敗：引擎什麼都沒刪、只回 -1（多格不完整就是這個回傳）。不得當成成功、不得接著再
-- 補一台，也不得回報健康。
local refused = owned(500, 600, 1)[1]
worldRemoveRefuses[refused] = true
refused:getDeviceData():setTurnedOnRaw(false)
sweep()
check(#owned(500, 600, 1) == 1 and owned(500, 600, 1)[1].serial == refused.serial
    and Rl.state(500, 600, 1) == "error",
    "a removal the engine refused with -1 is not success: no second device is placed and the square reports error")
worldRemoveRefuses[refused] = nil
worldFault.removeItem = "native removal threw"
sweep()
check(#owned(500, 600, 1) == 1 and owned(500, 600, 1)[1].serial == refused.serial
    and Rl.state(500, 600, 1) == "error" and worldFault.removeItem == nil,
    "a removal that raised stops the pass with the engine's own error instead of adding a device on top of it")
sweep()
check(#owned(500, 600, 1) == 1 and owned(500, 600, 1)[1].serial ~= refused.serial
    and refused.removed == true and Rl.state(500, 600, 1) == "active",
    "the bounded sweep recovers from a removal failure too, once the removal goes through")

-- AddSpecialObject 先插入、之後才 addToWorld 與重算（IsoGridSquare.java:6189-6224）。
-- added 布林會說「加成功了」；只有問格子才知道世界上真的留了東西。
local squareObjects = #(worldObjects["500,600,1"] or {})
local doomed = owned(500, 600, 1)[1]
doomed:getDeviceData():setTurnedOnRaw(false)
worldFault.addSpecialObject = "addToWorld failed after the object was inserted"
sweep()
check(#owned(500, 600, 1) == 0 and doomed.removed == true
    and #(worldObjects["500,600,1"] or {}) == squareObjects - 1
    and Rl.state(500, 600, 1) == "error",
    "a build that failed after its object was inserted takes the half-built device back out by membership")

-- Add 成功、發送失敗、回滾的 remove 又被拒絕：一台裝置資料完全正確、卻從未走完 addToWorld／
-- RegisterDevice、也從未送給任何 client 的物件留在世界上。只讀資料的健康檢查會說它 active。
worldFault.transmit = "publish failed"
worldRemoveRefuseAll = true
sweep()
local ghost = owned(500, 600, 1)[1]
check(#owned(500, 600, 1) == 1 and ghost ~= nil and Rl.state(500, 600, 1) == "error"
    and ghost:getDeviceData():getIsTurnedOn() == true and ghost:getDeviceData():getChannel() == 104200,
    "an inserted but unpublished device whose rollback was refused stays visible as an error, not as a healthy station")
worldRemoveRefuseAll = false
sweep()
check(#owned(500, 600, 1) == 1 and owned(500, 600, 1)[1].serial ~= ghost.serial
    and ghost.removed == true and Rl.state(500, 600, 1) == "active",
    "the unpublished leftover is replaced on the next pass: correct device data does not clear an unfinished build")

-- guard 裝不起來（原版 symbol 不見、require 失敗）就不准有裝置：原生 pickup 會發一件真物品並
-- 移走世界裝置，sweep 再補一台，一次漏擋就成了可反覆領取的免費 HAM。
local realInstall = TR.installGuards
TR.installGuards = function() return false, "ISMoveableSpriteProps:pickUpMoveableInternal" end
local unguarded = owned(500, 600, 1)[1]
sweep()
check(#owned(500, 600, 1) == 0 and unguarded.removed == true and Rl.state(500, 600, 1) == "error",
    "with the operation guards unavailable nothing is created and the standing device is taken away")
TR.installGuards = realInstall
sweep()
check(#owned(500, 600, 1) == 1 and Rl.state(500, 600, 1) == "active",
    "the device comes back by itself once the guards install again")

-- cloneDeviceDataFromItem 回 nil 是真失敗。沿用建構子留下的亂數化資料會放出一台看起來成功、
-- 實際頻率／開關／耗電全不對的電台——契約要的是真正的 Base.HamRadio1 裝置。
worldFault.clone = "no device data for Base.HamRadio1"
local uncloned = owned(500, 600, 1)[1]
uncloned:getDeviceData():setTurnedOnRaw(false)
sweep()
check(#owned(500, 600, 1) == 0 and uncloned.removed == true and Rl.state(500, 600, 1) == "error",
    "a device data clone that came back nil fails the build instead of publishing whatever the constructor left")
sweep()

-- 解除登錄／拆站：附屬裝置得先確認清掉，才准丟掉登錄或動不可回復的實體。bounded sweep 只走
-- 還在登錄裡的格子，先丟登錄再清理失敗，就是把一台還在收音的裝置留在世界上，而且再也沒有任何
-- 路徑會重試它。
local id500b = nil
for tid, t in pairs(root.terminals) do if t.x == 500 then id500b = tid end end
worldFault.removeItem = "native removal threw"
local blocked = cmd(boss, "terminal.unregister", { id = id500b })
check(blocked.ok == false and blocked.error == "radio_unavailable"
    and root.terminals[id500b] ~= nil and #owned(500, 600, 1) == 1,
    "an unregister whose device would not go is refused, so the registration that entitles the retry survives")
local freed = cmd(boss, "terminal.unregister", { id = id500b })
check(freed.ok == true and root.terminals[id500b] == nil and #owned(500, 600, 1) == 0,
    "the same unregister succeeds once the device really leaves the square")
local reg500 = cmd(boss, "terminal.register", { x = 500, y = 600, z = 1, kind = "trade" })
worldFault.removeItem = "native removal threw"
local kept = cmd(boss, "terminal.demolish", { x = 500, y = 600, z = 1 })
check(kept.ok == false and kept.error == "radio_unavailable"
    and root.terminals[reg500.id] ~= nil and worldSprites["500,600,1"] == "appliances_com_01_53"
    and #owned(500, 600, 1) == 1,
    "a demolish whose device would not go is refused before the tile is touched: tile and registration both stay")
local razed = cmd(boss, "terminal.demolish", { x = 500, y = 600, z = 1 })
check(razed.ok == true and root.terminals[reg500.id] == nil
    and worldSprites["500,600,1"] == nil and #owned(500, 600, 1) == 0,
    "the same demolish succeeds once the device goes, and takes the tile and the registration with it")

-- 設定已提交、裝置沒跟上：option 必須回 warning——不是假成功，也不是把已提交的設定回滾。
worldSprites["100,200,0"] = "MinidoracatEconomy_terminal_2"
worldSpriteDeny["MinidoracatEconomy_speaker_terminal_2"] = true
local warned = option("RadioFrequency", 105500)
check(warned.ok == true and warned.warning == "radio_unavailable"
    and Rd.frequency() == 105500 and lastSent("config").args.radio.frequency == 105500
    and Rl.state(100, 200, 0) == "error",
    "a radio setting that could not reach the devices keeps the committed value and answers with a warning")
worldSpriteDeny["MinidoracatEconomy_speaker_terminal_2"] = nil
local applied = option("RadioFrequency", 101100)
check(applied.ok == true and applied.warning == nil
    and owned(100, 200, 0)[1]:getDeviceData():getChannel() == 101100,
    "the same change answers without a warning once the standing devices really were rebuilt")

-- 掃描裡變動的狀態要自己推一次聚合快照：已經開著的視窗只在 hello 或自己再要一次時才收得到
-- 清單，否則修復／失敗／chunk 載入之後永遠顯示舊狀態。
worldSpriteDeny["MinidoracatEconomy_speaker_terminal_2"] = true
owned(100, 200, 0)[1]:getDeviceData():setTurnedOnRaw(false)
sentCommands = {}
sweep()
local pushedState = nil
for _, e in ipairs(((lastSent("terminals") or {}).args or {}).list or {}) do
    if e.x == 100 then pushedState = e.radioState end
end
check(pushedState == "error" and Rl.state(100, 200, 0) == "error",
    "a state that changed during a sweep is pushed to the clients once, with nobody asking for the list")
worldSpriteDeny["MinidoracatEconomy_speaker_terminal_2"] = nil
sweep()
sentCommands = {}
sweep()
check(lastSent("terminals") == nil and Rl.state(100, 200, 0) == "active",
    "a sweep that changed no state pushes nothing: the aggregate push follows changes, not the clock")

-- 真正的旋轉入口是外層 rotateMoveable（TransactionProcessor.lua:16-25、
-- ISMoveablesAction.lua:236-245）：原版先 _forceAllow 撿起來，再無條件從背包挑一件同
-- worldSprite 的既有物品放下。只擋 canRotateMoveable 的「拒絕」會挪用玩家另一台普通 HAM。
worldObjects["100,200,0"] = {}
sweep()
local target = owned(100, 200, 0)[1]
local ham = instanceItem("Base.RadioRed")
ham.worldSprite = "MinidoracatEconomy_speaker_terminal_2"
boss.inventory:AddItem(ham)
movCalls = {}
ISMoveableSpriteProps.rotateMoveable({}, boss, square(100, 200, 0), "MinidoracatEconomy_speaker_terminal_2")
check(#movCalls == 0 and boss.inventory:contains(ham) == true
    and #(worldObjects["100,200,0"] or {}) == 1 and target.removed == nil
    and owned(100, 200, 0)[1].serial == target.serial,
    "the real rotate entry point refuses an owned device with no side effects: the player's other ham radio stays in the bag")
local spare = place(100, 200, 0, fakeWorldRadio("appliances_com_01_9"))
local spareItem = instanceItem("Base.RadioRed")
spareItem.worldSprite = "appliances_com_01_9"
boss.inventory:AddItem(spareItem)
movCalls = {}
ISMoveableSpriteProps.rotateMoveable({}, boss, square(100, 200, 0), "appliances_com_01_9")
check(#movCalls == 2 and spare.removed == true and boss.inventory:contains(spareItem) == false
    and target.removed == nil,
    "a vanilla radio still goes through the whole original rotation, item and all")
-- A partial Lua load must not forget existing native devices while pretending cleanup worked.
local registeredId = S.Terminal.at(100, 200, 0)
S.TradeRadio = nil
check(cmd(boss, "terminal.unregister", { id = registeredId }).error == "radio_unavailable"
    and root.terminals[registeredId] ~= nil and target.removed == nil,
    "a missing relay module cannot silently unregister an existing device")
check(cmd(boss, "terminal.demolish", { x = 100, y = 200, z = 0 }).error == "radio_unavailable"
    and worldSprites["100,200,0"] ~= nil and root.terminals[registeredId] ~= nil,
    "a missing relay module refuses demolition before losing the cleanup coordinates")
worldSprites["700,800,0"] = "MinidoracatEconomy_terminal_0"
local partial = cmd(boss, "terminal.register", { x = 700, y = 800, z = 0, kind = "trade" })
check(partial.ok == true and partial.warning == "radio_unavailable" and root.terminals[partial.id] ~= nil,
    "a registered terminal discloses that its relay module could not synchronise")
S.TradeRadio = Rl

-- ---------- 外觀：自有的小喇叭，不是原版那台大 HAM ----------
-- 造型只是 sprite：裝置仍站在終端自己那格（語音來源座標不變），肩側／機台上緣的位移存在
-- 128x256 cell 裡（fixPlacedItemRenderOffsets:10213-10249 只重定位 IsoWorldInventoryObject，
-- 不動 IsoRadio）。這裡要證的是選哪一組、朝向跟不跟得上、舊存檔的大 HAM 會不會換過來，以及
-- 新 tile 沒載入時會不會偷偷退回大 HAM 或放一台看不見的裝置。
worldSprites["820,130,0"] = "MinidoracatEconomy_catgirl_3"
local kitty = cmd(boss, "terminal.register", { x = 820, y = 130, z = 0, kind = "trade" })
local shoulder = owned(820, 130, 0)[1]
check(kitty.ok == true and kitty.warning == nil and #owned(820, 130, 0) == 1
    and shoulder:getSprite():getName() == "MinidoracatEconomy_speaker_catgirl_3"
    and shoulder:getDeviceData():getChannel() == 101100
    and shoulder:getDeviceData():getIsTurnedOn() == true,
    "a catgirl terminal gets the shoulder speaker set facing the way she does, on a real ham device")
-- 每一種可登錄的終端 tile 都要對到自己那組喇叭的同一個面向：貓娘前綴挑肩側組，自有機台與
-- 原版主控台（appliances_com_01_52..55、security_01_0..3）挑機台組，面向沿尾碼 % 4。
local wrong = {}
for tile, speaker in pairs({
    MinidoracatEconomy_catgirl_0 = "MinidoracatEconomy_speaker_catgirl_0",
    MinidoracatEconomy_catgirl_1 = "MinidoracatEconomy_speaker_catgirl_1",
    MinidoracatEconomy_catgirl_2 = "MinidoracatEconomy_speaker_catgirl_2",
    MinidoracatEconomy_catgirl_3 = "MinidoracatEconomy_speaker_catgirl_3",
    MinidoracatEconomy_terminal_0 = "MinidoracatEconomy_speaker_terminal_0",
    MinidoracatEconomy_terminal_1 = "MinidoracatEconomy_speaker_terminal_1",
    MinidoracatEconomy_terminal_2 = "MinidoracatEconomy_speaker_terminal_2",
    MinidoracatEconomy_terminal_3 = "MinidoracatEconomy_speaker_terminal_3",
    appliances_com_01_52 = "MinidoracatEconomy_speaker_terminal_0",
    appliances_com_01_55 = "MinidoracatEconomy_speaker_terminal_3",
    security_01_1 = "MinidoracatEconomy_speaker_terminal_1",
    security_01_2 = "MinidoracatEconomy_speaker_terminal_2",
}) do
    if Rl.radioSprite(tile) ~= speaker then wrong[#wrong + 1] = tile end
end
check(#wrong == 0, "every registered terminal tile maps to its own speaker set and keeps its facing")

-- 舊版本存檔留下來的大 HAM：所有權是 deviceName，所以它仍然是我們的，但外觀已經不是現在要的
-- 那組——走既有的 remove(false) + add 換成喇叭，數量恆為一，旁邊玩家自己那台 HAM 不准被牽連。
local stale = owned(820, 130, 0)[1]
stale:setSprite({ getName = function() return "appliances_com_01_3" end })
local mine = place(820, 130, 0, fakeWorldRadio("appliances_com_01_3"))
sweep()
local swapped = owned(820, 130, 0)[1]
check(#owned(820, 130, 0) == 1 and stale.removed == true and swapped.serial ~= stale.serial
    and TR.isOwned(swapped) == true and mine.removed == nil
    and swapped:getSprite():getName() == "MinidoracatEconomy_speaker_catgirl_3"
    and Rl.state(820, 130, 0) == "active",
    "a device saved with the old large ham sprite is swapped for the speaker, and the player's own ham beside it stays")

-- 缺 tiledef 時 getSprite 仍可能回非 nil placeholder；必須拒絕建造。
-- 這不是 client pack/GPU 載入證據，後者由原生解碼與實機畫面分別驗證。
worldSpriteDeny["MinidoracatEconomy_speaker_catgirl_3"] = true
swapped:getDeviceData():setTurnedOnRaw(false)
sweep()
check(#owned(820, 130, 0) == 0 and swapped.removed == true and mine.removed == nil
    and Rl.state(820, 130, 0) == "error",
    "with the speaker tile not loaded the build fails: no fallback to the large ham and no invisible device")
worldSpriteDeny["MinidoracatEconomy_speaker_catgirl_3"] = nil
sweep()

-- Load callbacks retain repair throttling, ownership and diagnosable failures.
do
local logs = {}
local realLog = EC.log
EC.log = function(m) logs[#logs + 1] = tostring(m) end
local function logged(text)
    for _, m in ipairs(logs) do if string.find(m, text, 1, true) then return true end end
    return false
end
local realCell = getCell
local fakeSquares = {}
getCell = function()
    return { getGridSquare = function(_, x, y, z)
        return fakeSquares[worldKey(x, y, z)] or realCell():getGridSquare(x, y, z)
    end }
end
local function fakeSquare(x, y, objects, mode)
    local sq = { __class = "IsoGridSquare" }
    sq.getX = function() return x end
    sq.getY = function() return y end
    sq.getZ = function() return 0 end
    sq.getObjects = function()
        return {
            size = function() return #objects end,
            get = function(_, i)
                if mode == "get" then error("native object list get threw", 0) end
                return objects[i + 1]
            end,
        }
    end
    sq.transmitRemoveItemFromSquare = function() return 0 end
    sq.RecalcProperties = function() end
    sq.RecalcAllWithNeighbours = function() end
    fakeSquares[worldKey(x, y, 0)] = sq
    return sq
end

worldSprites["640,240,0"] = "MinidoracatEconomy_terminal_1"
SandboxVars.MinidoracatEconomy.RadioRelayEnabled = false
local cold = cmd(boss, "terminal.register", { x = 640, y = 240, z = 0, kind = "trade" })
check(cold.ok == true and cold.warning == nil and #owned(640, 240, 0) == 0
    and Rl.state(640, 240, 0) == "disabled",
    "a terminal registered while the relay is off is registered with no device and no repair stamp")
SandboxVars.MinidoracatEconomy.RadioRelayEnabled = true
fire("LoadGridsquare", square(640, 240, 0))
local built = owned(640, 240, 0)[1]
check(#owned(640, 240, 0) == 1 and Rl.state(640, 240, 0) == "active"
    and built:getSprite():getName() == "MinidoracatEconomy_speaker_terminal_1"
    and built:getDeviceData():getChannel() == 101100
    and built:getDeviceData():getIsTurnedOn() == true,
    "the first chunk load of a registered terminal that was never built puts a configured device up at once")
worldObjects["640,240,0"] = {}                      -- chunk 卸載：裝置跟著世界走了
nowMs = nowMs + Rl.REPAIR_MS - 1
fire("LoadGridsquare", square(640, 240, 0))
check(#owned(640, 240, 0) == 0 and Rl.state(640, 240, 0) == "waiting",
    "a chunk load inside the repair window rebuilds nothing and reports not ready: loading is not a way around the rate limit")
nowMs = nowMs + 1                                   -- 剛好踩到界線
fire("LoadGridsquare", square(640, 240, 0))
local relit = owned(640, 240, 0)[1]
check(#owned(640, 240, 0) == 1 and relit ~= nil and relit.serial ~= built.serial
    and Rl.state(640, 240, 0) == "active",
    "the same chunk load does build once the repair window has passed")
SandboxVars.MinidoracatEconomy.RadioRelayEnabled = false
fire("LoadGridsquare", square(640, 240, 0))
check(#owned(640, 240, 0) == 0 and relit.removed == true and Rl.state(640, 240, 0) == "disabled",
    "a chunk load while the relay is off takes the registered square's device away instead of putting one back")
SandboxVars.MinidoracatEconomy.RadioRelayEnabled = true

worldLoaded["641,241,0"] = true
local keepA = place(641, 241, 0, fakeWorldRadio("appliances_com_01_1", "both"))
local o1 = place(641, 241, 0, ownedRadio("appliances_com_01_1"))
local keepB = place(641, 241, 0, fakeWorldRadio("appliances_com_01_1"))
local o2 = place(641, 241, 0, ownedRadio("MinidoracatEconomy_speaker_terminal_1"))
fire("LoadGridsquare", square(641, 241, 0))
check(#owned(641, 241, 0) == 0 and o1.removed == true and o2.removed == true
    and keepA.removed == nil and keepB.removed == nil
    and #(worldObjects["641,241,0"] or {}) == 2,
    "an unregistered square loses every owned device it carries, whatever their sprites, and both vanilla radios stay")

local scanned = place(641, 241, 0, ownedRadio("appliances_com_01_1"))
local blind = place(641, 241, 0, {
    __class = "IsoRadio",
    getDeviceData = function() error("native DeviceData getter threw", 0) end,
})
fire("LoadGridsquare", square(641, 241, 0))
check(scanned.removed == nil and keepA.removed == nil and keepB.removed == nil
    and #(worldObjects["641,241,0"] or {}) == 4 and logged("native DeviceData getter threw"),
    "a device-data getter that raised aborts the pass before anything is removed: the owned device ahead of it is not deleted mid-scan")
table.remove(worldObjects["641,241,0"])             -- 那台讀不到的物件離開了格子
fire("LoadGridsquare", square(641, 241, 0))
check(scanned.removed == true and #owned(641, 241, 0) == 0
    and keepA.removed == nil and keepB.removed == nil,
    "the same load deletes the orphan once the object that could not be read is gone")

local survivor = place(641, 241, 0, ownedRadio("appliances_com_01_1"))
worldFault.getObjects = "native getObjects threw"
fire("LoadGridsquare", square(641, 241, 0))
check(survivor.removed == nil and #owned(641, 241, 0) == 1
    and worldFault.getObjects == nil and logged("native getObjects threw"),
    "a square whose object list could not be read is reported with the engine's own text, not treated as an empty square")
worldFault.removeItem = "native removal threw"
fire("LoadGridsquare", square(641, 241, 0))
check(survivor.removed == nil and #owned(641, 241, 0) == 1
    and worldFault.removeItem == nil and logged("native removal threw"),
    "an orphan removal that raised leaves the orphan visible and says so instead of counting the square as cleaned")
worldRemoveRefuses[survivor] = true
local beforeRefuse = #logs
fire("LoadGridsquare", square(641, 241, 0))
check(survivor.removed == nil and #owned(641, 241, 0) == 1 and #logs > beforeRefuse
    and keepA.removed == nil and keepB.removed == nil,
    "a removal the engine refused with -1 is diagnosed rather than believed, and takes no vanilla radio with it")
worldRemoveRefuses[survivor] = nil
fire("LoadGridsquare", square(641, 241, 0))
check(survivor.removed == true and #owned(641, 241, 0) == 0
    and keepA.removed == nil and keepB.removed == nil,
    "the orphan is collected by the next load once the engine really removes it: a failed pass loses no orphan")
local lied = ownedRadio("appliances_com_01_1")
local lieMate = fakeWorldRadio("appliances_com_01_1")
local beforeLie = #logs
fire("LoadGridsquare", fakeSquare(642, 242, { lieMate, lied }, "lie"))
check(lied.removed == nil and lieMate.removed == nil and #logs > beforeLie,
    "a removal that answered with a success index while the object is still on the square is a failure, not a cleanup")
local getOwned = ownedRadio("appliances_com_01_1")
local beforeGet = #logs
fire("LoadGridsquare", fakeSquare(643, 243, { getOwned }, "get"))
check(getOwned.removed == nil and #logs > beforeGet and logged("native object list get threw"),
    "an object list whose get raised mid-scan removes nothing and is reported")
getCell = realCell
EC.log = realLog
end

SandboxVars.MinidoracatEconomy.RadioIntervalMinutes = nil
SandboxVars.MinidoracatEconomy.RadioFrequency = nil
SandboxVars.MinidoracatEconomy.RadioRange = nil
SandboxVars.MinidoracatEconomy.RadioRelayEnabled = nil
worldSprites, worldObjects, worldLoaded, worldSpriteDeny = {}, {}, {}, {}
worldRemoveRefuses, worldFault, worldRemoveRefuseAll = {}, {}, false
onlinePlayers = {}
end)()

;(function()
    local player = fakePlayer("atm-protection")
    local function object(name)
        local obj = { removed = false }
        local sq = { transmitRemoveItemFromSquare = function(_, target) target.removed = true end }
        obj.getSprite = function() return { getName = function() return name end } end
        obj.getSquare = function() return sq end
        return obj
    end
    for i = 64, 67 do
        local atm = object("location_business_bank_01_" .. i)
        local action = { character = player, item = atm }
        check(not ISDestroyStuffAction.isValid(action) and not ISDestroyStuffAction.complete(action) and not atm.removed,
            "native ATM " .. i .. " refuses both sledgehammer admission and server completion")
        local props = { object = atm }
        local result, chance = ISMoveableSpriteProps.canScrapObject(props, player)
        check(not result.canScrap and chance == 0
            and ISMoveableSpriteProps.scrapObjectInternal(props, player, {}, atm:getSquare(), atm, {}, 100, nil) == 0
            and not atm.removed, "native ATM " .. i .. " refuses scrap without removing the object or producing loot")
    end
    player.role = "admin"
    local atm = object("location_business_bank_01_64")
    local action = { character = player, item = atm }
    check(ISDestroyStuffAction.isValid(action) and ISDestroyStuffAction.complete(action) and atm.removed,
        "authorized administrator retains native sledgehammer removal")
    atm = object("location_business_bank_01_65")
    check(ISMoveableSpriteProps.canScrapObject({ object = atm }, player).canScrap
        and ISMoveableSpriteProps.scrapObjectInternal({}, player, {}, atm:getSquare(), atm, {}, 100, nil) == 3
        and atm.removed, "authorized administrator retains native scrap result and removal")
    player.role = "user"
    local cabinet = object("appliances_com_01_52")
    check(ISDestroyStuffAction.complete({ character = player, item = cabinet }) and cabinet.removed,
        "ATM protection does not change unrelated furniture removal")
    player.role = "admin"
    atm = object("location_business_bank_01_64")
    action = { character = player, item = atm }
    local admitted = ISDestroyStuffAction.isValid(action)
    player.role = "user"
    check(admitted and not ISDestroyStuffAction.complete(action) and not atm.removed,
        "revoking permission while queued prevents ATM removal at completion")
    player.role = "admin"; player.caps[Capability.AddItem] = false
    check(not ISDestroyStuffAction.complete(action) and not atm.removed,
        "an admin role without AddItem cannot remove an ATM")
    local previousOverride = EC.optionOverride
    EC.optionOverride = function(key)
        if key == "AdminRoles" then return { "ATM Keeper" } end
        return previousOverride and previousOverride(key)
    end
    player.role = "ATM Keeper"; player.caps[Capability.AddItem] = true
    check(ISDestroyStuffAction.complete(action) and atm.removed,
        "configured custom administrator role retains exact-name ATM removal")
    EC.optionOverride = previousOverride
    check(EC.AtmProtection.blocked(nil, object("location_business_bank_01_67")),
        "missing actor never grants ATM removal permission")
end)()

;(function()
    modDataStore[EC.MODDATA_KEY] = nil
    files, sentCommands, worldObjects = {}, {}, {}
    worldSprites = { ["100,200,0"] = "location_business_bank_01_64" }
    nowMs = nowMs + 61000
    fire("OnServerStarted")
    local boss, player = fakePlayer("atm-owner"), fakePlayer("atm-user")
    boss.role = "admin"
    player.x, player.y, player.z = 101, 200, 0
    onlinePlayers = { boss, player }
    local T, Shop = S.Terminal, S.Shop
    local atm = { removed = false }
    local square = { transmitRemoveItemFromSquare = function(_, obj) obj.removed = true end }
    atm.getSprite = function() return { getName = function() return "location_business_bank_01_64" end } end
    atm.getSquare = function() return square end
    local action = { character = player, item = atm }
    local function option(who, key, value)
        nowMs = nowMs + 700
        fire("OnClientCommand", EC.COMMAND_MODULE, "admin.option", who,
            { key = key, value = value, requestId = "atm-option-" .. nowMs })
        return lastSent("admin.option").args
    end
    check(T.near(player) and not ISDestroyStuffAction.complete(action) and not atm.removed,
        "map ATMs default to usable terminals protected from ordinary removal")
    check(option(player, "MapATMAsTerminal", false).error == "forbidden" and T.near(player),
        "ordinary players cannot disable automatic ATM access")
    check(option(player, "MapATMAllowDestruction", true).error == "forbidden"
        and not ISDestroyStuffAction.complete(action), "ordinary players cannot grant themselves ATM removal")
    check(option(boss, "MapATMAsTerminal", "false").error == "invalid_args" and T.near(player),
        "ATM access rejects string booleans")
    local reply = option(boss, "MapATMAsTerminal", false)
    check(reply.ok and reply.options.MapATMAsTerminal.value == false and not T.near(player),
        "administrator disabling ATM access changes the server gate immediately")
    check(lastSent("config").args.options.MapATMAsTerminal.value == false,
        "live ATM access denial is published to connected clients")
    check(not ISDestroyStuffAction.complete(action) and not atm.removed,
        "disabling ATM access does not disable its independent protection")
    L.credit("atm-user", "survivor", 100, "SYSTEM_MINT", { requestId = "atm-settings-seed", reasonCode = "t" })
    nowMs = nowMs + 700
    fire("OnClientCommand", EC.COMMAND_MODULE, "shop.buy", player,
        { id = "bandage", currency = "survivor", revision = Shop.revision(), requestId = "atm-disabled-buy" })
    check(lastSent("shop.buy").args.error == "not_at_terminal"
        and L.getBalance("atm-user", "survivor").available == 100 and player.inventory.count("Base.Bandage") == 0,
        "disabled ATM refuses a real purchase without charging or delivering")
    check(option(boss, "MapATMAllowDestruction", true).ok and not T.near(player)
        and ISDestroyStuffAction.complete(action) and atm.removed,
        "removal can be opened while ATM access remains disabled")
    atm.removed = false
    check(ISMoveableSpriteProps.canScrapObject({ object = atm }, player).canScrap
        and ISMoveableSpriteProps.scrapObjectInternal({}, player, {}, square, atm, {}, 100, nil) == 3 and atm.removed,
        "open removal reaches the original furniture scrap result")
    atm.removed = false
    local admitted = ISDestroyStuffAction.isValid(action)
    check(option(boss, "MapATMAllowDestruction", false).ok and admitted
        and not ISDestroyStuffAction.complete(action) and not atm.removed,
        "closing removal blocks an action admitted before the setting changed")
    worldSprites["100,200,0"] = "MinidoracatEconomy_terminal_0"
    nowMs = nowMs + 700
    fire("OnClientCommand", EC.COMMAND_MODULE, "terminal.register", boss, { x = 100, y = 200, z = 0 })
    local registered = lastSent("terminal.register").args
    check(registered.ok and T.near(player), "disabling map ATMs leaves registered custom terminals usable")
    nowMs = nowMs + 700
    fire("OnClientCommand", EC.COMMAND_MODULE, "terminal.demolish", player, { x = 100, y = 200, z = 0 })
    check(lastSent("terminal.demolish").args.error == "forbidden", "ATM settings do not grant custom-terminal demolition")
    nowMs = nowMs + 700
    fire("OnClientCommand", EC.COMMAND_MODULE, "terminal.unregister", boss, { id = registered.id })
    worldSprites["100,200,0"] = "location_business_bank_01_64"
    check(option(boss, "MapATMAsTerminal", nil).ok and T.near(player),
        "resetting ATM access restores the sandbox default")
    check(option(boss, "MapATMAllowDestruction", nil).ok and not ISDestroyStuffAction.complete(action),
        "resetting ATM removal restores protected default")
    check(option(boss, "MapATMAllowDestruction", 1).error == "invalid_args",
        "ATM removal rejects numeric booleans")
    check(option(boss, "MapATMAsTerminal", false).ok and option(boss, "MapATMAllowDestruction", true).ok,
        "both independent overrides can be stored together")
    nowMs = nowMs + 61000
    fire("OnServerStarted")
    check(not T.near(player) and ISDestroyStuffAction.complete(action) and atm.removed,
        "reinitialization preserves both stored ATM overrides")
    onlinePlayers, worldSprites = {}, {}
end)()

-- ===== 情境 LC：每人永久限購（第三種互斥模式）=====
-- 永久份數不回補舊日桶、不因模式／角色／換季而清零；回滾沿用同一份世界資料。
-- 本段新增 25 個 check；事件 writer 使用 harness 記憶體檔，不代表原生落盤驗證。
io.write("scenario LC: a lifetime cap belongs to the account, not to the day\n")
;(function()
local Shop, M = S.Shop, S.Mailbox
local DAY = 86400000
modDataStore[EC.MODDATA_KEY] = nil
files, sentCommands, writerDeny = {}, {}, {}
-- 對齊到獎勵日開始後一小時：整段前半要留在同一個獎勵日內，不能剛好壓在日界上
nowMs = R.nextResetMs(nowMs) + 3600000
-- 部署現場：這個世界的舊版只記每日份數，永久表還不存在
modDataStore[EC.MODDATA_KEY] = { shopDaily = { [R.dayKey(nowMs)] = { ["lc-zed"] = { keepsake = 4 } } } }
files[Shop.FILE] = { lines = { EC.jsonEncode({ items = {
    { id = "keepsake", item = "Base.Bandage", qty = 1, dailyCap = 3, dailyCapScope = "lifetime", category = "medical",
        prices = { survivor = { price = 10 }, cat = { price = 4 } } },
    { id = "ration", item = "Base.Nails", qty = 1, dailyCap = 2, category = "food",
        prices = { survivor = { price = 5 } } },
    { id = "sand", item = "Base.RippedSheets", qty = 1, dailyCap = 0, category = "medical",
        prices = { survivor = { price = 5 } } },
    { id = "crate", item = "Base.Plank", qty = 3, dailyCap = 2, dailyCapScope = "lifetime", category = "tool",
        prices = { survivor = { price = 30 } } },
} }) }, opens = 0 }
fire("OnServerStarted")
worldSprites = { ["100,200,0"] = "MinidoracatEconomy_terminal_0" }
local boss = fakePlayer("lc-admin"); boss.role = "admin"
local zed = fakePlayer("lc-zed"); zed.x, zed.y = 101, 200; zed.inventory = fakeInventory(400)
local kit = fakePlayer("lc-kit"); kit.x, kit.y = 101, 200; kit.inventory = fakeInventory(400)
onlinePlayers = { boss, zed, kit }
local function cmd(who, name, args)
    nowMs = nowMs + 600
    args = args or {}
    args.requestId = args.requestId or (name .. nowMs)
    withCurrency(name, args)
    fire("OnClientCommand", EC.COMMAND_MODULE, name, who, args)
    local s = lastSent(name)
    return s and s.args or {}
end
-- 從事件 writer 輸出的 harness 記憶體檔解碼，不採用 command 回覆當寫檔證據。
local function purchases(username, sku)
    proofSettle()
    local out = {}
    for _, f in pairs(files) do
        for _, line in ipairs(f.lines or {}) do
            if string.find(line, '"type":"shop.purchase"', 1, true) then
                local row = EC.jsonDecode(line)
                if type(row) == "table" and row.username == username and row.sku == sku then out[#out + 1] = row end
            end
        end
    end
    return out
end
local function rowOf(snapshot, id)
    for _, it in ipairs(snapshot.items or {}) do if it.id == id then return it end end
    return nil
end
cmd(boss, "terminal.register", { x = 100, y = 200, z = 0, kind = "atm" })
L.credit("lc-zed", "survivor", 500, "SYSTEM_MINT", { requestId = "lc-seed-s", reasonCode = "t" })
L.credit("lc-zed", "cat", 50, "SYSTEM_MINT", { requestId = "lc-seed-c", reasonCode = "t" })
L.credit("lc-kit", "survivor", 500, "SYSTEM_MINT", { requestId = "lc-seed-k", reasonCode = "t" })
check(Shop.sku("keepsake").dailyCapScope == "lifetime" and Shop.used("lc-zed", "keepsake", nowMs) == 0,
    "a lifetime count starts at zero even in a world where the previous version already wrote day rows")
local toDaily = cmd(boss, "admin.catalog", { action = "set", id = "keepsake", dailyCapScope = "player", revision = Shop.revision() })
local dayView = Shop.used("lc-zed", "keepsake", nowMs)
local back = cmd(boss, "admin.catalog", { action = "set", id = "keepsake", dailyCapScope = "lifetime", revision = Shop.revision() })
check(toDaily.ok and back.ok and dayView == 4 and Shop.used("lc-zed", "keepsake", nowMs) == 0,
    "the day rows the old version wrote are still the daily count and are never adopted as a lifetime head start")
local buyRev = Shop.revision()
local first = cmd(zed, "shop.buy", { id = "keepsake", count = 2, currency = "survivor", revision = buyRev, requestId = "lc-first" })
check(first.ok and first.used == 2 and first.remaining == 1 and zed.inventory.count("Base.Bandage") == 2,
    "the buy reply answers with this account's lifetime shares and the room that is left")
local kitBuy = cmd(kit, "shop.buy", { id = "keepsake", count = 3, currency = "survivor", revision = buyRev, requestId = "lc-kit-fill" })
check(kitBuy.ok and kitBuy.used == 3 and kitBuy.remaining == 0 and Shop.used("lc-zed", "keepsake", nowMs) == 2,
    "one account spending its whole lifetime allowance leaves another account's allowance untouched")
local paidInCat = cmd(zed, "shop.buy", { id = "keepsake", currency = "cat", revision = buyRev, requestId = "lc-cat" })
check(paidInCat.ok and paidInCat.currency == "cat" and paidInCat.used == 3 and paidInCat.remaining == 0
    and L.getBalance("lc-zed", "cat").available == 46,
    "the last lifetime share can be paid in another currency: the allowance belongs to the row, not to the wallet")
local surBefore, catBefore = L.getBalance("lc-zed", "survivor").available, L.getBalance("lc-zed", "cat").available
local mailBefore = M.unclaimed("lc-zed")
local over = cmd(zed, "shop.buy", { id = "keepsake", currency = "survivor", revision = buyRev, requestId = "lc-over" })
check(over.error == "lifetime_cap" and over.used == 3 and over.remaining == 0
    and L.getBalance("lc-zed", "survivor").available == surBefore
    and L.getBalance("lc-zed", "cat").available == catBefore
    and M.unclaimed("lc-zed") == mailBefore and zed.inventory.count("Base.Bandage") == 3,
    "an exhausted lifetime cap has its own refusal code, charges neither wallet and posts no letter")
check(lastSent("shop.stock") == nil,
    "one account's personal allowance is never broadcast to the whole server as shared stock")
local replay = cmd(zed, "shop.buy", { id = "keepsake", count = 2, currency = "survivor", revision = buyRev, requestId = "lc-first" })
local keepRows = purchases("lc-zed", "keepsake")
check(replay.duplicate == true and replay.used == 3 and #keepRows == 2
    and keepRows[2].capScope == "lifetime" and keepRows[2].cap == 3
    and keepRows[2].usedAfter == 3 and keepRows[2].lifetimeUsed == 3,
    "a resend is answered from the record: one share, one published purchase, and the event names the mode, the limit and the totals")
cmd(zed, "shop.buy", { id = "ration", count = 2, currency = "survivor", revision = buyRev, requestId = "lc-ration" })
local rationRows = purchases("lc-zed", "ration")
check(#rationRows == 1 and rationRows[1].capScope == "player" and rationRows[1].cap == 2
    and rationRows[1].usedAfter == 2 and rationRows[1].lifetimeUsed == 2,
    "a sale under a daily cap publishes that day's total and the account's lifetime total side by side")
local rationLife = cmd(boss, "admin.catalog", { action = "set", id = "ration", dailyCapScope = "lifetime", revision = Shop.revision() })
local rationBlocked = cmd(zed, "shop.buy", { id = "ration", currency = "survivor", revision = Shop.revision(), requestId = "lc-ration-2" })
check(rationLife.ok and Shop.used("lc-zed", "ration", nowMs) == 2 and rationBlocked.error == "lifetime_cap",
    "shares sold while the row was a daily row are already counted the moment it becomes a lifetime row")
cmd(zed, "shop.buy", { id = "sand", count = 4, currency = "survivor", revision = Shop.revision(), requestId = "lc-sand" })
local snap = cmd(zed, "shop.list", {})
local sandRow, keepRow = rowOf(snap, "sand"), rowOf(snap, "keepsake")
local sandRows = purchases("lc-zed", "sand")
check(sandRow.used == 4 and sandRow.remaining == nil and keepRow.used == 3 and keepRow.remaining == 0
    and #sandRows == 1 and sandRows[1].cap == 0 and sandRows[1].lifetimeUsed == 4,
    "an unlimited row publishes what the account bought with no room figure at all, and is still counted for good")
local lowered = cmd(boss, "admin.catalog", { action = "set", id = "sand", dailyCapScope = "lifetime", dailyCap = 3, revision = Shop.revision() })
local past = cmd(zed, "shop.buy", { id = "sand", currency = "survivor", revision = Shop.revision(), requestId = "lc-sand-2" })
check(lowered.ok and Shop.used("lc-zed", "sand", nowMs) == 4
    and past.error == "lifetime_cap" and past.used == 4 and past.remaining == 0,
    "a limit set below what an account already bought refuses the next share instead of clearing the count")
local batch = cmd(boss, "admin.catalog", { action = "batch", ids = { "keepsake", "crate" },
    fields = { qty = 4, dailyCap = 5, dailyCapScope = "lifetime" }, revision = Shop.revision() })
check(batch.ok and Shop.sku("keepsake").qty == 4 and Shop.sku("crate").dailyCapScope == "lifetime"
    and Shop.sku("crate").dailyCap == 5 and Shop.used("lc-zed", "keepsake", nowMs) == 3,
    "a batch that rewrites all three limit columns hands nobody the shares they already spent back")
local off = cmd(boss, "admin.catalog", { action = "set", id = "keepsake", enabled = false, revision = Shop.revision() })
local on = cmd(boss, "admin.catalog", { action = "set", id = "keepsake", enabled = true, revision = Shop.revision() })
check(off.ok and on.ok and Shop.used("lc-zed", "keepsake", nowMs) == 3,
    "taking the row off the shelf and putting it back on is not a reset either")
local away = cmd(boss, "admin.catalog", { action = "set", id = "keepsake", dailyCapScope = "player", revision = Shop.revision() })
local dailySide = Shop.used("lc-zed", "keepsake", nowMs)
local home = cmd(boss, "admin.catalog", { action = "set", id = "keepsake", dailyCapScope = "lifetime", revision = Shop.revision() })
check(away.ok and home.ok and dailySide == 7 and Shop.used("lc-zed", "keepsake", nowMs) == 3,
    "every purchase writes both counters: a mode round trip reads its own number and clears neither")
local crateRev = Shop.revision()
zed.inventory.maxWeight = 0
local refusedMail = cmd(zed, "shop.buy", { id = "crate", currency = "survivor", revision = crateRev, requestId = "lc-crate" })
local parked = cmd(zed, "shop.buy", { id = "crate", currency = "survivor", revision = crateRev, requestId = "lc-crate", acceptMail = true })
check(refusedMail.error == "mail_confirmation_required" and refusedMail.used == 0
    and parked.ok and parked.mailed == true and parked.used == 1,
    "a purchase refused for capacity spends nothing, while the one parked in the mailbox spends its lifetime share immediately")
zed.inventory.maxWeight = 400
local claimed = cmd(zed, "mail.claim", { mailId = parked.mailId })
check(claimed.ok and zed.inventory.count("Base.Plank") == 4 and Shop.used("lc-zed", "crate", nowMs) == 1,
    "collecting the letter hands the goods over without spending a second share")
nowMs = nowMs + 2 * DAY
local newDay = cmd(zed, "shop.buy", { id = "ration", currency = "survivor", revision = Shop.revision(), requestId = "lc-newday" })
check(Shop.used("lc-zed", "keepsake", nowMs) == 3 and Shop.used("lc-zed", "ration", nowMs) == 2
    and newDay.error == "lifetime_cap",
    "two reward days later a lifetime row is still exhausted: no day boundary hands the allowance back")
nowMs = nowMs + 1000
fire("OnServerStarted")
check(Shop.used("lc-zed", "keepsake", nowMs) == 3 and Shop.used("lc-kit", "keepsake", nowMs) == 3
    and Shop.used("lc-zed", "sand", nowMs) == 4,
    "reinitialisation reads every account's lifetime counts back out of the world's own data")
zed.dead = true
fire("OnCharacterDeath", zed)
local reborn = fakePlayer("lc-zed"); reborn.x, reborn.y = 101, 200; reborn.inventory = fakeInventory(400)
onlinePlayers = { boss, reborn, kit }
fire("OnNewGame", reborn)
local rebornRow = rowOf(cmd(reborn, "shop.list", {}), "keepsake")
check(rebornRow.used == 3 and rebornRow.remaining == 2,
    "a brand new character on the same account inherits the shares that account already spent")
zed = reborn
local seasonBefore = S.Seasons.currentId()
local rotated = cmd(boss, "admin.seasons", { action = "start", expectedSeason = seasonBefore, reason = "quota isolation" })
check(rotated.ok and S.Seasons.currentId() ~= seasonBefore and Shop.used("lc-zed", "keepsake", nowMs) == 3,
    "a real season rotation leaves this account's lifetime purchase allowance unchanged")
-- 只還原 harness 的假 ModData 世界表（不是原生存檔）：世界回到購買前，錢與份數必須一起回去
local worldBefore = proofSnapshot()
local balBefore = L.getBalance("lc-zed", "survivor").available
local extra = cmd(zed, "shop.buy", { id = "keepsake", currency = "survivor", revision = Shop.revision(), requestId = "lc-extra" })
local spentAfter = L.getBalance("lc-zed", "survivor").available
proofRestartFrom(worldBefore)
check(extra.ok and extra.used == 4 and spentAfter == balBefore - 10
    and Shop.used("lc-zed", "keepsake", nowMs) == 3
    and L.getBalance("lc-zed", "survivor").available == balBefore,
    "a world rolled back to before a purchase takes the lifetime share back together with the money")
local added = cmd(boss, "admin.catalog", { action = "add", id = "relic", item = "Base.Twine", qty = 1,
    dailyCap = 1, dailyCapScope = "lifetime", category = "other",
    prices = { survivor = { price = 6 } }, revision = Shop.revision() })
local once = cmd(zed, "shop.buy", { id = "relic", currency = "survivor", revision = Shop.revision(), requestId = "lc-relic" })
local twice = cmd(zed, "shop.buy", { id = "relic", currency = "survivor", revision = Shop.revision(), requestId = "lc-relic-2" })
check(added.ok and Shop.sku("relic").dailyCapScope == "lifetime" and once.ok and once.remaining == 0
    and twice.error == "lifetime_cap" and zed.inventory.count("Base.Twine") == 1,
    "a row added as a lifetime row sells exactly once per account from the moment it appears")
local disk = table.concat(files[Shop.FILE].lines, "\n")
local badSet = cmd(boss, "admin.catalog", { action = "set", id = "keepsake", dailyCapScope = "server", revision = Shop.revision() })
local badBatch = cmd(boss, "admin.catalog", { action = "batch", ids = { "keepsake", "crate" },
    fields = { dailyCapScope = "daily" }, revision = Shop.revision() })
check(badSet.error == "invalid_args" and badBatch.error == "invalid_args"
    and Shop.sku("keepsake").dailyCapScope == "lifetime"
    and table.concat(files[Shop.FILE].lines, "\n") == disk,
    "there are exactly three modes: an invented scope is refused by the single edit and by the batch without touching the file")
files[Shop.FILE] = { lines = { EC.jsonEncode({ items = {
    { id = "keepsake", item = "Base.Bandage", qty = 1, dailyCap = 1, dailyCapScope = "daily",
        prices = { survivor = { price = 10 } } },
} }) }, opens = 0 }
local reload = cmd(boss, "admin.catalog", { action = "reload" })
check(reload.error == "catalog_invalid" and Shop.sku("keepsake").dailyCap == 5
    and Shop.sku("keepsake").dailyCapScope == "lifetime" and Shop.used("lc-zed", "keepsake", nowMs) == 3,
    "a catalog file naming a mode the shop does not have keeps the previous rows instead of becoming unlimited")
onlinePlayers = {}
end)()

-- ===== 累積在線簽到：晚領不推遲門檻，設定即時重算且不重發 =====
io.write("scenario cumulative check-in: late claims, live settings and payment boundaries\n")
;(function()
modDataStore[EC.MODDATA_KEY] = nil
files, sentCommands = {}, {}
SandboxVars.MinidoracatEconomy.RewardDayResetHour = 0
SandboxVars.MinidoracatEconomy.RewardTimezoneUTC = 8
SandboxVars.MinidoracatEconomy.CheckinAmount = 30
SandboxVars.MinidoracatEconomy.CheckinMinPlaytimeMinutes = 15
SandboxVars.MinidoracatEconomy.CheckinDailyLimit = 2
SandboxVars.MinidoracatEconomy.CheckinIntervalMinutes = 60
SandboxVars.MinidoracatEconomy.CheckinServerDailyCap = 0
nowMs = R.dayStartMs(1788699986478) + 3600000
fire("OnServerStarted")
local late, waiting, boss = fakePlayer("cum-late"), fakePlayer("cum-waiting"), fakePlayer("cum-admin")
boss.role = "admin"
onlinePlayers = { late, waiting, boss }
R.observe(late, nowMs)
R.observe(waiting, nowMs)
local serial = 0
local function cmd(player, name, args)
    serial = serial + 1
    args = args or {}
    args.requestId = args.requestId or ("cum-" .. serial)
    S.handlers[name](player, args)
    return lastSent(name).args
end
local function take(player, index)
    return cmd(player, "rewards.checkin", { day = R.dayKey(nowMs), rewardIndex = index })
end
local function option(key, value)
    return cmd(boss, "admin.option", { key = key, value = value })
end
local function tick(minutes)
    for _ = 1, minutes do nowMs = nowMs + 60000; fire("OnTickEvenPaused") end
end
tick(39)
local first = take(late, 1)
check(first.ok and first.state.requiredOnlineMs == 60 * 60000
    and first.state.remainingOnlineMs == 21 * 60000,
    "claiming the first reward at minute 39 leaves 21 minutes, not another hour")
-- 舊存檔的領取基準不再控制資格；重新初始化不能丟失當日時間或已領次數。
S.modData().claims["cum-late"].claimBasePlayedMs = 39 * 60000
fire("OnServerStarted")
local resumed = cmd(late, "rewards.state")
check(resumed.claimedCount == 1 and resumed.playedMs == 39 * 60000
    and resumed.requiredOnlineMs == 60 * 60000,
    "reinitialising an old interval record preserves progress but no longer postpones its next reward")
local lookup = cmd(boss, "admin.lookup", { username = "cum-late" })
check(lookup.ok and lookup.rewards.requiredOnlineMs == resumed.requiredOnlineMs,
    "the administrative read-only view uses the same cumulative threshold as the player")
R.observe(waiting, nowMs)
tick(21)
local deferredFirst, deferredSecond = take(waiting, 1), take(waiting, 2)
check(deferredFirst.ok and deferredFirst.state.canClaim and deferredSecond.ok
    and L.getBalance("cum-waiting", "survivor").available == 60,
    "at minute 60 a player who never claimed can take both earned rewards in order")
local replay, excess = take(waiting, 1), take(waiting, 3)
check(replay.error == "stale_request" and excess.error == "daily_limit_reached"
    and L.getBalance("cum-waiting", "survivor").available == 60,
    "banked eligibility neither replays a paid index nor bypasses the daily limit")
local raised = option("CheckinIntervalMinutes", 120)
local pushed = lastSent("rewards.state").args
check(raised.ok and pushed.intervalMs == 120 * 60000
    and R.state("cum-late", nowMs).remainingOnlineMs == 60 * 60000,
    "raising the cumulative step updates live snapshots and the unpaid threshold immediately")
check(take(late, 2).error == "interval_not_elapsed" and L.getBalance("cum-late", "survivor").available == 30,
    "an already open claim is checked against the new longer step without consuming it")
local lowered = option("CheckinIntervalMinutes", 30)
local second = take(late, 2)
check(lowered.ok and second.ok and second.state.requiredOnlineMs == 60 * 60000
    and L.getBalance("cum-late", "survivor").available == 60,
    "lowering the step unlocks the unpaid second reward and keeps the third threshold at twice the step")
local expanded = option("CheckinDailyLimit", 3)
local third = take(late, 3)
check(expanded.ok and third.ok and third.state.claimedCount == 3
    and L.getBalance("cum-late", "survivor").available == 90,
    "raising today's limit exposes an already earned third reward without restarting its clock")
local reduced = option("CheckinDailyLimit", 1)
check(reduced.ok and take(late, 4).error == "daily_limit_reached"
    and L.getBalance("cum-late", "survivor").available == 90,
    "lowering the daily limit neither claws back money nor resets paid indices")
option("CheckinDailyLimit", 3)
local high = fakePlayer("cum-high")
onlinePlayers = { high }
R.observe(high, nowMs)
option("CheckinMinPlaytimeMinutes", 90)
tick(60)
check(take(high, 1).error == "not_enough_playtime",
    "a first threshold above the step remains a real minimum, not a shortcut through later rewards")
tick(30)
local highFirst, highSecond = take(high, 1), take(high, 2)
check(highFirst.ok and highFirst.state.requiredOnlineMs == 90 * 60000 and highSecond.ok,
    "later thresholds never fall below the configured first minimum, and time already earned still counts")
local free = fakePlayer("cum-zero")
onlinePlayers = { free }
R.observe(free, nowMs)
local zero = option("CheckinMinPlaytimeMinutes", 0)
local immediate = take(free, 1)
check(zero.ok and immediate.ok and immediate.state.requiredOnlineMs == 30 * 60000
    and take(free, 2).error == "interval_not_elapsed",
    "zero permits only the first claim at login; the following claim still needs the configured step")
local restored = option("CheckinIntervalMinutes", nil)
check(restored.ok and R.state("cum-zero", nowMs).requiredOnlineMs == 60 * 60000,
    "clearing the runtime override restores the sandbox step rather than a hardcoded threshold")
option("CheckinMinPlaytimeMinutes", 15)
option("CheckinDailyLimit", 2)
onlinePlayers = { late }
R.observe(late, nowMs)
nowMs = R.nextResetMs(nowMs) + 1000
local newDay = cmd(late, "rewards.state")
check(newDay.claimedCount == 0 and newDay.playedMs == 1000 and newDay.requiredOnlineMs == 15 * 60000,
    "a new reward day discards banked eligibility and counts only its own connected time")
check(take(late, 1).error == "not_enough_playtime" and L.getBalance("cum-late", "survivor").available == 90,
    "yesterday's unused online time cannot pay today's first reward")
check(L.conservation("survivor") == 0,
    "cumulative claims and runtime changes preserve ledger conservation")
SandboxVars.MinidoracatEconomy.CheckinDailyLimit = nil
SandboxVars.MinidoracatEconomy.CheckinIntervalMinutes = nil
SandboxVars.MinidoracatEconomy.CheckinAmount = nil
SandboxVars.MinidoracatEconomy.CheckinMinPlaytimeMinutes = nil
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
