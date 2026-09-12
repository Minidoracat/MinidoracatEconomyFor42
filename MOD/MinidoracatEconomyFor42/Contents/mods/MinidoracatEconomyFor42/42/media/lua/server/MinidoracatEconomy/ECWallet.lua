-- MinidoracatEconomyFor42 — wallet view for clients (server authority).
--
--   wallet.state            balances per currency + the short receipt ring (with rolledBack flags)
--   wallet.changed (push)   balances after every transaction that touched the player
--   wallet.history{month}   last entries of receipts/<safeName>/<YYYYMM>.json, read in batches of
--                           HISTORY_LINES_PER_TICK lines per tick (stage A15: 200 lines ≈ 0.27 ms)
--
-- Engine: getFileReader(filename, createIfNull) LuaManager.java:5933-5963 ; LuaFileReader.readLine
-- returns nil at EOF; close() releases the handle.

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

EC.Wallet = EC.Wallet or {}
local W = EC.Wallet

W.HISTORY_LINES_PER_TICK = 200
W.HISTORY_MAX_ENTRIES = 200          -- newest entries kept per reply (packet budget ~60 KB)
W.HISTORY_MAX_JOBS = 8               -- concurrent readers across all players

local jobs = {}                      -- key (username:command) -> { paths, index, reader, ring, head, count, truncated, player, command, extra }

local playerByUsername = S.onlinePlayer

function W.balances(username)
    local out = {}
    for _, id in ipairs(EC.CURRENCY_ORDER) do
        out[id] = L.getBalance(username, id)
    end
    return out
end

-- The receipt ring as the pages read it: the whole usable summary of the line (what moved, for
-- what, and the balance chain around it). A field the ring never carried stays nil - an unknown
-- balance is not 0, and the panel must be able to tell "no reserve movement" from "not recorded"
-- (the ledger writes reservedAfter only, so reservedBefore is unknown on every current line).
function W.state(username)
    local receipts = L.receipts(username)
    local list = {}
    for i, r in ipairs(receipts) do
        local epoch = r.txId and EC.parseId(r.txId) or nil
        list[i] = {
            txId = r.txId, seq = r.seq, ts = r.ts, kind = r.kind, currency = r.currency, amount = r.amount,
            before = r.before, after = r.after,
            reservedBefore = r.reservedBefore, reservedAfter = r.reservedAfter,
            counterparty = r.counterparty,
            item = r.item, qty = r.qty, reasonText = r.reasonText, sourceMod = r.sourceMod,
            rolledBack = S.isRolledBack(epoch, r.seq),
        }
    end
    return { balances = W.balances(username), receipts = list, currencies = EC.CURRENCY_ORDER, frozen = L.isFrozen(username) }
end

