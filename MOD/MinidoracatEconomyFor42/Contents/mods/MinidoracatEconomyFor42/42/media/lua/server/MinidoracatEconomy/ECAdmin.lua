-- MinidoracatEconomyFor42 — admin panel v1 (server authority, spec section 19).
--
--   Gate: role *name* lists from sandbox (AdminRoles = write, ReadOnlyRoles = read), re-checked
--   on the server for every command (player:getRole():getName(), IsoPlayer.java:7562 /
--   Role.java:41). Not capabilities: moderators also hold AddItem (stage A13), and roles are
--   editable by the host, so capability sets are not a stable permission level.
--
--   admin.lookup  {username}                      read   account summary + receipt ring + rewards
--   admin.adjust  {username,currency,delta,reason, write  SYSTEM_ADJUST <-> player posting with the
--                  expectedRev,requestId,reversalOfTxId}   spec 19.3 limits (per tx / per admin day /
--                                                          server day / rate), audit + admin.adjust event
--   admin.freeze  {username,frozen,reason}        write  account-level freeze (ledger refuses new tx)
--   admin.config  {currency,field,value,reason}   write  name | enabled | exchange -> ECConfig setters
--   admin.audit   {limit}                         read   ModData audit ring, newest first
--   admin.system  {}                              read   seq/epoch, sizes, heartbeat, paths, supply,
--                                                        7/30-day issuance, top holders
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
if not MinidoracatEconomy or not MinidoracatEconomy.Wallet then
    require "MinidoracatEconomy/ECWallet"
end
if not MinidoracatEconomy or not MinidoracatEconomy.Icons then
    require "MinidoracatEconomy/ECIcons"
end
if not MinidoracatEconomy or not MinidoracatEconomy.Integration then
    require "MinidoracatEconomy/ECIntegration"
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
if not S or not S.AUTHORITY or not L or not X or not Cfg or not R or not W or not I or not G then
    return
end

EC.Admin = EC.Admin or {}
local A = EC.Admin

A.ADJUST_ACCOUNT = "SYSTEM_ADJUST"
A.RATE_PER_MINUTE = 10
A.REASON_MAX = 1000                -- one JSON line in the event / audit files; "unlimited" for a text box
A.REQUEST_ID_MAX = 64
A.TOP_HOLDERS = 5
A.DAILY_VERSION = 2               -- md.adminDaily shape: per currency add/sub buckets

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

function A.canRead(player)
    return A.isAdmin(player) or EC.roleSet(EC.sandbox("ReadOnlyRoles", "moderator"))[A.roleName(player)] == true
end

local function gate(player, command, write)
    local allowed = write and A.isAdmin(player) or (not write and A.canRead(player))
    if not allowed then
        EC.log("admin command " .. command .. " refused for " .. tostring(player:getUsername()) .. " role=" .. A.roleName(player))
        S.reply(player, command, { ok = false, error = "forbidden" })
    end
    return allowed
end

-- ---------- helpers ----------

local function onlinePlayer(username)
    local players = getOnlinePlayers()
    if not players then return nil end
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p:getUsername() == username then return p end
    end
    return nil
end

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

