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
-- the file: none of EC.LISTING_FIXED_TYPES (containers, keys, maps, moveables, standing alarm
-- clocks, animals; radios travel with their DeviceData, clothing with its per-part holes / blood /
-- dirt / patches and its look, a wristwatch with its alarm), nothing rotten, equipped (worn
-- clothing included) or favourite or broken, and no modData
-- larger than the snapshot may carry (the data itself travels: vanilla writes customName /
-- condition:* there). State a snapshot cannot carry is refused instead of dropped: a notebook's
-- writing or author lock, applied poison, a prepared dish's ingredients, a fertilized egg, a
-- patch sewn over a hole, a disc or tape left inside a device.
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
--   head condition / head repairs / sharpness       InventoryItem.java:3167-3183, 4589-4641, 4789-4823
--   rounds, magazine, chamber, jam, fire mode       InventoryItem.java:3917-3923 ; HandWeapon.java:2064-2141, 2252-2258
--   infected / key id / remote pairing              InventoryItem.java:3759-3765, 1739-1748
--   raw food values (the *Unmodified getters)       Food.java:1767-1785, 1912-2144
--   writing / author lock                           Literature.java:43-44, 502-521
--   worn = equipped                                 InventoryItem.java:3426-3434 ; IsoGameCharacter.java:10355-10362
--   clothing levels / patches                       Clothing.java:741-787, 936-942, 944-981, 995-997, 1065-1072, 1132-1134
--   per-part holes / blood / dirt / patch visuals   ItemVisual.java:502-606 ; BloodBodyPartType.java:10-47
--   look (random on first getVisual)                InventoryItem.java:2320-2336 ; ItemVisual.java:127-222, 727-741
--   custom colour                                   InventoryItem.java:636-646, 3102-3104, 3645-3651
--   raw custom name (getName adds prefixes)         InventoryItem.java:2428-2479, 3204-3206
--   preview maxima                                  InventoryItem.java:2502, 2705-2715, 3909-3911 ; FluidContainer.java:530
--   device battery / medium                         DeviceData.java:84, 259-273, 588-601, 1310-1330 ; KahluaConverterManager.java:206
--   wristwatch alarm (hour, minute, set)            AlarmClockClothing.java:71-79, 232-254, 262-310
--                                                   (42.21.0; the server sets it the same way,
--                                                   SyncPlayerAlarmClockPacket.java:45-58)

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