-- ---------- tail-of-file jobs ----------
--
-- Reads one or more NDJSON files a batch per tick and replies with the newest MAX entries, each
-- annotated with rolledBack (S.isRolledBack on the line's epoch/seq). Shared by wallet.history
-- (receipt files), admin.auditFile (audit files) and auction.history / admin.transactions /
-- admin.transaction (the daily events files): one job per player per command.
--
-- An optional `projector(entry) -> record | nil` filters and reshapes every line before it enters
-- the ring, so the 200-entry bound applies to the matches and not to the raw lines (a search for
-- an old auction is not pushed out by newer unrelated events). A read that breaks halfway replies
-- error=read_failed: a truncated list must never be handed over as a complete one.
--
-- Read-your-writes: every job first waits for the export fence taken when the query started
-- (X.readFence / X.fenceStatus). The client's own successful operation is enqueued for the file
-- before its reply leaves the server, so reading before that watermark reached disk would answer
-- with the state *before* the operation - and for the very first record of a month it would open
-- no file at all and report an empty success. The fence is a watermark, not a flush: the export
-- keeps its 50-lines-per-tick budget and later lines never extend an existing fence.

-- The reply of a finished job. An internal reader (the recovery proof journal) passes
-- `onComplete` and takes the whole reply itself: raw evidence is never sent to a client, and the
-- refusals below take the same route, so one caller never has to handle two kinds of outcome.
local function deliver(job, reply)
    if job.onComplete then
        local ok, err = pcall(job.onComplete, reply)
        if not ok then EC.log("file job callback failed: " .. tostring(err)) end
        return
    end
    if job.player then S.reply(job.player, job.command, reply) end
end

local function finishJob(key, job)
    jobs[key] = nil
    if job.reader then pcall(function() job.reader:close() end) end
    if not job.player then return end
    local reply
    if job.failed then
        reply = { entries = {}, total = 0, truncated = false, error = "read_failed" }
    else
        local entries = {}
        local n = job.count
        local start = n < W.HISTORY_MAX_ENTRIES and 1 or job.head
        local size = math.min(n, W.HISTORY_MAX_ENTRIES)
        for i = 0, size - 1 do
            entries[#entries + 1] = job.ring[(start - 1 + i) % size + 1]
        end
        reply = { entries = entries, truncated = job.truncated, total = n }
    end
    -- On a broken read the verdict is read_failed; the echoed criteria must not overwrite it
    -- (a projector that reports its own outcome through `extra` cannot mask a failed read).
    for k, v in pairs(job.extra) do
        if not (job.failed and k == "error") then reply[k] = v end
    end
    deliver(job, reply)
end

local function pushEntry(job, entry)
    job.count = job.count + 1
    if #job.ring < W.HISTORY_MAX_ENTRIES then
        job.ring[#job.ring + 1] = entry
    else
        job.ring[job.head] = entry
        job.head = job.head % W.HISTORY_MAX_ENTRIES + 1
        job.truncated = true
    end
end

-- Opens the next path that exists; false when every path is exhausted.
local function openNext(job)
    while job.index < #job.paths do
        job.index = job.index + 1
        local path = job.paths[job.index]
        local reader = getFileReader(path, false)
        if reader then
            job.reader = reader
            return true
        end
        -- getFileReader catches IOException in Java and returns nil even for an existing file
        -- (LuaManager.java:5949-5960); cacheFileExists uses the same Lua cache root (:5541-5549).
        if cacheFileExists(path) then error("could not open history file: " .. path) end
    end
    job.reader = nil
    return false
end

-- Waits for the fence, then opens the first readable path; false while the fence is still behind.
local function startJob(key, job)
    local ready, err = X.fenceStatus(job.fence)
    if err then error("history fence failed: " .. tostring(err)) end
    if not ready then return false end
    job.opened = true
    if not openNext(job) then
        finishJob(key, job)          -- fence reached, no such file: an honest empty answer
        return false
    end
    return true
end

-- One batch: bounded by W.HISTORY_LINES_PER_TICK and, for an internal reader that asked for one,
-- by a byte budget as well (whichever runs out first). A journal line carries a whole replay, so
-- a line count alone is not a bound on the work a tick does - the decode is the cost.
local function stepJob(key, job)
    if not job.opened and not startJob(key, job) then return end
    local bytes = 0
    for _ = 1, W.HISTORY_LINES_PER_TICK do
        local line = job.reader and job.reader:readLine() or nil
        if line == nil then
            if job.reader then pcall(function() job.reader:close() end) end
            if not openNext(job) then
                finishJob(key, job)
                return
            end
        elseif string.find(line, "%S") then
            bytes = bytes + #line
            local entry = EC.jsonDecode(line)
            if type(entry) == "table" then
                local epoch = entry.txId and EC.parseId(entry.txId) or entry.epoch
                entry.rolledBack = S.isRolledBack(epoch, entry.seq)
                local record, done = entry, false
                if job.projector then record, done = job.projector(entry) end
                if record then pushEntry(job, record) end
                if done then finishJob(key, job); return end
            elseif job.strictJson then
                error("invalid history JSON: " .. job.paths[job.index])
            end
            if job.bytesPerTick and bytes >= job.bytesPerTick then return end
        end
    end
end

function W.onTick()
    for key, job in pairs(jobs) do
        local ok, err = pcall(stepJob, key, job)
        if not ok then
            EC.log("file job " .. key .. " failed: " .. tostring(err))
            job.failed = true
            finishJob(key, job)
        end
    end
end

-- Starts a job for `player`: the newest entries of `paths` (read in order) are replied through
-- `command` merged with `extra`, optionally filtered through `projector`. Refuses at once with
-- error=busy (same player+command still reading) or server_busy (too many readers); a file that
-- cannot be opened once the fence is reached replies error=read_failed, a file that does not
-- exist simply contributes nothing.
-- A projector may also return true as its second result to finish an exact single-record lookup,
-- and may report its own outcome by writing `extra.error` (a broken read still wins).
-- strictJson fails on malformed non-empty rows; financial queries cannot silently skip them.
--
-- `options` is internal only (the recovery proof journal; no client command passes one) and
-- every existing six-argument caller keeps its exact behaviour:
--   onComplete(reply)  the whole outcome - finish, refuse and read failure - goes to this
--                      callback and nothing is sent to the player. Server-only evidence is read
--                      through this door and never leaves as a reply.
--   bytesPerTick       an extra per-tick budget on top of the line count. There is deliberately
--                      no row pre-filter: a caller that skips a row it did not parse cannot say
--                      the row was intact, and for a financial read that is the whole question.
function W.tail(player, command, paths, extra, projector, strictJson, options)
    local key = player:getUsername() .. ":" .. command
    local onComplete = type(options) == "table" and options.onComplete or nil
    local function refuse(code)
        local reply = { entries = {}, total = 0, truncated = false, error = code }
        for k, v in pairs(extra) do
            if k ~= "error" then reply[k] = v end
        end
        if onComplete then
            local ok, err = pcall(onComplete, reply)
            if not ok then EC.log("file job callback failed: " .. tostring(err)) end
            return
        end
        S.reply(player, command, reply)
    end
    if jobs[key] then return refuse("busy") end
    if EC.countKeys(jobs) >= W.HISTORY_MAX_JOBS then return refuse("server_busy") end
    -- The watermark of these paths as of now: everything the caller's own operation already
    -- enqueued is read, nothing waits for lines written after the query started.
    jobs[key] = {
        paths = paths, index = 0, reader = nil, ring = {}, head = 1, count = 0, truncated = false,
        player = player, command = command, extra = extra, projector = projector,
        strictJson = strictJson == true, fence = X.readFence(paths), opened = false,
        onComplete = onComplete,
        bytesPerTick = type(options) == "table" and tonumber(options.bytesPerTick) or nil,
    }
end

-- Is there room for this read right now? An internal FIFO asks before it starts one, so a busy
-- pool means "wait", not a refusal that comes back through the callback and is answered with
-- another attempt in the same tick.
function W.canStartRead(player, command)
    if player == nil or type(command) ~= "string" then return false end
    local ok, username = pcall(function() return player:getUsername() end)
    if not ok or type(username) ~= "string" then return false end
    if jobs[username .. ":" .. command] then return false end
    return EC.countKeys(jobs) < W.HISTORY_MAX_JOBS
end

-- Receipt file paths for a username: the given months in order (a missing file contributes nothing).
function W.receiptPaths(username, months)
    local paths = {}
    for _, m in ipairs(months) do
        paths[#paths + 1] = X.ROOT .. "/receipts/" .. EC.safeName(username) .. "/" .. m .. ".json"
    end
    return paths
end

-- Market history file paths for a username (same layout as the receipts, under market/).
function W.marketPaths(username, months)
    local paths = {}
    for _, m in ipairs(months) do
        paths[#paths + 1] = X.ROOT .. "/market/" .. EC.safeName(username) .. "/" .. m .. ".json"
    end
    return paths
end

-- Daily events file paths, oldest first (a day with no file contributes nothing, so the ring
-- keeps the newest matches). Without a range this is the shared default window: the first day of
-- the previous UTC month through today, at most 62 paths (reached only when both months have 31
-- days and today is the 31st). With a range it is every UTC day covering fromMs .. toMs-1; the
-- caller bounds the span first (the admin endpoints refuse more than 62 days).
-- Server-built from timestamps: no client string ever reaches a path.
function W.eventPaths(ms, fromMs, toMs)
    local keys = {}
    if fromMs and toMs then
        for day = math.floor(fromMs / 86400000), math.floor((toMs - 1) / 86400000) do
            keys[#keys + 1] = EC.dayKey(day * 86400000)
        end
    else
        local _, _, d = EC.utcDate(ms)
        local prev, cur = EC.monthKey(ms - d * 86400000), EC.monthKey(ms)
        local newest = {}
        for i = 0, 61 do
            local t = ms - i * 86400000
            local key = EC.monthKey(t)
            if key ~= cur and key ~= prev then break end
            newest[#newest + 1] = EC.dayKey(t)
        end
        for i = #newest, 1, -1 do keys[#keys + 1] = newest[i] end
    end
    local paths = {}
    for i = 1, #keys do paths[i] = X.ROOT .. "/events-" .. keys[i] .. ".json" end
    return paths
end

-- Lower-cased display name of a fullType, for the query haystack of a tailed file (ScriptManager
-- as in Au.create; an unknown type contributes nothing). Cached: the same few types repeat across
-- a whole file. Shared by the auction history and the admin transactions view.
local itemNames = {}
function W.itemNameLower(fullType)
    if type(fullType) ~= "string" or fullType == "" then return "" end
    local cached = itemNames[fullType]
    if cached ~= nil then return cached end
    local name = nil
    pcall(function() name = ScriptManager.instance:FindItem(fullType):getDisplayName() end)
    name = type(name) == "string" and string.lower(name) or ""
    itemNames[fullType] = name
    return name
end

-- Previous and current UTC month keys (the "recent" window spans a month boundary).
function W.recentMonths(ms)
    local _, _, day = EC.utcDate(ms)
    local prev = EC.monthKey(ms - day * 86400000)
    local cur = EC.monthKey(ms)
    if prev == cur then return { cur } end
    return { prev, cur }
end

-- month: "YYYYMM" or "recent" (previous + current month, newest last); a month with no file
-- gives an empty reply.
function W.requestHistory(player, month, requestId)
    if requestId ~= nil and (type(requestId) ~= "string" or requestId == "" or #requestId > 96 or string.find(requestId, "%c")) then
        S.reply(player, "wallet.history", { month = tostring(month), entries = {}, error = "invalid_args" })
        return
    end
    local months
    if month == "recent" then
        months = W.recentMonths(EC.now())
    elseif type(month) == "string" and string.match(month, "^%d%d%d%d%d%d$") then
        months = { month }
    else
        S.reply(player, "wallet.history", { month = tostring(month), requestId = requestId, entries = {}, error = "invalid_args" })
        return
    end
    W.tail(player, "wallet.history", W.receiptPaths(player:getUsername(), months), { month = month, requestId = requestId })
end

-- ---------- push on change ----------

local function onCommitted(ev)
    local notified = {}
    for _, p in ipairs(ev.postings) do
        if not L.isSystemAccount(p.account) and not notified[p.account] then
            notified[p.account] = true
            local player = playerByUsername(p.account)
            if player then
                S.reply(player, "wallet.changed", { balances = W.balances(p.account), txId = ev.txId, kind = ev.kind, frozen = L.isFrozen(p.account) })
            end
        end
    end
end

-- The frozen flag changed for `username`: the player (when online) learns it at once instead of
-- at the next refused transaction.
function W.pushState(username)
    local player = playerByUsername(username)
    if player then
        S.reply(player, "wallet.changed", { balances = W.balances(username), frozen = L.isFrozen(username) })
    end
end

-- ---------- lifecycle ----------

local listenerRegistered = false
function W.init()
    for key, job in pairs(jobs) do
        if job.reader then pcall(function() job.reader:close() end) end
        jobs[key] = nil
    end
    if not listenerRegistered then
        L.onCommitted(onCommitted)
        listenerRegistered = true
    end
end

S.handlers["wallet.state"] = function(player, args)
    local res = W.state(player:getUsername())
    res.requestId = type(args.requestId) == "string" and #args.requestId <= 96 and args.requestId or nil
    S.reply(player, "wallet.state", res)
end

S.handlers["wallet.history"] = function(player, args)
    W.requestHistory(player, args.month, args.requestId)
end

S.Wallet = W
S.onInit(W.init)
Events.OnTickEvenPaused.Add(W.onTick)

return W
