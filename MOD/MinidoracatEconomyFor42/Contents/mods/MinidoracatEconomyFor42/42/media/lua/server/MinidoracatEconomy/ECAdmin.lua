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
--   admin.transactions {query,group,accountClass,  read   server-wide money view: one committed
--                       currency,fromMs,toMs,             transaction per row from the daily events
--                       requestId}                        files (tx.committed only, <= 62 days)
--   admin.transaction  {txId,fromMs,toMs,          read   the postings of one transaction (bucket +
--                       requestId}                        balance chain, reason text)
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
if not MinidoracatEconomy or not MinidoracatEconomy.Market then
    require "MinidoracatEconomy/ECMarket"
end
if not MinidoracatEconomy or not MinidoracatEconomy.Radio then
    require "MinidoracatEconomy/ECRadio"
end
if not MinidoracatEconomy or not MinidoracatEconomy.Exchange then
    require "MinidoracatEconomy/ECExchange"
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
if not S or not S.AUTHORITY or not L or not X or not Cfg or not R or not W or not I or not G or not T or not M or not Shop or not Codec or not Mk then
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
A.TX_QUERY_CHARS = 128            -- transactions search box (bytes, as the client sends them)
A.TX_ID_CHARS = 96
A.TX_RANGE_MAX_MS = 62 * 86400000 -- at most 62 daily events files per query
A.TX_POSTINGS_MAX = 200           -- packet bound for one transaction's postings (real ones: <= 8)

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

local function gate(player, command, write, requestId)
    local allowed = write and A.isAdmin(player) or (not write and A.canRead(player))
    if not allowed then
        EC.log("admin command " .. command .. " refused for " .. tostring(player:getUsername()) .. " role=" .. A.roleName(player))
        S.reply(player, command, { ok = false, error = "forbidden", requestId = requestId })
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
    local out = { checkin = 0, milestone = 0, mint = 0, burn = 0, buyback = 0 }
    for i = 0, days - 1 do
        local r = md.rollups and md.rollups[R.dayKey(ms - i * 86400000)]
        if r then
            out.checkin = out.checkin + (r.checkinTotal or 0)
            out.milestone = out.milestone + (r.milestoneTotal or 0)
            out.mint = out.mint + (r.mint or 0)
            out.burn = out.burn + (r.burn or 0)
            out.buyback = out.buyback + (r.buyback or 0)
        end
    end
    return out
end

-- Dashboard observability for the faucet and the drains (spec 12 stage G): every commit adds
-- what left SYSTEM_MINT and what reached SYSTEM_BURN to the day's rollup, buyback on its own
-- line. Market currency only; incremental, never a rescan of the ledger.
L.onCommitted(function(ev)
    local r = R.rollup(R.dayKey(ev.ts or EC.now()))
    for _, p in ipairs(ev.postings or {}) do
        if p.currency == R.CURRENCY then
            if p.account == "SYSTEM_MINT" and p.amount < 0 then
                r.mint = (r.mint or 0) - p.amount
                if ev.kind == "shop_sell" then r.buyback = (r.buyback or 0) - p.amount end
            elseif p.account == "SYSTEM_BURN" and p.amount > 0 then
                r.burn = (r.burn or 0) + p.amount
            end
        end
    end
end)

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

-- admin.catalog {action=list|set|reload, id?, price?, dailyCap?, enabled?, bidPrice?, buyback?,
-- buybackCap?, reason?, requestId}:
-- list = the catalog with this admin's own remaining caps (read gate); set = edit one SKU in
-- catalog.json (write gate, audited, pushed to everyone online); reload = re-read the file
-- (write gate). Every reply carries the whole catalog snapshot so the page redraws from one source.
S.handlers["admin.catalog"] = function(player, args)
    local action = type(args) == "table" and args.action or "list"
    local write = action == "set" or action == "reload"
    if not gate(player, "admin.catalog", write) then return end
    local res = { ok = true }
    if action == "set" then
        if type(args.id) ~= "string" then
            res = { ok = false, error = "invalid_args" }
        else
            local reason = type(args.reason) == "string" and args.reason ~= "" and args.reason or nil
            local ok, err = Shop.update(args.id, {
                price = args.price, dailyCap = args.dailyCap, enabled = args.enabled,
                bidPrice = args.bidPrice, buyback = args.buyback, buybackCap = args.buybackCap,
            }, player:getUsername(), reason)
            if not ok then res = { ok = false, error = err } end
            res.id = args.id
        end
    elseif action == "reload" then
        local ok, err = Shop.reload(player:getUsername())
        if not ok then res = { ok = false, error = "catalog_invalid", detail = err } end
    end
    if type(args) == "table" then res.requestId = args.requestId end
    local snap = Shop.snapshot(player:getUsername(), EC.now())
    for k, v in pairs(snap) do res[k] = v end
    res.perms = { read = true, write = A.isAdmin(player) }
    S.reply(player, "admin.catalog", res)
end

-- admin.listings {action=list|delist, listingId?, reason?, requestId} : every active listing (read
-- gate) or a forced return to the seller's mailbox (write gate, audited, allowed past the cap).
S.handlers["admin.listings"] = function(player, args)
    local delist = type(args) == "table" and args.action == "delist"
    if not gate(player, "admin.listings", delist) then return end
    local res = { ok = true }
    if delist then
        local reason = type(args.reason) == "string" and args.reason ~= "" and args.reason or nil
        local ok, err = Mk.delist(player:getUsername(), args.listingId, reason)
        if not ok then res = { ok = false, error = err } end
        res.listingId = args.listingId
    end
    if type(args) == "table" then res.requestId = args.requestId end
    local snap = Mk.browse(player:getUsername(), { page = type(args) == "table" and args.page or 1, query = type(args) == "table" and args.query or nil, sort = "time" })
    for k, v in pairs(snap) do res[k] = v end
    res.perms = { read = true, write = A.isAdmin(player) }
    S.reply(player, "admin.listings", res)
