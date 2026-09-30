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
--   player:getUsername()                IsoPlayer.java:6445-6446: the name the client sent. The
--                                       login name counts only as S.login verified it
--                                       (ECIdentity: SteamID binding; split-screen seats have
--                                       none); the account is S.accountOf(login). SteamID64 itself is no key: it loses
--                                       precision as a Lua double (KahluaNumberConverter.java:103-116)

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

-- The engine writes every packet to a player into one fixed 1,000,000-byte buffer
-- (UdpConnection.java:40, 198-202). sendServerCommand (GameServer.java:3460-3482) catches only
-- IOException, so a larger table raises BufferOverflowException: the reply is lost and the
-- connection's send lock is never released (endPacket unlocks, :303-319). S.wireBytes is an upper
-- bound of what TableNetworkUtils writes: a type byte, then an 8-byte double, a 1-byte boolean, a
-- 4-byte count plus the entries, or a string as a 2-byte length plus UTF-8 (TableNetworkUtils.java:
-- 30-41, 78-93; GameWindow.java:1263-1272). Kahlua strings are UTF-16 units, at most 3 UTF-8 bytes
-- each; standard Lua (the harness) already counts bytes.
S.REPLY_MAX_BYTES = 900000
local charOK, char256 = pcall(string.char, 256)
local UTF16 = charOK and string.byte(char256) == 256
function S.wireBytes(v)
    local t = type(v)
    if t == "string" then
        if not UTF16 then return 3 + #v end
        local _, wide = string.gsub(v, "[^\1-\127]", "")
        return 3 + #v + 2 * wide
    end
    if t == "number" then return 9 end
    if t == "boolean" then return 2 end
    if t ~= "table" then return 0 end
    local n = 5
    for k, x in pairs(v) do n = n + S.wireBytes(k) + S.wireBytes(x) end
    return n
end

