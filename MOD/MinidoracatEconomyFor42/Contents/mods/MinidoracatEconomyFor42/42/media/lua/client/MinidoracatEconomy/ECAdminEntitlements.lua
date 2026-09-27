-- MinidoracatEconomyFor42 -- admin integration plan page (client). Adds exactly one namespace:
-- C.AdminEntitlements.
--
--   C.AdminEntitlements.create(owner, send, isPending, newRequestId)
--       an initialised ISPanel child, NOT added (the admin controller addChild's it). The three
--       transport functions are the controller's own and are always called as self.send(...),
--       self.isPending(...), self.newRequestId() -- never with ":". The page owns no Events hook
--       and no timer: the controller calls tick(now) while this tab is on screen.
--
-- One command, admin.entitlements, four actions, one slot (the controller's): at most one of
-- them is open at a time and a reply is matched against exactly that request.
--   plans     every registered source product with its flat plan, the sandbox sync status
--   apply     { sourceMod, productId, expectedRevision, values = <whole flat plan>, reason }
--   account   { username } -> every entitlement snapshot of that exact account
--   refund    { username, sourceMod, productId, orderId, reason }
--
-- Two sections, switched by the page's own tabs:
--   plans     the product list on the left, the plan editor on the right: the current plan and the
--             draft side by side, a draft kept per product until it is applied or discarded. A
--             draft remembers the revision it was started from; the server applies it only at that
--             revision. When the plan moves on (another admin, a sandbox edit) the draft is kept
--             and marked, Review is blocked, and only the admin's own "re-check" moves the draft
--             onto the new revision -- nothing is ever re-sent against a newer revision on its own.
--   accounts  an exact account read: every product it holds, the recent orders of the picked one
--             and the full record. A refund goes through the same confirm step with a reason.
--             Admins can read a player's auto-renew choice but never change it.
-- Every write is a two step affair: Review builds the summary of exactly what will be sent and
-- locks it; Confirm sends that, once. A timeout is reported as an unknown outcome and never
-- re-sent.
--
-- Controls are the MinidoracatUI rev 7 modern primitives (Tabs, Button, TextField, Checkbox); the
-- lists are the shared VirtualList tables and the long read-only texts the shared reader. The plan
-- fields scroll inside one form: a control that is outside the viewport is parked off screen but
-- stays visible, so the keyboard ring can land on it and the form scrolls it into view first
-- (MinidoracatUI/Focus.lua land() -> scrollOwner:scrollTo).

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
local fill, text, textWidth, fitText, textRight = U.fill, U.text, U.textWidth, U.fitText, U.textRight
local amountText, card = U.amountText, U.card

local COMMAND = "admin.entitlements"
local REASON_MAX = 1000
local ACCOUNT_MAX = 64
local SCROLL_W = 10
local PARK_Y = -10000
local ROW_GAP = 6
-- the plan moved on under the draft: kept, marked, never re-sent on its own
local CONFLICT = { revision_mismatch = true, stale_revision = true, revision_conflict = true,
    plan_changed = true, stale = true }

-- The flat plan (contract: plan shape). Ranges are the server's; this side only refuses to send
-- what the server would refuse anyway.
local FIELDS = {
    { key = "permanentEnabled", kind = "bool", group = "permanent" },
    { key = "permanentCurrency", kind = "currency", group = "permanent" },
    { key = "permanentPrice", kind = "int", min = 1, max = 1000000000, unit = "price", group = "permanent" },
    { key = "permanentLimit", kind = "int", min = 0, max = 1000, group = "permanent" },
    { key = "rentalEnabled", kind = "bool", group = "rental" },
    { key = "rentalCurrency", kind = "currency", group = "rental" },
    { key = "rentalPrice", kind = "int", min = 1, max = 1000000000, unit = "price", group = "rental" },
    { key = "rentalQuantity", kind = "int", min = 1, max = 1000, group = "rental" },
    { key = "rentalDays", kind = "int", min = 1, max = 365, unit = "days", group = "rental" },
    { key = "graceHours", kind = "int", min = 0, max = 168, unit = "hours", group = "renewal" },
    { key = "reminderHours", kind = "int", min = 0, max = 168, unit = "hours", group = "renewal" },
    { key = "autoRenewAllowed", kind = "bool", group = "renewal" },
}
local FIELD_BY_KEY = {}
for _, spec in ipairs(FIELDS) do FIELD_BY_KEY[spec.key] = spec end
local GROUPS = { "permanent", "rental", "renewal" }

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
        and ui.Button and ui.TextField and ui.Checkbox and ui.Tabs then
        return ui
    end
    return nil
end

-- ---------- values ----------

local function boolText(v) return tr(v == true and "Ent_On" or "Ent_Off") end

local function valueText(spec, v)
    if v == nil or v == "" then return "-" end
    if spec.kind == "bool" then return boolText(v) end
    if spec.kind == "currency" then return U.currencyName(v) end
    local n = tonumber(v)
    if n == nil then return tostring(v) end
    if spec.unit == "price" then return amountText(n) end
    if spec.unit == "hours" then return getText(T .. "Ent_Hours", tostring(n)) end
    if spec.unit == "days" then return getText(T .. "Ent_Days", tostring(n)) end
    return tostring(n)
end

-- plan value -> what the editor holds: typed text for numbers, the value itself otherwise
local function draftValue(spec, v)
    if spec.kind == "int" then
        local n = tonumber(v)
        return n ~= nil and tostring(math.floor(n)) or ""
    end
    if spec.kind == "bool" then return v == true end
    return v ~= nil and tostring(v) or ""
end

local function fieldError(spec, v)
    if spec.kind == "int" then
        local s = tostring(v or "")
        if string.match(s, "^%d+$") == nil then return true end
        local n = tonumber(s)
        return n == nil or n < spec.min or n > spec.max
    end
    if spec.kind == "currency" then return type(v) ~= "string" or v == "" end
    return false
end

local function differs(spec, v, base)
    if spec.kind == "int" then
        local a, b = tonumber(v), tonumber(base)
        if a ~= nil and b ~= nil then return a ~= b end
        return tostring(v or "") ~= (b ~= nil and tostring(b) or "")
    end
    if spec.kind == "bool" then return (v == true) ~= (base == true) end
    return tostring(v or "") ~= tostring(base or "")
end

local function copyPlan(plan)
    local out = {}
    if type(plan) == "table" then
        for k, v in pairs(plan) do out[k] = v end
    end
    return out
end

-- The whole flat plan without its revision, typed the way the server takes it.
local function payload(draft)
    local out = {}
    for _, spec in ipairs(FIELDS) do
        local v = draft.values[spec.key]
        if spec.kind == "int" then out[spec.key] = math.floor(tonumber(v) or 0)
        elseif spec.kind == "bool" then out[spec.key] = v == true
        else out[spec.key] = v end
    end
    return out
end

-- A synced projection can still carry a recorded stale-sandbox conflict.
local SANDBOX_WARN = { invalid = true, missing_option = true, write_failed = true, unavailable = true }

local function sandboxText(status)
    local s, detail = status, nil
    if type(status) == "table" then s, detail = status.state, status.error end
    if s == nil then s = "unmapped" end
    local out = getTextOrNull(T .. "Ent_Sandbox_" .. tostring(s)) or tostring(s)
    if type(detail) == "string" and detail ~= "" then out = out .. " (" .. detail .. ")" end
    if type(status) == "table" then
        if status.dirty then out = out .. " / " .. tr("Ent_Sandbox_dirty") end
        if status.conflict then out = out .. " / " .. tr("Ent_Sandbox_conflict") end
        if status.field then out = out .. " (" .. tostring(status.field) .. ")" end
    end
    return out
end

local function sandboxToken(status)
    local s = type(status) == "table" and status.state or status
    local warning = SANDBOX_WARN[s] or (type(status) == "table" and (status.dirty or status.conflict))
    return warning and "warn" or "textMuted"
end

local function orderIdOf(o)
    if type(o) ~= "table" then return nil end
    local id = o.orderId or o.id
    return id ~= nil and tostring(id) or nil
end

-- Orders are paid | refunded (paid = true) or proven unpaid: unsubmitted | declined | rolledback
-- (paid = false, final). Only a paid order is offered; the server re-checks every refund (only
-- the latest order of a product may be refunded -- refund_not_latest -- and it says so if not).
local function refundable(o)
    if type(o) ~= "table" or orderIdOf(o) == nil then return false end
    if o.refundable ~= nil then return o.refundable == true end
    return o.status == "paid" and o.paid ~= false
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

-- ---------- the scrolling plan form ----------

local Form = ISPanel:derive("MinidoracatEconomyAdminEntForm")

function Form:maxScrollOffset()
    return math.max(0, (self.contentH or 0) - self.height)
end

function Form:setScrollOffset(offset)
    local clamped = math.max(0, math.min(math.floor(offset), self:maxScrollOffset()))
    if clamped == self.scrollOffset then return end
    self.scrollOffset = clamped
    self.page:placeForm()
end

-- Bring one control (and its label while both fit) into the viewport. ecFormY / ecFormH /
-- ecFormLabelY are recorded for every row, in view or not.
function Form:scrollTo(control)
    local top = type(control) == "table" and control.ecFormY or nil
    if top == nil then return false end
    local bottom = top + (control.ecFormH or 0)
    local label = control.ecFormLabelY or top
    if bottom - label <= self.height then top = label end
    local offset = self.scrollOffset or 0
    if top < offset then self:setScrollOffset(top)
    elseif bottom > offset + self.height then self:setScrollOffset(bottom - self.height) end
    return true
end

function Form:onMouseWheel(del)
    if self:maxScrollOffset() <= 0 then return false end
    self:setScrollOffset((self.scrollOffset or 0) + del * lineH() * 3)
    return true
end

function Form:dragTo(y)
    self:setScrollOffset(self:maxScrollOffset() * y / math.max(1, self.height))
end

-- Like vanilla ISScrollBar: capture the mouse while dragging so the release always comes back
-- here, even over another window that would consume it and leave the form stuck dragging.
function Form:stopDrag()
    if self.dragging then
        self.dragging = false
        self:setCapture(false)
    end
end

function Form:onMouseDown(x, y)
    if self:maxScrollOffset() > 0 and x >= self.width - SCROLL_W then
        self.dragging = true
        self:setCapture(true)
        self:dragTo(y)
    end
    return true
end

function Form:onMouseMove()
    if self.dragging then self:dragTo(self:getMouseY()) end
end

function Form:onMouseMoveOutside()
    if self.dragging then self:dragTo(self:getMouseY()) end
end

function Form:onMouseUp()
    self:stopDrag()
    return true
end

function Form:onMouseUpOutside()
    self:stopDrag()
end

function Form:prerender()
    local paint = self.paint
    if paint ~= nil then
        for i = 1, #paint do
            local p = paint[i]
            text(self, p.s, p.x, p.y, p.token, p.font)
        end
    end
    local max = self:maxScrollOffset()
    if max > 0 then
        local h = self.height
        local thumb = math.max(20, math.floor(h * h / self.contentH))
        local ty = math.floor((h - thumb) * (self.scrollOffset or 0) / max)
        fill(self, self.width - 6, 0, 4, h, "track", "rect")
        fill(self, self.width - 6, ty, 4, thumb, "textFaint", "rect")
    end
end

function Form:render() end

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

    local form = ISPanel:new(0, 0, 200, 100)
    setmetatable(form, Form)
    form.background = false
    form.page = self
    form.scrollOffset = 0
    form.contentH = 0
    form:initialise()
    form:instantiate()
    self:addChild(form)
    self.form = form

    self.fieldControls, self.formControls, self.chips, self.chipOrder = {}, {}, {}, {}
    for _, spec in ipairs(FIELDS) do
        local c
        if spec.kind == "int" then
            c = UI.TextField.new({ x = 0, y = PARK_Y, width = 160, height = ch, theme = theme,
                onlyNumbers = true, maxLength = 10,
                placeholder = getText(T .. "Ent_Range", tostring(spec.min), amountText(spec.max)),
                onChange = function(field, value) self:setDraftValue(field.internal, value, true) end })
            c.scrollTo = function(field) return form:scrollTo(field) end
        elseif spec.kind == "bool" then
            c = UI.Checkbox.new({ x = 0, y = PARK_Y, width = 80, height = ch, label = boolText(false),
                theme = theme, target = self,
                onChange = function(page, checked, box) page:setDraftValue(box.internal, checked) end })
            c.forceClick = function(box)
                if box._enabled then box:setChecked(not box.checked) end
            end
        end
        if c ~= nil then
            c.internal = spec.key
            form:addChild(c)
            self.fieldControls[spec.key] = c
            self.formControls[#self.formControls + 1] = c
        end
    end

    self.reviewButton = self:makeButton("Ent_Review", "primary", Page.onReview)
    self.discardButton = self:makeButton("Ent_Discard", "normal", Page.onDiscard)
    self.recheckButton = self:makeButton("Ent_Recheck", "normal", Page.onRecheck)
    self.planButtons = { self.reviewButton, self.discardButton, self.recheckButton }

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

    -- the confirm step (either write)
    self.summaryBox = U.newReader(self, 300, 200)
    self.reasonField = UI.TextField.new({ x = 0, y = 0, width = 300, height = ch, theme = theme,
        maxLength = REASON_MAX, placeholder = tr("Ent_Reason") })
    self:addChild(self.reasonField)
    self.confirmButton = self:makeButton("Ent_Confirm_Apply", "primary", Page.onConfirm)
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

function Page:draft()
    if self.selKey == nil then return nil end
    return self.drafts[self.selKey]
end

function Page:dirty()
    local d = self:draft()
    return d ~= nil and #d.changed > 0
end

-- the server plan is no longer the revision the draft was started from
function Page:baseMoved()
    local d, e = self:draft(), self:selectedEntry()
    return d ~= nil and e ~= nil and (tonumber(e.plan.revision) or 0) ~= d.revision
end

function Page:writeInFlight()
    local s = self.sent
    return s ~= nil and (s.action == "apply" or s.action == "refund") and not s.answered and not s.timedOut
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
    for _, spec in ipairs(FIELDS) do
        local c = self.fieldControls[spec.key]
        if spec.kind == "int" and c:isFocused() then c._entry:unfocus() end
    end
    for _, f in ipairs({ self.accountField, self.reasonField }) do
        if f:isFocused() then f._entry:unfocus() end
    end
end

-- ---------- drafts ----------

function Page:evaluate(d)
    local changed, invalid = {}, {}
    for _, spec in ipairs(FIELDS) do
        local v = d.values[spec.key]
        if differs(spec, v, d.base[spec.key]) then changed[#changed + 1] = spec end
        if fieldError(spec, v) then invalid[#invalid + 1] = spec end
    end
    d.changed, d.invalid = changed, invalid
end

function Page:ensureDraft(entry)
    local key = keyOf(entry.sourceMod, entry.productId)
    local d = self.drafts[key]
    if d == nil then
        d = { key = key, sourceMod = entry.sourceMod, productId = entry.productId,
            base = copyPlan(entry.plan), revision = tonumber(entry.plan.revision) or 0, values = {}, version = 0 }
        d.unknown = self.pendingApplies[key] ~= nil
        for _, spec in ipairs(FIELDS) do d.values[spec.key] = draftValue(spec, entry.plan[spec.key]) end
        self.drafts[key] = d
        self:evaluate(d)
    end
    return d
end

-- Puts the draft (or the current plan) into the controls. A box the admin is typing into is left
-- alone unless `force`: its next keystroke is what the draft takes.
function Page:syncControls(force)
    if self.broken then return end
    local entry = self:selectedEntry()
    local d = self:draft()
    for _, spec in ipairs(FIELDS) do
        local v
        if d ~= nil then v = d.values[spec.key]
        elseif entry ~= nil then v = draftValue(spec, entry.plan[spec.key]) end
        local c = self.fieldControls[spec.key]
        if spec.kind == "int" then
            if force or not c:isFocused() then c:setText(v or "") end
        elseif spec.kind == "bool" then
            c:setChecked(v == true, true)
            c:setLabel(boolText(v == true))
        end
    end
end

-- The one way a plan field changes, for the mouse, the keyboard and a script alike.
function Page:setDraftValue(field, value, fromUI)
    local spec = FIELD_BY_KEY[field]
    local entry = self:selectedEntry()
    if spec == nil or entry == nil or self.view ~= "list" or self:writeInFlight()
        or not self.owner:writeAllowed() then
        return false
    end
    local d = self:ensureDraft(entry)
    if spec.kind == "bool" then value = value == true
    else value = value ~= nil and tostring(value) or "" end
    d.values[field] = value
    d.version = d.version + 1
    self:evaluate(d)
    if not fromUI then self:syncControls(true) end
    if spec.kind == "bool" then self.fieldControls[field]:setLabel(boolText(value)) end
    self:rebuildPlanRows()
    self:layout()
    return true
end

-- Why Review is not available right now, as a translation key (nil = it is).
function Page:reviewBlockKey()
    local d, entry = self:draft(), self:selectedEntry()
    if entry == nil then return "Ent_PickProduct" end
    if not self.owner:writeAllowed() then return "Ent_ReadOnly" end
    if self.isPending(COMMAND) then return "Admin_Error_busy" end
    if self.pendingApplies[self.selKey] ~= nil then return "Ent_Draft_Unknown" end
    if d == nil or #d.changed == 0 then return "Ent_Draft_None" end
    if #d.invalid > 0 then return "Ent_Draft_Invalid" end
    if d.conflict ~= nil or self:baseMoved() then return "Ent_Draft_MovedShort" end
    return nil
end

function Page:invalidNames(d)
    local names = {}
    for _, spec in ipairs(d.invalid) do
        local range = spec.kind == "int" and (" (" .. getText(T .. "Ent_Range", tostring(spec.min), amountText(spec.max)) .. ")") or ""
        names[#names + 1] = tr("Ent_Field_" .. spec.key) .. range
    end
    return table.concat(names, "; ")
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
    self.form.scrollOffset = 0
    self:syncControls(true)
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

-- ---------- plan actions ----------

function Page:onReview()
    if self.view ~= "list" then return end
    local key = self:reviewBlockKey()
    local d, entry = self:draft(), self:selectedEntry()
    if key ~= nil then
        local msg = key == "Ent_Draft_Invalid" and getText(T .. key, self:invalidNames(d)) or tr(key)
        self:say(msg, true)
        self:layout()
        return
    end
    self.review = { kind = "apply", key = d.key, sourceMod = d.sourceMod, productId = d.productId,
        expectedRevision = d.revision, values = payload(d), text = self:applySummary(d, entry) }
    self:openReview()
end

function Page:onDiscard()
    if self.view ~= "list" or self:writeInFlight() or self.selKey == nil then return end
    if self.drafts[self.selKey] == nil then return end
    self:unfocusAll()
    self.drafts[self.selKey] = nil
    self:syncControls(true)
    self:say(tr("Ent_Discarded"))
    self:rebuildPlanRows()
    self:layout()
end

-- Re-check is an explicit fresh read, not permission to reuse a cached revision after a timeout.
function Page:onRecheck()
    local d = self:draft()
    if d == nil or self.view ~= "list" or self:writeInFlight() then return end
    self.recheck = { key = self.selKey, draft = d }
    self.plansWanted = true
    self:tick(EC.now())
end

function Page:finishRecheck(recheck)
    if recheck == nil or self.drafts[recheck.key] ~= recheck.draft then return end
    local entry = self:entryFor(recheck.key)
    if entry == nil then return end
    local d = recheck.draft
    local pending = self.pendingApplies[recheck.key]
    if pending ~= nil then
        local applied = false
        for _, receipt in ipairs(type(entry.applies) == "table" and entry.applies or {}) do
            if receipt.requestId == pending.requestId then applied = true end
        end
        -- A moved revision without our receipt is not proof of either outcome.
        if not applied and (type(entry.applies) ~= "table"
            or tonumber(entry.plan.revision) ~= pending.review.expectedRevision) then
            d.conflict = "stale_revision"
            self:say(tr("Ent_Draft_Unknown"), true)
            return
        end
    end
    d.base = copyPlan(entry.plan)
    d.revision = tonumber(entry.plan.revision) or 0
    d.conflict, d.unknown = nil, nil
    self.pendingApplies[recheck.key] = nil
    self:evaluate(d)
    self:say(getText(T .. "Ent_Rechecked", tostring(d.revision)))
end

-- ---------- the confirm step ----------

function Page:openReview()
    self.view = "review"
    self.reviewError = nil
    self:unfocusAll()
    self.reasonField:setText("")
    local r = self.review
    local title = tr(r.kind == "apply" and "Ent_Confirm_Apply" or "Ent_Confirm_Refund")
    self.confirmButton.ecFull = title
    self.confirmButton:setTitle(title)
    self.confirmButton:setStyle(r.kind == "apply" and "primary" or "danger")
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
    if bad == nil and r.kind == "apply" then
        if self.pendingApplies[r.key] ~= nil then bad = tr("Ent_Draft_Unknown") end
        local e = self:entryFor(r.key)
        if e ~= nil and (tonumber(e.plan.revision) or 0) ~= r.expectedRevision then bad = tr("Ent_Draft_MovedShort") end
    end
    if bad ~= nil then
        self.reviewError = bad
        self:layout()
        return
    end
    local args
    if r.kind == "apply" then
        args = { action = "apply", sourceMod = r.sourceMod, productId = r.productId,
            expectedRevision = r.expectedRevision, values = copyPlan(r.values), reason = reason }
    else
        args = { action = "refund", username = r.username, sourceMod = r.sourceMod, productId = r.productId,
            orderId = r.orderId, reason = reason }
    end
    local d = r.kind == "apply" and self.drafts[r.key] or nil
    local ok, why = self:sendAction(args, { action = r.kind, key = r.key, username = r.username,
        orderId = r.orderId, draft = d, version = d and d.version, review = r })
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
    if req.action == "apply" then self.pendingApplies[req.key] = req end
    self:updateEnabled()
    return true
end

function Page:requestPlans()
    if self:sendAction({ action = "plans" }, { action = "plans", recheck = self.recheck }) then
        self.plansWanted, self.plansTimeout, self.recheck = false, false, nil
        return true
    end
    return false
end

-- The controller cancelled a cooldown-held write before sending it: this is known, not a timeout.
function Page:onCancelled(requestId)
    local req = self.sent
    if req == nil or req.requestId ~= requestId or req.answered then return end
    req.answered = true
    if req.action == "apply" and self.pendingApplies[req.key] == req then self.pendingApplies[req.key] = nil end
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
            if args.ok == true and type(args.plans) == "table" then self:finishRecheck(req.recheck) end
        end
    elseif req.action == "apply" then
        self:onApplyReply(args, req)
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

function Page:onApplyReply(args, req)
    if type(args.plans) ~= "table" then self.plansWanted = true end
    local d = self.drafts[req.key]
    if self.pendingApplies[req.key] == req then self.pendingApplies[req.key] = nil end
    if d ~= nil and d == req.draft then d.unknown = nil end
    if args.ok == true then
        if d ~= nil and d == req.draft and d.version == req.version then self.drafts[req.key] = nil end
        if self.review == req.review then self:closeReview() end
        if req.key == self.selKey then self:syncControls(false) end
        local e = self:entryFor(req.key)
        local msg = args.updated == false and tr("Ent_AppliedNoChange")
            or getText(T .. "Ent_Applied", tostring(e and e.plan.revision or "?"))
        local sandbox = type(args.sandbox) == "table" and args.sandbox or nil
        local sandboxFailed = sandbox ~= nil and sandbox.ok == false
        if sandboxFailed then
            msg = msg .. " " .. getText(T .. "Ent_SandboxWriteFailed", self:errorText(sandbox.error))
        end
        self:say(msg, sandboxFailed)
        self:invalidateKeyboard()
    elseif CONFLICT[args.error] then
        if d ~= nil and d == req.draft then d.conflict = args.error end
        if self.review == req.review then self:closeReview() end
        self:say(getText(T .. "Ent_Draft_Conflict", self:errorText(args.error)), true)
        self:invalidateKeyboard()
    else
        local msg = self:errorText(args.error)
        if type(args.field) == "string" and FIELD_BY_KEY[args.field] ~= nil then
            msg = msg .. " (" .. tr("Ent_Field_" .. args.field) .. ")"
        end
        if self.review == req.review then self.reviewError = msg end
        self:say(msg, true)
    end
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

-- A request whose answer never came. A read is owed again on the next refresh; a write has an
-- unknown outcome and is never re-sent: the draft (or the refund) stays for the admin to check.
function Page:onTimeout()
    local req = self.sent
    if req == nil or req.answered then return end
    req.timedOut = true
    if req.action == "plans" then
        self.plansTimeout = true
        self:say(tr("Ent_PlansTimeout"), true)
    elseif req.action == "apply" then
        local d = self.drafts[req.key]
        if d ~= nil then d.unknown = true end
        if self.review == req.review then self:closeReview() end
        self:say(tr("Ent_ApplyTimeout"), true)
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
        self.form.scrollOffset = 0
    end
    self:syncControls(false)
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

function Page:stamp(ms)
    if type(ms) ~= "number" then return "-" end
    return U.stampText(ms, self.owner.offsetMin)
end

function Page:detailLine(out, key, value)
    out[#out + 1] = getText(T .. "Ent_D_Line", tr("Ent_D_" .. key), tostring(value))
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
    self:detailLine(out, "PaidUntil", self:stamp(ent.paidUntil))
    self:detailLine(out, "GraceUntil", self:stamp(ent.graceUntil))
    self:detailLine(out, "AutoRenew", E.autoRenewText(ent.autoRenewState or (ent.autoRenew == true and "on" or "off")))
    self:detailLine(out, "Terms", num(ent.termsRevision))
    self:detailLine(out, "LastOrder", tostring(ent.lastOrderId or "-"))
    local dur = type(ent.durable) == "table" and ent.durable or {}
    local seqText = dur.seq ~= nil and ("  (" .. tostring(dur.source or "-") .. " #" .. tostring(dur.seq) .. ")") or ""
    self:detailLine(out, "Durable", E.durableText(dur.status) .. seqText)
    local wait = E.waitText(ent.wait)
    if wait then self:detailLine(out, "Durable", wait) end
    if ent.notice ~= nil then self:detailLine(out, "Notice", E.noticeText(ent.notice)) end
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
    durable = true, paid = true, final = true }
for _, f in ipairs(ORDER_FIELDS) do ORDER_KNOWN[f.key] = true end

function Page:orderLines(out, o)
    local E = Ent()
    self:detailLine(out, "Order", orderIdOf(o) or "-")
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

function Page:applySummary(d, entry)
    local out = {}
    out[#out + 1] = getText(T .. "Ent_Review_Product", Ent().productName(entry), d.sourceMod, d.productId)
    out[#out + 1] = getText(T .. "Ent_Review_Base", tostring(d.revision))
    out[#out + 1] = ""
    out[#out + 1] = tr("Ent_Review_Changes")
    for _, spec in ipairs(d.changed) do
        out[#out + 1] = "  " .. getText(T .. "Ent_Review_Change", tr("Ent_Field_" .. spec.key),
            valueText(spec, d.base[spec.key]), valueText(spec, d.values[spec.key]))
    end
    out[#out + 1] = tr("Ent_Review_Whole")
    out[#out + 1] = ""
    out[#out + 1] = tr("Ent_Review_Effects")
    for _, key in ipairs({ "Ent_Review_EffectRevision", "Ent_Review_EffectLeases", "Ent_Review_EffectLimit",
        "Ent_Review_EffectSandbox" }) do
        out[#out + 1] = "- " .. tr(key)
    end
    if entry.loaded == false then out[#out + 1] = "- " .. tr("Ent_NotLoaded") end
    return table.concat(out, "\n")
end

function Page:refundSummary(username, e, o)
    local out = {}
    out[#out + 1] = getText(T .. "Ent_Review_Account", username)
    out[#out + 1] = getText(T .. "Ent_Review_Product", Ent().productName(e), e.sourceMod, e.productId)
    out[#out + 1] = ""
    self:orderLines(out, o)
    out[#out + 1] = ""
    out[#out + 1] = "- " .. tr("Ent_Review_RefundEffect")
    out[#out + 1] = "- " .. tr("Ent_Review_NoUndo")
    return table.concat(out, "\n")
end

-- ---------- rows (data changes only) ----------

function Page:rebuildPlanRows()
    if self.broken then return end
    local items, sel = {}, nil
    for i, e in ipairs(self.plans or {}) do
        local key = keyOf(e.sourceMod, e.productId)
        local d = self.drafts[key]
        local flag, flagToken = nil, "accent"
        if d ~= nil and (d.conflict ~= nil or d.unknown or (tonumber(e.plan.revision) or 0) ~= d.revision) then
            flag, flagToken = tr("Ent_Mark_Moved"), "warn"
        elseif d ~= nil and #d.changed > 0 then
            flag = tr("Ent_Mark_Draft")
        end
        items[i] = { sourceMod = e.sourceMod, productId = e.productId, line1 = Ent().productName(e),
            right1 = flag, rightToken1 = flagToken,
            line2 = e.sourceMod .. " / " .. e.productId,
            right2 = getText(T .. "Ent_SaleShort", boolText(e.plan.permanentEnabled == true), boolText(e.plan.rentalEnabled == true)),
            token2 = e.loaded == false and "warn" or nil }
        if key == self.selKey then sel = i end
    end
    self.planList:setItems(items)
    self.planList:setSelectedIndex(sel)
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
            right2 = type(ent.paidUntil) == "number" and self:stamp(ent.paidUntil) or nil }
    end
    self.entryList:setItems(items)
    self.entryList:setSelectedIndex(self.entrySel)
    local orders = {}
    for i, o in ipairs(self:selectedOrders()) do
        if type(o) == "table" then
            orders[i] = { line1 = orderIdOf(o) or "?",
                right1 = o.amount ~= nil and (amountText(o.amount) .. " " .. (o.currency and U.currencyName(o.currency) or "")) or nil,
                rightToken1 = "text",
                line2 = E.kindText(o.kind) .. "  " .. E.orderStatusText(o.status),
                right2 = self:stamp(tonumber(o.at or o.createdAt)),
                token2 = refundable(o) and nil or "textFaint" }
        else
            orders[i] = { line1 = "?" }
        end
    end
    self.orderList:setItems(orders)
    self.orderList:setSelectedIndex(self.orderSel)
    local e, o = self:selectedAccountEntry(), self:selectedOrder()
    local out = {}
    if e ~= nil then self:entryLines(out, e) end
    if o ~= nil then
        out[#out + 1] = ""
        self:orderLines(out, o)
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
    show(self.form, plans and self:selectedEntry() ~= nil)
    for _, b in ipairs(self.planButtons) do b.ecShow = false; show(b, false) end
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
    if not plans then self:placeForm() end
    self:updateEnabled()
end

function Page:noticeLines(lines, entry, d, width)
    if d ~= nil and d.conflict ~= nil then
        wrapInto(lines, getText(T .. "Ent_Draft_Conflict", self:errorText(d.conflict)), width, "errorText", 4)
    elseif self:baseMoved() then
        wrapInto(lines, getText(T .. "Ent_Draft_Moved", num(entry.plan.revision), tostring(d.revision)), width, "warn", 4)
    end
    if d ~= nil and d.unknown then wrapInto(lines, tr("Ent_Draft_Unknown"), width, "warn", 3) end
    if d ~= nil and #d.invalid > 0 then
        wrapInto(lines, getText(T .. "Ent_Draft_Invalid", self:invalidNames(d)), width, "errorText", 3)
    end
    if d ~= nil and #d.changed > 0 then
        wrapInto(lines, getText(T .. "Ent_Draft_Dirty", tostring(d.revision), tostring(#d.changed)), width, "accent", 3)
    elseif self.owner:writeAllowed() then
        wrapInto(lines, tr("Ent_Draft_None"), width, "textMuted", 2)
    end
    if not self.owner:writeAllowed() then wrapInto(lines, tr("Ent_ReadOnly"), width, "warn", 2) end
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
    self:layoutEditor(g, ex, ey, ew, eh)
end

function Page:layoutEditor(g, ex, ey, ew, eh)
    local lh, ch = lineH(), ctrlH()
    local x, iw = ex + PAD, math.max(80, ew - PAD * 2)
    local entry = self:selectedEntry()
    g.edX = x
    g.edLines = {}
    if entry == nil then
        g.edTitle = nil
        g.edLinesY = ey + PAD
        if self.plans ~= nil and #self.plans > 0 then wrapInto(g.edLines, tr("Ent_PickProduct"), iw, "textMuted", 3) end
        self:placeForm()
        return
    end
    local d = self:draft()
    local y = ey + PAD
    g.edTitle = fitText(Ent().productName(entry), iw, UIFont.Medium)
    g.edTitleY = y
    y = y + fontH.medium + 4
    local lines = {}
    self:noticeLines(lines, entry, d, iw)
    wrapInto(lines, getText(T .. "Ent_Ids", entry.sourceMod, entry.productId, num(entry.plan.revision)), iw, "textMuted", 2)
    if entry.loaded == false then wrapInto(lines, tr("Ent_NotLoaded"), iw, "warn", 3) end
    wrapInto(lines, getText(T .. "Ent_SyncLine", sandboxText(entry.sandboxStatus)), iw, sandboxToken(entry.sandboxStatus), 2)
    local change = entry.lastChange
    if type(change) == "table" then
        local origin = getTextOrNull(T .. "Ent_Origin_" .. tostring(change.origin)) or tostring(change.origin or "-")
        wrapInto(lines, getText(T .. "Ent_LastChange", origin, tostring(change.actor or "-"),
            self:stamp(tonumber(change.at))), iw, "textMuted", 2)
        if type(change.reason) == "string" and change.reason ~= "" then
            wrapInto(lines, getText(T .. "Ent_LastReason", change.reason), iw, "textMuted", 2)
        end
    end

    local write = self.owner:writeAllowed()
    self.reviewButton.ecShow = write
    self.discardButton.ecShow = write and d ~= nil
    self.recheckButton.ecShow = write and d ~= nil and (d.conflict ~= nil or d.unknown == true or self:baseMoved())
    local barH = self:flowButtons(self.planButtons, x, iw, nil)
    local barY = ey + eh - PAD - barH
    self:flowButtons(self.planButtons, x, iw, barY)
    -- the prose gives way before the form does: one whole field row always stays
    local maxLines = math.max(1, math.floor((barY - 6 - (ch + lh + 4) - y) / lh))
    while #lines > maxLines do table.remove(lines) end
    g.edLines, g.edLinesY = lines, y
    y = y + #lines * lh + 4
    self.form:setX(x)
    self.form:setY(y)
    self.form:setWidth(iw)
    self.form:setHeight(math.max(ch, barY - 6 - y))
    self:placeForm()
end

function Page:currencyIds(entry, a, b)
    local ids, seen = {}, {}
    local list = type(entry.currencies) == "table" and entry.currencies or EC.CURRENCY_ORDER
    for _, id in ipairs(list) do
        if type(id) == "string" and not seen[id] then ids[#ids + 1] = id; seen[id] = true end
    end
    for _, id in ipairs({ a, b }) do
        if type(id) == "string" and id ~= "" and not seen[id] then ids[#ids + 1] = id; seen[id] = true end
    end
    return ids
end

function Page:chipFor(field, id)
    local set = self.chips[field]
    if set == nil then
        set = {}
        self.chips[field] = set
    end
    local b = set[id]
    if b == nil then
        local title = U.currencyName(id)
        b = controls().Button.new({ x = 0, y = PARK_Y, width = textWidth(title) + 20, height = ctrlH(), title = title,
            theme = U.theme, target = self, onClick = function(page, button) page:setDraftValue(button.ecField, button.internal) end })
        b.internal, b.ecField, b.ecFull = id, field, title
        self.form:addChild(b)
        set[id] = b
        self.formControls[#self.formControls + 1] = b
    end
    return b
end

-- The controls one row shows, sized for `width`, with the row's height.
function Page:rowControls(spec, entry, value, width)
    local ch = ctrlH()
    if spec.kind == "int" then
        local c = self.fieldControls[spec.key]
        setFieldWidth(c, math.min(width, math.max(140, textWidth("1,000,000,000") + 40)))
        return { c }, ch
    end
    if spec.kind == "bool" then
        local c = self.fieldControls[spec.key]
        c:setWidth(math.min(width, 36 + 8 + textWidth(c.label or "") + 4))
        return { c }, ch
    end
    local ids = self:currencyIds(entry, entry.plan[spec.key], value)
    self.chipOrder[spec.key] = ids
    local out = {}
    for _, id in ipairs(ids) do
        local b = self:chipFor(spec.key, id)
        local title = U.currencyName(id)
        b.ecFull = title
        local natural = textWidth(title) + 20
        local bw = math.min(natural, width)
        b:setWidth(bw)
        b:setTitle(bw < natural and fitText(title, bw - 20) or title)
        b:setStyle(id == value and "primary" or "normal")
        out[#out + 1] = b
    end
    -- the height the chips take once they flow into the width
    local cx, rows = 0, 1
    for _, b in ipairs(out) do
        if cx > 0 and cx + b.width > width then cx, rows = 0, rows + 1 end
        cx = cx + b.width + 6
    end
    return out, rows * ch + (rows - 1) * 4
end

local function paintText(paint, s, x, y, token, font, scroll, viewH, textH)
    local ay = y - scroll
    if ay >= 0 and ay + textH <= viewH then
        paint[#paint + 1] = { s = s, x = x, y = ay, token = token, font = font }
    end
end

-- One row: its label, the current value and its controls, at content y. Returns the row height.
function Page:placeRow(ctx, spec, y)
    local entry, d, paint = ctx.entry, ctx.draft, ctx.paint
    local scroll, viewH, fh, lh = ctx.scroll, ctx.viewH, fontH.small, lineH()
    local live = entry.plan[spec.key]
    -- `false` is a real value here (a disabled sale), so no and/or shortcut
    local value, base = draftValue(spec, live), live
    if d ~= nil then value, base = d.values[spec.key], d.base[spec.key] end
    local labelToken = (d ~= nil and fieldError(spec, value) and "errorText")
        or (d ~= nil and differs(spec, value, base) and "accent") or "text"
    local moved = d ~= nil and differs(spec, draftValue(spec, live), base)
    local label = tr("Ent_Field_" .. spec.key)
    local current = valueText(spec, live)
    local ctrlX, ctrlW, ctrlY
    if ctx.wide then
        ctrlX, ctrlW, ctrlY = ctx.ctrlX, ctx.ctrlW, y
    else
        ctrlX, ctrlW, ctrlY = 0, ctx.w, y + lh
    end
    local list, rowH = self:rowControls(spec, entry, value, ctrlW)
    local textY = ctx.wide and (y + math.floor((ctrlH() - fh) / 2)) or y
    if ctx.wide then
        paintText(paint, fitText(label, ctx.labelW), 0, textY, labelToken, nil, scroll, viewH, fh)
        paintText(paint, fitText(current, ctx.curW), ctx.curX, textY, moved and "warn" or "textMuted", nil, scroll, viewH, fh)
    else
        local cur = fitText(getText(T .. "Ent_CurrentValue", current), math.floor(ctx.w * 0.45))
        local cw = textWidth(cur)
        paintText(paint, fitText(label, math.max(0, ctx.w - cw - PAD)), 0, textY, labelToken, nil, scroll, viewH, fh)
        paintText(paint, cur, ctx.w - cw, textY, moved and "warn" or "textMuted", nil, scroll, viewH, fh)
    end
    local cx, cy = ctrlX, ctrlY
    for _, c in ipairs(list) do
        if cx > ctrlX and cx + c.width > ctrlX + ctrlW then cx, cy = ctrlX, cy + ctrlH() + 4 end
        c.ecFormY, c.ecFormH, c.ecFormLabelY = cy, ctrlH(), y
        ctx.placed[c] = true
        show(c, true)
        local ay = cy - scroll
        if ay >= 0 and ay + c.height <= viewH then
            c:setX(cx)
            c:setY(ay)
        else
            ctx.parked[#ctx.parked + 1] = c
        end
        cx = cx + c.width + 6
    end
    return (ctx.wide and 0 or lh) + rowH
end

-- Positions every field for the selected product at the current scroll offset. Runs on data,
-- geometry and scroll changes, never per frame.
function Page:placeForm()
    if self.broken then return end
    local form = self.form
    local paint = {}
    form.paint = paint
    local entry = self:selectedEntry()
    local ctx = { placed = {}, parked = {}, paint = paint }
    if entry ~= nil and self.view == "list" and self.section == "plans" and form:getIsVisible() then
        local w = math.max(80, form.width - SCROLL_W)
        local lh, fh = lineH(), fontH.small
        ctx.entry, ctx.draft, ctx.w = entry, self:draft(), w
        ctx.scroll, ctx.viewH = form.scrollOffset or 0, form.height
        local labelW = 0
        for _, spec in ipairs(FIELDS) do labelW = math.max(labelW, textWidth(tr("Ent_Field_" .. spec.key))) end
        ctx.labelW = math.min(labelW, math.floor(w * 0.4))
        ctx.curX = ctx.labelW + 8
        ctx.curW = math.min(200, math.floor(w * 0.25))
        ctx.ctrlX = ctx.curX + ctx.curW + 8
        ctx.ctrlW = w - ctx.ctrlX
        ctx.wide = ctx.ctrlW >= 180
        local y = 0
        if ctx.wide then
            paintText(paint, fitText(tr("Ent_Col_Field"), ctx.labelW), 0, y, "textFaint", nil, ctx.scroll, ctx.viewH, fh)
            paintText(paint, fitText(getText(T .. "Ent_Col_Current", num(entry.plan.revision)), ctx.curW), ctx.curX, y,
                "textFaint", nil, ctx.scroll, ctx.viewH, fh)
            paintText(paint, fitText(tr("Ent_Col_Draft"), ctx.ctrlW), ctx.ctrlX, y, "textFaint", nil, ctx.scroll, ctx.viewH, fh)
            y = y + lh + 2
        end
        for _, group in ipairs(GROUPS) do
            paintText(paint, fitText(tr("Ent_Group_" .. group), w), 0, y, "accent", nil, ctx.scroll, ctx.viewH, fh)
            y = y + lh + 2
            for _, spec in ipairs(FIELDS) do
                if spec.group == group then y = y + self:placeRow(ctx, spec, y) + ROW_GAP end
            end
            y = y + 4
        end
        form.contentH = y
        if (form.scrollOffset or 0) > form:maxScrollOffset() then
            form.scrollOffset = form:maxScrollOffset()
            return self:placeForm()
        end
    else
        form.contentH = 0
    end
    -- everything this product does not show, and every row outside the viewport: off screen, but
    -- still visible for the keyboard (a currency chip of another product is simply hidden)
    for _, c in ipairs(self.formControls) do
        if not ctx.placed[c] then
            if c.ecField ~= nil then show(c, false) end
            ctx.parked[#ctx.parked + 1] = c
        end
    end
    for _, c in ipairs(ctx.parked) do
        if c._entry ~= nil and c:isFocused() then c._entry:unfocus() end
        c:setX(0)
        c:setY(PARK_Y)
    end
end

function Page:layoutReview(g, w, h)
    local lh, ch = lineH(), ctrlH()
    local r = self.review
    g.rvTitle = fitText(tr(r.kind == "apply" and "Ent_Review_TitleApply" or "Ent_Review_TitleRefund"), w, UIFont.Medium)
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
    local d = self:draft()
    local edit = write and not modal and listView and not inFlight and self:selectedEntry() ~= nil
    self.editable = edit
    for _, spec in ipairs(FIELDS) do
        if spec.kind ~= "currency" then
            local c = self.fieldControls[spec.key]
            c:setEnabled(edit)
            if spec.kind == "bool" then c.enable = edit end
        end
    end
    -- Currency fields are chip groups, not entries in fieldControls.
    for _, set in pairs(self.chips) do
        for _, b in pairs(set) do b:setEnabled(edit) end
    end
    self.reviewButton:setEnabled(edit and self:reviewBlockKey() == nil)
    self.discardButton:setEnabled(edit and d ~= nil)
    self.recheckButton:setEnabled(edit and d ~= nil)
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
    if self.editable then
        for _, spec in ipairs(FIELDS) do
            local label = tr("Ent_Field_" .. spec.key)
            local c = self.fieldControls[spec.key]
            if spec.kind == "int" then
                out[#out + 1] = { kind = "entry", control = c._entry, label = label, scrollOwner = c }
            elseif spec.kind == "bool" then
                out[#out + 1] = { kind = "button", control = c, label = label, scrollOwner = self.form }
            else
                for _, id in ipairs(self.chipOrder[spec.key] or {}) do
                    local b = self.chips[spec.key] and self.chips[spec.key][id]
                    if b ~= nil then
                        out[#out + 1] = { kind = "button", control = b, label = label .. ": " .. b.ecFull, scrollOwner = self.form }
                    end
                end
            end
        end
    end
    if self.form:getIsVisible() and self.form:maxScrollOffset() > 0 then
        out[#out + 1] = { kind = "scroll", control = self.form, label = tr("Ent_Kb_Form") }
    end
    out[#out + 1] = { kind = "group", controls = self.planButtons, label = tr("Ent_Kb_Actions") }
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

-- Hiding keeps every snapshot and draft; it only takes the keyboard out of the text boxes.
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

-- The permission collapse: everything this page learned or was drafting goes, and nothing is
-- asked for again until the controller says reading is allowed.
function Page:clear()
    if self.broken then return end
    self:unfocusAll()
    self.plans, self.plansError, self.plansTimeout, self.updatedAt = nil, nil, false, nil
    self.drafts = {}
    self.pendingApplies, self.recheck = {}, nil
    self.sent, self.review, self.reviewError, self.view = nil, nil, nil, "list"
    self.account, self.accountUser, self.accountError, self.accountTimeout = nil, nil, nil, false
    self.entrySel, self.entryKey, self.orderSel, self.orderKey = nil, nil, nil, nil
    self.plansWanted, self.accountWanted = false, false
    self.selKey, self.pendingSelect, self.message = nil, nil, nil
    self.detailText = nil
    self.accountField:setText("")
    self.reasonField:setText("")
    self.form:stopDrag()
    self.form.scrollOffset = 0
    self.planList:setItems({})
    self.entryList:setItems({})
    self.orderList:setItems({})
    self:syncControls(true)
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
    o.drafts = {}
    o.pendingApplies = {}
    o.plansWanted = true
    o:initialise()
    o:instantiate()
    o:setVisible(false)
    return o
end

return P
