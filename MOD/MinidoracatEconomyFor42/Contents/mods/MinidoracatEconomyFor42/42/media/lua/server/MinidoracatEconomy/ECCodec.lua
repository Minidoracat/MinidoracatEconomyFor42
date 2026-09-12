-- MinidoracatEconomyFor42 - listing whitelist + bounded item snapshots (server; spec 12 stage D,
-- 17.1, stage A7).
--
-- The market never stores an InventoryItem (Lua has no ByteBuffer for save/load): a listing keeps a
-- bounded snapshot and the buyer gets a rebuilt item. Only item classes whose rebuild is faithful
-- may be listed, and the host decides which in {cachedir}/Lua/MinidoracatEconomy/whitelist.json
-- (display categories, extra fullTypes, excluded fullTypes). The file is the single source of
-- truth, like the shop's catalog.json: the admin page edits it through Codec.update (one category
-- or one item per write, written straight back, refused with whitelist_stale when the file on disk
-- changed since the last load), and a hand edit takes effect after reload. Fixed rules on top of
-- the file: none of EC.LISTING_FIXED_TYPES (containers, clothing, keys, maps, moveables, animals;
-- radios travel with their DeviceData), nothing rotten, equipped, favourite or broken, and no modData larger than the snapshot
-- may carry (the data itself travels: vanilla writes customName / condition:* there).
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
Codec.MODDATA_MAX_LEAVES = 32      -- scalar values a snapshot's modData may carry
Codec.MODDATA_MAX_DEPTH = 3        -- nesting: modData -> table -> table
Codec.MODDATA_STRING_MAX = 128
Codec.FILE_LINES_MAX = 5000
Codec.FIELDS = { "categories", "types", "excludeTypes" }
Codec.DEFAULT = {
    categories = {
        "Tool", "ToolWeapon", "Weapon", "WeaponCrafted", "MaterialWeapon", "Material", "Ammo",
        "FirstAid", "Bandage", "Literature", "SkillBook", "Food", "VehicleMaintenance", "Water",
        "WaterContainer", "LightSource", "Camping", "Electronics", "Household", "Cooking", "Gardening",
        "RecipeResource",
    },
    types = {},
    excludeTypes = {},
}

-- Sets answer Codec.check; the lists keep the file's order so a write-back stays diff-friendly.
local wl = { categories = {}, types = {}, excludeTypes = {}, lists = {}, loadedAt = 0, error = nil, counts = {}, hash = "0" }

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
    wl.categories, wl.types, wl.excludeTypes = parsed.categories, parsed.types, parsed.excludeTypes
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
        if type(ft) ~= "string" or ft == "" or #ft > 128 or string.find(ft, "%c") then return false, "invalid_args" end
        if mode ~= "allow" and mode ~= "exclude" and mode ~= "inherit" then return false, "invalid_args" end
        -- Removing a stored rule must still work after its providing mod was uninstalled.
        if mode ~= "inherit" and not itemExists(ft) then return false, "unknown_item" end
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

-- Sandbox FoodRotSpeed -> the multiplier Food.getFoodRotSpeed() applies (Food.java:724-732; the
-- method itself is private, the enum is the sandbox option "FoodRotSpeed").
local ROT_SPEED = { [1] = 1.7, [2] = 1.4, [3] = 1.0, [4] = 0.7, [5] = 0.4 }
local function rotSpeed()
    local ok, v = pcall(function() return getSandboxOptions():getOptionByName("FoodRotSpeed"):getValue() end)
    return (ok and ROT_SPEED[v]) or 1.0
end

-- In-game world clock in hours (GameTime.java:901); food ages by this clock (Food.java:739-786).
local function worldHours()
    local ok, v = pcall(function() return getGameTime():getWorldAgeHours() end)
    if ok and type(v) == "number" then return v end
    return nil
end

