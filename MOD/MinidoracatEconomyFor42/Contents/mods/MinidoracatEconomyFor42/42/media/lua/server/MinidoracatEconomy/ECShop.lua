-- MinidoracatEconomyFor42 - system shop: sell side (spec 12 stage C) and buyback (stage G).
--
-- The catalog is a server-owned file, {cachedir}/Lua/MinidoracatEconomy/catalog.json (one JSON
-- document: {"items":[{"id","item","qty","price","dailyCap","category","enabled","bidPrice",
-- "buyback","buybackCap"}]}), read at start and on admin.catalog{action="reload"}; a broken file
-- keeps the previous catalog and the error is shown in the panel. The admin page edits the
-- per-SKU numbers and flags and those edits are written straight back into the file (the file is
-- the single source of truth, it never rolls back with the world save; a hand edit made since the
-- last load is detected by hash and refused until the admin reloads). Every change is pushed to
-- everyone online. Players see the catalog under a revision string (the file hash); shop.buy and
-- shop.sell carry that revision and are refused when the catalog changed underneath (no silent
-- repricing).
--
-- A purchase burns the market currency (player -> SYSTEM_BURN), counts against the per-account
-- daily cap (reward day, ECRewards.dayKey) and puts a mailbox entry in the same tick (rule one);
-- the immediate claim-in then moves the items into the backpack when they fit.
--
-- Buyback is the faucet: the player hands over canonical copies of a SKU (Codec.isCanonical) and
-- the server mints bidPrice per unit (SYSTEM_MINT -> player), destroying the items in the same
-- tick through the market's three-phase list-out (pendingOuts kind "buyback": a crash between the
-- removal and the credit is repaired by ECMailbox.reconcileOuts, rows 4-6). Three gross mint caps
-- per reward day, none reopened by burns: per SKU (units, catalog buybackCap), per account and
-- server-wide (coins, sandbox); the sandbox ShopBuybackEnabled switch closes the faucet at once.
-- ECCodec and ECMarket load after this file (they require it), so they are reached through S at
-- call time.

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

-- Written when the file is missing so the host sees the shape. Prices are in the market currency
-- (daily check-in pays 30 by default); the host is expected to edit this.
Shop.DEFAULT_ITEMS = {
    { id = "bandage", item = "Base.Bandage", qty = 1, price = 12, dailyCap = 5, category = "medical" },
    { id = "antibiotics", item = "Base.Antibiotics", qty = 1, price = 60, dailyCap = 2, category = "medical" },
    { id = "ripped_sheets", item = "Base.RippedSheets", qty = 5, price = 10, dailyCap = 5, category = "medical" },
    { id = "canned_corn", item = "Base.CannedCorn", qty = 2, price = 20, dailyCap = 5, category = "food" },
    { id = "nails", item = "Base.Nails", qty = 20, price = 25, dailyCap = 5, category = "material" },
    { id = "screws", item = "Base.Screws", qty = 20, price = 25, dailyCap = 5, category = "material" },
    { id = "plank", item = "Base.Plank", qty = 5, price = 30, dailyCap = 5, category = "material" },
    { id = "rope", item = "Base.Rope", qty = 2, price = 24, dailyCap = 5, category = "material" },
    { id = "twine", item = "Base.Twine", qty = 1, price = 12, dailyCap = 5, category = "material" },
    { id = "lighter", item = "Base.Lighter", qty = 1, price = 15, dailyCap = 2, category = "tool" },
    { id = "hammer", item = "Base.Hammer", qty = 1, price = 80, dailyCap = 1, category = "tool" },
    { id = "saw", item = "Base.Saw", qty = 1, price = 90, dailyCap = 1, category = "tool" },
    { id = "axe", item = "Base.Axe", qty = 1, price = 150, dailyCap = 1, category = "tool" },
}

local md = nil
local file = { items = {}, byId = {}, count = 0, loadedAt = 0, error = nil, hash = "0" }

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

