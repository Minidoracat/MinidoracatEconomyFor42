-- MinidoracatEconomyFor42 - system shop: sell side (spec 12 stage C) and buyback (stage G).
--
-- The catalog is a server-owned file, {cachedir}/Lua/MinidoracatEconomy/catalog.json (one JSON
-- document: {"items":[{"id","item","qty","category","enabled","dailyCap","dailyCapScope",
-- "buybackCap","prices":{"<currency>":{"price","bidPrice","enabled","buyback"}}}]}), read at
-- start and on admin.catalog{action="reload"}; a broken file keeps the previous catalog and the
-- error is shown in the panel. A SKU carries one quote per currency it trades in: `price` is
-- what a copy costs in that currency, `bidPrice` what buyback pays for it, `enabled` whether it
-- sells in that currency and `buyback` whether it is bought back in it. A currency with no quote
-- is not on offer at all - it is never a free one and never silently swapped for another. Rows
-- written before the shop had more than one currency carry a flat price and are normalised into
-- prices.survivor once, on the way in; the writer only ever writes the current shape.
-- The admin page edits the per-SKU numbers and flags and those edits are written straight back
-- into the file (the file is the single source of truth, it never rolls back with the world
-- save; a hand edit made since the last load is detected by hash and refused until the admin
-- reloads). Every change is pushed to everyone online. Players see the catalog under a revision
-- string (the file hash); shop.buy and shop.sell carry that revision and are refused when the
-- catalog changed underneath (no silent repricing).
--
-- A purchase names its currency, burns it (player -> SYSTEM_BURN), counts against the SKU's
-- cap: dailyCapScope "player"/"global" use the reward day (ECRewards.dayKey), while
-- "lifetime" counts all this account's purchases since tracking began in this world.
-- The published dailyCap field still holds the limit in shares; 0 means unlimited.
-- The letter is built and weighed before the debit: an item this server cannot create
-- costs nothing, and a purchase that does not fit in the backpack is refused with
-- mail_confirmation_required (nothing debited, no entry) until the client confirms the mailbox.
--
-- Buyback is the faucet: the player hands over canonical copies of a SKU (Codec.isCanonical) and
-- the server mints the chosen currency's bidPrice per unit (SYSTEM_MINT -> player), destroying
-- the items in the same tick through the mailbox's three-phase list-out (M.beginOut /
-- M.abortOut / M.finishOut, pending kind "buyback": a crash between the removal and the credit
-- is repaired by ECMailbox.reconcileOuts, rows 4-6). Three gross mint caps per reward day, none
-- reopened by burns: per SKU (shares, catalog buybackCap - one pool across currencies), and per
-- account and server-wide (coins, per currency, ECConfig buybackCaps). A currency whose account
-- or server cap is 0 does not buy back at all; the sandbox ShopBuybackEnabled switch closes the
-- faucet for every currency at once. ECCodec and ECMarket load after this file (they require
-- it), so they are reached through S at call time.

if not MinidoracatEconomy or not MinidoracatEconomy.Mailbox then
    require "MinidoracatEconomy/ECMailbox"
end
local EC = MinidoracatEconomy
local S = EC and EC.Server
local L = EC and EC.Ledger
local X = EC and EC.Export
local Cfg = EC and EC.Config
local R = EC and EC.Rewards
local T = EC and EC.Terminal
local M = EC and EC.Mailbox
if not S or not S.AUTHORITY or not L or not X or not Cfg or not R or not T or not M then
    return
end

EC.Shop = EC.Shop or {}
local Shop = EC.Shop

Shop.FILE = X.ROOT .. "/catalog.json"
Shop.BURN_ACCOUNT = "SYSTEM_BURN"
Shop.MINT_ACCOUNT = "SYSTEM_MINT"
Shop.MAX_SKUS = 200
Shop.ID_MAX = 32
Shop.CATEGORY_MAX = 32
Shop.QTY_MAX = 50
Shop.COUNT_MAX = 10
Shop.ITEMS_PER_BUY_MAX = 100
Shop.PRICE_MAX = 1000000000
Shop.CAP_MAX = 1000000
Shop.DAILY_KEEP_DAYS = 31
Shop.FILE_LINES_MAX = 20000
Shop.BUYBACK_DAY_VERSION = 2
-- Fields of a SKU an admin patch may change on an existing row. id and item are fixed once the
-- row exists; the per-currency numbers live under `prices` and are patched leaf by leaf.
Shop.UPDATE_FIELDS = { "qty", "category", "dailyCap", "dailyCapScope", "enabled", "buybackCap" }
Shop.QUOTE_FIELDS = { "price", "bidPrice", "enabled", "buyback" }

-- Written when the file is missing so the host sees the shape. Prices are in the survivor
-- currency (daily check-in pays 30 by default); the host is expected to edit this and to add
-- the quotes of any other currency it wants the shop to trade in. bidPrice is what buyback would
-- pay once the host turns that quote's buyback flag (and the sandbox switch) on.
Shop.DEFAULT_ITEMS = {
    { id = "bandage", item = "Base.Bandage", qty = 1, dailyCap = 5, category = "medical",
        prices = { survivor = { price = 12, bidPrice = 5 } } },
    { id = "antibiotics", item = "Base.Antibiotics", qty = 1, dailyCap = 2, dailyCapScope = "global", category = "medical",
        prices = { survivor = { price = 60, bidPrice = 25 } } },
    { id = "ripped_sheets", item = "Base.RippedSheets", qty = 5, dailyCap = 5, category = "medical",
        prices = { survivor = { price = 10, bidPrice = 4 } } },
    { id = "canned_corn", item = "Base.CannedCorn", qty = 2, dailyCap = 5, category = "food",
        prices = { survivor = { price = 20, bidPrice = 8 } } },
    { id = "nails", item = "Base.Nails", qty = 20, dailyCap = 5, category = "material",
        prices = { survivor = { price = 25, bidPrice = 10 } } },
    { id = "screws", item = "Base.Screws", qty = 20, dailyCap = 5, category = "material",
        prices = { survivor = { price = 25, bidPrice = 10 } } },
    { id = "plank", item = "Base.Plank", qty = 5, dailyCap = 5, category = "material",
        prices = { survivor = { price = 30, bidPrice = 12 } } },
    { id = "rope", item = "Base.Rope", qty = 2, dailyCap = 5, category = "material",
        prices = { survivor = { price = 24, bidPrice = 10 } } },
    { id = "twine", item = "Base.Twine", qty = 1, dailyCap = 5, category = "material",
        prices = { survivor = { price = 12, bidPrice = 5 } } },
    { id = "lighter", item = "Base.Lighter", qty = 1, dailyCap = 2, category = "tool",
        prices = { survivor = { price = 15, bidPrice = 6 } } },
    { id = "hammer", item = "Base.Hammer", qty = 1, dailyCap = 1, category = "tool",
        prices = { survivor = { price = 80, bidPrice = 30 } } },
    { id = "saw", item = "Base.Saw", qty = 1, dailyCap = 1, category = "tool",
        prices = { survivor = { price = 90, bidPrice = 35 } } },
    { id = "axe", item = "Base.Axe", qty = 1, dailyCap = 1, dailyCapScope = "global", category = "tool",
        prices = { survivor = { price = 150, bidPrice = 60 } } },
}

local md = nil
local file = { items = {}, byId = {}, count = 0, loadedAt = 0, error = nil, hash = "0" }

-- ---------- currencies ----------

-- Registered, tradable (marketUnit) and not switched off at runtime. There is no "the shop's
-- currency": every price names its own, and a request names the one it wants to pay in.
-- Returns the currency record, or nil plus the refusal code.
local function currencyState(id)
    if not L.isCurrency(id) then return nil, "unknown_currency" end
    local def = Cfg.currency(id)
    if not def then return nil, "unknown_currency" end
    if def.marketUnit ~= true then return nil, "currency_unavailable" end
    if def.enabled == false then return nil, "currency_disabled" end
    return def
end

local function optionInt(key)
    local spec = EC.OPTION_BY_KEY[key]
    if not spec then return 0 end
    local v = EC.sandbox(key, type(spec.default) == "number" and spec.default or 0)
    return type(v) == "number" and math.floor(v) or 0
end

-- The gross mint caps of one currency for a reward day. ECConfig owns the effective values
-- (runtime override > sandbox file > code default) and hands them over on the currency record;
-- the sandbox keys in EC.BUYBACK_OPTIONS are the same values read directly when that block is
-- not there. A cap of 0 means this currency does not buy back - it never means "unlimited".
local function buybackCaps(id)
    local def = Cfg.currency(id)
    local caps = def and def.buybackCaps
    if type(caps) == "table" then
        return { account = math.max(0, math.floor(tonumber(caps.account) or 0)),
            server = math.max(0, math.floor(tonumber(caps.server) or 0)) }
    end
    local keys = EC.BUYBACK_OPTIONS and EC.BUYBACK_OPTIONS[id]
    if type(keys) == "table" then
        return { account = optionInt(keys.account), server = optionInt(keys.server) }
    end
    return { account = 0, server = 0 }
