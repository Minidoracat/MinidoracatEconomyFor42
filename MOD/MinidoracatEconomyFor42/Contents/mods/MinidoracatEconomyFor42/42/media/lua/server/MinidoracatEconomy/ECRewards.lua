-- MinidoracatEconomyFor42 — rewards (server authority, spec section 8.2, decisions 2026-09-06).
--
--   Daily check-in: once per account per *server reward day* (real-world clock; the day flips at
--   RewardDayResetHour in the RewardTimezoneUTC zone, default Taiwan (UTC+8) 00:00),
--   fixed amount, after a minimum of effective connected time; no server-wide cap by
--   default (fuse only). Survival milestones: once per account per season, granted automatically
--   when IsoPlayer.getHoursSurvived() (server-side, IsoPlayer.java:7837-7839) crosses a threshold.
--   hoursSurvived restarts with every new character (stage A20); the claim record does not.
--
-- Engine facts: OnTickEvenPaused keeps firing on an empty PauseEmpty server (IngameState.java:1317);
-- getOnlinePlayers() is the server-side player list (LuaManager.java:4437-4443).

if not MinidoracatEconomy or not MinidoracatEconomy.Config then
    require "MinidoracatEconomy/ECConfig"
end
local EC = MinidoracatEconomy
local S = EC and EC.Server
local L = EC and EC.Ledger
local X = EC and EC.Export
if not S or not S.AUTHORITY or not L or not X then
    return
end

EC.Rewards = EC.Rewards or {}
local R = EC.Rewards

R.TICK_MS = 60000                 -- playtime accrual / milestone scan interval
R.CURRENCY = "survivor"
R.MINT_ACCOUNT = "SYSTEM_MINT"
R.MAX_MILESTONES = 16

local md = nil
local lastTick = 0
local lastPos = {}                -- username -> { x, y, ms }  (AFK heuristic)

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

-- ---------- state ----------

function R.init(root)
    md = root
    md.claims = md.claims or {}
    md.rollups = md.rollups or {}
    md.config.season = md.config.season or "1"
    lastTick = 0
    lastPos = {}
end

local function claim(username)
    local c = md.claims[username]
    if not c then
        c = { day = nil, playedMs = 0, checkinDay = nil, milestones = 0, season = md.config.season }
        md.claims[username] = c
    end
    if c.season ~= md.config.season then
        -- New season: milestones start over, daily state is untouched.
        c.season = md.config.season
        c.milestones = 0
    end
    return c
end

