-- MinidoracatEconomyFor42 - real-time seasons and server-observed single-life survival.
-- Season deadlines use wall-clock milliseconds; survival uses server game hours.
-- getHoursSurvived is loaded/saved by the dedicated server (GameServer.java:2778,
-- ServerPlayerDB.java:348-362). Player modData and OnNewGame's orphan are not evidence.
require "MinidoracatEconomy/ECConfig"
local EC = MinidoracatEconomy
local S, X = EC.Server, EC.Export
if not S or not S.AUTHORITY or not X then return end

EC.Seasons = EC.Seasons or {}
local Se = EC.Seasons
local DAY_MS = 86400000
local md, data
local initError
local seen = {} -- username -> slot -> live IsoPlayer; never serialized
local lastCheck, lastPrune = 0, 0
local rotate

local function finite(n)
    return type(n) == "number" and n == n and n > -math.huge and n < math.huge
end

local function whole(n, minimum, maximum)
    return finite(n) and n >= minimum and n <= maximum and n == math.floor(n)
end

local function validId(id)
    return type(id) == "string" and #id <= 64 and EC.parseId(id) ~= nil
end

local function validMeta(meta, closed)
    if type(meta) ~= "table" or not validId(meta.id) or not whole(meta.number, 1, 1000000000)
        or not finite(meta.startedAt) or not whole(meta.durationDays, 0, 3650)
        or type(meta.partial) ~= "boolean" or not whole(meta.participants, 0, 1000000000) then return false end
    if meta.durationDays == 0 then
        if meta.endsAt ~= nil then return false end
    elseif meta.endsAt ~= meta.startedAt + meta.durationDays * DAY_MS then
        return false
    end
    if closed then return finite(meta.endedAt) and meta.endedAt >= meta.startedAt end
    return meta.endedAt == nil
end

local function current()
    if initError ~= nil then return nil, initError end
    if md == nil or data == nil then return nil, "not_ready" end
    if type(data) ~= "table" then return nil, "data_unreadable" end
    local c = data.current
    if data.version ~= 1 or type(data.history) ~= "table" or not validMeta(c, false)
        or md.config.season ~= c.id or type(md.claims) ~= "table" then return nil, "data_unreadable" end
    return c
end

local function configuredDays()
    local days = EC.sandbox("SeasonDays", 0)
    if not whole(days, 0, 3650) then return nil, "data_unreadable" end
    return days
end

local function metaView(meta)
    return { id = meta.id, number = meta.number, startedAt = meta.startedAt, endsAt = meta.endsAt,
        endedAt = meta.endedAt, durationDays = meta.durationDays, partial = meta.partial,
        participants = meta.participants }
end

local function resetClaim(c, id, preserveMilestones)
    c.season = id
    c.survivalBase, c.survivalBest, c.survivalLife = {}, 0, nil
    if not preserveMilestones then c.milestones = 0 end
end

local function validSurvival(c)
    if type(c) ~= "table" or type(c.survivalBase) ~= "table"
        or not finite(c.survivalBest) or c.survivalBest < 0
        or (c.survivalLife ~= nil and (not finite(c.survivalLife) or c.survivalLife < 0)) then return false end
    if c.survivalLife == nil and (c.survivalBest ~= 0 or EC.countKeys(c.survivalBase) ~= 0) then return false end
    for slot, base in pairs(c.survivalBase) do
        if (slot ~= "0" and slot ~= "1" and slot ~= "2" and slot ~= "3") or not finite(base) or base < 0 then
            return false
        end
    end
    return true
end

-- The reward claim factory has one owner. Daily reward state is never reset by a season change.
function Se.claim(username)
    if not md then return nil, initError or "not_ready" end
    if type(md.claims) ~= "table" then return nil, "data_unreadable" end
    if type(username) ~= "string" or username == "" then return nil, "invalid_args" end
    local c = md.claims[username]
    if c == nil then
        c = { day = nil, playedMs = 0, claimedCount = 0, claimBasePlayedMs = 0,
            paid = {}, paidDay = nil, milestones = 0 }
        c.season = nil
        md.claims[username] = c
    elseif type(c) ~= "table" then
        return nil, "data_unreadable"
    end
    local season = current()
    if season and c.season ~= season.id then resetClaim(c, season.id, false) end
    -- A broken survival section is reported by progress/observe, not allowed to break daily claims.
    return c
end

function Se.currentId()
    local season = current()
    return season and season.id or nil
end