-- Length-prefixed actor: '<len>:<name>' is injective, so admin "a" + requestId "b:c" and admin
-- "a:b" + requestId "c" cannot produce the same ledger key.
local function requestKey(admin, requestId)
    if type(requestId) ~= "string" or requestId == "" or #requestId > A.REQUEST_ID_MAX
        or string.find(requestId, "%c") then
        return nil
    end
    return "admin:" .. tostring(#admin) .. ":" .. admin .. ":" .. requestId
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
local function rewardsView(username, ms)
    local c = md.claims[username]
    local day = R.dayKey(ms)
    local season = md.config.season
    return {
        day = day,
        claimed = c ~= nil and c.checkinDay == day,
        playedMs = (c and c.day == day) and c.playedMs or 0,
        milestones = (c and c.season == season) and c.milestones or 0,
        milestoneList = R.milestones(),
        season = season,
        nextResetMs = R.nextResetMs(ms),
    }
end

function A.lookup(admin, username, write)
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
        adminToday = dailyView(R.dayKey(ms), admin),
        maxPerTx = EC.sandbox("AdminAdjustMaxPerTx", 5000),
        -- Spec 19.2 wants season-to-date earned/spent from a `stats` table. That table does not
        -- exist in this build, and the 5-entry receipt ring is not a season total: say so instead
        -- of shipping a number the panel would present as a season figure.
        stats = nil, statsAvailable = false,
        perms = { read = true, write = write == true },
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
    if username == admin then return { ok = false, error = "self_target" } end
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
    X.emit("admin.freeze", { admin = admin, target = username, frozen = frozen, reason = reason })
    X.audit({ action = frozen and "freeze" or "unfreeze", admin = admin, target = username, reason = reason })
    W.pushState(username)
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
    }
end

local function sumRollups(days, ms)
    local out = { checkin = 0, milestone = 0 }
    for i = 0, days - 1 do
        local r = md.rollups and md.rollups[R.dayKey(ms - i * 86400000)]
        if r then
            out.checkin = out.checkin + (r.checkinTotal or 0)
            out.milestone = out.milestone + (r.milestoneTotal or 0)
        end
    end
    return out
end

-- Player-held supply, system balances and the top holders per currency (single pass over
-- wallets). `net` is the conservation sum for that currency (players + reserved + system side):
-- it must be 0, and it only is if the system accounts' reserved column is counted too.
local function supply()
    local out = {}
    for _, id in ipairs(EC.CURRENCY_ORDER) do
        out[id] = { players = 0, reserved = 0, system = 0, systemReserved = 0, accounts = 0, top = {} }
    end
    for account, byCurrency in pairs(md.wallets) do
        local system = L.isSystemAccount(account)
        for id, w in pairs(byCurrency) do
            local s = out[id]
            if s then
                if system then
                    s.system = s.system + w.available
                    s.systemReserved = s.systemReserved + w.reserved
                else
                    s.players = s.players + w.available
                    s.reserved = s.reserved + w.reserved
                    s.accounts = s.accounts + 1
                    local top = s.top
                    local total = w.available + w.reserved
                    local pos = #top + 1
                    while pos > 1 and top[pos - 1].amount < total do pos = pos - 1 end
                    if pos <= A.TOP_HOLDERS then
                        table.insert(top, pos, { account = account, amount = total })
                        if #top > A.TOP_HOLDERS then table.remove(top) end
                    end
                end
            end
        end
    end
    for _, id in ipairs(EC.CURRENCY_ORDER) do
        local s = out[id]
        s.net = s.players + s.reserved + s.system + s.systemReserved
    end
    return out
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

