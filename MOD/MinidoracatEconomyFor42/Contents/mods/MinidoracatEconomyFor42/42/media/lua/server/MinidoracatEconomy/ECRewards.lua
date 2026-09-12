-- MinidoracatEconomyFor42 — rewards (server authority, spec section 8.2, decisions 2026-09-06).
--
--   Daily check-in: up to CheckinDailyLimit claims per account per *server reward day* (real-world
--   clock; the day flips at RewardDayResetHour in the RewardTimezoneUTC zone, default Taiwan
--   (UTC+8) 00:00), a fixed amount each. The first claim of a day needs CheckinMinPlaytimeMinutes
--   of connected time; every further claim needs another CheckinIntervalMinutes of connected time
--   counted from the moment the previous claim was paid, so waiting does not bank up extra claims
--   and a day never carries over. No server-wide cap by default (fuse only).
--   Connected time is real time spent online on this server: it stops at logout, continues on the
--   next login of the same day, survives death / a new character (the account keeps its count),
--   and a reward-day flip only keeps the part of an interval that falls into the new day.
--   Survival milestones: once per account per season, granted automatically when the *season's*
--   current life crosses a threshold. The hours come from ECSeasons (S.Seasons.observe, a
--   server-side observation of this very session), never from the character's lifetime
--   getHoursSurvived(): a character that survived 40 days before this season started is at day 0
--   in it, and an observation the season module cannot confirm pays nothing at all.
--
-- Engine facts: OnTickEvenPaused keeps firing on an empty PauseEmpty server (IngameState.java:1317);
-- getOnlinePlayers() is the server-side player list (LuaManager.java:4437-4443).

if not MinidoracatEconomy or not MinidoracatEconomy.Config then
    require "MinidoracatEconomy/ECConfig"
end
if not MinidoracatEconomy or not MinidoracatEconomy.Seasons then
    require "MinidoracatEconomy/ECSeasons"
end
local EC = MinidoracatEconomy
local S = EC and EC.Server
local L = EC and EC.Ledger
local X = EC and EC.Export
local Se = EC and EC.Seasons
if not S or not S.AUTHORITY or not L or not X or not Se then
    return
end

EC.Rewards = EC.Rewards or {}
local R = EC.Rewards

R.TICK_MS = 60000                 -- connected-time flush / milestone scan interval
R.CURRENCY = "survivor"
R.MINT_ACCOUNT = "SYSTEM_MINT"
R.MAX_MILESTONES = 16
R.ROLLUP_VERSION = 2

local Cfg = EC.Config
local md = nil
local lastTick = 0
local sessions = {}               -- username -> { player = IsoPlayer, at = ms of the last sighting }

-- ---------- reward day ----------

-- Reward day boundary = RewardDayResetHour in the players' timezone (RewardTimezoneUTC, offset
-- hours from UTC). Deliberately not the host clock: Kahlua's os.date is fixed UTC (pitfalls.md) and a
-- dedicated host is often set to UTC, which would silently move the boundary. The day key is the
-- *local* calendar date of the reward day, so "20260907" reads as the players see it.
function R.resetShiftMs()
    local hour = EC.sandbox("RewardDayResetHour", 0)
    if hour < 0 or hour > 23 then hour = 0 end
    local tz = EC.sandbox("RewardTimezoneUTC", 8)
    if tz < -12 or tz > 14 then tz = 8 end
    local offsetMin = math.floor(tz * 60 + 0.5)   -- 5.5 -> 330; sandbox doubles carry float noise
    return (hour * 60 - offsetMin) * 60000
end

function R.dayKey(ms)
    return EC.dayKey(ms - R.resetShiftMs())
end

function R.nextResetMs(ms)
    local shift = R.resetShiftMs()
    local startOfDay = math.floor((ms - shift) / 86400000) * 86400000
    return startOfDay + 86400000 + shift
end

function R.dayStartMs(ms)
    return R.nextResetMs(ms) - 86400000
end

-- ---------- state ----------

function R.init(root)
    md = root
    md.claims = md.claims or {}
    md.rollups = md.rollups or {}
    lastTick = 0
    sessions = {}
end

