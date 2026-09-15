-- MinidoracatEconomyFor42 — Economy Center modal dialogs (client). The two panels the player
-- pages add over themselves: the shop buy / sell dialog, and the one market / auction dialog
-- that carries every step of both trade pages (purchase, cancel, backpack picker, pricing,
-- bid, create). Both are plain child panels of the window: the window owns them, sizes them
-- against the band it gave them (Panel:layoutDialog) and confirms them through its own
-- submitBuy / submitSell / submitMarket / submitAuction. Nothing here reaches for C.Panel.
--
-- Controls, row builders and the reader / summary helpers come from the page toolkit
-- (ECPanelWidgets), the drawing and formatting primitives from ECWidgets — no copies here.

require "ISUI/ISPanel"

if not MinidoracatEconomy or not MinidoracatEconomy.Client or not MinidoracatEconomy.Client.UI then
    require "MinidoracatEconomy/ECWidgets"
end
require "MinidoracatEconomy/ECKeyboard"
require "MinidoracatEconomy/ECPanelWidgets"

local EC = MinidoracatEconomy
local C = EC.Client
local U = C.UI
local W = C.PanelWidgets
local Keys = C.Keyboard

local D = {}
C.PanelDialogs = D

local PAD, CHIP_H, T = U.PAD, U.CHIP_H, U.T
local fontH = U.fontH
local Button = U.Button
local fill, border, text, textWidth, fitText, textRight, textCentre = U.fill, U.border, U.text, U.textWidth, U.fitText, U.textRight, U.textCentre
local amountText = U.amountText
local entryText = U.entryText
local ITEM_ICON = W.ITEM_ICON
local newEntry, detailLine, readerHeight = W.newEntry, W.detailLine, W.readerHeight
local newReader, capacityLines = U.newReader, W.capacityLines
local setSummary, summaryMoved, placeField, drawIcon = W.setSummary, W.summaryMoved, W.placeField, W.drawIcon
local ceilPercent, listingFee = W.ceilPercent, W.listingFee
local tileSize, gridCandidate, CandidateCell = W.tileSize, W.gridCandidate, W.CandidateCell
local currencyIds, currencyLabel, moneyText = W.currencyIds, W.currencyLabel, W.moneyText

-- A cap or a remaining allowance the server did not send is unknown, never zero.
local function amountOrDash(value)
    local n = tonumber(value)
    return n and amountText(n) or getText(T .. "Shop_NoQuote")
end

-- This sku's quote in one currency, out of the row's own quote list (shopRow built it from
-- sku.prices). nil means this currency is simply not offered for it.
local function shopQuote(row, currency)
    for _, q in ipairs((row and row.quotes) or {}) do
        if q.currency == currency then return q end
    end
    return nil
end

-- Whether the shop buys this currency back at all right now: the server-wide switch and this
-- currency's own cap block, straight from the snapshot (never inferred from a price).
local function buybackRoom(currency)
    local bb = C.shop and C.shop.buyback
    if type(bb) ~= "table" then return nil end
    local by = type(bb.byCurrency) == "table" and bb.byCurrency[currency] or nil
    if bb.enabled ~= true or by == nil or by.enabled ~= true then return nil end
    return by
end

-- One chip per registered currency, built once and shown only where the step offers a choice.
local function newCurrencyChips(owner, onClick)
    local out = {}
    for i, id in ipairs(currencyIds()) do
        local title = currencyLabel(id)
        local b = Button.create(0, 0, textWidth(title) + 22, math.max(CHIP_H, fontH.small + 10),
            title, owner, onClick, "chip")
        b.internal = id
        b.fullTitle = title
        b.coinId = id
        b:setVisible(false)
        owner:addChild(b)
        out[i] = b
    end
    return out
end

-- The chips this step may offer, laid out as one wrapped row under `y`; returns the y below it.
local function placeChips(buttons, x, y, right, gap)
    local cx, cy = x, y
    local h = buttons[1] and buttons[1].height or CHIP_H
    for _, b in ipairs(buttons) do
        if b:getIsVisible() then
            if cx > x and cx + b.width > right then cx = x; cy = cy + h + 4 end
            b:setX(cx); b:setY(cy)
            cx = cx + b.width + 6
        end
    end
    return cy + h + (gap or 0)
end

-- How tall that wrapped row becomes inside `width`, measured before anything is placed.
local function chipsHeight(buttons, x, right)
    local cx, rows = x, 0
    local h = buttons[1] and buttons[1].height or CHIP_H
    for _, b in ipairs(buttons) do
        if b:getIsVisible() then
            if rows == 0 then rows = 1 end
            if cx > x and cx + b.width > right then cx = x; rows = rows + 1 end
            cx = cx + b.width + 6
        end
    end
    if rows == 0 then return 0 end
    return rows * h + (rows - 1) * 4
end


-- ---------- buy dialog ----------
-- Same shape as the admin write dialog (ECAdminPanel Dialog): a panel added to the window,
-- centred over the band the window gave it, swallowing the clicks of the page underneath. Head,
-- one scrolling reader, the count stepper, the buttons -- the reader is what gives way when the
-- font grows, so the trade never runs past the window.
local BuyDialog = ISPanel:derive("MinidoracatEconomyBuyDialog")

function BuyDialog:createChildren()
    local step = math.max(CHIP_H, fontH.medium + 8)
    self.minusButton = Button.create(0, 0, step + 6, step, "-", self, BuyDialog.onStep, "chip")
    self.minusButton.internal = -1
    self:addChild(self.minusButton)
    self.plusButton = Button.create(0, 0, step + 6, step, "+", self, BuyDialog.onStep, "chip")
    self.plusButton.internal = 1
    self:addChild(self.plusButton)
    local buy = getText(T .. (self.sell and "Shop_SellConfirm" or "Shop_Buy"))
    local bh = math.max(28, fontH.medium + 10)
    self.confirmButton = Button.create(0, 0, math.max(120, textWidth(buy, UIFont.Medium) + 40), bh, buy, self, BuyDialog.onConfirm, "primary")
    self.confirmButton.font = UIFont.Medium
    self:addChild(self.confirmButton)
    local cancel = getText(T .. "Admin_Cancel")
    self.cancelButton = Button.create(0, 0, textWidth(cancel) + 30, bh, cancel, self, BuyDialog.onCancel, "chip")
    self:addChild(self.cancelButton)
    -- The currency of this one order. The player picks it here every time: nothing carries a
    -- choice over from another order, and no page silently spends the wallet the sku happens
    -- to be cheapest in.
    self.currencyButtons = newCurrencyChips(self, BuyDialog.onCurrency)
    -- every value of the trade, scrolling: a 1000x560 window at the largest UI font has no room
    -- to stack them as lines, and none of them may be cut
    self.summaryBox = newReader(self, 240, fontH.small * 2 + 12)
end

-- This sku's quote in the currency the order is being made in.
function BuyDialog:quote()
    return shopQuote(self.row, self.currency)
end

