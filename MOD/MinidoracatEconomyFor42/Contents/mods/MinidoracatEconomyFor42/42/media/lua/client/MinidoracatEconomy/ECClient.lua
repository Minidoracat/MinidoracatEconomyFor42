-- MinidoracatEconomyFor42 — client side (MP client only; the dedicated server never loads this dir).
--
-- Login request shape (pitfalls.md "MP client 不可在 OnGameStart 直接送 sendClientCommand",
-- IngameState.java:762-775, LuaManager.java:8912-8924): OnGameStart only registers a one-shot
-- OnTick handler; the handler removes itself first, then sends. Stage A18 measured the server
-- receiving it ~23 ms later. Death -> new character does NOT pass through OnGameStart again
-- (stage A6); the server handles that path itself (spec 19.7 rule five).

if not MinidoracatEconomy or not MinidoracatEconomy.makeId then
    require "MinidoracatEconomy/ECCore"
end
if not MinidoracatEconomy.Options then
    require "MinidoracatEconomy/ECOptions"
end
local EC = MinidoracatEconomy
if not EC or not EC.makeId then
    error("MinidoracatEconomy shared core failed to load")
end

EC.Client = EC.Client or {}
local C = EC.Client

C.session = nil          -- hello.ack payload from the current server process
C.unclaimed = 0          -- pending mailbox items; every reply that knows the number refreshes it

local function send(command, args)
    sendClientCommand(getPlayer(), EC.COMMAND_MODULE, command, args or {})
end

-- hello.ack and every reply that touches the mailbox (mail.list/claim, shop.buy, market.buy/
-- cancel/notice) carry the pending count: the float button and the Mail tab paint it as a
-- bubble without a page of their own being open.
local function setUnclaimed(args)
    local n = tonumber(args.unclaimed)
    if n then C.unclaimed = math.max(0, math.floor(n)) end
end

local handlers = {}
C.handlers = handlers

