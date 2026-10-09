-- MinidoracatEconomyFor42 - the wallet's "slots" mode (client). Adds exactly one namespace:
-- C.PanelEntitlements.
--
-- The wallet card has two modes (statement | slots). The slots mode lists every product this login
-- holds slots in, read at once through C.Entitlements.requestList (entitlement.list; rows are per
-- login name, never merged across the account's other characters). Like ECPanelShopMail these are
-- the window's own methods: ECPanel binds request / rebuild, ECPanelLayout calls layout / draw, so
-- `self` is the window. No control is created here and no event is registered.
--
-- One list, one row height, four kinds of row per product:
--   product   name and source mod            pills   usable / outright / rented as pills
--   rental    one per rental, its auto-renew  order   time, content, amount, status
-- A product, pills or rental row opens the product's card (Panel:onDetailRow "ent"); an order row
-- opens the order's (refund amount and time; order and transaction ids behind the collapsed
-- technical info). Cards: ECPanelCards K.entitlement.

require "ISUI/ISPanel"
if not MinidoracatEconomy or not MinidoracatEconomy.Client or not MinidoracatEconomy.Client.UI then
    require "MinidoracatEconomy/ECWidgets"
end

local EC = MinidoracatEconomy
local C = EC.Client
local U = C.UI

local M = {}
C.PanelEntitlements = M

local PAD, ROW, CHIP_H, COIN_SMALL, T = U.PAD, U.ROW, U.CHIP_H, U.COIN_SMALL, U.T
local fontH = U.fontH
local fill, text, textWidth, fitText, textRight, drawCoin = U.fill, U.text, U.textWidth, U.fitText, U.textRight, U.drawCoin

local function Ent() return C.Entitlements end
local function tr(key, ...) return getText(T .. key, ...) end
local function num(v) return tostring(tonumber(v) or 0) end

function M.rowHeight() return math.max(ROW, fontH.small + 8, CHIP_H + 4) end

-- ---------- rows (built once per read, never per frame) ----------

