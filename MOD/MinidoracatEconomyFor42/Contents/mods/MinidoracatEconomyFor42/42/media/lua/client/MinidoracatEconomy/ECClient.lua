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

-- The read gate the snapshot reads below and the three history pages of the panel share; it
-- hangs off C, so it is loaded once C exists.
require "MinidoracatEconomy/ECReadGate"

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

local function notify(listeners, label, kind, args)
    for _, fn in ipairs(listeners) do
        local ok, err = pcall(fn, kind, args)
        if not ok then EC.log(label .. " listener failed: " .. tostring(err)) end
    end
end
-- ---------- the five snapshot reads ----------
-- wallet.state, shop.list, mail.list, market.mine and auction.mine take no parameters at all:
-- every caller -- a page that came into view, a views.changed notice, the reply of a purchase
-- or of a claim -- asks for the very same thing, "the newest one". So they share one gate per
-- command (ECReadGate: the server's own command window, one read in flight, only the newest
-- wish kept). A write reply and a page can no longer knock each other's read out of that
-- window: the second ask is remembered and goes out when the first is answered, instead of
-- being dropped by the server without a reply and lost.
--
-- Whether a read is owed at all stays the caller's decision (a page that is not on screen asks
-- for nothing); this owns the timing only. The wish is flushed by a one-shot OnTick that is
-- added while a read is owed and removes itself again the moment none is, so an idle client
-- polls nothing.
local snapshotGates = {}
local snapshotPumping = false

local function snapshotPump()
    local owed = false
    for _, gate in ipairs(snapshotGates) do
        local query, requestId = gate.sentQuery, gate.sentId
        gate:pump(true)
        if gate.onTimeout and gate:expired() then gate.onTimeout(query, requestId) end
        if gate.wanted == true or (gate.onTimeout and gate.pending ~= nil) then owed = true end
    end
    if not owed then
        snapshotPumping = false
        Events.OnTick.Remove(snapshotPump)
    end
end

