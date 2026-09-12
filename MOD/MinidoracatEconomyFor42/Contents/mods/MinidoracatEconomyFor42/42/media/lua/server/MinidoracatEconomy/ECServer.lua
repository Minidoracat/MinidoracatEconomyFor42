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

-- Durable watermark of THIS uptime (see the durable watermark section below). Process memory
-- only, never ModData: a seq some earlier uptime confirmed says nothing about the save this
-- uptime actually loaded.
local durableSeq = nil                  -- highest seq of this epoch confirmed to be inside a save
local durableAt = nil                   -- local ms when that marker was accepted
local durableState = "idle"             -- outcome of the last poll (S.durableStatus().status)
local durablePolledAt = 0

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
    -- A new process has confirmed nothing yet, and neither has a harness restart.
    durableSeq, durableAt, durableState, durablePolledAt = nil, nil, "idle", 0
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

-- ---------- durable watermark (companion) ----------

-- Global ModData only reaches the disk in QueuedSaveAll (ServerMap.java:409) and nothing inside
-- this process can observe that moment: there is no save-finished event, and inferring one from a
-- clock would be a guess about other people's assets. The companion already parses the save's
-- global_mod_data.bin for its own reconciliation; once it has fully parsed a stable one it writes
-- the seq it found there to this file. Every record of that epoch stamped seq <= that seq is
-- therefore inside a save on disk - exactly what a pending record must know before it may be
-- cleared (ECRecovery), and the one thing the epoch history alone can never say about the
-- running epoch.
--
-- One line, {realmId, epoch, seq, ts}, under the same Lua cache root as our own exports: a local
-- companion file a client cannot reach. No client command may ever report a watermark, and this
-- file is only trusted for the realm and the epoch it names.
S.DURABLE_FILE = "MinidoracatEconomy/durable.json"
S.DURABLE_POLL_MS = 60000
S.DURABLE_MAX_LINES = 4                 -- one line and its newline; anything longer is not this file
S.DURABLE_MAX_CHARS = 512

local function finiteInt(v)
    -- NaN fails the floor equality, +inf fails the upper bound, -inf and negatives fail >= 0.
    return type(v) == "number" and v == math.floor(v) and v >= 0 and v < math.huge
end

