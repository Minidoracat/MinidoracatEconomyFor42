-- MinidoracatEconomyFor42 - entitlement plans (API rev 2, server authority).
--
-- One flat price sheet per product a source registers (contract "plan shape"):
--   { revision, permanentEnabled, permanentCurrency, permanentPrice, permanentLimit,
--     rentalEnabled, rentalCurrency, rentalPrice, rentalLimit, rentalDays,
--     graceHours, reminderHours, autoRenewAllowed }
-- Global ModData is the financial truth: md.entitlements.plans[modId][productId] =
--   { revision, values, nameKey, provisional?, lastChange = { actor, origin, at, reason?, revision } }
-- Any change of any field is revision + 1. A quote carries the revision it was priced at and a
-- purchase refuses another one; an auto-renew consent records the money terms it agreed to and
-- pauses while the plan offers other ones (ECEntitlements). Existing paid periods keep their own
-- frozen terms.
--
-- The plan belongs to its source: the product's mod decides it (its own settings file or admin
-- window) and hands it over whole through setPlan. Economy validates and stores it; it has no editor
-- and no sandbox mirror of its own. `defaults` only create the row the first time this ModData sees
-- the product; a row an older version saved that no longer validates is provisional (defaults
-- nobody can buy under) until a setPlan replaces it.
-- setPlanSource keeps, in memory only, where the source reads its plan from and what is wrong with
-- it, for the admin overview.

if not MinidoracatEconomy or not MinidoracatEconomy.Integration then
    require "MinidoracatEconomy/ECIntegration"
end
local EC = MinidoracatEconomy
local S = EC and EC.Server
local X = EC and EC.Export
local G = EC and EC.Integration
if not S or not S.AUTHORITY or not X or not G then
    return
end

EC.EntitlementPlans = EC.EntitlementPlans or {}
local P = EC.EntitlementPlans

P.PRODUCT_ID_MAX = 32
P.NAME_KEY_MAX = 96
P.REASON_KEEP = 64
P.ACTOR_MAX = 64
P.SOURCE_FILE_MAX = 160
P.PROBLEM_KEY_MAX = 96
P.PROBLEM_REF_MAX = 64
P.ORIGINS = { file = true, admin = true, source = true }
P.REQUIRED_REASONS = { "entitlement_purchase", "entitlement_renewal", "entitlement_refund" }

P.FIELDS = {
    { key = "permanentEnabled", kind = "bool" },
    { key = "permanentCurrency", kind = "currency" },
    { key = "permanentPrice", kind = "int", min = 1, max = 1000000000 },
    { key = "permanentLimit", kind = "int", min = 0, max = 1000 },
    { key = "rentalEnabled", kind = "bool" },
    { key = "rentalCurrency", kind = "currency" },
    { key = "rentalPrice", kind = "int", min = 1, max = 1000000000 },
    { key = "rentalLimit", kind = "int", min = 1, max = 1000 },
    { key = "rentalDays", kind = "int", min = 1, max = 365 },
    { key = "graceHours", kind = "int", min = 0, max = 168 },
    { key = "reminderHours", kind = "int", min = 0, max = 168 },
    { key = "autoRenewAllowed", kind = "bool" },
}
local FIELD = {}
for _, f in ipairs(P.FIELDS) do FIELD[f.key] = f end

local md = nil          -- md.entitlements
local products = {}     -- modId -> productId -> { modId, id, nameKey, defaults, instant, validatePurchase }
local sources = {}      -- modId \1 productId -> { file?, problem?, at } (setPlanSource, this process only)

local function isInt(v)
    return type(v) == "number" and v == math.floor(v) and v > -1e15 and v < 1e15
end

local function keyOf(modId, productId)
    return modId .. "\1" .. productId
end

local function sourceCurrencies(modId)
    local src = G.source(modId)
    return src and src.currencies or nil
end