-- What one lot costs in the chosen currency, or nil when this sku has no such quote at all.
-- nil is not zero: the confirm stays closed and the summary says the currency is not offered.
function BuyDialog:unitPrice()
    local q = self:quote()
    if q == nil or q.enabled ~= true then return nil end
    return q.price
end

-- What one lot is bought back for. The candidate reply is the server's own quote for the very
-- currency this dialog asked about, so it wins over the catalog row it was opened from.
function BuyDialog:unitBid()
    local c = self.cand
    if c ~= nil and c.currency == self.currency and tonumber(c.bidPrice) then
        return math.floor(tonumber(c.bidPrice))
    end
    local q = self:quote()
    if q == nil or q.buyback ~= true then return nil end
    return q.bidPrice
end

-- The currencies this order may be made in: the ones the sku is really quoted in, and for a
-- sale the ones the shop is buying back in right now.
function BuyDialog:offers(id)
    local q = shopQuote(self.row, id)
    if q == nil then return false end
    if self.sell then return q.buyback == true and q.bidPrice ~= nil and buybackRoom(id) ~= nil end
    return q.enabled == true and q.price ~= nil
end

-- An order already on the wire owns this dialog: until the server answers it (or the write
-- times out) the currency, the count, the consent and the revision it was sent with stay
-- exactly as they were sent. Both the mouse and the keyboard land here, so one guard covers
-- both -- the chips are painted disabled as well, but a handler must never rely on that.
function BuyDialog:frozen()
    return self.panel.buyPending ~= nil
end

-- How many lots the player asked for is their own decision, not a side effect of the wallet
-- they pay from: a currency change keeps it. It is only cut when the new currency really
-- allows less, and then the step says so and has to be confirmed again -- never silently.
-- While the allowance is unknown (a sale waiting for its candidates) nothing is cut at all:
-- the confirm simply stays shut until the server has quoted that currency.
function BuyDialog:clampCount()
    local max = self:maxCount()
    if max < 1 or self.count <= max then return end
    self.count = max
    self.requoteRequired = true
    self.message = getText(T .. "Trade_CountClamped", tostring(max))
end

function BuyDialog:onCurrency(button)
    if self:frozen() or self.currency == button.internal then return end
    self.currency = button.internal
    for _, b in ipairs(self.currencyButtons) do b.active = b.internal == self.currency end
    self.message = nil
    self.mailRequired = nil       -- a consent belongs to one order, not to the dialog
    self.requoteRequired = nil
    if self.sell then
        -- what the backpack is worth is quoted per currency: this is a different question, and
        -- the new caps are not known until it is answered. The count is kept meanwhile.
        self.cand = nil
        self.panel:sendSellCandidates(self)
    else
        -- a purchase share is counted per sku, not per currency, so this usually changes
        -- nothing at all
        self:clampCount()
    end
    self.panel:layoutBuy()
end

-- What this sale still has room for, in the currency it is paid in. The candidate reply states
-- the two money allowances at its top level and the shared unit quota inside its buyback view;
-- an allowance the server did not send is unknown, and unknown is never read as zero.
local function sellRoom(cand, currency)
    if type(cand) ~= "table" then return {} end
    local bb = type(cand.buyback) == "table" and cand.buyback or {}
    local byCurrency = type(bb.byCurrency) == "table" and bb.byCurrency[currency] or nil
    return {
        account = tonumber(cand.accountRemaining)
            or (byCurrency and tonumber(byCurrency.accountRemaining)) or nil,
        server = tonumber(cand.serverRemaining)
            or (byCurrency and tonumber(byCurrency.serverRemaining)) or nil,
        sku = tonumber(bb.skuRemaining),
    }
end

-- Lots per purchase: the server cap, and never more than the share the sku has left -- a share
-- that has run out is 0 lots, not one, whichever of the three cap modes counts it. Selling:
-- whole SKU units the backpack holds, within every remaining cap the server reported (units for
-- the SKU, coins for the account and the server); 0 when there is nothing to sell.
function BuyDialog:maxCount()
    local max = math.max(1, tonumber(C.shop and C.shop.countMax) or 1)
    local row = self.row
    if self.sell then
        local c = self.cand
        if not c then return 0 end
        local unitQty = math.max(1, math.floor(tonumber(c.unitQty) or 1))
        local units = math.floor((tonumber(c.count) or 0) / unitQty)
        local room = sellRoom(c, self.currency)
        local bid = math.max(1, math.floor(self:unitBid() or 1))
        if room.sku ~= nil then units = math.min(units, math.floor(room.sku)) end
        if room.account ~= nil then units = math.min(units, math.floor(room.account / bid)) end
        if room.server ~= nil then units = math.min(units, math.floor(room.server / bid)) end
        return math.max(0, math.min(max, units))
    end
    if row.dailyCap > 0 and row.remaining then
        max = math.min(max, math.max(0, math.floor(row.remaining)))
    end
    return max
end

-- nil when this order has no price at all in the chosen currency.
function BuyDialog:total()
    local unit = self.sell and self:unitBid() or self:unitPrice()
    if unit == nil then return nil end
    return self.count * unit
end

function BuyDialog:available()
    local bal = C.wallet and C.wallet.balances and C.wallet.balances[self.currency]
    return bal and tonumber(bal.available) or 0
end

function BuyDialog:onStep(button)
    if self:frozen() then return end
    self.count = math.max(1, math.min(self:maxCount(), self.count + button.internal))
    self.message = nil
    -- a smaller lot may fit again: the consent to park this purchase belongs to one count
    self.mailRequired = nil
end

-- The room this purchase needs against the room the player has, estimated on this client from
-- the item's own weight (C.deliveryPreview). It walks the container, so it is recomputed when
-- the count moves and never per frame; the server re-checks it before it debits anything, and
-- an item whose weight is unknown here says so instead of quoting a number it invented.
-- Selling has no delivery of its own: the items leave the backpack.
function BuyDialog:refreshPreview()
    if self.sell then self.preview = nil; return end
    local row = self.row
    local qty = math.max(1, math.floor(tonumber(row.qty) or 1)) * self.count
    self.preview = C.deliveryPreview(row.item, qty, row.weight)
end

function BuyDialog:onCancel() self.panel:closeBuy() end
function BuyDialog:onConfirm()
    if self.sell then self.panel:submitSell(self) else self.panel:submitBuy(self) end
end

