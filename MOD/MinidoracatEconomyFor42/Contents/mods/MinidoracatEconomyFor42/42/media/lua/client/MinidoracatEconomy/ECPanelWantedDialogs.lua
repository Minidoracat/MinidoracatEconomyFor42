-- MinidoracatEconomyFor42 - the three dialogs of the buy-order page (client). Adds exactly one
-- namespace: C.PanelWantedDialogs.
--
--   D.new(kind, panel, page, ctx)   kind = "create" | "fill" | "offer"; added to the window, laid
--                                   out by Panel:layoutDialog like every other modal of it
--
-- One class, three forms. Each form is a list of labelled rows (the label left, its controls
-- right, wrapped inside the dialog at any font), a one-line refusal under them, a scrolling reader
-- with the numbers the press will move, and the two buttons. A refusal that belongs to a field
-- marks that field (TextField:setInvalid where the framework has it, rev 16) and says why on the
-- message line; the next edit of the field drops it. The write itself goes out through the page
-- (Page:send: one in flight, its requestId), which hands the answer back here (onRefused /
-- onTimeout). A press after a timeout carries the same requestId, so the server answers a
-- repeat with what it already did instead of doing it twice; anything changed is a new request.
--
--   create  item type (the framework item picker over the market universe), count 1..50, the
--           condition (any / new only / durability at least N%), 1..3 payment options: coins
--           (one currency each, unit price) or items (one option at most: a backpack group from
--           market.candidates and how many per unit). The reader states each option's reserve and
--           listing fee, the items taken from the backpack, the expiry and the mailbox slot.
--   fill    the seller's step: which option to be paid in (with what reaches them after tax), the
--           backpack group to deliver from (wanted.candidates; the copies the order does not take
--           are counted and named), and how many. mail_confirmation_required is pressed again to
--           accept the mailbox, price_changed shows the new price and is pressed again to accept.
--   offer   a seller asks for a higher unit price on one coin option: the price, the count and a
--           note of at most 64 characters. Nothing moves; the buyer may raise to it.

require "ISUI/ISPanel"
if not MinidoracatEconomy or not MinidoracatEconomy.Client or not MinidoracatEconomy.Client.UI then
    require "MinidoracatEconomy/ECWidgets"
end
require "MinidoracatEconomy/ECPanelWidgets"
require "MinidoracatEconomy/ECReadGate"
require "MinidoracatEconomy/ECItemPicker"
require "MinidoracatEconomy/ECPanelWantedText"

local EC = MinidoracatEconomy
local C = EC.Client
local U = C.UI
local W = C.PanelWidgets
local X = C.WantedText
local Keys = C.Keyboard

local D = {}
C.PanelWantedDialogs = D

local PAD, CHIP_H, T = U.PAD, U.CHIP_H, U.T
local fontH = U.fontH
local fill, border, text, textWidth, fitText = U.fill, U.border, U.text, U.textWidth, U.fitText
local OPTIONS_MAX = 3
local QTY_MAX = 50
local MEMO_MAX = 64

local function tr(key, ...) return getText(T .. key, ...) end
local function int(v) return math.floor(tonumber(v) or 0) end

local Dlg = ISPanel:derive("MinidoracatEconomyWantedDialog")

-- ---------- controls ----------

local function field(dlg, width, maxLen, numbers, placeholder)
    local f = U.framework.TextField.new({ width = width, height = math.max(26, fontH.small + 12), theme = U.theme,
        onlyNumbers = numbers, maxLength = maxLen, placeholder = placeholder,
        onChange = function() dlg:edited() end })
    dlg:addChild(f)
    return f
end

local function button(dlg, title, onClick, style)
    local b = U.Button.create(0, 0, textWidth(title) + 22, math.max(CHIP_H, fontH.small + 8), title, dlg, onClick,
        style or "chip")
    dlg:addChild(b)
    return b
end

-- A whole positive number typed into a field, or nil.
local function number(f)
    local raw = string.match(f:getText() or "", "^%s*(%d+)%s*$")
    local n = raw and tonumber(raw) or nil
    if n == nil or n < 1 then return nil end
    return math.floor(n)
end

function D.new(kind, panel, page, ctx)
    local dlg = ISPanel:new(0, 0, 480, 200)
    setmetatable(dlg, Dlg)
    dlg.background = false
    dlg.kind, dlg.panel, dlg.page, dlg.ctx = kind, panel, page, ctx
    dlg.info = ctx.info
    dlg.all, dlg.priceNow = {}, {}
    dlg:initialise()
    panel:addChild(dlg)     -- instantiate -> createChildren
    dlg:open()
    return dlg
