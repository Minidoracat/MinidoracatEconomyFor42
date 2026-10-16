--[[
Player buy orders (ECWanted) - behaviour scenarios, run by scripts/smoke_harness.lua. The harness
passes its fake PZ globals, clock and `check`; money, ModData, mailbox, recovery journal, events
and commands all go through the real modules. Every check counts toward the harness
EXPECTED_ASSERTIONS.

Recovery probes first (W-R*): each one is a place the escrowed lot or a delivery has to be known to
the recovery core, and each check goes red when that probe is taken out.
]]

local ctx = ...
local check, fire, fakePlayer = ctx.check, ctx.fire, ctx.fakePlayer
local EC = MinidoracatEconomy
local S, L = EC.Server, EC.Ledger
local Wd, M, Mk, Rec, A = S.Wanted, S.Mailbox, S.Market, S.Recovery, EC.Admin
local KEY = EC.PLAYER_MODDATA_KEY
local SV = SandboxVars.MinidoracatEconomy
local CURRENCIES = { "survivor", "cat" }

local serial = 0
local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, value in pairs(v) do out[k] = copy(value) end
    return out
end
local function advance(ms) ctx.setNow(ctx.now() + ms) end
local function cmd(p, name, args)
    serial = serial + 1
    advance(700)
    args = args or {}
    args.requestId = args.requestId or ("want-" .. serial)
    withCurrency(name, args)
    local sent = ctx.sent()
    local first = #sent + 1
    fire("OnClientCommand", EC.COMMAND_MODULE, name, p, args)
    local replyName = name == "hello" and "hello.ack" or name
    for i = first, #sent do
        if sent[i].player == p and sent[i].command == replyName then return sent[i].args end
    end
    error("missing reply: " .. name)
