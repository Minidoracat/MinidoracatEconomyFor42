-- MinidoracatEconomyFor42 - the filter bar of the client-paged lists (client).
--
-- Moved out of ECPanel.lua unchanged: the two client-paged lists (the market ring and the wallet
-- statement) get the same toolbar: kind chips (multi-select; "all" clears the set), a from/to day
-- pair, a time/amount sort pair (a second click on the active chip flips the direction) and a
-- pager under the list. Every filter is local -- the reply is at most a few hundred rows, so
-- nothing here talks to the server. The owner supplies the kind labeller and the field the amount
-- sort reads.
--
-- The bar owns no widget of its own: every chip and every entry is a child of the owner window
-- (the layout places them in window coordinates), so the bar only remembers them. It registers no
-- event and knows nothing about the pages it filters beyond the `onChange(panel)` the owner gave
-- it. The auction record page is searched by the server instead, so it asks for no keyword box.

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

local PAD, ROW, CHIP_H, T = U.PAD, U.ROW, U.CHIP_H, U.T
local fontH = U.fontH
local text, textWidth, textRight = U.text, U.textWidth, U.textRight
local entryText = U.entryText
local Button = U.Button
local newEntry = W.newEntry
local drawArrow = W.drawArrow
local ARROW_W, ARROW_H = W.ARROW_W, W.ARROW_H

local PER_PAGE = 25

local FilterBar = {}
FilterBar.__index = FilterBar