-- One raw catalog row -> normalised sku or nil, error text (for the panel).
local function validateSku(raw, index)
    local where = "item " .. tostring(index)
    if type(raw) ~= "table" then return nil, where .. ": not an object" end
    if not validId(raw.id) then return nil, where .. ": bad id" end
    where = raw.id
    if not itemExists(raw.item) then return nil, where .. ": unknown item " .. tostring(raw.item) end
    local qty = raw.qty == nil and 1 or raw.qty
    if not isInt(qty, 1, Shop.QTY_MAX) then return nil, where .. ": qty must be 1-" .. Shop.QTY_MAX end
    if not isInt(raw.price, 1, Shop.PRICE_MAX) then return nil, where .. ": price must be 1-" .. Shop.PRICE_MAX end
    local cap = raw.dailyCap == nil and 0 or raw.dailyCap
    if not isInt(cap, 0, Shop.CAP_MAX) then return nil, where .. ": dailyCap must be 0-" .. Shop.CAP_MAX end
    local category = raw.category == nil and "other" or raw.category
    if type(category) ~= "string" or category == "" or #category > Shop.CATEGORY_MAX or string.find(category, "%c") then
        return nil, where .. ": bad category"
    end
    if raw.enabled ~= nil and type(raw.enabled) ~= "boolean" then return nil, where .. ": enabled must be true/false" end
    -- buyback: 0 <= bidPrice < price; the flag (not a zero price) says whether the system buys
    local bid = raw.bidPrice == nil and 0 or raw.bidPrice
    if not isInt(bid, 0, raw.price - 1) then return nil, where .. ": bidPrice must be 0-" .. (raw.price - 1) end
    if raw.buyback ~= nil and type(raw.buyback) ~= "boolean" then return nil, where .. ": buyback must be true/false" end
    if raw.buyback == true and bid < 1 then return nil, where .. ": buyback needs a bidPrice of at least 1" end
    local bcap = raw.buybackCap == nil and 0 or raw.buybackCap
    if not isInt(bcap, 0, Shop.CAP_MAX) then return nil, where .. ": buybackCap must be 0-" .. Shop.CAP_MAX end
    return {
        id = raw.id, item = raw.item, qty = qty, price = raw.price, dailyCap = cap, category = category, enabled = raw.enabled ~= false,
        bidPrice = bid, buyback = raw.buyback == true, buybackCap = bcap,
    }
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
    return { items = items, byId = byId }
end

-- ---------- file ----------

