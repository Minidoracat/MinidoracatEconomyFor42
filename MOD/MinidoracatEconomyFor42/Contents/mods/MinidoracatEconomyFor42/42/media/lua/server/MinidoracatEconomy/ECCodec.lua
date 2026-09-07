-- MinidoracatEconomyFor42 - listing whitelist + bounded item snapshots (server; spec 12 stage D,
-- 17.1, stage A7).
--
-- The market never stores an InventoryItem (Lua has no ByteBuffer for save/load): a listing keeps a
-- bounded snapshot and the buyer gets a rebuilt item. Only item classes whose rebuild is faithful
-- may be listed, and the host decides which in {cachedir}/Lua/MinidoracatEconomy/whitelist.json
-- (display categories, extra fullTypes, excluded fullTypes, allowed modData keys). Fixed rules on
-- top of the file: no containers / clothing / keys / radios / moveables, no perishable food, no
-- read books, nothing equipped, favourite or broken, and no modData key outside the allowed list
-- (fail closed - a mod that keeps state on the item would lose it in the rebuild).
--
-- Engine references (snapshot 42.20.4-20260826, all exercised in A7):
--   instanceItem                    LuaManager.java:5610-5620
--   getCondition/setCondition       InventoryItem.java:2818-2820
--   getCurrentUses/setCurrentUses   InventoryItem.java:2577-2579 ; DrainableComboItem.java:72-75
--   getAge/setAge                   InventoryItem.java:2629-2631
--   getHaveBeenRepaired/set         InventoryItem.java:3147-3149
--   getModData                      InventoryItem.java:433-437
--   Literature read pages           Literature.java:456
--   FluidContainer Empty/addFluid/getAmount/getPrimaryFluid  FluidContainer.java:867, 921, 558, 792 ; Fluid.Get Fluid.java:99
--   HandWeapon getAllWeaponParts/detachWeaponPart  HandWeapon.java:1690-1692, 1807-1809
--   getCategory (main type) / getDisplayCategory   InventoryItem.java:681-683, 3135-3137
--   script daysTotallyRotten (1e9 = never rots)    Item.java:90-91, 594-596

if not MinidoracatEconomy or not MinidoracatEconomy.Shop then
    require "MinidoracatEconomy/ECShop"
end
local EC = MinidoracatEconomy
local S = EC and EC.Server
local X = EC and EC.Export
if not S or not S.AUTHORITY or not X then
    return
end

EC.Codec = EC.Codec or {}
local Codec = EC.Codec

Codec.FILE = X.ROOT .. "/whitelist.json"
Codec.MODDATA_KEYS_MAX = 8
Codec.MODDATA_VALUE_MAX = 64
Codec.FILE_LINES_MAX = 5000
Codec.NEVER_ROTS = 1000000000
Codec.EXCLUDED_MAIN = { Container = true, Clothing = true, Key = true, Moveable = true, Radio = true, AlarmClock = true, Map = true }
Codec.DEFAULT = {
    categories = {
        "Tool", "ToolWeapon", "Weapon", "WeaponCrafted", "MaterialWeapon", "Material", "Ammo",
        "FirstAid", "Bandage", "Literature", "SkillBook", "Food", "VehicleMaintenance", "Water",
        "WaterContainer", "LightSource", "Camping", "Electronics", "Household", "Cooking", "Gardening",
        "RecipeResource",
    },
    types = {},
    excludeTypes = {},
    modDataKeys = {},
}

local wl = { categories = {}, types = {}, excludeTypes = {}, modDataKeys = {}, loadedAt = 0, error = nil, counts = {} }

-- ---------- file ----------

