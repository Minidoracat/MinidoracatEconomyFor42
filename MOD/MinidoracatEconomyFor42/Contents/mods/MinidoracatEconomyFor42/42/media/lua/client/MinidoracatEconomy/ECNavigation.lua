-- MinidoracatEconomyFor42 — the navigation strip shared by both windows (client).
--
-- One vertical strip for the Economy Center and for the administration window. The owner hands it
-- the page buttons it already built; this module gives them geometry, an icon and a collapsed /
-- expanded state. Two things it deliberately does not do:
--
--   * it never builds a second button. The instances stay the very ones the page created, with
--     their target / onclick / internal / fullTitle untouched, so a click here is the same call
--     the old horizontal tab strip made — same page switch, same draft guard, same permission.
--     Only the paint and the geometry are ours (`b.render` is replaced the way ECAdminWindow
--     already restyles the vanilla window-chrome buttons).
--   * it never sends a command and never rebuilds a page. Collapsing changes an icon, a label and
--     a width; the selection, the drafts, the filters and the list scroll underneath are not
--     touched at all, so the strip can be folded in the middle of typing an offer.
--
-- Collapsed is a 56 px icon rail, expanded is icon + label measured from the labels actually on
-- screen. Each window keeps its own preference (ECOptions, two independent ModOptions tick boxes):
-- the admin tables want the width back, the player pages want the words.
--
-- The toggle button belongs to the owner's title bar, not to the strip: it is then reachable in
-- both states (a rail that hides its own way out is a trap) and it costs the strip no vertical
-- room — the admin has twelve pages to fit at 1000x560 with a large font.
--
-- Engine references (snapshot 42.20.4-20260826):
--   update()             UIElement.java:1568-1585 — the engine ticks every added, visible child,
--                        so a preference changed on the ESC options screen is picked up without an
--                        Events subscription of the mod's own.
--   removeChild/addChild UIElement.java:1249-1290 — reparenting keeps the java object and every
--                        Lua field of the button; only the parent changes, and with it the
--                        isReallyVisible walk the keyboard uses.
--   drawTextureScaled    the framework's Icons.draw wraps it and answers false for a missing
--                        sheet (V1.lua:393-417), which is the one signal a fallback needs.

require "ISUI/ISPanel"

if not MinidoracatEconomy or not MinidoracatEconomy.Client or not MinidoracatEconomy.Client.UI then
    require "MinidoracatEconomy/ECWidgets"
end
require "MinidoracatEconomy/ECKeyboard"
require "MinidoracatEconomy/ECOptions"

local EC = MinidoracatEconomy
local C = EC.Client
local U = C.UI
local Keys = C.Keyboard
local O = EC.Options

local N = {}
C.Navigation = N

local PAD, T = U.PAD, U.T
local fontH = U.fontH
local color, fill, border, text, textCentre = U.color, U.fill, U.border, U.text, U.textCentre
local textWidth, fitText = U.textWidth, U.fitText

local RAIL_W = 56           -- collapsed width: icon + a thumb-sized margin either side
local EXPANDED_MIN = 160
local EXPANDED_SHARE = 0.26 -- ceiling: the strip never takes more than a quarter of the window
local ICON = 22             -- the art sheet is 32 px, drawn at 20-24
local ICON_GAP = 8
local EDGE = 10             -- icon inset of an expanded row
local MIN_ROW = 24          -- hit-area floor
local ROW_GAP = 4
local UTIL_GAP = 14         -- the break above the utility group
local ACTIVE_BAR = 3
local TOGGLE_ICON = 16

local EMPTY = {}

local Nav = ISPanel:derive("MinidoracatEconomyNav")
N.Panel = Nav

-- ---------- paint ----------

-- A row. The selected page is a filled band with an accent bar on its leading edge; the keyboard
-- ring is drawn *outside* the control by ECKeyboard, with the label as its caption. The two are
-- never the same shape, so neither of them depends on colour alone.
local function rowRender(b)
    local nav = b.navPanel
    local w, h = b.width, b.height
    local hovered = b.enable and b.mouseOver and b:isMouseOver()
    local token
    if b.active then
        fill(b, 0, 0, w, h, "selected", "rect")
        fill(b, 0, 0, ACTIVE_BAR, h, "accent", "rect")
        token = "accent"
    elseif hovered then
        fill(b, 0, 0, w, h, "hover", "rect")
        token = "text"
    else
        token = "textMuted"
    end
    if not b.enable then token = "textFaint" end

    local collapsed = nav.collapsed
    local iconX = collapsed and math.floor((w - ICON) / 2) or EDGE
    local drew = false
    local Icons = U.framework and U.framework.Icons
    if Icons and b.navIcon then
        drew = Icons.draw(b, b.navIcon, iconX, math.floor((h - ICON) / 2), ICON, color(token), 1) == true
    end
    local ty = math.floor((h - fontH.small) / 2)
    if collapsed then
        -- No glyph (an asset that never shipped): the rail still has to say something, so the
        -- label itself is fitted into it. The tooltip and the keyboard caption carry the full
        -- name either way, so nothing is ever reduced to a single letter and nothing vanishes.
        if not drew then textCentre(b, fitText(b.navTitle, w - 8, b.font), w / 2, ty, token, b.font) end
    else
        text(b, b.title, iconX + ICON + ICON_GAP, ty, token, b.font)
    end
    if b.joypadFocused then border(b, 1, 1, w - 2, h - 2, "accent") end