-- The season every claim record and every milestone ledger key is scoped by. ECSeasons owns it
-- (md.config.season stays the canonical current id, written there and nowhere else); this file
-- only reads it, and a read taken before the season module is ready has no season rather than an
-- invented one - a made-up id would scope a milestone payment to a season that never existed.
local function seasonId()
    local id = Se.currentId()
    if type(id) ~= "string" or id == "" then return nil end
    return id
end

-- Survival failures are explicit and independent of the daily reward state.
local function progressOf(username)
    local ok, progress, err = pcall(Se.progress, username)
    if ok and type(progress) == "table" then return progress end
    local code = ok and (err or "data_unreadable") or "data_unreadable"
    EC.log("survival progress failed for " .. tostring(username) .. ": " .. tostring(ok and code or progress))
    return nil, code
end

local function observeSurvival(player, ms)
    local ok, hours, err = pcall(Se.observe, player, ms)
    if ok and (hours ~= nil or err == "not_alive") then return hours end
    local code = ok and (err or "data_unreadable") or "data_unreadable"
    EC.log("survival observation failed for " .. tostring(player:getUsername())
        .. ": " .. tostring(ok and code or hours))
    return nil, code
end

-- The claim record factory is ECSeasons': it creates the same daily fields this file has always
-- read and is the one place that keeps the record's season in step with the running one (a new
-- season starts the milestone mask over; the daily state is untouched). One implementation, so a
-- record can never be created here with a season the season module disagrees with.
local claim = Se.claim

-- Day bucket of the dashboard rollups, one row per currency (ECAdmin adds mint / burn / buyback
-- to the same rows). A pre-v2 bucket carries flat counters from the era when only survivor was
-- ever paid, so those move to byCurrency.survivor verbatim; no other currency is invented, an
-- absent row means "nothing recorded", never a zero. Such a day keeps `legacy = true` so a
-- dashboard can say "no record" for the other currencies instead of reporting a made-up 0.
local function normalise(r)
    if r.v == R.ROLLUP_VERSION and type(r.byCurrency) == "table" then return r end
    local flat = nil
    if r.checkinTotal or r.checkinCount or r.milestoneTotal or r.mint or r.burn or r.buyback then
        flat = {
            checkinTotal = r.checkinTotal or 0, checkinCount = r.checkinCount or 0,
            milestoneTotal = r.milestoneTotal or 0,
            mint = r.mint or 0, burn = r.burn or 0, buyback = r.buyback or 0,
        }
    end
    if type(r.byCurrency) ~= "table" then r.byCurrency = {} end
    if flat and not r.byCurrency[R.CURRENCY] then
        r.byCurrency[R.CURRENCY] = flat
        r.legacy = true
    end
    r.checkinTotal, r.checkinCount, r.milestoneTotal = nil, nil, nil
    r.mint, r.burn, r.buyback = nil, nil, nil
    r.v = R.ROLLUP_VERSION
    return r
end

