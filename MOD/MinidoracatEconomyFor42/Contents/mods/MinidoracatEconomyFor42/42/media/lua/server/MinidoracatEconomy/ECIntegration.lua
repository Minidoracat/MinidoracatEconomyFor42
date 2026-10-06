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
-- Rev 2 (ECEntitlements, which raises API_REVISION and adds CAPABILITIES.entitlements /
-- subscriptions once it has loaded): the handle also carries registerProduct, getEntitlement,
-- quote, purchase, setAutoRenew, getOrder, refund and onEntitlementChanged, all bound to the
-- source. Entitlement money uses the same post below with a private `internal` argument the facade
-- can never pass: its own "ent:" idempotency namespace, a copy-on-write commit descriptor that
-- L.post publishes together with the money, and the bounded reversal of one paid order.
-- Rev 3 (ECTransfer, which raises API_REVISION and sets CAPABILITIES.transfer once it has
-- loaded): src.transfer(from, to, currency, amount, opts) / E.transfer(..., opts with modId)
-- moves money player -> player through the same rules as a player transfer (minus the terminal
-- and the memo), only for a source the host marked allowTransfer. Still not here: no
-- client-originated third-party commands.
-- Rev 4 (ECEntitlements, CAPABILITIES.freeze): registerProduct{ freezeWhenAbsent = true } - a product
-- missing at start has its rentals frozen until it registers again.

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
G.NAME_KEY_MAX = 96
G.REASON_CODE_MAX = 32
G.REASON_TEXT_MAX = 64
G.REQUEST_ID_MAX = 96
G.META_KEYS_MAX = 8
G.META_VALUE_MAX = 64
G.REF_ID_MAX = 64
G.CAP_MAX = 1000000000
G.DAILY_KEEP_DAYS = 31

local md = nil
local registry = {}      -- modId -> { modId, displayName, nameKey?, currencies = set, reasonCodes = set, registeredAt }
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
        row = { mint = 0, burn = 0, refund = 0, calls = 0, ok = 0, rejected = {} }
        byDay[modId] = row
    end
    return row
end

-- Entitlement methods every handle carries (rev 2; setPlan / getPlan / setPlanSource with
-- CAPABILITIES.setPlan). Resolved at call time, so a handle made before ECEntitlements finished
-- loading still reaches it; each call is bound to the source.
G.ENTITLEMENT_METHODS = { "registerProduct", "getEntitlement", "quote", "purchase", "setAutoRenew",
    "getOrder", "refund", "onEntitlementChanged", "setPlan", "getPlan", "setPlanSource" }

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

-- spec = { modId, displayName = { CH=, EN=, ... }, nameKey? (the source's own translation key for its
-- name, preferred over displayName by clients), currencies = { id... }, reasonCodes = { code... } }
-- Returns a handle bound to the source ({ modId, credit, debit, post } plus the rev 2
-- G.ENTITLEMENT_METHODS) or nil, error.
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
    local nameKey = spec.nameKey
    if nameKey ~= nil and (type(nameKey) ~= "string" or #nameKey < 1 or #nameKey > G.NAME_KEY_MAX
        or not string.match(nameKey, "^[%w_]+$")) then
        return nil, "invalid_args"
    end
    local modId = spec.modId
    registry[modId] = { modId = modId, displayName = displayName, nameKey = nameKey, currencies = currencies,
        reasonCodes = reasonCodes, registeredAt = EC.now() }
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
    local handle = {
        modId = modId,
        credit = bind(G.credit),
        debit = bind(G.debit),
        post = function(req)
            local copy = {}
            if type(req) == "table" then for k, v in pairs(req) do copy[k] = v end end
            copy.modId = modId
            return G.post(copy)
        end,
        transfer = function(from, to, currency, amount, opts)
            local copy = {}
            if type(opts) == "table" then for k, v in pairs(opts) do copy[k] = v end end
            copy.modId = modId
            return G.transfer(from, to, currency, amount, copy)
        end,
    }
    for _, name in ipairs(G.ENTITLEMENT_METHODS) do
        handle[name] = function(...)
            local Ent = EC.Entitlements
            if type(Ent) ~= "table" or type(Ent[name]) ~= "function" then return { ok = false, error = "not_ready" } end
            return Ent[name](modId, ...)
        end
    end
    return handle
end

-- Read-only view of a source registered this session (nil otherwise) for ECEntitlements.
function G.source(modId)
    local live = validModId(modId) and registry[modId] or nil
    if not live then return nil end
    local cfg = md and md.config.sources[modId]
    return { currencies = live.currencies, reasonCodes = live.reasonCodes, enabled = cfg == nil or cfg.enabled ~= false,
        allowTransfer = cfg ~= nil and cfg.allowTransfer == true, nameKey = live.nameKey, displayName = live.displayName }
end

-- One call of this source's per-tick budget for a mutation that moves no money (auto-renew
-- consent); false when the budget is spent.
function G.takeCall(modId)
    local calls = (tickCalls[modId] or 0) + 1
    tickCalls[modId] = calls
    return calls <= G.CALLS_PER_TICK
end


-- ---------- posting ----------

