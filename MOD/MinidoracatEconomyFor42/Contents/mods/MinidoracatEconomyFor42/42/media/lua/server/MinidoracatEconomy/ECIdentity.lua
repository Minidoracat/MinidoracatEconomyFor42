-- MinidoracatEconomyFor42 — player identity (server authority). Family convention "player
-- identity" (pz-family-docs/conventions.md) is the contract; this file is Economy's half of it.
--
-- The account key stays the login name; the SteamID is only the factor that proves a player is
-- that name. S.principal(player) (installed here, asked by S.dispatch, S.forEachOnline and
-- S.onlinePlayer) answers, in this order:
--   1. a split-screen seat (getPlayerNum() ~= 0)          -> nil: it shares the main seat's SteamID
--   2. no name                                            -> nil
--   3. no Steam mode (getSteamModeActive() is false)      -> the name: no factor to check
--   4. the name is bound: not reserved and bound SteamID == player:getSteamID() -> the name, else nil
--   5. the name is not bound: before the first administrator import -> the name, afterwards nil
--
-- Bindings live in Lua/MinidoracatEconomy/identity/bindings.json (one JSON object per line,
-- appended, replayed on start) - never in Global ModData, which any logged-in client can ask for
-- whole (GlobalModDataRequestPacket.java:15,32). Three writers only:
--   * OnNewGame. On the server only CreatePlayerPacket fires it, after naming the new character
--     with the connection's login name and giving it the connection's SteamID
--     (CreatePlayerPacket.java:296-301). An unbound name is bound; a bound or reserved one with
--     another SteamID is left alone and audited BIND_CONFLICT.
--   * the administrator's whitelist import (admin.identity import): whitelist rows sent by the
--     admin client (requestUsers -> OnNetworkUsersReceived -> getUsers, isInWhitelist rows only;
--     NetworkUsersPacket.java:30-56). Unbound names are bound, differing ones become conflicts,
--     and names the economy knows that are not whitelist accounts are reserved.
--   * the administrator's confirmation of those conflicts (admin.identity rebind).
--
-- SteamIDs are numbers here and are only ever compared as numbers. getSteamID() is a long that
-- reaches Lua as a double (KahluaNumberConverter.java:103-116), rounded to a multiple of 16 for a
-- SteamID64; tonumber() is Double.parseDouble (KahluaUtil.java:290-293) and rounds an exact text
-- to the very same double. A SteamID is never passed to tostring, `..`, %d or %.0f: from 1e14 on
-- tostring prints scientific notation (KahluaUtil.java:180-189) and the format paths go wrong
-- above 2^53. Id.sidText writes the exact decimal of a double from two halves below 1e9.
--
-- Engine references (snapshot 42.21.0-20260928):
--   ConnectCoopPacket.java:72-97, 125   a seat's name is the client's; only empty and online names are refused
--   GameServer.java:2797-2803           Steam mode kicks a connection without a validated SteamID
--   GameServer.java:2830, 2841-2848     seat index, role from the connection, SteamID, then the name
--   LuaManager.java:9359-9364           getSteamModeActive -> SteamUtils.isSteamModeEnabled
--   IsoPlayer.java:979, 6412, 6445      getPlayerNum, getSteamID, getUsername

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
Id.VERSION = 1
Id.MAX_LINES = 100000              -- far above any whitelist; a longer file is refused, not cut
Id.IMPORT_ROWS_MAX = 10000         -- NetworkUsersPacket itself breaks near 6000 accounts (1 MB buffer)
Id.NAME_MAX = 64
Id.LIST_MAX = 500                  -- names per list in one reply (the counts are always complete)
Id.NOTICE_MS = 60000               -- identity.unverified at most once a minute per claimed name
Id.FLUSH_MS = 60000                -- IDENTITY_UNVERIFIED audit lines are aggregated per minute
Id.FLUSH_LINES = 10                -- at most this many names per minute, the rest in one "*" line
Id.SID_EXACT = "^7656119%d%d%d%d%d%d%d%d%d%d$"   -- a whitelist text (conventions, point 4)

