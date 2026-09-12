-- MinidoracatEconomyFor42 - authoritative recovery journal (server authority, report CORE-H1).
--
-- WHY THIS FILE EXISTS. A pending record lives in the player's own save. After a world rollback
-- it is the only thing left that describes the operation - and it is exactly the thing a client
-- can edit. Rebuilding a listing, an auction or a buyback from it means the player writes the
-- currency, the price, the quantity, the snapshot and the origins of the asset that comes back.
-- A hash cannot help: whatever the client can recompute, the client can also forge.
--
-- So the server writes its own copy of the replay at the one commit point that exists
-- (R.finishOut), append-only, and a restore may only use that copy:
--
--   MinidoracatEconomy/recovery/<safeName>/YYYYMM.json     NDJSON, one line per finishOut
--   { type="recovery.journal", version=2, opId, owner, kind, ref, outAt, epoch, seq, replay }
--   (version 2: replay.snapshot travels as typed flat leaves - see the wire form section below)
--
-- THE FILE IS CHOSEN BY THE OPERATION ID, AND BY NOTHING ELSE. An id is "<epoch>:<seq>" and an
-- epoch is the wall clock of the server start that minted it, so the month is derivable from the
-- id alone: server root, server owner name, server id. No timestamp the player's save carries is
-- ever turned into a path - a hint that picks the file is a hint that can hide the evidence.
-- Every later decision about the same operation lands in that same file, forever.
--
-- THE CHAIN. One operation may be committed more than once: a restore re-commits it, an
-- administrator returns or discards it. Those lines are an append-only history, not duplicates:
--   * the server seq is strictly increasing along the chain (every producer bumps past the
--     current successor before it commits),
--   * the SUCCESSOR is the last legal line in the file, and it is what a restore, a verdict and
--     the retention floor are taken from - never an earlier point the player's record names,
--   * an identical rewrite of the same commit point is idempotent and ignored,
--   * the same commit point with different content, a seq that goes backwards, or a line owned
--     by another account is fail-closed: this server says it cannot tell instead of picking.
--
-- The pending record must match one line of that chain on its whole economic content (everything
-- except the commit point itself). Matching an ancestor is normal - that is precisely what a save
-- from before the last decision looks like - and it is still the successor that is handed back.
-- Content that matches no line at all is a tampered record: journal_mismatch, and nothing moves.
--
-- READS ARE ASYNCHRONOUS, ALWAYS, AND THEY READ THE WHOLE FILE. A lookup never opens a file on
-- the caller's tick: it registers a bounded want, answers `journal_pending`, and one shared
-- reader per account walks the files those ids derive from through the existing ECWallet
-- segmented reader (J.BYTES_PER_TICK bytes and W.HISTORY_LINES_PER_TICK lines per tick, whichever
-- comes first). It never stops at the first line it recognises: stopping there is how a successor
-- three rows further down gets missed, which is the whole bug this file exists for.
--
-- WHAT IS NEVER GUESSED. A file that exists and cannot be read (or a write this server knows
-- failed) is `journal_unreadable`; a matching line whose shape does not hold up, a contradicted
-- commit point or a broken chain order is `journal_malformed`; no line at all is
-- `journal_missing`; a line still in the export queue is not a missing line - every read waits
-- for X.readFence first, and a record enqueued after a read started re-queues instead of being
-- answered "missing".
--
-- The reply is a copy of the server's own replay. Whatever the client wrote into its pending
-- record - currency, price, unitPrice, snapshot, qty, origins, src, durable - never reaches it.
--
-- Engine references (snapshot 42.20.4-20260826):
--   getFileReader / readLine / close   LuaManager.java:5933-5963 (nil at EOF; close releases)
--   getTimestampMs                     LuaManager.java:9267-9272

if not MinidoracatEconomy or not MinidoracatEconomy.Wallet then
    require "MinidoracatEconomy/ECWallet"
end
if not MinidoracatEconomy or not MinidoracatEconomy.Recovery then
    require "MinidoracatEconomy/ECRecovery"
end
local EC = MinidoracatEconomy
local S = EC and EC.Server
local X = EC and EC.Export
local W = EC and EC.Wallet
local R = EC and EC.Recovery
if not S or not S.AUTHORITY or not X or not W or not R then
    return
end

EC.RecoveryJournal = EC.RecoveryJournal or {}
local J = EC.RecoveryJournal

