-- MinidoracatEconomyFor42 — floating entry button (client), thin wrapper over
-- MinidoracatUI.v1.FloatButton (capability probe; no framework -> no button, the hotkey still works).
-- Position persists through ISLayoutManager (layout.ini).

require "ISUI/ISLayoutManager"

if not MinidoracatEconomy or not MinidoracatEconomy.Client or not MinidoracatEconomy.Client.Panel then
    require "MinidoracatEconomy/ECPanel"
end
local EC = MinidoracatEconomy
local C = EC.Client

local F = {}
C.FloatButton = F

local LAYOUT_NAME = "MinidoracatEconomyFloatButton"
local SIZE = 40
local RIGHT_MARGIN = 8
local ICON_SIZE = 28
local ICON_PATH = EC.CURRENCIES.survivor.iconDefault -- shipped in stage B8; text fallback until then
local TEXT = { r = 1, g = 0.85, b = 0.4, a = 1 }

local function framework()
    local ui = MinidoracatUI and MinidoracatUI.v1
    if ui and ui.API_MAJOR == 1 and ui.CAPABILITIES and ui.CAPABILITIES.floatButton == true then
        return ui
    end
    return nil
end

local function drawContent(btn)
    if btn.icon then
        btn:drawTextureScaled(btn.icon, math.floor((btn.width - ICON_SIZE) / 2), math.floor((btn.height - ICON_SIZE) / 2),
            ICON_SIZE, ICON_SIZE, 1, 1, 1, 1)
    else
        local h = getTextManager():getFontHeight(UIFont.Medium)
        btn:drawTextCentre("$", btn.width / 2, (btn.height - h) / 2, TEXT.r, TEXT.g, TEXT.b, TEXT.a, UIFont.Medium)
    end
end

-- ISLayoutManager calls funcs.RestoreLayout(target, name, layout) / funcs.SaveLayout(target, ...)
-- on the table passed to RegisterWindow (ISLayoutManager.lua:6-13, 99-113), so these live on F.
function F.RestoreLayout(button, name, layout)
    local x, y = tonumber(layout.x), tonumber(layout.y)
    if x and y then button:setPosition(x, y) end
    button:setVisible(true)
end

function F.SaveLayout(button, name, layout)
    layout.x = button:getX()
    layout.y = button:getY()
    layout.visible = "true"
end

function F.ensure()
    if F.instance then
        F.instance:setVisible(true)
        return F.instance
    end
    local ui = framework()
    if not ui then return nil end
    local theme = ui.Theme.create()
    local button = ui.FloatButton.new({
        size = SIZE,
        x = getCore():getScreenWidth() - SIZE - RIGHT_MARGIN,
        y = math.floor(getCore():getScreenHeight() / 2 + SIZE), -- below the NoticeBoard button slot
        colors = { surface = theme.colors.surface, hover = theme.colors.hover, border = theme.colors.border },
        drawContent = drawContent,
        onClick = function() C.Panel.toggle() end,
        getTooltip = function() return getText("IGUI_MinidoracatEconomy_Float_Tooltip") end,
    })
    local ok, tex = pcall(getTexture, ICON_PATH)
    button.icon = (ok and tex) or nil

    F.instance = button
    ISLayoutManager.RegisterWindow(LAYOUT_NAME, F, button)
    button:setVisible(true)
    return button
end

local function onGameStart()
    if not isClient() then return end
    F.ensure()
end
Events.OnGameStart.Add(onGameStart)

return F
