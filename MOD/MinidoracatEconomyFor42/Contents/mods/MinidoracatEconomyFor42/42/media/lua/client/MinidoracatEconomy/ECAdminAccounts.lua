-- MinidoracatEconomyFor42 -- admin account list page (client). Adds exactly one namespace:
-- C.AdminAccounts.
--
--   C.AdminAccounts.create(owner, isPending)
--       an initialised ISPanel child, NOT added (the admin controller addChild's it) and never
--       sends a command of its own. isPending is the controller's plain function, always called
--       as self.isPending(...), never with ":".
--
-- Why a page and not a card on the player tab: "who holds what" is a question about the whole
-- server, and the old admin.players read answered a different one (the first 30 names that match
-- a prefix, out of at most 200 scanned). This page reads admin.accounts, which sorts the whole
-- population the economy knows about (wallets, claims, freezes and whoever is online, minus the
-- system accounts) and only then cuts it into pages of 20 -- so the ordering is the server's, the
-- page is a slice of a complete sort, and an account with nothing in it is still in the list.
--
-- The player tab has two modes and this page is the list one; the controller owns the two chips
-- that switch them. Picking a row hands the account to the controller's own lookup (the operate
-- mode), and coming back finds the list exactly as it was: the page is only hidden, so query,
-- status, sort, direction, page and the rows it last read all stay. Nothing is re-asked on the
-- way back -- only the 30 s poll or a views.changed mark does that.
--
-- What it borrows from the controller, and nothing else:
--   owner:readAllowed()          the permission gate (this page has no write at all)
--   owner:requestAccounts()      the only way a read leaves this page; the controller owns the
--                                one in-flight admin.accounts slot and stamps the requestId
--   owner:openLookup(username)   the row jump into the operate mode
--   owner.message / owner.offsetMin   the shared footer line / the window's timezone
--   owner.dialog                 a controller dialog owns the panel (modal)
--   owner.owner                  the root window, the only thing C.Keyboard.invalidate accepts
--
-- Every condition is the server's: the page never filters or sorts a slice locally, because a
-- slice of 20 is not the population. Changing a condition resets to page 1 and asks again; the
-- page chips walk the pages the reply declared. A reply is only adopted when it echoes the very
-- question that is on screen, so an answer to a condition the admin has already moved off is
-- dropped instead of being read as this condition's result.
--
-- Rows and truncation are rebuilt when a reply lands and when the geometry changes -- never per
-- frame. No Events hook and no timer of its own: the controller calls tick(now) while this page
-- is up.
--
-- Engine references (snapshot 42.20.4-20260826):
--   setSelectedIndex does not fire onSelect (MinidoracatUI/VirtualList.lua:106-131), and Enter
--   over a list descriptor does (ECKeyboard.lua:521-526) -- so arrowing through the rows never
--   triggers a lookup, and Enter is the keyboard equal of the click.

require "ISUI/ISPanel"
require "MinidoracatEconomy/ECWidgets"

local EC = MinidoracatEconomy
local C = EC.Client
local U = C.UI

local P = {}
C.AdminAccounts = P

local PAD, T = U.PAD, U.T
local CARD_TITLE_H = U.CARD_TITLE_H
local fontH = U.fontH
local fill, text, textRight = U.fill, U.text, U.textRight
local textWidth, fitText = U.textWidth, U.fitText
local card, amountText = U.card, U.amountText
local Button = U.Button
local newEntry, entryText, setEntryEditable = U.newEntry, U.entryText, U.setEntryEditable
local errorText, currencyName = U.adminErrorText, U.currencyName

-- The server's own page size (ECAdmin.accounts): used for the "showing N-M of T" line only, never
-- to cut a reply -- the rows that arrived are the rows that are painted.
local PAGE_SIZE = 20
-- One read per pause in the search box, never one per key; the server throttles per command too.
local QUERY_DEBOUNCE_MS = 650
local QUERY_MAX = 64          -- ECAdmin's own bound for the query string

