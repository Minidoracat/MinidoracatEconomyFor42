-- MinidoracatEconomyFor42 - chart painters (client): the daily flow chart, the line chart and the
-- histogram of the admin reports page and overview card, plus the small pieces a table row or a
-- KPI card paints inline (trend sparkline, share bar, change arrow).
--
-- Every chart is plain rectangles and lines in the element's own coordinates: no rounded corners,
-- no stencil (a parent may be a scrolling panel that owns the stencil). Geometry is computed into
-- flat arrays when the data arrive or the size changes (checked in prerender); render only loops
-- over those arrays - no table, closure or string is built per frame. A nil / false value is a gap:
-- the line breaks there. All-zero data draws an empty chart with only the zero line.
--
-- The palette is the chart's own (not theme tokens): the inflow and outflow series colours, the
-- net line, the grid. Text is drawn with U.text in textFaint / text.
--
-- Engine references (snapshot 42.20.4-20260826):
--   drawRect      ISUIElement.lua:1191-1198 (x, y, w, h, a, r, g, b)
--   drawLine      ISUIElement.lua:1235-1240 (texture, x1, y1, x2, y2, thickness, a, r, g, b; element coords)
--   drawPolygon   ISUIElement.lua:1254-1258 (texture, 4 corners, r, g, b, a; nil texture as ISWorldMap.lua:508)

require "ISUI/ISPanel"

if not MinidoracatEconomy or not MinidoracatEconomy.Client or not MinidoracatEconomy.Client.UI then
    require "MinidoracatEconomy/ECWidgets"
end

local EC = MinidoracatEconomy
local C = EC.Client
local U = C.UI

local Ch = {}
C.Charts = Ch

local floor, ceil, max, min, abs = math.floor, math.ceil, math.max, math.min, math.abs
local fontH = U.fontH

-- A colour carries both forms: named (r, g, b, a: what U.color returns) and positional [1..3].
local function hex(s)
    local r = tonumber(string.sub(s, 1, 2), 16) / 255
    local g = tonumber(string.sub(s, 3, 4), 16) / 255
    local b = tonumber(string.sub(s, 5, 6), 16) / 255
    return { r = r, g = g, b = b, a = 1, r, g, b }
end

Ch.IN = { hex("73d973"), hex("4fae5a"), hex("a5e8a5"), hex("2f7d3a") }
Ch.OUT = { hex("f27366"), hex("c94f45"), hex("ffa094"), hex("8f3a33") }
Ch.NET = hex("ffd966")

local NET = Ch.NET
local GRID_A, ZERO_A, CURSOR_A, TRACK_A, AREA_A = 0.08, 0.25, 0.07, 0.10, 0.10
local HATCH_STEP, HATCH_SHADE, HATCH_LINE = 8, 0.35, 0.65
local CAP_BG, CAP_BORDER, CAP_PAD, CAP_GAP = hex("111111"), hex("666666"), 8, 16

local function round(v) return floor(v + 0.5) end

-- A number, or nil for a gap (nil, false, anything else).
local function num(v)
    if type(v) == "number" then return v end
    return nil
end

-- Highest positive integer key: arrays may carry nil holes, where # is undefined.
local function count(t)
    local n = 0
    if type(t) ~= "table" then return 0 end
    for k in pairs(t) do
        if type(k) == "number" and k > n and k == floor(k) then n = k end
    end
    return n
end

-- 1, 2, 2.5, 5 x 10^k, never below 1 (amounts are whole coins).
local function niceStep(raw)
    if raw <= 1 then return 1 end
    local mag = 1
    while mag * 10 <= raw do mag = mag * 10 end
    if raw <= mag then return mag end
    if raw <= 2 * mag then return 2 * mag end
    if mag >= 10 and raw <= 2.5 * mag then return 2.5 * mag end
    if raw <= 5 * mag then return 5 * mag end
    return 10 * mag
end

local function tickCount(plotH)
    return max(2, floor(plotH / (fontH.small * 2.2)))
end

local function defaultFormat(n) return U.amountText(n) end