local function rollup(day)
    local r = md.rollups[day]
    if not r then
        r = { v = R.ROLLUP_VERSION, byCurrency = {} }
        md.rollups[day] = r
        -- keep at most 60 day buckets (spec 20)
        local keys = {}
        for k in pairs(md.rollups) do keys[#keys + 1] = k end
        if #keys > 60 then
            EC.sortSafe(keys, function(a, b) return a < b end)
            for i = 1, #keys - 60 do md.rollups[keys[i]] = nil end
        end
        return r
    end
    return normalise(r)
end
R.rollup = rollup

-- Writer's row for one currency on one day (created on demand).
function R.rollupCurrency(day, currency)
    local r = rollup(day)
    local b = r.byCurrency[currency]
    if not b then
        b = { checkinTotal = 0, checkinCount = 0, milestoneTotal = 0, mint = 0, burn = 0, buyback = 0 }
        r.byCurrency[currency] = b
    end
    return b
end

-- Reader's row: nil when that day / currency recorded nothing, so a caller can tell "unknown"
-- from a real zero. Creates no bucket and no row.
function R.rollupPeek(day, currency)
    local r = md.rollups[day]
    if not r then return nil end
    return normalise(r).byCurrency[currency]
end

-- Durable proof of payment, per account: `paid[dayKey] = reward indices paid that day` for the
-- last PAID_DAYS reward days, plus `paidDay`, the newest day key ever paid (a watermark that
-- never moves backwards). The ledger's idempotency map is a bounded LRU -- it forgets -- so it
-- can never be the only evidence that a reward day was already paid: moving the reset hour or
-- the timezone back and forth would otherwise pay the same day again once the key was evicted.
R.PAID_DAYS = 4

local function prunePaid(c)
    local keys = {}
    for k in pairs(c.paid) do keys[#keys + 1] = k end
    if #keys <= R.PAID_DAYS then return end
    EC.sortSafe(keys, function(a, b) return a < b end)   -- "YYYYMMDD" sorts chronologically
    for i = 1, #keys - R.PAID_DAYS do c.paid[keys[i]] = nil end
end

local function markPaid(c, day, index)
    c.paid[day] = index
    if c.paidDay == nil or day > c.paidDay then c.paidDay = day end
    prunePaid(c)
end

-- A reward day older than this account's watermark with no record of its own: whatever it was
-- paid is outside the window, so there is no way to prove how much is left. Fail closed.
-- Safe on a record no read boundary has touched yet (read-only callers pass those), and safe
-- when the watermark exists without its table: unprovable still means blocked, never free.
function R.isBackdated(c, day)
    if c.paidDay == nil or day >= c.paidDay then return false end
    return type(c.paid) ~= "table" or c.paid[day] == nil
end

-- Reward-day bucket of one claim record plus the one-shot migration of a pre-N record. Runs at
-- every read boundary (state, check-in, tick), so nobody ever reads a stale day.
local function touchDay(username, c, day)
    local legacy = c.claimedCount == nil
    if type(c.paid) ~= "table" then
        -- Record from before the watermark existed. Whatever it can still prove about a payment
        -- is moved into the watermark *first*, before any day switch and before the legacy field
        -- is dropped, and for whichever day it names -- not only today. The first read after
        -- midnight must not be the moment the only evidence of yesterday's payment disappears:
        -- the ledger's LRU is allowed to forget it, and a revisited day would then pay again.
        c.paid = {}
        if legacy then
            if type(c.checkinDay) == "string" and c.checkinDay ~= "" then markPaid(c, c.checkinDay, 1) end
        elseif c.day ~= nil and c.claimedCount > 0 then
            markPaid(c, c.day, c.claimedCount)
        end
    end
    if c.day ~= day then
        c.day = day
        c.playedMs = 0
        c.claimedCount = c.paid[day] or 0    -- back on a day we paid: it keeps what it already got
        c.claimBasePlayedMs = 0
    end
    if legacy then
        -- A pre-N record paid at most once a day. Today's status comes from the watermark seeded
        -- above; the ledger is asked as a second witness for a record whose day mark was lost
        -- while the payment stands. Then the legacy field goes, leaving one truth behind.
        local paid = c.paid[day] ~= nil
        if not paid and L.priorResult(R.legacyRequestId(username, day)) ~= nil then
            paid = true
            markPaid(c, day, 1)
        end
        c.claimedCount = paid and (c.paid[day] or 1) or 0
        c.claimBasePlayedMs = paid and c.playedMs or 0
        c.checkinDay = nil
    end
    if c.claimBasePlayedMs == nil then c.claimBasePlayedMs = 0 end
end

-- ---------- milestones ----------

local function parseList(str, count)
    local out = {}
    for token in string.gmatch(tostring(str or ""), "[^;%s]+") do
        local n = tonumber(token)
        if n and n > 0 then out[#out + 1] = math.floor(n) end
        if #out >= count then break end
    end
    return out
end

function R.milestones()
    local days = parseList(EC.sandbox("MilestoneDays", "1;3;7;14;30"), R.MAX_MILESTONES)
    local amounts = parseList(EC.sandbox("MilestoneAmounts", "100;150;250;400;1000"), R.MAX_MILESTONES)
    local list = {}
    for i = 1, math.min(#days, #amounts) do
        list[i] = { index = i, days = days[i], amount = amounts[i] }
    end
    return list
end

local function hasBit(mask, index)
    return math.floor(mask / (2 ^ (index - 1))) % 2 == 1
end

local function setBit(mask, index)
    if hasBit(mask, index) then return mask end
    return mask + 2 ^ (index - 1)
end

function R.grantMilestones(player, ms)
    local hours = observeSurvival(player, ms)
    if type(hours) ~= "number" then return end
    local season = seasonId()
    if season == nil then return end
    local username = player:getUsername()
    local c = claim(username)
    if c == nil then return end
    local daysSurvived = hours / 24
    for _, m in ipairs(R.milestones()) do
        if daysSurvived >= m.days and not hasBit(c.milestones, m.index) then
            local res = L.credit(username, R.CURRENCY, m.amount, R.MINT_ACCOUNT, {
                kind = "milestone", reasonCode = "survival_milestone",
                requestId = "survival:" .. username .. ":" .. season .. ":" .. m.index,
                payload = { milestone = m.index, days = m.days, season = season },
            })
            if res.ok then
                c.milestones = setBit(c.milestones, m.index)
                local b = R.rollupCurrency(R.dayKey(ms), R.CURRENCY)
                b.milestoneTotal = b.milestoneTotal + m.amount
                S.reply(player, "milestone.granted", { index = m.index, days = m.days, amount = m.amount, currency = R.CURRENCY })
            elseif res.error ~= "account_frozen" then
                -- Frozen accounts simply retry next scan; anything else is worth a log line.
                EC.log("milestone " .. m.index .. " for " .. username .. " failed: " .. tostring(res.error))
            end
        end
    end
end

-- ---------- connected time + tick ----------

-- Real connected time and nothing else: what accrues is the wall-clock gap between two moments
-- the server saw *this very session* online (the tick scan of getOnlinePlayers, or one of the
-- player's own commands). The anchor is volatile (process memory) and carries the IsoPlayer
-- instance it was taken from, so a reconnect or a character change -- a different instance for
-- the same username, even within one tick -- starts a new session instead of swallowing the
-- offline gap in between. No position or AFK heuristic: being connected is what is paid for.
--
-- Deliberately conservative in one direction only: the tail between the last observation and a
-- disconnect (at most R.TICK_MS) is dropped, never guessed. Offline time is never counted.
-- Entry points are the tick, the player's own commands, `hello` and a respawn, so the guard on
-- md belongs here: nothing may touch a claim record before the ModData root is installed.
function R.observe(player, ms)
    if not md then return false, "not_ready" end
    local username = player:getUsername()
    local session = sessions[username]
    if session == nil or session.player ~= player then
        sessions[username] = { player = player, at = ms }
        return true
    end
    local anchor = session.at
    if ms <= anchor then session.at = ms; return true end
    local c, err = claim(username)
    if c == nil then
        EC.log("reward observation failed for " .. tostring(username) .. ": " .. tostring(err))
        return false, err
    end
    session.at = ms
    touchDay(username, c, R.dayKey(ms))
    -- A reward day that flipped inside the gap only gets its own part of it.
    local from = math.max(anchor, R.dayStartMs(ms))
    if ms > from then c.playedMs = c.playedMs + (ms - from) end
    return true
end

function R.onTick()
    if not md then return end
    local ms = EC.now()
    if ms - lastTick < R.TICK_MS then return end
    lastTick = ms
    local seen = {}
    S.forEachOnline(function(p)
        local username = p:getUsername()
        local ok, err = pcall(function()
            R.observe(p, ms)
            R.grantMilestones(p, ms)
        end)
        if not ok then EC.log("reward tick failed for " .. tostring(username) .. ": " .. tostring(err)) end
        seen[username] = true
    end)
    for username in pairs(sessions) do
        if not seen[username] then sessions[username] = nil end
    end
end

-- ---------- check-in ----------

function R.dailyLimit()
    local n = math.floor(tonumber(EC.sandbox("CheckinDailyLimit", 1)) or 1)
    if n < 1 then n = 1 elseif n > 24 then n = 24 end
    return n
end

function R.intervalMs()
    local n = math.floor(tonumber(EC.sandbox("CheckinIntervalMinutes", 60)) or 60)
    if n < 1 then n = 1 elseif n > 1440 then n = 1440 end
    return n * 60000
end

-- One identity per (account, reward day, reward index). The ledger refuses the second post of the
-- same one, which is what makes a resend, a revisited day key (reset hour / timezone moved) and a
-- restart idempotent. The pre-N form carried no index; it is read for migration, never written.
function R.requestId(username, day, index)
    return "checkin:" .. username .. ":" .. day .. ":" .. tostring(index)
end

function R.legacyRequestId(username, day)
    return "checkin:" .. username .. ":" .. day
end

function R.state(username, ms)
    if not md then return nil, "not_ready" end
    local c, claimErr = claim(username)
    if c == nil then return nil, claimErr end
    touchDay(username, c, R.dayKey(ms))
    local prog, survivalErr = progressOf(username)
    local day = c.day
    local limit = R.dailyLimit()
    local claimed = c.claimedCount
    local remainingClaims = math.max(0, limit - claimed)
    local intervalMs = R.intervalMs()
    local firstMs = math.max(0, EC.sandbox("CheckinMinPlaytimeMinutes", 15)) * 60000
    -- What the *next* claim needs, in today's connected time: the entry threshold for the first
    -- one, a full interval after the previous payment for every further one. Time played while a
    -- claim is already available does not shorten the interval after it.
    local requiredOnlineMs = claimed <= 0 and firstMs or (c.claimBasePlayedMs + intervalMs)
    local remainingOnlineMs = math.max(0, requiredOnlineMs - c.playedMs)
    local amount = EC.sandbox("CheckinAmount", 30)
    local cap = EC.sandbox("CheckinServerDailyCap", 0)
    local bucket = R.rollupPeek(day, R.CURRENCY)
    local paidToday = bucket and bucket.checkinTotal or 0
    local cur = Cfg and Cfg.currency and Cfg.currency(R.CURRENCY) or nil
    local blocked = nil
    if amount <= 0 then
        -- CheckinAmount 0 turns the daily reward off outright (zeroOff): no zero-value credit, no
        -- consumed index, no receipt. Survival milestones have their own amounts and keep running.
        blocked = "checkin_disabled"
    elseif R.isBackdated(c, day) then
        -- The server clock / reset hour moved the reward day back behind what this account was
        -- already paid, and that day is no longer in its own window: pay nothing rather than pay
        -- a day twice. Moving forward again restores normal service.
        blocked = "day_reverted"
    elseif cur ~= nil and cur.enabled == false then
        blocked = "currency_disabled"
    elseif L.isFrozen(username) then
        blocked = "account_frozen"
    elseif remainingClaims <= 0 then
        blocked = "daily_limit_reached"
    elseif remainingOnlineMs > 0 then
        blocked = claimed > 0 and "interval_not_elapsed" or "not_enough_playtime"
    elseif cap > 0 and paidToday + amount > cap then
        blocked = "cap_exceeded"
    elseif cur ~= nil and type(cur.balanceMax) == "number"
        and L.getBalance(username, R.CURRENCY).available + amount > cur.balanceMax then
        -- Knowable up front: the ledger would refuse this credit as balance_cap, so the page says
        -- so instead of offering a button that fails.
        blocked = "balance_cap"
    end
    return {
        day = day,
        amount = amount,
        currency = R.CURRENCY,
        claimedCount = claimed,
        dailyLimit = limit,
        remainingClaims = remainingClaims,
        playedMs = c.playedMs,
        requiredOnlineMs = requiredOnlineMs,
        remainingOnlineMs = remainingOnlineMs,
        intervalMs = intervalMs,
        canClaim = blocked == nil,
        blockedReason = blocked,
        nextResetMs = R.nextResetMs(ms),
        serverCap = cap,
        serverPaidToday = paidToday,
        milestones = c.milestones,
        milestoneList = R.milestones(),
        season = seasonId(),
        -- The season block: the number a page shows, the hours of the current life and this
        -- season's best, plus whether the server could confirm them at all. Absent means
        -- unknown - never 0, which would read as "you died just now".
        seasonNumber = prog and prog.seasonNumber or nil,
        survivalHours = prog and prog.currentHours or nil,
        bestSurvivalHours = prog and prog.bestHours or nil,
        survivalKnown = prog ~= nil and prog.known == true,
        survivalIncomplete = prog ~= nil and prog.incomplete == true,
        survivalError = survivalErr,
    }
end

-- The claim itself. `args` is mandatory and complete: the reward day and the reward index the
-- client believes is next, plus its own requestId for echoing. A missing or malformed field is
-- invalid_args -- there is no bare form, so a client can never claim without naming what it
-- thinks it is claiming. A request whose day or index does not match the server is refused as
-- stale_request instead of silently becoming the *next* index: a resend must never turn into a
-- second reward once the interval happens to have elapsed. The ledger identity stays
-- server-built (day + index); the client requestId is echoed, never trusted as the idem key.
local function doCheckin(username, ms, args)
    if type(args) ~= "table" then return { ok = false, error = "invalid_args" } end
    local wantDay, wantIndex, requestId = args.day, args.rewardIndex, args.requestId
    if type(wantDay) ~= "string" or wantDay == "" then return { ok = false, error = "invalid_args" } end
    if type(wantIndex) ~= "number" or wantIndex ~= math.floor(wantIndex) or wantIndex < 1 then
        return { ok = false, error = "invalid_args" }
    end
    if type(requestId) ~= "string" or requestId == "" or #requestId > 64 or string.find(requestId, "%c") then
        return { ok = false, error = "invalid_args" }
    end
    local st, stateErr = R.state(username, ms)
    if st == nil then return { ok = false, error = stateErr } end
    local nextIndex = st.claimedCount + 1
    if wantDay ~= st.day or wantIndex ~= nextIndex then
        return {
            ok = false, error = "stale_request", currency = st.currency, day = st.day,
            rewardIndex = nextIndex, claimedCount = st.claimedCount, dailyLimit = st.dailyLimit,
            remainingClaims = st.remainingClaims, nextResetMs = st.nextResetMs,
        }
    end
    if not st.canClaim then
        return {
            ok = false, error = st.blockedReason, currency = st.currency,
            claimedCount = st.claimedCount, dailyLimit = st.dailyLimit, remainingClaims = st.remainingClaims,
            playedMs = st.playedMs, requiredOnlineMs = st.requiredOnlineMs,
            remainingOnlineMs = st.remainingOnlineMs, nextResetMs = st.nextResetMs,
        }
    end
    local c, claimErr = claim(username)
    if c == nil then return { ok = false, error = claimErr } end
    local index = c.claimedCount + 1
    local res = L.credit(username, R.CURRENCY, st.amount, R.MINT_ACCOUNT, {
        kind = "checkin", reasonCode = "daily_checkin",
        requestId = R.requestId(username, st.day, index),
        payload = { day = st.day, rewardIndex = index },
    })
    if not res.ok then return { ok = false, error = res.error, currency = R.CURRENCY, nextResetMs = st.nextResetMs } end
    if res.duplicate then
        -- The ledger already paid this (day, index): the counter was reset under us, e.g. the day
        -- key was revisited after the reset hour / timezone moved. No money moved, so no rollup
        -- and no success; the counter only catches up so the next claim asks for the next index
        -- instead of retrying a paid one forever.
        c.claimedCount = index
        c.claimBasePlayedMs = c.playedMs
        markPaid(c, st.day, index)
        return {
            ok = false, error = "already_claimed", currency = R.CURRENCY, rewardIndex = index,
            claimedCount = index, dailyLimit = st.dailyLimit,
            remainingClaims = math.max(0, st.dailyLimit - index), nextResetMs = st.nextResetMs,
        }
    end
    c.claimedCount = index
    c.claimBasePlayedMs = c.playedMs    -- the next interval starts now; nothing banks up
    markPaid(c, st.day, index)          -- durable: never rely on the ledger's LRU alone
    local b = R.rollupCurrency(st.day, R.CURRENCY)
    b.checkinTotal = b.checkinTotal + st.amount
    b.checkinCount = b.checkinCount + 1
    return {
        ok = true, amount = st.amount, currency = R.CURRENCY, rewardIndex = index,
        claimedCount = index, dailyLimit = st.dailyLimit,
        remainingClaims = math.max(0, st.dailyLimit - index),
        balance = L.getBalance(username, R.CURRENCY).available,
        txId = res.txId, nextResetMs = st.nextResetMs,
    }
end

-- Returns { ok, ... , requestId (echo), state } -- every reply carries the state the claim left
-- behind, so a client can never act on the snapshot it sent the request with.
function R.checkin(player, args)
    local ms = EC.now()
    local username = player:getUsername()
    local observed, observeErr = R.observe(player, ms)
    local _, survivalErr = observeSurvival(player, ms)
    local result = observed == false and { ok = false, error = observeErr } or doCheckin(username, ms, args)
    if type(args) == "table" and type(args.requestId) == "string" then result.requestId = args.requestId end
    local state, stateErr = R.state(username, EC.now())
    if state and survivalErr then
        state.survivalKnown, state.survivalHours, state.bestSurvivalHours = false, nil, nil
        state.survivalError = survivalErr
    end
    result.state, result.stateError = state, stateErr
    result.day = state and state.day or nil
    return result
end

-- One player's reward snapshot, pushed now: observe first so the connected time in it is current,
-- then reply. This is the whole publish path for this page -- the player's own rewards.state, the
-- option-change fan-out, and any module that changes something the snapshot's eligibility depends
-- on (freezing an account changes canClaim, and a wallet push cannot say that). `ms` lets a
-- fan-out share one clock reading; omitted, it is taken here.
function R.pushState(player, ms)
    if not md then return end
    ms = ms or EC.now()
    local observed, observeErr = R.observe(player, ms)
    local _, survivalErr = observeSurvival(player, ms)
    local state, stateErr = R.state(player:getUsername(), ms)
    if observed == false or state == nil then
        S.reply(player, "rewards.state", { ok = false, error = observeErr or stateErr or "data_unreadable" })
        return
    end
    if survivalErr then
        state.survivalKnown, state.survivalHours, state.bestSurvivalHours = false, nil, nil
        state.survivalError = survivalErr
    end
    S.reply(player, "rewards.state", state)
end

-- A rewards option changed at runtime: refresh every online player's snapshot now instead of
-- leaving the reward page to its 30 s poll (ECPanel.prerender).
function R.pushAll()
    if not md then return end
    local ms = EC.now()
    S.forEachOnline(function(p) R.pushState(p, ms) end)
end

-- ---------- commands ----------

S.handlers["rewards.state"] = function(player, args)
    R.pushState(player, EC.now())
end

S.handlers["rewards.checkin"] = function(player, args)
    S.reply(player, "rewards.checkin", R.checkin(player, args))
end

-- Session start, so connected time counts from the moment the player is actually there instead
-- of from the first reward tick after it (up to R.TICK_MS of a real session was lost that way).
-- `hello` is the client's first command after login (ECServer handlers.hello); the wrapper keeps
-- whatever other modules already chained onto it -- ECMailbox reconciles there too. The season
-- is told as well: `hello` is a real command from a player who is actually in the online list,
-- which is the only kind of sighting survival time may be observed from.
local prevHello = S.handlers.hello
S.handlers.hello = function(player, args)
    local ms = EC.now()
    if prevHello then prevHello(player, args) end
    local ok, err = pcall(R.observe, player, ms)
    if not ok then EC.log("reward session start failed for " .. tostring(player:getUsername()) .. ": " .. tostring(err)) end
    observeSurvival(player, ms)
end

-- A respawn / new character is a new IsoPlayer instance for the same account: start its session
-- here rather than letting the next tick do it, and let R.observe's identity check drop the old
-- anchor so the time between the two instances is never counted as connected. Nothing about the
-- season happens here - OnNewGame also fires for an orphan instance that never joined the online
-- list (see ECSeasons), so it proves nothing about a life starting and must not reset anything.
function R.onNewGame(player)
    if not md then return end
    local ok, err = pcall(R.observe, player, EC.now())
    if not ok then EC.log("reward session restart failed: " .. tostring(err)) end
end

S.Rewards = R
S.onInit(R.init)
Events.OnTickEvenPaused.Add(R.onTick)
Events.OnNewGame.Add(R.onNewGame)

return R
