-- MinidoracatEconomyFor42 -- admin money flow page (client). Adds exactly one namespace:
-- C.AdminTransactions.
--
--   C.AdminTransactions.create(owner, send, isPending, newRequestId)
--       an initialised ISPanel child, NOT added (the admin controller addChild's it) and never
--       sends a command. The three transport functions are the controller's own: they are plain
--       functions, always called as self.send(...) / self.isPending(...) / self.newRequestId(),
--       never with ":".
--
-- The controller owns the window chrome, the sub tab bar, the footer and the opaque backdrop the
-- money views are read against; it positions this child at x = 0, y = bodyY, (width, bodyH) and
-- keeps it visible exactly while the Transactions tab is open and reading is allowed. Everything
-- from the card frame down belongs to this file: the search box, the currency chips, the account
-- class combo, the shared filter row, the list of committed transactions (admin.transactions) and
-- one transaction's whole record (admin.transaction).
--
-- Geometry is page relative: the card starts at y = 0 and ends at self.height. Nothing here reads
-- the controller's own g.
--
-- What the page borrows from the controller (and nothing else):
--   owner:readAllowed()   the permission gate both sides collapse on
--   owner.dialog          the modal flag (a write dialog owns the panel while it is open)
--   owner.message         the shared footer line
--   owner.offsetMin       the window's timezone offset, mirrored onto the page for the calendar
--   owner.owner           the root window, the only thing C.Keyboard.invalidate accepts
--
-- Painting rules are the controller's: rows, wrapped text and truncation are rebuilt when data
-- arrives, when the filter changes or when the geometry changes -- never per frame. The page owns
-- no Events hook and no timer of its own: the controller calls tick(now) while this page is the
-- one on screen.

require "ISUI/ISPanel"
require "ISUI/ISComboBox"
require "MinidoracatEconomy/ECWidgets"
require "MinidoracatEconomy/ECAdminFilters"
require "MinidoracatEconomy/ECDatePicker"

local EC = MinidoracatEconomy
local C = EC.Client
local U = C.UI
local F = C.AdminFilters
local DatePicker = C.DatePicker

local P = {}
C.AdminTransactions = P

local PAD, T = U.PAD, U.T
local CARD_TITLE_H = U.CARD_TITLE_H
local fontH = U.fontH
local fill, text, textWidth, fitText, textRight = U.fill, U.text, U.textWidth, U.fitText, U.textRight
local stampText, amountText, signedText, card = U.stampText, U.amountText, U.signedText, U.card
local accountName, reasonText = U.accountName, U.reasonText
local Button = U.Button
local newEntry, entryText, setEntryText, setEntryEditable = U.newEntry, U.entryText, U.setEntryText, U.setEntryEditable
local errorText, currencyName, itemName = U.adminErrorText, U.currencyName, U.itemName

-- The sources the server sorts every committed transaction into: a fixed enumeration, never what
-- a reply happened to carry, so a search that matched nothing still offers every other source to
-- switch to. "all" is the filter row's own first chip.
local TX_GROUPS = { "shop_buy", "shop_sell", "market", "auction", "rewards", "admin", "mod", "exchange", "other" }
local TX_RANGE_MAX_MS = 62 * 86400000   -- the span one read may cover; the server enforces the same
local TX_DEBOUNCE_MS = 650              -- typing (a word or a day) costs one command per pause

-- the ids a payload may name; anything else it holds stays out of the panel
local TX_REF_KEYS = { "auctionId", "listingId", "orderId" }

local function tr(key) return getText(T .. key) end
local function lineH() return fontH.small + 6 end
local function rowH() return math.max(26, fontH.small + 12) end
local function entryH() return math.max(26, fontH.small + 12) end

local function txGroupText(group)
    return getTextOrNull(T .. "Admin_Tx_Group_" .. tostring(group)) or tostring(group)
end

-- "120 倖存幣  3 貓幣": every currency on its own line of the same string, never a sum. The
-- figures are what the postings moved -- a hold turning into a payment moves twice, and two
-- currencies share no unit -- so this is an amount changed, not revenue and not a net (the
-- postings of one transaction always add up to nothing). This server's currencies first and
-- whatever else the reply carried after them, so the order never jumps between rows.
local function txAmountText(amounts)
    if type(amounts) ~= "table" then return "-" end
    local out, seen = nil, {}
    for _, id in ipairs(EC.CURRENCY_ORDER) do
        seen[id] = true
        local n = tonumber(amounts[id])
        if n then out = (out and (out .. "  ") or "") .. amountText(n) .. " " .. currencyName(id) end
    end
    local rest = {}
    for id in pairs(amounts) do
        if not seen[id] and tonumber(amounts[id]) then rest[#rest + 1] = tostring(id) end
    end
    EC.sortSafe(rest, function(a, b) return a < b end)
    for _, id in ipairs(rest) do
        out = (out and (out .. "  ") or "") .. amountText(tonumber(amounts[id])) .. " " .. currencyName(id)
    end
    return out or "-"
end

-- "100 -> 80" for one bucket of one account. A bound the event never carried reads "-": a
-- printed 0 would claim the wallet was empty.
local function beforeAfterText(before, after)
    local a, b = tonumber(before), tonumber(after)
    return getText(T .. "Admin_Tx_BeforeAfter", a and amountText(a) or "-", b and amountText(b) or "-")
end

-- Cut `s` into lines of at most `w`, on codepoint boundaries: fitText appends "..." when it had
-- to cut, and its head is exactly where the next line starts (the audit detail strip splits its
-- reason the same way). `maxLines` is the hard stop, so a pathological string cannot build an
-- unbounded row list.
local function wrapText(s, w, maxLines)
    local out, rest = {}, tostring(s or "")
    while rest ~= "" and #out < maxLines do
        local cut = fitText(rest, w)
        if cut == rest or string.sub(cut, -3) ~= "..." then
            out[#out + 1] = rest
            rest = ""
        else
            local n = #cut - 3
            if n <= 0 then
                out[#out + 1] = cut   -- not even one character fits: stop rather than loop
                rest = ""
            else
                out[#out + 1] = string.sub(rest, 1, n)
                rest = string.sub(rest, n + 1)
            end
        end
    end
    return out
end

local function setWrappedText(box, value, width)
    value = tostring(value or "")
    width = math.max(80, width - 20)
    if box.ecRawText == value and box.ecWrapWidth == width then return end
    local changed = box.ecRawText ~= value
    local lines = {}
    for line in (string.gsub(value, "\r\n", "\n") .. "\n"):gmatch("(.-)\n") do
        if line == "" then lines[#lines + 1] = ""
        else
            for _, part in ipairs(wrapText(line, width, math.huge)) do lines[#lines + 1] = part end
        end
    end
    box.ecRawText, box.ecWrapWidth = value, width
    setEntryText(box, table.concat(lines, "\n"))
    if changed then box:setYScroll(0) end
end

-- The initiating integration or actor, otherwise a related internal account. This is an
-- origin label, not a claim about the direction or sign of a posting.
local function txSourceName(d)
    if d.kind == "exchange_deposit" then return U.accountClassName("discord") end
    if type(d.sourceMod) == "string" and d.sourceMod ~= "" then
        return accountName("MOD:" .. d.sourceMod)
    end
    if type(d.actor) == "string" and d.actor ~= "" then return d.actor end
    for _, account in ipairs(type(d.accounts) == "table" and d.accounts or {}) do
        local cls = EC.accountClass(account)
        if cls ~= nil and cls ~= "player" then return accountName(account) end
    end
    return "-"
end

-- One posting as its own lines: who moved, in which bucket, how much, and both balance chains.
-- Money that only changed bucket still shows the amount that moved; the pairs say which side it
-- left and which side it landed on.
local function txPostingLines(out, index, p)
    out[#out + 1] = getText(T .. "Admin_Tx_Field_Posting", tostring(index),
        accountName(p.account, true))
    local amount = tonumber(p.amount)
    local label = amount and signedText(amount) or "-"
    if amount and type(p.currency) == "string" and p.currency ~= "" then
        label = label .. " " .. currencyName(p.currency)
    end
    out[#out + 1] = "  " .. getText(T .. "Admin_Tx_Pair", tr("Admin_Tx_Amount"), label)
    out[#out + 1] = "  " .. getText(T .. "Admin_Tx_Pair", tr("Admin_Tx_Field_Bucket"),
        tr(p.bucket == "reserved" and "Admin_Tx_Reserved" or "Admin_Tx_Available"))
    out[#out + 1] = "  " .. getText(T .. "Admin_Tx_Pair", tr("Admin_Tx_Available"),
        beforeAfterText(p.availableBefore, p.availableAfter))
    out[#out + 1] = "  " .. getText(T .. "Admin_Tx_Pair", tr("Admin_Tx_Reserved"),
        beforeAfterText(p.reservedBefore, p.reservedAfter))
end

-- One chip row of the card. The slot is budgeted, never natural: a long translation truncates
-- its own label instead of pushing a chip out of the card. `skip` is the chip this size of card
-- does not offer at all.
local function txButtonRow(buttons, visible, x, y, width, height, skip)
    local count = #buttons - (skip and 1 or 0)
    local cap = math.max(24, (width - math.max(0, count - 1) * 6) / math.max(1, count))
    for _, button in ipairs(buttons) do
        button:setVisible(visible and button ~= skip)
        if button ~= skip then
            local bw = math.min(textWidth(button.fullTitle) + 20, cap)
            button:setX(x); button:setY(y); button:setWidth(bw); button:setHeight(height)
            U.setButtonTitle(button, button.fullTitle)
            x = x + bw + 6
        end
    end
    return x
end

-- The shared admin history row plus the selection band: the transaction list is picked from
-- (picking a row opens that transaction's own view), the history lists are not.
local AdminHistoryCell = U.AdminHistoryCell
local TxCell = AdminHistoryCell:derive("MinidoracatEconomyTxCell")

function TxCell:render()
    if self.list:isSelected(self.index) then fill(self, 0, 0, self.width, self.height, "selected", "rect") end
    AdminHistoryCell.render(self)
end

local Page = ISPanel:derive("MinidoracatEconomyAdminTxPage")

-- ----- controls -----

-- The search box and the currency chips on one row, the fixed source chips on the next and the
-- shared date / sort / page row under them, over one read-only list of committed transactions.
-- Picking a row opens the postings band, a second read on its own command so the two can never
-- overwrite each other's answer.
function Page:createChildren()
    self.txEntry = newEntry(240, entryH(), { maxLen = 64, clear = true, placeholder = tr("Admin_Tx_Search") })
    self.txEntry.target = self
    self.txEntry.onTextChangeFunction = Page.onTxSearch
    self:addChild(self.txEntry)
    self.txCurButtons = {}
    local txCurKeys = { "all" }
    for _, id in ipairs(EC.CURRENCY_ORDER) do txCurKeys[#txCurKeys + 1] = id end
    for _, id in ipairs(txCurKeys) do
        local title = id == "all" and tr("Filter_All") or currencyName(id)
        local b = Button.create(0, 0, textWidth(title) + 20, 22, title, self, Page.onTxCurrency, "chip")
        b.internal = id
        b.active = id == "all"
        self:addChild(b)
        self.txCurButtons[#self.txCurButtons + 1] = b
    end
    local accountCombo = ISComboBox:new(0, 0, 110, entryH(), self, Page.onTxAccountClass)
    accountCombo:initialise()
    accountCombo:instantiate()
    accountCombo.backgroundColor = U.color("well")
    accountCombo.borderColor = U.color("border")
    accountCombo.textColor = U.color("text")
    accountCombo.backgroundColorMouseOver = U.color("hover")
    accountCombo:addOptionWithData(U.accountClassName("all"), "all", tr("Admin_Tx_ClassHint"))
    for _, class in ipairs(EC.ACCOUNT_CLASSES) do
        accountCombo:addOptionWithData(U.accountClassName(class), class, tr("Admin_Tx_ClassHint"))
    end
    accountCombo:setWidthToOptions(110)
    self.txAccountCombo = accountCombo
    self:addChild(accountCombo)
    self.txF = F.create(self, {
        label = txGroupText,
        kindLabel = tr("Admin_Tx_Group"),
        sorts = { "time" }, fields = { time = "ord" },
        fromLabel = tr("Filter_From"), toLabel = tr("Filter_To"),
        onChange = function(panel) panel:onTxFilterChanged() end,
    })
    self.txF.accountCombo = accountCombo
    self.txF.accountLabel = tr("Admin_Tx_AccountClass")
    self.txF.accountW = accountCombo.width
    -- the source chips are an enumeration, not whatever a reply happened to carry: a search that
    -- matched nothing still offers every other source to switch to
    F.kinds(self.txF, TX_GROUPS)
    self.txKindSig = self.txF.kind
    self.txDateSig = entryText(self.txF.fromEntry) .. "\1" .. entryText(self.txF.toEntry)
    self.txList = U.newTable(TxCell, lineH() * 2 + 12)
    self.txList.onSelect = function(_, item)
        self:onTxRow(item)
    end
    self:addChild(self.txList)
    -- the list view's own chips: clear every server-side filter, ask a refused or timed-out read
    -- again
    local function chip(label, handler, internal)
        local b = Button.create(0, 0, textWidth(label) + 20, 22, label, self, handler, "chip")
        b.internal = internal
        self:addChild(b)
        return b
    end
    self.txClearButton = chip(tr("Admin_Tx_Clear"), Page.onTxClear, "clear")
    self.txRetryButton = chip(tr("Admin_Tx_Retry"), Page.onTxRetry, "retry")
    self.txFilterButton = chip(tr("Admin_Tx_Filters"), Page.onTxFilters, "filters")
    self.txActionButtons = { self.txFilterButton, self.txClearButton, self.txRetryButton }

    -- Native read-only viewers stay non-selectable: selection would trap the keyboard.
    for _, name in ipairs({ "txDetailBox", "txNotesBox" }) do
        local box = newEntry(240, lineH() * 4, { multiline = true })
        box.target = self
        local bg, fg = U.color("well"), U.color("text")
        box.backgroundColor = { r = bg.r, g = bg.g, b = bg.b, a = 1 }
        setEntryEditable(box, false)
        box:setSelectable(false)
        box:setTextRGBA(fg.r, fg.g, fg.b, fg.a)
        self[name] = box
        self:addChild(box)
        box:addScrollBars()
    end
    self.txBackButton = chip(tr("Admin_Tx_Back"), Page.onTxBack, "back")
    self.txCopyButton = chip(tr("Admin_Tx_Copy"), Page.onTxCopy, "copyId")
    self.txCopyFullButton = chip(tr("Admin_Tx_CopyFull"), Page.onTxCopyFull, "copyFull")
    self.txDetailRetryButton = chip(tr("Admin_Tx_DetailRetry"), Page.onTxDetailRetry, "retry")
    self.txDetailButtons = { self.txBackButton, self.txCopyButton, self.txCopyFullButton,
        self.txDetailRetryButton }

    self:layout()
end

-- ----- actions (every one of them a read) -----

-- The civil days the two boxes hold, as the range the server will read: "to" means the end of
-- that day, so the exclusive bound is the next midnight. A malformed box is simply not a bound
-- (its placeholder says what it wants).
function Page:txRange()
    local f = self.txF
    local to = EC.parseDay(entryText(f.toEntry), self.offsetMin)
    return EC.parseDay(entryText(f.fromEntry), self.offsetMin), to and (to + 86400000) or nil
end

-- The same span check the server runs, so a typo never costs a round trip: at most 62 days, and
-- the end after the start. A one-sided pair is completed the way the server completes it -- a
-- missing end is tomorrow, a missing start is 62 days before the end.
function Page:txRangeError(from, to)
    local f = self.txF
    if (string.find(entryText(f.fromEntry), "%S") and from == nil)
        or (string.find(entryText(f.toEntry), "%S") and to == nil) then return true end
    if from == nil and to == nil then return false end
    local stop = to or (math.floor(EC.now() / 86400000) * 86400000 + 86400000)
    local start = from or math.max(0, stop - TX_RANGE_MAX_MS)
    return stop <= start or stop - start > TX_RANGE_MAX_MS
end

-- One read per search / source / currency / day change. The sent state is cleared when the
-- request leaves -- never when the answer lands -- so a server that refuses is reported once
-- instead of asked again in a loop; the 30 s poll and the refresh chip are what retry.
function Page:requestTransactions()
    local from, to = self:txRange()
    if self:txRangeError(from, to) then
        -- A refused range counts as asked for: the same bad pair must not go out every frame.
        -- It is also recorded as the list's state, so the rows are never left reading "loading"
        -- for a request that was never sent.
        self.txDirty = false
        self.txAsked = true
        self.txListError = "invalid_range"
        self.txListTimeout = false
        self.owner.message = { text = tr("Admin_Tx_InvalidRange"), error = true }
        self:rebuildTxNotes()
        self:updateEnabled()
        return false
    end
    local sig = self:txFilterSig()
    local args = { requestId = self.newRequestId() }
    if self.txQuery then args.query = self.txQuery end
    if self.txF.kind ~= "all" then args.group = self.txF.kind end
    if self.txCurrency then args.currency = self.txCurrency end
    if self.txAccountClass then args.accountClass = self.txAccountClass end
    if from then args.fromMs = from end
    if to then args.toMs = to end
    if not self.send("admin.transactions", args) then return false end
    self.txRequestId = args.requestId
    -- the conditions this read is asking about: a reply stamps them onto the snapshot, so the
    -- rows on screen always know which question they answered
    self.txReqSig = sig
    self.txAsked = true
    self.txDirty = false
    -- a read that is on its way is not a read that failed: the previous refusal stops being the
    -- state as soon as a new request leaves
    self.txListError = nil
    self.txListTimeout = false
    self:rebuildTxNotes()
    self:updateEnabled()
    return true
end

-- The postings of one transaction, over the very range the list reply named: both sides read
-- the same day files, so a row that is on screen can always be opened. Its own command and its
-- own requestId keep it clear of the list read.
function Page:requestTxDetail(txId)
    local args = { txId = txId, requestId = self.newRequestId() }
    if self.txFromMs then args.fromMs = self.txFromMs end
    if self.txToMs then args.toMs = self.txToMs end
    if not self.send("admin.transaction", args) then
        self.txDetailRetry = txId   -- held by the cooldown: the controller's tick asks again
        return false
    end
    self.txDetailRequestId = args.requestId
    self.txDetailRetry = nil
    self.txDetailError = nil
    self.txDetailTimeout = false
    self.txDetailAnswered = false
    self:rebuildTxNotes()
    self:updateEnabled()
    return true
end

-- A keystroke only arms the clock tick() owns: one command per pause in the typing, never one
-- per key, and only ever the last text.
function Page:onTxSearch()
    local raw = string.match(entryText(self.txEntry), "^%s*(.-)%s*$")
    local query = raw ~= "" and raw or nil
    if query == self.txQuery then return end
    self.txQuery = query
    self.txF.page = 1
    self.txDirty = true
    self.txQueryAt = EC.now()
    self:rebuildTxNotes()
end

-- Every chip, date box and page click on the shared filter row lands here. The source and the
-- days are the server's own filter and have to be asked for again; the sort and the page belong
-- to this side, so they only rebuild.
function Page:onTxFilterChanged()
    local f = self.txF
    local dates = entryText(f.fromEntry) .. "\1" .. entryText(f.toEntry)
    if f.kind ~= self.txKindSig then
        self.txKindSig = f.kind
        self.txDateSig = dates
        f.page = 1
        self.txDirty = true
        self.txQueryAt = nil   -- a chip is one click, not typing: it goes out on the next frame
    elseif dates ~= self.txDateSig then
        self.txDateSig = dates
        f.page = 1
        self.txDirty = true
        self.txQueryAt = EC.now()   -- a day is typed: coalesced exactly like the search box
    end
    self:rebuildTransactions()
    self:rebuildTxNotes()
end

function Page:onTxCurrency(button)
    local id = button.internal ~= "all" and button.internal or nil
    if id == self.txCurrency then return end
    self.txCurrency = id
    for _, b in ipairs(self.txCurButtons) do b.active = b.internal == (id or "all") end
    self.txF.page = 1
    self.txDirty = true
    self.txQueryAt = nil
    self:updateEnabled()
    self:rebuildTxNotes()
end

function Page:onTxAccountClass(combo)
    local class = combo:getOptionData(combo.selected)
    if class == "all" then class = nil end
    if class == self.txAccountClass then return end
    self.txAccountClass = class
    self.txF.page = 1
    self.txDirty = true
    self.txQueryAt = nil
    self:updateEnabled()
    self:rebuildTxNotes()
end

-- Switching view re-lays the card out (each view owns the whole card) and drops the keyboard
-- out of every text field the leaving view owned. A box that keeps Core.currentTextEntryBox
-- after its view is hidden would swallow every key the root keyboard needs, so the search box
-- and both date boxes are unfocused explicitly, not just hidden.
function Page:setTxView(view)
    if self.txView == view then return end
    self.txView = view
    self.txFiltersOpen = false
    DatePicker.close(self)
    F.closeCombo(self.txAccountCombo)
    pcall(function() self.txEntry:unfocus() end)
    pcall(function() self.txF.fromEntry:unfocus() end)
    pcall(function() self.txF.toEntry:unfocus() end)
    pcall(function() self.txDetailBox:unfocus() end)
    self.owner.message = nil
    self:layout()
    -- keyboardTargets() answers with a different set now, and some of the old set is hidden: the
    -- keyboard owns the focus ring, so it is told to drop what it was holding. This file never
    -- dispatches a key itself, and the controls are built once (createChildren), never rebuilt
    -- per view, so nothing else here can leave the keyboard pointing at a dead widget.
    if C.Keyboard and C.Keyboard.invalidate then pcall(C.Keyboard.invalidate, self.owner.owner) end
end

function Page:onTxFilters()
    DatePicker.close(self)
    F.closeCombo(self.txAccountCombo)
    self.txEntry:unfocus()
    self.txF.fromEntry:unfocus()
    self.txF.toEntry:unfocus()
    self.txFiltersOpen = not self.txFiltersOpen
    self:layout()
    if C.Keyboard then C.Keyboard.invalidate(self.owner.owner) end
end

-- A click in the list opens that transaction's own view. The pick is held by tx id, so a page
-- turn or a fresh read still points at the transaction being described.
function Page:onTxRow(item)
    if item == nil or item.txId == nil or item.txId == "" then return end
    if self.txDetailTx ~= item.txId then
        self.txDetailTx = item.txId
        self.txDetail = nil
        self.txDetailText = nil
        self.txDetailError = nil
        self.txDetailTimeout = false
        self.txDetailAnswered = false
        self:requestTxDetail(item.txId)
    end
    self:setTxView("detail")
end

function Page:clearTxDetail()
    self.txDetailTx = nil
    self.txDetail = nil
    self.txDetailText = nil
    self.txDetailError = nil
    self.txDetailTimeout = false
    self.txDetailAnswered = false
    self.txDetailRetry = nil
    self.txList:setSelectedIndex(nil)
end

-- Back is always reachable, at every card size: it is a chip of its own on the detail view's
-- own row, never a corner of a band that a short card can decide not to draw.
function Page:onTxBack()
    self:clearTxDetail()
    self:setTxView("list")
end

-- Ask the list read again. The failure flags are cleared by the send itself, so a refusal that
-- is still on screen cannot outlive the request that replaces it.
function Page:onTxRetry()
    self.owner.message = nil
    self.txDirty = true
    self.txQueryAt = nil
    if not self:requestTransactions() then self:rebuildTxNotes() end
    self:layout()
end

function Page:onTxDetailRetry()
    local txId = self.txDetailTx
    if txId == nil then return end
    self.owner.message = nil
    self.txDetail = nil
    self.txDetailText = nil
    if not self:requestTxDetail(txId) then self.txDetailRetry = txId end
    self:layout()
end

-- Every filter the server reads with, back to its default, as one request: the query, the
-- source, the currency, the account class and both days. The sort and the page belong to this
-- side and are reset with them, so the list reads exactly like a page that was just opened.
function Page:onTxClear()
    local f = self.txF
    f.kind = "all"
    f.page = 1
    -- one sortable column on this page, so the direction is the whole of the sort: back to
    -- "newest first", the state a freshly opened page has
    f.desc = true
    for _, b in ipairs(f.kindButtons) do b.active = (not b.unused) and b.internal == "all" end
    setEntryText(self.txEntry, "")
    setEntryText(f.fromEntry, "")
    setEntryText(f.toEntry, "")
    DatePicker.close(self)
    self.txQuery = nil
    self.txCurrency = nil
    for _, b in ipairs(self.txCurButtons) do b.active = b.internal == "all" end
    self.txAccountClass = nil
    if self.txAccountCombo then
        F.closeCombo(self.txAccountCombo)
        self.txAccountCombo:setSelectedData("all")
    end
    self.txKindSig = f.kind
    self.txDateSig = entryText(f.fromEntry) .. "\1" .. entryText(f.toEntry)
    self.owner.message = nil
    -- a refusal that is still on screen must not survive the click that replaces the question
    self.txListError = nil
    self.txListTimeout = false
    self.txDirty = true
    -- a chip, not typing: exactly one request goes out on the next frame, and the debounce clock
    -- is cleared so a half-typed day cannot queue a second one behind it
    self.txQueryAt = nil
    self:layout()
end

function Page:copyToClipboard(value, label)
    if type(value) ~= "string" or value == "" then return end
    if not (Clipboard and Clipboard.setClipboard) then
        self.owner.message = { text = tr("Admin_Sys_CopyFailed"), error = true }
        return
    end
    local ok = pcall(Clipboard.setClipboard, value)
    self.owner.message = ok and { text = getText(T .. "Admin_Audit_Copied", label or value) }
        or { text = tr("Admin_Sys_CopyFailed"), error = true }
end

function Page:onTxCopy()
    local d = self.txDetail
    local id = (d ~= nil and d.txId ~= nil) and tostring(d.txId) or nil
    self:copyToClipboard(id, id)
end

-- Keep the original values, not the display-only hard line breaks.
function Page:onTxCopyFull()
    self:copyToClipboard(self.txDetailText, tr("Admin_Tx_Detail"))
end

-- The shop page's two shortcuts: the money page filtered to what the system sold, or to what it
-- bought back. The filter is set before the tab switch, so the page's first read is already the
-- filtered one instead of a full read followed a frame later by the real one. The controller
-- calls this and then switches the tab itself.
function Page:show(group)
    local f = self.txF
    f.kind = group or "all"
    f.page = 1
    for _, b in ipairs(f.kindButtons) do b.active = (not b.unused) and b.internal == f.kind end
    self.txKindSig = f.kind
    setEntryText(self.txEntry, "")
    self.txQuery = nil
    self.txDirty = true
    self.txQueryAt = nil
    self.txView = "list"
    self:clearTxDetail()
    self:rebuildTransactions()
end

-- ----- keyboard targets (C.Keyboard walks these; this page owns no key dispatch) -----

-- The controls of the money view that is open, in the order a keyboard should reach them. The
-- controller answers with an empty table while another sub page is up, so the root only ever
-- offers what is on screen.
function Page:keyboardTargets()
    local out = {}
    local function add(kind, label, control, controls)
        out[#out + 1] = { kind = kind, label = label, control = control, controls = controls }
    end
    local function group(label, buttons)
        local shown = {}
        for _, b in ipairs(buttons) do
            if b:getIsVisible() then shown[#shown + 1] = b end
        end
        if #shown > 0 then add("group", label, nil, shown) end
    end
    if self.txView == "detail" then
        group(tr("Admin_Tx_Detail"), self.txDetailButtons)
        -- kind = "scroll", and never focused: focusing this box would hand every key to
        -- Core.currentTextEntryBox. The keyboard scrolls it and copies the record with the chip
        -- above; `focusable = false` states that so no root can focus it by default.
        out[#out + 1] = { kind = "scroll", label = tr("Admin_Tx_Detail"), control = self.txDetailBox,
            focusable = false, copyAll = self.txCopyFullButton }
        return out
    end
    local f = self.txF
    add("entry", tr("Admin_Tx_SearchLabel"), self.txEntry)
    group(tr("Admin_Tx_Currency"), self.txCurButtons)
    group(tr("Admin_Tx_Group"), f.kindButtons)
    add("entry", f.fromLabel, f.fromEntry)
    add("button", tr("Filter_Calendar"), f.fromEntry.calendarButton)
    add("entry", f.toLabel, f.toEntry)
    add("button", tr("Filter_Calendar"), f.toEntry.calendarButton)
    add("combo", tr("Admin_Tx_AccountClass"), self.txAccountCombo)
    group(f.sortLabel, f.sortButtons)
    group(tr("Filter_PageNav"), { f.prevButton, f.nextButton })
    group(tr("Admin_Tx_Actions"), self.txActionButtons)
    add("scroll", tr("Admin_Tx_Title"), self.txNotesBox)
    add("list", tr("Admin_Tx_Title"), self.txList)
    return out
end

-- ----- transport -----

-- Does this reply still belong to the read that is open? Asked before the controller frees the
-- command slot, and answered without touching a single field: a stale reply must not release the
-- slot owned by a newer read.
function Page:matchesReply(kind, args)
    if args.requestId == nil then return true end
    local expected
    if kind == "transactions" then expected = self.txRequestId
    elseif kind == "transaction" then expected = self.txDetailRequestId
    else return true end
    return expected == nil or args.requestId == expected
end

function Page:onReply(kind, args)
    if kind == "transactions" then
        -- matched against the request that is still open: an answer to a search the admin has
        -- already moved on from never lands, even when its own pending flag was cleared by a
        -- timeout first. A refusal is recorded as a refusal -- the rows that are up stay up and
        -- are labelled as the previous conditions, so a busy or unreadable server never reads as
        -- "this server has no money flow" and never reads as "still loading" either.
        if args.requestId ~= nil and self.txRequestId ~= nil and args.requestId ~= self.txRequestId then return end
        if args.error ~= nil then
            self.txListError = args.error
            self.txListTimeout = false
            self.owner.message = { text = self:txStatusText("error"), error = true }
            self:layout()
            return
        end
        if type(args.entries) ~= "table" then return end
        -- the reply is oldest first: every row remembers its place, which is what the "time"
        -- sort reads, so the page reverses exactly
        for i, e in ipairs(args.entries) do
            if type(e) == "table" then e.ord = i end
        end
        self.transactions = args
        self.updatedAt = EC.now()
        self.txListError = nil
        self.txListTimeout = false
        -- the conditions this snapshot answers; the row's current state is compared against it,
        -- so rows read under an older filter are labelled instead of passed off as the answer
        self.txSnapSig = self.txReqSig
        -- the range the server actually read; the detail read quotes it back so both sides look
        -- in the same files
        self.txFromMs = tonumber(args.fromMs)
        self.txToMs = tonumber(args.toMs)
        self.owner.message = nil
        self:layout()
    elseif kind == "transaction" then
        if args.requestId ~= nil and self.txDetailRequestId ~= nil and args.requestId ~= self.txDetailRequestId then return end
        if args.txId ~= nil and self.txDetailTx ~= nil and tostring(args.txId) ~= self.txDetailTx then return end
        if args.error ~= nil then
            self.txDetailError = args.error
            self.txDetailTimeout = false
            self.txDetailAnswered = false
            self.owner.message = { text = self:txDetailNoteText("error"), error = true }
            self:layout()
            return
        end
        local entries = type(args.entries) == "table" and args.entries or {}
        -- an empty answer is an answer: the id is not in the files the range covers. A read that
        -- never came back is a different thing and is never folded into this one.
        self.txDetail = type(entries[1]) == "table" and entries[1] or nil
        self.txDetailError = nil
        self.txDetailTimeout = false
        self.txDetailAnswered = true
        self:layout()
    else
        return
    end
    self:updateEnabled()
end

-- The controller keeps the shared command timeout and its footer line; the page keeps what the
-- two money reads say about themselves. Neither read drops the rows that are up.
function Page:onTimeout(command)
    if command == "admin.transaction" then
        -- the answer is never coming. This is *not* "the transaction does not exist": the state
        -- says timed out, the retry chip is what asks again.
        self.txDetailRetry = nil
        self.txDetailTimeout = true
        self.txDetailAnswered = false
        self:rebuildTxNotes()
    elseif command == "admin.transactions" then
        -- the rows that are up stay up; the status line says the read timed out, and the retry
        -- chip is what asks again (a dead server is never hammered by the debounce)
        self.txListTimeout = true
        self:rebuildTxNotes()
    end
end

-- ----- data normalisation (data or geometry changes only) -----

function Page:updateTxText()
    setWrappedText(self.txNotesBox, self.txNotesText, self.txNotesBox.width)
    setWrappedText(self.txDetailBox, (self.txDetailNote or "") .. "\n\n" .. (self.txDetailText or ""), self.txDetailBox.width)
end

-- One transaction: "kind / item xN" over "time / tx id / the accounts it touched", the
-- per-currency movement on the right. A rolled-back transaction is struck through and labelled,
-- exactly like the wallet's own receipt rows.
function Page:transactionRow(e, lh, width)
    local kind = tostring(e.kind or "?")
    local head = getTextOrNull(T .. "Kind_" .. kind) or kind
    if type(e.item) == "string" and e.item ~= "" then
        head = head .. "  " .. itemName(e.item)
        -- an event that never carried a lot size says nothing rather than inventing one
        local qty = math.floor(tonumber(e.qty) or 0)
        if qty > 1 then head = head .. "  " .. getText(T .. "Market_Lot", tostring(qty)) end
    end
    local meta = stampText(e.ts, self.offsetMin) .. " / " .. getText(T .. "Admin_Tx_Id", tostring(e.txId or "-"))
    local accounts = e.accounts
    if type(accounts) == "table" and #accounts > 0 then
        local names = accountName(accounts[1])
        for i = 2, #accounts do names = names .. ", " .. accountName(accounts[i]) end
        meta = meta .. " / " .. tr("Admin_Tx_Account") .. " " .. names
    end
    if type(e.sourceMod) == "string" and e.sourceMod ~= "" then
        meta = meta .. " / " .. getText(T .. "Admin_Tx_Source", txSourceName(e))
    end
    local rolled = e.rolledBack == true
    local rolledLabel = rolled and tr("Wallet_RolledBack") or nil
    local amountLabel = txAmountText(e.amounts)
    local right = math.max(60, width - PAD)
    local headW = math.max(0, right - textWidth(amountLabel) - PAD * 2)
    local metaW = rolled and math.max(0, headW - textWidth(rolledLabel) - PAD) or headW
    local item = {
        txId = tostring(e.txId or ""),
        line1Y = 5, line2Y = 5 + lh, amountRight = right, amountLabel = amountLabel,
        rolled = rolled, rolledLabel = rolledLabel,
        headText = fitText(head, headW), metaText = fitText(meta, metaW),
    }
    item.headW = textWidth(item.headText)
    return item
end

-- The page the server last sent, turned into one local page over the shared filter row. The
-- reply is oldest first (the server reads the event files forward) and every entry was tagged
-- with its position when it landed, so "time, newest first" is exactly that reversal -- two
-- transactions inside the same second included. Source and date filters belong to the server;
-- sorting an older snapshot while the next read is pending or failed must not filter it away.
function Page:rebuildTransactions()
    local f = self.txF
    local snap = self.transactions
    local src = (snap and type(snap.entries) == "table") and snap.entries or {}
    local picked, page, pages, total = EC.filterPage(src, {
        sortKey = f.fields[f.sortKey], desc = f.desc, page = f.page, perPage = F.PER_PAGE,
    })
    f.page, f.pages, f.total = page, pages, total
    local rows = {}
    local width = math.max(120, self.txList.width - 12)   -- 12 = the scrollbar gutter
    local lh = lineH()
    local selected = nil
    for _, e in ipairs(picked) do
        if type(e) == "table" then
            rows[#rows + 1] = self:transactionRow(e, lh, width)
            -- the pick follows the transaction, not the row number: a page turn or a fresh read
            -- keeps the band on the very transaction it is describing
            if self.txDetailTx ~= nil and rows[#rows].txId == self.txDetailTx then selected = #rows end
        end
    end
    self.txRows = rows
    self.txList:setItems(rows)
    self.txList:setSelectedIndex(selected)
end

-- The filter the snapshot on screen was read with. Comparing it against the row's current
-- state is what tells an old answer apart from the answer to the question being asked now.
function Page:txFilterSig()
    local f = self.txF
    return tostring(self.txQuery or "") .. "\1" .. tostring(f.kind)
        .. "\1" .. tostring(self.txCurrency or "") .. "\1" .. tostring(self.txAccountClass or "")
        .. "\1" .. entryText(f.fromEntry) .. "\1" .. entryText(f.toEntry)
end

function Page:txStale()
    if self.transactions == nil then return false end
    return self.txSnapSig ~= self:txFilterSig()
end

-- What the list is showing, as exactly one state. Read off the snapshot and the read flags, not
-- off the row count alone: a read that failed before any snapshot arrived is not "loading", a
-- read that never came back is not "no matching transactions", and rows that answer a question
-- the admin has since changed are not an answer to the new one.
function Page:txListStatus()
    if self.txListTimeout == true then return "timeout" end
    if self.txListError ~= nil then return "error" end
    local snap = self.transactions
    if snap == nil then return "loading" end
    if self:txStale() then return "stale" end
    if #(type(snap.entries) == "table" and snap.entries or {}) == 0 then return "empty" end
    return "ready"
end

-- Every state says what it is and what to do next, so "busy" or an unknown code never leaves the
-- admin guessing. This is the read flow only: an adjustment's own refusal keeps its own wording.
function Page:txStatusText(state)
    if state == "loading" then return tr("Admin_Loading") end
    if state == "timeout" then return tr("Admin_Tx_TimedOut") end
    if state == "error" then
        local code = self.txListError
        -- a range this side refused: the boxes are what is wrong, not the server
        if code == "invalid_range" then return tr("Admin_Tx_InvalidRange") end
        if code == "read_failed" then return getText(T .. "Admin_Tx_ListError", tr("Admin_Tx_ReadFailed")) end
        if code == "busy" or code == "server_busy" or code == "rate_limited" then
            return getText(T .. "Admin_Tx_ListError", tr("Admin_Tx_BusyHint"))
        end
        return getText(T .. "Admin_Tx_ListError", errorText(code))
    end
    if state == "stale" then return tr("Admin_Tx_Stale") end
    return tr("Admin_Tx_Empty")
end

function Page:txDetailStatus()
    if self.txDetail ~= nil then return "ready" end
    if self.txDetailTimeout == true then return "timeout" end
    if self.txDetailError ~= nil then return "error" end
    if self.isPending("admin.transaction") or self.txDetailRetry ~= nil then return "loading" end
    if self.txDetailAnswered == true then return "missing" end
    return "loading"
end

function Page:txDetailNoteText(state)
    if state == "ready" then return tr("Admin_Tx_DetailHint") end
    if state == "loading" then return tr("Admin_Loading") end
    if state == "timeout" then return tr("Admin_Tx_DetailTimedOut") end
    if state == "error" then
        local code = self.txDetailError
        if code == "read_failed" then return getText(T .. "Admin_Tx_DetailError", tr("Admin_Tx_ReadFailed")) end
        if code == "busy" or code == "server_busy" or code == "rate_limited" then
            return getText(T .. "Admin_Tx_DetailError", tr("Admin_Tx_DetailBusy"))
        end
        return getText(T .. "Admin_Tx_DetailError", errorText(code))
    end
    return tr("Admin_Tx_NotFound")
end

-- Every wrapped block the two views draw. Wrapping happens here -- on a layout, and when a
-- reply changes what a block says -- so the card can reserve exactly the room each block needs
-- and the painters only draw. Never per frame (the file's painting rule). The blocks are painted
-- by the native read-only boxes, which carry one text colour: the state is in the words.
function Page:rebuildTxNotes()
    local snap = self.transactions
    local cut = snap ~= nil and snap.truncated == true
    local state = self:txListStatus()
    local status = state ~= "ready" and self:txStatusText(state) or ""
    local note = tr(cut and "Admin_Tx_Truncated" or "Admin_Tx_Note")
    self.txNotesText = (status ~= "" and (status .. "\n") or "") .. note
    self.txDetailNote = self:txDetailNoteText(self:txDetailStatus())
    self:updateTxText()
end

-- Every field of one committed transaction as plain lines, and nothing left out: the origin, the
-- request id, every reference id, every account by its raw key, the whole reason and every
-- posting with both balance chains. Display wrapping is separate from the copied raw record.
function Page:buildTxDetailText()
    local d = self.txDetail
    self.txDetailText = nil
    if d == nil then
        self:updateTxText()
        return
    end
    local out = {}
    local function pair(label, value)
        out[#out + 1] = getText(T .. "Admin_Tx_Pair", label, value)
    end
    pair(tr("Admin_Tx_Field_Id"), tostring(d.txId or "-"))
    pair(tr("Wallet_Col_Time"), stampText(d.ts, self.offsetMin))
    local kind = tostring(d.kind or "?")
    pair(tr("Admin_Tx_Field_Kind"), (getTextOrNull(T .. "Kind_" .. kind) or kind) .. "  (" .. kind .. ")")
    pair(tr("Admin_Tx_Field_Group"), txGroupText(d.group))
    if d.rolledBack == true then out[#out + 1] = tr("Wallet_RolledBack") end
    pair(tr("Admin_Tx_Amount"), txAmountText(d.amounts))
    pair(tr("Admin_Tx_Field_Origin"), txSourceName(d))
    if type(d.actor) == "string" and d.actor ~= "" then pair(tr("Admin_Tx_Field_Actor"), d.actor) end
    if type(d.sourceMod) == "string" and d.sourceMod ~= "" then
        pair(tr("Admin_Tx_Field_Mod"), "MOD:" .. d.sourceMod)
    end
    -- its own line: a request id has no space in it, so it is the one field word wrap cannot
    -- break and the one that must never share a line with anything else
    pair(tr("Admin_Tx_Field_Request"), tostring(d.requestId or "-"))
    if type(d.epoch) == "string" or d.seq ~= nil then
        pair(tr("Admin_Tx_Field_Event"), tostring(d.epoch or "-") .. ":" .. tostring(d.seq or "-"))
    end
    local ref = d.ref
    if type(ref) == "table" and (ref.id ~= nil or ref.type ~= nil) then
        pair(tr("Admin_Tx_Field_Ref"), tostring(ref.type or "ref") .. " " .. tostring(ref.id or "-"))
    end
    for _, key in ipairs(TX_REF_KEYS) do
        if d[key] ~= nil then out[#out + 1] = getText(T .. "Admin_Tx_Ref_" .. key, tostring(d[key])) end
    end
    if type(d.item) == "string" and d.item ~= "" then
        local label = itemName(d.item) .. "  (" .. d.item .. ")"
        local qty = math.floor(tonumber(d.qty) or 0)
        if qty > 1 then label = label .. "  " .. getText(T .. "Market_Lot", tostring(qty)) end
        pair(tr("Admin_Tx_Field_Item"), label)
    end
    if type(d.sku) == "string" and d.sku ~= "" then pair(tr("Admin_Tx_Field_Sku"), d.sku) end
    -- every account by name *and* raw key: the raw key is what the event files and the commands
    -- are reconciled against, so it is never the part that gets dropped
    for _, account in ipairs(type(d.accounts) == "table" and d.accounts or {}) do
        pair(tr("Admin_Tx_Account"), accountName(account, true))
    end
    if type(d.reasonCode) == "string" and d.reasonCode ~= "" then
        pair(tr("Admin_Tx_Field_ReasonCode"), d.reasonCode)
    end
    pair(tr("Admin_Tx_Field_Reason"), reasonText(d.reasonCode, d.reasonText) or "-")
    local postings = type(d.postings) == "table" and d.postings or {}
    pair(tr("Admin_Tx_Field_Postings"), tostring(#postings))
    for i, p in ipairs(postings) do
        if type(p) == "table" then
            out[#out + 1] = ""
            txPostingLines(out, i, p)
        end
    end
    self.txDetailText = table.concat(out, "\n")
    self:updateTxText()
end

-- ----- enabling -----

-- The list and the detail view are both reads, so a read-only role drives the whole page. Only
-- the modal flag and the two money commands can take a control away.
function Page:updateEnabled()
    local read = self.owner:readAllowed()
    local modal = self.owner.dialog ~= nil
    local txRead = read and not modal
    setEntryEditable(self.txEntry, txRead)
    F.enable(self.txF, txRead)
    for _, b in ipairs(self.txCurButtons) do b:setEnable(txRead) end
    self.txClearButton:setEnable(txRead)
    self.txFilterButton:setEnable(txRead)
    self.txRetryButton:setEnable(txRead and not self.isPending("admin.transactions"))
    self.txBackButton:setEnable(txRead)
    self.txCopyButton:setEnable(txRead and self.txDetailText ~= nil)
    self.txCopyFullButton:setEnable(txRead and self.txDetailText ~= nil)
    self.txDetailRetryButton:setEnable(txRead and self.txDetailTx ~= nil and not self.isPending("admin.transaction"))
    -- the record box is set read-only once, in createChildren, and never touched here: every
    -- pass through this function would otherwise drop the keyboard out of it mid-selection
end

-- ----- geometry -----

-- The page's two chip rows -- the list view's own, so the detail view hides them outright. The
-- source chips are a fixed enumeration (F.kinds is fed once, in createChildren): a search that
-- matched nothing must still offer every other source to switch to, so nothing here ever depends
-- on what a reply carried.
function Page:layoutTxFilters(force)
    local g = self.g
    if g == nil then return end
    local visible = self:getIsVisible() and self.txView ~= "detail"
        and (force == true or not self.txCompact or self.txFiltersOpen == true)
    local chipH = math.max(20, fontH.small + 6)
    local w = math.max(60, self.width - PAD * 2 - (g.txHintW or 0) - PAD)
    F.layoutKinds(self.txF, visible, PAD, g.txGroupY, w, chipH)
    F.layoutRow(self.txF, visible, PAD, g.txRowY, math.max(60, self.width - PAD * 2), entryH(), chipH)
end

-- Short windows use a filter sheet; results and complete information keep real viewports.
function Page:layout()
    local w, h = self.width, self.height
    local lh, rh, eh = lineH(), rowH(), entryH()
    local pageH = math.max(20, fontH.small + 6)
    local lstW = math.max(160, w - PAD * 2)
    local g = {}
    self.g = g
    -- the window owns the zone; the calendar popup reads it off whichever panel attached the box
    self.offsetMin = self.owner.offsetMin
    local on = self:getIsVisible()
    local txL = on and self.txView ~= "detail"
    local txD = on and self.txView == "detail"
    local txTop, txBottom = CARD_TITLE_H + 4, h
    local infoH = fontH.small * 2 + 8
    g.txHintW = math.min(textWidth(tr("Admin_Tx_RangeHint")), math.floor(w * 0.3))
    g.txGroupY, g.txRowY = txTop + eh + 4, txTop + eh + pageH + 8
    self:layoutTxFilters(true)
    local fullActionY = g.txRowY + self.txF.rowH + 4
    self.txCompact = txBottom - lh - fullActionY - pageH - infoH - 12 < rh * 2
    local filterSheet = self.txCompact and self.txFiltersOpen == true
    local results = txL and not filterSheet
    local showFilters = txL and (not self.txCompact or filterSheet)
    local filterTop = filterSheet and 4 or txTop
    g.txSearchLabelY = filterTop + math.floor((eh - fontH.small) / 2)
    local txEntryX = PAD + textWidth(tr("Admin_Tx_SearchLabel")) + 6
    if not showFilters and self.txEntry:isFocused() then self.txEntry:unfocus() end
    self.txEntry:setVisible(showFilters)
    self.txEntry:setX(txEntryX); self.txEntry:setY(filterTop)
    self.txEntry:setWidth(math.min(240, math.floor(w * 0.28))); self.txEntry:setHeight(eh)
    g.txCurTextY = g.txSearchLabelY
    g.txCurLabelX = txEntryX + self.txEntry.width + PAD
    local txCurX = g.txCurLabelX + textWidth(tr("Admin_Tx_Currency")) + 6
    for _, button in ipairs(self.txCurButtons) do
        button:setVisible(showFilters)
        button:setWidth(math.min(textWidth(button.fullTitle) + 20, math.max(24, math.floor(w * 0.14))))
        button:setHeight(pageH); button:setX(txCurX); button:setY(filterTop)
        U.setButtonTitle(button, button.fullTitle)
        txCurX = txCurX + button.width + 4
    end
    g.txGroupY = filterTop + eh + 4
    g.txRangeHintY = g.txGroupY + math.floor((pageH - fontH.small) / 2)
    g.txRowY = g.txGroupY + pageH + 4
    self:layoutTxFilters()
    self.txFilterButton.fullTitle = tr(filterSheet and "Admin_Tx_Results" or "Admin_Tx_Filters")
    local actionY = showFilters and (g.txRowY + self.txF.rowH + 4) or txTop
    local pagerSpace = self.txCompact and not filterSheet and (pageH * 2 + 12) or 0
    txButtonRow(self.txActionButtons, txL, PAD, actionY, lstW - pagerSpace, pageH,
        not self.txCompact and self.txFilterButton or nil)
    if txL and self.txCompact and not filterSheet then
        for i, button in ipairs({ self.txF.prevButton, self.txF.nextButton }) do
            button:setVisible(true); button:setX(w - PAD - (3 - i) * (pageH + 4))
            button:setY(actionY); button:setWidth(pageH); button:setHeight(pageH)
            U.setButtonTitle(button, button.fullTitle)
        end
    end
    local noteY = actionY + pageH + 4
    g.txSelectY = txBottom - lh
    self.txNotesBox:setVisible(results)
    self.txNotesBox:setX(PAD); self.txNotesBox:setY(noteY)
    self.txNotesBox:setWidth(lstW); self.txNotesBox:setHeight(infoH)
    local txListY = noteY + infoH + 4
    U.placeList(self.txList, results, PAD, txListY, lstW, math.max(1, g.txSelectY - 4 - txListY))

    g.txDetailHeadY, g.txDetailHeadW = txTop, lstW
    local detailActionY = txTop + eh + 2
    txButtonRow(self.txDetailButtons, txD, PAD, detailActionY, lstW, pageH)
    local detailY = detailActionY + pageH + 6
    self.txDetailBox:setVisible(txD)
    self.txDetailBox:setX(PAD); self.txDetailBox:setY(detailY)
    self.txDetailBox:setWidth(lstW); self.txDetailBox:setHeight(math.max(1, txBottom - PAD - detailY))

    self:rebuildTxNotes()
    self:rebuildTransactions()
    self:buildTxDetailText()
    self:updateEnabled()
end

-- The controller sizes the page on every one of its own layouts: the labels and the rows are
-- data driven, so they are rebuilt even when the box did not move.
function Page:resize(width, height)
    if self.width ~= width then self:setWidth(width) end
    if self.height ~= height then self:setHeight(height) end
    self:layout()
end

-- Hiding the page is what takes its controls off the keyboard's list and off the screen, so the
-- children follow the flag. Snapshots are kept: coming back to the page must not re-read what is
-- already known (the poll and the retry chip are what re-read).
function Page:setVisible(visible)
    local was = self:getIsVisible()
    local offsetChanged = visible and self.offsetMin ~= self.owner.offsetMin
    ISPanel.setVisible(self, visible)
    if visible then
        self.offsetMin = self.owner.offsetMin
    else
        DatePicker.close(self)
        F.closeCombo(self.txAccountCombo)
        F.blurDates(self.txF)
        pcall(function() self.txEntry:unfocus() end)
        pcall(function() self.txDetailBox:unfocus() end)
    end
    if self.txList ~= nil and (was ~= visible or offsetChanged) then self:layout() end
end

-- ----- drawing -----

-- The page paints exactly one of its two views: the list of committed transactions, or one
-- transaction's whole record. Both are reads, so nothing it draws is ever armed by write
-- permission.
function Page:prerender()
    if self.txView == "detail" then return self:drawTxDetail() end
    self:drawTxList()
end

function Page:render() end

-- The note and the status line the list view draws above its rows, wrapped by rebuildTxNotes so
-- the card could reserve exactly the room they need: nothing important is ever fitted to one
-- line and cut. Six states are told apart, so a first read that failed never reads as
-- "loading", a timeout never reads as "no matching transactions", and rows that answer a
-- question the admin has since changed say so instead of pretending to answer the new one.
function Page:drawTxList()
    local g = self.g
    if not (self.txCompact and self.txFiltersOpen) then
        card(self, 0, 0, self.width, self.height, tr("Admin_Tx_Title"))
    end
    if self.txEntry:getIsVisible() then
        F.draw(self.txF, self)
        text(self, tr("Admin_Tx_SearchLabel"), PAD, g.txSearchLabelY, "textMuted")
        text(self, tr("Admin_Tx_Currency"), g.txCurLabelX, g.txCurTextY, "textMuted")
        textRight(self, fitText(tr("Admin_Tx_RangeHint"), g.txHintW), self.width - PAD, g.txRangeHintY, "textMuted")
    end
    if self.txList:getIsVisible() then
        local hint = tr("Admin_Tx_Select")
        if self.txCompact then hint = tostring(self.txF.page) .. "/" .. tostring(self.txF.pages or 1) .. "  " .. hint end
        text(self, fitText(hint, self.width - PAD * 2), PAD, g.txSelectY, "textMuted")
    end
end

-- One transaction's whole record. The record itself lives in a read-only, non-selectable,
-- scrolling text box (a child the engine paints), so this only draws the frame, the id line and
-- -- when there is no record on screen -- which of the four reasons that is. The four are told
-- apart: a read still out, a read that timed out, a read the server refused, and an id the files
-- of that window really do not carry.
function Page:drawTxDetail()
    local g = self.g
    card(self, 0, 0, self.width, self.height, tr("Admin_Tx_Detail"))
    text(self, fitText(getText(T .. "Admin_Tx_Id", tostring(self.txDetailTx or "-")),
        g.txDetailHeadW), PAD, g.txDetailHeadY, "text")
end

-- ----- lifecycle -----

-- The open view decides what a refresh means: the list read for the list, the very transaction
-- on screen for the detail view. A refresh that only ever re-read the list left the detail view
-- stale. The controller has already checked read permission and the command cooldown guards the
-- rest, so a rapid tab switch simply skips the extra request.
function Page:refresh()
    if self.txView == "detail" then
        if self.txDetailTx ~= nil then self:requestTxDetail(self.txDetailTx) end
    else
        self:requestTransactions()
    end
end

-- The clock the controller drives while this page is the one on screen and reading is allowed.
-- The list's search box and filter row share it: a typed word (or a typed day) costs one command
-- per pause, a chip costs one on the next frame. The sent state is recorded when the request
-- leaves -- never when the answer lands -- so a server that says "busy" is reported once instead
-- of asked again in a loop; the 30 s poll and the retry chip are what retry.
function Page:tick(now)
    if self.txView == "list" then
        if self.txQueryAt and now - self.txQueryAt > TX_DEBOUNCE_MS then
            self.txQueryAt = nil
            self:requestTransactions()
        elseif not self.txQueryAt and (self.txDirty == true or self.txAsked ~= true) then
            self:requestTransactions()
        end
    elseif self.txView == "detail" then
        -- the detail read is its own command: a list read in flight must never starve it
        if self.txDetailRetry ~= nil and not self.isPending("admin.transaction") then
            self:requestTxDetail(self.txDetailRetry)
        end
    end
end

-- The permission collapse: everything this page learned from the server is dropped, and the page
-- reads as one that was never opened. No command is sent, and nothing is asked for again until
-- the controller says reading is allowed once more.
function Page:clear()
    self.transactions = nil
    self.txDetail = nil
    self.txDetailTx = nil
    self.txDetailText = nil
    self.txDetailError = nil
    self.txDetailTimeout = false
    self.txListError = nil
    self.txListTimeout = false
    self.txView = "list"
    self.txAsked = false
    self.txDirty = false
end

function Page:dispose()
    DatePicker.close(self)
    F.closeCombo(self.txAccountCombo)
    pcall(function() self.txEntry:unfocus() end)
    pcall(function() self.txF.fromEntry:unfocus() end)
    pcall(function() self.txF.toEntry:unfocus() end)
    pcall(function() self.txDetailBox:unfocus() end)
    self.transactions = nil
    self.txDetail = nil
    self.txDetailText = nil
    self.txDetailTx = nil
    self.txDetailRetry = nil
    self.txDetailError = nil
    self.txDetailTimeout = false
    self.txListError = nil
    self.txListTimeout = false
    self.txView = "list"
end

-- ---------- module API ----------

-- owner: the admin controller. Returns an initialised child that the owner adds, positions and
-- resizes. No command is sent, and the three transport functions are the owner's own.
function P.create(owner, send, isPending, newRequestId)
    local o = ISPanel:new(0, 0, 600, 300)
    setmetatable(o, Page)
    o.background = false
    o.owner = owner
    o.send, o.isPending, o.newRequestId = send, isPending, newRequestId
    o.offsetMin = owner.offsetMin
    o.txView = "list"
    o.txFiltersOpen = false
    o:initialise()
    o:instantiate()   -- builds the children now; the owner only has to addChild/resize
    o:setVisible(false)
    return o
end

return P
