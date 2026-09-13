-- MinidoracatEconomyFor42 - Discord deposits, v1 inbound only (server authority; spec 12 stage H,
-- persistence spec 5.4-5.5).
--
-- The companion is the single writer of {cachedir}/Lua/MinidoracatEconomy/inbox/<orderId>.json
-- (one JSON object per file, written as .tmp then renamed). This module polls the directory on
-- OnTickEvenPaused (PauseEmpty stops every other clock), reads each order once, decides, and
-- reports only through the event stream: exchange.deposited / exchange.failed. It never writes
-- or deletes an inbox file; the companion removes a file once the matching event is durable.
--
-- Deciding an order: the tombstone (md.exchange.tombstones[orderId]) makes the file idempotent
-- while it is still on disk; the currency must be registered, exchangeable and enabled; the
-- pinned (rateVersion, rateSnapshot) must be the current rate or one of the last superseded
-- ones (Cfg.rateAccepted, no clock); amount must be what the pinned rate gives for the points
-- and lie in perOrderMin..perOrderMax; the per-account and server-wide daily caps count gross
-- deposits per reward day. Then a single posting EXTERNAL_DISCORD_<currency> -> player (kind
-- exchange_deposit, requestId discord:<orderId>): that account's balance is the Discord-side
-- liability. A failure is final for that orderId (tombstone status "failed"); Watchcord refunds
-- the points once exchange.failed is durable.
--
-- Crash before the save: ModData rolls back (wallet and tombstone alike) but the inbox file is
-- still there, so the next poll replays it exactly once. Tombstones are dropped once their file
-- is gone (the companion only deletes after durability, so the tombstone itself is saved by
-- then); at TOMBSTONE_MAX new orders are refused (fail closed), nothing is evicted.
--
-- Engine: listFilesInZomboidLuaDirectory(dir) returns file names, non-recursive, an empty list
-- for a missing directory (LuaManager.java:6024-6033, 6057-6068); getFileReader (:5933-5963);
-- both relative to {cachedir}/Lua/. Every directory entry costs one getCanonicalFile, so the
-- poll is throttled and the per-poll file count is capped.

if not MinidoracatEconomy or not MinidoracatEconomy.Auction then
    require "MinidoracatEconomy/ECAuction"
end
local EC = MinidoracatEconomy
local S = EC and EC.Server
local L = EC and EC.Ledger
local X = EC and EC.Export
local Cfg = EC and EC.Config
local R = EC and EC.Rewards
local W = EC and EC.Wallet
if not S or not S.AUTHORITY or not L or not X or not Cfg or not R or not W then
    return
end

EC.Exchange = EC.Exchange or {}
local Ex = EC.Exchange

Ex.DIR = X.ROOT .. "/inbox"
Ex.POLL_MS = 2000
Ex.FILES_PER_POLL = 50
Ex.TOMBSTONE_MAX = 5000
Ex.PRUNE_EVERY_MS = 60000
Ex.ORDER_ID_MAX = 64
Ex.USERNAME_MAX = 64
Ex.DAILY_KEEP_DAYS = 31
Ex.ACCOUNT_PREFIX = "EXTERNAL_DISCORD_"

local md = nil
local lastPoll, lastPrune = 0, 0
local lastSeen = 0          -- .json files in the directory at the last poll (health)

-- ---------- helpers ----------

local function isInt(v, lo, hi)
    return type(v) == "number" and v == math.floor(v) and v >= lo and v <= hi
end

local function validOrderId(id)
    return type(id) == "string" and id ~= "" and #id <= Ex.ORDER_ID_MAX and string.match(id, "^[A-Za-z0-9_%-]+$") ~= nil
end

