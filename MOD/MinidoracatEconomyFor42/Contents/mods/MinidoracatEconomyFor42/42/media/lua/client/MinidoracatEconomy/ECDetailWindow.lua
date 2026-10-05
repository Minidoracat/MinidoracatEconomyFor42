-- MinidoracatEconomyFor42 -- the shared detail window (client). Adds exactly one namespace:
-- C.DetailWindow.
--
-- One window for the whole session, borrowed by whichever page is showing a record right now.
-- Before it existed, every page that had something long to say built a band of its own inside
-- its card: the band ate the rows it was describing, it could only ever show the first few
-- lines, and a card too short for both simply dropped the list. This window is the one answer to
-- all of that, and the list underneath keeps every row, every filter, its page and its scroll.
--
--   D.open(owner, key, title, value, onClose?, card?)
--                                   show the record and make it this owner's window. Returns the
--                                   window element, nil when the UI framework is not up. The same
--                                   owner opening a different key reuses this very window (there
--                                   is never a second one); another owner taking it over tells the
--                                   previous one through its onClose.
--   D.update(owner, key, title, value, card?)
--                                   only while that owner's key is really on screen. Returns false
--                                   for a window that was closed, so a reply that came back late
--                                   can never revive it. Keeps the scroll and the technical-info
--                                   state. Every call with a card re-measures: call it when the
--                                   data changed, never per frame.
--   D.close(owner)                  closes the window when it belongs to that owner or to any of
--                                   its descendants (a page, a sub page, a row editor).
--   D.isOpen(owner, key?)           visible, owned by that owner (or a descendant), and -- when a
--                                   key is named -- showing that key.
--   D.text(owner)                   the copy value on screen right now, for the owner only.
--
-- The detail card (contract: .omc/plans/econ-detail-report-1005/impl-contract.md section 1). Every
-- field is optional and a missing block is not drawn; card == nil shows `value` as paragraphs:
--   source, sourceIcon        title bar: small muted label, framework Icons key left of it
--   item | iconKey | coin     header icon (item texture, Icons key, currency), 44 px box
--   name, sub                 header lines (UIFont.Medium; muted, at most two lines)
--   hero                      { value, token, coin, unit, strike } the big number (UIFont.Large)
--   chips                     { { label, value, token, dot, coin } } wrapping pills
--   meters                    { { label, frac, value, token } } 8 px bars
--   rows                      { { label, value, note, token, coin } } label left, value right
--   flow                      { { name, role, delta, token, note } } who paid, who received
--   sections                  { { title, lines = { { pill | mark = "ok"|"no", text, note } } } }
--   text                      free text ("\n\n" paragraphs, "\n" lines)
--   note                      one muted line above the actions
--   actions, actionsLeft      { { id, label, style, enabled, coin, tooltip, run } } -- the window
--                             never validates: a press only calls run(). `enabled` may be a
--                             function: it is asked again every frame (a pending read, the
--                             terminal in reach), so a card never keeps a state its row lost
--   tech, techHint, techOpen  { { label, value } } behind a collapsed "technical info" row
-- The middle part scrolls (wheel, keyboard); the note, the actions and the technical-info row stay
-- fixed at the bottom. `value` is what the copy chip and Ctrl+C hand over, never the wrapped lines.
--
-- Where it opens: beside the page the first record of all was read from, and from then on wherever
-- the player last left it (ISLayoutManager keeps the position; the size follows the content).
-- Only a screen that shrank moves it, and then just far enough to be visible again.
--
-- What it deliberately is not:
--   * not always on top -- it is an ordinary top level window and it may be covered
--   * not collapsible -- it is read while the cursor stays on the row it was opened from, and
--     vanilla collapses an unpinned window exactly then, so the title-bar pair that arms that is
--     removed in createChildren and the record stays whole from the click that opened it
--   * not a second keyboard engine -- C.Keyboard owns the ring here exactly like in the other
--     two windows
--
-- Everything is measured once per content or width change (Win:layout); prerender/render only
-- walk the prepared draw lists and allocate nothing.
--
-- Engine references (snapshot 42.20.4-20260826):
--   top-level keys      UIManager.java:1435-1466 -- visible + isWantKeyEvents, last added asked
--                       first. Focusing this window makes it the root C.Keyboard answers for, so
--                       Escape closes this window instead of leaking into the one behind it.
--   onFocus order       UIElement.java:1056-1065 -- onFocus runs before the press reaches a child
--   mouse down          UIElement.java:1068-1083 -- a child that answers false lets the press reach
--                       the window, so dragging the card body moves the window
--   render order        UIElement.java:1626-1634 -- children paint between prerender and render,
--                       so the focus ring is painted last (Keys.render)
--   DrawLine            UIElement.java:509-514 -- element-relative coordinates
--   mouse-out collapse  UIManager.java:794-806 -- every visible top level window the cursor is
--                       not over is given onMouseMoveOutside on each move, which is what
--                       ISCollapsableWindow.lua:228-247 counts towards collapsing

require "ISUI/ISCollapsableWindow"
require "ISUI/ISLayoutManager"
require "ISUI/ISButton"
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
C.DetailWindow = D

local PAD, T = U.PAD, U.T
local fontH = U.fontH
local color, fill, text, textWidth, fitText, wrapText = U.color, U.fill, U.text, U.textWidth, U.fitText, U.wrapText
local Button = U.Button

-- 400 px at the small font the design was drawn for, scaled with the player's font size.
-- ponytail: FONT_REF is a calibration knob (px of UIFont.Small at the reference size).
local WIDTH_BASE, WIDTH_MIN, WIDTH_MAX, FONT_REF = 400, 360, 560, 16
local MAX_SCREEN_H = 0.7
-- How far the parent chain is walked when a window is asked whether it belongs to an owner. The
-- same bound C.Keyboard uses to find a root.
local OWNER_DEPTH = 32
-- the breathing room between the owner's window and this one
local GAP = 8
-- An ISLayoutManager name of its own: this window keeps a position independent of the two big
-- windows, and keeps it across a close and a reopen.
local LAYOUT_NAME = "MinidoracatEconomyDetailWindow"
local ICON_BOX, METER_H, ROW_COIN, CHEVRON = 44, 8, 16, 12
local DIVIDER = { r = 1, g = 1, b = 1, a = 0.08 }
local EMPTY = {}

-- draw-list op kinds
local K_TEXT, K_RECT, K_FILL, K_TEX, K_ICON, K_COIN, K_PILL, K_MARK = 1, 2, 3, 4, 5, 6, 7, 8

local function tr(key) return getText(T .. key) end
local function chipH() return math.max(22, fontH.small + 8) end
local function lineH() return fontH.small + 3 end
local function blank(s) return s == nil or tostring(s) == "" end
local function hasRows(t) return type(t) == "table" and #t > 0 end
local function validCoin(id)
    if type(id) == "string" and EC.CURRENCIES[id] ~= nil then return id end
    return nil