-- Every value of this trade, in reading order. The server's refusal comes first: the reader
-- scrolls back to the top whenever its text changes, so it is the line the player lands on.
function BuyDialog:summaryLines()
    local out, row, sell = {}, self.row, self.sell == true
    local cur = self.currency
    local curName = currencyLabel(cur)
    local c = self.cand
    if self.message then out[#out + 1] = self.message; out[#out + 1] = "" end
    out[#out + 1] = row.name
    if row.altName and row.altName ~= row.name then out[#out + 1] = row.altName end
    out[#out + 1] = tostring(row.item)
    out[#out + 1] = detailLine("Trade_Currency", curName)
    local unit = sell and self:unitBid() or self:unitPrice()
    local total = self:total()
    local available = self:available()
    if sell then
        -- what the backpack holds, in the server's words (only canonical copies count)
        if not c then out[#out + 1] = getText(T .. "Wallet_Loading")
        elseif (tonumber(c.count) or 0) < 1 then out[#out + 1] = getText(T .. "Shop_SellNone")
        else out[#out + 1] = getText(T .. "Shop_SellHave", tostring(math.floor(tonumber(c.count) or 0)),
            tostring(math.floor(tonumber(c.unitQty) or 1)), amountOrDash(unit)) end
        out[#out + 1] = detailLine("Shop_Col_Bid", moneyText(unit, cur))
        out[#out + 1] = detailLine("Shop_SellUnits", tostring(self.count))
        out[#out + 1] = detailLine("Shop_SellTotal", moneyText(total, cur))
        out[#out + 1] = detailLine("Shop_AfterBalance",
            moneyText(total and (available + total) or available, cur))
        if c then
            local room = sellRoom(c, cur)
            out[#out + 1] = getText(T .. "Shop_SellRoom", amountOrDash(room.account),
                amountOrDash(room.server))
            if room.sku ~= nil then
                out[#out + 1] = getText(T .. "Shop_SellRoomSku", tostring(math.floor(room.sku)))
            end
        end
    else
        out[#out + 1] = row.qtyText
        out[#out + 1] = detailLine("Shop_Col_Price", moneyText(unit, cur))
        out[#out + 1] = detailLine("Shop_Col_Remaining", row.remainText)
        -- a limited sku says which count it is limited by and how much of that count is
        -- already spent, so an order is never confirmed against a number the row had to cut
        if row.dailyCap > 0 then
            out[#out + 1] = detailLine("Shop_CapScope", row.capScopeText)
            out[#out + 1] = detailLine("Shop_Used", row.usedText)
        end
        out[#out + 1] = detailLine("Shop_Count", tostring(self.count))
        out[#out + 1] = detailLine("Shop_Total", moneyText(total, cur))
        out[#out + 1] = detailLine("Shop_AfterBalance",
            moneyText(total and (available - total) or available, cur))
        capacityLines(out, self.preview)
    end
    -- every currency this sku is quoted in, so the choice above is made with both prices in view
    out[#out + 1] = ""
    out[#out + 1] = getText(T .. "Shop_Quotes")
    for _, q in ipairs(row.quotes or {}) do
        local line = currencyLabel(q.currency) .. "  "
            .. detailLine("Shop_Col_Price", amountOrDash(q.enabled and q.price or nil))
        if q.buyback then line = line .. "  " .. detailLine("Shop_Col_Bid", amountOrDash(q.bidPrice)) end
        out[#out + 1] = line
    end
    return out
end

-- Cheap guard first: while none of the values the summary names has moved, prerender does no
-- work at all. layoutInside writes the summary itself, so a fresh row or candidate is always
-- on the box before this ever runs.
function BuyDialog:syncSummary()
    local c = self.cand
    local d, e = self.mailRequired == true, nil
    if self.sell then
        d, e = c and (tonumber(c.count) or 0) or -1, c and c.bidPrice or nil
    end
    if not summaryMoved(self, self.count, self:available(), self.message, d, e)
        and self.sumCur == self.currency then return end
    self.sumCur = self.currency
    self:refreshPreview()
    setSummary(self, self:summaryLines())
end

function BuyDialog:layoutInside(maxW, maxH)
    local step = self.minusButton.height
    local w = math.max(340, math.min(maxW, 520))
    local y = PAD
    self.headY = y
    self.headH = math.max(ITEM_ICON, fontH.medium)
    self.titleY = y + math.floor((self.headH - fontH.medium) / 2)
    y = y + self.headH + PAD
    -- the currency chips: only the currencies this order can really be made in
    local chipsX = PAD + textWidth(getText(T .. "Trade_Currency")) + PAD
    for _, b in ipairs(self.currencyButtons) do b:setVisible(self:offers(b.internal)) end
    local chipsH = chipsHeight(self.currencyButtons, chipsX, w - PAD)
    if chipsH > 0 then chipsH = chipsH + 8 end
    -- the fixed tail is the currency row, the stepper row and the buttons; the reader takes what
    -- is left, and never more than its own text needs (so the estimate is on the dialog before
    -- it is measured)
    self:refreshPreview()
    local lines = self:summaryLines()
    local boxW = w - PAD * 2
    local room = maxH - y - (PAD + chipsH + step + 8 + self.confirmButton.height + PAD)
    local box = self.summaryBox
    box:setX(PAD); box:setY(y); box:setWidth(boxW)
    box:setHeight(math.max(fontH.small + 12, math.min(readerHeight(lines, boxW), room)))
    setSummary(self, lines)
    y = y + box.height + PAD
    self.curY = nil
    if chipsH > 0 then
        self.curY = y
        self.curLabelW = chipsX - PAD * 2
        y = placeChips(self.currencyButtons, chipsX, y, w - PAD, 8)
    end
    self.countY = y
    -- the stepper keeps the right edge and the label whatever is left of the row: a wide
    -- translation at the largest font is cut, never painted over the buttons
    self.numW = math.max(34, textWidth(tostring(self:maxCount()), UIFont.Medium) + 16)
    self.plusButton:setX(w - PAD - self.plusButton.width)
    self.plusButton:setY(y)
    self.numX = self.plusButton.x - self.numW
    self.minusButton:setX(self.numX - self.minusButton.width)
    self.minusButton:setY(y)
    self.countLabelW = math.max(0, self.minusButton.x - PAD * 2)
    y = y + step + 8
    self.buttonY = y
    self:setWidth(w)
    self:setHeight(y + self.confirmButton.height + PAD)
    self.confirmButton:setX(w - PAD - self.confirmButton.width)
    self.confirmButton:setY(self.buttonY)
    self.cancelButton:setX(self.confirmButton.x - 8 - self.cancelButton.width)
    self.cancelButton:setY(self.buttonY)
    self:syncSummary()      -- the text is already written: this only primes the change guard
end

function BuyDialog:keyboardTargets()
    return {
        -- the reader holds every value of the trade: the ring scrolls it, and never focuses it
        { kind = "scroll", control = self.summaryBox, focusable = false, label = getText(T .. "Kb_Detail") },
        { kind = "group", controls = { self.minusButton, self.plusButton }, label = getText(T .. "Market_Col_Qty") },
        { kind = "group", controls = self.currencyButtons, label = getText(T .. "Trade_Currency") },
        { kind = "group", controls = { self.confirmButton, self.cancelButton }, label = getText(T .. "Kb_Dialog_Actions") },
    }
end

function BuyDialog:prerender()
    local row = self.row
    local w, h = self.width, self.height
    local sell = self.sell == true
    fill(self, 0, 0, w, h, "surface")
    border(self, 0, 0, w, h, "accent")
    drawIcon(self, row.texture, PAD, self.headY + math.floor((self.headH - ITEM_ICON) / 2), ITEM_ICON)
    local tx = PAD + ITEM_ICON + PAD
    text(self, fitText(getText(T .. (sell and "Shop_SellTitle" or "Shop_BuyTitle"), row.name),
        w - tx - PAD, UIFont.Medium), tx, self.titleY, "text", UIFont.Medium)
    local max = self:maxCount()
    -- A cut is a change to the order, so it goes through clampCount (which says so and asks
    -- for the confirm again). While the allowance is unknown -- a sale whose candidates have
    -- not answered yet -- the count the player asked for is left exactly as it is.
    if max >= 1 then
        self:clampCount()
        if self.count < 1 then self.count = 1 end
    end
    local stepH = self.minusButton.height
    if self.curY then
        text(self, fitText(getText(T .. "Trade_Currency"), self.curLabelW), PAD,
            self.curY + math.floor((self.currencyButtons[1].height - fontH.small) / 2), "textMuted")
    end
    text(self, fitText(getText(T .. (sell and "Shop_SellUnits" or "Shop_Count")), self.countLabelW),
        PAD, self.countY + math.floor((stepH - fontH.small) / 2), "textMuted")
    textCentre(self, tostring(self.count), self.numX + self.numW / 2,
        self.countY + math.floor((stepH - fontH.medium) / 2), "text", UIFont.Medium)
    self:syncSummary()
    local total = self:total()
    local after = total and (sell and (self:available() + total) or (self:available() - total)) or nil
    local pending = self.panel.buyPending ~= nil
    self.minusButton:setEnable(self.count > 1 and not pending)
    self.plusButton:setEnable(self.count < max and not pending)
    -- the order on the wire owns the currency too: the chips read as shut while it is out
    for _, b in ipairs(self.currencyButtons) do b:setEnable(not pending) end
    -- A fresh zero allowance disables confirmation even if this dialog was already open.
    local ok = total ~= nil and max >= 1 and self.count >= 1 and (sell or after >= 0)
    self.confirmButton:setEnable(ok and not pending and self.panel:tradeAllowed())
end

function BuyDialog:render() end

-- the page underneath must not be operable while the dialog is open
function BuyDialog:onMouseDown() return true end
function BuyDialog:onMouseUp() return true end
function BuyDialog:onMouseMove() return true end

-- ---------- market / auction dialog ----------
-- Same shape as BuyDialog (a child panel centred over the content, swallowing the page's
-- clicks), with every step of both trade pages on one panel: the purchase, the cancel
-- confirmation, the backpack picker and the pricing step the picker hands over to (the picker
-- switches its own content instead of stacking a second dialog on top of itself), plus the
-- auction bid, the auction create step the same picker hands over to, and its cancel.
local MarketDialog = ISPanel:derive("MinidoracatEconomyMarketDialog")

-- The durations offered when the sandbox range allows them; a range that holds none of them
-- (a server that only permits 10..30 h, say, still keeps 12 and 24) falls back to its bounds.
local HOUR_PRESETS = { 6, 12, 24, 48, 72 }
local HOUR_DEFAULT = 24

local function hourChoices(minH, maxH)
    local out = {}
    for _, hrs in ipairs(HOUR_PRESETS) do
        if hrs >= minH and hrs <= maxH then out[#out + 1] = hrs end
    end
    if #out == 0 then
        out[1] = minH
        if maxH > minH then out[2] = maxH end
    end
    return out
end

-- the auction steps confirm through Panel:submitAuction, the market ones through submitMarket
local AUCTION_MODES = { bid = true, auction = true, acancel = true }

local function confirmLabel(mode)
    if mode == "buy" then return getText(T .. "Market_Buy") end
    if mode == "cancel" then return getText(T .. "Market_Cancel") end
    if mode == "price" then return getText(T .. "Market_List") end
    if mode == "bid" then return getText(T .. "Auction_Bid") end
    if mode == "auction" then return getText(T .. "Auction_Create") end
    if mode == "acancel" then return getText(T .. "Auction_CancelTitle") end
    return nil     -- the picker confirms by picking a row
end

function MarketDialog:createChildren()
    local bh = math.max(28, fontH.medium + 10)
    self.confirmButton = Button.create(0, 0, 120, bh, confirmLabel("buy"), self, MarketDialog.onConfirm, "primary")
    self.confirmButton.font = UIFont.Medium
    self:addChild(self.confirmButton)
    local cancel = getText(T .. "Admin_Cancel")
    self.cancelButton = Button.create(0, 0, textWidth(cancel) + 30, bh, cancel, self, MarketDialog.onCancel, "chip")
    self:addChild(self.cancelButton)
    -- The currency a new listing or auction is priced in. The seller fixes it here, once, and
    -- the server keeps it on the record from then on; the buy and bid steps have no chips at
    -- all, because a buyer never picks the currency of somebody else's listing.
    self.currencyButtons = newCurrencyChips(self, MarketDialog.onCurrency)
    -- every value of the step, scrolling: a 1000x560 window at the largest UI font has no room
    -- to stack them as lines, and none of them may be cut
    self.summaryBox = newReader(self, 240, fontH.small * 2 + 12)
    self.priceEntry = newEntry(140, math.max(26, fontH.small + 12), nil, true)
    self.priceEntry.target = self
    self.priceEntry.onTextChangeFunction = MarketDialog.onPriceChanged
    self:addChild(self.priceEntry)
    -- the lot size: only shown when the picked row carries more than one item
    self.qtyEntry = newEntry(140, math.max(26, fontH.small + 12), nil, true)
    self.qtyEntry.target = self
    self.qtyEntry.onTextChangeFunction = MarketDialog.onPriceChanged
    self:addChild(self.qtyEntry)
    local only = getText(T .. "Market_OnlyListable")
    self.onlyButton = Button.create(0, 0, textWidth(only) + 30, math.max(CHIP_H, fontH.small + 10),
        only, self, MarketDialog.onOnlyListable, "chip")
    self.onlyListable = true             -- the backpack is mostly unlistable: start on the useful half
    self.onlyButton.active = true
    self:addChild(self.onlyButton)
    -- auction duration chips: one per preset, retitled when the create step opens (the sandbox
    -- range decides which of them exist, so they are built once and hidden until then)
    self.hourButtons = {}
    for i = 1, #HOUR_PRESETS do
        local b = Button.create(0, 0, 60, math.max(CHIP_H, fontH.small + 10), "", self, MarketDialog.onHours, "chip")
        b:setVisible(false)
        self:addChild(b)
        self.hourButtons[i] = b
    end
    local tw, th = tileSize()
    self.pickList = U.newTable(CandidateCell, th)
    self.pickList.cols.tileW, self.pickList.cols.tileH = tw, th
    -- VirtualList hands onSelect the row (a whole strip of tiles) and no x, so the tile is
    -- resolved here from the click's own x; the scrollbar keeps the framework's handler.
    local scrollDown = self.pickList.onMouseDown
    self.pickList.onMouseDown = function(list, x, y)
        local e = self:tileAt(x, y)
        if e then
            self.panel:onCandidate(e)
            return true
        end
        return scrollDown(list, x, y)
    end
    -- This grid uses the same list focus and held-key ledger as every other table.
    self.pickList.ecKey = function(list, key)
        local rows, k = list.items, Keyboard
        if #rows == 0 then return false end
        if key == k.KEY_RETURN or key == k.KEY_NUMPADENTER or key == k.KEY_SPACE then
            local candidate = gridCandidate(list)
            if candidate then self.panel:onCandidate(candidate) end
            return true
        end
        local row = list:getSelectedIndex() or 1
        row = math.max(1, math.min(#rows, row))
        local col = math.max(1, math.min(list.ecColumn or 1, #rows[row]))
        local page = math.max(1, math.floor(list.height / (list.rowHeight + (list.padding or 0))))
        if key == k.KEY_LEFT then
            if col > 1 then col = col - 1
            elseif row > 1 then row = row - 1; col = #rows[row] end
        elseif key == k.KEY_RIGHT then
            if col < #rows[row] then col = col + 1
            elseif row < #rows then row = row + 1; col = 1 end
        elseif key == k.KEY_UP then row = math.max(1, row - 1)
        elseif key == k.KEY_DOWN then row = math.min(#rows, row + 1)
        elseif key == k.KEY_PRIOR then row = math.max(1, row - page)
        elseif key == k.KEY_NEXT then row = math.min(#rows, row + page)
        elseif key == k.KEY_HOME then row, col = 1, 1
        elseif key == k.KEY_END then row = #rows; col = #rows[row]
        else return false end
        list.ecColumn = math.min(col, #rows[row])
        list:setSelectedIndex(row)
        list:scrollToIndex(row)
        return true
    end
    self:addChild(self.pickList)
end

-- The seller picked the currency of the listing they are creating. It is fixed on the record
-- the moment the server accepts it, so nothing after this step may change it -- and once the
-- write is on the wire the choice is frozen until it answers, for the keyboard as well as the
-- mouse (the chips are painted disabled too, but a handler never relies on the paint).
function MarketDialog:onCurrency(button)
    if self.panel.marketPending ~= nil or self.currency == button.internal then return end
    self.currency = button.internal
    for _, b in ipairs(self.currencyButtons) do b.active = b.internal == self.currency end
    self.message = nil
    self.panel:layoutDialog(self)
end

-- The currency this step really trades in: a buy or a bid is the record's own (a buyer never
-- picks it), everything else is the seller's choice above.
function MarketDialog:activeCurrency()
    if self.row ~= nil then return self.row.currency end
    return self.currency
end


function MarketDialog:onCancel() self.panel:closeMarketDialog() end
function MarketDialog:onConfirm()
    if AUCTION_MODES[self.mode] then self.panel:submitAuction(self) else self.panel:submitMarket(self) end
end

function MarketDialog:keyboardTargets()
    local out = {}
    if self.pickList:getIsVisible() then
        out[#out + 1] = { kind = "list", control = self.pickList, label = getText(T .. "Admin_Pick_Title") }
        out[#out + 1] = { kind = "button", control = self.onlyButton, label = self.onlyButton.fullTitle }
    else
        -- the reader holds every value of this step: the ring scrolls it, and never focuses it
        out[#out + 1] = { kind = "scroll", control = self.summaryBox, focusable = false,
            label = getText(T .. "Kb_Detail") }
    end
    out[#out + 1] = { kind = "group", controls = self.currencyButtons,
        label = getText(T .. "Trade_Currency") }
    if self.qtyEntry:getIsVisible() then
        out[#out + 1] = { kind = "entry", control = self.qtyEntry, label = getText(T .. "Market_Col_Qty") }
    end
    if self.priceEntry:getIsVisible() then
        out[#out + 1] = { kind = "entry", control = self.priceEntry, label = getText(T .. "Market_Col_LotPrice") }
    end
    if #self.hourButtons > 0 then
        out[#out + 1] = { kind = "group", controls = self.hourButtons, label = getText(T .. "Auction_Duration") }
    end
    out[#out + 1] = { kind = "group", controls = { self.confirmButton, self.cancelButton },
        label = getText(T .. "Kb_Dialog_Actions") }
    return out
end

function MarketDialog:onHours(button)
    if self.panel.marketPending ~= nil then return end
    self.hours = button.internal
    for _, b in ipairs(self.hourButtons) do b.active = b.internal == self.hours end
    self.message = nil
end

-- The create step opens: build the chip set the sandbox range allows and preselect the one
-- closest to a day (the duration a player picks by default on every auction house there is).
function MarketDialog:setHourRange(minH, maxH)
    local choices = hourChoices(minH, maxH)
    local best = choices[1]
    for _, hrs in ipairs(choices) do
        if math.abs(hrs - HOUR_DEFAULT) < math.abs(best - HOUR_DEFAULT) then best = hrs end
    end
    self.hours = best
    for i, b in ipairs(self.hourButtons) do
        b.internal = choices[i]
        if b.internal then
            local title = getText(T .. "Auction_Hours", tostring(b.internal))
            b:setTitle(title)
            b:setWidth(textWidth(title) + 22)
            b.active = b.internal == best
        end
    end
end
function MarketDialog:onPriceChanged() self.message = nil end

function MarketDialog:onOnlyListable()
    self.onlyListable = not self.onlyListable
    self.onlyButton.active = self.onlyListable
    self.pickNote = nil
    self:rebuildGrid()
end

-- The candidate under (x, y), or nil outside the tiles (row gap, empty tail of a strip, the
-- scrollbar column). Returns the strip index and the column too: the paint reads them for hover.
function MarketDialog:tileAt(x, y)
    local list = self.pickList
    local tw = list.cols.tileW
    if not tw or x < 0 or x >= list:cellWidth() then return nil end
    local index = list:indexAt(x, y)
    if not index then return nil end
    local tiles = list:getItems()[index]
    local col = math.floor(x / tw) + 1
    local e = tiles and tiles[col]
    if not e then return nil end
    return e, index, col
end

-- Candidates -> strips of gridCols tiles, dropping the unlistable ones while the filter is on.
-- Called on a fresh snapshot, on the filter chip, and when a resize changes the column count.
function MarketDialog:rebuildGrid()
    local rows = self.panel.candidateRows or {}
    local perRow = math.max(1, self.gridCols or 1)
    local grid, strip, shown, listable = {}, nil, 0, 0
    for i = 1, #rows do
        local e = rows[i]
        if e.ok then listable = listable + 1 end
        if e.ok or not self.onlyListable then
            if not strip or #strip >= perRow then
                strip = {}
                grid[#grid + 1] = strip
            end
            strip[#strip + 1] = e
            shown = shown + 1
        end
    end
    self.candTotal, self.candListable, self.candShown = #rows, listable, shown
    self.pickList:setItems(grid)
end

-- Whole numbers only: the entry filters the keyboard, this filters a paste.
function MarketDialog:priceValue()
    local raw = string.match(entryText(self.priceEntry), "^%s*(.-)%s*$")
    if not string.match(raw, "^%d+$") then return nil end
    local n = tonumber(raw)
    if not n or n <= 0 then return nil end
    return math.floor(n)
end

-- The lot size to list, 1..count. nil = not a usable number: the confirm stays closed instead
-- of the server refusing a request the client could already tell was wrong.
function MarketDialog:lotCount()
    return (self.cand and self.cand.count) or 1
end

function MarketDialog:qtyValue()
    local max = self:lotCount()
    if max <= 1 then return 1 end
    local raw = string.match(entryText(self.qtyEntry), "^%s*(.-)%s*$")
    if not string.match(raw, "^%d+$") then return nil end
    local n = tonumber(raw)
    if not n or n < 1 or n > max then return nil end
    return math.floor(n)
end

function MarketDialog:available()
    local bal = C.wallet and C.wallet.balances and C.wallet.balances[self:activeCurrency()]
    return bal and tonumber(bal.available) or 0
end

-- Raising an own leading bid only reserves the difference: the server holds the first amount
-- already (ECAuction.bid takes `delta` off the available balance, not the whole new bid).
function MarketDialog:bidReserve(amount)
    local row = self.row
    local held = (row and row.leading and tonumber(row.bid)) or 0
    return math.max(0, amount - held)
end

-- Every value this step trades on, in reading order. The server's refusal comes first: the
-- reader scrolls back to the top whenever its text changes, so it is the line the player lands
-- on. Built when one of those values moves (syncSummary), never per frame.
function MarketDialog:summaryLines()
    local out, mode, panel = {}, self.mode, self.panel
    local info = panel.marketInfo or {}
    local currency = self:activeCurrency()
    local cur = currencyLabel(currency)
    if self.message then out[#out + 1] = self.message; out[#out + 1] = "" end
    -- Which currency this step moves, always spelled out: a buy or a bid reads the record's own
    -- (and a record that carries none is refused rather than guessed at), a new listing reads
    -- the seller's choice above.
    out[#out + 1] = detailLine("Trade_Currency", cur)
    -- a step that moves money and has no currency cannot go out, and says so; a withdrawal
    -- can, so it is not warned about something that does not stop it
    if currency == nil and mode ~= "cancel" and mode ~= "acancel" then
        out[#out + 1] = getText(T .. "Market_CurrencyMissing")
    end
    if mode == "buy" then
        local row = self.row
        out[#out + 1] = row.lotName
        if row.altName and row.altName ~= row.name then out[#out + 1] = row.altName end
        out[#out + 1] = tostring(row.item)
        if row.statusText then out[#out + 1] = row.statusText end
        out[#out + 1] = getText(T .. "Market_BuyFrom", row.seller)
        out[#out + 1] = detailLine("Market_Col_Qty", tostring(row.qty))
        out[#out + 1] = detailLine("Market_Col_Expires", row.expiresText)
        out[#out + 1] = detailLine("Market_YouPay", amountText(row.price) .. " " .. cur)
        out[#out + 1] = detailLine("Shop_AfterBalance", amountText(self:available() - row.price) .. " " .. cur)
        capacityLines(out, self.preview)
    elseif mode == "cancel" then
        local row = self.row
        out[#out + 1] = row.nameText
        out[#out + 1] = tostring(row.item)
        out[#out + 1] = detailLine("Market_Col_Qty", tostring(row.qty))
        out[#out + 1] = detailLine("Market_Col_LotPrice", row.priceText .. " " .. cur)
        out[#out + 1] = getText(T .. "Market_CancelConfirm", row.name)
    elseif mode == "acancel" then
        local row = self.row
        out[#out + 1] = row.nameText
        out[#out + 1] = tostring(row.item)
        out[#out + 1] = detailLine("Auction_Col_Bid", row.priceText .. " " .. cur)
        out[#out + 1] = detailLine("Auction_Col_Bids", row.bidsText)
        out[#out + 1] = detailLine("Auction_Col_Ends", row.expiresText)
        out[#out + 1] = getText(T .. "Auction_CancelHint")
    elseif mode == "bid" then
        local row = self.row
        local amount = self:priceValue() or 0
        local reserve = self:bidReserve(amount)
        out[#out + 1] = row.nameText
        if row.altName and row.altName ~= row.name then out[#out + 1] = row.altName end
        out[#out + 1] = tostring(row.item)
        if row.statusText then out[#out + 1] = row.statusText end
        out[#out + 1] = detailLine("Auction_Col_Bid", row.priceText .. " " .. cur)
        out[#out + 1] = detailLine("Auction_Col_Bids", row.bidsText)
        out[#out + 1] = detailLine("Auction_Col_Ends", row.expiresText)
        out[#out + 1] = getText(T .. "Auction_MinNext", amountText(row.minNext))
        out[#out + 1] = detailLine("Auction_YourBid", amountText(amount) .. " " .. cur)
        out[#out + 1] = detailLine("Auction_WillReserve", amountText(reserve) .. " " .. cur)
        out[#out + 1] = detailLine("Shop_AfterBalance", amountText(self:available() - reserve) .. " " .. cur)
    else
        -- the pricing step the picker handed over to: what is being listed, what the server
        -- allows, and what this price costs and pays out
        local cand = self.cand or {}
        local count = self:lotCount()
        local price = self:priceValue() or 0
        out[#out + 1] = count > 1 and (tostring(cand.name) .. " " .. tostring(cand.qtyText)) or tostring(cand.name)
        if cand.altName and cand.altName ~= cand.name then out[#out + 1] = cand.altName end
        out[#out + 1] = tostring(cand.item)
        if cand.detailText and cand.detailText ~= "" then out[#out + 1] = cand.detailText end
        out[#out + 1] = detailLine("Market_Qty", tostring(self:qtyValue() or 0))
        out[#out + 1] = detailLine(mode == "auction" and "Auction_StartPrice" or "Market_Price",
            amountText(price) .. " " .. cur)
        out[#out + 1] = detailLine("Shop_AfterBalance",
            amountText(self:available() - listingFee(price, info.feePercent)) .. " " .. cur)
        if count > 1 then
            out[#out + 1] = detailLine("Market_Qty", getText(T .. "Market_QtyHint", tostring(count), tostring(count)))
        end
        local range = getText(T .. "Market_PriceHint", amountText(info.priceMin), amountText(info.priceMax))
        if mode == "auction" then
            local hours = panel.auctionInfo or {}
            out[#out + 1] = detailLine("Auction_StartPrice", range)
            out[#out + 1] = detailLine("Auction_Duration",
                (self.hours and getText(T .. "Auction_Hours", tostring(self.hours)) or "-")
                .. " (" .. getText(T .. "Auction_HoursHint", tostring(hours.minHours or 0),
                    tostring(hours.maxHours or 0)) .. ")")
            out[#out + 1] = detailLine("Market_Fee", amountText(listingFee(price, info.feePercent)) .. " " .. cur)
        else
            out[#out + 1] = detailLine("Market_Price", range)
            out[#out + 1] = detailLine("Market_Fee", amountText(listingFee(price, info.feePercent)) .. " " .. cur)
            out[#out + 1] = detailLine("Market_YouGet",
                amountText(price - ceilPercent(price, info.taxPercent)) .. " " .. cur)
        end
    end
    return out
end

-- Cheap guard first: while none of the five values the summary names has moved, prerender does
-- no work at all. layoutInside writes the summary itself, so a fresh row, candidate or snapshot
-- is always on the box before this ever runs.
function MarketDialog:syncSummary()
    if self.mode == "pick" then return end
    if not summaryMoved(self, self:priceValue(), self:qtyValue(), self:available(),
        self.message, self.hours) and self.sumCur == self:activeCurrency() then return end
    self.sumCur = self:activeCurrency()
    setSummary(self, self:summaryLines())
end

function MarketDialog:layoutInside(maxW, maxH)
    local mode = self.mode
    local pick = mode == "pick"
    local priceField = mode == "price" or mode == "auction" or mode == "bid"
    local multi = (mode == "price" or mode == "auction") and self:lotCount() > 1
    local chips = mode == "auction"
    -- only the seller's own steps offer a currency: a buyer trades the record's own
    local curChips = mode == "price" or mode == "auction"
    -- A market lot is a fixed size, so the room it needs is estimated once, when the step opens:
    -- what it costs to walk the container does not belong in a layout that runs on every resize.
    -- The server re-checks the room before it debits and asks again when it changed.
    if mode == "buy" and self.preview == nil then
        self.preview = C.deliveryPreview(self.row.item, self.row.qty, self.row.weight)
    end
    self.priceEntry:setVisible(priceField)
    self.qtyEntry:setVisible(multi)
    for _, b in ipairs(self.hourButtons) do b:setVisible(chips and b.internal ~= nil) end
    for _, b in ipairs(self.currencyButtons) do b:setVisible(curChips) end
    self.pickList:setVisible(pick)
    self.onlyButton:setVisible(pick)
    self.summaryBox:setVisible(not pick)
    local label = confirmLabel(mode)
    self.confirmButton:setVisible(label ~= nil)
    if label then
        if self.confirmButton.title ~= label then self.confirmButton:setTitle(label) end
        self.confirmButton:setWidth(math.max(120, textWidth(label, UIFont.Medium) + 40))
    end
    local chipsX = PAD + textWidth(getText(T .. "Auction_Duration")) + PAD
    local curX = PAD + textWidth(getText(T .. "Trade_Currency")) + PAD
    local w
    if pick then
        -- the grid is the page: 90% of the content area, never under a readable minimum
        w = math.min(maxW, math.max(640, math.floor(maxW * 0.9)))
    elseif chips then
        -- wide enough for the duration chips on one line while the window allows it
        local want = chipsX + PAD
        for _, b in ipairs(self.hourButtons) do
            if b.internal then want = want + b.width + 6 end
        end
        w = math.max(360, math.min(maxW, want))
    else
        w = math.max(360, math.min(maxW, 520))
    end
    local footerW = self.cancelButton.width + PAD * 2
    if label then footerW = footerW + self.confirmButton.width + 8 end
    w = math.min(maxW, math.max(w, footerW))
    local line = fontH.small + 8
    local buttonH = self.cancelButton.height
    local y = PAD
    if pick then
        -- title, the listable counter and the filter chip share the top line
        local chipH = self.onlyButton.height
        self.curY = nil
        local headH = math.max(fontH.medium, chipH)
        self.onlyButton:setX(w - PAD - self.onlyButton.width)
        self.onlyButton:setY(y + math.floor((headH - chipH) / 2))
        self.countR = self.onlyButton.x - 8
        self.titleY = y + math.floor((headH - fontH.medium) / 2)
        y = y + headH + PAD
        local tw, th = tileSize()
        local listW = w - PAD * 2
        -- the tail (status line, error line, buttons) is taken off the grid, so the dialog lands
        -- on the height the window gave it instead of growing past it
        local tail = PAD + line + line + 6 + buttonH + PAD
        local listH = math.max(60, maxH - y - tail)
        self.pickList:setX(PAD); self.pickList:setY(y)
        if self.pickList.width ~= listW or self.pickList.height ~= listH then
            self.pickList:resize(listW, listH)
        end
        local cols = self.pickList.cols
        cols.tileW, cols.tileH = tw, th
        -- the scrollbar (10 wide + 2 margin) appears as soon as the grid overflows: budget for
        -- it always, so the strips never have to reflow when it does
        local perRow = math.max(1, math.floor((listW - 12) / tw))
        if self.gridCols ~= perRow then
            self.gridCols = perRow
            self:rebuildGrid()
        end
        y = y + listH + PAD
        self.statusY = y; y = y + line
        -- the error line is always reserved: an answer from the server must not make the dialog
        -- (and with it the button under the cursor) jump
        self.messageY = y; y = y + line + 6
    else
        self.headY = y
        self.headH = math.max(ITEM_ICON, fontH.medium)
        self.titleY = y + math.floor((self.headH - fontH.medium) / 2)
        y = y + self.headH + PAD
        local entryH = self.priceEntry.height
        local fieldW = math.max(120, textWidth("999,999,999") + 30)
        local fieldsH = ((multi and 1 or 0) + (priceField and 1 or 0)) * (entryH + 8)
        local curH = curChips and (chipsHeight(self.currencyButtons, curX, w - PAD) + 8) or 0
        local chipH = self.hourButtons[1].height
        local chipRows, chipsH = 0, 0
        if chips then
            -- the chips wrap inside the width above; measuring the wrap first is what keeps the
            -- reader (and with it the dialog) inside the band
            local cx = chipsX
            chipRows = 1
            for _, b in ipairs(self.hourButtons) do
                if b.internal then
                    if cx > PAD and cx + b.width > w - PAD then cx = PAD; chipRows = chipRows + 1 end
                    cx = cx + b.width + 6
                end
            end
            chipsH = chipRows * chipH + (chipRows - 1) * 4 + 8
        end
        -- the reader takes what the fixed rows leave, and never more than its own text needs
        local lines = self:summaryLines()
        local boxW = w - PAD * 2
        local room = maxH - y - (PAD + fieldsH + curH + chipsH + buttonH + PAD)
        local box = self.summaryBox
        box:setX(PAD); box:setY(y); box:setWidth(boxW)
        box:setHeight(math.max(fontH.small + 12, math.min(readerHeight(lines, boxW), room)))
        setSummary(self, lines)
        y = y + box.height + PAD
        self.qtyY, self.priceY, self.hoursY, self.curY = nil, nil, nil, nil
        if multi then
            self.qtyY = y
            self.qtyLabelW = placeField(self.qtyEntry, w, y, fieldW)
            y = y + entryH + 8
        end
        if priceField then
            self.priceY = y
            self.priceLabelW = placeField(self.priceEntry, w, y, fieldW)
            y = y + entryH + 8
        end
        if curChips then
            self.curY = y
            self.curLabelW = curX - PAD * 2
            y = placeChips(self.currencyButtons, curX, y, w - PAD, 8)
        end
        if chips then
            self.hoursY = y
            self.hoursLabelW = chipsX - PAD * 2
            local cx, cy = chipsX, y
            for _, b in ipairs(self.hourButtons) do
                if b.internal then
                    if cx > PAD and cx + b.width > w - PAD then cx = PAD; cy = cy + chipH + 4 end
                    b:setX(cx); b:setY(cy)
                    cx = cx + b.width + 6
                end
            end
            y = cy + chipH + 8
        end
    end
    self.buttonY = y
    self:setWidth(w)
    self:setHeight(y + buttonH + PAD)
    if label then
        self.confirmButton:setX(w - PAD - self.confirmButton.width)
        self.confirmButton:setY(self.buttonY)
        self.cancelButton:setX(self.confirmButton.x - 8 - self.cancelButton.width)
    else
        self.cancelButton:setX(w - PAD - self.cancelButton.width)
    end
    self.cancelButton:setY(self.buttonY)
    self:syncSummary()      -- the text is already written: this only primes the change guard
end

function MarketDialog:prerender()
    local w, h = self.width, self.height
    local mode = self.mode
    local panel = self.panel
    local busy = panel.marketPending ~= nil
    fill(self, 0, 0, w, h, "surface")
    border(self, 0, 0, w, h, "accent")
    if mode == "pick" then
        local info = panel.marketInfo or {}
        -- title, counter and filter chip share the head line: the counter takes its width first
        self.countText = getText(T .. "Market_PickCount", tostring(self.candListable or 0),
            tostring(self.candTotal or 0))
        if info.mailCapacity then
            -- a listing takes a mailbox slot: the counter says how many are left
            self.countText = getText(T .. "Market_MailUsage", tostring(info.mailUsed or 0), tostring(info.mailCapacity))
                .. "   " .. self.countText
        end
        text(self, fitText(getText(T .. "Market_ListTitle"),
            self.countR - PAD - textWidth(self.countText) - PAD, UIFont.Medium), PAD, self.titleY, "text", UIFont.Medium)
        textRight(self, self.countText, self.countR,
            self.titleY + math.floor((fontH.medium - fontH.small) / 2), "textMuted")
        -- one pass over the grid: the tile under the cursor decides the status line, and the
        -- strips read the same two numbers back when they paint their hover highlight
        local list = self.pickList
        local hover = nil
        list.hoverIndex, list.hoverCol = nil, nil
        if list:isMouseOver() then
            local e, index, col = self:tileAt(list:getMouseX(), list:getMouseY())
            if e then
                hover, list.hoverIndex, list.hoverCol = e, index, col
            end
        end
        if not hover and Keys.isKeyboardFocused(list) then hover = gridCandidate(list) end
        -- the hovered tile, else the refusal of the last unlistable tile the player clicked,
        -- else the invitation to pick one
        local status, token = getText(T .. "Market_PickSelect"), "textMuted"
        if info.mailCapacity and (info.mailUsed or 0) >= info.mailCapacity then
            status, token = getText(T .. "Market_Error_mailbox_full"), "errorText"
        elseif hover then
            status = hover.detailText
            if not hover.ok then token = "warn" end
        elseif self.pickNote then
            status, token = self.pickNote, "warn"
        end
        text(self, fitText(status, w - PAD * 2), PAD, self.statusY, token)
        if (self.candTotal or 0) == 0 then
            text(self, getText(T .. "Market_PickEmpty"), PAD * 2, list.y + 6, "textMuted")
        elseif (self.candShown or 0) == 0 then
            text(self, getText(T .. "Market_NoMatch"), PAD * 2, list.y + 6, "textMuted")
        end
        if self.message then text(self, fitText(self.message, w - PAD * 2), PAD, self.messageY, "errorText") end
        return
    end
    -- Every other step is the same shape: the icon and the title, the reader that spells out
    -- every value of the trade (including the server's refusal), and the fields this step needs.
    -- Nothing but the title and the field labels is painted here, so no amount can be cut by the
    -- room the window has left.
    local row, cand = self.row, self.cand
    drawIcon(self, (row and row.texture) or (cand and cand.texture), PAD,
        self.headY + math.floor((self.headH - ITEM_ICON) / 2), ITEM_ICON)
    local tx = PAD + ITEM_ICON + PAD
    local title = getText(T .. "Market_ListTitle")
    if mode == "buy" then title = getText(T .. "Market_BuyTitle", row.lotName)
    elseif mode == "cancel" then title = getText(T .. "Market_Cancel")
    elseif mode == "bid" then title = getText(T .. "Auction_BidTitle", row.nameText)
    elseif mode == "auction" then title = getText(T .. "Auction_CreateTitle")
    elseif mode == "acancel" then title = getText(T .. "Auction_CancelTitle") end
    text(self, fitText(title, w - tx - PAD, UIFont.Medium), tx, self.titleY, "text", UIFont.Medium)
    if self.qtyY then
        text(self, fitText(getText(T .. "Market_Qty"), self.qtyLabelW), PAD,
            self.qtyY + math.floor((self.qtyEntry.height - fontH.small) / 2), "textMuted")
    end
    if self.priceY then
        local key = "Market_Price"
        if mode == "bid" then key = "Auction_YourBid"
        elseif mode == "auction" then key = "Auction_StartPrice" end
        text(self, fitText(getText(T .. key), self.priceLabelW), PAD,
            self.priceY + math.floor((self.priceEntry.height - fontH.small) / 2), "textMuted")
    end
    if self.curY then
        text(self, fitText(getText(T .. "Trade_Currency"), self.curLabelW), PAD,
            self.curY + math.floor((self.currencyButtons[1].height - fontH.small) / 2), "textMuted")
    end
    if self.hoursY then
        text(self, fitText(getText(T .. "Auction_Duration"), self.hoursLabelW), PAD,
            self.hoursY + math.floor((self.hourButtons[1].height - fontH.small) / 2), "textMuted")
    end
    self:syncSummary()
    local price = self:priceValue() or 0
    -- A step that spends or receives has to know its currency: a record without one is refused
    -- here rather than sent with a currency this client picked for it. Pulling an own listing
    -- or auction back moves no money at all -- the server hands the items over and settles
    -- nothing -- so a record whose currency it could not prove may still be withdrawn.
    local moneyless = mode == "cancel" or mode == "acancel"
    local ok = moneyless or self:activeCurrency() ~= nil
    if mode == "buy" then ok = ok and self:available() - row.price >= 0
    elseif mode == "bid" then
        ok = ok and price >= row.minNext and not row.ended and self:available() - self:bidReserve(price) >= 0
    elseif mode == "auction" then ok = ok and price > 0 and self:qtyValue() ~= nil and self.hours ~= nil
    elseif mode == "price" then ok = ok and price > 0 and self:qtyValue() ~= nil end
    for _, b in ipairs(self.currencyButtons) do b:setEnable(not busy) end
    self.confirmButton:setEnable(ok and not busy and panel:tradeAllowed())
end

function MarketDialog:render() end

function MarketDialog:onMouseDown() return true end
function MarketDialog:onMouseUp() return true end
function MarketDialog:onMouseMove() return true end

D.BuyDialog = BuyDialog
D.MarketDialog = MarketDialog
D.AUCTION_MODES = AUCTION_MODES

return D
