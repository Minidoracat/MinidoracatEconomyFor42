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
    EC.log("session epoch=" .. tostring(args.epoch) .. " loadedSeq=" .. tostring(args.loadedSeq)
        .. " server=" .. tostring(args.version) .. " remoteReadOnly=" .. tostring(args.remoteReadOnly)
        .. " currencies=" .. tostring(args.currencies and #args.currencies or 0))
end

-- Runtime currency changes (name override, enabled, rates) pushed by the server.
handlers["config"] = function(args)
    if type(args.currencies) == "table" then
        C.currencies = args.currencies
    end
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
