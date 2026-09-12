-- MinidoracatEconomyFor42 -- shared account candidate picker (client). Adds exactly one
-- namespace: C.PlayerPicker.
--
--   C.PlayerPicker.create(owner, send, isPending, newRequestId, onPick, context, command) -> picker
--
-- One search box plus the candidate list that drops out of it, hosted inside whichever page asked
-- for it (the admin player page, the money page). It owns no transport and no Events hook of its
-- own: the host hands it the very send / isPending / newRequestId the rest of that window already
-- uses, so the candidate read shares the one in-flight admin.players slot and the one client
-- cooldown instead of opening a scan of its own.
--
--   picker:setText(s) / :getText()      the box, trimmed on the way out
--   picker:setVisible(v)                hides the box and folds the list away
--   picker:setEditable(v)               a read-only role still sees the box, greyed
--   picker:layout(x, y, w, maxH)        the box at (x, y, w); the list drops below it, capped
--                                       to maxH so it can never run past the page
--   picker:anchorDrop(maxH)             the host placed the box itself (a wrapping row placer):
--                                       the list is re-hung under wherever the box ended up
--   picker:tick(now)                    the debounce clock, the focus-driven first read and the
--                                       list's own geometry; the host calls it while its page is up
--   picker:onReply(args) -> bool        true when this picker owned the reply (context and the
--                                       requestId it is still waiting for)
--   picker:owns(args) -> bool           the same match without consuming it: the host asks before
--                                       it releases the shared command slot
--   picker:keyboardTargets()            the box, and the list while it is open
--   picker:close() / :dispose()
--
-- `context` travels with every request and comes back on the reply, so two pickers may share one
-- command without ever reading each other's answer. Four are known: "player" / "transactions"
-- (the admin account box) and "market" / "auction" (the seller box). `command` is the read the
-- box sends -- "admin.players" by default, "market.sellers" for the public seller candidates
-- every player may ask for -- and it is also the key `isPending` is asked about, so the box
-- shares its host's one in-flight slot for that command.
--
-- Engine references (snapshot 42.20.4-20260826):
--   ISTextEntryBox  ISUI/ISTextEntryBox.lua:321-341 (new -> initialise -> instantiate),
--                   isFocused :152-154, unfocus :140-150
--   the list is a plain painted panel with the six members C.Keyboard's "list" descriptor reads
--   (items / rowHeight / padding / height / getSelectedIndex / setSelectedIndex / onSelect), so
--   Tab reaches the candidates and the arrows walk them without a VirtualList behind eight rows.

require "ISUI/ISPanel"

if not MinidoracatEconomy or not MinidoracatEconomy.Client or not MinidoracatEconomy.Client.UI then
    require "MinidoracatEconomy/ECWidgets"
end
local EC = MinidoracatEconomy
local C = EC.Client
local U = C.UI

local P = {}
C.PlayerPicker = P

local PAD, T = U.PAD, U.T
local fontH = U.fontH
local fill, border, text, textRight = U.fill, U.border, U.text, U.textRight
local textWidth, fitText, amountText = U.textWidth, U.fitText, U.amountText
local newEntry, entryText, setEntryText, setEntryEditable = U.newEntry, U.entryText, U.setEntryText, U.setEntryEditable

local DEBOUNCE_MS = 250    -- keystrokes are coalesced; the server throttles the command as well
local ROWS_MAX = 8         -- rows the list ever draws, the "type more" line included
local MIN_W = 260
local USERNAME_MAX = 64
local EMPTY = {}

-- What the box calls itself, per context: the admin pages ask for an account, the market and the
-- auction pages for a seller. The labels are the only thing the two uses differ in.
local ACCOUNT_LABELS = { hint = "Admin_Player_Hint", account = "Admin_Player_Account",
    candidates = "Admin_Player_Candidates" }
local SELLER_LABELS = { hint = "Market_Seller_Hint", account = "Market_Seller",
    candidates = "Market_Seller_Candidates" }