local function readFile()
    local reader = nil
    local ok = pcall(function() reader = getFileReader(Codec.FILE, false) end)
    if not ok or not reader then return nil end
    local lines = {}
    pcall(function()
        for _ = 1, Codec.FILE_LINES_MAX do
            local line = reader:readLine()
            if line == nil then break end
            lines[#lines + 1] = line
        end
    end)
    pcall(function() reader:close() end)
    return table.concat(lines, "\n")
end

local function writeDefault()
    local writer = nil
    local ok = pcall(function() writer = getFileWriter(Codec.FILE, true, false) end)
    if not ok or not writer then return false end
    local wrote = pcall(function()
        writer:writeln("{")
        writer:writeln('  "categories": ' .. EC.jsonEncode(Codec.DEFAULT.categories) .. ",")
        writer:writeln('  "types": [],')
        writer:writeln('  "excludeTypes": [],')
        writer:writeln('  "modDataKeys": []')
        writer:writeln("}")
    end)
    pcall(function() writer:close() end)
    return wrote
end

local function stringSet(list, field)
    if list == nil then return {}, 0 end
    if type(list) ~= "table" then return nil, field .. " must be an array" end
    local set, n = {}, 0
    for i, v in ipairs(list) do
        if type(v) ~= "string" or v == "" or #v > 128 or string.find(v, "%c") then return nil, field .. "[" .. i .. "] must be a short string" end
        set[v] = true
        n = n + 1
    end
    return set, n
end

function Codec.load()
    local text = readFile()
    if text == nil then
        if not writeDefault() then
            wl.error = "whitelist file unavailable"
            return false, wl.error
        end
        text = readFile() or ""
    end
    local doc, err = EC.jsonDecode(text)
    if doc == nil or type(doc) ~= "table" then
        wl.error = "json: " .. tostring(err or "not an object")
        EC.log("whitelist.json rejected: " .. tostring(wl.error))
        return false, wl.error
    end
    local parsed, counts = {}, {}
    for _, field in ipairs({ "categories", "types", "excludeTypes", "modDataKeys" }) do
        local set, n = stringSet(doc[field], field)
        if set == nil then
            wl.error = n
            EC.log("whitelist.json rejected: " .. tostring(n))
            return false, n
        end
        parsed[field], counts[field] = set, n
    end
    wl.categories, wl.types, wl.excludeTypes, wl.modDataKeys = parsed.categories, parsed.types, parsed.excludeTypes, parsed.modDataKeys
    wl.counts = counts
    wl.loadedAt = EC.now()
    wl.error = nil
    return true
end

function Codec.status()
    return { loadedAt = wl.loadedAt, error = wl.error, counts = wl.counts, path = Codec.FILE }
end

-- ---------- item introspection (every call guarded: the harness fakes only what a test needs) ----------

local function call(item, method, ...)
    local fn = item[method]
    if type(fn) ~= "function" then return nil end
    local ok, v = pcall(fn, item, ...)
    if ok then return v end
    return nil
end

local function fluidOf(item)
    local fc = call(item, "getFluidContainer")
    if not fc then return nil end
    local ok, info = pcall(function()
        local f = fc:getPrimaryFluid()
        return { name = f and f:getFluidTypeString() or "", amount = fc:getAmount() }
    end)
    if ok and type(info) == "table" then return info end
    return nil
end

-- Returns ok, reason. `unlisted_moddata` carries the offending key in the third value.
function Codec.check(item)
    local fullType = call(item, "getFullType")
    if type(fullType) ~= "string" then return false, "invalid_item" end
    if wl.excludeTypes[fullType] then return false, "not_whitelisted" end
    local main = call(item, "getCategory")
    if type(main) == "string" and Codec.EXCLUDED_MAIN[main] then return false, "not_whitelisted" end
    local display = call(item, "getDisplayCategory")
    if not wl.types[fullType] and not (type(display) == "string" and wl.categories[display]) then return false, "not_whitelisted" end
    if call(item, "isEquipped") == true then return false, "equipped" end
    if call(item, "isFavorite") == true then return false, "favorite" end
    if call(item, "isBroken") == true then return false, "broken" end
    if main == "Food" then
        local script = call(item, "getScriptItem")
        local rots = script and call(script, "getDaysTotallyRotten")
        if type(rots) == "number" and rots < Codec.NEVER_ROTS then return false, "perishable" end
        if call(item, "isRotten") == true then return false, "perishable" end
    end
    local pages = call(item, "getAlreadyReadPages")
    if type(pages) == "number" and pages > 0 then return false, "read_book" end
    local md = call(item, "getModData")
    if type(md) == "table" then
        for k in pairs(md) do
            if k ~= EC.PLAYER_MODDATA_KEY and not wl.modDataKeys[k] then return false, "unlisted_moddata", tostring(k) end
        end
    end
    return true
end

-- Bounded snapshot; call after Codec.check passed. Our own claim stamp is dropped on purpose.
function Codec.snapshot(item)
    local s = {
        type = call(item, "getFullType"),
        condition = call(item, "getCondition"),
        uses = call(item, "getCurrentUses"),
        age = call(item, "getAge"),
        repaired = call(item, "getHaveBeenRepaired"),
        readPages = call(item, "getAlreadyReadPages"),
    }
    local fluid = fluidOf(item)
    if fluid and fluid.name ~= "" and (fluid.amount or 0) > 0 then s.fluid = { name = fluid.name, amount = fluid.amount } end
    local md = call(item, "getModData")
    if type(md) == "table" then
        local copy, n = {}, 0
        for k, v in pairs(md) do
            if k ~= EC.PLAYER_MODDATA_KEY and wl.modDataKeys[k] and n < Codec.MODDATA_KEYS_MAX then
                local t = type(v)
                if t == "number" or t == "boolean" or (t == "string" and #v <= Codec.MODDATA_VALUE_MAX) then
                    copy[k] = v
                    n = n + 1
                end
            end
        end
        if n > 0 then s.modData = copy end
    end
    return s
end

-- Fresh item from a snapshot; nil, err when the script no longer exists on this server.
function Codec.rebuild(s)
    if type(s) ~= "table" or type(s.type) ~= "string" then return nil, "invalid_snapshot" end
    local item = instanceItem(s.type)
    if not item then return nil, "item_unavailable" end
    if type(s.condition) == "number" then call(item, "setCondition", s.condition) end
    if type(s.uses) == "number" then call(item, "setCurrentUses", s.uses) end
    if type(s.age) == "number" then call(item, "setAge", s.age) end
    if type(s.repaired) == "number" then call(item, "setHaveBeenRepaired", s.repaired) end
    if type(s.readPages) == "number" then call(item, "setAlreadyReadPages", s.readPages) end
    if type(s.fluid) == "table" then
        local fc = call(item, "getFluidContainer")
        if fc then
            pcall(function()
                fc:Empty()
                local fl = Fluid.Get(s.fluid.name)
                if fl and (s.fluid.amount or 0) > 0 then fc:addFluid(fl, s.fluid.amount) end
            end)
        end
    end
    if type(s.modData) == "table" then
        local md = call(item, "getModData")
        if type(md) == "table" then
            for k, v in pairs(s.modData) do md[k] = v end
        end
    end
    return item
end

-- Weapon attachments go back to the seller as their own items (they are WeaponPart items,
-- WeaponPart.java:169-171); the weapon is listed bare. Returns how many were detached.
function Codec.detachParts(item, inv)
    local parts = call(item, "getAllWeaponParts")
    if not parts then return 0 end
    local list = {}
    pcall(function()
        for i = 0, parts:size() - 1 do list[#list + 1] = parts:get(i) end
    end)
    local n = 0
    for _, part in ipairs(list) do
        local ok = pcall(function()
            item:detachWeaponPart(part)
            inv:AddItem(part)
            sendAddItemToContainer(inv, part)
        end)
        if ok then n = n + 1 end
    end
    return n
end

function Codec.init(root)
    local ok, err = Codec.load()
    EC.log("whitelist: " .. (ok and (tostring(wl.counts.categories) .. " categories, " .. tostring(wl.counts.types) .. " types") or ("error " .. tostring(err))))
end

S.Codec = Codec
S.onInit(Codec.init)
return Codec
