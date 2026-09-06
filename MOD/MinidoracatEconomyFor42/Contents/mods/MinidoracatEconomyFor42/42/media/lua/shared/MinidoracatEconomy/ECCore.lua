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

function EC.countKeys(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

return EC
