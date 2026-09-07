-- MinidoracatEconomyFor42 - system shop, sell side only (server authority; spec 12 stage C).
--
-- The catalog is a server-owned file, {cachedir}/Lua/MinidoracatEconomy/catalog.json (one JSON
-- document: {"items":[{"id","item","qty","price","dailyCap","category","enabled"}]}), read at
-- start and on admin.catalog{action="reload"}; a broken file keeps the previous catalog and the
-- error is shown in the panel. The admin page edits enabled / price / dailyCap per SKU and those
-- edits are written straight back into the file (the file is the single source of truth, it never
-- rolls back with the world save; a hand edit made since the last load is detected by hash and
-- refused until the admin reloads). Every change is pushed to everyone online. Players see the
-- catalog under a revision string (the file hash); shop.buy carries that revision and is refused
-- when the catalog changed underneath (no silent repricing).
--
-- A purchase burns the market currency (player -> SYSTEM_BURN), counts against the per-account
-- daily cap (reward day, ECRewards.dayKey) and puts a mailbox entry in the same tick (rule one);
-- the immediate claim-in then moves the items into the backpack when they fit.

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
    return { id = raw.id, item = raw.item, qty = qty, price = raw.price, dailyCap = cap, category = category, enabled = raw.enabled ~= false }
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
            writer:writeln("    " .. EC.jsonEncode({ id = row.id, item = row.item, qty = row.qty, price = row.price, dailyCap = row.dailyCap, category = row.category, enabled = row.enabled ~= false })
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
    return { id = base.id, item = base.item, qty = base.qty, category = base.category, price = base.price, dailyCap = base.dailyCap, enabled = base.enabled }
end

-- The one currency the shop trades in (exactly one registry entry has marketUnit, spec 18.1).
local function marketCurrency()
    for id, c in pairs(EC.CURRENCIES) do if c.marketUnit then return id end end
    return R.CURRENCY
end

local function dailyRow(day, username, create)
    local byDay = md.shopDaily[day]
    if not byDay then
        if not create then return nil end
        byDay = {}
        md.shopDaily[day] = byDay
        local oldest = R.dayKey(EC.now() - Shop.DAILY_KEEP_DAYS * 86400000)
        local stale = {}
        for k in pairs(md.shopDaily) do if k < oldest then stale[#stale + 1] = k end end
        for _, k in ipairs(stale) do md.shopDaily[k] = nil end
    end
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

-- The client list: every SKU (disabled ones too, for admins) with this player's remaining cap.
function Shop.snapshot(username, ms)
    ms = ms or EC.now()
    local items = {}
    for _, base in ipairs(file.items) do
        local sku = Shop.sku(base.id)
        if sku.dailyCap > 0 then
            sku.remaining = math.max(0, sku.dailyCap - Shop.boughtToday(username, sku.id, ms))
        end
        items[#items + 1] = sku
    end
    EC.sortSafe(items, function(a, b)
        if a.category ~= b.category then return a.category < b.category end
        return a.id < b.id
    end)
    return {
        revision = Shop.revision(), currency = marketCurrency(), items = items, count = #items,
        file = Shop.fileStatus(), dayEndsMs = R.nextResetMs(ms), countMax = Shop.COUNT_MAX,
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
    local changes = {}
    if fields.price ~= nil then
        if not isInt(fields.price, 1, Shop.PRICE_MAX) then return false, "invalid_args" end
        changes[#changes + 1] = { "price", row.price, fields.price }
    end
    if fields.dailyCap ~= nil then
        if not isInt(fields.dailyCap, 0, Shop.CAP_MAX) then return false, "invalid_args" end
        changes[#changes + 1] = { "dailyCap", row.dailyCap, fields.dailyCap }
    end
    if fields.enabled ~= nil then
        if type(fields.enabled) ~= "boolean" then return false, "invalid_args" end
        changes[#changes + 1] = { "enabled", row.enabled, fields.enabled }
    end
    local changed = {}
    for _, c in ipairs(changes) do
        if c[2] ~= c[3] then changed[#changed + 1] = c end
    end
    if #changed == 0 then return true end
    local onDisk = readFile()
    if onDisk == nil or hashOf(onDisk) ~= file.hash then return false, "catalog_stale" end
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

function Shop.init(root)
    md = root
    md.shopDaily = md.shopDaily or {}
    local ok, err = Shop.load()
    EC.log("catalog: " .. (ok and (file.count .. " items") or ("error " .. tostring(err))))
end

S.Shop = Shop
S.onInit(Shop.init)
return Shop
