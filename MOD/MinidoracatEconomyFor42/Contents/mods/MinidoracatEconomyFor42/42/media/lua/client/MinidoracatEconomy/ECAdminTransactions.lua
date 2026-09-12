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
-- from the card frame down belongs to this file: the search box, the keyword match mode, the
-- exact account, the exact item, the currency chips, the account class combo, the shared filter
-- row, the list of committed transactions (admin.transactions) and one transaction's whole
-- record (admin.transaction).
--
-- Three questions the page can ask, and they are not the same question:
--   account   an exact, case-sensitive account: it is picked from the shared player picker, and
--             it is compared against the accounts of the postings only. A short username can
--             never match a longer one, and it is never confused with an actor or a reason that
--             happens to mention the name.
--   item      an exact fullType, picked from the shared item picker.
--   keyword   free text over the identifiers an admin has in hand, 'contains' or 'exact'. When
--             C.ItemNames can name items in the current language (or in English), the keyword is
--             also resolved into the fullTypes it names and those go with the request, so a
--             Chinese or English item name really does narrow the read on the server. The item
--             set is never applied here: the server's 200-row bound has to count matches, so a
--             page of 200 unrelated rows filtered down to none afterwards is exactly what this
--             page must not do.
--
-- What the page borrows from the controller (and nothing else):
--   owner:readAllowed()   the permission gate both sides collapse on
--   owner.dialog          the modal flag (a write dialog owns the panel while it is open)
--   owner.message         the shared footer line
--   owner.offsetMin       the window's timezone offset, mirrored onto the page for the calendar
--   owner.owner           the root window, the only thing C.Keyboard.invalidate accepts
--
-- The controller also hands the page what belongs to it and to nothing else:
--   Page:show(group, filters)     filters = { account?, item?, query?, txId?, ts? }; txId with ts
--                                 opens that one record over the single civil day it happened on
--   Page:onPlayersReply(args)     an admin.players reply the account picker asked for
--   Page:onViewChanged(scope)     'transactions' changed on the server: read again when visible
--   Page:isModal() / onEscape()   the item picker overlay this page puts over itself
--
-- Reading a row and opening it are one gesture with two answers: the row body picks the
-- transaction and opens the shared detail window (C.DetailWindow) on it -- first the summary the
-- list snapshot already carries, then the whole record (every posting, both balance chains) when
-- the second read lands. Nothing is spelled out inside the card any more: there is no preview
-- band eating the rows, no full-summary mode that drops the list, and no second view. The list
-- keeps its conditions, its page and its scroll while a record is being read.
--
-- Painting rules are the controller's: rows, wrapped text and truncation are rebuilt when data
-- arrives, when the filter changes or when the geometry changes -- never per frame. The page owns
-- no Events hook and no timer of its own: the controller calls tick(now) while this page is the
-- one on screen.

require "ISUI/ISPanel"
require "ISUI/ISComboBox"
require "ISUI/ISScrollBar"
require "MinidoracatEconomy/ECWidgets"
require "MinidoracatEconomy/ECDetailWindow"
require "MinidoracatEconomy/ECAdminFilters"
require "MinidoracatEconomy/ECDatePicker"
require "MinidoracatEconomy/ECPlayerPicker"
require "MinidoracatEconomy/ECItemPicker"
require "MinidoracatEconomy/ECItemNames"

local EC = MinidoracatEconomy
local C = EC.Client
local U = C.UI
local F = C.AdminFilters
local Detail = C.DetailWindow
local DatePicker = C.DatePicker
local PlayerPicker = C.PlayerPicker
local ItemPicker = C.ItemPicker
local ItemNames = C.ItemNames

local P = {}
C.AdminTransactions = P

local PAD, T = U.PAD, U.T
local CARD_TITLE_H = U.CARD_TITLE_H
local fontH = U.fontH
local fill, text, textWidth, fitText, textRight = U.fill, U.text, U.textWidth, U.fitText, U.textRight
local stampText, amountText, signedText, card = U.stampText, U.amountText, U.signedText, U.card
local accountName, reasonText, dateText = U.accountName, U.reasonText, U.dateText
local Button = U.Button
local newEntry, entryText, setEntryText, setEntryEditable = U.newEntry, U.entryText, U.setEntryText, U.setEntryEditable
local errorText, currencyName, itemName = U.adminErrorText, U.currencyName, U.itemName
local newReader = U.newReader

-- The sources the server sorts every committed transaction into: a fixed enumeration, never what
-- a reply happened to carry, so a search that matched nothing still offers every other source to
-- switch to. "all" is the filter row's own first chip.
local TX_GROUPS = { "shop_buy", "shop_sell", "market", "auction", "rewards", "admin", "mod", "exchange", "other" }
local TX_MATCH_MODES = { "contains", "exact" }
local TX_RANGE_MAX_MS = 62 * 86400000   -- the span one read may cover; the server enforces the same
local TX_DEBOUNCE_MS = 650              -- typing (a word or a day) costs one command per pause
local TX_QUERY_CHARS = 96               -- a whole transaction id fits, so one can be pasted in
local TX_QUERY_BYTES = 128              -- what the server accepts; a CJK word is three bytes a letter
local TX_ACCOUNT_BYTES = 64             -- what the server accepts for the exact account
local TX_ITEM_BYTES = 128               -- and for one fullType
local TX_ITEM_TYPES_MAX = 256           -- the resolved item set the server will take

-- the ids a payload may name; anything else it holds stays out of the panel
local TX_REF_KEYS = { "auctionId", "listingId", "orderId" }

-- The filter sheet keeps a gutter for its own scrollbar (17 px wide, 4 px clear of the row), so a
-- condition never lands under the bar that scrolls it.
local SHEET_GUTTER = 21

local function tr(key) return getText(T .. key) end
local function lineH() return fontH.small + 6 end
local function entryH() return math.max(26, fontH.small + 12) end
local function listRowH() return lineH() * 2 + 12 end
local function chipH() return math.max(20, fontH.small + 6) end

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

-- Every account of one transaction, by name and by raw key. Never fitted to a width: the readers
-- that show this wrap and scroll, and a cut account key is the one thing an audit cannot use.
local function txAccountsText(accounts)
    if type(accounts) ~= "table" or #accounts == 0 then return "-" end
    local out = accountName(accounts[1], true)
    for i = 2, #accounts do out = out .. ", " .. accountName(accounts[i], true) end
    return out
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

local Page = ISPanel:derive("MinidoracatEconomyAdminTxPage")

-- ----- controls -----