-- Bounded deep copy of a modData table (string/number/boolean/table only, the types Global
-- ModData can hold, KahluaTableImpl.java:365-404). Returns copy, leaves; nil when the data is
-- deeper or larger than the snapshot may carry. Our own claim stamp is skipped on purpose.
local function copyModData(md, depth, leaves)
    local copy = {}
    for k, v in pairs(md) do
        local kt = type(k)
        if (kt == "string" or kt == "number") and not (depth == 0 and k == EC.PLAYER_MODDATA_KEY) then
            local t = type(v)
            if t == "number" or t == "boolean" or t == "string" then
                if t == "string" and #v > Codec.MODDATA_STRING_MAX then return nil end
                leaves = leaves + 1
                if leaves > Codec.MODDATA_MAX_LEAVES then return nil end
                copy[k] = v
            elseif t == "table" then
                if depth + 1 >= Codec.MODDATA_MAX_DEPTH then return nil end
                local sub
                sub, leaves = copyModData(v, depth + 1, leaves)
                if sub == nil then return nil end
                copy[k] = sub
            end
            -- functions / userdata cannot live in ModData either: dropped like the engine would
        end
    end
    return copy, leaves
end

-- State an item must not be in to leave a backpack through us, whatever the list says. Returns
-- ok, reason. Vanilla itself writes modData (customName, condition:<type>,
-- InventoryItem.java:3253-3256, 3262-3271), so a mod-data key is never a reason by itself: the
-- data travels in the snapshot and only an oversized blob is refused (moddata_too_big).
function Codec.stateCheck(item)
    if call(item, "isEquipped") == true then return false, "equipped" end
    if call(item, "isFavorite") == true then return false, "favorite" end
    if call(item, "isBroken") == true then return false, "broken" end
    if call(item, "isRotten") == true then return false, "perishable" end
    local md = call(item, "getModData")
    if type(md) == "table" and copyModData(md, 0, 0) == nil then return false, "moddata_too_big" end
    return true
end

function Codec.check(item)
    local fullType = call(item, "getFullType")
    if type(fullType) ~= "string" then return false, "invalid_item" end
    if wl.excludeTypes[fullType] then return false, "not_whitelisted" end
    local script = call(item, "getScriptItem")
    if EC.isFixedType(script) then return false, "not_whitelisted" end
    local display = call(item, "getDisplayCategory")
    if not wl.types[fullType] and not (type(display) == "string" and wl.categories[display]) then return false, "not_whitelisted" end
    return Codec.stateCheck(item)
end

-- The system buys only what it could have handed out itself: the item must look like a freshly
-- created one of that type in everything the shop pays for (condition, uses, repairs, read
-- pages, food state, fluid, no custom name). Age and modData are not compared: vanilla writes
-- both on ordinary items (planks carry customName, Food.updateAge ticks age; Food.java:774).
local canonical = {}
local function canonicalSignature(s)
    local copy = {}
    for k, v in pairs(s) do if k ~= "age" and k ~= "modData" then copy[k] = v end end
    return Codec.signature(copy)
end

function Codec.isCanonical(item, fullType)
    if call(item, "getFullType") ~= fullType then return false end
    local ref = canonical[fullType]
    if not ref then
        local fresh = instanceItem(fullType)
        if not fresh then return false end
        ref = canonicalSignature(Codec.snapshot(fresh))
        canonical[fullType] = ref
    end
    return canonicalSignature(Codec.snapshot(item)) == ref
end

-- Bounded snapshot; call after Codec.check passed. Food keeps its edible state and the world
-- hour it was listed at: escrow is not a freezer, so the rebuild ages it by the hours it spent
-- there (Codec.rebuild). Our own claim stamp is dropped on purpose.
function Codec.snapshot(item)
    local s = {
        type = call(item, "getFullType"),
        condition = call(item, "getCondition"),
        uses = call(item, "getCurrentUses"),
        age = call(item, "getAge"),
        repaired = call(item, "getHaveBeenRepaired"),
        readPages = call(item, "getAlreadyReadPages"),
    }
    if call(item, "isCustomName") == true then
        local name = call(item, "getName")
        if type(name) == "string" and name ~= "" and #name <= Codec.MODDATA_STRING_MAX then s.name = name end
    end
    if call(item, "getCategory") == "Food" then
        s.food = {
            hunger = call(item, "getHungChange"),
            thirst = call(item, "getThirstChange"),
            cooked = call(item, "isCooked") == true,
            burnt = call(item, "isBurnt") == true,
            frozen = call(item, "isFrozen") == true,
            freezing = call(item, "getFreezingTime"),
            listedHours = worldHours(),
        }
    end
    -- radio / walkie-talkie: the tuned state lives in DeviceData (Radio.java:46; getters and the
    -- side-effect-free *Raw setters DeviceData.java:382-604, 1314-1326)
    local dev = call(item, "getDeviceData")
    if dev then
        s.device = {
            channel = call(dev, "getChannel"),
            power = call(dev, "getPower"),
            on = call(dev, "getIsTurnedOn") == true,
            volume = call(dev, "getDeviceVolume"),
            headphones = call(dev, "getHeadphoneType"),
            muted = call(dev, "getMicIsMuted") == true,
            battery = call(dev, "getHasBattery"),
            mediaType = call(dev, "getMediaType"),
            mediaIndex = call(dev, "getMediaIndex"),
        }
    end
    local fluid = fluidOf(item)
    if fluid and fluid.name ~= "" and (fluid.amount or 0) > 0 then s.fluid = { name = fluid.name, amount = fluid.amount } end
    local md = call(item, "getModData")
    if type(md) == "table" then
        local copy, leaves = copyModData(md, 0, 0)
        if copy and leaves > 0 then s.modData = copy end
    end
    return s