local function newChart(class, x, y, w, h)
    local o = ISPanel:new(x, y, w, h)
    setmetatable(o, class)
    o.background = false
    o.n = 0
    o.data = {}
    o.format = defaultFormat
    o.layoutW, o.layoutH = -1, -1
    o.labS, o.labW = {}, {}
    o.tkV, o.tkY, o.tkS, o.tkW, o.tkX = {}, {}, {}, {}, {}
    o.tkN = 0
    o.xlX, o.xlS = {}, {}
    o.xlN = 0
    o.px, o.py = {}, {}
    o.sX1, o.sY1, o.sX2, o.sY2 = {}, {}, {}, {}
    o.sN = 0
    o.dX, o.dY = {}, {}
    o.dN = 0
    o:initialise()
    return o
end

local function setLabels(o, labels, n)
    for i = 1, n do
        local s = tostring(labels[i] or "")
        o.labS[i] = s
        o.labW[i] = U.textWidth(s)
    end
end

-- Y ticks from `from` to `to` by `step`; y = top + (hi - v) * scale. Returns the widest label.
local function setTicks(o, from, to, step, top, hi, scale, format)
    local n, widest = 0, 0
    local count = floor((to - from) / step + 0.5)
    for k = 0, count do
        local v = from + k * step
        local s = tostring(format(v))
        n = n + 1
        o.tkV[n] = v
        o.tkY[n] = round(top + (hi - v) * scale)
        o.tkS[n] = s
        o.tkW[n] = U.textWidth(s)
        widest = max(widest, o.tkW[n])
    end
    o.tkN = n
    return widest
end

local function placeTicks(o, plotX)
    for k = 1, o.tkN do o.tkX[k] = plotX - 6 - o.tkW[k] end
end

-- X labels centred at x0 + (i - 1) * gap + off, every `step` days counted back from the last one
-- (the last day - "today" - always shows), step chosen so no two labels touch.
local function setXLabels(o, n, x0, gap, off)
    local widest = 0
    for i = 1, n do widest = max(widest, o.labW[i]) end
    local step = max(1, ceil((widest + 8) / max(1, gap)))
    local k, i = 0, n
    while i >= 1 do
        local s, w = o.labS[i], o.labW[i]
        if s ~= "" then
            k = k + 1
            o.xlX[k] = max(0, min(o.width - w, round(x0 + (i - 1) * gap + off - w / 2)))
            o.xlS[k] = s
        end
        i = i - step
    end
    o.xlN = k
end

-- Polyline segments between consecutive present points of o.px / o.py (false = gap); a point
-- with no present neighbour becomes a dot.
local function setSegments(o, n)
    local sN, dN = 0, 0
    local px, py = o.px, o.py
    for i = 1, n do
        if py[i] then
            if i > 1 and py[i - 1] then
                sN = sN + 1
                o.sX1[sN], o.sY1[sN], o.sX2[sN], o.sY2[sN] = px[i - 1], py[i - 1], px[i], py[i]
            elseif not (i < n and py[i + 1]) then
                dN = dN + 1
                o.dX[dN], o.dY[dN] = px[i], py[i]
            end
        end
    end
    o.sN, o.dN = sN, dN
end

local function drawTicks(o, plotX, plotW)
    local half = floor(fontH.small / 2)
    for k = 1, o.tkN do
        local y = o.tkY[k]
        o:drawRect(plotX, y, plotW, 1, o.tkV[k] == 0 and ZERO_A or GRID_A, 1, 1, 1)
        U.text(o, o.tkS[k], o.tkX[k], y - half, "textFaint")
    end
end

local function drawXLabels(o, y)
    for k = 1, o.xlN do U.text(o, o.xlS[k], o.xlX[k], y, "textFaint") end
end

local function drawSegments(o, thickness, c)
    for k = 1, o.sN do
        o:drawLine(nil, o.sX1[k], o.sY1[k], o.sX2[k], o.sY2[k], thickness, 1, c.r, c.g, c.b)
    end
    for k = 1, o.dN do o:drawRect(o.dX[k] - 1, o.dY[k] - 1, 3, 3, 1, c.r, c.g, c.b) end
end

local function relayoutIfResized(o)
    if o.width ~= o.layoutW or o.height ~= o.layoutH then o:layout() end
end

-- ---------- 1) daily flow chart ----------

local Flow = ISPanel:derive("MinidoracatEconomyFlowChart")
Ch.FlowChart = Flow

