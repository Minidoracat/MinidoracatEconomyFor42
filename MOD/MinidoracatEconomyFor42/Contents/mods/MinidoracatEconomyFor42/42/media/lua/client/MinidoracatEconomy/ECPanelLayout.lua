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
require "MinidoracatEconomy/ECPanelWidgets"
require "MinidoracatEconomy/ECPanelShopMail"
require "MinidoracatEconomy/ECPanelCards"

local EC = MinidoracatEconomy
local C = EC.Client
local U = C.UI
local W = C.PanelWidgets

local L = {}

local PAD, ROW, CHIP_H, COIN_SMALL, T = U.PAD, U.ROW, U.CHIP_H, U.COIN_SMALL, U.T
local CARD_TITLE_H = U.CARD_TITLE_H
local fontH = U.fontH
local fill, text, textWidth, fitText, textRight, textCentre, drawCoin = U.fill, U.text, U.textWidth, U.fitText, U.textRight, U.textCentre, U.drawCoin
local amountText, card = U.amountText, U.card
local ITEM_ICON = W.ITEM_ICON
local placeRow, comboWidth = W.placeRow, W.comboWidth
local HISTORY_KINDS, AUCTION_HISTORY_KINDS = W.HISTORY_KINDS, W.AUCTION_HISTORY_KINDS
local historyError = W.historyError