-- ---------- clothing ----------
-- Per-part state lives in the ItemVisual as one byte per BloodBodyPartType (holes / patch visuals
-- are 0 or 255, blood / dirt 0-255); the snapshot keeps holes and patch visuals as bit masks and
-- blood / dirt as two hex digits per part, so a fully torn, bloody, dirty shirt costs a handful of
-- journal leaves instead of ~90 (ECRecoveryJournal J.PACK_LEAVES_MAX = 128).
local parts = nil
local function bodyParts()
    if parts then return parts end
    local ok, list = pcall(function()
        local out = {}
        for i = 0, BloodBodyPartType.MAX:index() - 1 do out[#out + 1] = BloodBodyPartType.FromIndex(i) end
        return out
    end)
    if ok and type(list) == "table" and #list > 0 then parts = list end
    return parts
end

local function hasBit(mask, i)
    return type(mask) == "number" and math.floor(mask / 2 ^ (i - 1)) % 2 == 1
end

local function hexByte(text, i)
    if type(text) ~= "string" then return 0 end
    return tonumber(string.sub(text, i * 2 - 1, i * 2), 16) or 0
end

-- ClothingPatch(tailorLvl, fabricType, hasHole) derives its defences from the level
-- (Clothing.java:1419-1428; fabric maxima :1470-1473). Lua cannot read tailorLvl or hasHole:
-- only static fields are exposed (LuaJavaClassExposer.java:299-311) and the reflection globals
-- are debug-only (LuaManager.java:1671-1677). The level is recovered as the lowest one that gives
-- the same defences (it has no other effect: it is only saved and synced); integer arithmetic
-- here equals the engine's float arithmetic for every level 0-127 (checked against the JVM).
local FABRIC = { [1] = { 5, 0 }, [2] = { 10, 5 }, [3] = { 20, 10 } }
local function patchLevel(fabric, scratch, bite)
    local f = FABRIC[fabric]
    if not f then return nil end
    for lvl = 1, 10 do
        local s = math.max(1, math.floor(f[1] * lvl / 10))
        local b = f[2] > 0 and math.max(1, math.floor(f[2] * lvl / 10)) or 0
        if s == scratch and b == bite then return lvl end
    end
    return nil
end

-- A patch sewn over a hole also remembers the condition it gave back (conditionGain) and takes it
-- away again when it is removed (Clothing.java:999-1006, 1101-1106). addPatchForSync cannot set
-- that field (:1065-1072), so a rebuilt copy would lose it - and accepting the loss opens a loop:
-- patch a hole, list and cancel, remove the patch without losing condition, patch again, the same
-- free-repair class a17479c closed for heads and edges. Such clothing is refused. Whether a patch
-- covers a hole is read the one way Lua can: share the patch map with a probe whose own scratch
-- defence is non-zero (copyPatchesTo only assigns the reference, :1132-1134; nothing is written)
-- and ask getDefForPart, which returns the patch's defence alone for a hole patch and adds the
-- garment's own for padding (:944-981). Anything that does not match either is refused too.
Codec.PATCH_PROBE = "Base.Trousers_Denim"   -- ScratchDefense 20, no neck modifier
local function patchesCarried(item)
    local list = bodyParts()
    if not list then return false end
    local probe, base = nil, nil
    for _, part in ipairs(list) do
        local p = call(item, "getPatchType", part)
        if p then
            local scratch = call(p, "getScratchDefense")
            if not patchLevel(call(p, "getFabricType"), scratch, call(p, "getBiteDefense")) then return false end
            if not probe then
                probe = instanceItem(Codec.PATCH_PROBE)
                if not probe then return false end
                call(item, "copyPatchesTo", probe)
                if call(probe, "getPatchType", part) == nil then return false end
                base = call(probe, "getScratchDefense")
                if type(base) ~= "number" or base <= 0 then return false end
            end
            if call(probe, "getDefForPart", part, false, false) ~= base + scratch then return false end
        end
    end
    return true
end

local function colorOf(c)
    if c == nil then return nil end
    local ok, v = pcall(function() return { r = c:getRedFloat(), g = c:getGreenFloat(), b = c:getBlueFloat(), a = c:getAlphaFloat() } end)
    if ok then return v end
    return nil
end

-- Clothing state that is not the default of a fresh copy, plus its look. The look (hue, tint,
-- texture choices, decal) is rolled on the first getVisual of every new instance, so it is always
-- stored, kept apart in s.look and left out of the buyback comparison.
local function clothSnapshot(item, s)
    if call(item, "IsClothing") ~= true then return end
    local c, any = {}, false
    local vis, list = call(item, "getVisual"), bodyParts()
    if vis and list then
        local masks = { holes = "getHole", basic = "getBasicPatch", denim = "getDenimPatch", leather = "getLeatherPatch" }
        for key, getter in pairs(masks) do
            local mask = 0
            for i, part in ipairs(list) do
                if (call(vis, getter, part) or 0) > 0 then mask = mask + 2 ^ (i - 1) end
            end
            if mask > 0 then c[key] = mask; any = true end
        end
        for _, key in ipairs({ "blood", "dirt" }) do
            local getter = key == "blood" and "getBlood" or "getDirt"
            local hex, set = {}, false
            for i, part in ipairs(list) do
                local b = math.floor((call(vis, getter, part) or 0) * 255 + 0.5)
                hex[i] = string.format("%02x", b)
                if b > 0 then set = true end
            end
            if set then c[key] = table.concat(hex); any = true end
        end
        local patches = {}
        for i, part in ipairs(list) do
            local p = call(item, "getPatchType", part)
            if p then
                local fabric = call(p, "getFabricType")
                local lvl = patchLevel(fabric, call(p, "getScratchDefense"), call(p, "getBiteDefense"))
                if lvl then patches[#patches + 1] = (i - 1) .. ":" .. fabric .. ":" .. lvl end
            end
        end
        if #patches > 0 then c.patches = table.concat(patches, ","); any = true end
        local look = {
            hue = call(vis, "getHue"),
            tint = colorOf(call(vis, "getTint")),
            base = call(vis, "getBaseTexture"),
            choice = call(vis, "getTextureChoice"),
            decal = call(vis, "getDecal", call(item, "getClothingItem")),
        }
        if type(look.hue) ~= "number" or look.hue ~= look.hue or look.hue == math.huge then look.hue = nil end
        if type(look.base) == "number" and look.base < 0 then look.base = nil end
        if type(look.choice) == "number" and look.choice < 0 then look.choice = nil end
        if type(look.decal) ~= "string" or look.decal == "" or #look.decal > Codec.MODDATA_STRING_MAX then look.decal = nil end
        s.look = look
    end
    for key, getter in pairs({ bloodLv = "getBloodLevel", dirtLv = "getDirtiness", wet = "getWetness" }) do
        local v = call(item, getter)
        if type(v) == "number" and v > 0 then c[key] = v; any = true end
    end
    if call(item, "isCustomColor") == true then
        c.color = { r = call(item, "getR"), g = call(item, "getG"), b = call(item, "getB"), a = call(item, "getA") }
        any = true
    end
    if any then s.cloth = c end
end

-- Order: per-part visuals, then the overall levels (setBlood does not recompute them), then the
-- patch map, then the look over what the fresh copy rolled. Blood / dirt go back as (b + 0.5) / 255
-- because the setter truncates amount * 255 (ItemVisual.java:582-606) and b / 255 may land just
-- under b.
local function clothRebuild(item, s)
    local c = type(s.cloth) == "table" and s.cloth or {}
    local vis, list = call(item, "getVisual"), bodyParts()
    if vis and list then
        for i, part in ipairs(list) do
            if hasBit(c.holes, i) then call(vis, "setHole", part) end
            if hasBit(c.basic, i) then call(vis, "setBasicPatch", part) end
            if hasBit(c.denim, i) then call(vis, "setDenimPatch", part) end
            if hasBit(c.leather, i) then call(vis, "setLeatherPatch", part) end
            local b, d = hexByte(c.blood, i), hexByte(c.dirt, i)
            if b > 0 then call(vis, "setBlood", part, (b + 0.5) / 255) end
            if d > 0 then call(vis, "setDirt", part, (d + 0.5) / 255) end
        end
        local look = s.look
        if type(look) == "table" then
            if type(look.hue) == "number" then call(vis, "setHue", look.hue) end
            local t = look.tint
            if type(t) == "table" and type(t.r) == "number" then
                pcall(function() vis:setTint(ImmutableColor.new(t.r, t.g, t.b, t.a or 1)) end)
            end
            if type(look.base) == "number" then call(vis, "setBaseTexture", look.base) end
            if type(look.choice) == "number" then call(vis, "setTextureChoice", look.choice) end
            if type(look.decal) == "string" then call(vis, "setDecal", look.decal) end
        end
    end
    if type(c.bloodLv) == "number" then call(item, "setBloodLevel", c.bloodLv) end
    if type(c.dirtLv) == "number" then call(item, "setDirtiness", c.dirtLv) end
    if type(c.wet) == "number" then call(item, "setWetness", c.wet) end
    for idx, fabric, lvl in string.gmatch(c.patches or "", "(%d+):(%d+):(%d+)") do
        call(item, "addPatchForSync", tonumber(idx), tonumber(lvl), tonumber(fabric), false)
    end
    local col = c.color
    if type(col) == "table" and type(col.r) == "number" then
        pcall(function() item:setColor(Color.new(col.r, col.g, col.b, col.a or 1)) end)
        call(item, "setCustomColor", true)
    end
end

-- State an item must not be in to leave a backpack through us, whatever the list says. Returns
-- ok, reason. Vanilla itself writes modData (customName, condition:<type>,
-- InventoryItem.java:3253-3256, 3262-3271), so a mod-data key is never a reason by itself: the
-- data travels in the snapshot and only an oversized blob is refused (moddata_too_big).
function Codec.stateCheck(item)
    -- A force-drop heavy item (generator, anvil, ore: InventoryItem.java:534-538) is only ever
    -- carried with both hands on it (ISEquipHeavyItem.lua:59-86), so held is its normal state:
    -- the list-out empties the hands before it removes the item (ECMailbox M.takeOut).
    if call(item, "isEquipped") == true and call(item, "isForceDropHeavyItem") ~= true then return false, "equipped" end
    if call(item, "isFavorite") == true then return false, "favorite" end
    if call(item, "isBroken") == true then return false, "broken" end
    if call(item, "isRotten") == true then return false, "perishable" end
    local md = call(item, "getModData")
    if type(md) == "table" and copyModData(md, 0, 0) == nil then return false, "moddata_too_big" end
    -- Refused, not dropped: pages of up to 16 384 characters and their lock, applied poison, a
    -- dish's ingredient list (its sickness value has no raw getter, Food.java:2081-2096) and an
    -- egg's genome would all vanish in the rebuild.
    if call(item, "isEmptyPages") == false or call(item, "getLockedBy") ~= nil then return false, "written" end
    local poison = call(item, "getPoisonPower")
    if type(poison) == "number" and poison > 0 then return false, "poisoned" end
    local extra = call(item, "getExtraItems")
    if extra ~= nil and (call(extra, "size") or 0) > 0 then return false, "prepared_dish" end
    if call(item, "isFertilized") == true then return false, "fertilized" end
    if call(item, "IsClothing") == true and (call(item, "getPatchesNumber") or 0) > 0 and not patchesCarried(item) then
        return false, "clothing_patch"
    end
    -- A disc or tape inside a device cannot be carried: the medium's item type (DeviceData.mediaItem,
    -- DeviceData.java:84) has no getter, and setMediaIndex(short) (:1318) cannot be called from Lua at
    -- all - the converter maps primitive short to itself (KahluaConverterManager.java:206), so no
    -- number converts. The rebuilt device would come out empty and the disc would be gone.
    local dev = call(item, "getDeviceData")
    if dev and call(dev, "hasMedia") == true then return false, "device_media" end
    -- The snapshot keeps one fluid and the total (fluidOf): a mixture (FluidContainer.isMixture,
    -- FluidContainer.java:855-857) would come back as the whole amount of its primary fluid.
    local fc = call(item, "getFluidContainer")
    if fc and call(fc, "isMixture") == true then return false, "fluid_mixture" end
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
-- pages, food state, fluid, no custom name, clothing wear). Age, modData, a garment's look and a
-- watch's alarm are not compared: vanilla writes the first two on ordinary items (planks carry
-- customName, Food.updateAge ticks age; Food.java:774) and rolls the other two for every new copy.
local canonical = {}
local function canonicalSignature(s)
    local copy = {}
    for k, v in pairs(s) do if k ~= "age" and k ~= "modData" and k ~= "look" and k ~= "alarm" then copy[k] = v end end
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
        -- the raw name: getName() prefixes "Bloody, Worn" and the like, which a rebuild would
        -- then prefix a second time (InventoryItem.java:2428-2479, 3204-3206)
        local name = call(item, "getDisplayName")
        if type(name) == "string" and name ~= "" and #name <= Codec.MODDATA_STRING_MAX then s.name = name end
    end
    if call(item, "getCategory") == "Food" then
        -- raw values: the plain getters add the burnt / stale / cooked modifiers, and writing those
        -- back would apply them a second time
        s.food = {
            hunger = call(item, "getHungChange"),
            thirst = call(item, "getThirstChangeUnmodified") or call(item, "getThirstChange"),
            cooked = call(item, "isCooked") == true,
            burnt = call(item, "isBurnt") == true,
            frozen = call(item, "isFrozen") == true,
            freezing = call(item, "getFreezingTime"),
            listedHours = worldHours(),
            calories = call(item, "getCalories"),
            proteins = call(item, "getProteins"),
            lipids = call(item, "getLipids"),
            carbs = call(item, "getCarbohydrates"),
            baseHunger = call(item, "getBaseHunger"),
            unhappy = call(item, "getUnhappyChangeUnmodified"),
            boredom = call(item, "getBoredomChangeUnmodified"),
            stress = call(item, "getStressChangeUnmodified"),
            endurance = call(item, "getEnduranceChangeUnmodified"),
            fatigue = call(item, "getFatigueChange"),
            pain = call(item, "getPainReduction"),
            flu = call(item, "getFluReduction"),
            cookingTime = call(item, "getCookingTime"),
        }
        if call(item, "isCookedInMicrowave") == true then s.food.microwave = true end
        local chef = call(item, "getChef")
        if type(chef) == "string" and chef ~= "" and #chef <= Codec.MODDATA_STRING_MAX then s.food.chef = chef end
    end
    -- A fresh copy starts at the script's full head and edge: only a worn head, a dull edge or a
    -- repaired head is stored, so new copies keep one signature (and one listing).
    if call(item, "hasHeadCondition") == true then
        local head, max = call(item, "getHeadCondition"), call(item, "getHeadConditionMax")
        if type(head) == "number" and type(max) == "number" and head < max then s.head = head end
    end
    if call(item, "hasTimesHeadRepaired") == true then
        local repairs = call(item, "getTimesHeadRepaired")
        if type(repairs) == "number" and repairs > 0 then s.headRepaired = repairs end
    end
    if call(item, "hasSharpness") == true then
        local sharp, max = call(item, "getSharpness"), call(item, "getMaxSharpness")
        if type(sharp) == "number" and type(max) == "number" and sharp < max then s.sharpness = sharp end
    end
    -- rounds are a count on the gun or the magazine, and an inserted magazine is a flag: none of
    -- them is an item of its own
    local ammo = call(item, "getCurrentAmmoCount")
    if type(ammo) == "number" and ammo > 0 then s.ammo = ammo end
    if call(item, "isContainsClip") == true then s.clip = true end
    if call(item, "isRoundChambered") == true then s.chamber = true end
    if call(item, "isJammed") == true then s.jammed = true end
    local mode = call(item, "getFireMode")
    if type(mode) == "string" and mode ~= "" then s.fireMode = mode end
    if call(item, "isInfected") == true then s.infected = true end
    local keyId = call(item, "getKeyId")
    if type(keyId) == "number" and keyId ~= -1 then s.keyId = keyId end
    local remoteId, remoteRange = call(item, "getRemoteControlID"), call(item, "getRemoteRange")
    if (type(remoteId) == "number" and remoteId ~= -1) or (type(remoteRange) == "number" and remoteRange ~= 0) then
        s.remote = { id = remoteId, range = remoteRange }
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
    -- a wristwatch: every new one rolls its alarm (AlarmClockClothing.randomizeAlarm), so it is
    -- always stored, and left out of the buyback comparison like a garment's look
    local hour = call(item, "getHour")
    if type(hour) == "number" then
        s.alarm = { hour = hour, minute = call(item, "getMinute"), set = call(item, "isAlarmSet") == true }
    end
    clothSnapshot(item, s)
    local fluid = fluidOf(item)
    if fluid and fluid.name ~= "" and (fluid.amount or 0) > 0 then s.fluid = { name = fluid.name, amount = fluid.amount } end
    local md = call(item, "getModData")
    if type(md) == "table" then
        local copy, leaves = copyModData(md, 0, 0)
        if copy and leaves > 0 then s.modData = copy end
    end
    return s
