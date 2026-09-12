-- MinidoracatEconomyFor42 - central escrow market (server authority; spec 12 stage D, 19.7).
--
-- Listings live in Global ModData with a bounded item snapshot (ECCodec); the physical item left
-- the seller through `list-out` (rule two): M.beginOut records the operation and the origin of
-- every unit in the seller's own modData before the item is removed, so a world rollback can
-- rebuild the listing from the player save (rule three, rows 4-6, in ECMailbox.reconcileOuts),
-- and M.finishOut writes the transfer receipt that keeps it from being rebuilt twice. A refused
-- list-out removes nothing: M.abortOut hands the very same objects back, never a rebuilt copy.
-- A sale moves money and the snapshot in one
-- tick (buyer -price, seller +price-tax, tax burned, snapshot into the buyer's mailbox) and then
-- claim-in hands the rebuilt item over. Cancels and expiries return the snapshot to the seller's
-- mailbox the same way. Money never moves without the listing changing in the same tick.
--
-- Currency (spec contract 6): the seller picks it when the listing is created and it is fixed
-- into the listing from that moment - the fee, the sale, the tax and every record read it off
-- the listing. A buyer sends the currency it believes it is paying in and that is checked
-- against the listing, never used to decide the settlement. Listings written before the market
-- had more than one currency are normalised once at load; one whose currency cannot be proved
-- is held (it can still be cancelled, delisted and expired - none of those move money) instead
-- of being settled in a guessed one.

if not MinidoracatEconomy or not MinidoracatEconomy.Codec then
    require "MinidoracatEconomy/ECCodec"
end
local EC = MinidoracatEconomy
local S = EC and EC.Server
local L = EC and EC.Ledger
local X = EC and EC.Export
local Cfg = EC and EC.Config
local T = EC and EC.Terminal
local M = EC and EC.Mailbox
local Codec = EC and EC.Codec
if not S or not S.AUTHORITY or not L or not X or not Cfg or not T or not M or not Codec then
    return
end

EC.Market = EC.Market or {}
local Mk = EC.Market

Mk.BURN_ACCOUNT = "SYSTEM_BURN"
Mk.MAX_LISTINGS = 2000            -- server-wide (spec 20 budget)
Mk.PAGE = 20
Mk.CANDIDATES_MAX = 200
Mk.SELLERS_MAX = 30               -- seller candidates one market.sellers reply ever carries
Mk.SWEEP_EVERY_MS = 60000
Mk.QUERY_MAX = 64
Mk.QTY_MAX = 50                   -- identical items one listing may bundle (one snapshot, rebuilt qty times)
-- The widest price the wire shape accepts. It is not the host's limit - MarketPriceMin /
-- MarketPriceMax are, and those are read after the idempotency record has been looked up, so a
-- narrowed range cannot re-judge a listing that was already paid for. This one only keeps a
-- request that is not a sane integer out of the fingerprint.
Mk.PRICE_CEILING = 1000000000
Mk.CURRENCY_ALL = "all"

-- Browse sort keys (column headers of the market page): name is the script DisplayName the
-- server has (English), time is newest first by default. The two price sorts compare money and
-- are therefore only meaningful inside one currency (spec contract 7).
local function lname(l) return string.lower(tostring(l.name or l.item or "")) end
Mk.SORTS = {
    time = { key = function(l) return l.at or 0 end, desc = true },
    time_asc = { key = function(l) return l.at or 0 end, desc = false },
    price = { key = function(l) return l.price or 0 end, desc = false, money = true },
    price_desc = { key = function(l) return l.price or 0 end, desc = true, money = true },
    name = { key = lname, desc = false },
    name_desc = { key = lname, desc = true },
    seller = { key = function(l) return string.lower(tostring(l.seller or "")) end, desc = false },
    seller_desc = { key = function(l) return string.lower(tostring(l.seller or "")) end, desc = true },
    expires = { key = function(l) return l.expiresAt or 0 end, desc = false },
    expires_desc = { key = function(l) return l.expiresAt or 0 end, desc = true },
    qty = { key = function(l) return l.qty or 1 end, desc = false },
    qty_desc = { key = function(l) return l.qty or 1 end, desc = true },
}

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

-- Active listings of one seller: they occupy mailbox slots (ECMailbox.used).
function Mk.ownerCount(username) return ownerCount(username) end

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

-- ---------- currencies ----------

-- Registered, tradable (marketUnit) and not switched off at runtime. Returns the currency
-- record, or nil plus the refusal code. There is no "the market currency": every listing names
-- its own.
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

-- A resend is answered from the ledger's record of the first attempt. `order` is what this
-- request is: every key in it must match what the first attempt recorded, or the id is being
-- reused for a different order (another listing, another currency, another price) and is
-- refused instead of being answered with someone else's result (spec contract 12). The reply
-- always names the currency that was actually recorded, never the one the resend guessed.
local function priorOrder(requestId, order)
    local prior = L.priorResult(requestId)
    if not prior then return nil end
    local meta = prior.meta or {}
    for key, value in pairs(order) do
        if meta[key] ~= value then
            return { ok = false, error = "request_conflict", listingId = meta.listingId,
                currency = meta.currency, price = meta.price }
        end
    end
    return { ok = prior.ok, txId = prior.txId, duplicate = true, error = prior.error,
        listingId = meta.listingId, currency = meta.currency, price = meta.price }
end

-- ---------- views ----------

-- `weight` is one copy's estimate: the real weight of the listed item, taken when it was listed,
-- and the script estimate for a listing that predates the field. It is what lets the buyer see
-- whether a lot would fit before asking for it. `currency` is the listing's own - a row without
-- one is a held legacy record and says so instead of borrowing another currency's name.
local function view(l)
    local s = l.snapshot or {}
    return {
        id = l.id, seller = l.seller, item = l.item, name = l.name, category = l.category, qty = l.qty or 1,
        price = l.price, currency = l.currency, blocked = l.blocked, at = l.at, expiresAt = l.expiresAt,
        weight = l.weight or M.scriptWeight(l.item),
        condition = s.condition, uses = s.uses, fluid = s.fluid and s.fluid.name or nil, fluidAmount = s.fluid and s.fluid.amount or nil,
    }
end

-- Seller-side push: sold / expired / delisted happen without the seller asking, so the online
-- seller hears about it (toast + mailbox badge) instead of finding out on the next refresh.
local function notify(username, fields)
    local p = S.onlinePlayer(username)
    if not p then return end
    fields.unclaimed = M.unclaimed(username)
    S.reply(p, "market.notice", fields)
end

-- Search space on the server is what it can compare without translations: fullType, the script
-- DisplayName (English) and the seller; the client re-filters the page by translated names.
local function matches(l, category, query, seller, currency)
    -- `seller` is an exact account name, compared byte for byte: asking for "bob" must never
    -- answer with "bobby", and an offline seller's rows are as visible as an online one's
    if seller and l.seller ~= seller then return false end
    if currency and l.currency ~= currency then return false end
    if category and l.category ~= category then return false end
    if query then
        local hay = string.lower(tostring(l.item) .. " " .. tostring(l.name or "") .. " " .. tostring(l.seller))
        if not string.find(hay, query, 1, true) then return false end
    end
    return true
end

-- args.currency = "all" (default) or one registered currency id. The reply echoes the filter it
-- used. A price sort across currencies would compare 10 cat coins with 10 survivor coins, so it
-- is refused with currency_required instead of being answered with a meaningless order.
function Mk.browse(username, args)
    args = type(args) == "table" and args or {}
    local category = type(args.category) == "string" and args.category ~= "" and args.category or nil
    -- an account name is bounded: a longer one matches nothing anyway, and it is not worth
    -- carrying through the scan
    local seller = type(args.seller) == "string" and args.seller ~= "" and #args.seller <= 64
        and args.seller or nil
    local query = type(args.query) == "string" and string.lower(string.sub((string.gsub(args.query, "^%s*(.-)%s*$", "%1")), 1, Mk.QUERY_MAX)) or ""
    if query == "" then query = nil end
    local sort = Mk.SORTS[args.sort] and args.sort or "time"
    local page = isInt(args.page, 1, 100000) and args.page or 1
    local currency = Mk.CURRENCY_ALL
    if args.currency ~= nil and args.currency ~= Mk.CURRENCY_ALL then
        if not L.isCurrency(args.currency) then
            return { ok = false, error = "unknown_currency", currency = args.currency, sort = sort,
                items = {}, page = 1, pages = 1, total = 0, categories = {}, currencies = tradableCurrencies() }
        end
        currency = args.currency
    end
    if currency == Mk.CURRENCY_ALL and Mk.SORTS[sort].money then
        return { ok = false, error = "currency_required", currency = Mk.CURRENCY_ALL, sort = sort,
            items = {}, page = 1, pages = 1, total = 0, categories = {}, currencies = tradableCurrencies() }
    end
    local filter = currency ~= Mk.CURRENCY_ALL and currency or nil
    local rows = {}
    for _, l in pairs(md.market.listings) do
        if matches(l, category, query, seller, filter) then rows[#rows + 1] = l end
    end
    local key, desc = Mk.SORTS[sort].key, Mk.SORTS[sort].desc
    EC.sortSafe(rows, function(a, b)
        local av, bv = key(a), key(b)
        if av ~= bv then
            if desc then return av > bv end
            return av < bv
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
        ok = true, page = page, pages = pages, total = total, items = out, categories = catList,
        currency = currency, currencies = tradableCurrencies(),
        sort = sort, category = category, query = query, seller = seller,
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
-- the reason, so the picker can grey out the rest instead of round-tripping per item. Identical
-- copies (same snapshot signature and verdict) fold into one row with every itemId, so the
-- picker offers a quantity instead of forty plank tiles.
function Mk.candidates(player)
    local out, groups = {}, {}
    local inv = player:getInventory()
    if not inv then return out end
    local ok, items = pcall(function() return inv:getItems() end)
    if not ok or not items then return out end
    for i = 0, items:size() - 1 do
        if #out >= Mk.CANDIDATES_MAX then break end
        local it = items:get(i)
        if it then
            local pass, reason = Codec.check(it)
            local id, fullType = nil, nil
            pcall(function() id = it:getID() fullType = it:getFullType() end)
            if id and fullType then
                local key = fullType .. "|" .. tostring(pass == true) .. "|" .. tostring(reason or "")
                if pass then key = key .. "|" .. Codec.signature(Codec.snapshot(it)) end
                local row = groups[key]
                if row then
                    row.itemIds[#row.itemIds + 1] = id
                    row.count = row.count + 1
                else
                    row = { itemId = id, itemIds = { id }, count = 1, item = fullType, ok = pass == true, reason = (not pass) and reason or nil }
                    pcall(function()
                        row.condition = it:getCondition()
                        row.uses = it:getCurrentUses()
                        row.category = it:getDisplayCategory()
                    end)
                    groups[key] = row
                    out[#out + 1] = row
                end
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

-- args = { itemIds | itemId, price, currency, requestId }: interchangeable copies from the top
-- level of the backpack; price is for the whole lot, in the currency the seller chose. That
-- currency is fixed into the listing here and everything downstream reads it off the listing.
function Mk.list(player, args)
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
    local currency = args.currency
    local price = args.price
    -- The shape of the request is checked here; what the live configuration currently allows is
    -- checked after the record has been looked up. A listing that was already paid for must not
    -- be re-judged by settings that changed since: an admin switching the currency off or
    -- narrowing the price range between the listing and its resend would otherwise answer a
    -- committed operation with currency_disabled / price_range, and the player would never learn
    -- the id, the currency or the result of the operation they already paid for (FINAL-LEDGER-2).
    if not isInt(price, 1, Mk.PRICE_CEILING) then return { ok = false, error = "price_range" } end
    -- a new listing has no id yet, so the order it is measured against is its currency, its
    -- price and the exact batch it lists: the same requestId carrying another pile of items is
    -- another listing, not a resend of this one
    local requestId = "list:" .. username .. ":" .. args.requestId
    -- the whole namespaced key is what the record is stored under, and it is checked here,
    -- before any item leaves the backpack: an operation must never complete without one
    -- (report CORE-M2)
    if not L.validRequestKey(requestId) then return { ok = false, error = "request_too_long" } end
    local batch = L.batchKey(ids, Mk.QTY_MAX)
    if batch == nil then return { ok = false, error = "invalid_args" } end
    local prior = priorOrder(requestId, { currency = currency, price = price, items = batch })
    if prior then return prior end
    -- a new request: from here the live configuration decides
    local def, cerr = currencyState(currency)
    if not def then return { ok = false, error = cerr, currency = currency } end
    local pmin, pmax = EC.sandbox("MarketPriceMin", 1), EC.sandbox("MarketPriceMax", 1000000)
    if not isInt(price, pmin, pmax) then return { ok = false, error = "price_range", min = pmin, max = pmax } end
    if not T.near(player) then return { ok = false, error = "not_at_terminal" } end
    if L.isFrozen(username) then return { ok = false, error = "account_frozen" } end
    if ownerCount(username) >= EC.sandbox("MarketMaxListings", 5) then return { ok = false, error = "too_many_listings" } end
    if md.market.count >= Mk.MAX_LISTINGS then return { ok = false, error = "market_full" } end
    -- a listing occupies a mailbox slot from the start: whatever brings it back (sale is money,
    -- but cancel / expiry / delist are items) already has its place
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
    local fee = pct(price, EC.sandbox("MarketListingFeePercent", 2))
    if fee > 0 and L.getBalance(username, currency).available < fee then
        return { ok = false, error = "insufficient_funds", fee = fee, currency = currency }
    end

    local ms = EC.now()
    for _, item in ipairs(items) do Codec.detachParts(item, inv) end
    local snapshot = Codec.snapshot(items[1])
    local qty = #items
    local id = S.newId()
    local _, seq = EC.parseId(id)
    -- phase 1: the seller's own save records the operation and the exact origin of every unit
    -- before anything is removed. A refusal here has moved no item and charged no fee.
    local rec = { itemId = ids[1], itemIds = ids, qty = qty, lotQty = qty, snapshot = snapshot,
        kind = "listing", price = price, currency = currency, tradeSchema = L.TRADE_SCHEMA,
        seq = seq, epoch = md.meta.epoch, at = ms }
    local began, beginErr, beginDetail = M.beginOut(player, id, items, rec)
    -- the refusal names the unit it happened on, so the seller is not told "the source could not
    -- be verified" for four different problems
    if not began then
        return { ok = false, error = beginErr, recovery = M.recoveryStatus(username),
            recoveryDetail = beginDetail }
    end
    -- phase 2: the items leave the backpack
    local taken, takeError = M.takeOut(player, id, items)
    if not taken then return { ok = false, error = takeError, recovery = M.recoveryStatus(username) } end
    -- phase 3: listing + fee in ModData (same tick). pending stays until reconcile clears it.
    local name, category = nil, nil
    pcall(function() name = ScriptManager.instance:FindItem(snapshot.type):getDisplayName() end)
    pcall(function() category = items[1]:getDisplayCategory() end)
    local l = {
        id = id, seller = username, item = snapshot.type, snapshot = snapshot, qty = qty, price = price,
        currency = currency, tradeSchema = L.TRADE_SCHEMA, fee = fee,
        at = ms, expiresAt = ms + EC.sandbox("MarketListingDays", 7) * 86400000, weight = M.itemWeight(items[1]),
        category = type(category) == "string" and category or "other", name = type(name) == "string" and name or nil,
    }
    addListing(l)
    if fee > 0 then
        local res = L.debit(username, currency, fee, Mk.BURN_ACCOUNT, {
            kind = "market_fee", requestId = requestId, reasonCode = "market_fee",
            idemMeta = { listingId = id, currency = currency, price = price, items = batch },
            payload = { item = snapshot.type, qty = qty, listingId = id, currency = currency },
        })
        if not res.ok then
            -- balance was checked above; only a ledger-level refusal can land here (frozen
            -- mid-tick). The very objects that left the backpack go back into it: nothing is
            -- rebuilt from the snapshot, so no copy can outlive the refusal.
            removeListing(id)
            local returned = M.abortOut(player, id, items)
            return { ok = false, error = returned and res.error or "recovery_pending", recovery = M.recoveryStatus(username) }
        end
    end
    -- the world side is committed: the transfer receipt consumes those origins exactly once,
    -- so a later login with an older save cannot list them a second time
    local recorded, recordError = M.finishOut(username, id, rec, "listing", id)
    if not recorded then error("list-out receipt invariant: " .. tostring(recordError)) end
    if fee <= 0 then
        -- a fee percent of 0 is a legal configuration, so this listing moved no money and the
        -- ledger has no transaction to remember it by. It records the operation in the same
        -- idempotency ring instead, so a resend is answered from the record and a reused id
        -- carrying another batch or price is the same request_conflict a paid listing answers.
        -- The key was validated before the items moved, so a refusal here can only mean the
        -- window already holds this key: that is an anomaly worth seeing, not a silent pass.
        if not L.noteOperation(requestId, id, { listingId = id, currency = currency, price = price, items = batch }) then
            EC.log("market listing " .. id .. ": the idempotency record was refused")
            X.emit("ledger.anomaly", { kind = "market", listingId = id, username = username,
                resolution = "idempotency-record-refused" })
        end
    end
    X.emit("market.listed", { listingId = id, seller = username, item = snapshot.type, qty = qty, price = price, fee = fee, currency = currency, expiresAt = l.expiresAt })
    X.market(username, { kind = "listed", listingId = id, item = snapshot.type, qty = qty, price = price, fee = fee, currency = currency })
    return { ok = true, listingId = id, qty = qty, fee = fee, price = price, currency = currency, expiresAt = l.expiresAt }
end

-- ---------- returns (cancel / expiry / admin delist) ----------

-- Listing -> seller mailbox. The listing already held the slot the entry takes, so this never
-- fails (cancel, expiry and admin delist alike). No money moves here, which is why a listing
-- whose currency could not be proved can still come home this way.
local function returnListing(l, reasonKind, extra)
    removeListing(l.id)
    local qty = l.qty or 1
    -- a held listing carries a currency this server could not prove: the letter says what the
    -- goods were, not a currency name nobody can resolve
    local currency = L.isCurrency(l.currency) and l.currency or nil
    local entry = M.add(l.seller, { kind = "return", item = l.item, qty = qty, txId = nil, price = l.price,
        currency = currency, snapshot = l.snapshot, listingId = l.id })
    X.emit("market." .. reasonKind, { listingId = l.id, seller = l.seller, item = l.item, qty = qty,
        price = l.price, currency = l.currency, mailId = entry.id })
    local line = { kind = reasonKind, listingId = l.id, item = l.item, qty = qty, price = l.price,
        currency = l.currency, mailId = entry.id }
    for k, v in pairs(extra or {}) do line[k] = v end
    X.market(l.seller, line)
    return true, entry
end

function Mk.cancel(player, args)
    local username = player:getUsername()
    if not validRequest(args) or type(args.listingId) ~= "string" then return { ok = false, error = "invalid_args" } end
    if not T.near(player) then return { ok = false, error = "not_at_terminal" } end
    local l = md.market.listings[args.listingId]
    if not l then return { ok = false, error = "unknown_listing" } end
    if l.seller ~= username then return { ok = false, error = "not_owner" } end
    local _, entryOrErr = returnListing(l, "cancelled")
    local out = { ok = true, listingId = l.id, mailId = entryOrErr.id, currency = l.currency }
    return M.deliveryFields(out, M.claim(player, entryOrErr.id), l.qty or 1)
end

function Mk.delist(admin, listingId, reason)
    local l = md.market.listings[listingId]
    if not l then return false, "unknown_listing" end
    returnListing(l, "delisted", { admin = admin, reason = reason })
    X.audit({ action = "delist", admin = admin, target = l.seller, field = listingId, before = tostring(l.item),
        after = tostring(l.price), currency = l.currency, reason = reason })
    notify(l.seller, { kind = "delisted", listingId = l.id, item = l.item, qty = l.qty or 1, price = l.price,
        currency = l.currency, reason = reason })
    return true
end

-- ---------- sale ----------

-- args = { listingId, price, currency, acceptMail, requestId }. The buyer's letter is prepared
-- before any money moves: a snapshot this server can no longer rebuild refuses the sale instead
-- of charging for it, and a lot that does not fit the backpack is refused with
-- mail_confirmation_required - nothing posted, the listing untouched - until the client confirms
-- the mailbox once. With acceptMail the lot is parked in the mailbox and the prepared objects
-- are handed over when it does fit (never built twice). priorResult still answers first, so a
-- resend never buys twice. `currency` and `price` are the buyer's understanding of the deal and
-- are checked against the listing's own: they never decide what the sale settles in.
function Mk.buy(player, args)
    local username = player:getUsername()
    if not validRequest(args) or type(args.listingId) ~= "string" then return { ok = false, error = "invalid_args" } end
    if type(args.currency) ~= "string" or args.currency == "" then return { ok = false, error = "invalid_args" } end
    if args.acceptMail ~= nil and type(args.acceptMail) ~= "boolean" then return { ok = false, error = "invalid_args" } end
    -- The price the buyer confirmed is part of the order, not an optional courtesy: it is what
    -- the player agreed to pay, so the same requestId sent with another number is another
    -- intent and must be refused rather than answered with the first sale (FINAL-LEDGER-3).
    -- Leaving it out would be a second, unfingerprinted way to ask for the same thing.
    if not isInt(args.price, 1, Mk.PRICE_CEILING) then return { ok = false, error = "invalid_args" } end
    local requestId = "buy:" .. username .. ":" .. args.requestId
    if not L.validRequestKey(requestId) then return { ok = false, error = "request_too_long" } end
    local prior = priorOrder(requestId, { listingId = args.listingId, currency = args.currency,
        price = args.price })
    if prior then return prior end
    if not T.near(player) then return { ok = false, error = "not_at_terminal" } end
    if L.isFrozen(username) then return { ok = false, error = "account_frozen" } end
    local l = md.market.listings[args.listingId]
    if not l then return { ok = false, error = "unknown_listing" } end
    if l.seller == username then return { ok = false, error = "own_listing" } end
    if l.blocked then return { ok = false, error = "currency_unknown", listingId = l.id } end
    local currency = l.currency
    if args.currency ~= currency then
        return { ok = false, error = "currency_mismatch", listingId = l.id, currency = currency }
    end
    local def, cerr = currencyState(currency)
    if not def then return { ok = false, error = cerr, currency = currency } end
    if args.price ~= l.price then return { ok = false, error = "price_changed", price = l.price, currency = currency } end
    if not M.hasFreeSlot(username) then return { ok = false, error = "mailbox_full" } end
    if L.getBalance(username, currency).available < l.price then
        return { ok = false, error = "insufficient_funds", currency = currency, price = l.price }
    end
    local qty = l.qty or 1
    local prepared, perr = M.prepare(player, { item = l.item, qty = qty, snapshot = l.snapshot })
    if not prepared then return { ok = false, error = perr or "item_unavailable" } end
    if not prepared.fits and args.acceptMail ~= true then
        return { ok = false, error = "mail_confirmation_required", willMail = true, listingId = l.id, item = l.item,
            qty = prepared.qty, totalWeight = prepared.totalWeight, price = l.price, currency = currency }
    end
    local tax = pct(l.price, EC.sandbox("MarketSalesTaxPercent", 5))
    if tax >= l.price then tax = l.price - 1 end
    if tax < 0 then tax = 0 end
    local postings = {
        { account = username, currency = currency, amount = -l.price },
        { account = l.seller, currency = currency, amount = l.price - tax },
    }
    if tax > 0 then postings[#postings + 1] = { account = Mk.BURN_ACCOUNT, currency = currency, amount = tax } end
    local res = L.post({
        kind = "market_buy", requestId = requestId, reasonCode = "market_buy", actor = username,
        idemMeta = { listingId = l.id, currency = currency, price = l.price },
        payload = { item = l.item, qty = qty, listingId = l.id, seller = l.seller, buyer = username, tax = tax, currency = currency },
        postings = postings,
    })
    if not res.ok then return { ok = false, error = res.error, currency = currency } end
    removeListing(l.id)
    -- Keep the seller on the letter after the listing is removed.
    local entry = M.add(username, { kind = "market", item = l.item, qty = qty, txId = res.txId, price = l.price,
        currency = currency, seller = l.seller, snapshot = l.snapshot, listingId = l.id })
    X.emit("market.sold", { listingId = l.id, seller = l.seller, buyer = username, item = l.item, qty = qty, price = l.price, tax = tax, currency = currency, txId = res.txId, mailId = entry.id })
    X.market(l.seller, { kind = "sold", listingId = l.id, item = l.item, qty = qty, price = l.price, tax = tax, currency = currency, txId = res.txId, other = username })
    X.market(username, { kind = "bought", listingId = l.id, item = l.item, qty = qty, price = l.price, currency = currency, txId = res.txId, other = l.seller })
    notify(l.seller, { kind = "sold", listingId = l.id, item = l.item, qty = qty, price = l.price, tax = tax, currency = currency, buyer = username })
    local out = {
        ok = true, txId = res.txId, listingId = l.id, mailId = entry.id, item = l.item, qty = qty, price = l.price, tax = tax, currency = currency,
        balance = L.getBalance(username, currency).available,
    }
    if prepared.fits then
        -- delivered/deliveryError plus the item counts: a handover that only settled part of
        -- the lot says so in deliveredQty/remainingQty instead of reading as a total loss
        M.deliveryFields(out, M.claim(player, entry.id, prepared), qty)
    else
        -- the buyer asked for the mailbox: park it there instead of a failed handover
        M.deliveryFields(out, nil, qty)
        out.mailed = true
    end
    return out
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
    for _, l in ipairs(dead) do
        returnListing(l, "expired")
        notify(l.seller, { kind = "expired", listingId = l.id, item = l.item, qty = l.qty or 1, price = l.price,
            currency = l.currency })
    end
end

-- ---------- rebuild from a pending record (rule three row 4, called by ECMailbox.reconcileOuts) ----------

-- Returns ok, info - and every refusal carries an info table, so the reconcile can name the
-- held record without guarding for a missing one. info carries what ECMailbox needs to finish a
-- recovery it cannot complete here: a lot whose units were only partly accounted for is not
-- relisted, because the price was for the whole lot and guessing a share of it would reprice the
-- seller's goods behind their back. ECMailbox writes the transfer receipt for the restores that
-- did succeed.
function Mk.restoreFromPending(username, id, pend)
    -- `pend` here is never the player's own pending: ECMailbox passes the server's journal
    -- record for this operation, marked `proven`. Without that mark the caller skipped the
    -- proof, and nothing is rebuilt from it (report CORE-H1).
    local Rec = S.Recovery
    if Rec == nil or type(Rec.isProven) ~= "function" or not Rec.isProven(pend) then
        return false, { reason = "proof_required", kind = type(pend) == "table" and pend.kind or nil }
    end
    if pend.kind == "auction" then
        local Au = S.Auction
        if Au == nil then return false, { reason = "restore_failed", cause = "no_auction_module", kind = "auction" } end
        return Au.restoreFromPending(username, id, pend)
    elseif pend.kind == "buyback" then
        if S.Shop == nil then return false, { reason = "restore_failed", cause = "no_shop_module", kind = "buyback" } end
        return S.Shop.restoreFromPending(username, id, pend)
    end
    if md.market.listings[id] then
        return false, { reason = "restore_failed", cause = "listing_exists", kind = "listing" }
    end
    local qty, lotQty = pend.qty or 1, pend.lotQty or pend.qty or 1
    if isInt(qty, 1, Mk.QTY_MAX) and isInt(lotQty, 1, Mk.QTY_MAX) and qty < lotQty then
        return false, { reason = "partial_lot", kind = "listing", item = pend.snapshot and pend.snapshot.type or nil,
            snapshot = pend.snapshot, qty = qty, lotQty = lotQty, price = pend.price }
    end
    -- the listing comes back in the currency it was created in, or it does not come back: a
    -- relist priced in a guessed currency is a repricing of someone else's goods
    local currency = L.normalizeRecord(pend, L.TRUST_SERVER)
    if currency == nil then
        return false, { reason = "currency_unknown", kind = "listing", item = pend.snapshot and pend.snapshot.type or nil,
            snapshot = pend.snapshot, qty = qty, lotQty = lotQty, price = pend.price }
    end
    local l = {
        id = id, seller = username, item = pend.snapshot and pend.snapshot.type or nil, snapshot = pend.snapshot,
        qty = pend.qty or 1, price = pend.price, currency = currency, tradeSchema = L.TRADE_SCHEMA, fee = 0,
        at = pend.at or EC.now(), expiresAt = (pend.at or EC.now()) + EC.sandbox("MarketListingDays", 7) * 86400000, category = "other",
    }
    if type(l.item) ~= "string" or not isInt(l.price, 1, 1000000000) or not isInt(l.qty, 1, Mk.QTY_MAX) then
        return false, { reason = "restore_failed", cause = "bad_record", kind = "listing", item = l.item,
            snapshot = pend.snapshot, qty = l.qty, lotQty = lotQty, price = l.price }
    end
    l.weight = M.scriptWeight(l.item)
    pcall(function()
        local script = ScriptManager.instance:FindItem(l.item)
        l.name = script:getDisplayName()
        l.category = script:getDisplayCategory() or "other"
    end)
    addListing(l)
    X.market(username, { kind = "restored", listingId = id, item = l.item, qty = l.qty, price = l.price, currency = currency })
    return true
end

-- What the live listing under this id actually is, for the recovery core: who owns it, what it
-- holds and how many units. "There is something under this id" is not enough to act on a
-- pending record that merely named the id (report CORE-H1 follow-up).
function Mk.operationInfo(id)
    local l = type(id) == "string" and md.market.listings[id] or nil
    if not l then return nil end
    return { kind = "listing", owner = l.seller, item = l.item, qty = l.qty or 1,
        price = l.price, currency = l.currency }
end

-- "The world side of this pending op happened" -> true, false, or nil for "no evidence either
-- way". The transfer receipt answers first and answers for good: it outlives a listing that has
-- since been sold, cancelled or expired, so a pending record from an older save can never
-- resurrect one. Without a receipt the live record speaks (listing or auction). A buyback has no
-- record to look at, so it is judged by the mint's own ledger idempotency key, and when a
-- pending is too old to carry that key the answer is nil: neither "paid" nor "unpaid" can be
-- shown, and guessing from the age of the stamp would either mint twice or swallow the goods.
-- A nil is the reconcile's cue to keep the record held, not a false.
function Mk.hasListing(id, pend)
    if M.hasOut(id) then return true end
    if md.market.listings[id] ~= nil then return true end
    local Au = S.Auction
    if Au ~= nil and Au.hasAuction(id) then return true end
    if type(pend) == "table" and pend.kind == "buyback" then
        if S.Shop == nil then return nil end
        return S.Shop.hasBuyback(pend)
    end
    return false
end

-- Only "is there a listing record right now": no receipt, no epoch guess. The reconcile needs
-- this apart from hasListing to see that a cancelled listing came back with a world rollback -
-- which means its derived claim/relist must be undone, not restored. Au.hasAuction is the same
-- shape for auctions.
function Mk.listingExists(id) return md.market.listings[id] ~= nil end

function Mk.stats()
    local byCurrency, held = {}, 0
    for _, l in pairs(md.market.listings) do
        if l.blocked then held = held + 1
        elseif l.currency then byCurrency[l.currency] = (byCurrency[l.currency] or 0) + 1 end
    end
    return { listings = md.market.count, max = Mk.MAX_LISTINGS, byCurrency = byCurrency, held = held }
end

-- ---------- commands ----------

S.handlers["market.browse"] = function(player, args)
    local res = Mk.browse(player:getUsername(), args)
    res.atTerminal = T.near(player)
    res.requestId = type(args) == "table" and type(args.requestId) == "string" and #args.requestId <= 96 and args.requestId or nil
    S.reply(player, "market.browse", res)
end

S.handlers["market.mine"] = function(player, args)
    S.reply(player, "market.mine", { items = Mk.mine(player:getUsername()), maxListings = EC.sandbox("MarketMaxListings", 5),
        atTerminal = T.near(player), requestId = type(args.requestId) == "string" and #args.requestId <= 96 and args.requestId or nil })
end

S.handlers["market.candidates"] = function(player, args)
    S.reply(player, "market.candidates", {
        items = Mk.candidates(player), atTerminal = T.near(player),
        feePercent = EC.sandbox("MarketListingFeePercent", 2), taxPercent = EC.sandbox("MarketSalesTaxPercent", 5),
        priceMin = EC.sandbox("MarketPriceMin", 1), priceMax = EC.sandbox("MarketPriceMax", 1000000),
        mine = ownerCount(player:getUsername()), maxListings = EC.sandbox("MarketMaxListings", 5),
        currencies = tradableCurrencies(),
        usage = M.usage(player:getUsername()),
    })
end

-- market.sellers {query, context = "market"|"auction", requestId} (public): the accounts that
-- actually have something on the board right now, so a player can pick a seller instead of
-- guessing how it is spelled. The source is md.market.byOwner / md.auctions.byOwner, which hold
-- exactly the sellers of live listings / live auctions and are pruned the moment the last one
-- goes (removeListing / Au.remove) -- so this never reaches the ledger's account list, the
-- frozen marks or an account that has never traded, which is what makes the read safe to hand
-- to everyone. A seller whose rows the browse page already shows is named here whatever the
-- state of their wallet: hiding them would only make the picker disagree with the rows on
-- screen. Offline sellers are listed too -- their listings are as buyable as anyone's.
-- requestId and context are echoed unchanged: one shared picker serves four pages.
S.handlers["market.sellers"] = function(player, args)
    args = type(args) == "table" and args or {}
    local requestId = type(args.requestId) == "string" and args.requestId ~= "" and #args.requestId <= 96
        and args.requestId or nil
    local context = (args.context == "market" or args.context == "auction") and args.context or nil
    if requestId == nil or context == nil then
        S.reply(player, "market.sellers", { ok = false, error = "invalid_args", query = "",
            players = {}, total = 0, truncated = false, requestId = requestId, context = context })
        return
    end
    local query = type(args.query) == "string" and args.query or ""
    query = string.lower(string.sub((string.gsub(query, "^%s*(.-)%s*$", "%1")), 1, Mk.QUERY_MAX))
    local owners = md.market.byOwner
    if context == "auction" then owners = (md.auctions and md.auctions.byOwner) or {} end
    -- Active owner sets are bounded by the market/auction limits; count them completely.
    local online = {}
    local players = getOnlinePlayers()
    for i = 0, players:size() - 1 do
        online[players:get(i):getUsername()] = true
    end
    local names = {}
    for name in pairs(owners) do
        if query == "" or string.find(string.lower(name), query, 1, true) then
            names[#names + 1] = name
        end
    end
    EC.sortSafe(names, function(a, b)
        if (online[a] == true) ~= (online[b] == true) then return online[a] == true end
        return string.lower(a) < string.lower(b)
    end)
    local list = {}
    for i = 1, math.min(#names, Mk.SELLERS_MAX) do
        local name = names[i]
        list[i] = { username = name, online = online[name] == true }
    end
    S.reply(player, "market.sellers", { ok = true, query = query, context = context,
        players = list, total = #names, truncated = false, requestId = requestId })
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

-- The player's own market history: the newest lines of this and last month's market file (tailed
-- like the receipts; rolled-back lines are flagged by epoch/seq). The requestId is echoed so a
-- client can tell this reply from the one it asked for before.
S.handlers["market.history"] = function(player, args)
    local W = EC.Wallet
    local username = player:getUsername()
    local extra = { username = username }
    if type(args) == "table" and args.requestId ~= nil then
        if type(args.requestId) ~= "string" or args.requestId == "" or #args.requestId > 96 then
            S.reply(player, "market.history", { entries = {}, total = 0, truncated = false, error = "invalid_args", username = username })
            return
        end
        extra.requestId = args.requestId
    end
    W.tail(player, "market.history", W.marketPaths(username, W.recentMonths(EC.now())), extra)
end

-- Load boundary (spec contract 13): listings written before the market had more than one
-- currency carry none and no schema mark - those are provably the old single-currency ones and
-- are normalised and marked here, once. One that carries the mark but no usable currency cannot
-- be proved either way: it is held (no sale, no bid) and stays exactly as it is until an
-- administrator or its own expiry resolves it. Bounded by MAX_LISTINGS, once per start.
local function adoptCurrencies()
    local held = 0
    for _, l in pairs(md.market.listings) do
        if L.normalizeRecord(l, L.TRUST_SERVER) == nil then
            l.blocked = "currency_unknown"
            held = held + 1
        else
            l.blocked = nil
        end
    end
    if held > 0 then
        X.emit("market.held", { reason = "currency_unknown", listings = held })
        EC.log("market: " .. tostring(held) .. " listings held, currency cannot be proved")
    end
end

function Mk.init(root)
    md = root
    md.market = md.market or { listings = {}, byOwner = {}, count = 0 }
    lastSweep = 0
    adoptCurrencies()
end

S.Market = Mk
S.onInit(Mk.init)
Events.OnTickEvenPaused.Add(Mk.onTick)
return Mk
