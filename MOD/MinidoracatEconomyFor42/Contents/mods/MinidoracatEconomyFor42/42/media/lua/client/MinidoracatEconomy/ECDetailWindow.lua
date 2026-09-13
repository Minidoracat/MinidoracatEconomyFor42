-- MinidoracatEconomyFor42 -- the shared detail window (client). Adds exactly one namespace:
-- C.DetailWindow.
--
-- One window for the whole session, borrowed by whichever page is showing a record right now.
-- Before it existed, every page that had something long to say built a band of its own inside
-- its card: the band ate the rows it was describing, it could only ever show the first few
-- lines, and a card too short for both simply dropped the list. This window is the one answer to
-- all of that -- it is a window, so it is dragged, resized and closed like any other, and the
-- list underneath keeps every row, every filter, its page and its scroll.
--
--   D.open(owner, key, title, text, onClose?)  show `text` and make it this owner's window.
--                                              Returns the window element, nil when the UI
--                                              framework is not up. The same owner opening a
--                                              different key reuses this very window (there is
--                                              never a second one); another owner taking it over
--                                              tells the previous one through its onClose.
--   D.update(owner, key, title, text)          only while that owner's key is really on screen.
--                                              Returns false for a window that was closed, so a
--                                              reply that came back late can never revive it.
--   D.close(owner)                             closes the window when it belongs to that owner
--                                              or to any of its descendants (a page, a sub page,
--                                              a row editor): the owner's page switch, its hide
--                                              and its loss of permission all end here.
--   D.isOpen(owner, key?)                      visible, owned by that owner (or a descendant),
--                                              and -- when a key is named -- showing that key.
--   D.text(owner)                              what is on screen right now, for the owner only.
--
-- Where it opens: beside the page the first record of all was read from, and from then on wherever
-- the player last left it -- a close and a reopen, another row, another page and another owner all
-- find it there, and ISLayoutManager keeps that place and that size (layout.ini). Only a screen
-- that shrank moves it, and then just far enough to be visible again.
--
-- What it deliberately is not:
--   * not always on top -- it is an ordinary top level window and it may be covered
--   * not collapsible -- it is read while the cursor stays on the row it was opened from, and
--     vanilla collapses an unpinned window exactly then, so the title-bar pair that arms that is
--     removed in createChildren and the record stays whole from the click that opened it
--   * not a second keyboard engine -- C.Keyboard owns the ring here exactly like in the other
--     two windows, and the read-only box is never given the engine's text focus (ECKeyboard's
--     read-only trap: a non-editable box takes every key and handles none)
--   * not a confirmation: paying, cancelling and delisting keep their own explicit prompts. This
--     window only ever reads.
--
-- The copied text is the value the caller handed over, never the wrapped lines on screen: a
-- record is pasted into a ticket exactly as the server wrote it.
--
-- Engine references (snapshot 42.20.4-20260826):
--   top-level keys      UIManager.java:1435-1466 -- visible + isWantKeyEvents, last added asked
--                       first. Focusing this window makes it the root C.Keyboard answers for, so
--                       Escape closes this window instead of leaking into the one behind it.
--   onFocus order       UIElement.java:1056-1065 -- onFocus runs before the press reaches a child
--   render order        UIElement.java:1626-1634 -- children paint between prerender and render,
--                       so the focus ring is painted last (Keys.render)
--   mouse-out collapse  UIManager.java:794-806 -- every visible top level window the cursor is
--                       not over is given onMouseMoveOutside on each move, which is what
--                       ISCollapsableWindow.lua:228-247 counts towards collapsing

require "ISUI/ISCollapsableWindow"
require "ISUI/ISLayoutManager"

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
local color, fill, text, textWidth, fitText = U.color, U.fill, U.text, U.textWidth, U.fitText
local Button = U.Button