end

-- Hidden records two copies of one item may differ in without being different goods. A lot
-- leaves them out of the comparison (Codec.signature) and keeps one only when every copy carries
-- the same value (Codec.lotSnapshot), so merging can lose such a record but never hand it to a
-- copy that did not have it. Nothing reads either kind back (vanilla Lua, the engine and the
-- production server's mods, searched 2026-10-02):
--   MIC42_*: MinidoracatCleaner's "<last mover>,<hour>" and dropper stamps
--     (MinidoracatCleaner_Core.lua:21-34), rewritten whenever the item is moved or dropped
--   <Module.Type> = count: the inputs of a craft with a single output
--     (ISHandcraftAction:performRecipe, ISHandcraftAction.lua:236-247)
local function looseRecord(k, v)
    if type(k) ~= "string" then return false end
    if string.sub(k, 1, 6) == "MIC42_" then return true end
    return type(v) == "number" and string.find(k, ".", 1, true) ~= nil and itemExists(k)
end

-- Items with the same signature are interchangeable copies (one listing may carry several of
-- them): the whole snapshot except the clock it was taken at and the loose records above.
function Codec.signature(s)
    local copy = {}
    for k, v in pairs(s) do copy[k] = v end
    local food = s.food
    if type(food) == "table" and food.listedHours ~= nil then
        local f = {}
        for k, v in pairs(food) do if k ~= "listedHours" then f[k] = v end end
        copy.food = f
    end
    if type(s.modData) == "table" then
        local md, any = {}, false
        for k, v in pairs(s.modData) do
            if not looseRecord(k, v) then
                md[k] = v
                any = true
            end
        end
        copy.modData = any and md or nil
    end
    return EC.jsonEncode(copy)
end

-- The one snapshot a lot is stored as, once every copy passed the same signature: the first
-- copy's, with a loose record kept only when all of them carry it with the same value.
function Codec.lotSnapshot(items)
    local s = Codec.snapshot(items[1])
    if #items < 2 or type(s.modData) ~= "table" then return s end
    local others = {}
    for i = 2, #items do others[#others + 1] = call(items[i], "getModData") end
    local md, any = {}, false
    for k, v in pairs(s.modData) do
        local keep = true
        if looseRecord(k, v) then
            for _, o in ipairs(others) do
                if type(o) ~= "table" or o[k] ~= v then
                    keep = false
                    break
                end
            end
        end
        if keep then
            md[k] = v
            any = true
        end
    end
    s.modData = any and md or nil
    return s
end

-- Fresh item from a snapshot; nil, err when the script no longer exists on this server.
function Codec.rebuild(s)
    if type(s) ~= "table" or type(s.type) ~= "string" then return nil, "invalid_snapshot" end
    local item = instanceItem(s.type)
    if not item then return nil, "item_unavailable" end
    if type(s.condition) == "number" then call(item, "setCondition", s.condition) end
    -- head before edge: the edge is capped by the head's share of its maximum
    if type(s.head) == "number" then call(item, "setHeadCondition", s.head) end
    if type(s.headRepaired) == "number" then call(item, "setTimesHeadRepaired", s.headRepaired) end
    if type(s.sharpness) == "number" then call(item, "setSharpness", s.sharpness) end
    if type(s.ammo) == "number" then call(item, "setCurrentAmmoCount", s.ammo) end
    if s.clip then call(item, "setContainsClip", true) end
    if s.chamber then call(item, "setRoundChambered", true) end
    if s.jammed then call(item, "setJammed", true) end
    if type(s.fireMode) == "string" then call(item, "setFireMode", s.fireMode) end
    if s.infected then call(item, "setInfected", true) end
    if type(s.keyId) == "number" then call(item, "setKeyId", s.keyId) end
    if type(s.remote) == "table" then
        if type(s.remote.id) == "number" then call(item, "setRemoteControlID", s.remote.id) end
        if type(s.remote.range) == "number" then call(item, "setRemoteRange", s.remote.range) end
    end
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
        if type(food.calories) == "number" then call(item, "setCalories", food.calories) end
        if type(food.proteins) == "number" then call(item, "setProteins", food.proteins) end
        if type(food.lipids) == "number" then call(item, "setLipids", food.lipids) end
        if type(food.carbs) == "number" then call(item, "setCarbohydrates", food.carbs) end
        if type(food.baseHunger) == "number" then call(item, "setBaseHunger", food.baseHunger) end
        if type(food.unhappy) == "number" then call(item, "setUnhappyChange", food.unhappy) end
        if type(food.boredom) == "number" then call(item, "setBoredomChange", food.boredom) end
        if type(food.stress) == "number" then call(item, "setStressChange", food.stress) end
        if type(food.endurance) == "number" then call(item, "setEnduranceChange", food.endurance) end
        if type(food.fatigue) == "number" then call(item, "setFatigueChange", food.fatigue) end
        if type(food.pain) == "number" then call(item, "setPainReduction", food.pain) end
        if type(food.flu) == "number" then call(item, "setFluReduction", food.flu) end
        if type(food.cookingTime) == "number" then call(item, "setCookingTime", food.cookingTime) end
        if food.microwave then call(item, "setCookedInMicrowave", true) end
        if type(food.chef) == "string" then call(item, "setChef", food.chef) end
    end
    if type(age) == "number" then call(item, "setAge", age) end
    if type(s.repaired) == "number" then call(item, "setHaveBeenRepaired", s.repaired) end
    if type(s.readPages) == "number" then call(item, "setAlreadyReadPages", s.readPages) end
    if type(s.cloth) == "table" or type(s.look) == "table" then clothRebuild(item, s) end
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
            -- no setMediaIndex: see device_media in Codec.stateCheck (a listed device holds no medium)
            if d.on then call(dev, "setTurnedOnRaw", true) end
        end
    end
    if type(s.alarm) == "table" then
        if type(s.alarm.hour) == "number" then call(item, "setHour", s.alarm.hour) end
        if type(s.alarm.minute) == "number" then call(item, "setMinute", s.alarm.minute) end
        call(item, "setAlarmSet", s.alarm.set == true)
    end
    -- a fresh container starts with its script's fluid (FluidContainer.readFromScript,
    -- FluidContainer.java:99-112) and an empty one leaves no fluid in the snapshot: empty it either way
    local fc = call(item, "getFluidContainer")
    if fc then
        pcall(function()
            fc:Empty()
            local fl = type(s.fluid) == "table" and Fluid.Get(s.fluid.name)
            if fl and (s.fluid.amount or 0) > 0 then fc:addFluid(fl, s.fluid.amount) end
        end)
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