local CONTEXTS = {
    player = ACCOUNT_LABELS, transactions = ACCOUNT_LABELS,
    market = SELLER_LABELS, auction = SELLER_LABELS,
}

local function tr(key) return getText(T .. key) end
local function rowH() return math.max(26, fontH.small + 12) end
local function entryH() return math.max(26, fontH.small + 12) end

-- ---------- the dropped list ----------
--
-- Owns no data: the rows are the reply the picker is holding and the row plan it computed in
-- refresh(), so this child only paints and turns a press into a pick. It is added last, which puts
-- it over every sibling without a per-frame bringToTop (that reorders the parent's child list).

local Drop = ISPanel:derive("MinidoracatEconomyPlayerPickerDrop")

function Drop:rowAt(y)
    local i = math.floor((y - 1) / rowH()) + 1
    if i < 1 or i > (self.shown or 0) then return nil end
    return self.items[i]
end

function Drop:getSelectedIndex() return self.selectedIndex end

function Drop:setSelectedIndex(index)
    if type(index) ~= "number" or index < 1 or (self.shown or 0) < 1 then
        self.selectedIndex = nil
    else
        self.selectedIndex = math.min(math.floor(index), self.shown)
    end
end

function Drop:prerender()
    local w, h = self.width, self.height
    fill(self, 0, 0, w, h, "surface")
    border(self, 0, 0, w, h, "accent")
    local rh = rowH()
    local hover = self:isMouseOver() and (math.floor(self:getMouseY() / rh) + 1) or 0
    local online = tr("Admin_Player_Online")
    local onlineW = textWidth(online) + PAD
    local shown = self.shown or 0
    local y = 1
    for i = 1, shown do
        local p = self.items[i]
        if hover == i or self.selectedIndex == i then fill(self, 1, y, w - 2, rh, "selected", "rect") end
        local ty = y + math.floor((rh - fontH.small) / 2)
        local showOnline = p.online and w - PAD * 2 - onlineW >= fontH.small * 3
        text(self, fitText(tostring(p.username), w - PAD * 2 - (showOnline and onlineW or 0)), PAD, ty, "text")
        if showOnline then textRight(self, online, w - PAD, ty, "accent") end
        y = y + rh
    end
    local note = nil
    if self.more then
        note = self.truncated and tr("Admin_Players_Partial")
            or getText(T .. "Admin_Players_More", amountText(math.max(0, (self.total or shown) - shown)))
    elseif self.empty then
        note = tr("Admin_Players_Empty")
    end
    if note then
        text(self, fitText(note, w - PAD * 2), PAD, y + math.floor((rh - fontH.small) / 2), "textFaint")
    end
end

function Drop:render() end

function Drop:onMouseDown(x, y)
    local p = self:rowAt(y)
    if p then self.picker:pick(p) end
    return true
end

function Drop:onMouseUp(x, y) return true end

-- ---------- the picker ----------

local Picker = {}
Picker.__index = Picker

-- Every programmatic write of the box goes through here: `seenText` is what tick() compares the
-- box against to catch an IME commit, so a text this picker put there itself must never read as
-- something the player typed.
local function setBoxText(o, value)
    setEntryText(o.entry, value)
    o.seenText = o:getText()
end

function Picker:setText(value)
    setBoxText(self, value)
    self.sentQuery = nil     -- the host replaced the text: the next tick asks for it
end

function Picker:getText()
    return string.match(entryText(self.entry), "^%s*(.-)%s*$")
end

function Picker:setVisible(visible)
    self.shownOnPage = visible == true
    self.entry:setVisible(self.shownOnPage)
    if not self.shownOnPage then
        if self.entry:isFocused() then self.entry:unfocus() end
        self:close()
    end
end

function Picker:setEditable(editable)
    self.editable = editable ~= false
    setEntryEditable(self.entry, self.editable)
    if not self.editable then self:close() end
end

function Picker:layout(x, y, w, maxH)
    self.entry:setX(x)
    self.entry:setY(y)
    self.entry:setWidth(w)
    self.entry:setHeight(entryH())
    self:anchorDrop(maxH)
end

-- The box is already where the host wants it (a wrapping row placer moved it): hang the list
-- under it and cap it to maxH so it can never run past the page.
function Picker:anchorDrop(maxH)
    self.dropMaxH = math.max(0, maxH or 0)
    self.drop:setX(self.entry.x)
    self.drop:setY(self.entry.y + self.entry.height)
    self.drop:setWidth(math.max(MIN_W, self.entry.width))
    self:refresh()
end

-- Forget the candidates: a pick, Escape, a page switch and a permission collapse all invalidate
-- them, and the next focus asks again.
function Picker:close()
    self.open = false
    self.candidates = nil
    self.total = nil
    self.truncated = nil
    self.sentQuery = nil
    self.sentRequestId = nil
    self.queryAt = nil
    self.drop.items = EMPTY
    self.drop.shown = 0
    self.drop.selectedIndex = nil
    self.drop:setVisible(false)
end

function Picker:pick(entry)
    if type(entry) ~= "table" or type(entry.username) ~= "string" or entry.username == "" then return end
    setBoxText(self, entry.username)
    pcall(self.entry.unfocus, self.entry)
    self:close()
    self.onPick(entry)
end

-- Row plan and geometry. Called per frame from tick, so it only does arithmetic: no row tables,
-- no text measuring, and no bringToTop (the panel is the last child its host added).
function Picker:refresh()
    local drop = self.drop
    local rh = rowH()
    local cap = math.min(ROWS_MAX, math.floor(self.dropMaxH / rh))
    local list = self.candidates
    local shown, more, empty = 0, false, false
    if list and cap > 0 then
        local n = #list
        if n == 0 then
            empty = self.sentQuery ~= nil and self.sentQuery ~= ""
        else
            shown = math.min(n, cap)
            local total = tonumber(self.total) or n
            more = shown < n or total > n or self.truncated == true
            if more and shown >= cap then shown = cap - 1 end
        end
    end
    -- the keyboard's page step reads these two off the panel: rowH() follows the UI font, so the
    -- stride is refreshed here instead of staying at whatever it was when the list was built
    drop.rowHeight = rh
    drop.items = list or EMPTY
    drop.shown = shown
    drop.more = more
    drop.truncated = self.truncated == true
    drop.empty = empty
    drop.total = tonumber(self.total) or shown
    if drop.selectedIndex ~= nil and drop.selectedIndex > shown then drop.selectedIndex = nil end
    local rows = shown + ((more or empty) and 1 or 0)
    local visible = rows > 0 and self.open == true and self.shownOnPage == true
        and self.editable ~= false and (self.focused == true or drop:isMouseOver()
            or (C.Keyboard and C.Keyboard.isKeyboardFocused(drop)))
    drop:setVisible(visible)
    if visible then drop:setHeight(rows * rh + 2) end
end

-- Debounce clock, the focus-driven first read and the list's visibility.
function Picker:tick(now)
    if not self.shownOnPage then return end
    -- An IME commit can land in the box without the text-change callback ever firing (the rule
    -- the panel's own keyword boxes follow), so the text is read back here as well: one string
    -- compare per frame, and nothing happens at all while it stands still.
    local raw = self:getText()
    if raw ~= self.seenText then
        self.seenText = raw
        self:onTextChanged()
    end
    local focused = false
    local ok, v = pcall(self.entry.isFocused, self.entry)
    if ok and v == true then focused = true end
    if focused and not self.focused then
        self.open = true
        -- nothing cached yet: an empty query lists whoever is online
        if self.candidates == nil then self.queryAt = now - DEBOUNCE_MS end
    end
    self.focused = focused
    local at = self.queryAt
    -- a query still in flight is left to finish: nothing is measured, cut or allocated per frame
    if at and now - at >= DEBOUNCE_MS and not self.isPending(self.command) then
        if raw == self.sentQuery and self.candidates ~= nil then
            self.queryAt = nil
        else
            local id = self.newRequestId()
            if self.send(self.command, { query = raw, requestId = id, context = self.context }) then
                self.sentQuery = raw
                self.sentRequestId = id
                self.queryAt = nil
            end
        end
    end
    self:refresh()
end

-- A keystroke only arms the debounce; the request itself goes out from tick, so a fast typist
-- costs one command per DEBOUNCE_MS instead of one per key.
function Picker:onTextChanged()
    self.queryAt = EC.now()
    self.seenText = self:getText()
    self.open = true
    if self:getText() ~= self.sentQuery then
        self.candidates, self.total, self.truncated = nil, nil, nil
        self.drop.selectedIndex = nil
        self:refresh()
    end
end

-- Is the candidate list actually dropped? The host asks before it answers Escape with something
-- of its own, so the list folds first and the page behind it is left alone.
function Picker:isOpen()
    return self.drop:getIsVisible() == true
end

-- The reply this picker is still waiting for: its own context, and the requestId it sent. Asked
-- (without consuming) by the host before it releases the shared command slot.
function Picker:owns(args)
    if type(args) ~= "table" then return false end
    if tostring(args.context or "") ~= self.context then return false end
    return self.sentRequestId ~= nil and args.requestId == self.sentRequestId
end

function Picker:onReply(args)
    if not self:owns(args) then return false end
    self.sentRequestId = nil
    if self:getText() ~= self.sentQuery then
        self.candidates, self.total, self.truncated = nil, nil, nil
        self:refresh()
        return true
    end
    -- a refusal is silent: the candidate list is a convenience, never a result
    if args.ok == false then
        self.sentQuery = nil
        return true
    end
    self.candidates = type(args.players) == "table" and args.players or {}
    self.total = tonumber(args.total) or #self.candidates
    self.truncated = args.truncated == true
    self:refresh()
    return true
end

-- The answer is never coming: the same text may be asked for again.
function Picker:onTimeout()
    self.sentQuery = nil
    self.sentRequestId = nil
    if self.open and self.shownOnPage and self.editable ~= false and (self.focused or self:isOpen()) then
        self.queryAt = EC.now()
    end
end

function Picker:keyboardTargets()
    local out = { { kind = "entry", label = tr(self.labels.account), control = self.entry } }
    if self.drop:getIsVisible() then
        out[2] = { kind = "list", label = tr(self.labels.candidates), control = self.drop }
    end
    return out
end

function Picker:dispose()
    self:close()
    pcall(self.entry.unfocus, self.entry)
end

-- ---------- module API ----------

-- owner: the page that hosts this picker. Both children are added to it (the list last, so it
-- paints over the rows behind it); the owner positions them through layout() and drives the clock
-- through tick(). No command is sent here.
function P.create(owner, send, isPending, newRequestId, onPick, context, command)
    local o = setmetatable({}, Picker)
    o.owner = owner
    o.send, o.isPending, o.newRequestId = send, isPending, newRequestId
    o.onPick = onPick
    o.context = CONTEXTS[context] and context or "player"
    o.labels = CONTEXTS[o.context]
    -- the public seller candidates and the admin account candidates are the same box over two
    -- commands; nothing else in here knows the difference
    o.command = command == "market.sellers" and "market.sellers" or "admin.players"
    o.editable = true
    o.shownOnPage = false
    o.dropMaxH = 0
    o.seenText = ""
    o.entry = newEntry(180, entryH(), { maxLen = USERNAME_MAX, clear = true,
        placeholder = tr(o.labels.hint) })
    o.entry.target = o
    o.entry.onTextChangeFunction = Picker.onTextChanged
    o.entry:setVisible(false)
    owner:addChild(o.entry)

    local drop = ISPanel:new(0, 0, MIN_W, rowH())
    setmetatable(drop, Drop)
    drop.background = false
    drop.picker = o
    drop.items = {}
    drop.shown = 0
    drop.rowHeight = rowH()
    drop.padding = 0
    drop.onSelect = function(_, item) o:pick(item) end
    drop:initialise()
    drop:setVisible(false)
    o.drop = drop
    owner:addChild(drop)
    return o
end

return P