local function rollup(day)
    local r = md.rollups[day]
    if not r then
        r = { checkinTotal = 0, checkinCount = 0, milestoneTotal = 0 }
        md.rollups[day] = r
        -- keep at most 60 day buckets (spec 20)
        local keys = {}
        for k in pairs(md.rollups) do keys[#keys + 1] = k end
        if #keys > 60 then
            EC.sortSafe(keys, function(a, b) return a < b end)
            for i = 1, #keys - 60 do md.rollups[keys[i]] = nil end
        end
    end
    return r
end

local function touchDay(c, day)
    if c.day ~= day then
        c.day = day
        c.playedMs = 0
    end
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
    local username = player:getUsername()
    local c = claim(username)
    local hours = player:getHoursSurvived()
    if type(hours) ~= "number" then return end
    local daysSurvived = hours / 24
    for _, m in ipairs(R.milestones()) do
        if daysSurvived >= m.days and not hasBit(c.milestones, m.index) then
            local res = L.credit(username, R.CURRENCY, m.amount, R.MINT_ACCOUNT, {
                kind = "milestone", reasonCode = "survival_milestone",
                requestId = "survival:" .. username .. ":" .. md.config.season .. ":" .. m.index,
                payload = { milestone = m.index, days = m.days, season = md.config.season },
            })
            if res.ok then
                c.milestones = setBit(c.milestones, m.index)
                local r = rollup(R.dayKey(ms))
                r.milestoneTotal = r.milestoneTotal + m.amount
                S.reply(player, "milestone.granted", { index = m.index, days = m.days, amount = m.amount, currency = R.CURRENCY })
            elseif res.error ~= "account_frozen" then
                -- Frozen accounts simply retry next scan; anything else is worth a log line.
                EC.log("milestone " .. m.index .. " for " .. username .. " failed: " .. tostring(res.error))
            end
        end
    end
end

-- ---------- playtime + tick ----------

-- ponytail: AFK heuristic is "position unchanged for the whole interval"; upgrade to input-based
-- detection if players park at a terminal to farm check-ins.
local function accruePlaytime(player, ms)
    local username = player:getUsername()
    local c = claim(username)
    touchDay(c, R.dayKey(ms))
    local x, y = math.floor(player:getX()), math.floor(player:getY())
    local prev = lastPos[username]
    lastPos[username] = { x = x, y = y, ms = ms }
    if not prev then return end                     -- first sample this process: nothing to add yet
    local moved = prev.x ~= x or prev.y ~= y
    if moved then
        c.playedMs = c.playedMs + math.min(ms - prev.ms, R.TICK_MS * 2)
    end
end

function R.onTick()
    if not md then return end
    local ms = EC.now()
    if ms - lastTick < R.TICK_MS then return end
    lastTick = ms
    local seen = {}
    S.forEachOnline(function(p)
        do
            local ok, err = pcall(function()
                accruePlaytime(p, ms)
                R.grantMilestones(p, ms)
            end)
            if not ok then EC.log("reward tick failed for " .. tostring(p:getUsername()) .. ": " .. tostring(err)) end
            seen[p:getUsername()] = true
        end
    end)
    for username in pairs(lastPos) do
        if not seen[username] then lastPos[username] = nil end
    end
end

-- ---------- check-in ----------

function R.state(username, ms)
    local c = claim(username)
    local day = R.dayKey(ms)
    touchDay(c, day)
    local minMs = EC.sandbox("CheckinMinPlaytimeMinutes", 15) * 60000
    local cap = EC.sandbox("CheckinServerDailyCap", 0)
    local r = md.rollups[day]
    return {
        day = day,
        amount = EC.sandbox("CheckinAmount", 30),
        currency = R.CURRENCY,
        claimed = c.checkinDay == day,
        playedMs = c.playedMs,
        minPlaytimeMs = minMs,
        nextResetMs = R.nextResetMs(ms),
        serverCap = cap,
        serverPaidToday = r and r.checkinTotal or 0,
        milestones = c.milestones,
        milestoneList = R.milestones(),
        season = md.config.season,
    }
end

-- Returns { ok = true, amount, balance } or { ok = false, error, ... }.
function R.checkin(player)
    local ms = EC.now()
    local username = player:getUsername()
    local st = R.state(username, ms)
    if st.claimed then return { ok = false, error = "already_claimed", nextResetMs = st.nextResetMs } end
    if st.playedMs < st.minPlaytimeMs then
        return { ok = false, error = "not_enough_playtime", playedMs = st.playedMs, minPlaytimeMs = st.minPlaytimeMs }
    end
    if st.serverCap > 0 and st.serverPaidToday + st.amount > st.serverCap then
        return { ok = false, error = "cap_exceeded", nextResetMs = st.nextResetMs }
    end
    local res = L.credit(username, R.CURRENCY, st.amount, R.MINT_ACCOUNT, {
        kind = "checkin", reasonCode = "daily_checkin",
        requestId = "checkin:" .. username .. ":" .. st.day,
        payload = { day = st.day },
    })
    if not res.ok then return { ok = false, error = res.error } end
    local c = claim(username)
    if res.duplicate then
        -- The ledger already paid this reward day (idempotency hit: the claim record lost the day,
        -- e.g. the day key revisited after the reset hour/timezone changed). No money moved, so no
        -- rollup, no success reply — just restore the claim mark.
        c.checkinDay = st.day
        return { ok = false, error = "already_claimed", nextResetMs = st.nextResetMs }
    end
    c.checkinDay = st.day
    local r = rollup(st.day)
    r.checkinTotal = r.checkinTotal + st.amount
    r.checkinCount = r.checkinCount + 1
    return { ok = true, amount = st.amount, currency = R.CURRENCY, balance = L.getBalance(username, R.CURRENCY).available, txId = res.txId, nextResetMs = st.nextResetMs }
end

-- A rewards option changed at runtime: refresh every online player's snapshot now instead of
-- leaving the reward page to its 30 s poll (ECPanel.prerender).
function R.pushAll()
    if not md then return end
    local ms = EC.now()
    S.forEachOnline(function(p) S.reply(p, "rewards.state", R.state(p:getUsername(), ms)) end)
end

-- ---------- commands ----------

S.handlers["rewards.state"] = function(player, args)
    S.reply(player, "rewards.state", R.state(player:getUsername(), EC.now()))
end

S.handlers["rewards.checkin"] = function(player, args)
    local result = R.checkin(player)
    S.reply(player, "rewards.checkin", result)
end

S.Rewards = R
S.onInit(R.init)
Events.OnTickEvenPaused.Add(R.onTick)

return R
