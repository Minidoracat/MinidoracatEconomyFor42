-- MinidoracatEconomyFor42 — floating entry button (client), thin wrapper over
-- MinidoracatUI.v1.FloatButton (capability probe; no framework -> no button, the hotkey still works).
-- Position persists through ISLayoutManager (layout.ini): saved the moment a drag is released,
-- and re-applied per resolution when the screen size changes.

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
local BADGE_FILL = { r = 0.85, g = 0.2, b = 0.2, a = 1 }  -- the vanilla "unread" red
local BADGE_RIM = { r = 1, g = 1, b = 1, a = 1 }

-- Default slot: right edge, one button below the NoticeBoard one. Shared by the first build and
-- by "this resolution has no record yet", so a new screen lands where a fresh install would.
local function defaultX() return getCore():getScreenWidth() - SIZE - RIGHT_MARGIN end
local function defaultY() return math.floor(getCore():getScreenHeight() / 2 + SIZE) end

local function framework()
    local ui = MinidoracatUI and MinidoracatUI.v1
    if ui and ui.API_MAJOR == 1 and ui.CAPABILITIES and ui.CAPABILITIES.floatButton == true then
        return ui
    end
    return nil
end

-- The bubble is drawn round through the framework's dot texture (Skin.dot) when the toolkit is
-- there. This runs before the panel exists, so C.UI (U.init) may not have run: probe
-- MinidoracatUI.v1.Skin directly, and fall back to the square drawRect bubble without it.
local function skin()
    local ui = MinidoracatUI and MinidoracatUI.v1
    if ui and ui.API_MAJOR == 1 and ui.Skin then return ui.Skin end
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
    -- closed. Drawn, not a texture: it has to carry the number. One digit is a circle, two or
    -- more widen it into a pill so the number keeps its 4 px of air on both sides.
    local n = math.floor(tonumber(C.unclaimed) or 0)
    if n <= 0 then return end
    local label = n > 99 and "99+" or tostring(n)
    local tm = getTextManager()
    local fh = tm:getFontHeight(UIFont.Small)
    local size = math.max(BADGE, fh + 6)
    local w = math.max(size, tm:MeasureStringX(UIFont.Small, label) + 8)
    local x, y = btn.width - w - 1, 1
    local S = skin()
    if S and w <= size then
        S.dot(btn, x, y, size, BADGE_FILL, BADGE_RIM)
    elseif S then
        S.fill(btn, x, y, w, size, BADGE_FILL, "pill")
        S.border(btn, x, y, w, size, BADGE_RIM, "pill")
    else
        btn:drawRect(x, y, w, size, BADGE_FILL.a, BADGE_FILL.r, BADGE_FILL.g, BADGE_FILL.b)
        btn:drawRectBorder(x, y, w, size, BADGE_RIM.a, BADGE_RIM.r, BADGE_RIM.g, BADGE_RIM.b)
    end
    btn:drawTextCentre(label, x + w / 2, y + math.floor((size - fh) / 2), 1, 1, 1, 1, UIFont.Small)
end

-- Re-read every frame by the framework's tooltip pass: pending mail outranks the plain label.
function F.tooltip()
    local n = math.floor(tonumber(C.unclaimed) or 0)
    if n > 0 then return getText("IGUI_MinidoracatEconomy_Float_TooltipMail", tostring(n)) end
    return getText("IGUI_MinidoracatEconomy_Float_Tooltip")
end

-- Reject non-finite saved coordinates; the widget clamps finite out-of-bounds values.
local function coord(value)
    local number = tonumber(value)
    if number and number == number and number ~= math.huge and number ~= -math.huge then
        return number
    end
    return nil
end

-- ISLayoutManager calls funcs.RestoreLayout(target, name, layout) / funcs.SaveLayout(target, ...)
-- on the table passed to RegisterWindow (ISLayoutManager.lua:6-13, 99-113), so these live on F.
-- Coordinates only: visibility is this mod's own policy (MP-client gate, hotkey, panel state), and
-- a layout restore that re-showed the button would undo whatever the player just hid.
function F.RestoreLayout(button, name, layout)
    local x, y = coord(layout.x), coord(layout.y)
    if x and y then button:setPosition(x, y) end
end

function F.SaveLayout(button, name, layout)
    layout.x = button:getX()
    layout.y = button:getY()
    layout.visible = nil -- visibility belongs to the consumer, not the saved layout
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
        x = defaultX(),
        y = defaultY(),
        colors = { surface = theme.colors.surface, hover = theme.colors.hover, border = theme.colors.border },
        drawContent = drawContent,
        onClick = function() C.Panel.toggle() end,
        getTooltip = F.tooltip,
        -- Save the layout only; do not broadcast the OnPostSave event to other listeners.
        onMoved = ISLayoutManager.OnPostSave,
    })
    local ok, tex = pcall(getTexture, ICON_PATH)
    button.icon = (ok and tex) or nil

    F.instance = button
    ISLayoutManager.RegisterWindow(LAYOUT_NAME, F, button) -- TryRestore runs inside
    button:setVisible(true)
    return button
end

-- Core.java:2242-2262 updates dimensions before this event. Restore without showing or writing.
function F.onResolutionChange()
    local button = F.instance
    if not button then return end
    button:setPosition(defaultX(), defaultY()) -- fallback when this resolution has no record
    ISLayoutManager.TryRestore(LAYOUT_NAME)
end

local function onGameStart()
    if not isClient() then return end
    F.ensure()
end
Events.OnGameStart.Add(onGameStart)
Events.OnCreatePlayer.Add(function(playerNum)
    if playerNum == 0 then onGameStart() end
end)
Events.OnResolutionChange.Add(F.onResolutionChange)

return F