end

-- The toggle. Icon-only, so its title stays empty and the words live in fullTitle / tooltip (the
-- pair ECKeyboard.captionOf reads). Without the chevron assets it paints three bars — the shape
-- every player reads as "the menu", and one that cannot be mistaken for a page.
local function toggleRender(b)
    local nav = b.navPanel
    local w, h = b.width, b.height
    local hovered = b.enable and b.mouseOver and b:isMouseOver()
    local token = "textMuted"
    if not b.enable then token = "textFaint" elseif hovered then token = "text" end
    if hovered then fill(b, 0, 0, w, h, "hover", "pill") end
    border(b, 0, 0, w, h, "border", "pill")

    local c = color(token)
    local Icons = U.framework and U.framework.Icons
    local name = nav.collapsed and "chevronRight" or "chevronLeft"
    if Icons and Icons.draw(b, name, math.floor((w - TOGGLE_ICON) / 2), math.floor((h - TOGGLE_ICON) / 2),
        TOGGLE_ICON, c, 1) == true then
        return
    end
    local bw = math.max(10, math.floor(w / 2))
    local bx = math.floor((w - bw) / 2)
    local by = math.floor(h / 2) - 5
    for i = 0, 2 do b:drawRect(bx, by + i * 4, bw, 2, c.a, c.r, c.g, c.b) end
end

-- The one thing the strip paints for itself: the hairline above the utility group, so "settings
-- and the other window" read as a group of their own instead of two more pages.
function Nav:prerender()
    local y = self.utilLine
    if y == nil then return end
    local c = color("border")
    self:drawRect(PAD, y, math.max(0, self.width - PAD * 2), 1, c.a, c.r, c.g, c.b)
end

-- ---------- state ----------

function Nav:syncToggle()
    local b = self.toggleButton
    if b == nil then return end
    local title = getText(T .. (self.collapsed and "Nav_Expand" or "Nav_Collapse"))
    b.fullTitle = title
    b.tooltip = title
    b:setTitle("")
end

-- The whole toggle: write the preference, let the owner re-lay itself out, revalidate the ring.
-- No command, no page rebuild, no data request — the pages underneath do not even hear about it.
function Nav:onToggle()
    if self.owner:isModal() then return end
    O.setNavigationCollapsed(self.preference, not O.navigationCollapsed(self.preference))
    local owner = self.owner
    if owner ~= nil and owner.layout ~= nil then owner:layout() end
    Keys.invalidate(owner)
end

