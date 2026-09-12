-- MinidoracatEconomyFor42 — the administration window (client): the admin pages in a window of
-- their own, beside the Economy Center.
--
-- Why a second window and not a tab: the admin pages are wide tables of numbers over a left
-- navigation, and sharing the player window meant paying for the wallet chrome (status line,
-- balance strip, main tab strip) with the height those tables need. The Economy Center keeps its
-- Admin entry — it opens (or focuses) this window and never builds an Admin panel of its own:
-- C.AdminPanel is a module singleton (every admin.* reply is delivered to its P.instance), so the
-- session has exactly one admin page and this window owns it.
--
-- What this file owns:
--   * the window chrome — drag / pin / collapse / close, an ISLayoutManager name of its own, the
--     size clamp, the reset chip — and where the navigation strip and its toggle sit
--   * the admin page's sub-tab buttons, handed to ECNavigation (which reparents them with
--     removeChild/addChild). They stay the very objects ECAdminPanel built: same callbacks, same
--     permission-driven visibility, same `internal`. Only their geometry and their paint are the
--     strip's, so ECAdminPanel no longer lays out (or paints) a horizontal tab bar and its page
--     area is everything but the strip.
--   * the keyboard root: the navigation descriptors plus whatever the page offers. While the page
--     holds an overlay of its own (isModal: an item picker, an unsaved-changes prompt) the
--     navigation is left out of the walk, and Escape is offered to the page before the ring.
--
-- What it does not own: every read, write, permission, dialog and snapshot stays in ECAdminPanel.
-- This window never sends a command.
--
-- Closing: the title-bar close button goes through Admin:requestClose(callback), so an unsaved
-- draft is never dropped without the player saying so. The page is disposed only on a session
-- reset (AW.reset, driven by ECPanel's OnGameStart), never on a plain hide.
--
-- Engine references (snapshot 42.20.4-20260826):
--   two visible roots   UIManager.java:1435-1466 — top-level, visible, isWantKeyEvents, last added
--                       asked first: the front window is offered a key before the one behind it and
--                       the first consumer ends the walk (ECKeyboard keeps the ledger for both).
--   anchors             UIElement.java:1411-1430 — children shift with the parent size; everything
--                       here is placed explicitly in layout(), so the anchors stay default.
--   setWidth/setHeight  UIElement.java:1772-1779, 1813-1820 — they only record lastwidth/lastheight
--                       and the anchored chrome moves by the delta on the next update, so each axis
--                       is written at most once per frame (see RestoreLayout).

require "ISUI/ISCollapsableWindow"
require "ISUI/ISLayoutManager"

if not MinidoracatEconomy or not MinidoracatEconomy.Client or not MinidoracatEconomy.Client.UI then
    require "MinidoracatEconomy/ECWidgets"
end
require "MinidoracatEconomy/ECKeyboard"
require "MinidoracatEconomy/ECDatePicker"
require "MinidoracatEconomy/ECAdminPanel"
require "MinidoracatEconomy/ECDetailWindow"
require "MinidoracatEconomy/ECNavigation"

local EC = MinidoracatEconomy
local C = EC.Client
local U = C.UI
local Keys = C.Keyboard
local DatePicker = C.DatePicker
-- The session's detail window: every read-only record a page of this window opens goes there,
-- and D.close(owner) closes whatever this window or any child of it opened -- so hiding it,
-- closing it or losing the read right never leaves a record floating on its own.
local D = C.DetailWindow

local AW = {}
C.AdminWindow = AW

-- An ISLayoutManager name of its own: the two windows keep independent positions and sizes.
local LAYOUT_NAME = "MinidoracatEconomyAdminWindow"
local MIN_WIDTH, MIN_HEIGHT = 1000, 560
local Nav = C.Navigation

-- The strip's glyphs, by the sub tab's own `internal` (ECAdminPanel.TABS). A page with no entry
-- here simply has no icon; the strip stays readable either way. "Seasons" wears the rotation
-- glyph on purpose: the framework ships neither a calendar nor a clock, and a season tab is
-- about the turn from one period to the next rather than about a date.
local ADMIN_ICONS = {
    Player = "users", Recovery = "layers", Dashboard = "chart", Currencies = "coins", Sources = "plug",
    Shop = "shop", Whitelist = "shieldCheck", Listings = "tag", Auctions = "auction",
    Transactions = "transactions", Audit = "clipboardCheck", System = "server",
    Settings = "settings", Seasons = "reload",
}
local PAD, T = U.PAD, U.T
local fontH = U.fontH
local color, fill, text, textWidth = U.color, U.fill, U.text, U.textWidth
local Button = U.Button

local EMPTY = {}

-- ---------- window chrome buttons ----------
-- The vanilla title buttons (Button_Close / Button_Pin / Button_Collapse textures) restyled with
-- the framework's line icons: the button keeps its click, only the paint changes. Without the icon
-- capability the vanilla textures stay. Both windows wear the same chrome, so this lives here and
-- ECPanel reads it (ECWidgets is the toolkit of the pages, not of the window frame).
local CHROME_ICON = 16
function AW.iconButton(btn, name)
    local Icons = U.framework and U.framework.Icons
    if not (Icons and Icons.get and Icons.get(name)) then return end
    btn.image = nil
    btn.iconName = name
    btn.render = function(b)
        local hot = b:isMouseOver()
        Icons.draw(b, b.iconName, math.floor((b.width - CHROME_ICON) / 2), math.floor((b.height - CHROME_ICON) / 2),
            CHROME_ICON, color(hot and "text" or "textMuted"), 1)
    end
end

-- ---------- window ----------

local Win = ISCollapsableWindow:derive("MinidoracatEconomyAdminWindow")

-- Bigger than the player window by default (these are tables, not cards), never off-screen; a size
-- the admin dragged to is kept by ISLayoutManager and only clamped back into the screen.
local function defaultSize()
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    local w = math.min(sw, math.max(MIN_WIDTH, math.min(sw - 40, math.floor(sw * 0.84))))
    local h = math.min(sh, math.max(MIN_HEIGHT, math.min(sh - 40, math.floor(sh * 0.84))))
    return w, h
end

-- Taller than vanilla so the Medium title fits; the vanilla close/pin/collapse buttons and the drag
-- region size themselves from this value.
function Win:titleBarHeight()
    return math.max(28, fontH.medium + 8)
end

-- The strip's toggle: a chip of its own in the title bar, right of the vanilla close button and
-- left of the title, so it is in the same place whether the strip is folded or not.
function Win:toggleSize()
    return math.max(24, self:titleBarHeight() - 8)
end

function Win:createChildren()
    ISCollapsableWindow.createChildren(self)
    AW.iconButton(self.closeButton, "close")
    AW.iconButton(self.collapseButton, "lock")
    AW.iconButton(self.pinButton, "unlock")
    self.closeButton.fullTitle = getText(T .. "Window_Close")
    self.collapseButton.fullTitle = getText(T .. "Window_Pin")
    self.pinButton.fullTitle = getText(T .. "Window_Unpin")
    for _, b in ipairs({ self.closeButton, self.collapseButton, self.pinButton }) do b.tooltip = b.fullTitle end

    local reset = getText(T .. "Window_ResetSize")
    self.resetSizeButton = Button.create(0, 0, textWidth(reset) + 20, self:titleBarHeight() - 8,
        reset, self, Win.onResetSize, "chip")
    self:addChild(self.resetSizeButton)

    local admin = C.AdminPanel.create(self)
    self.adminPanel = admin

    -- One container for the whole strip, so hiding or collapsing the window takes it in one
    -- call, while every button keeps the visibility ECAdminPanel gives it per permission
    -- (isReallyVisible walks the parents, so the keyboard sees exactly what the eye does).
    -- ECNavigation reparents the sub tabs; they stay ECAdminPanel's objects in every other way.
    if admin then self:addChild(admin) end
    self.nav = Nav.create(self, admin and admin.subTabButtons or EMPTY, ADMIN_ICONS, "admin")
    self.nav.groupLabel = getText(T .. "Kb_Group_AdminTabs")
    self:addChild(self.nav)

    -- The toggle is the strip's, but it lives here: twelve pages already spend the height.
    local ts = self:toggleSize()
    self.navToggleButton = self.nav.toggleButton
    self.navToggleButton:setWidth(ts)
    self.navToggleButton:setHeight(ts)
    self:addChild(self.navToggleButton)
end

-- ----- geometry -----

function Win:layout()
    local w, h = self.width, self.height
    local th = self:titleBarHeight()
    local rh = self.resizable and self:resizeWidgetHeight() or 0
    local open = not self.isCollapsed
    local g = {}
    g.contentY = th + PAD
    g.contentH = math.max(80, h - g.contentY - rh - PAD)
    g.navX = PAD
    g.navW = self.nav:widthFor(w)
    g.bodyX = g.navX + g.navW + PAD
    g.bodyW = math.max(160, w - g.bodyX - PAD)
    self.g = g

    -- title bar: left of the vanilla pin/collapse button (both are th-2 square at w-1-(th-2))
    local dw, dh = defaultSize()
    local rb = self.resetSizeButton
    rb:setVisible((w ~= dw or h ~= dh) and open)
    rb:setX(w - 1 - (th - 2) - 6 - rb.width)
    rb:setY(math.floor((th - rb.height) / 2))

    -- The toggle keeps one place in both states: right of the vanilla close button
    -- (ISCollapsableWindow.lua:55 — a th-2 square at x = 1), left of the title, which starts
    -- after it.
    local tb = self.navToggleButton
    local ts = self:toggleSize()
    tb:setVisible(open)
    tb:setWidth(ts); tb:setHeight(ts)
    tb:setX(1 + (th - 2) + 8)
    tb:setY(math.floor((th - ts) / 2))
    g.titleX = tb.x + ts + PAD

    local nav = self.nav
    nav:setVisible(open and self.shown == true)
    nav:setX(g.navX); nav:setY(g.contentY)

    -- The page is sized first and the navigation arranged afterwards: ECAdminPanel re-runs its own
    -- layout from resize(), and the sub tabs are ours to place once it has.
    local admin = self.adminPanel
    if admin then
        admin:setX(g.bodyX); admin:setY(g.contentY)
        admin:resize(g.bodyW, g.contentH)
        admin:setVisible(open and self.shown == true and C.AdminPanel.canRead())
    end
    nav:layout(g.navW, g.contentH)
    self.layoutW, self.layoutH, self.layoutCollapsed = w, h, self.isCollapsed
end

-- Title-bar chip, shown only while the size differs from the default. One setWidth/setHeight per
-- axis (see RestoreLayout); ISLayoutManager saves the result.
function Win:onResetSize()
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    local w, h = defaultSize()
    self:setWidth(w)
    self:setHeight(h)
    self:setX(math.floor((sw - w) / 2))
    self:setY(math.floor((sh - h) / 2))
    self:layout()
end

-- ----- keyboard -----
-- A dialog supplies the whole focus ring; its background navigation stays out.
-- Lighter page overlays likewise omit navigation while keeping their own controls.
function Win:keyboardTargets()
    if not self.shown or self.isCollapsed then return nil end
    local admin = self.adminPanel
    if admin == nil or not C.AdminPanel.canRead() then return nil end
    if admin.dialog then return admin.dialog:keyboardTargets() end
    local out = {}
    local modal = admin:isModal()
    if not modal then
        for _, desc in ipairs(self.nav:keyboardTargets()) do out[#out + 1] = desc end
        out[#out + 1] = { kind = "button", control = admin.refreshButton, label = getText(T .. "Admin_Refresh") }
    end
    for _, desc in ipairs(admin:keyboardTargets()) do out[#out + 1] = desc end
    if not modal then
        out[#out + 1] = { kind = "button", control = self.resetSizeButton, label = self.resetSizeButton.fullTitle }
        for _, b in ipairs({ self.collapseButton, self.pinButton, self.closeButton }) do
            out[#out + 1] = { kind = "button", control = b, label = b.fullTitle }
        end
    end
    if #out == 0 then return nil end
    return out
end

-- ECKeyboard offers Escape here before the focus ring answers it: an overlay the page owns closes
-- first, and only the root the engine handed the key to is asked, so this window can never close a
-- popup that belongs to the Economy Center.
function Win:onEscape()
    return self.adminPanel:onEscape()
end
function Win:isModal() return self.adminPanel:isModal() end

-- UIManager offers key events to top-level UI only and asks isKeyConsumed after the handler ran
-- (UIElement.java:2185-2214): all four hooks go to the one engine, which keeps the ledger for both
-- windows.
function Win:onKeyPress(key) Keys.onKeyPress(self, key) end
function Win:onKeyRepeat(key) Keys.onKeyRepeat(self, key) end
function Win:onKeyRelease(key) Keys.onKeyRelease(self, key) end
function Win:isKeyConsumed(key) return Keys.isKeyConsumed(self, key) end
function Win:onFocus() Keys.onFocus(self) end

-- ----- drawing -----
-- prerender/render replace the parent versions (rounded surfaces; the Economy Center paints the
-- same way).

function Win:prerender()
    -- A local demotion closes immediately; clear first, since a hidden child no longer renders.
    if not C.AdminPanel.canRead() then
        if self.shown then
            self.adminPanel:clearData()
            self.adminPanel.lastLevel = nil
            self:setVisible(false)
        end
        return
    end
    if self.width ~= self.layoutW or self.height ~= self.layoutH
        or self.layoutCollapsed ~= self.isCollapsed then
        self:layout()
    end
    local modal = self.adminPanel:isModal()
    if self.modal ~= modal then
        self.modal = modal
        self.adminPanel:updateEnabled()
        Keys.invalidate(self)
    end
    local w = self:getWidth()
    local h = self:getHeight()
    local th = self:titleBarHeight()
    if self.isCollapsed then h = th end
    fill(self, 0, 0, w, h, "surface")
    fill(self, 0, 0, w, th, "surfaceTitle", not self.isCollapsed)
    if not self.isCollapsed then
        local c = color("border")
        self:drawRect(0, th - 1, w, 1, c.a, c.r, c.g, c.b)
    end
    if self.clearStentil then
        self:setStencilRect(0, 0, self.width, h)
    end
    if self.title then
        local tx = self.g and self.g.titleX or (th + PAD)
        text(self, self.title, tx, math.floor((th - fontH.medium) / 2), "text", UIFont.Medium)
    end
    if self.isCollapsed then return end
    local g = self.g
    fill(self, g.navX, g.contentY, g.navW, g.contentH, "well", "rect")
end

function Win:render()
    local w = self:getWidth()
    local h = self:getHeight()
    local th = self:titleBarHeight()
    if self.isCollapsed then h = th end
    if not self.isCollapsed and self.resizable and self.resizeWidget:getIsVisible() then
        local rh = self:resizeWidgetHeight()
        local c = color("border")
        self:drawRect(0, h - rh, w, 1, c.a, c.r, c.g, c.b)
        self:drawTextureScaled(self.resizeimage, w - rh + 1, h - rh + 1, rh - 4, rh - 4, 1, 1, 1, 1)
    end
    if self.clearStentil then
        self:clearStencilRect()
    end
    U.Skin.border(self, 0, 0, w, h, color("border"))
    -- last, and after the stencil was cleared: the children were rendered between prerender and
    -- this call (UIElement.java:1626-1634), so the ring is painted over the control it marks
    Keys.render(self)
end

-- ----- lifecycle -----

-- The title-bar close button (ISCollapsableWindow calls this) and every other normal close: the
-- page is asked first, so an unsaved draft is never dropped without the player saying so. The
-- callback runs once the page agrees; while it holds a prompt open the window simply stays.
function Win:close()
    self.adminPanel:requestClose(function() Keys.close(self) end)
end

function Win:setVisible(visible)
    ISCollapsableWindow.setVisible(self, visible)
    self.shown = visible == true
    local admin = self.adminPanel
    if not visible then
        if self.nav then self.nav:setVisible(false) end
        if admin then
            admin:setVisible(false)
            DatePicker.close(admin)   -- this page's calendar only: the Economy Center keeps its own
        end
        D.close(self)                 -- this window and every page under it
        Keys.clear(self)              -- no ring waiting behind a closed window
        return
    end
    local O = EC.Options
    if O and O.panelOpacity then U.setAlpha(O.panelOpacity()) end   -- ModOptions may have moved it
    Keys.onFocus(self)
    self:layout()
    if admin then admin:refresh() end
end

-- ISLayoutManager: keep position/size, never auto-show on login. The saved numbers are clamped
-- *before* the parent applies them (see the setWidth/setHeight note in the header).
function Win:RestoreLayout(name, layout)
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    self.minimumWidth, self.minimumHeight = math.min(MIN_WIDTH, sw), math.min(MIN_HEIGHT, sh)
    local w = math.min(sw, math.max(MIN_WIDTH, tonumber(layout.width) or self.width))
    local h = math.min(sh, math.max(MIN_HEIGHT, tonumber(layout.height) or self.height))
    layout.width, layout.height = w, h
    layout.x = math.max(0, math.min(tonumber(layout.x) or self.x, sw - w))
    layout.y = math.max(0, math.min(tonumber(layout.y) or self.y, sh - h))
    local visible = layout.visible
    layout.visible = nil
    ISCollapsableWindow.RestoreLayout(self, name, layout)
    layout.visible = visible
    self:setVisible(false)
end

function Win.create()
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    local w, h = defaultSize()
    local o = ISCollapsableWindow:new(math.floor((sw - w) / 2), math.floor((sh - h) / 2), w, h)
    setmetatable(o, Win)
    o.title = getText(T .. "Admin_Window_Title")
    o.resizable = true
    o.minimumWidth = math.min(MIN_WIDTH, sw)
    o.minimumHeight = math.min(MIN_HEIGHT, sh)
    o:initialise()
    -- UIManager offers key events to top-level UI that asked for them (UIManager.java:1435-1466)
    o:setWantKeyEvents(true)
    o:addToUIManager()
    o:setVisible(false)
    ISLayoutManager.RegisterWindow(LAYOUT_NAME, Win, o)
    return o
end

-- ---------- module API ----------

-- The one entry point: opens the singleton, or brings it to the front when it is already up. Never
-- a second window and never a second Admin page (C.AdminPanel is a singleton of its own).
function AW.open()
    if not C.AdminPanel.canRead() then return nil end
    if not U.init() then return nil end
    local win = AW.window
    if win == nil then
        win = Win.create()
        AW.window = win
    end
    if win:getIsVisible() then
        Keys.onFocus(win)
    else
        win:setVisible(true)
    end
    return win
end

-- Session reset (a new world): the page is disposed for real here — this is the one place that
-- forces it — and the window is rebuilt against the new server state on the next open.
function AW.reset()
    local win = AW.window
    if win == nil then return end
    AW.window = nil
    D.close(win)      -- before the page is disposed: it is the owner of whatever is still open
    Keys.clear(win)
    local admin = win.adminPanel
    win.adminPanel = nil
    if admin then admin:dispose() end
    win:removeFromUIManager()
end

-- A resolution change (or a window-mode switch) must not leave the window off-screen or larger
-- than the screen; the size the admin chose is otherwise kept.
function AW.clampToScreen()
    local win = AW.window
    if win == nil then return end
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    win.minimumWidth, win.minimumHeight = math.min(MIN_WIDTH, sw), math.min(MIN_HEIGHT, sh)
    local width = math.min(sw, math.max(MIN_WIDTH, win.width))
    local height = math.min(sh, math.max(MIN_HEIGHT, win.height))
    if width ~= win.width then win:setWidth(width) end
    if height ~= win.height then win:setHeight(height) end
    win:setX(math.max(0, math.min(win.x, sw - win.width)))
    win:setY(math.max(0, math.min(win.y, sh - win.height)))
    win:layout()
end

return AW
