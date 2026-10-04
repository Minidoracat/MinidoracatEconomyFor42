--[[
Generic entitlements (API rev 2) - behaviour scenarios, run by scripts/smoke_harness.lua after every
other scenario. The harness passes its fake PZ globals, clock and `check`; this file loads nothing of
its own. Every check counts toward the harness EXPECTED_ASSERTIONS (+87 here).

Native boundaries faked here (and only these): getSandboxOptions / getServerName (the sandbox object
the engine hands the server), and the companion's durable.json marker. Money, ModData, journal file
and commands all go through the real modules.
]]

local ctx = ...
local check, fire, fakePlayer, lastSent = ctx.check, ctx.fire, ctx.fakePlayer, ctx.lastSent
local EC = MinidoracatEconomy
local S, L, G, E, P = EC.Server, EC.Ledger, EC.Integration, EC.Entitlements, EC.EntitlementPlans
local V = EC.v1
local DAY, HOUR = 86400000, 3600000

local function advance(ms) ctx.setNow(ctx.now() + ms) end

io.write("scenario E1: generic entitlements (API rev 2)\n")

-- ---------- fake sandbox options (SandboxOptions.set / toLua / saveServerLuaFile) ----------
local registered, javaValues = {}, {}
local saveResult, saves = true, 0
local function split(name) return string.match(name, "^([^%.]+)%.(.+)$") end
local function vanillaSet(name, v)          -- what the vanilla packet handler leaves behind: Java value + SandboxVars
    javaValues[name] = v
    local page, key = split(name)
    SandboxVars[page] = SandboxVars[page] or {}
    SandboxVars[page][key] = v
end
local fakeOptions = {
    getOptionByName = function(_, name) return registered[name] and { name = name } or nil end,
    set = function(_, name, v)
        if not registered[name] or v == nil then error("IllegalArgumentException: " .. tostring(name)) end
        javaValues[name] = v
    end,
    toLua = function()
        for name, v in pairs(javaValues) do
            local page, key = split(name)
            SandboxVars[page] = SandboxVars[page] or {}
            SandboxVars[page][key] = v
        end
    end,
    saveServerLuaFile = function(_, server)
        saves = saves + 1
        if saveResult == "throw" then error("java.io.IOException") end
        return saveResult
    end,
}
getSandboxOptions = function() return fakeOptions end
getServerName = function() return "servertest" end

local MAP = { permanentEnabled = "TestVM.PermEnabled", permanentCurrency = "TestVM.PermCurrency",
    permanentPrice = "TestVM.PermPrice", permanentLimit = "TestVM.PermLimit", rentalEnabled = "TestVM.RentEnabled",
    rentalCurrency = "TestVM.RentCurrency", rentalPrice = "TestVM.RentPrice", rentalLimit = "TestVM.RentLimit",
    rentalDays = "TestVM.RentDays", graceHours = "TestVM.Grace", reminderHours = "TestVM.Reminder",
    autoRenewAllowed = "TestVM.AutoAllowed", revision = "TestVM.PlanRevision" }
local DEFAULTS = { permanentEnabled = true, permanentCurrency = "survivor", permanentPrice = 1000, permanentLimit = 3,
    rentalEnabled = true, rentalCurrency = "survivor", rentalPrice = 250, rentalLimit = 3, rentalDays = 7,
    graceHours = 24, reminderHours = 24, autoRenewAllowed = true }
local function defaults(over)
    local t = {}
    for k, v in pairs(DEFAULTS) do t[k] = v end
    for k, v in pairs(over or {}) do t[k] = v end
    return t
end
for field, name in pairs(MAP) do
    registered[name] = true
    vanillaSet(name, field == "revision" and 0 or DEFAULTS[field])
end

-- ---------- helpers ----------
local function marker(seq)
    local m = S.modData().meta
    ctx.files()[S.DURABLE_FILE] = { lines = { EC.jsonEncode({ realmId = m.realmId, epoch = m.epoch, seq = seq, ts = ctx.now() }) } }
    return S.pollDurable(true)
end
local function confirmAll()                  -- the companion proves this epoch's save up to now
    marker(S.modData().meta.seq)
    advance(1000)
    fire("OnTickEvenPaused")
end
local function cmd(who, name, args)
    advance(600)
    args.requestId = args.requestId or (name .. tostring(ctx.now()))
    fire("OnClientCommand", EC.COMMAND_MODULE, name, who, args)
    local r = lastSent(name)
    return r and r.args or {}
end
local function state() return EC.jsonEncode({ S.modData().entitlements.rows, L.getBalance("ann", "survivor"),
    L.getBalance("MOD:TestVM", "survivor") }) end
local SLOT = { sourceMod = "TestVM", productId = "vehicle_slot" }
local function with(extra)
    local t = { sourceMod = SLOT.sourceMod, productId = SLOT.productId }
    for k, v in pairs(extra) do t[k] = v end
    return t
end
local function planRowIn(list)
    for _, p in ipairs(list or {}) do
        if p.sourceMod == "TestVM" and p.productId == "vehicle_slot" then return p end
    end
    return nil
end
local function planValues(over)
    local t = {}
    for k, v in pairs(P.row("TestVM", "vehicle_slot").values) do t[k] = v end
    for k, v in pairs(over or {}) do t[k] = v end
    return t
end
local function rent1(e) return (e and e.rentals and e.rentals[1]) or {} end   -- the first rental (view or row)

-- ---------- a fresh world, two sources with the same product id ----------
ctx.store()[EC.MODDATA_KEY] = nil
ctx.clearFiles()
ctx.clearSent()
advance(61000)
fire("OnServerStarted")

check(V.API_REVISION >= 2 and V.CAPABILITIES.entitlements == true and V.CAPABILITIES.subscriptions == true
    and V.CAPABILITIES.rentals == true and V.CAPABILITIES.post == true,
    "the facade is at least rev 2 with entitlements and independent rentals; the rev 1 capabilities are unchanged")

local REASONS = { "entitlement_purchase", "entitlement_renewal", "entitlement_refund" }
local vm = V.registerSource({ modId = "TestVM", currencies = { "survivor", "cat" }, reasonCodes = REASONS })
local safe = V.registerSource({ modId = "TestSafe", currencies = { "survivor" }, reasonCodes = REASONS })
local bare = V.registerSource({ modId = "TestBare", currencies = { "survivor" }, reasonCodes = { "other" } })
check(bare.registerProduct({ id = "slot", nameKey = "K", defaults = defaults() }).field == "reasonCodes.entitlement_purchase",
    "a source that did not declare the entitlement reason codes cannot register a product")
local noRevision = {}
for k, v in pairs(MAP) do if k ~= "revision" then noRevision[k] = v end end
check(vm.registerProduct({ id = "slot", nameKey = "K", defaults = defaults(), sandbox = noRevision }).field == "sandbox.revision"
    and vm.registerProduct({ id = "Bad-Id", nameKey = "K", defaults = defaults() }).field == "id"
    and vm.registerProduct({ id = "slot", nameKey = "K", defaults = defaults({ permanentPrice = 0 }) }).field == "defaults.permanentPrice"
    and vm.registerProduct({ id = "slot", nameKey = "K", defaults = defaults({ permanentCurrency = "gold" }) }).ok == false,
    "registration refuses a mirror without a revision option, bad ids and invalid defaults")

local gate = { calls = 0 }
local function validate(username, productId, kind, qty, projected)
    gate.calls = gate.calls + 1
    if gate.reenter then
        local f = gate.reenter
        gate.reenter = nil
        f()
    end
    if gate.throw then error("consumer boom") end
    if gate.refuse then return false, gate.refuse end
    return true
end
local reg = vm.registerProduct({ id = "vehicle_slot", nameKey = "IGUI_Test_Slot", defaults = defaults(), sandbox = MAP,
    validatePurchase = validate })
