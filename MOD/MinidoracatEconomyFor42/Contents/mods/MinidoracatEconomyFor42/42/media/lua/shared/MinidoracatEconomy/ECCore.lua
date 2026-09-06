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

-- Sandbox read with type guard: a missing page (mod loaded without sandbox-options) or a
-- value of the wrong type silently falls back to the code default, logged once per key.
local sandboxWarned = {}
function EC.sandbox(key, default)
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

-- File-system safe, collision-free name for a username: [A-Za-z0-9_-] kept, everything else
-- becomes _xHHHH_ (UTF-16 code unit). Usernames may be non-ASCII on the production server.
function EC.safeName(name)
    return (string.gsub(tostring(name), "[^A-Za-z0-9_%-]", function(ch)
        return string.format("_x%04x_", string.byte(ch))
    end))
end

function EC.countKeys(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

return EC
