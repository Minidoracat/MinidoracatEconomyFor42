-- MinidoracatEconomyFor42 — the calendar popover behind every "YYYY-MM-DD" filter field.
-- The text entry stays the source of truth: this file only adds a small calendar button next to
-- one and, on demand, a single shared month grid that writes the picked day back through the
-- entry's own setText. Typing keeps working exactly as before.
--
-- Facade (the panels never touch the popup itself):
--   D.attach(entry, owner) -> button   creates + addChild()s the calendar button (owner places it),
--                                      and points entry.calendarButton at it
--   D.close(owner?)                    closes the open popup (all owners when owner is nil)
--   D.active                           the open popup, or nil
--
-- One popup exists per session and is built on the first open, so no field ever carries 42 idle
-- day cells; the days are painted, not child elements, and hit-tested from the click position.
--
-- Engine references (snapshot 42.20.4-20260826):
--   setText does not notify               ISTextEntryBox.lua:109-115 -> UITextBox2.java:780-802;
--                                         update :398-471 does not call onTextChange either.
--                                         After a changed value, call ISTextEntryBox:onTextChange
--                                         (:19-23) once to reach the existing filter handler.
--   popup pattern                         ISUI/ISComboBox.lua:185-215 (setAlwaysOnTop + setCapture +
--                                         addToUIManager / removeFromUIManager), :123-157 (a captured
--                                         popup closes on the click outside), :37-42 (it drops itself
--                                         when the anchor stops being visible), :159-179 (anchored at
--                                         the widget, flipped upwards near the screen edge)
--   capture routing                       UIManager.java:472-492 (isOverElement returns 1 for a
--                                         capturing element, so it is asked first), :661-704 (the
--                                         click stops at the first element that returns true)
--   key events                            ISUIElement.lua:1828-1835 (setWantKeyEvents), dispatched to
--                                         top-level UI only: UIManager.java:1435-1466 (the list is
--                                         walked backwards, so this popup is asked before the
--                                         window) -> UIElement.java:2185-2214: onConsumeKeyPress
--                                         calls onKeyPress *first* and isKeyConsumed afterwards, so
--                                         the answer comes from ECKeyboard's ledger and not from a
--                                         key list. Vanilla shape: ISUI/Crafting/
--                                         ISHandcraftWindow.lua:289-299 + :386.
--   key names                             Keyboard.KEY_ESCAPE/RETURN (ISHandcraftWindow.lua:290,
--                                         ISUI/ISTextBox.lua), KEY_LEFT/RIGHT/UP/DOWN (DebugUIs/
--                                         AnimationClipViewer.lua:693+), KEY_PRIOR/KEY_NEXT
--                                         (DebugUIs/StreamMapWindow.lua:180-183), KEY_TAB
--                                         (ISUI/ISMPEditServer.lua:245-260), KEY_HOME/KEY_DELETE
--                                         (Core.java:2056-2076, the engine's own text-entry map)
--   anchor liveness                       ISUIElement.lua:690 (isReallyVisible),
--                                         ISTextEntryBox.lua:73-75 (isEditable)
--   button tooltip                        ISButton.lua:316-346 (updateTooltip), :445 (setTooltip);
--                                         vanilla calls it from ISButton:prerender :176, which the
--                                         mod's Button now re-runs for every button (ECWidgets),
--                                         so this file only sets the text.
--
-- Civil-date maths is EC's (EC.parseDay / EC.daysInMonth): no os.time, no os.date, no second leap
-- year rule. Kahlua truncates a negative % towards zero, so the weekday uses floor division.

require "ISUI/ISPanel"

if not MinidoracatEconomy or not MinidoracatEconomy.Client or not MinidoracatEconomy.Client.UI then
    require "MinidoracatEconomy/ECWidgets"
end
require "MinidoracatEconomy/ECKeyboard"
local EC = MinidoracatEconomy
local C = EC.Client
local U = C.UI
local Keys = C.Keyboard

local D = {}
C.DatePicker = D
D.active = nil

local T = U.T
local PAD = 8
local GAP = 6
local ROWS = 6                      -- a month never needs a seventh row (31 days + 6 lead days)
local MIN_YEAR, MAX_YEAR = 1, 9999  -- the field holds four digits, so the grid stays inside them
local WEEK_KEYS = { "WeekSun", "WeekMon", "WeekTue", "WeekWed", "WeekThu", "WeekFri", "WeekSat" }

local color, fill, border, text, textCentre, textWidth, fitText, pad2 =
    U.color, U.fill, U.border, U.text, U.textCentre, U.textWidth, U.fitText, U.pad2
local fontH = U.fontH
local Button = U.Button

local function tr(suffix) return getText(T .. "DatePicker_" .. suffix) end

local pad4 = U.pad4

local function dateText(y, m, d) return pad4(y) .. "-" .. pad2(m) .. "-" .. pad2(d) end

-- 0 = Sunday, for the first of the month. Day 0 (1970-01-01) was a Thursday, hence the +4; the
-- floor division keeps a pre-1970 month inside 0..6 (Kahlua's % truncates towards zero).
local function firstWeekday(y, m)
    local ms = EC.parseDay(pad4(y) .. "-" .. pad2(m) .. "-01", 0)
    local n = math.floor(ms / 86400000) + 4
    return n - math.floor(n / 7) * 7
end

-- The field's own value, when it is a real day; nil for empty or malformed text (the picker then
-- opens on today's month and leaves the text alone).
local function entryDate(e)
    local ms = EC.parseDay(e:getInternalText(), 0)
    if ms == nil then return nil end
    local y, m, d = EC.utcDate(ms)
    if y < MIN_YEAR or y > MAX_YEAR then return nil end
    return y, m, d
end

local function writeEntry(entry, value)
    if not entry or entry:getInternalText() == value then return end
    entry:setText(value)
    entry:onTextChange()
end

-- ---------- the calendar glyph on the button ----------
-- A vector page (Icons ships no calendar texture): binding tabs, a header band, a 2x3 dot grid.
local function drawGlyph(el, x, y, size, token)
    local c = color(token)
    local a = c.a * U.alpha
    local top = y + 3
    local h = size - 3
    el:drawRectBorder(x, top, size, h, a, c.r, c.g, c.b)
    el:drawRect(x, top, size, 3, a, c.r, c.g, c.b)
    el:drawRect(x + 3, y, 2, 4, a, c.r, c.g, c.b)
    el:drawRect(x + size - 5, y, 2, 4, a, c.r, c.g, c.b)
    local step = math.floor((size - 4) / 3)
    if step < 2 then return end
    for row = 0, 1 do
        for col = 0, 2 do
            el:drawRect(x + 3 + col * step, top + 6 + row * step, 2, 2, a, c.r, c.g, c.b)
        end
    end
end

local IconButton = Button:derive("MinidoracatEconomyDateButton")

function IconButton:render()
    Button.render(self)
    local size = math.min(self.width, self.height) - 10
    if size < 9 then size = 9 end
    local token = "textFaint"
    if self.enable then
        token = (self.active or (self.mouseOver and self:isMouseOver())) and "accent" or "textMuted"
    end
    drawGlyph(self, math.floor((self.width - size) / 2), math.floor((self.height - size) / 2), size, token)
end

-- ---------- the month grid ----------

local Popup = ISPanel:derive("MinidoracatEconomyDatePicker")
local popup   -- the one shared instance, built on the first open

local function shiftMonths(self, delta)
    local total = self.year * 12 + (self.month - 1) + delta
    local y = math.floor(total / 12)
    self:setMonth(y, total - y * 12 + 1)
end

local function onNav(self, b) shiftMonths(self, b.internal) end

local function onToday(self)
    self:write(self.todayY, self.todayM, self.todayD)
end

local function onClear(self)
    local e = self.entry
    D.close()
    writeEntry(e, "")
end

local function onCloseButton(self)
    D.close()
end

function Popup:createChildren()
    self.weekLabels = {}
    for i = 1, 7 do self.weekLabels[i] = tr(WEEK_KEYS[i]) end
    -- "<<" tells nobody what it does: each arrow carries its own words, which the Button tooltip
    -- pass shows the mouse and the focus caption shows the keyboard.
    self.navButtons = {}
    for _, spec in ipairs({ { "<<", -12, "PrevYear" }, { "<", -1, "PrevMonth" },
        { ">", 1, "NextMonth" }, { ">>", 12, "NextYear" } }) do
        local b = Button.create(0, 0, 24, 24, spec[1], self, onNav, "chip")
        b.internal = spec[2]
        b:setTooltip(getText(T .. "Kb_Date_" .. spec[3]))
        self:addChild(b)
        self.navButtons[#self.navButtons + 1] = b
    end
    self.footButtons = {}
    for _, spec in ipairs({ { "Today", onToday }, { "Clear", onClear }, { "Close", onCloseButton } }) do
        local b = Button.create(0, 0, 24, 24, tr(spec[1]), self, spec[2], "chip")
        self:addChild(b)
        self.footButtons[#self.footButtons + 1] = b
    end
end

-- Every measurement comes from MeasureStringX at open time: a large font or a CJK weekday header
-- widens the cells instead of overlapping them.
function Popup:relayout()
    local navH = math.max(U.CHIP_H, fontH.small + 8)
    local cellH = math.max(20, fontH.small + 8)
    local cellW = textWidth("00") + 12
    for i = 1, 7 do
        local w = textWidth(self.weekLabels[i]) + 6
        if w > cellW then cellW = w end
    end
    if cellW < 22 then cellW = 22 end
    local gridW = cellW * 7

    local navW = math.max(navH, textWidth("<<") + 12)
    local titleW = textWidth("0000-00", UIFont.Medium) + 12
    local footW = GAP * (#self.footButtons - 1)
    for _, b in ipairs(self.footButtons) do footW = footW + textWidth(b.fullTitle) + 20 end

    local contentW = gridW
    if navW * 4 + titleW + GAP * 2 > contentW then contentW = navW * 4 + titleW + GAP * 2 end
    if footW > contentW then contentW = footW end

    self.cellW, self.cellH = cellW, cellH
    self.gridX = PAD + math.floor((contentW - gridW) / 2)
    self.navY = PAD
    self.navH = navH
    self.weekY = self.navY + navH + GAP
    self.gridY = self.weekY + fontH.small + 4
    local footY = self.gridY + cellH * ROWS + GAP
    self:setWidth(contentW + PAD * 2)
    self:setHeight(footY + navH + PAD)

    local x = PAD
    for i, b in ipairs(self.navButtons) do
        if i == 3 then x = PAD + contentW - navW * 2 end
        b:setWidth(navW); b:setHeight(navH); b:setX(x); b:setY(self.navY)
        b.title = fitText(b.fullTitle, navW - 6)
        x = x + navW
    end
    x = PAD + math.floor((contentW - footW) / 2)
    for _, b in ipairs(self.footButtons) do
        local w = textWidth(b.fullTitle) + 20
        b:setWidth(w); b:setHeight(navH); b:setX(x); b:setY(footY)
        b.title = fitText(b.fullTitle, w - 8)
        x = x + w + GAP
    end
end

-- Returns false when the month is outside the four-digit range (the caller then stops moving).
function Popup:setMonth(y, m)
    if y < MIN_YEAR or y > MAX_YEAR then return false end
    self.year, self.month = y, m
    self.days = EC.daysInMonth(y, m)
    self.lead = firstWeekday(y, m)
    if self.cursor and self.cursor > self.days then self.cursor = self.days end
    for _, button in ipairs(self.navButtons) do
        local target = y * 12 + m - 1 + button.internal
        button:setEnable(target >= MIN_YEAR * 12 and target < (MAX_YEAR + 1) * 12)
    end
    return true
end

function Popup:write(y, m, d)
    local e = self.entry
    local s = dateText(y, m, d)
    D.close()                       -- the field's own handler reruns the page: let it find no popup
    writeEntry(e, s)
end

function Popup:moveCursor(delta)
    local d = self.cursor + delta
    for _ = 1, 4 do
        if d < 1 then
            local y, m = self.year, self.month - 1
            if m < 1 then y, m = y - 1, 12 end
            if not self:setMonth(y, m) then d = 1; break end
            d = d + self.days
        elseif d > self.days then
            d = d - self.days
            local y, m = self.year, self.month + 1
            if m > 12 then y, m = y + 1, 1 end
            if not self:setMonth(y, m) then d = self.days; break end
        else
            break
        end
    end
    if d < 1 then d = 1 elseif d > self.days then d = self.days end
    self.cursor = d
end

-- The anchor decides the popup's life: a hidden tab, a closed window, a read-only (non-editable)
-- field or a hidden/disabled button all take the calendar with them.
function Popup:anchorAlive()
    local e = self.entry
    if not e or not e.javaObject then return false end
    if not e:isReallyVisible() then return false end
    local parent = e.parent
    while parent do
        if parent.isCollapsed then return false end
        parent = parent.parent
    end
    if e.isEditable and not e:isEditable() then return false end
    local b = self.button
    if b and (not b:isReallyVisible() or b.enable == false) then return false end
    return true
end

function Popup:place()
    local e = self.entry
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    local x, ay = e:getAbsoluteX(), e:getAbsoluteY()
    local y = ay + e:getHeight() + 2
    if y + self.height > sh then y = ay - self.height - 2 end   -- no room below: flip above
    if y + self.height > sh then y = sh - self.height end       -- anchor itself off-screen
    if y < 0 then y = 0 end
    if x + self.width > sw then x = sw - self.width end
    if x < 0 then x = 0 end
    self:setX(x); self:setY(y)
end

function Popup:prerender()
    if not self:anchorAlive() then D.close(); return end
    self:place()                    -- follows the window while it is dragged or relaid out

    local w, h = self.width, self.height
    fill(self, 0, 0, w, h, "surface")
    border(self, 0, 0, w, h, "border")
    textCentre(self, pad4(self.year) .. "-" .. pad2(self.month), w / 2,
        self.navY + math.floor((self.navH - fontH.medium) / 2), "text", UIFont.Medium)

    local cw, ch = self.cellW, self.cellH
    local gx, gy = self.gridX, self.gridY
    for i = 1, 7 do
        textCentre(self, self.weekLabels[i], gx + (i - 1) * cw + cw / 2, self.weekY, "textFaint")
    end

    local ty = math.floor((ch - fontH.small) / 2)
    local selHere = self.selY == self.year and self.selM == self.month
    local todayHere = self.todayY == self.year and self.todayM == self.month
    for i = 0, ROWS * 7 - 1 do
        local d = i - self.lead + 1
        if d >= 1 and d <= self.days then
            local col = i - math.floor(i / 7) * 7
            local cx = gx + col * cw
            local cy = gy + math.floor(i / 7) * ch
            local token = (col == 0 or col == 6) and "textMuted" or "text"
            if selHere and d == self.selD then
                fill(self, cx + 1, cy + 1, cw - 2, ch - 2, "selected", "rect")
                border(self, cx + 1, cy + 1, cw - 2, ch - 2, "accent", "rect")
                token = "accent"
            end
            if todayHere and d == self.todayD then
                token = "gold"
                fill(self, cx + math.floor(cw / 4), cy + ch - 3, math.floor(cw / 2), 1, "gold", "rect")
            end
            if d == self.cursor then border(self, cx, cy, cw, ch, "accent", "rect") end
            textCentre(self, tostring(d), cx + cw / 2, cy + ty, token)
        end
    end
end

function Popup:onMouseDown(x, y)
    if self:isMouseOver() then return true end        -- inside: never falls through to the page
    if self.button and self.button:isReallyVisible() and self.button:isMouseOver() then
        return false                                  -- our own button: let its click close us
    end
    D.close()
    return false
end

function Popup:onMouseUp(x, y)
    if not self:isMouseOver() then return false end
    local col = math.floor((x - self.gridX) / self.cellW)
    local row = math.floor((y - self.gridY) / self.cellH)
    if col >= 0 and col < 7 and row >= 0 and row < ROWS then
        local d = row * 7 + col - self.lead + 1
        if d >= 1 and d <= self.days then self:write(self.year, self.month, d) end
    end
    return true
end

-- ---------- keyboard ----------
-- The popup is its own top-level element, so it is offered the key events before the window is
-- (UIManager.java:1435-1466 walks the UI list backwards). Everything the mouse can press here has
-- a key: the grid keeps the arrows, Tab / Shift+Tab walk the nav and foot buttons the same way the
-- window's own Tab walks its targets, and Home / Delete are the direct twins of Today / Clear.
--
-- Acting on the press (not the release) is what lets a held arrow repeat; the release of that same
-- hold is consumed through the shared ledger, including the Escape that removed this popup from the
-- UI list before its release event existed (the window answers that one).

-- The focus ring inside the popup: 0 is the day grid (the cursor cell is the ring), 1..n are the
-- four nav arrows followed by Today / Clear / Close.
local function focusRow(self)
    local row = {}
    for _, b in ipairs(self.navButtons) do
        if b:getIsVisible() and b.enable ~= false then row[#row + 1] = b end
    end
    for _, b in ipairs(self.footButtons) do
        if b:getIsVisible() and b.enable ~= false then row[#row + 1] = b end
    end
    return row
end

local function stepFocus(self, delta)
    local row = focusRow(self)
    local count = #row + 1                  -- the grid is one of the stops
    local i = (self.kbFocus or 0) + delta
    while i < 0 do i = i + count end
    while i >= count do i = i - count end
    self.kbFocus = i
end

function Popup:focusedButton()
    local i = self.kbFocus or 0
    if i < 1 then return nil end
    local row = focusRow(self)
    return row[i]
end

local function popupKey(self, key)
    local k = Keyboard
    if key == k.KEY_TAB then
        local back = false
        if isShiftKeyDown ~= nil then
            local ok, down = pcall(isShiftKeyDown)
            back = ok and down == true
        end
        stepFocus(self, back and -1 or 1)
        return true
    end
    if key == k.KEY_ESCAPE then D.close(); return true end
    if key == k.KEY_PRIOR then shiftMonths(self, -1); return true end
    if key == k.KEY_NEXT then shiftMonths(self, 1); return true end
    if key == k.KEY_HOME then onToday(self); return true end
    if key == k.KEY_DELETE then onClear(self); return true end
    local button = self:focusedButton()
    if key == k.KEY_RETURN or key == k.KEY_NUMPADENTER or key == k.KEY_SPACE then
        if button == nil then
            self:write(self.year, self.month, self.cursor)
        else
            pcall(button.forceClick, button)    -- ISButton:forceClick: one onclick call, gates checked
        end
        return true
    end
    if button ~= nil then
        -- a focused chip: left/right walk the chips, up/down hand the keyboard back to the grid
        if key == k.KEY_LEFT then stepFocus(self, -1); return true end
        if key == k.KEY_RIGHT then stepFocus(self, 1); return true end
        if key == k.KEY_UP or key == k.KEY_DOWN then self.kbFocus = 0; return true end
        return false
    end
    if key == k.KEY_LEFT then self:moveCursor(-1); return true end
    if key == k.KEY_RIGHT then self:moveCursor(1); return true end
    if key == k.KEY_UP then self:moveCursor(-7); return true end
    if key == k.KEY_DOWN then self:moveCursor(7); return true end
    return false
end

function Popup:onKeyPress(key)
    if D.active ~= self then return end
    if popupKey(self, key) then Keys.eat(key) end
end

-- Only the four arrows repeat: a held Escape or Enter must act once.
function Popup:onKeyRepeat(key)
    if D.active ~= self then return end
    local k = Keyboard
    if key ~= k.KEY_LEFT and key ~= k.KEY_RIGHT and key ~= k.KEY_UP and key ~= k.KEY_DOWN
        and key ~= k.KEY_PRIOR and key ~= k.KEY_NEXT then
        return
    end
    if popupKey(self, key) then Keys.eat(key) end
end

function Popup:onKeyRelease(key)
    Keys.release(key)
end

-- Asked after the handler ran (UIElement.java:2185-2214), so the ledger and not the key list is the
-- answer: a key that closed this popup is still ours for the rest of that hold.
function Popup:isKeyConsumed(key)
    return Keys.consumed(key)
end

-- The chips are children, so they were painted before this call: the ring goes on top of them.
-- The four arrows paint "<<" and friends, so their words (the tooltip) are the focus caption; a
-- chip that already paints its whole label gets the ring alone.
function Popup:render()
    local button = self:focusedButton()
    if button == nil then return end
    local x = button:getAbsoluteX() - self:getAbsoluteX()
    local y = button:getAbsoluteY() - self:getAbsoluteY()
    local caption = button.tooltip
    if caption == button.title then caption = nil end
    U.drawFocus(self, x, y, button.width, button.height)
    U.drawFocusCaption(self, x, y, button.width, button.height, caption)
end

-- ---------- facade ----------

local function ensurePopup()
    if popup then return popup end
    local o = ISPanel:new(0, 0, 100, 100)
    setmetatable(o, Popup)
    o.background = false
    o:initialise()
    o:instantiate()
    o:setAlwaysOnTop(true)
    o:setCapture(true)              -- the click outside reaches us first, so we can close
    o:setWantKeyEvents(true)        -- only top-level UI is offered key events
    o:setVisible(false)
    popup = o
    return o
end

function D.open(entry, owner, button)
    D.close()
    entry:unfocus()
    local p = ensurePopup()
    p.entry, p.owner, p.button = entry, owner, button
    if button then button.active = true end
    local offsetMin = tonumber(owner and owner.offsetMin) or U.localOffsetMinutes()
    local ty, tm, td = EC.utcDate(getTimestampMs() + offsetMin * 60000)
    p.todayY, p.todayM, p.todayD = ty, tm, td
    local y, m, d = entryDate(entry)
    p.selY, p.selM, p.selD = y, m, d
    p.cursor = nil
    -- the calendar opens on the day grid, and remembers whether the keyboard was the one that
    -- opened it: only then does closing it hand the ring back to the button
    p.kbFocus = 0
    p.kbReturn = Keys.focused() == button
    p:setMonth(y or ty, m or tm)
    p.cursor = d or ((ty == p.year and tm == p.month) and td or 1)
    p:relayout()
    p:place()
    p:setVisible(true)
    p:addToUIManager()
    p:bringToTop()
    D.active = p
    return p
end

function D.close(owner)
    local p = D.active
    if not p then return end
    if owner ~= nil and p.owner ~= owner then return end
    D.active = nil
    if p.button then p.button.active = false end
    local button, back = p.button, p.kbReturn
    p.entry, p.owner, p.button = nil, nil, nil
    p.kbFocus, p.kbReturn = 0, nil
    p:setVisible(false)
    p:removeFromUIManager()
    if back and button ~= nil then Keys.refocus(button) end
end

local function onButtonClick(owner, button)
    local p = D.active
    if p and p.entry == button.dateEntry then D.close(); return end
    D.open(button.dateEntry, owner, button)
end

-- The button is square by nature (a glyph, no label): the owner should give it the entry's height
-- for both width and height, and owns its X/Y/visible/enable from then on.
function D.attach(entry, owner)
    local h = math.max(U.CHIP_H, entry.height or U.CHIP_H)
    local b = Button.create(0, 0, h, h, "", owner, onButtonClick, "chip")
    setmetatable(b, IconButton)
    b.dateEntry = entry
    b:setTooltip(tr("Open"))
    entry.calendarButton = b
    local lostFocus = entry.onLostFocus
    entry.onLostFocus = function(e)
        if lostFocus then lostFocus(e) end
        local y, m, d = entryDate(e)
        if y then writeEntry(e, dateText(y, m, d)) end
    end
    owner:addChild(b)
    return b
end

return D