end
local function notices(p, kind)
    local out = {}
    for _, s in ipairs(ctx.sent()) do
        if s.player == p and s.command == "market.notice" and s.args.kind == kind then out[#out + 1] = s.args end
    end
    return out
end
local function fresh(tag)
    ctx.store()[EC.MODDATA_KEY] = nil
    ctx.clearFiles()
    ctx.clearSent()
    worldSprites = { ["100,200,0"] = "MinidoracatEconomy_terminal_0" }
    SV.MarketListingFeePercent, SV.MarketSalesTaxPercent = 10, 10
    advance(61000)
    fire("OnServerStarted")
    local admin, buyer, seller = fakePlayer(tag .. "-admin"), fakePlayer(tag .. "-buyer"), fakePlayer(tag .. "-seller")
    admin.role = "admin"
    buyer.inventory, seller.inventory = fakeInventory(500), fakeInventory(500)
    ctx.setOnline({ admin, buyer, seller })
    assert(cmd(admin, "terminal.register", { x = 100, y = 200, z = 0, kind = "atm" }).ok)
    for _, p in ipairs({ buyer, seller }) do
        assert(L.credit(p:getUsername(), "survivor", 5000, "SYSTEM_MINT", { requestId = tag .. p:getUsername() .. "-s", reasonCode = "test" }).ok)
        assert(L.credit(p:getUsername(), "cat", 1000, "SYSTEM_MINT", { requestId = tag .. p:getUsername() .. "-c", reasonCode = "test" }).ok)
    end
    return admin, buyer, seller
end
local function native(p, fullType, n)
    local out = {}
    for i = 1, n or 1 do
        local it = instanceItem(fullType)
        assert(p.inventory:AddItem(it) == it)
        out[i] = it
    end
    return out
end
local function ids(list, from, to)
    local out = {}
    for i = from or 1, to or #list do out[#out + 1] = list[i]:getID() end
    return out
end
local function restart(saved)
    ctx.store()[EC.MODDATA_KEY] = copy(saved)
    advance(1000)
    fire("OnServerStarted")
end
local function reason(user, id)
    local rec = Rec.heldRecord(user, "pend:" .. id)
    return rec and rec.resolvedAt == nil and rec.reason or nil
end
local function pendOf(p, kind)
    for id, pend in pairs(p.modData[KEY].pendingOuts) do
        if type(pend) == "table" and pend.kind == kind then return id, pend end
    end
    return nil
end
local function letters(user, kind, item)
    local n, qty = 0, 0
    for _, e in ipairs(M.list(user)) do
        if (kind == nil or e.kind == kind) and (item == nil or e.item == item) then n, qty = n + 1, qty + (e.qty or 0) end
    end
    return n, qty
end
local function bal(user, cur) return L.getBalance(user, cur or "survivor") end
local function order(id) return S.modData().wanted.orders[id] end
-- per currency: every open order's held plus every auction's highest bid is every wallet's reserved
local function reservedInvariant()
    for _, cur in ipairs(CURRENCIES) do
        local held, reserved = 0, 0
        for _, o in pairs(S.modData().wanted.orders) do
            for _, opt in ipairs(o.options) do
                if opt.kind == "coin" and opt.currency == cur then held = held + opt.held end
            end
        end
        for _, a in pairs(S.modData().auctions.items) do
            if a.highest and a.highest.currency == cur then held = held + a.highest.amount end
        end
        for _, byCur in pairs(S.modData().wallets) do
            if byCur[cur] then reserved = reserved + byCur[cur].reserved end
        end
        if held ~= reserved or L.conservation(cur) ~= 0 then return false end
    end
    return true
end
local function heldMatches(o)
    for _, opt in ipairs(o.options) do
        if opt.kind == "coin" and opt.held ~= opt.unitPrice * o.qty then return false end
        if opt.kind == "item" and opt.lot.qty < opt.perUnit * o.qty then return false end
    end
    return true
end
-- everything a refusal must leave alone
local function state(...)
    local parts = { S.modData().meta.seq, S.modData().wanted.count, S.modData().mailbox.unclaimed }
    for _, p in ipairs({ ... }) do
        local u = p:getUsername()
        for _, cur in ipairs(CURRENCIES) do
            local b = bal(u, cur)
            parts[#parts + 1] = u .. cur .. b.available .. "/" .. b.reserved .. "/" .. b.rev
        end
        parts[#parts + 1] = #p.inventory.items
        parts[#parts + 1] = EC.countKeys(p.modData[KEY] and p.modData[KEY].pendingOuts or {})
    end
    for _, cur in ipairs(CURRENCIES) do parts[#parts + 1] = bal("SYSTEM_BURN", cur).available end
    return table.concat(parts, "|")
end
local function coinOrder(p, item, qty, price, extra)
    local args = { item = item, qty = qty, options = { { kind = "coin", currency = "survivor", unitPrice = price } } }
    for k, v in pairs(extra or {}) do args[k] = v end
    return cmd(p, "wanted.create", args)
end

io.write("scenario W-R: buy orders and the recovery core\n")

-- ---- W-R1: a delivery the world lost while the seller's save kept it goes back to the seller ----
do
    local _, buyer, seller = fresh("wr1")
    local created = coinOrder(buyer, "Base.Nails", 5, 10)
    assert(created.ok, tostring(created.error))
    local saved = copy(S.modData())
    local nails = native(seller, "Base.Nails", 2)
    local filled = cmd(seller, "wanted.fill", { orderId = created.orderId, option = 1, itemIds = ids(nails), unitPrice = 10 })
    assert(filled.ok, tostring(filled.error))
    local fillId = pendOf(seller, "fill")
    assert(fillId and proofSettle() == 0)
    restart(saved)
    ctx.setOnline({ buyer, seller })
    M.reconcile(seller)
    proofPump(seller:getUsername())
    local _, back = letters(seller:getUsername(), "return", "Base.Nails")
    check(back == 2 and not Mk.listingExists(fillId) and Mk.ownerCount(seller:getUsername()) == 0
        and order(created.orderId).qty == 5 and order(created.orderId).options[1].held == 50
        and letters(buyer:getUsername(), "wanted") == 0 and reason(seller:getUsername(), fillId) == nil
        and reservedInvariant(),
        "W-R1: a fill the world lost comes back to the seller as a return letter; the order is the world's own and is not touched")
end

-- ---- W-R2: the world kept the fill, the seller's older save still holds the goods ----
do
    local _, buyer, seller = fresh("wr2")
    local created = coinOrder(buyer, "Base.Nails", 5, 10)
    local nails = native(seller, "Base.Nails", 2)
    local oldIds = ids(nails)
    assert(cmd(seller, "wanted.fill", { orderId = created.orderId, option = 1, itemIds = oldIds, unitPrice = 10 }).ok)
    local fillId = pendOf(seller, "fill")
    assert(proofSettle() == 0)
    restart(copy(S.modData()))
    ctx.setOnline({ buyer, seller })
    seller.modData[KEY].pendingOuts[fillId] = nil
    for _, id in ipairs(oldIds) do local ghost = instanceItem("Base.Nails"); ghost.id = id; seller.inventory:AddItem(ghost) end
    cmd(seller, "hello")
    check(seller.inventory.count("Base.Nails") == 0 and order(created.orderId).qty == 3
        and letters(buyer:getUsername(), "wanted") == 1 and bal(seller:getUsername()).available == 5000 + 20 - 2,
        "W-R2: an older save's copies of a delivered fill are taken back, the payment and the buyer's letter stay")
end

-- ---- W-R3: the delivery's receipt is gone but its ledger key is not: no live record, no hold ----
do
    local _, buyer, seller = fresh("wr3")
    local created = coinOrder(buyer, "Base.Nails", 5, 10)
    local nails = native(seller, "Base.Nails", 2)
    assert(cmd(seller, "wanted.fill", { orderId = created.orderId, option = 1, itemIds = ids(nails), unitPrice = 10 }).ok)
    local fillId = pendOf(seller, "fill")
    assert(proofSettle() == 0)
    S.modData().recovery.ops[fillId] = nil              -- as if the receipt had been pruned
    M.reconcile(seller)
    proofPump(seller:getUsername())
    check(reason(seller:getUsername(), fillId) == nil and seller.modData[KEY].pendingOuts[fillId] ~= nil
        and letters(seller:getUsername(), "return") == 0,
        "W-R3: a fill whose commit key is in the ledger is not a world_unverified hold and nothing is mailed back")
    -- the same after the world was saved: the commit survived, so the pending converges
    restart(copy(S.modData()))
    ctx.setOnline({ buyer, seller })
    M.reconcile(seller)
    proofPump(seller:getUsername())
    check(reason(seller:getUsername(), fillId) == nil and seller.modData[KEY].pendingOuts[fillId] == nil
        and letters(seller:getUsername(), "return") == 0,
        "W-R3b: once saved, a fill proven by its ledger key clears its pending without a receipt (never judged from the journal)")
end

-- ---- W-R4: the buyer's escrowed lot the world lost goes back to the buyer; twice in a row ----
do
    local _, buyer = fresh("wr4")
    local planks = native(buyer, "Base.Plank", 3)
    local saved = copy(S.modData())
    local created = cmd(buyer, "wanted.create", { item = "Base.Nails", qty = 3,
        options = { { kind = "item", itemIds = ids(planks), perUnit = 1 } } })
    assert(created.ok, tostring(created.error))
    local lotId = order(created.orderId).options[1].lot.id
    assert(proofSettle() == 0)
    restart(saved)
    ctx.setOnline({ buyer })
    M.reconcile(buyer)
    proofPump(buyer:getUsername())
    local _, back = letters(buyer:getUsername(), "return", "Base.Plank")
    check(back == 3 and S.modData().wanted.count == 0 and not Mk.listingExists(lotId)
        and reason(buyer:getUsername(), lotId) == nil,
        "W-R4: a lot the world lost is mailed back to the buyer and the order is not rebuilt")
    assert(proofSettle() == 0)
    restart(saved)
    ctx.setOnline({ buyer })
    M.reconcile(buyer)
    proofPump(buyer:getUsername())
    local _, again = letters(buyer:getUsername(), "return", "Base.Plank")
    check(again == 3 and reason(buyer:getUsername(), lotId) == nil and S.modData().wanted.count == 0,
        "W-R4b: rolled back again, the return of a lot that never had a price or a currency is mailed once more, not held as currency_unknown")
end

-- ---- W-R5: while the lot is escrowed its receipt stays open; an older save's copy is reclaimed ----
do
    local _, buyer = fresh("wr5")
    local planks = native(buyer, "Base.Plank", 2)
    local oldIds = ids(planks)
    local created = cmd(buyer, "wanted.create", { item = "Base.Nails", qty = 2,
        options = { { kind = "item", itemIds = oldIds, perUnit = 1 } } })
    local lotId = order(created.orderId).options[1].lot.id
    assert(proofSettle() == 0)
    restart(copy(S.modData()))
    ctx.setOnline({ buyer })
    cmd(buyer, "hello")
    local receipt = S.modData().recovery.ops[lotId]
    check(buyer.modData[KEY].pendingOuts[lotId] == nil and receipt ~= nil and receipt.closed == nil,
        "W-R5: the lot's pending clears once saved, but its receipt is not closed while the lot is escrowed")
    for _, id in ipairs(oldIds) do local ghost = instanceItem("Base.Plank"); ghost.id = id; buyer.inventory:AddItem(ghost) end
    cmd(buyer, "hello")
    check(buyer.inventory.count("Base.Plank") == 0 and order(created.orderId) ~= nil,
        "W-R5b: an older save's copies of the escrowed lot are taken back and the order stays")
    assert(cmd(buyer, "wanted.cancel", { orderId = created.orderId }).ok)
    cmd(buyer, "hello")
    check(buyer.inventory.count("Base.Plank") == 2 and S.modData().recovery.ops[lotId].closed ~= nil,
        "W-R5c: once the lot is mailed back and claimed the receipt closes")
end

-- ---- W-R6: no receipt, lot alive after a partial payment: the core sees it and its original size ----
do
    local _, buyer, seller = fresh("wr6")
    local planks = native(buyer, "Base.Plank", 3)
    local created = cmd(buyer, "wanted.create", { item = "Base.Nails", qty = 3,
        options = { { kind = "item", itemIds = ids(planks), perUnit = 1 } } })
    local lotId = order(created.orderId).options[1].lot.id
    local nails = native(seller, "Base.Nails", 1)
    assert(cmd(seller, "wanted.fill", { orderId = created.orderId, option = 1, itemIds = ids(nails) }).ok)
    assert(proofSettle() == 0)
    S.modData().recovery.ops[lotId] = nil               -- as if the receipt had been pruned
    M.reconcile(buyer)
    proofPump(buyer:getUsername())
    check(order(created.orderId).options[1].lot.qty == 2 and Wd.lotExists(lotId)
        and reason(buyer:getUsername(), lotId) == nil and buyer.modData[KEY].pendingOuts[lotId] ~= nil,
        "W-R6: a live lot is found by the recovery core with the quantity it left with (3), not what is left (2): no hold")
    restart(copy(S.modData()))
    ctx.setOnline({ buyer, seller })
    M.reconcile(buyer)
    proofPump(buyer:getUsername())
    check(reason(buyer:getUsername(), lotId) == nil and buyer.modData[KEY].pendingOuts[lotId] == nil and Wd.lotExists(lotId),
        "W-R6b: once saved, the live lot alone proves the escrow and its pending clears")
end

-- ---- W-R7: partial -> rollback -> partial for goods that never had a price (a lot, a goods-paid fill) ----
-- The first rollback finds one original back in the player save and mails the other two home as a
-- `return` whose originalKind is the goods' own kind; that return is lost by a second rollback while
-- the save now also holds a second original, so the last unit is a second partial of a return.
local function partialTwice(tag, giver, items, saved, id)
    local user = giver:getUsername()
    restart(saved)
    ctx.setOnline({ giver })
    giver.inventory:AddItem(items[1])
    M.reconcile(giver)
    proofPump(user)
    local _, first = letters(user, "return", items[1]:getFullType())
    assert(proofSettle() == 0)
    restart(saved)
    ctx.setOnline({ giver })
    giver.inventory:AddItem(items[2])
    M.reconcile(giver)
    proofPump(user)
    local _, second = letters(user, "return", items[1]:getFullType())
    return first, second, reason(user, id)
end
do
    local _, buyer = fresh("wr7a")
    local planks = native(buyer, "Base.Plank", 3)
    local saved = copy(S.modData())
    local created = cmd(buyer, "wanted.create", { item = "Base.Nails", qty = 3,
        options = { { kind = "item", itemIds = ids(planks), perUnit = 1 } } })
    local lotId = order(created.orderId).options[1].lot.id
    assert(proofSettle() == 0)
    local first, second, held = partialTwice("wr7a", buyer, planks, saved, lotId)
    check(first == 2 and second == 1 and held == nil and buyer.inventory.count("Base.Plank") == 2,
        "W-R7a: a buy order's lot partly returned twice: the second partial of the price-less return still mails the last unit (" .. tostring(held) .. ")")
end
do
    local _, buyer, seller = fresh("wr7b")
    local planks = native(buyer, "Base.Plank", 3)
    local created = cmd(buyer, "wanted.create", { item = "Base.Nails", qty = 3,
        options = { { kind = "item", itemIds = ids(planks), perUnit = 1 } } })
    local saved = copy(S.modData())
    local nails = native(seller, "Base.Nails", 3)
    assert(cmd(seller, "wanted.fill", { orderId = created.orderId, option = 1, itemIds = ids(nails) }).ok)
    local fillId = pendOf(seller, "fill")
    assert(fillId and proofSettle() == 0)
    local first, second, held = partialTwice("wr7b", seller, nails, saved, fillId)
    check(first == 2 and second == 1 and held == nil and seller.inventory.count("Base.Nails") == 2,
        "W-R7b: a goods-paid fill partly returned twice: the second partial still mails the last unit (" .. tostring(held) .. ")")
end

io.write("scenario W: player buy orders\n")

local admin, buyer, seller = fresh("w")
local bu, su = buyer:getUsername(), seller:getUsername()
local mod = fakePlayer("w-mod"); mod.role = "moderator"
local seller2 = fakePlayer("w-seller2"); seller2.inventory = fakeInventory(500)
ctx.setOnline({ admin, buyer, seller, mod, seller2 })
for _, p in ipairs({ seller, seller2, mod }) do cmd(p, "wanted.mine", {}) end   -- first sight of each login is not part of any refusal below
assert(L.credit(seller2:getUsername(), "survivor", 100, "SYSTEM_MINT", { requestId = "w-s2", reasonCode = "test" }).ok)

-- ---- W-1: create, every shape ----
local planks = native(buyer, "Base.Plank", 10)
local mixed = cmd(buyer, "wanted.create", { item = "Base.Nails", qty = 10, options = {
    { kind = "coin", currency = "survivor", unitPrice = 10 }, { kind = "coin", currency = "cat", unitPrice = 3 },
    { kind = "item", itemIds = ids(planks), perUnit = 1 } } })
local mo = order(mixed.orderId)
check(mixed.ok and mixed.fees.survivor == 10 and mixed.fees.cat == 3 and mixed.held.survivor == 100 and mixed.held.cat == 30
    and mixed.lotQty == 10 and bal(bu).available == 5000 - 110 and bal(bu).reserved == 100
    and bal(bu, "cat").available == 1000 - 33 and bal(bu, "cat").reserved == 30
    and bal("SYSTEM_BURN").available == 10 and bal("SYSTEM_BURN", "cat").available == 3
    and buyer.inventory.count("Base.Plank") == 0 and mo.options[3].lot.qty == 10 and heldMatches(mo)
    and #mixed.mine == 1 and mixed.usage.wanted == 1,
    "W-1: a mixed order reserves price x qty per coin option, burns one listing fee per coin option, escrows the lot")
local resend = cmd(buyer, "wanted.create", { requestId = "want-" .. (serial), item = "Base.Nails", qty = 10, options = {
    { kind = "coin", currency = "survivor", unitPrice = 10 }, { kind = "coin", currency = "cat", unitPrice = 3 },
    { kind = "item", itemIds = ids(planks), perUnit = 1 } } })
check(resend.duplicate == true and resend.orderId == mixed.orderId and S.modData().wanted.count == 1
    and bal(bu).available == 5000 - 110,
    "W-1b: a resent create answers the first order and charges nothing")
check(resend.expiresAt == mixed.expiresAt and resend.item == "Base.Nails" and resend.qty == 10 and resend.lotQty == 10
    and resend.fees.survivor == 10 and resend.held.cat == 30,
    "W-1b2: the resent create answers with the first one's expiry, fees and reservations")
local conflict = cmd(buyer, "wanted.create", { requestId = "want-" .. (serial - 1), item = "Base.Nails", qty = 9, options = {
    { kind = "coin", currency = "survivor", unitPrice = 10 } } })
check(conflict.error == "request_conflict" and S.modData().wanted.count == 1,
    "W-1c: the same create id for another order is request_conflict")
local corn = native(buyer, "Base.CannedCorn", 2)
local itemOnly = cmd(buyer, "wanted.create", { item = "Base.Axe", qty = 2, cond = { minPct = 80 },
    options = { { kind = "item", itemIds = ids(corn), perUnit = 1 } } })
check(itemOnly.ok and EC.countKeys(itemOnly.fees) == 0 and bal(bu).available == 5000 - 110 and buyer.inventory.count("Base.CannedCorn") == 0
    and cmd(buyer, "wanted.create", { requestId = "want-" .. serial, item = "Base.Axe", qty = 2, cond = { minPct = 80 },
        options = { { kind = "item", itemIds = ids(corn), perUnit = 1 } } }).duplicate == true,
    "W-1d: an item-only order is free and a resend is answered from the operation record")
local coinOnly = cmd(buyer, "wanted.create", { item = "Base.Axe", qty = 1, cond = { new = true },
    options = { { kind = "coin", currency = "survivor", unitPrice = 95 } } })
check(coinOnly.ok and coinOnly.fees.survivor == 10 and bal(bu).available == 5000 - 110 - 105 and bal(bu).reserved == 195
    and reservedInvariant(), "W-1e: a coin-only order: fee rounds up (95 x 10% = 10), the reservation is exact")
local rope = native(seller, "Base.Rope", 1)
local auc = cmd(seller, "auction.create", { itemIds = ids(rope), startPrice = 20, minutes = 720 })
local bid = cmd(buyer, "auction.bid", { auctionId = auc.auctionId, amount = 20 })
check(auc.ok and bid.ok and bal(bu).reserved == 195 + 20 and reservedInvariant(),
    "W-1f: per currency, the open orders' held plus the auction's high bid is exactly every wallet's reserved")

-- ---- W-2: create refusals move nothing ----
local before = state(buyer)
local function refused(args, code, label)
    local r = cmd(buyer, "wanted.create", args)
    check(r.error == code and state(buyer) == before, label .. " (" .. tostring(r.error) .. ")")
    return r
end
local poor = refused({ item = "Base.Nails", qty = 50, options = { { kind = "coin", currency = "cat", unitPrice = 100 } } },
    "insufficient_funds", "W-2a: not enough for price x qty + fee is refused with zero change")
check(poor.currency == "cat" and poor.needed == 5500, "W-2b: the refusal names the currency and what was needed")
refused({ item = "Base.Nails", qty = 1, options = { { kind = "coin", currency = "survivor", unitPrice = 1 },
    { kind = "coin", currency = "survivor", unitPrice = 2 } } }, "invalid_args", "W-2c: two coin options in one currency are refused")
refused({ item = "Base.Nails", qty = 1, cond = { new = true, minPct = 5 }, options = { { kind = "coin", currency = "survivor", unitPrice = 1 } } },
    "invalid_args", "W-2d: new-only and a minimum durability are exclusive")
refused({ item = "Base.Nope", qty = 1, options = { { kind = "coin", currency = "survivor", unitPrice = 1 } } },
    "unknown_item", "W-2e: an item type without a script is unknown_item")
refused({ item = "Base.Map", qty = 1, options = { { kind = "coin", currency = "survivor", unitPrice = 1 } } },
    "not_whitelisted", "W-2f: a fixed type is not_whitelisted")
local pmax = EC.sandbox("MarketPriceMax", 1000000)
refused({ item = "Base.Nails", qty = 1, options = { { kind = "coin", currency = "survivor", unitPrice = pmax + 1 } } },
    "price_range", "W-2g: a unit price above MarketPriceMax is price_range")
buyer.x = 500
refused({ item = "Base.Nails", qty = 1, options = { { kind = "coin", currency = "survivor", unitPrice = 1 } } },
    "not_at_terminal", "W-2h: away from a terminal")
buyer.x = 100
SV.WantedMaxPerPlayer = 0
refused({ item = "Base.Nails", qty = 1, options = { { kind = "coin", currency = "survivor", unitPrice = 1 } } },
    "wanted_disabled", "W-2i: WantedMaxPerPlayer 0 switches creation off")
SV.WantedMaxPerPlayer = 3
local cap = refused({ item = "Base.Nails", qty = 1, options = { { kind = "coin", currency = "survivor", unitPrice = 1 } } },
    "too_many_orders", "W-2j: the per-player cap")
check(cap.max == 3, "W-2k: too_many_orders names the cap")
SV.WantedMaxPerPlayer = nil
local savedMax = Wd.MAX_ORDERS
Wd.MAX_ORDERS = S.modData().wanted.count
refused({ item = "Base.Nails", qty = 1, options = { { kind = "coin", currency = "survivor", unitPrice = 1 } } },
    "wanted_full", "W-2l: the server-wide cap")
Wd.MAX_ORDERS = savedMax
SV.MailboxPerAccount = 5
for i = 1, 2 do M.add(bu, { kind = "return", item = "Base.Nails", qty = 1 }) end
before = state(buyer)
SV.WantedMaxPerPlayer = 10
refused({ item = "Base.Nails", qty = 1, options = { { kind = "coin", currency = "survivor", unitPrice = 1 } } },
    "mailbox_full", "W-2m: three open orders and two letters fill five slots")
check(M.usage(bu).wanted == 3 and M.usage(bu).used == 5 and M.used(bu) == 5,
    "W-2n: every open order holds one mailbox slot")
SV.MailboxPerAccount, SV.WantedMaxPerPlayer = nil, nil
for _, e in ipairs(M.list(bu)) do if e.kind == "return" then cmd(buyer, "mail.claim", { mailId = e.id }) end end
local axes = native(buyer, "Base.Axe", 2)
axes[2].condition = 3
before = state(buyer)
refused({ item = "Base.Nails", qty = 2, options = { { kind = "item", itemIds = ids(axes), perUnit = 1 } } },
    "mixed_items", "W-2o: an item option is one signature")
axes[1].equipped = true
refused({ item = "Base.Nails", qty = 1, options = { { kind = "item", itemIds = { axes[1]:getID() }, perUnit = 1 } } },
    "equipped", "W-2p: the market's state check refuses an equipped copy")
axes[1].equipped = false
refused({ item = "Base.Nails", qty = 1, options = { { kind = "item", itemIds = { 987654 }, perUnit = 1 } } },
    "item_not_found", "W-2q: a copy not in the backpack")
S.modData().frozen[bu] = { at = ctx.now() }
refused({ item = "Base.Nails", qty = 1, options = { { kind = "coin", currency = "survivor", unitPrice = 1 } } },
    "account_frozen", "W-2r: a frozen buyer")
S.modData().frozen[bu] = nil

-- ---- W-3: fill with coin, with goods, and the completed close ----
local nails = native(seller, "Base.Nails", 10)
before = state(buyer, seller)
local wrong = cmd(seller, "wanted.fill", { orderId = mixed.orderId, option = 1, itemIds = ids(nails, 1, 4), unitPrice = 9 })
check(wrong.error == "price_changed" and wrong.unitPrice == 10 and state(buyer, seller) == before,
    "W-3a: a fill at a stale unit price is price_changed with the current one")
check(cmd(buyer, "wanted.fill", { orderId = mixed.orderId, option = 1, itemIds = { 987654 }, unitPrice = 10 }).error == "own_order"
    and state(buyer, seller) == before, "W-3b: a buyer filling their own order is own_order before any item is looked up")
local over = cmd(seller, "wanted.fill", { orderId = mixed.orderId, option = 1, itemIds = ids(native(seller, "Base.Nails", 11)), unitPrice = 10 })
check(over.error == "qty_exceeded" and over.qty == 10, "W-3c: more units than wanted is qty_exceeded with the remaining quantity")
local hammer = native(seller, "Base.Hammer", 1)
check(cmd(seller, "wanted.fill", { orderId = mixed.orderId, option = 1, itemIds = ids(hammer), unitPrice = 10 }).error == "wrong_item",
    "W-3d: another item type is wrong_item")
local odd = native(seller, "Base.Nails", 1)[1]
odd.condition = 3
before = state(buyer, seller)
check(cmd(seller, "wanted.fill", { orderId = mixed.orderId, option = 1, itemIds = { nails[1]:getID(), odd:getID() }, unitPrice = 10 }).error == "mixed_items"
    and state(buyer, seller) == before, "W-3d2: one delivery is one signature (mixed_items), with zero change")
S.modData().frozen[bu] = { at = ctx.now() }
check(cmd(seller, "wanted.fill", { orderId = mixed.orderId, option = 1, itemIds = ids(nails, 1, 4), unitPrice = 10 }).error == "owner_frozen",
    "W-3e: a frozen buyer's order cannot be filled")
S.modData().frozen[bu] = nil
check(cmd(seller, "wanted.fill", { orderId = mixed.orderId, option = 4, itemIds = ids(nails, 1, 4), unitPrice = 10 }).error == "invalid_args",
    "W-3f: an option number past three is invalid_args")
local sBefore, burnBefore = bal(su).available, bal("SYSTEM_BURN").available
local catBefore = bal(bu, "cat").available
local fillArgs = { orderId = mixed.orderId, option = 1, itemIds = ids(nails, 1, 4), unitPrice = 10 }
local filled = cmd(seller, "wanted.fill", fillArgs)
local fillRid = "want-" .. serial
check(filled.ok and filled.qty == 4 and filled.price == 40 and filled.tax == 4 and filled.remaining == 6
    and bal(su).available == sBefore + 36 and bal("SYSTEM_BURN").available == burnBefore + 4
    and bal(bu).reserved == 215 - 40 and bal(bu, "cat").reserved == 18 and bal(bu, "cat").available == catBefore + 12
    and mo.qty == 6 and heldMatches(mo) and mo.options[3].lot.qty == 10 and reservedInvariant(),
    "W-3g: a coin fill pays the seller less 10% tax and releases the other coin option by the units filled")
local wantedLetter = nil
for _, e in ipairs(M.list(bu)) do if e.kind == "wanted" then wantedLetter = e end end
check(wantedLetter ~= nil and wantedLetter.qty == 4 and wantedLetter.item == "Base.Nails" and wantedLetter.listingId == nil
    and #notices(buyer, "wanted_filled") == 1 and notices(buyer, "wanted_filled")[1].remainingQty == 6,
    "W-3h: the buyer's letter carries the goods without a listingId, and the buyer is told")
local again = cmd(seller, "wanted.fill", { requestId = fillRid, orderId = mixed.orderId, option = 1, itemIds = fillArgs.itemIds, unitPrice = 10 })
local swapped = cmd(seller, "wanted.fill", { requestId = fillRid, orderId = mixed.orderId, option = 1, itemIds = ids(nails, 5, 6), unitPrice = 10 })
check(again.duplicate == true and swapped.error == "request_conflict" and mo.qty == 6 and bal(su).available == sBefore + 36,
    "W-3i: a resent fill is a duplicate and other items under the same id are request_conflict")
local sPlanks = seller.inventory.count("Base.Plank")
local byGoods = cmd(seller, "wanted.fill", { orderId = mixed.orderId, option = 3, itemIds = ids(nails, 5, 6) })
local payLetter = S.modData().mailbox.byOwner[su] and S.modData().mailbox.byOwner[su].entries[byGoods.mailId]
check(byGoods.ok and byGoods.payQty == 2 and byGoods.delivered == true and seller.inventory.count("Base.Plank") == sPlanks + 2
    and payLetter ~= nil and payLetter.listingId == mo.options[3].lot.id and payLetter.kind == "wanted_pay"
    and mo.options[3].lot.qty == 8 and mo.qty == 4 and heldMatches(mo) and reservedInvariant(),
    "W-3j: a fill paid in goods hands the seller perUnit x n out of the lot (letter listingId = lot id) and releases both coin options")
local byGoodsAgain = cmd(seller, "wanted.fill", { requestId = "want-" .. serial, orderId = mixed.orderId, option = 3, itemIds = ids(nails, 5, 6) })
check(byGoodsAgain.duplicate == true and byGoodsAgain.payItem == "Base.Plank" and byGoodsAgain.payQty == 2
    and byGoodsAgain.remaining == 4 and byGoodsAgain.closed == false and byGoodsAgain.mailId == byGoods.mailId
    and byGoodsAgain.qty == 2 and mo.options[3].lot.qty == 8,
    "W-3j2: a resent goods-paid fill answers with the first one's payment, letter, remaining units and closed flag")
local sCat = bal(su, "cat").available
local done = cmd(seller, "wanted.fill", { orderId = mixed.orderId, option = 2, itemIds = ids(nails, 7, 10), unitPrice = 3 })
local _, lotBack = letters(bu, "return", "Base.Plank")
check(done.ok and done.closed == true and order(mixed.orderId) == nil and bal(su, "cat").available == sCat + 10
    and lotBack == 8 and bal(bu).reserved == 95 + 20 and bal(bu, "cat").reserved == 0 and reservedInvariant(),
    "W-3k: the last units close the order in the same tick and the unused lot goes back to the buyer")

-- ---- W-4: conditions ----
local axe = native(seller, "Base.Axe", 1)[1]
axe.condition, axe.head = 9, 5
local cands = cmd(seller, "wanted.candidates", { orderId = itemOnly.orderId })
check(cands.ok and #cands.rows == 1 and cands.rows[1].verdict == "worn" and cands.rows[1].pct == 50 and cands.usage ~= nil,
    "W-4a: candidates name the worn verdict with the lower of body (90%) and head (50%)")
before = state(buyer, seller)
local worn = cmd(seller, "wanted.fill", { orderId = itemOnly.orderId, option = 1, itemIds = { axe:getID() } })
check(worn.error == "worn" and worn.pct == 50 and worn.minPct == 80 and state(buyer, seller) == before,
    "W-4b: a head below the minimum refuses the fill even though the body passes")
axe.head = 8
local good = cmd(seller, "wanted.fill", { orderId = itemOnly.orderId, option = 1, itemIds = { axe:getID() } })
check(good.ok and good.payQty == 1 and S.Codec.durabilityPct(instanceItem("Base.Axe")) == 100,
    "W-4c: 80% exactly passes a minimum of 80 (rounded down, both parts)")
check(cmd(seller, "wanted.candidates", { orderId = coinOnly.orderId }).rows[1] == nil
    and cmd(buyer, "wanted.candidates", { orderId = coinOnly.orderId }).error == "own_order",
    "W-4d: candidates list only the wanted type and refuse the buyer")
local used = native(seller, "Base.Axe", 1)[1]
used.condition = 9
check(cmd(seller, "wanted.fill", { orderId = coinOnly.orderId, option = 1, itemIds = { used:getID() }, unitPrice = 95 }).error == "not_new",
    "W-4e: a new-only order refuses a worn copy")

-- ---- W-5: offers, raise, dismiss ----
local o2 = coinOrder(buyer, "Base.Nails", 5, 10)
assert(o2.ok)
local function offer(p, args) args.orderId = args.orderId or o2.orderId; args.option = args.option or 1; return cmd(p, "wanted.offer", args) end
check(offer(seller, { unitPrice = 10, qty = 1 }).error == "offer_not_higher" and offer(seller, { unitPrice = 12, qty = 6 }).error == "qty_exceeded"
    and offer(seller, { unitPrice = pmax + 1, qty = 1 }).error == "price_range" and offer(seller, { unitPrice = 12, qty = 1, option = 2 }).error == "invalid_option"
    and offer(buyer, { unitPrice = 12, qty = 1 }).error == "own_order",
    "W-5a: an offer must be higher, within the units and the price range, on a coin option, and not the buyer's own")
check(offer(seller, { unitPrice = 12, qty = 1, memo = string.rep("a", 65) }).error == "invalid_args"
    and offer(seller, { unitPrice = 12, qty = 1, memo = "line\nbreak" }).error == "invalid_args",
    "W-5b: a memo over 64 characters or with a control character is invalid_args")
local o12 = offer(seller, { unitPrice = 12, qty = 3, memo = "new ones" })
local o15 = offer(seller2, { unitPrice = 15, qty = 2, memo = string.rep("b", 64) })
check(o12.ok and o15.ok and o15.offer.memo == string.rep("b", 64) and #notices(buyer, "wanted_offer") == 2
    and offer(seller, { unitPrice = 13, qty = 1 }).error == "offer_exists" and bal(su).reserved == 0,
    "W-5c: two offers (64 characters is fine), one per seller, nothing reserved; the buyer is told each time")
local savedOffers = Wd.OFFERS_MAX
Wd.OFFERS_MAX = 2
check(offer(mod, { unitPrice = 20, qty = 1 }).error == "offers_full", "W-5d: at OFFERS_MAX the next offer is offers_full")
Wd.OFFERS_MAX = savedOffers
local view = cmd(seller, "wanted.browse", {})
local row = nil
for _, r in ipairs(view.rows) do if r.id == o2.orderId then row = r end end
check(row and row.myOffer and row.myOffer.unitPrice == 12 and row.offers == nil and row.options[1].held == nil,
    "W-5e: the public row shows only the viewer's own offer and no held amounts")
local avail = bal(bu).available
local raised = cmd(buyer, "wanted.raise", { orderId = o2.orderId, option = 1, unitPrice = 12 })
local raiseRid = "want-" .. serial
check(raised.ok and raised.delta == 10 and raised.fee == 1 and raised.held == 60 and raised.met == 1
    and bal(bu).available == avail - 11 and #notices(seller, "wanted_raised") == 1 and #notices(seller2, "wanted_raised") == 0
    and #order(o2.orderId).offers == 1 and order(o2.orderId).offers[1].from == seller2:getUsername()
    and heldMatches(order(o2.orderId)) and reservedInvariant(),
    "W-5f: a raise reserves the difference x units, pays the fee on it, removes and tells only the offers it meets")
check(cmd(buyer, "wanted.raise", { requestId = raiseRid, orderId = o2.orderId, option = 1, unitPrice = 12 }).duplicate == true
    and cmd(buyer, "wanted.raise", { requestId = raiseRid, orderId = o2.orderId, option = 1, unitPrice = 13 }).error == "request_conflict"
    and cmd(buyer, "wanted.raise", { orderId = o2.orderId, option = 1, unitPrice = 12 }).error == "price_not_higher"
    and cmd(seller, "wanted.raise", { orderId = o2.orderId, option = 1, unitPrice = 14 }).error == "not_owner"
    and bal(bu).available == avail - 11,
    "W-5g: a resent raise is a duplicate, a changed one a conflict; never lower; only the buyer raises")
local raisedAgain = cmd(buyer, "wanted.raise", { requestId = raiseRid, orderId = o2.orderId, option = 1, unitPrice = 12 })
check(raisedAgain.duplicate == true and raisedAgain.currency == "survivor" and raisedAgain.held == 60 and raisedAgain.delta == 10
    and raisedAgain.fee == 1 and raisedAgain.met == 1 and raisedAgain.unitPrice == 12,
    "W-5g2: a resent raise answers with the first one's currency, reservation, difference, fee and offers met")
local poorRaise = cmd(buyer, "wanted.raise", { orderId = o2.orderId, option = 1, unitPrice = 1000 })
check(poorRaise.error == "insufficient_funds" and poorRaise.needed == (1000 - 12) * 5 + 494 and bal(bu).available == avail - 11,
    "W-5h: a raise the buyer cannot pay moves nothing")
local f2 = native(seller2, "Base.Nails", 1)
check(cmd(seller2, "wanted.fill", { orderId = o2.orderId, option = 1, itemIds = ids(f2), unitPrice = 12 }).ok
    and #order(o2.orderId).offers == 0, "W-5i: a delivery removes that seller's own offer")
offer(seller, { unitPrice = 20, qty = 1 })
check(cmd(buyer, "wanted.dismiss", { orderId = o2.orderId, from = su }).ok and #order(o2.orderId).offers == 0
    and cmd(buyer, "wanted.dismiss", { orderId = o2.orderId, from = su }).error == "unknown_offer"
    and #notices(seller, "wanted_raised") == 1,
    "W-5j: the buyer dismisses an offer without telling its seller; a second dismiss is unknown_offer")

-- ---- W-6: cancel, refund refused and retried, expiry ----
local resBefore, availBefore = bal(bu).reserved, bal(bu).available
local cancelled = cmd(buyer, "wanted.cancel", { orderId = o2.orderId })
check(cancelled.ok and cancelled.refunded.survivor == 48 and bal(bu).reserved == resBefore - 48
    and bal(bu).available == availBefore + 48 and order(o2.orderId) == nil and reservedInvariant(),
    "W-6a: cancel releases the reservation (the fee stays paid)")
local cancelRid = "want-" .. serial
local cancelAgain = cmd(buyer, "wanted.cancel", { requestId = cancelRid, orderId = o2.orderId })
local cancelOther = cmd(buyer, "wanted.cancel", { requestId = cancelRid, orderId = coinOnly.orderId })
check(cancelAgain.duplicate == true and cancelAgain.ok and cancelAgain.orderId == o2.orderId
    and cancelAgain.refunded.survivor == 48 and cancelOther.error == "request_conflict" and order(coinOnly.orderId) ~= nil
    and bal(bu).available == availBefore + 48,
    "W-6a2: a resent cancel answers the first refund; the same id for another order is request_conflict and cancels nothing")
local o3planks = native(buyer, "Base.Plank", 2)
local o3 = cmd(buyer, "wanted.create", { item = "Base.Nails", qty = 2, options = {
    { kind = "coin", currency = "cat", unitPrice = 5 }, { kind = "item", itemIds = ids(o3planks), perUnit = 1 } } })
local wallet = S.modData().wallets[bu].cat
wallet.reserved = wallet.reserved - 10                 -- the release cannot be posted
before = state(buyer)
local stuck = cmd(buyer, "wanted.cancel", { orderId = o3.orderId })
check(stuck.error == "refund_failed" and order(o3.orderId).blocked == "refund_failed" and order(o3.orderId).closing == "cancelled"
    and buyer.inventory.count("Base.Plank") == 0 and state(buyer) == before and Wd.stats().held == 1,
    "W-6b: a refused release keeps the order, its money and its lot exactly as they were and marks it held")
local n3 = native(seller, "Base.Nails", 1)
check(cmd(seller, "wanted.fill", { orderId = o3.orderId, option = 1, itemIds = ids(n3), unitPrice = 5 }).error == "order_held"
    and cmd(seller, "wanted.offer", { orderId = o3.orderId, option = 1, unitPrice = 9, qty = 1 }).error == "order_held",
    "W-6c: a held order takes no delivery and no offer")
wallet.reserved = wallet.reserved + 10
local _, plankLettersBefore = letters(bu, "return", "Base.Plank")
advance(Wd.SWEEP_EVERY_MS + 1)
fire("OnTickEvenPaused")
local _, plankLettersAfter = letters(bu, "return", "Base.Plank")
check(order(o3.orderId) == nil and plankLettersAfter - plankLettersBefore == 2 and Wd.stats().held == 0 and reservedInvariant(),
    "W-6d: the minute sweep retries the release and finishes the cancel")
check(Wd.mergeBlocker(bu) == "live_order" and Wd.mergeBlocker(su) == nil
    and S.Merge and (function()
        for _, why in ipairs(S.Merge.blockers(bu, su, {})) do if why == "live_order" then return true end end
        return false
    end)(),
    "W-6f: an open order blocks merging the buyer's name")

-- ---- W-7: admin ----
local list = cmd(mod, "admin.wanted", { action = "list" })
check(list.ok and list.total == S.modData().wanted.count and list.rows[1].offerCount ~= nil and list.rows[1].offers == nil
    and list.stats.orders == list.total and list.requestId ~= nil,
    "W-7a: a read role lists every order with counts but no offer text")
local denied = cmd(mod, "admin.wanted", { action = "cancel", orderId = coinOnly.orderId, reason = "nope" })
check(denied.error == "forbidden" and denied.rows == nil and denied.requestId ~= nil and order(coinOnly.orderId) ~= nil,
    "W-7b: a read-only role cannot cancel; the refusal carries no data")
check(cmd(admin, "admin.wanted", { action = "cancel", orderId = coinOnly.orderId, reason = "   " }).error == "reason_blank"
    and order(coinOnly.orderId) ~= nil, "W-7c: an admin cancel needs a real reason")
local adm = cmd(admin, "admin.wanted", { action = "cancel", orderId = coinOnly.orderId, reason = "duplicate order" })
local audit = EC.Export.auditEntries(1)[1]
check(adm.ok and adm.refunded.survivor == 95 and order(coinOnly.orderId) == nil and audit.action == "wanted"
    and audit.field == coinOnly.orderId and audit.target == bu and #notices(buyer, "wanted_cancelled") == 1
    and cmd(admin, "admin.system", {}).wanted.orders == S.modData().wanted.count,
    "W-7d: an admin cancel refunds, audits, tells the buyer, and admin.system counts what is left")
local o4 = coinOrder(buyer, "Base.Nails", 1, 7)
advance(EC.sandbox("MarketListingDays", 7) * 86400000 + 1)
fire("OnTickEvenPaused")
check(order(o4.orderId) == nil and S.modData().wanted.count == 0 and #notices(buyer, "wanted_expired") >= 1
    and Wd.mergeBlocker(bu) == nil and reservedInvariant(),
    "W-6e: expired orders are closed by the sweep, their buyer told, and the name can merge again")

-- ---- W-8: reply size at the caps, history ----
SV.WantedMaxPerPlayer, SV.MailboxPerAccount = 50, 500
local big = fakePlayer("w-big"); big.inventory = fakeInventory(5000)
ctx.setOnline({ admin, buyer, seller, mod, seller2, big })
assert(L.credit("w-big", "survivor", 5000000, "SYSTEM_MINT", { requestId = "w-big", reasonCode = "test" }).ok)
assert(L.credit("w-big", "cat", 5000000, "SYSTEM_MINT", { requestId = "w-bigc", reasonCode = "test" }).ok)
for i = 1, 50 do
    local lot = native(big, "Base.Nails", 50)
    local r = cmd(big, "wanted.create", { item = "Base.Axe", qty = 50, cond = { minPct = 1 }, options = {
        { kind = "coin", currency = "survivor", unitPrice = 1000 }, { kind = "coin", currency = "cat", unitPrice = 1000 },
        { kind = "item", itemIds = ids(lot), perUnit = 1 } } })
    assert(r.ok, tostring(r.error))
    local o = order(r.orderId)
    for k = 1, Wd.OFFERS_MAX do
        o.offers[k] = { from = string.rep("s", 60) .. k, option = 1, unitPrice = 1000000, qty = 50, memo = string.rep("m", 64), at = ctx.now() }
    end
end
local mine = cmd(big, "wanted.mine", {})
local page1 = cmd(big, "wanted.browse", {})
check(#mine.orders == 50 and S.wireBytes(mine) < S.REPLY_MAX_BYTES and #page1.rows == Wd.PAGE and S.wireBytes(page1) < S.REPLY_MAX_BYTES,
    "W-8a: fifty full orders with ten offers each fit one mine reply, a browse page carries twenty")
EC.Export.market(bu, { kind = "listed", listingId = "x", item = "Base.Nails", qty = 1, price = 1, currency = "survivor" })
proofSettle()
advance(700)
fire("OnClientCommand", EC.COMMAND_MODULE, "wanted.history", buyer, { requestId = "w-hist" })
proofPump(bu)
local histReply = ctx.lastSent("wanted.history").args
local onlyWanted, created = #histReply.entries > 0, 0
for _, e in ipairs(histReply.entries) do
    if string.sub(e.kind, 1, 7) ~= "wanted_" then onlyWanted = false end
    if e.kind == "wanted_created" then created = created + 1 end
end
check(histReply.requestId == "w-hist" and onlyWanted and created >= 6,
    "W-8b: wanted.history answers the buyer's wanted_ lines and nothing else of the market file")
SV.WantedMaxPerPlayer, SV.MailboxPerAccount, SV.MarketListingFeePercent, SV.MarketSalesTaxPercent = nil, nil, nil, nil
ctx.setOnline({})

-- ---- W-9: an offer made under a login name that was merged into another account ----
do
    local _, buyerM, aliasP = fresh("wm")
    local alias = aliasP:getUsername()
    local canon = fakePlayer("wm-canon")
    local o = coinOrder(buyerM, "Base.Nails", 5, 10)
    assert(cmd(aliasP, "wanted.offer", { orderId = o.orderId, option = 1, unitPrice = 12, qty = 2 }).ok)
    local id = S.modData().identity or {}
    S.modData().identity = id
    id.merged = id.merged or {}
    id.merged[alias] = { into = canon:getUsername() }
    ctx.setOnline({ buyerM, canon })
    cmd(canon, "wanted.mine", {})
    local row = nil
    for _, r in ipairs(cmd(canon, "wanted.browse", {}).rows) do if r.id == o.orderId then row = r end end
    local second = cmd(canon, "wanted.offer", { orderId = o.orderId, option = 1, unitPrice = 13, qty = 1 })
    local raised = cmd(buyerM, "wanted.raise", { orderId = o.orderId, option = 1, unitPrice = 12 })
    check(row and row.myOffer and row.myOffer.unitPrice == 12 and second.error == "offer_exists"
        and raised.met == 1 and #notices(canon, "wanted_raised") == 1 and #order(o.orderId).offers == 0,
        "W-9: an offer left under a merged login is the account's own: shown to it, counted once, its seller told on the account")
end

-- ---- W-10: a buy-order sale is in the market report's scan, not only in the daily rollup ----
do
    local admin10, buyer10, seller10 = fresh("wrp")
    local o = coinOrder(buyer10, "Base.Twine", 1, 10)
    assert(cmd(seller10, "wanted.fill", { orderId = o.orderId, option = 1, itemIds = ids(native(seller10, "Base.Twine", 1)), unitPrice = 10 }).ok)
    assert(proofSettle() == 0)
    cmd(admin10, "admin.report", { action = "market", days = 7, currency = "survivor", refresh = true })
    for _ = 1, 300 do
        if EC.Reports.status().state ~= "running" then break end
        fire("OnTickEvenPaused")
    end
    local m = cmd(admin10, "admin.report", { action = "market", days = 7, currency = "survivor" })
    local twine = nil
    for _, it in ipairs(m.items or {}) do if it.item == "Base.Twine" then twine = it end end
    check(m.state == "ready" and m.turnover.daily[#m.turnover.daily] == 10 and twine ~= nil and twine.amount == 10
        and twine.units == 1 and m.traders.daily[#m.traders.daily] == 2,
        "W-10: a 10-coin buy-order fill is turnover, a priced item and two traders in the market report")
end

-- ---- W-11: a localized search: the client's resolved item types widen the query before paging ----
do
    local _, buyer11 = fresh("w11")
    for _, item in ipairs({ "Base.Axe", "Base.Nails", "Base.Twine" }) do assert(coinOrder(buyer11, item, 1, 10).ok) end
    local function browse(args) return cmd(buyer11, "wanted.browse", args) end
    check(browse({ query = "zzlocal" }).total == 0 and browse({ query = "zzlocal", types = { "Base.Axe" } }).total == 1
        and browse({ types = { "Base.Axe" } }).total == 3 and browse({ query = "nails", types = { "Base.Axe" } }).total == 2,
        "W-11a: a translated name the server cannot read finds its orders through the client's types; types only widen a query")
    local savedPage = Wd.PAGE
    Wd.PAGE = 1
    local p2 = browse({ query = "zzlocal", types = { "Base.Axe", "Base.Twine" }, page = 2 })
    Wd.PAGE = savedPage
    check(p2.total == 2 and p2.pages == 2 and #p2.rows == 1 and p2.rows[1].item ~= "Base.Nails",
        "W-11b: the types are matched before paging: the second page holds the other matching order")
    local long = {}
    for i = 1, Mk.TYPES_MAX do long[i] = "Base.None" .. i end
    long[#long + 1] = "Base.Axe"
    check(browse({ query = "zzlocal", types = long }).total == 0 and browse({ query = "zzlocal", types = "Base.Axe" }).total == 0,
        "W-11c: the list is bounded at TYPES_MAX and anything but a list is ignored")
end

-- ---- W-12: the same localized search on every item board: market, auction, the admin listings,
-- auctions and buy orders (Mk.typesOf), matched before paging; one row per page proves it ----
do
    local admin12, buyer12, seller12 = fresh("w12")
    local items = { "Base.Axe", "Base.Nails", "Base.Hammer" }
    for _, item in ipairs(items) do
        assert(cmd(seller12, "market.list", { itemIds = ids(native(seller12, item)), price = 10 }).ok)
        assert(cmd(seller12, "auction.create", { itemIds = ids(native(seller12, item)), startPrice = 10, minutes = 720 }).ok)
        assert(coinOrder(buyer12, item, 1, 10).ok)
    end
    local two = { "Base.Axe", "Base.Hammer" }
    local saved = { Mk.PAGE, S.Auction.PAGE, Wd.PAGE }
    Mk.PAGE, S.Auction.PAGE, Wd.PAGE = 1, 1, 1
    -- a keyword no English name holds finds nothing alone, and both typed rows with the types:
    -- the second page holds the other one, so the match ran before the page was cut
    local function found(p, command, args, key)
        local bare = cmd(p, command, copy(args))
        args.types, args.page = two, 2
        local typed = cmd(p, command, args)
        local rows = typed[key] or {}
        return bare.total == 0 and typed.total == 2 and typed.pages == 2 and #rows == 1 and rows[1].item ~= "Base.Nails"
    end
    check(found(buyer12, "market.browse", { query = "zzlocal" }, "items"),
        "W-12a: market.browse matches the client's item types before paging")
    check(found(buyer12, "auction.browse", { query = "zzlocal" }, "items"),
        "W-12b: auction.browse matches the client's item types before paging")
    check(found(admin12, "admin.listings", { action = "list", query = "zzlocal" }, "items"),
        "W-12c: admin.listings matches the client's item types before paging")
    check(found(admin12, "admin.auctions", { action = "list", query = "zzlocal" }, "items"),
        "W-12d: admin.auctions matches the client's item types before paging")
    check(found(admin12, "admin.wanted", { action = "list", query = "zzlocal" }, "rows"),
        "W-12e: admin.wanted list matches the client's item types before paging")
    Mk.PAGE, S.Auction.PAGE, Wd.PAGE = saved[1], saved[2], saved[3]
    local long = {}
    for i = 1, Mk.TYPES_MAX do long[i] = "Base.None" .. i end
    long[#long + 1] = "Base.Axe"
    local set = Mk.typesOf({ string.rep("x", Mk.TYPE_CHARS + 1), "", 7, "Base.Axe" })
    check(cmd(buyer12, "market.browse", { query = "zzlocal", types = long }).total == 0
        and cmd(buyer12, "auction.browse", { query = "zzlocal", types = "Base.Axe" }).total == 0
        and cmd(admin12, "admin.listings", { action = "list", types = two }).total == 3
        and set["Base.Axe"] and EC.countKeys(set) == 1 and Mk.typesOf("Base.Axe") == nil,
        "W-12f: the types are bounded (TYPES_MAX entries, TYPE_CHARS bytes, strings only), a non-list is ignored, and alone they filter nothing")
end

-- ---- W-13: an offer's memo lives in a server-private file, never in Global ModData ----
do
    local _, buyerM, sellerM = fresh("wmm")
    local thirdM = fakePlayer("wmm-third"); thirdM.inventory = fakeInventory(50)
    ctx.setOnline({ buyerM, sellerM, thirdM })
    cmd(thirdM, "wanted.mine", {})
    local su, tu = sellerM:getUsername(), thirdM:getUsername()
    local function holds(t, needle, depth)
        if type(t) == "string" then return string.find(t, needle, 1, true) ~= nil end
        if type(t) ~= "table" or depth > 12 then return false end
        for k, v in pairs(t) do
            if holds(k, needle, depth + 1) or holds(v, needle, depth + 1) then return true end
        end
        return false
    end
    local function fileText()
        local f = ctx.files()[Wd.MEMO_FILE]
        return f and table.concat(f.lines, "\n") or ""
    end
    local function lastLine()
        local f = ctx.files()[Wd.MEMO_FILE]
        return f and #f.lines > 0 and EC.jsonDecode(f.lines[#f.lines]) or {}
    end
    local function mineMemo(orderId, from)
        for _, o in ipairs(cmd(buyerM, "wanted.mine", {}).orders) do
            if o.id == orderId then
                for _, f in ipairs(o.offers) do if f.from == from then return f.memo end end
            end
        end
        return nil
    end
    local function ask(p, orderId, price, memo)
        return cmd(p, "wanted.offer", { orderId = orderId, option = 1, unitPrice = price, qty = 1, memo = memo })
    end

    local o = coinOrder(buyerM, "Base.Nails", 5, 10)
    local first = ask(sellerM, o.orderId, 12, "memo-alpha-1")
    local told = notices(buyerM, "wanted_offer")
    check(first.ok and not holds(S.modData(), "memo-alpha-1", 0) and string.find(fileText(), "memo-alpha-1", 1, true) ~= nil
        and mineMemo(o.orderId, su) == "memo-alpha-1" and told[#told].memo == "memo-alpha-1" and first.offer.memo == "memo-alpha-1",
        "W-13a: an offer's memo is in the private file and nowhere under the ModData root; the buyer's mine view, the notice and the author's own reply carry it")
    local beforeSecond = copy(S.modData())
    assert(ask(thirdM, o.orderId, 13, "memo-beta-2").ok)
    restart(copy(S.modData()))
    check(mineMemo(o.orderId, su) == "memo-alpha-1" and mineMemo(o.orderId, tu) == "memo-beta-2",
        "W-13b: the memos survive a restart: they are read back from the file")
    restart(beforeSecond)
    check(mineMemo(o.orderId, su) == "memo-alpha-1" and mineMemo(o.orderId, tu) == nil
        and string.find(fileText(), "memo-beta-2", 1, true) == nil,
        "W-13c: a world rollback that took an offer back prunes its memo from the file at the next start")

    assert(ask(thirdM, o.orderId, 20, "memo-gamma-3").ok)
    assert(cmd(buyerM, "wanted.dismiss", { orderId = o.orderId, from = tu }).ok)
    local dismissed = lastLine()
    assert(cmd(buyerM, "wanted.raise", { orderId = o.orderId, option = 1, unitPrice = 12 }).ok)
    local met = lastLine()
    local o2 = coinOrder(buyerM, "Base.Nails", 2, 10)
    assert(ask(sellerM, o2.orderId, 11, "memo-eps-5").ok)
    assert(cmd(sellerM, "wanted.fill", { orderId = o2.orderId, option = 1, itemIds = ids(native(sellerM, "Base.Nails", 1)), unitPrice = 10 }).ok)
    local filled = lastLine()
    assert(ask(thirdM, o.orderId, 15, "memo-delta-4").ok)
    assert(cmd(buyerM, "wanted.cancel", { orderId = o.orderId }).ok)
    local closed = lastLine()
    restart(copy(S.modData()))
    check(dismissed.k == "del" and dismissed.f == tu and met.k == "del" and met.f == su and filled.k == "del" and filled.f == su
        and filled.o == o2.orderId and closed.k == "del" and closed.f == tu and closed.o == o.orderId and fileText() == "",
        "W-13d: a dismiss, a raise that meets the offer, the seller's own delivery and closing the order each drop the memo; the next start keeps none")

    local o3 = coinOrder(buyerM, "Base.Nails", 1, 10)
    local saved = copy(S.modData())
    saved.wanted.orders[o3.orderId].offers[1] = { from = tu, option = 1, unitPrice = 11, qty = 1, memo = "memo-legacy-6", at = ctx.now() }
    restart(saved)
    check(not holds(S.modData(), "memo-legacy-6", 0) and mineMemo(o3.orderId, tu) == "memo-legacy-6"
        and string.find(fileText(), "memo-legacy-6", 1, true) ~= nil,
        "W-13e: an offer an older build saved with its memo hands the memo to the file at load and keeps none in ModData")

    local realWriter, realReader = getFileWriter, getFileReader
    getFileWriter = function(path, create, append)
        if path == Wd.MEMO_FILE then return nil end
        return realWriter(path, create, append)
    end
    local denied = ask(sellerM, o3.orderId, 12, "memo-lost-7")
    local plain = ask(sellerM, o3.orderId, 12)
    getFileWriter = realWriter
    check(denied.error == "memo_unavailable" and plain.ok and #S.modData().wanted.orders[o3.orderId].offers == 2
        and not holds(S.modData(), "memo-lost-7", 0),
        "W-13f: a memo the file cannot take refuses the offer and changes nothing; the same offer without one goes through")
    local o4 = coinOrder(buyerM, "Base.Nails", 1, 10)
    local kept = fileText()
    getFileReader = function(path, create)
        if path == Wd.MEMO_FILE then return nil end
        return realReader(path, create)
    end
    restart(copy(S.modData()))
    local blind = ask(thirdM, o4.orderId, 12, "memo-x-8")
    getFileReader = realReader
    local blindKept = fileText()
    restart(copy(S.modData()))
    check(blind.error == "memo_unavailable" and blindKept == kept and mineMemo(o3.orderId, tu) == "memo-legacy-6",
        "W-13g: a memo file that exists but cannot be read is never rewritten and takes no new memo; once readable the memos are back")
    ctx.setOnline({})
end