-- req = { modId, requestId, reasonCode, reasonText?, ref?, meta?,
--         postings = { { account, currency, amount }, ... } }
-- Accounts are player usernames or the source's own MOD:<modId>; per-currency sums must be 0.
--
-- `internal` is ECEntitlements' own argument and never reaches the facade (G.post passes nil):
--   { commit = <L.post commit descriptor>, reversal = <amount>? }
-- It keys idempotency under "ent:" instead of "mod:", hands the copy-on-write commit to L.post,
-- and for a reversal of one paid order (at most that order's amount, once - ECEntitlements owns
-- that bound) counts the mint as `refund` instead of weighing it against dailyMintCap. Budget,
-- source switch, reason codes, currencies, burn cap and every ledger check are the same code.
local function post(req, internal)
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

    local key = (internal and "ent:" or "mod:") .. #modId .. ":" .. modId .. ":" .. req.requestId
    local prior = L.priorResult(key)
    if prior then
        if not prior.meta or prior.meta.fp ~= fp then return reject(modId, "request_conflict", req) end
        return { ok = prior.ok, txId = prior.txId, seq = prior.seq, error = prior.error, duplicate = true }
    end

    -- Daily caps per source, totals across currencies (spec 21.2). A refused call leaves no row.
    local mint, burn, refund = 0, 0, 0
    for _, delta in pairs(modDelta) do
        if delta < 0 then mint = mint - delta else burn = burn + delta end
    end
    -- the bounded reversal of one paid order is not new money: it never needs mint headroom
    local reversal = internal and internal.reversal
    if mint > 0 and isInteger(reversal) and mint <= reversal then mint, refund = 0, mint end
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
        postings = postings, commit = internal and internal.commit or nil,
    })
    if not res.ok then return reject(modId, res.error, req) end
    local row = dailyRow(day, modId, true)
    row.mint, row.burn, row.calls, row.ok = row.mint + mint, row.burn + burn, row.calls + 1, row.ok + 1
    row.refund = (row.refund or 0) + refund
    return { ok = true, txId = res.txId, seq = res.seq, duplicate = false }
end

function G.post(req)
    return post(req, nil)
end

-- ECEntitlements only (never on the facade or a handle). internal = { commit, reversal? }.
function G.entitlementPost(req, internal)
    if type(internal) ~= "table" then return { ok = false, error = "invalid_args" } end
    return post(req, internal)
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

-- transfer: player -> player (rev 3, ECTransfer). opts = { modId, requestId, reasonCode,
-- reasonText?, ref?, meta? }. The source must be enabled and marked allowTransfer by the host;
-- the money rules (switches, recipient, freezes, age, range, daily limit, caps, fee) are
-- ECTransfer's. Shares the source's "mod:" idempotency namespace with post, so one requestId is
-- one operation of that source whatever it was. -> { ok, txId, fee, duplicate } | { ok=false, error }
function G.transfer(from, to, currency, amount, opts)
    if type(opts) ~= "table" then return { ok = false, error = "invalid_args" } end
    if not md then return { ok = false, error = "not_ready" } end
    local modId = opts.modId
    local source = validModId(modId) and registry[modId] or nil
    if not source then return reject(nil, "unknown_source", opts) end
    local calls = (tickCalls[modId] or 0) + 1
    tickCalls[modId] = calls
    if calls > G.CALLS_PER_TICK then return reject(modId, "rate_limited", opts) end
    local cfg = configRow(modId, true)
    if cfg.enabled == false then return reject(modId, "source_disabled", opts) end
    if cfg.allowTransfer ~= true then return reject(modId, "transfer_not_allowed", opts) end
    if not shortString(opts.requestId, G.REQUEST_ID_MAX) then return reject(modId, "invalid_args", opts) end
    if type(opts.reasonCode) ~= "string" or not source.reasonCodes[opts.reasonCode] then
        return reject(modId, "invalid_args", opts)
    end
    local extras, extrasErr = cleanExtras(opts)
    if not extras then return reject(modId, extrasErr, opts) end
    if type(from) ~= "string" or type(to) ~= "string" or not isInteger(amount) or amount <= 0
        or not EC.CURRENCIES[currency] then
        return reject(modId, "invalid_args", opts)
    end
    if not source.currencies[currency] then return reject(modId, "currency_not_allowed", opts) end
    local Tr = EC.Transfer
    if type(Tr) ~= "table" or type(Tr.execute) ~= "function" then return reject(modId, "not_ready", opts) end
    local res = Tr.execute({
        from = from, to = to, currency = currency, amount = amount,
        key = "mod:" .. #modId .. ":" .. modId .. ":" .. opts.requestId,
        reasonCode = opts.reasonCode, reasonText = extras.reasonText, actor = modId,
        payload = { sourceMod = modId, ref = extras.ref, meta = extras.meta },
    })
    if not res.ok then return reject(modId, res.error, opts) end
    if not res.duplicate then
        local row = dailyRow(R.dayKey(EC.now()), modId, true)
        row.calls, row.ok = row.calls + 1, row.ok + 1
    end
    return { ok = true, txId = res.txId, fee = res.fee, duplicate = res.duplicate == true }
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
            sourceNameKey = live and live.nameKey or nil,
            loaded = live ~= nil,
            enabled = cfg.enabled ~= false,
            dailyMintCap = cfg.dailyMintCap or 0,
            allowTransfer = cfg.allowTransfer == true,
            dailyBurnCap = cfg.dailyBurnCap,
            registeredAt = cfg.registeredAt,
            balance = {},
            today = {
                mint = today and today.mint or 0, burn = today and today.burn or 0, refund = today and today.refund or 0,
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

-- values = { dailyMintCap?, dailyBurnCap? (false = unlimited), enabled?, allowTransfer? }; each change is audited.
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
    if values.allowTransfer ~= nil then
        if type(values.allowTransfer) ~= "boolean" then return false, "invalid_args" end
        changes[#changes + 1] = { "allowTransfer", cfg.allowTransfer == true, values.allowTransfer }
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
