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
S.reply = reply

-- Server-side player list (LuaManager.java:4437-4443); the client-side getConnectedPlayers is
-- unavailable on a dedicated server (AGENTS.md API table).
-- The one loop every push and lookup goes through: fn(player) for each online player in the
-- engine's order (LuaManager.java:4437-4443); returning true stops early.
function S.forEachOnline(fn)
    local players = getOnlinePlayers()
    if not players then return end
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p and fn(p) == true then return end
    end
end

function S.onlinePlayer(username)
    local found = nil
    S.forEachOnline(function(p)
        if p:getUsername() == username then found = p return true end
    end)
    return found
end

-- Push pattern (spec 19.2): a module that changes player-visible state pushes the fresh snapshot
-- itself - S.reply to one player, S.broadcast for a shared table, S.forEachOnline when every
-- player needs a per-player shaped copy (rewards.state, shop.list). Clients register
-- C.handlers[command] and re-render; there is no polling of mutable state.
function S.broadcast(command, args)
    S.forEachOnline(function(p) reply(p, command, args) end)
end

-- ---------- ModData root ----------

-- Every server start appends one line {epoch, loadedSeq, flagged} to this file (append-only,
-- tiny). ModData only remembers epochs that reached a world save: an epoch that crashed before its
-- first save leaves no trace in the save, yet its receipts and events are already on disk. On
-- start every epoch in this file that ModData does not know about is a crashed one, and
-- everything it wrote above the seq it loaded from was rolled back (the companion derives the
-- same from the event stream, spec 4.2). `flagged` lists the crashed epochs that start already
-- reported: until a save lands, every restart rolls the same epochs back again, and the journal
-- must not repeat the epoch.rolledback line each time (seen live: 10 kill-restarts = 45 lines).
-- Kept in ECServer because it must run before ECExport initialises.
S.EPOCHS_FILE = "MinidoracatEconomy/epochs.json"
S.EPOCHS_KEEP = 60

local function readEpochLines()
    local out = {}
    local reader = nil
    local ok = pcall(function() reader = getFileReader(S.EPOCHS_FILE, false) end)
    if not ok or not reader then return out end
    pcall(function()
        for _ = 1, 10000 do
            local line = reader:readLine()
            if line == nil then break end
            local rec = EC.jsonDecode(line)
            if type(rec) == "table" and type(rec.epoch) == "string" and type(rec.loadedSeq) == "number" then
                out[#out + 1] = { epoch = rec.epoch, loadedSeq = rec.loadedSeq, flagged = type(rec.flagged) == "table" and rec.flagged or nil }
            end
        end
    end)
    pcall(function() reader:close() end)
    return out
end

local function writeEpochLines(lines, append)
    local writer = nil
    local ok = pcall(function() writer = getFileWriter(S.EPOCHS_FILE, true, append) end)
    if not ok or not writer then
        EC.log("epochs file unavailable; crashed epochs will not be flagged as rolled back")
        return
    end
    pcall(function()
        for _, h in ipairs(lines) do
            writer:writeln(EC.jsonEncode({ epoch = h.epoch, loadedSeq = h.loadedSeq, flagged = h.flagged }))
        end
    end)
    pcall(function() writer:close() end)
end

-- Returns the root table; creates the meta block on first run. `seq` survives restarts (it is
-- part of the saved table); `loadedSeq` is the rollback point of this process; `epoch` is new
-- for every start so ids from a rolled-back branch never collide (spec 19.7 rule four).
function S.initModData()
    md = ModData.getOrCreate(EC.MODDATA_KEY)
    local prevMeta = type(md.meta) == "table" and md.meta or {}
    local prevSeq = type(prevMeta.seq) == "number" and prevMeta.seq or 0
    md.schemaVersion = md.schemaVersion or EC.SCHEMA_VERSION
    -- Epoch history: which seq each previous epoch was loaded back to. A receipt line from epoch E
    -- with seq > history[E].loadedSeq was rolled back (spec 19.6). Bounded to the last 20 starts.
    local history = type(prevMeta.history) == "table" and prevMeta.history or {}
    if type(prevMeta.epoch) == "string" then
        history[#history + 1] = { epoch = prevMeta.epoch, loadedSeq = prevSeq }
    end
    local known = {}
    local oldestRemembered = nil
    for _, h in ipairs(history) do
        known[h.epoch] = true
        local n = tonumber(h.epoch)
        if n and (oldestRemembered == nil or n < oldestRemembered) then oldestRemembered = n end
    end
    local fileLines = readEpochLines()
    local reported = {}
    for _, h in ipairs(fileLines) do
        for _, e in ipairs(h.flagged or {}) do reported[e] = true end
    end
    S.crashedEpochs = {}   -- newly discovered this start; ECExport writes one epoch.rolledback line each
    local flagged = {}
    for _, h in ipairs(fileLines) do
        -- Unknown to ModData and newer than the oldest epoch it still remembers: it crashed before
        -- its first save. Older unknown lines are epochs the bounded history has simply forgotten.
        local n = tonumber(h.epoch)
        if not known[h.epoch] and (oldestRemembered == nil or (n and n > oldestRemembered)) then
            known[h.epoch] = true
            history[#history + 1] = { epoch = h.epoch, loadedSeq = h.loadedSeq }
            if not reported[h.epoch] then
                S.crashedEpochs[#S.crashedEpochs + 1] = h
                flagged[#flagged + 1] = h.epoch
            end
        end
    end
    EC.sortSafe(history, function(a, b) return (tonumber(a.epoch) or 0) < (tonumber(b.epoch) or 0) end)
    while #history > 20 do table.remove(history, 1) end
    md.meta = {
        realmId = type(prevMeta.realmId) == "string" and prevMeta.realmId or ("realm-" .. tostring(EC.now())),
        epoch = tostring(EC.now()),
        seq = prevSeq,
        loadedSeq = prevSeq,
        startedAt = EC.now(),
        history = history,
    }
    local mine = { epoch = md.meta.epoch, loadedSeq = prevSeq, flagged = #flagged > 0 and flagged or nil }
    if #fileLines >= S.EPOCHS_KEEP then
        local keep = {}
        for i = #fileLines - math.floor(S.EPOCHS_KEEP / 2) + 1, #fileLines do keep[#keep + 1] = fileLines[i] end
        keep[#keep + 1] = mine
        writeEpochLines(keep, false)
    else
        writeEpochLines({ mine }, true)
    end
    return md
end

-- True when a record stamped (epoch, seq) did not survive into the save its successor loaded.
function S.isRolledBack(epoch, seq)
    if type(epoch) ~= "string" or type(seq) ~= "number" or epoch == md.meta.epoch then return false end
    for _, h in ipairs(md.meta.history) do
        if h.epoch == epoch then return seq > h.loadedSeq end
    end
    return false
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
        currencies = S.Config and S.Config.snapshot() or nil,
        terminals = S.Terminal and S.Terminal.list() or nil,
        terminalRange = EC.TERMINAL_RANGE,
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
