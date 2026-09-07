-- MinidoracatEconomyFor42 - terminal right-click menu (client; stage C thin slice, stage A11/A18).
--
-- On a registered terminal square everyone gets "use terminal" (opens the economy center on the
-- shop tab). Admins additionally get "register" on a square that carries an allowed terminal
-- tile (EC.TERMINAL_SPRITES) and "unregister" on a registered one; the server re-validates both
-- (ECTerminal.register / unregister). getAccessLevel is a client-only read of the connection
-- (LuaManager.java:4435-4436); OnFillWorldObjectContextMenu: LuaEventManager.java:619-620.

if not MinidoracatEconomy or not MinidoracatEconomy.Client or not MinidoracatEconomy.Client.Panel then
    require "MinidoracatEconomy/ECPanel"
end
local EC = MinidoracatEconomy
local C = EC.Client
local P = C.Panel
local T = "IGUI_MinidoracatEconomy_"

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

local function onFillMenu(playerNum, context, worldobjects, test)
    if test or not isClient() then return end
    local square = nil
    for _, o in ipairs(worldobjects) do
        local ok, sq = pcall(function() return o:getSquare() end)
        if ok and sq then square = sq break end
    end
    if not square then return end
    local x, y, z = square:getX(), square:getY(), square:getZ()
    local terminal = C.terminalAt(x, y, z)
    if terminal then
        context:addOption(getText(T .. "Terminal_Use"), nil, useTerminal)
    end
    if isAdmin() then
        if terminal then
            context:addOption(getText(T .. "Terminal_Unregister"), nil, function()
                C.unregisterTerminal(terminal.id, C.newRequestId())
            end)
        elseif hasTerminalTile(square, worldobjects) then
            context:addOption(getText(T .. "Terminal_Register"), nil, function()
                C.registerTerminal(x, y, z, "atm", C.newRequestId())
            end)
        end
    end
end

local function onReply(okKey, args)
    if args.ok then
        C.toast(getText(T .. okKey))
    else
        local key = T .. "Terminal_Error_" .. tostring(args.error)
        local text = getTextOrNull(key)
        C.toast(text or tostring(args.error))
    end
end

C.handlers["terminal.register"] = function(args) onReply("Terminal_Registered", args) end
C.handlers["terminal.unregister"] = function(args) onReply("Terminal_Unregistered", args) end

Events.OnFillWorldObjectContextMenu.Add(onFillMenu)