-- Big enough for a posting block at the default font, small enough to sit beside the window it
-- was opened from on a 1280 wide screen.
local MIN_WIDTH, MIN_HEIGHT = 420, 260
-- How far the parent chain is walked when a window is asked whether it belongs to an owner. The
-- same bound C.Keyboard uses to find a root.
local OWNER_DEPTH = 32
-- the breathing room between the owner's window and this one
local GAP = 8
-- An ISLayoutManager name of its own: this window keeps a position and a size independent of the
-- two big windows, and keeps them across a close and a reopen.
local LAYOUT_NAME = "MinidoracatEconomyDetailWindow"

local function tr(key) return getText(T .. key) end
local function chipH() return math.max(22, fontH.small + 8) end

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

    local ch = chipH()
    local copy = tr("Detail_CopyAll")
    self.copyButton = Button.create(0, 0, textWidth(copy) + 24, ch, copy, self, Win.onCopyAll, "chip")
    self:addChild(self.copyButton)
    local close = tr("Detail_Close")
    self.dismissButton = Button.create(0, 0, textWidth(close) + 24, ch, close, self, Win.onDismiss, "chip")
    self:addChild(self.dismissButton)

    -- the one read-only, scrolling surface the whole mod uses. Never selectable and never given
    -- the engine's text focus: the keyboard scrolls it and Ctrl+C presses the copy chip.
    self.reader = U.newReader(self, 200, 100)
end

-- ----- content -----

-- The text is held unwrapped (that is what CopyAll hands over) and the box is given the wrapped
-- copy for this width alone, so a resize re-wraps and nothing is ever cut.
local function setContent(win, title, value)
    local heading = (type(title) == "string" and title ~= "") and title or tr("Detail_Title")
    local raw = type(value) == "string" and value or ""
    if raw == "" then raw = tr("Detail_Loading") end
    -- an owner that re-states what is already on screen (a layout, a snapshot that changed
    -- nothing) costs one comparison, not a re-wrap and a re-place
    if win.rawText == raw and win.detailTitle == heading then return end
    win.detailTitle, win.rawText = heading, raw
    win.copyNote = nil
    win:layout()
end

local function closeNow(win)
    if win == nil or win.closing == true then return end
    local owner, callback = win.detailOwner, win.onDetailClose
    win.closing = true
    win.detailOwner, win.detailKey, win.onDetailClose = nil, nil, nil
    win.rawText, win.detailTitle, win.copyNote = nil, nil, nil
    if win:getIsVisible() then win:setVisible(false) end
    if win.reader ~= nil then
        U.setWrappedText(win.reader, "", win.reader.width)
        pcall(win.reader.unfocus, win.reader)
    end
    win.closing = false
    -- the owner is told after the window is already closed, so a callback that asks D.isOpen
    -- reads the state it is being told about. It is a notification only: the list keeps its
    -- selection unless the owner itself decides otherwise.
    if callback ~= nil then pcall(callback, owner) end
end

function Win:onCopyAll()
    local value = self.rawText
    if type(value) ~= "string" or value == "" then return end
    if not (Clipboard and Clipboard.setClipboard) then
        self.copyNote = tr("Admin_Sys_CopyFailed")
        return
    end
    local ok = pcall(Clipboard.setClipboard, value)
    self.copyNote = ok and getText(T .. "Admin_Audit_Copied", self.detailTitle or tr("Detail_Title"))
        or tr("Admin_Sys_CopyFailed")
end

function Win:onDismiss()
    closeNow(self)
end

-- The title bar's own close button lands here (ISCollapsableWindow:close).
function Win:close()
    closeNow(self)
end

-- ----- geometry -----

-- Inside the screen, and never larger than it: a resolution change or a window-mode switch must
-- not leave the window half off the desktop. Every write is guarded, so a window already in
-- place costs four comparisons.
function Win:clampToScreen()
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    self.minimumWidth, self.minimumHeight = math.min(MIN_WIDTH, sw), math.min(MIN_HEIGHT, sh)
    local w = math.min(sw, math.max(self.minimumWidth, self.width))
    local h = math.min(sh, math.max(self.minimumHeight, self.height))
    if w ~= self.width then self:setWidth(w) end
    if h ~= self.height then self:setHeight(h) end
    local x = math.max(0, math.min(self.x, sw - w))
    local y = math.max(0, math.min(self.y, sh - h))
    if x ~= self.x then self:setX(x) end
    if y ~= self.y then self:setY(y) end
