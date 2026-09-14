-- MinidoracatEconomyFor42 — shared core (loaded on both dedicated server and client).
--
-- Rules for this file (see AGENTS.md / pz-family-docs/pitfalls.md):
--   * every string literal must stay ASCII: Kahlua's LexState truncates each char to one byte,
--     so any user-visible text goes through Translate/<LANG>/*.json keys instead;
--   * no client-only / server-only globals here (getAccessLevel, sendClientCommand, ...);
--   * Kahlua has no next/assert/xpcall; iterate with pairs, sort with EC.sortSafe.
--
-- Engine references (snapshot 42.20.4-20260826, see AGENTS.md API table):
--   getTimestampMs        LuaManager.java:9267-9272  (System.currentTimeMillis, UTC ms)
--   Global ModData        ModData.java:16-49 -> GlobalModData.java:74-102; saved only by
--                         ServerMap.QueuedSaveAll (ServerMap.java:409), readable by any logged-in
--                         client (GlobalModDataRequestPacket.java:15) -> current state only, no secrets
--   SandboxVars           pushed to clients on connect (ConnectionDetails.java:137-138)

MinidoracatEconomy = MinidoracatEconomy or {}
local EC = MinidoracatEconomy

EC.MOD_ID = "MinidoracatEconomyFor42"
EC.LOG_TAG = "[MinidoracatEconomyFor42]"
EC.COMMAND_MODULE = "MinidoracatEconomy"      -- sendClientCommand / sendServerCommand module name
EC.MODDATA_KEY = "MinidoracatEconomy"          -- Global ModData table name
EC.PLAYER_MODDATA_KEY = "MinidoracatEconomy"   -- sub-table inside player:getModData() (pending records)
EC.SANDBOX_PAGE = "MinidoracatEconomy"         -- SandboxVars.MinidoracatEconomy.*
EC.SCHEMA_VERSION = 1
EC.VERSION = "0.1.2"

-- Static half of the currency registry (spec section 18.1). Runtime overrides
-- (nameOverride / iconHash / enabled / caps) live in Global ModData `config.currencies[id]`
-- and are layered on top by the server (stage B4). Never hardcode a currency id elsewhere.
EC.CURRENCIES = {
    survivor = {
        id = "survivor", sortOrder = 1,
        nameKey = "IGUI_MinidoracatEconomy_Currency_survivor",
        iconDefault = "media/ui/MinidoracatEconomy/currency_survivor.png",
        marketUnit = true, directTransfer = false,
    },
    cat = {
        id = "cat", sortOrder = 2,
        nameKey = "IGUI_MinidoracatEconomy_Currency_cat",
        iconDefault = "media/ui/MinidoracatEconomy/currency_cat.png",
        marketUnit = true, directTransfer = false,
    },
}
EC.CURRENCY_ORDER = { "survivor", "cat" }

-- Shop buyback daily caps: one option key pair per currency, so the currency page and the shop
-- read the same truth (ECConfig.buybackCaps -> Cfg.currency(id).buybackCaps). A cap of 0 means
-- this currency does not buy anything back; it never means unlimited.
EC.BUYBACK_OPTIONS = {
    survivor = { account = "ShopBuybackPerAccountDaily", server = "ShopBuybackServerDaily" },
    cat = { account = "ShopCatBuybackPerAccountDaily", server = "ShopCatBuybackServerDaily" },
}

-- Terminals (stage C thin slice, spec 12 stage C / 17.1): the mod's own terminal tiles (the ATM
-- and the catgirl android, four facings each, MinidoracatEconomy_tiles.tiles) plus the vanilla
-- "Terminal" consoles an admin may register in an existing building (appliances_com_01_52-55
-- CeroSec, security_01_0-3 Security; newtiledefinitions.tiles CustomName=Terminal). Write
-- commands always need the player within TERMINAL_RANGE tiles (Chebyshev, same level) of a
-- registered terminal or a vanilla ATM; the sandbox option RemoteReadOnly only allows opening the window
-- elsewhere for read-only browsing.
EC.TERMINAL_SPRITES = {
    MinidoracatEconomy_terminal_0 = true, MinidoracatEconomy_terminal_1 = true,
    MinidoracatEconomy_terminal_2 = true, MinidoracatEconomy_terminal_3 = true,
    MinidoracatEconomy_catgirl_0 = true, MinidoracatEconomy_catgirl_1 = true,
    MinidoracatEconomy_catgirl_2 = true, MinidoracatEconomy_catgirl_3 = true,
    appliances_com_01_52 = true, appliances_com_01_53 = true, appliances_com_01_54 = true, appliances_com_01_55 = true,
    security_01_0 = true, security_01_1 = true, security_01_2 = true, security_01_3 = true,
}
EC.TERMINAL_RANGE = 2
EC.TERMINAL_KINDS = { atm = true, trade = true }

-- Vanilla floor-standing and wall-mounted ATMs (Tiles2x.pack bank_01 frames 64-67).
-- These grant nearby access only: no persistent registration, radio, or demolition privilege.
EC.ATM_SPRITES = {
    location_business_bank_01_64 = true, location_business_bank_01_65 = true,
    location_business_bank_01_66 = true, location_business_bank_01_67 = true,
}

function EC.isAtmObject(object)
    local sprite = object and object:getSprite()
    return sprite ~= nil and EC.ATM_SPRITES[sprite:getName()] == true
end

function EC.isAtmSquare(square)
    if not square then return false end
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        if EC.isAtmObject(objects:get(i)) then return true end
    end
    return false
end

function EC.mapAtmEnabled()
    local option = isClient() and EC.Client and EC.Client.options and EC.Client.options.MapATMAsTerminal
    if type(option) == "table" and type(option.value) == "boolean" then return option.value end
    return EC.sandbox("MapATMAsTerminal", true)
end

function EC.nearMapAtm(player)
    if not EC.mapAtmEnabled() then return false end
    local cell = getCell()
    if not cell then return false end
    local x, y, z = player:getX(), player:getY(), math.floor(player:getZ())
    local range = EC.TERMINAL_RANGE
    for sx = math.ceil(x - range), math.floor(x + range) do
        for sy = math.ceil(y - range), math.floor(y + range) do
            if EC.isAtmSquare(cell:getGridSquare(sx, sy, z)) then return true end
        end
    end
    return false
end

-- Item classes the market can never list, whatever whitelist.json says: their Java-side state
-- (contents, keys, map markers, worn/attached objects, the animal) is not in the bounded
-- snapshot, so a rebuilt copy would silently lose it. Script items carry their class as an
-- ItemType (Item.java:1375-1385 getItemType/isItemType; the registry names are the static fields
-- of ItemType.java:7-22, exposed to Lua by LuaManager.java:2311). Shared: the server refuses in
-- Codec.check, the admin page hides these classes from the category list. Radios are not here:
-- their DeviceData travels in the snapshot (Codec.snapshot / rebuild).
EC.LISTING_FIXED_TYPES = { "CONTAINER", "CLOTHING", "KEY", "KEY_RING", "MOVEABLE", "MAP", "ALARM_CLOCK", "ALARM_CLOCK_CLOTHING", "ANIMAL" }
function EC.isFixedType(script)
    if script == nil or ItemType == nil then return false end
    for _, name in ipairs(EC.LISTING_FIXED_TYPES) do
        local t = ItemType[name]
        if t ~= nil then
            local ok, hit = pcall(script.isItemType, script, t)
            if ok and hit == true then return true end
        end
    end
    return false
end

-- CraftRecipe OnAddToMenu callback of the terminal entity (CraftRecipe.java:379-380, called by
-- ISRecipeScrollingListBox.lua:344-347 on the client): only admins see the build entry. Server
-- side never lists build menus; getAccessLevel is client-only (LuaManager.java:4435-4436).
function MinidoracatEconomy_AdminBuildOnly(param)
    if isServer() then return false end
    local ok, level = pcall(getAccessLevel)
    return ok and level == "admin"
end

function EC.log(msg)
    print(EC.LOG_TAG .. " " .. tostring(msg))
end

function EC.now()
    return getTimestampMs()
end

-- Identity of every ModData record and event is <epoch>:<seq> (spec 19.7 rule four):
-- epoch = wall-clock ms string of the server start, seq = monotonic ModData counter.
-- A rollback restarts seq from loadedSeq under a new epoch, so ids never collide across branches.
function EC.makeId(epoch, seq)
    return tostring(epoch) .. ":" .. tostring(seq)
end

function EC.parseId(id)
    if type(id) ~= "string" then return nil end
    local colon = string.find(id, ":", 1, true)
    if not colon then return nil end
    local epoch = string.sub(id, 1, colon - 1)
    local seq = tonumber(string.sub(id, colon + 1))
    if epoch == "" or not seq then return nil end
    return epoch, seq
end

-- Gregorian month length shared by typed dates and the client calendar; month is 1..12.
function EC.daysInMonth(year, month)
    if month == 2 then
        return year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0) and 29 or 28
    end
    return (month == 4 or month == 6 or month == 9 or month == 11) and 30 or 31
end

-- "YYYY-MM-DD" (or "YYYY/MM/DD") -> start of that civil day in ms, for a clock that is
-- offsetMinutes ahead of UTC (the client passes its localOffsetMinutes); nil when malformed.
-- Days-from-civil (Howard Hinnant), so no os.time / time zone of the JVM is involved.
function EC.parseDay(text, offsetMinutes)
    if type(text) ~= "string" then return nil end
    local y, m, d = string.match(text, "^%s*(%d%d%d%d)[-/](%d%d?)[-/](%d%d?)%s*$")
    if not y then return nil end
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    if m < 1 or m > 12 or d < 1 or d > EC.daysInMonth(y, m) then return nil end
    if m <= 2 then y = y - 1 end
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local mp = (m + 9) % 12
    local doy = math.floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    local days = era * 146097 + doe - 719468
    return days * 86400000 - (tonumber(offsetMinutes) or 0) * 60000
end

-- One page of a filtered, sorted list (the history / statement / audit pages all page on
-- the client: a reply is at most a few hundred rows). opts = { kinds = {[kind]=true}?, kindField?
-- ("kind"), fromMs?, toMs? (exclusive), timeField? ("ts"), sortKey? (field name or function),
-- desc?, page?, perPage? }. Returns rows, page, pages, total (rows filtered).
function EC.filterPage(list, opts)
    opts = opts or {}
    local kindField, timeField = opts.kindField or "kind", opts.timeField or "ts"
    local kinds = opts.kinds
    local rows = {}
    for _, e in ipairs(list or {}) do
        local ok = true
        if kinds and not kinds[e[kindField]] then ok = false end
        local t = tonumber(e[timeField])
        if ok and opts.fromMs and (not t or t < opts.fromMs) then ok = false end
        if ok and opts.toMs and (not t or t >= opts.toMs) then ok = false end
        if ok then rows[#rows + 1] = e end
    end
    local key = opts.sortKey
    if key ~= nil then
        local get = type(key) == "function" and key or function(e) return e[key] end
        local desc = opts.desc == true
        EC.sortSafe(rows, function(a, b)
            local av, bv = get(a), get(b)
            if av == nil or bv == nil then return av ~= nil and bv == nil end
            if type(av) ~= type(bv) then av, bv = tostring(av), tostring(bv) end
            if type(av) == "string" then av, bv = string.lower(av), string.lower(bv) end
            if av == bv then return false end
            if desc then return av > bv end
            return av < bv
        end)
    end
    local total = #rows
    local perPage = math.max(1, math.floor(tonumber(opts.perPage) or 25))
    local pages = math.max(1, math.ceil(total / perPage))
    local page = math.max(1, math.min(pages, math.floor(tonumber(opts.page) or 1)))
    local out = {}
    for i = (page - 1) * perPage + 1, math.min(total, page * perPage) do out[#out + 1] = rows[i] end
    return out, page, pages, total
end

-- Stable insertion sort avoids Kahlua's recursive table.sort (guarded by verify_mod.py).
-- `less(a, b)` must return true only when a sorts strictly before b.
function EC.sortSafe(list, less)
    for i = 2, #list do
        local v = list[i]
        local j = i - 1
        while j >= 1 and less(v, list[j]) do
            list[j + 1] = list[j]
            j = j - 1
        end
        list[j + 1] = v
    end
    return list
end

-- Runtime overrides (server only): ECConfig installs a reader over ModData config.options so an
-- admin change from the settings page wins over the sandbox file without a restart.
EC.optionOverride = nil   -- function(key) -> value or nil

-- Sandbox read with type guard: a missing page (mod loaded without sandbox-options) or a
-- value of the wrong type silently falls back to the code default, logged once per key.
local sandboxWarned = {}
function EC.sandboxDefault(key, default)
    local page = SandboxVars and SandboxVars[EC.SANDBOX_PAGE]
    local v = page and page[key]
    if v == nil or type(v) ~= type(default) then
        if not sandboxWarned[key] then
            sandboxWarned[key] = true
            EC.log("sandbox " .. key .. " missing or wrong type, using default " .. tostring(default))
        end
        return default
    end
    return v
end

function EC.sandbox(key, default)
    if EC.optionOverride then
        local v = EC.optionOverride(key)
        if v ~= nil then
            if type(v) == type(default) then return v end
            -- One exception, by design: a role list is stored as an array of exact role names,
            -- while the sandbox half of the same key is one ';'-separated string - the two halves
            -- of that key have different types. Every other key keeps the strict type guard.
            local spec = EC.OPTION_BY_KEY and EC.OPTION_BY_KEY[key]
            if spec ~= nil and spec.kind == "roles" and type(v) == "table" then return v end
        end
    end
    return EC.sandboxDefault(key, default)
end

-- Role names -> set, for an exact-name membership test. Two shapes reach this:
--   * the sandbox file half, "admin;gm" (commas are impossible there, ScriptParser splits on
--     them - pitfalls.md "Sandbox 選項"): split on ';' only, trimmed at both ends;
--   * the runtime override half (admin.option): an array of exact role names.
-- Nothing is lower-cased and nothing is split on whitespace: role lookup is case sensitive
-- (Roles.java:302-305) and a host-made role may contain spaces, so "Admin" and "admin" are two
-- different roles and must never authorise each other.
function EC.roleSet(value)
    local set = {}
    if type(value) == "table" then
        for i = 1, #value do
            local name = value[i]
            if type(name) == "string" and name ~= "" then set[name] = true end
        end
        return set
    end
    for part in string.gmatch(tostring(value or ""), "[^;]+") do
        local name = (string.gsub(part, "^%s*(.-)%s*$", "%1"))
        if name ~= "" then set[name] = true end
    end
    return set
end

-- Every role this server actually has, highest rank first: { name = <exact>, position = n }.
-- getRoles (LuaManager.java:3359-3365 -> Roles.getRoles) answers on the dedicated server as well
-- as on the client and includes the host's custom roles; the order follows vanilla's own role
-- list (ISRolesList.lua:74-79, position descending) with the name as tie-break so it is stable.
-- An unavailable API or a failed read returns nil, never a fabricated list of default roles.
function EC.roleChoices()
    local out = {}
    local ok = pcall(function()
        local roles = getRoles()
        for i = 0, roles:size() - 1 do
            local role = roles:get(i)
            local name = role:getName()
            if type(name) == "string" and name ~= "" then
                out[#out + 1] = { name = name, position = tonumber(role:getPosition()) or 0 }
            end
        end
    end)
    if not ok then return nil end
    EC.sortSafe(out, function(a, b)
        if a.position ~= b.position then return a.position > b.position end
        return a.name < b.name
    end)
    return out
end

-- May this player change the options that decide who the economy's admins are? Only the native
-- role-editing capability says yes: Capability.RolesWrite is the gate on vanilla's own role
-- editor (ISRolesList.lua:20/110, RolesEditPacket.java:19), answered by Role.hasCapability
-- (Role.java:185-191). Deliberately not one of this mod's own role lists - the list this guards
-- could then be re-pointed by the very people it limits - and deliberately not "may see the
-- panel": moderator holds SandboxOptions without RolesWrite (Roles.java:448-461). Fails closed
-- when the API or the capability is missing.
function EC.canManageSettings(player)
    if player == nil then return false end
    local ok, cap = pcall(function() return player:getRole():hasCapability(Capability.RolesWrite) end)
    return ok and cap == true
end

-- Terminal administration also requires the native AddItem capability.
function EC.canManageTerminals(player)
    local ok, role = pcall(function() return player:getRole():getName() end)
    if not ok or type(role) ~= "string" then return false end
    local option = isClient() and EC.Client and EC.Client.options and EC.Client.options.AdminRoles
    local roles
    if type(option) == "table" and (type(option.value) == "string" or type(option.value) == "table") then
        roles = option.value
    else roles = EC.sandbox("AdminRoles", "admin") end
    if not EC.roleSet(roles)[role] then return false end
    local okCap, cap = pcall(function() return player:getRole():hasCapability(Capability.AddItem) end)
    return okCap and cap == true
end

-- ---------- time ----------

-- Civil date from epoch ms, computed by hand so the harness (standard Lua) and Kahlua agree:
-- Kahlua's os.date is fixed UTC while standard Lua's is local time (pitfalls.md).
-- Algorithm: days-from-civil inverse (H. Hinnant), valid for the whole range we care about.
function EC.utcDate(ms)
    local days = math.floor(ms / 86400000)
    local z = days + 719468
    local era = math.floor(z / 146097)
    local doe = z - era * 146097
    local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
    local y = yoe + era * 400
    local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
    local mp = math.floor((5 * doy + 2) / 153)
    local d = doy - math.floor((153 * mp + 2) / 5) + 1
    local m = mp < 10 and mp + 3 or mp - 9
    if m <= 2 then y = y + 1 end
    return y, m, d
end

local function pad2(n) return n < 10 and ("0" .. n) or tostring(n) end

function EC.dayKey(ms)          -- "YYYYMMDD" (UTC)
    local y, m, d = EC.utcDate(ms)
    return tostring(y) .. pad2(m) .. pad2(d)
end

function EC.monthKey(ms)        -- "YYYYMM" (UTC)
    local y, m = EC.utcDate(ms)
    return tostring(y) .. pad2(m)
end

-- ---------- JSON (encode only; one line per record) ----------

local function jsonString(s)
    local out = string.gsub(s, '[%c"\\]', function(ch)
        if ch == '"' then return '\\"' end
        if ch == "\\" then return "\\\\" end
        if ch == "\n" then return "\\n" end
        if ch == "\r" then return "\\r" end
        if ch == "\t" then return "\\t" end
        return string.format("\\u%04x", string.byte(ch))
    end)
    return '"' .. out .. '"'
end

local function jsonNumber(n)
    if n ~= n or n == math.huge or n == -math.huge then return "null" end
    if n == math.floor(n) and math.abs(n) < 1e15 then return string.format("%.0f", n) end
    return string.format("%.6f", n)
end

-- Tables with a positive #len and no other keys encode as arrays; everything else as objects
-- with keys sorted (deterministic lines). Non-string keys are stringified. Depth is capped.
function EC.jsonEncode(value, depth)
    depth = depth or 0
    local t = type(value)
    if t == "string" then return jsonString(value) end
    if t == "number" then return jsonNumber(value) end
    if t == "boolean" then return value and "true" or "false" end
    if t ~= "table" then return "null" end
    if depth > 8 then return '"<depth>"' end
    local n = #value
    local isArray = n > 0
    if isArray then
        for k in pairs(value) do
            if type(k) ~= "number" or k < 1 or k > n or k ~= math.floor(k) then isArray = false break end
        end
    end
    local parts = {}
    if isArray then
        for i = 1, n do parts[i] = EC.jsonEncode(value[i], depth + 1) end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for k in pairs(value) do keys[#keys + 1] = tostring(k) end
    EC.sortSafe(keys, function(a, b) return a < b end)
    for i, k in ipairs(keys) do
        local v = value[k]
        if v == nil then v = value[tonumber(k)] end
        parts[i] = jsonString(k) .. ":" .. EC.jsonEncode(v, depth + 1)
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

-- ---------- JSON decode (strict enough for our own NDJSON, whitelist.json and inbox files) ----------
-- Returns value, nil on success; nil, message on error. Objects become tables keyed by string,
-- arrays become 1-based sequences, null becomes EC.JSON_NULL (so keys are not lost).
EC.JSON_NULL = setmetatable({}, { __tostring = function() return "null" end })

local function decodeError(s, pos, msg)
    return nil, msg .. " at " .. tostring(pos) .. " near '" .. string.sub(s, pos, pos + 12) .. "'"
end

local function skipSpace(s, pos)
    local _, e = string.find(s, "^[ \t\r\n]*", pos)
    return e + 1
end

local decodeValue

local function unicodeChar(code)
    -- Kahlua strings are UTF-16 (StringLib.java:760-768); the offline Lua runtime uses UTF-8.
    if utf8 and utf8.char then return utf8.char(code) end
    if code < 65536 then return string.char(code) end
    code = code - 65536
    return string.char(55296 + math.floor(code / 1024), 56320 + code % 1024)
end

local function decodeString(s, pos)
    -- pos is at the opening quote
    local out = {}
    local i = pos + 1
    local n = #s
    while i <= n do
        local c = string.sub(s, i, i)
        if c == '"' then
            return table.concat(out), i + 1
        elseif c == "\\" then
            local e = string.sub(s, i + 1, i + 1)
            if e == "n" then out[#out + 1] = "\n"
            elseif e == "t" then out[#out + 1] = "\t"
            elseif e == "r" then out[#out + 1] = "\r"
            elseif e == "b" then out[#out + 1] = "\b"
            elseif e == "f" then out[#out + 1] = "\f"
            elseif e == "u" then
                local hex = string.sub(s, i + 2, i + 5)
                if not string.match(hex, "^%x%x%x%x$") then return nil, i end
                local code = tonumber(hex, 16)
                if code >= 55296 and code <= 56319 then
                    local lowHex = string.sub(s, i + 8, i + 11)
                    if string.sub(s, i + 6, i + 7) ~= "\\u" or not string.match(lowHex, "^%x%x%x%x$") then return nil, i end
                    local low = tonumber(lowHex, 16)
                    if low < 56320 or low > 57343 then return nil, i end
                    code = 65536 + (code - 55296) * 1024 + low - 56320
                    i = i + 6
                elseif code >= 56320 and code <= 57343 then
                    return nil, i
                end
                out[#out + 1] = unicodeChar(code)
                i = i + 4
            elseif e == '"' or e == "\\" or e == "/" then
                out[#out + 1] = e
            else
                return nil, i
            end
            i = i + 2
        else
            if string.byte(c) < 32 then return nil, i end
            out[#out + 1] = c
            i = i + 1
        end
    end
    return nil, pos
end

decodeValue = function(s, pos)
    pos = skipSpace(s, pos)
    local c = string.sub(s, pos, pos)
    if c == "{" then
        local obj = {}
        pos = skipSpace(s, pos + 1)
        if string.sub(s, pos, pos) == "}" then return obj, pos + 1 end
        while true do
            pos = skipSpace(s, pos)
            if string.sub(s, pos, pos) ~= '"' then return decodeError(s, pos, "expected key") end
            local key, np = decodeString(s, pos)
            if not key then return decodeError(s, pos, "bad string") end
            pos = skipSpace(s, np)
            if string.sub(s, pos, pos) ~= ":" then return decodeError(s, pos, "expected ':'") end
            local value, np2 = decodeValue(s, pos + 1)
            if type(np2) ~= "number" then return nil, np2 end
            obj[key] = value
            pos = skipSpace(s, np2)
            local d = string.sub(s, pos, pos)
            if d == "," then pos = pos + 1
            elseif d == "}" then return obj, pos + 1
            else return decodeError(s, pos, "expected ',' or '}'") end
        end
    elseif c == "[" then
        local arr = {}
        pos = skipSpace(s, pos + 1)
        if string.sub(s, pos, pos) == "]" then return arr, pos + 1 end
        while true do
            local value, np = decodeValue(s, pos)
            if type(np) ~= "number" then return nil, np end
            arr[#arr + 1] = value
            pos = skipSpace(s, np)
            local d = string.sub(s, pos, pos)
            if d == "," then pos = pos + 1
            elseif d == "]" then return arr, pos + 1
            else return decodeError(s, pos, "expected ',' or ']'") end
        end
    elseif c == '"' then
        local str, np = decodeString(s, pos)
        if not str then return decodeError(s, pos, "unterminated string") end
        return str, np
    elseif string.sub(s, pos, pos + 3) == "true" then return true, pos + 4
    elseif string.sub(s, pos, pos + 4) == "false" then return false, pos + 5
    elseif string.sub(s, pos, pos + 3) == "null" then return EC.JSON_NULL, pos + 4
    else
        local numStr = string.match(s, "^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
        local num = numStr and tonumber(numStr)
        if not num then return decodeError(s, pos, "unexpected token") end
        return num, pos + #numStr
    end
end

function EC.jsonDecode(s)
    if type(s) ~= "string" then return nil, "not a string" end
    local value, np = decodeValue(s, 1)
    if type(np) ~= "number" then return nil, np end
    np = skipSpace(s, np)
    if np <= #s then return decodeError(s, np, "trailing garbage") end
    return value
end

-- File-system safe, collision-free name for a username: [A-Za-z0-9_-] kept, everything else
-- becomes _xHHHH_ (UTF-16 code unit). Usernames may be non-ASCII on the production server.
function EC.safeName(name)
    return (string.gsub(tostring(name), "[^A-Za-z0-9_%-]", function(ch)
        return string.format("_x%04x_", string.byte(ch))
    end))
end

-- ---------- account classes (shared: admin money view filter + panel labels) ----------
--
-- The ledger's account namespace is flat; its only structure is the prefix set the server keeps
-- in ECLedger.SYSTEM_PREFIXES ("SYSTEM_", "EXTERNAL_", "MOD:"). One class per account name,
-- derived from the name alone so client and server agree without a round trip.
--
-- Case-sensitive, exactly like L.isSystemAccount: "system_mint" is a player who picked that
-- name, not the faucet. Exact names win over the prefixes, so "SYSTEM_MINT_extra" is a system
-- account of unknown purpose and never counted as minting. An unmapped SYSTEM_/EXTERNAL_
-- account lands in "system" instead of disappearing, the same way txGroup keeps unknown kinds.
-- ACCOUNT_CLASSES is the wire vocabulary (ids only, never a translated name) in display order.
EC.ACCOUNT_CLASSES = { "player", "mint", "burn", "adjust", "mod", "discord", "system" }

function EC.accountClass(account)
    if type(account) ~= "string" or account == "" then return nil end
    if account == "SYSTEM_MINT" then return "mint" end
    if account == "SYSTEM_BURN" then return "burn" end
    if account == "SYSTEM_ADJUST" then return "adjust" end
    if string.sub(account, 1, 4) == "MOD:" then return "mod" end
    if string.sub(account, 1, 17) == "EXTERNAL_DISCORD_" then return "discord" end
    if string.sub(account, 1, 7) == "SYSTEM_" or string.sub(account, 1, 9) == "EXTERNAL_" then
        return "system"
    end
    return "player"
end

-- Sandbox options of this mod: one schema shared by the server (validation of runtime overrides,
-- `admin.option`) and the admin panel's settings page (controls, grouping, formatting).
--   kind     bool | int | number | list_int | text | roles
--   min/max/step  numeric bounds (ints) / step of the +- buttons
--   unit     coin | minutes | hour | tz | roles | days   (presentation only)
--   locked   true = server file only, never editable in-game (no option needs this today)
--   manageOnly  true = the option decides who this mod's admins are or how far they may reach,
--            so changing it needs the native role-editing capability (EC.canManageSettings),
--            not the economy write role it hands out: the people a limit applies to must not be
--            the people who raise it (spec 19.3 decision 11, re-decided in favour of an in-game
--            path for whoever already owns the server's roles)
--   kind "roles" values are an array of exact native role names at runtime and a ';'-separated
--            string in the sandbox file (EC.roleSet reads both, EC.roleChoices offers the names)
--   currency values live in config.currencies (ECConfig) and are edited through the currency page
EC.OPTIONS = {
    { key = "CheckinAmount", group = "rewards", kind = "int", min = 0, max = 1000000, step = 10, default = 30, unit = "coin", zeroOff = true },
    { key = "CheckinMinPlaytimeMinutes", group = "rewards", kind = "int", min = 0, max = 1440, step = 5, default = 15, unit = "minutes" },
    { key = "CheckinServerDailyCap", group = "rewards", kind = "int", min = 0, max = 100000000, step = 1000, default = 0, unit = "coin", zeroUnlimited = true },
    { key = "CheckinDailyLimit", group = "rewards", kind = "int", min = 1, max = 24, step = 1, default = 1 },
    { key = "CheckinIntervalMinutes", group = "rewards", kind = "int", min = 1, max = 1440, step = 5, default = 60, unit = "minutes" },
    { key = "RewardDayResetHour", group = "rewards", kind = "int", min = 0, max = 23, step = 1, default = 0, unit = "hour" },
    { key = "RewardTimezoneUTC", group = "rewards", kind = "number", min = -12, max = 14, step = 0.5, default = 8, unit = "tz" },
    { key = "MilestoneDays", group = "rewards", kind = "list_int", min = 1, max = 3650, maxItems = 16, default = "1;3;7;14;30", unit = "days" },
    { key = "MilestoneAmounts", group = "rewards", kind = "list_int", min = 0, max = 1000000, maxItems = 16, default = "100;150;250;400;1000", unit = "coin" },
    { key = "SeasonDays", group = "seasons", kind = "int", min = 0, max = 3650, step = 1, default = 0, unit = "days", manageOnly = true, zeroOff = true },
    { key = "AdminRoles", group = "admin", kind = "roles", default = "admin", unit = "roles", manageOnly = true },
    { key = "ReadOnlyRoles", group = "admin", kind = "roles", default = "moderator", unit = "roles", manageOnly = true },
    -- empty by default: holding the write role is never on its own a licence to pay yourself
    { key = "AdminSelfAdjustRoles", group = "admin", kind = "roles", default = "", unit = "roles", manageOnly = true },
    { key = "AdminAdjustMaxPerTx", group = "admin", kind = "int", min = 1, max = 10000000, default = 5000, unit = "coin", manageOnly = true },
    { key = "AdminAdjustDailyPerAdmin", group = "admin", kind = "int", min = 1, max = 100000000, default = 10000, unit = "coin", manageOnly = true },
    { key = "AdminAdjustServerDaily", group = "admin", kind = "int", min = 1, max = 1000000000, default = 50000, unit = "coin", manageOnly = true },
    { key = "BalanceMax", group = "currency", kind = "int", min = 1000, max = 1000000000, step = 100000, default = 10000000, unit = "coin", page = "Currencies" },
    { key = "CatRatePointsPerCoin", group = "currency", kind = "int", min = 1, max = 1000000, default = 1, page = "Currencies" },
    { key = "CatPerOrderMin", group = "currency", kind = "int", min = 1, max = 1000000, default = 10, page = "Currencies" },
    { key = "CatPerOrderMax", group = "currency", kind = "int", min = 1, max = 1000000, default = 5000, page = "Currencies" },
    { key = "CatPerAccountDaily", group = "currency", kind = "int", min = 1, max = 100000000, default = 5000, page = "Currencies" },
    { key = "CatServerDaily", group = "currency", kind = "int", min = 1, max = 100000000, default = 50000, page = "Currencies" },
    { key = "RemoteReadOnly", group = "general", kind = "bool", default = true },
    { key = "MapATMAsTerminal", group = "general", kind = "bool", default = true },
    { key = "MapATMAllowDestruction", group = "general", kind = "bool", default = false },
    { key = "LeaderboardEnabled", group = "general", kind = "bool", default = true },
    { key = "LeaderboardShowAmounts", group = "general", kind = "bool", default = false },
    { key = "ShopBuybackEnabled", group = "shop", kind = "bool", default = false },
    { key = "ShopBuybackPerAccountDaily", group = "shop", kind = "int", min = 0, max = 100000000, step = 100, default = 500, unit = "coin", zeroOff = true },
    { key = "ShopBuybackServerDaily", group = "shop", kind = "int", min = 0, max = 100000000, step = 1000, default = 20000, unit = "coin", zeroOff = true },
    { key = "ShopCatBuybackPerAccountDaily", group = "shop", kind = "int", min = 0, max = 100000000, step = 100, default = 0, unit = "coin", zeroOff = true },
    { key = "ShopCatBuybackServerDaily", group = "shop", kind = "int", min = 0, max = 100000000, step = 1000, default = 0, unit = "coin", zeroOff = true },
    { key = "MarketListingFeePercent", group = "market", kind = "int", min = 0, max = 50, step = 1, default = 2, unit = "percent" },
    { key = "MarketSalesTaxPercent", group = "market", kind = "int", min = 0, max = 50, step = 1, default = 5, unit = "percent" },
    { key = "MarketListingDays", group = "market", kind = "int", min = 1, max = 30, step = 1, default = 7, unit = "days" },
    { key = "MarketMaxListings", group = "market", kind = "int", min = 1, max = 50, step = 1, default = 5 },
    { key = "MailboxPerAccount", group = "market", kind = "int", min = 5, max = 500, step = 5, default = 50 },
    { key = "MarketPriceMin", group = "market", kind = "int", min = 1, max = 1000000, step = 1, default = 1, unit = "coin" },
    { key = "MarketPriceMax", group = "market", kind = "int", min = 1, max = 1000000000, step = 1000, default = 1000000, unit = "coin" },
    { key = "AuctionMinHours", group = "auction", kind = "int", min = 1, max = 168, step = 1, default = 6, unit = "hour" },
    { key = "AuctionMaxHours", group = "auction", kind = "int", min = 1, max = 168, step = 1, default = 72, unit = "hour" },
    { key = "AuctionMaxPerPlayer", group = "auction", kind = "int", min = 1, max = 50, step = 1, default = 3 },
    { key = "AuctionMinIncrementPercent", group = "auction", kind = "int", min = 1, max = 100, step = 1, default = 5, unit = "percent" },
    { key = "RadioIntervalMinutes", group = "radio", kind = "int", min = 0, max = 120, step = 5, default = 10, unit = "minutes", zeroOff = true },
    -- the voice/chat relay is its own switch: an upgrade must never start picking up microphones
    -- next to a trade terminal because the market summary happened to be on (spec 17.3, radio
    -- contract decision 4). RadioIntervalMinutes = 0 still only stops the summary.
    { key = "RadioRelayEnabled", group = "radio", kind = "bool", default = false },
    { key = "RadioFrequency", group = "radio", kind = "int", min = 88000, max = 108000, step = 200, default = 101100, unit = "mhz" },
    { key = "RadioRange", group = "radio", kind = "int", min = 0, max = 5000, step = 50, default = 500, unit = "tiles", zeroUnlimited = true },
    { key = "RadioLanguage", group = "radio", kind = "text", default = "auto", unit = "lang" },
}
EC.OPTION_GROUPS = { "rewards", "seasons", "admin", "currency", "shop", "market", "auction", "radio", "general" }
EC.OPTION_BY_KEY = {}
for _, o in ipairs(EC.OPTIONS) do EC.OPTION_BY_KEY[o.key] = o end

-- "1;3;7" -> { 1, 3, 7 } or nil when any item is not an integer within [min, max] or the list
-- is empty / too long. Shared by the server validator and the panel's pre-check.
function EC.parseIntList(text, spec)
    if type(text) ~= "string" then return nil end
    local out = {}
    for item in string.gmatch(text, "[^;]+") do
        local n = tonumber((string.gsub(item, "^%s*(.-)%s*$", "%1")))
        if not n or n ~= math.floor(n) or n < spec.min or n > spec.max then return nil end
        out[#out + 1] = n
        if #out > (spec.maxItems or 16) then return nil end
    end
    if #out == 0 then return nil end
    return out
end

function EC.countKeys(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- ---------- currency icon sync (stage B8; server ECIcons.lua, client ECIconCache.lua) ----------
--
-- Bytes travel as Lua strings whose chars are 0..255 ("byte strings"): a command-table string is
-- serialised as int16 byteLength + UTF-8 (TableNetworkUtils.java:80-81 -> ByteBufferWriter.putUTF
-- -> GameWindow.StringUTF.save, GameWindow.java:1263-1272) and decoded with new String(bytes,
-- UTF_8) (ByteBufferReader.java:48-53), so every char U+0000..U+00FF round-trips exactly (1-2
-- bytes each). The int16 is signed: a chunk of ICON_CHUNK_CHARS chars is at most 2x that in
-- bytes and must stay below 32767. DataOutputStream.writeBytes(String) on the client writes the
-- low 8 bits of each char (NoticeBoard NBImageCache, verified in production).
EC.ICON_MAX_BYTES = 65536        -- hard cap on both ends (a 64 px PNG is ~10 KB)
EC.ICON_CHUNK_CHARS = 8192       -- <= 16384 bytes on the wire
EC.ICON_HASH_LEN = 8

-- Streaming DJB2 over byte values (Kahlua has no bit ops; 33*h + b stays exact below 2^53 when
-- reduced mod 2^32 every step). Same function on both ends; the hex form names the cache file.
function EC.hashInit() return 5381 end

function EC.hashUpdate(hash, byteString, fromIndex, toIndex)
    local h = hash
    for i = fromIndex or 1, toIndex or #byteString do
        h = (h * 33 + string.byte(byteString, i)) % 4294967296
    end
    return h
end

-- Manual hex: Kahlua's string.format("%x") on a double above 2^31 is not something this mod
-- has verified in-engine, and eight iterations cost nothing.
local HEX = "0123456789abcdef"
function EC.hashHex(hash)
    local out, v = {}, hash
    for i = EC.ICON_HASH_LEN, 1, -1 do
        local d = v % 16
        out[i] = string.sub(HEX, d + 1, d + 1)
        v = (v - d) / 16
    end
    return table.concat(out)
end

function EC.isIconHash(text)
    return type(text) == "string" and #text == EC.ICON_HASH_LEN and string.match(text, "^[0-9a-f]+$") ~= nil
end

return EC