local function snapshotRead(command, encode, onTimeout)
    local gate
    gate = C.ReadGate.create(function(query, requestId)
        local args = encode and encode(query) or {}
        args.requestId = requestId
        gate.sentQuery = query
        send(command, args)
    end)
    gate.onTimeout = onTimeout
    snapshotGates[#snapshotGates + 1] = gate
    return gate
end

local function askSnapshot(gate, query)
    if query == nil then query = true end
    gate:want(query, true)
    if (gate.wanted == true or (gate.onTimeout and gate.pending ~= nil)) and not snapshotPumping then
        snapshotPumping = true
        Events.OnTick.Add(snapshotPump)
    end
end

local walletSnapshot = snapshotRead("wallet.state")
local shopSnapshot = snapshotRead("shop.list")
local mailSnapshot = snapshotRead("mail.list")
local listingsSnapshot = snapshotRead("market.mine")
local auctionsSnapshot = snapshotRead("auction.mine")

-- The radio the trade terminals own, as the server sees it right now: { frequency, category,
-- enabled (either mode), relayEnabled, range, summaryEnabled }. hello.ack brings the state of
-- the session, the `config` broadcast every later change of it -- a new frequency is registered
-- on the spot instead of waiting for the next login. A broadcast that carries no radio at all
-- (a currency or option change) leaves the last known one alone.
C.radio = nil

-- Read the native registry instead of caching a successful registration: its instance may
-- change between sessions, and addChannelName appends knownFrequencies even on overwrite
-- (ZomboidRadio.java:135-168). A failed registration must remain eligible on the next snapshot.

local function applyRadio(info)
    C.radio = info
    local frequency = info and tonumber(info.frequency)
    if not frequency or not info.enabled then return end
    local ok, err = pcall(function()
        local radio = getZomboidRadio()
        if not radio then
            EC.log("radio channel registration: no native instance")
            return
        end
        local name = getText("IGUI_MinidoracatEconomy_Radio_Channel")
        if radio:getChannelName(frequency) ~= name then
            radio:addChannelName(name, frequency, info.category or "Economy")
        end
    end)
    if not ok then EC.log("radio channel registration failed: " .. tostring(err)) end
end

handlers["hello.ack"] = function(args)
    C.session = args
    C.options = type(args.options) == "table" and args.options or nil
    C.seasonState = type(args.seasonState) == "table" and args.seasonState or nil
    setUnclaimed(args)
    C.currencies = args.currencies or C.currencies
    if type(args.terminals) == "table" then C.terminals = args.terminals end
    C.setMapAtms(args.atms)
    applyRadio(type(args.radio) == "table" and args.radio or nil)
    EC.log("session epoch=" .. tostring(args.epoch) .. " loadedSeq=" .. tostring(args.loadedSeq)
        .. " server=" .. tostring(args.version) .. " remoteReadOnly=" .. tostring(args.remoteReadOnly)
        .. " currencies=" .. tostring(args.currencies and #args.currencies or 0)
        .. " terminals=" .. tostring(args.terminals and #args.terminals or 0))
    -- The item menu offers "sell to the shop" only for an item some SKU buys back, and builds
    -- itself from what is cached (no request while a menu opens): the catalog is read once per
    -- session here, and every catalog change after that is pushed (ECShop Shop.pushAll).
    if C.shop == nil then C.requestShop() end
end

-- Who this client is to the server (hello.ack): `account` owns the money, the mail and the
-- records; `login` is the name the character came in with. They differ only after the server
-- merged this login into another login of the same Steam account. Before hello.ack arrives (or
-- while the identity is refused, which sends no hello.ack) both fall back to the local name. The
-- server stays the authority: these only keep self checks and labels from lying.
local function localName()
    local ok, value = pcall(function() return getPlayer():getUsername() end)
    if ok and type(value) == "string" and value ~= "" then return value end
    return nil
end

local function sessionName(key)
    local value = C.session and C.session[key]
    if type(value) == "string" and value ~= "" then return value end
    return localName()
end

function C.account() return sessionName("account") end
function C.login() return sessionName("login") end
-- Is `name` this client's own account or login?
function C.isMe(name) return name ~= nil and (name == C.account() or name == C.login()) end

local leaderboardGate
local seasonGeneration, leaderboardSentGeneration = 0, nil
local function optionValue(options, key)
    local option = options and options[key]
    if type(option) == "table" then return option.value end
end
-- The live value of one server option, from the snapshot hello.ack and every `config` push carry.
function C.option(key) return optionValue(C.options, key) end

-- Runtime currency changes (name override, enabled, rates) pushed by the server.
handlers["config"] = function(args)
    if type(args.currencies) == "table" then
        C.currencies = args.currencies
    end
    if type(args.options) == "table" then
        local changed = optionValue(C.options, "LeaderboardEnabled") ~= optionValue(args.options, "LeaderboardEnabled")
            or optionValue(C.options, "LeaderboardShowAmounts") ~= optionValue(args.options, "LeaderboardShowAmounts")
        C.options = args.options
        if changed then
            C.leaderboard, C.leaderboardError = nil, nil
            leaderboardGate:clear()
            leaderboardGate.pending, leaderboardGate.sentId = nil, nil
            leaderboardGate.query, leaderboardGate.settled = nil, true
            notify(C.leaderboardListeners, "leaderboard", "config", args)
        end
    end
    -- a config push that carries a radio replaces it (a frequency, a range or a switch changed);
    -- one that does not is about something else and leaves the known radio in place
    if type(args.radio) == "table" then applyRadio(args.radio) end
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
C.rewardsError = nil
local checkinRequestId
C.rewardsListeners = {}
function C.onRewards(fn) C.rewardsListeners[#C.rewardsListeners + 1] = fn end
C.viewListeners = {}
function C.onViews(fn) C.viewListeners[#C.viewListeners + 1] = fn end
local VIEW_SCOPES = { wallet = true, market = true, auction = true, mail = true, shop = true,
    transactions = true, audit = true, players = true, whitelist = true, leaderboard = true }
handlers["views.changed"] = function(args)
    for _, scope in ipairs(args.scopes or {}) do
        if VIEW_SCOPES[scope] then notify(C.viewListeners, "views", scope, args) end
    end
end

handlers["rewards.state"] = function(args)
    if args.ok == false or args.error ~= nil then
        C.rewards, C.rewardsError = nil, args.error or "data_unreadable"
        notify(C.rewardsListeners, "rewards", "error", args)
    else
        C.rewards, C.rewardsError = args, nil
        notify(C.rewardsListeners, "rewards", "state", args)
    end
end

handlers["rewards.checkin"] = function(args)
    if checkinRequestId == nil or args.requestId ~= checkinRequestId then return end
    checkinRequestId = nil
    EC.log("checkin ok=" .. tostring(args.ok) .. " error=" .. tostring(args.error) .. " amount=" .. tostring(args.amount) .. " balance=" .. tostring(args.balance))
    if type(args.state) == "table" then
        C.rewards, C.rewardsError = args.state, nil
    elseif args.stateError ~= nil or args.error == "data_unreadable" or args.error == "not_ready" then
        C.rewards, C.rewardsError = nil, args.stateError or args.error
    end
    if args.ok then
        local money = C.UI and C.UI.amountText or tostring
        C.toast(getText("IGUI_MinidoracatEconomy_Rewards_Granted", money(args.amount), C.currencyName(args.currency)))
    end
    notify(C.rewardsListeners, "rewards", "checkin", args)
end

handlers["milestone.granted"] = function(args)
    EC.log("milestone " .. tostring(args.index) .. " (" .. tostring(args.days) .. " days) +" .. tostring(args.amount))
    C.toast(getText("IGUI_MinidoracatEconomy_Rewards_MilestoneGranted", tostring(args.days), tostring(args.amount), C.currencyName(args.currency)))
    if C.rewards then C.requestRewards() end
    notify(C.rewardsListeners, "rewards", "milestone", args)
end

function C.requestRewards() send("rewards.state") end
function C.checkin()
    local state = C.rewards
    if not state then return end
    local requestId = C.newRequestId()
    checkinRequestId = requestId
    send("rewards.checkin", { day = state.day, rewardIndex = state.claimedCount + 1, requestId = requestId })
    return requestId
end

-- Parameterized reads use stable query keys and exact request ids; an old answer cannot
-- restore a different currency, page, or a snapshot revoked by a privacy-setting change.
local function pairQuery(first, second)
    return tostring(first) .. "\1" .. tostring(second)
end

C.leaderboard = nil
C.leaderboardError = nil
C.leaderboardListeners = {}
function C.onLeaderboard(fn) C.leaderboardListeners[#C.leaderboardListeners + 1] = fn end

local function leaderboardArgs(query)
    local kind, currency, season, page = string.match(query, "^(.-)\1(.-)\1(.-)\1(.*)$")
    return { kind = kind, currency = currency ~= "" and currency or nil,
        season = season ~= "" and season or nil, page = tonumber(page) }
end

leaderboardGate = snapshotRead("leaderboard", function(query)
    leaderboardSentGeneration = seasonGeneration
    return leaderboardArgs(query)
end, function(query, requestId)
    local args = leaderboardArgs(query)
    args.ok, args.error, args.requestId = false, "timeout", requestId
    handlers["leaderboard"](args)
end)

handlers["leaderboard"] = function(args)
    if args.requestId ~= leaderboardGate.sentId then return end
    local query = leaderboardGate.sentQuery
    local generation = leaderboardSentGeneration
    if leaderboardGate:accept(args, query) == "stale" then return end
    local expected = leaderboardArgs(query)
    local matches = args.kind == expected.kind and args.currency == expected.currency and args.season == expected.season
    if expected.kind == "survival" then
        matches = matches and type(args.selectedSeason) == "table" and type(args.seasonState) == "table"
            and args.selectedSeason.id == (expected.season == "current" and args.seasonState.currentId or expected.season)
    end
    if args.ok == true and matches and type(args.entries) == "table" then
        C.leaderboard, C.leaderboardError = args, nil
        if type(args.seasonState) == "table" and generation == seasonGeneration then
            C.seasonState = args.seasonState
        end
        notify(C.leaderboardListeners, "leaderboard", "state", args)
    else
        if args.ok == true then
            args = { ok = false, error = "read_failed", kind = expected.kind, currency = expected.currency,
                season = expected.season, page = expected.page, requestId = args.requestId }
        end
        C.leaderboardError = args.error or "read_failed"
        if C.leaderboardError ~= "timeout" then C.leaderboard = nil end
        notify(C.leaderboardListeners, "leaderboard", "error", args)
    end
end

function C.requestLeaderboard(kind, currency, season, page)
    page = page or 1
    currency = kind == "wealth" and currency or nil
    season = kind == "survival" and (season or "current") or nil
    C.leaderboardError = nil
    local query = tostring(kind) .. "\1" .. tostring(currency or "") .. "\1" .. tostring(season or "") .. "\1" .. tostring(page)
    askSnapshot(leaderboardGate, query)
    notify(C.leaderboardListeners, "leaderboard", "loading", { kind = kind, currency = currency, season = season, page = page })
end

function C.leaderboardBusy() return leaderboardGate:busy() end
function C.cancelLeaderboard() leaderboardGate:clear() end

handlers["seasons.changed"] = function(args)
    if type(args.seasonState) ~= "table" then return end
    seasonGeneration = seasonGeneration + 1
    C.seasonState = args.seasonState
    local query = leaderboardGate.query or leaderboardGate.sentQuery
    local selected = query and leaderboardArgs(query) or nil
    if selected and selected.kind == "survival" and selected.season == "current" then
        leaderboardGate:clear()
        leaderboardGate.pending, leaderboardGate.sentId = nil, nil
        leaderboardGate.query, leaderboardGate.settled = nil, true
    end
    if C.leaderboard and C.leaderboard.kind == "survival" and C.leaderboard.season == "current" then
        C.leaderboard, C.leaderboardError = nil, nil
    end
    notify(C.leaderboardListeners, "leaderboard", "seasons", args)
    notify(C.rewardsListeners, "rewards", "season", args)
    if args.warning == "publication_failed" then
        C.toast(getText("IGUI_MinidoracatEconomy_Season_PublicationFailed"))
    end
end

-- Wallet (server-authoritative view; ECWallet.lua). C.wallet = { balances, receipts, currencies }.
C.wallet = nil
C.walletListeners = {}
function C.onWallet(fn) C.walletListeners[#C.walletListeners + 1] = fn end


handlers["wallet.state"] = function(args)
    if args.requestId ~= nil and walletSnapshot:accept(args) == "stale" then return end
    C.wallet = args
    notify(C.walletListeners, "wallet", "state", args)
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
    notify(C.walletListeners, "wallet", "changed", args)
    C.requestWallet()
end

handlers["wallet.history"] = function(args)
    notify(C.walletListeners, "wallet", "history", args)
end

function C.requestWallet() askSnapshot(walletSnapshot) end
function C.requestHistory(month, requestId)
    requestId = requestId or C.newRequestId()
    send("wallet.history", { month = month, requestId = requestId })
    return requestId
end

-- ---------- player transfer ----------
-- Transport only: the wallet page's transfer dialog matches every reply against the requestId it
-- sent. transfer.info { requestId, ok, enabled, remote, atTerminal, feePercent, min, maxPerTx,
-- dailyLimit, sentToday, remainingToday? (nil = unlimited), readyAt? (ms), currencies };
-- transfer.recipients { requestId, query, items = { {username, online}, ... } };
-- wallet.transfer { requestId, ok, error?, to, currency, amount, fee, total, txId?, balance?,
-- sentToday?, remainingToday?, duplicate?, feeNow?, availableAt?, needed?, min?, max? }.
handlers["transfer.info"] = function(args)
    notify(C.walletListeners, "wallet", "transfer.info", args)
end

-- The candidate box (ECPlayerPicker) reads the shape admin.players / market.sellers answer in;
-- this command is its own context, so the reply is named for it here.
handlers["transfer.recipients"] = function(args)
    args.context, args.players = "transfer", args.items
    notify(C.walletListeners, "wallet", "transfer.recipients", args)
end

handlers["wallet.transfer"] = function(args)
    if args.ok then C.requestWallet() end
    notify(C.walletListeners, "wallet", "transfer", args)
end

-- Pushed to an online payee only: { from, currency, amount, memo?, txId, balance }. The wallet
-- push that comes with it repaints the balance; this is the toast, whatever page is open.
handlers["wallet.transferReceived"] = function(args)
    local money = C.UI and C.UI.amountText or tostring
    local memo = type(args.memo) == "string" and args.memo ~= "" and args.memo or nil
    local key = "IGUI_MinidoracatEconomy_Transfer_Received" .. (memo and "Memo" or "")
    C.toast(getText(key, tostring(args.from), money(args.amount), C.currencyName(args.currency), memo or ""))
    notify(C.walletListeners, "wallet", "transferReceived", args)
end

function C.requestTransferInfo(requestId) send("transfer.info", { requestId = requestId }) end
function C.requestTransferRecipients(query, requestId)
    send("transfer.recipients", { query = query, requestId = requestId })
end
function C.transfer(to, currency, amount, fee, memo, requestId)
    send("wallet.transfer", { to = to, currency = currency, amount = amount, fee = fee, memo = memo,
        requestId = requestId })
end

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

-- Map ATMs the server has seen (ECAtmMap), from hello.ack and the `atms` push: flat
-- {x1, y1, z1, x2, ...} on the wire, kept as { {x, y, z, kind = "map_atm"}, ... }. Navigation
-- targets only: the trade gate never reads this list (EC.nearMapAtm asks the square).
C.mapAtms = {}
function C.setMapAtms(flat)
    if type(flat) ~= "table" then return end
    local list = {}
    for i = 1, #flat - 2, 3 do
        local x, y, z = flat[i], flat[i + 1], flat[i + 2]
        if type(x) == "number" and type(y) == "number" and type(z) == "number" then
            list[#list + 1] = { x = x, y = y, z = z, kind = "map_atm" }
        end
    end
    C.mapAtms = list
end
handlers["atms"] = function(args) C.setMapAtms(args.list) end

-- Client-side mirror of the server gate (ECTerminal.near) for enabling buttons; the server
-- re-checks every write. Chebyshev distance on the player's level, EC.TERMINAL_RANGE tiles.
function C.nearTerminal()
    local player = getPlayer()
    if not player then return false end
    local px, py, pz = player:getX(), player:getY(), math.floor(player:getZ())
    for _, t in ipairs(C.terminals or {}) do
        if t.z == pz and math.max(math.abs(px - t.x), math.abs(py - t.y)) <= EC.TERMINAL_RANGE then return true end
    end
    return EC.nearMapAtm(player)
end

function C.registerTerminal(x, y, z, kind, requestId) send("terminal.register", { x = x, y = y, z = z, kind = kind or "atm", requestId = requestId }) end
function C.unregisterTerminal(id, requestId) send("terminal.unregister", { id = id, requestId = requestId }) end
function C.demolishTerminal(x, y, z, requestId) send("terminal.demolish", { x = x, y = y, z = z, requestId = requestId }) end

-- Shop snapshots carry per-SKU prices[currency], a shared unit quota, and per-currency buyback
-- budgets. Every transaction names its currency; there is no page-level settlement currency.
C.shop = nil
C.shopListeners = {}
function C.onShop(fn) C.shopListeners[#C.shopListeners + 1] = fn end


handlers["shop.list"] = function(args)
    if args.requestId ~= nil and shopSnapshot:accept(args) == "stale" then return end
    C.shop = args
    setUnclaimed(args)
    notify(C.shopListeners, "shop", "list", args)
end
handlers["shop.stock"] = function(args)
    if not C.shop or C.shop.revision ~= args.revision then
        notify(C.viewListeners, "views", "shop", args)
        return
    end
    for _, item in ipairs(C.shop.items or {}) do
        if item.id == args.id then
            item.remaining = args.remaining
            -- Clear missing used values rather than pairing stale usage with fresh remaining.
            item.used = tonumber(args.used)
            notify(C.shopListeners, "shop", "stock", args)
            return
        end
    end
end

-- Reply of one purchase: { ok, error?, requestId, txId?, item, qty, total, currency, delivered,
-- deliveryError?, deliveredQty, remainingQty, childMailId?, balance, revision,
-- used?, remaining?, unclaimed }. Qty fields count pieces; used/remaining count shares.
-- The catalog refresh below owns the snapshot; purchase replies do not patch it.
handlers["shop.buy"] = function(args)
    setUnclaimed(args)
    if args.ok then C.requestWallet() end
    notify(C.shopListeners, "shop", "buy", args)
    C.requestShop()
end

-- Buyback (stage G). shop.candidates: { ok, id, item, itemIds, count, unitQty, bidPrice, revision,
-- buyback = { enabled, accountRemaining, serverRemaining, skuRemaining? } }; shop.sell: { ok, error?,
-- requestId, txId?, item, qty, count, total, currency, balance, revision, buyback }.
local function sellCandidatesArgs(query)
    local id, currency = string.match(query, "^(.-)\1(.*)$")
    return { id = id, currency = currency }
end

local sellCandidatesGate = snapshotRead("shop.candidates", sellCandidatesArgs, function(query, requestId)
    local args = sellCandidatesArgs(query)
    args.ok, args.error, args.requestId = false, "timeout", requestId
    handlers["shop.candidates"](args)
end)

handlers["shop.candidates"] = function(args)
    if args.requestId ~= sellCandidatesGate.sentId then return end
    local query = sellCandidatesGate.sentQuery
    if sellCandidatesGate:accept(args, query) == "stale" then return end
    local expected = sellCandidatesArgs(query)
    if args.ok == true and (args.id ~= expected.id or args.currency ~= expected.currency) then
        args = { ok = false, error = "read_failed", id = expected.id,
            currency = expected.currency, requestId = args.requestId }
    end
    notify(C.shopListeners, "shop", "candidates", args)
end

handlers["shop.sell"] = function(args)
    if args.ok then C.requestWallet() end
    notify(C.shopListeners, "shop", "sell", args)
    C.requestShop()
end

-- A Discord deposit landed while this player is online: { orderId, currency, amount, points }.
-- The wallet push that comes with it repaints the balance; this is only the toast.
handlers["exchange.notice"] = function(args)
    local money = C.UI and C.UI.amountText or tostring
    C.toast(getText("IGUI_MinidoracatEconomy_Exchange_Notice_deposited", money(args.amount), C.currencyName(args.currency), tostring(math.floor(tonumber(args.points) or 0))))
end

function C.requestShop() askSnapshot(shopSnapshot) end
function C.buy(id, count, currency, revision, requestId, acceptMail)
    send("shop.buy", { id = id, count = count, currency = currency, revision = revision, requestId = requestId, acceptMail = acceptMail })
end
function C.sell(id, itemIds, currency, revision, requestId)
    send("shop.sell", { id = id, itemIds = itemIds, currency = currency, revision = revision, requestId = requestId })
end
function C.requestSellCandidates(id, currency)
    askSnapshot(sellCandidatesGate, pairQuery(id, currency))
end
function C.cancelSellCandidates() sellCandidatesGate:clear() end

-- Mailbox: { entries = { {id, kind, item, qty, price, currency, seller?, txId, at}, ... }, unclaimed,
-- atTerminal }. `seller` is the account on the other side of a real trade, written by the server
-- from its own record of the deal; a shop purchase, a return and every letter written before the
-- field simply have none.
C.mail = nil
C.mailListeners = {}
function C.onMail(fn) C.mailListeners[#C.mailListeners + 1] = fn end


handlers["mail.list"] = function(args)
    if args.requestId ~= nil and mailSnapshot:accept(args) == "stale" then return end
    C.mail = args
    setUnclaimed(args)
    notify(C.mailListeners, "mail", "list", args)
end

-- Reply of one claim: { ok, error?, requestId, mailId, item, qty, deliveredQty?, remainingQty?,
-- childMailId?, unitWeight?, freeCapacity?, capacity?, needWeight?, entries, unclaimed }. A claim
-- that only settled part of the letter (the room took only that many whole units, or a take-back
-- failed) answers ok=false with error='delivery_partial': deliveredQty went into the backpack and
-- remainingQty stayed in the letter, which is still there to be claimed again.
handlers["mail.claim"] = function(args)
    setUnclaimed(args)
    if C.mail then
        C.mail.entries = args.entries or C.mail.entries
        C.mail.unclaimed = args.unclaimed or C.mail.unclaimed
        C.mail.usage = args.usage or C.mail.usage
    end
    notify(C.mailListeners, "mail", "claim", args)
end
handlers["mail.claimAll"] = function(args)
    setUnclaimed(args)
    if C.mail then
        C.mail.entries = args.entries or C.mail.entries
        C.mail.unclaimed = args.unclaimed or C.mail.unclaimed
        C.mail.usage = args.usage or C.mail.usage
    end
    notify(C.mailListeners, "mail", "claimAll", args)
end

function C.requestMail() askSnapshot(mailSnapshot) end
function C.claimMail(mailId, requestId) send("mail.claim", { mailId = mailId, requestId = requestId }) end
function C.claimMailBatch(mailIds, requestId)
    send("mail.claimAll", { mailIds = mailIds, requestId = requestId })
end

-- ---------- recovery (asset conservation) ----------
-- Units the server is holding back because it cannot prove where they came from: they are
-- neither handed over nor written off until an admin has reconciled them, and the evidence is
-- kept either way. The server pushes the count when the player logs in and whenever it moves
-- (recovery.status { held }). This is a read for the player, so it is worded once per new
-- number -- never per frame, and never again for a number that has not changed. A held count of
-- zero says nothing at all: there is nothing waiting.
C.recoveryHeld = 0

handlers["recovery.status"] = function(args)
    local n = tonumber(args.held)
    if n == nil then return end
    n = math.max(0, math.floor(n))
    local previous = C.recoveryHeld
    C.recoveryHeld = n
    if n > 0 and n ~= previous then
        C.toast(getText("IGUI_MinidoracatEconomy_Recovery_Held", tostring(n)))
    end
end

-- The server took back a copy an older save brought back (it had already been listed, auctioned
-- or sold, possibly by someone else) and wrote it into the market history: { item, qty }.
handlers["recovery.reclaimed"] = function(args)
    local qty = math.max(1, math.floor(tonumber(args.qty) or 1))
    C.toast(getText("IGUI_MinidoracatEconomy_Recovery_Reclaimed", C.itemLabel(args.item), tostring(qty)))
end

-- An administrator mailed one of those back: { item, qty, unclaimed }.
handlers["recovery.restored"] = function(args)
    setUnclaimed(args)
    local qty = math.max(1, math.floor(tonumber(args.qty) or 1))
    C.toast(getText("IGUI_MinidoracatEconomy_Recovery_Restored", C.itemLabel(args.item), tostring(qty)))
end

-- What became of the items a write produced, worded for a toast. The outcome is a delivery code
-- (`deliveryError` next to a purchase's `delivered = false`, or the `error` of a claim, which is
-- itself the outcome); any other code is not a delivery answer and is left to the caller's own
-- error space. The counts are items and the mailbox figure is letters still waiting, so a
-- partial hand-over never reads as "the whole thing failed" and a parked one never as "all
-- claimed". deliveredQty = nil means the server could not confirm a count, and an unknown is
-- never worded as zero. When the room decided it, the server's own numbers say what to free:
-- backpack_full names the unit weight, the room left and what one more unit needs (or that no
-- backpack of this character can ever hold it), delivery_partial what the rest of the letter
-- needs, and a purchase refused as unit_too_heavy the unit weight against the empty capacity.
-- This lives in the transport because the auction notice has to toast without any page open.
local DELIVERY_CODES = { mailbox = true, backpack_full = true, delivery_failed = true, delivery_partial = true,
    unit_too_heavy = true, hands_full = true }

-- A weight as the player reads it (one decimal, like the buy dialog). `round` = "up" for an
-- amount to free (never shown smaller than the server asked for), "down" for room left (never
-- shown larger than there is, so "weight - room = what to free" adds up on screen), nil = nearest.
function C.weightText(value, round)
    local v = tonumber(value) or 0
    if round == "up" then v = math.ceil(v * 10 - 1e-6) / 10
    elseif round == "down" then v = math.floor(v * 10 + 1e-6) / 10 end
    return string.format("%.1f", v)
end

function C.deliveryText(args)
    if type(args) ~= "table" then return nil end
    local code = args.deliveryError
    if code == nil and args.ok ~= true then code = args.error end
    if code == nil and args.delivered == false then code = "mailbox" end
    if type(code) ~= "string" or DELIVERY_CODES[code] ~= true then return nil end
    local key = "IGUI_MinidoracatEconomy_"
    local left = tostring(math.max(0, math.floor(tonumber(args.unclaimed) or C.unclaimed or 0)))
    local done = tonumber(args.deliveredQty)
    local unit, free, cap, need = tonumber(args.unitWeight), tonumber(args.freeCapacity),
        tonumber(args.capacity), tonumber(args.needWeight)
    if code == "unit_too_heavy" then
        return getText(key .. "Delivery_TooHeavyBuy", C.weightText(unit), C.weightText(cap))
    end
    -- a heavy item goes into both hands, one per claim, whatever the backpack holds (ECMailbox
    -- deliver): the weights do not apply, the hands do
    if code == "hands_full" then return getText(key .. "Delivery_HandsFull", left) end
    if code == "delivery_partial" and args.heavy == true then
        return getText(key .. "Delivery_HeavyPartial", tostring(math.floor(done or 0)),
            tostring(math.floor(tonumber(args.remainingQty) or 0)), left)
    end
    if code == "delivery_partial" then
        local text = getText(key .. "Delivery_Partial", tostring(math.floor(done or 0)),
            tostring(math.floor(tonumber(args.remainingQty) or 0)), left)
        if need ~= nil and need > 0 then
            text = text .. getText(key .. "Text_SentenceSep") .. getText(key .. "Delivery_FreeToFinish", C.weightText(need, "up"))
        end
        return text
    end
    if code == "delivery_failed" then
        return getText(key .. "Delivery_Failed", getText(key .. "Shop_Error_delivery_failed"), left)
    end
    if code == "backpack_full" and unit ~= nil and cap ~= nil and unit > cap then
        return getText(key .. "Delivery_TooHeavy", C.weightText(unit), C.weightText(cap))
    end
    if code == "backpack_full" and unit ~= nil and free ~= nil and need ~= nil then
        return getText(key .. "Delivery_NoRoom", C.weightText(unit), C.weightText(free, "down"), C.weightText(need, "up"), left)
    end
    return getText(key .. "Shop_Parked", left)
end

local function finiteWeight(value)
    return type(value) == "number" and value >= 0 and value < math.huge
end

-- Whether this item type is carried in both hands (vanilla's isForceDropHeavyItem: generators,
-- base:heavyitem; InventoryItem.java:534-540). The script alone does not say it for every case
-- (the type name decides for "Generator"), so one throwaway copy per type answers, cached.
local heavyTypes = {}
function C.isHeavyType(fullType)
    if type(fullType) ~= "string" then return false end
    local known = heavyTypes[fullType]
    if known ~= nil then return known end
    local ok, heavy = pcall(function() return instanceItem(fullType):isForceDropHeavyItem() end)
    heavyTypes[fullType] = ok and heavy == true
    return heavyTypes[fullType]
end

-- Preview only: encumbrance is not the hard container capacity. The server prepares the real
-- items and checks again before debit (ItemContainer.java:195-237, 2247-2270).
function C.deliveryPreview(fullType, qty, unitWeight)
    local out = { known = false, qty = qty }
    if not finiteWeight(qty) or qty < 1 or qty ~= math.floor(qty) then return out end
    -- a heavy item is handed over into both hands, one per claim, and never by backpack room
    -- (ECMailbox M.prepare): a second unit, or hands already on one, means the mailbox
    if C.isHeavyType(fullType) then
        local busy = false
        pcall(function()
            local player = getPlayer()
            local a, b = player:getPrimaryHandItem(), player:getSecondaryHandItem()
            busy = (a ~= nil and a:isForceDropHeavyItem()) or (b ~= nil and b:isForceDropHeavyItem())
        end)
        out.known, out.heavy, out.handsBusy = true, true, busy
        out.fitQty = busy and 0 or 1
        out.willMail = busy or qty > 1
        return out
    end
    if unitWeight == nil then
        local ok, value = pcall(function()
            local script = ScriptManager.instance:FindItem(fullType)
            return script and script:getActualWeight()
        end)
        if ok then unitWeight = value end
    end
    if not finiteWeight(unitWeight) or not finiteWeight(qty * unitWeight) then return out end
    local player = getPlayer()
    if not player then return out end
    local ok, capacity, weight, limit, fits = pcall(function()
        local inv = player:getInventory()
        return inv:getEffectiveCapacity(player), inv:getCapacityWeight(), inv:getMaxWeight(),
            inv:hasRoomFor(player, qty * unitWeight)
    end)
    if not ok or not finiteWeight(capacity) or not finiteWeight(weight)
        or not finiteWeight(limit) or type(fits) ~= "boolean" then return out end
    out.known, out.totalWeight = true, qty * unitWeight
    out.freeCapacity, out.carriedWeight, out.encumbranceLimit = math.max(0, capacity - weight), weight, limit
    out.fitQty = weight <= capacity and (unitWeight == 0 and qty or math.min(qty, math.floor(out.freeCapacity / unitWeight))) or 0
    out.willMail = not fits
    return out
end

-- ---------- market (stage D) ----------

-- Browse page: { page, pages, total, items = { {id, seller, item, name, category, price, at,
-- expiresAt, state? (ECCodec Codec.preview)}, ... }, categories, currency, sort, category,
-- query, mine, maxListings, feePercent, taxPercent, priceMin, priceMax, listingDays, atTerminal }.
C.market = nil
-- Own listings: { items = { view... (qty >= 1) }, maxListings, atTerminal }.
C.myListings = nil
-- Backpack candidates: { items = { {itemId, itemIds = {...}, count, item, ok, reason?,
-- state? (Codec.preview), category?}, ... }, atTerminal, feePercent, priceMin, priceMax, mine,
-- maxListings }. One row per item state: `itemIds` holds every stacked item the server merged
-- into it and `count` is how many (the picker lists a lot, not a single item).
C.candidates = nil
-- Own market history (market.history / admin.marketHistory reply): { username, entries =
-- { {kind, listingId, item, qty, price, fee?, tax?, currency?, other?, reason?, admin?, ts,
-- epoch, seq, rolledBack}, ... } (oldest first), total, truncated, error? }.
C.marketHistory = nil
C.marketListeners = {}
function C.onMarket(fn) C.marketListeners[#C.marketListeners + 1] = fn end


handlers["market.browse"] = function(args)
    notify(C.marketListeners, "market", "browse", args)
end

handlers["market.mine"] = function(args)
    if args.requestId ~= nil and listingsSnapshot:accept(args) == "stale" then return end
    C.myListings = args
    notify(C.marketListeners, "market", "mine", args)
end

handlers["market.candidates"] = function(args)
    C.candidates = args
    notify(C.marketListeners, "market", "candidates", args)
end

-- market.list reply: { ok, error?, requestId, listingId?, qty?, fee?, expiresAt?,
-- mine (own listings), min?, max?, modDataKey? }
handlers["market.list"] = function(args)
    if type(args.mine) == "table" then
        C.myListings = C.myListings or {}
        C.myListings.items = args.mine
    end
    if args.ok then C.requestWallet() end
    notify(C.marketListeners, "market", "list", args)
end

-- market.buy reply: { ok, error?, requestId, txId?, listingId, item, price, tax, delivered,
-- deliveryError?, deliveredQty, remainingQty, childMailId?, balance, unclaimed }
handlers["market.buy"] = function(args)
    setUnclaimed(args)
    if args.ok then C.requestWallet() end
    notify(C.marketListeners, "market", "buy", args)
end

-- market.cancel reply: { ok, error?, requestId, listingId, mailId?, delivered, deliveryError?,
-- deliveredQty, remainingQty, childMailId?, mine, unclaimed }
handlers["market.cancel"] = function(args)
    setUnclaimed(args)
    if type(args.mine) == "table" then
        C.myListings = C.myListings or {}
        C.myListings.items = args.mine
    end
    notify(C.marketListeners, "market", "cancel", args)
end

-- market.history reply: the player's own ring (oldest first). Transport only -- the page's read
-- gate decides whether this answer is still the question it is asking, and the page writes
-- C.marketHistory itself once it has accepted it. A refusal never becomes a snapshot.
handlers["market.history"] = function(args)
    notify(C.marketListeners, "market", "history", args)
end

-- The server pushes this to an online seller when their listing left the market, and to both
-- sides of an auction (stage F): { kind = "sold"|"delisted"|"expired"|"auction_bid"|
-- "auction_outbid"|"auction_sold"|"auction_won"|"auction_unsold"|"auction_cancelled"|
-- "auction_refund", listingId?, auctionId?, item, qty, price, tax?, currency?, buyer?, bidder?,
-- reason?, mailId?, delivered?, deliveryError?, deliveredQty?, remainingQty?,
-- unclaimed }. The toast has to fire without any page being open, so it lives here.
-- %3 of the message: a sale nets the tax off, a cancellation names its reason, every auction
-- money line is the amount that moved; auction_unsold uses two parameters only.
-- A won auction is claimed for the winner before this notice is sampled, so the second line
-- says how many items actually reached the backpack and how many letters are still waiting.
handlers["market.notice"] = function(args)
    setUnclaimed(args)
    local kind = tostring(args.kind or "")
    local money = C.UI and C.UI.amountText or tostring
    local currency = args.currency ~= nil and C.currencyName(args.currency)
        or getText("IGUI_MinidoracatEconomy_Market_CurrencyUnknown")
    local third = ""
    if kind == "sold" or kind == "auction_sold" then
        local price, tax = tonumber(args.price), tonumber(args.tax)
        third = price and tax and (money(price - tax) .. " " .. currency) or "-"
    elseif kind == "delisted" or kind == "auction_cancelled" then
        third = (type(args.reason) == "string" and args.reason ~= "") and args.reason or "-"
    elseif kind == "auction_bid" or kind == "auction_outbid" or kind == "auction_won"
        or kind == "auction_refund" then
        local price = tonumber(args.price)
        third = price and (money(price) .. " " .. currency) or "-"
    end
    -- the args go in the one lookup: probing the key bare makes the engine warn about %1
    local text = getTextOrNull("IGUI_MinidoracatEconomy_Market_Notice_" .. kind, C.itemLabel(args.item),
        tostring(math.max(1, math.floor(tonumber(args.qty) or 1))), third)
    if text then
        C.toast(text)
        local note = C.deliveryText(args)
        if note then C.toast(note) end
    end
    notify(C.marketListeners, "market", "notice", args)
end

-- The whitelist changed under an open picker: { at }. The candidate list is now stale.
handlers["market.whitelist"] = function(args)
    notify(C.marketListeners, "market", "whitelist", args)
end

-- market.sellers reply: { ok, error?, query, context, requestId, players = { {username, online},
-- ... }, total, truncated }. Transport only -- the candidate box that asked for it matches the
-- reply against its own context and requestId (ECPlayerPicker:owns), so the market page, the
-- auction page and the two admin pages never read each other's answer. The listener is the
-- market one, the way every auction reply already rides it.
handlers["market.sellers"] = function(args)
    notify(C.marketListeners, "market", "sellers", args)
end

-- `seller` is an exact account name: the server compares it byte for byte, and it is a condition
-- of its own -- the keyword still searches item and seller text the way it always did.
function C.requestMarket(opts)
    opts = opts or {}
    send("market.browse", { category = opts.category, query = opts.query, sort = opts.sort,
        page = opts.page, seller = opts.seller, currency = opts.currency or "all" })
end
function C.requestMyListings() askSnapshot(listingsSnapshot) end
-- requestId (optional) comes back on the reply: a dropped item waits for its own read
function C.requestCandidates(requestId) send("market.candidates", { requestId = requestId }) end
-- `itemIds` is the whole lot the player picked; `price` is the total for it.
function C.listItem(itemIds, price, currency, requestId)
    send("market.list", { itemIds = itemIds, price = price, currency = currency, requestId = requestId })
end
function C.buyListing(listingId, price, currency, requestId, acceptMail)
    send("market.buy", { listingId = listingId, price = price, currency = currency, requestId = requestId, acceptMail = acceptMail })
end
function C.cancelListing(listingId, requestId) send("market.cancel", { listingId = listingId, requestId = requestId }) end
function C.requestMarketHistory(requestId)
    requestId = requestId or C.newRequestId()
    send("market.history", { requestId = requestId })
    return requestId
end

-- ---------- auction (stage F) ----------
-- The auction pages ride the market listener (C.onMarket): the kinds are prefixed "auction.",
-- so one subscription keeps every server-driven refresh (and market.notice) in one place.

-- Browse page: { page, pages, total, items = { {id, seller, item, name, category, qty,
-- startPrice, bid?, bidder?, bids, at, expiresAt, minNext, mine, leading, state? (Codec.preview)},
-- ... }, sort, query, currency, minHours, maxHours, incrementPercent,
-- feePercent, taxPercent, maxAuctions, mine, atTerminal }.
C.auction = nil
-- Own auctions: { selling = { view... }, bidding = { view... }, atTerminal, maxAuctions }.
C.myAuctions = nil
-- Auction history (auction.history reply): the server filters the daily event files it already
-- writes -- no ledger of its own -- and answers { history = true, entries = { {kind, auctionId,
-- listingId, ts, epoch, seq, txId?, item?, qty?, seller?, bidder?, buyer?, previous?, price?,
-- currency?, rolledBack}, ... } (oldest first, at most 200), total, truncated, query, auctionId?,
-- requestId?, error? }. `price` is what the auction quoted (the opening bid, one bid, the winning
-- amount) -- never a wallet delta, so two bids in a row are two amounts and not a double charge.
C.auctionHistory = nil

-- create/cancel answer with the fresh { selling, bidding, biddingTotal } set; the page-level
-- fields (atTerminal, maxAuctions) only come with auction.mine, so they are kept. `bidding` is cut
-- at the server's cap (soonest-ending first); biddingTotal counts every auction bid on.
local function setMyAuctions(mine)
    if type(mine) ~= "table" then return end
    C.myAuctions = C.myAuctions or {}
    C.myAuctions.selling = mine.selling or {}
    C.myAuctions.bidding = mine.bidding or {}
    C.myAuctions.biddingTotal = tonumber(mine.biddingTotal)
end

handlers["auction.browse"] = function(args)
    notify(C.marketListeners, "market", "auction.browse", args)
end

handlers["auction.mine"] = function(args)
    if args.requestId ~= nil and auctionsSnapshot:accept(args) == "stale" then return end
    C.myAuctions = args
    notify(C.marketListeners, "market", "auction.mine", args)
end

-- auction.create reply: { ok, error?, requestId, auctionId?, qty?, fee?, expiresAt?, mine }
handlers["auction.create"] = function(args)
    setUnclaimed(args)
    setMyAuctions(args.mine)
    if args.ok then C.requestWallet() end
    notify(C.marketListeners, "market", "auction.create", args)
end

-- auction.bid reply: { ok, error?, requestId, auctionId, amount, minNext, reserved, balance }.
-- A bid moves money into `reserved`, so the wallet card is refreshed the way a purchase is.
handlers["auction.bid"] = function(args)
    setUnclaimed(args)
    if args.ok then C.requestWallet() end
    notify(C.marketListeners, "market", "auction.bid", args)
end

-- auction.cancel reply: { ok, error?, requestId, auctionId, mailId, delivered, deliveryError?,
-- deliveredQty, remainingQty, childMailId?, mine, unclaimed }
handlers["auction.cancel"] = function(args)
    setUnclaimed(args)
    setMyAuctions(args.mine)
    notify(C.marketListeners, "market", "auction.cancel", args)
end

-- auction.history reply. Transport only: a search is typed, so two answers can be in flight at
-- once and only the page's own read gate knows which question is still in force. It writes
-- C.auctionHistory after it accepted the answer; a refusal never becomes a snapshot.
handlers["auction.history"] = function(args)
    notify(C.marketListeners, "market", "auction.history", args)
end

function C.requestAuctions(opts)
    opts = opts or {}
    send("auction.browse", { page = opts.page, sort = opts.sort, query = opts.query,
        seller = opts.seller, currency = opts.currency or "all" })
end

-- The public seller candidates both browse pages (and the two admin pages) type into. The caller
-- owns the requestId and the throttle: this is the wire and nothing else.
function C.requestSellers(query, context, requestId)
    send("market.sellers", { query = query, context = context, requestId = requestId })
end
function C.requestMyAuctions() askSnapshot(auctionsSnapshot) end
-- `itemIds` is the whole lot the player picked; `startPrice` is the opening bid for it.
function C.createAuction(itemIds, startPrice, hours, currency, requestId)
    send("auction.create", { itemIds = itemIds, startPrice = startPrice, hours = hours, currency = currency, requestId = requestId })
end
function C.bidAuction(auctionId, amount, currency, requestId)
    send("auction.bid", { auctionId = auctionId, amount = amount, currency = currency, requestId = requestId })
end
function C.cancelAuction(auctionId, requestId) send("auction.cancel", { auctionId = auctionId, requestId = requestId }) end
-- `query` searches the whole visible history (auction id, account, item), `auctionId` pins one
-- auction and asks for its public timeline instead. Returns the requestId the reply will echo.
function C.requestAuctionHistory(opts)
    opts = opts or {}
    local requestId = opts.requestId or C.newRequestId()
    send("auction.history", { query = opts.query, auctionId = opts.auctionId, requestId = requestId })
    return requestId
end

-- Picked-up furniture has no item script of its own: it is made from "Moveables.<sprite>" and
-- then calls itself "<module>.<sprite>" after the shared Base.Moveable script
-- (InventoryItemFactory.java:87-92, 144-150), so getItemNameFromFullType answers the raw type
-- (Translator.java:600-614). The inventory names it from the sprite instead (Moveable.java:151-174):
-- GroupName + CustomName through the moveables dictionary, "(n/m)" on a piece of a multi-tile
-- object. The sprite, or nil for a type with a script or a name no tile answers with a
-- CustomName. getSprite makes and keeps a placeholder for a name it does not know
-- (IsoSpriteManager.java:47-49, 77-81), so the named map is asked first: an item whose MOD was
-- removed must not leave a fake sprite behind.
function C.moveableSprite(fullType)
    local sprite = type(fullType) == "string" and string.match(fullType, "^[^.]+%.(.+)$") or nil
    if sprite == nil or sprite == "Moveable" then return nil end
    local ok, own = pcall(function()
        if ScriptManager.instance:FindItem(fullType) ~= nil then return false end
        if not getSpriteManager(sprite):getNamedMap():containsKey(sprite) then return false end
        local props = getSprite(sprite):getProperties()
        return props ~= nil and props:has("CustomName")
    end)
    return (ok and own) and sprite or nil
end

local function moveableLabel(sprite)
    local ok, spr, name = pcall(function()
        local s = getSprite(sprite)
        local props = s and s:getProperties()
        if not (props and props:has("CustomName")) then return s, nil end
        local n = props:get("CustomName")
        if props:has("GroupName") then n = props:get("GroupName") .. " " .. n end
        return s, Translator.getMoveableDisplayName(n)
    end)
    if not ok or type(name) ~= "string" or name == "" then return nil end
    pcall(function()
        local grid = spr:getSpriteGrid()
        if grid == nil then return end
        if spr:getProperties():has("ForceSingleItem") then name = name .. " (1/1)"
        else name = name .. " (" .. tostring(grid:getSpriteIndex(spr) + 1) .. "/" .. tostring(grid:getSpriteCount()) .. ")" end
    end)
    return name
end

-- Localised item name (engine call, cached): the notice toast needs it before any UI exists.
local itemLabels = {}
function C.itemLabel(fullType)
    local name = itemLabels[fullType]
    if name == nil then
        local sprite = C.moveableSprite(fullType)
        name = sprite and moveableLabel(sprite)
        if name == nil then
            local ok, value = pcall(getItemNameFromFullType, fullType)
            name = (ok and type(value) == "string" and value ~= "") and value or tostring(fullType)
        end
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
-- While the Economy Center is on screen the stack moves below the window's top band (rev 12
-- toastAvoid): title bar, the location row with the balances, and the page's first row of actions
-- (market / auction: the tab row and the card title). The whole window cannot be avoided - at its
-- default size nothing fits below or beside it - and a toast over the right end of a table for a
-- few seconds is better than one over the balances or the claim-all button. Registered once; the
-- window is only looked up, never created, and nothing is allocated per frame.
local toastAvoidSet = false
local function economyWindowRect()
    local w = C.Panel and C.Panel.window
    if w == nil or not w:getIsVisible() then return nil end
    local g, titleH = w.g, (C.UI and C.UI.CARD_TITLE_H) or 36
    local band = w.height
    if g ~= nil and g.contentY ~= nil then
        band = g.contentY + titleH
        if w.tab == "Market" and g.marketCardY then band = g.marketCardY + titleH
        elseif w.tab == "Auction" and g.auctionCardY then band = g.auctionCardY + titleH end
    end
    return w:getAbsoluteX(), w:getAbsoluteY(), w.width, math.min(w.height, band)
end
function C.toast(message)
    local ui = MinidoracatUI and MinidoracatUI.v1
    if ui and ui.API_MAJOR == 1 and ui.CAPABILITIES and ui.CAPABILITIES.toast == true then
        if not toastAvoidSet and (ui.API_REVISION or 0) >= 12 and ui.CAPABILITIES.toastAvoid == true then
            toastAvoidSet = pcall(ui.Toast.setAvoid, "MinidoracatEconomyFor42", economyWindowRect)
        end
        local hold = EC.Options and EC.Options.toastHoldMs() or 5000
        pcall(ui.Toast.show, { title = getText("IGUI_MinidoracatEconomy_Toast_Title"), message = message, holdMs = hold, maxLines = 3 })
    end
end

-- Identity (server ECIdentity): the server answers a player whose name it cannot verify - a
-- name that does not match the SteamID it is bound to - with identity.unverified (at most once a
-- minute) instead of any reply, and with identity.verified once an administrator's import or
-- confirmation fixed it. The flag is what the panel paints; listeners (the panel) repaint on it.
-- Only identity.verified and hello.ack clear it: a login the one-account policy keeps out still
-- receives what belongs to its save (recovery, entitlements) and an administrator's exempt pages,
-- so no other command says the server answers this player as its account. A respawn says hello
-- again while the flag is set (below), which is how a respawn under the right name clears it.
-- C.identityReason is "one_account" when the server refused this login because its Steam account
-- already uses the economy under another login (IdentityMultiAccount off); every other refusal
-- carries no reason.
C.identityUnverified = false
C.identityReason = nil
C.identityListeners = {}
function C.onIdentity(fn) C.identityListeners[#C.identityListeners + 1] = fn end
local function setIdentity(unverified, reason)
    local changed = C.identityUnverified ~= unverified or C.identityReason ~= reason
    C.identityUnverified, C.identityReason = unverified, reason
    if not changed then return end
    notify(C.identityListeners, "identity", unverified and "unverified" or "verified", {})
end

handlers["identity.unverified"] = function(args)
    local reason = args.reason == "one_account" and "one_account" or nil
    setIdentity(true, reason)
    C.toast(getText(reason and "IGUI_MinidoracatEconomy_Identity_OneAccount" or "IGUI_MinidoracatEconomy_Identity_Unverified"))
end

-- An identity alert (a suspected respawn rename, a bound name worn by another SteamID) the server
-- pushes to the administrators online; it says nothing about this player's own identity.
handlers["identity.alert"] = function(args)
    local panel = C.AdminPanel
    if not (panel and panel.canRead and panel.canRead()) then return end
    local kind = getTextOrNull("IGUI_MinidoracatEconomy_Admin_Id_Alert_" .. tostring(args.kind))
        or C.UI.unknownText("identity alert", args.kind)
    C.toast(getText("IGUI_MinidoracatEconomy_Identity_Alert", tostring(args.name), kind))
end

-- A character that died came back on its old save and the server killed it (ECRecovery
-- judgeReturn); pushed to the administrators online, like an identity alert.
handlers["recovery.resurrection"] = function(args)
    local panel = C.AdminPanel
    if not (panel and panel.canRead and panel.canRead()) then return end
    C.toast(getText("IGUI_MinidoracatEconomy_Admin_Resurrection", tostring(args.name), tostring(args.items)))
end

-- The session this client never received while it was refused: say hello again.
handlers["identity.verified"] = function()
    setIdentity(false)
    send("hello")
end

local function onServerCommand(module, command, args)
    if module ~= EC.COMMAND_MODULE then return end
    if command == "hello.ack" then setIdentity(false) end
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
    for _, gate in ipairs(snapshotGates) do
        gate.query, gate.wanted, gate.pending = nil, nil, nil
        gate.sentAt, gate.sentId, gate.sentQuery = nil, nil, nil
        gate.settled, gate.timedOut = nil, nil
    end
    if snapshotPumping then
        snapshotPumping = false
        Events.OnTick.Remove(snapshotPump)
    end
    sent = false
    C.identityUnverified, C.identityReason = false, nil
    C.session = nil
    C.unclaimed = 0
    C.wallet = nil
    C.rewards = nil
    checkinRequestId = nil
    C.rewardsError, C.seasonState = nil, nil
    seasonGeneration, leaderboardSentGeneration = seasonGeneration + 1, nil
    C.leaderboard, C.leaderboardError = nil, nil
    C.shop = nil
    C.mail = nil
    C.market = nil
    C.myListings = nil
    C.candidates = nil
    C.marketHistory = nil
    C.auctionHistory = nil
    C.terminals = {}
    C.mapAtms = {}
    Events.OnTick.Add(firstTick)
end

Events.OnGameStart.Add(onGameStart)
Events.OnServerCommand.Add(onServerCommand)
-- A respawn keeps the client past OnGameStart (the new character comes through AddCoopPlayer,
-- which fires OnCreatePlayer, util/AddCoopPlayer.java:162): a refused player asks again, since the
-- new character may carry the name the server does verify.
Events.OnCreatePlayer.Add(function(playerNum)
    if playerNum == 0 and C.identityUnverified and isClient() then send("hello") end
end)

-- Client half of the integration facade (spec 21.1). Other mods that want to move money go
-- through their own server handler and MinidoracatEconomy.v1 on the server; the client exposes
-- the wallet snapshot this UI already holds and, from rev 2, the entitlement transport
-- (ECEntitlementClient: state / quote / purchase / auto-renew consent / order lookup, all priced
-- and decided by the server). CAPABILITIES.rentals: quote and auto-renew name a rental id (each
-- rental order is its own lease). API_MAJOR lives on the server table on purpose: probing
-- `MinidoracatEconomy.v1.API_MAJOR` on the client stays nil.
require "MinidoracatEconomy/ECEntitlementClient"
EC.v1 = EC.v1 or {}
EC.v1.Client = {
    API_MAJOR = 1,
    API_REVISION = 2,
    CAPABILITIES = { wallet = true, entitlements = true, adminPlans = true, rentals = true },
    getWallet = function() return C.wallet end,
    onWalletChanged = C.onWallet,
    Entitlements = C.Entitlements,
    -- Opens the Economy admin window on the integration plan page (a read-only overview; the
    -- terms are the source mod's own). false when this player may not read the admin pages.
    openAdminPlans = function(sourceMod, productId)
        local AW = C.AdminWindow
        if AW == nil or AW.openPlans == nil then return false end
        return AW.openPlans(sourceMod, productId) == true
    end,
}

return C