local STATUSES = { "all", "online", "offline", "frozen" }
local FIXED_SORTS = { "username", "online", "frozen" }

local function tr(key) return getText(T .. key) end
local function lineH() return fontH.small + 6 end
local function entryH() return math.max(26, fontH.small + 12) end
local function chipH() return math.max(24, fontH.small + 6) end

-- Every sort the server accepts: the three account properties, then one per registered currency.
-- Built per rebuild of the chip row, because the registry is what the session declares.
local function sortIds()
    local out = {}
    for _, id in ipairs(FIXED_SORTS) do out[#out + 1] = id end
    for _, id in ipairs(EC.CURRENCY_ORDER) do out[#out + 1] = id end
    return out
end

local function sortLabel(id)
    return getTextOrNull(T .. "Admin_Accounts_Sort_" .. id) or currencyName(id)
end

-- The box's text as the server is asked for it: trimmed and sent exactly as typed (the server
-- folds case for the match itself), refused when it carries a control character or runs past the
-- bound. Case only matters to answersCurrent, which compares the normalised form.
-- nil means "no condition"; `bad` tells an empty box and an unusable name apart, so a name that
-- cannot be asked for is reported instead of silently dropping the filter.
local function queryOf(box)
    local raw = string.match(entryText(box), "^%s*(.-)%s*$")
    if raw == "" then return nil, false end
    if #raw > QUERY_MAX or string.find(raw, "%c") then return nil, true end
    return raw, false
end

-- ---------- cells ----------

-- One account: the name over its state and per-currency holdings, the sorted currency's total
-- right aligned. Every string and x is computed once per rebuild (Page:accountRow), so the cell
-- only paints and a row never measures anything.
local AccountCell = ISPanel:derive("MinidoracatEconomyAccountCell")

function AccountCell:render()
    local e = self.entry
    if not e then return end
    local lit = U.rowBackground(self)
    text(self, e.nameText, PAD, e.line1Y, e.frozen and "warn" or "text")
    textRight(self, e.amountText, self.width - PAD, e.line1Y, "accent")
    text(self, e.stateText, PAD, e.line2Y, lit and "text" or "textMuted")
    if e.holdText then
        textRight(self, e.holdText, self.width - PAD, e.line2Y, lit and "text" or "textFaint")
    end
end

local Page = ISPanel:derive("MinidoracatEconomyAdminAccountsPage")

-- One chip row. The slot is budgeted, never natural: a long translation truncates its own label
-- instead of pushing a chip off the card.
local function chipRow(buttons, visible, x, y, width, height)
    local shown = 0
    for _, b in ipairs(buttons) do
        if b.wanted then shown = shown + 1 end
    end
    local cap = math.max(24, (width - math.max(0, shown - 1) * 6) / math.max(1, shown))
    for _, b in ipairs(buttons) do
        local want = visible and b.wanted == true
        b:setVisible(want)
        if want then
            b:setWidth(math.floor(math.min(textWidth(b.fullTitle) + 20, cap)))
            b:setHeight(height); b:setX(math.floor(x)); b:setY(y)
            U.setButtonTitle(b, b.fullTitle)
            x = x + b.width + 6
        end
    end
end

-- ----- controls -----

function Page:createChildren()
    local function chip(label, handler, internal)
        local b = Button.create(0, 0, textWidth(label) + 20, 22, label, self, handler, "chip")
        b.internal = internal
        self:addChild(b)
        return b
    end

    self.searchEntry = newEntry(240, entryH(), { maxLen = QUERY_MAX, clear = true,
        placeholder = tr("Admin_Accounts_Search") })
    self.searchEntry.target = self
    self.searchEntry.onTextChangeFunction = Page.onSearchTyped
    self.searchEntry.onCommandEntered = function() self:applyQuery() end
    self:addChild(self.searchEntry)

    self.statusButtons = {}
    for _, id in ipairs(STATUSES) do
        local b = chip(tr("Admin_Accounts_Status_" .. id), Page.onStatus, id)
        b.active = id == self.status
        self.statusButtons[#self.statusButtons + 1] = b
    end

    self.sortButtons = {}
    for _, id in ipairs(sortIds()) do
        local b = chip(sortLabel(id), Page.onSort, id)
        b.active = id == self.sort
        self.sortButtons[#self.sortButtons + 1] = b
    end
    self.descButton = chip(tr("Admin_Accounts_Desc"), Page.onDirection, "desc")

    self.prevButton = chip(tr("Market_Prev"), Page.onPage, -1)
    self.nextButton = chip(tr("Market_Next"), Page.onPage, 1)

    self.accountList = U.newTable(AccountCell, lineH() * 2 + 12)
    -- Picking a row is the jump into the operate mode. setSelectedIndex does not fire onSelect,
    -- so walking the rows with the arrows costs nothing; Enter and the click are the one path.
    self.accountList.onSelect = function(_, item)
        if item ~= nil then self.owner:openLookup(item.username) end
    end
    self:addChild(self.accountList)

    self:layout()
end

-- ----- actions -----

function Page:invalidateKeyboard()
    if C.Keyboard and C.Keyboard.invalidate then pcall(C.Keyboard.invalidate, self.owner.owner) end
end

-- What the page is asking for right now, as one string: the controller records it when a request
-- leaves, and the frame callback re-asks whenever the two differ (a cooldown refusal, a deferred
-- send, a condition the admin changed while an older read was still in flight).
function Page:askKey()
    return tostring(self.query or "") .. "\1" .. tostring(self.status) .. "\1"
        .. tostring(self.sort) .. "\1" .. tostring(self.descending) .. "\1" .. tostring(self.page)
end

function Page:requestArgs()
    local args = { status = self.status, sort = self.sort, descending = self.descending == true,
        page = self.page }
    if self.query ~= nil then args.query = self.query end
    return args
end

function Page:onSent(args)
    self.sentKey = self:askKey()
    self.sentQuery = args.query
    self.sentStatus, self.sentSort = args.status, args.sort
    self.sentDescending, self.sentPage = args.descending, args.page
end

function Page:request()
    self.owner:requestAccounts()
end

-- A condition moved: the page is a slice of a complete sort, so a new condition starts at its
-- first page instead of keeping an offset that meant something else.
function Page:conditionChanged()
    self.page = 1
    self.owner.message = nil
    self:request()
    self:layout()
end

function Page:onSearchTyped()
    self.queryAt = EC.now()
end

function Page:applyQuery()
    self.queryAt = nil
    local q, bad = queryOf(self.searchEntry)
    if bad then
        self.owner.message = { text = tr("Admin_Accounts_QueryBad"), error = true }
        return
    end
    self.querySeen = entryText(self.searchEntry)
    if q == self.query then return end
    self.query = q
    self:conditionChanged()
end

function Page:onStatus(button)
    if self.status == button.internal then return end
    self.status = button.internal
    for _, b in ipairs(self.statusButtons) do b.active = b.internal == self.status end
    self:conditionChanged()
end

function Page:onSort(button)
    if self.sort == button.internal then return end
    self.sort = button.internal
    for _, b in ipairs(self.sortButtons) do b.active = b.internal == self.sort end
    self:conditionChanged()
end

function Page:onDirection()
    self.descending = not (self.descending == true)
    self:conditionChanged()
end

function Page:onPage(button)
    local target = math.max(1, (self.page or 1) + button.internal)
    if target == self.page then return end
    -- the pages the reply declared are the only ones that exist; past the last one there is
    -- nothing to read, so the chip simply does nothing rather than asking for an empty page
    if target > math.max(1, self.pages or 1) then return end
    self.page = target
    self.owner.message = nil
    self:request()
    self:layout()
end

-- The list, pointed at one currency's holders and sorted by it: the entry the dashboard and the
-- currency page use. Only ever a condition change -- the read itself goes out the usual way.
function Page:showCurrency(currency)
    local wanted = tostring(currency)
    local known = false
    for _, id in ipairs(EC.CURRENCY_ORDER) do
        if id == wanted then known = true end
    end
    if not known then return end
    self.sort = wanted
    self.descending = true
    self.status = "all"
    self.query = nil
    U.setEntryText(self.searchEntry, "")
    self.querySeen = ""
    self.queryAt = nil
    for _, b in ipairs(self.statusButtons) do b.active = b.internal == self.status end
    for _, b in ipairs(self.sortButtons) do b.active = b.internal == self.sort end
    self.page = 1
    self:layout()
end

-- ----- overlay contract (this page holds no popup of its own) -----

function Page:isModal() return false end
function Page:onEscape() return false end

-- ----- keyboard targets (C.Keyboard walks these; this page owns no key dispatch) -----

function Page:keyboardTargets()
    local out = {}
    local function add(kind, label, control)
        out[#out + 1] = { kind = kind, label = label, control = control }
    end
    local function group(label, buttons)
        local shown = {}
        for _, b in ipairs(buttons) do
            if b ~= nil and b:getIsVisible() then shown[#shown + 1] = b end
        end
        if #shown > 0 then out[#out + 1] = { kind = "group", label = label, controls = shown } end
    end
    add("entry", tr("Admin_Accounts_Search"), self.searchEntry)
    group(tr("Admin_Accounts_Status"), self.statusButtons)
    local sorts = {}
    for _, b in ipairs(self.sortButtons) do sorts[#sorts + 1] = b end
    sorts[#sorts + 1] = self.descButton
    group(tr("Admin_Accounts_Sort"), sorts)
    group(tr("Filter_PageNav"), { self.prevButton, self.nextButton })
    -- The caption carries the slice and the measurement time in full: a keyboard user never sees
    -- the card's fitted line, so this is where those two facts have to survive whole.
    local caption = tr("Admin_Accounts_Title")
    local summary, fresh = self:summaryText(), self:freshnessText()
    if summary ~= nil then caption = caption .. "  " .. summary end
    if fresh ~= nil then caption = caption .. "  " .. fresh end
    add("list", caption, self.accountList)
    return out
end

-- ----- transport -----

-- A reply is adopted only when it echoes the question that is on screen: the query, the status,
-- the sort and the direction, all four. The page number is the server's to clamp, so that one is
-- taken from the reply instead of being compared -- and the recorded question moves with it, so a
-- clamped page is never re-asked in a loop.
--
-- The query is compared on its *normalised* form, because that is the only form both sides agree
-- on: the server matches account names case-insensitively and echoes the query folded to lower
-- case (ECStats), so comparing "Alice" against the echoed "alice" byte for byte would refuse
-- every answer to a query typed with a capital and the list would never fill. What the box holds
-- and what is sent stay exactly as typed -- only this comparison folds.
local function queryKey(value)
    return string.lower(tostring(value or ""))
end

function Page:answersCurrent(args)
    if queryKey(args.query) ~= queryKey(self.query) then return false end
    if tostring(args.status or "") ~= tostring(self.status) then return false end
    if tostring(args.sort or "") ~= tostring(self.sort) then return false end
    return (args.descending == true) == (self.descending == true)
end

function Page:onReply(args)
    if type(args) ~= "table" then return end
    if args.ok == false then
        local body = errorText(args.error)
        self.owner.message = { text = body, error = true }
        -- The right to read the whole population is what this page is: losing it must not leave
        -- every account's balances on screen. The refusal is recorded *after* the wipe, because
        -- clear() drops everything the page learned -- the read error included -- and a page that
        -- was just refused must say so instead of reading as one that is still loading.
        if args.error == "forbidden" then self:clear() end
        self.readError = body
        self:layout()
        return
    end
    if type(args.items) ~= "table" or not self:answersCurrent(args) then return end
    self.rows = args.items
    self.total = math.max(0, math.floor(tonumber(args.total) or 0))
    self.pages = math.max(1, math.floor(tonumber(args.pages) or 1))
    self.page = math.max(1, math.floor(tonumber(args.page) or 1))
    self.at = tonumber(args.at) or EC.now()
    self.snapshot = args
    self.readError = nil
    self.timedOut = false
    -- the server clamped the page: adopt it as the question we asked, never re-ask it
    self.sentKey = self:askKey()
    self.sentPage = self.page
    self:layout()
end

function Page:onTimeout(command)
    if command ~= "admin.accounts" then return end
    if self.rows == nil then self.timedOut = true end
    -- The question that was asked is remembered on purpose: a server that stopped answering must
    -- not be asked again on the very next frame. The 30 s page poll and the refresh chip are what
    -- try again, so a dead server is reported once instead of hammered.
    self:layout()
end

-- ----- rows (data or geometry changes only) -----

-- The state words of one account: online or offline, and frozen said out loud rather than being
-- left to a colour.
local function stateText(rec)
    local out = tr(rec.online == true and "Admin_Accounts_Online" or "Admin_Accounts_Offline")
    if rec.frozen == true then out = out .. "  " .. tr("Admin_Accounts_Frozen") end
    return out
end

-- Every currency's holdings on one line: "name total (available / reserved)".
--
-- Three cases, and they are not the same answer. An entry with three numbers is the truth, zeros
-- included: an account with no wallet row for a currency really holds nothing. `unknown = true`
-- is the server saying it could not read that one row (a missing field, a non-integer, a value
-- that is not a table) -- it is neither zero nor absent, and the server leaves such a row out of
-- every total it reports, so it is named as unreadable. A currency the reply does not carry at
-- all was simply not stated. None of the three may print a 0 the server did not state.
local function balanceBody(id, b)
    if type(b) ~= "table" then
        return getText(T .. "Admin_Accounts_RowMissing", currencyName(id))
    end
    if b.unknown == true then
        return getText(T .. "Admin_Accounts_RowUnknown", currencyName(id))
    end
    local total = tonumber(b.total)
    return getText(T .. "Admin_Accounts_Row", currencyName(id),
        total ~= nil and amountText(total) or "-",
        b.available ~= nil and amountText(tonumber(b.available) or 0) or "-",
        b.reserved ~= nil and amountText(tonumber(b.reserved) or 0) or "-")
end

local function holdText(balances)
    local out = nil
    for _, id in ipairs(EC.CURRENCY_ORDER) do
        local body = balanceBody(id, type(balances) == "table" and balances[id] or nil)
        out = out and (out .. "   " .. body) or body
    end
    return out
end

-- The figure the rows are lined up by: the total of the currency the sort names, or -- while the
-- sort is an account property -- the first registered currency's. Always labelled with the
-- currency, so the column is never read as a sum of two units. A row the server could not read
-- says so here too: the server sorts those last in both directions, and a column that showed
-- them as 0 would put them among the empty wallets instead.
function Page:amountFor(rec)
    local id = self.sort
    if id == "username" or id == "online" or id == "frozen" then id = EC.CURRENCY_ORDER[1] end
    local b = type(rec.balances) == "table" and rec.balances[id] or nil
    if type(b) == "table" and b.unknown == true then
        return getText(T .. "Admin_Accounts_RowUnknown", currencyName(id))
    end
    local total = type(b) == "table" and tonumber(b.total) or nil
    if total == nil then return getText(T .. "Admin_Accounts_RowMissing", currencyName(id)) end
    return amountText(total) .. " " .. currencyName(id)
end

function Page:rebuild()
    local rows = {}
    local width = math.max(80, self.accountList.width)
    local rowHeight = self.accountList.rowHeight or (lineH() * 2 + 12)
    local line1Y = math.floor((rowHeight - lineH() * 2) / 2)
    local line2Y = line1Y + lineH()
    for _, rec in ipairs(self.rows or {}) do
        if type(rec) == "table" and type(rec.username) == "string" and rec.username ~= "" then
            local amount = self:amountFor(rec)
            local state = stateText(rec)
            local hold = holdText(rec.balances)
            local holdW = hold and textWidth(hold) or 0
            local stateW = textWidth(state)
            -- the holdings share the second line with the state words: whichever does not fit is
            -- the one that is cut, and the state words are never the ones dropped
            local room = math.max(0, width - PAD * 2 - stateW - PAD)
            rows[#rows + 1] = {
                id = rec.username,
                username = rec.username,
                online = rec.online == true,
                frozen = rec.frozen == true,
                balances = rec.balances,
                amountText = amount,
                nameText = fitText(rec.username, math.max(20, width - PAD * 2 - textWidth(amount) - PAD)),
                stateText = state,
                holdText = (hold ~= nil and room > 20) and fitText(hold, math.min(holdW, room)) or nil,
                line1Y = line1Y,
                line2Y = line2Y,
            }
        end
    end
    self.rowItems = rows
    self.accountList:setItems(rows)
end

-- ----- what the page is showing, as exactly one state -----

function Page:listStatus()
    if self.readError then return "failed" end
    if self.timedOut then return "timeout" end
    if self.rows == nil then
        return self.isPending("admin.accounts") and "loading" or "idle"
    end
    if #(self.rowItems or {}) == 0 then return "empty" end
    return "rows"
end

function Page:statusText(state)
    if state == "loading" or state == "idle" then return tr("Admin_Accounts_Loading") end
    if state == "failed" then return self.readError end
    if state == "timeout" then return tr("Admin_Accounts_Timeout") end
    if state == "empty" then return tr("Admin_Accounts_Empty") end
    return nil
end

-- "21-40 of 137, page 2/7": which slice of the complete sort is on screen. The numbers are the
-- reply's own, so nothing here claims a population the server did not state.
--
-- The measurement time is deliberately NOT on this line. At the minimum window with a large UI
-- font the two together are wider than the room left beside the page chips, and fitText cut the
-- stamp down to "Updated 2026..." -- a timestamp that has lost its time. The slice numbers are
-- what this line exists for, so they keep the line to themselves, and the full stamp is carried
-- where it can be read whole: the freshness line in the tab strip, the refresh chip's tooltip
-- and the list's own keyboard caption.
function Page:summaryText()
    if self.rows == nil then return nil end
    local shown = #(self.rowItems or {})
    local first = shown > 0 and ((self.page - 1) * PAGE_SIZE + 1) or 0
    local last = shown > 0 and (first + shown - 1) or 0
    return getText(T .. "Admin_Accounts_Summary", tostring(first), tostring(last),
        tostring(self.total or 0), tostring(self.page or 1), tostring(self.pages or 1))
end

-- When the figures on screen were measured, in full and never fitted. nil before the first reply.
function Page:freshnessText()
    if self.at == nil then return nil end
    return getText(T .. "Admin_Updated", U.stampText(self.at, self.owner.offsetMin))
end

-- ----- enabling -----

function Page:updateEnabled()
    local read = self.owner:readAllowed()
    local modal = self.owner.dialog ~= nil
    local live = read and not modal
    local busy = self.isPending("admin.accounts")
    setEntryEditable(self.searchEntry, live)
    for _, b in ipairs(self.statusButtons) do b:setEnable(live and not busy) end
    for _, b in ipairs(self.sortButtons) do b:setEnable(live and not busy) end
    self.descButton:setEnable(live and not busy)
    U.setButtonTitle(self.descButton,
        tr(self.descending == true and "Admin_Accounts_Desc" or "Admin_Accounts_Asc"))
    local pages = math.max(1, self.pages or 1)
    self.prevButton:setEnable(live and not busy and (self.page or 1) > 1)
    self.nextButton:setEnable(live and not busy and (self.page or 1) < pages)
    -- there is no write on this page at all: the rows are a read and the jump into the operate
    -- mode is a read as well, so a read-only role uses every control here
    self.accountList.optionsDisabled = not live
end

-- ----- geometry -----

function Page:layout()
    local w, h = self.width, self.height
    local lh, eh, ch = lineH(), entryH(), chipH()
    local g = {}
    self.g = g
    local on = self:getIsVisible()
    local listW = math.max(160, w - PAD * 2)

    -- row A: the search box, and what it searches said in words beside it
    local top = CARD_TITLE_H + 4
    if not on and self.searchEntry:isFocused() then self.searchEntry:unfocus() end
    self.searchEntry:setVisible(on)
    self.searchEntry:setX(PAD); self.searchEntry:setY(top)
    self.searchEntry:setWidth(math.max(120, math.min(280, math.floor(w * 0.3))))
    self.searchEntry:setHeight(eh)
    g.scopeX = PAD + self.searchEntry.width + PAD
    g.scopeY = top + math.floor((eh - fontH.small) / 2)
    g.scopeW = math.max(0, w - PAD - g.scopeX)

    -- row B: the status filter
    local statusY = top + eh + 4
    g.statusLabelX = PAD
    g.statusLabelY = statusY + math.floor((ch - fontH.small) / 2)
    local statusLabelW = textWidth(tr("Admin_Accounts_Status")) + 6
    for _, b in ipairs(self.statusButtons) do b.wanted = on end
    chipRow(self.statusButtons, on, PAD + statusLabelW, statusY,
        math.max(60, listW - statusLabelW), ch)

    -- row C: the sort, and the direction chip after it
    local sortY = statusY + ch + 4
    g.sortLabelX = PAD
    g.sortLabelY = sortY + math.floor((ch - fontH.small) / 2)
    local sortLabelW = textWidth(tr("Admin_Accounts_Sort")) + 6
    local sortChips = {}
    for _, b in ipairs(self.sortButtons) do
        b.wanted = on
        sortChips[#sortChips + 1] = b
    end
    self.descButton.wanted = on
    sortChips[#sortChips + 1] = self.descButton
    chipRow(sortChips, on, PAD + sortLabelW, sortY, math.max(60, listW - sortLabelW), ch)

    -- row D: the slice on screen, and the page chips on the same line
    local summaryY = sortY + ch + 6
    g.summaryY = summaryY + math.floor((ch - fontH.small) / 2)
    local nextW = math.min(textWidth(self.nextButton.fullTitle) + 24, math.floor(w * 0.2))
    local prevW = math.min(textWidth(self.prevButton.fullTitle) + 24, math.floor(w * 0.2))
    self.nextButton:setVisible(on)
    self.nextButton:setWidth(nextW); self.nextButton:setHeight(ch)
    self.nextButton:setX(math.max(PAD, w - PAD - nextW)); self.nextButton:setY(summaryY)
    U.setButtonTitle(self.nextButton, self.nextButton.fullTitle)
    self.prevButton:setVisible(on)
    self.prevButton:setWidth(prevW); self.prevButton:setHeight(ch)
    self.prevButton:setX(math.max(PAD, self.nextButton.x - 6 - prevW)); self.prevButton:setY(summaryY)
    U.setButtonTitle(self.prevButton, self.prevButton.fullTitle)
    g.summaryW = math.max(0, self.prevButton.x - PAD * 2)

    local listY = summaryY + ch + 4
    g.emptyY = listY + 4
    local listH = math.max(lh, h - PAD - listY)
    U.placeList(self.accountList, on, PAD, listY, listW, listH)

    self:rebuild()
    self:updateEnabled()
end

function Page:resize(width, height)
    if self.width ~= width then self:setWidth(width) end
    if self.height ~= height then self:setHeight(height) end
    self:layout()
end

-- Hiding the page takes its controls off the keyboard's list and off the screen. Everything it
-- holds is kept on purpose: the operate mode is one click away and coming back must find the very
-- slice the admin left.
function Page:setVisible(visible)
    local was = self:getIsVisible()
    ISPanel.setVisible(self, visible)
    -- P.create hides the page before the owner has added it, and a derived panel can be hidden
    -- before instantiate built the controls: the guard is what the whitelist page uses too
    if self.accountList == nil then return end
    if not visible then pcall(self.searchEntry.unfocus, self.searchEntry) end
    if was ~= visible then self:layout() end
end

-- ----- drawing -----

function Page:prerender()
    local g = self.g
    card(self, 0, 0, self.width, self.height, tr("Admin_Accounts_Title"))
    text(self, fitText(tr("Admin_Accounts_Scope"), g.scopeW), g.scopeX, g.scopeY, "textFaint")
    text(self, tr("Admin_Accounts_Status"), g.statusLabelX, g.statusLabelY, "textMuted")
    text(self, tr("Admin_Accounts_Sort"), g.sortLabelX, g.sortLabelY, "textMuted")
    local summary = self:summaryText()
    if summary then
        text(self, fitText(summary, g.summaryW), PAD, g.summaryY, "textFaint")
    end
    local state = self:listStatus()
    local empty = self:statusText(state)
    if empty then
        text(self, fitText(empty, math.max(0, self.width - PAD * 2)), PAD, g.emptyY,
            (state == "failed" or state == "timeout") and "errorText" or "textFaint")
    end
end

function Page:render() end

-- ----- lifecycle -----

function Page:refresh()
    self:request()
end

-- The controller's frame callback is this page's whole clock: the search box's pause, and the
-- read a cooldown (or an older answer) held back.
function Page:tick(now)
    if entryText(self.searchEntry) ~= self.querySeen and self.queryAt == nil then
        self.queryAt = now
    end
    if self.queryAt ~= nil and now - self.queryAt > QUERY_DEBOUNCE_MS then
        self:applyQuery()
        return
    end
    -- The read a condition change asked for while the cooldown (or an older answer) still held
    -- the command. The in-flight check is what keeps this to one request instead of one per
    -- frame; a read that came back refused is *not* re-asked, because the question it answered
    -- was recorded when it left.
    if self.queryAt == nil and not self.isPending("admin.accounts")
        and self.sentKey ~= self:askKey() then
        self:request()
    end
end

-- The permission collapse: every account this page read is dropped and it reads as one that was
-- never opened. No command is sent.
function Page:clear()
    self.rows = nil
    self.rowItems = nil
    self.snapshot = nil
    self.total, self.pages, self.at = nil, nil, nil
    self.page = 1
    self.sentKey = nil
    self.readError = nil
    self.timedOut = false
    -- setItems drops a selection that points past the new list (VirtualList.lua:82-84)
    self.accountList:setItems({})
end

function Page:dispose()
    self:clear()
    pcall(self.searchEntry.unfocus, self.searchEntry)
end

-- ---------- module API ----------

-- owner: the admin controller. Returns an initialised child that the owner adds, positions and
-- resizes. No command is sent, and isPending is the owner's own plain function.
function P.create(owner, isPending)
    local o = ISPanel:new(0, 0, 600, 300)
    setmetatable(o, Page)
    o.background = false
    o.owner = owner
    o.isPending = isPending
    o.status = "all"
    o.sort = "username"
    o.descending = false
    o.page = 1
    o.querySeen = ""
    o:initialise()
    o:instantiate()   -- builds the children now; the owner only has to addChild/resize
    o:setVisible(false)
    return o
end

return P