-- A complete plan (every field, nothing else) or nil, error, field. `currencies` (a set) limits the
-- currency fields to what the source registered; nil skips that part.
function P.validate(values, currencies)
    if type(values) ~= "table" then return nil, "invalid_plan" end
    for k in pairs(values) do
        if FIELD[k] == nil then return nil, "unknown_fields", string.sub(tostring(k), 1, 32) end
    end
    local out = {}
    for _, f in ipairs(P.FIELDS) do
        local v = values[f.key]
        if f.kind == "bool" then
            if type(v) ~= "boolean" then return nil, "invalid_plan", f.key end
        elseif f.kind == "currency" then
            if type(v) ~= "string" or not EC.CURRENCIES[v] or (currencies ~= nil and not currencies[v]) then
                return nil, "invalid_plan", f.key
            end
        elseif not isInt(v) or v < f.min or v > f.max then
            return nil, "invalid_plan", f.key
        end
        out[f.key] = v
    end
    return out
end

local function sameValues(a, b)
    for _, f in ipairs(P.FIELDS) do
        if a[f.key] ~= b[f.key] then return false end
    end
    return true
end

local function changedFields(before, after)
    local out = {}
    for _, f in ipairs(P.FIELDS) do
        if before == nil or before[f.key] ~= after[f.key] then out[#out + 1] = f.key end
    end
    return out
end

-- ---------- registry ----------

function P.product(modId, productId)
    local bySource = products[modId]
    return bySource and bySource[productId] or nil
end

function P.row(modId, productId)
    local bySource = md and md.plans[modId]
    return bySource and bySource[productId] or nil
end

-- The plan as a snapshot publishes it: a copy carrying its revision (and provisional, when no plan
-- was adopted yet).
function P.copy(row)
    local out = { revision = row.revision, provisional = row.provisional or nil }
    for k, v in pairs(row.values) do out[k] = v end
    return out
end

local function lastChangeOf(row)
    local lc = row.lastChange or {}
    return { actor = lc.actor, origin = lc.origin, at = lc.at, reason = lc.reason, revision = lc.revision }
end

local function copyProblem(p)
    return p and { key = p.key, field = p.field, ref = p.ref } or nil
end

local function sourceOf(modId, productId)
    local s = sources[keyOf(modId, productId)]
    return s and { file = s.file, problem = copyProblem(s.problem), at = s.at } or nil
end

-- First sight of a product in this ModData creates its plan row from the defaults; a known row
-- keeps its plan, provisional when an older version saved fields that no longer validate.
function P.reconcile(modId, productId)
    local spec = P.product(modId, productId)
    if not spec or not md then return end
    local bySource = md.plans[modId]
    if not bySource then
        bySource = {}
        md.plans[modId] = bySource
    end
    local row = bySource[productId]
    if row == nil then
        row = { revision = 1, values = spec.defaults, nameKey = spec.nameKey }
        row.lastChange = { actor = "system", origin = "defaults", at = EC.now(), revision = 1 }
        bySource[productId] = row
        X.emit("entitlement.plan", { sourceMod = modId, productId = productId, revision = 1,
            actor = "system", origin = "defaults", created = true })
        return
    end
    row.nameKey = spec.nameKey
    row.applies = nil           -- receipts of the removed admin editor
    if not P.validate(row.values, nil) then row.values, row.provisional = spec.defaults, true end
end

-- spec = { id, nameKey, defaults = <plan without revision>, instant?, validatePurchase? }. Callable
-- before ModData is ready; the plan row is then created by P.init. Re-registering a product
-- replaces its runtime spec. `instant`: payments take effect in the paying commit (ECEntitlements).
function P.register(modId, spec)
    local src = G.source(modId)
    if not src then return { ok = false, error = "unknown_source" } end
    if type(spec) ~= "table" then return { ok = false, error = "invalid_args" } end
    local id = spec.id
    if type(id) ~= "string" or #id < 1 or #id > P.PRODUCT_ID_MAX or not string.match(id, "^[a-z0-9_]+$") then
        return { ok = false, error = "invalid_args", field = "id" }
    end
    local nameKey = spec.nameKey
    if type(nameKey) ~= "string" or nameKey == "" or #nameKey > P.NAME_KEY_MAX or string.find(nameKey, "%c") then
        return { ok = false, error = "invalid_args", field = "nameKey" }
    end
    for _, code in ipairs(P.REQUIRED_REASONS) do
        if not src.reasonCodes[code] then return { ok = false, error = "invalid_args", field = "reasonCodes." .. code } end
    end
    if type(spec.defaults) == "table" and spec.defaults.revision ~= nil then
        return { ok = false, error = "invalid_args", field = "defaults.revision" }
    end
    local defaults, _, field = P.validate(spec.defaults, src.currencies)
    if not defaults then return { ok = false, error = "invalid_args", field = "defaults." .. tostring(field) } end
    -- the sandbox mirror is gone: a source that still asks for it must not believe it got one
    if spec.sandbox ~= nil then return { ok = false, error = "invalid_args", field = "sandbox" } end
    if spec.instant ~= nil and type(spec.instant) ~= "boolean" then
        return { ok = false, error = "invalid_args", field = "instant" }
    end
    if spec.validatePurchase ~= nil and type(spec.validatePurchase) ~= "function" then
        return { ok = false, error = "invalid_args", field = "validatePurchase" }
    end
    local bySource = products[modId]
    if not bySource then
        bySource = {}
        products[modId] = bySource
    end
    bySource[id] = { modId = modId, id = id, nameKey = nameKey, defaults = defaults, instant = spec.instant == true,
        validatePurchase = spec.validatePurchase }
    if md then P.reconcile(modId, id) end
    EC.log("entitlement product registered: " .. modId .. "/" .. id)
    return { ok = true, product = { sourceMod = modId, id = id, nameKey = nameKey } }
end

-- ---------- the source's plan ----------

-- opts = { actor?, origin?, reason?, expectedRevision? } -> actor, origin, reason, expectedRevision,
-- or nil, field.
local function planOpts(opts)
    if opts == nil then opts = {} end
    if type(opts) ~= "table" then return nil, "opts" end
    local actor = opts.actor == nil and "source" or opts.actor
    if type(actor) ~= "string" or actor == "" or #actor > P.ACTOR_MAX or string.find(actor, "%c") then return nil, "actor" end
    local origin = opts.origin == nil and "source" or opts.origin
    if not P.ORIGINS[origin] then return nil, "origin" end
    local reason = opts.reason
    if reason ~= nil then
        -- the admin reason ceiling (ECAdmin.REASON_MAX characters, up to 3 bytes each)
        if type(reason) ~= "string" or #reason > EC.Admin.REASON_MAX * 3 then return nil, "reason" end
        reason = string.gsub(reason, "%c", " ")
    end
    local expected = opts.expectedRevision
    if expected ~= nil and not isInt(expected) then return nil, "expectedRevision" end
    return actor, origin, reason, expected
end

-- The source hands over its whole plan. The same content (with a real plan in place) is a no-op
-- that ignores expectedRevision, so a resend is idempotent by itself; a change needs the revision it
-- was based on when one is given. Effects on contracts follow from the plan alone: consents pause
-- and resume by their recorded terms, rentals over a lowered limit by rentalLimit.
function P.set(modId, productId, values, opts)
    if not md then return { ok = false, error = "not_ready" } end
    local row = P.row(modId, productId)
    if not row then return { ok = false, error = "unknown_product" } end
    local actor, origin, reason, expected = planOpts(opts)
    if not actor then return { ok = false, error = "invalid_args", field = origin } end
    local clean, err, field = P.validate(values, sourceCurrencies(modId))
    if not clean then return { ok = false, error = err, field = field } end
    if not row.provisional and sameValues(clean, row.values) then
        return { ok = true, updated = false, revision = row.revision, changed = {} }
    end
    if expected ~= nil and expected ~= row.revision then return { ok = false, error = "stale_revision" } end
    local before = row.values
    local changed = changedFields(before, clean)
    local revision = row.revision + 1
    row.values, row.revision, row.provisional = clean, revision, nil
    row.lastChange = { actor = actor, origin = origin, at = EC.now(), revision = revision,
        reason = reason and string.sub(reason, 1, P.REASON_KEEP) or nil }
    local target = modId .. "/" .. productId
    X.emit("entitlement.plan", { sourceMod = modId, productId = productId, revision = revision,
        actor = actor, origin = origin, fields = changed })
    for _, f in ipairs(changed) do
        X.audit({ action = "entitlement.plan", target = target, field = f, before = before[f],
            after = clean[f], revision = revision, admin = actor, origin = origin, reason = reason })
    end
    if P.onChanged then P.onChanged(modId, productId) end
    return { ok = true, updated = true, revision = revision, changed = changed }
end

function P.get(modId, productId)
    if not md then return { ok = false, error = "not_ready" } end
    local row = P.row(modId, productId)
    if not row then return { ok = false, error = "unknown_product" } end
    return { ok = true, plan = P.copy(row), lastChange = lastChangeOf(row), source = sourceOf(modId, productId) }
end

local function sourceText(v, max)
    if v == nil then return true, nil end
    if type(v) ~= "string" then return false end
    v = string.gsub(v, "%c", "")
    if #v > max then return false end
    return true, v
end

local function translationKey(v)
    return type(v) == "string" and #v >= 1 and #v <= P.PROBLEM_KEY_MAX and string.match(v, "^[%w_]+$") ~= nil
end

-- A problem is nil (no error) or { key = <translation key>, field = <translation key>?, ref = <raw text>? }:
-- the admin overview words it in the reader's language; ref is data (a file key), shown as is.
local function problemOf(v)
    if v == nil then return true, nil end
    if type(v) ~= "table" or not translationKey(v.key) or (v.field ~= nil and not translationKey(v.field)) then return false end
    local ok, ref = sourceText(v.ref, P.PROBLEM_REF_MAX)
    if not ok then return false end
    return true, { key = v.key, field = v.field, ref = ref }
end

-- info = { file?, problem? } (problem nil = no error). Memory only, for the admin overview.
function P.setSource(modId, productId, info)
    if not P.product(modId, productId) then return { ok = false, error = "unknown_product" } end
    if info ~= nil and type(info) ~= "table" then return { ok = false, error = "invalid_args" } end
    info = info or {}
    local okFile, file = sourceText(info.file, P.SOURCE_FILE_MAX)
    if not okFile then return { ok = false, error = "invalid_args", field = "file" } end
    local okProblem, problem = problemOf(info.problem)
    if not okProblem then return { ok = false, error = "invalid_args", field = "problem" } end
    sources[keyOf(modId, productId)] = { file = file, problem = problem, at = EC.now() }
    return { ok = true }
end

-- Every plan this ModData knows (loaded this session or not), for the admin overview.
function P.list()
    local out = {}
    if not md then return out end
    for modId, bySource in pairs(md.plans) do
        for productId, row in pairs(bySource) do
            local spec = P.product(modId, productId)
            local src = G.source(modId)
            out[#out + 1] = {
                sourceMod = modId, productId = productId, nameKey = row.nameKey,
                sourceNameKey = src and src.nameKey or nil, sourceName = src and src.displayName or nil,
                loaded = spec ~= nil, instant = spec ~= nil and spec.instant, plan = P.copy(row),
                lastChange = lastChangeOf(row), source = sourceOf(modId, productId),
            }
        end
    end
    EC.sortSafe(out, function(a, b)
        if a.sourceMod ~= b.sourceMod then return a.sourceMod < b.sourceMod end
        return a.productId < b.productId
    end)
    return out
end

function P.init(ent)
    md = ent
    md.plans = md.plans or {}
    for modId, bySource in pairs(products) do
        for productId in pairs(bySource) do P.reconcile(modId, productId) end
    end
end

return P