local reg2 = safe.registerProduct({ id = "vehicle_slot", nameKey = "IGUI_Test_Safe", defaults = defaults({ permanentLimit = 5 }) })
check(reg.ok and reg2.ok and P.row("TestVM", "vehicle_slot").revision == 1 and SandboxVars.TestVM.PlanRevision == 1 and saves >= 1,
    "the first plan comes from the sandbox as revision 1, and that revision is written back and saved")

local ann, bob, boss = fakePlayer("ann"), fakePlayer("bob"), fakePlayer("boss")
boss.role = "admin"
ctx.setOnline({ ann, bob, boss })
L.credit("ann", "survivor", 5000, "SYSTEM_MINT", { requestId = "ent-seed-ann", reasonCode = "t" })
L.credit("bob", "survivor", 300, "SYSTEM_MINT", { requestId = "ent-seed-bob", reasonCode = "t" })
local consumerSaw = {}
vm.onEntitlementChanged(function(username, productId, snap) consumerSaw[#consumerSaw + 1] = snap end)

local st = vm.getEntitlement("ann", "vehicle_slot")
check(st.ok and st.entitlement.usable == 0 and st.entitlement.state == "none" and #st.entitlement.rentals == 0
    and st.entitlement.rentalsMax == E.RENTALS_MAX and st.plan.revision == 1 and st.balances.survivor.available == 5000
    and st.available == true,
    "a fresh account reads as none with no rentals")
check(E.peek("TestVM", "carl", "vehicle_slot") == nil and vm.getEntitlement("carl", "vehicle_slot").ok == true
    and E.peek("TestVM", "carl", "vehicle_slot") == nil and vm.getEntitlement("ann", "nope").error == "unknown_product",
    "reading creates no row, and an unknown product is refused")
local unknownSource = cmd(ann, "entitlement.state", { sourceMod = "Nobody", productId = "vehicle_slot", requestId = "rq-1" })
check(unknownSource.ok == false and unknownSource.error == "unknown_source" and unknownSource.requestId == "rq-1",
    "an unknown source is refused and the refusal echoes the requestId")

-- ---------- permanent: quote, atomic purchase, duplicate, isolation ----------
local q1 = cmd(ann, "entitlement.quote", with({ kind = "permanent", quantity = 1 }))
check(q1.ok and q1.quote.orderId == q1.quote.id and q1.quote.amount == 1000 and q1.quote.termsRevision == 1
    and q1.quote.ttlMs == 120000 and L.getBalance("ann", "survivor").available == 5000,
    "a quote fixes the order id and the price and moves nothing")
local seenAtCommit = nil
L.onCommitted(function(ev)
    if seenAtCommit == false and ev.payload and ev.payload.sourceMod == "TestVM" then
        local row = E.peek("TestVM", "ann", "vehicle_slot")
        seenAtCommit = row ~= nil and row.perm == 1 and L.getBalance("ann", "survivor").available == 4000
    end
end)
seenAtCommit = false
local p1 = cmd(ann, "entitlement.purchase", { sourceMod = "TestVM", quoteId = q1.quote.id })
local ent1 = p1.snapshot and p1.snapshot.entitlement or {}
check(p1.ok and p1.orderId == q1.quote.orderId and p1.duplicate == false and seenAtCommit == true,
    "money and entitlement switch in one commit: the ledger listener already sees both")
check(L.getBalance("ann", "survivor").available == 4000 and L.getBalance("MOD:TestVM", "survivor").available == 1000
    and ent1.usable == 0 and ent1.permanent == 0 and ent1.pendingQuantity == 1 and ent1.state == "pending"
    and ent1.durable.status == "pending" and ent1.wait.code == "await_restart",
    "a paid unit is pending and not usable until a save is proven")
local lastSnap = consumerSaw[#consumerSaw]
local push = lastSent("entitlement.changed")
check(lastSnap ~= nil and lastSnap.entitlement.pendingQuantity == 1 and push ~= nil and push.player == ann
    and push.args.entitlement.pendingQuantity == 1,
    "the consumer listener and the owner's push come after the commit")
local p1b = cmd(ann, "entitlement.purchase", { sourceMod = "TestVM", quoteId = q1.quote.id })
check(p1b.ok and p1b.duplicate == true and p1b.orderId == p1.orderId and L.getBalance("ann", "survivor").available == 4000,
    "resending the same quote answers the same order and charges nothing")
local q2 = cmd(ann, "entitlement.quote", with({ kind = "permanent", quantity = 1 }))
local stolen = cmd(bob, "entitlement.purchase", { sourceMod = "TestVM", quoteId = q2.quote.id })
check(stolen.ok == false and stolen.error == "quote_unknown" and L.getBalance("bob", "survivor").available == 300
    and L.getBalance("ann", "survivor").available == 4000,
    "another player's quote is unknown to them and moves nobody's money")
check(safe.getEntitlement("ann", "vehicle_slot").entitlement.pendingQuantity == 0
    and cmd(ann, "entitlement.purchase", { sourceMod = "TestSafe", quoteId = q2.quote.id }).error == "quote_unknown",
    "a second source with the same product id sees nothing of the first and cannot settle its quotes")

-- ---------- durability: only the companion watermark or a loaded save make it usable ----------
local _, paidSeq = EC.parseId(p1.txId)
marker(paidSeq - 1)
advance(1000)
fire("OnTickEvenPaused")
check(vm.getEntitlement("ann", "vehicle_slot").entitlement.usable == 0, "a watermark below the payment proves nothing")
marker(paidSeq)
advance(1000)
fire("OnTickEvenPaused")
local e2 = vm.getEntitlement("ann", "vehicle_slot").entitlement
check(e2.usable == 1 and e2.permanent == 1 and e2.pendingQuantity == 0 and e2.durable.status == "confirmed"
    and E.peek("TestVM", "ann", "vehicle_slot").pp == nil,
    "the companion watermark over the payment makes the unit usable")

-- ---------- refusals leave nothing behind ----------
local before = state()
local lim = cmd(ann, "entitlement.quote", with({ kind = "permanent", quantity = 3 }))
check(lim.ok == false and lim.error == "limit_reached" and state() == before,
    "the permanent limit counts held units and refuses with no side effect")
S.modData().frozen.ann = { admin = "boss" }
local frozen = cmd(ann, "entitlement.purchase", { sourceMod = "TestVM", quoteId = q2.quote.id })
S.modData().frozen.ann = nil
check(frozen.ok == false and frozen.error == "account_frozen" and state() == before,
    "a frozen account cannot buy and nothing changes")
local currencies = S.modData().config.currencies
currencies.survivor = currencies.survivor or {}
currencies.survivor.enabled = false
local disabled = cmd(ann, "entitlement.purchase", { sourceMod = "TestVM", quoteId = q2.quote.id })
currencies.survivor.enabled = nil
check(disabled.ok == false and disabled.error == "currency_disabled" and state() == before,
    "paying in a disabled currency is refused with no side effect")
local poor = cmd(bob, "entitlement.quote", with({ kind = "permanent", quantity = 1 }))
check(poor.ok == false and poor.error == "insufficient_funds" and E.peek("TestVM", "bob", "vehicle_slot") == nil,
    "an account that cannot pay gets no quote and no row")
G.setSource("TestVM", { enabled = false }, "boss", "entitlement test")
local off = cmd(ann, "entitlement.purchase", { sourceMod = "TestVM", quoteId = q2.quote.id })
local offRead = vm.getEntitlement("ann", "vehicle_slot")
G.setSource("TestVM", { enabled = true }, "boss", "entitlement test")
check(off.ok == false and off.error == "source_disabled" and offRead.ok and offRead.entitlement.usable == 1 and offRead.available == false,
    "a disabled source refuses purchases but still reads the confirmed units")
gate.refuse = "CONFIG_BLOCKED"
local refused = cmd(ann, "entitlement.purchase", { sourceMod = "TestVM", quoteId = q2.quote.id })
gate.refuse, gate.throw = nil, true
local thrown = cmd(ann, "entitlement.purchase", { sourceMod = "TestVM", quoteId = q2.quote.id })
gate.throw = nil
check(refused.error == "CONFIG_BLOCKED" and thrown.error == "validation_failed" and state() == before,
    "the consumer's refusal code comes back as is and a throwing gate fails closed")
gate.reenter = function() gate.inner = vm.purchase("ann", q2.quote.id) end
local outer = vm.purchase("ann", q2.quote.id)
check(gate.inner ~= nil and gate.inner.ok == true and outer.ok == false and outer.error == "quote_unknown"
    and L.getBalance("ann", "survivor").available == 3000,
    "a gate that re-enters the purchase cannot make one quote pay twice")

-- ---------- order lookups: proven unpaid only when this process can prove it ----------
local q3 = cmd(ann, "entitlement.quote", with({ kind = "permanent", quantity = 1 }))
advance(121000)
local expired = cmd(ann, "entitlement.purchase", { sourceMod = "TestVM", quoteId = q3.quote.id })
local o3 = cmd(ann, "entitlement.order", with({ orderId = q3.quote.id }))
check(expired.ok == false and expired.error == "quote_expired" and o3.known == true and o3.order.status == "unsubmitted"
    and o3.order.paid == false and o3.order.final == true,
    "an expired quote cannot pay and its order is proven unsubmitted")
local q4 = cmd(ann, "entitlement.quote", with({ kind = "permanent", quantity = 1 }))
gate.refuse = "NOT_READY"
cmd(ann, "entitlement.purchase", { sourceMod = "TestVM", quoteId = q4.quote.id })
gate.refuse = nil
advance(121000)
fire("OnTickEvenPaused")
local o4 = vm.getOrder("ann", "vehicle_slot", q4.quote.id)
local op = vm.getOrder("ann", "vehicle_slot", p1.orderId)
check(o4.known == true and o4.order.status == "declined" and o4.order.error == "NOT_READY" and op.known == true
    and op.order.status == "paid" and op.order.paid == true and op.order.durable.status == "confirmed",
    "a refused quote is proven declined; a paid order is known with its durability")
local q5 = vm.quote("ann", "vehicle_slot", "permanent", 1)
local o5 = vm.getOrder("ann", "vehicle_slot", q5.quote.id)
check(o5.known == false and o5.quoteState == "active" and o5.order.durable.status == "unknown",
    "a live quote is unknown, never a refusal")

-- ---------- restarts ----------
advance(1000)
fire("OnServerStarted")
check(vm.getEntitlement("ann", "vehicle_slot").entitlement.usable == 2,
    "a payment the loaded save contains is usable after a restart without any companion")
local saved = proofSnapshot()
local q6 = vm.quote("ann", "vehicle_slot", "permanent", 1)
local p6 = vm.purchase("ann", q6.quote.id)
local paidBalance = L.getBalance("ann", "survivor").available
proofRestartFrom(saved)
local o6 = vm.getOrder("ann", "vehicle_slot", q6.quote.id)
check(p6.ok and paidBalance == 2000 and L.getBalance("ann", "survivor").available == 3000
    and vm.getEntitlement("ann", "vehicle_slot").entitlement.usable == 2 and o6.known == false
    and o6.order.durable.status == "unknown",
    "a crash takes unsaved money and units back together, but a missing order has no ownership proof")
check(vm.getOrder("bob", "vehicle_slot", q6.quote.id).known == false
    and safe.getOrder("ann", "vehicle_slot", q6.quote.id).known == false
    and vm.getOrder("ann", "vehicle_slot", string.match(q6.quote.id, "^(.*):") .. ":999999999").known == false,
    "old global sequence numbers prove neither another row's order nor an unissued order")

-- ---------- rental: activation only after the save, journaled, replayed after crashes ----------
local r1q = cmd(ann, "entitlement.quote", with({ kind = "rental" }))
local r1 = cmd(ann, "entitlement.purchase", { sourceMod = "TestVM", quoteId = r1q.quote.id })
local re1 = r1.snapshot and r1.snapshot.entitlement or {}
check(r1.ok and rent1(re1).state == "pending" and re1.rental == 0 and re1.pendingQuantity == 1
    and rent1(re1).paidUntil == nil and rent1(re1).id == r1.orderId and re1.rentalCommitted == 1,
    "a paid rental waits for the save: no period starts before it is proven")
local savedPaid = proofSnapshot()             -- the world save holds the payment, not the activation
advance(HOUR)                                 -- an hour waiting for the save is not eaten
confirmAll()
local activatedAt = ctx.now()
local ra = vm.getEntitlement("ann", "vehicle_slot").entitlement
local journalLines = ctx.files()[E.JOURNAL_FILE]
check(rent1(ra).state == "active" and ra.rental == 1 and ra.usable == 3 and rent1(ra).paidUntil == activatedAt + 7 * DAY
    and rent1(ra).graceUntil == rent1(ra).paidUntil + DAY and journalLines ~= nil and #journalLines.lines == 1,
    "the period starts at activation after the save, and the activation is journaled first")
local paidUntil1 = rent1(ra).paidUntil
advance(5 * HOUR)
proofRestartFrom(savedPaid)
local rr1 = vm.getEntitlement("ann", "vehicle_slot").entitlement
advance(HOUR)
proofRestartFrom(savedPaid)
fire("OnTickEvenPaused")
local rr2 = vm.getEntitlement("ann", "vehicle_slot").entitlement
check(rent1(rr1).paidUntil == paidUntil1 and rent1(rr2).paidUntil == paidUntil1 and rent1(rr2).state == "active",
    "crashes before the activation is saved replay the journaled time: the period is never extended")
confirmAll()
check(#ctx.files()[E.JOURNAL_FILE].lines == 0 and E.journalStatus().state == "ok",
    "once the activation itself is proven saved the journal is emptied as a whole")

local bq = cmd(bob, "entitlement.quote", with({ kind = "rental" }))
local bp = cmd(bob, "entitlement.purchase", { sourceMod = "TestVM", quoteId = bq.quote.id })
ctx.writerDeny()[E.JOURNAL_FILE] = true
confirmAll()
local bs = vm.getEntitlement("bob", "vehicle_slot").entitlement
local as = vm.getEntitlement("ann", "vehicle_slot").entitlement
check(bp.ok and rent1(bs).state == "paused_system" and bs.rental == 0 and rent1(bs).paidUntil == nil
    and bs.wait.code == "journal_blocked" and as.usable == 3 and E.journalStatus().state == "write_failed",
    "a journal that cannot be written pauses activation instead of starting a period, and confirmed units stay usable")
check(vm.quote("ann", "vehicle_slot", "rental").error == "journal_unavailable",
    "no rental is sold while activation is paused")
ctx.writerDeny()[E.JOURNAL_FILE] = nil
advance(61000)
fire("OnTickEvenPaused")
local bh = vm.getEntitlement("bob", "vehicle_slot").entitlement
check(rent1(bh).state == "active" and rent1(bh).paidUntil == ctx.now() + 7 * DAY and E.journalStatus().state == "ok",
    "after the journal recovers the period starts then, never earlier")

-- ---------- auto-renew: consent, durable consent, one charge per cycle ----------
local st0 = vm.getEntitlement("ann", "vehicle_slot")
local staleConsent = cmd(ann, "entitlement.autoRenew", with({ enabled = true, expectedRevision = st0.entitlement.revision,
    termsRevision = st0.plan.revision - 1, rental = r1.orderId }))
local consent = cmd(ann, "entitlement.autoRenew", with({ enabled = true, expectedRevision = st0.entitlement.revision,
    termsRevision = st0.plan.revision, rental = r1.orderId }))
check(staleConsent.error == "stale_terms" and consent.ok
    and rent1(consent.snapshot and consent.snapshot.entitlement).autoRenewState == "pending_on",
    "consent names the current terms and stays pending until it is saved")
local ann0 = L.getBalance("ann", "survivor").available
local lease0 = rent1(E.peek("TestVM", "ann", "vehicle_slot")).lease
ctx.setNow(lease0.paidUntil + 1000)
fire("OnTickEvenPaused")
check(L.getBalance("ann", "survivor").available == ann0 and rent1(vm.getEntitlement("ann", "vehicle_slot").entitlement).state == "grace",
    "an unsaved consent never charges; the lease enters grace")
confirmAll()
local afterCharge = L.getBalance("ann", "survivor").available
local rs = vm.getEntitlement("ann", "vehicle_slot").entitlement
check(afterCharge == ann0 - 250 and rent1(rs).autoRenewState == "on" and rent1(rs).state == "grace"
    and rent1(rs).pendingOrderId ~= nil,
    "a saved consent charges one period when due; the extension waits for its own save")
check(vm.quote("ann", "vehicle_slot", "rental", nil, r1.orderId).error == "lease_pending"
    and L.getBalance("ann", "survivor").available == afterCharge,
    "manual and automatic renewal of the same cycle cannot both charge")
confirmAll()
local rn = vm.getEntitlement("ann", "vehicle_slot").entitlement
check(rent1(rn).paidUntil == lease0.paidUntil + 7 * DAY and rent1(rn).state == "active" and rn.notice.code == "renewed",
    "a renewal inside grace continues the old period instead of restarting it")

local annB = L.getBalance("ann", "survivor").available
ctx.setNow(rent1(rn).paidUntil + 3 * 7 * DAY)
fire("OnServerStarted")                       -- the server was down for three periods
fire("OnTickEvenPaused")
local charged = annB - L.getBalance("ann", "survivor").available
advance(1000)
fire("OnTickEvenPaused")
local chargedTwice = annB - L.getBalance("ann", "survivor").available
confirmAll()
local dn = vm.getEntitlement("ann", "vehicle_slot").entitlement
check(charged == 250 and chargedTwice == 250 and rent1(dn).paidUntil == ctx.now() + 7 * DAY and rent1(dn).state == "active",
    "after downtime one period is charged, no arrears, and it starts at activation")

local cs = vm.getEntitlement("ann", "vehicle_slot")
local savedOn = proofSnapshot()               -- a save that still has auto-renew on
local cancel = cmd(ann, "entitlement.autoRenew", with({ enabled = false, expectedRevision = cs.entitlement.revision,
    termsRevision = cs.plan.revision, rental = r1.orderId }))
check(cancel.ok and rent1(cancel.snapshot and cancel.snapshot.entitlement).autoRenewState == "pending_off",
    "a cancel stops at once and shows pending until it is saved")
proofRestartFrom(savedOn)                     -- the cancel never reached a save
local replayed = vm.getEntitlement("ann", "vehicle_slot").entitlement
ctx.setNow(rent1(replayed).paidUntil + 1000)
local annC = L.getBalance("ann", "survivor").available
fire("OnTickEvenPaused")
check(rent1(replayed).autoRenew == false and L.getBalance("ann", "survivor").available == annC,
    "a crash cannot revive a cancelled consent: the journaled cancel is replayed and nothing is charged")
local s1 = vm.getEntitlement("ann", "vehicle_slot")
local oldRev = s1.entitlement.revision
vm.setAutoRenew("ann", "vehicle_slot", true, oldRev, s1.plan.revision, r1.orderId)
local staleCancel = vm.setAutoRenew("ann", "vehicle_slot", false, oldRev - 1, s1.plan.revision, r1.orderId)
check(staleCancel.error == "stale_revision" and rent1(vm.getEntitlement("ann", "vehicle_slot").entitlement).autoRenew == true,
    "a cancel naming a revision older than the current consent cannot switch it off")

-- ---------- admin plans: apply, idempotency, conflicts, sandbox mirror ----------
local plans = cmd(boss, "admin.entitlements", { action = "plans" })
local row = planRowIn(plans.plans)
local qOld = vm.quote("ann", "vehicle_slot", "permanent", 1)
local applyArgs = { action = "apply", sourceMod = "TestVM", productId = "vehicle_slot", expectedRevision = row.plan.revision,
    values = planValues({ rentalPrice = 300 }), reason = "raise rent", requestId = "apply-1" }
local ap = cmd(boss, "admin.entitlements", applyArgs)
check(ap.ok and ap.updated and ap.revision == row.plan.revision + 1 and SandboxVars.TestVM.RentPrice == 300
    and SandboxVars.TestVM.PlanRevision == ap.revision and ap.sandbox.ok == true,
    "an admin apply raises the revision and mirrors it into the saved sandbox")
check(rent1(vm.getEntitlement("ann", "vehicle_slot").entitlement).autoRenewState == "paused_terms"
    and vm.purchase("ann", qOld.quote.id).error == "stale_terms",
    "a rent change pauses the consent given for the old rent and makes old quotes stale")
local ap2 = cmd(boss, "admin.entitlements", { action = "apply", sourceMod = "TestVM", productId = "vehicle_slot",
    expectedRevision = row.plan.revision, values = applyArgs.values, reason = "raise rent", requestId = "apply-1" })
local conflict = cmd(boss, "admin.entitlements", { action = "apply", sourceMod = "TestVM", productId = "vehicle_slot",
    expectedRevision = row.plan.revision, values = planValues({ rentalPrice = 301 }), reason = "raise rent", requestId = "apply-1" })
check(ap2.ok and ap2.duplicate == true and ap2.revision == ap.revision and P.row("TestVM", "vehicle_slot").revision == ap.revision
    and conflict.error == "request_conflict",
    "the same apply resent answers its first outcome; a different body under that id is a conflict")
local staleApply = cmd(boss, "admin.entitlements", { action = "apply", sourceMod = "TestVM", productId = "vehicle_slot",
    expectedRevision = row.plan.revision, values = planValues({ rentalPrice = 310 }), reason = "late", requestId = "apply-2" })
local joe = fakePlayer("joe")
local forbidden = cmd(joe, "admin.entitlements", { action = "apply", sourceMod = "TestVM", productId = "vehicle_slot",
    expectedRevision = ap.revision, values = planValues(), reason = "mine", requestId = "apply-3" })
check(staleApply.error == "stale_revision" and forbidden.error == "forbidden" and forbidden.requestId == "apply-3"
    and P.row("TestVM", "vehicle_slot").revision == ap.revision,
    "an apply against an older revision or without the write role changes nothing")
local extra = planValues()
extra.bogus = 1
local unknownField = cmd(boss, "admin.entitlements", { action = "apply", sourceMod = "TestVM", productId = "vehicle_slot",
    expectedRevision = ap.revision, values = extra, reason = "r", requestId = "apply-4" })
check(unknownField.error == "unknown_fields" and P.row("TestVM", "vehicle_slot").revision == ap.revision,
    "unknown plan fields are refused")
saveResult = false
local failedSave = cmd(boss, "admin.entitlements", { action = "apply", sourceMod = "TestVM", productId = "vehicle_slot",
    expectedRevision = ap.revision, values = planValues({ rentalPrice = 320 }), reason = "r", requestId = "apply-5" })
local failedRow = planRowIn(failedSave.plans) or { sandboxStatus = {} }
check(failedSave.ok and failedSave.sandbox.ok == false and failedSave.sandbox.error == "save_failed"
    and failedRow.sandboxStatus.state == "write_failed" and failedRow.sandboxStatus.dirty == true,
    "a sandbox save that fails is reported, never claimed as synced")
saveResult = true
advance(1000)
fire("OnTickEvenPaused")
local mirror = lastSent("entitlement.sandbox")
check(P.sandboxStatus("TestVM", "vehicle_slot").state == "synced" and mirror ~= nil
    and mirror.args.values["TestVM.RentPrice"] == 320,
    "the failed mirror is retried and clients hear it only after a successful save")
local r0 = P.row("TestVM", "vehicle_slot").revision
vanillaSet("TestVM.PermPrice", 1200)
advance(1000)
fire("OnTickEvenPaused")
local edited = P.row("TestVM", "vehicle_slot")
check(edited.revision == r0 + 1 and edited.values.permanentPrice == 1200 and SandboxVars.TestVM.PlanRevision == r0 + 1
    and edited.lastChange.origin == "sandbox",
    "a vanilla sandbox edit at the synced revision becomes the next revision")
vanillaSet("TestVM.PlanRevision", r0)
vanillaSet("TestVM.PermPrice", 1000)
advance(1000)
fire("OnTickEvenPaused")
check(P.row("TestVM", "vehicle_slot").values.permanentPrice == 1200 and SandboxVars.TestVM.PermPrice == 1200
    and SandboxVars.TestVM.PlanRevision == r0 + 1 and P.sandboxStatus("TestVM", "vehicle_slot").conflict ~= nil,
    "a stale whole-table copy is a conflict: the plan is written back, never imported")
local savedPlan = proofSnapshot()
local cur = P.row("TestVM", "vehicle_slot")
local ap3 = cmd(boss, "admin.entitlements", { action = "apply", sourceMod = "TestVM", productId = "vehicle_slot",
    expectedRevision = cur.revision, values = planValues({ permanentPrice = 1500 }), reason = "r", requestId = "apply-6" })
proofRestartFrom(savedPlan)
check(ap3.ok and P.row("TestVM", "vehicle_slot").values.permanentPrice == 1500 and P.row("TestVM", "vehicle_slot").revision == ap3.revision,
    "an applied change the world save lost comes back from the newer sandbox revision")

-- ---------- refunds ----------
local annR = L.getBalance("ann", "survivor").available
local refundArgs = { action = "refund", username = "ann", sourceMod = "TestVM", productId = "vehicle_slot",
    orderId = p1.orderId, reason = "customer request" }
local rf = cmd(boss, "admin.entitlements", refundArgs)
local rf2 = cmd(boss, "admin.entitlements", { action = "refund", username = "ann", sourceMod = "TestVM",
    productId = "vehicle_slot", orderId = p1.orderId, reason = "customer request" })
check(rf.ok and rf2.ok and rf2.duplicate == true and L.getBalance("ann", "survivor").available == annR + 1000
    and E.peek("TestVM", "ann", "vehicle_slot").perm == 1,
    "an admin refund reverses the original order once and takes its unit back in the same commit")
local today = nil
for _, s in ipairs(G.sources()) do if s.modId == "TestVM" then today = s.today end end
check(today ~= nil and today.refund == 1000 and today.mint == 0 and S.modData().config.sources.TestVM.dailyMintCap == 0,
    "a refund needs no mint headroom and is counted apart from mint")
local notLatest = vm.refund("ann", "vehicle_slot", r1.orderId, { reason = "old period" })
check(notLatest.ok == false and notLatest.error == "refund_not_latest",
    "a rental period that a later one depends on cannot be refunded")
local lastOrder = rent1(E.peek("TestVM", "ann", "vehicle_slot")).lease.last
local latest = vm.refund("ann", "vehicle_slot", lastOrder, { reason = "latest period" })
local afterRefund = rent1(E.peek("TestVM", "ann", "vehicle_slot"))
check(latest.ok and afterRefund.auto.on == false and afterRefund.lease.last ~= lastOrder,
    "refunding the latest period restores the previous lease and switches auto-renew off in the same commit")

-- ---------- long life, privacy, admin view, budget, LRU ----------
for _ = 1, 21 do
    advance(1000)
    fire("OnServerStarted")
end
check(vm.getEntitlement("ann", "vehicle_slot").entitlement.permanent == 1 and #S.modData().meta.history == 20,
    "twenty-one restarts later the permanent unit is still usable: it carries no epoch stamp")
local spy = cmd(bob, "entitlement.order", with({ orderId = p1.orderId }))
check(spy.ok and spy.known == false and spy.snapshot.entitlement.permanent == 0,
    "another player's order is never found in one's own row")
local account = cmd(boss, "admin.entitlements", { action = "account", username = "ann" })
check(account.ok and #account.entries == 1 and account.entries[1].sourceMod == "TestVM" and account.perms.write == true,
    "the admin account view lists the player's entitlements per source")
local qb = vm.quote("ann", "vehicle_slot", "permanent", 1)
for _ = 1, G.CALLS_PER_TICK do G.takeCall("TestVM") end
local limited = vm.purchase("ann", qb.quote.id)
fire("OnTickEvenPaused")
local paid = vm.purchase("ann", qb.quote.id)
check(limited.error == "rate_limited" and paid.ok == true, "entitlement money shares the source's per-tick budget")
for i = 1, L.IDEMPOTENCY_MAX + 1 do
    L.credit("lru-filler", "survivor", 1, "SYSTEM_MINT", { requestId = "ent-lru-" .. i, reasonCode = "t" })
end
local annL = L.getBalance("ann", "survivor").available
local lruAgain = vm.purchase("ann", paid.orderId)
check(lruAgain.ok and lruAgain.duplicate == true and L.getBalance("ann", "survivor").available == annL,
    "after the ledger's idempotency window rotated, a resend is answered from the order ring and charges nothing")

-- ---------- review fixes (2026-09-27): one counterexample per finding ----------
-- Each finding in its own do-block: this chunk is close to Lua's 200 active locals.
local function renter(name, funds)             -- a confirmed active lease under a saved consent
    L.credit(name, "survivor", funds, "SYSTEM_MINT", { requestId = "ent-fix-" .. name, reasonCode = "t" })
    vm.purchase(name, vm.quote(name, "vehicle_slot", "rental").quote.id)
    confirmAll()                               -- the payment is saved: the period starts, journaled
    confirmAll()                               -- the activation is saved
    local s = vm.getEntitlement(name, "vehicle_slot")
    vm.setAutoRenew(name, "vehicle_slot", true, s.entitlement.revision, s.plan.revision, rent1(s.entitlement).id)
    confirmAll()                               -- the consent is saved
    return vm.getEntitlement(name, "vehicle_slot")
end
local function offLinesOf(name)
    local n = 0
    for _, line in ipairs((ctx.files()[E.JOURNAL_FILE] or { lines = {} }).lines) do
        local rec = EC.jsonDecode(line)
        if type(rec) == "table" and rec.k == "off" and rec.acct == name then n = n + 1 end
    end
    return n
end
local rentPrice = P.row("TestVM", "vehicle_slot").values.rentalPrice

-- 1. a cancel whose off line cannot be written is not done; the line is owed and written once it can
do
    local cf = renter("cf1", 2000)
    local savedOnCf = proofSnapshot()          -- a save with the consent still on
    ctx.writerDeny()[E.JOURNAL_FILE] = true
    local cfId = rent1(cf.entitlement).id
    local cfail = vm.setAutoRenew("cf1", "vehicle_slot", false, cf.entitlement.revision, cf.plan.revision, cfId)
    local cfailAgain = vm.setAutoRenew("cf1", "vehicle_slot", false, cf.entitlement.revision + 1, cf.plan.revision, cfId)
    local cfe = cfail.snapshot and cfail.snapshot.entitlement or {}
    check(cfail.ok == false and cfail.error == "journal_unavailable" and rent1(cfe).autoRenew == false
        and rent1(cfe).autoRenewState == "pending_off" and cfe.wait ~= nil and cfe.wait.code == "journal_blocked"
        and cfailAgain.error == "journal_unavailable" and cfailAgain.duplicate == nil,
        "a cancel whose off line cannot be written stops here but is not reported done, and resending it is no duplicate")
    ctx.writerDeny()[E.JOURNAL_FILE] = nil
    advance(61000)
    fire("OnTickEvenPaused")                   -- the journal works again: the owed line is written by itself
    local cfLines = offLinesOf("cf1")
    local cfResent = vm.setAutoRenew("cf1", "vehicle_slot", false, 0, cf.plan.revision, cfId)
    proofRestartFrom(savedOnCf)                -- the cancel never reached a save
    ctx.setNow(rent1(E.peek("TestVM", "cf1", "vehicle_slot")).lease.paidUntil + 1000)
    local cfBal = L.getBalance("cf1", "survivor").available
    fire("OnTickEvenPaused")
    check(cfLines == 1 and cfResent.ok and cfResent.duplicate == true and rent1(E.peek("TestVM", "cf1", "vehicle_slot")).auto.on == false
        and L.getBalance("cf1", "survivor").available == cfBal,
        "the owed off line lands once the journal works; a crash back to the consent replays it and charges nothing")
end

-- 9. emptying the journal: a writer that does not open keeps every line and says so, retried slowly
do
    L.credit("tj1", "survivor", rentPrice, "SYSTEM_MINT", { requestId = "ent-fix-tj1", reasonCode = "t" })
    vm.purchase("tj1", vm.quote("tj1", "vehicle_slot", "rental").quote.id)
    confirmAll()                               -- the activation is journaled
    ctx.writerDeny()[E.JOURNAL_FILE] = true
    confirmAll()                               -- the activation is saved: no line is needed any more
    local keptLines = #ctx.files()[E.JOURNAL_FILE].lines
    advance(1000)
    fire("OnTickEvenPaused")
    local jsDenied = E.journalStatus()
    ctx.writerDeny()[E.JOURNAL_FILE] = nil
    check(keptLines > 0 and jsDenied.state == "write_failed" and jsDenied.needSeq > 0
        and #ctx.files()[E.JOURNAL_FILE].lines == keptLines,
        "a journal that cannot be emptied keeps its lines and reports write_failed instead of claiming it is healthy")
    advance(61000)
    fire("OnTickEvenPaused")
    local jsBack = E.journalStatus()
    check(#ctx.files()[E.JOURNAL_FILE].lines == 0 and jsBack.state == "ok" and jsBack.needSeq == 0,
        "once it can be written the journal is emptied, and only an empty read-back clears what it needed")
end

-- 1b. an off line that landed but could not be read back is kept, never emptied as unneeded
do
    local c2 = renter("cf2", 2000)
    local realReader, failReads = getFileReader, 1
    getFileReader = function(path, create)
        if path == E.JOURNAL_FILE and failReads > 0 then
            failReads = failReads - 1
            error("java.io.IOException: read back")
        end
        return realReader(path, create)
    end
    local c2off = vm.setAutoRenew("cf2", "vehicle_slot", false, c2.entitlement.revision, c2.plan.revision, rent1(c2.entitlement).id)
    getFileReader = realReader
    advance(61000)
    fire("OnTickEvenPaused")                   -- the journal is read again
    local c2Lines = offLinesOf("cf2")
    local c2again = vm.setAutoRenew("cf2", "vehicle_slot", false, 0, c2.plan.revision, rent1(c2.entitlement).id)
    check(c2off.error == "journal_unavailable" and c2Lines == 1 and c2again.ok and c2again.duplicate == true,
        "an off line that landed but could not be read back is found on the next read and kept")
end

-- 7. a consent that lapses for want of money is journaled like a cancel
do
    renter("lp1", rentPrice)
    local lpSaved = proofSnapshot()            -- the consent is on in this save
    local lpLease = rent1(E.peek("TestVM", "lp1", "vehicle_slot")).lease
    ctx.setNow(lpLease.paidUntil + lpLease.G + 1000)
    fire("OnTickEvenPaused")                   -- due, no money, grace over: the consent lapses
    local lapsed = vm.getEntitlement("lp1", "vehicle_slot").entitlement
    proofRestartFrom(lpSaved)                  -- crash: the save still has the consent on
    L.credit("lp1", "survivor", 1000, "SYSTEM_MINT", { requestId = "ent-fix-lp1-topup", reasonCode = "t" })
    local lpBal = L.getBalance("lp1", "survivor").available
    advance(1000)
    fire("OnTickEvenPaused")
    check(rent1(lapsed).autoRenew == false and lapsed.notice ~= nil and lapsed.notice.code == "renewal_failed" and offLinesOf("lp1") == 1
        and rent1(E.peek("TestVM", "lp1", "vehicle_slot")).auto.on == false and L.getBalance("lp1", "survivor").available == lpBal,
        "a consent that lapsed for want of money is journaled: a crash back to it charges nothing after a top-up")
end

-- 2. a renewal reads the row, the consent and the plan again after the consumer's callback
do
    renter("rn1", 2000)
    ctx.setNow(rent1(E.peek("TestVM", "rn1", "vehicle_slot")).lease.paidUntil + 1000)
    gate.reenter = function()                  -- the consumer cancels and consents again meanwhile
        local s = vm.getEntitlement("rn1", "vehicle_slot")
        gate.cancelled = vm.setAutoRenew("rn1", "vehicle_slot", false, s.entitlement.revision, s.plan.revision, rent1(s.entitlement).id)
        s = vm.getEntitlement("rn1", "vehicle_slot")
        gate.consented = vm.setAutoRenew("rn1", "vehicle_slot", true, s.entitlement.revision, s.plan.revision, rent1(s.entitlement).id)
    end
    local rnBal = L.getBalance("rn1", "survivor").available
    fire("OnTickEvenPaused")
    gate.reenter = nil
    local rnE = vm.getEntitlement("rn1", "vehicle_slot").entitlement
    check(gate.cancelled ~= nil and gate.cancelled.ok and gate.consented ~= nil and gate.consented.ok
        and rent1(rnE).autoRenewState == "pending_on" and rent1(rnE).pendingOrderId == nil and L.getBalance("rn1", "survivor").available == rnBal,
        "a gate that cancels and consents again during a renewal: the new, unsaved consent is never charged")
end

-- 4. a new consent passes the payment gate; a cancel passes regardless
do
    advance(61000)                             -- past the consent cooldown
    local function consentNow(on)
        local s = vm.getEntitlement("rn1", "vehicle_slot")
        return vm.setAutoRenew("rn1", "vehicle_slot", on, s.entitlement.revision, s.plan.revision, rent1(s.entitlement).id)
    end
    consentNow(false)
    S.modData().frozen.rn1 = { admin = "boss" }
    local frozenOn = consentNow(true)
    S.modData().frozen.rn1 = nil
    local cfgCur = S.modData().config.currencies
    cfgCur.survivor = cfgCur.survivor or {}
    cfgCur.survivor.enabled = false
    local disabledOn = consentNow(true)
    cfgCur.survivor.enabled = nil
    local fineOn = consentNow(true)
    S.modData().frozen.rn1 = { admin = "boss" }
    local frozenOff = consentNow(false)
    S.modData().frozen.rn1 = nil
    check(frozenOn.error == "account_frozen" and disabledOn.error == "currency_disabled" and fineOn.ok and frozenOff.ok
        and rent1(E.peek("TestVM", "rn1", "vehicle_slot")).auto.on == false,
        "a frozen account or a disabled currency cannot consent to auto-renew; a cancel goes through regardless")
end

-- 3. only the row a quote was issued for can prove it unpaid
do
    L.credit("go1", "survivor", 5000, "SYSTEM_MINT", { requestId = "ent-fix-go1", reasonCode = "t" })
    local paidA = vm.purchase("go1", vm.quote("go1", "vehicle_slot", "permanent", 1).quote.id)
    local openA = vm.quote("go1", "vehicle_slot", "permanent", 1)
    advance(121000)
    fire("OnTickEvenPaused")                   -- the quote expires unpaid
    local ownA = vm.getOrder("go1", "vehicle_slot", openA.quote.id)
    local crossPaid = safe.getOrder("go1", "vehicle_slot", paidA.orderId)
    local crossOpen = safe.getOrder("go1", "vehicle_slot", openA.quote.id)
    local otherUser = vm.getOrder("bob", "vehicle_slot", openA.quote.id)
    check(paidA.ok and ownA.known == true and ownA.order.status == "unsubmitted" and crossPaid.known == false
        and crossOpen.known == false and otherUser.known == false,
        "only the source/account/product a quote was issued for proves it unpaid; another source or player reads unknown")
    local firstQuote = vm.quote("go1", "vehicle_slot", "permanent", 1)
    for _ = 1, E.CLOSED_KEEP do vm.quote("go1", "vehicle_slot", "permanent", 1) end
    local inRing = vm.getOrder("go1", "vehicle_slot", firstQuote.quote.id)
    vm.quote("go1", "vehicle_slot", "permanent", 1)
    local pastRing = vm.getOrder("go1", "vehicle_slot", firstQuote.quote.id)
    check(inRing.known == true and inRing.order.status == "unsubmitted" and pastRing.known == false,
        "the unpaid proofs are a bounded ring: past it an old quote reads unknown, never unpaid")
end

-- 8. options that exist but are invalid at first sight are never replaced by the defaults
do
    registered["TestVM.BadPrice"], registered["TestVM.BadRevision"] = true, true
    vanillaSet("TestVM.BadPrice", 0)
    vanillaSet("TestVM.BadRevision", 4)
    local badReg = vm.registerProduct({ id = "bad_plan", nameKey = "K", defaults = defaults(),
        sandbox = { permanentPrice = "TestVM.BadPrice", revision = "TestVM.BadRevision" } })
    local badSt = P.sandboxStatus("TestVM", "bad_plan")
    local badSnap = vm.getEntitlement("go1", "bad_plan")
    check(badReg.ok and SandboxVars.TestVM.BadPrice == 0 and SandboxVars.TestVM.BadRevision == 4 and badSt.state == "invalid"
        and badSt.field == "permanentPrice" and badSnap.plan.provisional == true and badSnap.available == false
        and vm.quote("go1", "bad_plan", "permanent", 1).error == "product_unavailable",
        "invalid sandbox options at first sight are kept for repair: the plan is provisional and sells nothing")
    vanillaSet("TestVM.BadPrice", 700)
    advance(1000)
    fire("OnTickEvenPaused")                   -- the host repaired the option
    local badFixed = P.row("TestVM", "bad_plan")
    check(badFixed.provisional == nil and badFixed.values.permanentPrice == 700
        and SandboxVars.TestVM.BadRevision == badFixed.revision and P.sandboxStatus("TestVM", "bad_plan").state == "synced"
        and vm.getEntitlement("go1", "bad_plan").available == true,
        "the repaired options become the plan, and its revision is written back")
end

-- 6. an unchanged apply reports the mirror as it really is
do
    saveResult = false
    local failedApply = cmd(boss, "admin.entitlements", { action = "apply", sourceMod = "TestVM", productId = "vehicle_slot",
        expectedRevision = P.row("TestVM", "vehicle_slot").revision, values = planValues({ rentalPrice = rentPrice + 10 }),
        reason = "raise rent again", requestId = "apply-n1" })
    local noop = cmd(boss, "admin.entitlements", { action = "apply", sourceMod = "TestVM", productId = "vehicle_slot",
        expectedRevision = failedApply.revision, values = planValues(), reason = "same again", requestId = "apply-n2" })
    saveResult = true
    check(failedApply.ok and failedApply.sandbox.ok == false and noop.ok and noop.updated == false
        and noop.revision == failedApply.revision and noop.sandbox.ok == false and noop.sandbox.error == "save_failed",
        "an unchanged apply after a failed mirror reports the failure again, with no new revision")
end

-- 5. entitlement admin writes use the one admin reason rule
do
    local rev5 = P.row("TestVM", "vehicle_slot").revision
    local paid = E.peek("TestVM", "go1", "vehicle_slot").orders[1]
    local blankReason = cmd(boss, "admin.entitlements", { action = "apply", sourceMod = "TestVM", productId = "vehicle_slot",
        expectedRevision = rev5, values = planValues({ rentalPrice = rentPrice + 20 }),
        reason = string.rep("\227\128\128", 3), requestId = "apply-r1" })
    local longReason = cmd(boss, "admin.entitlements", { action = "refund", username = "go1", sourceMod = "TestVM",
        productId = "vehicle_slot", orderId = paid.id, reason = string.rep("a", EC.Admin.REASON_MAX + 1) })
    local cjkReason = cmd(boss, "admin.entitlements", { action = "apply", sourceMod = "TestVM", productId = "vehicle_slot",
        expectedRevision = rev5, values = planValues({ rentalPrice = rentPrice + 20 }),
        reason = string.rep("\228\184\173", EC.Admin.REASON_MAX), requestId = "apply-r2" })
    check(blankReason.error == "reason_blank" and longReason.error == "reason_too_long" and cjkReason.ok and cjkReason.updated
        and E.peek("TestVM", "go1", "vehicle_slot").orders[1].st == "paid",
        "entitlement admin writes share the admin reason rule: ideographic blanks and 1001 characters are refused, 1000 CJK pass")
end

-- 10. independent rentals (2026-10-04): every rental is a contract with its own units, period,
-- recorded terms, renewal, consent and refund; together they stay within the plan's rental limit.
-- The blocks share their state through `mx` (this chunk is close to Lua's 200 active locals).
local mx = {}
do
    local planNow = P.row("TestVM", "vehicle_slot").values
    mx.price, mx.period = planNow.rentalPrice, planNow.rentalDays * DAY
    L.credit("mx1", "survivor", 30 * mx.price, "SYSTEM_MINT", { requestId = "ent-fix-mx1", reasonCode = "t" })
    mx.ent = function() return vm.getEntitlement("mx1", "vehicle_slot").entitlement end
    mx.buy = function(qty, rental)
        local q = vm.quote("mx1", "vehicle_slot", "rental", qty, rental)
        if not q.ok then return q end
        return vm.purchase("mx1", q.quote.id)
    end
    local a = mx.buy(2)
    confirmAll()                               -- the payment is saved: this rental starts now
    local tA = ctx.now()
    confirmAll()
    advance(DAY)
    local b = mx.buy(1)
    local overPending = vm.quote("mx1", "vehicle_slot", "rental", 1)
    confirmAll()
    local tB = ctx.now()
    confirmAll()
    local s = mx.ent()
    mx.a, mx.ra, mx.rb = a, s.rentals[1] or {}, s.rentals[2] or {}
    check(a.ok and b.ok and #s.rentals == 2 and mx.ra.id == a.orderId and mx.rb.id == b.orderId
        and mx.ra.quantity == 2 and mx.rb.quantity == 1 and mx.ra.paidUntil == tA + mx.period
        and mx.rb.paidUntil == tB + mx.period and s.rental == 3 and s.usable == 3 and s.rentalCommitted == 3
        and (mx.ra.terms or {}).price == mx.price and (mx.ra.terms or {}).amount == 2 * mx.price
        and overPending.error == "limit_reached",
        "rentals stand side by side, each from its own activation and with its own terms; one still being paid counts toward the limit")
end
do
    local renewB = mx.buy(nil, mx.rb.id)
    confirmAll()
    confirmAll()
    local s = mx.ent()
    check(renewB.ok and (s.rentals[1] or {}).paidUntil == mx.ra.paidUntil
        and (s.rentals[2] or {}).paidUntil == mx.rb.paidUntil + mx.period
        and vm.quote("mx1", "vehicle_slot", "rental", 2, mx.rb.id).error == "invalid_args"
        and vm.quote("mx1", "vehicle_slot", "rental", nil, "no-such-rental").error == "rental_unknown",
        "a renewal extends only the rental it names and keeps its units; an unknown rental is refused")
end
do
    local sc = vm.getEntitlement("mx1", "vehicle_slot")
    local noRental = vm.setAutoRenew("mx1", "vehicle_slot", true, sc.entitlement.revision, sc.plan.revision)
    local onA = vm.setAutoRenew("mx1", "vehicle_slot", true, sc.entitlement.revision, sc.plan.revision, mx.ra.id)
    confirmAll()                               -- the consent is saved
    mx.onA = noRental.error == "invalid_args" and onA.ok
    local function applyPlan(over, id)
        return cmd(boss, "admin.entitlements", { action = "apply", sourceMod = "TestVM", productId = "vehicle_slot",
            expectedRevision = P.row("TestVM", "vehicle_slot").revision, values = planValues(over),
            reason = "contract terms", requestId = id })
    end
    local function stateA() return (mx.ent().rentals[1] or {}).autoRenewState end
    local other = applyPlan({ permanentPrice = P.row("TestVM", "vehicle_slot").values.permanentPrice + 1 }, "apply-mx-perm")
    local afterOther = stateA()
    local rent = applyPlan({ rentalPrice = mx.price + 5 }, "apply-mx-rent")
    local afterRent = stateA()
    local back = applyPlan({ rentalPrice = mx.price }, "apply-mx-back")
    check(other.ok and rent.ok and back.ok and afterOther == "on" and afterRent == "paused_terms" and stateA() == "on",
        "a consent keeps the terms it was given for: another plan edit leaves it on, a rent change pauses it, the agreed rent back resumes it")
end
do
    local bal = L.getBalance("mx1", "survivor").available
    ctx.setNow(mx.ra.paidUntil + 1000)
    fire("OnTickEvenPaused")                   -- only rental A is due
    local s = mx.ent()
    local ra, rb = s.rentals[1] or {}, s.rentals[2] or {}
    check(mx.onA and bal - L.getBalance("mx1", "survivor").available == 2 * mx.price
        and ra.autoPending == true and ra.pendingOrderId ~= nil and s.pendingOrderId == nil and s.rental == 3
        and (ra.autoTerms or {}).price == mx.price and rb.autoRenewState == "off" and rb.pendingOrderId == nil,
        "a consent belongs to one rental: only it is charged when due, its units times the agreed rent, and a renewal the server started is not the player's pending purchase")
end
do
    confirmAll()                               -- A's renewal is saved and starts
    confirmAll()
    local s4 = vm.getEntitlement("mx1", "vehicle_slot")
    local onB = vm.setAutoRenew("mx1", "vehicle_slot", true, s4.entitlement.revision, s4.plan.revision, mx.rb.id)
    confirmAll()
    local bothOn = proofSnapshot()             -- a save with both consents on
    local s5 = vm.getEntitlement("mx1", "vehicle_slot")
    local offA = vm.setAutoRenew("mx1", "vehicle_slot", false, s5.entitlement.revision, s5.plan.revision, mx.ra.id)
    proofRestartFrom(bothOn)                   -- the cancel of A never reached a save
    local s = mx.ent()
    check((s4.entitlement.rentals[1] or {}).paidUntil == mx.ra.paidUntil + mx.period and onB.ok and offA.ok
        and (s.rentals[1] or {}).autoRenew == false and (s.rentals[2] or {}).autoRenew == true,
        "a journaled cancel is replayed onto its own rental only: the other rental's consent survives the crash")
end
do
    local s7 = vm.getEntitlement("mx1", "vehicle_slot")
    vm.setAutoRenew("mx1", "vehicle_slot", false, s7.entitlement.revision, s7.plan.revision, mx.rb.id)
    confirmAll()                               -- both cancels are saved
    ctx.setNow((s7.entitlement.rentals[1] or {}).graceUntil + 1000)
    fire("OnTickEvenPaused")
    local s = mx.ent()
    check(#s.rentals == 1 and (s.rentals[1] or {}).id == mx.rb.id and s.rental == 1 and s.usable == 1
        and s.rentalCommitted == 1,
        "a rental past its grace with no consent left leaves the list; only its own units stop counting")
end
do
    local cap = E.RENTALS_MAX
    E.RENTALS_MAX = 1
    local capped = vm.quote("mx1", "vehicle_slot", "rental", 1)
    E.RENTALS_MAX = cap
    local lastA = nil
    for _, o in ipairs(E.peek("TestVM", "mx1", "vehicle_slot").orders) do
        if lastA == nil and o.rental == mx.ra.id then lastA = o.id end
    end
    local bal = L.getBalance("mx1", "survivor").available
    local firstA = vm.refund("mx1", "vehicle_slot", mx.a.orderId, { reason = "old period" })
    local endedA = vm.refund("mx1", "vehicle_slot", lastA, { reason = "ended rental" })
    local c = mx.buy(1)
    local cancelC = vm.refund("mx1", "vehicle_slot", c.orderId, { reason = "never started" })
    local s = mx.ent()
    check(capped.error == "rental_count_limit" and firstA.error == "refund_not_latest" and endedA.ok and cancelC.ok
        and #s.rentals == 1 and (s.rentals[1] or {}).id == mx.rb.id
        and L.getBalance("mx1", "survivor").available == bal + 2 * mx.price,
        "refunds: an ended rental returns its newest order's money only, an older period is refused, and a rental still being paid goes with its money")
end
do
    local d = mx.buy(2)
    confirmAll()
    confirmAll()
    local applied = cmd(boss, "admin.entitlements", { action = "apply", sourceMod = "TestVM", productId = "vehicle_slot",
        expectedRevision = P.row("TestVM", "vehicle_slot").revision, values = planValues({ rentalLimit = 2 }),
        reason = "fewer rentals", requestId = "apply-mx1" })
    local s = mx.ent()
    local dv = s.rentals[2] or {}
    mx.d = dv.id
    check(d.ok and applied.ok and s.rentalCommitted == 3 and dv.state == "paused_terms"
        and vm.quote("mx1", "vehicle_slot", "rental", 1).error == "limit_reached"
        and vm.quote("mx1", "vehicle_slot", "rental", nil, dv.id).error == "limit_reached",
        "below a lowered rental limit an account keeps its rentals running but buys no new rental and renews none")
end
do
    local sb = vm.getEntitlement("mx1", "vehicle_slot")
    local onB = vm.setAutoRenew("mx1", "vehicle_slot", true, sb.entitlement.revision, sb.plan.revision, mx.rb.id)
    confirmAll()                               -- the consent is saved; B is due but over the limit
    local bal = L.getBalance("mx1", "survivor").available
    local lease = E.peek("TestVM", "mx1", "vehicle_slot").rentals[1].lease
    ctx.setNow(lease.paidUntil + lease.G + HOUR)
    fire("OnTickEvenPaused")                   -- grace over, still over the limit: the consent lapses
    local lapsed = mx.ent()
    confirmAll()                               -- the lapse is saved: the ended rental leaves
    local s = mx.ent()
    check(onB.ok and (lapsed.rentals[1] or {}).autoRenew == false and lapsed.notice ~= nil
        and lapsed.notice.error == "limit_reached" and lapsed.notice.rental == mx.rb.id
        and L.getBalance("mx1", "survivor").available == bal and #s.rentals == 1 and (s.rentals[1] or {}).id == mx.d
        and s.rentalCommitted == 2 and vm.quote("mx1", "vehicle_slot", "rental", nil, mx.d).ok == true,
        "over the limit a due rental is never charged: at the end of its grace its consent lapses and it ends, and the rest renew again")
end

getSandboxOptions, getServerName = nil, nil
SandboxVars.TestVM = nil
ctx.setOnline({})