handlers["hello.ack"] = function(args)
    C.session = args
    setUnclaimed(args)
    C.currencies = args.currencies or C.currencies
    if type(args.terminals) == "table" then C.terminals = args.terminals end
    -- the radio channel name is a client-side registry (RWMGeneral.lua reads it): register the
    -- market frequency here so a tuned radio shows the name instead of a bare number
    if type(args.radio) == "table" and args.radio.enabled and tonumber(args.radio.frequency) then
        pcall(function()
            local radio = getZomboidRadio()
            if radio then radio:addChannelName(getText("IGUI_MinidoracatEconomy_Radio_Channel"), args.radio.frequency, args.radio.category or "Economy") end
        end)
    end
    EC.log("session epoch=" .. tostring(args.epoch) .. " loadedSeq=" .. tostring(args.loadedSeq)
        .. " server=" .. tostring(args.version) .. " remoteReadOnly=" .. tostring(args.remoteReadOnly)
        .. " currencies=" .. tostring(args.currencies and #args.currencies or 0)
        .. " terminals=" .. tostring(args.terminals and #args.terminals or 0))
end

-- Runtime currency changes (name override, enabled, rates) pushed by the server.
handlers["config"] = function(args)
    if type(args.currencies) == "table" then
        C.currencies = args.currencies
    end
    if type(args.options) == "table" then C.options = args.options end
    -- the remote read-only switch is a runtime option now: the session mirrors the live value
    if args.remoteReadOnly ~= nil and C.session then C.session.remoteReadOnly = args.remoteReadOnly end
end

-- Display name: admin override -> translation key -> id. Never cache the result across ticks.
function C.currencyName(id)
    local cur = C.currency(id)
    if cur and cur.nameOverride then return cur.nameOverride end
    local static = EC.CURRENCIES[id]
    if static then return getText(static.nameKey) end
    return tostring(id)
end

function C.currency(id)
    for _, cur in ipairs(C.currencies or {}) do
        if cur.id == id then return cur end
    end
    return nil
end

-- Rewards (server-authoritative; the UI in stage B6 renders C.rewards and listens via C.onRewards)
C.rewards = nil
C.rewardsListeners = {}
function C.onRewards(fn) C.rewardsListeners[#C.rewardsListeners + 1] = fn end
local function notifyRewards(kind, args)
    for _, fn in ipairs(C.rewardsListeners) do
        local ok, err = pcall(fn, kind, args)
        if not ok then EC.log("rewards listener failed: " .. tostring(err)) end
    end
end

handlers["rewards.state"] = function(args)
    C.rewards = args
    notifyRewards("state", args)
end

handlers["rewards.checkin"] = function(args)
    EC.log("checkin ok=" .. tostring(args.ok) .. " error=" .. tostring(args.error) .. " amount=" .. tostring(args.amount) .. " balance=" .. tostring(args.balance))
    if args.ok then
        if C.rewards then C.rewards.claimed = true end
        C.toast(getText("IGUI_MinidoracatEconomy_Rewards_Granted", tostring(args.amount), C.currencyName(args.currency)))
    end
    notifyRewards("checkin", args)
end

handlers["milestone.granted"] = function(args)
    EC.log("milestone " .. tostring(args.index) .. " (" .. tostring(args.days) .. " days) +" .. tostring(args.amount))
    C.toast(getText("IGUI_MinidoracatEconomy_Rewards_MilestoneGranted", tostring(args.days), tostring(args.amount), C.currencyName(args.currency)))
    if C.rewards then C.requestRewards() end
    notifyRewards("milestone", args)
end

function C.requestRewards() send("rewards.state") end
function C.checkin() send("rewards.checkin") end

-- Wallet (server-authoritative view; ECWallet.lua). C.wallet = { balances, receipts, currencies }.
C.wallet = nil
C.walletListeners = {}
function C.onWallet(fn) C.walletListeners[#C.walletListeners + 1] = fn end
local function notifyWallet(kind, args)
    for _, fn in ipairs(C.walletListeners) do
        local ok, err = pcall(fn, kind, args)
        if not ok then EC.log("wallet listener failed: " .. tostring(err)) end
    end
end

handlers["wallet.state"] = function(args)
    C.wallet = args
    notifyWallet("state", args)
end

-- Balances arrive with the push; the receipt ring is refreshed with one extra round trip
-- (a player sees at most a few transactions per day, so the cost is irrelevant).
handlers["wallet.changed"] = function(args)
    if C.wallet then
        C.wallet.balances = args.balances or C.wallet.balances
        if args.frozen ~= nil and args.frozen ~= C.wallet.frozen then
            C.wallet.frozen = args.frozen
            C.toast(getText(args.frozen and "IGUI_MinidoracatEconomy_Toast_Frozen" or "IGUI_MinidoracatEconomy_Toast_Unfrozen"))
        end
    end
    notifyWallet("changed", args)
    C.requestWallet()
end

handlers["wallet.history"] = function(args)
    notifyWallet("history", args)
end

function C.requestWallet() send("wallet.state") end
function C.requestHistory(month) send("wallet.history", { month = month }) end

-- ---------- terminals / shop / mailbox (stage C) ----------

-- Terminal list from hello.ack and the `terminals` broadcast: { {id, x, y, z, kind}, ... }.
C.terminals = {}
C.terminalListeners = {}
function C.onTerminals(fn) C.terminalListeners[#C.terminalListeners + 1] = fn end

handlers["terminals"] = function(args)
    if type(args.list) == "table" then C.terminals = args.list end
    if args.remoteReadOnly ~= nil and C.session then C.session.remoteReadOnly = args.remoteReadOnly end
    for _, fn in ipairs(C.terminalListeners) do pcall(fn, C.terminals) end
end

function C.terminalAt(x, y, z)
    for _, t in ipairs(C.terminals or {}) do
        if t.x == x and t.y == y and t.z == z then return t end
    end
    return nil
end

-- Client-side mirror of the server gate (ECTerminal.near) for enabling buttons; the server
-- re-checks every write. Chebyshev distance on the player's level, EC.TERMINAL_RANGE tiles.
function C.nearTerminal()
    local player = getPlayer()
    if not player then return false end
    local px, py, pz = player:getX(), player:getY(), math.floor(player:getZ())
    for _, t in ipairs(C.terminals or {}) do
        if t.z == pz and math.max(math.abs(px - t.x), math.abs(py - t.y)) <= EC.TERMINAL_RANGE then return true end
    end
    return false
end

function C.requestTerminals() send("terminals") end
function C.registerTerminal(x, y, z, kind, requestId) send("terminal.register", { x = x, y = y, z = z, kind = kind or "atm", requestId = requestId }) end
function C.unregisterTerminal(id, requestId) send("terminal.unregister", { id = id, requestId = requestId }) end
function C.demolishTerminal(x, y, z, requestId) send("terminal.demolish", { x = x, y = y, z = z, requestId = requestId }) end

-- Shop snapshot (shop.list / shop.buy replies carry the same fields): { revision, currency,
-- items = { {id, item, qty, price, dailyCap, category, enabled, remaining?, override?}, ... },
-- count, file, dayEndsMs, countMax, atTerminal, unclaimed }.
C.shop = nil
C.shopListeners = {}
function C.onShop(fn) C.shopListeners[#C.shopListeners + 1] = fn end
local function notifyShop(kind, args)
    for _, fn in ipairs(C.shopListeners) do
        local ok, err = pcall(fn, kind, args)
        if not ok then EC.log("shop listener failed: " .. tostring(err)) end
    end
end

handlers["shop.list"] = function(args)
    C.shop = args
    setUnclaimed(args)
    notifyShop("list", args)
end

-- Reply of one purchase: { ok, error?, requestId, txId?, item, qty, total, currency, delivered,
-- deliveryError?, balance, revision, remaining?, unclaimed }.
handlers["shop.buy"] = function(args)
    setUnclaimed(args)
    if args.ok then C.requestWallet() end
    notifyShop("buy", args)
    C.requestShop()
end

function C.requestShop() send("shop.list") end
function C.buy(id, count, revision, requestId) send("shop.buy", { id = id, count = count, revision = revision, requestId = requestId }) end

-- Mailbox: { entries = { {id, kind, item, qty, price, txId, at}, ... }, unclaimed, atTerminal }.
C.mail = nil
C.mailListeners = {}
function C.onMail(fn) C.mailListeners[#C.mailListeners + 1] = fn end
local function notifyMail(kind, args)
    for _, fn in ipairs(C.mailListeners) do
        local ok, err = pcall(fn, kind, args)
        if not ok then EC.log("mail listener failed: " .. tostring(err)) end
    end
end

handlers["mail.list"] = function(args)
    C.mail = args
    setUnclaimed(args)
    notifyMail("list", args)
end

-- Reply of one claim: { ok, error?, requestId, mailId, item, qty, entries, unclaimed }.
handlers["mail.claim"] = function(args)
    setUnclaimed(args)
    if C.mail then
        C.mail.entries = args.entries or C.mail.entries
        C.mail.unclaimed = args.unclaimed or C.mail.unclaimed
        C.mail.usage = args.usage or C.mail.usage
    end
    notifyMail("claim", args)
end

function C.requestMail() send("mail.list") end
function C.claimMail(mailId, requestId) send("mail.claim", { mailId = mailId, requestId = requestId }) end

-- ---------- market (stage D) ----------

-- Browse page: { page, pages, total, items = { {id, seller, item, name, category, price, at,
-- expiresAt, condition, uses, fluid, fluidAmount}, ... }, categories, currency, sort, category,
-- query, mine, maxListings, feePercent, taxPercent, priceMin, priceMax, listingDays, atTerminal }.
C.market = nil
-- Own listings: { items = { view... (qty >= 1) }, maxListings, atTerminal }.
C.myListings = nil
-- Backpack candidates: { items = { {itemId, itemIds = {...}, count, item, ok, reason?,
-- condition?, uses?, category?}, ... }, atTerminal, feePercent, priceMin, priceMax, mine,
-- maxListings }. One row per item state: `itemIds` holds every stacked item the server merged
-- into it and `count` is how many (the picker lists a lot, not a single item).
C.candidates = nil
-- Own market history (market.history / admin.marketHistory reply): { username, entries =
-- { {kind, listingId, item, qty, price, fee?, tax?, currency?, other?, reason?, admin?, ts,
-- epoch, seq, rolledBack}, ... } (oldest first), total, truncated, error? }.
C.marketHistory = nil
C.marketListeners = {}
function C.onMarket(fn) C.marketListeners[#C.marketListeners + 1] = fn end
local function notifyMarket(kind, args)
    for _, fn in ipairs(C.marketListeners) do
        local ok, err = pcall(fn, kind, args)
        if not ok then EC.log("market listener failed: " .. tostring(err)) end
    end
end

handlers["market.browse"] = function(args)
    C.market = args
    notifyMarket("browse", args)
end

handlers["market.mine"] = function(args)
    C.myListings = args
    notifyMarket("mine", args)
end

handlers["market.candidates"] = function(args)
    C.candidates = args
    notifyMarket("candidates", args)
end

-- market.list reply: { ok, error?, requestId, listingId?, qty?, fee?, expiresAt?,
-- mine (own listings), min?, max?, modDataKey? }
handlers["market.list"] = function(args)
    if type(args.mine) == "table" then
        C.myListings = C.myListings or {}
        C.myListings.items = args.mine
    end
    if args.ok then C.requestWallet() end
    notifyMarket("list", args)
end

-- market.buy reply: { ok, error?, requestId, txId?, listingId, item, price, tax, delivered, deliveryError?, balance, unclaimed }
handlers["market.buy"] = function(args)
    setUnclaimed(args)
    if args.ok then C.requestWallet() end
    notifyMarket("buy", args)
end

-- market.cancel reply: { ok, error?, requestId, listingId, mailId?, delivered?, mine, unclaimed }
handlers["market.cancel"] = function(args)
    setUnclaimed(args)
    if type(args.mine) == "table" then
        C.myListings = C.myListings or {}
        C.myListings.items = args.mine
    end
    notifyMarket("cancel", args)
end

-- market.history reply: the player's own ring (oldest first). A refusal (busy/server_busy)
-- must not wipe the snapshot the page is already showing.
handlers["market.history"] = function(args)
    if not args.error then C.marketHistory = args end
    notifyMarket("history", args)
end

-- The server pushes this to an online seller when their listing left the market:
-- { kind = "sold"|"delisted"|"expired", listingId, item, qty, price, tax?, currency?, buyer?,
-- reason?, unclaimed }. The toast has to fire without any page being open, so it lives here.
handlers["market.notice"] = function(args)
    setUnclaimed(args)
    local kind = tostring(args.kind or "")
    local key = getTextOrNull("IGUI_MinidoracatEconomy_Market_Notice_" .. kind)
    if key then
        local money = C.UI and C.UI.amountText or tostring
        local name = C.itemLabel(args.item)
        local qty = tostring(math.max(1, math.floor(tonumber(args.qty) or 1)))
        local third = ""
        if kind == "sold" then
            third = money((tonumber(args.price) or 0) - (tonumber(args.tax) or 0))
        elseif kind == "delisted" then
            third = (type(args.reason) == "string" and args.reason ~= "") and args.reason or "-"
        end
        C.toast(getText("IGUI_MinidoracatEconomy_Market_Notice_" .. kind, name, qty, third))
    end
    notifyMarket("notice", args)
end

-- The whitelist changed under an open picker: { at }. The candidate list is now stale.
handlers["market.whitelist"] = function(args)
    notifyMarket("whitelist", args)
end

function C.requestMarket(opts)
    opts = opts or {}
    send("market.browse", { category = opts.category, query = opts.query, sort = opts.sort, page = opts.page })
end
function C.requestMyListings() send("market.mine") end
function C.requestCandidates() send("market.candidates") end
-- `itemIds` is the whole lot the player picked; `price` is the total for it.
function C.listItem(itemIds, price, requestId) send("market.list", { itemIds = itemIds, price = price, requestId = requestId }) end
function C.buyListing(listingId, price, requestId) send("market.buy", { listingId = listingId, price = price, requestId = requestId }) end
function C.cancelListing(listingId, requestId) send("market.cancel", { listingId = listingId, requestId = requestId }) end
function C.requestMarketHistory() send("market.history") end

-- Localised item name (engine call, cached): the notice toast needs it before any UI exists.
local itemLabels = {}
function C.itemLabel(fullType)
    local name = itemLabels[fullType]
    if name == nil then
        local ok, value = pcall(getItemNameFromFullType, fullType)
        name = (ok and type(value) == "string" and value ~= "") and value or tostring(fullType)
        itemLabels[fullType] = name
    end
    return name
end

-- One id per request; the server echoes it so a reply can be matched to its dialog.
local requestCounter = 0
function C.newRequestId()
    requestCounter = requestCounter + 1
    return tostring(EC.now()) .. "-" .. requestCounter
end

-- Toast through the UI framework when present (family rule: capability probe, never a hard call).
-- Notifications: three lines at most (rev 5 maxLines; an older framework ignores it and
-- truncates), held for the player's ToastSeconds option.
function C.toast(message)
    local ui = MinidoracatUI and MinidoracatUI.v1
    if ui and ui.API_MAJOR == 1 and ui.CAPABILITIES and ui.CAPABILITIES.toast == true then
        local hold = EC.Options and EC.Options.toastHoldMs() or 5000
        pcall(ui.Toast.show, { title = getText("IGUI_MinidoracatEconomy_Toast_Title"), message = message, holdMs = hold, maxLines = 3 })
    end
end

local function onServerCommand(module, command, args)
    if module ~= EC.COMMAND_MODULE then return end
    local handler = handlers[command]
    if not handler then return end
    local ok, err = pcall(handler, args or {})
    if not ok then
        EC.log("server command " .. tostring(command) .. " failed: " .. tostring(err))
    end
end

local sent = false
local function firstTick()
    Events.OnTick.Remove(firstTick)
    if sent then return end
    sent = true
    send("hello")
end

local function onGameStart()
    if not isClient() then return end
    sent = false
    C.session = nil
    C.unclaimed = 0
    C.wallet = nil
    C.rewards = nil
    C.shop = nil
    C.mail = nil
    C.market = nil
    C.myListings = nil
    C.candidates = nil
    C.marketHistory = nil
    C.terminals = {}
    Events.OnTick.Add(firstTick)
end

Events.OnGameStart.Add(onGameStart)
Events.OnServerCommand.Add(onServerCommand)

-- Read-only client half of the integration facade (spec 21.1). Other mods that want to move
-- money go through their own server handler and MinidoracatEconomy.v1 on the server; the
-- client only exposes the wallet snapshot this UI already holds. API_MAJOR lives on the server
-- table on purpose: probing `MinidoracatEconomy.v1.API_MAJOR` on the client stays nil.
EC.v1 = EC.v1 or {}
EC.v1.Client = {
    API_MAJOR = 1,
    API_REVISION = 1,
    getWallet = function() return C.wallet end,
    onWalletChanged = C.onWallet,
}

return C
