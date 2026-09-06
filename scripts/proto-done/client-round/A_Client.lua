-- 階段 A 拋棄式原型：client 端。F7 開原型視窗（按鈕送 sendClientCommand)；右鍵格子登錄／使用終端；
-- OnGameStart 不送任何指令、首個 OnTick 才送 reconcile（A18)。只在 proto/enable.txt 存在時執行（本機同一台)。
-- API 出處：sendClientCommand LuaManager.java:8912；OnServerCommand LuaEventManager.java:730；
-- OnFillWorldObjectContextMenu :619；getAccessLevel LuaManager.java:4435；ISCollapsableWindow／ISButton 原版 ISUI。

if isServer() then return end

local TAG = "[MinidoracatEconomyFor42][A*]"
local MODULE = "MinidoracatEconomyProto"
local DIR = "MinidoracatEconomy/proto"

local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function enabled()
    local ok, r = pcall(getFileReader, DIR .. "/enable.txt", false)
    if ok and r then pcall(function() r:close() end); return true end
    return false
end
if not enabled() then return end

local terminals = {}
local window = nil

local function send(cmd, args)
    local p = getPlayer()
    if not p then return end
    sendClientCommand(p, MODULE, cmd, args or {})
    log("sent " .. cmd)
end

local function toast(text)
    log("toast: " .. text)
    local p = getPlayer()
    if p then pcall(function() p:setHaloNote(text, 255, 220, 120, 400) end) end
end

local BUTTONS = {
    { "A8 give axe", function() send("give") end },
    { "A8 take axe", function() send("take") end },
    { "A9 list-out axe", function()
        local item = getPlayer():getInventory():getFirstTypeRecurse("Base.Axe")
        if not item then toast("no axe in backpack"); return end
        send("listout", { itemId = item:getID() })
    end },
    { "A9 mailbox+claim", function() send("mailclaim") end },
    { "A9 reconcile", function() send("reconcile") end },
    { "A10 mark watermark", function() send("mark") end },
    { "A10 read watermark", function() send("readmark") end },
    { "A12 buy", function() send("buy") end },
    { "A13 role", function()
        local ok, lvl = pcall(getAccessLevel)
        log("A13 client getAccessLevel=" .. tostring(ok and lvl or ("err " .. tostring(lvl))))
        send("role", { accessLevel = ok and lvl or "err" })
    end },
    { "A14 radio 50", function() send("radio", { strength = 50 }) end },
    { "A14 radio 500", function() send("radio", { strength = 500 }) end },
    { "A19 integration", function() send("integ") end },
    -- B42 MP: body damage is server-authoritative (client BodyDamage.Update returns early, BodyDamage.java:2099-2107)
    { "A6 suicide", function() send("suicide") end },
}

local function toggleWindow()
    if window then
        window:setVisible(not window:isVisible())
        return
    end
    local h = 30 + #BUTTONS * 26 + 10
    window = ISCollapsableWindow:new(60, 120, 220, h)
    window:initialise()
    window:setTitle("Economy proto (End key)")
    for i, b in ipairs(BUTTONS) do
        local btn = ISButton:new(10, 24 + (i - 1) * 26, 200, 22, b[1], nil, function() b[2]() end)
        btn:initialise()
        window:addChild(btn)
    end
    window:addToUIManager()
    window:setVisible(true)
end

Events.OnKeyPressed.Add(function(key)
    if key == Keyboard.KEY_END then toggleWindow() end
end)

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= MODULE then return end
    if command == "toast" then
        toast(args.text or "")
    elseif command == "terminals" then
        terminals = args.list or {}
        local n = 0
        for _ in pairs(terminals) do n = n + 1 end
        log("terminal list updated: " .. n)
    end
end)

local function terminalAt(x, y, z)
    for id, t in pairs(terminals) do
        if t.x == x and t.y == y and t.z == z then return id end
    end
    return nil
end

Events.OnFillWorldObjectContextMenu.Add(function(playerNum, context, worldobjects, test)
    if test then return end
    local sq = nil
    for _, o in ipairs(worldobjects) do
        if o and o.getSquare and o:getSquare() then sq = o:getSquare(); break end
    end
    if not sq then return end
    local x, y, z = sq:getX(), sq:getY(), sq:getZ()
    local id = terminalAt(x, y, z)
    if id then
        context:addOption("Use terminal " .. id, nil, function() toast("open economy center (proto)"); send("buy") end)
    end
    local ok, lvl = pcall(getAccessLevel)
    if ok and lvl == "admin" then
        context:addOption("Register terminal here (admin)", nil, function() send("terminal.register", { x = x, y = y, z = z, kind = "trade" }) end)
    end
end)

local sentFirstTick = false
Events.OnGameStart.Add(function()
    log("A18 OnGameStart: no command sent here")
    sentFirstTick = false
end)
local function firstTick()
    if sentFirstTick then return end
    if not getPlayer() then return end
    sentFirstTick = true
    log("A18 first OnTick: sending reconcile + terminals")
    send("reconcile")
    send("terminals")
    Events.OnTick.Remove(firstTick)
end
Events.OnTick.Add(firstTick)
