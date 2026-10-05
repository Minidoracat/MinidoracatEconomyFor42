-- MinidoracatEconomyFor42 -- admin reports page (client). Adds exactly one namespace:
-- C.AdminReports.
--
--   C.AdminReports.create(owner, send, isPending, newRequestId)
--       an initialised ISPanel child, NOT added (the admin controller addChild's it). Like
--       C.AdminTransactions it owns no Events hook and no timer: the controller calls tick(now)
--       while the Reports tab is on screen and reading is allowed, and every command goes out
--       through the controller's own send / isPending / newRequestId (plain functions, never ":").
--
-- One command, admin.report, two questions (ECReports.lua on the server):
--   summary   { currency, days | season | fromMs+toMs }: per reward day totals, the period before
--             it, totals by kind, the money supply, the wealth bins and the shop's sales
--   market    { action = "market", currency, days = 7|30, refresh }: the hot items, prices and
--             active traders from the event-file scan. A scan runs asynchronously; while the
--             answer says "running" the page asks again every MARKET_POLL_MS (on screen only).
-- One request is in flight at a time (the controller's per-command slot), and each answer is
-- matched by its own requestId, so a late market answer never lands as a summary and never frees
-- the slot a newer request holds.
--
-- What the controller lends the page: owner:readAllowed(), owner.message (the footer line),
-- owner.offsetMin (the clock the calendar and "updated at" use), owner.owner (the root window,
-- for C.Keyboard.invalidate) and owner:showTransactions(group, filters) for every jump.
--
-- Layout: a fixed header (period, currency, range and refresh) over one scrolling body. The body
-- clips with a stencil (set in prerender, cleared in render) and places every child itself at
-- contentY - scrollOffset, so the engine's own scroll is never used; the charts (C.Charts) and
-- the three row tables are children that draw inside their own bounds and set no stencil. Every
-- string, width and position is prepared when data or geometry changes; render only paints.

require "ISUI/ISPanel"
require "ISUI/ISScrollBar"
require "MinidoracatEconomy/ECWidgets"
require "MinidoracatEconomy/ECPanelWidgets"
require "MinidoracatEconomy/ECCharts"

local EC = MinidoracatEconomy
local C = EC.Client
local U = C.UI
local W = C.PanelWidgets

local P = {}
C.AdminReports = P

local PAD, T = U.PAD, U.T
local fontH = U.fontH
local fill, border, text, textWidth, fitText, textRight = U.fill, U.border, U.text, U.textWidth, U.fitText, U.textRight
local amountText, signedText = U.amountText, U.signedText
local Button = U.Button

local CMD = "admin.report"
local DAY_MS = 86400000
local RANGE_MAX_DAYS = 60
local DEBOUNCE_MS = 650          -- a typed day costs one command per pause
local MARKET_POLL_MS = 3000      -- a running scan is asked about again this often
local GAP = 8
local GUTTER = 21                -- the body's scrollbar: 17 px wide, 4 px clear of the content
local PERIODS = { "d7", "d30", "season", "custom" }
local SPARK_RGB = { r = 0.9, g = 0.9, b = 0.9 }

local function tr(key) return getText(T .. key) end
local function lineH() return fontH.small + 6 end
local function largeH() return getTextManager():getFontHeight(UIFont.Large) end

-- ----- numbers and days -----

-- "5k" / "2.5k" / "1.2M": axis ticks (decimals from the tick step) and bin labels
local compactText = C.Charts.compact

local function round(x) return math.floor(x + 0.5) end

-- A unit price may carry cents (the server sends medians to 2 decimals): "145", "12.5".
local function priceText(n)
    n = tonumber(n) or 0
    local whole = math.floor(n)
    local cents = round((n - whole) * 100)
    if cents >= 100 then whole, cents = whole + 1, 0 end
    if cents == 0 then return amountText(whole) end
    local s = string.gsub(string.format("%02d", cents), "0$", "")
    return amountText(whole) .. "." .. s
end

-- Change against the period before, in whole percent; nil when there is nothing to compare with.
local function deltaPct(cur, prev)
    prev = tonumber(prev)
    if prev == nil or prev <= 0 then return nil end
    return round(((tonumber(cur) or 0) - prev) / prev * 100)
end

-- The server's rule (ECRewards R.resetShiftMs), read the way this client reads options: the config
-- broadcast first, the sandbox file before any has arrived. A reward day key "YYYYMMDD" starts at
-- that UTC midnight plus this shift.
local function optionValue(key, default)
    local state = C.options and C.options[key]
    if state ~= nil and type(state.value) == type(default) then return state.value end
    return EC.sandbox(key, default)
end

local function resetShiftMs()
    local hour = optionValue("RewardDayResetHour", 0)
    if hour < 0 or hour > 23 then hour = 0 end
    local tz = optionValue("RewardTimezoneUTC", 8)
    if tz < -12 or tz > 14 then tz = 8 end
    return (hour * 60 - math.floor(tz * 60 + 0.5)) * 60000
end

-- "20261003" -> "2026-10-03" (the framework's date text), "10-03" (labels)
local function keyDate(key)
    key = tostring(key or "")
    return string.sub(key, 1, 4) .. "-" .. string.sub(key, 5, 6) .. "-" .. string.sub(key, 7, 8)
end
local function keyShort(key)
    key = tostring(key or "")
    return string.sub(key, 5, 6) .. "-" .. string.sub(key, 7, 8)
end

local function Date() return U.framework.Date end

-- [start, start + DAY) of one reward day, in ms; nil for a malformed key
local function dayStartMs(key)
    local base = Date().dayStart(keyDate(key), 0)
    if base == nil then return nil end
    return base + resetShiftMs()
end

local WEEK_KEYS = { "WeekSun", "WeekMon", "WeekTue", "WeekWed", "WeekThu", "WeekFri", "WeekSat" }
local function weekdayText(key)
    local base = Date().dayStart(keyDate(key), 0)
    if base == nil then return "" end
    local n = math.floor(base / DAY_MS) + 4
    return getText("IGUI_MinidoracatUI_Date_" .. WEEK_KEYS[n - math.floor(n / 7) * 7 + 1])
end

-- The money page's own source groups (ECAdmin txGroup): a source row jumps to its group.
local function txGroup(kind)
    if kind == "shop_buy" or kind == "shop_sell" then return kind end
    if kind == "checkin" or kind == "milestone" then return "rewards" end
    if kind == "mod" or kind == "transfer" then return kind end
    local prefix = type(kind) == "string" and string.match(kind, "^(%a+)_") or nil
    if prefix == "market" or prefix == "auction" or prefix == "admin" or prefix == "exchange" then return prefix end
    return "other"
end

-- One source row's name: the kind and its direction ("mod" pays out and charges), else the kind.
local function sourceText(kind, dir)
    return getTextOrNull(T .. "Report_Src_" .. tostring(kind) .. "_" .. tostring(dir)) or U.kindText(kind)
end

-- The flow chart's stacks: which band a kind's inflow / outflow feeds (1..4, 4 = everything else).
local UP_BAND = { checkin = 1, milestone = 2, shop_sell = 3 }
local DOWN_BAND = { shop_buy = 1, market_fee = 2, auction_fee = 2, market_buy = 3, auction_sale = 3 }

-- The chart palette, in either shape C.Charts hands it ({r,g,b} fields or [1..3]).
local function rgbOf(c)
    if type(c) ~= "table" then return SPARK_RGB end
    if c.r ~= nil then return c end
    return { r = c[1] or 1, g = c[2] or 1, b = c[3] or 1 }
end

local function palette(name, i)
    local p = C.Charts and C.Charts[name]
    if type(p) ~= "table" then return SPARK_RGB end
    if type(p[1]) == "table" then return rgbOf(p[i] or p[1]) end
    return rgbOf(p)
end

local function drawSwatch(el, x, y, w, h, rgb)
    el:drawRect(x, y, w, h, 1, rgb.r, rgb.g, rgb.b)
end

-- ----- row tables (keyboard: kind = "button", up / down move the cursor, Enter opens) -----

local Rows = ISPanel:derive("MinidoracatEconomyAdminReportsRows")

function Rows.new(page, drawRow, onActivate)
    local o = ISPanel:new(0, 0, 10, 10)
    setmetatable(o, Rows)
    o.background = false
    o.page, o.drawRow, o.onActivate = page, drawRow, onActivate
    o.rows = {}
    o.rowH = 30
    o:initialise()
    return o
end

function Rows:prerender() end

function Rows:render()
    local rows, rh, w = self.rows, self.rowH, self.width
    local body = self.parent
    local first = math.max(1, math.floor(-self.y / rh) + 1)
    local last = math.min(#rows, math.floor(((body and body.height or self.height) - self.y) / rh) + 1)
    for i = first, last do
        local y = (i - 1) * rh
        local r = rows[i]
        if i == self.cursor then fill(self, 0, y, w, rh, "selected")
        elseif r.zebra then fill(self, 0, y, w, rh, "card") end
        self.drawRow(self, r, y, i)
    end
end

function Rows:selectable(i)
    local r = self.rows[i]
    return r ~= nil and r.section == nil
end

function Rows:firstSelectable(from, step)
    local i = from
    while i >= 1 and i <= #self.rows do
        if self:selectable(i) then return i end
        i = i + step
    end
    return nil
end

function Rows:cursorRect()
    local i = self.cursor or self:firstSelectable(1, 1) or 1
    return (i - 1) * self.rowH, self.rowH
end

-- rev 12: the ring marks the cursor row, not the whole table
function Rows:focusRect()
    local y, h = self:cursorRect()
    return 0, y, self.width, h
end

function Rows:moveCursor(i)
    self.cursor = i
    local body = self.parent
    if body and body.scrollToRect then
        local y, h = self:cursorRect()
        body:scrollToRect(self.contentY + y - 4, h + 8)
    end
end

function Rows:activate(i)
    if not self:selectable(i) or self.onActivate == nil then return false end
    self.cursor = i
    self.onActivate(self.page, self.rows[i])
    return true
end

function Rows:forceClick()
    local i = self.cursor or self:firstSelectable(1, 1)
    if i then self:activate(i) end
end

function Rows:onFocusKey(key)
    if self.onActivate == nil or #self.rows == 0 then return false end
    if key == Keyboard.KEY_RETURN or key == Keyboard.KEY_NUMPADENTER then
        self:forceClick()
        return true
    end
    local step = (key == Keyboard.KEY_UP and -1) or (key == Keyboard.KEY_DOWN and 1) or nil
    if step == nil then return false end
    local i
    if self.cursor == nil then i = self:firstSelectable(1, 1)
    else i = self:firstSelectable(self.cursor + step, step) end
    if i == nil then return false end   -- at the edge: a controller moves on to the next target
    self:moveCursor(i)
    return true
end

function Rows:onMouseDown(x, y)
    local i = math.floor(y / self.rowH) + 1
    if self:selectable(i) and self.onActivate ~= nil then self:activate(i) end
    return true
end

-- ----- the scrolling body -----

local Body = ISPanel:derive("MinidoracatEconomyAdminReportsBody")

function Body:maxScrollOffset() return math.max(0, (self.contentH or 0) - self.height) end
function Body:getScrollHeight() return self.contentH or 0 end
function Body:getScrollAreaHeight() return self.height end
function Body:getYScroll() return -(self.scrollOffset or 0) end
function Body:setYScroll(value) self:setScrollOffset(-value) end

function Body:setScrollOffset(offset)
    local clamped = math.max(0, math.min(offset, self:maxScrollOffset()))
    if clamped == self.scrollOffset then return end
    self.scrollOffset = clamped
    self.page:placeBody()
end

function Body:scrollToRect(cy, h)
    local off = self.scrollOffset or 0
    if cy < off then off = cy
    elseif cy + h > off + self.height then off = math.min(cy, cy + h - self.height) end
    self:setScrollOffset(off)
end

-- Focus `scrollOwner`: bring a control (or a table's cursor row) on screen before it is focused
function Body:scrollTo(control)
    local cy = control.contentY or ((control.y or 0) + (self.scrollOffset or 0))
    local h = control.height or 0
    if control.cursorRect then
        local ry, rh = control:cursorRect()
        cy, h = cy + ry, rh
    end
    self:scrollToRect(cy - 4, h + 8)
end

function Body:onMouseWheel(del)
    if self:maxScrollOffset() <= 0 then return false end
    self:setScrollOffset((self.scrollOffset or 0) + del * lineH() * 3)
    return true
end

function Body:prerender()
    self:setStencilRect(0, 0, self.width, self.height)
    if self.bar:getIsVisible() then self.bar:updatePos() end
    self.page:drawBody(self)
end

function Body:render()
    self:clearStencilRect()
end

-- ----- the page -----

local Page = ISPanel:derive("MinidoracatEconomyAdminReportsPage")

local function addTo(parent, child)
    parent:addChild(child)
    return child
end

function Page:createChildren()
    local fw = U.framework
    local periodItems = {}
    for i, id in ipairs(PERIODS) do periodItems[i] = { id = id, label = tr("Report_Period_" .. id) } end
    self.periodTabs = W.modeTabs(self, periodItems, self.period, Page.onPeriod)
    local curItems = {}
    for i, id in ipairs(EC.CURRENCY_ORDER) do curItems[i] = { id = id, label = U.currencyName(id) } end
    self.curTabs = W.modeTabs(self, curItems, self.currency, Page.onCurrency)
    local dh = self.periodTabs.height
    self.fromField = addTo(self, fw.DateField.new({ theme = U.theme, height = dh, target = self,
        onChange = Page.onCustomDate }))
    self.toField = addTo(self, fw.DateField.new({ theme = U.theme, height = dh, target = self,
        onChange = Page.onCustomDate }))
    self.refreshButton = W.iconChip(self, "reload", tr("Report_Refresh"), Page.onRefresh)

    local body = ISPanel:new(0, 0, 100, 100)
    setmetatable(body, Body)
    body.background = false
    body.page = self
    body.scrollOffset = 0
    body.contentH = 0
    body:initialise()
    self.body = addTo(self, body)

    local Ch = C.Charts
    self.flowChart = addTo(body, Ch.FlowChart.create(0, 0, 100, 100))
    self.flowChart.onPick = function(_, index) self:onFlowPick(index) end
    self.supplyChart = addTo(body, Ch.LineChart.create(0, 0, 100, 100))
    self.wealthChart = addTo(body, Ch.Histogram.create(0, 0, 100, 100))
    local function chip(label, handler)
        return addTo(body, Button.create(0, 0, textWidth(label) + 20, U.CHIP_H, label, self, handler, "chip"))
    end
    self.onlyInButton = chip(tr("Report_OnlyIn"), Page.onOnlyIn)
    self.onlyOutButton = chip(tr("Report_OnlyOut"), Page.onOnlyOut)
    self.regenButton = chip(tr("Report_Regenerate"), Page.onRegenerate)
    self.sourceRows = addTo(body, Rows.new(self, P.drawSourceRow, Page.onSourcePick))
    self.itemRows = addTo(body, Rows.new(self, P.drawItemRow, Page.onItemPick))
    self.shopRows = addTo(body, Rows.new(self, P.drawShopRow, nil))
    self.bodyChildren = { self.flowChart, self.supplyChart, self.wealthChart, self.onlyInButton,
        self.onlyOutButton, self.regenButton, self.sourceRows, self.itemRows, self.shopRows }

    local bar = ISScrollBar:new(body, true)
    bar:initialise()
    body:addChild(bar)
    bar:setAnchorLeft(true); bar:setAnchorRight(false); bar:setAnchorBottom(false)
    bar:setVisible(false)
    body.bar = bar
    self:rebuildStatus()
    self:rebuildMarketStatus()
    self:layout()
end

-- ----- controls -----

function Page:onPeriod(id)
    if id == self.period then return end
    self.period = id
    if id == "custom" then
        -- start from the range on screen, so "custom" is an edit of it and not a blank form
        local keys = self.keys
        if self.fromField:getText() == "" and keys and #keys > 0 then
            self.fromField:setText(keyDate(keys[1]))
            self.toField:setText(keyDate(keys[#keys]))
        end
    else
        self.fromField:blur(); self.toField:blur()
    end
    self.rangeError = nil
    self.summaryWant = true
    self.customAt = nil
    local days = self:marketDays()
    if days ~= self.marketAskedDays then self.marketWant = true end
    self:layout()
    if C.Keyboard and C.Keyboard.invalidate then pcall(C.Keyboard.invalidate, self.owner.owner) end
end

function Page:onCurrency(id)
    if id == self.currency then return end
    self.currency = id
    self.summaryWant = true
    self.marketWant = true
    self:layout()
end

function Page:onCustomDate()
    self.customAt = EC.now()
    self.summaryWant = true
end

function Page:onRefresh()
    self.owner.message = nil
    self.summaryWant = true
    self.marketWant = true
    self:updateEnabled()
end

function Page:onRegenerate()
    self.marketWant = true
    self.marketRefresh = true
    self:updateEnabled()
end

function Page:setFlowMode(mode)
    self.flowMode = self.flowMode == mode and "all" or mode
    self:applyFlowData()
    self:updateEnabled()
end
function Page:onOnlyIn() self:setFlowMode("in") end
function Page:onOnlyOut() self:setFlowMode("out") end

function Page:onFlowPick(index)
    local key = self.keys and self.keys[index]
    local from = key and dayStartMs(key)
    if from == nil then return end
    self.owner:showTransactions("all", { fromMs = from, toMs = from + DAY_MS })
end

function Page:onSourcePick(row)
    self.owner:showTransactions(txGroup(row.kind), { query = row.kind, fromMs = self.rangeFrom, toMs = self.rangeTo })
end

function Page:onItemPick(row)
    self.owner:showTransactions("all", { item = row.item })
end

-- ----- transport -----

function Page:marketDays()
    return self.period == "d7" and 7 or 30
end

-- The custom range as reward-day bounds [from, to), or nil with the reason recorded.
function Page:customRange()
    local shift = resetShiftMs()
    local from = Date().dayStart(self.fromField:getText(), 0)
    local to = Date().dayStart(self.toField:getText(), 0)
    if from == nil or to == nil or to < from or (to - from) / DAY_MS + 1 > RANGE_MAX_DAYS then
        self.rangeError = true
        return nil
    end
    self.rangeError = nil
    return from + shift, to + shift + DAY_MS
end

function Page:summaryArgs()
    local args = { requestId = self.newRequestId(), currency = self.currency }
    local p = self.period
    if p == "d7" then args.days = 7
    elseif p == "d30" then args.days = 30
    elseif p == "season" then args.season = true
    else
        local from, to = self:customRange()
        if from == nil then return nil end
        args.fromMs, args.toMs = from, to
    end
    return args
end

function Page:sendSummary()
    local args = self:summaryArgs()
    if args == nil then
        self.summaryWant = false
        self:rebuildStatus()
        self:layout()
        return
    end
    if not self.send(CMD, args) then return end   -- busy: the next tick asks again
    self.summaryWant = false
    self.inflightId, self.inflight = args.requestId, "summary"
    self.summaryReqId = args.requestId
    self.reqToday = args.toMs == nil or args.toMs > EC.now()
    self.summaryError, self.summaryTimeout = nil, false
    self:rebuildStatus()
    self:layout()
end

function Page:sendMarket()
    local days = self:marketDays()
    local args = { requestId = self.newRequestId(), action = "market", currency = self.currency, days = days,
        refresh = self.marketRefresh == true }
    if not self.send(CMD, args) then return end
    self.marketWant, self.marketRefresh, self.marketPollAt = false, false, nil
    self.inflightId, self.inflight = args.requestId, "market"
    self.marketReqId = args.requestId
    self.marketAskedDays = days
    self.marketError, self.marketTimeout = nil, false
    self:rebuildMarketStatus()
    self:layout()
end

-- The clock the controller drives while this page is on screen: one request at a time, the
-- summary first, a typed day only after a pause, and a running scan asked about every few seconds.
function Page:tick(now)
    if not self:getIsVisible() or not self.owner:readAllowed() then return end
    if self.inflightId ~= nil or self.isPending(CMD) then return end
    if self.summaryWant then
        if self.period == "custom" and self.customAt and now - self.customAt < DEBOUNCE_MS then return end
        self:sendSummary()
    elseif self.marketWant or (self.marketState == "running" and self.marketPollAt and now >= self.marketPollAt) then
        self:sendMarket()
    end
end

function Page:refresh()
    self.summaryWant = true
    self.marketWant = true
end

-- Asked by the controller before the shared slot is freed, without touching a field: only the
-- request in flight may free it.
function Page:matchesReply(kind, args)
    if kind ~= "report" then return true end
    if args.requestId == nil or self.inflightId == nil then return true end
    return args.requestId == self.inflightId
end

-- Routed by requestId (a refusal such as "forbidden" carries no action); a reply to a question the
-- admin has already changed (another currency, a newer question queued) frees the slot and is
-- dropped, so it never paints over the question being asked now.
function Page:onReply(kind, args)
    if kind ~= "report" or type(args) ~= "table" then return end
    local id = args.requestId
    if id ~= nil and id == self.inflightId then self.inflightId, self.inflight = nil, nil end
    local isMarket
    if id ~= nil then
        if id == self.marketReqId then isMarket = true
        elseif id == self.summaryReqId then isMarket = false
        else self:layout(); return end
    else
        isMarket = args.action == "market"
    end
    local failed = args.ok == false or args.error ~= nil
    local stale = args.currency ~= nil and args.currency ~= self.currency
    if isMarket then
        if failed then
            self.marketError = args.error or "unknown"
            self.marketTimeout = false
        elseif not stale and not self.marketWant then
            self.market = args
            self.marketError, self.marketTimeout = nil, false
            self.marketState = args.state
            self.marketPollAt = args.state == "running" and (EC.now() + MARKET_POLL_MS) or nil
        end
        self:rebuildMarket()
    else
        if failed then
            self.summaryError = args.error or "unknown"
            self.summaryTimeout = false
            self.owner.message = { text = U.adminErrorText(self.summaryError), error = true }
        elseif not stale and not self.summaryWant then
            self.summary = args
            self.summaryError, self.summaryTimeout = nil, false
            self.updatedAt = EC.now()
            self.owner.message = nil
            self:rebuildSummary()
        end
        self:rebuildStatus()
    end
    self:layout()
end

function Page:onTimeout(command)
    if command ~= CMD then return end
    if self.inflight == "market" then
        self.marketTimeout = true
        self:rebuildMarketStatus()
    else
        self.summaryTimeout = true
        self:rebuildStatus()
    end
    self.inflightId, self.inflight = nil, nil
    self:layout()
end

-- ----- data: summary (on a reply only) -----

-- One day's bands. A day the server kept by kind (k) is split exactly; an older day only has the
-- reward rollup, so its inflow is check-in / milestone / buyback / the rest of the mint, and its
-- outflow is the whole burn, unsplit.
local function dayBands(d, up, down, i)
    for b = 1, 4 do up[b][i] = 0; down[b][i] = 0 end
    local k = d.k
    local inT, outT, trade = 0, 0, false
    if type(k) == "table" then
        trade = 0
        for kind, v in pairs(k) do
            if type(v) == "table" then
                local vi, vo = tonumber(v.i) or 0, tonumber(v.o) or 0
                local ub, db = UP_BAND[kind] or 4, DOWN_BAND[kind] or 4
                up[ub][i] = up[ub][i] + vi
                down[db][i] = down[db][i] + vo
                inT, outT = inT + vi, outT + vo
                trade = trade + (tonumber(v.t) or 0)
            end
        end
    else
        local c, m, b = tonumber(d.checkin) or 0, tonumber(d.milestone) or 0, tonumber(d.buyback) or 0
        local mint, burn = tonumber(d.mint) or 0, tonumber(d.burn) or 0
        up[1][i], up[2][i], up[3][i] = c, m, b
        up[4][i] = math.max(0, mint - c - m - b)
        down[4][i] = burn
        inT, outT = math.max(mint, c + m + b), burn
    end
    return inT, outT, trade
end

function Page:rebuildSummary()
    local s = self.summary
    local keys = type(s.keys) == "table" and s.keys or {}
    local days = type(s.days) == "table" and s.days or {}
    local n = #keys
    self.keys = keys
    local up, down = { {}, {}, {}, {} }, { {}, {}, {}, {} }
    local labels, net, hatch = {}, {}, {}
    local inS, outS, tradeS, supS = {}, {}, {}, {}
    local inT, outT, tradeT, est = 0, 0, 0, 0
    local caps = {}
    local today = self.reqToday == true
    local stamp = self.updatedAt and U.clockText(self.updatedAt, self.owner.offsetMin) or "?"
    for i = 1, n do
        local d = type(days[i]) == "table" and days[i] or {}
        local di, do_, dt = dayBands(d, up, down, i)
        local noK = type(d.k) ~= "table"
        if noK then est = est + 1 end
        inS[i], outS[i], tradeS[i], net[i] = di, do_, dt, di - do_
        inT, outT = inT + di, outT + do_
        if dt then tradeT = tradeT + dt end
        local sup = type(d.sup) == "table" and tonumber(d.sup.t) or nil
        supS[i] = sup or false
        local isToday = today and i == n
        labels[i] = isToday and tr("Report_Today") or keyShort(keys[i])
        if isToday or d.unknown == true then hatch[i] = true end
        local lines = {
            { text = getText(T .. "Report_CapIn", signedText(di)), token = "positive" },
            { text = getText(T .. "Report_CapOut", signedText(-do_)), token = "negative" },
            { text = getText(T .. "Report_CapNet", signedText(di - do_)), token = "text" },
        }
        if isToday then lines[#lines + 1] = { text = getText(T .. "Report_CapToday", stamp), token = "textFaint" } end
        if d.unknown == true then lines[#lines + 1] = { text = tr("Report_Incomplete"), token = "warn" } end
        if noK then lines[#lines + 1] = { text = tr("Report_CapEst"), token = "textFaint" } end
        lines[#lines + 1] = { text = tr("Report_CapEnter"), token = "textMuted" }
        caps[i] = { title = getText(T .. "Report_CapTitle", keyShort(keys[i]), weekdayText(keys[i])), lines = lines }
    end
    self.flowSeries = { labels = labels, up = up, down = down, net = net, hatch = hatch, captions = caps, est = est }
    self.rangeFrom = n > 0 and dayStartMs(keys[1]) or nil
    self.rangeTo = n > 0 and dayStartMs(keys[n]) and (dayStartMs(keys[n]) + DAY_MS) or nil
    self.rangeText = n > 0 and getText(T .. "Report_Range", keyShort(keys[1]), keyShort(keys[n])) or nil
    self:rebuildKpis(n, inT, outT, tradeT, est, inS, outS, net, tradeS)
    self:rebuildFlowText(n, est)
    self.supplyData = { labels = labels, values = supS, format = compactText }
    self:rebuildSupplyPill(supS)
    self:rebuildWealth()
    self:rebuildSources(n)
    self:rebuildShop(n)
    self:applyFlowData()
    self.supplyChart:setData(self.supplyData)
end

function Page:rebuildKpis(n, inT, outT, tradeT, est, inS, outS, netS, tradeS)
    local s = self.summary
    local prev = type(s.prev) == "table" and s.prev or nil
    local nowT = type(s.now) == "table" and tonumber(s.now.total) or nil
    local Ch = C.Charts
    local vs = getText(T .. "Report_VsPrev", tostring(n))
    local estNote = est > 0 and getText(T .. "Report_KpiEst", tostring(est)) or nil
    local pIn = prev and (prev.known and prev.i or prev.mint) or nil
    local pOut = prev and (prev.known and prev.o or prev.burn) or nil
    local pTrade = prev and prev.known and prev.t or nil
    local netT = inT - outT
    local kindsFrom = s.kindsFrom
    local tradeNote = nil
    if est > 0 then
        tradeNote = kindsFrom and getText(T .. "Report_KpiFrom", keyShort(kindsFrom)) or tr("Report_KpiNoKinds")
    end
    self.kpis = {
        { label = tr("Report_Kpi_In"), value = signedText(inT), token = "positive", vs = vs,
            pct = deltaPct(inT, pIn), note = estNote, spark = Ch.spark(inS), rgb = palette("IN", 1) },
        { label = tr("Report_Kpi_Out"), value = signedText(-outT), token = "negative", vs = vs,
            pct = deltaPct(outT, pOut), note = estNote, spark = Ch.spark(outS), rgb = palette("OUT", 1) },
        { label = tr("Report_Kpi_Net"), value = signedText(netT), token = "accent",
            sub = (nowT and nowT > 0) and getText(T .. "Report_KpiShare", string.format("%.1f", netT / nowT * 100)) or nil,
            note = estNote, spark = Ch.spark(netS), rgb = palette("NET", 1) },
        { label = tr("Report_Kpi_Trade"), value = (kindsFrom or est == 0) and amountText(tradeT) or "-", token = "text",
            vs = vs, pct = deltaPct(tradeT, pTrade), note = tradeNote, spark = Ch.spark(tradeS), rgb = SPARK_RGB },
        { label = tr("Report_Kpi_Traders"), value = "-", token = "text", rgb = SPARK_RGB },
    }
    self:rebuildTradersKpi()
end

-- The traders card is the market scan's: "-" with a hint until a scan has produced it.
function Page:rebuildTradersKpi()
    local k = self.kpis and self.kpis[5]
    if k == nil then return end
    local m = self.market
    local tdata = m and m.state == "ready" and type(m.traders) == "table" and m.traders or nil
    if tdata == nil then
        k.value, k.sub, k.spark, k.note = "-", nil, nil, tr("Report_KpiTradersHint")
        return
    end
    local daily = type(tdata.daily) == "table" and tdata.daily or {}
    local sum = 0
    for i = 1, #daily do sum = sum + (tonumber(daily[i]) or 0) end
    k.value = amountText(tonumber(tdata.total) or 0)
    k.sub = getText(T .. "Report_KpiTradersAvg", tostring(#daily > 0 and round(sum / #daily) or 0))
    k.spark = C.Charts.spark(daily)
    k.note = getText(T .. "Report_KpiTradersDays", tostring(m.days or self.marketAskedDays or 30))
end

function Page:rebuildFlowText(n, est)
    local legend = {}
    local inLabels = { "Report_Flow_In1", "Report_Flow_In2", "Report_Flow_In3",
        est > 0 and "Report_Flow_In4Est" or "Report_Flow_In4" }
    local outLabels = { "Report_Flow_Out1", "Report_Flow_Out2", "Report_Flow_Out3",
        est > 0 and "Report_Flow_Out4Est" or "Report_Flow_Out4" }
    local series = self.flowSeries
    series.upDefs, series.downDefs = {}, {}
    for i = 1, 4 do
        series.upDefs[i] = { label = tr(inLabels[i]), color = i, values = series.up[i] }
        series.downDefs[i] = { label = tr(outLabels[i]), color = i, values = series.down[i] }
        legend[#legend + 1] = { label = series.upDefs[i].label, rgb = palette("IN", i) }
    end
    for i = 1, 4 do legend[#legend + 1] = { label = series.downDefs[i].label, rgb = palette("OUT", i) } end
    legend[#legend + 1] = { label = tr("Report_Flow_Net"), rgb = palette("NET", 1), line = true }
    for _, e in ipairs(legend) do e.w = 14 + 5 + textWidth(e.label) end
    self.legend = legend
    local foot = {}
    if self.reqToday then
        foot[#foot + 1] = getText(T .. "Report_FlowFootToday",
            self.updatedAt and U.clockText(self.updatedAt, self.owner.offsetMin) or "?")
    end
    foot[#foot + 1] = tr("Report_FlowFootKeys")
    local kindsFrom = self.summary.kindsFrom
    if est > 0 then
        foot[#foot + 1] = kindsFrom and getText(T .. "Report_FlowFootKinds", keyShort(kindsFrom)) or tr("Report_KpiNoKinds")
    end
    self.flowFoot = table.concat(foot, " ")
end

function Page:applyFlowData()
    local s = self.flowSeries
    if s == nil then return end
    local mode = self.flowMode
    local captions = s.captions
    self.flowChart:setData({
        labels = s.labels,
        up = mode ~= "out" and s.upDefs or {},
        down = mode ~= "in" and s.downDefs or {},
        net = mode == "all" and s.net or nil,
        hatch = s.hatch,
        caption = function(i) return captions[i] end,
        format = compactText,
    })
    self.onlyInButton.active = mode == "in"
    self.onlyOutButton.active = mode == "out"
end

function Page:rebuildSupplyPill(supS)
    local first = nil
    for i = 1, #supS do
        if supS[i] then first = supS[i]; break end
    end
    local s = self.summary
    local nowT = type(s.now) == "table" and tonumber(s.now.total) or nil
    self.supplyPill = (first and nowT) and {
        label = getText(T .. "Report_DaysLabel", tostring(#supS)), value = signedText(nowT - first) } or nil
end

function Page:rebuildWealth()
    local w = type(self.summary.wealth) == "table" and self.summary.wealth or {}
    local bins = type(w.bins) == "table" and w.bins or {}
    local labels, values = {}, {}
    for i, b in ipairs(bins) do
        local lo, hi = tonumber(b.lo) or 0, tonumber(b.hi)
        if hi == nil then labels[i] = compactText(lo) .. "+"
        elseif hi == lo then labels[i] = compactText(lo)
        else labels[i] = compactText(lo) .. "-" .. compactText(hi) end
        values[i] = tonumber(b.n) or 0
    end
    local top = type(w.top) == "table" and w.top or nil
    local topN = top and tonumber(top.n) or nil
    -- the white bars: the richest bins whose accounts are all inside the top N
    local from, count = nil, 0
    if topN and topN > 0 then
        local acc = 0
        for i = #values, 1, -1 do
            if acc + values[i] > topN then break end
            acc = acc + values[i]
            if values[i] > 0 or from ~= nil then from, count = i, acc end
        end
    end
    self.wealthChart:setData({ labels = labels, values = values, highlightFrom = from, axis = tr("Report_WealthAxis") })
    local share = top and tonumber(top.share) or nil
    self.wealthPill = (topN and share) and { label = getText(T .. "Report_TopN", tostring(topN)),
        value = getText(T .. "Report_TopShare", string.format("%.0f", share * 100)) } or nil
    local foot = getText(T .. "Report_WealthFoot", amountText(tonumber(w.accounts) or 0), amountText(tonumber(w.median) or 0))
    if from ~= nil then
        foot = foot .. " " .. getText(T .. "Report_WealthHi", amountText(tonumber(bins[from].lo) or 0), tostring(count))
    end
    self.wealthFoot = foot
end

function Page:rebuildSources(n)
    local list = type(self.summary.sources) == "table" and self.summary.sources or {}
    local rows = {}
    local sums = { ["in"] = 0, out = 0 }
    for _, s in ipairs(list) do
        if type(s) == "table" and sums[s.dir] ~= nil then sums[s.dir] = sums[s.dir] + (tonumber(s.amount) or 0) end
    end
    for _, dir in ipairs({ "in", "out" }) do
        local inbound = dir == "in"
        rows[#rows + 1] = { section = dir, label = tr(inbound and "Report_SecIn" or "Report_SecOut"),
            amt = inbound and signedText(sums[dir]) or signedText(-sums[dir]),
            token = inbound and "positive" or "negative" }
        local z = false
        for _, s in ipairs(list) do
            if type(s) == "table" and s.dir == dir then
                local amount = tonumber(s.amount) or 0
                local prev = tonumber(s.prev)
                local frac = sums[dir] > 0 and amount / sums[dir] or 0
                z = not z
                rows[#rows + 1] = { zebra = not z, kind = s.kind, label = sourceText(s.kind, dir),
                    cnt = amountText(tonumber(s.n) or 0), amt = inbound and signedText(amount) or signedText(-amount),
                    token = inbound and "positive" or "negative", frac = frac,
                    share = string.format("%.0f", frac * 100) .. "%",
                    rgb = palette(inbound and "IN" or "OUT", 1),
                    pct = deltaPct(amount, prev), isNew = prev ~= nil and prev <= 0 and amount > 0 }
            end
        end
    end
    self.sourceRows.rows = rows
    self.sourceRows.cursor = nil
    self.sourcesSub = getText(T .. "Report_SourcesSub", tostring(n))
    self.sourcesFoot = getText(T .. "Report_SourcesFoot", tostring(n))
end

-- ponytail: "rarely bought" = under one unit per ten days of the period; tune if admins disagree
function Page:rebuildShop(n)
    local shop = type(self.summary.shop) == "table" and self.summary.shop or {}
    local list = type(shop.rows) == "table" and shop.rows or {}
    local rows = {}
    for i, r in ipairs(list) do
        if type(r) == "table" then
            local capDays = tonumber(r.capDays) or 0
            local units = tonumber(r.units) or 0
            local cap = tonumber(r.cap)
            local scope = getTextOrNull(T .. "Admin_Audit_Value_" .. tostring(r.scope))
            local tag = nil
            if n > 0 and capDays * 2 >= n and capDays > 0 then tag = "soldout"
            elseif units < math.max(1, n / 10) then tag = "rare" end
            rows[#rows + 1] = { zebra = i % 2 == 0, item = r.item, name = U.itemName(r.item),
                sub = (scope and cap and cap > 0) and getText(T .. "Report_ShopCap", scope, amountText(cap)) or tr("Report_ShopNoCap"),
                units = amountText(units), amt = amountText(tonumber(r.amount) or 0),
                capDays = getText(T .. "Report_CapDays", tostring(capDays), tostring(n)),
                capToken = tag == "soldout" and "warn" or "textMuted", tag = tag,
                tagText = tag and tr(tag == "soldout" and "Report_TagSoldOut" or "Report_TagRare") or nil }
        end
    end
    self.shopRows.rows = rows
    local bb = type(shop.buyback) == "table" and tonumber(shop.buyback.pct) or nil
    self.shopPill = bb and { label = tr("Report_BuybackLabel"),
        value = getText(T .. "Report_BuybackUsed", string.format("%.0f", bb * 100)) } or nil
    self.shopSub = getText(T .. "Report_DaysLabel", tostring(n))
end

-- ----- data: market (on a reply only) -----

function Page:rebuildMarket()
    local m = self.market
    local rows = {}
    if m and m.state == "ready" and type(m.items) == "table" then
        for i, it in ipairs(m.items) do
            if type(it) == "table" then
                local n, auction = tonumber(it.n) or 0, tonumber(it.auction) or 0
                local units = amountText(tonumber(it.units) or 0)
                local sub = auction > 0
                    and getText(T .. "Report_ItemSub", tostring(n - auction), tostring(auction), units)
                    or getText(T .. "Report_ItemSubMarket", tostring(n), units)
                local spark = {}
                local src = type(it.spark) == "table" and it.spark or {}
                for d = 1, 14 do spark[d] = tonumber(src[d]) or false end
                rows[#rows + 1] = { zebra = i % 2 == 0, item = it.item, name = U.itemName(it.item), sub = sub,
                    n = amountText(n), amt = amountText(tonumber(it.amount) or 0),
                    median = priceText(it.median),
                    range = priceText(it.lo) .. "~" .. priceText(it.hi),
                    spark = C.Charts.spark(spark) }
            end
        end
    end
    self.itemRows.rows = rows
    self.itemRows.cursor = nil
    self.itemsSub = getText(T .. "Report_ItemsSub", tostring((m and m.days) or self:marketDays()))
    self:rebuildTradersKpi()
    self:rebuildMarketStatus()
end

function Page:rebuildMarketStatus()
    local m = self.market
    local s, token
    if self.marketTimeout then s, token = tr("Report_Timeout"), "errorText"
    elseif self.marketError then s, token = U.adminErrorText(self.marketError), "errorText"
    elseif self.inflight == "market" and m == nil then s, token = tr("Admin_Loading"), "textMuted"
    elseif m == nil then s, token = tr("Report_NotGenerated"), "textMuted"
    elseif m.state == "running" then s, token = tr("Report_Generating"), "warn"
    elseif m.state == "ready" then
        s, token = getText(T .. "Report_GeneratedAt", U.clockText(tonumber(m.generatedAt) or 0, self.owner.offsetMin)), "textMuted"
    elseif m.state == "failed" then s, token = tr("Report_GenFailed"), "errorText"
    else s, token = tr("Report_NotGenerated"), "textMuted" end
    self.marketStatus, self.marketStatusToken = s, token
    local rows = self.itemRows.rows
    if #rows == 0 then
        self.itemsEmpty = (m and m.state == "ready") and tr("Report_ItemsEmpty") or tr("Report_ItemsHint")
    else
        self.itemsEmpty = nil
    end
end

-- The page's own state line (under the header): what went wrong, or that it is still loading.
function Page:rebuildStatus()
    local s, token = nil, nil
    if self.rangeError then s, token = tr("Report_RangeInvalid"), "errorText"
    elseif self.summaryTimeout then s, token = tr("Report_Timeout"), "errorText"
    elseif self.summaryError then s, token = U.adminErrorText(self.summaryError), "errorText"
    elseif self.summary == nil then s, token = tr("Admin_Loading"), "textMuted"
    elseif self.summary.capped == true then s, token = tr("Report_Capped"), "warn" end
    self.statusText, self.statusToken = s, token
end

-- ----- enabling -----

function Page:updateEnabled()
    local read = self.owner:readAllowed()
    local busy = self.inflightId ~= nil
    self.periodTabs:setEnabled(read)
    self.curTabs:setEnabled(read)
    self.fromField:setEnabled(read)
    self.toField:setEnabled(read)
    self.refreshButton:setEnable(read and not busy)
    local m = self.market
    self.regenButton:setEnable(read and not busy and not (m and m.state == "running"))
    local has = self.flowSeries ~= nil
    self.onlyInButton:setEnable(read and has)
    self.onlyOutButton:setEnable(read and has)
end

-- ----- geometry -----

-- The currencies this server names: the tab row is hidden when there is only one.
function Page:currencyIds()
    local out = {}
    for _, id in ipairs(EC.CURRENCY_ORDER) do
        if U.currencyDef(id) ~= nil then out[#out + 1] = id end
    end
    if #out == 0 then out[1] = EC.CURRENCY_ORDER[1] end
    return out
end

function Page:layoutHeader(w, on)
    local g = self.g
    local tabs = self.periodTabs
    local rowH = tabs.height
    local y = 6
    local x = PAD
    g.titleY = y + math.floor((rowH - fontH.medium) / 2)
    x = x + textWidth(tr("Report_Title"), UIFont.Medium) + 12
    tabs:setVisible(on); tabs:setX(x); tabs:setY(y)
    x = x + tabs.width + 8
    local ids = self:currencyIds()
    local shown = {}
    for _, id in ipairs(ids) do shown[id] = true end
    for _, id in ipairs(EC.CURRENCY_ORDER) do
        self.curTabs:setItemVisible(id, shown[id] == true)
        self.curTabs:setItemLabel(id, U.currencyName(id))
    end
    if not shown[self.currency] then self.currency = ids[1]; self.curTabs:setSelected(ids[1], true) end
    local curOn = on and #ids > 1
    self.curTabs:setVisible(curOn)
    if curOn then
        self.curTabs:setX(x); self.curTabs:setY(y)
        x = x + self.curTabs.width + 8
    end
    local refresh = self.refreshButton
    refresh:setVisible(on)
    refresh:setX(w - PAD - refresh.width); refresh:setY(y + math.floor((rowH - refresh.height) / 2))
    local right = refresh.x - 8
    local meta = self.rangeText
    if meta and self.updatedAt then
        meta = getText(T .. "Report_UpdatedAt", meta, U.clockText(self.updatedAt, self.owner.offsetMin))
    end
    g.meta = meta
    local metaW = meta and textWidth(meta) or 0
    local custom = self.period == "custom"
    local row2 = y + rowH + 6
    local bottom = y + rowH
    -- the custom days: beside the tabs when they fit, else on a row of their own
    local dw = self.fromField.width
    local tildeW = textWidth("~") + 12
    local datesW = dw * 2 + tildeW
    local dx, dy = x, y
    if custom and x + datesW + (metaW > 0 and metaW + 12 or 0) > right then dx, dy = PAD, row2 end
    self.fromField:setVisible(on and custom); self.toField:setVisible(on and custom)
    if custom then
        self.fromField:setX(dx); self.fromField:setY(dy)
        self.toField:setX(dx + dw + tildeW); self.toField:setY(dy)
        g.tildeX, g.tildeY = dx + dw + 6, dy + math.floor((rowH - fontH.small) / 2)
        x = dx + datesW + 12
        bottom = math.max(bottom, dy + rowH)
    end
    if meta then
        local my = (dy == y) and y or dy
        if (my == y and x + metaW > right) then my = row2 end
        g.metaX = (my == y) and (right - metaW) or (w - PAD - metaW)
        g.metaY = my + math.floor((rowH - fontH.small) / 2)
        bottom = math.max(bottom, my + rowH)
    end
    if self.statusText and self.flowSeries ~= nil then
        g.statusY = bottom + 4
        g.statusLine = fitText(self.statusText, w - PAD * 2)
        bottom = g.statusY + fontH.small
    end
    return bottom + 6
end

-- Content coordinates: every block below records its own y; placeBody subtracts the offset.
function Page:layoutBody(cw)
    local g = self.g
    local lh, sh, mh, LH = lineH(), fontH.small, fontH.medium, largeH()
    local titleH = math.max(30, mh + 12)
    g.titleH = titleH
    local y = 0
    -- KPI row
    local kw = math.floor((cw - GAP * 4) / 5)
    g.kpiW, g.kpiY = kw, y
    g.kpiH = 8 + sh + 2 + LH + 2 + sh + 2 + sh + 4 + 30 + 6
    for i, k in ipairs(self.kpis or {}) do
        k.x = (i - 1) * (kw + GAP)
        k.valueFit = fitText(k.value, kw - 20, UIFont.Large)
        k.labelFit = fitText(k.label, kw - 20)
        k.noteFit = k.note and fitText(k.note, kw - 20) or nil
        k.vsFit = k.vs and fitText(k.vs, math.max(10, kw - 20 - 50)) or nil
        k.subFit = k.sub and fitText(k.sub, kw - 20) or nil
    end
    y = y + g.kpiH + GAP
    y = self:layoutFlow(cw, y)
    y = self:layoutCols(cw, y)
    y = self:layoutSources(cw, y)
    y = self:layoutItems(cw, y)
    y = self:layoutShop(cw, y)
    g.footLines = U.wrapText(tr("Report_PageFoot"), cw - PAD)
    g.footY = y
    return y + #g.footLines * lh + 4
end

function Page:layoutFlow(cw, y)
    local g = self.g
    local lh = lineH()
    g.flowY = y
    local cy = y + 4
    -- card head: title, the muted subtitle, the two filter chips on the right
    local b2 = self.onlyOutButton
    local b1 = self.onlyInButton
    b2.contentY = cy + math.floor((g.titleH - b2.height) / 2) - 4
    b2.contentX = cw - PAD - b2.width
    b1.contentY = b2.contentY
    b1.contentX = b2.contentX - 6 - b1.width
    g.flowTitleY = y + math.floor((g.titleH - fontH.medium) / 2)
    local titleW = textWidth(tr("Report_FlowTitle"), UIFont.Medium)
    g.flowSub = fitText(tr("Report_FlowSub"), math.max(0, b1.contentX - PAD - titleW - 24))
    g.flowSubX = PAD + titleW + 12
    cy = y + g.titleH
    -- legend: wrapped swatches
    local lx, ly = PAD, cy
    for _, e in ipairs(self.legend or {}) do
        if lx > PAD and lx + e.w > cw - PAD then lx, ly = PAD, ly + lh end
        e.x, e.y = lx, ly
        lx = lx + e.w + 12
    end
    cy = ly + lh + 2
    local chartH = math.max(160, math.min(260, math.floor(cw * 0.3)))
    local chart = self.flowChart
    chart.contentY, chart.contentX = cy, PAD
    chart:setWidth(cw - PAD * 2); chart:setHeight(chartH)
    cy = cy + chartH + 4
    g.flowFoot = U.wrapText(self.flowFoot or "", cw - PAD * 2)
    g.flowFootY = cy
    cy = cy + #g.flowFoot * lh + 6
    g.flowH = cy - y
    return cy + GAP
end

function Page:layoutCols(cw, y)
    local g = self.g
    local lh = lineH()
    g.colsY = y
    local lw = math.floor((cw - GAP) * 1.4 / 2.4)
    g.supX, g.supW = 0, lw
    g.wlX, g.wlW = lw + GAP, cw - lw - GAP
    local chartH = 150
    local sc = self.supplyChart
    sc.contentY, sc.contentX = y + g.titleH, PAD
    sc:setWidth(lw - PAD * 2); sc:setHeight(chartH)
    local wc = self.wealthChart
    wc.contentY, wc.contentX = y + g.titleH, g.wlX + PAD
    wc:setWidth(g.wlW - PAD * 2); wc:setHeight(chartH)
    g.wlFoot = U.wrapText(self.wealthFoot or "", g.wlW - PAD * 2)
    g.colsFootY = y + g.titleH + chartH + 4
    g.supSub = fitText(tr("Report_SupplySub"), math.max(0, lw - PAD * 3 - textWidth(tr("Report_SupplyTitle"), UIFont.Medium)
        - (self.supplyPill and U.pillWidth(self.supplyPill.label, self.supplyPill.value) or 0) - 12))
    g.colsH = g.titleH + chartH + 4 + math.max(1, #g.wlFoot) * lh + 8
    return y + g.colsH + GAP
end

-- Column x positions: fixed widths (at least their header) and one flexible column.
local function columns(x0, width, fixed, flex)
    local xs, ws = {}, {}
    local used = 0
    for i, f in ipairs(fixed) do if i ~= flex then used = used + f end end
    local flexW = math.max(40, width - used - GAP * (#fixed - 1))
    local x = x0
    for i, f in ipairs(fixed) do
        ws[i] = i == flex and flexW or f
        xs[i] = x
        x = x + ws[i] + GAP
    end
    return xs, ws
end

local function headW(key, min) return math.max(min, textWidth(tr(key)) + 4) end

function Page:placeRows(rowsPanel, y, cw, rowH)
    rowsPanel.rowH = rowH
    rowsPanel.contentY, rowsPanel.contentX = y, 1
    rowsPanel:setWidth(cw - 2)
    rowsPanel:setHeight(math.max(1, #rowsPanel.rows * rowH))
    return y + #rowsPanel.rows * rowH
end

function Page:layoutSources(cw, y)
    local g = self.g
    local lh, sh = lineH(), fontH.small
    g.srcY = y
    g.srcSub = fitText(self.sourcesSub or "", math.max(0, cw - PAD * 3 - textWidth(tr("Report_SourcesTitle"), UIFont.Medium)))
    local theadH = math.max(22, sh + 8)
    g.theadH = theadH
    g.srcHeadY = y + g.titleH
    local inner = cw - PAD * 2
    local fixed = { 0, headW("Report_Col_Count", 60), headW("Report_Col_Amount", 100), 0, headW("Report_Col_Delta", 64) }
    local rest = math.max(80, inner - fixed[2] - fixed[3] - fixed[5] - GAP * 4)
    fixed[1] = math.floor(rest * 1.4 / 2.7)
    fixed[4] = rest - fixed[1]
    local xs, ws = columns(PAD, inner, fixed, 0)
    g.srcXs, g.srcWs = xs, ws
    local rows = self.sourceRows
    for _, r in ipairs(rows.rows) do r.labelFit = fitText(r.label, ws[1]) end
    rows.cols = { xs = xs, ws = ws, shareW = math.max(10, ws[4] - textWidth("100%") - 8) }
    local rowH = math.max(26, sh + 12)
    local cy = self:placeRows(rows, g.srcHeadY + theadH, cw, rowH)
    g.srcFoot = U.wrapText(self.sourcesFoot or "", inner)
    g.srcFootY = cy + 4
    cy = cy + 4 + #g.srcFoot * lh + 6
    g.srcH = cy - y
    return cy + GAP
end

function Page:layoutItems(cw, y)
    local g = self.g
    local lh, sh = lineH(), fontH.small
    g.itY = y
    local regen = self.regenButton
    regen.contentY = y + math.floor((g.titleH - regen.height) / 2)
    regen.contentX = cw - PAD - regen.width
    g.itStatusW = textWidth(self.marketStatus or "")
    g.itStatusX = regen.contentX - 10 - g.itStatusW
    local titleW = textWidth(tr("Report_ItemsTitle"), UIFont.Medium)
    g.itSub = fitText(self.itemsSub or "", math.max(0, g.itStatusX - PAD - titleW - 24))
    g.itHeadY = y + g.titleH
    local inner = cw - PAD * 2
    local fixed = { 38, 0, headW("Report_Col_Trades", 54), headW("Report_Col_Amount", 78),
        headW("Report_Col_Median", 86), headW("Report_Col_Range", 92), headW("Report_Col_Trend", 84) }
    local xs, ws = columns(PAD, inner, fixed, 2)
    local rows = self.itemRows
    rows.cols = { xs = xs, ws = ws }
    g.itXs, g.itWs = xs, ws
    for _, r in ipairs(rows.rows) do
        r.nameFit = fitText(r.name, ws[2])
        r.subFit = fitText(r.sub, ws[2])
    end
    local rowH = math.max(40, sh * 2 + 10)
    local cy = g.itHeadY + g.theadH
    if self.itemsEmpty then
        g.itEmptyY = cy + 6
        g.itEmpty = fitText(self.itemsEmpty, inner)
        cy = cy + lh + 12
        self:placeRows(rows, cy, cw, rowH)
    else
        g.itEmpty = nil
        cy = self:placeRows(rows, cy, cw, rowH)
    end
    cy = cy + 6
    g.itH = cy - y
    return cy + GAP
end

function Page:layoutShop(cw, y)
    local g = self.g
    local lh, sh = lineH(), fontH.small
    g.shY = y
    g.shSub = self.shopSub or ""
    g.shHeadY = y + g.titleH
    local inner = cw - PAD * 2
    local fixed = { 38, 0, headW("Report_Col_Units", 64), headW("Report_Col_Revenue", 82), headW("Report_Col_SoldOut", 100) }
    local xs, ws = columns(PAD, inner, fixed, 2)
    local rows = self.shopRows
    rows.cols = { xs = xs, ws = ws }
    g.shXs, g.shWs = xs, ws
    for _, r in ipairs(rows.rows) do
        local tagW = r.tagText and (textWidth(r.tagText) + 18) or 0
        r.tagW = tagW
        r.nameFit = fitText(r.name, ws[2] - tagW)
        r.nameW = textWidth(r.nameFit)
        r.subFit = fitText(r.sub, ws[2])
    end
    local rowH = math.max(40, sh * 2 + 10)
    local cy = g.shHeadY + g.theadH
    if #rows.rows == 0 then
        g.shEmptyY = cy + 6
        cy = cy + lh + 12
    else
        g.shEmptyY = nil
    end
    cy = self:placeRows(rows, cy, cw, rowH) + 6
    g.shH = cy - y
    return cy + GAP
end

function Page:layout()
    local w, h = self.width, self.height
    self.offsetMin = self.owner.offsetMin
    self.g = {}
    local on = self:getIsVisible()
    local top = self:layoutHeader(w, on)
    local body = self.body
    body:setX(0); body:setY(top)
    body:setWidth(w); body:setHeight(math.max(1, h - top))
    body:setVisible(on)
    self.g.top = top
    local has = self.flowSeries ~= nil
    local cw = w - PAD - GUTTER
    self.g.cw = cw
    body.contentH = has and (self:layoutBody(cw) + PAD) or 0
    local bar = body.bar
    local scroll = has and body:maxScrollOffset() > 0
    bar:setVisible(scroll)
    bar:setX(w - 17 - 4); bar:setY(0)
    bar:setWidth(17); bar:setHeight(body.height)
    body.scrollOffset = math.max(0, math.min(body.scrollOffset or 0, body:maxScrollOffset()))
    for _, c in ipairs(self.bodyChildren) do c:setVisible(has) end
    self:placeBody()
    self:updateEnabled()
end

-- Every body child at its content position less the scroll offset (and the body's left pad).
function Page:placeBody()
    local off = self.body.scrollOffset or 0
    for _, c in ipairs(self.bodyChildren) do
        if c.contentY ~= nil then
            c:setX(PAD + (c.contentX or 0))
            c:setY(c.contentY - off)
        end
    end
end

function Page:resize(width, height)
    if self.width ~= width then self:setWidth(width) end
    if self.height ~= height then self:setHeight(height) end
    self:layout()
end

function Page:setVisible(visible)
    local was = self:getIsVisible()
    local offsetChanged = visible and self.offsetMin ~= self.owner.offsetMin
    ISPanel.setVisible(self, visible)
    if not visible and self.fromField ~= nil then
        self.fromField:blur()
        self.toField:blur()
    end
    if self.body ~= nil and (was ~= visible or offsetChanged) then
        if offsetChanged and self.summary ~= nil then self:rebuildSummary() end
        if offsetChanged then self:rebuildMarketStatus() end
        self:layout()
    end
end

-- ----- drawing -----

function Page:prerender()
    local g = self.g
    if g == nil then return end
    text(self, tr("Report_Title"), PAD, g.titleY, "text", UIFont.Medium)
    if self.fromField:getIsVisible() then text(self, "~", g.tildeX, g.tildeY, "textMuted") end
    if g.meta then text(self, g.meta, g.metaX, g.metaY, "textMuted") end
    if g.statusLine then text(self, g.statusLine, PAD, g.statusY, self.statusToken or "textMuted") end
end

function Page:render() end

local function cardFrame(el, x, y, w, h)
    fill(el, x, y, w, h, "card")
    border(el, x, y, w, h, "border")
end

-- A pill right-aligned at `right`; returns its left edge.
local function pillRight(el, right, y, pill)
    if pill == nil then return right end
    local pw = U.pillWidth(pill.label, pill.value)
    U.drawPill(el, right - pw, y, pill.label, pill.value)
    return right - pw
end

function Page:drawBody(body)
    local g = self.g
    if g == nil then return end
    local off = body.scrollOffset or 0
    if self.flowSeries == nil then
        if self.statusText then text(body, self.statusText, PAD, PAD, self.statusToken or "textMuted") end
        return
    end
    local vh = body.height
    local x0 = PAD
    if g.kpiY + g.kpiH - off > 0 and g.kpiY - off < vh then self:drawKpis(body, x0, g.kpiY - off) end
    if g.flowY + g.flowH - off > 0 and g.flowY - off < vh then self:drawFlowCard(body, x0, g.flowY - off) end
    if g.colsY + g.colsH - off > 0 and g.colsY - off < vh then self:drawColsCards(body, x0, g.colsY - off) end
    if g.srcY + g.srcH - off > 0 and g.srcY - off < vh then self:drawSourcesCard(body, x0, g.srcY - off) end
    if g.itY + g.itH - off > 0 and g.itY - off < vh then self:drawItemsCard(body, x0, g.itY - off) end
    if g.shY + g.shH - off > 0 and g.shY - off < vh then self:drawShopCard(body, x0, g.shY - off) end
    local lh = lineH()
    for i, line in ipairs(g.footLines) do text(body, line, x0, g.footY - off + (i - 1) * lh, "textFaint") end
end

function Page:drawKpis(el, x0, y)
    local g = self.g
    local sh, LH = fontH.small, largeH()
    local Ch = C.Charts
    for _, k in ipairs(self.kpis) do
        local x = x0 + k.x
        cardFrame(el, x, y, g.kpiW, g.kpiH)
        local ty = y + 8
        text(el, k.labelFit, x + 10, ty, "textMuted")
        ty = ty + sh + 2
        text(el, k.valueFit, x + 10, ty, k.token, UIFont.Large)
        ty = ty + LH + 2
        if k.vsFit then
            text(el, k.vsFit, x + 10, ty, "textMuted")
            if k.pct ~= nil then Ch.drawDelta(el, x + 10 + textWidth(k.vsFit) + 6, ty, k.pct, "textMuted") end
        elseif k.subFit then
            text(el, k.subFit, x + 10, ty, "textMuted")
        end
        ty = ty + sh + 2
        if k.noteFit then text(el, k.noteFit, x + 10, ty, "textFaint") end
        ty = ty + sh + 4
        if k.spark then Ch.drawSpark(el, x + 10, ty, g.kpiW - 20, 30, k.spark, k.rgb) end
    end
end

function Page:drawCardHead(el, x, y, w, title, sub, subX)
    local g = self.g
    text(el, title, x + PAD, y + math.floor((g.titleH - fontH.medium) / 2), "text", UIFont.Medium)
    if sub and sub ~= "" then
        text(el, sub, subX or (x + PAD + textWidth(title, UIFont.Medium) + 12),
            y + math.floor((g.titleH - fontH.small) / 2), "textMuted")
    end
end

function Page:drawFlowCard(el, x0, y)
    local g = self.g
    local lh = lineH()
    cardFrame(el, x0, y, g.cw, g.flowH)
    self:drawCardHead(el, x0, y, g.cw, tr("Report_FlowTitle"), g.flowSub, x0 + g.flowSubX)
    local dy = y - g.flowY
    local sw = 10
    for _, e in ipairs(self.legend or {}) do
        local ey = e.y + dy + math.floor((fontH.small - sw) / 2) + 1
        if e.line then drawSwatch(el, x0 + e.x, ey + 4, 14, 3, e.rgb)
        else drawSwatch(el, x0 + e.x, ey, sw, sw, e.rgb) end
        text(el, e.label, x0 + e.x + 19, e.y + dy, "textMuted")
    end
    for i, line in ipairs(g.flowFoot) do text(el, line, x0 + PAD, g.flowFootY + dy + (i - 1) * lh, "textFaint") end
end

function Page:drawColsCards(el, x0, y)
    local g = self.g
    local lh = lineH()
    local th = math.floor((g.titleH - U.CHIP_H) / 2)
    -- money supply
    cardFrame(el, x0 + g.supX, y, g.supW, g.colsH)
    self:drawCardHead(el, x0 + g.supX, y, g.supW, tr("Report_SupplyTitle"), g.supSub)
    pillRight(el, x0 + g.supX + g.supW - PAD, y + th, self.supplyPill)
    -- wealth
    local wx = x0 + g.wlX
    cardFrame(el, wx, y, g.wlW, g.colsH)
    self:drawCardHead(el, wx, y, g.wlW, tr("Report_WealthTitle"), nil)
    pillRight(el, wx + g.wlW - PAD, y + th, self.wealthPill)
    local fy = g.colsFootY - g.colsY + y
    for i, line in ipairs(g.wlFoot) do text(el, line, wx + PAD, fy + (i - 1) * lh, "textFaint") end
end

-- The column header band; xs are card-relative, the card's left edge is x.
local function drawThead(el, x, y, w, h, xs, ws, keys, rightAlign)
    fill(el, x + 1, y, w - 2, h, "well")
    local ty = y + math.floor((h - fontH.small) / 2)
    for i, key in ipairs(keys) do
        if key ~= "" then
            if rightAlign[i] then textRight(el, tr(key), x + xs[i] + ws[i], ty, "textMuted")
            else text(el, tr(key), x + xs[i], ty, "textMuted") end
        end
    end
end

local SRC_HEAD = { "Report_Col_Source", "Report_Col_Count", "Report_Col_Amount", "Report_Col_Share", "Report_Col_Delta" }
local SRC_RIGHT = { false, true, true, false, false }
local IT_HEAD = { "", "Report_Col_Item", "Report_Col_Trades", "Report_Col_Amount", "Report_Col_Median", "Report_Col_Range", "Report_Col_Trend" }
local IT_RIGHT = { false, false, true, true, true, true, false }
local SH_HEAD = { "", "Report_Col_Product", "Report_Col_Units", "Report_Col_Revenue", "Report_Col_SoldOut" }
local SH_RIGHT = { false, false, true, true, true }

function Page:drawSourcesCard(el, x0, y)
    local g = self.g
    local lh = lineH()
    local dy = y - g.srcY
    cardFrame(el, x0, y, g.cw, g.srcH)
    self:drawCardHead(el, x0, y, g.cw, tr("Report_SourcesTitle"), g.srcSub)
    drawThead(el, x0, g.srcHeadY + dy, g.cw, g.theadH, g.srcXs, g.srcWs, SRC_HEAD, SRC_RIGHT)
    for i, line in ipairs(g.srcFoot) do text(el, line, x0 + PAD, g.srcFootY + dy + (i - 1) * lh, "textFaint") end
end

function Page:drawItemsCard(el, x0, y)
    local g = self.g
    local dy = y - g.itY
    cardFrame(el, x0, y, g.cw, g.itH)
    self:drawCardHead(el, x0, y, g.cw, tr("Report_ItemsTitle"), g.itSub)
    if self.marketStatus then
        text(el, self.marketStatus, x0 + g.itStatusX, y + math.floor((g.titleH - fontH.small) / 2),
            self.marketStatusToken or "textMuted")
    end
    drawThead(el, x0, g.itHeadY + dy, g.cw, g.theadH, g.itXs, g.itWs, IT_HEAD, IT_RIGHT)
    if g.itEmpty then text(el, g.itEmpty, x0 + PAD, g.itEmptyY + dy, "textMuted") end
end

function Page:drawShopCard(el, x0, y)
    local g = self.g
    local dy = y - g.shY
    local th = math.floor((g.titleH - U.CHIP_H) / 2)
    cardFrame(el, x0, y, g.cw, g.shH)
    self:drawCardHead(el, x0, y, g.cw, tr("Report_ShopTitle"), g.shSub)
    pillRight(el, x0 + g.cw - PAD, y + th, self.shopPill)
    drawThead(el, x0, g.shHeadY + dy, g.cw, g.theadH, g.shXs, g.shWs, SH_HEAD, SH_RIGHT)
    if g.shEmptyY then text(el, tr("Report_ShopEmpty"), x0 + PAD, g.shEmptyY + dy, "textMuted") end
end

-- Row painters (Rows:render calls them with the row panel as `el`; x is panel-relative, so the
-- body's PAD is taken off the column positions).
local function rowTextY(y, rh) return y + math.floor((rh - fontH.small) / 2) end

function P.drawSourceRow(el, r, y)
    local rh = el.rowH
    local xs, ws = el.cols.xs, el.cols.ws
    local ty = rowTextY(y, rh)
    local dx = -1
    if r.section then
        text(el, r.label, xs[1] + dx, ty, "textMuted")
        textRight(el, r.amt, xs[3] + ws[3] + dx, ty, r.token)
        return
    end
    text(el, r.labelFit, xs[1] + dx, ty, "text")
    textRight(el, r.cnt, xs[2] + ws[2] + dx, ty, "textMuted")
    textRight(el, r.amt, xs[3] + ws[3] + dx, ty, r.token)
    local shareW = el.cols.shareW
    C.Charts.drawShare(el, xs[4] + dx, y + math.floor((rh - 8) / 2), shareW, 8, r.frac, r.rgb)
    text(el, r.share, xs[4] + dx + shareW + 6, ty, "textMuted")
    if r.pct ~= nil then C.Charts.drawDelta(el, xs[5] + dx, ty, r.pct, "textMuted")
    elseif r.isNew then text(el, tr("Report_New"), xs[5] + dx, ty, "textMuted") end
end

local function drawItemIcon(el, item, x, y, size)
    local tex = U.itemTexture(item)
    if tex then pcall(el.drawTextureScaled, el, tex, x, y, size, size, 1, 1, 1, 1) end
end

function P.drawItemRow(el, r, y)
    local rh = el.rowH
    local xs, ws = el.cols.xs, el.cols.ws
    local dx = -1
    local sh = fontH.small
    drawItemIcon(el, r.item, xs[1] + dx, y + math.floor((rh - 28) / 2), 28)
    local ny = y + math.floor((rh - sh * 2 - 2) / 2)
    text(el, r.nameFit, xs[2] + dx, ny, "text")
    text(el, r.subFit, xs[2] + dx, ny + sh + 2, "textMuted")
    local ty = rowTextY(y, rh)
    textRight(el, r.n, xs[3] + ws[3] + dx, ty, "text")
    textRight(el, r.amt, xs[4] + ws[4] + dx, ty, "text")
    textRight(el, r.median, xs[5] + ws[5] + dx, ty, "text")
    textRight(el, r.range, xs[6] + ws[6] + dx, ty, "textMuted")
    if r.spark then C.Charts.drawSpark(el, xs[7] + dx, y + math.floor((rh - 22) / 2), ws[7], 22, r.spark, SPARK_RGB) end
end

function P.drawShopRow(el, r, y)
    local rh = el.rowH
    local xs, ws = el.cols.xs, el.cols.ws
    local dx = -1
    local sh = fontH.small
    drawItemIcon(el, r.item, xs[1] + dx, y + math.floor((rh - 28) / 2), 28)
    local ny = y + math.floor((rh - sh * 2 - 2) / 2)
    text(el, r.nameFit, xs[2] + dx, ny, "text")
    if r.tagText then
        local tx = xs[2] + dx + r.nameW + 6
        local tok = r.tag == "soldout" and "warn" or "textMuted"
        border(el, tx, ny, r.tagW - 6, sh + 1, r.tag == "soldout" and "warn" or "border", "pill")
        text(el, r.tagText, tx + 6, ny, tok)
    end
    text(el, r.subFit, xs[2] + dx, ny + sh + 2, "textMuted")
    local ty = rowTextY(y, rh)
    textRight(el, r.units, xs[3] + ws[3] + dx, ty, "text")
    textRight(el, r.amt, xs[4] + ws[4] + dx, ty, "text")
    textRight(el, r.capDays, xs[5] + ws[5] + dx, ty, r.capToken)
end

-- ----- keyboard -----

function Page:keyboardTargets()
    local out = {}
    local body = self.body
    out[#out + 1] = { kind = "button", label = tr("Report_Period"), control = self.periodTabs }
    if self.fromField:getIsVisible() then
        self.fromField:appendTargets(out, tr("Report_From"))
        self.toField:appendTargets(out, tr("Report_To"))
    end
    if self.curTabs:getIsVisible() then
        out[#out + 1] = { kind = "button", label = tr("Report_Currency"), control = self.curTabs }
    end
    out[#out + 1] = { kind = "button", label = tr("Report_Refresh"), control = self.refreshButton }
    if self.flowSeries ~= nil then
        out[#out + 1] = { kind = "button", label = tr("Report_OnlyIn"), control = self.onlyInButton, scrollOwner = body }
        out[#out + 1] = { kind = "button", label = tr("Report_OnlyOut"), control = self.onlyOutButton, scrollOwner = body }
        local d = self.flowChart:focusDescriptor(tr("Report_FlowTitle"))
        d.scrollOwner = body
        out[#out + 1] = d
        if #self.sourceRows.rows > 0 then
            out[#out + 1] = { kind = "button", label = tr("Report_SourcesTitle"), control = self.sourceRows,
                scrollOwner = body, captionSide = "none" }
        end
        out[#out + 1] = { kind = "button", label = tr("Report_Regenerate"), control = self.regenButton, scrollOwner = body }
        if #self.itemRows.rows > 0 then
            out[#out + 1] = { kind = "button", label = tr("Report_ItemsTitle"), control = self.itemRows,
                scrollOwner = body, captionSide = "none" }
        end
        if body:maxScrollOffset() > 0 then
            out[#out + 1] = { kind = "scroll", label = tr("Report_Title"), control = body, focusable = false }
        end
    end
    return out
end

function Page:isModal() return false end
function Page:onEscape() return false end

-- ----- lifecycle -----

-- Permission collapse: everything learned and everything asked for is dropped; nothing is sent
-- until the controller says reading is allowed again.
function Page:clear()
    self.summary, self.market = nil, nil
    self.flowSeries, self.kpis, self.legend, self.keys = nil, nil, nil, nil
    self.supplyPill, self.wealthPill, self.shopPill = nil, nil, nil
    self.rangeText, self.rangeFrom, self.rangeTo = nil, nil, nil
    self.updatedAt = nil
    self.inflightId, self.inflight = nil, nil
    self.summaryReqId, self.marketReqId, self.marketAskedDays = nil, nil, nil
    self.summaryError, self.summaryTimeout, self.marketError, self.marketTimeout = nil, false, nil, false
    self.marketState, self.marketPollAt, self.marketRefresh = nil, nil, false
    self.summaryWant, self.marketWant = true, true
    self.rangeError = nil
    self.sourceRows.rows, self.itemRows.rows, self.shopRows.rows = {}, {}, {}
    self.sourceRows.cursor, self.itemRows.cursor = nil, nil
    self.flowMode = "all"
    self.body.scrollOffset = 0
    self:rebuildStatus()
    self:rebuildMarketStatus()
    self:layout()
end

function Page:dispose()
    self.fromField:blur()
    self.toField:blur()
    self:clear()
end

-- ---------- module API ----------

function P.create(owner, send, isPending, newRequestId)
    local o = ISPanel:new(0, 0, 600, 300)
    setmetatable(o, Page)
    o.background = false
    o.owner = owner
    o.send, o.isPending, o.newRequestId = send, isPending, newRequestId
    o.offsetMin = owner.offsetMin
    o.period = "d30"
    o.currency = EC.CURRENCY_ORDER[1]
    o.flowMode = "all"
    o.summaryWant, o.marketWant = true, true
    o.summaryTimeout, o.marketTimeout = false, false
    o:initialise()
    o:instantiate()
    o:rebuildStatus()
    o:setVisible(false)
    return o
end

return P
