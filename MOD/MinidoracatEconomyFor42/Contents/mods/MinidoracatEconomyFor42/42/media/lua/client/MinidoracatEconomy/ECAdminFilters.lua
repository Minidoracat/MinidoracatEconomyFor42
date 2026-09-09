-- Shared filter controls for administrative history and transaction pages.
-- The host supplies updateEnabled(); cfg.onChange owns the page-specific rebuild/read.
require "MinidoracatEconomy/ECWidgets"
require "MinidoracatEconomy/ECDatePicker"
local EC = MinidoracatEconomy
local C = EC.Client
local U = C.UI
local DatePicker = C.DatePicker
local F = {}
C.AdminFilters = F
F.PER_PAGE = 25
local FILTER_KIND_MAX = 12   -- audit has 11 actions; transaction sources have 9
local T, fontH = U.T, U.fontH
local Button = U.Button
local color, text, textWidth, fitText, textRight = U.color, U.text, U.textWidth, U.fitText, U.textRight
local newEntry, entryText, setEntryEditable = U.newEntry, U.entryText, U.setEntryEditable
local ARROW_W, ARROW_H = 7, 4
local onKind, onSort, onPage, onDate
local function tr(key) return getText(T .. key) end
local function entryH() return math.max(26, fontH.small + 12) end

