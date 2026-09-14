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
C.RATE_RING = 8    -- superseded exchange rates still honoured for orders already in flight (persistence spec 5.4)

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

-- What the companion projects into GET /currencies: one slim record per currency (no icon
-- bytes), the exchange block with its version. Emitted at start and after every change.
function C.exchangeSnapshot()
    local out = {}
    for _, id in ipairs(EC.CURRENCY_ORDER) do
        local e = md.config.currencies[id] or {}
        local ex = nil
        if type(e.exchange) == "table" then
            ex = {}
            for k, v in pairs(e.exchange) do if k ~= "ring" then ex[k] = v end end
        end
        out[#out + 1] = {
            id = id, enabled = e.enabled ~= false, nameOverride = e.nameOverride, marketUnit = EC.CURRENCIES[id].marketUnit,
            balanceMax = type(e.balanceMax) == "number" and e.balanceMax or EC.sandbox("BalanceMax", C.DEFAULT_BALANCE_MAX),
            exchange = ex,
        }
    end
    return out
end

function C.emitExchangeConfig()
    X.emit("exchange.config", { currencies = C.exchangeSnapshot() })
end

-- Every runtime change: event + audit line + config push to everyone online.
local function changed(id, field, before, after, actor, reason)
    C.emitExchangeConfig()   -- the projection first, then the change record and its audit line
    X.emit("admin.config", { currency = id, field = field, before = before, after = after, actor = actor, reason = reason })
    X.audit({ action = "config", currency = id, field = field, before = before, after = after, admin = actor, reason = reason })
    -- `radio` rides along so a frequency, range or relay change reaches every client's channel
    -- registration and station text at once, without waiting for a reconnect (hello.ack).
    S.broadcast("config", { currencies = C.snapshot(), options = C.options(), remoteReadOnly = EC.sandbox("RemoteReadOnly", true),
        radio = S.Radio and S.Radio.clientInfo() or nil })
end

-- Runtime option overrides (settings page): config.options[key] wins over the sandbox file for
-- every EC.sandbox() read on the server. The Cat* exchange keys are routed to the currency's
-- exchange block instead. A `manageOnly` option (admin roles, admin caps) is stored here like
-- any other; what guards it is the native role capability checked in ECAdmin's admin.option
-- handler, not this layer.
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

