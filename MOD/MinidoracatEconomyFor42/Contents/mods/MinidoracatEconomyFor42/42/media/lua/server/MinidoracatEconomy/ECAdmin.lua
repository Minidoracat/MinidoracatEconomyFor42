-- MinidoracatEconomyFor42 — admin panel v1 (server authority, spec section 19).
--
--   Gate: role *name* lists from sandbox (AdminRoles = write, ReadOnlyRoles = read), re-checked
--   on the server for every command (player:getRole():getName(), IsoPlayer.java:7562 /
--   Role.java:41). Not capabilities: moderators also hold AddItem (stage A13), and roles are
--   editable by the host, so capability sets are not a stable permission level. One exception,
--   and only one: the options that define those very lists and the adjustment caps (manageOnly
--   in EC.OPTIONS) are gated on the native role-editing capability instead (EC.canManageSettings),
--   because the people a limit applies to must not be the people who raise it. That capability
--   also keeps the panel readable for whoever owns the server's roles, so an AdminRoles list
--   edited down to nobody can still be edited back.
--
--   admin.lookup  {username}                      read   account summary + receipt ring + rewards
--   admin.adjust  {username,currency,delta,reason, write  SYSTEM_ADJUST <-> player posting with the
--                  expectedRev,requestId,reversalOfTxId}   spec 19.3 limits (per tx / per admin day /
--                                                          server day / rate), audit + admin.adjust event
--   admin.freeze  {username,frozen,reason}        write  account-level freeze (ledger refuses new tx)
--   admin.config  {currency,field,value,reason}   write  name | enabled | exchange -> ECConfig setters
--   admin.audit   {limit,actor,fromMs,toMs,       read   filtered ModData audit ring, newest first
--                  requestId}
--   admin.system  {}                              read   seq/epoch, sizes, heartbeat, paths, supply,
--                                                        7/30-day issuance, top holders
--   admin.transactions {query,matchMode,itemTypes,  read   server-wide money view: one committed
--                       account,item,group,               transaction per row from the daily events
--                       accountClass,currency,            files (tx.committed only, <= 62 days per
--                       fromMs,toMs,requestId}            query - a span, not an age limit)
--   admin.transaction  {txId,fromMs,toMs,          read   the postings of one transaction (bucket +
--                       requestId}                        balance chain, reason text)
--   admin.auditDetail  {key,month,requestId}       read   the full audit record behind one row of
--                                                        the ring or the file list
--   admin.seasons {action,requestId,             read   the season history + the running season;
--                  expectedSeason,reason}        +cap   action='start' rotates (native RolesWrite)
--
-- Every reply is `<command>` with { ok, error } (+ payload); `forbidden` when the gate fails.
--
-- Trust boundary: `args` is a client packet. Every field is validated here (type, finiteness,
-- integer, length, character class) before it reaches the ledger or ModData; `tonumber` is never
-- used to coerce a caller value into a limit check. Three properties this file owns:
--
--   * read commands create nothing. A lookup for a username that was only typed into the search
--     box must not leave a wallet, a claim record or a daily-total row behind, and a moderator
--     must never mutate state (that is why the reward view here is a projection of md.claims and
--     not R.state, which creates/normalises the claim record).
--   * a resend of an already committed requestId returns the original result and consumes no
--     cap, no rate slot and writes no audit line - even when the caps are now full. The ledger
--     idempotency entry carries the money fingerprint of the request (target, currency, delta,
--     reversal link, expectedRev - never the reason text, which must not enter Global ModData),
--     so one requestId reused for a different amount or account is a conflict instead of a
--     second posting or a posting against the other account.
--   * the ledger key is length-prefixed with the actor (`admin:<len>:<name>:<requestId>`) so no
--     two (admin, requestId) pairs can collide even though usernames may contain ':'.
--
-- Paths for the panel's copy buttons come from getMyDocumentFolder() (LuaManager.java:8835-8837
-- -> Core.java:1670 ZomboidFileSystem.getCacheDir, valid on the dedicated server too). When the
-- engine does not hand one out there are no paths: a relative "Lua/..." string would be a
-- fabricated absolute path in the panel's copy button.

if not MinidoracatEconomy or not MinidoracatEconomy.Rewards then
    require "MinidoracatEconomy/ECRewards"
end
if not MinidoracatEconomy or not MinidoracatEconomy.Seasons then
    require "MinidoracatEconomy/ECSeasons"
end
if not MinidoracatEconomy or not MinidoracatEconomy.Wallet then
    require "MinidoracatEconomy/ECWallet"
end
if not MinidoracatEconomy or not MinidoracatEconomy.Icons then
    require "MinidoracatEconomy/ECIcons"
end
if not MinidoracatEconomy or not MinidoracatEconomy.Integration then
    require "MinidoracatEconomy/ECIntegration"
end
if not MinidoracatEconomy or not MinidoracatEconomy.Market then
    require "MinidoracatEconomy/ECMarket"
end
if not MinidoracatEconomy or not MinidoracatEconomy.Radio then
    require "MinidoracatEconomy/ECRadio"
end
if not MinidoracatEconomy or not MinidoracatEconomy.Exchange then
    require "MinidoracatEconomy/ECExchange"
end
if not MinidoracatEconomy or not MinidoracatEconomy.Stats then
    require "MinidoracatEconomy/ECStats"
end
local EC = MinidoracatEconomy
local S = EC and EC.Server
local L = EC and EC.Ledger
local X = EC and EC.Export
local Cfg = EC and EC.Config
local R = EC and EC.Rewards
local W = EC and EC.Wallet
local I = EC and EC.Icons
local G = EC and EC.Integration
local T = EC and EC.Terminal
local M = EC and EC.Mailbox
local Shop = EC and EC.Shop
local Codec = EC and EC.Codec
local Mk = EC and EC.Market
local St = EC and EC.Stats
local Se = EC and EC.Seasons
if not S or not S.AUTHORITY or not L or not X or not Cfg or not R or not W or not I or not G or not T or not M or not Shop or not Codec or not Mk or not St or not Se then
    return
end

EC.Admin = EC.Admin or {}
local A = EC.Admin

A.ADJUST_ACCOUNT = "SYSTEM_ADJUST"
A.RATE_PER_MINUTE = 10
A.REASON_MAX = 1000                -- one JSON line in the event / audit files; "unlimited" for a text box
A.REQUEST_ID_MAX = 64
A.DAILY_VERSION = 2               -- md.adminDaily shape: per currency add/sub buckets
A.TX_QUERY_CHARS = 128            -- transactions search box (bytes, as the client sends them)
A.TX_ID_CHARS = 96
A.TX_RANGE_MAX_MS = 62 * 86400000 -- at most 62 daily events files per query
A.TX_POSTINGS_MAX = 200           -- packet bound for one transaction's postings (real ones: <= 8)
A.ITEM_TYPE_CHARS = 128           -- one fullType (the client resolves display names to these)
A.ITEM_TYPES_MAX = 256            -- resolved item set of one multilingual keyword search

local md = nil
local recentAdjusts = {}          -- admin -> { ms, ... } (rate limit, in-memory)

-- ---------- text length (Kahlua vs standard Lua) ----------

-- Kahlua strings are Java Strings: one element per UTF-16 code unit and string.char takes values
-- above 255 (StringLib.java:760-768), so '#s' already counts characters. Standard Lua (the smoke
-- harness) holds UTF-8 bytes, where a CJK character is three bytes. Counting the non-continuation
-- bytes makes both runtimes agree that one CJK character is one character, so a Chinese reason of
-- 10 characters counts as 10 on the server and in the harness alike (REASON_MAX is in characters).
local WIDE_STRINGS = pcall(string.char, 19981)
local IDEO_SPACE = WIDE_STRINGS and string.char(12288) or "\227\128\128"   -- U+3000

local function charCount(s)
    if WIDE_STRINGS then return #s end
    local n = 0
    for i = 1, #s do
        local b = string.byte(s, i)
        if b < 128 or b >= 192 then n = n + 1 end
    end
    return n
end

-- ---------- roles ----------

function A.roleName(player)
    local ok, role = pcall(function() return player:getRole():getName() end)
    if ok and type(role) == "string" then return role end
    return ""
end

function A.isAdmin(player)
    return EC.roleSet(EC.sandbox("AdminRoles", "admin"))[A.roleName(player)] == true
end

-- Whoever may edit the server's roles natively keeps the panel readable even when no economy
-- role list names them: that is the way back from an AdminRoles list that names nobody. It
-- grants nothing else - every ordinary write command still needs AdminRoles.
function A.canRead(player)
    return A.isAdmin(player) or EC.canManageSettings(player)
        or EC.roleSet(EC.sandbox("ReadOnlyRoles", "moderator"))[A.roleName(player)] == true
end

-- Paying yourself needs a second, explicit grant on top of the write role: the caller's role
-- must be named in AdminSelfAdjustRoles, which is empty by default. An absent or empty list
-- means nobody - never everybody.
function A.canAdjustSelf(player)
    return A.isAdmin(player)
        and EC.roleSet(EC.sandbox("AdminSelfAdjustRoles", ""))[A.roleName(player)] == true
end

local function gate(player, command, write, requestId, context)
    local allowed = write and A.isAdmin(player) or (not write and A.canRead(player))
    if not allowed then
        EC.log("admin command " .. command .. " refused for " .. tostring(player:getUsername()) .. " role=" .. A.roleName(player))
        S.reply(player, command, { ok = false, error = "forbidden", requestId = requestId, context = context })
    end
    return allowed
end

-- ---------- helpers ----------

local onlinePlayer = S.onlinePlayer

local function accountExists(username)
    return md.wallets[username] ~= nil or onlinePlayer(username) ~= nil
end

local function validUsername(s)
    return type(s) == "string" and s ~= "" and #s <= 64
        and not string.find(s, "%c") and not L.isSystemAccount(s)
end