function Flow.create(x, y, w, h)
    local o = newChart(Flow, x, y, w, h)
    o.rX, o.rY, o.rH, o.rC = {}, {}, {}, {}
    o.rN = 0
    o.hX, o.hY, o.hW, o.hH = {}, {}, {}, {}
    o.hN = 0
    o.hlX1, o.hlY1, o.hlX2, o.hlY2 = {}, {}, {}, {}
    o.hlN = 0
    o.colX = {}
    o.capS, o.capT, o.capR, o.capRT = {}, {}, {}, {}
    o.capN = 0
    return o
end

function Flow:setData(data)
    data = type(data) == "table" and data or {}
    self.data = data
    local labels = type(data.labels) == "table" and data.labels or {}
    local n = count(labels)
    self.n = n
    setLabels(self, labels, n)
    self.format = type(data.format) == "function" and data.format or defaultFormat
    if self.cursor and self.cursor > n then
        if n > 0 then self.cursor = n else self.cursor = nil end
    end
    if self.hover and self.hover > n then self.hover = nil end
    self:layout()
    self:refreshCaption(true)
end

local function paletteColor(set, c, j)
    local idx = floor(tonumber(c) or j)
    return set[((idx - 1) % 4) + 1]
end

-- Stack one direction of day i from zeroY; returns the far edge (top for up, bottom for down).
function Flow:stack(series, set, i, bx, zeroY, scale, sign)
    local cum, edge = 0, zeroY
    for j = 1, #series do
        local s = series[j]
        local v = type(s) == "table" and type(s.values) == "table" and num(s.values[i]) or nil
        if v and v > 0 then
            cum = cum + v
            local y = round(zeroY - sign * cum * scale)
            if y ~= edge then
                local n = self.rN + 1
                self.rN = n
                self.rX[n], self.rC[n] = bx, paletteColor(set, s.color, j)
                if sign > 0 then self.rY[n], self.rH[n] = y, edge - y
                else self.rY[n], self.rH[n] = edge, y - edge end
                edge = y
            end
        end
    end
    return edge
end

-- "/" stripes over the rectangle [x0, x1] x [y0, y1], clipped to it.
function Flow:hatchLines(x0, y0, x1, y1)
    local n = self.hlN
    local c = x0 + y0 + HATCH_STEP
    while c < x1 + y1 do
        local xa, xb = max(x0, c - y1), min(x1, c - y0)
        if xb > xa then
            n = n + 1
            self.hlX1[n], self.hlY1[n], self.hlX2[n], self.hlY2[n] = xa, c - xa, xb, c - xb
        end
        c = c + HATCH_STEP
    end
    self.hlN = n
end

local function seriesTotal(series, i)
    local sum = 0
    for j = 1, #series do
        local s = series[j]
        local v = type(s) == "table" and type(s.values) == "table" and num(s.values[i]) or nil
        if v and v > 0 then sum = sum + v end
    end
    return sum
end

function Flow:layout()
    local w, h, n, data = self.width, self.height, self.n, self.data
    self.layoutW, self.layoutH = w, h
    local fh = fontH.small
    local top, bottom = ceil(fh / 2) + 2, h - fh - 6
    local up = type(data.up) == "table" and data.up or {}
    local down = type(data.down) == "table" and data.down or {}
    local net = type(data.net) == "table" and data.net or nil
    local hiV, loV = 0, 0
    for i = 1, n do
        hiV = max(hiV, seriesTotal(up, i))
        loV = max(loV, seriesTotal(down, i))
        local v = net and num(net[i])
        if v then hiV, loV = max(hiV, v), max(loV, -v) end
    end
    local plotH = max(1, bottom - top)
    local hi, lo, scale, widest
    if hiV == 0 and loV == 0 then
        hi, lo = 1, -1   -- nothing to show: the zero line alone, mid-height
        scale = plotH / 2
        widest = setTicks(self, 0, 0, 1, top, hi, scale, self.format)
    else
        local step = niceStep((hiV + loV) / tickCount(plotH))
        hi, lo = ceil(hiV / step) * step, -ceil(loV / step) * step
        scale = plotH / (hi - lo)
        widest = setTicks(self, lo, hi, step, top, hi, scale, self.format)
    end
    local zeroY = round(top + hi * scale)
    local plotX = widest + 8
    local plotW = max(1, w - plotX - 8)
    placeTicks(self, plotX)
    local gap = plotW / max(1, n)
    local bw = gap < 3 and max(1, floor(gap)) or max(1, floor(gap * 0.62))
    self.plotX, self.plotW, self.top, self.bottom, self.gap, self.barW = plotX, plotW, top, bottom, gap, bw
    self.colW = max(1, round(gap) - 2)
    self.rN, self.hN, self.hlN = 0, 0, 0
    local hatch = type(data.hatch) == "table" and data.hatch or {}
    for i = 1, n do
        local bx = round(plotX + (i - 1) * gap + (gap - bw) / 2)
        self.colX[i] = round(plotX + (i - 1) * gap) + 1
        local topY = self:stack(up, Ch.IN, i, bx, zeroY, scale, 1)
        local botY = self:stack(down, Ch.OUT, i, bx, zeroY, scale, -1)
        if hatch[i] and botY > topY then
            local k = self.hN + 1
            self.hN = k
            self.hX[k], self.hY[k], self.hW[k], self.hH[k] = bx, topY, bw, botY - topY
            self:hatchLines(bx, topY, bx + bw, botY)
        end
        local v = net and num(net[i])
        self.px[i] = round(plotX + (i - 0.5) * gap)
        self.py[i] = v and round(zeroY - v * scale) or false
    end
    setSegments(self, n)
    setXLabels(self, n, plotX, gap, gap / 2)
    self:placeCaption()