-- A reply that would not fit is never handed to the engine: a request is answered with
-- reply_too_large (the client's pending slot is freed and the page says why), a push is dropped.
-- Both are logged. The lists that can grow are bounded where they are built; this is the net.
local function reply(player, command, args)
    args = args or {}
    local size = S.wireBytes(args)
    if size > S.REPLY_MAX_BYTES then
        EC.log("reply " .. tostring(command) .. " not sent: about " .. size .. " bytes, over the packet limit")
        if args.requestId == nil then return end
        args = { ok = false, error = "reply_too_large", requestId = args.requestId }
    end
    sendServerCommand(player, EC.COMMAND_MODULE, command, args)
end
S.reply = reply

-- ---------- identity ----------

-- getUsername() is whatever name the client sent: a split-screen seat or a respawn may carry any
-- name that is not online at that moment (ConnectCoopPacket.java:72-97 refuses only an empty or
-- an already connected one; GameServer.java:2830, 2848 then names the seat with it). The raw name
-- is never an identity. Three kinds of name:
--   S.login(player)      the login name this player verifiably is, or nil. It keys what belongs
--                        to one character save: recovery receipts/holds/journal, pending outs,
--                        the season survival base, which save claimed a letter, entitlements.
--   S.principal(player)  the ACCOUNT: S.accountOf(S.login(player)), or nil while the one-account
--                        policy (IdentityMultiAccount off) keeps that login out - S.login stays
--                        set then, so the save's own bookkeeping keeps running. Money, caps,
--                        claims, mail, market, auctions, transfers, shop, boards, pushes, throttling.
--   S.claimedName(player) the raw name, for log lines only.
-- ECIdentity installs S.login (family convention "player identity": split-screen seats have
-- none, in Steam mode the name must match its bound SteamID). Until that module has loaded
-- nobody is anyone: a missing identity check must fail closed, never open.
S.login = S.login or function() return nil end
S.principal = S.principal or function() return nil end

-- The account a login name belongs to: md.identity.merged[name].into when that name was merged
-- into another, else the name itself. One hop, never chained. The marker lives in Global ModData,
-- so it rolls back together with the data a merge moved (ServerMap.java:373-409 saves both).
function S.accountOf(name)
    local merged = md and md.identity and md.identity.merged
    local rec = merged and type(name) == "string" and merged[name] or nil
    if type(rec) == "table" and type(rec.into) == "string" and rec.into ~= "" then return rec.into end
    return name
end

function S.sameAccount(a, b)
    if type(a) ~= "string" or type(b) ~= "string" then return false end
    return a == b or S.accountOf(a) == S.accountOf(b)
end

-- Every name sharing this name's account: the account first, then the names merged into it.
-- The one place other code asks for a group (ECIdentity extends it with the logins bound to
-- the same exact SteamID, so a rolled-back merge still finds what its names hold).
function S.groupOf(name)
    local account = S.accountOf(name)
    local out = { account }
    local merged = md and md.identity and md.identity.merged
    if type(account) ~= "string" or type(merged) ~= "table" then return out end
    for alias, rec in pairs(merged) do
        if alias ~= account and type(rec) == "table" and rec.into == account then out[#out + 1] = alias end
    end
    return out
end

-- The raw name, for log lines and for keying a refusal - never an identity.
function S.claimedName(player)
    local ok, name = pcall(function() return player:getUsername() end)
    return ok and type(name) == "string" and name or "?"
end

-- Commands a player without a verified identity may still send, each gated on its own terms:
-- the identity page, the settings page and the system overview (where the settings page reads the
-- options) only on the role, which comes from the connection and not from the name
-- (GameServer.java:2841), so an administrator whose own binding is wrong can repair it and one the
-- one-account policy refuses can still change IdentityMultiAccount. admin.system answers
-- server-wide figures only, nothing of the caller's account. Such a caller is throttled under
-- "?<claimed name>" (below); the writers audit it as its login, or that claim.
S.IDENTITY_EXEMPT = { ["admin.identity"] = true, ["admin.option"] = true, ["admin.system"] = true }

-- Server-side player list (LuaManager.java:4453-4463); the client-side getConnectedPlayers is
-- unavailable on a dedicated server (AGENTS.md API table).
-- The one loop every push and lookup goes through: fn(player, account) for each online player
-- with a verified identity, in the engine's order; returning true stops early. A player without
-- one (a split-screen seat, a name that does not match its SteamID) is never visited, so no push
-- meant for an account can reach someone who merely carries its name.
function S.forEachOnline(fn)
    local players = getOnlinePlayers()
    if not players then return end
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        local who = p and S.principal(p)
        if who and fn(p, who) == true then return end
    end
end

-- An online player who IS this account (any of its login names), or nil. The raw name is
-- compared first so a lookup costs one identity check, not one per online player.
function S.onlinePlayer(account)
    local players = getOnlinePlayers()
    if not players then return nil end
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        local name = p and p:getUsername()
        if name ~= nil and (name == account or S.accountOf(name) == account) and S.principal(p) == account then return p end
    end
    return nil
end

-- The online player who IS this login name (this very character save), or nil. Recovery and
-- every scan that judges a save by its inventory must use this, never S.onlinePlayer: another
-- login of the same account carries another save.
function S.onlineLogin(login)
    local players = getOnlinePlayers()
    if not players then return nil end
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p and p:getUsername() == login and S.login(p) == login then return p end
    end
    return nil
end

-- The raw names of every online seat, verified or not, split-screen included: a set.
function S.onlineNames()
    local out = {}
    local players = getOnlinePlayers()
    if not players then return out end
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        local ok, name = pcall(function() return p:getUsername() end)
        if ok and type(name) == "string" then out[name] = true end
    end
    return out
end

-- Every online seat as the engine lists it, verified or not: ECRecovery's per-tick first
-- sighting keys a session by the player object before any name is trusted (it asks S.login
-- itself before anything is written for a name).
function S.seats()
    return getOnlinePlayers()
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
-- `n` counts starts: one more than the largest `n` already in the file, and server.started
-- carries the same number (S.startIndex). Trimming drops only the oldest lines and keeps their
-- numbers, so a reader can prove an epoch missing from this file is older than its first line
-- (trimmed) and not a lost line in between; old lines without `n` are pre-counter history.
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
                local n = type(rec.n) == "number" and rec.n >= 1 and rec.n == math.floor(rec.n) and rec.n or nil
                out[#out + 1] = { epoch = rec.epoch, loadedSeq = rec.loadedSeq, n = n, flagged = type(rec.flagged) == "table" and rec.flagged or nil }
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
            writer:writeln(EC.jsonEncode({ epoch = h.epoch, loadedSeq = h.loadedSeq, n = h.n, flagged = h.flagged }))
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
    local lastN = 0
    for _, h in ipairs(fileLines) do
        if h.n and h.n > lastN then lastN = h.n end
    end
    S.startIndex = lastN + 1
    local mine = { epoch = md.meta.epoch, loadedSeq = prevSeq, n = S.startIndex, flagged = #flagged > 0 and flagged or nil }
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
    local account = S.principal(player)
    reply(player, "hello.ack", {
        account = account,              -- whose money and mail this session is
        login = S.login(player),        -- the login name (character save) it came in with
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
        unclaimed = S.Mailbox and S.Mailbox.unclaimed(account) or 0,   -- the float button badge
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
        EC.log("unknown command " .. tostring(command) .. " from " .. S.claimedName(player))
        return
    end
    -- Every handler acts for the account S.principal verified, so a player without one is refused
    -- before any handler runs (ECIdentity.refuse: counted for the audit, a notice at most once a
    -- minute, nothing at all for a split-screen seat). An exempt command checks its own gate and
    -- is throttled under the claimed name, apart from the account it claims.
    local username = S.principal(player)
    if username == nil then
        if not S.IDENTITY_EXEMPT[command] then
            if S.Identity then S.Identity.refuse(player, command) end
            return
        end
        username = "?" .. S.claimedName(player)
    end
    if throttled(username, command, EC.now()) then
        return
    end
    -- No command may act before this session's save has been matched against the world once
    -- (ECMailbox: a claim sent before hello would otherwise take a letter the save already has).
    if command ~= "hello" and S.ensureReconciled then S.ensureReconciled(player) end
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
    -- the companion's whitelist export and the account merge pass run once every module is
    -- ready and before any packet: OnServerStarted fires inside startServer (GameServer.java:828,
    -- 1533), ahead of the first packet processing (:894, 910, 939)
    if S.Merge and type(S.Merge.onStarted) == "function" then
        local ok, err = pcall(S.Merge.onStarted)
        if not ok then EC.log("identity start pass failed: " .. tostring(err)) end
    end
    EC.log("server ready version=" .. EC.VERSION .. " schema=" .. tostring(md.schemaVersion)
        .. " epoch=" .. md.meta.epoch .. " loadedSeq=" .. tostring(md.meta.loadedSeq)
        .. " remoteReadOnly=" .. tostring(EC.sandbox("RemoteReadOnly", true)))
end

Events.OnServerStarted.Add(S.onServerStarted)
Events.OnClientCommand.Add(S.dispatch)
Events.OnTickEvenPaused.Add(function() S.pollDurable() end)

return S
