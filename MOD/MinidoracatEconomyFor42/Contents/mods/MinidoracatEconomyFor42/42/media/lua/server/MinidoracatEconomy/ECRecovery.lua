-- MinidoracatEconomyFor42 - asset conservation core (server authority; spec 19.7 rule three,
-- reassessment item 3). Internal module: the only supported entry points are the five M.* calls
-- re-exported by ECMailbox (beginOut / finishOut / abortOut / hasOut / recoveryStatus).
--
-- Why this exists. A listing rebuilt from a pending record after a world rollback is a new
-- physical copy. Rebuilding only conserves the world when the units that went into the operation
-- are not already represented somewhere else. Before this file a pending record carried no source
-- at all, so "cancel -> claim the letter -> list the same object again -> roll the world back
-- below the cancel" rebuilt the listing while the world had already restored the listing that
-- letter came from: five objects became six (.omc/tmp/reassess11-recovery-evidence.json).
--
-- THE UNIT TOKEN. A native item id is a locator, not an identity: Codec.rebuild mints a new
-- object (and the probe in .omc/tmp/asset-id-reuse-evidence.json shows an id can even come back
-- on a different object). So every unit this mod hands over carries a token minted once by the
-- letter that delivered it - "<mailId>#<n>" - and that token is what everything downstream is
-- keyed by. A redelivery re-stamps the same tokens onto fresh objects; a split delivery moves the
-- exact tokens of the confirmed subset onto the child letter and takes them out of the parent.
-- That is what keeps the hard case straight: hand over five, transfer two out, redeliver the
-- remaining three onto brand-new objects, transfer two of those out, then log in with the very
-- first save again - the four transferred tokens are recognised on those older objects and only
-- the one untransferred unit stays. Matching on native ids would have left ghosts.
-- A native id is still recorded, and it is the only key available for a unit that entered the mod
-- unstamped (an ordinary world item's first hand-over); that case is a locator match and says so.
--
-- Three durable pieces, and nothing else is invented:
--   1. origins  - a protocol 2 pending record carries one entry per physical unit: its token when
--                 the unit came out of this mod (with the letter, its owner, the parent letter of
--                 a split, the record the letter came back from and the epoch/seq of the claim),
--                 or its native id when the server observed it unstamped. A stamp it cannot read
--                 in full is "legacy" and is never downgraded to native - not knowing is its own
--                 answer.
--   2. receipts - md.recovery.ops[opId] is the world side of a committed transfer: which units it
--                 consumed and what it produced. It lives in Global ModData, so it rolls back
--                 exactly when the operation it describes rolls back, and it is keyed by the
--                 operation (a single "consumed" counter cannot say which operation was already
--                 applied). hasOut() is what stops a sold or cancelled listing from being
--                 resurrected by an older player save, however often the server restarts.
--                 Per-letter consumption also lands on the letter itself (entry.outUnits[token]),
--                 which is where the redelivery of a partly consumed letter gets its remainder.
--   3. held     - anything this server cannot prove either way stays exactly as it is and is
--                 counted. A held record is never dropped, never capped away and never hidden;
--                 only one that was resolved against an observation is ever retired, and the
--                 anomaly event stream keeps the trace even then.
--
-- Bounds, and what they are allowed to cost. A live operation is one pending record in the
-- player's own save plus one receipt; the pending cap (R.PENDING_MAX) is therefore the real
-- gate, and it refuses new work instead of evicting evidence. Receipts are not gated per
-- account - that only ever locked a busy session out of the market - they are retired by the
-- convergence protocol below and pruned, oldest closed first, under one world-wide ceiling.
-- Pruning raises a floor (md.recovery.floorAt): a pending older than the floor whose receipt
-- cannot be found is "forgotten", not "never happened", and is held instead of replayed.
--
-- Convergence (what closes a receipt without waiting for a restart). A receipt is closed the
-- moment this server watches the owner's save stop referring to the operation: the pending record
-- is gone, nothing the operation consumed is in the backpack, and what it produced is no longer
-- standing in the market. That observation can happen in the same uptime. It is not a deletion:
-- a later login from an older save that still carries the pending re-opens the receipt, and only
-- the world-wide ceiling ever drops a closed one, with an event line and the floor above.
--
-- Engine references (snapshot 42.20.4-20260826):
--   item:getID()                    InventoryItem.java:1663/1944 (saved with the item; a locator)
--   item:getModData()               InventoryItem.java:433-437 (saved with the item)
--   inv:AddItem / contains / Remove ItemContainer.java:458 / 630-632

if not MinidoracatEconomy or not MinidoracatEconomy.Export then
    require "MinidoracatEconomy/ECExport"
end
local EC = MinidoracatEconomy
local S = EC and EC.Server
local X = EC and EC.Export
if not S or not S.AUTHORITY or not X then
    return
end

EC.Recovery = EC.Recovery or {}
local R = EC.Recovery

R.PROTOCOL = 2
R.PENDING_MAX = 64            -- live operations one player save may carry; the real gate
R.ORIGINS_MAX = 100           -- units one operation may carry (Shop.ITEMS_PER_BUY_MAX)
R.OPS_MAX = 4000              -- world-wide receipts; refuses new work only if this is reached
R.OPS_PRUNE_AT = 3000         -- above this, closed receipts are pruned oldest first
R.OPS_PRUNE_TO = 2400
R.HELD_WARN = 64              -- one event line when an account passes it; never a drop
R.HELD_TTL_MS = 7 * 24 * 3600000   -- resolved held records are kept this long for the admin view
R.HELD_LIMIT = 64
R.SCAN_DEPTH = 3              -- backpack plus three levels of carried bags
R.RECLAIMS_MAX = 200          -- reclaimed copies an administrator can still restore; oldest dropped
R.TICK_EPS_MIN = 0.01         -- game hours: the narrowest tie band a save/commit comparison uses
R.EPS_WINDOW_MS = 60000       -- the per-tick hours step is the largest seen over about this long
R.STARTS_MAX = 128            -- session starts kept per login name
R.CLAIMED_HOLDS_PER_HOUR = 64 -- new receipt-less pend: holds one login may open per hour

local md = nil
local reserved, reservedCount, consumedIndex = {}, 0, {}
-- Process memory of the player sessions (see "player sessions" below).
local sessions, outAnchors, claimedHourly, unanchoredNoted = {}, {}, {}, {}
local epsProbe, epsProbeH, epsNow, epsPrev, epsAt = nil, nil, 0, 0, 0
-- Epochs whose ledger file this start could not read in full (ECMailbox harvest): what they held
-- is unknown, so nothing that happened up to them is decided from the ledger's silence.
local ledgerGaps = {}

-- ---------- resume tickets for cold proof reads ----------
--
-- R.judgePending is asked the same question by two very different callers: the login reconcile
-- (and an administrator's write-gated recheck), which is allowed to act on the answer, and the
-- administration page merely looking at a record, which is not. A cold journal read started by
-- the second kind must never turn into a repair when it completes: only a caller that passed
-- `opts.resume` leaves a ticket here, and only a ticket makes the journal's completion notice
-- schedule another reconcile. Process-local and bounded: a ticket is an intention to finish a
-- repair in this uptime, not durable state.
R.PROOF_TICKETS_MAX = 256
local proofTickets, proofTicketCount = {}, 0

-- A ticket is refreshed whenever the same operation has to wait again, and it carries a mark so
-- the drain can retire exactly the tickets it has already answered without throwing away one
-- the answering pass took anew.
local proofTicketMark = 0
local proofSightings = {}

function R.noteProofTicket(username, id)
    if type(username) ~= "string" or username == "" or type(id) ~= "string" or id == "" then return false end
    local owned = proofTickets[username]
    proofTicketMark = proofTicketMark + 1
    if owned and owned[id] then
        owned[id].mark = proofTicketMark
        return true
    end
    if proofTicketCount >= R.PROOF_TICKETS_MAX then
        EC.log("recovery proof tickets full; " .. username .. " will be judged again at the next login")
        return false
    end
    if not owned then
        owned = {}
        proofTickets[username] = owned
    end
    owned[id] = { mark = proofTicketMark }
    proofTicketCount = proofTicketCount + 1
    return true
end

function R.proofMark()
    return proofTicketMark
end

-- What this server could actually see when it started waiting: the rows of that inventory walk,
-- kept by reference and keyed by token and by locator. It is the raw walk, not a selection made
-- from the player's own record - a forged origin list must not be able to make the "before"
-- picture empty and the disappearance invisible. The walk is already bounded (R.SCAN_DEPTH), so
-- it is reused whole: nothing is capped away and then read as "never seen".
--
-- The rows are kept rather than copied because the server itself removes objects during a pass
-- (R.dropRow / R.removeUnit mark `row.gone`): a unit this server took away is not a unit that
-- vanished behind its back, and holding on it would stall legitimate convergence.
function R.noteProofScan(username, scan)
    if type(username) ~= "string" or username == "" or type(scan) ~= "table" then return false end
    local snap = proofSightings[username]
    if not snap then
        snap = { byToken = {}, byNative = {} }
        proofSightings[username] = snap
    end
    for token, row in pairs(scan.byToken or {}) do
        if type(token) == "string" then snap.byToken[token] = row end
    end
    for native, rows in pairs(scan.byId or {}) do
        local remembered = snap.byNative[native]
        if not remembered then
            remembered = {}
            snap.byNative[native] = remembered
        end
        for _, row in ipairs(rows) do
            local found = false
            for i, previous in ipairs(remembered) do
                if previous.item == row.item then
                    -- Keep the latest row while visible, so this pass's own removal marks it.
                    remembered[i], found = row, true
                    break
                end
            end
            if not found then remembered[#remembered + 1] = row end
        end
    end
    return true
end

-- Was this unit of the authoritative record in that walk, and is that sighting still standing?
--
-- Identity here is the same identity R.matchUnit uses, and for the same reason: a token names
-- exactly one unit, while a 32-bit locator is reused by the engine, so a locator only counts
-- when the object wearing it is the item type the record is about. Anything looser would read
-- "another item happens to carry that number" as "our unit was here and then vanished" and hold
-- a legitimate rebuild for ever (report FINAL-REC-D). A row this server removed itself in that
-- same pass is `gone` and does not count either.
function R.wasSighted(username, origin, expectedType)
    local snap = type(username) == "string" and proofSightings[username] or nil
    if not snap or type(origin) ~= "table" then return false end
    if type(origin.unit) == "string" then
        local row = snap.byToken[origin.unit]
        if type(row) == "table" then return row.gone ~= true end
        return false
    end
    if origin.nativeId == nil then return false end
    for _, row in ipairs(snap.byNative[origin.nativeId] or {}) do
        if row.gone ~= true and (expectedType == nil or row.fullType == expectedType) then return true end
    end
    return false
end

function R.hasProofTicket(username)
    local owned = type(username) == "string" and proofTickets[username] or nil
    if not owned then return false end
    for _ in pairs(owned) do return true end
    return false
end

-- Retire the tickets this drain has answered. `upto` is the mark taken before the answering
-- pass ran, so a ticket that pass took anew (a read that still has to finish) survives.
function R.clearProofTickets(username, upto)
    local owned = type(username) == "string" and proofTickets[username] or nil
    if not owned then
        if upto == nil and type(username) == "string" then proofSightings[username] = nil end
        return 0
    end
    local n, left = 0, false
    for id, ticket in pairs(owned) do
        if upto == nil or (ticket.mark or 0) <= upto then
            owned[id] = nil
            n = n + 1
        else
            left = true
        end
    end
    if not left then
        proofTickets[username] = nil
        proofSightings[username] = nil
    end
    proofTicketCount = math.max(0, proofTicketCount - n)
    return n
end

-- Is this unit key in the walk this pass just took?
function R.unitVisible(scan, key, expectedType)
    if type(scan) ~= "table" or type(key) ~= "string" then return false end
    if scan.byToken and scan.byToken[key] and not scan.byToken[key].gone then return true end
    local native = tonumber(string.match(key, "^n:(%-?%d+)$"))
    if native ~= nil then
        -- a locator is reused by the engine, so it only speaks for this record while the object
        -- wearing it is the item type the record is about (same rule as R.matchUnit)
        for _, row in ipairs((scan.byId and scan.byId[native]) or {}) do
            if not row.gone and (expectedType == nil or row.fullType == expectedType) then return true end
        end
    end
    return false
end

-- The units a previous pass saw leave. It lives in the held record of that operation, which is
-- the server's own state: it survives a relog, a restart and an administrator's recheck, so the
-- finding cannot be walked past by simply asking again. Returns a list (possibly empty).
function R.rememberedSightings(username, id)
    local held = R.heldRecord(username, "pend:" .. tostring(id))
    if not held or held.resolvedAt then return {} end
    if type(held.vanished) ~= "string" or held.vanished == "" then return {} end
    local out = {}
    for key in string.gmatch(held.vanished, "[^,]+") do out[#out + 1] = key end
    return out
end

-- ---------- the proof marker ----------
--
-- A record that may rebuild assets carries a mark, and the mark is this one private table. Its
-- identity is the whole test: a boolean, a string, or a table a player built are all different
-- values, so `proven = true` in a player's own pendingOuts blob proves nothing and nothing
-- copied out of a save can ever equal it. It costs no id and no sequence number - identity is
-- not something to spend world state on. REPLAY_FIELDS does not carry it, copyReplay drops it,
-- and the callers strip it before anything is stored; a mark that somehow did get persisted
-- would come back as a different table and fail closed.
local provenMark = {}

function R.markProven(record)
    if type(record) ~= "table" then return nil end
    record.proven = provenMark
    return record
end

function R.isProven(record)
    return type(record) == "table" and record.proven == provenMark
end

function R.stripProven(record)
    if type(record) == "table" then record.proven = nil end
end

-- The locator (type + engine id) is indexed for every unit that has one, not only legacy ones: an
-- older player save can bring back an unstamped copy of a native unit the world already moved
-- out, and the copy can change hands before anything removes it. Whoever holds it, R.consumer
-- then answers with the operation that consumed it instead of letting it be sold a second time.
local function indexReceipt(receipt)
    for _, unit in ipairs(receipt.units or {}) do
        if type(unit.t) == "string" then consumedIndex[unit.t] = receipt.id end
        if unit.n ~= nil and type(receipt.item) == "string" then
            consumedIndex["legacy:" .. receipt.item .. ":" .. tostring(unit.n)] = receipt.id
        end
    end
end

-- ---------- state ----------

function R.init(root)
    md = root
    local rec = type(root.recovery) == "table" and root.recovery or {}
    if type(rec.ops) ~= "table" then rec.ops = {} end
    if type(rec.owners) ~= "table" then rec.owners = {} end
    if type(rec.count) ~= "number" then rec.count = EC.countKeys(rec.ops) end
    if type(rec.floorAt) ~= "number" then rec.floorAt = 0 end
    if type(rec.floorCount) ~= "number" then rec.floorCount = 0 end
    if type(rec.reclaims) ~= "table" then rec.reclaims = {} end
    -- lives[login] = { life, seen, starts[], floor }; lost[login][mailId] = the claims the world
    -- lost (ECMailbox). `seen` is the life this world save itself watched begin: a life only the
    -- ledger harvest raised is not proof that the save that loads is that later character.
    if type(rec.lives) ~= "table" then rec.lives = {} end
    if type(rec.lost) ~= "table" then rec.lost = {} end
    for _, life in pairs(rec.lives) do
        if type(life) == "table" and tonumber(life.seen) == nil then life.seen = tonumber(life.life) or 0 end
    end
    root.recovery = rec
    reserved, reservedCount, consumedIndex = {}, 0, {}
    -- a new process has no player objects yet: every session starts over
    sessions, outAnchors, claimedHourly, unanchoredNoted = {}, {}, {}, {}
    epsProbe, epsProbeH, epsNow, epsPrev, epsAt = nil, nil, 0, 0, 0
    ledgerGaps, R.ledgerGapsAt = {}, nil
    for _, receipt in pairs(rec.ops) do indexReceipt(receipt) end
end

function R.ready()
    return md ~= nil and type(md.recovery) == "table"
end

-- A stale copy taken back at login, kept as what it was (a snapshot, not the object) so an
-- administrator can mail it back from the audit line if the removal turns out to be wrong.
-- Bounded: past RECLAIMS_MAX the oldest record goes, and its audit line then answers
-- reclaim_unknown instead of restoring. ponytail: O(n) oldest scan per insert, n <= 200 on a
-- path that runs after crashes only.
function R.noteReclaim(fields)
    local list = md.recovery.reclaims
    local id = S.newId()
    fields.at = EC.now()
    list[id] = fields
    local n, oldest, oldestAt = 0, nil, nil
    for key, r in pairs(list) do
        n = n + 1
        if oldest == nil or (r.at or 0) < oldestAt then oldest, oldestAt = key, r.at or 0 end
    end
    if n > R.RECLAIMS_MAX then list[oldest] = nil end
    return id
end

function R.reclaimRecord(id)
    if not R.ready() or type(id) ~= "string" then return nil end
    return md.recovery.reclaims[id]
end

local function ownerRec(username, create)
    if not R.ready() or type(username) ~= "string" or username == "" then return nil end
    local o = md.recovery.owners[username]
    if not o and create then
        o = { ops = {}, open = 0, held = {}, heldOpen = 0 }
        md.recovery.owners[username] = o
    end
    return o
end

-- "current" | "survived" | "rolledback" | "unknown", from the one epoch history reader.
function R.verdict(epoch, seq)
    if not md then return "unknown" end
    return S.epochVerdict(epoch, seq)
end

-- ---------- player save ----------

-- The retired claim-witness table (`claims`) is dropped on sight: the client can replace this
-- whole table (ObjectModDataPacket.java:61, KahluaTableImpl.java:292-294), so nothing it holds
-- decides a delivery any more. Only pendingOuts stays - as a pointer that makes the server look.
function R.playerData(player)
    local t = player:getModData()
    local p = t[EC.PLAYER_MODDATA_KEY]
    if type(p) ~= "table" then
        p = {}
        t[EC.PLAYER_MODDATA_KEY] = p
    end
    p.claims = nil
    if type(p.pendingOuts) ~= "table" then p.pendingOuts = {} end
    return p
end

local function transmit(player)
    pcall(function() player:transmitModData() end)
end
R.transmit = transmit

local function contains(inv, obj)
    if not inv then return false end
    local ok, v = pcall(function() return inv:contains(obj) end)
    return ok and v == true
end

local function nativeId(item)
    local ok, id = pcall(function() return item:getID() end)
    if ok and type(id) == "number" and id == id and id >= -2147483648 and id <= 2147483647
        and id == math.floor(id) then return id end
    return nil
end
R.nativeId = nativeId

local function nativeStamp(stamp)
    return type(stamp) == "table" and stamp.proto == R.PROTOCOL and stamp.src == "native"
        and type(stamp.unit) == "string" and type(stamp.owner) == "string"
        and type(stamp.epoch) == "string" and type(stamp.seq) == "number"
end

-- GENERATION ZERO. The stamp this mod wrote before unit tokens existed: a letter id, the claim
-- epoch/seq, and nothing else. It is recognised by its exact shape and never by "protocol 2 did
-- not parse" - a stamp that carries a protocol, a unit or an owner is a protocol 2 stamp this
-- server failed to read in full, and calling that generation zero would invent a source for it.
-- These stamps are finite: no build writes one any more.
function R.gen0Stamp(stamp)
    if type(stamp) ~= "table" then return false end
    for k in pairs(stamp) do
        if k ~= "mailId" and k ~= "txId" and k ~= "epoch" and k ~= "seq" then return false end
    end
    if type(stamp.mailId) ~= "string" or not EC.parseId(stamp.mailId) then return false end
    if type(stamp.epoch) ~= "string" or stamp.epoch == "" then return false end
    local seq = stamp.seq
    if type(seq) ~= "number" or seq ~= seq or seq == math.huge or seq ~= math.floor(seq) then return false end
    if stamp.txId ~= nil and type(stamp.txId) ~= "string" then return false end
    return true
end

-- The delivery stamp this mod writes onto an item it hands over. A protocol 2 stamp carries the
-- unit token, the letter and its owner, and the epoch/seq of the claim.
function R.stampOf(item)
    local ok, stamp = pcall(function()
        if item.hasModData and not item:hasModData() then return nil end
        return item:getModData()[EC.PLAYER_MODDATA_KEY]
    end)
    if not ok then return nil, false end
    if stamp == nil then return nil, true end
    if nativeStamp(stamp) then return stamp, true end
    if type(stamp) == "table" and type(stamp.mailId) == "string" then return stamp, true end
    return nil, false
end

-- The key every map in this module is indexed by: the unit token for a delivered unit, and
-- "n:<locator>" for a unit that entered the mod unstamped. Never nil.
local function originKey(origin)
    if type(origin) ~= "table" then return nil end
    if type(origin.unit) == "string" then return origin.unit end
    if origin.nativeId ~= nil then return "n:" .. tostring(origin.nativeId) end
    return nil
end
R.originKey = originKey

-- One physical unit the caller is about to move out. Returns origin, or nil plus the error code
-- and the refusal reason behind it (which of the two reads failed - they are different problems
-- with different next steps, and neither one says the item's type is broken).
-- An item whose id or modData this server cannot read is refused here - before the removal -
-- instead of being recorded as a source-less native unit.
function R.originOf(item)
    local id = nativeId(item)
    if id == nil then return nil, "recovery_unverified", "item_locator_unreadable" end
    local readable, stamp = pcall(function() return item:getModData()[EC.PLAYER_MODDATA_KEY] end)
    if not readable then return nil, "recovery_unverified", "item_stamp_unreadable" end
    if stamp == nil then return { src = "native", nativeId = id, item = item:getFullType() } end
    if nativeStamp(stamp) then
        return { src = "native", nativeId = id, item = item:getFullType(), unit = stamp.unit,
            owner = stamp.owner, epoch = stamp.epoch, seq = stamp.seq }
    end
    if type(stamp) ~= "table" or type(stamp.mailId) ~= "string" then
        return { src = "legacy", nativeId = id }
    end
    local o = {
        src = "mail", nativeId = id, unit = type(stamp.unit) == "string" and stamp.unit or nil,
        item = item:getFullType(),
        mailId = stamp.mailId,
        owner = type(stamp.owner) == "string" and stamp.owner or nil,
        epoch = type(stamp.epoch) == "string" and stamp.epoch or nil,
        seq = tonumber(stamp.seq),
        txId = type(stamp.txId) == "string" and stamp.txId or nil,
        parentMailId = type(stamp.parentMailId) == "string" and stamp.parentMailId or nil,
        srcRef = type(stamp.srcRef) == "string" and stamp.srcRef or nil,
        durable = stamp.durable == true,
    }
    if stamp.proto ~= R.PROTOCOL or o.unit == nil or o.owner == nil or o.epoch == nil or o.seq == nil then
        o.src = "legacy"
        if R.gen0Stamp(stamp) then o.gen0 = true end
    end
    return o
end

-- ---------- held records ----------

local function heldFields(fields)
    local out = {}
    for k, v in pairs(fields or {}) do
        local t = type(v)
        if t == "string" or t == "number" or t == "boolean" then out[k] = v end
    end
    return out
end

-- Idempotent by key: the same unresolved condition seen at every login is one record, not a
-- growing pile. An unresolved record is never dropped, never capped away and never hidden - the
-- keys are derived from records that are themselves bounded (this account's pending records, its
-- letters, its receipts), so the working set is bounded by construction, not by a cap that would
-- have to throw evidence away. Returns true when the working set changed.
function R.hold(username, key, reason, fields)
    local o = ownerRec(username, true)
    if not o or type(key) ~= "string" or key == "" then return false end
    local prev = o.held[key]
    if prev and not prev.resolvedAt then
        prev.seenAt = EC.now()
        return false
    end
    local rec = heldFields(fields)
    rec.key, rec.reason, rec.at, rec.seenAt = key, reason, EC.now(), EC.now()
    rec.resolvedAt = nil
    o.held[key] = rec
    o.heldOpen = o.heldOpen + 1
    if o.heldOpen == R.HELD_WARN then
        EC.log("recovery held for " .. username .. " reached " .. tostring(R.HELD_WARN) .. " records")
        X.emit("ledger.anomaly", { kind = "recovery", username = username, resolution = "held-many", count = o.heldOpen })
    end
    X.emit("ledger.anomaly", { kind = "recovery", username = username, resolution = "held", key = key, reason = reason,
        opId = rec.opId, mailId = rec.mailId, qty = rec.qty })
    EC.log("recovery hold " .. username .. " " .. key .. " (" .. tostring(reason) .. ")")
    return true
end

-- The same unresolved condition, with fresher evidence. R.hold deliberately keeps the record it
-- already made (a login loop must not stack rows), but an administrator still has to see the ids,
-- the quantity and the source state as they are now, not as they were at the first refusal. The
-- record keeps its original `at`, so the age of the problem is not reset by looking at it.
function R.holdUpdate(username, key, reason, fields)
    local o = ownerRec(username, false)
    local prev = o and o.held[key] or nil
    if not prev or prev.resolvedAt then return R.hold(username, key, reason, fields) end
    local rec = heldFields(fields)
    if rec.vanished == nil then
        rec.vanished = prev.vanished
        if type(prev.vanished) == "string" and prev.vanished ~= "" then
            rec.item = prev.item
        end
    end
    rec.key, rec.reason, rec.at, rec.seenAt = key, reason, prev.at, EC.now()
    o.held[key] = rec
    return true
end

-- Only ever called with an observation that the condition is gone. The record is kept (resolved)
-- for the admin view and the event line stays in the stream: a pruned record is not a record
-- that never existed. Only resolved records are ever retired, and only after the TTL.
function R.resolveHold(username, key, note)
    local o = ownerRec(username, false)
    local rec = o and o.held[key] or nil
    if not rec or rec.resolvedAt then return false end
    rec.resolvedAt = EC.now()
    rec.note = type(note) == "string" and note or nil
    o.heldOpen = math.max(0, o.heldOpen - 1)
    X.emit("ledger.anomaly", { kind = "recovery", username = username, resolution = "held-resolved", key = key, reason = rec.reason, note = rec.note })
    return true
end

function R.unresolvedOp(username, id)
    local owner = ownerRec(username, false)
    for _, held in pairs(owner and owner.held or {}) do
        if not held.resolvedAt and held.opId == id then return true end
    end
    return false
end

-- Unresolved records of one account, oldest first: what the admin reconciliation page lists.
function R.heldRecords(username)
    local out = {}
    local o = ownerRec(username, false)
    for _, rec in pairs(o and o.held or {}) do
        if not rec.resolvedAt then out[#out + 1] = rec end
    end
    EC.sortSafe(out, function(a, b) return (a.at or 0) < (b.at or 0) end)
    return out
end

function R.heldRecord(username, key)
    local o = ownerRec(username, false)
    return o and type(key) == "string" and o.held[key] or nil
end

-- An earlier build recorded one held row per physical nail of a generation zero letter. The
-- evidence did not change; where it is written did. Those rows are retired with a note naming the
-- group row that now carries them - nothing here claims an object disappeared, and the group row
-- lists the very ids the per-unit rows named.
function R.regroupUnitHolds(username, mailId, groupKey)
    local o = ownerRec(username, false)
    if not o or type(mailId) ~= "string" then return 0 end
    local prefix, stampKey, n = "unit:" .. mailId .. ":", "stamp:" .. mailId, 0
    for key, rec in pairs(o.held) do
        if not rec.resolvedAt and key ~= groupKey
            and (key == stampKey or string.sub(key, 1, #prefix) == prefix) then
            R.resolveHold(username, key, "regrouped:" .. groupKey)
            n = n + 1
        end
    end
    return n
end

-- A pend: record with no receipt behind it is the player's own claim about an operation (its
-- pendingOuts): nothing of the world backs it, so it never blocks new work (R.heldCount) and it
-- is closed - and dropped, the event line keeps it - the moment the claim is withdrawn.
local function claimedHold(key, rec)
    return string.sub(key, 1, 5) == "pend:" and (rec.opId == nil or R.receipt(rec.opId) == nil)
end
R.claimedHold = claimedHold

function R.resolveObserved(username, playerData, scan)
    if scan.failed then return end
    local owner = ownerRec(username, false)
    local gone = {}
    for key, held in pairs(owner and owner.held or {}) do
        if not held.resolvedAt and held.opId ~= nil and claimedHold(key, held)
            and playerData.pendingOuts[held.opId] == nil then
            gone[#gone + 1] = key
        end
    end
    for _, key in ipairs(gone) do
        R.resolveHold(username, key, "pending_gone")
        owner.held[key] = nil
    end
    for key, held in pairs(owner and owner.held or {}) do
        if not held.resolvedAt then
            local unit = held.unit
            if unit ~= nil and string.sub(key, 1, 5) == "unit:" then
                local row
                if type(unit) == "string" then
                    row = R.matchUnit(scan, { unit = unit })
                else
                    -- A legacy-stamped item still occupies its locator; matchUnit only accepts unstamped locators.
                    for _, candidate in ipairs(scan.byId[unit] or {}) do
                        if not candidate.gone then row = candidate; break end
                    end
                end
                if not row or row.gone then R.resolveHold(username, key, "no_conflicting_item") end
            elseif string.sub(key, 1, 10) == "duplicate:" then
                if not scan.duplicates[unit] then R.resolveHold(username, key, "single_unit") end
            elseif string.sub(key, 1, 6) == "abort:" and playerData.pendingOuts[held.opId] == nil then
                R.resolveHold(username, key, "returned")
            elseif string.sub(key, 1, 8) == "receipt:" and held.reason == "replay_unavailable" then
                -- This key carries whichever condition was written first, and an insured replay
                -- only answers one of them: the record that could not be copied into the save
                -- now is. A lookup nobody could run, or any other reason parked on the same key,
                -- says nothing about being insured and keeps its own reason.
                local receipt = R.receipt(held.opId)
                if receipt and (playerData.pendingOuts[held.opId] or R.receiptVerdict(receipt) == "survived") then
                    R.resolveHold(username, key, "protected")
                end
            end
        end
    end
end

-- Remove one observed object and prove it is gone: a call that did not throw is not a
-- postcondition, the container read is (ItemContainer.java:630-632). No held record is touched
-- here - the caller decides what a partial result means.
function R.dropRow(row)
    if row.gone then return true end
    local ok, err = pcall(function() row.container:Remove(row.item) end)
    local checked, present = pcall(function() return row.container:contains(row.item) end)
    if not checked or present ~= false then
        EC.log("recovery removal unconfirmed: " .. tostring(err) .. " (remove ok=" .. tostring(ok) .. ")")
        return false
    end
    row.gone = true
    local notified, notifyErr = pcall(sendRemoveItemFromContainer, row.container, row.item)
    if not notified then EC.log("recovery removal notification failed: " .. tostring(notifyErr)) end
    return true
end

-- What stops a removal the server would otherwise make: it never pulls an object out of an
-- equipment or hotbar slot, and never deletes a bag that still holds something. A state it
-- cannot read blocks as well.
function R.removalBlock(row)
    local ok, blocked = pcall(function()
        if row.item:isEquipped() or row.item:getAttachedSlot() > -1 then return "legacy_item_equipped" end
        if row.item.getInventory then
            local contents = row.item:getInventory()
            if contents and contents:getItems():size() > 0 then return "legacy_container_not_empty" end
        end
        return nil
    end)
    if not ok then return "legacy_item_unreadable" end
    return blocked
end

-- The automatic path. A legacy-stamped object is never removed here: this server cannot name its
-- source, so it is held instead. Removing one is an administrator's decision, taken against a
-- named set of ids with a written reason (admin.recovery), and it goes through R.dropRow.
function R.removeUnit(username, key, row, fields)
    if row.gone then return true end
    local origin = R.originOf(row.item)
    local allowed = origin ~= nil and origin.src == "mail" and not row.duplicate
    if not allowed then
        R.hold(username, key, row.duplicate and "duplicate_unit" or "stale_native_copy", fields)
        return false
    end
    if not R.dropRow(row) then
        R.hold(username, key, "remove_unconfirmed", fields)
        return false
    end
    R.resolveHold(username, key, "removed")
    return true
end

-- `traceable` counts only what the server itself can stand behind: the player's own claims
-- (claimedHold) are left out, so a flood of them cannot lock a player - or a victim whose save
-- someone else wrote - out of new work (held_limit_reached).
function R.heldCount(username, traceable)
    local o = ownerRec(username, false)
    if not o then return 0 end
    if not traceable then return o.heldOpen end
    local n = 0
    for key, rec in pairs(o.held) do
        if not rec.resolvedAt and not claimedHold(key, rec) then n = n + 1 end
    end
    return n
end

-- How many new claimed holds this login may still open in this pass: at most PENDING_MAX open
-- at once and CLAIMED_HOLDS_PER_HOUR new ones an hour (ECMailbox folds the rest into one
-- pend:overflow record). Returns the room and the hourly counter the caller spends from.
function R.claimedHoldRoom(username)
    local hour = math.floor(EC.now() / 3600000)
    local counter = claimedHourly[username]
    if counter == nil or counter.hour ~= hour then
        counter = { hour = hour, n = 0 }
        claimedHourly[username] = counter
    end
    local open = 0
    local o = ownerRec(username, false)
    for key, rec in pairs(o and o.held or {}) do
        if not rec.resolvedAt and claimedHold(key, rec) then open = open + 1 end
    end
    return math.min(R.PENDING_MAX - open, R.CLAIMED_HOLDS_PER_HOUR - counter.n), counter
end

function R.status(username)
    local player = S.onlineLogin(username)
    local data = player and player:getModData()[EC.PLAYER_MODDATA_KEY] or nil
    local pending = type(data) == "table" and data.pendingOuts or nil
    local durable = S.durableStatus()
    return { held = R.heldCount(username), open = type(pending) == "table" and EC.countKeys(pending) or 0,
        max = R.PENDING_MAX, durableSource = durable.source, durableStatus = durable.status, durableSeq = durable.seq }
end

-- ---------- player sessions and the rollback ledger (moddata trust boundary) ----------
--
-- The player's own modData is written by its client, wholesale: ObjectModDataPacket is handled
-- on the server (ObjectModDataPacket.java:25-26), its load wipes and replaces the table
-- (KahluaTableImpl.java:292-294) and objectType 2 resolves ANY online player
-- (MovingObject.java:111-113). So no decision below reads it. What decides is server data:
--   * a session is one server-side player object. Its h0 is the hoursSurvived the save was
--     loaded with (IsoPlayer.java:1230), taken on the first tick the object is seen; the server
--     only ever adds to it (GameTime.java:519, 540-546), so "save hours < claim hours" proves
--     the save was written before the claim.
--   * a claim is anchored on its letter (claimSess, claimHours, claimLife) in Global ModData.
--   * a life is a character of one login name: only a death of the main seat the server saw
--     (ECMailbox.onDeath) starts the next one (lives[login].life). A character made without a
--     death (a lifeBreak mark) is never taken as one: a reconnect is a new object of the same
--     character, so a letter the mark covers is refused its redelivery instead (ECMailbox).
--   * the ledger (ECRecoveryJournal, one file per epoch) keeps what a world rollback forgets:
--     claims, session starts and lives, written at the moment they happen. Global ModData only
--     reaches the disk with the world save (ServerMap.java:409); the file does not roll back.

local function hoursOf(player)
    local ok, h = pcall(function() return player:getHoursSurvived() end)
    if ok and type(h) == "number" and h == h and h >= 0 and h < math.huge then return h end
    return nil
end

local function ledger(fields)
    local J = S.RecoveryJournal
    if J ~= nil and type(J.ledger) == "function" then J.ledger(fields) end
end

-- Created by the per-tick first sighting (R.observeSessions); a lookup before that tick creates
-- it on the spot. A late creation only makes h0 larger, which only ever withholds a delivery.
function R.session(player)
    local s = sessions[player]
    if s == nil then
        local seq = S.nextSeq()
        s = { sid = EC.makeId(md.meta.epoch, seq), seq = seq, h0 = hoursOf(player), noted = {} }
        sessions[player] = s
    end
    return s
end

-- The largest per-tick hours step seen over the last minute or two (fast-forward widens it), and
-- never narrower than TICK_EPS_MIN. Hours advance by the same step for every player
-- (GameTime.java:540-546), so one probe player is enough.
function R.tickEps()
    local eps = epsNow > epsPrev and epsNow or epsPrev
    return eps > R.TICK_EPS_MIN and eps or R.TICK_EPS_MIN
end

local function lifeRec(login, create)
    local rec = md.recovery.lives[login]
    if type(rec) ~= "table" and create then
        rec = { life = 0, seen = 0, starts = {} }
        md.recovery.lives[login] = rec
    end
    return type(rec) == "table" and rec or nil
end

-- A ledger number written as text: the shared JSON encoder prints six decimals (ECCore), and an
-- hours value rounded up by that would read a tie as a fork. Kahlua's number text keeps the
-- double (see ECRecoveryJournal "snapshot wire form"); tonumber reads either form back.
local function numText(v)
    if type(v) ~= "number" then return nil end
    return tostring(v)
end
R.numText = numText

function R.life(login)
    local rec = type(login) == "string" and md ~= nil and lifeRec(login, false) or nil
    return rec and tonumber(rec.life) or 0
end

-- The next character of this login: the main seat died while the server watched (M.onDeath).
function R.newLife(login)
    local rec = lifeRec(login, true)
    rec.life = (tonumber(rec.life) or 0) + 1
    -- this world save watched the life begin (a death)
    rec.seen = rec.life
    ledger({ k = "life", l = login, s = S.nextSeq(), life = rec.life })
    return rec.life
end

-- Harvest: a life change the world rolled back is still a life change.
function R.raiseLife(login, life)
    if type(login) ~= "string" or type(life) ~= "number" then return end
    local rec = lifeRec(login, true)
    if life > (tonumber(rec.life) or 0) then rec.life = life end
end

-- (e, s) after (epoch, seq)? Epochs are the start wall clock; unreadable order counts as after.
local function later(e, s, epoch, seq)
    local a, b = tonumber(e), tonumber(epoch)
    if a == nil or b == nil then return true end
    if a ~= b then return a > b end
    return (tonumber(s) or 0) > (tonumber(seq) or 0)
end
R.later = later

-- Bounded per login name. The oldest start that has to go leaves its commit point behind as the
-- floor: a claim or transfer before the floor may have a fork this server no longer remembers,
-- so R.forkedAfter answers "unknown" for it instead of "no fork".
local function addStart(rec, start)
    if type(rec.starts) ~= "table" then rec.starts = {} end
    for _, st in ipairs(rec.starts) do
        if st.e == start.e and st.s == start.s then return end
    end
    rec.starts[#rec.starts + 1] = start
    if #rec.starts > R.STARTS_MAX then
        EC.sortSafe(rec.starts, function(a, b) return later(b.e, b.s, a.e, a.s) end)
        local gone = table.remove(rec.starts, 1)
        local floor = type(rec.floor) == "table" and rec.floor or nil
        if floor == nil or later(gone.e, gone.s, floor.e, floor.s) then rec.floor = { e = gone.e, s = gone.s } end
    end
end

-- A session of this login began: in the world (bounded, trimmed at start) and in the ledger. It
-- carries both the life counter and `seen`, the life this world save itself watched begin: when
-- only the ledger harvest raised the counter, the character that loaded may still be any of them.
function R.noteStart(login, s)
    local rec = lifeRec(login, true)
    s.life = tonumber(rec.life) or 0
    s.seen = math.min(tonumber(rec.seen) or s.life, s.life)
    addStart(rec, { e = md.meta.epoch, s = s.seq, h = s.h0, life = s.life, seen = s.seen })
    ledger({ k = "start", l = login, s = s.seq, h = numText(s.h0), life = s.life, sn = s.seen })
end

function R.harvestStart(login, start)
    if type(login) == "string" then addStart(lifeRec(login, true), start) end
end

-- Starts only matter inside the bounded epoch history (R.verdict answers "unknown" beyond it);
-- a floor in an epoch that left it is older than every commit point still judged.
function R.trimStarts()
    local keep, empty = { [md.meta.epoch] = true }, {}
    for _, h in ipairs(md.meta.history) do keep[h.epoch] = true end
    for login, rec in pairs(md.recovery.lives) do
        local starts = {}
        for _, st in ipairs(type(rec) == "table" and type(rec.starts) == "table" and rec.starts or {}) do
            if keep[st.e] then starts[#starts + 1] = st end
        end
        if type(rec) == "table" and type(rec.floor) == "table" and not keep[rec.floor.e] then rec.floor = nil end
        if type(rec) ~= "table" or (#starts == 0 and rec.floor == nil and (tonumber(rec.life) or 0) == 0) then
            empty[#empty + 1] = login
        else
            rec.starts = starts
        end
    end
    for _, login in ipairs(empty) do md.recovery.lives[login] = nil end
end

-- Did a save of this life load at or below `bound` hours after (epoch, seq)? That session started
-- from a save older than the claim or transfer at (epoch, seq), so every later save of that life
-- may lack it, whatever hours it reached since. `inclusive` false leaves an equal start out.
-- A start whose character was not proven (seen < life) may be any life in between and counts for
-- each of them. true | false | "unknown" (a start after the commit was trimmed: the floor).
function R.forkedAfter(login, life, epoch, seq, bound, inclusive)
    local rec = lifeRec(login, false)
    for _, st in ipairs(rec and type(rec.starts) == "table" and rec.starts or {}) do
        local h = tonumber(st.h) or -1
        local top = tonumber(st.life) or 0
        local low = math.min(tonumber(st.seen) or top, top)
        if low <= life and life <= top and later(st.e, st.s, epoch, seq)
            and (h < bound or (inclusive and h == bound)) then
            return true
        end
    end
    local floor = rec and type(rec.floor) == "table" and rec.floor or nil
    if floor ~= nil and later(floor.e, floor.s, epoch, seq) then return "unknown" end
    return false
end

-- Ledger files this start could not read in full (ECMailbox harvest), and the question every
-- ledger-backed decision asks: may something up to `epoch` be missing from what was read?
function R.setLedgerGaps(gaps)
    ledgerGaps = type(gaps) == "table" and gaps or {}
    R.ledgerGapsAt = EC.now()
end

-- For the admin System page: every epoch whose ledger could not be read in full, oldest first,
-- with why and when this start found it (the harvest runs once, at start).
function R.ledgerGaps()
    local out = {}
    for epoch, why in pairs(ledgerGaps) do
        out[#out + 1] = { epoch = epoch, reason = type(why) == "string" and why or "incomplete", at = R.ledgerGapsAt }
    end
    EC.sortSafe(out, function(a, b) return tostring(a.epoch) < tostring(b.epoch) end)
    return out
end

function R.ledgerGap(epoch)
    local n = tonumber(epoch)
    for gap in pairs(ledgerGaps) do
        local g = tonumber(gap)
        if n == nil or g == nil or n <= g then return gap end
    end
    return nil
end

-- The claims the world lost for one login (ECMailbox owns their meaning).
function R.lostClaims(login, create)
    local lost = md.recovery.lost
    local mine = lost[login]
    if type(mine) ~= "table" then
        mine = nil
        if create then mine = {}; lost[login] = mine end
    end
    return mine
end

-- The anchor of a claim. From evidence (a stamp, a reattached unit) the true claim moment is
-- unknown, only that it is not after this save: 0 = "every save of this life has it". A live
-- claim is also written to the ledger, so a world rollback cannot forget that it happened.
function R.anchorClaim(entry, player, login, fromProof)
    entry.claimSess = R.session(player).sid
    entry.claimHours = (not fromProof) and hoursOf(player) or 0
    entry.claimLife = R.life(login)
    entry.lifeBreak = nil
    if not fromProof then
        local child = type(entry.parentMailId) == "string"
        ledger({ k = "claim", l = login, m = entry.id, o = entry.owner, s = entry.claimSeq,
            h = numText(entry.claimHours), life = entry.claimLife, p = child and entry.parentMailId or nil,
            u = child and entry.units or nil })
    end
end

-- "contained" | "predates" | "tie" | "unanchored": may this save lack that claim?
function R.claimOrder(entry, player)
    local s = R.session(player)
    if entry.claimSess ~= nil and entry.claimSess == s.sid then return "contained" end
    local h = tonumber(entry.claimHours)
    if h == nil or s.h0 == nil then return "unanchored" end
    if s.h0 > h then return "contained" end
    if s.h0 < h then return "predates" end
    return "tie"
end

-- Is the transfer whose first journal line is `first` inside the save this login loaded?
-- "contained" | "excluded" | "tie" | "unanchored" (a line written before anchors existed) |
-- "life_unproven" (only the ledger says that life ended: the save may be the old character) |
-- "ledger_incomplete" (a ledger file up to the commit could not be read).
-- A transfer of a life this world save did not watch begin or end (life >= seen while seen <
-- lifeNow: its own life, or a later one only the ledger knows, including the current one) is
-- always life_unproven: the save may be that character or another, and hours of two characters
-- are not one clock, so neither "past the commit" nor "below it" proves anything.
-- Otherwise (life == seen == lifeNow) the save's hours must be past the commit by more than a
-- tick. No start of the transfer's life after its commit may have loaded a save at or below it
-- (a fork); a trimmed start is a fork nobody can rule out.
-- The second value says how an "excluded" was reached: "hours" (this save loaded below the
-- commit, same life) and "fork" (a recorded start of that life loaded below it) are proof the
-- save never had the transfer; "floor" (only a trimmed start could be one) and "life_ahead" are
-- not - like "tie", they only fail to prove it has it.
function R.outOrder(login, first, player)
    local h = type(first) == "table" and tonumber(first.h) or nil
    if h == nil then return "unanchored" end
    if R.ledgerGap(first.epoch) then return "ledger_incomplete" end
    local rec = lifeRec(login, false)
    local lifeNow = rec and tonumber(rec.life) or 0
    local seen = rec and math.min(tonumber(rec.seen) or lifeNow, lifeNow) or 0
    local life, eps = tonumber(first.life) or 0, R.tickEps()
    if life > lifeNow then return "excluded", "life_ahead" end
    if seen < lifeNow and life >= seen then return "life_unproven" end
    local order, why = "contained", nil
    if life >= seen then
        local p = player or S.onlineLogin(login)
        local h0 = p and R.session(p).h0 or nil
        if h0 == nil or (h0 <= h + eps and h0 >= h - eps) then order = "tie"
        elseif h0 < h - eps then order, why = "excluded", "hours" end
    end
    if order == "contained" then
        local fork = R.forkedAfter(login, life, first.epoch, first.seq, h + eps, true)
        if fork == true then order, why = "excluded", "fork"
        elseif fork == "unknown" then order, why = "excluded", "floor" end
    end
    return order, why
end

-- Once per tick (ECMailbox.onTick): every online object gets its session on the first tick it
-- is seen, and `onFirst(player, login, session)` runs once its login name is verified (retried
-- once a second until then). Cheap for the common case: one table lookup per player, plus one
-- hours read of a single probe player for the tick step.
function R.observeSessions(onFirst)
    local players = S.seats()
    if not players or not md then return end
    local now = EC.now()
    if now - epsAt >= R.EPS_WINDOW_MS then epsPrev, epsNow, epsAt = epsNow, 0, now end
    local probeSeen = false
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p ~= nil then
            local s = sessions[p] or R.session(p)
            if p == epsProbe then
                probeSeen = true
                local h = hoursOf(p)
                if h ~= nil and epsProbeH ~= nil and h - epsProbeH > epsNow then epsNow = h - epsProbeH end
                epsProbeH = h
            end
            if not s.proved and (s.tryAt == nil or now - s.tryAt >= 1000) then
                s.tryAt = now
                local ok, login = pcall(S.login, p)
                if ok and type(login) == "string" then
                    local done, err = pcall(onFirst, p, login, s)
                    if not done then EC.log("first sighting failed for " .. login .. ": " .. tostring(err)) end
                else
                    -- an object the binding does not vouch for keeps the name its seat may be
                    -- held to for a death nobody processed (R.unsettledDeaths): the same rules as
                    -- an unverified death, refreshed with every retry (a rename flag clears it)
                    local Id = S.Identity
                    local okSeat, name = pcall(function() return Id and Id.seatName(p) or nil end)
                    s.seat = okSeat and type(name) == "string" and name or nil
                end
            end
        end
    end
    if not probeSeen then
        epsProbe = players:size() > 0 and players:get(0) or nil
        epsProbeH = epsProbe and hoursOf(epsProbe) or nil
    end
end

-- Objects of `login` this process still knows (sessions are pruned each minute) whose character
-- is dead but whose death M.onDeath never processed (s.died). A seat can be taken over by
-- ConnectCoop between the frame BodyDamage set health 0 and the next one where die() fires
-- OnCharacterDeath (IsoGameCharacter.java:9054 vs :9177-9179): ConnectCoopPacket.java:69 only
-- asks isDead() and :94 disconnectPlayer removes the object, so that event may never come.
-- An object verified at its first sighting counts under s.login; one never verified under the
-- seat name it last showed (s.seat, Id.seatName), and is reported unverified.
-- `except` is the object asking (the new one). Returns { { player, unverified } }.
local function deadUnprocessed(p, s)
    if s.died then return false end
    local ok, dead = pcall(function() return p:isDead() end)
    return ok and dead == true
end

function R.unsettledDeaths(login, except)
    local out = {}
    for p, s in pairs(sessions) do
        if p ~= except and (s.login == login or (s.login == nil and s.seat == login)) and deadUnprocessed(p, s) then
            out[#out + 1] = { player = p, unverified = s.login == nil }
        end
    end
    return out
end

-- On the minute clock: forget the objects that left. A departing object that is dead and whose
-- death nobody processed is handed to `onDeadGone(player, name, session, unverified)` first, so a
-- prune that runs before the login's next object is seen does not lose that death.
function R.pruneSessions(onDeadGone)
    local players, online, gone = S.seats(), {}, {}
    for i = 0, (players and players:size() or 0) - 1 do
        local p = players:get(i)
        if p ~= nil then online[p] = true end
    end
    for p in pairs(sessions) do
        if not online[p] then gone[#gone + 1] = p end
    end
    for _, p in ipairs(gone) do
        local s = sessions[p]
        local name = type(s.login) == "string" and s.login or s.seat
        if onDeadGone ~= nil and type(name) == "string" and deadUnprocessed(p, s) then
            local ok, err = pcall(onDeadGone, p, name, s, s.login == nil)
            if not ok then EC.log("unseen death of " .. name .. " failed: " .. tostring(err)) end
        end
        sessions[p] = nil
    end
end

-- One event per operation per process for a journal line older than the anchors.
function R.noteUnanchored(username, id)
    if unanchoredNoted[id] then return end
    unanchoredNoted[id] = true
    X.emit("ledger.anomaly", { kind = "recovery", username = username, opId = id, resolution = "journal-unanchored" })
end

-- ---------- transfer receipts ----------

function R.receipt(id)
    if not R.ready() or type(id) ~= "string" then return nil end
    return md.recovery.ops[id]
end

function R.hasOut(id)
    return R.receipt(id) ~= nil
end

function R.receiptVerdict(receipt)
    if type(receipt) ~= "table" then return "unknown" end
    -- A world-side record carried in from a previous process is itself persistence evidence.
    if receipt.epoch ~= md.meta.epoch and type(receipt.seq) == "number"
        and receipt.seq <= md.meta.loadedSeq then return "survived" end
    return R.verdict(receipt.epoch, receipt.seq)
end

-- Below this timestamp the absence of a receipt proves nothing: a closed receipt that old may
-- have been pruned under the world-wide ceiling. Callers hold instead of replaying.
function R.forgotten(at)
    if not R.ready() then return false end
    local t = tonumber(at)
    if t == nil then return (md.recovery.floorAt or 0) > 0 end
    return t <= (md.recovery.floorAt or 0)
end

-- Admission is reserved before an operation can move assets; nested ledger listeners cannot steal it.
function R.reserveOut(username, id)
    if not R.ready() then return false, "recovery_unverified" end
    if R.receipt(id) or reserved[id] then return true end
    R.prune(EC.now())
    if md.recovery.count + reservedCount >= R.OPS_MAX then
        -- The table is full of records this server no longer needs to keep: receipts it already
        -- watched converge, in epochs that have left the bounded history. Reclaiming them raises
        -- the retention floor, so nothing they used to guard can come back unnoticed. Only after
        -- that does a full table mean full: an operation that never converged is never dropped
        -- to make room for a new one.
        R.reclaimClosed(R.OPS_PRUNE_TO, R.OPS_PRUNE_TO)
    end
    if md.recovery.count + reservedCount >= R.OPS_MAX then return false, "recovery_capacity" end
    reserved[id], reservedCount = username, reservedCount + 1
    return true
end

function R.releaseOut(id)
    if reserved[id] then reserved[id], reservedCount = nil, math.max(0, reservedCount - 1) end
    outAnchors[id] = nil
end

-- `currency` and `tradeSchema` travel with a replayed operation: a listing, an auction or a
-- buyback that comes back after a rollback comes back in the money it was made in, and the
-- schema mark is what keeps a record that never named one from being read as a legacy single
-- currency record (spec contract 12 / 13). There is deliberately no time hint here: the journal
-- file of an operation is derived from the operation id alone, so nothing a player carries can
-- steer which file - or which successor line - this server reads.
local REPLAY_FIELDS = { "protocol", "origins", "itemId", "itemIds", "snapshot", "kind", "qty", "lotQty",
    "price", "currency", "tradeSchema", "sku", "hours", "unitPrice", "unitQty", "count", "txRequestId",
    "epoch", "seq", "at", "returnMailId", "originalKind" }
function R.copyReplay(rec)
    local copy = {}
    for _, key in ipairs(REPLAY_FIELDS) do copy[key] = rec[key] end
    return copy
end

-- The source mail retains its consumption proof even after a closed global receipt is pruned.
function R.consumer(origin)
    if type(origin) ~= "table" then return nil end
    if type(origin.unit) == "string" then
        local id = consumedIndex[origin.unit]
        if id then return id, R.receipt(id) end
        -- Failure to read consumption evidence is a third state, never a consuming operation.
        local Mb = S.Mailbox
        if Mb == nil or type(Mb.entryOf) ~= "function" then
            EC.log("recovery consumption check unavailable: mailbox module missing")
            return nil, nil, "unreadable"
        end
        local readable, source = pcall(Mb.entryOf, origin.owner, origin.mailId)
        if not readable then
            EC.log("recovery consumption check failed for letter " .. tostring(origin.mailId))
            return nil, nil, "unreadable"
        end
        id = source and source.outUnits and source.outUnits[origin.unit] or nil
        if id then return id, R.receipt(id) or (source.outProof and source.outProof[id]) end
    end
    local locator = (origin.gen0 == true or origin.src == "native") and origin.nativeId
        or (type(origin.unit) == "string" and tonumber(string.match(origin.unit, "#L(%-?%d+)$")))
    if locator ~= nil and type(origin.item) == "string" then
        local id = consumedIndex["legacy:" .. origin.item .. ":" .. tostring(locator)]
        if id then return id, R.receipt(id), "locator" end
    end
    return nil
end

-- What a receipt has to remember about a unit: its token (identity) and the letter it came from,
-- or its native locator when that is all there ever was. The claim epoch/seq were judged when the
-- operation was accepted and are not re-litigated here.
local function compactOrigins(origins, owner)
    local out = {}
    for _, o in ipairs(type(origins) == "table" and origins or {}) do
        if #out >= R.ORIGINS_MAX then break end
        if type(o) == "table" then
            local c = nil
            if type(o.unit) == "string" then
                c = { t = o.unit, m = o.mailId }
                if o.src == "native" then c.n = o.nativeId end
                if type(o.owner) == "string" and o.owner ~= owner then c.o = o.owner end
            elseif o.nativeId ~= nil then
                c = { n = o.nativeId }
                if o.src == "legacy" then
                    c.l = true
                    c.m = o.mailId
                end
            end
            if c then out[#out + 1] = c end
        end
    end
    return out
end

-- Mark the source letters of a committed transfer, by token. The delivered unit left the mailbox
-- for good, so a later login from an older save is handed only the units that are still the
-- letter's own. Keyed by token, so the mark is idempotent however often it is applied.
local function markSources(username, receipt)
    local Mb = S.Mailbox
    if not Mb or not Mb.entryOf then return end
    for _, c in ipairs(receipt.units or {}) do
        if type(c.t) == "string" and type(c.m) == "string" then
            local entry = Mb.entryOf(type(c.o) == "string" and c.o or username, c.m)
            if entry then
                entry.outProof = entry.outProof or {}
                entry.outProof[receipt.id] = { epoch = receipt.epoch, seq = receipt.seq }
                -- A generation zero unit was named into this letter by a binding the world may
                -- since have rolled back below. Its consumption is being recorded right now, so
                -- its membership has to exist as well, or availableUnits would subtract nothing
                -- and offer the unit again. The admission gate is the same one the binding used;
                -- callers prove it before they commit (R.originState / R.beginOut), so a refusal
                -- here is an invariant break and is held, never papered over.
                if R.gen0Unit(c.t) then
                    local placed, slotError = R.gen0Admit(entry, c.t, entry.claimSeq, nil, true)
                    if not placed then
                        R.hold(entry.owner or username, "legacy:" .. c.m, slotError or "legacy_slot_unavailable",
                            { mailId = c.m, kind = "legacy", item = entry.item, opId = receipt.id,
                              detail = "consumption recorded without a slot to account for it" })
                    end
                end
                if type(entry.outUnits) ~= "table" then entry.outUnits = {} end
                if entry.outUnits[c.t] == nil then
                    entry.outUnits[c.t] = receipt.id
                    entry.outQty = (tonumber(entry.outQty) or 0) + 1
                end
            end
        end
    end
end

-- The world side of a committed transfer. Idempotent by operation id: a retry, a restore that ran
-- twice, or a second finishOut from a recovery path updates the reference and consumes nothing a
-- second time.
function R.finishOut(username, id, rec, kind, ref)
    if not R.ready() then return false, "recovery_unverified" end
    if type(username) ~= "string" or username == "" or type(id) ~= "string" or id == "" then
        return false, "recovery_unverified"
    end
    local ops = md.recovery.ops
    local prev = ops[id]
    if prev then
        if prev.ref == nil and (type(ref) == "string" or type(ref) == "number") then prev.ref = tostring(ref) end
        if prev.kind == nil and type(kind) == "string" then prev.kind = kind end
        return true
    end
    if not reserved[id] then return false, "recovery_unverified" end
    local o = ownerRec(username, true)
    local units = compactOrigins(rec and rec.origins, username)
    local receipt = {
        id = id, owner = username, kind = type(kind) == "string" and kind or nil,
        ref = (type(ref) == "string" or type(ref) == "number") and tostring(ref) or nil,
        epoch = md.meta.epoch, seq = S.nextSeq(), at = EC.now(),
        qty = tonumber(rec and rec.qty) or #units,
        lotQty = tonumber(rec and rec.lotQty) or nil,
        item = type(rec.snapshot) == "table" and rec.snapshot.type or nil,
        protocol = tonumber(rec and rec.protocol) or nil,
        units = units,
        replay = R.copyReplay(rec),
    }
    ops[id] = receipt
    local anchor = outAnchors[id]
    R.releaseOut(id)
    receipt.replay.epoch, receipt.replay.seq = receipt.epoch, receipt.seq
    rec.epoch, rec.seq = receipt.epoch, receipt.seq
    -- The authoritative record of what this operation moved. It is written at the one server
    -- commit point, from the server's own `rec`, so a rollback can be rebuilt without ever
    -- reading the economics out of a player save (report CORE-H1). Where that line lives is
    -- derived from the operation id alone, so no hint from the player's record is written here.
    local J = S.RecoveryJournal
    if J == nil or type(J.record) ~= "function" then
        receipt.journal = "unavailable"
        EC.log("recovery journal module missing: " .. id .. " has no durable replay evidence")
        X.emit("ledger.anomaly", { kind = "recovery", username = username, opId = id,
            resolution = "journal-unavailable" })
    else
        local wrote, journalError = J.record(username, id, receipt, R.copyReplay(rec), anchor)
        if wrote then
            receipt.journal = "queued"
        else
            -- the world side is committed and the receipt stays; what is not true is that the
            -- evidence is durable, and that is said out loud instead of assumed
            receipt.journal = "failed"
            EC.log("recovery journal not written for " .. id .. ": " .. tostring(journalError))
            X.emit("ledger.anomaly", { kind = "recovery", username = username, opId = id,
                resolution = "journal-not-written", reason = tostring(journalError) })
        end
    end
    indexReceipt(receipt)
    md.recovery.count = md.recovery.count + 1
    o.ops[id] = true
    o.open = o.open + 1
    markSources(username, receipt)
    X.emit("recovery.out", { username = username, opId = id, kind = receipt.kind, ref = receipt.ref,
        qty = receipt.qty, units = #units })
    R.resolveHold(username, "receipt:" .. id, "committed")
    return true
end

-- discard: the operation is declared void against the *world*, not merely deleted from one
-- player save. finishOut writes the receipt with nothing in it, so hasOut answers true from now
-- on and an older save that logs in with the same pending record finds it closed (judgePending,
-- receipt kind "discard") instead of resurrecting it at every login. One function for the
-- administrator's discard (ECAdmin) and the automatic one of a pending the save never had
-- (ECMailbox reconcileOuts, pending_not_in_save).
function R.discardPending(username, target, opId, pend, proof, successorSeq)
    local admitted, admissionError = R.reserveOut(username, opId)
    if not admitted then return false, admissionError or "recovery_not_actionable" end
    -- same chain rule as a return: the new point comes after the successor's
    S.bumpSeq(successorSeq or tonumber((proof or pend).seq))
    local record = R.copyReplay(proof or pend)
    -- The record itself has to say what it is. The envelope's kind reaches the journal, but
    -- the replay inside it kept the original listing/auction/return kind, and the reader that
    -- later walks this operation's file judges the replay: a discard wearing "listing" with
    -- no origins reads as a malformed line and poisons the whole chain - the very rollback
    -- this decision exists to close would then have no reviewable successor at all. The
    -- original kind is kept beside it, because "what was discarded" is part of the record.
    record.originalKind = record.originalKind or record.kind
    record.kind = "discard"
    record.origins, record.qty, record.lotQty = {}, 0, nil
    record.protocol = R.PROTOCOL
    record.epoch, record.seq = md.meta.epoch, S.nextSeq()
    local committed, commitError = R.finishOut(username, opId, record, "discard", opId)
    if not committed then
        R.releaseOut(opId)
        return false, commitError or "recovery_not_actionable"
    end
    R.transmit(target)
    return true
end

-- Every receipt of one account, oldest first, for the login reconcile.
function R.ownerReceipts(username)
    local out = {}
    local o = ownerRec(username, false)
    if not o then return out end
    for id in pairs(o.ops) do
        local r = md.recovery.ops[id]
        if r then out[#out + 1] = r end
    end
    EC.sortSafe(out, function(a, b) return (a.at or 0) < (b.at or 0) end)
    return out
end

-- Closed = this server watched the owner's save stop referring to the operation. It is a state,
-- not a deletion: the receipt still answers hasOut and still recognises a stale unit. Reopening
-- is honest and expected - an older save that still carries the pending record reopens it.
function R.closeReceipt(username, receipt, ms)
    if receipt.closed then return false end
    if R.unresolvedOp(username, receipt.id) then return false end
    receipt.closed = ms or EC.now()
    local o = ownerRec(username, false)
    if o then o.open = math.max(0, o.open - 1) end
    return true
end

function R.reopenReceipt(username, receipt)
    if not receipt.closed then return false end
    receipt.closed = nil
    local o = ownerRec(username, false)
    if o then o.open = o.open + 1 end
    return true
end

-- Bounded working set. Only closed receipts are droppable, oldest first, every drop leaves an
-- event line, and every drop raises the floor: from then on, a pending record older than the
-- floor whose receipt is missing is treated as forgotten (held), never as one that never
-- happened. Resolved held records are retired by their own TTL; unresolved ones never are.
function R.prune(ms)
    if not R.ready() then return end
    for username, o in pairs(md.recovery.owners) do
        local dropKeys = {}
        for key, rec in pairs(o.held) do
            if rec.resolvedAt and ms - rec.resolvedAt > R.HELD_TTL_MS then dropKeys[#dropKeys + 1] = key end
        end
        for _, key in ipairs(dropKeys) do o.held[key] = nil end
        if o.open <= 0 and o.heldOpen <= 0 and EC.countKeys(o.ops) == 0 and EC.countKeys(o.held) == 0 then
            md.recovery.owners[username] = nil
        end
    end
    for _, receipt in pairs(md.recovery.ops) do
        if R.receiptVerdict(receipt) == "survived" then receipt.replay = nil end
    end
    R.reclaimClosed(R.OPS_PRUNE_AT, R.OPS_PRUNE_TO)
    consumedIndex = {}
    for _, receipt in pairs(md.recovery.ops) do indexReceipt(receipt) end
end

-- Drop closed receipts, oldest closure first, while the table is above `above`, down to `downTo`.
--
-- Closure already required proof: this server watched the owner's save stop referring to the
-- operation. What may be dropped is therefore decided by the epoch the receipt was written in:
-- `survived` (the save that carries it is the one that was kept) and `unknown` (the epoch has
-- left the bounded history, so nothing can be decided from it any more) are both settled, while
-- `rolledback` is still live evidence for a rebuild and `current` is this run's own work.
-- Dropping one raises the retention floor, so an older pending that turns up later is refused as
-- forgotten instead of being treated as an operation that never happened.
function R.reclaimClosed(above, downTo)
    if not R.ready() then return 0 end
    if md.recovery.count <= above then return 0 end
    local closed = {}
    for _, r in pairs(md.recovery.ops) do
        local verdict = r.closed and R.receiptVerdict(r) or nil
        if verdict == "survived" or verdict == "unknown" then closed[#closed + 1] = r end
    end
    EC.sortSafe(closed, function(a, b) return (a.closed or 0) < (b.closed or 0) end)
    local dropped = 0
    for _, r in ipairs(closed) do
        if md.recovery.count <= downTo then break end
        md.recovery.ops[r.id] = nil
        md.recovery.count = math.max(0, md.recovery.count - 1)
        dropped = dropped + 1
        local o = ownerRec(r.owner, false)
        if o then o.ops[r.id] = nil end
        if (tonumber(r.at) or 0) > (md.recovery.floorAt or 0) then md.recovery.floorAt = tonumber(r.at) or 0 end
        md.recovery.floorCount = (md.recovery.floorCount or 0) + 1
        X.emit("recovery.receiptPruned", { username = r.owner, opId = r.id, kind = r.kind, ref = r.ref,
            at = r.at, closed = r.closed, floorAt = md.recovery.floorAt })
    end
    if dropped > 0 then
        consumedIndex = {}
        for _, receipt in pairs(md.recovery.ops) do indexReceipt(receipt) end
    end
    return dropped
end

-- ---------- inventory scan ----------

-- One walk of the backpack and the carried bags: every unit by token (identity), by native id
-- (locator) and every stamp by letter. The mailbox reconcile and the pending adjudication read
-- the same snapshot - nothing is scanned twice and nothing is decided from a container read taken
-- after the first change.
function R.scanUnits(inv)
    local scan = { byId = {}, byToken = {}, stamped = {}, duplicates = {}, failed = false }
    local function walk(container, depth)
        local items = container:getItems()
        if not items then error("inventory list unavailable") end
        for i = 0, items:size() - 1 do
            local item = items:get(i)
            if item then
                local stamp, readable = R.stampOf(item)
                if not readable then error("inventory stamp unreadable") end
                local id = nativeId(item)
                local row = { item = item, container = container, stamp = stamp, nativeId = id, fullType = item:getFullType() }
                if id ~= nil then
                    local rows = scan.byId[id]
                    if not rows then rows = {}; scan.byId[id] = rows end
                    rows[#rows + 1] = row
                end
                if stamp then
                    if type(stamp.unit) == "string" then
                        local previous = scan.byToken[stamp.unit]
                        if previous then
                            previous.duplicate, row.duplicate, scan.duplicates[stamp.unit] = true, true, true
                        else scan.byToken[stamp.unit] = row end
                    end
                    if type(stamp.mailId) == "string" then
                        local letter = scan.stamped[stamp.mailId]
                        if not letter then letter = { stamp = stamp, items = {} }; scan.stamped[stamp.mailId] = letter end
                        letter.items[#letter.items + 1] = row
                    end
                end
                if depth < R.SCAN_DEPTH and item.getInventory then
                    local inner = item:getInventory()
                    if inner and inner ~= container then walk(inner, depth + 1) end
                end
            end
        end
    end
    local ok, err = pcall(walk, inv, 0)
    if not ok then scan.failed = true; EC.log("recovery inventory scan failed: " .. tostring(err)) end
    return scan
end

-- The live operation this id names, as the owning module holds it right now:
-- { kind, owner, item, qty }. nil plus a reason when no module can answer (a required module
-- that is not loaded or a lookup that threw is "cannot ask", never "it is not there"), and nil
-- plus "world_owner" is never returned from here - the caller compares the owner itself.
function R.worldOperation(id)
    if type(id) ~= "string" or id == "" then return nil, "world_unverified" end
    local Mk, Au = S.Market, S.Auction
    if Mk == nil or type(Mk.operationInfo) ~= "function"
        or Au == nil or type(Au.operationInfo) ~= "function" then
        EC.log("recovery world lookup unavailable for " .. id)
        return nil, "world_unverified"
    end
    local ok, info = pcall(Mk.operationInfo, id)
    if not ok then
        EC.log("recovery world lookup failed for " .. id .. ": market")
        return nil, "world_unverified"
    end
    if type(info) == "table" then return info end
    ok, info = pcall(Au.operationInfo, id)
    if not ok then
        EC.log("recovery world lookup failed for " .. id .. ": auction")
        return nil, "world_unverified"
    end
    return info
end

-- The live object this origin points at, or nil. A delivered unit is matched by its token, which
-- is the same on the object however often it was rebuilt or redelivered. A unit that entered the
-- mod unstamped has only its locator, and then an unstamped object with that id is the best this
-- server can say - which is why an unstamped copy is never deleted on that evidence alone.
function R.matchUnit(scan, origin, expectedType)
    if type(origin) ~= "table" then return nil end
    if type(origin.unit) == "string" then
        local row = scan.byToken[origin.unit]
        if row and not row.gone then return row end
        if origin.src ~= "native" then return nil end
    end
    if origin.nativeId == nil then return nil end
    local legacyRow, legacyAmbiguous = nil, false
    for _, row in ipairs(scan.byId[origin.nativeId] or {}) do
        if not row.gone and (expectedType == nil or row.fullType == expectedType) then
            if row.stamp == nil then
                if origin.unit then return nil, row end -- a missing token plus locator is ambiguity, not identity
                return row
            elseif origin.src == "legacy" and origin.unit == nil then
                -- The original of a legacy record still wears its generation zero stamp, or the
                -- protocol 2 stamp this server adopted it under (whose token carries the very
                -- locator it was adopted on). Anything else standing on that id is a rebuilt
                -- object wearing a reused locator: taking it for the original would clear the
                -- record and leave the world with two.
                if legacyRow or not (R.gen0Stamp(row.stamp) or R.adoptedFrom(row.stamp, origin.nativeId)) then
                    legacyAmbiguous = true
                else
                    legacyRow = row
                end
            end
        end
    end
    if legacyAmbiguous then return nil, legacyRow or true end
    return legacyRow
end

-- ---------- origin adjudication ----------

local function mailEntry(username, mailId)
    local Mb = S.Mailbox
    if not Mb or not Mb.entryOf or type(username) ~= "string" or type(mailId) ~= "string" then return nil end
    if username == "" or mailId == "" then return nil end
    return Mb.entryOf(username, mailId)
end

-- Does this letter still owe this very unit? A letter holds a token until it is delivered and
-- transferred out, or moved to a split child. "The letter exists" is not the question - which
-- unit it still holds is.
local function letterHoldsUnit(entry, token)
    if entry == nil then return false end
    if entry.state ~= "ready" and entry.state ~= "claiming" then return false end
    if type(token) ~= "string" then return true end
    if type(entry.outUnits) == "table" and entry.outUnits[token] ~= nil then return false end
    if type(entry.units) ~= "table" then return true end
    for _, t in ipairs(entry.units) do
        if t == token then return true end
    end
    return false
end

-- Does the record this letter came back from exist in the world right now? Not "did its list-out
-- ever complete" (that is hasOut and stays true after a sale): the question is whether the asset
-- is sitting in the market or the auction house at this moment.
--
-- Three answers, never two: true (a live source was found), false (every probe answered and none
-- knows this reference), and nil for "this server could not ask". A required module that is not
-- loaded, a lookup that threw, or a source table that could not be read is not evidence that the
-- source is gone, and a caller must not retire transfer evidence on it (report ER-10). Every nil
-- names its reason in the log so it can be diagnosed instead of inferred.
function R.sourceAlive(ref)
    if type(ref) ~= "string" or ref == "" then return false end
    local unknown = nil
    local Mk, Au, Mb = S.Market, S.Auction, S.Mailbox
    if Mk == nil or type(Mk.listingExists) ~= "function" then
        unknown = "market_module_missing"
    else
        local ok, alive = pcall(Mk.listingExists, ref)
        if not ok then unknown = "market_lookup_failed"
        elseif alive == true then return true end
    end
    if Au == nil or type(Au.hasAuction) ~= "function" then
        unknown = unknown or "auction_module_missing"
    else
        local ok, alive = pcall(Au.hasAuction, ref)
        if not ok then unknown = unknown or "auction_lookup_failed"
        elseif alive == true then return true end
    end
    local receipt = R.receipt(ref)
    if receipt and receipt.kind == "return" then
        if Mb == nil or type(Mb.entryOf) ~= "function" then
            unknown = unknown or "mailbox_module_missing"
        else
            local ok, entry = pcall(Mb.entryOf, receipt.owner, receipt.ref)
            if not ok then unknown = unknown or "mailbox_lookup_failed"
            elseif entry and (entry.state == "ready" or entry.state == "claiming") then return true end
        end
    end
    if unknown then
        EC.log("recovery source state unknown for " .. ref .. ": " .. unknown)
        return nil
    end
    return false
end

local function absentRolledBackLetter(owner, id)
    local epoch, seq = EC.parseId(id)
    return epoch ~= nil and mailEntry(owner, id) == nil and R.verdict(epoch, seq) == "rolledback"
end

-- Return-mail ids may be reused during recovery; only original token roots prove creation.
local function sourceCreationRolledBack(origin, owner)
    if origin.srcRef ~= nil then return false end
    local root = type(origin.unit) == "string" and string.match(origin.unit, "^([^#]+)#%d+$")
    if not root or not absentRolledBackLetter(owner, origin.mailId) then return false end
    local parent = origin.parentMailId
    if parent and parent ~= origin.mailId and not absentRolledBackLetter(owner, parent) then return false end
    return root == origin.mailId or root == parent or absentRolledBackLetter(owner, root)
end

-- "valid"    - this unit is the player's to put back into a listing: nothing upstream holds it.
-- "upstream" - the world already represents this unit somewhere earlier in the chain (the letter
--              still owes it, the parent letter of a split still owes it, or the listing the
--              letter came back from is in the world again), or its source creation rolled back.
-- "unknown"  - the evidence is missing, unreadable or from an epoch this server no longer knows.
--              Never a synonym for valid, and never downgraded to native.
function R.originState(origin, username)
    if type(origin) ~= "table" then return "unknown" end
    local consumed, _, proof = R.consumer(origin)
    if proof == "unreadable" then return "unknown" end
    if consumed then return proof == "locator" and "unknown" or "upstream" end
    if origin.src == "native" then return "valid" end
    if origin.src == "legacy" then return "unknown" end
    if origin.src ~= "mail" then return "unknown" end
    local owner = origin.owner or username
    local entry = mailEntry(owner, origin.mailId)
    if entry then
        if letterHoldsUnit(entry, origin.unit) then return "upstream" end
        -- A generation zero token is a unit of this letter only while the letter can still
        -- account for it. After a world rollback below the binding the membership is gone, and
        -- the slot it used to hold may since have been redelivered to someone else: replaying
        -- against "the letter exists" alone would put one object into two places. Proven here,
        -- before the replay commits anything.
        if R.gen0Unit(origin.unit) and not R.gen0Admit(entry, origin.unit, origin.seq, nil, false) then
            return "unknown"
        end
        return "valid"
        -- The ready-mail case is marked claimed from a verified player witness before replay.
    end
    -- A split delivery: the child letter can roll back on its own while the parent keeps the
    -- unit. The child being absent is not proof that the asset is gone - the parent is asked for
    -- that exact token.
    if origin.parentMailId then
        local parent = mailEntry(owner, origin.parentMailId)
        if parent then
            if letterHoldsUnit(parent, origin.unit) then return "upstream" end
            return "valid"
        end
    end
    local v = origin.durable == true and "survived" or R.verdict(origin.epoch, origin.seq)
    if v == "rolledback" then
        local alive = R.sourceAlive(origin.srcRef)
        if alive == true then return "upstream" end
        -- nil is "could not ask": it is not a licence to call this unit the player's again
        if alive == nil then return "unknown" end
        if sourceCreationRolledBack(origin, owner) then return "upstream" end
        return "unknown"
    end
    if v == "survived" or v == "current" then return "valid" end
    return "unknown"
end

-- ---------- generation zero binding (report #2 / #4) ----------
--
-- Everything below is the cold path for units delivered before unit tokens existed. Their stamp
-- names a letter, a claim epoch and a claim seq, and nothing else: no unit, no owner, no
-- protocol. Such a unit used to be refused outright by beginOut ("the server cannot verify this
-- item's source"), which is correct as a default and useless as an outcome - the letter that
-- delivered it is often still in the world, claimed, with the very slot the object came out of.
--
-- What is proved here, and what is never guessed:
--   * the letter is found by its own id - the holder first, then the whole mailbox but only for
--     a globally unique id. The owner is the letter's, never the player who happens to hold the
--     object (the stamp never carried one).
--   * the claim must be the same one: entry.claimSeq == stamp.seq. A letter claimed again since
--     is a different delivery, and the object in hand cannot say which one it came from. That
--     equality is also what proves no protocol 2 delivery ever issued the placeholder this
--     binding is about to take.
--   * the token is "<mailId>#L<nativeId>" and it replaces one untouched placeholder. The
--     letter's quantity does not move: appending would invent a unit out of a locator.
--   * a source that is gone is not a source. There is no quantity to infer and no owner to pick,
--     so the answer is a reason an administrator acts on, per letter, with the ids in it.

R.GEN0_MARK = "#L"

function R.gen0Token(mailId, nativeId)
    return mailId .. R.GEN0_MARK .. tostring(nativeId)
end

-- The protocol 2 stamp this server wrote onto a generation zero object keeps the locator it was
-- adopted on inside its token, so a legacy record can still recognise its own original.
function R.adoptedFrom(stamp, id)
    return type(stamp) == "table" and stamp.proto == R.PROTOCOL and type(stamp.mailId) == "string"
        and type(stamp.unit) == "string" and stamp.unit == R.gen0Token(stamp.mailId, id)
end


-- The letter a generation zero stamp names. `cache` is one table per pass: a letter of twenty
-- nails is looked up once, not twenty times, and the global walk never runs per item.
function R.findLetter(mailId, holder, cache)
    if type(mailId) ~= "string" or mailId == "" then return nil, "missing" end
    local hit = cache and cache[mailId] or nil
    if hit then return hit.entry, hit.why end
    local Mb = S.Mailbox
    local entry = (Mb and Mb.entryOf and type(holder) == "string" and holder ~= "")
        and Mb.entryOf(holder, mailId) or nil
    local why = nil
    if not entry and Mb and Mb.findEntry then entry, why = Mb.findEntry(mailId) end
    if cache then cache[mailId] = { entry = entry, why = why } end
    return entry, why
end

-- A slot this token may take: an untouched "<mailId>#<i>" placeholder that no committed transfer
-- consumed and that no live object in this snapshot is wearing.
local function freeSlot(entry, scan)
    local units = type(entry.units) == "table" and entry.units or nil
    if not units then return nil end
    local taken = type(entry.outUnits) == "table" and entry.outUnits or nil
    for i = 1, #units do
        local t = units[i]
        if t == entry.id .. "#" .. tostring(i) and not (taken and taken[t] ~= nil)
            and not (scan and scan.byToken[t]) then
            return i
        end
    end
    return nil
end

-- Is this token one a generation zero binding minted for this very letter? The locator it was
-- adopted on is inside the name, so the test is exact rather than a prefix: "<mailId>#L<digits>"
-- and nothing else. A token that merely starts with the letter id is not this letter's unit.
function R.gen0Unit(token)
    return type(token) == "string" and string.find(token, R.GEN0_MARK, 1, true) ~= nil
end

function R.gen0Owned(entry, token)
    if type(entry) ~= "table" or type(token) ~= "string" or type(entry.id) ~= "string" then return false end
    local head = entry.id .. R.GEN0_MARK
    if string.sub(token, 1, #head) ~= head then return false end
    local id = tonumber(string.sub(token, #head + 1))
    return id ~= nil and R.gen0Token(entry.id, id) == token
end

-- THE ADMISSION GATE. Every generation zero binding goes through this, the first one and every
-- re-binding after a rollback, and it is also what a replay must satisfy *before* it commits.
-- The proof is always the same four facts, because a rollback does not make them cheaper:
--   * the letter is a generation zero letter and this token is its own,
--   * it is claimed or settled (a letter that still owes its units is not a source yet),
--   * the claim is the same one: entry.claimSeq == the stamp's seq. A letter claimed again since
--     issued its slots to that newer delivery, and renaming one of those would take a modern
--     unit away from whoever holds it. A letter with no recorded claim seq at all has never
--     issued one under a recorded claim, so the first generation zero stamp that names it fixes
--     the value - and every later stamp is measured against it.
--   * the token is already a member, or an unissued placeholder can account for it.
-- `apply` false answers without touching anything, which is what the replay path needs.
function R.gen0Admit(entry, token, seq, scan, apply)
    if type(entry) ~= "table" then return nil, "legacy_source_pruned" end
    for _, t in ipairs(type(entry.units) == "table" and entry.units or {}) do
        if t == token then return "already" end
    end
    if entry.gen0 ~= true or not R.gen0Owned(entry, token) then return nil, "legacy_source_unknown" end
    if entry.state ~= "claimed" and entry.state ~= "settled" then return nil, "legacy_source_unclaimed" end
    local claimSeq, stampSeq = tonumber(entry.claimSeq), tonumber(seq)
    if stampSeq == nil then return nil, "legacy_claim_superseded" end
    if claimSeq ~= nil and claimSeq ~= stampSeq then return nil, "legacy_claim_superseded" end
    if freeSlot(entry, scan) == nil then return nil, "legacy_slot_unavailable" end
    if not apply then return "admissible" end
    if claimSeq == nil then entry.claimSeq = stampSeq end
    return R.bindSlot(entry, token, scan)
end

-- Before any unit of a letter is named: are its objects even distinguishable? Two real objects
-- can wear the same engine id (one in the backpack, one in a bag inside it), and both would mint
-- the same "<mailId>#L<id>" token - the second would be told it is already bound, one slot would
-- account for two objects, and the next login would read the spare as a stale copy and delete a
-- legal asset. The whole letter is held instead: naming part of it is the swallow. Evaluated
-- once per letter from the pre-adoption snapshot and cached, so no row can see a different
-- answer than the row before it.
function R.gen0Group(scan, mailId)
    local seen = {}
    local letter = (scan and type(mailId) == "string") and scan.stamped[mailId] or nil
    for _, row in ipairs(letter and letter.items or {}) do
        if not row.gone and R.gen0Stamp(row.stamp) then
            local id = row.nativeId
            if id == nil then return "legacy_source_unknown" end
            if seen[id] then return "legacy_duplicate_locator" end
            seen[id] = true
            local worn = scan.byToken[R.gen0Token(mailId, id)]
            if worn ~= nil and worn ~= row then return "legacy_duplicate_locator" end
        end
    end
    return nil
end

local function groupConflict(ctx, mailId)
    if type(ctx) ~= "table" or ctx.scan == nil then return nil end
    ctx.groups = ctx.groups or {}
    local cached = ctx.groups[mailId]
    if cached == nil then
        cached = R.gen0Group(ctx.scan, mailId) or false
        ctx.groups[mailId] = cached
    end
    return cached or nil
end

-- The raw mutation behind the admission gate: take one unissued placeholder for this token and
-- carry over the consumption a surviving receipt already recorded against it, so availableUnits
-- can never hand the same unit over twice. Never called directly - R.gen0Admit is what proves a
-- token may be here at all.
function R.bindSlot(entry, token, scan)
    if type(entry) ~= "table" or type(token) ~= "string" then return nil, "legacy_slot_unavailable" end
    for _, t in ipairs(type(entry.units) == "table" and entry.units or {}) do
        if t == token then return "already" end
    end
    local slot = freeSlot(entry, scan)
    if slot == nil then return nil, "legacy_slot_unavailable" end
    entry.units[slot] = token
    entry.gen0Bound = entry.gen0Bound or {}
    entry.gen0Bound[token] = slot
    local opId = consumedIndex[token]
    if opId and R.receipt(opId) then
        if type(entry.outUnits) ~= "table" then entry.outUnits = {} end
        if entry.outUnits[token] == nil then
            entry.outUnits[token] = opId
            entry.outQty = (tonumber(entry.outQty) or 0) + 1
        end
    end
    return "bound"
end

-- Everything an administrator has to see about one generation zero letter, read from the one
-- inventory snapshot this pass already took: how many of its objects are in the backpack right
-- now, and which engine ids they are standing on.
function R.gen0Evidence(scan, mailId)
    local n, ids = 0, {}
    local letter = (scan and type(mailId) == "string") and scan.stamped[mailId] or nil
    for _, row in ipairs(letter and letter.items or {}) do
        if not row.gone then
            n = n + 1
            if #ids < 32 then ids[#ids + 1] = tostring(row.nativeId) end
        end
    end
    return n, table.concat(ids, ",")
end

-- Can this unit be named? Returns the upgraded origin, or nil plus the record an administrator
-- acts on: { reason, sourceState, mailId, item, owner, epoch, seq, txId, detail }.
function R.judgeGen0(origin, holder, ctx)
    local out = { mailId = origin and origin.mailId, epoch = origin and origin.epoch,
        seq = origin and origin.seq, txId = origin and origin.txId,
        sourceState = "unknown", reason = "legacy_source_unknown" }
    if type(origin) ~= "table" or origin.gen0 ~= true or type(origin.mailId) ~= "string" then
        out.detail = "not a generation zero stamp"
        return nil, out
    end
    local entry, why = R.findLetter(origin.mailId, holder, ctx and ctx.letters)
    local verdict = R.verdict(origin.epoch, origin.seq)
    local consumed, _, proof = R.consumer(origin)
    if proof == "unreadable" then
        out.detail = "mailbox consumption state could not be read"
        return nil, out
    end
    if consumed then
        out.reason, out.opId, out.item = "legacy_unit_consumed", consumed, origin.item
        return nil, out
    end
    -- The letter outranks the epoch history. A claim that rolled back while its letter is still
    -- in the world is the ordinary "world save older than the player save" convergence: the
    -- purchase itself survived (the letter is the proof that it was paid for), so the units are
    -- reconciled, never destroyed. Only when the letter is gone does the claim verdict decide,
    -- and then a rolled-back claim means the money came back with it.
    if not entry then
        if why == "ambiguous" then
            out.detail = "more than one account holds letter " .. origin.mailId
            out.sourceState = "ambiguous"
        elseif verdict == "rolledback" then
            out.sourceState, out.reason = "rolledback", "legacy_claim_rolledback"
            out.detail = "claim " .. tostring(origin.epoch) .. ":" .. tostring(origin.seq)
                .. " did not survive and its letter is gone"
        elseif verdict == "survived" or verdict == "current" then
            out.sourceState, out.reason = "pruned", "legacy_source_pruned"
        end
        return nil, out
    end
    out.sourceState, out.owner, out.item = "present", entry.owner, entry.item
    -- A letter a generation zero stamp names is a generation zero letter, whatever its `units`
    -- array looks like by now (an older build minted placeholders into it on every login).
    -- Marking it here is what keeps the retention from pruning the one record this binding -
    -- and every later one against the same letter - is read from.
    entry.gen0 = true
    local clash = groupConflict(ctx, entry.id)
    if clash then
        out.reason = clash
        out.detail = "two objects of this letter cannot be told apart by their engine id"
        return nil, out
    end
    local token = R.gen0Token(entry.id, origin.nativeId)
    local tokenConsumer, _, tokenProof = R.consumer({ unit = token, owner = entry.owner,
        mailId = entry.id, item = origin.item })
    if tokenProof == "unreadable" then
        out.detail = "mailbox consumption state could not be read"
        return nil, out
    end
    if tokenConsumer then
        out.reason, out.detail = "legacy_unit_consumed", "unit " .. token .. " was already transferred out"
        return nil, out
    end
    local placed, slotError = R.gen0Admit(entry, token, origin.seq, ctx and ctx.scan, true)
    if not placed then
        out.reason = slotError
        if slotError == "legacy_source_unclaimed" then
            out.sourceState = "unclaimed"
            out.detail = "letter state " .. tostring(entry.state)
        elseif slotError == "legacy_claim_superseded" then
            out.detail = "letter claim seq " .. tostring(entry.claimSeq) .. " vs stamp seq " .. tostring(origin.seq)
        else
            out.detail = "no unissued placeholder left in letter " .. entry.id
        end
        return nil, out
    end
    out.unit = token
    return {
        src = "mail", nativeId = origin.nativeId, unit = token, mailId = entry.id,
        item = origin.item,
        owner = entry.owner, epoch = origin.epoch, seq = origin.seq, txId = origin.txId,
        srcRef = entry.listingId, parentMailId = entry.parentMailId,
        durable = verdict == "survived" or nil,
    }, out
end

-- Name the unit for good: the token goes into the letter and onto the object, carrying the
-- claim's own epoch and seq (never this login's - a re-stamp with the current claim would make
-- an old delivery look like a new one) and the survived verdict frozen in, so twenty epochs from
-- now the same object is still provable instead of unknown again.
function R.adoptGen0(player, item, origin, ctx)
    local bound, info = R.judgeGen0(origin, player and S.login(player) or nil, ctx)
    if bound then
        local written = pcall(function()
            item:getModData()[EC.PLAYER_MODDATA_KEY] = { proto = R.PROTOCOL, mailId = bound.mailId,
                unit = bound.unit, owner = bound.owner, epoch = bound.epoch, seq = bound.seq,
                txId = bound.txId, srcRef = bound.srcRef, parentMailId = bound.parentMailId,
                durable = bound.durable }
        end)
        if written then
            if player then
                local synced, err = pcall(syncItemModData, player, item)
                if not synced then EC.log("recovery legacy stamp notification failed: " .. tostring(err)) end
            end
            return bound, info
        end
        info.reason, info.detail = "legacy_source_unknown", "item metadata could not be written"
    end
    if ctx and ctx.scan then info.qty, info.ids = R.gen0Evidence(ctx.scan, info.mailId) end
    return nil, info
end

-- One held record per letter, never one per nail. The same refusal seen again updates the
-- evidence in place instead of stacking, and per-unit rows an earlier build left behind are
-- folded into this one.
function R.holdGen0(username, info)
    if type(info) ~= "table" or type(info.mailId) ~= "string" then return false end
    local key = "legacy:" .. info.mailId
    R.regroupUnitHolds(username, info.mailId, key)
    return R.holdUpdate(username, key, info.reason, {
        mailId = info.mailId, sourceState = info.sourceState, detail = info.detail,
        item = info.item, owner = info.owner, epoch = info.epoch, seq = info.seq,
        txId = info.txId, qty = info.qty, ids = info.ids, kind = "legacy",
    })
end

-- ---------- pending adjudication (login, rule three rows 4-6) ----------

-- Pure: it reads the world, the player save and one inventory snapshot and says what should
-- happen. ECMailbox applies it. Actions:
--   "removeOriginal" - the world committed the transfer and the older player save still carries
--                      the units: those exact objects go (present[] carries them).
--   "clear"          - the operation converged; the pending record has nothing left to guard.
--   "restore"        - the world lost the record below a rollback and every unit is still the
--                      player's: rebuild the whole lot through the owner module.
--   "partial"        - only some units are still the player's: the verified remainder goes back
--                      to the mailbox at the unchanged price (never a prorated one, never a
--                      blind buyback payout) and the operation is closed.
--   "cancel"         - every unit is already represented upstream: the derived operation is void.
--   "hold"           - unprovable; keep the pending record exactly as it is and count it.
--   "keep"           - this epoch's own work, still in flight.
-- `opts.resume` marks a caller that is allowed to act on the answer (the login reconcile, or an
-- administrator's write-gated recheck): only such a caller leaves a resume ticket when a cold
-- journal read has to be waited for. A read-only look at a record passes nothing, so its wait
-- never turns into a repair when the read completes.
local function judgeRecord(username, id, pend, scan, opts)
    local out = { action = "keep", present = {}, keys = {}, validOrigins = {}, valid = 0,
        upstream = 0, unknown = 0, total = 0 }
    if type(pend) ~= "table" then out.action, out.reason = "hold", "pending_malformed"; return out end
    local held = R.heldRecord(username, "pend:" .. id)
    local vanished = R.rememberedSightings(username, id)
    if #vanished > 0 then
        local missingSightings = {}
        for _, key in ipairs(vanished) do
            if type(held.item) ~= "string" or not R.unitVisible(scan, key, held.item) then
                missingSightings[#missingSightings + 1] = key
            end
        end
        out.vanished = table.concat(missingSightings, ",")
        if #missingSightings > 0 then
            out.action, out.reason, out.restorable = "hold", "source_state_changed", false
            out.item, out.ids = held.item, out.vanished
            return out
        end
    end
    local legacy = pend.protocol ~= R.PROTOCOL or type(pend.origins) ~= "table"
    local origins = {}
    if legacy then
        local ids = type(pend.itemIds) == "table" and pend.itemIds or { pend.itemId }
        for _, native in ipairs(ids) do
            if #origins >= R.ORIGINS_MAX then break end
            if type(native) == "number" then origins[#origins + 1] = { src = "legacy", nativeId = native } end
        end
    else
        if #pend.origins > R.ORIGINS_MAX then out.action, out.reason = "hold", "pending_malformed"; return out end
        for _, origin in ipairs(pend.origins) do
            if type(origin) ~= "table" then out.action, out.reason = "hold", "pending_malformed"; return out end
            origins[#origins + 1] = origin
        end
    end
    out.total = #origins
    if out.total == 0 then out.action, out.reason = "hold", "pending_malformed"; return out end
    local missing = {}
    local expectedType = type(pend.snapshot) == "table" and pend.snapshot.type or nil
    for _, origin in ipairs(origins) do
        local key = originKey(origin)
        if key then out.keys[key] = true end
        if type(origin.unit) ~= "string" and type(expectedType) ~= "string" then
            out.action, out.reason = "hold", "snapshot_unverified"
            return out
        end
        local row, ambiguous = R.matchUnit(scan, origin, expectedType)
        if ambiguous then out.action, out.reason = "hold", "native_identity_unverified"; return out end
        if row then out.present[#out.present + 1] = row
        else missing[#missing + 1] = origin end
    end
    local receipt = R.receipt(id)
    local pendVerdict = R.verdict(pend.epoch, tonumber(pend.seq))
    if pend.abortIncomplete then
        if #missing == 0 and not receipt then out.action, out.reason = "clear", "abort_returned"
        else out.action, out.reason = "hold", "abort_incomplete" end
        return out
    end
    if receipt then
        if receipt.owner ~= username then out.action, out.reason = "hold", "receipt_owner"; return out end
        -- from here the server's own receipt is the record: its units and its item type, never
        -- the type the player's pending claims (recovery-proof contract, integration)
        expectedType = type(receipt.item) == "string" and receipt.item or expectedType
        -- An administrator voided this operation against the world (R.finishOut kind "discard").
        -- The decision only outranks the player's record once it is inside a save: until then a
        -- world rollback could take the decision away while the pending record stayed cleared,
        -- and the operation would be gone with nothing having decided it. Held until durable, so
        -- a lost decision is re-reviewed rather than silently applied.
        if receipt.kind == "discard" then
            if R.receiptVerdict(receipt) == "survived" then out.action, out.reason = "clear", "admin_discarded"
            else out.action, out.reason = "hold", "legacy_discard_unsaved" end
            return out
        end
        -- A partial resolution only authorizes removal of the units it actually consumed.
        local covered = {}
        out.present, out.keys = {}, {}
        local locatorOnly = false
        for _, unit in ipairs(receipt.units or {}) do
            -- A unit that entered the mod with a legacy stamp was compacted as one (`l`), and it
            -- has to come back as one: read as native, its still-stamped original would never
            -- match and the record would call an object that is right here missing.
            local origin = { unit = unit.t, nativeId = unit.n, mailId = unit.m,
                src = unit.l == true and "legacy" or (unit.n ~= nil and "native" or "mail") }
            local key = originKey(origin)
            if key then covered[key], out.keys[key] = true, true end
            local row, ambiguous = R.matchUnit(scan, origin, expectedType)
            if ambiguous then out.action, out.reason = "hold", "native_identity_unverified"; return out end
            if row then
                out.present[#out.present + 1] = row
                if unit.l == true then locatorOnly = true end
            end
        end
        for _, origin in ipairs(origins) do
            if not covered[originKey(origin)] and not R.matchUnit(scan, origin, expectedType) then
                local consumed, _, proof = R.consumer(origin)
                if proof == "unreadable" then
                    out.action, out.reason = "hold", "source_state_unknown"
                    return out
                end
                if not consumed and R.originState(origin, username) ~= "upstream" then
                    out.action, out.reason = "hold", "uncovered_unit_missing"
                    return out
                end
            end
        end
        if locatorOnly then
            out.action, out.reason = "hold", "native_identity_unverified"
            return out
        end
        local durable = R.receiptVerdict(receipt) == "survived"
        if #out.present > 0 then out.action, out.clear = "removeOriginal", durable
        elseif durable then out.action = "clear" end
        return out
    end
    local Mk = S.Market
    local probed, world = pcall(Mk.hasListing, id, pend)
    if not probed then world = nil end
    if legacy then
        -- A record written before origins existed. It carries engine ids and nothing else, so
        -- the order the evidence is read in is the whole safety argument:
        --   forgotten first - below the receipt floor the absence of a receipt proves nothing;
        --   the world still holding it is the existing safe path, unchanged;
        --   a verified "not in the world" plus a claim that reached a save means the operation
        --     completed (an old listing that was sold must never be handed back by hand);
        --   this epoch's own work is still in flight;
        --   anything else is held and listed, with the outcome named so the reconciliation page
        --     can offer a manual return only where the world really did lose it. A record whose
        --     world side cannot even be probed (an old buyback with no txRequestId) lands here
        --     too instead of disappearing behind world_unverified - it is exactly the kind that
        --     has to be voidable by hand.
        if R.forgotten(pend.at) then out.action, out.reason = "hold", "receipt_forgotten"; return out end
        if world == true then
            -- the same ownership rule as the protocol 2 path: a record from before origins
            -- existed still cannot make another account's live listing into this account's
            -- business, and a row of theirs must not be described as this player's old copy
            local live, worldError = R.worldOperation(id)
            if worldError or (live == nil and pend.kind ~= "buyback") then
                out.action, out.reason = "hold", "world_unverified"
                return out
            end
            if live ~= nil and not S.sameAccount(live.owner, username) then
                out.action, out.reason, out.foreign = "hold", "world_owner", true
                out.restorable, out.unproven = false, false
                out.present, out.keys, out.outcome = {}, {}, live.kind
                return out
            end
            if #out.present > 0 then out.action, out.clear = "removeOriginal", pendVerdict == "survived"
            elseif pendVerdict == "survived" then out.action = "clear" end
            return out
        end
        if world == false then
            if #missing == 0 then out.action, out.reason = "clear", "item_present"; return out end
            if pendVerdict == "survived" then out.action, out.reason = "clear", "legacy_completed"; return out end
        end
        if pendVerdict == "current" then return out end
        local ids = {}
        for _, origin in ipairs(origins) do
            if #ids < 32 then ids[#ids + 1] = tostring(origin.nativeId) end
        end
        out.action, out.reason = "hold", "pending_legacy"
        out.outcome, out.item, out.ids = pendVerdict, expectedType, table.concat(ids, ",")
        out.found, out.absent = #out.present, #missing
        return out
    end
    if world == nil then out.action, out.reason = "hold", "world_unverified"; return out end
    if world then
        -- "The world holds something under this id" is a single boolean, and a pending record is
        -- the one thing that named the id: on its own it cannot say the live listing or auction
        -- is this account's, nor that it is the same goods. The live operation is read and
        -- checked - owner, item and unit count - and anything that does not line up is held
        -- instead of being acted on with the player's own description of it; a refusal drops
        -- the rows matched from the claim, so it never hands a caller objects to remove.
        local live, worldError = R.worldOperation(id)
        if worldError or (live == nil and pend.kind ~= "buyback") then
            out.action, out.reason = "hold", "world_unverified"
            return out
        end
        if live == nil then
            -- Both live stores answered absent; hasListing proved this buyback's mint exists.
            if #out.present > 0 then out.action, out.clear = "removeOriginal", pendVerdict == "survived"
            elseif pendVerdict == "survived" then out.action = "clear" end
            return out
        end
        if not S.sameAccount(live.owner, username) then
            -- the id names a live operation of another account: never acted on, never accepted
            -- by hand (a rebuild under that id would write a receipt over someone else's
            -- operation), and nothing of that account is named in the answer
            out.action, out.reason, out.foreign = "hold", "world_owner", true
            out.restorable, out.unproven = false, false
            out.present, out.outcome = {}, live.kind
            return out
        end
        local liveType = type(live.item) == "string" and live.item or nil
        local liveQty = tonumber(live.qty)
        if liveType == nil or (liveQty ~= nil and liveQty ~= out.total) then
            out.action, out.reason = "hold", "world_mismatch"
            out.present, out.item, out.outcome = {}, liveType, live.kind
            return out
        end
        -- present is re-matched against the live operation's own item type, and the durability
        -- of the decision comes from the operation id's own commit stamp (the id under which
        -- the server minted that live row), never from the epoch/seq the pending claims
        out.present, out.keys = {}, {}
        for _, origin in ipairs(origins) do
            local key = originKey(origin)
            if key then out.keys[key] = true end
            local row, ambiguous = R.matchUnit(scan, origin, liveType)
            if ambiguous then
                out.action, out.reason, out.restorable = "hold", "native_identity_unverified", false
                return out
            end
            if row then out.present[#out.present + 1] = row end
        end
        local liveEpoch, liveSeq = EC.parseId(id)
        local durable = liveEpoch ~= nil and R.verdict(liveEpoch, liveSeq) == "survived"
        out.found, out.absent, out.item = #out.present, out.total - #out.present, liveType
        if #out.present > 0 then out.action, out.clear = "removeOriginal", durable
        elseif durable then out.action = "clear"
        else out.action = "keep" end
        return out
    end
    if pendVerdict == "current" then return out end
    return R.judgeFromJournal(username, id, pend, scan, out, opts)
end

-- One place decides the two flags every caller reads, so no branch can forget them:
--   `action`     - what this server does by itself; only restore / partial ever rebuild.
--   `restorable` - whether an administrator may rebuild by hand. A hold that did not explicitly
--                  earn it does not have it: an unanswered or contradicted question is never a
--                  licence. `pending_legacy` is the one exception - a record from before the
--                  journal existed keeps the manual path it always had, judged by the pre-journal
--                  evidence the administration page already shows.
function R.judgePending(username, id, pend, scan, opts)
    local out = judgeRecord(username, id, pend, scan, opts)
    if out.action == "hold" and out.restorable == nil and out.reason ~= "pending_legacy" then
        out.restorable, out.unproven = false, false
    end
    return out
end

-- The authoritative half of the rollback judgement. Everything the restore will use is recomputed
-- from the journal record: present / missing against its origins and its item type, the rollback
-- verdict against the commit point it recorded, and the retention floor against its own time.
-- The player's record is only what made this server go looking.
--
-- Two answers come out of here and they mean different things:
--   `action`     - what this server does by itself. Only "restore" / "partial" ever rebuild, and
--                  only with the authoritative record in `replay`.
--   `restorable` - whether an administrator may rebuild by hand at all. It is false whenever
--                  this server holds evidence that says no (the record's own commit point
--                  survived the save, or it is past the retention floor) and whenever it simply
--                  could not read (still running, unreadable, malformed, module absent): an
--                  unanswered question is not a licence. It is true when the evidence supports
--                  the rebuild, and when there is provably no record of ours at all - then
--                  nothing contradicts the player's account, and an administrator may accept it
--                  explicitly (`unproven`), which is never automatic.
local function judgeSuccessor(username, id, replay, detail, scan, out, opts)
    out.source, out.replay, out.detail = "journal", replay, detail
    out.present, out.keys, out.validOrigins = {}, {}, {}
    out.valid, out.upstream, out.unknown, out.total = 0, 0, 0, 0
    out.restorable, out.unproven = false, false
    local epoch = type(detail) == "table" and detail.serverEpoch or nil
    local seq = type(detail) == "table" and detail.serverSeq or nil
    local at = type(detail) == "table" and detail.outAt or nil
    out.serverEpoch, out.serverSeq = epoch, seq
    out.chain = type(detail) == "table" and detail.chain or nil
    if type(epoch) ~= "string" or type(seq) ~= "number" or type(at) ~= "number" then
        out.action, out.reason = "hold", "journal_malformed"
        return out
    end
    out.outcome = R.verdict(epoch, seq)
    if out.outcome ~= "rolledback" then
        out.action, out.reason = "hold", "outcome_unverified"
        return out
    end
    if R.forgotten(at) then
        out.action, out.reason = "hold", "receipt_forgotten"
        return out
    end
    local discarded = replay.kind == "discard"
    local evidence = replay
    if discarded then
        out.previous, out.discardable = detail.previous, true
        evidence = out.previous
        if evidence == nil then
            out.action, out.reason = "hold", "admin_discard_rolledback"
            return out
        end
    end
    local item = type(evidence.snapshot) == "table" and evidence.snapshot.type or nil
    local origins = evidence.origins
    if type(item) ~= "string" or type(origins) ~= "table"
        or #origins < 1 or #origins > R.ORIGINS_MAX then
        out.action, out.reason = "hold", "journal_malformed"
        return out
    end
    out.item, out.total = item, #origins
    local absent, changed, seen = {}, {}, {}
    for _, origin in ipairs(origins) do
        local key = originKey(origin)
        if key then out.keys[key] = true end
        local row, ambiguous = R.matchUnit(scan, origin, item)
        if ambiguous then
            out.action, out.reason = "hold", "native_identity_unverified"
            return out
        end
        if row then
            out.present[#out.present + 1] = row
        else
            absent[#absent + 1] = origin
            if key and R.wasSighted(username, origin, item) and not seen[key] then
                seen[key], changed[#changed + 1] = true, key
            end
        end
    end
    out.missing, out.found, out.absent = absent, #out.present, #absent
    if #changed > 0 then
        out.vanished = table.concat(changed, ",")
        out.ids = out.vanished
        out.action, out.reason = "hold", "source_state_changed"
        return out
    end
    if #absent == 0 then
        out.action, out.reason = "clear", "item_present"
    else
        for _, origin in ipairs(absent) do
            local state = R.originState(origin, username)
            if state == "valid" then
                out.valid = out.valid + 1
                out.validOrigins[#out.validOrigins + 1] = origin
            elseif state == "upstream" then out.upstream = out.upstream + 1
            else out.unknown = out.unknown + 1 end
        end
        if out.unknown > 0 then
            out.action, out.reason = "hold", "origin_unverified"
            return out
        end
        if out.valid == 0 then
            out.action, out.reason = "cancel", "origin_upstream"
        else
            out.restorable = true
            out.preview = { item = item, qty = out.valid, origins = out.validOrigins }
            if out.valid == #absent and #out.present == 0 then out.action = "restore"
            else out.action, out.reason = "partial", "origin_partial" end
        end
    end
    if discarded then out.action, out.reason = "hold", "admin_discard_rolledback" end
    -- A rebuild is only right when the save this player loaded really had the objects taken
    -- out: a save from before the transfer still had them, and a replayed pending plus a dropped
    -- original would then be two (moddata trust boundary, R.outOrder).
    if out.action == "restore" or out.action == "partial" then
        local order, why = R.outOrder(username, detail.first, type(opts) == "table" and opts.player or nil)
        out.saveOrder, out.saveProof = order, why
        if order == "excluded" or order == "tie" then
            out.action, out.reason, out.discardable = "hold", "pending_not_in_save", true
            -- only a proven exclusion may be voided by the server itself (ECMailbox autoDiscard);
            -- a tie or a floor stays a hold the administrator closes
            out.autoDiscard = order == "excluded" and (why == "hours" or why == "fork") or nil
            out.restorable, out.preview = false, nil
        elseif order == "life_unproven" or order == "ledger_incomplete" then
            -- the server cannot tell which way it is: never rebuilt by itself, but the journal
            -- record stays in hand and an administrator may rebuild from it or close it
            out.action, out.reason, out.discardable = "hold", order == "life_unproven"
                and "pending_life_unproven" or "ledger_incomplete", true
        elseif order == "unanchored" then
            R.noteUnanchored(username, id)
        end
    end
    return out
end

function R.judgeFromJournal(username, id, pend, scan, out, opts)
    out.unproven, out.restorable = false, false
    local J = S.RecoveryJournal
    if J == nil or type(J.lookup) ~= "function" then
        out.action, out.reason = "hold", "journal_unavailable"
        return out
    end
    local replay, reason, detail = J.lookup(username, id, pend)
    local found = type(detail) == "table" and detail.record or nil
    if reason == nil and type(replay) == "table" then
        return judgeSuccessor(username, id, replay, detail, scan, out, opts)
    end
    if reason == "journal_mismatch" and type(found) == "table" then
        out = judgeSuccessor(username, id, found, detail, scan, out, opts)
        -- A mismatched claim needs a human decision, not weaker source checks.
        if out.action ~= "hold" then out.action, out.reason = "hold", reason end
        return out
    end
    out.action, out.reason, out.detail = "hold", reason or "journal_missing", detail
    if out.reason == "journal_missing" then
        -- A verified absence permits explicit manual acceptance, never automatic creation.
        out.unproven, out.restorable = true, true
    elseif out.reason == "journal_mismatch" then
        out.foreign = true
        out.present, out.keys = {}, {}
    elseif out.reason == "journal_pending" and type(opts) == "table" and opts.resume == true then
        out.resume = R.noteProofTicket(username, id)
        if out.resume then R.noteProofScan(username, scan) end
    end
    return out
end

-- ---------- refusal detail (report #3) ----------
--
-- "The server could not verify these items' source" is one sentence for a stamp that could not
-- be read, a letter that still owes the unit, a claim that rolled back and a transfer that
-- already consumed it. They are four different problems with three different next steps, and a
-- seller told the generic sentence has nothing to act on. Every refusal below therefore carries
-- the evidence of the very unit it was refused on.
--
-- What it is allowed to contain: this request's own item (full type and engine locator), its
-- position in this request, the player's own letter / operation ids, the claim this object
-- carries and the verdict this server reached on it. Never another account, never a balance,
-- never the whole source table, never a server path. Naming the source is not acting on it:
-- nothing here removes an object, reissues one, or edits a save.
local DETAIL_FIELDS = { "item", "itemId", "index", "qty", "mailId", "opId", "epoch", "seq",
    "verdict", "heldKey" }

-- The next step, and only one of three. None of them promises the refusal can be undone.
--   "retry"        - something the player can see is in the way; the same request can succeed
--                    once it is not (claim the letter, pick the object again, re-open the panel)
--   "wait_save"    - an operation of this account is waiting for a world save to judge it
--   "admin_review" - the evidence conflicts or is gone; only a person reading the records can
--                    settle it, and until then nothing is reissued and nothing is deleted
local DETAIL_ACTION = {
    recovery_state_unavailable = "retry",
    inventory_unreadable = "retry",
    item_locator_unreadable = "retry",
    item_stamp_unreadable = "retry",
    request_unit_count = "retry",
    operation_in_flight = "retry",
    duplicate_unit = "retry",
    source_claim_pending = "retry",
    legacy_source_unclaimed = "retry",
    player_save_not_synced = "retry",
    pending_cap_unconfirmed = "wait_save",
    unit_in_pending_operation = "wait_save",
    receipt_capacity_reached = "wait_save",
}

local function detail(reason, fields)
    local d = { reason = reason, action = fields.action or DETAIL_ACTION[reason] or "admin_review" }
    for _, key in ipairs(DETAIL_FIELDS) do
        local v = fields[key]
        local t = type(v)
        if t == "string" or t == "number" then d[key] = v end
    end
    return d
end

-- The type of an object whose reads are already suspect: a refusal must still be able to name
-- which item it is about, and a throwing getter is not a reason to answer with nothing.
local function fullTypeOf(item)
    local ok, t = pcall(function() return item:getFullType() end)
    if ok and type(t) == "string" then return t end
    return nil
end

-- ---------- public list-out entries (re-exported by ECMailbox) ----------

-- Phase one of every live list-out: the player's own save remembers the operation, with its
-- sources, before anything is removed and before any money moves. Every refusal happens here,
-- and every refusal names the unit it happened on: the first two return values are unchanged
-- (true, or false plus the error code), the third is the detail table on failure.
function R.beginOut(player, id, items, rec)
    if not R.ready() then
        return false, "recovery_unverified", detail("recovery_state_unavailable", {})
    end
    if type(id) ~= "string" or id == "" or type(items) ~= "table" or type(rec) ~= "table" then
        return false, "recovery_unverified", detail("request_malformed", {})
    end
    local n, username = #items, S.login(player)
    if n < 1 or n > R.ORIGINS_MAX then
        return false, "recovery_capacity", detail("request_unit_count", { qty = n })
    end
    local heldOpen = R.heldCount(username, true)
    if heldOpen >= R.HELD_LIMIT then
        return false, "recovery_capacity", detail("held_limit_reached", { qty = heldOpen })
    end
    local p = R.playerData(player)
    if p.pendingOuts[id] ~= nil then
        return false, "recovery_pending", detail("operation_in_flight", { opId = id })
    end
    -- The table is the client's: one past the cap is more than any server path writes, and it is
    -- refused before a single record of it is looked into (ECMailbox holds it as pend:oversized).
    local held = 0
    for _ in pairs(p.pendingOuts) do
        held = held + 1
        if held > R.PENDING_MAX then
            return false, "recovery_pending", detail("pending_cap_unconfirmed", { qty = held })
        end
    end
    local origins, byKey, legacy = {}, {}, nil
    for i = 1, n do
        local origin, err, why = R.originOf(items[i])
        if not origin then
            return false, err or "recovery_unverified",
                detail(why or "item_stamp_malformed", { index = i, item = fullTypeOf(items[i]) })
        end
        if origin.src == "legacy" then
            -- Generation zero: delivered before unit tokens existed. It is named from its own
            -- letter or it is refused with the reason an administrator acts on - never waved
            -- through because the shape of its stamp looked close enough.
            if origin.gen0 ~= true then
                -- A protocol 2 stamp this server could not read in full. The object is fine;
                -- what this mod wrote onto it is not, and that is what the answer says.
                return false, "recovery_unverified", detail("item_stamp_malformed",
                    { index = i, item = fullTypeOf(items[i]), itemId = origin.nativeId })
            end
            if legacy == nil then
                legacy = { letters = {}, scan = R.scanUnits(player:getInventory()) }
            end
            if legacy.scan.failed then
                R.hold(username, "inventory", "inventory_unreadable", {})
                return false, "recovery_unverified",
                    detail("inventory_unreadable", { index = i, heldKey = "inventory" })
            end
            local named, info = R.adoptGen0(player, items[i], origin, legacy)
            if not named then
                local kept = R.holdGen0(username, info)
                return false, "recovery_unverified", detail(info.reason or "legacy_source_unknown",
                    { index = i, item = info.item or fullTypeOf(items[i]), itemId = origin.nativeId,
                      mailId = info.mailId, opId = info.opId, epoch = info.epoch, seq = info.seq,
                      qty = info.qty, verdict = R.verdict(info.epoch, info.seq),
                      action = info.reason == "legacy_source_unclaimed" and not S.sameAccount(info.owner, username) and "admin_review" or nil,
                      heldKey = (kept and type(info.mailId) == "string") and ("legacy:" .. info.mailId) or nil })
            end
            origin = named
        end
        local key = originKey(origin)
        if key == nil then
            return false, "recovery_unverified", detail("item_stamp_malformed",
                { index = i, item = origin.item or fullTypeOf(items[i]) })
        end
        if byKey[key] then
            return false, "recovery_conflict", detail("duplicate_unit",
                { index = i, item = origin.item, itemId = origin.nativeId, mailId = origin.mailId })
        end
        local consumed, _, proof = R.consumer(origin)
        if proof == "unreadable" then
            return false, "recovery_unverified", detail("source_state_unknown",
                { index = i, item = origin.item, itemId = origin.nativeId, mailId = origin.mailId,
                  action = "retry" })
        end
        if consumed then
            local reason, heldKey = "unit_already_consumed", nil
            if proof == "locator" then
                reason = "stale_native_copy"
                heldKey = "unit:" .. consumed .. ":" .. tostring(origin.nativeId)
                R.hold(username, heldKey, reason,
                    { opId = consumed, unit = origin.nativeId, item = origin.item, qty = 1 })
            end
            return false, "recovery_conflict", detail(reason, { index = i, item = origin.item,
                itemId = origin.nativeId, mailId = origin.mailId, opId = consumed, heldKey = heldKey })
        end
        if origin.src == "mail" then
            local source = mailEntry(origin.owner, origin.mailId)
            if source then
                local found = false
                for _, token in ipairs(source.units or {}) do
                    if token == origin.unit then found = true; break end
                end
                if not found and R.gen0Unit(origin.unit) then
                    if legacy == nil then legacy = { letters = {}, scan = R.scanUnits(player:getInventory()) } end
                    local problem
                    if legacy.scan.failed then problem = "inventory_unreadable"
                    elseif legacy.scan.duplicates[origin.unit] then problem = "duplicate_unit" end
                    if not problem then
                        local placed
                        placed, problem = R.gen0Admit(source, origin.unit, origin.seq, legacy.scan, true)
                        found = placed ~= nil
                    end
                    if not found then
                        return false, "recovery_unverified", detail(problem or "source_membership_missing",
                            { index = i, item = origin.item, itemId = origin.nativeId,
                              mailId = origin.mailId, epoch = origin.epoch, seq = origin.seq,
                              action = problem == "legacy_source_unclaimed" and not S.sameAccount(origin.owner, username) and "admin_review" or nil })
                    end
                end
                if not found then
                    -- Membership is missing; that alone does not prove the object was spent twice.
                    return false, "recovery_unverified", detail("source_membership_missing",
                        { index = i, item = origin.item, itemId = origin.nativeId,
                          mailId = origin.mailId, epoch = origin.epoch, seq = origin.seq })
                end
                if source.state == "ready" or source.state == "claiming" then
                    return false, "recovery_pending", detail("source_claim_pending",
                        { index = i, item = origin.item, mailId = origin.mailId,
                          qty = tonumber(source.qty), action = not S.sameAccount(origin.owner, username) and "admin_review" or "retry" })
                end
            else
                local verdict = origin.durable == true and "survived" or R.verdict(origin.epoch, origin.seq)
                if verdict ~= "survived" and verdict ~= "current" then
                    -- The letter is gone, so the claim decides. "rolledback" is an answer (that
                    -- delivery did not survive the save); "unknown" is the absence of one (the
                    -- epoch is past the history). Neither says the item itself is broken.
                    return false, "recovery_unverified",
                        detail(verdict == "rolledback" and "source_claim_rolledback" or "source_outcome_unknown",
                            { index = i, item = origin.item, itemId = origin.nativeId,
                              mailId = origin.mailId, epoch = origin.epoch, seq = origin.seq,
                              verdict = verdict })
                end
            end
        end
        byKey[key], origins[i] = i, origin
    end
    local open = 0
    for pid, pend in pairs(p.pendingOuts) do
        -- a value this server never wrote (the player's table is the client's) is not an operation
        if type(pend) == "table" then open = open + 1 end
        local list = type(pend) == "table" and type(pend.origins) == "table" and pend.origins or {}
        for at, origin in ipairs(list) do
            if at > R.ORIGINS_MAX then break end   -- no operation this server wrote has more
            local key = type(origin) == "table" and originKey(origin) or nil
            local index = key and byKey[key] or nil
            if index == nil and type(origin) == "table" and origin.nativeId ~= nil then
                index = byKey["n:" .. tostring(origin.nativeId)]
            end
            if index then
                local hit = origins[index]
                return false, "recovery_conflict", detail("unit_in_pending_operation",
                    { index = index, item = hit.item, itemId = hit.nativeId, mailId = hit.mailId, opId = pid })
            end
        end
    end
    for _, receipt in ipairs(R.ownerReceipts(username)) do
        for _, unit in ipairs(receipt.units or {}) do
            local key = unit.t or (unit.n ~= nil and "n:" .. tostring(unit.n) or nil)
            local index = key and byKey[key] or nil
            if index == nil and unit.n ~= nil then index = byKey["n:" .. tostring(unit.n)] end
            if index then
                local hit = origins[index]
                return false, "recovery_conflict", detail("unit_already_consumed",
                    { index = index, item = hit.item, itemId = hit.nativeId, mailId = hit.mailId, opId = receipt.id })
            end
        end
    end
    if open >= R.PENDING_MAX then
        for pid, pend in pairs(p.pendingOuts) do
            if type(pend) == "table" and not pend.abortIncomplete and R.hasOut(pid) and R.verdict(pend.epoch, tonumber(pend.seq)) == "survived" then
                p.pendingOuts[pid], open = nil, open - 1
            end
        end
        if open >= R.PENDING_MAX then
            -- Every record still here is an operation no world save has judged yet. The wait is
            -- the whole of the fix: no evidence is evicted to make room for this request.
            return false, "recovery_pending", detail("pending_cap_unconfirmed", { qty = open })
        end
    end
    local admitted, err = R.reserveOut(username, id)
    if not admitted then
        return false, err, detail(err == "recovery_capacity" and "receipt_capacity_reached"
            or "recovery_state_unavailable", { opId = id })
    end
    -- The save hours the objects leave at, for the journal line finishOut writes (R.outOrder).
    outAnchors[id] = { h = hoursOf(player), life = R.life(username), sess = R.session(player).sid }
    -- Name a native unit before the first handover; keep its engine id unchanged.
    for i, origin in ipairs(origins) do
        if origin.src == "native" and origin.unit == nil then
            origin.unit, origin.owner = id .. "#" .. tostring(i), username
            origin.epoch, origin.seq = md.meta.epoch, rec.seq
            items[i]:getModData()[EC.PLAYER_MODDATA_KEY] = { proto = R.PROTOCOL, src = "native",
                unit = origin.unit, owner = username, epoch = origin.epoch, seq = origin.seq }
            local synced, syncError = pcall(syncItemModData, player, items[i])
            if not synced then EC.log("recovery item metadata notification failed: " .. tostring(syncError)) end
        end
    end
    rec.protocol, rec.origins, rec.at = R.PROTOCOL, origins, tonumber(rec.at) or EC.now()
    p.pendingOuts[id] = rec
    local sent = pcall(function() player:transmitModData() end)
    if not sent then
        p.pendingOuts[id] = nil
        R.releaseOut(id)
        return false, "recovery_pending", detail("player_save_not_synced", { opId = id, qty = n })
    end
    return true
end

-- The failure path of a live list-out: the very objects the caller removed go back, keeping their
-- native id and their stamp (a rebuilt replacement would be a new asset with no source). The
-- pending record is cleared only when every object is back; what could not be returned is held.
function R.abortOut(player, id, items)
    if not R.ready() then return false, "recovery_unverified" end
    local username = S.login(player)
    local p = R.playerData(player)
    local inv = player:getInventory()
    R.releaseOut(id)
    local back, stuck = {}, {}
    for _, obj in ipairs(type(items) == "table" and items or {}) do
        if contains(inv, obj) then
            back[#back + 1] = obj
        else
            pcall(function() inv:AddItem(obj) end)
            if contains(inv, obj) then back[#back + 1] = obj else stuck[#stuck + 1] = obj end
        end
    end
    if #back > 0 then
        local list = ArrayList.new()
        for _, obj in ipairs(back) do list:add(obj) end
        local ok, err = pcall(sendAddItemsToContainer, inv, list)
        if not ok then EC.log("recovery abort notification failed: " .. tostring(err)) end
    end
    if #stuck == 0 then
        p.pendingOuts[id] = nil
        R.resolveHold(username, "abort:" .. id, "returned")
        transmit(player)
        return true
    end
    if type(p.pendingOuts[id]) == "table" then p.pendingOuts[id].abortIncomplete = true end
    local units = {}
    for i, obj in ipairs(stuck) do
        if i <= 16 then
            local stamp = R.stampOf(obj)
            units[#units + 1] = (stamp and type(stamp.unit) == "string" and stamp.unit)
                or ("n:" .. tostring(nativeId(obj) or -1))
        end
    end
    R.hold(username, "abort:" .. id, "abort_incomplete",
        { opId = id, qty = #stuck, returned = #back, units = table.concat(units, ",") })
    X.emit("ledger.anomaly", { kind = "recovery", username = username, opId = id, resolution = "abort-incomplete",
        stuck = #stuck, returned = #back })
    transmit(player)
    return false, "recovery_pending"
end

S.Recovery = R
S.onInit(R.init)
return R
