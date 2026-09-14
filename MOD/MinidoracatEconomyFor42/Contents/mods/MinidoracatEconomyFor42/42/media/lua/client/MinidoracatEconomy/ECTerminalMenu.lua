-- MinidoracatEconomyFor42 - terminal right-click menu (client; stage C thin slice, stage A11/A18).
--
-- On a registered terminal square everyone gets "use terminal" (opens the economy center on the
-- shop tab), and on a trade terminal everyone also gets the radio note: what the station is
-- tuned to, whether it picks voices up at all, and every native limit that decides whether a
-- word actually leaves the tile. Admins additionally get "register as ATM" / "register as trade
-- station" on a square that carries an allowed terminal tile (EC.TERMINAL_SPRITES) and
-- "unregister" on a registered one; the server re-validates all of them (ECTerminal.register /
-- unregister). Changing the kind of a square is unregister then register, exactly as before --
-- there is no "set kind" call. getAccessLevel is a client-only read of the connection
-- (LuaManager.java:4435-4436); OnFillWorldObjectContextMenu: LuaEventManager.java:619-620.
--
-- What this file may and may not claim about the radio: the note is a reading of what the server
-- last told the client (C.radio, the terminal's own radioState) plus the engine's own rules. It
-- is never a promise that somebody heard anything, and the device-panel guard below is a
-- courtesy that keeps a player out of a window that would offer to retune the market's radio --
-- not a lock. The server owns the device and repairs it.

if not MinidoracatEconomy or not MinidoracatEconomy.Client or not MinidoracatEconomy.Client.Panel then
    require "MinidoracatEconomy/ECPanel"
end
-- the shared module that says which IsoRadio is the economy's own (server author's file): the
-- client only ever consumes EC.TradeRadio.isOwned
if not MinidoracatEconomy.TradeRadio then
    require "MinidoracatEconomy/ECTradeRadio"
end
require "MinidoracatEconomy/ECAtmProtection"
local EC = MinidoracatEconomy
local C = EC.Client
local P = C.Panel
local T = "IGUI_MinidoracatEconomy_"

-- The server maps RadioRange=0 to 100000, covering native signed-short radio coordinates.
-- This is the mod's mapping, not a DeviceData maximum.
local RELAY_RANGE_UNLIMITED = 100000

local function isAdmin()
    local ok, level = pcall(getAccessLevel)
    return ok and level == "admin"
end

local function spriteName(o)
    local ok, name = pcall(function() return o:getSprite():getName() end)
    return ok and name or nil
end

local function hasTerminalTile(square, worldobjects)
    for _, o in ipairs(worldobjects or {}) do
        local name = spriteName(o)
        if name and EC.TERMINAL_SPRITES[name] then return true end
    end
    local ok, found = pcall(function()
        local objects = square:getObjects()
        for i = 0, objects:size() - 1 do
            local name = spriteName(objects:get(i))
            if name and EC.TERMINAL_SPRITES[name] then return true end
        end
        return false
    end)
    return ok and found == true
end

local function useTerminal()
    local win = P.instance()
    if not win then return end
    win:setVisible(true)
    if win.setTab then win:setTab("Shop") end
end

-- ---------- the radio note ----------

local function tr(key, ...) return getText(T .. key, ...) end

-- 101100 -> "101.1", the same reading the settings page paints for a "mhz" option.
local function mhz(frequency)
    return tostring(frequency / 1000)
end

