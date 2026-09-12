-- Native buttons inside pooled rows. The row body remains a separate read/selection action.
-- VirtualList clears a cell before rebinding: a held mouse press must not act on its next item.
require "MinidoracatEconomy/ECWidgets"
local C = MinidoracatEconomy.Client
local U = C.UI
local R = {}
C.RowActions = R
local EMPTY = {}

local function hide(button)
    button.pressed = false
    button.mouseOver = false
    button:setVisible(false)
    if button.tooltipUI then
        button.tooltipUI:setVisible(false)
        button.tooltipUI:removeFromUIManager()
    end
end

function R.reset(cell)
    for _, button in pairs(cell.ecRowButtons or EMPTY) do hide(button) end
    local active = cell.ecActiveButtons
    if active then for i = #active, 1, -1 do active[i] = nil end end
    cell.ecActionsEntry = nil
    cell.ecActionsRevision = nil
end

local function activate(cell, button)
    local list, entry = cell.list, cell.entry
    if not button.enable or not list or not entry or cell.ecActionsEntry ~= entry
        or cell.ecActionsRevision ~= list.revision or list.items[cell.index] ~= entry then return end
    if type(list.onRowAction) ~= "function" then return end
    list:setSelectedIndex(cell.index)
    list.onRowAction(list, entry, button.internal)
end

function R.begin(cell)
    if cell.ecActionsEntry ~= cell.entry or cell.ecActionsRevision ~= cell.list.revision then
        R.reset(cell)
    end
    cell.ecRowButtons = cell.ecRowButtons or {}
    cell.ecActiveButtons = cell.ecActiveButtons or {}
    cell.ecResetActions = R.reset
    cell.ecActionsEntry = cell.entry
    cell.ecActionsRevision = cell.list.revision
    cell.ecActionPass = (cell.ecActionPass or 0) + 1
    cell.ecActionCount = 0
end

function R.put(cell, id, label, x, y, width, height, enabled)
    local buttons = cell.ecRowButtons
    local button = buttons[id]
    local refit = not button or button.fullTitle ~= label or button.width ~= width
    if not button then
        button = U.Button.create(x, y, width, height, label, cell, activate, "chip")
        button.internal = id
        cell:addChild(button)
        buttons[id] = button
    end
    if button.x ~= x then button:setX(x) end
    if button.y ~= y then button:setY(y) end
    if button.width ~= width then button:setWidth(width) end
    if button.height ~= height then button:setHeight(height) end
    if refit then U.setButtonTitle(button, label) end
    button:setEnable(enabled == true)
    button.stateToken = enabled == true and "accent" or nil
    button:setVisible(true)
    button.ecSeenPass = cell.ecActionPass
    cell.ecActionCount = cell.ecActionCount + 1
    cell.ecActiveButtons[cell.ecActionCount] = button
    return button
end

function R.finish(cell)
    for _, button in pairs(cell.ecRowButtons) do
        if button.ecSeenPass ~= cell.ecActionPass then hide(button) end
    end
    for i = #cell.ecActiveButtons, cell.ecActionCount + 1, -1 do cell.ecActiveButtons[i] = nil end
end

function R.targets(list)
    if not list or not list:getIsVisible() then return EMPTY end
    local index = list:getSelectedIndex()
    local entry = list:getSelectedItem()
    if not index or not entry then return EMPTY end
    for _, cell in ipairs(list.pool or EMPTY) do
        if cell.index == index and cell.entry == entry and cell:getIsVisible()
            and cell.ecActionsEntry == entry and cell.ecActionsRevision == list.revision then
            return cell.ecActiveButtons or EMPTY
        end
    end
    return EMPTY
end

return R
