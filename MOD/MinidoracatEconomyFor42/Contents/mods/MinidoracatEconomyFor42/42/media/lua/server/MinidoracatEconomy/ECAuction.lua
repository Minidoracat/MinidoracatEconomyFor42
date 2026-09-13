-- MinidoracatEconomyFor42 - auctions (server authority; spec 12 stage F, 10.4, 11.1, 16.3).
--
-- An auction is an escrow listing with a clock: the seller's items leave the backpack through the
-- same three-phase list-out as a market listing (M.beginOut / M.abortOut / M.finishOut, pending
-- kind "auction", rebuilt from the
-- player save after a world rollback), the highest bid is money the bidder still owns but cannot
-- spend (ledger bucket "reserved": one tx moves -X available / +X reserved on the bidder's own
-- wallet, and that same tx releases the previous highest bidder), and expiry settles in one
-- tick: reserved -> seller minus tax, snapshot -> winner's mailbox; no bid -> back to the seller.
-- Restarts: the auction table lives in Global ModData, the sweep resumes; downtime measured from
-- heartbeat.json (spec 12 stage F policy): <= 5 min nothing, 5 min .. 24 h every active auction
-- is extended by the downtime, > 24 h every auction is cancelled (items back, reserves released).
--
-- Currency (spec contract 6): the seller fixes it when the auction is created. Every bid, the
-- release of an outbid reservation, the settlement and the refund read it off the auction, and
-- a bidder's `currency` is only checked against it. A previous highest bid recorded in another
-- currency than the auction's is a contradiction this server does not resolve by guessing: the
-- new bid is refused and the auction is held for review.
--
-- Money that was reserved is never left stranded: a release that the ledger refuses does not
-- get logged and walked past - the auction keeps its highest bid and its items and is retried,
-- because the reservation and the row that names it are the only link between the two.
--
-- Engine: nothing new beyond ECMarket; the clock is getTimestampMs (OnTickEvenPaused).

if not MinidoracatEconomy or not MinidoracatEconomy.Market then
    require "MinidoracatEconomy/ECMarket"
end
if not MinidoracatEconomy or not MinidoracatEconomy.Wallet then
    require "MinidoracatEconomy/ECWallet"
end
local EC = MinidoracatEconomy
local S = EC and EC.Server
local L = EC and EC.Ledger
local X = EC and EC.Export
local Cfg = EC and EC.Config
local T = EC and EC.Terminal
local M = EC and EC.Mailbox
local Mk = EC and EC.Market
local Codec = EC and EC.Codec
local W = EC and EC.Wallet
if not S or not S.AUTHORITY or not L or not X or not Cfg or not T or not M or not Mk or not Codec or not W then
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
Au.CURRENCY_ALL = "all"
-- The widest duration the wire shape accepts. The host's own window is AuctionMinHours /
-- AuctionMaxHours, read after the idempotency record has been looked up so a narrowed window
-- cannot re-judge an auction that is already standing. This one only keeps a request that is
-- not a sane integer out of the fingerprint.
Au.HOURS_CEILING = 24 * 365

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

-- Registered, tradable (marketUnit) and not switched off at runtime. An auction names its own
-- currency; nothing here scans the registry for "the" market currency.
local function currencyState(id)
    if not L.isCurrency(id) then return nil, "unknown_currency" end
    local def = Cfg.currency(id)
    if not def then return nil, "unknown_currency" end
    if def.marketUnit ~= true then return nil, "currency_unavailable" end
    if def.enabled == false then return nil, "currency_disabled" end
    return def
end

