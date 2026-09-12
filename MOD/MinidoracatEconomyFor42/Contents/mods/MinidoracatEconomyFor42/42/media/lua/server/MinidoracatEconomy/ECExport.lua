-- MinidoracatEconomyFor42 — file export (server authority).
--
-- Everything durable outside Global ModData lives under {cachedir}/Lua/MinidoracatEconomy/:
--   events-YYYYMMDD.json          one JSON object per line (NDJSON); the extension must be .json
--                                 (getFileWriter whitelist: ini/cfg/txt/log/json, LuaManager.java:1034)
--   receipts/<safeName>/YYYYMM.json  one line per posting of that account (balance chain)
--   audit/YYYYMM.json             admin operations (written by the admin module)
--   heartbeat.json                single line, rewritten every 60 s (auction downtime policy)
--
-- Engine facts (stage A): getFileWriter appends in UTF-8 (LuaManager.java:6729-6761); writeln uses
-- System.lineSeparator() (CRLF on Windows, LF on Linux; LuaManager.java:12762-12765); close() is the
-- only flush. Cost is almost entirely string building (A2): a tick may write at most
-- MAX_LINES_PER_TICK lines, the rest waits in the queue. Files are append-only and never deleted
-- by Lua (no delete API); the companion / server owner rotates them.

if not MinidoracatEconomy or not MinidoracatEconomy.Ledger then
    require "MinidoracatEconomy/ECLedger"
end
local EC = MinidoracatEconomy
local S = EC and EC.Server
local L = EC and EC.Ledger
if not S or not S.AUTHORITY or not L then
    return
end

EC.Export = EC.Export or {}
local X = EC.Export

X.ROOT = "MinidoracatEconomy"
X.MAX_LINES_PER_TICK = 50
X.HEARTBEAT_INTERVAL_MS = 60000
X.MAX_QUEUE_LINES = 20000           -- hard bound: beyond this the oldest lines are dropped and logged
X.AUDIT_RING = 500                  -- admin operations kept in ModData for the panel (spec 19.2 / 20)
X.AUDIT_REASON_CHARS = 40           -- ModData is readable by every client: only a reason prefix (spec 19.3.7)

local sep = "/"                       -- getFileWriter normalises separators (LuaManager.java:6732-6733)

local md = nil
local queue = {}                      -- ordered list of { path = ..., lines = { ... } }
local queueIndex = {}                 -- path -> entry
local queuedLines = 0
local lastHeartbeat = 0
local writerWarned = {}
local failedPaths = {}
local publicViews, adminViews, ownerViews = {}, {}, {}
local viewsDirty = false

function X.changed(scope, username)
    local target
    if username then
        target = ownerViews[username]
        if not target then target = {}; ownerViews[username] = target end
    elseif scope == "transactions" or scope == "audit" or scope == "players" then
        target = adminViews
    else
        target = publicViews
    end
    target[scope] = true
    viewsDirty = true
end

local function eventsPath(ms)
    return X.ROOT .. sep .. "events-" .. EC.dayKey(ms) .. ".json"
end

local function receiptsPath(account, ms)
    return X.ROOT .. sep .. "receipts" .. sep .. EC.safeName(account) .. sep .. EC.monthKey(ms) .. ".json"
end

-- market/<safeName>/YYYYMM.json: one line per market event of that account (the player and
-- admin "market history" pages tail it like the receipts)
local function marketPath(account, ms)
    return X.ROOT .. "/market/" .. EC.safeName(account) .. "/" .. EC.monthKey(ms) .. ".json"
end

local function auditPath(ms)
    return X.ROOT .. sep .. "audit" .. sep .. EC.monthKey(ms) .. ".json"
end

X.eventsPath = eventsPath
X.receiptsPath = receiptsPath
X.auditPath = auditPath
X.marketPath = marketPath

-- ---------- queue ----------

