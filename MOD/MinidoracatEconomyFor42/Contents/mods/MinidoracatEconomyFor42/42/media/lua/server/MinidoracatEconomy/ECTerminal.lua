-- MinidoracatEconomyFor42 - terminals (server authority; spec 12 stage C, 17.1, stage A11/A12).
--
-- A terminal is a registered map square: an admin builds the entity (or picks a vanilla
-- console), right-clicks it and registers the coordinates; the server re-checks the role, the
-- AddItem capability and that the square really carries an allowed tile. Every write command
-- (shop.buy, mail.claim, market.*) asks T.near(player): within EC.TERMINAL_RANGE tiles
-- (Chebyshev, same level) of any registered terminal.
--
-- Engine references (snapshot 42.20.4-20260826):
--   hasCapability                 LuaManager.java:2454-2455, GameServer.java:2806 (A11)
--   getCell():getGridSquare(x,y,z) IsoCell.java:3189 ; IsoObject.getSprite():getName()
--                                 IsoObject.java:1958, IsoSprite.java:1980
--   distance rule                 A12: 0.80 / 1.25 tiles accepted, 3.77 refused, zero debit

if not MinidoracatEconomy or not MinidoracatEconomy.Integration then
    require "MinidoracatEconomy/ECIntegration"
end
local EC = MinidoracatEconomy
local S = EC and EC.Server
local X = EC and EC.Export
if not S or not S.AUTHORITY or not X then
    return
end

EC.Terminal = EC.Terminal or {}
local T = EC.Terminal

T.MAX = 200

local md = nil

local function roleName(player)
    local ok, role = pcall(function() return player:getRole():getName() end)
    return ok and type(role) == "string" and role or ""
end

-- Same rule as ECAdmin.isAdmin (that module loads later) plus the engine capability check A11
-- used. The role name is matched exactly, like everywhere else: role lookup is case sensitive
-- (Roles.java:302-305), so a lower-cased comparison would let "Admin" pass an "admin" list.
local function isAdmin(player)
    if not EC.roleSet(EC.sandbox("AdminRoles", "admin"))[roleName(player)] then return false end
    local ok, cap = pcall(function() return player:getRole():hasCapability(Capability.AddItem) end)
    return ok and cap == true
end

local function isInt(v)
    return type(v) == "number" and v == math.floor(v)
end

-- The square must hold an object whose sprite is an allowed terminal tile. Unloaded chunk or bare
-- floor = no.
local function squareHasTerminal(x, y, z)
    local ok, found = pcall(function()
        local sq = getCell():getGridSquare(x, y, z)
        if not sq then return false end
        local objects = sq:getObjects()
        for i = 0, objects:size() - 1 do
            local o = objects:get(i)
            local sprite = o and o:getSprite()
            local name = sprite and sprite:getName()
            if name and EC.TERMINAL_SPRITES[name] then return true end
        end
        return false
    end)
    return ok and found == true
end

