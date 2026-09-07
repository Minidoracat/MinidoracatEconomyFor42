-- MinidoracatEconomyFor42 - client-side preferences (PZAPI.ModOptions, per player, saved by the
-- engine into ModOptions.ini; the main-menu "Mod Options" page shows them too).
--
--   ToastSeconds   how long a notification stays (2-10 s, default 5)
--   PanelOpacity   opacity of the economy window's chrome (30-100 %, default 100); the slider in
--                  the window's title row writes the same option (and saves it at once)
--
-- Engine: PZAPI/ModOptions.lua (client) - create/addSlider/getOption/getValue/setValue/save;
-- the MiniMap does the same for its own knobs.

if not MinidoracatEconomy then require "MinidoracatEconomy/ECCore" end
local EC = MinidoracatEconomy
EC.Options = EC.Options or {}
local O = EC.Options

O.TOAST_MIN, O.TOAST_MAX, O.TOAST_DEFAULT = 2, 10, 5
O.OPACITY_MIN, O.OPACITY_MAX, O.OPACITY_DEFAULT = 30, 100, 100

local options = nil

local function option(id)
    if not options then return nil end
    local ok, opt = pcall(function() return options:getOption(id) end)
    if ok then return opt end
    return nil
end

local function number(id, fallback, lo, hi)
    local opt = option(id)
    local v = opt and tonumber(opt:getValue()) or nil
    if v == nil then return fallback end
    if v < lo then v = lo elseif v > hi then v = hi end
    return v
end

-- Seconds a toast holds on screen (the panel's preference popover edits it).
function O.toastSeconds()
    if not options then return O.fallbackToast or O.TOAST_DEFAULT end
    return number("ToastSeconds", O.TOAST_DEFAULT, O.TOAST_MIN, O.TOAST_MAX)
end

function O.toastHoldMs()
    return O.toastSeconds() * 1000
end

-- Panel chrome opacity, 0.3..1.
function O.panelOpacity()
    return number("PanelOpacity", O.OPACITY_DEFAULT, O.OPACITY_MIN, O.OPACITY_MAX) / 100
end

local function apply()
    local C = EC.Client
    if C and C.UI and C.UI.setAlpha then C.UI.setAlpha(O.panelOpacity()) end
end

-- The title-row slider: percent 30..100, applied at once; saved through the engine unless
-- deferSave (a drag in progress: ModOptions:save writes the ini, once per mouse-up is enough).
local dirty = false
function O.setPanelOpacity(percent, deferSave)
    local v = math.floor((tonumber(percent) or O.OPACITY_DEFAULT) + 0.5)
    if v < O.OPACITY_MIN then v = O.OPACITY_MIN elseif v > O.OPACITY_MAX then v = O.OPACITY_MAX end
    local opt = option("PanelOpacity")
    if opt then
        pcall(function() opt:setValue(v) end)
        dirty = true
        if not deferSave then O.flush() end
    else
        O.fallbackOpacity = v
    end
    apply()
end

function O.setToastSeconds(seconds, deferSave)
    local v = math.floor((tonumber(seconds) or O.TOAST_DEFAULT) + 0.5)
    if v < O.TOAST_MIN then v = O.TOAST_MIN elseif v > O.TOAST_MAX then v = O.TOAST_MAX end
    local opt = option("ToastSeconds")
    if opt then
        pcall(function() opt:setValue(v) end)
        dirty = true
        if not deferSave then O.flush() end
    else
        O.fallbackToast = v
    end
end

function O.flush()
    if not dirty then return end
    dirty = false
    pcall(function() PZAPI.ModOptions:save() end)
end

if PZAPI and PZAPI.ModOptions then
    options = PZAPI.ModOptions:create("MinidoracatEconomy", "UI_MinidoracatEconomy_Options")
    options:addSlider("ToastSeconds", "UI_MinidoracatEconomy_ToastSeconds", O.TOAST_MIN, O.TOAST_MAX, 1, O.TOAST_DEFAULT,
        "UI_MinidoracatEconomy_ToastSeconds_tooltip")
    options:addSlider("PanelOpacity", "UI_MinidoracatEconomy_PanelOpacity", O.OPACITY_MIN, O.OPACITY_MAX, 5, O.OPACITY_DEFAULT,
        "UI_MinidoracatEconomy_PanelOpacity_tooltip")
    options.apply = apply   -- the options screen calls this after "Accept"
end

-- No ModOptions (stub / very old build): the slider still works for the session.
if not options then
    O.panelOpacity = function() return (O.fallbackOpacity or O.OPACITY_DEFAULT) / 100 end
end

Events.OnGameStart.Add(apply)
return O
