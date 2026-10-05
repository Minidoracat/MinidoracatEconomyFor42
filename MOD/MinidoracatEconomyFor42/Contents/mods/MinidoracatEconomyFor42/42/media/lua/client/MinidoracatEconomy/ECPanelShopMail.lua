-- MinidoracatEconomyFor42 - the shop and mailbox pages of the Economy Center window (client).
--
-- Geometry and paint of the two pages, split out of ECPanelLayout the way L.layoutMarket was (the
-- debug compiler's cumulative local budget, and one owner per page). The methods are the window's
-- own: ECPanelLayout calls M.layoutShop / M.layoutMail from L.layout and binds M.drawShop /
-- M.drawMail as L.drawShop / L.drawMail, so `self` is the window. No control, state or event here.
--
-- Both title rows follow one shape (design 2026-10-05): the card title, the numbers that change as
-- pills that wrap instead of being cut, the rules chip (the page's rules live in that detail
-- window, not in sentences above the table) and, on the mailbox, the one gold action.

if not MinidoracatEconomy or not MinidoracatEconomy.Client or not MinidoracatEconomy.Client.UI then
    require "MinidoracatEconomy/ECWidgets"
end
require "MinidoracatEconomy/ECPanelWidgets"
require "MinidoracatEconomy/ECPanelCards"

local EC = MinidoracatEconomy
local C = EC.Client
local U = C.UI
local W = C.PanelWidgets

local M = {}
C.PanelShopMail = M

local PAD, ROW, CHIP_H, COIN_SMALL, T = U.PAD, U.ROW, U.CHIP_H, U.COIN_SMALL, U.T
local CARD_TITLE_H = U.CARD_TITLE_H
local fontH = U.fontH
local fill, text, textWidth, textRight, amountText, card = U.fill, U.text, U.textWidth, U.textRight, U.amountText, U.card
local ITEM_ICON = W.ITEM_ICON
local placeRow, comboWidth = W.placeRow, W.comboWidth

-- ---------- the stat pills of the two title rows ----------
-- placePills flows up to three widths (nil = that pill is absent) from `firstX` (right of the
-- title) to `right`, wrapping to `x0`, writes where each went into xs/ys and returns how many rows
-- it took. It builds no table, so the paint can call it again when a countdown moves a width.
local function placePills(xs, ys, x0, firstX, right, top, a, b, c)
    local rowY = top + math.floor((CARD_TITLE_H - CHIP_H) / 2)
    local x, rows = firstX, 1
    for i = 1, 3 do
        local pw = (i == 1 and a) or (i == 2 and b) or (i == 3 and c) or nil
        if pw ~= nil then
            if x + pw > right and x > (rows == 1 and firstX or x0) then
                rows, x = rows + 1, x0
            end
            xs[i], ys[i] = x, rowY + (rows - 1) * (CHIP_H + 4)
            x = x + pw + 6
        end
    end
    return rows
end

local function headHeight(rows) return CARD_TITLE_H + (rows - 1) * (CHIP_H + 4) end

-- The real-world moment the shop's daily counters reset, read in the player's own zone: the date
-- and time, the zone itself, and how long is left (the rules text). Empty while no snapshot has
-- arrived (or the server sends no reset time): an unknown is not a date.
function M.shopDayNote(self)
    local shop = C.shop
    local ends = shop and tonumber(shop.dayEndsMs) or nil
    if ends == nil then return "" end
    local off = self.offsetMin or 0
    return getText(T .. "Shop_DayEnds", U.stampText(ends, off),
        U.durationText(math.max(0, ends - EC.now())), C.PanelCards.zoneText(off))
end

-- The shop's pills, rebuilt by the layout and once a second by the paint (the reset countdown):
-- what this account may still sell back today while buyback is open in the page's currency, a
-- short warning while it is paused or off for that currency, and when the purchase limits reset.
function M.shopPillText(self)
    local shop = C.shop
    local cur = self:shopCurrency()
    local bb = shop and shop.buyback
    self.shopPillV1, self.shopPillW1, self.shopPillV2, self.shopPillW2 = nil, nil, nil, nil
    self.shopPillV3, self.shopPillW3 = nil, nil
    self.shopPillCoin = cur
    if shop == nil then return end
    if self.shopHasBuyback and W.buybackOpen(bb, cur) then
        local n = tonumber(bb.byCurrency[cur].accountRemaining)
        self.shopPillL1 = getText(T .. "Shop_PillBuyback")
        self.shopPillV1 = n and amountText(n) or "-"
        self.shopPillW1 = U.pillWidth(self.shopPillL1, self.shopPillV1, cur)
    elseif self.shopHasBuyback then
        self.shopPillV2 = getText(T .. ((type(bb) == "table" and bb.enabled == true)
            and "Shop_PillBuybackOff" or "Shop_PillBuybackPaused"))
        self.shopPillW2 = U.pillWidth(nil, self.shopPillV2)
    end
    local ends = tonumber(shop.dayEndsMs)
    if ends ~= nil then
        self.shopPillL3 = getText(T .. "Shop_PillReset")
        self.shopPillV3 = getText(T .. "Shop_ResetIn", U.durationText(math.max(0, ends - EC.now())))
        self.shopPillW3 = U.pillWidth(self.shopPillL3, self.shopPillV3)
    end
end

function M.placeShopPills(self)
    local g = self.g
    local x0 = g.bodyX + PAD
    return placePills(g.shopPillX, g.shopPillY, x0,
        x0 + textWidth(getText(T .. "Shop_Title"), UIFont.Medium) + PAD, g.shopPillRight, g.contentY,
        self.shopPillW1, self.shopPillW2, self.shopPillW3)
end

-- The mailbox pills: letters waiting, the slots used against the capacity (red when full; what
-- the total is made of is the pill's tooltip and the rules text), and a bulk claim's progress.
function M.mailPillText(self)
    local mail = C.mail
    self.mailPillV1, self.mailPillW1, self.mailPillV2, self.mailPillW2 = nil, nil, nil, nil
    self.mailPillV3, self.mailPillW3, self.mailPartsText = nil, nil, nil
    if mail == nil then return end
    local unclaimed = tonumber(mail.unclaimed) or 0
    self.mailPillL1 = getText(T .. "Mail_PillWaiting")
    self.mailPillV1 = tostring(unclaimed)
    self.mailPillT1 = unclaimed > 0 and "accent" or "textMuted"
    self.mailPillW1 = U.pillWidth(self.mailPillL1, self.mailPillV1)
    local usage = mail.usage
    if type(usage) == "table" and tonumber(usage.capacity) then
        local used, cap = tonumber(usage.used) or 0, tonumber(usage.capacity) or 0
        self.mailPillL2 = getText(T .. "Mail_PillCapacity")
        self.mailPillV2 = tostring(used) .. " / " .. tostring(cap)
        self.mailPillT2 = used >= cap and "negative" or "text"
        self.mailPillW2 = U.pillWidth(self.mailPillL2, self.mailPillV2)
        self.mailPartsText = getText(T .. "Mail_CapacityParts", tostring(tonumber(usage.unclaimed) or 0),
            tostring(tonumber(usage.marketListings) or 0), tostring(tonumber(usage.auctions) or 0))
    end
    local batch = self.mailBatch
    if batch ~= nil then
        self.mailPillV3 = getText(T .. "Mail_BatchProgress", tostring(batch.total - #batch.ids), tostring(batch.total))
        self.mailPillW3 = U.pillWidth(nil, self.mailPillV3)
    end
end

function M.placeMailPills(self)
    local g = self.g
    local x0 = g.bodyX + PAD
    return placePills(g.mailPillX, g.mailPillY, x0,
        x0 + textWidth(getText(T .. "Mail_Title"), UIFont.Medium) + PAD, g.mailPillRight, g.contentY,
        self.mailPillW1, self.mailPillW2, self.mailPillW3)
end

-- ---------- the rules texts (Panel:onRules opens them in the shared detail window) ----------
-- The shop: what the page trades in, how a per-item limit and its scope count, when the daily
-- limits reset (date, zone, countdown), why buyback is shut for this currency if it is, and what
-- the buyback takes.
function M.shopRules(self)
    local cur = self:shopCurrency()
    local parts = { getText(T .. "Shop_Note", C.currencyName(cur)), getText(T .. "Shop_RulesScope") }
    local day = M.shopDayNote(self)
    if day ~= "" then parts[#parts + 1] = day end
    local bb = C.shop and C.shop.buyback
    if self.shopHasBuyback and not W.buybackOpen(bb, cur) then
        parts[#parts + 1] = (type(bb) == "table" and bb.enabled == true)
            and getText(T .. "Shop_BuybackOffCurrency", C.currencyName(cur)) or getText(T .. "Shop_BuybackPaused")
    end
    parts[#parts + 1] = getText(T .. "Shop_SellRule")
    return table.concat(parts, "\n\n")
end

-- The mailbox: where letters come from and where they are claimed, what the slot total is made
-- of right now, and what a full mailbox stops.
function M.mailRules(self)
    local parts = { getText(T .. "Mail_Note") }
    if self.mailPartsText ~= nil then parts[#parts + 1] = self.mailPartsText end
    parts[#parts + 1] = getText(T .. "Mail_RulesSlots")
    return table.concat(parts, "\n\n")
end

-- ---------- layout ----------
-- Shop: the title row (pills, rules), search / category / currency, one full-workspace table.
-- The rules chip's place goes to g.rulesX / g.rulesY; L.layout's rules block shows it.
function M.layoutShop(self, workBottom, toolBand, capH, watch)
    local g = self.g
    local bx, bw = g.bodyX, g.bodyW
    local right, listX, listW = bx + bw - PAD, bx + 1, bw - 2
    local inner = listW - 12
    local isShop = self.tab == "Shop"
    local rules = self.rulesButton
    if isShop then
        g.rulesX = right - rules.width
        g.rulesY = g.contentY + math.floor((CARD_TITLE_H - rules.height) / 2)
    end
    g.shopPillX, g.shopPillY, g.shopPillRight = {}, {}, right - rules.width - 8
    M.shopPillText(self)
    g.shopPillRows = M.placeShopPills(self)
    g.shopHeadH = headHeight(g.shopPillRows)
    self.shopEntry:setVisible(isShop)
    self.shopEntry:setWidth(math.max(140, math.min(300, math.floor(bw * 0.28))))
    self.shopCatCombo:setVisible(isShop)
    self.shopCatCombo:setWidth(comboWidth(self.shopCatCombo, 120, math.floor(bw * 0.3)))
    -- the currency switch only exists where there is a second currency to switch to; it sits at
    -- the right end of the search row whenever that row has room for it
    local tabs = self.shopCurTabs
    local showTabs = isShop and tabs ~= nil and #W.currencyIds() > 1
    if tabs ~= nil then tabs:setVisible(showTabs) end
    local tools = { self.shopEntry, self.shopCatCombo }
    if showTabs then tools[3] = tabs end
    local y = placeRow(tools, bx + PAD, g.contentY + g.shopHeadH + 4 + capH, right, toolBand, capH + 6) + 6
    if showTabs and tabs.y == self.shopEntry.y + math.floor((self.shopEntry.height - tabs.height) / 2) then
        tabs:setX(right - tabs.width)
    end
    g.shopHeaderY = y
    local listY = y + ROW
    local listH = math.max(ROW * 2, workBottom - listY - PAD)
    self.shopList:setVisible(isShop)
    self.shopList:setX(listX); self.shopList:setY(listY)
    self.shopList.ecChromeH = listY - g.contentY + PAD
    local sc = self.shopList.cols
    sc.icon = PAD
    sc.name = PAD + ITEM_ICON + PAD
    sc.buyW = math.max(textWidth(getText(T .. "Shop_Buy")), textWidth(getText(T .. "Shop_SoldOutButton"))) + 22
    sc.buyX = math.max(sc.name, inner - sc.buyW - PAD)
    -- the sell chip (only painted on buyback rows) sits left of the buy chip; its width fits
    -- "Sell 1,000,000" so the columns never move when the faucet opens
    sc.sellW = textWidth(getText(T .. "Shop_Sell", "1,000,000")) + 16
    sc.sellX = math.max(sc.name, sc.buyX - 6 - sc.sellW)
    sc.remainR = sc.sellX - PAD
    -- the column holds the widest thing it ever paints: its header, a count, or "unlimited"
    sc.priceR = math.max(sc.name + PAD, sc.remainR - PAD
        - math.max(textWidth(getText(T .. "Shop_Col_Remaining")), textWidth("99,999"),
            textWidth(getText(T .. "Shop_Unlimited"))))
    -- the price column holds a price with its coin, or "not offered in this currency"
    local priceW = math.max(COIN_SMALL + 4 + textWidth("999,999"), textWidth(getText(T .. "Shop_NoQuote")))
    sc.nameW = math.max(0, sc.priceR - priceW - PAD - sc.name)
    if self.shopList.width ~= listW or self.shopList.height ~= listH then
        self.shopList:resize(listW, listH)
    end
    -- an empty catalog says what the page is for (no next step: only an admin can stock it)
    U.emptyState(self, "shop", listX, listY, listW, listH, getText(T .. "Shop_Empty"),
        getText(T .. "Shop_EmptyBody"))
    if isShop then watch[#watch + 1] = { kind = "shop", list = self.shopList } end
end

-- Mailbox: the title row (pills, rules, the gold claim-all) over one full-workspace table.
-- Picking a row reads it; the row's own claim button takes that one letter, and the gold button
-- claims every ready letter in one go. Both are real buttons: nothing on a row is hit-tested.
function M.layoutMail(self, workBottom, watch)
    local g = self.g
    local bx, bw = g.bodyX, g.bodyW
    local right, listX, listW = bx + bw - PAD, bx + 1, bw - 2
    local inner = listW - 12
    local isMail = self.tab == "Mail"
    local claimB = self.mailClaimAllButton
    claimB:setVisible(isMail)
    claimB:setX(right - claimB.width)
    claimB:setY(g.contentY + math.floor((CARD_TITLE_H - claimB.height) / 2))
    local rules = self.rulesButton
    if isMail then
        g.rulesX = claimB.x - 8 - rules.width
        g.rulesY = g.contentY + math.floor((CARD_TITLE_H - rules.height) / 2)
    end
    g.mailPillX, g.mailPillY, g.mailPillRight = {}, {}, claimB.x - 16 - rules.width
    M.mailPillText(self)
    g.mailPillRows = M.placeMailPills(self)
    g.mailHeadH = headHeight(g.mailPillRows)
    -- what the slot total is made of, on the capacity pill itself
    if isMail and self.mailPillW2 ~= nil then
        g.noteTip = { x = g.mailPillX[2], y = g.mailPillY[2], w = self.mailPillW2, h = CHIP_H,
            text = self.mailPartsText }
    end
    local listY = g.contentY + g.mailHeadH + 4
    g.mailListY = listY
    local listH = math.max(ROW * 2, workBottom - listY - PAD)
    self.mailList:setVisible(isMail)
    self.mailList:setX(listX); self.mailList:setY(listY)
    self.mailList.ecChromeH = listY - g.contentY + PAD
    local mc = self.mailList.cols
    mc.icon = PAD
    mc.name = PAD + ITEM_ICON + PAD
    mc.claimW = textWidth(getText(T .. "Mail_Claim")) + 22
    mc.claimX = math.max(mc.name, inner - mc.claimW - PAD)
    mc.timeR = mc.claimX - PAD
    mc.nameW = math.max(0, mc.timeR - textWidth(U.STAMP_SAMPLE) - PAD - mc.name)
    if self.mailList.width ~= listW or self.mailList.height ~= listH then
        self.mailList:resize(listW, listH)
    end
    U.emptyState(self, "mail", listX, listY, listW, listH, getText(T .. "Mail_EmptyTitle"),
        getText(T .. "Mail_EmptyBody"))
    if isMail then watch[#watch + 1] = { kind = "mail", list = self.mailList } end
end

-- ---------- paint ----------
-- The card with a heading as tall as its pill rows, and the title on the first of them.
local function pageCard(self, g, title, headH)
    card(self, g.bodyX, g.contentY, g.bodyW, g.workH, "", headH)
    text(self, title, g.bodyX + PAD, g.contentY + math.floor((CARD_TITLE_H - fontH.medium) / 2), "text", UIFont.Medium)
end

function M.drawShop(self)
    local g = self.g
    pageCard(self, g, getText(T .. "Shop_Title"), g.shopHeadH)
    if not C.shop then
        textRight(self, getText(T .. "Wallet_Loading"), g.shopPillRight,
            g.contentY + math.floor((CARD_TITLE_H - fontH.small) / 2), "textMuted")
        return
    end
    -- the countdown moves once a second: the pills are measured again then (never per frame),
    -- and a pill that now needs another row lays the page out again
    local second = math.floor(EC.now() / 1000)
    if self.shopPillSecond ~= second then
        self.shopPillSecond = second
        M.shopPillText(self)
        if M.placeShopPills(self) ~= g.shopPillRows then
            self:layout()
            g = self.g
        end
    end
    if self.shopPillV1 then
        U.drawPill(self, g.shopPillX[1], g.shopPillY[1], self.shopPillL1, self.shopPillV1, "text", self.shopPillCoin)
    end
    if self.shopPillV2 then U.drawPill(self, g.shopPillX[2], g.shopPillY[2], nil, self.shopPillV2, "warn") end
    if self.shopPillV3 then
        U.drawPill(self, g.shopPillX[3], g.shopPillY[3], self.shopPillL3, self.shopPillV3, "text")
    end
    text(self, getText(T .. "Shop_Category"), self.shopCatCombo.x,
        self.shopCatCombo.y - fontH.small - 2, "textMuted")
    local list = self.shopList
    local cols = list.cols
    local hx, hy = list.x, g.shopHeaderY
    fill(self, hx, hy, list.width, ROW, "well", "rect")
    local hty = hy + math.floor((ROW - fontH.small) / 2)
    text(self, getText(T .. "Shop_Col_Item"), hx + cols.name, hty, "textMuted")
    textRight(self, getText(T .. "Shop_Col_Price"), hx + cols.priceR, hty, "textMuted")
    textRight(self, getText(T .. "Shop_Col_Remaining"), hx + cols.remainR, hty, "textMuted")
    if #list:getItems() == 0 then
        if self.shopQuery or self.shopCat then
            text(self, getText(T .. "Shop_NoMatch"), hx + PAD, list.y + math.floor((ROW - fontH.small) / 2), "textMuted")
        else
            U.drawEmptyState(self, "shop")
        end
    end
end

function M.drawMail(self)
    local g = self.g
    pageCard(self, g, getText(T .. "Mail_Title"), g.mailHeadH)
    if not C.mail then
        text(self, getText(T .. "Wallet_Loading"), g.bodyX + PAD,
            self.mailList.y + math.floor((ROW - fontH.small) / 2), "textMuted")
        return
    end
    -- a bulk claim's progress and the counts move without a layout: measured once a second
    local second = math.floor(EC.now() / 1000)
    if self.mailPillSecond ~= second then
        self.mailPillSecond = second
        M.mailPillText(self)
        if M.placeMailPills(self) ~= g.mailPillRows then
            self:layout()
            g = self.g
        end
    end
    if self.mailPillV1 then
        U.drawPill(self, g.mailPillX[1], g.mailPillY[1], self.mailPillL1, self.mailPillV1, self.mailPillT1)
    end
    if self.mailPillV2 then
        U.drawPill(self, g.mailPillX[2], g.mailPillY[2], self.mailPillL2, self.mailPillV2, self.mailPillT2)
    end
    if self.mailPillV3 then U.drawPill(self, g.mailPillX[3], g.mailPillY[3], nil, self.mailPillV3, "accent") end
    if #self.mailList:getItems() == 0 then U.drawEmptyState(self, "mail") end
end

return M