-- Ticked by the engine while the strip is on screen. Two jobs: the toggle follows the owner's
-- modal state (a picker is open: the window is not the player's to reshape), and a preference
-- changed somewhere else — the ESC options screen, the other window sharing nothing but the ini —
-- is adopted on the next frame.
function Nav:update()
    local collapsed = O.navigationCollapsed(self.preference)
    if collapsed ~= self.collapsed then
        self.collapsed = collapsed
        self:syncToggle()
        local owner = self.owner
        if owner ~= nil and owner.layout ~= nil then owner:layout() end
        Keys.invalidate(owner)
    end
    local b = self.toggleButton
    if b == nil then return end
    local owner = self.owner
    local modal = owner ~= nil and owner.isModal ~= nil and owner:isModal() == true
    if b.enable == modal then b:setEnable(not modal) end
end

-- ---------- geometry ----------

-- Collapsed is a constant; expanded is measured from the labels that are actually visible, so a
-- permission the player does not hold never widens the strip. Bounded both ways: a language with
-- short words still gets a strip that reads as one, a long one never eats the table beside it.
function Nav:widthFor(windowWidth)
    if O.navigationCollapsed(self.preference) then return RAIL_W end
    local widest = 0
    for _, b in ipairs(self.buttons) do
        if b:getIsVisible() then
            local tw = textWidth(b.navTitle, b.font)
            if tw > widest then widest = tw end
        end
    end
    local want = EDGE + ICON + ICON_GAP + widest + PAD
    local ceiling = math.max(EXPANDED_MIN, math.floor((tonumber(windowWidth) or 0) * EXPANDED_SHARE))
    if want < EXPANDED_MIN then want = EXPANDED_MIN end
    if want > ceiling then want = ceiling end
    return want
end

function Nav:place(b, y, w, rowH)
    b:setX(0)
    b:setY(y)
    b:setWidth(w)
    b:setHeight(rowH)
    if self.collapsed then
        b:setTitle("")   -- icon only; fullTitle keeps the words for the tooltip and the caption
    else
        b:setTitle(fitText(b.navTitle, w - (EDGE + ICON + ICON_GAP) - PAD, b.font))
    end
end

-- Places every visible button inside width x height. The height is spent on the rows there are:
-- the gaps give way before the row height does, and the row height itself is floored by the hit
-- area rather than by the font. Nothing is ever parked below the bottom edge, where a player with
-- no scroll bar to see would never look for it.
function Nav:layout(width, height)
    local w = math.max(RAIL_W, math.floor(tonumber(width) or RAIL_W))
    local h = math.max(0, math.floor(tonumber(height) or 0))
    self:setWidth(w)
    self:setHeight(h)
    self.collapsed = O.navigationCollapsed(self.preference)
    self:syncToggle()
    self.utilLine = nil

    local main, util = {}, {}
    for _, b in ipairs(self.buttons) do
        if b:getIsVisible() then
            if b.navUtility then util[#util + 1] = b else main[#main + 1] = b end
        end
    end
    local n = #main + #util
    if n == 0 then return end

    local split = (#main > 0 and #util > 0) and UTIL_GAP or 0
    local gap = ROW_GAP
    local room = math.floor((h - gap * (n - 1) - split) / n)
    if room < MIN_ROW then
        gap = 0
        room = math.floor((h - split) / n)
    end
    local rowH = math.max(MIN_ROW, math.min(fontH.small + 12, room))
    if rowH > room then rowH = math.max(1, room) end

    local y = 0
    for _, b in ipairs(main) do
        self:place(b, y, w, rowH)
        y = y + rowH + gap
    end
    if #util == 0 then return end

    -- The utility group sits on the bottom edge while there is room for it to, and falls in
    -- behind the pages when there is not.
    local blockH = #util * rowH + (#util - 1) * gap
    local uy = h - blockH
    if #main > 0 and uy < y + split then uy = y + split end
    if #main > 0 then self.utilLine = uy - math.floor(split / 2) end
    for _, b in ipairs(util) do
        self:place(b, uy, w, rowH)
        uy = uy + rowH + gap
    end
end

-- ---------- keyboard ----------

-- The toggle first (it sits in the title bar, above the strip), then the pages as they are
-- painted — one group, so the arrows walk the pages and Tab steps out of the navigation.
function Nav:keyboardTargets()
    local out = {}
    local toggle = self.toggleButton
    if toggle ~= nil and toggle:getIsVisible() then
        out[#out + 1] = { kind = "button", control = toggle, label = toggle.fullTitle }
    end
    local controls = {}
    for _, b in ipairs(self.buttons) do
        if b:getIsVisible() and not b.navUtility then controls[#controls + 1] = b end
    end
    for _, b in ipairs(self.buttons) do
        if b:getIsVisible() and b.navUtility then controls[#controls + 1] = b end
    end
    if #controls > 0 then
        out[#out + 1] = { kind = "group", controls = controls, label = self.groupLabel }
    end
    return out
end

-- ---------- module API ----------

-- create(owner, buttons, iconById, preference) -> the strip, initialised and instantiated but not
-- added: the owner adds it where it wants it and calls layout(width, height) from its own.
--
--   buttons     existing button instances, in the order they should read. `navUtility = true`
--               moves one into the bottom group without changing its order within it.
--   iconById    button.internal -> framework icon key. A missing entry is not an error.
--   preference  "player" or "admin" — which of the two saved collapse states this strip follows.
--
-- `toggleButton` is created here and left unadded on purpose (see the header).
function N.create(owner, buttons, iconById, preference)
    local nav = ISPanel:new(0, 0, RAIL_W, 100)
    setmetatable(nav, Nav)
    nav.background = false
    nav.owner = owner
    nav.preference = preference == "admin" and "admin" or "player"
    nav.buttons = {}
    nav.groupLabel = getText(T .. "Kb_Group_Nav")
    nav:initialise()
    nav:instantiate()   -- it adopts children of its own, so it needs its java object now
    nav.collapsed = O.navigationCollapsed(preference)

    local icons = iconById or EMPTY
    for _, b in ipairs(buttons or EMPTY) do
        local parent = b.parent
        if parent ~= nil and parent.removeChild ~= nil then parent:removeChild(b) end
        nav:addChild(b)
        b.navPanel = nav
        b.navTitle = b.fullTitle or b.title or ""
        b.navIcon = icons[b.internal]
        b.render = rowRender
        nav.buttons[#nav.buttons + 1] = b
    end

    nav.toggleButton = U.Button.create(0, 0, 26, 26, "", nav, Nav.onToggle, "chip")
    nav.toggleButton.navPanel = nav
    nav.toggleButton.render = toggleRender
    nav:syncToggle()
    return nav
end

return N