end

-- Every control a form builds goes in self.all, so the layout can hide what the form does not
-- place this time (a coin option has no group box, a removed option nothing at all).
function Dlg:add(control)
    self.all[#self.all + 1] = control
    return control
end

function Dlg:createChildren()
    local bh = math.max(28, fontH.medium + 10)
    self.confirmButton = U.Button.create(0, 0, 120, bh, "", self, Dlg.onConfirm, "primary")
    self.confirmButton.font = UIFont.Medium
    self:addChild(self.confirmButton)
    local cancel = tr("Admin_Cancel")
    self.cancelButton = U.Button.create(0, 0, textWidth(cancel) + 30, bh, cancel, self, Dlg.onCancel, "chip")
    self:addChild(self.cancelButton)
    self.summaryBox = U.newReader(self, 240, fontH.small * 2 + 12)
    self.combos = {}
    if self.kind == "create" then
        self:buildCreate()
    elseif self.kind == "fill" then
        self:buildFill()
    else
        self:buildOffer()
    end
end

function Dlg:firstControl()
    -- a framework TextField is focused through its native entry (the descriptor's control)
    local c = self.first or self.confirmButton
    return c._entry or c
end

function Dlg:closeCombos()
    for _, combo in ipairs(self.combos) do W.closeCombo(combo) end
end

function Dlg:dispose()
    self:closeCombos()
    Keys.blurInputs(self.panel)
    if self.picker then self.picker:dispose() end
end

function Dlg:onCancel() self.page:closeDialog() end

-- A field, a box or a choice changed: the reader and the confirm label follow on the next frame,
-- and a refusal shown next to a field the player is now editing is dropped. A refusal that marks
-- a button (no item picked yet) has no text to compare: picking the item drops it.
function Dlg:edited()
    self.dirtySummary = true
    local c = self.err and self.err.control
    if c and c.getText and self.err.text0 ~= c:getText() then self:setError(nil) end
end

-- The refusal on screen: `control` is the field it belongs to (nil: the request as a whole).
function Dlg:setError(text, control)
    local old = self.err and self.err.control
    if old and old.setInvalid then old:setInvalid(false) end
    self.err = text and { text = text, control = control, text0 = control and control.getText and control:getText() } or nil
    if control and control.setInvalid and control.getText then control:setInvalid(true, text) end
    self.panel:layoutDialog(self)
    Keys.invalidate(self.panel)
end

-- ---------- create ----------

function Dlg:buildCreate()
    local info = self.info
    self.itemButton = self:add(button(self, tr("Wanted_PickItem"), Dlg.onPickItem))
    self.qtyField = self:add(field(self, 80, 2, true, "1-" .. QTY_MAX))
    self.condTabs = self:add(W.modeTabs(self, { { id = "any", label = tr("Wanted_Cond_Any") },
        { id = "new", label = tr("Wanted_Cond_NewTab") }, { id = "min", label = tr("Wanted_Cond_MinTab") } }, "any",
        function(dlg) dlg:edited(); dlg.panel:layoutDialog(dlg) end))
    self.pctField = self:add(field(self, 70, 3, true, "1-100"))
    self.opt = {}
    local ids = W.currencyIds()
    for i = 1, OPTIONS_MAX do
        local o = { kind = "coin" }
        o.tabs = self:add(W.modeTabs(self, { { id = "coin", label = tr("Wanted_Kind_coin") },
            { id = "item", label = tr("Wanted_Kind_item") } }, "coin", Dlg.onOptionKind))
        o.tabs.internal = i
        o.cur = self:add(W.newCombo(self, 120, Dlg.onComboEdit))
        W.comboFill(o.cur, ids, W.currencyLabel, ids[math.min(i, #ids)])
        o.price = self:add(field(self, 100, 9, true, tr("Wanted_PriceHint", tostring(info.priceMin))))
        o.group = self:add(W.newCombo(self, 220, Dlg.onComboEdit))
        o.per = self:add(field(self, 70, 2, true, tr("Wanted_PerHint")))
        o.remove = self:add(button(self, tr("Wanted_RemoveOption"), Dlg.onRemoveOption))
        o.remove.internal = i
        self.combos[#self.combos + 1] = o.cur
        self.combos[#self.combos + 1] = o.group
        self.opt[i] = o
    end
    self.optCount = 1
    self.addButton = self:add(button(self, tr("Wanted_AddOption"), Dlg.onAddOption))
    self.first = self.itemButton
    -- last child: it paints over the whole dialog while it is open
    self.picker = C.ItemPicker.create(self, "market", function(rec) self:onItemPicked(rec) end,
        function() self.panel:layoutDialog(self) end, true)
    self:addChild(self.picker)
end

function Dlg:onPickItem()
    self:closeCombos()
    self.picker:open()
    self.panel:layoutDialog(self)
    Keys.invalidate(self.panel)
end

-- The type the order asks for. Whether a durability bar means anything for it is read from its
-- script (Item.getConditionMax, Item.java:851); without one the "at least N%" choice is shut.
function Dlg:onItemPicked(rec)
    self.itemType, self.itemName = rec.fullType, C.itemLabel(rec.fullType)
    local ok, max = pcall(function() return rec.script:getConditionMax() end)
    self.hasCondition = ok and (tonumber(max) or 0) > 0
    if not self.hasCondition and self.condTabs:getSelected() == "min" then self.condTabs:setSelected("any", true) end
    self.itemButton:setWidth(math.min(320, textWidth(self.itemName) + 22))
    U.setButtonTitle(self.itemButton, self.itemName)
    self:setError(nil)
    self:edited()
    Keys.focusControl(self.qtyField._entry, Keys.isKeyboardFocused(Keys.focused()))
end

function Dlg:onOptionKind(id, tabs)
    local i = tabs.internal
    if id == "item" then
        for j = 1, self.optCount do
            if j ~= i and self.opt[j].kind == "item" then
                tabs:setSelected("coin", true)
                self:setError(tr("Wanted_Err_OneItem"), nil)
                return
            end
        end
        -- the backpack groups come from the market's own candidate read
        self.page.panel:askCandidates(C.newRequestId())
    end
    self.opt[i].kind = id
    self:edited()
    self.panel:layoutDialog(self)
end

function Dlg:onComboEdit() self:edited() end

function Dlg:onAddOption()
    if self.optCount >= OPTIONS_MAX then return end
    self.optCount = self.optCount + 1
    local o = self.opt[self.optCount]
    o.kind = "coin"
    o.tabs:setSelected("coin", true)
    self:edited()
    self.panel:layoutDialog(self)
    Keys.invalidate(self.panel)
end

-- Removing an option moves the ones under it up, so the numbering stays 1..n with no gap.
function Dlg:onRemoveOption(b)
    if self.optCount <= 1 then return end
    for j = b.internal, self.optCount - 1 do
        local a, nxt = self.opt[j], self.opt[j + 1]
        a.kind = nxt.kind
        a.tabs:setSelected(nxt.kind, true)
        W.comboSelect(a.cur, nxt.cur:getOptionData(nxt.cur.selected))
        a.price:setText(nxt.price:getText())
        a.per:setText(nxt.per:getText())
        a.group.selected = nxt.group.selected
    end
    local last = self.opt[self.optCount]
    last.price:setText("")
    last.per:setText("")
    self.optCount = self.optCount - 1
    self:edited()
    self.panel:layoutDialog(self)
    Keys.invalidate(self.panel)
end

-- The backpack groups an item option may pay with: the market's candidate rows that may be listed.
function Dlg:fillGroups()
    local rows = {}
    for _, row in ipairs(self.panel.candidateRows or {}) do
        if row.ok then rows[#rows + 1] = row end
    end
    self.groups = rows
    local keys = {}
    for i = 1, #rows do keys[i] = i end
    for i = 1, OPTIONS_MAX do
        local box = self.opt[i].group
        local was = box:getOptionData(box.selected)
        W.comboFill(box, keys, function(k) return rows[k].detailText end, was)
    end
    self:edited()
end

function Dlg:condValue()
    local mode = self.condTabs:getSelected()
    if mode == "new" then return { new = true } end
    if mode == "min" then return { minPct = number(self.pctField) } end
    return nil
end

-- What each option costs as the form stands: per coin option its reserve and fee, the item
-- option's lot. Fields that do not read yet count as nothing.
function Dlg:createLines()
    local out = {}
    local qty = number(self.qtyField) or 0
    for i = 1, self.optCount do
        local o = self.opt[i]
        if o.kind == "coin" then
            local cur = o.cur:getOptionData(o.cur.selected)
            local held = (number(o.price) or 0) * qty
            local fee = X.pct(held, self.info.feePercent)
            local bal = cur and C.wallet and C.wallet.balances and C.wallet.balances[cur]
            out[#out + 1] = tr("Wanted_SumCoin", tostring(i), X.money(held, cur), X.money(fee, cur),
                X.money(held + fee, cur), X.money(bal and bal.available or 0, cur))
        else
            local g = self.groups and self.groups[o.group:getOptionData(o.group.selected)]
            out[#out + 1] = tr("Wanted_SumItem", tostring(i), tostring((number(o.per) or 0) * qty),
                g and g.name or tr("Wanted_NoGroup"))
        end
    end
    out[#out + 1] = ""
    if self.info.days > 0 then out[#out + 1] = tr("Wanted_SumDays", tostring(self.info.days)) end
    out[#out + 1] = tr("Wanted_SumSlot")
    out[#out + 1] = tr("Wanted_CancelNoRefund")
    return out
end

-- Every check the client can make before anything goes out: the text and the field, or nil.
function Dlg:checkCreate()
    if self.itemType == nil then return tr("Wanted_Err_NoItem"), self.itemButton end
    local qty = number(self.qtyField)
    if qty == nil or qty > QTY_MAX then return tr("Wanted_Err_Qty", tostring(QTY_MAX)), self.qtyField end
    local cond = self:condValue()
    if cond and cond.new == nil and (cond.minPct == nil or cond.minPct > 100 or self.hasCondition == false) then
        return tr("Wanted_Err_Pct"), self.pctField
    end
    local info, seen = self.info, {}
    for i = 1, self.optCount do
        local o = self.opt[i]
        if o.kind == "coin" then
            local cur = o.cur:getOptionData(o.cur.selected)
            if cur == nil or seen[cur] then return tr("Wanted_Err_SameCurrency"), nil end
            seen[cur] = true
            local price = number(o.price)
            if price == nil or price < info.priceMin or (info.priceMax > 0 and price > info.priceMax) then
                return X.errorText({ error = "price_range", min = info.priceMin, max = info.priceMax }), o.price
            end
            local need = price * qty + X.pct(price * qty, info.feePercent)
            local bal = C.wallet and C.wallet.balances and C.wallet.balances[cur]
            if bal and need > int(bal.available) then
                return X.errorText({ error = "insufficient_funds", needed = need - int(bal.available), currency = cur }), o.price
            end
        else
            local g = self.groups and self.groups[o.group:getOptionData(o.group.selected)]
            if g == nil then return tr("Wanted_Err_NoGroup"), nil end
            local per = number(o.per)
            if per == nil or per * qty > QTY_MAX or per * qty > g.count then
                return tr("Wanted_Err_Per", tostring(math.min(QTY_MAX, g.count)), tostring(qty)), o.per
            end
        end
    end
    return nil
end

function Dlg:createArgs()
    local qty = number(self.qtyField)
    local options = {}
    for i = 1, self.optCount do
        local o = self.opt[i]
        if o.kind == "coin" then
            options[i] = { kind = "coin", currency = o.cur:getOptionData(o.cur.selected), unitPrice = number(o.price) }
        else
            local g = self.groups[o.group:getOptionData(o.group.selected)]
            local per = number(o.per)
            local ids = {}
            for k = 1, per * qty do ids[k] = g.itemIds[k] end
            options[i] = { kind = "item", itemIds = ids, perUnit = per }
        end
    end
    return { item = self.itemType, qty = qty, cond = self:condValue(), options = options }
end

function Dlg:createRows(rows)
    rows[#rows + 1] = { label = tr("Wanted_F_Item"), items = { self.itemButton } }
    rows[#rows + 1] = { label = tr("Wanted_F_Qty"), items = { self.qtyField } }
    local condItems = { self.condTabs }
    if self.condTabs:getSelected() == "min" then condItems[2] = self.pctField end
    -- rev 12 shuts the choice itself; an older framework keeps it and checkCreate refuses it
    if self.condTabs.setItemEnabled then self.condTabs:setItemEnabled("min", self.hasCondition ~= false) end
    rows[#rows + 1] = { label = tr("Wanted_F_Cond"), items = condItems }
    for i = 1, self.optCount do
        local o = self.opt[i]
        local items = { o.tabs }
        if o.kind == "coin" then
            items[2], items[3] = o.cur, o.price
        else
            items[2], items[3] = o.group, o.per
        end
        if self.optCount > 1 then items[4] = o.remove end
        rows[#rows + 1] = { label = tr("Wanted_OptionN", tostring(i)), items = items }
    end
    if self.optCount < OPTIONS_MAX then rows[#rows + 1] = { label = "", items = { self.addButton } } end
end

-- ---------- fill ----------

function Dlg:buildFill()
    local v = self.ctx.view
    self.optButtons = {}
    for i, opt in ipairs(v.options or {}) do
        local b = self:add(button(self, X.optionText(opt), Dlg.onOptionPick))
        b.internal = i
        self.optButtons[i] = b
    end
    self.choice = 1
    self.groupBox = self:add(W.newCombo(self, 260, Dlg.onGroupPick))
    self.combos[1] = self.groupBox
    local step = math.max(CHIP_H, fontH.small + 8)
    self.minus = self:add(U.Button.create(0, 0, step + 6, step, "-", self, Dlg.onStep, "chip"))
    self.minus.internal = -1
    self:addChild(self.minus)
    self.qtyField = self:add(field(self, 70, 2, true, nil))
    self.plus = self:add(U.Button.create(0, 0, step + 6, step, "+", self, Dlg.onStep, "chip"))
    self.plus.internal = 1
    self:addChild(self.plus)
    self.first = self.optButtons[1]
    -- the seller's own copies of the type, judged against the order (one read, paced)
    self.candGate = C.ReadGate.create(function(_, requestId)
        C.sendWanted("candidates", { orderId = v.id, requestId = requestId })
    end)
    self.candGate:want("c", true)
end

function Dlg:onOptionPick(b)
    self.choice = b.internal
    self.acceptMail = nil
    self:edited()
end

function Dlg:onGroupPick()
    self:clampQty()
    self:edited()
end

function Dlg:group()
    return self.goodRows and self.goodRows[self.groupBox:getOptionData(self.groupBox.selected)] or nil
end

function Dlg:maxQty()
    local g = self:group()
    return math.min(int(self.ctx.view.qty), g and int(g.count) or 0)
end

function Dlg:clampQty()
    local n = number(self.qtyField)
    local max = self:maxQty()
    if max > 0 and (n == nil or n > max) then self.qtyField:setText(tostring(max)) end
end

function Dlg:onStep(b)
    local n = math.max(1, math.min(self:maxQty(), (number(self.qtyField) or 0) + b.internal))
    self.qtyField:setText(tostring(n))
    self:edited()
end

-- The unit price of a coin option as the server last quoted it (price_changed moves it).
function Dlg:unitPrice(i)
    return self.priceNow[i] or int(self.ctx.view.options[i].unitPrice)
end

-- The label of option i for `n` units: what reaches the seller, the tax already taken off.
function Dlg:optionLabel(i, n)
    local opt = self.ctx.view.options[i]
    if opt.kind == "coin" then
        local net, tax = X.net(self:unitPrice(i) * n, self.info.taxPercent)
        return tr("Wanted_FillCoin", X.optionText({ kind = "coin", unitPrice = self:unitPrice(i), currency = opt.currency }),
            X.money(net, opt.currency), X.money(tax, opt.currency))
    end
    return tr("Wanted_FillItem", X.optionText(opt), tostring(int(opt.perUnit) * n), C.itemLabel(opt.item))
end

-- wanted.candidates: the groups the order takes fill the box, the others are counted and named.
function Dlg:onRead(kind, args)
    if kind == "market.candidates" then
        if self.kind == "create" then self:fillGroups() end
        return
    end
    if self.kind ~= "fill" or self.candGate:accept(args) == "stale" then return end
    if args.ok == false then
        self.candError = args.error
        self:setError(X.errorText(args), nil)
        return
    end
    local good, bad = {}, {}
    for _, row in ipairs(args.rows or {}) do
        if row.verdict == "ok" then good[#good + 1] = row else bad[#bad + 1] = row end
    end
    self.goodRows, self.badRows, self.candError = good, bad, nil
    local keys = {}
    for i = 1, #good do keys[i] = i end
    W.comboFill(self.groupBox, keys, function(k)
        local row = good[k]
        local tokens = W.stateTokens(row.state)
        local name = C.itemLabel(row.item)
        return tr("Wanted_Group", tostring(int(row.count)), tokens[1] and tr("Card_Join2", name, tokens[1]) or name)
    end, 1)
    self:clampQty()
    self:edited()
    self.panel:layoutDialog(self)
end

function Dlg:fillLines()
    local v = self.ctx.view
    local out = { tr("Card_Join2", tr("Wanted_LeftQty", tostring(int(v.qty))), X.condText(v.cond) or tr("Wanted_Cond_Any")) }
    if self.goodRows == nil then
        out[#out + 1] = tr(self.candError and "Wanted_CandFailed" or "Wallet_Loading")
        return out
    end
    if #self.goodRows == 0 then out[#out + 1] = tr("Wanted_NoneToGive") end
    for _, row in ipairs(self.badRows) do
        out[#out + 1] = tr("Wanted_NotTaken", tostring(int(row.count)), X.verdictText(row))
    end
    if self.acceptMail then out[#out + 1] = tr("Wanted_MailAccepted") end
    return out
end

function Dlg:checkFill()
    if self:group() == nil then return tr("Wanted_NoneToGive"), nil end
    local n = number(self.qtyField)
    if n == nil or n > self:maxQty() then
        return tr("Wanted_Err_FillQty", tostring(self:maxQty())), self.qtyField
    end
    return nil
end

function Dlg:fillArgs()
    local g, n, i = self:group(), number(self.qtyField), self.choice
    local ids = {}
    for k = 1, n do ids[k] = g.itemIds[k] end
    local opt = self.ctx.view.options[i]
    return { orderId = self.ctx.view.id, option = i, itemIds = ids,
        unitPrice = opt.kind == "coin" and self:unitPrice(i) or nil, acceptMail = self.acceptMail }
end

function Dlg:fillRows(rows)
    local n = math.max(1, number(self.qtyField) or 1)
    for i, b in ipairs(self.optButtons) do
        local label = self:optionLabel(i, n)
        if b.fullTitle ~= label then
            b:setWidth(math.min(self.fieldW, textWidth(label) + 22))
            U.setButtonTitle(b, label)
        end
        b.active = i == self.choice
    end
    rows[#rows + 1] = { label = tr("Wanted_F_PayWith"), items = self.optButtons, stack = true }
    rows[#rows + 1] = { label = tr("Wanted_F_Give"), items = { self.groupBox } }
    rows[#rows + 1] = { label = tr("Wanted_F_Qty"), items = { self.minus, self.qtyField, self.plus } }
end

-- ---------- offer ----------

function Dlg:buildOffer()
    local v = self.ctx.view
    self.optButtons = {}
    for i, opt in ipairs(v.options or {}) do
        if opt.kind == "coin" then
            local b = self:add(button(self, X.optionText(opt), Dlg.onOptionPick))
            b.internal = i
            self.optButtons[#self.optButtons + 1] = b
            self.choice = self.choice or i
        end
    end
    self.priceField = self:add(field(self, 100, 9, true, nil))
    self.qtyField = self:add(field(self, 70, 2, true, "1-" .. tostring(int(v.qty))))
    self.qtyField:setText(tostring(int(v.qty)))
    self.memoField = self:add(field(self, 260, MEMO_MAX, false, tr("Wanted_MemoHint")))
    self.first = self.priceField
end

function Dlg:offerLines()
    local opt = self.ctx.view.options[self.choice]
    return { tr("Wanted_OfferNow", X.money(opt.unitPrice, opt.currency)), tr("Wanted_OfferHow"), tr("Wanted_OfferFree") }
end

function Dlg:checkOffer()
    local v = self.ctx.view
    local opt = v.options[self.choice]
    local price = number(self.priceField)
    if price == nil or price <= int(opt.unitPrice) then
        return X.errorText({ error = "offer_not_higher", unitPrice = opt.unitPrice }), self.priceField
    end
    if self.info.priceMax > 0 and price > self.info.priceMax then
        return X.errorText({ error = "price_range", max = self.info.priceMax }), self.priceField
    end
    local n = number(self.qtyField)
    if n == nil or n > int(v.qty) then return X.errorText({ error = "qty_exceeded", qty = v.qty }), self.qtyField end
    local memo = string.match(self.memoField:getText() or "", "^%s*(.-)%s*$")
    if X.charCount(memo) > MEMO_MAX then return tr("Wanted_Err_Memo", tostring(MEMO_MAX)), self.memoField end
    return nil
end

function Dlg:offerArgs()
    local memo = string.match(self.memoField:getText() or "", "^%s*(.-)%s*$")
    return { orderId = self.ctx.view.id, option = self.choice, unitPrice = number(self.priceField),
        qty = number(self.qtyField), memo = memo ~= "" and memo or nil }
end

function Dlg:offerRows(rows)
    for _, b in ipairs(self.optButtons) do
        b.active = b.internal == self.choice
    end
    if #self.optButtons > 1 then rows[#rows + 1] = { label = tr("Wanted_F_Option"), items = self.optButtons } end
    rows[#rows + 1] = { label = tr("Wanted_F_OfferPrice"), items = { self.priceField } }
    rows[#rows + 1] = { label = tr("Wanted_F_Qty"), items = { self.qtyField } }
    rows[#rows + 1] = { label = tr("Wanted_F_Memo"), items = { self.memoField } }
end

-- ---------- the write ----------

local CHECKS = { create = "checkCreate", fill = "checkFill", offer = "checkOffer" }
local ARGS = { create = "createArgs", fill = "fillArgs", offer = "offerArgs" }

-- A stable text of what the press asks for: the same text is the same request (same requestId).
local function keyOf(v)
    if type(v) ~= "table" then return tostring(v) end
    local parts = {}
    for k, x in pairs(v) do parts[#parts + 1] = tostring(k) .. "=" .. keyOf(x) end
    EC.sortSafe(parts, function(a, b) return a < b end)
    return "{" .. table.concat(parts, ",") .. "}"
end

function Dlg:onConfirm()
    if self.page:busy() then return end
    local gate = self.page:gateReason(self.kind == "create")
    if gate then return self:setError(gate, nil) end
    local msg, control = self[CHECKS[self.kind]](self)
    if msg then return self:setError(msg, control) end
    local args = self[ARGS[self.kind]](self)
    local key = keyOf(args)
    if not (self.sent and self.sent.key == key) then self.sent = { key = key, requestId = C.newRequestId() } end
    args.requestId = self.sent.requestId
    self:setError(nil)
    local item = self.kind == "create" and args.item or self.ctx.view.item
    self.page:send(self.kind, args, item, self.kind)
end

-- The server refused: the next press is a new request. Two refusals are a question put back to
-- the player rather than a dead end -- the mailbox (mail_confirmation_required) and a price that
-- moved (price_changed) -- and both are answered by pressing again.
local FIELD_OF = { qty_exceeded = "qtyField", offer_not_higher = "priceField", price_range = "priceField" }
local REREAD = { not_new = true, worn = true, wrong_item = true, item_not_found = true, mixed_items = true }

function Dlg:onRefused(args)
    self.sent = nil
    local code = tostring(args.error or "")
    if code == "mail_confirmation_required" then self.acceptMail = true end
    if code == "price_changed" and tonumber(args.unitPrice) then self.priceNow[self.choice] = int(args.unitPrice) end
    if self.kind == "fill" and REREAD[code] then self.candGate:want("c", true) end
    if code == "item_not_found" and self.kind == "create" then self.panel:askCandidates(C.newRequestId()) end
    self.dirtySummary = true
    local name = FIELD_OF[code]
    self:setError(X.errorText(args), name and self[name] or nil)
end

-- No answer: it may or may not have landed. Nothing is resent; a press repeats the same request.
function Dlg:onTimeout()
    self:setError(X.errorText({ error = "timeout" }), nil)
end

-- ---------- geometry ----------

-- One labelled row after another: the label left (fitted when painted), the controls right of it,
-- wrapped onto a further line when the dialog is too narrow; `stack` puts one control per line.
function Dlg:placeRows(rows, y)
    self.labels = {}
    self.targets = {}
    local right = self.width - PAD
    for _, row in ipairs(rows) do
        local x, lineY, lineH = self.fieldX, y, 0
        for _, c in ipairs(row.items) do
            if x > self.fieldX and (row.stack or x + c.width > right) then
                lineY = lineY + lineH + 4
                x, lineH = self.fieldX, 0
            end
            c:setX(x); c:setY(lineY)
            c:setVisible(true)
            x = x + c.width + 6
            lineH = math.max(lineH, c.height)
            local d = { kind = "button", control = c, label = row.label ~= "" and row.label or c.fullTitle }
            if c.addOptionWithData then
                d.kind = "combo"
            elseif c._focusKind == "entry" then
                d.kind, d.control, d.frame = "entry", c._entry, c
            end
            self.targets[#self.targets + 1] = d
        end
        self.labels[#self.labels + 1] = { text = row.label, y = y, h = math.max(lineH, CHIP_H) }
        y = lineY + lineH + 8
    end
    return y
end

local TITLES = { create = "Wanted_CreateTitle", fill = "Wanted_FillTitle", offer = "Wanted_OfferTitle" }

function Dlg:title()
    if self.kind == "create" then return tr(TITLES.create) end
    local v = self.ctx.view
    return tr(TITLES[self.kind], tostring(v.owner or "-"), C.itemLabel(v.item))
end

function Dlg:confirmLabel()
    if self.kind == "create" then return tr("Wanted_Create") end
    if self.kind == "offer" then return tr("Wanted_OfferConfirm") end
    return tr("Wanted_FillConfirm", tostring(math.max(1, number(self.qtyField) or 1)))
end

function Dlg:lines()
    if self.kind == "create" then return self:createLines() end
    if self.kind == "fill" then return self:fillLines() end
    return self:offerLines()
end

function Dlg:layoutInside(maxW, maxH)
    local w = math.max(420, math.min(maxW, 680))
    if self.picker and self.picker:isOpen() then
        -- the item picker takes the whole band while it is open
        self:setWidth(maxW); self:setHeight(maxH)
        self.picker:setX(0); self.picker:setY(0)
        self.picker:resize(maxW, maxH)
        return
    end
    self:setWidth(w)
    for _, c in ipairs(self.all) do c:setVisible(false) end
    local labelW = math.floor(w * 0.28)
    self.fieldX = PAD + labelW + PAD
    self.fieldW = w - self.fieldX - PAD
    self.labelW = labelW
    local y = PAD
    self.titleY = y
    y = y + fontH.medium + PAD
    local rows = {}
    if self.kind == "create" then self:createRows(rows)
    elseif self.kind == "fill" then self:fillRows(rows)
    else self:offerRows(rows) end
    y = self:placeRows(rows, y)
    -- what this layout hid gives up the keyboard and its popup (a hidden box keeps both otherwise)
    for _, c in ipairs(self.all) do
        if not c:getIsVisible() then
            if c._entry and c:isFocused() then c._entry:unfocus() end
            if c.expanded then W.closeCombo(c) end
        end
    end
    self.errY, self.errLines = nil, nil
    if self.err then
        self.errY = y
        self.errLines = U.wrapText(self.err.text, w - PAD * 2, 3)
        y = y + #self.errLines * (fontH.small + 2) + 6
    end
    local lines = self:lines()
    local buttonH = self.cancelButton.height
    local room = maxH - y - PAD - buttonH - PAD
    local box = self.summaryBox
    box:setX(PAD); box:setY(y); box:setWidth(w - PAD * 2)
    box:setHeight(math.max(fontH.small + 12, math.min(W.readerHeight(lines, w - PAD * 2), room)))
    W.setSummary(self, lines)
    self.dirtySummary = false
    y = y + box.height + PAD
    local label = self:confirmLabel()
    local cb = self.confirmButton
    cb:setWidth(math.max(120, math.min(w - PAD * 3 - self.cancelButton.width, textWidth(label, UIFont.Medium) + 40)))
    U.setButtonTitle(cb, label, UIFont.Medium)
    cb:setX(w - PAD - cb.width); cb:setY(y)
    self.cancelButton:setX(cb.x - 8 - self.cancelButton.width); self.cancelButton:setY(y)
    self:setHeight(y + buttonH + PAD)
end

function Dlg:keyboardTargets()
    if self.picker and self.picker:isOpen() then return self.picker:keyboardTargets() end
    local out = {}
    for _, d in ipairs(self.targets or {}) do out[#out + 1] = d end
    out[#out + 1] = { kind = "scroll", control = self.summaryBox, focusable = false, label = tr("Kb_Detail") }
    out[#out + 1] = { kind = "group", controls = { self.confirmButton, self.cancelButton }, label = tr("Kb_Dialog_Actions") }
    return out
end

function Dlg:open()
    if self.kind == "create" then self.panel:askCandidates(C.newRequestId()) end
end

-- ---------- paint ----------

function Dlg:prerender()
    local w, h = self.width, self.height
    fill(self, 0, 0, w, h, "surface")
    border(self, 0, 0, w, h, "accent")
    if self.candGate then
        self.candGate:pump(true)
        -- a candidate read is safe to repeat: one that never came back is simply asked again
        if self.candGate:expired() then self.candGate:want("c", true) end
    end
    if self.picker and self.picker:isOpen() then return end
    if self.dirtySummary then self.panel:layoutDialog(self) end
    text(self, fitText(self:title(), w - PAD * 2, UIFont.Medium), PAD, self.titleY, "text", UIFont.Medium)
    for _, l in ipairs(self.labels or {}) do
        if l.text ~= "" then
            text(self, fitText(l.text, self.labelW), PAD, l.y + math.floor((l.h - fontH.small) / 2), "textMuted")
        end
    end
    if self.errY then
        for i, line in ipairs(self.errLines) do
            text(self, line, PAD, self.errY + (i - 1) * (fontH.small + 2), "errorText")
        end
    end
    local busy = self.page:busy()
    self.confirmButton:setEnable(not busy and self.page:gateReason(self.kind == "create") == nil)
    self.confirmButton.tooltip = self.page:gateReason(self.kind == "create")
end

function Dlg:render() end
function Dlg:onMouseDown() return true end
function Dlg:onMouseUp() return true end
function Dlg:onMouseMove() return true end

D.Dialog = Dlg

return D