end

-- ---------- validation ----------

local function isInt(v, lo, hi)
    return type(v) == "number" and v == math.floor(v) and v >= lo and v <= hi
end

local function validId(id)
    return type(id) == "string" and #id <= Shop.ID_MAX and string.match(id, "^[A-Za-z0-9_%-]+$") ~= nil
end

local function itemExists(fullType)
    if type(fullType) ~= "string" or fullType == "" or #fullType > 128 then return false end
    local ok, found = pcall(function() return ScriptManager.instance:FindItem(fullType) ~= nil end)
    return ok and found == true
end

-- One currency's quote of a SKU: 0 <= bidPrice < price, and the two direction flags. The flags
-- (not a zero price) say whether the SKU sells / is bought back in this currency, so a stopped
-- quote keeps the price it will trade at again when it is switched back on.
local function validateQuote(raw, where, currency)
    if type(raw) ~= "table" then return nil, where .. ": " .. currency .. " quote is not an object" end
    if not isInt(raw.price, 1, Shop.PRICE_MAX) then
        return nil, where .. ": " .. currency .. " price must be 1-" .. Shop.PRICE_MAX
    end
    local bid = raw.bidPrice == nil and 0 or raw.bidPrice
    if not isInt(bid, 0, raw.price - 1) then
        return nil, where .. ": " .. currency .. " bidPrice must be 0-" .. (raw.price - 1)
    end
    if raw.enabled ~= nil and type(raw.enabled) ~= "boolean" then
        return nil, where .. ": " .. currency .. " enabled must be true/false"
    end
    if raw.buyback ~= nil and type(raw.buyback) ~= "boolean" then
        return nil, where .. ": " .. currency .. " buyback must be true/false"
    end
    if raw.buyback == true and bid < 1 then
        return nil, where .. ": " .. currency .. " buyback needs a bidPrice of at least 1"
    end
    return { price = raw.price, bidPrice = bid, enabled = raw.enabled ~= false, buyback = raw.buyback == true }
end

-- One raw catalog row -> normalised sku or nil, error text (for the panel).
local function validateSku(raw, index)
    local where = "item " .. tostring(index)
    if type(raw) ~= "table" then return nil, where .. ": not an object" end
    if not validId(raw.id) then return nil, where .. ": bad id" end
    where = raw.id
    if not itemExists(raw.item) then return nil, where .. ": unknown item " .. tostring(raw.item) end
    local qty = raw.qty == nil and 1 or raw.qty
    if not isInt(qty, 1, Shop.QTY_MAX) then return nil, where .. ": qty must be 1-" .. Shop.QTY_MAX end
    local cap = raw.dailyCap == nil and 0 or raw.dailyCap
    if not isInt(cap, 0, Shop.CAP_MAX) then return nil, where .. ": dailyCap must be 0-" .. Shop.CAP_MAX end
    -- Shares, not pieces. Keep the published field names; only the mode determines the period.
    -- Older catalogs omit the scope and remain per-player, per reward day.
    local scope = raw.dailyCapScope == nil and "player" or raw.dailyCapScope
    if scope ~= "player" and scope ~= "global" and scope ~= "lifetime" then
        return nil, where .. ": dailyCapScope must be player, global or lifetime"
    end
    local category = raw.category == nil and "other" or raw.category
    if type(category) ~= "string" or category == "" or #category > Shop.CATEGORY_MAX or string.find(category, "%c") then
        return nil, where .. ": bad category"
    end
    if raw.enabled ~= nil and type(raw.enabled) ~= "boolean" then return nil, where .. ": enabled must be true/false" end
    local bcap = raw.buybackCap == nil and 0 or raw.buybackCap
    if not isInt(bcap, 0, Shop.CAP_MAX) then return nil, where .. ": buybackCap must be 0-" .. Shop.CAP_MAX end
    local prices, quoted = {}, 0
    if raw.prices ~= nil then
        if type(raw.prices) ~= "table" then return nil, where .. ": prices must be an object" end
        -- a row cannot be both shapes: which of the two the old flat price meant would be a guess
        if raw.price ~= nil or raw.bidPrice ~= nil or raw.buyback ~= nil then
            return nil, where .. ": prices and a flat price cannot both be given"
        end
        for currency, quote in pairs(raw.prices) do
            if not L.isCurrency(currency) then return nil, where .. ": unknown currency " .. tostring(currency) end
            local q, err = validateQuote(quote, where, currency)
            if not q then return nil, err end
            prices[currency] = q
            quoted = quoted + 1
        end
    elseif raw.price ~= nil then
        -- legacy single-currency row, normalised once here: the sale direction was the SKU's own
        -- enabled flag, so the quote itself is on
        local q, err = validateQuote({ price = raw.price, bidPrice = raw.bidPrice, enabled = true, buyback = raw.buyback },
            where, L.LEGACY_CURRENCY)
        if not q then return nil, err end
        prices[L.LEGACY_CURRENCY] = q
        quoted = 1
    end
    if quoted == 0 then return nil, where .. ": no price in any currency" end
    return {
        id = raw.id, item = raw.item, qty = qty, dailyCap = cap, dailyCapScope = scope,
        category = category, enabled = raw.enabled ~= false, buybackCap = bcap, prices = prices,
    }
end

-- ---------- cross-SKU price safety (spec contract 10) ----------
--
-- Every enabled quote is turned into a per-item rate first: one copy of a fullType costs
-- price/qty to buy in that currency and earns bidPrice/qty to sell, so two SKUs of the same item
-- with different bundle sizes are compared on the same scale. A catalog is refused when a cycle
-- over those rates ends with more money than it started with: the same currency (buy from one
-- SKU, sell to another) or a two-currency loop (buy in A and sell in B, buy in B and sell in A).
-- Only directions that are actually switched on count. There is no exchange rate here and none
-- is invented: the loop is closed by the shop's own quotes, which is exactly what makes it free
-- money. A daily cap rations an exploit, it never closes one, so caps are not part of this.

-- Profit of a cycle is compared with a tolerance that is far below one coin on the largest
-- allowed price (1e-9 relative) and far above the noise of four double multiplications (~4e-16).
local ARBITRAGE_EPSILON = 1e-12

local function bestRates(items)
    local byItem = {}
    for _, sku in ipairs(items) do
        local row = byItem[sku.item]
        if not row then
            row = { ask = {}, bid = {} }
            byItem[sku.item] = row
        end
        for currency, q in pairs(sku.prices) do
            -- sku.enabled is the sale switch: it closes the way in, never the way out. A row
            -- taken off the shelf still buys back, so its bid stays in the loop check - leaving
            -- it out would open exactly the gap the sale switch is not supposed to open.
            if sku.enabled and q.enabled then
                local best = row.ask[currency]
                -- cheapest way in: q.price / sku.qty per copy (cross-multiplied, exact)
                if not best or q.price * best.qty < best.price * sku.qty then
                    row.ask[currency] = { price = q.price, qty = sku.qty, id = sku.id }
                end
            end
            if q.buyback and q.bidPrice > 0 then
                local best = row.bid[currency]
                if not best or q.bidPrice * best.qty > best.price * sku.qty then
                    row.bid[currency] = { price = q.bidPrice, qty = sku.qty, id = sku.id }
                end
            end
        end
    end
    return byItem
end

-- nil, or { id, currency, otherId, otherCurrency, cycle? } naming the two quotes that close the
-- loop (the buy side first).
local function arbitrage(items)
    local byItem = bestRates(items)
    for _, row in pairs(byItem) do
        for currency, bid in pairs(row.bid) do
            local ask = row.ask[currency]
            -- integers below 1e9 * 50: the cross product is exact in a double
            if ask and bid.price * ask.qty > ask.price * bid.qty then
                return { field = "prices", id = ask.id, currency = currency, otherId = bid.id, otherCurrency = currency }
            end
        end
    end
    local best = {}
    for _, row in pairs(byItem) do
        for from, ask in pairs(row.ask) do
            for to, bid in pairs(row.bid) do
                if from ~= to then
                    local ratio = (bid.price * ask.qty) / (ask.price * bid.qty)
                    local key = from .. "\1" .. to
                    local prev = best[key]
                    if not prev or ratio > prev.ratio then
                        best[key] = { ratio = ratio, from = from, to = to, askId = ask.id, bidId = bid.id }
                    end
                end
            end
        end
    end
    for _, leg in pairs(best) do
        local back = best[leg.to .. "\1" .. leg.from]
        if back and leg.ratio * back.ratio > 1 + ARBITRAGE_EPSILON then
            return { field = "prices", id = leg.askId, currency = leg.from,
                otherId = back.askId, otherCurrency = back.from, cycle = true }
        end
    end
    return nil
end

