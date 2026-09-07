-- MinidoracatEconomyFor42 - auctions (server authority; spec 12 stage F, 10.4, 11.1, 16.3).
--
-- An auction is an escrow listing with a clock: the seller's items leave the backpack through the
-- same three-phase list-out as a market listing (pendingOuts kind "auction", rebuilt from the
-- player save after a world rollback), the highest bid is money the bidder still owns but cannot
-- spend (ledger bucket "reserved": one tx moves -X available / +X reserved on the bidder's own
-- wallet, the previous highest bidder is released in the same tick), and expiry settles in one
-- tick: reserved -> seller minus tax, snapshot -> winner's mailbox; no bid -> back to the seller.
-- Restarts: the auction table lives in Global ModData, the sweep resumes; downtime measured from
-- heartbeat.json (spec 12 stage F policy): <= 5 min nothing, 5 min .. 24 h every active auction
-- is extended by the downtime, > 24 h every auction is cancelled (items back, reserves released).
--
-- Engine: nothing new beyond ECMarket; the clock is getTimestampMs (OnTickEvenPaused).

if not MinidoracatEconomy or not MinidoracatEconomy.Market then
    require "MinidoracatEconomy/ECMarket"
end
local EC = MinidoracatEconomy
local S = EC and EC.Server
local L = EC and EC.Ledger
local X = EC and EC.Export
local T = EC and EC.Terminal
local M = EC and EC.Mailbox
local Mk = EC and EC.Market
local Codec = EC and EC.Codec
if not S or not S.AUTHORITY or not L or not X or not T or not M or not Mk or not Codec then
    return
end

EC.Auction = EC.Auction or {}
local Au = EC.Auction

Au.RESERVED_KIND = "auction_bid"
Au.MAX_AUCTIONS = 1000            -- server-wide
Au.PAGE = 20
Au.SWEEP_EVERY_MS = 60000
Au.DOWNTIME_IGNORE_MS = 5 * 60000
Au.DOWNTIME_CANCEL_MS = 24 * 3600000

local md = nil
local lastSweep = 0

-- ---------- options ----------

local function hoursRange()
    local lo, hi = EC.sandbox("AuctionMinHours", 6), EC.sandbox("AuctionMaxHours", 72)
    if hi < lo then hi = lo end
    return lo, hi
end

local function minIncrement(current)
    local pct = EC.sandbox("AuctionMinIncrementPercent", 5)
    return math.max(1, math.ceil(current * pct / 100))
end

local function currency()
    for id, c in pairs(EC.CURRENCIES) do if c.marketUnit then return id end end
    return EC.Rewards.CURRENCY
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

-- ---------- state ----------

local function ownerSet(username, create)
    local s = md.auctions.byOwner[username]
    if not s and create then
        s = {}
        md.auctions.byOwner[username] = s
    end
    return s
end

function Au.ownerCount(username)
    local s = ownerSet(username, false)
    if not s then return 0 end
    local n = 0
    for _ in pairs(s) do n = n + 1 end
    return n
end

local function add(a)
    md.auctions.items[a.id] = a
    md.auctions.count = md.auctions.count + 1
    ownerSet(a.seller, true)[a.id] = true
end

local function remove(id)
    local a = md.auctions.items[id]
    if not a then return nil end
    md.auctions.items[id] = nil
    md.auctions.count = math.max(0, md.auctions.count - 1)
    local s = ownerSet(a.seller, false)
    if s then
        s[id] = nil
        local empty = true
        for _ in pairs(s) do empty = false break end
        if empty then md.auctions.byOwner[a.seller] = nil end
    end
    return a
end

function Au.hasAuction(id) return md.auctions.items[id] ~= nil end

function Au.stats()
    return { auctions = md.auctions.count, max = Au.MAX_AUCTIONS }
end

-- ---------- views ----------