-- Text of the marker, or nil plus the status saying why. "missing" stays distinct from
-- "unreadable": getFileReader catches IOException in Java and returns nil even for a file that
-- exists (LuaManager.java:5949-5960) while cacheFileExists shares the same Lua cache root
-- (:5541-5549), so a file that cannot be opened must never be reported as "nothing was written".
local function readDurableText()
    local reader = nil
    local ok = pcall(function() reader = getFileReader(S.DURABLE_FILE, false) end)
    if not ok or not reader then
        local checked, exists = pcall(cacheFileExists, S.DURABLE_FILE)
        if checked and not exists then return nil, "missing" end
        return nil, "unreadable"
    end
    local parts = {}
    local readOk = pcall(function()
        for _ = 1, S.DURABLE_MAX_LINES do
            local line = reader:readLine()
            if line == nil then return end
            parts[#parts + 1] = line
        end
        if reader:readLine() ~= nil then error("marker has too many lines") end
    end)
    pcall(function() reader:close() end)
    if not readOk then return nil, "unreadable" end
    local text = table.concat(parts, "\n")
    if text == "" then return nil, "unreadable" end
    if #text > S.DURABLE_MAX_CHARS then return nil, "malformed" end
    return text
end

-- Reads the marker at most once per S.DURABLE_POLL_MS; `force` skips the throttle (used once at
-- start). A marker that fails any check is discarded and the watermark already confirmed during
-- this uptime stays exactly as it was: the worst a truncated, foreign or stale file can do is stop
-- the watermark from advancing. Returns S.durableStatus().
function S.pollDurable(force)
    if md == nil then return S.durableStatus() end
    local now = EC.now()
    if not force and now - durablePolledAt < S.DURABLE_POLL_MS then return S.durableStatus() end
    durablePolledAt = now
    local text, why = readDurableText()
    if text == nil then
        durableState = why
        return S.durableStatus()
    end
    local doc = EC.jsonDecode(text)
    if type(doc) ~= "table" or type(doc.realmId) ~= "string" or type(doc.epoch) ~= "string"
        or not finiteInt(doc.seq) or not finiteInt(doc.ts) then
        durableState = "malformed"
    elseif doc.realmId ~= md.meta.realmId then
        durableState = "foreign_realm"
    elseif doc.epoch ~= md.meta.epoch then
        -- a marker for an earlier epoch describes an earlier save; this epoch is not in it
        durableState = "other_epoch"
    elseif doc.seq > md.meta.seq then
        durableState = "above_seq"
    elseif durableSeq ~= nil and doc.seq < durableSeq then
        durableState = "regressed"
    else
        durableSeq = doc.seq
        durableAt = now
        durableState = "confirmed"
    end
    return S.durableStatus()
end

-- What this process knows about the save, for the callers that must not guess and for the status
-- UI. `source` is "companion" only while a marker accepted during THIS uptime is being trusted;
-- "none" means "no watermark for this uptime" and never means "the companion is not running" -
-- `status` is the one that says which it was:
--   "idle"          - not polled yet this uptime
--   "missing"       - no such file (companion never wrote one, or not since this start)
--   "unreadable"    - the file is there but could not be opened or read
--   "malformed"     - not one small JSON object with the four fields in the right shapes
--   "foreign_realm" - another realm's marker
--   "other_epoch"   - a marker for an epoch other than the running one
--   "above_seq"     - claims a seq this process has not even issued yet
--   "regressed"     - below a seq already confirmed this uptime
--   "confirmed"     - accepted; `seq` is the watermark
-- `ageMs` is measured from the local time the last valid marker was accepted (not from the
-- marker's own clock) and is the age of that marker, not a claim that anything is online now.
function S.durableStatus()
    return {
        source = durableSeq ~= nil and "companion" or "none",
        seq = durableSeq,
        ageMs = durableAt ~= nil and (EC.now() - durableAt) or nil,
        status = durableState,
    }
end

-- What the epoch history says about a record stamped (epoch, seq). Four answers, and the fourth
-- is the one that keeps assets conserved: an epoch this bounded history no longer remembers is
-- neither durable nor rolled back, and a caller that cannot tell must hold the record instead of
-- guessing (ECRecovery).
--   "current"    - written by this process and not yet known to be in a save
--   "survived"   - it was inside the save its successor loaded, or (for the running epoch) inside
--                  the save the companion confirmed through S.pollDurable
--   "rolledback" - it was written above that save point and did not survive
--   "unknown"    - the epoch is no longer in the history, or the stamp is malformed
function S.epochVerdict(epoch, seq)
    if type(epoch) ~= "string" or epoch == "" or not finiteInt(seq) then return "unknown" end
    if epoch == md.meta.epoch then
        -- The history cannot judge the running epoch; a confirmed watermark can, for the part of
        -- it that is already in a save. Without one, every record of this epoch stays "current".
        if durableSeq ~= nil and seq <= durableSeq then return "survived" end
        return "current"
    end
    local n = seq
    for _, h in ipairs(md.meta.history) do
        if h.epoch == epoch then
            if n > (tonumber(h.loadedSeq) or 0) then return "rolledback" end
            return "survived"
        end
    end
    return "unknown"
end

-- True when a record stamped (epoch, seq) did not survive into the save its successor loaded.
-- A forgotten epoch answers false here, exactly as it always has; the callers that must tell
-- "not rolled back" from "cannot tell" read S.epochVerdict.
function S.isRolledBack(epoch, seq)
    if type(seq) ~= "number" then return false end
    return S.epochVerdict(epoch, seq) == "rolledback"
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
        options = S.Config and S.Config.options() or nil,
        -- The seasons a client needs before it can even label a board or a reward page. Taken
        -- through the same public projection the leaderboard replies use (ECStats.seasonState),
        -- so the handshake can never publish a season field the boards keep private.
        seasonState = S.Stats and S.Stats.seasonState() or nil,
        terminals = S.Terminal and S.Terminal.list() or nil,
        terminalRange = EC.TERMINAL_RANGE,
        unclaimed = S.Mailbox and S.Mailbox.unclaimed(player:getUsername()) or 0,   -- the float button badge
        radio = S.Radio and S.Radio.clientInfo() or nil,   -- channel name registration on the client
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
    S.pollDurable(true)
    EC.log("server ready version=" .. EC.VERSION .. " schema=" .. tostring(md.schemaVersion)
        .. " epoch=" .. md.meta.epoch .. " loadedSeq=" .. tostring(md.meta.loadedSeq)
        .. " remoteReadOnly=" .. tostring(EC.sandbox("RemoteReadOnly", true)))
end

Events.OnServerStarted.Add(S.onServerStarted)
Events.OnClientCommand.Add(S.dispatch)
Events.OnTickEvenPaused.Add(function() S.pollDurable() end)

return S
