-- MinidoracatEconomyFor42 - the tile grids of the Economy Center's item pages (client).
--
-- The shop, the market's browse page and the auction's browse page can each show their items as a
-- grid of tiles instead of the table: a player preference per page (ECOptions `ShopGrid` /
-- `MarketGrid` / `AuctionGrid`, default off), switched by the List / Grid tabs at the right end
-- of the page's toolbar. Switching sends nothing and keeps the search, the filters and the pick.
--
-- A grid is a second view over the page's own table. The rows, the picked row and the source list
-- the record window reads all stay on that table (hidden while the grid shows), so buying, selling
-- and bidding keep the one path they had: a tile opens the row's record card exactly as a click on
-- the row does, and the card's buttons run the row's own action (Panel:onDetailAction). The table
-- keeps its geometry under the grid, so the empty, loading and error states paint where they did.
-- VirtualList is one column, so one list row holds a strip of tiles (W.gridStrips), the way the
-- listing dialog's backpack picker does; the hit test and the keys are the picker's too.
--
-- Called by the window (G.create in createChildren) and by the page layouts (G.on / G.pinRight /
-- G.fit); no request, no event, no state beyond the grid's own geometry and cursor.

require "MinidoracatEconomy/ECWidgets"
require "MinidoracatEconomy/ECKeyboard"
require "MinidoracatEconomy/ECOptions"
require "MinidoracatEconomy/ECPanelWidgets"

local EC = MinidoracatEconomy
local C = EC.Client
local U = C.UI
local W = C.PanelWidgets
local O = EC.Options
local Keys = C.Keyboard

local G = {}
C.PanelGrid = G

local T = U.T
local fontH = U.fontH
local fill, text, textCentre, textRight, textWidth, fitText = U.fill, U.text, U.textCentre, U.textRight, U.textWidth, U.fitText
local drawCoin, amountText, litToken = U.drawCoin, U.amountText, W.litToken
local TILE_ICON = 48

-- The window fields of each page: its table, its grid and its List / Grid tabs; the tile `kind`;
-- the keyboard label the grid shares with the table (the per-tile caption replaces it on rev 16).
local PAGES = {
    shop = { list = "shopList", grid = "shopGrid", tabs = "shopViewTabs", kind = "shop", label = "Shop_Title" },
    market = { list = "marketList", grid = "marketGrid", tabs = "marketViewTabs", kind = "market", label = "Kb_Market_List" },
    auction = { list = "auctionList", grid = "auctionGrid", tabs = "auctionViewTabs", kind = "auction", label = "Kb_Auction_List" },
}
G.PAGES = PAGES

-- Text lines under a tile's icon: two for the name, the price, then one (shop, market) or two
-- (auction: time left and the bids) for what the table's other columns said.
local LINES = { shop = 4, market = 4, auction = 5 }

local function lineH() return fontH.small + 2 end
local function coinSize() return math.max(12, math.min(20, fontH.small + 2)) end

-- The smallest tile of a page, from the font alone (every window is built after U.init): the
-- price line holds 999,999 with its coin, and on the trade pages the widest currency name too.
function G.tileSize(kind)
    local priceW = coinSize() + 4 + textWidth("999,999")
    if kind ~= "shop" then priceW = priceW + 4 + textWidth(W.currencySample()) end
    local w = math.max(112, priceW + 16)
    local h = 6 + fontH.small + 2 + TILE_ICON + 4 + lineH() * LINES[kind] + 6
    return w, h
end

-- Tiles per strip for a list `width` wide, and the tile width once the spare room is shared out.
-- The scrollbar's 12 px is always set aside (as in the picker), so the strips never reflow when
-- it appears.
function G.columns(width, tileW)
    local room = math.max(tileW, width - 12)
    local n = math.max(1, math.floor(room / tileW))
    return n, math.floor(room / n)
end

-- Is the page's grid the view in force? The trade pages ask it for their browse mode only.
function G.on(page)
    return O.gridView(page)
end

-- ---------- what a tile says ----------
-- Every string a tile paints, measured once per row and tile width. The rows are rebuilt with
-- every snapshot, so the cache lives on the row itself and the paint allocates nothing.