-- One line per fact the server really sent, then the block of native rules that no setting of
-- this mod can change. A fact that never arrived is left out instead of being guessed at, and
-- nothing here turns a switch that is on into "you were heard".
local function radioLines(terminal)
    local lines = { tr("Terminal_Radio_Locked") }
    local info = C.radio
    if type(info) ~= "table" then
        lines[#lines + 1] = tr("Terminal_Radio_Unknown")
        return lines
    end
    local frequency = tonumber(info.frequency)
    if frequency then lines[#lines + 1] = tr("Terminal_Radio_Freq", mhz(frequency), tr("Radio_Channel")) end
    local relay = info.relayEnabled == true
    lines[#lines + 1] = relay and tr("Terminal_Radio_Relay_On") or tr("Terminal_Radio_Relay_Off")
    local range = tonumber(info.range)
    if relay and range then
        lines[#lines + 1] = range >= RELAY_RANGE_UNLIMITED and tr("Terminal_Radio_Range_Max")
            or tr("Terminal_Radio_Range", tostring(math.floor(range)))
    end
    lines[#lines + 1] = info.summaryEnabled == true and tr("Terminal_Radio_Summary_On") or tr("Terminal_Radio_Summary_Off")
    -- this one station, as of the last terminal list: 'disabled' | 'active' | 'waiting' | 'error'.
    -- An older server that sends no state simply adds no line.
    local state = terminal ~= nil and terminal.radioState or nil
    if type(state) == "string" then
        local text = getTextOrNull(T .. "Terminal_Radio_State_" .. state)
        if text then lines[#lines + 1] = text end
    end
    lines[#lines + 1] = tr("Terminal_Radio_Limits")
    return lines
end

-- Use the existing scrollable reader; a tall native tooltip has no scrolling or keyboard path.
local function showRadioInfo(terminal)
    local owner = P.instance()
    if not owner or owner:isModal() then return end
    owner:setVisible(true)
    owner.detailList = nil
    C.DetailWindow.open(owner, "radio:" .. tostring(terminal.id), tr("Terminal_Radio_Name"),
        table.concat(radioLines(C.terminalAt(terminal.x, terminal.y, terminal.z) or terminal), "\n"))
end

local function addRadioOption(context, terminal)
    local option = context:addOption(tr("Terminal_Radio"), terminal, showRadioInfo)
    local tip = ISWorldObjectContextMenu.addToolTip()
    tip:setVisible(false)
    tip:setName(tr("Terminal_Radio_Name"))
    local info = C.radio
    tip.description = (type(info) == "table"
        and tr(info.relayEnabled == true and "Terminal_Radio_Relay_On" or "Terminal_Radio_Relay_Off")
        or tr("Terminal_Radio_Unknown")) .. "\n" .. tr("Terminal_Radio_Open")
    tip.maxLineWidth = 512
    option.toolTip = tip
end

local function onFillMenu(playerNum, context, worldobjects, test)
    if test or not isClient() then return end
    local square = nil
    for _, o in ipairs(worldobjects) do
        local ok, sq = pcall(function() return o:getSquare() end)
        if ok and sq then
            square = square or sq
            if EC.isAtmSquare(sq) then square = sq break end
        end
    end
    if not square then return end
    local x, y, z = square:getX(), square:getY(), square:getZ()
    local terminal = C.terminalAt(x, y, z)
    if terminal or EC.isAtmSquare(square) then
        -- Explicit registrations keep their existing actions and radio information.
        context:addOption(getText(T .. "Terminal_Use"), nil, useTerminal)
        -- everyone reads the radio of a trade station, admin or not: whether it is listening is
        -- exactly what a player standing next to it needs to know before speaking
        if terminal and terminal.kind == "trade" then addRadioOption(context, terminal) end
    end
    if isAdmin() then
        local tile = hasTerminalTile(square, worldobjects)
        if terminal then
            context:addOption(getText(T .. "Terminal_Unregister"), nil, function()
                C.unregisterTerminal(terminal.id, C.newRequestId())
            end)
        elseif tile then
            context:addOption(getText(T .. "Terminal_Register"), nil, function()
                C.registerTerminal(x, y, z, "atm", C.newRequestId())
            end)
            context:addOption(getText(T .. "Terminal_RegisterTrade"), nil, function()
                C.registerTerminal(x, y, z, "trade", C.newRequestId())
            end)
        end
        if tile then
            context:addOption(getText(T .. "Terminal_Demolish"), nil, function()
                C.demolishTerminal(x, y, z, C.newRequestId())
            end)
        end
    end
end

-- Only admins take a terminal down: the entity is not thumpable and not moveable, and the
-- sledgehammer cursor (ISDestroyCursor.canDestroy, server/BuildingObjects, shared code) refuses
-- the mod's own terminal tiles and any registered terminal square for everyone else. Vanilla
-- consoles that nobody registered stay destroyable as usual.
local function protectedObject(object)
    local name = spriteName(object)
    if not name or not EC.TERMINAL_SPRITES[name] then return false end
    if string.find(name, "^MinidoracatEconomy_") then return true end
    local ok, sq = pcall(function() return object:getSquare() end)
    if not ok or not sq then return false end
    return C.terminalAt(sq:getX(), sq:getY(), sq:getZ()) ~= nil
end

local function guardDestroyCursor()
    if not ISDestroyCursor or ISDestroyCursor.MinidoracatEconomyGuarded then return end
    ISDestroyCursor.MinidoracatEconomyGuarded = true
    local base = ISDestroyCursor.canDestroy
    ISDestroyCursor.canDestroy = function(self, object)
        if EC.AtmProtection.blocked(self.character, object) then return false end
        if not isAdmin() and protectedObject(object) then return false end
        return base(self, object)
    end
end

-- Every way into the vanilla device panel ends in ISRadioWindow.activate: the world context menu
-- (ISRadioAndTvMenu.openTvPanel / .openRadioPanel: ISRadioAndTvMenu.lua:44-50, and
-- ISWorldObjectContextMenu.activateRadio: ISWorldObjectContextMenu.lua:225-227), the double
-- click on the tile (ISObjectClickHandler.lua:243-245) and the controller prompt
-- (ISButtonPrompt:openDeviceOptions: ISButtonPrompt.lua:312-315). Wrapping that one function
-- answers all of them at once: the station's own radio explains itself instead of opening a
-- panel whose dials would retune, mute or switch off the market's frequency. Any other radio --
-- a player's walkie-talkie, a vanilla HAM set, a car radio -- goes through untouched.
--
-- This is client courtesy only. A modified client can still send the device packets the engine
-- accepts from any logged-in player; that is why the server re-asserts the device's settings.
local function guardRadioWindow()
    if not ISRadioWindow or ISRadioWindow.MinidoracatEconomyGuarded then return end
    ISRadioWindow.MinidoracatEconomyGuarded = true
    local base = ISRadioWindow.activate
    ISRadioWindow.activate = function(player, device, ...)
        local ok, owned = pcall(EC.TradeRadio.isOwned, device)
        if not ok then
            EC.log("trade radio identity read failed: " .. tostring(owned))
            C.toast(tr("Terminal_Radio_Unknown"))
            return nil
        end
        if owned then
            C.toast(tr("Terminal_Radio_LockedToast"))
            return nil
        end
        return base(player, device, ...)
    end
end

local function onReply(okKey, args)
    if args.ok then
        -- the registration itself succeeded; a warning means a part of it did not (the station's
        -- radio could not be put up yet), and saying so is the whole point of carrying it
        local text = getText(T .. okKey)
        if args.warning ~= nil then
            local note = getTextOrNull(T .. "Terminal_Warning_" .. tostring(args.warning))
            text = text .. "\n" .. (note or tostring(args.warning))
        end
        C.toast(text)
    else
        local key = T .. "Terminal_Error_" .. tostring(args.error)
        local text = getTextOrNull(key)
        C.toast(text or tostring(args.error))
    end
end

C.handlers["terminal.register"] = function(args) onReply("Terminal_Registered", args) end
C.handlers["terminal.unregister"] = function(args) onReply("Terminal_Unregistered", args) end
C.handlers["terminal.demolish"] = function(args) onReply("Terminal_Demolished", args) end

Events.OnFillWorldObjectContextMenu.Add(onFillMenu)
Events.OnGameStart.Add(guardDestroyCursor)
Events.OnGameStart.Add(guardRadioWindow)
