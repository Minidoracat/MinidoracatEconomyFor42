-- MinidoracatEconomyFor42 - central escrow market (server authority; spec 12 stage D, 19.7).
--
-- Listings live in Global ModData with a bounded item snapshot (ECCodec); the physical item left
-- the seller through `list-out` (rule two): the seller's own modData records pendingOuts[id]
-- before the item is removed, so a world rollback can rebuild the listing from the player save
-- (rule three, rows 4-6, in ECMailbox.reconcileOuts). A sale moves money and the snapshot in one
-- tick (buyer -price, seller +price-tax, tax burned, snapshot into the buyer's mailbox) and then
-- claim-in hands the rebuilt item over. Cancels and expiries return the snapshot to the seller's
-- mailbox the same way. Money never moves without the listing changing in the same tick.

if not MinidoracatEconomy or not MinidoracatEconomy.Codec then
    require "MinidoracatEconomy/ECCodec"
end
local EC = MinidoracatEconomy
local S = EC and EC.Server
local L = EC and EC.Ledger
local X = EC and EC.Export
local R = EC and EC.Rewards
local T = EC and EC.Terminal
local M = EC and EC.Mailbox
local Codec = EC and EC.Codec
if not S or not S.AUTHORITY or not L or not X or not R or not T or not M or not Codec then
    return
end

EC.Market = EC.Market or {}
local Mk = EC.Market

Mk.BURN_ACCOUNT = "SYSTEM_BURN"
Mk.MAX_LISTINGS = 2000            -- server-wide (spec 20 budget)
Mk.PAGE = 20
Mk.CANDIDATES_MAX = 200
Mk.PENDING_MAX = 64               -- pendingOuts per player (spec 19.7 rule two)
Mk.SWEEP_EVERY_MS = 60000
Mk.QUERY_MAX = 64

local md = nil
local lastSweep = 0

-- ---------- state ----------

local function ownerSet(username, create)
    local s = md.market.byOwner[username]
    if not s and create then
        s = {}
        md.market.byOwner[username] = s
    end
    return s
end

local function ownerCount(username)
    local s = ownerSet(username, false)
    if not s then return 0 end
    local n = 0
    for _ in pairs(s) do n = n + 1 end
    return n
end

local function removeListing(id)
    local l = md.market.listings[id]
    if not l then return nil end
    md.market.listings[id] = nil
    md.market.count = math.max(0, md.market.count - 1)
    local s = ownerSet(l.seller, false)
    if s then
        s[id] = nil
        local empty = true
        for _ in pairs(s) do empty = false break end
        if empty then md.market.byOwner[l.seller] = nil end
    end
    return l
end

local function addListing(l)
    md.market.listings[l.id] = l
    md.market.count = md.market.count + 1
    ownerSet(l.seller, true)[l.id] = true
end

local function marketCurrency()
    for id, c in pairs(EC.CURRENCIES) do if c.marketUnit then return id end end
    return R.CURRENCY
end

local function pct(amount, percent)
    if percent <= 0 then return 0 end
    return math.max(1, math.ceil(amount * percent / 100))
end

local function isInt(v, lo, hi)
    return type(v) == "number" and v == math.floor(v) and v >= lo and v <= hi
end

local function validRequest(args)
    return type(args) == "table" and type(args.requestId) == "string" and args.requestId ~= "" and #args.requestId <= 96
end

-- ---------- player side (pendingOuts, rule two) ----------

local function playerData(player)
    local t = player:getModData()
    local p = t[EC.PLAYER_MODDATA_KEY]
    if type(p) ~= "table" then
        p = {}
        t[EC.PLAYER_MODDATA_KEY] = p
    end
    if type(p.pendingOuts) ~= "table" then p.pendingOuts = {} end
    return p
end

local function transmit(player)
    pcall(function() player:transmitModData() end)
end

local function addPending(p, id, rec)
    p.pendingOuts[id] = rec
    local n, oldest, oldestSeq = 0, nil, nil
    for k, v in pairs(p.pendingOuts) do
        n = n + 1
        if not oldestSeq or (v.seq or 0) < oldestSeq then oldest, oldestSeq = k, v.seq or 0 end
    end
    if n > Mk.PENDING_MAX and oldest then
        X.emit("ledger.anomaly", { kind = "pending_evicted", listingId = oldest })
        p.pendingOuts[oldest] = nil
    end
end

-- ---------- views ----------

local function view(l)
    local s = l.snapshot or {}
    return {
        id = l.id, seller = l.seller, item = l.item, name = l.name, category = l.category,
        price = l.price, at = l.at, expiresAt = l.expiresAt,
        condition = s.condition, uses = s.uses, fluid = s.fluid and s.fluid.name or nil, fluidAmount = s.fluid and s.fluid.amount or nil,
    }
end

-- Search space on the server is what it can compare without translations: fullType, the script
-- DisplayName (English) and the seller; the client re-filters the page by translated names.
local function matches(l, category, query)
    if category and l.category ~= category then return false end
    if query then
        local hay = string.lower(tostring(l.item) .. " " .. tostring(l.name or "") .. " " .. tostring(l.seller))
        if not string.find(hay, query, 1, true) then return false end
    end
    return true
end

function Mk.browse(username, args)
    args = type(args) == "table" and args or {}
    local category = type(args.category) == "string" and args.category ~= "" and args.category or nil
    local query = type(args.query) == "string" and string.lower(string.sub((string.gsub(args.query, "^%s*(.-)%s*$", "%1")), 1, Mk.QUERY_MAX)) or ""
    if query == "" then query = nil end
    local sort = args.sort == "price" and "price" or (args.sort == "price_desc" and "price_desc" or "time")
    local page = isInt(args.page, 1, 100000) and args.page or 1
    local rows = {}
    for _, l in pairs(md.market.listings) do
        if matches(l, category, query) then rows[#rows + 1] = l end
    end
    EC.sortSafe(rows, function(a, b)
        if sort == "price" then
            if a.price ~= b.price then return a.price < b.price end
        elseif sort == "price_desc" then
            if a.price ~= b.price then return a.price > b.price end
        end
        if a.at ~= b.at then return a.at > b.at end
        return a.id < b.id
    end)
    local total = #rows
    local pages = math.max(1, math.ceil(total / Mk.PAGE))
    if page > pages then page = pages end
    local out = {}
    for i = (page - 1) * Mk.PAGE + 1, math.min(total, page * Mk.PAGE) do
        out[#out + 1] = view(rows[i])
    end
    local categories = {}
    for _, l in pairs(md.market.listings) do categories[l.category or "other"] = true end
    local catList = {}
    for c in pairs(categories) do catList[#catList + 1] = c end
    EC.sortSafe(catList, function(a, b) return a < b end)
    return {
        page = page, pages = pages, total = total, items = out, categories = catList,
        currency = marketCurrency(), sort = sort, category = category, query = query,
        mine = ownerCount(username), maxListings = EC.sandbox("MarketMaxListings", 5),
        feePercent = EC.sandbox("MarketListingFeePercent", 2), taxPercent = EC.sandbox("MarketSalesTaxPercent", 5),
        priceMin = EC.sandbox("MarketPriceMin", 1), priceMax = EC.sandbox("MarketPriceMax", 1000000),
        listingDays = EC.sandbox("MarketListingDays", 7),
    }
end

function Mk.mine(username)
    local out = {}
    local s = ownerSet(username, false)
    if s then
        for id in pairs(s) do
            local l = md.market.listings[id]
            if l then out[#out + 1] = view(l) end
        end
    end
    EC.sortSafe(out, function(a, b) return a.at > b.at end)
    return out
end

-- What the seller can list from the top level of the backpack: every item with the verdict and
-- the reason, so the picker can grey out the rest instead of round-tripping per item.
function Mk.candidates(player)
    local out = {}
    local inv = player:getInventory()
    if not inv then return out end
    local ok, items = pcall(function() return inv:getItems() end)
    if not ok or not items then return out end
    for i = 0, items:size() - 1 do
        if #out >= Mk.CANDIDATES_MAX then break end
        local it = items:get(i)
        if it then
            local pass, reason, key = Codec.check(it)
            local id, fullType = nil, nil
            pcall(function() id = it:getID() fullType = it:getFullType() end)
            if id and fullType then
                local row = { itemId = id, item = fullType, ok = pass == true, reason = (not pass) and reason or nil, modDataKey = key }
                pcall(function()
                    row.condition = it:getCondition()
                    row.uses = it:getCurrentUses()
                    row.category = it:getDisplayCategory()
                end)
                out[#out + 1] = row
            end
        end
    end
    return out
end

-- ---------- list-out (rule two) ----------

local function findItem(inv, itemId)
    local found = nil
    pcall(function() found = inv:getItemWithID(itemId) end)
    if not found then return nil end
    -- top level only: the item must be directly in the backpack (bags are not scanned by the picker)
    local ok, items = pcall(function() return inv:getItems() end)
    if not ok or not items then return nil end
    for i = 0, items:size() - 1 do
        if items:get(i) == found then return found end
    end
    return nil
end

function Mk.list(player, args)
    local username = player:getUsername()
    if not validRequest(args) or not isInt(args.itemId, -2147483648, 2147483647) then return { ok = false, error = "invalid_args" } end
    local prior = L.priorResult("list:" .. username .. ":" .. args.requestId)
    if prior then return { ok = prior.ok, duplicate = true, error = prior.error } end
    local price = args.price
    local pmin, pmax = EC.sandbox("MarketPriceMin", 1), EC.sandbox("MarketPriceMax", 1000000)
    if not isInt(price, pmin, pmax) then return { ok = false, error = "price_range", min = pmin, max = pmax } end
    if not T.near(player) then return { ok = false, error = "not_at_terminal" } end
    if L.isFrozen(username) then return { ok = false, error = "account_frozen" } end
    if ownerCount(username) >= EC.sandbox("MarketMaxListings", 5) then return { ok = false, error = "too_many_listings" } end
    if md.market.count >= Mk.MAX_LISTINGS then return { ok = false, error = "market_full" } end
    local inv = player:getInventory()
    local item = inv and findItem(inv, args.itemId) or nil
    if not item then return { ok = false, error = "item_not_found" } end
    local pass, reason, key = Codec.check(item)
    if not pass then return { ok = false, error = reason, modDataKey = key } end
    local currency = marketCurrency()
    local fee = pct(price, EC.sandbox("MarketListingFeePercent", 2))
    if fee > 0 and L.getBalance(username, currency).available < fee then return { ok = false, error = "insufficient_funds", fee = fee } end

    local ms = EC.now()
    Codec.detachParts(item, inv)
    local snapshot = Codec.snapshot(item)
    local id = S.newId()
    local _, seq = EC.parseId(id)
    -- phase 1: the seller's own save remembers the operation before the item leaves the backpack
    local p = playerData(player)
    addPending(p, id, { itemId = args.itemId, snapshot = snapshot, kind = "listing", price = price, seq = seq, epoch = md.meta.epoch, at = ms })
    transmit(player)
    -- phase 2: the item leaves the backpack
    inv:Remove(item)
    sendRemoveItemFromContainer(inv, item)
    -- phase 3: listing + fee in ModData (same tick). pending stays until reconcile clears it.
    local name, category = nil, nil
    pcall(function() name = ScriptManager.instance:FindItem(snapshot.type):getDisplayName() end)
    pcall(function() category = item:getDisplayCategory() end)
    local l = {
        id = id, seller = username, item = snapshot.type, snapshot = snapshot, price = price, fee = fee,
        at = ms, expiresAt = ms + EC.sandbox("MarketListingDays", 7) * 86400000,
        category = type(category) == "string" and category or "other", name = type(name) == "string" and name or nil,
    }
    addListing(l)
    if fee > 0 then
        local res = L.debit(username, currency, fee, Mk.BURN_ACCOUNT, {
            kind = "market_fee", requestId = "list:" .. username .. ":" .. args.requestId, reasonCode = "market_fee",
            payload = { item = snapshot.type, qty = 1, listingId = id },
        })
        if not res.ok then
            -- balance was checked above; only a ledger-level refusal can land here (frozen mid-tick)
            removeListing(id)
            local back = Codec.rebuild(snapshot)
            if back then inv:AddItem(back) sendAddItemToContainer(inv, back) end
            p.pendingOuts[id] = nil
            transmit(player)
            return { ok = false, error = res.error }
        end
    end
    X.emit("market.listed", { listingId = id, seller = username, item = snapshot.type, price = price, fee = fee, currency = currency, expiresAt = l.expiresAt })
    return { ok = true, listingId = id, fee = fee, expiresAt = l.expiresAt }
end

-- ---------- returns (cancel / expiry / admin delist) ----------

-- Listing -> seller mailbox. `force` lets system returns exceed the mailbox cap (spec 12 stage D).
local function returnListing(l, reasonKind, force)
    if not force and not M.hasFreeSlot(l.seller) then return false, "mailbox_full" end
    removeListing(l.id)
    local entry = M.add(l.seller, { kind = "return", item = l.item, qty = 1, txId = nil, price = l.price, snapshot = l.snapshot, listingId = l.id })
    X.emit("market." .. reasonKind, { listingId = l.id, seller = l.seller, item = l.item, price = l.price, mailId = entry.id })
    return true, entry
end

function Mk.cancel(player, args)
    local username = player:getUsername()
    if not validRequest(args) or type(args.listingId) ~= "string" then return { ok = false, error = "invalid_args" } end
    if not T.near(player) then return { ok = false, error = "not_at_terminal" } end
    local l = md.market.listings[args.listingId]
    if not l then return { ok = false, error = "unknown_listing" } end
    if l.seller ~= username then return { ok = false, error = "not_owner" } end
    local ok, entryOrErr = returnListing(l, "cancelled", false)
    if not ok then return { ok = false, error = entryOrErr } end
    local claim = M.claim(player, entryOrErr.id)
    return { ok = true, listingId = l.id, mailId = entryOrErr.id, delivered = claim.ok == true, deliveryError = (not claim.ok) and claim.error or nil }
end

function Mk.delist(admin, listingId, reason)
    local l = md.market.listings[listingId]
    if not l then return false, "unknown_listing" end
    returnListing(l, "delisted", true)
    X.audit({ action = "delist", admin = admin, target = l.seller, field = listingId, before = tostring(l.item), after = tostring(l.price), reason = reason })
    return true
end

-- ---------- sale ----------

function Mk.buy(player, args)
    local username = player:getUsername()
    if not validRequest(args) or type(args.listingId) ~= "string" then return { ok = false, error = "invalid_args" } end
    local prior = L.priorResult("buy:" .. username .. ":" .. args.requestId)
    if prior then return { ok = prior.ok, txId = prior.txId, duplicate = true, error = prior.error } end
    if not T.near(player) then return { ok = false, error = "not_at_terminal" } end
    if L.isFrozen(username) then return { ok = false, error = "account_frozen" } end
    local l = md.market.listings[args.listingId]
    if not l then return { ok = false, error = "unknown_listing" } end
    if l.seller == username then return { ok = false, error = "own_listing" } end
    if args.price ~= nil and args.price ~= l.price then return { ok = false, error = "price_changed", price = l.price } end
    if not M.hasFreeSlot(username) then return { ok = false, error = "mailbox_full" } end
    local currency = marketCurrency()
    if L.getBalance(username, currency).available < l.price then return { ok = false, error = "insufficient_funds" } end
    local tax = pct(l.price, EC.sandbox("MarketSalesTaxPercent", 5))
    if tax >= l.price then tax = l.price - 1 end
    if tax < 0 then tax = 0 end
    local postings = {
        { account = username, currency = currency, amount = -l.price },
        { account = l.seller, currency = currency, amount = l.price - tax },
    }
    if tax > 0 then postings[#postings + 1] = { account = Mk.BURN_ACCOUNT, currency = currency, amount = tax } end
    local res = L.post({
        kind = "market_buy", requestId = "buy:" .. username .. ":" .. args.requestId, reasonCode = "market_buy", actor = username,
        payload = { item = l.item, qty = 1, listingId = l.id, seller = l.seller, buyer = username, tax = tax },
        postings = postings,
    })
    if not res.ok then return { ok = false, error = res.error } end
    removeListing(l.id)
    local entry = M.add(username, { kind = "market", item = l.item, qty = 1, txId = res.txId, price = l.price, snapshot = l.snapshot, listingId = l.id })
    X.emit("market.sold", { listingId = l.id, seller = l.seller, buyer = username, item = l.item, price = l.price, tax = tax, currency = currency, txId = res.txId, mailId = entry.id })
    local claim = M.claim(player, entry.id)
    return {
        ok = true, txId = res.txId, listingId = l.id, mailId = entry.id, item = l.item, price = l.price, tax = tax, currency = currency,
        delivered = claim.ok == true, deliveryError = (not claim.ok) and claim.error or nil,
        balance = L.getBalance(username, currency).available,
    }
end

-- ---------- expiry ----------

-- ponytail: full scan once a minute (<= MAX_LISTINGS rows); index by expiresAt if that ever shows.
function Mk.onTick()
    if not md then return end
    local ms = EC.now()
    if ms - lastSweep < Mk.SWEEP_EVERY_MS then return end
    lastSweep = ms
    local dead = {}
    for _, l in pairs(md.market.listings) do
        if (l.expiresAt or 0) <= ms then dead[#dead + 1] = l end
    end
    for _, l in ipairs(dead) do returnListing(l, "expired", true) end
end

-- ---------- rebuild from a pending record (rule three row 4, called by ECMailbox.reconcileOuts) ----------

function Mk.restoreFromPending(username, id, pend)
    if md.market.listings[id] then return false end
    local l = {
        id = id, seller = username, item = pend.snapshot and pend.snapshot.type or nil, snapshot = pend.snapshot, price = pend.price, fee = 0,
        at = pend.at or EC.now(), expiresAt = (pend.at or EC.now()) + EC.sandbox("MarketListingDays", 7) * 86400000, category = "other",
    }
    if type(l.item) ~= "string" or not isInt(l.price, 1, 1000000000) then return false end
    pcall(function()
        local script = ScriptManager.instance:FindItem(l.item)
        l.name = script:getDisplayName()
        l.category = script:getDisplayCategory() or "other"
    end)
    addListing(l)
    return true
end

function Mk.hasListing(id)
    return md.market.listings[id] ~= nil
end

function Mk.stats()
    return { listings = md.market.count, max = Mk.MAX_LISTINGS }
end

-- ---------- commands ----------

S.handlers["market.browse"] = function(player, args)
    local res = Mk.browse(player:getUsername(), args)
    res.atTerminal = T.near(player)
    S.reply(player, "market.browse", res)
end

S.handlers["market.mine"] = function(player, args)
    S.reply(player, "market.mine", { items = Mk.mine(player:getUsername()), maxListings = EC.sandbox("MarketMaxListings", 5), atTerminal = T.near(player) })
end

S.handlers["market.candidates"] = function(player, args)
    S.reply(player, "market.candidates", {
        items = Mk.candidates(player), atTerminal = T.near(player),
        feePercent = EC.sandbox("MarketListingFeePercent", 2), taxPercent = EC.sandbox("MarketSalesTaxPercent", 5),
        priceMin = EC.sandbox("MarketPriceMin", 1), priceMax = EC.sandbox("MarketPriceMax", 1000000),
        mine = ownerCount(player:getUsername()), maxListings = EC.sandbox("MarketMaxListings", 5),
    })
end

S.handlers["market.list"] = function(player, args)
    local res = Mk.list(player, args)
    res.requestId = type(args) == "table" and args.requestId or nil
    res.mine = Mk.mine(player:getUsername())
    S.reply(player, "market.list", res)
end

S.handlers["market.buy"] = function(player, args)
    local res = Mk.buy(player, args)
    res.requestId = type(args) == "table" and args.requestId or nil
    res.unclaimed = M.unclaimed(player:getUsername())
    S.reply(player, "market.buy", res)
end

S.handlers["market.cancel"] = function(player, args)
    local res = Mk.cancel(player, args)
    res.requestId = type(args) == "table" and args.requestId or nil
    res.mine = Mk.mine(player:getUsername())
    res.unclaimed = M.unclaimed(player:getUsername())
    S.reply(player, "market.cancel", res)
end

function Mk.init(root)
    md = root
    md.market = md.market or { listings = {}, byOwner = {}, count = 0 }
    lastSweep = 0
end

S.Market = Mk
S.onInit(Mk.init)
Events.OnTickEvenPaused.Add(Mk.onTick)
return Mk
