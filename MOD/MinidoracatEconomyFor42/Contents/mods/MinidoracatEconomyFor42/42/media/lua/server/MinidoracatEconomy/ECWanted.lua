-- MinidoracatEconomyFor42 - player buy orders (server authority).
--
--   wanted.browse / wanted.mine / wanted.candidates / wanted.history       reads
--   wanted.create / wanted.fill / wanted.cancel                              money and goods
--   wanted.offer / wanted.raise / wanted.dismiss                             counter-offers
--   admin.wanted {action = list | cancel}                                    read / write gate
--
-- A buyer asks for one item type (1..50 units, optionally new-only or a minimum durability) and
-- offers up to three ways to be paid: at most one coin option per currency and at most one item
-- option (one kind of item, perUnit copies per unit wanted). Everything is escrowed when the
-- order is created:
--   * every coin option reserves unitPrice x qty in the buyer's own wallet (bucket "reserved") and
--     pays its listing fee in the same `wanted_create` transaction, so `held == unitPrice x qty`
--     for every coin option for as long as the order is open;
--   * the item option leaves the buyer's backpack through the ordinary list-out (M.beginOut ->
--     M.takeOut -> commit -> M.finishOut) as a "wanted" operation whose op id is the lot id, the
--     receipt ref and the listingId of every letter that later carries those goods - the same
--     shape as a market listing, so the recovery core recognises the lot as a live world holder
--     (Mk.hasListing, R.worldOperation, R.sourceAlive all ask Wd.lotExists / Wd.operationInfo).
-- A seller fills the order by choosing one option: the goods leave the seller's backpack as a
-- "fill" operation, and in the same tick the ledger pays (`wanted_fill`: the chosen coin to the
-- seller less the sales tax, every other coin option released by the units filled), the order
-- shrinks, the buyer gets a "wanted" letter (allowed past the mailbox cap, like an auction win)
-- and a seller paid in goods gets a "wanted_pay" letter out of the escrowed lot.
-- Closing (completed, cancelled, expired, admin) releases first (allowFrozen) and only then mails
-- the rest of the lot back; a release the ledger refuses keeps the order exactly as it is, marks
-- it blocked = "refund_failed" and the minute sweep tries again.
--
-- Crash semantics: an order is never rebuilt from a player save. What can be restored is what a
-- player save gave away - the buyer's lot ("wanted") or a seller's delivery ("fill") - and it is
-- mailed back to whoever gave it (Wd.restoreFromPending). The money lives in the world save and
-- rolls back with it. Commands, money flow and crash semantics: docs/economy-system-analysis.md section 22.

if not MinidoracatEconomy or not MinidoracatEconomy.Auction then
    require "MinidoracatEconomy/ECAuction"
end
if not MinidoracatEconomy or not MinidoracatEconomy.Admin then
    require "MinidoracatEconomy/ECAdmin"
end
local EC = MinidoracatEconomy
local S = EC and EC.Server
local L = EC and EC.Ledger
local X = EC and EC.Export
local T = EC and EC.Terminal
local M = EC and EC.Mailbox
local Codec = EC and EC.Codec
local Mk = EC and EC.Market
local W = EC and EC.Wallet
local A = EC and EC.Admin
if not S or not S.AUTHORITY or not L or not X or not T or not M or not Codec or not Mk or not W or not A or not A.gate then
    return
end

EC.Wanted = EC.Wanted or {}
local Wd = EC.Wanted

Wd.MAX_ORDERS = 500               -- server-wide: every item option is a receipt the recovery core keeps
Wd.PAGE = 20
Wd.OPTIONS_MAX = 3
Wd.QTY_MAX = Mk.QTY_MAX
Wd.CANDIDATES_MAX = 200
Wd.OFFERS_MAX = 10                -- per order
Wd.MEMO_MAX = 64                  -- characters (A.charCount), as a transfer memo
Wd.MEMO_FILE = X.ROOT .. "/wanted-memos.json"
Wd.SWEEP_EVERY_MS = 60000
Wd.QUERY_MAX = 64
Wd.BURN_ACCOUNT = "SYSTEM_BURN"

local md = nil
local lastSweep = 0
local lotIndex = {}               -- lot id -> order id (memory only, rebuilt at init)

local function isInt(v, lo, hi)
    return type(v) == "number" and v == math.floor(v) and v >= lo and v <= hi
end

local function requestIdOf(args)
    return type(args) == "table" and type(args.requestId) == "string" and args.requestId ~= ""
        and #args.requestId <= 96 and args.requestId or nil
end

-- ---------- offer memos (server-private file) ----------
--
-- A seller's note is free text, and Global ModData is not private (any logged-in client can
-- request the whole table): the offer in ModData carries everything but the note, which lives in
-- Wd.MEMO_FILE as NDJSON lines { k = "set", o, f, at, m } / { k = "del", o, f } keyed by the
-- order id and the offer's own `from`; `at` ties a note to that very offer. One open, the lines,
-- one close per write, and memory changes only after the write succeeded. A file that exists but
-- cannot be read is never rewritten: offers then take no note until it can be read.

local memos = {}                  -- orderId -> from -> { m, at } (what the file holds)
local memoLines = 0               -- lines in the file (the start compacts it)
local memoUnreadable = false

local function memoWrite(recs, append)
    local writer = nil
    local opened = pcall(function() writer = getFileWriter(Wd.MEMO_FILE, true, append) end)
    if not opened or writer == nil then
        EC.log("buy-order memo file " .. Wd.MEMO_FILE .. " could not be opened for writing")
        return false
    end
    local written = pcall(function()
        for _, rec in ipairs(recs) do writer:writeln(EC.jsonEncode(rec)) end
    end)
    local closed = pcall(function() writer:close() end)
    if not (written and closed) then
        EC.log("buy-order memo file write failed")
        return false
    end
    memoLines = append and memoLines + #recs or #recs
    return true
end

-- An offer written before the notes moved out may still hold its own until the start moves it.
local function memoOf(orderId, f)
    local e = memos[orderId] and memos[orderId][f.from]
    if e and e.at == f.at then return e.m end
    return f.memo
end

local function setMemo(orderId, f, text)
    if memoUnreadable or not memoWrite({ { k = "set", o = orderId, f = f.from, at = f.at, m = text } }, true) then
        return false
    end
    memos[orderId] = memos[orderId] or {}
    memos[orderId][f.from] = { m = text, at = f.at }
    return true
end