function Se.state()
    local season, err = current()
    if not season then return nil, err end
    local days, daysErr = configuredDays()
    if days == nil then return nil, daysErr end
    local out = { metaView(season) }
    for id, old in pairs(data.history) do
        if not validMeta(old, true) or old.id ~= id then return nil, "data_unreadable" end
        out[#out + 1] = metaView(old)
    end
    EC.sortSafe(out, function(a, b) return a.number > b.number end)
    return { currentId = season.id, configuredDays = days, seasons = out }
end

function Se.progress(username)
    local season, err = current()
    if not season then return nil, err end
    local result = { seasonId = season.id, seasonNumber = season.number, known = false,
        incomplete = season.partial }
    local c = md.claims[username]
    if c == nil then return result end
    if type(c) ~= "table" then return nil, "data_unreadable" end
    if c.season ~= season.id then return result end
    if not validSurvival(c) then return nil, "data_unreadable" end
    if c.survivalLife ~= nil then
        result.currentHours, result.bestHours, result.known = c.survivalLife, c.survivalBest, true
    end
    return result
end

-- A fresh map protects the recorded bests from readers. Closed seasons are never re-observed.
function Se.records(selector)
    local season, err = current()
    if not season then return nil, nil, err end
    local target = selector == "current" and season or data.history[selector]
    if selector == season.id then target = season end
    if target == nil then return nil, nil, "unknown_season" end
    local records = {}
    if target == season then
        for username, c in pairs(md.claims) do
            if type(c) ~= "table" then return nil, nil, "data_unreadable" end
            if c.season == season.id then
                if not validSurvival(c) then return nil, nil, "data_unreadable" end
                if c.survivalLife ~= nil then records[username] = math.floor(c.survivalBest * 60) end
            end
        end
    else
        if not validMeta(target, true) or target.id ~= selector or type(target.best) ~= "table" then
            return nil, nil, "data_unreadable"
        end
        for username, minutes in pairs(target.best) do
            if type(username) ~= "string" or not whole(minutes, 0, 1000000000000) then
                return nil, nil, "data_unreadable"
            end
            records[username] = minutes
        end
    end
    if EC.countKeys(records) ~= target.participants then return nil, nil, "data_unreadable" end
    return records, metaView(target)
end

local function readPlayer(player)
    return player:getUsername(), player:getPlayerNum(), player:isDead(), player:getHoursSurvived()
end

local function observe(player, fromDeath)
    local ok, username, slot, dead, hours = pcall(readPlayer, player)
    if not ok or type(username) ~= "string" or username == "" or not whole(slot, 0, 3)
        or type(dead) ~= "boolean" or not finite(hours) or hours < 0 then return nil, "data_unreadable" end
    if dead and not fromDeath then return nil, "not_alive" end
    local key = tostring(slot)
    local slots = seen[username]
    if fromDeath and (not dead or not slots or slots[key] ~= player) then return nil, "not_alive" end
    local c, err = Se.claim(username)
    if not c then return nil, err end
    if not validSurvival(c) then return nil, "data_unreadable" end
    if c.survivalLife == nil then
        local records, _, recordsErr = Se.records("current")
        if not records then return nil, recordsErr end
    end
    local base = c.survivalBase[key]
    -- Do not mistake an older players.db snapshot for a new character and clear the base to 0.
    -- A slot identifies a server-owned DB row, not an untrusted descriptor or character stamp.
    if base == nil or not slots or slots[key] ~= player then
        base = math.min(base or hours, hours)
        c.survivalBase[key] = base
    end
    local life = math.max(0, hours - base)
    if c.survivalLife == nil then data.current.participants = data.current.participants + 1 end
    c.survivalLife = life
    c.survivalBest = math.max(c.survivalBest, life)
    if not slots then slots = {}; seen[username] = slots end
    if fromDeath then slots[key] = nil else slots[key] = player end
    return life, c.survivalBest
end

local function ensureDeadline(ms)
    local season, err = current()
    if not season then return false, err end
    if season.endsAt ~= nil and ms >= season.endsAt then return rotate("auto", nil, nil, nil, ms) end
    return true
end

-- Call only for a live server player (tick, hello or its own command), never an OnNewGame orphan.
function Se.observe(player, ms)
    ms = ms or EC.now()
    if not finite(ms) then return nil, "data_unreadable" end
    local ok, err = ensureDeadline(ms)
    if not ok then return nil, err end
    return observe(player, false)
end

local function reanchor(player)
    local life, err = observe(player, false)
    if life ~= nil or err == "not_alive" then return true end
    return false, err
end

local function publish(old, season, cause, actor, reason)
    local failed = season.publicationFailed == true
    local function attempt(step, fn, ...)
        local ok, err = pcall(fn, ...)
        if not ok then
            failed = true
            EC.log("season " .. season.id .. " " .. step .. " failed after the season changed: " .. tostring(err))
        end
    end
    -- `old` is the season this one replaced. Without it nothing started: the same season is
    -- still running with a new deadline, so no season.started event and no rotation audit line
    -- (the option write that caused it is audited by ECConfig).
    if old then
        attempt("event", X.emit, "season.started", { season = season.id, seasonNumber = season.number,
            previousSeason = old.id, startedAt = season.startedAt, endsAt = season.endsAt,
            cause = cause, actor = actor, reason = reason })
        attempt("audit", X.audit, { action = "season", target = season.id, field = "season",
            before = old.number, after = season.number, admin = actor or "SYSTEM", reason = reason })
    end
    local state, stateErr = Se.state()
    if state then
        local args = { seasonState = state, warning = failed and "publication_failed" or nil }
        S.forEachOnline(function(p) attempt("notification", S.reply, p, "seasons.changed", args) end)
    else
        failed = true
        EC.log("season " .. season.id .. " state publication failed: " .. tostring(stateErr))
    end
    if S.Rewards then
        S.forEachOnline(function(p) attempt("rewards", S.Rewards.pushState, p) end)
    end
    season.publicationFailed = failed or nil
    return failed and "publication_failed" or nil
end

-- The running season follows the SeasonDays option: its deadline is recomputed from its own
-- start, so the id, the number, the start, the claimed milestones and every recorded best stay
-- exactly as they are and no season is opened or closed here. Called by ECConfig.setOption after
-- the override is stored and before the change is announced, so the state pushed out already
-- carries the length just written. Returns ok, error, warning like a rotation does.
function Se.applyDuration()
    local season, err = current()
    if not season then return false, err end
    local days, daysErr = configuredDays()
    if days == nil then return false, daysErr end
    local endsAt = nil
    if days > 0 then endsAt = season.startedAt + days * DAY_MS end
    local state, stateErr = Se.state()
    if state == nil then return false, stateErr end
    -- Nothing to announce twice: the same effective length leaves the metadata untouched.
    if season.durationDays == days and season.endsAt == endsAt then return true end
    local ms = EC.now()
    if not finite(ms) then return false, "data_unreadable" end
    -- A deadline that has already been reached belongs to the rotation that is due, not to an
    -- option write: a season is never shortened into the past, and one whose own deadline has
    -- passed is never handed more time instead of being closed.
    if (endsAt ~= nil and ms >= endsAt) or (season.endsAt ~= nil and ms >= season.endsAt) then
        return false, "season_duration_elapsed"
    end
    season.durationDays, season.endsAt = days, endsAt
    return true, nil, publish(nil, season)
end

rotate = function(cause, actor, reason, requestId, ms)
    local old, err = current()
    if not old then return false, err end
    local state, stateErr = Se.state()
    if not state then return false, stateErr end
    if ms < old.startedAt then return false, "invalid_args" end
    local days, daysErr = configuredDays()
    if days == nil then return false, daysErr end
    -- A manual close may flush its live tail. An overdue close must not attribute time after
    -- the fixed deadline to the old season, so it archives only previously confirmed samples.
    if cause == "manual" then
        local sampleErr
        S.forEachOnline(function(p)
            local hours, err = observe(p, false)
            if hours == nil and err ~= "not_alive" then sampleErr = err; return true end
        end)
        if sampleErr then
            EC.log("season close refused because a live sample failed: " .. tostring(sampleErr))
            return false, sampleErr
        end
    end
    local best, _, recordErr = Se.records("current")
    if not best then return false, recordErr end
    if data.history[old.id] ~= nil then return false, "data_unreadable" end
    local season = { id = S.newId(), number = old.number + 1, startedAt = ms, durationDays = days,
        endsAt = days > 0 and (ms + days * DAY_MS) or nil, partial = false, participants = 0,
        previousId = old.id, requestId = requestId, actor = actor, reason = reason }
    local archive = {}
    for key, value in pairs(old) do archive[key] = value end
    archive.endedAt, archive.best = ms, best
    data.history[old.id] = archive
    data.current = season
    md.config.season = season.id
    seen = {}
    S.forEachOnline(function(p)
        local ok, anchorErr = reanchor(p)
        if not ok then
            season.partial, season.publicationFailed = true, true
            EC.log("season " .. season.id .. " re-anchor failed: " .. tostring(anchorErr))
        end
    end)
    return true, nil, publish(old, season, cause, actor, reason)
end

local function sameRequest(season, actor, requestId)
    return season.actor == actor and season.requestId == requestId
end

function Se.start(expectedSeason, requestId, actor, reason, ms)
    local season, err = current()
    if not season then return { ok = false, error = err } end
    local state, stateErr = Se.state()
    if not state then return { ok = false, error = stateErr } end
    if not validId(expectedSeason) or type(requestId) ~= "string" or requestId == "" or #requestId > 96
        or string.find(requestId, "%c") or type(actor) ~= "string" or actor == ""
        or type(reason) ~= "string" or #reason > 3000 or not string.find(reason, "%S") then
        return { ok = false, error = "invalid_args", seasonState = state }
    end
    -- Rotation has no money posting. Its own persisted metadata remembers the request rather
    -- than consuming the ledger's bounded idempotency ring.
    local prior = sameRequest(season, actor, requestId) and season or nil
    for _, old in pairs(data.history) do
        if type(old) ~= "table" then return { ok = false, error = "data_unreadable" } end
        if sameRequest(old, actor, requestId) then prior = old end
    end
    if prior then
        if prior.previousId ~= expectedSeason or prior.reason ~= reason then
            return { ok = false, error = "request_conflict", seasonState = state }
        end
        return { ok = true, duplicate = true, seasonState = state,
            warning = prior.publicationFailed and "publication_failed" or nil }
    end
    ms = ms or EC.now()
    if not finite(ms) then return { ok = false, error = "invalid_args" } end
    local ready, deadlineErr = ensureDeadline(ms)
    if not ready then return { ok = false, error = deadlineErr, seasonState = Se.state() } end
    if expectedSeason ~= Se.currentId() then
        return { ok = false, error = "season_changed", seasonState = Se.state() }
    end
    local ok, rotateErr, warning = rotate("manual", actor, reason, requestId, ms)
    return { ok = ok, error = rotateErr, duplicate = false, seasonState = Se.state(), warning = warning }
end

local function onDeath(character)
    if not instanceof(character, "IsoPlayer") then return end
    -- Only the tracked instance gets one final sample, and never after its season's deadline.
    local ok, username, slot = pcall(readPlayer, character)
    if not ok or not whole(slot, 0, 3) then return end
    local slots = seen[username]
    if not slots or slots[tostring(slot)] ~= character then return end
    local ms = EC.now()
    if not finite(ms) or not ensureDeadline(ms) then return end
    observe(character, true)
end

function Se.onTick()
    local ms = EC.now()
    if not finite(ms) then return end
    if ms >= lastCheck and ms - lastCheck < 1000 then return end
    lastCheck = ms
    local ok, err = ensureDeadline(ms)
    if not ok then EC.log("season clock failed: " .. tostring(err)); return end
    if ms < lastPrune or ms - lastPrune >= 60000 then
        lastPrune = ms
        local online = {}
        S.forEachOnline(function(p) online[p] = true end)
        for username, slots in pairs(seen) do
            local keep = false
            for slot, player in pairs(slots) do
                if not online[player] then slots[slot] = nil else keep = true end
            end
            if not keep then seen[username] = nil end
        end
    end
end

function Se.init(root)
    initError = "data_unreadable"
    md, data = nil, nil
    seen, lastCheck, lastPrune = {}, 0, 0
    if type(root.config) ~= "table" then error("season config unavailable") end
    if root.seasons == nil and root.claims == nil then root.claims = {} end
    if type(root.claims) ~= "table" then error("season claims unreadable") end
    md = root
    if root.seasons == nil then
        local legacyId = root.config.season or "1"
        local number = tonumber(legacyId)
        if not whole(number, 1, 1000000000) then number = 1 end
        local days, err = configuredDays()
        if days == nil then error(err) end
        local ms = EC.now()
        if not finite(ms) then error("season clock unreadable") end
        local id = S.newId()
        root.seasons = { version = 1, history = {}, current = {
            id = id, number = number, startedAt = ms, durationDays = days,
            endsAt = days > 0 and (ms + days * DAY_MS) or nil, partial = true, participants = 0,
        } }
        root.config.season = id
        -- Start observing now, without inventing earlier survival or paying claimed milestones again.
        for _, c in pairs(root.claims) do
            if type(c) == "table" and c.season == legacyId then resetClaim(c, id, true) end
        end
    end
    md, data = root, root.seasons
    initError = nil
    local season, err = current()
    if not season then initError = err; error(err) end
    -- The running season follows the setting, so a length stored while this server was down (or
    -- written under the old "next season only" rule) is applied to it here, keeping its id, its
    -- number and its start. An expired result is left expired: the tick's own deadline check
    -- closes it once, exactly like any other overdue season.
    local days, daysErr = configuredDays()
    if days == nil then initError = daysErr; error(daysErr) end
    if season.durationDays ~= days then
        season.durationDays = days
        season.endsAt = days > 0 and (season.startedAt + days * DAY_MS) or nil
    end
    local records, _, recordsErr = Se.records("current")
    if not records then initError = recordsErr; error(recordsErr) end
    local state, stateErr = Se.state()
    if not state then initError = stateErr; error(stateErr) end
end

S.Seasons = Se
S.onInit(Se.init)
Events.OnTickEvenPaused.Add(Se.onTick)
Events.OnCharacterDeath.Add(onDeath)
return Se