-- The list view is five rows of conditions over one read-only list: the keyword and its match
-- mode, the exact account and the exact item, the currencies, the fixed sources, and the shared
-- date / sort / page row. A picked row is spelled out in the summary band under the note; the
-- whole record is the row's own button and opens the detail view, a second read on its own
-- command so the two can never overwrite each other's answer.
function Page:createChildren()
    self.txEntry = newEntry(240, entryH(), { maxLen = TX_QUERY_CHARS, clear = true,
        placeholder = tr("Admin_Tx_Search") })
    self.txEntry.target = self
    self.txEntry.onTextChangeFunction = Page.onTxSearch
    self:addChild(self.txEntry)
    -- the keyword's own mode: one field's whole value, or any field containing the text
    self.txModeButtons = {}
    for _, mode in ipairs(TX_MATCH_MODES) do
        local title = tr("Admin_Tx_Match_" .. mode)
        local b = Button.create(0, 0, textWidth(title) + 20, 22, title, self, Page.onTxMatchMode, "chip")
        b.internal = mode
        b.active = mode == "contains"
        self:addChild(b)
        self.txModeButtons[#self.txModeButtons + 1] = b
    end
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
    accountCombo.doRepaintStencil = true
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
    self.txList = U.newTable(U.AdminHistoryCell, listRowH())
    -- the body of a row reads: it picks the transaction (by id, so a page turn keeps the pick)
    -- and opens the record in the shared detail window. The row carries no control of its own,
    -- so the whole width belongs to the text.
    self.txList.onSelect = function(_, item)
        self:onTxSelect(item)
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
    -- the exact account and the exact item: each is picked, each is cleared, and neither is ever
    -- changed by typing a keyword
    self.txAccountClearButton = chip(tr("Admin_Tx_AccountClear"), Page.onTxAccountClear, "accountClear")
    self.txItemButton = chip(tr("Admin_Pick_Title"), Page.onTxItemPick, "itemPick")
    self.txItemClearButton = chip(tr("Admin_Tx_ItemClear"), Page.onTxItemClear, "itemClear")
    -- the note over the list: one read-only, scrolling surface, and it says what the *read* is
    -- doing. A record is never spelled out here -- that is the detail window's -- so the card
    -- never trades rows for a band.
    self.txNotesBox = newReader(self, 240, lineH() * 2)
    -- The filter sheet's own scrollbar. A short window folds the conditions into a viewport;
    -- every control in it is still positioned by layout(), so this bar only moves the page's own
    -- offset (getYScroll / setYScroll answer it) and the engine's scroll is never used.
    self.txSheetBar = ISScrollBar:new(self, true)
    self.txSheetBar:initialise()
    self:addChild(self.txSheetBar)
    self.txSheetBar:setAnchorLeft(true)
    self.txSheetBar:setAnchorRight(false)
    self.txSheetBar:setAnchorBottom(false)
    self.txSheetBar:setVisible(false)

    -- The shared player picker. It is a plain object, not a widget: it adds its own two children
    -- (the box, then the candidate list) onto this page, so it is created here -- after
    -- everything the list has to drop over, before the overlay that has to cover it. It owns no
    -- Events hook: tick(now) below is its clock, and admin.players replies reach it through the
    -- controller as onPlayersReply.
    self.txAccountPicker = PlayerPicker.create(self, self.send, self.isPending, self.newRequestId,
        function(entry) self:onAccountPicked(entry) end, "transactions")
    -- and the item picker overlay is added last of all: it paints over the whole page
    self.itemPicker = ItemPicker.create(self, "shop",
        function(record) self:onItemPicked(record) end,
        function() self:onItemPickCancelled() end)
    self:addChild(self.itemPicker)

    self:layout()
end

-- ----- the keyword's item set (C.ItemNames) -----

-- What the keyword names, as fullTypes, so the server can narrow the read itself. Three answers
-- are not the same and none of them is "no matching transactions":
--   not ready   the index is still loading: the rows on screen stay up and are labelled, and the
--               read goes out exactly once, when the index is ready
--   too broad   the keyword names more items than one request may carry: said out loud, never
--               silently cut to the first 256
--   {}          the keyword really names no item -- the read still goes out, because the keyword
--               also matches ids, accounts and reasons
-- A finished index that could not read every MOD still answers: the search runs on the real
-- names it does hold, and the MODs it could not read are copied out here, so the answer this
-- read produces can name them instead of letting an empty list pass for "there were none".

-- The gaps the index reports, as this page's own copy. The module keeps one growing list for the
-- whole session; an answer on screen has to stand by the state it was actually read under.
function Page:txNamesGapList()
    local names, _, gaps = ItemNames.status()
    if names ~= "partial" or type(gaps) ~= "table" then return nil end
    local out = {}
    for _, gap in ipairs(gaps) do
        if type(gap) == "table" and type(gap.modId) == "string" and gap.modId ~= "" then
            out[#out + 1] = { modId = gap.modId, reason = tostring(gap.reason or "unknown") }
        end
    end
    return #out > 0 and out or nil
end

function Page:resolveItemTypes()
    self.txNamesDirty = false
    local query = self.txQuery
    if query == nil then
        self.txItemTypes, self.txItemTypesKey = nil, ""
        self.txItemTypesError, self.txNamesWait = nil, false
        -- no keyword means no name was resolved: this read carries no index warning at all
        self.txNamesGaps = nil
        return
    end
    if not ItemNames.ensure() then
        -- loading (or not started until this very call): keep the previous set and the previous
        -- rows, and come back for one read when the index is ready
        self.txNamesWait = true
        return
    end
    local types, err = ItemNames.resolve(query, self.txMatchMode, ItemPicker.universe())
    if types == nil and err == "names_not_ready" then
        self.txNamesWait = true
        return
    end
    self.txNamesWait = false
    self.txNamesRev = tonumber(ItemNames.revision) or 0
    -- what the index could not see when this keyword was resolved
    self.txNamesGaps = self:txNamesGapList()
    if types == nil then
        -- too broad, or an index that cannot answer at all: a refusal of this side's own, so no
        -- request goes out under a condition the page could not apply
        self.txItemTypes, self.txItemTypesKey = nil, ""
        self.txItemTypesError = err or "names_unavailable"
        return
    end
    self.txItemTypesError = nil
    local out, seen = {}, {}
    for _, fullType in ipairs(types) do
        if type(fullType) == "string" and fullType ~= "" and #fullType <= TX_ITEM_BYTES
            and not seen[fullType] then
            seen[fullType] = true
            out[#out + 1] = fullType
        end
    end
    if #out > TX_ITEM_TYPES_MAX then
        -- the server would refuse the request, and cutting the set would answer a question the
        -- admin never asked
        self.txItemTypes, self.txItemTypesKey = nil, ""
        self.txItemTypesError = "item_query_too_broad"
        return
    end
    local key = table.concat(out, "\1")
    if key ~= self.txItemTypesKey then
        -- the condition really changed (a first resolve, or an index that finished loading):
        -- the snapshot on screen answered a different question
        self.txItemTypesKey = key
        self.txF.page = 1
        self.txDirty = true
    end
    self.txItemTypes = #out > 0 and out or nil
end

-- Why no request may leave right now -- always a condition of this side, never a server state,
-- and never a claim about what the files hold.
function Page:txBlockReason()
    if self.txNamesWait == true then return "names_loading" end
    if self.txItemTypesError ~= nil then return self.txItemTypesError end
    if self.txQuery ~= nil and #self.txQuery > TX_QUERY_BYTES then return "query_too_long" end
    return nil
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

-- One read per search / mode / account / item / source / currency / day change. Every condition
-- goes with the request, so the 200-row bound the server applies counts matches of the whole
-- question: nothing is filtered here afterwards. The sent state is cleared when the request
-- leaves -- never when the answer lands -- so a server that refuses is reported once instead of
-- asked again in a loop; the 30 s poll and the refresh chip are what retry.
function Page:requestTransactions()
    local blocked = self:txBlockReason()
    if blocked ~= nil then
        -- the question cannot be asked yet. It stays dirty (an index that finishes loading is
        -- what unblocks it), the rows on screen stay up, and the state is recorded once instead
        -- of every frame.
        if self.txBlockedBy ~= blocked then
            self.txBlockedBy = blocked
            self.owner.message = { text = self:txStatusText("blocked"), error = blocked ~= "names_loading" }
            self:rebuildTxNotes()
            self:updateEnabled()
        end
        return false
    end
    if self.txBlockedBy ~= nil then
        self.txBlockedBy = nil
        self.owner.message = nil
    end
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
    if self.txMatchMode == "exact" then args.matchMode = "exact" end
    if self.txAccount then args.account = self.txAccount end
    if self.txItem then args.item = self.txItem end
    if self.txItemTypes then args.itemTypes = self.txItemTypes end
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
    -- and what the name index could not see when it was resolved, so the answer to this read
    -- carries the warning that belongs to it and never one from an earlier keyword
    self.txReqGaps = self.txQuery ~= nil and self.txNamesGaps or nil
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

-- The postings of one transaction, over the window openTxDetail recorded: the window the row
-- was selected from, so both sides read the same day files and a row that is on screen can
-- always be opened -- or, for a jump that named the very instant (a receipt's txId and ts), the
-- single civil day it happened on, which is what makes an old transaction readable at all: 62
-- days is a span a read may cover, not an age beyond which a record stops existing. The window
-- is state and not an argument here, so a retry and a refresh ask the same question again
-- instead of inheriting whichever window happened to be around. Its own command and its own
-- requestId keep it clear of the list read.
function Page:requestTxDetail(txId)
    local args = { txId = txId, requestId = self.newRequestId() }
    if self.txDetailFrom then args.fromMs = self.txDetailFrom end
    if self.txDetailTo then args.toMs = self.txDetailTo end
    if not self.send("admin.transaction", args) then
        self.txDetailRetry = txId   -- held by the cooldown: the controller's tick asks again
        return false
    end
    self.txDetailRequestId = args.requestId
    self.txDetailRetry = nil
    self.txDetailError = nil
    self.txDetailTimeout = false
    self.txDetailAnswered = false
    self:showTxDetail(false)   -- a window already up says "reading" again, and nothing reopens
    self:updateEnabled()
    return true
end

-- A keystroke only arms the clock tick() owns: one command per pause in the typing, never one
-- per key, and only ever the last text. The keyword's item set is resolved on the same pause.
function Page:onTxSearch()
    local raw = string.match(entryText(self.txEntry), "^%s*(.-)%s*$")
    local query = raw ~= "" and raw or nil
    if query == self.txQuery then return end
    self.txQuery = query
    self.txF.page = 1
    self.txDirty = true
    self.txNamesDirty = true
    self.txItemTypesError = nil
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

-- 'contains' or 'exact', and it is the keyword's mode only: the account and the item are exact
-- by construction, so this never loosens them.
function Page:onTxMatchMode(button)
    local mode = button.internal
    if mode == self.txMatchMode then return end
    self.txMatchMode = mode
    for _, b in ipairs(self.txModeButtons) do b.active = b.internal == mode end
    self.txF.page = 1
    self.txDirty = true
    self.txNamesDirty = true
    self.txItemTypesError = nil
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

-- ----- the exact account -----

-- A picked candidate, and only a picked candidate, sets the account: the box the picker owns is
-- a way to find a name, not the condition itself. So a longer username typed over a shorter one
-- never quietly changes which account the page is reading, and a keyword typed afterwards never
-- changes it either.
function Page:onAccountPicked(entry)
    local name = type(entry) == "table" and entry.username or entry
    if type(name) ~= "string" or name == "" or #name > TX_ACCOUNT_BYTES then return end
    self.txAccountPicker:setText(name)
    if self.txAccount == name then return end
    self.txAccount = name
    self.txF.page = 1
    self.txDirty = true
    self.txQueryAt = nil
    self:layout()
end

function Page:onTxAccountClear()
    self.txAccountPicker:setText("")
    self.txAccountPicker:close()
    if self.txAccount == nil then
        self:layout()
        return
    end
    self.txAccount = nil
    self.txF.page = 1
    self.txDirty = true
    self.txQueryAt = nil
    self:layout()
end

-- ----- the exact item -----

-- The whole item universe this server loaded, the same policy the shop page picks a SKU with: an
-- admin looking for money that moved for an item has to be able to name any item, including the
-- ones no SKU sells.
function Page:onTxItemPick()
    self.txEntry:unfocus()
    self.txAccountPicker:close()
    DatePicker.close(self)
    F.closeCombo(self.txAccountCombo)
    self.itemPicker:open()
    self:layout()
    if C.Keyboard and C.Keyboard.invalidate then pcall(C.Keyboard.invalidate, self.owner.owner) end
end

function Page:onItemPicked(record)
    local fullType = type(record) == "table" and record.fullType or nil
    if type(fullType) ~= "string" or fullType == "" or #fullType > TX_ITEM_BYTES then
        self:layout()
        return
    end
    if self.txItem ~= fullType then
        self.txItem = fullType
        self.txF.page = 1
        self.txDirty = true
        self.txQueryAt = nil
    end
    self:layout()
    if C.Keyboard and C.Keyboard.invalidate then pcall(C.Keyboard.invalidate, self.owner.owner) end
end

function Page:onItemPickCancelled()
    self:layout()
    if C.Keyboard and C.Keyboard.invalidate then pcall(C.Keyboard.invalidate, self.owner.owner) end
end

function Page:onTxItemClear()
    if self.txItem == nil then return end
    self.txItem = nil
    self.txF.page = 1
    self.txDirty = true
    self.txQueryAt = nil
    self:layout()
end

function Page:onTxFilters()
    DatePicker.close(self)
    F.closeCombo(self.txAccountCombo)
    self.txAccountPicker:close()
    self.txEntry:unfocus()
    self.txF.fromEntry:unfocus()
    self.txF.toEntry:unfocus()
    self.txFiltersOpen = not self.txFiltersOpen
    -- the sheet opens at its top: an offset left over from the last time it was open would hide
    -- the first conditions behind a scroll the admin never made
    self.scrollOffset = 0
    self:layout()
    if C.Keyboard then C.Keyboard.invalidate(self.owner.owner) end
end

-- The body of a row reads: the pick is held by tx id, so a page turn or a fresh read still
-- points at the transaction being described, and the record opens in the shared window. Picking
-- the same row again re-opens a window the admin dismissed -- a window that can be closed has to
-- be one that can be opened again.
function Page:onTxSelect(item)
    local id = (type(item) == "table" and type(item.txId) == "string" and item.txId ~= "")
        and item.txId or nil
    if id == nil then
        self.txSelectedTx, self.txSelected = nil, nil
        self:layout()
        return
    end
    self.txSelectedTx = id
    self.txSelected = self:txEntryById(id)
    self:openTxDetail(id, self.txFromMs, self.txToMs)
    self:layout()
end

-- One transaction in the window: the summary the snapshot already carries is readable at once,
-- and the whole record is asked for over the window the row was read from (or the single civil
-- day a jump named), so both sides read the same day files and a row that is on screen can
-- always be opened. The window is recorded before the read leaves, so every later retry of this
-- record asks over the same days; a record already read for this very id is shown again without
-- a second command, and the refresh chip is what re-reads it.
function Page:openTxDetail(txId, fromMs, toMs)
    if type(txId) ~= "string" or txId == "" then return end
    self.txDetailSummary = self:txSummaryText(self:txEntryById(txId))
    if self.txDetailTx ~= txId or self.txDetailFrom ~= fromMs or self.txDetailTo ~= toMs then
        self.txDetailTx = txId
        self.txDetailFrom, self.txDetailTo = fromMs, toMs
        self.txDetail = nil
        self.txDetailText = nil
        self.txDetailError = nil
        self.txDetailTimeout = false
        self.txDetailAnswered = false
        self:requestTxDetail(txId)
    end
    self:showTxDetail(true)
end

-- What the window says about this transaction: the state of the record read, the summary of the
-- row, and the record itself once it has landed. `open` is the explicit gesture (a pick) and is
-- the only thing that may put the window back on screen: an answer that came back after the
-- admin closed it updates nothing and revives nothing (D.update says so, and is believed).
function Page:showTxDetail(open)
    local id = self.txDetailTx
    if id == nil then return false end
    if open == true and not self:getIsVisible() then
        -- the jump from another tab sets the record up before the controller has switched to
        -- this page: a window opened over a page that is not on screen yet would close itself on
        -- the very next frame, so it waits for setVisible
        self.txDetailOpenPending = true
        return false
    end
    local key = "tx:" .. id
    local title = getText(T .. "Admin_Tx_Id", id)
    local body = self:txDetailNoteText(self:txDetailStatus())
    if self.txDetailSummary ~= nil then body = body .. "\n\n" .. self.txDetailSummary end
    if self.txDetailText ~= nil then body = body .. "\n\n" .. self.txDetailText end
    if open == true then
        self.txDetailOpenPending = nil
        return Detail.open(self, key, title, body, function() self:onTxDetailClosed() end) ~= nil
    end
    return Detail.update(self, key, title, body)
end

-- The window closed (its own chip, Escape, the page hid, or another owner took it over). The
-- pick is left exactly as it is: the row the admin was reading is still the row they were
-- reading, and picking it again opens the record once more.
function Page:onTxDetailClosed()
    self.txDetailSummary = nil
end

-- Everything the *record* read learned, dropped, and the window with it. The selection is not
-- part of it: the list keeps the row picked and every condition it was reading with.
function Page:clearTxDetail()
    self.txDetailTx = nil
    self.txDetail = nil
    self.txDetailText = nil
    self.txDetailSummary = nil
    self.txDetailError = nil
    self.txDetailTimeout = false
    self.txDetailAnswered = false
    self.txDetailRetry = nil
    self.txDetailFrom, self.txDetailTo = nil, nil
    self.txDetailOpenPending = nil
    Detail.close(self)
end

-- Ask the list read again. The failure flags are cleared by the send itself, so a refusal that
-- is still on screen cannot outlive the request that replaces it.
function Page:onTxRetry()
    self.owner.message = nil
    self.txDirty = true
    self.txQueryAt = nil
    if self.txQuery ~= nil and self.txItemTypesError ~= nil then
        -- the keyword's item set is what refused: ask the index again before the server
        self.txNamesDirty = true
        self.txItemTypesError = nil
        self:resolveItemTypes()
    end
    if not self:requestTransactions() then self:rebuildTxNotes() end
    self:layout()
end

-- Every filter the server reads with, back to its default, as one request: the keyword and its
-- mode, the exact account, the exact item, the source, the currency, the account class and both
-- days. The sort and the page belong to this side and are reset with them, so the list reads
-- exactly like a page that was just opened.
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
    self.txMatchMode = "contains"
    for _, b in ipairs(self.txModeButtons) do b.active = b.internal == "contains" end
    self.txAccount = nil
    self.txAccountPicker:setText("")
    self.txAccountPicker:close()
    self.txItem = nil
    self.txNamesDirty = true
    self.txItemTypes, self.txItemTypesKey = nil, ""
    self.txItemTypesError, self.txNamesWait = nil, false
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
    self.txBlockedBy = nil
    self.txDirty = true
    -- a chip, not typing: exactly one request goes out on the next frame, and the debounce clock
    -- is cleared so a half-typed day cannot queue a second one behind it
    self.txQueryAt = nil
    self:layout()
end

-- The jump every other page takes into the money view. `filters` is a table and only a table:
--   account   an exact username (a receipt, a lookup, a listing owner)
--   item      an exact fullType (the shop's own lookup)
--   query     free text, the caller's own stable value
--   txId + ts one committed transaction: the days are set to the single civil day it happened
--             on, and its whole record opens straight away
-- The filter is set before the tab switch, so the page's first read is already the filtered one
-- instead of a full read followed a frame later by the real one. The controller calls this and
-- then switches the tab itself.
--
-- Everything the caller did NOT name goes back to its default -- the source stays as asked, but
-- the currency, the account class, the match mode and (without a ts) the days are cleared --
-- because a shortcut asks a fresh question: leaving last week's range or another currency on
-- would answer a different one and say nothing about it.
function Page:show(group, filters)
    filters = type(filters) == "table" and filters or {}
    local f = self.txF
    f.kind = group or "all"
    f.page = 1
    for _, b in ipairs(f.kindButtons) do b.active = (not b.unused) and b.internal == f.kind end
    self.txKindSig = f.kind
    local q = string.match(tostring(filters.query or ""), "^%s*(.-)%s*$") or ""
    -- the query is set before the box is written, so the box's own change hook (which compares
    -- against this very field) cannot mistake the caller's value for typing and delay the first
    -- read behind the debounce
    self.txQuery = q ~= "" and q or nil
    setEntryText(self.txEntry, q)
    self.txMatchMode = "contains"
    for _, b in ipairs(self.txModeButtons) do b.active = b.internal == "contains" end
    self.txNamesDirty = true
    self.txItemTypes, self.txItemTypesKey = nil, ""
    self.txItemTypesError, self.txNamesWait = nil, false
    local account = filters.account
    account = (type(account) == "string" and account ~= "" and #account <= TX_ACCOUNT_BYTES)
        and account or nil
    self.txAccount = account
    self.txAccountPicker:setText(account or "")
    self.txAccountPicker:close()
    local item = filters.item
    self.txItem = (type(item) == "string" and item ~= "" and #item <= TX_ITEM_BYTES) and item or nil
    self.itemPicker:close()
    self.offsetMin = self.owner.offsetMin
    local txId = (type(filters.txId) == "string" and filters.txId ~= "") and filters.txId or nil
    local ts = tonumber(filters.ts)
    local day = (txId ~= nil and ts ~= nil) and dateText(ts, self.offsetMin) or ""
    setEntryText(f.fromEntry, day)
    setEntryText(f.toEntry, day)
    DatePicker.close(self)
    self.txDateSig = entryText(f.fromEntry) .. "\1" .. entryText(f.toEntry)
    self.txCurrency = nil
    for _, b in ipairs(self.txCurButtons) do b.active = b.internal == "all" end
    self.txAccountClass = nil
    if self.txAccountCombo then
        F.closeCombo(self.txAccountCombo)
        self.txAccountCombo:setSelectedData("all")
    end
    -- a refusal still on screen belongs to the question that was just replaced
    self.txListError = nil
    self.txListTimeout = false
    self.txBlockedBy = nil
    self.txDirty = true
    self.txQueryAt = nil
    self:clearTxDetail()
    -- the named row is the picked row, and its record opens straight away
    self.txSelectedTx = txId
    self.txSelected = nil
    self.txFiltersOpen = false
    self:rebuildTransactions()
    if txId ~= nil then
        local from = day ~= "" and EC.parseDay(day, self.offsetMin) or nil
        self:openTxDetail(txId, from, from and (from + 86400000) or nil)
    end
end

-- ----- modal state (what this page puts over itself) -----

-- The item overlay eats the whole page while it is up; the account picker's candidate list does
-- not (it is a drop-down over one row), so it is never a modal state -- only an Escape target.
function Page:isModal()
    return self.itemPicker:getIsVisible()
end

function Page:onEscape()
    if self.itemPicker:getIsVisible() then
        self.itemPicker:cancel()
        self:layout()
        return true
    end
    -- the candidate list folds first, and the window behind it is left alone
    if self.txAccountPicker:isOpen() then
        self.txAccountPicker:close()
        if C.Keyboard and C.Keyboard.invalidate then pcall(C.Keyboard.invalidate, self.owner.owner) end
        return true
    end
    return false
end

-- ----- keyboard targets (C.Keyboard walks these; this page owns no key dispatch) -----

-- The controls of the money view that is open, in the order a keyboard should reach them: every
-- chip, both pickers, the summary band and the selected row's own action button. The controller
-- answers with an empty table while another sub page is up, so the root only ever offers what is
-- on screen.
function Page:keyboardTargets()
    if self.itemPicker:getIsVisible() then return self.itemPicker:keyboardTargets() end
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
    local f = self.txF
    -- the sheet's viewport, while the conditions do not fit it whole: Home / End / PageUp /
    -- PageDown move it, and the rows that were off it come back onto this list as they arrive
    if self.txFiltersOpen == true and self:maxScrollOffset() > 0 then
        out[#out + 1] = { kind = "scroll", label = tr("Admin_Tx_Filters"), control = self,
            focusable = false }
    end
    add("entry", tr("Admin_Tx_SearchLabel"), self.txEntry)
    group(tr("Admin_Tx_Match"), self.txModeButtons)
    for _, desc in ipairs(self.txAccountPicker:keyboardTargets()) do out[#out + 1] = desc end
    group(tr("Admin_Tx_AccountExact"), { self.txAccountClearButton })
    group(tr("Admin_Tx_Item"), { self.txItemButton, self.txItemClearButton })
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

-- Does this reply still belong to a read this page has open? Asked by the controller for every
-- command before it frees the shared slot, and answered without touching a single field: a stale
-- reply must not release the slot owned by a newer read. Three commands are this page's --
-- admin.transactions, admin.transaction, and the account picker's admin.players.
function Page:matchesReply(kind, args)
    -- the candidate read is the picker's: it answers by its own requestId and context, without
    -- consuming the reply. A players answer this page never asked for must not release the slot
    -- the player page (or a newer candidate read) is holding, so this is asked before the
    -- requestId shortcut below -- a players reply with no requestId is nobody's.
    if kind == "players" then return self.txAccountPicker:owns(args) == true end
    if args.requestId == nil then return true end
    local expected
    if kind == "transactions" then expected = self.txRequestId
    elseif kind == "transaction" then expected = self.txDetailRequestId
    else return true end
    return expected == nil or args.requestId == expected
end

-- The account picker's own read. The controller routes an admin.players reply here by its
-- context, and the picker answers whether it was the one asking: nothing about the list read or
-- the player page is touched either way.
function Page:onPlayersReply(args)
    local picker = self.txAccountPicker
    if picker == nil then return false end
    return picker:onReply(args) == true
end

-- The server says the money view changed. A notification is not a snapshot: the page only marks
-- itself for one read (the visible page takes it on the next tick, through the same debounce and
-- in-flight gate), and it never drops what is on screen.
function Page:onViewChanged(scope)
    if scope ~= "transactions" then return end
    self.txDirty = true
    self.txQueryAt = nil
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
        -- the same for the index gaps: the rows below answer a question that was asked with an
        -- incomplete set of names, and they say so
        self.txSnapGaps = self.txReqGaps
        -- the range the server actually read; the detail read quotes it back so both sides look
        -- in the same files
        self.txFromMs = tonumber(args.fromMs)
        self.txToMs = tonumber(args.toMs)
        -- the picked row either survives this answer or it is not in it: a summary of a
        -- transaction the current conditions do not return would describe nothing on screen
        self:syncSelection()
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
            self:showTxDetail(false)
            self:updateEnabled()
            return
        end
        local entries = type(args.entries) == "table" and args.entries or {}
        -- an empty answer is an answer: the id is not in the files the range covers. A read that
        -- never came back is a different thing and is never folded into this one.
        self.txDetail = type(entries[1]) == "table" and entries[1] or nil
        self.txDetailError = nil
        self.txDetailTimeout = false
        self.txDetailAnswered = true
        self.txDetailText = self:txRecordText(self.txDetail)
        -- a window the admin closed while this read was out stays closed
        self:showTxDetail(false)
    else
        return
    end
    self:updateEnabled()
end

-- The controller keeps the shared command timeout and its footer line; the page keeps what the
-- two money reads say about themselves. Neither read drops the rows that are up.
function Page:onTimeout(command)
    if command == "admin.transaction" then
        -- the answer is never coming. This is *not* "the transaction does not exist": the window
        -- says timed out, and picking the row again (or the refresh chip) asks once more.
        self.txDetailRetry = nil
        self.txDetailTimeout = true
        self.txDetailAnswered = false
        self:showTxDetail(false)
    elseif command == "admin.transactions" then
        -- the rows that are up stay up; the status line says the read timed out, and the retry
        -- chip is what asks again (a dead server is never hammered by the debounce)
        self.txListTimeout = true
        self:rebuildTxNotes()
    elseif command == "admin.players" then
        -- the candidate read the account picker owns: it drops its own in-flight bookkeeping and
        -- asks again on the next pause. The account already picked is untouched.
        self.txAccountPicker:onTimeout()
    end
end

-- ----- data normalisation (data or geometry changes only) -----

function Page:updateTxText()
    U.setWrappedText(self.txNotesBox, self.txNotesText, self.txNotesBox.width)
end

-- One transaction: "kind / item xN" over "time / tx id / the accounts it touched", and the
-- per-currency movement on the right. The row carries no control at all -- picking it is what
-- opens the record -- so every pixel of the width is text.
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
            -- keeps the highlight on the very transaction the window is describing
            if self.txSelectedTx ~= nil and rows[#rows].txId == self.txSelectedTx then selected = #rows end
        end
    end
    self.txRows = rows
    self.txList:setItems(rows)
    self.txList:setSelectedIndex(selected)
end

-- One entry of the snapshot by its transaction id: what the window's summary reads. The
-- snapshot is at most 200 rows and this runs on a pick, never per frame.
function Page:txEntryById(txId)
    local snap = self.transactions
    local src = (snap and type(snap.entries) == "table") and snap.entries or {}
    for _, e in ipairs(src) do
        if type(e) == "table" and tostring(e.txId or "") == txId then return e end
    end
    return nil
end

-- A new snapshot either still holds the picked transaction or it does not. It is re-read by id
-- (the row objects are rebuilt every time) and dropped when the new conditions do not return
-- it; the layout that follows the reply is what re-writes the summary band.
function Page:syncSelection()
    if self.txSelectedTx == nil then return end
    local entry = self:txEntryById(self.txSelectedTx)
    if entry == nil then
        self.txSelectedTx = nil
        self.txSelected = nil
    else
        self.txSelected = entry
    end
end

-- The filter the snapshot on screen was read with. Comparing it against the row's current
-- state is what tells an old answer apart from the answer to the question being asked now: the
-- resolved item set is part of it, so an index that finished loading between two reads makes the
-- rows say so instead of passing for the new answer.
function Page:txFilterSig()
    local f = self.txF
    return tostring(self.txQuery or "") .. "\1" .. tostring(f.kind)
        .. "\1" .. tostring(self.txCurrency or "") .. "\1" .. tostring(self.txAccountClass or "")
        .. "\1" .. entryText(f.fromEntry) .. "\1" .. entryText(f.toEntry)
        .. "\1" .. tostring(self.txMatchMode) .. "\1" .. tostring(self.txAccount or "")
        .. "\1" .. tostring(self.txItem or "") .. "\1" .. tostring(self.txItemTypesKey or "")
end

function Page:txStale()
    if self.transactions == nil then return false end
    return self.txSnapSig ~= self:txFilterSig()
end

-- What the list is showing, as exactly one state. Read off the snapshot and the read flags, not
-- off the row count alone: a read that failed before any snapshot arrived is not "loading", a
-- read that never came back is not "no matching transactions", rows that answer a question the
-- admin has since changed are not an answer to the new one, and a question this side has not
-- been able to ask yet is none of those things either.
function Page:txListStatus()
    if self.txBlockedBy ~= nil then return "blocked" end
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
    if state == "blocked" then
        local why = self.txBlockedBy
        if why == "names_loading" then return tr("Admin_Tx_NamesLoading") end
        if why == "item_query_too_broad" then return tr("Admin_Tx_ItemTooBroad") end
        if why == "query_too_long" then return tr("Admin_Tx_QueryTooLong") end
        return getText(T .. "Admin_Tx_ItemUnavailable", errorText(why))
    end
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
    -- The keyword this snapshot was read with was resolved against an index that could not read
    -- every MOD. Every one of them is named -- the box scrolls and Ctrl+C copies it whole, so
    -- the list is never cut -- and the warning says what an empty result does not prove.
    local gaps = self.txSnapGaps
    if gaps ~= nil then
        local lines = { tr("Admin_Tx_NamesIncomplete") }
        for _, gap in ipairs(gaps) do
            lines[#lines + 1] = gap.modId .. ": " .. errorText(gap.reason)
        end
        lines[#lines + 1] = self.txNotesText
        self.txNotesText = table.concat(lines, "\n")
    end
    self:updateTxText()
end

-- The picked transaction, spelled out from the row the server already sent: the whole amount of
-- every currency, every account by name and raw key, the item and its lot, the origin and the
-- posting count -- never fitted to a width, never rounded, never a 0 standing in for something
-- the event did not carry. The reason *text* and the postings themselves are what the record
-- read carries, so this block never claims to be the whole record. nil when the conditions on
-- screen do not return that row at all (a jump straight to an id).
function Page:txSummaryText(e)
    if type(e) ~= "table" then return nil end
    local out = { tr("Admin_Tx_PreviewHint") }
    local function pair(label, value)
        out[#out + 1] = getText(T .. "Admin_Tx_Pair", label, value)
    end
    pair(tr("Admin_Tx_Field_Id"), tostring(e.txId or "-"))
    pair(tr("Wallet_Col_Time"), stampText(e.ts, self.offsetMin))
    local kind = tostring(e.kind or "?")
    pair(tr("Admin_Tx_Field_Kind"), (getTextOrNull(T .. "Kind_" .. kind) or kind)
        .. "  /  " .. txGroupText(e.group))
    pair(tr("Admin_Tx_Amount"), txAmountText(e.amounts))
    pair(tr("Admin_Tx_Account"), txAccountsText(e.accounts))
    if type(e.item) == "string" and e.item ~= "" then
        local label = itemName(e.item) .. "  (" .. e.item .. ")"
        local qty = tonumber(e.qty)
        if qty ~= nil and qty > 1 then
            label = label .. "  " .. getText(T .. "Market_Lot", tostring(math.floor(qty)))
        end
        pair(tr("Admin_Tx_Field_Item"), label)
    elseif type(e.sku) == "string" and e.sku ~= "" then
        pair(tr("Admin_Tx_Field_Sku"), e.sku)
    end
    if type(e.category) == "string" and e.category ~= "" then
        pair(tr("Admin_Tx_Field_Category"), U.categoryText(e.category))
    end
    pair(tr("Admin_Tx_Field_Origin"), txSourceName(e))
    if type(e.reasonCode) == "string" and e.reasonCode ~= "" then
        pair(tr("Admin_Tx_Field_ReasonCode"), e.reasonCode)
    end
    -- a count the row did not carry is a dash: "0 postings" would describe a transaction that
    -- moved nothing, which is not what an absent field says
    local postings = tonumber(e.postingCount)
    pair(tr("Admin_Tx_Field_Postings"), postings ~= nil and tostring(math.floor(postings)) or "-")
    if e.rolledBack == true then out[#out + 1] = tr("Wallet_RolledBack") end
    return table.concat(out, "\n")
end

-- Every field of one committed transaction as plain lines, and nothing left out: the origin, the
-- request id, every reference id, every account by its raw key, the whole reason and every
-- posting with both balance chains. The window wraps this for the width it has; the value
-- returned here is the one CopyAll hands over, so a copied record keeps its own line breaks.
function Page:txRecordText(d)
    if type(d) ~= "table" then return nil end
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
    -- the SKU's catalog category, where the event carried one: a shop movement is reconciled
    -- against the catalog row it came from, and the category is part of that row now
    if type(d.category) == "string" and d.category ~= "" then
        pair(tr("Admin_Tx_Field_Category"), U.categoryText(d.category))
    end
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
    return table.concat(out, "\n")
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
    for _, b in ipairs(self.txModeButtons) do b:setEnable(txRead) end
    self.txClearButton:setEnable(txRead)
    self.txFilterButton:setEnable(txRead)
    self.txRetryButton:setEnable(txRead and not self.isPending("admin.transactions"))
    self.txAccountClearButton:setEnable(txRead and self.txAccount ~= nil)
    self.txItemButton:setEnable(txRead)
    self.txItemClearButton:setEnable(txRead and self.txItem ~= nil)
    -- a dialog owns the panel: the box greys out and the candidate list must not hang over it
    self.txAccountPicker:setEditable(txRead)
    -- the note box is set read-only once, in createChildren, and never touched here: every pass
    -- through this function would otherwise drop the keyboard out of it mid-scroll
end

-- ----- the filter sheet's viewport -----

-- A short window folds the conditions into a sheet, and a sheet is a form: the exit row is pinned
-- to the bottom of the page and the conditions above it are one scrolling column. The offset is
-- the page's own -- every control is placed explicitly by layout(), so the engine's scroll is
-- never used -- and it answers both the keyboard's scroll contract (ECKeyboard:525) and the
-- native ISScrollBar, which speaks in negative offsets. The same contract the shop editor's
-- field area answers.
function Page:maxScrollOffset()
    return math.max(0, (self.sheetContentH or 0) - (self.sheetViewH or 0))
end

function Page:getScrollHeight() return self.sheetContentH or 0 end
function Page:getScrollAreaHeight() return self.sheetViewH or 0 end
function Page:getYScroll() return -(self.scrollOffset or 0) end
function Page:setYScroll(value) self:setScrollOffset(-value) end

function Page:setScrollOffset(offset)
    local clamped = math.max(0, math.min(offset, self:maxScrollOffset()))
    if clamped == (self.scrollOffset or 0) then return end
    self.scrollOffset = clamped
    self:layout()
    -- the rows that came on and off the sheet came on and off the keyboard's list with them
    if C.Keyboard and C.Keyboard.invalidate then pcall(C.Keyboard.invalidate, self.owner.owner) end
end

function Page:onMouseWheel(del)
    if self:maxScrollOffset() <= 0 then return false end
    self:setScrollOffset((self.scrollOffset or 0) + del * lineH() * 3)
    return true
end

-- ----- geometry -----

-- Every row below places exactly one band of conditions at the y it is given and answers with the
-- height it took, so the card and the sheet are the same rows in two orders and neither invents a
-- geometry of its own. `visible` is the page's answer for that row alone: on the sheet a row that
-- does not fit the viewport whole is off the sheet, and a row that is off it keeps neither the
-- engine's text focus nor a popup.

-- The keyword and the mode it is matched with: the mode sits with the keyword, never with the
-- exact conditions beside it.
function Page:layoutTxKeyword(visible, y, w, eh, ch)
    local g = self.g
    g.txSearchLabelY = y + math.floor((eh - fontH.small) / 2)
    local x = PAD + textWidth(tr("Admin_Tx_SearchLabel")) + 6
    if not visible and self.txEntry:isFocused() then self.txEntry:unfocus() end
    self.txEntry:setVisible(visible)
    self.txEntry:setX(x); self.txEntry:setY(y)
    self.txEntry:setWidth(math.min(240, math.floor(w * 0.28))); self.txEntry:setHeight(eh)
    g.txModeLabelX = x + self.txEntry.width + PAD
    local modeX = g.txModeLabelX + textWidth(tr("Admin_Tx_Match")) + 6
    for _, button in ipairs(self.txModeButtons) do
        button:setVisible(visible)
        button:setWidth(math.min(textWidth(button.fullTitle) + 20, math.max(24, math.floor(w * 0.14))))
        button:setHeight(ch); button:setX(modeX); button:setY(y + math.floor((eh - ch) / 2))
        U.setButtonTitle(button, button.fullTitle)
        modeX = modeX + button.width + 4
    end
    return eh
end

-- Every currency this server runs, with "all" in the first slot.
function Page:layoutTxCurrency(visible, y, w, ch)
    local g = self.g
    g.txCurTextY = y + math.floor((ch - fontH.small) / 2)
    g.txCurLabelX = PAD
    local x = PAD + textWidth(tr("Admin_Tx_Currency")) + 6
    for _, button in ipairs(self.txCurButtons) do
        button:setVisible(visible)
        button:setWidth(math.min(textWidth(button.fullTitle) + 20, math.max(24, math.floor(w * 0.14))))
        button:setHeight(ch); button:setX(x); button:setY(y)
        U.setButtonTitle(button, button.fullTitle)
        x = x + button.width + 4
    end
    return ch
end

-- The page's source chips -- a fixed enumeration (F.kinds is fed once, in createChildren), so a
-- search that matched nothing still offers every other source to switch to -- with the range hint
-- on their right. `w` is the row's own width: the sheet keeps a gutter for its scrollbar, so the
-- hint never lands under it.
function Page:layoutTxKinds(visible, y, w, ch)
    local g = self.g
    g.txGroupY = y
    g.txRangeHintY = y + math.floor((ch - fontH.small) / 2)
    g.txHintRight = PAD + w
    F.layoutKinds(self.txF, visible, PAD, y, math.max(60, w - (g.txHintW or 0) - PAD), ch)
    return ch
end

-- The shared date / sort / page / account-class row. It wraps into as many bands as the width
-- forces, so its height is whatever F measured; a calendar left open over a row that is no longer
-- on screen goes with it.
function Page:layoutTxRange(visible, y, w, eh, ch)
    local g = self.g
    g.txRowY = y
    F.layoutRow(self.txF, visible, PAD, y, math.max(60, w), eh, ch)
    if not visible then DatePicker.close(self) end
    return self.txF.rowH
end

-- The exact-account row: the shared player picker's box (its candidate list drops over whatever
-- is under it) with its clear chip, then the item picker's button with its own. Both conditions
-- read as what they are -- the account and the item currently locked -- and neither is ever
-- changed by the keyword next to them. `w` is the width the row shares out: the page's own,
-- less the sheet's scrollbar gutter while that is what the row sits in.
function Page:layoutTxCriteria(visible, y, w, eh)
    local g = self.g
    local ch = chipH()
    local chipY = y + math.floor((eh - ch) / 2)
    g.txAccountLabelY = y + math.floor((eh - fontH.small) / 2)
    -- the row is budgeted, never natural: the two labels and the four gaps come off the card
    -- first, and what is left is shared out, so a long translation shortens a control instead of
    -- pushing one off the card
    local accountLabelW = textWidth(tr("Admin_Tx_AccountExact")) + 6
    local itemLabelW = textWidth(tr("Admin_Tx_Item")) + 6
    local budget = math.max(120, w - PAD * 2 - accountLabelW - itemLabelW - 12 - PAD)
    local pickW = math.max(60, math.floor(budget * 0.34))
    local clearW = math.min(textWidth(self.txAccountClearButton.fullTitle) + 20,
        math.max(24, math.floor(budget * 0.16)))
    local itemClearW = math.min(textWidth(self.txItemClearButton.fullTitle) + 20,
        math.max(24, math.floor(budget * 0.16)))
    -- the button says which item is locked, so the condition is readable without opening it
    local label = self.txItem ~= nil and getText(T .. "Admin_Tx_ItemPicked", itemName(self.txItem))
        or tr("Admin_Pick_Title")
    local itemW = math.min(textWidth(label) + 20,
        math.max(48, budget - pickW - clearW - itemClearW))
    local x = PAD + accountLabelW
    self.txAccountPicker:setVisible(visible)
    -- the candidate list may use everything under the box; the page is the only clip
    self.txAccountPicker:layout(x, y, pickW, math.max(eh, self.height - y - PAD))
    x = x + pickW + 6
    self.txAccountClearButton:setVisible(visible)
    self.txAccountClearButton:setX(x); self.txAccountClearButton:setY(chipY)
    self.txAccountClearButton:setWidth(clearW); self.txAccountClearButton:setHeight(ch)
    U.setButtonTitle(self.txAccountClearButton, self.txAccountClearButton.fullTitle)
    x = x + clearW + PAD
    g.txItemLabelX = x
    x = x + itemLabelW
    self.txItemButton.fullTitle = label
    self.txItemButton:setVisible(visible)
    self.txItemButton:setX(x); self.txItemButton:setY(chipY)
    self.txItemButton:setWidth(itemW); self.txItemButton:setHeight(ch)
    U.setButtonTitle(self.txItemButton, label)
    x = x + itemW + 6
    self.txItemClearButton:setVisible(visible)
    self.txItemClearButton:setX(x); self.txItemClearButton:setY(chipY)
    self.txItemClearButton:setWidth(itemClearW); self.txItemClearButton:setHeight(ch)
    U.setButtonTitle(self.txItemClearButton, self.txItemClearButton.fullTitle)
    -- what is actually locked, on the right of the row: a picked account is a fact about the
    -- read, not a hint in a box the admin may have typed over since. It is dropped only when
    -- the card has no room for it at all -- the summary band and the rows still name the
    -- account, so nothing is lost by not painting a two-letter stub here.
    local restW = w - PAD - (x + itemClearW + PAD)
    g.txLockedX = x + itemClearW + PAD
    g.txLockedText = (self.txAccount ~= nil and restW >= 40)
        and fitText(getText(T .. "Admin_Tx_AccountPicked", self.txAccount), restW)
        or nil
end

-- Short windows use a filter sheet; results and complete information keep real viewports.
function Page:layout()
    local w, h = self.width, self.height
    local lh, eh = lineH(), entryH()
    local pageH = chipH()
    local lstW = math.max(160, w - PAD * 2)
    local g = {}
    self.g = g
    -- the window owns the zone; the calendar popup reads it off whichever panel attached the box
    self.offsetMin = self.owner.offsetMin
    local on = self:getIsVisible()
    local txTop, txBottom = CARD_TITLE_H + 4, h
    local infoH = fontH.small * 2 + 8
    g.txHintW = math.min(textWidth(tr("Admin_Tx_RangeHint")), math.floor(w * 0.3))
    -- the first pass only decides whether the card is a compact one: five condition rows
    -- (keyword, the two exact conditions, the currencies, the sources) over the shared row
    self:layoutTxKinds(on, txTop + eh * 2 + pageH + 12, lstW, pageH)
    local probeH = self:layoutTxRange(on, g.txGroupY + pageH + 4, lstW, eh, pageH)
    local fullActionY = g.txRowY + probeH + 4
    self.txCompact = txBottom - lh - fullActionY - pageH - infoH - 12 < listRowH() * 2
    local filterSheet = self.txCompact and self.txFiltersOpen == true
    local results = on and not filterSheet
    local showFilters = on and (not self.txCompact or filterSheet)
    self.txFilterButton.fullTitle = tr(filterSheet and "Admin_Tx_Results" or "Admin_Tx_Filters")
    local actionY, pagerSpace = txTop, 0
    if filterSheet then
        -- The exit row is pinned to the bottom of the page: the way out of the sheet (and Clear
        -- and Retry with it) is a real button at every size, never something the conditions above
        -- it pushed past the page's edge. What is left is the viewport, and the conditions scroll
        -- inside it -- clamping them under the pinned row would only hide the last ones.
        --
        -- The shared row rides straight under the keyword here, ahead of the exact conditions and
        -- the two chip sets: those narrow a question that already has a range and a page, and a
        -- sheet whose primary controls need a scroll before they appear is a sheet an admin
        -- cannot use.
        actionY = h - PAD - pageH
        local top = 4
        local viewH = math.max(pageH, actionY - 6 - top)
        local rowW = math.max(60, lstW - SHEET_GUTTER)
        local sheetW = math.max(120, w - SHEET_GUTTER)
        -- measured at the sheet's own width, which is the width it is placed at below
        local rangeH = self:layoutTxRange(true, top, rowW, eh, pageH)
        local contentH = eh * 2 + rangeH + pageH * 2 + 16
        self.sheetContentH, self.sheetViewH = contentH, viewH
        local maxOffset = math.max(0, contentH - viewH)
        local offset = math.max(0, math.min(self.scrollOffset or 0, maxOffset))
        self.scrollOffset = offset
        local bottom = top + viewH
        local y = top - offset
        local shown = showFilters and y >= top and y + eh <= bottom
        self:layoutTxKeyword(shown, y, sheetW, eh, pageH)
        y = y + eh + 4
        shown = showFilters and y >= top and y + rangeH <= bottom
        self:layoutTxRange(shown, y, rowW, eh, pageH)
        y = y + rangeH + 4
        shown = showFilters and y >= top and y + eh <= bottom
        self:layoutTxCriteria(shown, y, sheetW, eh)
        y = y + eh + 4
        shown = showFilters and y >= top and y + pageH <= bottom
        self:layoutTxCurrency(shown, y, sheetW, pageH)
        y = y + pageH + 4
        shown = showFilters and y >= top and y + pageH <= bottom
        self:layoutTxKinds(shown, y, rowW, pageH)
        local bar = self.txSheetBar
        bar:setVisible(showFilters and maxOffset > 0)
        bar:setX(w - PAD - 17); bar:setY(top)
        bar:setWidth(17); bar:setHeight(viewH)
    else
        -- the card: the five condition rows top down, the shared row last, and the list under them
        self:layoutTxKeyword(showFilters, txTop, w, eh, pageH)
        self:layoutTxCriteria(showFilters, txTop + eh + 4, w, eh)
        self:layoutTxCurrency(showFilters, txTop + eh * 2 + 8, w, pageH)
        self:layoutTxKinds(showFilters, txTop + eh * 2 + pageH + 12, lstW, pageH)
        local rangeH = self:layoutTxRange(showFilters, g.txGroupY + pageH + 4, lstW, eh, pageH)
        self.sheetContentH, self.sheetViewH = 0, 0
        self.txSheetBar:setVisible(false)
        if showFilters then actionY = g.txRowY + rangeH + 4 end
        pagerSpace = self.txCompact and (pageH * 2 + 12) or 0
    end
    txButtonRow(self.txActionButtons, on, PAD, actionY, lstW - pagerSpace, pageH,
        not self.txCompact and self.txFilterButton or nil)
    if on and self.txCompact and not filterSheet then
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
    -- the rows get the whole workspace under the note: the record they describe is a window of
    -- its own, so nothing here has to be traded for it
    local txListY = noteY + infoH + 4
    local listH = g.txSelectY - 4 - txListY
    U.placeList(self.txList, results, PAD, txListY, lstW, math.max(1, listH))

    self.itemPicker:setX(0); self.itemPicker:setY(0)
    self.itemPicker:resize(w, h)

    self:rebuildTxNotes()
    self:rebuildTransactions()
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
        -- the item-name index is loaded on demand and only ever once: this is the page that
        -- needs it, so this is where it starts
        if self.txQuery ~= nil then self.txNamesDirty = true end
        -- a record a jump asked for while this page was still off screen
        if self.txDetailOpenPending == true then self:showTxDetail(true) end
    else
        DatePicker.close(self)
        F.closeCombo(self.txAccountCombo)
        F.blurDates(self.txF)
        self.txAccountPicker:close()
        self.itemPicker:close()
        pcall(function() self.txEntry:unfocus() end)
        self.txDetailOpenPending = nil
        Detail.close(self)
    end
    if self.txList ~= nil and (was ~= visible or offsetChanged) then self:layout() end
end

-- ----- drawing -----

-- One view: the list of committed transactions. It is a read, so nothing it draws is ever armed
-- by write permission, and one transaction's record is painted by the detail window, not here.
function Page:prerender()
    if self.txSheetBar:getIsVisible() then self.txSheetBar:updatePos() end
    self:drawTxList()
end

function Page:render() end

-- The note and the status line the list view draws above its rows, wrapped by rebuildTxNotes so
-- the card could reserve exactly the room they need: nothing important is ever fitted to one
-- line and cut. Seven states are told apart, so a first read that failed never reads as
-- "loading", a timeout never reads as "no matching transactions", a question this side could not
-- ask yet says why, and rows that answer a question the admin has since changed say so instead
-- of pretending to answer the new one.
function Page:drawTxList()
    local g = self.g
    if not (self.txCompact and self.txFiltersOpen) then
        card(self, 0, 0, self.width, self.height, tr("Admin_Tx_Title"))
    end
    local f = self.txF
    -- the shared row's own labels; F draws nothing while that row is off the sheet
    F.draw(f, self)
    if self.txEntry:getIsVisible() then
        text(self, tr("Admin_Tx_SearchLabel"), PAD, g.txSearchLabelY, "textMuted")
        text(self, tr("Admin_Tx_Match"), g.txModeLabelX, g.txSearchLabelY, "textMuted")
    end
    if self.txAccountClearButton:getIsVisible() then
        text(self, tr("Admin_Tx_AccountExact"), PAD, g.txAccountLabelY, "textMuted")
        text(self, tr("Admin_Tx_Item"), g.txItemLabelX, g.txAccountLabelY, "textMuted")
        if g.txLockedText then text(self, g.txLockedText, g.txLockedX, g.txAccountLabelY, "accent") end
    end
    if self.txCurButtons[1]:getIsVisible() then
        text(self, tr("Admin_Tx_Currency"), g.txCurLabelX, g.txCurTextY, "textMuted")
    end
    if f.kindButtons[1]:getIsVisible() then
        -- F.draw paints the source label with the shared row; the sheet can scroll the two apart,
        -- and a chip row without its label is not a readable condition
        if f.kindLabelX and not f.fromEntry:getIsVisible() then
            text(self, f.kindLabel, f.kindLabelX, f.kindLabelY, "textFaint")
        end
        textRight(self, fitText(tr("Admin_Tx_RangeHint"), g.txHintW), g.txHintRight, g.txRangeHintY, "textMuted")
    end
    if self.txList:getIsVisible() then
        local hint = tr("Admin_Tx_Select")
        if self.txCompact then
            hint = tostring(self.txF.page) .. "/" .. tostring(self.txF.pages or 1) .. "  " .. hint
        end
        text(self, fitText(hint, self.width - PAD * 2), PAD, g.txSelectY, "textMuted")
    end
end

-- ----- lifecycle -----

-- A refresh re-reads the list, and the record on screen with it: a window left open over a
-- transaction must not go stale because the list was refreshed under it. The controller has
-- already checked read permission and the command cooldown guards the rest.
function Page:refresh()
    self:requestTransactions()
    if self.txDetailTx ~= nil and Detail.isOpen(self, "tx:" .. self.txDetailTx) then
        self:requestTxDetail(self.txDetailTx)
    end
end

-- The clock the controller drives while this page is the one on screen and reading is allowed.
-- The list's search box and filter row share it: a typed word (or a typed day) costs one command
-- per pause, a chip costs one on the next frame. The item-name index is stepped by the same
-- clock and asked exactly once per keyword, so the read that needs it waits for it instead of
-- going out under half an index. The sent state is recorded when the request leaves -- never when
-- the answer lands -- so a server that says "busy" is reported once instead of asked again in a
-- loop; the 30 s poll and the retry chip are what retry.
function Page:tick(now)
    self.txAccountPicker:tick(now)
    self.itemPicker:tick(now)
    -- number compares only while nothing moved: the keyword's item set is resolved when the
    -- keyword or the mode changed, while the index is still loading, and once more when the
    -- index reaches its terminal state (revision bumps exactly once)
    if self.txNamesDirty == true or self.txNamesWait == true
        or (self.txQuery ~= nil and self.txNamesRev ~= nil
            and (tonumber(ItemNames.revision) or 0) ~= self.txNamesRev) then
        self:resolveItemTypes()
    end
    if self.txQueryAt and now - self.txQueryAt > TX_DEBOUNCE_MS then
        self.txQueryAt = nil
        self:requestTransactions()
    elseif not self.txQueryAt and (self.txDirty == true or self.txAsked ~= true) then
        self:requestTransactions()
    end
    -- the record read is its own command: a list read in flight must never starve it
    if self.txDetailRetry ~= nil and not self.isPending("admin.transaction") then
        self:requestTxDetail(self.txDetailRetry)
    end
end

-- The permission collapse: everything this page learned from the server, everything it was
-- waiting for and every condition it was reading with is dropped, and the page reads as one that
-- was never opened. Both pickers are closed and emptied -- a candidate list or a locked account
-- is information about this server too. No command is sent, and nothing is asked for again until
-- the controller says reading is allowed once more.
function Page:clear()
    self.transactions = nil
    self:clearTxDetail()
    self.txDetailRequestId = nil
    self.txRequestId = nil
    self.txReqSig, self.txSnapSig = nil, nil
    self.txNamesGaps, self.txReqGaps, self.txSnapGaps = nil, nil, nil
    self.txFromMs, self.txToMs = nil, nil
    self.txListError = nil
    self.txListTimeout = false
    self.txBlockedBy = nil
    self.txSelectedTx = nil
    self.txSelected = nil
    self.txAccount = nil
    self.txItem = nil
    self.txItemTypes, self.txItemTypesKey = nil, ""
    self.txItemTypesError, self.txNamesWait = nil, false
    self.txNamesDirty = false
    self.txNamesRev = nil
    self.txAccountPicker:setText("")
    self.txAccountPicker:close()
    self.itemPicker:close()
    self.txList:setSelectedIndex(nil)
    self.txAsked = false
    self.txDirty = false
    self.txQueryAt = nil
end

function Page:dispose()
    DatePicker.close(self)
    F.closeCombo(self.txAccountCombo)
    pcall(function() self.txEntry:unfocus() end)
    pcall(function() self.txF.fromEntry:unfocus() end)
    pcall(function() self.txF.toEntry:unfocus() end)
    self.txAccountPicker:dispose()
    self.itemPicker:dispose()
    self.transactions = nil
    self:clearTxDetail()
    self.txListError = nil
    self.txListTimeout = false
    self.txBlockedBy = nil
    self.txSelected = nil
    self.txItemTypes = nil
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
    o.txFiltersOpen = false
    o.scrollOffset = 0
    o.txMatchMode = "contains"
    o.txItemTypesKey = ""
    o.txNamesWait = false
    o.txNamesDirty = false
    o:initialise()
    o:instantiate()   -- builds the children now; the owner only has to addChild/resize
    o:setVisible(false)
    return o
end

return P