local function view(a, username)
    local s = a.snapshot or {}
    return {
        id = a.id, seller = a.seller, item = a.item, name = a.name, category = a.category, qty = a.qty or 1,
        startPrice = a.startPrice, bid = a.highest and a.highest.amount or nil, bidder = a.highest and a.highest.bidder or nil,
        bids = a.bids or 0, at = a.at, expiresAt = a.expiresAt,
        minNext = Au.minNext(a),
        mine = a.seller == username, leading = a.highest ~= nil and a.highest.bidder == username,
        condition = s.condition, uses = s.uses, fluid = s.fluid and s.fluid.name or nil, fluidAmount = s.fluid and s.fluid.amount or nil,
    }
end

-- The smallest bid the next bidder may place.
function Au.minNext(a)
    if a.highest then return a.highest.amount + minIncrement(a.highest.amount) end
    return a.startPrice
end

Au.SORTS = {
    ending = { key = function(a) return a.expiresAt or 0 end, desc = false },
    ending_desc = { key = function(a) return a.expiresAt or 0 end, desc = true },
    time = { key = function(a) return a.at or 0 end, desc = true },
    time_asc = { key = function(a) return a.at or 0 end, desc = false },
    price = { key = function(a) return a.highest and a.highest.amount or a.startPrice end, desc = false },
    price_desc = { key = function(a) return a.highest and a.highest.amount or a.startPrice end, desc = true },
    name = { key = function(a) return string.lower(tostring(a.name or a.item or "")) end, desc = false },
    name_desc = { key = function(a) return string.lower(tostring(a.name or a.item or "")) end, desc = true },
    bids = { key = function(a) return a.bids or 0 end, desc = false },
    bids_desc = { key = function(a) return a.bids or 0 end, desc = true },
}

