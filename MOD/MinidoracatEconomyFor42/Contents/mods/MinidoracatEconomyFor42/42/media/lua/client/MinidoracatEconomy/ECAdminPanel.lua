-- MinidoracatEconomyFor42 -- admin panel (client, stage B7). Adds exactly one namespace:
-- C.AdminPanel.
--
--   C.AdminPanel.canRead() / canWrite()   pure functions, callable before any UI exists
--   C.AdminPanel.create(owner)            initialised ISPanel child, NOT added (owner addChild's
--                                         it); never sends a command
--   instance:resize(w, h) / :refresh() / :dispose() / :setVisible(v)
--
-- ECAdminWindow owns the window and its sidebar. This controller owns permissions, shared
-- command slots, write dialogs, navigation and the footer. Shop, whitelist and transactions
-- own their widgets and state in separate page modules; the other business pages stay here.
--
-- Permission gate mirrors the server (ECAdmin.lua gate()): role *name* lists compared exactly
-- against the client-only getAccessLevel(), plus the native role-editing capability for the
-- handful of options that decide who the admins are. The server re-checks every command; this
-- side only decides what to draw and what to enable, and collapses when a right is taken away.
--
-- Transport rules (no framework, ECClient stays untouched):
--   * replies land in C.handlers["admin.*"] (registered at the bottom of this file) and are routed
--     to the live instance only;
--   * one in-flight request per command; the 650 ms client cooldown covers the server's 500 ms
--     throttle window (ECServer.lua COMMAND_COOLDOWN_MS), with a timeout after TIMEOUT_MS;
--   * every reply is matched against the request that is still open (username / requestId), so a
--     late answer cannot land on a different player or a closed dialog.
--
-- Rows and text wrapping rebuild on data, filter or geometry changes. The frame callback owns
-- shared polling, deferred sends and timeouts, and delegates the active transaction page's tick.
--
-- Engine references (snapshot 42.20.4-20260826):
--   getAccessLevel()             LuaManager.java:4435-4436 (client only; "" when unavailable)
--   getRoles()                   LuaManager.java:3359-3365 -> Roles.getRoles (client and
--                                dedicated both answer; read through EC.roleChoices)
--   Role.getName / getPosition   Role.java:41-43 / :73-75 (exact, case sensitive; Roles.java:302-305)
--   Capability.RolesWrite        Role.java:185-191, the gate of vanilla's own role editor
--                                (ISRolesList.lua:20/110); read through EC.canManageSettings
--   Clipboard.setClipboard(str)  core/Clipboard.java:52-59
--   ISTextEntryBox               ISUI/ISTextEntryBox.lua:321-341 (new -> initialise ->
--                                instantiate; family-verified use in
--                                MinidoracatMiniMap_Search.lua:393-395), setMultipleLine :85-95,
--                                setMaxTextLength :170-172, getInternalText :158-160
--   #string under Kahlua counts UTF-16 units, the same unit the server counts reason chars in
--   (StringLib.java:760-768), so the local reason length check matches ECAdmin.reasonError.

require "ISUI/ISPanel"

if not MinidoracatEconomy or not MinidoracatEconomy.Client or not MinidoracatEconomy.Client.UI then
    require "MinidoracatEconomy/ECWidgets"
end
require "MinidoracatEconomy/ECDatePicker"
require "MinidoracatEconomy/ECAdminFilters"
require "MinidoracatEconomy/ECAdminTransactions"
require "MinidoracatEconomy/ECAdminShop"
require "MinidoracatEconomy/ECAdminWhitelist"
require "MinidoracatEconomy/ECAdminRecovery"
require "MinidoracatEconomy/ECAdminSeasons"
require "MinidoracatEconomy/ECAdminAccounts"
require "MinidoracatEconomy/ECRowActions"
require "MinidoracatEconomy/ECPlayerPicker"
require "MinidoracatEconomy/ECItemNames"
require "ISUI/ISComboBox"
require "MinidoracatEconomy/ECDetailWindow"
local EC = MinidoracatEconomy
local C = EC.Client
local U = C.UI
local DatePicker = C.DatePicker
local Filters, Transactions = C.AdminFilters, C.AdminTransactions
local R, PlayerPicker = C.RowActions, C.PlayerPicker
local filterCreate, filterKinds = Filters.create, Filters.kinds
local filterLayoutKinds, filterLayoutRow = Filters.layoutKinds, Filters.layoutRow
local filterDraw, filterOptions, filterEnable = Filters.draw, Filters.options, Filters.enable
local blurFilterDates = Filters.blurDates
local filterCloseCombo = Filters.closeCombo
-- Every read-only record this page can show goes to the one session detail window: it scrolls,
-- it copies the untruncated text and it closes on its own X or Escape, so no table here pays
-- rows for an inline preview band.
local D = C.DetailWindow

local P = {}
C.AdminPanel = P

local PAD, T = U.PAD, U.T
local CARD_TITLE_H = U.CARD_TITLE_H
local fontH = U.fontH
local color, fill, border, text, textWidth, fitText, textRight, textCentre = U.color, U.fill, U.border, U.text, U.textWidth, U.fitText, U.textRight, U.textCentre
local stampText, amountText, signedText, hasBit, kindText, card, drawCoin = U.stampText, U.amountText, U.signedText, U.hasBit, U.kindText, U.card, U.drawCoin
local Button, TableCell = U.Button, U.TableCell
local rowBackground = U.rowBackground

-- U.fill scales every fill by the window opacity slider (U.alpha). The money views need one
-- backdrop that ignores it: their text is read against the numbers, and at 50 % opacity the
-- selected row's secondary text measured 1.00:1 against the world showing through
-- (.omc/tmp/colour-audit.json). This paints at full alpha without touching the stored setting.
local function fillSolid(el, x, y, w, h, token)
    U.theme:fill(el, x, y, w, h, token, "rect", 1)
end

-- "Recovery" sits beside "Player" on purpose: what the whole server is holding back is a question
-- of its own, not something a host should have to reach by guessing account names one at a time.
-- "Seasons" sits beside "Settings" for the same reason the season length lives in the option
-- schema: rotating a season and deciding how long the next one runs are the same rare,
-- deliberate act, and both of them take the native role capability rather than the write role.
local TABS = { "Player", "Recovery", "Dashboard", "Currencies", "Sources", "Shop", "Whitelist", "Listings", "Auctions", "Transactions", "Audit", "System", "Settings", "Seasons" }
local COMMANDS = { "admin.lookup", "admin.adjust", "admin.freeze", "admin.config", "admin.audit", "admin.auditFile", "admin.auditDetail", "admin.system", "admin.icons", "admin.sources", "admin.players", "admin.accounts", "admin.receipts", "admin.option", "admin.catalog", "admin.currency", "admin.listings", "admin.auctions", "admin.whitelist", "admin.marketHistory", "admin.transactions", "admin.transaction", "admin.recovery", "admin.seasons" }
local PATH_KEYS = { "root", "events", "receipts", "audit", "heartbeat", "icons" }
local EXCHANGE_FIELDS = { "pointsPerCoin", "perOrderMin", "perOrderMax", "perAccountDaily", "serverDaily" }

local COOLDOWN_MS = 650      -- server window is 500 ms; the margin covers clock jitter (a repeat inside the window is dropped silently -> 8 s timeout)
local TIMEOUT_MS = 8000
local POLL_MS = 30000
local PERM_POLL_MS = 500
local ICONS_RECHECK_MS = 2500   -- an icon reload reads a few KB per tick; the outcome is asked for after this
local AUDIT_LIMIT = 500
local PLAYERS_DEBOUNCE_MS = 250   -- keystrokes are coalesced; the server also throttles per command
local AUCTION_DEBOUNCE_MS = 650   -- the auction search box (both modes) asks once the typing stops, never per key; the server drops a repeat inside 500 ms
local REASON_MAX = 1000
local NAME_MAX = 24
local ROW_ACTION_GAP = 6          -- between two row buttons, and between the strip and the amount
local AUDIT_DETAIL_TRIES = 3      -- a server that keeps answering "busy" is asked this often, then left alone
local ACCOUNT_BYTES = 64          -- ECAdmin's own bound for an account / actor name
local FILTER_DEBOUNCE_MS = 650    -- an exact name typed into a filter box: one read per pause, never one per key

-- ---------- permissions (no UI, no session required) ----------

-- The player's own role name, exactly as the engine spells it: role lookup is case sensitive
-- (Roles.java:302-305) and a host-made role may contain spaces, so nothing is folded or split.
local function accessLevel()
    if type(getAccessLevel) ~= "function" then return "" end
    local ok, level = pcall(getAccessLevel)
    if not ok or type(level) ~= "string" then return "" end
    return level
end

-- A role list option, as this client has to read it. EC.sandbox alone would answer with the
-- sandbox *file*, because EC.optionOverride is the server's ModData reader and is never
-- installed here: an admin granted by a runtime change would see no panel at all until the
-- server restarted. The config broadcast (C.options) carries the very snapshot the settings
-- page paints, so it wins, and the file is what is left before any snapshot has arrived.
local function roleOption(key, default)
    local state = C.options and C.options[key]
    if state ~= nil and state.value ~= nil then return state.value end
    return EC.sandbox(key, default)
end

function P.canWrite()
    local level = accessLevel()
    if level == "" then return false end
    return EC.roleSet(roleOption("AdminRoles", "admin"))[level] == true
end

-- The native role-editing capability, and nothing this mod hands out: whoever already owns the
-- server's roles keeps a way into the page that decides who the economy's admins are, even
-- after moving their own role out of AdminRoles. It is not economy write permission -- it opens
-- the options marked manageOnly and the page they live on, nothing else.
function P.canManage()
    return EC.canManageSettings(getPlayer())
end

function P.canRead()
    if P.canWrite() or P.canManage() then return true end
    local level = accessLevel()
    if level == "" then return false end
    return EC.roleSet(roleOption("ReadOnlyRoles", "moderator"))[level] == true
end

-- Paying yourself is the write role plus a grant of its own: the actor's exact role has to be
-- listed in AdminSelfAdjustRoles, which is empty by default (nobody). A missing or unreadable
-- list is never "everyone", and it never unlocks freezing your own account.
function P.canSelfAdjust()
    if not P.canWrite() then return false end
    local level = accessLevel()
    if level == "" then return false end
    return EC.roleSet(roleOption("AdminSelfAdjustRoles", ""))[level] == true
end

-- ---------- transport ----------

local sentAt = {}        -- command -> ms of the last send (client cooldown)
local pendingAt = {}     -- command -> ms of the request still waiting for a reply
local deferred = {}      -- command -> { args, at }: held until the server's 500 ms window has passed
local requestSeq = 0

-- The server drops a repeat of the same command from the same player inside 500 ms
-- (ECServer COMMAND_COOLDOWN_MS) without replying. A click that lands right after an automatic
-- request (status re-check, page poll) used to be refused with a red "too fast": instead the
-- request is held and sent when the window has passed. `pendingAt` is set at once so the
-- buttons disable and the timeout clock starts from the click.
local function send(command, args)
    local player = getPlayer()
    if not player then return false, "no_player" end
    local now = EC.now()
    if pendingAt[command] then return false, "busy" end
    pendingAt[command] = now
    local last = sentAt[command]
    if last and now - last < COOLDOWN_MS then
        deferred[command] = { args = args or {}, at = last + COOLDOWN_MS }
        return true
    end
    sentAt[command] = now
    sendClientCommand(player, EC.COMMAND_MODULE, command, args or {})
    return true
end

local function flushDeferred(now)
    local player = getPlayer()
    if not player then return end
    for command, d in pairs(deferred) do
        if now >= d.at then
            deferred[command] = nil
            sentAt[command] = now
            sendClientCommand(player, EC.COMMAND_MODULE, command, d.args)
        end
    end
end

local function isPending(command)
    return pendingAt[command] ~= nil
end

-- market.sellers is the one command a page hands to a control instead of calling itself, so the
-- requestId that reserved the slot is remembered here: the reply frees the slot by matching it,
-- which keeps a stale answer from releasing a newer read and keeps a box folded away by a page
-- switch from holding the slot until the timeout.
local lastSellersRequestId = nil
local function sendSellers(command, args)
    lastSellersRequestId = args.requestId
    return send(command, args)
end

local function newRequestId()
    requestSeq = requestSeq + 1
    return "b7-" .. tostring(EC.now()) .. "-" .. tostring(requestSeq)
end

-- Kahlua strings are UTF-16 units (#s counts characters); standard Lua holds UTF-8 bytes, so
-- count non-continuation bytes there. Mirrors ECAdmin.reasonError.
local WIDE_STRINGS = pcall(string.char, 19981)
local function charCount(s)
    if WIDE_STRINGS then return #s end
    local n = 0
    for i = 1, #s do
        local b = string.byte(s, i)
        if b < 128 or b >= 192 then n = n + 1 end
    end
    return n
end

-- ---------- small helpers ----------

local function lineH() return fontH.small + 6 end
local function rowH() return math.max(26, fontH.small + 12) end
local function entryH() return math.max(26, fontH.small + 12) end
local function btnH() return math.max(28, fontH.medium + 10) end

local function tr(key) return getText(T .. key) end

-- One season survival figure, worded the way the season pages word it. The server states hours;
-- U.survivalText splits whole game minutes into days / hours / minutes, so this side and the
-- player's own card can never disagree about the rounding. A figure the server could not
-- establish -- or did not send -- is unknown, never zero: zero reads as a life that ended at
-- once, which is the opposite of "we do not know".
local function survivalFigure(known, hours)
    local value = tonumber(hours)
    if not known or value == nil or value ~= value or value < 0 then
        return tr("Season_SurvivalUnknown")
    end
    return U.survivalText(math.floor(value * 60))
end

-- shared, allocation-free label lookups
local ISSUE_PERIODS = { "today", "week", "month" }
local ISSUE_FIELDS = {
    { "checkin", "Admin_Dash_Checkin", "+" }, { "milestone", "Admin_Dash_Milestone", "+" },
    { "mint", "Admin_Dash_Mint", "+" }, { "buyback", "Admin_Dash_Buyback", "+" },
    { "burn", "Admin_Dash_Burn", "-" },
}
-- Stands in for a rollup window the reply did not carry: every field of it reads nil, which the
-- painters turn into a dash instead of a zero. Shared, so the hot path allocates nothing.
local EMPTY_ROW = {}

local function exchangeLabel(field)
    return tr("Admin_Cur_" .. string.upper(string.sub(field, 1, 1)) .. string.sub(field, 2))
end

local errorText = U.adminErrorText

local currencyDefs = U.currencyDefs

local currencyDef = U.currencyDef

local currencyName = U.currencyName

-- Source display names arrive as { CH = ..., EN = ... }. The language option cannot change
-- without a restart, so it is read once; getOptionLanguageName is absent on old builds.
local langCode = nil
local function gameLanguage()
    if langCode then return langCode end
    langCode = "EN"
    if type(getCore) == "function" then
        local ok, name = pcall(function() return getCore():getOptionLanguageName() end)
        if ok and type(name) == "string" and name ~= "" then langCode = name end
    end
    return langCode
end

local function sourceName(src)
    local names = src and src.displayName
    if type(names) == "table" then
        local lang = gameLanguage()
        local pick = (lang == "CH" or lang == "CN") and names.CH or names.EN
        if type(pick) ~= "string" or pick == "" then pick = names.EN or names.CH end
        if type(pick) == "string" and pick ~= "" then return pick end
    end
    return tostring(src and src.modId or "-")
end

-- a missing daily burn cap means "no limit" (ECIntegration.setSource stores nil for it)
local function capText(value)
    if value == nil then return tr("Admin_Src_Unlimited") end
    return amountText(value)
end

-- The cap beside a market counter. A limit the reply does not carry is a dash: the count is
-- still the truth, and inventing a bound the server never stated would be read as one.
local function countLimitText(value)
    local n = tonumber(value)
    if n == nil then return "-" end
    return tostring(math.floor(n))
end

-- A figure the server either stated or did not. A dash is not "zero": the money pages are what a
-- dispute is reconciled against, and a 0 the reply never carried would be read as a real balance.
local function numText(value)
    local n = tonumber(value)
    if n == nil then return "-" end
    return amountText(n)
end

-- A duration the reply states in milliseconds, read as whole minutes. A duration it did not
-- state is a dash: "0 minutes online" and "the server did not say" are different answers.
local function minutesText(ms)
    local n = tonumber(ms)
    if n == nil then return "-" end
    return tostring(math.floor(n / 60000))
end

-- A figure the server could only count part of. Once a currency's supply reports `complete =
-- false`, every sum and count it carries excludes the wallet rows it could not read, so each one
-- is a floor and not a total: it is marked as such instead of being printed as if it were the
-- whole truth. `proven` true gives the plain figure back.
local function boundText(value, proven)
    if proven then return numText(value) end
    if tonumber(value) == nil then return "-" end
    return getText(T .. "Admin_Dash_LowerBound", numText(value))
end

-- The three helpers below are file locals on purpose: drawIssued runs every frame, and a closure
-- built per frame is exactly what the framework's hot-path rule forbids (V1.lua:138-139).

local function issuePeriodLabel(period)
    return tr("Admin_Dash_" .. string.upper(string.sub(period, 1, 1)) .. string.sub(period, 2))
end

-- One currency's counters for one window, or nil. The second return is how many days of that
-- window the server could not attribute to this currency.
local function issueRow(issued, period, currency)
    local window = issued[period]
    local byCurrency = type(window) == "table" and window.byCurrency or nil
    local row = type(byCurrency) == "table" and byCurrency[currency] or nil
    if type(row) ~= "table" then return nil, 0 end
    return row, math.floor(tonumber(row.unknownDays) or 0)
end

-- A signed counter. A figure the reply did not carry stays a dash: a printed 0 would claim
-- nothing was issued in that window, which is not what an absent field says.
local function issueText(value, sign, token)
    local n = tonumber(value)
    if n == nil then return "-", "textFaint" end
    return sign .. amountText(n), token
end

-- How many rows of one board belong to each currency ("survivor 12  cat 3"). The reply keys this
-- by currency id; a currency it does not name is a dash, because "no entry" is not "zero rows"
-- on a board the server may simply not have counted yet.
local function boardByCurrencyText(byCurrency)
    if type(byCurrency) ~= "table" then return "-" end
    local out = nil
    for _, id in ipairs(EC.CURRENCY_ORDER) do
        local body = currencyName(id) .. " " .. numText(byCurrency[id])
        out = out and (out .. "   " .. body) or body
    end
    return out or "-"
end

-- What a currency may be used for, as every tag that is true -- never one of two roles. A unit
-- that is tradable on the market and a unit that can be bought back are two independent
-- properties, and a currency can hold both, one or neither.
local function currencyUses(id, def)
    local static = EC.CURRENCIES[id]
    local out = nil
    local function add(key)
        local body = tr("Admin_Cur_Use_" .. key)
        out = out and (out .. ", " .. body) or body
    end
    if static and static.marketUnit then add("Market") end
    -- Two different things, never treated as one: `directTransfer` is a player handing money to
    -- another player, while an `exchange` block is money arriving from outside the game (the
    -- points bridge). A currency can have either, both or neither, so both are asked for
    -- separately -- calling one of them by the other's name would state something untrue about
    -- what the unit can do.
    if static and static.directTransfer then add("Transfer") end
    if type(def) == "table" and type(def.exchange) == "table" then add("External") end
    local caps = def and def.buybackCaps
    if type(caps) == "table" then
        local account, server = tonumber(caps.account), tonumber(caps.server)
        -- the shop stops buying a currency back as soon as either cap is at or below zero
        -- (ECShop reads both), so "can be bought back" needs both of them above it
        if account ~= nil and server ~= nil and account > 0 and server > 0 then add("Buyback") end
    end
    return out or tr("Admin_Cur_Use_None")
end

-- One of the two buyback caps of one currency, as the currency page prints it. nil means the
-- server did not state this cap at all; 0 means the host switched buyback off for this currency
-- on purpose, which is said in words rather than left as a bare number.
local function buybackCapText(def, which)
    local caps = def and def.buybackCaps
    local n = type(caps) == "table" and tonumber(caps[which]) or nil
    if n == nil then return tr("Admin_Cur_BuybackUnset"), "textFaint" end
    if n <= 0 then return tr("Admin_Cur_BuybackOff"), "warn" end
    return amountText(n), "text"
end

-- The sandbox option key behind one of those caps (EC.BUYBACK_OPTIONS, owned by the config
-- slice): the currency page edits the very option the settings page does, so there is one truth
-- about a cap and not a second editor beside it. nil when this build has no key for the pair.
local function buybackOptionKey(id, which)
    local map = EC.BUYBACK_OPTIONS
    local entry = type(map) == "table" and map[id] or nil
    local key = type(entry) == "table" and entry[which] or nil
    if type(key) ~= "string" or key == "" then return nil end
    if EC.OPTION_BY_KEY[key] == nil then return nil end
    return key
end

local function currencyOrder(lookup)
    if lookup and type(lookup.currencies) == "table" and #lookup.currencies > 0 then
        return lookup.currencies
    end
    return EC.CURRENCY_ORDER
end

local function sizeText(bytes)
    local n = tonumber(bytes) or 0
    if n >= 1048576 then return string.format("%.1f MB", n / 1048576) end
    if n >= 1024 then return string.format("%.0f KB", n / 1024) end
    return tostring(math.floor(n)) .. " B"
end

local function agoText(ms, now)
    local diff = math.max(0, (now or EC.now()) - (tonumber(ms) or 0))
    return U.durationText(diff)
end

-- Display form of a server path: everything before the Lua data dir becomes "..." (the cache dir
-- carries the host's user name, which a streaming admin may not want on screen), and when the
-- rest still does not fit the *head* is trimmed so the file name stays readable. The copy button
-- always copies the full path. Cached per (path, width): drawn every frame.
local pathCache = {}
local function pathDisplay(value, maxW)
    local key = value .. "\1" .. tostring(maxW)
    local cached = pathCache[key]
    if cached then return cached end
    local s = value
    local i = string.find(s, "[/\\]Lua[/\\]")
    if i then s = string.sub(s, i) end
    local shown = "..." .. s
    if textWidth(shown) > maxW then
        local low, high, best = 1, #s, ""
        while low <= high do
            local mid = math.floor((low + high) / 2)
            local cut = "..." .. string.sub(s, mid)
            if textWidth(cut) <= maxW then
                best = cut
                high = mid - 1
            else
                low = mid + 1
            end
        end
        shown = best
    end
    pathCache[key] = shown
    return shown
end

-- integer parse for the dialog fields: "-500" / "+30" / "12" only
local function parseInt(str)
    local digits = string.match(tostring(str or ""), "^%s*([%+%-]?%d+)%s*$")
    if not digits then return nil end
    local n = tonumber(digits)
    if not n or n ~= math.floor(n) then return nil end
    return n
end

local newEntry = U.newEntry

local entryText = U.entryText

local setEntryText = U.setEntryText

local setEntryEditable = U.setEntryEditable

-- Column layout for a TableCell table: spec = { { key, header, sample, flex } , ... }.
-- Every column gets max(header, sample) + PAD; one flex column absorbs the rest and carries a
-- width for fitText. `right` columns are measured from their right edge.
local function layoutColumns(list, spec, innerWidth)
    local cols = list.cols
    for i = #cols, 1, -1 do cols[i] = nil end
    local fixed, flexIndex = 0, nil
    local widths = {}
    for i, c in ipairs(spec) do
        if c.flex then
            flexIndex = i
            widths[i] = 0
        else
            widths[i] = math.max(textWidth(c.header), textWidth(c.sample or "")) + PAD
            fixed = fixed + widths[i]
        end
    end
    if flexIndex then
        widths[flexIndex] = math.max(40, innerWidth - PAD - fixed)
    end
    local x = PAD
    for i, c in ipairs(spec) do
        local width = math.min(widths[i], math.max(0, innerWidth - x))
        if c.right then
            cols[i] = { x = x + width - PAD, right = true, width = math.max(0, width - PAD) }
        else
            cols[i] = { x = x, width = math.max(0, width - PAD) }
        end
        x = x + width
    end
    return cols
end

local function drawColumnHeaders(el, list, spec, x, y, h)
    fill(el, x, y, list.width, h, "well", "rect")
    local ty = y + math.floor((h - fontH.small) / 2)
    for i, c in ipairs(spec) do
        local col = list.cols[i]
        if col then
            local label = fitText(c.header, col.width)
            if col.right then
                textRight(el, label, x + col.x, ty, "textMuted")
            else
                text(el, label, x + col.x, ty, "textMuted")
            end
        end
    end
end

local RECEIPT_COLS = nil
local AUDIT_COLS = nil

local function receiptSpec()
    RECEIPT_COLS = {
        { header = tr("Wallet_Col_Time"), sample = U.STAMP_SAMPLE },
        { header = tr("Admin_Col_Currency"), sample = currencyName(EC.CURRENCY_ORDER[1]) },
        { header = tr("Wallet_Col_Amount"), sample = "+999,999", right = true },
        { header = tr("Wallet_Col_Kind"), sample = kindText("admin_adjust") },
        { header = tr("Wallet_Col_Balance"), sample = "999,999,999", right = true },
        { header = tr("Admin_Col_Tx"), sample = "", flex = true },
    }
    return RECEIPT_COLS
end

-- Row action strip of a receipt line: the exact transaction behind it, and nothing else. Every
-- movement of the account is one entry on the account status card -- a property of the account,
-- not of the line that happens to be picked -- so no row repeats it. The detail jump needs the
-- line's own txId, and a line that has none simply has that button disabled.
local RECEIPT_ACTIONS = nil
local function receiptActions()
    if RECEIPT_ACTIONS == nil then
        RECEIPT_ACTIONS = { { id = "detail", label = tr("Admin_Rcpt_Detail") } }
    end
    return RECEIPT_ACTIONS
end

-- Width the strip needs, so the columns can be laid out inside what is left of the row.
local function receiptActionsW()
    local total = PAD
    for _, a in ipairs(receiptActions()) do
        total = total + textWidth(a.label) + 20 + ROW_ACTION_GAP
    end
    return total
end

-- Where each of those buttons sits: once per rebuild, shared by every row.
local function receiptActionGeo(width, chipH, chipY)
    local out = {}
    local x = width - PAD
    local list = receiptActions()
    for i = #list, 1, -1 do
        local a = list[i]
        local bw = textWidth(a.label) + 20
        x = x - bw
        out[i] = { id = a.id, label = a.label, x = math.max(20, x), y = chipY, w = bw, h = chipH }
        x = x - ROW_ACTION_GAP
    end
    return out
end

-- One receipt line: the shared table cell, the selection band and the row's two buttons. The
-- columns were laid out inside the width the strip leaves, so no text is ever painted under
-- them, and the buttons are real children -- a press lands on a button, never on a rectangle.
local ReceiptCell = TableCell:derive("MinidoracatEconomyReceiptCell")

function ReceiptCell:render()
    TableCell.render(self)      -- the base cell owns zebra / selection / hover (U.rowBackground)
    local e = self.entry
    if e == nil or e.actions == nil then return end
    R.begin(self)
    for _, a in ipairs(e.actions) do
        R.put(self, a.id, a.label, a.x, a.y, a.w, a.h, a.id ~= "detail" or e.txId ~= nil)
    end
    R.finish(self)
end

local function auditSpec()
    AUDIT_COLS = {
        { header = tr("Wallet_Col_Time"), sample = U.STAMP_SAMPLE },
        { header = tr("Admin_Audit_Col_Admin"), sample = "admin0000" },
        { header = tr("Admin_Audit_Col_Action"), sample = tr("Admin_Audit_Action_unfreeze") },
        -- the target is a fullType / a DisplayCategory / a SKU id as often as an account now,
        -- and the change column carries a translated "field: before -> after" for the
        -- structural actions: both are budgeted for that, not for a player name and an amount
        { header = tr("Admin_Audit_Col_Target"), sample = "Base.Screwdriver" },
        { header = tr("Admin_Col_Currency"), sample = currencyName(EC.CURRENCY_ORDER[1]) },
        { header = tr("Admin_Audit_Col_Change"), right = true,
            sample = getText(T .. "Admin_Audit_Change", tr("Admin_Audit_Field_category"), tr("Admin_Audit_Value_inherit"), tr("Admin_Audit_Value_exclude")) },
        { header = tr("Admin_Audit_Col_Reason"), sample = "", flex = true },
        { header = tr("Admin_Col_Tx"), sample = "0000000000000:0000" },
    }
    return AUDIT_COLS
end

local function auditActionText(action)
    return getTextOrNull(T .. "Admin_Audit_Action_" .. tostring(action)) or tostring(action)
end

local function configValueText(v)
    local t = type(v)
    if t == "table" then
        if v.rateVersion then return "v" .. tostring(v.rateVersion) end
        return tr("Admin_Cur_Title")
    end
    if t == "boolean" then return v and tr("Admin_On") or tr("Admin_Off") end
    if t == "number" then return amountText(v) end
    if t == "string" and v ~= "" then return v end
    return "-"
end

-- ---------- settings page (runtime option editor) ----------

-- Option controls are measured from the current font and value. The same hit geometry drives
-- painting and clicks; the row's read-only record retains anything its columns must shorten.
local OPTION_TOGGLE_W = 44
local OPTION_TEXT_MAX = 200   -- ECConfig.validateOption's limit for kind = "text"

-- ";" separated sandbox lists read as a sentence ("1, 3, 7"); the separator is per language.
local function listText(value, coins)
    local out = nil
    for part in string.gmatch(tostring(value), "[^;]+") do
        local item = string.match(part, "^%s*(.-)%s*$")
        if item ~= "" then
            if coins then item = amountText(tonumber(item) or 0) end
            out = out and (out .. tr("Admin_Set_ListSep") .. item) or item
        end
    end
    return out or tostring(value)
end

-- A roles option's value as an ordered list of exact native role names. Two shapes arrive: the
-- runtime override is an array (admin.option), the sandbox file half is one ';' string. Nothing
-- is lower-cased and nothing is split on whitespace -- a host-made role may contain spaces, and
-- "Admin" and "admin" are two different roles (Roles.java:302-305).
local function roleList(value)
    local out = {}
    if type(value) == "table" then
        for i = 1, #value do
            local name = value[i]
            if type(name) == "string" and name ~= "" then out[#out + 1] = name end
        end
        return out
    end
    for part in string.gmatch(tostring(value or ""), "[^;]+") do
        local name = (string.gsub(part, "^%s*(.-)%s*$", "%1"))
        if name ~= "" then out[#out + 1] = name end
    end
    return out
end

-- How one role name is shown. Vanilla's own role list translates the built-in names
-- (ISRolesList.lua:50-52, IGUI_RolesList_Role_<name>); a host-made role has no such key and is
-- shown exactly as it was typed -- which is also the only string that may be saved back.
local function roleLabel(name)
    return getTextOrNull("IGUI_RolesList_Role_" .. name) or name
end

-- The whole selected set as one line, and an explicit "nobody" for an empty list: a blank cell
-- would read as "not loaded" where it really means "this list authorises no one".
local function roleSummary(value)
    local names = roleList(value)
    if #names == 0 then return tr("Admin_Roles_None") end
    for i = 1, #names do names[i] = roleLabel(names[i]) end
    return table.concat(names, tr("Admin_Set_ListSep"))
end

-- UTC offset in hours: "+8" for 8.0, "+5:30" for 5.5, "-5" for -5
local function offsetText(n)
    local whole = math.floor(math.abs(n))
    local minutes = math.floor((math.abs(n) - whole) * 60 + 0.5)
    local body = (n < 0 and "-" or "+") .. tostring(whole)
    if minutes > 0 then body = body .. ":" .. (minutes < 10 and "0" or "") .. tostring(minutes) end
    return getText(T .. "Admin_Set_Timezone", body)
end

-- Display form of an option value; the schema's unit decides. Serves the rows, the
-- "overridden (default X)" note and the range hint of the edit dialog.
local function optionValueText(spec, value)
    if value == nil then return tr("Admin_Set_Missing") end
    if spec.kind == "bool" then return tr(value == true and "Admin_On" or "Admin_Off") end
    if spec.kind == "list_int" then return listText(value, spec.unit == "coin") end
    if spec.kind == "roles" then return roleSummary(value) end
    if spec.kind == "text" then return listText(value, false) end
    local n = tonumber(value)
    if n == nil then return tostring(value) end
    if spec.zeroUnlimited and n <= 0 then return tr("Admin_Set_Unlimited") end
    if spec.zeroOff and n <= 0 then return tr("Admin_Off") end
    if spec.unit == "mhz" then return getText(T .. "Admin_Set_Mhz", tostring(math.floor(n / 1000)) .. "." .. tostring(math.floor((n % 1000) / 100))) end
    if spec.unit == "tiles" then return getText(T .. "Admin_Set_Tiles", amountText(n)) end
    if spec.unit == "minutes" then return getText(T .. "Admin_Set_Minutes", amountText(n)) end
    if spec.unit == "hour" then return getText(T .. "Admin_Set_Hour", tostring(math.floor(n))) end
    if spec.unit == "percent" then return getText(T .. "Admin_Set_Percent", tostring(math.floor(n))) end
    if spec.unit == "days" then return getText(T .. "Admin_Set_Days", tostring(math.floor(n))) end
    if spec.unit == "tz" then return offsetText(n) end
    return amountText(n)
end

-- What the edit dialog's box is prefilled with (and what the range hint quotes): the raw value,
-- never its decorated display form -- the box is parsed back with tonumber / EC.parseIntList.
local function optionInputText(spec, value)
    if spec.kind == "list_int" or spec.kind == "text" then return tostring(value or "") end
    local n = tonumber(value)
    if n == nil then return "" end
    if n == math.floor(n) then return tostring(math.floor(n)) end
    return string.format("%.1f", n)
end

-- Toggle colours are the mod's own tokens (the framework's defaults are grey); built once, since
-- the painter takes the table every frame.
local toggleColors = nil
local function optionToggleColors()
    if not toggleColors then
        toggleColors = { on = color("gold"), off = color("well"), knob = color("text"), border = color("border") }
    end
    return toggleColors
end


-- Is this row's control strip dead? Three separate reasons, and they are not the same right:
-- the whole list freezes while a write is in flight or a dialog is up, the manageOnly options
-- need the native role-editing capability, and every other option needs the economy write role.
-- A role manager who is not an economy admin gets exactly those, and an economy admin without
-- the native capability gets everything except them.
local function optionRowOff(list, e)
    if list.optionsDisabled == true then return true end
    if e.manageOnly == true then return list.denyManage == true end
    return list.denyWrite == true
end

local OptionGroupCell = ISPanel:derive("MinidoracatEconomyOptionGroupCell")

function OptionGroupCell:render()
    local id = self.entry
    if not id then return end
    local admin = self.list.admin
    local total, overrides = admin:optionGroupCount(id)
    local active = id == admin.setGroup and admin.setQuery == nil
    U.rowBackground(self)
    if active then fill(self, 0, 0, 2, self.height, "accent", "rect") end
    local tail = overrides > 0 and getText(T .. "Admin_Set_OverrideCount", tostring(overrides))
        or getText(T .. "Admin_Set_Count", tostring(total))
    local ty = math.floor((self.height - fontH.small) / 2)
    textRight(self, tail, self.width - PAD, ty, overrides > 0 and "warn" or "textMuted")
    text(self, fitText(tr("Admin_Set_Group_" .. id), math.max(0, self.width - PAD * 3 - textWidth(tail))),
        PAD, ty, active and "accent" or "text")
end

-- One option row: measured text on the left, native pooled action buttons on the right.
local OptionCell = ISPanel:derive("MinidoracatEconomyOptionCell")

-- Skin.toggle is a rev >= 3 painter: an older framework has no such key, and the painter itself
-- answers false when it declines the geometry. Both fall back to a labelled pill, so a row keeps
-- its switch either way. `off` = the whole list is disabled (a write is in flight, or the role is
-- read only): the painter dims, the fallback greys its label.
local function renderOptionToggle(button)
    local e = button.parent.entry
    if not e then return end
    local w, h, off = button.width, button.height, not button.enable
    if U.Skin and U.Skin.toggle then
        local pok, res = pcall(U.Skin.toggle, button, 0, 0, w, h, e.toggleOn, optionToggleColors(), off and 0.5 or 1)
        if pok and res ~= false then return end
    end
    fill(button, 0, 0, w, h, e.toggleOn and "selected" or "well", "pill")
    border(button, 0, 0, w, h, off and "border" or "accent", "pill")
    textCentre(button, e.toggleLabel, w / 2, math.floor((h - fontH.small) / 2), off and "textFaint" or "text")
end

function OptionCell:prerender()
    local e = self.entry
    if not e then R.reset(self); return end
    U.rowBackground(self)
    local off = optionRowOff(self.list, e)
    R.begin(self)
    for _, hit in ipairs(e.hits) do
        local button = R.put(self, hit.id, hit.label or e.toggleLabel, hit.x,
            math.floor((self.height - e.chipH) / 2), hit.w, e.chipH, not off)
        if hit.id == "toggle" then button.render = renderOptionToggle end
    end
    R.finish(self)
end

function OptionCell:render()
    local e = self.entry
    if not e then return end
    local w = self.width
    local muted = (self.list:isSelected(self.index) or self:isMouseOver()) and "text" or "textMuted"
    if e.prefixText then text(self, e.prefixText, PAD, e.line1Y, muted) end
    text(self, e.nameText, e.nameX, e.line1Y, "text")
    if e.overText then text(self, e.overText, PAD, e.line2Y, "warn") end
    if e.descText ~= "" then text(self, e.descText, e.descX, e.line2Y, muted) end
    if e.runtimeText then text(self, e.runtimeText, e.runtimeX, e.line2Y, "warn") end
    if e.lockedText then textRight(self, e.lockedText, w - PAD, e.line2Y, muted) end
    if e.valueText then
        local token = e.missing and "textFaint" or "accent"
        if e.valueCentre then
            textCentre(self, e.valueText, e.valueX + e.valueW / 2, e.valueY, token)
        else
            textRight(self, e.valueText, e.valueX + e.valueW, e.valueY, token)
        end
    end
end

-- Item display name through the engine's own lookup (LuaManager.java:8579-8583), so the admin
-- reads the same translated name a player sees; an unknown fullType falls back to itself.
local itemName = U.itemName

-- The item's real English name (C.ItemNames: the shipped EN dictionary plus every activated
-- MOD's own EN/ItemName.json), shown faint after the localised name so the host can match a row
-- against the item id on any language; nil when the two read the same or the index has no
-- English for it. script:getDisplayName() is *not* consulted: after OnScriptsLoaded it is the
-- Translator's name (Item.java:493-495), so it was never an English source.
-- The cache is keyed on the index's revision, which moves once when a load finishes.
local itemBaseNames = {}
local itemBaseRev = nil
local function itemBaseName(fullType)
    local names = C.ItemNames
    if itemBaseRev ~= names.revision then
        itemBaseRev = names.revision
        itemBaseNames = {}
    end
    local base = itemBaseNames[fullType]
    if base == nil then
        base = names.english(fullType) or false
        itemBaseNames[fullType] = base
    end
    if not base or base == itemName(fullType) then return nil end
    return base
end

local itemTexture = U.itemTexture

local categoryText = U.categoryText

-- A texture the engine handed out can still be refused by the renderer: ask once, and a refusal
-- clears the entry's icon so the row simply has none from the next frame on. Shared by every
-- list row that carries an item icon; the geometry is computed once per rebuild.
local function paintIcon(cell, e)
    if not e.icon then return end
    local ok = pcall(cell.drawTextureScaled, cell, e.icon, PAD, e.iconY, e.iconSize, e.iconSize, 1, 1, 1, 1)
    if not ok then e.icon = nil end
end

local BalanceCell = ISPanel:derive("MinidoracatEconomyBalanceCell")
function BalanceCell:render()
    local e = self.entry
    if not e then return end
    local coin = math.max(24, fontH.medium + 8)
    local headH = math.max(rowH(), coin + 6, fontH.medium + 8)
    fill(self, 0, 0, self.width, self.height, "well")
    drawCoin(self, e.currency, 4, math.floor((headH - coin) / 2), coin)
    text(self, fitText(e.name, self.width - coin - 18, UIFont.Medium), coin + 10,
        math.floor((headH - fontH.medium) / 2), "text", UIFont.Medium)
    for i, field in ipairs(e.fields) do
        local value = fitText(field[2], self.width - 16)
        local y = headH + (i - 1) * lineH()
        text(self, fitText(field[1], self.width - 22 - textWidth(value)), 8, y, "textMuted")
        U.textRight(self, value, self.width - 8, y, field[3])
    end
end

-- ---------- market listings / auctions page ----------

-- One market row, shared by the listings page and the auctions page: the item's icon plus its
-- translated name (and the script's own name) over a meta line the page owns, the amount, and
-- the row's real action buttons on the right. Every string is computed once per rebuild
-- (Admin:rowChipGeometry / Admin:marketRow); the buttons belong to C.RowActions, so a press
-- lands on a button instead of on a painted rectangle the row had to hit-test itself.
local MarketRowCell = ISPanel:derive("MinidoracatEconomyMarketRowCell")

function MarketRowCell:render()
    local e = self.entry
    if not e then return end
    rowBackground(self)
    paintIcon(self, e)
    text(self, e.nameText, e.nameX, e.line1Y, "text")
    if e.altText then text(self, e.altText, e.altX, e.line1Y, "textFaint") end
    text(self, e.metaText, e.nameX, e.line2Y, "textFaint")
    textRight(self, e.priceText, e.priceRight, e.line1Y, "accent")
    -- a read action (the auctions page's jump to the record) is never disabled with the writes:
    -- looking at what happened is allowed whenever the page itself is
    local write = self.list.optionsDisabled ~= true
    R.begin(self)
    for _, a in ipairs(e.actions) do
        R.put(self, a.id, a.label, a.x, a.y, a.w, a.h, a.read == true or write)
    end
    R.finish(self)
end

-- The row strips of the two market pages, named once: the same tables lay the buttons out
-- (Admin:rowChipGeometry) and answer the click (Admin:onListingAction / onAuctionAction).
-- "This seller" is a read -- it re-asks this very page for that one account's live rows, never
-- the record of rows that are gone -- so it stays live for a read-only role and while a write
-- is in flight.
local LISTING_ACTIONS, AUCTION_ACTIONS = nil, nil

local function listingActions()
    if LISTING_ACTIONS == nil then
        LISTING_ACTIONS = { { id = "seller", label = tr("Admin_Lst_Seller"), read = true },
            { id = "delist", label = tr("Admin_Lst_Delist") } }
    end
    return LISTING_ACTIONS
end

local function auctionActions()
    if AUCTION_ACTIONS == nil then
        AUCTION_ACTIONS = { { id = "seller", label = tr("Admin_Auc_Seller"), read = true },
            { id = "record", label = tr("Auction_History"), read = true },
            { id = "cancel", label = tr("Admin_Auc_Cancel") } }
    end
    return AUCTION_ACTIONS
end

-- An exact account typed into a filter box: byte for byte what the server compares, so it is
-- only trimmed -- never lowercased, and never accepted with a control character or past the
-- server's own bound. nil means "the box holds no usable name"; `bad` tells the two apart, so a
-- name that cannot be asked for is reported instead of silently dropping the condition.
local function exactName(box)
    local raw = string.match(entryText(box), "^%s*(.-)%s*$")
    if raw == "" then return nil, false end
    if #raw > ACCOUNT_BYTES or string.find(raw, "%c") then return nil, true end
    return raw, false
end

-- The exact seller a market reply says it answered for: the server echoes the field it was
-- asked with, so "the whole market" and "this one account" are told apart without guessing.
local function replySeller(args)
    local seller = args.seller
    if type(seller) ~= "string" or seller == "" then return nil end
    return seller
end

-- Fold one of the server's actor lists into the candidate set, keeping the order it arrived in.
local function addActors(names, seen, list)
    if type(list) ~= "table" then return end
    for _, name in ipairs(list) do
        if type(name) == "string" and name ~= "" and not seen[name] then
            seen[name] = true
            names[#names + 1] = name
        end
    end
end

-- DisplayCategory name the way the vanilla inventory paints it (ISInventoryPane.lua:2533): the
-- engine's own IGUI_ItemCat_* key, falling back to the raw script category.
local function itemCategoryName(category)
    local key = tostring(category or "-")
    return getTextOrNull("IGUI_ItemCat_" .. key) or key
end

-- ---------- audit page ----------

-- Every audit action, every field it names and the enumerated values now carry a translation;
-- anything the files do not know falls back to the raw string the server wrote, so a new action
-- added on the server side is still readable here.
--
-- A catalog field is a path into the SKU now, not a flat name: "prices.cat.bidPrice" is the
-- buyback price of one currency, and reading it as one opaque string would make a per-currency
-- change unreadable -- two currencies of the same SKU would look like the same line twice. The
-- path is split, the leaf is translated on its own and the currency is named after it, so the
-- audit says *which* currency's price moved. A leaf with no translation keeps its raw name, and
-- a currency the registry does not know still prints its id (an audit line about a currency that
-- has since been removed must stay readable).
local function auditFieldText(field)
    local raw = tostring(field)
    local direct = getTextOrNull(T .. "Admin_Audit_Field_" .. raw)
    if direct then return direct end
    local currency, leaf = string.match(raw, "^prices%.([^.]+)%.(.+)$")
    if currency ~= nil then
        return getText(T .. "Admin_Audit_FieldCur",
            getTextOrNull(T .. "Admin_Audit_Field_" .. leaf) or leaf, currencyName(currency))
    end
    -- "prices.cat" as a whole: the whole quote of one currency was added or removed
    currency = string.match(raw, "^prices%.([^.]+)$")
    if currency ~= nil then
        return getText(T .. "Admin_Audit_FieldCur", tr("Admin_Audit_Field_prices"),
            currencyName(currency))
    end
    return raw
end

local function auditValueText(value)
    if value == nil then return nil end
    local s = tostring(value)
    return getTextOrNull(T .. "Admin_Audit_Value_" .. s) or s
end

-- What the target column means depends on the action: the whitelist names item fullTypes and
-- DisplayCategories (painted the way the vanilla inventory does), the catalog names its own SKU
-- ids, and a forced delist or an auction cancel names the seller's account -- all of which stay
-- verbatim. Anything else that looks like a fullType is shown by its item name.
local function auditTargetText(action, field, target)
    local raw = tostring(target or "-")
    if action == "whitelist" then
        if field == "reload" then return auditFieldText("reload") end
        if field == "category" then return itemCategoryName(raw) end
        return itemName(raw)
    end
    if action == "catalog" or action == "delist" or action == "auction" then return raw end
    if string.find(raw, ".", 1, true) then return itemName(raw) end
    return raw
end

-- The change column for the structural actions (whitelist / catalog / terminal): "field: before
-- -> after", or the field name alone when the action carries no value pair (a file reload).
-- The money actions keep their signed amount and config keeps its own value pair.
local function auditChangeText(e)
    local field = e.field
    if field == nil or field == "" then return nil end
    local before, after = auditValueText(e.before), auditValueText(e.after)
    if before == nil and after == nil then return auditFieldText(field) end
    return getText(T .. "Admin_Audit_Change", auditFieldText(field), before or "-", after or "-")
end

-- ---------- one player's market history (admin.marketHistory) ----------

-- One history row: "kind / item / xN" over "time / counterparty / reason", the amount on the
-- right. Every string and width is computed once per rebuild (Admin:historyRow), so the cell
-- only paints.
local AdminHistoryCell = U.AdminHistoryCell

-- ---------- write dialog ----------

-- One native dropdown, skinned with the mod's own tokens (the same lines the audit actor box
-- and the shop page use). A list of role names is exactly what ISComboBox is for: it costs one
-- control at any font size, its popup scrolls a long server's roles on its own, and every
-- option is reachable from the keyboard through ECKeyboard's "combo" target.
local function newDialogCombo(owner, onChange)
    local c = ISComboBox:new(0, 0, 160, entryH(), owner, onChange)
    c:initialise()
    c:instantiate()
    -- Restore the parent's stencil pixels after the native text clip (ISComboBox.lua:284-299).
    c.doRepaintStencil = true
    c.backgroundColor = U.color("well")
    c.borderColor = U.color("border")
    c.textColor = U.color("text")
    c.backgroundColorMouseOver = U.color("hover")
    return c
end

-- The exact role name behind the highlighted option, or nil for an empty box.
local function comboRole(combo)
    if combo == nil or combo.selected == nil then return nil end
    local data = combo:getOptionData(combo.selected)
    if type(data) ~= "string" then return nil end
    return data
end

local Dialog = ISPanel:derive("MinidoracatEconomyAdminDialog")

-- field descriptors per mode; `flex` marks the reason box that absorbs the leftover height
local function dialogFields(mode, optionKey)
    -- one option value; no reason box (a per-click toggle must not demand an essay, and the
    -- server audits the change with the actor's name either way)
    if mode == "option" then
        -- No free-text entry: existing unknown names stay visible and the server validates them.
        local spec = optionKey ~= nil and EC.OPTION_BY_KEY[optionKey] or nil
        if spec ~= nil and spec.kind == "roles" then return {} end
        return { { key = "value", label = tr("Admin_Set_Edit"), width = 220, maxLen = OPTION_TEXT_MAX } }
    end
    if mode == "optionReset" then return {} end   -- confirmation only: the warning line is the body
    if mode == "adjust" then
        return {
            { key = "amount", label = tr("Admin_Adjust_Amount"), width = 180, maxLen = 14, hint = tr("Admin_Adjust_AmountHint") },
            { key = "reversal", label = tr("Admin_Adjust_Reversal"), width = 300, maxLen = 40 },
            { key = "reason", label = "", multiline = true, flex = true, maxLen = REASON_MAX },
        }
    end
    if mode == "balanceMax" then
        return {
            { key = "balanceMax", label = tr("Admin_BalanceMax_Field"), width = 160, maxLen = 13, hint = tr("Admin_BalanceMax_Hint") },
            { key = "reason", label = "", multiline = true, flex = true, maxLen = REASON_MAX },
        }
    end
    if mode == "name" then
        return {
            { key = "name", label = getText(T .. "Admin_Name_Field", tostring(NAME_MAX)), width = 220, maxLen = NAME_MAX, hint = tr("Admin_Cur_NameNote") },
            { key = "reason", label = "", multiline = true, flex = true, maxLen = REASON_MAX },
        }
    end
    if mode == "exchange" then
        local list = {}
        for _, field in ipairs(EXCHANGE_FIELDS) do
            list[#list + 1] = { key = field, label = exchangeLabel(field), width = 110, maxLen = 12, half = true }
        end
        list[#list + 1] = { key = "reason", label = "", multiline = true, flex = true, maxLen = REASON_MAX }
        return list
    end
    if mode == "sourceCaps" then
        return {
            { key = "mintCap", label = tr("Admin_Src_MintCap"), width = 140, maxLen = 12 },
            { key = "burnCap", label = tr("Admin_Src_BurnCap"), width = 140, maxLen = 12, hint = tr("Admin_Src_BurnCapNote") },
            { key = "reason", label = "", multiline = true, flex = true, maxLen = REASON_MAX },
        }
    end
    -- freeze / enabled: reason only
    return { { key = "reason", label = "", multiline = true, flex = true, maxLen = REASON_MAX } }
end

function Dialog:createChildren()
    self.boxes = {}
    self.fields = dialogFields(self.mode, self.optionKey)
    for _, f in ipairs(self.fields) do
        local box = newEntry(f.width or 200, f.multiline and (rowH() * 2) or entryH(), {
            maxLen = f.maxLen, multiline = f.multiline, maxLines = 4,
        })
        box.target = self
        box.onTextChangeFunction = Dialog.onFieldChanged
        self.boxes[f.key] = box
        self:addChild(box)
    end
    -- One option whose value is a set of native role names: picked from the server's own role
    -- list, never typed. Two dropdowns -- every role this server has, and the ones this option
    -- authorises -- with an explicit add and remove between them, and a reader underneath that
    -- spells the whole set out: a combo paints one line, and a host has to be able to read all
    -- of what they are about to save before they save it.
    self.roleSpec = nil
    if self.mode == "option" and self.optionKey ~= nil then
        local spec = EC.OPTION_BY_KEY[self.optionKey]
        if spec ~= nil and spec.kind == "roles" then self.roleSpec = spec end
    end
    if self.roleSpec ~= nil then
        -- read once, as the dialog opens: the native list is the server's own, it changes
        -- rarely, and the server validates every name again before it stores anything. nil is
        -- "the engine would not say", which is not the same as "this server has no roles".
        self.roleChoices = EC.roleChoices()
        self.roleSelected = roleList(self.roleValue)
        self.roleCombo = newDialogCombo(self, Dialog.onRoleField)
        self:addChild(self.roleCombo)
        self.roleHaveCombo = newDialogCombo(self, Dialog.onRoleField)
        self:addChild(self.roleHaveCombo)
        local add, remove = tr("Admin_Roles_Add"), tr("Admin_Roles_Remove")
        self.roleAddButton = Button.create(0, 0, textWidth(add) + 24, btnH(), add, self, Dialog.onRoleAdd, "chip")
        self:addChild(self.roleAddButton)
        self.roleRemoveButton = Button.create(0, 0, textWidth(remove) + 24, btnH(), remove, self, Dialog.onRoleRemove, "chip")
        self:addChild(self.roleRemoveButton)
        self.roleReader = U.newReader(self, 200, 60)
        self:fillRoles()
    end
    self.currencyButtons = {}
    if self.mode == "adjust" then
        for _, id in ipairs(currencyOrder(self.admin.lookup)) do
            local title = currencyName(id)
            local b = Button.create(0, 0, textWidth(title) + 22, math.max(20, fontH.small + 6), title, self, Dialog.onCurrency, "chip")
            b.internal = id
            b.active = id == self.currency
            self:addChild(b)
            self.currencyButtons[#self.currencyButtons + 1] = b
        end
    end
    self.confirmButton = Button.create(0, 0, 140, btnH(), self.confirmLabel, self, Dialog.onConfirm, "primary")
    self:addChild(self.confirmButton)
    local cancel = tr("Admin_Cancel")
    self.cancelButton = Button.create(0, 0, textWidth(cancel) + 30, btnH(), cancel, self, Dialog.onCancel, "chip")
    self:addChild(self.cancelButton)
    -- The explicit acceptance of data the server could not prove. It exists only for the one
    -- case that needs it (`requireAccept`, set when a reconciliation record's source is the
    -- player's own save), it starts unticked, and the confirm button stays disabled until it is
    -- ticked -- so accepting unproven data is always a second, deliberate act and never a side
    -- effect of pressing confirm. The server refuses the write without the matching flag
    -- (recovery_unproven_source), so this is the client half of one gate, not the whole gate.
    local accept = tr("Admin_Rec_AcceptUnproven")
    self.acceptButton = Button.create(0, 0, textWidth(accept) + 30, btnH(), accept, self, Dialog.onAccept, "chip")
    self.acceptButton:setVisible(false)
    self:addChild(self.acceptButton)
    self.warnReader = U.newReader(self, 200, 80)
    self.warnReader:setVisible(false)
end

-- Does this server still have a role by that exact name? "Unknown" is not "no": a selection is
-- only marked as gone when the engine really answered and did not name it.
function Dialog:roleExists(name)
    local choices = self.roleChoices
    if choices == nil then return true end
    for i = 1, #choices do
        if choices[i].name == name then return true end
    end
    return false
end

-- Both dropdowns and the summary, rebuilt from the two lists this dialog owns. A selected role
-- the server no longer has keeps its place, marked, so it is removed on purpose instead of
-- disappearing behind a save nobody was shown.
function Dialog:fillRoles()
    local pick, have = self.roleCombo, self.roleHaveCombo
    local wantPick, wantHave = comboRole(pick), comboRole(have)
    pick:clear()
    for _, choice in ipairs(self.roleChoices or {}) do
        pick:addOptionWithData(roleLabel(choice.name), choice.name)
    end
    -- an empty box says why it is empty instead of painting nothing (ISComboBox.lua:294-300)
    pick.noSelectionText = tr("Admin_Roles_Unavailable")
    pick.selected = 1
    if wantPick ~= nil then pick:setSelectedData(wantPick) end
    have:clear()
    local names = self.roleSelected
    local lines = {}
    for i = 1, #names do
        local label = roleLabel(names[i])
        if not self:roleExists(names[i]) then label = getText(T .. "Admin_Roles_Missing", label) end
        have:addOptionWithData(label, names[i])
        lines[i] = label
    end
    have.noSelectionText = tr("Admin_Roles_None")
    have.selected = 1
    if wantHave ~= nil then have:setSelectedData(wantHave) end
    if self.roleChoices == nil then
        -- no list, no save: an authorisation list must never be rewritten against a guess
        self.roleText = tr("Admin_Roles_Unavailable")
    elseif #lines == 0 then
        self.roleText = tr("Admin_Roles_None")
    else
        self.roleText = table.concat(lines, "\n")
    end
end

-- Moving either highlight changes nothing about the set: it only says what the next add or
-- remove would act on. The stale refusal under the controls goes with the move.
function Dialog:onRoleField()
    local hadMessage = self.message ~= nil
    self.message = nil
    if self.admin == nil then return end
    self.admin:updateEnabled()
    if hadMessage then self.admin:layoutDialog() end
end

function Dialog:onRoleAdd()
    local name = comboRole(self.roleCombo)
    if name == nil then return end
    for i = 1, #self.roleSelected do
        if self.roleSelected[i] == name then return end   -- already authorised
    end
    self.roleSelected[#self.roleSelected + 1] = name
    self.message = nil
    self:fillRoles()
    if self.admin then self.admin:updateEnabled(); self.admin:layoutDialog() end
end

function Dialog:onRoleRemove()
    local name = comboRole(self.roleHaveCombo)
    if name == nil then return end
    local out = {}
    for i = 1, #self.roleSelected do
        if self.roleSelected[i] ~= name then out[#out + 1] = self.roleSelected[i] end
    end
    self.roleSelected = out
    self.message = nil
    self:fillRoles()
    if self.admin then self.admin:updateEnabled(); self.admin:layoutDialog() end
end

-- What the command carries: a dense array of exact names in the order they were added. An
-- empty selection is an empty array -- "nobody" -- and never a reset of the override.
function Dialog:roleArgs()
    local out = {}
    for i = 1, #self.roleSelected do out[i] = self.roleSelected[i] end
    return out
end

-- The picker follows the very right the row did: a role manager moves the set, everybody else
-- (an economy admin who is not one included) reads it. Disabled, never hidden, so what is
-- authorised stays readable either way -- and a box that is switched off drops its popup.
function Dialog:setRolesEnabled(on)
    if self.roleSpec == nil then return end
    local pick = on and self.roleChoices ~= nil
    self.roleCombo:setEnabled(pick)
    self.roleAddButton:setEnable(pick and comboRole(self.roleCombo) ~= nil)
    self.roleHaveCombo:setEnabled(on and #self.roleSelected > 0)
    self.roleRemoveButton:setEnable(on and comboRole(self.roleHaveCombo) ~= nil)
    if not pick then filterCloseCombo(self.roleCombo) end
    if not on then filterCloseCombo(self.roleHaveCombo) end
end

-- A native combo popup lives on the UIManager (ISComboBox.lua:200-215) and the popup object is
-- shared between boxes (ISComboBox.SharedPopup), so this takes down its own two and never
-- somebody else's -- filterCloseCombo checks the popup still belongs to the box it is given.
function Dialog:closeCombos()
    filterCloseCombo(self.roleCombo)
    filterCloseCombo(self.roleHaveCombo)
end

function Dialog:onCurrency(button)
    self.currency = button.internal
    for _, b in ipairs(self.currencyButtons) do b.active = b.internal == self.currency end
    self:updateInfo()
end

function Dialog:onFieldChanged()
    local hadMessage = self.message ~= nil
    self.message = nil
    self:updateInfo()
    if hadMessage and self.admin then self.admin:layoutDialog() end
end

-- Ticking (or unticking) the acceptance. Nothing is sent: this only decides whether the confirm
-- button may be pressed at all, and the flag it sets is what the command carries.
function Dialog:onAccept()
    self.accepted = not (self.accepted == true)
    self.acceptButton.active = self.accepted
    self.admin:updateEnabled()
end

function Dialog:onCancel()
    self.admin:closeDialog()
end

function Dialog:onConfirm()
    self.admin:submitDialog(self)
end

-- Info lines are derived from the live lookup snapshot: rebuilt on open, on every field change
-- and whenever a fresh reply lands (never per frame).
function Dialog:updateInfo()
    local info = {}
    local lookup = self.admin.lookup
    if self.mode == "adjust" and lookup then
        local bal = lookup.balances and lookup.balances[self.currency]
        local available = bal and tonumber(bal.available) or 0
        local rev = bal and tonumber(bal.rev) or 0
        local delta = parseInt(entryText(self.boxes.amount)) or 0
        info[#info + 1] = { text = getText(T .. "Admin_Adjust_Balance", amountText(available), amountText(available + delta), tostring(rev)) }
        local today = lookup.adminToday or {}
        local mine = (type(today.currencies) == "table" and today.currencies[self.currency]) or today
        info[#info + 1] = { text = getText(T .. "Admin_Adjust_Daily", currencyName(self.currency),
            amountText(mine.add or 0), amountText(mine.sub or 0), amountText(today.cap or 0)) }
        -- adminToday.serverDaily = { cap, currencies[id] = { add, sub } } (ECAdmin.lookup)
        local server = today.serverDaily
        if type(server) == "table" then
            local used = (type(server.currencies) == "table" and server.currencies[self.currency]) or server
            info[#info + 1] = { text = getText(T .. "Admin_Adjust_Server", amountText(used.add or 0), amountText(used.sub or 0), amountText(server.cap or 0)) }
        end
        info[#info + 1] = { text = getText(T .. "Admin_Adjust_Snapshot", stampText(self.admin.lookupAt or EC.now(), self.admin.offsetMin)), token = "textFaint" }
    elseif self.mode == "exchange" then
        local def = currencyDef(self.currency)
        local ex = def and def.exchange
        if ex then
            info[#info + 1] = { text = getText(T .. "Admin_Cur_RateVersion", tostring(ex.rateVersion or 1)), token = "textFaint" }
        end
    elseif self.mode == "name" then
        local def = currencyDef(self.currency)
        local override = def and def.nameOverride
        if type(override) == "string" and override ~= "" then
            info[#info + 1] = { text = getText(T .. "Admin_Cur_Override", override), token = "textFaint" }
        else
            info[#info + 1] = { text = tr("Admin_Cur_NoOverride"), token = "textFaint" }
        end
    elseif self.mode == "recovery" then
        -- the record this decision is about, spelled out inside the confirmation: the row's own
        -- heading, its key and the revision that is being answered. A host confirming a removal
        -- reads the very identity the command will carry, not a number they have to trust.
        local rec = self.recovery
        if rec ~= nil then
            info[#info + 1] = { text = tostring(rec.headText or rec.key or "-") }
            info[#info + 1] = { text = "key " .. tostring(rec.key or "-"), token = "textFaint" }
            info[#info + 1] = { text = "revision " .. tostring(rec.revision or "-"), token = "textFaint" }
        end
    elseif self.mode == "season" then
        -- the season this rotation replaces, spelled out inside the confirmation: the command
        -- carries that exact id, so a host reads the identity they are authorising instead of
        -- trusting the button to have picked the right one
        info[#info + 1] = { text = "season " .. tostring(self.seasonExpected or "-"), token = "textFaint" }
    elseif self.hintText and self.mode == "option" then
        info[#info + 1] = { text = self.hintText, token = "textFaint" }
    end
    self.info = info
end

-- Row metrics per density level. Level 0 is the comfortable spacing used at the default UI font;
-- 1 and 2 are what a scaled-up font falls back to so the dialog still fits the child area.
local function dialogMetrics(level)
    local small, medium = fontH.small, fontH.medium
    if level == 1 then
        return { gap = 4, entry = math.max(20, small + 8), button = math.max(22, small + 10),
            line = small + 3, title = math.max(22, medium + 6), reason = 20, chip = math.max(18, small + 4) }
    end
    if level >= 2 then
        return { gap = 2, entry = math.max(18, small + 6), button = math.max(20, small + 8),
            line = small + 1, title = math.max(20, medium + 4), reason = 16, chip = math.max(16, small + 2) }
    end
    return { gap = 8, entry = entryH(), button = btnH(), line = lineH(),
        title = math.max(26, medium + 10), reason = math.max(24, rowH() * 3), chip = math.max(22, small + 8) }
end

local function planRowHeight(row, m)
    local kind = row.kind
    if kind == "currency" then return m.chip end
    if kind == "fields" then return m.entry end
    if kind == "rolePick" or kind == "roleHave" then return m.entry end
    if kind == "roleList" then return m.roles end
    if kind == "reason" then return m.reason end
    if kind == "buttons" then return m.button end
    if kind == "accept" then return m.button end
    if kind == "warn" then return m.warn end
    return m.line   -- reasonLabel / info / warn / message
end

function Dialog:layoutInside(maxW, maxH)
    local labelW = 0
    for _, f in ipairs(self.fields) do
        if f.key ~= "reason" then labelW = math.max(labelW, textWidth(f.label)) end
    end
    labelW = math.max(labelW, textWidth(tr("Admin_Adjust_Currency")))
    if self.roleSpec ~= nil then
        labelW = math.max(labelW, textWidth(tr("Admin_Roles_Pick")), textWidth(tr("Admin_Roles_Current")))
    end
    -- 560 wide by default, growing with the window up to 720: the dialog is the admin's main
    -- working surface, not a confirmation popup
    local width = math.min(maxW, math.max(560, math.min(720, math.floor(maxW * 0.7)), labelW + 380))
    -- a long label is truncated instead of pushing its field out of the dialog
    labelW = math.min(labelW, math.max(60, math.floor(width * 0.45)))
    local half = math.floor((width - PAD * 4 - labelW * 2) / 2)
    local pairable = half >= 90
    local warnLines = self.warnText and U.wrapText(self.warnText, math.max(60, width - PAD * 2 - 22), math.huge) or {}
    -- the set spelled out, one role per line: the reader is what keeps a long list readable
    -- (and scrollable) where the dropdown can only ever paint the one option it highlights
    local roleLines = self.roleSpec and U.wrapText(self.roleText or "", math.max(60, width - PAD * 2 - 22), math.huge) or {}
    self.warnReader:setVisible(self.warnText ~= nil)

    -- row plan: title, currency chips (adjust), one row per field (halves pair up when they fit),
    -- reason label + box, info lines, warning, message, buttons
    local rows = {}
    if self.mode == "adjust" then rows[#rows + 1] = { kind = "currency" } end
    local pendingHalf = nil
    for _, f in ipairs(self.fields) do
        if f.key == "reason" then
            if pendingHalf then
                rows[#rows + 1] = { kind = "fields", a = pendingHalf }
                pendingHalf = nil
            end
            rows[#rows + 1] = { kind = "reasonLabel" }
            rows[#rows + 1] = { kind = "reason", field = f }
        elseif f.half and pairable then
            if pendingHalf then
                rows[#rows + 1] = { kind = "fields", a = pendingHalf, b = f }
                pendingHalf = nil
            else
                pendingHalf = f
            end
        else
            rows[#rows + 1] = { kind = "fields", a = f }
        end
    end
    if pendingHalf then rows[#rows + 1] = { kind = "fields", a = pendingHalf } end
    -- the role picker: pick + add, the authorised set + remove, and the set spelled out
    if self.roleSpec ~= nil then
        rows[#rows + 1] = { kind = "rolePick" }
        rows[#rows + 1] = { kind = "roleHave" }
        rows[#rows + 1] = { kind = "roleList" }
    end
    -- The warning goes above the informational lines, and it is not one of them: a dialog that
    -- drops its own warning would be asking for a decision without saying what the decision
    -- means. Only the info and message rows may be dropped on a tight window.
    if self.warnText then rows[#rows + 1] = { kind = "warn" } end
    -- The acceptance sits directly under the warning it answers, and it is a core row like the
    -- warning: a window too small to show it would otherwise leave a confirm button that can
    -- never be enabled.
    if self.requireAccept then rows[#rows + 1] = { kind = "accept" } end
    for _ = 1, #(self.info or {}) do rows[#rows + 1] = { kind = "info" } end
    if self.message then rows[#rows + 1] = { kind = "message" } end
    rows[#rows + 1] = { kind = "buttons" }

    -- first density level whose core rows fit the area the child can give us. Info and message
    -- lines are droppable (see the layout loop), so they do not force a denser level; the
    -- warning is core, and the reason box keeps its full height as long as the rest fits.
    local m, core, total
    for level = 0, 2 do
        m = dialogMetrics(level)
        m.warn = math.min(#warnLines * (fontH.small + 4) + 12,
            math.max(fontH.small + 12, math.floor(maxH * 0.3)))
        m.roles = math.min(#roleLines * (fontH.small + 4) + 12,
            math.max(fontH.small * 2 + 12, math.floor(maxH * 0.25)))
        core, total = m.title + PAD * 2, m.title + PAD * 2
        for _, r in ipairs(rows) do
            local h = planRowHeight(r, m) + m.gap
            total = total + h
            if r.kind ~= "info" and r.kind ~= "message" then core = core + h end
        end
        if core <= maxH then break end
    end
    -- Reason box budget, in this order: (1) at least three lines when the core rows leave room,
    -- (2) the informational rows, (3) whatever is still spare, up to three more lines. The info
    -- rows are the droppable ones, so a tight window loses them before the reason box shrinks.
    local infoH = total - core
    local spare = math.max(0, maxH - core)
    local grow = math.min(spare, math.max(0, rowH() * 3 - m.reason))
    spare = spare - grow
    local shownInfo = math.min(spare, infoH)
    spare = spare - shownInfo
    grow = grow + math.min(spare, rowH() * 3)
    local reasonH = m.reason + grow
    local height = math.min(maxH, core + grow + shownInfo)

    self.rows = rows
    self.titleH = m.title
    self.gap = m.gap
    self.labelW = labelW
    self:setWidth(width)
    self:setHeight(height)

    -- buttons are anchored to the bottom so the controls are always reachable; the rows above are
    -- laid out top-down and an informational row that would collide with them is dropped.
    local buttonsY = height - PAD - m.button
    local y = m.title + PAD
    local infoIndex = 0
    local fieldX = PAD * 2 + labelW
    local fieldW = math.max(60, width - PAD - fieldX)
    for _, r in ipairs(rows) do
        local h = planRowHeight(r, m)
        if r.kind == "reason" then h = reasonH end
        if r.kind == "buttons" then
            r.y, r.h = buttonsY, m.button
            local slot = math.floor((width - PAD * 2 - 6) / 2)
            local confirmW = math.max(90, math.min(textWidth(self.confirmLabel, UIFont.Medium) + 40, slot))
            local cancelW = math.max(60, math.min(textWidth(tr("Admin_Cancel")) + 30, slot))
            self.confirmButton:setWidth(confirmW)
            self.confirmButton:setHeight(m.button)
            self.confirmButton:setX(width - PAD - confirmW)
            self.confirmButton:setY(buttonsY)
            U.setButtonTitle(self.confirmButton, self.confirmLabel, UIFont.Medium)
            self.cancelButton:setWidth(cancelW)
            self.cancelButton:setHeight(m.button)
            self.cancelButton:setX(self.confirmButton.x - 6 - cancelW)
            self.cancelButton:setY(buttonsY)
            U.setButtonTitle(self.cancelButton, tr("Admin_Cancel"))
        elseif y + h > buttonsY - m.gap and (r.kind == "info" or r.kind == "message") then
            r.skip = true
            r.h = 0
            if r.kind == "info" then infoIndex = infoIndex + 1; r.index = infoIndex end
        else
            r.y, r.h = y, h
            if r.kind == "warn" then
                self.warnReader:setX(PAD); self.warnReader:setY(y)
                self.warnReader:setWidth(width - PAD * 2); self.warnReader:setHeight(h)
                U.setWrappedText(self.warnReader, self.warnText, self.warnReader.width)
            end
            if r.kind == "accept" then
                local acceptW = math.min(textWidth(self.acceptButton.fullTitle) + 30,
                    width - PAD * 2)
                self.acceptButton:setVisible(true)
                self.acceptButton:setWidth(acceptW); self.acceptButton:setHeight(h)
                self.acceptButton:setX(PAD); self.acceptButton:setY(y)
                self.acceptButton.active = self.accepted == true
                U.setButtonTitle(self.acceptButton, self.acceptButton.fullTitle)
            end
            if r.kind == "currency" then
                local cx = fieldX
                local slot = math.floor((width - PAD - cx) / math.max(1, #self.currencyButtons)) - 4
                for _, b in ipairs(self.currencyButtons) do
                    b:setWidth(math.max(30, math.min(textWidth(b.fullTitle or b.title) + 22, slot)))
                    b:setHeight(h)
                    b:setX(cx); b:setY(y)
                    U.setButtonTitle(b, b.fullTitle or b.title)
                    cx = cx + b.width + 4
                end
            elseif r.kind == "fields" then
                local box = self.boxes[r.a.key]
                box:setY(y); box:setHeight(h)
                if r.b then
                    box:setX(fieldX); box:setWidth(half)
                    local second = self.boxes[r.b.key]
                    second:setX(PAD * 3 + labelW * 2 + half); second:setY(y)
                    second:setWidth(half); second:setHeight(h)
                else
                    box:setX(fieldX)
                    box:setWidth(math.min(r.a.width or 200, fieldW))
                end
            elseif r.kind == "reason" then
                local box = self.boxes.reason
                box:setX(PAD); box:setY(y)
                box:setWidth(width - PAD * 2); box:setHeight(h)
            elseif r.kind == "info" then
                infoIndex = infoIndex + 1
                r.index = infoIndex
            elseif r.kind == "rolePick" or r.kind == "roleHave" then
                local pick = r.kind == "rolePick"
                local combo = pick and self.roleCombo or self.roleHaveCombo
                local button = pick and self.roleAddButton or self.roleRemoveButton
                local label = button.fullTitle or button.title
                local bw = math.min(math.max(60, textWidth(label) + 24), math.floor(fieldW / 3))
                local cw = math.max(60, fieldW - bw - 6)
                combo:setX(fieldX); combo:setY(y)
                combo:setWidth(cw); combo:setHeight(h)
                button:setX(fieldX + cw + 6); button:setY(y)
                button:setWidth(bw); button:setHeight(h)
                U.setButtonTitle(button, label)
            elseif r.kind == "roleList" then
                self.roleReader:setX(PAD); self.roleReader:setY(y)
                self.roleReader:setWidth(width - PAD * 2); self.roleReader:setHeight(h)
                U.setWrappedText(self.roleReader, self.roleText or "", self.roleReader.width)
            end
            y = y + h + m.gap
        end
    end
end

function Dialog:prerender()
    local w, h = self.width, self.height
    fill(self, 0, 0, w, h, "surface")
    border(self, 0, 0, w, h, "accent")
    fill(self, 0, 0, w, self.titleH, "surfaceTitle", true)
    text(self, fitText(self.titleText, w - PAD * 2, UIFont.Medium), PAD, math.floor((self.titleH - fontH.medium) / 2), "text", UIFont.Medium)
    local labelX = PAD
    for _, r in ipairs(self.rows or {}) do
        if not r.skip then
            local ty = r.y + math.floor((r.h - fontH.small) / 2)
            if r.kind == "currency" then
                text(self, fitText(tr("Admin_Adjust_Currency"), self.labelW), labelX, ty, "textMuted")
            elseif r.kind == "fields" then
                text(self, fitText(r.a.label, self.labelW), labelX, ty, "textMuted")
                if r.b then
                    text(self, fitText(r.b.label, self.labelW), self.boxes[r.b.key].x - PAD - self.labelW, ty, "textMuted")
                elseif r.a.hint then
                    local box = self.boxes[r.a.key]
                    local hintX = box.x + box.width + PAD
                    text(self, fitText(r.a.hint, math.max(0, self.width - PAD - hintX)), hintX, ty, "textFaint")
                end
            elseif r.kind == "reasonLabel" then
                text(self, fitText(tr("Admin_Adjust_Reason"), self.width - PAD * 2), labelX, r.y, "textMuted")
            elseif r.kind == "info" then
                local info = self.info[r.index]
                if info then
                    text(self, fitText(info.text, self.width - PAD * 2), labelX, r.y, info.token or "text")
                end
            elseif r.kind == "rolePick" then
                text(self, fitText(tr("Admin_Roles_Pick"), self.labelW), labelX, ty, "textMuted")
            elseif r.kind == "roleHave" then
                text(self, fitText(tr("Admin_Roles_Current"), self.labelW), labelX, ty, "textMuted")
            elseif r.kind == "message" and self.message then
                text(self, fitText(self.message.text, self.width - PAD * 2), labelX, r.y, self.message.error and "errorText" or "positive")
            end
        end
    end
end

function Dialog:render() end

function Dialog:keyboardTargets()
    local out = {}
    if #self.currencyButtons > 0 then
        out[#out + 1] = { kind = "group", label = tr("Trade_Currency"), controls = self.currencyButtons }
    end
    for _, field in ipairs(self.fields) do
        out[#out + 1] = { kind = "entry",
            label = field.key == "reason" and tr("Admin_Adjust_Reason") or field.label,
            control = self.boxes[field.key] }
    end
    -- the picker walks in the order it is operated: choose a role, add it, then the set that is
    -- already authorised, remove from it, and the reader that spells the whole set out
    if self.roleSpec ~= nil then
        out[#out + 1] = { kind = "combo", label = tr("Admin_Roles_Pick"), control = self.roleCombo }
        out[#out + 1] = { kind = "button", label = self.roleAddButton.fullTitle or self.roleAddButton.title,
            control = self.roleAddButton }
        out[#out + 1] = { kind = "combo", label = tr("Admin_Roles_Current"), control = self.roleHaveCombo }
        out[#out + 1] = { kind = "button", label = self.roleRemoveButton.fullTitle or self.roleRemoveButton.title,
            control = self.roleRemoveButton }
        out[#out + 1] = { kind = "scroll", label = self.titleText, control = self.roleReader, focusable = false }
    end
    if self.warnReader:getIsVisible() then
        out[#out + 1] = { kind = "scroll", label = self.titleText,
            control = self.warnReader, focusable = false }
    end
    -- the gate is a control like any other: a keyboard user ticks it before the confirm button
    -- will take their Enter
    if self.acceptButton:getIsVisible() then
        out[#out + 1] = { kind = "button", label = self.acceptButton.fullTitle,
            control = self.acceptButton }
    end
    out[#out + 1] = { kind = "group", label = self.confirmLabel,
        controls = { self.cancelButton, self.confirmButton } }
    return out
end

-- swallow clicks so the page underneath cannot be operated while the dialog is open
function Dialog:onMouseDown(x, y) return true end
function Dialog:onMouseUp(x, y) return true end
function Dialog:onMouseMove(dx, dy) return true end

function Dialog:unfocusAll()
    for _, box in pairs(self.boxes or {}) do
        pcall(function() box:unfocus() end)
    end
    -- a native popup outlives its box (it is a UIManager root), so leaving takes it too
    self:closeCombos()
end

-- ---------- admin panel ----------

local Admin = ISPanel:derive("MinidoracatEconomyAdminPanel")

function Admin:createChildren()
    self.subTabButtons = {}
    for _, tab in ipairs(TABS) do
        local title = tr("Admin_Tab_" .. tab)
        local b = Button.create(0, 0, textWidth(title) + 28, 26, title, self, Admin.onSubTab)
        b.internal = tab
        b.active = tab == self.tab
        self:addChild(b)
        self.subTabButtons[#self.subTabButtons + 1] = b
    end

    local refresh = tr("Admin_Refresh")
    self.refreshButton = Button.create(0, 0, textWidth(refresh) + 24, 22, refresh, self, Admin.onRefreshClick, "chip")
    self:addChild(self.refreshButton)

    -- player page, two modes: the whole account list (ECAdminAccounts) or the one account the
    -- lookup is operating on. The list is where a host arrives -- "who holds what" needs nothing
    -- typed in first -- and picking a row carries that account into the operate mode.
    self.accListButton = Button.create(0, 0, 120, entryH(), tr("Admin_Accounts_ModeList"), self, Admin.onPlayerMode, "chip")
    self.accListButton.internal = "list"
    self.accListButton.active = self.playerMode == "list"
    self:addChild(self.accListButton)
    self.accLookupButton = Button.create(0, 0, 120, entryH(), tr("Admin_Accounts_ModeLookup"), self, Admin.onPlayerMode, "chip")
    self.accLookupButton.internal = "lookup"
    self.accLookupButton.active = self.playerMode == "lookup"
    self:addChild(self.accLookupButton)
    self.playerModeButtons = { self.accListButton, self.accLookupButton }

    -- player page: the shared account picker owns the search box and its candidate list (it is
    -- created last, so that list paints over everything); this chip re-reads whatever it holds
    local look = tr("Admin_Player_Search")
    self.lookupButton = Button.create(0, 0, textWidth(look) + 26, entryH(), look, self, Admin.onLookupClick, "chip")
    self:addChild(self.lookupButton)
    self.adjustButton = Button.create(0, 0, 150, btnH(), tr("Admin_Player_Adjust"), self, Admin.onAdjustClick, "primary")
    self:addChild(self.adjustButton)
    self.freezeButton = Button.create(0, 0, 150, btnH(), tr("Admin_Player_Freeze"), self, Admin.onFreezeClick, "chip")
    self:addChild(self.freezeButton)
    self.receiptList = U.newTable(ReceiptCell, rowH())
    self.receiptList.onSelect = function(_, item) self:onReceiptRow(item) end
    self.receiptList.onRowAction = function(_, item, id) self:onReceiptAction(item, id) end
    self:addChild(self.receiptList)
    -- the account's whole money flow: one entry, on the status card
    self.moneyButton = Button.create(0, 0, 120, btnH(), tr("Admin_Rcpt_Money"), self, Admin.onMoneyClick, "chip")
    self:addChild(self.moneyButton)
    -- and what the account holds on the two markets: the counters are read from the lookup, and
    -- these two carry the account over as an exact seller
    self.lstJumpButton = Button.create(0, 0, 120, btnH(), tr("Admin_Player_ViewListings"), self, Admin.onPlayerListings, "chip")
    self:addChild(self.lstJumpButton)
    self.aucJumpButton = Button.create(0, 0, 120, btnH(), tr("Admin_Player_ViewAuctions"), self, Admin.onPlayerAuctions, "chip")
    self:addChild(self.aucJumpButton)
    -- and what the server is still holding back for it: the reconciliation desk, under the very
    -- line of the status card that counts those records
    self.recoveryButton = Button.create(0, 0, 120, btnH(), tr("Admin_Rec_Open"), self, Admin.onRecoveryOpen, "chip")
    self:addChild(self.recoveryButton)
    self.statusReader = U.newReader(self, 200, 100)
    local summaryH = math.max(rowH(), fontH.medium + 14) + lineH() * 3 + 8
    self.summaryList = U.newTable(BalanceCell, summaryH)
    self.summaryList.onSelect = function(_, item)
        if item then self:showDetail("balance", item.id, item.name, item.detailText) end
    end
    self:addChild(self.summaryList)
    self.freezeAuditButton = Button.create(0, 0, 120, btnH(), tr("Admin_Player_FreezeAudit"), self, Admin.onFreezeAudit, "chip")
    self:addChild(self.freezeAuditButton)
    self.modalGuard = U.newModalGuard(self)

    -- currencies page
    self.renameButton = Button.create(0, 0, 120, btnH(), tr("Admin_Cur_Rename"), self, Admin.onRenameClick, "chip")
    self:addChild(self.renameButton)
    self.toggleButton = Button.create(0, 0, 120, btnH(), tr("Admin_Cur_Disable"), self, Admin.onToggleClick, "chip")
    self:addChild(self.toggleButton)
    self.rateButton = Button.create(0, 0, 120, btnH(), tr("Admin_Cur_EditRate"), self, Admin.onRateClick, "chip")
    self:addChild(self.rateButton)
    self.balanceMaxButton = Button.create(0, 0, 120, btnH(), tr("Admin_Cur_EditBalanceMax"), self, Admin.onBalanceMaxClick, "chip")
    self:addChild(self.balanceMaxButton)
    self.iconsButton = Button.create(0, 0, 120, btnH(), tr("Admin_Cur_ReloadIcons"), self, Admin.onIconsClick, "chip")
    self:addChild(self.iconsButton)
    -- The two buyback caps of the selected currency. Both edit the very sandbox option the
    -- settings page edits (EC.BUYBACK_OPTIONS -> admin.option), so a cap has one truth and this
    -- page is a shortcut to it, never a second store. A build whose config slice has no key for
    -- the pair simply keeps the chip disabled instead of writing somewhere else.
    self.buybackAccountButton = Button.create(0, 0, 120, btnH(), tr("Admin_Cur_EditBuybackAccount"), self, Admin.onBuybackCapClick, "chip")
    self.buybackAccountButton.internal = "account"
    self:addChild(self.buybackAccountButton)
    self.buybackServerButton = Button.create(0, 0, 120, btnH(), tr("Admin_Cur_EditBuybackServer"), self, Admin.onBuybackCapClick, "chip")
    self.buybackServerButton.internal = "server"
    self:addChild(self.buybackServerButton)
    -- "who holds this": the account list, sorted by this currency, descending
    self.curHoldersButton = Button.create(0, 0, 120, btnH(), tr("Admin_Cur_ViewHolders"), self, Admin.onCurrencyHolders, "chip")
    self:addChild(self.curHoldersButton)

    -- dashboard: the issued card reads one currency at a time (five sources over three windows
    -- is a table, and two of them side by side in a third of the window would be unreadable), and
    -- every supply column carries its own entry into the account list
    self.dashIssueButtons = {}
    for _, id in ipairs(EC.CURRENCY_ORDER) do
        local b = Button.create(0, 0, 90, 22, currencyName(id), self, Admin.onDashIssueCurrency, "chip")
        b.internal = id
        b.active = id == self.dashCurrency
        self:addChild(b)
        self.dashIssueButtons[#self.dashIssueButtons + 1] = b
    end
    self.dashHolderButtons = {}
    for _, id in ipairs(EC.CURRENCY_ORDER) do
        local b = Button.create(0, 0, 90, 22, tr("Admin_Dash_ViewHolders"), self, Admin.onDashHolders, "chip")
        b.internal = id
        self:addChild(b)
        self.dashHolderButtons[#self.dashHolderButtons + 1] = b
    end
    -- What the issued figures do and do not count is a paragraph, not a caption: the card has
    -- one narrow column and fitText would cut it, so the whole text goes to the session's detail
    -- window (it wraps, it scrolls, CopyAll takes it whole) and this chip is the disclosure.
    self.dashNoteButton = Button.create(0, 0, 90, 22, tr("Admin_Dash_Note"), self, Admin.onDashNote, "chip")
    self:addChild(self.dashNoteButton)

    -- sources page
    self.srcCapsButton = Button.create(0, 0, 120, btnH(), tr("Admin_Src_EditCaps"), self, Admin.onSourceCapsClick, "primary")
    self:addChild(self.srcCapsButton)
    self.srcToggleButton = Button.create(0, 0, 120, btnH(), tr("Admin_Src_Disable"), self, Admin.onSourceToggleClick, "chip")
    self:addChild(self.srcToggleButton)
    self.currencyReader = U.newReader(self, 100, 100)
    self.sourceReader = U.newReader(self, 100, 100)
    self.systemReader = U.newReader(self, 100, 100)

    -- audit page: the search box and the action chips share the top row, the dates / sort / page
    -- chips get their own line under it. Both are local filters over what the two reads carried.
    self.auditEntry = newEntry(220, entryH(), { maxLen = 64, clear = true, placeholder = tr("Admin_Audit_Hint") })
    self.auditEntry.target = self
    self.auditEntry.onTextChangeFunction = Admin.onAuditQueryChanged
    self:addChild(self.auditEntry)
    self.auditF = filterCreate(self, {
        label = auditActionText,
        sorts = { "time" }, fields = { time = "ts" },
        extra = { { "rolled", tr("Admin_Audit_Rolled") } },
        fromLabel = tr("Admin_Audit_From"), toLabel = tr("Admin_Audit_To"),
        onChange = function(panel) panel:onAuditFilterChanged() end,
    })

    -- The exact actor: the administrator whose own actions are read. The server compares it byte
    -- for byte *before* the ring slice and the file tail are cut, so the page never filters an
    -- already truncated read. The box takes any name -- an administrator who has since lost the
    -- role, or one the candidate list was too short to carry -- and the combo beside it offers
    -- the candidates the server listed for the interval it read; picking one fills the box.
    self.auditActorEntry = newEntry(160, entryH(), { maxLen = ACCOUNT_BYTES, clear = true,
        placeholder = tr("Admin_Audit_ActorHint") })
    self.auditActorEntry.target = self
    self.auditActorEntry.onTextChangeFunction = Admin.onAuditActorTyped
    self.auditActorEntry.onCommandEntered = function() self:applyAuditActor() end
    self:addChild(self.auditActorEntry)
    local actorCombo = ISComboBox:new(0, 0, 140, entryH(), self, Admin.onAuditActorPicked)
    actorCombo:initialise()
    actorCombo:instantiate()
    actorCombo.doRepaintStencil = true
    actorCombo.backgroundColor = color("well")
    actorCombo.borderColor = color("border")
    actorCombo.textColor = color("text")
    actorCombo.backgroundColorMouseOver = color("hover")
    actorCombo:addOptionWithData(tr("Filter_All"), "")
    actorCombo:setWidthToOptions(140)
    self.auditActorCombo = actorCombo
    self:addChild(actorCombo)
    -- the shared filter row hosts one combo of its own (the money page puts its account class
    -- there): here it is the actor candidates
    self.auditF.accountCombo = actorCombo
    self.auditF.accountLabel = tr("Admin_Audit_Actor")
    self.auditF.accountW = actorCombo.width
    self.auditList = U.newTable(TableCell, rowH())
    self.auditList.onSelect = function(_, item)
        self:onAuditRow(item)
    end
    self:addChild(self.auditList)
    -- detail strip under the table: two copy chips over the selected line's own strings
    self.auditCopyNameButton = Button.create(0, 0, 90, 22, tr("Admin_Audit_CopyName"), self, Admin.onAuditCopy, "chip")
    self.auditCopyNameButton.internal = "name"
    self:addChild(self.auditCopyNameButton)
    self.auditCopyIdButton = Button.create(0, 0, 90, 22, tr("Admin_Audit_CopyId"), self, Admin.onAuditCopy, "chip")
    self.auditCopyIdButton.internal = "id"
    self:addChild(self.auditCopyIdButton)

    -- system page: one copy button per path
    self.copyButtons = {}
    local copy = tr("Admin_Sys_Copy")
    for _, key in ipairs(PATH_KEYS) do
        local b = Button.create(0, 0, textWidth(copy) + 20, 20, copy, self, Admin.onCopyPath, "chip")
        b.internal = key
        self:addChild(b)
        self.copyButtons[#self.copyButtons + 1] = b
    end

    self.shopPage = C.AdminShop.create(self, isPending)
    self:addChild(self.shopPage)
    self.whitelistPage = C.AdminWhitelist.create(self, isPending)
    self:addChild(self.whitelistPage)

    -- listings page: the search box, the listing list and the two page chips. A row carries one
    -- control, so the click needs the row-local x and y.
    self.lstEntry = newEntry(220, entryH(), { maxLen = 64, clear = true, placeholder = tr("Market_Search") })
    self.lstEntry.target = self
    self.lstEntry.onTextChangeFunction = Admin.onListingSearch
    self:addChild(self.lstEntry)
    -- The exact seller: a condition of its own, compared byte for byte on the server. Typing the
    -- box lists the accounts that really have something on the board (market.sellers -- the same
    -- public read the player pages use), and the condition only moves when a whole candidate is
    -- picked or Enter is pressed over a name typed out in full. The keyword box keeps whatever
    -- it holds: a name that merely contains the text is not this question. The box itself is
    -- built with the account picker at the end of this function, so its candidate list lands
    -- over the table it drops across.
    self.lstSellerClearButton = Button.create(0, 0, 90, 22, tr("Admin_Mkt_SellerClear"), self,
        Admin.onListingSellerClear, "chip")
    self:addChild(self.lstSellerClearButton)
    self.lstPrevButton = Button.create(0, 0, 80, 22, tr("Market_Prev"), self, Admin.onListingPage, "chip")
    self.lstPrevButton.internal = -1
    self:addChild(self.lstPrevButton)
    self.lstNextButton = Button.create(0, 0, 80, 22, tr("Market_Next"), self, Admin.onListingPage, "chip")
    self.lstNextButton.internal = 1
    self:addChild(self.lstNextButton)
    self.listingsList = U.newTable(MarketRowCell, lineH() * 2 + 12)
    -- the row body only reads: picking one spells the whole record out in the shared detail
    -- window, and the delist button on the right is the one thing that can arm a write
    self.listingsList.onSelect = function(_, item) self:onListingRow(item) end
    self.listingsList.onRowAction = function(_, item, id) self:onListingAction(item, id) end
    self:addChild(self.listingsList)
    -- the same card in history mode: the search box asks for an account (Enter, or a pause,
    -- sends admin.marketHistory) and this list replaces the listing rows
    self.lstEntry.onCommandEntered = function() self:onListingEnter() end
    self.lstHistoryButton = Button.create(0, 0, 90, 22, tr("Admin_Lst_History"), self, Admin.onListingMode, "chip")
    self:addChild(self.lstHistoryButton)
    self.historyList = U.newTable(AdminHistoryCell, lineH() * 2 + 12)
    self.historyList.onSelect = function(_, row)
        if not row then return end
        self.marketHistoryDetailId = row.id
        self:showDetail("market_history", row.id, tr("Admin_Lst_History"), row.detailText)
    end
    self:addChild(self.historyList)
    -- the history filter row: type / date / sort / page, all of it local to this side
    self.histF = filterCreate(self, {
        label = function(kind) return getTextOrNull(T .. "Market_Kind_" .. tostring(kind)) or tostring(kind) end,
        kindLabel = tr("Filter_Kind"),
        sorts = { "time", "amount" }, fields = { time = "ts", amount = "price" },
        fromLabel = tr("Filter_From"), toLabel = tr("Filter_To"),
        onChange = function(panel) D.close(panel); panel:rebuildHistory() end,
    })

    -- auctions page: the listings card's shape with two modes -- a debounced search box, the
    -- live auction list and the two page chips, or the whole server's auction record over the
    -- shared filter row. A row carries two controls (the record jump and the cancel chip), so
    -- the click needs the row-local x and y.
    self.aucEntry = newEntry(220, entryH(), { maxLen = 64, clear = true, placeholder = tr("Market_Search") })
    self.aucEntry.target = self
    self.aucEntry.onTextChangeFunction = Admin.onAuctionSearch
    self:addChild(self.aucEntry)
    self.aucSellerClearButton = Button.create(0, 0, 90, 22, tr("Admin_Mkt_SellerClear"), self,
        Admin.onAuctionSellerClear, "chip")
    self:addChild(self.aucSellerClearButton)
    self.aucPrevButton = Button.create(0, 0, 80, 22, tr("Market_Prev"), self, Admin.onAuctionPage, "chip")
    self.aucPrevButton.internal = -1
    self:addChild(self.aucPrevButton)
    self.aucNextButton = Button.create(0, 0, 80, 22, tr("Market_Next"), self, Admin.onAuctionPage, "chip")
    self.aucNextButton.internal = 1
    self:addChild(self.aucNextButton)
    self.auctionsList = U.newTable(MarketRowCell, lineH() * 2 + 12)
    -- the row body only reads: picking one spells the whole record out in the shared detail
    -- window. The record jump and the seller jump are reads and stay live for a read-only role;
    -- the cancel button is the only write.
    self.auctionsList.onSelect = function(_, item) self:onAuctionRow(item) end
    self.auctionsList.onRowAction = function(_, item, id) self:onAuctionAction(item, id) end
    self:addChild(self.auctionsList)
    self.aucActiveButton = Button.create(0, 0, 90, 22, tr("Admin_Auc_Active"), self, Admin.onAuctionMode, "chip")
    self.aucActiveButton.internal = "active"
    self.aucActiveButton.active = self.aucMode ~= "history"
    self:addChild(self.aucActiveButton)
    self.aucHistoryButton = Button.create(0, 0, 90, 22, tr("Admin_Auc_History"), self, Admin.onAuctionMode, "chip")
    self.aucHistoryButton.internal = "history"
    self.aucHistoryButton.active = self.aucMode == "history"
    self:addChild(self.aucHistoryButton)
    self.aucHistoryList = U.newTable(AdminHistoryCell, lineH() * 2 + 12)
    self.aucHistoryList.onSelect = function(_, row)
        if not row then return end
        self.auctionHistoryDetailId = row.id
        self:showDetail("auction_history", row.id, tr("Auction_History_Title"), row.detailText)
    end
    self:addChild(self.aucHistoryList)
    -- the record's filter row: type / date / sort / page, all of it local to this side. "time"
    -- sorts on the position the reply gave each line, so newest first is the exact reversal of
    -- the file order the server read.
    self.aucF = filterCreate(self, {
        label = function(kind) return getTextOrNull(T .. "Market_Kind_" .. tostring(kind)) or tostring(kind) end,
        kindLabel = tr("Filter_Kind"),
        sorts = { "time", "amount" }, fields = { time = "ord", amount = "price" },
        fromLabel = tr("Filter_From"), toLabel = tr("Filter_To"),
        onChange = function(panel) D.close(panel); panel:rebuildAuctionHistory() end,
    })

    self.txPage = Transactions.create(self, send, isPending, newRequestId)
    self:addChild(self.txPage)
    -- Native lists keep both the groups and their options scrollable and keyboard-reachable.
    self.setEntry = newEntry(200, entryH(), { maxLen = 32, clear = true, placeholder = tr("Admin_Set_Search") })
    self.setEntry.target = self
    self.setEntry.onTextChangeFunction = Admin.onSettingSearch
    self:addChild(self.setEntry)
    local resetLabel = tr("Admin_Set_ResetGroup")
    self.setResetButton = Button.create(0, 0, textWidth(resetLabel) + 24, 22, resetLabel, self, Admin.onResetGroupClick, "chip")
    self.settingsNav = U.newTable(OptionGroupCell, lineH() + 8)
    self.settingsNav.admin = self
    self.settingsNav:setItems(EC.OPTION_GROUPS)
    self.settingsNav.onSelect = function(_, group) self:onSettingNav(group) end
    self:addChild(self.settingsNav)
    self:addChild(self.setResetButton)
    self.settingsList = U.newTable(OptionCell, lineH() * 2 + 12)
    self.settingsList.onSelect = function(_, item)
        self:onSettingRow(item)
    end
    self.settingsList.onRowAction = function(_, item, action)
        self:onOptionAction(item, action)
    end
    self:addChild(self.settingsList)
    self.setMessageButton = Button.create(0, 0, 1, 1, tr("Admin_Tab_Settings"), self, Admin.onSettingMessage, "chip")
    self.setMessageButton:setVisible(false)
    self:addChild(self.setMessageButton)

    -- last children: the account picker's candidate list paints over the page and takes the
    -- press before the row underneath it (the dialog is added later still, and hides it while
    -- it is open)
    self.picker = PlayerPicker.create(self, send, isPending, newRequestId,
        function(entry) self:onPickedPlayer(entry) end, "player")
    -- the two seller boxes ride the same picker over the public market.sellers read, and are
    -- built here for the same reason: their candidate lists are the last children added, so they
    -- paint over the tables they drop across. The rows behind the pages are still
    -- admin.listings / admin.auctions.
    self.lstSellerPicker = PlayerPicker.create(self, sendSellers, isPending, newRequestId,
        function(entry) self:setListingSeller(entry.username) end, "market", "market.sellers")
    self.lstSellerPicker.entry.onCommandEntered = function() self:applyListingSeller() end
    self.aucSellerPicker = PlayerPicker.create(self, sendSellers, isPending, newRequestId,
        function(entry) self:setAuctionSeller(entry.username) end, "auction", "market.sellers")
    self.aucSellerPicker.entry.onCommandEntered = function() self:applyAuctionSeller() end

    -- The reconciliation page. It is an ordinary sub page (it owns the body area of its own tab,
    -- like the shop, whitelist and money pages) and is added after the candidate lists so its own
    -- surface is never punched through by a popup that belongs to another tab. The write dialog is
    -- added later still, with the modal backdrop raised between the two, so a confirmation always
    -- sits over it. Exactly one instance per page, driven by this page's own prerender: it has no
    -- Events hook and it is never a second window.
    self.recoveryPage = C.AdminRecovery.create(self, isPending)
    self:addChild(self.recoveryPage)

    -- The account list, the player tab's list mode. An ordinary sub page like the shop, the
    -- whitelist and the reconciliation desk: it owns the body area while that mode is on, holds
    -- no popup and no timer, and is driven entirely by this page's own prerender. Added after the
    -- candidate lists so the account picker of the operate mode still paints over everything.
    self.accountsPage = C.AdminAccounts.create(self, isPending)
    self:addChild(self.accountsPage)

    -- The season desk. Another ordinary sub page: it owns the body area of its own tab, holds
    -- no popup of its own (the rotation's confirmation is this controller's dialog) and is
    -- driven entirely by this page's own prerender.
    self.seasonsPage = C.AdminSeasons.create(self, isPending)
    self:addChild(self.seasonsPage)

    self:layout()
end

-- ----- state / actions -----

function Admin:requestClose(callback)
    if self.pendingCatalog or self.pendingWhitelist or self.pendingOption then
        self.message = { text = tr("Admin_Shop_SavePending") }
        return
    end
    if self.tab == "Shop" then self.shopPage:requestLeave(callback)
    else callback() end
end

function Admin:onSubTab(button)
    if self.tab == button.internal or self:isModal() then return end
    self:requestClose(function() self:setTab(button.internal) end)
end

function Admin:setTab(tab)
    if self.tab == tab then return end
    DatePicker.close(self)
    self.tab = tab
    for _, b in ipairs(self.subTabButtons) do b.active = b.internal == tab end
    self.message = nil
    self:closeDialog()
    self.picker:close()
    -- the reconciliation page owns a queue: leaving the tab drops whatever it has not sent and
    -- reports a write still in flight as unknown, instead of resuming behind the host's back
    if self.tab ~= "Recovery" then self:leaveRecovery() end
    -- the season desk has an unsent draft and a read of its own; leaving the tab drops the
    -- focus and the record window, and a read still in flight keeps the slot it owns
    if self.tab ~= "Seasons" then self:leaveSeasons() end
    -- the detail window belongs to the page that opened it: leaving that page closes it
    D.close(self)
    filterCloseCombo(self.auditActorCombo)
    pcall(function() self.setEntry:unfocus() end)
    pcall(function() self.auditActorEntry:unfocus() end)
    self:closeSellerPickers()
    self:layout()
    if C.Keyboard then C.Keyboard.invalidate(self.owner) end
    self:refresh()
end

function Admin:onRefreshClick()
    if self:isModal() then return end
    self.message = nil
    self:refresh()
end

function Admin:onLookupClick()
    local username = self.picker:getText()
    if username == "" then
        self.message = { text = tr("Admin_Player_Hint"), error = true }
        return
    end
    local ok, why = self:requestLookup(username)
    if not ok and why == "throttled" then
        self.message = { text = tr("Admin_Throttled"), error = true }
    end
end

-- Never touches self.message: a background re-read must not overwrite the result of the write the
-- admin just did. A request blocked by the cooldown (or by a lookup still in flight for the old
-- target) is remembered and retried from prerender, so a click is never silently dropped.
function Admin:requestLookup(username)
    if username ~= self.lookupUser then
        -- switching target: drop the old snapshot and any dialog bound to it
        D.close(self)
        self:closeDialog()
        -- the reconciliation page is not touched: it is a tab of its own with its own question
        -- (the whole server, or the account it was asked about), and a lookup on the player page
        -- is no longer what decides whose records it is showing
        self.lookup = nil
        self.lookupError = nil
        self.receiptRows = {}
        self.receiptList:setItems({})
        self:onReceiptRow(nil)
        self.pendingAdjust = nil
        self.pendingFreeze = nil
        self.message = nil
    end
    self.picker:close()
    self.lookupUser = username
    local ok, why = send("admin.lookup", { username = username })
    self.lookupRetryUser = (not ok) and username or nil
    self:updateEnabled()
    return ok, why
end

-- ----- player page rows (candidates, receipts) -----

-- A pick is a lookup: the picker has already put the account in its box and folded its list,
-- so nothing here re-opens it.
function Admin:onPickedPlayer(entry)
    self:requestLookup(tostring(entry.username))
end

-- ----- player page modes (the account list, and the one account being operated on) -----

-- Switching modes moves nothing but the mode: the list keeps its conditions and its rows, the
-- lookup keeps its account, and neither is re-read on the way over. The candidate list of the
-- operate mode is folded away, because it belongs to a box the list mode does not show.
function Admin:setPlayerMode(mode)
    if self.playerMode == mode then return end
    self.playerMode = mode
    for _, b in ipairs(self.playerModeButtons) do b.active = b.internal == mode end
    self.picker:close()
    -- a record opened out of one mode is not a record of the other
    D.close(self)
    self:layout()
    if C.Keyboard then C.Keyboard.invalidate(self.owner) end
    self:refresh()
end

function Admin:onPlayerMode(button)
    if self:isModal() then return end
    self.message = nil
    self:setPlayerMode(button.internal)
end

-- A row of the account list: the very lookup the operate mode does, on the account that was
-- picked. This is the one path from the list into a write, and it goes through requestLookup, so
-- the target change drops the old snapshot and any dialog bound to it exactly as a typed name
-- would.
function Admin:openLookup(username)
    if type(username) ~= "string" or username == "" then return end
    if self:isModal() then return end
    self.picker:setText(username)
    self:setPlayerMode("lookup")
    local ok, why = self:requestLookup(username)
    if not ok and why == "throttled" then
        self.message = { text = tr("Admin_Throttled"), error = true }
    end
end

-- "Who holds this currency", from the dashboard or the currency page: the same list, pointed at
-- one currency and sorted by it. The draft guard is unchanged -- requestClose still asks first,
-- because this is a tab switch like any other.
function Admin:showAccounts(currency)
    self:requestClose(function()
        self.accountsPage:showCurrency(currency)
        self.playerMode = "list"
        for _, b in ipairs(self.playerModeButtons) do b.active = b.internal == "list" end
        if self.tab == "Player" then
            self:layout()
            if C.Keyboard then C.Keyboard.invalidate(self.owner) end
            self:refresh()
        else
            self:setTab("Player")
        end
    end)
end

function Admin:onDashHolders(button)
    self:showAccounts(button.internal)
end

function Admin:onCurrencyHolders()
    self:showAccounts(self:selectedCurrency())
end

function Admin:onDashIssueCurrency(button)
    if self.dashCurrency == button.internal then return end
    self.dashCurrency = button.internal
    for _, b in ipairs(self.dashIssueButtons) do b.active = b.internal == self.dashCurrency end
    -- the note names the currency it is about, so a window that is open follows the chips
    if D.isOpen(self, "dash:issued") then
        D.update(self, "dash:issued", tr("Admin_Dash_Note"), self:issuedNoteText())
    end
end

-- How many days of the widest window the server could not attribute to this currency. The card
-- shows the marker, the note spells the consequence out.
function Admin:issuedUnknownDays()
    local sys = self.system
    local issued = type(sys) == "table" and type(sys.issued) == "table" and sys.issued or nil
    if issued == nil then return 0 end
    local worst = 0
    for _, period in ipairs(ISSUE_PERIODS) do
        local _, days = issueRow(issued, period, self.dashCurrency)
        if days > worst then worst = days end
    end
    return worst
end

-- What the issued figures count, which currency they are about, and -- when some days could not
-- be attributed -- that they are a floor rather than a total.
function Admin:issuedNoteText()
    local body = getText(T .. "Admin_Dash_IssuedFor", currencyName(self.dashCurrency))
    local unknown = self:issuedUnknownDays()
    if unknown > 0 then
        body = body .. "\n\n" .. getText(T .. "Admin_Dash_IssuedPartial", tostring(unknown))
    end
    local lines = { body, "", tr("Admin_Dash_IssuedNote") }
    local issued = self.system and type(self.system.issued) == "table" and self.system.issued or EMPTY_ROW
    for _, period in ipairs(ISSUE_PERIODS) do
        lines[#lines + 1] = "\n" .. issuePeriodLabel(period)
        local row = issueRow(issued, period, self.dashCurrency) or EMPTY_ROW
        for _, field in ipairs(ISSUE_FIELDS) do
            lines[#lines + 1] = tr(field[2]) .. ": " .. issueText(row[field[1]], field[3], "text")
        end
    end
    return table.concat(lines, "\n")
end

-- Pressing the chip again while the note is up closes it, so the one chip is the whole switch.
function Admin:onDashNote()
    if self:isModal() then return end
    if D.isOpen(self, "dash:issued") then
        D.close(self)
        return
    end
    self:showDetail("dash", "issued", tr("Admin_Dash_Note"), self:issuedNoteText())
end

-- The account list's one read. The page owns the conditions; this owns the shared command slot,
-- the cooldown and the requestId a reply is matched against.
function Admin:requestAccounts()
    if not self:readAllowed() then return false end
    local args = self.accountsPage:requestArgs()
    args.requestId = newRequestId()
    if not send("admin.accounts", args) then return false end
    self.accRequestId = args.requestId
    self.accountsPage:onSent(args)
    self:updateEnabled()
    return true
end

-- The currency page's read gate: the registry, the option snapshot the caps live in and the
-- supply figures, in one answer. A read, so a read-only role gets it too.
function Admin:requestCurrency()
    if not self:readAllowed() then return false end
    local args = { requestId = newRequestId() }
    if not send("admin.currency", args) then return false end
    self.curRequestId = args.requestId
    return true
end

-- ----- the shared detail window -----
--
-- A click on a row opens the session's detail window on that record; a rebuild (a poll, a page
-- that came back, a resize) only *updates* a window that is still open, so a record the admin
-- closed never comes back on its own. Every window this page opens belongs to this page, so
-- hiding it, leaving the tab or losing the read right closes them all.
function Admin:showDetail(kind, id, title, body, refreshOnly)
    if id == nil then return end
    local key = kind .. ":" .. tostring(id)
    if refreshOnly then
        D.update(self, key, title, body)
    else
        D.open(self, key, title, body)
    end
end

-- The record a row described is gone (a fresh page dropped it, the target changed): the window
-- is closed only while it is the one still showing that very record.
function Admin:closeDetail(kind, id)
    if id == nil then return end
    if D.isOpen(self, kind .. ":" .. tostring(id)) then D.close(self) end
end

-- Picking a receipt is a read: the whole line is spelled out in the detail window, and the row's
-- own button is the jump to the transaction behind it.
function Admin:onReceiptRow(item, refreshOnly)
    local had = self.selectedReceipt
    self.selectedReceipt = item
    if item == nil then
        if had ~= nil then self:closeDetail("receipt", had.id) end
    else
        self:showDetail("receipt", item.id, tr("Admin_Rcpt_DetailTitle"),
            self:receiptDetailText(item), refreshOnly)
    end
    self:updateEnabled()
end

-- The row's one button, a read: the exact transaction behind this line. It carries the line's
-- own day, because the money page's 62-day limit is a span and not an age -- an old receipt
-- still opens. Every movement of the account is the status card's own entry instead, so the
-- strip does not repeat that jump on every row.
function Admin:onReceiptAction(item, id)
    if item == nil or self.lookupUser == nil then return end
    if id ~= "detail" or item.txId == nil then return end
    self:showTransactions("all", { txId = item.txId, ts = item.ts, account = self.lookupUser })
end

-- The account status card's three entries. The money flow is a property of the account, not of
-- a receipt line, so it never needs one picked; the two market jumps carry the account over as
-- an exact seller, which is exactly what the counters beside them counted.
function Admin:onMoneyClick()
    if self.lookupUser == nil then return end
    self:showTransactions("all", { account = self.lookupUser })
end

function Admin:onPlayerListings()
    self:showSellerListings(self.lookupUser)
end

function Admin:onPlayerAuctions()
    self:showSellerAuctions(self.lookupUser)
end

-- The whole receipt as lines. A field the server did not send is left out entirely: a printed 0
-- would read as a real balance, and these lines are what a dispute is reconciled against.
function Admin:receiptDetailText(e)
    local body = kindText(e.kind) .. " / " .. currencyName(e.currency) .. " / "
        .. signedText(e.amount or 0) .. "\n" .. stampText(e.ts, self.offsetMin)
    if type(e.item) == "string" and e.item ~= "" then
        -- the count is optional as well: a line that names an item without one is printed
        -- without a number, because a 1 the file never carried would be reconciled against
        local qty = tonumber(e.qty)
        body = body .. "\n" .. getText(T .. "Admin_Rcpt_Item", itemName(e.item),
            qty ~= nil and tostring(math.floor(qty)) or "-")
    end
    if e.reasonText then body = body .. "\n" .. getText(T .. "Admin_Rcpt_Reason", e.reasonText) end
    if e.sourceMod then
        body = body .. "\n" .. getText(T .. "Admin_Rcpt_Source", tostring(e.sourceMod))
    end
    if e.before ~= nil or e.after ~= nil then
        body = body .. "\n" .. getText(T .. "Admin_Rcpt_Balance",
            e.before ~= nil and amountText(e.before) or "-",
            e.after ~= nil and amountText(e.after) or "-")
    end
    if e.reservedBefore ~= nil or e.reservedAfter ~= nil then
        body = body .. "\n" .. getText(T .. "Admin_Rcpt_Reserved",
            e.reservedBefore ~= nil and amountText(e.reservedBefore) or "-",
            e.reservedAfter ~= nil and amountText(e.reservedAfter) or "-")
    end
    body = body .. "\n" .. getText(T .. "Admin_Rcpt_Tx", tostring(e.txId or "-"))
    if e.rolled then body = body .. "\n" .. tr("Wallet_RolledBack") end
    return body
end

function Admin:onAuditQueryChanged()
    local q = string.match(entryText(self.auditEntry), "^%s*(.-)%s*$")
    self.auditQuery = q ~= "" and string.lower(q) or nil
    self.auditF.page = 1
    self:rebuildAudit()
end

-- What the two audit reads were last asked for: the exact actor and the day bounds. The dates
-- are the *parsed* bounds, so a half-typed date does not cost a read -- the key only moves once
-- a whole day has been typed.
function Admin:auditFilterKey()
    local f = self.auditF
    local from = EC.parseDay(entryText(f.fromEntry), self.offsetMin)
    local to = EC.parseDay(entryText(f.toEntry), self.offsetMin)
    return tostring(self.auditActor or "") .. "\1" .. tostring(from or "")
        .. "\1" .. tostring(to or "")
end

-- The arguments both audit reads share. The actor and the day bounds go to the server, which
-- narrows the ring slice and the file tail *before* either is cut: the same filter applied on
-- this side would only hide how much of the record it never saw. "to" is the end of that civil
-- day, the exclusive bound the server takes. Every read carries a fresh requestId, so a late
-- answer neither lands on screen nor releases the slot the newer read owns.
function Admin:auditArgs(args)
    local f = self.auditF
    local to = EC.parseDay(entryText(f.toEntry), self.offsetMin)
    args.actor = self.auditActor
    args.fromMs = EC.parseDay(entryText(f.fromEntry), self.offsetMin)
    args.toMs = to and (to + 86400000) or nil
    args.requestId = newRequestId()
    return args
end

function Admin:requestAudit()
    if not self:readAllowed() then return false end
    local args = self:auditArgs({ limit = AUDIT_LIMIT })
    if not send("admin.audit", args) then return false end
    self.auditRequestId = args.requestId
    self.auditSentKey = self:auditFilterKey()
    self:updateEnabled()
    return true
end

function Admin:requestAuditFile()
    if not self:readAllowed() then return false end
    local args = self:auditArgs({})
    if not send("admin.auditFile", args) then return false end
    self.auditFileRequestId = args.requestId
    self.auditFileSentKey = self:auditFilterKey()
    self:updateEnabled()
    return true
end

-- Every chip, date box and page click on the audit row lands here. The action chips, the search
-- box and the page are local to this side; the actor and the day bounds are the server's, so a
-- change to either asks both reads again (prerender re-asks whatever the cooldown refused).
function Admin:onAuditFilterChanged()
    local key = self:auditFilterKey()
    if self.audit == nil or self.auditSentKey ~= key then self:requestAudit() end
    if self.auditFile == nil or self.auditFileSentKey ~= key then self:requestAuditFile() end
    self:rebuildAudit()
end

-- A keystroke in the actor box only arms the clock prerender owns: one read per pause in the
-- typing, never one per key. Enter applies it at once.
function Admin:onAuditActorTyped()
    self.auditActorAt = EC.now()
end

-- The typed actor, applied: exactly what the box holds (never lowercased -- the server compares
-- it byte for byte), and a name the server could never be asked for is reported instead of
-- quietly dropping the condition.
function Admin:applyAuditActor()
    self.auditActorAt = nil
    local name, bad = exactName(self.auditActorEntry)
    if bad then
        self.message = { text = errorText("invalid_args"), error = true }
        return
    end
    if name == self.auditActor then return end
    self.auditActor = name
    self.auditF.page = 1
    self:rebuildAuditActors()
    self:onAuditFilterChanged()
    self:updateEnabled()
end

-- A candidate picked from the combo fills the box and is applied at once: the box stays the one
-- place the actor in force is read from.
function Admin:onAuditActorPicked(combo)
    local value = combo:getOptionData(combo.selected)
    setEntryText(self.auditActorEntry, type(value) == "string" and value or "")
    self:applyAuditActor()
end

-- The actor candidates of one of the two reads: the server's list for the whole window it read,
-- taken before the actor condition narrowed it. It also says when that list was cut short, and
-- the page repeats that instead of presenting a short list as the whole set -- the box still
-- takes a name the list never carried.
function Admin:onAuditActorsReply(source, args)
    local cut = args.actorsTruncated == true
    if source == "file" then
        if type(args.actors) == "table" then self.auditActorsFile = args.actors end
        self.auditActorsFileKey = self.auditFileSentKey
        self.auditFileActorsCut = cut
    else
        if type(args.actors) == "table" then self.auditActorsRing = args.actors end
        self.auditActorsRingKey = self.auditSentKey
        self.auditRingActorsCut = cut
    end
    self.auditActorsTruncated = self.auditFileActorsCut == true or self.auditRingActorsCut == true
    self:rebuildAuditActors()
end

-- The actor candidates the combo offers: the server's own names, never the current role lists
-- and never who happens to be online -- an administrator who has since lost the role is in the
-- record and has to stay pickable. The actor in force stays in the list even when the narrowed
-- read carries no line of his, so the box and the combo cannot disagree about what is running.
function Admin:rebuildAuditActors()
    local names, seen = {}, {}
    local key = self:auditFilterKey()
    if self.auditActorsFileKey == key then addActors(names, seen, self.auditActorsFile) end
    if self.auditActorsRingKey == key then addActors(names, seen, self.auditActorsRing) end
    EC.sortSafe(names, function(a, b) return a < b end)
    if self.auditActor ~= nil and not seen[self.auditActor] then
        names[#names + 1] = self.auditActor
    end
    -- the candidate set in force, as one list: what the combo offers and what the page would
    -- have to say about is the same thing
    self.auditActors = names
    local sig = table.concat(names, "\1") .. "\2" .. tostring(self.auditActor or "")
    if sig == self.auditActorSig then return end
    self.auditActorSig = sig
    local combo = self.auditActorCombo
    filterCloseCombo(combo)
    combo:clear()
    combo:addOptionWithData(tr("Filter_All"), "")
    for _, name in ipairs(names) do combo:addOptionWithData(name, name) end
    -- the box is what the read is built from: the combo only follows it
    local wanted = self.auditActor or ""
    local width = 140
    combo.selected = 1
    for i = 1, #combo.options do
        if combo:getOptionData(i) == wanted then combo.selected = i end
        width = math.max(width, textWidth(combo:getOptionText(i)) + 30)
    end
    self.auditF.accountW = math.min(240, width)
    self:layoutAuditFilters()
end

-- A click in the audit table opens the detail window on that line. The strings themselves are
-- built once, in rebuildAudit; a fresh read re-picks the same line by key, so a full text
-- already read is never asked for twice and the window it is in does not blink.
function Admin:onAuditRow(item, refreshOnly)
    local key = item and item.key or nil
    if item ~= nil and key ~= nil and key == self.auditDetailKey then
        self.auditSelected = item      -- the same line, on a newer page
        self:buildAuditDetail(refreshOnly)
        self:updateEnabled()
        return
    end
    local had = self.auditDetailKey
    self.auditSelected = item
    self.auditDetailEntries = nil
    self.auditDetailRequestId = nil
    self.auditDetailTries = 0
    self.auditDetailKey = key
    self.auditDetailMonth = item and item.month or nil
    if item == nil then
        self.auditDetailState = "idle"
        if had ~= nil then self:closeDetail("audit", had) end
        self:updateEnabled()
        return
    end
    if item.full == true then
        self.auditDetailState = "full"     -- the reply already carried the whole file line
    elseif key == nil or type(self.auditDetailMonth) ~= "string"
        or string.find(self.auditDetailMonth, "^%d%d%d%d%d%d$") == nil then
        -- no usable timestamp means there is no file to open: say summary only, never guess a
        -- month out of the clock
        self.auditDetailState = "none"
    else
        self.auditDetailState = "ring"     -- prerender sends it; a refused send stays here
        self:requestAuditDetail()
    end
    self:buildAuditDetail(refreshOnly)
    self:updateEnabled()
end

-- The full text of one audited action, out of that month's own file (behind the export fence).
-- The key and the month are the server's identity for the line: copied, never rebuilt here.
function Admin:requestAuditDetail()
    if not self:readAllowed() then return false end
    local id = newRequestId()
    if not send("admin.auditDetail",
        { key = self.auditDetailKey, month = self.auditDetailMonth, requestId = id }) then
        return false
    end
    self.auditDetailTries = (self.auditDetailTries or 0) + 1
    self.auditDetailRequestId = id
    self.auditDetailState = "loading"
    self:updateEnabled()
    return true
end

-- The read's own reply, matched against the line that is still picked: a late answer to a row
-- the admin has moved off never lands. A refusal from the shared permission gate carries the
-- requestId alone, so the key / month echo is only compared when the reply has one.
function Admin:onAuditDetailReply(args)
    if self.auditDetailRequestId == nil or args.requestId ~= self.auditDetailRequestId then return end
    self.auditDetailRequestId = nil
    if args.key ~= nil and (args.key ~= self.auditDetailKey or args.month ~= self.auditDetailMonth) then
        return
    end
    local list = type(args.entries) == "table" and args.entries or {}
    local err = args.error
    if err == "ambiguous_record" or (err == nil and #list > 1) then
        -- several legacy lines share this key and disagree: every one of them is shown, and none
        -- is promoted to "the" record
        self.auditDetailState = "ambiguous"
        self.auditDetailEntries = list
    elseif err == "busy" or err == "server_busy" then
        self.auditDetailState = "busy"     -- prerender re-asks, a bounded number of times
    elseif err == "missing" or (err == nil and #list == 0) then
        self.auditDetailState = "missing"
    elseif err ~= nil then
        self.auditDetailState = "read_failed"
    else
        self.auditDetailState = "full"
        self.auditDetailEntries = list
    end
    -- a late answer only updates a window that is still open: a record the admin closed while
    -- the file was being read is not brought back by its own reply
    self:buildAuditDetail(true)
end

-- What the band is showing, and where it came from. A summary is never presented as the record.
function Admin:auditSourceLine()
    local state = self.auditDetailState
    if state == "loading" then return tr("Admin_AuditDetail_Loading") end
    if state == "missing" then return tr("Admin_AuditDetail_Missing") end
    if state == "read_failed" then return tr("Admin_AuditDetail_ReadFailed") end
    if state == "busy" then return tr("Admin_AuditDetail_Busy") end
    if state == "ambiguous" then
        return getText(T .. "Admin_AuditDetail_Ambiguous", tostring(#(self.auditDetailEntries or {})))
    end
    if state == "full" then return tr("Admin_Audit_Source_File") end
    return tr("Admin_Audit_Source_Ring") .. " / " .. tr("Admin_AuditDetail_SummaryOnly")
end

-- The detail window's text: the summary the row was built from, whatever the file added to it,
-- and the one line that says which of the two the reader is looking at.
function Admin:buildAuditDetail(refreshOnly)
    local d = self.auditSelected
    if d == nil then return end
    local body = d.actionText .. " / " .. d.targetText
    if d.rawTarget ~= d.targetText then body = body .. "\n" .. d.rawTarget end
    body = body .. "\n" .. d.adminName .. " / " .. d.stamp .. "\n" .. d.changeFull
    if d.txId ~= nil then body = body .. "\n" .. getText(T .. "Admin_Rcpt_Tx", tostring(d.txId)) end
    body = body .. "\n" .. getText(T .. "Admin_Audit_ReasonLine", d.reasonFull)
    local list = self.auditDetailEntries
    if self.auditDetailState == "full" and list ~= nil and type(list[1]) == "table" then
        local reason = tostring(list[1].reason or "")
        if reason ~= "" and reason ~= d.reasonFull then
            body = body .. "\n" .. getText(T .. "Admin_Audit_FullReason", reason)
        end
    elseif self.auditDetailState == "ambiguous" and list ~= nil then
        for i, rec in ipairs(list) do
            if type(rec) == "table" then
                body = body .. "\n" .. getText(T .. "Admin_Audit_Candidate", tostring(i),
                    stampText(rec.ts, self.offsetMin), tostring(rec.reason or "-"))
            end
        end
    end
    self:showDetail("audit", self.auditDetailKey or d.id, tr("Admin_Audit_Detail"),
        body .. "\n" .. self:auditSourceLine(), refreshOnly)
end

-- The two copy chips: the translated name the admin reads, and the raw id the server wrote
-- (a fullType such as "Base.Screwdriver", the only form a command or a file edit accepts).
function Admin:onAuditCopy(button)
    local d = self.auditSelected
    if d == nil then return end
    local value = button.internal == "id" and d.rawTarget or d.targetText
    if not (Clipboard and Clipboard.setClipboard) then
        self.message = { text = tr("Admin_Sys_CopyFailed"), error = true }
        return
    end
    local ok = pcall(Clipboard.setClipboard, value)
    self.message = ok and { text = getText(T .. "Admin_Audit_Copied", value) }
        or { text = tr("Admin_Sys_CopyFailed"), error = true }
end

function Admin:onCopyPath(button)
    local paths = self.system and self.system.paths
    local path = paths and paths[button.internal]
    if type(path) ~= "string" or path == "" then return end
    if not (Clipboard and Clipboard.setClipboard) then
        self.message = { text = tr("Admin_Sys_CopyFailed"), error = true }
        return
    end
    local ok = pcall(Clipboard.setClipboard, path)
    self.message = { text = ok and tr("Admin_Sys_Copied") or tr("Admin_Sys_CopyFailed"), error = not ok }
end

function Admin:selectedCurrency()
    return self.cfgSelected or EC.CURRENCY_ORDER[1]
end

-- The integration row the action buttons operate on: the clicked one, else the first the
-- server sent (the list is already sorted by modId).
function Admin:selectedSource()
    local list = self.sources or {}
    for _, s in ipairs(list) do
        if s.modId == self.srcSelected then return s end
    end
    return list[1]
end

-- Reader bodies retain full values and their scroll position while a snapshot is refreshed.
local function setReaderContent(reader, value)
    local scroll = reader:getYScroll()
    U.setWrappedText(reader, value, reader.width)
    reader:setYScroll(scroll)
end

local function addReaderLine(lines, label, value)
    lines[#lines + 1] = value == nil and label or (label .. "  " .. tostring(value))
end

function Admin:refreshCurrencyReader(id, def)
    local reader = self.currencyReader
    if reader.ecTarget ~= id then reader:setYScroll(0); reader.ecTarget = id end
    -- the supply figures are part of this card now, so a fresh measurement rebuilds it as surely
    -- as a changed definition does
    if reader.ecSnapshot ~= def or reader.ecIcons ~= self.icons or reader.ecSupply ~= self.supply
        or reader.ecRawText == nil then
        local lines = {}
        if not def then
            lines[1] = tr("Admin_Loading")
        else
            lines[1] = type(def.nameOverride) == "string" and def.nameOverride ~= ""
                and getText(T .. "Admin_Cur_Override", def.nameOverride) or tr("Admin_Cur_NoOverride")
            lines[#lines + 1] = getText(T .. (def.balanceMaxOverride and "Admin_Cur_BalanceMaxOverride" or "Admin_Cur_BalanceMaxDefault"), amountText(def.balanceMax or 0))
            if EC.isIconHash(def.iconHash) and type(def.iconBytes) == "number" then
                lines[#lines + 1] = getText(T .. "Admin_Cur_IconCustom", def.iconHash, tostring(math.floor((def.iconBytes + 1023) / 1024)))
            else
                lines[#lines + 1] = tr("Admin_Cur_IconDefault")
                lines[#lines + 1] = getText(T .. "Admin_Cur_IconHint", def.id .. ".png")
            end
            local status = self.icons and self.icons[def.id]
            if status and status.error then
                local code = tostring(status.error)
                lines[#lines + 1] = getText(T .. "Admin_Cur_IconError", getTextOrNull(T .. "Admin_IconErr_" .. code) or code)
            end
            local ex = def.exchange
            if type(ex) == "table" then
                lines[#lines + 1] = getText(T .. "Admin_Cur_RateVersion", tostring(ex.rateVersion or 1))
                for _, field in ipairs(EXCHANGE_FIELDS) do addReaderLine(lines, exchangeLabel(field), amountText(ex[field] or 0)) end
            else
                lines[#lines + 1] = tr("Admin_Cur_NoExchange")
            end
            -- What the server is holding in this currency, and the two bounds on it. The
            -- per-account bound is the balance cap above; there is no server-wide circulation
            -- cap at all, and that is said in words -- a blank here would be read as "no data",
            -- and a 0 as "nothing may circulate".
            local s = type(self.supply) == "table" and self.supply[id] or nil
            if s == nil then
                lines[#lines + 1] = isPending("admin.currency") and tr("Admin_Loading")
                    or tr("Admin_Cur_SupplyNone")
            else
                local proven = s.complete ~= false
                addReaderLine(lines, tr("Admin_Dash_Total"), boundText(s.total, proven))
                addReaderLine(lines, tr("Admin_Dash_Players"), boundText(s.players, proven))
                addReaderLine(lines, tr("Admin_Dash_Reserved"), boundText(s.reserved, proven))
                addReaderLine(lines, tr("Admin_Dash_Holders"), boundText(s.holders, proven))
                addReaderLine(lines, tr("Admin_Dash_WalletAccounts"), boundText(s.accounts, proven))
                -- The rows the dashboard column is allowed to drop when a scaled-up font leaves
                -- it no height: they have to exist somewhere, and this reader wraps and scrolls,
                -- so this is that somewhere. Without them "the cross-reference is elsewhere"
                -- would not be true of anything.
                addReaderLine(lines, tr("Admin_Dash_System"), boundText(s.system, proven))
                if s.systemReserved ~= nil then
                    addReaderLine(lines, tr("Admin_Dash_SystemReserved"),
                        boundText(s.systemReserved, proven))
                end
                local top = type(s.top) == "table" and s.top or {}
                lines[#lines + 1] = getText(T .. "Admin_Dash_Top", tostring(#top))
                for _, holder in ipairs(top) do
                    addReaderLine(lines, tostring(holder.account or "-"), numText(holder.amount))
                end
                addReaderLine(lines, tr("Admin_Dash_Conserve"),
                    proven and numText(s.net) or tr("Admin_Dash_ConserveUnverifiable"))
                -- the reader wraps, so this is where the unprovable case is stated in full
                local unreadable = tonumber(s.unreadable)
                if unreadable ~= nil and unreadable > 0 then
                    addReaderLine(lines, tr("Admin_Dash_Unreadable"), numText(s.unreadable))
                end
                if s.complete == false then
                    lines[#lines + 1] = getText(T .. "Admin_Cur_ConserveUnprovenNote",
                        numText(s.unreadable))
                end
            end
            addReaderLine(lines, tr("Admin_Dash_AccountCap"), numText(def.balanceMax))
            addReaderLine(lines, tr("Admin_Dash_ServerCap"), tr("Admin_Dash_ServerCapNone"))
            -- the dashboard column has room for the verdict only; the reader wraps, so the
            -- reason there is no such cap is said here in full
            lines[#lines + 1] = tr("Admin_Cur_ServerCapNote")
            -- The two buyback caps. Zero is a decision, not an absence: the shop stops buying
            -- this currency back, which is the opposite of "no limit", so it is spelled out.
            addReaderLine(lines, tr("Admin_Cur_BuybackAccount"), (buybackCapText(def, "account")))
            addReaderLine(lines, tr("Admin_Cur_BuybackServer"), (buybackCapText(def, "server")))
            if buybackOptionKey(id, "account") == nil or buybackOptionKey(id, "server") == nil then
                lines[#lines + 1] = tr("Admin_Cur_BuybackNoOption")
            end
        end
        setReaderContent(reader, table.concat(lines, "\n"))
        reader.ecSnapshot, reader.ecIcons, reader.ecSupply = def, self.icons, self.supply
    else
        setReaderContent(reader, reader.ecRawText)
    end
end

function Admin:refreshSourceReader(selected)
    local reader = self.sourceReader
    local id = selected and selected.modId
    if reader.ecTarget ~= id then reader:setYScroll(0); reader.ecTarget = id end
    local waiting = selected == nil and isPending("admin.sources")
    if reader.ecSnapshot ~= selected or reader.ecOffset ~= self.offsetMin or reader.ecCurrencies ~= C.currencies
        or reader.ecWaiting ~= waiting or reader.ecRawText == nil then
        local lines = {}
        if not selected then
            lines[1] = waiting and tr("Admin_Loading") or tr("Admin_Src_Empty")
        else
            addReaderLine(lines, tr("Admin_Src_Name"), sourceName(selected))
            addReaderLine(lines, tr("Admin_Src_RegisteredAt"), selected.registeredAt and stampText(tonumber(selected.registeredAt) or 0, self.offsetMin) or "-")
            local today = selected.today or {}
            addReaderLine(lines, tr("Admin_Src_Col_Mint"), amountText(today.mint or 0) .. " / " .. amountText(selected.dailyMintCap or 0))
            addReaderLine(lines, tr("Admin_Src_Col_Burn"), amountText(today.burn or 0) .. " / " .. capText(selected.dailyBurnCap))
            local balances = selected.balance or {}
            for _, currency in ipairs(EC.CURRENCY_ORDER) do
                addReaderLine(lines, getText(T .. "Admin_Src_Balance", currencyName(currency)), amountText(balances[currency] or 0))
            end
            lines[#lines + 1] = tr("Admin_Src_BalanceNote")
            lines[#lines + 1] = getText(T .. "Admin_Src_Calls", amountText(today.ok or 0), amountText(today.calls or 0))
            for _, rejected in ipairs(selected.rejectedRows or {}) do
                addReaderLine(lines, getText(T .. "Admin_Src_Rejected", errorText(rejected.code)), amountText(rejected.n))
            end
        end
        setReaderContent(reader, table.concat(lines, "\n"))
        reader.ecSnapshot, reader.ecOffset = selected, self.offsetMin
        reader.ecCurrencies, reader.ecWaiting = C.currencies, waiting
    else
        setReaderContent(reader, reader.ecRawText)
    end
end

function Admin:refreshSystemReader()
    local reader, sys = self.systemReader, self.system
    local second = math.floor(EC.now() / 1000)
    if reader.ecSnapshot ~= sys or reader.ecSecond ~= second or reader.ecOffset ~= self.offsetMin or reader.ecRawText == nil then
        local lines = {}
        if not sys then
            lines[1] = isPending("admin.system") and tr("Admin_Loading") or tr("Admin_Dash_Empty")
        else
            addReaderLine(lines, tr("Admin_Sys_Seq"), amountText(sys.seq or 0))
            local durable = type(sys.durable) == "table" and sys.durable or nil
            addReaderLine(lines, tr("Admin_Sys_Durable"), durable and durable.seq ~= nil and amountText(durable.seq) or tr("Admin_Sys_DurableNone"))
            addReaderLine(lines, tr("Admin_Sys_Epoch"), sys.epoch or "-")
            addReaderLine(lines, tr("Admin_Sys_LoadedSeq"), amountText(sys.loadedSeq or 0))
            lines[#lines + 1] = tr("Admin_Sys_LoadedSeqNote")
            addReaderLine(lines, tr("Admin_Sys_Realm"), sys.realmId or "-")
            lines[#lines + 1] = getText(T .. "Admin_Sys_StartedAt", stampText(sys.startedAt, self.offsetMin))
            lines[#lines + 1] = getText(T .. "Admin_Sys_Version", tostring(sys.version or "-"), tostring(sys.schemaVersion or "-"))
            lines[#lines + 1] = getText(T .. "Admin_Sys_Accounts", tostring(sys.accounts or 0), tostring(sys.frozen or 0))
            addReaderLine(lines, tr("Admin_Sys_Terminals"), amountText(sys.terminals or 0))
            addReaderLine(lines, tr("Admin_Sys_Mailbox"), amountText(sys.mailboxUnclaimed or 0))
            local cat = type(sys.catalog) == "table" and sys.catalog or {}
            -- the catalog now names its failure with a code (file_unreadable / catalog_invalid /
            -- arbitrage_rejected / file_write_failed) plus the file's own text; the code is
            -- translated and the detail is appended, and an older reply that only carried
            -- `error` still reads
            local catError = nil
            if type(cat.errorCode) == "string" and cat.errorCode ~= "" then
                catError = errorText(cat.errorCode)
                if type(cat.errorDetail) == "string" and cat.errorDetail ~= "" then
                    catError = catError .. ": " .. cat.errorDetail
                end
            elseif type(cat.error) == "string" and cat.error ~= "" then
                catError = cat.error
            end
            addReaderLine(lines, tr("Admin_Sys_Catalog"),
                catError or getText(T .. "Admin_Shop_Count", tostring(cat.count or 0)))
            -- The two boards: how many rows are up against the bound, then the per-currency
            -- split, then what is held back. `held` is the fail-closed pile -- rows whose
            -- currency the server could not prove, taken out of trading until a host deals with
            -- them -- so it is named even when it is zero, and a count the reply did not carry
            -- stays a dash instead of reading as "nothing is stuck".
            local market = type(sys.market) == "table" and sys.market or {}
            addReaderLine(lines, tr("Admin_Sys_Listings"), amountText(market.listings or 0) .. " / " .. tostring(market.max or "?"))
            addReaderLine(lines, tr("Admin_Sys_ListingsByCurrency"), boardByCurrencyText(market.byCurrency))
            addReaderLine(lines, tr("Admin_Sys_Held"), numText(market.held))
            local auctions = type(sys.auctions) == "table" and sys.auctions or {}
            addReaderLine(lines, tr("Admin_Sys_Auctions"), amountText(auctions.auctions or 0) .. " / " .. tostring(auctions.max or "?"))
            addReaderLine(lines, tr("Admin_Sys_AuctionsByCurrency"), boardByCurrencyText(auctions.byCurrency))
            addReaderLine(lines, tr("Admin_Sys_Held"), numText(auctions.held))
            -- Buyback is per currency now: the switch is server-wide, the counter and both caps
            -- belong to one currency. A cap at or below zero is what stops that currency, so it
            -- is said in words rather than printed as a bare 0.
            local buyback = sys.buyback
            if type(buyback) == "table" then
                addReaderLine(lines, tr("Admin_Sys_Buyback"),
                    tr(buyback.enabled == true and "Admin_On" or "Admin_Off"))
                local byCurrency = type(buyback.byCurrency) == "table" and buyback.byCurrency or nil
                if byCurrency == nil then
                    lines[#lines + 1] = tr("Admin_Cur_BuybackUnset")
                else
                    for _, id in ipairs(EC.CURRENCY_ORDER) do
                        local b = byCurrency[id]
                        local body
                        if type(b) ~= "table" then
                            body = tr("Admin_Cur_BuybackUnset")
                        else
                            local account, server = tonumber(b.accountCap), tonumber(b.serverCap)
                            local stopped = account ~= nil and server ~= nil
                                and (account <= 0 or server <= 0)
                            body = getText(T .. "Admin_Sys_BuybackValue", numText(b.mintedToday),
                                numText(b.accountCap), numText(b.serverCap))
                            if stopped then body = body .. "  " .. tr("Admin_Cur_BuybackOff") end
                        end
                        addReaderLine(lines, getText(T .. "Admin_Sys_BuybackCurrency", currencyName(id)), body)
                    end
                end
            end
            local exchange = sys.exchange
            if type(exchange) == "table" then
                local today = 0
                for _, value in pairs(type(exchange.depositedToday) == "table" and exchange.depositedToday or {}) do today = today + (tonumber(value) or 0) end
                addReaderLine(lines, tr("Admin_Sys_Exchange"), getText(T .. "Admin_Sys_ExchangeValue", amountText(today), amountText(exchange.tombstones or 0), amountText(exchange.tombstoneMax or 0), tostring(math.floor(tonumber(exchange.inboxFiles) or 0))))
            end
            local whitelist = type(sys.whitelist) == "table" and sys.whitelist or {}
            local counts = type(whitelist.counts) == "table" and whitelist.counts or {}
            addReaderLine(lines, tr("Admin_Sys_Whitelist"), whitelist.error and whitelist.error ~= "" and whitelist.error or tostring(counts.categories or 0))
            addReaderLine(lines, tr("Admin_Sys_Size"), sizeText(sys.sizeEstimate))
            if type(sys.sizeParts) == "table" then
                lines[#lines + 1] = getText(T .. "Admin_Sys_SizeParts", sizeText(sys.sizeParts.ledger), sizeText(sys.sizeParts.admin))
            end
            lines[#lines + 1] = tr("Admin_Sys_SizeNote")
            if sys.auditCount ~= nil then addReaderLine(lines, tr("Admin_Sys_AuditRing"), tostring(sys.auditCount) .. " / " .. tostring(sys.auditMax or "?")) end
            lines[#lines + 1] = tr("Admin_Sys_Export")
            addReaderLine(lines, tr("Admin_Sys_Queued"), amountText(sys.queuedLines or 0))
            local heartbeat = tonumber(sys.heartbeatAt) or 0
            lines[#lines + 1] = heartbeat > 0 and getText(T .. "Admin_Sys_Heartbeat", stampText(heartbeat, self.offsetMin), agoText(heartbeat, EC.now())) or tr("Admin_Sys_HeartbeatNever")
            lines[#lines + 1] = tr("Admin_Sys_HeartbeatNote")
        end
        setReaderContent(reader, table.concat(lines, "\n"))
        reader.ecSnapshot, reader.ecSecond, reader.ecOffset = sys, second, self.offsetMin
    else
        setReaderContent(reader, reader.ecRawText or "")
    end
end

function Admin:onIconsClick()
    self.message = nil
    local ok, err = send("admin.icons", { action = "reload" })
    if not ok then self.message = { text = errorText(err), error = true } end
    self:updateEnabled()
end

function Admin:onRenameClick()
    local id = self:selectedCurrency()
    local dlg = self:openDialog("name", { currency = id, title = getText(T .. "Admin_Name_Title", currencyName(id)), confirm = tr("Admin_Name_Confirm") })
    if dlg then
        local def = currencyDef(id)
        setEntryText(dlg.boxes.name, def and def.nameOverride or "")
    end
end

function Admin:onToggleClick()
    local id = self:selectedCurrency()
    local def = currencyDef(id)
    local target = not (def == nil or def.enabled ~= false)
    self:openDialog("enabled", {
        currency = id, enabledTarget = target,
        title = getText(T .. "Admin_Enable_Title", currencyName(id)),
        confirm = tr("Admin_Enable_Confirm"), warn = tr("Admin_Enable_Warn"),
    })
end

function Admin:onBalanceMaxClick()
    local id = self:selectedCurrency()
    local def = currencyDef(id)
    local dlg = self:openDialog("balanceMax", {
        currency = id, title = getText(T .. "Admin_BalanceMax_Title", currencyName(id)),
        confirm = tr("Admin_BalanceMax_Confirm"), warn = tr("Admin_BalanceMax_Warn"),
    })
    if dlg and def and def.balanceMaxOverride then
        setEntryText(dlg.boxes.balanceMax, tostring(def.balanceMaxOverride))
    end
end

-- One of the selected currency's two buyback caps. The dialog is the settings page's own option
-- editor on the very key EC.BUYBACK_OPTIONS names, so the value is validated, audited and stored
-- exactly like any other sandbox override -- this page adds a shortcut, not a second store. The
-- hint quotes the schema's range, and for a cap whose minimum is 0 it also says what 0 does:
-- buyback of this currency stops, which is not the same as "no limit".
function Admin:onBuybackCapClick(button)
    local id = self:selectedCurrency()
    local key = buybackOptionKey(id, button.internal)
    if key == nil then
        self.message = { text = tr("Admin_Cur_BuybackNoOption"), error = true }
        return
    end
    local spec = EC.OPTION_BY_KEY[key]
    local state = (self.options or {})[key]
    local hint = getText(T .. "Admin_Set_NumberHint", optionInputText(spec, spec.min),
        optionInputText(spec, spec.max))
    -- the schema says which options treat 0 as "off" rather than "no limit" (zeroOff), so the
    -- hint states it from the schema instead of guessing it from the range
    if spec.zeroOff == true then
        hint = hint .. "  " .. tr("Admin_Cur_BuybackZeroHint")
    end
    self:openDialog("option", {
        title = getText(T .. "Admin_Cur_BuybackTitle",
            tr(button.internal == "account" and "Admin_Cur_BuybackAccount" or "Admin_Cur_BuybackServer"),
            currencyName(id)),
        confirm = tr("Admin_Set_Edit"),
        optionKey = key,
        hint = hint,
        value = optionInputText(spec, state and state.value),
    })
end

function Admin:onRateClick()
    local id = self:selectedCurrency()
    local def = currencyDef(id)
    if not (def and type(def.exchange) == "table") then
        self.message = { text = tr("Admin_Cur_NoExchange"), error = true }
        return
    end
    local dlg = self:openDialog("exchange", {
        currency = id, title = getText(T .. "Admin_Exchange_Title", currencyName(id)),
        confirm = tr("Admin_Exchange_Confirm"), warn = tr("Admin_Exchange_Warn"),
    })
    if dlg then
        for _, field in ipairs(EXCHANGE_FIELDS) do
            setEntryText(dlg.boxes[field], tostring(def.exchange[field] or ""))
        end
    end
end

function Admin:onSourceCapsClick()
    local src = self:selectedSource()
    if not src then return end
    local dlg = self:openDialog("sourceCaps", {
        modId = src.modId, title = getText(T .. "Admin_Src_CapsTitle", tostring(src.modId)),
        confirm = tr("Admin_Src_CapsConfirm"),
    })
    if dlg then
        setEntryText(dlg.boxes.mintCap, tostring(src.dailyMintCap or 0))
        setEntryText(dlg.boxes.burnCap, src.dailyBurnCap ~= nil and tostring(src.dailyBurnCap) or "")
    end
end

function Admin:onSourceToggleClick()
    local src = self:selectedSource()
    if not src then return end
    local target = not (src.enabled ~= false)
    self:openDialog("sourceEnabled", {
        modId = src.modId, enabledTarget = target,
        title = getText(T .. (target and "Admin_Src_EnableTitle" or "Admin_Src_DisableTitle"), tostring(src.modId)),
        confirm = tr(target and "Admin_Src_EnableConfirm" or "Admin_Src_DisableConfirm"),
        warn = (not target) and tr("Admin_Src_DisableWarn") or nil,
    })
end

function Admin:onAdjustClick()
    if not self.lookup then return end
    local currency = (self.selectedReceipt and self.selectedReceipt.currency) or currencyOrder(self.lookup)[1]
    local dlg = self:openDialog("adjust", {
        currency = currency,
        title = getText(T .. "Admin_Adjust_Title", tostring(self.lookupUser)),
        confirm = tr("Admin_Adjust_Confirm"), warn = tr("Admin_Adjust_Warn"),
        -- one's own account is only a target with the explicit grant, whichever way the
        -- dialog was reached (the button is disabled too, but a handler never trusts paint)
        allowed = self:writeAllowed() and (not self:isSelfTarget() or self:selfAdjustAllowed()),
        deniedError = self:isSelfTarget() and "self_target" or "forbidden",
    })
    if dlg and self.selectedReceipt and self.selectedReceipt.txId then
        setEntryText(dlg.boxes.reversal, self.selectedReceipt.txId)
        dlg:updateInfo()
    end
end

function Admin:onFreezeClick()
    if not self.lookup then return end
    local target = not (self.lookup.frozen == true)
    self:openDialog("freeze", {
        frozenTarget = target,
        title = getText(T .. (target and "Admin_Freeze_Title" or "Admin_Unfreeze_Title"), tostring(self.lookupUser)),
        confirm = tr(target and "Admin_Freeze_Confirm" or "Admin_Unfreeze_Confirm"),
        warn = target and tr("Admin_Freeze_Warn") or nil,
    })
end

-- ----- settings page actions -----

-- Options of one group: how many there are and how many carry a runtime override. Drives the
-- nav counters and the "reset this group" button; locked options can never be overridden here.
function Admin:optionGroupCount(group)
    local snap = self.options
    local total, overrides = 0, 0
    for _, spec in ipairs(EC.OPTIONS) do
        if spec.group == group then
            total = total + 1
            local state = snap and snap[spec.key]
            if state and state.override == true and spec.locked ~= true and state.locked ~= true then
                overrides = overrides + 1
            end
        end
    end
    return total, overrides
end

-- May this actor change this one option? The options that decide who the economy's admins are
-- (and how far one of them may reach in a day) take the native role-editing capability instead
-- of the write role they hand out -- the people a limit applies to must not be the people who
-- raise it. Everything else takes the write role. The server splits the same way, off the key
-- it looked up itself, so the page never offers a control the server would refuse.
-- `write` / `manage` are the two rights already read by a caller walking the whole schema; a
-- single-row caller omits them and each is read here instead (a read builds a role set).
function Admin:optionAllowed(spec, write, manage)
    if spec == nil then return false end
    if spec.locked == true then return false end
    local state = self.options and self.options[spec.key]
    if state ~= nil and state.locked == true then return false end
    if spec.manageOnly == true or (state ~= nil and state.manageOnly == true) then
        if manage == nil then manage = self:manageAllowed() end
        return manage
    end
    if write == nil then write = self:writeAllowed() end
    return write
end

-- The overridden keys of one group this actor may really reset: the same per-option right the
-- rows are drawn with, so a group reset never does what a single row refuses.
function Admin:overriddenKeys(group)
    local keys = {}
    local snap = self.options
    local write, manage = self:writeAllowed(), self:manageAllowed()
    for _, spec in ipairs(EC.OPTIONS) do
        if spec.group == group and self:optionAllowed(spec, write, manage) then
            local state = snap and snap[spec.key]
            if state and state.override == true then keys[#keys + 1] = spec.key end
        end
    end
    return keys
end

-- Search is a filter over the rows, not a request: the whole option schema is local.
function Admin:onSettingSearch()
    local raw = string.match(entryText(self.setEntry), "^%s*(.-)%s*$")
    local query = raw ~= "" and string.lower(raw) or nil
    if query == self.setQuery then return end
    D.close(self)
    self.setQuery = query
    self.setResetButton:setVisible(self.tab == "Settings" and self:readAllowed() and query == nil)
    self:rebuildSettings()
    self:updateEnabled()
end

function Admin:onSettingNav(group)
    if not self:readAllowed() or self:isModal() then return end
    if not group or group == self.setGroup then return end
    D.close(self)
    self.setGroup = group
    self:rebuildSettings()
    self:updateEnabled()
end

-- Row bodies only read; native row buttons own changes for pointer and keyboard alike.
function Admin:onSettingRow(item)
    if item == nil or not self:readAllowed() or self:isModal() then return end
    self:showDetail("option", item.key, item.plainName, item.detailText)
end
function Admin:onSettingMessage()
    if self.tab ~= "Settings" or not self.message or not self:readAllowed() or self:isModal() then return end
    self:showDetail("settingMessage", "status", tr("Admin_Tab_Settings"), self.message.text)
end


function Admin:onOptionAction(item, id)
    if self.settingsList.optionsDisabled or self:isModal() then return end
    local spec = item.spec
    if not self:optionAllowed(spec) then return end
    local state = (self.options or {})[spec.key]
    local value = state and state.value
    if id == "reset" then
        self:sendOption(spec.key, nil, nil)
    elseif id == "toggle" then
        self:sendOption(spec.key, value ~= true, nil)
    elseif id == "minus" or id == "plus" then
        local base = tonumber(value)
        if base == nil then base = tonumber(spec.default) or spec.min or 0 end
        local target = base + (id == "plus" and (spec.step or 1) or -(spec.step or 1))
        if target < spec.min then target = spec.min end
        if target > spec.max then target = spec.max end
        if target ~= base then self:sendOption(spec.key, target, nil) end
    elseif id == "edit" then
        local hint = nil
        if spec.kind == "list_int" then
            hint = tr("Admin_Set_ListHint")
        elseif spec.kind == "int" or spec.kind == "number" then
            hint = getText(T .. "Admin_Set_NumberHint", optionInputText(spec, spec.min), optionInputText(spec, spec.max))
        end
        self:openDialog("option", {
            title = getText(T .. "Admin_Set_EditTitle", item.plainName),
            confirm = tr("Admin_Set_Edit"),
            optionKey = spec.key,
            hint = hint,
            -- a roles option has no box to prefill; it opens on the set it is about to change
            value = spec.kind ~= "roles" and optionInputText(spec, value) or nil,
            roleValue = value,
            allowed = self:optionAllowed(spec),
            deniedError = spec.manageOnly == true and "manage_settings_required" or "forbidden",
        })
    end
end

-- One write per click. `value == nil` drops the runtime override, so the sandbox file's value is
-- what the server runs with again (Lua tables have no nil member: the key is simply absent).
--
-- Every caller goes through here -- a settings row's chip, its edit dialog, a group reset and
-- the season desk's length chip -- so this is the one place the open write is named. The id is
-- what a reply is matched against *before* the shared slot is freed (matchesReply): an answer
-- to the write before it must not release the write that is open, whichever page sent either.
function Admin:sendOption(key, value, dlg)
    local spec = EC.OPTION_BY_KEY[key]
    if not self:optionAllowed(spec) then
        self:dialogError(dlg, errorText(spec ~= nil and spec.manageOnly == true
            and "manage_settings_required" or "forbidden"))
        return false
    end
    local args = { key = key, requestId = newRequestId() }
    if value ~= nil then args.value = value end
    if not send("admin.option", args) then
        self:dialogError(dlg, tr("Admin_Throttled"))
        return false
    end
    self.optionRequestId = args.requestId
    self.pendingOption = { requestId = args.requestId, key = key }
    if not dlg then self.message = nil end
    self:updateEnabled()
    return true
end

-- Group reset is one command per key: the queue advances on every reply, so the client cooldown
-- (and the server's) is never fought against.
function Admin:nextOptionReset()
    local queue = self.resetQueue
    if queue == nil then return end
    if queue.i > #queue.keys then
        self.resetQueue = nil
        return
    end
    local key = queue.keys[queue.i]
    queue.i = queue.i + 1
    if not self:sendOption(key, nil, nil) then self.resetQueue = nil end
end

function Admin:onResetGroupClick()
    local keys = self:overriddenKeys(self.setGroup)
    if #keys == 0 then return end
    self:openDialog("optionReset", {
        title = tr("Admin_Set_ResetGroup"),
        confirm = tr("Admin_Set_Reset"),
        warn = getText(T .. "Admin_Set_ResetConfirm", tr("Admin_Set_Group_" .. self.setGroup), tostring(#keys)),
        optionGroup = self.setGroup,
        -- overriddenKeys already dropped every option this actor may not reset, so a non-empty
        -- queue is itself the permission this confirmation needs
        allowed = true,
    })
end

-- One write per click; every reply carries the whole catalog back, so nothing is guessed here.
function Admin:sendCatalog(args, dlg)
    if not self:writeAllowed() then
        self:dialogError(dlg, errorText("forbidden"))
        return false
    end
    args.requestId = newRequestId()
    if not send("admin.catalog", args) then
        self:dialogError(dlg, tr("Admin_Throttled"))
        return false
    end
    self.pendingCatalog = { requestId = args.requestId, id = args.id, action = args.action }
    self.catalogRequestId = args.requestId
    if not dlg then self.message = nil end
    self:updateEnabled()
    return true
end

function Admin:requestCatalog()
    if not self:readAllowed() then return false end
    local args = { action = "list", requestId = newRequestId() }
    if not send("admin.catalog", args) then return false end
    self.catalogRequestId = args.requestId
    return true
end

function Admin:requestWhitelist()
    if not self:readAllowed() then return false end
    local args = { action = "status", requestId = newRequestId() }
    if not send("admin.whitelist", args) then return false end
    self.whitelistRequestId = args.requestId
    return true
end

-- ----- market listings actions -----

-- The page and the search text are state, not a request: the read goes out from here when the
-- command is free and is retried from prerender when the cooldown (or an older answer) held it,
-- so a keystroke is never silently dropped.
function Admin:requestListings()
    local args = { action = "list", page = self.lstPage or 1, query = self.lstQuery,
        seller = self.lstSeller, requestId = newRequestId() }
    if not send("admin.listings", args) then return false end
    self.lstRequestId = args.requestId
    self.lstSentQuery = self.lstQuery
    self.lstSentSeller = self.lstSeller
    self.lstSentPage = args.page
    self:updateEnabled()
    return true
end

function Admin:onListingSearch()
    if self.lstMode == "history" then
        -- an account is asked for once the typing stops (Enter does not have to be pressed);
        -- prerender owns the clock, so a fast typist costs one command, not one per key
        self.histQueryAt = EC.now()
        return
    end
    local raw = string.match(entryText(self.lstEntry), "^%s*(.-)%s*$")
    self.lstQuery = raw ~= "" and string.lower(raw) or nil
    self.lstPage = 1
    self:requestListings()
end

-- The exact seller of the live listings page. Typing only lists candidates (the box owns that
-- read and its debounce); the condition moves when a whole candidate is picked, or when Enter is
-- pressed over a name typed out in full. It is a condition of its own: the keyword box keeps
-- whatever it holds, and an account whose name merely *contains* the text is not this question.
function Admin:closeSellerPickers()
    for _, picker in ipairs({ self.lstSellerPicker, self.aucSellerPicker }) do
        picker:close()
        pcall(picker.entry.unfocus, picker.entry)
    end
end

function Admin:setListingSeller(name)
    if name == self.lstSeller then return end
    self.lstSeller = name
    self.lstPage = 1
    self:requestListings()
    self:updateEnabled()
end

-- Enter over the box: what is typed has to be a whole account name, so it is validated the way
-- it always was and a name that cannot be asked for is reported instead of silently dropped.
function Admin:applyListingSeller()
    local name, bad = exactName(self.lstSellerPicker.entry)
    if bad then
        self.message = { text = errorText("invalid_args"), error = true }
        return
    end
    self.lstSellerPicker:close()
    self:setListingSeller(name)
end

function Admin:onListingSellerClear()
    self.lstSellerPicker:setText("")
    self.lstSellerPicker:close()
    if self.lstSeller == nil then return end
    self.lstSeller = nil
    self.lstPage = 1
    self.message = nil
    self:requestListings()
    self:updateEnabled()
end

-- "Every live listing of this account" -- from a row of this page, from the account page's
-- counters or from its jump. The exact seller is what the server compares byte for byte; the
-- keyword box is emptied, the page goes back to 1 and the card is put in its live mode. It is
-- never the market history: rows that are already gone are a different question.
function Admin:showSellerListings(seller)
    local name = type(seller) == "string" and seller or nil
    if name == nil or name == "" or #name > ACCOUNT_BYTES then return end
    self:requestClose(function()
        if self.lstMode == "history" then self:setListingMode(false) end
        setEntryText(self.lstEntry, "")
        self.lstQuery = nil
        self.lstSellerPicker:setText(name)
        self.lstSellerPicker:close()
        self.lstSeller = name
        self.lstPage = 1
        self.message = nil
        if self.tab ~= "Listings" then
            self:setTab("Listings")      -- its own refresh sends the read
        else
            self:layout()
            self:requestListings()
        end
    end)
end

-- The card has two modes over the same search box: every active listing, or one player's own
-- market history (a read: admin.marketHistory passes the read gate, so a read-only role may
-- look). Switching clears the box and whatever the other mode was holding; the exact seller
-- belongs to the live list, so it is left alone.
function Admin:setListingMode(history)
    if self.lstMode ~= (history and "history" or "listings") then D.close(self) end
    self.lstMode = history and "history" or "listings"
    self.lstHistoryButton.active = history
    self.message = nil
    setEntryText(self.lstEntry, "")
    self.histQueryAt = nil
    self.histUser = nil
    self.histSentUser = nil
    self.marketHistory = nil
    if history then
        self.lstQuery = nil
        self.lstSentQuery = nil
    end
    if self.lstEntry.setPlaceholderText then
        pcall(function() self.lstEntry:setPlaceholderText(tr(history and "Admin_Lst_HistoryUser" or "Market_Search")) end)
    end
end

function Admin:onListingMode()
    self:setListingMode(self.lstMode ~= "history")
    self:layout()
end

function Admin:onListingEnter()
    if self.lstMode ~= "history" then return end
    self.histQueryAt = nil
    self:requestMarketHistory()
end

-- One read per account. No requestId: the reply names the account it answered for, which is
-- what a late answer is matched against.
function Admin:requestMarketHistory()
    local username = string.match(entryText(self.lstEntry), "^%s*(.-)%s*$")
    if username == "" then
        self.histUser = nil
        self.histSentUser = nil
        self.marketHistory = nil
        self:rebuildHistory()
        self:updateEnabled()
        return false
    end
    if not send("admin.marketHistory", { username = username }) then return false end
    self.histSentUser = username
    self:updateEnabled()
    return true
end

function Admin:onListingPage(button)
    local pages = 1
    if self.listings then pages = math.max(1, math.floor(tonumber(self.listings.pages) or 1)) end
    local page = math.max(1, math.min(pages, (self.lstPage or 1) + button.internal))
    if page == (self.lstPage or 1) then return end
    self.lstPage = page
    self.message = nil
    self:requestListings()
end

-- The row body is a read: picking a listing spells the whole record out in the detail window.
-- "This seller" is a read as well; forcing a listing down is the delist button on the right,
-- and it still goes through its own confirmation.
function Admin:onListingRow(item, refreshOnly)
    local had = self.selectedListing
    self.selectedListing = item
    if item == nil then
        if had ~= nil then self:closeDetail("listing", had.id) end
    else
        self:showDetail("listing", item.id, tr("Admin_Lst_Detail"), item.detailText, refreshOnly)
    end
    self:updateEnabled()
end

function Admin:onListingAction(item, id)
    if item == nil then return end
    if id == "seller" then
        self:showSellerListings(item.sellerId)
        return
    end
    if id ~= "delist" or self.listingsList.optionsDisabled then return end
    self:openDialog("delist", {
        title = getText(T .. "Admin_Lst_DelistTitle", item.plainName, item.seller),
        confirm = tr("Admin_Lst_Delist"), listingId = item.id,
    })
end

-- One write per click; every reply carries the current page back, so nothing is guessed here.
function Admin:sendListings(args, dlg)
    if not self:writeAllowed() then
        self:dialogError(dlg, errorText("forbidden"))
        return false
    end
    args.requestId = newRequestId()
    args.page = self.lstPage or 1
    args.query = self.lstQuery
    args.seller = self.lstSeller
    if not send("admin.listings", args) then
        self:dialogError(dlg, tr("Admin_Throttled"))
        return false
    end
    self.pendingListings = { requestId = args.requestId, action = args.action, listingId = args.listingId }
    if not dlg then self.message = nil end
    self:updateEnabled()
    return true
end

-- ----- auction admin actions -----

-- Every read carries the page and the query it was asked with, so a request the cooldown refused
-- (or an answer that never came) is noticed by prerender and asked for again.
function Admin:requestAuctions()
    local args = { action = "list", page = self.aucPage or 1, query = self.aucQuery,
        seller = self.aucSeller, requestId = newRequestId() }
    if not send("admin.auctions", args) then return false end
    self.aucRequestId = args.requestId
    self.aucSentQuery = self.aucQuery
    self.aucSentSeller = self.aucSeller
    self.aucSentPage = args.page
    self:updateEnabled()
    return true
end

-- One read per search over the whole server's auction record. The requestId is what a late
-- answer is matched against (the same box may be typed in again while an answer is on its way),
-- and the sent state is recorded here -- never when the answer lands -- so a server that says
-- "busy" is reported once instead of asked again in a loop. An empty box is a legitimate read:
-- it means the whole record, not "nothing to ask for".
function Admin:requestAuctionHistory()
    local args = { action = "history", requestId = newRequestId() }
    if self.aucHistId then
        args.auctionId = self.aucHistId   -- one auction's own timeline, never a text match
    else
        args.query = self.aucQuery
    end
    if not send("admin.auctions", args) then return false end
    self.pendingAucHistory = { requestId = args.requestId }
    self.aucHistRequestId = args.requestId
    self.aucHistAsked = true
    self.aucHistSentQuery = self.aucQuery
    self.aucHistSentId = self.aucHistId
    self:updateEnabled()
    return true
end

-- The card has two modes over the same search box: the live auctions, or the whole server's
-- auction record (a read -- the record passes the read gate, so a read-only role may look and
-- search). Entering a mode clears the box and whatever the other mode was holding, and marks
-- both reads as never asked for: prerender sends the first one on the next frame.
function Admin:setAuctionMode(mode)
    if self.aucMode ~= mode then D.close(self) end
    self.aucMode = mode
    self.aucActiveButton.active = mode == "active"
    self.aucHistoryButton.active = mode == "history"
    self.message = nil
    self.aucQuery = nil
    self.aucQueryAt = nil
    self.aucHistId = nil
    self.aucHistory = nil
    self.aucHistAsked = false
    self.aucSentPage = nil
    self.aucPage = 1
    setEntryText(self.aucEntry, "")
    if self.aucEntry.setPlaceholderText then
        pcall(function()
            self.aucEntry:setPlaceholderText(tr(mode == "history" and "Auction_History_Search" or "Market_Search"))
        end)
    end
end

function Admin:onAuctionMode(button)
    if self.aucMode == button.internal then return end
    self:setAuctionMode(button.internal)
    self:layout()
end

-- The "record" chip on a live auction row: switch to the record and pin it to that auction by
-- id, so an item name that happens to contain the same characters cannot add rows of its own.
function Admin:showAuctionHistory(id)
    self:setAuctionMode("history")
    self.aucHistId = tostring(id)
    setEntryText(self.aucEntry, self.aucHistId)
    local f = self.aucF
    f.kind = "all"   -- a type filter left over from the last search must not hide the jump
    f.page = 1
    for _, b in ipairs(f.kindButtons) do b.active = (not b.unused) and b.internal == "all" end
    self:layout()
end

-- A keystroke only arms the clock prerender owns: one command per pause in the typing, never one
-- per key. Both modes share the box, and typing in it replaces a row's "this auction only" jump
-- with a plain search.
function Admin:onAuctionSearch()
    local raw = string.match(entryText(self.aucEntry), "^%s*(.-)%s*$")
    self.aucQuery = raw ~= "" and string.lower(raw) or nil
    self.aucHistId = nil
    self.aucPage = 1
    self.aucQueryAt = EC.now()
end

-- The exact seller of the live auctions page: the same condition the listings page carries, over
-- the same candidate box -- typing lists, picking (or Enter over a whole name) pins.
function Admin:setAuctionSeller(name)
    if name == self.aucSeller then return end
    self.aucSeller = name
    self.aucPage = 1
    self:requestAuctions()
    self:updateEnabled()
end

function Admin:applyAuctionSeller()
    local name, bad = exactName(self.aucSellerPicker.entry)
    if bad then
        self.message = { text = errorText("invalid_args"), error = true }
        return
    end
    self.aucSellerPicker:close()
    self:setAuctionSeller(name)
end

function Admin:onAuctionSellerClear()
    self.aucSellerPicker:setText("")
    self.aucSellerPicker:close()
    if self.aucSeller == nil then return end
    self.aucSeller = nil
    self.aucPage = 1
    self.message = nil
    self:requestAuctions()
    self:updateEnabled()
end

-- "Every live auction of this account": the live list with the exact seller in force, never the
-- record of auctions that have ended.
function Admin:showSellerAuctions(seller)
    local name = type(seller) == "string" and seller or nil
    if name == nil or name == "" or #name > ACCOUNT_BYTES then return end
    self:requestClose(function()
        if self.aucMode ~= "active" then self:setAuctionMode("active") end
        setEntryText(self.aucEntry, "")
        self.aucQuery = nil
        self.aucQueryAt = nil
        self.aucSellerPicker:setText(name)
        self.aucSellerPicker:close()
        self.aucSeller = name
        self.aucPage = 1
        self.message = nil
        if self.tab ~= "Auctions" then
            self:setTab("Auctions")      -- its own refresh sends the read
        else
            self:layout()
            self:requestAuctions()
        end
    end)
end

function Admin:onAuctionPage(button)
    local pages = 1
    if self.auctions then pages = math.max(1, math.floor(tonumber(self.auctions.pages) or 1)) end
    local page = math.max(1, math.min(pages, (self.aucPage or 1) + button.internal))
    if page == (self.aucPage or 1) then return end
    self.aucPage = page
    self.message = nil
    self:requestAuctions()
end

-- The row body is a read: picking an auction spells the whole record out in the detail window.
-- The record jump and the seller jump are reads as well (they work for a read-only role and
-- while a write is in flight); the cancel button is the write, and it still goes through its
-- own confirmation.
function Admin:onAuctionRow(item, refreshOnly)
    local had = self.selectedAuction
    self.selectedAuction = item
    if item == nil then
        if had ~= nil then self:closeDetail("auction", had.id) end
    else
        self:showDetail("auction", item.id, tr("Admin_Auc_Detail"), item.detailText, refreshOnly)
    end
    self:updateEnabled()
end

function Admin:onAuctionAction(item, id)
    if item == nil then return end
    if id == "record" then
        self:showAuctionHistory(item.id)
        return
    end
    if id == "seller" then
        self:showSellerAuctions(item.sellerId)
        return
    end
    if id ~= "cancel" or self.auctionsList.optionsDisabled then return end
    self:openDialog("auctionCancel", {
        title = getText(T .. "Admin_Auc_CancelTitle", item.plainName),
        confirm = tr("Admin_Auc_Cancel"), auctionId = item.id,
    })
end

-- One write per click; every reply carries the current page back, so nothing is guessed here.
function Admin:sendAuctions(args, dlg)
    if not self:writeAllowed() then
        self:dialogError(dlg, errorText("forbidden"))
        return false
    end
    args.requestId = newRequestId()
    args.page = self.aucPage or 1
    args.query = self.aucQuery
    args.seller = self.aucSeller
    if not send("admin.auctions", args) then
        self:dialogError(dlg, tr("Admin_Throttled"))
        return false
    end
    self.pendingAuctions = { requestId = args.requestId, action = args.action, auctionId = args.auctionId }
    if not dlg then self.message = nil end
    self:updateEnabled()
    return true
end

function Admin:sendWhitelist(args)
    if not self:writeAllowed() then
        self.message = { text = errorText("forbidden"), error = true }
        return false
    end
    args.requestId = newRequestId()
    if not send("admin.whitelist", args) then
        self.message = { text = tr("Admin_Throttled"), error = true }
        return false
    end
    self.pendingWhitelist = { requestId = args.requestId, action = args.action }
    self.whitelistRequestId = args.requestId
    self:updateEnabled()
    return true
end

-- ----- asset reconciliation (admin.recovery) -----
--
-- One command, four actions. `overview` is the server-wide read and carries no account at all
-- (scope="all"); `list` and `recheck` are reads of one named account's held records; `resolve` is
-- one decision over one record of one account. The page (C.AdminRecovery) owns the rows, the
-- selection, the queue and the drawing; this owns the shared slot, the request identity and every
-- lifecycle rule around it.
--
-- The request that is still open is remembered whole (requestId, scope, username, action, key,
-- decision), because a reply has to be placed before the slot may be freed: matchesReply compares
-- the requestId *and* the identity the request was sent under -- the account for an account-scoped
-- command, scope="all" for the overview -- so an answer about another account (or an account
-- answer arriving against a server-wide read) can neither land on what is on screen nor release
-- the slot the newer request owns.
--
-- `username` is the caller's, never the player page's lookup: a batch resolves records belonging
-- to accounts nobody looked up, and the server-wide read belongs to no account.
function Admin:sendRecovery(args)
    local overview = args.action == "overview"
    local username = args.username
    if overview then
        if username ~= nil then
            self.message = { text = errorText("invalid_args"), error = true }
            return false
        end
    elseif type(username) ~= "string" or username == "" then
        self.message = { text = errorText("invalid_args"), error = true }
        return false
    end
    -- a decision is a write; the three reads only need the read right. Either side saying no
    -- means no, and the server re-checks both regardless.
    local read = args.action == "list" or overview
    local allowed = read and self:readAllowed() or self:writeAllowed()
    if not allowed then
        self.message = { text = errorText("forbidden"), error = true }
        return false
    end
    args.requestId = newRequestId()
    if not send("admin.recovery", args) then return false end
    -- what reserved the slot (freed by this very pair, whatever happens to the page meanwhile).
    -- recRequestUser is nil for the server-wide read, which is what makes scope="all" the only
    -- answer that may free it.
    self.recRequestId, self.recRequestUser = args.requestId, username
    -- and what is still open: a reply that arrives after the page left frees the command and
    -- changes nothing
    self.pendingRecovery = { requestId = args.requestId, username = username,
        action = args.action, key = args.key, decision = args.decision, query = args.query, page = args.page }
    self:updateEnabled()
    return true
end

-- Only the matching request still held by cooldown can be cancelled. Sent work keeps its slot.
function Admin:cancelDeferredRecovery(requestId)
    local held = deferred["admin.recovery"]
    if held == nil or held.args.requestId ~= requestId then return false end
    deferred["admin.recovery"] = nil
    if self.recRequestId == requestId then
        pendingAt["admin.recovery"] = nil
        self.recRequestId, self.recRequestUser = nil, nil
        if self.pendingRecovery and self.pendingRecovery.requestId == requestId then self.pendingRecovery = nil end
    end
    return true
end

-- The player page's entry, and the one way the page is narrowed to a single account: the same
-- Recovery sub tab, showing one name instead of the whole server, with the way back on a chip.
-- The counter on the status card is a summary of a lookup, never the list, and the permitted
-- decisions are recomputed per read on the server.
function Admin:onRecoveryOpen()
    if self:isModal() or not self:readAllowed() then return end
    if self.lookupUser == nil or not (self.lookup and self.lookup.found == true) then
        self.message = { text = tr("Admin_Player_Hint"), error = true }
        return
    end
    self:showRecovery(self.lookupUser)
end

-- Carrying an account over to the reconciliation page, exactly like showTransactions carries one
-- to the money page: the unsaved-work gate still asks first, and setTab's own refresh is what
-- sends the read.
function Admin:showRecovery(username)
    self:requestClose(function()
        self.message = nil
        self.picker:close()
        self:closeSellerPickers()
        DatePicker.close(self)
        filterCloseCombo(self.auditActorCombo)
        D.close(self)
        self.recoveryPage:showUser(username)
        self:setTab("Recovery")
    end)
end

-- Leaving is the same whether the host switched tab, hid the window, lost the right or closed the
-- window: whatever the page had not sent yet is dropped and a write still in flight is reported as
-- unknown. The request that is still open is deliberately *not* forgotten here -- the page that
-- issued it still owns the command until its own answer comes back, and freeing the slot then is
-- what lets the next read go out at once instead of after the timeout.
function Admin:leaveRecovery()
    self.recoveryPage:onLeave()
end

-- ----- survival seasons (admin.seasons) -----
--
-- One command, two actions. `list` is the read every visit makes; `start` is the manual
-- rotation, and it is the one write on this window that takes the NATIVE role capability
-- instead of the economy write role -- the people a season resets must not be the people who
-- reset it, so an ordinary economy admin has no way to press it and a role manager who is not
-- an economy admin does.
--
-- Two identities, and they are not the same thing:
--   pendingSeason  the request that holds the shared slot right now (its id, action and the
--                  season a rotation expected to replace). A reply is matched against it
--                  *before* the slot is freed, so an older answer can neither land on screen
--                  nor release the slot the newer request owns.
--   seasonUnknown  the request whose answer never came. The slot is already free, and that one
--                  request may still be closed by its late answer -- but only while nothing
--                  else is open, because the slot belongs to whatever is open now. It is kept
--                  until it is answered or the right to read is taken away, and it is never
--                  sent again: a later snapshot resolves the state without repeating the write.
function Admin:sendSeasons(args, dlg)
    local start = args.action == "start"
    if start and (type(args.expectedSeason) ~= "string" or args.expectedSeason == "") then
        self:dialogError(dlg, errorText("invalid_args"))
        return false
    end
    local allowed = self:readAllowed()
    if start then allowed = self:manageAllowed() end
    if not allowed then
        self:dialogError(dlg, errorText(start and "manage_settings_required" or "forbidden"))
        return false
    end
    args.requestId = newRequestId()
    if not send("admin.seasons", args) then
        self:dialogError(dlg, tr("Admin_Throttled"))
        return false
    end
    self.pendingSeason = { requestId = args.requestId, action = args.action,
        expectedSeason = args.expectedSeason, dialog = dlg }
    self:updateEnabled()
    return true
end

-- A command the client cooldown is still holding has not left yet, so it can still be taken
-- back -- and a rotation the host has cancelled, left behind or lost the capability for must
-- not go out afterwards. Only the matching request, and only while it is still deferred: one
-- already on the wire keeps its slot, because its outcome is unknown rather than cancelled.
function Admin:cancelDeferredSeason(requestId)
    local held = deferred["admin.seasons"]
    if held == nil or held.args.requestId ~= requestId then return false end
    deferred["admin.seasons"] = nil
    if self.pendingSeason ~= nil and self.pendingSeason.requestId == requestId then
        pendingAt["admin.seasons"] = nil
        self.pendingSeason = nil
    end
    self:updateEnabled()
    return true
end

-- The rotation this window has confirmed but not managed to send yet. Called wherever the host
-- takes the question back: the confirmation closing, the desk being left, the window being
-- hidden or closed. A rotation that really did leave is untouched.
function Admin:dropUnsentSeasonStart()
    local req = self.pendingSeason
    if req == nil or req.action ~= "start" then return false end
    return self:cancelDeferredSeason(req.requestId)
end

-- The reason + confirmation step for a rotation. `allowed` is the native capability and not the
-- economy write role openDialog defaults to, and dialogAllowed re-asks the very same question
-- on the permission poll: a host whose capability is taken away while the box stands open loses
-- the box before they can confirm it.
function Admin:openSeasonDialog(ctx)
    local number = tonumber(ctx.number)
    local current = number ~= nil and tostring(math.floor(number)) or "-"
    local after = number ~= nil and tostring(math.floor(number) + 1) or "-"
    return self:openDialog("season", {
        title = tr("Season_StartNext"),
        confirm = tr("Season_StartNext"),
        -- the confirmation is what states the whole consequence: the season that is running is
        -- archived, the next one starts every account at no progress, and no balance is touched
        warn = getText(T .. "Season_StartConfirm", current, after),
        seasonExpected = ctx.expectedSeason,
        allowed = self:manageAllowed(),
        deniedError = "manage_settings_required",
    })
end

-- Leaving the tab, hiding the window, losing the right, closing the window. A rotation the
-- cooldown is still holding never leaves a desk the host has left; one already sent keeps its
-- slot, and its outcome stays unknown until an answer (or a later read) says otherwise.
function Admin:leaveSeasons()
    self:dropUnsentSeasonStart()
    self.seasonsPage:onLeave()
end

-- The reason box and the explicit confirmation every decision has to pass. It is the window's
-- one write dialog, so the reason is mandatory here exactly as it is for an adjustment or a
-- freeze; `warn` states what the decision means in the host's own words -- an approval says out
-- loud that it is the administrator vouching for an uncertain source, not the server proving it.
function Admin:openRecoveryDialog(rec)
    local decision = tostring(rec.decision)
    local warn = getTextOrNull(T .. "Admin_Rec_Warn_" .. decision)
    -- A record whose only source is the player's own save: the confirmation has to say so in
    -- those words and show exactly what accepting it would put back, because there is no server
    -- evidence behind it. This is never presented as a reconciliation that succeeded. The page
    -- built the preview block (Admin_Rec_UnprovenWarn plus the item, the count and every origin
    -- the record named); two spaces join the parts, because the scrolling warning box wraps on
    -- width and a literal newline is not a line break to it.
    local unproven = rec.unprovenText
    if unproven ~= nil then
        warn = warn ~= nil and (unproven .. "  " .. warn) or unproven
    end
    local dlg = self:openDialog("recovery", {
        title = getTextOrNull(T .. "Admin_Rec_Title_" .. decision) or tr("Admin_Rec_List"),
        confirm = getTextOrNull(T .. "Admin_Rec_Do_" .. decision) or decision,
        warn = warn,
        recovery = rec,
        requireAccept = rec.unproven == true,
    })
    return dlg
end

-- The same step for a selection. It is deliberately the very same dialog engine and the very same
-- mandatory reason: what is added is the scale (how many records, how many accounts, how many
-- items) in front of the complete per-decision warning, so nothing a single decision discloses is
-- lost when the same decision is taken over a set. Two spaces, not a newline, join the two: the
-- scrolling warning box wraps on width and a literal newline is not a line break to it.
function Admin:openRecoveryBatchDialog(ctx)
    local decision = tostring(ctx.decision)
    local warn = getText(T .. "Admin_Rec_BatchWarn", tostring(ctx.count or 0),
        tostring(ctx.accounts or 0), ctx.units ~= nil and tostring(ctx.units) or tr("Admin_Rec_QuantityUnknown"))
    warn = getText(T .. "Admin_Rec_BatchScope", tostring(ctx.selectedCount), tostring(ctx.count), tostring(ctx.excludedCount))
        .. "  " .. warn
    local own = getTextOrNull(T .. "Admin_Rec_Warn_" .. decision)
    if own ~= nil then warn = warn .. "  " .. own end
    local targets = {}
    for _, item in ipairs(ctx.items or {}) do
        local qty, label = item.qty, "Admin_Rec_DQty"
        if decision == "remove" or decision == "approve" then qty, label = item.presentQty, "Admin_Rec_DPresent" end
        targets[#targets + 1] = tostring(item.username) .. " / " .. tostring(item.key) .. " / " .. tostring(item.headText or "")
            .. " / " .. getText(T .. label, qty ~= nil and tostring(qty) or tr("Admin_Rec_QuantityUnknown"))
    end
    warn = warn .. "  " .. tr("Admin_Rec_BatchTargets") .. "  " .. table.concat(targets, "  |  ")
    return self:openDialog("recoveryBatch", {
        title = getTextOrNull(T .. "Admin_Rec_Title_" .. decision) or tr("Admin_Rec_List"),
        confirm = getTextOrNull(T .. "Admin_Rec_Do_" .. decision) or decision,
        warn = warn,
        recoveryBatch = ctx,
    })
end

function Admin:isModal()
    return self.dialog ~= nil
        -- the reconciliation page is an ordinary sub page now, not an overlay: it holds no popup
        -- of its own, so it never makes the window modal
        or (self.tab == "Shop" and self.shopPage:isModal())
        or (self.tab == "Whitelist" and self.whitelistPage:isModal())
        or (self.tab == "Transactions" and self.txPage:isModal())
end

-- Escape, offered by the root that actually holds the keyboard (ECAdminWindow:onEscape). There
-- is no Events hook of our own: a window sitting in the background must never eat the key.
function Admin:onEscape()
    if self.dialog then
        local combo = self.dialog.roleCombo
        if combo and combo.expanded then filterCloseCombo(combo); return true end
        combo = self.dialog.roleHaveCombo
        if combo and combo.expanded then filterCloseCombo(combo); return true end
        self:closeDialog()
        return true
    end
    -- on the reconciliation page Escape stops a queue that is running; it is not a way out of the
    -- page itself, because the page is a sub tab and not an overlay over another one
    if self.tab == "Recovery" then return self.recoveryPage:onEscape() end
    if self.tab == "Seasons" then return self.seasonsPage:onEscape() end
    if self.tab == "Player" and self.picker:isOpen() then self.picker:close(); return true end
    if self.tab == "Listings" and self.lstSellerPicker:isOpen() then
        self.lstSellerPicker:close()
        return true
    end
    if self.tab == "Auctions" and self.aucSellerPicker:isOpen() then
        self.aucSellerPicker:close()
        return true
    end
    -- the actor candidates fold first, and the page behind them is left alone
    if self.tab == "Audit" and self.auditActorCombo.expanded == true then
        filterCloseCombo(self.auditActorCombo)
        return true
    end
    if self.tab == "Shop" then return self.shopPage:onEscape() end
    if self.tab == "Whitelist" then return self.whitelistPage:onEscape() end
    if self.tab == "Transactions" then return self.txPage:onEscape() end
    return false
end

-- ----- keyboard targets (C.Keyboard walks these; this page owns no key dispatch) -----

local function addTarget(out, kind, label, control, controls)
    out[#out + 1] = { kind = kind, label = label, control = control, controls = controls }
end

local function addGroup(out, label, buttons)
    local shown = {}
    for _, b in ipairs(buttons) do
        if b ~= nil and b:getIsVisible() then shown[#shown + 1] = b end
    end
    if #shown > 0 then addTarget(out, "group", label, nil, shown) end
end

-- The filter row of a history / audit card: the type chips, both dates with their calendar
-- glyphs, the sort chips and the page chips.
local function addFilters(out, f)
    addGroup(out, f.kindLabel or tr("Filter_Kind"), f.kindButtons)
    addTarget(out, "entry", f.fromLabel, f.fromEntry)
    addTarget(out, "button", tr("Filter_Calendar"), f.fromEntry.calendarButton)
    addTarget(out, "entry", f.toLabel, f.toEntry)
    addTarget(out, "button", tr("Filter_Calendar"), f.toEntry.calendarButton)
    addGroup(out, f.sortLabel, f.sortButtons)
    addGroup(out, tr("Filter_PageNav"), { f.prevButton, f.nextButton })
end

-- The audit filter row carries one combo of its own (the actor candidates); the shared helper
-- above walks the chips, the dates and the pages, and this adds the box beside them.
local function addCombo(out, label, combo)
    if combo ~= nil and combo:getIsVisible() then
        out[#out + 1] = { kind = "combo", label = label, control = combo }
    end
end

-- Every control the mouse can reach, in the order a keyboard should walk it -- the action
-- buttons of the selected row included (C.RowActions answers which ones are live), so a row
-- action is never a pointer-only path.
function Admin:keyboardTargets()
    if not self:readAllowed() then return {} end
    if self.tab == "Transactions" then return self.txPage:keyboardTargets() end
    if self.tab == "Shop" then return self.shopPage:keyboardTargets() end
    if self.tab == "Whitelist" then return self.whitelistPage:keyboardTargets() end
    if self.tab == "Recovery" then return self.recoveryPage:keyboardTargets() end
    if self.tab == "Seasons" then return self.seasonsPage:keyboardTargets() end
    local out = {}
    if self.tab == "Player" then
        -- the mode switch comes first in both modes, so the way back out of the list (and into
        -- it) is always the first stop of the walk
        addGroup(out, tr("Admin_Accounts_Modes"), self.playerModeButtons)
        if self.playerMode == "list" then
            for _, desc in ipairs(self.accountsPage:keyboardTargets()) do out[#out + 1] = desc end
            return out
        end
        for _, desc in ipairs(self.picker:keyboardTargets()) do out[#out + 1] = desc end
        addTarget(out, "list", tr("Admin_Player_Summary"), self.summaryList)
        addGroup(out, tr("Admin_Player_Actions"),
            { self.lookupButton, self.adjustButton, self.freezeButton })
        addGroup(out, tr("Admin_Player_Status"),
            { self.recoveryButton, self.moneyButton, self.lstJumpButton, self.aucJumpButton })
        out[#out + 1] = { kind = "scroll", label = tr("Admin_Player_Status"), control = self.statusReader, focusable = false }
        addTarget(out, "button", tr("Admin_Player_FreezeAudit"), self.freezeAuditButton)
        addTarget(out, "list", tr("Admin_Player_Receipts"), self.receiptList)
        addGroup(out, tr("Admin_Rcpt_Actions"), R.targets(self.receiptList))
    elseif self.tab == "Listings" then
        addTarget(out, "entry", tr("Market_Search"), self.lstEntry)
        addGroup(out, tr("Admin_Lst_Title"), { self.lstHistoryButton })
        if self.lstMode == "history" then
            addFilters(out, self.histF)
            addTarget(out, "list", tr("Admin_Lst_History"), self.historyList)
        else
            for _, desc in ipairs(self.lstSellerPicker:keyboardTargets()) do out[#out + 1] = desc end
            addGroup(out, tr("Admin_Mkt_SellerExact"), { self.lstSellerClearButton })
            addGroup(out, tr("Filter_PageNav"), { self.lstPrevButton, self.lstNextButton })
            addTarget(out, "list", tr("Admin_Lst_Title"), self.listingsList)
            addGroup(out, tr("Admin_Lst_RowActions"), R.targets(self.listingsList))
        end
    elseif self.tab == "Auctions" then
        addTarget(out, "entry", tr("Market_Search"), self.aucEntry)
        addGroup(out, tr("Admin_Auc_Title"), { self.aucActiveButton, self.aucHistoryButton })
        if self.aucMode == "history" then
            addFilters(out, self.aucF)
            addTarget(out, "list", tr("Auction_History_Title"), self.aucHistoryList)
        else
            for _, desc in ipairs(self.aucSellerPicker:keyboardTargets()) do out[#out + 1] = desc end
            addGroup(out, tr("Admin_Mkt_SellerExact"), { self.aucSellerClearButton })
            addGroup(out, tr("Filter_PageNav"), { self.aucPrevButton, self.aucNextButton })
            addTarget(out, "list", tr("Admin_Auc_Title"), self.auctionsList)
            addGroup(out, tr("Admin_Auc_RowActions"), R.targets(self.auctionsList))
        end
    elseif self.tab == "Audit" then
        addTarget(out, "entry", tr("Admin_Audit_Hint"), self.auditEntry)
        addTarget(out, "entry", tr("Admin_Audit_Actor"), self.auditActorEntry)
        addCombo(out, tr("Admin_Audit_Actor"), self.auditActorCombo)
        addFilters(out, self.auditF)
        addTarget(out, "list", tr("Admin_Audit_Title"), self.auditList)
        addGroup(out, tr("Admin_Audit_Actions"),
            { self.auditCopyNameButton, self.auditCopyIdButton })
    elseif self.tab == "Dashboard" then
        -- the issued card's currency, and one entry per supply column into the account list
        addGroup(out, tr("Admin_Dash_Issued"), self.dashIssueButtons)
        addTarget(out, "button", tr("Admin_Dash_Note"), self.dashNoteButton)
        addGroup(out, tr("Admin_Dash_ViewHolders"), self.dashHolderButtons)
    elseif self.tab == "Currencies" then
        out[#out + 1] = { kind = "scroll", label = tr("Admin_Cur_Title"), control = self.currencyReader, focusable = false }
        addGroup(out, tr("Admin_Cur_Title"), { self.renameButton, self.toggleButton, self.rateButton, self.balanceMaxButton })
        addGroup(out, tr("Admin_Cur_Actions"), { self.buybackAccountButton, self.buybackServerButton,
            self.curHoldersButton, self.iconsButton })
    elseif self.tab == "Sources" then
        out[#out + 1] = { kind = "scroll", label = tr("Admin_Src_Title"), control = self.sourceReader, focusable = false }
        addGroup(out, tr("Admin_Src_Title"), { self.srcCapsButton, self.srcToggleButton })
    elseif self.tab == "System" then
        out[#out + 1] = { kind = "scroll", label = tr("Admin_Sys_State"), control = self.systemReader, focusable = false }
        addGroup(out, tr("Admin_Sys_Paths"), self.copyButtons)
    elseif self.tab == "Settings" then
        addTarget(out, "entry", tr("Admin_Set_Search"), self.setEntry)
        addTarget(out, "list", tr("Admin_Tab_Settings"), self.settingsNav)
        addTarget(out, "list", tr("Admin_Tab_Settings"), self.settingsList)
        local selected = self.settingsList:getSelectedItem()
        addGroup(out, selected and selected.plainName or tr("Admin_Tab_Settings"), R.targets(self.settingsList))
        addTarget(out, "button", tr("Admin_Set_ResetGroup"), self.setResetButton)
        addTarget(out, "button", self.setMessageButton.fullTitle, self.setMessageButton)
    end
    return out
end

-- The shop page's two shortcuts and the player page's own jumps: the money page, narrowed to
-- what the caller means. `filters` is that page's own table ({ account, item, query, txId, ts });
-- it travels untouched, and setTab's refresh is what sends the request with the group and the
-- filters already in place. The draft guard is unchanged: requestClose still asks first.
function Admin:showTransactions(group, filters)
    self:requestClose(function()
        self.txPage:show(group, filters)
        self:setTab("Transactions")
    end)
end

-- ----- dialog lifecycle -----

-- `ctx.allowed` is the right this particular dialog needs, decided by the caller that knows
-- what it is about to change: the settings page asks per option (a manageOnly one takes the
-- native role capability), everything else is the economy write role, which stays the default.
function Admin:openDialog(mode, ctx)
    local allowed = ctx.allowed
    if allowed == nil then allowed = self:writeAllowed() end
    if not allowed then
        self.message = { text = errorText(ctx.deniedError or "forbidden"), error = true }
        return nil
    end
    self:closeDialog()
    C.Keyboard.blurInputs(self)
    self.picker:close()
    self:closeSellerPickers()
    DatePicker.close(self)
    filterCloseCombo(self.auditActorCombo)
    D.close(self)
    local dlg = ISPanel:new(0, 0, 360, 200)
    setmetatable(dlg, Dialog)
    dlg.background = false
    dlg.admin = self
    dlg.mode = mode
    dlg.currency = ctx.currency
    dlg.modId = ctx.modId
    dlg.frozenTarget = ctx.frozenTarget
    dlg.enabledTarget = ctx.enabledTarget
    dlg.titleText = ctx.title
    dlg.confirmLabel = ctx.confirm
    dlg.warnText = ctx.warn
    dlg.optionKey = ctx.optionKey
    dlg.optionGroup = ctx.optionGroup
    dlg.listingId = ctx.listingId
    dlg.auctionId = ctx.auctionId
    dlg.hintText = ctx.hint
    -- the season a rotation expects to replace: the command carries this exact id, so the
    -- confirmation stays bound to the season that was on screen when it was opened
    dlg.seasonExpected = ctx.seasonExpected
    -- the roles option's current set, in the shape it arrived in (array or the file's string):
    -- the dialog turns it into its own working list and never edits the snapshot
    dlg.roleValue = ctx.roleValue
    -- Set when the decision would act on data the server could not prove (a reconciliation
    -- record whose only source is the player's own save). It adds the acceptance gate and, once
    -- ticked, is what puts acceptUnproven on the command -- the server refuses the write without
    -- it, so the two halves always agree.
    dlg.requireAccept = ctx.requireAccept == true
    dlg.accepted = false
    -- the reconciliation record a decision is being confirmed over: its key, its revision, the
    -- decision itself and the row heading the confirmation prints back
    dlg.recovery = ctx.recovery
    -- and, for a batch, the set that was confirmed: the records with their own accounts, keys and
    -- revisions, plus the scale the confirmation printed. The queue works off this very table, so
    -- what runs is exactly what was agreed to.
    dlg.recoveryBatch = ctx.recoveryBatch
    dlg.info = {}
    dlg.message = nil
    dlg:initialise()
    self:addChild(dlg)      -- the boxes exist from here on (instantiate -> createChildren)
    self.dialog = dlg
    self.modalGuard:setVisible(true)
    self.modalGuard:raise(dlg)
    if ctx.value ~= nil and dlg.boxes.value ~= nil then setEntryText(dlg.boxes.value, ctx.value) end
    dlg:updateInfo()
    self:layoutDialog()
    self:updateEnabled()
    return dlg
end

function Admin:layoutDialog()
    self.modalGuard:setX(0); self.modalGuard:setY(0)
    self.modalGuard:setWidth(self.width); self.modalGuard:setHeight(self.height)
    local dlg = self.dialog
    if not dlg then return end
    dlg:layoutInside(math.max(320, self.width - PAD * 4), math.max(160, self.height - PAD * 2))
    dlg:setX(math.max(0, math.floor((self.width - dlg.width) / 2)))
    dlg:setY(math.max(0, math.floor((self.height - dlg.height) / 2)))
end

-- A refusal goes to the supplied dialog, or the footer when there is no dialog.
-- Only dialog messages need layout; callers may `return self:dialogError(dlg, body)`.
function Admin:dialogError(dlg, body)
    local target = dlg or self
    target.message = { text = body, error = true }
    if dlg then self:layoutDialog() end
end

function Admin:closeDialog()
    local dlg = self.dialog
    if not dlg then return end
    -- A rotation this very box confirmed and the client cooldown has not let out yet goes with
    -- it: cancel, Escape, the window closing and a capability taken away all end up here, and
    -- a command that leaves *after* the host closed the question is a season turned by nobody.
    -- One already on the wire is left alone -- unknown is not cancelled.
    if dlg.mode == "season" then self:dropUnsentSeasonStart() end
    self.dialog = nil
    self.modalGuard:setVisible(false)
    dlg:unfocusAll()
    dlg:setVisible(false)
    self:removeChild(dlg)
    self:updateEnabled()
end

-- Local validation first (the server re-validates everything); then one command with a fresh
-- requestId and the wallet revision the dialog was showing.
-- The option dialog carries no reason box and the group reset carries no field at all, so both
-- are answered before the reason gate every other write has to pass.
function Admin:submitDialog(dlg)
    if dlg.mode == "option" then return self:submitOption(dlg) end
    if dlg.mode == "optionReset" then
        local keys = self:overriddenKeys(dlg.optionGroup)
        self:closeDialog()
        if #keys == 0 then return end
        self.resetQueue = { keys = keys, i = 1 }
        self:nextOptionReset()
        return
    end
    local reason = string.match(entryText(dlg.boxes.reason), "^%s*(.-)%s*$")
    local reasonChars = charCount(reason)
    -- any non-empty reason is accepted; REASON_MAX only guards the one-line JSON files
    if reasonChars < 1 or string.find(reason, "%c") then
        return self:dialogError(dlg, tr("Admin_Adjust_BadReason"))
    elseif reasonChars > REASON_MAX then
        return self:dialogError(dlg, errorText("reason_too_long"))
    end
    -- The manual rotation. Nothing about it is derived here: the season it replaces is the one
    -- the desk was showing when the box opened, and the server refuses the write outright once
    -- that is no longer the current season -- which is exactly what stops a rotation from
    -- landing on a season an automatic deadline has already turned.
    if dlg.mode == "season" then
        self:sendSeasons({ action = "start", expectedSeason = dlg.seasonExpected, reason = reason }, dlg)
        return
    end
    -- The reconciliation page's decision. Nothing about it is derived here: the account, the key,
    -- the revision and the decision are the row the host pressed, and the note is what they just
    -- typed. The server re-checks all of them against the evidence it recomputes for that record,
    -- so a revision that moved while the box was open is refused there rather than forced here.
    if dlg.mode == "recovery" then
        local rec = dlg.recovery
        if type(rec) ~= "table" or type(rec.key) ~= "string" or type(rec.revision) ~= "string"
            or type(rec.decision) ~= "string" or type(rec.username) ~= "string" then
            return self:dialogError(dlg, errorText("invalid_args"))
        end
        -- The note is the reason gate above and nothing else: mandatory, free text, bounded by
        -- REASON_MAX. No extra minimum -- this window asks for a reason the same way for an
        -- adjustment, a freeze and a decision here, and the server re-validates it either way.
        local args = { action = "resolve", username = rec.username, key = rec.key,
            revision = rec.revision, decision = rec.decision, note = reason }
        -- Accepting data the server could not prove is its own act: the flag only goes out when
        -- the gate was really ticked, and it is never inferred from the decision or the record.
        -- Without it the server refuses with recovery_unproven_source, which is the point -- the
        -- button is disabled until then, so this is a second line rather than the only one.
        if dlg.requireAccept then
            if dlg.accepted ~= true then
                return self:dialogError(dlg, tr("Admin_Rec_AcceptRequired"))
            end
            args.acceptUnproven = true
        end
        if not self:sendRecovery(args) then
            return self:dialogError(dlg, tr("Admin_Throttled"))
        end
        dlg.message = nil
        self:updateEnabled()
        return
    end
    -- The same decision over the confirmed set. Nothing is sent from here: the dialog closes and
    -- the page runs the set one existing resolve at a time, each one carrying that record's own
    -- account, key and revision and this one reason. There is no bulk command and no retry.
    if dlg.mode == "recoveryBatch" then
        local ctx = dlg.recoveryBatch
        if type(ctx) ~= "table" or type(ctx.items) ~= "table" or #ctx.items == 0
            or type(ctx.decision) ~= "string" then
            return self:dialogError(dlg, errorText("invalid_args"))
        end
        self:closeDialog()
        self.recoveryPage:startBatch(ctx.decision, reason, ctx.items, ctx.excludedCount)
        return
    end
    if dlg.mode == "adjust" then
        -- Paying yourself needs the explicit grant, and it is re-asked here rather than only
        -- at the button: the grant can be taken away while this dialog stands open, and the
        -- server refuses the command with self_target either way.
        if self:isSelfTarget() and not self:selfAdjustAllowed() then
            return self:dialogError(dlg, errorText("self_target"))
        end
        local delta = parseInt(entryText(dlg.boxes.amount))
        if not delta or delta == 0 then
            return self:dialogError(dlg, tr("Admin_Adjust_BadAmount"))
        end
        local maxPerTx = self.lookup and tonumber(self.lookup.maxPerTx)
        if maxPerTx and math.abs(delta) > maxPerTx then
            return self:dialogError(dlg, errorText("over_max_per_tx"))
        end
        local bal = self.lookup and self.lookup.balances and self.lookup.balances[dlg.currency]
        local rev = bal and tonumber(bal.rev) or 0
        local reversal = string.match(entryText(dlg.boxes.reversal), "^%s*(.-)%s*$")
        local requestId = newRequestId()
        local ok, why = send("admin.adjust", {
            username = self.lookupUser, currency = dlg.currency, delta = delta, reason = reason,
            expectedRev = rev, requestId = requestId,
            reversalOfTxId = reversal ~= "" and reversal or nil,
        })
        if not ok then
            return self:dialogError(dlg, tr("Admin_Throttled"))
        end
        self.pendingAdjust = { username = self.lookupUser, currency = dlg.currency, delta = delta, requestId = requestId }
    elseif dlg.mode == "freeze" then
        local ok = send("admin.freeze", { username = self.lookupUser, frozen = dlg.frozenTarget == true, reason = reason })
        if not ok then
            return self:dialogError(dlg, tr("Admin_Throttled"))
        end
        self.pendingFreeze = { username = self.lookupUser, frozen = dlg.frozenTarget == true }
    elseif dlg.mode == "sourceCaps" or dlg.mode == "sourceEnabled" then
        if type(dlg.modId) ~= "string" or dlg.modId == "" then
            return self:dialogError(dlg, errorText("invalid_args"))
        end
        local payload = { action = "set", modId = dlg.modId, reason = reason }
        if dlg.mode == "sourceCaps" then
            local mint = parseInt(entryText(dlg.boxes.mintCap))
            if not mint or mint < 0 then
                return self:dialogError(dlg, tr("Admin_Src_BadCap"))
            end
            payload.dailyMintCap = mint
            -- an empty burn field is an explicit "no limit": the server only clears the stored
            -- cap when it is told `false` (nil would mean "leave it alone")
            local raw = string.match(entryText(dlg.boxes.burnCap), "^%s*(.-)%s*$")
            if raw == "" then
                payload.dailyBurnCap = false
            else
                local burn = parseInt(raw)
                if not burn or burn < 0 then
                    return self:dialogError(dlg, tr("Admin_Src_BadCap"))
                end
                payload.dailyBurnCap = burn
            end
        else
            payload.enabled = dlg.enabledTarget == true
        end
        payload.requestId = newRequestId()
        if not send("admin.sources", payload) then
            return self:dialogError(dlg, tr("Admin_Throttled"))
        end
        self.pendingSource = { requestId = payload.requestId, modId = dlg.modId }
    elseif dlg.mode == "delist" then
        if dlg.listingId == nil then
            return self:dialogError(dlg, errorText("invalid_args"))
        end
        if not self:sendListings({ action = "delist", listingId = dlg.listingId, reason = reason }, dlg) then return end
    elseif dlg.mode == "auctionCancel" then
        if dlg.auctionId == nil then
            return self:dialogError(dlg, errorText("invalid_args"))
        end
        if not self:sendAuctions({ action = "cancel", auctionId = dlg.auctionId, reason = reason }, dlg) then return end
    else
        local field, value
        if dlg.mode == "name" then
            field = "name"
            value = string.match(entryText(dlg.boxes.name), "^%s*(.-)%s*$")
            if #value > NAME_MAX then
                return self:dialogError(dlg, errorText("invalid_args"))
            end
        elseif dlg.mode == "enabled" then
            field = "enabled"
            value = dlg.enabledTarget == true
        elseif dlg.mode == "balanceMax" then
            field = "balanceMax"
            local raw = string.match(entryText(dlg.boxes.balanceMax), "^%s*(.-)%s*$")
            if raw ~= "" then
                local n = parseInt(raw)
                if not n or n < 1000 then
                    return self:dialogError(dlg, tr("Admin_BalanceMax_BadValue"))
                end
                value = n
            end
        else
            field = "exchange"
            local values = {}
            for _, key in ipairs(EXCHANGE_FIELDS) do
                local n = parseInt(entryText(dlg.boxes[key]))
                if not n or n <= 0 then
                    return self:dialogError(dlg, tr("Admin_Exchange_BadValue"))
                end
                values[key] = n
            end
            if values.perOrderMin > values.perOrderMax then
                return self:dialogError(dlg, tr("Admin_Exchange_BadValue"))
            end
            value = values
        end
        local ok = send("admin.config", { currency = dlg.currency, field = field, value = value, reason = reason })
        if not ok then
            return self:dialogError(dlg, tr("Admin_Throttled"))
        end
        self.pendingConfig = { currency = dlg.currency, field = field }
    end
    dlg.message = nil
    self:updateEnabled()
end

-- The same checks ECConfig.validateOption runs, so a typo never costs a round trip; the hint
-- line (the range / the list format) doubles as the error message, because it says what is
-- accepted. The server re-validates everything regardless.
function Admin:submitOption(dlg)
    local spec = EC.OPTION_BY_KEY[dlg.optionKey]
    if spec == nil then
        return self:dialogError(dlg, errorText("unknown_option"))
    end
    -- A role list leaves as the exact names that were picked, in an array. Nothing is dropped
    -- on the way out: a name the server has since deleted travels too and is refused there
    -- (unknown_role), which is the one answer that cannot quietly change who is authorised.
    if spec.kind == "roles" then
        if dlg.roleChoices == nil then
            return self:dialogError(dlg, errorText("roles_unavailable"))
        end
        self:sendOption(dlg.optionKey, dlg:roleArgs(), dlg)
        return
    end
    local raw = string.match(entryText(dlg.boxes.value), "^%s*(.-)%s*$")
    local value
    if spec.kind == "list_int" then
        if EC.parseIntList(raw, spec) == nil then
            return self:dialogError(dlg, dlg.hintText or errorText("invalid_args"))
        end
        value = raw
    elseif spec.kind == "text" then
        if raw == "" or charCount(raw) > OPTION_TEXT_MAX or string.find(raw, "%c") then
            return self:dialogError(dlg, errorText("invalid_args"))
        end
        value = raw
    else
        local n = tonumber(raw)
        local bad = n == nil or n ~= n or n < spec.min or n > spec.max
        if not bad and spec.kind == "int" and n ~= math.floor(n) then bad = true end
        if not bad and spec.kind == "number" and spec.step then
            local steps = n / spec.step
            if math.abs(steps - math.floor(steps + 0.5)) > 1e-9 then bad = true end
        end
        if bad then
            return self:dialogError(dlg, dlg.hintText or errorText("invalid_args"))
        end
        value = n
    end
    self:sendOption(dlg.optionKey, value, dlg)
end

-- ----- shared reply routing -----

-- Does this reply still belong to a read that is open? Asked before the shared command slot is
-- freed, and answered without touching a single field: a stale answer must never release the
-- slot a newer read owns. admin.players now has two owners (this page's picker and the money
-- page's), so the wrong one must not consume the other's answer either.
function Admin:matchesReply(kind, args)
    if kind == "players" and self.picker:owns(args) then return true end
    if kind == "transactions" or kind == "transaction" or kind == "players" then
        return self.txPage:matchesReply(kind, args)
    end
    if kind == "auditDetail" then
        return self.auditDetailRequestId == nil or args.requestId == nil
            or args.requestId == self.auditDetailRequestId
    end
    -- The two audit reads and the two market list reads now carry the question they were asked
    -- (the actor and the day bounds, the exact seller and the page): an answer to a question the
    -- admin has already moved off neither lands nor releases the slot the newer read owns. A
    -- write's reply is matched against the write that is still open instead.
    if kind == "audit" then
        return self.auditRequestId == nil or args.requestId == nil
            or args.requestId == self.auditRequestId
    end
    if kind == "auditFile" then
        return self.auditFileRequestId == nil or args.requestId == nil
            or args.requestId == self.auditFileRequestId
    end
    if kind == "listings" then
        if args.requestId == nil or args.requestId == self.lstRequestId then return true end
        local req = self.pendingListings
        return req ~= nil and req.requestId == args.requestId
    end
    if kind == "auctions" then
        if args.requestId == nil or args.requestId == self.aucRequestId
            or args.requestId == self.aucHistRequestId then return true end
        local req = self.pendingAuctions
        return req ~= nil and req.requestId == args.requestId
    end
    -- The two new reads are matched strictly: a reply is this window's only if it names the very
    -- request that is still open. Both carry whole-server data -- every account's balances, the
    -- registry and the supply figures -- so "no request of ours is open" must mean "refuse",
    -- never "accept anything". The permissive form the older reads use (a nil owner, or a reply
    -- that names no request, is let through) would reopen the exact hole a permission collapse
    -- closes: clearData drops the owner, and the next unowned success -- carrying perms.read =
    -- true, which this side then believes because the local role read can still say yes for a
    -- runtime role list the server does not honour -- would put the whole population back on
    -- screen. A timeout deliberately keeps the owner instead of dropping it, so the late answer
    -- to that one request can still land; the id is unique, so keeping it lets nothing else in.
    if kind == "accounts" then
        return self.accRequestId ~= nil and args.requestId == self.accRequestId
    end
    if kind == "currency" then
        return self.curRequestId ~= nil and args.requestId == self.curRequestId
    end
    -- The reconciliation page is the strictest of the lot, because its writes remove real items
    -- from a real inventory: an answer has to name both the request this page last sent *and* the
    -- identity it was sent under. An account-scoped request is only answered by a reply naming
    -- that very account; the server-wide read carries no account at all, so it is only answered by
    -- a reply that declares scope="all" (which every overview reply does, refusals included).
    -- An older answer, one that names no request, or one that answers the wrong scope is refused
    -- here -- so it can neither land on what is on screen nor release the slot the newer request
    -- owns; that slot is freed by its own timeout instead. The pair is remembered past the page
    -- being left on purpose: the read this window abandoned still owns the command until its own
    -- answer comes back, and freeing the slot then is what lets the next read go out at once
    -- instead of after the timeout. Whether the answer may be *used* is a separate question,
    -- asked in the page's onReply against what it is showing now.
    if kind == "recovery" then
        if self.recRequestId == nil or args.requestId ~= self.recRequestId then return false end
        if self.recRequestUser == nil then return args.scope == "all" end
        return args.username == self.recRequestUser
    end
    -- One option slot, several pages writing through it (a settings row, its dialog, a group
    -- reset, the season desk's length chip), so the write that is open is named by id and
    -- nothing else answers for it. Without this an answer to the write before it would free the
    -- slot the open write owns -- and the page's own "is this mine" check in onReply happens
    -- after that, far too late to keep the slot. A write whose answer never came keeps its id
    -- on purpose: that one late answer may still land, and the id names exactly it.
    if kind == "option" then
        return self.optionRequestId ~= nil and args.requestId == self.optionRequestId
    end
    -- The season desk is matched as strictly as the two whole-server reads above: a reply is
    -- this window's only if it names the request that is open. A rotation must never be
    -- confirmed by an answer nobody asked for, and an unowned success would otherwise be able
    -- to repaint the season state a permission collapse had just dropped. Once nothing is open,
    -- the one request whose answer never came may still be closed by it -- while something else
    -- *is* open the slot belongs to that one, so the late answer is refused and the outcome is
    -- learned from the read that is already on its way.
    if kind == "seasons" then
        local open = self.pendingSeason
        if open ~= nil then return args.requestId == open.requestId end
        local lost = self.seasonUnknown
        return lost ~= nil and args.requestId == lost.requestId
    end
    return true
end

-- views.changed says a scope moved, never what it moved to: the page that shows it re-reads
-- while it is on screen, and a page that is not gets marked so its own next refresh does. The
-- notice is never treated as the fresh snapshot.
local SCOPE_TAB = { wallet = "Player", market = "Listings", auction = "Auctions",
    audit = "Audit", players = "Player", whitelist = "Whitelist", shop = "Shop",
    transactions = "Transactions" }

function Admin:onViewChanged(scope)
    if scope == "transactions" then self.txPage:onViewChanged(scope) end
    local tab = SCOPE_TAB[scope]
    if tab ~= nil then self.dirty[tab] = true end
end

function Admin:tabDirty()
    return self.dirty[self.tab] == true
end

-- ----- replies -----

-- The supply figures, wherever they arrive from. Three commands state them now (admin.system,
-- the currency page's own admin.currency, and every admin.config write reply), and the dashboard
-- and the currency page must not disagree about what the server holds -- so there is one copy,
-- replaced by whichever answer came last, with the moment the server measured it. A reply that
-- carries no supply leaves the previous one alone: nothing here invents a figure, and nothing
-- drops a known one because a write reply happened not to repeat it.
function Admin:adoptSupply(args)
    if type(args.supply) ~= "table" then return end
    self.supply = args.supply
    self.supplyAt = tonumber(args.at) or EC.now()
end

-- The record read's own reply (admin.auctions{action = "history"}), matched against the request
-- that is still open: a late answer to a search the admin has already moved on from never lands
-- on screen. A refusal is a message and nothing else -- the snapshot that is up stays up, so a
-- busy or unreadable server never reads as "this auction has no record".
function Admin:onAuctionHistoryReply(args)
    if args.requestId ~= nil and self.aucHistRequestId ~= nil and args.requestId ~= self.aucHistRequestId then return end
    self.pendingAucHistory = nil
    if args.error ~= nil then
        local body = args.error == "read_failed" and tr("Auction_History_ReadFailed")
            or errorText(args.error)
        self.message = { text = body, error = true }
        return
    end
    if type(args.entries) ~= "table" then return end
    -- the reply is oldest first: every line remembers its place, which is what the "time" sort
    -- reads -- so the record reverses exactly, two bids inside the same minute included
    for i, rec in ipairs(args.entries) do
        if type(rec) == "table" then rec.ord = i end
    end
    self.aucHistory = args
    self.aucHistoryAt = EC.now()
    self.message = nil
    self:rebuildAuctionHistory()
end

function Admin:onReply(kind, args)
    -- Hello/config owns the live permission source. A complete admin reply may bootstrap it,
    -- but a delayed write reply must not restore a grant revoked by a newer config broadcast.
    local options = kind == "system" and args.sandbox or args.options
    if C.options == nil and type(options) == "table" then C.options = options end
    self:syncPermissionContext(true)
    if not P.canRead() then self:clearData(); return end
    -- the server states the permission level it just enforced; it wins over the local role read
    if type(args.perms) == "table" then
        local perms = self.serverPerms or {}
        for key, value in pairs(args.perms) do
            if type(value) == "boolean" then perms[key] = value end
        end
        self.serverPerms = perms
    end
    if kind == "lookup" then
        if args.ok == false then
            if args.username and args.username ~= self.lookupUser then return end
            self.lookupError = args.error or "unknown"
            self.lookup = nil
            self.receiptRows = {}
            self.receiptList:setItems({})
        elseif args.username ~= self.lookupUser then
            return -- stale: the admin already asked about someone else
        else
            self.lookupError = nil
            self.lookup = args
            self.lookupAt = EC.now()
            self.lookupFile = nil
            self:rebuildReceipts()
            -- the ring paints first; the receipt files (with rolled-back lines) replace it
            send("admin.receipts", { username = self.lookupUser })
            if self.dialog then self.dialog:updateInfo(); self:layoutDialog() end
        end
    elseif kind == "adjust" then
        local req = self.pendingAdjust
        if not req or req.username ~= args.username then return end
        if args.requestId and req.requestId and args.requestId ~= req.requestId then return end
        self.pendingAdjust = nil
        if args.ok then
            local msg
            if args.replay or args.duplicate then
                -- the ledger recognised the requestId: nothing was posted twice
                msg = { text = args.verified == false and tr("Admin_Adjust_ReplayUnverified") or tr("Admin_Adjust_Duplicate"),
                    error = args.verified == false }
            else
                msg = { text = getText(T .. "Admin_Adjust_Ok", signedText(req.delta), currencyName(req.currency), tostring(args.txId or "-")) }
            end
            self.message = msg
            self:closeDialog()
            self:requestLookup(req.username)
        elseif args.error == "revision_mismatch" or args.error == "request_conflict" or args.error == "expected_rev_required" then
            -- never silently re-post: the next confirm mints a fresh requestId over fresh data
            local key = args.error == "request_conflict" and "Admin_Adjust_Conflict" or "Admin_Adjust_Stale"
            local msg = { text = tr(key), error = true }
            if self.dialog then self.dialog.message = msg else self.message = msg end
            self:requestLookup(req.username)
        else
            self:dialogError(self.dialog, errorText(args.error))
        end
    elseif kind == "freeze" then
        local req = self.pendingFreeze
        if not req or req.username ~= args.username then return end
        self.pendingFreeze = nil
        if args.ok then
            self.message = { text = getText(T .. (args.frozen and "Admin_Freeze_Ok" or "Admin_Unfreeze_Ok"), tostring(req.username)) }
            self:closeDialog()
            self:requestLookup(req.username)
        else
            self:dialogError(self.dialog, errorText(args.error))
        end
    elseif kind == "accounts" then
        self.accRequestId = nil
        self.accountsPage:onReply(args)
    elseif kind == "currency" then
        -- the currency page's own read gate: the registry, the option snapshot behind the caps
        -- and the supply figures, all in one answer
        self.curRequestId = nil
        if args.ok == false then
            self.message = { text = errorText(args.error), error = true }
            return
        end
        if type(args.currencies) == "table" then C.currencies = args.currencies end
        if type(args.options) == "table" then
            self.options = args.options
            self.optionsSeen = C.options
        end
        self:adoptSupply(args)
        self:rebuildSettings()
        self:layout()
    elseif kind == "config" then
        local req = self.pendingConfig
        -- the write's reply states the supply it left behind, refusals included: the figures the
        -- currency page is showing belong to the state the server is running with now, whether or
        -- not the write went through
        self:adoptSupply(args)
        if not req then return end
        self.pendingConfig = nil
        if args.ok then
            if type(args.currencies) == "table" then C.currencies = args.currencies end
            self.message = { text = tr("Admin_Config_Ok") }
            self:closeDialog()
            self:layout()
        else
            self:dialogError(self.dialog, errorText(args.error))
        end
    elseif kind == "option" then
        -- every reply carries the whole snapshot, a refusal included, so the page always shows
        -- what the server actually runs with
        if type(args.currencies) == "table" then C.currencies = args.currencies end
        if type(args.options) == "table" then
            self.options = args.options
            self.optionsSeen = C.options
        end
        -- the reply named the write that is open (matchesReply refused anything else), so the
        -- id it reserved is released here; `req` is what says which key and which page asked
        if self.optionRequestId ~= nil and args.requestId == self.optionRequestId then
            self.optionRequestId = nil
        end
        local req = self.pendingOption
        local mine = req == nil or args.requestId == nil or req.requestId == args.requestId
        if mine then
            self.pendingOption = nil
            if args.ok then
                self.message = { text = args.warning and errorText(args.warning) or tr("Admin_Set_Saved"),
                    error = args.warning ~= nil }
                if args.warning then self.resetQueue = nil end
                self:closeDialog()
            else
                self.resetQueue = nil   -- a group reset stops at the first refusal
                self:dialogError(self.dialog, errorText(args.error))
            end
        end
        self:rebuildSettings()
        if mine and args.ok then self:nextOptionReset() end
        -- Season length uses the shared option slot; only its own reply may settle its draft.
        self.seasonsPage:onOptionReply(args, mine and req or nil)
        self.shopPage:onReply(kind, args)
    elseif kind == "catalog" then
        local req = self.pendingCatalog
        local mine = req == nil or args.requestId == nil or req.requestId == args.requestId
        if mine then
            self.pendingCatalog = nil
            if not args.ok then
                -- catalog_invalid carries the file's own parse error: the code alone would not
                -- tell the host which line to go and fix
                local body = errorText(args.error)
                if type(args.detail) == "string" and args.detail ~= "" then body = body .. ": " .. args.detail end
                self:dialogError(self.dialog, body)
            elseif req and req.action == "reload" then
                local file = args.file
                self.message = { text = getText(T .. "Admin_Shop_Reloaded", tostring((file and file.count) or args.count or 0)) }
            elseif req then
                self.message = { text = tr("Admin_Shop_Saved") }
                self:closeDialog()
            end
        end
        self.shopPage:onReply(kind, args)
    elseif kind == "listings" then
        -- Every reply carries the page and the exact seller it answered for, a refusal
        -- included. The seller is compared before a single row is adopted: an answer for an
        -- account the admin has already moved off must never be read as this account's rows --
        -- two names that look alike are two accounts.
        if type(args.items) == "table" and replySeller(args) == self.lstSeller then
            self.listings = args
            self.listingsAt = EC.now()
            self.lstPage = math.max(1, math.floor(tonumber(args.page) or 1))
            self.lstSentPage = self.lstPage   -- the server clamps the page; adopt it, never re-ask
            self:rebuildListings()
        end
        local req = self.pendingListings
        local mine = req == nil or args.requestId == nil or req.requestId == args.requestId
        if mine then
            self.pendingListings = nil
            if not args.ok then
                self:dialogError(self.dialog, errorText(args.error))
            elseif req and req.action == "delist" then
                self.message = { text = tr("Admin_Lst_Delisted") }
                self:closeDialog()
            end
        end
    elseif kind == "auctions" then
        -- the record read answers on the same command: it names itself (history = true) and
        -- never carries `items`, so the two shapes never touch each other's state
        if args.history == true then
            self:onAuctionHistoryReply(args)
        else
            -- every list reply carries the page and the exact seller back, a refusal included,
            -- so the page always shows what the server actually holds for the account asked for
            if type(args.items) == "table" and replySeller(args) == self.aucSeller then
                self.auctions = args
                self.auctionsAt = EC.now()
                self.aucPage = math.max(1, math.floor(tonumber(args.page) or 1))
                self.aucSentPage = self.aucPage   -- the server clamps the page; adopt it, never re-ask
                self:rebuildAuctions()
            end
            local req = self.pendingAuctions
            local mine = req == nil or args.requestId == nil or req.requestId == args.requestId
            if mine then
                self.pendingAuctions = nil
                if not args.ok then
                    self:dialogError(self.dialog, errorText(args.error))
                elseif req and req.action == "cancel" then
                    self.message = { text = tr("Auction_Cancelled") }
                    self:closeDialog()
                end
            end
        end
    elseif kind == "whitelist" then
        local req = self.pendingWhitelist
        local mine = req == nil or args.requestId == nil or req.requestId == args.requestId
        if mine then
            self.pendingWhitelist = nil
            if not args.ok then
                -- whitelist_invalid carries the file's own parse error: the code alone would not
                -- tell the host which line to go and fix
                local body = errorText(args.error)
                if type(args.detail) == "string" and args.detail ~= "" then body = body .. ": " .. args.detail end
                self.message = { text = body, error = true }
            elseif req and req.action == "reload" then
                self.message = { text = tr("Admin_Wl_Reloaded") }
            elseif req and req.action == "set" then
                self.message = { text = tr("Admin_Wl_Saved") }
            end
        end
        self.whitelistPage:onReply(kind, args)
    elseif kind == "icons" then
        if args.ok == false then
            self.message = { text = errorText(args.error), error = true }
            return
        end
        if type(args.icons) == "table" then self.icons = args.icons end
        if args.started then
            self.iconsReloading = true
            self.message = { text = tr("Admin_Icons_Started") }
        elseif args.busy then
            self.message = { text = tr("Admin_Icons_Busy") }
        elseif self.iconsReloading then
            -- the status re-check after a reload: replace the "reading..." line with the outcome
            self.iconsReloading = nil
            self.message = { text = tr("Admin_Icons_Done") }
        end
        -- the read runs over the next ticks: ask for the outcome once it had time to finish
        if args.busy then self.iconsRecheckAt = EC.now() + ICONS_RECHECK_MS end
    elseif kind == "audit" then
        self.auditRequestId = nil
        if args.ok == false then
            self.message = { text = errorText(args.error), error = true }
            return
        end
        self.audit = args.entries or {}
        self.auditSnapshotKey = self.auditSentKey
        self.auditAt = EC.now()
        self:onAuditActorsReply("ring", args)
        self:rebuildAudit()
    elseif kind == "receipts" then
        if args.error or args.username ~= self.lookupUser then return end
        self.lookupFile = args.entries or {}
        self:rebuildReceipts()
    elseif kind == "auditFile" then
        self.auditFileRequestId = nil
        -- a file read that failed is a failure, never "the record is empty": the older snapshot
        -- stays on screen and the note says what happened
        if args.error then
            self.auditFileMessage = { text = errorText(args.error), error = true }
            self.message = self.auditFileMessage
            return
        end
        self.auditFile = args.entries or {}
        self.auditFileSnapshotKey = self.auditFileSentKey
        if self.message == self.auditFileMessage then self.message = nil end
        self.auditFileMessage = nil
        self.auditFileAt = EC.now()
        self:onAuditActorsReply("file", args)
        self:rebuildAudit()
    elseif kind == "auditDetail" then
        self:onAuditDetailReply(args)
    elseif kind == "system" then
        if args.ok == false then
            self.message = { text = errorText(args.error), error = true }
            return
        end
        self.system = args
        self.systemAt = EC.now()
        self:adoptSupply(args)
        -- admin.system carries the option snapshot under `sandbox` (ECAdmin.system)
        if type(args.sandbox) == "table" then
            self.options = args.sandbox
            self.optionsSeen = C.options
        end
        self:layout()
    elseif kind == "sources" then
        -- every reply carries the full list, a write reply included
        if type(args.sources) == "table" then
            self.sources = args.sources
            self.sourcesAt = EC.now()
            self:rebuildSources()
        end
        local req = self.pendingSource
        if req and req.requestId == args.requestId then
            self.pendingSource = nil
            if args.ok then
                self.srcSelected = req.modId
                self.message = { text = tr("Admin_Src_Saved") }
                self:closeDialog()
            else
                self:dialogError(self.dialog, errorText(args.error))
            end
        elseif args.ok == false then
            self.message = { text = errorText(args.error), error = true }
        end
    elseif kind == "players" then
        -- two pickers share this command: the context and the requestId on the reply say which
        -- one asked for it. Neither ever takes the other's answer.
        if not self.picker:onReply(args) then self.txPage:onPlayersReply(args) end
    elseif kind == "marketHistory" then
        -- the reply names the account it answered for: anything else is a late answer to an
        -- account the admin has already moved on from, and is dropped
        if args.error ~= nil then
            self.message = { text = errorText(args.error), error = true }
        elseif type(args.entries) == "table" then
            local who = tostring(args.username or self.histSentUser or "")
            if self.histSentUser == nil or string.lower(who) == string.lower(self.histSentUser) then
                self.histUser = who
                self.marketHistory = args
                self.historyAt = EC.now()
                self:rebuildHistory()
            end
        end
    elseif kind == "transactions" or kind == "transaction" then
        self.txPage:onReply(kind, args)
    elseif kind == "recovery" then
        -- The slot has already been freed by the request that reserved it (matchesReply). The
        -- request travels into the page, which is how a server-wide read, an account read, a
        -- single decision and a queued one are told apart without trusting the reply to say which
        -- it was -- and the page decides for itself whether the answer still belongs to what it is
        -- showing (a page that was left, or one that has since moved to another question, applies
        -- nothing).
        local req = self.pendingRecovery
        self.pendingRecovery = nil
        if req ~= nil and req.requestId == args.requestId then
            self.recoveryPage:onReply(args, req)
        end
    elseif kind == "seasons" then
        -- The slot has already been freed by the request that reserved it (matchesReply). The
        -- request travels into the page, which is how a read and a rotation are told apart
        -- without trusting the reply to say which it was. Whichever owner it was is dropped
        -- here, so a second copy of the same answer can neither land nor free a newer read.
        local req = self.pendingSeason
        if req ~= nil and req.requestId == args.requestId then
            self.pendingSeason = nil
            self.seasonsPage:onReply(args, req)
        else
            -- nothing was open: this is the late answer to the request whose outcome was
            -- unknown, and it is what finally closes that one (matchesReply let nothing else
            -- through). It is reported, never re-sent.
            local lost = self.seasonUnknown
            if lost ~= nil and lost.requestId == args.requestId then
                self.seasonUnknown = nil
                self.seasonsPage:onReply(args, lost)
            end
        end
    end
    self:updateEnabled()
end

function Admin:onTimeout(command)
    -- a candidate query is a background nicety: it never takes over the footer, and the same
    -- text may be asked for again by whichever picker was waiting for it
    if command == "market.sellers" then
        -- the seller candidates are a background nicety too: the slot is freed, the boxes may
        -- ask for the same text again, and the footer is left alone
        lastSellersRequestId = nil
        self.lstSellerPicker:onTimeout()
        self.aucSellerPicker:onTimeout()
        return
    end
    if command == "admin.players" then
        self.picker:onTimeout()
        self.txPage:onTimeout(command)
        self:updateEnabled()
        return
    end
    local label = getTextOrNull(T .. "Admin_Cmd_" .. string.sub(command, 7)) or command
    self.message = { text = getText(T .. "Admin_Timeout", label), error = true }
    if command == "admin.option" then
        -- the write is no longer waited for, and a group reset stops where it stands. The id it
        -- reserved is kept on purpose (see matchesReply): that one late answer may still land,
        -- and keeping the id is what stops anything else from landing in its place.
        self.pendingOption = nil
        self.resetQueue = nil
    end
    if command == "admin.catalog" then self.pendingCatalog = nil end
    if command == "admin.listings" then
        self.pendingListings = nil
        self.lstRequestId = nil
    end
    if command == "admin.audit" then self.auditRequestId = nil end
    if command == "admin.auditFile" then self.auditFileRequestId = nil end
    -- The owner of the read that timed out is kept on purpose (see matchesReply): the slot is
    -- free again, and if that one answer still turns up late it may land -- but nothing else
    -- can, because the id names exactly that request. Dropping it here is what would let an
    -- unowned reply through.
    if command == "admin.accounts" then self.accountsPage:onTimeout(command) end
    if command == "admin.auditDetail" then
        -- the summary stays on screen and says so; the record is never faked from it
        self.auditDetailRequestId = nil
        self.auditDetailState = "read_failed"
        self:buildAuditDetail(true)
    end
    if command == "admin.auctions" then
        self.pendingAuctions = nil
        self.aucRequestId = nil
        -- the record read is forgotten as well, but its sent state is kept: the 30 s page poll
        -- (or the refresh chip) is what asks again, so a dead server is not hammered
        self.pendingAucHistory = nil
    end
    if command == "admin.whitelist" then self.pendingWhitelist = nil end
    if command == "admin.recovery" then
        -- the request that was open travels in: a read the page merely owes again is one thing, a
        -- write whose outcome nobody can know is another, and only the page can tell them apart
        local req = self.pendingRecovery
        self.pendingRecovery = nil
        self.recoveryPage:onTimeout(req)
        if self.dialog then
            self.dialog.message = { text = getText(T .. "Admin_Timeout", label), error = true }
            self:layoutDialog()
        end
    end
    if command == "admin.seasons" then
        -- A request whose answer never came has a genuinely unknown outcome: it is reported as
        -- one and, for a rotation, never sent again on its own. It stops owning the slot but
        -- keeps its identity (see matchesReply) so that one late answer can still close it --
        -- and nothing else can take its place.
        local req = self.pendingSeason
        self.pendingSeason = nil
        self.seasonUnknown = req
        self.seasonsPage:onTimeout(req)
        if self.dialog ~= nil and self.dialog.mode == "season" then
            self.dialog.message = { text = getText(T .. "Admin_Timeout", label), error = true }
            self:layoutDialog()
        end
    end
    if command == "admin.transaction" or command == "admin.transactions" then
        self.txPage:onTimeout(command)
    end
    if command == "admin.catalog" or command == "admin.option" then self.shopPage:onTimeout(command) end
    if command == "admin.whitelist" then self.whitelistPage:onTimeout(command) end
    if command == "admin.adjust" or command == "admin.freeze" or command == "admin.config" or command == "admin.sources" or command == "admin.option" or command == "admin.catalog" or command == "admin.listings" or command == "admin.auctions" then
        if self.dialog then
            self.dialog.message = { text = getText(T .. "Admin_Timeout", label), error = true }
            self:layoutDialog()
        end
    end
    self:updateEnabled()
end

-- ----- data normalisation (data or geometry changes only) -----

-- A fresh page must not silently drop the row the admin is reading: the same id is picked again
-- when the reply still carries it, and the pick is only cleared when the row really went away.
-- The rebuild's own pick is marked as such, so it may refresh a detail window that is open but
-- never opens one the admin has closed.
function Admin:reselect(list, rows, previous, apply)
    local id = previous and previous.id
    if id ~= nil then
        for i, row in ipairs(rows) do
            if row.id == id then
                list:setSelectedIndex(i)
                apply(self, row, true)
                return
            end
        end
    end
    list:setSelectedIndex(nil)
    apply(self, nil, true)
end

function Admin:rebuildReceipts()
    local rows = {}
    -- receipt file lines (delta / availableAfter) once they arrived, else the ring (amount / after)
    local src = self.lookupFile or (self.lookup and self.lookup.receipts) or {}
    local chipH = math.max(20, fontH.small + 6)
    local geo = receiptActionGeo(math.max(120, self.receiptList.width - 12), chipH,
        math.max(2, math.floor((self.receiptList.rowHeight - chipH) / 2)))
    for i = #src, 1, -1 do
        local e = src[i]
        local amount = tonumber(e.amount or e.delta) or 0
        local qty = tonumber(e.qty)      -- nil stays nil: never printed as one piece
        if e.after == nil then e.after = e.availableAfter end
        if e.before == nil then e.before = e.availableBefore end
        if e.kind == nil then e.kind = e.type end
        rows[#rows + 1] = {
            -- a txId alone is not unique across currencies: the band has to come back to the
            -- very line it was reading after a poll, so the identity carries all three
            id = tostring(e.txId or "-") .. "\1" .. tostring(e.ts or 0) .. "\1" .. tostring(e.currency or "-"),
            txId = e.txId, currency = e.currency, kind = e.kind, ts = e.ts, amount = amount,
            item = e.item, qty = e.qty, reasonText = U.reasonText(e.reason, e.reasonText),
            sourceMod = e.sourceMod, before = e.before, after = e.after,
            reservedBefore = e.reservedBefore, reservedAfter = e.reservedAfter,
            rolled = e.rolledBack == true, actions = geo,
            cells = {
                stampText(e.ts, self.offsetMin), currencyName(e.currency), signedText(amount),
                kindText(e.kind), amountText(e.after),
                (type(e.item) == "string" and (itemName(e.item)
                    .. (qty ~= nil and (" x" .. tostring(math.floor(qty))) or "") .. "  ") or "")
                    .. tostring(e.txId or "-"),
            },
            tokens = { "textMuted", "text", amount >= 0 and "positive" or "negative", "text", "text", "textFaint" },
            muted = e.rolledBack == true,
        }
    end
    self.receiptRows = rows
    self.receiptList:setItems(rows)
    self:reselect(self.receiptList, rows, self.selectedReceipt, Admin.onReceiptRow)
end

-- One audit action = one line in the files and one entry in the ring; the same fields identify it.
local function auditKey(e)
    return tostring(e.epoch) .. ":" .. tostring(e.seq) .. ":" .. tostring(e.ts) .. ":" .. tostring(e.action) .. ":" .. tostring(e.target or e.field)
end

-- The server now states the identity itself (X.auditKey: the new auditId where a line has one,
-- a stable compound identity for the older ones). The local form above is the fallback for a
-- reply that predates it, so ring and file lines still merge on one identity.
local function auditKeyOf(e)
    if type(e.key) == "string" and e.key ~= "" then return e.key end
    return auditKey(e)
end

function Admin:rebuildAudit()
    local f = self.auditF
    -- Sources: the audit files (this and last month) carry full reasons and the rolled-back lines;
    -- the ModData ring (40-char reasons) only adds what the files do not have (older months).
    -- "rolled" shows the rolled-back file lines alone.
    local fromFile = f.kind == "rolled"
    local src, seen = {}, {}
    local key = self:auditFilterKey()
    local file = self.auditFileSnapshotKey == key and self.auditFile or {}
    local ring = self.auditSnapshotKey == key and self.audit or {}
    for i = #file, 1, -1 do
        local e = file[i]
        if type(e) == "table" and (not fromFile or e.rolledBack == true) then
            seen[auditKeyOf(e)] = true
            src[#src + 1] = e
        end
    end
    if not fromFile then
        for _, e in ipairs(ring) do
            if type(e) == "table" and not seen[auditKeyOf(e)] then src[#src + 1] = e end
        end
    end
    -- The action chips are whatever the two reads carried, whichever source is on screen: the row
    -- must not lose a chip just because the admin is looking at the rolled-back lines.
    local actions, seenAction = {}, {}
    for _, list in ipairs({ file, ring }) do
        for _, e in ipairs(list or {}) do
            if type(e) == "table" then
                local a = tostring(e.action or "?")
                if not seenAction[a] then
                    seenAction[a] = true
                    actions[#actions + 1] = a
                end
            end
        end
    end
    EC.sortSafe(actions, function(a, b) return auditActionText(a) < auditActionText(b) end)
    if filterKinds(f, actions) then
        fromFile = f.kind == "rolled"
        self:layoutAuditFilters()
    end
    local q = self.auditQuery
    -- One entry per line that survives the source and the search box; the action, the day and the
    -- page are EC.filterPage's job, so the row it picks carries the strings already built for it.
    local matched = {}
    for _, e in ipairs(src) do
        if type(e) == "table" then
            local action = tostring(e.action or "?")
            local keep = not fromFile or e.rolledBack == true
            local target = e.target or e.field or "-"
            local targetText = auditTargetText(action, e.field, target)
            local delta = tonumber(e.delta)
            local change, changeToken
            if action == "config" then
                change = configValueText(e.before) .. " > " .. configValueText(e.after)
                changeToken = "text"
            elseif delta then
                change = signedText(delta)
                changeToken = delta >= 0 and "positive" or "negative"
            else
                -- the structural actions (whitelist / catalog / terminal) name a field, not money
                change = auditChangeText(e)
                changeToken = change and "text" or "textFaint"
                change = change or "-"
            end
            local reason = tostring(e.reason or "-")
            local txId = tostring(e.txId or "-")
            local admin = tostring(e.admin or "-")
            local actionText = auditActionText(action)
            local stamp = stampText(e.ts, self.offsetMin)
            if keep and q then
                local hay = string.lower(admin .. " " .. action .. " " .. actionText .. " "
                    .. tostring(target) .. " " .. targetText .. " " .. reason .. " " .. txId)
                keep = string.find(hay, q, 1, true) ~= nil
            end
            if keep then
                local rowKey = auditKeyOf(e)
                matched[#matched + 1] = { action = action, ts = tonumber(e.ts) or 0, row = {
                    cells = {
                        stamp, admin, actionText, targetText,
                        e.currency and currencyName(e.currency) or "-", change, reason, txId,
                    },
                    tokens = { "textMuted", "text", "text", "text", "textMuted", changeToken, "textMuted", "textFaint" },
                    muted = e.rolledBack == true,
                    -- what the detail band and the two copy chips read. `full` and `source` are
                    -- the server's own words about the line it sent: false means this is the
                    -- ring's 40-character summary and the whole text has to be asked for by
                    -- key and month.
                    -- `key` is the *record's* identity (the server's X.auditKey), and a legacy
                    -- line may share it with another that says something else. The selection id
                    -- carries this line's own content as well, so a rebuild comes back to the
                    -- line that was picked instead of the first one holding the same key.
                    id = rowKey .. "\1" .. admin .. "\1" .. targetText .. "\1" .. change
                        .. "\1" .. reason .. "\1" .. txId,
                    key = rowKey, month = e.month,
                    full = e.full == true, source = tostring(e.source or "ring"),
                    rawTarget = tostring(target), targetText = targetText, actionText = actionText,
                    adminName = admin, stamp = stamp, changeFull = change, reasonFull = reason,
                    txId = e.txId,
                } }
            end
        end
    end
    local picked, page, pages, total = EC.filterPage(matched, filterOptions(f, self, "action", "ts"))
    f.page, f.pages, f.total = page, pages, total
    local rows = {}
    for _, m in ipairs(picked) do rows[#rows + 1] = m.row end
    self.auditRows = rows
    self.auditTotal = #src
    self.auditList:setItems(rows)
    -- a filter switch, a page turn or a fresh read invalidates the picked line
    self:reselect(self.auditList, rows, self.auditSelected, Admin.onAuditRow)
end

-- Rejection counters arrive as a map; the drawn order has to be stable, so the rows are built
-- and sorted when the reply lands, never per frame.
function Admin:rebuildSources()
    self.sourceReader.ecRawText = nil
    for _, s in ipairs(self.sources or {}) do
        local rows = {}
        local rejected = type(s.today) == "table" and s.today.rejected or nil
        if type(rejected) == "table" then
            for code, n in pairs(rejected) do
                if (tonumber(n) or 0) > 0 then rows[#rows + 1] = { code = tostring(code), n = tonumber(n) or 0 } end
            end
            EC.sortSafe(rows, function(a, b) return a.code < b.code end)
        end
        s.rejectedRows = rows
    end
end

-- One row of the settings page: the option's state (value / default / override / locked) turned
-- into fitted strings, control hit boxes and y positions. The list width is known here, so the
-- cell never measures anything -- and the click test reads the very numbers the paint used.
function Admin:optionRow(spec, name, desc, snap, searching, width, lh, chipH, valueY)
    local state = snap[spec.key]
    local value = state and state.value
    local locked = spec.locked == true or (state ~= nil and state.locked == true)
    local override = state ~= nil and state.override == true and not locked
    -- Management controls remain visible but disabled without the native role capability.
    local manageOnly = spec.manageOnly == true or (state ~= nil and state.manageOnly == true)
    local item = {
        key = spec.key, spec = spec, plainName = name, missing = state == nil,
        locked = locked, override = override, manageOnly = manageOnly, hits = {},
        chipH = chipH, line1Y = 5, line2Y = 5 + lh, valueY = valueY,
    }
    local stepW = math.max(26, fontH.small + 8)
    local controlW = math.max(240, textWidth(optionValueText(spec, value)) + stepW * 2
        + textWidth(tr("Admin_Set_Edit")) + (override and textWidth(tr("Admin_Set_Reset")) or 0) + 64)
    local ctrlX = math.max(80, width - PAD - controlW)
    local right = width - PAD
    local valueRaw = nil
    -- the reset chip is pinned to the right edge, so the value column stays where it is
    if override then
        local label = tr("Admin_Set_Reset")
        local bw = textWidth(label) + 16
        right = right - bw
        item.hits[#item.hits + 1] = { id = "reset", x = right, w = bw, label = label }
        right = right - 4
    end
    if locked then
        valueRaw = optionValueText(spec, value)
        item.valueX, item.valueW = ctrlX, math.max(10, right - ctrlX)
        item.valueY = item.line1Y
        item.lockedText = fitText(tr("Admin_Set_Locked"), math.max(0, width - PAD - ctrlX))
    elseif spec.kind == "bool" then
        item.toggleOn = value == true
        item.toggleLabel = tr(item.toggleOn and "Admin_On" or "Admin_Off")
        item.hits[#item.hits + 1] = { id = "toggle", x = ctrlX, w = OPTION_TOGGLE_W }
    else
        local label = tr("Admin_Set_Edit")
        local bw = textWidth(label) + 16
        right = right - bw
        item.hits[#item.hits + 1] = { id = "edit", x = right, w = bw, label = label }
        right = right - 4
        if spec.kind == "int" or spec.kind == "number" then
            item.hits[#item.hits + 1] = { id = "minus", x = ctrlX, w = stepW, label = "-" }
            item.hits[#item.hits + 1] = { id = "plus", x = right - stepW, w = stepW, label = "+" }
            item.valueX = ctrlX + stepW + 4
            item.valueW = math.max(10, right - stepW - 8 - item.valueX)
            item.valueCentre = true
        else
            item.valueX = ctrlX
            item.valueW = math.max(10, right - ctrlX)
        end
        valueRaw = optionValueText(spec, value)
    end
    if valueRaw then item.valueText = fitText(valueRaw, item.valueW) end
    item.detailText = name .. "\n" .. optionValueText(spec, value) .. "\n" .. desc
    if locked then item.detailText = item.detailText .. "\n" .. tr("Admin_Set_Locked") end
    if override then item.detailText = item.detailText .. "\n" .. getText(T .. "Admin_Set_Overridden", optionValueText(spec, state.default)) end
    if manageOnly then
        item.detailText = item.detailText .. "\n" .. tr("Admin_Set_ManageOnly")
    end

    -- left column: [group] name over [overridden (default X)] description [runtime hint]
    local leftW = math.max(0, ctrlX - PAD * 2)
    item.nameX = PAD
    if searching then
        item.prefixText = fitText(tr("Admin_Set_Group_" .. spec.group), math.floor(leftW * 0.35))
        item.nameX = PAD + textWidth(item.prefixText) + 6
    end
    item.nameText = fitText(name, math.max(0, ctrlX - PAD - item.nameX))
    item.descX = PAD
    if override then
        item.overText = fitText(getText(T .. "Admin_Set_Overridden", optionValueText(spec, state.default)), math.floor(leftW * 0.5))
        item.descX = PAD + textWidth(item.overText) + 6
    end
    if spec.page then item.runtimeText = getText(T .. "Admin_Set_Runtime", tr("Admin_Tab_" .. spec.page)) end
    local runW = item.runtimeText and (textWidth(item.runtimeText) + 8) or 0
    item.descText = fitText(desc, math.max(0, ctrlX - PAD - item.descX - runW))
    if item.runtimeText then
        item.runtimeX = item.descX + textWidth(item.descText) + 8
        item.runtimeText = fitText(item.runtimeText, math.max(0, ctrlX - PAD - item.runtimeX))
    end
    return item
end

-- The selected group's options, or -- while the search box holds text -- every option whose
-- name, description or key contains it, across groups. Built when a snapshot lands, when the
-- search text or the group changes and when the geometry changes; never per frame.
function Admin:rebuildSettings()
    local rows = {}
    local snap = self.options
    if snap then
        local query = self.setQuery
        local list = self.settingsList
        local width = math.max(120, list.width - 12)   -- 12 = the scrollbar gutter
        local lh = lineH()
        local chipH = math.max(20, fontH.small + 6)
        local valueY = math.floor((list.rowHeight - fontH.small) / 2)
        for _, spec in ipairs(EC.OPTIONS) do
            local name = getTextOrNull("Sandbox_MinidoracatEconomy_" .. spec.key) or spec.key
            local desc = getTextOrNull("Sandbox_MinidoracatEconomy_" .. spec.key .. "_tooltip") or ""
            local take
            if query then
                take = string.find(string.lower(name), query, 1, true) ~= nil
                    or string.find(string.lower(desc), query, 1, true) ~= nil
                    or string.find(string.lower(spec.key), query, 1, true) ~= nil
            else
                take = spec.group == self.setGroup
            end
            if take then
                local row = self:optionRow(spec, name, desc, snap, query ~= nil, width, lh, chipH, valueY)
                rows[#rows + 1] = row
                self:showDetail("option", row.key, row.plainName, row.detailText, true)
            end
        end
    end
    self.settingRows = rows
    self.settingsList:setItems(rows)
end

-- Geometry of the right-hand strip of a market row (listings, auctions): identical for every
-- row, so it is computed once per rebuild and every row shares the very same table. `actions` is
-- the row's buttons in draw order; each entry carries the x / y / w / h C.RowActions places its
-- real button at, and what the strip leaves over is what the amount and the two text lines may
-- use -- so a large UI font shrinks the text instead of pushing the digits out of the row.
function Admin:rowChipGeometry(width, chipH, chipY, actions)
    local geo = { chipH = chipH, actions = {} }
    geo.priceW = math.max(60, textWidth("1,000,000") + 8)
    local x = width - PAD
    for i = #actions, 1, -1 do
        local a = actions[i]
        local bw = textWidth(a.label) + 20
        x = x - bw
        geo.actions[i] = { id = a.id, label = a.label, read = a.read, x = math.max(40, x),
            y = chipY, w = bw, h = chipH }
        x = x - ROW_ACTION_GAP
    end
    geo.priceRight = math.max(60, x + ROW_ACTION_GAP - 8)
    geo.textLimit = math.max(0, geo.priceRight - geo.priceW - PAD)
    return geo
end

-- The shared body of a market row: icon plus the localised item name (and its untranslated
-- name) on the first line, the amount on the right, the row's buttons after it. The caller fills
-- in metaText and detailText, the two parts the pages disagree on. `seller` is what the row
-- prints ("-" when the record names nobody); `sellerId` is the account itself, the only thing
-- the "this seller" jump may ask the server about.
function Admin:marketRow(entry, geo, lh, rowHeight, name, amount)
    local size = math.min(math.max(12, rowHeight - 10), 28)
    local seller = type(entry.seller) == "string" and entry.seller ~= "" and entry.seller or nil
    local item = {
        id = entry.id, seller = seller or "-", sellerId = seller, plainName = name,
        line1Y = 5, line2Y = 5 + lh, actions = geo.actions,
        icon = itemTexture(entry.item), iconSize = size, iconY = math.floor((rowHeight - size) / 2),
        priceRight = geo.priceRight, priceText = fitText(amountText(amount), geo.priceW),
    }
    item.nameX = PAD + size + 6
    item.textW = math.max(0, geo.textLimit - item.nameX)
    item.nameText = fitText(name, item.textW)
    local alt = itemBaseName(entry.item)
    if alt then
        item.altX = item.nameX + textWidth(item.nameText) + 8
        local altW = geo.textLimit - item.altX
        if altW > 20 then item.altText = fitText(alt, altW) end
    end
    return item
end

-- One listing row: the shared body plus "seller / category / expiry", and the whole record as
-- the detail window's text -- nothing the columns had to cut is lost to the reader.
function Admin:listingRow(l, geo, lh, rowHeight)
    local name = itemName(l.item)
    local item = self:marketRow(l, geo, lh, rowHeight, name, l.price)
    local meta = item.seller .. " / " .. categoryText(l.category) .. " / "
        .. tr("Market_Col_Expires") .. " " .. stampText(l.expiresAt, self.offsetMin)
    item.metaText = fitText(meta, item.textW)
    local detail = name
    local alt = itemBaseName(l.item)
    if alt then detail = detail .. "  (" .. alt .. ")" end
    item.detailText = detail .. "\n" .. tostring(l.item or "-") .. "\n" .. meta
        .. "\n" .. getText(T .. "Admin_Lst_DetailPrice", amountText(l.price))
        .. "\n" .. getText(T .. "Admin_Lst_DetailId", tostring(l.id or "-"))
    return item
end

-- The page the server last sent, turned into rows. Built when a reply lands and when the
-- geometry changes; never per frame.
function Admin:rebuildListings()
    local rows = {}
    local snap = self.listings
    if snap and type(snap.items) == "table" then
        local list = self.listingsList
        local width = math.max(120, list.width - 12)   -- 12 = the scrollbar gutter
        local chipH = math.max(20, fontH.small + 6)
        local geo = self:rowChipGeometry(width, chipH,
            math.max(3, math.floor((list.rowHeight - chipH) / 2)), listingActions())
        for _, l in ipairs(snap.items) do
            rows[#rows + 1] = self:listingRow(l, geo, lineH(), list.rowHeight)
        end
    end
    self.listingRows = rows
    self.listingsList:setItems(rows)
    self:reselect(self.listingsList, rows, self.selectedListing, Admin.onListingRow)
end

-- One auction row: the shared body (the amount is the standing high bid, or the start price
-- while nobody has bid) plus "seller / who holds it / bid count / time left". The remaining time
-- is a string built here, not per frame: the 30 s page poll refreshes it.
function Admin:auctionRow(a, geo, lh, rowHeight, now)
    local name = itemName(a.item)
    local qty = math.max(1, math.floor(tonumber(a.qty) or 1))
    local label = name
    if qty > 1 then label = label .. "  " .. getText(T .. "Market_Lot", tostring(qty)) end
    local bid = tonumber(a.bid)
    local item = self:marketRow(a, geo, lh, rowHeight, label, bid or a.startPrice)
    item.plainName = name   -- the cancel dialog names the item, never the lot size
    local holder = bid and (tr("Auction_Col_Bid") .. " " .. tostring(a.bidder or "-"))
        or tr("Auction_NoBids")
    local left = (tonumber(a.expiresAt) or 0) - now
    local ends = left > 0 and getText(T .. "Auction_Ends_In", U.durationText(left))
        or tr("Auction_Ended")
    local meta = item.seller .. " / " .. holder .. " / " .. tr("Auction_Col_Bids") .. " "
        .. tostring(math.max(0, math.floor(tonumber(a.bids) or 0))) .. " / " .. ends
    item.metaText = fitText(meta, item.textW)
    local detail = label
    local alt = itemBaseName(a.item)
    if alt then detail = detail .. "  (" .. alt .. ")" end
    detail = detail .. "\n" .. tostring(a.item or "-") .. "\n" .. meta
        .. "\n" .. getText(T .. "Admin_Auc_DetailStart", amountText(a.startPrice))
    if bid then
        detail = detail .. "\n" .. getText(T .. "Admin_Auc_DetailBid", amountText(bid),
            tostring(a.bidder or "-"))
    end
    item.detailText = detail .. "\n" .. tr("Market_Col_Expires") .. " "
        .. stampText(a.expiresAt, self.offsetMin)
        .. "\n" .. getText(T .. "Auction_History_Id", tostring(a.id or "-"))
    return item
end

function Admin:rebuildAuctions()
    local rows = {}
    local snap = self.auctions
    if snap and type(snap.items) == "table" then
        local list = self.auctionsList
        local width = math.max(120, list.width - 12)   -- 12 = the scrollbar gutter
        local chipH = math.max(20, fontH.small + 6)
        local geo = self:rowChipGeometry(width, chipH,
            math.max(3, math.floor((list.rowHeight - chipH) / 2)), auctionActions())
        local now = EC.now()
        for _, a in ipairs(snap.items) do
            rows[#rows + 1] = self:auctionRow(a, geo, lineH(), list.rowHeight, now)
        end
    end
    self.auctionRows = rows
    self.auctionsList:setItems(rows)
    self:reselect(self.auctionsList, rows, self.selectedAuction, Admin.onAuctionRow)
end

-- One auction record line: "kind / item / xN" over "time / auction id / the accounts involved",
-- the amount right aligned. The amount is what the auction was worth at that moment (the start
-- price, one bid, the winning bid), never a wallet delta -- so it is never signed and never
-- doubled into "the bidder paid this twice". A rolled-back line is struck through and labelled,
-- exactly like the wallet's own receipt rows.
function Admin:auctionHistoryRow(rec, lh, width)
    local kind = tostring(rec.kind or "?")
    local head = getTextOrNull(T .. "Market_Kind_" .. kind) or kind
    if type(rec.item) == "string" and rec.item ~= "" then
        head = head .. "  " .. itemName(rec.item)
        -- an old auction.bid line carries no qty: say nothing rather than invent a lot size
        local qty = math.floor(tonumber(rec.qty) or 0)
        if qty > 1 then head = head .. "  " .. getText(T .. "Market_Lot", tostring(qty)) end
    end
    local meta = stampText(rec.ts, self.offsetMin)
    if rec.auctionId ~= nil then
        meta = meta .. " / " .. getText(T .. "Auction_History_Id", tostring(rec.auctionId))
    end
    if type(rec.seller) == "string" and rec.seller ~= "" then
        meta = meta .. " / " .. getText(T .. "Auction_History_Seller", rec.seller)
    end
    if type(rec.bidder) == "string" and rec.bidder ~= "" then
        meta = meta .. " / " .. getText(T .. "Auction_History_Bidder", rec.bidder)
    end
    if type(rec.buyer) == "string" and rec.buyer ~= "" then
        meta = meta .. " / " .. getText(T .. "Auction_History_Buyer", rec.buyer)
    end
    if type(rec.previous) == "string" and rec.previous ~= "" then
        meta = meta .. " / " .. getText(T .. "Auction_History_Previous", rec.previous)
    end
    if type(rec.reason) == "string" and rec.reason ~= "" then meta = meta .. " / " .. rec.reason end
    local rolled = rec.rolledBack == true
    local rolledLabel = rolled and tr("Wallet_RolledBack") or nil
    -- a line with no price (a flow-back, a cancel, an old event that never carried one) shows no
    -- number: a printed 0 would read as "sold for nothing"
    local price = tonumber(rec.price)
    local amountLabel = "-"
    if price then
        amountLabel = amountText(price)
        if type(rec.currency) == "string" and rec.currency ~= "" then
            amountLabel = amountLabel .. " " .. currencyName(rec.currency)
        end
    end
    local right = math.max(60, width - PAD)
    local headW = math.max(0, right - textWidth(amountLabel) - PAD * 2)
    local metaW = rolled and math.max(0, headW - textWidth(rolledLabel) - PAD) or headW
    local item = {
        id = U.recordKey(rec), detailText = head .. "\n" .. amountLabel .. "\n" .. meta .. (rolled and ("\n" .. rolledLabel) or ""),
        line1Y = 5, line2Y = 5 + lh, amountRight = right, amountLabel = amountLabel,
        rolled = rolled, rolledLabel = rolledLabel,
        headText = fitText(head, headW), metaText = fitText(meta, metaW),
    }
    item.headW = textWidth(item.headText)
    return item
end

-- The record the server last sent, turned into one local page over the shared filter row. The
-- reply is oldest first (the server reads the event files forward) and every entry was tagged
-- with its position when it landed, so "time, newest first" is exactly the reversal the record
-- needs -- two bids in the same minute included.
function Admin:rebuildAuctionHistory()
    local f = self.aucF
    local snap = self.aucHistory
    local src = (snap and type(snap.entries) == "table") and snap.entries or {}
    local kinds, seenKind = {}, {}
    for _, rec in ipairs(src) do
        if type(rec) == "table" then
            local k = tostring(rec.kind or "?")
            if not seenKind[k] then
                seenKind[k] = true
                kinds[#kinds + 1] = k
            end
        end
    end
    EC.sortSafe(kinds, function(a, b) return f.label(a) < f.label(b) end)
    if filterKinds(f, kinds) then self:layoutAuctionFilters() end
    local picked, page, pages, total = EC.filterPage(src, filterOptions(f, self, "kind", "ts"))
    f.page, f.pages, f.total = page, pages, total
    local rows = {}
    local width = math.max(120, self.aucHistoryList.width - 12)   -- 12 = the scrollbar gutter
    local lh = lineH()
    for _, rec in ipairs(picked) do
        if type(rec) == "table" then rows[#rows + 1] = self:auctionHistoryRow(rec, lh, width) end
    end
    self.aucHistoryRows = rows
    local found = false
    for _, row in ipairs(rows) do
        if row.id == self.auctionHistoryDetailId then
            self:showDetail("auction_history", row.id, tr("Auction_History_Title"), row.detailText, true)
            found = true
        end
    end
    if not found then self:closeDetail("auction_history", self.auctionHistoryDetailId) end
    self.aucHistoryList:setItems(rows)
end

-- One history line: "kind / item / xN" over "time / counterparty / reason", the amount right
-- aligned. A rolled-back line is struck through and labelled, exactly like the wallet's own
-- receipt rows.
function Admin:historyRow(rec, lh, width)
    local kind = tostring(rec.kind or "?")
    local qty = math.max(1, math.floor(tonumber(rec.qty) or 1))
    local head = (getTextOrNull(T .. "Market_Kind_" .. kind) or kind) .. "  " .. itemName(rec.item)
    if qty > 1 then head = head .. "  " .. getText(T .. "Market_Lot", tostring(qty)) end
    local meta = stampText(rec.ts, self.offsetMin)
    if type(rec.other) == "string" and rec.other ~= "" then
        meta = meta .. " / " .. getText(T .. "Market_History_Other", rec.other)
    end
    if type(rec.reason) == "string" and rec.reason ~= "" then meta = meta .. " / " .. rec.reason end
    local rolled = rec.rolledBack == true
    local rolledLabel = rolled and tr("Wallet_RolledBack") or nil
    local amountLabel = amountText(rec.price)
    local right = math.max(60, width - PAD)
    local headW = math.max(0, right - textWidth(amountLabel) - PAD * 2)
    local metaW = rolled and math.max(0, headW - textWidth(rolledLabel) - PAD) or headW
    local item = {
        id = U.recordKey(rec), detailText = head .. "\n" .. amountLabel .. "\n" .. meta .. (rolled and ("\n" .. rolledLabel) or ""),
        line1Y = 5, line2Y = 5 + lh, amountRight = right, amountLabel = amountLabel,
        rolled = rolled, rolledLabel = rolledLabel,
        headText = fitText(head, headW), metaText = fitText(meta, metaW),
    }
    item.headW = textWidth(item.headText)
    return item
end

-- The history the server last sent, turned into one local page. The reply is oldest first (the
-- server reads the files forward); the default sort (time, newest first) turns it around.
function Admin:rebuildHistory()
    local f = self.histF
    local snap = self.marketHistory
    local src = (snap and type(snap.entries) == "table") and snap.entries or {}
    local kinds, seenKind = {}, {}
    for _, rec in ipairs(src) do
        if type(rec) == "table" then
            local k = tostring(rec.kind or "?")
            if not seenKind[k] then
                seenKind[k] = true
                kinds[#kinds + 1] = k
            end
        end
    end
    EC.sortSafe(kinds, function(a, b) return f.label(a) < f.label(b) end)
    if filterKinds(f, kinds) then self:layoutHistoryFilters() end
    local picked, page, pages, total = EC.filterPage(src, filterOptions(f, self, "kind", "ts"))
    f.page, f.pages, f.total = page, pages, total
    local rows = {}
    local width = math.max(120, self.historyList.width - 12)   -- 12 = the scrollbar gutter
    local lh = lineH()
    for _, rec in ipairs(picked) do
        if type(rec) == "table" then rows[#rows + 1] = self:historyRow(rec, lh, width) end
    end
    self.historyRows = rows
    local found = false
    for _, row in ipairs(rows) do
        if row.id == self.marketHistoryDetailId then
            self:showDetail("market_history", row.id, tr("Admin_Lst_History"), row.detailText, true)
            found = true
        end
    end
    if not found then self:closeDetail("market_history", self.marketHistoryDetailId) end
    self.historyList:setItems(rows)
end

-- ----- enable state (permission, in-flight command, data presence) -----

-- Omitted verdicts stay in force. A changed grant invalidates only its own verdict;
-- changing role identity invalidates them all.
function Admin:syncPermissionContext(force)
    local level, manage = accessLevel(), P.canManage()
    if force or level ~= self.lastLevel or C.options ~= self.permissionOptions or manage ~= self.permissionManage then
        local write, read, own = P.canWrite(), P.canRead(), P.canSelfAdjust()
        if level ~= self.lastLevel then
            self.serverPerms = nil
        elseif self.serverPerms then
            if write ~= self.permissionWrite then self.serverPerms.write = nil end
            if read ~= self.permissionRead then self.serverPerms.read = nil end
            if own ~= self.permissionSelfAdjust then self.serverPerms.selfAdjust = nil end
            if manage ~= self.permissionManage then self.serverPerms.manage = nil end
        end
        self.lastLevel, self.permissionOptions, self.permissionManage = level, C.options, manage
        self.permissionWrite, self.permissionRead, self.permissionSelfAdjust = write, read, own
    end
end

-- Local role read (getAccessLevel + sandbox lists) AND, once a reply has told us, the level the
-- server actually enforced. Either side saying no means no.
function Admin:writeAllowed()
    self:syncPermissionContext()
    if not P.canWrite() then return false end
    return not (self.serverPerms and self.serverPerms.write == false)
end

function Admin:readAllowed()
    self:syncPermissionContext()
    if not P.canRead() then return false end
    return not (self.serverPerms and self.serverPerms.read == false)
end

-- Native capability plus any current server veto. Not every reply carries this field.
function Admin:manageAllowed()
    self:syncPermissionContext()
    if not P.canManage() then return false end
    return not (self.serverPerms and self.serverPerms.manage == false)
end

-- May the actor adjust their *own* balance? The write role plus the explicit grant, and the
-- server's own verdict (admin.lookup states selfAdjust) can only take it away.
function Admin:selfAdjustAllowed()
    self:syncPermissionContext()
    if not P.canSelfAdjust() then return false end
    return not (self.serverPerms and self.serverPerms.selfAdjust == false)
end

-- Is the account on the player page this very admin? Freezing it stays refused whatever the
-- grant says: an admin who locks themselves out cannot unlock themselves again.
function Admin:isSelfTarget()
    local player = getPlayer()
    if player == nil or self.lookupUser == nil then return false end
    return self.lookupUser == player:getUsername()
end

-- The right the open dialog was opened with, re-asked. A settings dialog asks per option (or
-- per reset queue), a self adjustment asks for its own grant, and every other write dialog
-- asks for the economy write role. It drives the confirm button and, on the permission poll,
-- decides whether a dialog whose right was taken away is still allowed to stand open.
function Admin:dialogAllowed()
    local dlg = self.dialog
    if dlg == nil then return false end
    if dlg.optionKey ~= nil then return self:optionAllowed(EC.OPTION_BY_KEY[dlg.optionKey]) end
    if dlg.optionGroup ~= nil then return #self:overriddenKeys(dlg.optionGroup) > 0 end
    -- A rotation is the native role capability and nothing else: it must not fall through to
    -- the economy write role the line below applies, in either direction -- an economy admin
    -- without the capability may not confirm it, and a role manager who is not an economy admin
    -- may. Without this the confirm button would be switched off by the permission poll for the
    -- very people the page is for.
    if dlg.mode == "season" then return self:manageAllowed() end
    if not self:writeAllowed() then return false end
    if dlg.mode == "adjust" and self:isSelfTarget() then return self:selfAdjustAllowed() end
    return true
end

function Admin:updateEnabled()
    local write = self:writeAllowed()
    local manage = self:manageAllowed()
    -- readAllowed already counts the native capability as a way in (P.canRead), and it is the
    -- one place the server's read verdict is applied: a server that says "no reading" is not
    -- talked out of it by a local capability
    local read = write or self:readAllowed()
    local modal = self:isModal()
    for _, b in ipairs(self.subTabButtons) do b:setEnable(read and not modal) end
    local me = getPlayer() and getPlayer():getUsername() or nil
    local found = self.lookup ~= nil and self.lookup.found == true
    local selfTarget = me ~= nil and self.lookupUser == me

    self.picker:setEditable(read and not modal)
    self.lookupButton:setEnable(read and not modal and not isPending("admin.lookup"))
    self.refreshButton:setEnable(read and not modal)
    -- the account status card's three entries: all three are reads of one account, so they need
    -- a target that really exists and nothing else
    local lookupRead = read and not modal and found
    self.moneyButton:setEnable(lookupRead)
    self.lstJumpButton:setEnable(lookupRead)
    self.aucJumpButton:setEnable(lookupRead)
    -- The reconciliation desk is a read of one account as well: it lists what the server is
    -- holding. A read-only role opens it and can decide nothing inside it -- the desk gates its
    -- own decisions. The label carries the held count so the entry says whether there is
    -- anything to do before it is pressed; layout() sized it for the longer of the two labels,
    -- so the count appearing never shortens the word in front of it.
    self.recoveryButton:setEnable(lookupRead)
    local held = self.lookup and tonumber(self.lookup.recoveryHeld) or nil
    U.setButtonTitle(self.recoveryButton, (held ~= nil and held > 0)
        and getText(T .. "Admin_Rec_OpenCount", tostring(math.floor(held)))
        or tr("Admin_Rec_Open"))
    self.freezeAuditButton:setEnable(lookupRead and self.lookup.frozen == true)
    local showFreezeAudit = self.tab == "Player" and read and found and self.lookup.frozen == true
    self.freezeAuditButton:setVisible(showFreezeAudit)
    if self.g then
        self.g.actionNoteX = self.freezeAuditButton.x + (showFreezeAudit and (self.freezeAuditButton.width + PAD) or 0)
    end

    local canWriteTarget = write and found and not modal
    -- Paying your own account is a grant of its own (AdminSelfAdjustRoles); freezing it is
    -- never allowed, granted or not -- an admin who locks themselves out cannot get back in.
    local selfOk = not selfTarget or self:selfAdjustAllowed()
    self.adjustButton:setEnable(canWriteTarget and selfOk and not isPending("admin.adjust"))
    self.freezeButton:setEnable(canWriteTarget and not selfTarget and not isPending("admin.freeze"))
    U.setButtonTitle(self.freezeButton, self.lookup and self.lookup.frozen and tr("Admin_Player_Unfreeze") or tr("Admin_Player_Freeze"))

    local def = currencyDef(self:selectedCurrency())
    local cfgWrite = write and not modal and not isPending("admin.config")
    self.renameButton:setEnable(cfgWrite)
    self.toggleButton:setEnable(cfgWrite)
    U.setButtonTitle(self.toggleButton, (def == nil or def.enabled ~= false) and tr("Admin_Cur_Disable") or tr("Admin_Cur_Enable"))
    self.rateButton:setEnable(cfgWrite and def ~= nil and type(def.exchange) == "table")
    self.balanceMaxButton:setEnable(cfgWrite)
    self.iconsButton:setEnable(write and not modal and not isPending("admin.icons") and self.iconsRecheckAt == nil)
    local curId = self:selectedCurrency()
    -- A cap is edited through the option command, so the chip follows *that* write, not
    -- admin.config; a build whose config slice names no option for the pair keeps it disabled
    -- rather than offering a shortcut into nothing.
    local optWriteNow = write and not modal and not isPending("admin.option")
    self.buybackAccountButton:setEnable(optWriteNow and buybackOptionKey(curId, "account") ~= nil)
    self.buybackServerButton:setEnable(optWriteNow and buybackOptionKey(curId, "server") ~= nil)
    -- "who holds this" is a read: a read-only role uses it
    self.curHoldersButton:setEnable(read and not modal)
    for _, b in ipairs(self.dashIssueButtons) do b:setEnable(read and not modal) end
    self.dashNoteButton:setEnable(read and not modal)
    for _, b in ipairs(self.dashHolderButtons) do b:setEnable(read and not modal) end
    for _, b in ipairs(self.playerModeButtons) do b:setEnable(read and not modal) end

    local src = self:selectedSource()
    local srcWrite = write and not modal and not isPending("admin.sources") and src ~= nil
    self.srcCapsButton:setEnable(srcWrite)
    self.srcToggleButton:setEnable(srcWrite)
    U.setButtonTitle(self.srcToggleButton, (src == nil or src.enabled ~= false) and tr("Admin_Src_Disable") or tr("Admin_Src_Enable"))

    setEntryEditable(self.auditEntry, read and not modal)
    setEntryEditable(self.auditActorEntry, read and not modal)
    filterEnable(self.auditF, read and not modal)
    local picked = read and not modal and self.auditSelected ~= nil
    self.auditCopyNameButton:setEnable(picked)
    self.auditCopyIdButton:setEnable(picked)
    for _, b in ipairs(self.copyButtons) do
        local paths = self.system and self.system.paths
        b:setEnable(not modal and paths ~= nil and type(paths[b.internal]) == "string")
    end

    self.shopPage:updateEnabled()

    -- listings page: one in-flight listings command at a time; the page chips follow the
    -- snapshot, and a read-only role browses without ever arming a delist
    local lstWrite = write and not modal and not isPending("admin.listings")
    self.listingsList.optionsDisabled = not lstWrite
    setEntryEditable(self.lstEntry, read and not modal)
    local lstPage, lstPages = 1, 1
    if self.listings then
        lstPage = math.max(1, math.floor(tonumber(self.listings.page) or 1))
        lstPages = math.max(1, math.floor(tonumber(self.listings.pages) or 1))
    end
    local lstRead = read and not modal and not isPending("admin.listings")
    self.lstPrevButton:setEnable(lstRead and lstPage > 1)
    self.lstNextButton:setEnable(lstRead and lstPage < lstPages)
    self.lstHistoryButton:setEnable(read and not modal)
    self.lstSellerPicker:setEditable(read and not modal and self.lstMode ~= "history")
    self.lstSellerClearButton:setEnable(lstRead and self.lstSeller ~= nil)
    filterEnable(self.histF, read and not modal)

    -- auctions page: one in-flight auctions command at a time; the page chips follow the
    -- snapshot, and a read-only role browses without ever arming a cancel
    local aucBusy = isPending("admin.auctions")
    self.auctionsList.optionsDisabled = not (write and not modal and not aucBusy)
    setEntryEditable(self.aucEntry, read and not modal)
    local aucPage, aucPages = 1, 1
    if self.auctions then
        aucPage = math.max(1, math.floor(tonumber(self.auctions.page) or 1))
        aucPages = math.max(1, math.floor(tonumber(self.auctions.pages) or 1))
    end
    local aucRead = read and not modal and not aucBusy
    self.aucPrevButton:setEnable(aucRead and aucPage > 1)
    self.aucNextButton:setEnable(aucRead and aucPage < aucPages)
    -- the two mode chips and the record's own filter row are reads: a read-only role switches to
    -- the record and searches it, it just never arms the cancel chip
    self.aucActiveButton:setEnable(read and not modal)
    self.aucHistoryButton:setEnable(read and not modal)
    self.aucSellerPicker:setEditable(read and not modal and self.aucMode ~= "history")
    self.aucSellerClearButton:setEnable(aucRead and self.aucSeller ~= nil)
    filterEnable(self.aucF, read and not modal)

    self.txPage:updateEnabled()

    self.whitelistPage:updateEnabled()

    -- Settings page: one in-flight option write at a time, and one right per row. The manage
    -- options follow the native role capability and every other option the write role, so a
    -- role manager who is not an economy admin sees exactly those live, and an economy admin
    -- without the capability sees everything but them. A read-only role sees neither.
    local optBusy = modal or not read or isPending("admin.option")
    self.settingsList.optionsDisabled = optBusy or not (write or manage)
    self.settingsList.denyWrite = not write
    self.settingsList.denyManage = not manage
    setEntryEditable(self.setEntry, read and not modal)
    -- the queue is already filtered to what this actor may reset, so its size is the answer
    self.setResetButton:setEnable(not optBusy and #self:overriddenKeys(self.setGroup) > 0)
    self.recoveryPage:updateEnabled()
    self.accountsPage:updateEnabled()
    self.seasonsPage:updateEnabled()
    local dlg = self.dialog
    if dlg then
        local mayConfirm = self:dialogAllowed()
        local busy = isPending("admin.adjust") or isPending("admin.freeze") or isPending("admin.config") or isPending("admin.sources") or isPending("admin.option") or isPending("admin.catalog") or isPending("admin.listings") or isPending("admin.auctions") or isPending("admin.recovery") or isPending("admin.seasons")
        local ok = mayConfirm and not busy
        -- a decision over data the server could not prove needs its own explicit acceptance
        -- first: until the gate is ticked the confirm button is not pressable at all
        if dlg.requireAccept and dlg.accepted ~= true then ok = false end
        -- and a role list is never saved against a guess: no native list, no save
        if dlg.roleSpec ~= nil and dlg.roleChoices == nil then ok = false end
        dlg.confirmButton:setEnable(ok)
        dlg:setRolesEnabled(mayConfirm and not busy)
    end
end

-- ----- geometry -----

-- Where the two filter rows sit. Both are called from layout() -- and again from their own
-- rebuild when a reply changed the set of chips, because a chip has to be placed before it can
-- be clicked. Neither reads anything layout() has not already put on self.g.
function Admin:layoutAuditFilters()
    local g = self.g
    if g == nil then return end
    local visible = self:readAllowed() and self.tab == "Audit"
    local chipH = math.max(20, fontH.small + 6)
    local x = self.auditEntry.width + PAD + self.auditActorEntry.width + PAD
    g.auditCountX = filterLayoutKinds(self.auditF, visible, x, self.auditEntry.y
        + math.floor((entryH() - chipH) / 2), math.max(60, self.width - x - PAD), chipH) + PAD
    filterLayoutRow(self.auditF, visible, 0, g.auditFilterY, self.width, entryH(), chipH)
end

function Admin:layoutHistoryFilters()
    local g = self.g
    if g == nil then return end
    local visible = self:readAllowed() and self.tab == "Listings" and self.lstMode == "history"
    local chipH = math.max(20, fontH.small + 6)
    local w = math.max(60, self.width - PAD * 2)
    filterLayoutKinds(self.histF, visible, PAD, g.histKindY, w, chipH)
    filterLayoutRow(self.histF, visible, PAD, g.histRowY, w, entryH(), chipH)
end

function Admin:layoutAuctionFilters()
    local g = self.g
    if g == nil then return end
    local visible = self:readAllowed() and self.tab == "Auctions" and self.aucMode == "history"
    local chipH = math.max(20, fontH.small + 6)
    local w = math.max(60, self.width - PAD * 2)
    filterLayoutKinds(self.aucF, visible, PAD, g.aucKindY, w, chipH)
    filterLayoutRow(self.aucF, visible, PAD, g.aucRowY, w, entryH(), chipH)
end

-- Fair share with redistribution, shared by the currencies and the sources action row: a button
-- whose natural width is below its share keeps it and what it leaves over goes to the wider ones
-- (an equal split would truncate the longest label at the minimum window with large fonts).
-- `items` is {button, natural width} pairs in draw order; the row starts at x and steps by 6.
local function fairShareButtons(items, visible, x, y, totalW, height)
    local byNeed = {}
    for i = 1, #items do byNeed[i] = items[i] end
    EC.sortSafe(byNeed, function(a, b) return a[2] < b[2] end)
    local remaining = totalW - 6 * (#items - 1)
    local width = {}
    for i, item in ipairs(byNeed) do
        local share = math.floor(remaining / (#byNeed - i + 1))
        local bw = math.max(40, math.min(item[2], share))
        width[item[1]] = bw
        remaining = remaining - bw
    end
    for _, item in ipairs(items) do
        local b = item[1]
        b:setVisible(visible)
        b:setHeight(height)
        b:setWidth(width[b])
        b:setX(x); b:setY(y)
        U.setButtonTitle(b, b.fullTitle)
        x = x + b.width + 6
    end
end

function Admin:layout()
    local w, h = self.width, self.height
    local sub = math.max(24, fontH.small + 12)
    local lh = lineH()
    local g = {}
    g.subH = sub
    g.footerH = lh + 2
    g.bodyY = sub + PAD
    g.bodyH = math.max(60, h - g.bodyY - g.footerH)
    g.footerY = h - g.footerH
    self.g = g
    self.setMessageButton:setX(0)
    self.setMessageButton:setY(g.footerY + 1)
    self.setMessageButton:setWidth(math.max(1, w - PAD * 2))
    self.setMessageButton:setHeight(g.footerH - 2)
    U.setButtonTitle(self.setMessageButton, self.setMessageButton.fullTitle)

    -- Navigation lives in the window's sidebar; this row only carries freshness and refresh.
    local refreshW = math.min(textWidth(self.refreshButton.fullTitle) + 24, math.floor(w * 0.25))
    self.refreshButton:setWidth(refreshW)
    self.refreshButton:setHeight(math.max(24, fontH.small + 6))
    self.refreshButton:setX(w - refreshW)
    self.refreshButton:setY(math.floor((sub - self.refreshButton.height) / 2))
    U.setButtonTitle(self.refreshButton, self.refreshButton.fullTitle)

    -- permission is re-read here (layout runs on size / tab / permission changes, never per frame)
    local read = self:readAllowed()
    self.hadWrite = self:writeAllowed()
    self.hadRead = read
    self.hadManage = self:manageAllowed()
    self.hadSelfAdjust = self:selfAdjustAllowed()
    -- the player tab has two modes: the whole account list, and the one account being operated
    -- on. `player` is the operate mode -- every control of it is hidden while the list is up.
    local playerTab = read and self.tab == "Player"
    local accounts = playerTab and self.playerMode == "list"
    local player = playerTab and not accounts
    local currencies = read and self.tab == "Currencies"
    local audit = read and self.tab == "Audit"
    local system = read and self.tab == "System"
    local sources = read and self.tab == "Sources"
    local settings = read and self.tab == "Settings"
    local shop = read and self.tab == "Shop"
    local listings = read and self.tab == "Listings"
    local auctions = read and self.tab == "Auctions"
    local tx = read and self.tab == "Transactions"
    local whitelist = read and self.tab == "Whitelist"
    local recovery = read and self.tab == "Recovery"
    for _, b in ipairs(self.subTabButtons) do b:setVisible(read) end
    self.refreshButton:setVisible(read)

    -- player page: the two mode chips own the first row of the body, so the switch is in the
    -- same place whichever mode is up. Under it, either the account list (its own sub page) or
    -- the operate mode's account picker with the lookup chip beside it.
    local eh = entryH()
    local modeH = math.max(24, fontH.small + 6)
    g.playerModeY = g.bodyY
    local modeX = 0
    for _, b in ipairs(self.playerModeButtons) do
        b:setVisible(playerTab)
        b:setWidth(math.min(textWidth(b.fullTitle) + 24, math.max(40, math.floor(w * 0.24))))
        b:setHeight(modeH); b:setX(modeX); b:setY(g.playerModeY)
        U.setButtonTitle(b, b.fullTitle)
        modeX = modeX + b.width + 6
    end
    g.playerBodyY = g.bodyY + modeH + 4
    g.queryY = g.playerBodyY
    local pickW = math.min(200, math.floor(w * 0.25))
    self.picker:setVisible(player)
    self.picker:layout(0, g.queryY, pickW, math.max(0, h - g.queryY - eh - 2))
    self.lookupButton:setVisible(player)
    self.lookupButton:setWidth(math.min(textWidth(self.lookupButton.fullTitle) + 26, math.floor(w * 0.2)))
    self.lookupButton:setHeight(eh)
    self.lookupButton:setX(pickW + 6); self.lookupButton:setY(g.queryY)
    U.setButtonTitle(self.lookupButton, self.lookupButton.fullTitle)
    g.statusX = self.lookupButton.x + self.lookupButton.width + PAD

    -- the account list takes the whole body under the mode chips; visibility first, so its own
    -- resize re-runs that decision for its chips and rows
    self.accountsPage:setVisible(accounts and self:getIsVisible())
    self.accountsPage:setX(0)
    self.accountsPage:setY(g.playerBodyY)
    self.accountsPage:resize(w, math.max(80, g.bodyY + g.bodyH - g.playerBodyY))

    local actionH = btnH()
    g.cardsY = g.queryY + eh + 6
    g.actionY = g.bodyY + g.bodyH - actionH
    g.cardsH = math.max(60, g.actionY - 6 - g.cardsY)
    -- The two summary cards are measured from the widest line they can really print -- a
    -- balance, a currency name, a reset stamp, a daily row -- instead of taking a fixed share
    -- of the window: the receipt table is the one that needs the room, and a card with little
    -- to say gives its share back to it. What the pair may take together is capped at half the
    -- row, so the receipts always keep the larger half; inside that cap both shrink in
    -- proportion to what they asked for, and the balances and stamps they print stay whole for
    -- as long as the window allows it.
    local moneySample = amountText(999999999)
    local coinW = math.max(24, fontH.medium + 8)
    local nameW, dailyW = 0, 0
    for _, id in ipairs(currencyOrder(self.lookup)) do
        nameW = math.max(nameW, textWidth(currencyName(id), UIFont.Medium))
        dailyW = math.max(dailyW, textWidth(getText(T .. "Admin_Player_DailyRow",
            currencyName(id), moneySample, moneySample)))
    end
    local leftNeed = math.max(150,
        textWidth(tr("Wallet_Available")) + PAD + textWidth(moneySample) + PAD * 2 + 10,
        coinW + 6 + nameW + 20)
    local midNeed = math.max(150, dailyW + PAD * 2,
        textWidth(getText(T .. "Admin_Player_NextReset", U.STAMP_SAMPLE)) + PAD * 2,
        textWidth(getText(T .. "Admin_Player_ServerDaily", moneySample, moneySample, moneySample)) + PAD * 2,
        textWidth(getText(T .. "Admin_Player_Listings", "999", "999")) + PAD * 2)
    local cardBudget = math.max(300, math.floor((w - PAD * 2) * 0.5))
    g.leftW, g.midW = leftNeed, midNeed
    if leftNeed + midNeed > cardBudget then
        g.leftW = math.max(150, math.floor(cardBudget * leftNeed / (leftNeed + midNeed)))
        g.midW = math.max(150, cardBudget - g.leftW)
    end
    g.midX = g.leftW + PAD
    g.rightX = g.midX + g.midW + PAD
    g.rightW = math.max(180, w - g.rightX)

    -- action row: adjust takes at most a third, freeze is sized for the longer of its two labels
    self.adjustButton:setVisible(player)
    self.adjustButton:setHeight(actionH)
    self.adjustButton:setWidth(math.min(math.max(140, textWidth(self.adjustButton.fullTitle, UIFont.Medium) + 40), math.floor(w * 0.34)))
    self.adjustButton:setX(0); self.adjustButton:setY(g.actionY)
    U.setButtonTitle(self.adjustButton, self.adjustButton.fullTitle, UIFont.Medium)
    self.freezeButton:setVisible(player)
    self.freezeButton:setHeight(actionH)
    local freezeW = math.max(textWidth(tr("Admin_Player_Unfreeze")), textWidth(tr("Admin_Player_Freeze"))) + 30
    self.freezeButton:setWidth(math.min(math.max(120, freezeW), math.floor(w * 0.3)))
    self.freezeButton:setX(self.adjustButton.width + 6); self.freezeButton:setY(g.actionY)
    U.setButtonTitle(self.freezeButton, self.freezeButton.fullTitle)
    g.actionNoteX = self.freezeButton.x + self.freezeButton.width + PAD
    self.freezeAuditButton:setX(g.actionNoteX)
    self.freezeAuditButton:setY(g.actionY)
    self.freezeAuditButton:setHeight(actionH)
    self.freezeAuditButton:setWidth(math.max(40, math.min(textWidth(self.freezeAuditButton.fullTitle) + 24, w - g.actionNoteX)))
    U.setButtonTitle(self.freezeAuditButton, self.freezeAuditButton.fullTitle)

    -- The status card's own entries, under the lines they belong to: the reconciliation desk
    -- sits directly beneath the "N records awaiting reconciliation" line that card prints, which
    -- is the one place a host reading that number looks for something to do about it. Narrow
    -- cards (or a scaled-up UI font) move the pair of market jumps onto a second line instead of
    -- shrinking any of the four past its label -- an entry that reads as three dots is an entry
    -- nobody finds.
    local jumpH, jumpW = math.max(20, fontH.small + 8), math.max(60, g.midW - PAD * 2)
    local recoveryNeed = math.max(textWidth(tr("Admin_Rec_Open")),
        textWidth(getText(T .. "Admin_Rec_OpenCount", "999"))) + 24
    local jumps = { { self.recoveryButton, recoveryNeed },
        { self.moneyButton, textWidth(self.moneyButton.fullTitle) + 24 },
        { self.lstJumpButton, textWidth(self.lstJumpButton.fullTitle) + 24 },
        { self.aucJumpButton, textWidth(self.aucJumpButton.fullTitle) + 24 } }
    local wrapJumps = jumps[1][2] + jumps[2][2] + jumps[3][2] + jumps[4][2] + 18 > jumpW
    g.statusButtonY = g.cardsY + g.cardsH - PAD - (wrapJumps and (jumpH * 2 + 6) or jumpH)
    g.statusBottom = g.statusButtonY - 4
    if wrapJumps then
        fairShareButtons({ jumps[1], jumps[2] }, player, g.midX + PAD, g.statusButtonY, jumpW, jumpH)
        fairShareButtons({ jumps[3], jumps[4] }, player, g.midX + PAD, g.statusButtonY + jumpH + 6, jumpW, jumpH)
    else
        fairShareButtons(jumps, player, g.midX + PAD, g.statusButtonY, jumpW, jumpH)
    end
    local summaryY = g.cardsY + CARD_TITLE_H + 4
    U.placeList(self.summaryList, player, 4, summaryY, g.leftW - 8, math.max(1, g.cardsY + g.cardsH - summaryY - 4))
    self.statusReader:setVisible(player)
    self.statusReader:setX(g.midX + 2); self.statusReader:setY(g.cardsY + CARD_TITLE_H + 4)
    self.statusReader:setWidth(math.max(40, g.midW - 4))
    self.statusReader:setHeight(math.max(fontH.small + 10, g.statusBottom - self.statusReader.y))
    self:refreshPlayerStatus()

    -- receipts table inside the right card: it owns the whole card, because a picked line is
    -- read in the detail window instead of in a band that used to take the rows' room. The
    -- columns stop short of the row action strip, so no text is ever painted under the button.
    local rh = rowH()
    g.receiptHeaderY = g.cardsY + CARD_TITLE_H + lh
    local listY = g.receiptHeaderY + rh
    local listW = math.max(120, g.rightW - 2)
    local receiptH = math.max(rh, g.cardsY + g.cardsH - listY - 2)
    U.placeList(self.receiptList, player, g.rightX + 1, listY, listW, receiptH)
    layoutColumns(self.receiptList, receiptSpec(), listW - 12 - receiptActionsW())
    g.receiptBottom = listY + receiptH

    -- Dashboard: the issued card on the left reads one currency at a time (its chips sit in the
    -- card's title row area), and every supply column to the right of it carries its own entry
    -- into the account list, sorted by that very currency. The geometry is here rather than in
    -- the painter because a chip has to be placed before it can be clicked.
    local dash = read and self.tab == "Dashboard"
    local dashChipH = math.max(20, fontH.small + 6)
    local order = EC.CURRENCY_ORDER
    g.dashLeftW = math.max(220, math.floor((w - PAD) * 0.34))
    g.dashChipY = g.bodyY + CARD_TITLE_H + 2
    -- the note chip sits at the right end of the chip row and is budgeted first, so a long
    -- currency name shrinks its own chip instead of pushing the disclosure off the card
    local noteW = math.min(textWidth(self.dashNoteButton.fullTitle) + 20,
        math.floor(g.dashLeftW * 0.4))
    self.dashNoteButton:setVisible(dash)
    self.dashNoteButton:setWidth(noteW); self.dashNoteButton:setHeight(dashChipH)
    self.dashNoteButton:setX(math.max(PAD, g.dashLeftW - PAD - noteW))
    self.dashNoteButton:setY(g.dashChipY)
    self.dashNoteButton.active = D.isOpen(self, "dash:issued")
    U.setButtonTitle(self.dashNoteButton, self.dashNoteButton.fullTitle)
    local chipRoom = math.max(40, self.dashNoteButton.x - PAD * 2
        - 6 * math.max(0, #self.dashIssueButtons - 1))
    local chipCap = math.max(40, math.floor(chipRoom / math.max(1, #self.dashIssueButtons)))
    local dashChipX = PAD
    for _, b in ipairs(self.dashIssueButtons) do
        b:setVisible(dash)
        b:setWidth(math.min(textWidth(b.fullTitle) + 20, chipCap))
        b:setHeight(dashChipH); b:setX(dashChipX); b:setY(g.dashChipY)
        U.setButtonTitle(b, b.fullTitle)
        dashChipX = dashChipX + b.width + 6
    end
    g.dashIssueY = g.dashChipY + dashChipH + 4
    g.dashColX = g.dashLeftW + PAD
    g.dashColW = math.max(180, math.floor((w - g.dashColX - PAD * math.max(0, #order - 1)) / math.max(1, #order)))
    g.dashHolderY = g.bodyY + g.bodyH - PAD - dashChipH
    for i, b in ipairs(self.dashHolderButtons) do
        b:setVisible(dash)
        b:setWidth(math.min(textWidth(b.fullTitle) + 20, math.max(40, g.dashColW - PAD * 2)))
        b:setHeight(dashChipH)
        b:setX(g.dashColX + (i - 1) * (g.dashColW + PAD) + PAD)
        b:setY(g.dashHolderY)
        U.setButtonTitle(b, b.fullTitle)
    end
    -- what the text of both cards may use: the entries own the strip along the bottom
    g.dashBottom = g.dashHolderY - 4

    -- The two bound rows are the only ones whose label is a sentence rather than a word, and at a
    -- scaled-up UI font the column cannot hold a nine-digit figure beside one: the label slot is
    -- `lw - valueW - PAD`, which falls to roughly a third of the label at the largest scale. The
    -- full meaning is not negotiable here ("the cap on what one account may hold available" is
    -- not "cap"), so the label keeps its words and gives up the shared line instead -- it wraps
    -- across the whole column and the figure takes a line of its own underneath.
    --
    -- Decided here, once per layout, and never per frame: wrapping measures text, and the
    -- painter runs every frame. The widest figure of any currency decides for all of them, so
    -- the columns agree with each other instead of one wrapping and its neighbour not.
    local capInner = math.max(40, g.dashColW - PAD * 2)
    local capValueW = 0
    for _, id in ipairs(order) do
        local s = type(self.supply) == "table" and self.supply[id] or nil
        local def = currencyDef(id)
        capValueW = math.max(capValueW, textWidth(numText(def and def.balanceMax)),
            textWidth(tr("Admin_Dash_ServerCapNone")))
        if s ~= nil then capValueW = math.max(capValueW, textWidth(numText(s.total))) end
    end
    capValueW = math.min(capValueW, math.floor(capInner * 0.6))
    g.dashCapPlan = {}
    for _, key in ipairs({ "Admin_Dash_AccountCap", "Admin_Dash_ServerCap" }) do
        local label = tr(key)
        local plan = { label = label }
        plan.inline = textWidth(label) <= capInner - capValueW - PAD
        if not plan.inline then
            plan.lines = U.wrapText(label, capInner, 4)
            -- The figure rides on the label's LAST wrapped line whenever that line has room for
            -- it, which is the usual case: a wrapped label ends short. That saves the row a whole
            -- line, and a line is what this column runs out of at the largest font -- the
            -- alternative was a row that vanished entirely (ServerCapNone did) because the value
            -- needed a line the column no longer had.
            local tail = plan.lines[#plan.lines] or ""
            plan.tailFits = textWidth(tail) + capValueW + PAD <= capInner
        end
        g.dashCapPlan[key] = plan
    end

    -- currencies page
    g.cfgTableW = math.max(240, math.floor((w - PAD) * 0.58))
    g.cfgDetailX = g.cfgTableW + PAD
    g.cfgDetailW = math.max(200, w - g.cfgDetailX)
    g.cfgRowY = g.bodyY + CARD_TITLE_H + rh
    -- Eight actions now share the detail column, so they take two rows: four per row, fair share
    -- with redistribution inside each. One row of eight would leave every label as three dots at
    -- the minimum window width, and an action nobody can read is an action nobody finds.
    local cfgRow2Y = g.bodyY + g.bodyH - actionH
    local cfgBtnY = cfgRow2Y - actionH - 6
    g.cfgButtonY = cfgBtnY
    local toggleFull = math.max(textWidth(tr("Admin_Cur_Disable")), textWidth(tr("Admin_Cur_Enable"))) + 30
    local cfgItems = { { self.renameButton, textWidth(self.renameButton.fullTitle) + 30 },
        { self.toggleButton, toggleFull }, { self.rateButton, textWidth(self.rateButton.fullTitle) + 30 },
        { self.balanceMaxButton, textWidth(self.balanceMaxButton.fullTitle) + 30 } }
    fairShareButtons(cfgItems, currencies, g.cfgDetailX, cfgBtnY, g.cfgDetailW, actionH)
    local cfgItems2 = { { self.buybackAccountButton, textWidth(self.buybackAccountButton.fullTitle) + 30 },
        { self.buybackServerButton, textWidth(self.buybackServerButton.fullTitle) + 30 },
        { self.curHoldersButton, textWidth(self.curHoldersButton.fullTitle) + 30 },
        { self.iconsButton, textWidth(self.iconsButton.fullTitle) + 30 } }
    fairShareButtons(cfgItems2, currencies, g.cfgDetailX, cfgRow2Y, g.cfgDetailW, actionH)
    local currencyY = g.bodyY + CARD_TITLE_H + 12 + math.max(32, math.min(64, lineH() * 2))
    self.currencyReader:setVisible(currencies)
    self.currencyReader:setX(g.cfgDetailX + 2); self.currencyReader:setY(currencyY)
    self.currencyReader:setWidth(g.cfgDetailW - 4)
    self.currencyReader:setHeight(math.max(1, g.cfgButtonY - 8 - currencyY))

    -- sources page: table left, detail card plus two action buttons right (the currencies page
    -- shape, which a host already knows). Same fair share with redistribution for the buttons.
    local sourceDetailMin = textWidth(U.STAMP_SAMPLE) + PAD * 2
    g.srcTableW = math.max(240, math.min(math.floor((w - PAD) * 0.58), w - PAD - sourceDetailMin))
    g.srcDetailX = g.srcTableW + PAD
    g.srcDetailW = math.max(200, w - g.srcDetailX)
    g.srcRowY = g.bodyY + CARD_TITLE_H + rh
    g.srcButtonY = g.bodyY + g.bodyH - actionH
    local srcToggleFull = math.max(textWidth(tr("Admin_Src_Disable")), textWidth(tr("Admin_Src_Enable"))) + 30
    local srcItems = { { self.srcCapsButton, textWidth(self.srcCapsButton.fullTitle) + 30 },
        { self.srcToggleButton, srcToggleFull } }
    fairShareButtons(srcItems, sources, g.srcDetailX, g.srcButtonY, g.srcDetailW, actionH)
    local sourceY = g.bodyY + CARD_TITLE_H + 4
    self.sourceReader:setVisible(sources)
    self.sourceReader:setX(g.srcDetailX + 2); self.sourceReader:setY(sourceY)
    self.sourceReader:setWidth(g.srcDetailW - 4)
    self.sourceReader:setHeight(math.max(1, g.srcButtonY - 8 - sourceY))

    -- audit page: the search box, the exact actor box and the action chips on the first row,
    -- the actor candidates / dates / sort / page chips on the second, then the table
    self.auditEntry:setVisible(audit)
    self.auditEntry:setX(0); self.auditEntry:setY(g.bodyY + CARD_TITLE_H + 2)
    self.auditEntry:setWidth(math.min(240, math.floor(w * 0.28))); self.auditEntry:setHeight(eh)
    self.auditActorEntry:setVisible(audit)
    self.auditActorEntry:setX(self.auditEntry.width + PAD)
    self.auditActorEntry:setY(self.auditEntry.y)
    self.auditActorEntry:setWidth(math.max(120, math.min(180, math.floor(w * 0.18))))
    self.auditActorEntry:setHeight(eh)
    g.auditFilterY = self.auditEntry.y + eh + 4
    self:layoutAuditFilters()
    g.auditHeaderY = g.auditFilterY + self.auditF.rowH + 6
    local auditListY = g.auditHeaderY + rh
    local auditW = math.max(200, w - 2)
    -- a picked line is read in the detail window, so the table keeps the whole card
    local auditH = math.max(rh, g.bodyY + g.bodyH - auditListY - lh - 8)
    U.placeList(self.auditList, audit, 1, auditListY, auditW, auditH)
    layoutColumns(self.auditList, auditSpec(), auditW - 12)
    g.auditBottom = auditListY + auditH
    local copyH = math.max(20, fontH.small + 6)
    local copyMax = math.max(40, math.floor(w * 0.22))
    local copyId, copyName = self.auditCopyIdButton, self.auditCopyNameButton
    local copyY = g.bodyY + math.max(0, math.floor((CARD_TITLE_H - copyH) / 2))
    copyId:setVisible(audit)
    copyId:setWidth(math.min(textWidth(copyId.fullTitle) + 20, copyMax)); copyId:setHeight(copyH)
    copyId:setX(math.max(PAD, w - PAD - copyId.width)); copyId:setY(copyY)
    U.setButtonTitle(copyId, copyId.fullTitle)
    copyName:setVisible(audit)
    copyName:setWidth(math.min(textWidth(copyName.fullTitle) + 20, copyMax)); copyName:setHeight(copyH)
    copyName:setX(math.max(PAD, copyId.x - 6 - copyName.width)); copyName:setY(copyY)
    U.setButtonTitle(copyName, copyName.fullTitle)

    -- system page: state card left, paths card right. Each path is "label / value / copy": two
    -- lines when the card has the room, one line at the minimum window height with a large UI font
    -- (the rows must never run into the footer).
    g.sysLeftW = math.max(240, math.floor((w - PAD) * 0.5))
    g.sysRightX = g.sysLeftW + PAD
    g.sysRightW = math.max(220, w - g.sysRightX)
    local systemY = g.bodyY + CARD_TITLE_H + 4
    self.systemReader:setVisible(system)
    self.systemReader:setX(2); self.systemReader:setY(systemY)
    self.systemReader:setWidth(g.sysLeftW - 4)
    self.systemReader:setHeight(math.max(1, g.bodyY + g.bodyH - systemY - 4))
    local copyH = math.max(20, fontH.small + 6)
    local top = g.bodyY + CARD_TITLE_H + PAD
    local roomH = g.bodyY + g.bodyH - PAD - top
    g.sysStacked = #PATH_KEYS * (lh + copyH + 4) <= roomH
    g.sysLabelW = 0
    if not g.sysStacked then
        for _, key in ipairs(PATH_KEYS) do
            g.sysLabelW = math.max(g.sysLabelW, textWidth(tr("Admin_Sys_Path_" .. key)))
        end
        g.sysLabelW = math.min(g.sysLabelW, math.floor(g.sysRightW * 0.3))
    end
    local py = top
    for _, b in ipairs(self.copyButtons) do
        b:setVisible(system)
        b:setWidth(math.min(textWidth(b.fullTitle) + 20, math.max(30, g.sysRightW - PAD * 2)))
        b:setHeight(copyH)
        b:setX(g.sysRightX + g.sysRightW - PAD - b.width)
        b:setY(g.sysStacked and (py + lh) or py)
        py = py + copyH + 4 + (g.sysStacked and lh or 0)
    end
    g.sysPathY = top

    self.shopPage:setX(0)
    self.shopPage:setY(g.bodyY)
    self.shopPage:resize(w, g.bodyH)
    self.shopPage:setVisible(shop and self:getIsVisible())
    self.whitelistPage:setX(0)
    self.whitelistPage:setY(g.bodyY)
    self.whitelistPage:resize(w, g.bodyH)
    self.whitelistPage:setVisible(whitelist and self:getIsVisible())

    -- listings page: the listings card carries the search row, the list and the page chips along
    -- its bottom (the whitelist has its own page). In history mode the same card shows one
    -- player's market history instead: no paging, so that list takes the chips' room as well.
    local history = listings and self.lstMode == "history"
    local paged = listings and not history
    g.lstY = g.bodyY
    g.lstH = math.max(CARD_TITLE_H + eh + rh, g.bodyY + g.bodyH - g.lstY)
    local lstTop = g.lstY + CARD_TITLE_H + 4
    local pageH = math.max(20, fontH.small + 6)
    local histW = math.min(textWidth(self.lstHistoryButton.fullTitle) + 22, math.max(40, math.floor(w * 0.25)))
    self.lstHistoryButton:setVisible(listings)
    self.lstHistoryButton:setWidth(histW); self.lstHistoryButton:setHeight(pageH)
    self.lstHistoryButton:setX(math.max(PAD, w - PAD - histW))
    self.lstHistoryButton:setY(g.lstY + math.max(0, math.floor((CARD_TITLE_H - pageH) / 2)))
    U.setButtonTitle(self.lstHistoryButton, self.lstHistoryButton.fullTitle)
    self.lstEntry:setVisible(listings)
    self.lstEntry:setX(PAD); self.lstEntry:setY(lstTop)
    self.lstEntry:setWidth(math.max(120, math.min(240, math.floor(w * 0.28)))); self.lstEntry:setHeight(eh)
    -- the exact seller sits on the search row, right of the keyword box: two conditions side by
    -- side, so it is plain that neither one stands in for the other
    local sellerLabelW = textWidth(tr("Admin_Mkt_SellerExact")) + 6
    local sellerW = math.max(90, math.min(200, math.floor(w * 0.18)))
    local sellerClearW = math.min(textWidth(self.lstSellerClearButton.fullTitle) + 20,
        math.max(30, math.floor(w * 0.12)))
    local sellerX = PAD + self.lstEntry.width + PAD
    g.lstSellerLabelX = sellerX
    self.lstSellerPicker:setVisible(paged)
    self.lstSellerPicker:layout(sellerX + sellerLabelW, lstTop, sellerW,
        math.max(0, g.lstY + g.lstH - PAD - lstTop - eh))
    self.lstSellerClearButton:setVisible(paged)
    self.lstSellerClearButton:setWidth(sellerClearW); self.lstSellerClearButton:setHeight(pageH)
    self.lstSellerClearButton:setX(self.lstSellerPicker.entry.x + sellerW + 6)
    self.lstSellerClearButton:setY(lstTop + math.floor((eh - pageH) / 2))
    U.setButtonTitle(self.lstSellerClearButton, self.lstSellerClearButton.fullTitle)
    g.lstNoteX = paged and (self.lstSellerClearButton.x + sellerClearW + PAD) or sellerX
    g.lstHeadY = lstTop + math.floor((eh - fontH.small) / 2)
    local lstListY = lstTop + eh + 6
    g.lstPageY = math.max(lstListY + rh + 6, g.lstY + g.lstH - PAD - pageH)
    g.lstPageTextY = g.lstPageY + math.floor((pageH - fontH.small) / 2)
    local prevW = math.min(textWidth(self.lstPrevButton.fullTitle) + 24, math.floor(w * 0.2))
    local nextW = math.min(textWidth(self.lstNextButton.fullTitle) + 24, math.floor(w * 0.2))
    self.lstNextButton:setVisible(paged)
    self.lstNextButton:setWidth(nextW); self.lstNextButton:setHeight(pageH)
    self.lstNextButton:setX(math.max(PAD, w - PAD - nextW)); self.lstNextButton:setY(g.lstPageY)
    U.setButtonTitle(self.lstNextButton, self.lstNextButton.fullTitle)
    self.lstPrevButton:setVisible(paged)
    self.lstPrevButton:setWidth(prevW); self.lstPrevButton:setHeight(pageH)
    self.lstPrevButton:setX(math.max(PAD, self.lstNextButton.x - 6 - prevW)); self.lstPrevButton:setY(g.lstPageY)
    U.setButtonTitle(self.lstPrevButton, self.lstPrevButton.fullTitle)
    local lstW = math.max(160, w - PAD * 2)
    local lstListH = math.max(rh, g.lstPageY - 6 - lstListY)
    U.placeList(self.listingsList, paged, PAD, lstListY, lstW, lstListH)
    -- history mode: the type chips and the date / sort / page row take the two lines the page
    -- chips own in listings mode, and the list runs to the bottom of the card
    g.histKindY = lstListY
    g.histRowY = g.histKindY + pageH + 4
    self:layoutHistoryFilters()
    local histListY = g.histRowY + self.histF.rowH + 6
    local histH = math.max(rh, g.lstY + g.lstH - PAD - histListY)
    U.placeList(self.historyList, history, PAD, histListY, lstW, histH)

    -- auctions page: the listings card's shape plus two mode chips in the title row -- the live
    -- auctions (search row, list, page chips along the bottom) or the whole server's auction
    -- record (search row, the type / date / sort / page row, the record list to the bottom).
    local aucHistory = auctions and self.aucMode == "history"
    local aucPaged = auctions and not aucHistory
    g.aucY = g.bodyY
    g.aucH = math.max(CARD_TITLE_H + eh + rh, g.bodyY + g.bodyH - g.aucY)
    local aucTop = g.aucY + CARD_TITLE_H + 4
    local aucModeY = g.aucY + math.floor((CARD_TITLE_H - pageH) / 2)
    local aucHistW = math.min(textWidth(self.aucHistoryButton.fullTitle) + 22, math.max(40, math.floor(w * 0.25)))
    self.aucHistoryButton:setVisible(auctions)
    self.aucHistoryButton:setWidth(aucHistW); self.aucHistoryButton:setHeight(pageH)
    self.aucHistoryButton:setX(math.max(PAD, w - PAD - aucHistW)); self.aucHistoryButton:setY(aucModeY)
    U.setButtonTitle(self.aucHistoryButton, self.aucHistoryButton.fullTitle)
    local aucActiveW = math.min(textWidth(self.aucActiveButton.fullTitle) + 22, math.max(40, math.floor(w * 0.25)))
    self.aucActiveButton:setVisible(auctions)
    self.aucActiveButton:setWidth(aucActiveW); self.aucActiveButton:setHeight(pageH)
    self.aucActiveButton:setX(math.max(PAD, self.aucHistoryButton.x - 4 - aucActiveW))
    self.aucActiveButton:setY(aucModeY)
    U.setButtonTitle(self.aucActiveButton, self.aucActiveButton.fullTitle)
    self.aucEntry:setVisible(auctions)
    self.aucEntry:setX(PAD); self.aucEntry:setY(aucTop)
    self.aucEntry:setWidth(math.max(120, math.min(240, math.floor(w * 0.28)))); self.aucEntry:setHeight(eh)
    local aucSellerX = PAD + self.aucEntry.width + PAD
    g.aucSellerLabelX = aucSellerX
    self.aucSellerPicker:setVisible(aucPaged)
    self.aucSellerPicker:layout(aucSellerX + sellerLabelW, aucTop, sellerW,
        math.max(0, g.aucY + g.aucH - PAD - aucTop - eh))
    self.aucSellerClearButton:setVisible(aucPaged)
    self.aucSellerClearButton:setWidth(sellerClearW); self.aucSellerClearButton:setHeight(pageH)
    self.aucSellerClearButton:setX(self.aucSellerPicker.entry.x + sellerW + 6)
    self.aucSellerClearButton:setY(aucTop + math.floor((eh - pageH) / 2))
    U.setButtonTitle(self.aucSellerClearButton, self.aucSellerClearButton.fullTitle)
    g.aucNoteX = aucPaged and (self.aucSellerClearButton.x + sellerClearW + PAD) or aucSellerX
    g.aucHeadY = aucTop + math.floor((eh - fontH.small) / 2)
    local aucListY = aucTop + eh + 6
    g.aucPageY = math.max(aucListY + rh + 6, g.aucY + g.aucH - PAD - pageH)
    g.aucPageTextY = g.aucPageY + math.floor((pageH - fontH.small) / 2)
    local aucNextW = math.min(textWidth(self.aucNextButton.fullTitle) + 24, math.floor(w * 0.2))
    local aucPrevW = math.min(textWidth(self.aucPrevButton.fullTitle) + 24, math.floor(w * 0.2))
    self.aucNextButton:setVisible(aucPaged)
    self.aucNextButton:setWidth(aucNextW); self.aucNextButton:setHeight(pageH)
    self.aucNextButton:setX(math.max(PAD, w - PAD - aucNextW)); self.aucNextButton:setY(g.aucPageY)
    U.setButtonTitle(self.aucNextButton, self.aucNextButton.fullTitle)
    self.aucPrevButton:setVisible(aucPaged)
    self.aucPrevButton:setWidth(aucPrevW); self.aucPrevButton:setHeight(pageH)
    self.aucPrevButton:setX(math.max(PAD, self.aucNextButton.x - 6 - aucPrevW)); self.aucPrevButton:setY(g.aucPageY)
    U.setButtonTitle(self.aucPrevButton, self.aucPrevButton.fullTitle)
    local aucListH = math.max(rh, g.aucPageY - 6 - aucListY)
    U.placeList(self.auctionsList, aucPaged, PAD, aucListY, lstW, aucListH)
    -- history mode: the type chips and the date / sort / page row take the two lines the page
    -- chips own in the active list, and the record list runs to the bottom of the card
    g.aucKindY = aucListY
    g.aucRowY = g.aucKindY + pageH + 4
    self:layoutAuctionFilters()
    local aucHistListY = g.aucRowY + self.aucF.rowH + 6
    local aucHistH = math.max(rh, g.aucY + g.aucH - PAD - aucHistListY)
    U.placeList(self.aucHistoryList, aucHistory, PAD, aucHistListY, lstW, aucHistH)

    self.txPage:setX(0)
    self.txPage:setY(g.bodyY)
    self.txPage:setVisible(tx)
    self.txPage:resize(w, g.bodyH)

    -- settings page: search row on top, the group nav down the left, the option list plus the
    -- "reset this group" button on the right. The reset row is reserved whether the button is
    -- shown or not, so typing in the search box never re-flows the list.
    local setTop = g.bodyY + CARD_TITLE_H + 4
    self.setEntry:setVisible(settings)
    self.setEntry:setX(PAD); self.setEntry:setY(setTop)
    self.setEntry:setWidth(math.max(120, math.min(260, math.floor(w * 0.3)))); self.setEntry:setHeight(eh)
    g.setCountX = PAD + self.setEntry.width + PAD
    g.setNavY = setTop + eh + 6
    local navNeed = 200
    for _, group in ipairs(EC.OPTION_GROUPS) do
        local total, overrides = self:optionGroupCount(group)
        local tail = overrides > 0 and getText(T .. "Admin_Set_OverrideCount", tostring(overrides)) or getText(T .. "Admin_Set_Count", tostring(total))
        navNeed = math.max(navNeed, textWidth(tr("Admin_Set_Group_" .. group)) + textWidth(tail) + PAD * 3)
    end
    g.setNavW = math.max(120, math.min(navNeed, math.floor(w * 0.38)))
    g.setNavRowH = math.max(24, lh + 8)
    g.setNavH = math.max(g.setNavRowH, g.bodyY + g.bodyH - PAD - g.setNavY)
    self.settingsNav.rowHeight = g.setNavRowH
    U.placeList(self.settingsNav, settings, PAD, g.setNavY, g.setNavW, g.setNavH)
    g.setContentX = PAD + g.setNavW + PAD
    g.setContentW = math.max(160, w - g.setContentX - PAD)
    g.setHeadY = g.setNavY   -- the group heading; the standing note rides the search row instead
    local resetH = math.max(20, fontH.small + 6)
    g.setResetY = g.bodyY + g.bodyH - PAD - resetH
    local resetW = math.min(textWidth(self.setResetButton.fullTitle) + 24, g.setContentW)
    self.setResetButton:setVisible(settings and self.setQuery == nil)
    self.setResetButton:setWidth(resetW)
    self.setResetButton:setHeight(resetH)
    self.setResetButton:setX(g.setContentX + g.setContentW - resetW)
    self.setResetButton:setY(g.setResetY)
    U.setButtonTitle(self.setResetButton, self.setResetButton.fullTitle)
    local setListY = g.setHeadY + fontH.medium + 6
    local setW = math.max(120, g.setContentW)
    local setH = math.max(rowH(), g.setResetY - 6 - setListY)
    U.placeList(self.settingsList, settings, g.setContentX, setListY, setW, setH)

    self:rebuildAudit()
    self:rebuildSettings()
    self:rebuildListings()
    self:rebuildAuctions()
    self:rebuildAuctionHistory()
    self:rebuildHistory()
    -- the receipt rows carry the geometry of their own action strip, so a resize rebuilds them
    -- exactly like every other table here
    if self.lookup then self:rebuildReceipts() end
    -- The reconciliation page takes the body area of its own tab (not the tab strip row, so the
    -- window's own freshness line stays readable). Leaving the tab or losing the read right stops
    -- whatever it had queued; the page itself is only ever hidden, never torn down.
    if not recovery then self:leaveRecovery() end
    -- visibility first: the page hides its own chips and rows when it is not on screen, and its
    -- resize always re-runs that decision
    self.recoveryPage:setVisible(recovery and self:getIsVisible())
    self.recoveryPage:setX(0)
    self.recoveryPage:setY(g.bodyY)
    self.recoveryPage:resize(w, math.max(80, g.bodyH))
    -- the season desk, on the same terms: leaving the tab drops its focus and its record, and
    -- the page itself is only ever hidden
    if not (read and self.tab == "Seasons") then self:leaveSeasons() end
    self.seasonsPage:setVisible(read and self.tab == "Seasons" and self:getIsVisible())
    self.seasonsPage:setX(0)
    self.seasonsPage:setY(g.bodyY)
    self.seasonsPage:resize(w, math.max(80, g.bodyH))
    if self.dialog then self:layoutDialog() end
    self.layoutW, self.layoutH = w, h
    self:updateEnabled()
end

function Admin:resize(width, height)
    if self.width == width and self.height == height then return end
    self:setWidth(width)
    self:setHeight(height)
    self:layout()
end

-- ----- drawing -----

-- Vertical text cursor shared by the summary cards. State lives on the panel so the hot path
-- allocates nothing (the framework's per-frame-closure rule, V1.lua:138-139).
function Admin:beginLines(x, y, w, limit)
    self.lx, self.ly, self.lw, self.lLimit = x, y, w, limit
end

function Admin:line(str, token)
    local lh = lineH()
    if self.ly + lh > self.lLimit then return false end
    text(self, fitText(str, self.lw), self.lx, self.ly, token or "text")
    self.ly = self.ly + lh
    return true
end

-- label left, value right-aligned on the same line
function Admin:lineRow(label, value, token)
    local lh = lineH()
    if self.ly + lh > self.lLimit then return false end
    local valueText = tostring(value)
    local valueW = math.min(textWidth(valueText), math.floor(self.lw * 0.6))
    text(self, fitText(label, self.lw - valueW - PAD), self.lx, self.ly, "textMuted")
    textRight(self, fitText(valueText, valueW), self.lx + self.lw, self.ly, token or "text")
    self.ly = self.ly + lh
    return true
end

function Admin:lineGap(n)
    self.ly = self.ly + (n or 3)
end

-- One of the two bound rows of a supply column, drawn to the plan cached for this geometry
-- (Admin:layout, g.dashCapPlan). Three forms, in order of preference: the label still fits
-- beside its figure (an ordinary lineRow); the label wraps and the figure rides on its last
-- wrapped line, which is the usual case because a wrapped label ends short; or, only when even
-- that last line is full, the figure takes a line of its own. Every line goes through
-- Admin:line / Admin:lineRow, so the shared limit (lLimit, just above the holder entry) stops
-- the text before it can reach that button.
function Admin:capRow(key, value, token)
    local plan = self.g.dashCapPlan and self.g.dashCapPlan[key]
    if plan == nil then return self:lineRow(tr(key), value, token) end
    if plan.inline then return self:lineRow(plan.label, value, token) end
    local lines = plan.lines
    local n = #lines
    if plan.tailFits then
        -- every line but the last, then the last carrying the figure on its right
        for i = 1, n - 1 do
            if not self:line(lines[i], "textMuted") then return false end
        end
        return self:lineRow(lines[n], value, token)
    end
    for i = 1, n do
        if not self:line(lines[i], "textMuted") then return false end
    end
    -- the figure alone, right-aligned under its own label
    return self:lineRow("", value, token)
end

function Admin:onFreezeAudit()
    if self:isModal() or not self.lookup or not self.lookup.frozen then return end
    self.auditActor = nil
    setEntryText(self.auditActorEntry, "")
    self:showAuditFor(self.lookupUser, "freeze")
end

function Admin:refreshPlayerStatus()
    local lookup, waiting = self.lookup, isPending("admin.lookup")
    if self.statusLookup == lookup and self.statusLookupAt == self.lookupAt and self.statusWaiting == waiting
        and self.statusCurrencies == C.currencies and self.statusOffset == self.offsetMin
        and self.statusWidth == self.statusReader.width and self.statusHeight == self.statusReader.height then return end
    self.statusLookup, self.statusLookupAt, self.statusWaiting = lookup, self.lookupAt, waiting
    self.statusCurrencies, self.statusOffset, self.statusWidth = C.currencies, self.offsetMin, self.statusReader.width
    self.statusHeight = self.statusReader.height
    local lines = {}
    if not lookup then
        lines[1] = waiting and tr("Admin_Loading") or tr("Admin_Player_Hint")
    else
        local held, listed, running = tonumber(lookup.recoveryHeld), tonumber(lookup.listingsCount), tonumber(lookup.auctionsCount)
        if held and held > 0 then
            lines[#lines + 1] = getText(T .. "Admin_Player_Recovery", tostring(math.floor(held)))
        end
        if listed then
            lines[#lines + 1] = getText(T .. "Admin_Player_Listings", tostring(math.floor(listed)), countLimitText(lookup.maxListings))
        end
        if running then
            lines[#lines + 1] = getText(T .. "Admin_Player_Auctions", tostring(math.floor(running)), countLimitText(lookup.maxAuctions))
        end
        local rewards = lookup.rewards or {}
        lines[#lines + 1] = lookup.hoursSurvived ~= nil
            and getText(T .. "Admin_Player_Survived", string.format("%.1f", (tonumber(lookup.hoursSurvived) or 0) / 24))
            or tr("Admin_Player_SurvivedOffline")
        -- Check-in is a count now, not a flag: a day can allow several claims, so the card says
        -- how many were taken of how many and how many are left. `claimed` and `minPlaytimeMs`
        -- are gone from the reply -- reading them would have shown "not claimed" forever.
        lines[#lines + 1] = getText(T .. "Admin_Player_Claims", numText(rewards.claimedCount),
            numText(rewards.dailyLimit), numText(rewards.remainingClaims))
        -- Today's total time online against the next cumulative threshold. The server deliberately does
        -- not say whether a claim is possible right now (that is the rewards backend's verdict),
        -- so this card states the two figures and never a verdict of its own.
        lines[#lines + 1] = getText(T .. "Admin_Player_OnlineToday", minutesText(rewards.playedMs),
            minutesText(rewards.requiredOnlineMs))
        -- The cumulative step only matters when a day allows more than one claim.
        local limit = tonumber(rewards.dailyLimit)
        if rewards.intervalMs ~= nil and limit ~= nil and limit > 1 then
            lines[#lines + 1] = getText(T .. "Admin_Player_ClaimInterval", minutesText(rewards.intervalMs))
        end
        -- The one reason the server states for withholding a reward (currently "day_reverted":
        -- the reward day was moved back and that day has slid out of the durable payment window,
        -- so the server fail-closes). Absent means "not applicable", never "everything is fine".
        if type(rewards.blockedReason) == "string" and rewards.blockedReason ~= "" then
            -- the wording is the rewards slice's own (Rewards_Error_<code>), so the admin reads
            -- the very sentence the player is shown instead of a second explanation of it
            local code = rewards.blockedReason
            lines[#lines + 1] = getText(T .. "Admin_Player_Blocked",
                getTextOrNull(T .. "Rewards_Error_" .. code) or code)
        end
        if rewards.nextResetMs then lines[#lines + 1] = getText(T .. "Admin_Player_NextReset", stampText(rewards.nextResetMs, self.offsetMin)) end
        local done, total = 0, 0
        for _, milestone in ipairs(rewards.milestoneList or {}) do
            total = total + 1
            if hasBit(rewards.milestones, milestone.index) then done = done + 1 end
        end
        -- The milestone line names the season by its DISPLAY number: the id is an internal,
        -- never-reused token and means nothing to a host reading a card. The two lines under it
        -- are the season's own survival figures -- what this character has survived in the
        -- season that is running, and the best single life the account recorded in it. The
        -- `Admin_Player_Survived` line further up stays the character's total across every
        -- season: the two must never be read as the same number.
        local seasonNo = tonumber(rewards.seasonNumber)
        lines[#lines + 1] = getText(T .. "Admin_Player_Milestones", tostring(done), tostring(total),
            seasonNo ~= nil and getText(T .. "Season_Number", tostring(math.floor(seasonNo))) or "-")
        -- A read the server could not complete is its own answer: it is neither "nothing
        -- recorded yet" nor a reason to keep the last figure that was confirmed on screen. The
        -- code is printed exactly as the server stated it -- the same wording the player's own
        -- card uses (ECPanel rewards lines), so the two never describe one failure differently.
        local survivalError = rewards.survivalError
        if survivalError ~= nil then
            lines[#lines + 1] = getText(T .. "Season_SurvivalFailed", tostring(survivalError))
        else
            local seasonKnown = rewards.survivalKnown == true
            lines[#lines + 1] = getText(T .. "Rewards_SeasonSurvived",
                survivalFigure(seasonKnown, rewards.survivalHours))
            lines[#lines + 1] = getText(T .. "Rewards_SeasonBest",
                survivalFigure(seasonKnown, rewards.bestSurvivalHours))
            -- the server could only account for part of the season (a restart it cannot
            -- bridge): said plainly, so a figure that is a floor is never read as the whole
            -- truth
            if rewards.survivalIncomplete == true then lines[#lines + 1] = tr("Season_Incomplete") end
        end
        if lookup.frozen then
            local info = lookup.frozenInfo or {}
            lines[#lines + 1] = getText(T .. "Admin_Player_FrozenBy", tostring(info.by or "-"), stampText(info.ts, self.offsetMin))
            if info.reason then lines[#lines + 1] = getText(T .. "Admin_Player_FrozenReason", tostring(info.reason)) end
        end
        lines[#lines + 1] = ""
        lines[#lines + 1] = tr("Admin_Player_MyDaily")
        local today = lookup.adminToday or {}
        if type(today.currencies) == "table" then
            for _, id in ipairs(currencyOrder(lookup)) do
                local amount = today.currencies[id] or {}
                lines[#lines + 1] = getText(T .. "Admin_Player_DailyRow", currencyName(id), amountText(amount.add or 0), amountText(amount.sub or 0))
            end
        else lines[#lines + 1] = getText(T .. "Admin_Player_DailyAll", amountText(today.add or 0), amountText(today.sub or 0)) end
        lines[#lines + 1] = getText(T .. "Admin_Player_DailyCap", amountText(today.cap or 0))
        local server = today.serverDaily or today.server or lookup.serverDaily
        if type(server) == "table" and server.cap ~= nil then
            lines[#lines + 1] = getText(T .. "Admin_Player_ServerDaily", amountText(server.add or 0), amountText(server.sub or 0), amountText(server.cap))
        end
        lines[#lines + 1] = getText(T .. "Admin_Player_MaxPerTx", amountText(lookup.maxPerTx or 0))
    end
    local scroll = self.statusUser == self.lookupUser and self.statusReader:getYScroll() or 0
    U.setWrappedText(self.statusReader, table.concat(lines, "\n"), self.statusReader.width)
    self.statusReader:setYScroll(scroll)
    local balances = {}
    for _, id in ipairs(currencyOrder(lookup)) do
        local balance = lookup and lookup.balances and lookup.balances[id] or {}
        local fields = {
            { tr("Wallet_Available"), amountText(balance.available or 0), "accent" },
            { tr("Wallet_Reserved"), amountText(balance.reserved or 0), "text" },
            { "", getText(T .. "Admin_Player_Rev", tostring(balance.rev or 0)), "textFaint" },
        }
        local detail = currencyName(id)
        for _, field in ipairs(fields) do detail = detail .. "\n" .. field[1] .. " " .. field[2] end
        local key = tostring(self.lookupUser) .. "\1" .. id
        balances[#balances + 1] = { id = key, currency = id, name = currencyName(id), fields = fields, detailText = detail }
        self:showDetail("balance", key, currencyName(id), detail, true)
    end
    self.summaryList:setItems(balances)
    self.statusUser = self.lookupUser
end

function Admin:drawPlayer()
    local g = self.g
    local rh = rowH()
    local ty = g.queryY + math.floor((entryH() - fontH.small) / 2)
    if self.lookupError then
        text(self, fitText(errorText(self.lookupError), self.width - g.statusX), g.statusX, ty, "errorText")
    elseif self.lookup then
        local status = self.lookup.found and (self.lookup.online and tr("Admin_Player_Online") or tr("Admin_Player_Offline"))
            or tr("Admin_Player_NotFound")
        local label = tostring(self.lookupUser) .. "  " .. status
        if self.lookup.frozen then label = label .. "  " .. tr("Admin_Player_Frozen") end
        local stamp = getText(T .. "Admin_Updated", stampText(self.lookupAt or 0, self.offsetMin))
        local stampW = textWidth(stamp)
        text(self, fitText(label, self.width - g.statusX - stampW - PAD), g.statusX, ty, self.lookup.frozen and "warn" or "text")
        textRight(self, stamp, self.width, ty, "textFaint")
    elseif isPending("admin.lookup") then
        text(self, tr("Admin_Loading"), g.statusX, ty, "textMuted")
    end

    local lookup = self.lookup

    -- account summary: available / reserved / wallet revision per currency
    card(self, 0, g.cardsY, g.leftW, g.cardsH, tr("Admin_Player_Summary"))

    -- status, rewards and the daily adjustment budget
    card(self, g.midX, g.cardsY, g.midW, g.cardsH, tr("Admin_Player_Status"))
    self:refreshPlayerStatus()

    -- receipt ring (explicitly labelled as a ring, never presented as a full history)
    card(self, g.rightX, g.cardsY, g.rightW, g.cardsH, tr("Admin_Player_Receipts"))
    text(self, fitText(tr("Admin_Player_RingNote"), g.rightW - PAD * 2), g.rightX + PAD, g.cardsY + CARD_TITLE_H + 1, "textFaint")
    -- the table owns the card now; its headers (and its empty line) go with it
    if self.receiptList:getIsVisible() then
        drawColumnHeaders(self, self.receiptList, RECEIPT_COLS, self.receiptList.x, g.receiptHeaderY, rh)
        if #(self.receiptRows or {}) == 0 then
            text(self, lookup and tr("Wallet_Empty") or tr("Admin_Player_Hint"), self.receiptList.x + PAD,
                g.receiptHeaderY + rh + 4, "textFaint")
        end
    end

    -- note next to the action buttons
    local noteY = g.actionY + math.floor((btnH() - fontH.small) / 2)
    local noteW = self.width - g.actionNoteX
    if self.selectedReceipt and self.selectedReceipt.txId then
        text(self, fitText(getText(T .. "Admin_Player_SelectedTx", tostring(self.selectedReceipt.txId)), noteW), g.actionNoteX, noteY, "textFaint")
    elseif self:isSelfTarget() then
        -- two different facts, and the difference matters to the admin reading it: whether
        -- they may pay their own account at all, and that nobody may freeze their own
        text(self, fitText(self:selfAdjustAllowed() and tr("Admin_Player_SelfFreezeNote")
            or tr("Admin_Player_SelfNote"), noteW), g.actionNoteX, noteY, "warn")
    elseif not self.hadWrite then
        text(self, fitText(tr("Admin_ReadOnly"), noteW), g.actionNoteX, noteY, "textFaint")
    end
end

-- The issued card, for the currency its chips have selected. Five sources over three windows is
-- a table of its own, and two currencies of it side by side in a third of the window would be
-- unreadable -- so the card shows one currency and the chips say which. Every figure is the sum
-- of the days the server could attribute to this currency; `unknownDays` counts the days it
-- could not (rollup buckets written before the counters were kept per currency), and while that
-- is above zero the block says so instead of presenting the sum as the whole truth. The known
-- part is still printed: throwing it away would answer "how much was issued" with nothing.
function Admin:drawIssued(sys, lh)
    local g = self.g
    local id = self.dashCurrency
    local leftW = g.dashLeftW
    card(self, 0, g.bodyY, leftW, g.bodyH, fitText(tr("Admin_Dash_Issued"), leftW - PAD * 2, UIFont.Medium))
    local y = g.dashIssueY
    if not sys then
        text(self, isPending("admin.system") and tr("Admin_Loading") or tr("Admin_Dash_Empty"),
            PAD, y, "textMuted")
        return
    end
    local issued = type(sys.issued) == "table" and sys.issued or {}
    local colW = math.floor((leftW - PAD * 2) / 3)
    local unknown = 0
    for _, period in ipairs(ISSUE_PERIODS) do
        local _, days = issueRow(issued, period, id)
        if days > unknown then unknown = days end
    end
    textRight(self, fitText(tr("Admin_Dash_Checkin"), colW - 6), PAD + colW * 2, y, "textMuted")
    textRight(self, fitText(tr("Admin_Dash_Milestone"), colW - 6), PAD + colW * 3, y, "textMuted")
    y = y + lh + 2
    for _, period in ipairs(ISSUE_PERIODS) do
        local row = issueRow(issued, period, id) or EMPTY_ROW
        text(self, fitText(issuePeriodLabel(period), colW - 6), PAD, y, "text")
        local body, token = issueText(row.checkin, "+", "positive")
        textRight(self, fitText(body, colW - 6), PAD + colW * 2, y, token)
        body, token = issueText(row.milestone, "+", "positive")
        textRight(self, fitText(body, colW - 6), PAD + colW * 3, y, token)
        y = y + lh
    end
    -- Reserve a separate period column; complete labels and values remain in the note reader.
    colW = math.floor((leftW - PAD * 2) / 4)
    y = y + 4
    textRight(self, fitText(tr("Admin_Dash_Mint"), colW - 6), PAD + colW * 2, y, "textMuted")
    textRight(self, fitText(tr("Admin_Dash_Buyback"), colW - 6), PAD + colW * 3, y, "textMuted")
    textRight(self, fitText(tr("Admin_Dash_Burn"), colW - 6), PAD + colW * 4, y, "textMuted")
    y = y + lh + 2
    for _, period in ipairs(ISSUE_PERIODS) do
        local row = issueRow(issued, period, id) or EMPTY_ROW
        text(self, fitText(issuePeriodLabel(period), colW - 6), PAD, y, "text")
        local body, token = issueText(row.mint, "+", "positive")
        textRight(self, fitText(body, colW - 6), PAD + colW * 2, y, token)
        local buyback = tonumber(row.buyback)
        body, token = issueText(row.buyback, "+", (buyback or 0) > 0 and "positive" or "textFaint")
        textRight(self, fitText(body, colW - 6), PAD + colW * 3, y, token)
        body, token = issueText(row.burn, "-", "negative")
        textRight(self, fitText(body, colW - 6), PAD + colW * 4, y, token)
        y = y + lh
    end
    -- Only what fits a narrow column goes on the card: which currency these figures are about,
    -- and -- when some days could not be attributed -- that they are a floor. What the figures
    -- do and do not count is a paragraph, and Admin:line would cut it, so it lives behind the
    -- note chip in the detail window where it wraps and can be copied whole.
    self:beginLines(PAD, y + 4, leftW - PAD * 2, g.dashBottom)
    self:line(getText(T .. "Admin_Dash_IssuedFor", currencyName(id)), "textFaint")
    if unknown > 0 then
        self:line(getText(T .. "Admin_Dash_IssuedPartialShort", tostring(unknown)), "warn")
    end
end

function Admin:drawDashboard()
    local g = self.g
    local lh = lineH()
    local sys = self.system
    self:drawIssued(sys, lh)

    -- One supply column per currency: what the players hold, what the auctions are holding back,
    -- the system side, the conservation check, the two bounds and who the largest holders are.
    -- There is no server-wide circulation cap at all -- no total is ever minted against one --
    -- so that line says "does not exist" rather than leaving a number-shaped blank a host would
    -- read as zero.
    local order = EC.CURRENCY_ORDER
    local supply = self.supply
    local x = g.dashColX
    local colW = g.dashColW
    for _, id in ipairs(order) do
        card(self, x, g.bodyY, colW, g.bodyH, fitText(currencyName(id), colW - PAD * 2, UIFont.Medium))
        local s = type(supply) == "table" and supply[id] or nil
        self:beginLines(x + PAD, g.bodyY + CARD_TITLE_H + 4, colW - PAD * 2, g.dashBottom)
        if not s then
            self:line(supply and tr("Admin_Dash_Empty") or tr("Admin_Loading"), "textMuted")
        else
            -- Total is the players' side whole: available plus what the two markets reserved.
            -- The system accounts are counted apart, because a host asking "how much money is
            -- out there" means the players' money.
            --
            -- Once the server reports `complete = false`, every one of these figures excludes
            -- the wallet rows it could not read, so none of them is a total any more -- each is
            -- marked as a floor. And the conservation difference stops being a figure at all:
            -- a 0 would claim the books add up when some of them could not be opened, so the
            -- line says it cannot be reconciled instead of printing a number that looks like a
            -- verdict.
            --
            -- Drawn in priority order, because at the largest UI font this column holds about ten
            -- lines and the wrapped bound labels want six of them. What a host cannot do without
            -- comes first and contiguously (no gap lines to spend): the players' total, the two
            -- buckets it splits into, the conservation check, both bounds, and the holder count.
            -- Everything after the gap is a cross-reference that exists elsewhere -- the system
            -- accounts and the largest holders are both on the currency page's reader, and the
            -- full holder list is one button away -- so those are the lines the limit may eat.
            local proven = s.complete ~= false
            self:lineRow(tr("Admin_Dash_Total"), boundText(s.total, proven), "accent")
            self:lineRow(tr("Admin_Dash_Players"), boundText(s.players, proven))
            self:lineRow(tr("Admin_Dash_Reserved"), boundText(s.reserved, proven))
            if proven then
                self:lineRow(tr("Admin_Dash_Conserve"), numText(s.net),
                    (tonumber(s.net) or 0) ~= 0 and "warn" or "textMuted")
            else
                self:lineRow(tr("Admin_Dash_Conserve"), tr("Admin_Dash_ConserveUnverifiable"), "warn")
                self:line(getText(T .. "Admin_Dash_ConserveUnproven", numText(s.unreadable)), "warn")
            end
            -- the two bounds a host can act on: one per account, and none at all server-wide
            local def = currencyDef(id)
            self:capRow("Admin_Dash_AccountCap", numText(def and def.balanceMax))
            self:capRow("Admin_Dash_ServerCap", tr("Admin_Dash_ServerCapNone"), "textFaint")
            -- how many accounts hold any of this currency at all
            self:lineRow(tr("Admin_Dash_Holders"), boundText(s.holders, proven))

            self:lineGap()
            -- From here down the limit is allowed to cut: wallet accounts (the zero-balance
            -- contrast to the holder count), the system side, the unreadable tally and the
            -- largest holders. All of them are also on the currency page's reader, which wraps.
            self:lineRow(tr("Admin_Dash_WalletAccounts"), boundText(s.accounts, proven), "textFaint")
            self:lineRow(tr("Admin_Dash_System"), boundText(s.system, proven), "textMuted")
            if s.systemReserved ~= nil then
                self:lineRow(tr("Admin_Dash_SystemReserved"), boundText(s.systemReserved, proven), "textMuted")
            end
            local unreadable = tonumber(s.unreadable)
            if unreadable ~= nil and unreadable > 0 then
                self:lineRow(tr("Admin_Dash_Unreadable"), numText(s.unreadable), "warn")
            end
            local top = s.top or {}
            self:line(getText(T .. "Admin_Dash_Top", tostring(#top)), "textMuted")
            if #top == 0 then
                self:line(tr("Admin_Dash_Empty"), "textFaint")
            end
            for _, holder in ipairs(top) do
                if not self:lineRow(tostring(holder.account or "-"), numText(holder.amount)) then break end
            end
        end
        x = x + colW + PAD
    end
end

function Admin:drawCurrencies()
    local g = self.g
    local rh = rowH()
    card(self, 0, g.bodyY, g.cfgTableW, g.bodyH, tr("Admin_Cur_Title"))
    local headerY = g.bodyY + CARD_TITLE_H
    fill(self, 1, headerY, g.cfgTableW - 2, rh, "well", "rect")
    local hy = headerY + math.floor((rh - fontH.small) / 2)
    local c1, c2, c3, c4 = PAD, math.floor(g.cfgTableW * 0.24), math.floor(g.cfgTableW * 0.46), math.floor(g.cfgTableW * 0.76)
    text(self, tr("Admin_Cur_Col_Id"), c1, hy, "textMuted")
    text(self, tr("Admin_Cur_Col_Use"), c2, hy, "textMuted")
    text(self, tr("Admin_Cur_Col_Name"), c3, hy, "textMuted")
    text(self, tr("Admin_Cur_Col_State"), c4, hy, "textMuted")
    local y = g.cfgRowY
    local rects = self.cfgRowRects
    for i = #rects, 1, -1 do rects[i] = nil end
    local coin = math.max(16, math.min(rh - 6, 24))
    for i, id in ipairs(EC.CURRENCY_ORDER) do
        if y + rh > g.bodyY + g.bodyH - 2 then break end
        local def = currencyDef(id)
        local selected = id == self:selectedCurrency()
        if selected then
            fill(self, 1, y, g.cfgTableW - 2, rh, "selected", "rect")
        elseif i % 2 == 0 then
            fill(self, 1, y, g.cfgTableW - 2, rh, "card", "rect")
        end
        local ty = y + math.floor((rh - fontH.small) / 2)
        -- the icon that is in force for this currency, at row size: U.drawCoin is the one reader
        -- (EC.IconCache, then the shipped texture, then the dot), so the list costs no load of
        -- its own and an unknown or still-loading icon simply keeps the fallback
        drawCoin(self, id, c1, y + math.floor((rh - coin) / 2), coin)
        local idX = c1 + coin + 6
        text(self, fitText(id, math.max(20, c2 - idX - PAD)), idX, ty, selected and "accent" or "text")
        -- What this currency may be used for: every property that is true, not one of two roles.
        -- "Tradable on the market" and "bought back by the shop" are independent, and a unit can
        -- be both -- calling one of them "external" would state the opposite of the other.
        text(self, fitText(currencyUses(id, def), math.max(20, c3 - c2 - PAD)), c2, ty, "textMuted")
        text(self, fitText(currencyName(id), c4 - c3 - PAD), c3, ty, "text")
        local enabled = def == nil or def.enabled ~= false
        text(self, enabled and tr("Admin_On") or tr("Admin_Off"), c4, ty, enabled and "positive" or "textFaint")
        rects[#rects + 1] = { id = id, y = y, h = rh }
        y = y + rh
    end
    if not currencyDefs() then
        text(self, tr("Admin_Loading"), PAD, y + 4, "textFaint")
    end

    -- detail card for the selected currency (exchange block only where the server has one)
    local id = self:selectedCurrency()
    local def = currencyDef(id)
    local detailH = math.max(60, g.cfgButtonY - 6 - g.bodyY)
    card(self, g.cfgDetailX, g.bodyY, g.cfgDetailW, detailH, getText(T .. "Admin_Cur_Detail", currencyName(id)))
    -- The preview keeps its own space; the complete settings below it are scrollable.
    local big = math.max(32, math.min(64, lineH() * 2))
    local iconY = g.bodyY + CARD_TITLE_H + 4
    drawCoin(self, id, g.cfgDetailX + PAD, iconY, big)
    self:refreshCurrencyReader(id, def)
end

function Admin:drawSources()
    local g = self.g
    local rh = rowH()
    card(self, 0, g.bodyY, g.srcTableW, g.bodyH, tr("Admin_Src_Title"))
    local headerY = g.bodyY + CARD_TITLE_H
    fill(self, 1, headerY, g.srcTableW - 2, rh, "well", "rect")
    local hy = headerY + math.floor((rh - fontH.small) / 2)
    -- the mod id column takes the widest share: ids are long and identify the row
    local c1, c2, c3 = PAD, math.floor(g.srcTableW * 0.36), math.floor(g.srcTableW * 0.48)
    local c4, c5 = math.floor(g.srcTableW * 0.60), math.floor(g.srcTableW * 0.80)
    text(self, tr("Admin_Src_Col_Mod"), c1, hy, "textMuted")
    text(self, tr("Admin_Src_Col_Loaded"), c2, hy, "textMuted")
    text(self, tr("Admin_Src_Col_Enabled"), c3, hy, "textMuted")
    text(self, tr("Admin_Src_Col_Mint"), c4, hy, "textMuted")
    text(self, tr("Admin_Src_Col_Burn"), c5, hy, "textMuted")

    local list = self.sources or {}
    local selected = self:selectedSource()
    local y = g.srcRowY
    local rects = self.srcRowRects
    for i = #rects, 1, -1 do rects[i] = nil end
    for i, s in ipairs(list) do
        if y + rh > g.bodyY + g.bodyH - 2 then break end
        local isSelected = selected ~= nil and selected.modId == s.modId
        if isSelected then
            fill(self, 1, y, g.srcTableW - 2, rh, "selected", "rect")
        elseif i % 2 == 0 then
            fill(self, 1, y, g.srcTableW - 2, rh, "card", "rect")
        end
        local ty = y + math.floor((rh - fontH.small) / 2)
        local today = s.today or {}
        local enabled = s.enabled ~= false
        text(self, fitText(tostring(s.modId), c2 - c1 - PAD), c1, ty, isSelected and "accent" or "text")
        text(self, fitText(s.loaded and tr("Admin_Src_Loaded") or tr("Admin_Src_NotLoaded"), c3 - c2 - PAD), c2, ty,
            s.loaded and "textMuted" or "textFaint")
        text(self, fitText(enabled and tr("Admin_On") or tr("Admin_Off"), c4 - c3 - PAD), c3, ty, enabled and "positive" or "textFaint")
        text(self, fitText(amountText(today.mint or 0) .. " / " .. amountText(s.dailyMintCap or 0), c5 - c4 - PAD), c4, ty, "text")
        text(self, fitText(amountText(today.burn or 0) .. " / " .. capText(s.dailyBurnCap), g.srcTableW - c5 - PAD), c5, ty, "text")
        rects[#rects + 1] = { id = s.modId, y = y, h = rh }
        y = y + rh
    end
    if #list == 0 then
        text(self, isPending("admin.sources") and tr("Admin_Loading") or tr("Admin_Src_Empty"), PAD, y + 4, "textFaint")
    end

    -- detail card for the selected source (the MOD account balance is that mod's net take)
    local detailH = math.max(60, g.srcButtonY - 6 - g.bodyY)
    card(self, g.srcDetailX, g.bodyY, g.srcDetailW, detailH,
        getText(T .. "Admin_Src_Detail", selected and tostring(selected.modId) or "-"))
    self:refreshSourceReader(selected)
end

-- The listings card in history mode: the same header row, one player's own market history under
-- it (newest first) and no paging.
function Admin:drawListingHistory()
    local g = self.g
    filterDraw(self.histF, self)
    local rows = self.historyRows or {}
    local snap = self.marketHistory
    local countText = ""
    if snap then
        countText = getText(T .. "Admin_Lst_Count", tostring(math.floor(tonumber(snap.total) or #rows)))
        textRight(self, countText, self.width - PAD, g.lstHeadY, "textFaint")
    end
    text(self, fitText(tr("Admin_Lst_HistoryHint"),
        math.max(0, self.width - PAD * 2 - g.lstNoteX - textWidth(countText))), g.lstNoteX, g.lstHeadY, "textFaint")
    if #rows > 0 then return end
    local empty = nil
    if isPending("admin.marketHistory") then empty = tr("Admin_Loading")
    elseif snap and self.histF.total == 0 and #(snap.entries or {}) > 0 then
        -- the reply carried lines; the filter row is what emptied the page
        empty = tr("Filter_NoMatch")
    elseif self.histUser then empty = tr("Admin_Lst_HistoryEmpty") end
    if empty then
        text(self, fitText(empty, math.max(0, self.historyList.width - PAD * 2)),
            self.historyList.x + PAD, self.historyList.y + 4, "textFaint")
    end
end

function Admin:drawListings()
    local g = self.g
    card(self, 0, g.lstY, self.width, g.lstH, tr("Admin_Lst_Title"))
    if self.lstMode == "history" then return self:drawListingHistory() end
    local snap = self.listings
    local rows = self.listingRows or {}
    local countText = getText(T .. "Admin_Lst_Count", tostring((snap and snap.total) or 0))
    textRight(self, countText, self.width - PAD, g.lstHeadY, "textFaint")
    text(self, tr("Admin_Mkt_SellerExact"), g.lstSellerLabelX, g.lstHeadY, "textFaint")
    -- the standing note gives way to the seller in force: it is the one thing that changes what
    -- the rows and the count on screen mean
    local note = self.lstSeller and getText(T .. "Admin_Mkt_SellerPicked", self.lstSeller)
        or tr("Admin_Lst_Note")
    text(self, fitText(note, math.max(0, self.width - PAD * 2 - g.lstNoteX - textWidth(countText))),
        g.lstNoteX, g.lstHeadY, self.lstSeller and "accent" or "textFaint")
    -- with the table hidden the record owns the area: its empty line must not paint over it
    if #rows == 0 and self.listingsList:getIsVisible() then
        local empty
        if snap == nil then
            empty = isPending("admin.listings") and tr("Admin_Loading") or tr("Admin_Dash_Empty")
        else
            empty = tr("Admin_Lst_Empty")
        end
        text(self, empty, self.listingsList.x + PAD, self.listingsList.y + 4, "textFaint")
    end
    local page, pages = 1, 1
    if snap then
        page = math.max(1, math.floor(tonumber(snap.page) or 1))
        pages = math.max(1, math.floor(tonumber(snap.pages) or 1))
    end
    text(self, fitText(getText(T .. "Market_Page", tostring(page), tostring(pages)),
        math.max(0, self.lstPrevButton.x - PAD * 2)), PAD, g.lstPageTextY, "textFaint")
end

-- The auctions card in history mode: the same header row, the whole server's auction record
-- under it (newest first), the type / date / sort / page row instead of the page chips.
function Admin:drawAuctionHistory()
    local g = self.g
    filterDraw(self.aucF, self)
    local snap = self.aucHistory
    local rows = self.aucHistoryRows or {}
    local countText = ""
    if snap then
        countText = getText(T .. "Admin_Auc_Count", tostring(math.floor(tonumber(snap.total) or #rows)))
        textRight(self, countText, self.width - PAD, g.aucHeadY, "textFaint")
    end
    -- the truncation warning replaces the standing note: it is the one thing that changes what
    -- the numbers on screen mean
    local note = (snap and snap.truncated == true) and tr("Auction_History_Truncated")
        or tr("Admin_Auc_HistoryNote")
    text(self, fitText(note, math.max(0, self.width - PAD * 2 - g.aucNoteX - textWidth(countText))),
        g.aucNoteX, g.aucHeadY, "textFaint")
    if #rows > 0 then return end
    -- the record is always being asked for while this mode is open, so "no snapshot yet" reads
    -- as loading rather than as an empty server
    local empty = tr("Auction_History_Empty")
    if snap == nil or isPending("admin.auctions") then
        empty = tr("Admin_Loading")
    elseif self.aucF.total == 0 and #(snap.entries or {}) > 0 then
        empty = tr("Filter_NoMatch")   -- the reply carried lines; the filter row emptied the page
    end
    text(self, fitText(empty, math.max(0, self.aucHistoryList.width - PAD * 2)),
        self.aucHistoryList.x + PAD, self.aucHistoryList.y + 4, "textFaint")
end

function Admin:drawAuctions()
    local g = self.g
    card(self, 0, g.aucY, self.width, g.aucH,
        tr(self.aucMode == "history" and "Auction_History_Title" or "Admin_Auc_Title"))
    if self.aucMode == "history" then return self:drawAuctionHistory() end
    local snap = self.auctions
    local rows = self.auctionRows or {}
    local countText = getText(T .. "Admin_Auc_Count", tostring((snap and snap.total) or 0))
    textRight(self, countText, self.width - PAD, g.aucHeadY, "textFaint")
    text(self, tr("Admin_Mkt_SellerExact"), g.aucSellerLabelX, g.aucHeadY, "textFaint")
    local note = self.aucSeller and getText(T .. "Admin_Mkt_SellerPicked", self.aucSeller)
        or tr("Admin_Auc_Note")
    text(self, fitText(note, math.max(0, self.width - PAD * 2 - g.aucNoteX - textWidth(countText))),
        g.aucNoteX, g.aucHeadY, self.aucSeller and "accent" or "textFaint")
    if #rows == 0 and self.auctionsList:getIsVisible() then
        local empty
        if snap == nil then
            empty = isPending("admin.auctions") and tr("Admin_Loading") or tr("Admin_Dash_Empty")
        else
            empty = tr("Admin_Auc_Empty")
        end
        text(self, empty, self.auctionsList.x + PAD, self.auctionsList.y + 4, "textFaint")
    end
    local page, pages = 1, 1
    if snap then
        page = math.max(1, math.floor(tonumber(snap.page) or 1))
        pages = math.max(1, math.floor(tonumber(snap.pages) or 1))
    end
    text(self, fitText(getText(T .. "Market_Page", tostring(page), tostring(pages)),
        math.max(0, self.aucPrevButton.x - PAD * 2)), PAD, g.aucPageTextY, "textFaint")
end


function Admin:drawAudit()
    local g = self.g
    local rh = rowH()
    card(self, 0, g.bodyY, self.width, g.bodyH, tr("Admin_Audit_Title"))
    local filterY = self.auditEntry.y + math.floor((entryH() - fontH.small) / 2)
    local stampW = 0
    if self.auditAt then
        local stamp = getText(T .. "Admin_Updated", stampText(self.auditAt, self.offsetMin))
        stampW = textWidth(stamp) + PAD
        textRight(self, stamp, self.width - PAD, filterY, "textFaint")
    end
    local rolled = self.auditF.kind == "rolled"
    filterDraw(self.auditF, self)
    local total = self.auditTotal or 0
    text(self, fitText(getText(T .. "Admin_Audit_Count", tostring(#(self.auditRows or {})), tostring(total)),
        self.width - g.auditCountX - stampW), g.auditCountX, filterY, "textMuted")
    if self.auditList:getIsVisible() then
        drawColumnHeaders(self, self.auditList, AUDIT_COLS, self.auditList.x, g.auditHeaderY, rh)
        if #(self.auditRows or {}) == 0 then
            local empty
            if isPending("admin.audit") or isPending("admin.auditFile") then empty = tr("Admin_Loading")
            elseif total > 0 then empty = tr("Filter_NoMatch")   -- the filter emptied a live source
            else empty = tr("Admin_Audit_Empty") end
            text(self, empty, self.auditList.x + PAD, g.auditHeaderY + rh + 4, "textFaint")
        end
    end
    -- the standing note, plus the one thing that changes what the actor box can offer: a
    -- candidate list the server had to cut short is said to be short, never shown as the whole
    -- set -- an actor it left out can still be typed in by hand
    local note = tr(rolled and "Admin_Audit_RolledNote" or "Admin_Audit_ReasonNote")
    if self.auditActorsTruncated then note = tr("Admin_Audit_ActorsTruncated") .. "  " .. note end
    text(self, fitText(note, self.width - PAD * 2), PAD, g.auditBottom + 2, self.auditActorsTruncated and "warn" or "textFaint")
end

function Admin:drawSystem()
    local g = self.g
    local lh = lineH()
    local sys = self.system
    card(self, 0, g.bodyY, g.sysLeftW, g.bodyH, tr("Admin_Sys_State"))
    self:refreshSystemReader()

    card(self, g.sysRightX, g.bodyY, g.sysRightW, g.bodyH, tr("Admin_Sys_Paths"))
    local py = g.sysPathY
    local paths = sys and sys.paths
    for i, key in ipairs(PATH_KEYS) do
        local button = self.copyButtons[i]
        local value = tostring(paths and paths[key] or "-")
        local label = tr("Admin_Sys_Path_" .. key)
        local vy = py + math.floor((button.height - fontH.small) / 2)
        if g.sysStacked then
            text(self, label, g.sysRightX + PAD, py, "textMuted")
            py = py + lh
            vy = py + math.floor((button.height - fontH.small) / 2)
            text(self, pathDisplay(value, button.x - 6 - (g.sysRightX + PAD)), g.sysRightX + PAD, vy, "text")
        else
            text(self, fitText(label, g.sysLabelW), g.sysRightX + PAD, vy, "textMuted")
            local vx = g.sysRightX + PAD + g.sysLabelW + PAD
            text(self, pathDisplay(value, button.x - 6 - vx), vx, vy, "text")
        end
        py = py + button.height + 4
    end
    -- the server omits paths entirely when it could not resolve the cache dir (pathsResolved)
    if sys and paths == nil and py + lh <= g.bodyY + g.bodyH - 2 then
        text(self, fitText(tr("Admin_Sys_PathsUnavailable"), g.sysRightW - PAD * 2), g.sysRightX + PAD, py, "warn")
    end
end

function Admin:drawSettings()
    local g = self.g
    card(self, 0, g.bodyY, self.width, g.bodyH, tr("Admin_Set_Title"))
    local searching = self.setQuery ~= nil
    local rows = self.settingRows or {}
    -- search row: the standing note fills the space beside the box, the row count sits far right
    local countText = getText(T .. "Admin_Set_Count", tostring(#rows))
    local headY = self.setEntry.y + math.floor((self.setEntry.height - fontH.small) / 2)
    textRight(self, countText, self.width - PAD, headY, "textFaint")
    text(self, fitText(tr("Admin_Set_Note"), math.max(0, self.width - PAD * 2 - g.setCountX - textWidth(countText))),
        g.setCountX, headY, "textFaint")

    -- The group list draws inside this well and owns its scrollbar.
    fill(self, PAD, g.setNavY, g.setNavW, g.setNavH, "well", "rect")

    -- content column: the group (or "search") as its heading, then the list
    local title = searching and tr("Admin_Set_Search") or tr("Admin_Set_Group_" .. self.setGroup)
    text(self, fitText(title, g.setContentW, UIFont.Medium), g.setContentX, g.setHeadY, "text", UIFont.Medium)
    if #rows == 0 then
        local empty
        if self.options == nil then
            empty = isPending("admin.system") and tr("Admin_Loading") or tr("Admin_Dash_Empty")
        else
            empty = tr("Admin_Set_NoMatch")
        end
        text(self, empty, self.settingsList.x + PAD, self.settingsList.y + 4, "textFaint")
    end
end

function Admin:clearData()
    self:closeDialog()
    self.picker:close()
    -- every record on screen belonged to data that is now gone
    D.close(self)
    self.pendingRecovery = nil
    self.recoveryPage:clear()
    -- losing the right takes both season identities with it: neither the request that was open
    -- nor the one whose outcome was unknown may come back and repaint a desk this actor is no
    -- longer allowed to read
    self.pendingSeason, self.seasonUnknown = nil, nil
    pendingAt["admin.seasons"], pendingAt["admin.option"] = nil, nil
    self.seasonsPage:clear()
    self.pendingCatalog, self.pendingWhitelist, self.pendingOption = nil, nil, nil
    self.optionRequestId = nil
    self.pendingAdjust, self.pendingFreeze, self.pendingConfig = nil, nil, nil
    self.pendingSource, self.pendingListings, self.pendingAuctions = nil, nil, nil
    self.resetQueue = nil
    for command in pairs(deferred) do
        deferred[command], pendingAt[command] = nil, nil
    end
    self.lookup, self.lookupFile, self.system, self.sources = nil, nil, nil, nil
    -- losing the right to read must not leave the whole server's balances on screen: the supply
    -- figures and the account list both go with it
    self.supply, self.supplyAt = nil, nil
    self.accRequestId, self.curRequestId = nil, nil
    self.accountsPage:clear()
    for _, reader in ipairs({ self.statusReader, self.currencyReader, self.sourceReader, self.systemReader }) do
        reader.ecSnapshot, reader.ecIcons, reader.ecSupply = nil, nil, nil
        U.setWrappedText(reader, "", reader.width)
        reader.ecRawText = nil
    end
    self.summaryList:setItems({})
    self.audit, self.auditFile, self.auditSelected, self.options = nil, nil, nil, nil
    self.auditDetailKey, self.auditDetailMonth = nil, nil
    self.auditDetailRequestId, self.auditDetailEntries = nil, nil
    self.auditDetailState = "idle"
    self.auditRequestId, self.auditFileRequestId = nil, nil
    self.auditSentKey, self.auditFileSentKey = nil, nil
    self.auditActor, self.auditActorAt = nil, nil
    self.auditActorsFile, self.auditActorsRing = nil, nil
    self.auditFileActorsCut, self.auditRingActorsCut = nil, nil
    self.auditActorsTruncated = false
    setEntryText(self.auditActorEntry, "")
    self:rebuildAuditActors()
    self.selectedReceipt, self.receiptRows = nil, {}
    self.receiptList:setItems({})
    self.listings, self.auctions = nil, nil
    self.lstRequestId, self.aucRequestId = nil, nil
    self.selectedListing, self.selectedAuction = nil, nil
    self.lstSeller, self.lstSentSeller = nil, nil
    self.aucSeller, self.aucSentSeller = nil, nil
    self.lstSellerPicker:setText("")
    self.aucSellerPicker:setText("")
    self:closeSellerPickers()
    self.marketHistory, self.histUser, self.histSentUser = nil, nil, nil
    self.aucHistory, self.aucHistId, self.aucHistAsked = nil, nil, false
    self.aucHistSentQuery, self.aucHistSentId = nil, nil
    self.txPage:clear()
    self.shopPage:clear()
    self.whitelistPage:clear()
end

function Admin:prerender()
    if self.width ~= self.layoutW or self.height ~= self.layoutH then
        self:layout()
    end

    local now = EC.now()
    -- permission collapse: re-read the role at most twice a second
    if not self.permCheckedAt or now - self.permCheckedAt > PERM_POLL_MS then
        self.permCheckedAt = now
        self:syncPermissionContext(true)
        -- four separate rights, and any of them moving redraws the page: the write role, the
        -- read role, the native role capability (it alone opens the manage options) and the
        -- grant to adjust one's own balance
        local write, read = self:writeAllowed(), self:readAllowed()
        local manage, selfAdjust = self:manageAllowed(), self:selfAdjustAllowed()
        if self.dialog ~= nil and not self:dialogAllowed() then self:closeDialog() end
        if write ~= self.hadWrite or read ~= self.hadRead or manage ~= self.hadManage
            or selfAdjust ~= self.hadSelfAdjust then
            if not write then self.recoveryPage:stopJob("forbidden") end
            if not read then self:clearData() end
            self:layout()   -- hides/shows the page children for the new permission level
        end
    end

    -- outcome of an icon reload started a moment ago
    if self.iconsRecheckAt and now >= self.iconsRecheckAt then
        self.iconsRecheckAt = nil
        if self:readAllowed() then send("admin.icons", { action = "status" }) end
        self:updateEnabled()
    end

    -- Another admin's change reaches us as a config broadcast (ECClient replaces C.options with
    -- a fresh table): adopt whichever snapshot arrived last, without a round trip of our own.
    if self.tab == "Settings" and C.options ~= nil and C.options ~= self.optionsSeen then
        self.optionsSeen = C.options
        self.options = C.options
        self:rebuildSettings()
        self:updateEnabled()
    end

    if self.recoveryPage.job ~= nil and not self:writeAllowed() then self.recoveryPage:stopJob("forbidden") end
    local option = deferred["admin.option"]
    if option and not self:optionAllowed(EC.OPTION_BY_KEY[option.args.key]) then
        deferred["admin.option"], pendingAt["admin.option"] = nil, nil
        -- the write never left the client, so nothing can answer for it: its identity goes too
        self.pendingOption, self.optionRequestId, self.resetQueue = nil, nil, nil
        self:updateEnabled()
    end
    -- a rotation the cooldown is still holding on to, after the capability that authorised it
    -- was taken away: it never leaves the client, and it is not revived when the right returns
    local rotation = deferred["admin.seasons"]
    if rotation ~= nil and rotation.args.action == "start" and not self:manageAllowed() then
        self:cancelDeferredSeason(rotation.args.requestId)
    end
    local adjustment = deferred["admin.adjust"]
    if adjustment and (not self:writeAllowed() or (getPlayer()
        and adjustment.args.username == getPlayer():getUsername() and not self:selfAdjustAllowed())) then
        deferred["admin.adjust"], pendingAt["admin.adjust"] = nil, nil
        self.pendingAdjust = nil
        self:updateEnabled()
    end
    flushDeferred(now)

    -- one timed-out command per frame at most (pendingAt holds at most #COMMANDS keys)
    local stale = nil
    for command, at in pairs(pendingAt) do
        if now - at > TIMEOUT_MS then stale = command end
    end
    if stale then
        pendingAt[stale] = nil
        deferred[stale] = nil
        self:onTimeout(stale)
    end

    -- a target the admin asked for while the cooldown or an older lookup was still holding
    if self.lookupRetryUser and self.hadRead then
        if self.lookupRetryUser ~= self.lookupUser then
            self.lookupRetryUser = nil
        elseif send("admin.lookup", { username = self.lookupRetryUser }) then
            self.lookupRetryUser = nil
            self:updateEnabled()
        end
    end

    -- a page, a search text or an exact seller the admin changed while the cooldown (or an
    -- older answer) was still holding the command. The seller box has its own pause clock, so
    -- typing a name costs one read, not one per key.
    if self.tab == "Listings" and self.hadRead and self.lstMode ~= "history" then
        if self.lstSentQuery ~= self.lstQuery or self.lstSentSeller ~= self.lstSeller
            or self.lstSentPage ~= (self.lstPage or 1) then
            self:requestListings()
        end
    end

    -- the auction page's search box, both modes over the same clock: one command per pause, and
    -- -- once the pause has passed -- the same re-ask the listings page does when the cooldown
    -- refused the request. A read that came back refused is *not* re-asked: the sent state was
    -- recorded when it left, so a busy server is reported once instead of hammered.
    if self.tab == "Auctions" and self.hadRead then
        local history = self.aucMode == "history"
        local moved = history
            and (not self.aucHistAsked or self.aucHistSentQuery ~= self.aucQuery
                or self.aucHistSentId ~= self.aucHistId)
            or (not history
                and (self.aucSentQuery ~= self.aucQuery or self.aucSentSeller ~= self.aucSeller
                    or self.aucSentPage ~= (self.aucPage or 1)))
        if self.aucQueryAt and now - self.aucQueryAt > AUCTION_DEBOUNCE_MS then
            self.aucQueryAt = nil
            if history then self:requestAuctionHistory() else self:requestAuctions() end
        elseif not self.aucQueryAt and moved then
            if history then self:requestAuctionHistory() else self:requestAuctions() end
        end
    end

    if self.tab == "Transactions" and self.hadRead then self.txPage:tick(now) end
    if self.tab == "Shop" and self.hadRead then self.shopPage:tick(now) end
    if self.tab == "Whitelist" and self.hadRead then self.whitelistPage:tick(now) end
    -- the account list: its search box's pause, and the read a cooldown or an older answer held
    -- back. No Events hook and no timer of its own either -- this frame callback is its clock.
    if self.tab == "Player" and self.playerMode == "list" and self.hadRead then
        self.accountsPage:tick(now)
    end
    -- the reconciliation page: the read a host asked for while the shared slot was busy, the
    -- account filter's pause and the next write of a queue all go out from here. No Events hook
    -- and no poll of its own -- this frame callback is the whole clock.
    if self.tab == "Recovery" and self.hadRead then self.recoveryPage:tick(now) end
    -- the season desk: the read it was owed while the shared slot was busy goes out from here
    if self.tab == "Seasons" and self.hadRead then self.seasonsPage:tick(now) end

    -- the account typed in history mode: one command per pause, never one per keystroke
    if self.histQueryAt and now - self.histQueryAt > PLAYERS_DEBOUNCE_MS then
        self.histQueryAt = nil
        if self.tab == "Listings" and self.lstMode == "history" and self.hadRead then
            self:requestMarketHistory()
        end
    end

    -- the English item index loads in bounded slices: the rows that carry an English name are
    -- rebuilt once, when it moves, and nothing polls it
    if self.hadRead and (self.tab == "Listings" or self.tab == "Auctions") then
        C.ItemNames.ensure()
        if self.namesRev ~= C.ItemNames.revision then
            self.namesRev = C.ItemNames.revision
            self:rebuildListings()
            self:rebuildAuctions()
        end
    end

    -- the full text of the picked audit line, asked for again while the cooldown held it back
    -- ("ring" is what a refused send leaves behind) or while the server was busy (bounded, so a
    -- stuck fence is reported once instead of hammered)
    if self.tab == "Audit" and self.hadRead
        and (self.auditDetailState == "ring"
            or (self.auditDetailState == "busy" and (self.auditDetailTries or 0) < AUDIT_DETAIL_TRIES)) then
        self:requestAuditDetail()
    end

    -- the actor typed into the audit box, and whatever read the cooldown refused after an actor
    -- or a day bound moved: both reads carry the same question, so both are asked again
    if self.tab == "Audit" and self.hadRead then
        if self.auditActorAt and now - self.auditActorAt > FILTER_DEBOUNCE_MS then
            self:applyAuditActor()
        else
            local key = self:auditFilterKey()
            if self.auditSentKey ~= nil and self.auditSentKey ~= key then self:requestAudit() end
            if self.auditFileSentKey ~= nil and self.auditFileSentKey ~= key then
                self:requestAuditFile()
            end
        end
    end

    -- visible auto refresh of the open page (read permission only): the 30 s backstop, plus the
    -- pages a views.changed marked while they were hidden or while another read was in flight
    if self.hadRead and (not self.polledAt or now - self.polledAt > POLL_MS or self:tabDirty()) then
        self.polledAt = now
        self:refresh()
    end

    -- search candidates: debounce clock and the dropdown's own geometry
    if self.tab == "Player" and self.hadRead then self.picker:tick(now) end
    -- the two seller boxes: the debounce clock, the IME read-back and the list's own geometry.
    -- A box the layout has hidden answers tick with nothing.
    if self.hadRead then
        self.lstSellerPicker:tick(now)
        self.aucSellerPicker:tick(now)
    end

    local g = self.g
    -- The money views are read against the numbers, so their backdrop is painted opaque whatever
    -- the window opacity slider says: at 50 % the selected row's secondary text measured
    -- 1.00:1 against the world behind it (.omc/tmp/colour-audit.json). The stored opacity is
    -- untouched -- the window chrome around this child still honours it.
    if self.tab == "Transactions" or self.tab == "Shop" or self.tab == "Whitelist"
        or self.tab == "Recovery" or self.tab == "Seasons"
        or (self.tab == "Player" and self.playerMode == "list") then
        fillSolid(self, 0, 0, self.width, self.height, "surface")
    end
    fill(self, 0, 0, self.width, g.subH, "well", "rect")
    if not self.hadRead then
        text(self, tr("Admin_NoPermission"), PAD, g.bodyY, "errorText")
        return
    end
    -- The freshness of the page that is up, in the tab strip. The account list carries its own
    -- measurement time here rather than on its card: at the minimum window with a large UI font
    -- the card's line had to share its width with the page chips and fitText ate the stamp, so
    -- this strip (right-aligned, never fitted) and the refresh chip's tooltip are where the full
    -- value lives. The chip's tooltip is set whether or not the strip had room to paint it.
    local stampAt = ((self.tab == "Dashboard" or self.tab == "System" or self.tab == "Settings") and self.systemAt)
        or (self.tab == "Sources" and self.sourcesAt) or (self.tab == "Shop" and self.shopPage.updatedAt)
        or (self.tab == "Currencies" and self.supplyAt)
        or (self.tab == "Player" and self.playerMode == "list" and self.accountsPage.at)
        or (self.tab == "Listings" and (self.lstMode == "history" and self.historyAt or self.listingsAt))
        or (self.tab == "Auctions" and (self.aucMode == "history" and self.aucHistoryAt or self.auctionsAt))
        or (self.tab == "Transactions" and self.txPage.updatedAt)
        or (self.tab == "Recovery" and self.recoveryPage.updatedAt)
        or (self.tab == "Seasons" and self.seasonsPage.updatedAt) or nil
    if stampAt then
        local fresh = getText(T .. "Admin_Updated", stampText(stampAt, self.offsetMin))
        textRight(self, fresh, self.refreshButton.x - PAD,
            math.floor((g.subH - fontH.small) / 2), "textMuted")
        -- a manual tooltip: Button:prerender only replaces one it set itself (autoTooltip), so
        -- this is never clobbered by the label-truncation tooltip
        self.refreshButton.tooltip = fresh
    else
        self.refreshButton.tooltip = nil
    end
    -- the account list is a sub page and paints itself; the operate mode is drawn here
    if self.tab == "Player" then
        if self.playerMode ~= "list" then self:drawPlayer() end
    elseif self.tab == "Dashboard" then
        self:drawDashboard()
    elseif self.tab == "Currencies" then
        self:drawCurrencies()
    elseif self.tab == "Sources" then
        self:drawSources()
    elseif self.tab == "Listings" then
        self:drawListings()
    elseif self.tab == "Auctions" then
        self:drawAuctions()
    elseif self.tab == "Audit" then
        self:drawAudit()
    elseif self.tab == "Settings" then
        self:drawSettings()
    elseif self.tab == "System" then
        self:drawSystem()
    end

    -- Feedback takes the whole footer; the standing audit note must not hide a failed write.
    local fy = g.footerY + 1
    local settingMessage = self.tab == "Settings" and self.message ~= nil
    self.setMessageButton:setVisible(settingMessage)
    self.setMessageButton:setEnable(settingMessage and not self:isModal())
    if self.message then
        if settingMessage then
            if self.setMessageButton.fullTitle ~= self.message.text then
                U.setButtonTitle(self.setMessageButton, self.message.text)
            end
            self.setMessageButton.stateToken = self.message.error and "errorText" or "positive"
        else
            text(self, fitText(self.message.text, self.width - PAD * 2), 0, fy, self.message.error and "errorText" or "positive")
        end
    else
        textRight(self, fitText(tr("Admin_AuditNote"), self.width - PAD * 2), self.width, fy, "textFaint")
    end
end

function Admin:render() end

-- row click selects the currency / integration source the action buttons operate on
-- Jump to the audit page filtered to one account's freeze history (full reasons come from the
-- audit files, which the page loads on open).
function Admin:showAuditFor(username, filter)
    for _, b in ipairs(self.subTabButtons) do
        if b.internal == "Audit" then self:onSubTab(b) end
    end
    setEntryText(self.auditEntry, username)
    self.auditQuery = string.lower(username)
    local f = self.auditF
    f.kind = filter or "all"
    f.page = 1
    for _, b in ipairs(f.kindButtons) do b.active = (not b.unused) and b.internal == f.kind end
    self:rebuildAudit()
end

function Admin:onMouseDown(x, y)
    if self.dialog then return true end
    if self.tab == "Currencies" and x < (self.g and self.g.cfgTableW or 0) then
        for _, r in ipairs(self.cfgRowRects or {}) do
            if y >= r.y and y < r.y + r.h then
                self.cfgSelected = r.id
                self:updateEnabled()
                return true
            end
        end
    elseif self.tab == "Sources" and x < (self.g and self.g.srcTableW or 0) then
        for _, r in ipairs(self.srcRowRects or {}) do
            if y >= r.y and y < r.y + r.h then
                self.srcSelected = r.id
                self:updateEnabled()
                return true
            end
        end
    end
    return true
end

function Admin:onMouseUp(x, y) return true end

-- ----- lifecycle -----

-- Server round trips for the page that is on screen. Commands are cooldown-guarded, so a rapid
-- tab switch simply skips the extra request.
function Admin:refresh()
    if not self:readAllowed() then return end
    -- the views.changed mark is cleared by the read it asked for, never by the notice itself
    self.dirty[self.tab] = nil
    if self.tab == "Player" then
        -- the mode on screen decides the read: the account list, or the one account the operate
        -- mode is holding (and nothing at all before a target has been named)
        if self.playerMode == "list" then
            self.accountsPage:refresh()
        elseif self.lookupUser then
            send("admin.lookup", { username = self.lookupUser })
        end
    elseif self.tab == "Audit" then
        self:requestAudit()
        self:requestAuditFile()
    elseif self.tab == "Dashboard" or self.tab == "System" or self.tab == "Settings" then
        send("admin.system", {})
    elseif self.tab == "Currencies" then
        -- the currency page's own read: the registry, the option snapshot behind the caps and the
        -- supply figures in one answer. The icon status is asked for once, separately.
        self:requestCurrency()
        if self.icons == nil then send("admin.icons", { action = "status" }) end
    elseif self.tab == "Sources" then
        send("admin.sources", { action = "list" })
    elseif self.tab == "Shop" then
        self.shopPage:refresh()
    elseif self.tab == "Listings" then
        if self.lstMode == "history" then
            if self.histUser then self:requestMarketHistory() end
        else
            self:requestListings()
        end
    elseif self.tab == "Auctions" then
        if self.aucMode == "history" then
            -- a read either way: an empty box is the whole server's record, so the poll asks
            -- for it exactly like the active list. A refusal keeps the snapshot on screen.
            self:requestAuctionHistory()
        else
            self:requestAuctions()
        end
    elseif self.tab == "Transactions" then
        self.txPage:refresh()
    elseif self.tab == "Whitelist" then
        self.whitelistPage:refresh()
    elseif self.tab == "Recovery" then
        self.recoveryPage:refresh()
    elseif self.tab == "Seasons" then
        self.seasonsPage:refresh()
    end
    self:updateEnabled()
end

function Admin:setVisible(visible)
    local was = self:getIsVisible()
    ISPanel.setVisible(self, visible)
    if visible then
        self.offsetMin = U.localOffsetMinutes()
        if not was then
            self.permCheckedAt = nil
            self.polledAt = nil
        end
    else
        for _, f in ipairs({ self.auditF, self.histF, self.aucF }) do blurFilterDates(f) end
        self:closeDialog()
        self.picker:close()
        -- the reconciliation page may have a queue running: a window nobody can see must not keep
        -- writing, and a write already in flight is reported as unknown rather than resumed
        self:leaveRecovery()
        self:leaveSeasons()
        -- a record read out of a page that is no longer on screen has no owner left
        D.close(self)
        filterCloseCombo(self.auditActorCombo)
        pcall(function() self.auditEntry:unfocus() end)
        pcall(function() self.auditActorEntry:unfocus() end)
        pcall(function() self.setEntry:unfocus() end)
        pcall(function() self.lstEntry:unfocus() end)
        pcall(function() self.aucEntry:unfocus() end)
        self:closeSellerPickers()
    end
    self.txPage:setVisible(visible and self.tab == "Transactions" and self:readAllowed())
    self.shopPage:setVisible(visible and self.tab == "Shop" and self:readAllowed())
    self.whitelistPage:setVisible(visible and self.tab == "Whitelist" and self:readAllowed())
    self.recoveryPage:setVisible(visible and self.tab == "Recovery" and self:readAllowed())
    self.seasonsPage:setVisible(visible and self.tab == "Seasons" and self:readAllowed())
    -- the account list keeps everything it read: a window that was merely hidden must come back
    -- to the same slice, and the permission collapse is what drops it
    self.accountsPage:setVisible(visible and self.tab == "Player" and self.playerMode == "list"
        and self:readAllowed())
end

function Admin:dispose()
    self:dropUnsentSeasonStart()
    self.txPage:dispose()
    self.recoveryPage:dispose()
    self.pendingRecovery = nil
    self.seasonsPage:dispose()
    self.pendingSeason, self.seasonUnknown = nil, nil
    self.shopPage:dispose()
    self.whitelistPage:dispose()
    self.accountsPage:dispose()
    self:closeDialog()
    self.picker:dispose()
    D.close(self)
    filterCloseCombo(self.auditActorCombo)
    pcall(function() self.auditEntry:unfocus() end)
    pcall(function() self.auditActorEntry:unfocus() end)
    pcall(function() self.setEntry:unfocus() end)
    pcall(function() self.lstEntry:unfocus() end)
    pcall(function() self.aucEntry:unfocus() end)
    self.lstSellerPicker:dispose()
    self.aucSellerPicker:dispose()
    pcall(function() self.auditF.fromEntry:unfocus() end)
    pcall(function() self.auditF.toEntry:unfocus() end)
    pcall(function() self.histF.fromEntry:unfocus() end)
    pcall(function() self.histF.toEntry:unfocus() end)
    pcall(function() self.aucF.fromEntry:unfocus() end)
    pcall(function() self.aucF.toEntry:unfocus() end)
    self.lookup = nil
    self.audit = nil
    self.system = nil
    self.pendingAdjust = nil
    self.pendingFreeze = nil
    self.pendingConfig = nil
    self.sources = nil
    self.pendingSource = nil
    self.options = nil
    self.pendingOption, self.optionRequestId = nil, nil
    self.resetQueue = nil
    self.pendingCatalog = nil
    self.catalogRequestId = nil
    self.listings = nil
    self.pendingListings = nil
    self.auctions = nil
    self.pendingAuctions = nil
    self.aucHistory = nil
    self.pendingAucHistory = nil
    self.aucHistId = nil
    self.pendingWhitelist = nil
    self.whitelistRequestId = nil
    self.marketHistory = nil
    self.histUser = nil
    self.histSentUser = nil
    self.auditSelected = nil
    self.auditDetailKey, self.auditDetailMonth = nil, nil
    self.auditDetailRequestId, self.auditDetailEntries = nil, nil
    self.auditRequestId, self.auditFileRequestId = nil, nil
    self.auditActorsFile, self.auditActorsRing = nil, nil
    self.lstRequestId, self.aucRequestId = nil, nil
    self.lstSeller, self.aucSeller = nil, nil
    self.accRequestId, self.curRequestId = nil, nil
    self.supply, self.supplyAt = nil, nil
    if P.instance == self then P.instance = nil end
end

-- ---------- module API ----------

-- owner: the independent ECAdminWindow, which owns the sidebar and root keyboard focus.
-- Returns an initialised child that the owner adds, positions and resizes. No command is sent.
function P.create(owner)
    if not U.init() then return nil end
    local o = ISPanel:new(0, 0, 600, 300)
    setmetatable(o, Admin)
    o.background = false
    o.owner = owner
    o.tab = "Player"
    -- the player tab opens on the account list: "who holds what" is a question the server can
    -- answer with nothing typed in, and the operate mode needs a target first
    o.playerMode = "list"
    o.dashCurrency = EC.CURRENCY_ORDER[1]
    o.lstPage = 1
    o.aucPage = 1
    o.aucMode = "active"
    o.lstMode = "listings"
    o.auditDetailState = "idle"
    o.auditActorsTruncated = false
    o.dirty = {}
    o.auditQuery = nil
    o.cfgSelected = EC.CURRENCY_ORDER[1]
    o.cfgRowRects = {}
    o.srcRowRects = {}
    o.setGroup = EC.OPTION_GROUPS[1]
    o.offsetMin = U.localOffsetMinutes()
    o.hadWrite = P.canWrite()
    o.hadManage = P.canManage()
    o.hadRead = o.hadWrite or o.hadManage or P.canRead()
    o.hadSelfAdjust = P.canSelfAdjust()
    o:initialise()
    o:instantiate()   -- builds the children now; the owner only has to addChild/resize
    o:setVisible(false)
    P.instance = o
    return o
end

for _, command in ipairs(COMMANDS) do
    local kind = string.sub(command, 7)
    C.handlers[command] = function(args)
        local inst = P.instance
        -- A stale page reply must not release the shared slot owned by a newer read: the owner is
        -- matched *before* the pending flag is cleared, never after.
        if inst and type(args) == "table" and not inst:matchesReply(kind, args) then return end
        if inst and type(args) == "table" then
            local id
            if kind == "catalog" then id = inst.catalogRequestId
            elseif kind == "whitelist" then id = inst.whitelistRequestId end
            if id ~= nil and args.requestId ~= id then return end
        end
        pendingAt[command] = nil
        if inst then inst:onReply(kind, args or {}) end
    end
end

-- market.sellers is a public command, so ECClient owns its one handler and hands it to every
-- market listener; this window is one of them. The box that asked is matched *before* the
-- shared slot is freed, so an answer to a read a box has already moved past can neither release
-- the slot nor be shown as its candidates. A reply that belongs to the player panel's own boxes
-- is simply not owned here and falls through untouched.
C.onMarket(function(kind, args)
    if kind ~= "sellers" then return end
    local inst = P.instance
    if inst == nil or type(args) ~= "table" then return end
    -- the slot is freed by the read that reserved it, matched on that read's own requestId: a
    -- stale answer never releases a newer read, and a box folded away by a page switch does not
    -- hold the command until the timeout. Which box still wants the candidates is separate.
    if args.requestId ~= nil and args.requestId == lastSellersRequestId then
        pendingAt["market.sellers"] = nil
        lastSellersRequestId = nil
    end
    if not inst.lstSellerPicker:onReply(args) then inst.aucSellerPicker:onReply(args) end
end)

-- The server tells a client which scopes moved (ECExport -> S.reply("views.changed")); the page
-- that shows one re-reads it while it is up and is simply marked while it is not. The notice
-- carries no economy data and is never treated as the fresh snapshot itself.
C.onViews(function(scope)
    local inst = P.instance
    if inst then inst:onViewChanged(scope) end
end)

return P
