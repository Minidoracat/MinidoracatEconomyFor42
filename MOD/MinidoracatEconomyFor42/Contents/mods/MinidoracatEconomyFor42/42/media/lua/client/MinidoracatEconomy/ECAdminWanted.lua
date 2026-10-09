-- MinidoracatEconomyFor42 -- admin buy order page (client). Adds exactly one namespace:
-- C.AdminWanted. (C.AdminShop.wanted is an unrelated feature: another mod's listing drafts.)
--
--   C.AdminWanted.create(owner, send, isPending, newRequestId)
--       an initialised ISPanel child, NOT added (the admin controller addChild's it). The three
--       transport functions are the controller's own and are always called as self.send(...),
--       self.isPending(...), self.newRequestId() -- never with ":". The page owns no Events hook
--       and no timer: the controller calls tick(now) while this tab is on screen.
--
-- One command, admin.wanted, two actions, one slot (the controller's):
--   list    { query?, types?, owner?, page? } -> { rows = { adminView }, page, pages, total, stats }
--           read gate. The query is a substring of the item or the owner, or names the item in
--           the admin's own language (types, C.ItemPicker.queryTypes); owner is an exact
--           account. The page is the server's to clamp.
--   cancel  { orderId, reason } -> { orderId, refunded = { [currency] = amount } }
--           write gate. The reason dialog says what goes back to the buyer; a refusal is the
--           error and nothing else, a timeout is an unknown outcome and is never re-sent.
--
-- A row: the item and how many are still wanted, the status pill (refund failed included), every
-- payment option with what it holds, then owner / condition / time left / counter-offers. The
-- row body opens the shared detail card; "this buyer" is a read and stays live for a read-only
-- role, "force cancel" is the one write and is disabled without the write role.

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
C.AdminWanted = P

local PAD, T = U.PAD, U.T
local CARD_TITLE_H = U.CARD_TITLE_H
local fontH = U.fontH
local text, textWidth, fitText = U.text, U.textWidth, U.fitText

local COMMAND = "admin.wanted"
local REASON_MAX = 1000
local QUERY_MAX = 64
local DEBOUNCE_MS = 650   -- one read per pause in either box; the server drops a repeat inside 500 ms
local DIALOG_W = 480

local function tr(key) return getText(T .. key) end
local function lineH() return fontH.small + 6 end
local function entryH() return math.max(26, fontH.small + 12) end
local function chipH() return math.max(20, fontH.small + 6) end
local function trim(s) return string.match(tostring(s or ""), "^%s*(.-)%s*$") end
local function num(v) return math.max(0, math.floor(tonumber(v) or 0)) end

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

local function dialogApi()
    local ui = U.framework
    if ui ~= nil and ui.Dialog == nil then pcall(require, "MinidoracatUI/Widgets/Window") end
    return ui ~= nil and ui.Dialog or nil
end

-- ---------- words (pure: shared with the tests) ----------

local function moneyText(amount, currency)
    return U.amountText(num(amount)) .. " " .. U.currencyName(currency)
end

-- The status pill of one order, as its translation key suffix and colour token. A refund the
-- ledger refused comes first: the server keeps retrying it and the order trades no more.
function P.statusOf(v, now)
    if v.blocked ~= nil then
        if v.blocked == "refund_failed" then return "refund_failed", "errorText" end
        return nil, "warn"
    end
    if v.closing ~= nil then return "closing", "textMuted" end
    if (tonumber(v.expiresAt) or 0) <= now then return "expired", "warn" end
    if num(v.qty) < num(v.qtyTotal) then return "partial", "accent" end
    return "open", "positive"
end

function P.statusText(v, now)
    local key, token = P.statusOf(v, now)
    if key == nil then return U.unknownText("wanted blocked", v.blocked), token end
    return tr("Admin_Wd_Status_" .. key), token
end

function P.condText(cond)
    if type(cond) ~= "table" then return tr("Admin_Wd_Cond_any") end
    if cond.new == true then return tr("Admin_Wd_Cond_new") end
    if tonumber(cond.minPct) then return getText(T .. "Admin_Wd_Cond_pct", tostring(num(cond.minPct))) end
    return tr("Admin_Wd_Cond_any")
end

local function options(v)
    return type(v.options) == "table" and v.options or {}
end

-- What a forced cancel gives back, one line each: every coin option's held money to the buyer's
-- wallet, the item option's escrowed items to the buyer's mailbox. The listing fee is not refunded.
function P.cancelLines(v)
    local lines = { getText(T .. "Admin_Wd_CancelHead", U.itemName(v.item), tostring(num(v.qty)), tostring(num(v.qtyTotal))) }
    for _, o in ipairs(options(v)) do
        if type(o) == "table" and num(o.held) > 0 then
            if o.kind == "coin" then
                lines[#lines + 1] = getText(T .. "Admin_Wd_CancelRefund", moneyText(o.held, o.currency))
            elseif o.kind == "item" then
                lines[#lines + 1] = getText(T .. "Admin_Wd_CancelReturn", tostring(num(o.held)), U.itemName(o.item))
            end
        end
    end
    lines[#lines + 1] = tr("Admin_Wd_CancelWarn")
    return lines
end

-- { [currency] = amount } in the registry's order, nil when nothing was refunded.
function P.refundText(refunded)
    if type(refunded) ~= "table" then return nil end
    local out = nil
    for _, cid in ipairs(EC.CURRENCY_ORDER or {}) do
        if num(refunded[cid]) > 0 then
            local s = moneyText(refunded[cid], cid)
            out = out and (out .. tr("Admin_Set_ListSep") .. s) or s
        end
    end
    return out
end

local function payText(o)
    if o.kind == "coin" then
        return getText(T .. "Admin_Wd_PayCoin", U.amountText(num(o.unitPrice)), U.amountText(num(o.held)))
    end
    return getText(T .. "Admin_Wd_PayItem", U.itemName(o.item), tostring(num(o.perUnit)), tostring(num(o.held)))
end

local function reasonError(reason)
    if reason == "" then return tr("Admin_Wd_ReasonMissing") end
    if string.find(reason, "%c") then return tr("Admin_Error_reason_invalid") end
    if charCount(reason) > REASON_MAX then return tr("Admin_Error_reason_too_long") end
    return nil
end

local function errorText(code)
    return getTextOrNull(T .. "Admin_Wd_Error_" .. tostring(code)) or U.adminErrorText(code)
end

-- The box's text as the server is asked for it: trimmed, refused with a control character or
-- past the bound. nil = no condition; `bad` tells an empty box from an unusable one.
local function boxValue(box)
    local raw = trim(U.entryText(box))
    if raw == "" then return nil, false end
    if #raw > QUERY_MAX or string.find(raw, "%c") then return nil, true end
    return raw, false
end

-- ---------- the row ----------

local ACTIONS = nil
local function rowActions()
    if ACTIONS == nil then
        ACTIONS = { { id = "owner", label = tr("Admin_Wd_OwnerAction"), read = true },
            { id = "cancel", label = tr("Admin_Wd_Cancel"), danger = true } }
    end
    return ACTIONS
end

-- Every string, x and y is set by Page:rebuild; the cell only paints.
local Cell = ISPanel:derive("MinidoracatEconomyAdminWantedCell")

function Cell:render()
    local e = self.entry
    if not e then return end
    U.framework.Table.rowBackground(self)
    if e.icon and not pcall(self.drawTextureScaled, self, e.icon, PAD, e.y1, e.iconSize, e.iconSize, 1, 1, 1, 1) then
        e.icon = nil
    end
    text(self, e.nameText, e.nameX, e.y1, "text")
    if e.qtyText then text(self, e.qtyText, e.qtyX, e.y1, "textMuted") end
    U.drawPill(self, e.pillX, e.pillY, nil, e.statusText, e.statusToken, nil, true)
    for _, s in ipairs(e.segs) do
        if s.coin then U.drawCoin(self, s.coin, s.x, s.coinY, s.coinSize) end
        text(self, s.s, s.tx, e.y2, "text")
    end
    text(self, e.metaText, e.nameX, e.y3, "textFaint")
    local R = C.RowActions
    local write = self.list.optionsDisabled ~= true
    R.begin(self)
    for _, a in ipairs(e.actions) do
        R.put(self, a.id, a.label, a.x, a.y, a.w, a.h, a.read == true or write, a.danger and "danger" or nil)
    end
    R.finish(self)
end

-- ---------- the page ----------

local Page = ISPanel:derive("MinidoracatEconomyAdminWantedPage")

function Page:createChildren()
    self.searchEntry = U.newEntry(240, entryH(), { maxLen = QUERY_MAX, clear = true, placeholder = tr("Admin_Wd_Search") })
    self:addChild(self.searchEntry)
    self.ownerEntry = U.newEntry(200, entryH(), { maxLen = QUERY_MAX, clear = true, placeholder = tr("Admin_Wd_Owner") })
    self:addChild(self.ownerEntry)
    for _, box in ipairs({ self.searchEntry, self.ownerEntry }) do
        box.onCommandEntered = function() self:applyFilters() end
    end
    self.prevButton = U.Button.create(0, 0, 60, chipH(), tr("Market_Prev"), self, Page.onPage, "chip")
    self.prevButton.internal = -1
    self:addChild(self.prevButton)
    self.nextButton = U.Button.create(0, 0, 60, chipH(), tr("Market_Next"), self, Page.onPage, "chip")
    self.nextButton.internal = 1
    self:addChild(self.nextButton)
    self.list = U.newTable(Cell, lineH() * 3 + 12)
    self.list.onSelect = function(_, item) self:openDetail(item) end
    self.list.onRowAction = function(_, item, id) self:onRowAction(item, id) end
    self:addChild(self.list)
    self:layout()
end

function Page:say(s, isError)
    self.owner.message = { text = s, error = isError == true }
end

function Page:invalidateKeyboard()
    if C.Keyboard and C.Keyboard.invalidate then pcall(C.Keyboard.invalidate, self.owner.owner) end
end

-- ---------- conditions ----------

function Page:askKey()
    return tostring(self.query or "") .. "\1" .. tostring(self.ownerFilter or "") .. "\1" .. tostring(self.page)
end

function Page:applyFilters()
    self.queryAt = nil
    self.querySeen, self.ownerSeen = U.entryText(self.searchEntry), U.entryText(self.ownerEntry)
    local q, badQ = boxValue(self.searchEntry)
    local o, badO = boxValue(self.ownerEntry)
    if badQ or badO then
        self:say(tr("Admin_Accounts_QueryBad"), true)
        return
    end
    if q == self.query and o == self.ownerFilter then return end
    self.query, self.ownerFilter, self.page = q, o, 1
    self.owner.message = nil
    self:layout()
end

function Page:onPage(button)
    local target = math.max(1, math.min(math.max(1, self.pages or 1), (self.page or 1) + button.internal))
    if target == self.page then return end
    self.page = target
    self.owner.message = nil
    self:layout()
end

-- "This buyer": the owner box takes the row's account and the list asks for that account only.
function Page:filterOwner(name)
    if type(name) ~= "string" or name == "" then return end
    U.setEntryText(self.ownerEntry, name)
    self:applyFilters()
end

function Page:onRowAction(item, id)
    if item == nil then return end
    if id == "owner" then self:filterOwner(item.rec.owner)
    elseif id == "cancel" and self.list.optionsDisabled ~= true then self:openCancel(item) end
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

function Page:requestList()
    local args = { action = "list", page = self.page, query = self.query,
        types = (C.ItemPicker.queryTypes(self.query)), owner = self.ownerFilter }
    local key = self:askKey()
    if self:sendAction(args, { action = "list", key = key }) then
        self.sentKey, self.wantRead = key, false
        return true
    end
    return false
end

-- The controller cancelled a cooldown-held write before sending it: this is known, not a timeout.
function Page:onCancelled(requestId)
    local req = self.sent
    if req == nil or req.requestId ~= requestId or req.answered then return end
    req.answered = true
    self:say(tr("Admin_Error_forbidden"), true)
    self:layout()
end

-- Asked by the controller before it frees the shared slot; touches nothing.
function Page:matchesReply(args)
    local s = self.sent
    return type(args) == "table" and s ~= nil and not s.answered and args.requestId == s.requestId
end

function Page:onReply(args)
    local req = self.sent
    if not self:matchesReply(args) then return end
    req.answered = true
    if req.action == "list" then
        if args.ok ~= true then
            -- the right to read every buyer's orders is this page: a refusal for it drops them,
            -- and the question stays recorded so the next frame does not ask it again
            if args.error == "forbidden" then
                self:clear()
                self.sentKey = self:askKey()
            end
            self.readError = errorText(args.error)
            self:say(self.readError, true)
        elseif req.key == self:askKey() then
            self.rows = type(args.rows) == "table" and args.rows or {}
            self.total, self.pages = num(args.total), math.max(1, num(args.pages))
            self.page = math.max(1, num(args.page))
            self.stats = type(args.stats) == "table" and args.stats or nil
            self.sentKey = self:askKey()   -- the server clamped the page: adopt it, never re-ask
            self.readError, self.timedOut, self.updatedAt = nil, false, EC.now()
        end
        -- an answer to a condition the admin has moved off is dropped; tick asks the new one
    elseif req.action == "cancel" then
        if args.ok ~= true then
            self:say(errorText(args.error), true)
        else
            local refund = P.refundText(args.refunded)
            self:say(refund and getText(T .. "Admin_Wd_DoneRefund", req.ownerName, refund)
                or getText(T .. "Admin_Wd_Done", req.ownerName))
        end
        self.wantRead = true
    end
    self:layout()
    self:invalidateKeyboard()
end

-- A read is owed again on the next poll; a forced cancel has an unknown outcome and is never re-sent.
function Page:onTimeout()
    local req = self.sent
    if req == nil or req.answered then return end
    req.timedOut = true
    if req.action == "list" then
        self.timedOut = true
        self:say(tr("Admin_Wd_Timeout"), true)
    else
        self:say(tr("Admin_Wd_CancelTimeout"), true)
    end
    self:layout()
end

-- ---------- forced cancel ----------

function Page:closeDialog()
    local d = self.dialog
    self.dialog = nil
    local api = dialogApi()
    if d ~= nil and api then api.close(d, false) end
end

function Page:openCancel(row, problem)
    local api = dialogApi()
    if row == nil or api == nil then return end
    if not self.owner:writeAllowed() then
        self:say(tr("Admin_Error_forbidden"), true)
        return
    end
    local v = row.rec
    local lines = P.cancelLines(v)
    if problem ~= nil then table.insert(lines, 1, problem) end
    lines[#lines + 1] = ""
    lines[#lines + 1] = tr("Admin_Wd_Reason")
    local width = DIALOG_W
    if type(getCore) == "function" then width = math.min(DIALOG_W, getCore():getScreenWidth() - 40) end
    local dialog
    dialog = api.show({ title = getText(T .. "Admin_Wd_CancelTitle", U.itemName(v.item), tostring(v.owner)),
        text = table.concat(lines, "\n"), theme = U.theme, width = width,
        input = { placeholder = tr("Admin_Wd_ReasonHint") },
        confirmText = tr("Admin_Wd_Cancel"), cancelText = tr("Admin_Wd_Keep"), danger = true,
        onResult = function(ok, value) self:onCancelResult(dialog, row, ok, value) end })
    self.dialog = dialog
    self:updateEnabled()
end

function Page:onCancelResult(dialog, row, ok, value)
    if self.dialog == dialog then self.dialog = nil end
    if not ok then
        self:updateEnabled()
        return
    end
    local reason = trim(value)
    local bad = reasonError(reason)
    if bad ~= nil then
        self:openCancel(row, bad)
        return
    end
    if not self.owner:writeAllowed() then
        self:say(tr("Admin_Error_forbidden"), true)
        return
    end
    local v = row.rec
    local sent, why = self:sendAction({ action = "cancel", orderId = v.id, reason = reason },
        { action = "cancel", orderId = v.id, ownerName = tostring(v.owner) })
    if sent then self:say(tr("Admin_Wd_Sending")) else self:say(errorText(why), true) end
    self:layout()
end

-- ---------- the detail card ----------

function Page:detailOf(row)
    local v = row.rec
    local now = EC.now()
    local status, token = P.statusText(v, now)
    local rows, lines, out = {}, {}, {}
    local function add(label, value)
        rows[#rows + 1] = { label = label, value = value }
        out[#out + 1] = label .. ": " .. value
    end
    add(tr("Admin_Wd_Col_Owner"), tostring(v.owner))
    add(tr("Admin_Wd_Col_Qty"), getText(T .. "Admin_Wd_Qty", tostring(num(v.qty)), tostring(num(v.qtyTotal))))
    add(tr("Admin_Wd_Col_Cond"), P.condText(v.cond))
    add(tr("Admin_Wd_Col_Created"), U.stampText(tonumber(v.at), self.owner.offsetMin))
    add(tr("Market_Col_Expires"), U.stampText(tonumber(v.expiresAt), self.owner.offsetMin))
    add(tr("Admin_Wd_Col_Offers"), tostring(num(v.offerCount)))
    for _, o in ipairs(options(v)) do
        if type(o) == "table" then
            local s = payText(o)
            if o.kind == "coin" then s = U.currencyName(o.currency) .. " " .. s end
            local fee = o.kind == "coin" and num(o.fee) > 0 and getText(T .. "Admin_Wd_PayFee", U.amountText(num(o.fee))) or nil
            lines[#lines + 1] = { text = s, note = fee }
            out[#out + 1] = s .. (fee and ("  " .. fee) or "")
        end
    end
    local id = row.id
    local card = {
        source = tr("Admin_Wd_Detail"), sourceIcon = "market", item = v.item, iconKey = "market",
        name = U.itemName(v.item), sub = getText(T .. "Admin_Wd_Qty", tostring(num(v.qty)), tostring(num(v.qtyTotal))),
        chips = { { value = status, token = token, dot = true } },
        rows = rows,
        sections = { { title = tr("Admin_Wd_Col_Pay"), lines = lines } },
        tech = { { label = tr("Detail_ItemCode"), value = tostring(v.item) }, { label = tr("Admin_Wd_Col_Id"), value = tostring(id) } },
        techOpen = true,
        actions = {
            { id = "owner", label = tr("Admin_Wd_OwnerAction"), run = function() self:cardAction(id, "owner") end },
            { id = "cancel", label = tr("Admin_Wd_Cancel"), style = "danger",
                enabled = function() return self.list.optionsDisabled ~= true end,
                run = function() self:cardAction(id, "cancel") end },
        },
    }
    return U.itemName(v.item), table.concat(out, "\n"), card
end

function Page:rowById(id)
    for _, r in ipairs(self.rowItems or {}) do
        if r.id == id then return r end
    end
    return nil
end

-- The card's buttons are the row's own: found again by id, nothing when the row is gone.
function Page:cardAction(id, action)
    local row = self:rowById(id)
    if row ~= nil then self:onRowAction(row, action) end
end

function Page:openDetail(row)
    if row == nil then return end
    self.detailId = row.id
    local title, body, card = self:detailOf(row)
    C.DetailWindow.open(self, "wanted:" .. tostring(row.id), title, body, function() self.detailId = nil end, card)
end

-- a fresh read keeps the open card current; a row that is gone takes its card with it
function Page:refreshDetail()
    if self.detailId == nil then return end
    local row = self:rowById(self.detailId)
    if row == nil then
        self.detailId = nil
        C.DetailWindow.close(self)
        return
    end
    local title, body, card = self:detailOf(row)
    C.DetailWindow.update(self, "wanted:" .. tostring(row.id), title, body, card)
end

-- ---------- rows (data or geometry changes only) ----------

function Page:rebuild()
    local list = self.list
    local width = math.max(160, list.width - 12)   -- 12 = the scrollbar gutter
    local lh = lineH()
    local y1 = math.floor((list.rowHeight - lh * 3) / 2) + 3
    local ch = chipH()
    local ay = math.floor((list.rowHeight - ch) / 2)
    -- the two buttons, right to left
    local actions, ax = {}, width - PAD
    local defs = rowActions()
    for i = #defs, 1, -1 do
        local a = defs[i]
        local w = textWidth(a.label) + 20
        ax = ax - w
        actions[i] = { id = a.id, label = a.label, read = a.read, danger = a.danger, x = ax, y = ay, w = w, h = ch }
        ax = ax - 6
    end
    local limit = ax - PAD
    local iconSize = math.min(28, lh * 2)
    local nameX = PAD + iconSize + 6
    local coinSize = math.max(12, math.min(20, fontH.small + 2))
    local now = EC.now()
    local rows = {}
    for _, v in ipairs(self.rows or {}) do
        if type(v) == "table" and v.id ~= nil then
            local status, token = P.statusText(v, now)
            local pillW = U.pillWidth(nil, status, nil, true)
            local e = { id = v.id, rec = v, actions = actions, y1 = y1, y2 = y1 + lh, y3 = y1 + lh * 2,
                icon = U.itemTexture(v.item), iconSize = iconSize, nameX = nameX,
                statusText = status, statusToken = token, pillX = math.max(nameX, limit - pillW),
                pillY = y1 - math.floor((U.CHIP_H - fontH.small) / 2) }
            local qty = getText(T .. "Admin_Wd_Qty", tostring(num(v.qty)), tostring(num(v.qtyTotal)))
            local qtyW = textWidth(qty)
            local nameRoom = math.max(20, e.pillX - 8 - nameX - qtyW - PAD)
            e.nameText = fitText(U.itemName(v.item), nameRoom)
            e.qtyX = nameX + textWidth(e.nameText) + PAD
            e.qtyText = e.qtyX + qtyW <= e.pillX - 8 and qty or nil
            -- payment options left to right; what does not fit is counted, never cut mid-number
            local segs, x, opts = {}, nameX, options(v)
            for i, o in ipairs(opts) do
                if type(o) == "table" then
                    local s = payText(o)
                    local coin = o.kind == "coin" and o.currency or nil
                    local w = textWidth(s) + (coin and coinSize + 4 or 0)
                    local more = i < #opts and textWidth("+" .. tostring(#opts - i)) + 12 or 0
                    if x + w + more > limit then
                        segs[#segs + 1] = { s = "+" .. tostring(#opts - i + 1), tx = x }
                        break
                    end
                    segs[#segs + 1] = { s = s, coin = coin, x = x, coinSize = coinSize,
                        coinY = e.y2 + math.floor((fontH.small - coinSize) / 2), tx = coin and (x + coinSize + 4) or x }
                    x = x + w + 12
                end
            end
            e.segs = segs
            local ends = (tonumber(v.expiresAt) or 0) - now
            local meta = tostring(v.owner) .. " / " .. P.condText(v.cond) .. " / "
                .. (ends > 0 and getText(T .. "Auction_Ends_In", U.remainText(ends)) or tr("Admin_Wd_Status_expired"))
                .. " / " .. getText(T .. "Admin_Wd_Offers", tostring(num(v.offerCount)))
            e.metaText = fitText(meta, math.max(0, limit - nameX))
            rows[#rows + 1] = e
        end
    end
    self.rowItems = rows
    local sel = list:getSelectedItem()
    list:setItems(rows)
    for i, r in ipairs(rows) do
        if sel ~= nil and r.id == sel.id then list:setSelectedIndex(i) end
    end
    self:refreshDetail()
end

-- ---------- geometry ----------

function Page:summaryText()
    if self.rows == nil then return nil end
    local st = self.stats or {}
    return getText(T .. "Admin_Wd_Summary", tostring(self.total or 0), tostring(self.page or 1),
        tostring(self.pages or 1), tostring(num(st.orders)), tostring(num(st.max)))
end

function Page:statusLine()
    if self.readError then return self.readError, "errorText" end
    if self.timedOut and self.rows == nil then return tr("Admin_Wd_Timeout"), "errorText" end
    if self.rows == nil then return tr("Admin_Loading"), "textFaint" end
    if #(self.rowItems or {}) == 0 then return tr("Admin_Wd_Empty"), "textFaint" end
    return nil
end

function Page:layout()
    if self.list == nil then return end
    local w, h = self.width, self.height
    local eh, ch = entryH(), chipH()
    local on = self:getIsVisible()
    local g = {}
    self.g = g
    local top = CARD_TITLE_H + 4
    local sw = math.max(120, math.min(280, math.floor(w * 0.32)))
    local ow = math.max(100, math.min(220, math.floor(w * 0.25)))
    for _, box in ipairs({ self.searchEntry, self.ownerEntry }) do
        if not on then pcall(box.unfocus, box) end
        box:setVisible(on)
        box:setY(top); box:setHeight(eh)
    end
    self.searchEntry:setX(PAD); self.searchEntry:setWidth(sw)
    self.ownerEntry:setX(PAD + sw + 6); self.ownerEntry:setWidth(ow)

    local rowY = top + eh + 6
    local nextW = math.min(textWidth(self.nextButton.fullTitle) + 24, math.floor(w * 0.2))
    local prevW = math.min(textWidth(self.prevButton.fullTitle) + 24, math.floor(w * 0.2))
    self.nextButton:setVisible(on)
    self.nextButton:setWidth(nextW); self.nextButton:setHeight(ch)
    self.nextButton:setX(math.max(PAD, w - PAD - nextW)); self.nextButton:setY(rowY)
    U.setButtonTitle(self.nextButton, self.nextButton.fullTitle)
    self.prevButton:setVisible(on)
    self.prevButton:setWidth(prevW); self.prevButton:setHeight(ch)
    self.prevButton:setX(math.max(PAD, self.nextButton.x - 6 - prevW)); self.prevButton:setY(rowY)
    U.setButtonTitle(self.prevButton, self.prevButton.fullTitle)
    g.summaryY = rowY + math.floor((ch - fontH.small) / 2)
    g.summaryW = math.max(0, self.prevButton.x - PAD * 2)

    local listY = rowY + ch + 4
    g.emptyY = listY + 4
    U.placeList(self.list, on, PAD, listY, math.max(160, w - PAD * 2), math.max(lineH(), h - PAD - listY))
    self:rebuild()
    self:updateEnabled()
end

function Page:updateEnabled()
    if self.list == nil then return end
    local read = self.owner:readAllowed()
    local write = read and self.owner:writeAllowed()
    local modal = self.owner.dialog ~= nil or self.dialog ~= nil
    local busy = self.isPending(COMMAND)
    U.setEntryEditable(self.searchEntry, read and not modal)
    U.setEntryEditable(self.ownerEntry, read and not modal)
    self.prevButton:setEnable(read and not modal and not busy and (self.page or 1) > 1)
    self.nextButton:setEnable(read and not modal and not busy and (self.page or 1) < (self.pages or 1))
    -- the read-only role sees the cancel button, disabled
    self.list.optionsDisabled = not (write and not modal and not busy)
end

function Page:keyboardTargets()
    if self.list == nil or not self:getIsVisible() then return {} end
    local out = {
        { kind = "entry", label = tr("Admin_Wd_Search"), control = self.searchEntry },
        { kind = "entry", label = tr("Admin_Wd_Owner"), control = self.ownerEntry },
        { kind = "group", label = tr("Filter_PageNav"), controls = { self.prevButton, self.nextButton } },
        { kind = "list", label = tr("Admin_Wd_Title"), control = self.list },
    }
    local actions = C.RowActions.targets(self.list)
    if #actions > 0 then out[#out + 1] = { kind = "group", label = tr("Admin_Wd_RowActions"), controls = actions } end
    return out
end

-- The cancel dialog is the framework's own modal root; while it is up the controller refuses a
-- tab switch.
function Page:isModal() return self.dialog ~= nil end
function Page:onEscape() return false end

function Page:prerender()
    local g = self.g
    if g == nil then return end
    U.card(self, 0, 0, self.width, self.height, tr("Admin_Wd_Title"))
    local summary = self:summaryText()
    if summary then text(self, fitText(summary, g.summaryW), PAD, g.summaryY, "textFaint") end
    local s, token = self:statusLine()
    if s then text(self, fitText(s, math.max(0, self.width - PAD * 2)), PAD * 2, g.emptyY, token) end
end

function Page:render() end

-- ---------- lifecycle ----------

function Page:resize(width, height)
    if self.width ~= width then self:setWidth(width) end
    if self.height ~= height then self:setHeight(height) end
    self:layout()
end

-- Hiding keeps every snapshot; it takes the keyboard out of the boxes and drops an open dialog
-- (nothing was sent from it) and the detail card.
function Page:setVisible(visible)
    local was = self:getIsVisible()
    ISPanel.setVisible(self, visible)
    if self.list == nil then return end
    if not visible then
        pcall(self.searchEntry.unfocus, self.searchEntry)
        pcall(self.ownerEntry.unfocus, self.ownerEntry)
        self:closeDialog()
        C.DetailWindow.close(self)
    end
    if was ~= visible then self:layout() end
end

function Page:refresh()
    self.wantRead = true
    self:tick(EC.now())
end

-- The controller's frame callback is this page's whole clock: the boxes' pause, then the read
-- that is owed (a refresh, a changed condition, one the cooldown or a write in flight held back).
function Page:tick(now)
    if self.list == nil then return end
    if self.queryAt == nil and (U.entryText(self.searchEntry) ~= self.querySeen
        or U.entryText(self.ownerEntry) ~= self.ownerSeen) then
        self.queryAt = now
    end
    if self.queryAt ~= nil and now - self.queryAt > DEBOUNCE_MS then self:applyFilters() end
    if not self.owner:readAllowed() or self.isPending(COMMAND) then return end
    if self.wantRead or self.sentKey ~= self:askKey() then self:requestList() end
end

-- The permission collapse: everything this page learned goes; nothing is sent.
function Page:clear()
    if self.list == nil then return end
    self:closeDialog()
    C.DetailWindow.close(self)
    self.rows, self.rowItems, self.stats, self.total, self.pages = nil, nil, nil, nil, nil
    self.page, self.sent, self.sentKey, self.wantRead = 1, nil, nil, false
    self.readError, self.timedOut, self.updatedAt, self.detailId = nil, false, nil, nil
    self.list:setItems({})
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
    o.page = 1
    o.querySeen, o.ownerSeen = "", ""
    o:initialise()
    o:instantiate()
    o:setVisible(false)
    return o
end

return P