-- Settings page snapshot: key -> { value (effective), default (sandbox file / code), override,
-- locked, manageOnly }.
function C.options()
    local out = {}
    for _, spec in ipairs(EC.OPTIONS) do
        local ex = EXCHANGE_BY_KEY[spec.key]
        local default = EC.sandboxDefault(spec.key, spec.default)
        local value = C.optionValue(spec)
        -- role lists are arrays: hand out a copy, so no reply carries a live ModData table
        if spec.kind == "roles" and type(value) == "table" then
            local names = {}
            for i = 1, #value do names[i] = value[i] end
            value = names
        end
        local override
        if ex then
            override = value ~= default
        else
            override = md.config.options[spec.key] ~= nil
        end
        out[spec.key] = { value = value, default = default, override = override,
            locked = spec.locked == true, manageOnly = spec.manageOnly == true }
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
    elseif kind == "roles" then
        -- A dense array of exact native role names, checked against this server's own role list.
        -- Everything doubtful is refused outright rather than repaired: a name silently dropped
        -- from AdminRoles is a lockout, and one silently kept is a privilege grant. An empty
        -- array is a valid answer and means "nobody", which is why it is not treated as absent.
        if type(value) ~= "table" then return nil, "invalid_roles" end
        local n = #value
        -- holes and non-numeric keys: a sparse list would authorise a set nobody chose
        if EC.countKeys(value) ~= n then return nil, "invalid_roles" end
        if n > 255 then return nil, "invalid_roles" end       -- Roles.addRole caps the server at 255
        local out = {}
        if n == 0 then return out end
        local known = EC.roleChoices()
        if known == nil then return nil, "roles_unavailable" end
        local exists = {}
        for _, r in ipairs(known) do exists[r.name] = true end
        local seen = {}
        for i = 1, n do
            local name = value[i]
            if type(name) ~= "string" or name == "" or #name > 200 or string.find(name, "%c") then
                return nil, "invalid_roles"
            end
            if seen[name] then return nil, "invalid_roles" end
            -- exact name: a role that differs only in case is a different role, not a match
            if not exists[name] then return nil, "unknown_role" end
            seen[name] = true
            out[i] = name
        end
        return out
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
    if spec.group == "seasons" and (not S.Seasons or type(S.Seasons.applyDuration) ~= "function") then
        return false, "not_ready"
    end
    if before == normalised then
        if spec.group == "seasons" then return S.Seasons.applyDuration() end
        return true
    end
    md.config.options[key] = normalised
    local warning = nil
    -- The running season follows SeasonDays live (ECSeasons.applyDuration recomputes its
    -- deadline from its own start and hands every online client the new state). It is asked
    -- after the override is stored, so what it publishes is the length this page just wrote;
    -- a refusal (a deadline already in the past, unreadable season data) puts the stored
    -- override back exactly as it was, so nothing is announced and nothing is half applied.
    if spec.group == "seasons" then
        local seasonOk, seasonErr, pubWarning = S.Seasons.applyDuration()
        if not seasonOk then
            md.config.options[key] = before
            return false, seasonErr
        end
        warning = pubWarning
    end
    if spec.group == "seasons" then
        local published, err = pcall(changed, "options", key, before, normalised, actor, reason)
        if not published then
            warning = "publication_failed"
            EC.log("season setting applied; config publication failed: " .. tostring(err))
        end
    else
        changed("options", key, before, normalised, actor, reason)
    end
    -- These modules load later; publish the changed effective state, not just the options table.
    if spec.group == "rewards" and S.Rewards then S.Rewards.pushAll() end
    if spec.group == "shop" and S.Shop then S.Shop.pushAll() end
    -- A radio setting change must reach the devices already standing in the world: the relay
    -- rebuilds them on the new frequency / range, or takes them away when it was switched off.
    -- The option stays committed either way - it is what this page wrote and what every later
    -- read returns - but the reply carries the warning instead of implying the world followed.
    -- A missing relay module is not a success either: nothing reached the devices then.
    if spec.group == "radio" then
        local relay = S.TradeRadio
        local called, synced, syncErr = true, false, "the radio relay is not loaded"
        if relay then called, synced, syncErr = pcall(relay.onConfigChanged) end
        if not called or synced ~= true then
            warning = "radio_unavailable"
            EC.log("trade radio: setting applied; device sync failed: "
                .. tostring(called and syncErr or synced))
        end
    end
    -- The public board's two rules ride along in the `config` broadcast above (options table);
    -- the board itself is never pushed -- a server-wide ranking must stay a pull per request.
    return true, nil, warning
end

-- Buyback daily caps of one currency, in that currency. The numbers are plain options
-- (EC.BUYBACK_OPTIONS), so the currency page edits them through admin.option like any other
-- setting and the shop reads exactly what the page shows. A cap of 0 stops buyback for this
-- currency; it is never "unlimited". Unknown currency -> nil (no cap table invented).
function C.buybackCaps(id)
    local keys = EC.BUYBACK_OPTIONS[id]
    if not keys then return nil end
    local account = EC.OPTION_BY_KEY[keys.account]
    local server = EC.OPTION_BY_KEY[keys.server]
    return {
        account = account and C.optionValue(account) or 0,
        server = server and C.optionValue(server) or 0,
    }
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
        buybackCaps = C.buybackCaps(id),
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
    -- the rate this version paid stays accepted for orders the companion already took in
    local ring = e.exchange.ring or {}
    ring[#ring + 1] = { rateVersion = e.exchange.rateVersion or 1, pointsPerCoin = e.exchange.pointsPerCoin }
    while #ring > C.RATE_RING do table.remove(ring, 1) end
    e.exchange.ring = ring
    for field in pairs(EXCHANGE_DEFAULTS) do e.exchange[field] = next_[field] end
    e.exchange.rateVersion = (e.exchange.rateVersion or 1) + 1
    local after = {}
    for k, v in pairs(e.exchange) do if k ~= "ring" then after[k] = v end end
    changed(id, "exchange", before, after, actor, reason)
    return true
end

-- An order pinned to (rateVersion, rateSnapshot) is honoured when that pair is the current rate
-- or one of the last C.RATE_RING superseded ones (no clock, no grace window).
function C.rateAccepted(id, rateVersion, rateSnapshot)
    local e = md.config.currencies[id]
    local ex = e and e.exchange
    if type(ex) ~= "table" then return false end
    if rateVersion == (ex.rateVersion or 1) then return rateSnapshot == ex.pointsPerCoin end
    for _, r in ipairs(ex.ring or {}) do
        if r.rateVersion == rateVersion then return r.pointsPerCoin == rateSnapshot end
    end
    return false
end


S.Config = C
S.onInit(C.init)
return C
