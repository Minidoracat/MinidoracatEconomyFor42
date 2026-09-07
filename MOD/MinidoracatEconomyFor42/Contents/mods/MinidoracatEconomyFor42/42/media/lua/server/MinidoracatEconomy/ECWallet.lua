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

local md = nil
local jobs = {}                      -- key (username:command) -> { paths, index, reader, ring, head, count, truncated, player, command, extra }

local playerByUsername = S.onlinePlayer

function W.balances(username)
    local out = {}
    for _, id in ipairs(EC.CURRENCY_ORDER) do
        out[id] = L.getBalance(username, id)
    end
    return out
end

function W.state(username)
    local receipts = L.receipts(username)
    local list = {}
    for i, r in ipairs(receipts) do
        local epoch = r.txId and EC.parseId(r.txId) or nil
        list[i] = {
            txId = r.txId, seq = r.seq, ts = r.ts, kind = r.kind, currency = r.currency, amount = r.amount,
            before = r.before, after = r.after, counterparty = r.counterparty,
            rolledBack = S.isRolledBack(epoch, r.seq),
        }
    end
    return { balances = W.balances(username), receipts = list, currencies = EC.CURRENCY_ORDER, frozen = L.isFrozen(username) }
end

-- ---------- tail-of-file jobs ----------
--
-- Reads one or more NDJSON files a batch per tick and replies with the newest MAX entries, each
-- annotated with rolledBack (S.isRolledBack on the line's epoch/seq). Shared by wallet.history
-- (receipt files) and admin.auditFile (audit files): one job per player per command.

local function finishJob(key, job)
    jobs[key] = nil
    if job.reader then pcall(function() job.reader:close() end) end
    local entries = {}
    local n = job.count
    local start = n < W.HISTORY_MAX_ENTRIES and 1 or job.head
    local size = math.min(n, W.HISTORY_MAX_ENTRIES)
    for i = 0, size - 1 do
        entries[#entries + 1] = job.ring[(start - 1 + i) % size + 1]
    end
    local p = job.player
    if p then
        local reply = { entries = entries, truncated = job.truncated, total = n }
        for k, v in pairs(job.extra) do reply[k] = v end
        S.reply(p, job.command, reply)
    end
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
        local reader = getFileReader(job.paths[job.index], false)
        if reader then
            job.reader = reader
            return true
        end
    end
    job.reader = nil
    return false
end

local function stepJob(key, job)
    for _ = 1, W.HISTORY_LINES_PER_TICK do
        local line = job.reader and job.reader:readLine() or nil
        if line == nil then
            if job.reader then pcall(function() job.reader:close() end) end
            if not openNext(job) then
                finishJob(key, job)
                return
            end
        elseif line ~= "" then
            local entry = EC.jsonDecode(line)
            if type(entry) == "table" then
                local epoch = entry.txId and EC.parseId(entry.txId) or entry.epoch
                entry.rolledBack = S.isRolledBack(epoch, entry.seq)
                pushEntry(job, entry)
            end
        end
    end
end

function W.onTick()
    for key, job in pairs(jobs) do
        local ok, err = pcall(stepJob, key, job)
        if not ok then
            EC.log("file job " .. key .. " failed: " .. tostring(err))
            finishJob(key, job)
        end
    end
end

-- Starts a job for `player`: the newest entries of `paths` (read in order) are replied through
-- `command` merged with `extra`. Refuses with error=busy (same player+command still reading) or
-- server_busy (too many readers); missing files simply contribute nothing.
function W.tail(player, command, paths, extra)
    local key = player:getUsername() .. ":" .. command
    local function refuse(code)
        local reply = { entries = {}, error = code }
        for k, v in pairs(extra) do reply[k] = v end
        S.reply(player, command, reply)
    end
    if jobs[key] then return refuse("busy") end
    if EC.countKeys(jobs) >= W.HISTORY_MAX_JOBS then return refuse("server_busy") end
    local job = { paths = paths, index = 0, reader = nil, ring = {}, head = 1, count = 0, truncated = false,
        player = player, command = command, extra = extra }
    if not openNext(job) then
        local reply = { entries = {}, total = 0, truncated = false }
        for k, v in pairs(extra) do reply[k] = v end
        S.reply(player, command, reply)
        return
    end
    jobs[key] = job
end

-- Receipt file paths for a username: the given months in order (a missing file contributes nothing).
function W.receiptPaths(username, months)
    local paths = {}
    for _, m in ipairs(months) do
        paths[#paths + 1] = X.ROOT .. "/receipts/" .. EC.safeName(username) .. "/" .. m .. ".json"
    end
    return paths
end

-- Previous and current UTC month keys (the "recent" window spans a month boundary).
function W.recentMonths(ms)
    local prev = EC.monthKey(ms - 30 * 86400000)
    local cur = EC.monthKey(ms)
    if prev == cur then return { cur } end
    return { prev, cur }
end

-- month: "YYYYMM" or "recent" (previous + current month, newest last); a month with no file
-- gives an empty reply.
function W.requestHistory(player, month)
    local months
    if month == "recent" then
        months = W.recentMonths(EC.now())
    elseif type(month) == "string" and string.match(month, "^%d%d%d%d%d%d$") then
        months = { month }
    else
        S.reply(player, "wallet.history", { month = tostring(month), entries = {}, error = "invalid_args" })
        return
    end
    W.tail(player, "wallet.history", W.receiptPaths(player:getUsername(), months), { month = month })
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
function W.init(root)
    md = root
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
    S.reply(player, "wallet.state", W.state(player:getUsername()))
end

S.handlers["wallet.history"] = function(player, args)
    W.requestHistory(player, args.month)
end

S.Wallet = W
S.onInit(W.init)
Events.OnTickEvenPaused.Add(W.onTick)

return W
