-- MinidoracatEconomyFor42 -- admin integration plan page (client). Adds exactly one namespace:
-- C.AdminEntitlements.
--
--   C.AdminEntitlements.create(owner, send, isPending, newRequestId)
--       an initialised ISPanel child, NOT added (the admin controller addChild's it). The three
--       transport functions are the controller's own and are always called as self.send(...),
--       self.isPending(...), self.newRequestId() -- never with ":". The page owns no Events hook
--       and no timer: the controller calls tick(now) while this tab is on screen.
--   C.AdminEntitlements.sourceName(src)
--       a source's display name: its registered translation key, else its { CH, EN } display
--       name, else its mod id. The sources page uses the same one.
--
-- One command, admin.entitlements, four actions, one slot (the controller's): at most one of
-- them is open at a time and a reply is matched against exactly that request.
--   plans     every registered source product:
--             { sourceMod, productId, nameKey, loaded, instant, plan, lastChange, source,
--               sourceNameKey?, sourceName? }
--   orders    { before? } -> one page of every account's orders, newest first, { orders, more }
--   account   { username } -> every entitlement snapshot of that exact account
--   refund    { username, sourceMod, productId, orderId, reason }
--
-- Two sections, switched by the page's own tabs:
--   plans     the product list on the left; on the right the picked product's terms as two cards
--             (buying slots outright, renting them), a warning box when the source reported a
--             settings file problem / the plan is provisional / the source is not loaded, and a
--             footer with the last change and the settings file. The terms belong to the source
--             mod (its settings file or its own in-game settings); this page never writes them.
--   accounts  without an account filter: every order of every account, newest first, a page at
--             a time ("show earlier" asks for the next one). A row's own button refunds it; the
--             row itself (click or Enter) filters the page to that player. With a filter: that
--             account's slots, each rental on a line with the real reason its auto-renew is
--             paused, and the orders of the picked product.
-- A refund goes through the framework dialog with a required reason and is sent once; a timeout
-- is reported as an unknown outcome and never re-sent. Instant products never show a save state.
--
-- Every word on screen is a translation key; numbers, times, account names, the settings file
-- path and the file's own keys (which the source passes as data) are shown as they are.

require "ISUI/ISPanel"
if not MinidoracatEconomy or not MinidoracatEconomy.Client or not MinidoracatEconomy.Client.UI then
    require "MinidoracatEconomy/ECWidgets"
end
require "MinidoracatEconomy/ECRowActions"
require "MinidoracatEconomy/ECDetailWindow"

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
local DAY_MS, HOUR_MS = 86400000, 3600000
local CARD_MIN_W = 240
local DIALOG_W = 480

local function tr(key) return getText(T .. key) end
local function lineH() return fontH.small + 6 end
local function ctrlH() return math.max(26, fontH.small + 12) end
local function rowH2() return lineH() * 2 + 12 end
local function titleH() return math.max(CARD_TITLE_H, fontH.medium + 10) end
local function trim(s) return string.match(tostring(s or ""), "^%s*(.-)%s*$") end
local function keyOf(sourceMod, productId) return tostring(sourceMod) .. "\1" .. tostring(productId) end
local function Ent() return C.Entitlements end
local function pair(a, b) return getText(T .. "Ent_Pair", a, b) end

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
    if ui ~= nil and ui.Dialog == nil then pcall(require, "MinidoracatUI/Widgets/Window") end
    if ui ~= nil and (ui.API_REVISION or 0) >= 7 and ui.CAPABILITIES and ui.CAPABILITIES.controls == true
        and ui.Button and ui.TextField and ui.Tabs and ui.Checkbox and ui.Dialog then
        return ui
    end
    return nil
end

-- ---------- words (pure: shared with the tests) ----------

local function num(v)
    local n = tonumber(v)
    return n ~= nil and tostring(n) or "-"
end

local function boolText(v) return tr(v == true and "Ent_On" or "Ent_Off") end

local function moneyText(amount, currency)
    local n = tonumber(amount)
    local s = n ~= nil and amountText(n) or "-"
    if type(currency) == "string" and currency ~= "" then s = s .. " " .. U.currencyName(currency) end
    return s
end
P.moneyText = moneyText

local function orderIdOf(o)
    if type(o) ~= "table" then return nil end
    local id = o.orderId or o.id
    return id ~= nil and tostring(id) or nil
end

-- The language option cannot change without a restart, so it is read once; getOptionLanguageName
-- is absent on old builds.
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

function P.sourceName(src)
    if type(src) ~= "table" then return "-" end
    local key = src.sourceNameKey
    local named = type(key) == "string" and key ~= "" and getTextOrNull(key) or nil
    if named ~= nil then return named end
    local names = src.sourceName or src.displayName
    if type(names) == "table" then
        local lang = gameLanguage()
        local pick = (lang == "CH" or lang == "CN") and names.CH or names.EN
        if type(pick) ~= "string" or pick == "" then pick = names.EN or names.CH end
        if type(pick) == "string" and pick ~= "" then return pick end
    end
    return tostring(src.modId or src.sourceMod or "-")
end

-- What an order bought: "buy outright", a new rental, a renewal or a scheduler renewal, and how
-- many slots. A rental the account no longer holds is named as removed.
function P.contentText(o)
    local q = num(o.quantity)
    if o.kind == "permanent" then return getText(T .. "Ent_Content_Permanent", q) end
    local which = (o.auto == true and "Auto") or ((o.renewal == true or o.kind == "renewal") and "Renewal") or "New"
    local n = tonumber(o.rentalNo)
    if n == nil then return getText(T .. "Ent_Content_" .. which .. "Gone", q) end
    return getText(T .. "Ent_Content_" .. which, tostring(n), q)
end

-- Paid / refunded; a product that waits for the world save says so while it waits -- for a refund
-- that is the refund's own save, not the payment's. An instant product takes effect in the paying
-- commit and never shows a save state.
function P.statusText(o, instant)
    local s = Ent().orderStatusText(o.status)
    if instant ~= true then
        local d = o.durable
        if o.status == "refunded" then d = type(o.refund) == "table" and o.refund.durable or nil end
        local saved = type(d) == "table" and d.status or nil
        if saved ~= nil and saved ~= "confirmed" then s = getText(T .. "Ent_StatusUnsaved", s) end
    end
    return s
end

-- One label for a rental's auto-renew, naming the one reason it is paused: the agreed terms no
-- longer match the plan's rent / currency / period, the account rents more than the limit, the
-- plan stopped renting, the plan does not allow auto-renew, or the server holds it.
function P.autoTag(r, plan, ent)
    local state = r.autoRenewState or (r.autoRenew == true and "on" or "off")
    if state == "on" or state == "pending_on" then return tr("Ent_AutoTag_on"), "textMuted" end
    if state == "off" or state == "pending_off" then return tr("Ent_AutoTag_off"), "textMuted" end
    if state == "paused_system" then return tr("Ent_AutoTag_system"), "warn" end
    local reason = "paused"
    if type(plan) == "table" then
        local a = r.autoTerms
        if type(a) == "table" and (tonumber(a.price) ~= tonumber(plan.rentalPrice)
            or a.currency ~= plan.rentalCurrency or tonumber(a.days) ~= tonumber(plan.rentalDays)) then
            reason = "terms"
        elseif type(ent) == "table" and (tonumber(ent.rentalCommitted) or 0) > (tonumber(plan.rentalLimit) or 0) then
            reason = "limit"
        elseif plan.rentalEnabled ~= true then
            reason = "stopped"
        elseif plan.autoRenewAllowed ~= true then
            reason = "disallowed"
        end
    end
    return tr("Ent_AutoTag_" .. reason), "warn"
end

-- Whole days while a day or more is left, hours below that.
function P.remainingText(ms)
    ms = math.max(0, tonumber(ms) or 0)
    if ms >= DAY_MS then return getText(T .. "Ent_Days", tostring(math.floor(ms / DAY_MS))) end
    return getText(T .. "Ent_Hours", tostring(math.max(1, math.ceil(ms / HOUR_MS))))
end

-- "#n, k slots, <state>": active with its end and what is left, in grace with the grace end,
-- expired, frozen (its product's mod is missing: what was left when it froze), or (a product that
-- waits for the save) a new rental not confirmed yet.
function P.rentalLine(i, r, now, offsetMin)
    local n, q = tostring(i), num(r.quantity)
    local state, paid = r.state, tonumber(r.paidUntil)
    if state == "grace" then
        return getText(T .. "Ent_RentalLine_grace", n, q, U.stampText(tonumber(r.graceUntil), offsetMin))
    end
    if state == "expired" then return getText(T .. "Ent_RentalLine_expired", n, q) end
    if state == "pending" or paid == nil then return getText(T .. "Ent_RentalLine_pending", n, q) end
    if state == "frozen" then
        -- the server shows a frozen rental's times as if it came back now: what is left stays put
        if paid > now then return getText(T .. "Ent_RentalLine_frozen", n, q, P.remainingText(paid - now)) end
        return getText(T .. "Ent_RentalLine_frozenGrace", n, q, P.remainingText((tonumber(r.graceUntil) or now) - now))
    end
    return getText(T .. "Ent_RentalLine_active", n, q, U.stampText(paid, offsetMin), P.remainingText(paid - now))
end

-- Every rental of one account entry, one full line each with its auto-renew label: what the
-- shared detail window shows when the page has no room for all of them.
function P.rentalsText(entry, now, offsetMin)
    local ent = type(entry) == "table" and type(entry.entitlement) == "table" and entry.entitlement or {}
    local lines = {}
    for i, r in ipairs(type(ent.rentals) == "table" and ent.rentals or {}) do
        if type(r) == "table" then
            lines[#lines + 1] = getText(T .. "Ent_Pair", P.rentalLine(i, r, now, offsetMin), (P.autoTag(r, entry.plan, ent)))
        end
    end
    return table.concat(lines, "\n")
end

-- The same rentals as a detail card: the product and account in the header, one line per rental
-- with its auto-renew label as the note, and the source mod / product id as technical facts.
function P.rentalsCard(entry, username, now, offsetMin)
    local ent = type(entry) == "table" and type(entry.entitlement) == "table" and entry.entitlement or {}
    local lines = {}
    for i, r in ipairs(type(ent.rentals) == "table" and ent.rentals or {}) do
        if type(r) == "table" then
            lines[#lines + 1] = { text = P.rentalLine(i, r, now, offsetMin), note = (P.autoTag(r, entry.plan, ent)) }
        end
    end
    return {
        sourceIcon = "sliders", iconKey = "sliders",
        name = Ent().productName(entry), sub = tostring(username),
        sections = { { title = tr("Ent_RentalsHead"), lines = lines } },
        tech = { { label = tr("Ent_Origin_source"), value = tostring(entry.sourceMod) },
            { label = tr("PCard_Ent_ProductId"), value = tostring(entry.productId) } },
        techOpen = true,
    }
end

-- The settings file problem a source reported ({ key, field?, ref? }): its own sentence when this
-- client has the source's translations, else Economy's general one with the file key.
function P.problemText(problem)
    if type(problem) ~= "table" then return nil end
    local ref = type(problem.ref) == "string" and problem.ref ~= "" and problem.ref or nil
    local label = (type(problem.field) == "string" and getTextOrNull(problem.field)) or ref or ""
    local detail = type(problem.key) == "string" and getTextOrNull(problem.key, label, ref or "") or nil
    if detail == nil then
        detail = ref ~= nil and getText(T .. "Ent_FileProblemGeneric", ref) or tr("Ent_FileProblemPlain")
    end
    return getText(T .. "Ent_FileProblem", detail)
end

-- What the refund dialog says above its reason box. `content` is the row's own content text.
function P.refundLines(o, username, content, offsetMin)
    local lines = {}
    lines[#lines + 1] = getText(T .. "Ent_RefundLine", moneyText(o.amount, o.currency), tostring(username))
    lines[#lines + 1] = pair(content, U.stampText(tonumber(o.at), offsetMin))
    local effect, n = o.refundEffect, o.rentalNo ~= nil and tostring(o.rentalNo) or "-"
    if effect == "units" then
        lines[#lines + 1] = getText(T .. "Ent_Effect_units", num(o.quantity))
    elseif effect == "cancel" then
        lines[#lines + 1] = tr("Ent_Effect_cancel")
    elseif effect == "previous" then
        lines[#lines + 1] = getText(T .. "Ent_Effect_previous", n, U.stampText(tonumber(o.previousUntil), offsetMin))
    elseif effect == "remove" then
        lines[#lines + 1] = getText(T .. "Ent_Effect_remove", n)
    elseif effect == "money" then
        lines[#lines + 1] = tr("Ent_Effect_money")
    end
    if o.kind ~= "permanent" and effect ~= "money" then lines[#lines + 1] = tr("Ent_EffectAutoOff") end
    lines[#lines + 1] = tr("Ent_NoUndo")
    return lines
end

local function reasonError(reason)
    if reason == "" then return tr("Ent_ReasonMissing") end
    if string.find(reason, "%c") then return tr("Admin_Error_reason_invalid") end
    if charCount(reason) > REASON_MAX then return tr("Admin_Error_reason_too_long") end
    return nil
end

local function wrapInto(lines, s, width, token, maxLines)
    for _, part in ipairs(U.wrapText(s, width, maxLines)) do
        lines[#lines + 1] = { s = part, token = token }
    end
end

-- ---------- cells ----------

-- Product list: two lines per row. Texts are fitted once per width and entry, never per frame.
local LineCell = ISPanel:derive("MinidoracatEconomyAdminEntCell")

function LineCell:render()
    local e = self.entry
    if not e then return end
    local lit = U.framework.Table.rowBackground(self)
    local w, lh = self.width, lineH()
    if self.fitW ~= w or self.fitE ~= e then
        self.t1 = fitText(e.line1 or "", math.max(0, w - PAD * 2))
        self.t2 = fitText(e.line2 or "", math.max(0, w - PAD * 2))
        self.fitW, self.fitE = w, e
    end
    text(self, self.t1, PAD, 6, "text")
    text(self, self.t2, PAD, 6 + lh, lit and "text" or (e.token2 or "textMuted"))
end

-- Order table: the columns (list.cols) and every fitted string are set by Page:rebuildOrderRows,
-- the refund button is a real ECRowActions button (only on a row the server says can be refunded).
local OrderCell = ISPanel:derive("MinidoracatEconomyAdminEntOrderCell")

function OrderCell:render()
    local e = self.entry
    if not e or not e.fit then return end
    local lit = U.framework.Table.rowBackground(self)
    local list = self.list
    local cols = list.cols
    local ty = list.showIds and 4 or math.floor((self.height - fontH.small) / 2)
    for i = 1, #cols do
        local col, s = cols[i], e.fit[i]
        if col and s then
            local token = e.tokens[i]
            if lit and (token == "textMuted" or token == "textFaint") then token = "text" end
            if col.right then textRight(self, s, col.x + col.w - PAD, ty, token)
            else text(self, s, col.x, ty, token) end
        end
    end
    if list.showIds and e.idsFit then
        text(self, e.idsFit, list.contentX, ty + lineH(), lit and "text" or "textMuted")
    end
    local R = C.RowActions
    R.begin(self)
    if e.refundable then
        local chipH = math.min(ctrlH(), self.height - 4)
        R.put(self, "refund", list.refundLabel, list.actionX, math.floor((self.height - chipH) / 2),
            list.actionW, chipH, list.refundEnabled == true)
    end
    R.finish(self)
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

    -- accounts section
    self.accountField = UI.TextField.new({ x = 0, y = 0, width = 220, height = ch, theme = theme,
        maxLength = ACCOUNT_MAX, placeholder = tr("Ent_AccountHint") })
    self.accountField._entry.onCommandEntered = function() self:onLookup() end
    self:addChild(self.accountField)
    self.lookupButton = self:makeButton("Ent_Lookup", "normal", Page.onLookup)
    self.allButton = self:makeButton("Ent_All", "normal", Page.onAll)
    self.orderList = U.newTable(OrderCell, ch + 6)
    self.orderList.onSelect = function(_, item) self:onOrderRow(item) end
    self.orderList.onRowAction = function(_, item, id) if id == "refund" then self:openRefund(item) end end
    self.orderList.refundLabel = tr("Ent_RefundRow")
    self:addChild(self.orderList)
    self.moreButton = self:makeButton("Ent_More", "normal", Page.onMore)
    self.rentalsButton = self:makeButton("Ent_More", "normal", Page.onAllRentals)
    local idsLabel = tr("Ent_ShowIds")
    self.idsToggle = UI.Checkbox.new({ x = 0, y = 0, width = 36 + 8 + textWidth(idsLabel) + 4, height = ch,
        label = idsLabel, theme = theme, target = self,
        onChange = function(page, checked) page:setShowIds(checked) end })
    self.idsToggle.forceClick = function(box)
        if box._enabled ~= false then box:setChecked(not box.checked) end
    end
    self:addChild(self.idsToggle)
    self.productChips = {}

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
    if self.accountField:isFocused() then self.accountField._entry:unfocus() end
end

function Page:closeDialog()
    local d = self.dialog
    self.dialog = nil
    if d ~= nil and U.framework and U.framework.Dialog then U.framework.Dialog.close(d, false) end
end

function Page:stamp(ms)
    if type(ms) ~= "number" then return "-" end
    return U.stampText(ms, self.owner.offsetMin)
end

-- ---------- sections and selection ----------

function Page:setSection(id)
    if self.broken or (id ~= "plans" and id ~= "accounts") then return end
    self.section = id
    self.tabs:setSelected(id, true)
    self:unfocusAll()
    if id == "plans" and self.plans == nil then self.plansWanted = true end
    if id == "accounts" and self.accountUser == nil and self.orders == nil then self.ordersWanted = true end
    self:layout()
    self:invalidateKeyboard()
end

function Page:selectPlan(sourceMod, productId)
    if self.broken then return false end
    self:unfocusAll()
    self.selKey = keyOf(sourceMod, productId)
    self:rebuildPlanRows()
    self:layout()
    return self:selectedEntry() ~= nil
end

-- Another page (or a consumer's admin button) asked for one product's plan.
function Page:showPlan(sourceMod, productId)
    if self.broken then return end
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

-- The whole list from the top, or (append) the next page after the last row shown: the cursor is
-- that row's time and order id, the server's own sort keys.
function Page:requestOrders()
    local args, rows = { action = "orders" }, self.orders and self.orders.rows
    local last = self.ordersAppend and rows and rows[#rows] or nil
    if last ~= nil then args.before = { at = last.at, id = tostring(last.orderId) } end
    if self:sendAction(args, { action = "orders", append = last ~= nil }) then
        self.ordersWanted, self.ordersAppend, self.ordersTimeout = false, false, false
        return true
    end
    return false
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

-- The controller cancelled a cooldown-held write before sending it: this is known, not a timeout.
function Page:onCancelled(requestId)
    local req = self.sent
    if req == nil or req.requestId ~= requestId or req.answered then return end
    req.answered = true
    self:say(tr("Ent_ReadOnly"), true)
    self:layout()
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
    if req.action == "plans" then
        if type(args.plans) == "table" then self:adoptPlans(args.plans) end
        if args.ok == false then
            self.plansError = args.error or "unknown"
            self:say(getText(T .. "Ent_PlansError", self:errorText(args.error)), true)
        else
            self.plansError = nil
        end
    elseif req.action == "orders" then
        if args.ok == false then
            self.ordersError = args.error or "unknown"
            self:say(getText(T .. "Ent_OrdersError", self:errorText(args.error)), true)
        else
            self:adoptOrders(args, req.append)
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
    self:rebuildOrderRows()
    self:layout()
end

-- A request whose answer never came. A read is owed again on the next refresh; a refund has an
-- unknown outcome and is never re-sent: the admin reads the list again.
function Page:onTimeout()
    local req = self.sent
    if req == nil or req.answered then return end
    req.timedOut = true
    if req.action == "plans" then
        self.plansTimeout = true
        self:say(tr("Ent_PlansTimeout"), true)
    elseif req.action == "orders" then
        self.ordersTimeout = true
        self:say(tr("Ent_OrdersTimeout"), true)
    elseif req.action == "account" then
        self.accountTimeout = true
        self:say(tr("Ent_AccountTimeout"), true)
    elseif req.action == "refund" then
        self:say(tr("Ent_RefundTimeout"), true)
    end
    self:unfocusAll()
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
    self.plansTimeout, self.updatedAt = false, EC.now()
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

function Page:adoptOrders(args, append)
    local rows, seen = {}, {}
    local function add(r)
        local key = keyOf(r.sourceMod, r.orderId)
        if not seen[key] then
            seen[key] = true
            rows[#rows + 1] = r
        end
    end
    if append and self.orders ~= nil then
        for _, r in ipairs(self.orders.rows) do add(r) end
    end
    for _, r in ipairs(type(args.orders) == "table" and args.orders or {}) do
        if type(r) == "table" and type(r.username) == "string" and type(r.sourceMod) == "string"
            and type(r.productId) == "string" and r.orderId ~= nil then
            add(r)
        end
    end
    self.orders = { rows = rows, more = args.more == true }
    self.ordersError, self.ordersTimeout, self.updatedAt = nil, false, EC.now()
end

-- ---------- accounts ----------

function Page:filterUser(user, productKey)
    self:unfocusAll()
    if user ~= self.accountUser then
        self.account, self.entrySel, self.accountError = nil, nil, nil
        self.entryKey = productKey
    elseif productKey ~= nil then
        self.entryKey = productKey
    end
    self.accountUser = user
    self.accountWanted = true
    self.accountField:setText(user)
    self:tick(EC.now())
    self:rebuildOrderRows()
    self:layout()
    self:invalidateKeyboard()
    self:closeRentals()
end

function Page:onLookup()
    if self.broken then return end
    local user = trim(self.accountField:getText())
    if user == "" then
        self:onAll()
        return
    end
    self:filterUser(user, nil)
end

-- Back to every account's orders, read again from the top.
function Page:onAll()
    if self.broken then return end
    self:unfocusAll()
    self.accountUser, self.account, self.entrySel, self.entryKey = nil, nil, nil, nil
    self.accountError, self.accountTimeout, self.accountWanted = nil, false, false
    self.accountField:setText("")
    self.ordersWanted, self.ordersAppend = true, false
    self:tick(EC.now())
    self:rebuildOrderRows()
    self:layout()
    self:invalidateKeyboard()
    self:closeRentals()
end

function Page:onMore()
    if self.broken or self.accountUser ~= nil or self.orders == nil or not self.orders.more then return end
    self.ordersWanted, self.ordersAppend = true, true
    self:tick(EC.now())
    self:layout()
end

-- A row of every account's orders filters the page to that player (and that product).
function Page:onOrderRow(item)
    if item == nil or self.accountUser ~= nil then return end
    self:filterUser(item.username, keyOf(item.sourceMod, item.productId))
end

function Page:setShowIds(on)
    self.showIds = on == true
    self:rebuildOrderRows()
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
    self.account = { username = username, entries = list }
    self.accountError, self.accountTimeout, self.updatedAt = nil, false, EC.now()
    self.entrySel = nil
    for i, e in ipairs(list) do
        if keyOf(e.sourceMod, e.productId) == self.entryKey then self.entrySel = i end
    end
    if self.entrySel == nil and list[1] ~= nil then self.entrySel = 1 end
    local e = self.entrySel and list[self.entrySel] or nil
    self.entryKey = e and keyOf(e.sourceMod, e.productId) or nil
    self:refreshRentals()
end

function Page:selectedAccountEntry()
    local acc = self.account
    if acc == nil or self.entrySel == nil then return nil end
    return acc.entries[self.entrySel]
end

function Page:selectEntry(index)
    local acc = self.account
    if acc == nil or type(index) ~= "number" or acc.entries[index] == nil then return false end
    local e = acc.entries[index]
    self.entrySel, self.entryKey = index, keyOf(e.sourceMod, e.productId)
    self:rebuildOrderRows()
    self:layout()
    self:invalidateKeyboard()
    self:closeRentals()
    return true
end

-- ---------- every rental, in the shared detail window ----------

function Page:rentalsKey()
    return "entrentals:" .. tostring(self.accountUser) .. "\1" .. tostring(self.entryKey)
end

function Page:rentalsContent()
    local entry = self:selectedAccountEntry()
    if entry == nil then return nil end
    local now = EC.now()
    return getText(T .. "Ent_Pair", self.account.username, Ent().productName(entry)),
        P.rentalsText(entry, now, self.owner.offsetMin),
        P.rentalsCard(entry, self.account.username, now, self.owner.offsetMin)
end

function Page:onAllRentals()
    local D = C.DetailWindow
    local title, body, card = self:rentalsContent()
    if D == nil or title == nil then return end
    D.open(self, self:rentalsKey(), title, body, nil, card)
end

-- a fresh account read keeps an open list current; the window never outlives its account
function Page:refreshRentals()
    local D = C.DetailWindow
    local title, body, card = self:rentalsContent()
    if D ~= nil and title ~= nil then D.update(self, self:rentalsKey(), title, body, card) end
end

function Page:closeRentals()
    local D = C.DetailWindow
    if D ~= nil then D.close(self) end
end

-- ---------- refunds ----------

-- The refund of one order row: the framework dialog says what goes back to whom and what happens
-- to the slots, and takes the reason. A blank reason sends nothing and asks again.
function Page:openRefund(row, problem)
    if self.broken or row == nil or not row.refundable then return end
    if not self.owner:writeAllowed() then
        self:say(tr("Ent_ReadOnly"), true)
        return
    end
    local o = row.order
    local lines = P.refundLines(o, row.username, row.content, self.owner.offsetMin)
    if problem ~= nil then table.insert(lines, 1, problem) end
    lines[#lines + 1] = ""
    lines[#lines + 1] = tr("Ent_Reason")
    local width = DIALOG_W
    if type(getCore) == "function" then width = math.min(DIALOG_W, getCore():getScreenWidth() - 40) end
    local dialog
    dialog = U.framework.Dialog.show({ title = tr("Ent_RefundTitle"), text = table.concat(lines, "\n"),
        theme = U.theme, width = width, input = { placeholder = tr("Ent_ReasonHint") },
        confirmText = getText(T .. "Ent_RefundConfirm", moneyText(o.amount, o.currency)),
        cancelText = tr("Ent_Cancel"), danger = true,
        onResult = function(ok, value) self:onRefundResult(dialog, row, ok, value) end })
    self.dialog = dialog
    self:updateEnabled()
end

function Page:onRefundResult(dialog, row, ok, value)
    if self.dialog == dialog then self.dialog = nil end
    if not ok or self.broken then
        self:updateEnabled()
        return
    end
    local reason = trim(value)
    local bad = reasonError(reason)
    if bad ~= nil then
        self:openRefund(row, bad)
        return
    end
    if not self.owner:writeAllowed() then
        self:say(tr("Ent_ReadOnly"), true)
        return
    end
    local o = row.order
    local args = { action = "refund", username = row.username, sourceMod = row.sourceMod, productId = row.productId,
        orderId = orderIdOf(o), reason = reason }
    local sent, why = self:sendAction(args, { action = "refund", username = row.username, orderId = args.orderId,
        amount = moneyText(o.amount, o.currency) })
    if sent then self:say(tr("Ent_RefundSending")) else self:say(self:errorText(why), true) end
    self:layout()
end

-- Answered: the view on screen is read again (the account's snapshot comes with the reply).
function Page:onRefundReply(args, req)
    if args.ok ~= true then
        self:say(self:errorText(args.error), true)
        return
    end
    if self.accountUser == nil then
        self.ordersWanted, self.ordersAppend = true, false
    elseif req.username == self.accountUser and type(args.entries) == "table" then
        self:adoptAccount(req.username, args.entries)
    else
        self.accountWanted = true
    end
    self:say(args.duplicate and tr("Ent_RefundDuplicate") or getText(T .. "Ent_RefundDone", req.amount, req.username))
    self:invalidateKeyboard()
end

-- ---------- rows (data changes only) ----------

function Page:rebuildPlanRows()
    if self.broken then return end
    local items, sel = {}, nil
    for i, e in ipairs(self.plans or {}) do
        local key = keyOf(e.sourceMod, e.productId)
        local problem = type(e.source) == "table" and type(e.source.problem) == "table"
        items[i] = { sourceMod = e.sourceMod, productId = e.productId, line1 = Ent().productName(e),
            line2 = getText(T .. "Ent_PlanRowLine", P.sourceName(e), boolText(e.plan.permanentEnabled == true),
                boolText(e.plan.rentalEnabled == true)),
            token2 = (e.loaded == false or problem or e.plan.provisional == true) and "warn" or nil }
        if key == self.selKey then sel = i end
    end
    self.planList:setItems(items)
    self.planList:setSelectedIndex(sel)
end

-- The orders the accounts section shows: every account's (newest first, as the server sent them)
-- or the filtered account's picked product (sorted the same way here).
function Page:orderSource()
    if self.accountUser == nil then
        local out, products, count = {}, {}, 0
        for _, r in ipairs(self.orders and self.orders.rows or {}) do
            local key = keyOf(r.sourceMod, r.productId)
            if not products[key] then products[key], count = true, count + 1 end
            out[#out + 1] = { order = r, username = r.username, sourceMod = r.sourceMod, productId = r.productId,
                instant = r.instant == true, product = r }
        end
        return out, count > 1
    end
    local e = self:selectedAccountEntry()
    local out = {}
    if e == nil then return out, false end
    for _, o in ipairs(type(e.orders) == "table" and e.orders or {}) do
        if type(o) == "table" then
            out[#out + 1] = { order = o, username = self.accountUser, sourceMod = e.sourceMod, productId = e.productId,
                instant = e.instant == true, product = e }
        end
    end
    EC.sortSafe(out, function(a, b)
        local ta, tb = tonumber(a.order.at) or 0, tonumber(b.order.at) or 0
        if ta ~= tb then return ta > tb end
        return tostring(orderIdOf(a.order)) > tostring(orderIdOf(b.order))
    end)
    return out, false
end

local function idsText(o)
    local id = orderIdOf(o) or "-"
    local s = o.txId ~= nil and getText(T .. "Ent_IdsLine", id, tostring(o.txId)) or getText(T .. "Ent_IdsOrder", id)
    local refundTx = type(o.refund) == "table" and o.refund.txId or nil
    if refundTx ~= nil then s = pair(s, getText(T .. "Ent_IdsRefund", tostring(refundTx))) end
    return s
end

-- Builds the rows, then the columns from what they hold, then fits every string once.
function Page:rebuildOrderRows()
    if self.broken then return end
    local list = self.orderList
    local source, multi = self:orderSource()
    local withPlayer = self.accountUser == nil
    local rows = {}
    local wPlayer, wAmount, wStatus = textWidth(tr("Ent_Col_Player")), textWidth(tr("Ent_Col_Amount")),
        textWidth(tr("Ent_Col_Status"))
    -- digits are proportional in the CN/JP fonts: "0000-00-00 00:00" can be narrower than a real stamp
    local wTime = math.max(textWidth(U.STAMP_SAMPLE), textWidth(tr("Ent_Col_Time")))
    for i, s in ipairs(source) do
        local o = s.order
        local content = P.contentText(o)
        if multi then content = pair(Ent().productName(s.product), content) end
        local status = P.statusText(o, s.instant)
        local cells = { self:stamp(tonumber(o.at)) }
        wTime = math.max(wTime, textWidth(cells[1]))
        if withPlayer then cells[#cells + 1] = s.username end
        cells[#cells + 1] = content
        cells[#cells + 1] = moneyText(o.amount, o.currency)
        cells[#cells + 1] = status
        local tokens = { "textMuted" }
        if withPlayer then tokens[#tokens + 1] = "text" end
        tokens[#tokens + 1] = "text"
        tokens[#tokens + 1] = "text"
        tokens[#tokens + 1] = o.status == "paid" and "text" or "textMuted"
        rows[i] = { order = o, username = s.username, sourceMod = s.sourceMod, productId = s.productId,
            instant = s.instant, content = content, cells = cells, tokens = tokens, ids = idsText(o),
            refundable = o.refundable == true and o.status == "paid" }
        if withPlayer then wPlayer = math.max(wPlayer, textWidth(s.username)) end
        wAmount = math.max(wAmount, textWidth(cells[#cells - 1]))
        wStatus = math.max(wStatus, textWidth(status))
    end
    -- columns: time | player? | content (the rest) | amount (right) | status | the refund button
    local width = list.width - 10
    local timeW = wTime + PAD
    local actionW = textWidth(list.refundLabel) + 20
    local playerW = withPlayer and math.min(math.floor(width * 0.2), wPlayer + PAD) or 0
    local amountW, statusW = wAmount + PAD * 2, math.min(math.floor(width * 0.25), wStatus + PAD)
    local contentW = math.max(40, width - PAD - timeW - playerW - amountW - statusW - actionW - PAD)
    local cols, x = {}, PAD
    local function col(w, right, title)
        cols[#cols + 1] = { x = x, w = w, right = right, title = title }
        x = x + w
    end
    col(timeW, false, tr("Ent_Col_Time"))
    if withPlayer then col(playerW, false, tr("Ent_Col_Player")) end
    list.contentX = x
    col(contentW, false, tr("Ent_Col_Content"))
    col(amountW, true, tr("Ent_Col_Amount"))
    col(statusW, false, tr("Ent_Col_Status"))
    list.actionX, list.actionW = x, actionW
    list.cols, list.showIds = cols, self.showIds == true
    for _, r in ipairs(rows) do
        r.fit = {}
        for i, c in ipairs(cols) do r.fit[i] = fitText(r.cells[i], math.max(0, c.w - PAD)) end
        r.idsFit = fitText(r.ids, math.max(0, width - list.contentX - actionW - PAD))
    end
    self.orderRows = rows
    self.orderRowsW = list.width
    local rowH = self.showIds and rowH2() or ctrlH() + 6
    if list.rowHeight ~= rowH then
        list.rowHeight = rowH
        list:resize(list.width, list.height)
    end
    local sel = list:getSelectedItem()
    list:setItems(rows)
    local keep = nil
    for i, r in ipairs(rows) do
        if sel ~= nil and r.order == sel.order then keep = i end
    end
    list:setSelectedIndex(keep)
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
    local plans = self.section == "plans"
    local accounts = not plans
    g.topH = self.tabs.height + 6
    g.statusX = self.tabs.width + PAD
    g.statusY = math.floor((self.tabs.height - fontH.small) / 2)

    show(self.planList, plans)
    for _, el in ipairs({ self.accountField, self.lookupButton }) do show(el, accounts) end
    if plans then
        for _, el in ipairs({ self.allButton, self.orderList, self.moreButton, self.idsToggle, self.rentalsButton }) do show(el, false) end
        for _, b in ipairs(self.productChips) do show(b, false) end
        self:layoutPlans(g, w, h)
    else
        self:layoutAccounts(g, w, h)
    end
    self:updateEnabled()
end

function Page:layoutPlans(g, w, h)
    local top = g.topH
    local bodyH = math.max(ctrlH() * 3, h - top)
    local th = titleH()
    local lx, ly, lw, lh2, ex, ey, ew, eh
    -- nothing registered at all: the one card takes the whole body and says so as an empty state,
    -- instead of a narrow list beside three empty quarters of the page
    local none = self.plans ~= nil and #self.plans == 0 and not self.plansError and not self.plansTimeout
    if none then
        lx, ly, lw, lh2 = 0, top, w, bodyH
        ex, ey, ew, eh = 0, top + bodyH, w, 0
    elseif w < 640 then
        lx, ly, lw = 0, top, w
        lh2 = math.max(th + rowH2() * 2 + 4, math.floor(bodyH * 0.3))
        ex, ey, ew, eh = 0, top + lh2 + PAD, w, math.max(ctrlH() * 3, bodyH - lh2 - PAD)
    else
        lw = math.max(200, math.min(300, math.floor(w * 0.28)))
        lx, ly, lh2 = 0, top, bodyH
        ex, ey, ew, eh = lw + PAD, top, w - lw - PAD, bodyH
    end
    g.listCard = { x = lx, y = ly, w = lw, h = lh2, title = fitText(tr("Ent_Products"), lw - PAD * 2, UIFont.Medium) }
    U.placeList(self.planList, true, lx + 1, ly + th + 1, lw - 2, math.max(rowH2(), lh2 - th - 2))
    g.listEmpty = {}
    g.noPlans = none
    if none then
        U.emptyState(self, "plans", lx, ly + th, lw, lh2 - th, tr("Ent_NoProductsTitle"), tr("Ent_NoProducts"))
    elseif self.plans == nil or #self.plans == 0 then
        local msg
        if self.plansTimeout then msg = tr("Ent_PlansTimeout")
        elseif self.plansError then msg = getText(T .. "Ent_PlansError", self:errorText(self.plansError))
        else msg = tr("Admin_Loading") end
        wrapInto(g.listEmpty, msg, lw - PAD * 2, self.plansError and "errorText" or "textMuted", 6)
    end
    g.listEmptyY = ly + th + PAD
    g.ops = {}
    self:layoutOverview(g, ex, ey, ew, eh)
end

local function opText(ops, s, x, y, token, font)
    ops[#ops + 1] = { kind = "text", s = s, x = x, y = y, token = token, font = font }
end

local function opChip(ops, s, x, y, token)
    local w, h = textWidth(s) + 16, fontH.small + 4
    ops[#ops + 1] = { kind = "chip", s = s, x = x, y = y, w = w, h = h, token = token }
    return w, h
end

-- One terms card: its title with the open / closed chip on the right, then label / value rows.
-- Returns the card op (its height may be raised to match a neighbour) and its height.
local function opCard(ops, x, y, w, title, open, rows)
    local th, lh = titleH(), lineH()
    local h = th + PAD + #rows * lh + PAD - 6
    local chip = tr(open and "Ent_Open" or "Ent_Closed")
    local cw = textWidth(chip) + 16
    local cardOp = { kind = "card", x = x, y = y, w = w, h = h, title = fitText(title, w - PAD * 3 - cw, UIFont.Medium) }
    ops[#ops + 1] = cardOp
    opChip(ops, chip, x + w - PAD - cw, y + math.floor((th - fontH.small - 4) / 2), open and "positive" or "textMuted")
    local labelW = 0
    for _, r in ipairs(rows) do labelW = math.max(labelW, textWidth(r[1])) end
    labelW = math.min(labelW, math.floor((w - PAD * 2) * 0.5))
    local vx = x + PAD + labelW + 14
    local ry = y + th + PAD - 3
    for _, r in ipairs(rows) do
        opText(ops, fitText(r[1], labelW), x + PAD, ry, "textMuted")
        opText(ops, fitText(r[2], math.max(0, x + w - PAD - vx)), vx, ry, "text")
        ry = ry + lh
    end
    return cardOp, h
end

-- The picked product, drawn from ops built here (data or geometry changes only, never per frame).
function Page:layoutOverview(g, ex, ey, ew, eh)
    local ops, lh = g.ops, lineH()
    local x, iw = ex, math.max(80, ew)
    local entry = self:selectedEntry()
    if entry == nil then
        if self.plans ~= nil and #self.plans > 0 then
            local lines = {}
            wrapInto(lines, tr("Ent_PickProduct"), iw, "textMuted", 3)
            for i, l in ipairs(lines) do opText(ops, l.s, x, ey + (i - 1) * lh, l.token) end
        end
        return
    end
    local plan, y = entry.plan, ey
    -- title, the "takes effect on payment" chip, and who sets these terms
    local title = fitText(Ent().productName(entry), iw, UIFont.Medium)
    opText(ops, title, x, y, "text", UIFont.Medium)
    local cx = x + textWidth(title, UIFont.Medium) + PAD
    local cy = y + math.floor((fontH.medium - fontH.small - 4) / 2)
    if entry.instant == true then
        local cw = opChip(ops, tr("Ent_InstantChip"), cx, cy, "positive")
        cx = cx + cw + PAD
    end
    local managed = tr("Ent_ManagedBy")
    if cx + textWidth(managed) <= x + iw then
        opText(ops, managed, cx, cy + 2, "textMuted")
        y = y + fontH.medium + PAD
    else
        y = y + fontH.medium + 4
        opText(ops, fitText(managed, iw), x, y, "textMuted")
        y = y + lh + 6
    end
    -- the warning box: settings file problem, provisional plan, source not loaded
    local warn = {}
    local problem = P.problemText(type(entry.source) == "table" and entry.source.problem or nil)
    if problem ~= nil then wrapInto(warn, problem, iw - PAD * 2, "warn", 4) end
    if plan.provisional == true then wrapInto(warn, tr("Ent_Provisional"), iw - PAD * 2, "warn", 3) end
    if entry.loaded == false then wrapInto(warn, tr("Ent_NotLoaded"), iw - PAD * 2, "warn", 3) end
    if #warn > 0 then
        local bh = #warn * lh + 8
        ops[#ops + 1] = { kind = "box", x = x, y = y, w = iw, h = bh, token = "warn" }
        for i, l in ipairs(warn) do opText(ops, l.s, x + PAD, y + 4 + (i - 1) * lh, l.token) end
        y = y + bh + PAD
    end
    -- the two terms cards, side by side when both fit
    local permanent = {
        { tr("Ent_L_UnitPrice"), moneyText(plan.permanentPrice, plan.permanentCurrency) },
        { tr("Ent_L_Limit"), getText(T .. "Ent_Units", num(plan.permanentLimit)) },
    }
    local rental = {
        { tr("Ent_L_UnitPrice"), getText(T .. "Ent_PerPeriod", moneyText(plan.rentalPrice, plan.rentalCurrency), num(plan.rentalDays)) },
        { tr("Ent_L_RentalLimit"), getText(T .. "Ent_Units", num(plan.rentalLimit)) },
        { tr("Ent_L_GraceReminder"), getText(T .. "Ent_GraceReminder", num(plan.graceHours), num(plan.reminderHours)) },
        { tr("Ent_L_AutoRenew"), tr(plan.autoRenewAllowed == true and "Ent_Allowed" or "Ent_NotAllowed") },
    }
    if iw >= CARD_MIN_W * 2 + PAD then
        local cw = math.floor((iw - PAD) / 2)
        local c1, h1 = opCard(ops, x, y, cw, tr("Ent_CardPermanent"), plan.permanentEnabled == true, permanent)
        local c2, h2 = opCard(ops, x + cw + PAD, y, iw - cw - PAD, tr("Ent_CardRental"), plan.rentalEnabled == true, rental)
        -- both cards share the taller one's height
        c1.h, c2.h = math.max(h1, h2), math.max(h1, h2)
        y = y + math.max(h1, h2) + PAD
    else
        local _, h1 = opCard(ops, x, y, iw, tr("Ent_CardPermanent"), plan.permanentEnabled == true, permanent)
        y = y + h1 + PAD
        local _, h2 = opCard(ops, x, y, iw, tr("Ent_CardRental"), plan.rentalEnabled == true, rental)
        y = y + h2 + PAD
    end
    -- footer: the last change and the settings file
    local foot = {}
    for _, s in ipairs(self:planFooter(entry)) do wrapInto(foot, s, iw, "textMuted", 2) end
    if #foot > 0 then
        ops[#ops + 1] = { kind = "rule", x = x, y = y, w = iw }
        y = y + 6
        for i, l in ipairs(foot) do
            if y + i * lh <= ey + eh then opText(ops, l.s, x, y + (i - 1) * lh, l.token) end
        end
    end
end

-- "Last changed <time>, <where> [, <admin>] [, reason: ...]" and "Settings file <path>". The
-- account is shown only for a change made in a source's in-game settings (anything else names a
-- process, not a person).
function Page:planFooter(entry)
    local out = {}
    local c = entry.lastChange
    if type(c) == "table" and tonumber(c.at) ~= nil then
        local s = getText(T .. "Ent_FootChanged", self:stamp(tonumber(c.at)))
        s = pair(s, getTextOrNull(T .. "Ent_Origin_" .. tostring(c.origin)) or tr("Ent_Origin_other"))
        if c.origin == "admin" and type(c.actor) == "string" and c.actor ~= "" then s = pair(s, c.actor) end
        if type(c.reason) == "string" and c.reason ~= "" then s = pair(s, getText(T .. "Ent_FootReason", c.reason)) end
        out[#out + 1] = s
    end
    local file = type(entry.source) == "table" and entry.source.file or nil
    if type(file) == "string" and file ~= "" then out[#out + 1] = getText(T .. "Ent_FootFile", file) end
    return out
end

function Page:accountNote()
    if self.accountUser == nil then
        if self.ordersTimeout then return tr("Ent_OrdersTimeout"), "errorText" end
        if self.ordersError ~= nil then return getText(T .. "Ent_OrdersError", self:errorText(self.ordersError)), "errorText" end
        return nil
    end
    if self.accountTimeout then return tr("Ent_AccountTimeout"), "errorText" end
    if self.accountError ~= nil then return getText(T .. "Ent_AccountError", self:errorText(self.accountError)), "errorText" end
    if self.account == nil then return tr("Admin_Loading"), "textMuted" end
    if #self.account.entries == 0 then return getText(T .. "Ent_AccountEmpty", self.account.username), "textMuted" end
    return nil
end

function Page:productChip(i)
    local b = self.productChips[i]
    if b == nil then
        b = controls().Button.new({ x = 0, y = 0, width = 80, height = ctrlH(), title = "", style = "normal",
            theme = U.theme, target = self, onClick = function(page) page:selectEntry(i) end })
        self:addChild(b)
        self.productChips[i] = b
    end
    return b
end

function Page:layoutAccounts(g, w, h)
    local lh, ch = lineH(), ctrlH()
    local top = g.topH
    -- the filter row
    local label = tr("Ent_Account")
    local labelW = math.min(textWidth(label), math.floor(w * 0.3))
    g.accLabel, g.accLabelY = fitText(label, labelW), top + math.floor((ch - fontH.small) / 2)
    local fx = labelW + 8
    local fw = math.max(120, math.min(260, math.floor(w * 0.35)))
    self.accountField:setX(fx)
    self.accountField:setY(top)
    setFieldWidth(self.accountField, fw)
    self.lookupButton.ecShow = true
    self.allButton.ecShow = self.accountUser ~= nil
    self:flowButtons({ self.lookupButton, self.allButton }, fx + fw + 6, math.max(60, w - fx - fw - 6), top)
    local last = self.allButton.ecShow and self.allButton or self.lookupButton
    local noteX = last.x + last.width + PAD
    local note, token = self:accountNote()
    local y = top + ch + PAD
    g.accNote = nil
    if note ~= nil then
        if w - noteX < 160 then
            g.accNoteX, g.accNoteY = 0, y
            y = y + lh + 4
        else
            g.accNoteX, g.accNoteY = noteX, g.accLabelY
        end
        g.accNote, g.accNoteToken = fitText(note, w - g.accNoteX), token
    end
    -- the footer: who may switch auto-renew (filtered), show earlier (all), the ids toggle
    local footY = h - ch
    g.foot = {}
    if self.accountUser ~= nil then g.foot[#g.foot + 1] = { s = tr("Ent_AutoRenewOwner"), token = "textMuted" } end
    if not self.owner:writeAllowed() then g.foot[#g.foot + 1] = { s = tr("Ent_ReadOnly"), token = "warn" } end
    local idsW = self.idsToggle.width
    show(self.idsToggle, true)
    self.idsToggle:setX(math.max(0, w - idsW))
    self.idsToggle:setY(footY)
    self.idsToggle:setChecked(self.showIds == true, true)
    local more = self.accountUser == nil and self.orders ~= nil and self.orders.more == true
    self.moreButton.ecShow = more
    self:flowButtons({ self.moreButton }, 0, math.max(60, w - idsW - PAD), footY)
    local footTextX = more and (self.moreButton.width + PAD) or 0
    g.footX, g.footY = footTextX, footY + math.floor((ch - fontH.small) / 2)
    local footRoom = math.max(0, w - idsW - PAD - footTextX)
    local parts = nil
    for _, f in ipairs(g.foot) do parts = parts and pair(parts, f.s) or f.s end
    g.footText = parts and fitText(parts, footRoom) or nil
    g.footToken = (#g.foot > 0 and g.foot[#g.foot].token == "warn") and "warn" or "textMuted"
    local bodyBottom = footY - PAD

    -- the filtered account's head: title, product chips, summary, rentals
    g.head, g.rentals = {}, {}
    local entry = self.accountUser ~= nil and self:selectedAccountEntry() or nil
    local chips = {}
    self.rentalsButton.ecShow = false
    if entry ~= nil then
        local acc = self.account
        opText(g.head, fitText(getText(T .. "Ent_Pair", acc.username, Ent().productName(entry)), w, UIFont.Medium), 0, y, "text", UIFont.Medium)
        y = y + fontH.medium + 6
        if #acc.entries > 1 then
            for i, e in ipairs(acc.entries) do
                local b = self:productChip(i)
                local name = Ent().productName(e)
                b.ecFull, b.ecShow = name, true
                b:setStyle(i == self.entrySel and "primary" or "normal")
                chips[#chips + 1] = b
            end
            y = y + self:flowButtons(chips, 0, w, y) + 6
        end
        local ent = type(entry.entitlement) == "table" and entry.entitlement or {}
        local rentals = type(ent.rentals) == "table" and ent.rentals or {}
        opText(g.head, fitText(getText(T .. "Ent_Summary", num(ent.usable), num(ent.permanent), num(ent.rental),
            tostring(#rentals)), w), 0, y, "textMuted")
        y = y + lh + 6
        if #rentals > 0 then
            opText(g.head, tr("Ent_RentalsHead"), 0, y, "text")
            y = y + lh
            local room = math.max(1, math.floor((bodyBottom - y) * 0.4 / lh))
            local shown = #rentals <= room and #rentals or math.max(1, room - 1)
            local now = EC.now()
            for i = 1, shown do
                local r = rentals[i]
                if type(r) == "table" then
                    local tag, tagToken = P.autoTag(r, entry.plan, ent)
                    local tagFit = fitText(tag, math.floor(w * 0.45))
                    local tagW = textWidth(tagFit)
                    opText(g.head, fitText(P.rentalLine(i, r, now, self.owner.offsetMin), w - tagW - PAD * 2), PAD, y, "text")
                    g.head[#g.head + 1] = { kind = "textRight", s = tagFit, x = w - PAD, y = y, token = tagToken }
                    y = y + lh
                end
            end
            if shown < #rentals then
                -- the rest opens in the shared detail window: every rental, in full
                self.rentalsButton.ecFull = getText(T .. "Ent_MoreRentals", tostring(#rentals))
                self.rentalsButton.ecShow = true
                y = y + self:flowButtons({ self.rentalsButton }, PAD, math.max(60, w - PAD * 2), y) + 4
            end
            y = y + 6
        end
        opText(g.head, tr("Ent_OrdersHead"), 0, y, "text")
        y = y + lh
    end
    if not self.rentalsButton.ecShow then show(self.rentalsButton, false) end
    for i, b in ipairs(self.productChips) do
        if chips[i] ~= b then b.ecShow = false; show(b, false) end
    end

    -- the order table (with its column titles) fills what is left
    local tableOn = self.accountUser == nil or entry ~= nil
    local listY = y + lh + 2
    local listH = math.max(lh, bodyBottom - listY)
    U.placeList(self.orderList, tableOn, 0, listY, w, listH)
    if tableOn and self.orderRowsW ~= self.orderList.width then self:rebuildOrderRows() end
    g.header, g.headerY = {}, y
    g.empty = nil
    if tableOn then
        for _, c in ipairs(self.orderList.cols or {}) do
            g.header[#g.header + 1] = { s = fitText(c.title, math.max(0, c.w - PAD)), x = c.right and (c.x + c.w - PAD) or c.x, right = c.right }
        end
        if #(self.orderRows or {}) == 0 then
            local msg
            if self.accountUser ~= nil then msg = tr("Ent_NoOrders")
            elseif self.orders == nil then msg = (self.ordersError == nil and not self.ordersTimeout) and tr("Admin_Loading") or nil
            else msg = tr("Ent_NoOrdersAll") end
            if msg ~= nil then g.empty = { s = fitText(msg, w - PAD * 2), y = listY + PAD } end
        end
    end
end

-- ---------- enabling ----------

function Page:updateEnabled()
    if self.broken then return end
    local read = self.owner:readAllowed()
    local write = read and self.owner:writeAllowed()
    local modal = self.owner.dialog ~= nil or self.dialog ~= nil
    local pending = self.isPending(COMMAND)
    self.accountField:setEnabled(read and not modal)
    self.lookupButton:setEnabled(read and not modal and not pending)
    self.allButton:setEnabled(read and not modal)
    self.moreButton:setEnabled(read and not modal and not pending)
    self.idsToggle:setEnabled(not modal)
    for _, b in ipairs(self.productChips) do b:setEnabled(not modal) end
    self.orderList.refundEnabled = write and not modal and not pending
    self.tabs.enable = not modal
end

-- ---------- keyboard (ECKeyboard walks these; the page owns no key dispatch) ----------

function Page:keyboardTargets()
    if self.broken or not self:getIsVisible() then return {} end
    local out = {}
    out[#out + 1] = { kind = "button", control = self.tabs, label = tr("Ent_Kb_Sections") }
    if self.section ~= "accounts" then
        out[#out + 1] = { kind = "list", control = self.planList, label = tr("Ent_Kb_Plans") }
        return out
    end
    out[#out + 1] = { kind = "entry", control = self.accountField._entry, label = tr("Ent_Account") }
    out[#out + 1] = { kind = "button", control = self.lookupButton, label = tr("Ent_Lookup") }
    if self.allButton:getIsVisible() then
        out[#out + 1] = { kind = "button", control = self.allButton, label = tr("Ent_All") }
    end
    local chips = {}
    for _, b in ipairs(self.productChips) do
        if b:getIsVisible() then chips[#chips + 1] = b end
    end
    if #chips > 0 then out[#out + 1] = { kind = "group", controls = chips, label = tr("Ent_Kb_Products") } end
    if self.rentalsButton:getIsVisible() then
        out[#out + 1] = { kind = "button", control = self.rentalsButton, label = self.rentalsButton.ecFull }
    end
    if self.orderList:getIsVisible() then
        out[#out + 1] = { kind = "list", control = self.orderList,
            label = tr(self.accountUser == nil and "Ent_Kb_OrdersAll" or "Ent_Kb_Orders") }
        local actions = C.RowActions.targets(self.orderList)
        if #actions > 0 then out[#out + 1] = { kind = "group", controls = actions, label = tr("Ent_Kb_RowActions") } end
    end
    if self.moreButton:getIsVisible() then
        out[#out + 1] = { kind = "button", control = self.moreButton, label = tr("Ent_More") }
    end
    out[#out + 1] = { kind = "button", control = self.idsToggle, label = tr("Ent_ShowIds") }
    return out
end

-- The refund dialog is the framework's own modal root; while it is up the controller refuses a
-- tab switch.
function Page:isModal()
    return not self.broken and self.dialog ~= nil
end

function Page:onEscape()
    return false
end

-- ---------- drawing ----------

local function drawOps(el, ops)
    for i = 1, #ops do
        local o = ops[i]
        local kind = o.kind
        if kind == "text" then
            text(el, o.s, o.x, o.y, o.token, o.font)
        elseif kind == "textRight" then
            textRight(el, o.s, o.x, o.y, o.token)
        elseif kind == "chip" then
            U.border(el, o.x, o.y, o.w, o.h, o.token)
            text(el, o.s, o.x + 8, o.y + 2, o.token)
        elseif kind == "box" then
            U.border(el, o.x, o.y, o.w, o.h, o.token)
        elseif kind == "card" then
            card(el, o.x, o.y, o.w, o.h, o.title, titleH())
        elseif kind == "rule" then
            U.fill(el, o.x, o.y, o.w, 1, "border", "rect")
        end
    end
end

function Page:prerender()
    if self.broken then
        text(self, tr("Ent_NeedsFramework"), 0, 0, "errorText")
        return
    end
    local g = self.g
    if g == nil then return end
    local lh = lineH()
    if self.isPending(COMMAND) then text(self, self.busyText, g.statusX, g.statusY, "textMuted") end
    if self.section == "plans" then
        local c = g.listCard
        card(self, c.x, c.y, c.w, c.h, c.title, titleH())
        if g.noPlans then U.drawEmptyState(self, "plans") end
        for i, l in ipairs(g.listEmpty) do text(self, l.s, c.x + PAD, g.listEmptyY + (i - 1) * lh, l.token) end
        drawOps(self, g.ops)
        return
    end
    text(self, g.accLabel, 0, g.accLabelY, "text")
    if g.accNote then text(self, g.accNote, g.accNoteX, g.accNoteY, g.accNoteToken) end
    drawOps(self, g.head)
    for _, hdr in ipairs(g.header) do
        if hdr.right then textRight(self, hdr.s, hdr.x, g.headerY, "textMuted")
        else text(self, hdr.s, hdr.x, g.headerY, "textMuted") end
    end
    if g.empty then text(self, g.empty.s, PAD, g.empty.y, "textMuted") end
    if g.footText then text(self, g.footText, g.footX, g.footY, g.footToken) end
end

function Page:render() end

-- ---------- lifecycle ----------

-- The controller sizes the page on every one of its own layouts.
function Page:resize(width, height)
    if self.width ~= width then self:setWidth(width) end
    if self.height ~= height then self:setHeight(height) end
    self:layout()
end

-- Hiding keeps every snapshot; it takes the keyboard out of the text box and drops an open refund
-- dialog (nothing was sent from it).
function Page:setVisible(visible)
    ISPanel.setVisible(self, visible)
    if not visible then
        self:unfocusAll()
        self:closeDialog()
        self:closeRentals()
    end
end

-- A refresh re-reads the section on screen; the read goes out on the next tick the shared slot
-- is free, so a write in flight is never displaced.
function Page:refresh()
    if self.broken then return end
    if self.section == "accounts" then
        if self.accountUser ~= nil then self.accountWanted = true
        else self.ordersWanted, self.ordersAppend = true, false end
    else
        self.plansWanted = true
    end
    self:tick(EC.now())
end

-- The section on screen asks first.
function Page:tick(now)
    if self.broken or not self.owner:readAllowed() or self.isPending(COMMAND) then return end
    if self.section == "accounts" then
        if self.accountWanted then self:requestAccount()
        elseif self.ordersWanted then self:requestOrders()
        elseif self.plansWanted then self:requestPlans() end
    else
        if self.plansWanted then self:requestPlans()
        elseif self.accountWanted then self:requestAccount()
        elseif self.ordersWanted then self:requestOrders() end
    end
end

-- The permission collapse: everything this page learned goes, and nothing is asked for again
-- until the controller says reading is allowed.
function Page:clear()
    if self.broken then return end
    self:unfocusAll()
    self:closeDialog()
    self:closeRentals()
    self.plans, self.plansError, self.plansTimeout, self.updatedAt = nil, nil, false, nil
    self.orders, self.ordersError, self.ordersTimeout, self.ordersAppend = nil, nil, false, false
    self.sent = nil
    self.account, self.accountUser, self.accountError, self.accountTimeout = nil, nil, nil, false
    self.entrySel, self.entryKey = nil, nil
    self.plansWanted, self.accountWanted, self.ordersWanted = false, false, false
    self.selKey, self.pendingSelect, self.message = nil, nil, nil
    self.accountField:setText("")
    self.planList:setItems({})
    self.orderRows = nil
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
    o.plansWanted = true
    o:initialise()
    o:instantiate()
    o:setVisible(false)
    return o
end

return P
