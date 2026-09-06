-- MinidoracatEconomyFor42 — server authority (dedicated GameServer only; never -coop).
--
-- Engine references (snapshot 42.20.4-20260826):
--   OnServerStarted / OnClientCommand   LuaEventManager.java:729 ; ModData loaded before it
--                                       (stage A: loadedSeq read back correctly after restart)
--   sendServerCommand                   LuaManager.java:8942
--   ModData.getOrCreate                 ModData.java:16-49 ; persisted only in QueuedSaveAll
--                                       (ServerMap.java:409); transmit() from a client is not
--                                       validated (GlobalModData.java:112-150) -> this table is never
--                                       transmitted and the client must never transmit it either
--   player:getUsername()                IsoPlayer.java:6445-6446 (account key; SteamID64 loses
--                                       precision through Lua doubles, KahluaNumberConverter.java:140-142)

if not MinidoracatEconomy or not MinidoracatEconomy.makeId then
    require "MinidoracatEconomy/ECCore"
end
local EC = MinidoracatEconomy
if not EC or not EC.makeId then
    error("MinidoracatEconomy shared core failed to load")
end

EC.Server = EC.Server or {}
local S = EC.Server

-- media/lua/server files are also loaded by MP clients; only the dedicated server is authority.
S.AUTHORITY = isServer()
if not S.AUTHORITY then
    return S
end

local COMMAND_COOLDOWN_MS = 500        -- per player per command; the first call is always accepted

local md = nil                          -- Global ModData root (EC.MODDATA_KEY)
local lastCommandAt = {}                -- [username][command] = ms

local function reply(player, command, args)
    sendServerCommand(player, EC.COMMAND_MODULE, command, args or {})
end

-- ---------- ModData root ----------

-- Returns the root table; creates the meta block on first run. `seq` survives restarts (it is
-- part of the saved table); `loadedSeq` is the rollback point of this process; `epoch` is new
-- for every start so ids from a rolled-back branch never collide (spec 19.7 rule four).
function S.initModData()
    md = ModData.getOrCreate(EC.MODDATA_KEY)
    local prevMeta = type(md.meta) == "table" and md.meta or {}
    local prevSeq = type(prevMeta.seq) == "number" and prevMeta.seq or 0
    md.schemaVersion = md.schemaVersion or EC.SCHEMA_VERSION
    md.meta = {
        realmId = type(prevMeta.realmId) == "string" and prevMeta.realmId or ("realm-" .. tostring(EC.now())),
        epoch = tostring(EC.now()),
        seq = prevSeq,
        loadedSeq = prevSeq,
        startedAt = EC.now(),
    }
    return md
end

function S.modData()
    return md
end

function S.nextSeq()
    md.meta.seq = md.meta.seq + 1
    return md.meta.seq
end

-- Never let a recreated record reuse a seq from the rolled-back branch (rule four).
function S.bumpSeq(seq)
    if type(seq) == "number" and seq > md.meta.seq then
        md.meta.seq = seq
    end
end

function S.newId()
    return EC.makeId(md.meta.epoch, S.nextSeq())
end

-- ---------- command plumbing ----------

local handlers = {}
S.handlers = handlers

local function throttled(username, command, now)
    local perUser = lastCommandAt[username]
    if not perUser then
        perUser = {}
        lastCommandAt[username] = perUser
    end
    local last = perUser[command]
    if last and now - last < COMMAND_COOLDOWN_MS then
        return true
    end
    perUser[command] = now
    return false
end

-- Login handshake (stage A18 shape: the client sends it from its first OnTick, never from
-- OnGameStart). Everything the client needs to know about this server process goes here.
handlers.hello = function(player, args)
    reply(player, "hello.ack", {
        epoch = md.meta.epoch,
        loadedSeq = md.meta.loadedSeq,
        schemaVersion = md.schemaVersion,
        version = EC.VERSION,
        remoteReadOnly = EC.sandbox("RemoteReadOnly", true),
    })
end

function S.dispatch(module, command, player, args)
    if module ~= EC.COMMAND_MODULE then return end
    if not md then
        EC.log("command " .. tostring(command) .. " before ModData init, ignored")
        return
    end
    local handler = handlers[command]
    if not handler then
        EC.log("unknown command " .. tostring(command) .. " from " .. tostring(player and player:getUsername()))
        return
    end
    local username = player:getUsername()
    if throttled(username, command, EC.now()) then
        return
    end
    local ok, err = pcall(handler, player, args or {})
    if not ok then
        EC.log("command " .. tostring(command) .. " from " .. tostring(username) .. " failed: " .. tostring(err))
    end
end

-- ---------- lifecycle ----------

-- Modules register their ModData initializers here; they run in registration order right after
-- the root/meta block exists (both on start and when the harness simulates a restart).
local initializers = {}
function S.onInit(fn)
    initializers[#initializers + 1] = fn
end

function S.onServerStarted()
    S.initModData()
    lastCommandAt = {}
    for _, fn in ipairs(initializers) do
        local ok, err = pcall(fn, md)
        if not ok then
            EC.log("module init failed: " .. tostring(err))
        end
    end
    EC.log("server ready version=" .. EC.VERSION .. " schema=" .. tostring(md.schemaVersion)
        .. " epoch=" .. md.meta.epoch .. " loadedSeq=" .. tostring(md.meta.loadedSeq)
        .. " remoteReadOnly=" .. tostring(EC.sandbox("RemoteReadOnly", true)))
end

Events.OnServerStarted.Add(S.onServerStarted)
Events.OnClientCommand.Add(S.dispatch)

return S
