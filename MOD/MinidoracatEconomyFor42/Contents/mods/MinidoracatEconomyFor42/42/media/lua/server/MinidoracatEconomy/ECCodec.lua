-- MinidoracatEconomyFor42 - listing whitelist + bounded item snapshots (server; spec 12 stage D,
-- 17.1, stage A7).
--
-- The market never stores an InventoryItem (Lua has no ByteBuffer for save/load): a listing keeps a
-- bounded snapshot and the buyer gets a rebuilt item. Only item classes whose rebuild is faithful
-- may be listed, and the host decides which in {cachedir}/Lua/MinidoracatEconomy/whitelist.json
-- (display categories, extra fullTypes, excluded fullTypes, allowed modData keys). The file is the
-- single source of truth, like the shop's catalog.json: the admin page edits it through
-- Codec.update (one category or one item per write, written straight back, refused with
-- whitelist_stale when the file on disk changed since the last load), and a hand edit takes
-- effect after reload. Fixed rules on top of the file: none of EC.LISTING_FIXED_TYPES (containers,
-- clothing, keys, radios, maps, moveables, animals), no perishable food, no read books, nothing
-- equipped, favourite or broken, and no modData key outside the allowed list (fail closed - a mod
-- that keeps state on the item would lose it in the rebuild).
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
Codec.FIELDS = { "categories", "types", "excludeTypes", "modDataKeys" }
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

-- Sets answer Codec.check; the lists keep the file's order so a write-back stays diff-friendly.
local wl = { categories = {}, types = {}, excludeTypes = {}, modDataKeys = {}, lists = {}, loadedAt = 0, error = nil, counts = {}, hash = "0" }

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