-- `label(kind)` names a kind chip, `amountField` is the row field the amount sort reads, and
-- `onChange(panel)` rebuilds the owner's rows. `hintKey` asks for a keyword box (the statement and
-- the market ring each own one; the auction record is searched by the server instead) and is the
-- translation key of its placeholder. Chips/entries are children of the window (the layout places
-- them in window coordinates), so the bar only remembers them.
function FilterBar.new(panel, label, amountField, onChange, hintKey)
    local bar = setmetatable({ panel = panel, label = label, amountField = amountField,
        onChange = onChange, kinds = {}, kindCount = 0, kindButtons = {}, labels = {},
        sortKey = "time", desc = true, page = 1, pages = 1, total = 0 }, FilterBar)
    local entryH = math.max(26, fontH.small + 12)
    bar.dateW = math.max(textWidth("0000-00-00"), textWidth(getText(T .. "Filter_DateHint"))) + 24
    for _, which in ipairs({ "from", "to" }) do
        local e = newEntry(bar.dateW, entryH, getText(T .. "Filter_DateHint"))
        e.target = bar
        e.onTextChangeFunction = FilterBar.onDate
        panel:addChild(e)
        bar[which .. "Entry"] = e
        DatePicker.attach(e, panel)
    end
    -- The keyword box of this page. It narrows the rows the page has already loaded and nothing
    -- else: no request goes out, and the note under the table says which rows those are.
    if hintKey ~= nil then
        local e = newEntry(200, entryH, getText(T .. hintKey))
        e.target = bar
        e.onTextChangeFunction = FilterBar.onSearchTyped
        panel:addChild(e)
        bar.searchEntry = e
        bar.searchLabel = getText(T .. "Filter_Search")
    end
    bar.sortButtons = {}
    for _, key in ipairs({ "time", "amount" }) do
        local title = getText(T .. "Filter_Sort_" .. key)
        local b = Button.create(0, 0, textWidth(title) + 22 + ARROW_W + 4, CHIP_H, title, bar, FilterBar.onSort, "chip")
        b.internal = key
        b.active = key == bar.sortKey
        panel:addChild(b)
        bar.sortButtons[#bar.sortButtons + 1] = b
    end
    for _, spec in ipairs({ { "kindPrevButton", "<", -1 }, { "kindNextButton", ">", 1 } }) do
        local b = Button.create(0, 0, math.max(26, fontH.small + 8), CHIP_H, spec[2], bar, FilterBar.onKindPage, "chip")
        b.internal = spec[3]
        b:setVisible(false)
        panel:addChild(b)
        bar[spec[1]] = b
    end
    for _, spec in ipairs({ { "Prev", -1 }, { "Next", 1 } }) do
        local title = getText(T .. "Market_" .. spec[1])
        local b = Button.create(0, 0, textWidth(title) + 22, CHIP_H, title, bar, FilterBar.onPage, "chip")
        b.internal = spec[2]
        panel:addChild(b)
        bar[string.lower(spec[1]) .. "Button"] = b
    end
    return bar
end

function FilterBar:changed()
    self.page = 1
    self.onChange(self.panel)
end

function FilterBar:onDate() self:changed() end

-- Typing and an IME commit reach the box by two different routes (the text-change callback fires
-- for the keyboard, while an IME candidate may only land in the text), so the text is read back
-- from the box: one guard, whichever way the characters arrived, and no work at all while it
-- stands still. The owner polls this every frame for the box that is on screen.
function FilterBar:onSearchTyped() self:pollSearch() end

function FilterBar:pollSearch()
    local e = self.searchEntry
    if e == nil or not e:getIsVisible() then return end
    local raw = string.match(entryText(e), "^%s*(.-)%s*$")
    if raw == self.searchRaw then return end
    self.searchRaw = raw
    self.query = raw ~= "" and string.lower(raw) or nil
    self:changed()          -- a new keyword starts on page 1; kinds, days and sort stay as they are
end

-- The rows this keyword leaves, out of the ones the page has loaded. Runs before EC.filterPage, so
-- the kind chips, the day range and the pager all count exactly the matches. No query, no copy.
function FilterBar:search(rows)
    local query = self.query
    if query == nil then return rows end
    local out = {}
    for i = 1, #rows do
        local e = rows[i]
        if e.searchText ~= nil and string.find(e.searchText, query, 1, true) then out[#out + 1] = e end
    end
    return out
end

function FilterBar:onKind(button)
    local kind = button.internal
    if kind == "" then
        self.kinds, self.kindCount = {}, 0
    elseif self.kinds[kind] then
        self.kinds[kind] = nil
        self.kindCount = self.kindCount - 1
    else
        self.kinds[kind] = true
        self.kindCount = self.kindCount + 1
    end
    for _, b in ipairs(self.kindButtons) do
        b.active = b.internal == "" and self.kindCount == 0 or self.kinds[b.internal] == true
    end
    self:changed()
end

-- Long multi-select sets page horizontally instead of consuming the history viewport.
function FilterBar:onKindPage(button)
    local start = math.max(1, math.min(#self.kindButtons, (self.kindStart or 1) + button.internal))
    if start == self.kindStart then return end
    self.kindStart = start
    self.panel:layout()
    C.Keyboard.invalidate(self.panel)
end

function FilterBar:onToggleFilters()
    DatePicker.close(self.panel)
    self.panel:unfocusEntries()
    C.DetailWindow.close(self.panel)
    self.filtersOpen = not self.filtersOpen
    self.panel:layout()
    C.Keyboard.invalidate(self.panel)
end

function FilterBar:onSort(button)
    if self.sortKey == button.internal then
        self.desc = not self.desc
    else
        self.sortKey = button.internal
        self.desc = true          -- newest / largest first, both ways round
    end
    for _, b in ipairs(self.sortButtons) do b.active = b.internal == self.sortKey end
    self:changed()
end

function FilterBar:onPage(button)
    local page = self.page + button.internal
    if page < 1 or page > self.pages then return end
    self.page = page
    self.onChange(self.panel)
end

-- The chips are the kinds the reply actually carries (plus "all"), the rule the shop/market
-- category chips follow. Rebuilt only when that set changes; the caller re-runs layout.
function FilterBar:syncKinds(rows)
    local seen, order, sig = {}, { "" }, ""
    for _, e in ipairs(rows) do
        local kind = e.kind
        if type(kind) == "string" and kind ~= "" and not seen[kind] then
            seen[kind] = true
            order[#order + 1] = kind
            sig = sig .. kind .. ","
        end
    end
    -- a kind that left the data must not stay selected (its chip is gone). The stale keys are
    -- collected first: Kahlua is not promised to survive a delete mid-traversal.
    local stale = {}
    for kind in pairs(self.kinds) do
        if not seen[kind] then stale[#stale + 1] = kind end
    end
    for _, kind in ipairs(stale) do
        self.kinds[kind] = nil
        self.kindCount = self.kindCount - 1
    end
    if sig == self.kindSig then return false end
    self.kindSig = sig
    for _, b in ipairs(self.kindButtons) do
        b:setVisible(false)
        self.panel:removeChild(b)
    end
    self.kindButtons = {}
    for _, kind in ipairs(order) do
        local title = kind == "" and getText(T .. "Filter_All") or self.label(kind)
        local b = Button.create(0, 0, textWidth(title) + 22, CHIP_H, title, self, FilterBar.onKind, "chip")
        b.ecKindWidth = b.width
        b.internal = kind
        b.active = kind == "" and self.kindCount == 0 or self.kinds[kind] == true
        self.panel:addChild(b)
        self.kindButtons[#self.kindButtons + 1] = b
    end
    self.kindStart = math.min(self.kindStart or 1, math.max(1, #self.kindButtons))
    return true
end

-- EC.filterPage options for the current filter state. A malformed date is "no bound" (the
-- player is still typing); "to" is the end of that day, so the day itself is included.
function FilterBar:opts(timeField)
    local offset = self.panel.offsetMin or 0
    local from = EC.parseDay(entryText(self.fromEntry), offset)
    local to = EC.parseDay(entryText(self.toEntry), offset)
    return {
        kinds = self.kindCount > 0 and self.kinds or nil,
        fromMs = from, toMs = to and (to + 86400000) or nil,
        timeField = timeField or "ts",
        sortKey = self.sortKey == "amount" and self.amountField or (timeField or "ts"),
        desc = self.desc, page = self.page, perPage = PER_PAGE,
    }
end

function FilterBar:setPage(page, pages, total)
    self.page, self.pages, self.total = page, pages, total
end

-- One wrapped row of widgets between x and right; returns the y under the last row. Wrapping
-- (the shop's chip rule) is what keeps the bar inside the card at every font scale.
function FilterBar:layout(x, y, right, visible)
    local labels = {}
    local cx, cy = x, y
    local band = math.max(CHIP_H, self.fromEntry.height)
    local ty = math.floor((band - fontH.small) / 2)
    local function place(w)
        if cx > x and cx + w > right then
            cx = x
            cy = cy + band + 6
        end
        local at = cx
        cx = cx + w + 6
        return at
    end
    local function labelAt(key)
        local str = getText(T .. key)
        local x = place(textWidth(str))     -- place() may open a new row: read cy after it
        labels[#labels + 1] = { text = str, x = x, y = cy + ty }
    end
    local function dateAt(entry, key)
        local label = getText(T .. key)
        local labelW = textWidth(label)
        local button = entry.calendarButton
        local at = place(labelW + 4 + self.dateW + 4 + band)
        labels[#labels + 1] = { text = label, x = at, y = cy + ty }
        entry:setVisible(visible)
        entry:setWidth(self.dateW)
        entry:setX(at + labelW + 4); entry:setY(cy + math.floor((band - entry.height) / 2))
        button:setVisible(visible)
        button:setWidth(band); button:setHeight(band)
        button:setX(entry.x + self.dateW + 4); button:setY(cy)
    end
    -- the keyword box first: it is what a player reaches for, and its label stays visible while
    -- they type (the placeholder is gone the moment the box holds anything)
    local search = self.searchEntry
    if search ~= nil then
        search:setWidth(math.max(140, math.min(280, math.floor((right - x) * 0.32))))
        local labelW = textWidth(self.searchLabel)
        local at = place(labelW + 4 + search.width)
        labels[#labels + 1] = { text = self.searchLabel, x = at, y = cy + ty }
        search:setVisible(visible)
        search:setX(at + labelW + 4); search:setY(cy + math.floor((band - search.height) / 2))
    end
    local kindWidth = textWidth(getText(T .. "Filter_Kind")) + 6
    for _, b in ipairs(self.kindButtons) do kindWidth = kindWidth + b.ecKindWidth + 6 end
    local pagedKinds = kindWidth > right - x
    self.kindPrevButton:setVisible(visible and pagedKinds)
    self.kindNextButton:setVisible(visible and pagedKinds)
    if pagedKinds then
        local minimum = textWidth(getText(T .. "Filter_Kind")) + self.kindPrevButton.width + self.kindNextButton.width
            + textWidth("...") + 28 + (self.kindCount > 0 and (textWidth("(" .. tostring(self.kindCount) .. ")") + 6) or 0)
        if cx > x and right - cx < minimum then cx = x; cy = cy + band + 6 end
        labelAt("Filter_Kind")
        if self.kindCount > 0 then
            local count = "(" .. tostring(self.kindCount) .. ")"
            local at = place(textWidth(count))
            labels[#labels + 1] = { text = count, x = at, y = cy + ty }
        end
        local prev, nextButton = self.kindPrevButton, self.kindNextButton
        prev:setX(cx); prev:setY(cy + math.floor((band - prev.height) / 2))
        cx = cx + prev.width + 6
        nextButton:setX(right - nextButton.width); nextButton:setY(prev.y)
        local limit, last, full = nextButton.x - 6, 0, false
        for index, b in ipairs(self.kindButtons) do
            if index >= (self.kindStart or 1) and last > 0 and cx + b.ecKindWidth > limit then full = true end
            local show = index >= (self.kindStart or 1) and not full
            b:setVisible(visible and show)
            if show then
                b:setWidth(math.max(1, math.min(b.ecKindWidth, limit - cx)))
                U.setButtonTitle(b, b.fullTitle)
                b:setX(cx); b:setY(cy + math.floor((band - b.height) / 2))
                cx, last = cx + b.width + 6, index
            end
        end
        prev:setEnable((self.kindStart or 1) > 1)
        nextButton:setEnable(last < #self.kindButtons)
        cx, cy = x, cy + band + 6
    else
        self.kindStart = 1
        labelAt("Filter_Kind")
        for _, b in ipairs(self.kindButtons) do
            b:setVisible(visible)
            b:setWidth(b.ecKindWidth)
            U.setButtonTitle(b, b.fullTitle)
            b:setX(place(b.width)); b:setY(cy + math.floor((band - b.height) / 2))
        end
    end
    dateAt(self.fromEntry, "Filter_From")
    dateAt(self.toEntry, "Filter_To")
    labelAt("Filter_Sort")
    for _, b in ipairs(self.sortButtons) do
        b:setVisible(visible)
        b:setX(place(b.width)); b:setY(cy + math.floor((band - b.height) / 2))
    end
    self.labels = visible and labels or {}
    return cy + band
end

-- Give records a usable viewport. Oversized filters get the card to themselves on demand.
function FilterBar:layoutViewport(x, y, right, bottom, visible, buttonY)
    local pagerH = math.max(CHIP_H, fontH.small + 8)
    local filterBottom = self:layout(x, y, right, false) + 6
    local compact = bottom - pagerH - 2 - filterBottom < W.historyRowHeight()
    local showingFilters = visible and (not compact or self.filtersOpen == true)
    local showingRecords = visible and (not compact or self.filtersOpen ~= true)
    self:layout(x, y, right, showingFilters)
    if visible and not self.filterButton then
        self.filterButton = Button.create(0, 0, 100, CHIP_H, "", self, FilterBar.onToggleFilters, "chip")
        self.panel:addChild(self.filterButton)
    end
    if self.filterButton then
        local title = getText(T .. (compact and self.filtersOpen and "Admin_Tx_Results" or "Admin_Tx_Filters"))
        self.filterButton:setVisible(visible and compact)
        self.filterButton:setWidth(textWidth(title) + 22)
        self.filterButton:setX(right - self.filterButton.width); self.filterButton:setY(buttonY)
        U.setButtonTitle(self.filterButton, title)
    end
    local listY = compact and y or filterBottom
    self:layoutPager(x, bottom - pagerH, right, showingRecords, pagerH)
    return listY, math.max(0, bottom - pagerH - 2 - listY), showingRecords
end

-- Pager strip under the list: the page counter on the left, the two chips, the row count right.
function FilterBar:layoutPager(x, y, right, visible, rowHeight)
    local cx = x + textWidth(getText(T .. "Filter_Page", "99", "99")) + PAD
    self.pagerVisible = visible
    self.pagerY = y
    self.pagerRight = right
    self.pagerH = rowHeight or ROW
    for _, b in ipairs({ self.prevButton, self.nextButton }) do
        b:setVisible(visible)
        b:setX(cx); b:setY(y + math.floor((self.pagerH - b.height) / 2))
        cx = cx + b.width + 6
    end
end

function FilterBar:draw(el)
    for _, l in ipairs(self.labels) do text(el, l.text, l.x, l.y, "textMuted") end
    for _, b in ipairs(self.sortButtons) do
        if b.active and b:getIsVisible() then
            drawArrow(el, b.x + b.width - ARROW_W - 8, b.y + math.floor((b.height - ARROW_H) / 2), not self.desc)
        end
    end
end

function FilterBar:drawPager(el, x, hideCount)
    if not self.pagerVisible then return end
    local ty = self.pagerY + math.floor(((self.pagerH or ROW) - fontH.small) / 2)
    text(el, getText(T .. "Filter_Page", tostring(self.page), tostring(self.pages)), x, ty, "textMuted")
    if not hideCount then
        textRight(el, getText(T .. "Filter_Count", tostring(self.total)), self.pagerRight, ty, "textMuted")
    end
    self.prevButton:setEnable(self.page > 1)
    self.nextButton:setEnable(self.page < self.pages)
end

C.PanelFilters = FilterBar

return FilterBar