-- The notes of offers that are gone. A "del" line that fails to land leaves a note the file still
-- holds for an offer that no longer exists, which the next start prunes.
local function dropMemos(orderId, offers)
    local byFrom = memos[orderId]
    if not byFrom then return end
    local recs = {}
    for _, f in ipairs(offers) do
        if byFrom[f.from] then
            byFrom[f.from] = nil
            recs[#recs + 1] = { k = "del", o = orderId, f = f.from }
        end
    end
    if EC.countKeys(byFrom) == 0 then memos[orderId] = nil end
    if #recs > 0 then memoWrite(recs, true) end
end

local function memoLoad()
    memos, memoLines, memoUnreadable = {}, 0, false
    local reader = nil
    local opened = pcall(function() reader = getFileReader(Wd.MEMO_FILE, false) end)
    if not opened or reader == nil then
        local ok, exists = pcall(cacheFileExists, Wd.MEMO_FILE)
        if not ok or exists then
            memoUnreadable = true
            EC.log("buy-order memo file " .. Wd.MEMO_FILE .. " exists but could not be read: no new notes until it can be")
        end
        return
    end
    local bad = 0
    local readOk, readErr = pcall(function()
        while true do
            local line = reader:readLine()
            if line == nil then break end
            memoLines = memoLines + 1
            local rec = EC.jsonDecode(line)
            local byFrom = type(rec) == "table" and type(rec.o) == "string" and type(rec.f) == "string" and memos[rec.o] or nil
            if type(rec) ~= "table" or type(rec.o) ~= "string" or type(rec.f) ~= "string" then
                bad = bad + 1
            elseif rec.k == "set" and type(rec.m) == "string" and type(rec.at) == "number" then
                memos[rec.o] = byFrom or {}
                memos[rec.o][rec.f] = { m = rec.m, at = rec.at }
            elseif rec.k == "del" then
                if byFrom then byFrom[rec.f] = nil end
            else
                bad = bad + 1
            end
        end
    end)
    pcall(function() reader:close() end)
    if not readOk then
        memos, memoUnreadable = {}, true
        EC.log("buy-order memo file read failed (" .. tostring(readErr) .. "): no new notes until it can be read")
        return
    end
    if bad > 0 then EC.log("buy-order memo file: " .. bad .. " of " .. memoLines .. " lines were not usable and were skipped") end
end

-- At start, against the orders the world save holds: a note whose offer is gone (closed, or taken
-- back by a world rollback while the file kept it) is dropped, an offer from before the notes
-- moved out hands its note to the file, and the file is rewritten with the live notes only when
-- it holds anything else. A note left in ModData is stripped once the file holds it.
-- ponytail: truncate-and-rewrite; a rewrite that fails halfway loses notes (text only, no money).
local function memoSync()
    if memoUnreadable then return end
    local live, kept, moved, strip = {}, {}, {}, {}
    for id, o in pairs(md.wanted.orders) do
        for _, f in ipairs(o.offers) do
            local e = memos[id] and memos[id][f.from]
            if e and e.at == f.at then
                live[#live + 1] = { k = "set", o = id, f = f.from, at = f.at, m = e.m }
                kept[#kept + 1] = live[#live]
                if f.memo ~= nil then strip[#strip + 1] = f end
            elseif type(f.memo) == "string" then
                live[#live + 1] = { k = "set", o = id, f = f.from, at = f.at, m = f.memo }
                moved[#moved + 1] = f
            end
        end
    end
    local wrote = (#moved == 0 and #kept == memoLines) or memoWrite(live, false)
    if not wrote then EC.log("buy-order memo file kept as it was: pruned again at the next start") end
    memos = {}
    for _, rec in ipairs(wrote and live or kept) do
        memos[rec.o] = memos[rec.o] or {}
        memos[rec.o][rec.f] = { m = rec.m, at = rec.at }
    end
    for _, f in ipairs(strip) do f.memo = nil end
    if wrote then
        for _, f in ipairs(moved) do f.memo = nil end
    end
end

-- ---------- state ----------

local function ownerSet(username, create)
    local s = md.wanted.byOwner[username]
    if not s and create then
        s = {}
        md.wanted.byOwner[username] = s
    end
    return s
end

-- Open orders of one buyer: each holds a mailbox slot (ECMailbox.used).
function Wd.ownerCount(username)
    local s = ownerSet(username, false)
    return s and EC.countKeys(s) or 0
end

-- An order names its buyer: a merge waits until the name has none open.
function Wd.mergeBlocker(name)
    return Wd.ownerCount(name) > 0 and "live_order" or nil
end

local function lotOption(order)
    for i, opt in ipairs(order.options) do
        if opt.kind == "item" then return opt, i end
    end
    return nil
end

local function addOrder(order)
    md.wanted.orders[order.id] = order
    md.wanted.count = md.wanted.count + 1
    ownerSet(order.owner, true)[order.id] = true
    local opt = lotOption(order)
    if opt then lotIndex[opt.lot.id] = order.id end
end

local function removeOrder(order)
    if md.wanted.orders[order.id] ~= order then return end
    md.wanted.orders[order.id] = nil
    md.wanted.count = math.max(0, md.wanted.count - 1)
    local s = ownerSet(order.owner, false)
    if s then
        s[order.id] = nil
        if EC.countKeys(s) == 0 then md.wanted.byOwner[order.owner] = nil end
    end
    local opt = lotOption(order)
    if opt then lotIndex[opt.lot.id] = nil end
    dropMemos(order.id, order.offers)
end

local function orderOfLot(id)
    local orderId = type(id) == "string" and lotIndex[id] or nil
    return orderId and md.wanted.orders[orderId] or nil
end

-- Is this id a buy order's escrowed lot right now (R.sourceAlive, Mk.hasListing)?
function Wd.lotExists(id)
    return orderOfLot(id) ~= nil
end

-- The live lot for the recovery core: its owner, item and the quantity the list-out moved. That
-- is the original lotQty, never what is left after fills - the core compares it with the
-- operation's own unit count.
function Wd.operationInfo(id)
    local order = orderOfLot(id)
    if not order then return nil end
    local lot = lotOption(order).lot
    return { kind = "wanted", owner = order.owner, item = lot.item, qty = lot.lotQty }
end

function Wd.stats()
    local held = 0
    for _, o in pairs(md.wanted.orders) do
        if o.blocked then held = held + 1 end
    end
    return { orders = md.wanted.count, max = Wd.MAX_ORDERS, held = held }
end

-- ---------- views ----------

local function optionView(opt, full)
    if opt.kind == "coin" then
        return { kind = "coin", currency = opt.currency, unitPrice = opt.unitPrice,
            held = full and opt.held or nil, fee = full and opt.fee or nil }
    end
    local lot = opt.lot
    return { kind = "item", perUnit = opt.perUnit, item = lot.item, name = lot.name, category = lot.category,
        weight = lot.weight, lotQty = lot.lotQty, state = Codec.preview(lot.snapshot), held = full and lot.qty or nil }
end

-- An offer belongs to the account that made it: a login name merged into another account since
-- (ECMerge) is that account's offer - shown to it, deduplicated with it and told through it.
-- The memo comes from the private file; only the buyer's own view and the offer's author see it.
local function offerView(order, f)
    return { from = S.accountOf(f.from), option = f.option, unitPrice = f.unitPrice, qty = f.qty, memo = memoOf(order.id, f), at = f.at }
end

local function offerOf(order, username)
    local account = S.accountOf(username)
    for i, f in ipairs(order.offers) do
        if S.accountOf(f.from) == account then return f, i end
    end
    return nil
end

-- mode: nil (public row: the viewer's own offer only), "mine" (held, fees, every offer) or
-- "admin" (held and fees, the number of offers but not their text).
local function view(order, viewer, mode)
    local full = mode ~= nil
    local v = { id = order.id, owner = order.owner, item = order.item, name = order.name, category = order.category,
        weight = order.weight, qty = order.qty, qtyTotal = order.qtyTotal, at = order.at, expiresAt = order.expiresAt,
        mine = order.owner == viewer, blocked = order.blocked, options = {},
        cond = order.cond and { new = order.cond.new, minPct = order.cond.minPct } or nil }
    for i, opt in ipairs(order.options) do v.options[i] = optionView(opt, full) end
    if mode == "mine" then
        v.closing, v.offers = order.closing, {}
        for i, f in ipairs(order.offers) do v.offers[i] = offerView(order, f) end
    elseif mode == "admin" then
        v.closing, v.offerCount = order.closing, #order.offers
    else
        local own = offerOf(order, viewer)
        v.myOffer = own and offerView(order, own) or nil
    end
    return v
end

local function notify(username, fields)
    local p = S.onlinePlayer(username)
    if not p then return end
    fields.unclaimed = M.unclaimed(username)
    S.reply(p, "market.notice", fields)
end

local function newestFirst(a, b)
    if a.at ~= b.at then return a.at > b.at end
    return a.id > b.id
end

function Wd.mine(username)
    local out = {}
    for id in pairs(ownerSet(username, false) or {}) do
        local o = md.wanted.orders[id]
        if o then out[#out + 1] = o end
    end
    EC.sortSafe(out, newestFirst)
    for i, o in ipairs(out) do out[i] = view(o, username, "mine") end
    return out
end

local function queryOf(args)
    local q = type(args.query) == "string" and string.lower(string.sub((string.gsub(args.query, "^%s*(.-)%s*$", "%1")), 1, Wd.QUERY_MAX)) or ""
    return q ~= "" and q or nil
end

-- The item types the client resolved the typed text to through its own translated names (the
-- server never sees the player's language). A set of at most Wd.TYPES_MAX strings; anything else
-- in the list is ignored, never an error: the raw query still matches on its own.
Wd.TYPES_MAX = 200
local function typesOf(args)
    if type(args.types) ~= "table" then return nil end
    local set, n = {}, 0
    for i = 1, math.min(#args.types, Wd.TYPES_MAX) do
        local t = args.types[i]
        if type(t) == "string" and t ~= "" and #t <= 128 then
            set[t], n = true, n + 1
        end
    end
    return n > 0 and set or nil
end

-- An order matches when its type is one the client resolved the query to, or when the raw query
-- is found in its fullType, English name or buyer. Types only widen a query; alone they are ignored.
local function matches(o, query, types)
    if not query then return true end
    if types and types[o.item] then return true end
    local hay = string.lower(tostring(o.item) .. " " .. tostring(o.name or "") .. " " .. tostring(o.owner))
    return string.find(hay, query, 1, true) ~= nil
end

local function page(rows, requested, viewer, mode)
    local total = #rows
    local pages = math.max(1, math.ceil(total / Wd.PAGE))
    local p = isInt(requested, 1, 100000) and requested or 1
    if p > pages then p = pages end
    local out = {}
    for i = (p - 1) * Wd.PAGE + 1, math.min(total, p * Wd.PAGE) do out[#out + 1] = view(rows[i], viewer, mode) end
    return out, p, pages, total
end

-- args = { page?, query?, types?, category?, currency? = "all" }. Newest first; the query matches
-- the fullType, the English name and the buyer, or one of the `types` the client resolved it to
-- from translated names -- before paging, so a localized search finds every page's orders.
function Wd.browse(username, args)
    args = type(args) == "table" and args or {}
    local query = queryOf(args)
    local types = query and typesOf(args) or nil
    local category = type(args.category) == "string" and args.category ~= "" and args.category or nil
    local currency = Mk.CURRENCY_ALL
    local base = { page = 1, pages = 1, total = 0, per = Wd.PAGE, rows = {}, currencies = Mk.tradableCurrencies() }
    if args.currency ~= nil and args.currency ~= Mk.CURRENCY_ALL then
        if not L.isCurrency(args.currency) then
            base.ok, base.error, base.currency = false, "unknown_currency", args.currency
            return base
        end
        currency = args.currency
    end
    local rows = {}
    for _, o in pairs(md.wanted.orders) do
        local take = matches(o, query, types) and (category == nil or o.category == category)
        if take and currency ~= Mk.CURRENCY_ALL then
            take = false
            for _, opt in ipairs(o.options) do
                if opt.kind == "coin" and opt.currency == currency then take = true end
            end
        end
        if take then rows[#rows + 1] = o end
    end
    EC.sortSafe(rows, newestFirst)
    local out, p, pages, total = page(rows, args.page, username, nil)
    return {
        ok = true, page = p, pages = pages, total = total, per = Wd.PAGE, query = query, category = category,
        currency = currency, rows = out, max = EC.sandbox("WantedMaxPerPlayer", 5), mineCount = Wd.ownerCount(username),
        feePercent = EC.sandbox("MarketListingFeePercent", 2), taxPercent = EC.sandbox("MarketSalesTaxPercent", 5),
        priceMin = EC.sandbox("MarketPriceMin", 1), priceMax = EC.sandbox("MarketPriceMax", 1000000),
        days = EC.sandbox("MarketListingDays", 7), currencies = base.currencies,
    }
end

-- ---------- item checks ----------

-- Why this copy cannot fill the order, or nil: the condition first (new-only, minimum durability),
-- then the market's own whitelist and state check. Returns reason, rule, pct.
local function refusal(order, item)
    local cond = order.cond
    if cond and cond.new then
        if not Codec.isCanonical(item, order.item) then return "not_new" end
    elseif cond and cond.minPct then
        local pct = Codec.durabilityPct(item)
        if pct < cond.minPct then return "worn", nil, pct end
    end
    local pass, reason, rule = Codec.check(item)
    if not pass then return reason, rule end
    return nil
end

-- The seller's top-level copies of the wanted type, folded by snapshot signature and verdict (the
-- shape of Mk.candidates), at most CANDIDATES_MAX copies looked at.
function Wd.candidates(player, order)
    local rows, groups, seen = {}, {}, 0
    local inv = player:getInventory()
    local ok, items = pcall(function() return inv:getItems() end)
    if not ok or not items then return rows end
    for i = 0, items:size() - 1 do
        if seen >= Wd.CANDIDATES_MAX then break end
        local it = items:get(i)
        local id, fullType = nil, nil
        pcall(function() id = it:getID() fullType = it:getFullType() end)
        if id and fullType == order.item then
            seen = seen + 1
            local reason, rule, pct = refusal(order, it)
            local snap = Codec.snapshot(it)
            local key = tostring(reason) .. "|" .. tostring(rule) .. "|" .. tostring(pct) .. "|" .. Codec.signature(snap)
            local row = groups[key]
            if row then
                row.itemIds[#row.itemIds + 1] = id
                row.count = row.count + 1
            else
                row = { itemIds = { id }, item = fullType, count = 1, verdict = reason or "ok", rule = rule, pct = pct,
                    state = Codec.preview(snap) }
                groups[key] = row
                rows[#rows + 1] = row
            end
        end
    end
    return rows
end

-- The copies `ids` from the top level of the backpack, all of one signature. Returns the list,
-- or nil plus the refusal reply. `judge(item)` adds the caller's own per-item rule.
local function takeable(player, ids, judge)
    local inv = player:getInventory()
    if not inv then return nil, { ok = false, error = "item_not_found" } end
    local items, signature = {}, nil
    for _, id in ipairs(ids) do
        local item = M.findTopLevel(inv, id)
        if not item then return nil, { ok = false, error = "item_not_found" } end
        local refused = judge(item)
        if refused then return nil, refused end
        local sig = Codec.signature(Codec.snapshot(item))
        if signature == nil then signature = sig
        elseif sig ~= signature then return nil, { ok = false, error = "mixed_items" } end
        items[#items + 1] = item
    end
    return items, nil, inv
end

local function idList(ids, max)
    if type(ids) ~= "table" or #ids < 1 or #ids > max or EC.countKeys(ids) ~= #ids then return nil end
    local seen = {}
    for _, id in ipairs(ids) do
        if not isInt(id, -2147483648, 2147483647) or seen[id] then return nil end
        seen[id] = true
    end
    return L.batchKey(ids, max)
end

-- A resend is answered from the ledger's record of the first attempt; every key of `order` must
-- match what that attempt recorded (flat fields, ledger-trade rule 1), or the id is being reused.
local function priorOrder(requestId, order)
    local prior = L.priorResult(requestId)
    if not prior then return nil end
    local meta = prior.meta or {}
    for key, value in pairs(order) do
        if meta[key] ~= value then return { ok = false, error = "request_conflict", orderId = meta.orderId } end
    end
    return { ok = prior.ok, txId = prior.txId, duplicate = true, error = prior.error, orderId = meta.orderId }, meta
end

local function copy(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

-- ---------- create ----------

-- The wire shape of one create request, checked before anything is looked up. Returns the parsed
-- options and the flat idempotency fingerprint, or nil.
local function parseCreate(args)
    if type(args.item) ~= "string" or args.item == "" or #args.item > 128 then return nil end
    if not isInt(args.qty, 1, Wd.QTY_MAX) then return nil end
    local cond = args.cond
    if cond ~= nil then
        if type(cond) ~= "table" or EC.countKeys(cond) ~= 1 then return nil end
        if cond.new ~= nil then
            if cond.new ~= true then return nil end
            cond = { new = true }
        elseif isInt(cond.minPct, 1, 100) then
            cond = { minPct = cond.minPct }
        else
            return nil
        end
    end
    local list = args.options
    if type(list) ~= "table" or #list < 1 or #list > Wd.OPTIONS_MAX or EC.countKeys(list) ~= #list then return nil end
    local fp = { item = args.item, qty = args.qty, condNew = cond ~= nil and cond.new == true,
        condPct = cond and cond.minPct or 0, n = #list }
    local options, currencies, items = {}, {}, 0
    for i, o in ipairs(list) do
        if type(o) ~= "table" then return nil end
        local p = "o" .. i
        if o.kind == "coin" then
            if type(o.currency) ~= "string" or o.currency == "" or currencies[o.currency] then return nil end
            if not isInt(o.unitPrice, 1, Mk.PRICE_CEILING) then return nil end
            currencies[o.currency] = true
            options[i] = { kind = "coin", currency = o.currency, unitPrice = o.unitPrice }
            fp[p .. "k"], fp[p .. "c"], fp[p .. "p"] = "coin", o.currency, o.unitPrice
        elseif o.kind == "item" then
            items = items + 1
            if items > 1 or not isInt(o.perUnit, 1, Wd.QTY_MAX) or o.perUnit * args.qty > Wd.QTY_MAX then return nil end
            local batch = idList(o.itemIds, Wd.QTY_MAX)
            if batch == nil or #o.itemIds ~= o.perUnit * args.qty then return nil end
            options[i] = { kind = "item", perUnit = o.perUnit, itemIds = o.itemIds }
            fp[p .. "k"], fp[p .. "n"], fp[p .. "b"] = "item", o.perUnit, batch
        else
            return nil
        end
    end
    return options, fp, cond
end

local function scriptFacts(fullType)
    local name, category = nil, "other"
    pcall(function()
        local script = ScriptManager.instance:FindItem(fullType)
        name = script:getDisplayName()
        category = EC.itemCategory(script) or "other"
    end)
    return type(name) == "string" and name or nil, type(category) == "string" and category or "other"
end

-- args = { item, qty, cond?, options = { {kind="coin", currency, unitPrice} | {kind="item", itemIds, perUnit} }, requestId }
function Wd.create(player, args)
    local username, login = S.principal(player), S.login(player)
    if type(args) ~= "table" or not requestIdOf(args) then return { ok = false, error = "invalid_args" } end
    local options, fp, cond = parseCreate(args)
    if not options then return { ok = false, error = "invalid_args" } end
    local requestId = "wcreate:" .. username .. ":" .. args.requestId
    if not L.validRequestKey(requestId) then return { ok = false, error = "request_too_long" } end
    local prior, recorded = priorOrder(requestId, fp)
    if prior then
        -- the duplicate answers with what the first attempt recorded (flat "fee:<cur>" / "held:<cur>")
        if prior.duplicate and recorded then
            prior.fees, prior.held, prior.lotQty = {}, {}, recorded.lotQty
            for key, value in pairs(recorded) do
                local cur = string.match(key, "^fee:(.+)$")
                if cur then prior.fees[cur] = value end
                cur = string.match(key, "^held:(.+)$")
                if cur then prior.held[cur] = value end
            end
            prior.item, prior.qty, prior.expiresAt = recorded.item, recorded.qty, recorded.expiresAt
        end
        return prior
    end
    -- a new request: from here the live configuration decides
    local max = EC.sandbox("WantedMaxPerPlayer", 5)
    if max <= 0 then return { ok = false, error = "wanted_disabled" } end
    local allowed, why, rule = Codec.typeAllowed(args.item)
    if not allowed then return { ok = false, error = why, rule = rule } end
    local pmin, pmax = EC.sandbox("MarketPriceMin", 1), EC.sandbox("MarketPriceMax", 1000000)
    local feePct = EC.sandbox("MarketListingFeePercent", 2)
    for _, opt in ipairs(options) do
        if opt.kind == "coin" then
            local def, cerr = Mk.currencyState(opt.currency)
            if not def then return { ok = false, error = cerr, currency = opt.currency } end
            if not isInt(opt.unitPrice, pmin, pmax) then return { ok = false, error = "price_range", min = pmin, max = pmax } end
            opt.held = opt.unitPrice * args.qty
            opt.fee = Mk.pct(opt.held, feePct)
        end
    end
    if not T.near(player) then return { ok = false, error = "not_at_terminal" } end
    if L.isFrozen(username) then return { ok = false, error = "account_frozen" } end
    if Wd.ownerCount(username) >= max then return { ok = false, error = "too_many_orders", max = max } end
    if md.wanted.count >= Wd.MAX_ORDERS then return { ok = false, error = "wanted_full" } end
    if not M.hasFreeSlot(username) then return { ok = false, error = "mailbox_full" } end
    local postings, fees, held = {}, {}, {}
    for _, opt in ipairs(options) do
        if opt.kind == "coin" then
            local needed = opt.held + opt.fee
            if L.getBalance(username, opt.currency).available < needed then
                return { ok = false, error = "insufficient_funds", currency = opt.currency, needed = needed }
            end
            postings[#postings + 1] = { account = username, currency = opt.currency, amount = -needed, fee = opt.fee > 0 and opt.fee or nil }
            postings[#postings + 1] = { account = username, currency = opt.currency, amount = opt.held, bucket = "reserved" }
            if opt.fee > 0 then postings[#postings + 1] = { account = Wd.BURN_ACCOUNT, currency = opt.currency, amount = opt.fee } end
            fees[opt.currency], held[opt.currency] = opt.fee, opt.held
        end
    end
    local lotOpt = nil
    for _, opt in ipairs(options) do if opt.kind == "item" then lotOpt = opt end end
    local items, inv
    if lotOpt then
        local refused
        items, refused, inv = takeable(player, lotOpt.itemIds, function(item)
            local pass, reason, r = Codec.check(item)
            if not pass then return { ok = false, error = reason, rule = r, category = EC.itemCategory(item) } end
            return nil
        end)
        if not items then return refused end
    end

    local ms = EC.now()
    local name, category = scriptFacts(args.item)
    local order = {
        id = S.newId(), owner = username, item = args.item, name = name, category = category,
        weight = M.scriptWeight(args.item), qtyTotal = args.qty, qty = args.qty, cond = cond,
        options = {}, offers = {}, tradeSchema = L.TRADE_SCHEMA, at = ms,
        expiresAt = ms + EC.sandbox("MarketListingDays", 7) * 86400000,
    }
    local meta = copy(fp)
    meta.orderId, meta.lotQty, meta.expiresAt = order.id, lotOpt and #lotOpt.itemIds or nil, order.expiresAt
    for cur, fee in pairs(fees) do meta["fee:" .. cur], meta["held:" .. cur] = fee, held[cur] end
    local rec = nil
    if lotOpt then
        for _, item in ipairs(items) do Codec.detachParts(item, inv) end
        local snapshot = Codec.lotSnapshot(items)
        local lotId = S.newId()
        local _, seq = EC.parseId(lotId)
        local lotName, lotCategory = scriptFacts(snapshot.type)
        local lotQty = #items
        rec = { itemId = lotOpt.itemIds[1], itemIds = lotOpt.itemIds, qty = lotQty, lotQty = lotQty, snapshot = snapshot,
            kind = "wanted", tradeSchema = L.TRADE_SCHEMA, seq = seq, epoch = md.meta.epoch, at = ms }
        local began, beginErr, beginDetail = M.beginOut(player, lotId, items, rec)
        if not began then
            return { ok = false, error = beginErr, recovery = M.recoveryStatus(login), recoveryDetail = beginDetail }
        end
        local taken, takeError = M.takeOut(player, lotId, items)
        if not taken then return { ok = false, error = takeError, recovery = M.recoveryStatus(login) } end
        lotOpt.lot = { id = lotId, item = snapshot.type, snapshot = snapshot, lotQty = lotQty, qty = lotQty,
            name = lotName, category = lotCategory, weight = M.itemWeight(items[1]) }
    end
    for i, opt in ipairs(options) do
        order.options[i] = opt.kind == "coin"
            and { kind = "coin", currency = opt.currency, unitPrice = opt.unitPrice, held = opt.held, fee = opt.fee }
            or { kind = "item", perUnit = opt.perUnit, lot = opt.lot }
    end
    if #postings > 0 then
        local res = L.post({
            kind = "wanted_create", requestId = requestId, reasonCode = "wanted_create", actor = username,
            idemMeta = meta, payload = { item = order.item, qty = order.qty, orderId = order.id },
            postings = postings,
        })
        if not res.ok then
            -- everything was checked above; only a ledger-level refusal lands here. The very
            -- objects that left the backpack go back into it: nothing is rebuilt.
            if lotOpt then
                local returned = M.abortOut(player, lotOpt.lot.id, items)
                return { ok = false, error = returned and res.error or "recovery_pending", recovery = M.recoveryStatus(login) }
            end
            return { ok = false, error = res.error }
        end
    end
    addOrder(order)
    if lotOpt then
        local recorded, recordError = M.finishOut(login, lotOpt.lot.id, rec, "wanted", lotOpt.lot.id)
        if not recorded then error("wanted lot receipt invariant: " .. tostring(recordError)) end
    end
    if #postings == 0 and not L.noteOperation(requestId, order.id, meta) then
        -- the key was validated before anything moved: a refusal means the window already holds it
        EC.log("wanted order " .. order.id .. ": the idempotency record was refused")
        X.emit("ledger.anomaly", { kind = "wanted", orderId = order.id, username = username,
            resolution = "idempotency-record-refused" })
    end
    X.emit("wanted.created", { orderId = order.id, owner = username, item = order.item, qty = order.qty,
        held = held, fees = fees, lotId = lotOpt and lotOpt.lot.id or nil, lotItem = lotOpt and lotOpt.lot.item or nil,
        lotQty = lotOpt and lotOpt.lot.lotQty or nil, expiresAt = order.expiresAt })
    X.market(username, { kind = "wanted_created", orderId = order.id, item = order.item, qty = order.qty })
    return { ok = true, orderId = order.id, item = order.item, qty = order.qty, fees = fees, held = held,
        lotQty = lotOpt and lotOpt.lot.lotQty or nil, expiresAt = order.expiresAt }
end

-- ---------- closing ----------

-- Every coin option's reservation home in one transaction (allowFrozen: it is the buyer's own
-- money). Returns true, refunded, or false, error. Nothing to release is not a transaction.
local function release(order)
    local postings, refunded = {}, {}
    for _, opt in ipairs(order.options) do
        if opt.kind == "coin" and (opt.held or 0) > 0 then
            postings[#postings + 1] = { account = order.owner, currency = opt.currency, amount = -opt.held, bucket = "reserved" }
            postings[#postings + 1] = { account = order.owner, currency = opt.currency, amount = opt.held }
            refunded[opt.currency] = opt.held
        end
    end
    if #postings == 0 then return true, refunded end
    local res = L.post({
        kind = "wanted_release", requestId = "wclose:" .. order.id, reasonCode = "wanted_release", actor = order.owner,
        allowFrozen = true, payload = { item = order.item, qty = order.qty, orderId = order.id }, postings = postings,
    })
    if not res.ok then return false, res.error end
    for _, opt in ipairs(order.options) do
        if opt.kind == "coin" then opt.held = 0 end
    end
    return true, refunded
end

-- Close an order (reason completed | cancelled | expired | admin). The release goes first: when
-- the ledger refuses it the order stays exactly as it is, blocked = "refund_failed", and the
-- minute sweep tries again with the same reason. Otherwise the order goes and what is left of the
-- lot is mailed back - a system return, never refused for room. Returns ok, refunded | error, entry.
local function closeOrder(order, reason, closeReason)
    local ok, refunded = release(order)
    if not ok then
        order.closing, order.closeReason = reason, closeReason
        if order.blocked ~= "refund_failed" then
            order.blocked = "refund_failed"
            X.emit("wanted.held", { orderId = order.id, owner = order.owner, item = order.item, reason = "refund_failed",
                closing = reason, error = refunded })
            EC.log("wanted order " .. tostring(order.id) .. " held: refund_failed (" .. tostring(refunded) .. ")")
        end
        return false, refunded
    end
    removeOrder(order)
    local opt = lotOption(order)
    local entry = nil
    if opt and opt.lot.qty > 0 then
        entry = M.add(order.owner, { kind = "return", item = opt.lot.item, qty = opt.lot.qty, snapshot = opt.lot.snapshot,
            listingId = opt.lot.id })
    end
    X.emit("wanted.closed", { orderId = order.id, owner = order.owner, item = order.item, qty = order.qty,
        qtyTotal = order.qtyTotal, reason = reason, refunded = refunded, returnedQty = entry and entry.qty or nil,
        mailId = entry and entry.id or nil, closeReason = closeReason })
    X.market(order.owner, { kind = "wanted_closed", orderId = order.id, item = order.item, qty = order.qty,
        qtyTotal = order.qtyTotal, reason = reason, mailId = entry and entry.id or nil })
    return true, refunded, entry
end

-- args = { orderId, requestId }. The request is idempotent on its own key (a resend answers the
-- first refund, the same id for another order is request_conflict); the refund itself is keyed by
-- the order (`wclose:<orderId>`), so nothing here can release twice.
function Wd.cancel(player, args)
    local username = S.principal(player)
    if not requestIdOf(args) or type(args.orderId) ~= "string" then return { ok = false, error = "invalid_args" } end
    local requestId = "wcancel:" .. username .. ":" .. args.requestId
    if not L.validRequestKey(requestId) then return { ok = false, error = "request_too_long" } end
    local prior, recorded = priorOrder(requestId, { orderId = args.orderId })
    if prior then
        if prior.duplicate and recorded then
            prior.refunded, prior.returnedQty, prior.mailId = {}, recorded.returnedQty, recorded.mailId
            for key, value in pairs(recorded) do
                local cur = string.match(key, "^refunded:(.+)$")
                if cur then prior.refunded[cur] = value end
            end
        end
        return prior
    end
    if not T.near(player) then return { ok = false, error = "not_at_terminal" } end
    local order = md.wanted.orders[args.orderId]
    if not order then return { ok = false, error = "unknown_order" } end
    if order.owner ~= username then return { ok = false, error = "not_owner" } end
    local ok, refunded, entry = closeOrder(order, "cancelled")
    if not ok then return { ok = false, error = "refund_failed", orderId = order.id } end
    local meta = { orderId = order.id, returnedQty = entry and entry.qty or nil, mailId = entry and entry.id or nil }
    for cur, amount in pairs(refunded) do meta["refunded:" .. cur] = amount end
    if not L.noteOperation(requestId, order.id, meta) then
        EC.log("wanted cancel " .. order.id .. ": the idempotency record was refused")
    end
    local out = { ok = true, orderId = order.id, refunded = refunded }
    if not entry then return out end
    out.returnedQty, out.mailId = entry.qty, entry.id
    return M.deliveryFields(out, M.claim(player, entry.id), entry.qty)
end

function Wd.adminCancel(admin, orderId, reason)
    local order = md.wanted.orders[orderId]
    if not order then return false, "unknown_order" end
    local ok, refunded = closeOrder(order, "admin", reason)
    X.audit({ action = "wanted", admin = admin, target = order.owner, field = orderId, before = tostring(order.item),
        after = ok and "closed" or "refund_failed", reason = reason })
    if not ok then return false, "refund_failed" end
    notify(order.owner, { kind = "wanted_cancelled", orderId = order.id, item = order.item, qty = order.qty, reason = reason })
    return true, refunded
end

-- ponytail: full scan once a minute (<= MAX_ORDERS rows); index by expiresAt if that ever shows.
function Wd.onTick()
    if not md then return end
    local ms = EC.now()
    if ms - lastSweep < Wd.SWEEP_EVERY_MS then return end
    lastSweep = ms
    local due = {}
    for _, o in pairs(md.wanted.orders) do
        if o.blocked == "refund_failed" or (o.expiresAt or 0) <= ms then due[#due + 1] = o end
    end
    for _, o in ipairs(due) do
        local reason = o.closing or "expired"
        if closeOrder(o, reason, o.closeReason) then
            if reason == "expired" then
                notify(o.owner, { kind = "wanted_expired", orderId = o.id, item = o.item, qty = o.qty })
            elseif reason == "admin" then
                notify(o.owner, { kind = "wanted_cancelled", orderId = o.id, item = o.item, qty = o.qty, reason = o.closeReason })
            end
        end
    end
end

-- ---------- fill ----------

-- The shared front of every seller-side command: the order exists, is someone else's, is not
-- held and is open, and `option` names one of its options. Returns order, opt or nil, refusal.
local function openOrder(username, orderId, option)
    local order = md.wanted.orders[orderId]
    if not order then return nil, { ok = false, error = "unknown_order" } end
    if order.owner == username then return nil, { ok = false, error = "own_order" } end
    if order.blocked then return nil, { ok = false, error = "order_held" } end
    if order.closing or (order.expiresAt or 0) <= EC.now() then return nil, { ok = false, error = "order_closed" } end
    local opt = order.options[option]
    if not opt then return nil, { ok = false, error = "invalid_option" } end
    return order, opt
end

-- The wanted_fill postings: the chosen coin to the seller less the tax, every other coin option
-- released by the units filled. Returns postings, tax.
local function fillPostings(order, chosen, seller, n)
    local postings, tax = {}, 0
    for _, opt in ipairs(order.options) do
        if opt.kind == "coin" then
            local amount = opt.unitPrice * n
            postings[#postings + 1] = { account = order.owner, currency = opt.currency, amount = -amount, bucket = "reserved" }
            if opt == chosen then
                tax = Mk.pct(amount, EC.sandbox("MarketSalesTaxPercent", 5))
                if tax >= amount then tax = amount - 1 end
                if tax < 0 then tax = 0 end
                postings[#postings + 1] = { account = seller, currency = opt.currency, amount = amount - tax, fee = tax > 0 and tax or nil }
                if tax > 0 then postings[#postings + 1] = { account = Wd.BURN_ACCOUNT, currency = opt.currency, amount = tax } end
            else
                postings[#postings + 1] = { account = order.owner, currency = opt.currency, amount = amount }
            end
        end
    end
    return postings, tax
end

-- args = { orderId, option, itemIds, unitPrice? (coin: the price the seller saw), acceptMail?, requestId }
function Wd.fill(player, args)
    local username, login = S.principal(player), S.login(player)
    if type(args) ~= "table" or not requestIdOf(args) or type(args.orderId) ~= "string"
        or not isInt(args.option, 1, Wd.OPTIONS_MAX) then return { ok = false, error = "invalid_args" } end
    if args.unitPrice ~= nil and not isInt(args.unitPrice, 1, Mk.PRICE_CEILING) then return { ok = false, error = "invalid_args" } end
    if args.acceptMail ~= nil and type(args.acceptMail) ~= "boolean" then return { ok = false, error = "invalid_args" } end
    local batch = idList(args.itemIds, Wd.QTY_MAX)
    if batch == nil then return { ok = false, error = "invalid_args" } end
    local requestId = "wfill:" .. username .. ":" .. args.requestId
    if not L.validRequestKey(requestId) then return { ok = false, error = "request_too_long" } end
    local fp = { orderId = args.orderId, option = args.option, items = batch, price = args.unitPrice or 0 }
    local prior, recorded = priorOrder(requestId, fp)
    if prior then
        prior.option = args.option
        if prior.duplicate and recorded then
            prior.qty, prior.currency, prior.price, prior.tax = recorded.qty, recorded.currency, recorded.paid, recorded.tax
            prior.unitPrice = recorded.currency and args.unitPrice or nil
            prior.payItem, prior.payQty, prior.mailId = recorded.payItem, recorded.payQty, recorded.mailId
            prior.remaining, prior.closed = recorded.remaining, recorded.closed
        end
        return prior
    end
    if not T.near(player) then return { ok = false, error = "not_at_terminal" } end
    if L.isFrozen(username) then return { ok = false, error = "account_frozen" } end
    local order, opt = openOrder(username, args.orderId, args.option)
    if not order then return opt end
    if L.isFrozen(order.owner) then return { ok = false, error = "owner_frozen" } end
    local n = #args.itemIds
    if n > order.qty then return { ok = false, error = "qty_exceeded", qty = order.qty } end
    local coin = opt.kind == "coin"
    local prepared = nil
    if coin then
        local def, cerr = Mk.currencyState(opt.currency)
        if not def then return { ok = false, error = cerr, currency = opt.currency } end
        if args.unitPrice ~= opt.unitPrice then
            return { ok = false, error = "price_changed", unitPrice = opt.unitPrice, currency = opt.currency }
        end
        local _, tax = fillPostings(order, opt, username, n)
        if L.getBalance(username, opt.currency).available + opt.unitPrice * n - tax > L.currency(opt.currency).balanceMax then
            return { ok = false, error = "balance_cap", currency = opt.currency }
        end
    else
        if not M.hasFreeSlot(username) then return { ok = false, error = "mailbox_full" } end
        local perr
        prepared, perr = M.prepare(player, { item = opt.lot.item, qty = opt.perUnit * n, snapshot = opt.lot.snapshot })
        if not prepared then return { ok = false, error = perr or "item_unavailable" } end
        if not prepared.fits and args.acceptMail ~= true then
            return { ok = false, error = "mail_confirmation_required", willMail = true, orderId = order.id,
                item = opt.lot.item, qty = prepared.qty, totalWeight = prepared.totalWeight, heavy = prepared.heavy }
        end
    end
    local items, refused, inv = takeable(player, args.itemIds, function(item)
        local fullType = nil
        pcall(function() fullType = item:getFullType() end)
        if fullType ~= order.item then return { ok = false, error = "wrong_item" } end
        local reason, rule, pct = refusal(order, item)
        if not reason then return nil end
        return { ok = false, error = reason, rule = rule, pct = pct, minPct = pct and order.cond.minPct or nil }
    end)
    if not items then return refused end

    for _, item in ipairs(items) do Codec.detachParts(item, inv) end
    local snapshot = Codec.lotSnapshot(items)
    local fillId = S.newId()
    local _, seq = EC.parseId(fillId)
    local price = coin and opt.unitPrice * n or nil
    local rec = { itemId = args.itemIds[1], itemIds = args.itemIds, qty = n, lotQty = n, snapshot = snapshot, kind = "fill",
        price = price, currency = coin and opt.currency or nil, tradeSchema = L.TRADE_SCHEMA, txRequestId = requestId,
        seq = seq, epoch = md.meta.epoch, at = EC.now() }
    local began, beginErr, beginDetail = M.beginOut(player, fillId, items, rec)
    if not began then return { ok = false, error = beginErr, recovery = M.recoveryStatus(login), recoveryDetail = beginDetail } end
    local taken, takeError = M.takeOut(player, fillId, items)
    if not taken then return { ok = false, error = takeError, recovery = M.recoveryStatus(login) } end
    -- one tick from here: ledger, order, letters, receipt
    local postings, tax = fillPostings(order, coin and opt or nil, username, n)
    local meta = copy(fp)
    local payQty = (not coin) and opt.perUnit * n or nil
    -- the seller's payment letter gets its id now, so the record a resend answers from can name it
    local payMailId = payQty and S.newId() or nil
    meta.orderId, meta.fillId, meta.qty = order.id, fillId, n
    meta.remaining, meta.closed = order.qty - n, order.qty - n == 0
    if coin then meta.currency, meta.paid, meta.tax = opt.currency, opt.unitPrice * n, tax
    else meta.payItem, meta.payQty, meta.mailId = opt.lot.item, payQty, payMailId end
    local txId = nil
    if #postings > 0 then
        local res = L.post({
            kind = "wanted_fill", requestId = requestId, reasonCode = "wanted_fill", actor = username, idemMeta = meta,
            payload = { item = order.item, qty = n, orderId = order.id, option = args.option, seller = username,
                buyer = order.owner, tax = coin and tax or nil, currency = coin and opt.currency or nil },
            postings = postings,
        })
        if not res.ok then
            local returned = M.abortOut(player, fillId, items)
            return { ok = false, error = returned and res.error or "recovery_pending", recovery = M.recoveryStatus(login) }
        end
        txId = res.txId
    end
    order.qty = order.qty - n
    for _, o in ipairs(order.options) do
        if o.kind == "coin" then o.held = o.unitPrice * order.qty end
    end
    if payQty then opt.lot.qty = opt.lot.qty - payQty end
    local ownOffer, own = offerOf(order, username)
    if own then
        table.remove(order.offers, own)
        dropMemos(order.id, { ownOffer })
    end
    local entry = M.add(order.owner, { kind = "wanted", item = order.item, qty = n, txId = txId, price = price,
        currency = coin and opt.currency or nil, seller = username, snapshot = snapshot })
    local pay = payQty and M.add(username, { kind = "wanted_pay", item = opt.lot.item, qty = payQty, txId = txId,
        snapshot = opt.lot.snapshot, listingId = opt.lot.id, seller = order.owner }, payMailId) or nil
    local recorded, recordError = M.finishOut(login, fillId, rec, "fill", txId or fillId)
    if not recorded then error("wanted fill receipt invariant: " .. tostring(recordError)) end
    if #postings == 0 and not L.noteOperation(requestId, fillId, meta) then
        EC.log("wanted fill " .. fillId .. ": the idempotency record was refused")
        X.emit("ledger.anomaly", { kind = "wanted", orderId = order.id, username = username,
            resolution = "idempotency-record-refused" })
    end
    local closed = order.qty == 0 and closeOrder(order, "completed") or false
    local currency = coin and opt.currency or nil
    X.emit("wanted.filled", { orderId = order.id, owner = order.owner, seller = username, item = order.item, qty = n,
        option = args.option, price = price, unitPrice = coin and opt.unitPrice or nil, tax = coin and tax or nil,
        currency = currency, payItem = pay and pay.item or nil, payQty = payQty, txId = txId, mailId = entry.id,
        payMailId = pay and pay.id or nil, remaining = order.qty, closed = closed })
    X.market(order.owner, { kind = "wanted_filled", orderId = order.id, item = order.item, qty = n, price = price,
        currency = currency, payItem = pay and pay.item or nil, payQty = payQty, other = username, txId = txId })
    X.market(username, { kind = "wanted_sold", orderId = order.id, item = order.item, qty = n, price = price,
        tax = coin and tax or nil, currency = currency, payItem = pay and pay.item or nil, payQty = payQty,
        other = order.owner, txId = txId, mailId = pay and pay.id or nil })
    notify(order.owner, { kind = "wanted_filled", orderId = order.id, item = order.item, qty = n, price = price,
        unitPrice = coin and opt.unitPrice or nil, currency = currency, payItem = pay and pay.item or nil,
        payQty = payQty, from = username, remainingQty = order.qty })
    local out = { ok = true, txId = txId, orderId = order.id, option = args.option, qty = n, currency = currency,
        price = price, unitPrice = coin and opt.unitPrice or nil, tax = coin and tax or nil,
        payItem = pay and pay.item or nil, payQty = payQty, remaining = order.qty, closed = closed }
    if coin then
        out.balance = L.getBalance(username, currency).available
    elseif prepared.fits then
        out.mailId = pay.id
        M.deliveryFields(out, M.claim(player, pay.id, prepared), payQty)
    else
        out.mailId, out.mailed = pay.id, true
        M.deliveryFields(out, nil, payQty)
    end
    return out
end

-- ---------- counter-offers ----------

local function validMemo(memo)
    return memo == nil or (type(memo) == "string" and A.charCount(memo) <= Wd.MEMO_MAX and not string.find(memo, "%c"))
end

-- args = { orderId, option, unitPrice, qty, memo?, requestId }: a seller names a higher unit
-- price for a coin option. Nothing moves; at most one per account and OFFERS_MAX per order.
function Wd.offer(player, args)
    local username = S.principal(player)
    local memo = type(args) == "table" and args.memo ~= "" and args.memo or nil
    if type(args) ~= "table" or not requestIdOf(args) or type(args.orderId) ~= "string" or not isInt(args.option, 1, Wd.OPTIONS_MAX)
        or not isInt(args.unitPrice, 1, Mk.PRICE_CEILING) or not isInt(args.qty, 1, Wd.QTY_MAX) or not validMemo(memo) then
        return { ok = false, error = "invalid_args" }
    end
    if not T.near(player) then return { ok = false, error = "not_at_terminal" } end
    if L.isFrozen(username) then return { ok = false, error = "account_frozen" } end
    local order, opt = openOrder(username, args.orderId, args.option)
    if not order then return opt end
    if opt.kind ~= "coin" then return { ok = false, error = "invalid_option" } end
    if args.qty > order.qty then return { ok = false, error = "qty_exceeded", qty = order.qty } end
    if args.unitPrice <= opt.unitPrice then return { ok = false, error = "offer_not_higher", unitPrice = opt.unitPrice } end
    local pmax = EC.sandbox("MarketPriceMax", 1000000)
    if args.unitPrice > pmax then return { ok = false, error = "price_range", max = pmax } end
    local own = offerOf(order, username)
    if own then return { ok = false, error = "offer_exists", offer = offerView(order, own) } end
    if #order.offers >= Wd.OFFERS_MAX then return { ok = false, error = "offers_full" } end
    local f = { from = username, option = args.option, unitPrice = args.unitPrice, qty = args.qty, at = EC.now() }
    -- the note goes to the private file first: an offer whose note cannot be kept is not made
    if memo and not setMemo(order.id, f, memo) then return { ok = false, error = "memo_unavailable" } end
    order.offers[#order.offers + 1] = f
    X.emit("wanted.offered", { orderId = order.id, owner = order.owner, from = username, option = args.option,
        unitPrice = f.unitPrice, qty = f.qty, currency = opt.currency })
    notify(order.owner, { kind = "wanted_offer", orderId = order.id, item = order.item, qty = f.qty, price = f.unitPrice,
        currency = opt.currency, from = username, memo = memo })
    return { ok = true, orderId = order.id, offer = offerView(order, f) }
end

-- args = { orderId, option, unitPrice, requestId }: the buyer raises a coin option for every
-- seller. The reservation grows by the difference times the units still wanted, and that
-- difference pays the listing fee like the original price did. Offers it meets are removed and
-- their sellers told.
function Wd.raise(player, args)
    local username = S.principal(player)
    if type(args) ~= "table" or not requestIdOf(args) or type(args.orderId) ~= "string" or not isInt(args.option, 1, Wd.OPTIONS_MAX)
        or not isInt(args.unitPrice, 1, Mk.PRICE_CEILING) then return { ok = false, error = "invalid_args" } end
    local requestId = "wraise:" .. username .. ":" .. args.requestId
    if not L.validRequestKey(requestId) then return { ok = false, error = "request_too_long" } end
    local fp = { orderId = args.orderId, option = args.option, price = args.unitPrice }
    local prior, recorded = priorOrder(requestId, fp)
    if prior then
        prior.option, prior.unitPrice = args.option, args.unitPrice
        if prior.duplicate and recorded then
            prior.currency, prior.held, prior.delta = recorded.currency, recorded.held, recorded.delta
            prior.fee, prior.met = recorded.fee, recorded.met
        end
        return prior
    end
    if not T.near(player) then return { ok = false, error = "not_at_terminal" } end
    if L.isFrozen(username) then return { ok = false, error = "account_frozen" } end
    local order = md.wanted.orders[args.orderId]
    if not order then return { ok = false, error = "unknown_order" } end
    if order.owner ~= username then return { ok = false, error = "not_owner" } end
    if order.blocked then return { ok = false, error = "order_held" } end
    if order.closing or (order.expiresAt or 0) <= EC.now() then return { ok = false, error = "order_closed" } end
    local opt = order.options[args.option]
    if not opt or opt.kind ~= "coin" then return { ok = false, error = "invalid_option" } end
    if args.unitPrice <= opt.unitPrice then return { ok = false, error = "price_not_higher", unitPrice = opt.unitPrice } end
    local pmin, pmax = EC.sandbox("MarketPriceMin", 1), EC.sandbox("MarketPriceMax", 1000000)
    if not isInt(args.unitPrice, pmin, pmax) then return { ok = false, error = "price_range", min = pmin, max = pmax } end
    local def, cerr = Mk.currencyState(opt.currency)
    if not def then return { ok = false, error = cerr, currency = opt.currency } end
    local delta = (args.unitPrice - opt.unitPrice) * order.qty
    local fee = Mk.pct(delta, EC.sandbox("MarketListingFeePercent", 2))
    if L.getBalance(username, opt.currency).available < delta + fee then
        return { ok = false, error = "insufficient_funds", currency = opt.currency, needed = delta + fee }
    end
    local postings = {
        { account = username, currency = opt.currency, amount = -(delta + fee), fee = fee > 0 and fee or nil },
        { account = username, currency = opt.currency, amount = delta, bucket = "reserved" },
    }
    if fee > 0 then postings[3] = { account = Wd.BURN_ACCOUNT, currency = opt.currency, amount = fee } end
    -- the offers this price meets, decided before the commit so the record can say how many
    local kept, met = {}, {}
    for _, f in ipairs(order.offers) do
        if f.option == args.option and f.unitPrice <= args.unitPrice then met[#met + 1] = f else kept[#kept + 1] = f end
    end
    local meta = copy(fp)
    meta.currency, meta.held, meta.delta, meta.fee, meta.met = opt.currency, opt.held + delta, delta, fee, #met
    local res = L.post({
        kind = "wanted_raise", requestId = requestId, reasonCode = "wanted_raise", actor = username, idemMeta = meta,
        payload = { item = order.item, qty = order.qty, orderId = order.id, option = args.option, currency = opt.currency },
        postings = postings,
    })
    if not res.ok then return { ok = false, error = res.error, currency = opt.currency } end
    opt.unitPrice, opt.held, opt.fee = args.unitPrice, opt.held + delta, (opt.fee or 0) + fee
    order.offers = kept
    dropMemos(order.id, met)
    X.emit("wanted.raised", { orderId = order.id, owner = username, option = args.option, currency = opt.currency,
        unitPrice = opt.unitPrice, delta = delta, fee = fee, met = #met, txId = res.txId })
    X.market(username, { kind = "wanted_raised", orderId = order.id, item = order.item, qty = order.qty,
        price = opt.unitPrice, currency = opt.currency, fee = fee, txId = res.txId })
    for _, f in ipairs(met) do
        local seller = S.accountOf(f.from)
        X.market(seller, { kind = "wanted_offer_met", orderId = order.id, item = order.item, qty = order.qty,
            price = opt.unitPrice, currency = opt.currency, other = username })
        notify(seller, { kind = "wanted_raised", orderId = order.id, item = order.item, qty = order.qty,
            price = opt.unitPrice, currency = opt.currency, from = username })
    end
    return { ok = true, txId = res.txId, orderId = order.id, option = args.option, currency = opt.currency,
        unitPrice = opt.unitPrice, held = opt.held, delta = delta, fee = fee,
        balance = L.getBalance(username, opt.currency).available, met = #met }
end

-- args = { orderId, from, requestId }: the buyer drops one offer; its seller is not told.
function Wd.dismiss(player, args)
    local username = S.principal(player)
    if type(args) ~= "table" or not requestIdOf(args) or type(args.orderId) ~= "string" or type(args.from) ~= "string" then
        return { ok = false, error = "invalid_args" }
    end
    if not T.near(player) then return { ok = false, error = "not_at_terminal" } end
    local order = md.wanted.orders[args.orderId]
    if not order then return { ok = false, error = "unknown_order" } end
    if order.owner ~= username then return { ok = false, error = "not_owner" } end
    local gone, at = offerOf(order, args.from)
    if not at then return { ok = false, error = "unknown_offer" } end
    table.remove(order.offers, at)
    dropMemos(order.id, { gone })
    X.emit("wanted.dismissed", { orderId = order.id, owner = username, from = args.from })
    return { ok = true, orderId = order.id, from = args.from }
end

-- ---------- rollback (rule three row 4, from ECMailbox.reconcileOuts through Mk.restoreFromPending) ----------

-- A buyer's lot ("wanted") or a seller's delivery ("fill") that a world rollback lost while the
-- player save kept the pending record: the goods go back to the login's account as a return
-- letter. The order is never rebuilt - the money that went with it is in the world save and
-- rolled back with it. Returns ok, info (ECMailbox writes the receipt and reads info.mailId).
function Wd.restoreFromPending(username, id, pend)
    local Rec = S.Recovery
    if Rec == nil or type(Rec.isProven) ~= "function" or not Rec.isProven(pend) then
        return false, { reason = "proof_required", kind = type(pend) == "table" and pend.kind or nil }
    end
    local snapshot, qty = pend.snapshot, tonumber(pend.qty)
    if type(snapshot) ~= "table" or type(snapshot.type) ~= "string" or not isInt(qty, 1, Wd.QTY_MAX) then
        return false, { reason = "restore_failed", cause = "bad_record", kind = pend.kind, qty = qty, snapshot = snapshot }
    end
    local owner = S.accountOf(username)
    local entry = M.add(owner, { kind = "return", item = snapshot.type, qty = qty, snapshot = snapshot, listingId = id })
    X.market(owner, { kind = "wanted_returned", item = snapshot.type, qty = qty, mailId = entry.id })
    return true, { mailId = entry.id, reason = "return" }
end

-- ---------- commands ----------

local function withRequestId(res, args)
    res.requestId = requestIdOf(args)
    return res
end

S.handlers["wanted.browse"] = function(player, args)
    local res = Wd.browse(S.principal(player), args)
    res.atTerminal = T.near(player)
    S.reply(player, "wanted.browse", withRequestId(res, args))
end

S.handlers["wanted.mine"] = function(player, args)
    S.reply(player, "wanted.mine", withRequestId({ ok = true, orders = Wd.mine(S.principal(player)),
        max = EC.sandbox("WantedMaxPerPlayer", 5), atTerminal = T.near(player) }, args))
end

S.handlers["wanted.candidates"] = function(player, args)
    local username = S.principal(player)
    local order = type(args) == "table" and type(args.orderId) == "string" and md.wanted.orders[args.orderId] or nil
    local res
    if not order then res = { ok = false, error = "unknown_order", rows = {} }
    elseif order.owner == username then res = { ok = false, error = "own_order", rows = {} }
    else res = { ok = true, rows = Wd.candidates(player, order) } end
    res.orderId = order and order.id or nil
    res.atTerminal, res.usage = T.near(player), M.usage(username)
    S.reply(player, "wanted.candidates", withRequestId(res, args))
end

S.handlers["wanted.create"] = function(player, args)
    local res = withRequestId(Wd.create(player, args), args)
    res.mine, res.usage = Wd.mine(S.principal(player)), M.usage(S.principal(player))
    S.reply(player, "wanted.create", res)
end

S.handlers["wanted.fill"] = function(player, args)
    local res = withRequestId(Wd.fill(player, args), args)
    res.unclaimed = M.unclaimed(S.principal(player))
    S.reply(player, "wanted.fill", res)
end

S.handlers["wanted.cancel"] = function(player, args)
    local res = withRequestId(Wd.cancel(player, args), args)
    res.mine, res.unclaimed = Wd.mine(S.principal(player)), M.unclaimed(S.principal(player))
    S.reply(player, "wanted.cancel", res)
end

S.handlers["wanted.offer"] = function(player, args)
    S.reply(player, "wanted.offer", withRequestId(Wd.offer(player, args), args))
end

S.handlers["wanted.raise"] = function(player, args)
    local res = withRequestId(Wd.raise(player, args), args)
    res.mine = Wd.mine(S.principal(player))
    S.reply(player, "wanted.raise", res)
end

S.handlers["wanted.dismiss"] = function(player, args)
    local res = withRequestId(Wd.dismiss(player, args), args)
    res.mine = Wd.mine(S.principal(player))
    S.reply(player, "wanted.dismiss", res)
end

-- The player's own buy-order lines of the market history (the same files market.history reads).
S.handlers["wanted.history"] = function(player, args)
    local username = S.principal(player)
    local extra = { username = username }
    if type(args) == "table" and args.requestId ~= nil then
        if not requestIdOf(args) then
            S.reply(player, "wanted.history", { entries = {}, total = 0, truncated = false, error = "invalid_args", username = username })
            return
        end
        extra.requestId = args.requestId
    end
    W.tail(player, "wanted.history", W.marketPaths(username, W.recentMonths(EC.now())), extra, function(entry)
        if type(entry.kind) == "string" and string.sub(entry.kind, 1, 7) == "wanted_" then return entry end
        return nil
    end)
end

-- admin.wanted {action = "list", query?, owner?, page?, requestId} (read gate) |
--              {action = "cancel", orderId, reason, requestId} (write gate, audited)
S.handlers["admin.wanted"] = function(player, args)
    args = type(args) == "table" and args or {}
    local action = args.action or "list"
    local requestId = requestIdOf(args)
    if not A.gate(player, "admin.wanted", action == "cancel", requestId) then return end
    local res = { ok = true, action = action, requestId = requestId }
    if (action ~= "list" and action ~= "cancel") or (args.requestId ~= nil and requestId == nil)
        or (args.owner ~= nil and (type(args.owner) ~= "string" or args.owner == "" or #args.owner > 64)) then
        res.ok, res.error = false, "invalid_args"
    elseif action == "cancel" then
        local reasonError, reason = A.reasonError(args.reason)
        res.orderId = type(args.orderId) == "string" and args.orderId or nil
        if res.orderId == nil then
            res.ok, res.error = false, "invalid_args"
        elseif reasonError then
            res.ok, res.error = false, reasonError
        else
            local ok, err = Wd.adminCancel(S.principal(player), res.orderId, reason)
            if ok then res.refunded = err else res.ok, res.error = false, err end
        end
    else
        local query = queryOf(args)
        local rows = {}
        for _, o in pairs(md.wanted.orders) do
            if (args.owner == nil or o.owner == args.owner) and matches(o, query) then rows[#rows + 1] = o end
        end
        EC.sortSafe(rows, newestFirst)
        res.rows, res.page, res.pages, res.total = page(rows, args.page, S.principal(player), "admin")
        res.per, res.query, res.owner, res.stats = Wd.PAGE, query, args.owner, Wd.stats()
    end
    S.reply(player, "admin.wanted", res)
end

function Wd.init(root)
    md = root
    md.wanted = md.wanted or { orders = {}, byOwner = {}, count = 0 }
    lotIndex = {}
    for id, o in pairs(md.wanted.orders) do
        local opt = lotOption(o)
        if opt then lotIndex[opt.lot.id] = id end
    end
    lastSweep = 0
    memoLoad()
    memoSync()
end

S.Wanted = Wd
S.onInit(Wd.init)
Events.OnTickEvenPaused.Add(Wd.onTick)
return Wd
