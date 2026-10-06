--[[
Client entitlement transport (ECEntitlementClient.lua) against fake PZ globals, loading the real
MOD file. Standard Lua 5.x, run from the repo root:

    lua scripts/test_entitlement_client.lua

What it pins is what a consumer mod (VehicleManager) relies on: one request in flight per
command and the server's 500 ms window respected, every caller's callback kept, stale replies
never overwriting a newer snapshot, a timeout reported as unknown without a re-send (keeping the
quote / order identity), a late answer updating the cache without a second callback, public
refresh signals, the one shared reading of an order lookup (instant products included), rental
ids checked locally and carried on quote / auto-renew, an error code never reaching the screen,
and the admin integration page: order content / status / auto-renew reason / rental line /
refund dialog / settings file problem wording, the order list's pages and player filter, and a
refund sent once with its reason.
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
function getText(key, ...)
    local out = key
    for i = 1, select("#", ...) do out = out .. "|" .. tostring(select(i, ...)) end
    return out
end
-- keys this client "has": a value is formatted like getText (arguments appended)
local known = { ["IGUI_MinidoracatEconomy_Ent_State_active"] = "Active" }
function getTextOrNull(key, ...)
    if known[key] == nil then return nil end
    return getText(known[key], ...)
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
    id, why = E.quote(SRC, PROD, "rental", 1, function() end, "")
    check(id == nil and why == "invalid_args", "empty rental id refused locally")
    id, why = E.quote(SRC, PROD, "rental", 1, function() end, 42)
    check(id == nil and why == "invalid_args", "non-string rental id refused locally")
    id, why = E.quote(SRC, PROD, "rental", 1, function() end, "bad\1id")
    check(id == nil and why == "invalid_args", "rental id with a control character refused locally")
    id, why = E.quote(SRC, PROD, "permanent", 1, function() end, "r-1")
    check(id == nil and why == "invalid_args", "a permanent quote cannot name a rental")
    id, why = E.setAutoRenew(SRC, PROD, true, 1, 1, function() end)
    check(id == nil and why == "invalid_args", "auto-renew without a rental refused locally")
    id, why = E.setAutoRenew(SRC, PROD, true, 1, 1, function() end, string.rep("x", 97))
    check(id == nil and why == "invalid_args", "over-long rental id refused locally")
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

-- ---------- the one reading of an order lookup ----------
;(function()
    local paid = { status = "paid", paid = true, durable = { status = "confirmed" } }
    check(E.orderOutcome({ ok = true, known = true, order = paid }) == "paid", "confirmed paid order")
    check(E.orderOutcome({ ok = true, known = true, order = { status = "paid", paid = true,
        durable = { status = "pending" } } }) == "processing", "paid but unsaved stays locked")
    check(E.orderOutcome({ ok = true, known = true, instant = true, order = { status = "paid", paid = true,
        durable = { status = "pending" } } }) == "paid", "an instant paid order is paid without a save")
    check(E.orderOutcome({ ok = true, known = true, instant = true, order = { status = "refunded", paid = true } })
        == "refunded", "an instant refund is refunded without a save")
    check(E.orderOutcome({ ok = true, known = true, instant = true, order = { status = "declined", paid = false,
        final = true } }) == "not_paid", "instant does not turn a proven unpaid order into paid")
    check(E.orderOutcome({ ok = true, known = true, order = { status = "paid", paid = true, instant = true,
        durable = { status = "pending" } } }) == "processing", "only the reply's instant flag skips the save wait")
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

-- ---------- rental ids reach the wire; one consent write per product ----------
;(function()
    tick(10001)
    tick(700)
    E.quote(SRC, PROD, "rental", 2, nil)
    local newRental = sent[#sent]
    check(newRental.command == "entitlement.quote" and newRental.args.kind == "rental"
        and newRental.args.quantity == 2 and newRental.args.rental == nil, "a new rental quote names no rental")
    reply("entitlement.quote", { ok = false, error = "limit_reached", requestId = newRental.args.requestId })
    tick(700)
    E.quote(SRC, PROD, "rental", nil, nil, "1:42")
    local renew = sent[#sent]
    check(renew.args.rental == "1:42" and renew.args.quantity == nil and renew.args.requestId ~= newRental.args.requestId,
        "a renewal quote carries its rental id")
    reply("entitlement.quote", { ok = false, error = "rental_unknown", requestId = renew.args.requestId })
    local results = {}
    local id = E.setAutoRenew(SRC, PROD, true, 9, 1, function(r) results[#results + 1] = r end, "1:42")
    local consent = sent[#sent]
    check(consent.command == "entitlement.autoRenew" and consent.args.rental == "1:42"
        and consent.args.expectedRevision == 9 and consent.args.termsRevision == 1 and consent.args.requestId == id,
        "auto-renew consent carries its rental id")
    local again, why = E.setAutoRenew(SRC, PROD, false, 9, 1, function() end, "1:43")
    check(again == nil and why == "pending", "a second rental's consent waits for the product's open write")
    tick(10001)
    check(#results == 1 and results[1].unknown == true and results[1].rental == "1:42",
        "a consent timeout keeps its rental id")
end)()

-- ---------- an error code never reaches the screen ----------
;(function()
    known["IGUI_MinidoracatEconomy_Ent_Error_limit_reached"] = "LIMIT"
    check(E.errorText("limit_reached") == "LIMIT", "a known error code reads as its sentence")
    check(E.errorText("made_up_code") == "IGUI_MinidoracatEconomy_Ent_Error_unknown",
        "an error code without a sentence is shown as the unknown-error sentence, not as the code")
    known["IGUI_MinidoracatEconomy_Ent_Error_limit_reached"] = nil
end)()

-- ---------- an entitlement value the files do not know is not shown raw ----------
;(function()
    check(E.stateText("active") == "Active", "a known entitlement state reads as its word")
    check(E.stateText("made_up_state") == "IGUI_MinidoracatEconomy_Common_Unknown"
        and E.autoRenewText("weird") == "IGUI_MinidoracatEconomy_Common_Unknown",
        "an entitlement state or auto-renew value without a translation reads as the unknown word, not its code")
end)()

-- ---------- the admin integration page, with rendering and engine controls replaced ----------
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
    package.loaded["MinidoracatEconomy/ECRowActions"] = true
    package.loaded["MinidoracatEconomy/ECDetailWindow"] = true
    local details = {}
    C.DetailWindow = {
        open = function(owner, key, title, value) details[#details + 1] = { owner = owner, key = key, title = title, value = value } end,
        update = function() return false end,
        close = function(owner) details.closedBy = owner end,
    }
    local rowTargets = {}
    C.RowActions = { targets = function() return rowTargets end }
    local dialogs = {}
    local function noop() end
    C.UI = { PAD = 8, T = "IGUI_MinidoracatEconomy_", CARD_TITLE_H = 28, STAMP_SAMPLE = "0000-00-00 00:00",
        fontH = { small = 16, medium = 20 }, amountText = tostring, currencyName = C.currencyName,
        stampText = function(ms) return "t" .. tostring(ms) end, wrapText = function(s) return { s } end,
        textWidth = function(s) return #tostring(s) end, fitText = function(s) return s end,
        text = noop, textRight = noop, card = noop, theme = {},
        framework = { Dialog = {
            show = function(opts) dialogs[#dialogs + 1] = opts; return { n = #dialogs } end,
            close = noop } } }
    MinidoracatEconomy.sortSafe = function(list, lt) table.sort(list, lt) end
    dofile(MEDIA .. "/client/MinidoracatEconomy/ECAdminEntitlements.lua")
    local A = C.AdminEntitlements
    local Page = classes.MinidoracatEconomyAdminEntPage
    local T = "IGUI_MinidoracatEconomy_"
    local function has(s, part) return type(s) == "string" and string.find(s, part, 1, true) ~= nil end
    -- the order status words this client has (an unknown status is the unknown word, tested above)
    known[T .. "Ent_OrderStatus_paid"], known[T .. "Ent_OrderStatus_refunded"] = "paid", "refunded"

    -- what an order bought, and its status
    check(A.contentText({ kind = "permanent", quantity = 2 }) == T .. "Ent_Content_Permanent|2",
        "a bought-outright order names its slots")
    check(A.contentText({ kind = "rental", quantity = 1, rentalNo = 2 }) == T .. "Ent_Content_New|2|1",
        "a new rental names its place and slots")
    check(A.contentText({ kind = "rental", quantity = 2, rentalNo = 1, renewal = true }) == T .. "Ent_Content_Renewal|1|2",
        "a renewal is a renewal")
    check(A.contentText({ kind = "rental", quantity = 2, rentalNo = 1, renewal = true, auto = true })
        == T .. "Ent_Content_Auto|1|2", "a scheduler renewal is an auto-renewal, not a plain renewal")
    check(A.contentText({ kind = "rental", quantity = 1 }) == T .. "Ent_Content_NewGone|1",
        "a rental the account no longer holds is named as removed")
    local pending = { status = "paid", durable = { status = "pending" } }
    check(A.statusText(pending, true) == "paid", "an instant product never shows a save state")
    check(A.statusText(pending, false) == T .. "Ent_StatusUnsaved|paid", "a product that waits for the save says so")
    check(A.statusText({ status = "paid", durable = { status = "confirmed" } }, false) == "paid",
        "a saved order shows only its status")
    check(A.statusText({ status = "refunded", durable = { status = "confirmed" }, refund = { durable = { status = "pending" } } }, false)
        == T .. "Ent_StatusUnsaved|refunded"
        and A.statusText({ status = "refunded", durable = { status = "pending" }, refund = { durable = { status = "confirmed" } } }, false)
        == "refunded"
        and A.statusText({ status = "refunded", durable = { status = "confirmed" }, refund = { durable = { status = "pending" } } }, true)
        == "refunded",
        "a refund shows its own save state, not the payment's; an instant product shows none")

    -- the one real reason a rental's auto-renew is paused
    local plan = { rentalEnabled = true, autoRenewAllowed = true, rentalPrice = 250, rentalCurrency = "survivor",
        rentalDays = 7, rentalLimit = 5 }
    local agreed = { price = 250, currency = "survivor", days = 7 }
    local function tag(state, p, ent, terms)
        local s, token = A.autoTag({ autoRenewState = state, autoTerms = terms or agreed }, p, ent or { rentalCommitted = 2 })
        return s, token
    end
    check(tag("on", plan) == T .. "Ent_AutoTag_on" and select(2, tag("on", plan)) == "textMuted", "auto-renew on")
    check(tag("off", plan) == T .. "Ent_AutoTag_off", "auto-renew off")
    check(tag("paused_system", plan) == T .. "Ent_AutoTag_system" and select(2, tag("paused_system", plan)) == "warn",
        "held by the server")
    check(tag("paused_terms", plan, { rentalCommitted = 9 }, { price = 200, currency = "survivor", days = 7 })
        == T .. "Ent_AutoTag_terms", "agreed terms that differ from the plan come first, even over the limit")
    check(tag("paused_terms", plan, { rentalCommitted = 6 }) == T .. "Ent_AutoTag_limit", "over the rental limit")
    local stopped = { rentalEnabled = false, autoRenewAllowed = true, rentalPrice = 250, rentalCurrency = "survivor",
        rentalDays = 7, rentalLimit = 5 }
    check(tag("paused_terms", stopped) == T .. "Ent_AutoTag_stopped", "the plan stopped renting")
    local disallowed = { rentalEnabled = true, autoRenewAllowed = false, rentalPrice = 250, rentalCurrency = "survivor",
        rentalDays = 7, rentalLimit = 5 }
    check(tag("paused_terms", disallowed) == T .. "Ent_AutoTag_disallowed", "the plan does not allow auto-renew")
    check(tag("paused_terms", nil) == T .. "Ent_AutoTag_paused", "no plan to compare: a plain pause, no invented reason")

    -- rental lines: what is left in days, or hours below a day
    local now = 1000000000
    local line = A.rentalLine(1, { quantity = 2, state = "active", paidUntil = now + 7 * 86400000 + 3 * 3600000 }, now, 0)
    check(line == T .. "Ent_RentalLine_active|1|2|t" .. tostring(now + 7 * 86400000 + 3 * 3600000) .. "|" .. T .. "Ent_Days|7",
        "an active rental shows its end and whole days left")
    check(has(A.rentalLine(1, { quantity = 2, state = "paused_terms", paidUntil = now + 5 * 3600000 }, now, 0),
        T .. "Ent_Hours|5"), "under a day left is shown in hours")
    check(A.rentalLine(2, { quantity = 1, state = "grace", paidUntil = now - 10, graceUntil = now + 900 }, now, 0)
        == T .. "Ent_RentalLine_grace|2|1|t" .. tostring(now + 900), "a rental in grace shows the grace end")
    check(A.rentalLine(3, { quantity = 1, state = "expired" }, now, 0) == T .. "Ent_RentalLine_expired|3|1", "expired")
    check(A.rentalLine(4, { quantity = 1, state = "pending" }, now, 0) == T .. "Ent_RentalLine_pending|4|1",
        "a new rental waiting for the save")

    -- the settings file problem a source reports, in its own words or Economy's
    known["IGUI_MVM_Paid_FileErr_invalid_plan"] = "VMDETAIL"
    known["IGUI_MVM_Paid_Name_rentalLimit"] = "RentLimit"
    check(A.problemText({ key = "IGUI_MVM_Paid_FileErr_invalid_plan", field = "IGUI_MVM_Paid_Name_rentalLimit",
        ref = "rent.limit" }) == T .. "Ent_FileProblem|VMDETAIL|RentLimit|rent.limit",
        "the source's sentence gets the field's name and the file key")
    check(A.problemText({ key = "IGUI_MVM_Paid_FileErr_invalid_plan", field = "IGUI_Missing_Field", ref = "rent.limit" })
        == T .. "Ent_FileProblem|VMDETAIL|rent.limit|rent.limit", "a field without a name falls back to the file key")
    known["IGUI_MVM_Paid_FileErr_invalid_plan"], known["IGUI_MVM_Paid_Name_rentalLimit"] = nil, nil
    local fallback = A.problemText({ key = "IGUI_MVM_Paid_FileErr_invalid_plan", ref = "rent.limit" })
    check(fallback == T .. "Ent_FileProblem|" .. T .. "Ent_FileProblemGeneric|rent.limit" and not has(fallback, "FileErr"),
        "without the source's translations: Economy's own sentence with the file key, never the code")
    check(A.problemText({ key = "IGUI_MVM_Paid_FileErr_other" }) == T .. "Ent_FileProblem|" .. T .. "Ent_FileProblemPlain",
        "no file key to show: the plain sentence")
    check(A.problemText(nil) == nil, "no problem, no sentence")

    -- the refund dialog says what goes back to whom and what happens to the slots
    local function lines(o) return table.concat(A.refundLines(o, "bob", "CONTENT", 0), "\n") end
    local permanent = lines({ kind = "permanent", quantity = 2, amount = 2000, currency = "survivor", at = 7,
        refundEffect = "units" })
    check(has(permanent, T .. "Ent_RefundLine|2000 cur:survivor|bob") and has(permanent, T .. "Ent_Pair|CONTENT|t7")
        and has(permanent, T .. "Ent_Effect_units|2") and not has(permanent, "Ent_EffectAutoOff")
        and has(permanent, T .. "Ent_NoUndo"), "a bought-outright refund takes the slots back and cannot be undone")
    local previous = lines({ kind = "rental", quantity = 1, amount = 250, currency = "survivor", at = 7, rentalNo = 2,
        refundEffect = "previous", previousUntil = 99 })
    check(has(previous, T .. "Ent_Effect_previous|2|t99") and has(previous, T .. "Ent_EffectAutoOff"),
        "a rental's latest period goes back to the previous one and its auto-renew closes")
    check(has(lines({ kind = "rental", rentalNo = 2, refundEffect = "remove" }), T .. "Ent_Effect_remove|2"), "a rental is removed")
    check(has(lines({ kind = "rental", refundEffect = "cancel" }), T .. "Ent_Effect_cancel"), "a waiting new rental is cancelled")
    local money = lines({ kind = "rental", refundEffect = "money" })
    check(has(money, T .. "Ent_Effect_money") and not has(money, "Ent_EffectAutoOff"),
        "a removed rental's refund is money only, with no auto-renew to close")

    -- source names: the registered key, else the display name, else the mod id
    known["IGUI_MVM_SourceName"] = "Vehicle Manager"
    check(A.sourceName({ sourceNameKey = "IGUI_MVM_SourceName", sourceMod = SRC }) == "Vehicle Manager", "the source's own key")
    check(A.sourceName({ sourceNameKey = "IGUI_Not_Here", sourceName = { EN = "VM", CH = "VMCH" }, sourceMod = SRC }) == "VM",
        "a key this client lacks falls back to the display name")
    check(A.sourceName({ modId = "SomeMod" }) == "SomeMod", "nothing else: the mod id")

    local function control()
        return { setEnabled = function(self, on) self.enabled = on end, setText = function(self, v) self.value = v end,
            getText = function(self) return self.value or "" end, getIsVisible = function(self) return self.visible ~= false end,
            isFocused = function() return false end, _entry = {} }
    end
    local function list()
        local l = control()
        l.width, l.height, l.rowHeight, l.items = 600, 200, 30, {}
        l.refundLabel = "REFUND"
        l.setItems = function(self, items) self.items = items end
        l.getSelectedItem = function() return nil end
        l.setSelectedIndex = noop
        l.resize = noop
        return l
    end
    local function page()
        local io = { sent = {}, pending = false, write = true }
        local p = setmetatable({
            owner = { readAllowed = function() return true end, writeAllowed = function() return io.write end, offsetMin = 0 },
            section = "accounts", tabs = control(), planList = list(), orderList = list(), accountField = control(),
            lookupButton = control(), allButton = control(), moreButton = control(), idsToggle = control(), productChips = {},
            rentalsButton = (function() local b = control(); b.visible = false; return b end)(),
            layout = noop, invalidateKeyboard = noop, getIsVisible = function() return true end,
            isPending = function() return io.pending end,
            newRequestId = function() return "admin-" .. (#io.sent + 1) end,
            send = function(command, args)
                io.sent[#io.sent + 1] = { command = command, args = args }
                io.pending = true
                return true
            end,
        }, Page)
        return p, io
    end
    local function receive(p, io, args)
        if p:matchesReply(args) then io.pending = false end
        p:onReply(args)
    end
    local function row(id, at, user, extra)
        local r = { username = user or "bob", sourceMod = SRC, productId = PROD, orderId = id, at = at, kind = "permanent",
            quantity = 1, amount = 500, currency = "survivor", status = "paid", instant = true, refundable = true,
            refundEffect = "units" }
        for k, v in pairs(extra or {}) do r[k] = v end
        return r
    end

    -- every account's orders, a page at a time; the cursor is the last row's time and id
    local p, io = page()
    p.ordersWanted = true
    p:tick(0)
    check(io.sent[1] and io.sent[1].args.action == "orders" and io.sent[1].args.before == nil,
        "no filter: the page reads every account's orders from the top")
    receive(p, io, { ok = true, requestId = io.sent[1].args.requestId, more = true,
        orders = { row("1:3", 300), row("1:2", 200, "amy") } })
    check(#p.orders.rows == 2 and p.orders.more == true and #p.orderList.items == 2, "the first page is shown")
    check(p.orderRows[1].cells[2] == "bob" and #p.orderRows[1].cells == 5, "every account's list has a player column")
    p:onMore()
    local before = io.sent[2] and io.sent[2].args.before
    check(before and before.at == 200 and before.id == "1:2", "show earlier asks after the last row shown")
    receive(p, io, { ok = true, requestId = io.sent[2].args.requestId, more = false,
        orders = { row("1:2", 200, "amy"), row("1:1", 100) } })
    check(#p.orders.rows == 3 and p.orders.rows[3].orderId == "1:1" and p.orders.more == false,
        "the next page is appended once, a repeated row is not doubled")
    p:onMore()
    check(#io.sent == 2, "nothing earlier left: show earlier sends nothing")
    receive(p, io, { ok = true, requestId = "someone-else", orders = {} })
    check(#p.orders.rows == 3, "a reply to another request changes nothing")

    -- a row filters the page to that player and product
    p:onOrderRow(p.orderList.items[2])
    local acc = io.sent[3] and io.sent[3].args
    check(p.accountUser == "amy" and acc and acc.action == "account" and acc.username == "amy"
        and p.accountField.value == "amy", "a row's player becomes the filter")
    receive(p, io, { ok = true, requestId = acc.requestId, entries = {
        { sourceMod = SRC, productId = "other_slot", orders = {} },
        { sourceMod = SRC, productId = PROD, instant = false, plan = plan, entitlement = { usable = 1, rentals = {} },
            orders = { row("1:4", 50, nil, { username = nil, durable = { status = "pending" } }),
                row("1:5", 60, nil, { username = nil, durable = { status = "confirmed" }, refundable = false }) } } } })
    check(p.entrySel == 2, "the filtered account opens on the product of the row that was picked")
    check(#p.orderRows == 2 and p.orderRows[1].order.orderId == "1:5" and #p.orderRows[1].cells == 4,
        "the account's orders: newest first, no player column")
    check(p.orderRows[2].cells[4] == T .. "Ent_StatusUnsaved|paid" and p.orderRows[1].refundable == false,
        "a product that waits for the save shows it; a row the server will not refund has no refund")
    p:onAll()
    check(p.accountUser == nil and io.sent[4] and io.sent[4].args.action == "orders" and io.sent[4].args.before == nil,
        "all: back to every account, read again from the top")
    receive(p, io, { ok = true, requestId = io.sent[4].args.requestId, orders = { row("1:3", 300),
        row("1:9", 90, "amy", { productId = "other_slot", instant = false, durable = { status = "pending" } }) } })
    check(p.orderRows[1].cells[5] == "paid" and p.orderRows[2].cells[5] == T .. "Ent_StatusUnsaved|paid",
        "an instant product's row never shows a save state; a waiting product's does")
    check(has(p.orderRows[1].cells[3], T .. "Ent_Pair|") and has(p.orderRows[1].cells[3], "Ent_Content_Permanent|1"),
        "two products in one list: the content names its product")

    -- the keyboard walks every control the accounts section shows, the row's own button included
    rowTargets = { "refund-button" }
    p.allButton.visible = false
    local ring = p:keyboardTargets()
    check(#ring == 7 and ring[1].control == p.tabs and ring[2].control == p.accountField._entry
        and ring[3].control == p.lookupButton and ring[4].control == p.orderList and ring[5].controls == rowTargets
        and ring[6].control == p.moreButton and ring[7].control == p.idsToggle,
        "accounts: tabs, account box, look up, the list, the row's refund, show earlier, show IDs")
    p.rentalsButton.visible = true
    ring = p:keyboardTargets()
    check(#ring == 8 and ring[4].control == p.rentalsButton, "the all-rentals button is on the keyboard ring when it is shown")
    p.rentalsButton.visible = false

    -- rentals the page has no room for open in the shared detail window, every one in full
    local many = {}
    for i = 1, 10 do
        many[i] = { id = "r" .. i, quantity = 1, state = "expired", autoRenewState = i == 10 and "paused_system" or "off" }
    end
    local zoeEntry = { sourceMod = SRC, productId = PROD, plan = plan, entitlement = { rentals = many, rentalCommitted = 1 } }
    local listing = A.rentalsText(zoeEntry, now, 0)
    local lineCount = select(2, string.gsub(listing, "\n", "")) + 1
    check(lineCount == 10 and has(listing, T .. "Ent_RentalLine_expired|10|1") and has(listing, T .. "Ent_AutoTag_system")
        and has(listing, T .. "Ent_AutoTag_off"), "the full rental list has every rental, each with its auto-renew label")
    local p2 = page()
    p2.accountUser, p2.account, p2.entrySel = "zoe", { username = "zoe", entries = { zoeEntry } }, 1
    p2.entryKey = SRC .. "\1" .. PROD
    p2:onAllRentals()
    local opened = details[#details]
    check(opened ~= nil and opened.owner == p2 and opened.value == A.rentalsText(zoeEntry, MinidoracatEconomy.now(), 0)
        and has(opened.title, "zoe"), "the all-rentals button opens the shared detail window on that account's rentals")
    p2:onAll()
    check(details.closedBy == p2, "leaving the account closes its rental list")
    p.section = "plans"
    ring = p:keyboardTargets()
    check(#ring == 2 and ring[2].control == p.planList, "plans: the tabs and the product list only")
    p.section = "accounts"

    -- a refund: the dialog, a required reason, one send
    io.pending = false
    local target = p.orderRows[1]
    p:openRefund(target)
    local d = dialogs[#dialogs]
    check(#dialogs == 1 and d.danger == true and d.input ~= nil and d.confirmText == T .. "Ent_RefundConfirm|500 cur:survivor"
        and has(d.text, T .. "Ent_RefundLine|500 cur:survivor|bob") and has(d.text, T .. "Ent_Reason"),
        "the refund dialog names the amount and the account and asks for a reason")
    local count = #io.sent
    d.onResult(true, "   ")
    check(#io.sent == count and #dialogs == 2 and string.sub(dialogs[2].text, 1, #(T .. "Ent_ReasonMissing"))
        == T .. "Ent_ReasonMissing", "a blank reason sends nothing and asks again, saying why first")
    dialogs[2].onResult(true, "Player misclick")
    local sentRefund = io.sent[count + 1] and io.sent[count + 1].args
    check(#io.sent == count + 1 and sentRefund.action == "refund" and sentRefund.username == "bob"
        and sentRefund.orderId == "1:3" and sentRefund.productId == PROD and sentRefund.reason == "Player misclick",
        "the confirmed refund is sent once, for that order, with its reason")
    d.onResult(true, "again")
    check(#io.sent == count + 1, "a refund in flight is never sent a second time")
    io.pending = false
    p:onTimeout()
    check(#io.sent == count + 1 and p.message.text == T .. "Ent_RefundTimeout", "a refund timeout re-sends nothing")
    p:openRefund({ refundable = false, order = row("1:8", 1) })
    check(#dialogs == 2, "a row the server will not refund opens nothing")
    io.write = false
    p:openRefund(target)
    check(#dialogs == 2 and p.message.text == T .. "Ent_ReadOnly", "a read-only admin gets no refund dialog")
    io.write = true
    p:openRefund(target)
    dialogs[#dialogs].onResult(true, "Second try")
    local last = io.sent[#io.sent].args
    receive(p, io, { ok = true, requestId = last.requestId })
    check(p.ordersWanted == true and p.message.text == T .. "Ent_RefundDone|500 cur:survivor|bob",
        "an answered refund says what went back and reads the list again")

    -- the plan footer: when, where from, the admin only for an in-game change, why, and the file
    known[T .. "Ent_Origin_admin"], known[T .. "Ent_Origin_file"] = "INGAME", "FILE"
    local foot = p:planFooter({ lastChange = { at = 5, origin = "file", actor = "file", reason = "r1" },
        source = { file = "Lua/x/paid-slots.json" } })
    check(#foot == 2 and foot[1] == T .. "Ent_Pair|" .. T .. "Ent_Pair|" .. T .. "Ent_FootChanged|t5|FILE|" .. T .. "Ent_FootReason|r1"
        and foot[2] == T .. "Ent_FootFile|Lua/x/paid-slots.json", "a file change names no actor")
    foot = p:planFooter({ lastChange = { at = 5, origin = "admin", actor = "alice" } })
    check(#foot == 1 and has(foot[1], "INGAME|alice"), "an in-game change names the admin")
    foot = p:planFooter({ lastChange = { at = 5, origin = "mystery", actor = "x" } })
    check(has(foot[1], T .. "Ent_Origin_other") and not has(foot[1], "mystery"), "an unknown origin is not shown raw")

    -- the identity page words the companion export's refusal from its code and facts
    package.loaded["MinidoracatEconomy/ECDetailWindow"] = true
    -- (the detail window stub from above stays in place)
    C.UI.unknownText = function(_, code) return T .. "Common_Unknown" end
    C.UI.adminErrorText = function(code) return "ERR:" .. tostring(code) end
    dofile(MEDIA .. "/client/MinidoracatEconomy/ECAdminIdentity.lua")
    local Ident = C.AdminIdentity
    for _, k in ipairs({ "rows", "bad_row", "open", "reserved" }) do
        known[T .. "Admin_Id_ExportDetail_" .. k] = T .. "Admin_Id_ExportDetail_" .. k
    end
    check(Ident.exportDetailText({ code = "rows", rows = 8, count = 9 }) == T .. "Admin_Id_ExportDetail_rows|8|9"
        and Ident.exportDetailText({ code = "bad_row", line = 3, field = "u" }) == T .. "Admin_Id_ExportDetail_bad_row|3|u"
        and Ident.exportDetailText({ code = "reserved", skipped = 2, dropped = 1 }) == T .. "Admin_Id_ExportDetail_reserved|2|1"
        and Ident.exportDetailText({ code = "open" }) == T .. "Admin_Id_ExportDetail_open",
        "an export refusal is worded from its code, with the line, field and row counts as data")
    check(Ident.exportDetailText({ code = "import_failed", error = "write_failed" })
        == T .. "Admin_Id_ExportDetail_import_failed|ERR:write_failed"
        and Ident.exportDetailText({ code = "never_heard_of" }) == T .. "Common_Unknown"
        and Ident.exportDetailText("no trailer after 3 rows") == nil and Ident.exportDetailText(nil) == nil,
        "an import failure names its error in words; an unknown code is the unknown word; a sentence is never echoed")
end)()

-- ---------- another mod's "put these up for sale" (v1.Client.openAdminShop, rev 4) ----------
;(function()
    local classes = {}
    ISPanel = { derive = function(_, name)
        local class = {}
        class.__index = class
        classes[name] = class
        return class
    end }
    for _, m in ipairs({ "ISUI/ISPanel", "ISUI/ISScrollBar", "ISUI/ISComboBox", "MinidoracatEconomy/ECWidgets",
        "MinidoracatEconomy/ECItemPicker", "MinidoracatEconomy/ECDetailWindow" }) do package.loaded[m] = true end
    local T = "IGUI_MinidoracatEconomy_"
    C.UI = { T = T, fontH = { small = 16, medium = 20 }, itemName = function(t) return "name:" .. t end }
    local universe = { byType = { ["Watch.A"] = { fullType = "Watch.A" }, ["Watch.B"] = { fullType = "Watch.B" },
        ["Watch.C"] = { fullType = "Watch.C" }, ["Base.Battery"] = { fullType = "Base.Battery" } } }
    C.ItemPicker = { universe = function() return universe end }
    MinidoracatEconomy.CURRENCY_ORDER = { "survivor" }
    local admin = false
    C.AdminPanel = { canWrite = function() return admin end }
    dofile(MEDIA .. "/client/MinidoracatEconomy/ECAdminShop.lua")
    local S, Page = C.AdminShop, classes.MinidoracatEconomyAdminShopPage

    local types, err = S.wanted("MinidoracatWatch", { "Watch.A" })
    check(types == nil and err == "forbidden", "a player without the admin write right is refused before any window")
    admin = true
    local many = {}
    for i = 1, S.WANTED_MAX + 1 do many[i] = "Watch.X" .. i end
    check(select(2, S.wanted("Bad Mod", {})) == "invalid_args" and select(2, S.wanted("M", "Watch.A")) == "invalid_args"
        and select(2, S.wanted("M", many)) == "invalid_args" and select(2, S.wanted(nil, {})) == "invalid_args",
        "a malformed mod id, a non-table list and more than 64 entries are refused")
    types = S.wanted("MinidoracatWatch", { "Watch.A", 7, "Watch.A", "Base.Battery", "Watch.B", "No.Such", "Watch.C" })
    check(#types == 5 and types[1] == "Watch.A" and types[2] == "Base.Battery" and types[3] == "Watch.B"
        and types[4] == "No.Such" and types[5] == "Watch.C", "repeats and non-strings are dropped, the order is kept")

    -- the page: a catalog that already sells the battery
    local opened = {}
    local p = setmetatable({ owner = {}, catalog = nil, picked = {}, pickedCount = 0, form = {} }, Page)
    p.layout, p.fillEntries, p.unfocusFields = function() end, function() end, function() end
    p.addRefusal = function() return nil end
    p.startNew = function(self, rec) self.draft = { isNew = true, item = rec.fullType }; opened[#opened + 1] = rec.fullType end
    p:queueItems("MinidoracatWatch", types)
    check(#opened == 0 and p.incoming ~= nil, "before the first catalog read the list waits")
    local catalog = { ok = true, revision = "r1", items = { { id = "battery", item = "Base.Battery" } } }
    p:onReply("catalog", catalog)
    check(#opened == 1 and opened[1] == "Watch.A" and p.incoming == nil
        and p.owner.message.text == T .. "Admin_Shop_QueueSummary|MinidoracatWatch|3|1",
        "the catalog read opens the first draft; the summary counts three drafts and one already in the shop")
    check(p:queueText() == T .. "Admin_Shop_QueueNote|MinidoracatWatch|2 " .. T .. "Admin_Shop_QueueListed|name:Base.Battery",
        "the draft's note says how many follow and names the item already sold")
    p.saveRequestId = "s1"
    p:onReply("catalog", { ok = true, requestId = "s1", id = "a", revision = "r2",
        items = { { id = "battery", item = "Base.Battery" }, { id = "a", item = "Watch.A" } } }, { action = "add" })
    check(#opened == 2 and opened[2] == "Watch.B", "a saved draft opens the next")
    p:onCancelEdit()
    check(#opened == 3 and opened[3] == "Watch.C" and p:queueText() == T .. "Admin_Shop_QueueLast|MinidoracatWatch "
        .. T .. "Admin_Shop_QueueListed|name:Base.Battery", "Cancel puts a draft aside and opens the next; the last one says so")
    p:onCancelEdit()
    check(#opened == 3 and p.draft == nil and p.queue == nil, "Cancel on the last draft ends the list")
    p:queueItems("MinidoracatWatch", { "Base.Battery", "Watch.A" })
    check(#opened == 3 and p.queue == nil and p.owner.message.text == T .. "Admin_Shop_QueueSummary|MinidoracatWatch|0|2",
        "a list the shop already sells opens nothing and says so")
    p:queueItems("MinidoracatWatch", { "Watch.B", "Watch.C" })
    p:startEdit("battery")
    p.saveRequestId = "s2"
    p:onReply("catalog", { ok = true, requestId = "s2", id = "battery", revision = "r3", items = catalog.items }, { action = "set" })
    check(#opened == 4 and p.queue == nil and p.draft.id == "battery", "opening a saved row ends the list")
end)()

print(string.format("test_entitlement_client: %d checks, %d failed", checks, failures))
if failures > 0 then os.exit(1) end