function F.create(panel, cfg)
    local f = { kind = "all", sortKey = cfg.sorts[1], desc = true, page = 1, pages = 1, total = 0,
        label = cfg.label, fields = cfg.fields, kindLabel = cfg.kindLabel,
        fromLabel = cfg.fromLabel, toLabel = cfg.toLabel, sortLabel = tr("Filter_Sort"),
        onChange = cfg.onChange, kindButtons = {}, sortButtons = {}, extras = {} }
    local chipH = math.max(20, fontH.small + 6)
    local function chip(title, internal, handler, dynamic)
        local b = Button.create(0, 0, textWidth(title) + 20, chipH, title, panel, handler, "chip")
        b.internal = internal
        b.filter = f
        b.dynamic = dynamic
        panel:addChild(b)
        return b
    end
    local all = chip(tr("Filter_All"), "all", onKind, false)
    all.active = true
    f.kindButtons[1] = all
    for _ = 1, FILTER_KIND_MAX do
        local b = chip("", nil, onKind, true)
        b.unused = true
        f.kindButtons[#f.kindButtons + 1] = b
    end
    for _, e in ipairs(cfg.extra or {}) do
        f.extras[e[1]] = true
        f.kindButtons[#f.kindButtons + 1] = chip(e[2], e[1], onKind, false)
    end
    for _, key in ipairs(cfg.sorts) do
        local b = chip(tr("Filter_Sort_" .. key), key, onSort, false)
        b.active = key == f.sortKey
        f.sortButtons[#f.sortButtons + 1] = b
    end
    f.prevButton = chip(tr("Market_Prev"), -1, onPage, false)
    f.nextButton = chip(tr("Market_Next"), 1, onPage, false)
    f.dateW = math.max(textWidth("0000-00-00"), textWidth(tr("Filter_DateHint"))) + 24
    for _, key in ipairs({ "fromEntry", "toEntry" }) do
        local e = newEntry(f.dateW, entryH(), { maxLen = 10, clear = true,
            placeholder = tr("Filter_DateHint") })
        e.target = panel
        e.filter = f
        e.onTextChangeFunction = onDate
        panel:addChild(e)
        f[key] = e
        DatePicker.attach(e, panel)
    end
    -- the page line is budgeted for its widest form, so a page change never re-flows the row
    f.pageSample = getText(T .. "Filter_Page", "99", "99") .. "  " .. getText(T .. "Filter_Count", "9999")
    return f
end

-- The dynamic chips: "all" keeps the first slot, every value the data carried takes the next one
-- and the rest are parked. Returns true when the set moved, so the caller re-lays the row out.
function F.kinds(f, values)
    local sig = table.concat(values, "\1")
    if sig == f.sig then return false end
    f.sig = sig
    local n = 0
    for _, b in ipairs(f.kindButtons) do
        if b.dynamic then
            n = n + 1
            local key = values[n]
            b.internal = key
            b.unused = key == nil
            b.fullTitle = key and f.label(key) or ""
            b.title = b.fullTitle
        end
    end
    -- a filter whose chip is gone falls back to everything
    local live = f.kind == "all"
    for _, b in ipairs(f.kindButtons) do
        if not b.unused and b.internal == f.kind then live = true end
    end
    if not live then
        f.kind = "all"
        f.page = 1
    end
    for _, b in ipairs(f.kindButtons) do b.active = (not b.unused) and b.internal == f.kind end
    return true
end

-- One line of kind chips. The slot is budgeted, never natural: a long action name truncates
-- itself instead of pushing the row out of the card. Returns the x just past the last chip.
function F.layoutKinds(f, visible, x, y, w, chipH)
    local shown = {}
    for _, b in ipairs(f.kindButtons) do
        local on = visible and not b.unused
        b:setVisible(on)
        if on then shown[#shown + 1] = b end
    end
    f.kindLabelX = nil
    f.kindLabelY = y + math.floor((chipH - fontH.small) / 2)
    if not visible then return x end
    local cx = x
    if f.kindLabel then
        f.kindLabelX = cx
        cx = cx + textWidth(f.kindLabel) + 6
    end
    local slot = math.floor((x + w - cx) / math.max(1, #shown)) - 4
    for _, b in ipairs(shown) do
        b:setWidth(math.max(24, math.min(textWidth(b.fullTitle) + 20, slot)))
        b:setHeight(chipH)
        b:setX(cx); b:setY(y)
        U.setButtonTitle(b, b.fullTitle)
        cx = cx + b.width + 4
    end
    return cx
end

-- The native popup is shared with other combo boxes; only close it when this field owns it.
function F.closeCombo(combo)
    if not combo or not combo.expanded then return end
    combo.expanded = false
    if combo.popup and combo.popup.parentCombo == combo then combo:hidePopup() end
end

function F.blurDates(f)
    if f.fromEntry:isFocused() then f.fromEntry:unfocus() end
    if f.toEntry:isFocused() then f.toEntry:unfocus() end
end

-- Keep each date and its calendar together; wrap groups instead of clipping the year.
function F.layoutRow(f, visible, x, y, w, eh, chipH)
    if not visible then F.blurDates(f) end
    local band = math.max(eh, chipH)
    f.rowH = band
    f.fromEntry:setVisible(visible)
    f.toEntry:setVisible(visible)
    f.fromEntry.calendarButton:setVisible(visible)
    f.toEntry.calendarButton:setVisible(visible)
    f.prevButton:setVisible(visible)
    f.nextButton:setVisible(visible)
    for _, b in ipairs(f.sortButtons) do b:setVisible(visible) end
    if f.accountCombo then
        f.accountCombo:setVisible(visible)
        F.closeCombo(f.accountCombo)
    end
    if not visible then return end
    local right, cx, cy = x + w, x, y
    local textOffset = math.floor((band - fontH.small) / 2)
    local function place(width)
        if cx > x and cx + width > right then
            cx, cy = x, cy + band + 6
        end
        local at = cx
        cx = cx + width + 8
        return at
    end
    local function dateAt(entry, label, prefix)
        local labelW = textWidth(label)
        local at = place(labelW + 4 + f.dateW + 4 + eh)
        f[prefix .. "LabelX"], f[prefix .. "LabelY"] = at, cy + textOffset
        entry:setWidth(f.dateW); entry:setHeight(eh)
        entry:setX(at + labelW + 4); entry:setY(cy + math.floor((band - eh) / 2))
        local button = entry.calendarButton
        button:setWidth(eh); button:setHeight(eh)
        button:setX(entry.x + f.dateW + 4); button:setY(entry.y)
    end
    dateAt(f.fromEntry, f.fromLabel, "from")
    dateAt(f.toEntry, f.toLabel, "to")
    local labelW = textWidth(f.sortLabel) + 6
    local slot = math.max(24, math.floor((w - labelW) / math.max(1, #f.sortButtons)) - ARROW_W - 4)
    local sortW = labelW
    for _, b in ipairs(f.sortButtons) do
        b:setWidth(math.max(24, math.min(textWidth(b.fullTitle) + 20, slot)))
        b:setHeight(chipH)
        sortW = sortW + b.width + ARROW_W + 4
    end
    local at = place(sortW)
    f.sortLabelX, f.sortLabelY = at, cy + textOffset
    at = at + labelW
    for _, b in ipairs(f.sortButtons) do
        b:setX(at); b:setY(cy + math.floor((band - chipH) / 2))
        U.setButtonTitle(b, b.fullTitle)
        at = at + b.width + ARROW_W + 4
    end
    if f.accountCombo then
        local combo = f.accountCombo
        local accountLabelW = textWidth(f.accountLabel) + 6
        local accountW = math.min(f.accountW, math.max(110, w - accountLabelW))
        local accountX = place(accountLabelW + accountW)
        f.accountLabelX, f.accountLabelY = accountX, cy + textOffset
        combo:setX(accountX + accountLabelW); combo:setY(cy + math.floor((band - eh) / 2))
        combo:setWidth(accountW); combo:setHeight(eh)
        combo.baseHeight = eh
    end
    local nextW = math.max(30, math.min(textWidth(f.nextButton.fullTitle) + 20, math.floor(w * 0.16)))
    local prevW = math.max(30, math.min(textWidth(f.prevButton.fullTitle) + 20, math.floor(w * 0.16)))
    f.pageTextW = math.min(textWidth(f.pageSample), math.floor(w * 0.26))
    place(f.pageTextW + 8 + prevW + 4 + nextW)
    local chipY = cy + math.floor((band - chipH) / 2)
    f.nextButton:setWidth(nextW); f.nextButton:setHeight(chipH)
    f.nextButton:setX(right - nextW); f.nextButton:setY(chipY)
    U.setButtonTitle(f.nextButton, f.nextButton.fullTitle)
    f.prevButton:setWidth(prevW); f.prevButton:setHeight(chipH)
    f.prevButton:setX(f.nextButton.x - 4 - prevW); f.prevButton:setY(chipY)
    U.setButtonTitle(f.prevButton, f.prevButton.fullTitle)
    f.pageTextRight, f.pageTextY = f.prevButton.x - 8, cy + textOffset
    f.rowH = cy - y + band
end

-- Sort direction marker: a 7 x 4 stepped triangle drawn just right of the lit sort chip (the icon
-- set has no chevron_up, and an arrow glyph would not be ASCII). Down = newest / largest first.
local function drawArrow(el, x, y, down, token)
    local c = color(token)
    for i = 0, ARROW_H - 1 do
        local row = down and (ARROW_H - 1 - i) or i
        local rw = 1 + row * 2
        el:drawRect(x + math.floor((ARROW_W - rw) / 2), y + i, rw, 1, c.a, c.r, c.g, c.b)
    end
end

function F.draw(f, panel)
    if not f.fromEntry:getIsVisible() then return end
    if f.kindLabelX then text(panel, f.kindLabel, f.kindLabelX, f.kindLabelY, "textFaint") end
    text(panel, f.fromLabel, f.fromLabelX, f.fromLabelY, "textFaint")
    text(panel, f.toLabel, f.toLabelX, f.toLabelY, "textFaint")
    text(panel, f.sortLabel, f.sortLabelX, f.sortLabelY, "textFaint")
    if f.accountCombo then
        text(panel, f.accountLabel, f.accountLabelX, f.accountLabelY, "textFaint")
    end
    for _, b in ipairs(f.sortButtons) do
        if b.internal == f.sortKey then
            drawArrow(panel, b.x + b.width + 2, b.y + math.floor((b.height - ARROW_H) / 2), f.desc,
                b.enable and "accent" or "textFaint")
        end
    end
    local str = getText(T .. "Filter_Page", tostring(f.page), tostring(f.pages))
        .. "  " .. getText(T .. "Filter_Count", tostring(f.total))
    textRight(panel, fitText(str, f.pageTextW), f.pageTextRight, f.pageTextY, "textFaint")
end

-- The state as EC.filterPage options. A malformed date is simply not a bound (the box's
-- placeholder says what it wants); "to" means the end of that day, so the exclusive bound is the
-- next midnight.
function F.options(f, panel, kindField, timeField)
    local kinds = nil
    if f.kind ~= nil and f.kind ~= "all" and not f.extras[f.kind] then kinds = { [f.kind] = true } end
    local to = EC.parseDay(entryText(f.toEntry), panel.offsetMin)
    return { kinds = kinds, kindField = kindField, timeField = timeField,
        fromMs = EC.parseDay(entryText(f.fromEntry), panel.offsetMin),
        toMs = to and (to + 86400000) or nil,
        sortKey = f.fields[f.sortKey], desc = f.desc, page = f.page, perPage = F.PER_PAGE }
end

-- Permission / modal gate for the whole row. The page chips also follow the page count, so a
-- one-page result never offers a next page.
function F.enable(f, on)
    for _, b in ipairs(f.kindButtons) do b:setEnable(on) end
    for _, b in ipairs(f.sortButtons) do b:setEnable(on) end
    setEntryEditable(f.fromEntry, on)
    setEntryEditable(f.toEntry, on)
    f.fromEntry.calendarButton:setEnable(on)
    f.toEntry.calendarButton:setEnable(on)
    if f.accountCombo then
        f.accountCombo:setEnabled(on)
        if not on then F.closeCombo(f.accountCombo) end
    end
    f.prevButton:setEnable(on and f.page > 1)
    f.nextButton:setEnable(on and f.page < f.pages)
end

-- Every handler ends the same way: the page's own rebuild, then updateEnabled -- the rebuild is
-- what learns the new page count, and the page chips (plus the audit's copy chips, whose line the
-- rebuild just dropped) follow it.
onKind = function(self, button)
    local f = button.filter
    if f.kind == button.internal then return end
    f.kind = button.internal
    f.page = 1
    for _, b in ipairs(f.kindButtons) do b.active = (not b.unused) and b.internal == f.kind end
    f.onChange(self)
    self:updateEnabled()
end

-- Clicking the lit chip flips the direction; picking another column starts it at "biggest first".
onSort = function(self, button)
    local f = button.filter
    if f.sortKey == button.internal then
        f.desc = not f.desc
    else
        f.sortKey = button.internal
        f.desc = true
        for _, b in ipairs(f.sortButtons) do b.active = b.internal == f.sortKey end
    end
    f.page = 1
    f.onChange(self)
    self:updateEnabled()
end

onPage = function(self, button)
    local f = button.filter
    local page = math.max(1, math.min(f.pages, f.page + button.internal))
    if page == f.page then return end
    f.page = page
    f.onChange(self)
    self:updateEnabled()
end

onDate = function(self, entry)
    entry.filter.page = 1
    entry.filter.onChange(self)
    self:updateEnabled()
end

return F