local function tradableCurrencies()
    local out = {}
    for _, id in ipairs(EC.CURRENCY_ORDER) do
        if currencyState(id) then out[#out + 1] = id end
    end
    return out
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

-- A resend is answered from the ledger's record of the first attempt; the same requestId used
-- for a different order (another auction, another currency, another amount) is refused instead
-- of being answered with the first one's result (spec contract 12).
local function priorOrder(requestId, order)
    local prior = L.priorResult(requestId)
    if not prior then return nil end
    local meta = prior.meta or {}
    for key, value in pairs(order) do
        if meta[key] ~= value then
            return { ok = false, error = "request_conflict", auctionId = meta.auctionId,
                currency = meta.currency, amount = meta.amount }
        end
    end
    return { ok = prior.ok, txId = prior.txId, duplicate = true, error = prior.error,
        auctionId = meta.auctionId, currency = meta.currency, amount = meta.amount }
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
    return s and EC.countKeys(s) or 0
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
    local byCurrency, held = {}, 0
    for _, a in pairs(md.auctions.items) do
        if a.blocked then held = held + 1
        elseif a.currency then byCurrency[a.currency] = (byCurrency[a.currency] or 0) + 1 end
    end
    return { auctions = md.auctions.count, max = Au.MAX_AUCTIONS, byCurrency = byCurrency, held = held }
end

-- One record this server cannot act on with money: it keeps its items and its bid exactly as
-- they are and an operator is told once, instead of a guess being settled every minute.
local function hold(a, reason, fields)
    if a.blocked == reason and a.heldReported == true then return end
    a.blocked, a.heldReported = reason, true
    local line = { auctionId = a.id, seller = a.seller, item = a.item, qty = a.qty, reason = reason }
    for k, v in pairs(fields or {}) do line[k] = v end
    X.emit("auction.held", line)
    EC.log("auction " .. tostring(a.id) .. " held: " .. tostring(reason))
end

-- Two kinds of hold, and only one of them stops the auction running: a currency this server
-- cannot prove is one nothing may be settled in, while a refund the ledger refused is retried -
-- the next bid releases it in its own transaction, and the next sweep settles again.
local function currencyHeld(a)
    return a.blocked == "currency_unknown" or a.blocked == "currency_conflict"
end

-- ---------- views ----------

-- `weight` is one copy's estimate (the real weight when the lot was created, the script estimate
-- for an auction that predates the field): a bidder can size the delivery before bidding. It is
-- only that - the auction never promises the winner's future backpack space.
local function view(a, username)
    local s = a.snapshot or {}
    return {
        id = a.id, seller = a.seller, item = a.item, name = a.name, category = a.category, qty = a.qty or 1,
        startPrice = a.startPrice, currency = a.currency, blocked = a.blocked,
        bid = a.highest and a.highest.amount or nil, bidder = a.highest and a.highest.bidder or nil,
        bids = a.bids or 0, at = a.at, expiresAt = a.expiresAt, weight = a.weight or M.scriptWeight(a.item),
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
    price = { key = function(a) return a.highest and a.highest.amount or a.startPrice end, desc = false, money = true },
    price_desc = { key = function(a) return a.highest and a.highest.amount or a.startPrice end, desc = true, money = true },
    name = { key = function(a) return string.lower(tostring(a.name or a.item or "")) end, desc = false },
    name_desc = { key = function(a) return string.lower(tostring(a.name or a.item or "")) end, desc = true },
    bids = { key = function(a) return a.bids or 0 end, desc = false },
    bids_desc = { key = function(a) return a.bids or 0 end, desc = true },
}

