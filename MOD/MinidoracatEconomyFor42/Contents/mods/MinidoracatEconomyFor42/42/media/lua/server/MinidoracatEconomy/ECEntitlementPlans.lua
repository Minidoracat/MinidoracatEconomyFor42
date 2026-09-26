-- MinidoracatEconomyFor42 - entitlement plans (API rev 2, server authority).
--
-- One flat price sheet per product a source registers (contract "plan shape"):
--   { revision, permanentEnabled, permanentCurrency, permanentPrice, permanentLimit,
--     rentalEnabled, rentalCurrency, rentalPrice, rentalQuantity, rentalDays,
--     graceHours, reminderHours, autoRenewAllowed }
-- Global ModData is the financial truth: md.entitlements.plans[modId][productId] =
--   { revision, values, nameKey, lastChange = { actor, origin, at, reason?, requestId?, revision },
--     applies = { { requestId, fp, revision, admin, at, changed }, ... newest first, <= 8 } }
-- Any change of any field is revision + 1. A quote carries the revision it was priced at and a
-- purchase refuses another one; an auto-renew consent names the revision it agreed to and pauses
-- once the plan moves on (ECEntitlements). Existing paid periods keep their own frozen terms.
--
-- Sandbox mirror (contract FINAL 9). A product that maps its fields to sandbox options must also
-- map `revision` to an integer option of its own (VM: PaidSlotPlanRevision) that only Economy
-- writes. The sandbox file is saved at once (SandboxOptions.saveServerLuaFile, a plain FileWriter,
-- SandboxOptions.java:683-685 / 862-870) while ModData waits for the world save, so the revision
-- decides direction (S = sandbox revision, G = plan revision), at start and every POLL_MS:
--   S >  G            the sandbox is newer (ModData lost an applied change in a crash, or the
--                     host edited the file and raised the revision): adopt it as revision S
--   S == G, same      in step
--   S == G, different an edit made through the vanilla sandbox UI or the file: accept it as
--                     revision G + 1, write the new revision back, audit it
--   S <  G            a stale whole-table copy (the vanilla UI sends every option it copied
--                     when it opened, GameServer.java:1694-1708): a conflict. It is never
--                     imported; the plan is written back over it and the conflict is reported
-- A write sets the mapped options and the revision, projects them (toLua) and saves the server
-- sandbox file; only a save that returned true counts. A failed save leaves the product dirty and
-- is retried on every poll; online clients hear entitlement.sandbox only after a successful save
-- (the server has no vanilla Lua broadcast for sandbox options).
-- Options that are there but invalid when a product is first seen are never replaced by the
-- defaults: the plan row is provisional (defaults nobody can buy under, `plan.provisional`), the
-- status says invalid with the field, and the first valid options - or an admin apply - become the
-- real plan.

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
P.OPTION_NAME_MAX = 128
P.REVISION_MAX = 2147483647
P.POLL_MS = 1000
P.APPLIES_KEEP = 8
P.REASON_KEEP = 64
P.REQUIRED_REASONS = { "entitlement_purchase", "entitlement_renewal", "entitlement_refund" }

P.FIELDS = {
    { key = "permanentEnabled", kind = "bool" },
    { key = "permanentCurrency", kind = "currency" },
    { key = "permanentPrice", kind = "int", min = 1, max = 1000000000 },
    { key = "permanentLimit", kind = "int", min = 0, max = 1000 },
    { key = "rentalEnabled", kind = "bool" },
    { key = "rentalCurrency", kind = "currency" },
    { key = "rentalPrice", kind = "int", min = 1, max = 1000000000 },
    { key = "rentalQuantity", kind = "int", min = 1, max = 1000 },
    { key = "rentalDays", kind = "int", min = 1, max = 365 },
    { key = "graceHours", kind = "int", min = 0, max = 168 },
    { key = "reminderHours", kind = "int", min = 0, max = 168 },
    { key = "autoRenewAllowed", kind = "bool" },
}
local FIELD = {}
for _, f in ipairs(P.FIELDS) do FIELD[f.key] = f end

local md = nil          -- md.entitlements
local products = {}     -- modId -> productId -> { modId, id, nameKey, defaults, sandbox, validatePurchase }
local status = {}       -- modId \1 productId -> { state, error?, field?, at?, dirty?, conflict? }
local lastPoll = 0

local function isInt(v)
    return type(v) == "number" and v == math.floor(v) and v > -1e15 and v < 1e15
end

local function keyOf(modId, productId)
    return modId .. "\1" .. productId
end

local function statusOf(modId, productId)
    local k = keyOf(modId, productId)
    local st = status[k]
    if not st then
        st = { state = "unmapped" }
        status[k] = st
    end
    return st
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