function Au.browse(username, args)
    args = type(args) == "table" and args or {}
    local query = type(args.query) == "string" and string.lower(string.sub((string.gsub(args.query, "^%s*(.-)%s*$", "%1")), 1, 64)) or ""
    if query == "" then query = nil end
    local sort = Au.SORTS[args.sort] and args.sort or "ending"
    local page = isInt(args.page, 1, 100000) and args.page or 1
    local rows = {}
    for _, a in pairs(md.auctions.items) do
        local hay = string.lower(tostring(a.item) .. " " .. tostring(a.name or "") .. " " .. tostring(a.seller))
        if not query or string.find(hay, query, 1, true) then rows[#rows + 1] = a end
    end
    local key, desc = Au.SORTS[sort].key, Au.SORTS[sort].desc
    EC.sortSafe(rows, function(a, b)
        local av, bv = key(a), key(b)
        if av ~= bv then
            if desc then return av > bv end
            return av < bv
        end
        return a.id < b.id
    end)
    local total = #rows
    local pages = math.max(1, math.ceil(total / Au.PAGE))
    if page > pages then page = pages end
    local out = {}
    for i = (page - 1) * Au.PAGE + 1, math.min(total, page * Au.PAGE) do out[#out + 1] = view(rows[i], username) end
    local lo, hi = hoursRange()
    return {
        page = page, pages = pages, total = total, items = out, sort = sort, query = query, currency = currency(),
        minHours = lo, maxHours = hi, incrementPercent = EC.sandbox("AuctionMinIncrementPercent", 5),
        feePercent = EC.sandbox("MarketListingFeePercent", 2), taxPercent = EC.sandbox("MarketSalesTaxPercent", 5),
        maxAuctions = EC.sandbox("AuctionMaxPerPlayer", 3), mine = Au.ownerCount(username),
    }
end

-- The player's own auctions: selling, and the ones they are bidding on (leading or outbid).
function Au.mine(username)
    local selling, bidding = {}, {}
    for _, a in pairs(md.auctions.items) do
        if a.seller == username then selling[#selling + 1] = view(a, username)
        elseif a.bidders and a.bidders[username] then bidding[#bidding + 1] = view(a, username) end
    end
    EC.sortSafe(selling, function(a, b) return a.expiresAt < b.expiresAt end)
    EC.sortSafe(bidding, function(a, b) return a.expiresAt < b.expiresAt end)
    return { selling = selling, bidding = bidding }
end

-- ---------- list-out (rule two, shared shape with ECMarket) ----------

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

local function findItem(inv, itemId)
    local found = nil
    pcall(function() found = inv:getItemWithID(itemId) end)
    if not found then return nil end
    local ok, items = pcall(function() return inv:getItems() end)
    if not ok or not items then return nil end
    for i = 0, items:size() - 1 do
        if items:get(i) == found then return found end
    end
    return nil
end

-- args = { itemIds | itemId, startPrice, hours, requestId }
function Au.create(player, args)
    local username = player:getUsername()
    if not validRequest(args) then return { ok = false, error = "invalid_args" } end
    local ids = type(args.itemIds) == "table" and args.itemIds or { args.itemId }
    if #ids < 1 or #ids > Mk.QTY_MAX then return { ok = false, error = "invalid_args" } end
    local seen = {}
    for _, id in ipairs(ids) do
        if not isInt(id, -2147483648, 2147483647) or seen[id] then return { ok = false, error = "invalid_args" } end
        seen[id] = true
    end
    local prior = L.priorResult("auction:" .. username .. ":" .. args.requestId)
    if prior then return { ok = prior.ok, duplicate = true, error = prior.error } end
    local pmin, pmax = EC.sandbox("MarketPriceMin", 1), EC.sandbox("MarketPriceMax", 1000000)
    local startPrice = args.startPrice
    if not isInt(startPrice, pmin, pmax) then return { ok = false, error = "price_range", min = pmin, max = pmax } end
    local lo, hi = hoursRange()
    if not isInt(args.hours, lo, hi) then return { ok = false, error = "hours_range", min = lo, max = hi } end
    if not T.near(player) then return { ok = false, error = "not_at_terminal" } end
    if L.isFrozen(username) then return { ok = false, error = "account_frozen" } end
    if Au.ownerCount(username) >= EC.sandbox("AuctionMaxPerPlayer", 3) then return { ok = false, error = "too_many_auctions" } end
    if md.auctions.count >= Au.MAX_AUCTIONS then return { ok = false, error = "market_full" } end
    if not M.hasFreeSlot(username) then return { ok = false, error = "mailbox_full" } end
    local inv = player:getInventory()
    if not inv then return { ok = false, error = "item_not_found" } end
    local items, signature = {}, nil
    for _, id in ipairs(ids) do
        local item = findItem(inv, id)
        if not item then return { ok = false, error = "item_not_found" } end
        local pass, reason = Codec.check(item)
        if not pass then return { ok = false, error = reason } end
        local sig = Codec.signature(Codec.snapshot(item))
        if signature == nil then signature = sig
        elseif sig ~= signature then return { ok = false, error = "mixed_items" } end
        items[#items + 1] = item
    end
    local cur = currency()
    local fee = pct(startPrice, EC.sandbox("MarketListingFeePercent", 2))
    if fee > 0 and L.getBalance(username, cur).available < fee then return { ok = false, error = "insufficient_funds", fee = fee } end

    local ms = EC.now()
    for _, item in ipairs(items) do Codec.detachParts(item, inv) end
    local snapshot = Codec.snapshot(items[1])
    local qty = #items
    local id = S.newId()
    local _, seq = EC.parseId(id)
    local p = playerData(player)
    Mk.addPending(p, id, { itemId = ids[1], itemIds = ids, qty = qty, snapshot = snapshot, kind = "auction", price = startPrice, hours = args.hours, seq = seq, epoch = md.meta.epoch, at = ms })
    transmit(player)
    for _, item in ipairs(items) do
        inv:Remove(item)
        sendRemoveItemFromContainer(inv, item)
    end
    local name, category = nil, nil
    pcall(function() name = ScriptManager.instance:FindItem(snapshot.type):getDisplayName() end)
    pcall(function() category = items[1]:getDisplayCategory() end)
    local a = {
        id = id, seller = username, item = snapshot.type, snapshot = snapshot, qty = qty, startPrice = startPrice, fee = fee,
        highest = nil, bids = 0, bidders = {}, at = ms, expiresAt = ms + args.hours * 3600000, hours = args.hours,
        category = type(category) == "string" and category or "other", name = type(name) == "string" and name or nil,
    }
    add(a)
    if fee > 0 then
        local res = L.debit(username, cur, fee, Mk.BURN_ACCOUNT, {
            kind = "auction_fee", requestId = "auction:" .. username .. ":" .. args.requestId, reasonCode = "auction_fee",
            payload = { item = snapshot.type, qty = qty, auctionId = id },
        })
        if not res.ok then
            remove(id)
            for _ = 1, qty do
                local back = Codec.rebuild(snapshot)
                if back then inv:AddItem(back) sendAddItemToContainer(inv, back) end
            end
            p.pendingOuts[id] = nil
            transmit(player)
            return { ok = false, error = res.error }
        end
    end
    X.emit("auction.created", { auctionId = id, seller = username, item = snapshot.type, qty = qty, startPrice = startPrice, fee = fee, hours = args.hours, currency = cur, expiresAt = a.expiresAt })
    X.market(username, { kind = "auction_created", listingId = id, item = snapshot.type, qty = qty, price = startPrice, fee = fee, currency = cur })
    return { ok = true, auctionId = id, qty = qty, fee = fee, expiresAt = a.expiresAt }
end

-- ---------- bidding ----------

-- Notify one online player (toast + mailbox badge), same shape as market.notice.
local function notify(username, fields)
    local p = S.onlinePlayer(username)
    if not p then return end
    fields.unclaimed = M.unclaimed(username)
    S.reply(p, "market.notice", fields)
end

-- Release the reservation of `a.highest` (outbid, cancel, downtime). Returns ok.
local function release(a, reason)
    local h = a.highest
    if not h then return true end
    local res = L.post({
        kind = "auction_refund", requestId = "arel:" .. a.id .. ":" .. tostring(h.seq), reasonCode = reason, actor = h.bidder,
        allowFrozen = true, payload = { item = a.item, qty = a.qty, auctionId = a.id },
        postings = {
            { account = h.bidder, currency = h.currency, amount = -h.amount, bucket = "reserved" },
            { account = h.bidder, currency = h.currency, amount = h.amount },
        },
    })
    return res.ok
end

function Au.bid(player, args)
    local username = player:getUsername()
    if not validRequest(args) or type(args.auctionId) ~= "string" then return { ok = false, error = "invalid_args" } end
    local prior = L.priorResult("abid:" .. username .. ":" .. args.requestId)
    if prior then return { ok = prior.ok, duplicate = true, error = prior.error } end
    if not T.near(player) then return { ok = false, error = "not_at_terminal" } end
    if L.isFrozen(username) then return { ok = false, error = "account_frozen" } end
    local a = md.auctions.items[args.auctionId]
    if not a then return { ok = false, error = "unknown_auction" } end
    if a.seller == username then return { ok = false, error = "own_auction" } end
    if (a.expiresAt or 0) <= EC.now() then return { ok = false, error = "auction_ended" } end
    local amount = args.amount
    local minNext = Au.minNext(a)
    local pmax = EC.sandbox("MarketPriceMax", 1000000)
    if not isInt(amount, 1, pmax) then return { ok = false, error = "price_range", min = minNext, max = pmax } end
    if amount < minNext then return { ok = false, error = "bid_too_low", min = minNext } end
    if not M.hasFreeSlot(username) and not (a.highest and a.highest.bidder == username) then return { ok = false, error = "mailbox_full" } end
    local cur = currency()
    local previous = a.highest
    local same = previous ~= nil and previous.bidder == username
    local delta = same and (amount - previous.amount) or amount   -- a raise only reserves the difference
    if L.getBalance(username, cur).available < delta then return { ok = false, error = "insufficient_funds" } end
    -- reserve first (the bidder's own money moves buckets); then release the outbid player
    local res = L.post({
        kind = Au.RESERVED_KIND, requestId = "abid:" .. username .. ":" .. args.requestId, reasonCode = "auction_bid", actor = username,
        payload = { item = a.item, qty = a.qty, auctionId = a.id, bid = amount },
        idemMeta = { auctionId = a.id, amount = amount },
        postings = {
            { account = username, currency = cur, amount = -delta },
            { account = username, currency = cur, amount = delta, bucket = "reserved" },
        },
    })
    if not res.ok then return { ok = false, error = res.error } end
    if previous and not same then
        if not release(a, "auction_outbid") then
            EC.log("auction " .. a.id .. ": release of the outbid reservation failed for " .. tostring(previous.bidder))
        end
    end
    a.highest = { bidder = username, amount = amount, currency = cur, at = EC.now(), seq = res.seq, txId = res.txId }
    a.bids = (a.bids or 0) + 1
    a.bidders = a.bidders or {}
    a.bidders[username] = true
    X.emit("auction.bid", { auctionId = a.id, bidder = username, amount = amount, previous = previous and previous.bidder or nil, previousAmount = previous and previous.amount or nil, seller = a.seller, item = a.item, txId = res.txId })
    X.market(username, { kind = "auction_bid", listingId = a.id, item = a.item, qty = a.qty, price = amount, currency = cur, other = a.seller, txId = res.txId })
    if previous and not same then
        X.market(previous.bidder, { kind = "auction_outbid", listingId = a.id, item = a.item, qty = a.qty, price = previous.amount, currency = cur, other = username })
        notify(previous.bidder, { kind = "auction_outbid", auctionId = a.id, item = a.item, qty = a.qty, price = amount, bidder = username })
    end
    notify(a.seller, { kind = "auction_bid", auctionId = a.id, item = a.item, qty = a.qty, price = amount, bidder = username })
    return { ok = true, auctionId = a.id, amount = amount, minNext = Au.minNext(a), reserved = L.getBalance(username, cur).reserved, balance = L.getBalance(username, cur).available }
end

-- ---------- ending ----------

-- Items back to the seller through the mailbox; the auction's slot becomes the entry's.
local function returnToSeller(a, reasonKind, extra)
    remove(a.id)
    local entry = M.add(a.seller, { kind = "return", item = a.item, qty = a.qty or 1, txId = nil, price = a.startPrice, snapshot = a.snapshot, listingId = a.id })
    X.emit("auction." .. reasonKind, { auctionId = a.id, seller = a.seller, item = a.item, qty = a.qty, startPrice = a.startPrice, mailId = entry.id })
    local line = { kind = "auction_" .. reasonKind, listingId = a.id, item = a.item, qty = a.qty, price = a.startPrice, mailId = entry.id }
    for k, v in pairs(extra or {}) do line[k] = v end
    X.market(a.seller, line)
    return entry
end

-- Highest bidder wins: reserved money to the seller minus tax, snapshot to the winner's mailbox
-- (allowed past the cap: the winner reserved a slot at bid time in spirit, the money already moved).
local function settle(a)
    local h = a.highest
    local tax = pct(h.amount, EC.sandbox("MarketSalesTaxPercent", 5))
    if tax >= h.amount then tax = h.amount - 1 end
    if tax < 0 then tax = 0 end
    local postings = {
        { account = h.bidder, currency = h.currency, amount = -h.amount, bucket = "reserved" },
        { account = a.seller, currency = h.currency, amount = h.amount - tax },
    }
    if tax > 0 then postings[#postings + 1] = { account = Mk.BURN_ACCOUNT, currency = h.currency, amount = tax } end
    local res = L.post({
        kind = "auction_sale", requestId = "asettle:" .. a.id, reasonCode = "auction_sale", actor = h.bidder, allowFrozen = true,
        payload = { item = a.item, qty = a.qty, auctionId = a.id, seller = a.seller, buyer = h.bidder, tax = tax },
        postings = postings,
    })
    if not res.ok then
        EC.log("auction " .. a.id .. " settlement refused (" .. tostring(res.error) .. "): returned to the seller, bid released")
        release(a, "auction_settle_failed")
        returnToSeller(a, "unsold", { error = res.error })
        return
    end
    remove(a.id)
    local entry = M.add(h.bidder, { kind = "auction", item = a.item, qty = a.qty or 1, txId = res.txId, price = h.amount, snapshot = a.snapshot, listingId = a.id })
    X.emit("auction.sold", { auctionId = a.id, seller = a.seller, buyer = h.bidder, item = a.item, qty = a.qty, price = h.amount, tax = tax, currency = h.currency, txId = res.txId, mailId = entry.id })
    X.market(a.seller, { kind = "auction_sold", listingId = a.id, item = a.item, qty = a.qty, price = h.amount, tax = tax, currency = h.currency, txId = res.txId, other = h.bidder })
    X.market(h.bidder, { kind = "auction_won", listingId = a.id, item = a.item, qty = a.qty, price = h.amount, currency = h.currency, txId = res.txId, other = a.seller })
    notify(a.seller, { kind = "auction_sold", auctionId = a.id, item = a.item, qty = a.qty, price = h.amount, tax = tax, buyer = h.bidder })
    notify(h.bidder, { kind = "auction_won", auctionId = a.id, item = a.item, qty = a.qty, price = h.amount })
    -- the winner standing at a terminal gets the item at once
    local winner = S.onlinePlayer(h.bidder)
    if winner and T.near(winner) then M.claim(winner, entry.id) end
end

local function endAuction(a)
    if a.highest then settle(a) else
        returnToSeller(a, "unsold")
        notify(a.seller, { kind = "auction_unsold", auctionId = a.id, item = a.item, qty = a.qty, price = a.startPrice })
    end
end

-- ponytail: full scan once a minute (<= MAX_AUCTIONS rows)
function Au.onTick()
    if not md then return end
    local ms = EC.now()
    if ms - lastSweep < Au.SWEEP_EVERY_MS then return end
    lastSweep = ms
    local due = {}
    for _, a in pairs(md.auctions.items) do
        if (a.expiresAt or 0) <= ms then due[#due + 1] = a end
    end
    for _, a in ipairs(due) do endAuction(a) end
end

-- Seller cancel: only while nobody has bid (a bid is a promise to the bidder). Fee not refunded.
function Au.cancel(player, args)
    local username = player:getUsername()
    if not validRequest(args) or type(args.auctionId) ~= "string" then return { ok = false, error = "invalid_args" } end
    if not T.near(player) then return { ok = false, error = "not_at_terminal" } end
    local a = md.auctions.items[args.auctionId]
    if not a then return { ok = false, error = "unknown_auction" } end
    if a.seller ~= username then return { ok = false, error = "not_owner" } end
    if a.highest then return { ok = false, error = "has_bids" } end
    local entry = returnToSeller(a, "cancelled")
    local claim = M.claim(player, entry.id)
    return { ok = true, auctionId = a.id, mailId = entry.id, delivered = claim.ok == true, deliveryError = (not claim.ok) and claim.error or nil }
end

-- Admin cancel: the reservation is released, the items go back to the seller.
function Au.adminCancel(admin, auctionId, reason)
    local a = md.auctions.items[auctionId]
    if not a then return false, "unknown_auction" end
    local bidder = a.highest and a.highest.bidder or nil
    release(a, "auction_cancelled")
    returnToSeller(a, "cancelled", { admin = admin, reason = reason })
    X.audit({ action = "auction", admin = admin, target = a.seller, field = auctionId, before = tostring(a.item), after = tostring(a.startPrice), reason = reason })
    notify(a.seller, { kind = "auction_cancelled", auctionId = a.id, item = a.item, qty = a.qty, price = a.startPrice, reason = reason })
    if bidder then notify(bidder, { kind = "auction_refund", auctionId = a.id, item = a.item, qty = a.qty, price = a.highest and a.highest.amount or 0, reason = reason }) end
    return true
end

-- ---------- rollback (rule three row 4, from ECMailbox.reconcileOuts through Mk.restoreFromPending) ----------

function Au.restoreFromPending(username, id, pend)
    if md.auctions.items[id] then return false end
    local hours = isInt(pend.hours, 1, 8760) and pend.hours or 24
    local a = {
        id = id, seller = username, item = pend.snapshot and pend.snapshot.type or nil, snapshot = pend.snapshot, qty = pend.qty or 1,
        startPrice = pend.price, fee = 0, highest = nil, bids = 0, bidders = {}, at = pend.at or EC.now(),
        expiresAt = (pend.at or EC.now()) + hours * 3600000, hours = hours, category = "other",
    }
    if type(a.item) ~= "string" or not isInt(a.startPrice, 1, 1000000000) or not isInt(a.qty, 1, Mk.QTY_MAX) then return false end
    pcall(function()
        local script = ScriptManager.instance:FindItem(a.item)
        a.name = script:getDisplayName()
        a.category = script:getDisplayCategory() or "other"
    end)
    add(a)
    X.market(username, { kind = "auction_restored", listingId = id, item = a.item, qty = a.qty, price = a.startPrice })
    return true
end

-- ---------- downtime policy (spec 12 stage F) ----------

local function readHeartbeat()
    local reader = nil
    local ok = pcall(function() reader = getFileReader(X.ROOT .. "/heartbeat.json", false) end)
    if not ok or not reader then return nil end
    local line = nil
    pcall(function() line = reader:readLine() end)
    pcall(function() reader:close() end)
    local doc = line and EC.jsonDecode(line) or nil
    return type(doc) == "table" and tonumber(doc.ts) or nil
end

-- Applied once per start, before the first sweep. Returns what it did (for the log and tests).
function Au.applyDowntime(now, lastBeat)
    if not lastBeat or md.auctions.count == 0 then return "none", 0 end
    local downtime = now - lastBeat
    if downtime <= Au.DOWNTIME_IGNORE_MS then return "ignored", downtime end
    if downtime > Au.DOWNTIME_CANCEL_MS then
        local ids = {}
        for id in pairs(md.auctions.items) do ids[#ids + 1] = id end
        for _, id in ipairs(ids) do
            local a = md.auctions.items[id]
            release(a, "auction_downtime")
            returnToSeller(a, "cancelled", { reason = "downtime", downtime = downtime })
        end
        X.emit("auction.downtime", { action = "cancelled", downtime = downtime, auctions = #ids })
        return "cancelled", downtime
    end
    local n = 0
    for _, a in pairs(md.auctions.items) do
        a.expiresAt = (a.expiresAt or now) + downtime
        n = n + 1
    end
    X.emit("auction.downtime", { action = "extended", downtime = downtime, auctions = n })
    return "extended", downtime
end

-- ---------- commands ----------

S.handlers["auction.browse"] = function(player, args)
    local res = Au.browse(player:getUsername(), args)
    res.atTerminal = T.near(player)
    S.reply(player, "auction.browse", res)
end

S.handlers["auction.mine"] = function(player, args)
    local res = Au.mine(player:getUsername())
    res.atTerminal = T.near(player)
    res.maxAuctions = EC.sandbox("AuctionMaxPerPlayer", 3)
    S.reply(player, "auction.mine", res)
end

S.handlers["auction.create"] = function(player, args)
    local res = Au.create(player, args)
    res.requestId = type(args) == "table" and args.requestId or nil
    res.mine = Au.mine(player:getUsername())
    S.reply(player, "auction.create", res)
end

S.handlers["auction.bid"] = function(player, args)
    local res = Au.bid(player, args)
    res.requestId = type(args) == "table" and args.requestId or nil
    S.reply(player, "auction.bid", res)
end

S.handlers["auction.cancel"] = function(player, args)
    local res = Au.cancel(player, args)
    res.requestId = type(args) == "table" and args.requestId or nil
    res.mine = Au.mine(player:getUsername())
    res.unclaimed = M.unclaimed(player:getUsername())
    S.reply(player, "auction.cancel", res)
end

function Au.init(root)
    md = root
    md.auctions = md.auctions or { items = {}, byOwner = {}, count = 0 }
    lastSweep = 0
    local action, downtime = Au.applyDowntime(EC.now(), readHeartbeat())
    EC.log("auctions: " .. tostring(md.auctions.count) .. " active, downtime " .. tostring(math.floor((downtime or 0) / 60000)) .. " min -> " .. action)
end

S.Auction = Au
S.onInit(Au.init)
Events.OnTickEvenPaused.Add(Au.onTick)
return Au
