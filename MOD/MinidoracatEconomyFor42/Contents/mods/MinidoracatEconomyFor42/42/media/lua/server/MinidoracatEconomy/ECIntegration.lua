-- MinidoracatEconomyFor42 - integration API for other mods (server authority, spec section 21).
--
-- Other mods only touch the ledger, never the market: every posting goes through L.post, so the
-- receipt ring, the receipt files, the event stream and the admin panel all see which mod moved
-- the money and why. The facade `MinidoracatEconomy.v1` is assigned at the end of this file (the
-- last server module in the require chain); consumers probe it:
--
--   local E = MinidoracatEconomy and MinidoracatEconomy.v1
--   if E and E.API_MAJOR == 1 and E.API_REVISION >= 1 then
--       local src = E.registerSource({ modId = "MyMod", displayName = { EN = "My Mod" },
--                                      currencies = { "survivor" }, reasonCodes = { "rent" } })
--       local res = src.debit("player", "survivor", 120, { requestId = "...", reasonCode = "rent" })
--   end
--
-- Money model: credit = MOD:<modId> -> player (mint), debit = player -> MOD:<modId> (burn); the
-- MOD account balance is what that mod has issued net. Each source has its own daily mint / burn
-- caps in ModData (config.sources[modId]; mint defaults to 0 = the host must grant it), a per
-- tick call budget, mandatory requestId + reasonCode, and idempotency keyed by
-- mod:<len>:<modId>:<requestId> (a resend returns the first result, consumes no cap).
--
-- Not here on purpose (spec 21.4): no subscription state machine, no player-to-player transfer
-- (CAPABILITIES.transfer = false), no client-originated third-party commands.

if not MinidoracatEconomy or not MinidoracatEconomy.Rewards then
    require "MinidoracatEconomy/ECRewards"
end
local EC = MinidoracatEconomy
local S = EC and EC.Server
local L = EC and EC.Ledger
local X = EC and EC.Export
local Cfg = EC and EC.Config
local R = EC and EC.Rewards
if not S or not S.AUTHORITY or not L or not X or not Cfg or not R then
    return
end

EC.Integration = EC.Integration or {}
local G = EC.Integration

G.API_MAJOR = 1
G.API_REVISION = 1
G.CALLS_PER_TICK = 20
G.MOD_ID_MAX = 64
G.NAME_MAX = 32
G.REASON_CODE_MAX = 32
G.REASON_TEXT_MAX = 64
G.REQUEST_ID_MAX = 96
G.META_KEYS_MAX = 8
G.META_VALUE_MAX = 64
G.REF_ID_MAX = 64
G.CAP_MAX = 1000000000
G.DAILY_KEEP_DAYS = 31

local md = nil
local registry = {}      -- modId -> { modId, displayName, currencies = set, reasonCodes = set, registeredAt }
local tickCalls = {}     -- modId -> calls this tick

-- ---------- validation helpers ----------

local function isInteger(v)
    return type(v) == "number" and v == math.floor(v) and v > -1e15 and v < 1e15
end

local function shortString(v, max)
    return type(v) == "string" and v ~= "" and #v <= max and not string.find(v, "%c")
end

local function validModId(id)
    return type(id) == "string" and #id <= G.MOD_ID_MAX and string.match(id, "^[A-Za-z0-9_%-]+$") ~= nil
end

function G.account(modId)
    return "MOD:" .. modId
end

-- Validated copies of the optional traceability fields (spec 21.3). nil, err on a bad shape.
local function cleanExtras(opts)
    local out = {}
    if opts.reasonText ~= nil then
        if not shortString(opts.reasonText, G.REASON_TEXT_MAX) then return nil, "invalid_args" end
        out.reasonText = opts.reasonText
    end
    if opts.ref ~= nil then
        local ref = opts.ref
        if type(ref) ~= "table" or not shortString(ref.type, G.NAME_MAX) or not shortString(ref.id, G.REF_ID_MAX) then
            return nil, "invalid_args"
        end
        out.ref = { type = ref.type, id = ref.id }
    end
    if opts.meta ~= nil then
        if type(opts.meta) ~= "table" then return nil, "invalid_args" end
        local meta, n = {}, 0
        for k, v in pairs(opts.meta) do
            n = n + 1
            if n > G.META_KEYS_MAX or not shortString(k, G.NAME_MAX) then return nil, "invalid_args" end
            if type(v) == "string" then
                if #v > G.META_VALUE_MAX or string.find(v, "%c") then return nil, "invalid_args" end
            elseif type(v) ~= "number" and type(v) ~= "boolean" then
                return nil, "invalid_args"
            end
            meta[k] = v
        end
        out.meta = meta
    end
    return out