function X.enqueue(path, line)
    local entry = queueIndex[path]
    if not entry then
        entry = { path = path, lines = {}, enqueued = 0, handled = 0 }
        queueIndex[path] = entry
        queue[#queue + 1] = entry
    end
    entry.lines[#entry.lines + 1] = line
    entry.enqueued = entry.enqueued + 1
    queuedLines = queuedLines + 1
    if queuedLines > X.MAX_QUEUE_LINES then
        -- Drop from the oldest file entry; log once per overflow episode.
        local oldest = queue[1]
        if oldest and #oldest.lines > 0 then
            table.remove(oldest.lines, 1)
            oldest.handled = oldest.handled + 1
            oldest.failed = true
            failedPaths[oldest.path] = true
            queuedLines = queuedLines - 1
            EC.log("export queue overflow, dropped a line for " .. oldest.path)
            if #oldest.lines == 0 then
                table.remove(queue, 1)
                queueIndex[oldest.path] = nil
            end
        end
    end
end

-- Capture only writes already queued for this read. Later arrivals never extend its wait.
-- The entry references survive queue removal; no copy of queued JSON strings is needed.
function X.readFence(paths)
    local fence = {}
    for _, path in ipairs(paths) do
        if failedPaths[path] then fence.failed = true end
        local entry = queueIndex[path]
        if entry then fence[#fence + 1] = { entry = entry, target = entry.enqueued } end
    end
    return fence
end

function X.fenceStatus(fence)
    if fence.failed then return false, "read_failed" end
    local ready = true
    for _, item in ipairs(fence) do
        if item.entry.failed then return false, "read_failed" end
        if item.entry.handled < item.target then ready = false end
    end
    return ready
end

function X.queuedLines()
    return queuedLines
end

local function openWriter(path, append)
    local w = getFileWriter(path, true, append)
    if not w and not writerWarned[path] then
        writerWarned[path] = true
        EC.log("getFileWriter failed for " .. path)
    end
    return w
end

-- The tick budget is shared by all paths. A partial path rotates to the back so a continuous
-- event stream cannot starve a receipt/history read waiting behind it.
function X.flush(budget)
    budget = budget or X.MAX_LINES_PER_TICK
    local processed, written = 0, 0
    while #queue > 0 and processed < budget do
        local entry = table.remove(queue, 1)
        local n = #entry.lines
        local take = math.min(n, budget - processed)
        if take > 0 then
            local writer
            local called, success = pcall(function()
                writer = openWriter(entry.path, true)
                if not writer then return false end
                for i = 1, take do writer:writeln(entry.lines[i]) end
                writer:close()
                writer = nil
                return true
            end)
            if writer then pcall(function() writer:close() end) end
            if called and success == true then
                written = written + take
            else
                entry.failed = true
                failedPaths[entry.path] = true
                if not writerWarned[entry.path] then
                    writerWarned[entry.path] = true
                    EC.log("export write failed for " .. entry.path .. ": " .. tostring(success))
                end
            end
            -- Keep the existing no-replay policy after a writer failure: an append may have
            -- partially reached disk. Mark reads failed instead of replaying uncertain rows.
            local rest = {}
            for i = take + 1, n do rest[#rest + 1] = entry.lines[i] end
            entry.lines = rest
            entry.handled = entry.handled + take
            queuedLines = queuedLines - take
            processed = processed + take
        end
        if #entry.lines == 0 then
            queueIndex[entry.path] = nil
        else
            queue[#queue + 1] = entry
        end
    end
    return written
end

-- ---------- records ----------

local function baseRecord(type_, ms)
    return { type = type_, ts = ms, epoch = md.meta.epoch, realmId = md.meta.realmId }
end

-- Generic event (server.started, admin.*, ledger.anomaly, ...). `seq` is the current ModData
-- seq at emission time unless the caller supplies one.
function X.emit(type_, fields)
    local ms = EC.now()
    local rec = baseRecord(type_, ms)
    rec.seq = md.meta.seq
    if type(fields) == "table" then
        for k, v in pairs(fields) do rec[k] = v end
    end
    X.enqueue(eventsPath(ms), EC.jsonEncode(rec))
    if string.sub(type_, 1, 7) == "market." then
        X.changed("market")
    elseif string.sub(type_, 1, 8) == "auction." then
        X.changed("auction")
    elseif type_ == "mail.claimed" and type(rec.username) == "string" then
        X.changed("mail", rec.username)
    end
    return rec
end

-- One market history line for `account` (seller or buyer side of a listing event): the
-- events file already has the neutral record, this is the per-player view the pages tail.
function X.market(account, fields)
    local ms = EC.now()
    local rec = baseRecord("market", ms)
    rec.seq = md.meta.seq
    for k, v in pairs(fields or {}) do rec[k] = v end
    X.enqueue(marketPath(account, ms), EC.jsonEncode(rec))
    X.changed("market", account)
    X.changed("mail", account)
end

local function auditPart(value)
    if type(value) == "number" then return string.format("%.0f", value) end
    return type(value) == "string" and value or ""
end

function X.auditKey(rec)
    if type(rec.auditId) == "string" and rec.auditId ~= "" then return rec.auditId end
    return "legacy:" .. EC.jsonEncode({
        auditPart(rec.epoch), auditPart(rec.seq), auditPart(rec.ts), auditPart(rec.action),
        auditPart(rec.admin), auditPart(rec.target), auditPart(rec.field),
    })
end

-- Full record goes to the audit + events files; a trimmed copy lands in the bounded ModData ring
-- the admin panel reads (newest first via X.auditEntries).
function X.audit(fields)
    local ms = EC.now()
    local rec = baseRecord("audit", ms)
    for k, v in pairs(fields or {}) do rec[k] = v end
    rec.auditId = S.newId()
    rec.seq = md.meta.seq
    X.enqueue(auditPath(ms), EC.jsonEncode(rec))
    X.enqueue(eventsPath(ms), EC.jsonEncode(rec))
    local ring = md.audit
    local short = {}
    for k, v in pairs(rec) do short[k] = v end
    short.reasonTruncated = type(short.reason) == "string" and #short.reason > X.AUDIT_REASON_CHARS
    if type(short.reason) == "string" and #short.reason > X.AUDIT_REASON_CHARS then
        short.reason = string.sub(short.reason, 1, X.AUDIT_REASON_CHARS)
    end
    ring.items[ring.head] = short
    ring.head = ring.head % X.AUDIT_RING + 1
    if ring.count < X.AUDIT_RING then ring.count = ring.count + 1 end
    X.changed("audit")
    X.changed("players")
    if rec.action == "whitelist" then X.changed("whitelist"); X.changed("market") end
end

-- Copy of a ring entry: the reply must never share a table with Global ModData, so nested values
-- (Cfg.setExchange stores flat before/after blocks of exchange numbers) are copied too, and
-- anything deeper than COPY_DEPTH is dropped rather than aliased.
local COPY_DEPTH = 4

local function copyValue(v, depth)
    if type(v) ~= "table" then return v end
    if depth >= COPY_DEPTH then return nil end
    local out = {}
    for k, inner in pairs(v) do out[k] = copyValue(inner, depth + 1) end
    return out
end

-- Newest first. The default and the hard bound are whatever the ring currently holds (never more
-- than AUDIT_RING); a positive integer `limit` below that narrows the reply, anything else is
-- ignored. Each copy is stamped with rolledBack for its own (epoch, seq) so the panel can mark
-- operations that did not survive into the save the current process loaded (spec 19.6).
function X.auditEntries(limit)
    local ring = md.audit
    local n = ring.count
    if type(limit) == "number" and limit == math.floor(limit) and limit > 0 and limit < n then
        n = limit
    end
    local out = {}
    local idx = ring.head - 1
    for _ = 1, n do
        if idx < 1 then idx = X.AUDIT_RING end
        local e = ring.items[idx]
        if type(e) == "table" then
            local copy = copyValue(e, 1)
            copy.rolledBack = S.isRolledBack(e.epoch, e.seq)
            copy.key = X.auditKey(e)
            local ts = e.ts
            if type(ts) == "number" and ts == ts and ts ~= math.huge and ts ~= -math.huge and ts == math.floor(ts) then
                copy.month = EC.monthKey(ts)
            end
            copy.source, copy.full = "ring", false
            out[#out + 1] = copy
        end
        idx = idx - 1
    end
    return out
end

function X.lastHeartbeatMs()
    return lastHeartbeat
end

local function fileHeader(ms)
    return EC.jsonEncode({
        type = "file.header", ts = ms, epoch = md.meta.epoch, realmId = md.meta.realmId,
        schemaVersion = md.schemaVersion, startedSeq = md.meta.loadedSeq, version = EC.VERSION,
    })
end

-- Ledger listener: one tx.committed event + one receipt line per player posting.
local function onCommitted(ev)
    local rec = baseRecord("tx.committed", ev.ts)
    rec.seq = ev.seq
    rec.txId = ev.txId
    rec.kind = ev.kind
    rec.reasonCode = ev.reasonCode
    rec.reasonText = ev.reasonText
    rec.actor = ev.actor
    rec.requestId = ev.requestId
    rec.payload = ev.payload
    rec.postings = ev.postings
    X.enqueue(eventsPath(ev.ts), EC.jsonEncode(rec))
    X.changed("transactions")
    X.changed("players")
    if ev.kind == "shop_sell" then X.changed("shop") end
    for _, p in ipairs(ev.postings) do
        if not L.isSystemAccount(p.account) then
            X.changed("wallet", p.account)
            X.enqueue(receiptsPath(p.account, ev.ts), EC.jsonEncode({
                epoch = md.meta.epoch, seq = ev.seq, ts = ev.ts, txId = ev.txId, type = ev.kind,
                reasonCode = ev.reasonCode, currency = p.currency, delta = p.amount,
                availableBefore = p.availableBefore, availableAfter = p.availableAfter,
                reservedBefore = p.reservedBefore, reservedAfter = p.reservedAfter,
                counterparty = L.counterparty(ev.postings, p),
                sourceMod = ev.payload and ev.payload.sourceMod or nil,
                reasonText = ev.reasonText,
                ref = ev.payload and ev.payload.ref or nil,
                item = ev.payload and ev.payload.item or nil,
                qty = ev.payload and ev.payload.qty or nil,
            }))
        end
    end
end

-- ---------- heartbeat ----------

function X.heartbeat(ms)
    local w = openWriter(X.ROOT .. sep .. "heartbeat.json", false)   -- truncate: single line
    if not w then return false end
    w:writeln(EC.jsonEncode({ ts = ms, epoch = md.meta.epoch, seq = md.meta.seq, realmId = md.meta.realmId }))
    w:close()
    lastHeartbeat = ms
    return true
end

-- ---------- lifecycle ----------

local listenerRegistered = false
local lastDay = nil

function X.init(root)
    md = root
    md.audit = md.audit or { items = {}, head = 1, count = 0, capacity = X.AUDIT_RING }
    local ring = md.audit
    if not ring.capacity then
        -- The first admin draft used a 200-slot ring. Preserve its chronological order before
        -- extending it: changing the modulo alone loses rows after the old ring has wrapped.
        local entries = {}
        local index = ring.head - ring.count
        if index < 1 then index = index + 200 end
        for _ = 1, ring.count do
            entries[#entries + 1] = ring.items[index]
            index = index % 200 + 1
        end
        ring.items, ring.count = entries, #entries
        ring.head = #entries + 1
        ring.capacity = X.AUDIT_RING
    end
    queue, queueIndex, queuedLines = {}, {}, 0
    failedPaths, writerWarned = {}, {}
    publicViews, adminViews, ownerViews, viewsDirty = {}, {}, {}, false
    if not listenerRegistered then
        L.onCommitted(onCommitted)
        listenerRegistered = true
    end
    local ms = EC.now()
    lastDay = EC.dayKey(ms)
    X.enqueue(eventsPath(ms), fileHeader(ms))
    X.emit("server.started", { loadedSeq = md.meta.loadedSeq, schemaVersion = md.schemaVersion, version = EC.VERSION })
    -- Epochs that crashed before their first save (ECServer epochs.json): the journal states the
    -- rolled-back range itself so a reader does not need the save to know it. The line belongs to
    -- the current epoch; the crashed one is a payload field.
    for _, h in ipairs(S.crashedEpochs or {}) do
        X.emit("epoch.rolledback", { crashedEpoch = h.epoch, fromSeq = h.loadedSeq + 1 })
        EC.log("epoch " .. h.epoch .. " crashed before saving; entries from seq " .. tostring(h.loadedSeq + 1) .. " are rolled back")
    end
    X.flush()                      -- startup lines go out immediately
    X.heartbeat(ms)
end

-- Throttled tick: flush the queue, heartbeat every minute, header on day change.
function X.onTick()
    if not md then return end
    local ms = EC.now()
    local day = EC.dayKey(ms)
    if day ~= lastDay then
        lastDay = day
        X.enqueue(eventsPath(ms), fileHeader(ms))
    end
    if queuedLines > 0 then
        X.flush()
    end
    if ms - lastHeartbeat >= X.HEARTBEAT_INTERVAL_MS then
        X.heartbeat(ms)
    end
    if viewsDirty and X.onViewsChanged then
        local sent, err = pcall(X.onViewsChanged, publicViews, adminViews, ownerViews)
        if sent then
            publicViews, adminViews, ownerViews, viewsDirty = {}, {}, {}, false
        else
            EC.log("view invalidation failed: " .. tostring(err))
        end
    end
end

S.Export = X
S.onInit(X.init)
Events.OnTickEvenPaused.Add(X.onTick)

return X