-- The deadline columns of the market and auction tables measure the rows themselves: every row
-- reads as a remaining time (W.remainText), and the widest one on screen is the column's width.
local function deadlineWidths(c, rows, moreRows)
    local valueW = c.sample and textWidth(c.sample) or 0
    local count = rows and #rows or 0
    local total = count + (moreRows and #moreRows or 0)
    for index = 1, total do
        local row = index <= count and rows[index] or moreRows[index - count]
        if type(row.expiresText) == "string" then valueW = math.max(valueW, textWidth(row.expiresText)) end
    end
    c.sampleW = valueW
end

local function tableColumns(specs, leftX, rightX, nameMin, rows, moreRows)
    for i = 2, #specs do
        local c = specs[i]
        if c.key == "expires" or c.key == "ending" then deadlineWidths(c, rows, moreRows) end
    end
    U.framework.Table.layoutColumns(specs, leftX, rightX, nameMin, PAD)
    -- A strip where the item name keeps less than twice its floor, or a column loses its own title
    -- (the minimum window, a long language), gives up the currency column first: the coin beside
    -- every price already names the currency, and the row's record window spells it out.
    local tight = specs[1].w < nameMin * 2
    for i = 2, #specs do
        if specs[i].w < textWidth(specs[i].title) + PAD then tight = true end
    end
    if tight then
        for i = 2, #specs do
            if specs[i].key == "cur" then
                table.remove(specs, i)
                U.framework.Table.layoutColumns(specs, leftX, rightX, nameMin, PAD)
                break
            end
        end
    end
    return specs
end

-- The size the window may never be dragged under, and the purely visual bands of its chrome.
local MIN_WIDTH, MIN_HEIGHT = 1000, 560
local HEAD_H = 34                -- the compact header: location row + exact available amounts
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

-- One currency's available amount on the header: "-" until the server sent a wallet. A login it
-- does not answer (identity unconfirmed, one account per Steam account) never gets one, and a 0
-- there reads as money gone.
local function headAmount(id)
    local bal = C.wallet and C.wallet.balances and C.wallet.balances[id]
    return bal and amountText(bal.available or 0) or "-"
end

-- The width the header's right block needs: every currency's exact available amount with its
-- coin. Measured in one place, so the layout can hand the left side the room that is really
-- left over (the page title on one row, the login account on the row under it) and the paint
-- can start the amounts at the very same x. Money is the one thing on this row that never
-- gives way, so it is measured first and everything else is fitted into the remainder.
local function headMoneyWidth(self)
    local total = 0
    for _, id in ipairs(self:currencies()) do
        total = total + textWidth(headAmount(id), UIFont.Medium)
            + COIN_HEAD + 6 + PAD
    end
    return total
end

-- ---------- the shop's note band ----------
-- The shop puts its daily-reset note under the card title, above search, wrapped only into
-- spare space.
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

local function drawNote(self, lines, x, y, token)
    local ty = y + math.floor((noteRowH() - fontH.small) / 2)
    local lh = noteLineH()
    for i = 1, #(lines or {}) do
        text(self, lines[i], x, ty + (i - 1) * lh, token or "textMuted")
    end
end

-- The top of a trade page: the mode tabs at the left with the page's actions right-aligned on the
-- same row (under the tabs when the row is too narrow), then the card's title row - the title,
-- the two fee pills of `info` and the rules chip at the right. Pills that do not fit beside the
-- title get a row of their own under it (a pill is never cut). Without `info` (the record pages)
-- the rules chip follows the title instead: the filter bar's compact toggle owns the right end.
-- Leaves g.<prefix>CardY, PillX / PillY (where the pills start), PillH (what a pill row of its own
-- adds under the title, else 0) and RulesX / RulesY (the rules block places the chip there).
local function tradeTop(self, prefix, tabs, actions, title, info)
    local g = self.g
    local bx, bw, y = g.bodyX, g.bodyW, g.contentY
    local barH = math.max(tabs.height, CHIP_H)
    tabs:setX(bx); tabs:setY(y)
    local ax = bx + bw + 6
    for i = 1, #actions do ax = ax - actions[i].width - 6 end
    if ax < bx + tabs.width + PAD then y = y + barH + 6 end
    for i = 1, #actions do
        local b = actions[i]
        b:setX(ax); b:setY(y + math.floor((barH - b.height) / 2))
        ax = ax + b.width + 6
    end
    local cardY = y + barH + PAD
    local rules = self.rulesButton
    local titleR = bx + PAD + textWidth(title, UIFont.Medium) + PAD
    local rulesX = info and (bx + bw - PAD - rules.width) or titleR
    g[prefix .. "CardY"], g[prefix .. "RulesX"] = cardY, rulesX
    g[prefix .. "RulesY"] = cardY + math.floor((CARD_TITLE_H - rules.height) / 2)
    g[prefix .. "PillX"], g[prefix .. "PillY"], g[prefix .. "PillH"] = titleR, cardY + math.floor((CARD_TITLE_H - CHIP_H) / 2), 0
    if info == nil then return end
    local pillsW = U.pillWidth(getText(T .. "Trade_Tax"), info.taxText) + 6
        + U.pillWidth(getText(T .. "Trade_Fee"), info.feeText)
    if titleR + pillsW > rulesX - 6 then
        g[prefix .. "PillX"], g[prefix .. "PillY"], g[prefix .. "PillH"] = bx + PAD, cardY + CARD_TITLE_H + 4, CHIP_H + 8
    end
end

-- The two fee pills tradeTop placed (g.<prefix>PillX / PillY).
function L.drawFeePills(self, x, y, info)
    x = x + U.drawPill(self, x, y, getText(T .. "Trade_Tax"), info.taxText) + 6
    U.drawPill(self, x, y, getText(T .. "Trade_Fee"), info.feeText)
end

-- A state line of a record page (an error, the first read, a capped or partial list), wrapped
-- into the two lines its band holds instead of cut; the lines are kept per text and width, so the
-- per-frame paint allocates nothing.
function L.drawStateNote(self, slot, note, x, y, w, token)
    local c = self[slot]
    if c == nil then c = {}; self[slot] = c end
    if c.note ~= note or c.w ~= w then c.note, c.w, c.lines = note, w, U.wrapText(note, math.max(60, w), 2) end
    drawNote(self, c.lines, x, y, token)
end

-- The rules chip of the two trade pages, where tradeTop left it: the fees in words and the
-- listing rules (the record pages: what their record holds).
function L.tradeRules(self, open)
    local rules, g = self.rulesButton, self.g
    local market = self.tab == "Market"
    local prefix = market and "market" or "auction"
    rules:setVisible(open)
    rules:setX(g[prefix .. "RulesX"]); rules:setY(g[prefix .. "RulesY"])
    local note
    local history = (market and self.marketMode or self.auctionMode) == "history"
    if history then
        note = getText(T .. (market and "Market_History_Note" or "Auction_History_Note"))
    elseif market then
        local info = self.marketInfo
        note = feeNote("Market_Note", info) .. "\n\n" .. (info.maxListings > 0
            and getText(T .. "Market_Rule_ListingMax", tostring(info.maxListings))
            or getText(T .. "Market_Rule_Listing"))
    else
        local info = self.auctionInfo
        local hours = info.minHours == info.maxHours and getText(T .. "Auction_Hours", tostring(info.minHours))
            or getText(T .. "Auction_HoursHint", tostring(info.minHours), tostring(info.maxHours))
        note = feeNote("Auction_Note", info) .. "\n\n" .. (info.maxAuctions > 0
            and getText(T .. "Auction_Rule_Max", tostring(info.maxAuctions), hours)
            or getText(T .. "Auction_Rule", hours))
    end
    rules.note, rules.ruleTitle = note, getText(T .. "Trade_Rules")
    rules.card = C.PanelCards.tradeRules(self, market, history)
    C.DetailWindow.update(self, "rules:" .. self.tab, rules.ruleTitle, note, rules.card)
end

-- Keep the debug compiler's cumulative local-variable table below its 200-entry limit.
function L.layoutMarket(self, workBottom, chipBand, toolBand, capH, watch)
    local g = self.g
    local bw = g.bodyW
    local x, y
    -- ----- market: the mode tabs and actions, then search / category / sort above one table --
    local isMarket = self.tab == "Market"
    local mineMode = self.marketMode == "mine"
    local historyMode = self.marketMode == "history"
    local browseMode = isMarket and not mineMode and not historyMode
    self.marketTabs:setVisible(isMarket)
    self.marketRefreshButton:setVisible(isMarket)
    self.marketListButton:setVisible(isMarket)   -- listing starts from either page
    tradeTop(self, "market", self.marketTabs, { self.marketRefreshButton, self.marketListButton },
        getText(T .. (historyMode and "Market_History_Title" or "Market_Title")),
        (not historyMode) and self.marketInfo or nil)
    y = g.marketCardY
    g.marketCardX, g.marketCardW = g.bodyX, bw
    g.marketCardH = math.max(CARD_TITLE_H + ROW * 3, workBottom - y)
    local mktBottom = g.marketCardY + g.marketCardH
    local mktRight = g.marketCardX + g.marketCardW - PAD
    y = y + CARD_TITLE_H + g.marketPillH
    self.marketEmptyButton:setVisible(false)     -- the paint shows it over an empty table
    -- one box for "item or seller": typing is the keyword, a picked candidate the exact seller,
    -- which then sits right of the box as a chip that drops it again
    local search, chip = self.marketSearch, self.marketSellerChip
    search:setVisible(browseMode)
    search.entry:setWidth(math.max(160, math.min(300, math.floor(bw * 0.28))))
    search.entry:setHeight(self.marketCatCombo.height)
    chip:setVisible(browseMode and self.marketSeller ~= nil)
    if self.marketSeller ~= nil then
        local label = getText(T .. "Market_SellerChip", self.marketSeller)
        chip:setWidth(math.min(textWidth(label) + 22, math.max(60, math.floor(bw * 0.3))))
        U.setButtonTitle(chip, label)
    end
    self.marketCatCombo:setVisible(browseMode)
    self.marketCatCombo:setWidth(comboWidth(self.marketCatCombo, 120, math.floor(bw * 0.28)))
    self.marketSortCombo:setVisible(browseMode)
    self.marketSortCombo:setWidth(comboWidth(self.marketSortCombo, 140, math.floor(bw * 0.3)))
    self.marketCurCombo:setVisible(browseMode)
    self.marketCurCombo:setWidth(comboWidth(self.marketCurCombo, 110, math.floor(bw * 0.25)))
    if browseMode then
        local tools = { search.entry }
        if chip:getIsVisible() then tools[2] = chip end
        tools[#tools + 1] = self.marketCatCombo
        tools[#tools + 1] = self.marketCurCombo
        tools[#tools + 1] = self.marketSortCombo
        y = placeRow(tools, g.marketCardX + PAD, y + capH, mktRight, toolBand, capH + 6) + 6
        -- the candidate list hangs under wherever the row placer left the box, and is capped to
        -- the card so it can never paint past it
        search:anchorDrop(mktBottom - (search.entry.y + search.entry.height) - PAD)
    elseif historyMode then
        y = y + noteRowH() + noteLineH()          -- the record's state band: two wrapped lines
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
            { key = "expires", title = getText(T .. "Market_Col_Expires"), sample = getText(T .. "Time_DH", "99", "23"),
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
            { key = "expires", title = getText(T .. "Market_Col_Expires"), sample = getText(T .. "Time_DH", "99", "23"),
              right = true },
        }
    end
    tableColumns(specs, mktCols.name, mktCols.actionX - PAD, textWidth("mmmmmmmm"), self.marketRows)
    self.marketHeader:setColumns(specs)
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
        mktRight, mktBottom - PAD, isMarket and historyMode, g.marketCardY + math.max(0, (CARD_TITLE_H - CHIP_H) / 2),
        W.historyRowHeight())
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
-- changes, the navigation is folded, the location row changes state or the currency list arrives.
--
-- Every page is laid out against the workspace the navigation left over (g.bodyX / g.bodyW), never
-- against the window: a rail that folds from its expanded width to 56 px moves every table with
-- it. There is no second permanent side panel any more — the filters of the shop and the market
-- sit above their table, and the tables themselves span the whole workspace.
function L.layout(self)
    local w, h = self.width, self.height
    local walletFiltersVisible = self.walletBar:isShown()
    local th = self:titleBarHeight()
    local rh = self.resizable and self:resizeWidgetHeight() or 0
    local open = not self.isCollapsed
    local band = self:statusBand()
    local g = {}
    g.headY = th
    -- One header row: the location row on the left (Panel:statusBand), the exact available
    -- balances on the right. The page names itself in the rail and on its card, never here.
    g.headH = math.max(HEAD_H, fontH.medium + 8, COIN_HEAD + 8)
    g.titleY = g.headY + math.floor((g.headH - fontH.medium) / 2)
    g.locW = math.max(0, w - PAD * 5 - headMoneyWidth(self))
    g.contentY = g.headY + g.headH + 4
    local st = C.rewards
    g.footerH = (self.tab == "Rewards" and st and (tonumber(st.serverCap) or 0) > 0) and ROW or 0
    g.contentH = math.max(ROW * 4, h - g.contentY - rh - PAD - g.footerH)

    -- The Admin entry appears and disappears with the right, and the navigation measures and
    -- places only what is visible: the permission is answered before either call.
    self.adminAccess = C.AdminPanel.canRead()
    if self.adminNavButton then self.adminNavButton:setVisible(self.adminAccess) end

    -- ----- the identity row of the rail -----
    -- The account this window belongs to, on every page: a screenshot of any tab names its
    -- owner. The row's words *are* the label, so what is on screen and what a press opens in full
    -- are one value (Panel:onIdentity). Labelled before the rail measures itself.
    local idB = self.identityButton
    local account, login = self:username(), C.login()
    self.identityName = account
    local unverified = C.identityUnverified == true
    local idLabel = unverified and getText(T .. "Player_IdentityUnverified")
        or (type(account) == "string" and login ~= nil and login ~= account)
            and getText(T .. "Player_IdentityMerged", account, login)
        or (type(account) == "string") and getText(T .. "Player_Identity", account)
        or getText(T .. "Player_IdentityUnknown")
    idB:setEnable(unverified or type(account) == "string")
    idB.stateToken = unverified and "errorText" or nil
    idB.fullTitle, idB.navTitle = idLabel, idLabel

    local nav = self.nav
    g.navX = PAD
    g.navW = nav:widthFor(w)
    g.bodyX = g.navX + g.navW + PAD
    g.bodyW = math.max(200, w - g.bodyX - PAD)
    self.g = g

    -- ----- the location row's one button -----
    -- "Take me there" while a terminal exists and the player is away from it, "stop" while the
    -- arrow is up; the paint puts it right after the row's words (L.drawLocation).
    local loc = self.locationButton
    local navigating = band == "nav"
    local locLabel = getText(T .. (navigating and "Loc_Stop" or "Loc_Go"))
    loc:setVisible(open and (navigating or band == "away"))
    loc.pinIcon = not navigating
    loc:setHeight(math.max(CHIP_H, fontH.small + 8))
    loc:setWidth(textWidth(locLabel) + 20 + (loc.pinIcon and 36 or 0))
    loc:setY(g.headY + math.floor((g.headH - loc.height) / 2))
    U.setButtonTitle(loc, locLabel)

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
    -- (the filter bar's own chips take their height from the bar: UI.FilterBar height)
    for _, buttons in ipairs({ self.periodButtons,
        { self.walletDetailsButton, self.walletFilterButton, self.transferButton, self.detailCopyButton,
            self.historyRetryButton, self.mailClaimAllButton } }) do
        for _, button in ipairs(buttons) do
            local height = math.max(CHIP_H, fontH.small + 8)
            if button.height ~= height then button:setHeight(height) end
        end
    end
    local chromeTop = g.contentY + g.walletHeaderH
    local chipRow = math.max(CHIP_H, fontH.small + 8)
    -- one filter row: the period chips first, the bar (keyword, kind, custom dates) right after
    -- them; a bar that would not get a usable width beside them starts on the row below
    local firstP, lastP = self.periodButtons[1], self.periodButtons[#self.periodButtons]
    local periodBottom = placeRow(self.periodButtons, bx + PAD, chromeTop, right, self.walletBar.height, 6) + 6
    g.walletBarX, g.walletBarY = lastP.x + lastP.width + 12, chromeTop
    if lastP.y ~= firstP.y or right - g.walletBarX < 240 then g.walletBarX, g.walletBarY = bx + PAD, periodBottom end
    -- a measuring pass at the visibility the bar already has: hiding it would blur a box the
    -- player is typing in (UI.FilterBar:layout with visible=false blurs)
    local filtersBottom = self.walletBar:layout(g.walletBarX, g.walletBarY, right, walletFiltersVisible) + 6

    -- ----- the balance reader -----
    -- No page keeps a preview band any more: a picked row opens the floating record window
    -- (ECDetailWindow), so every table keeps its full height, its filters, its page and its
    -- scroll whatever the player is reading. The one page that *is* a reading surface -- the
    -- wallet's balance view -- places the box over its own card with the copy chip under it.
    g.detailH = (open and balances) and chipRow or 0
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
    local detailVisible = open and not sheet and balances
    copy:setVisible(detailVisible)
    copy:setX(g.bodyX + g.bodyW - copy.width)
    copy:setY(g.detailY + math.floor((g.detailH - copy.height) / 2))
    box:setVisible(detailVisible)
    local boxX, boxY = g.bodyX, g.detailY
    local boxW = math.max(80, copy.x - 6 - g.bodyX)
    local boxH = math.max(1, g.detailH)
    if balances then
        -- inset from the card's edge like every other card body; "this month" takes the room under it
        boxX, boxY, boxW, boxH = listX + PAD, chromeTop + 4, listW - PAD * 2, math.max(1, copy.y - 10 - chromeTop)
        boxH = L.layoutBalances(self, boxX, boxY, boxW, boxH)
    end

    -- Full filters, a compact filter sheet, or the full balance reader; never stacked into zero room.
    local fold, filt = self.walletDetailsButton, self.walletFilterButton
    fold.active = balances
    fold:setVisible(isWallet)
    self.walletEmptyButton:setVisible(false)      -- the paint shows it over an empty statement
    fold:setX(right - fold.width)
    fold:setY(g.contentY + math.floor((g.walletHeaderH - fold.height) / 2))
    filt.active = sheet
    filt:setVisible(isWallet and not balances and self.walletCompact)
    filt:setX(fold.x - 6 - filt.width); filt:setY(fold.y)
    -- the gold transfer button sits left of the header chips; its visibility is the server's
    -- (per frame, Panel:syncTransfer), so the title keeps only the room left of it
    local xfer = self.transferButton
    xfer:setX((filt:getIsVisible() and filt.x or fold.x) - 6 - xfer.width); xfer:setY(fold.y)
    g.walletTitleW = xfer.x - bx - PAD * 2
    g.walletFilters, g.walletList, g.walletBalances = showFilters, showList, balances
    -- (the period chips lead the filter row; Wallet_Period names them for the keyboard only)
    for _, b in ipairs(self.periodButtons) do b:setVisible(showFilters) end
    self.walletBar:layout(g.walletBarX, g.walletBarY, right, showFilters)
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
    -- the status column only exists while a listed row was rolled back; the fee rides on the
    -- note (StatementCell), so amount and balance are the two figures on the right
    cols.status = self.statementRolledBack and (inner - colW("Wallet_Col_Status", getText(T .. "Wallet_RolledBack")) + PAD) or nil
    cols.balanceR = cols.status and (cols.status - PAD) or (inner - PAD)
    cols.amountR = cols.balanceR - colW("Wallet_Col_Balance", "999,999,999")
    -- The kind column is as wide as the widest kind the listed rows carry, but never more than
    -- half of the band it shares with the note, so the note keeps its room; a longer kind is cut
    -- with "..." on the row and spelled out in full in the row's record window. A band whose half
    -- cannot even hold the kind header goes compact.
    local band = cols.amountR - (self.statementAmountW or 0) - cols.kind
    local kindCap = math.floor(band / 2) - PAD * 2
    local headW = textWidth(getText(T .. "Wallet_Col_Kind"))
    cols.compact = kindCap < headW
    cols.kindW = math.min(kindCap, math.max(headW, self.statementKindW or 0))
    cols.desc = cols.kind + cols.kindW + PAD * 2
    cols.descW = cols.compact and 0 or (band - cols.kindW - PAD * 2)
    if cols.compact then
        cols.amountR = inner - PAD
        cols.timeW = math.max(0, cols.amountR - cols.time - (self.statementValueW or 0) - COIN_SMALL - PAD * 2)
    else
        cols.timeW = nil
    end
    if self.list.width ~= listW or self.list.height ~= listH then self.list:resize(listW, listH) end
    L.layoutWalletHeader(self, listX, listW, showList)
    g.listBottom = listY + listH
    self.walletBar:layoutPager(listX + PAD, g.listBottom + 2, listX + listW - PAD, showList, walletLineH)
    g.walletNoteY = g.listBottom + 2 + walletLineH
    if isWallet and not balances and not sheet then watch[#watch + 1] = { kind = "statement", list = self.list } end

    -- ----- rewards: the daily card and the milestone card (L.layoutRewards) -----
    L.layoutRewards(self, isRewards and open)

    -- ----- shop and mailbox: their own module (ECPanelShopMail) -----
    C.PanelShopMail.layoutShop(self, workBottom, toolBand, capH, watch)
    C.PanelShopMail.layoutMail(self, workBottom, watch)

    self:layoutMarket(workBottom, chipBand, toolBand, capH, watch)

    -- ----- auction: the mode tabs and actions, then search / sort over one full-workspace card --
    -- Browsing is a sortable table with the server's pager under it; "my auctions" splits the card
    -- into the two lists (what the player sells, what they bid on), and the record page swaps the
    -- whole table for the two-line history list with its own filter bar. All three item tables
    -- read one column set (they are the same width), so the numbers below are computed once.
    local isAuction = self.tab == "Auction"
    local aucMine = self.auctionMode == "mine"
    local aucHistory = self.auctionMode == "history"
    local aucTable = isAuction and not aucMine and not aucHistory
    local aucBand = math.max(CHIP_H, self.auctionEntry.height)
    self.auctionTabs:setVisible(isAuction)
    self.auctionRefreshButton:setVisible(isAuction)
    self.auctionCreateButton:setVisible(isAuction)
    tradeTop(self, "auction", self.auctionTabs, { self.auctionRefreshButton, self.auctionCreateButton },
        getText(T .. (aucHistory and "Auction_History_Title" or "Auction_Title")),
        (not aucHistory) and self.auctionInfo or nil)
    y = g.auctionCardY
    g.auctionCardX, g.auctionCardW = bx, bw
    g.auctionCardH = math.max(CARD_TITLE_H + ROW * 3, workBottom - y)
    local aucBottom = g.auctionCardY + g.auctionCardH
    local aucRight = g.auctionCardX + g.auctionCardW - PAD
    self.auctionEmptyButton:setVisible(false)     -- the paint shows it over an empty table
    -- the browse table searches through the combined "item or seller" box (the market's own
    -- shape); the record page has a search box of its own (an id, an account, an item)
    local aucSearch, aucChip = self.auctionSearch, self.auctionSellerChip
    aucSearch:setVisible(aucTable)
    aucSearch.entry:setWidth(math.max(160, math.min(300, math.floor(bw * 0.28))))
    aucSearch.entry:setHeight(self.auctionEntry.height)
    aucChip:setVisible(aucTable and self.auctionSeller ~= nil)
    if self.auctionSeller ~= nil then
        local label = getText(T .. "Market_SellerChip", self.auctionSeller)
        aucChip:setWidth(math.min(textWidth(label) + 22, math.max(60, math.floor(bw * 0.3))))
        U.setButtonTitle(aucChip, label)
    end
    self.auctionEntry:setVisible(isAuction and aucHistory)
    self.auctionEntry:setWidth(math.max(140, math.min(280, math.floor(bw * 0.26))))
    self.auctionSortCombo:setVisible(aucTable)
    self.auctionSortCombo:setWidth(comboWidth(self.auctionSortCombo, 140, math.floor(bw * 0.3)))
    self.auctionCurCombo:setVisible(aucTable)
    self.auctionCurCombo:setWidth(comboWidth(self.auctionCurCombo, 110, math.floor(bw * 0.25)))
    y = y + CARD_TITLE_H + g.auctionPillH
    if aucHistory then y = y + noteRowH() + noteLineH() end   -- the record's state band
    if aucTable then
        local toolItems = { aucSearch.entry }
        if aucChip:getIsVisible() then toolItems[2] = aucChip end
        toolItems[#toolItems + 1] = self.auctionCurCombo
        toolItems[#toolItems + 1] = self.auctionSortCombo
        y = placeRow(toolItems, g.auctionCardX + PAD, y + capH, aucRight, aucBand, capH + 6) + 6
        aucSearch:anchorDrop(aucBottom - (aucSearch.entry.y + aucSearch.entry.height) - PAD)
    elseif aucHistory then
        y = placeRow({ self.auctionEntry }, g.auctionCardX + PAD, y, aucRight, aucBand, 6) + 6
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
          sample = getText(T .. "Auction_Ends_In", getText(T .. "Time_DH", "99", "23")) },
    }
    if aucMine then
        tableColumns(aSpecs, aCols.name, aCols.histX - PAD, textWidth("mmmmmmmm"),
            self.auctionSellRows, self.auctionBidRows)
    else
        tableColumns(aSpecs, aCols.name, aCols.histX - PAD, textWidth("mmmmmmmm"), self.auctionRows)
    end
    self.auctionHeader:setColumns(aSpecs)
    aCols.nameW = aSpecs[1].w
    -- by key: a tight strip drops the currency column (tableColumns)
    aCols.curR, aCols.curW = nil, nil
    for _, c in ipairs(aSpecs) do
        if c.key == "cur" then aCols.curR, aCols.curW = c.textR, c.textW
        elseif c.key == "price" then aCols.priceR, aCols.priceW = c.textR, c.textW
        elseif c.key == "bids" then aCols.bidsR, aCols.bidsW = c.textR, c.textW
        elseif c.key == "ending" then aCols.expiresR, aCols.expiresW = c.textR, c.textW end
    end

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
    -- "my auctions": the selling half over the bidding half, one section title each, and under the
    -- bids one muted line for the server's cap (it lists only the bids ending soonest)
    g.aucSellLabelY = g.auctionCardY + CARD_TITLE_H + g.auctionPillH
    g.aucMineBottom = aucBottom - PAD
    g.aucSellY = g.aucSellLabelY + ROW
    g.aucSellH = math.max(ROW, math.floor((g.aucMineBottom - g.aucSellY - ROW * 2) / 2))
    g.aucBidLabelY = g.aucSellY + g.aucSellH
    g.aucBidY = g.aucBidLabelY + ROW
    g.aucBidH = math.max(ROW, g.aucMineBottom - ROW - g.aucBidY)
    g.aucBidNoteY = g.aucBidY + g.aucBidH
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
        aucRight, aucBottom - PAD, isAuction and aucHistory, g.auctionCardY + math.max(0, (CARD_TITLE_H - CHIP_H) / 2),
        W.historyRowHeight())
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

    -- The page on screen names its rules (body and title); an open rules window follows them.
    -- Hidden unless the page on screen shows it again in its own branch below.
    local rules = self.rulesButton
    rules:setVisible(false)
    if isRewards then
        -- far right of the daily card's title row; note and title from the reward state
        rules:setVisible(open)
        if open then rules:setX(g.rwRulesX); rules:setY(g.rwRulesY) end
        if self.rw then self:syncRewardsRules() end
    end
    rules:setVisible(rules:getIsVisible() and open)
    rules:setEnable(not self:isModal())
    if self.tab == "Market" or self.tab == "Auction" then L.tradeRules(self, open) end
    if self.tab == "Shop" or self.tab == "Mail" then
        -- right end of the title row (left of the mailbox's gold claim-all), placed by the page
        rules:setVisible(open)
        rules:setX(g.rulesX); rules:setY(g.rulesY)
        local SM = C.PanelShopMail
        rules.note = self.tab == "Shop" and SM.shopRules(self) or SM.mailRules(self)
        rules.card = self.tab == "Shop" and C.PanelCards.shopRules(self) or C.PanelCards.mailRules(self)
        rules.ruleTitle = getText(T .. "Trade_Rules")
        C.DetailWindow.update(self, "rules:" .. self.tab, rules.ruleTitle, rules.note, rules.card)
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
    self:layoutDialog(self.transferDialog)
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
    -- the location row's words, in full, while the row had to cut them (L.drawLocation)
    if self.locTip and mx >= PAD * 2 and mx < self.locTipR then return self.locTip end
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

-- The location row's words, by Panel:statusBand state: a label in the state's colour, then what
-- it means or where to go. The arrow's distance changes as the player walks, so both are read
-- here (C.Navigate keeps them cached) and the row's button follows the words.
function L.drawLocation(self, band, token)
    local g = self.g
    local label, body
    if band == "frozen" then
        label = getText(T .. "Band_Frozen")
    elseif band == "at" then
        label, body = getText(T .. "Loc_At"), getText(T .. "Loc_AtBody")
    elseif band == "nav" then
        label, body = getText(T .. "Loc_Navigating"), C.Navigate.targetText()
    elseif band == "away" then
        label, body = getText(T .. (self:remoteReadOnly() and "Loc_ReadOnly" or "Loc_Away")), C.Navigate.hintText()
    else
        label = getText(T .. "Loc_None")
        body = getText(T .. (EC.mapAtmEnabled() and "Loc_NoneAtm" or "Loc_NoneAsk"))
    end
    -- the whole row as one sentence, rebuilt only when a part changed: the header tip offers it
    -- while the row is cut, and the row's button carries it for the keyboard and the gamepad
    if self.locLabel ~= label or self.locBody ~= body then
        self.locLabel, self.locBody = label, body
        self.locFull = body and getText(T .. "Loc_Full", label, body) or label
    end
    local b = self.locationButton:getIsVisible() and self.locationButton or nil
    local x0 = PAD * 2
    local right = x0 + g.locW - (b and (b.width + PAD) or 0)
    local cy = g.headY + math.floor(g.headH / 2)
    local ty = cy - math.floor(fontH.small / 2)
    U.Skin.dot(self, x0, cy - 4, 8, U.color(token))
    local x = x0 + 14
    local shown = fitText(label, math.max(0, right - x))
    local cut = shown ~= label
    text(self, shown, x, ty, token)
    x = x + textWidth(shown)
    if body then
        x = x + PAD
        shown = fitText(body, math.max(0, right - x))
        cut = cut or shown ~= body
        text(self, shown, x, ty, "text")
        x = x + textWidth(shown)
    end
    self.locTip, self.locTipR = cut and self.locFull or nil, x
    self.locationButton.tooltip, self.locationButton.autoTooltip = self.locFull, nil
    if b then
        b:setX(x + PAD)
        x = b.x + b.width
    end
    self.locUsedW = x - x0
end

-- The pin glyph left of "take me there" (the layout widened the chip for it); "stop" has none.
function L.renderLocationButton(b)
    U.Button.render(b)
    local Icons = b.pinIcon and U.framework and U.framework.Icons
    if Icons then
        Icons.draw(b, "pin", 10, math.floor((b.height - 14) / 2), 14, U.color(b.enable and "accent" or "textDisabled"), 1)
    end
end

-- The gold "ready" mark on the Rewards entry of the rail while the daily claim is open: words
-- beside the label on the expanded rail, a dot on the icon of the folded one.
function L.drawRewardsHint(self)
    local b, nav = self.rewardsTabButton, self.nav
    local x, y = nav.x + b.x, nav.y + b.y
    local hint = getText(T .. "Nav_Claimable")
    -- the expanded row's label starts after its icon (ECNavigation: inset 10, icon 22, gap 8);
    -- a word that would run into it (a long language, a narrow rail) gives way to the dot
    local labelR = x + 40 + textWidth(b.title, b.font)
    if nav.collapsed or labelR + 6 + textWidth(hint) > x + b.width - PAD then
        U.Skin.dot(self, x + b.width - 14, y + math.floor((b.height - 8) / 2), 8, U.color("coin"))
        return
    end
    textRight(self, hint, x + b.width - PAD, y + math.floor((b.height - fontH.small) / 2), "coin")
end

-- The location row (L.drawLocation, painted first) keeps the left; exact available balances keep
-- the right edge. Optional reserved values may use only space left after that content fits.
function L.drawHeader(self)
    local g = self.g
    local y = g.headY
    local ty = g.titleY
    local cy = y + math.floor((g.headH - COIN_HEAD) / 2)
    local ids = self:currencies()
    local x = self.width - PAD
    local reservedLabel = getText(T .. "Wallet_Reserved")
    local spare = self.width - PAD * 4 - (self.locUsedW or 0)
    for _, id in ipairs(ids) do
        spare = spare - textWidth(headAmount(id), UIFont.Medium) - COIN_HEAD - 6 - PAD
    end
    -- the blocks the tooltip is hit-tested against, rebuilt in place (one table per window)
    local hits = self.headerHits or {}
    for i = #hits, #ids + 1, -1 do hits[i] = nil end
    for i = #ids, 1, -1 do
        local id = ids[i]
        local bal = C.wallet and C.wallet.balances and C.wallet.balances[id]
        local avail = headAmount(id)
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
end

-- The statement's sortable header (rev 12, Panel.walletHeader): the list's own columns as the
-- framework's TableHeader specs, time and amount sortable through the filter bar. Laid out with
-- the list, never per frame; an older framework has no header and drawWallet paints the titles.
function L.layoutWalletHeader(self, listX, listW, shown)
    local head = self.walletHeader
    if head == nil then return end
    local cols = self.list.cols
    head:setVisible(shown)
    head:setX(listX); head:setY(self.g.tableHeaderY)
    if head.width ~= listW or head.height ~= self.list.rowHeight then head:setWidth(listW); head:setHeight(self.list.rowHeight) end
    local amountX = cols.amountR - math.max(self.statementAmountW or 0, textWidth(getText(T .. "Wallet_Col_Amount")) + PAD)
    local specs = {
        { key = "time", title = getText(T .. "Wallet_Col_Time"), x = cols.time,
            w = (cols.compact and amountX or cols.kind) - cols.time },
        { key = "amount", title = getText(T .. "Wallet_Col_Amount"), right = true, x = amountX,
            w = cols.amountR + 10 - amountX, textR = cols.amountR },
    }
    if not cols.compact then
        specs[3] = { key = "kind", sortable = false, title = getText(T .. "Wallet_Col_Kind"), x = cols.kind, w = cols.kindW + PAD }
        specs[4] = { key = "desc", sortable = false, title = getText(T .. "Wallet_Col_Desc"), x = cols.desc, w = cols.descW }
        specs[5] = { key = "balance", sortable = false, right = true, title = getText(T .. "Wallet_Col_Balance"),
            x = cols.amountR + 10, w = cols.balanceR - cols.amountR - 10, textR = cols.balanceR }
        if cols.status then
            specs[6] = { key = "status", sortable = false, title = getText(T .. "Wallet_Col_Status"),
                x = cols.status, w = math.max(0, listW - 12 - cols.status) }
        end
    end
    head:setColumns(specs)
end

-- The balance view: the reader takes what its lines need (never under four lines), the month
-- block (ECPanelCards.monthView) the room under it. The fitted labels, the wrapped note and the
-- column widths are kept here, so L.drawBalances only paints.
function L.layoutBalances(self, x, y, w, h)
    local g, mv = self.g, self.monthView
    g.monthY = nil
    if mv == nil then return h end
    local lineH = fontH.small + 6
    g.monthLineH = lineH
    mv.noteLines = U.wrapText(mv.note, math.max(60, w), 2)
    local need = fontH.medium + 8 + #mv.noteLines * lineH + (#mv.lines + (mv.empty and 1 or 0)) * lineH + PAD
    local boxH = math.max(math.min(h, fontH.small * 4 + 12),
        math.min(W.readerHeight(self.balanceLines or {}, w), h - need - 8))
    g.monthX, g.monthW, g.monthY = x, w, y + boxH + 8
    g.monthBottom = y + h
    -- columns: the kind as wide as the widest (at most 40% of the block), the amount at the right
    local labelW, amountW = 0, 0
    for _, line in ipairs(mv.lines) do
        if not line.head then
            labelW = math.max(labelW, textWidth(line.label))
            amountW = math.max(amountW, textWidth(line.amountText))
        end
    end
    labelW = math.min(labelW, math.floor(w * 0.4))
    g.monthLabelW, g.monthAmountW = labelW, amountW
    for _, line in ipairs(mv.lines) do
        if line.head then
            line.inW, line.outW = textWidth(line.inText), textWidth(line.outText)
            line.fit = fitText(line.text, math.max(0, w - line.inW - line.outW - COIN_SMALL - PAD * 3))
        else
            line.fit = fitText(line.label, labelW)
        end
    end
    return boxH
end

-- "This month" under the balances: a title, the scope (or why it is incomplete), then per
-- currency its income and spending and one bar per kind (green in, red out). Lines that do not fit
-- the card are left out, never squeezed.
function L.drawBalances(self)
    local g, mv = self.g, self.monthView
    if mv == nil or g.monthY == nil or mv.noteLines == nil then return end   -- laid out by L.layoutBalances
    local x, w, y, bottom, lh = g.monthX, g.monthW, g.monthY, g.monthBottom, g.monthLineH
    if y + fontH.medium > bottom then return end
    local c = U.color("border")
    self:drawRect(x, y - 4, w, 1, c.a * 0.5, c.r, c.g, c.b)
    text(self, mv.title, x, y + 2, "text", UIFont.Medium)
    y = y + fontH.medium + 8
    for i = 1, #(mv.noteLines or {}) do
        if y + lh > bottom then return end
        text(self, mv.noteLines[i], x, y + 3, mv.noteToken)
        y = y + lh
    end
    if mv.empty and y + lh <= bottom then text(self, mv.empty, x, y + 3, "textMuted") end
    local track = U.color("selected")
    local barX = x + g.monthLabelW + PAD
    local barW = math.max(0, w - g.monthLabelW - g.monthAmountW - PAD * 2)
    for i = 1, #mv.lines do
        if y + lh > bottom then return end
        local line = mv.lines[i]
        local ty = y + 3
        if line.head then
            drawCoin(self, line.coin, x, y + math.floor((lh - COIN_SMALL) / 2), COIN_SMALL)
            text(self, line.fit, x + COIN_SMALL + 6, ty, "text")
            textRight(self, line.outText, x + w, ty, "negative")
            textRight(self, line.inText, x + w - line.outW - PAD, ty, "positive")
        else
            text(self, line.fit, x + 4, ty, "textMuted")
            local by = y + math.floor((lh - 8) / 2)
            self:drawRect(barX, by, barW, 8, track.a, track.r, track.g, track.b)
            local fillW = math.floor(barW * line.frac + 0.5)
            if fillW > 0 then
                local bc = U.color(line.token)
                self:drawRect(barX, by, fillW, 8, 1, bc.r, bc.g, bc.b)
            end
            textRight(self, line.amountText, x + w, ty, line.token)
        end
        y = y + lh
    end
end

function L.drawWallet(self)
    local g = self.g
    local bx, bw = g.bodyX, g.bodyW
    local title = fitText(getText(T .. (g.walletBalances and "Wallet_Balances" or "Wallet_Statement")),
        math.max(0, g.walletTitleW), UIFont.Medium)
    card(self, bx, g.contentY, bw, g.workH, title, g.walletHeaderH)
    if g.walletBalances then return L.drawBalances(self) end
    if g.walletFilters then self.walletBar:draw(self) end
    if not g.walletList then return end
    local cols = self.list.cols
    local hx = self.list.x
    local lineH = self.list.rowHeight
    -- the header: the framework's sortable one (rev 12, its own child), else painted here while
    -- the bar keeps its sort chips
    if not self.walletHeader then
        local hy = g.tableHeaderY
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
            if cols.status then text(self, getText(T .. "Wallet_Col_Status"), hx + cols.status, ty, "textMuted") end
        end
    end
    -- pager, then the footer note: what this list really is, most urgent first (a compact painted
    -- header carries the count itself)
    self.walletBar:drawPager(self, cols.compact and not self.walletHeader)
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
    elseif C.identityUnverified and all == 0 then
        -- the server does not answer this login: no read is on its way, say why instead of loading
        U.emptyState(self, "wallet", self.list.x, self.list.y, self.list.width, self.list.height,
            getText(T .. "Player_IdentityUnverified"), self:identityText())
        U.drawEmptyState(self, "wallet")
    elseif self.walletGate:busy() and all == 0 then
        note = getText(T .. "Wallet_Loading")      -- the first read of all is never an empty page
    elseif n == 0 and all > 0 then
        -- the filters emptied it: the empty state over the table, its one step drops them
        L.drawEmpty(self, self.walletEmptyButton, "wallet", self.list, getText(T .. "Filter_NoMatch"), nil,
            getText(T .. "Market_ClearFilters"), true)
    elseif all == 0 then
        U.emptyState(self, "wallet", self.list.x, self.list.y, self.list.width, self.list.height,
            getText(T .. "Wallet_Empty"), getText(T .. "Wallet_EmptyBody"))
        U.drawEmptyState(self, "wallet")
    elseif self.walletBar:getQuery() ~= nil then
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

-- ---------- rewards: the daily card and the milestone card ----------
-- Panel:syncRewards words everything (once per second and on every reply) into self.rw; the
-- layout places it and the paint only draws what both left behind. Two texts may wrap -- the hint
-- under the progress bar and the survival line -- and their wrapped lines are measured here, so a
-- change of either text runs one layout (drawRewards notices) instead of a wrap per frame.
local RW_BAR_H = 8

function L.layoutRewards(self, on)
    self.claimButton:setVisible(on)
    if not on then return end
    if self.rw == nil or self.rw.state ~= C.rewards then self:syncRewards() end
    local g, rw = self.g, self.rw
    local x, w = g.bodyX, g.bodyW
    local lineH = fontH.small + 2
    local rules, b = self.rulesButton, self.claimButton
    -- the daily card: title, then the two pills beside it when they fit (else on a row of their
    -- own, wrapping, never cut), the rules chip at the far right of the title row
    g.rwRulesX = x + w - PAD - rules.width
    g.rwRulesY = g.contentY + math.floor((CARD_TITLE_H - rules.height) / 2)
    local pillsW = U.pillWidth(getText(T .. "Rewards_PillToday"), getText(T .. "Rewards_PillTodayValue", "99", "99"))
        + 6 + U.pillWidth(getText(T .. "Rewards_PillReset"),
            getText(T .. "Rewards_PillResetIn", U.durationText(86340000)))
    local titleW = textWidth(getText(T .. "Rewards_Daily"), UIFont.Medium)
    g.rwPillsInline = x + PAD * 2 + titleW + pillsW + 8 <= g.rwRulesX
    local y = g.contentY + CARD_TITLE_H + PAD
    if g.rwPillsInline then
        g.rwPillY = g.contentY + math.floor((CARD_TITLE_H - CHIP_H) / 2)
    else
        g.rwPillY = y
        y = y + ((pillsW <= w - PAD * 2) and CHIP_H or (CHIP_H * 2 + 6)) + PAD
    end
    -- the claim button on the right, the online line, the bar and the hint on the left
    b:setHeight(math.max(40, fontH.medium + 16))
    b:setWidth(math.min(math.max(160, textWidth(b.fullTitle or "", UIFont.Medium) + COIN_SMALL + 50),
        math.floor(w / 2)))
    U.setButtonTitle(b, b.fullTitle or "", UIFont.Medium)
    g.rwLeftX = x + PAD * 2
    g.rwLeftW = math.max(60, x + w - PAD * 4 - b.width - g.rwLeftX)
    rw.hintLines = U.wrapText(rw.body or rw.hint or "", g.rwLeftW, 2)
    rw.hintLaid = rw.body or rw.hint
    local leftH = lineH + 6 + RW_BAR_H + 6 + lineH * math.max(1, #rw.hintLines)
    local bodyH = math.max(b.height, leftH)
    g.rwLineY = y + math.floor((bodyH - leftH) / 2)
    g.rwBarY = g.rwLineY + lineH + 6
    g.rwHintY = g.rwBarY + RW_BAR_H + 6
    b:setX(x + w - PAD * 2 - b.width)
    b:setY(y + math.floor((bodyH - b.height) / 2))
    g.rwDailyH = y + bodyH + PAD - g.contentY
    -- the milestone card: the survival line (wrapping), the track, the one note
    local my = g.contentY + g.rwDailyH + PAD
    g.rwMileY = my
    rw.survLines = U.wrapText(rw.survivalText or "", w - PAD * 4, 3)
    rw.survLaid = rw.survivalText
    my = my + CARD_TITLE_H + PAD
    g.rwSurvY = my
    my = my + lineH * math.max(1, #rw.survLines) + PAD
    g.rwDot = math.max(22, fontH.small + 10)
    g.rwTrackY = my
    my = my + g.rwDot + 6 + lineH * 3 + PAD
    g.rwNoteY = my
    g.rwMileH = my + lineH + PAD - g.rwMileY
end

-- A line of `t`-pixel squares from one point to another: the check mark of a reached milestone,
-- drawn rather than taken from a font glyph (CH/CN fonts carry no reliable check sign).
local function stroke(el, x1, y1, x2, y2, t, c)
    local steps = math.max(1, math.floor(math.max(math.abs(x2 - x1), math.abs(y2 - y1))))
    for i = 0, steps do
        local f = i / steps
        el:drawRect(math.floor(x1 + (x2 - x1) * f), math.floor(y1 + (y2 - y1) * f), t, t, c.a, c.r, c.g, c.b)
    end
end

-- One milestone on the track: reached (a green disc with a check), the next one (an accent ring
-- around its day count) or a later one (a grey disc), and under it its days, its amount and --
-- for the next one -- how many days are still missing. Shape and words say the state, not colour.
local function drawMark(self, mark, cx, y, d, labelW)
    local Skin, color = U.framework.Skin, U.color
    local left = cx - math.floor(d / 2)
    local lineH = fontH.small + 2
    local numY = y + math.floor((d - fontH.small) / 2)
    if mark.state == "done" then
        Skin.dot(self, left, y, d, color("positive"), nil, U.alpha)
        local c, cy = color("surface"), y + math.floor(d / 2)
        stroke(self, cx - d * 0.25, cy, cx - d * 0.07, cy + d * 0.18, 2, c)
        stroke(self, cx - d * 0.07, cy + d * 0.18, cx + d * 0.25, cy - d * 0.2, 2, c)
    elseif mark.state == "next" then
        Skin.dot(self, left, y, d, color("accent"), nil, U.alpha)
        Skin.dot(self, left + 2, y + 2, d - 4, color("surface"), nil, U.alpha)
        textCentre(self, mark.number, cx, numY, "accent")
    else
        -- a grey ring, not a grey disc: the muted day count stays readable on the surface
        Skin.dot(self, left, y, d, color("border"), nil, U.alpha)
        Skin.dot(self, left + 2, y + 2, d - 4, color("surface"), nil, U.alpha)
        textCentre(self, mark.number, cx, numY, "textMuted")
    end
    local ty = y + d + 6
    textCentre(self, fitText(mark.daysText, labelW), cx, ty, mark.state == "future" and "textMuted" or "text")
    textCentre(self, fitText(mark.amountText, labelW), cx, ty + lineH, mark.state == "done" and "positive" or "textMuted")
    if mark.toGo then textCentre(self, fitText(mark.toGo, labelW), cx, ty + lineH * 2, "accent") end
end

function L.drawRewards(self)
    local g, rw = self.g, self.rw
    if rw == nil or g.rwDailyH == nil then return end
    -- once per second (and on a new state) the words follow the clock; a text that wraps
    -- differently now runs one layout
    if rw.state ~= C.rewards or rw.second ~= math.floor(EC.now() / 1000) then self:syncRewards() end
    if (rw.body or rw.hint) ~= rw.hintLaid or rw.survivalText ~= rw.survLaid then
        self:layout()
        g = self.g
    end
    local x, w = g.bodyX, g.bodyW
    local lineH = fontH.small + 2
    card(self, x, g.contentY, w, g.rwDailyH, getText(T .. "Rewards_Daily"))
    local hintToken = rw.body and rw.bodyToken or rw.hintToken
    if not rw.body then
        -- the two pills: beside the title (right-aligned against the rules chip), or on a row of
        -- their own that wraps instead of cutting a number
        local l1, v1 = getText(T .. "Rewards_PillToday"), rw.todayValue
        local l2, v2 = getText(T .. "Rewards_PillReset"), rw.resetValue
        local w1, w2 = U.pillWidth(l1, v1), U.pillWidth(l2, v2)
        if g.rwPillsInline then
            local px = g.rwRulesX - 8 - w2
            U.drawPill(self, px, g.rwPillY, l2, v2)
            U.drawPill(self, px - 6 - w1, g.rwPillY, l1, v1)
        else
            local px = x + PAD
            U.drawPill(self, px, g.rwPillY, l1, v1)
            if px + w1 + 6 + w2 <= x + w - PAD then
                U.drawPill(self, px + w1 + 6, g.rwPillY, l2, v2)
            else
                U.drawPill(self, px, g.rwPillY + CHIP_H + 6, l2, v2)
            end
        end
        if not rw.off then
            local lx, lw = g.rwLeftX, g.rwLeftW
            text(self, fitText(rw.onlineText, lw - textWidth(rw.statusText) - PAD), lx, g.rwLineY, "text")
            textRight(self, rw.statusText, lx + lw, g.rwLineY, rw.statusToken)
            fill(self, lx, g.rwBarY, lw, RW_BAR_H, "track", "rect")
            local done = math.floor(lw * rw.progress)
            if done > 0 then fill(self, lx, g.rwBarY, done, RW_BAR_H, rw.progress >= 1 and "positive" or "accent", "rect") end
        end
    end
    -- the one hint line (or, before the first answer, the loading / error line), wrapped by layout
    local hy = rw.off and g.rwLineY or g.rwHintY
    if rw.body then hy = g.rwLineY end
    for i = 1, #(rw.hintLines or {}) do
        text(self, rw.hintLines[i], g.rwLeftX, hy + (i - 1) * lineH, hintToken)
    end
    if rw.body then return end
    -- the milestone card
    local my = g.rwMileY
    local title = getText(T .. "Rewards_MilestoneTitle")
    card(self, x, my, w, g.rwMileH, title)
    local titleR = x + PAD + textWidth(title, UIFont.Medium) + PAD
    local pillW = rw.seasonValue and U.pillWidth(rw.seasonLabel, rw.seasonValue) or 0
    if rw.seasonValue then
        U.drawPill(self, x + w - PAD - pillW, my + math.floor((CARD_TITLE_H - CHIP_H) / 2), rw.seasonLabel, rw.seasonValue)
    end
    text(self, fitText(rw.seasonSub, math.max(0, x + w - PAD * 2 - pillW - titleR)), titleR,
        my + math.floor((CARD_TITLE_H - fontH.small) / 2), "textMuted")
    for i = 1, #(rw.survLines or {}) do
        text(self, rw.survLines[i], x + PAD * 2, g.rwSurvY + (i - 1) * lineH, rw.survivalToken)
    end
    local n = rw.markCount or 0
    if n > 0 then
        local d = g.rwDot
        local spacing = (w - PAD * 4) / n
        local cy = g.rwTrackY + math.floor(d / 2)
        local marks = rw.marks
        -- the rail between the discs: green up to the last reached milestone
        for i = 1, n - 1 do
            local x1 = math.floor(x + PAD * 2 + spacing * (i - 0.5))
            local x2 = math.floor(x + PAD * 2 + spacing * (i + 0.5))
            local token = (marks[i].state == "done" and marks[i + 1].state == "done") and "positive" or "border"
            fill(self, x1, cy - 1, x2 - x1, 2, token, "rect")
        end
        for i = 1, n do
            drawMark(self, marks[i], math.floor(x + PAD * 2 + spacing * (i - 0.5)), g.rwTrackY, d,
                math.max(20, math.floor(spacing) - 4))
        end
    end
    text(self, getText(T .. "Rewards_AutoNote"), x + PAD * 2, g.rwNoteY, "textMuted")
end

-- the shop and mailbox pages paint from their own module
L.drawShop, L.drawMail = C.PanelShopMail.drawShop, C.PanelShopMail.drawMail

-- An empty table says what the place is for and offers the one next step, centred over the
-- table's own rect. The button is the page's own: shown here, hidden by every layout and by the
-- paint the moment the table has rows again.
function L.drawEmpty(self, button, slot, list, title, body, label, enabled)
    local by = U.emptyState(self, slot, list.x, list.y, list.width, list.height, title, body)
    U.drawEmptyState(self, slot)
    if button.fullTitle ~= label then
        button:setWidth(textWidth(label) + 22)
        U.setButtonTitle(button, label)
    end
    button:setX(list.x + math.floor((list.width - button.width) / 2)); button:setY(by)
    button:setEnable(enabled)
    if not button:getIsVisible() then button:setVisible(true) end
end

-- History page: one card, the state band, the filter bar and the ring (newest first by default).
-- No column header (the kind label already names each line); the ring is paged on the client,
-- so the pager under the table is the bar's own. What the record holds is the rules chip's.
function L.drawMarketHistory(self)
    local g = self.g
    local list = self.marketHistoryList
    card(self, g.marketCardX, g.marketCardY, g.marketCardW, g.marketCardH, getText(T .. "Market_History_Title"))
    local x, y = g.marketCardX + PAD, g.marketCardY + CARD_TITLE_H
    local retryB = self.historyRetryButton
    local noteR = retryB:getIsVisible() and retryB.x - 6 or g.marketCardX + g.marketCardW - PAD
    local noteW = math.max(0, noteR - x)
    local snap = C.marketHistory
    -- The state band, most urgent first: a read that failed (historyRetryButton beside it is the
    -- only way it is asked again, while the snapshot underneath stays on screen marked as older
    -- data), the first read of all, then what this list actually holds - the keyword's own scope
    -- and the server's own record limit. Wrapped into its two lines, never cut.
    if self.marketHistoryError then
        local note = historyError(self.marketHistoryError)
        if snap then note = note .. "  " .. getText(T .. "History_Stale") end
        L.drawStateNote(self, "marketStateNote", note, x, y, noteW, "errorText")
        if not snap then return end     -- nothing was ever read: no bar, no pager, no empty line
    elseif not snap then
        text(self, getText(T .. "Wallet_Loading"), x, rowTextY(y), "textMuted")
        return
    else
        local loaded = #(self.marketHistoryAll or {})
        local scoped = self.historyBar:getQuery() ~= nil
        if snap.truncated == true then
            local note = getText(T .. "Market_History_Truncated", tostring(loaded))
            if scoped then note = getText(T .. "Filter_SearchScope", tostring(loaded)) .. "  " .. note end
            L.drawStateNote(self, "marketStateNote", note, x, y, noteW, "warn")
        elseif scoped then
            L.drawStateNote(self, "marketStateNote", getText(T .. "Filter_SearchScope", tostring(loaded)),
                x, y, noteW, "textMuted")
        end
    end
    self.historyBar:draw(self)
    self.historyBar:drawPager(self)
    if list:getIsVisible() and #list:getItems() == 0 then
        local all = #(self.marketHistoryAll or {})
        self.marketEmptyAction = all > 0 and "clearHistory" or "browse"
        L.drawEmpty(self, self.marketEmptyButton, "marketHistory", list,
            getText(T .. (all > 0 and "Filter_NoMatch" or "Market_History_Empty")),
            all == 0 and getText(T .. "Market_History_EmptyBody") or nil,
            getText(T .. (all > 0 and "Market_ClearFilters" or "Market_GoBrowse")), true)
    elseif self.marketEmptyButton:getIsVisible() then
        self.marketEmptyButton:setVisible(false)
    end
end

function L.drawMarket(self)
    local g = self.g
    local mine = self.marketMode == "mine"
    local info = self.marketInfo
    if self.marketMode == "history" then return self:drawMarketHistory() end
    card(self, g.marketCardX, g.marketCardY, g.marketCardW, g.marketCardH, getText(T .. "Market_Title"))
    L.drawFeePills(self, g.marketPillX, g.marketPillY, info)
    local snap = mine and C.myListings or C.market
    local empty = self.marketEmptyButton
    if not snap then
        if empty:getIsVisible() then empty:setVisible(false) end
        text(self, getText(T .. "Wallet_Loading"), g.marketCardX + PAD,
            rowTextY(g.marketCardY + CARD_TITLE_H + g.marketPillH), "textMuted")
        return
    end
    if not mine then
        text(self, getText(T .. "Shop_Category"), self.marketCatCombo.x,
            self.marketCatCombo.y - fontH.small - 2, "textMuted")
        text(self, getText(T .. "Trade_Currency"), self.marketCurCombo.x,
            self.marketCurCombo.y - fontH.small - 2, "textMuted")
        text(self, getText(T .. "Filter_Sort"), self.marketSortCombo.x,
            self.marketSortCombo.y - fontH.small - 2, "textMuted")
    end
    -- the header row is a child (UI.TableHeader): it paints the column names and takes the clicks
    if #self.marketList:getItems() > 0 then
        if empty:getIsVisible() then empty:setVisible(false) end
    elseif self.marketNoMatch then
        self.marketEmptyAction = "clear"
        local query = self.marketQuery and self.marketSearch:getText() or ""
        L.drawEmpty(self, empty, "market", self.marketList, query ~= ""
            and getText(T .. "Market_NoMatchQuery", query) or getText(T .. "Market_NoMatch"),
            nil, getText(T .. "Market_ClearFilters"), true)
    else
        -- the player's own empty list, or an empty market, is where listing starts
        self.marketEmptyAction = "list"
        L.drawEmpty(self, empty, "market", self.marketList,
            getText(T .. (mine and "Market_MineEmpty" or "Market_Empty")),
            getText(T .. (mine and "Market_MineEmptyBody" or "Market_EmptyBody")),
            self.marketListButton.fullTitle, self.marketListButton.enable)
    end
    if mine then return end
    -- pager strip: the page counter, the two chips (children), the server's total on the right
    local fy = g.marketFooterY + math.floor((ROW - fontH.small) / 2)
    text(self, getText(T .. "Market_Page", tostring(self.marketPage), tostring(info.pages)),
        g.marketCardX + PAD, fy, "textMuted")
    textRight(self, getText(T .. "Market_Total", tostring(info.total)),
        g.marketCardX + g.marketCardW - PAD, fy, "textMuted")
end

-- Record page: one card, the state band and the client-paged ring. The band is the page's state
-- in one place, most urgent first: a refusal (the snapshot underneath stays on screen - an error
-- is not an empty record), the first read of all and the "only the newest 200" warning; what the
-- amounts mean is the rules chip's. A read still in flight over a snapshot says so on the right.
function L.drawAuctionHistory(self)
    local g = self.g
    local list = self.auctionHistoryList
    card(self, g.auctionCardX, g.auctionCardY, g.auctionCardW, g.auctionCardH,
        getText(T .. "Auction_History_Title"))
    local x, y = g.auctionCardX + PAD, g.auctionCardY + CARD_TITLE_H
    local ty = rowTextY(y)
    local retryB = self.historyRetryButton
    local noteR = retryB:getIsVisible() and retryB.x - 6 or g.auctionCardX + g.auctionCardW - PAD
    local pending = self.auctionGate:busy()
    local loading = getText(T .. "Wallet_Loading")
    local noteW = math.max(0, noteR - x - (pending and textWidth(loading) + PAD or 0))
    local snap = C.auctionHistory
    if self.auctionHistoryError then
        local note = historyError(self.auctionHistoryError)
        if snap then note = note .. "  " .. getText(T .. "History_Stale") end
        L.drawStateNote(self, "auctionStateNote", note, x, y, noteW, "errorText")
        if not snap then return end  -- nothing read yet: no bar, no pager, no empty-filter line
    elseif not snap then
        text(self, pending and loading or getText(T .. "Auction_History_Empty"), x, ty, "textMuted")
        return
    elseif self.auctionHistoryTruncated then
        L.drawStateNote(self, "auctionStateNote", getText(T .. "Auction_History_Truncated"), x, y, noteW, "warn")
    end
    if pending then textRight(self, loading, noteR, ty, "textMuted") end
    self.auctionHistoryBar:draw(self)
    self.auctionHistoryBar:drawPager(self)
    if list:getIsVisible() and #list:getItems() == 0 then
        local all = #(self.auctionHistoryAll or {})
        self.auctionEmptyAction = all > 0 and "clearHistory" or "browse"
        L.drawEmpty(self, self.auctionEmptyButton, "auctionHistory", list,
            getText(T .. (all > 0 and "Filter_NoMatch" or "Auction_History_Empty")),
            all == 0 and getText(T .. "Auction_History_EmptyBody") or nil,
            getText(T .. (all > 0 and "Market_ClearFilters" or "Auction_GoBrowse")), true)
    elseif self.auctionEmptyButton:getIsVisible() then
        self.auctionEmptyButton:setVisible(false)
    end
end

-- Auction page: one card (title, the two fee pills, the rules chip), then either the sortable
-- browse table with its pager or the two "my auctions" sections.
function L.drawAuction(self)
    if self.auctionMode == "history" then return self:drawAuctionHistory() end
    local g = self.g
    local info = self.auctionInfo
    local mine = self.auctionMode == "mine"
    card(self, g.auctionCardX, g.auctionCardY, g.auctionCardW, g.auctionCardH, getText(T .. "Auction_Title"))
    L.drawFeePills(self, g.auctionPillX, g.auctionPillY, info)
    local empty = self.auctionEmptyButton
    if (mine and not C.myAuctions) or (not mine and not C.auction) then
        if empty:getIsVisible() then empty:setVisible(false) end
        text(self, getText(T .. "Wallet_Loading"), g.auctionCardX + PAD,
            rowTextY(g.auctionCardY + CARD_TITLE_H + g.auctionPillH), "textMuted")
        return
    end
    if mine then
        local labelX = g.auctionCardX + PAD
        local selling, bidding = self.auctionSellList, self.auctionBidList
        if #selling:getItems() == 0 and #bidding:getItems() == 0 then
            self.auctionEmptyAction = "list"
            -- the empty state spans both sections (their tables stay where they are, empty)
            local area = self.auctionMineArea
            if area == nil then area = {}; self.auctionMineArea = area end
            area.x, area.y, area.width = selling.x, g.aucSellLabelY, selling.width
            area.height = g.aucMineBottom - g.aucSellLabelY
            L.drawEmpty(self, empty, "auctionMine", area, getText(T .. "Auction_MineEmpty"),
                getText(T .. "Auction_MineEmptyBody"), self.auctionCreateButton.fullTitle,
                self.auctionCreateButton.enable)
            return
        end
        if empty:getIsVisible() then empty:setVisible(false) end
        text(self, getText(T .. "Auction_SellingCount", tostring(#selling:getItems())),
            labelX, rowTextY(g.aucSellLabelY), "text")
        -- the server lists at most its cap of bids (soonest-ending first) and says how many exist
        local shown = #(C.myAuctions.bidding or {})
        local total = math.max(shown, tonumber(C.myAuctions.biddingTotal) or shown)
        text(self, getText(T .. "Auction_BiddingCount", tostring(total)), labelX, rowTextY(g.aucBidLabelY), "text")
        if total > shown then
            text(self, getText(T .. "Auction_BidsShown", tostring(shown)), labelX, rowTextY(g.aucBidNoteY), "textMuted")
        end
        -- one section empty while the other has rows: say so in it, rather than leave a blank band
        if #selling:getItems() == 0 then
            text(self, fitText(getText(T .. "Auction_SellingNone"), selling.width - PAD * 2), selling.x + PAD,
                rowTextY(selling.y), "textMuted")
        elseif #bidding:getItems() == 0 then
            text(self, fitText(getText(T .. "Auction_BiddingNone"), bidding.width - PAD * 2), bidding.x + PAD,
                rowTextY(bidding.y), "textMuted")
        end
        return
    end
    text(self, getText(T .. "Filter_Sort"), self.auctionSortCombo.x,
        self.auctionSortCombo.y - fontH.small - 2, "textMuted")
    text(self, getText(T .. "Trade_Currency"), self.auctionCurCombo.x,
        self.auctionCurCombo.y - fontH.small - 2, "textMuted")
    -- the header row is a child (UI.TableHeader): it paints the column names and takes the clicks
    if #self.auctionList:getItems() > 0 then
        if empty:getIsVisible() then empty:setVisible(false) end
    elseif self.auctionNoMatch then
        self.auctionEmptyAction = "clear"
        local query = self.auctionQuery and self.auctionSearch:getText() or ""
        L.drawEmpty(self, empty, "auction", self.auctionList, query ~= ""
            and getText(T .. "Auction_NoMatchQuery", query) or getText(T .. "Auction_NoMatch"),
            nil, getText(T .. "Market_ClearFilters"), true)
    else
        self.auctionEmptyAction = "list"
        L.drawEmpty(self, empty, "auction", self.auctionList, getText(T .. "Auction_Empty"),
            getText(T .. "Auction_EmptyBody"), self.auctionCreateButton.fullTitle, self.auctionCreateButton.enable)
    end
    local fy = g.auctionFooterY + math.floor((ROW - fontH.small) / 2)
    text(self, getText(T .. "Market_Page", tostring(self.auctionPage), tostring(info.pages)),
        g.auctionCardX + PAD, fy, "textMuted")
    textRight(self, getText(T .. "Auction_Total", tostring(info.total)),
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