end

Flow.prerender = relayoutIfResized

local function captionToken(token)
    if type(token) ~= "string" or U.color(token) == nil then return "text" end
    return token
end

-- The caption is asked for only when the shown day changes (or the data do), never per frame.
function Flow:refreshCaption(force)
    local shown = self.hover or self.cursor
    if shown == self.capFor and not force then return end
    self.capFor = shown
    self.capOn = false
    local fn = self.data.caption
    if not shown or type(fn) ~= "function" then return end
    local cap = fn(shown)
    if type(cap) ~= "table" then return end
    local lines = type(cap.lines) == "table" and cap.lines or {}
    local title = tostring(cap.title or "")
    local w = U.textWidth(title)
    local leftW, rightW, n = 0, 0, 0
    for k = 1, #lines do
        local line = lines[k]
        if type(line) == "table" then
            n = n + 1
            local s = tostring(line.text or "")
            local sw = U.textWidth(s)
            self.capS[n], self.capT[n] = s, captionToken(line.token)
            if line.right ~= nil then
                local r = tostring(line.right)
                self.capR[n], self.capRT[n] = r, captionToken(line.rightToken)
                leftW, rightW = max(leftW, sw), max(rightW, U.textWidth(r))
            else
                self.capR[n] = false
                w = max(w, sw)
            end
        end
    end
    if rightW > 0 then w = max(w, leftW + CAP_GAP + rightW) end
    local fh = fontH.small
    self.capTitle, self.capN = title, n
    self.capRX = CAP_PAD + leftW + CAP_GAP
    self.capW = w + CAP_PAD * 2
    self.capH = CAP_PAD * 2 + fh + n * (fh + 2)
    self.capOn = true
    self:placeCaption()
end

-- Beside the shown day: left of it on the right half, right of it otherwise; inside the chart.
function Flow:placeCaption()
    local i = self.capFor
    if not self.capOn then return end
    if not i or i > self.n then
        self.capOn = false
        return
    end
    local left = self.colX[i]
    local right = left + self.colW
    local x
    if left + right > self.width then x = left - 6 - self.capW else x = right + 6 end
    self.capX = max(0, min(self.width - self.capW, x))
    self.capY = max(0, min(self.height - self.capH, self.top + 4))
end

function Flow:render()
    local plotX, top, bottom = self.plotX, self.top, self.bottom
    drawTicks(self, plotX, self.plotW)
    local shown = self.hover or self.cursor
    if shown and shown <= self.n then
        self:drawRect(self.colX[shown], top, self.colW, bottom - top, CURSOR_A, 1, 1, 1)
    end
    local bw = self.barW
    for k = 1, self.rN do
        local c = self.rC[k]
        self:drawRect(self.rX[k], self.rY[k], bw, self.rH[k], 1, c.r, c.g, c.b)
    end
    for k = 1, self.hN do
        self:drawRect(self.hX[k], self.hY[k], self.hW[k], self.hH[k], HATCH_SHADE, 0, 0, 0)
    end
    for k = 1, self.hlN do
        self:drawLine(nil, self.hlX1[k], self.hlY1[k], self.hlX2[k], self.hlY2[k], 1, HATCH_LINE, 0, 0, 0)
    end
    drawSegments(self, 2, NET)
    drawXLabels(self, bottom + 4)
    if self.capOn then
        local x, y, w, h = self.capX, self.capY, self.capW, self.capH
        local fh = fontH.small
        self:drawRect(x, y, w, h, 0.95, CAP_BG.r, CAP_BG.g, CAP_BG.b)
        self:drawRectBorder(x, y, w, h, 1, CAP_BORDER.r, CAP_BORDER.g, CAP_BORDER.b)
        U.text(self, self.capTitle, x + CAP_PAD, y + CAP_PAD, "text")
        local ly = y + CAP_PAD + fh + 2
        for k = 1, self.capN do
            U.text(self, self.capS[k], x + CAP_PAD, ly, self.capT[k])
            if self.capR[k] then U.text(self, self.capR[k], x + self.capRX, ly, self.capRT[k]) end
            ly = ly + fh + 2
        end
    end
