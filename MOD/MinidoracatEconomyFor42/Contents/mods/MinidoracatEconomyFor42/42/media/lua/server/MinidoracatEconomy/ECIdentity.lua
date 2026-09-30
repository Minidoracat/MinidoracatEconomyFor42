-- MinidoracatEconomyFor42 — player identity (server authority). Family convention "player
-- identity" (pz-family-docs/conventions.md) is the contract; this file is Economy's half of it.
--
-- The SteamID is only the factor that proves a player is a login name. Two answers, installed
-- here on ECServer:
--   S.login(player)     which save this player is (the binding verdict), in this order:
--     1. a split-screen seat (getPlayerNum() ~= 0) or an animal (IsoAnimal extends IsoPlayer,
--        IsoAnimal.java:123)                                -> nil
--     2. no name                                            -> nil
--     3. no Steam mode (getSteamModeActive() is false)      -> the name: no factor to check
--     4. the name is bound: not reserved and bound SteamID == player:getSteamID() -> the name, else nil
--     5. the name is not bound: before the first accepted import it is bound on first sight (src
--        LOGIN, see "first sight" at the principal) or nil; afterwards nil (a file with unreadable
--        lines and no import marker counts as imported: fail closed)
--     and in 4, a name whose whitelist SteamID is another exact text of the same double
--     (EXACT_MISMATCH) is nil: both Steam accounts pass the double check, so neither is trusted.
--     Save-scoped bookkeeping keys on it (death settlement, pendingOuts carry-over, recovery,
--     seasons), so it keeps running for a login the one-account policy refuses.
--   S.principal(player) the ACCOUNT (what S.dispatch, S.forEachOnline and S.onlinePlayer ask):
--     S.accountOf(S.login(player)), or nil when the one-account policy (IdentityMultiAccount off,
--     the default) keeps that login out; its refusal carries the reason one_account. First sight
--     never binds a name the policy would keep out.
--
-- Bindings live in Lua/MinidoracatEconomy/identity/bindings.json (one JSON object per line,
-- appended, replayed on start) - never in Global ModData, which any logged-in client can ask for
-- whole (GlobalModDataRequestPacket.java:15,32). Record kinds, the last line of a name winning:
--   bind     {name, sid, exact?, src, from?, at}   src NEWGAME | LOGIN | IMPORT | COMPANION | REBIND
--   reserve  {name, src, at}
--   conflict {name, sid, reason, src, at} | {name, clear = true}   a whitelist row that disagrees
--   import   {at, by, src?, gen?, count?}          the first one starts the strict mode
--   canon    {sid, name, rule, src, at}            the account of one exact SteamID group; the
--                                                  first record of a SteamID wins forever
--   primary  {sid, name, rule, src, at}            the one-account primary of a SteamID (sid: the
--                                                  double's decimal, or the exact text when two
--                                                  texts share the double); the last one wins
-- Writers:
--   * OnNewGame. On the server only CreatePlayerPacket fires it, after naming the new character
--     with the connection's login name and giving it the connection's SteamID
--     (CreatePlayerPacket.java:296-301). An unbound name is bound (a rounded double, exact=false);
--     a bound or reserved one with another SteamID is left alone and audited BIND_CONFLICT.
--   * first sight (Id.login), before the first accepted import: an unbound name is bound to the
--     SteamID it is first seen with (a rounded double, exact=false) when nothing says it was renamed.
--   * the whitelist import, from two sources sharing one pipeline (applyImport):
--       - the administrator's (admin.identity import): whitelist rows the admin client read
--         (requestUsers -> OnNetworkUsersReceived -> getUsers, isInWhitelist rows only;
--         NetworkUsersPacket.java:30-56);
--       - the companion's export, Lua/MinidoracatEconomy/identity/whitelist.json (NDJSON: header,
--         one {id, u, s} row per whitelist account, trailer), read automatically.
--     Unbound names are bound exactly, a rounded NEWGAME binding with the same double is upgraded
--     to exact, differing ones become conflicts (recorded once per name and SteamID, never moved),
--     and names the economy knows that are not whitelist accounts are reserved. The automatic
--     import never unbinds or rebinds, and reserves only within the thresholds below.
--   * the administrator's confirmation of those conflicts (admin.identity rebind). A name that
--     took part in an account merge is never moved (merged_name).
--   * ECMerge, through Id.recordCanon: the first canonical decision of a SteamID group.
--   * the one-account policy: the primary of a SteamID with two or more logins, decided once.
--
-- SteamIDs are numbers here and are only ever compared as numbers - except that two exact
-- whitelist texts are compared as the strings they are. getSteamID() is a long that reaches Lua
-- as a double (KahluaNumberConverter.java:103-116), rounded to a multiple of 16 for a SteamID64;
-- tonumber() is Double.parseDouble (KahluaUtil.java:290-293) and rounds an exact text to the very
-- same double. A SteamID is never passed to tostring, `..`, %d or %.0f: from 1e14 on tostring
-- prints scientific notation (KahluaUtil.java:180-189) and the format paths go wrong above 2^53.
-- Id.sidText writes the exact decimal of a double from two halves below 1e9.
--
-- Engine references (snapshot 42.21.0-20260928):
--   ConnectCoopPacket.java:72-108, 125  a seat's name is the client's; only empty and online names are
--                                       refused; seat 0 replaces a dead player and keeps its onlineID (:93)
--   GameServer.java:2797-2803           Steam mode kicks a connection without a validated SteamID
--   GameServer.java:2830, 2841-2848     seat index, role from the connection, SteamID, then the name
--   LuaManager.java:9359-9364           getSteamModeActive -> SteamUtils.isSteamModeEnabled
--   LuaManager.java:4099-4105           getServerName -> GameServer.serverName on the server
--   IsoPlayer.java:979, 6412, 6445, 6490   getPlayerNum, getSteamID, getUsername, getOnlineID
--   IsoGameCharacter.java:4913          isDead

if not MinidoracatEconomy or not MinidoracatEconomy.Admin then
    require "MinidoracatEconomy/ECAdmin"
end
local EC = MinidoracatEconomy
local S = EC and EC.Server
local L = EC and EC.Ledger
local X = EC and EC.Export
local A = EC and EC.Admin
if not S or not S.AUTHORITY or not L or not X or not A then
    return
end

EC.Identity = EC.Identity or {}
local Id = EC.Identity