local function arbitrageText(conflict)
    return "arbitrage: " .. tostring(conflict.id) .. " (" .. tostring(conflict.currency) .. ") and "
        .. tostring(conflict.otherId) .. " (" .. tostring(conflict.otherCurrency) .. ")"
end

local function parseCatalog(text)
    local doc, err = EC.jsonDecode(text)
    if doc == nil then return nil, "json: " .. tostring(err) end
    local rows = type(doc) == "table" and doc.items or nil
    if type(rows) ~= "table" then return nil, "missing \"items\" array" end
    if #rows > Shop.MAX_SKUS then return nil, "more than " .. Shop.MAX_SKUS .. " items" end
    local items, byId = {}, {}
    for i, raw in ipairs(rows) do
        local sku, e = validateSku(raw, i)
        if not sku then return nil, e end
        if byId[sku.id] then return nil, sku.id .. ": duplicate id" end
        byId[sku.id] = sku
        items[#items + 1] = sku
    end
    local conflict = arbitrage(items)
    if conflict then return nil, arbitrageText(conflict), "arbitrage_rejected", conflict end
    return { items = items, byId = byId }
end

-- ---------- file ----------

local function readFile()
    local reader = nil
    local ok = pcall(function() reader = getFileReader(Shop.FILE, false) end)
    if not ok or not reader then return nil end
    local lines = {}
    ok = pcall(function()
        for _ = 1, Shop.FILE_LINES_MAX do
            local line = reader:readLine()
            if line == nil then break end
            lines[#lines + 1] = line
        end
    end)
    local closed = pcall(function() reader:close() end)
    if not ok or not closed then return nil end
    return table.concat(lines, "\n")
end

-- The document shape of one row: always the current one, whatever shape it was read from.
local function rowDocument(row)
    local prices = {}
    for currency, q in pairs(row.prices or {}) do
        prices[currency] = { price = q.price, bidPrice = q.bidPrice or 0,
            enabled = q.enabled ~= false, buyback = q.buyback == true }
    end
    return {
        id = row.id, item = row.item, qty = row.qty, category = row.category,
        enabled = row.enabled ~= false, dailyCap = row.dailyCap,
        dailyCapScope = row.dailyCapScope,
        buybackCap = row.buybackCap or 0, prices = prices,
    }
end

-- Canonical serialisation: one SKU per line so a host can still hand-edit the file.
local function writeCatalog(rows)
    local writer = nil
    local ok = pcall(function() writer = getFileWriter(Shop.FILE, true, false) end)
    if not ok or not writer then return false end
    local wrote = pcall(function()
        writer:writeln("{")
        writer:writeln('  "items": [')
        for i, row in ipairs(rows) do
            writer:writeln("    " .. EC.jsonEncode(rowDocument(row)) .. (i < #rows and "," or ""))
        end
        writer:writeln("  ]")
        writer:writeln("}")
    end)
    local closed = pcall(function() writer:close() end)
    return wrote and closed
end

local function hashOf(text)
    return EC.hashHex(EC.hashUpdate(EC.hashInit(), text))
end

-- Adopt only a fully parsed read. Failed panel writes must not alter the live catalog.
-- Returns ok, error text, error code, extra: the code is what a reply carries (a refused reload
-- says arbitrage_rejected, not just "the file is invalid") and the extra names the two quotes.
local function loadCatalog(text)
    local parsed, err, code, extra = parseCatalog(text)
    if not parsed then
        file.error, file.errorCode, file.errorDetail = err, code or "catalog_invalid", extra
        EC.log("catalog.json rejected: " .. tostring(err))
        return false, err, file.errorCode, extra
    end
    file.items, file.byId, file.count = parsed.items, parsed.byId, #parsed.items
    -- the per-copy weight estimate is taken once here (cached per fullType in ECMailbox), so a
    -- snapshot never builds items just to say how heavy a purchase would be
    for _, sku in ipairs(file.items) do sku.weight = M.scriptWeight(sku.item) end
    file.loadedAt = EC.now()
    file.error, file.errorCode, file.errorDetail = nil, nil, nil
    file.hash = hashOf(text)
    return true
end

-- Only initial loading may create the default file; write verification never does.
function Shop.load()
    local text = readFile()
    if text == nil then
        local checked, exists = pcall(cacheFileExists, Shop.FILE)
        if not checked or exists then
            file.error, file.errorCode, file.errorDetail = "catalog file unreadable", "file_unreadable", nil
            return false, file.error, file.errorCode
        end
        if not writeCatalog(Shop.DEFAULT_ITEMS) then
            file.error, file.errorCode, file.errorDetail = "catalog file unavailable", "file_write_failed", nil
            return false, file.error, file.errorCode
        end
        text = readFile() or ""
    end
    return loadCatalog(text)
end

function Shop.fileStatus()
    return { count = file.count, loadedAt = file.loadedAt, error = file.error,
        errorCode = file.errorCode, errorDetail = file.errorDetail, path = Shop.FILE }
end

-- ---------- catalog view ----------

function Shop.revision()
    return file.hash
end

function Shop.sku(id)
    local base = type(id) == "string" and file.byId[id] or nil
    if not base then return nil end
    local prices = {}
    for currency, q in pairs(base.prices) do
        prices[currency] = { price = q.price, bidPrice = q.bidPrice, enabled = q.enabled, buyback = q.buyback }
    end
    return {
        id = base.id, item = base.item, qty = base.qty, category = base.category,
        dailyCap = base.dailyCap, dailyCapScope = base.dailyCapScope or "player", enabled = base.enabled,
        weight = base.weight, buybackCap = base.buybackCap, prices = prices,
    }
end

-- Does any currency buy this SKU back at all (whatever today's caps say)?
local function anyBuyback(sku)
    for _, q in pairs(sku.prices) do
        if q.buyback and q.bidPrice > 0 then return true end
    end
    return false
end

-- The one place a request's currency becomes a price. `direction` is "buy" or "sell". It never
-- falls back to another currency: a quote that is not there is not a free one.
-- Returns the quote, or nil plus one of unknown_currency / currency_disabled /
-- currency_unavailable / currency_closed / invalid_args.
function Shop.quote(sku, currency, direction)
    if type(currency) ~= "string" or currency == "" then return nil, "invalid_args" end
    local def, err = currencyState(currency)
    if not def then return nil, err end
    local q = sku and sku.prices and sku.prices[currency] or nil
    if not q then return nil, "currency_unavailable" end
    if direction == "buy" then
        if not q.enabled then return nil, "currency_closed" end
    else
        if not q.buyback or q.bidPrice < 1 then return nil, "currency_closed" end
        local caps = buybackCaps(currency)
        if caps.account <= 0 or caps.server <= 0 then return nil, "currency_closed" end
    end
    return q
end

-- Day buckets (reward day) with the same 31-day retention: store[day] = byKey. Returns the day
-- table or nil when it does not exist and create is false.
local function dayTable(store, day, create)
    local byDay = store[day]
    if not byDay then
        if not create then return nil end
        byDay = {}
        store[day] = byDay
        local oldest = R.dayKey(EC.now() - Shop.DAILY_KEEP_DAYS * 86400000)
        local stale = {}
        for k in pairs(store) do if k < oldest then stale[#stale + 1] = k end end
        for _, k in ipairs(stale) do store[k] = nil end
    end
    return byDay
end

local function dailyRow(day, username, create)
    local byDay = dayTable(md.shopDaily, day, create)
    if not byDay then return nil end
    local row = byDay[username]
    if not row and create then
        row = {}
        byDay[username] = row
    end
    return row
end

-- Volatile per-day totals for the global scope. md.shopDaily is the persistent daily source;
-- this only caches "shares of this SKU the whole server bought today" so a snapshot does
-- not walk every account for every SKU. It is rebuilt on demand from shopDaily (which the buy
-- path has already updated), and a successful buy adds to it only when it is already built for
-- that day - otherwise the first rebuild after that buy would count it twice. Shop.init clears
-- it; a day change rebuilds it; changing a SKU's scope or cap never clears usage.
local totals = { day = nil, byId = nil }

local function globalToday(id, ms)
    local day = R.dayKey(ms)
    if totals.day ~= day or not totals.byId then
        local acc = {}
        local byDay = md.shopDaily[day]
        if byDay then
            for _, row in pairs(byDay) do
                for sku, n in pairs(row) do acc[sku] = (acc[sku] or 0) + (tonumber(n) or 0) end
            end
        end
        totals.day, totals.byId = day, acc
    end
    return totals.byId[id] or 0
end

-- Snapshot, purchase guard and reply use the same scope-aware count, always across currencies.
function Shop.used(username, id, ms)
    local base = type(id) == "string" and file.byId[id] or nil
    if base and base.dailyCapScope == "lifetime" then
        local row = md.shopLifetime[username]
        return row and row[id] or 0
    end
    if base and base.dailyCapScope == "global" then return globalToday(id, ms) end
    local row = dailyRow(R.dayKey(ms), username, false)
    return row and row[id] or 0
end

local function noteBuy(day, username, id, count)
    local row = dailyRow(day, username, true)
    row[id] = (row[id] or 0) + count
    if totals.day == day and totals.byId then totals.byId[id] = (totals.byId[id] or 0) + count end
    -- Count even unlimited/daily sales so switching modes never grants a fresh lifetime allowance.
    -- One number per purchased SKU, not a permanent log of individual orders.
    local lifetime = md.shopLifetime[username]
    if not lifetime then
        lifetime = {}
        md.shopLifetime[username] = lifetime
    end
    lifetime[id] = (lifetime[id] or 0) + count
    return lifetime[id]
end

-- ---------- buyback day buckets ----------

-- The coin caps are per currency, the share cap is one pool across them (spec contract 8):
-- { v = 2, byCurrency = { [currency] = coins }, accounts = { [username\1currency] = coins },
--   skus = { [id] = shares } }.
local function accountKey(username, currency)
    return tostring(username) .. "\1" .. tostring(currency)
end

local function buybackDay(ms, create)
    local t = dayTable(md.shopBuyback, R.dayKey(ms), create)
    if not t then return nil end
    if t.v ~= Shop.BUYBACK_DAY_VERSION then
        -- A bucket from the single-currency shop: one bare coin total and one bare number per
        -- account, all of it minted in the currency the shop had then. Normalised once, here.
        local byCurrency, accounts = {}, {}
        local legacyTotal = tonumber(t.total) or 0
        if legacyTotal > 0 then byCurrency[L.LEGACY_CURRENCY] = legacyTotal end
        if type(t.accounts) == "table" then
            for name, coins in pairs(t.accounts) do
                local n = tonumber(coins)
                if n then accounts[accountKey(name, L.LEGACY_CURRENCY)] = n end
            end
        end
        t.byCurrency, t.accounts = byCurrency, accounts
        t.skus = type(t.skus) == "table" and t.skus or {}
        t.total = nil
        t.v = Shop.BUYBACK_DAY_VERSION
    end
    return t
end

function Shop.buybackEnabled()
    return EC.sandbox("ShopBuybackEnabled", false) == true
end

-- Shares of this SKU the whole server may still buy back today, or nil when the row has no
-- share cap. One pool across currencies.
function Shop.buybackSkuRoom(id, ms)
    local sku = type(id) == "string" and file.byId[id] or nil
    if not sku or (sku.buybackCap or 0) <= 0 then return nil end
    local t = buybackDay(ms, false)
    return math.max(0, sku.buybackCap - (t and t.skus[id] or 0))
end

-- Remaining room today for one more sale in `currency`: coins for the account and the server
-- (per currency), shares for the SKU (shared by every currency).
function Shop.buybackRoom(username, id, ms, currency)
    local t = buybackDay(ms, false)
    local caps = buybackCaps(currency)
    return {
        currency = currency,
        account = math.max(0, caps.account - ((t and t.accounts[accountKey(username, currency)]) or 0)),
        server = math.max(0, caps.server - ((t and t.byCurrency[currency]) or 0)),
        accountCap = caps.account, serverCap = caps.server,
        sku = Shop.buybackSkuRoom(id, ms),
    }
end

-- Per-currency buyback state for one player: what the shop page shows next to the currency
-- picker. A currency whose caps are 0, that is switched off, or that is not tradable at all is
-- `enabled = false` with its own numbers still visible.
function Shop.buybackByCurrency(username, ms)
    local on = Shop.buybackEnabled()
    local out = {}
    for _, id in ipairs(EC.CURRENCY_ORDER) do
        local room = Shop.buybackRoom(username, nil, ms, id)
        local def = currencyState(id)
        out[id] = {
            enabled = on and def ~= nil and room.accountCap > 0 and room.serverCap > 0,
            accountRemaining = room.account, serverRemaining = room.server,
            accountCap = room.accountCap, serverCap = room.serverCap,
        }
    end
    return out
end

-- The buyback block every reply that names one SKU carries: the per-currency coin room, and the
-- share room of that SKU beside it (shares are one pool across currencies, so they are a single
-- number and not part of byCurrency).
function Shop.buybackView(username, ms, id)
    return { enabled = Shop.buybackEnabled(), skuRemaining = Shop.buybackSkuRoom(id, ms),
        byCurrency = Shop.buybackByCurrency(username, ms) }
end

function Shop.buybackStatus(ms)
    ms = ms or EC.now()
    local t = buybackDay(ms, false)
    local byCurrency = {}
    for _, id in ipairs(EC.CURRENCY_ORDER) do
        local caps = buybackCaps(id)
        byCurrency[id] = { mintedToday = (t and t.byCurrency[id]) or 0,
            accountCap = caps.account, serverCap = caps.server }
    end
    return { enabled = Shop.buybackEnabled(), byCurrency = byCurrency }
end

local function noteBuyback(ms, username, currency, sku, total, count)
    local day = buybackDay(ms, true)
    day.byCurrency[currency] = (day.byCurrency[currency] or 0) + total
    local key = accountKey(username, currency)
    day.accounts[key] = (day.accounts[key] or 0) + total
    if sku ~= nil and count > 0 then day.skus[sku] = (day.skus[sku] or 0) + count end
end

-- The client list: every SKU (disabled ones too, for admins) with this player's remaining caps.
function Shop.snapshot(username, ms)
    ms = ms or EC.now()
    local items = {}
    for _, base in ipairs(file.items) do
        local sku = Shop.sku(base.id)
        sku.used = Shop.used(username, sku.id, ms)
        if sku.dailyCap > 0 then
            sku.remaining = math.max(0, sku.dailyCap - sku.used)
        end
        if anyBuyback(sku) then
            -- shares left for this row today, whatever currency they are sold in
            sku.buybackRemaining = Shop.buybackSkuRoom(sku.id, ms)
        end
        items[#items + 1] = sku
    end
    EC.sortSafe(items, function(a, b)
        if a.category ~= b.category then return a.category < b.category end
        return a.id < b.id
    end)
    return {
        revision = Shop.revision(), items = items, count = #items,
        file = Shop.fileStatus(), dayEndsMs = R.nextResetMs(ms), countMax = Shop.COUNT_MAX,
        buyback = { enabled = Shop.buybackEnabled(), byCurrency = Shop.buybackByCurrency(username, ms) },
    }
end

-- ---------- admin edits (written to the file) ----------

-- Every online player gets a fresh snapshot: the list they are looking at must not go stale
-- after an admin took something off the shelf or repriced it.
function Shop.pushAll()
    local ms = EC.now()
    S.forEachOnline(function(p)
        local snap = Shop.snapshot(p:getUsername(), ms)
        snap.atTerminal = T.near(p)
        snap.unclaimed = M.unclaimed(p:getUsername())
        S.reply(p, "shop.list", snap)
    end)
end

-- A global-cap SKU changes for everyone the moment anyone buys it: send that one row's
-- remaining instead of pushing the whole catalog to every player on every purchase.
local function pushStock(id, remaining, used)
    local revision = Shop.revision()
    S.forEachOnline(function(p)
        S.reply(p, "shop.stock", { id = id, remaining = remaining, used = used, revision = revision })
    end)
end

-- Both edits verify the snapshot and the disk before writing a candidate list. The loaded
-- catalog changes only after read-back succeeds; a read-back failure never creates defaults.
local function currentCatalog(expectedRevision)
    if expectedRevision ~= nil and expectedRevision ~= file.hash then return false end
    local onDisk = readFile()
    return onDisk ~= nil and hashOf(onDisk) == file.hash
end

local function commitCatalog(items, expectedRevision)
    if not currentCatalog(expectedRevision) then return false, "catalog_stale" end
    if not writeCatalog(items) then return false, "file_write_failed" end
    local written = readFile()
    if written == nil then return false, "file_write_failed" end
    local ok, err = loadCatalog(written)
    if not ok then
        EC.log("catalog.json unreadable after the panel wrote it: " .. tostring(err))
        return false, "file_write_failed"
    end
    return true
end

-- One patch value on its own; the cross-field rules (bidPrice < price, buyback needs a bid, the
-- no-arbitrage rule) are checked on the whole candidate row and on the whole catalog.
local function validField(field, value)
    if field == "qty" then return isInt(value, 1, Shop.QTY_MAX) end
    if field == "dailyCap" or field == "buybackCap" then return isInt(value, 0, Shop.CAP_MAX) end
    if field == "dailyCapScope" then return value == "player" or value == "global" or value == "lifetime" end
    if field == "enabled" then return type(value) == "boolean" end
    if field == "category" then
        return type(value) == "string" and value ~= "" and #value <= Shop.CATEGORY_MAX
            and string.find(value, "%c") == nil
    end
    return false
end

local function isQuoteField(field)
    for _, f in ipairs(Shop.QUOTE_FIELDS) do
        if f == field then return true end
    end
    return false
end

-- Every field a live `add` is allowed to carry: the two that are fixed once the row exists, the
-- ones an existing row may be patched with, and the nested quotes. The retired flat shape
-- (price / bidPrice / buyback at the top level) is deliberately absent, so an old-shaped command
-- is named as an unknown field instead of being normalised behind the admin's back: that
-- normalisation belongs to the catalog read boundary alone, where there is no newer shape to
-- confuse it with. Returns nil on success, or the error code plus extra.
local function unknownAddField(raw)
    for name in pairs(raw) do
        local known = name == "id" or name == "item" or name == "prices"
        if not known then
            for _, f in ipairs(Shop.UPDATE_FIELDS) do
                if f == name then known = true; break end
            end
        end
        if not known then return "unknown_field", { field = tostring(name) } end
    end
    if raw.prices ~= nil then
        if type(raw.prices) ~= "table" then return "invalid_args", { field = "prices" } end
        for currency, leaves in pairs(raw.prices) do
            if not L.isCurrency(currency) then
                return "unknown_currency", { field = "prices", currency = tostring(currency) }
            end
            if type(leaves) ~= "table" then
                return "invalid_args", { field = "prices." .. currency, currency = currency }
            end
            for leaf in pairs(leaves) do
                if not isQuoteField(leaf) then
                    return "unknown_field",
                        { field = "prices." .. currency .. "." .. tostring(leaf), currency = currency }
                end
            end
        end
    end
    return nil
end

local function validQuoteField(field, value)
    if field == "price" then return isInt(value, 1, Shop.PRICE_MAX) end
    if field == "bidPrice" then return isInt(value, 0, Shop.PRICE_MAX) end
    if field == "enabled" or field == "buyback" then return type(value) == "boolean" end
    return false
end

-- fields.prices = { [currency] = { leaf = value } } -> the validated per-currency leaf patch.
-- Only the leaves that are there are touched; a currency that is not named is not touched, and
-- a `false` or a `0` is a value like any other. Returns patch, count or nil, error, extra.
local function quotePatchOf(prices)
    if type(prices) ~= "table" then return nil, "invalid_args", { field = "prices" } end
    local patch, currencies = {}, 0
    for currency, leaves in pairs(prices) do
        if not L.isCurrency(currency) then
            return nil, "unknown_currency", { field = "prices", currency = tostring(currency) }
        end
        if type(leaves) ~= "table" then
            return nil, "invalid_args", { field = "prices." .. currency, currency = currency }
        end
        local one, n = {}, 0
        for leaf, value in pairs(leaves) do
            local name = "prices." .. currency .. "." .. tostring(leaf)
            if not isQuoteField(leaf) then
                return nil, "unknown_field", { field = name, currency = currency }
            end
            if not validQuoteField(leaf, value) then
                return nil, "invalid_args", { field = name, currency = currency }
            end
            one[leaf] = value
            n = n + 1
        end
        if n == 0 then return nil, "invalid_args", { field = "prices." .. currency, currency = currency } end
        patch[currency] = one
        currencies = currencies + 1
    end
    if currencies == 0 then return nil, "invalid_args", { field = "prices" } end
    return patch, currencies
end

local function copySku(row)
    local copy = {}
    for k, v in pairs(row) do copy[k] = v end
    local prices = {}
    for currency, q in pairs(row.prices or {}) do
        prices[currency] = { price = q.price, bidPrice = q.bidPrice, enabled = q.enabled, buyback = q.buyback }
    end
    copy.prices = prices
    return copy
end

-- ids = a bounded list of unique existing SKU ids; fields = the patch to apply to every one of
-- them (only the fields the admin actually changed - a field that is not there is not touched on
-- any row). id and item of an existing row are never changed; qty and category are.
--
-- Every row is validated first, then one expectedRevision + on-disk hash check, one write, one
-- read-back, one audit pass and one pushAll: a refused row leaves the file exactly as it was and
-- nothing is audited or pushed. Refused with catalog_stale when the file on disk no longer
-- matches what was loaded (a hand edit the panel would otherwise overwrite) or when
-- expectedRevision is not the loaded one: reload first. Daily usage is never cleared here - a
-- qty change does not hand anyone their cap back, and it does not touch a letter already sent.
-- Returns ok, error, extra. A bad value or a candidate row that no longer parses is the same
-- invalid_args a single edit has always answered, with extra.field / extra.id / extra.currency
-- so the panel can point at the offending column or row (a nested leaf is named
-- "prices.<currency>.<leaf>"); a field the schema does not know is unknown_field and a repeated
-- id is duplicate_id (both are caller bugs, not admin input). A patch that would let someone buy
-- and sell their way to free money is arbitrage_rejected, naming both quotes. On success extra
-- carries { count = SKUs changed, changes = field changes written }.
function Shop.updateMany(ids, fields, actor, reason, expectedRevision)
    if type(ids) ~= "table" or type(fields) ~= "table" then return false, "invalid_args" end
    local n = #ids
    if n < 1 or n > Shop.MAX_SKUS or EC.countKeys(ids) ~= n then return false, "invalid_args" end
    local patch, known = {}, 0
    for _, f in ipairs(Shop.UPDATE_FIELDS) do
        if fields[f] ~= nil then
            if not validField(f, fields[f]) then return false, "invalid_args", { field = f } end
            patch[f] = fields[f]
            known = known + 1
        end
    end
    local quotePatch = nil
    if fields.prices ~= nil then
        local built, err, extra = quotePatchOf(fields.prices)
        if not built then return false, err, extra end
        quotePatch = built
        known = known + 1
    end
    if known ~= EC.countKeys(fields) then
        for k in pairs(fields) do
            if k ~= "prices" and patch[k] == nil then return false, "unknown_field", { field = tostring(k) } end
        end
        return false, "invalid_args"
    end
    if known == 0 then return false, "invalid_args" end
    local rows, seen, changes, touched = {}, {}, {}, 0
    for i = 1, n do
        local id = ids[i]
        if not validId(id) then return false, "invalid_args", { id = tostring(id) } end
        if seen[id] then return false, "duplicate_id", { id = id } end
        seen[id] = true
        local row = file.byId[id]
        if not row then return false, "unknown_sku", { id = id } end
        local patched, dirty = copySku(row), false
        for f, v in pairs(patch) do
            if v ~= row[f] then
                patched[f] = v
                changes[#changes + 1] = { id = id, field = f, before = row[f], after = v }
                dirty = true
            end
        end
        for currency, leaves in pairs(quotePatch or {}) do
            local before = row.prices[currency]
            if not before and leaves.price == nil then
                -- a new quote is created by naming its price; the flags alone would price it at
                -- nothing, and nothing is not a price
                return false, "invalid_args", { id = id, field = "prices." .. currency .. ".price", currency = currency }
            end
            local quote = patched.prices[currency]
            if not quote then
                quote = { price = leaves.price, bidPrice = 0, enabled = true, buyback = false }
                patched.prices[currency] = quote
            end
            for _, leaf in ipairs(Shop.QUOTE_FIELDS) do
                local v = leaves[leaf]
                if v ~= nil then
                    local was = before and before[leaf] or nil
                    if v ~= was then
                        quote[leaf] = v
                        changes[#changes + 1] = { id = id, field = "prices." .. currency .. "." .. leaf,
                            before = was, after = v, currency = currency }
                        dirty = true
                    end
                end
            end
        end
        if dirty then
            -- the whole row must still parse: the file is re-read after the write and a row that
            -- fails there would take the entire catalog down
            local candidate = validateSku(patched, id)
            if not candidate then return false, "invalid_args", { id = id } end
            rows[id] = candidate
            touched = touched + 1
        end
    end
    if #changes == 0 then
        if not currentCatalog(expectedRevision) then return false, "catalog_stale" end
        return true, nil, { count = 0, changes = 0 }
    end
    local items = {}
    for i, current in ipairs(file.items) do items[i] = rows[current.id] or current end
    local conflict = arbitrage(items)
    if conflict then return false, "arbitrage_rejected", conflict end
    local ok, err = commitCatalog(items, expectedRevision)
    if not ok then return false, err end
    for _, c in ipairs(changes) do
        X.emit("admin.catalog", { sku = c.id, field = c.field, before = c.before, after = c.after,
            currency = c.currency, actor = actor, reason = reason })
        X.audit({ action = "catalog", target = c.id, field = c.field, before = c.before, after = c.after,
            currency = c.currency, admin = actor, reason = reason })
    end
    Shop.pushAll()
    return true, nil, { count = touched, changes = #changes }
end

-- One SKU through the same core: there is no second write path.
function Shop.update(id, fields, actor, reason, expectedRevision)
    if type(id) ~= "string" then return false, "invalid_args" end
    return Shop.updateMany({ id }, fields, actor, reason, expectedRevision)
end

-- "survivor:20/8 cat:5/2" - every quoted currency in the audit line of a new row, never just
-- the first one.
local function priceText(sku)
    local parts = {}
    for _, currency in ipairs(EC.CURRENCY_ORDER) do
        local q = sku.prices[currency]
        if q then parts[#parts + 1] = currency .. ":" .. tostring(q.price) .. "/" .. tostring(q.bidPrice) end
    end
    return table.concat(parts, " ")
end

-- raw = { id, item, qty?, category?, dailyCap?, dailyCapScope?, enabled?, buybackCap?,
-- prices = { [currency] = { price, bidPrice?, enabled?, buyback? } } }: one new row appended to
-- the file. The item is whatever the server's own ScriptManager knows (a mod item is as good as
-- a Base one, the client's list is never trusted); a currency is on offer only if the row quotes
-- it. Nothing is audited or pushed unless the file on disk carries the new row. The whole shape
-- is checked before anything else: a field the schema does not know - the retired flat price
-- among them - refuses the row instead of being dropped and committing the rest. Returns ok, err
-- (duplicate_sku, catalog_full, unknown_item, unknown_field, unknown_currency, invalid_args,
-- arbitrage_rejected, catalog_stale, file_write_failed), extra.
function Shop.add(raw, actor, reason, expectedRevision)
    if type(raw) ~= "table" or not validId(raw.id) then return false, "invalid_args" end
    if file.byId[raw.id] then return false, "duplicate_sku" end
    if #file.items >= Shop.MAX_SKUS then return false, "catalog_full" end
    local badField, badExtra = unknownAddField(raw)
    if badField then return false, badField, badExtra end
    local sku = validateSku(raw, raw.id)
    if not sku then
        if not itemExists(raw.item) then return false, "unknown_item" end
        return false, "invalid_args"
    end
    local items = {}
    for i, current in ipairs(file.items) do items[i] = current end
    items[#items + 1] = sku
    local conflict = arbitrage(items)
    if conflict then return false, "arbitrage_rejected", conflict end
    local ok, err = commitCatalog(items, expectedRevision)
    if not ok then return false, err end
    X.emit("admin.catalog", { sku = sku.id, field = "add", after = sku.item, prices = priceText(sku),
        actor = actor, reason = reason })
    X.audit({ action = "catalog", target = sku.id, field = "add",
        after = sku.item .. " x" .. sku.qty .. " @" .. priceText(sku), admin = actor, reason = reason })
    Shop.pushAll()
    return true
end

-- Returns ok, error text, error code, extra. A hand-edited file that would open an arbitrage
-- loop is refused with the same arbitrage_rejected code an admin edit answers with, and the
-- live catalog (revision included) is left exactly as it was.
function Shop.reload(actor)
    local ok, err, code, extra = Shop.load()
    X.emit("admin.catalog", { field = "reload", after = ok and file.count or nil, error = err,
        errorCode = code, actor = actor })
    X.audit({ action = "catalog", target = "file", field = "reload", after = ok and tostring(file.count) or ("error: " .. tostring(err)), admin = actor })
    if ok then Shop.pushAll() end
    return ok, err, code, extra
end

-- ---------- request identity ----------

-- A resend is answered from the ledger's own record of the first attempt. `order` is what this
-- request is - the SKU, the currency, the count, and for a sale the exact batch of items it
-- hands over. Every key of it must match what the first attempt recorded, or the id is being
-- reused for a different order and is refused instead of being answered with the result of the
-- first one (spec contract 12). The reply always names what was recorded, never the resend's guess.
local function priorOrder(requestId, order)
    local prior = L.priorResult(requestId)
    if not prior then return nil end
    local meta = prior.meta or {}
    for key, value in pairs(order) do
        if meta[key] ~= value then
            return { ok = false, error = "request_conflict", currency = meta.currency, sku = meta.sku, count = meta.count }
        end
    end
    return { ok = prior.ok, txId = prior.txId, duplicate = true, error = prior.error,
        currency = meta.currency, total = meta.total, count = meta.count }
end

-- ---------- purchase ----------

-- args = { id, count, currency, revision, acceptMail, requestId }. All-or-nothing; nothing moves
-- unless every check passes. The currency is the player's choice and is never substituted: the
-- SKU must quote it, the quote must be on, and the money moves in exactly that currency. The
-- letter is prepared (built and weighed) before the debit, so the capacity answer is the one
-- that holds at settlement: it does not fit and the client has not confirmed the mailbox ->
-- mail_confirmation_required, zero debit and zero mailbox entry. With acceptMail = true the
-- purchase is parked in the mailbox instead of being pushed into a full backpack, and the
-- prepared objects are handed straight over when it does fit (never built twice).
function Shop.buy(player, args)
    local username = player:getUsername()
    if type(args) ~= "table" or not validId(args.id) or type(args.requestId) ~= "string" or args.requestId == "" or #args.requestId > 96 then
        return { ok = false, error = "invalid_args" }
    end
    if args.acceptMail ~= nil and type(args.acceptMail) ~= "boolean" then return { ok = false, error = "invalid_args" } end
    if type(args.currency) ~= "string" or args.currency == "" then return { ok = false, error = "invalid_args" } end
    local count = args.count == nil and 1 or args.count
    if not isInt(count, 1, Shop.COUNT_MAX) then return { ok = false, error = "invalid_args" } end
    -- the whole namespaced key is what the ledger will store: it is checked here, before any
    -- money or item moves, so a long account name plus a long client id cannot end in a
    -- completed purchase with no idempotency record (report CORE-M2)
    local requestId = "shop:" .. username .. ":" .. args.requestId
    if not L.validRequestKey(requestId) then return { ok = false, error = "request_too_long" } end
    -- the confirmed revision is part of the order: a purchase confirmed against another catalog
    -- is another business intent, not a resend of this one (report CORE-M1)
    local prior = priorOrder(requestId, { sku = args.id, currency = args.currency, count = count,
        revision = args.revision })
    if prior then return prior end
    local sku = Shop.sku(args.id)
    if not sku or not sku.enabled then return { ok = false, error = "unknown_sku" } end
    local currency = args.currency
    local quote, qerr = Shop.quote(sku, currency, "buy")
    if not quote then return { ok = false, error = qerr, currency = currency } end
    if args.revision ~= Shop.revision() then return { ok = false, error = "catalog_changed" } end
    if not T.near(player) then return { ok = false, error = "not_at_terminal" } end
    if L.isFrozen(username) then return { ok = false, error = "account_frozen" } end
    if sku.qty * count > Shop.ITEMS_PER_BUY_MAX then return { ok = false, error = "too_many_items" } end
    local ms = EC.now()
    local day = R.dayKey(ms)
    local used = Shop.used(username, sku.id, ms)
    if sku.dailyCap > 0 and used + count > sku.dailyCap then
        return { ok = false, error = sku.dailyCapScope == "lifetime" and "lifetime_cap" or "daily_cap" }
    end
    if not M.hasFreeSlot(username) then return { ok = false, error = "mailbox_full" } end
    local total = quote.price * count
    if L.getBalance(username, currency).available < total then
        return { ok = false, error = "insufficient_funds", currency = currency, total = total }
    end
    local prepared, perr = M.prepare(player, { item = sku.item, qty = sku.qty * count })
    if not prepared then return { ok = false, error = perr or "item_unavailable" } end
    if not prepared.fits and args.acceptMail ~= true then
        return { ok = false, error = "mail_confirmation_required", willMail = true, item = sku.item,
            qty = prepared.qty, totalWeight = prepared.totalWeight, total = total, currency = currency }
    end
    local res = L.debit(username, currency, total, Shop.BURN_ACCOUNT, {
        kind = "shop_buy", requestId = requestId, reasonCode = "shop_buy",
        idemMeta = { sku = sku.id, currency = currency, count = count, total = total,
            revision = args.revision },
        payload = { sku = sku.id, item = sku.item, qty = sku.qty * count, count = count,
            unitPrice = quote.price, currency = currency },
    })
    if not res.ok then return { ok = false, error = res.error, currency = currency } end
    local lifetimeUsed = noteBuy(day, username, sku.id, count)
    local entry = M.add(username, { kind = "shop", item = sku.item, qty = sku.qty * count, txId = res.txId,
        price = total, currency = currency })
    X.emit("shop.purchase", {
        username = username, sku = sku.id, item = sku.item, qty = sku.qty * count, count = count,
        total = total, currency = currency, txId = res.txId, mailId = entry.id,
        capScope = sku.dailyCapScope, cap = sku.dailyCap, usedAfter = used + count, lifetimeUsed = lifetimeUsed,
    })
    if sku.dailyCap > 0 and sku.dailyCapScope == "global" then
        pushStock(sku.id, math.max(0, sku.dailyCap - used - count), used + count)
    end
    local out = {
        ok = true, txId = res.txId, mailId = entry.id, item = sku.item, qty = sku.qty * count, count = count,
        total = total, currency = currency, unitPrice = quote.price,
        balance = L.getBalance(username, currency).available,
    }
    if prepared.fits then
        -- delivered/deliveryError plus the item counts: a handover that only settled part of
        -- the letter says so in deliveredQty/remainingQty instead of reading as a total loss
        M.deliveryFields(out, M.claim(player, entry.id, prepared), sku.qty * count)
    else
        -- the client asked for the mailbox: park it there instead of a failed handover
        M.deliveryFields(out, nil, sku.qty * count)
        out.mailed = true
    end
    return out
end

-- ---------- buyback (stage G) ----------

-- args = { id, itemIds, currency, revision, requestId }: itemIds are canonical copies of the
-- SKU's item from the top level of the backpack, a whole number of SKU units (qty each). The
-- player is paid the chosen currency's bidPrice per unit; the items are destroyed. Order of
-- checks mirrors Mk.list, then the three phases: pending in the player's own save -> items leave
-- the backpack -> mint (same tick). The currency is fixed into the pending record, so a
-- rollback repays in the very currency the sale was made in.
function Shop.sell(player, args)
    local username = player:getUsername()
    if type(args) ~= "table" or not validId(args.id) or type(args.requestId) ~= "string" or args.requestId == "" or #args.requestId > 96 then
        return { ok = false, error = "invalid_args" }
    end
    if type(args.currency) ~= "string" or args.currency == "" then return { ok = false, error = "invalid_args" } end
    local ids = args.itemIds
    if type(ids) ~= "table" or #ids < 1 or #ids > Shop.ITEMS_PER_BUY_MAX then return { ok = false, error = "invalid_args" } end
    local seen = {}
    for _, id in ipairs(ids) do
        if not isInt(id, -2147483648, 2147483647) or seen[id] then return { ok = false, error = "invalid_args" } end
        seen[id] = true
    end
    -- The recorded result is looked up by what this request immutably is - the SKU, the
    -- currency, the exact items and the catalog revision the player confirmed - before anything
    -- is read from the live catalog at all. The row itself is part of that: an admin who removes
    -- the SKU and reloads between the sale and its resend must not turn a paid operation into
    -- unknown_sku, which would leave the player with no id, no currency and no result to confirm
    -- (report FINAL-LEDGER-2). The count and the amount of the original are answered from the
    -- record, never recomputed.
    local requestId = "sell:" .. username .. ":" .. args.requestId
    if not L.validRequestKey(requestId) then return { ok = false, error = "request_too_long" } end
    local batch = L.batchKey(ids, Shop.ITEMS_PER_BUY_MAX)
    if batch == nil then return { ok = false, error = "invalid_args" } end
    local prior = priorOrder(requestId, { sku = args.id, currency = args.currency, items = batch,
        revision = args.revision })
    if prior then return prior end
    -- a new request: now the live catalog decides whether this row is here and how many shares
    -- this pile is. sku.enabled is the sale switch only: a row taken off the shelf can still be
    -- bought back if its quote says so (spec contract 2).
    local sku = Shop.sku(args.id)
    if not sku then return { ok = false, error = "unknown_sku" } end
    if #ids % sku.qty ~= 0 then return { ok = false, error = "invalid_args" } end
    local count = math.floor(#ids / sku.qty)
    if not Shop.buybackEnabled() then return { ok = false, error = "buyback_disabled" } end
    local currency = args.currency
    local quote, qerr = Shop.quote(sku, currency, "sell")
    if not quote then return { ok = false, error = qerr, currency = currency } end
    if args.revision ~= Shop.revision() then return { ok = false, error = "catalog_changed" } end
    if count > Shop.COUNT_MAX then return { ok = false, error = "too_many_items" } end
    if not T.near(player) then return { ok = false, error = "not_at_terminal" } end
    if L.isFrozen(username) then return { ok = false, error = "account_frozen" } end
    local ms = EC.now()
    local room = Shop.buybackRoom(username, sku.id, ms, currency)
    local total = quote.bidPrice * count
    if room.sku ~= nil and count > room.sku then return { ok = false, error = "buyback_cap_sku", remaining = room.sku } end
    if total > room.account then return { ok = false, error = "buyback_cap_account", remaining = room.account, currency = currency } end
    if total > room.server then return { ok = false, error = "buyback_cap_server", remaining = room.server, currency = currency } end
    if L.getBalance(username, currency).available + total > L.currency(currency).balanceMax then
        return { ok = false, error = "balance_cap", currency = currency }
    end
    local inv = player:getInventory()
    if not inv then return { ok = false, error = "item_not_found" } end
    local Codec = S.Codec
    local items = {}
    for _, id in ipairs(ids) do
        local item = M.findTopLevel(inv, id)
        if not item then return { ok = false, error = "item_not_found" } end
        local pass, reason = Codec.stateCheck(item)
        if not pass then return { ok = false, error = reason } end
        if not Codec.isCanonical(item, sku.item) then return { ok = false, error = "not_canonical" } end
        items[#items + 1] = item
    end

    local id = S.newId()
    local _, seq = EC.parseId(id)
    local snapshot = Codec.snapshot(items[1])
    -- phase 1: the player's own save records the sale and the exact origin of every unit before
    -- anything leaves the backpack. A refusal here destroys nothing and mints nothing. The
    -- ledger key of the mint is recorded with it: that receipt, not the age of the stamp, is
    -- what tells a later login whether this sale was ever paid, and the currency is recorded
    -- with it so the repayment cannot land in another one.
    local rec = { itemId = ids[1], itemIds = ids, qty = #ids, lotQty = #ids, snapshot = snapshot, kind = "buyback",
        sku = sku.id, price = total, unitPrice = quote.bidPrice, unitQty = sku.qty, count = count,
        currency = currency, tradeSchema = L.TRADE_SCHEMA,
        txRequestId = requestId, seq = seq, epoch = md.meta.epoch, at = ms }
    local began, beginErr, beginDetail = M.beginOut(player, id, items, rec)
    if not began then
        return { ok = false, error = beginErr, recovery = M.recoveryStatus(username),
            recoveryDetail = beginDetail }
    end
    -- phase 2: the items are destroyed
    local taken, takeError = M.takeOut(player, id, items)
    if not taken then return { ok = false, error = takeError, recovery = M.recoveryStatus(username) } end
    -- phase 3: the mint (same tick). pending stays until reconcile clears it.
    local res = L.credit(username, currency, total, Shop.MINT_ACCOUNT, {
        kind = "shop_sell", requestId = requestId, reasonCode = "shop_sell",
        idemMeta = { sku = sku.id, currency = currency, count = count, total = total, items = batch,
            revision = args.revision },
        payload = { sku = sku.id, item = sku.item, qty = #ids, count = count, unitPrice = quote.bidPrice,
            currency = currency, buybackId = id },
    })
    if not res.ok then
        -- everything was checked above; only a ledger-level refusal lands here (frozen
        -- mid-tick). The very objects that left the backpack go back into it: nothing is
        -- rebuilt from the snapshot, so a refused mint cannot leave a copy behind.
        local returned = M.abortOut(player, id, items)
        return { ok = false, error = returned and res.error or "recovery_pending", recovery = M.recoveryStatus(username) }
    end
    -- the world side is committed: the transfer receipt consumes those units exactly once
    local recorded, recordError = M.finishOut(username, id, rec, "buyback", res.txId)
    if not recorded then error("buyback receipt invariant: " .. tostring(recordError)) end
    noteBuyback(ms, username, currency, sku.id, total, count)
    X.emit("shop.buyback", { username = username, buybackId = id, sku = sku.id, item = sku.item, qty = #ids, count = count, total = total, currency = currency, txId = res.txId })
    return {
        ok = true, txId = res.txId, item = sku.item, qty = #ids, count = count, total = total, currency = currency,
        unitPrice = quote.bidPrice, balance = L.getBalance(username, currency).available,
    }
end

-- Rule three row 4 for a buyback: the world rolled back below the mint while the player's save
-- already lost the items. Called by Mk.restoreFromPending; returns ok, info (ECMailbox writes
-- the transfer receipt and reads info.txId / info.mailId).
--
-- Only a whole lot is repaid here, and only at the price and in the currency its own record
-- carries: a lot whose units were not all accounted for is handed straight back, because
-- ECMailbox owns the decision of what to do with a part of a lot (it returns the valid
-- remainder) and two places deciding that would pay and return the same unit. A record with no
-- mint receipt key cannot be proved unpaid either, so it is handed back too rather than minted a
-- second time. A record whose currency cannot be proved is held: paying it in a guessed currency
-- would mint money the sale never earned. If the ledger refuses the repayment (balance cap), the
-- goods go back through the mailbox instead.
function Shop.restoreFromPending(username, id, pend)
    -- only the server's own journal record repays a buyback (report CORE-H1)
    local Rec = S.Recovery
    if Rec == nil or type(Rec.isProven) ~= "function" or not Rec.isProven(pend) then
        return false, { reason = "proof_required", kind = "buyback" }
    end
    local qty = tonumber(pend.qty) or 0
    local lotQty = tonumber(pend.lotQty) or qty
    local unitPrice, unitQty = tonumber(pend.unitPrice) or 0, tonumber(pend.unitQty) or 0
    local unresolved = { reason = "buyback_unverified", sku = pend.sku, qty = qty, lotQty = lotQty, snapshot = pend.snapshot }
    if type(pend.txRequestId) ~= "string" or pend.txRequestId == "" then return false, unresolved end
    if qty < 1 or qty < lotQty then
        return false, { reason = "partial_lot", kind = "buyback", sku = pend.sku, item = pend.snapshot and pend.snapshot.type or nil,
            snapshot = pend.snapshot, qty = qty, lotQty = lotQty, unitPrice = unitPrice > 0 and unitPrice or nil,
            unitQty = unitQty > 0 and unitQty or nil, price = tonumber(pend.price) or nil }
    end
    -- the record reaching here is the server's own journal line (guarded above), so its
    -- currency is server evidence; a line that still cannot name one is held, not guessed
    local currency = L.normalizeRecord(pend, L.TRUST_SERVER)
    if currency == nil then
        return false, { reason = "currency_unknown", kind = "buyback", sku = pend.sku, qty = qty,
            lotQty = lotQty, snapshot = pend.snapshot }
    end
    local count = (unitPrice > 0 and unitQty > 0) and math.floor(qty / unitQty) or 0
    local total = count > 0 and unitPrice * count or (tonumber(pend.price) or 0)
    if total < 1 then return false, unresolved end
    local res = L.credit(username, currency, total, Shop.MINT_ACCOUNT, {
        kind = "shop_sell", requestId = "sellrestore:" .. id, reasonCode = "shop_sell_restore",
        payload = { sku = pend.sku, item = pend.snapshot and pend.snapshot.type or nil, qty = qty,
            count = count > 0 and count or nil, unitPrice = unitPrice > 0 and unitPrice or nil,
            currency = currency, buybackId = id },
    })
    if res.ok then
        -- the repaid mint counts against today's caps like any other: the day buckets rolled
        -- back with the world too, so without this the player could sell a full cap on top
        local sku = type(pend.sku) == "string" and file.byId[pend.sku] or nil
        local units = 0
        if sku then units = math.max(1, count > 0 and count or math.floor(qty / sku.qty)) end
        noteBuyback(EC.now(), username, currency, sku and sku.id or nil, total, units)
        X.emit("shop.buyback", { username = username, buybackId = id, sku = pend.sku, qty = qty, count = count > 0 and count or nil,
            total = total, currency = currency, txId = res.txId, restored = true })
        return true, { reason = "buyback_paid", sku = pend.sku, qty = qty, count = count > 0 and count or nil,
            unitPrice = unitPrice > 0 and unitPrice or nil, total = total, currency = currency, txId = res.txId }
    end
    if type(pend.snapshot) ~= "table" then return false, unresolved end
    local entry = M.add(username, { kind = "return", item = pend.snapshot.type, qty = qty, price = total,
        currency = currency, snapshot = pend.snapshot, listingId = id })
    X.emit("shop.buyback", { username = username, buybackId = id, sku = pend.sku, qty = qty, total = total, currency = currency, restored = true, returned = true, mailId = entry.id, error = res.error })
    return true, { reason = "buyback_returned", sku = pend.sku, qty = qty, currency = currency, mailId = entry.id, error = res.error }
end

-- "Did the world keep this buyback's mint?" -> true, false, or nil for "no evidence either way".
-- The mint's own ledger idempotency record is the receipt: it rolled back with the world exactly
-- when the mint did, so it answers the question. A pending written before that key was recorded
-- carries no proof at all, and the age of its epoch/seq stamp is not proof: a stamp that still
-- looks current would call every unpaid sale paid, and a stale one would call every paid sale
-- unpaid. Those are nil, and ECMailbox keeps them held for reconciliation instead of guessing.
-- Called by Mk.hasListing.
function Shop.hasBuyback(pend)
    if type(pend) ~= "table" then return nil end
    if type(pend.txRequestId) ~= "string" or pend.txRequestId == "" then return nil end
    return L.priorResult(pend.txRequestId) ~= nil
end

-- args = { id, currency, requestId? }: what this player could sell for a SKU right now in that
-- currency - the ids of the canonical copies at the top level of the backpack (state-checked
-- too, so the dialog counts only what shop.sell would take), the currency's bid price and the
-- room left today. id, currency and requestId are echoed so a late reply cannot be read as the
-- answer to the currency the player has since switched to.
function Shop.candidates(player, args)
    args = type(args) == "table" and args or {}
    local requested = type(args.currency) == "string" and args.currency or nil
    local sku = Shop.sku(args.id)
    if not sku then
        return { ok = false, error = "unknown_sku", id = type(args.id) == "string" and args.id or nil, currency = requested }
    end
    if requested == nil or requested == "" then return { ok = false, error = "invalid_args", id = sku.id } end
    local quote, qerr = Shop.quote(sku, requested, "sell")
    if not quote then return { ok = false, error = qerr, id = sku.id, currency = requested } end
    local Codec = S.Codec
    -- A read this server could not complete is not "the player owns nothing": an unreadable
    -- backpack, a container walk that threw, or an object whose engine id cannot be read all
    -- answer read_failed, with id / currency echoed so the dialog can retry the same question
    -- (report ER-09). A partial list is never dressed up as a complete one.
    local inv = player:getInventory()
    if not inv then
        EC.log("shop candidates: no inventory for " .. tostring(player:getUsername()))
        return { ok = false, error = "read_failed", id = sku.id, currency = requested }
    end
    local ids = {}
    local read = pcall(function()
        local items = inv:getItems()
        if items == nil then error("getItems gave no container") end
        for i = 0, items:size() - 1 do
            local item = items:get(i)
            if item == nil then error("container row " .. tostring(i) .. " is not readable") end
            if #ids < Shop.ITEMS_PER_BUY_MAX and Codec.stateCheck(item) and Codec.isCanonical(item, sku.item) then
                local itemId = item:getID()
                if itemId == nil then error("an item id is not readable") end
                ids[#ids + 1] = itemId
            end
        end
    end)
    if not read then
        EC.log("shop candidates inventory read failed for " .. tostring(player:getUsername()))
        return { ok = false, error = "read_failed", id = sku.id, currency = requested }
    end
    local ms = EC.now()
    local room = Shop.buybackRoom(player:getUsername(), sku.id, ms, requested)
    return {
        ok = true, id = sku.id, currency = requested, item = sku.item, itemIds = ids, count = #ids,
        unitQty = sku.qty, bidPrice = quote.bidPrice, revision = Shop.revision(),
        enabled = Shop.buybackEnabled(), accountRemaining = room.account, serverRemaining = room.server,
        buyback = Shop.buybackView(player:getUsername(), ms, sku.id),
    }
end

-- ---------- commands ----------

S.handlers["shop.list"] = function(player, args)
    local snap = Shop.snapshot(player:getUsername(), EC.now())
    snap.atTerminal = T.near(player)
    snap.unclaimed = M.unclaimed(player:getUsername())
    snap.requestId = type(args.requestId) == "string" and #args.requestId <= 96 and args.requestId or nil
    S.reply(player, "shop.list", snap)
end

S.handlers["shop.buy"] = function(player, args)
    local res = Shop.buy(player, args)
    res.requestId = type(args) == "table" and args.requestId or nil
    res.revision = Shop.revision()
    res.remaining = nil
    if type(args) == "table" and validId(args.id) then
        local sku = Shop.sku(args.id)
        if sku then
            res.used = Shop.used(player:getUsername(), sku.id, EC.now())
            if sku.dailyCap > 0 then res.remaining = math.max(0, sku.dailyCap - res.used) end
        end
    end
    res.unclaimed = M.unclaimed(player:getUsername())
    S.reply(player, "shop.buy", res)
end

S.handlers["shop.candidates"] = function(player, args)
    local res = Shop.candidates(player, args)
    res.requestId = type(args) == "table" and type(args.requestId) == "string" and #args.requestId <= 96 and args.requestId or nil
    S.reply(player, "shop.candidates", res)
end

S.handlers["shop.sell"] = function(player, args)
    local res = Shop.sell(player, args)
    res.requestId = type(args) == "table" and args.requestId or nil
    res.revision = Shop.revision()
    local id = type(args) == "table" and validId(args.id) and args.id or nil
    res.buyback = Shop.buybackView(player:getUsername(), EC.now(), id)
    S.reply(player, "shop.sell", res)
end

function Shop.init(root)
    md = root
    md.shopDaily = md.shopDaily or {}
    -- No history backfill: old day buckets are incomplete and event files may include rollbacks.
    md.shopLifetime = md.shopLifetime or {}
    md.shopBuyback = md.shopBuyback or {}
    totals.day, totals.byId = nil, nil
    local ok, err = Shop.load()
    EC.log("catalog: " .. (ok and (file.count .. " items") or ("error " .. tostring(err))))
end

S.Shop = Shop
S.onInit(Shop.init)
return Shop