end

function Flow:indexAt(x)
    if self.n == 0 or not self.gap then return nil end
    local i = floor((x - self.plotX) / self.gap) + 1
    if i < 1 or i > self.n then return nil end
    return i
end

function Flow:onMouseMove()
    local i = self:indexAt(self:getMouseX())
    if i ~= self.hover then
        self.hover = i
        self:refreshCaption()
    end
end

function Flow:onMouseMoveOutside()
    if self.hover then
        self.hover = nil
        self:refreshCaption()
    end
end

function Flow:onMouseDown(x)
    local i = self:indexAt(x)
    if i then
        self.cursor = i
        self:refreshCaption()
        if self.onPick then self.onPick(self, i) end
    end
    return true
end

function Flow:setCursor(index)
    index = tonumber(index)
    if index and self.n > 0 then
        self.cursor = max(1, min(self.n, floor(index)))
    else
        self.cursor = nil
    end
    self:refreshCaption()
end

-- Focus engine (MinidoracatUI Focus.lua header): a "button" target asks onFocusKey first.
function Flow:onFocusKey(key)
    local n = self.n
    if n == 0 then return false end
    local c = self.cursor
    if key == Keyboard.KEY_LEFT then c = c and max(1, c - 1) or n
    elseif key == Keyboard.KEY_RIGHT then c = c and min(n, c + 1) or n
    elseif key == Keyboard.KEY_HOME then c = 1
    elseif key == Keyboard.KEY_END then c = n
    else return false end
    self.hover = nil
    self:setCursor(c)
    return true
end

-- Enter / controller A: pick the cursor day; with no cursor yet, show one on the last day first.
function Flow:forceClick()
    if not self.cursor then
        if self.n > 0 then self:setCursor(self.n) end
        return
    end
    if self.onPick then self.onPick(self, self.cursor) end
end

function Flow:focusDescriptor(label)
    return { kind = "button", control = self, label = label }
end

-- ---------- 2) sparkline ----------

-- Normalised once per data: s.y[i] in 0..1 (bottom..top) or false for a gap; s.last = last point.
function Ch.spark(values)
    local n = count(values)
    local lo, hi, last
    for i = 1, n do
        local v = num(values[i])
        if v then
            lo = lo and min(lo, v) or v
            hi = hi and max(hi, v) or v
            last = i
        end
    end
    local ys = {}
    for i = 1, n do
        local v = num(values[i])
        if v then
            if hi > lo then ys[i] = (v - lo) / (hi - lo) else ys[i] = 0.5 end
        else
            ys[i] = false
        end
    end
    return { n = n, y = ys, last = last }
end

function Ch.drawSpark(el, x, y, w, h, s, c)
    if not s or not s.last then return end
    local r, g, b = c.r or c[1], c.g or c[2], c.b or c[3]
    local ys, n, last = s.y, s.n, s.last
    local x0, x1 = x + 2, x + w - 4
    local y0, span = y + 3, h - 6
    local gap = n > 1 and (x1 - x0) / (n - 1) or 0
    local px, py
    for i = 1, n do
        local f = ys[i]
        if f then
            local cx = n > 1 and round(x0 + (i - 1) * gap) or round(x1)
            local cy = round(y0 + (1 - f) * span)
            if py then el:drawLine(nil, px, py, cx, cy, 2, 1, r, g, b) end
            px, py = cx, cy
            if i == last then el:drawRect(cx - 2, cy - 2, 4, 4, 1, r, g, b) end
        else
            py = nil
        end
    end
