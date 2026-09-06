-- MinidoracatEconomyFor42 — currency registry runtime half (server authority, spec section 18).
--
-- Static half: EC.CURRENCIES (ECCore). Runtime half lives in Global ModData
-- `config.currencies[id] = { nameOverride, enabled, iconHash, balanceMax, exchange = {...} }`.
-- Exchange numbers (Discord points -> coins) are owned in-game: sandbox gives the boot default,
-- admins override at runtime, every change bumps `rateVersion` and emits `admin.config` so the
-- companion can project `GET /currencies` for Watchcord (persistence spec 5.4).

if not MinidoracatEconomy or not MinidoracatEconomy.Export then
    require "MinidoracatEconomy/ECExport"
end
local EC = MinidoracatEconomy
local S = EC and EC.Server
local L = EC and EC.Ledger
local X = EC and EC.Export
if not S or not S.AUTHORITY or not L or not X then
    return
end

EC.Config = EC.Config or {}
local C = EC.Config

C.NAME_MAX = 24
C.DEFAULT_BALANCE_MAX = 10000000

local md = nil

-- Sandbox keys per currency: Economy_<Id>_... is not possible (sandbox names are fixed at load),
-- so the keys are spelled out per external currency here.
local EXCHANGE_SANDBOX = {
    cat = { pointsPerCoin = "CatRatePointsPerCoin", perOrderMin = "CatPerOrderMin", perOrderMax = "CatPerOrderMax",
            perAccountDaily = "CatPerAccountDaily", serverDaily = "CatServerDaily" },
}
local EXCHANGE_DEFAULTS = { pointsPerCoin = 1, perOrderMin = 10, perOrderMax = 5000, perAccountDaily = 5000, serverDaily = 50000 }

local function entry(id)
    local e = md.config.currencies[id]
    if not e then
        e = {}
        md.config.currencies[id] = e
    end
    return e
end

function C.init(root)
    md = root
    md.config = md.config or {}
    md.config.currencies = md.config.currencies or {}
    for _, id in ipairs(EC.CURRENCY_ORDER) do
        local e = entry(id)
        if EXCHANGE_SANDBOX[id] and type(e.exchange) ~= "table" then
            -- First boot for this currency: seed the runtime exchange block from sandbox.
            local keys = EXCHANGE_SANDBOX[id]
            e.exchange = { rateVersion = 1 }
            for field, key in pairs(keys) do
                e.exchange[field] = EC.sandbox(key, EXCHANGE_DEFAULTS[field])
            end
        end
    end
end

-- Merged view used by the ledger, the client snapshot and the companion projection.
function C.currency(id)
    local static = EC.CURRENCIES[id]
    if not static then return nil end
    local e = md.config.currencies[id] or {}
    return {
        id = id,
        sortOrder = static.sortOrder,
        nameKey = static.nameKey,
        nameOverride = e.nameOverride,
        iconDefault = static.iconDefault,
        iconHash = e.iconHash,
        marketUnit = static.marketUnit,
        directTransfer = static.directTransfer,
        enabled = e.enabled ~= false,
        balanceMax = type(e.balanceMax) == "number" and e.balanceMax or EC.sandbox("BalanceMax", C.DEFAULT_BALANCE_MAX),
        balanceMaxOverride = type(e.balanceMax) == "number" and e.balanceMax or nil,
        exchange = e.exchange,
    }
end