end

-- A card button's enabled state: a boolean (absent = enabled) or a function asked now.
local function actionEnabled(a)
    local en = a.enabled
    if type(en) == "function" then
        local ok, v = pcall(en)
        return ok and v == true
    end
    return en ~= false
end
local function iconsLib() return U.framework and U.framework.Icons or nil end

local function cardWidth(sw)
    local w = math.floor(WIDTH_BASE * fontH.small / FONT_REF)
    return math.min(sw, math.max(WIDTH_MIN, math.min(WIDTH_MAX, w)))
end

-- Is this element still a live part of the screen? A page that switched tab, a window that was
-- hidden and a panel that lost the admin right all answer false here, and that is what closes the
-- window without the owner having to notice.
local function alive(el)
    if type(el) ~= "table" then return false end
    if el.javaObject == nil then return false end
    if el.getIsVisible and not el:getIsVisible() then return false end
    if el.isReallyVisible and not el:isReallyVisible() then return false end
    return true
end

-- Does `el` belong to `owner` -- is it the owner itself or one of its descendants? The admin
-- window closes the windows of every page inside it with one call this way.
local function ownedBy(el, owner)
    if owner == nil then return false end
    for _ = 1, OWNER_DEPTH do
        if type(el) ~= "table" then return false end
        if el == owner then return true end
        el = el.parent
    end
    return false
end

-- ---------- measuring (layout time only) ----------