end

-- ---------- 3) line + area ----------

local Line = ISPanel:derive("MinidoracatEconomyLineChart")
Ch.LineChart = Line

function Line.create(x, y, w, h)
    return newChart(Line, x, y, w, h)
end

function Line:setData(data)
    data = type(data) == "table" and data or {}
    self.data = data
    local labels = type(data.labels) == "table" and data.labels or {}
    local n = max(count(labels), count(data.values))
    self.n = n
    setLabels(self, labels, n)
    self.format = type(data.format) == "function" and data.format or defaultFormat
    self:layout()
end

function Line:layout()
    local w, h, n = self.width, self.height, self.n
    self.layoutW, self.layoutH = w, h
    local values = type(self.data.values) == "table" and self.data.values or {}
    local fh = fontH.small
    local top, bottom = ceil(fh / 2) + 2, h - fh - 6
    local plotH = max(1, bottom - top)
    local lo, hi, first, last
    for i = 1, n do
        local v = num(values[i])
        if v then
            lo = lo and min(lo, v) or v
            hi = hi and max(hi, v) or v
            first = first or i
            last = i
        end
    end
    lo, hi = lo or 0, hi or 0
    local scale, top0, widest
    if hi == lo then
        top0, scale = lo + 1, plotH / 2   -- flat (or empty): one gridline at the value, mid-height
        widest = setTicks(self, lo, lo, 1, top, top0, scale, self.format)
    else
        local step = niceStep((hi - lo) / tickCount(plotH))
        local a, b = floor(lo / step) * step, ceil(hi / step) * step
        top0, scale = b, plotH / (b - a)
        widest = setTicks(self, a, b, step, top, top0, scale, self.format)
    end
    self.lastS = last and tostring(self.format(values[last])) or nil
    local lastW = self.lastS and U.textWidth(self.lastS) or 0
    local plotX = widest + 8
    local plotW = max(1, w - plotX - (lastW > 0 and lastW + 14 or 8))
    placeTicks(self, plotX)
    local gap = n > 1 and plotW / (n - 1) or 0
    for i = 1, n do
        local v = num(values[i])
        self.px[i] = n > 1 and round(plotX + (i - 1) * gap) or round(plotX + plotW / 2)
        self.py[i] = v and round(top + (top0 - v) * scale) or false
    end
    setSegments(self, n)
    self.plotX, self.plotW, self.bottom, self.first, self.last = plotX, plotW, bottom, first, last
    if last then
        self.lastX = self.px[last] + 8
        self.lastY = max(0, min(h - fh, self.py[last] - floor(fh / 2)))
    end
    if n > 1 then setXLabels(self, n, plotX, gap, 0) else setXLabels(self, n, plotX, plotW, plotW / 2) end
end

Line.prerender = relayoutIfResized

function Line:render()
    local base = self.bottom
    drawTicks(self, self.plotX, self.plotW)
    for k = 1, self.sN do
        local x1, y1, x2, y2 = self.sX1[k], self.sY1[k], self.sX2[k], self.sY2[k]
        self:drawPolygon(nil, x1, y1, x2, y2, x2, base, x1, base, NET.r, NET.g, NET.b, AREA_A)
    end
    drawSegments(self, 2, NET)
    local first, last = self.first, self.last
    if first then self:drawRect(self.px[first] - 2, self.py[first] - 2, 5, 5, 1, NET.r, NET.g, NET.b) end
    if last then
        self:drawRect(self.px[last] - 2, self.py[last] - 2, 5, 5, 1, NET.r, NET.g, NET.b)
        U.text(self, self.lastS, self.lastX, self.lastY, "text")
    end
    drawXLabels(self, base + 4)
end

-- ---------- 4) histogram ----------

local Hist = ISPanel:derive("MinidoracatEconomyHistogram")
Ch.Histogram = Hist

function Hist.create(x, y, w, h)
    local o = newChart(Hist, x, y, w, h)
    o.bX, o.bY, o.bH, o.bT = {}, {}, {}, {}
    o.vS, o.vW, o.vX, o.vY = {}, {}, {}, {}
    o.lS, o.lX = {}, {}
    return o
end

