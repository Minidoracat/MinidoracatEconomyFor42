-- MinidoracatEconomyFor42 - the drop target a window shows while items are dragged out of an
-- inventory window (client). Adds exactly one namespace: C.ItemDrop.
--
-- Vanilla's drag is two globals the inventory pane sets on mouse down (ISInventoryPane.lua:
-- 1712-1723): ISMouseDrag.dragging (its rows: items, or groups whose first entry is a dummy) and
-- ISMouseDrag.draggingFocus (the pane it started in). A receiver reads them in its own onMouseUp
-- and leaves the clearing to the source pane, which drops the items on the floor only when the
-- pointer is over no UI at all (ISInventoryPane.lua:1882-1953); ISItemSlot.lua:342-373 is the
-- vanilla receiver this follows. The engine offers a mouse-up to the topmost child under the
-- pointer first (UIElement.java:1282-1330), so every frame of a drag the layer puts itself over its
-- siblings with the parent's immediate BringToTop, as ModalGuard does (UIElement.java:1691-1694).
--
--   C.ItemDrop.new(judge, drop)
--       an ISPanel the host adds as a child. Every frame the host calls layer:sync(x, y, w, h) -
--       or layer:sync(nil) where it takes no drop - from its render, after its own layout has
--       raised whatever it raises: the layer covers that rectangle while a drag from an inventory
--       pane is under way and hides otherwise. Nothing else drives it: no Events, no timer.
--       judge(items) -> { ok = bool, text = string, item = InventoryItem? } says what releasing
--       here would do. It is asked when the drag starts and twice a second while it lasts (the
--       page under it can change), and once more on release; drop(items) runs only when that
--       last answer is ok, after the host's top-level window has taken focus (its onFocus).
--       items are the dragged InventoryItems (groups flattened).
-- Colour, the item's icon and a sentence carry the outcome together; nothing moves or blinks.

require "ISUI/ISPanel"
require "MinidoracatEconomy/ECWidgets"
require "MinidoracatEconomy/ECItemRoute"

local EC = MinidoracatEconomy
local C = EC.Client
local U = C.UI
local Route = C.ItemRoute

local D = {}
C.ItemDrop = D

local JUDGE_MS = 500
local ICON = 48

local Layer = ISPanel:derive("MinidoracatEconomyDropLayer")

function D.new(judge, drop)
    local o = ISPanel:new(0, 0, 10, 10)
    setmetatable(o, Layer)
    o.background = false
    o.judge, o.drop = judge, drop
    o:setVisible(false)
    return o
end

-- The rows of the drag under way when it came from an inventory pane, else nil.
local function dragRows()
    local rows, from = ISMouseDrag.dragging, ISMouseDrag.draggingFocus
    if rows == nil or from == nil or from.inventory == nil then return nil end
    return rows
end

function Layer:hide()
    if self:getIsVisible() then self:setVisible(false) end
end

function Layer:sync(x, y, w, h)
    local rows = dragRows()
    -- a drag released over this layer is finished here even if its pane has not cleared it yet
    if rows == nil or rows == self.spent or x == nil then
        if rows == nil then self.rows, self.items, self.state, self.spent = nil, nil, nil, nil end
        return self:hide()
    end
    if rows ~= self.rows then
        self.rows, self.items, self.judgedAt = rows, Route.items(rows), nil
    end
    if #self.items == 0 then return self:hide() end
    if self.x ~= x or self.y ~= y then self:setX(x); self:setY(y) end
    if self.width ~= w or self.height ~= h then self:setWidth(w); self:setHeight(h) end
    local t = getTimestampMs()
    if self.judgedAt == nil or t - self.judgedAt > JUDGE_MS then
        self.judgedAt = t
        self.state = self.judge(self.items)
    end
    if not self:getIsVisible() then self:setVisible(true) end
    -- every frame of the drag: the host may have raised a dialog or its backdrop since, and the
    -- release goes to whichever child is on top
    self.parent.javaObject:BringToTop(self.javaObject)
end

function Layer:onMouseUp()
    local items = self.items
    self.spent = self.rows
    self:hide()
    if items == nil or #items == 0 then return true end
    -- judged again: half a second is long enough for the page under the pointer to have moved
    local state = self.judge(items)
    if state and state.ok then
        -- the window taking the item comes forward, as one opened from the item menu does: the
        -- drag began with a mouse down on the inventory, which left that window over this one
        local root = self.parent
        while root.parent do root = root.parent end
        if root.onFocus then root:onFocus() end
        self.drop(items)
    end
    return true
end

function Layer:onMouseDown() return true end
function Layer:onMouseWheel() return true end
function Layer:onRightMouseDown() return true end
function Layer:onRightMouseUp() return true end

function Layer:prerender()
    local st = self.state
    if st == nil then return end
    local w, h, PAD = self.width, self.height, U.PAD
    local tone = U.color(st.ok and "accent" or "warn")
    local back = U.color("surface")
    -- the page stays faintly visible under the veil: the player still sees where they are
    self:drawRect(0, 0, w, h, 0.72, back.r, back.g, back.b)
    self:drawRectBorder(0, 0, w, h, 1, tone.r, tone.g, tone.b)
    self:drawRectBorder(1, 1, w - 2, h - 2, 1, tone.r, tone.g, tone.b)
    local cardW = math.max(1, math.min(w - PAD * 2, math.max(360, math.floor(w * 0.6))))
    local textW = math.max(1, cardW - ICON - PAD * 3)
    local lines = U.wrapText(st.text or "", textW, 4)
    local lineH = U.fontH.medium + 4
    local cardH = math.max(ICON, #lines * lineH) + PAD * 2
    local cx, cy = math.floor((w - cardW) / 2), math.floor((h - cardH) / 2)
    self:drawRect(cx, cy, cardW, cardH, 0.96, back.r, back.g, back.b)
    self:drawRectBorder(cx, cy, cardW, cardH, 1, tone.r, tone.g, tone.b)
    local tex = st.item and U.itemTexture(st.item:getFullType())
    if tex then
        local a = st.ok and 1 or 0.45
        self:drawTextureScaledAspect(tex, cx + PAD, cy + math.floor((cardH - ICON) / 2), ICON, ICON, a, 1, 1, 1)
    end
    local ty = cy + math.floor((cardH - #lines * lineH) / 2) + 2
    for i, line in ipairs(lines) do
        self:drawText(line, cx + PAD * 2 + ICON, ty + (i - 1) * lineH, tone.r, tone.g, tone.b, 1, UIFont.Medium)
    end
end

return D