J.LINE_TYPE = "recovery.journal"
J.VERSION = 2
J.COMMAND = "recovery.proof"        -- internal reader key; never a client command
J.MAX_READERS = 2                   -- proof jobs at once (the wallet pool of 8 is shared)
J.BYTES_PER_TICK = 65536
J.RESULT_TTL_MS = 20000             -- verdicts are a cache, not a record: they expire fast
J.MAX_PATHS = 4                     -- distinct month files one pass reads; the rest wait a pass
J.MAX_WANTED = R.PENDING_MAX        -- operations one account may have in flight anyway
J.MAX_RESULTS = R.PENDING_MAX
J.MIN_EPOCH_MS = 1262304000000      -- 2010-01-01: below this an epoch is not a usable file key
J.COPY_DEPTH = 6
J.SWEEP_MS = 1000                   -- how often the tick walks the tracked accounts
J.PACK_DEPTH = 6                    -- snapshot nesting a line may carry (Codec allows 3 in modData)
J.PACK_LEAVES_MAX = 128             -- scalar values a packed snapshot may carry

-- username -> { wanted, wantedCount, results, resultCount, job, notify }
local accounts = {}
local queue, queued = {}, {}        -- FIFO of accounts waiting for a reader slot
local notifyQueue = {}              -- accounts whose consumers are told on the next tick
local readers = 0
local lastSweep = 0
local listeners = {}

-- ---------- small helpers ----------