function Hist:setData(data)
    data = type(data) == "table" and data or {}
    self.data = data
    local labels = type(data.labels) == "table" and data.labels or {}
    local values = type(data.values) == "table" and data.values or {}
    local n = max(count(labels), count(values))
    self.n = n
    setLabels(self, labels, n)
    local from = tonumber(data.highlightFrom)
    for i = 1, n do
        local v = num(values[i]) or 0
        self.vS[i] = U.amountText(v)
        self.vW[i] = U.textWidth(self.vS[i])
        self.bT[i] = (from and i >= from) and "text" or "textFaint"
    end
    self.axisRaw = data.axis ~= nil and tostring(data.axis) or nil
    self:layout()
end

function Hist:layout()
    local w, h, n = self.width, self.height, self.n
    self.layoutW, self.layoutH = w, h
    local values = type(self.data.values) == "table" and self.data.values or {}
    local fh = fontH.small
    local axisH = self.axisRaw and (fh + 2) or 0
    local labelY = h - axisH - fh - 2
    local base = labelY - 4
    local top = fh + 4
    local maxV = 0
    for i = 1, n do maxV = max(maxV, num(values[i]) or 0) end
    local left, right = 8, w - 8
    local gap = (right - left) / max(1, n)
    local bw = max(1, floor(gap * 0.68))
    local labelW = max(1, floor(gap) - 2)
    for i = 1, n do
        local v = max(0, num(values[i]) or 0)
        local cx = left + (i - 0.5) * gap
        local bh = maxV > 0 and round(v / maxV * (base - top)) or 0
        self.bX[i], self.bY[i], self.bH[i] = round(cx - bw / 2), base - bh, bh
        self.vX[i], self.vY[i] = round(cx - self.vW[i] / 2), base - bh - fh - 2
        local s = U.fitText(self.labS[i], labelW)
        self.lS[i] = s
        self.lX[i] = round(cx - U.textWidth(s) / 2)
    end
    self.left, self.right, self.base, self.labelY, self.bw = left, right, base, labelY, bw
    if self.axisRaw then
        self.axisS = U.fitText(self.axisRaw, max(1, w - 8))
        self.axisX = round((w - U.textWidth(self.axisS)) / 2)
        self.axisY = labelY + fh + 2
    else
        self.axisS = nil
    end
end

Hist.prerender = relayoutIfResized

function Hist:render()
    local bw, labelY = self.bw, self.labelY
    self:drawRect(self.left, self.base, self.right - self.left, 1, ZERO_A, 1, 1, 1)
    for i = 1, self.n do
        if self.bH[i] > 0 then
            local c = U.color(self.bT[i])
            self:drawRect(self.bX[i], self.bY[i], bw, self.bH[i], 1, c.r, c.g, c.b)
        end
        U.text(self, self.vS[i], self.vX[i], self.vY[i], "text")
        U.text(self, self.lS[i], self.lX[i], labelY, "textFaint")
    end
    if self.axisS then U.text(self, self.axisS, self.axisX, self.axisY, "textFaint") end
end

-- ---------- 5) small pieces ----------

-- Share bar: a faint track, filled to frac (0..1) in the given colour.
function Ch.drawShare(el, x, y, w, h, frac, c)
    x, y, w, h = round(x), round(y), round(w), round(h)
    frac = tonumber(frac) or 0
    if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
    el:drawRect(x, y, w, h, TRACK_A, 1, 1, 1)
    local fw = round(w * frac)
    if fw > 0 then el:drawRect(x, y, fw, h, c.a or 1, c.r or c[1], c.g or c[2], c.b or c[3]) end
end

-- Change marker: an up / down arrow (none at 0) and the whole percentage. Strings and widths are
-- cached per value, so a row calling this every frame builds nothing. Returns the width painted.
local deltaS, deltaW = {}, {}
function Ch.drawDelta(el, x, y, pct, token)
    pct = tonumber(pct)
    if pct == nil then return 0 end
    local n = floor(abs(pct) + 0.5)
    local s = deltaS[n]
    if not s then
        s = U.amountText(n) .. "%"
        deltaS[n], deltaW[n] = s, U.textWidth(s)
    end
    token = token or "textMuted"
    x, y = round(x), round(y)
    local ax = 0
    if n > 0 then
        local Skin = U.Skin
        Skin.arrow(el, x, y + floor((fontH.small - Skin.ARROW_H) / 2), pct > 0, U.color(token))
        ax = Skin.ARROW_W + 3
    end
    U.text(el, s, x + ax, y, token)
    return ax + deltaW[n]
end
