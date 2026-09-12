-- MinidoracatEconomyFor42 - the geometry and the paint of the Economy Center window (client).
--
-- Moved out of ECPanel.lua unchanged: every child position derives from the current width/height,
-- and every page is painted from the one geometry table the layout left behind (self.g), so the
-- measure and the paint can never disagree about where a column, a card or a band is.
--
-- These are the very methods of the window: they are declared as L.<name>(self, ...) and the owner
-- binds them onto its own class, so `self` is the window and a `self:` call inside them reaches the
-- owner's other methods exactly as before. The module holds no window, no control and no state of
-- its own, and it registers no event.
--
-- Engine references (snapshot 42.20.4-20260826):
--   UIElement anchors      UIElement.java:1411-1430 (children shift with the parent size; every
--                          child here is positioned explicitly in layout(), anchors stay default)
--   ISToolTip              ISToolTip.lua:56-62 - a tooltip whose owner is no longer visible takes
--                          itself down, so a closed or collapsed window leaves none behind

require "ISUI/ISCollapsableWindow"
require "ISUI/ISToolTip"

if not MinidoracatEconomy or not MinidoracatEconomy.Client or not MinidoracatEconomy.Client.UI then
    require "MinidoracatEconomy/ECWidgets"
end
require "MinidoracatEconomy/ECDatePicker"
require "MinidoracatEconomy/ECPanelWidgets"

local EC = MinidoracatEconomy
local C = EC.Client
local U = C.UI
local W = C.PanelWidgets
local DatePicker = C.DatePicker

local L = {}

local PAD, ROW, CHIP_H, COIN_SMALL, T = U.PAD, U.ROW, U.CHIP_H, U.COIN_SMALL, U.T
local CARD_TITLE_H = U.CARD_TITLE_H
local fontH = U.fontH
local fill, text, textWidth, fitText, textRight, textCentre, drawCoin = U.fill, U.text, U.textWidth, U.fitText, U.textRight, U.textCentre, U.drawCoin
local amountText, kindText, card = U.amountText, U.kindText, U.card
local ITEM_ICON = W.ITEM_ICON
local placeRow, listingColumns, comboWidth = W.placeRow, W.listingColumns, W.comboWidth
local HISTORY_KINDS, AUCTION_HISTORY_KINDS = W.HISTORY_KINDS, W.AUCTION_HISTORY_KINDS
local historyError = W.historyError

-- The size the window may never be dragged under, and the purely visual bands of its chrome.
local MIN_WIDTH, MIN_HEIGHT = 1000, 560
local STATUS_H = 24
local HEAD_H = 34                -- the compact header: page title + exact available amounts
local COIN_HEAD = 48             -- header currency icon (the header is measured from it)

-- Every table whose row carries a record opens the same floating window now (ECDetailWindow):
-- the wallet statement, the two rings, the mailbox, the catalog and the two trade tables. A row
-- is a read everywhere and the trade itself is the row's own action button, so nothing here
-- spells a record out differently from the rest -- and no page gives up a single row of its
-- table to do it.

-- Default size: the administration window's own ratio (these pages carry wide tables now too),
-- with a 40 px safety inset so the frame never sits under a screen edge. A size the player dragged
-- to is kept by ISLayoutManager and only clamped back into the screen; the reset chip and a
-- resolution change come back to this one.
--
-- The inset gives way before the minimum does. On a 1024-wide screen 84 % minus the inset is 984,
-- under MIN_WIDTH -- and minimumWidth would refuse it the moment the player touched the resize
-- grip, so the reset chip must not hand out a size the window cannot hold. There the frame touches
-- the screen edge instead, and only a screen narrower than the minimum itself goes below it.
local function axisSize(screen, ratio, minimum)
    local size = math.min(screen - 40, math.floor(screen * ratio))
    if size < minimum then size = math.min(screen, minimum) end
    return size
end

local function defaultSize()
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    return math.max(320, axisSize(sw, 0.84, MIN_WIDTH)), math.max(240, axisSize(sh, 0.86, MIN_HEIGHT))
end

-- The width the header's right block needs: every currency's exact available amount with its
-- coin. Measured in one place, so the layout can hand the left side the room that is really
-- left over (the page title on one row, the login account on the row under it) and the paint
-- can start the amounts at the very same x. Money is the one thing on this row that never
-- gives way, so it is measured first and everything else is fitted into the remainder.
local function headMoneyWidth(self)
    local total = 0
    for _, id in ipairs(self:currencies()) do
        local bal = C.wallet and C.wallet.balances and C.wallet.balances[id]
        total = total + textWidth(amountText(bal and bal.available or 0), UIFont.Medium)
            + COIN_HEAD + 6 + PAD
    end
    return total
end

-- ---------- the note band of the two trade pages ----------
-- Both trade pages put the server's fee quote under the card title, above search.
-- Wrap only into spare space; the mode bar opens the full, live quote in DetailWindow.
local NOTE_LINES_MAX = 3

local function noteLineH() return fontH.small + 2 end

-- The first line's own row. ROW is the height a one-line note always had, and at the shipped font
-- sizes it stays exactly that; a font taller than the row (the 38/45 accessibility sizes) grows it
-- instead of centring the text into negative space, which is what would otherwise lift the first
-- line back over the card title.
local function noteRowH() return math.max(ROW, fontH.small + 2) end

-- A note or a section label centred in its own ROW. At the shipped font sizes this is the very
-- offset these rows always used; at a font taller than the row (38/45) the text starts at the
-- row's top instead of above it, so it can never climb into the card title or into the line
-- above -- which is exactly the row the note band now ends on.
local function rowTextY(y) return y + math.floor(math.max(0, ROW - fontH.small) / 2) end

local function feeNote(key, info)
    if info == nil then return "" end
    return getText(T .. key, tostring(info.taxPercent or 0), tostring(info.feePercent or 0))
end

-- The real-world moment the shop's daily counters reset, read in the player's own zone: the
-- date and time, the zone itself, and how long is left. Daily shares turn over on a wall
-- clock, not at an in-game dawn, and "today" is never left to guesswork -- so all three are
-- spelled out and the band below wraps them instead of cutting any of them off. Empty while
-- no snapshot has arrived (or the server sends no reset time): an unknown is not a date.
local function shopDayNote(self)
    local shop = C.shop
    local ends = shop and tonumber(shop.dayEndsMs) or nil
    if ends == nil then return "" end
    local off = self.offsetMin or 0
    local abs = math.abs(off)
    local zone = "UTC" .. (off < 0 and "-" or "+") .. U.pad2(math.floor(abs / 60))
        .. ":" .. U.pad2(abs % 60)
    return getText(T .. "Shop_DayEnds", U.stampText(ends, off),
        U.durationText(math.max(0, ends - EC.now())), zone)
end