end

-- Items with the same signature are interchangeable copies (one listing may carry several of
-- them): the whole snapshot except the clock it was taken at.
function Codec.signature(s)
    local food = s.food
    if type(food) == "table" and food.listedHours ~= nil then
        local copy = {}
        for k, v in pairs(s) do copy[k] = v end
        local f = {}
        for k, v in pairs(food) do if k ~= "listedHours" then f[k] = v end end
        copy.food = f
        s = copy
    end
    return EC.jsonEncode(s)
end

-- Fresh item from a snapshot; nil, err when the script no longer exists on this server.
function Codec.rebuild(s)
    if type(s) ~= "table" or type(s.type) ~= "string" then return nil, "invalid_snapshot" end
    local item = instanceItem(s.type)
    if not item then return nil, "item_unavailable" end
    if type(s.condition) == "number" then call(item, "setCondition", s.condition) end
    if type(s.uses) == "number" then call(item, "setCurrentUses", s.uses) end
    local age = s.age
    local food = s.food
    if type(food) == "table" then
        -- the hours in escrow count like hours on a shelf (Food.java:774: age += hours * rot speed / 24)
        local now = worldHours()
        if type(age) == "number" and type(food.listedHours) == "number" and now and now > food.listedHours then
            age = age + (now - food.listedHours) * rotSpeed() / 24
        end
        if type(food.hunger) == "number" then call(item, "setHungChange", food.hunger) end
        if type(food.thirst) == "number" then call(item, "setThirstChange", food.thirst) end
        if food.cooked then call(item, "setCooked", true) end
        if food.burnt then call(item, "setBurnt", true) end
        if type(food.freezing) == "number" then call(item, "setFreezingTime", food.freezing) end
        if food.frozen then call(item, "setFrozen", true) end
    end
    if type(age) == "number" then call(item, "setAge", age) end
    if type(s.repaired) == "number" then call(item, "setHaveBeenRepaired", s.repaired) end
    if type(s.readPages) == "number" then call(item, "setAlreadyReadPages", s.readPages) end
    if type(s.name) == "string" then
        call(item, "setName", s.name)
        call(item, "setCustomName", true)
    end
    if type(s.device) == "table" then
        local dev = call(item, "getDeviceData")
        local d = s.device
        if dev then
            if type(d.channel) == "number" then call(dev, "setChannelRaw", d.channel) end
            if type(d.power) == "number" then call(dev, "setPower", d.power) end
            if type(d.volume) == "number" then call(dev, "setDeviceVolumeRaw", d.volume) end
            if type(d.headphones) == "number" then call(dev, "setHeadphoneType", d.headphones) end
            if type(d.battery) == "boolean" then call(dev, "setHasBattery", d.battery) end
            if d.muted then call(dev, "setMicIsMuted", true) end
            if type(d.mediaType) == "number" then call(dev, "setMediaType", d.mediaType) end
            if type(d.mediaIndex) == "number" then call(dev, "setMediaIndex", d.mediaIndex) end
            if d.on then call(dev, "setTurnedOnRaw", true) end
        end
    end
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
            local copy = copyModData(s.modData, 0, 0)
            for k, v in pairs(copy or {}) do md[k] = v end
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