function A.system(write)
    local ms = EC.now()
    local accounts, frozen = 0, 0
    for account in pairs(md.wallets) do
        if not L.isSystemAccount(account) then accounts = accounts + 1 end
    end
    for _ in pairs(md.frozen) do frozen = frozen + 1 end
    local ledgerBytes, adminBytes = L.sizeEstimate(), A.sizeEstimate()
    local p = dataPaths(ms)
    return {
        ok = true,
        epoch = md.meta.epoch, seq = md.meta.seq, loadedSeq = md.meta.loadedSeq, startedAt = md.meta.startedAt,
        realmId = md.meta.realmId, version = EC.VERSION, schemaVersion = md.schemaVersion,
        sizeEstimate = ledgerBytes + adminBytes,
        sizeParts = { ledger = ledgerBytes, admin = adminBytes },
        accounts = accounts, frozen = frozen,
        -- This is the MOD's export heartbeat, not the external companion or a world-save time.
        heartbeatAt = X.lastHeartbeatMs(), heartbeatSource = "export",
        queuedLines = X.queuedLines(),
        auditCount = md.audit and md.audit.count or 0, auditMax = X.AUDIT_RING,
        paths = p, pathsResolved = p ~= nil,
        supply = supply(),
        issued = { today = sumRollups(1, ms), week = sumRollups(7, ms), month = sumRollups(30, ms) },
        perms = { read = true, write = write == true },
        sandbox = Cfg.options(),
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
    S.reply(player, "admin.lookup", A.lookup(player:getUsername(), args.username, A.isAdmin(player)))
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

S.handlers["admin.config"] = function(player, args)
    if not gate(player, "admin.config", true) then return end
    local res = A.config(player, args)
    if type(args) == "table" then res.requestId = args.requestId end
    S.reply(player, "admin.config", res)
end

S.handlers["admin.audit"] = function(player, args)
    if not gate(player, "admin.audit", false) then return end
    local limit = type(args) == "table" and args.limit or nil
    S.reply(player, "admin.audit", {
        ok = true, entries = X.auditEntries(limit), max = X.AUDIT_RING,
        perms = { read = true, write = A.isAdmin(player) },
    })
end

S.handlers["admin.system"] = function(player, args)
    if not gate(player, "admin.system", false) then return end
    S.reply(player, "admin.system", A.system(A.isAdmin(player)))
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

-- admin.players {query} (read gate): candidate usernames for the search box. Everyone online plus
-- every account the ledger knows (wallets, claims, frozen marks), case-insensitive substring match,
-- online first then alphabetical, at most PLAYERS_MAX. An empty query lists only the online
-- players: scanning and sorting thousands of dormant accounts for no filter is not worth a tick.
A.PLAYERS_MAX = 30
A.PLAYERS_SCAN_MAX = 200
S.handlers["admin.players"] = function(player, args)
    if not gate(player, "admin.players", false) then return end
    local query = type(args) == "table" and type(args.query) == "string" and args.query or ""
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
    local players = getOnlinePlayers()
    if players then
        for i = 0, players:size() - 1 do
            local p = players:get(i)
            if p then add(p:getUsername(), true) end
        end
    end
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
    S.reply(player, "admin.players", { ok = true, query = query, players = list, total = total, truncated = truncated })
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

-- admin.option {key, value | nil (= back to the sandbox file), reason?, requestId} (write gate):
-- runtime override of one sandbox option (ECConfig.setOption validates against EC.OPTIONS;
-- locked options are refused). Reply carries the whole option snapshot so the page redraws.
S.handlers["admin.option"] = function(player, args)
    if not gate(player, "admin.option", true) then return end
    local res
    if type(args) ~= "table" or type(args.key) ~= "string" then
        res = { ok = false, error = "invalid_args" }
    else
        local reason = type(args.reason) == "string" and args.reason ~= "" and args.reason or nil
        local ok, err = Cfg.setOption(args.key, args.value, player:getUsername(), reason)
        res = ok and { ok = true } or { ok = false, error = err }
        res.key = args.key
    end
    if type(args) == "table" then res.requestId = args.requestId end
    res.options = Cfg.options()
    res.currencies = Cfg.snapshot()
    S.reply(player, "admin.option", res)
end

-- admin.auditFile (read gate): the newest entries of the previous and current month's audit
-- files, each line annotated with rolledBack. The ModData audit ring forgets what a crash rolled
-- back; the files do not, so this is how an admin learns which of their actions must be redone.
S.handlers["admin.auditFile"] = function(player, args)
    if not gate(player, "admin.auditFile", false) then return end
    local ms = EC.now()
    local months = { EC.monthKey(ms - 30 * 86400000), EC.monthKey(ms) }
    if months[1] == months[2] then months = { months[2] } end
    local paths = {}
    for _, m in ipairs(months) do paths[#paths + 1] = X.ROOT .. "/audit/" .. m .. ".json" end
    W.tail(player, "admin.auditFile", paths, { months = months, perms = { read = true, write = A.isAdmin(player) } })
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