local function readFile()
    local reader = nil
    local ok = pcall(function() reader = getFileReader(Shop.FILE, false) end)
    if not ok or not reader then return nil end
    local lines = {}
    pcall(function()
        for _ = 1, Shop.FILE_LINES_MAX do
            local line = reader:readLine()
            if line == nil then break end
            lines[#lines + 1] = line
        end
    end)
    pcall(function() reader:close() end)
    return table.concat(lines, "\n")
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
            writer:writeln("    " .. EC.jsonEncode({
                id = row.id, item = row.item, qty = row.qty, price = row.price, dailyCap = row.dailyCap, category = row.category, enabled = row.enabled ~= false,
                bidPrice = row.bidPrice or 0, buyback = row.buyback == true, buybackCap = row.buybackCap or 0,
            })
                .. (i < #rows and "," or ""))
        end
        writer:writeln("  ]")
        writer:writeln("}")
    end)
    pcall(function() writer:close() end)
    return wrote
end

local function hashOf(text)
    return EC.hashHex(EC.hashUpdate(EC.hashInit(), text))
end

-- Loads the file; on the first run writes the default catalog first. A bad file keeps the
-- previous catalog and records the error. Returns ok, error.
function Shop.load()
    local text = readFile()
    if text == nil then
        if not writeCatalog(Shop.DEFAULT_ITEMS) then
            file.error = "catalog file unavailable"
            return false, file.error
        end
        text = readFile() or ""
    end
    local parsed, err = parseCatalog(text)
    if not parsed then
        file.error = err
        EC.log("catalog.json rejected: " .. tostring(err))
        return false, err
    end
    file.items, file.byId, file.count = parsed.items, parsed.byId, #parsed.items
    file.loadedAt = EC.now()
    file.error = nil
    file.hash = hashOf(text)
    return true
end

function Shop.fileStatus()
    return { count = file.count, loadedAt = file.loadedAt, error = file.error, path = Shop.FILE }
end

-- ---------- catalog view ----------

function Shop.revision()
    return file.hash
end

function Shop.sku(id)
    local base = type(id) == "string" and file.byId[id] or nil
    if not base then return nil end
    return {
        id = base.id, item = base.item, qty = base.qty, category = base.category, price = base.price, dailyCap = base.dailyCap, enabled = base.enabled,
        bidPrice = base.bidPrice, buyback = base.buyback, buybackCap = base.buybackCap,
    }
end

-- The one currency the shop trades in (exactly one registry entry has marketUnit, spec 18.1).
local function marketCurrency()
    for id, c in pairs(EC.CURRENCIES) do if c.marketUnit then return id end end
    return R.CURRENCY
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

function Shop.boughtToday(username, id, ms)
    local row = dailyRow(R.dayKey(ms), username, false)
    return row and row[id] or 0
end

-- Gross mint per reward day: { total = coins, accounts = { [username] = coins }, skus = { [id] = units } }.
local function buybackDay(ms, create)
    local t = dayTable(md.shopBuyback, R.dayKey(ms), create)
    if t and not t.accounts then t.total, t.accounts, t.skus = 0, {}, {} end
    return t
end

function Shop.buybackEnabled()
    return EC.sandbox("ShopBuybackEnabled", false) == true
end

-- Remaining room today for one more sale: coins for the account and the server, units for the SKU.
function Shop.buybackRoom(username, id, ms)
    local t = buybackDay(ms, false)
    local sku = file.byId[id]
    return {
        account = math.max(0, EC.sandbox("ShopBuybackPerAccountDaily", 500) - (t and t.accounts[username] or 0)),
        server = math.max(0, EC.sandbox("ShopBuybackServerDaily", 20000) - (t and t.total or 0)),
        sku = (sku and sku.buybackCap > 0) and math.max(0, sku.buybackCap - (t and t.skus[id] or 0)) or nil,
    }
end

function Shop.buybackStatus(ms)
    ms = ms or EC.now()
    local t = buybackDay(ms, false)
    return {
        enabled = Shop.buybackEnabled(), mintedToday = t and t.total or 0,
        serverCap = EC.sandbox("ShopBuybackServerDaily", 20000), accountCap = EC.sandbox("ShopBuybackPerAccountDaily", 500),
    }
end

-- The client list: every SKU (disabled ones too, for admins) with this player's remaining caps.
function Shop.snapshot(username, ms)
    ms = ms or EC.now()
    local items = {}
    local buyback = Shop.buybackEnabled()
    local room = nil
    for _, base in ipairs(file.items) do
        local sku = Shop.sku(base.id)
        if sku.dailyCap > 0 then
            sku.remaining = math.max(0, sku.dailyCap - Shop.boughtToday(username, sku.id, ms))
        end
        if sku.buyback and sku.buybackCap > 0 then
            room = room or Shop.buybackRoom(username, sku.id, ms)
            sku.buybackRemaining = Shop.buybackRoom(username, sku.id, ms).sku
        end
        items[#items + 1] = sku
    end
    EC.sortSafe(items, function(a, b)
        if a.category ~= b.category then return a.category < b.category end
        return a.id < b.id
    end)
    room = room or Shop.buybackRoom(username, nil, ms)
    return {
        revision = Shop.revision(), currency = marketCurrency(), items = items, count = #items,
        file = Shop.fileStatus(), dayEndsMs = R.nextResetMs(ms), countMax = Shop.COUNT_MAX,
        buyback = { enabled = buyback, accountRemaining = room.account, serverRemaining = room.server },
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

-- fields = { price?, dailyCap?, enabled? } ; the SKU row is changed in the file. Returns ok, err.
-- Refused with catalog_stale when the file on disk no longer matches what was loaded (a hand
-- edit the panel would otherwise overwrite): reload first.
function Shop.update(id, fields, actor, reason)
    local row = file.byId[id]
    if not row then return false, "unknown_sku" end
    if type(fields) ~= "table" then return false, "invalid_args" end
    local next = {}
    for k, v in pairs(row) do next[k] = v end
    local changes = {}
    for _, f in ipairs({ "price", "dailyCap", "enabled", "bidPrice", "buyback", "buybackCap" }) do
        if fields[f] ~= nil and fields[f] ~= row[f] then
            next[f] = fields[f]
            changes[#changes + 1] = { f, row[f], fields[f] }
        end
    end
    if #changes == 0 then return true end
    -- the whole row must still parse: the file is re-read after the write and a row that fails
    -- there would take the entire catalog down
    if not validateSku(next, id) then return false, "invalid_args" end
    local onDisk = readFile()
    if onDisk == nil or hashOf(onDisk) ~= file.hash then return false, "catalog_stale" end
    local changed = changes
    for _, c in ipairs(changed) do row[c[1]] = c[3] end
    if not writeCatalog(file.items) then
        for _, c in ipairs(changed) do row[c[1]] = c[2] end
        return false, "file_write_failed"
    end
    local ok, err = Shop.load()   -- re-read what was written: hash, count and a sanity parse
    if not ok then
        EC.log("catalog.json unreadable after the panel wrote it: " .. tostring(err))
        return false, "file_write_failed"
    end
    for _, c in ipairs(changed) do
        X.emit("admin.catalog", { sku = id, field = c[1], before = c[2], after = c[3], actor = actor, reason = reason })
        X.audit({ action = "catalog", target = id, field = c[1], before = c[2], after = c[3], admin = actor, reason = reason })
    end
    Shop.pushAll()
    return true
end

function Shop.reload(actor)
    local ok, err = Shop.load()
    X.emit("admin.catalog", { field = "reload", after = ok and file.count or nil, error = err, actor = actor })
    X.audit({ action = "catalog", target = "file", field = "reload", after = ok and tostring(file.count) or ("error: " .. tostring(err)), admin = actor })
    if ok then Shop.pushAll() end
    return ok, err
end

-- ---------- purchase ----------

-- args = { id, count, revision, requestId }. All-or-nothing; nothing moves unless every check
-- passes, and the ledger debit is the last thing that can fail.
function Shop.buy(player, args)
    local username = player:getUsername()
    if type(args) ~= "table" or not validId(args.id) or type(args.requestId) ~= "string" or args.requestId == "" or #args.requestId > 96 then
        return { ok = false, error = "invalid_args" }
    end
    local prior = L.priorResult("shop:" .. username .. ":" .. args.requestId)
    if prior then
        return { ok = prior.ok, txId = prior.txId, duplicate = true, error = prior.error }
    end
    local count = args.count == nil and 1 or args.count
    if not isInt(count, 1, Shop.COUNT_MAX) then return { ok = false, error = "invalid_args" } end
    local sku = Shop.sku(args.id)
    if not sku or not sku.enabled then return { ok = false, error = "unknown_sku" } end
    if args.revision ~= Shop.revision() then return { ok = false, error = "catalog_changed" } end
    if not T.near(player) then return { ok = false, error = "not_at_terminal" } end
    if L.isFrozen(username) then return { ok = false, error = "account_frozen" } end
    if sku.qty * count > Shop.ITEMS_PER_BUY_MAX then return { ok = false, error = "too_many_items" } end
    local ms = EC.now()
    local day = R.dayKey(ms)
    if sku.dailyCap > 0 and Shop.boughtToday(username, sku.id, ms) + count > sku.dailyCap then
        return { ok = false, error = "daily_cap" }
    end
    if not M.hasFreeSlot(username) then return { ok = false, error = "mailbox_full" } end
    local total = sku.price * count
    local currency = marketCurrency()
    if L.getBalance(username, currency).available < total then return { ok = false, error = "insufficient_funds" } end
    local res = L.debit(username, currency, total, Shop.BURN_ACCOUNT, {
        kind = "shop_buy", requestId = "shop:" .. username .. ":" .. args.requestId, reasonCode = "shop_buy",
        payload = { sku = sku.id, item = sku.item, qty = sku.qty * count, count = count, unitPrice = sku.price },
    })
    if not res.ok then return { ok = false, error = res.error } end
    local row = dailyRow(day, username, true)
    row[sku.id] = (row[sku.id] or 0) + count
    local entry = M.add(username, { kind = "shop", item = sku.item, qty = sku.qty * count, txId = res.txId, price = total })
    X.emit("shop.purchase", { username = username, sku = sku.id, item = sku.item, qty = sku.qty * count, count = count, total = total, currency = currency, txId = res.txId, mailId = entry.id })
    local claim = M.claim(player, entry.id)
    return {
        ok = true, txId = res.txId, mailId = entry.id, item = sku.item, qty = sku.qty * count, total = total, currency = currency,
        delivered = claim.ok == true, deliveryError = (not claim.ok) and claim.error or nil,
        balance = L.getBalance(username, currency).available,
    }
end

-- ---------- buyback (stage G) ----------

local function findTopLevel(inv, itemId)
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

-- args = { id, itemIds, revision, requestId }: itemIds are canonical copies of the SKU's item from
-- the top level of the backpack, a whole number of SKU units (qty each). The player is paid
-- bidPrice per unit; the items are destroyed. Order of checks mirrors Mk.list, then the three
-- phases: pending in the player's own save -> items leave the backpack -> mint (same tick).
function Shop.sell(player, args)
    local username = player:getUsername()
    if type(args) ~= "table" or not validId(args.id) or type(args.requestId) ~= "string" or args.requestId == "" or #args.requestId > 96 then
        return { ok = false, error = "invalid_args" }
    end
    local ids = args.itemIds
    if type(ids) ~= "table" or #ids < 1 or #ids > Shop.ITEMS_PER_BUY_MAX then return { ok = false, error = "invalid_args" } end
    local seen = {}
    for _, id in ipairs(ids) do
        if not isInt(id, -2147483648, 2147483647) or seen[id] then return { ok = false, error = "invalid_args" } end
        seen[id] = true
    end
    local prior = L.priorResult("sell:" .. username .. ":" .. args.requestId)
    if prior then return { ok = prior.ok, txId = prior.txId, duplicate = true, error = prior.error } end
    if not Shop.buybackEnabled() then return { ok = false, error = "buyback_disabled" } end
    local sku = Shop.sku(args.id)
    if not sku or not sku.enabled or not sku.buyback then return { ok = false, error = "unknown_sku" } end
    if args.revision ~= Shop.revision() then return { ok = false, error = "catalog_changed" } end
    if #ids % sku.qty ~= 0 then return { ok = false, error = "invalid_args" } end
    local count = math.floor(#ids / sku.qty)
    if count > Shop.COUNT_MAX then return { ok = false, error = "too_many_items" } end
    if not T.near(player) then return { ok = false, error = "not_at_terminal" } end
    if L.isFrozen(username) then return { ok = false, error = "account_frozen" } end
    local ms = EC.now()
    local room = Shop.buybackRoom(username, sku.id, ms)
    local total = sku.bidPrice * count
    if room.sku ~= nil and count > room.sku then return { ok = false, error = "buyback_cap_sku", remaining = room.sku } end
    if total > room.account then return { ok = false, error = "buyback_cap_account", remaining = room.account } end
    if total > room.server then return { ok = false, error = "buyback_cap_server", remaining = room.server } end
    local currency = marketCurrency()
    if L.getBalance(username, currency).available + total > L.currency(currency).balanceMax then return { ok = false, error = "balance_cap" } end
    local inv = player:getInventory()
    if not inv then return { ok = false, error = "item_not_found" } end
    local Codec = S.Codec
    local items = {}
    for _, id in ipairs(ids) do
        local item = findTopLevel(inv, id)
        if not item then return { ok = false, error = "item_not_found" } end
        local pass, reason = Codec.stateCheck(item)
        if not pass then return { ok = false, error = reason } end
        if not Codec.isCanonical(item, sku.item) then return { ok = false, error = "not_canonical" } end
        items[#items + 1] = item
    end

    local Mk = S.Market
    local id = S.newId()
    local _, seq = EC.parseId(id)
    local p = player:getModData()[EC.PLAYER_MODDATA_KEY]
    if type(p) ~= "table" then
        p = {}
        player:getModData()[EC.PLAYER_MODDATA_KEY] = p
    end
    if type(p.pendingOuts) ~= "table" then p.pendingOuts = {} end
    local snapshot = Codec.snapshot(items[1])
    -- phase 1: the player's own save remembers the sale before the items leave the backpack
    Mk.addPending(p, id, { itemId = ids[1], itemIds = ids, qty = #ids, snapshot = snapshot, kind = "buyback", sku = sku.id, price = total, seq = seq, epoch = md.meta.epoch, at = ms })
    pcall(function() player:transmitModData() end)
    -- phase 2: the items are destroyed
    for _, item in ipairs(items) do
        inv:Remove(item)
        sendRemoveItemFromContainer(inv, item)
    end
    -- phase 3: the mint (same tick). pending stays until reconcile clears it.
    local res = L.credit(username, currency, total, Shop.MINT_ACCOUNT, {
        kind = "shop_sell", requestId = "sell:" .. username .. ":" .. args.requestId, reasonCode = "shop_sell",
        payload = { sku = sku.id, item = sku.item, qty = #ids, count = count, unitPrice = sku.bidPrice, buybackId = id },
    })
    if not res.ok then
        -- everything was checked above; only a ledger-level refusal lands here (frozen mid-tick)
        for _ = 1, #ids do
            local back = Codec.rebuild(snapshot)
            if back then inv:AddItem(back) sendAddItemToContainer(inv, back) end
        end
        p.pendingOuts[id] = nil
        pcall(function() player:transmitModData() end)
        return { ok = false, error = res.error }
    end
    local day = buybackDay(ms, true)
    day.total = day.total + total
    day.accounts[username] = (day.accounts[username] or 0) + total
    day.skus[sku.id] = (day.skus[sku.id] or 0) + count
    X.emit("shop.buyback", { username = username, buybackId = id, sku = sku.id, item = sku.item, qty = #ids, count = count, total = total, currency = currency, txId = res.txId })
    return {
        ok = true, txId = res.txId, item = sku.item, qty = #ids, count = count, total = total, currency = currency,
        balance = L.getBalance(username, currency).available,
    }
end

-- Rule three row 4 for a buyback: the world rolled back below the mint while the player's save
-- already lost the items. Pay again; if the ledger refuses (balance cap), give the items back
-- through the mailbox instead (a system return, never blocked). Called by Mk.restoreFromPending.
function Shop.restoreFromPending(username, id, pend)
    local total, qty = tonumber(pend.price) or 0, tonumber(pend.qty) or 0
    if total < 1 or qty < 1 then return false end
    local currency = marketCurrency()
    local res = L.credit(username, currency, total, Shop.MINT_ACCOUNT, {
        kind = "shop_sell", requestId = "sellrestore:" .. id, reasonCode = "shop_sell_restore",
        payload = { sku = pend.sku, item = pend.snapshot and pend.snapshot.type or nil, qty = qty, buybackId = id },
    })
    if res.ok then
        X.emit("shop.buyback", { username = username, buybackId = id, sku = pend.sku, qty = qty, total = total, currency = currency, txId = res.txId, restored = true })
        return true
    end
    if type(pend.snapshot) ~= "table" then return false end
    local entry = M.add(username, { kind = "return", item = pend.snapshot.type, qty = qty, price = total, snapshot = pend.snapshot, listingId = id })
    X.emit("shop.buyback", { username = username, buybackId = id, sku = pend.sku, qty = qty, total = total, currency = currency, restored = true, returned = true, mailId = entry.id, error = res.error })
    return true
end

-- What this player could sell for a SKU right now: the ids of the canonical copies at the top
-- level of the backpack (state-checked too, so the dialog counts only what shop.sell would take).
function Shop.candidates(player, id)
    local sku = Shop.sku(id)
    if not sku or not sku.buyback then return { ok = false, error = "unknown_sku" } end
    local Codec = S.Codec
    local ids = {}
    local inv = player:getInventory()
    local ok, items = pcall(function() return inv:getItems() end)
    if ok and items then
        for i = 0, items:size() - 1 do
            local item = items:get(i)
            if #ids < Shop.ITEMS_PER_BUY_MAX and Codec.stateCheck(item) and Codec.isCanonical(item, sku.item) then
                local itemId = nil
                pcall(function() itemId = item:getID() end)
                if itemId ~= nil then ids[#ids + 1] = itemId end
            end
        end
    end
    local room = Shop.buybackRoom(player:getUsername(), sku.id, EC.now())
    return {
        ok = true, id = sku.id, item = sku.item, itemIds = ids, count = #ids, unitQty = sku.qty, bidPrice = sku.bidPrice,
        revision = Shop.revision(), enabled = Shop.buybackEnabled(),
        buyback = { enabled = Shop.buybackEnabled(), accountRemaining = room.account, serverRemaining = room.server, skuRemaining = room.sku },
    }
end

-- ---------- commands ----------

S.handlers["shop.list"] = function(player, args)
    local snap = Shop.snapshot(player:getUsername(), EC.now())
    snap.atTerminal = T.near(player)
    snap.unclaimed = M.unclaimed(player:getUsername())
    S.reply(player, "shop.list", snap)
end

S.handlers["shop.buy"] = function(player, args)
    local res = Shop.buy(player, args)
    res.requestId = type(args) == "table" and args.requestId or nil
    res.revision = Shop.revision()
    res.remaining = nil
    if type(args) == "table" and validId(args.id) then
        local sku = Shop.sku(args.id)
        if sku and sku.dailyCap > 0 then res.remaining = math.max(0, sku.dailyCap - Shop.boughtToday(player:getUsername(), sku.id, EC.now())) end
    end
    res.unclaimed = M.unclaimed(player:getUsername())
    S.reply(player, "shop.buy", res)
end

S.handlers["shop.candidates"] = function(player, args)
    local res = Shop.candidates(player, type(args) == "table" and args.id or nil)
    res.requestId = type(args) == "table" and args.requestId or nil
    S.reply(player, "shop.candidates", res)
end

S.handlers["shop.sell"] = function(player, args)
    local res = Shop.sell(player, args)
    res.requestId = type(args) == "table" and args.requestId or nil
    res.revision = Shop.revision()
    local room = Shop.buybackRoom(player:getUsername(), type(args) == "table" and validId(args.id) and args.id or nil, EC.now())
    res.buyback = { enabled = Shop.buybackEnabled(), accountRemaining = room.account, serverRemaining = room.server, skuRemaining = room.sku }
    S.reply(player, "shop.sell", res)
end

function Shop.init(root)
    md = root
    md.shopDaily = md.shopDaily or {}
    md.shopBuyback = md.shopBuyback or {}
    local ok, err = Shop.load()
    EC.log("catalog: " .. (ok and (file.count .. " items") or ("error " .. tostring(err))))
end

S.Shop = Shop
S.onInit(Shop.init)
return Shop