local function validOptionName(name)
    return type(name) == "string" and #name <= P.OPTION_NAME_MAX and string.find(name, "%c") == nil
        and string.match(name, "^[^%.]+%..+$") ~= nil
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

-- ---------- sandbox access ----------

local function sandboxOptions()
    if type(getSandboxOptions) ~= "function" then return nil end
    local ok, opts = pcall(getSandboxOptions)
    if ok and opts ~= nil then return opts end
    return nil
end

local function optionExists(opts, name)
    local ok, opt = pcall(function() return opts:getOptionByName(name) end)
    return ok and opt ~= nil
end

-- SandboxVars.<Page>.<Option> is what toLua projects (SandboxOptions.java:279-285) and what the
-- vanilla packet handler refreshes; reading it never touches the Java objects.
local function readVar(name)
    local page, short = string.match(name, "^([^%.]+)%.(.+)$")
    local vars = page and SandboxVars and SandboxVars[page]
    if type(vars) ~= "table" then return nil end
    return vars[short]
end

-- The mapped options as the server sees them now, on top of `base` for unmapped fields:
-- values, revision - or nil, state, field when the mirror cannot be read.
local function readSandbox(spec, base)
    local opts = sandboxOptions()
    if not opts then return nil, "unavailable" end
    local values, revision = {}, nil
    for k, v in pairs(base) do values[k] = v end
    for field, name in pairs(spec.sandbox) do
        local v = nil
        if optionExists(opts, name) then v = readVar(name) end
        if v == nil then return nil, "missing_option", field end
        if field == "revision" then revision = v else values[field] = v end
    end
    if not isInt(revision) or revision < 0 or revision > P.REVISION_MAX then return nil, "invalid", "revision" end
    return values, revision
end

local function setOptions(opts, map, values, revision)
    for field, name in pairs(map) do
        if field == "revision" then opts:set(name, revision) else opts:set(name, values[field]) end
    end
    opts:toLua()
    return opts:saveServerLuaFile(getServerName())
end

-- Mirror (values, revision) into the product's options and the server sandbox file; true only
-- when the save itself returned true. Successful saves are announced to every online client.
local function writeSandbox(spec, values, revision)
    local st = statusOf(spec.modId, spec.id)
    local opts = sandboxOptions()
    local ok, saved = false, nil
    if opts then ok, saved = pcall(setOptions, opts, spec.sandbox, values, revision) end
    st.at = EC.now()
    if not ok or saved ~= true then
        st.state, st.dirty = "write_failed", true
        st.error = not opts and "unavailable" or (ok and "save_failed" or "save_error")
        EC.log("entitlement plan " .. spec.modId .. "/" .. spec.id .. " sandbox write failed: "
            .. tostring(st.error) .. (ok and "" or (" " .. tostring(saved))))
        return false, st.error
    end
    st.state, st.dirty, st.error, st.field = "synced", nil, nil, nil
    local out = {}
    for field, name in pairs(spec.sandbox) do
        if field == "revision" then out[name] = revision else out[name] = values[field] end
    end
    S.broadcast("entitlement.sandbox", { values = out })
    return true
end

-- The mirror as a reply states it: ok only for a mapped product that is synced and clean; a
-- product without a mirror has nothing to sync.
local function sandboxReply(spec)
    if spec.sandbox == nil then return { ok = true, skipped = "unmapped" } end
    local st = statusOf(spec.modId, spec.id)
    if st.state == "synced" and not st.dirty then return { ok = true } end
    return { ok = false, error = st.error or st.state, state = st.state, field = st.field }
end

-- ---------- changes ----------

-- The one place a plan changes: new values and revision, who and why, an event and one audit
-- record per changed field, then the public refresh signal (ECEntitlements sets P.onChanged).
local function publish(spec, row, values, revision, actor, origin, reason, requestId)
    local before = row.values
    local changed = changedFields(before, values)
    local now = EC.now()
    row.values, row.revision, row.provisional = values, revision, nil
    row.lastChange = { actor = actor, origin = origin, at = now, revision = revision, requestId = requestId,
        reason = type(reason) == "string" and string.sub(reason, 1, P.REASON_KEEP) or nil }
    local target = spec.modId .. "/" .. spec.id
    X.emit("entitlement.plan", { sourceMod = spec.modId, productId = spec.id, revision = revision,
        actor = actor, origin = origin, fields = changed })
    if before ~= nil then
        for _, field in ipairs(changed) do
            X.audit({ action = "entitlement.plan", target = target, field = field, before = before[field],
                after = values[field], revision = revision, admin = actor, origin = origin, reason = reason })
        end
    end
    if P.onChanged then P.onChanged(spec.modId, spec.id) end
    return changed
end