end

-- ---------- ModData: per-source config + daily totals ----------

local function configRow(modId, create)
    local rows = md.config.sources
    local row = rows[modId]
    if not row and create then
        row = { dailyMintCap = 0, enabled = true, registeredAt = EC.now() }
        rows[modId] = row
    end
    return row
end

local function dailyRow(day, modId, create)
    local byDay = md.sourceDaily[day]
    if not byDay then
        if not create then return nil end
        byDay = {}
        md.sourceDaily[day] = byDay
        local oldest = R.dayKey(EC.now() - G.DAILY_KEEP_DAYS * 86400000)
        local stale = {}
        for k in pairs(md.sourceDaily) do
            if k < oldest then stale[#stale + 1] = k end
        end
        for _, k in ipairs(stale) do md.sourceDaily[k] = nil end
    end
    local row = byDay[modId]
    if not row and create then
        row = { mint = 0, burn = 0, calls = 0, ok = 0, rejected = {} }
        byDay[modId] = row
    end
    return row
end

-- Refusals are counted per source per day (panel statistics) and exported as
-- integration.rejected; before ModData is ready there is nowhere to record them.
local function reject(modId, code, req)
    if md then
        if modId then
            local row = dailyRow(R.dayKey(EC.now()), modId, true)
            row.rejected[code] = (row.rejected[code] or 0) + 1
        end
        X.emit("integration.rejected", { sourceMod = modId, error = code, requestId = type(req) == "table" and req.requestId or nil })
    end
    return { ok = false, error = code }
end

-- ---------- registration ----------

-- spec = { modId, displayName = { CH=, EN=, ... }, currencies = { id... }, reasonCodes = { code... } }
-- Returns a handle bound to the source ({ modId, credit, debit, post }) or nil, error.
-- Re-registering the same modId replaces the spec (mods are reloaded with the server).
function G.registerSource(spec)
    if type(spec) ~= "table" or not validModId(spec.modId) then return nil, "invalid_args" end
    if type(spec.currencies) ~= "table" or #spec.currencies == 0 then return nil, "invalid_args" end
    if type(spec.reasonCodes) ~= "table" or #spec.reasonCodes == 0 then return nil, "invalid_args" end
    local currencies = {}
    for _, id in ipairs(spec.currencies) do
        if not EC.CURRENCIES[id] then return nil, "unknown_currency" end
        currencies[id] = true
    end
    local reasonCodes = {}
    for _, code in ipairs(spec.reasonCodes) do
        if type(code) ~= "string" or #code > G.REASON_CODE_MAX or not string.match(code, "^[a-z0-9_]+$") then
            return nil, "invalid_args"
        end
        reasonCodes[code] = true
    end
    local displayName = {}
    if spec.displayName ~= nil then
        if type(spec.displayName) ~= "table" then return nil, "invalid_args" end
        for lang, name in pairs(spec.displayName) do
            if not shortString(lang, 8) or not shortString(name, G.NAME_MAX) then return nil, "invalid_args" end
            displayName[lang] = name
        end
    end
    local modId = spec.modId
    registry[modId] = { modId = modId, displayName = displayName, currencies = currencies, reasonCodes = reasonCodes, registeredAt = EC.now() }
    if md then configRow(modId, true) end
    EC.log("integration source registered: " .. modId)
    local function bind(fn)
        return function(a, b, c, opts)
            local copy = {}
            if type(opts) == "table" then for k, v in pairs(opts) do copy[k] = v end end
            copy.modId = modId
            return fn(a, b, c, copy)
        end
    end
    return {
        modId = modId,
        credit = bind(G.credit),
        debit = bind(G.debit),
        post = function(req)
            local copy = {}
            if type(req) == "table" then for k, v in pairs(req) do copy[k] = v end end
            copy.modId = modId
            return G.post(copy)
        end,
    }
end


-- ---------- posting ----------

-- req = { modId, requestId, reasonCode, reasonText?, ref?, meta?,
--         postings = { { account, currency, amount }, ... } }
-- Accounts are player usernames or the source's own MOD:<modId>; per-currency sums must be 0.
function G.post(req)
    if type(req) ~= "table" then return { ok = false, error = "invalid_args" } end
    if not md then return { ok = false, error = "not_ready" } end
    local modId = req.modId
    local source = validModId(modId) and registry[modId] or nil
    if not source then return reject(nil, "unknown_source", req) end
    local calls = (tickCalls[modId] or 0) + 1
    tickCalls[modId] = calls
    if calls > G.CALLS_PER_TICK then return reject(modId, "rate_limited", req) end

    local cfg = configRow(modId, true)
    if cfg.enabled == false then return reject(modId, "source_disabled", req) end
    if not shortString(req.requestId, G.REQUEST_ID_MAX) then return reject(modId, "invalid_args", req) end
    if type(req.reasonCode) ~= "string" or not source.reasonCodes[req.reasonCode] then
        return reject(modId, "invalid_args", req)
    end
    local extras, extrasErr = cleanExtras(req)
    if not extras then return reject(modId, extrasErr, req) end
    if type(req.postings) ~= "table" or #req.postings == 0 or #req.postings > 8 then
        return reject(modId, "invalid_args", req)
    end

    local own = G.account(modId)
    local postings, modDelta, fingerprint = {}, {}, {}
    for _, p in ipairs(req.postings) do
        if type(p) ~= "table" or type(p.account) ~= "string" or not isInteger(p.amount) or p.amount == 0 then
            return reject(modId, "invalid_args", req)
        end
        if not EC.CURRENCIES[p.currency] then return reject(modId, "invalid_args", req) end
        if not source.currencies[p.currency] then return reject(modId, "currency_not_allowed", req) end
        if p.account ~= own and L.isSystemAccount(p.account) then return reject(modId, "invalid_args", req) end
        postings[#postings + 1] = { account = p.account, currency = p.currency, amount = p.amount }
        if p.account == own then modDelta[p.currency] = (modDelta[p.currency] or 0) + p.amount end
        fingerprint[#fingerprint + 1] = p.account .. "|" .. p.currency .. "|" .. tostring(p.amount)
    end
    EC.sortSafe(fingerprint, function(a, b) return a < b end)
    local fp = table.concat(fingerprint, ";")

    local key = "mod:" .. #modId .. ":" .. modId .. ":" .. req.requestId
    local prior = L.priorResult(key)
    if prior then
        if not prior.meta or prior.meta.fp ~= fp then return reject(modId, "request_conflict", req) end
        return { ok = prior.ok, txId = prior.txId, seq = prior.seq, error = prior.error, duplicate = true }
    end

    -- Daily caps per source, totals across currencies (spec 21.2). A refused call leaves no row.
    local mint, burn = 0, 0
    for _, delta in pairs(modDelta) do
        if delta < 0 then mint = mint - delta else burn = burn + delta end
    end
    local day = R.dayKey(EC.now())
    local today = dailyRow(day, modId, false)
    local usedMint, usedBurn = today and today.mint or 0, today and today.burn or 0
    if mint > 0 and usedMint + mint > (cfg.dailyMintCap or 0) then return reject(modId, "cap_exceeded", req) end
    if burn > 0 and type(cfg.dailyBurnCap) == "number" and usedBurn + burn > cfg.dailyBurnCap then
        return reject(modId, "cap_exceeded", req)
    end

    local res = L.post({
        kind = "mod", requestId = key, reasonCode = req.reasonCode, reasonText = extras.reasonText,
        actor = modId, idemMeta = { fp = fp },
        payload = { sourceMod = modId, reasonCode = req.reasonCode, reasonText = extras.reasonText, ref = extras.ref, meta = extras.meta },
        postings = postings,
    })
    if not res.ok then return reject(modId, res.error, req) end
    local row = dailyRow(day, modId, true)
    row.mint, row.burn, row.calls, row.ok = row.mint + mint, row.burn + burn, row.calls + 1, row.ok + 1
    return { ok = true, txId = res.txId, seq = res.seq, duplicate = false }
end

local function sugar(username, currency, amount, opts, sign)
    if type(opts) ~= "table" then return { ok = false, error = "invalid_args" } end
    local modId = validModId(opts.modId) and registry[opts.modId] and opts.modId or nil
    if type(username) ~= "string" or username == "" or L.isSystemAccount(username) or not isInteger(amount) or amount <= 0 then
        return reject(modId, modId and "invalid_args" or "unknown_source", opts)
    end
    return G.post({
        modId = opts.modId, requestId = opts.requestId, reasonCode = opts.reasonCode,
        reasonText = opts.reasonText, ref = opts.ref, meta = opts.meta,
        postings = {
            { account = username, currency = currency, amount = sign * amount },
            { account = modId and G.account(modId) or "", currency = currency, amount = -sign * amount },
        },
    })
end

-- credit: MOD:<modId> -> player (mint). opts = { modId, requestId, reasonCode, reasonText?, ref?, meta? }
function G.credit(username, currency, amount, opts)
    return sugar(username, currency, amount, opts, 1)
end

-- debit: player -> MOD:<modId> (burn)
function G.debit(username, currency, amount, opts)
    return sugar(username, currency, amount, opts, -1)
end

-- Read-only; never creates a wallet. nil for an unknown currency.
function G.getBalance(username, currency)
    if not md or type(username) ~= "string" or not EC.CURRENCIES[currency] then return nil end
    return L.getBalance(username, currency)
end

function G.currencies()
    if not md then return {} end
    return Cfg.snapshot()
end

-- ---------- admin view / settings ----------

-- Every source the ModData knows about (registered now or in an earlier session), with today's use.
function G.sources()
    if not md then return {} end
    local day = R.dayKey(EC.now())
    local out = {}
    for modId, cfg in pairs(md.config.sources) do
        local live = registry[modId]
        local today = dailyRow(day, modId, false)
        out[#out + 1] = {
            modId = modId,
            displayName = live and live.displayName or nil,
            loaded = live ~= nil,
            enabled = cfg.enabled ~= false,
            dailyMintCap = cfg.dailyMintCap or 0,
            dailyBurnCap = cfg.dailyBurnCap,
            registeredAt = cfg.registeredAt,
            balance = {},
            today = {
                mint = today and today.mint or 0, burn = today and today.burn or 0,
                calls = today and today.calls or 0, ok = today and today.ok or 0,
                rejected = today and today.rejected or {},
            },
        }
        for _, id in ipairs(EC.CURRENCY_ORDER) do
            out[#out].balance[id] = L.getBalance(G.account(modId), id).available
        end
    end
    EC.sortSafe(out, function(a, b) return a.modId < b.modId end)
    return out
end

-- values = { dailyMintCap?, dailyBurnCap? (false = unlimited), enabled? }; each change is audited.
function G.setSource(modId, values, actor, reason)
    if not md or not validModId(modId) or type(values) ~= "table" then return false, "invalid_args" end
    local cfg = configRow(modId, false)
    if not cfg then return false, "unknown_source" end
    local changes = {}
    if values.dailyMintCap ~= nil then
        local v = values.dailyMintCap
        if not isInteger(v) or v < 0 or v > G.CAP_MAX then return false, "invalid_args" end
        changes[#changes + 1] = { "dailyMintCap", cfg.dailyMintCap or 0, v }
    end
    if values.dailyBurnCap ~= nil then
        local v = values.dailyBurnCap
        if v == false then
            v = nil
        elseif not isInteger(v) or v < 0 or v > G.CAP_MAX then
            return false, "invalid_args"
        end
        changes[#changes + 1] = { "dailyBurnCap", cfg.dailyBurnCap, v, true }
    end
    if values.enabled ~= nil then
        if type(values.enabled) ~= "boolean" then return false, "invalid_args" end
        changes[#changes + 1] = { "enabled", cfg.enabled ~= false, values.enabled }
    end
    for _, c in ipairs(changes) do
        local field, before, after = c[1], c[2], c[3]
        if before ~= after then
            cfg[field] = after
            X.emit("admin.source", { sourceMod = modId, field = field, before = before, after = after, actor = actor, reason = reason })
            X.audit({ action = "source", target = modId, field = field, before = before, after = after, admin = actor, reason = reason })
        end
    end
    return true
end

function G.onTick()
    tickCalls = {}
end

function G.init(root)
    md = root
    md.config.sources = md.config.sources or {}
    md.sourceDaily = md.sourceDaily or {}
    for modId in pairs(registry) do configRow(modId, true) end
    tickCalls = {}
end

S.Integration = G
S.onInit(G.init)
Events.OnTickEvenPaused.Add(G.onTick)

-- The public facade (spec 21.1). Server only: the client half lives in ECClient.lua.
EC.v1 = {
    API_MAJOR = G.API_MAJOR,
    API_REVISION = G.API_REVISION,
    CAPABILITIES = { post = true, transfer = false, subscribe = false },
    registerSource = G.registerSource,
    post = G.post,
    credit = G.credit,
    debit = G.debit,
    getBalance = G.getBalance,
    currencies = G.currencies,
}

return G
