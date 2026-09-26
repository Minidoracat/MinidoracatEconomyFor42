--[[
Client entitlement transport (ECEntitlementClient.lua) against fake PZ globals, loading the real
MOD file. Standard Lua 5.x, run from the repo root:

    lua scripts/test_entitlement_client.lua

What it pins is what a consumer mod (VehicleManager) relies on: one request in flight per
command and the server's 500 ms window respected, every caller's callback kept, stale replies
never overwriting a newer snapshot, a timeout reported as unknown without a re-send (keeping the
quote / order identity), a late answer updating the cache without a second callback, public
refresh signals, the server-driven sandbox sync, and the one shared reading of an order lookup.
]]

local MEDIA = os.getenv("EC_LUA_ROOT") or "MOD/MinidoracatEconomyFor42/Contents/mods/MinidoracatEconomyFor42/42/media/lua"

local nowMs = 5000000
local sent = {}
local ticks = {}
local gameStart = {}
local failures, checks = 0, 0

local function check(cond, label)
    checks = checks + 1
    if not cond then
        failures = failures + 1
        io.stderr:write("FAIL: " .. label .. "\n")
    end
end

function getTimestampMs() return nowMs end
function getPlayer() return { name = "tester" } end
function sendClientCommand(_, module, command, args)
    sent[#sent + 1] = { module = module, command = command, args = args }
end
function getText(key, a, b) return key .. (a and ("|" .. tostring(a)) or "") .. (b and ("|" .. tostring(b)) or "") end
function getTextOrNull(key)
    if string.find(key, "Ent_State_active", 1, true) then return "Active" end
    return nil
end

local sandboxSet, sandboxProjected = {}, 0
local registered = { ["MinidoracatVehicleManager.RentalPrice"] = true }
function getSandboxOptions()
    return {
        getOptionByName = function(_, name) return registered[name] and {} or nil end,
        set = function(_, name, value) sandboxSet[name] = value end,
        toLua = function() sandboxProjected = sandboxProjected + 1 end,
    }
end

Events = {
    OnTick = {
        Add = function(fn) ticks[#ticks + 1] = fn end,
        Remove = function(fn)
            for i = #ticks, 1, -1 do if ticks[i] == fn then table.remove(ticks, i) end end
        end,
    },
    OnGameStart = { Add = function(fn) gameStart[#gameStart + 1] = fn end },
}

local counter = 0
MinidoracatEconomy = {
    COMMAND_MODULE = "MinidoracatEconomy",
    now = function() return nowMs end,
    log = function() end,
    Client = {
        handlers = {},
        ReadGate = { MIN_MS = 650 },
        currencyName = function(id) return "cur:" .. tostring(id) end,
        newRequestId = function()
            counter = counter + 1
            return "r" .. counter
        end,
    },
}

dofile(MEDIA .. "/client/MinidoracatEconomy/ECEntitlementClient.lua")
local C = MinidoracatEconomy.Client
local E = C.Entitlements

local function tick(ms)
    nowMs = nowMs + (ms or 0)
    local list = {}
    for i, fn in ipairs(ticks) do list[i] = fn end
    for _, fn in ipairs(list) do fn() end
end

local function reply(command, args) C.handlers[command](args) end

local function envelope(rev, planRev, extra)
    local env = { ok = true, sourceMod = "MinidoracatVehicleManagerFor42", productId = "claim_slot",
        entitlement = { revision = rev, usable = rev }, plan = { revision = planRev or 1 } }
    for k, v in pairs(extra or {}) do env[k] = v end
    return env
end

local SRC, PROD = "MinidoracatVehicleManagerFor42", "claim_slot"

-- ---------- local refusals send nothing ----------
;(function()
    local id, why = E.quote(SRC, "Bad-Id", "permanent", 1, function() end)
    check(id == nil and why == "invalid_args", "invalid product id refused locally")
    id, why = E.quote(SRC, PROD, "lifetime", 1, function() end)
    check(id == nil and why == "invalid_args", "unknown kind refused locally")
    check(#sent == 0, "nothing sent for refused arguments")
end)()

-- ---------- one in flight per command, the 500 ms window respected, every callback kept ----------
local changed = {}
E.onChanged(function(env) changed[#changed + 1] = env end)

;(function()
    local gotA, gotA2, gotB = {}, {}, {}
    local idA = E.requestState(SRC, PROD, function(r) gotA[#gotA + 1] = r end)
    local idB = E.requestState(SRC, "other_slot", function(r) gotB[#gotB + 1] = r end)
    local idA2 = E.requestState(SRC, "other_slot", function(r) gotA2[#gotA2 + 1] = r end)
    check(#sent == 1 and sent[1].command == "entitlement.state" and sent[1].args.requestId == idA,
        "first read leaves at once, the second waits for the lane")
    check(idA2 == idB, "a queued read for the same product answers both callers")
    reply("entitlement.state", envelope(3, 1, { requestId = idA }))
    check(#gotA == 1 and gotA[1].entitlement.revision == 3, "caller A got its reply")
    check(E.getState(SRC, PROD).entitlement.revision == 3, "reply cached")
    check(#changed == 1, "onChanged fired for the adopted snapshot")
    tick(100)
    check(#sent == 1, "no second command inside the server window")
    tick(600)
    check(#sent == 2 and sent[2].args.productId == "other_slot", "queued read goes after 650 ms")
    local other = envelope(1, 1, { requestId = sent[2].args.requestId })
    other.productId = "other_slot"
    reply("entitlement.state", other)
    check(#gotB == 1 and #gotA2 == 1, "both callers of the shared read answered exactly once")
end)()

-- ---------- stale and reordered replies never overwrite ----------
;(function()
    reply("entitlement.changed", envelope(5, 1))
    check(E.getState(SRC, PROD).entitlement.revision == 5, "owner push adopted")
    local before = #changed
    tick(700)
    local cbs = 0
    local id = E.requestState(SRC, PROD, function() cbs = cbs + 1 end)
    reply("entitlement.state", envelope(4, 1, { requestId = id }))
    check(cbs == 1, "stale reply still answers its caller")
    check(E.getState(SRC, PROD).entitlement.revision == 5, "older revision does not overwrite the cache")
    check(#changed == before, "no onChanged for a stale snapshot")
    reply("entitlement.changed", envelope(5, 2))
    check(E.getState(SRC, PROD).plan.revision == 2, "same entitlement, newer plan revision adopted")
end)()

-- ---------- quote identity survives a purchase timeout; nothing is re-sent ----------
;(function()
    tick(700)
    local quoteId
    E.quote(SRC, PROD, "rental", 1, function(r) quoteId = r.ok and r.quote.id end)
    local q = sent[#sent]
    reply("entitlement.quote", { ok = true, requestId = q.args.requestId,
        quote = { id = "q-77", orderId = "q-77", kind = "rental", quantity = 1, amount = 250 },
        snapshot = envelope(6, 2) })
    check(quoteId == "q-77", "quote reply delivered")
    tick(700)
    local results = {}
    local pid = E.purchase(SRC, "q-77", function(r) results[#results + 1] = r end)
    local count = #sent
    check(sent[count].command == "entitlement.purchase" and sent[count].args.quoteId == "q-77"
        and sent[count].args.productId == nil, "purchase wire carries only sourceMod and quoteId")
    local again, why = E.purchase(SRC, "q-77", function() end)
    check(again == nil and why == "pending", "same quote refused while its purchase is open")
    tick(10001)
    check(#results == 1 and results[1].ok == false and results[1].error == "timeout"
        and results[1].unknown == true, "timeout reported as unknown")
    check(results[1].quoteId == "q-77" and results[1].orderId == "q-77" and results[1].productId == PROD
        and results[1].requestId == pid, "timeout keeps quote, order and product identity")
    tick(10001)
    check(#sent == count, "timed-out purchase is never re-sent")
    -- the late answer: the cache takes its snapshot, the callback is not called again
    reply("entitlement.purchase", { ok = true, requestId = pid, orderId = "q-77", snapshot = envelope(7, 2) })
    check(#results == 1, "late answer does not call the callback twice")
    check(E.getState(SRC, PROD).entitlement.revision == 7, "late answer's snapshot adopted")
end)()

-- ---------- public refresh signal re-reads only what this client holds ----------
;(function()
    tick(700)
    local count = #sent
    reply("entitlement.changed", { sourceMod = "SomeOtherMod" })
    check(#sent == count, "refresh for another source sends nothing")
    reply("entitlement.changed", { sourceMod = SRC, productId = PROD })
    check(#sent == count + 1 and sent[#sent].command == "entitlement.state"
        and sent[#sent].args.productId == PROD, "refresh signal re-reads the held product")
    check(E.getState(SRC, PROD).entitlement.revision == 7, "a signal is not a snapshot")
end)()

-- ---------- sandbox sync: registered options only, projected once, nothing sent back ----------
;(function()
    local count = #sent
    reply("entitlement.sandbox", { values = { ["MinidoracatVehicleManager.RentalPrice"] = 300, ["Unknown.Option"] = 1 } })
    check(sandboxSet["MinidoracatVehicleManager.RentalPrice"] == 300, "registered option set")
    check(sandboxSet["Unknown.Option"] == nil, "unregistered option ignored")
    check(sandboxProjected == 1, "SandboxVars projected once")
    check(#sent == count, "sandbox sync sends nothing back")
end)()

-- ---------- the one reading of an order lookup ----------
;(function()
    local paid = { status = "paid", paid = true, durable = { status = "confirmed" } }
    check(E.orderOutcome({ ok = true, known = true, order = paid }) == "paid", "confirmed paid order")
    check(E.orderOutcome({ ok = true, known = true, order = { status = "paid", paid = true,
        durable = { status = "pending" } } }) == "processing", "paid but unsaved stays locked")
    check(E.orderOutcome({ ok = true, known = true, order = { status = "declined", paid = false, final = true,
        durable = { status = "confirmed" } } }) == "not_paid", "proven unpaid")
    check(E.orderOutcome({ ok = true, known = false, quoteState = "active",
        order = { durable = { status = "unknown" } } }) == "unknown", "known = false is never unpaid")
    check(E.orderOutcome({ ok = false, error = "timeout", unknown = true }) == "unknown", "timeout is unknown")
end)()

-- ---------- a new world forgets the old server ----------
;(function()
    for _, fn in ipairs(gameStart) do fn() end
    check(E.getState(SRC, PROD) == nil, "session reset drops the cache")
end)()

-- ---------- every still-valid quote retains the identity needed after a purchase timeout ----------
;(function()
    for i = 1, 33 do
        tick(650)
        local id = E.quote(SRC, "product_" .. i, "permanent", 1)
        reply("entitlement.quote", { ok = true, requestId = id,
            quote = { id = "active-quote-" .. i, orderId = "active-order-" .. i } })
    end
    local result
    E.purchase(SRC, "active-quote-1", function(r) result = r end)
    tick(10001)
    check(result and result.unknown == true and result.productId == "product_1"
        and result.orderId == "active-order-1", "33 valid quotes retain the first purchase's timeout identity")
end)()

-- ---------- equal quote ids from different sources keep separate purchase identities ----------
;(function()
    local sources = { "FirstConsumer", "SecondConsumer" }
    for i, source in ipairs(sources) do
        tick(700)
        local id = E.quote(source, PROD, "permanent", 1)
        reply("entitlement.quote", { ok = true, requestId = id,
            quote = { id = "shared-quote", orderId = "order-" .. i } })
    end
    local results = {}
    local first = E.purchase(sources[1], "shared-quote", function(r) results[1] = r end)
    local second = E.purchase(sources[2], "shared-quote", function(r) results[2] = r end)
    check(first ~= nil and second ~= nil, "equal quote ids from different sources do not share pending writes")
    tick(10001)
    tick(10001)
    check(results[1] and results[1].orderId == "order-1" and results[1].sourceMod == sources[1],
        "first source timeout retains its own quote identity")
    check(results[2] and results[2].orderId == "order-2" and results[2].sourceMod == sources[2],
        "second source timeout retains its own quote identity")
    reply("entitlement.order", { requestId = first, snapshot = envelope(90, 1) })
    check(E.getState(SRC, PROD) == nil, "another command cannot consume a late purchase identity")
    reply("entitlement.purchase", { requestId = first, snapshot = envelope(9, 1) })
    check(E.getState(SRC, PROD).entitlement.revision == 9, "correct command can still adopt the late purchase")
end)()

-- ---------- real admin page state machine, with rendering and engine controls replaced ----------
;(function()
    local classes = {}
    ISPanel = {
        derive = function(_, name)
            local class = {}
            class.__index = class
            classes[name] = class
            return class
        end,
    }
    package.loaded["ISUI/ISPanel"] = true
    C.UI = { PAD = 8, T = "IGUI_MinidoracatEconomy_", CARD_TITLE_H = 28,
        fontH = { small = 16, medium = 20 }, amountText = tostring, currencyName = C.currencyName }
    dofile(MEDIA .. "/client/MinidoracatEconomy/ECAdminEntitlements.lua")
    local Page = classes.MinidoracatEconomyAdminEntPage

    local function noop() end
    local function control()
        return {
            setEnabled = function(self, enabled) self.enabled = enabled end,
            setTitle = noop, setStyle = noop,
            setText = function(self, value) self.value = value end,
            getText = function(self) return self.value or "" end,
        }
    end
    local function planEntry(revision, price, applies)
        return { sourceMod = SRC, productId = PROD, applies = applies or {},
            plan = { revision = revision, permanentEnabled = true, permanentCurrency = "survivor",
                permanentPrice = price, permanentLimit = 10, rentalEnabled = false, rentalCurrency = "survivor",
                rentalPrice = 250, rentalQuantity = 1, rentalDays = 7, graceHours = 24, reminderHours = 24,
                autoRenewAllowed = true } }
    end
    local function page()
        local ioState = { sent = {}, pending = false, write = true }
        local p = setmetatable({
            owner = { readAllowed = function() return true end, writeAllowed = function() return ioState.write end },
            drafts = {}, pendingApplies = {}, plans = { planEntry(1, 1000) }, section = "plans", view = "list",
            selKey = SRC .. "\1" .. PROD, form = { scrollOffset = 0 }, fieldControls = {},
            chips = { permanentCurrency = { survivor = control() }, rentalCurrency = { survivor = control() } },
            tabs = {}, layout = noop, syncControls = noop, unfocusAll = noop, invalidateKeyboard = noop,
            rebuildPlanRows = noop, rebuildAccountRows = noop,
            isPending = function() return ioState.pending end,
            newRequestId = function() return "admin-" .. (#ioState.sent + 1) end,
            send = function(command, args)
                ioState.sent[#ioState.sent + 1] = { command = command, args = args }
                ioState.pending = true
                return true
            end,
        }, Page)
        for _, name in ipairs({ "reviewButton", "discardButton", "recheckButton", "reasonField", "confirmButton",
            "backButton", "accountField", "lookupButton", "refundButton" }) do p[name] = control() end
        for _, name in ipairs({ "permanentEnabled", "permanentPrice", "permanentLimit", "rentalEnabled",
            "rentalPrice", "rentalQuantity", "rentalDays", "graceHours", "reminderHours", "autoRenewAllowed" }) do
            p.fieldControls[name] = control()
        end
        return p, ioState
    end
    local function apply(p)
        p:setDraftValue("permanentPrice", "1200")
        p:onReview()
        p.reasonField:setText("Update plan")
        p:onConfirm()
        return p.sent
    end
    local function timeout(p, ioState)
        ioState.pending = false
        p:onTimeout()
    end
    local function receive(p, ioState, args)
        if p:matchesReply(args) then ioState.pending = false end
        p:onReply(args)
    end

    local p, ioState = page()
    p:updateEnabled()
    check(p.fieldControls.permanentPrice.enabled and p.fieldControls.permanentEnabled.enabled
        and p.chips.permanentCurrency.survivor.enabled and p.chips.rentalCurrency.survivor.enabled,
        "typed fields and both currency chip groups enable without phantom currency entries")
    ioState.write = false
    p:updateEnabled()
    check(not p.fieldControls.permanentPrice.enabled and not p.chips.permanentCurrency.survivor.enabled,
        "permission loss disables both typed fields and currency chips")

    p, ioState = page()
    local req = apply(p)
    receive(p, ioState, { ok = true, plans = { planEntry(2, 1200) } })
    check(not req.answered and ioState.pending and p:draft() ~= nil and p.plans[1].plan.revision == 1,
        "reply without requestId cannot release or complete an admin write")
    timeout(p, ioState)
    local count = #ioState.sent
    p:onReview()
    p:onConfirm()
    check(p.view == "list" and #ioState.sent == count and p.pendingApplies[p.selKey] == req,
        "unknown apply retains its context and cannot be reviewed or confirmed again")
    p:onDiscard()
    p:setDraftValue("permanentPrice", "1300")
    local replacement = p:draft()
    p:onReview()
    check(p.view == "list" and p:reviewBlockKey() == "Ent_Draft_Unknown",
        "discarding and recreating a draft cannot erase an unknown apply")
    receive(p, ioState, { ok = true, requestId = req.requestId, plans = { planEntry(2, 1200) } })
    check(p:draft() == replacement and replacement.values.permanentPrice == "1300",
        "late apply success cannot delete a replacement draft")

    p, ioState = page()
    req = apply(p)
    timeout(p, ioState)
    local edited = p:draft()
    p:setDraftValue("permanentPrice", "1400")
    receive(p, ioState, { ok = true, requestId = req.requestId, plans = { planEntry(2, 1200) } })
    check(p:draft() == edited and edited.values.permanentPrice == "1400",
        "late success cannot delete edits made to the original draft after timeout")

    p, ioState = page()
    req = apply(p)
    timeout(p, ioState)
    p:onRecheck()
    check(ioState.sent[#ioState.sent].args.action == "plans" and p.pendingApplies[p.selKey] == req
        and p:draft().unknown, "Re-check reads the server without clearing unknown from cached plans")
    local readId = p.sent.requestId
    receive(p, ioState, { ok = true, requestId = req.requestId, plans = { planEntry(99, 9999) } })
    check(ioState.pending and p.sent.requestId == readId and p.plans[1].plan.revision == 1,
        "late write reply cannot consume the new read slot or replace its snapshot")
    receive(p, ioState, { ok = true, requestId = readId, plans = { planEntry(2, 1500) } })
    check(p.pendingApplies[p.selKey] == req and p:draft().unknown and p:draft().revision == 1,
        "another revision without the original apply receipt cannot resolve unknown")
    p:onRecheck()
    receive(p, ioState, { ok = true, requestId = p.sent.requestId,
        plans = { planEntry(2, 1200, { { requestId = req.requestId, revision = 2 } }) } })
    check(p.pendingApplies[p.selKey] == nil and not p:draft().unknown and p:draft().revision == 2
        and #p:draft().changed == 0, "fresh matching apply receipt reconciles against server-authoritative plan")

    p, ioState = page()
    req = apply(p)
    timeout(p, ioState)
    p:onRecheck()
    receive(p, ioState, { ok = true, requestId = p.sent.requestId, plans = { planEntry(1, 1000) } })
    check(p.pendingApplies[p.selKey] == nil and p:reviewBlockKey() == nil,
        "fresh unchanged revision and explicit empty apply history proves the write was not applied")

    p, ioState = page()
    req = apply(p)
    local draft = p:draft()
    ioState.pending, ioState.write = false, false
    p:onCancelled(req.requestId)
    check(req.answered and not req.timedOut and p.pendingApplies[p.selKey] == nil and p:draft() == draft
        and not draft.unknown and p.view == "list", "cancelled unsent write retains draft without inventing unknown outcome")
end)()

print(string.format("test_entitlement_client: %d checks, %d failed", checks, failures))
if failures > 0 then os.exit(1) end