-- Bring one product's plan and its sandbox mirror into step (rules in the header).
local function sync(spec, row)
    local st = statusOf(spec.modId, spec.id)
    if spec.sandbox == nil then
        st.state = "unmapped"
        return
    end
    local values, revision, field = readSandbox(spec, row.values)
    if values == nil then
        st.state, st.field, st.at = revision, field, EC.now()
        return
    end
    local clean, _, bad = P.validate(values, sourceCurrencies(spec.modId))
    if row.provisional then
        -- no plan was adopted from these options yet: take them whole once they are valid, never write
        -- the defaults over them
        if not clean then
            st.state, st.field, st.at = "invalid", bad, EC.now()
            return
        end
        publish(spec, row, clean, math.max(revision, row.revision) + 1, "vanilla_sandbox", "sandbox", "sandbox options repaired")
        writeSandbox(spec, row.values, row.revision)
        return
    end
    if revision > row.revision then
        if not clean then
            st.state, st.field, st.at = "invalid", bad, EC.now()
            return
        end
        publish(spec, row, clean, revision, "vanilla_sandbox", "sandbox", "sandbox revision is newer than the plan")
        st.state, st.field, st.dirty = "synced", nil, nil
        return
    end
    if revision == row.revision then
        if clean and sameValues(clean, row.values) then
            if st.dirty then writeSandbox(spec, row.values, row.revision) else st.state, st.field = "synced", nil end
            return
        end
        if not clean then
            st.state, st.field, st.at = "invalid", bad, EC.now()
            return
        end
        publish(spec, row, clean, row.revision + 1, "vanilla_sandbox", "sandbox", "sandbox options edited")
        writeSandbox(spec, row.values, row.revision)
        return
    end
    -- a stale whole-table copy: report it and put the plan back
    st.conflict = { at = EC.now(), sandboxRevision = revision, planRevision = row.revision }
    X.emit("entitlement.sandbox_conflict", { sourceMod = spec.modId, productId = spec.id,
        sandboxRevision = revision, planRevision = row.revision })
    writeSandbox(spec, row.values, row.revision)
end

-- First sight of a product in this ModData, or a (re)registration: create the plan row from the
-- sandbox when it can be read and is valid, otherwise from the defaults - provisional when the
-- options are there but invalid - then keep in step.
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
        local values, revision, provisional, readState, readField = nil, 0, nil, nil, nil
        local read, rev = nil, nil
        if spec.sandbox then
            read, rev, readField = readSandbox(spec, spec.defaults)
            if read then
                values, readState, readField = P.validate(read, sourceCurrencies(modId))
                revision = rev
                if not values then provisional, readState = true, "invalid" end
            else
                readState = rev
            end
        end
        row = { revision = revision + 1, values = values or spec.defaults, nameKey = spec.nameKey, applies = {},
            provisional = provisional }
        row.lastChange = { actor = "system", origin = values and "sandbox" or "defaults", at = EC.now(), revision = row.revision }
        bySource[productId] = row
        X.emit("entitlement.plan", { sourceMod = modId, productId = productId, revision = row.revision,
            actor = "system", origin = row.lastChange.origin, created = true, provisional = provisional })
        if values then
            writeSandbox(spec, row.values, row.revision)
        elseif spec.sandbox then
            local st = statusOf(modId, productId)
            st.state, st.field, st.at = readState, readField, EC.now()
        end
        return
    end
    row.nameKey = spec.nameKey
    row.applies = row.applies or {}
    sync(spec, row)
end

-- spec = { id, nameKey, defaults = <plan without revision>, sandbox = { field = option, ...,
-- revision = option }?, validatePurchase? }. Callable before ModData is ready; the plan row is
-- then created by P.init. Re-registering a product replaces its runtime spec.
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
    local map = nil
    if spec.sandbox ~= nil then
        if type(spec.sandbox) ~= "table" then return { ok = false, error = "invalid_args", field = "sandbox" } end
        map = {}
        for k, name in pairs(spec.sandbox) do
            if (k ~= "revision" and FIELD[k] == nil) or not validOptionName(name) then
                return { ok = false, error = "invalid_args", field = "sandbox." .. string.sub(tostring(k), 1, 32) }
            end
            map[k] = name
        end
        if map.revision == nil then return { ok = false, error = "invalid_args", field = "sandbox.revision" } end
    end
    if spec.validatePurchase ~= nil and type(spec.validatePurchase) ~= "function" then
        return { ok = false, error = "invalid_args", field = "validatePurchase" }
    end
    local bySource = products[modId]
    if not bySource then
        bySource = {}
        products[modId] = bySource
    end
    bySource[id] = { modId = modId, id = id, nameKey = nameKey, defaults = defaults, sandbox = map,
        validatePurchase = spec.validatePurchase }
    if md then P.reconcile(modId, id) end
    EC.log("entitlement product registered: " .. modId .. "/" .. id)
    return { ok = true, product = { sourceMod = modId, id = id, nameKey = nameKey } }