-- args.currency = "all" (default) or one registered currency id, echoed back. A price sort
-- across currencies compares numbers that are not the same kind of money, so it is refused with
-- currency_required rather than answered with a meaningless order (spec contract 7).
function Au.browse(username, args)
    args = type(args) == "table" and args or {}
    local seller = type(args.seller) == "string" and args.seller ~= "" and args.seller or nil
    local query = type(args.query) == "string" and string.lower(string.sub((string.gsub(args.query, "^%s*(.-)%s*$", "%1")), 1, 64)) or ""
    if query == "" then query = nil end
    local sort = Au.SORTS[args.sort] and args.sort or "ending"
    local page = isInt(args.page, 1, 100000) and args.page or 1
    local currency = Au.CURRENCY_ALL
    if args.currency ~= nil and args.currency ~= Au.CURRENCY_ALL then
        if not L.isCurrency(args.currency) then
            return { ok = false, error = "unknown_currency", currency = args.currency, sort = sort,
                items = {}, page = 1, pages = 1, total = 0, currencies = tradableCurrencies() }
        end
        currency = args.currency
    end
    if currency == Au.CURRENCY_ALL and Au.SORTS[sort].money then
        return { ok = false, error = "currency_required", currency = Au.CURRENCY_ALL, sort = sort,
            items = {}, page = 1, pages = 1, total = 0, currencies = tradableCurrencies() }
    end
    local filter = currency ~= Au.CURRENCY_ALL and currency or nil
    local rows = {}
    for _, a in pairs(md.auctions.items) do
        -- `seller` is an exact account name, compared byte for byte ("bob" is not "bobby"), and
        -- it narrows the whole table before the sort and the page
        if (not seller or a.seller == seller) and (not filter or a.currency == filter) then
            local hay = string.lower(tostring(a.item) .. " " .. tostring(a.name or "") .. " " .. tostring(a.seller))
            if not query or string.find(hay, query, 1, true) then rows[#rows + 1] = a end
        end
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
        ok = true, page = page, pages = pages, total = total, items = out, sort = sort, query = query, seller = seller,
        currency = currency, currencies = tradableCurrencies(),
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

-- args = { itemIds | itemId, startPrice, hours, currency, requestId }
function Au.create(player, args)
    local username = player:getUsername()
    if not validRequest(args) then return { ok = false, error = "invalid_args" } end
    if type(args.currency) ~= "string" or args.currency == "" then return { ok = false, error = "invalid_args" } end
    local ids = type(args.itemIds) == "table" and args.itemIds or { args.itemId }
    if #ids < 1 or #ids > Mk.QTY_MAX then return { ok = false, error = "invalid_args" } end
    local seen = {}
    for _, id in ipairs(ids) do
        if not isInt(id, -2147483648, 2147483647) or seen[id] then return { ok = false, error = "invalid_args" } end
        seen[id] = true
    end
    local cur = args.currency
    local startPrice = args.startPrice
    -- The shape is checked here; what the live configuration currently allows is checked after
    -- the record has been looked up. An auction whose fee was already charged and whose items
    -- already left the backpack must not be re-judged by settings that changed since: an admin
    -- switching the currency off or narrowing the price / duration range between the auction and
    -- its resend would otherwise answer a committed operation with currency_disabled,
    -- price_range or hours_range, and the seller would never learn the auction id or its terms
    -- (report FINAL-LEDGER-2).
    if not isInt(startPrice, 1, Mk.PRICE_CEILING) then return { ok = false, error = "price_range" } end
    if not isInt(args.hours, 1, Au.HOURS_CEILING) then return { ok = false, error = "hours_range" } end
    -- a new auction has no id yet: its order is the currency, the start price, how long it runs
    -- and the exact batch it puts up. The same requestId with another pile of items or another
    -- duration is a different auction, not a resend of this one.
    local requestId = "auction:" .. username .. ":" .. args.requestId
    -- the whole namespaced key is checked before any item leaves the backpack: no operation may
    -- complete without the record that answers its resend (report CORE-M2)
    if not L.validRequestKey(requestId) then return { ok = false, error = "request_too_long" } end
    local batch = L.batchKey(ids, Mk.QTY_MAX)
    if batch == nil then return { ok = false, error = "invalid_args" } end
    local prior = priorOrder(requestId, { currency = cur, amount = startPrice, items = batch, hours = args.hours })
    if prior then return prior end
    -- a new request: from here the live configuration decides
    local def, cerr = currencyState(cur)
    if not def then return { ok = false, error = cerr, currency = cur } end
    local pmin, pmax = EC.sandbox("MarketPriceMin", 1), EC.sandbox("MarketPriceMax", 1000000)
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
        local item = M.findTopLevel(inv, id)
        if not item then return { ok = false, error = "item_not_found" } end
        local pass, reason = Codec.check(item)
        if not pass then return { ok = false, error = reason } end
        local sig = Codec.signature(Codec.snapshot(item))
        if signature == nil then signature = sig
        elseif sig ~= signature then return { ok = false, error = "mixed_items" } end
        items[#items + 1] = item
    end
    local fee = pct(startPrice, EC.sandbox("MarketListingFeePercent", 2))
    if fee > 0 and L.getBalance(username, cur).available < fee then
        return { ok = false, error = "insufficient_funds", fee = fee, currency = cur }
    end

    local ms = EC.now()
    for _, item in ipairs(items) do Codec.detachParts(item, inv) end
    local snapshot = Codec.snapshot(items[1])
    local qty = #items
    local id = S.newId()
    local _, seq = EC.parseId(id)
    -- phase 1: the seller's own save records the operation and the exact origin of every unit
    -- before anything is removed. A refusal here has moved no item and charged no fee.
    local rec = { itemId = ids[1], itemIds = ids, qty = qty, lotQty = qty, snapshot = snapshot, kind = "auction",
        price = startPrice, hours = args.hours, currency = cur, tradeSchema = L.TRADE_SCHEMA,
        seq = seq, epoch = md.meta.epoch, at = ms }
    local began, beginErr, beginDetail = M.beginOut(player, id, items, rec)
    if not began then
        return { ok = false, error = beginErr, recovery = M.recoveryStatus(username),
            recoveryDetail = beginDetail }
    end
    -- phase 2: the items leave the backpack
    local taken, takeError = M.takeOut(player, id, items)
    if not taken then return { ok = false, error = takeError, recovery = M.recoveryStatus(username) } end
    local name, category = nil, nil
    pcall(function() name = ScriptManager.instance:FindItem(snapshot.type):getDisplayName() end)
    pcall(function() category = items[1]:getDisplayCategory() end)
    local a = {
        id = id, seller = username, item = snapshot.type, snapshot = snapshot, qty = qty, startPrice = startPrice,
        currency = cur, tradeSchema = L.TRADE_SCHEMA, fee = fee,
        highest = nil, bids = 0, bidders = {}, at = ms, expiresAt = ms + args.hours * 3600000, hours = args.hours,
        weight = M.itemWeight(items[1]),
        category = type(category) == "string" and category or "other", name = type(name) == "string" and name or nil,
    }
    add(a)
    if fee > 0 then
        local res = L.debit(username, cur, fee, Mk.BURN_ACCOUNT, {
            kind = "auction_fee", requestId = requestId, reasonCode = "auction_fee",
            idemMeta = { auctionId = id, currency = cur, amount = startPrice, items = batch, hours = args.hours },
            payload = { item = snapshot.type, qty = qty, auctionId = id, currency = cur },
        })
        if not res.ok then
            -- the very objects that left the backpack go back into it: nothing is rebuilt from
            -- the snapshot, so a refused fee cannot leave a copy behind
            remove(id)
            local returned = M.abortOut(player, id, items)
            return { ok = false, error = returned and res.error or "recovery_pending", recovery = M.recoveryStatus(username) }
        end
    end
    -- the world side is committed: the transfer receipt consumes those origins exactly once,
    -- so a later login with an older save cannot auction them a second time
    local recorded, recordError = M.finishOut(username, id, rec, "auction", id)
    if not recorded then error("auction-out receipt invariant: " .. tostring(recordError)) end
    if fee <= 0 then
        -- a fee percent of 0 moved no money, so the ledger has no transaction to remember this
        -- auction by: the operation itself goes into the same idempotency ring, and a resend or
        -- a reused id with another batch / duration is answered exactly as on the paid path.
        -- The key was validated before the items moved, so a refusal can only be a key the
        -- window already holds: it is reported, never swallowed.
        if not L.noteOperation(requestId, id, { auctionId = id, currency = cur, amount = startPrice,
            items = batch, hours = args.hours }) then
            EC.log("auction " .. id .. ": the idempotency record was refused")
            X.emit("ledger.anomaly", { kind = "auction", auctionId = id, username = username,
                resolution = "idempotency-record-refused" })
        end
    end
    X.emit("auction.created", { auctionId = id, seller = username, item = snapshot.type, qty = qty, startPrice = startPrice, fee = fee, hours = args.hours, currency = cur, expiresAt = a.expiresAt })
    X.market(username, { kind = "auction_created", listingId = id, item = snapshot.type, qty = qty, price = startPrice, fee = fee, currency = cur })
    return { ok = true, auctionId = id, qty = qty, fee = fee, currency = cur, startPrice = startPrice, expiresAt = a.expiresAt }
end

-- ---------- bidding ----------

-- Notify one online player (toast + mailbox badge), same shape as market.notice.
local function notify(username, fields)
    local p = S.onlinePlayer(username)
    if not p then return end
    fields.unclaimed = M.unclaimed(username)
    S.reply(p, "market.notice", fields)
end

-- Release the reservation of `a.highest` in the currency that bid was made in (cancel, downtime,
-- a settlement the ledger refused). Returns ok: a false is never a line in the log the caller
-- walks past - the money is still reserved and the auction row is the only thing that names it.
local function release(a, reason)
    local h = a.highest
    if not h then return true end
    local res = L.post({
        kind = "auction_refund", requestId = "arel:" .. a.id .. ":" .. tostring(h.seq), reasonCode = reason, actor = h.bidder,
        allowFrozen = true, payload = { item = a.item, qty = a.qty, auctionId = a.id, currency = h.currency },
        postings = {
            { account = h.bidder, currency = h.currency, amount = -h.amount, bucket = "reserved" },
            { account = h.bidder, currency = h.currency, amount = h.amount },
        },
    })
    if not res.ok then
        hold(a, "refund_failed", { bidder = h.bidder, amount = h.amount, currency = h.currency, error = res.error })
        return false
    end
    return true
end

-- args = { auctionId, amount, currency, requestId }. The bid reserves the bidder's own money and
-- releases the outbid one in the same transaction: either both happen or neither does, so a
-- refused release can never strand a reservation whose auction row has already moved on.
function Au.bid(player, args)
    local username = player:getUsername()
    if not validRequest(args) or type(args.auctionId) ~= "string" then return { ok = false, error = "invalid_args" } end
    if type(args.currency) ~= "string" or args.currency == "" then return { ok = false, error = "invalid_args" } end
    local requestId = "abid:" .. username .. ":" .. args.requestId
    if not L.validRequestKey(requestId) then return { ok = false, error = "request_too_long" } end
    local prior = priorOrder(requestId, { auctionId = args.auctionId, currency = args.currency, amount = args.amount })
    if prior then return prior end
    if not T.near(player) then return { ok = false, error = "not_at_terminal" } end
    if L.isFrozen(username) then return { ok = false, error = "account_frozen" } end
    local a = md.auctions.items[args.auctionId]
    if not a then return { ok = false, error = "unknown_auction" } end
    if a.seller == username then return { ok = false, error = "own_auction" } end
    if currencyHeld(a) then return { ok = false, error = a.blocked, auctionId = a.id, currency = a.currency } end
    if (a.expiresAt or 0) <= EC.now() then return { ok = false, error = "auction_ended" } end
    local cur = a.currency
    if args.currency ~= cur then return { ok = false, error = "currency_mismatch", auctionId = a.id, currency = cur } end
    local def, cerr = currencyState(cur)
    if not def then return { ok = false, error = cerr, currency = cur } end
    local previous = a.highest
    if previous and previous.currency ~= cur then
        -- the standing bid and the auction disagree about what money is held here; settling or
        -- releasing either way would move the wrong wallet
        hold(a, "currency_conflict", { bidder = previous.bidder, amount = previous.amount,
            currency = previous.currency, auctionCurrency = cur })
        return { ok = false, error = "currency_conflict", auctionId = a.id, currency = cur }
    end
    local amount = args.amount
    local minNext = Au.minNext(a)
    local pmax = EC.sandbox("MarketPriceMax", 1000000)
    if not isInt(amount, 1, pmax) then return { ok = false, error = "price_range", min = minNext, max = pmax } end
    if amount < minNext then return { ok = false, error = "bid_too_low", min = minNext } end
    if not M.hasFreeSlot(username) and not (previous and previous.bidder == username) then return { ok = false, error = "mailbox_full" } end
    local same = previous ~= nil and previous.bidder == username
    local delta = same and (amount - previous.amount) or amount   -- a raise only reserves the difference
    if L.getBalance(username, cur).available < delta then return { ok = false, error = "insufficient_funds", currency = cur } end
    local postings = {
        { account = username, currency = cur, amount = -delta },
        { account = username, currency = cur, amount = delta, bucket = "reserved" },
    }
    if previous and not same then
        -- the outbid reservation comes home in the same transaction; allowFrozen is for that
        -- side only (this bidder was refused above if frozen), and the ledger treats an exact
        -- reserved -> available move as the bucket move it is, cap or no cap
        postings[#postings + 1] = { account = previous.bidder, currency = cur, amount = -previous.amount, bucket = "reserved" }
        postings[#postings + 1] = { account = previous.bidder, currency = cur, amount = previous.amount }
    end
    local res = L.post({
        kind = Au.RESERVED_KIND, requestId = requestId, reasonCode = "auction_bid", actor = username,
        allowFrozen = previous ~= nil and not same,
        payload = { item = a.item, qty = a.qty, auctionId = a.id, bid = amount, currency = cur,
            previous = previous and previous.bidder or nil },
        idemMeta = { auctionId = a.id, currency = cur, amount = amount },
        postings = postings,
    })
    if not res.ok then return { ok = false, error = res.error, currency = cur } end
    -- the mark travels with the bid: a later read must never take this record for one written
    -- before the market had more than one currency
    a.highest = { bidder = username, amount = amount, currency = cur, tradeSchema = L.TRADE_SCHEMA,
        at = EC.now(), seq = res.seq, txId = res.txId }
    a.bids = (a.bids or 0) + 1
    a.bidders = a.bidders or {}
    a.bidders[username] = true
    -- a refused refund is what this transaction just released: the row is not held any more
    if a.blocked == "refund_failed" then a.blocked, a.heldReported = nil, nil end
    X.emit("auction.bid", { auctionId = a.id, bidder = username, amount = amount, previous = previous and previous.bidder or nil, previousAmount = previous and previous.amount or nil, seller = a.seller, item = a.item, qty = a.qty, currency = cur, txId = res.txId })
    X.market(username, { kind = "auction_bid", listingId = a.id, item = a.item, qty = a.qty, price = amount, currency = cur, other = a.seller, txId = res.txId })
    if previous and not same then
        X.market(previous.bidder, { kind = "auction_outbid", listingId = a.id, item = a.item, qty = a.qty, price = previous.amount, currency = cur, other = username })
        notify(previous.bidder, { kind = "auction_outbid", auctionId = a.id, item = a.item, qty = a.qty, price = amount, currency = cur, bidder = username })
    end
    notify(a.seller, { kind = "auction_bid", auctionId = a.id, item = a.item, qty = a.qty, price = amount, currency = cur, bidder = username })
    return { ok = true, auctionId = a.id, amount = amount, currency = cur, minNext = Au.minNext(a),
        reserved = L.getBalance(username, cur).reserved, balance = L.getBalance(username, cur).available }
end

-- ---------- ending ----------

-- Items back to the seller through the mailbox; the auction's slot becomes the entry's. No money
-- moves here, so an auction whose currency could not be proved can still come home this way.
local function returnToSeller(a, reasonKind, extra)
    remove(a.id)
    local currency = L.isCurrency(a.currency) and a.currency or nil
    local entry = M.add(a.seller, { kind = "return", item = a.item, qty = a.qty or 1, txId = nil,
        price = a.startPrice, currency = currency, snapshot = a.snapshot, listingId = a.id })
    X.emit("auction." .. reasonKind, { auctionId = a.id, seller = a.seller, item = a.item, qty = a.qty, startPrice = a.startPrice,
        currency = a.currency, bidder = a.highest and a.highest.bidder or nil, mailId = entry.id })
    local line = { kind = "auction_" .. reasonKind, listingId = a.id, item = a.item, qty = a.qty,
        price = a.startPrice, currency = a.currency, mailId = entry.id }
    for k, v in pairs(extra or {}) do line[k] = v end
    X.market(a.seller, line)
    return entry
end

-- Highest bidder wins: reserved money to the seller minus tax, snapshot to the winner's mailbox
-- (allowed past the cap: the winner reserved a slot at bid time in spirit, the money already moved).
-- A settlement the ledger refuses releases the bid and hands the goods back - and when that
-- release is refused too, nothing is removed and nothing is handed over: the auction keeps its
-- bid and its items and the next sweep tries again, because the row is the only thing that
-- still names that reservation.
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
        payload = { item = a.item, qty = a.qty, auctionId = a.id, seller = a.seller, buyer = h.bidder, tax = tax, currency = h.currency },
        postings = postings,
    })
    if not res.ok then
        EC.log("auction " .. a.id .. " settlement refused (" .. tostring(res.error) .. ")")
        if not release(a, "auction_settle_failed") then
            -- release() has already held the row with the reason; the bid stays where it is
            return
        end
        a.highest = nil
        returnToSeller(a, "unsold", { error = res.error })
        notify(a.seller, { kind = "auction_unsold", auctionId = a.id, item = a.item, qty = a.qty,
            price = a.startPrice, currency = a.currency, error = res.error })
        return
    end
    remove(a.id)
    -- the auction row is gone one line above: the winner's letter keeps who it was won from
    local entry = M.add(h.bidder, { kind = "auction", item = a.item, qty = a.qty or 1, txId = res.txId,
        price = h.amount, currency = h.currency, seller = a.seller, snapshot = a.snapshot, listingId = a.id })
    X.emit("auction.sold", { auctionId = a.id, seller = a.seller, buyer = h.bidder, item = a.item, qty = a.qty, price = h.amount, tax = tax, currency = h.currency, txId = res.txId, mailId = entry.id })
    X.market(a.seller, { kind = "auction_sold", listingId = a.id, item = a.item, qty = a.qty, price = h.amount, tax = tax, currency = h.currency, txId = res.txId, other = h.bidder })
    X.market(h.bidder, { kind = "auction_won", listingId = a.id, item = a.item, qty = a.qty, price = h.amount, currency = h.currency, txId = res.txId, other = a.seller })
    notify(a.seller, { kind = "auction_sold", auctionId = a.id, item = a.item, qty = a.qty, price = h.amount, tax = tax, currency = h.currency, buyer = h.bidder })
    -- the winner standing at a terminal gets the item at once. The notice is sampled after that
    -- claim, so its unclaimed count and its wording say what actually happened (backpack, part
    -- of it in the backpack, or the mailbox) instead of the state from before the handover.
    local winner = S.onlinePlayer(h.bidder)
    local claim = nil
    if winner and T.near(winner) then claim = M.claim(winner, entry.id) end
    local line = { kind = "auction_won", auctionId = a.id, item = a.item, qty = a.qty, price = h.amount,
        currency = h.currency, mailId = entry.id }
    notify(h.bidder, M.deliveryFields(line, claim, a.qty or 1))
end

local function endAuction(a)
    if a.highest then
        if currencyHeld(a) then return end   -- nothing is ever settled in a guessed currency
        settle(a)
    else
        returnToSeller(a, "unsold")
        notify(a.seller, { kind = "auction_unsold", auctionId = a.id, item = a.item, qty = a.qty,
            price = a.startPrice, currency = a.currency })
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
    local out = { ok = true, auctionId = a.id, mailId = entry.id, currency = a.currency }
    return M.deliveryFields(out, M.claim(player, entry.id), a.qty or 1)
end

-- Admin cancel: the reservation is released, the items go back to the seller. A release the
-- ledger refuses cancels nothing: the auction and its bid stay, and the admin is told why.
function Au.adminCancel(admin, auctionId, reason)
    local a = md.auctions.items[auctionId]
    if not a then return false, "unknown_auction" end
    local bidder = a.highest and a.highest.bidder or nil
    local amount = a.highest and a.highest.amount or 0
    if not release(a, "auction_cancelled") then return false, "refund_failed" end
    a.highest = nil
    returnToSeller(a, "cancelled", { admin = admin, reason = reason })
    X.audit({ action = "auction", admin = admin, target = a.seller, field = auctionId, before = tostring(a.item),
        after = tostring(a.startPrice), currency = a.currency, reason = reason })
    notify(a.seller, { kind = "auction_cancelled", auctionId = a.id, item = a.item, qty = a.qty,
        price = a.startPrice, currency = a.currency, reason = reason })
    if bidder then notify(bidder, { kind = "auction_refund", auctionId = a.id, item = a.item, qty = a.qty,
        price = amount, currency = a.currency, reason = reason }) end
    return true
end

-- ---------- rollback (rule three row 4, from ECMailbox.reconcileOuts through Mk.restoreFromPending) ----------

-- Returns ok, info; every refusal carries an info table so the reconcile can name the held
-- record without guarding for a missing one.
function Au.restoreFromPending(username, id, pend)
    -- only the server's own journal record rebuilds an auction (report CORE-H1)
    local Rec = S.Recovery
    if Rec == nil or type(Rec.isProven) ~= "function" or not Rec.isProven(pend) then
        return false, { reason = "proof_required", kind = "auction" }
    end
    if md.auctions.items[id] then
        return false, { reason = "restore_failed", cause = "auction_exists", kind = "auction" }
    end
    local qty, lotQty = pend.qty or 1, pend.lotQty or pend.qty or 1
    if isInt(qty, 1, Mk.QTY_MAX) and isInt(lotQty, 1, Mk.QTY_MAX) and qty < lotQty then
        -- only part of the lot could be accounted for: the start price was for the whole lot, so
        -- ECMailbox mails the valid remainder back instead of reopening the auction repriced
        return false, { reason = "partial_lot", kind = "auction", item = pend.snapshot and pend.snapshot.type or nil,
            snapshot = pend.snapshot, qty = qty, lotQty = lotQty, price = pend.price }
    end
    local currency = L.normalizeRecord(pend, L.TRUST_SERVER)
    if currency == nil then
        return false, { reason = "currency_unknown", kind = "auction", item = pend.snapshot and pend.snapshot.type or nil,
            snapshot = pend.snapshot, qty = qty, lotQty = lotQty, price = pend.price }
    end
    local hours = isInt(pend.hours, 1, 8760) and pend.hours or 24
    local a = {
        id = id, seller = username, item = pend.snapshot and pend.snapshot.type or nil, snapshot = pend.snapshot, qty = pend.qty or 1,
        startPrice = pend.price, currency = currency, tradeSchema = L.TRADE_SCHEMA,
        fee = 0, highest = nil, bids = 0, bidders = {}, at = pend.at or EC.now(),
        expiresAt = (pend.at or EC.now()) + hours * 3600000, hours = hours, category = "other",
    }
    if type(a.item) ~= "string" or not isInt(a.startPrice, 1, 1000000000) or not isInt(a.qty, 1, Mk.QTY_MAX) then
        return false, { reason = "restore_failed", cause = "bad_record", kind = "auction", item = a.item,
            snapshot = pend.snapshot, qty = a.qty, lotQty = lotQty, price = a.startPrice }
    end
    a.weight = M.scriptWeight(a.item)
    pcall(function()
        local script = ScriptManager.instance:FindItem(a.item)
        a.name = script:getDisplayName()
        a.category = script:getDisplayCategory() or "other"
    end)
    add(a)
    X.market(username, { kind = "auction_restored", listingId = id, item = a.item, qty = a.qty, price = a.startPrice, currency = currency })
    X.emit("auction.restored", { auctionId = id, seller = username, item = a.item, qty = a.qty, startPrice = a.startPrice, currency = currency, expiresAt = a.expiresAt })
    return true
end

-- The live auction under this id, for the recovery core (see Mk.operationInfo): who owns it,
-- what it holds and how many units. "There is something under this id" is not enough to act on
-- a pending record that merely named the id.
function Au.operationInfo(id)
    local a = type(id) == "string" and md.auctions.items[id] or nil
    if not a then return nil end
    return { kind = "auction", owner = a.seller, item = a.item, qty = a.qty or 1,
        price = a.startPrice, currency = a.currency }
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
-- A cancellation whose refund the ledger refuses leaves that auction exactly as it is (held and
-- reported); the rest are cancelled.
function Au.applyDowntime(now, lastBeat)
    if not lastBeat or md.auctions.count == 0 then return "none", 0 end
    local downtime = now - lastBeat
    if downtime <= Au.DOWNTIME_IGNORE_MS then return "ignored", downtime end
    if downtime > Au.DOWNTIME_CANCEL_MS then
        local ids = {}
        for id in pairs(md.auctions.items) do ids[#ids + 1] = id end
        local cancelled, held = 0, 0
        for _, id in ipairs(ids) do
            local a = md.auctions.items[id]
            if release(a, "auction_downtime") then
                a.highest = nil
                returnToSeller(a, "cancelled", { reason = "downtime", downtime = downtime })
                cancelled = cancelled + 1
            else
                held = held + 1
            end
        end
        X.emit("auction.downtime", { action = "cancelled", downtime = downtime, auctions = cancelled, held = held })
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

-- ---------- history (the public record) ----------
--
-- No second ledger and no new file: the record is the auction.* lines ECExport already writes to
-- events-YYYYMMDD.json. They are read through W.tail (a batch of lines per tick, the newest 200
-- matches per reply) and projected to the public whitelist below - nothing else of a line leaves
-- the server (no postings, no balances, no admin reason). `price` is a start price, one bid or the
-- hammer price: it is not a wallet delta, so a raise must never be read as a second charge.

Au.HISTORY_QUERY_CHARS = 128
Au.HISTORY_ID_CHARS = 96
Au.HISTORY_KINDS = { created = true, bid = true, sold = true, unsold = true, cancelled = true, restored = true }

-- One events line -> the public entry of the shared contract, or nil when the line is not an
-- auction record (tx.committed, audit, auction.downtime, ...).
local function historyRecord(rec)
    local kind = type(rec.type) == "string" and string.match(rec.type, "^auction%.(.+)$") or nil
    if not kind or not Au.HISTORY_KINDS[kind] then return nil end
    if type(rec.auctionId) ~= "string" then return nil end
    local price = rec.price
    if price == nil then price = rec.amount end        -- auction.bid carries the bid as `amount`
    if price == nil then price = rec.startPrice end    -- created / unsold / cancelled / restored
    return {
        kind = "auction_" .. kind,
        auctionId = rec.auctionId,
        listingId = rec.auctionId,                     -- the history rows key on listingId already
        ts = type(rec.ts) == "number" and rec.ts or nil,
        epoch = type(rec.epoch) == "string" and rec.epoch or nil,
        seq = type(rec.seq) == "number" and rec.seq or nil,
        txId = type(rec.txId) == "string" and rec.txId or nil,
        item = type(rec.item) == "string" and rec.item or nil,
        qty = type(rec.qty) == "number" and rec.qty or nil,        -- older bid lines carry none
        seller = type(rec.seller) == "string" and rec.seller or nil,
        bidder = type(rec.bidder) == "string" and rec.bidder or nil,
        buyer = type(rec.buyer) == "string" and rec.buyer or nil,
        previous = type(rec.previous) == "string" and rec.previous or nil,
        price = type(price) == "number" and price or nil,
        currency = type(rec.currency) == "string" and rec.currency or nil,   -- older lines: unknown
        rolledBack = rec.rolledBack == true,
    }
end

local function involves(out, username)
    return out.seller == username or out.bidder == username or out.buyer == username or out.previous == username
end

local function matchesQuery(out, query)
    local hay = string.lower(out.auctionId .. " " .. tostring(out.seller or "") .. " " .. tostring(out.bidder or "")
        .. " " .. tostring(out.buyer or "") .. " " .. tostring(out.previous or "") .. " " .. tostring(out.item or ""))
    if string.find(hay, query, 1, true) then return true end
    return string.find(W.itemNameLower(out.item), query, 1, true) ~= nil
end

-- auction.history {query?, auctionId?, requestId?}, and admin.auctions action="history" with the
-- same reply shape. Without auctionId a player sees only the auctions they took part in (seller,
-- bidder, buyer or outbid); with one they see that auction's whole public timeline, which
-- auction.browse already shows live. `admin` = { write = bool } grants the server-wide view and is
-- only ever passed by the gated admin handler.
function Au.history(player, args, admin)
    local command = admin and "admin.auctions" or "auction.history"
    local username = player:getUsername()
    args = type(args) == "table" and args or {}
    local extra = { history = true, query = "" }
    if admin then extra.perms = { read = true, write = admin.write == true } end
    local function fail()
        local reply = { entries = {}, total = 0, truncated = false, error = "invalid_args" }
        for k, v in pairs(extra) do reply[k] = v end
        S.reply(player, command, reply)
    end
    if args.requestId ~= nil then
        if type(args.requestId) ~= "string" or args.requestId == "" or #args.requestId > Au.HISTORY_ID_CHARS then return fail() end
        extra.requestId = args.requestId
    end
    local query = nil
    if args.query ~= nil then
        if type(args.query) ~= "string" then return fail() end
        local trimmed = (string.gsub(args.query, "^%s*(.-)%s*$", "%1"))
        if #trimmed > Au.HISTORY_QUERY_CHARS then return fail() end
        extra.query = trimmed
        if trimmed ~= "" then query = string.lower(trimmed) end
    end
    local auctionId = nil
    if args.auctionId ~= nil then
        if type(args.auctionId) ~= "string" or args.auctionId == "" or #args.auctionId > Au.HISTORY_ID_CHARS
            or not string.match(args.auctionId, "^[%w:%.%-_]+$") then return fail() end
        auctionId = args.auctionId
        extra.auctionId = auctionId
    end
    W.tail(player, command, W.eventPaths(EC.now()), extra, function(rec)
        local out = historyRecord(rec)
        if not out then return nil end
        if auctionId then
            if out.auctionId ~= auctionId then return nil end
        elseif not admin and not involves(out, username) then
            return nil
        end
        if query and not matchesQuery(out, query) then return nil end
        return out
    end)
end

-- ---------- commands ----------

S.handlers["auction.browse"] = function(player, args)
    local res = Au.browse(player:getUsername(), args)
    res.atTerminal = T.near(player)
    res.requestId = type(args) == "table" and type(args.requestId) == "string" and #args.requestId <= 96 and args.requestId or nil
    S.reply(player, "auction.browse", res)
end

S.handlers["auction.mine"] = function(player, args)
    local res = Au.mine(player:getUsername())
    res.atTerminal = T.near(player)
    res.maxAuctions = EC.sandbox("AuctionMaxPerPlayer", 3)
    res.requestId = type(args.requestId) == "string" and #args.requestId <= 96 and args.requestId or nil
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

S.handlers["auction.history"] = function(player, args)
    Au.history(player, args, nil)
end

-- Load boundary (spec contract 13): an auction written before the market had more than one
-- currency carries none, and neither does the bid standing on it. Whether this row is one of
-- those is decided once, from its shape as it was read - before anything is normalised - and
-- only such a row may have its standing bid's currency filled in from the auction. A row that
-- already carries the schema mark is current data: a missing currency on its highest bid is
-- incomplete new data, not old data, and it is held rather than guessed (report ER-03). A
-- standing bid that names another currency than the auction is held either way: no bid, no
-- settlement, no refund in a guessed currency. Bounded by MAX_AUCTIONS, once per start.
local function adoptCurrencies()
    local held = 0
    for _, a in pairs(md.auctions.items) do
        local legacyAuction = a.currency == nil and a.tradeSchema == nil
        if legacyAuction and a.highest and L.isCurrency(a.highest.currency) then
            -- the standing bid is the better witness of what money is actually reserved
            a.currency = a.highest.currency
        end
        local currency = L.normalizeRecord(a, L.TRUST_SERVER)
        if currency == nil then
            a.blocked, a.heldReported = "currency_unknown", nil
            held = held + 1
        elseif a.highest and a.highest.currency ~= currency then
            if legacyAuction and a.highest.currency == nil and a.highest.tradeSchema == nil then
                a.highest.currency, a.highest.tradeSchema = currency, L.TRADE_SCHEMA
                a.blocked = nil
            else
                a.blocked = a.highest.currency == nil and "currency_unknown" or "currency_conflict"
                a.heldReported = nil
                held = held + 1
            end
        else
            a.blocked = nil
        end
    end
    if held > 0 then
        X.emit("auction.held", { reason = "currency_unprovable", auctions = held })
        EC.log("auctions: " .. tostring(held) .. " held, currency cannot be proved")
    end
end

function Au.init(root)
    md = root
    md.auctions = md.auctions or { items = {}, byOwner = {}, count = 0 }
    lastSweep = 0
    adoptCurrencies()
    local action, downtime = Au.applyDowntime(EC.now(), readHeartbeat())
    EC.log("auctions: " .. tostring(md.auctions.count) .. " active, downtime " .. tostring(math.floor((downtime or 0) / 60000)) .. " min -> " .. action)
end

S.Auction = Au
S.onInit(Au.init)
Events.OnTickEvenPaused.Add(Au.onTick)
return Au
