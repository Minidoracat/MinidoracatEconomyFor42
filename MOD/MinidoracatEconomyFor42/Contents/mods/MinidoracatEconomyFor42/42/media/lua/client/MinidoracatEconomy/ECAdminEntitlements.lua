-- MinidoracatEconomyFor42 -- admin integration plan page (client). Adds exactly one namespace:
-- C.AdminEntitlements.
--
--   C.AdminEntitlements.create(owner, send, isPending, newRequestId)
--       an initialised ISPanel child, NOT added (the admin controller addChild's it). The three
--       transport functions are the controller's own and are always called as self.send(...),
--       self.isPending(...), self.newRequestId() -- never with ":". The page owns no Events hook
--       and no timer: the controller calls tick(now) while this tab is on screen.
--
-- One command, admin.entitlements, three actions, one slot (the controller's): at most one of
-- them is open at a time and a reply is matched against exactly that request.
--   plans     every registered source product:
--             { sourceMod, productId, nameKey, loaded, instant, plan, lastChange, source }
--   account   { username } -> every entitlement snapshot of that exact account
--   refund    { username, sourceMod, productId, orderId, reason }
--
-- Two sections, switched by the page's own tabs:
--   plans     the product list on the left, a read-only overview of the picked product on the
--             right: its current terms, where they were last changed, and the source's settings
--             file with the problem it last reported. The terms belong to the source mod (its
--             settings file or its own in-game settings); this page never writes them.
--   accounts  an exact account read: every product it holds with each of its rentals, the recent
--             orders of the picked one (each rental order names its rental, scheduler renewals are
--             marked) and the full record. A refund goes through a confirm step with a reason.
--             Admins can read a player's auto-renew choices but never change them.
-- A refund is a two step affair: Review builds the summary of exactly what will be sent and locks
-- it; Confirm sends that, once. A timeout is reported as an unknown outcome and never re-sent.
--
-- Controls are the MinidoracatUI rev 7 modern primitives (Tabs, Button, TextField); the lists are
-- the shared VirtualList tables and the long read-only texts the shared reader.

require "ISUI/ISPanel"
if not MinidoracatEconomy or not MinidoracatEconomy.Client or not MinidoracatEconomy.Client.UI then
    require "MinidoracatEconomy/ECWidgets"
end

local EC = MinidoracatEconomy
local C = EC.Client
local U = C.UI

local P = {}
C.AdminEntitlements = P

local PAD, T = U.PAD, U.T
local CARD_TITLE_H = U.CARD_TITLE_H
local fontH = U.fontH
local text, textWidth, fitText, textRight = U.text, U.textWidth, U.fitText, U.textRight
local amountText, card = U.amountText, U.card

local COMMAND = "admin.entitlements"
local REASON_MAX = 1000
local ACCOUNT_MAX = 64

local function tr(key) return getText(T .. key) end
local function lineH() return fontH.small + 6 end
local function ctrlH() return math.max(26, fontH.small + 12) end
local function rowH2() return lineH() * 2 + 12 end
local function titleH() return math.max(CARD_TITLE_H, fontH.medium + 10) end
local function trim(s) return string.match(tostring(s or ""), "^%s*(.-)%s*$") end
local function keyOf(sourceMod, productId) return tostring(sourceMod) .. "\1" .. tostring(productId) end
local function Ent() return C.Entitlements end

-- Kahlua strings count UTF-16 units, standard Lua counts bytes: the reason bound is in characters.
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

local function controls()
    local ui = U.framework
    if ui ~= nil and (ui.API_REVISION or 0) >= 7 and ui.CAPABILITIES and ui.CAPABILITIES.controls == true
        and ui.Button and ui.TextField and ui.Tabs then
        return ui
    end
    return nil
end

-- ---------- values ----------

local function boolText(v) return tr(v == true and "Ent_On" or "Ent_Off") end
local function yesNo(v) return tr(v == true and "Ent_Yes" or "Ent_No") end

local function orderIdOf(o)
    if type(o) ~= "table" then return nil end
    local id = o.orderId or o.id
    return id ~= nil and tostring(id) or nil
end

-- Orders are paid | refunded (paid = true) or proven unpaid: unsubmitted | declined | rolledback
-- (paid = false, final). Only a paid order is offered; the server re-checks every refund (only
-- the latest order of a product or of one rental may be refunded -- refund_not_latest -- and it
-- says so if not).
local function refundable(o)
    if type(o) ~= "table" or orderIdOf(o) == nil then return false end
    if o.refundable ~= nil then return o.refundable == true end
    return o.status == "paid" and o.paid ~= false
end

-- A rental is shown by its place in the server's list (creation order); nil once it is gone.
local function rentalIndex(ent, id)
    if id == nil or type(ent) ~= "table" or type(ent.rentals) ~= "table" then return nil end
    for i, r in ipairs(ent.rentals) do
        if type(r) == "table" and r.id == id then return i end
    end
    return nil
end

local function rentalTag(ent, id)
    local i = rentalIndex(ent, id)
    return i ~= nil and getText(T .. "Ent_RentalNo", tostring(i)) or getText(T .. "Ent_RentalGone")
end

local function wrapInto(lines, s, width, token, maxLines)
    for _, part in ipairs(U.wrapText(s, width, maxLines)) do
        lines[#lines + 1] = { s = part, token = token }
    end
end

-- ---------- cells ----------

-- Two lines per row, each with an optional right-aligned figure. Texts are fitted once per width
-- and entry (bind resets the entry), never per frame.
local LineCell = ISPanel:derive("MinidoracatEconomyAdminEntCell")

function LineCell:render()
    local e = self.entry
    if not e then return end
    local lit = U.framework.Table.rowBackground(self)
    local w, lh = self.width, lineH()
    if self.fitW ~= w or self.fitE ~= e then
        local cap = math.floor(w * 0.45)
        self.r1 = e.right1 and fitText(e.right1, cap) or nil
        self.r2 = e.right2 and fitText(e.right2, cap) or nil
        local rw1 = self.r1 and textWidth(self.r1) + PAD or 0
        local rw2 = self.r2 and textWidth(self.r2) + PAD or 0
        self.t1 = fitText(e.line1 or "", math.max(0, w - PAD * 2 - rw1))
        self.t2 = fitText(e.line2 or "", math.max(0, w - PAD * 2 - rw2))
        self.fitW, self.fitE = w, e
    end
    text(self, self.t1, PAD, 6, e.token1 or "text")
    if self.r1 then textRight(self, self.r1, w - PAD, 6, e.rightToken1 or "accent") end
    local second = lit and "text" or (e.token2 or "textMuted")
    text(self, self.t2, PAD, 6 + lh, second)
    if self.r2 then textRight(self, self.r2, w - PAD, 6 + lh, second) end
end

-- ---------- the page ----------

local Page = ISPanel:derive("MinidoracatEconomyAdminEntPage")

local function setFieldWidth(field, width)
    if field.width ~= width then
        field:setWidth(width)
        field._entry:setWidth(math.max(10, width - 12))
    end
end

local function show(el, on)
    if el:getIsVisible() ~= on then el:setVisible(on) end
end

function Page:makeButton(key, style, onClick)
    local UI = controls()
    local title = tr(key)
    local b = UI.Button.new({ x = 0, y = 0, width = textWidth(title) + 20, height = ctrlH(), title = title,
        style = style, theme = U.theme, target = self, onClick = onClick })
    b.ecFull = title
    self:addChild(b)
    return b
end

function Page:createChildren()
    local UI = controls()
    if UI == nil then
        self.broken = true
        return
    end
    local theme, ch = U.theme, ctrlH()
    self.busyText = tr("Admin_Loading")

    self.tabs = UI.Tabs.new({ x = 0, y = 0, theme = theme, target = self, selected = self.section,
        items = { { id = "plans", label = tr("Ent_Section_plans") }, { id = "accounts", label = tr("Ent_Section_accounts") } },
        onSelect = function(page, id) page:setSection(id) end })
    -- the keyboard presses a descriptor through forceClick: Enter flips to the other section
    self.tabs.forceClick = function()
        self:setSection(self.section == "plans" and "accounts" or "plans")
    end
    self:addChild(self.tabs)

    -- plans section
    self.planList = U.newTable(LineCell, rowH2())
    self.planList.onSelect = function(_, item)
        if item then self:selectPlan(item.sourceMod, item.productId) end
    end
    self:addChild(self.planList)
    self.planBox = U.newReader(self, 300, 200)

    -- accounts section
    self.accountField = UI.TextField.new({ x = 0, y = 0, width = 220, height = ch, theme = theme,
        maxLength = ACCOUNT_MAX, placeholder = tr("Ent_AccountHint") })
    self.accountField._entry.onCommandEntered = function() self:onLookup() end
    self:addChild(self.accountField)
    self.lookupButton = self:makeButton("Ent_Lookup", "normal", Page.onLookup)
    self.entryList = U.newTable(LineCell, rowH2())
    self.entryList.onSelect = function(_, _, index) self:selectEntry(index) end
    self:addChild(self.entryList)
    self.orderList = U.newTable(LineCell, rowH2())
    self.orderList.onSelect = function(_, _, index) self:selectOrder(index) end
    self:addChild(self.orderList)
    self.detailBox = U.newReader(self, 300, 200)
    self.refundButton = self:makeButton("Ent_RefundButton", "danger", Page.onRefundReview)

    -- the confirm step (refunds)
    self.summaryBox = U.newReader(self, 300, 200)
    self.reasonField = UI.TextField.new({ x = 0, y = 0, width = 300, height = ch, theme = theme,
        maxLength = REASON_MAX, placeholder = tr("Ent_Reason") })
    self:addChild(self.reasonField)
    self.confirmButton = self:makeButton("Ent_Confirm_Refund", "danger", Page.onConfirm)
    self.backButton = self:makeButton("Ent_Back", "normal", Page.onBack)
    self.reviewButtons = { self.confirmButton, self.backButton }

    self:layout()
end

-- ---------- lookups ----------

function Page:entryFor(key)
    for _, e in ipairs(self.plans or {}) do
        if keyOf(e.sourceMod, e.productId) == key then return e end
    end
    return nil
end

function Page:selectedEntry()
    if self.selKey == nil then return nil end
    return self:entryFor(self.selKey)
end

function Page:writeInFlight()
    local s = self.sent
    return s ~= nil and s.action == "refund" and not s.answered and not s.timedOut
end

function Page:say(textValue, isError)
    self.message = { text = textValue, error = isError == true }
    self.owner.message = self.message
end

function Page:errorText(code)
    return Ent().errorText(code)
end

function Page:invalidateKeyboard()
    if C.Keyboard and C.Keyboard.invalidate then pcall(C.Keyboard.invalidate, self.owner.owner) end
end

function Page:unfocusAll()
    if self.broken then return end
    for _, f in ipairs({ self.accountField, self.reasonField }) do
        if f:isFocused() then f._entry:unfocus() end
    end
end

-- ---------- sections and selection ----------

function Page:setSection(id)
    if self.broken or (id ~= "plans" and id ~= "accounts") then return end
    if self.view == "review" then
        self.tabs:setSelected(self.section, true)
        return
    end
    self.section = id
    self.tabs:setSelected(id, true)
    self:unfocusAll()
    if id == "plans" and self.plans == nil then self.plansWanted = true end
    self:layout()
    self:invalidateKeyboard()
end

function Page:selectPlan(sourceMod, productId)
    if self.broken or self.view ~= "list" then return false end
    self:unfocusAll()
    self.selKey = keyOf(sourceMod, productId)
    self:rebuildPlanRows()
    self:layout()
    return self:selectedEntry() ~= nil
end

-- Another page (or a consumer's admin button) asked for one product's plan.
function Page:showPlan(sourceMod, productId)
    if self.broken then return end
    if self.view == "review" and not self:writeInFlight() then self:onBack() end
    self.section = "plans"
    self.tabs:setSelected("plans", true)
    if type(sourceMod) == "string" and type(productId) == "string" then
        self.pendingSelect = { sourceMod = sourceMod, productId = productId }
        if self:entryFor(keyOf(sourceMod, productId)) ~= nil then
            self.pendingSelect = nil
            self:selectPlan(sourceMod, productId)
        end
    end
    self.plansWanted = true
    self:layout()
end

-- ---------- the confirm step ----------

function Page:openReview()
    self.view = "review"
    self.reviewError = nil
    self:unfocusAll()
    self.reasonField:setText("")
    self:layout()
    self:invalidateKeyboard()
end

function Page:closeReview()
    self.view = "list"
    self.review, self.reviewError = nil, nil
    self:unfocusAll()
    self:invalidateKeyboard()
end

function Page:onBack()
    if self.view ~= "review" or self:writeInFlight() then return end
    self:closeReview()
    self:layout()
end

local function reasonError(reason)
    if reason == "" then return tr("Ent_ReasonMissing") end
    if string.find(reason, "%c") then return tr("Admin_Error_reason_invalid") end
    if charCount(reason) > REASON_MAX then return tr("Admin_Error_reason_too_long") end
    return nil
end

function Page:onConfirm()
    local r = self.review
    if self.view ~= "review" or r == nil or self:writeInFlight() then return end
    if not self.owner:writeAllowed() then
        self.reviewError = tr("Ent_ReadOnly")
        self:layout()
        return
    end
    local reason = trim(self.reasonField:getText())
    local bad = reasonError(reason)
    if bad ~= nil then
        self.reviewError = bad
        self:layout()
        return
    end
    local args = { action = "refund", username = r.username, sourceMod = r.sourceMod, productId = r.productId,
        orderId = r.orderId, reason = reason }
    local ok, why = self:sendAction(args, { action = "refund", username = r.username, orderId = r.orderId, review = r })
    self.reviewError = not ok and self:errorText(why) or nil
    self:layout()
end

-- ---------- transport ----------

function Page:sendAction(args, req)
    if self.isPending(COMMAND) then return false, "busy" end
    args.requestId = self.newRequestId()
    local ok, why = self.send(COMMAND, args)
    if not ok then return false, why end
    req.requestId = args.requestId
    self.sent = req
    self:updateEnabled()
    return true
end

function Page:requestPlans()
    if self:sendAction({ action = "plans" }, { action = "plans" }) then
        self.plansWanted, self.plansTimeout = false, false
        return true
    end
    return false
end

-- The controller cancelled a cooldown-held write before sending it: this is known, not a timeout.
function Page:onCancelled(requestId)
    local req = self.sent
    if req == nil or req.requestId ~= requestId or req.answered then return end
    req.answered = true
    if self.review == req.review then self:closeReview() end
    self:say(tr("Ent_ReadOnly"), true)
    self:layout()
end

function Page:requestAccount()
    local user = self.accountUser
    if user == nil then
        self.accountWanted = false
        return false
    end
    if self:sendAction({ action = "account", username = user }, { action = "account", username = user }) then
        self.accountWanted, self.accountTimeout = false, false
        return true
    end
    return false
end

-- Does this reply still belong to the request this page has open? Asked by the controller before
-- it frees the shared slot, and answered without touching a field.
function Page:matchesReply(args)
    local s = self.sent
    return type(args) == "table" and s ~= nil and not s.answered and args.requestId == s.requestId
end

function Page:onReply(args)
    local req = self.sent
    if not self:matchesReply(args) then return end
    req.answered = true
    if type(args.plans) == "table" then self:adoptPlans(args.plans) end
    if req.action == "plans" then
        if args.ok == false then
            self.plansError = args.error or "unknown"
            self:say(getText(T .. "Ent_PlansError", self:errorText(args.error)), true)
        else
            self.plansError = nil
        end
    elseif req.action == "account" then
        if args.ok == false then
            self.accountError = args.error or "unknown"
            self:say(getText(T .. "Ent_AccountError", self:errorText(args.error)), true)
        else
            self:adoptAccount(req.username, args.entries)
        end
    elseif req.action == "refund" then
        self:onRefundReply(args, req)
    end
    self:rebuildPlanRows()
    self:rebuildAccountRows()
    self:layout()
end

function Page:onRefundReply(args, req)
    if type(args.entries) == "table" then self:adoptAccount(req.username, args.entries) end
    if args.ok == true then
        if type(args.entries) ~= "table" then self.accountWanted = true end
        if self.review == req.review then self:closeReview() end
        local e = self:selectedAccountEntry()
        local ent = e and type(e.entitlement) == "table" and e.entitlement or nil
        local durable = ent and type(ent.durable) == "table" and Ent().durableText(ent.durable.status) or "-"
        self:say(getText(T .. (args.duplicate and "Ent_RefundDuplicate" or "Ent_Refunded"), tostring(req.orderId), durable))
        self:invalidateKeyboard()
    else
        self.reviewError = self:errorText(args.error)
        self:say(self.reviewError, true)
    end
end

-- A request whose answer never came. A read is owed again on the next refresh; a refund has an
-- unknown outcome and is never re-sent: the admin checks the account again.
function Page:onTimeout()
    local req = self.sent
    if req == nil or req.answered then return end
    req.timedOut = true
    if req.action == "plans" then
        self.plansTimeout = true
        self:say(tr("Ent_PlansTimeout"), true)
    elseif req.action == "account" then
        self.accountTimeout = true
        self:say(tr("Ent_AccountTimeout"), true)
    elseif req.action == "refund" then
        if self.review == req.review then self:closeReview() end
        self:say(tr("Ent_RefundTimeout"), true)
    end
    self:unfocusAll()
    self:rebuildPlanRows()
    self:layout()
    self:invalidateKeyboard()
end

function Page:adoptPlans(list)
    local out = {}
    for _, e in ipairs(list) do
        if type(e) == "table" and type(e.sourceMod) == "string" and type(e.productId) == "string"
            and type(e.plan) == "table" then
            out[#out + 1] = e
        end
    end
    self.plans = out
    self.plansTimeout = false
    self.updatedAt = EC.now()
    local want = self.pendingSelect
    if want ~= nil then
        self.pendingSelect = nil
        self.selKey = keyOf(want.sourceMod, want.productId)
        if self:selectedEntry() == nil then
            self:say(getText(T .. "Ent_UnknownProduct", want.sourceMod, want.productId), true)
        end
    end
    if self:selectedEntry() == nil and out[1] ~= nil then
        self.selKey = keyOf(out[1].sourceMod, out[1].productId)
    end
end

-- ---------- accounts ----------

function Page:onLookup()
    if self.broken or self.view ~= "list" then return end
    local user = trim(self.accountField:getText())
    if user == "" then
        self:say(tr("Ent_AccountHint"), true)
        return
    end
    if user ~= self.accountUser then
        self.account, self.entrySel, self.entryKey, self.orderSel, self.orderKey = nil, nil, nil, nil, nil
        self.accountError = nil
    end
    self.accountUser = user
    self.accountWanted = true
    self:tick(EC.now())
    self:rebuildAccountRows()
    self:layout()
end

function Page:adoptAccount(username, entries)
    if username ~= self.accountUser then return end
    local list = {}
    for _, e in ipairs(type(entries) == "table" and entries or {}) do
        if type(e) == "table" and type(e.sourceMod) == "string" and type(e.productId) == "string" then
            list[#list + 1] = e
        end
    end
    self.account = { username = username, entries = list, at = EC.now() }
    self.accountError, self.accountTimeout = nil, false
    self.entrySel = nil
    for i, e in ipairs(list) do
        if keyOf(e.sourceMod, e.productId) == self.entryKey then self.entrySel = i end
    end
    if self.entrySel == nil and list[1] ~= nil then self.entrySel = 1 end
    local e = self.entrySel and list[self.entrySel] or nil
    self.entryKey = e and keyOf(e.sourceMod, e.productId) or nil
    self.orderSel = nil
    for i, o in ipairs(self:selectedOrders()) do
        if orderIdOf(o) == self.orderKey then self.orderSel = i end
    end
    if self.orderSel == nil then self.orderKey = nil end
end

function Page:selectedAccountEntry()
    local acc = self.account
    if acc == nil or self.entrySel == nil then return nil end
    return acc.entries[self.entrySel]
end

function Page:selectedOrders()
    local e = self:selectedAccountEntry()
    return e ~= nil and type(e.orders) == "table" and e.orders or {}
end

function Page:selectedOrder()
    if self.orderSel == nil then return nil end
    return self:selectedOrders()[self.orderSel]
end

function Page:selectEntry(index)
    local acc = self.account
    if acc == nil or type(index) ~= "number" or acc.entries[index] == nil or self.view ~= "list" then return false end
    local e = acc.entries[index]
    self.entrySel, self.entryKey = index, keyOf(e.sourceMod, e.productId)
    self.orderSel, self.orderKey = nil, nil
    self:rebuildAccountRows()
    self:layout()
    return true
end

function Page:selectOrder(index)
    local o = type(index) == "number" and self:selectedOrders()[index] or nil
    if o == nil or self.view ~= "list" then return false end
    self.orderSel, self.orderKey = index, orderIdOf(o)
    self:rebuildAccountRows()
    self:layout()
    return true
end

function Page:onRefundReview()
    if self.view ~= "list" then return end
    local e, o = self:selectedAccountEntry(), self:selectedOrder()
    if not self.owner:writeAllowed() then
        self:say(tr("Ent_ReadOnly"), true)
        return
    end
    if e == nil or not refundable(o) then
        self:say(tr("Ent_RefundPick"), true)
        return
    end
    self.review = { kind = "refund", username = self.account.username, sourceMod = e.sourceMod,
        productId = e.productId, orderId = orderIdOf(o), text = self:refundSummary(self.account.username, e, o) }
    self:openReview()
end

-- ---------- texts (data changes only) ----------

local function num(v)
    local n = tonumber(v)
    return n ~= nil and tostring(n) or "-"
end

local function money(v)
    local n = tonumber(v)
    return n ~= nil and amountText(n) or "-"
end

-- A rental keeps the terms it was signed under and its consent the terms agreed to; either may
-- differ from today's plan (only price, currency and period decide whether a consent may charge).
local function termsDiffer(t, plan, withGrace)
    if type(plan) ~= "table" then return false end
    return tonumber(t.price) ~= tonumber(plan.rentalPrice) or t.currency ~= plan.rentalCurrency
        or tonumber(t.days) ~= tonumber(plan.rentalDays)
        or (withGrace and t.graceHours ~= nil and tonumber(t.graceHours) ~= tonumber(plan.graceHours))
end

function Page:stamp(ms)
    if type(ms) ~= "number" then return "-" end
    return U.stampText(ms, self.owner.offsetMin)
end

function Page:detailLine(out, key, value, indent)
    out[#out + 1] = (indent or "") .. getText(T .. "Ent_D_Line", tr("Ent_D_" .. key), tostring(value))
end

-- One rental, its state, dates and terms indented under a "#n" head (n = creation order).
function Page:rentalLines(out, i, r, plan)
    local E, sub = Ent(), "    "
    out[#out + 1] = "  " .. getText(T .. "Ent_RentalHead", tostring(i), num(r.quantity), E.stateText(r.state))
    if r.paidUntil ~= nil then self:detailLine(out, "PaidUntil", self:stamp(r.paidUntil), sub) end
    if r.graceUntil ~= nil then self:detailLine(out, "GraceUntil", self:stamp(r.graceUntil), sub) end
    local t = type(r.terms) == "table" and r.terms or nil
    if t ~= nil then
        self:detailLine(out, "RentTerms", getText(T .. "Ent_RentTermsValue", money(t.price), num(r.quantity),
            money(t.amount), t.currency and U.currencyName(t.currency) or "-")
            .. "  " .. getText(T .. "Ent_TermsPeriod", num(t.days), num(t.graceHours))
            .. (termsDiffer(t, plan, true) and ("  " .. tr("Ent_TermsDiffer")) or ""), sub)
    end
    self:detailLine(out, "AutoRenew", E.autoRenewText(r.autoRenewState or (r.autoRenew == true and "on" or "off")), sub)
    local a = type(r.autoTerms) == "table" and r.autoTerms or nil
    if a ~= nil then
        self:detailLine(out, "AutoTerms", getText(T .. "Ent_AutoTermsValue", money(a.price),
            a.currency and U.currencyName(a.currency) or "-", num(a.days))
            .. (termsDiffer(a, plan, false) and ("  " .. tr("Ent_TermsDiffer")) or ""), sub)
    end
    if r.termsRevision ~= nil then self:detailLine(out, "Terms", num(r.termsRevision), sub) end
    if r.pendingOrderId ~= nil then
        self:detailLine(out, "Pending", tostring(r.pendingOrderId)
            .. (r.autoPending == true and ("  " .. tr("Ent_AutoOrder")) or ""), sub)
    end
    self:detailLine(out, "RentalId", tostring(r.id or "-"), sub)
end

function Page:entryLines(out, e)
    local E = Ent()
    local ent = type(e.entitlement) == "table" and e.entitlement or {}
    self:detailLine(out, "Product", E.productName(e) .. " (" .. e.sourceMod .. " / " .. e.productId .. ")")
    self:detailLine(out, "State", E.stateText(ent.state))
    self:detailLine(out, "Usable", num(ent.usable))
    self:detailLine(out, "Permanent", num(ent.permanent))
    self:detailLine(out, "Rental", num(ent.rental))
    if (tonumber(ent.pendingQuantity) or 0) > 0 or ent.pendingOrderId ~= nil then
        self:detailLine(out, "Pending", num(ent.pendingQuantity) .. "  " .. tostring(ent.pendingOrderId or ""))
    end
    local rentals = type(ent.rentals) == "table" and ent.rentals or {}
    self:detailLine(out, "Rentals", getText(T .. "Ent_RentalsCount", tostring(#rentals), num(ent.rentalsMax),
        num(ent.rentalCommitted)))
    for i, r in ipairs(rentals) do
        if type(r) == "table" then self:rentalLines(out, i, r, e.plan) end
    end
    self:detailLine(out, "LastOrder", tostring(ent.lastOrderId or "-"))
    local dur = type(ent.durable) == "table" and ent.durable or {}
    local seqText = dur.seq ~= nil and ("  (" .. tostring(dur.source or "-") .. " #" .. tostring(dur.seq) .. ")") or ""
    self:detailLine(out, "Durable", E.durableText(dur.status) .. seqText)
    local wait = E.waitText(ent.wait)
    if wait then self:detailLine(out, "Durable", wait) end
    if ent.notice ~= nil then
        local rental = type(ent.notice) == "table" and ent.notice.rental or nil
        self:detailLine(out, "Notice", E.noticeText(ent.notice) .. (rental ~= nil and ("  " .. rentalTag(ent, rental)) or ""))
    end
    self:detailLine(out, "Plan", num(type(e.plan) == "table" and e.plan.revision or nil))
    self:detailLine(out, "Available", tr(e.available == true and "Ent_Yes" or "Ent_No"))
    if type(e.balances) == "table" then
        for id, b in pairs(e.balances) do
            if type(b) == "table" then
                self:detailLine(out, "Balance", amountText(b.available) .. " " .. U.currencyName(id))
            end
        end
    end
    out[#out + 1] = tr("Ent_AutoRenewNote")
end

local ORDER_FIELDS = {
    { key = "kind", label = "Kind" }, { key = "quantity", label = "Quantity" },
    { key = "status", label = "Status" }, { key = "at", label = "At", stamp = true },
    { key = "createdAt", label = "At", stamp = true }, { key = "paidUntil", label = "PaidUntil", stamp = true },
    { key = "refundedAt", label = "RefundedAt", stamp = true }, { key = "txId", label = "Tx" },
    { key = "refundTxId", label = "RefundTx" }, { key = "termsRevision", label = "Terms" },
    { key = "error", label = "Error" },
}
local ORDER_KNOWN = { orderId = true, id = true, amount = true, currency = true, refundable = true,
    durable = true, paid = true, final = true, rental = true, auto = true }
for _, f in ipairs(ORDER_FIELDS) do ORDER_KNOWN[f.key] = true end

-- ent: the entitlement the order belongs to, so a rental order can name its rental's place.
function Page:orderLines(out, o, ent)
    local E = Ent()
    self:detailLine(out, "Order", orderIdOf(o) or "-")
    if o.rental ~= nil then
        self:detailLine(out, "RentalOf", rentalTag(ent, o.rental) .. "  (" .. tostring(o.rental) .. ")"
            .. (o.auto == true and ("  " .. tr("Ent_AutoOrder")) or ""))
    end
    if o.amount ~= nil then
        self:detailLine(out, "Amount", amountText(o.amount) .. " " .. (o.currency and U.currencyName(o.currency) or ""))
    end
    for _, f in ipairs(ORDER_FIELDS) do
        local v = o[f.key]
        if v ~= nil then
            if f.stamp then v = self:stamp(tonumber(v))
            elseif f.key == "kind" then v = E.kindText(v)
            elseif f.key == "status" then v = E.orderStatusText(v)
            elseif f.key == "error" then v = E.errorText(v) end
            self:detailLine(out, f.label, v)
        end
    end
    if type(o.durable) == "table" then self:detailLine(out, "Durable", E.durableText(o.durable.status))
    elseif o.durable ~= nil then self:detailLine(out, "Durable", E.durableText(o.durable)) end
    self:detailLine(out, "Refundable", tr(refundable(o) and "Ent_Yes" or "Ent_No"))
    -- whatever else the server wrote for this order stays readable, in a stable order
    local extra = {}
    for k, v in pairs(o) do
        local kind = type(v)
        if not ORDER_KNOWN[k] and (kind == "string" or kind == "number" or kind == "boolean") then
            extra[#extra + 1] = tostring(k) .. ": " .. tostring(v)
        end
    end
    EC.sortSafe(extra, function(a, b) return a < b end)
    for _, s in ipairs(extra) do out[#out + 1] = s end
end

local function priceText(amount, currency)
    return money(amount) .. " " .. (type(currency) == "string" and U.currencyName(currency) or "-")
end

-- What the overview warns about above the terms, worst first: when the card runs out of room the
-- plain lines at the end give way first.
function Page:overviewNotices(entry, width)
    local lines = {}
    local problem = type(entry.source) == "table" and entry.source.problem or nil
    if type(problem) == "string" and problem ~= "" then
        wrapInto(lines, getText(T .. "Ent_FileProblem", problem), width, "warn", 4)
    end
    if entry.plan.provisional == true then wrapInto(lines, tr("Ent_Provisional"), width, "warn", 3) end
    if entry.loaded == false then wrapInto(lines, tr("Ent_NotLoaded"), width, "warn", 3) end
    wrapInto(lines, getText(T .. "Ent_Ids", entry.sourceMod, entry.productId, num(entry.plan.revision)), width, "textMuted", 2)
    wrapInto(lines, tr("Ent_ManagedBy"), width, "textMuted", 3)
    return lines
end

-- The current terms, the last change and the source's settings file, for the reader.
function Page:overviewText(entry)
    local plan, out, sub = entry.plan, {}, "  "
    self:detailLine(out, "Instant", tr(entry.instant == true and "Ent_Instant_Yes" or "Ent_Instant_No"))
    out[#out + 1] = ""
    out[#out + 1] = tr("Ent_Group_permanent")
    self:detailLine(out, "Open", yesNo(plan.permanentEnabled), sub)
    self:detailLine(out, "UnitPrice", priceText(plan.permanentPrice, plan.permanentCurrency), sub)
    self:detailLine(out, "Limit", getText(T .. "Ent_Slots", num(plan.permanentLimit)), sub)
    out[#out + 1] = ""
    out[#out + 1] = tr("Ent_Group_rental")
    self:detailLine(out, "Open", yesNo(plan.rentalEnabled), sub)
    self:detailLine(out, "PeriodPrice", priceText(plan.rentalPrice, plan.rentalCurrency), sub)
    self:detailLine(out, "PeriodDays", getText(T .. "Ent_Days", num(plan.rentalDays)), sub)
    self:detailLine(out, "RentalLimit", getText(T .. "Ent_Slots", num(plan.rentalLimit)), sub)
    self:detailLine(out, "Grace", getText(T .. "Ent_Hours", num(plan.graceHours)), sub)
    self:detailLine(out, "Reminder", getText(T .. "Ent_Hours", num(plan.reminderHours)), sub)
    self:detailLine(out, "AutoRenewAllowed", yesNo(plan.autoRenewAllowed), sub)
    out[#out + 1] = ""
    out[#out + 1] = tr("Ent_LastChangeHead")
    local c = type(entry.lastChange) == "table" and entry.lastChange or {}
    self:detailLine(out, "At", self:stamp(tonumber(c.at)), sub)
    self:detailLine(out, "Actor", tostring(c.actor or "-"), sub)
    self:detailLine(out, "Origin", c.origin == nil and "-"
        or (getTextOrNull(T .. "Ent_Origin_" .. tostring(c.origin)) or tostring(c.origin)), sub)
    if type(c.reason) == "string" and c.reason ~= "" then self:detailLine(out, "Reason", c.reason, sub) end
    out[#out + 1] = ""
    local file = type(entry.source) == "table" and entry.source.file or nil
    self:detailLine(out, "File", (type(file) == "string" and file ~= "") and file or tr("Ent_NoFile"))
    return table.concat(out, "\n")
end

function Page:refundSummary(username, e, o)
    local out = {}
    out[#out + 1] = getText(T .. "Ent_Review_Account", username)
    out[#out + 1] = getText(T .. "Ent_Review_Product", Ent().productName(e), e.sourceMod, e.productId)
    out[#out + 1] = ""
    self:orderLines(out, o, e.entitlement)
    out[#out + 1] = ""
    out[#out + 1] = "- " .. tr("Ent_Review_RefundEffect")
    if o.rental ~= nil then out[#out + 1] = "- " .. tr("Ent_Review_RefundRental") end
    out[#out + 1] = "- " .. tr("Ent_Review_NoUndo")
    return table.concat(out, "\n")
end

-- ---------- rows (data changes only) ----------

function Page:rebuildPlanRows()
    if self.broken then return end
    local items, sel = {}, nil
    for i, e in ipairs(self.plans or {}) do
        local key = keyOf(e.sourceMod, e.productId)
        local problem = type(e.source) == "table" and type(e.source.problem) == "string" and e.source.problem ~= ""
        items[i] = { sourceMod = e.sourceMod, productId = e.productId, line1 = Ent().productName(e),
            line2 = e.sourceMod .. " / " .. e.productId,
            right2 = getText(T .. "Ent_SaleShort", boolText(e.plan.permanentEnabled == true), boolText(e.plan.rentalEnabled == true)),
            token2 = (e.loaded == false or problem or e.plan.provisional == true) and "warn" or nil }
        if key == self.selKey then sel = i end
    end
    self.planList:setItems(items)
    self.planList:setSelectedIndex(sel)
    local entry = self:selectedEntry()
    self.planText = entry ~= nil and self:overviewText(entry) or nil
end

function Page:rebuildAccountRows()
    if self.broken then return end
    local E = Ent()
    local items = {}
    for i, e in ipairs(self.account and self.account.entries or {}) do
        local ent = type(e.entitlement) == "table" and e.entitlement or {}
        items[i] = { line1 = E.productName(e), right1 = E.stateText(ent.state),
            rightToken1 = (ent.state == "active" and "positive") or ((ent.state == "grace" or ent.state == "expired") and "warn") or "textMuted",
            line2 = getText(T .. "Ent_EntryLine", num(ent.usable), num(ent.permanent), num(ent.rental)),
            right2 = type(ent.rentals) == "table" and #ent.rentals > 0
                and getText(T .. "Ent_RentalsShort", tostring(#ent.rentals)) or nil }
    end
    self.entryList:setItems(items)
    self.entryList:setSelectedIndex(self.entrySel)
    local e, o = self:selectedAccountEntry(), self:selectedOrder()
    local selEnt = e ~= nil and e.entitlement or nil
    local orders = {}
    for i, row in ipairs(self:selectedOrders()) do
        if type(row) == "table" then
            local line2 = E.kindText(row.kind) .. "  " .. E.orderStatusText(row.status)
            if row.rental ~= nil then line2 = line2 .. "  " .. rentalTag(selEnt, row.rental) end
            if row.auto == true then line2 = line2 .. "  " .. tr("Ent_AutoOrder") end
            orders[i] = { line1 = orderIdOf(row) or "?",
                right1 = row.amount ~= nil and (amountText(row.amount) .. " " .. (row.currency and U.currencyName(row.currency) or "")) or nil,
                rightToken1 = "text",
                line2 = line2,
                right2 = self:stamp(tonumber(row.at or row.createdAt)),
                token2 = refundable(row) and nil or "textFaint" }
        else
            orders[i] = { line1 = "?" }
        end
    end
    self.orderList:setItems(orders)
    self.orderList:setSelectedIndex(self.orderSel)
    local out = {}
    if e ~= nil then self:entryLines(out, e) end
    if o ~= nil then
        out[#out + 1] = ""
        self:orderLines(out, o, selEnt)
    end
    self.detailText = table.concat(out, "\n")
end

-- ---------- geometry ----------

-- Places the buttons marked ecShow left to right, wrapping when a row is full; a label that does
-- not fit its budget is cut and offered whole as the tooltip. With y == nil it only measures.
function Page:flowButtons(buttons, x, width, y)
    local ch = ctrlH()
    local cx, cy, rows = x, y or 0, 1
    for _, b in ipairs(buttons) do
        if b.ecShow then
            local natural = textWidth(b.ecFull) + 20
            local bw = math.min(natural, width)
            if cx > x and cx + bw > x + width then
                cx, rows, cy = x, rows + 1, cy + ch + 4
            end
            if y ~= nil then
                show(b, true)
                b:setX(cx); b:setY(cy); b:setWidth(bw); b:setHeight(ch)
                b:setTitle(bw < natural and fitText(b.ecFull, bw - 20) or b.ecFull)
                b:setTooltip(bw < natural and b.ecFull or nil)
            end
            cx = cx + bw + 6
        elseif y ~= nil then
            show(b, false)
        end
    end
    return rows * ch + (rows - 1) * 4
end

function Page:layout()
    if self.broken then return end
    local w, h = self.width, self.height
    local g = {}
    self.g = g
    local review = self.view == "review"
    local plans = not review and self.section == "plans"
    local accounts = not review and self.section == "accounts"
    show(self.tabs, not review)
    g.topH = review and 0 or (self.tabs.height + 6)
    g.statusX = self.tabs.width + PAD
    g.statusY = math.floor((self.tabs.height - fontH.small) / 2)

    show(self.planList, plans)
    show(self.planBox, plans and self:selectedEntry() ~= nil)
    show(self.accountField, accounts)
    show(self.lookupButton, accounts)
    show(self.entryList, accounts)
    show(self.orderList, accounts)
    show(self.detailBox, accounts)
    show(self.refundButton, accounts)
    show(self.summaryBox, review)
    show(self.reasonField, review)
    show(self.confirmButton, review)
    show(self.backButton, review)

    if review then self:layoutReview(g, w, h)
    elseif plans then self:layoutPlans(g, w, h)
    else self:layoutAccounts(g, w, h) end
    self:updateEnabled()
end

function Page:layoutPlans(g, w, h)
    local top = g.topH
    local bodyH = math.max(ctrlH() * 3, h - top)
    local th = titleH()
    local lx, ly, lw, lh2, ex, ey, ew, eh
    if w < 640 then
        lx, ly, lw = 0, top, w
        lh2 = math.max(th + rowH2() * 2 + 4, math.floor(bodyH * 0.3))
        ex, ey, ew, eh = 0, top + lh2 + 6, w, math.max(ctrlH() * 3, bodyH - lh2 - 6)
    else
        lw = math.max(200, math.min(320, math.floor(w * 0.3)))
        lx, ly, lh2 = 0, top, bodyH
        ex, ey, ew, eh = lw + PAD, top, w - lw - PAD, bodyH
    end
    g.listCard = { x = lx, y = ly, w = lw, h = lh2, title = fitText(tr("Ent_Products"), lw - PAD * 2, UIFont.Medium) }
    U.placeList(self.planList, true, lx + 1, ly + th + 1, lw - 2, math.max(rowH2(), lh2 - th - 2))
    g.listEmpty = {}
    if self.plans == nil or #self.plans == 0 then
        local msg
        if self.plansTimeout then msg = tr("Ent_PlansTimeout")
        elseif self.plansError then msg = getText(T .. "Ent_PlansError", self:errorText(self.plansError))
        elseif self.plans == nil then msg = tr("Admin_Loading")
        else msg = tr("Ent_NoProducts") end
        wrapInto(g.listEmpty, msg, lw - PAD * 2, self.plansError and "errorText" or "textMuted", 6)
    end
    g.listEmptyY = ly + th + PAD
    g.edCard = { x = ex, y = ey, w = ew, h = eh }
    self:layoutOverview(g, ex, ey, ew, eh)
end

function Page:layoutOverview(g, ex, ey, ew, eh)
    local lh = lineH()
    local x, iw = ex + PAD, math.max(80, ew - PAD * 2)
    local entry = self:selectedEntry()
    g.edX, g.edLines, g.edLinesY, g.edTitle = x, {}, ey + PAD, nil
    if entry == nil then
        if self.plans ~= nil and #self.plans > 0 then wrapInto(g.edLines, tr("Ent_PickProduct"), iw, "textMuted", 3) end
        return
    end
    local y = ey + PAD
    g.edTitle = fitText(Ent().productName(entry), iw, UIFont.Medium)
    g.edTitleY = y
    y = y + fontH.medium + 4
    local bottom = ey + eh - PAD
    -- the notices give way before the terms do: three lines of terms always stay
    local lines = self:overviewNotices(entry, iw)
    local maxLines = math.max(1, math.floor((bottom - lh * 3 - y) / lh))
    while #lines > maxLines do table.remove(lines) end
    g.edLines, g.edLinesY = lines, y
    y = y + #lines * lh + 4
    self.planBox:setX(x)
    self.planBox:setY(y)
    self.planBox:setWidth(iw)
    self.planBox:setHeight(math.max(lh * 2, bottom - y))
    U.setWrappedText(self.planBox, self.planText or "", iw)
end

function Page:layoutReview(g, w, h)
    local lh, ch = lineH(), ctrlH()
    local r = self.review
    g.rvTitle = fitText(tr("Ent_Review_TitleRefund"), w, UIFont.Medium)
    local y = fontH.medium + 8
    self.confirmButton.ecShow, self.backButton.ecShow = true, true
    local barH = self:flowButtons(self.reviewButtons, 0, w, nil)
    local barY = h - barH
    self:flowButtons(self.reviewButtons, 0, w, barY)
    local lines = {}
    if self.reviewError ~= nil then wrapInto(lines, self.reviewError, w, "errorText", 3)
    elseif self:writeInFlight() then wrapInto(lines, tr("Ent_Sending"), w, "textMuted", 2)
    elseif not self.owner:writeAllowed() then wrapInto(lines, tr("Ent_ReadOnly"), w, "warn", 2) end
    g.rvLines = lines
    g.rvLinesY = barY - 4 - #lines * lh
    local fieldY = g.rvLinesY - 4 - ch
    g.rvReason = fitText(tr("Ent_Reason"), w)
    g.rvReasonY = fieldY - lh
    self.reasonField:setX(0)
    self.reasonField:setY(fieldY)
    setFieldWidth(self.reasonField, math.min(w, 720))
    self.summaryBox:setX(0)
    self.summaryBox:setY(y)
    self.summaryBox:setWidth(w)
    self.summaryBox:setHeight(math.max(lh * 2, g.rvReasonY - 6 - y))
    U.setWrappedText(self.summaryBox, r.text, w)
end

function Page:accountNote()
    if self.accountUser == nil then return tr("Ent_AccountHint"), "textMuted" end
    if self.accountTimeout then return tr("Ent_AccountTimeout"), "errorText" end
    if self.accountError ~= nil then return getText(T .. "Ent_AccountError", self:errorText(self.accountError)), "errorText" end
    if self.account == nil then return tr("Admin_Loading"), "textMuted" end
    if #self.account.entries == 0 then return getText(T .. "Ent_AccountEmpty", self.account.username), "textMuted" end
    return getText(T .. "Ent_AccountFor", self.account.username), "text"
end

function Page:layoutAccounts(g, w, h)
    local lh, ch, th = lineH(), ctrlH(), titleH()
    local top = g.topH
    local label = tr("Ent_Account")
    local labelW = math.min(textWidth(label), math.floor(w * 0.3))
    g.accLabel, g.accLabelY = fitText(label, labelW), top + math.floor((ch - fontH.small) / 2)
    local fx = labelW + 8
    local fw = math.max(120, math.min(260, math.floor(w * 0.35)))
    self.accountField:setX(fx)
    self.accountField:setY(top)
    setFieldWidth(self.accountField, fw)
    self.lookupButton.ecShow = true
    self:flowButtons({ self.lookupButton }, fx + fw + 6, math.max(60, w - fx - fw - 6), top)
    local noteX = self.lookupButton.x + self.lookupButton.width + PAD
    local note, token = self:accountNote()
    local y0 = top + ch + 6
    if w - noteX < 160 then
        noteX = 0
        g.accNoteY = y0
        y0 = y0 + lh + 4
    else
        g.accNoteY = g.accLabelY
    end
    g.accNote, g.accNoteX, g.accNoteToken = fitText(note, w - noteX), noteX, token
    self.refundButton.ecShow = true
    local barH = self:flowButtons({ self.refundButton }, 0, w, nil)
    local barY = h - barH
    self:flowButtons({ self.refundButton }, 0, w, barY)
    local bodyH = math.max(th * 3, barY - 6 - y0)
    local ec, oc, dc
    if w >= 700 then
        local lw = math.floor(w * 0.4)
        local rx, rw = lw + PAD, w - lw - PAD
        local oh = math.floor(bodyH * 0.45)
        ec = { x = 0, y = y0, w = lw, h = bodyH }
        oc = { x = rx, y = y0, w = rw, h = oh }
        dc = { x = rx, y = y0 + oh + 6, w = rw, h = bodyH - oh - 6 }
    else
        local eh, oh = math.floor(bodyH * 0.32), math.floor(bodyH * 0.28)
        ec = { x = 0, y = y0, w = w, h = eh }
        oc = { x = 0, y = y0 + eh + 6, w = w, h = oh }
        dc = { x = 0, y = y0 + eh + oh + 12, w = w, h = bodyH - eh - oh - 12 }
    end
    ec.title = fitText(tr("Ent_Entries"), ec.w - PAD * 2, UIFont.Medium)
    oc.title = fitText(tr("Ent_Orders"), oc.w - PAD * 2, UIFont.Medium)
    dc.title = fitText(tr("Ent_Details"), dc.w - PAD * 2, UIFont.Medium)
    g.cards = { ec, oc, dc }
    U.placeList(self.entryList, true, ec.x + 1, ec.y + th + 1, ec.w - 2, math.max(lh, ec.h - th - 2))
    U.placeList(self.orderList, true, oc.x + 1, oc.y + th + 1, oc.w - 2, math.max(lh, oc.h - th - 2))
    self.detailBox:setX(dc.x + 1)
    self.detailBox:setY(dc.y + th + 1)
    self.detailBox:setWidth(math.max(40, dc.w - 2))
    self.detailBox:setHeight(math.max(lh, dc.h - th - 2))
    U.setWrappedText(self.detailBox, self.detailText or "", self.detailBox.width)
    g.ordersEmpty = nil
    if self:selectedAccountEntry() ~= nil and #self:selectedOrders() == 0 then
        g.ordersEmpty = fitText(tr("Ent_NoOrders"), oc.w - PAD * 2)
    end
end

-- ---------- enabling ----------

function Page:updateEnabled()
    if self.broken then return end
    local read = self.owner:readAllowed()
    local write = read and self.owner:writeAllowed()
    local modal = self.owner.dialog ~= nil
    local pending = self.isPending(COMMAND)
    local listView = self.view == "list"
    local inFlight = self:writeInFlight()
    self.reasonOn = write and not modal and self.view == "review" and not inFlight
    self.reasonField:setEnabled(self.reasonOn)
    self.confirmButton:setEnabled(self.reasonOn and not pending)
    self.backButton:setEnabled(self.view == "review" and not inFlight)
    self.accountField:setEnabled(read and not modal and listView)
    self.lookupButton:setEnabled(read and not modal and listView and not pending)
    self.refundButton:setEnabled(write and not modal and listView and not pending and refundable(self:selectedOrder()))
    self.tabs.enable = listView and not modal
end

-- ---------- keyboard (ECKeyboard walks these; the page owns no key dispatch) ----------

function Page:keyboardTargets()
    if self.broken or not self:getIsVisible() then return {} end
    local out = {}
    if self.view == "review" then
        out[#out + 1] = { kind = "scroll", control = self.summaryBox, label = tr("Ent_Kb_Summary") }
        if self.reasonOn then
            out[#out + 1] = { kind = "entry", control = self.reasonField._entry, label = tr("Ent_Reason") }
        end
        out[#out + 1] = { kind = "group", controls = self.reviewButtons, label = tr("Ent_Kb_Actions") }
        return out
    end
    out[#out + 1] = { kind = "button", control = self.tabs, label = tr("Ent_Kb_Sections") }
    if self.section == "accounts" then
        out[#out + 1] = { kind = "entry", control = self.accountField._entry, label = tr("Ent_Account") }
        out[#out + 1] = { kind = "button", control = self.lookupButton, label = tr("Ent_Lookup") }
        out[#out + 1] = { kind = "list", control = self.entryList, label = tr("Ent_Kb_Entries") }
        out[#out + 1] = { kind = "list", control = self.orderList, label = tr("Ent_Kb_Orders") }
        out[#out + 1] = { kind = "scroll", control = self.detailBox, label = tr("Ent_Kb_Summary") }
        out[#out + 1] = { kind = "button", control = self.refundButton, label = self.refundButton.ecFull }
        return out
    end
    out[#out + 1] = { kind = "list", control = self.planList, label = tr("Ent_Kb_Plans") }
    if self.planBox:getIsVisible() then
        out[#out + 1] = { kind = "scroll", control = self.planBox, label = tr("Ent_Kb_Terms") }
    end
    return out
end

-- The confirm step owns the page while it is up: the navigation stays out of the ring and the
-- controller refuses a tab switch, exactly like its own write dialog.
function Page:isModal()
    return not self.broken and self.view == "review"
end

function Page:onEscape()
    if self.broken or self.view ~= "review" then return false end
    self:onBack()
    return true
end

-- ---------- drawing ----------

function Page:prerender()
    if self.broken then
        text(self, tr("Ent_NeedsFramework"), 0, 0, "errorText")
        return
    end
    local g = self.g
    if g == nil then return end
    local lh = lineH()
    if self.view ~= "review" and self.isPending(COMMAND) then
        text(self, self.busyText, g.statusX, g.statusY, "textMuted")
    end
    if self.view == "review" then
        text(self, g.rvTitle, 0, 0, "text", UIFont.Medium)
        text(self, g.rvReason, 0, g.rvReasonY, "text")
        for i, l in ipairs(g.rvLines) do text(self, l.s, 0, g.rvLinesY + (i - 1) * lh, l.token) end
    elseif self.section == "plans" then
        local c = g.listCard
        card(self, c.x, c.y, c.w, c.h, c.title, titleH())
        for i, l in ipairs(g.listEmpty) do text(self, l.s, c.x + PAD, g.listEmptyY + (i - 1) * lh, l.token) end
        c = g.edCard
        card(self, c.x, c.y, c.w, c.h)
        if g.edTitle then text(self, g.edTitle, g.edX, g.edTitleY, "text", UIFont.Medium) end
        for i, l in ipairs(g.edLines) do text(self, l.s, g.edX, g.edLinesY + (i - 1) * lh, l.token) end
    else
        text(self, g.accLabel, 0, g.accLabelY, "text")
        text(self, g.accNote, g.accNoteX, g.accNoteY, g.accNoteToken)
        for _, c in ipairs(g.cards) do card(self, c.x, c.y, c.w, c.h, c.title, titleH()) end
        if g.ordersEmpty then
            local c = g.cards[2]
            text(self, g.ordersEmpty, c.x + PAD, c.y + titleH() + PAD, "textMuted")
        end
    end
end

function Page:render() end

-- ---------- lifecycle ----------

-- The controller sizes the page on every one of its own layouts.
function Page:resize(width, height)
    if self.width ~= width then self:setWidth(width) end
    if self.height ~= height then self:setHeight(height) end
    self:layout()
end

-- Hiding keeps every snapshot; it only takes the keyboard out of the text boxes.
function Page:setVisible(visible)
    ISPanel.setVisible(self, visible)
    if not visible then self:unfocusAll() end
end

-- A refresh re-reads the section on screen; the read goes out on the next tick the shared slot
-- is free, so a write in flight is never displaced.
function Page:refresh()
    if self.broken then return end
    if self.section == "accounts" then
        if self.accountUser ~= nil then self.accountWanted = true end
    else
        self.plansWanted = true
    end
    self:tick(EC.now())
end

function Page:tick(now)
    if self.broken or not self.owner:readAllowed() or self.isPending(COMMAND) then return end
    if self.plansWanted then self:requestPlans()
    elseif self.accountWanted then self:requestAccount() end
end

-- The permission collapse: everything this page learned goes, and nothing is asked for again
-- until the controller says reading is allowed.
function Page:clear()
    if self.broken then return end
    self:unfocusAll()
    self.plans, self.plansError, self.plansTimeout, self.updatedAt = nil, nil, false, nil
    self.sent, self.review, self.reviewError, self.view = nil, nil, nil, "list"
    self.account, self.accountUser, self.accountError, self.accountTimeout = nil, nil, nil, false
    self.entrySel, self.entryKey, self.orderSel, self.orderKey = nil, nil, nil, nil
    self.plansWanted, self.accountWanted = false, false
    self.selKey, self.pendingSelect, self.message = nil, nil, nil
    self.detailText, self.planText = nil, nil
    self.accountField:setText("")
    self.reasonField:setText("")
    self.planList:setItems({})
    self.entryList:setItems({})
    self.orderList:setItems({})
    self:layout()
end

function Page:dispose()
    self:clear()
end

-- ---------- module API ----------

function P.create(owner, send, isPending, newRequestId)
    local o = ISPanel:new(0, 0, 600, 300)
    setmetatable(o, Page)
    o.background = false
    o.owner = owner
    o.send, o.isPending, o.newRequestId = send, isPending, newRequestId
    o.section = "plans"
    o.view = "list"
    o.plansWanted = true
    o:initialise()
    o:instantiate()
    o:setVisible(false)
    return o
end

return P