local function addProduct(rows, env, now, offsetMin)
    local E = Ent()
    local id = tostring(env.sourceMod) .. "/" .. tostring(env.productId)
    local ent = type(env.entitlement) == "table" and env.entitlement or {}
    local name, source = E.productName(env), E.sourceName(env)
    rows[#rows + 1] = { kind = "product", id = id, env = env, name = name, source = source }
    rows[#rows + 1] = { kind = "pills", id = id, env = env, usable = num(ent.usable), permanent = num(ent.permanent),
        rental = num(ent.rental) }
    for i, r in ipairs(type(ent.rentals) == "table" and ent.rentals or {}) do
        if type(r) == "table" then
            local tag, token = E.autoTag(r, env.plan, ent)
            rows[#rows + 1] = { kind = "rental", id = id, env = env, text = E.rentalLine(i, r, now, offsetMin),
                tag = tag, tagToken = token }
        end
    end
    for _, o in ipairs(type(env.orders) == "table" and env.orders or {}) do
        if type(o) == "table" then
            rows[#rows + 1] = { kind = "order", id = id .. "/" .. tostring(o.orderId), env = env, order = o,
                time = U.stampText(tonumber(o.at), offsetMin), content = E.contentText(o),
                amount = U.signedText(-(tonumber(o.amount) or 0)), currency = o.currency,
                status = E.statusText(o, env.instant), refunded = o.status == "refunded" }
        end
    end
end

-- The list as the facade holds it now: the rows, the error of the last read (kept beside the old
-- rows, which the paint marks as older), and whether the server cut the list.
function M.rebuild(self)
    local E = Ent()
    local list, err = nil, "unknown"
    if E ~= nil then list, err = E.getList() end
    local rows, products, now = {}, 0, EC.now()
    for _, env in ipairs(list and list.entries or {}) do
        products = products + 1
        addProduct(rows, env, now, self.offsetMin)
    end
    self.entError, self.entLoaded = err, list ~= nil
    self.entMore, self.entProducts = list ~= nil and list.more == true, products
    -- the order columns measure what is listed (CN / JP digits are not all the same width)
    local cols = self.entList.cols
    cols.timeW, cols.amountW, cols.statusW = textWidth(U.STAMP_SAMPLE), 0, 0
    for _, r in ipairs(rows) do
        if r.kind == "order" then
            cols.timeW = math.max(cols.timeW, textWidth(r.time))
            cols.amountW = math.max(cols.amountW, textWidth(r.amount))
            cols.statusW = math.max(cols.statusW, textWidth(r.status))
        end
    end
    self.entRows = rows
    self.entList:setItems(rows)
end

-- One read of every product (the facade's own lane: 650 ms gate, one in flight, the queued read
-- shared). Whatever comes back -- a list, a refusal, a timeout -- is rebuilt and laid out.
function M.request(self)
    local E = Ent()
    if E == nil then return end
    self.entError = nil
    self.entPending = (self.entPending or 0) + 1
    local id = E.requestList(function()
        self.entPending = math.max(0, (self.entPending or 1) - 1)
        M.rebuild(self)
        if self.g then self:layout() end
    end)
    if id == nil then
        self.entPending = math.max(0, self.entPending - 1)
        self.entError = "queue_full"
    end
end

-- ---------- geometry ----------

-- The wallet's mode tabs sit in the card's title row (the tab names the card); the balance view
-- keeps its own title instead. The slots list takes the card body and leaves the note row (and the
-- shared retry chip) under it.
function M.layout(self, isWallet, entMode, balances, x, w, top, bottom, open, watch)
    local g = self.g
    local tabs = self.walletTabs
    tabs:setVisible(isWallet and not balances and open)
    tabs:setX(g.bodyX + PAD)
    tabs:setY(g.contentY + math.floor((g.walletHeaderH - tabs.height) / 2))
    g.walletEnt = entMode
    local list = self.entList
    list:setVisible(entMode and open)
    if not entMode then return end
    local lineH = list.rowHeight
    local h = math.max(lineH, bottom - top - lineH - 2)
    list:setX(x); list:setY(top)
    list.ecChromeH = top - g.contentY + lineH
    if list.width ~= w or list.height ~= h then list:resize(w, h) end
    local cols = list.cols
    local inner = w - 12
    cols.w = inner
    cols.content = PAD + (cols.timeW or 0) + PAD
    cols.statusX = inner - PAD - (cols.statusW or 0)
    cols.amountR = cols.statusX - PAD
    cols.contentW = math.max(0, cols.amountR - (cols.amountW or 0) - COIN_SMALL - PAD * 2 - cols.content)
    g.walletNoteY = top + h + 2
    watch[#watch + 1] = { kind = "ent", list = list }
end

-- ---------- paint ----------

-- The note under the list, most urgent first: a failed read (over older rows: marked as older),
-- the first read on its way, nothing held at all (the empty state over the list), a cut list.
function M.draw(self)
    local g = self.g
    local list = self.entList
    local retryB = self.historyRetryButton
    local noteW = math.max(0, (retryB:getIsVisible() and retryB.x - 6 or list.x + list.width) - list.x - PAD)
    local note, token = nil, "textMuted"
    if self.entError then
        note, token = Ent().errorText(self.entError), "errorText"
        if self.entLoaded then note = note .. "  " .. tr("History_Stale") end
    elseif not self.entLoaded then
        note = tr("Wallet_Loading")
    elseif #(self.entRows or {}) == 0 then
        U.emptyState(self, "ent", list.x, list.y, list.width, list.height, tr("Wallet_Empty"), tr("Ent_WalletEmpty"))
        U.drawEmptyState(self, "ent")
    elseif self.entMore then
        note = tr("Ent_WalletMore", tostring(self.entProducts or 0))
    end
    if note then
        text(self, fitText(note, noteW), list.x + PAD, g.walletNoteY + math.floor((list.rowHeight - fontH.small) / 2), token)
    end
end

local EntCell = ISPanel:derive("MinidoracatEconomyEntitlementCell")
M.EntCell = EntCell

-- The fitted texts are kept per row and column width, so a frame only paints.
function EntCell:render()
    local e = self.entry
    if not e then return end
    local cols = self.list.cols
    local h = self.height
    local lit = U.framework.Table.rowBackground(self)
    local ty = math.floor((h - fontH.small) / 2)
    local muted = lit and "text" or "textMuted"
    if self.fitEntry ~= e or self.fitW ~= cols.w or self.fitContent ~= cols.contentW then
        self.fitEntry, self.fitW, self.fitContent = e, cols.w, cols.contentW
        local w = cols.w or self.width
        if e.kind == "product" then
            self.fitA = fitText(e.name, math.floor(w * 0.6), UIFont.Medium)
            self.fitB = fitText(e.source, w - PAD * 3 - textWidth(self.fitA, UIFont.Medium))
        elseif e.kind == "rental" then
            self.fitB = fitText(e.tag, math.floor(w * 0.4))
            self.fitA = fitText(e.text, w - PAD * 4 - textWidth(self.fitB))
        elseif e.kind == "order" then
            self.fitA = fitText(e.content, cols.contentW or 0)
        end
    end
    if e.kind == "product" then
        fill(self, 0, 0, self.width, 1, "border")
        text(self, self.fitA, PAD, math.floor((h - fontH.medium) / 2), "text", UIFont.Medium)
        text(self, self.fitB, PAD * 2 + textWidth(self.fitA, UIFont.Medium), ty, muted)
    elseif e.kind == "pills" then
        local py = math.floor((h - CHIP_H) / 2)
        local x = PAD
        x = x + U.drawPill(self, x, py, tr("Ent_PillUsable"), e.usable) + 6
        x = x + U.drawPill(self, x, py, tr("Ent_Kind_permanent"), e.permanent) + 6
        U.drawPill(self, x, py, tr("Ent_Kind_rental"), e.rental)
    elseif e.kind == "rental" then
        text(self, self.fitA, PAD * 2, ty, lit and "text" or "textMuted")
        textRight(self, self.fitB, (cols.w or self.width) - PAD, ty, lit and "text" or e.tagToken)
    else
        text(self, e.time, PAD, ty, muted)
        text(self, self.fitA, cols.content, ty, "text")
        local amountToken = e.refunded and muted or (lit and "text" or "negative")
        textRight(self, e.amount, cols.amountR, ty, amountToken)
        drawCoin(self, e.currency, cols.amountR - textWidth(e.amount) - COIN_SMALL - 4,
            math.floor((h - COIN_SMALL) / 2), COIN_SMALL)
        text(self, e.status, cols.statusX, ty, e.refunded and (lit and "text" or "warn") or muted)
    end
end

-- ---------- the copy text of a row's record (Panel:detailText "ent") ----------

function M.detailText(e, detailLine, offsetMin)
    local E = Ent()
    local env = e.env
    local out = { E.productName(env), E.sourceName(env) }
    if e.kind ~= "order" then
        local ent = type(env.entitlement) == "table" and env.entitlement or {}
        local rentals = type(ent.rentals) == "table" and ent.rentals or {}
        out[#out + 1] = tr("Ent_Summary", num(ent.usable), num(ent.permanent), num(ent.rental), tostring(#rentals))
        local now = EC.now()
        for i, r in ipairs(rentals) do
            if type(r) == "table" then
                out[#out + 1] = tr("Ent_Pair", E.rentalLine(i, r, now, offsetMin), (E.autoTag(r, env.plan, ent)))
            end
        end
        return out
    end
    local o = e.order
    out[#out + 1] = detailLine("Ent_Col_Content", e.content)
    out[#out + 1] = detailLine("Ent_Col_Time", e.time)
    out[#out + 1] = detailLine("Ent_Col_Amount", e.amount .. " " .. C.currencyName(o.currency))
    out[#out + 1] = detailLine("Ent_Col_Status", e.status)
    local rf = type(o.refund) == "table" and o.refund or nil
    if rf then
        out[#out + 1] = detailLine("Ent_RefundTitle", U.amountText(tonumber(rf.amount) or 0) .. " "
            .. C.currencyName(o.currency) .. "  " .. U.stampText(tonumber(rf.at), offsetMin))
    end
    out[#out + 1] = detailLine("Ent_OrderId", tostring(o.orderId))
    if o.txId then out[#out + 1] = detailLine("Detail_TxId", tostring(o.txId)) end
    if rf and rf.txId then out[#out + 1] = detailLine("Ent_RefundTxId", tostring(rf.txId)) end
    return out
end

return M