local function isFiniteInt(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge and v == math.floor(v)
end
local DAY_MS = 86400000

local function dayStart(ms) return math.floor(ms / DAY_MS) * DAY_MS end

local function textOf(v) return type(v) == "string" and v or "" end

-- A posting amount: a finite non-zero integer inside the ledger's own bound. A value that is not
-- one is not money, and must never be read as 0 (that would turn a corrupt line into a balanced
-- row the panel presents as fact).
local function isAmount(v)
    return isFiniteInt(v) and v ~= 0 and math.abs(v) <= L.MAX_ABS_AMOUNT
end

-- A balance-chain number: 0 is legitimate here, absent stays absent (old lines carry no chain).
local function chainOf(v)
    if isFiniteInt(v) then return v end
    return nil
end

-- Default window: the first day of the previous UTC month 00:00 through tomorrow 00:00. At most
-- 62 days (both months with 31 days, today the 31st), so it always fits TX_RANGE_MAX_MS.
local function defaultRange(ms)
    local today = dayStart(ms)
    local _, _, d = EC.utcDate(ms)
    local lastOfPrev = today - d * DAY_MS
    local _, _, pd = EC.utcDate(lastOfPrev)
    return lastOfPrev - (pd - 1) * DAY_MS, today + DAY_MS
end

-- fromMs inclusive / toMs exclusive, both optional. A single bound anchors the other so the
-- window is always a bounded number of daily files. Returns from, to or nil, nil, error code.
local function txRange(args)
    local from, to = args.fromMs, args.toMs
    if from ~= nil and (not isFiniteInt(from) or from < 0 or from > 9007199254740991) then return nil, nil, "invalid_args" end
    if to ~= nil and (not isFiniteInt(to) or to < 0 or to > 9007199254740991) then return nil, nil, "invalid_args" end
    if from == nil and to == nil then
        from, to = defaultRange(EC.now())
    elseif to == nil then
        -- 62 days is the span of one query, not the age of the data an admin may read: a window
        -- that starts in an old month ends 62 days later instead of being refused as too wide.
        local today = dayStart(EC.now()) + DAY_MS
        to = from + A.TX_RANGE_MAX_MS
        if to > today then to = today end
    elseif from == nil then
        from = to - A.TX_RANGE_MAX_MS
        if from < 0 then from = 0 end
    end
    if from >= to or to - from > A.TX_RANGE_MAX_MS then return nil, nil, "invalid_range" end
    return from, to, nil
end


-- Length-prefixed actor: '<len>:<name>' is injective, so admin "a" + requestId "b:c" and admin
-- "a:b" + requestId "c" cannot produce the same ledger key.
local function requestKey(admin, requestId)
    if type(requestId) ~= "string" or requestId == "" or #requestId > A.REQUEST_ID_MAX
        or string.find(requestId, "%c") then
        return nil
    end
    return "admin:" .. tostring(#admin) .. ":" .. admin .. ":" .. requestId
end

local function readRequestId(args)
    local id = args.requestId
    if type(id) == "string" and id ~= "" and #id <= A.TX_ID_CHARS and not string.find(id, "%c") then return id end
    return nil
end

-- Shared date and correlation validation for the money and audit readers.
local function txCommon(args, extra)
    extra.requestId = readRequestId(args)
    if args.requestId ~= nil and extra.requestId == nil then return nil, nil, "invalid_args" end
    local from, to, err = txRange(args)
    if err then return nil, nil, err end
    extra.fromMs, extra.toMs = from, to
    return from, to, nil
end

-- Candidate actors come from every row of the queried window, not the filtered tail or live roles.
local function auditQuery(player, command, args)
    local requestId = readRequestId(args)
    if not gate(player, command, false, requestId) then return nil end
    local extra = { requestId = requestId, entries = {}, total = 0, truncated = false,
        actors = {}, actorsTruncated = false, perms = { read = true, write = A.isAdmin(player) } }
    local _, _, err = txCommon(args, extra)
    if args.actor ~= nil and (type(args.actor) ~= "string" or args.actor == "" or #args.actor > 64
        or string.find(args.actor, "%c")) then err = "invalid_args" end
    if err then
        extra.ok, extra.error = false, err
        S.reply(player, command, extra)
        return nil
    end
    extra.actor = args.actor
    local seen = {}
    local ranged = args.fromMs ~= nil or args.toMs ~= nil
    local function matches(rec)
        if ranged and (not isFiniteInt(rec.ts) or rec.ts < extra.fromMs or rec.ts >= extra.toMs) then return false end
        local name = rec.admin
        if type(name) == "string" and name ~= "" and #name <= 64 and not string.find(name, "%c") and not seen[name] then
            if #extra.actors < A.PLAYERS_SCAN_MAX then
                seen[name] = true
                local i = #extra.actors + 1
                while i > 1 and name < extra.actors[i - 1] do
                    extra.actors[i] = extra.actors[i - 1]
                    i = i - 1
                end
                extra.actors[i] = name
            else
                extra.actorsTruncated = true
            end
        end
        return extra.actor == nil or name == extra.actor
    end
    return extra, matches
end


-- Returns nil + the trimmed text on success, otherwise an error code. Length is counted in
-- characters, so a 10-character Chinese reason is a valid reason; surrounding whitespace is not
-- part of it, and a reason made only of spaces (ASCII or ideographic) is not a reason at all.
local function reasonError(reason)
    if type(reason) ~= "string" then return "reason_too_short" end
    local text = (string.gsub(reason, "^[ \t\r\n]*(.-)[ \t\r\n]*$", "%1"))
    if string.find(text, "%c") then return "reason_invalid" end
    local bare = string.gsub(text, IDEO_SPACE, "")
    bare = string.gsub(bare, "[ \t]", "")
    if bare == "" then return "reason_blank" end
    local chars = charCount(text)
    if chars < 1 then return "reason_too_short" end
    if chars > A.REASON_MAX then return "reason_too_long" end
    return nil, text
end

-- ---------- per-day adjustment totals (ModData, per currency) ----------
--
-- md.adminDaily[day] = { v, server = { [currency] = {add,sub} }, admins = { [admin] = { [currency] = {add,sub} } } }
-- Only today + yesterday are kept. Add and sub never offset each other (spec 19.3.2).

local ZERO = { add = 0, sub = 0 }        -- read-only placeholder, never mutated

local function bucketOf(day)             -- read path: nil when this day has no totals yet
    local t = md.adminDaily[day]
    if type(t) ~= "table" or t.v ~= A.DAILY_VERSION then return nil end
    return t
end

local function ensureBucket(day, ms)     -- write path only
    local t = bucketOf(day)
    if t then return t end
    t = { v = A.DAILY_VERSION, server = {}, admins = {} }
    md.adminDaily[day] = t
    local yesterday = R.dayKey(ms - 86400000)
    local stale = {}
    for k in pairs(md.adminDaily) do
        if k < yesterday then stale[#stale + 1] = k end
    end
    for _, k in ipairs(stale) do md.adminDaily[k] = nil end
    return t
end

local function totalsView(day, admin, currency)
    local t = bucketOf(day)
    if not t then return ZERO, ZERO end
    local mine = t.admins[admin]
    return (mine and mine[currency]) or ZERO, t.server[currency] or ZERO
end

local function totalsFor(day, admin, currency, ms)
    local t = ensureBucket(day, ms)
    local mine = t.admins[admin]
    if not mine then
        mine = {}
        t.admins[admin] = mine
    end
    local a = mine[currency]
    if not a then
        a = { add = 0, sub = 0 }
        mine[currency] = a
    end
    local s = t.server[currency]
    if not s then
        s = { add = 0, sub = 0 }
        t.server[currency] = s
    end
    return a, s
end

-- What the panel needs to draw today's remaining room: aggregate (wire compatible) plus the
-- per-currency breakdown for this admin and for the whole server.
local function dailyView(day, admin)
    local t = bucketOf(day)
    local out = {
        add = 0, sub = 0, currencies = {},
        cap = EC.sandbox("AdminAdjustDailyPerAdmin", 10000),
        serverDaily = { cap = EC.sandbox("AdminAdjustServerDaily", 50000), currencies = {} },
    }
    local mine = t and t.admins[admin] or nil
    for _, id in ipairs(EC.CURRENCY_ORDER) do
        local a = (mine and mine[id]) or ZERO
        out.currencies[id] = { add = a.add, sub = a.sub }
        out.add = out.add + a.add
        out.sub = out.sub + a.sub
        local s = (t and t.server[id]) or ZERO
        out.serverDaily.currencies[id] = { add = s.add, sub = s.sub }
    end
    return out
end

local function rateLimited(admin, ms)
    local list = recentAdjusts[admin] or {}
    local kept = {}
    for _, t in ipairs(list) do
        if ms - t < 60000 then kept[#kept + 1] = t end
    end
    if #kept >= A.RATE_PER_MINUTE then
        recentAdjusts[admin] = kept
        return true
    end
    kept[#kept + 1] = ms
    recentAdjusts[admin] = kept
    return false
end

-- ---------- lookup ----------

-- Read-only projection of md.claims. R.state would create the claim record, reset the playtime
-- on a day change and clear the milestone mask on a season change: a lookup must do none of that.
-- Eligibility itself - may this player claim right now, how much online time is still missing -
-- belongs to the rewards module and is not recomputed here: a second opinion would be a second
-- answer, and the one the player is given is the true one.
local function rewardsView(username, ms)
    local c = md.claims[username]
    local day = R.dayKey(ms)
    local season = Se.currentId()
    local today = c ~= nil and c.day == day
    -- What today already paid this account, in the order the rewards module trusts it:
    --   * the record is on today's bucket        -> its own counter
    --   * the record moved on (or never arrived) -> the durable payment watermark c.paid[today],
    --     which outlives the ledger's bounded idempotency window; absent means nothing was paid
    --   * a pre-limit record                     -> checkinDay, or the ledger entry that proves
    --     the single old claim when that mark was lost
    -- Every branch only reads: L.priorResult reads the idempotency window, R.isBackdated reads
    -- the watermark, and the record is left in whatever shape the player's next visit migrates.
    local claimedCount = 0
    if c ~= nil then
        if today and isFiniteInt(c.claimedCount) and c.claimedCount > 0 then
            claimedCount = c.claimedCount
        elseif type(c.paid) == "table" and isFiniteInt(c.paid[day]) and c.paid[day] > 0 then
            claimedCount = c.paid[day]
        elseif c.claimedCount == nil
            and (c.checkinDay == day or L.priorResult(R.legacyRequestId(username, day)) ~= nil) then
            claimedCount = 1
        end
    end
    -- The one refusal this projection may state, because the rewards module owns the test:
    -- the reward day was moved back past the watermark's window, so this server pays nothing
    -- until the day catches up again. R.isBackdated is asked as it stands - guarding the call
    -- here would answer "not blocked" for a record whose watermark cannot be proven, which is
    -- the opposite of what the rewards module decides.
    local blockedReason = nil
    if c ~= nil and R.isBackdated(c, day) then
        blockedReason = "day_reverted"
    end
    local prog, survivalErr
    local okProgress, reported, reportErr = pcall(Se.progress, username)
    if okProgress and type(reported) == "table" then
        prog = reported
    else
        survivalErr = okProgress and (reportErr or "data_unreadable") or "data_unreadable"
        EC.log("admin survival read failed for " .. tostring(username) .. ": "
            .. tostring(okProgress and survivalErr or reported))
    end
    local dailyLimit = EC.sandbox("CheckinDailyLimit", 1)
    return {
        day = day,
        claimedCount = claimedCount,
        dailyLimit = dailyLimit,
        remainingClaims = math.max(0, dailyLimit - claimedCount),
        playedMs = today and c.playedMs or 0,
        requiredOnlineMs = EC.sandbox("CheckinMinPlaytimeMinutes", 15) * 60000,
        intervalMs = EC.sandbox("CheckinIntervalMinutes", 60) * 60000,
        milestones = (c and c.season == season) and c.milestones or 0,
        milestoneList = R.milestones(),
        season = season,
        -- This account's season survival, as the season module reports it (a pure read: a lookup
        -- for a name that never played must leave no record behind). Absent means the server
        -- could not confirm it, which is not the same as zero. `hoursSurvived` on the reply
        -- beside this is the character's lifetime total and is a different number entirely.
        seasonNumber = prog and prog.seasonNumber or nil,
        survivalHours = prog and prog.currentHours or nil,
        bestSurvivalHours = prog and prog.bestHours or nil,
        survivalKnown = prog ~= nil and prog.known == true,
        survivalIncomplete = prog ~= nil and prog.incomplete == true,
        survivalError = survivalErr,
        nextResetMs = R.nextResetMs(ms),
        blockedReason = blockedReason,
    }
end

function A.lookup(admin, username, write, selfAdjust)
    local ms = EC.now()
    local player = onlinePlayer(username)
    local state = W.state(username)
    local info = md.frozen[username]
    return {
        ok = true, username = username, found = accountExists(username), online = player ~= nil,
        frozen = info ~= nil,
        -- copy: the reply must not carry a live ModData table
        frozenInfo = info and { by = info.by, ts = info.ts, reason = info.reason } or nil,
        balances = state.balances, receipts = state.receipts, currencies = state.currencies,
        rewards = rewardsView(username, ms),
        hoursSurvived = player and player:getHoursSurvived() or nil,
        listingsCount = Mk.ownerCount(username),
        auctionsCount = S.Auction.ownerCount(username),
        maxListings = EC.sandbox("MarketMaxListings", 5),
        maxAuctions = EC.sandbox("AuctionMaxPerPlayer", 3),
        recoveryHeld = M.recoveryStatus(username).held,
        adminToday = dailyView(R.dayKey(ms), admin),
        maxPerTx = EC.sandbox("AdminAdjustMaxPerTx", 5000),
        -- Spec 19.2 wants season-to-date earned/spent from a `stats` table. That table does not
        -- exist in this build, and the 5-entry receipt ring is not a season total: say so instead
        -- of shipping a number the panel would present as a season figure.
        stats = nil, statsAvailable = false,
        perms = { read = true, write = write == true, selfAdjust = selfAdjust == true },
    }
end

-- ---------- adjust ----------

function A.adjust(player, args)
    local admin = player:getUsername()
    if type(args) ~= "table" then return { ok = false, error = "invalid_args" } end
    local username, currency, delta = args.username, args.currency, args.delta
    if not validUsername(username) or type(currency) ~= "string"
        or not isFiniteInt(delta) or delta == 0 then
        return { ok = false, error = "invalid_args" }
    end
    if args.reversalOfTxId ~= nil and (type(args.reversalOfTxId) ~= "string" or #args.reversalOfTxId > 64) then
        return { ok = false, error = "invalid_args" }
    end
    local key = requestKey(admin, args.requestId)
    if not key then return { ok = false, error = "invalid_request_id" } end
    -- Mandatory and never coerced: a missing or non-numeric expectedRev must not silently skip
    -- the ledger's revision check (that check is what stops an adjustment from being computed
    -- against a balance the player has since changed).
    if not isFiniteInt(args.expectedRev) or args.expectedRev < 0 then
        return { ok = false, error = "expected_rev_required" }
    end

    -- Resend of a committed request: answer from the ledger's idempotency entry before any of
    -- this admin's quota is touched. A full cap must not turn a retry of a paid adjustment into
    -- a failure the panel would show as "not applied".
    --
    -- The fingerprint is the money semantics of the request only - target, currency, delta,
    -- reversal link and the revision it was posted against. It deliberately does not contain the
    -- reason: ModData is readable by every logged-in client, so the reason text lives in the
    -- audit/event files with only a 40-character prefix in the ring (spec 19.3.7), and a
    -- fingerprint would smuggle the full text back in. A retry therefore resends the request
    -- unchanged; reusing one requestId for a different amount, account, currency, reversal link
    -- or wallet revision is a conflict, not a second posting and never a posting against the
    -- other account.
    local prior = L.priorResult(key)
    if prior then
        local m = prior.meta
        if not m or m.target ~= username or m.currency ~= currency or m.delta ~= delta
            or m.reversalOfTxId ~= args.reversalOfTxId or m.expectedRev ~= args.expectedRev then
            return { ok = false, error = "request_conflict", txId = prior.txId, requestId = args.requestId }
        end
        return {
            ok = prior.ok == true, error = prior.error, txId = prior.txId, requestId = args.requestId,
            duplicate = true,
            balance = L.getBalance(username, currency).available,
        }
    end

    local rerr, reason = reasonError(args.reason)
    if rerr then return { ok = false, error = rerr } end
    -- Adjusting your own account is refused unless this admin's role carries the explicit
    -- self-adjustment grant. The test sits after the idempotency reply above on purpose: a
    -- request that was already paid keeps answering with its original result even after the
    -- grant is taken away. Everything else about a self-adjustment is unchanged - same caps,
    -- same reason, same expectedRev, same rate limit, same audit and event line.
    if username == admin and not A.canAdjustSelf(player) then
        return { ok = false, error = "self_target" }
    end
    if not accountExists(username) then return { ok = false, error = "unknown_account" } end
    if not L.currency(currency) then return { ok = false, error = "unknown_currency" } end
    local absDelta = math.abs(delta)
    if absDelta > EC.sandbox("AdminAdjustMaxPerTx", 5000) then return { ok = false, error = "over_max_per_tx" } end

    local ms = EC.now()
    local day = R.dayKey(ms)
    local side = delta > 0 and "add" or "sub"
    -- Read-only totals: a refused adjustment leaves no daily-total row behind.
    local mineView, serverView = totalsView(day, admin, currency)
    if mineView[side] + absDelta > EC.sandbox("AdminAdjustDailyPerAdmin", 10000) then
        return { ok = false, error = "over_admin_daily" }
    end
    if serverView[side] + absDelta > EC.sandbox("AdminAdjustServerDaily", 50000) then
        return { ok = false, error = "over_server_daily" }
    end
    if rateLimited(admin, ms) then return { ok = false, error = "rate_limited" } end

    local res = L.credit(username, currency, delta, A.ADJUST_ACCOUNT, {
        kind = "admin_adjust", reasonCode = "admin_adjust", reasonText = reason, actor = admin,
        requestId = key, expectedRev = args.expectedRev, allowFrozen = true,
        -- money semantics only: no reason text in Global ModData (spec 19.3.7)
        idemMeta = {
            target = username, currency = currency, delta = delta,
            reversalOfTxId = args.reversalOfTxId, expectedRev = args.expectedRev,
        },
        payload = { admin = admin, reversalOfTxId = args.reversalOfTxId },
    })
    if not res.ok then return { ok = false, error = res.error } end
    if not res.duplicate then
        local mine, server = totalsFor(day, admin, currency, ms)
        mine[side] = mine[side] + absDelta
        server[side] = server[side] + absDelta
        X.emit("admin.adjust", {
            admin = admin, target = username, currency = currency, delta = delta, reason = reason,
            txId = res.txId, requestId = args.requestId, expectedRev = args.expectedRev,
            reversalOfTxId = args.reversalOfTxId,
        })
        X.audit({
            action = "adjust", admin = admin, target = username, currency = currency, delta = delta,
            reason = reason, txId = res.txId, requestId = args.requestId, reversalOfTxId = args.reversalOfTxId,
        })
    end
    return {
        ok = true, txId = res.txId, duplicate = res.duplicate, requestId = args.requestId,
        balance = L.getBalance(username, currency).available,
    }
end

-- ---------- freeze ----------

function A.freeze(player, args)
    local admin = player:getUsername()
    if type(args) ~= "table" then return { ok = false, error = "invalid_args" } end
    local username = args.username
    -- frozen must be a real boolean: a garbled field must not silently read as "unfreeze".
    if not validUsername(username) or type(args.frozen) ~= "boolean" then
        return { ok = false, error = "invalid_args" }
    end
    if username == admin then return { ok = false, error = "self_target" } end
    if not accountExists(username) then return { ok = false, error = "unknown_account" } end
    local rerr, reason = reasonError(args.reason)
    if rerr then return { ok = false, error = rerr } end
    local frozen = args.frozen
    if frozen then
        md.frozen[username] = { by = admin, ts = EC.now(), reason = string.sub(reason, 1, X.AUDIT_REASON_CHARS) }
    else
        md.frozen[username] = nil
    end
    -- A freeze mark is part of the account census and moves no money, so no ledger commit
    -- invalidates it for us.
    St.invalidate()
    X.emit("admin.freeze", { admin = admin, target = username, frozen = frozen, reason = reason })
    X.audit({ action = frozen and "freeze" or "unfreeze", admin = admin, target = username, reason = reason })
    W.pushState(username)
    -- A freeze decides whether the rewards page may claim, and that page reads the server's
    -- verdict rather than working it out itself. Without this the button stays as it was for
    -- up to a reward tick - the client would either offer a claim the ledger will refuse, or
    -- withhold one it would now accept. Only this account is told, and only when someone is
    -- there to hear it: a freeze is nobody else's business, and an offline player reads the
    -- fresh state on login anyway. R.pushState is this build's publisher for that page (the
    -- same one its own handler uses), so it is called plainly: a failure here is a broken
    -- server, not a case to absorb, and it belongs to the command dispatcher like any other.
    local target = onlinePlayer(username)
    if target ~= nil then
        R.pushState(target, EC.now())
    end
    return { ok = true, frozen = frozen }
end

-- ---------- config ----------

function A.config(player, args)
    local admin = player:getUsername()
    if type(args) ~= "table" or type(args.currency) ~= "string" or type(args.field) ~= "string" then
        return { ok = false, error = "invalid_args" }
    end
    local rerr, reason = reasonError(args.reason)
    if rerr then return { ok = false, error = rerr } end
    local ok, err
    if args.field == "name" then
        ok, err = Cfg.setNameOverride(args.currency, args.value, admin, reason)
    elseif args.field == "enabled" then
        if type(args.value) ~= "boolean" then return { ok = false, error = "invalid_args" } end
        ok, err = Cfg.setEnabled(args.currency, args.value, admin, reason)
    elseif args.field == "exchange" then
        -- a malformed value is refused, never coerced to {}: an empty table is a silent no-op
        -- that the panel would report as an applied change
        if type(args.value) ~= "table" then return { ok = false, error = "invalid_args" } end
        ok, err = Cfg.setExchange(args.currency, args.value, admin, reason)
    elseif args.field == "balanceMax" then
        -- nil clears the override (back to the sandbox default); the setter validates the number
        if args.value ~= nil and type(args.value) ~= "number" then return { ok = false, error = "invalid_args" } end
        ok, err = Cfg.setBalanceMax(args.currency, args.value, admin, reason)
    else
        return { ok = false, error = "invalid_args" }
    end
    if not ok then return { ok = false, error = err or "invalid_args" } end
    return { ok = true, currencies = Cfg.snapshot() }
end

-- ---------- system / dashboard ----------

local function cacheDir()
    local ok, base = pcall(getMyDocumentFolder)
    if ok and type(base) == "string" and base ~= "" then return base end
    return nil
end

-- nil when the engine gives no cache dir: the panel shows "unavailable" instead of copying a
-- relative path dressed up as an absolute one.
local function dataPaths(ms)
    local base = cacheDir()
    if not base then return nil end
    local root = base .. "/Lua/" .. X.ROOT
    return {
        root = root,
        events = root .. "/events-" .. EC.dayKey(ms) .. ".json",
        receipts = root .. "/receipts",
        audit = root .. "/audit/" .. EC.monthKey(ms) .. ".json",
        heartbeat = root .. "/heartbeat.json",
        icons = root .. "/icons",
        -- append-only, one month file per account, written by ECRecoveryJournal. Lua deletes
        -- no file: whoever rotates receipts and events has to know this directory exists too.
        recovery = root .. "/recovery",
    }
end

-- Admin-owned ModData that the ledger estimate does not see: the audit ring, freeze marks, the
-- per-day adjustment totals and the money fingerprints stored in the idempotency entries
-- (byte constants in the same spirit as A4's measurements, spec 20).
function A.sizeEstimate()
    local bytes = (md.audit and md.audit.count or 0) * 200
    for _ in pairs(md.frozen) do bytes = bytes + 96 end
    for _, t in pairs(md.adminDaily) do
        if type(t) == "table" then
            for _, byCurrency in pairs(t.admins or {}) do
                for _ in pairs(byCurrency) do bytes = bytes + 48 end
            end
            for _ in pairs(t.server or {}) do bytes = bytes + 48 end
        end
    end
    local idem = md.idempotency
    if idem and idem.map then
        for _, v in pairs(idem.map) do
            -- table header + target/currency/delta/reversalOfTxId/expectedRev
            if type(v) == "table" and v.meta then bytes = bytes + 96 end
        end
    end
    return bytes
end

function A.system(write, manage)
    local ms = EC.now()
    local accounts, frozen = 0, 0
    for account in pairs(md.wallets) do
        if not L.isSystemAccount(account) then accounts = accounts + 1 end
    end
    for _ in pairs(md.frozen) do frozen = frozen + 1 end
    local ledgerBytes, adminBytes = L.sizeEstimate(), A.sizeEstimate()
    local p = dataPaths(ms)
    -- `at` is the instant the census behind the supply was taken, never the instant this reply
    -- was built: the numbers are as old as the census, and the page says so.
    local supplyView, supplyAt = St.supply(ms)
    return {
        ok = true,
        epoch = md.meta.epoch, seq = md.meta.seq, loadedSeq = md.meta.loadedSeq, startedAt = md.meta.startedAt,
        durable = S.durableStatus(),
        realmId = md.meta.realmId, version = EC.VERSION, schemaVersion = md.schemaVersion,
        sizeEstimate = ledgerBytes + adminBytes,
        sizeParts = { ledger = ledgerBytes, admin = adminBytes },
        accounts = accounts, frozen = frozen,
        -- This is the MOD's export heartbeat, not the external companion or a world-save time.
        heartbeatAt = X.lastHeartbeatMs(), heartbeatSource = "export",
        queuedLines = X.queuedLines(),
        auditCount = md.audit and md.audit.count or 0, auditMax = X.AUDIT_RING,
        paths = p, pathsResolved = p ~= nil,
        supply = supplyView,
        issued = { today = St.issued(1, ms), week = St.issued(7, ms), month = St.issued(30, ms) },
        at = supplyAt,
        perms = { read = true, write = write == true, manage = manage == true },
        sandbox = Cfg.options(),
        terminals = T.count(),
        catalog = Shop.fileStatus(),
        buyback = Shop.buybackStatus(ms),
        exchange = S.Exchange and S.Exchange.stats() or nil,
        mailboxUnclaimed = md.mailbox and md.mailbox.unclaimed or 0,
        market = Mk.stats(),
        auctions = S.Auction and S.Auction.stats() or nil,
        whitelist = Codec.status(),
    }
end

-- ---------- commands ----------

local function username(args)
    if type(args) == "table" and type(args.username) == "string" then return args.username end
    return nil
end

S.handlers["admin.lookup"] = function(player, args)
    if not gate(player, "admin.lookup", false) then return end
    if type(args) ~= "table" or not validUsername(args.username) then
        S.reply(player, "admin.lookup", { ok = false, error = "invalid_args" })
        return
    end
    S.reply(player, "admin.lookup", A.lookup(player:getUsername(), args.username,
        A.isAdmin(player), A.canAdjustSelf(player)))
end

S.handlers["admin.adjust"] = function(player, args)
    if not gate(player, "admin.adjust", true) then return end
    local res = A.adjust(player, args)
    if type(args) == "table" then res.requestId = args.requestId end
    res.username = username(args)
    S.reply(player, "admin.adjust", res)
end

S.handlers["admin.freeze"] = function(player, args)
    if not gate(player, "admin.freeze", true) then return end
    local res = A.freeze(player, args)
    if type(args) == "table" then res.requestId = args.requestId end
    res.username = username(args)
    S.reply(player, "admin.freeze", res)
end

-- Every currency-shaped reply carries the supply and the instant it was taken: the dashboard,
-- the currency page and an edit's own answer must not disagree about how much money exists.
-- It is deliberately not part of Cfg.snapshot, which is broadcast to every player online.
local function withSupply(res)
    res.supply, res.at = St.supply()
    return res
end

S.handlers["admin.config"] = function(player, args)
    if not gate(player, "admin.config", true) then return end
    local res = A.config(player, args)
    if type(args) == "table" then res.requestId = args.requestId end
    S.reply(player, "admin.config", withSupply(res))
end

-- admin.currency {requestId?} (read gate): the currency page's own read - the registry as this
-- server runs it (names, icons, enabled, balance caps, buyback caps, exchange), the option
-- snapshot those numbers come from, and the supply. Read-only; the writes are admin.config and
-- admin.option.
S.handlers["admin.currency"] = function(player, args)
    args = type(args) == "table" and args or {}
    local requestId, idOk = St.requestId(args.requestId)
    if not gate(player, "admin.currency", false, requestId) then return end
    local res
    if idOk then
        res = { ok = true, currencies = Cfg.snapshot(), options = Cfg.options() }
    else
        res = { ok = false, error = "invalid_args" }
    end
    res.requestId = requestId
    res.perms = { read = true, write = A.isAdmin(player) }
    S.reply(player, "admin.currency", withSupply(res))
end

S.handlers["admin.audit"] = function(player, args)
    args = type(args) == "table" and args or {}
    local extra, matches = auditQuery(player, "admin.audit", args)
    if not extra then return end
    local limit = isFiniteInt(args.limit) and args.limit > 0 and math.min(args.limit, X.AUDIT_RING) or X.AUDIT_RING
    for _, rec in ipairs(X.auditEntries()) do
        if matches(rec) then
            extra.total = extra.total + 1
            if #extra.entries < limit then extra.entries[#extra.entries + 1] = rec
            else extra.truncated = true end
        end
    end
    extra.ok, extra.max = true, X.AUDIT_RING
    S.reply(player, "admin.audit", extra)
end

S.handlers["admin.system"] = function(player, args)
    if not gate(player, "admin.system", false) then return end
    S.reply(player, "admin.system", A.system(A.isAdmin(player), EC.canManageSettings(player)))
end

-- admin.icons {action = "reload" | "status"}: reload re-reads icons/<id>.png for every currency
-- (write gate; the resulting hash changes are audited by ECConfig), status only reports the
-- outcome of the last read (read gate). `busy` = a reload is still in flight.
S.handlers["admin.icons"] = function(player, args)
    local reload = type(args) == "table" and args.action == "reload"
    if not gate(player, "admin.icons", reload) then return end
    local started = false
    if reload then
        started = I.reload(player:getUsername(), "admin_reload")
        EC.log("admin " .. tostring(player:getUsername()) .. " icon reload " .. (started and "started" or "refused: busy"))
    end
    S.reply(player, "admin.icons", { ok = true, started = started, busy = I.busy(), icons = I.status(), perms = { read = true, write = A.isAdmin(player) } })
end

-- admin.sources {action = "list"} (read gate) | {action = "set", modId, dailyMintCap?, dailyBurnCap?
-- (false = unlimited), enabled?, reason} (write gate): per-source integration caps (spec 21.5).
S.handlers["admin.sources"] = function(player, args)
    local set = type(args) == "table" and args.action == "set"
    if not gate(player, "admin.sources", set) then return end
    local res = { ok = true, perms = { read = true, write = A.isAdmin(player) } }
    if set then
        local reason = args.reason
        if type(reason) ~= "string" or charCount((string.gsub(reason, "^%s*(.-)%s*$", "%1"))) < 1 or #reason > A.REASON_MAX * 3 then
            res = { ok = false, error = "reason_too_short" }
        else
            local ok, err = G.setSource(args.modId, { dailyMintCap = args.dailyMintCap, dailyBurnCap = args.dailyBurnCap, enabled = args.enabled },
                player:getUsername(), reason)
            if not ok then res = { ok = false, error = err } end
        end
        if type(args) == "table" then res.requestId = args.requestId end
    end
    res.sources = G.sources()
    S.reply(player, "admin.sources", res)
end

-- admin.players {query, requestId?, context?} (read gate): candidate usernames for a search box.
-- Everyone online plus every account the ledger knows (wallets, claims, frozen marks),
-- case-insensitive substring match, online first then alphabetical, at most PLAYERS_MAX. An empty
-- query lists only the online players: scanning and sorting thousands of dormant accounts for no
-- filter is not worth a tick. requestId and context are echoed unchanged: the one shared picker
-- serves several pages, and a reply to another page's ask must not be applied to this one.
A.PLAYERS_MAX = 30
A.PLAYERS_SCAN_MAX = 200
S.handlers["admin.players"] = function(player, args)
    args = type(args) == "table" and args or {}
    local requestId = readRequestId(args)
    local context = (args.context == "player" or args.context == "transactions") and args.context or nil
    if not gate(player, "admin.players", false, requestId, context) then return end
    if (args.requestId ~= nil and requestId == nil) or (args.context ~= nil and context == nil) then
        S.reply(player, "admin.players", { ok = false, error = "invalid_args", query = "", players = {},
            total = 0, truncated = false, requestId = requestId, context = context })
        return
    end
    local query = type(args.query) == "string" and args.query or ""
    query = string.lower(string.sub((string.gsub(query, "^%s*(.-)%s*$", "%1")), 1, 64))
    local seen, list, truncated = {}, {}, false
    local function add(name, online)
        local rec = seen[name]
        if rec then
            if online then rec.online = true end
            return
        end
        if query ~= "" and not string.find(string.lower(name), query, 1, true) then return end
        if #list >= A.PLAYERS_SCAN_MAX then truncated = true return end
        rec = { username = name, online = online }
        seen[name] = rec
        list[#list + 1] = rec
    end
    S.forEachOnline(function(p) add(p:getUsername(), true) end)
    if query ~= "" then
        for name in pairs(md.wallets) do
            if not L.isSystemAccount(name) then add(name, false) end
        end
        for name in pairs(md.claims or {}) do add(name, false) end
        for name in pairs(md.frozen or {}) do add(name, false) end
    end
    EC.sortSafe(list, function(a, b)
        if a.online ~= b.online then return a.online end
        return string.lower(a.username) < string.lower(b.username)
    end)
    local total = #list
    while #list > A.PLAYERS_MAX do table.remove(list) end
    S.reply(player, "admin.players", { ok = true, query = query, players = list, total = total,
        truncated = truncated, requestId = requestId, context = context })
end

-- admin.accounts {query?, status?, sort?, descending?, page?, requestId?} (read gate): the
-- server's account list - every account the economy knows (a wallet, a reward record, a freeze
-- mark, or a session online right now), system accounts excluded, offline and empty accounts
-- included. It is not a wider admin.players: that one answers a search box with at most
-- PLAYERS_MAX candidates out of a PLAYERS_SCAN_MAX scan, and a list that stops at the 200th
-- account it happened to walk is not this server's accounts. Here the whole population is
-- filtered and sorted first and paged afterwards, so page 3 is the third page of the matches.
-- Only the 20 rows of the requested page carry balances, and one census (ECStats) serves every
-- page opened within a few seconds: no per-player query, no per-tick scan, no broadcast.
S.handlers["admin.accounts"] = function(player, args)
    args = type(args) == "table" and args or {}
    local requestId, idOk = St.requestId(args.requestId)
    if not gate(player, "admin.accounts", false, requestId) then return end
    local res
    if idOk then
        res = St.accounts(args)
    else
        res = { ok = false, error = "invalid_args", at = EC.now() }
    end
    res.requestId = requestId
    res.perms = { read = true, write = A.isAdmin(player) }
    S.reply(player, "admin.accounts", res)
end

-- admin.receipts {username} (read gate): the target's receipt files for the previous and current
-- month, rolledBack per line - the lookup's 5-entry ring never shows what a crash rolled back.
S.handlers["admin.receipts"] = function(player, args)
    if not gate(player, "admin.receipts", false) then return end
    local target = type(args) == "table" and args.username or nil
    if not validUsername(target) then
        S.reply(player, "admin.receipts", { username = tostring(target), entries = {}, error = "invalid_args" })
        return
    end
    W.tail(player, "admin.receipts", W.receiptPaths(target, W.recentMonths(EC.now())), { username = target })
end

-- admin.option {key, value | nil (= back to the sandbox file), reason?, requestId}: runtime
-- override of one sandbox option (ECConfig.setOption validates against EC.OPTIONS). Write gate,
-- except for a manageOnly key (the admin role lists, the adjustment caps): those take the read
-- gate plus the native role-editing capability, so the economy write role cannot widen itself.
-- Which gate applies is decided by the key the server itself looked up in EC.OPTION_BY_KEY and
-- by nothing else that travels in `args`. Reply carries the whole option snapshot so the page
-- redraws, and this caller's permissions so it redraws with the right controls enabled.
-- A key that changes the running server state as it is stored (SeasonDays retimes the running
-- season) can succeed and still fail to reach everyone: that `warning` travels with the reply
-- rather than being swallowed, exactly like the one a rotation reports.
S.handlers["admin.option"] = function(player, args)
    local spec = type(args) == "table" and type(args.key) == "string" and EC.OPTION_BY_KEY[args.key] or nil
    local requestId = type(args) == "table" and type(args.requestId) == "string" and args.requestId or nil
    local res = nil
    if spec ~= nil and spec.manageOnly == true then
        if not gate(player, "admin.option", false, requestId) then return end
        if not EC.canManageSettings(player) then
            -- refused before anything is read or written; the reply still carries the snapshot
            res = { ok = false, error = "manage_settings_required", key = args.key }
        end
    elseif not gate(player, "admin.option", true, requestId) then
        return
    end
    if res == nil then
        if type(args) ~= "table" or type(args.key) ~= "string" then
            res = { ok = false, error = "invalid_args" }
        else
            local reason = type(args.reason) == "string" and args.reason ~= "" and args.reason or nil
            local ok, err, warning = Cfg.setOption(args.key, args.value, player:getUsername(), reason)
            res = ok and { ok = true, warning = warning } or { ok = false, error = err }
            res.key = args.key
        end
    end
    if type(args) == "table" then res.requestId = args.requestId end
    res.options = Cfg.options()
    res.currencies = Cfg.snapshot()
    res.perms = { read = true, write = A.isAdmin(player), manage = EC.canManageSettings(player) }
    S.reply(player, "admin.option", res)
end

-- The rotation itself: the capability, then the arguments, then one call into the season module,
-- which owns the decision and every code it can fail with (season_changed, request_conflict,
-- not_ready, data_unreadable). Nothing here rotates a season by itself, and ECSeasons' own
-- automatic deadline goes through the very same function: this mod has one rotation, not an
-- administrative copy of it that could drift from the scheduled one.
function A.startSeason(player, args, requestId)
    if not EC.canManageSettings(player) then
        return { ok = false, error = "manage_settings_required" }
    end
    local expected = args.expectedSeason
    if type(expected) ~= "string" or expected == "" or #expected > 64 or string.find(expected, "%c") then
        return { ok = false, error = "invalid_args" }
    end
    local bad, reason = reasonError(args.reason)
    if bad then return { ok = false, error = bad } end
    local res = Se.start(expected, requestId, player:getUsername(), reason, EC.now())
    if type(res) ~= "table" then return { ok = false, error = "not_ready" } end
    return { ok = res.ok == true, error = res.ok ~= true and res.error or nil,
        duplicate = res.duplicate == true or nil, warning = res.warning }
end

-- admin.seasons {action='list'|'start', requestId, expectedSeason?, reason?}: the season page.
-- `list` is the plain read gate - a read-only role may look at the history. `start` closes the
-- running season and opens the next one, and it takes the *native* role-editing capability on
-- top of that read gate, never the economy write role: a rotation archives everybody's standing
-- and starts the next season from nothing, which is not something an economy admin is
-- automatically entitled to do. `expectedSeason` is the season the caller was looking at, so an
-- automatic rotation (or another admin) that got there first is refused as season_changed
-- instead of skipping a season, and one requestId rotates at most once however often a client
-- resends it. Every reply carries the season state and this caller's permissions, so the page
-- redraws from one source whatever the outcome was.
S.handlers["admin.seasons"] = function(player, args)
    args = type(args) == "table" and args or {}
    local requestId, idOk = St.requestId(args.requestId)
    if not gate(player, "admin.seasons", false, requestId) then return end
    local action = args.action
    local known = action == "list" or action == "start"
    local res = nil
    if not idOk or requestId == nil or not known then
        res = { ok = false, error = "invalid_args" }
    elseif action == "start" then
        res = A.startSeason(player, args, requestId)
    else
        res = { ok = true }
    end
    res.action = known and action or nil
    res.requestId = requestId
    local state, stateErr = St.seasonState()
    res.seasonState = state
    if res.seasonState == nil and res.ok == true then
        -- The page is the season state; a reply without it is not a successful read, and saying
        -- ok with no seasons attached would render as "this server has never had a season".
        res.ok, res.error = false, stateErr or "data_unreadable"
    end
    res.perms = { read = true, write = A.isAdmin(player), manage = EC.canManageSettings(player) }
    S.reply(player, "admin.seasons", res)
end

-- admin.catalog {action=list|set|add|batch|reload, id?, ids?, fields?, item?, qty?, category?,
-- dailyCap?, dailyCapScope?, enabled?, buybackCap?, prices?, revision?, reason?, requestId}:
-- list = the catalog with this admin's own remaining caps (read gate); set = edit one SKU in
-- catalog.json, add = append a new SKU to it, batch = apply the same explicitly chosen fields to
-- a selection of SKUs (write gate, audited, pushed to everyone online); reload = re-read the file
-- (write gate). Every edit carries the revision the panel's snapshot was built from, so an edit
-- racing another admin is refused instead of overwriting them; the item of a new SKU is checked
-- against the server's own ScriptManager, never trusted from the client.
--
-- A SKU is priced per currency, so the money fields travel as one nested patch:
--   prices = { [currencyId] = { price?, bidPrice?, enabled?, buyback? } }
-- Only the leaves the admin actually chose are sent. A currency the patch does not mention keeps
-- its quote (including "no quote at all" - which is not a price of 0), and `false` or `0` is a
-- chosen value, never an absent one. There is no flat price / bidPrice / buyback any more.
-- Validation of every field, the cross-SKU arbitrage check and the audit trail belong to ECShop:
-- a second copy of the rules here would be a second truth about what a valid catalog is. This
-- handler only refuses a `prices` that is not an object at all, and passes the rest through.
-- Every reply carries the whole catalog snapshot so the page redraws from one source.

-- Whatever the catalog writer has to say about the row it refused (or the rows it changed),
-- passed through as one nested block. It stays nested on purpose: the reply also carries the
-- whole catalog snapshot, and a flattened `count` or `field` would either collide with it or
-- become a second path a client could read the same fact from - and get a different answer.
local function catalogExtra(res, extra)
    if type(extra) ~= "table" then return end
    res.extra = extra
end

-- What belongs to the command rather than to the SKU: the action being performed, the record
-- it names, the revision it was built from, the correlation id and the written reason. Those
-- are this handler's business. Everything else in the packet is a claim about the SKU and
-- goes to the catalog writer untouched - including names it does not know and names the new
-- shape retired (price / bidPrice / buyback), which come back as `unknown_field` naming the
-- field. Filtering to a whitelist here is what let `set{id=..., price=7}` answer "nothing
-- changed" as though it had succeeded, and a partial apply of `qty` beside an unknown `foo`
-- is the same failure wearing a different hat: the validator decides, not this list.
local CATALOG_TRANSPORT_FIELDS = { action = true, id = true, ids = true, fields = true,
    revision = true, requestId = true, reason = true }

local function skuPatch(args)
    local patch = {}
    for field, value in pairs(args) do
        if not CATALOG_TRANSPORT_FIELDS[field] then patch[field] = value end
    end
    return patch
end

-- Merge the page's read snapshot into a reply without letting it answer for the write. A
-- browse / list snapshot is always ok=true - the read worked - so copying it field by field
-- over a refused delist, cancel or catalog edit turns "this failed, here is why" into
-- "ok=true, error=<code>", which every client reads as success. The verdict of the operation
-- the administrator actually asked for is restored afterwards and always wins.
local function mergeSnapshot(res, snap)
    if type(snap) ~= "table" then return res end
    local ok, err, detail = res.ok, res.error, res.detail
    for k, v in pairs(snap) do res[k] = v end
    res.ok, res.error, res.detail = ok, err, detail
    return res
end

S.handlers["admin.catalog"] = function(player, args)
    local action = type(args) == "table" and args.action or "list"
    local write = action == "set" or action == "add" or action == "batch" or action == "reload"
    if not gate(player, "admin.catalog", write, type(args) == "table" and args.requestId or nil) then return end
    local res = { ok = true }
    local reason = type(args) == "table" and type(args.reason) == "string" and args.reason ~= "" and args.reason or nil
    local badPrices = type(args) == "table" and args.prices ~= nil and type(args.prices) ~= "table"
    if action == "set" then
        if type(args.id) ~= "string" or badPrices then
            res = { ok = false, error = "invalid_args" }
            res.id = type(args.id) == "string" and args.id or nil
        else
            local ok, err, extra = Shop.update(args.id, skuPatch(args),
                player:getUsername(), reason, args.revision)
            if not ok then res = { ok = false, error = err or "invalid_args" } end
            res.id = args.id
            catalogExtra(res, extra)
        end
    elseif action == "add" then
        if badPrices then
            res = { ok = false, error = "invalid_args" }
            res.id = type(args.id) == "string" and args.id or nil
        else
            local raw = skuPatch(args)
            raw.id, raw.item = args.id, args.item
            local ok, err, extra = Shop.add(raw, player:getUsername(), reason, args.revision)
            if not ok then res = { ok = false, error = err or "invalid_args" } end
            res.id = type(args.id) == "string" and args.id or nil
            catalogExtra(res, extra)
        end
    elseif action == "batch" then
        -- One validated write for the whole selection: Shop.updateMany checks every row against
        -- one expected revision, commits once and audits once. A per-SKU loop would leave half a
        -- selection applied when row seven turns out to be invalid. `extra` names the row and the
        -- field that failed so the page can point at it instead of saying "something was wrong".
        if type(args.ids) ~= "table" or type(args.fields) ~= "table"
            or (args.fields.prices ~= nil and type(args.fields.prices) ~= "table") then
            res = { ok = false, error = "invalid_args" }
        else
            local ok, err, extra = Shop.updateMany(args.ids, args.fields, player:getUsername(), reason, args.revision)
            if not ok then res = { ok = false, error = err or "invalid_args" } end
            catalogExtra(res, extra)
        end
    elseif action == "reload" then
        -- A refused reload says which kind of refusal it was (an unreadable file, a broken
        -- document, a price table that would let someone trade in a circle). "catalog_invalid"
        -- is only the fallback for a writer that names no code: telling an admin the file is
        -- malformed when the disk could not be read sends them to fix the wrong thing.
        local ok, errText, errorCode, extra = Shop.reload(player:getUsername())
        if not ok then
            res = { ok = false, error = errorCode or "catalog_invalid", detail = errText }
            catalogExtra(res, extra)
        end
    end
    if type(args) == "table" then res.requestId = args.requestId end
    local snap = Shop.snapshot(player:getUsername(), EC.now())
    mergeSnapshot(res, snap)
    res.perms = { read = true, write = A.isAdmin(player) }
    S.reply(player, "admin.catalog", res)
end

-- Optional seller is an exact username; filtering precedes the market's page limit.
S.handlers["admin.listings"] = function(player, args)
    args = type(args) == "table" and args or {}
    local requestId = readRequestId(args)
    local delist = args.action == "delist"
    if not gate(player, "admin.listings", delist, requestId) then return end
    if (args.requestId ~= nil and requestId == nil) or (args.seller ~= nil and not validUsername(args.seller)) then
        S.reply(player, "admin.listings", { ok = false, error = "invalid_args", requestId = requestId,
            perms = { read = true, write = A.isAdmin(player) } })
        return
    end
    local res = { ok = true, requestId = requestId, seller = args.seller }
    if delist then
        local reason = type(args.reason) == "string" and args.reason ~= "" and args.reason or nil
        local ok, err = Mk.delist(player:getUsername(), args.listingId, reason)
        if not ok then res.ok, res.error = false, err end
        res.listingId = args.listingId
    end
    local snap = Mk.browse(player:getUsername(), { page = args.page or 1, query = args.query,
        seller = args.seller, sort = "time" })
    mergeSnapshot(res, snap)
    res.perms = { read = true, write = A.isAdmin(player) }
    S.reply(player, "admin.listings", res)
end

-- admin.auctions {action=list|cancel|history, auctionId?, reason?, query?, requestId}: every active
-- auction (read gate); cancel releases the highest bid and returns the items to the seller (write
-- gate, audited); history is the server-wide public record (read gate, ECAuction.history - same
-- reply shape as the player's auction.history, marked history=true, no active-auction snapshot).
S.handlers["admin.auctions"] = function(player, args)
    args = type(args) == "table" and args or {}
    local Au = S.Auction
    local action = args.action or "list"
    local requestId = readRequestId(args)
    if not gate(player, "admin.auctions", action == "cancel", requestId) then return end
    if (args.requestId ~= nil and requestId == nil) or (args.seller ~= nil and not validUsername(args.seller)) then
        S.reply(player, "admin.auctions", { ok = false, error = "invalid_args", requestId = requestId,
            perms = { read = true, write = A.isAdmin(player) } })
        return
    end
    if action == "history" then
        Au.history(player, args, { write = A.isAdmin(player) })
        return
    end
    local res = { ok = true, requestId = requestId, seller = args.seller }
    if action == "cancel" then
        local reason = type(args.reason) == "string" and args.reason or ""
        local ok, err = Au.adminCancel(player:getUsername(), args.auctionId, reason)
        if not ok then res.ok, res.error = false, err end
    end
    local page = Au.browse(player:getUsername(), { page = args.page or 1, sort = "ending",
        query = args.query, seller = args.seller })
    res.items, res.page, res.pages, res.total = page.items, page.page, page.pages, page.total
    res.perms = { read = true, write = A.isAdmin(player) }
    S.reply(player, "admin.auctions", res)
end

-- admin.whitelist {action=status|set|reload, category?, allowed?, fullType?, mode?, requestId}: the
-- listing whitelist file. status = counts + the four lists (read gate); set = one edit written
-- back into whitelist.json (write gate, audited; see Codec.update); reload = re-read the file
-- (write gate). Every reply carries the whole document so the page redraws from one source.
S.handlers["admin.whitelist"] = function(player, args)
    local action = type(args) == "table" and args.action or "status"
    local write = action == "set" or action == "reload"
    if not gate(player, "admin.whitelist", write, type(args) == "table" and args.requestId or nil) then return end
    local res = { ok = true }
    if action == "set" then
        local ok, err = Codec.update(args, player:getUsername())
        if not ok then res = { ok = false, error = err } end
    elseif action == "reload" then
        local ok, err = Codec.reload(player:getUsername())
        if not ok then res = { ok = false, error = "whitelist_invalid", detail = err } end
    end
    if write and res.ok then
        -- an open picker re-asks for its candidates: the verdicts it shows just changed
        S.broadcast("market.whitelist", { at = EC.now() })
    end
    if type(args) == "table" then res.requestId = args.requestId end
    res.whitelist = Codec.status(true)
    res.perms = { read = true, write = A.isAdmin(player) }
    S.reply(player, "admin.whitelist", res)
end

-- admin.marketHistory {username} (read gate): that player's market history file, tailed like
-- the receipts (this and last month, newest first, rolled-back lines flagged).
S.handlers["admin.marketHistory"] = function(player, args)
    if not gate(player, "admin.marketHistory", false) then return end
    local username = type(args) == "table" and args.username or nil
    if type(username) ~= "string" or username == "" or #username > 64 then
        S.reply(player, "admin.marketHistory", { entries = {}, error = "invalid_args" })
        return
    end
    local W = EC.Wallet
    W.tail(player, "admin.marketHistory", W.marketPaths(username, W.recentMonths(EC.now())), { username = username })
end

-- Every audit row a page receives says where it came from and whether it is the whole record:
-- source='file' + full=true here, source='ring' + full=false for the 40-character ModData copies
-- (X.auditEntries). `key` is the identity admin.auditDetail asks for; `month` is derived from
-- the record's own timestamp, and stays nil when the line has none - a guessed month would send
-- the lookup to a file that cannot hold the record.
local function auditRow(rec, key)
    if rec.type ~= "audit" then return nil end
    rec.key = key or X.auditKey(rec)
    rec.month = isFiniteInt(rec.ts) and EC.monthKey(rec.ts) or nil
    rec.full = true
    rec.source = "file"
    return rec
end

-- Audit files default to the previous/current month. Explicit dates may name any age, within
-- the same 62-day span as the money reader; exact actor filtering happens before the 200-row tail.
S.handlers["admin.auditFile"] = function(player, args)
    args = type(args) == "table" and args or {}
    local extra, matches = auditQuery(player, "admin.auditFile", args)
    if not extra then return end
    local months, paths, previous = {}, {}, nil
    for day = dayStart(extra.fromMs), extra.toMs - 1, DAY_MS do
        local month = EC.monthKey(day)
        if month ~= previous then
            months[#months + 1] = month
            paths[#paths + 1] = X.ROOT .. "/audit/" .. month .. ".json"
            previous = month
        end
    end
    extra.months = months
    -- W.tail supplies its own count and truncation after the projector has seen every input row.
    extra.entries, extra.total, extra.truncated = nil, nil, nil
    W.tail(player, "admin.auditFile", paths, extra, function(rec)
        if rec.type ~= "audit" or not matches(rec) then return nil end
        return auditRow(rec)
    end, true)
end

-- admin.auditDetail {key, month, requestId?} (read gate): the full record behind one audit row.
-- `month` picks exactly one audit file - any month, not only the two the list page tails - so an
-- operation from an old month can be read in full; the read goes through the same fence and the
-- same 200-entry bound as every other history read, and nothing here widens the list page's
-- window. The verdict is always explicit:
--   missing           no such file, or no line in it carries that key
--   read_failed       the file broke halfway (the page keeps its summary and says so)
--   ambiguous_record  a legacy compound key matches two lines of *different* content. Records
--                     written before the unique auditId have no identity of their own; showing
--                     the first one as "the" record would put words in an admin's mouth.
-- A new key is one auditId, but a legacy key is X.auditKey's JSON of epoch/seq/ts/action/admin/
-- target/field: two 64-character usernames plus the escaping already pass 250 characters, so the
-- bound only exists to keep an absurd packet out - it must not be tight enough to make a real
-- old record unopenable.
A.AUDIT_KEY_CHARS = 512
S.handlers["admin.auditDetail"] = function(player, args)
    args = type(args) == "table" and args or {}
    local requestId = readRequestId(args)
    if not gate(player, "admin.auditDetail", false, requestId) then return end
    local key, month = args.key, args.month
    local function fail(code)
        S.reply(player, "admin.auditDetail", {
            entries = {}, total = 0, truncated = false, error = code, requestId = requestId,
            key = type(key) == "string" and key or "", month = type(month) == "string" and month or "",
            perms = { read = true, write = A.isAdmin(player) },
        })
    end
    if args.requestId ~= nil and requestId == nil then return fail("invalid_args") end
    if type(key) ~= "string" or key == "" or #key > A.AUDIT_KEY_CHARS or string.find(key, "%c") then
        return fail("invalid_args")
    end
    -- YYYYMM only, month 01..12: the string becomes part of a path, so it is matched, never
    -- coerced. A year with no file is simply `missing`.
    if type(month) ~= "string" or not string.match(month, "^%d%d%d%d%d%d$") then return fail("invalid_args") end
    local mm = string.sub(month, 5, 6)
    if mm < "01" or mm > "12" then return fail("invalid_args") end

    -- `missing` stands until a line matches; the projector clears it on the first match and
    -- raises ambiguity when a second, different record carries the same key. A read that breaks
    -- keeps read_failed (W.tail does not let echoed fields overwrite that verdict).
    local extra = { key = key, month = month, requestId = requestId, error = "missing",
        perms = { read = true, write = A.isAdmin(player) } }
    local firstSig = nil
    W.tail(player, "admin.auditDetail", { X.ROOT .. "/audit/" .. month .. ".json" }, extra, function(rec)
        local k = X.auditKey(rec)
        if k ~= key then return nil end
        -- A unique auditId identifies one line: no later line can hold it, so stop here.
        if type(rec.auditId) == "string" and rec.auditId == key then
            extra.error = nil
            return auditRow(rec, k), true
        end
        local out = auditRow(rec, k)
        local sig = EC.jsonEncode(out)
        if firstSig == nil then
            firstSig = sig
            extra.error = nil
        elseif sig == firstSig then
            return nil                      -- the very same record twice: one row, not a conflict
        else
            extra.error = "ambiguous_record"
        end
        return out
    end, true)
end

-- ---------- asset reconciliation (admin.recovery) ----------
--
-- admin.recovery {action='list'|'overview'|'recheck'|'resolve', username, requestId, page?,
--                 query?, key?, revision?, decision?, note?}: the read side of ECRecovery's held
-- records plus the four decisions an administrator may take on one of them. list (one account)
-- and overview (the whole server, no account asked for) are read-gated; recheck and resolve are
-- write-gated and need the target online, because both are decided from a fresh walk of that
-- player's backpack and neither may be taken from a remembered snapshot.
--
-- Three properties this section owns:
--
--   * nothing here is an automatic fix. Every row carries the reason this server could not
--     decide, every write needs a written reason, and `approve` is explicitly an administrator
--     accepting an object whose source this server never verified - it is not a verification and
--     the reply says so by naming the tokens it wrote.
--   * the rows and the available actions are recomputed on every call, and the revision the
--     administrator was shown is compared against the evidence as it stands now. `revision` is a
--     fingerprint of that whole evidence - the engine ids, the counts, the source state, the
--     letter's own state and the pending record - not of a quantity: two different sets of three
--     objects must never look like the same decision.
--   * every decision reuses the machinery that already exists. Removals go through the recovery
--     core's confirmed removal (the container read is the postcondition), a restore goes through
--     reserveOut -> mailbox return -> finishOut so the world gets a deduplicating receipt, and a
--     discard writes that same receipt with nothing in it. No second ledger: X.audit and X.emit
--     carry the trail, exactly as every other admin write does.

local Rcv = S.Recovery
A.RECOVERY_PER_PAGE = 20
A.RECOVERY_KEY_CHARS = 160
A.RECOVERY_RESTORE_KINDS = { listing = true, auction = true, ["return"] = true }
A.RECOVERY_QUERY_CHARS = 64       -- the overview's account filter, as the client sends it

-- What the recovery journal (ECRecoveryJournal, read for us by ECRecovery.judgePending - this
-- file never opens a file and never waits for one) says about a protocol 2 operation, and what
-- an administrator may do about it. Two fields of the judgement decide, never the reason text:
--
--   judged.restorable == false   nothing may be rebuilt, by hand or otherwise. The read has
--                                not finished, or broke, or the module is absent - or a record
--                                *was* found whose own commit point says it survived, is
--                                unknown, or has aged past the retention floor. The only thing
--                                to press is "check again"; the reason names which it was.
--   judged.unproven == true      this server has no record of the operation at all. An
--                                administrator may still hand the goods back or void it, but
--                                only as an explicit acceptance of the player's own account of
--                                it: the reply, the page and the audit line all say the source
--                                was never proven here. No money is created on this path - it
--                                returns objects or voids an operation, it never mints and
--                                never touches an adjustment allowance.
--   judged.replay                the server's own record. It decides the item, the quantity,
--                                the origins and every economic field, whatever the player's
--                                save claims. A commit point that does not line up
--                                (journal_mismatch) is still this case when the record was
--                                found: held, reported, and resolved from the record - never
--                                downgraded into believing the save.
--
-- A pre-journal operation (pending_legacy / receipt_forgotten) carries no flags; it is the
-- journal_missing situation and is treated as unproven.
A.RECOVERY_MANUAL_REASONS = { pending_legacy = true, receipt_forgotten = true,
    journal_missing = true }
-- Every state a protocol 2 judgement can hold on: the journal reader's five, the two the
-- recovery core adds around it, and the checks it makes against the live world. None of them
-- is a manual exit - a judgement in one of these that does not say restorable is a no - and
-- the reason travels to the page as the blocker, so "still reading", "the record refuses" and
-- "nothing to do" never look alike.
A.RECOVERY_JOURNAL_REASONS = { journal_pending = true, journal_missing = true,
    journal_mismatch = true, journal_unreadable = true, journal_malformed = true,
    journal_unavailable = true, proof_required = true, outcome_unverified = true,
    native_identity_unverified = true, origin_unverified = true, origin_partial = true,
    world_owner = true, world_mismatch = true, world_unverified = true,
    -- the successor is this server's own administrative discard: closed, reviewable only
    -- against `previous`, never rebuilt automatically
    admin_discard_rolledback = true,
    -- the objects moved between the scan the evidence was matched against and now: a
    -- conservative hold, and counter-evidence rather than an absence of it
    source_state_changed = true }

-- restorable as this file must read it: an explicit false is a no, and a journal state that
-- does not say yes is a no as well. Only a pre-journal judgement, which carries no flag at
-- all, is allowed to fall through to the checks that existed before the journal.
local function judgedRestorable(judged, reason)
    if judged == nil then return false end
    if judged.restorable ~= nil then return judged.restorable == true end
    return A.RECOVERY_JOURNAL_REASONS[reason] ~= true
end

-- The summary of what a decision would actually do, for the confirmation dialog: which item,
-- how many, and which objects. Never the whole trusted record - a page gets what it needs to
-- show an administrator the consequence, not the server's evidence to forward elsewhere.
local function recoveryPreview(evidence, origins, source)
    local snapshot = type(evidence) == "table" and type(evidence.snapshot) == "table"
        and evidence.snapshot or nil
    local out = { source = source, item = snapshot and snapshot.type or nil,
        qty = origins and #origins or nil, origins = {} }
    for _, origin in ipairs(origins or {}) do
        out.origins[#out.origins + 1] = { nativeId = origin.nativeId, src = origin.src }
    end
    return out
end

local function removalBlock(row)
    local ok, blocked = pcall(function()
        if row.item:isEquipped() or row.item:getAttachedSlot() > -1 then return "legacy_item_equipped" end
        if row.item.getInventory then
            local contents = row.item:getInventory()
            if contents and contents:getItems():size() > 0 then return "legacy_container_not_empty" end
        end
        return nil
    end)
    if not ok then return "legacy_item_unreadable" end
    return blocked
end

-- The objects one operation took out, as this page must name them: one entry per unit, no
-- duplicates, engine ids inside the range the engine issues. A protocol 2 record (and the
-- journal's own copy of one) carries its origins already; an older one carries bare engine
-- ids. Both are accepted, neither is invented: a record whose origins do not add up to its
-- own quantity is refused rather than trimmed to fit.
local function pendingOrigins(pend)
    if type(pend) ~= "table" or not isFiniteInt(pend.qty) or pend.qty < 1
        or pend.qty > Rcv.ORIGINS_MAX then return nil end
    local seen = {}
    if type(pend.origins) == "table" then
        local origins = {}
        if #pend.origins ~= pend.qty then return nil end
        for i, origin in ipairs(pend.origins) do
            local id = type(origin) == "table" and origin.nativeId or nil
            if not isFiniteInt(id) or id < -2147483648 or id > 2147483647 or seen[id] then return nil end
            seen[id] = true
            origins[i] = { src = type(origin.src) == "string" and origin.src or "legacy", nativeId = id }
        end
        return origins
    end
    local ids = pend.itemIds or { pend.itemId }
    if type(ids) ~= "table" or #ids ~= pend.qty then return nil end
    local origins = {}
    for i, id in ipairs(ids) do
        if not isFiniteInt(id) or id < -2147483648 or id > 2147483647 or seen[id] then return nil end
        seen[id] = true
        origins[i] = { src = "legacy", nativeId = id }
    end
    return origins
end

-- Which origins a decision may act on.
--
-- With a record in hand it is never the whole replay: the judgement has already walked the
-- server's own origins against the world and says which of them are actually missing and
-- eligible (`validOrigins` / `valid`). Replaying everything would hand back units that are
-- still in the backpack or still held upstream - the same duplication the authoritative
-- re-judgement exists to prevent. The entries are used exactly as given, because a record
-- carries more than engine ids: the unit token, the letter it came from, the owner written
-- into it. That is the chain the consumption bookkeeping is keyed on, and projecting it down
-- to src/nativeId would write a return whose sources can never be marked consumed.
--
-- Only an explicitly accepted claim - no record at all - goes through the locator-only
-- projection, because a locator is all such a claim ever had.
local function evidenceOrigins(evidence, proven, judged)
    if not proven then return pendingOrigins(evidence) end
    local eligible = type(judged) == "table" and judged.validOrigins or nil
    if type(eligible) ~= "table" then return nil end
    local count = #eligible
    if count < 1 or count > Rcv.ORIGINS_MAX then return nil end
    if isFiniteInt(judged.valid) and judged.valid ~= count then return nil end
    for _, origin in ipairs(eligible) do
        if type(origin) ~= "table" then return nil end
    end
    return eligible
end

-- The objects of one generation zero letter that this snapshot can see. The letter's own stamp
-- is what groups them, so nothing here is matched by a bare engine id.
--
-- A consumption lookup has three answers, not two: an operation id (spent), nothing (never
-- spent) and "the place that records it could not be read". The third is the one that must
-- never be rounded off - read as "not spent" it lets an administrator hand out an object a
-- second time, read as "spent" it lets one delete an object nobody proved was spent. So an
-- unreadable source keeps the object visible on the page and blocks every button on it.
local function legacyRows(scan, mailId, consumedOnly)
    local rows, blocked = {}, nil
    local letter = (scan and type(mailId) == "string") and scan.stamped[mailId] or nil
    for _, row in ipairs(letter and letter.items or {}) do
        local origin = row.stamp and Rcv.originOf(row.item) or nil
        local consumed, unreadable = nil, false
        if consumedOnly and origin then
            local id, _, state = Rcv.consumer(origin)
            consumed, unreadable = id, state == "unreadable"
        end
        if not row.gone and ((not consumedOnly and Rcv.gen0Stamp(row.stamp))
            or (consumedOnly and (consumed ~= nil or unreadable)
                and (origin.gen0 or Rcv.gen0Unit(origin.unit)))) then
            rows[#rows + 1] = row
            blocked = blocked or (unreadable and "legacy_source_unknown") or removalBlock(row)
        end
    end
    return rows, blocked
end

-- What the page may do with this record, and the fingerprint of the evidence that says so.
local function recoveryRow(username, rec, scan, pdata)
    local out = { key = rec.key, reason = rec.reason, at = rec.at, item = rec.item,
        qty = tonumber(rec.qty), opId = rec.opId, mailId = rec.mailId, txId = rec.txId,
        epoch = rec.epoch, seq = tonumber(rec.seq), detail = rec.detail,
        sourceState = rec.sourceState or "n_a", nativeIds = {},
        actions = { approve = false, remove = false, restore = false, discard = false } }
    local fingerprint = { key = rec.key, reason = rec.reason, scanned = scan ~= nil }
    if rec.kind == "legacy" and type(rec.mailId) == "string" then
        local consumedOnly = rec.reason == "legacy_unit_consumed"
        local rows, blocked = legacyRows(scan, rec.mailId, consumedOnly)
        local entry, why = M.entryOf(username, rec.mailId)
        if not entry then entry, why = M.findEntry(rec.mailId) end
        local commonVerdict, mixed, seen = nil, false, {}
        fingerprint.units = {}
        for _, row in ipairs(rows) do
            out.nativeIds[#out.nativeIds + 1] = row.nativeId
            local verdict = Rcv.verdict(row.stamp.epoch, tonumber(row.stamp.seq))
            if commonVerdict == nil then commonVerdict = verdict
            elseif commonVerdict ~= verdict then mixed = true end
            local token = Rcv.gen0Token(rec.mailId, row.nativeId)
            if seen[row.nativeId] or (scan.byToken[token] and scan.byToken[token] ~= row) then
                blocked = "legacy_duplicate_locator"
            elseif not consumedOnly then
                local byOrigin, _, originState = Rcv.consumer(Rcv.originOf(row.item))
                local byToken, _, tokenState = Rcv.consumer({ unit = token })
                if byOrigin ~= nil or byToken ~= nil then blocked = "legacy_unit_consumed"
                elseif originState == "unreadable" or tokenState == "unreadable" then
                    blocked = "legacy_source_unknown"
                end
            end
            seen[row.nativeId] = true
            fingerprint.units[#fingerprint.units + 1] = { id = row.nativeId, item = row.fullType, stamp = row.stamp }
        end
        out.kind = "legacy"
        -- When the letter is gone there is no recorded item type either; what the objects in
        -- hand actually are is an observation, not an inference, and it is all the page gets.
        out.item = out.item or (entry and entry.item) or (rows[1] and rows[1].fullType) or nil
        out.presentQty = scan and #rows or nil
        out.equipped = blocked == "legacy_item_equipped" or nil
        out.verdict = mixed and "unknown" or commonVerdict or Rcv.verdict(rec.epoch, tonumber(rec.seq))
        if entry then out.sourceState = "present"
        elseif why == "ambiguous" then out.sourceState = "ambiguous"
        elseif out.verdict == "rolledback" then out.sourceState = "rolledback"
        elseif out.verdict == "survived" or out.verdict == "current" then out.sourceState = "pruned"
        else out.sourceState = "unknown" end
        if mixed then blocked = "legacy_mixed_claims" end
        local absent = entry == nil and why ~= "ambiguous"
        out.actions.approve = scan ~= nil and #rows > 0 and absent and not blocked
            and not consumedOnly and out.verdict ~= "rolledback"
        out.actions.remove = scan ~= nil and #rows > 0 and not blocked
            and (consumedOnly or (absent and out.verdict == "rolledback"))
        out.blocked = blocked
        fingerprint.state, fingerprint.present, fingerprint.verdict = out.sourceState, out.presentQty, out.verdict
        fingerprint.blocked = blocked
        fingerprint.letter = entry and { state = entry.state, claimSeq = entry.claimSeq,
            owner = entry.owner, units = entry.units, outUnits = entry.outUnits } or "none"
    elseif type(rec.opId) == "string" and (A.RECOVERY_MANUAL_REASONS[rec.reason]
        or A.RECOVERY_JOURNAL_REASONS[rec.reason] or rec.reason == "receipt_forgotten") then
        local pend = pdata and pdata.pendingOuts[rec.opId] or nil
        local judged = pend and scan and Rcv.judgePending(username, rec.opId, pend, scan) or nil
        -- A line found under this operation id that belongs to *another account* is evidence,
        -- and it is evidence against this claim: the id is known and it is not this account's.
        -- That is not the same situation as "this server has no record", so it opens nothing -
        -- endorsing the claim here would write a fresh receipt for an operation id that
        -- demonstrably belongs to someone else. Refused, re-checkable, and said without a
        -- single word about whose it is: no record of it is read even if one were attached,
        -- so nothing of that account can reach this row by any field.
        local judgedReason = (judged and judged.reason) or rec.reason
        local foreign = (judged ~= nil and judged.foreign == true)
            or (type(judged) == "table" and type(judged.detail) == "table"
                and judged.detail.owner == true)
        -- The evidence, and what the judgement allows. A record the judgement carries is the
        -- server's own and decides everything; only a judgement that says so outright
        -- (unproven) falls back to what the player's save claims, and says so in the row, in
        -- the preview and in the audit line.
        local proof = (not foreign) and judged and type(judged.replay) == "table"
            and judged.replay or nil
        -- `unproven` is the judgement's own word. The fallback below is only for a judgement
        -- that carries no journal flags at all - a pre-journal operation - and never for one
        -- that answered with evidence in hand: a refusal that names a record must not turn
        -- into an acceptance of the claim just because its reason is an old one.
        local unproven = not foreign and ((judged and judged.unproven == true)
            or (judged ~= nil and proof == nil and judged.restorable == nil and judged.unproven == nil
                and A.RECOVERY_MANUAL_REASONS[judgedReason] == true))
        local restorable = not foreign and judgedRestorable(judged, judgedReason)
        -- The successor - the last legitimate decision in the server's own file - is what the
        -- commit point, the verdict and the retention floor are read from, always. When that
        -- successor is an administrative discard the operation is closed, and the only thing
        -- a human review may rebuild from is `previous`: the last server record that was not
        -- a discard. Without one there is nothing proven to rebuild, so the review may only
        -- close the record, never create an object.
        local evidence = proof or pend
        -- `previous` is only ever read when the verdict itself says the rebuild is allowed.
        -- A previous record that exists but cannot be built from (no item type, no origins)
        -- comes back with restorable = false, and this row must then look exactly like the
        -- no-previous case: a door that leads to a blind rebuild must not be drawn at all.
        -- The verdict carries `previous` itself; the nested form is accepted too so a reader
        -- that reports it inside `detail` is not silently ignored.
        local previous = nil
        if judgedReason == "admin_discard_rolledback" and restorable and type(judged) == "table" then
            if type(judged.previous) == "table" then previous = judged.previous
            elseif type(judged.detail) == "table" and type(judged.detail.previous) == "table" then
                previous = judged.detail.previous
            end
        end
        local content = previous or evidence
        -- The successor's own commit point, as the reader reports it: what a new record of
        -- this operation has to come after. `chain` is how many lines this id already has,
        -- and `ids` names the units a source-state hold is waiting on - both passed straight
        -- through for the page to show.
        out.chain = judged and tonumber(judged.chain) or nil
        out.unitIds = (judged and type(judged.ids) == "string" and judged.ids ~= "") and judged.ids or nil
        out.reason = judgedReason
        out.source = proof and "journal" or (unproven and "player_claim" or nil)
        out.unproven = unproven or nil
        out.proofState = judgedReason
        out.outcome = judged and judged.outcome or nil
        out.pending = (judgedReason == "journal_pending") or nil
        out.kind = type(pend) == "table" and pend.kind or rec.kind
        -- Only a judgement can say which units of this operation are still in the world. A
        -- pre-journal legacy record has no judgement at all, and there is no honest empty
        -- split to stand in for one: "nobody looked" is reported as unknown, never as zero.
        local present = (type(judged) == "table" and type(judged.present) == "table")
            and judged.present or nil
        out.presentQty = present and #present or nil
        out.qty = (content and tonumber(content.qty)) or out.qty
        out.item = (content and type(content.snapshot) == "table" and content.snapshot.type) or out.item
        out.epoch = (evidence and evidence.epoch) or out.epoch
        out.seq = (evidence and tonumber(evidence.seq)) or out.seq
        out.verdict = Rcv.verdict(out.epoch, out.seq)
        -- Three separate facts, and the page needs them apart:
        --   mismatch   the two commit points, side by side. The reader names its own
        --              serverEpoch/serverSeq and the compared expectedEpoch/expectedSeq; the
        --              claim is only read off the player's record when the reader did not say
        --              what it compared against. Built only when there is a number to show.
        --   foreign    the line found under this operation id belongs to another account.
        --              Nothing of it is shown or used - the flag is the whole answer.
        --   duplicate  two lines of the same operation contradict each other. The record is
        --              not damaged and this is not an IO fault: the server refuses to pick
        --              one, and an administrator has to find out why there are two.
        out.foreign = foreign or nil
        -- The successor's commit point is reported on the verdict itself; the nested form is
        -- read as a fallback so neither reader shape is silently dropped.
        local serverPointEpoch = judged and judged.serverEpoch or nil
        local serverPointSeq = judged and tonumber(judged.serverSeq) or nil
        local detail = type(judged) == "table" and judged.detail or nil
        if type(detail) == "table" then
            out.duplicate = detail.duplicate == true or nil
            -- Which part of the chain the reader could not accept ("chain.order",
            -- "chain.duplicate", a replay field name). It is the only diagnosis a malformed
            -- row can offer, and the operator needs it to know where to look.
            out.proofField = (type(detail.field) == "string" and detail.field ~= "")
                and detail.field or nil
            serverPointEpoch = serverPointEpoch or detail.serverEpoch or detail.epoch
            serverPointSeq = serverPointSeq or tonumber(detail.serverSeq or detail.seq)
        elseif type(detail) == "string" then
            out.detail = detail
        end
        if judgedReason == "journal_mismatch" or foreign then
            -- A foreign line's own commit point is that other operation's data, so it is not
            -- forwarded either: this row may say "the id is not yours", never anything about
            -- what the other account did with it. Only the claim side - which is this
            -- player's own record - survives.
            local serverEpoch = (not foreign) and serverPointEpoch or nil
            local serverSeq = (not foreign) and serverPointSeq or nil
            local claimedEpoch = (type(detail) == "table" and detail.expectedEpoch)
                or (pend and pend.epoch) or nil
            local claimedSeq = tonumber((type(detail) == "table" and detail.expectedSeq)
                or (pend and pend.seq))
            if serverEpoch ~= nil or serverSeq ~= nil or claimedEpoch ~= nil or claimedSeq ~= nil then
                out.mismatch = { serverEpoch = serverEpoch, serverSeq = serverSeq,
                    claimedEpoch = claimedEpoch, claimedSeq = claimedSeq }
            end
        end
        out.previous = previous ~= nil or nil
        local snapshot = content and type(content.snapshot) == "table" and content.snapshot or nil
        local origins = evidenceOrigins(content, proof ~= nil, judged)
        for _, origin in ipairs(origins or {}) do out.nativeIds[#out.nativeIds + 1] = origin.nativeId end
        -- Two different permissions, and they must not be collapsed into one:
        --   * with a record in hand, `restorable` is what says the rebuild is allowed - the
        --     record's own commit point and retention floor decide, and a refusal here is
        --     final. An identity mismatch narrows what is possible; it never becomes an
        --     acceptance of the claim.
        --   * with no record at all, the decision is the administrator's to take in writing.
        --     A judgement that says "no evidence either way" must not also be read as "and
        --     therefore nothing may be done by hand": that combination would leave a stranded
        --     operation with no way out at all, which is the one outcome this page must never
        --     produce. Either flag opens it (`unproven` from the journal reader, `restorable`
        --     from a pre-journal judgement that carries no journal flags), and *every* one of
        --     them is an acceptance of the claim: no record, no automatic anything, and the
        --     write path demands the acknowledgement whichever flag let it through.
        --     Reading, unreadable, malformed and module-absent are none of these - they carry
        --     neither flag and can only be asked again.
        -- The retention floor is measured against the *successor's* own moment, and the one
        -- place that reports it is `detail.outAt`. A replay's `at` is the original
        -- operation's time and it survives every recovery of it, so reading the floor from
        -- there would answer a question about today with a timestamp from the first attempt.
        -- Only this one field is read: a second accepted spelling would let a judgement that
        -- filled in the other one silently pass a floor nobody measured. With a record in
        -- hand and no outAt to read, the floor cannot be checked at all, and an unprovable
        -- floor is a refusal rather than a guess.
        local evidenceAt = pend and pend.at or nil
        if proof ~= nil then
            evidenceAt = type(judged) == "table" and type(judged.detail) == "table"
                and tonumber(judged.detail.outAt) or nil
        end
        local permitted = (proof ~= nil and restorable)
            or (proof == nil and (unproven == true or restorable == true))
        -- Whatever opened it, a decision taken without a record is the player's account of
        -- events and is labelled as one - the page shows the warning, the write demands the
        -- acknowledgement, and the audit line says so.
        if proof == nil and permitted then
            out.source, out.unproven = "player_claim", true
        end
        -- The shape clause is the pre-journal guard: before the journal existed, only a
        -- legacy-shaped pending (no protocol 2 origins) was ever resolved by hand, because a
        -- modern one was always finished automatically. A judgement that names the evidence -
        -- a record in hand, or an explicit "there is none" - has already decided that
        -- question, and a protocol 2 operation the journal has no line for is exactly the
        -- stranded case this exit exists for. Only the flagless fallback still needs it.
        local judgedEvidence = proof ~= nil or (judged and judged.unproven == true)
        local actionable = permitted and judged and judged.action == "hold"
            and (judgedEvidence or pend.protocol ~= Rcv.PROTOCOL or type(pend.origins) ~= "table")
            and not M.hasOut(rec.opId)
        local restorableKind = A.RECOVERY_RESTORE_KINDS[out.kind] == true
        -- An administrative discard is the server's own closing decision. A human review may
        -- reopen it only against `previous`, the last proven record that was not a discard;
        -- with none there is nothing proven to rebuild from, so this record may be closed
        -- again and nothing may be created.
        local reviewable = judgedReason ~= "admin_discard_rolledback" or previous ~= nil
        -- An unknown moment is not a passed check: without a time to measure the floor
        -- against, this row cannot say the operation is still inside it.
        local withinFloor = evidenceAt ~= nil and not Rcv.forgotten(evidenceAt)
        -- With a record, "some of it is still here" is not a reason to refuse: the judgement
        -- already split the operation into what is present and what is eligible, and the
        -- restore below rebuilds only the eligible part. A claim has no such split, so for
        -- one of those anything still in the backpack still blocks the whole decision.
        local partialBlocked = proof == nil and present ~= nil and #present > 0
        out.actions.restore = actionable == true and reviewable and restorableKind and origins ~= nil
            and snapshot ~= nil and type(snapshot.type) == "string" and not partialBlocked
            and out.verdict == "rolledback" and withinFloor
        -- Closing and creating are two different permissions. `discardable` says the server
        -- has already decided this operation is void, so the leftover pending may always be
        -- cleared - whether or not anything could be rebuilt from it. Without this, a discard
        -- nobody can rebuild would sit in the working set forever with no way to close it,
        -- and borrowing `restorable` to open the button would be a lie to whoever reads it.
        local closable = judged ~= nil and judged.discardable == true and not M.hasOut(rec.opId)
        out.actions.discard = actionable == true or closable
        if not permitted then
            -- the state itself is the blocker, unless the record in hand explains it better
            out.blocked = (proof ~= nil and (out.verdict ~= "rolledback" or not withinFloor))
                and "legacy_outcome_unverified" or judgedReason
        elseif not actionable then out.blocked = "recovery_not_actionable"
        elseif not reviewable then out.blocked = judgedReason
        elseif not restorableKind then out.blocked = "legacy_kind_unsafe"
        elseif out.verdict ~= "rolledback" or not withinFloor then out.blocked = "legacy_outcome_unverified"
        elseif partialBlocked then out.blocked = "legacy_partial_present"
        elseif origins == nil then out.blocked = "legacy_ids_mismatch"
        elseif snapshot == nil or type(snapshot.type) ~= "string" then out.blocked = "legacy_snapshot_unavailable" end
        -- What pressing the button would actually create. The judgement brings its own
        -- preview whenever it has a record to describe - for a discard successor that preview
        -- is already `previous`, which is exactly what a review rebuilds. Without a record it
        -- is built here from the claim and marked as one.
        if out.actions.restore then
            out.preview = (proof and type(judged.preview) == "table"
                and { source = "journal", item = judged.preview.item, qty = judged.preview.qty,
                    origins = judged.preview.origins })
                or recoveryPreview(content, origins, out.source or (previous and "journal") or "player_claim")
        end
        fingerprint.pending = pend
        fingerprint.present = {}
        for _, row in ipairs(present or {}) do
            fingerprint.present[#fingerprint.present + 1] = { id = row.nativeId, item = row.fullType, stamp = row.stamp }
        end
        fingerprint.judgment = judged and { action = judged.action, reason = judged.reason, missing = judged.missing } or nil
        -- The evidence state is part of the fingerprint: a decision an administrator confirmed
        -- while the journal was still being read must not apply once the answer has arrived.
        fingerprint.proof = { state = judgedReason, proven = proof ~= nil, unproven = unproven == true,
            restorable = restorable == true, outcome = out.outcome,
            epoch = out.epoch, seq = out.seq, qty = out.qty, item = out.item }
        fingerprint.verdict, fingerprint.receipt = out.verdict, M.hasOut(rec.opId)
    else
        fingerprint.opId, fingerprint.unit = rec.opId, rec.unit
    end
    out.revision = EC.jsonEncode(fingerprint)
    return out
end

-- One walk of one account's backpack, or the reason there is none: nobody is holding it (offline
-- is a limit, not a failure) or the read itself broke. Taken once per account, so every row built
-- from it describes the same instant and no second row of that account walks again.
local function accountScan(username)
    local target = onlinePlayer(username)
    if target == nil then return nil, nil, nil, nil end
    local inv = target:getInventory()
    local scan = inv and Rcv.scanUnits(inv) or nil
    if scan == nil or scan.failed then return target, nil, nil, "read_failed" end
    local pdata = target:getModData()[EC.PLAYER_MODDATA_KEY]
    if type(pdata) ~= "table" or type(pdata.pendingOuts) ~= "table" then pdata = nil end
    return target, scan, pdata, nil
end

-- Every unresolved record of one account as the page sees it.
function A.recoveryRows(username)
    local target, scan, pdata, err = accountScan(username)
    if err ~= nil then return nil, nil, target, nil, err end
    local rows = {}
    for _, rec in ipairs(Rcv.heldRecords(username)) do
        rows[#rows + 1] = recoveryRow(username, rec, scan, pdata)
    end
    return rows, scan, target, pdata
end

-- approve: the administrator accepts, in writing, that these objects came from the old purchase
-- the row describes. Nothing is created - no item, no coin - and no engine id is touched: each
-- object is named with the same deterministic token a found letter would have given it
-- ("<mailId>#L<nativeId>"), so an older save that turns up later with the original stamp lands on
-- that very token, and on any consumption already recorded against it, instead of being washed
-- into a fresh source. The owner written into the stamp is the holder, because the letter that
-- would have named one is gone: that substitution is the administrator's decision and is exactly
-- what the audit line records. `durable` is set for the same reason - the acceptance, not an
-- epoch, is what makes the unit provable from here on.
local function approveLegacy(username, target, rows)
    local named, refused = {}, 0
    for _, row in ipairs(rows) do
        local origin = Rcv.originOf(row.item)
        if type(origin) ~= "table" or origin.gen0 ~= true or type(origin.mailId) ~= "string" then
            refused = refused + 1
        else
            local token = Rcv.gen0Token(origin.mailId, origin.nativeId)
            local byOrigin, _, originState = Rcv.consumer(origin)
            local byToken, _, tokenState = Rcv.consumer({ unit = token, owner = username,
                mailId = origin.mailId, item = origin.item })
            -- Already spent, or nobody can say whether it was: accepting on an unreadable
            -- source is how one object becomes two, so only a readable "never consumed"
            -- lets the acceptance be written.
            if byOrigin ~= nil or byToken ~= nil
                or originState == "unreadable" or tokenState == "unreadable" then
                refused = refused + 1
            else
                local ok = pcall(function()
                    row.item:getModData()[EC.PLAYER_MODDATA_KEY] = { proto = Rcv.PROTOCOL,
                        mailId = origin.mailId, unit = token, owner = username, epoch = origin.epoch,
                        seq = origin.seq, txId = origin.txId, durable = true }
                end)
                if ok then
                    named[#named + 1] = token
                    local synced, err = pcall(syncItemModData, target, row.item)
                    if not synced then EC.log("recovery approve notification failed: " .. tostring(err)) end
                else
                    refused = refused + 1
                end
            end
        end
    end
    return named, refused
end

-- restore: the confirmed remainder goes back to the owner's mailbox at no charge, through the
-- same return path the login reconcile uses. reserveOut admits it, the letter is created once
-- (its id is written onto the pending record before the receipt, so a retry reuses the very same
-- letter instead of adding a second one) and finishOut is what makes the world remember it: an
-- `proof` is the successor: the server's own last legitimate record of this operation. It is
-- what the new commit point must come after - the journal chain reads strictly increasing
-- server seq, so the bump below is taken from it and never from the older point the player's
-- save (or an earlier record) still carries. `content` is what actually comes back: normally
-- the successor itself, but a human review of an administrative discard rebuilds from
-- `previous` instead. With neither, the claim is all there is and an administrator has
-- already accepted that in writing.
local function restorePending(username, target, opId, pend, proof, content, successorSeq, judged)
    local evidence = content or proof or pend
    local snapshot = type(evidence.snapshot) == "table" and evidence.snapshot or nil
    local origins = evidenceOrigins(evidence, proof ~= nil, judged)
    local qty = origins and #origins or 0
    if origins == nil or snapshot == nil or type(snapshot.type) ~= "string" then
        return false, "legacy_snapshot_unavailable"
    end
    local admitted, admissionError = Rcv.reserveOut(username, opId)
    if not admitted then return false, admissionError or "recovery_not_actionable" end
    S.bumpSeq(successorSeq or tonumber((proof or pend).seq))
    local entry, addError = M.add(username, { kind = "return", item = snapshot.type, qty = qty,
        snapshot = snapshot, listingId = opId }, pend.returnMailId)
    if not entry then
        Rcv.releaseOut(opId)
        return false, addError or "recovery_not_actionable"
    end
    pend.returnMailId = entry.id
    Rcv.transmit(target)
    local record = Rcv.copyReplay(evidence)
    record.originalKind, record.kind, record.returnMailId = evidence.kind or pend.kind, "return", entry.id
    record.origins, record.qty, record.lotQty = origins, qty, qty
    record.protocol = Rcv.PROTOCOL
    record.epoch, record.seq = md.meta.epoch, S.nextSeq()
    local committed, commitError = Rcv.finishOut(username, opId, record, "return", entry.id)
    if not committed then
        Rcv.releaseOut(opId)
        return false, commitError or "recovery_not_actionable"
    end
    Rcv.playerData(target).pendingOuts[opId] = record
    Rcv.transmit(target)
    return true, nil, entry.id, qty
end

-- discard: the operation is declared void against the *world*, not merely deleted from one
-- player save. finishOut writes the receipt with nothing in it, so hasOut answers true from now
-- on and an older save that logs in with the same pending record finds it closed (judgePending,
-- receipt kind "discard") instead of resurrecting it at every login.
local function discardPending(username, target, opId, pend, proof, successorSeq)
    local admitted, admissionError = Rcv.reserveOut(username, opId)
    if not admitted then return false, admissionError or "recovery_not_actionable" end
    -- same chain rule as a return: the new point comes after the successor's
    S.bumpSeq(successorSeq or tonumber((proof or pend).seq))
    local record = Rcv.copyReplay(proof or pend)
    -- The record itself has to say what it is. The envelope's kind reaches the journal, but
    -- the replay inside it kept the original listing/auction/return kind, and the reader that
    -- later walks this operation's file judges the replay: a discard wearing "listing" with
    -- no origins reads as a malformed line and poisons the whole chain - the very rollback
    -- this decision exists to close would then have no reviewable successor at all. The
    -- original kind is kept beside it, because "what was discarded" is part of the record.
    record.originalKind = record.originalKind or record.kind
    record.kind = "discard"
    record.origins, record.qty, record.lotQty = {}, 0, nil
    record.protocol = Rcv.PROTOCOL
    record.epoch, record.seq = md.meta.epoch, S.nextSeq()
    local committed, commitError = Rcv.finishOut(username, opId, record, "discard", opId)
    if not committed then
        Rcv.releaseOut(opId)
        return false, commitError or "recovery_not_actionable"
    end
    Rcv.transmit(target)
    return true
end

-- Every reply of this command, refusals included, echoes the requestId *and* the account it was
-- about: the page holds one command slot per account and releases it on both, so a refusal that
-- named neither would leave it waiting.
local function recoveryRefusal(player, requestId, target, code)
    S.reply(player, "admin.recovery", { ok = false, error = code, requestId = requestId,
        username = target, perms = { read = A.canRead(player), write = A.isAdmin(player) } })
end
-- The whole reply, always rebuilt from the server's own state: rows, the page, the status block
-- and the permissions. `extra` carries whatever the decision that just ran has to say.
local function recoveryReply(player, target, requestId, page, extra)
    local rows, _, _, _, err = A.recoveryRows(target)
    if not rows then return recoveryRefusal(player, requestId, target, err or "read_failed") end
    local res = extra or {}
    res.ok = res.ok ~= false
    res.requestId, res.username = requestId, target
    res.online = onlinePlayer(target) ~= nil
    res.status = M.recoveryStatus(target)
    res.perms = { read = true, write = A.isAdmin(player) }
    local shown, pageNo, pages, total = EC.filterPage(rows, { perPage = A.RECOVERY_PER_PAGE, page = page })
    res.records, res.page, res.pages, res.total = shown, pageNo, pages, total
    S.reply(player, "admin.recovery", res)
end


-- ---------- the server-wide overview (action = 'overview') ----------
--
-- One reply that answers "who is waiting" without asking for an account first. It adds no write
-- path: a batch taken on this page is the existing list / recheck / resolve commands sent one at
-- a time, each against a revision this server recomputed. Three properties this part owns:
--
--   * it never walks the world's backpacks, and it never sorts the world's records. The accounts
--     and the summary come from ModData the server already holds (md.recovery.owners) plus what
--     the online players' own saves already carry; the accounts are ordered once, and only an
--     account that really has a row on the requested page has its own (few) keys ordered and its
--     backpack walked - once for every row of it, never once per row. An unresolved working set
--     is never dropped or capped away (R.hold), so nothing here may cost the square of it.
--   * the accounts and the summary are the whole server; the query narrows records and total
--     only. An administrator typing one name must still see how much is waiting elsewhere.
--   * offline is a limit and a broken read is a fact, and both are said out loud instead of
--     being answered with an empty page. No scan means no action - every action of a row built
--     without one is false by construction - so an offline account and an account whose backpack
--     could not be read are both listed with their known reason and nothing to press. A failed
--     read marks its own rows (readError) rather than dropping them: an account that disappears
--     from the list reads as an account with nothing left to do.

local function overviewRefusal(player, requestId, code)
    S.reply(player, "admin.recovery", { ok = false, error = code, scope = "all",
        requestId = requestId, perms = { read = A.canRead(player), write = A.isAdmin(player) } })
end

-- The overview's only filter is an account substring: trimmed, lower-cased, at most
-- RECOVERY_QUERY_CHARS bytes as the client sends them. "" is no filter at all; nil means this
-- server will not read the value as a query, which is refused instead of widened to everything.
local function recoveryQuery(v)
    if v == nil then return "" end
    if type(v) ~= "string" or #v > A.RECOVERY_QUERY_CHARS or string.find(v, "%c") then return nil end
    return string.lower((string.gsub(v, "^%s*(.-)%s*$", "%1")))
end

-- Count existing records without allocating a per-record wrapper; only page-local keys are sorted.
local function recoveryRefs()
    local accounts, index, byAccount, held = {}, {}, {}, 0
    local owners = Rcv.ready() and md.recovery.owners or {}
    for name, owner in pairs(owners) do
        if validUsername(name) and type(owner) == "table" and type(owner.held) == "table" then
            local count = 0
            for key, rec in pairs(owner.held) do
                if type(key) == "string" and type(rec) == "table" and not rec.resolvedAt then
                    count = count + 1
                end
            end
            if count > 0 then
                held = held + count
                byAccount[name] = owner.held
                index[name] = { username = name, online = false, held = count }
                accounts[#accounts + 1] = index[name]
            end
        end
    end
    return accounts, index, byAccount, held
end

-- The online side of the same question, read from the saves already in memory: how many transfers
-- each online account still has open. An offline account's pending records live in a save nobody
-- is holding, so `open` is left out instead of reported as 0 - "unknown" and "none" are different
-- answers, and the page must be able to tell which one it was given.
local function recoveryOnline(accounts, index)
    local online, open = 0, 0
    S.forEachOnline(function(p)
        local name = p:getUsername()
        if not validUsername(name) then return end
        local data = p:getModData()[EC.PLAYER_MODDATA_KEY]
        local pending = type(data) == "table" and type(data.pendingOuts) == "table"
            and EC.countKeys(data.pendingOuts) or 0
        local account = index[name]
        if account == nil then
            if pending == 0 then return end
            account = { username = name, held = 0 }
            index[name] = account
            accounts[#accounts + 1] = account
        end
        account.online, account.open = true, pending
        online, open = online + 1, open + pending
    end)
    return online, open
end

-- The whole reply. `query` is already normalised ("" = no filter) and `page` is >= 1; a page past
-- the end is answered with the last one, so the client always learns page / pages / total.
function A.recoveryOverview(player, requestId, query, page)
    local accounts, index, byAccount, held = recoveryRefs()
    local online, open = recoveryOnline(accounts, index)
    EC.sortSafe(accounts, function(a, b) return a.username < b.username end)
    local total = 0
    for _, account in ipairs(accounts) do
        if query == "" or string.find(string.lower(account.username), query, 1, true) then
            total = total + account.held
        end
    end
    local pages = math.max(1, math.ceil(total / A.RECOVERY_PER_PAGE))
    local pageNo = math.max(1, math.min(pages, page))
    local from, last = (pageNo - 1) * A.RECOVERY_PER_PAGE + 1, pageNo * A.RECOVERY_PER_PAGE
    -- The accounts are already in order, so one page is a window over their counts: an account
    -- wholly before it is counted and skipped, and the walk stops at the first one past it. The
    -- order across pages is still (username, key), because both sides of it are fixed strings.
    local records, skipped = {}, 0
    for _, account in ipairs(accounts) do
        if skipped >= last then break end
        local entries = byAccount[account.username]
        local count = account.held
        local matching = count > 0
            and (query == "" or string.find(string.lower(account.username), query, 1, true))
        if matching and skipped + count >= from then
            local keys = {}
            for key, rec in pairs(entries) do
                if type(key) == "string" and type(rec) == "table" and not rec.resolvedAt then
                    keys[#keys + 1] = key
                end
            end
            EC.sortSafe(keys, function(a, b) return a < b end)
            local target, scan, pdata, err = accountScan(account.username)
            for i = math.max(1, from - skipped), math.min(count, last - skipped) do
                local row = recoveryRow(account.username, entries[keys[i]], scan, pdata)
                row.username, row.online, row.readError = account.username, target ~= nil, err
                records[#records + 1] = row
            end
        end
        if matching then skipped = skipped + count end
    end
    local durable = S.durableStatus()
    S.reply(player, "admin.recovery", { ok = true, scope = "all", requestId = requestId,
        query = query, records = records, page = pageNo, pages = pages, total = total,
        accounts = accounts,
        summary = { accounts = #accounts, held = held, onlineAccounts = online,
            offlineAccounts = #accounts - online, open = open },
        status = { durableSource = durable.source, durableStatus = durable.status, durableSeq = durable.seq },
        perms = { read = true, write = A.isAdmin(player) } })
end


S.handlers["admin.recovery"] = function(player, args)
    args = type(args) == "table" and args or {}
    local action = type(args.action) == "string" and args.action or "list"
    local write = action == "recheck" or action == "resolve"
    local requestId = readRequestId(args)
    local target = username(args)
    local page = isFiniteInt(args.page) and args.page or 1
    -- The same role gate as every other admin command, but the refusal is this command's own so
    -- it can carry back what was asked about (gate() replies with the requestId alone): the
    -- account for a per-account call, the scope for the overview - which names no account at all,
    -- because a caller who may not read this must not learn who is waiting either.
    if not (write and A.isAdmin(player) or (not write and A.canRead(player))) then
        EC.log("admin command admin.recovery refused for " .. tostring(player:getUsername())
            .. " role=" .. A.roleName(player))
        if action == "overview" then return overviewRefusal(player, requestId, "forbidden") end
        return recoveryRefusal(player, requestId, type(target) == "string" and target or nil, "forbidden")
    end
    -- The overview asks about the whole server, so it carries no account to validate and answers
    -- with the scope instead; every other action still needs one.
    if action == "overview" then
        local query = recoveryQuery(args.query)
        if requestId == nil or page < 1 or query == nil or (args.page ~= nil and not isFiniteInt(args.page)) then
            return overviewRefusal(player, requestId, "invalid_args")
        end
        return A.recoveryOverview(player, requestId, query, page)
    end
    if requestId == nil or not validUsername(target) or page < 1
        or (action ~= "list" and action ~= "recheck" and action ~= "resolve") then
        return recoveryRefusal(player, requestId, type(target) == "string" and target or nil, "invalid_args")
    end
    if action == "list" then
        return recoveryReply(player, target, requestId, page, { ok = true })
    end
    -- A backpack cannot be walked from here when nobody is holding it, and every write below is
    -- decided from that walk. Offline is a limit, not a failure the page should retry blindly.
    local online = onlinePlayer(target)
    if online == nil then return recoveryRefusal(player, requestId, target, "player_offline") end
    if action == "recheck" then
        local ok, result, err = pcall(M.reconcile, online)
        if not ok or result == false then
            EC.log("admin recovery recheck failed for " .. target .. ": " .. tostring(ok and err or result))
            return recoveryRefusal(player, requestId, target, "read_failed")
        end
        return recoveryReply(player, target, requestId, page, { ok = true, rechecked = true })
    end
    local admin = player:getUsername()
    local key = type(args.key) == "string" and args.key ~= "" and #args.key <= A.RECOVERY_KEY_CHARS
        and not string.find(args.key, "%c") and args.key or nil
    local decision = type(args.decision) == "string" and args.decision or nil
    if key == nil or decision == nil then
        return recoveryRefusal(player, requestId, target, "invalid_args")
    end
    -- The same written-reason gate every other admin write uses (trimmed, non-blank, no control
    -- characters, REASON_MAX characters): one rule, so a two-character Chinese reason an admin
    -- typed is as valid here as it is on an adjustment.
    local reasonFailure, note = reasonError(args.note)
    if reasonFailure then
        return recoveryRefusal(player, requestId, target, "recovery_reason_required")
    end
    local held = Rcv.heldRecord(target, key)
    if held and held.resolvedAt then
        -- A resend of the decision that already closed this record is the same decision, and it
        -- must cost nothing a second time. A *different* decision on a closed record is not a
        -- duplicate and is never quietly accepted.
        if held.decision == decision then
            return recoveryReply(player, target, requestId, page, { ok = true, duplicate = true, key = key })
        end
        return recoveryRefusal(player, requestId, target, "recovery_not_actionable")
    end
    if held == nil then return recoveryRefusal(player, requestId, target, "recovery_not_actionable") end
    -- Recomputed here, from a scan taken now: the client's view of what was possible when the
    -- dialog opened is never what authorises the write.
    local rows, scan, _, pdata, scanError = A.recoveryRows(target)
    if not rows then return recoveryRefusal(player, requestId, target, scanError or "read_failed") end
    local row = nil
    for _, candidate in ipairs(rows) do
        if candidate.key == key then row = candidate; break end
    end
    if row == nil or scan == nil then return recoveryRefusal(player, requestId, target, "recovery_not_actionable") end
    -- "The journal is still being read", "the record itself says this cannot be rebuilt" and
    -- "there is nothing to do here" are different answers, and an administrator who pressed a
    -- button deserves the one that is true. A protocol 2 row always names its own blocker, so
    -- that name is what comes back instead of the generic refusal.
    if row.proofState ~= nil and row.blocked ~= nil and row.actions[decision] ~= true then
        return recoveryReply(player, target, requestId, page, { ok = false, error = row.blocked,
            key = key, source = row.source, proofState = row.proofState,
            foreign = row.foreign, duplicate = row.duplicate,
            pending = row.blocked == "journal_pending" or nil })
    end
    if row.actions[decision] ~= true then
        return recoveryRefusal(player, requestId, target, "recovery_not_actionable")
    end
    if type(args.revision) ~= "string" or args.revision ~= row.revision then
        return recoveryReply(player, target, requestId, page, { ok = false, error = "recovery_stale", key = key })
    end
    local before = row.reason .. "/" .. tostring(row.sourceState) .. "/" .. tostring(row.presentQty)
    if decision == "approve" then
        local observed = legacyRows(scan, row.mailId)
        local named, refused = approveLegacy(target, online, observed)
        if #named == 0 then
            return recoveryReply(player, target, requestId, page, { ok = false,
                error = "recovery_not_actionable", key = key, refused = refused })
        end
        Rcv.transmit(online)
        if refused == 0 then
            Rcv.resolveHold(target, key, decision)
            local done = Rcv.heldRecord(target, key)
            if done then done.decision = decision end
        end
        X.emit("recovery.adminResolved", { admin = admin, username = target, key = key,
            decision = decision, mailId = row.mailId, item = row.item, qty = #named, refused = refused })
        X.audit({ action = "recovery", admin = admin, target = target, field = key,
            before = before, after = decision .. " " .. tostring(#named) .. " unit(s): " .. table.concat(named, ","),
            reason = note, item = row.item, qty = #named })
        return recoveryReply(player, target, requestId, page,
            { ok = refused == 0, error = refused > 0 and "recovery_approve_failed" or nil,
                key = key, decision = decision, approvalToken = table.concat(named, ","), refused = refused })
    end
    if decision == "remove" then
        -- Every object is removed through the recovery core's confirmed removal: the container
        -- read afterwards is the postcondition, a call that did not throw is not. The held
        -- record is closed only when every one of them is gone - the administrator authorised
        -- this exact set, and half of it removed is not that decision carried out.
        local observed = legacyRows(scan, row.mailId, row.reason == "legacy_unit_consumed")
        local dropped, stuck, ids = 0, 0, {}
        for _, unit in ipairs(observed) do
            local origin = Rcv.originOf(unit.item)
            local consumed, unreadable = nil, false
            if origin then
                local id, _, state = Rcv.consumer(origin)
                consumed, unreadable = id, state == "unreadable"
            end
            -- Deleting on the consumed reason needs the consumption proved. A source that
            -- could not be read proves nothing, and the object stays where it is rather
            -- than being destroyed on a guess; the rollback verdict is separate evidence
            -- and stands on its own.
            local allowed = type(origin) == "table" and not unit.duplicate and removalBlock(unit) == nil
                and ((origin.gen0 == true and Rcv.verdict(origin.epoch, origin.seq) == "rolledback")
                    or (row.reason == "legacy_unit_consumed" and consumed ~= nil and not unreadable))
            if allowed and Rcv.dropRow(unit) then
                dropped = dropped + 1
                if #ids < 32 then ids[#ids + 1] = tostring(unit.nativeId) end
            else
                stuck = stuck + 1
            end
        end
        Rcv.transmit(online)
        X.emit("recovery.adminResolved", { admin = admin, username = target, key = key,
            decision = decision, mailId = row.mailId, item = row.item, qty = dropped, stuck = stuck })
        X.audit({ action = "recovery", admin = admin, target = target, field = key, before = before,
            after = decision .. " removed=" .. tostring(dropped) .. " stuck=" .. tostring(stuck)
                .. " ids=" .. table.concat(ids, ","),
            reason = note, item = row.item, qty = dropped })
        if stuck > 0 or dropped == 0 then
            -- The reason this record exists did not change - only the outcome of the last
            -- attempt did. Rewriting the reason would take the remove action off the row and
            -- strand the objects that are still there.
            Rcv.holdUpdate(target, key, row.reason, { mailId = row.mailId,
                item = row.item, sourceState = row.sourceState, kind = "legacy",
                qty = #observed, ids = table.concat(ids, ","),
                detail = "admin remove: " .. tostring(dropped) .. " removed, " .. tostring(stuck) .. " refused" })
            return recoveryReply(player, target, requestId, page, { ok = false,
                error = "recovery_remove_failed", key = key, removed = dropped, stuck = stuck })
        end
        Rcv.resolveHold(target, key, decision)
        local done = Rcv.heldRecord(target, key)
        if done then done.decision = decision end
        return recoveryReply(player, target, requestId, page,
            { ok = true, key = key, decision = decision, removed = dropped })
    end
    local pend = pdata and pdata.pendingOuts[row.opId] or nil
    if type(pend) ~= "table" then return recoveryRefusal(player, requestId, target, "recovery_not_actionable") end
    -- Judged once more from the scan taken a moment ago, with `resume` set: this is the
    -- write-gated path, so a cold read may leave its ticket and the mailbox will come back to
    -- it. The row the page was drawn from is not what authorises this write - the evidence as
    -- it stands now is, and between the two the journal read may well have finished or failed.
    local judged = Rcv.judgePending(target, row.opId, pend, scan, { resume = true })
    local judgedReason = (judged and judged.reason) or row.reason
    -- A line under this operation id that belongs to another account is counter-evidence, not
    -- absence: endorsing the claim would write a fresh receipt against an id that is
    -- demonstrably someone else's. No decision here, whatever the page sent, and no record of
    -- that account is read even if one were attached.
    local foreign = (judged ~= nil and judged.foreign == true)
        or (type(judged) == "table" and type(judged.detail) == "table"
            and judged.detail.owner == true)
    local proof = (not foreign) and judged and type(judged.replay) == "table"
        and judged.replay or nil
    local unproven = not foreign and ((judged and judged.unproven == true)
        or (judged ~= nil and proof == nil and judged.restorable == nil and judged.unproven == nil
            and A.RECOVERY_MANUAL_REASONS[judgedReason] == true))
    -- With a record in hand the record decides (restorable). With no record, either flag
    -- opens the manual exit - `unproven` from the journal reader, or `restorable` from a
    -- pre-journal judgement that carries no journal flags - and both paths land in the
    -- acknowledgement below, because a decision taken without a record is an acceptance of
    -- the claim whichever flag allowed it. A judgement that offers neither is a wait or a
    -- refusal, and it says which.
    local restorable = judgedRestorable(judged, judgedReason)
    -- Closing is its own permission: the server already ruled this operation void, so the
    -- leftover pending may be cleared even when nothing could be rebuilt from it. It never
    -- creates anything, and it is not available on any other state.
    local closable = (judged ~= nil and judged.discardable == true) and not foreign
    local permitted = not foreign
        and ((proof ~= nil and restorable)
            or (proof == nil and (unproven == true or restorable == true)))
    if not permitted and not (decision == "discard" and closable) then
        -- still reading, could not be read, or a record whose own commit point refuses the
        -- rebuild: no decision is taken, and the answer says which of those it was
        if A.RECOVERY_JOURNAL_REASONS[judgedReason] then
            return recoveryReply(player, target, requestId, page,
                { ok = false, error = judgedReason, key = key, foreign = foreign or nil,
                    pending = judgedReason == "journal_pending" or nil })
        end
        return recoveryRefusal(player, requestId, target, "recovery_not_actionable")
    end
    if proof == nil then
        -- No record of this operation exists. Handing the goods back or voiding it is still
        -- allowed, but only as a stated acceptance of the player's own account of it: the page
        -- must say so and send it, and what is written down says the source was never proven.
        if args.acceptUnproven ~= true then
            return recoveryReply(player, target, requestId, page,
                { ok = false, error = "recovery_unproven_source", key = key,
                    source = "player_claim", reason = judgedReason })
        end
    end
    -- A human review of an administrative discard rebuilds from `previous` - the last proven
    -- record that was not a discard - while the commit point, the verdict and the retention
    -- floor stay the successor's. With no previous there is nothing proven to rebuild, so a
    -- restore is refused outright and only the closing decision remains.
    local previous = nil
    if judgedReason == "admin_discard_rolledback" and type(judged) == "table" then
        if type(judged.previous) == "table" then previous = judged.previous
        elseif type(judged.detail) == "table" and type(judged.detail.previous) == "table" then
            previous = judged.detail.previous
        end
    end
    if decision == "restore" and judgedReason == "admin_discard_rolledback" and previous == nil then
        return recoveryReply(player, target, requestId, page,
            { ok = false, error = judgedReason, key = key, source = "journal" })
    end
    -- The chain reads strictly increasing server seq, so the new record must come after the
    -- successor's own commit point - the one the reader reports, not the older point a
    -- matched ancestor or the player's save still carries.
    local successorSeq = (judged and tonumber(judged.serverSeq))
        or (type(judged) == "table" and type(judged.detail) == "table"
            and tonumber(judged.detail.serverSeq))
        or tonumber((proof or pend).seq)
    local source = proof and "journal" or "player_claim"
    local ok, failure, mailId, qty
    if decision == "restore" then
        ok, failure, mailId, qty = restorePending(target, online, row.opId, pend, proof, previous,
            successorSeq, judged)
    else
        ok, failure = discardPending(target, online, row.opId, pend, proof, successorSeq)
    end
    if not ok then
        return recoveryReply(player, target, requestId, page,
            { ok = false, error = failure or "recovery_not_actionable", key = key, source = source })
    end
    Rcv.resolveHold(target, key, decision)
    local done = Rcv.heldRecord(target, key)
    if done then done.decision = decision end
    X.emit("recovery.adminResolved", { admin = admin, username = target, key = key, decision = decision,
        opId = row.opId, item = row.item, qty = qty, mailId = mailId, source = source,
        proofState = judgedReason })
    X.audit({ action = "recovery", admin = admin, target = target, field = key, before = before,
        after = decision .. " [" .. source .. "/" .. tostring(judgedReason) .. "]"
            .. (mailId and (" -> mail " .. mailId .. " x" .. tostring(qty)) or " (void)"),
        reason = note, item = row.item, qty = qty })
    return recoveryReply(player, target, requestId, page,
        { ok = true, key = key, decision = decision, mailId = mailId, qty = qty, source = source })
end

-- ---------- view invalidation notices ----------
--
-- ECExport merges, once per tick, the scopes whose data changed and calls X.onViewsChanged with
-- three sets: what every player may know, what only a read role may know, and what belongs to
-- one account. One pass over the online players turns that into at most one views.changed per
-- player carrying the scope names that player is allowed to refresh - no balances, no listings,
-- no ModData transmit. It is a hint that data changed, never a promise that the next read is
-- already on disk: that is what the read fence in W.tail is for.
local function mergeScopes(set, seen, scopes)
    if type(set) ~= "table" then return end
    for k, v in pairs(set) do
        local scope = type(k) == "string" and k or (type(v) == "string" and v or nil)
        if scope and not seen[scope] then
            seen[scope] = true
            scopes[#scopes + 1] = scope
        end
    end
end

X.onViewsChanged = function(publicScopes, adminScopes, byUsername)
    local owners = type(byUsername) == "table" and byUsername or nil
    local hasPublic = type(publicScopes) == "table" and EC.countKeys(publicScopes) > 0
    local hasAdmin = type(adminScopes) == "table" and EC.countKeys(adminScopes) > 0
    if not hasPublic and not hasAdmin and not owners then return end
    S.forEachOnline(function(p)
        local own = owners and owners[p:getUsername()] or nil
        local canRead = hasAdmin and A.canRead(p)
        if not hasPublic and own == nil and not canRead then return end
        local scopes, seen = {}, {}
        mergeScopes(publicScopes, seen, scopes)
        mergeScopes(own, seen, scopes)
        if canRead then mergeScopes(adminScopes, seen, scopes) end
        if #scopes > 0 then S.reply(p, "views.changed", { scopes = scopes }) end
    end)
end

-- ---------- server-wide money view (admin.transactions / admin.transaction) ----------
--
-- One committed transaction is one row. The only source is the tx.committed line of the daily
-- events files: the business events of the same trade (auction.bid, market.sold, ...) and the
-- per-player receipt lines describe the *same* money from another angle, so folding them in
-- would list one purchase two or three times. Nothing is recomputed into a second ledger and no
-- revenue is inferred: `amounts` is the gross movement of the postings, which includes money
-- moving between the available and reserved buckets of one wallet.
--
-- Both commands are read-gated (a read-only moderator may look, a player may not) and reply
-- through W.tail, so a broken read is error=read_failed and never an empty success.

A.TX_GROUPS = {
    all = true, shop_buy = true, shop_sell = true, market = true, auction = true,
    rewards = true, admin = true, mod = true, exchange = true, other = true,
}

-- tx.kind -> the group the panel filters on. An unmapped kind lands in "other" instead of
-- disappearing: a row whose source this build does not know is still a row of the ledger.
local function txGroup(kind)
    if kind == "shop_buy" or kind == "shop_sell" then return kind end
    if kind == "checkin" or kind == "milestone" then return "rewards" end
    if kind == "mod" then return "mod" end
    local prefix = type(kind) == "string" and string.match(kind, "^(%a+)_") or nil
    if prefix == "market" or prefix == "auction" or prefix == "admin" or prefix == "exchange" then
        return prefix
    end
    return "other"
end

-- The account-class filter accepts the shared vocabulary plus "all" (= no filter). A translated
-- label must never arrive here: the wire carries class ids only.
A.TX_ACCOUNT_CLASSES = {}
for _, c in ipairs(EC.ACCOUNT_CLASSES) do A.TX_ACCOUNT_CLASSES[c] = true end

-- A row is one whole transaction, so a class matches when *any* account it touches is of that
-- class; the other side stays in the row (hiding it would misreport where the money went).
local function txHasClass(accounts, class)
    for _, account in ipairs(accounts) do
        if EC.accountClass(account) == class then return true end
    end
    return false
end

-- The exact participant filter: byte-for-byte equality with an account the transaction actually
-- posted to. A name that only appears in the actor field or inside a reason text is not a
-- participant, and answering "transactions of this player" with those would be a lie about where
-- the money went. Case-sensitive: login names are.
local function txHasAccount(accounts, account)
    for _, name in ipairs(accounts) do
        if name == account then return true end
    end
    return false
end

-- The resolved fullType set of a multilingual item search: a bounded array of unique non-empty
-- identifiers. Returns the lookup set plus the normalised array, or nil when the client sent
-- something else (a hole, a non-string, an over-long entry, more than ITEM_TYPES_MAX of them).
-- A search whose input is not understood is refused, never silently narrowed to what parsed.
local function txItemTypes(list)
    if type(list) ~= "table" then return nil end
    local n = #list
    if n > A.ITEM_TYPES_MAX or EC.countKeys(list) ~= n then return nil end
    local set, out = {}, {}
    for i = 1, n do
        local v = list[i]
        if type(v) ~= "string" or v == "" or #v > A.ITEM_TYPE_CHARS or string.find(v, "%c") then return nil end
        if not set[v] then
            set[v] = true
            out[#out + 1] = v
        end
    end
    return set, out
end

-- Invalid event headers are read errors, not non-matching transactions.
local function txHeader(rec)
    if type(rec.type) ~= "string" then error("invalid financial event header") end
    if rec.type ~= "tx.committed" then return false end
    if type(rec.txId) ~= "string" or rec.txId == "" or not isFiniteInt(rec.ts) then
        error("invalid transaction identity or timestamp")
    end
    return true
end

-- One events line -> the summary row, or nil when the line is not a committed transaction.
-- Every field is picked by name: the raw payload (arbitrary keys from an integrating mod, meta
-- blobs) never reaches a client. No long reasonText and no postings here - 200 of those would
-- not fit one reply; admin.transaction carries them for the single row the admin opens.
local function txSummary(rec)
    if not txHeader(rec) then return nil end
    local payload = type(rec.payload) == "table" and rec.payload or {}
    local accounts, seen, amounts, count = {}, {}, {}, 0
    local postings = rec.postings
    if type(postings) ~= "table" or #postings == 0 or #postings > A.TX_POSTINGS_MAX then
        error("invalid transaction postings: " .. rec.txId)
    end
    for _, p in ipairs(postings) do
        if type(p) ~= "table" or type(p.account) ~= "string" or p.account == ""
            or type(p.currency) ~= "string" or p.currency == "" or not isAmount(p.amount)
            or (p.bucket ~= nil and p.bucket ~= "available" and p.bucket ~= "reserved") then
            error("invalid transaction posting: " .. rec.txId)
        end
        count = count + 1
        if not seen[p.account] then
            seen[p.account] = true
            accounts[#accounts + 1] = p.account
        end
        -- Sum the positive side separately for each currency, including reserve movements.
        if p.amount > 0 then amounts[p.currency] = (amounts[p.currency] or 0) + p.amount end
    end
    return {
        txId = rec.txId,
        epoch = type(rec.epoch) == "string" and rec.epoch or nil,
        seq = isFiniteInt(rec.seq) and rec.seq or nil,
        ts = rec.ts,
        kind = type(rec.kind) == "string" and rec.kind or nil,
        group = txGroup(rec.kind),
        actor = type(rec.actor) == "string" and rec.actor or nil,
        requestId = type(rec.requestId) == "string" and rec.requestId or nil,
        reasonCode = type(rec.reasonCode) == "string" and rec.reasonCode or nil,
        item = type(payload.item) == "string" and payload.item
            or (type(payload.fullType) == "string" and payload.fullType or nil),
        qty = isFiniteInt(payload.qty) and payload.qty or nil,
        sku = type(payload.sku) == "string" and payload.sku or nil,
        sourceMod = type(payload.sourceMod) == "string" and payload.sourceMod or nil,
        accounts = accounts, amounts = amounts, postingCount = count,
        rolledBack = rec.rolledBack == true,
    }
end

-- Keyword match over the identifiers an admin has in hand, field by field: `contains` is a
-- case-insensitive substring of one field, `exact` is one field whose whole value equals the
-- query (matching the concatenation of every field would make "exact" meaningless). The resolved
-- item types of a multilingual search are the other half of the same OR: a row whose fullType is
-- in that set matches the keyword even though its text fields do not carry the typed word.
local function txKeyword(rec, out, query, exact, itemTypes)
    if itemTypes and out.item and itemTypes[out.item] then return true end
    if not query then return false end
    local payload = type(rec.payload) == "table" and rec.payload or {}
    local ref = type(payload.ref) == "table" and payload.ref or {}
    local fields = {
        out.txId, textOf(out.kind), textOf(out.actor), textOf(out.requestId), textOf(out.reasonCode),
        textOf(rec.reasonText), textOf(out.item), textOf(payload.fullType), textOf(out.sku),
        textOf(out.sourceMod), textOf(ref.id), textOf(payload.auctionId), textOf(payload.listingId),
        textOf(payload.orderId), W.itemNameLower(out.item),
    }
    for _, account in ipairs(out.accounts) do fields[#fields + 1] = account end
    for i = 1, #fields do
        local v = string.lower(fields[i])
        if v ~= "" then
            if exact then
                if v == query then return true end
            elseif string.find(v, query, 1, true) then return true end
        end
    end
    return false
end

-- The summary plus what only one row can afford: the full reason text and the postings with
-- their bucket and balance chain. Named payload fields only, and no `meta` blob.
local function txDetail(rec, out)
    out.reasonText = type(rec.reasonText) == "string" and rec.reasonText or nil
    local payload = type(rec.payload) == "table" and rec.payload or {}
    local ref = type(payload.ref) == "table" and payload.ref or nil
    if ref and (type(ref.type) == "string" or type(ref.id) == "string") then
        out.ref = {
            type = type(ref.type) == "string" and ref.type or nil,
            id = type(ref.id) == "string" and ref.id or nil,
        }
    end
    out.auctionId = type(payload.auctionId) == "string" and payload.auctionId or nil
    out.listingId = type(payload.listingId) == "string" and payload.listingId or nil
    out.orderId = type(payload.orderId) == "string" and payload.orderId or nil
    local raw = rec.postings -- already validated by txSummary; never silently omit a posting
    local list = {}
    for _, p in ipairs(raw) do
        list[#list + 1] = {
            account = p.account, currency = p.currency, amount = p.amount,
            bucket = p.bucket == "reserved" and "reserved" or "available",
            availableBefore = chainOf(p.availableBefore), availableAfter = chainOf(p.availableAfter),
            reservedBefore = chainOf(p.reservedBefore), reservedAfter = chainOf(p.reservedAfter),
        }
    end
    out.postings = list
    return out
end

-- admin.transactions {query?, matchMode?, itemTypes?, account?, item?, group?, accountClass?,
-- currency?, fromMs?, toMs?, requestId?} (read gate): the newest MAX_ENTRIES *matching*
-- transactions of the window, oldest first. The filters run inside the tail projector, so the
-- 200-row bound applies to the matches: searching for one account does not lose it behind newer
-- unrelated transactions, and nothing is left for the client to filter away afterwards.
-- `account` (exact participant) and `item` (exact fullType) are conditions of their own;
-- `query` + `itemTypes` are the one fuzzy condition, `matchMode` shapes only that one.
-- `currency` narrows which transactions are listed, never which currencies a listed transaction
-- reports; `accountClass` narrows which transactions are listed, never which accounts a listed
-- transaction reports. Every criterion is echoed back (also on failure) so a late reply cannot
-- be read as the current one.
S.handlers["admin.transactions"] = function(player, args)
    -- the requestId rides along on the refusal too: a page that matches replies by id must not
    -- be left waiting when a role change turns its next query into a forbidden one
    if not gate(player, "admin.transactions", false,
        type(args) == "table" and type(args.requestId) == "string" and args.requestId or nil) then return end
    args = type(args) == "table" and args or {}
    local extra = { query = "", group = "all", accountClass = "all", matchMode = "contains",
        perms = { read = true, write = A.isAdmin(player) } }
    local function fail(code)
        local reply = { entries = {}, total = 0, truncated = false, error = code }
        for k, v in pairs(extra) do reply[k] = v end
        -- Echo every bounded scalar criterion even when a preceding criterion was rejected.
        -- Oversized/structured invalid inputs are explicitly omitted, never reflected verbatim.
        for _, key in ipairs({ "query", "group", "accountClass", "matchMode", "account", "item", "currency", "fromMs", "toMs" }) do
            local value = args[key]
            if value ~= nil then
                if (type(value) == "string" and #value <= 512) or type(value) == "boolean"
                    or (type(value) == "number" and value == value and math.abs(value) < math.huge) then
                    reply[key] = value
                else
                    reply[key], reply.criteriaIncomplete = nil, true
                end
            end
        end
        if args.itemTypes ~= nil then
            local _, list = txItemTypes(args.itemTypes)
            reply.itemTypes = list
            if not list then reply.criteriaIncomplete = true end
        end
        S.reply(player, "admin.transactions", reply)
    end

    local from, to, err = txCommon(args, extra)
    if err then return fail(err) end
    local query = nil
    if args.query ~= nil then
        if type(args.query) ~= "string" then return fail("invalid_args") end
        local trimmed = (string.gsub(args.query, "^%s*(.-)%s*$", "%1"))
        if #trimmed > A.TX_QUERY_CHARS then return fail("invalid_args") end
        extra.query = trimmed
        if trimmed ~= "" then query = string.lower(trimmed) end
    end
    if args.matchMode ~= nil then
        if args.matchMode ~= "contains" and args.matchMode ~= "exact" then return fail("invalid_args") end
        extra.matchMode = args.matchMode
    end
    local itemTypes = nil
    if args.itemTypes ~= nil then
        local set, list = txItemTypes(args.itemTypes)
        if not set then return fail("invalid_args") end
        extra.itemTypes = list
        if list[1] ~= nil then itemTypes = set end
    end
    if args.group ~= nil then
        if type(args.group) ~= "string" or not A.TX_GROUPS[args.group] then return fail("invalid_args") end
        extra.group = args.group
    end
    local accountClass = nil
    if args.accountClass ~= nil and args.accountClass ~= "all" then
        if type(args.accountClass) ~= "string" or not A.TX_ACCOUNT_CLASSES[args.accountClass] then
            return fail("invalid_args")
        end
        accountClass = args.accountClass
        extra.accountClass = args.accountClass
    end
    local currency = nil
    if args.currency ~= nil and args.currency ~= "" then
        if type(args.currency) ~= "string" or not EC.CURRENCIES[args.currency] then return fail("invalid_args") end
        currency = args.currency
        extra.currency = args.currency
    end
    -- A picked player, not a typed word: the name is compared to the accounts of the postings.
    local account = nil
    if args.account ~= nil and args.account ~= "" then
        if type(args.account) ~= "string" or #args.account > 64 or string.find(args.account, "%c") then
            return fail("invalid_args")
        end
        account = args.account
        extra.account = account
    end
    -- A picked item: the exact fullType of the row, never a display name.
    local item = nil
    if args.item ~= nil and args.item ~= "" then
        if type(args.item) ~= "string" or #args.item > A.ITEM_TYPE_CHARS or string.find(args.item, "%c") then
            return fail("invalid_args")
        end
        item = args.item
        extra.item = item
    end

    local group = extra.group
    local exact = extra.matchMode == "exact"
    W.tail(player, "admin.transactions", W.eventPaths(EC.now(), from, to), extra, function(rec)
        local out = txSummary(rec)
        if not out then return nil end
        -- the daily files are whole UTC days; the window may start and end inside one
        if out.ts < from or out.ts >= to then return nil end
        if group ~= "all" and out.group ~= group then return nil end
        if account and not txHasAccount(out.accounts, account) then return nil end
        if item and out.item ~= item then return nil end
        if accountClass and not txHasClass(out.accounts, accountClass) then return nil end
        if currency and out.amounts[currency] == nil then return nil end
        if (query or itemTypes) and not txKeyword(rec, out, query, exact, itemTypes) then return nil end
        return out
    end, true)
end

-- admin.transaction {txId, fromMs?, toMs?, requestId?} (read gate): the postings of one
-- transaction, looked up in the same window (the panel passes the range of the list it selected
-- from). At most one row: the events file holds one tx.committed per transaction, and a repeated
-- line must not double the analysis of a single trade. An unknown id is an empty entry list, not
-- an error - it is a fact about the window, not a failed read.
S.handlers["admin.transaction"] = function(player, args)
    if not gate(player, "admin.transaction", false,
        type(args) == "table" and type(args.requestId) == "string" and args.requestId or nil) then return end
    args = type(args) == "table" and args or {}
    local extra = { txId = "", perms = { read = true, write = A.isAdmin(player) } }
    local function fail(code)
        local reply = { entries = {}, total = 0, truncated = false, error = code }
        for k, v in pairs(extra) do reply[k] = v end
        S.reply(player, "admin.transaction", reply)
    end
    local from, to, err = txCommon(args, extra)
    if err then return fail(err) end
    local txId = args.txId
    if type(txId) ~= "string" or txId == "" or #txId > A.TX_ID_CHARS
        or not string.match(txId, "^[%w:%.%-_]+$") then
        return fail("invalid_args")
    end
    extra.txId = txId

    W.tail(player, "admin.transaction", W.eventPaths(EC.now(), from, to), extra, function(rec)
        if not txHeader(rec) then return nil end
        if rec.txId ~= txId then return nil end
        local out = txSummary(rec)
        if not out or out.ts < from or out.ts >= to then return nil end
        return txDetail(rec, out), true
    end, true)
end

function A.init(root)
    md = root
    md.adminDaily = md.adminDaily or {}
    -- Before per-currency caps, totals were aggregate. Charge that aggregate to each currency
    -- for the remainder of the day; upgrading must not grant a fresh administrative allowance.
    for _, t in pairs(md.adminDaily) do
        if t.v == nil then
            local server, admins = t.server, t.admins
            t.v, t.server, t.admins = A.DAILY_VERSION, {}, {}
            for _, id in ipairs(EC.CURRENCY_ORDER) do
                t.server[id] = { add = server.add, sub = server.sub }
            end
            for admin, amounts in pairs(admins) do
                local byCurrency = {}
                for _, id in ipairs(EC.CURRENCY_ORDER) do
                    byCurrency[id] = { add = amounts.add, sub = amounts.sub }
                end
                t.admins[admin] = byCurrency
            end
        end
    end
    recentAdjusts = {}
end

S.Admin = A
S.onInit(A.init)

return A