end

-- admin.auctions {action=list|cancel|history, auctionId?, reason?, query?, requestId}: every active
-- auction (read gate); cancel releases the highest bid and returns the items to the seller (write
-- gate, audited); history is the server-wide public record (read gate, ECAuction.history - same
-- reply shape as the player's auction.history, marked history=true, no active-auction snapshot).
S.handlers["admin.auctions"] = function(player, args)
    local Au = S.Auction
    local action = type(args) == "table" and args.action or "list"
    if not gate(player, "admin.auctions", action == "cancel") then return end
    if action == "history" then
        Au.history(player, args, { write = A.isAdmin(player) })
        return
    end
    local res = { ok = true }
    if action == "cancel" then
        local reason = type(args.reason) == "string" and args.reason or ""
        local ok, err = Au.adminCancel(player:getUsername(), args.auctionId, reason)
        if not ok then res = { ok = false, error = err } end
    end
    if type(args) == "table" then res.requestId = args.requestId end
    local page = Au.browse(player:getUsername(), { page = type(args) == "table" and args.page or 1, sort = "ending", query = type(args) == "table" and args.query or nil })
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
    if not gate(player, "admin.whitelist", write) then return end
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
        to = dayStart(EC.now()) + DAY_MS
    elseif from == nil then
        from = to - A.TX_RANGE_MAX_MS
        if from < 0 then from = 0 end
    end
    if from >= to or to - from > A.TX_RANGE_MAX_MS then return nil, nil, "invalid_range" end
    return from, to, nil
end

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

-- Plain case-insensitive search over the identifiers an admin has in hand, built once per line
-- and only when there is a query at all.
local function txMatches(rec, out, query)
    local payload = type(rec.payload) == "table" and rec.payload or {}
    local ref = type(payload.ref) == "table" and payload.ref or {}
    local hay = out.txId .. " " .. textOf(out.kind) .. " " .. textOf(out.actor)
        .. " " .. textOf(out.requestId) .. " " .. textOf(out.reasonCode)
        .. " " .. textOf(rec.reasonText) .. " " .. textOf(out.item) .. " " .. textOf(payload.fullType)
        .. " " .. textOf(out.sku) .. " " .. textOf(out.sourceMod) .. " " .. textOf(ref.id)
        .. " " .. textOf(payload.auctionId) .. " " .. textOf(payload.listingId)
        .. " " .. textOf(payload.orderId)
    for _, account in ipairs(out.accounts) do hay = hay .. " " .. account end
    if string.find(string.lower(hay), query, 1, true) then return true end
    return string.find(W.itemNameLower(out.item), query, 1, true) ~= nil
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

-- Shared argument validation of both commands: requestId (echoed so a late reply cannot be
-- mistaken for the current one) and the date window. `extra` is filled in place with what the
-- reply must carry back.
local function txCommon(args, extra)
    if args.requestId ~= nil then
        if type(args.requestId) ~= "string" or args.requestId == ""
            or #args.requestId > A.TX_ID_CHARS or string.find(args.requestId, "%c") then
            return nil, nil, "invalid_args"
        end
        extra.requestId = args.requestId
    end
    local from, to, err = txRange(args)
    if err then return nil, nil, err end
    extra.fromMs, extra.toMs = from, to
    return from, to, nil
end

-- admin.transactions {query?, group?, accountClass?, currency?, fromMs?, toMs?, requestId?}
-- (read gate): the newest MAX_ENTRIES *matching* transactions of the window, oldest first. The
-- filters run inside the tail projector, so the 200-row bound applies to the matches: searching
-- for one account does not lose it behind newer unrelated transactions. `currency` narrows which
-- transactions are listed, never which currencies a listed transaction reports; `accountClass`
-- narrows which transactions are listed, never which accounts a listed transaction reports.
-- Every filter is echoed back (also on failure) so a late reply cannot be read as the current one.
S.handlers["admin.transactions"] = function(player, args)
    if not gate(player, "admin.transactions", false) then return end
    args = type(args) == "table" and args or {}
    local extra = { query = "", group = "all", accountClass = "all", perms = { read = true, write = A.isAdmin(player) } }
    local function fail(code)
        local reply = { entries = {}, total = 0, truncated = false, error = code }
        for k, v in pairs(extra) do reply[k] = v end
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

    local group = extra.group
    W.tail(player, "admin.transactions", W.eventPaths(EC.now(), from, to), extra, function(rec)
        local out = txSummary(rec)
        if not out then return nil end
        -- the daily files are whole UTC days; the window may start and end inside one
        if out.ts < from or out.ts >= to then return nil end
        if group ~= "all" and out.group ~= group then return nil end
        if accountClass and not txHasClass(out.accounts, accountClass) then return nil end
        if currency and out.amounts[currency] == nil then return nil end
        if query and not txMatches(rec, out, query) then return nil end
        return out
    end, true)
end

-- admin.transaction {txId, fromMs?, toMs?, requestId?} (read gate): the postings of one
-- transaction, looked up in the same window (the panel passes the range of the list it selected
-- from). At most one row: the events file holds one tx.committed per transaction, and a repeated
-- line must not double the analysis of a single trade. An unknown id is an empty entry list, not
-- an error - it is a fact about the window, not a failed read.
S.handlers["admin.transaction"] = function(player, args)
    if not gate(player, "admin.transaction", false) then return end
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
