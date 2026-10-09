-- MinidoracatEconomyFor42 - the buy-order page of the Economy Center (client). Adds exactly one
-- namespace: C.PanelWanted.
--
-- A page of its own like the leaderboard (ECLeaderboard): own controls, own geometry, own paint,
-- so the window class grows no upvalues for it. The window owns the instance (Panel.wanted), adds
-- nothing itself and calls the entry points below; nothing here reaches back for C.Panel.
--
-- Three modes over one card (wanted-contract.md):
--   browse  every open order, newest first, paged by the server (wanted.browse); keyword and
--           category; a row offers "deliver" and, when the order pays in coins, "ask more"
--   mine    the player's own orders (wanted.mine): status, what they hold, each seller's asking
--           price under its order with "raise to this" / "ignore", and "cancel"
--   history the buy-order lines of the player's market record (wanted.history), painted like the
--           market history
-- Reads go through three ECReadGate instances (650 ms, one in flight, a hidden page owes its read,
-- stale replies dropped); a refused read keeps the snapshot on screen marked as older. One write is
-- in flight at a time (Page.pending), matched on its requestId. The create / deliver / ask dialogs
-- are ECPanelWantedDialogs; the cancel and raise confirmations are the framework's UI.Dialog.

require "ISUI/ISPanel"
if not MinidoracatEconomy or not MinidoracatEconomy.Client or not MinidoracatEconomy.Client.UI then
    require "MinidoracatEconomy/ECWidgets"
end
require "MinidoracatEconomy/ECPanelWidgets"
require "MinidoracatEconomy/ECRowActions"
require "MinidoracatEconomy/ECReadGate"
require "MinidoracatEconomy/ECDetailWindow"
require "MinidoracatEconomy/ECPanelCards"
require "MinidoracatEconomy/ECItemPicker"
require "MinidoracatEconomy/ECPanelWantedText"
require "MinidoracatEconomy/ECPanelWantedDialogs"

local EC = MinidoracatEconomy
local C = EC.Client
local U = C.UI
local W = C.PanelWidgets
local R = C.RowActions
local X = C.WantedText
local Keys = C.Keyboard
local Detail = C.DetailWindow

local M = {}
C.PanelWanted = M

local PAD, ROW, CHIP_H, T = U.PAD, U.ROW, U.CHIP_H, U.T
local CARD_TITLE_H = U.CARD_TITLE_H
local fontH = U.fontH
local fill, text, textWidth, fitText, textRight, textCentre = U.fill, U.text, U.textWidth, U.fitText, U.textRight, U.textCentre
local ITEM_ICON = W.ITEM_ICON
local TIMEOUT_MS = 8000
local QUERY_DEBOUNCE_MS = 600

local function tr(key, ...) return getText(T .. key, ...) end
local function int(v) return math.floor(tonumber(v) or 0) end
local function rowBackground(cell) return U.framework.Table.rowBackground(cell) end

local Page = {}
Page.__index = Page

-- ---------- rows (built once per reply, never per frame) ----------

-- A short state pill inside a row line (condition, status, "yours"): the row is two text lines
-- tall, so it is a line high, not a toolbar pill. Returns the width it took.
local function linePill(el, x, y, label, token)
    local w = textWidth(label) + 12
    fill(el, x, y, w, fontH.small + 2, "selected", "pill")
    text(el, label, x + 6, y + 1, token or "accent")
    return w
end

local function hasCoin(view)
    for _, opt in ipairs(type(view.options) == "table" and view.options or {}) do
        if opt.kind == "coin" then return true end
    end
    return false
end

-- The fields every order row shares, browse or own.
local function orderBase(v, kind)
    local name = C.itemLabel(v.item)
    local left = (tonumber(v.expiresAt) or 0) - EC.now()
    return {
        kind = kind, key = kind .. ":" .. tostring(v.id), id = v.id, item = v.item, view = v,
        name = name, altName = W.itemBaseName(v.item), texture = U.itemTexture(v.item),
        condText = X.condText(v.cond),
        qtyText = tr("Wanted_QtyOf", tostring(int(v.qty)), tostring(int(v.qtyTotal))),
        expiresText = left > 0 and W.remainText(left) or tr("Auction_Ended"),
    }
end

local function browseRow(v)
    local row = orderBase(v, "browse")
    local line = tr("Card_Join2", X.optionsLine(v.options), tr("Card_Buyer", tostring(v.owner or "-")))
    local my = type(v.myOffer) == "table" and v.myOffer or nil
    if my then
        line = tr("Card_Join2", line, tr("Wanted_MyOffer", X.optionText({ kind = "coin",
            unitPrice = my.unitPrice, currency = (v.options[int(my.option)] or {}).currency }), tostring(int(my.qty))))
    end
    row.line2 = line
    if v.mine == true then
        row.pill = tr("Wanted_Own")
    elseif type(v.blocked) == "string" then
        row.note, row.noteToken = X.errorText({ error = "order_held" }), "warn"
    else
        row.actions = { "fill" }
        if hasCoin(v) then row.actions[2] = "offer" end
    end
    row.search = string.lower(table.concat({ row.name, row.altName or "", tostring(v.item), tostring(v.owner or "") }, " "))
    return row
end