-- ---------- buyer preview ----------
-- What a buyer sees of a snapshot before paying: filtered, never the snapshot itself. No modData
-- (owner decision 2026-09-28), no key or remote ids (flags only), no raw per-part bytes. Maxima come
-- from one fresh copy per fullType, the way isCanonical gets its reference.
local maxima = {}
local function maximaOf(fullType)
    local m = maxima[fullType]
    if m then return m end
    m = {}
    local fresh = instanceItem(fullType)
    if fresh then
        m.cond = call(fresh, "getConditionMax")
        if call(fresh, "hasHeadCondition") == true then m.head = call(fresh, "getHeadConditionMax") end
        m.sharp = call(fresh, "hasSharpness") == true
        m.uses = call(fresh, "getCurrentUses")
        m.ammo = call(fresh, "getMaxAmmo")
        m.offAge = call(fresh, "getOffAge")
        local fc = call(fresh, "getFluidContainer")
        if fc then m.fluidCap = call(fc, "getCapacity") end
        local dev = call(fresh, "getDeviceData")
        m.battery = dev ~= nil and call(dev, "getIsBatteryPowered") == true
    end
    maxima[fullType] = m
    return m
end

local function num(v) if type(v) == "number" and v == v then return v end; return nil end
local function round(v, step) return math.floor(v / step + 0.5) * step end
local function bits(mask)
    local n = 0
    for i = 1, 32 do if hasBit(mask, i) then n = n + 1 end end
    return n
