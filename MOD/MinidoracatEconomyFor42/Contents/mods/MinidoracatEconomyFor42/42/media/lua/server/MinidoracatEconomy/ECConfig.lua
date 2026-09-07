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

-- Every runtime change: event + audit line + config push to everyone online.
local function changed(id, field, before, after, actor, reason)
    X.emit("admin.config", { currency = id, field = field, before = before, after = after, actor = actor, reason = reason })
    X.audit({ action = "config", currency = id, field = field, before = before, after = after, admin = actor, reason = reason })
    S.broadcast("config", { currencies = C.snapshot(), options = C.options(), remoteReadOnly = EC.sandbox("RemoteReadOnly", true) })
end

-- Runtime option overrides (settings page): config.options[key] wins over the sandbox file for
-- every EC.sandbox() read on the server. Locked options (admin caps, role lists) are never
-- stored here; the Cat* exchange keys are routed to the currency's exchange block instead.
local function optionOverride(key)
    local opts = md and md.config and md.config.options
    if not opts then return nil end
    return opts[key]   -- not `and/or`: a stored false must come back as false
end

function C.init(root)
    md = root
    md.config = md.config or {}
    md.config.currencies = md.config.currencies or {}
    md.config.options = md.config.options or {}
    EC.optionOverride = optionOverride
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

-- Sandbox key -> { currency, field } for the exchange values that live in config.currencies.
local EXCHANGE_BY_KEY = {}
for id, keys in pairs(EXCHANGE_SANDBOX) do
    for field, key in pairs(keys) do EXCHANGE_BY_KEY[key] = { currency = id, field = field } end
end

-- Effective value of an option as the server runs with it right now.
function C.optionValue(spec)
    local ex = EXCHANGE_BY_KEY[spec.key]
    if ex then
        local e = md.config.currencies[ex.currency]
        local v = e and type(e.exchange) == "table" and e.exchange[ex.field] or nil
        if v ~= nil then return v end
    end
    return EC.sandbox(spec.key, spec.default)
end

-- Settings page snapshot: key -> { value (effective), default (sandbox file / code), override }.
function C.options()
    local out = {}
    for _, spec in ipairs(EC.OPTIONS) do
        local ex = EXCHANGE_BY_KEY[spec.key]
        local default = EC.sandboxDefault(spec.key, spec.default)
        local value = C.optionValue(spec)
        local override
        if ex then
            override = value ~= default
        else
            override = md.config.options[spec.key] ~= nil
        end
        out[spec.key] = { value = value, default = default, override = override, locked = spec.locked == true }
    end
    return out
end

-- Validates `value` against the option schema; returns the normalised value or nil, error.
local function validateOption(spec, value)
    local kind = spec.kind
    if kind == "bool" then
        if type(value) ~= "boolean" then return nil, "invalid_args" end
        return value
    elseif kind == "int" or kind == "number" then
        if type(value) ~= "number" or value ~= value or value < spec.min or value > spec.max then return nil, "invalid_args" end
        if kind == "int" and value ~= math.floor(value) then return nil, "invalid_args" end
        if kind == "number" and spec.step and math.abs(value / spec.step - math.floor(value / spec.step + 0.5)) > 1e-9 then return nil, "invalid_args" end
        return value
    elseif kind == "list_int" then
        local list = EC.parseIntList(value, spec)
        if not list then return nil, "invalid_args" end
        local parts = {}
        for i, n in ipairs(list) do parts[i] = tostring(n) end
        return table.concat(parts, ";")
    elseif kind == "text" then
        if type(value) ~= "string" or value == "" or #value > 200 or string.find(value, "%c") then return nil, "invalid_args" end
        return value
    end
    return nil, "invalid_args"
end

-- value = nil clears the override (back to the sandbox file). Audited like every config change;
-- reason is optional here (a toggle per click must not demand an essay).
function C.setOption(key, value, actor, reason)
    local spec = EC.OPTION_BY_KEY[key]
    if not spec then return false, "unknown_option" end
    if spec.locked then return false, "locked" end
    local ex = EXCHANGE_BY_KEY[key]
    if ex then
        local v = value
        if v == nil then v = EC.sandboxDefault(key, spec.default) end
        local ok, err = validateOption(spec, v)
        if ok == nil then return false, err end
        return C.setExchange(ex.currency, { [ex.field] = ok }, actor, reason)
    end
    local normalised = nil
    if value ~= nil then
        local ok, err = validateOption(spec, value)
        if ok == nil then return false, err end
        normalised = ok
    end
    local before = md.config.options[key]
    if before == normalised then return true end
    md.config.options[key] = normalised
    changed("options", key, before, normalised, actor, reason)
    -- ECRewards loads after this module: resolve it at call time
    if spec.group == "rewards" and S.Rewards then S.Rewards.pushAll() end
    return true
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
        iconBytes = e.iconBytes,
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

-- hash: 8 hex chars (EC.hashHex) + bytes, or nil/nil to fall back to the shipped icon. The
-- byte count travels with the hash so clients can validate a cached file before asking for it.
function C.setIconHash(id, hash, bytes, actor, reason)
    if not EC.CURRENCIES[id] then return false, "unknown_currency" end
    if hash ~= nil and not (EC.isIconHash(hash) and type(bytes) == "number" and bytes > 0 and bytes <= EC.ICON_MAX_BYTES) then
        return false, "invalid_args"
    end
    local e = entry(id)
    local before = e.iconHash
    if before == hash and e.iconBytes == bytes then return true end
    e.iconHash = hash
    e.iconBytes = hash and bytes or nil
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