function C.snapshot()
    local list = {}
    for _, id in ipairs(EC.CURRENCY_ORDER) do
        list[#list + 1] = C.currency(id)
    end
    return list
end

local function changed(id, field, before, after, actor, reason)
    X.emit("admin.config", { currency = id, field = field, before = before, after = after, actor = actor, reason = reason })
    X.audit({ action = "config", currency = id, field = field, before = before, after = after, admin = actor, reason = reason })
    S.broadcast("config", { currencies = C.snapshot() })
end

-- name: string (1..NAME_MAX, no control chars) or nil/"" to clear the override.
function C.setNameOverride(id, name, actor, reason)
    if not EC.CURRENCIES[id] then return false, "unknown_currency" end
    if name == "" then name = nil end
    if name ~= nil then
        if type(name) ~= "string" or #name > C.NAME_MAX or string.find(name, "%c") then return false, "invalid_args" end
    end
    local e = entry(id)
    local before = e.nameOverride
    if before == name then return true end
    e.nameOverride = name
    changed(id, "nameOverride", before, name, actor, reason)
    return true
end

function C.setEnabled(id, enabled, actor, reason)
    if not EC.CURRENCIES[id] then return false, "unknown_currency" end
    if type(enabled) ~= "boolean" then return false, "invalid_args" end
    local e = entry(id)
    local before = e.enabled ~= false
    if before == enabled then return true end
    e.enabled = enabled
    changed(id, "enabled", before, enabled, actor, reason)
    return true
end

function C.setIconHash(id, hash, actor, reason)
    if not EC.CURRENCIES[id] then return false, "unknown_currency" end
    if hash ~= nil and (type(hash) ~= "string" or #hash > 16) then return false, "invalid_args" end
    local e = entry(id)
    local before = e.iconHash
    if before == hash then return true end
    e.iconHash = hash
    changed(id, "iconHash", before, hash, actor, reason)
    return true
end

-- value: positive integer (BALANCE_MAX_MIN..L.MAX_ABS_AMOUNT) or nil to fall back to the sandbox
-- default. Lowering the cap never touches existing balances: the fuse only refuses new credits.
C.BALANCE_MAX_MIN = 1000
function C.setBalanceMax(id, value, actor, reason)
    if not EC.CURRENCIES[id] then return false, "unknown_currency" end
    if value ~= nil then
        if type(value) ~= "number" or value ~= math.floor(value) or value < C.BALANCE_MAX_MIN or value > L.MAX_ABS_AMOUNT then
            return false, "invalid_args"
        end
    end
    local e = entry(id)
    local before = e.balanceMax
    if before == value then return true end
    e.balanceMax = value
    changed(id, "balanceMax", before, value, actor, reason)
    return true
end

-- values: table with any of pointsPerCoin / perOrderMin / perOrderMax / perAccountDaily / serverDaily
-- (positive integers; perOrderMin <= perOrderMax). Bumps rateVersion when anything changes.
function C.setExchange(id, values, actor, reason)
    if not EC.CURRENCIES[id] then return false, "unknown_currency" end
    local e = entry(id)
    if type(e.exchange) ~= "table" then return false, "not_exchangeable" end
    if type(values) ~= "table" then return false, "invalid_args" end
    local next_ = {}
    for field in pairs(EXCHANGE_DEFAULTS) do
        local v = values[field]
        if v == nil then v = e.exchange[field] end
        if type(v) ~= "number" or v ~= math.floor(v) or v <= 0 or v > L.MAX_ABS_AMOUNT then return false, "invalid_args" end
        next_[field] = v
    end
    if next_.perOrderMin > next_.perOrderMax then return false, "invalid_args" end
    local diff = false
    for field in pairs(EXCHANGE_DEFAULTS) do
        if next_[field] ~= e.exchange[field] then diff = true end
    end
    if not diff then return true end
    local before = {}
    for field in pairs(EXCHANGE_DEFAULTS) do before[field] = e.exchange[field] end
    before.rateVersion = e.exchange.rateVersion
    for field in pairs(EXCHANGE_DEFAULTS) do e.exchange[field] = next_[field] end
    e.exchange.rateVersion = (e.exchange.rateVersion or 1) + 1
    local after = {}
    for k, v in pairs(e.exchange) do after[k] = v end
    changed(id, "exchange", before, after, actor, reason)
    return true
end

-- Display name resolution happens on the client (override -> translation -> id); the server
-- only needs it for logs.
function C.displayName(id)
    local cur = C.currency(id)
    if not cur then return tostring(id) end
    return cur.nameOverride or getText(cur.nameKey)
end

S.Config = C
S.onInit(C.init)
return C
