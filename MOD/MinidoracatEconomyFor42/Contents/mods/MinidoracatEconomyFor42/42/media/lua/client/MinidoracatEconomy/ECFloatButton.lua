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
local ICON_PATH = EC.CURRENCIES.survivor.iconDefault -- shipped 64 px texture; text fallback if it fails to load
local TEXT = { r = 1, g = 0.85, b = 0.4, a = 1 }
local BADGE = 18                                          -- pending-mail bubble, top right corner
local BADGE_FILL = { r = 0.72, g = 0.16, b = 0.14, a = 1 }
local BADGE_RIM = { r = 1, g = 0.55, b = 0.5, a = 1 }

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
    -- Pending mailbox items: the bubble is the only hint a player gets while every window is
    -- closed. Drawn, not a texture: it has to carry the number. U.init may not have run yet
    -- (the panel is built on first open), so nothing here may touch the UI toolkit.
    local n = math.floor(tonumber(C.unclaimed) or 0)
    if n <= 0 then return end
    local label = n > 99 and "99+" or tostring(n)
    local tm = getTextManager()
    local w = math.max(BADGE, tm:MeasureStringX(UIFont.Small, label) + 8)
    local x, y = btn.width - w - 1, 1
    btn:drawRect(x, y, w, BADGE, BADGE_FILL.a, BADGE_FILL.r, BADGE_FILL.g, BADGE_FILL.b)
    btn:drawRectBorder(x, y, w, BADGE, BADGE_RIM.a, BADGE_RIM.r, BADGE_RIM.g, BADGE_RIM.b)
    btn:drawTextCentre(label, x + w / 2, y + math.floor((BADGE - tm:getFontHeight(UIFont.Small)) / 2),
        1, 1, 1, 1, UIFont.Small)
end

-- Re-read every frame by the framework's tooltip pass: pending mail outranks the plain label.
function F.tooltip()
    local n = math.floor(tonumber(C.unclaimed) or 0)
    if n > 0 then return getText("IGUI_MinidoracatEconomy_Float_TooltipMail", tostring(n)) end
    return getText("IGUI_MinidoracatEconomy_Float_Tooltip")
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
        getTooltip = F.tooltip,
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