local function nameLines(e, w)
    local name = tostring(e.name or "")
    local first = U.wrapText(name, w, 1)[1] or ""
    local rest = string.gsub(string.sub(name, #first + 1), "^%s+", "")
    e.gtName1 = first
    e.gtName2 = rest ~= "" and fitText(rest, w) or nil
end

-- The price line: an optional label, the coin, the amount and an optional currency name, centred
-- as one run. When it cannot fit, the label goes first, then the amount is cut.
local function priceLine(e, w, label, coin, amount, token, curText)
    local cs = coinSize()
    local function width()
        local n = textWidth(amount)
        if coin then n = n + cs + 4 end
        if label then n = n + textWidth(label) + 4 end
        if curText then n = n + 4 + textWidth(curText) end
        return n
    end
    if label and width() > w then label = nil end
    if width() > w then
        local others = width() - textWidth(amount)
        amount = fitText(amount, math.max(0, w - others))
    end
    e.gtLabel, e.gtCoin, e.gtPrice, e.gtPriceToken, e.gtCur = label, coin, amount, token, curText
    e.gtLabelW, e.gtAmountW, e.gtPriceW = label and textWidth(label) or 0, textWidth(amount), width()
end

local function shopWords(e, w)
    e.gtLot = (e.qty or 1) > 1 and getText(T .. "Market_Lot", tostring(e.qty)) or nil
    e.gtTag, e.gtTagToken = nil, nil
    if e.delisted then
        e.gtTag, e.gtTagToken = e.tagText, "warn"
        priceLine(e, w, getText(T .. "Shop_Col_Bid"), e.bidPrice ~= nil and e.currency or nil,
            e.bidPrice ~= nil and amountText(e.bidPrice) or "-", "text")
    elseif e.hasQuote then
        priceLine(e, w, nil, e.currency, e.priceText, "accent")
    else
        priceLine(e, w, nil, nil, getText(T .. "Shop_NoQuote"), "textMuted")
    end
    -- the last line holds one fact, in this order: sold out, the share left, the buyback price,
    -- or for a sku without a price here the price it has in another currency
    local sub, token = nil, "textFaint"
    if e.soldOut then
        sub, token = getText(T .. "Shop_SoldOutButton"), "negative"
    elseif e.delisted then
        sub = nil
    elseif (e.dailyCap or 0) > 0 then
        sub = getText(T .. "Shop_TileLeft", tostring(math.max(0, e.remaining or e.dailyCap)))
    elseif e.buyback and e.bidPrice ~= nil then
        sub = getText(T .. "Shop_BidLine", amountText(e.bidPrice))
    elseif not e.hasQuote then
        for _, q in ipairs(e.quotes or {}) do
            if q.currency ~= e.currency and q.enabled then
                sub = W.moneyText(q.price, q.currency)
                break
            end
        end
    end
    e.gtSub1, e.gtSub1Token = sub and fitText(sub, w) or nil, token
    e.gtSub2 = nil
    e.gtDim = e.soldOut == true
end

local function marketWords(e, w)
    e.gtLot = (e.qty or 1) > 1 and getText(T .. "Market_Lot", tostring(e.qty)) or nil
    e.gtTag, e.gtTagToken = nil, nil
    -- the currency is named beside the coin: one page may quote two (the table's own rule)
    priceLine(e, w, nil, e.currency, e.priceText, "accent", e.currencyText)
    local sub, token = e.seller, "textMuted"
    if e.blocked then
        sub, token = e.actionLabel, "warn"
    elseif e.own then
        sub, token = getText(T .. "Market_Own"), "textFaint"
    end
    e.gtSub1, e.gtSub1Token = fitText(tostring(sub or ""), w), token
    e.gtSub2 = nil
    e.gtDim = false
end

local function auctionWords(e, w)
    e.gtLot = (e.qty or 1) > 1 and getText(T .. "Market_Lot", tostring(e.qty)) or nil
    -- the player's own standing in this auction, where the table had its action column
    e.gtTag, e.gtTagToken = nil, nil
    if e.mine then
        e.gtTag, e.gtTagToken = getText(T .. "Auction_Own"), "textMuted"
    elseif e.ended then
        e.gtTag, e.gtTagToken = getText(T .. "Auction_Ended"), "warn"
    elseif e.leading then
        e.gtTag, e.gtTagToken = getText(T .. "Auction_Leading"), "positive"
    end
    -- the current bid, or the opening price while nobody has bid (the last line says which)
    priceLine(e, w, nil, e.currency, amountText(e.price or 0), "accent", e.currencyText)
    e.gtSub1, e.gtSub1Token = fitText(tostring(e.expiresText or ""), w), e.expiresToken or "textFaint"
    if e.blocked then
        e.gtSub2, e.gtSub2Token = fitText(tostring(e.actionLabel or ""), w), "warn"
    elseif (e.bids or 0) > 0 then
        e.gtSub2, e.gtSub2Token = fitText(getText(T .. "Detail_Line", getText(T .. "Auction_Col_Bids"),
            tostring(e.bids)), w), "textMuted"
    else
        e.gtSub2, e.gtSub2Token = fitText(getText(T .. "Auction_NoBids"), w), "textFaint"
    end
    e.gtDim = e.ended == true
end

local WORDS = { shop = shopWords, market = marketWords, auction = auctionWords }

-- Fills the row's gt* fields for a tile `tw` wide (the paint calls it once per row and width).
function G.words(kind, e, tw)
    local w = tw - 12
    nameLines(e, w)
    WORDS[kind](e, w)
    if e.gtTag then
        local room = w - (e.gtLot and (textWidth(e.gtLot) + 6) or 0)
        e.gtTag = fitText(e.gtTag, math.max(0, room))
    end
    e.gtW = tw
end
local words = G.words

-- ---------- the tile strip ----------
-- One list row: up to perRow tiles side by side. A tile is a read like a table row: it picks the
-- row and opens its record, nothing on it spends money. The picked row (the table's own selection)
-- and the tile under the mouse are lit, and lit tiles read their muted text as plain text.
local Tile = ISPanel:derive("MinidoracatEconomyGridTile")
G.Tile = Tile

function Tile:render()
    local strip = self.entry
    if not strip then return end
    local list = self.list
    local kind, tw, th = list.ecKind, list.cols.tileW, self.height
    if not tw then return end
    local base = (self.index - 1) * (list.ecPerRow or 1)
    local picked = list.ecSource:getSelectedIndex()
    local hot = nil
    if self:isMouseOver() then hot = math.floor(self:getMouseX() / tw) + 1 end
    local lh, cs = lineH(), coinSize()
    for i = 1, #strip do
        local e = strip[i]
        local x = (i - 1) * tw
        if e.gtW ~= tw then words(kind, e, tw) end
        local isPicked = picked == base + i
        local lit = isPicked or hot == i
        fill(self, x + 2, 2, tw - 4, th - 4, "card", "round")
        if isPicked then fill(self, x + 2, 2, tw - 4, th - 4, "selected", "round") end
        if hot == i then fill(self, x + 2, 2, tw - 4, th - 4, "hover", "round") end
        local y = 6
        if e.gtLot then textRight(self, e.gtLot, x + tw - 8, y, "accent") end
        if e.gtTag then text(self, e.gtTag, x + 8, y, litToken(lit, e.gtTagToken)) end
        y = y + fontH.small + 2
        if e.texture then
            self:drawTextureScaled(e.texture, x + math.floor((tw - TILE_ICON) / 2), y, TILE_ICON, TILE_ICON,
                e.gtDim and 0.4 or 1, 1, 1, 1)
        end
        y = y + TILE_ICON + 4
        local cx = x + math.floor(tw / 2)
        textCentre(self, e.gtName1, cx, y, "text")
        if e.gtName2 then textCentre(self, e.gtName2, cx, y + lh, "text") end
        y = y + lh * 2
        local px = x + math.floor((tw - e.gtPriceW) / 2)
        if e.gtLabel then
            text(self, e.gtLabel, px, y, litToken(lit, "textMuted"))
            px = px + e.gtLabelW + 4
        end
        if e.gtCoin then
            drawCoin(self, e.gtCoin, px, y + math.floor((fontH.small - cs) / 2), cs)
            px = px + cs + 4
        end
        text(self, e.gtPrice, px, y, litToken(lit, e.gtPriceToken))
        if e.gtCur then text(self, e.gtCur, px + e.gtAmountW + 4, y, litToken(lit, "textMuted")) end
        y = y + lh
        if e.gtSub1 then textCentre(self, e.gtSub1, cx, y, litToken(lit, e.gtSub1Token)) end
        if e.gtSub2 then textCentre(self, e.gtSub2, cx, y + lh, litToken(lit, e.gtSub2Token)) end
    end
end

-- ---------- the grid list ----------

-- The grid's cursor (strip + column) on the table's picked row; `reveal` scrolls it into view.
function G.follow(grid, reveal)
    local i = grid.ecSource:getSelectedIndex()
    grid.ecSel = i
    if i == nil then
        grid:setSelectedIndex(nil)
        return
    end
    local per = grid.ecPerRow or 1
    local strip = math.floor((i - 1) / per) + 1
    grid.ecColumn = (i - 1) % per + 1
    grid:setSelectedIndex(strip)
    if reveal then grid:scrollToIndex(strip) end
end

-- The table got new rows (its items table was replaced) or the strips another width: cut the
-- strips again. The table's pick moved from elsewhere (a card's button, a fresh snapshot): the
-- cursor follows it. Two comparisons per frame while nothing changed.
function G.sync(grid)
    local src = grid.ecSource
    if grid.ecItems ~= src.items or grid.ecPerRow ~= grid.ecWantPerRow then
        grid.ecItems, grid.ecPerRow = src.items, grid.ecWantPerRow
        grid:setItems((W.gridStrips(src.items, grid.ecPerRow)))
        grid.ecSel = false
    end
    if src:getSelectedIndex() ~= grid.ecSel then G.follow(grid, false) end
end

-- Tile `col` of strip `strip` becomes the table's picked row (and the grid's cursor); `open` then
-- runs the table's own onSelect, the row's record card, exactly as a click on the row does.
function G.pick(grid, strip, col, open)
    local src = grid.ecSource
    local i = (strip - 1) * (grid.ecPerRow or 1) + col
    local row = src.items[i]
    if row == nil then return end
    grid.ecColumn = col
    grid:setSelectedIndex(strip)
    src:setSelectedIndex(i)
    grid.ecSel = i
    if open and src.onSelect then src.onSelect(src, row, i) end
end

function G.prerender(grid)
    G.sync(grid)
    grid.ecBasePrerender(grid)
end

-- A press on a tile picks it and opens its record; the scrollbar keeps the list's own handler,
-- and a press between tiles picks nothing.
function G.onMouseDown(grid, x, y)
    local e, strip, col = W.tileAt(grid, x, y)
    if e ~= nil then
        G.pick(grid, strip, col, true)
        return true
    end
    if x >= grid:cellWidth() then return grid.ecBaseMouseDown(grid, x, y) end
    return true
end

-- The picker's keys (W.gridFocusKey); a moved cursor picks its tile on the table, Enter opens it.
function G.onFocusKey(grid, key)
    local taken, open = W.gridFocusKey(grid, key)
    if not taken then return false end
    local strip = grid:getSelectedIndex()
    if strip == nil then
        -- Enter before any tile was picked: the first one
        if #grid.items == 0 then return true end
        strip, grid.ecColumn = 1, 1
        open = true
    end
    local tiles = grid.items[strip]
    G.pick(grid, strip, math.min(grid.ecColumn or 1, #tiles), open ~= nil)
    return true
end

-- Framework rev 12: the focus ring frames the cursor's tile instead of the whole grid (an older
-- framework ignores this and rings the grid). nil while that tile is scrolled out of view.
function G.focusRect(grid)
    local strip, tw = grid:getSelectedIndex(), grid.cols.tileW
    if strip == nil or tw == nil then return nil end
    local th = grid.rowHeight
    local y = grid.padding + (strip - 1) * (th + grid.padding) - grid.scrollOffset
    if y < 0 or y + th > grid.height then return nil end
    return ((grid.ecColumn or 1) - 1) * tw + 6, y + 6, tw - 12, th - 12
end

-- What the cursor's tile costs, in words (the focus caption)
function G.priceWords(kind, row)
    if kind == "shop" then
        if row.hasQuote then return W.moneyText(row.price, row.currency) end
        if row.delisted and row.bidPrice ~= nil then
            return getText(T .. "Shop_BidLine", W.moneyText(row.bidPrice, row.currency))
        end
        return row.priceText
    end
    if kind == "auction" and row.bid == nil then
        return getText(T .. "Auction_StartsAt", W.moneyText(row.price, row.currency))
    end
    return W.moneyText(row.price, row.currency)
end

-- Framework rev 16: the caption beside the ring names the cursor's tile and its price, built again
-- only when the picked row changes (an older framework shows the grid's label instead).
function G.focusLabel(grid)
    local row = grid.ecSource:getSelectedItem()
    if row ~= grid.ecLabelRow then
        grid.ecLabelRow = row
        grid.ecLabelText = row ~= nil and getText(T .. "Detail_Line", tostring(row.name or ""),
            G.priceWords(grid.ecKind, row)) or nil
    end
    return grid.ecLabelText
end

-- ---------- the window's side ----------

-- The three grids and their List / Grid tabs, after the window built the three tables.
function G.create(panel)
    for page, spec in pairs(PAGES) do
        local src = panel[spec.list]
        local _, th = G.tileSize(spec.kind)
        local grid = U.newTable(Tile, th)
        grid.ecPage, grid.ecKind, grid.ecSource = page, spec.kind, src
        grid.ecPerRow, grid.ecWantPerRow, grid.ecSel = 1, 1, false
        grid.ecBaseMouseDown, grid.ecBasePrerender = grid.onMouseDown, grid.prerender
        grid.onMouseDown, grid.prerender = G.onMouseDown, G.prerender
        grid.onFocusKey, grid.focusRect, grid.focusLabel = G.onFocusKey, G.focusRect, G.focusLabel
        grid:setVisible(false)
        panel:addChild(grid)
        panel[spec.grid] = grid
        src.ecGrid = grid
        local tabs = W.modeTabs(panel, { { id = "list", label = getText(T .. "View_List") },
            { id = "grid", label = getText(T .. "View_Grid") } }, O.gridView(page) and "grid" or "list", G.onTabs)
        tabs.ecPage = page
        tabs:setVisible(false)
        panel[spec.tabs] = tabs
    end
end

-- The keyboard descriptors of a page's view: its tabs and its grid (ECKeyboard drops whichever
-- is hidden, so the page lists them beside its table's own).
function G.targets(panel, page, out)
    local spec = PAGES[page]
    out[#out + 1] = { kind = "button", control = panel[spec.tabs], label = getText(T .. "Kb_View") }
end

function G.gridTarget(panel, page, out)
    local spec = PAGES[page]
    out[#out + 1] = { kind = "list", control = panel[spec.grid], label = getText(T .. spec.label) }
end

function G.onTabs(panel, id, tabs)
    G.setView(panel, tabs.ecPage, id == "grid")
end

-- The player switched views: the choice is stored, the page laid out again, and the picked row
-- kept in sight in the view it lands on.
function G.setView(panel, page, grid)
    O.setGridView(page, grid)
    local spec = PAGES[page]
    panel:layout()
    local src = panel[spec.list]
    local i = src:getSelectedIndex()
    if i ~= nil then
        if grid then G.follow(panel[spec.grid], true) else src:scrollToIndex(i) end
    end
    Keys.invalidate(panel)
end

-- A toolbar placed by W.placeRow: `a`, then `b` (optional), move to the right end of the row the
-- first control (`first`, the search box) is on, when they landed on that row. A row that wrapped
-- keeps them where the placer left them.
local function sameRow(c, first)
    return math.abs((c.y + c.height / 2) - (first.y + first.height / 2)) < 2
end

function G.pinRight(first, right, a, b)
    if a ~= nil and sameRow(a, first) then
        a:setX(right - a.width)
        right = a.x - 8
    end
    if b ~= nil and sameRow(b, first) then b:setX(right - b.width) end
end

-- The page's layout placed its table: the grid takes the same rectangle when it is the view in
-- force (the table is hidden behind it, its geometry kept for the empty and error states), the
-- tabs show the stored choice. `shown` is whether that table is on screen at all; a hidden page,
-- or a trade page off its browse mode, keeps the table's visibility as the layout set it.
function G.fit(panel, page, shown)
    local spec = PAGES[page]
    local src, grid, tabs = panel[spec.list], panel[spec.grid], panel[spec.tabs]
    local want = O.gridView(page)
    local id = want and "grid" or "list"
    if tabs:getSelected() ~= id then tabs:setSelected(id, true) end
    local on = shown and want
    grid:setVisible(on)
    if not on then return false end
    src:setVisible(false)
    local tw, th = G.tileSize(spec.kind)
    local n, w = G.columns(src.width, tw)
    grid.cols.tileW, grid.ecWantPerRow = w, n
    grid.ecChromeH = src.ecChromeH
    grid:setX(src.x)
    grid:setY(src.y)
    if grid.rowHeight ~= th or grid.width ~= src.width or grid.height ~= src.height then
        grid.rowHeight = th
        grid:resize(src.width, src.height)
    end
    G.sync(grid)
    return true
end

return G