local function readOrder(name)
    local reader = nil
    local ok = pcall(function() reader = getFileReader(Ex.DIR .. "/" .. name, false) end)
    if not ok or not reader then return nil, "unreadable" end
    local text = nil
    pcall(function()
        local parts = {}
        for _ = 1, 64 do
            local line = reader:readLine()
            if line == nil then break end
            parts[#parts + 1] = line
        end
        text = table.concat(parts, "\n")
    end)
    pcall(function() reader:close() end)
    if type(text) ~= "string" or text == "" then return nil, "empty" end
    local doc, err = EC.jsonDecode(text)
    if type(doc) ~= "table" then return nil, "json: " .. tostring(err) end
    return doc
end

local function dailyRow(day, create)
    local t = md.exchange.daily[day]
    if not t then
        if not create then return nil end
        t = { total = {}, accounts = {} }
        md.exchange.daily[day] = t
        local oldest = R.dayKey(EC.now() - Ex.DAILY_KEEP_DAYS * 86400000)
        local stale = {}
        for k in pairs(md.exchange.daily) do if k < oldest then stale[#stale + 1] = k end end
        for _, k in ipairs(stale) do md.exchange.daily[k] = nil end
    end
    return t
end

local function tombstone(orderId, fields)
    fields.ts = EC.now()
    fields.seq = md.meta.seq
    fields.epoch = md.meta.epoch
    md.exchange.tombstones[orderId] = fields
    md.exchange.count = md.exchange.count + 1
end

-- ---------- one order ----------

-- Returns "deposited" | "failed" | "skipped".
function Ex.process(order, orderId)
    if md.exchange.tombstones[orderId] then return "skipped" end
    local function fail(reason, extra)
        local rec = { status = "failed", reason = reason, username = type(order) == "table" and order.username or nil,
            currency = type(order) == "table" and order.currency or nil }
        tombstone(orderId, rec)
        local ev = { orderId = orderId, reason = reason, username = rec.username, currency = rec.currency,
            amount = type(order) == "table" and order.amount or nil, points = type(order) == "table" and order.points or nil }
        if type(extra) == "table" then for k, v in pairs(extra) do ev[k] = v end end
        X.emit("exchange.failed", ev)
        EC.log("deposit " .. orderId .. " failed: " .. reason)
        return "failed", reason
    end
    if md.exchange.count >= Ex.TOMBSTONE_MAX then
        -- fail closed without a tombstone: the file stays and is retried once room exists
        EC.log("deposit " .. orderId .. " deferred: tombstone cap")
        return "deferred", "tombstone_cap"
    end
    if type(order) ~= "table" or order.orderId ~= orderId then return fail("invalid_order") end
    local username, currency = order.username, order.currency
    if type(username) ~= "string" or username == "" or #username > Ex.USERNAME_MAX or string.find(username, "%c") then return fail("invalid_order") end
    if type(currency) ~= "string" or not EC.CURRENCIES[currency] then return fail("unknown_currency") end
    if L.isSystemAccount(username) then return fail("invalid_order") end
    local cur = Cfg.currency(currency)
    local ex = cur and cur.exchange
    if type(ex) ~= "table" then return fail("not_exchangeable") end
    if not cur.enabled then return fail("currency_disabled") end
    if not isInt(order.amount, 1, L.MAX_ABS_AMOUNT) or not isInt(order.points, 1, L.MAX_ABS_AMOUNT) then return fail("invalid_order") end
    if not isInt(order.rateVersion, 1, 1000000000) or not isInt(order.rateSnapshot, 1, L.MAX_ABS_AMOUNT) then return fail("invalid_order") end
    if not Cfg.rateAccepted(currency, order.rateVersion, order.rateSnapshot) then
        return fail("rate_mismatch", { currentVersion = ex.rateVersion, currentRate = ex.pointsPerCoin })
    end
    if order.amount ~= math.floor(order.points / order.rateSnapshot) then return fail("amount_mismatch") end
    if order.amount < ex.perOrderMin or order.amount > ex.perOrderMax then
        return fail("order_range", { min = ex.perOrderMin, max = ex.perOrderMax })
    end
    local ms = EC.now()
    local day = R.dayKey(ms)
    local row = dailyRow(day, false)
    local usedAccount = row and (row.accounts[username .. "\1" .. currency] or 0) or 0
    local usedServer = row and (row.total[currency] or 0) or 0
    if usedAccount + order.amount > ex.perAccountDaily then return fail("daily_cap", { scope = "account", cap = ex.perAccountDaily, used = usedAccount }) end
    if usedServer + order.amount > ex.serverDaily then return fail("daily_cap", { scope = "server", cap = ex.serverDaily, used = usedServer }) end
    local res = L.credit(username, currency, order.amount, Ex.ACCOUNT_PREFIX .. currency, {
        kind = "exchange_deposit", requestId = "discord:" .. orderId, reasonCode = "exchange_deposit",
        payload = { orderId = orderId, points = order.points, rateSnapshot = order.rateSnapshot, rateVersion = order.rateVersion, sourceMod = "discord" },
    })
    if not res.ok then return fail(res.error) end
    row = dailyRow(day, true)
    if type(row.total) ~= "table" then row.total = {} end
    row.total[currency] = (row.total[currency] or 0) + order.amount
    row.accounts[username .. "\1" .. currency] = usedAccount + order.amount
    tombstone(orderId, { status = "deposited", txId = res.txId, username = username, currency = currency, amount = order.amount })
    X.emit("exchange.deposited", {
        orderId = orderId, username = username, currency = currency, points = order.points, amount = order.amount,
        rateSnapshot = order.rateSnapshot, rateVersion = order.rateVersion, txId = res.txId, creditSeq = res.seq,
    })
    EC.log("deposit " .. orderId .. ": " .. username .. " +" .. tostring(order.amount) .. " " .. currency)
    -- the player hears about it when online; offline, the statement shows the receipt at the next login
    W.pushState(username)
    S.forEachOnline(function(p)
        if p:getUsername() == username then
            S.reply(p, "exchange.notice", { orderId = orderId, currency = currency, amount = order.amount, points = order.points })
        end
    end)
    return "deposited"
end

-- ---------- polling ----------

-- nil when the listing itself failed: that is not "no files", and a poll must not act on it
-- (the prune below would drop every tombstone and the next good listing would replay them all)
local function listInbox()
    local names = {}
    local ok, list = pcall(listFilesInZomboidLuaDirectory, Ex.DIR)
    if not ok or not list then return nil end
    local walked = pcall(function()
        for i = 0, list:size() - 1 do
            local name = tostring(list:get(i))
            if string.match(name, "^[A-Za-z0-9_%-]+%.json$") then names[#names + 1] = name end
        end
    end)
    if not walked then return nil end
    return names
end

function Ex.poll()
    local names = listInbox()
    if names == nil then
        EC.log("inbox listing failed; skipping this poll")
        return
    end
    lastSeen = #names
    local processed = 0
    local present = {}
    for _, name in ipairs(names) do
        local orderId = string.sub(name, 1, #name - 5)
        present[orderId] = true
        if not md.exchange.tombstones[orderId] and processed < Ex.FILES_PER_POLL then
            processed = processed + 1
            local order, err = readOrder(name)
            if order == nil then
                -- a half-written file cannot happen (tmp + rename); an unreadable one is left for
                -- the host to look at, it is not tombstoned so a fixed file is picked up
                EC.log("inbox " .. name .. " unreadable: " .. tostring(err))
            else
                Ex.process(order, orderId)
            end
        end
    end
    local now = EC.now()
    if now - lastPrune >= Ex.PRUNE_EVERY_MS then
        lastPrune = now
        -- a tombstone whose file is gone did its job: the companion deletes only after the
        -- event (and with it this ModData) is durable
        local gone = {}
        for orderId in pairs(md.exchange.tombstones) do
            if not present[orderId] then gone[#gone + 1] = orderId end
        end
        for _, orderId in ipairs(gone) do md.exchange.tombstones[orderId] = nil end
        md.exchange.count = md.exchange.count - #gone
    end
end

function Ex.onTick()
    if not md then return end
    local now = EC.now()
    if now - lastPoll < Ex.POLL_MS then return end
    lastPoll = now
    Ex.poll()
end

-- Admin / health view.
function Ex.stats()
    local n = EC.countKeys(md.exchange.tombstones)
    local today = dailyRow(R.dayKey(EC.now()), false)
    local total = {}
    if today and type(today.total) == "table" then for k, v in pairs(today.total) do total[k] = v end end
    return { tombstones = n, tombstoneMax = Ex.TOMBSTONE_MAX, inboxFiles = lastSeen, lastPollAt = lastPoll, depositedToday = total }
end

-- Recorded outcome of one order (nil when unknown here: never seen, or already pruned).
function Ex.order(orderId)
    if not validOrderId(orderId) then return nil end
    return md.exchange.tombstones[orderId]
end

function Ex.init(root)
    md = root
    md.exchange = md.exchange or { tombstones = {}, count = 0, daily = {} }
    if type(md.exchange.daily) ~= "table" then md.exchange.daily = {} end
    local n = EC.countKeys(md.exchange.tombstones)
    md.exchange.count = n
    lastPoll, lastPrune = 0, 0
    Cfg.emitExchangeConfig()
    EC.log("exchange: " .. tostring(n) .. " tombstones")
end

S.Exchange = Ex
S.onInit(Ex.init)
Events.OnTickEvenPaused.Add(Ex.onTick)
return Ex