local function finiteNumber(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function positiveInt(v)
    return finiteNumber(v) and v > 0 and v == math.floor(v)
end

-- The month file of an operation, derived from the operation id alone, and the one place that
-- says whether an id is a server id at all: "<epoch>:<seq>" with a whole-millisecond epoch this
-- build could have started in and a positive whole seq. EC.parseId is the only parser - a second
-- one here would be a second opinion on what an id is. nil means there is no file to guess at,
-- and callers treat that as evidence they cannot read rather than evidence of absence.
local function journalPath(username, id)
    if type(username) ~= "string" or username == "" or type(id) ~= "string" then return nil end
    local epoch, seq = EC.parseId(id)
    if not positiveInt(seq) then return nil end
    local ms = epoch and tonumber(epoch) or nil
    if not positiveInt(ms) or ms < J.MIN_EPOCH_MS then return nil end
    return X.ROOT .. "/recovery/" .. EC.safeName(username) .. "/" .. EC.monthKey(ms) .. ".json"
end
J.journalPath = journalPath

local copyValue
copyValue = function(v, depth)
    if v == EC.JSON_NULL then return nil end
    if type(v) ~= "table" then return v end
    if depth >= J.COPY_DEPTH then return nil end
    local out = {}
    for k, item in pairs(v) do
        local c = copyValue(item, depth + 1)
        if c ~= nil then out[k] = c end
    end
    return out
end

-- ---------- snapshot wire form (journal version 2, report FR-11) ----------
--
-- The rest of the replay is integers and strings, which the shared JSON encoder writes back
-- exactly. A snapshot is not: it carries the item's modData, and Global ModData legitimately
-- holds NUMBER keys next to string keys (KahluaTableImpl stores a key type byte) and doubles
-- that are not integers. The shared encoder stringifies every key and prints non-integers with
-- six decimals - it is a display/event encoder, and using it as a replay codec silently turns
-- `{[0]="v"}` into `{["0"]="v"}` and rounds a float. The rebuilt item would then be missing the
-- other mod's data, and `contentKey` would not even notice, because both sides went through the
-- same lossy funnel.
--
-- So on the wire a snapshot is a sorted array of typed leaves, [path, tag, value]:
--   path   segments, "s:<key>" for a string key and "n:<text>" for a number key
--   tag    "s" string | "n" number | "b" boolean | "t" the empty table (no value)
--   value  the string, the number AS TEXT, or the boolean
-- Kahlua's number text preserves double precision (KahluaUtil.java:180-189,290-303).
-- Signed zero needs an explicit literal on both sides: tostring drops its sign, and
-- tonumber's BoxedStaticValues.toDouble cache returns positive zero (BoxedStaticValues.java:9-17).
-- Key TYPE is what the prefix carries, so a numeric-looking string key stays a string key and
-- `{[0]=...}` and `{["0"]=...}` remain two different entries instead of colliding.

local function numText(n)
    if n ~= n then return "nan" end
    if n == math.huge then return "inf" end
    if n == -math.huge then return "-inf" end
    if n == 0 and 1 / n == -math.huge then return "-0.0" end
    return tostring(n)
end

-- Accept numeric text without requiring this runtime's exact spelling.
-- Non-finite values and signed zero use the explicit forms emitted by numText.
local function numFromText(text)
    if type(text) ~= "string" or text == "" then return nil end
    if text == "nan" then return 0 / 0 end
    if text == "inf" then return math.huge end
    if text == "-inf" then return -math.huge end
    if text == "-0.0" then return -0.0 end
    local n = tonumber(text)
    if not finiteNumber(n) then return nil end
    return n
end

local function pathCopy(path)
    local out = {}
    for i = 1, #path do out[i] = path[i] end
    return out
end

local function pathLess(a, b)
    local na, nb = #a, #b
    local n = na < nb and na or nb
    for i = 1, n do
        if a[i] ~= b[i] then return a[i] < b[i] end
    end
    return na < nb
end

local function packLeaves(value, path, out, depth)
    if depth > J.PACK_DEPTH then return false end
    local empty = true
    for k, v in pairs(value) do
        empty = false
        local segment
        if type(k) == "string" then segment = "s:" .. k
        elseif type(k) == "number" then segment = "n:" .. numText(k)
        else return false end
        path[#path + 1] = segment
        local t = type(v)
        if t == "string" then out[#out + 1] = { pathCopy(path), "s", v }
        elseif t == "number" then out[#out + 1] = { pathCopy(path), "n", numText(v) }
        elseif t == "boolean" then out[#out + 1] = { pathCopy(path), "b", v }
        elseif t == "table" then
            if not packLeaves(v, path, out, depth + 1) then return false end
        else
            return false
        end
        path[#path] = nil
        if #out > J.PACK_LEAVES_MAX then return false end
    end
    -- A table with nothing in it is a fact of its own; a leaf cannot express it.
    if empty and #path > 0 then out[#out + 1] = { pathCopy(path), "t" } end
    return true
end

-- nil when the table holds something Global ModData could not hold anyway (Codec.copyModData
-- accepts exactly string/number/boolean/table) or is bigger than a snapshot may carry: the
-- caller then refuses instead of writing a record it cannot read back.
local function packTable(value)
    if value == nil then return nil, false end
    if type(value) ~= "table" then return nil, true end
    local out = {}
    if not packLeaves(value, {}, out, 1) then return nil, true end
    EC.sortSafe(out, function(a, b) return pathLess(a[1], b[1]) end)
    return out, false
end

local function unpackTable(leaves)
    if type(leaves) ~= "table" then return nil end
    local n = #leaves
    if n > J.PACK_LEAVES_MAX then return nil end
    local root, taken = {}, {}
    for i = 1, n do
        local entry = leaves[i]
        if type(entry) ~= "table" then return nil end
        local path, tag, value = entry[1], entry[2], entry[3]
        if type(path) ~= "table" or type(tag) ~= "string" then return nil end
        local depth = #path
        if depth < 1 or depth > J.PACK_DEPTH then return nil end
        local node, prefix = root, ""
        for d = 1, depth do
            local segment = path[d]
            if type(segment) ~= "string" then return nil end
            local kind, text = string.sub(segment, 1, 2), string.sub(segment, 3)
            local key
            if kind == "s:" then key = text
            elseif kind == "n:" then key = numFromText(text)
            else return nil end
            if key == nil then return nil end
            -- Length-framed, not separator-joined: a modData key may legally contain any byte,
            -- including whatever character a separator picked, and two different paths that
            -- joined to the same string would share a `taken` entry and refuse each other.
            prefix = prefix .. #segment .. ":" .. segment
            if d < depth then
                -- A path that runs through a leaf, or two entries claiming the same place, is a
                -- contradiction; the reader does not get to decide which one was meant.
                if taken[prefix] then return nil end
                local child = node[key]
                if child == nil then
                    child = {}
                    node[key] = child
                elseif type(child) ~= "table" then
                    return nil
                end
                node = child
            else
                if taken[prefix] or node[key] ~= nil then return nil end
                taken[prefix] = true
                if tag == "s" then
                    if type(value) ~= "string" then return nil end
                    node[key] = value
                elseif tag == "n" then
                    local number = numFromText(value)
                    if number == nil then return nil end
                    node[key] = number
                elseif tag == "b" then
                    if type(value) ~= "boolean" then return nil end
                    node[key] = value
                elseif tag == "t" then
                    if value ~= nil then return nil end
                    node[key] = {}
                else
                    return nil
                end
            end
        end
    end
    return root
end

-- The whole economic content of an operation, and nothing else: the commit point is excluded
-- because it is the one thing that legitimately differs between a save and the line it came from
-- (R.finishOut writes it back into the record after the fact). Encoded through the shared JSON
-- encoder, which sorts keys, so two records are the same record exactly when their keys are the
-- same string. Comparing strings is also what keeps a whole chain out of memory.
--
-- The snapshot goes through the packer first, on BOTH sides: the save's live table and the table
-- read back out of a line are compared in the one form that keeps key types and exact numbers.
-- A snapshot that cannot be packed has no comparable form, so the record cannot be matched.
local MATCH_FIELDS = { "protocol", "kind", "origins", "itemId", "itemIds", "qty",
    "lotQty", "price", "currency", "tradeSchema", "sku", "hours", "unitPrice", "unitQty",
    "count", "txRequestId", "at", "returnMailId", "originalKind" }

local function contentKey(rec)
    if type(rec) ~= "table" then return nil end
    local subset = {}
    for _, key in ipairs(MATCH_FIELDS) do subset[key] = rec[key] end
    local packed, failed = packTable(rec.snapshot)
    if failed then return nil end
    subset.snapshot = packed
    local encoded
    local ok = pcall(function() encoded = EC.jsonEncode(subset) end)
    if not ok or type(encoded) ~= "string" then return nil end
    return encoded
end

-- ---------- producer ----------

-- One line per committed transfer, built synchronously and handed to the existing export queue
-- (same budget, same fence, same month layout as the receipts). No forced save, no flush: the
-- caller keeps its receipt either way, and a false return is an admission that the evidence is
-- NOT durable - never a silent success.
function J.record(username, id, receipt, replay)
    if type(username) ~= "string" or username == "" then return false, "invalid_args" end
    if type(id) ~= "string" or id == "" then return false, "invalid_args" end
    if type(receipt) ~= "table" or type(replay) ~= "table" then return false, "invalid_args" end
    if not finiteNumber(receipt.at) or type(receipt.epoch) ~= "string" or receipt.epoch == ""
        or not finiteNumber(receipt.seq) then
        return false, "invalid_args"
    end
    local path = journalPath(username, id)
    if path == nil then return false, "invalid_args" end
    -- The wire copy is shallow on purpose: R.copyReplay is a shallow copy too, so `replay.snapshot`
    -- is the very table the receipt in Global ModData holds. Packing it in place would rewrite
    -- live server state into a transport form.
    local wire = {}
    for key, value in pairs(replay) do wire[key] = value end
    local packed, failed = packTable(replay.snapshot)
    if failed then
        EC.log("recovery journal snapshot cannot be represented for " .. id)
        return false, "journal_encode_failed"
    end
    wire.snapshot = packed
    local line = {
        type = J.LINE_TYPE, version = J.VERSION, opId = id, owner = username,
        kind = type(receipt.kind) == "string" and receipt.kind or nil,
        ref = (type(receipt.ref) == "string" or type(receipt.ref) == "number") and tostring(receipt.ref) or nil,
        outAt = receipt.at, epoch = receipt.epoch, seq = receipt.seq,
        replay = wire,
    }
    local encoded
    local ok = pcall(function() encoded = EC.jsonEncode(line) end)
    if not ok or type(encoded) ~= "string" or encoded == "" then
        EC.log("recovery journal encode failed for " .. id)
        return false, "journal_encode_failed"
    end
    X.enqueue(path, encoded)
    -- The queue drops the oldest lines on overflow and marks the path failed; a read of a failed
    -- path answers read_failed from then on. Either way this line is not durable evidence.
    local _, fenceError = X.fenceStatus(X.readFence({ path }))
    if fenceError then
        EC.log("recovery journal not queued for " .. id .. ": " .. tostring(fenceError))
        return false, "journal_write_failed"
    end
    local acct = accounts[username]
    if acct then
        -- A verdict taken before this write is stale evidence now, and a read already walking the
        -- file took its fence before this line was queued: "not seen" must not become "missing".
        if acct.results[id] ~= nil then
            acct.results[id] = nil
            acct.resultCount = acct.resultCount - 1
        end
        if acct.job and acct.job.ids[id] then acct.job.stale[id] = true end
    end
    return true
end

-- ---------- line validation ----------

local NUMBER_FIELDS = { "qty", "lotQty", "price", "unitPrice", "unitQty", "count", "hours",
    "at", "seq" }
local STRING_FIELDS = { "kind", "currency", "sku", "txRequestId", "returnMailId", "originalKind",
    "epoch" }

-- The replay has to be usable as the whole economic content of the rebuilt operation. Anything
-- this server cannot read in full is "unknown", and unknown is its own answer: the fields below
-- are checked for shape only, never repaired and never defaulted.
-- A discard is the one decision that legitimately produces nothing: it may carry no units at all,
-- and that emptiness must not be read as a broken record.
local function replayProblem(replay)
    if type(replay) ~= "table" then return "replay" end
    if tonumber(replay.protocol) ~= R.PROTOCOL then return "replay.protocol" end
    if type(replay.kind) ~= "string" or replay.kind == "" then return "replay.kind" end
    local discard = replay.kind == "discard"
    if not discard and type(replay.snapshot) ~= "table" then return "replay.snapshot" end
    if replay.snapshot ~= nil and type(replay.snapshot) ~= "table" then return "replay.snapshot" end
    local origins = replay.origins
    if origins ~= nil and type(origins) ~= "table" then return "replay.origins" end
    local n = origins and #origins or 0
    if n > R.ORIGINS_MAX then return "replay.origins" end
    if n == 0 and not discard then return "replay.origins" end
    for i = 1, n do
        local o = origins[i]
        if type(o) ~= "table" then return "replay.origins" end
        local token = o.unit
        if type(token) == "string" and token ~= "" then
            if o.mailId ~= nil and type(o.mailId) ~= "string" then return "replay.origins" end
        elseif not finiteNumber(o.nativeId) then
            return "replay.origins"
        end
    end
    if replay.itemIds ~= nil and type(replay.itemIds) ~= "table" then return "replay.itemIds" end
    for _, key in ipairs(NUMBER_FIELDS) do
        if replay[key] ~= nil and not finiteNumber(replay[key]) then return "replay." .. key end
    end
    for _, key in ipairs(STRING_FIELDS) do
        if replay[key] ~= nil and type(replay[key]) ~= "string" then return "replay." .. key end
    end
    if replay.qty ~= nil and not (positiveInt(replay.qty) or (discard and replay.qty == 0)) then
        return "replay.qty"
    end
    return nil
end

-- A decoded line that claims to be this operation's record. Returns the line, or nil plus the
-- field that failed and whether the failure is an owner conflict.
local function readLine(entry, username)
    if entry.type ~= J.LINE_TYPE then return nil, "type" end
    if tonumber(entry.version) ~= J.VERSION then return nil, "version" end
    if type(entry.owner) ~= "string" or entry.owner ~= username then return nil, "owner", true end
    if type(entry.epoch) ~= "string" or entry.epoch == "" then return nil, "epoch" end
    if not finiteNumber(entry.seq) then return nil, "seq" end
    if not finiteNumber(entry.outAt) then return nil, "outAt" end
    -- The snapshot comes back out of its typed wire form before anything looks at it, so every
    -- check below - and the rebuild the caller may do later - sees the item's own key types and
    -- exact numbers. A form this server cannot read back is not a record it can act on.
    if type(entry.replay) == "table" and entry.replay.snapshot ~= nil then
        local snapshot = unpackTable(entry.replay.snapshot)
        if snapshot == nil then return nil, "replay.snapshot" end
        entry.replay.snapshot = snapshot
    end
    local problem = replayProblem(entry.replay)
    if problem then return nil, problem end
    -- finishOut stamps the commit point into the replay it copies; a line whose two copies
    -- disagree is not a record this server wrote as it stands.
    if entry.replay.epoch ~= nil and entry.replay.epoch ~= entry.epoch then return nil, "replay.epoch" end
    if entry.replay.seq ~= nil and entry.replay.seq ~= entry.seq then return nil, "replay.seq" end
    -- The same goes for what the decision WAS. An envelope that says "discard" over a replay that
    -- still says "listing" describes two different decisions, and picking either one would be
    -- this reader inventing the one the producer failed to state (report FR-07).
    if type(entry.kind) == "string" and type(entry.replay.kind) == "string"
        and entry.kind ~= entry.replay.kind then
        return nil, "kind"
    end
    return { epoch = entry.epoch, seq = entry.seq, outAt = entry.outAt,
        kind = type(entry.kind) == "string" and entry.kind or entry.replay.kind,
        replay = entry.replay, key = contentKey(entry.replay) }
end

-- ---------- the chain ----------

-- One line of this operation, in file order. The state carries the successor, the last non-
-- discard replay behind it (what a manual review of a discarded operation is allowed to preview)
-- and whether any line matched the pending record - never the chain itself.
local function addLine(state, line)
    if state.bad or state.owner then return end
    local last = state.last
    if last == nil then
        state.last, state.count = line, 1
    elseif line.epoch == last.epoch and line.seq == last.seq then
        -- Same commit point: an identical rewrite is idempotent and says nothing new. Different
        -- content under one commit point is a contradiction, and picking one would be a guess.
        if line.key == nil or last.key == nil or line.key ~= last.key then
            state.bad = "chain.duplicate"
            state.duplicate = true
            return
        end
        return
    elseif line.seq > last.seq then
        if last.kind ~= "discard" then state.previous = last.replay end
        state.last, state.count = line, state.count + 1
    else
        -- A chain that goes backwards is not a history this server wrote: every producer bumps
        -- the sequence past the current successor before it commits.
        state.bad = "chain.order"
        return
    end
    if state.key ~= nil and line.key ~= nil and line.key == state.key then state.matched = true end
end

-- ---------- verdicts ----------

-- One name per fact: the commit point of the successor is serverEpoch/serverSeq, and nothing
-- else. This is a new interface with no caller to be compatible with, so it carries no aliases.
local function detailOf(res, id)
    local out = { opId = id, chain = res.chain, outAt = res.outAt,
        serverEpoch = res.epoch, serverSeq = res.seq }
    if res.record then out.record = copyValue(res.record, 0) end
    if res.previous then out.previous = copyValue(res.previous, 0) end
    return out
end

-- The answer for a verified operation. The successor travels in both cases, because an
-- administrator reviewing a mismatch has to see what the server wrote, not what the save claims;
-- an automatic path restores only when the reason is nil.
local function answer(res, id)
    local detail = detailOf(res, id)
    if res.matched then return detail.record, nil, detail end
    return detail.record, "journal_mismatch", detail
end

local function accountRec(username, create)
    local a = accounts[username]
    if a == nil and create then
        a = { wanted = {}, wantedCount = 0, results = {}, resultCount = 0, job = nil, notify = false }
        accounts[username] = a
    end
    return a
end

local function enqueueAccount(username)
    if queued[username] then return end
    queued[username] = true
    queue[#queue + 1] = username
end

local function dropResult(acct, id)
    if acct.results[id] ~= nil then
        acct.results[id] = nil
        acct.resultCount = acct.resultCount - 1
    end
end

local function expireResults(acct, now)
    local stale = {}
    for id, res in pairs(acct.results) do
        if now - res.at >= J.RESULT_TTL_MS then stale[#stale + 1] = id end
    end
    for _, id in ipairs(stale) do dropResult(acct, id) end
end

-- A dropped verdict is a cache miss (the read runs again), never an answer.
local function putResult(acct, id, res, now)
    res.at = now
    if acct.results[id] == nil then
        if acct.resultCount >= J.MAX_RESULTS then
            local oldestId, oldestAt = nil, nil
            for key, value in pairs(acct.results) do
                if oldestAt == nil or value.at < oldestAt then oldestId, oldestAt = key, value.at end
            end
            if oldestId then dropResult(acct, oldestId) end
        end
        acct.resultCount = acct.resultCount + 1
    end
    acct.results[id] = res
end

local function dropWant(acct, id)
    if acct.wanted[id] ~= nil then
        acct.wanted[id] = nil
        acct.wantedCount = acct.wantedCount - 1
    end
end

-- Everything this account has in flight goes away together: the work, the cached verdicts, any
-- result the read still walking the files would have produced - and the recovery side's tickets
-- and inventory rows for it. Those tickets are only ever retired by the mailbox drain, and a
-- read this session will never be told about cannot produce one: leaving them behind holds raw
-- rows of a player who left and, at R.PROOF_TICKETS_MAX, starves the accounts still here
-- (report FR-12).
local function forget(username)
    local acct = accounts[username]
    if acct == nil then return end
    if acct.job then acct.job.abandoned = true end
    accounts[username] = nil
    queued[username] = nil
    R.clearProofTickets(username)
end

-- The only read entry point. Never opens a file, never blocks, never answers from the pending
-- record: it either has server evidence for this very operation or it says why it has none.
--
-- A cached verdict is only served for the very content it was taken against (`askedKey`). A
-- pending whose content changed was never verified against the chain, and a warm cache is not
-- allowed to accept it: the entry is dropped and the files are read again.
function J.lookup(username, id, pending)
    if type(username) ~= "string" or username == "" or type(id) ~= "string" or id == "" then
        return nil, "journal_malformed", { note = "bad_args" }
    end
    if journalPath(username, id) == nil then
        return nil, "journal_malformed", { opId = id, note = "bad_op_id" }
    end
    local key = contentKey(pending)
    if key == nil then
        return nil, "journal_mismatch", { opId = id, note = "pending_unreadable" }
    end
    local now = EC.now()
    local acct = accounts[username]
    if acct then
        expireResults(acct, now)
        local res = acct.results[id]
        if res then
            if res.askedKey == key then
                if res.reason then return nil, res.reason, res.detail and copyValue(res.detail, 0) or { opId = id } end
                if res.owner then return nil, "journal_mismatch", { opId = id, owner = true } end
                return answer(res, id)
            end
            dropResult(acct, id)
        end
    end
    acct = accountRec(username, true)
    local want = acct.wanted[id]
    if want == nil then
        if acct.wantedCount >= J.MAX_WANTED then
            -- Every slot is already a read this account has in flight; this operation is picked
            -- up by the next pass. Work exists, so `pending` is the truth, not a parking space.
            return nil, "journal_pending", { opId = id, note = "queue_saturated" }
        end
        want = {}
        acct.wanted[id] = want
        acct.wantedCount = acct.wantedCount + 1
    end
    want.key = key
    enqueueAccount(username)
    return nil, "journal_pending", { opId = id }
end

-- ---------- reader ----------

-- One pass reads at most J.MAX_PATHS distinct month files, chosen by the ids themselves and read
-- oldest month first so the choice is deterministic. Operations whose file is not in this pass
-- stay wanted and are answered by the next one.
local function planPass(username, acct)
    local order = {}
    for id in pairs(acct.wanted) do order[#order + 1] = id end
    EC.sortSafe(order, function(a, b) return a < b end)
    local paths, byPath = {}, {}
    for _, id in ipairs(order) do
        local path = journalPath(username, id)
        if path ~= nil and byPath[path] == nil then
            if #paths >= J.MAX_PATHS then break end
            paths[#paths + 1] = path
            byPath[path] = true
        end
    end
    EC.sortSafe(paths, function(a, b) return a < b end)
    local ids, n = {}, 0
    for _, id in ipairs(order) do
        local path = journalPath(username, id)
        if path ~= nil and byPath[path] then
            ids[id] = true
            n = n + 1
        end
    end
    return paths, ids, n
end

-- Every file of this pass is read to its end: the successor of an operation is the LAST legal
-- line, so a read that stops at the first recognised row is exactly the bug this journal exists
-- to fix.
--
-- And every row is decoded and identified BEFORE it can be dismissed as "not the operation we
-- asked about". A row of this file that cannot say which operation it belongs to - no opId, no
-- envelope, `{}` - is damage, and damage that is skipped becomes "this operation has no record"
-- (which opens the manual acceptance door) or leaves an older ancestor standing as if it were
-- the last decision (report FR-10). So an unidentifiable row fails the whole read instead: the
-- answer becomes journal_unreadable, which shuts every door until a person looks at the file.
-- There is no cheap pre-filter here on purpose - a string match cannot prove a row it skips was
-- intact - and the per-tick byte budget is what keeps the full decode bounded.
local function projectorFor(job)
    return function(entry)
        local id = entry.opId
        -- "Not the operation we asked about" is only a safe conclusion for a row that names an
        -- operation at all. A non-empty but broken id ("x", "e:", a negative seq) names none, so
        -- letting it fall through to the wanted filter would file damage under "some other op" -
        -- and the op we came for would read as missing, or an older ancestor would stand as the
        -- last decision. The test is the same one that picks the file: a real server id.
        if entry.type ~= J.LINE_TYPE or type(id) ~= "string" or id == ""
            or journalPath(job.username, id) == nil then
            error("unidentifiable recovery journal row")
        end
        if not job.ids[id] then return nil end
        local state = job.chains[id]
        if state == nil then
            state = { count = 0, key = job.keys[id] }
            job.chains[id] = state
        end
        local line, field, ownerConflict = readLine(entry, job.username)
        if line == nil then
            if ownerConflict then state.owner = true
            elseif not state.bad then state.bad = field end
            return nil
        end
        addLine(state, line)
        return nil
    end
end

local function finishRead(job, reply)
    readers = math.max(0, readers - 1)
    local acct = accounts[job.username]
    if job.abandoned or acct == nil or acct.job ~= job then return end
    acct.job = nil
    -- The player who asked has to be the player who is told: a reconnect between the start and
    -- the end of the read is a different session, and nothing of this read carries over to it.
    local player = S.onlinePlayer(job.username)
    local same = false
    if player ~= nil and job.player ~= nil then
        local ok, equal = pcall(function() return player == job.player end)
        same = ok and equal == true
    end
    if not same then
        forget(job.username)
        return
    end
    local error_ = type(reply) == "table" and reply.error or nil
    if error_ == "busy" or error_ == "server_busy" then
        enqueueAccount(job.username)        -- the pool was full; the wants are untouched
        return
    end
    local now = EC.now()
    local unreadable = error_ ~= nil        -- read_failed (open failed, fence failed, broken row)
    for id in pairs(job.ids) do
        local want = acct.wanted[id]
        -- A want whose content changed while the read ran was verified against nothing.
        if want ~= nil and want.key == job.keys[id] then
            local state = job.chains[id]
            if unreadable then
                dropWant(acct, id)
                putResult(acct, id, { askedKey = want.key, reason = "journal_unreadable",
                    detail = { opId = id, note = tostring(error_) } }, now)
            elseif state == nil or (state.last == nil and not state.owner and not state.bad) then
                if job.stale[id] then
                    -- Its line was queued after this read took its fence. Not missing: unread.
                    enqueueAccount(job.username)
                else
                    dropWant(acct, id)
                    putResult(acct, id, { askedKey = want.key, reason = "journal_missing",
                        detail = { opId = id } }, now)
                end
            elseif state.owner then
                dropWant(acct, id)
                putResult(acct, id, { askedKey = want.key, owner = true }, now)
            elseif state.bad then
                dropWant(acct, id)
                putResult(acct, id, { askedKey = want.key, reason = "journal_malformed",
                    detail = { opId = id, field = state.bad, duplicate = state.duplicate } }, now)
            else
                dropWant(acct, id)
                putResult(acct, id, { askedKey = want.key, matched = state.matched == true,
                    record = state.last.replay, previous = state.last.kind == "discard" and state.previous or nil,
                    epoch = state.last.epoch, seq = state.last.seq, outAt = state.last.outAt,
                    chain = state.count }, now)
            end
        end
    end
    if not acct.notify then
        acct.notify = true
        notifyQueue[#notifyQueue + 1] = job.username
    end
    if acct.wantedCount > 0 then enqueueAccount(job.username) end
end

local function startRead(username)
    local acct = accounts[username]
    if acct == nil or acct.wantedCount == 0 or acct.job then return true end
    local player = S.onlinePlayer(username)
    if player == nil then
        forget(username)                    -- disconnected: the work and its results go with it
        return true
    end
    if not W.canStartRead(player, J.COMMAND) then return false end
    -- Every wanted id has a derivable path (J.lookup refuses the others), so a pass always has
    -- something to open; a plan that somehow came back empty still reads as "no line", which is
    -- the honest answer for an operation this server has no file for.
    local paths, ids = planPass(username, acct)
    local job = { username = username, player = player, ids = ids, keys = {}, chains = {},
        stale = {}, abandoned = false }
    for id in pairs(ids) do job.keys[id] = acct.wanted[id].key end
    acct.job = job
    readers = readers + 1
    -- strictJson: a damaged row in a financial file fails the read instead of being skipped.
    W.tail(player, J.COMMAND, paths, {}, projectorFor(job), true, {
        onComplete = function(reply) finishRead(job, reply) end,
        bytesPerTick = J.BYTES_PER_TICK,
    })
    return true
end

local function startReads()
    while readers < J.MAX_READERS and #queue > 0 do
        local username = queue[1]
        local acct = accounts[username]
        if acct == nil or acct.wantedCount == 0 or acct.job then
            table.remove(queue, 1)
            queued[username] = nil
        elseif startRead(username) then
            table.remove(queue, 1)
            queued[username] = nil
        else
            return                          -- reader pool busy; this account keeps its place
        end
    end
end

-- ---------- consumers ----------

-- fn(username, player): evidence for at least one operation of this account is now available (or
-- proved unavailable). This is a notification and nothing else - nothing here repairs, pays or
-- writes. The consumer re-reads the world and the player state itself, because a verdict taken
-- when the read started is not what anything is allowed to act on.
function J.onReady(fn)
    if type(fn) ~= "function" then return false end
    listeners[#listeners + 1] = fn
    return true
end

function J.status(username)
    local acct = type(username) == "string" and accounts[username] or nil
    return {
        wanted = acct and acct.wantedCount or 0,
        reading = acct ~= nil and acct.job ~= nil,
        results = acct and acct.resultCount or 0,
        readers = readers,
        queued = #queue,
    }
end

-- ---------- tick ----------

-- Order matters: expiry, then reads, then notifications. A lookup made from inside a callback
-- registers work for the next tick instead of extending this one - no read starts, completes and
-- re-enters reconcile within a single tick, and a busy pool can never turn into a retry loop.
--
-- The sweep (has this account gone offline, has a verdict expired) is throttled: it walks every
-- tracked account and asks the engine for each one, and nothing it does needs frame precision.
-- A read that finishes for a player who left is caught by the identity check in finishRead, not
-- by how often this runs.
function J.onTick()
    local now = EC.now()
    if now - lastSweep >= J.SWEEP_MS then
        lastSweep = now
        local names = {}
        for username in pairs(accounts) do names[#names + 1] = username end
        for _, username in ipairs(names) do
            local acct = accounts[username]
            if acct then
                expireResults(acct, now)
                if S.onlinePlayer(username) == nil then
                    forget(username)
                elseif acct.wantedCount > 0 and acct.job == nil then
                    enqueueAccount(username)
                end
            end
        end
    end
    startReads()
    if #notifyQueue == 0 then return end
    local batch = notifyQueue
    notifyQueue = {}
    for _, username in ipairs(batch) do
        local acct = accounts[username]
        if acct then acct.notify = false end
        local player = acct and S.onlinePlayer(username) or nil
        if player ~= nil then
            for _, fn in ipairs(listeners) do
                local ok, err = pcall(fn, username, player)
                if not ok then EC.log("recovery journal consumer failed: " .. tostring(err)) end
            end
        end
    end
end

function J.init()
    accounts, queue, queued, notifyQueue, readers, lastSweep = {}, {}, {}, {}, 0, 0
end

S.RecoveryJournal = J
S.onInit(J.init)
Events.OnTickEvenPaused.Add(J.onTick)

return J
