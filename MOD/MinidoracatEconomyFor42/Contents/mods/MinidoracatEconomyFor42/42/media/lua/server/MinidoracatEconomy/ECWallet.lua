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
local jobs = {}                      -- username -> { reader, month, ring, head, count, truncated, player }

local function playerByUsername(username)
    local players = getOnlinePlayers()
    if not players then return nil end
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p and p:getUsername() == username then return p end
    end
    return nil
end

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
    return { balances = W.balances(username), receipts = list, currencies = EC.CURRENCY_ORDER }
end

-- ---------- history jobs ----------

local function finishJob(username, job)
    jobs[username] = nil
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
        S.reply(p, "wallet.history", { month = job.month, entries = entries, truncated = job.truncated, total = n })
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

local function stepJob(username, job)
    for _ = 1, W.HISTORY_LINES_PER_TICK do
        local line = job.reader:readLine()
        if line == nil then
            finishJob(username, job)
            return
        end
        if line ~= "" then
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
    for username, job in pairs(jobs) do
        local ok, err = pcall(stepJob, username, job)
        if not ok then
            EC.log("history job for " .. username .. " failed: " .. tostring(err))
            finishJob(username, job)
        end
    end
end

-- month: "YYYYMM"; the file may not exist (no activity that month) -> empty reply.
function W.requestHistory(player, month)
    local username = player:getUsername()
    if type(month) ~= "string" or not string.match(month, "^%d%d%d%d%d%d$") then
        S.reply(player, "wallet.history", { month = tostring(month), entries = {}, error = "invalid_args" })
        return
    end
    if jobs[username] then
        S.reply(player, "wallet.history", { month = month, entries = {}, error = "busy" })
        return
    end
    if EC.countKeys(jobs) >= W.HISTORY_MAX_JOBS then
        S.reply(player, "wallet.history", { month = month, entries = {}, error = "server_busy" })
        return
    end
    local path = X.ROOT .. "/receipts/" .. EC.safeName(username) .. "/" .. month .. ".json"
    local reader = getFileReader(path, false)
    if not reader then
        S.reply(player, "wallet.history", { month = month, entries = {}, total = 0 })
        return
    end
    jobs[username] = { reader = reader, month = month, ring = {}, head = 1, count = 0, truncated = false, player = player }
end

-- ---------- push on change ----------

local function onCommitted(ev)
    local notified = {}
    for _, p in ipairs(ev.postings) do
        if not L.isSystemAccount(p.account) and not notified[p.account] then
            notified[p.account] = true
            local player = playerByUsername(p.account)
            if player then
                S.reply(player, "wallet.changed", { balances = W.balances(p.account), txId = ev.txId, kind = ev.kind })
            end
        end
    end
end

-- ---------- lifecycle ----------

local listenerRegistered = false
function W.init(root)
    md = root
    for username, job in pairs(jobs) do
        if job.reader then pcall(function() job.reader:close() end) end
        jobs[username] = nil
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