end

-- ---------- admin ----------

local function applyEntry(row, requestId)
    for _, e in ipairs(row.applies or {}) do
        if e.requestId == requestId then return e end
    end
    return nil
end

-- The Economy admin page's whole-plan write. Idempotent per requestId: the same request with the
-- same content answers the recorded outcome (no second revision, no second audit); only applied
-- writes are recorded, so a refused one is judged again when it is resent.
function P.apply(modId, productId, expectedRevision, values, actor, reason, requestId)
    local row = P.row(modId, productId)
    if not row then return { ok = false, error = "unknown_product" } end
    local spec = P.product(modId, productId)
    if not spec then return { ok = false, error = "product_unavailable" } end
    local fp = EC.jsonEncode({ modId, productId, expectedRevision, values })
    local prior = applyEntry(row, requestId)
    if prior then
        if prior.fp ~= fp then return { ok = false, error = "request_conflict" } end
        return { ok = true, updated = true, duplicate = true, revision = prior.revision, changed = prior.changed,
            sandbox = sandboxReply(spec) }
    end
    sync(spec, row)       -- a sandbox edit nobody polled yet moves the revision first
    if not isInt(expectedRevision) or expectedRevision ~= row.revision then return { ok = false, error = "stale_revision" } end
    local clean, err, field = P.validate(values, sourceCurrencies(modId))
    if not clean then return { ok = false, error = err, field = field } end
    if not row.provisional and sameValues(clean, row.values) then
        return { ok = true, updated = false, changed = {}, revision = row.revision, sandbox = sandboxReply(spec) }
    end
    local changed = publish(spec, row, clean, row.revision + 1, actor, "admin", reason, requestId)
    local applies = { { requestId = requestId, fp = fp, revision = row.revision, admin = actor, at = EC.now(), changed = changed } }
    for i = 1, math.min(#row.applies, P.APPLIES_KEEP - 1) do applies[#applies + 1] = row.applies[i] end
    row.applies = applies
    if spec.sandbox then writeSandbox(spec, row.values, row.revision) end
    return { ok = true, updated = true, changed = changed, revision = row.revision, sandbox = sandboxReply(spec) }
end

function P.sandboxStatus(modId, productId)
    local spec = P.product(modId, productId)
    local st = status[keyOf(modId, productId)]
    local out = { state = spec == nil and "unavailable" or (st and st.state or "unmapped") }
    if st then
        out.error, out.field, out.at, out.dirty = st.error, st.field, st.at, st.dirty
        if st.conflict then
            out.conflict = { at = st.conflict.at, sandboxRevision = st.conflict.sandboxRevision, planRevision = st.conflict.planRevision }
        end
    end
    if spec and spec.sandbox then
        out.mapped = {}
        for k, v in pairs(spec.sandbox) do out.mapped[k] = v end
    end
    return out
end

-- Every plan this ModData knows (loaded this session or not), for the admin page.
function P.list()
    local out = {}
    if not md then return out end
    for modId, bySource in pairs(md.plans) do
        for productId, row in pairs(bySource) do
            local applies = {}
            for _, e in ipairs(row.applies or {}) do
                applies[#applies + 1] = { requestId = e.requestId, revision = e.revision, admin = e.admin, at = e.at }
            end
            local lc = row.lastChange or {}
            out[#out + 1] = {
                sourceMod = modId, productId = productId, nameKey = row.nameKey,
                loaded = P.product(modId, productId) ~= nil, plan = P.copy(row),
                sandboxStatus = P.sandboxStatus(modId, productId), applies = applies,
                lastChange = { actor = lc.actor, origin = lc.origin, at = lc.at, reason = lc.reason,
                    requestId = lc.requestId, revision = lc.revision },
            }
        end
    end
    EC.sortSafe(out, function(a, b)
        if a.sourceMod ~= b.sourceMod then return a.sourceMod < b.sourceMod end
        return a.productId < b.productId
    end)
    return out
end

-- Every registered product with a plan row, in step with its sandbox mirror (rate limited).
function P.poll(now)
    if not md or now - lastPoll < P.POLL_MS then return end
    lastPoll = now
    for modId, bySource in pairs(products) do
        for productId, spec in pairs(bySource) do
            local row = P.row(modId, productId)
            if row then sync(spec, row) end
        end
    end
end

function P.init(ent)
    md = ent
    md.plans = md.plans or {}
    status = {}
    lastPoll = 0
    for modId, bySource in pairs(products) do
        for productId in pairs(bySource) do P.reconcile(modId, productId) end
    end
end

return P