-- Preserve the table and pager first; spare room holds up to three fee-note lines.
local function noteBand(note, width, room)
    local lh, first = noteLineH(), noteRowH()
    if room < first then return {}, 0, note end
    local cap = math.max(1, math.min(NOTE_LINES_MAX, math.floor((room - first) / lh) + 1))
    local lines = U.wrapText(note, math.max(60, width), cap)
    local h = first + math.max(0, #lines - 1) * lh
    if table.concat(lines) ~= note then return lines, h, note end
    return lines, h
end

local function drawNote(self, lines, x, y)
    local ty = y + math.floor((noteRowH() - fontH.small) / 2)
    local lh = noteLineH()
    for i = 1, #(lines or {}) do
        text(self, lines[i], x, ty + (i - 1) * lh, "textMuted")
    end
end

-- Keep trading modes on one row; full labels remain in tooltips and keyboard descriptions.
local function fitModeRow(buttons, width)
    local cap = math.max(40, math.floor((width - 6 * (#buttons - 1)) / #buttons))
    for _, button in ipairs(buttons) do
        button:setWidth(math.min(textWidth(button.fullTitle or button.title) + 22, cap))
        U.setButtonTitle(button, button.fullTitle or button.title)
    end
end

-- Keep the debug compiler's cumulative local-variable table below its 200-entry limit.
function L.layoutMarket(self, workBottom, chipBand, toolBand, capH, watch)
    local g = self.g
    local bx, bw = g.bodyX, g.bodyW
    local x, y
    -- ----- market: the mode bar, then search / category / sort above one full-workspace table --
    local isMarket = self.tab == "Market"
    local mineMode = self.marketMode == "mine"
    local historyMode = self.marketMode == "history"
    local browseMode = isMarket and not mineMode and not historyMode
    g.marketBarY = g.contentY
    for _, b in ipairs(self.marketModeButtons) do b:setVisible(isMarket) end
    self.marketRefreshButton:setVisible(isMarket)
    self.marketListButton:setVisible(isMarket)   -- listing starts from either page
    local modeItems = {}
    for _, b in ipairs(self.marketModeButtons) do modeItems[#modeItems + 1] = b end
    modeItems[#modeItems + 1] = self.marketListButton
    modeItems[#modeItems + 1] = self.marketRefreshButton
    self.feeInfoButton:setVisible(browseMode)
    if browseMode then modeItems[#modeItems + 1] = self.feeInfoButton end
    fitModeRow(modeItems, bw)
    y = placeRow(modeItems, bx, g.marketBarY, bx + bw, math.max(chipBand, self.feeInfoButton.height), 6) + PAD
    g.marketCardX, g.marketCardW, g.marketCardY = bx, bw, y
    g.marketCardH = math.max(CARD_TITLE_H + ROW * 3, workBottom - y)
    local mktBottom = g.marketCardY + g.marketCardH
    local mktRight = g.marketCardX + g.marketCardW - PAD
    y = y + CARD_TITLE_H
    self.marketEntry:setVisible(browseMode)
    self.marketEntry:setWidth(math.max(140, math.min(300, math.floor(bw * 0.28))))
    -- the exact seller sits right of the keyword box: two conditions side by side, so it is
    -- plain that neither one stands in for the other
    local mktSeller = self.marketSellerPicker
    mktSeller:setVisible(browseMode)
    mktSeller.entry:setWidth(math.max(120, math.min(220, math.floor(bw * 0.2))))
    mktSeller.entry:setHeight(self.marketEntry.height)
    self.marketSellerClearButton:setVisible(browseMode)
    self.marketCatCombo:setVisible(browseMode)
    self.marketCatCombo:setWidth(comboWidth(self.marketCatCombo, 120, math.floor(bw * 0.28)))
    self.marketSortCombo:setVisible(browseMode)
    self.marketSortCombo:setWidth(comboWidth(self.marketSortCombo, 140, math.floor(bw * 0.3)))
    self.marketCurCombo:setVisible(browseMode)
    self.marketCurCombo:setWidth(comboWidth(self.marketCurCombo, 110, math.floor(bw * 0.25)))
    if browseMode then
        -- The fee note under the card title, the search row under the note. The toolbar is
        -- measured first (it wraps at a large font and in a narrow window), so what the note may
        -- take is what is really left over: a long locale costs neither the search row, nor the
        -- table's first row, nor the pager.
        local tools = { self.marketEntry, mktSeller.entry, self.marketSellerClearButton,
            self.marketCatCombo, self.marketCurCombo, self.marketSortCombo }
        g.marketToolH = capH + placeRow(tools, g.marketCardX + PAD, 0, mktRight, toolBand, capH + 6) + 6
        g.marketNoteLines, g.marketNoteH, g.marketNoteFull =
            noteBand(feeNote("Market_Note", self.marketInfo), g.marketCardW - PAD * 2,
                mktBottom - (g.marketCardY + CARD_TITLE_H) - g.marketToolH - ROW * 3 - PAD)
        if g.marketNoteFull ~= nil then
            -- the strip covers the card title row as well, so a card too small for a band of its
            -- own is still hovered where the note would have been
            g.noteTip = { x = g.marketCardX, y = g.marketCardY,
                w = g.marketCardW, h = CARD_TITLE_H + g.marketNoteH, text = g.marketNoteFull }
        end
        y = placeRow(tools, g.marketCardX + PAD, y + g.marketNoteH + capH, mktRight, toolBand, capH + 6) + 6
        -- the candidate list hangs under wherever the row placer left the box, and is capped to
        -- the card so it can never paint past it
        mktSeller:anchorDrop(mktBottom - (mktSeller.entry.y + mktSeller.entry.height) - PAD)
    else
        y = y + ROW                              -- the own-listings / record note line
    end
    g.marketHeaderY = y
    local mktListY = y + ROW
    local mktFooterH = mineMode and 0 or ROW
    local mktListW = g.marketCardW - 2
    local mktListH = math.max(ROW, mktBottom - mktListY - PAD - mktFooterH)
    self.marketList:setVisible(isMarket and not historyMode)
    self.marketList:setX(g.marketCardX + 1); self.marketList:setY(mktListY)
    self.marketList.ecChromeH = mktListY - g.contentY + PAD + mktFooterH
    local mktCols = self.marketList.cols
    local mktInner = mktListW - 12
    mktCols.icon = PAD
    mktCols.name = PAD + ITEM_ICON + PAD
    mktCols.actionW = math.max(textWidth(getText(T .. "Market_Buy")), textWidth(getText(T .. "Market_Cancel")),
        textWidth(getText(T .. "Market_Own"))) + 22
    mktCols.actionX = math.max(mktCols.name, mktInner - mktCols.actionW - PAD)
    -- One column strip per mode, read by the cells and by the header alike. The own-listings page
    -- drops the seller (it is always this player) and sorts by nothing, so its header is a caption
    -- over the very same edges; both pages carry the lot column, which is why the painted name no
    -- longer repeats the count, and its price column is the price of the whole lot.
    -- `soft` marks a column whose value the player can do without when the strip runs out of
    -- room (the count, the seller): it keeps its own title, while the price and the date keep
    -- their full width. A picked row spells every column out in its record window.
    local specs
    if mineMode then
        specs = {
            { key = "name", title = getText(T .. "Market_Col_Item"), sortable = false },
            { key = "qty", title = getText(T .. "Market_Col_Qty"), sample = "999",
              right = true, sortable = false, soft = true },
            { key = "cur", title = getText(T .. "Market_Col_Currency"), sample = W.currencySample(),
              right = true, sortable = false, soft = true },
            { key = "price", title = getText(T .. "Market_Col_LotPrice"), sample = "999,999",
              extra = COIN_SMALL + 4, right = true, sortable = false },
            { key = "expires", title = getText(T .. "Market_Col_Expires"), sample = U.STAMP_SAMPLE,
              right = true, sortable = false },
        }
    else
        specs = {
            { key = "name", title = getText(T .. "Market_Col_Item") },
            { key = "qty", title = getText(T .. "Market_Col_Qty"), sample = "999", right = true,
              soft = true },
            { key = "seller", title = getText(T .. "Market_Col_Seller"), sample = "mmmmmmmm",
              soft = true },
            -- a browse page may quote two currencies at once, so the row names its own
            { key = "cur", title = getText(T .. "Market_Col_Currency"), sample = W.currencySample(),
              right = true, sortable = false, soft = true },
            { key = "price", title = getText(T .. "Market_Col_Price"), sample = "999,999",
              extra = COIN_SMALL + 4, right = true },
            { key = "expires", title = getText(T .. "Market_Col_Expires"), sample = U.STAMP_SAMPLE,
              right = true },
        }
    end
    listingColumns(specs, mktCols.name, mktCols.actionX - PAD, textWidth("mmmmmmmm"), self.marketRows)
    self.marketHeaderHits = specs
    local mktBy = {}
    for _, c in ipairs(specs) do mktBy[c.key] = c end
    mktCols.nameW = mktBy.name.w
    mktCols.qtyR, mktCols.qtyW = mktBy.qty.textR, mktBy.qty.textW
    mktCols.sellerX = mktBy.seller and (mktBy.seller.x + PAD) or nil
    mktCols.sellerW = mktBy.seller and math.max(0, mktBy.seller.w - PAD) or nil
    mktCols.priceR, mktCols.priceW = mktBy.price.textR, mktBy.price.textW
    mktCols.expiresR, mktCols.expiresW = mktBy.expires.textR, mktBy.expires.textW
    mktCols.curR = mktBy.cur and mktBy.cur.textR or nil
    mktCols.curW = mktBy.cur and mktBy.cur.textW or nil
    mktCols.wrapDate = mktBy.expires.wrapDate
    if self.marketList.width ~= mktListW or self.marketList.height ~= mktListH then
        self.marketList:resize(mktListW, mktListH)
    end
    local header = self.marketHeader
    header:setVisible(isMarket and not historyMode)
    header:setX(self.marketList.x); header:setY(g.marketHeaderY)
    header:setWidth(mktListW); header:setHeight(ROW)

    -- history: the same card with the filter bar under the note line, two lines per row, no icon
    -- column (kind, item, amount, status) and the bar's own pager under the table
    local hist = self.marketHistoryList
    local histY, histH, showHistory = self.historyBar:layoutViewport(g.marketCardX + PAD, g.marketHeaderY,
        mktRight, mktBottom - PAD, isMarket and historyMode, g.marketCardY + math.max(0, (CARD_TITLE_H - CHIP_H) / 2))
    hist:setVisible(showHistory)
    hist:setX(g.marketCardX + 1); hist:setY(histY)
    hist.ecChromeH = histY - g.contentY + ROW
    local hCols = hist.cols
    local hInner = mktListW - 12
    local kindW = 0
    for _, k in ipairs(HISTORY_KINDS) do
        kindW = math.max(kindW, textWidth(getTextOrNull(T .. "Market_Kind_" .. k) or k))
    end
    hCols.kind = PAD
    hCols.name = hCols.kind + kindW + PAD
    hCols.status = math.max(hCols.name, hInner - textWidth(getText(T .. "Wallet_RolledBack")) - PAD)
    hCols.amountR = hCols.status - PAD
    hCols.nameW = math.max(0, hCols.amountR - textWidth("-999,999") - PAD - hCols.name)
    if hist.width ~= mktListW or hist.height ~= histH then hist:resize(mktListW, histH) end
    g.historyFooterY = self.historyBar.pagerY

    -- browse pager: the server's own paging, under the listing table
    g.marketFooterY = mktListY + mktListH + 2
    x = g.marketCardX + PAD + textWidth(getText(T .. "Market_Page", "99", "99")) + PAD
    for _, b in ipairs({ self.marketPrevButton, self.marketNextButton }) do
        b:setVisible(browseMode)
        b:setX(x); b:setY(g.marketFooterY + math.floor((ROW - CHIP_H) / 2))
        x = x + b.width + 6
    end
    if isMarket then
        watch[#watch + 1] = { kind = "market", list = self.marketList }
        watch[#watch + 1] = { kind = "history", list = hist }
    end
end

-- All child positions derive from the current width/height; called when the size changes, the page
-- changes, the navigation is folded, the status band appears or the currency list arrives.
--
-- Every page is laid out against the workspace the navigation left over (g.bodyX / g.bodyW), never
-- against the window: a rail that folds from its expanded width to 56 px moves every table with
-- it. There is no second permanent side panel any more — the filters of the shop and the market
-- sit above their table, and the tables themselves span the whole workspace.
function L.layout(self)
    local w, h = self.width, self.height
    local walletFiltersVisible = self.walletBar.fromEntry:getIsVisible()
    local th = self:titleBarHeight()
    local rh = self.resizable and self:resizeWidgetHeight() or 0
    local open = not self.isCollapsed
    local band = self:statusBand()
    local g = {}
    g.headY = th
    -- Stack identity under the title when both fit beside the coin. At larger fonts use one
    -- row; the account keeps its space and the redundant page title takes what remains.
    g.idH = math.max(24, fontH.small + 6)
    g.headH = math.max(HEAD_H, fontH.medium + 8, COIN_HEAD + 8)
    g.identityInline = fontH.medium + g.idH + 10 > g.headH
    g.titleY = g.headY + math.floor((g.headH - fontH.medium) / 2)
    if g.identityInline then
        g.idY = g.headY + math.floor((g.headH - g.idH) / 2)
    else
        g.titleY = g.headY + math.floor((g.headH - fontH.medium - g.idH - 2) / 2)
        g.idY = g.titleY + fontH.medium + 2
    end
    g.headTextW = math.max(0, w - PAD * 4 - headMoneyWidth(self))
    g.statusY = th + g.headH
    g.statusH = band and math.max(STATUS_H, fontH.small + 6) or 0
    g.contentY = g.statusY + g.statusH + 4
    local st = C.rewards
    g.footerH = (self.tab == "Rewards" and st and (tonumber(st.serverCap) or 0) > 0) and ROW or 0
    g.contentH = math.max(ROW * 4, h - g.contentY - rh - PAD - g.footerH)

    -- The Admin entry appears and disappears with the right, and the navigation measures and
    -- places only what is visible: the permission is answered before either call.
    self.adminAccess = C.AdminPanel.canRead()
    if self.adminNavButton then self.adminNavButton:setVisible(self.adminAccess) end
    local nav = self.nav
    g.navX = PAD
    g.navW = nav:widthFor(w)
    g.bodyX = g.navX + g.navW + PAD
    g.bodyW = math.max(200, w - g.bodyX - PAD)
    self.g = g

    -- ----- the fixed header identity -----
    -- The account this window belongs to, on every page: a screenshot of any tab names its
    -- owner. The chip *is* the label, so what is on screen and what a press opens in full are
    -- one value (Panel:onIdentity) -- and it is fitted into the room the money column left, so
    -- it can never climb over a balance, a coin or the title bar's own buttons.
    local idB = self.identityButton
    local account = self:username()
    self.identityName = account
    local idLabel = (type(account) == "string") and getText(T .. "Player_Identity", account)
        or getText(T .. "Player_IdentityUnknown")
    idB:setVisible(open)
    idB:setEnable(type(account) == "string")
    idB:setHeight(g.idH)
    local idWidth = math.max(40, math.min(textWidth(idLabel) + 20, g.headTextW))
    local titleWidth = textWidth(getText(T .. "Tab_" .. tostring(self.tab)), UIFont.Medium)
    g.headerTitleW = g.identityInline and math.min(titleWidth, math.max(0, g.headTextW - idWidth - PAD)) or g.headTextW
    local idOffset = (g.identityInline and g.headerTitleW > 0) and (g.headerTitleW + PAD) or 0
    idB:setWidth(idWidth)
    idB:setX(math.max(0, PAD * 2 - 10 + idOffset))
    g.headerUsedW = g.identityInline and (idOffset + idWidth) or math.max(titleWidth, idWidth)
    idB:setY(g.idY - 1)
    U.setButtonTitle(idB, idLabel)

    -- title bar: the rail toggle left of the window title (so it is reachable in both states and
    -- costs none of the vertical rows), the reset chip left of the vanilla pin/collapse button
    -- (both are th-2 square at w-1-(th-2))
    local dw, dh = defaultSize()
    local rb = self.resetSizeButton
    rb:setVisible((w ~= dw or h ~= dh) and open)
    rb:setX(w - 1 - (th - 2) - 6 - rb.width)
    rb:setY(math.floor((th - rb.height) / 2))
    local toggle = self.navToggle
    local ts = math.max(24, th - 8)
    toggle:setVisible(open)
    toggle:setWidth(ts); toggle:setHeight(ts)
    toggle:setX(self.closeButton.x + self.closeButton.width + 8)
    toggle:setY(math.floor((th - ts) / 2))
    g.titleX = toggle.x + toggle.width + PAD

    nav:setVisible(open and self.shown == true)
    nav:setX(g.navX); nav:setY(g.contentY)
    nav:layout(g.navW, g.contentH)

    -- the preference popover: centred over the workspace, so it is on screen at every window size
    local pop = self.prefsPopover
    pop:setX(math.max(PAD, math.min(w - PAD - pop.width, g.bodyX + math.floor((g.bodyW - pop.width) / 2))))
    pop:setY(g.contentY + PAD)
    if not open then pop:setVisible(false) end

    local bx, bw = g.bodyX, g.bodyW
    local right = bx + bw - PAD
    local listX, listW = bx + 1, bw - 2
    local inner = listW - 12
    local chipBand = math.max(CHIP_H, fontH.small + 10)
    local toolBand = math.max(CHIP_H, self.shopEntry.height)
    local capH = fontH.small + 4
    local watch = {}
    local x, y
    local isWallet = self.tab == "Wallet"
    local isRewards = self.tab == "Rewards"
    local balances = isWallet and self.walletDetails
    local walletLineH = self.list.rowHeight
    g.walletHeaderH = math.max(CARD_TITLE_H, fontH.medium + 8)
    for _, buttons in ipairs({ self.periodButtons, self.walletBar.kindButtons, self.walletBar.sortButtons,
        { self.walletDetailsButton, self.walletFilterButton, self.walletBar.prevButton,
            self.walletBar.nextButton, self.detailCopyButton,
            self.historyRetryButton, self.mailClaimAllButton } }) do
        for _, button in ipairs(buttons) do
            local height = math.max(CHIP_H, fontH.small + 8)
            if button.height ~= height then button:setHeight(height) end
        end
    end
    local chromeTop = g.contentY + g.walletHeaderH
    local chipRow = math.max(CHIP_H, fontH.small + 8)
    local periodBottom = placeRow(self.periodButtons,
        bx + PAD + textWidth(getText(T .. "Wallet_Period")) + PAD,
        chromeTop, right, chipBand, 6) + 6
    local filtersBottom = self.walletBar:layout(bx + PAD, periodBottom, right, false) + 6

    -- ----- the whole-page reader -----
    -- No page keeps a preview band any more: a picked row opens the floating record window
    -- (ECDetailWindow), so every table keeps its full height, its filters, its page and its
    -- scroll whatever the player is reading. What is left here are the two pages that *are* a
    -- reading surface -- the wallet's balance view and the Rewards page -- and they place the box
    -- over their own card with the copy chip on the row under it.
    local fullReader = balances or isRewards
    g.detailH = (open and fullReader) and chipRow or 0
    g.detailY = g.contentY + g.contentH - g.detailH
    local resultsBottom = g.detailY - 6
    self.walletCompact = resultsBottom - filtersBottom - walletLineH * 3 - 2 < walletLineH * 3
    local sheet = isWallet and not balances and self.walletCompact and self.walletFiltersOpen
    local showFilters = isWallet and not balances and (not self.walletCompact or sheet)
    local showList = isWallet and not balances and not sheet
    if sheet then g.detailH, g.detailY = 0, g.contentY + g.contentH end
    local hasTable = not isRewards and not balances and not sheet
    g.workH = hasTable and math.max(ROW * 3, g.contentH - g.detailH - 6) or g.contentH
    local workBottom = g.contentY + g.workH
    local copy, box = self.detailCopyButton, self.detailBox
    local detailVisible = open and not sheet and fullReader
    copy:setVisible(detailVisible)
    copy:setX(g.bodyX + g.bodyW - copy.width)
    copy:setY(g.detailY + math.floor((g.detailH - copy.height) / 2))
    box:setVisible(detailVisible)
    local boxX, boxY = g.bodyX, g.detailY
    local boxW = math.max(80, copy.x - 6 - g.bodyX)
    local boxH = math.max(1, g.detailH)
    if balances then
        boxX, boxY, boxW, boxH = listX, chromeTop, listW, math.max(1, copy.y - 6 - chromeTop)
    end

    -- Full filters, a compact filter sheet, or the full balance reader; never stacked into zero room.
    local fold, filt = self.walletDetailsButton, self.walletFilterButton
    fold.active = balances
    fold:setVisible(isWallet)
    fold:setX(right - fold.width)
    fold:setY(g.contentY + math.floor((g.walletHeaderH - fold.height) / 2))
    filt.active = sheet
    filt:setVisible(isWallet and not balances and self.walletCompact)
    filt:setX(fold.x - 6 - filt.width); filt:setY(fold.y)
    g.walletTitleW = (filt:getIsVisible() and filt.x or fold.x) - bx - PAD * 2
    g.walletFilters, g.walletList, g.walletBalances = showFilters, showList, balances
    g.walletChipY = chromeTop
    for _, b in ipairs(self.periodButtons) do b:setVisible(showFilters) end
    if walletFiltersVisible and not showFilters then
        DatePicker.close(self)
        self.walletBar.fromEntry:unfocus()
        self.walletBar.toEntry:unfocus()
        if self.walletBar.searchEntry then self.walletBar.searchEntry:unfocus() end
    end
    self.walletBar:layout(bx + PAD, periodBottom, right, showFilters)
    g.tableHeaderY = self.walletCompact and chromeTop or filtersBottom
    local listY = g.tableHeaderY + walletLineH
    local listH = math.max(walletLineH, workBottom - listY - walletLineH * 2 - 2)
    self.list:setVisible(showList)
    self.list:setX(listX); self.list:setY(listY)
    -- what this page needs above the first row, plus the pager and the note line under the last
    self.list.ecChromeH = listY - g.contentY + walletLineH * 2
    -- When the measured columns cannot fit, keep timestamp and exact amount on the row. Picking
    -- one still spells every field, currency name and rollback status out in its record window.
    local cols = self.list.cols
    local function colW(header, sample) return math.max(textWidth(getText(T .. header)), textWidth(sample)) + PAD * 2 end
    cols.time = PAD
    cols.kind = cols.time + colW("Wallet_Col_Time", U.STAMP_SAMPLE)
    cols.desc = cols.kind + colW("Wallet_Col_Kind", kindText("admin_adjust"))
    cols.status = inner - colW("Wallet_Col_Status", getText(T .. "Wallet_RolledBack")) + PAD
    cols.balanceR = cols.status - PAD
    cols.amountR = cols.balanceR - colW("Wallet_Col_Balance", "999,999,999")
    cols.descW = math.max(0, cols.amountR - (self.statementAmountW or 0) - cols.desc)
    cols.compact = cols.descW == 0
    if cols.compact then
        cols.amountR = inner - PAD
        cols.timeW = math.max(0, cols.amountR - cols.time - (self.statementValueW or 0) - COIN_SMALL - PAD * 2)
    else
        cols.timeW = nil
    end
    if self.list.width ~= listW or self.list.height ~= listH then self.list:resize(listW, listH) end
    g.listBottom = listY + listH
    self.walletBar:layoutPager(listX + PAD, g.listBottom + 2, listX + listW - PAD, showList, walletLineH)
    g.walletNoteY = g.listBottom + 2 + walletLineH
    if isWallet and not balances and not sheet then watch[#watch + 1] = { kind = "statement", list = self.list } end

    -- Rewards reuse the full-value reader: every configured milestone remains scrollable and
    -- copyable, while claim and history stay outside it as always-reachable actions.
    self.claimButton:setVisible(isRewards)
    self.claimButton:setWidth(math.max(160, math.min(420, bw - PAD * 2)))
    local more = self.moreButton
    more:setVisible(isRewards)
    local rewardsTop = placeRow({ self.claimButton, more }, bx + PAD,
        g.contentY + CARD_TITLE_H + 6, right, math.max(self.claimButton.height, chipBand), 6) + PAD
    if isRewards then
        copy:setY(g.contentY + g.contentH - copy.height)
        boxX, boxY, boxW, boxH = listX, rewardsTop, listW, math.max(1, copy.y - PAD - rewardsTop)
    end

    -- ----- shop: search and category above one full-workspace table -----
    local isShop = self.tab == "Shop"
    self.shopEntry:setVisible(isShop)
    self.shopEntry:setWidth(math.max(140, math.min(300, math.floor(bw * 0.28))))
    self.shopCatCombo:setVisible(isShop)
    self.shopCatCombo:setWidth(comboWidth(self.shopCatCombo, 120, math.floor(bw * 0.3)))
    -- the two chips act on the row the table has picked, and that row carries its own buy and
    -- sell buttons
    self.shopBuyButton:setVisible(isShop)
    self.shopSellButton:setVisible(isShop)
    self.shopCurCombo:setVisible(isShop)
    self.shopCurCombo:setWidth(comboWidth(self.shopCurCombo, 110, math.floor(bw * 0.25)))
    -- The reset note is a band of its own under the card title, wrapped like the trade pages'
    -- fee note: the real-world date, the zone it is read in and the countdown all have to be
    -- readable at every font size, so the toolbar below is measured first and the note takes
    -- what is really left -- never a line clipped at the category box.
    local shopTools = { self.shopEntry, self.shopCatCombo, self.shopCurCombo, self.shopBuyButton,
        self.shopSellButton }
    local shopToolH = capH + placeRow(shopTools, bx + PAD, 0, right, toolBand, capH + 6) + 6
    g.shopNoteY = g.contentY + CARD_TITLE_H
    local shopNote = shopDayNote(self)
    if shopNote == "" then
        g.shopNoteLines, g.shopNoteH, g.shopNoteFull = nil, 0, nil
    else
        g.shopNoteLines, g.shopNoteH, g.shopNoteFull = noteBand(shopNote, bw - PAD * 2,
            workBottom - g.shopNoteY - shopToolH - ROW * 3 - PAD)
        if g.shopNoteFull ~= nil and isShop then
            g.noteTip = { x = bx, y = g.contentY, w = bw,
                h = CARD_TITLE_H + g.shopNoteH, text = g.shopNoteFull }
        end
    end
    y = placeRow(shopTools, bx + PAD, g.shopNoteY + g.shopNoteH + 4 + capH, right, toolBand,
        capH + 6) + 6
    g.shopHeaderY = y
    local shopListY = y + ROW
    local shopListH = math.max(ROW * 2, workBottom - shopListY - PAD)
    self.shopList:setVisible(isShop)
    self.shopList:setX(listX); self.shopList:setY(shopListY)
    self.shopList.ecChromeH = shopListY - g.contentY + PAD
    local sc = self.shopList.cols
    sc.icon = PAD
    sc.name = PAD + ITEM_ICON + PAD
    sc.buyW = textWidth(getText(T .. "Shop_Buy")) + 22
    sc.buyX = math.max(sc.name, inner - sc.buyW - PAD)
    -- the sell chip (only painted on buyback rows) sits left of the buy chip; its width fits
    -- "Sell 1,000,000" so the columns never move when the faucet opens
    sc.sellW = textWidth(getText(T .. "Shop_Sell", "1,000,000")) + 16
    sc.sellX = math.max(sc.name, sc.buyX - 6 - sc.sellW)
    sc.remainR = sc.sellX - PAD
    sc.priceR = math.max(sc.name + PAD, sc.remainR
        - math.max(textWidth(getText(T .. "Shop_Col_Remaining")), textWidth(getText(T .. "Shop_SoldOut"))) - PAD)
    sc.nameW = math.max(0, sc.priceR - COIN_SMALL - 4 - textWidth("999,999") - PAD - sc.name)
    if self.shopList.width ~= listW or self.shopList.height ~= shopListH then
        self.shopList:resize(listW, shopListH)
    end
    if isShop then watch[#watch + 1] = { kind = "shop", list = self.shopList } end

    -- ----- mailbox: one full-workspace table (name, source, time, claim) -----
    -- Picking a row reads it; the row's own claim button takes that one letter, and the toolbar
    -- chip claims every ready letter in one go. Both are real buttons, so nothing about a
    -- mailbox row is hit-tested any more.
    local isMail = self.tab == "Mail"
    local claimB = self.mailClaimAllButton
    claimB:setVisible(isMail)
    g.mailActionH = math.max(ROW, claimB.height)
    -- What the mailbox total is made of (letters waiting, listings parked, auctions running)
    -- gets a row of its own, the whole card wide. It used to share the title row and was
    -- dropped whenever it did not fit, and "6 / 50" on its own reads as six unread letters.
    local mailUsage = C.mail and C.mail.usage or nil
    g.mailPartsY = g.contentY + CARD_TITLE_H
    g.mailPartsH = (isMail and mailUsage ~= nil and tonumber(mailUsage.capacity) ~= nil) and ROW or 0
    g.mailActionY = g.mailPartsY + g.mailPartsH
    claimB:setX(right - claimB.width)
    claimB:setY(g.mailActionY + math.floor((g.mailActionH - claimB.height) / 2))
    local mailListY = g.mailActionY + g.mailActionH + 4
    g.mailListY = mailListY
    local mailListH = math.max(ROW * 2, workBottom - mailListY - PAD)
    self.mailList:setVisible(isMail)
    self.mailList:setX(listX); self.mailList:setY(mailListY)
    self.mailList.ecChromeH = mailListY - g.contentY + PAD
    local mc = self.mailList.cols
    mc.icon = PAD
    mc.name = PAD + ITEM_ICON + PAD
    mc.claimW = textWidth(getText(T .. "Mail_Claim")) + 22
    mc.claimX = math.max(mc.name, inner - mc.claimW - PAD)
    mc.timeR = mc.claimX - PAD
    mc.nameW = math.max(0, mc.timeR - textWidth(U.STAMP_SAMPLE) - PAD - mc.name)
    if self.mailList.width ~= listW or self.mailList.height ~= mailListH then
        self.mailList:resize(listW, mailListH)
    end
    if isMail then watch[#watch + 1] = { kind = "mail", list = self.mailList } end

    self:layoutMarket(workBottom, chipBand, toolBand, capH, watch)

    -- ----- auction: the mode bar, then search / sort over one full-workspace card -----
    -- Browsing is a sortable table with the server's pager under it; "my auctions" splits the card
    -- into the two lists (what the player sells, what they bid on), and the record page swaps the
    -- whole table for the two-line history list with its own filter bar. All three item tables
    -- read one column set (they are the same width), so the numbers below are computed once.
    local isAuction = self.tab == "Auction"
    local aucMine = self.auctionMode == "mine"
    local aucHistory = self.auctionMode == "history"
    local aucTable = isAuction and not aucMine and not aucHistory
    local aucBand = math.max(CHIP_H, self.auctionEntry.height)
    g.auctionBarY = g.contentY
    for _, b in ipairs(self.auctionModeButtons) do b:setVisible(isAuction) end
    self.auctionRefreshButton:setVisible(isAuction)
    self.auctionCreateButton:setVisible(isAuction)
    self.auctionEntry:setVisible(isAuction and not aucMine)
    self.auctionEntry:setWidth(math.max(140, math.min(280, math.floor(bw * 0.26))))
    -- the seller box belongs to the browse table only: the record page is a different question
    local aucSeller = self.auctionSellerPicker
    aucSeller:setVisible(aucTable)
    aucSeller.entry:setWidth(math.max(120, math.min(200, math.floor(bw * 0.2))))
    aucSeller.entry:setHeight(self.auctionEntry.height)
    self.auctionSellerClearButton:setVisible(aucTable)
    self.auctionSortCombo:setVisible(aucTable)
    self.auctionSortCombo:setWidth(comboWidth(self.auctionSortCombo, 140, math.floor(bw * 0.3)))
    self.auctionCurCombo:setVisible(aucTable)
    self.auctionCurCombo:setWidth(comboWidth(self.auctionCurCombo, 110, math.floor(bw * 0.25)))
    if aucTable then
        local clear = self.auctionSellerClearButton
        clear:setWidth(math.min(textWidth(clear.fullTitle) + 22,
            math.max(40, bw - PAD * 2 - self.auctionEntry.width - aucSeller.entry.width - self.auctionSortCombo.width - 18)))
        U.setButtonTitle(clear, clear.fullTitle)
    end
    local aucItems = {}
    for _, b in ipairs(self.auctionModeButtons) do aucItems[#aucItems + 1] = b end
    aucItems[#aucItems + 1] = self.auctionCreateButton
    aucItems[#aucItems + 1] = self.auctionRefreshButton
    if isAuction and not aucHistory then
        self.feeInfoButton:setVisible(true)
        aucItems[#aucItems + 1] = self.feeInfoButton
    end
    fitModeRow(aucItems, bw)
    y = placeRow(aucItems, bx, g.auctionBarY, bx + bw, math.max(aucBand, self.feeInfoButton.height), 6) + PAD
    g.auctionCardX, g.auctionCardW, g.auctionCardY = bx, bw, y
    g.auctionCardH = math.max(CARD_TITLE_H + ROW * 3, workBottom - y)
    local aucBottom = g.auctionCardY + g.auctionCardH
    local aucRight = g.auctionCardX + g.auctionCardW - PAD
    local toolItems = { self.auctionEntry }
    if aucTable then
        toolItems[#toolItems + 1] = aucSeller.entry
        toolItems[#toolItems + 1] = self.auctionSellerClearButton
    end
    if aucTable then toolItems[#toolItems + 1] = self.auctionCurCombo end
    toolItems[#toolItems + 1] = self.auctionSortCombo
    -- the same wrapped fee band the market page carries, in the same place and measured the same
    -- way: the toolbar's own wrapped height first, the note only in what is left
    g.auctionToolH = 0
    if isAuction and not aucMine then
        g.auctionToolH = capH + placeRow(toolItems, g.auctionCardX + PAD, 0, aucRight, aucBand, capH + 6) + 6
    end
    g.auctionNoteLines, g.auctionNoteH, g.auctionNoteFull =
        noteBand(feeNote("Auction_Note", self.auctionInfo), g.auctionCardW - PAD * 2,
            aucBottom - (g.auctionCardY + CARD_TITLE_H) - g.auctionToolH - ROW * 4 - 2)
    if aucHistory then g.auctionNoteH = ROW end        -- the record page has a note of its own
    if isAuction and not aucHistory and g.auctionNoteFull ~= nil then
        g.noteTip = { x = g.auctionCardX, y = g.auctionCardY,
            w = g.auctionCardW, h = CARD_TITLE_H + g.auctionNoteH, text = g.auctionNoteFull }
    end
    y = y + CARD_TITLE_H + g.auctionNoteH              -- the note line under the card title
    if isAuction and not aucMine then
        y = placeRow(toolItems, g.auctionCardX + PAD, y + capH, aucRight, aucBand, capH + 6) + 6
        if aucTable then
            aucSeller:anchorDrop(aucBottom - (aucSeller.entry.y + aucSeller.entry.height) - PAD)
        end
    end
    g.auctionHeaderY = y
    g.auctionListY = y + ROW
    -- The pager is placed *under the table*, the way the market page does it, instead of being
    -- pinned to the card bottom and then overrun: a toolbar that wrapped (a large font, a long
    -- locale, one control more) shortens the table, and the table never grows into the row the
    -- pager owns. It keeps one operable row at the floor, and the pager stays inside the
    -- workspace even when the card itself was measured taller than what is left.
    local aucFooterH = aucTable and ROW or 0
    local aucListH = math.max(ROW, aucBottom - g.auctionListY - PAD - aucFooterH)
    aucListH = math.min(aucListH, math.max(ROW, workBottom - g.auctionListY - 2 - aucFooterH))
    g.auctionFooterY = g.auctionListY + aucListH + 2

    local aucListW = g.auctionCardW - 2
    local aCols = self.auctionList.cols
    aCols.icon = PAD
    aCols.name = PAD + ITEM_ICON + PAD
    aCols.qtyR, aCols.sellerX, aCols.sellerW = nil, nil, nil   -- both live in the name block
    aCols.actionW = math.max(textWidth(getText(T .. "Auction_Bid")), textWidth(getText(T .. "Auction_Own")),
        textWidth(getText(T .. "Auction_Leading")), textWidth(getText(T .. "Auction_Outbid")),
        textWidth(getText(T .. "Auction_Raise")),
        textWidth(getText(T .. "Auction_Ended")), textWidth(getText(T .. "Auction_CancelTitle"))) + 22
    aCols.actionX = math.max(aCols.name, aucListW - 12 - aCols.actionW - PAD)
    -- the record button lives left of the action one on every auction row (browse and mine
    -- alike): one column set, so the paint and the button can never disagree about where it is
    aCols.histLabel = getText(T .. "Auction_History")
    aCols.histW = textWidth(aCols.histLabel) + 22
    aCols.histX = math.max(aCols.name, aCols.actionX - 6 - aCols.histW)
    -- the same shared strip the market table uses: three right-aligned columns between the name
    -- block and the record chip, each with an arrow gutter of its own. The bid count and the
    -- countdown are the soft ones here -- the row's record window carries both in full -- while
    -- the current bid keeps its own width.
    local aSpecs = {
        { key = "name", title = getText(T .. "Market_Col_Item") },
        -- the currency each auction was fixed in: a mixed board quotes more than one
        { key = "cur", title = getText(T .. "Market_Col_Currency"), sample = W.currencySample(),
          right = true, sortable = false, soft = true },
        { key = "price", title = getText(T .. "Auction_Col_Bid"), extra = COIN_SMALL + 4,
          sample = getText(T .. "Auction_StartsAt", "999,999"), right = true },
        { key = "bids", title = getText(T .. "Auction_Col_Bids"), soft = true,
          sample = getText(T .. "Auction_NoBids"), right = true },
        { key = "ending", title = getText(T .. "Auction_Col_Ends"), right = true, soft = true,
          sample = getText(T .. "Auction_Ends_In", getText(T .. "Time_HM", "99", "59")) },
    }
    if aucMine then
        listingColumns(aSpecs, aCols.name, aCols.histX - PAD, textWidth("mmmmmmmm"),
            self.auctionSellRows, self.auctionBidRows)
    else
        listingColumns(aSpecs, aCols.name, aCols.histX - PAD, textWidth("mmmmmmmm"), self.auctionRows)
    end
    self.auctionHeaderHits = aSpecs
    aCols.nameW = aSpecs[1].w
    aCols.curR, aCols.curW = aSpecs[2].textR, aSpecs[2].textW
    aCols.priceR, aCols.priceW = aSpecs[3].textR, aSpecs[3].textW
    aCols.bidsR, aCols.bidsW = aSpecs[4].textR, aSpecs[4].textW
    aCols.expiresR, aCols.expiresW = aSpecs[5].textR, aSpecs[5].textW

    self.auctionHeader:setVisible(aucTable)
    self.auctionHeader:setX(g.auctionCardX + 1); self.auctionHeader:setY(g.auctionHeaderY)
    self.auctionHeader:setWidth(aucListW); self.auctionHeader:setHeight(ROW)
    -- (the table height was measured with the pager above, so the two can never overlap)
    self.auctionList:setVisible(aucTable)
    self.auctionList:setX(g.auctionCardX + 1); self.auctionList:setY(g.auctionListY)
    self.auctionList.ecChromeH = g.auctionListY - g.contentY + ROW
    if self.auctionList.width ~= aucListW or self.auctionList.height ~= aucListH then
        self.auctionList:resize(aucListW, aucListH)
    end
    -- "my auctions": the selling half over the bidding half, one section label each
    g.aucSellLabelY = g.auctionCardY + CARD_TITLE_H + g.auctionNoteH
    g.aucSellY = g.aucSellLabelY + ROW
    g.aucSellH = math.max(ROW, math.floor((aucBottom - PAD - g.aucSellY - ROW) / 2))
    g.aucBidLabelY = g.aucSellY + g.aucSellH
    g.aucBidY = g.aucBidLabelY + ROW
    g.aucBidH = math.max(ROW, aucBottom - PAD - g.aucBidY)
    for _, spec in ipairs({ { self.auctionSellList, g.aucSellY, g.aucSellH },
        { self.auctionBidList, g.aucBidY, g.aucBidH } }) do
        spec[1]:setVisible(isAuction and aucMine)
        spec[1]:setX(g.auctionCardX + 1); spec[1]:setY(spec[2])
        spec[1].ecChromeH = spec[2] - g.contentY + PAD
        if spec[1].width ~= aucListW or spec[1].height ~= spec[3] then spec[1]:resize(aucListW, spec[3]) end
    end
    -- the record page: the filter bar, the two-line list and the bar's own pager (the snapshot is
    -- paged on the client, exactly like the market ring)
    local ahist = self.auctionHistoryList
    local ahY, ahH, showAuctionHistory = self.auctionHistoryBar:layoutViewport(g.auctionCardX + PAD, g.auctionHeaderY,
        aucRight, aucBottom - PAD, isAuction and aucHistory, g.auctionCardY + math.max(0, (CARD_TITLE_H - CHIP_H) / 2))
    ahist:setVisible(showAuctionHistory)
    ahist:setX(g.auctionCardX + 1); ahist:setY(ahY)
    ahist.ecChromeH = ahY - g.contentY + ROW
    local ahCols = ahist.cols
    local ahInner = aucListW - 12
    local aKindW = 0
    for _, k in ipairs(AUCTION_HISTORY_KINDS) do
        aKindW = math.max(aKindW, textWidth(getTextOrNull(T .. "Market_Kind_" .. k) or k))
    end
    ahCols.kind = PAD
    ahCols.name = ahCols.kind + aKindW + PAD
    ahCols.status = math.max(ahCols.name, ahInner - textWidth(getText(T .. "Wallet_RolledBack")) - PAD)
    ahCols.amountR = ahCols.status - PAD
    ahCols.nameW = math.max(0, ahCols.amountR - textWidth("999,999,999") - PAD - ahCols.name)
    if ahist.width ~= aucListW or ahist.height ~= ahH then ahist:resize(aucListW, ahH) end
    g.aucHistoryFooterY = self.auctionHistoryBar.pagerY
    x = g.auctionCardX + PAD + textWidth(getText(T .. "Market_Page", "99", "99")) + PAD
    for _, b in ipairs({ self.auctionPrevButton, self.auctionNextButton }) do
        b:setVisible(aucTable)
        b:setX(x); b:setY(g.auctionFooterY + math.floor((ROW - CHIP_H) / 2))
        x = x + b.width + 6
    end
    if isAuction then
        watch[#watch + 1] = { kind = "auction", list = self.auctionList }
        watch[#watch + 1] = { kind = "auction", list = self.auctionSellList }
        watch[#watch + 1] = { kind = "auction", list = self.auctionBidList }
        watch[#watch + 1] = { kind = "history", list = ahist }
    end

    -- ----- the public board -----
    -- Its own module owns its controls, its geometry and its paint; the window only tells it
    -- whether it is on screen and how much workspace it may use.
    local board = self.leaderboard
    local isBoard = self.tab == "Leaderboard"
    board:setVisible(isBoard and open)
    board:layout(bx, g.contentY, bw, g.contentH)

    local fee = self.feeInfoButton
    fee:setVisible(fee:getIsVisible() and open)
    fee:setEnable(not self:isModal())
    if self.tab == "Market" or self.tab == "Auction" then
        fee.note = self.tab == "Market" and feeNote("Market_Note", self.marketInfo) or feeNote("Auction_Note", self.auctionInfo)
        C.DetailWindow.update(self, "fees:" .. self.tab, getText(T .. "Trade_FeeDetails"), fee.note)
    end

    -- A failed read is recoverable from the list it belongs to.
    local retryB = self.historyRetryButton
    retryB:setVisible(self:historyFault() ~= nil and open and not sheet)
    if retryB:getIsVisible() then
        local ry, rh = g.walletNoteY, walletLineH
        if self.tab == "Market" then ry, rh = g.marketCardY + CARD_TITLE_H, ROW
        elseif self.tab == "Auction" then ry, rh = g.auctionCardY + CARD_TITLE_H, ROW end
        retryB:setX(right - retryB.width)
        retryB:setY(ry + math.floor((rh - retryB.height) / 2))
    end
    -- The tables this pass really placed, with what each of them had picked last time carried
    -- over: Panel:syncDetail refreshes an open record window from them and opens none.
    for _, spec in ipairs(watch) do
        for _, previous in ipairs(self.detailWatch or {}) do
            if previous.list == spec.list then
                spec.last, spec.revision = previous.last, previous.revision
                break
            end
        end
    end
    self.detailWatch = watch
    self:syncDetail()
    box:setX(boxX); box:setY(boxY)
    if box.width ~= boxW then box:setWidth(boxW) end
    if box.height ~= boxH then box:setHeight(boxH) end
    self:updateDetail()
    self:updateModalGuard()   -- the window may have been resized or collapsed under a dialog
    self:layoutMarketDialog()
    self:layoutBuy()
    self.layoutW, self.layoutH = w, h
    self.layoutCollapsed = self.isCollapsed
    self.layoutBand = band
end

-- ----- drawing -----

-- ---------- the header currency tooltip ----------
-- A coin icon over an amount cannot say *which* currency it is, and an admin may have renamed it
-- (C.currencyName reads that override). The name is offered through the engine's own ISToolTip,
-- the way ISButton offers a button's (ISButton.lua:316-346): added to the UIManager, because it
-- has to paint over the window, and taken down again the moment the pointer leaves the strip. A
-- tooltip whose owner is no longer visible removes itself as well (ISToolTip.lua:56-62), so a
-- closed, hidden or collapsed window can never leave one behind.
--
-- This is a read of what is already on the header: no chip, no control, no second way to spend.
function L.headerTipName(self)
    if not self.shown or self.isCollapsed or not self:isMouseOver() then return nil end
    local g = self.g
    if not g then return nil end
    local my = self:getMouseY()
    if my < g.headY or my >= g.headY + g.headH then return nil end
    local mx = self:getMouseX()
    for _, hit in ipairs(self.headerHits or {}) do
        if mx >= hit.x and mx < hit.x + hit.w then return hit.name end
    end
    return nil
end

-- ---------- the note tooltip ----------
-- A fee note the card was too small to hold whole is read in full by hovering it, through the very
-- tooltip the header already owns. No chip, no second page and no scroll box for one sentence: the
-- layout only leaves a hit strip behind when it really had to cap the lines.
local function noteTipText(self)
    local tip = self.g and self.g.noteTip
    if tip == nil or not self.shown or self.isCollapsed or not self:isMouseOver() then return nil end
    local my = self:getMouseY()
    if my < tip.y or my >= tip.y + tip.h then return nil end
    local mx = self:getMouseX()
    if mx < tip.x or mx >= tip.x + tip.w then return nil end
    return tip.text
end

function L.updateHeaderTip(self)
    local name = not self:isModal() and (self:headerTipName() or noteTipText(self)) or nil
    local tip = self.headerTip
    if name == nil then
        if tip ~= nil and tip:getIsVisible() then
            tip:setVisible(false)
            tip:removeFromUIManager()
        end
        return
    end
    if tip == nil then
        tip = ISToolTip:new()
        tip:setOwner(self)
        tip:setVisible(false)
        tip:setAlwaysOnTop(true)
        self.headerTip = tip
    end
    tip.description = name
    if not tip:getIsVisible() then
        tip.maxLineWidth = 420
        tip:addToUIManager()
        tip:setVisible(true)
    end
end

-- The pointer moved: the tooltip follows it at once instead of waiting for the next frame, and
-- leaving the window takes it down through the very same call.
function L.onMouseMove(self, dx, dy)
    ISCollapsableWindow.onMouseMove(self, dx, dy)
    self:updateHeaderTip()
end

function L.onMouseMoveOutside(self, dx, dy)
    ISCollapsableWindow.onMouseMoveOutside(self, dx, dy)
    self:updateHeaderTip()
end

-- Account/title share the left budget; exact available balances keep the right edge.
-- Optional reserved values may use only space left after that content fits.
function L.drawHeader(self)
    local g = self.g
    local y = g.headY
    local ty = g.titleY
    local cy = y + math.floor((g.headH - COIN_HEAD) / 2)
    local ids = self:currencies()
    local x = self.width - PAD
    local reservedLabel = getText(T .. "Wallet_Reserved")
    local title = getText(T .. "Tab_" .. tostring(self.tab))
    local spare = self.width - PAD * 4 - g.headerUsedW
    for _, id in ipairs(ids) do
        local bal = C.wallet and C.wallet.balances and C.wallet.balances[id]
        spare = spare - textWidth(amountText(bal and bal.available or 0), UIFont.Medium) - COIN_HEAD - 6 - PAD
    end
    -- the blocks the tooltip is hit-tested against, rebuilt in place (one table per window)
    local hits = self.headerHits or {}
    for i = #hits, #ids + 1, -1 do hits[i] = nil end
    for i = #ids, 1, -1 do
        local id = ids[i]
        local bal = C.wallet and C.wallet.balances and C.wallet.balances[id]
        local avail = amountText(bal and bal.available or 0)
        local blockR = x
        x = x - textWidth(avail, UIFont.Medium)
        text(self, avail, x, ty, "accent", UIFont.Medium)
        x = x - 6 - COIN_HEAD
        drawCoin(self, id, x, cy, COIN_HEAD)
        local reserved = bal and tonumber(bal.reserved) or 0
        if reserved > 0 then
            -- Optional reserved values may use only space left after every available balance.
            local r = reservedLabel .. " " .. amountText(reserved)
            local rw = textWidth(r, UIFont.Medium)
            if rw + PAD <= spare then
                spare = spare - rw - PAD
                x = x - PAD - rw
                text(self, r, x, ty, "textMuted", UIFont.Medium)
            end
        end
        local index = #ids - i + 1
        local hit = hits[index]
        if not hit then hit = {}; hits[index] = hit end
        hit.x, hit.w, hit.name = x, math.max(0, blockR - x), C.currencyName(id)
        x = x - PAD
    end
    self.headerHits = hits
    text(self, fitText(title, math.min(g.headerTitleW, math.max(0, x - PAD * 2)), UIFont.Medium),
        PAD * 2, ty, "text", UIFont.Medium)
end

function L.drawWallet(self)
    local g = self.g
    local bx, bw = g.bodyX, g.bodyW
    local title = getText(T .. (g.walletBalances and "Wallet_Balances" or "Wallet_Statement"))
    card(self, bx, g.contentY, bw, g.workH, fitText(title, math.max(0, g.walletTitleW), UIFont.Medium), g.walletHeaderH)
    if g.walletBalances then return end
    if g.walletFilters then
        text(self, getText(T .. "Wallet_Period"), bx + PAD,
            g.walletChipY + math.floor((math.max(CHIP_H, fontH.small + 10) - fontH.small) / 2), "textMuted")
        self.walletBar:draw(self)
    end
    if not g.walletList then return end
    -- table header
    local cols = self.list.cols
    local hx = self.list.x
    local hy = g.tableHeaderY
    local lineH = self.list.rowHeight
    fill(self, hx, hy, self.list.width, lineH, "well", "rect")
    local ty = hy + math.floor((lineH - fontH.small) / 2)
    text(self, getText(T .. "Wallet_Col_Time"), hx + cols.time, ty, "textMuted")
    if not cols.compact then
        text(self, getText(T .. "Wallet_Col_Kind"), hx + cols.kind, ty, "textMuted")
        text(self, fitText(getText(T .. "Wallet_Col_Desc"), cols.descW), hx + cols.desc, ty, "textMuted")
    else
        textCentre(self, getText(T .. "Filter_Count", tostring(self.walletBar.total)),
            hx + self.list.width / 2, ty, "textMuted")
    end
    textRight(self, getText(T .. "Wallet_Col_Amount"), hx + cols.amountR, ty, "textMuted")
    if not cols.compact then
        textRight(self, getText(T .. "Wallet_Col_Balance"), hx + cols.balanceR, ty, "textMuted")
        text(self, getText(T .. "Wallet_Col_Status"), hx + cols.status, ty, "textMuted")
    end
    -- pager, then the footer note: what this list really is, most urgent first
    self.walletBar:drawPager(self, hx + PAD, cols.compact)
    local retryB = self.historyRetryButton
    local noteW = math.max(0, (retryB:getIsVisible() and retryB.x - 6 or hx + self.list.width) - hx - PAD)
    local note, token = nil, "textMuted"
    local n = #self.list:getItems()
    local all = #(self.allRows or {})
    if self.historyError then
        -- a statement read is a read, never a claim: it failed, it can be retried through
        -- historyRetryButton, and whatever was read before stays on screen marked as the older data
        note, token = historyError(self.historyError), "errorText"
        if all > 0 then note = note .. "  " .. getText(T .. "History_Stale") end
    elseif self.walletGate:busy() and all == 0 then
        note = getText(T .. "Wallet_Loading")      -- the first read of all is never an empty page
    elseif n == 0 and all > 0 then
        note = getText(T .. "Filter_NoMatch")
    elseif all == 0 then
        note = getText(T .. "Wallet_Empty")
    elseif self.walletBar.query ~= nil then
        -- the keyword only ever narrows what is loaded: the recent window is RECENT_ROWS lines and
        -- a month file is cut to the server's own limit, so it is never the whole two months
        note = getText(T .. "Filter_SearchScope", tostring(all))
        if self.history and self.history.truncated then
            note = note .. "  " .. getText(T .. "Wallet_Truncated", tostring(all), tostring(self.history.total or all))
        end
    elseif self.history and self.history.truncated then
        note = getText(T .. "Wallet_Truncated", tostring(all), tostring(self.history.total or all))
    end
    if note then
        text(self, fitText(note, noteW), hx + PAD, g.walletNoteY + math.floor((lineH - fontH.small) / 2), token)
    end
end

function L.drawRewards(self)
    local g, st = self.g, C.rewards
    card(self, g.bodyX, g.contentY, g.bodyW, g.contentH, getText(T .. "Rewards_Daily"))
    if not st then self.claimButton:setEnable(false); return end
    -- an amount of zero is not a reward: a check-in the admin switched off says so on the
    -- button instead of inviting a claim worth nothing
    if st.blockedReason == "checkin_disabled" then
        self.claimButton:setTitle(getText(T .. "Rewards_ClaimOff"))
    else
        self.claimButton:setTitle(getText(T .. "Rewards_ClaimButton", amountText(st.amount)))
    end
    self.claimButton.coinId = st.currency
    -- Whether this claim may be taken is the server's answer and nothing else: the online time,
    -- the per-day count, the interval since the last one, the server-wide cap, a frozen account
    -- and a disabled currency are all folded into canClaim, with blockedReason spelled out in
    -- the reader beside it. Recomputing any of that here could only disagree with the server.
    self.claimButton:setEnable(st.canClaim == true and not self.claimPending)
    if self.detailRewards ~= st or self.detailRewardsSecond ~= math.floor(EC.now() / 1000) then
        self:updateDetail()
    end
end

function L.drawShop(self)
    local g = self.g
    local shop = C.shop
    local x, w = g.bodyX, g.bodyW
    card(self, x, g.contentY, w, g.workH, getText(T .. "Shop_Title"))
    local titleY = g.contentY + math.floor((CARD_TITLE_H - fontH.small) / 2)
    if not shop then
        textRight(self, getText(T .. "Wallet_Loading"), x + w - PAD, titleY, "textMuted")
        return
    end
    -- the note shares the card title row: what this page is trading in, and the state of the
    -- buyback *for that currency* (the server switches them one by one)
    local currency = self:shopCurrency()
    local note = getText(T .. "Shop_Note", C.currencyName(currency))
    local noteToken = "textMuted"
    local bb = shop.buyback
    local byCurrency = (type(bb) == "table" and type(bb.byCurrency) == "table")
        and bb.byCurrency[currency] or nil
    local open = type(bb) == "table" and bb.enabled == true and byCurrency ~= nil
        and byCurrency.enabled == true
    if open then
        if self.shopHasBuyback then
            note = getText(T .. "Shop_BuybackNote",
                W.moneyText(byCurrency.accountRemaining, currency)) .. "  " .. note
        else
            note = getText(T .. "Shop_BuybackNone")
        end
    elseif self.shopHasBuyback then
        note = (type(bb) == "table" and bb.enabled == true)
            and getText(T .. "Shop_BuybackOffCurrency", C.currencyName(currency))
            or getText(T .. "Shop_BuybackPaused")
        noteToken = "warn"
    end
    local titleW = textWidth(getText(T .. "Shop_Title"), UIFont.Medium)
    textRight(self, fitText(note, math.max(0, w - PAD * 3 - titleW)), x + w - PAD, titleY, noteToken)
    -- The reset band the layout reserved. It counts down, so the text is rebuilt when the
    -- second changes (never per frame) and wrapped to the lines that band really has -- the
    -- date, the zone and the countdown are all readable, and none of them is clipped.
    local lines = g.shopNoteLines
    if lines ~= nil and #lines > 0 then
        local second = math.floor(EC.now() / 1000)
        if self.shopNoteSecond ~= second or self.shopNoteWidth ~= w then
            self.shopNoteSecond, self.shopNoteWidth = second, w
            self.shopNoteWrapped = U.wrapText(shopDayNote(self), math.max(60, w - PAD * 2), #lines)
        end
        drawNote(self, self.shopNoteWrapped, x + PAD, g.shopNoteY)
    end
    text(self, getText(T .. "Shop_Category"), self.shopCatCombo.x,
        self.shopCatCombo.y - fontH.small - 2, "textMuted")
    text(self, getText(T .. "Trade_Currency"), self.shopCurCombo.x,
        self.shopCurCombo.y - fontH.small - 2, "textMuted")
    local cols = self.shopList.cols
    local hx, hy = self.shopList.x, g.shopHeaderY
    fill(self, hx, hy, self.shopList.width, ROW, "well", "rect")
    local hty = hy + math.floor((ROW - fontH.small) / 2)
    text(self, getText(T .. "Shop_Col_Item"), hx + cols.name, hty, "textMuted")
    textRight(self, getText(T .. "Shop_Col_Price"), hx + cols.priceR, hty, "textMuted")
    textRight(self, getText(T .. "Shop_Col_Remaining"), hx + cols.remainR, hty, "textMuted")
    if #self.shopList:getItems() == 0 then
        text(self, getText(T .. ((self.shopQuery or self.shopCat) and "Market_NoMatch" or "Shop_Empty")),
            hx + PAD, self.shopList.y + math.floor((ROW - fontH.small) / 2), "textMuted")
    end
end

function L.drawMail(self)
    local g = self.g
    local mail = C.mail
    local x, w = g.bodyX, g.bodyW
    card(self, x, g.contentY, w, g.workH, getText(T .. "Mail_Title"))
    local unclaimed = tonumber(mail and mail.unclaimed) or 0
    local usage = mail and mail.usage or nil
    local titleY = g.contentY + math.floor((CARD_TITLE_H - fontH.small) / 2)
    local rightX = x + w - PAD
    if usage and tonumber(usage.capacity) then
        local used = tonumber(usage.used) or 0
        local cap = tonumber(usage.capacity) or 0
        local capText = getText(T .. "Mail_Capacity", tostring(used), tostring(cap))
        textRight(self, capText, rightX, titleY, used >= cap and "negative" or "textMuted")
        rightX = rightX - textWidth(capText) - PAD
    end
    textRight(self, getText(T .. "Mail_Count", tostring(unclaimed)), rightX, titleY, unclaimed > 0 and "accent" or "textMuted")
    -- the capacity row: what the total the server counts is really made of. Its own row, so a
    -- large font or a narrow workspace cuts nothing away, and it stays readable over the full
    -- reader as well (it explains the mailbox, not the letter being read)
    if g.mailPartsH > 0 and usage then
        text(self, fitText(getText(T .. "Mail_CapacityParts", tostring(tonumber(usage.unclaimed) or 0),
            tostring(tonumber(usage.marketListings) or 0), tostring(tonumber(usage.auctions) or 0)),
            w - PAD * 2), x + PAD, g.mailPartsY + math.floor((ROW - fontH.small) / 2), "textMuted")
    end
    local ty = g.mailActionY + math.floor((g.mailActionH - fontH.small) / 2)
    if not mail then
        text(self, getText(T .. "Wallet_Loading"), x + PAD, ty, "textMuted")
        return
    end
    -- the note names the two things a row cannot: where these items come from, and that picking
    -- a row only reads it - the row's own claim button takes that one letter
    local claimB = self.mailClaimAllButton
    local noteW = math.max(0, (claimB:getIsVisible() and claimB.x - 6 or x + w - PAD) - x - PAD)
    local note = getText(T .. "Mail_Note") .. "  " .. getText(T .. "Mail_ClaimHint")
    local batch = self.mailBatch
    if batch ~= nil then
        note = getText(T .. "Mail_BatchProgress", tostring(batch.total - #batch.ids), tostring(batch.total))
    end
    text(self, fitText(note, noteW), x + PAD, ty, batch ~= nil and "accent" or "textMuted")
    if #self.mailList:getItems() == 0 then
        text(self, getText(T .. "Mail_Empty"), x + PAD, self.mailList.y + math.floor((ROW - fontH.small) / 2), "textMuted")
    end
end

-- History page: one card, the note line, the filter bar and the ring (newest first by default).
-- No column header (the kind label already names each line); the ring is paged on the client,
-- so the pager under the table is the bar's own.
function L.drawMarketHistory(self)
    local g = self.g
    local list = self.marketHistoryList
    card(self, g.marketCardX, g.marketCardY, g.marketCardW, g.marketCardH, getText(T .. "Market_History_Title"))
    local ty = rowTextY(g.marketCardY + CARD_TITLE_H)
    local retryB = self.historyRetryButton
    local noteR = retryB:getIsVisible() and retryB.x - 6 or g.marketCardX + g.marketCardW - PAD
    local noteW = math.max(0, noteR - g.marketCardX - PAD)
    local snap = C.marketHistory
    -- The note line is the page's whole state, most urgent first: a read that failed (a read, not
    -- a claim — and historyRetryButton beside it is the only way it is asked again, while the
    -- snapshot underneath stays on screen marked as older data), the first read of all, and then
    -- what this list actually holds: the keyword's own scope and the server's own record limit.
    if self.marketHistoryError then
        local note = historyError(self.marketHistoryError)
        if snap then note = note .. "  " .. getText(T .. "History_Stale") end
        text(self, fitText(note, noteW), g.marketCardX + PAD, ty, "errorText")
        if not snap then return end     -- nothing was ever read: no bar, no pager, no empty line
    elseif not snap then
        text(self, getText(T .. "Wallet_Loading"), g.marketCardX + PAD, ty, "textMuted")
        return
    else
        local loaded = #(self.marketHistoryAll or {})
        local note, noteToken = getText(T .. "Market_History_Note"), "textMuted"
        if self.historyBar.query ~= nil then
            note = getText(T .. "Filter_SearchScope", tostring(loaded))
        end
        if snap.truncated == true then
            note = note .. "  " .. getText(T .. "Market_History_Truncated", tostring(loaded))
            noteToken = "warn"
        end
        text(self, fitText(note, noteW), g.marketCardX + PAD, ty, noteToken)
    end
    self.historyBar:draw(self)
    self.historyBar:drawPager(self, g.marketCardX + PAD)
    if list:getIsVisible() and #list:getItems() == 0 then
        local all = #(self.marketHistoryAll or {})
        text(self, getText(T .. (all > 0 and "Filter_NoMatch" or "Market_History_Empty")), list.x + PAD,
            list.y + math.floor((ROW - fontH.small) / 2), "textMuted")
    end
end

function L.drawMarket(self)
    local g = self.g
    local mine = self.marketMode == "mine"
    local info = self.marketInfo
    if self.marketMode == "history" then return self:drawMarketHistory() end
    card(self, g.marketCardX, g.marketCardY, g.marketCardW, g.marketCardH, getText(T .. "Market_Title"))
    local snap = mine and C.myListings or C.market
    local titleY = g.marketCardY + math.floor((CARD_TITLE_H - fontH.small) / 2)
    if not snap then
        textRight(self, getText(T .. "Wallet_Loading"), g.marketCardX + g.marketCardW - PAD, titleY, "textMuted")
        return
    end
    -- both pages read their note under the card title, left aligned: the browse page the fee note
    -- the server quoted (wrapped and measured by the layout), the own-listings page its own count
    if mine then
        text(self, fitText(getText(T .. "Market_MineCount", tostring(info.mine), tostring(info.maxListings)),
            g.marketCardW - PAD * 2), g.marketCardX + PAD,
            rowTextY(g.marketCardY + CARD_TITLE_H), "textMuted")
    else
        drawNote(self, g.marketNoteLines, g.marketCardX + PAD, g.marketCardY + CARD_TITLE_H)
        text(self, getText(T .. "Shop_Category"), self.marketCatCombo.x,
            self.marketCatCombo.y - fontH.small - 2, "textMuted")
        text(self, getText(T .. "Trade_Currency"), self.marketCurCombo.x,
            self.marketCurCombo.y - fontH.small - 2, "textMuted")
        text(self, getText(T .. "Filter_Sort"), self.marketSortCombo.x,
            self.marketSortCombo.y - fontH.small - 2, "textMuted")
    end
    -- the header row is a child (MarketHeader): it paints the column names and takes the clicks
    if #self.marketList:getItems() == 0 then
        text(self, getText(T .. (self.marketNoMatch and "Market_NoMatch" or "Market_Empty")),
            self.marketList.x + PAD, self.marketList.y + math.floor((ROW - fontH.small) / 2), "textMuted")
    end
    if mine then return end
    -- pager strip: the page counter, the two chips (children), the server's total on the right
    local fy = g.marketFooterY + math.floor((ROW - fontH.small) / 2)
    text(self, getText(T .. "Market_Page", tostring(self.marketPage), tostring(info.pages)),
        g.marketCardX + PAD, fy, "textMuted")
    textRight(self, getText(T .. "Market_Total", tostring(info.total)),
        g.marketCardX + g.marketCardW - PAD, fy, "textMuted")
end

-- Record page: one card, one note line and the client-paged ring. The note line is the page's
-- whole state in one place, most urgent first: a refusal (the snapshot underneath stays on
-- screen - an error is not an empty record), the first read of all, the "only the newest 200"
-- warning, and otherwise the note that these amounts are bids and not wallet movements. A read
-- that is still in flight over a snapshot says so on the right, without hiding anything.
function L.drawAuctionHistory(self)
    local g = self.g
    local list = self.auctionHistoryList
    card(self, g.auctionCardX, g.auctionCardY, g.auctionCardW, g.auctionCardH,
        getText(T .. "Auction_History_Title"))
    local ty = rowTextY(g.auctionCardY + CARD_TITLE_H)
    local retryB = self.historyRetryButton
    local noteR = retryB:getIsVisible() and retryB.x - 6 or g.auctionCardX + g.auctionCardW - PAD
    local noteW = math.max(0, noteR - g.auctionCardX - PAD)
    local pending = self.auctionGate:busy()
    local snap = C.auctionHistory
    if self.auctionHistoryError then
        local note = historyError(self.auctionHistoryError)
        if snap then note = note .. "  " .. getText(T .. "History_Stale") end
        text(self, fitText(note, noteW), g.auctionCardX + PAD, ty, "errorText")
        if not snap then return end  -- nothing read yet: no bar, no pager, no empty-filter line
    elseif not snap then
        text(self, getText(T .. (pending and "Wallet_Loading" or "Auction_History_Empty")),
            g.auctionCardX + PAD, ty, "textMuted")
        return
    elseif self.auctionHistoryTruncated then
        text(self, fitText(getText(T .. "Auction_History_Truncated"), noteW), g.auctionCardX + PAD, ty, "warn")
    else
        text(self, fitText(getText(T .. "Auction_History_Note"), noteW), g.auctionCardX + PAD, ty, "textMuted")
    end
    if pending then
        textRight(self, getText(T .. "Wallet_Loading"), noteR, ty, "textMuted")
    end
    self.auctionHistoryBar:draw(self)
    self.auctionHistoryBar:drawPager(self, g.auctionCardX + PAD)
    if list:getIsVisible() and #list:getItems() == 0 then
        local all = #(self.auctionHistoryAll or {})
        text(self, getText(T .. (all > 0 and "Filter_NoMatch" or "Auction_History_Empty")), list.x + PAD,
            list.y + math.floor((ROW - fontH.small) / 2), "textMuted")
    end
end

-- Auction page: one card, the note line (the tax and the listing fee the server quoted), then
-- either the sortable browse table with its pager or the two "my auctions" sections.
function L.drawAuction(self)
    if self.auctionMode == "history" then return self:drawAuctionHistory() end
    local g = self.g
    local info = self.auctionInfo
    local mine = self.auctionMode == "mine"
    card(self, g.auctionCardX, g.auctionCardY, g.auctionCardW, g.auctionCardH, getText(T .. "Auction_Title"))
    local ty = rowTextY(g.auctionCardY + CARD_TITLE_H)
    if (mine and not C.myAuctions) or (not mine and not C.auction) then
        text(self, getText(T .. "Wallet_Loading"), g.auctionCardX + PAD, ty, "textMuted")
        return
    end
    drawNote(self, g.auctionNoteLines, g.auctionCardX + PAD, g.auctionCardY + CARD_TITLE_H)
    if mine then
        local labelX = g.auctionCardX + PAD
        text(self, getText(T .. "Auction_Mine", tostring(info.mine), tostring(info.maxAuctions)),
            labelX, rowTextY(g.aucSellLabelY), "text")
        text(self, getText(T .. "Auction_Bidding"), labelX, rowTextY(g.aucBidLabelY), "text")
        if #self.auctionSellList:getItems() == 0 and #self.auctionBidList:getItems() == 0 then
            text(self, getText(T .. "Auction_MineEmpty"), labelX, rowTextY(g.aucSellY), "textMuted")
        end
        return
    end
    text(self, getText(T .. "Filter_Sort"), self.auctionSortCombo.x,
        self.auctionSortCombo.y - fontH.small - 2, "textMuted")
    text(self, getText(T .. "Trade_Currency"), self.auctionCurCombo.x,
        self.auctionCurCombo.y - fontH.small - 2, "textMuted")
    -- the header row is a child (MarketHeader): it paints the column names and takes the clicks
    if #self.auctionList:getItems() == 0 then
        text(self, getText(T .. (self.auctionNoMatch and "Market_NoMatch" or "Auction_Empty")),
            self.auctionList.x + PAD, self.auctionList.y + math.floor((ROW - fontH.small) / 2), "textMuted")
    end
    local fy = g.auctionFooterY + math.floor((ROW - fontH.small) / 2)
    text(self, getText(T .. "Market_Page", tostring(self.auctionPage), tostring(info.pages)),
        g.auctionCardX + PAD, fy, "textMuted")
    textRight(self, getText(T .. "Market_Total", tostring(info.total)),
        g.auctionCardX + g.auctionCardW - PAD, fy, "textMuted")
end

function L.drawFooter(self)
    local g = self.g
    local st = C.rewards
    if g.footerH == 0 or not st then return end
    local cap = tonumber(st.serverCap) or 0
    local used = math.floor((tonumber(st.serverPaidToday) or 0) * 100 / cap)
    textCentre(self, getText(T .. "Rewards_ServerCap", tostring(used)), self.width / 2, g.contentY + g.contentH + math.floor((ROW - fontH.small) / 2), "textMuted")
end

L.MIN_WIDTH, L.MIN_HEIGHT = MIN_WIDTH, MIN_HEIGHT
L.defaultSize = defaultSize

C.PanelLayout = L

return L