end

function Win:layout()
    local w, h = self.width, self.height
    local th = self:titleBarHeight()
    local rh = self.resizable and self:resizeWidgetHeight() or 0
    local ch = chipH()
    local open = not self.isCollapsed

    local actionY = h - rh - PAD - ch
    local bx = PAD
    for _, b in ipairs({ self.copyButton, self.dismissButton }) do
        local bw = math.min(textWidth(b.fullTitle) + 24, math.max(48, math.floor((w - PAD * 3) / 2)))
        b:setVisible(open)
        b:setWidth(bw); b:setHeight(ch)
        b:setX(bx); b:setY(actionY)
        U.setButtonTitle(b, b.fullTitle)
        bx = bx + bw + 6
    end
    self.noteX = bx + PAD
    self.noteW = math.max(0, w - PAD - self.noteX)
    self.noteY = actionY + math.floor((ch - fontH.small) / 2)

    local readerY = th + PAD
    local reader = self.reader
    reader:setVisible(open)
    reader:setX(PAD); reader:setY(readerY)
    reader:setWidth(math.max(80, w - PAD * 2))
    reader:setHeight(math.max(fontH.small + 8, actionY - PAD - readerY))
    U.setWrappedText(reader, self.rawText or "", reader.width)

    -- one glyph wide on the left (close) and nothing on the right since the collapse pair went
    self.titleW = math.max(0, w - 2 - (th - 2) - PAD * 2)
    self.layoutW, self.layoutH, self.layoutCollapsed = w, h, self.isCollapsed
end

-- ----- keyboard -----

function Win:keyboardTargets()
    if not self:getIsVisible() or self.isCollapsed then return nil end
    return {
        { kind = "group", label = tr("Detail_Title"),
            controls = { self.copyButton, self.dismissButton } },
        -- kind = "scroll" and focusable = false: the engine's text focus would swallow every key
        -- and handle none. Ctrl+C over it presses the copy chip, so there is one copy path.
        { kind = "scroll", label = self.detailTitle or tr("Detail_Title"), control = self.reader,
            focusable = false, copyAll = self.copyButton },
    }
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

-- ----- painting -----

function Win:prerender()
    -- the page that opened this window switched tab, hid, or lost the right to read: the record
    -- goes with it, and no owner has to remember to say so
    if self.detailOwner ~= nil and not alive(self.detailOwner) then
        closeNow(self)
        return
    end
    self:clampToScreen()
    if self.width ~= self.layoutW or self.height ~= self.layoutH
        or self.layoutCollapsed ~= self.isCollapsed then
        self:layout()
    end
    local w, h = self:getWidth(), self:getHeight()
    local th = self:titleBarHeight()
    if self.isCollapsed then h = th end
    fill(self, 0, 0, w, h, "surface")
    fill(self, 0, 0, w, th, "surfaceTitle", not self.isCollapsed)
    if not self.isCollapsed then
        local c = color("border")
        self:drawRect(0, th - 1, w, 1, c.a, c.r, c.g, c.b)
    end
    if self.clearStentil then self:setStencilRect(0, 0, self.width, h) end
    text(self, fitText(self.detailTitle or tr("Detail_Title"), self.titleW or w, UIFont.Medium),
        1 + (th - 2) + PAD, math.floor((th - fontH.medium) / 2), "text", UIFont.Medium)
    if self.isCollapsed then return end
    if self.copyNote ~= nil and (self.noteW or 0) > 0 then
        text(self, fitText(self.copyNote, self.noteW), self.noteX, self.noteY, "textMuted")
    end
end

function Win:render()
    local w, h = self:getWidth(), self:getHeight()
    local th = self:titleBarHeight()
    if self.isCollapsed then h = th end
    if not self.isCollapsed and self.resizable and self.resizeWidget:getIsVisible() then
        local rh = self:resizeWidgetHeight()
        local c = color("border")
        self:drawRect(0, h - rh, w, 1, c.a, c.r, c.g, c.b)
        self:drawTextureScaled(self.resizeimage, w - rh + 1, h - rh + 1, rh - 4, rh - 4, 1, 1, 1, 1)
    end
    if self.clearStentil then self:clearStencilRect() end
    U.Skin.border(self, 0, 0, w, h, color("border"))
    -- last: the children were painted between prerender and here, so the ring is over them
    Keys.render(self)