-- Overridable on purpose: the E2E scenarios run a no-steam server and replace these two with a
-- Steam mode and a SteamID per connection slot. Everything below calls them through Id.
Id.steamMode = function() return getSteamModeActive() == true end
Id.sidOf = function(player) return player:getSteamID() end

local bindings = {}          -- name -> { sid, text, exact?, src, at } | { reserved = true, src, at }
local importedAt, importedBy = nil, nil     -- the first import; strict from then on
local lastImportAt, lastImportBy = nil, nil
local unreadable = false     -- the file exists but could not be read: nobody is verified
local conflicts = nil        -- name -> { sid, text, reason, bound } of the last import (memory only)
local lastImport = nil       -- the last import's summary (memory only)
local refused = {}           -- claimed name -> commands refused since the last flush
local noticeAt = {}          -- claimed name -> when it was last told
local lastFlush = 0

-- ---------- numbers ----------

-- Standard Lua (the harness) keeps an exact integer for a 17-digit text where the engine holds a
-- rounded double; adding 0.0 gives both runtimes the same IEEE double (a no-op in Kahlua).
local function double(n) return n + 0.0 end

local function validSid(v)
    return type(v) == "number" and v > 0 and v < math.huge and v == math.floor(v)
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

-- ---------- the principal ----------

function Id.principal(player)
    if player == nil or player:getPlayerNum() ~= 0 then return nil end
    local name = player:getUsername()
    if type(name) ~= "string" or name == "" then return nil end
    if not Id.steamMode() then return name end
    if unreadable then return nil end
    local b = bindings[name]
    if b == nil then return importedAt == nil and name or nil end
    -- checked on its own: a reserved record has no SteamID, and a player whose SteamID reads as
    -- nil must not match that nil
    if b.reserved then return nil end
    return Id.sidOf(player) == b.sid and name or nil
end
S.principal = Id.principal

-- ---------- the file ----------

local function apply(rec)
    if type(rec) ~= "table" or rec.v ~= Id.VERSION then return false end
    local at = type(rec.at) == "number" and rec.at or 0
    if rec.k == "import" then
        local by = type(rec.by) == "string" and rec.by or nil
        if importedAt == nil then importedAt, importedBy = at, by end
        lastImportAt, lastImportBy = at, by
        return true
    end
    if not validName(rec.name) then return false end
    local src = type(rec.src) == "string" and rec.src or "?"
    if rec.k == "bind" then
        local sid = sidFromText(rec.sid)
        if sid == nil then return false end
        bindings[rec.name] = { sid = sid, text = rec.sid, exact = rec.exact == true or nil, src = src, at = at }
        return true
    end
    if rec.k == "reserve" then
        bindings[rec.name] = { reserved = true, src = src, at = at }
        return true
    end
    return false
end

-- Replays the file into memory. A missing file is a fresh server; a file that exists but cannot
-- be read (getFileReader swallows the IOException and answers nil, LuaManager.java:5949-5960;
-- cacheFileExists shares its root, :5541-5549) must not read as "nothing bound": Steam mode then
-- verifies nobody until it can be read, instead of trusting every name.
function Id.load()
    bindings, unreadable = {}, false
    importedAt, importedBy, lastImportAt, lastImportBy = nil, nil, nil, nil
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
end

-- One open, every line, one close (the writer flushes only on close). Records are applied to
-- memory only after this returned true, so memory never holds what the file does not.
local function writeLines(recs)
    local writer = nil
    local opened = pcall(function() writer = getFileWriter(Id.FILE, true, true) end)
    if not opened or writer == nil then
        EC.log("identity file " .. Id.FILE .. " could not be opened for writing")
        return false
    end
    local written = pcall(function()
        for _, rec in ipairs(recs) do writer:writeln(EC.jsonEncode(rec)) end
    end)
    local closed = pcall(function() writer:close() end)
    if not (written and closed) then EC.log("identity file write failed") end
    return written and closed
end

-- ---------- audit ----------

-- Account names go to the ModData ring like any audit line; SteamIDs only to the files.
local function audit(action, target, field, actor, fields, private)
    local rec = { action = action, target = target, field = field, admin = actor or "SYSTEM" }
    for k, v in pairs(fields or {}) do rec[k] = v end
    local ok, err = pcall(X.audit, rec, private)
    if not ok then EC.log("identity audit " .. action .. " failed: " .. tostring(err)) end
