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

-- Same rule as ECAdmin.isAdmin (that module loads later) plus the engine capability check A11 used.
local function isAdmin(player)
    if not EC.roleSet(EC.sandbox("AdminRoles", "admin"))[string.lower(roleName(player))] then return false end
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

function T.list()
    local out = {}
    for id, t in pairs(md.terminals) do
        out[#out + 1] = { id = id, x = t.x, y = t.y, z = t.z, kind = t.kind }
    end
    EC.sortSafe(out, function(a, b) return a.id < b.id end)
    return out
end

function T.count()
    local n = 0
    for _ in pairs(md.terminals) do n = n + 1 end
    return n
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
    return d ~= nil and d <= EC.TERMINAL_RANGE
end

local function broadcastList()
    S.broadcast("terminals", { list = T.list(), remoteReadOnly = EC.sandbox("RemoteReadOnly", true), range = EC.TERMINAL_RANGE })
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
    broadcastList()
    return { ok = true, id = id }
end

function T.unregister(player, args)
    if not isAdmin(player) then return { ok = false, error = "forbidden" } end
    local id = type(args) == "table" and args.id or nil
    local t = type(id) == "string" and md.terminals[id] or nil
    if not t then return { ok = false, error = "unknown_terminal" } end
    md.terminals[id] = nil
    X.emit("terminal.unregistered", { terminalId = id, x = t.x, y = t.y, z = t.z, actor = player:getUsername() })
    X.audit({ action = "terminal", target = id, field = "unregister", before = t.x .. "," .. t.y .. "," .. t.z, admin = player:getUsername() })
    broadcastList()
    return { ok = true, id = id }
end

-- ---------- commands ----------

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