local function push(ops, op)
    ops[#ops + 1] = op
    return op
end

local function opText(ops, s, x, y, tok, font, h)
    return push(ops, { k = K_TEXT, s = s, x = x, y = y, h = h or fontH.small, tok = tok or "text",
        font = font or UIFont.Small })
end

local function opRight(ops, s, right, y, tok, font, h)
    return opText(ops, s, right - textWidth(s, font), y, tok, font, h)
end

-- Every "\n" breaks, every line wraps (U.wrapText measures the small font); "" marks a blank line.
local function wrapAll(s, w, out)
    out = out or {}
    w = math.max(20, w)
    local str = string.gsub(tostring(s or ""), "\r\n", "\n")
    for line in (str .. "\n"):gmatch("(.-)\n") do
        if line == "" then
            out[#out + 1] = ""
        else
            local parts = wrapText(line, w, math.huge)
            for i = 1, #parts do out[#out + 1] = parts[i] end
        end
    end
    return out
end

-- A larger font wraps at the width scaled by how much wider this very string is in it.
local function wrapFont(s, w, font)
    if font == nil or font == UIFont.Small then return wrapAll(s, w) end
    local str = tostring(s or "")
    local small = textWidth(str)
    local ratio = small > 0 and textWidth(str, font) / small or 1
    return wrapAll(str, math.floor(w / math.max(1, ratio) * 0.97))
end

-- At most n lines; the last one says that more was cut.
local function clampLines(lines, n, w)
    if #lines <= n then return lines end
    lines[n] = fitText(lines[n] .. " " .. lines[n + 1] .. "...", w)
    for i = #lines, n + 1, -1 do lines[i] = nil end
    return lines
end

-- a 1px divider over the full width, unless the block is the first one
local function startBlock(b, y, top)
    if y > 0 then push(b.ops, { k = K_RECT, x = 0, y = y, w = b.full, h = 1, c = DIVIDER, chrome = true }) end
    return y + top
end

local function buildHeader(b, card, y)
    local Icons = iconsLib()
    local tex = U.itemTexture(card.item)
    local iconKey = (not tex and Icons ~= nil and Icons.get(card.iconKey) ~= nil) and card.iconKey or nil
    local coin = (not tex and iconKey == nil) and validCoin(card.coin) or nil
    local hasIcon = tex or iconKey ~= nil or coin ~= nil
    if not hasIcon and blank(card.name) and blank(card.sub) then return y end
    local ops = b.ops
    y = y + 12
    local tx, tw = b.x, b.w
    if hasIcon then
        push(ops, { k = K_FILL, x = b.x, y = y, w = ICON_BOX, h = ICON_BOX, tok = "card" })
        if tex then
            push(ops, { k = K_TEX, tex = tex, x = b.x + 5, y = y + 5, w = ICON_BOX - 10, h = ICON_BOX - 10 })
        elseif iconKey ~= nil then
            push(ops, { k = K_ICON, name = iconKey, x = b.x + 9, y = y + 9, w = ICON_BOX - 18, h = ICON_BOX - 18,
                tok = "text" })
        else
            push(ops, { k = K_COIN, coin = coin, x = b.x + 7, y = y + 7, w = ICON_BOX - 14, h = ICON_BOX - 14 })
        end
        tx, tw = b.x + ICON_BOX + 12, b.w - ICON_BOX - 12
    end
    local names = blank(card.name) and EMPTY or wrapFont(card.name, tw, UIFont.Medium)
    local subs = blank(card.sub) and EMPTY or clampLines(wrapAll(card.sub, tw), 2, tw)
    local textH = #names * (fontH.medium + 1) + (#subs > 0 and (2 + #subs * b.lh) or 0)
    local boxH = hasIcon and ICON_BOX or 0
    local ty = y + math.max(0, math.floor((boxH - textH) / 2))
    for i = 1, #names do
        opText(ops, names[i], tx, ty, "text", UIFont.Medium, fontH.medium)
        ty = ty + fontH.medium + 1
    end
    if #subs > 0 then ty = ty + 2 end
    for i = 1, #subs do
        opText(ops, subs[i], tx, ty, "textMuted")
        ty = ty + b.lh
    end
    return y + math.max(boxH, textH) + 4
end

local function buildHero(b, hero, y)
    if type(hero) ~= "table" or blank(hero.value) then return y end
    local ops = b.ops
    local lgH = b.largeH
    local tok = hero.token or "text"
    local right = b.x + b.w
    y = y + (y == 0 and 12 or 4)
    local x = b.x
    local coin = validCoin(hero.coin)
    if coin ~= nil then
        push(ops, { k = K_COIN, coin = coin, x = x, y = y + math.floor((lgH - U.COIN_SMALL) / 2),
            w = U.COIN_SMALL, h = U.COIN_SMALL })
        x = x + U.COIN_SMALL + 6
    end
    local value = tostring(hero.value)
    local lines = textWidth(value, UIFont.Large) <= right - x and { value } or wrapFont(value, right - x, UIFont.Large)
    local vy = y
    for i = 1, #lines do
        opText(ops, lines[i], x, vy, tok, UIFont.Large, lgH)
        if hero.strike then
            push(ops, { k = K_RECT, x = x, y = vy + math.floor(lgH / 2), w = textWidth(lines[i], UIFont.Large),
                h = 2, tok = tok })
        end
        vy = vy + lgH
    end
    if not blank(hero.unit) then
        local unit = tostring(hero.unit)
        local ux = x + textWidth(lines[#lines], UIFont.Large) + 8
        if ux + textWidth(unit) <= right then
            opText(ops, unit, ux, vy - lgH + math.floor((lgH - fontH.small) / 2), "textMuted")
        else
            local units = wrapAll(unit, b.w)
            for i = 1, #units do
                opText(ops, units[i], b.x, vy, "textMuted")
                vy = vy + b.lh
            end
        end
    end
    return vy + 8
end

local function buildChips(b, chips, y)
    if not hasRows(chips) then return y end
    local h = U.CHIP_H
    local right = b.x + b.w
    y = y + (y == 0 and 10 or 0)
    local x = b.x
    for i = 1, #chips do
        local c = chips[i]
        if type(c) == "table" then
            local label = not blank(c.label) and tostring(c.label) or nil
            local value = c.value ~= nil and tostring(c.value) or ""
            local coin = validCoin(c.coin)
            local dot = c.dot == true
            local pw = U.pillWidth(label, value, coin, dot)
            if x > b.x and x + pw > right then
                x = b.x
                y = y + h + 6
            end
            push(b.ops, { k = K_PILL, x = x, y = y, w = pw, h = h, label = label, value = value,
                tok = c.token or "text", coin = coin, dot = dot })
            x = x + pw + 6
        end
    end
    return y + h + 10
end

local function buildMeters(b, meters, y)
    if not hasRows(meters) then return y end
    local ops = b.ops
    local labelW, valueW = 0, 0
    for i = 1, #meters do
        local m = meters[i]
        if type(m) == "table" then
            labelW = math.max(labelW, textWidth(tostring(m.label or "")))
            valueW = math.max(valueW, textWidth(tostring(m.value or "")))
        end
    end
    labelW = math.min(labelW, math.floor(b.w * 0.4))
    valueW = math.min(valueW, math.floor(b.w * 0.3))
    local right = b.x + b.w
    local trackX = b.x + labelW + (labelW > 0 and 10 or 0)
    local trackW = math.max(20, right - (valueW > 0 and valueW + 10 or 0) - trackX)
    y = startBlock(b, y, 9)
    for i = 1, #meters do
        local m = meters[i]
        if type(m) == "table" then
            if labelW > 0 then opText(ops, fitText(tostring(m.label or ""), labelW), b.x, y, "textMuted") end
            local ty = y + math.floor((fontH.small - METER_H) / 2)
            push(ops, { k = K_FILL, x = trackX, y = ty, w = trackW, h = METER_H, tok = "track" })
            local frac = math.max(0, math.min(1, tonumber(m.frac) or 0))
            local fw = math.floor(trackW * frac + 0.5)
            if fw > 0 then
                push(ops, { k = K_RECT, x = trackX, y = ty, w = fw, h = METER_H, tok = m.token or "positive" })
            end
            if valueW > 0 then opRight(ops, fitText(tostring(m.value or ""), valueW), right, y, "text") end
            y = y + fontH.small + 8
        end
    end
    return y + 1
end

-- A fact's value, right-aligned: on one line with its coin and note when they fit, else the value
-- wrapped (coin before its first line) and the note on the lines under it.
local function buildFactValue(b, r, y, vw)
    local ops = b.ops
    local right = b.x + b.w
    local value = tostring(r.value or "")
    local note = not blank(r.note) and tostring(r.note) or nil
    local coin = validCoin(r.coin)
    local coinW = coin ~= nil and ROW_COIN + 4 or 0
    local tok = r.token or "text"
    local valW = textWidth(value)
    local noteW = note ~= nil and textWidth(note) + 4 or 0
    local coinY = math.floor((fontH.small - ROW_COIN) / 2)
    if coinW + valW + noteW <= vw then
        local x = right - noteW - valW
        if note ~= nil then opText(ops, note, right - noteW + 4, y, "textMuted") end
        opText(ops, value, x, y, tok)
        if coin ~= nil then push(ops, { k = K_COIN, coin = coin, x = x - coinW, y = y + coinY, w = ROW_COIN, h = ROW_COIN }) end
        return y + b.lh
    end
    local lines = wrapAll(value, vw - coinW)
    for i = 1, #lines do
        local x = right - textWidth(lines[i])
        opText(ops, lines[i], x, y, tok)
        if i == 1 and coin ~= nil then
            push(ops, { k = K_COIN, coin = coin, x = x - coinW, y = y + coinY, w = ROW_COIN, h = ROW_COIN })
        end
        y = y + b.lh
    end
    if note ~= nil then
        local notes = wrapAll(note, vw)
        for i = 1, #notes do
            opRight(ops, notes[i], right, y, "textMuted")
            y = y + b.lh
        end
    end
    return y
end

local function buildRows(b, rows, y)
    if not hasRows(rows) then return y end
    local labelW = 0
    for i = 1, #rows do
        if type(rows[i]) == "table" then labelW = math.max(labelW, textWidth(tostring(rows[i].label or ""))) end
    end
    labelW = math.min(labelW, math.floor(b.w * 0.45))
    local vw = b.w - labelW - (labelW > 0 and 14 or 0)
    y = startBlock(b, y, 9)
    for i = 1, #rows do
        local r = rows[i]
        if type(r) == "table" then
            local ly = y
            if labelW > 0 then
                local labels = wrapAll(r.label, labelW)
                for j = 1, #labels do
                    opText(b.ops, labels[j], b.x, ly, "textMuted")
                    ly = ly + b.lh
                end
            end
            y = math.max(ly, buildFactValue(b, r, y, vw)) + 2
        end
    end
    return y + 8
end

local function buildFlow(b, flow, y)
    if not hasRows(flow) then return y end
    local ops = b.ops
    local deltaW, noteW = 0, 0
    for i = 1, #flow do
        local f = flow[i]
        if type(f) == "table" then
            deltaW = math.max(deltaW, textWidth(tostring(f.delta or "")))
            noteW = math.max(noteW, textWidth(tostring(f.note or "")))
        end
    end
    noteW = math.min(noteW, math.floor(b.w * 0.4))
    local right = b.x + b.w
    local deltaRight = noteW > 0 and right - noteW - 12 or right
    local nameW = math.max(40, deltaRight - deltaW - 12 - b.x)
    y = startBlock(b, y, 8)
    for i = 1, #flow do
        local f = flow[i]
        if type(f) == "table" then
            local names = wrapAll(f.name, nameW)
            local ny = y
            for j = 1, #names do
                opText(ops, names[j], b.x, ny, "text")
                ny = ny + b.lh
            end
            if not blank(f.role) then
                local role = tostring(f.role)
                local rx = b.x + textWidth(names[#names]) + 6
                if rx + textWidth(role) <= b.x + nameW then
                    opText(ops, role, rx, ny - b.lh, "textMuted")
                else
                    local roles = wrapAll(role, nameW)
                    for j = 1, #roles do
                        opText(ops, roles[j], b.x, ny, "textMuted")
                        ny = ny + b.lh
                    end
                end
            end
            if not blank(f.delta) then opRight(ops, tostring(f.delta), deltaRight, y, f.token or "text") end
            local vy = y + b.lh
            if not blank(f.note) and noteW > 0 then
                local notes = wrapAll(f.note, noteW)
                for j = 1, #notes do opRight(ops, notes[j], right, y + (j - 1) * b.lh, "textMuted") end
                vy = math.max(vy, y + #notes * b.lh)
            end
            y = math.max(ny, vy) + 5
        end
    end
    return y + 5
end

-- a section line's pill: a plain word, or { label, value, token, dot, coin }
local function pillParts(p)
    if type(p) == "table" then
        return not blank(p.label) and tostring(p.label) or nil, tostring(p.value or ""), p.token or "text",
            p.dot == true, validCoin(p.coin)
    end
    return nil, tostring(p), "text", false, nil
end

local function markSize() return math.max(10, math.min(14, fontH.small - 2)) end

local function buildLine(b, ln, y, tx, tw)
    local ops = b.ops
    local ty, pillH = y, 0
    if ln.pill ~= nil then
        local label, value, tok, dot, coin = pillParts(ln.pill)
        push(ops, { k = K_PILL, x = b.x, y = y, w = U.pillWidth(label, value, coin, dot), h = U.CHIP_H,
            label = label, value = value, tok = tok, coin = coin, dot = dot })
        pillH = U.CHIP_H
        ty = y + math.floor((U.CHIP_H - fontH.small) / 2)
    elseif ln.mark == "ok" or ln.mark == "no" then
        local s = markSize()
        push(ops, { k = K_MARK, x = b.x, y = y + math.floor((fontH.small - s) / 2), w = s, h = s, ok = ln.mark == "ok" })
    end
    local top = y
    if not blank(ln.text) then
        local lines = wrapAll(ln.text, tw)
        for i = 1, #lines do
            opText(ops, lines[i], tx, ty, ln.token or "text")
            ty = ty + b.lh
        end
    end
    if not blank(ln.note) then
        local notes = wrapAll(ln.note, tw)
        for i = 1, #notes do
            opText(ops, notes[i], tx, ty, "textMuted")
            ty = ty + b.lh
        end
    end
    return math.max(top + pillH, ty)
end

local function buildSection(b, s, y)
    y = startBlock(b, y, 10)
    if not blank(s.title) then
        local titles = wrapAll(s.title, b.w)
        for i = 1, #titles do
            opText(b.ops, titles[i], b.x, y, "text")
            y = y + b.lh
        end
        y = y + 4
    end
    local lines = s.lines
    if hasRows(lines) then
        local col1 = 0
        for i = 1, #lines do
            local ln = lines[i]
            if type(ln) == "table" then
                if ln.pill ~= nil then
                    local label, value, _, dot, coin = pillParts(ln.pill)
                    col1 = math.max(col1, U.pillWidth(label, value, coin, dot))
                elseif ln.mark == "ok" or ln.mark == "no" then
                    col1 = math.max(col1, markSize())
                end
            end
        end
        local tx = b.x + (col1 > 0 and col1 + 10 or 0)
        local tw = b.x + b.w - tx
        for i = 1, #lines do
            if type(lines[i]) == "table" then y = buildLine(b, lines[i], y, tx, tw) + 4 end
        end
    end
    return y + 6
end

local function buildText(b, s, y)
    if blank(s) then return y end
    y = startBlock(b, y, 10)
    local lines = wrapAll(s, b.w)
    for i = 1, #lines do
        if lines[i] == "" then
            y = y + math.floor(b.lh / 2)
        else
            opText(b.ops, lines[i], b.x, y, "text")
            y = y + b.lh
        end
    end
    return y + 10
end

-- ---------- painting (no allocation) ----------

local function drawMark(el, x, y, s, ok)
    local c = color(ok and "positive" or "negative")
    if ok then
        local mx = x + math.floor(s * 0.38)
        el:drawLine(nil, x, y + math.floor(s * 0.55), mx, y + s - 1, 2, c.a, c.r, c.g, c.b)
        el:drawLine(nil, mx, y + s - 1, x + s, y + 1, 2, c.a, c.r, c.g, c.b)
    else
        el:drawLine(nil, x + 1, y + 1, x + s - 1, y + s - 1, 2, c.a, c.r, c.g, c.b)
        el:drawLine(nil, x + s - 1, y + 1, x + 1, y + s - 1, 2, c.a, c.r, c.g, c.b)
    end
end

-- Paints a prepared list shifted by dy, skipping what falls outside [top, bottom].
local function paintOps(el, ops, dy, top, bottom)
    if ops == nil then return end
    local Icons = iconsLib()
    for i = 1, #ops do
        local o = ops[i]
        local y = o.y + dy
        if y + o.h >= top and y <= bottom then
            local k = o.k
            if k == K_TEXT then
                text(el, o.s, o.x, y, o.tok, o.font)
            elseif k == K_RECT then
                local c = o.c or color(o.tok)
                el:drawRect(o.x, y, o.w, o.h, c.a * (o.chrome and U.alpha or 1), c.r, c.g, c.b)
            elseif k == K_FILL then
                fill(el, o.x, y, o.w, o.h, o.tok)
            elseif k == K_TEX then
                el:drawTextureScaled(o.tex, o.x, y, o.w, o.h, 1, 1, 1, 1)
            elseif k == K_ICON then
                if Icons ~= nil then Icons.draw(el, o.name, o.x, y, o.w, color(o.tok), 1) end
            elseif k == K_COIN then
                U.drawCoin(el, o.coin, o.x, y, o.w)
            elseif k == K_PILL then
                U.drawPill(el, o.x, y, o.label, o.value, o.tok, o.coin, o.dot)
            elseif k == K_MARK then
                drawMark(el, o.x, y, o.w, o.ok)
            end
        end
    end
end

-- ---------- the scrolling card body ----------

-- Answers the keyboard's scroll contract (scrollOffset / setScrollOffset / maxScrollOffset,
-- MinidoracatUI/Focus.lua scrollBy), so a kind = "scroll" target scrolls it with no help.
local Body = ISPanel:derive("MinidoracatEconomyDetailBody")

function Body:maxScrollOffset()
    return math.max(0, (self.contentH or 0) - self.height)
end

function Body:setScrollOffset(offset)
    self.scrollOffset = math.max(0, math.min(math.floor(offset), self:maxScrollOffset()))
end

function Body:onMouseWheel(del)
    if self:maxScrollOffset() <= 0 then return false end
    self:setScrollOffset((self.scrollOffset or 0) + del * lineH() * 3)
    return true
end

-- not consumed: the press reaches the window, which drags (see the header)
function Body:onMouseDown() return false end

function Body:prerender()
    local w, h = self.width, self.height
    self:setStencilRect(0, 0, w, h)
    local off = self.scrollOffset or 0
    paintOps(self, self.ops, -off, 0, h)
    local max = self:maxScrollOffset()
    if max > 0 then
        local thumbH = math.max(16, math.floor(h * h / self.contentH))
        local c = color("textFaint")
        self:drawRect(w - 4, math.floor((h - thumbH) * off / max), 3, thumbH, c.a * 0.6, c.r, c.g, c.b)
    end
end

-- The stencil is restored to the window's level, so a modal drawn over this region later is not
-- clipped by the depth left behind (same reason as ISComboBox doRepaintStencil).
function Body:render()
    self:clearStencilRect()
    self:repaintStencilRect(0, 0, self.width, self.height)
end

-- ---------- the technical-info toggle ----------

local Toggle = ISButton:derive("MinidoracatEconomyDetailTechToggle")

function Toggle:prerender() end

function Toggle:render()
    local hot = self:isMouseOver()
    local c = color(hot and "text" or "textFaint")
    local iy = math.floor((self.height - CHEVRON) / 2)
    local Icons = iconsLib()
    if not (Icons ~= nil and Icons.draw(self, self.open and "chevronDown" or "chevronRight", 0, iy, CHEVRON, c, 1)) then
        if self.open then
            U.Skin.arrow(self, 2, iy + 4, false, c)
        else
            for i = 0, 3 do self:drawRect(4 + i, iy + 2 + i, 1, 7 - i * 2, c.a, c.r, c.g, c.b) end
        end
    end
    text(self, self.label or "", CHEVRON + 6, math.floor((self.height - fontH.small) / 2), hot and "text" or "textFaint")
end

-- ---------- the window ----------

local Win = ISCollapsableWindow:derive("MinidoracatEconomyDetailWindow")

function Win:titleBarHeight()
    return math.max(26, fontH.medium + 8)
end

function Win:createChildren()
    ISCollapsableWindow.createChildren(self)
    -- Keep details expanded while the cursor remains on the source row.
    -- Remove the pin/collapse controls so the shared window cannot retain an unpinned state.
    self.pin = true
    self:removeChild(self.collapseButton)
    self:removeChild(self.pinButton)
    self.collapseButton, self.pinButton = nil, nil
    -- the admin window's chrome painter, when that file is loaded: the same close glyph both
    -- other windows wear. Never required from here -- ECAdminWindow requires the pages that
    -- require this file.
    local AW = C.AdminWindow
    if AW ~= nil and AW.iconButton ~= nil then
        AW.iconButton(self.closeButton, "close")
    end
    self.closeButton.fullTitle = tr("Detail_Close")
    self.closeButton.tooltip = self.closeButton.fullTitle

    local body = ISPanel.new(Body, 0, 0, 10, 10)
    body.background = false
    body.scrollOffset = 0
    body:initialise()
    self:addChild(body)
    self.body = body

    local ch = chipH()
    local copy = tr("Detail_Copy")
    self.copyButton = Button.create(0, 0, textWidth(copy) + 24, ch, copy, self, Win.onCopyAll, "chip")
    self:addChild(self.copyButton)

    local toggle = ISButton:new(0, 0, 10, ch, "", self, Win.onTechToggle)
    setmetatable(toggle, Toggle)
    toggle.label = tr("Detail_Tech")
    toggle:initialise()
    self:addChild(toggle)
    self.techToggle = toggle

    self.actionButtons = {}
    self.kbList = {}
end

-- ----- content -----

local function closeNow(win)
    if win == nil or win.closing == true then return end
    local owner, callback = win.detailOwner, win.onDetailClose
    win.closing = true
    win.detailOwner, win.detailKey, win.onDetailClose = nil, nil, nil
    win.rawText, win.detailTitle, win.copyNote, win.card = nil, nil, nil, nil
    for _, b in ipairs(win.actionButtons or EMPTY) do b.cardAction = nil end
    if win:getIsVisible() then win:setVisible(false) end
    win.closing = false
    -- the owner is told after the window is already closed, so a callback that asks D.isOpen
    -- reads the state it is being told about. It is a notification only: the list keeps its
    -- selection unless the owner itself decides otherwise.
    if callback ~= nil then pcall(callback, owner) end
end

-- reset: a new record (another key or owner, or a closed window) starts at the top with the
-- technical info as the card asks; an update keeps the scroll and the player's toggle.
local function setContent(win, title, value, card, reset)
    local heading = (type(title) == "string" and title ~= "") and title or tr("Detail_Title")
    card = type(card) == "table" and card or nil
    local raw = type(value) == "string" and value or ""
    if raw == "" and card == nil then raw = tr("Detail_Loading") end
    -- an owner that re-states what is already on screen costs one comparison, not a re-measure
    if not reset and card == win.card and win.rawText == raw and win.detailTitle == heading then return end
    win.detailTitle, win.rawText, win.card = heading, raw, card
    win.copyNote = nil
    if reset then
        win.body.scrollOffset = 0
        win.techOpen = card ~= nil and card.techOpen == true
    end
    win.bodyDirty = true
    win:layout()
end

function Win:onCopyAll()
    local value = self.rawText
    if type(value) ~= "string" or value == "" then return end
    if not (Clipboard and Clipboard.setClipboard) then
        self.copyNote = tr("Admin_Sys_CopyFailed")
    else
        local ok = pcall(Clipboard.setClipboard, value)
        local name = self.card ~= nil and not blank(self.card.name) and tostring(self.card.name) or self.detailTitle
        self.copyNote = ok and getText(T .. "Admin_Audit_Copied", name or tr("Detail_Title")) or tr("Admin_Sys_CopyFailed")
    end
    self:layout()
end

function Win:onTechToggle()
    self.techOpen = not self.techOpen
    self:layout()
end

-- The window never validates: the source finds its current row again inside run().
function Win:onAction(button)
    local a = button ~= nil and button.cardAction or nil
    if type(a) ~= "table" or type(a.run) ~= "function" then return end
    local ok, err = pcall(a.run)
    if not ok then EC.log("detail card action " .. tostring(a.id) .. " failed: " .. tostring(err)) end
end

-- The title bar's own close button lands here (ISCollapsableWindow:close).
function Win:close()
    closeNow(self)
end

-- ----- geometry -----

-- Inside the screen: a resolution change or a window-mode switch must not leave the window half
-- off the desktop. Every write is guarded, so a window already in place costs four comparisons.
function Win:clampToScreen()
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    if self.width > sw then self:setWidth(sw) end
    if self.height > sh then self:setHeight(sh) end
    local x = math.max(0, math.min(self.x, sw - self.width))
    local y = math.max(0, math.min(self.y, sh - self.height))
    if x ~= self.x then self:setX(x) end
    if y ~= self.y then self:setY(y) end
end

function Win:measureBody(width)
    local b = { ops = {}, x = PAD, w = width - PAD * 2, full = width, lh = lineH(),
        largeH = getTextManager():getFontHeight(UIFont.Large) }
    local card = self.card
    local y = 0
    if card ~= nil then
        y = buildHeader(b, card, y)
        y = buildHero(b, card.hero, y)
        y = buildChips(b, card.chips, y)
        y = buildMeters(b, card.meters, y)
        y = buildRows(b, card.rows, y)
        y = buildFlow(b, card.flow, y)
        for _, s in ipairs(type(card.sections) == "table" and card.sections or EMPTY) do
            if type(s) == "table" then y = buildSection(b, s, y) end
        end
        y = buildText(b, card.text, y)
    end
    -- no card, or a card with nothing in its middle: the copy value is the body
    if y == 0 then y = buildText(b, self.rawText, y) end
    self.body.ops, self.body.contentH = b.ops, y
end

-- One action button, reused across records; a pool button is never rebuilt.
function Win:actionButton(i, a)
    local b = self.actionButtons[i]
    if b == nil then
        b = Button.create(0, 0, 10, chipH(), "", self, Win.onAction, "chip")
        self:addChild(b)
        self.actionButtons[i] = b
    end
    local style = (a.style == "primary" or a.style == "danger") and a.style or "chip"
    b.style = style
    b.coinId = style == "primary" and validCoin(a.coin) or nil
    b.cardAction = a
    b:setEnable(actionEnabled(a))
    b.tooltip, b.autoTooltip = a.tooltip, nil
    local label = tostring(a.label or "")
    return b, label, textWidth(label) + 24 + (b.coinId ~= nil and U.COIN_SMALL + 6 or 0)
end

local function shiftRow(pool, from, to, dx)
    for i = from, to do pool[i].relX = pool[i].relX + dx end
end

-- The action rows, wrapped; right-aligned unless the card asks for the left. Returns the y under
-- them and how many buttons are in use.
function Win:layoutActions(ops, y, w)
    local card = self.card
    local acts = card ~= nil and card.actions or nil
    local pool = self.actionButtons
    local n = 0
    if hasRows(acts) then
        if y == 0 then push(ops, { k = K_RECT, x = 0, y = 0, w = w + PAD * 2, h = 1, c = DIVIDER, chrome = true }) end
        y = y + 10
        local ch = chipH()
        local left = card.actionsLeft == true
        local x, rowFrom = 0, 1
        for i = 1, #acts do
            if type(acts[i]) == "table" then
                n = n + 1
                local b, label, want = self:actionButton(n, acts[i])
                local bw = math.min(w, want)
                b:setWidth(bw)
                b:setHeight(ch)
                U.setButtonTitle(b, label)
                b:setVisible(true)
                if x > 0 and x + bw > w then
                    if not left then shiftRow(pool, rowFrom, n - 1, w - (x - 8)) end
                    x, rowFrom = 0, n
                    y = y + ch + 6
                end
                b.relX, b.relY = x, y
                x = x + bw + 8
            end
        end
        if n > 0 and not left then shiftRow(pool, rowFrom, n, w - (x - 8)) end
        y = y + ch + 10
    end
    for i = n + 1, #pool do
        pool[i]:setVisible(false)
        pool[i].cardAction = nil
    end
    return y, n
end

-- The technical-info row: toggle, a hint (or the copy result) on the right, the copy chip; the
-- label / value lines under it when open.
function Win:layoutTech(ops, y, w)
    local card = self.card
    local tech = card ~= nil and card.tech or nil
    local hasTech = hasRows(tech)
    local open = hasTech and self.techOpen == true
    local ch = chipH()
    if y > 0 or (self.body.contentH or 0) > 0 then
        push(ops, { k = K_RECT, x = 0, y = y, w = w + PAD * 2, h = 1, c = DIVIDER, chrome = true })
    end
    y = y + 6
    local toggle, copy = self.techToggle, self.copyButton
    toggle:setVisible(hasTech)
    toggle.open = open
    local toggleW = CHEVRON + 6 + textWidth(toggle.label) + 6
    toggle:setWidth(toggleW)
    toggle:setHeight(ch)
    toggle.relX, toggle.relY = 0, y
    local copyW = math.min(textWidth(copy.fullTitle) + 24, math.floor(w / 3))
    copy:setWidth(copyW)
    copy:setHeight(ch)
    U.setButtonTitle(copy, copy.fullTitle)
    copy:setEnable(self.rawText ~= nil and self.rawText ~= "")
    copy.relX, copy.relY = w - copyW, y
    local hint, hintTok = self.copyNote, "textMuted"
    if hint == nil and not open and card ~= nil and not blank(card.techHint) then
        hint, hintTok = tostring(card.techHint), "textFaint"
    end
    if hint ~= nil then
        local from = hasTech and toggleW + 10 or 0
        local shown = fitText(hint, math.max(0, w - copyW - 10 - from))
        if shown ~= "" then opRight(ops, shown, PAD + w - copyW - 10, y + math.floor((ch - fontH.small) / 2), hintTok) end
    end
    y = y + ch + 6
    if not open then return y end
    local labelW = 0
    for i = 1, #tech do
        if type(tech[i]) == "table" then labelW = math.max(labelW, textWidth(tostring(tech[i].label or ""))) end
    end
    labelW = math.min(labelW, math.floor(w * 0.4))
    local vx = PAD + labelW + 12
    local lh = lineH()
    for i = 1, #tech do
        local t = tech[i]
        if type(t) == "table" then
            local labels = wrapAll(t.label, labelW)
            local values = wrapAll(t.value, w - labelW - 12)
            for j = 1, #labels do opText(ops, labels[j], PAD, y + (j - 1) * lh, "textFaint") end
            for j = 1, #values do opText(ops, values[j], vx, y + (j - 1) * lh, "textMuted") end
            y = y + math.max(#labels, #values) * lh + 3
        end
    end
    return y + 6
end

-- Fixed bottom (note, actions, technical info), measured relative to its own top. Returns its
-- height and how many action buttons are in use.
function Win:layoutFooter(width)
    local ops = {}
    local w = width - PAD * 2
    local card = self.card
    local y = 0
    if card ~= nil and not blank(card.note) then
        push(ops, { k = K_RECT, x = 0, y = 0, w = width, h = 1, c = DIVIDER, chrome = true })
        y = 8
        local notes = wrapAll(card.note, w)
        for i = 1, #notes do
            opText(ops, notes[i], PAD, y, "textMuted")
            y = y + lineH()
        end
    end
    local n
    y, n = self:layoutActions(ops, y, w)
    y = self:layoutTech(ops, y, w)
    self.footerOps = ops
    return y, n
end

-- Keyboard order: actions -> technical info -> copy -> the card body -> close. Built here, never
-- per frame: Focus.render asks for the list every frame.
function Win:buildTargets(n)
    local list = {}
    local label = self.detailTitle or tr("Detail_Title")
    if n > 0 then
        local controls = {}
        for i = 1, n do controls[i] = self.actionButtons[i] end
        list[#list + 1] = { kind = "group", label = label, controls = controls }
    end
    if self.techToggle:getIsVisible() then
        list[#list + 1] = { kind = "button", control = self.techToggle, label = self.techToggle.label }
    end
    list[#list + 1] = { kind = "button", control = self.copyButton, label = self.copyButton.fullTitle }
    -- focusable = false: the engine's text focus would swallow every key and handle none. Ctrl+C
    -- over it presses the copy chip, so there is one copy path.
    list[#list + 1] = { kind = "scroll", control = self.body, label = label, focusable = false,
        copyAll = self.copyButton }
    list[#list + 1] = { kind = "button", control = self.closeButton, label = self.closeButton.fullTitle }
    self.kbList = list
end

function Win:layoutTitle(width, th)
    local card = self.card
    local Icons = iconsLib()
    local source = card ~= nil and not blank(card.source) and tostring(card.source) or (self.detailTitle or tr("Detail_Title"))
    local size = math.min(16, fontH.small)
    local icon = card ~= nil and Icons ~= nil and Icons.get(card.sourceIcon) ~= nil and card.sourceIcon or nil
    self.titleIcon, self.titleIconSize = icon, size
    self.titleIconX, self.titleIconY = th + 2, math.floor((th - size) / 2)
    self.titleX = th + 2 + (icon ~= nil and size + 6 or 0)
    self.titleY = math.floor((th - fontH.small) / 2)
    self.titleShown = fitText(source, math.max(0, width - self.titleX - PAD))
end

-- Size follows content: width from the font, the body as tall as it needs up to 70 % of the
-- screen with the fixed bottom always whole. The top-left corner stays where it is.
function Win:layout()
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    local width = cardWidth(sw)
    if self.bodyDirty or self.layoutW ~= width then
        self:measureBody(width)
        self.bodyDirty = false
    end
    local footerH, n = self:layoutFooter(width)
    local th = self:titleBarHeight()
    local contentH = self.body.contentH or 0
    local room = math.floor(sh * MAX_SCREEN_H) - th - footerH
    local bodyH = math.max(math.min(contentH, fontH.small * 4), math.min(contentH, room))
    if self.width ~= width then self:setWidth(width) end
    local h = th + bodyH + footerH
    if self.height ~= h then self:setHeight(h) end
    local body = self.body
    body:setX(0)
    body:setY(th)
    body:setWidth(width)
    body:setHeight(bodyH)
    body:setVisible(bodyH > 0)
    body:setScrollOffset(body.scrollOffset or 0)
    local footerY = th + bodyH
    self.footerY = footerY
    for i = 1, n do
        local b = self.actionButtons[i]
        b:setX(PAD + b.relX)
        b:setY(footerY + b.relY)
    end
    for _, b in ipairs({ self.techToggle, self.copyButton }) do
        b:setX(PAD + b.relX)
        b:setY(footerY + b.relY)
    end
    self:layoutTitle(width, th)
    self:buildTargets(n)
    self.layoutW, self.layoutSW, self.layoutSH = width, sw, sh
    self:clampToScreen()
end

-- ----- keyboard -----

function Win:keyboardTargets()
    if not self:getIsVisible() then return nil end
    return self.kbList
end

-- C.Keyboard offers Escape to the root that was handed the key, before the focus ring answers
-- it. This window is that root while it is the focused one, so Escape closes it and is eaten
-- here instead of reaching the window underneath.
function Win:onEscape()
    if not self:getIsVisible() then return false end
    closeNow(self)
    return true
end

function Win:onKeyPress(key) Keys.onKeyPress(self, key) end
function Win:onKeyRepeat(key) Keys.onKeyRepeat(self, key) end
function Win:onKeyRelease(key) Keys.onKeyRelease(self, key) end
function Win:isKeyConsumed(key) return Keys.isKeyConsumed(self, key) end
function Win:onFocus() Keys.onFocus(self) end

-- Controller: same engine and focus state as the keyboard (JoyPadSetup.lua:431-458, :678-680).
-- B is Escape here too: onEscape closes the record, and setVisible hands the joypad back to the
-- window it came from.
function Win:onJoypadDown(button, joypadData) Keys.onJoypadDown(self, button, joypadData) end
function Win:onJoypadDirUp(joypadData) Keys.onJoypadDir(self, "up", joypadData) end
function Win:onJoypadDirDown(joypadData) Keys.onJoypadDir(self, "down", joypadData) end
function Win:onJoypadDirLeft(joypadData) Keys.onJoypadDir(self, "left", joypadData) end
function Win:onJoypadDirRight(joypadData) Keys.onJoypadDir(self, "right", joypadData) end
-- the controller is going away (JoyPadSetup.lua:1056-1064): its focus goes back, the ring goes
function Win:onJoypadBeforeDeactivate(joypadData)
    Keys.releaseJoypad(self)
    Keys.clear(self)
end

-- ----- painting -----

function Win:prerender()
    -- the page that opened this window switched tab, hid, or lost the right to read: the record
    -- goes with it, and no owner has to remember to say so
    if self.detailOwner ~= nil and not alive(self.detailOwner) then
        closeNow(self)
        return
    end
    -- A row is picked on mouse *down*, and the click first ran onFocus of the window the row sits
    -- in (UIElement.java:1055-1064), which raised that window together with this one. The UIManager
    -- applies raises at the start of the next update, in the windows' old list order
    -- (UIManager.java:546-553), so a record that sat below that window stays behind it; a raise
    -- in the first prerender after the open still joins that same batch. The second prerender
    -- comes after the batch was applied, and a raise there is the only one of its batch.
    local pending = self.raisePending
    if pending ~= nil then
        if pending > 1 then
            self.raisePending = pending - 1
        else
            self.raisePending = nil
            self:bringToTop()
        end
    end
    if self.layoutSW ~= getCore():getScreenWidth() or self.layoutSH ~= getCore():getScreenHeight() then
        self:layout()
    end
    self:clampToScreen()
    local w, h = self:getWidth(), self:getHeight()
    local th = self:titleBarHeight()
    fill(self, 0, 0, w, h, "surface")
    fill(self, 0, 0, w, th, "surfaceTitle", true)
    local c = color("border")
    self:drawRect(0, th - 1, w, 1, c.a, c.r, c.g, c.b)
    if self.clearStentil then self:setStencilRect(0, 0, w, h) end
    if self.titleIcon ~= nil then
        local Icons = iconsLib()
        if Icons ~= nil then
            Icons.draw(self, self.titleIcon, self.titleIconX, self.titleIconY, self.titleIconSize, color("textMuted"), 1)
        end
    end
    if self.titleShown ~= nil then text(self, self.titleShown, self.titleX, self.titleY, "textMuted") end
    paintOps(self, self.footerOps, self.footerY or 0, 0, h)
    for _, b in ipairs(self.actionButtons) do
        local a = b.cardAction
        if a ~= nil and type(a.enabled) == "function" then b:setEnable(actionEnabled(a)) end
    end
end

function Win:render()
    local w, h = self:getWidth(), self:getHeight()
    if self.clearStentil then self:clearStencilRect() end
    U.Skin.border(self, 0, 0, w, h, color("border"))
    -- last: the children were painted between prerender and here, so the ring is over them
    Keys.render(self, U.theme)
end

-- ----- lifecycle -----

-- Every close (Escape / B, the close glyph, a vanished owner) ends here, so the controller focus
-- is handed back here and nowhere else.
function Win:setVisible(visible)
    local was = self.javaObject ~= nil and self:getIsVisible()
    ISCollapsableWindow.setVisible(self, visible)
    if not visible then
        Keys.clear(self)          -- no ring and no text focus left behind a closed window
        Keys.releaseJoypad(self)  -- the controller goes back to the window it came from
        return
    end
    Keys.onFocus(self)
    if not was then Keys.takeJoypad(self, 0) end
end

-- ISLayoutManager: the position the player dragged to is kept, and the window never auto-shows on
-- login. Position only -- the size follows the content, and there is no pin and no collapse state
-- to save here (createChildren removes both buttons), so the vanilla pair is deliberately not
-- delegated to: its restore branch calls ISCollapsableWindow:pin (ISCollapsableWindow.lua:336-354),
-- which writes to the very buttons this window no longer has (:145-148).
function Win:RestoreLayout(name, layout)
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    layout.width, layout.height = nil, nil
    layout.x = math.max(0, math.min(tonumber(layout.x) or self.x, sw - self.width))
    layout.y = math.max(0, math.min(tonumber(layout.y) or self.y, sh - self.height))
    layout.visible, layout.pin = nil, nil
    ISLayoutManager.DefaultRestoreWindow(self, layout)
    -- a remembered place is a place: the next open reads the record where the player left it
    self.placed = true
    self:setVisible(false)
end

function Win:SaveLayout(name, layout)
    layout.x, layout.y = self:getX(), self:getY()
    layout.width, layout.height = nil, nil
    layout.visible = "false"
end

local function create()
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    local w = cardWidth(sw)
    local h = math.min(sh, 200)
    local o = ISCollapsableWindow:new(math.floor((sw - w) / 2), math.floor((sh - h) / 2), w, h)
    setmetatable(o, Win)
    o.title = tr("Detail_Title")
    o.resizable = false
    o:initialise()
    -- UIManager offers key events to top-level UI that asked for them
    o:setWantKeyEvents(true)
    o:addToUIManager()
    o:setVisible(false)
    ISLayoutManager.RegisterWindow(LAYOUT_NAME, Win, o)
    return o
end

-- Beside the page it was opened from, never centred over it: both other windows are centred, so
-- a centred record would land on the very list it describes and every "read this, then carry on
-- with the list" would cost a drag first. Right of the owner when it fits, left when that is the
-- side with room, and -- for an owner as wide as the administration window, where neither side
-- fits -- against the screen edge the owner reaches least far into, so the largest possible part
-- of the list underneath stays clickable. Done for the first record of all only: from then on the
-- window opens where it was last left, whichever page, row or owner asks for it.
local function placeBeside(win, owner)
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    local ox = owner.getAbsoluteX ~= nil and owner:getAbsoluteX() or 0
    local oy = owner.getAbsoluteY ~= nil and owner:getAbsoluteY() or 0
    local ow = tonumber(owner.width) or 0
    local oh = tonumber(owner.height) or 0
    local x
    if ox + ow + GAP + win.width <= sw then x = ox + ow + GAP
    elseif ox - GAP - win.width >= 0 then x = ox - GAP - win.width
    elseif ox + ow / 2 <= sw / 2 then x = sw - win.width
    else x = 0 end
    win:setX(math.max(0, math.min(x, sw - win.width)))
    win:setY(math.max(0, math.min(oy + math.floor((oh - win.height) / 2), sh - win.height)))
end

-- ---------- module API ----------

-- owner: the page the record belongs to (any UI element). key: "kind:id", so the same row opened
-- twice is the same window and two different rows replace each other's content.
function D.open(owner, key, title, value, onClose, card)
    if type(owner) ~= "table" or type(key) ~= "string" or key == "" then return nil end
    if not U.init() then return nil end
    local win = D.window
    if win == nil then
        win = create()
        D.window = win
    end
    local shown = win:getIsVisible()
    local reset = not shown or win.detailOwner ~= owner or win.detailKey ~= key
    -- a record that belonged to somebody else is handed over, and that somebody is told
    if win.detailOwner ~= nil and (win.detailOwner ~= owner or win.detailKey ~= key)
        and win.onDetailClose ~= nil then
        local callback = win.onDetailClose
        local previous = win.detailOwner
        win.onDetailClose = nil
        pcall(callback, previous)
    end
    win.detailOwner, win.detailKey = owner, key
    win.onDetailClose = type(onClose) == "function" and onClose or nil
    setContent(win, title, value, card, reset)
    if not shown then
        -- the player's own place wins over the default one, and it survives the close: only a
        -- window that has never been placed is put beside its owner
        if not win.placed then
            placeBeside(win, owner)
            win.placed = true
        end
        win:clampToScreen()   -- a smaller screen than last time pulls it back into view
        win:setVisible(true)
    else
        win:bringToTop()
        Keys.onFocus(win)
    end
    win.raisePending = 2   -- and once more on its own, two prerenders later (Win:prerender says why)
    return win
end

-- Only the window that is really on screen for this owner and key. A reply that came back after
-- the admin closed the window is answered with false and changes nothing.
function D.update(owner, key, title, value, card)
    local win = D.window
    if win == nil or not win:getIsVisible() then return false end
    if win.detailOwner ~= owner or win.detailKey ~= key then return false end
    setContent(win, title, value, card, false)
    return true
end

-- The owner (or any ancestor of it: a window closes every page's record with one call).
function D.close(owner)
    local win = D.window
    if win == nil or win.detailOwner == nil then return end
    if owner ~= nil and not ownedBy(win.detailOwner, owner) then return end
    closeNow(win)
end

function D.isOpen(owner, key)
    local win = D.window
    if win == nil or not win:getIsVisible() or win.detailOwner == nil then return false end
    if owner ~= nil and not ownedBy(win.detailOwner, owner) then return false end
    if key ~= nil and win.detailKey ~= key then return false end
    return true
end

-- What the copy chip hands to the clipboard, unwrapped. nil when this owner has no window open.
function D.text(owner)
    if not D.isOpen(owner) then return nil end
    return D.window.rawText
end

return D