Id.FILE = "MinidoracatEconomy/identity/bindings.json"
Id.EXPORT_FILE = "MinidoracatEconomy/identity/whitelist.json"
Id.VERSION = 1
Id.MAX_LINES = 100000              -- far above any whitelist; a longer file is refused, not cut
Id.IMPORT_ROWS_MAX = 10000         -- NetworkUsersPacket itself breaks near 6000 accounts (1 MB buffer)
Id.EXPORT_ROWS_MAX = 50000         -- the companion export's count bound
Id.EXPORT_POLL_MS = 60000          -- the export's first line is read once a minute
Id.EXPORT_LINES_PER_TICK = 250     -- a changed export is read this many lines per tick while running
                                   -- (jsonDecode of 1000 rows took ~25 ms on the game's Kahlua VM)
Id.AUTO_RESERVE_MAX = 50           -- an automatic import reserves at most this many names at once
Id.AUTO_DROP_MIN = 5               -- ... and only when it dropped at most max(5, 0.5%) of the last
Id.AUTO_DROP_RATIO = 0.005         --     accepted export's rows (design 0-6)
Id.NAME_MAX = 64
Id.LIST_MAX = 500                  -- names per list in one reply (the counts are always complete)
Id.NOTICE_MS = 60000               -- identity.unverified at most once a minute per claimed name
Id.FLUSH_MS = 60000                -- IDENTITY_UNVERIFIED audit lines are aggregated per minute
Id.FLUSH_LINES = 10                -- at most this many names per minute, the rest in one "*" line
Id.SID_EXACT = "^7656119%d%d%d%d%d%d%d%d%d%d$"   -- a whitelist text (conventions, point 4)
Id.SCAN_MS = 1000                  -- the online main seats are observed once a second (Id.observe)
Id.SLOT_GAP_MS = 120000            -- a seat unseen this long was a disconnect: its next occupant starts a
                                   -- new occupancy (a respawn replaces the seat within seconds)
Id.NEWGAME_WINDOW_MS = 120000      -- a CreatePlayer is followed by its ConnectCoop within seconds
                                   -- (util/AddCoopPlayer.java:46-151); longer only flags account switches
Id.WRITE_RETRY_MS = 60000          -- after a failed identity-file write, the automatic writers (first
                                   -- sight, the policy primary) wait this long before opening it again
Id.ALERT_RING = 50                 -- identity alerts kept in memory for the admin page
Id.ALERT_TOAST_MS = 10000          -- at most one admin toast every ten seconds, server-wide
Id.MULTI_LIST_MAX = 50             -- Steam accounts with several logins listed in one reply (counts complete)
Id.MULTI_MEMBERS_MAX = 20          -- logins listed per Steam account (the count is complete)

-- Overridable on purpose: the E2E scenarios run a no-steam server and replace these two with a
-- Steam mode and a SteamID per connection slot. Everything below calls them through Id.
Id.steamMode = function() return getSteamModeActive() == true end
Id.sidOf = function(player) return player:getSteamID() end

local bindings = {}          -- name -> { sid, text, exact?, src, at } | { reserved = true, src, at }
local byText = {}            -- exact text -> { n, names = { [name] = true } }: exact bindings, not reserved
local bySid = {}             -- SteamID double -> { n, names }: every binding, exact or rounded, not reserved
local primaries = {}         -- policy key -> { name, rule, at }: the one-account primary (file records)
local doubles = {}           -- SteamID double -> how many exact texts round to it (> 1: a collision)
local disputes = {}          -- name -> { text, reason }: the conflict the file recorded for it
local canon = {}             -- exact text -> { name, rule, src, at }: the group's account, decided once
local importedAt, importedBy = nil, nil     -- the first import; strict from then on
local lastImportAt, lastImportBy = nil, nil
local markerGen, markerCount, markerDigest = nil, nil, nil   -- the last companion import marker in the file
local unreadable = false     -- the file exists but could not be read: nobody is verified
local damaged = false        -- lines were skipped and no import marker survived: strict anyway
local conflicts = nil        -- name -> { sid, text, reason, bound } of the last import (memory only)
local lastImport = nil       -- the last import's summary (memory only)
local refused = {}           -- claimed name -> commands refused since the last flush
local noticeAt = {}          -- claimed name -> when it was last told
local lastFlush = 0
-- the companion export (memory only: the file is read again on every start)
local export = { status = "none" }
local acceptedGen = nil      -- generatedAt of the export accepted during this uptime
local rejectedGen = nil      -- generatedAt of an export whose rows were refused (not read again)
local rejectAudited = {}     -- generatedAt (or status without one) -> audited already
local wlIds = {}             -- name -> whitelist id of the accepted export
local lastNames, lastNamesCount = nil, 0    -- the accepted export's names (this uptime)
local stream = nil           -- an export being read across ticks
local lastPoll = 0
local collisionAudited = {}  -- name .. text -> audited during this uptime
-- first sight and the alerts (memory only: this uptime)
local slots = {}             -- onlineID -> { name, sid, seen, obj, suspect, other }: the seat's occupancy
local newGames = {}          -- SteamID double -> { name, at }: the last OnNewGame of that Steam account
local alerts, alertTotal = {}, 0     -- the last Id.ALERT_RING alerts, and how many this uptime
local alerted = {}           -- kind, name and SteamID -> alerted already
local lastToast, lastScan = 0, 0
local multiWas = nil         -- IdentityMultiAccount at the last scan (a change is announced)
local peekMulti = nil        -- the policy value a verdict is computed under while set
local writeFailedAt = nil    -- when an identity-file write last failed (the automatic writers back off)

-- ---------- numbers ----------

-- Standard Lua (the harness) keeps an exact integer for a 17-digit text where the engine holds a
-- rounded double; adding 0.0 gives both runtimes the same IEEE double (a no-op in Kahlua).
local function double(n) return n + 0.0 end

local function validSid(v)
    return type(v) == "number" and v > 0 and v < math.huge and v == math.floor(v)
end

local function whole(v, lo, hi)
    return type(v) == "number" and v == math.floor(v) and v >= lo and v <= hi
end

-- The exact decimal text of a SteamID double: two halves below 1e9, each printed exactly.
function Id.sidText(v)
    local hi = math.floor(v / 1e9)
    local lo = v - hi * 1e9
    if lo < 0 then
        hi, lo = hi - 1, lo + 1e9
    elseif lo >= 1e9 then
        hi, lo = hi + 1, lo - 1e9
    end
    local low = tostring(math.floor(lo))
    return tostring(math.floor(hi)) .. string.rep("0", 9 - #low) .. low
end

-- A SteamID text back to its double: digits only (parseDouble would also take 7.6E16, blanks
-- and hex floats), then the one rounding both ends share.
local function sidFromText(text, pattern)
    if type(text) ~= "string" or #text > 19 or not string.match(text, pattern or "^%d+$") then return nil end
    local v = tonumber(text)
    if v == nil then return nil end
    v = double(v)
    return validSid(v) and v or nil
end

local function validName(name)
    return type(name) == "string" and name ~= "" and #name <= Id.NAME_MAX and not string.find(name, "%c")
end

-- ---------- bindings and the exact groups ----------

-- Every binding that is not reserved counts for its SteamID double (the one-account policy);
-- only an exact binding (a whitelist text) joins its SteamID's exact group: a rounded double
-- cannot say which of the Steam accounts sharing it the name belongs to.
local function unindex(name, b)
    if b == nil or b.reserved then return end
    local all = bySid[b.sid]
    if all ~= nil and all.names[name] then
        all.names[name], all.n = nil, all.n - 1
        if all.n <= 0 then bySid[b.sid] = nil end
    end
    if not b.exact then return end
    local set = byText[b.text]
    if set == nil or not set.names[name] then return end
    set.names[name], set.n = nil, set.n - 1
    if set.n <= 0 then
        byText[b.text] = nil
        local d = (doubles[b.sid] or 1) - 1
        doubles[b.sid] = d > 0 and d or nil
    end
end

local function index(name, b)
    if b == nil or b.reserved then return end
    local all = bySid[b.sid]
    if all == nil then
        all = { n = 0, names = {} }
        bySid[b.sid] = all
    end
    if not all.names[name] then all.names[name], all.n = true, all.n + 1 end
    if not b.exact then return end
    local set = byText[b.text]
    if set == nil then
        set = { n = 0, names = {} }
        byText[b.text] = set
        doubles[b.sid] = (doubles[b.sid] or 0) + 1
    end
    if not set.names[name] then set.names[name], set.n = true, set.n + 1 end
end

local function setBinding(name, b)
    unindex(name, bindings[name])
    bindings[name] = b
    index(name, b)
end

-- The conflict recorded for this name while its binding still disagrees with it, or nil. A
-- confirmed rebind moves the binding onto the recorded SteamID, which resolves it.
function Id.unresolved(name)
    local d = disputes[name]
    if d == nil then return nil end
    local b = bindings[name]
    if b ~= nil and not b.reserved and b.text == d.text then return nil end
    return d.reason
end

-- Two different exact texts that round to one double: the SteamIDs cannot be told apart at login.
function Id.collides(text)
    local d = sidFromText(text, Id.SID_EXACT)
    return d ~= nil and (doubles[d] or 0) > 1
end

function Id.sidDouble(text)
    return sidFromText(text, Id.SID_EXACT)
end

-- Read-only views for ECMerge (never written through).
function Id.view()
    return { bindings = bindings, byText = byText, disputes = disputes, canon = canon, wlIds = wlIds }
end

-- Every name sharing this name's account (ECServer: the account and the names merged into it),
-- plus every login bound exactly to the same SteamID as the name or its account, so a letter
-- written under a merged name is still found after a world rollback took the marker away.
local baseGroupOf = S.groupOf
function Id.groupOf(name)
    local out = baseGroupOf(name)
    local seen, extra = {}, {}
    for _, n in ipairs(out) do seen[n] = true end
    local function addText(n)
        local b = type(n) == "string" and bindings[n] or nil
        local set = b and not b.reserved and b.exact and byText[b.text] or nil
        if set == nil then return end
        for m in pairs(set.names) do
            if not seen[m] then seen[m] = true; extra[#extra + 1] = m end
        end
    end
    addText(name)
    addText(out[1])
    EC.sortSafe(extra, function(a, b) return a < b end)
    for _, m in ipairs(extra) do out[#out + 1] = m end
    return out
end
S.groupOf = Id.groupOf

-- ---------- the file ----------

local function apply(rec)
    if type(rec) ~= "table" or rec.v ~= Id.VERSION then return false end
    local at = type(rec.at) == "number" and rec.at or 0
    local src = type(rec.src) == "string" and rec.src or "?"
    if rec.k == "import" then
        local by = type(rec.by) == "string" and rec.by or nil
        if importedAt == nil then importedAt, importedBy = at, by end
        lastImportAt, lastImportBy = at, by
        if src == "COMPANION" and whole(rec.gen, 1, 9007199254740991) then
            markerGen, markerCount, markerDigest = rec.gen, tonumber(rec.count), tonumber(rec.digest)
        end
        return true
    end
    if rec.k == "primary" then
        if sidFromText(rec.sid) == nil or not validName(rec.name) then return false end
        primaries[rec.sid] = { name = rec.name, rule = rec.rule, at = at }
        return true
    end
    if rec.k == "canon" then
        if sidFromText(rec.sid, Id.SID_EXACT) == nil or not validName(rec.name) then return false end
        if canon[rec.sid] == nil then
            canon[rec.sid] = { name = rec.name, rule = rec.rule, src = src, at = at }
        end
        return true
    end
    if not validName(rec.name) then return false end
    if rec.k == "bind" then
        local sid = sidFromText(rec.sid)
        if sid == nil then return false end
        setBinding(rec.name, { sid = sid, text = rec.sid, exact = rec.exact == true or nil, src = src, at = at })
        return true
    end
    if rec.k == "reserve" then
        setBinding(rec.name, { reserved = true, src = src, at = at })
        return true
    end
    if rec.k == "conflict" then
        if rec.clear == true then
            disputes[rec.name] = nil
            return true
        end
        if sidFromText(rec.sid, Id.SID_EXACT) == nil or type(rec.reason) ~= "string" then return false end
        disputes[rec.name] = { text = rec.sid, reason = rec.reason }
        return true
    end
    return false
end

-- Replays the file into memory. A missing file is a fresh server; a file that exists but cannot
-- be read (getFileReader swallows the IOException and answers nil, LuaManager.java:5949-5960;
-- cacheFileExists shares its root, :5541-5549) must not read as "nothing bound": Steam mode then
-- verifies nobody until it can be read, instead of trusting every name.
function Id.load()
    bindings, byText, bySid, doubles, disputes, canon, primaries = {}, {}, {}, {}, {}, {}, {}
    unreadable, damaged = false, false
    importedAt, importedBy, lastImportAt, lastImportBy = nil, nil, nil, nil
    markerGen, markerCount, markerDigest = nil, nil, nil
    local reader = nil
    local opened = pcall(function() reader = getFileReader(Id.FILE, false) end)
    if not opened or reader == nil then
        local ok, exists = pcall(cacheFileExists, Id.FILE)
        if not ok or exists then
            unreadable = true
            EC.log("identity file " .. Id.FILE .. " exists but could not be read: in Steam mode nobody is verified until it can be")
        end
        return
    end
    local lines, bad = 0, 0
    local readOk, readErr = pcall(function()
        while true do
            local line = reader:readLine()
            if line == nil then break end
            lines = lines + 1
            if lines > Id.MAX_LINES then error("more than " .. Id.MAX_LINES .. " lines") end
            if not apply(EC.jsonDecode(line)) then bad = bad + 1 end
        end
    end)
    pcall(function() reader:close() end)
    if not readOk then
        unreadable = true
        EC.log("identity file read failed (" .. tostring(readErr) .. "): in Steam mode nobody is verified until it can be read")
        return
    end
    if bad > 0 then EC.log("identity file: " .. bad .. " of " .. lines .. " lines were not usable and were skipped") end
    -- the torn line may have been the only import marker: never fall back to trusting names
    damaged = bad > 0 and importedAt == nil
    if damaged then EC.log("identity file has no usable import marker next to skipped lines: strict mode until an import is accepted") end
end

-- One open, every line, one close (the writer flushes only on close). Records are applied to
-- memory only after this returned true, so memory never holds what the file does not. `auto`
-- marks a writer that runs on its own (first sight, a policy primary): after a failure it does not
-- open the file again for Id.WRITE_RETRY_MS - first sight is asked every second per session.
local function writeLines(recs, auto)
    local ms = EC.now()
    if auto and writeFailedAt ~= nil and ms - writeFailedAt < Id.WRITE_RETRY_MS then return false end
    local writer = nil
    local opened = pcall(function() writer = getFileWriter(Id.FILE, true, true) end)
    if not opened or writer == nil then
        writeFailedAt = ms
        EC.log("identity file " .. Id.FILE .. " could not be opened for writing")
        return false
    end
    local written = pcall(function()
        for _, rec in ipairs(recs) do writer:writeln(EC.jsonEncode(rec)) end
    end)
    local closed = pcall(function() writer:close() end)
    if not (written and closed) then
        writeFailedAt = ms
        EC.log("identity file write failed")
        return false
    end
    writeFailedAt = nil
    return true
end

-- The account of one exact SteamID group, decided once (ECMerge). A SteamID that already has a
-- decision keeps it: returns false and writes nothing.
function Id.recordCanon(text, name, rule, src, ms)
    if unreadable or canon[text] ~= nil or sidFromText(text, Id.SID_EXACT) == nil or not validName(name) then return false end
    if not writeLines({ { v = Id.VERSION, k = "canon", sid = text, name = name, rule = rule, src = src, at = ms } }) then
        return false
    end
    canon[text] = { name = name, rule = rule, src = src, at = ms }
    return true
end

-- ---------- audit ----------

-- Account names go to the ModData ring like any audit line; SteamIDs only to the files.
local function audit(action, target, field, actor, fields, private)
    local rec = { action = action, target = target, field = field, admin = actor or "SYSTEM" }
    for k, v in pairs(fields or {}) do rec[k] = v end
    local ok, err = pcall(X.audit, rec, private)
    if not ok then EC.log("identity audit " .. action .. " failed: " .. tostring(err)) end
end

-- The name an administrator acts under here: the account, else the login this save is (a login
-- the one-account policy keeps out is still verified as itself), else the claim, marked as one.
local function actorOf(player)
    return Id.principal(player) or Id.login(player) or ("?" .. S.claimedName(player))
end
Id.actorOf = actorOf

-- ---------- the principal ----------

-- First sight. Before the first accepted import an unbound name is bound to the SteamID it is
-- first seen with - but the name a seat carries is the client's after a respawn: seat 0 may
-- replace a dead player under any name that is not online (ConnectCoopPacket.java:73-108, keeping
-- the onlineID, :93) and GameServer.receivePlayerConnect names the player with it (:2848), while
-- the character is still the login's own (GameServer.java:2814). A respawn with a new character
-- sends CreatePlayer first (util/AddCoopPlayer.java:48-50: OnNewGame under the true login); a seat
-- reconnected with an existing object sends none (LuaManager.java:6555-6596) and reloads the
-- login's last saved row. That row is written only on CreatePlayer, disconnect (GameServer.java:3040),
-- trades and the periodic save every 180 s (NetworkPlayerManager.java:25-28); ConnectCoop's
-- disconnectPlayer (ConnectCoopPacket.java:94 -> GameServer.java:2616) does not save it, so that
-- respawn usually comes back ALIVE: the alive check does not guard it, the slot rule below does.
-- First sight binds only an alive player with a valid name (not a system account) and SteamID,
-- whose seat occupancy carries no rename evidence, and whom the one-account policy lets in;
-- otherwise the name is nil.
--
-- Rename evidence (Id.observe, this uptime): slots[onlineID] = { name, sid, seen, obj, suspect,
-- other }. An occupancy is one name and one SteamID seen on a seat with gaps under
-- Id.SLOT_GAP_MS; a new one is suspect when the previous occupant had the same SteamID, another
-- name, was seen within Id.SLOT_GAP_MS and is DEAD (slot rule), or when OnNewGame made a character
-- for another login of the same SteamID within Id.NEWGAME_WINDOW_MS (newgame rule). The slot rule
-- needs the death: ConnectCoop refuses to replace a seat whose player exists alive
-- (ConnectCoopPacket.java:69) and replaces only a dead one, keeping its onlineID (:91-100), so every
-- rename on a seat follows a death there - while a player who logs out alive and comes back within
-- the window as another login of the same Steam account (a new connection may reuse the onlineID)
-- is an ordinary account switch. The dead player stays listed until replaced (GameServer.getPlayers
-- :3572-3587 lists connection.players[] with an onlineId; disconnectPlayer at :94 removes it).
-- "Dead" is the previous occupant's own state, never a clock the client could stretch: the
-- occupant object (`obj`, the IsoPlayer last seen on the seat) reading isDead() when the next name
-- is seen. A seat ConnectCoop replaced keeps its health at 0 (a dead player is never revived: the
-- replacement is a new object); a player who logged out alive leaves an object that is still alive.
-- This also covers the window where the server already reads health 0 but has not fired
-- OnCharacterDeath yet: BodyDamage.Update (IsoGameCharacter.java:9054) takes the health to 0 in one
-- update and die() -> Kill -> onKilled -> DoDeath -> OnCharacterDeath runs only in the next one
-- (:9177-9179, :14605-14626, IsoPlayer.java:8350-8368, IsoGameCharacter.java:2024-2025, :4874), with
-- ConnectCoop (:69 reads isDead()) handled in between - so no death event is needed at all, and
-- none is listened to (it also fires for animals, IsoAnimal.java:1141, whose onlineIDs overlap seats).
-- The flag lasts as long as the occupancy: waiting out the window does not clear it.
-- ponytail: a seat that stays out of getOnlinePlayers longer than Id.SLOT_GAP_MS and comes back
-- renamed more than Id.NEWGAME_WINDOW_MS after its CreatePlayer passes both rules; only the
-- one-account policy stands then (the alive check does not: see above). The import (strict mode)
-- closes it for good.
--
-- One account per Steam account (IdentityMultiAccount off, Steam mode). Among the bound, not
-- reserved names of one SteamID double (bySid) one is the primary: the group's exact canon
-- (ECMerge) when there is one, else the recorded primary while it is still bound there, else the
-- (firstSeen, whitelist id, name) smallest, recorded once (k = "primary"). A login is allowed when
-- its account is the primary's (an alias merged into it is). Two exact texts sharing one double
-- are two Steam accounts (Id.collides): each text is its own group, and a rounded binding on such
-- a double cannot be attributed, so the policy leaves it alone.

local function multiAllowed()
    if peekMulti ~= nil then return peekMulti end
    return EC.sandbox("IdentityMultiAccount", false) == true
end

local function firstName(names)
    local best = nil
    for n in pairs(names) do
        if best == nil or n < best then best = n end
    end
    return best
end

local function seatId(player)
    local ok, id = pcall(function() return player:getOnlineID() end)
    return ok and type(id) == "number" and id >= 0 and id or nil
end

-- The administrators online (the read role or more, from the connection) get a toast.
local function tellAdmins(payload)
    local players = getOnlinePlayers()
    if not players then return end
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p and p:getPlayerNum() == 0 and A.canRead(p) then S.reply(p, "identity.alert", payload) end
    end
end

-- One alert per (kind, name, SteamID) and uptime: an IDENTITY_ALERT audit line (the SteamID and
-- the other login only in the private part: the ring is Global ModData any client can request,
-- and "these two logins are one Steam user" is exactly what it must not say), the in-memory ring,
-- and for rename and sid_mismatch a toast to the administrators online, at most one every
-- Id.ALERT_TOAST_MS server-wide.
local function alert(kind, name, sid, other)
    local text = validSid(sid) and Id.sidText(sid) or ""
    local key = kind .. "\1" .. name .. "\1" .. text
    if alerted[key] then return end
    alerted[key] = true
    local ms = EC.now()
    alertTotal = alertTotal + 1
    alerts[#alerts + 1] = { kind = kind, name = name, other = other, at = ms }
    if #alerts > Id.ALERT_RING then table.remove(alerts, 1) end
    -- the public audit line says only that there was an identity alert about this name: its kind
    -- (a rename, one Steam account) and the other login go to the server's files only
    audit("IDENTITY_ALERT", name, "identity", nil, nil, { steamId = text, kind = kind, other = other })
    if (kind == "rename" or kind == "sid_mismatch") and ms - lastToast >= Id.ALERT_TOAST_MS then
        lastToast = ms
        local ok, err = pcall(tellAdmins, { kind = kind, name = name, other = other, at = ms })
        if not ok then EC.log("identity alert push failed: " .. tostring(err)) end
    end
end

local function deadNow(player)
    local ok, dead = pcall(function() return player:isDead() end)
    return ok and dead == true
end

-- The seat's occupancy after seeing this player now (nil without an onlineID).
function Id.observe(player, ms)
    local id = seatId(player)
    if id == nil then return nil end
    ms = ms or EC.now()
    local name, sid = S.claimedName(player), Id.sidOf(player)
    local r = slots[id]
    if r ~= nil and r.name == name and r.sid == sid and ms - r.seen <= Id.SLOT_GAP_MS then
        r.seen, r.obj = ms, player
        return r
    end
    local other = nil
    if validSid(sid) then
        local ng = newGames[sid]
        local prevDead = r ~= nil and r.obj ~= nil and deadNow(r.obj)
        if prevDead and r.sid == sid and r.name ~= name and ms - r.seen <= Id.SLOT_GAP_MS then
            other = r.name
        elseif ng ~= nil and ng.name ~= name and ms - ng.at <= Id.NEWGAME_WINDOW_MS then
            other = ng.name
        end
    end
    r = { name = name, sid = sid, seen = ms, obj = player, suspect = other ~= nil, other = other }
    slots[id] = r
    -- a name that is no valid login is refused anyway and is not worth an alert line or a toast
    if other ~= nil and Id.steamMode() and validName(name) then
        -- a seat renamed back to the login bound to this very SteamID is its owner coming back:
        -- flagged like any rename (the binding decides it anyway), not worth an administrator's toast
        local b = bindings[name]
        if not (b and not b.reserved and b.sid == sid) then alert("rename", name, sid, other) end
    end
    return r
end

-- The seat's own name for the no-duplicate bookkeeping of a death or a new character when the
-- binding verdict is nil - never an identity, never a key for anything the player gains. An
-- existing account may be entered from any Steam account that knows its password
-- (ServerWorldDatabase.authClient :1026-1135 compares only the password; LoginPacket.java:208-209
-- then overwrites whitelist.steamid), so a login that dies while unverified must still settle
-- what it claimed. Only the main seat, never an animal (IsoAnimal extends IsoPlayer), a valid
-- non-system name, and never an occupancy flagged as a suspected rename: an impostor dying
-- under a victim's name must not settle the victim's letters.
function Id.seatName(player)
    if player == nil or instanceof(player, "IsoAnimal") then return nil end
    local okNum, num = pcall(function() return player:getPlayerNum() end)
    if not okNum or num ~= 0 then return nil end
    local okName, name = pcall(function() return player:getUsername() end)
    if not okName or not validName(name) or L.isSystemAccount(name) then return nil end
    local r = Id.observe(player)
    if r ~= nil and r.suspect then return nil end
    return name
end

-- The smallest (md.firstSeen or +inf, whitelist id or +inf, name bytes): the oldest economy
-- account first (0 = older than the tracking), then the oldest whitelist row (the companion's
-- export carries the AUTOINCREMENT id; a manual import has none), then the name. `rule` names
-- the part that decided. `names` holds two or more. ECMerge's canonical and the policy's primary.
function Id.pickCanonical(md, names)
    local list = {}
    for i, name in ipairs(names) do
        local fs = md.firstSeen and md.firstSeen[name]
        list[i] = { name = name, f = type(fs) == "number" and fs or math.huge, w = Id.whitelistId(name) or math.huge }
    end
    EC.sortSafe(list, function(a, b)
        if a.f ~= b.f then return a.f < b.f end
        if a.w ~= b.w then return a.w < b.w end
        return a.name < b.name
    end)
    local a, b = list[1], list[2]
    return a.name, (a.f ~= b.f and "firstSeen") or (a.w ~= b.w and "whitelistId") or "name"
end

-- The primary of one policy group (names: a set of bound names). `peek` decides without writing.
local function primaryOf(key, names, peek)
    for n in pairs(names) do
        local b = bindings[n]
        local c = b and b.exact and canon[b.text] or nil
        if c ~= nil and names[c.name] then return c.name end
    end
    local p = primaries[key]
    if p ~= nil and names[p.name] then return p.name end
    local list = {}
    for n in pairs(names) do list[#list + 1] = n end
    if #list == 1 then return list[1] end
    local name, rule = Id.pickCanonical(S.modData(), list)
    local at = EC.now()
    if not peek and writeLines({ { v = Id.VERSION, k = "primary", sid = key, name = name, rule = rule, src = "POLICY", at = at } }, true) then
        primaries[key] = { name = name, rule = rule, at = at }
    end
    return name
end

-- The primary that keeps `name` (bound as b, or { sid } for a first sight) out, or nil when the
-- policy lets it in.
local function oneAccountBlock(name, b, peek)
    local key, set = nil, nil
    if (doubles[b.sid] or 0) > 1 then
        if not b.exact then return nil end
        key, set = b.text, byText[b.text]
    else
        set = bySid[b.sid]
    end
    if set == nil or set.n == 0 or (set.n == 1 and set.names[name]) or multiAllowed() then return nil end
    local primary = primaryOf(key or Id.sidText(b.sid), set.names, peek)
    if S.accountOf(name) == S.accountOf(primary) then return nil end
    return primary
end

local function firstSight(player, name, peek)
    local sid = Id.sidOf(player)
    if not validName(name) or L.isSystemAccount(name) or not validSid(sid) then return nil end
    local okDead, dead = pcall(function() return player:isDead() end)
    if not okDead or dead then return nil end
    local r
    if peek then
        local id = seatId(player)
        r = id and slots[id] or nil
    else
        r = Id.observe(player)
    end
    if r == nil then return nil end
    if r.suspect then
        -- the rename alert is out already; when the one-account policy would refuse this name
        -- anyway, that is the more useful thing to tell an account switch after a death
        if oneAccountBlock(name, { sid = sid }, true) ~= nil then return nil, "one_account" end
        return nil
    end
    local primary = oneAccountBlock(name, { sid = sid }, peek)
    if primary ~= nil then
        if not peek then alert("one_account", name, sid, primary) end
        return nil, "one_account"
    end
    if peek then return name end
    local others = bySid[sid] and firstName(bySid[sid].names) or nil
    local at, text = EC.now(), Id.sidText(sid)
    if not writeLines({ { v = Id.VERSION, k = "bind", name = name, sid = text, src = "LOGIN", at = at } }, true) then return nil end
    setBinding(name, { sid = sid, text = text, src = "LOGIN", at = at })
    audit("BIND", name, "LOGIN", nil, nil, { steamId = text, exact = false })
    if others ~= nil and multiAllowed() then alert("shared_steam", name, sid, others) end
    return name
end

-- Which save this player is (S.login): the binding verdict, first sight included. `peek` answers
-- without writing a binding or an alert. The second value is "one_account" when first sight kept
-- the name unbound because of the one-account policy.
local function verdict(player, peek)
    if player == nil or player:getPlayerNum() ~= 0 or instanceof(player, "IsoAnimal") then return nil end
    local name = player:getUsername()
    if type(name) ~= "string" or name == "" then return nil end
    if not Id.steamMode() then return name end
    if unreadable then return nil end
    local b = bindings[name]
    if b == nil then
        if importedAt ~= nil or damaged then return nil end
        return firstSight(player, name, peek)
    end
    -- the slot rule reads the previous occupant object's own death, so that object must have been
    -- seen: a bound login is recorded on its seat the first time anything asks about a new object,
    -- not only by the once-a-second scan (one lookup on the hot path; a new object pays for observe)
    if not peek then
        local id = seatId(player)
        local r = id and slots[id] or nil
        if id ~= nil and (r == nil or r.obj ~= player) then Id.observe(player) end
    end
    -- checked on its own: a reserved record has no SteamID, and a player whose SteamID reads as
    -- nil must not match that nil
    if b.reserved or Id.unresolved(name) == "EXACT_MISMATCH" then return nil end
    local sid = Id.sidOf(player)
    if sid ~= b.sid then
        if not peek and validSid(sid) then alert("sid_mismatch", name, sid, nil) end
        return nil
    end
    return name
end

-- The account this player acts as (S.principal), or nil and why: the login, unless the
-- one-account policy keeps its bound name out. `peek` writes no primary and no alert.
local function standing(player, peek)
    local login, why = verdict(player, peek)
    if login == nil then return nil, why end
    local b = Id.steamMode() and bindings[login] or nil
    local primary = b and not b.reserved and oneAccountBlock(login, b, peek) or nil
    if primary ~= nil then
        if not peek then alert("one_account", login, b.sid, primary) end
        return nil, "one_account"
    end
    return S.accountOf(login)
end

function Id.login(player)
    local name = verdict(player)
    return name
end
S.login = Id.login

function Id.principal(player)
    local account = standing(player)
    return account
end
S.principal = Id.principal

-- ---------- OnNewGame ----------

function Id.onNewGame(player)
    if player == nil or unreadable or not Id.steamMode() then return end
    local name, sid = player:getUsername(), Id.sidOf(player)
    if not validName(name) or not validSid(sid) or L.isSystemAccount(name) then return end
    -- the rename evidence: the login this Steam account last made a character for (Id.observe)
    newGames[sid] = { name = name, at = EC.now() }
    local b = bindings[name]
    if b == nil then
        local at, text = EC.now(), Id.sidText(sid)
        local other = bySid[sid] and firstName(bySid[sid].names) or nil
        if not writeLines({ { v = Id.VERSION, k = "bind", name = name, sid = text, src = "NEWGAME", at = at } }) then return end
        setBinding(name, { sid = sid, text = text, src = "NEWGAME", at = at })
        audit("BIND", name, "NEWGAME", nil, nil, { steamId = text, exact = false })
        if other ~= nil and multiAllowed() then alert("shared_steam", name, sid, other) end
    elseif b.reserved or b.sid ~= sid then
        audit("BIND_CONFLICT", name, b.reserved and "RESERVED" or "SID_MISMATCH", nil, nil,
            { steamId = Id.sidText(sid), boundSteamId = b.text })
    end
end

-- ---------- online players whose identity an operation changed ----------

-- Who each main seat is right now, computed without writing anything (the verdict "before").
local function onlineVerdicts()
    local out = {}
    local players = getOnlinePlayers()
    if not players then return out end
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p and p:getPlayerNum() == 0 then
            local who = standing(p, true)
            out[#out + 1] = { player = p, who = who }
        end
    end
    return out
end

-- Tells each main seat whose verdict flipped: verified now (the client says hello again and
-- gets its session) or no longer verified (the client shows why).
local function announce(before)
    for _, entry in ipairs(before) do
        local now, why = standing(entry.player)
        if now ~= nil and entry.who == nil then
            S.reply(entry.player, "identity.verified", {})
        elseif now == nil and entry.who ~= nil then
            noticeAt[S.claimedName(entry.player)] = EC.now()
            S.reply(entry.player, "identity.unverified", { reason = why })
        end
    end
end

-- For ECMerge: a pass that records a canonical can change who the one-account policy lets in.
Id.onlineVerdicts, Id.announce = onlineVerdicts, announce

-- The one-account primary recorded for an exact SteamID text's group, or nil (ECMerge prefers it
-- when it records a new canonical, so the canonical never moves a primary players were told of).
function Id.recordedPrimary(text)
    local d = sidFromText(text, Id.SID_EXACT)
    if d == nil then return nil end
    local p = primaries[(doubles[d] or 0) > 1 and text or Id.sidText(d)]
    return p and p.name or nil
end

-- ---------- import ----------

-- Every name the economy holds something for or remembers: the ones an import reserves when
-- the whitelist has no such account (deleted accounts, split-screen and renamed names).
local function knownNames()
    local md, out = S.modData(), {}
    local function add(name)
        if validName(name) and not L.isSystemAccount(name) then out[name] = true end
    end
    local function keys(t)
        if type(t) == "table" then for name in pairs(t) do add(name) end end
    end
    keys(md.wallets); keys(md.claims); keys(md.frozen); keys(md.firstSeen)
    keys(md.mailbox and md.mailbox.byOwner)
    keys(md.market and md.market.byOwner)
    keys(md.auctions and md.auctions.byOwner)
    for _, byUser in pairs(md.entitlements and md.entitlements.rows or {}) do keys(byUser) end
    return out
end

local function capped(list)
    local out = {}
    for i = 1, math.min(#list, Id.LIST_MAX) do out[i] = list[i] end
    return out, #list > Id.LIST_MAX
end

local function byName(a, b) return a < b end

-- rows: { { u = login name, s = "" | exact SteamID64 text }, ... } as the admin client read them.
-- The whole request is refused on any malformed row (a well-behaved client sends "" for a
-- whitelist SteamID it cannot use): nothing is half imported.
local function checkRows(rows)
    if type(rows) ~= "table" then return nil, "invalid_args" end
    local n = #rows
    if n < 1 or n > Id.IMPORT_ROWS_MAX or EC.countKeys(rows) ~= n then return nil, "invalid_args" end
    local seen = {}
    for i = 1, n do
        local r = rows[i]
        if type(r) ~= "table" or not validName(r.u) or seen[r.u] or type(r.s) ~= "string" then
            return nil, "invalid_args"
        end
        if r.s ~= "" and sidFromText(r.s, Id.SID_EXACT) == nil then return nil, "invalid_steamid", r.u end
        seen[r.u] = true
    end
    return n
end

-- How many rows of the last accepted export this one no longer lists, and the most an automatic
-- import may drop and still reserve (design 0-6). Without the last export's names in memory (the
-- first read after a start) the counts of the last companion marker stand in.
local function dropped(listed, n)
    local base, gone = 0, 0
    if lastNames ~= nil then
        base = lastNamesCount
        for name in pairs(lastNames) do if not listed[name] then gone = gone + 1 end end
    elseif type(markerCount) == "number" then
        base = markerCount
        gone = math.max(0, markerCount - n)
    end
    return gone, math.max(Id.AUTO_DROP_MIN, math.floor(base * Id.AUTO_DROP_RATIO))
end

-- The one import pipeline. rows are checked already; o = { src = "IMPORT" | "COMPANION", actor,
-- ms, auto?, gen?, count? }. Everything is written in one open and applied only afterwards:
-- the marker first (a write cut short keeps "imported" and loses bindings - names then refused -
-- rather than keeping bindings and losing the strict mode they were imported for), and only when
-- something changes or no import was ever accepted, so the same export read again after a
-- restart writes nothing.
local function applyImport(rows, o)
    if unreadable then return nil, "unreadable" end
    local n, ms = #rows, o.ms
    local res = { at = ms, by = o.actor, src = o.src, rows = n, bound = 0, same = 0, upgraded = 0, ignored = 0,
        missing = {}, reserved = {}, collisions = {}, conflicts = 0 }
    local recs, listed, bySid, fresh, pending, clears = {}, {}, {}, {}, {}, {}
    for i = 1, n do
        local name, text = rows[i].u, rows[i].s
        listed[name] = text      -- truthy for every listed row, "" included
        if L.isSystemAccount(name) then
            res.ignored = res.ignored + 1
        elseif text == "" then
            res.missing[#res.missing + 1] = name
        else
            local sid = sidFromText(text, Id.SID_EXACT)
            local first = bySid[sid]
            if first == nil then
                bySid[sid] = { name = name, text = text }
            elseif first.text ~= text then
                -- two Steam accounts that round to one double cannot be told apart: listed
                if not first.collided then first.collided = true; res.collisions[#res.collisions + 1] = first.name end
                res.collisions[#res.collisions + 1] = name
            end
            local b, reason = bindings[name], nil
            if b == nil or (not b.reserved and not b.exact and b.sid == sid) then
                -- a new exact binding, or the rounded NEWGAME one upgraded to the text it rounds from
                recs[#recs + 1] = { v = Id.VERSION, k = "bind", name = name, sid = text, exact = true, src = o.src,
                    from = b and b.src or nil, at = ms }
                fresh[name] = { sid = sid, text = text, exact = true, src = o.src, at = ms }
                if b == nil then res.bound = res.bound + 1 else res.upgraded = res.upgraded + 1 end
            elseif b.reserved then
                reason = "RESERVED"
            elseif b.sid ~= sid then
                reason = "SID_MISMATCH"
            elseif b.text ~= text then
                reason = "EXACT_MISMATCH"   -- both exact, one double, two Steam accounts
            else
                res.same = res.same + 1
            end
            if reason then
                pending[name] = { sid = sid, text = text, reason = reason, bound = b }
                res.conflicts = res.conflicts + 1
            elseif disputes[name] ~= nil then
                clears[#clears + 1] = name
            end
        end
    end
    local candidates = {}
    for name in pairs(knownNames()) do
        if not listed[name] and bindings[name] == nil then candidates[#candidates + 1] = name end
    end
    EC.sortSafe(candidates, byName)
    local gone, dropLimit = dropped(listed, n)
    if o.auto and #candidates > 0 and (#candidates > Id.AUTO_RESERVE_MAX or (importedAt ~= nil and gone > dropLimit)) then
        -- an export that suddenly lacks many accounts is more likely cut short than true: bind,
        -- never lock anybody out on its word (an administrator's import reserves them)
        res.reserveSkipped, res.dropped = #candidates, gone
    else
        for _, name in ipairs(candidates) do
            recs[#recs + 1] = { v = Id.VERSION, k = "reserve", name = name, src = o.src, at = ms }
            res.reserved[#res.reserved + 1] = name
        end
    end
    local pendingNames, newConflicts = {}, {}
    for name in pairs(pending) do pendingNames[#pendingNames + 1] = name end
    EC.sortSafe(pendingNames, byName)
    for _, name in ipairs(pendingNames) do
        local c, d = pending[name], disputes[name]
        -- recorded and audited once per name and SteamID; never moved by an import
        if d == nil or d.text ~= c.text or d.reason ~= c.reason then
            recs[#recs + 1] = { v = Id.VERSION, k = "conflict", name = name, sid = c.text, reason = c.reason, src = o.src, at = ms }
            newConflicts[#newConflicts + 1] = name
        end
    end
    EC.sortSafe(clears, byName)
    for _, name in ipairs(clears) do
        recs[#recs + 1] = { v = Id.VERSION, k = "conflict", name = name, clear = true, src = o.src, at = ms }
    end
    local changed = #recs > 0
    -- every new companion export leaves its generation and a digest of its rows in the file, so
    -- after a restart an older export, or the same generation with other rows, is refused
    local newGen = o.src == "COMPANION" and (o.gen ~= markerGen or o.digest ~= markerDigest)
    if changed or importedAt == nil or newGen then
        table.insert(recs, 1, { v = Id.VERSION, k = "import", at = ms, by = o.actor, src = o.src, gen = o.gen,
            count = o.count, digest = o.digest })
    end
    if #recs > 0 and not writeLines(recs) then return nil, "write_failed" end
    if #recs > 0 then
        if importedAt == nil then importedAt, importedBy = ms, o.actor end
        lastImportAt, lastImportBy = ms, o.actor
        if o.src == "COMPANION" then markerGen, markerCount, markerDigest = o.gen, o.count, o.digest end
    end
    for name, b in pairs(fresh) do setBinding(name, b) end
    for _, name in ipairs(res.reserved) do setBinding(name, { reserved = true, src = o.src, at = ms }) end
    for _, name in ipairs(newConflicts) do disputes[name] = { text = pending[name].text, reason = pending[name].reason } end
    for _, name in ipairs(clears) do disputes[name] = nil end
    conflicts, lastImport = pending, res
    res.changed = changed
    -- the administrator's import is always audited; the companion's only when it changed something
    if o.src ~= "COMPANION" or changed or res.reserveSkipped then
        audit("IDENTITY_IMPORT", "whitelist", o.src == "COMPANION" and "COMPANION" or "MANUAL", o.actor, {
            count = n, bound = res.bound, upgraded = res.upgraded, same = res.same, missing = #res.missing,
            reserved = #res.reserved, conflicts = res.conflicts, collisions = #res.collisions, ignored = res.ignored,
            gen = o.gen, reserveSkipped = res.reserveSkipped },
            { missingNames = res.missing, reservedNames = res.reserved, collisionNames = res.collisions })
    end
    for _, name in ipairs(res.reserved) do audit("BIND_RESERVED", name, o.src, o.actor) end
    for _, name in ipairs(newConflicts) do
        local c = pending[name]
        audit("BIND_CONFLICT", name, c.reason, o.actor, nil, { steamId = c.text, boundSteamId = c.bound.text })
    end
    for _, name in ipairs(res.collisions) do
        local key = name .. "\1" .. listed[name]    -- listed[name] is the row's SteamID text
        if not collisionAudited[key] then
            collisionAudited[key] = true
            audit("BIND_CONFLICT", name, "COLLISION", o.actor)
        end
    end
    return res
end

-- An import was accepted: the merge plan follows it (ECMerge).
local function imported(ms)
    local Mg = S.Merge
    if Mg == nil or type(Mg.onImport) ~= "function" then return end
    local ok, err = pcall(Mg.onImport, ms)
    if not ok then EC.log("merge plan after import failed: " .. tostring(err)) end
end

-- Both import paths take every online seat's verdict before applyImport and tell the players
-- only after the whitelist ids are in and ECMerge has recorded the canonical of each group
-- (imported): the canonical decides a Steam account's one-account primary, so an earlier
-- announcement could tell a player a state the same import is about to change.
function Id.import(rows, actor, ms)
    if unreadable then return nil, "unreadable" end
    local n, err, errName = checkRows(rows)
    if n == nil then return nil, err, errName end
    local before = onlineVerdicts()
    local res, applyErr = applyImport(rows, { src = "IMPORT", actor = actor, ms = ms })
    if res == nil then return nil, applyErr end
    imported(ms)
    announce(before)
    return res
end

-- ---------- the companion export ----------

local function serverName()
    local ok, name = pcall(getServerName)
    return ok and type(name) == "string" and name or nil
end

-- The header, in the design's order (7.2 step 1). An equal generatedAt is decided by the caller.
local function headerError(h)
    if type(h) ~= "table" or h.type ~= "whitelist" or h.v ~= 1 then return "malformed", "header" end
    local name = serverName()
    if name == nil or h.serverName ~= name then return "server_mismatch", "serverName" end
    if not whole(h.generatedAt, 1, 9007199254740991) then return "malformed", "generatedAt" end
    local last = acceptedGen or markerGen
    if last ~= nil and h.generatedAt < last then return "stale", "generatedAt" end
    if not whole(h.count, 1, Id.EXPORT_ROWS_MAX) then return "malformed", "count" end
    return nil
end

-- One refusal: the status says why, and it is audited once per generatedAt (or once per status
-- when the header carried none). Nothing of the file is applied.
local function exportReject(status, detail, h)
    local gen = type(h) == "table" and whole(h.generatedAt, 1, 9007199254740991) and h.generatedAt or nil
    export = { status = status, generatedAt = gen, count = type(h) == "table" and tonumber(h.count) or nil,
        acceptedAt = export.acceptedAt, reason = detail }
    local key = gen or status
    if rejectAudited[key] then return end
    rejectAudited[key] = true
    audit("IDENTITY_EXPORT_REJECTED", "whitelist", status, nil, { generatedAt = gen, reason = detail })
end

local function rowError(st, r)
    if not whole(r.id, 1, 9007199254740991) or st.ids[r.id] then return "id" end
    if not validName(r.u) or st.names[r.u] then return "u" end
    if type(r.s) ~= "string" or (r.s ~= "" and sidFromText(r.s, Id.SID_EXACT) == nil) then return "s" end
    st.ids[r.id], st.names[r.u] = true, true
    return nil
end

-- Reads up to `budget` lines (all of them when nil). nil while more remains, "ok" when the rows,
-- the trailer and the end of the file all agree with the header, otherwise status and detail.
local function readLines(st, budget)
    local status, detail = nil, nil
    local ok, err = pcall(function()
        local left = budget
        while left == nil or left > 0 do
            local line = st.reader:readLine()
            if line == nil then
                if st.ended then status = "ok" else status, detail = "truncated", "no trailer after " .. #st.rows .. " rows" end
                return
            end
            if left ~= nil then left = left - 1 end
            if st.ended then status, detail = "malformed", "a line after the trailer"; return end
            local r = EC.jsonDecode(line)
            local where = "line " .. tostring(#st.rows + 2)
            if type(r) ~= "table" then status, detail = "malformed", where; return end
            if r.type == "end" then
                if r.count ~= st.header.count then status, detail = "malformed", "trailer count"; return end
                if #st.rows ~= st.header.count then status, detail = "truncated", #st.rows .. " of " .. st.header.count .. " rows"; return end
                st.ended = true
            else
                if #st.rows >= st.header.count then status, detail = "malformed", "more rows than count"; return end
                local bad = rowError(st, r)
                if bad then status, detail = "malformed", where .. ": " .. bad; return end
                st.rows[#st.rows + 1] = { u = r.u, s = r.s, id = r.id }
                st.digest = EC.hashUpdate(st.digest, line)
            end
        end
    end)
    if not ok then return "unreadable", tostring(err) end
    return status, detail
end

local function finishExport(st, status, detail, ms)
    pcall(function() st.reader:close() end)
    if status == "ok" and st.gen == markerGen and markerDigest ~= nil and st.digest ~= markerDigest then
        status, detail = "replaced", "same generatedAt, other rows"
    end
    if status ~= "ok" then
        rejectedGen = st.gen      -- refused whole: not read again until a newer export
        exportReject(status, detail, st.header)
        return
    end
    local before = onlineVerdicts()
    local res, err = applyImport(st.rows, { src = "COMPANION", actor = "COMPANION", ms = ms, auto = true,
        gen = st.gen, count = #st.rows, digest = st.digest })
    if res == nil then
        -- our own file failed, not the export: the next poll tries again
        export.reason = err
        EC.log("companion whitelist export not applied: " .. tostring(err))
        return
    end
    acceptedGen, rejectedGen = st.gen, nil
    wlIds, lastNames, lastNamesCount = {}, st.names, #st.rows
    for _, r in ipairs(st.rows) do wlIds[r.u] = r.id end
    export = { status = res.reserveSkipped and "reserve_suspect" or "accepted", generatedAt = st.gen,
        count = #st.rows, acceptedAt = ms,
        reason = res.reserveSkipped and (tostring(res.reserveSkipped) .. " reservations skipped, " .. tostring(res.dropped) .. " rows dropped") or nil }
    imported(ms)
    announce(before)
end

-- Reads the export's first line and, when it names a newer export, starts reading it: all of it
-- at once on `startup` (nothing else runs yet), otherwise Id.EXPORT_LINES_PER_TICK lines a tick
-- through the same open reader.
function Id.pollExport(ms, startup)
    if stream ~= nil or unreadable or not Id.steamMode() then return end
    local reader = nil
    local opened = pcall(function() reader = getFileReader(Id.EXPORT_FILE, false) end)
    if not opened or reader == nil then
        local ok, exists = pcall(cacheFileExists, Id.EXPORT_FILE)
        if ok and not exists then
            export = { status = "missing", acceptedAt = export.acceptedAt }
        else
            exportReject("unreadable", "open")
        end
        return
    end
    local okLine, line = pcall(function() return reader:readLine() end)
    local h = okLine and type(line) == "string" and EC.jsonDecode(line) or nil
    local status, detail
    if not okLine then status, detail = "unreadable", "header" else status, detail = headerError(h) end
    if status == nil and ((not startup and acceptedGen ~= nil and h.generatedAt <= acceptedGen) or h.generatedAt == rejectedGen) then
        pcall(function() reader:close() end)      -- unchanged, or refused whole already
        return
    end
    if status ~= nil then
        pcall(function() reader:close() end)
        exportReject(status, detail, h)
        return
    end
    local st = { reader = reader, header = h, gen = h.generatedAt, rows = {}, ids = {}, names = {},
        digest = EC.hashInit() }
    if startup then
        local s, d = readLines(st, nil)
        finishExport(st, s, d, ms)
    else
        stream = st
    end
end

function Id.continueExport(ms)
    local st = stream
    if st == nil then return end
    local status, detail = readLines(st, Id.EXPORT_LINES_PER_TICK)
    if status == nil then return end
    stream = nil
    finishExport(st, status, detail, ms)
end

-- The start-up read (ECMerge.onStarted, after every module's init).
function Id.startExport(ms)
    lastPoll = ms
    Id.pollExport(ms, true)
end

function Id.whitelistId(name)
    return wlIds[name]
end

-- ---------- rebind (the administrator's confirmation) ----------

-- A name that took part in an account merge, as the alias or as the account. Moving it would
-- hand the merged account to whoever holds the new SteamID.
local function tookPartInMerge(name)
    local merged = S.modData().identity.merged
    if merged[name] ~= nil then return true end
    for _, rec in pairs(merged) do
        if type(rec) == "table" and rec.into == name then return true end
    end
    return false
end

-- Moves the named conflicts of the last import to the whitelist's SteamID. A name the last
-- import did not list as a conflict (or one already moved) is returned as stale. Nothing else
-- can touch a conflicting binding in between: OnNewGame and the automatic import never change a
-- bound name, and a new import replaces the whole list.
function Id.rebind(names, actor, reason, ms)
    if unreadable then return nil, "unreadable" end
    if type(names) ~= "table" or #names < 1 or #names > Id.LIST_MAX or EC.countKeys(names) ~= #names then
        return nil, "invalid_args"
    end
    for _, name in ipairs(names) do
        if not validName(name) then return nil, "invalid_args" end
        if tookPartInMerge(name) then return nil, "merged_name", name end
    end
    if conflicts == nil then return nil, "import_first" end
    local recs, moved, stale, seen = {}, {}, {}, {}
    for _, name in ipairs(names) do
        if seen[name] then return nil, "invalid_args" end
        seen[name] = true
        local c = conflicts[name]
        if c ~= nil then
            recs[#recs + 1] = { v = Id.VERSION, k = "bind", name = name, sid = c.text, exact = true, src = "REBIND", at = ms }
            moved[#moved + 1] = name
        else
            stale[#stale + 1] = name
        end
    end
    if #recs > 0 then
        local before = onlineVerdicts()
        if not writeLines(recs) then return nil, "write_failed" end
        for _, name in ipairs(moved) do
            local c = conflicts[name]
            setBinding(name, { sid = c.sid, text = c.text, exact = true, src = "REBIND", at = ms })
            conflicts[name] = nil
            audit("BIND_MOVE", name, "REBIND", actor, { reason = reason },
                { steamId = c.text, before = c.bound.reserved and "reserved" or c.bound.text })
        end
        announce(before)
    end
    return { rebound = #moved, moved = moved, stale = stale }
end

-- ---------- status ----------

-- status.multi: every Steam account with two or more bound logins, as the one-account policy
-- sees it right now (decided without writing): each login is the primary, merged into it,
-- blocked by the policy, or allowed. Lists capped, counts complete.
local function multiView()
    local groups, logins, blocked = {}, 0, 0
    local function add(key, set)
        local primary = primaryOf(key, set.names, true)
        local members = {}
        for name in pairs(set.names) do
            local state = "allowed"
            if name == primary then
                state = "primary"
            elseif S.accountOf(name) == S.accountOf(primary) then
                state = "merged"
            elseif oneAccountBlock(name, bindings[name], true) ~= nil then
                state, blocked = "blocked", blocked + 1
            end
            members[#members + 1] = { name = name, state = state }
        end
        EC.sortSafe(members, function(a, b)
            if (a.state == "primary") ~= (b.state == "primary") then return a.state == "primary" end
            return a.name < b.name
        end)
        local shown = {}
        for i = 1, math.min(#members, Id.MULTI_MEMBERS_MAX) do shown[i] = members[i] end
        logins = logins + #members
        groups[#groups + 1] = { primary = primary, count = #members, members = shown }
    end
    for d, set in pairs(bySid) do
        if set.n >= 2 and (doubles[d] or 0) <= 1 then add(Id.sidText(d), set) end
    end
    -- a double two Steam accounts share: each exact text is its own group
    for text, set in pairs(byText) do
        local d = set.n >= 2 and sidFromText(text, Id.SID_EXACT) or nil
        if d ~= nil and (doubles[d] or 0) > 1 then add(text, set) end
    end
    EC.sortSafe(groups, function(a, b) return a.primary < b.primary end)
    local list = {}
    for i = 1, math.min(#groups, Id.MULTI_LIST_MAX) do list[i] = groups[i] end
    return { steamIds = #groups, logins = logins, blocked = blocked, list = list,
        truncated = #groups > Id.MULTI_LIST_MAX or nil }
end

function Id.status()
    local bound, reserved = 0, 0
    for _, b in pairs(bindings) do
        if b.reserved then reserved = reserved + 1 else bound = bound + 1 end
    end
    local alertList = {}
    for i = #alerts, 1, -1 do alertList[#alertList + 1] = alerts[i] end   -- newest first
    local names = {}
    for name in pairs(conflicts or {}) do names[#names + 1] = name end
    EC.sortSafe(names, byName)
    local shown, cut = capped(names)
    local list = {}
    for i, name in ipairs(shown) do
        local c = conflicts[name]
        list[i] = { name = name, reason = c.reason, whitelist = c.text,
            bound = c.bound.text or "", boundExact = c.bound.exact == true }
    end
    return {
        steam = Id.steamMode(), unreadable = unreadable, damaged = (damaged and importedAt == nil) or nil,
        imported = importedAt ~= nil, importedAt = importedAt, importedBy = importedBy,
        lastImportAt = lastImportAt, lastImportBy = lastImportBy,
        bound = bound, reserved = reserved,
        conflicts = list, conflictCount = #names, conflictsTruncated = cut or nil,
        -- before the first import: unbound names are bound on first sight (with the rename checks)
        firstSight = (Id.steamMode() and not unreadable and importedAt == nil and not damaged) or nil,
        multiAccount = multiAllowed(), multi = multiView(),
        alerts = alertList, alertCount = alertTotal,
    }
end

-- The companion export as the admin page shows it.
function Id.exportStatus()
    return { status = export.status, generatedAt = export.generatedAt, count = export.count,
        acceptedAt = export.acceptedAt, reason = export.reason }
end

-- The last import's summary as a reply carries it: lists capped, counts complete.
local function importView(res)
    if res == nil then return nil end
    local out = {}
    for k, v in pairs(res) do if type(v) ~= "table" then out[k] = v end end
    local cut
    out.missing, cut = capped(res.missing); out.missingTruncated = cut or nil
    out.reserved, cut = capped(res.reserved); out.reservedTruncated = cut or nil
    out.collisions, cut = capped(res.collisions); out.collisionsTruncated = cut or nil
    out.missingCount, out.reservedCount, out.collisionCount = #res.missing, #res.reserved, #res.collisions
    return out
end

-- ---------- refusals ----------

-- A player without a verified identity sent a command (S.dispatch). A split-screen seat gets
-- nothing at all; a main seat is counted for the minute's IDENTITY_UNVERIFIED line and told why
-- at most once a minute - never once per command.
function Id.refuse(player, command)
    local ok, seat = pcall(function() return player:getPlayerNum() end)
    if not ok or seat ~= 0 then return end
    local name, ms = S.claimedName(player), EC.now()
    refused[name] = (refused[name] or 0) + 1
    if ms - (noticeAt[name] or 0) >= Id.NOTICE_MS then
        noticeAt[name] = ms
        -- only the one-account refusal says which rule it is: telling an impostor which check
        -- caught them would only help the next attempt
        local _, why = standing(player, true)
        S.reply(player, "identity.unverified", { reason = why })
    end
end

local function flush(ms)
    local names = {}
    for name in pairs(refused) do names[#names + 1] = name end
    if #names > 0 then
        EC.sortSafe(names, function(a, b)
            if refused[a] ~= refused[b] then return refused[a] > refused[b] end
            return a < b
        end)
        local rest, restNames = 0, 0
        for i, name in ipairs(names) do
            if i <= Id.FLUSH_LINES then
                audit("IDENTITY_UNVERIFIED", name, "commands", nil, { after = refused[name] })
            else
                rest, restNames = rest + refused[name], restNames + 1
            end
        end
        if restNames > 0 then audit("IDENTITY_UNVERIFIED", "*", "commands", nil, { after = rest, names = restNames }) end
    end
    refused = {}
    for name, at in pairs(noticeAt) do
        if ms - at >= Id.NOTICE_MS then noticeAt[name] = nil end
    end
end

-- Once a second: every online main seat is observed (the rename evidence), and a change of
-- IdentityMultiAccount (admin.option or the sandbox file) re-evaluates everybody online under the
-- old and the new value and tells each seat whose verdict flipped.
local function scan(ms)
    if Id.steamMode() then
        local players = getOnlinePlayers()
        for i = 0, (players and players:size() or 0) - 1 do
            local p = players:get(i)
            if p and p:getPlayerNum() == 0 then Id.observe(p, ms) end
        end
    end
    local multi = EC.sandbox("IdentityMultiAccount", false) == true
    if multiWas ~= nil and multi ~= multiWas then
        peekMulti = multiWas
        local ok, before = pcall(onlineVerdicts)
        peekMulti = nil
        if ok then announce(before) else EC.log("identity policy change: " .. tostring(before)) end
    end
    multiWas = multi
end

function Id.onTick()
    local ms = EC.now()
    if stream ~= nil then
        Id.continueExport(ms)
    elseif ms - lastPoll >= Id.EXPORT_POLL_MS then
        lastPoll = ms
        Id.pollExport(ms, false)
    end
    if ms - lastScan >= Id.SCAN_MS then
        lastScan = ms
        scan(ms)
    end
    if ms - lastFlush < Id.FLUSH_MS then return end
    lastFlush = ms
    flush(ms)
end

-- ---------- admin.identity ----------

-- admin.identity { action = "status" | "import" | "rebind", requestId, rows?, names?, reason? }
-- Exempt from the identity gate (S.IDENTITY_EXEMPT): status needs the read role, import and
-- rebind the write role; roles come from the connection, never from the name. Every reply
-- carries the status, with the companion export (status.export) and the merge plan (status.merge).
S.handlers["admin.identity"] = function(player, args)
    args = type(args) == "table" and args or {}
    local action = args.action
    local requestId = type(args.requestId) == "string" and #args.requestId <= A.REQUEST_ID_MAX
        and not string.find(args.requestId, "%c") and args.requestId or nil
    local write = action == "import" or action == "rebind"
    local res
    if action ~= "status" and not write then
        res = { ok = false, error = "invalid_args" }
    elseif write and not A.isAdmin(player) or not write and not A.canRead(player) then
        EC.log("admin.identity " .. tostring(action) .. " refused for " .. S.claimedName(player) .. " role=" .. A.roleName(player))
        res = { ok = false, error = "forbidden" }
    elseif write and not Id.steamMode() then
        res = { ok = false, error = "not_steam" }
    elseif action == "import" then
        local out, err, name = Id.import(args.rows, actorOf(player), EC.now())
        res = out and { ok = true } or { ok = false, error = err, name = name }
    elseif action == "rebind" then
        local rerr, reason = A.reasonError(args.reason)
        if rerr then
            res = { ok = false, error = rerr }
        else
            local out, err, name = Id.rebind(args.names, actorOf(player), reason, EC.now())
            res = out and { ok = true, rebound = out.rebound, moved = out.moved, stale = out.stale }
                or { ok = false, error = err, name = name }
        end
    else
        res = { ok = true }
    end
    res.action, res.requestId = action, requestId
    res.perms = { read = A.canRead(player), write = A.isAdmin(player) }
    res.status = Id.status()
    res.status.export = Id.exportStatus()
    res.status.merge = S.Merge and S.Merge.status() or nil
    res.last = importView(lastImport)
    S.reply(player, "admin.identity", res)
end

-- ---------- lifecycle ----------

-- On every start: the bindings are replayed from the file; what only lived in memory (the
-- last import's conflicts, refusal counters, the accepted export) starts empty. The export
-- itself is read again once every module is ready (Id.startExport, from ECMerge).
function Id.init(md)
    conflicts, lastImport, refused, noticeAt, lastFlush = nil, nil, {}, {}, 0
    if stream ~= nil then pcall(function() stream.reader:close() end) end
    export, acceptedGen, rejectedGen, rejectAudited, stream = { status = "none" }, nil, nil, {}, nil
    wlIds, lastNames, lastNamesCount, lastPoll, collisionAudited = {}, nil, 0, 0, {}
    slots, newGames, alerts, alertTotal, alerted = {}, {}, {}, 0, {}
    lastToast, lastScan, multiWas, peekMulti, writeFailedAt = 0, 0, nil, nil, nil
    md = md or S.modData()
    if type(md.identity) ~= "table" then md.identity = {} end
    if type(md.identity.merged) ~= "table" then md.identity.merged = {} end
    Id.load()
end

S.Identity = Id
S.onInit(Id.init)
-- OnNewGame binds (and records the rename evidence) before anything else asks who the player is:
-- ECMailbox and ECRewards, loaded earlier, ask S.login synchronously in theirs, and a first sight
-- there would bind under LOGIN and judge the seat before this character's newGames record exists.
-- Handlers run in the order they were added, so theirs go back in after ours.
-- Checked one by one: a nil (a module missing from a changed require order) must not end the list.
local later = {}
if S.Mailbox and type(S.Mailbox.onNewGame) == "function" then later[#later + 1] = S.Mailbox.onNewGame end
if S.Rewards and type(S.Rewards.onNewGame) == "function" then later[#later + 1] = S.Rewards.onNewGame end
for _, fn in ipairs(later) do Events.OnNewGame.Remove(fn) end
Events.OnNewGame.Add(Id.onNewGame)
for _, fn in ipairs(later) do Events.OnNewGame.Add(fn) end
Events.OnTickEvenPaused.Add(Id.onTick)

return Id
