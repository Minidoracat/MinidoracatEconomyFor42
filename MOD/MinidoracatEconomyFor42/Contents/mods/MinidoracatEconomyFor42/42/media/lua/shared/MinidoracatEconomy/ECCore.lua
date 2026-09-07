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
EC.VERSION = "0.1.0"

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
        marketUnit = false, directTransfer = false,
    },
}
EC.CURRENCY_ORDER = { "survivor", "cat" }

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

-- Stable insertion sort (family rule: no table.sort under Kahlua, see verify_mod check 6).
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
        if v ~= nil and type(v) == type(default) then return v end
    end
    return EC.sandboxDefault(key, default)
end

-- "admin;moderator" -> { admin = true, moderator = true } (sandbox strings cannot contain commas:
-- ScriptParser splits on them, pitfalls.md "Sandbox 選項").
function EC.roleSet(str)
    local set = {}
    for name in string.gmatch(tostring(str or ""), "[^;%s]+") do
        set[string.lower(name)] = true
    end
    return set
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
                local code = tonumber(hex, 16)
                if not code or #hex ~= 4 then return nil, i end
                out[#out + 1] = string.char(code < 256 and code or 63)   -- non-Latin-1 escapes become '?'
                i = i + 4
            else
                out[#out + 1] = e
            end
            i = i + 2
        else
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

-- Sandbox options of this mod: one schema shared by the server (validation of runtime overrides,
-- `admin.option`) and the admin panel's settings page (controls, grouping, formatting).
--   kind     bool | int | number | list_int | text
--   min/max/step  numeric bounds (ints) / step of the +- buttons
--   unit     coin | minutes | hour | tz | roles | days   (presentation only)
--   locked   true = server file only: the caps that limit admins and the role lists must not be
--            raised from inside the panel by the very people they limit (spec 19.3 decision 11)
--   currency values live in config.currencies (ECConfig) and are edited through the currency page
EC.OPTIONS = {
    { key = "CheckinAmount", group = "rewards", kind = "int", min = 0, max = 1000000, step = 10, default = 30, unit = "coin" },
    { key = "CheckinMinPlaytimeMinutes", group = "rewards", kind = "int", min = 0, max = 1440, step = 5, default = 15, unit = "minutes" },
    { key = "CheckinServerDailyCap", group = "rewards", kind = "int", min = 0, max = 100000000, step = 1000, default = 0, unit = "coin", zeroUnlimited = true },
    { key = "RewardDayResetHour", group = "rewards", kind = "int", min = 0, max = 23, step = 1, default = 0, unit = "hour" },
    { key = "RewardTimezoneUTC", group = "rewards", kind = "number", min = -12, max = 14, step = 0.5, default = 8, unit = "tz" },
    { key = "MilestoneDays", group = "rewards", kind = "list_int", min = 1, max = 3650, maxItems = 16, default = "1;3;7;14;30", unit = "days" },
    { key = "MilestoneAmounts", group = "rewards", kind = "list_int", min = 0, max = 1000000, maxItems = 16, default = "100;150;250;400;1000", unit = "coin" },
    { key = "AdminRoles", group = "admin", kind = "text", default = "admin", unit = "roles", locked = true },
    { key = "ReadOnlyRoles", group = "admin", kind = "text", default = "moderator", unit = "roles", locked = true },
    { key = "AdminAdjustMaxPerTx", group = "admin", kind = "int", min = 1, max = 100000000, default = 5000, unit = "coin", locked = true },
    { key = "AdminAdjustDailyPerAdmin", group = "admin", kind = "int", min = 1, max = 100000000, default = 10000, unit = "coin", locked = true },
    { key = "AdminAdjustServerDaily", group = "admin", kind = "int", min = 1, max = 100000000, default = 50000, unit = "coin", locked = true },
    { key = "BalanceMax", group = "currency", kind = "int", min = 1000, max = 1000000000, step = 100000, default = 10000000, unit = "coin", page = "Currencies" },
    { key = "CatRatePointsPerCoin", group = "currency", kind = "int", min = 1, max = 1000000, default = 1, page = "Currencies" },
    { key = "CatPerOrderMin", group = "currency", kind = "int", min = 1, max = 1000000, default = 10, page = "Currencies" },
    { key = "CatPerOrderMax", group = "currency", kind = "int", min = 1, max = 1000000, default = 5000, page = "Currencies" },
    { key = "CatPerAccountDaily", group = "currency", kind = "int", min = 1, max = 100000000, default = 5000, page = "Currencies" },
    { key = "CatServerDaily", group = "currency", kind = "int", min = 1, max = 100000000, default = 50000, page = "Currencies" },
    { key = "RemoteReadOnly", group = "general", kind = "bool", default = true },
}
EC.OPTION_GROUPS = { "rewards", "admin", "currency", "general" }
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