-- Trade terminals carry the placement state of their two-way radio (ECTradeRadioRelay):
-- "disabled" (the relay option is off), "waiting" (registered, device not standing yet),
-- "active" (device placed and configured this uptime), "error" (the last attempt failed).
-- It is a placement state, never a promise that anybody heard anything. ATMs have no device and
-- no field. The relay module loads after this one, so it is looked up per call, not captured.
function T.list()
    local out = {}
    local relay = S.TradeRadio
    for id, t in pairs(md.terminals) do
        local e = { id = id, x = t.x, y = t.y, z = t.z, kind = t.kind }
        if t.kind == "trade" and relay then e.radioState = relay.state(t.x, t.y, t.z) end
        out[#out + 1] = e
    end
    EC.sortSafe(out, function(a, b) return a.id < b.id end)
    return out
end

function T.count()
    return EC.countKeys(md.terminals)
end

function T.at(x, y, z)
    for id, t in pairs(md.terminals) do
        if t.x == x and t.y == y and t.z == z then return id end
    end
    return nil
end

-- Chebyshev distance to the nearest terminal on the player's level; nil when there is none.
function T.nearest(player)
    local px, py, pz = player:getX(), player:getY(), player:getZ()
    local best = nil
    for _, t in pairs(md.terminals) do
        if t.z == math.floor(pz) then
            local d = math.max(math.abs(px - t.x), math.abs(py - t.y))
            if not best or d < best then best = d end
        end
    end
    return best
end

-- The write gate every terminal-bound command uses. Always a distance check: the sandbox option
-- RemoteReadOnly only decides whether the window may be *opened* away from a terminal (read-only
-- browsing), never whether a write needs one (spec 12 stage D position rule).
function T.near(player)
    local d = T.nearest(player)
    return (d ~= nil and d <= EC.TERMINAL_RANGE) or EC.nearMapAtm(player)
end

-- The client snapshot of the terminal list. Public because the radio relay pushes it as well: a
-- device state that changed during a sweep (repaired, failed, chunk loaded) has no other way
-- into a window that is already open.
function T.pushList()
    S.broadcast("terminals", { list = T.list(), remoteReadOnly = EC.sandbox("RemoteReadOnly", true), range = EC.TERMINAL_RANGE })
end

-- Registration changes tell the radio relay about the square it touched, before the list goes
-- out, so the pushed list already carries the state this change produced. The relay answers with
-- the state of that square (nil when it no longer holds a registration).
local function radioSync(x, y, z)
    local relay = S.TradeRadio
    if not relay then
        EC.log("trade radio: the relay module is not loaded")
        return "error"
    end
    local ok, state = pcall(relay.onTerminalsChanged, x, y, z)
    if not ok then
        EC.log("trade radio: sync after a registration change failed: " .. tostring(state))
        return "error"
    end
    return state
end

-- The companion device has to go before the registration does: the relay's bounded sweep only
-- visits registered squares, so dropping the entry first and failing afterwards would leave a
-- listening device standing with nothing left that would ever retry it. Returns nil when the
-- square is verified clear - a genuinely unloaded chunk included, since the next chunk load
-- collects orphans - or the failure's own text.
local function clearCompanion(x, y, z)
    local relay = S.TradeRadio
    if not relay then return "the radio relay is not loaded" end
    local ok, cleared, err = pcall(relay.clearSquare, x, y, z)
    if not ok then return tostring(cleared) end
    if cleared == false then return tostring(err) end
    return nil
end

function T.register(player, args)
    if not isAdmin(player) then return { ok = false, error = "forbidden" } end
    if type(args) ~= "table" or not isInt(args.x) or not isInt(args.y) or not isInt(args.z) then
        return { ok = false, error = "invalid_args" }
    end
    local kind = type(args.kind) == "string" and args.kind or "atm"
    if not EC.TERMINAL_KINDS[kind] then return { ok = false, error = "invalid_args" } end
    if T.at(args.x, args.y, args.z) then return { ok = false, error = "already_registered" } end
    if T.count() >= T.MAX then return { ok = false, error = "too_many" } end
    if not squareHasTerminal(args.x, args.y, args.z) then return { ok = false, error = "no_terminal_object" } end
    local id = S.newId()
    md.terminals[id] = { x = args.x, y = args.y, z = args.z, kind = kind, by = player:getUsername(), at = EC.now() }
    X.emit("terminal.registered", { terminalId = id, x = args.x, y = args.y, z = args.z, terminalKind = kind, actor = player:getUsername() })
    X.audit({ action = "terminal", target = id, field = "register", after = args.x .. "," .. args.y .. "," .. args.z, admin = player:getUsername() })
    local radioState = radioSync(args.x, args.y, args.z)
    T.pushList()
    -- The terminal IS registered; only the native device failed. The result says so, and the
    -- warning tells the admin the station is not carrying voice yet.
    if radioState == "error" then return { ok = true, id = id, warning = "radio_unavailable" } end
    return { ok = true, id = id }
end

function T.unregister(player, args)
    if not isAdmin(player) then return { ok = false, error = "forbidden" } end
    local id = type(args) == "table" and args.id or nil
    local t = type(id) == "string" and md.terminals[id] or nil
    if not t then return { ok = false, error = "unknown_terminal" } end
    local stuck = clearCompanion(t.x, t.y, t.z)
    if stuck then
        EC.log("trade radio: unregister refused, the device is still standing: " .. stuck)
        return { ok = false, error = "radio_unavailable" }
    end
    md.terminals[id] = nil
    X.emit("terminal.unregistered", { terminalId = id, x = t.x, y = t.y, z = t.z, actor = player:getUsername() })
    X.audit({ action = "terminal", target = id, field = "unregister", before = t.x .. "," .. t.y .. "," .. t.z, admin = player:getUsername() })
    radioSync(t.x, t.y, t.z)
    T.pushList()
    return { ok = true, id = id }
end

-- Admin removal of the world object itself (right-click "demolish"): the square's terminal-tile
-- object is transmitted away (IsoGridSquare.transmitRemoveItemFromSquare, the ClientCommands.lua
-- server pattern) and a registration on that square is dropped with it. Players never get this
-- path: the entity is not thumpable, not moveable, and the client refuses the sledgehammer.
function T.demolish(player, args)
    if not isAdmin(player) then return { ok = false, error = "forbidden" } end
    if type(args) ~= "table" or not isInt(args.x) or not isInt(args.y) or not isInt(args.z) then
        return { ok = false, error = "invalid_args" }
    end
    -- The device first: it is the reversible half. A demolish that took the tile away and then
    -- failed to remove the device would drop the very registration the sweep needs to retry.
    local stuck = clearCompanion(args.x, args.y, args.z)
    if stuck then
        EC.log("trade radio: demolish refused, the device is still standing: " .. stuck)
        return { ok = false, error = "radio_unavailable" }
    end
    local removed = false
    local ok = pcall(function()
        local sq = getCell():getGridSquare(args.x, args.y, args.z)
        if not sq then return end
        local objects = sq:getObjects()
        local victims = {}
        for i = 0, objects:size() - 1 do
            local o = objects:get(i)
            local sprite = o and o:getSprite()
            local name = sprite and sprite:getName()
            if name and EC.TERMINAL_SPRITES[name] then victims[#victims + 1] = o end
        end
        for _, o in ipairs(victims) do
            sq:transmitRemoveItemFromSquare(o)
            removed = true
        end
    end)
    if not ok or not removed then return { ok = false, error = "no_terminal_object" } end
    local id = T.at(args.x, args.y, args.z)
    if id then
        md.terminals[id] = nil
        X.emit("terminal.unregistered", { terminalId = id, x = args.x, y = args.y, z = args.z, actor = player:getUsername(), demolished = true })
    end
    -- the terminal tile is gone either way, so the square must not keep a device standing on it
    radioSync(args.x, args.y, args.z)
    if id then T.pushList() end
    X.audit({ action = "terminal", target = id or (args.x .. "," .. args.y .. "," .. args.z), field = "demolish", admin = player:getUsername() })
    return { ok = true, id = id }
end

-- ---------- commands ----------

S.handlers["terminal.demolish"] = function(player, args)
    local res = T.demolish(player, args)
    res.requestId = type(args) == "table" and args.requestId or nil
    S.reply(player, "terminal.demolish", res)
end

S.handlers["terminals"] = function(player, args)
    S.reply(player, "terminals", { list = T.list(), remoteReadOnly = EC.sandbox("RemoteReadOnly", true), range = EC.TERMINAL_RANGE })
end

S.handlers["terminal.register"] = function(player, args)
    local res = T.register(player, args)
    res.requestId = type(args) == "table" and args.requestId or nil
    S.reply(player, "terminal.register", res)
end

S.handlers["terminal.unregister"] = function(player, args)
    local res = T.unregister(player, args)
    res.requestId = type(args) == "table" and args.requestId or nil
    S.reply(player, "terminal.unregister", res)
end

function T.init(root)
    md = root
    md.terminals = md.terminals or {}
end

S.Terminal = T
S.onInit(T.init)
return T
