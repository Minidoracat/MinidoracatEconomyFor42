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
local EC = MinidoracatEconomy
if not EC or not EC.makeId then
    error("MinidoracatEconomy shared core failed to load")
end

EC.Client = EC.Client or {}
local C = EC.Client

C.session = nil          -- hello.ack payload from the current server process

local function send(command, args)
    sendClientCommand(getPlayer(), EC.COMMAND_MODULE, command, args or {})
end

local handlers = {}
C.handlers = handlers

handlers["hello.ack"] = function(args)
    C.session = args
    C.currencies = args.currencies or C.currencies
    if type(args.terminals) == "table" then C.terminals = args.terminals end
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
    if C.session and C.session.remoteReadOnly == false then return true end
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
    notifyShop("list", args)
end

-- Reply of one purchase: { ok, error?, requestId, txId?, item, qty, total, currency, delivered,
-- deliveryError?, balance, revision, remaining?, unclaimed }.
handlers["shop.buy"] = function(args)
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
    notifyMail("list", args)
end

-- Reply of one claim: { ok, error?, requestId, mailId, item, qty, entries, unclaimed }.
handlers["mail.claim"] = function(args)
    if C.mail then
        C.mail.entries = args.entries or C.mail.entries
        C.mail.unclaimed = args.unclaimed or C.mail.unclaimed
    end
    notifyMail("claim", args)
end

function C.requestMail() send("mail.list") end
function C.claimMail(mailId, requestId) send("mail.claim", { mailId = mailId, requestId = requestId }) end

-- One id per request; the server echoes it so a reply can be matched to its dialog.
local requestCounter = 0
function C.newRequestId()
    requestCounter = requestCounter + 1
    return tostring(EC.now()) .. "-" .. requestCounter
end

-- Toast through the UI framework when present (family rule: capability probe, never a hard call).
function C.toast(message)
    local ui = MinidoracatUI and MinidoracatUI.v1
    if ui and ui.API_MAJOR == 1 and ui.CAPABILITIES and ui.CAPABILITIES.toast == true then
        pcall(ui.Toast.show, { title = getText("IGUI_MinidoracatEconomy_Toast_Title"), message = message })
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
    C.wallet = nil
    C.rewards = nil
    C.shop = nil
    C.mail = nil
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