end

-- The name an administrator acts under here: verified, or marked as the claim it is.
local function actorOf(player)
    return Id.principal(player) or ("?" .. S.claimedName(player))
end

-- ---------- OnNewGame ----------

function Id.onNewGame(player)
    if player == nil or unreadable or not Id.steamMode() then return end
    local name, sid = player:getUsername(), Id.sidOf(player)
    if not validName(name) or not validSid(sid) or L.isSystemAccount(name) then return end
    local b = bindings[name]
    if b == nil then
        local at, text = EC.now(), Id.sidText(sid)
        if not writeLines({ { v = Id.VERSION, k = "bind", name = name, sid = text, src = "NEWGAME", at = at } }) then return end
        bindings[name] = { sid = sid, text = text, src = "NEWGAME", at = at }
        audit("BIND", name, "NEWGAME", nil, nil, { steamId = text, exact = false })
    elseif b.reserved or b.sid ~= sid then
        audit("BIND_CONFLICT", name, b.reserved and "RESERVED" or "SID_MISMATCH", nil, nil,
            { steamId = Id.sidText(sid), boundSteamId = b.text })
    end
end

-- ---------- online players whose identity an operation changed ----------

local function onlineVerdicts()
    local out = {}
    local players = getOnlinePlayers()
    if not players then return out end
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p and p:getPlayerNum() == 0 then out[#out + 1] = { player = p, who = Id.principal(p) } end
    end
    return out
end

-- Tells each main seat whose verdict flipped: verified now (the client says hello again and
-- gets its session) or no longer verified (the client shows why).
local function announce(before)
    for _, entry in ipairs(before) do
        local now = Id.principal(entry.player)
        if now ~= nil and entry.who == nil then
            S.reply(entry.player, "identity.verified", {})
        elseif now == nil and entry.who ~= nil then
            noticeAt[S.claimedName(entry.player)] = EC.now()
            S.reply(entry.player, "identity.unverified", {})
        end
    end
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

function Id.import(rows, actor, ms)
    if unreadable then return nil, "unreadable" end
    local n, err, errName = checkRows(rows)
    if n == nil then return nil, err, errName end
    local res = { at = ms, by = actor, rows = n, bound = 0, same = 0, ignored = 0,
        missing = {}, reserved = {}, collisions = {}, conflicts = 0 }
    -- the marker first: a write cut short keeps "imported" and loses bindings (names then refused)
    -- rather than keeping bindings and losing the strict mode they were imported for
    local recs = { { v = Id.VERSION, k = "import", at = ms, by = actor } }
    local listed, bySid, fresh, pending = {}, {}, {}, {}
    for i = 1, n do
        local name, text = rows[i].u, rows[i].s
        listed[name] = true
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
            local b = bindings[name]
            if b == nil then
                recs[#recs + 1] = { v = Id.VERSION, k = "bind", name = name, sid = text, exact = true, src = "IMPORT", at = ms }
                fresh[name] = { sid = sid, text = text, exact = true, src = "IMPORT", at = ms }
                res.bound = res.bound + 1
            elseif not b.reserved and b.sid == sid then
                res.same = res.same + 1
            else
                pending[name] = { sid = sid, text = text, reason = b.reserved and "RESERVED" or "SID_MISMATCH", bound = b }
                res.conflicts = res.conflicts + 1
            end
        end
    end
    for name in pairs(knownNames()) do
        if not listed[name] and bindings[name] == nil then
            recs[#recs + 1] = { v = Id.VERSION, k = "reserve", name = name, src = "IMPORT", at = ms }
            res.reserved[#res.reserved + 1] = name
        end
    end
    EC.sortSafe(res.reserved, byName)
    local before = onlineVerdicts()
    if not writeLines(recs) then return nil, "write_failed" end
    if importedAt == nil then importedAt, importedBy = ms, actor end
    lastImportAt, lastImportBy = ms, actor
    for name, b in pairs(fresh) do bindings[name] = b end
    for _, name in ipairs(res.reserved) do bindings[name] = { reserved = true, src = "IMPORT", at = ms } end
    conflicts, lastImport = pending, res
    announce(before)
    audit("IDENTITY_IMPORT", "whitelist", nil, actor, { count = n, bound = res.bound, same = res.same,
        missing = #res.missing, reserved = #res.reserved, conflicts = res.conflicts,
        collisions = #res.collisions, ignored = res.ignored },
        { missingNames = res.missing, reservedNames = res.reserved, collisionNames = res.collisions })
    for _, name in ipairs(res.reserved) do audit("BIND_RESERVED", name, "IMPORT", actor) end
    for name, c in pairs(pending) do
        audit("BIND_CONFLICT", name, c.reason, actor, nil, { steamId = c.text, boundSteamId = c.bound.text })
    end
    for _, name in ipairs(res.collisions) do audit("BIND_CONFLICT", name, "COLLISION", actor) end
    return res
end

-- ---------- rebind (the administrator's confirmation) ----------

-- Moves the named conflicts of the last import to the whitelist's SteamID. A name the last
-- import did not list as a conflict (or one already moved) is returned as stale. Nothing else
-- can touch a conflicting binding in between: OnNewGame never changes a bound name, and a new
-- import replaces the whole list.
function Id.rebind(names, actor, reason, ms)
    if unreadable then return nil, "unreadable" end
    if type(names) ~= "table" or #names < 1 or #names > Id.LIST_MAX or EC.countKeys(names) ~= #names then
        return nil, "invalid_args"
    end
    if conflicts == nil then return nil, "import_first" end
    local recs, moved, stale, seen = {}, {}, {}, {}
    for _, name in ipairs(names) do
        if not validName(name) or seen[name] then return nil, "invalid_args" end
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
            bindings[name] = { sid = c.sid, text = c.text, exact = true, src = "REBIND", at = ms }
            conflicts[name] = nil
            audit("BIND_MOVE", name, "REBIND", actor, { reason = reason },
                { steamId = c.text, before = c.bound.reserved and "reserved" or c.bound.text })
        end
        announce(before)
    end
    return { rebound = #moved, moved = moved, stale = stale }
end

-- ---------- status ----------

function Id.status()
    local bound, reserved = 0, 0
    for _, b in pairs(bindings) do
        if b.reserved then reserved = reserved + 1 else bound = bound + 1 end
    end
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
        steam = Id.steamMode(), unreadable = unreadable,
        imported = importedAt ~= nil, importedAt = importedAt, importedBy = importedBy,
        lastImportAt = lastImportAt, lastImportBy = lastImportBy,
        bound = bound, reserved = reserved,
        conflicts = list, conflictCount = #names, conflictsTruncated = cut or nil,
    }
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
        S.reply(player, "identity.unverified", {})
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

function Id.onTick()
    local ms = EC.now()
    if ms - lastFlush < Id.FLUSH_MS then return end
    lastFlush = ms
    flush(ms)
end

-- ---------- admin.identity ----------

-- admin.identity { action = "status" | "import" | "rebind", requestId, rows?, names?, reason? }
-- Exempt from the identity gate (S.IDENTITY_EXEMPT): status needs the read role, import and
-- rebind the write role; roles come from the connection, never from the name.
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
            local out, err = Id.rebind(args.names, actorOf(player), reason, EC.now())
            res = out and { ok = true, rebound = out.rebound, moved = out.moved, stale = out.stale }
                or { ok = false, error = err }
        end
    else
        res = { ok = true }
    end
    res.action, res.requestId = action, requestId
    res.perms = { read = A.canRead(player), write = A.isAdmin(player) }
    res.status = Id.status()
    res.last = importView(lastImport)
    S.reply(player, "admin.identity", res)
end

-- ---------- lifecycle ----------

-- On every start: the bindings are replayed from the file; what only lived in memory (the
-- last import's conflicts, refusal counters) starts empty.
function Id.init()
    conflicts, lastImport, refused, noticeAt, lastFlush = nil, nil, {}, {}, 0
    Id.load()
end

S.Identity = Id
S.onInit(Id.init)
Events.OnNewGame.Add(Id.onNewGame)
Events.OnTickEvenPaused.Add(Id.onTick)

return Id