end

-- ----- lifecycle -----

function Win:setVisible(visible)
    ISCollapsableWindow.setVisible(self, visible)
    if not visible then
        Keys.clear(self)   -- no ring and no text focus left behind a closed window
        return
    end
    Keys.onFocus(self)
    self:layout()
end

-- ISLayoutManager: the position and the size the player dragged to are kept, and the window never
-- auto-shows on login. Geometry only -- there is no pin and no collapse state to save here
-- (createChildren removes both buttons), so the vanilla pair is deliberately not delegated to:
-- its restore branch calls ISCollapsableWindow:pin (ISCollapsableWindow.lua:336-354), which
-- writes to the very buttons this window no longer has (:145-148). The saved numbers are clamped
-- *before* the parent applies them, the way both other windows do it, so the resize widget takes
-- one delta and the grips stay on the frame.
function Win:RestoreLayout(name, layout)
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    self.minimumWidth, self.minimumHeight = math.min(MIN_WIDTH, sw), math.min(MIN_HEIGHT, sh)
    local w = math.min(sw, math.max(self.minimumWidth, tonumber(layout.width) or self.width))
    local h = math.min(sh, math.max(self.minimumHeight, tonumber(layout.height) or self.height))
    layout.width, layout.height = w, h
    layout.x = math.max(0, math.min(tonumber(layout.x) or self.x, sw - w))
    layout.y = math.max(0, math.min(tonumber(layout.y) or self.y, sh - h))
    layout.visible, layout.pin = nil, nil
    ISLayoutManager.DefaultRestoreWindow(self, layout)
    -- a remembered place is a place: the next open reads the record where the player left it
    self.placed = true
    self:setVisible(false)
end

function Win:SaveLayout(name, layout)
    layout.x, layout.y = self:getX(), self:getY()
    layout.width, layout.height = self:getWidth(), self:getHeight()
    layout.visible = "false"
end

local function create()
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    local w = math.min(sw, math.max(MIN_WIDTH, math.floor(sw * 0.34)))
    local h = math.min(sh, math.max(MIN_HEIGHT, math.floor(sh * 0.46)))
    local o = ISCollapsableWindow:new(math.floor((sw - w) / 2), math.floor((sh - h) / 2), w, h)
    setmetatable(o, Win)
    o.title = tr("Detail_Title")
    o.resizable = true
    o.minimumWidth = math.min(MIN_WIDTH, sw)
    o.minimumHeight = math.min(MIN_HEIGHT, sh)
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
function D.open(owner, key, title, value, onClose)
    if type(owner) ~= "table" or type(key) ~= "string" or key == "" then return nil end
    if not U.init() then return nil end
    local win = D.window
    if win == nil then
        win = create()
        D.window = win
    end
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
    if not win:getIsVisible() then
        -- the player's own place wins over the default one, and it survives the close: only a
        -- window that has never been placed is put beside its owner
        if not win.placed then
            placeBeside(win, owner)
            win.placed = true
        end
        win:clampToScreen()   -- a smaller screen than last time pulls it back into view
        setContent(win, title, value)
        win:setVisible(true)
    else
        setContent(win, title, value)
        win:bringToTop()
        Keys.onFocus(win)
    end
    return win
end

-- Only the window that is really on screen for this owner and key. A reply that came back after
-- the admin closed the window is answered with false and changes nothing.
function D.update(owner, key, title, value)
    local win = D.window
    if win == nil or not win:getIsVisible() then return false end
    if win.detailOwner ~= owner or win.detailKey ~= key then return false end
    setContent(win, title, value)
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

-- What is on screen, unwrapped -- the very value CopyAll hands to the clipboard. nil when this
-- owner has no window open.
function D.text(owner)
    if not D.isOpen(owner) then return nil end
    return D.window.rawText
end

return D