-- Canonical serialisation: one array per line so a host can still hand-edit the file.
local function writeDoc(lists)
    local writer = nil
    local ok = pcall(function() writer = getFileWriter(Codec.FILE, true, false) end)
    if not ok or not writer then return false end
    local wrote = pcall(function()
        writer:writeln("{")
        for i, field in ipairs(Codec.FIELDS) do
            local list = lists[field] or {}
            writer:writeln('  "' .. field .. '": ' .. (#list > 0 and EC.jsonEncode(list) or "[]") .. (i < #Codec.FIELDS and "," or ""))
        end
        writer:writeln("}")
    end)
    pcall(function() writer:close() end)
    return wrote
end

local function hashOf(text)
    return EC.hashHex(EC.hashUpdate(EC.hashInit(), text))
end

-- Array of short strings -> set + de-duplicated ordered list; nil, message when malformed.
local function stringSet(list, field)
    if list == nil then return {}, {} end
    if type(list) ~= "table" then return nil, field .. " must be an array" end
    local set, ordered = {}, {}
    for i, v in ipairs(list) do
        if type(v) ~= "string" or v == "" or #v > 128 or string.find(v, "%c") then return nil, field .. "[" .. i .. "] must be a short string" end
        if not set[v] then
            set[v] = true
            ordered[#ordered + 1] = v
        end
    end
    return set, ordered
end

function Codec.load()
    local text = readFile()
    if text == nil then
        if not writeDoc(Codec.DEFAULT) then
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
    local parsed, lists, counts = {}, {}, {}
    for _, field in ipairs(Codec.FIELDS) do
        local set, ordered = stringSet(doc[field], field)
        if set == nil then
            wl.error = ordered
            EC.log("whitelist.json rejected: " .. tostring(ordered))
            return false, ordered
        end
        parsed[field], lists[field], counts[field] = set, ordered, #ordered
    end
    wl.categories, wl.types, wl.excludeTypes, wl.modDataKeys = parsed.categories, parsed.types, parsed.excludeTypes, parsed.modDataKeys
    wl.lists = lists
    wl.counts = counts
    wl.loadedAt = EC.now()
    wl.error = nil
    wl.hash = hashOf(text)
    return true
end

-- withLists adds the four arrays (the admin page edits from them); admin.system only wants counts.
function Codec.status(withLists)
    local s = { loadedAt = wl.loadedAt, error = wl.error, counts = wl.counts, path = Codec.FILE }
    if withLists then
        for _, field in ipairs(Codec.FIELDS) do
            local copy = {}
            for i, v in ipairs(wl.lists[field] or {}) do copy[i] = v end
            s[field] = copy
        end
    end
    return s
end

local function itemExists(fullType)
    if type(fullType) ~= "string" or fullType == "" or #fullType > 128 then return false end
    local ok, found = pcall(function() return ScriptManager.instance:FindItem(fullType) ~= nil end)
    return ok and found == true
end

local function without(list, value)
    local out = {}
    for _, v in ipairs(list) do
        if v ~= value then out[#out + 1] = v end
    end
    return out
end

-- One edit from the admin page, written straight back into the file:
--   { category = "Tool", allowed = true|false }               toggle a display category
--   { fullType = "Base.Axe", mode = "allow"|"exclude"|"inherit" }  per-item override (exclude wins
--                                                             over allow in Codec.check; inherit
--                                                             clears both)
-- Returns ok, err. Refused with whitelist_stale when the file on disk no longer matches what was
-- loaded (a hand edit the page would otherwise overwrite): reload first.
function Codec.update(args, actor)
    if type(args) ~= "table" then return false, "invalid_args" end
    local target, field, before, after
    local lists = { categories = wl.lists.categories, types = wl.lists.types, excludeTypes = wl.lists.excludeTypes, modDataKeys = wl.lists.modDataKeys }
    if args.category ~= nil then
        local cat = args.category
        if type(cat) ~= "string" or cat == "" or #cat > 64 or string.find(cat, "[%c%s]") or type(args.allowed) ~= "boolean" then return false, "invalid_args" end
        target, field = cat, "category"
        before = wl.categories[cat] == true
        after = args.allowed
        if before == after then return true end
        lists.categories = without(lists.categories, cat)
        if after then lists.categories[#lists.categories + 1] = cat end
    elseif args.fullType ~= nil then
        local ft, mode = args.fullType, args.mode
        if mode ~= "allow" and mode ~= "exclude" and mode ~= "inherit" then return false, "invalid_args" end
        if not itemExists(ft) then return false, "unknown_item" end
        target, field = ft, "type"
        before = wl.excludeTypes[ft] and "exclude" or (wl.types[ft] and "allow" or "inherit")
        after = mode
        if before == after then return true end
        lists.types = without(lists.types, ft)
        lists.excludeTypes = without(lists.excludeTypes, ft)
        if mode == "allow" then lists.types[#lists.types + 1] = ft
        elseif mode == "exclude" then lists.excludeTypes[#lists.excludeTypes + 1] = ft end
    else
        return false, "invalid_args"
    end
    local onDisk = readFile()
    if onDisk == nil or hashOf(onDisk) ~= wl.hash then return false, "whitelist_stale" end
    if not writeDoc(lists) then return false, "file_write_failed" end
    local ok, err = Codec.load()   -- re-read what was written: hash, counts and a sanity parse
    if not ok then
        EC.log("whitelist.json unreadable after the panel wrote it: " .. tostring(err))
        return false, "file_write_failed"
    end
    X.emit("admin.whitelist", { target = target, field = field, before = before, after = after, actor = actor })
    X.audit({ action = "whitelist", target = target, field = field, before = tostring(before), after = tostring(after), admin = actor })
    return true
end

function Codec.reload(actor)
    local ok, err = Codec.load()
    X.emit("admin.whitelist", { field = "reload", after = ok and wl.counts.categories or nil, error = err, actor = actor })
    X.audit({ action = "whitelist", target = "file", field = "reload", after = ok and "ok" or ("error: " .. tostring(err)), admin = actor })
    return ok, err
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
    local script = call(item, "getScriptItem")
    if EC.isFixedType(script) then return false, "not_whitelisted" end
    local main = call(item, "getCategory")
    local display = call(item, "getDisplayCategory")
    if not wl.types[fullType] and not (type(display) == "string" and wl.categories[display]) then return false, "not_whitelisted" end
    if call(item, "isEquipped") == true then return false, "equipped" end
    if call(item, "isFavorite") == true then return false, "favorite" end
    if call(item, "isBroken") == true then return false, "broken" end
    if main == "Food" then
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