end

function Codec.preview(s)
    if type(s) ~= "table" or type(s.type) ~= "string" then return nil end
    local m = maximaOf(s.type)
    local p = { cond = num(s.condition), condMax = num(m.cond) }
    if num(m.head) then p.head, p.headMax = num(s.head) or m.head, m.head end
    if m.sharp then
        -- an unstored edge is at its maximum, which the head (or the body) caps (InventoryItem.java:4605-4611)
        local cap = 1
        if p.head and p.headMax and p.headMax > 0 then cap = p.head / p.headMax
        elseif p.cond and p.condMax and p.condMax > 0 then cap = p.cond / p.condMax end
        p.sharp = math.floor(math.min(num(s.sharpness) or 1, cap, 1) * 100 + 0.5)
    end
    if num(s.uses) and (num(m.uses) or 0) > 1 then p.uses, p.usesMax = s.uses, m.uses end
    -- a battery device (the script's UsesBattery -> setIsBatteryPowered, Item.java:1789): whether
    -- the battery is in and how full it is (DeviceData.java:259-273, 588-601)
    local d = s.device
    if m.battery and type(d) == "table" then
        if d.battery == false then p.battery = false
        elseif num(d.power) then p.power = math.floor(math.max(0, math.min(1, d.power)) * 100 + 0.5) end
    end
    if (num(m.ammo) or 0) > 0 then p.ammo, p.ammoMax = num(s.ammo) or 0, m.ammo end
    if s.clip then p.clip = true end
    if s.chamber then p.chamber = true end
    if s.jammed then p.jammed = true end
    if type(s.fireMode) == "string" and string.match(s.fireMode, "^[%w_]+$") and #s.fireMode <= 32 then p.fireMode = s.fireMode end
    if (num(s.repaired) or 0) > 0 then p.repaired = s.repaired end
    if (num(s.headRepaired) or 0) > 0 then p.headRepaired = s.headRepaired end
    if s.infected then p.infected = true end
    if s.keyId ~= nil then p.keyed = true end
    if s.remote ~= nil then p.paired = true end
    if type(s.name) == "string" then p.name = s.name end
    local food = s.food
    if type(food) == "table" then
        p.food = { cooked = food.cooked == true, burnt = food.burnt == true, frozen = food.frozen == true }
        -- freshness when it was listed; escrow keeps ageing it (Codec.rebuild), the client says so
        local age, off = num(s.age), num(m.offAge)
        if age and off and off < 1000000 then
            if age < off then p.food.freshDays = round((off - age) / rotSpeed(), 0.1) else p.food.stale = true end
        end
    end
    if type(s.fluid) == "table" and type(s.fluid.name) == "string" then
        p.fluid = s.fluid.name
        p.fluidL = round(num(s.fluid.amount) or 0, 0.01)
        if num(m.fluidCap) then p.fluidCap = round(m.fluidCap, 0.01) end
    end
    local c = s.cloth
    if type(c) == "table" then
        p.holes = bits(c.holes)
        local n = 0
        for _ in string.gmatch(c.patches or "", "%d+:%d+:%d+") do n = n + 1 end
        p.patches = n
        p.blood = math.floor((num(c.bloodLv) or 0) + 0.5)
        p.dirt = math.floor((num(c.dirtLv) or 0) + 0.5)
        p.wet = math.floor((num(c.wet) or 0) + 0.5)
    end
    return p
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