-- One own order, then one row per seller asking for more (wanted.offer), right under it.
local function addMine(rows, v)
    local row = orderBase(v, "order")
    row.line2 = X.heldText(v)
    row.status, row.statusToken = X.status(v)
    row.actions = { "cancel" }
    rows[#rows + 1] = row
    for _, off in ipairs(type(v.offers) == "table" and v.offers or {}) do
        local opt = type(v.options) == "table" and v.options[int(off.option)] or nil
        local price = int(off.unitPrice)
        local cur = opt and opt.currency or nil
        local each = X.optionText({ kind = "coin", unitPrice = price, currency = cur })
        rows[#rows + 1] = {
            kind = "offer", key = "offer:" .. tostring(v.id) .. ":" .. tostring(off.from), id = v.id, item = v.item,
            view = v, offer = off, option = int(off.option), currency = cur, unitPrice = price,
            line1 = tr("Wanted_OfferLine", tostring(off.from or "-"), each, tostring(int(off.qty))),
            line2 = (type(off.memo) == "string" and off.memo ~= "") and tr("Wanted_MemoLine", off.memo) or nil,
            -- a raise is only offered while the asking price is still above the order's own
            actions = { "raise", "dismiss" },
            raiseOff = not (opt and opt.kind == "coin" and price > int(opt.unitPrice)),
        }
    end
end

-- The words of the row buttons, one place: the cell, the card and the column width read it.
local ACTION_KEYS = { fill = "Wanted_Fill", offer = "Wanted_Offer", cancel = "Wanted_Cancel",
    raise = "Wanted_Raise", dismiss = "Wanted_Dismiss" }

local Cell = ISPanel:derive("MinidoracatEconomyWantedCell")
M.Cell = Cell

function Cell:render()
    local e = self.entry
    if not e then return end
    local cols = self.list.cols
    local h = self.height
    rowBackground(self)
    local half = math.floor(h / 2)
    local y1, y2 = half - fontH.small - 2, half + 2
    local ty = math.floor((h - fontH.small) / 2)
    if e.kind == "offer" then
        -- a seller's asking price, indented under the order it belongs to
        local x = cols.name
        text(self, fitText(e.line1, cols.offerW), x, e.line2 and y1 or ty, "text")
        if e.line2 then text(self, fitText(e.line2, cols.offerW), x, y2, "textFaint") end
    else
        W.drawIcon(self, e.texture, cols.icon, math.floor((h - ITEM_ICON) / 2), ITEM_ICON)
        local nameText = fitText(e.name, cols.nameW)
        text(self, nameText, cols.name, y1, "text")
        local px = cols.name + textWidth(nameText) + 8
        -- the status first (own orders), then the condition: both only where they fit whole
        if e.status and px + textWidth(e.status) + 12 <= cols.name + cols.nameW then
            px = px + linePill(self, px, y1, e.status, e.statusToken) + 6
        end
        if e.condText and px + textWidth(e.condText) + 12 <= cols.name + cols.nameW then
            linePill(self, px, y1, e.condText, "accent")
        end
        text(self, fitText(e.line2 or "", cols.nameW), cols.name, y2, "textFaint")
        textRight(self, fitText(e.qtyText, cols.qtyW), cols.qtyR, ty, "accent")
        textRight(self, fitText(e.expiresText, cols.expW), cols.expR, ty, "textFaint")
    end
    local chipY = math.floor((h - CHIP_H) / 2)
    R.begin(self)
    local x = cols.actionR
    local acts = e.actions
    if acts then
        -- each action has its own gate (Page:sync): a frozen account may still cancel and ignore
        local open = self.list.actionOpen
        for i = #acts, 1, -1 do
            local id = acts[i]
            local w = cols.actW[id]
            x = x - w
            R.put(self, id, cols.actLabel[id], x, chipY, w, CHIP_H,
                open ~= nil and open[id] == true and not (id == "raise" and e.raiseOff), id == "cancel" and "danger" or nil)
            x = x - 6
        end
    elseif e.pill then
        linePill(self, x - textWidth(e.pill) - 12, ty - 1, e.pill, "textMuted")
    elseif e.note then
        textRight(self, fitText(e.note, cols.actionsW), x, ty, e.noteToken)
    end
    R.finish(self)
end

-- ---------- construction ----------

local function chip(panel, page, key, onClick, style)
    local title = tr(key)
    local b = U.Button.create(0, 0, textWidth(title) + 22, CHIP_H, title, page, onClick, style or "chip")
    panel:addChild(b)
    return b
end

local function newList(panel, page, cell, height)
    local list = U.newTable(cell, height)
    list.onSelect = function(_, row) page:openDetail(row) end
    list.onRowAction = function(_, row, id) page:onRowAction(row, id) end
    panel:addChild(list)
    return list
end

function M.create(panel)
    local p = setmetatable({ panel = panel, mode = "browse", pageNo = 1, rows = {}, mineRows = {},
        histAll = {}, histRows = {} }, Page)
    p.tabs = W.modeTabs(panel, { { id = "browse", label = tr("Wanted_Browse") },
        { id = "mine", label = tr("Wanted_MineCount", "0", "0") },
        { id = "history", label = tr("Wanted_History") } }, "browse", function(_, id) p:onMode(id) end)
    p.refreshButton = W.iconChip(panel, "reload", tr("Market_Refresh"), function() p:onRefresh() end)
    p.createButton = chip(panel, p, "Wanted_Create", Page.onCreate, "primary")
    p.search = U.framework.TextField.new({ width = 200, height = math.max(26, fontH.small + 12), theme = U.theme,
        placeholder = tr("Wanted_SearchHint"), clearButton = true, maxLength = 64,
        onChange = function(_, value) p:onSearch(value) end })
    panel:addChild(p.search)
    p.catCombo = W.newCombo(panel, 140, function(_, combo) p:onCategory(combo) end)
    p.list = newList(panel, p, Cell, W.itemRowHeight())
    p.mineList = newList(panel, p, Cell, W.itemRowHeight())
    p.mineList.cols = p.list.cols         -- one width, one column set
    p.histList = U.newTable(W.HistoryCell, W.historyRowHeight())
    p.histList.onSelect = function(_, row) p:openDetail(row) end
    panel:addChild(p.histList)
    p.histBar = U.framework.FilterBar.new({
        parent = panel, target = panel, theme = U.theme, height = math.max(CHIP_H, fontH.small + 8),
        onChange = function() p:rebuildHistory() end,
        onLayout = function(owner) Detail.close(owner); owner:layout() end,
        kinds = { field = "kind", label = W.marketKindText, multi = true },
        search = { placeholder = tr("Market_History_SearchHint"), field = "searchText" },
        dates = { field = "ts" },
        sorts = { { id = "time", label = tr("Filter_Sort_time"), field = "ts" },
            { id = "amount", label = tr("Filter_Sort_amount"), field = "amount" } },
    })
    p.prevButton = chip(panel, p, "Market_Prev", Page.onPage)
    p.nextButton = chip(panel, p, "Market_Next", Page.onPage)
    p.prevButton.internal, p.nextButton.internal = -1, 1
    p.retryButton = chip(panel, p, "History_Retry", Page.onRetry)
    p.emptyButton = chip(panel, p, "Market_ClearFilters", Page.onEmpty)
    p.combos = { p.catCombo }
    -- a browse with a keyword also carries the item types the keyword names in the player's own
    -- language (C.ItemPicker.queryTypes): the server matches them before it pages, so a translated
    -- name finds orders on every page, not only on the one already on screen
    p.browseGate = C.ReadGate.create(function(_, requestId) C.sendWanted("browse", p:browseArgs(requestId)) end)
    p.mineGate = C.ReadGate.create(function(_, requestId) C.sendWanted("mine", { requestId = requestId }) end)
    p.histGate = C.ReadGate.create(function(_, requestId) C.sendWanted("history", { requestId = requestId }) end)
    -- the seller's copies for one order: the question is the order id, so an answer about another
    -- order (a dialog closed and another opened) is never applied, and one read paces them all
    p.candGate = C.ReadGate.create(function(orderId, requestId)
        p.candSentFor = orderId
        C.sendWanted("candidates", { orderId = orderId, requestId = requestId })
    end)
    -- which row action is open right now, by action (Page:sync); both tables read the same one
    p.actionOpen = {}
    p.list.actionOpen, p.mineList.actionOpen = p.actionOpen, p.actionOpen
    p.gateState = {}
    p.controls = { p.tabs, p.refreshButton, p.createButton, p.search, p.catCombo, p.list, p.mineList, p.histList,
        p.prevButton, p.nextButton, p.retryButton, p.emptyButton }
    p:setVisible(false)
    return p
end

-- The categories the filter offers: every item category this session knows (the item universe
-- the pickers read), by translated name. Filled the first time the page is shown.
function Page:fillCategories()
    if self.catsFilled then return end
    self.catsFilled = true
    local cats = {}
    for cat in pairs(C.ItemPicker.universe().cats or {}) do
        if type(cat) == "string" and cat ~= "" then cats[#cats + 1] = cat end
    end
    local label = {}
    for _, cat in ipairs(cats) do label[cat] = U.itemCategoryText(cat) end
    EC.sortSafe(cats, function(a, b) return label[a] < label[b] end)
    table.insert(cats, 1, "")
    W.comboFill(self.catCombo, cats, function(cat)
        if cat == "" then return tr("Shop_All") end
        return label[cat]
    end, self.category or "")
end

-- ---------- visibility and leaving ----------

function Page:closeCombos()
    for _, combo in ipairs(self.combos) do W.closeCombo(combo) end
    if self.dialog then self.dialog:closeCombos() end
end

function Page:blur()
    if self.search:isFocused() then self.search._entry:unfocus() end
    self.histBar:blur()
end

-- Shown or hidden as a whole; the layout then hides what the open mode does not paint.
function Page:setVisible(visible)
    for _, control in ipairs(self.controls) do control:setVisible(visible) end
    if not visible then
        self:closeCombos()
        self:blur()
        self.histBar:layout(0, 0, 1, false)
    end
end

-- The page was left: a dialog, its popups and queued reads go with it (the read in flight is kept
-- by its gate until it answers, so coming back never starts a second one).
function Page:leave()
    self:closeDialog()
    self:closeCombos()
    self:blur()
    self.browseGate:clear()
    self.mineGate:clear()
    self.histGate:clear()
    self.candGate:clear()
    self.queryAt = nil
end

-- ---------- reads ----------

local function norm(s) return (s == nil or s == "") and "" or tostring(s) end

-- The question a browse read asks: the keyword and the category. The page number is adopted
-- from the answer (the server clamps it), so it is no part of the match.
function Page:browseKey()
    return norm(self.query) .. "\1" .. norm(self.category)
end

-- What a browse read asks: the page, the category, the keyword and (with a keyword) the item types
-- it names in the player's own language (C.ItemPicker.queryTypes).
function Page:browseArgs(requestId)
    return { page = self.pageNo, query = self.query, types = (C.ItemPicker.queryTypes(self.query)),
        category = self.category, requestId = requestId }
end

function Page:visible(mode)
    return self.panel:pageVisible("Wanted") and (mode == nil or self.mode == mode)
end

-- Whatever the mode on screen reads. The browse page is also read once under the other modes
-- until it answered: it carries the rates, the price bounds and the order limit every dialog needs.
function Page:request()
    if self.mode == "mine" then
        self.mineGate:want("mine", self:visible())
    elseif self.mode == "history" then
        self.histGate:want("history", self:visible())
    end
    if self.mode == "browse" or self.browseSnap == nil then
        self.browseGate:want(self:browseKey(), self:visible())
    end
end

function Page:onRefresh()
    self:request()
end

-- The retry chip: the refused read of the mode on screen, and the policy read (rates, bounds,
-- the order limit) when that one is what failed.
function Page:onRetry()
    if self.mode == "browse" or self.browseSnap == nil then self.browseError = nil end
    if self.mode == "mine" then self.mineError = nil
    elseif self.mode == "history" then self.histError = nil end
    self:request()
    self.panel:layout()
end

function Page:onMode(mode)
    if mode == self.mode then return end
    self.mode = mode
    self.tabs:setSelected(mode, true)
    self:closeCombos()
    self:blur()
    Detail.close(self.panel)
    if mode == "history" then self:rebuildHistory() end
    self.panel:layout()
    Keys.invalidate(self.panel)
    self:request()
end

function Page:onSearch(value)
    local q = string.lower(string.match(tostring(value or ""), "^%s*(.-)%s*$"))
    self.query = q ~= "" and q or nil
    self.queryAt = EC.now() + QUERY_DEBOUNCE_MS
    self:rebuild()
end

function Page:onCategory(combo)
    local cat = combo:getOptionData(combo.selected)
    cat = (type(cat) == "string" and cat ~= "") and cat or nil
    if cat == self.category then return end
    self.category = cat
    self.pageNo = 1
    self:request()
end

function Page:onPage(button)
    local pages = math.max(1, int(self.browseSnap and self.browseSnap.pages))
    local target = math.max(1, math.min(pages, self.pageNo + button.internal))
    if target == self.pageNo or self.browseGate:busy() then return end
    self.pageNo = target
    self:request()
end

-- The one button over an empty table: clear the filters, start a buy order, or (an empty record)
-- go and look at the orders there are.
function Page:onEmpty()
    if self.emptyAction == "create" then return self:onCreate() end
    if self.emptyAction == "browse" then return self:onMode("browse") end
    if self.emptyAction == "history" then
        self.histBar:reset()
        return
    end
    self.query, self.category, self.pageNo, self.queryAt = nil, nil, 1, nil
    self.search:setText("")
    W.comboSelect(self.catCombo, "")
    self:rebuild()
    self:request()
end

-- ---------- snapshots ----------

function Page:rebuild()
    local rows = {}
    local q = self.query
    local _, types = C.ItemPicker.queryTypes(q)
    for _, v in ipairs(self.browseSnap and self.browseSnap.rows or {}) do
        local row = browseRow(v)
        -- the snapshot on screen is filtered at once while the next read is on its way: by the
        -- player's own words, or by a type those words name (the server's own match, C.ItemPicker.queryTypes)
        if q == nil or string.find(row.search, q, 1, true) or types[v.item] then rows[#rows + 1] = row end
    end
    self.rows = rows
    self.list:setItems(rows)
    local mine = {}
    for _, v in ipairs(self.mineSnap and self.mineSnap.orders or {}) do addMine(mine, v) end
    self.mineRows = mine
    self.mineList:setItems(mine)
    -- the numbers the page quotes follow the snapshots; the frames only read them
    self.infoT = nil
    local info = self:info()
    self.tabs:setItemLabel("mine", tr("Wanted_MineCount", tostring(info.count or 0), tostring(info.max or 0)))
    -- an open dialog quotes these numbers too: it is measured again with them
    if self.dialog then self.dialog.dirtySummary = true end
    self:syncDetail()
end

-- The history reply is oldest first; the bar sorts, filters and pages it on this side.
function Page:rebuildHistory()
    local src = self.histSnap and self.histSnap.entries or {}
    local rows = {}
    local off = self.panel.offsetMin
    for i = #src, 1, -1 do rows[#rows + 1] = W.historyRow(src[i], off) end
    self.histAll = rows
    local bar = self.histBar
    if bar:syncKinds(rows) and self.panel.g then self.panel:layout() end
    self.histRows = bar:apply(rows)
    self.histList:setItems(self.histRows)
end

-- The numbers the page and its dialogs quote. The rates and bounds come from the browse read only
-- (`known` says whether it has answered: an unknown fee is not a zero fee); the own-order count
-- and limit from whichever of browse and mine answered last. Built when a snapshot lands
-- (Page:rebuild), read every frame.
function Page:info()
    if self.infoT then return self.infoT end
    local b = self.browseSnap or {}
    local count, maxOrders = X.ownCount(self.browseSnap, self.browseAt, self.mineSnap, self.mineAt)
    self.infoT = {
        feePercent = int(b.feePercent), taxPercent = int(b.taxPercent),
        priceMin = math.max(1, int(b.priceMin)), priceMax = int(b.priceMax), days = int(b.days),
        max = maxOrders and int(maxOrders) or nil, count = count and int(count) or nil, known = self.browseSnap ~= nil,
    }
    return self.infoT
end

-- The gate of one write (create | fill | offer | raise | cancel | dismiss) as a code (X.gateCode)
-- or nil. Read every frame by Page:sync: one state table, refilled.
function Page:gateCode(action)
    local s, info = self.gateState, self:info()
    s.frozen = C.wallet ~= nil and C.wallet.frozen == true
    s.atTerminal = C.nearTerminal()
    s.known, s.max, s.count = info.known, info.max, info.count
    return X.gateCode(action, s)
end

-- The same gate in words, or nil when the write may go out. A policy that is not read yet says
-- so (or why its read failed); it is never quoted as zero.
function Page:gateReason(action)
    local code = self:gateCode(action)
    if code == nil then return nil end
    if code == "account_frozen" then return tr("Shop_Error_account_frozen") end
    if code == "not_at_terminal" then
        local s = tr("Wanted_AtTerminal")
        return C.Navigate and C.Navigate.withHint(s) or s
    end
    if code == "policy_unknown" then
        return self.browseError and W.readError(self.browseError) or tr("Wallet_Loading")
    end
    return X.errorText({ error = code, max = self:info().max })
end

-- ---------- replies ----------

local READS = { browse = true, mine = true, history = true }

-- Whether a reply is the answer this gate is waiting for. A good answer names its question (`key`)
-- and is matched on it (ECReadGate: an older read of the same question may still be shown). A
-- refusal often carries nothing but its code and the requestId (reply_too_large, ECServer), so it
-- is taken only as the answer to the very read this gate sent -- never dropped as "another
-- question" for lacking the echo, and never borrowed from an older read.
local function accepted(gate, args, key)
    if args.ok == false or args.error ~= nil then
        if args.requestId == nil or args.requestId ~= gate.sentId then return false end
        return gate:accept(args, nil) ~= "stale"
    end
    return gate:accept(args, key) ~= "stale"
end
M.accepted = accepted

function Page:onReply(kind, args)
    if READS[kind] then return self:onRead(kind, args) end
    if kind == "candidates" then return self:onCandidates(args) end
    if kind == "market.candidates" then
        if self.dialog then self.dialog:onRead(kind, args) end
        return
    end
    self:onWrite(kind, args)
end

-- wanted.candidates: only the answer about the order the open fill dialog is for. A refusal that
-- names no order is about the one this gate last asked for.
function Page:onCandidates(args)
    if not accepted(self.candGate, args, args.orderId) then return end
    local about = args.orderId or self.candSentFor
    local dlg = self.dialog
    if dlg and dlg.kind == "fill" and about == dlg.ctx.view.id then dlg:onCandidates(args) end
end

-- Asked by the fill dialog: the seller's copies of the type, judged against this order.
function Page:wantCandidates(orderId)
    self.candGate:want(orderId, true)
end

function Page:onRead(kind, args)
    local now = EC.now()
    if kind == "browse" then
        if not accepted(self.browseGate, args, norm(args.query) .. "\1" .. norm(args.category)) then return end
        if args.ok == false or args.error ~= nil then
            self.browseError = tostring(args.error or "unknown")
        else
            self.browseError, self.browseSnap, self.browseAt = nil, args, now
            self.pageNo = math.max(1, int(args.page))
        end
    elseif kind == "mine" then
        if not accepted(self.mineGate, args) then return end
        if args.ok == false or args.error ~= nil then
            self.mineError = tostring(args.error or "unknown")
        else
            self.mineError, self.mineSnap, self.mineAt = nil, args, now
        end
    else
        if not accepted(self.histGate, args) then return end
        if args.ok == false or args.error ~= nil then
            self.histError = tostring(args.error or "unknown")
        else
            self.histError, self.histSnap = nil, args
            self:rebuildHistory()
        end
    end
    self:rebuild()
    self.panel:layout()
end

-- A write this page sent and nothing else: another window's or an old answer is dropped.
function Page:onWrite(kind, args)
    local pending = self.pending
    if pending == nil or args.requestId == nil or args.requestId ~= pending.requestId then return end
    self.pending = nil
    if type(args.mine) == "table" then
        -- a write answers with the own orders as they are now: the freshest count there is
        self.mineSnap = self.mineSnap or {}
        self.mineSnap.orders, self.mineAt = args.mine, EC.now()
    end
    self.panel:updateMailTab(args.unclaimed)
    self:rebuild()
    local dlg = self.dialog
    if args.ok ~= true then
        -- a refusal may leave out what the request itself named (a raise's currency)
        if args.currency == nil then args.currency = pending.currency end
        if dlg and dlg.kind == pending.dialog then
            dlg:onRefused(args)
        else
            C.toast(X.errorText(args))
        end
        -- a refusal about the order itself means the page is out of date
        self:request()
        return
    end
    if pending.dialog then self:closeDialog() end
    C.toast(self:doneText(kind, args, pending))
    local note = C.deliveryText(args)
    if note then C.toast(note) end
    if kind == "create" then
        self:onMode("mine")
    end
    self:request()
    self.panel:layout()
end

-- The toast of a write that landed.
function Page:doneText(kind, args, pending)
    local name = C.itemLabel(args.item or pending.item)
    if kind == "create" then
        local fees
        for cur, fee in pairs(type(args.fees) == "table" and args.fees or {}) do
            if int(fee) > 0 then
                local part = X.money(fee, cur)
                fees = fees and (fees .. tr("Admin_Set_ListSep") .. part) or part
            end
        end
        return tr("Wanted_Created", name, tostring(int(args.qty)), fees or tr("Wanted_NoFee"))
    elseif kind == "fill" then
        -- what reached the seller: the coins net of the tax, or the items of the item option
        local got = tonumber(args.price) and X.money(int(args.price) - int(args.tax), args.currency)
            or W.payItemText(args) or "-"
        return tr("Wanted_Filled", tostring(int(args.qty)), name, got)
    elseif kind == "cancel" then
        return tr("Wanted_Cancelled", name)
    elseif kind == "offer" then
        return tr("Wanted_OfferSent", name)
    elseif kind == "raise" then
        return tr("Wanted_Raised", name, X.money(args.unitPrice, args.currency), tostring(int(args.met)))
    end
    return tr("Wanted_Dismissed")
end

-- ---------- writes ----------

-- Every write goes out here: one in flight, matched on its requestId, given up on after the
-- timeout (never resent on its own). `dialog` names the dialog that waits for the answer.
function Page:send(command, args, item, dialog, currency)
    if self.pending then return false end
    args.requestId = args.requestId or C.newRequestId()
    self.pending = { requestId = args.requestId, at = EC.now(), item = item, dialog = dialog, currency = currency }
    C.sendWanted(command, args)
    return true
end

function Page:busy() return self.pending ~= nil end

-- A dialog opens only on a known policy (Page:gateReason "create"): the dialog then reads the
-- page's numbers live (Page:info), so a policy that changes while it is open is quoted at once.
function Page:onCreate()
    if self:busy() or self.panel:isModal() or self:gateReason("create") then return end
    self:openDialog("create", {})
end

-- Find the row a card (or a stale button) names again in what is on screen now.
function Page:findRow(key)
    for _, list in ipairs({ self.rows, self.mineRows, self.histRows }) do
        for _, row in ipairs(list) do
            if row.key == key or row.recordKey == key then return row end
        end
    end
    return nil
end

function Page:onRowAction(row, id)
    if row == nil or self:busy() or self.panel:isModal() or self:gateReason(id) then return end
    local v = row.view
    if id == "fill" then
        self:openDialog("fill", { view = v })
    elseif id == "offer" then
        self:openDialog("offer", { view = v })
    elseif id == "cancel" then
        self:confirmCancel(v)
    elseif id == "raise" and not row.raiseOff then
        self:confirmRaise(row)
    elseif id == "dismiss" then
        self:send("dismiss", { orderId = v.id, from = row.offer.from }, v.item)
    end
end

function Page:onDetailAction(key, id)
    local row = self:findRow(key)
    if row then self:onRowAction(row, id) end
end

local function frameworkDialog()
    local ui = U.framework
    if ui ~= nil and ui.Dialog == nil then pcall(require, "MinidoracatUI/Widgets/Window") end
    return ui ~= nil and ui.CAPABILITIES and ui.CAPABILITIES.dialog == true and ui.Dialog or nil
end

-- Cancelling says what comes back and where before anything is sent: the coins of every coin
-- option to the wallet, the items in escrow to the mailbox, and that the listing fee stays paid.
-- The close button keeps the order ("Keep order"); only the danger button cancels.
function Page:confirmCancel(v)
    local Dialog = frameworkDialog()
    if Dialog == nil then return end
    local lines = { tr("Card_Join2", C.itemLabel(v.item), tr("Wanted_LeftQty", tostring(int(v.qty)))) }
    local coins
    for _, opt in ipairs(v.options or {}) do
        if opt.kind == "coin" and int(opt.held) > 0 then
            local part = X.money(opt.held, opt.currency)
            coins = coins and (coins .. tr("Admin_Set_ListSep") .. part) or part
        elseif opt.kind == "item" and int(opt.held) > 0 then
            lines[#lines + 1] = tr("Wanted_CancelItems", tostring(int(opt.held)), W.titledName(C.itemLabel(opt.item), opt.state))
        end
    end
    if coins then table.insert(lines, 2, tr("Wanted_CancelCoins", coins)) end
    lines[#lines + 1] = tr("Wanted_CancelNoRefund")
    local page = self
    Dialog.show({ title = tr("Wanted_CancelTitle"), text = table.concat(lines, "\n"), theme = U.theme,
        confirmText = tr("Wanted_Cancel"), cancelText = tr("Wanted_Keep"), danger = true,
        onResult = function(ok)
            -- a frozen account may still take its order down (the server refunds with allowFrozen)
            if ok and not page:gateReason("cancel") then page:send("cancel", { orderId = v.id }, v.item) end
        end })
end

-- Raising an option to a seller's asking price: the extra the order holds from now on and the
-- listing fee on that extra, both before the press.
function Page:confirmRaise(row)
    local Dialog = frameworkDialog()
    if Dialog == nil then return end
    local v = row.view
    local opt = v.options[row.option]
    local delta = (row.unitPrice - int(opt.unitPrice)) * int(v.qty)
    local fee = X.pct(delta, self:info().feePercent)
    local text = table.concat({
        tr("Wanted_RaiseLine", C.itemLabel(v.item), X.money(opt.unitPrice, opt.currency),
            X.money(row.unitPrice, opt.currency), tostring(int(v.qty))),
        tr("Wanted_RaiseHold", X.money(delta, opt.currency)),
        tr("Wanted_RaiseFee", X.money(fee, opt.currency)),
        tr("Wanted_RaiseAll") }, "\n")
    local page = self
    Dialog.show({ title = tr("Wanted_RaiseTitle"), text = text, theme = U.theme,
        confirmText = tr("Wanted_RaiseConfirm", X.money(delta + fee, opt.currency)), cancelText = tr("Admin_Cancel"),
        onResult = function(ok)
            if ok and not page:gateReason("raise") then
                page:send("raise", { orderId = v.id, option = row.option, unitPrice = row.unitPrice }, v.item, nil,
                    opt.currency)
            end
        end })
end

-- ---------- dialogs ----------

function Page:openDialog(kind, ctx)
    local panel = self.panel
    local trigger = Keys.focused()
    local keyboard = Keys.isKeyboardFocused(trigger)
    local dlg = C.PanelWantedDialogs.new(kind, panel, self, ctx)
    dlg.returnFocus = keyboard and trigger or nil
    self.dialog = dlg
    panel.wantedDialog = dlg
    panel:closeCombos()
    panel:updateModalGuard()
    panel:layoutDialog(dlg)
    Keys.invalidate(panel)
    Keys.focusControl(dlg:firstControl(), keyboard)
end

function Page:closeDialog()
    local dlg = self.dialog
    if not dlg then return end
    local panel = self.panel
    self.dialog, panel.wantedDialog = nil, nil
    dlg:dispose()
    dlg:setVisible(false)
    panel:removeChild(dlg)
    Keys.invalidate(panel)
    panel:updateModalGuard()
    panel.buyReturnFocus = dlg.returnFocus
end

-- ---------- detail ----------

function Page:cardOf(row)
    if row.recordKey then
        return C.PanelCards.history(self.panel, row, tr("Wanted_History"), false)
    end
    local v = row.view
    local c = { source = tr("Tab_Wanted"), sourceIcon = "tag", item = v.item,
        name = tr("Card_ItemQty", C.itemLabel(v.item), tostring(int(v.qty))), rows = {}, tech = {}, chips = {} }
    c.sub = row.altName or C.itemLabel(v.item)
    if v.mine ~= true and row.kind == "browse" then c.sub = tr("Card_Join2", c.sub, tr("Card_Buyer", tostring(v.owner or "-"))) end
    if row.kind == "order" then c.chips[1] = { value = row.status, token = row.statusToken, dot = true } end
    c.chips[#c.chips + 1] = { label = tr("Wanted_Remaining"), value = tr("Wanted_QtyOf", tostring(int(v.qty)),
        tostring(int(v.qtyTotal))) }
    local left = (tonumber(v.expiresAt) or 0) - EC.now()
    c.chips[#c.chips + 1] = { label = tr("Card_Left"), value = left > 0 and W.remainText(left) or tr("Auction_Ended") }
    c.chips[#c.chips + 1] = { value = X.condText(v.cond) or tr("Wanted_Cond_Any"), dot = true }
    for i, opt in ipairs(v.options or {}) do
        c.rows[#c.rows + 1] = { label = tr("Wanted_OptionN", tostring(i)), value = X.optionText(opt), coin = opt.currency }
    end
    if row.kind == "order" then c.rows[#c.rows + 1] = { label = tr("Wanted_HeldLabel"), value = X.heldText(v) } end
    if row.kind == "offer" then
        c.rows[#c.rows + 1] = { label = tr("Wanted_OfferFrom"), value = row.line1, note = row.line2 }
    elseif type(v.myOffer) == "table" then
        local my = v.myOffer
        c.rows[#c.rows + 1] = { label = tr("Wanted_MyOfferLabel"), value = tr("Wanted_QtyEach",
            X.optionText({ kind = "coin", unitPrice = my.unitPrice, currency = (v.options[int(my.option)] or {}).currency }),
            tostring(int(my.qty))), note = (type(my.memo) == "string" and my.memo ~= "") and my.memo or nil }
    end
    local page, acts = self, {}
    for _, id in ipairs(row.actions or {}) do
        acts[#acts + 1] = { id = id, label = tr(ACTION_KEYS[id]),
            style = id == "cancel" and "danger" or ((id == "fill" or id == "raise") and "primary" or "chip"),
            enabled = function() return page.actionOpen[id] == true and not (id == "raise" and row.raiseOff) end,
            run = function() page:onDetailAction(row.key, id) end }
    end
    c.actions = acts
    table.insert(c.tech, { label = tr("Detail_ItemCode"), value = tostring(v.item) })
    table.insert(c.tech, { label = tr("Wanted_OrderId"), value = tostring(v.id) })
    c.techHint = tr("Wanted_OrderId")
    return c
end

-- What the copy chip hands over: every line of the card, in reading order.
local function cardText(c)
    local out = { c.name or "" }
    if c.sub then out[#out + 1] = c.sub end
    for _, pill in ipairs(c.chips or {}) do
        out[#out + 1] = pill.label and getText(T .. "Detail_Line", pill.label, pill.value) or pill.value
    end
    for _, r in ipairs(c.rows or {}) do
        out[#out + 1] = getText(T .. "Detail_Line", r.label, r.value)
        if r.note then out[#out + 1] = r.note end
    end
    for _, t in ipairs(c.tech or {}) do out[#out + 1] = getText(T .. "Detail_Line", t.label, t.value) end
    return table.concat(out, "\n")
end

function Page:openDetail(row)
    if row == nil then return end
    local key = row.key or row.recordKey
    self.detailKey = key
    self.panel.detailList = nil     -- the window's own row refresh is not this page's
    local c = self:cardOf(row)
    Detail.open(self.panel, "wanted:" .. tostring(key), tr("Tab_Wanted"), cardText(c), nil, c)
end

-- An open record follows its row; a row that left the page closes it.
function Page:syncDetail()
    local key = self.detailKey
    if key == nil or not Detail.isOpen(self.panel, "wanted:" .. tostring(key)) then return end
    local row = self:findRow(key)
    if row == nil then
        Detail.close(self.panel)
        return
    end
    local c = self:cardOf(row)
    Detail.update(self.panel, "wanted:" .. tostring(key), tr("Tab_Wanted"), cardText(c), c)
end

-- ---------- per frame ----------

local ROW_ACTIONS = { "fill", "offer", "raise", "cancel", "dismiss" }

function Page:sync()
    local now = EC.now()
    self.browseGate:pump(self:visible() and (self.mode == "browse" or self.browseSnap == nil))
    self.mineGate:pump(self:visible("mine"))
    self.histGate:pump(self:visible("history"))
    local expired = false
    if self.browseGate:expired() then self.browseError, expired = "timeout", true end
    if self.mineGate:expired() then self.mineError, expired = "timeout", true end
    if self.histGate:expired() then self.histError, expired = "timeout", true end
    if expired then self.panel:layout() end
    -- the fill dialog's candidate read: paced with every other one, asked again if it never came back
    local dlg = self.dialog
    local filling = dlg ~= nil and dlg.kind == "fill"
    self.candGate:pump(filling)
    if self.candGate:expired() and filling then self.candGate:want(dlg.ctx.view.id, true) end
    if self.queryAt and now >= self.queryAt then
        self.queryAt = nil
        self.pageNo = 1
        self:request()
    end
    local pending = self.pending
    if pending and now - pending.at > TIMEOUT_MS then
        -- the write may or may not have landed: nothing is resent, the page is read back
        self.pending = nil
        if self.dialog and self.dialog.kind == pending.dialog then
            self.dialog:onTimeout()
        else
            C.toast(X.errorText({ error = "timeout" }))
        end
        self:request()
    end
    -- every row action has its own gate: a frozen account may still cancel and ignore an asking
    -- price, and nothing that quotes the rates opens before they are read
    local open = self.actionOpen
    for _, id in ipairs(ROW_ACTIONS) do open[id] = pending == nil and self:gateCode(id) == nil end
    local reason = self:gateReason("create")
    self.createButton:setEnable(reason == nil and pending == nil and not self.panel:isModal())
    self.createButton.tooltip = reason
    local busy = self.browseGate:busy()
    local pages = math.max(1, int(self.browseSnap and self.browseSnap.pages))
    self.prevButton:setEnable(not busy and self.pageNo > 1)
    self.nextButton:setEnable(not busy and self.pageNo < pages)
    self.catCombo:setEnabled(not busy)
end

-- ---------- geometry ----------

function Page:modeError()
    if self.mode == "browse" then return self.browseError, self.browseSnap end
    if self.mode == "mine" then return self.mineError, self.mineSnap end
    return self.histError, self.histSnap
end

-- The whole page inside the workspace the window handed over: the mode tabs with the refresh and
-- create buttons at their right, then one card. Under its title (the two rates as pills, the
-- rules chip at the right) one state line: a refused read, the first read, or why the page's
-- buttons are shut (away from a terminal, frozen, no order slot left).
function Page:layout(x, y, w, h)
    local g = {}
    self.g = g
    local open = self.panel:pageVisible("Wanted")
    local right = x + w - PAD
    local tabs = self.tabs
    local barH = math.max(tabs.height, CHIP_H)
    tabs:setX(x); tabs:setY(y)
    local actions = { self.refreshButton, self.createButton }
    local ax = x + w + 6
    for i = 1, #actions do ax = ax - actions[i].width - 6 end
    local ty = y
    if ax < x + tabs.width + PAD then ty = y + barH + 6 end
    for i = 1, #actions do
        local b = actions[i]
        b:setX(ax); b:setY(ty + math.floor((barH - b.height) / 2))
        ax = ax + b.width + 6
    end
    local cardY = ty + barH + PAD
    g.cardX, g.cardY, g.cardW = x, cardY, w
    g.cardH = math.max(CARD_TITLE_H + ROW * 3, y + h - cardY)
    local bottom = cardY + g.cardH
    g.title = tr(self.mode == "history" and "Wanted_HistoryTitle" or "Wanted_Title")
    g.pillX = x + PAD + textWidth(g.title, UIFont.Medium) + PAD
    g.pillY = cardY + math.floor((CARD_TITLE_H - CHIP_H) / 2)
    local info = self:info()
    g.taxText, g.feeText = tostring(info.taxPercent) .. "%", tostring(info.feePercent) .. "%"
    local rules = self.panel.rulesButton
    g.rulesX = right - rules.width
    g.rulesY = cardY + math.floor((CARD_TITLE_H - rules.height) / 2)
    local top = cardY + CARD_TITLE_H
    g.showPills = self.mode ~= "history" and info.known
    if g.showPills then
        local pillsW = U.pillWidth(tr("Trade_Tax"), g.taxText) + 6 + U.pillWidth(tr("Trade_Fee"), g.feeText)
        if g.pillX + pillsW > g.rulesX - 6 then
            g.pillX, g.pillY = x + PAD, top + 4
            top = top + CHIP_H + 8
        end
    end
    -- the state line: what failed, what is loading, or why the buttons are shut
    local err, snap = self:modeError()
    g.noteY = top
    g.note, g.noteToken = nil, nil
    if err then
        g.note = (self.mode == "history" and W.historyError(err) or W.readError(err))
        if snap then g.note = g.note .. "  " .. tr("History_Stale") end
        g.noteToken = "errorText"
    elseif snap == nil then
        g.note, g.noteToken = tr("Wallet_Loading"), "textMuted"
    elseif self.mode ~= "history" then
        -- why this mode's own writes are shut; a policy read that failed is an error with its retry
        g.note = self:gateReason(self.mode == "mine" and "create" or "fill")
        local policyFailed = self.browseSnap == nil and self.browseError ~= nil
        g.noteToken = policyFailed and "errorText" or "warn"
        err = err or (policyFailed and self.browseError) or nil
    end
    local retry = self.retryButton
    retry:setVisible(open and err ~= nil)
    retry:setX(right - retry.width)
    retry:setY(top + math.floor((ROW - retry.height) / 2))
    if g.note then top = top + ROW end
    local browse, mine, history = self.mode == "browse", self.mode == "mine", self.mode == "history"
    -- the browse tools: keyword and category, each under its caption
    local capH = fontH.small + 4
    local search, cat = self.search, self.catCombo
    search:setVisible(open and browse)
    cat:setVisible(open and browse)
    if browse then
        if open then self:fillCategories() end   -- the item universe is scanned only for a page on screen
        search:setWidth(math.max(160, math.min(300, math.floor(w * 0.3))))
        search:setHeight(cat.height)
        cat:setWidth(W.comboWidth(cat, 140, math.floor(w * 0.3)))
        top = W.placeRow({ search, cat }, x + PAD, top + capH, right, math.max(search.height, cat.height), capH + 6) + 6
        g.headerY = top
        top = top + ROW
    end
    -- the two tables share one column set
    local listW = w - 2
    local footer = browse and ROW or 0
    local listH = math.max(ROW * 2, bottom - top - PAD - footer)
    U.placeList(self.list, open and browse, x + 1, top, listW, listH)
    U.placeList(self.mineList, open and mine, x + 1, top, listW, listH)
    self.list.ecChromeH, self.mineList.ecChromeH = top - y + PAD + footer, top - y + PAD
    self:columns(listW)
    g.footerY = top + listH + 2
    local px = x + PAD + textWidth(tr("Market_Page", "99", "99")) + PAD
    for _, b in ipairs({ self.prevButton, self.nextButton }) do
        b:setVisible(open and browse)
        b:setX(px); b:setY(g.footerY + math.floor((ROW - CHIP_H) / 2))
        px = px + b.width + 6
    end
    -- history: the market history's own filter bar and two-line rows
    local hist = self.histList
    local hy, hh, shown = self.histBar:layoutViewport(x + PAD, top, right, bottom - PAD, open and history,
        cardY + math.max(0, (CARD_TITLE_H - CHIP_H) / 2), W.historyRowHeight())
    U.placeList(hist, shown and self.histSnap ~= nil, x + 1, hy, listW, hh)
    hist.ecChromeH = hy - y + ROW
    self:historyColumns(listW)
    self.emptyButton:setVisible(false)   -- the paint shows it over an empty table
    if Detail.isOpen(self.panel) then self:syncDetail() end
end

function Page:columns(listW)
    local cols = self.list.cols
    cols.icon = PAD
    cols.name = PAD + ITEM_ICON + PAD
    cols.actW, cols.actLabel = cols.actW or {}, cols.actLabel or {}
    for id, key in pairs(ACTION_KEYS) do
        cols.actLabel[id] = tr(key)
        cols.actW[id] = textWidth(cols.actLabel[id]) + 22
    end
    local a = cols.actW
    cols.actionsW = math.max(a.fill + 6 + a.offer, a.cancel, a.raise + 6 + a.dismiss, textWidth(tr("Wanted_Own")) + 12)
    cols.actionR = listW - 12 - PAD
    local left = cols.actionR - cols.actionsW - PAD
    cols.expW = math.max(textWidth(tr("Time_DH", "99", "23")), textWidth(tr("Wanted_Col_Left")))
    cols.expR = left
    cols.qtyW = math.max(textWidth(tr("Wanted_QtyOf", "50", "50")), textWidth(tr("Wanted_Col_Qty")))
    cols.qtyR = cols.expR - cols.expW - PAD
    cols.nameW = math.max(40, cols.qtyR - cols.qtyW - PAD - cols.name)
    cols.offerW = math.max(40, left - cols.name)
end

function Page:historyColumns(listW)
    local cols = self.histList.cols
    local kindW = 0
    for _, k in ipairs(W.HISTORY_KINDS) do
        if string.sub(k, 1, 7) == "wanted_" then
            kindW = math.max(kindW, textWidth(getTextOrNull(T .. "Market_Kind_" .. k) or k))
        end
    end
    cols.kind = PAD
    cols.name = cols.kind + kindW + PAD
    cols.status = math.max(cols.name, listW - 12 - textWidth(tr("Wallet_RolledBack")) - PAD)
    cols.amountR = cols.status - PAD
    cols.nameW = math.max(0, cols.amountR - textWidth("-999,999") - PAD - cols.name)
end

-- The rules chip of the page (the window owns the one chip): the rates, how an order works and
-- what it costs, behind it.
function Page:placeRules(rules, open)
    local g = self.g
    rules:setVisible(open)
    rules:setX(g.rulesX); rules:setY(g.rulesY)
    local info = self:info()
    local how = { { text = tr("Wanted_R_How") }, { text = tr("Wanted_R_Fill") }, { text = tr("Wanted_R_Offer") } }
    local costs = {
        { pill = g.feeText, text = tr("Wanted_R_Fee") },
        { pill = g.taxText, text = tr("Wanted_R_Tax") },
        { mark = "no", text = tr("Wanted_R_NoRefund") },
    }
    local limits = {}
    if info.max and info.max > 0 then limits[1] = { pill = tostring(info.max), text = tr("Wanted_R_Max") } end
    if info.days > 0 then limits[#limits + 1] = { pill = tr("Wanted_Days", tostring(info.days)), text = tr("Wanted_R_Days") } end
    limits[#limits + 1] = { text = tr("Wanted_R_Slot") }
    limits[#limits + 1] = { text = tr("Wanted_R_Mail") }
    rules.ruleTitle = tr("Trade_Rules")
    rules.card = { source = tr("Card_Join2", tr("Tab_Wanted"), tr("Trade_Rules")), sourceIcon = "document",
        sections = { { title = tr("Card_R_HowTitle"), lines = how }, { title = tr("Card_R_FeesTitle"), lines = costs },
            { title = tr("Wanted_R_LimitsTitle"), lines = limits } } }
    local note = {}
    for _, sec in ipairs(rules.card.sections) do
        for _, line in ipairs(sec.lines) do
            note[#note + 1] = line.pill and getText(T .. "Detail_Line", line.text, line.pill) or line.text
        end
    end
    rules.note = table.concat(note, "\n")
    Detail.update(self.panel, "rules:Wanted", rules.ruleTitle, rules.note, rules.card)
end

-- ---------- paint ----------

function Page:drawEmpty(owner, list, title, body, label, action, enabled)
    local b = self.emptyButton
    self.emptyAction = action
    local by = U.emptyState(owner, "wanted", list.x, list.y, list.width, list.height, title, body)
    U.drawEmptyState(owner, "wanted")
    if b.fullTitle ~= label then
        b:setWidth(textWidth(label) + 22)
        U.setButtonTitle(b, label)
    end
    b:setX(list.x + math.floor((list.width - b.width) / 2)); b:setY(by)
    b:setEnable(enabled)
    if not b:getIsVisible() then b:setVisible(true) end
end

function Page:draw(owner)
    local g = self.g
    if g == nil then return end
    U.card(owner, g.cardX, g.cardY, g.cardW, g.cardH, g.title)
    if g.showPills then
        local px = g.pillX + U.drawPill(owner, g.pillX, g.pillY, tr("Trade_Tax"), g.taxText) + 6
        U.drawPill(owner, px, g.pillY, tr("Trade_Fee"), g.feeText)
    end
    if g.note then
        local noteR = self.retryButton:getIsVisible() and self.retryButton.x - 6 or g.cardX + g.cardW - PAD
        text(owner, fitText(g.note, math.max(0, noteR - g.cardX - PAD * 2)), g.cardX + PAD,
            g.noteY + math.floor((ROW - fontH.small) / 2), g.noteToken)
    end
    local _, snap = self:modeError()
    if snap == nil then return end
    if self.mode == "history" then return self:drawHistory(owner) end
    local list = self.mode == "browse" and self.list or self.mineList
    if self.mode == "browse" then
        text(owner, tr("Wanted_Search"), self.search.x, self.search.y - fontH.small - 2, "textMuted")
        text(owner, tr("Shop_Category"), self.catCombo.x, self.catCombo.y - fontH.small - 2, "textMuted")
        local cols, hx, hy = list.cols, list.x, g.headerY
        fill(owner, hx, hy, list.width, ROW, "well", "rect")
        local hty = hy + math.floor((ROW - fontH.small) / 2)
        text(owner, tr("Market_Col_Item"), hx + cols.name, hty, "textMuted")
        textRight(owner, tr("Wanted_Col_Qty"), hx + cols.qtyR, hty, "textMuted")
        textRight(owner, tr("Wanted_Col_Left"), hx + cols.expR, hty, "textMuted")
        local fy = g.footerY + math.floor((ROW - fontH.small) / 2)
        text(owner, tr("Market_Page", tostring(self.pageNo), tostring(math.max(1, int(snap.pages)))),
            g.cardX + PAD, fy, "textMuted")
        textRight(owner, tr("Wanted_Total", tostring(int(snap.total))), g.cardX + g.cardW - PAD, fy, "textMuted")
    end
    if #list:getItems() > 0 then
        if self.emptyButton:getIsVisible() then self.emptyButton:setVisible(false) end
        return
    end
    local create = self.createButton
    if self.mode == "browse" and (self.query or self.category) then
        self:drawEmpty(owner, list, self.query and tr("Market_NoMatchQuery", self.search:getText())
            or tr("Wanted_NoMatch"), nil, tr("Market_ClearFilters"), "clear", true)
    else
        local mine = self.mode == "mine"
        self:drawEmpty(owner, list, tr(mine and "Wanted_MineEmpty" or "Wanted_Empty"),
            tr(mine and "Wanted_MineEmptyBody" or "Wanted_EmptyBody"), create.fullTitle, "create", create.enable)
    end
end

function Page:drawHistory(owner)
    local g = self.g
    local loaded = #self.histAll
    if self.histSnap and self.histSnap.truncated == true then
        text(owner, fitText(tr("Market_History_Truncated", tostring(loaded)), g.cardW - PAD * 2), g.cardX + PAD,
            g.noteY + math.floor((ROW - fontH.small) / 2), "warn")
    end
    self.histBar:draw(owner)
    self.histBar:drawPager(owner)
    local list = self.histList
    if list:getIsVisible() and #list:getItems() == 0 then
        local filtered = loaded > 0
        self:drawEmpty(owner, list, tr(filtered and "Filter_NoMatch" or "Wanted_HistoryEmpty"), nil,
            tr(filtered and "Market_ClearFilters" or "Wanted_Browse"), filtered and "history" or "browse", true)
    elseif self.emptyButton:getIsVisible() then
        self.emptyButton:setVisible(false)
    end
end

-- ---------- keyboard ----------

-- Every control of the page in reading order; ECKeyboard drops a descriptor whose controls are
-- all unreachable, so a control the open mode does not paint is simply not in the walk.
function Page:keyboardTargets(out)
    out[#out + 1] = { kind = "button", control = self.tabs, label = tr("Wanted_Kb_Modes") }
    out[#out + 1] = { kind = "group", controls = { self.refreshButton, self.createButton }, label = tr("Kb_Trade_Actions") }
    out[#out + 1] = { kind = "button", control = self.retryButton, label = tr("History_Retry") }
    out[#out + 1] = { kind = "entry", control = self.search._entry, frame = self.search, label = tr("Wanted_Search") }
    out[#out + 1] = { kind = "combo", control = self.catCombo, label = tr("Shop_Category") }
    for _, list in ipairs({ self.list, self.mineList }) do
        out[#out + 1] = { kind = "list", control = list, label = tr("Wanted_Title") }
        out[#out + 1] = { kind = "group", controls = R.targets(list), label = tr("Kb_Row_Actions") }
    end
    out[#out + 1] = { kind = "button", control = self.emptyButton, label = self.emptyButton.fullTitle }
    self.histBar:appendTargets(out)
    out[#out + 1] = { kind = "list", control = self.histList, label = tr("Wanted_HistoryTitle") }
    self.histBar:appendPagerTargets(out)
    out[#out + 1] = { kind = "group", controls = { self.prevButton, self.nextButton }, label = tr("Kb_Market_Pager") }
    return out
end

M.Page = Page

return M
