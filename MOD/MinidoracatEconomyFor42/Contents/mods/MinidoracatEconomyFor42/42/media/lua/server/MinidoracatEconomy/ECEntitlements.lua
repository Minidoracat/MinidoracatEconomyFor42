-- MinidoracatEconomyFor42 - generic entitlements (API rev 2, server authority).
--
-- A source (ECIntegration) registers products (ECEntitlementPlans owns their price sheets);
-- players buy permanent units and any number of independent rentals (each with its own units,
-- period, renewal and auto-renew consent), and admins refund a paid order. Consumers read
-- `entitlement.usable` and nothing else (contract supplement 1).
--
-- Global ModData (public, financial only - never vehicle ids, coordinates or ACLs):
--   md.entitlements.rows[modId][username][productId] = Row
--   Row = { rev,                         -- CAS token, only grows; rows are never deleted
--           perm,                        -- committed permanent units (durable or not)
--           pp    = { q, o, epoch, seq, ts, tx } | nil,   -- the part of perm not proven saved
--           rentals = { Rental, ... },   -- creation order, <= RENTALS_MAX; an ended one is pruned
--           orders = { { id, kind, q, amt, cur, tr, rental?, auto?, renewal?, st, epoch, seq, ts, tx,
--                        activatedAt?, prev?, rf? }, ... newest first, <= ORDERS_KEEP },
--           notice = { code, at, error?, rental? } | nil }
--   Rental = { id,                       -- the order id that created it
--              q,                        -- its units, fixed for its whole life
--              lease = { price, D, G, R, cur, amt, tr, start, paidUntil, cycle, last, phase?, reminded? } | nil,
--              pend  = { o, q, price, D, G, R, cur, amt, tr, renewal?, auto?, epoch, seq, ts, tx } | nil,
--              auto  = { on, gen, price?, cur?, D?, tr, rev, why?, epoch, seq, at } | nil }
--   D/G/R are milliseconds (period, grace, reminder); price is the rent per unit; tr is the plan
--   revision the terms came from.
--   A rental is a contract: each period records the terms it was paid under, and an auto-renew
--   consent records the money terms the player agreed to (unit price, currency, period). Renewals run
--   only while the plan still offers exactly those; any other plan edit leaves the consent alone.
--   Rentals are independent of each other; usable is perm + the units of every live rental, and all
--   rentals together stay within plan.rentalLimit.
--
-- Money and entitlement switch together (contract FINAL 1): every check - including the
-- consumer's validatePurchase, called before the row and the quote are read again for the CAS -
-- runs first, then the new rows are built copy-on-write and handed to L.post as a data-only
-- commit descriptor. L.post stamps them and publishes them with rawset after validation and
-- before any wallet moves; listeners and our own notifications run only after both are complete.
--
-- Durability (FINAL 2): only pending children carry stamps (pp, pend, auto, orders, refunds).
-- A stamp is proven saved when it came with the save this process loaded (another epoch, seq <=
-- loadedSeq) or when the companion confirmed this epoch's save up to it. Nothing else counts -
-- not the bounded epoch history, not a clock. Confirmed permanent units and a lease body carry no
-- stamp, so twenty restarts cannot age them away. Unproven payments are pending and never usable.
--
-- Rental activation (FINAL 3-5): once the payment is proven saved, an `act` line naming the order
-- and the activation time is appended to the journal and read back; only then does the period
-- start at that time. A crash before the next world save replays the same time, so any number of
-- crashes gives the same paidUntil. A cancelled or lapsed auto-renew stops at once and appends an
-- `off` line bound to its consent generation, replayed on start against the same generation only;
-- the cancel counts as done only once that line is read back (or the off state is proven saved),
-- and a line that could not be written is owed and written again once it can. A journal that cannot
-- be read, is malformed or full pauses activation and renewals (paused_system) - it never falls
-- back to "now" - while every confirmed entitlement stays usable. The file is only ever emptied as
-- a whole, when no line is needed any more.
--
-- Instant products (registerProduct{ instant = true }) skip that wait: the payment takes effect in
-- its own commit - permanent units straight into perm (no pp), a rental period from the payment time
-- (a renewal continues from paidUntil, past grace from the payment time, like activate) with no `act`
-- line - and an auto-renew consent counts at once, so the scheduler charges it unsaved. Money,
-- units and consent all sit in the same ModData, so a crash rolls them back together. Only a cancel
-- still writes its `off` line (a crash must not bring a cancelled consent back). Their orders, refunds
-- and consents never make the snapshot pending; pp / pend an older save left still settle as above.
--
-- Scheduler: OnTickEvenPaused (fires on an empty dedicated server, AGENTS.md API table), one step
-- per STEP_MS, at most ROWS_PER_STEP rows with rentals per step. Expiry and grace are computed from the clock
-- on every read; the scheduler only sends notices, activates, and charges consented renewals: the
-- first attempt at paidUntil, insufficient funds retried every hour until grace ends (then the
-- consent lapses), other errors paused and retried without touching the consent. A server that was
-- down for several periods charges one period and starts it at activation - no arrears.

if not MinidoracatEconomy or not MinidoracatEconomy.Admin then
    require "MinidoracatEconomy/ECAdmin"
end
if not MinidoracatEconomy or not MinidoracatEconomy.EntitlementPlans then
    require "MinidoracatEconomy/ECEntitlementPlans"
end
local EC = MinidoracatEconomy
local S = EC and EC.Server
local L = EC and EC.Ledger
local X = EC and EC.Export
local G = EC and EC.Integration
local A = EC and EC.Admin
local P = EC and EC.EntitlementPlans
if not S or not S.AUTHORITY or not L or not X or not G or not A or not P then
    return
end

EC.Entitlements = EC.Entitlements or {}
local E = EC.Entitlements

E.QUOTE_TTL_MS = 120000
E.PERMANENT_QTY_MAX = 100
E.ORDERS_KEEP = 20
-- ponytail: a fixed cap on rentals per account keeps the row and the player's list small; raise it
-- (and page the list) if hosts want many small rentals.
E.RENTALS_MAX = 10
E.STEP_MS = 1000
E.ROWS_PER_STEP = 20
E.FUNDS_RETRY_MS = 3600000
E.SYSTEM_RETRY_MS = 600000
E.CONSENT_COOLDOWN_MS = 60000
E.JOURNAL_FILE = "MinidoracatEconomy/entitlements-journal.json"
E.JOURNAL_MAX_LINES = 10000
E.JOURNAL_RETRY_MS = 60000
E.HOUR_MS = 3600000
E.DAY_MS = 86400000
-- ponytail: a fixed ring of quotes closed unpaid, the only "not paid" proof getOrder has for this
-- epoch; past it an old quote reads unknown. Grow it if clients look orders up much later.
E.CLOSED_KEEP = 256

local root, ent = nil, nil          -- ModData root, root.entitlements
local quotes = {}                    -- orderId -> live quote (RAM, this process only)
local quoteOf = {}                   -- rowKey -> orderId of the one live quote
local closed, closedRing, closedAt = {}, {}, 0   -- orderId -> { key, error? } of a quote closed unpaid (ring)
local offOwed = {}                   -- rentalKey -> true: a consent switched off here, its `off` line not read back yet
local waiting = {}                   -- rowKey -> ref: rows with something not yet proven saved
local leaseRefs, leaseSet, cursor = {}, {}, 1
local nextRetry = {}                 -- rentalKey -> ms before which auto-renew does not try again
local cooldown = {}                  -- rentalKey -> ms before which a new consent is refused
local listeners = {}                 -- modId -> { fn, ... }
local journal = { state = "ok", lines = 0, needSeq = 0, readAt = 0 }
local lastStep, lastW, dirty = 0, nil, false
local saveMinutes = false            -- false = not read yet, nil = unknown

-- ---------- small helpers ----------

local function isInt(v)
    return type(v) == "number" and v == math.floor(v) and v > -1e15 and v < 1e15
end

local function validMod(m)
    return type(m) == "string" and #m <= G.MOD_ID_MAX and string.match(m, "^[A-Za-z0-9_%-]+$") ~= nil
end

local function validProduct(p)
    return type(p) == "string" and #p <= P.PRODUCT_ID_MAX and string.match(p, "^[a-z0-9_]+$") ~= nil
end

local function validUser(u)
    return type(u) == "string" and u ~= "" and #u <= 64 and not string.find(u, "%c") and not L.isSystemAccount(u)
end

local function validId(o)
    return type(o) == "string" and o ~= "" and #o <= G.REQUEST_ID_MAX and not string.find(o, "%c")
end

local function fail(code)
    return { ok = false, error = code }
end

local function rowKey(m, u, p)
    return m .. "\1" .. u .. "\1" .. p
end

local function rowOf(m, u, p)
    local byUser = ent and ent.rows[m]
    local byProduct = byUser and byUser[u]
    return byProduct and byProduct[p] or nil
end

local function rowsOf(m)
    local byUser = ent.rows[m]
    if not byUser then
        byUser = {}
        ent.rows[m] = byUser
    end
    return byUser
end

local function copyTable(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

-- One rental of a row by id (and its index), or nil.
local function rentalOf(row, id)
    for i, r in ipairs(row and row.rentals or {}) do
        if r.id == id then return r, i end
    end
    return nil
end

-- Process state that belongs to one rental (retry clock, consent cooldown, owed off line).
local function rentalKey(ref, id)
    return rowKey(ref.m, ref.u, ref.p) .. "\1" .. tostring(id)
end

-- The copy-on-write start of every financial change: a new row table (rev + 1) with new orders and
-- rentals arrays; nested tables (a rental included) are replaced, never edited.
local function nextRowOf(row)
    local out = row and copyTable(row) or {}
    out.rev = (out.rev or 0) + 1
    out.perm = out.perm or 0
    local orders, rentals = {}, {}
    for i, o in ipairs(row and row.orders or {}) do orders[i] = o end
    for i, r in ipairs(row and row.rentals or {}) do rentals[i] = r end
    out.orders, out.rentals = orders, rentals
    return out
end

local function trackLease(ref)
    local k = rowKey(ref.m, ref.u, ref.p)
    if leaseSet[k] then return end
    leaseSet[k] = true
    leaseRefs[#leaseRefs + 1] = ref
end

local function wait(ref)
    waiting[rowKey(ref.m, ref.u, ref.p)] = ref
end

-- ---------- durability ----------

-- "confirmed" when the stamp came with the save this process loaded or is inside this epoch's
-- companion watermark `w`; "pending" for this epoch above it; "unknown" for anything else.
local function verdict(stamp, w)
    if type(stamp) ~= "table" then return "unknown" end
    local e, s = stamp.epoch, stamp.seq
    if type(e) ~= "string" or not isInt(s) then return "unknown" end
    if e ~= root.meta.epoch then
        if s <= root.meta.loadedSeq then return "confirmed" end
        return "unknown"
    end
    if w ~= nil and s <= w then return "confirmed" end
    return "pending"
end

local function pendingPermanent(row, w)
    if row.pp and verdict(row.pp, w) ~= "confirmed" then return row.pp.q end
    return 0
end

local function leaseLive(lease, now)
    return lease ~= nil and now < lease.paidUntil + lease.G
end

-- Rented units that count against plan.rentalLimit: every rental live now or with a payment on the
-- way (`except` leaves one rental out, for its own renewal).
local function committed(row, now, except)
    local n = 0
    for _, r in ipairs(row and row.rentals or {}) do
        if r ~= except and (r.pend ~= nil or leaseLive(r.lease, now)) then n = n + r.q end
    end
    return n
end

-- Rented units usable now.
local function rentedLive(row, now)
    local n = 0
    for _, r in ipairs(row and row.rentals or {}) do
        if leaseLive(r.lease, now) then n = n + r.q end
    end
    return n
end

-- The money terms a consent was given for, against the plan as it stands: auto-renew charges only
-- while they are the same. A changed price, currency or period waits for the player's new consent.
local function sameTerms(auto, plan)
    return auto.price == plan.rentalPrice and auto.cur == plan.rentalCurrency and auto.D == plan.rentalDays * E.DAY_MS
end

-- `instant`: the product's orders, refunds and consents take effect when committed; only pp / pend
-- an older save left can still be pending.
local function hasPending(row, w, instant)
    if pendingPermanent(row, w) > 0 then return true end
    for _, r in ipairs(row.rentals or {}) do
        if r.pend or (not instant and r.auto and verdict(r.auto, w) ~= "confirmed") then return true end
    end
    if instant then return false end
    for _, o in ipairs(row.orders or {}) do
        if verdict(o, w) ~= "confirmed" then return true end
        if o.rf and verdict(o.rf, w) ~= "confirmed" then return true end
    end
    return false
end

local function serverSaveMinutes()
    if saveMinutes == false then
        local ok, v = pcall(function() return getServerOptions():getInteger("SaveWorldEveryMinutes") end)
        saveMinutes = ok and type(v) == "number" and v or nil
    end
    return saveMinutes
end

-- Why something is still pending, for the player (oracle section 4).
local function waitInfo(ds)
    if journal.state ~= "ok" then return { code = "journal_blocked", journal = journal.state } end
    local code = "await_restart"
    if ds.status == "confirmed" then
        code = "await_save"
    elseif ds.status == "idle" or ds.status == "other_epoch" then
        code = "await_first_save"
    end
    return { code = code, saveMinutes = serverSaveMinutes(), confirmedAgoMs = ds.ageMs }
end

-- ---------- journal ----------

-- All lines, or nil + "unreadable" | "full". A missing file is an empty journal; a file that
-- exists but cannot be opened is not (getFileReader returns nil for both, LuaManager.java:5949-5960).
local function readJournal()
    local reader = nil
    local ok = pcall(function() reader = getFileReader(E.JOURNAL_FILE, false) end)
    if not ok or not reader then
        local checked, exists = pcall(cacheFileExists, E.JOURNAL_FILE)
        if checked and not exists then return {} end
        return nil, "unreadable"
    end
    local lines, over = {}, false
    local readOk = pcall(function()
        for _ = 1, E.JOURNAL_MAX_LINES + 1 do
            local line = reader:readLine()
            if line == nil then return end
            lines[#lines + 1] = line
        end
        over = true
    end)
    pcall(function() reader:close() end)
    if not readOk then return nil, "unreadable" end
    if over then return nil, "full" end
    return lines
end

local function parseLine(text)
    local rec = EC.jsonDecode(text)
    if type(rec) ~= "table" or type(rec.realm) ~= "string" or type(rec.src) ~= "string"
        or type(rec.acct) ~= "string" or type(rec.prod) ~= "string" then
        return nil
    end
    if rec.k == "act" then
        if type(rec.o) ~= "string" or not isInt(rec.at) then return nil end
    elseif rec.k == "off" then
        if not isInt(rec.gen) then return nil end
    else
        return nil
    end
    return rec
end

-- getFileWriter reports no I/O error (family pitfalls), so a line counts only once it is read back.
-- A failure pauses activation and renewals; the file is read again after JOURNAL_RETRY_MS.
local function appendJournal(rec)
    if journal.state ~= "ok" then return false end
    local lines, why = nil, "full"
    if journal.lines < E.JOURNAL_MAX_LINES then
        local text = EC.jsonEncode(rec)
        local writer, wrote = nil, false
        local opened = pcall(function() writer = getFileWriter(E.JOURNAL_FILE, true, true) end)
        if opened and writer then
            wrote = pcall(function() writer:writeln(text) end)
            pcall(function() writer:close() end)
        end
        lines, why = readJournal()
        if lines ~= nil then
            journal.lines = #lines
            if wrote and lines[#lines] == text then return true end
            why = "write_failed"
        end
    end
    journal.state, journal.readAt = why, EC.now()
    EC.log("entitlement journal append failed (" .. tostring(why) .. "); activation and renewals paused")
    return false
end

-- Empty the whole file (never a partial rewrite) once no line in it is needed. Only an empty
-- read-back counts: a writer that does not open (or a file that stays) keeps every line and pauses
-- like a failed append, tried again after JOURNAL_RETRY_MS.
local function truncateJournal()
    local writer = nil
    local ok = pcall(function() writer = getFileWriter(E.JOURNAL_FILE, true, false) end)
    if ok and writer then pcall(function() writer:close() end) end
    local lines, why = readJournal()
    if lines ~= nil then
        journal.lines = #lines
        if #lines == 0 then
            journal.needSeq = 0
            return
        end
        why = "write_failed"
    end
    journal.state, journal.readAt = why, EC.now()
    EC.log("entitlement journal could not be emptied (" .. tostring(why) .. "); lines kept, activation and renewals paused")
end

-- ---------- activation ----------

-- The period payment `pend` buys for a rental whose lease is `lease`, starting at `at`: a lease
-- still live (or in grace) continues from its paidUntil, anything else starts at `at`.
local function nextLeaseOf(pend, lease, at)
    local continuing = lease ~= nil and at < lease.paidUntil + lease.G
    return {
        price = pend.price, D = pend.D, G = pend.G, R = pend.R, cur = pend.cur, amt = pend.amt, tr = pend.tr,
        start = continuing and lease.start or at,
        paidUntil = (continuing and lease.paidUntil or at) + pend.D,
        cycle = (lease and lease.cycle or 0) + 1, last = pend.o, phase = "active",
    }, continuing
end

-- Start (or continue) the paid period of rental `r`'s pending payment at `at`. Only called with the
-- payment proven saved and `at` already in the journal (or read from it).
local function activate(ref, row, r, at)
    local pend, lease = r.pend, r.lease
    local nextLease, continuing = nextLeaseOf(pend, lease, at)
    local orders = {}
    for i, o in ipairs(row.orders) do
        if o.id == pend.o then
            local c = copyTable(o)
            c.prev, c.activatedAt = lease, at
            orders[i] = c
        else
            orders[i] = o
        end
    end
    local seq = S.nextSeq()
    row.orders, r.lease, r.pend = orders, nextLease, nil
    row.rev = row.rev + 1
    row.notice = { code = continuing and "renewed" or "activated", at = at, rental = r.id }
    if seq > journal.needSeq then journal.needSeq = seq end
    trackLease(ref)
    X.emit("entitlement.activated", { sourceMod = ref.m, username = ref.u, productId = ref.p, orderId = pend.o,
        rental = r.id, at = at, paidUntil = nextLease.paidUntil, continuing = continuing })
end

local function startPeriod(ref, row, r, now)
    if journal.state ~= "ok" then return false end
    local ok = appendJournal({ k = "act", realm = root.meta.realmId, src = ref.m, acct = ref.u, prod = ref.p,
        o = r.pend.o, at = now })
    if not ok then
        row.notice = { code = "activation_blocked", at = now, rental = r.id }
        return false
    end
    activate(ref, row, r, now)
    return true
end

-- Switch rental `r`'s consent off: at once in this process (the scheduler stops charging it), then
-- an `off` line bound to that rental and generation, appended and read back. True once that line is
-- in the journal or the off state is proven saved. Until then a crash before the next world save
-- brings the saved consent back, so no caller may report the switch as done: the line stays owed and
-- is tried again by the next call (a resent cancel, settleWaiting once the journal works again).
-- `journaled`: the line was just read from the journal (replay), there is nothing to append.
local function consentOff(ref, row, r, why, now, journaled)
    local k = rentalKey(ref, r.id)
    local auto = r.auto
    nextRetry[k] = nil
    if auto and auto.on then
        local seq = S.nextSeq()
        row.rev = row.rev + 1
        r.auto = { on = false, gen = auto.gen, tr = auto.tr, rev = row.rev, why = why,
            epoch = root.meta.epoch, seq = seq, at = now }
        -- a line that landed but could not be read back is still needed until this state is saved
        if seq > journal.needSeq then journal.needSeq = seq end
        offOwed[k] = true
        wait(ref)
    end
    if offOwed[k] == nil then return true end
    if journaled or verdict(r.auto, S.durableStatus().seq) == "confirmed" or appendJournal({ k = "off",
        realm = root.meta.realmId, src = ref.m, acct = ref.u, prod = ref.p, rental = r.id, gen = r.auto.gen,
        at = now }) then
        offOwed[k] = nil
        return true
    end
    return false
end

-- Read the journal and replay what the loaded rows still need (start, and every retry while it
-- is broken). Lines only ever match their own pending order / rental consent generation; an `off`
-- line without a rental (written before rentals existed) matches nothing.
local function loadJournal(now)
    journal.readAt = now
    local lines, why = readJournal()
    if lines == nil then
        journal.state = why
        return false
    end
    local realm = root.meta.realmId
    local acts, offs = {}, {}
    for _, text in ipairs(lines) do
        if text ~= "" then
            local rec = parseLine(text)
            if rec == nil then
                journal.state = "malformed"
                EC.log("entitlement journal has a malformed line; activation and renewals paused, file kept")
                return false
            end
            local row = rec.realm == realm and rowOf(rec.src, rec.acct, rec.prod) or nil
            if row and rec.k == "act" then
                for _, r in ipairs(row.rentals or {}) do
                    if r.pend and r.pend.o == rec.o then acts[#acts + 1] = rec end
                end
            elseif row and rec.k == "off" then
                local r = rentalOf(row, rec.rental)
                if r and r.auto and r.auto.gen == rec.gen
                    and (r.auto.on or offOwed[rentalKey({ m = rec.src, u = rec.acct, p = rec.prod }, r.id)]) then
                    offs[#offs + 1] = rec    -- a consent to replay, or an owed line that landed after all
                end
            end
        end
    end
    journal.state, journal.lines = "ok", #lines
    for _, rec in ipairs(offs) do
        local row = rowOf(rec.src, rec.acct, rec.prod)
        consentOff({ m = rec.src, u = rec.acct, p = rec.prod }, row, rentalOf(row, rec.rental), "cancel_replayed", now, true)
    end
    for _, rec in ipairs(acts) do
        local ref = { m = rec.src, u = rec.acct, p = rec.prod }
        local row = rowOf(rec.src, rec.acct, rec.prod)
        for _, r in ipairs(row.rentals) do
            if r.pend and r.pend.o == rec.o then activate(ref, row, r, rec.at) end
        end
    end
    if #acts == 0 and #offs == 0 and #lines > 0 and journal.needSeq == 0 then truncateJournal() end
    return true
end

-- ---------- snapshot ----------

local function systemBlock(modId, spec)
    if spec == nil then return "unloaded" end
    local src = G.source(modId)
    if src == nil then return "unloaded" end
    if not src.enabled then return "source_disabled" end
    if journal.state ~= "ok" then return "journal" end
    return nil
end

local function balancesOf(username, plan)
    local out = {}
    local ids = { plan.permanentCurrency, plan.rentalCurrency }
    for _, id in ipairs(ids) do
        if out[id] == nil and EC.CURRENCIES[id] then out[id] = L.getBalance(username, id) end
    end
    return out
end

local function orderView(o, w, ds)
    local v = { orderId = o.id, kind = o.kind, quantity = o.q, amount = o.amt, currency = o.cur,
        termsRevision = o.tr, status = o.st, paid = true, at = o.ts, renewal = o.renewal, rental = o.rental,
        auto = o.auto, activatedAt = o.activatedAt, durable = { status = verdict(o, w), source = ds.source, seq = ds.seq } }
    if o.rf then
        v.refund = { amount = o.rf.amt, at = o.rf.ts, txId = o.rf.tx, by = o.rf.by, durable = { status = verdict(o.rf, w) } }
    end
    return v
end

-- One rental's state. `over`: the account holds more rented units than the plan allows now, so no
-- rental can be renewed under the plan as it stands.
local function rentalState(r, plan, now, blocked, over)
    local lease = r.lease
    local state
    if lease and now < lease.paidUntil then
        state = "active"
    elseif lease and now < lease.paidUntil + lease.G then
        state = "grace"
    elseif r.pend then
        state = "pending"
    else
        state = "expired"
    end
    if state == "pending" and blocked == "journal" then return "paused_system" end
    if state == "active" then
        if blocked then return "paused_system" end
        if not plan.rentalEnabled or over then return "paused_terms" end
    end
    return state
end

-- `owed`: an instant product's cancel whose `off` line is not in the journal yet.
local function autoStateOf(r, planRow, w, blocked, over, instant, owed)
    local auto = r.auto
    if auto == nil then return "off" end
    local proven = instant or verdict(auto, w) == "confirmed"
    if not auto.on then return (proven and not owed) and "off" or "pending_off" end
    if blocked then return "paused_system" end
    local plan = planRow.values
    if not sameTerms(auto, plan) or not plan.rentalEnabled or not plan.autoRenewAllowed or over then
        return "paused_terms"
    end
    return proven and "on" or "pending_on"
end

-- What the contract says: the terms of the period it runs (or is paid for), and the money terms its
-- auto-renew consent was given for.
local function rentalView(r, planRow, now, w, blocked, over, ref, instant)
    local lease, pend, auto = r.lease, r.pend, r.auto
    local t = lease or pend
    local owed = instant and offOwed[rentalKey(ref, r.id)] == true
    return { id = r.id, quantity = r.q, state = rentalState(r, planRow.values, now, blocked, over),
        paidUntil = lease and lease.paidUntil or nil, graceUntil = lease and (lease.paidUntil + lease.G) or nil,
        autoRenew = auto ~= nil and auto.on == true, autoRenewState = autoStateOf(r, planRow, w, blocked, over, instant, owed),
        termsRevision = t and t.tr or nil,
        terms = t and { price = t.price, amount = t.amt, currency = t.cur, days = t.D / E.DAY_MS,
            graceHours = t.G / E.HOUR_MS } or nil,
        autoTerms = (auto and auto.on and auto.price) and { price = auto.price, currency = auto.cur,
            days = auto.D / E.DAY_MS } or nil,
        pendingOrderId = pend and pend.o or nil, autoPending = (pend and pend.auto) or nil }
end

local function entitlementView(row, planRow, now, ds, blocked, ref, instant)
    local w = ds.seq
    local out = { revision = 0, permanent = 0, rental = 0, usable = 0, state = "none", pendingQuantity = 0,
        rentalCommitted = 0, rentalsMax = E.RENTALS_MAX, rentals = {},
        durable = { status = "confirmed", source = ds.source, seq = ds.seq, companion = ds.status, journal = journal.state } }
    if row == nil then return out end
    local pendPerm = pendingPermanent(row, w)
    local perm = (row.perm or 0) - pendPerm
    local held = committed(row, now)
    -- a plan row an older version saved may lack the limit (its product is not loaded then)
    local over = held > (planRow.values.rentalLimit or 0)
    local rental, pendRent = 0, 0
    for i, r in ipairs(row.rentals or {}) do
        if leaseLive(r.lease, now) then
            rental = rental + r.q
        elseif r.pend then
            pendRent = pendRent + r.q
        end
        out.rentals[i] = rentalView(r, planRow, now, w, blocked, over, ref, instant)
    end
    out.revision, out.permanent, out.rental, out.usable = row.rev or 0, perm, rental, perm + rental
    out.rentalCommitted, out.pendingQuantity = held, pendPerm + pendRent
    if out.usable > 0 then
        out.state = "active"
    elseif out.pendingQuantity > 0 then
        out.state = "pending"
    end
    -- the newest payment the player started that is not proven saved: a renewal the scheduler
    -- charged is the server's own, never something the player has to look up; an instant product's
    -- payment has nothing to wait for
    for _, o in ipairs(row.orders or {}) do
        if out.lastOrderId == nil then out.lastOrderId = o.id end
        if not instant and out.pendingOrderId == nil and o.st == "paid" and not o.auto and verdict(o, w) ~= "confirmed" then
            out.pendingOrderId = o.id
        end
    end
    if hasPending(row, w, instant) then
        out.durable.status = "pending"
        out.wait = waitInfo(ds)
    end
    if row.notice then
        out.notice = { code = row.notice.code, kind = row.notice.code, at = row.notice.at, error = row.notice.error,
            rental = row.notice.rental }
    end
    return out
end

-- The envelope of the contract, or nil when the product was never seen. Pure read: creates no
-- row, no wallet, nothing in ModData.
local function snapshot(modId, username, productId)
    local planRow = P.row(modId, productId)
    if not planRow then return nil end
    local spec = P.product(modId, productId)
    local instant = spec ~= nil and spec.instant
    local blocked = systemBlock(modId, spec)
    local plan = planRow.values
    local now, ds = EC.now(), S.durableStatus()
    local row = rowOf(modId, username, productId)
    local env = { ok = true, sourceMod = modId, productId = productId, nameKey = planRow.nameKey,
        instant = instant or nil,
        available = spec ~= nil and blocked ~= "source_disabled" and blocked ~= "unloaded" and not planRow.provisional
            and (plan.permanentEnabled or plan.rentalEnabled),
        plan = P.copy(planRow),
        entitlement = entitlementView(row, planRow, now, ds, blocked, { m = modId, u = username, p = productId }, instant),
        balances = balancesOf(username, plan), orders = {} }
    for _, o in ipairs(row and row.orders or {}) do env.orders[#env.orders + 1] = orderView(o, ds.seq, ds) end
    return env
end

-- After a complete change: the owner's client gets the envelope, then each consumer listener
-- (isolated; a failure is logged and changes nothing that was committed).
-- Rows belong to login names (the money behind them is the account's, resolved by the ledger).
local function changed(modId, username, productId)
    local player = S.onlineLogin(username)
    if player then
        local env = snapshot(modId, username, productId)
        if env then S.reply(player, "entitlement.changed", env) end
    end
    local list = listeners[modId]
    if not list then return end
    for _, fn in ipairs(list) do
        local env = snapshot(modId, username, productId)
        local ok, err = pcall(fn, username, productId, env)
        if not ok then EC.log("entitlement listener of " .. modId .. " failed: " .. tostring(err)) end
    end
end

local function withSnapshot(res, modId, username, productId)
    res.snapshot = snapshot(modId, username, productId)
    return res
end

-- ---------- pricing ----------

-- The currency half of the payment gate, shared with a new auto-renew consent (a promise to pay in
-- that currency): nil or the refusal code.
local function currencyGate(src, cur)
    if not src.currencies[cur] then return "currency_not_allowed" end
    local cfg = L.currency(cur)
    if not cfg then return "unknown_currency" end
    -- the ledger only refuses money *into* a disabled currency; paying out of one is policy here
    if not cfg.enabled then return "currency_disabled" end
    return nil
end

-- Every rule a new payment must pass, shared by quote, purchase and auto-renew. `rentalId` names the
-- rental a "rental" payment renews (nil: a new rental). Returns { kind, q, amt, cur, renewal, rental }
-- or nil, error.
local function priceOf(modId, planRow, row, username, kind, quantity, now, w, rentalId)
    local plan = planRow.values
    if planRow.provisional then return nil, "product_unavailable" end
    local src = G.source(modId)
    if not src then return nil, "product_unavailable" end
    if not src.enabled then return nil, "source_disabled" end
    if L.isFrozen(username) then return nil, "account_frozen" end
    local cur, amt, q, renewal, target
    if kind == "permanent" then
        if not plan.permanentEnabled then return nil, "kind_disabled" end
        if rentalId ~= nil then return nil, "invalid_args" end
        q = quantity == nil and 1 or quantity
        if not isInt(q) or q < 1 or q > E.PERMANENT_QTY_MAX then return nil, "invalid_args" end
        local held = row and row.perm or 0
        if plan.permanentLimit <= 0 or held + q > plan.permanentLimit then return nil, "limit_reached" end
        cur, amt = plan.permanentCurrency, plan.permanentPrice * q
    elseif kind == "rental" then
        if not plan.rentalEnabled then return nil, "kind_disabled" end
        if journal.state ~= "ok" then return nil, "journal_unavailable" end
        if rentalId == nil then
            q = quantity == nil and 1 or quantity
            if not isInt(q) or q < 1 then return nil, "invalid_args" end
            if #(row and row.rentals or {}) >= E.RENTALS_MAX then return nil, "rental_count_limit" end
            if committed(row, now) + q > plan.rentalLimit then return nil, "limit_reached" end
        else
            local r = rentalOf(row, rentalId)
            if not r then return nil, "rental_unknown" end
            if quantity ~= nil and quantity ~= r.q then return nil, "invalid_args" end
            if r.pend then return nil, "lease_pending" end
            -- a renewal keeps the units; over the limit nothing renews until other rentals end
            if committed(row, now, r) + r.q > plan.rentalLimit then return nil, "limit_reached" end
            q, renewal, target = r.q, leaseLive(r.lease, now), r.id
        end
        cur, amt = plan.rentalCurrency, plan.rentalPrice * q
    else
        return nil, "invalid_args"
    end
    local bad = currencyGate(src, cur)
    if bad then return nil, bad end
    if L.getBalance(username, cur).available < amt then return nil, "insufficient_funds" end
    return { kind = kind, q = q, amt = amt, cur = cur, renewal = renewal == true, rental = target }
end

-- What the row would look like after the payment, for the consumer's own gate.
local function projection(row, kind, q, now, w, rentalId)
    local pendPerm = row and pendingPermanent(row, w) or 0
    local perm = (row and row.perm or 0) - pendPerm
    local rental = rentedLive(row, now)
    local r = rentalId and rentalOf(row, rentalId) or nil
    local adds = kind == "rental" and not (r and leaseLive(r.lease, now))
    return { permanent = perm + pendPerm + (kind == "permanent" and q or 0),
        rental = rental + (adds and q or 0), usable = perm + rental,
        pendingQuantity = pendPerm + q }
end

-- The consumer's validatePurchase: nil when it passes, otherwise the refusal code. A throw fails
-- closed and is logged.
local function consumerCheck(spec, username, kind, q, projected)
    local fn = spec.validatePurchase
    if fn == nil then return nil end
    local ok, pass, reason = pcall(fn, username, spec.id, kind, q, projected)
    if not ok then
        EC.log("validatePurchase of " .. spec.modId .. "/" .. spec.id .. " failed: " .. tostring(pass))
        return "validation_failed"
    end
    if pass == true then return nil end
    if type(reason) == "string" and #reason <= 32 and string.match(reason, "^[A-Za-z0-9_]+$") then return reason end
    return "purchase_refused"
end

-- ---------- settle (the one path money buys an entitlement) ----------

local function findOrder(modId, username, orderId)
    local byUser = ent.rows[modId]
    local byProduct = byUser and byUser[username]
    for productId, row in pairs(byProduct or {}) do
        for _, o in ipairs(row.orders or {}) do
            if o.id == orderId then return o, productId end
        end
    end
    return nil
end

-- `row` and `terms` must have been read after every callback; nothing below calls out.
-- An instant product's payment takes effect right here (header); any other waits for its save.
local function settle(spec, planRow, username, row, terms, orderId, reasonCode)
    local modId, productId, instant = spec.modId, spec.id, spec.instant
    local now = EC.now()
    local bySource = rowsOf(modId)
    local user = bySource[username] and copyTable(bySource[username]) or {}
    local nextRow = nextRowOf(row)
    local auto = reasonCode == "entitlement_renewal" or nil
    local order = { id = orderId, kind = terms.kind, q = terms.q, amt = terms.amt, cur = terms.cur,
        tr = planRow.revision, renewal = terms.renewal or nil, st = "paid", auto = auto,
        activatedAt = instant and now or nil }
    table.insert(nextRow.orders, 1, order)
    while #nextRow.orders > E.ORDERS_KEEP do table.remove(nextRow.orders) end
    local stamps = { order }
    local lease, continuing = nil, nil
    nextRow.notice = nil
    if terms.kind == "permanent" then
        nextRow.perm = nextRow.perm + terms.q
        if not instant then
            local w = S.durableStatus().seq
            local carry = row and pendingPermanent(row, w) or 0
            local pp = { q = carry + terms.q, o = orderId }
            nextRow.pp = pp
            stamps[2] = pp
        end
    else
        local plan = planRow.values
        local pend = { o = orderId, q = terms.q, price = plan.rentalPrice, D = plan.rentalDays * E.DAY_MS,
            G = plan.graceHours * E.HOUR_MS, R = plan.reminderHours * E.HOUR_MS, cur = terms.cur, amt = terms.amt,
            tr = planRow.revision, renewal = terms.renewal or nil, auto = auto }
        local r
        if terms.rental then
            local old, i = rentalOf(nextRow, terms.rental)
            if not old then return fail("state_mismatch") end
            r = copyTable(old)
            nextRow.rentals[i] = r
        else
            r = { id = orderId, q = terms.q }
            nextRow.rentals[#nextRow.rentals + 1] = r
        end
        order.rental = r.id
        if instant then
            lease, continuing = nextLeaseOf(pend, r.lease, now)
            order.prev, r.lease = r.lease, lease
            nextRow.notice = { code = continuing and "renewed" or "activated", at = now, rental = r.id }
        else
            r.pend = pend
            stamps[2] = pend
        end
    end
    user[productId] = nextRow
    local res = G.entitlementPost({
        modId = modId, requestId = orderId, reasonCode = reasonCode,
        ref = { type = "entitlement", id = productId }, meta = { kind = terms.kind, qty = terms.q, orderId = orderId },
        postings = {
            { account = username, currency = terms.cur, amount = -terms.amt },
            { account = G.account(modId), currency = terms.cur, amount = terms.amt },
        },
    }, { commit = { into = bySource, key = username, value = user, stamps = stamps } })
    if not res.ok then return fail(res.error) end
    if res.duplicate then
        -- that key already paid and published; answer from the ring, never publish again
        local found = findOrder(modId, username, orderId)
        if not found then return fail("state_mismatch") end
        return { ok = true, duplicate = true, orderId = orderId, txId = found.tx }
    end
    local ref = { m = modId, u = username, p = productId }
    wait(ref)
    if lease then trackLease(ref) end
    X.emit("entitlement.order", { sourceMod = modId, username = username, productId = productId, orderId = orderId,
        kind = terms.kind, quantity = terms.q, amount = terms.amt, currency = terms.cur, txId = res.txId,
        termsRevision = planRow.revision, renewal = terms.renewal or nil, rental = order.rental })
    if instant then
        X.emit("entitlement.activated", { sourceMod = modId, username = username, productId = productId, orderId = orderId,
            kind = terms.kind, rental = order.rental, at = now, paidUntil = lease and lease.paidUntil or nil,
            continuing = continuing })
    end
    changed(modId, username, productId)
    return { ok = true, orderId = orderId, txId = res.txId, duplicate = false }
end

-- ---------- quotes ----------

-- A quote leaves unpaid: remembered (bounded) as getOrder's proof, with the refusal if there was one.
local function closeQuote(q, err)
    quotes[q.id] = nil
    if quoteOf[q.key] == q.id then quoteOf[q.key] = nil end
    closedAt = closedAt % E.CLOSED_KEEP + 1
    local old = closedRing[closedAt]
    if old then closed[old] = nil end
    closedRing[closedAt] = q.id
    closed[q.id] = { key = q.key, error = err or q.lastError }
end

function E.quote(modId, username, productId, kind, quantity, rental)
    if not ent then return fail("not_ready") end
    if not validMod(modId) or not validUser(username) or not validProduct(productId)
        or (rental ~= nil and not validId(rental)) then
        return fail("invalid_args")
    end
    local planRow = P.row(modId, productId)
    if not planRow then return fail("unknown_product") end
    local spec = P.product(modId, productId)
    if not spec then return withSnapshot(fail("product_unavailable"), modId, username, productId) end
    local now, w = EC.now(), S.durableStatus().seq
    local row = rowOf(modId, username, productId)
    local terms, err = priceOf(modId, planRow, row, username, kind, quantity, now, w, rental)
    if not terms then return withSnapshot(fail(err), modId, username, productId) end
    local refusal = consumerCheck(spec, username, terms.kind, terms.q,
        projection(row, terms.kind, terms.q, now, w, terms.rental))
    if refusal then return withSnapshot(fail(refusal), modId, username, productId) end
    -- the callback may have changed anything: price again from what is there now
    planRow, row = P.row(modId, productId), rowOf(modId, username, productId)
    terms, err = priceOf(modId, planRow, row, username, kind, quantity, now, w, rental)
    if not terms then return withSnapshot(fail(err), modId, username, productId) end
    local k = rowKey(modId, username, productId)
    local old = quoteOf[k] and quotes[quoteOf[k]]
    if old then closeQuote(old, nil) end
    local id = S.newId()
    local q = { id = id, key = k, m = modId, u = username, p = productId, kind = terms.kind, q = terms.q,
        amt = terms.amt, cur = terms.cur, tr = planRow.revision, rev = row and row.rev or 0,
        renewal = terms.renewal, rental = terms.rental, expiresAt = now + E.QUOTE_TTL_MS }
    quotes[id], quoteOf[k] = q, id
    return withSnapshot({ ok = true, quote = { id = id, orderId = id, kind = q.kind, quantity = q.q, currency = q.cur,
        amount = q.amt, termsRevision = q.tr, expiresAt = q.expiresAt, ttlMs = E.QUOTE_TTL_MS, renewal = q.renewal,
        rental = q.rental } },
        modId, username, productId)
end

function E.purchase(modId, username, orderId)
    if not ent then return fail("not_ready") end
    if not validMod(modId) or not validUser(username) or not validId(orderId) then return fail("invalid_args") end
    local q = quotes[orderId]
    if q == nil or q.u ~= username or q.m ~= modId then
        local found, productId = findOrder(modId, username, orderId)
        if found then
            return withSnapshot({ ok = true, duplicate = true, orderId = orderId, txId = found.tx }, modId, username, productId)
        end
        return fail("quote_unknown")
    end
    local productId = q.p
    local now = EC.now()
    if now > q.expiresAt then
        closeQuote(q, nil)
        return withSnapshot(fail("quote_expired"), modId, username, productId)
    end
    local spec = P.product(modId, productId)
    if not spec then return withSnapshot(fail("product_unavailable"), modId, username, productId) end
    local w = S.durableStatus().seq
    local refusal = consumerCheck(spec, username, q.kind, q.q,
        projection(rowOf(modId, username, productId), q.kind, q.q, now, w, q.rental))
    if refusal then
        q.lastError = refusal
        return withSnapshot(fail(refusal), modId, username, productId)
    end
    -- read everything again after the callback: the quote, the plan, the row (CAS)
    q = quotes[orderId]
    if q == nil or q.u ~= username or q.m ~= modId then return fail("quote_unknown") end
    local planRow = P.row(modId, productId)
    if not planRow or planRow.revision ~= q.tr then
        closeQuote(q, "stale_terms")
        return withSnapshot(fail("stale_terms"), modId, username, productId)
    end
    local row = rowOf(modId, username, productId)
    if (row and row.rev or 0) ~= q.rev then
        closeQuote(q, "stale_quote")
        return withSnapshot(fail("stale_quote"), modId, username, productId)
    end
    local terms, err = priceOf(modId, planRow, row, username, q.kind, q.q, now, w, q.rental)
    if terms and (terms.amt ~= q.amt or terms.cur ~= q.cur or terms.q ~= q.q or terms.renewal ~= q.renewal
        or terms.rental ~= q.rental) then
        terms, err = nil, "stale_quote"
    end
    if not terms then
        q.lastError = err
        if err == "stale_quote" then closeQuote(q, err) end
        return withSnapshot(fail(err), modId, username, productId)
    end
    local res = settle(spec, planRow, username, row, terms, orderId, "entitlement_purchase")
    if not res.ok then
        q.lastError = res.error
        return withSnapshot(res, modId, username, productId)
    end
    quotes[orderId] = nil
    if quoteOf[q.key] == orderId then quoteOf[q.key] = nil end
    return withSnapshot(res, modId, username, productId)
end

-- ---------- reads ----------

function E.getEntitlement(modId, username, productId)
    if not ent then return fail("not_ready") end
    if not validMod(modId) or not validUser(username) or not validProduct(productId) then return fail("invalid_args") end
    local env = snapshot(modId, username, productId)
    if env then return env end
    if G.source(modId) == nil and ent.plans[modId] == nil then return fail("unknown_source") end
    return fail("unknown_product")
end

-- Known with a status (paid / refunded) only for orders in the row's ring; known as proven not paid
-- only with evidence for this very row (FINAL 10): a quote this process issued for it and closed
-- unpaid (the bounded ring). Anything else - another row's order, a quote past the ring, a live
-- quote, or a missing order across a restart - is unknown. An instant product's reply says so
-- (`instant`): its paid / refunded orders took effect when committed, there is no save to wait for.
function E.getOrder(modId, username, productId, orderId)
    if not ent then return fail("not_ready") end
    if not validMod(modId) or not validUser(username) or not validProduct(productId) or not validId(orderId) then
        return fail("invalid_args")
    end
    if not P.row(modId, productId) then return fail("unknown_product") end
    local spec = P.product(modId, productId)
    local instant = (spec ~= nil and spec.instant) or nil
    local function reply(res)
        res.instant = instant
        return withSnapshot(res, modId, username, productId)
    end
    local ds = S.durableStatus()
    local row = rowOf(modId, username, productId)
    for _, o in ipairs(row and row.orders or {}) do
        if o.id == orderId then
            return reply({ ok = true, known = true, order = orderView(o, ds.seq, ds) })
        end
    end
    local k = rowKey(modId, username, productId)
    local unknown = { orderId = orderId, durable = { status = "unknown", source = ds.source, seq = ds.seq } }
    local q = quotes[orderId]
    if q and q.key == k and EC.now() <= q.expiresAt then
        return reply({ ok = true, known = false, quoteState = "active", order = unknown })
    end
    local c = closed[orderId]
    if c and c.key == k then
        -- a quote this process issued for this very source/account/product and closed unpaid
        return reply({ ok = true, known = true, order = { orderId = orderId, status = c.error and "declined" or "unsubmitted",
            paid = false, final = true, error = c.error, durable = { status = "confirmed", source = ds.source, seq = ds.seq } } })
    end
    return reply({ ok = true, known = false, order = unknown })
end

-- ---------- auto-renew consent ----------

function E.setAutoRenew(modId, username, productId, enabled, expectedRevision, termsRevision, rentalId)
    if not ent then return fail("not_ready") end
    if not validMod(modId) or not validUser(username) or not validProduct(productId)
        or type(enabled) ~= "boolean" or not isInt(expectedRevision) or not validId(rentalId) then
        return fail("invalid_args")
    end
    local planRow = P.row(modId, productId)
    if not planRow then return fail("unknown_product") end
    local row = rowOf(modId, username, productId)
    local r = rentalOf(row, rentalId)
    if not r then return withSnapshot(fail("rental_unknown"), modId, username, productId) end
    local rev, auto = row.rev or 0, r.auto
    local ref = { m = modId, u = username, p = productId }
    local k = rentalKey(ref, r.id)
    local now = EC.now()
    if not enabled then
        -- a cancel that is journaled (or saved) is done; one whose line is still owed writes it again
        if not auto or (not auto.on and not offOwed[k]) then
            return withSnapshot({ ok = true, duplicate = true }, modId, username, productId)
        end
        -- source state, terms, a freeze or a currency never block a cancel, but it must name a revision
        -- that already showed this consent generation: a stale cancel cannot switch off a newer consent
        if auto.on and (expectedRevision < (auto.rev or 0) or expectedRevision > rev) then
            return withSnapshot(fail("stale_revision"), modId, username, productId)
        end
        if not G.takeCall(modId) then return withSnapshot(fail("rate_limited"), modId, username, productId) end
        local switched = auto.on
        local done = consentOff(ref, row, r, "cancelled", now)
        if switched then
            X.emit("entitlement.autorenew", { sourceMod = modId, username = username, productId = productId,
                rental = r.id, on = false, gen = auto.gen })
        end
        changed(modId, username, productId)
        -- stopped in this process either way, but without the line a crash before the next save brings
        -- the saved consent back: not reported as done (the snapshot says pending_off, journal_blocked)
        if not done then return withSnapshot(fail("journal_unavailable"), modId, username, productId) end
        return withSnapshot({ ok = true }, modId, username, productId)
    end
    if expectedRevision ~= rev then return withSnapshot(fail("stale_revision"), modId, username, productId) end
    if not isInt(termsRevision) then return fail("invalid_args") end
    if not P.product(modId, productId) or planRow.provisional then
        return withSnapshot(fail("product_unavailable"), modId, username, productId)
    end
    -- the owed line of the last cancel names this generation: no new consent before it is written
    if offOwed[k] then return withSnapshot(fail("journal_unavailable"), modId, username, productId) end
    local src = G.source(modId)
    if not src or not src.enabled then return withSnapshot(fail("source_disabled"), modId, username, productId) end
    local plan = planRow.values
    if not plan.rentalEnabled or not plan.autoRenewAllowed then
        return withSnapshot(fail("autorenew_not_allowed"), modId, username, productId)
    end
    -- a consent is a promise to pay: the account and currency gate of the payments it allows
    if L.isFrozen(username) then return withSnapshot(fail("account_frozen"), modId, username, productId) end
    local bad = currencyGate(src, plan.rentalCurrency)
    if bad then return withSnapshot(fail(bad), modId, username, productId) end
    if termsRevision ~= planRow.revision then return withSnapshot(fail("stale_terms"), modId, username, productId) end
    if not (leaseLive(r.lease, now) or r.pend) then return withSnapshot(fail("no_lease"), modId, username, productId) end
    if auto and auto.on and sameTerms(auto, plan) then return withSnapshot({ ok = true, duplicate = true }, modId, username, productId) end
    if cooldown[k] and now < cooldown[k] then return withSnapshot(fail("rate_limited"), modId, username, productId) end
    if not G.takeCall(modId) then return withSnapshot(fail("rate_limited"), modId, username, productId) end
    row.rev = rev + 1
    r.auto = { on = true, gen = (auto and auto.gen or 0) + 1, price = plan.rentalPrice, cur = plan.rentalCurrency,
        D = plan.rentalDays * E.DAY_MS, tr = termsRevision, rev = row.rev, epoch = root.meta.epoch, seq = S.nextSeq(), at = now }
    cooldown[k] = now + E.CONSENT_COOLDOWN_MS
    wait(ref)
    X.emit("entitlement.autorenew", { sourceMod = modId, username = username, productId = productId, rental = r.id,
        on = true, gen = r.auto.gen, termsRevision = termsRevision })
    changed(modId, username, productId)
    return withSnapshot({ ok = true }, modId, username, productId)
end

-- ---------- refund ----------

-- The exact reversal of one paid order still in the row's ring, at most its amount, once. The units
-- leave in the same commit as the money: permanent units, a rental's pending payment (with the
-- rental itself when it never started) or its latest period (back to the one before, or the rental
-- goes); a rental that already ended and was pruned gives the money back only, for its newest
-- order. Outside the ring an order needs manual reconciliation.
-- opts = { reason, actor?, amount? } (actor defaults to the source).
function E.refund(modId, username, productId, orderId, opts)
    if not ent then return fail("not_ready") end
    if not validMod(modId) or not validUser(username) or not validProduct(productId) or not validId(orderId) then
        return fail("invalid_args")
    end
    opts = type(opts) == "table" and opts or {}
    local reason = opts.reason
    if type(reason) ~= "string" or reason == "" or string.find(reason, "%c") then return fail("invalid_args") end
    local actor = type(opts.actor) == "string" and opts.actor or modId
    local row = rowOf(modId, username, productId)
    local idx, o = nil, nil
    for i, cand in ipairs(row and row.orders or {}) do
        if cand.id == orderId then idx, o = i, cand end
    end
    if not o then return withSnapshot(fail("unknown_order"), modId, username, productId) end
    if o.st == "refunded" then
        return withSnapshot({ ok = true, duplicate = true, orderId = orderId, txId = o.rf and o.rf.tx }, modId, username, productId)
    end
    local amount = opts.amount == nil and o.amt or opts.amount
    if not isInt(amount) or amount < 1 or amount > o.amt then return fail("invalid_args") end
    local now, w = EC.now(), S.durableStatus().seq
    local nextRow = nextRowOf(row)
    local rf = { amt = amount, by = actor, reason = string.sub(reason, 1, 64) }
    local refunded = copyTable(o)
    refunded.st, refunded.rf, refunded.prev = "refunded", rf, nil
    nextRow.orders[idx] = refunded
    local stamps = { rf }
    if o.kind == "permanent" then
        if nextRow.perm < o.q then return withSnapshot(fail("not_refundable"), modId, username, productId) end
        nextRow.perm = nextRow.perm - o.q
        if row.pp and verdict(row.pp, w) ~= "confirmed" and verdict(o, w) ~= "confirmed" then
            local left = row.pp.q - math.min(row.pp.q, o.q)
            local pp = nil
            if left > 0 then
                pp = copyTable(row.pp)
                pp.q = left
            end
            nextRow.pp = pp
        end
    else
        if o.rental == nil then return withSnapshot(fail("refund_not_latest"), modId, username, productId) end
        local r, i = rentalOf(row, o.rental)
        if r then
            local nr = copyTable(r)
            if r.pend and r.pend.o == orderId then
                nr.pend = nil
            elseif r.lease and r.lease.last == orderId and not r.pend then
                nr.lease = o.prev
            else
                return withSnapshot(fail("refund_not_latest"), modId, username, productId)
            end
            if r.auto and r.auto.on then
                nr.auto = { on = false, gen = r.auto.gen, tr = r.auto.tr, rev = nextRow.rev, why = "refunded", at = now }
                stamps[#stamps + 1] = nr.auto
            end
            if nr.lease == nil and nr.pend == nil then
                table.remove(nextRow.rentals, i)
            else
                nextRow.rentals[i] = nr
            end
        else
            for _, other in ipairs(row.orders) do
                if other.rental == o.rental then
                    if other.id ~= orderId then return withSnapshot(fail("refund_not_latest"), modId, username, productId) end
                    break
                end
            end
        end
    end
    nextRow.notice = { code = "refunded", at = now }
    local bySource = rowsOf(modId)
    local user = copyTable(bySource[username])
    user[productId] = nextRow
    local res = G.entitlementPost({
        modId = modId, requestId = "rf:" .. orderId, reasonCode = "entitlement_refund",
        ref = { type = "entitlement_order", id = string.sub(orderId, 1, G.REF_ID_MAX) },
        meta = { productId = productId, orderId = string.sub(orderId, 1, G.META_VALUE_MAX) },
        postings = {
            { account = G.account(modId), currency = o.cur, amount = -amount },
            { account = username, currency = o.cur, amount = amount },
        },
    }, { commit = { into = bySource, key = username, value = user, stamps = stamps }, reversal = o.amt })
    if not res.ok then return withSnapshot(fail(res.error), modId, username, productId) end
    if res.duplicate then
        local found = findOrder(modId, username, orderId)
        if not found or found.st ~= "refunded" then return fail("state_mismatch") end
        return withSnapshot({ ok = true, duplicate = true, orderId = orderId, txId = found.rf and found.rf.tx }, modId, username, productId)
    end
    local ref = { m = modId, u = username, p = productId }
    if #nextRow.rentals > 0 then trackLease(ref) end
    wait(ref)
    X.audit({ action = "entitlement.refund", target = username, sourceMod = modId, productId = productId, orderId = orderId,
        currency = o.cur, amount = amount, before = o.st, after = "refunded", revision = nextRow.rev, txId = res.txId,
        admin = actor, reason = reason })
    changed(modId, username, productId)
    return withSnapshot({ ok = true, orderId = orderId, txId = res.txId, duplicate = false }, modId, username, productId)
end

-- ---------- registration and the source's plan (bound to a source by the handle) ----------

function E.registerProduct(modId, spec)
    local res = P.register(modId, spec)
    if res.ok and ent then rowsOf(modId) end
    return res
end

-- The plan belongs to the source (ECEntitlementPlans): setPlan(productId, values, opts),
-- getPlan(productId), setPlanSource(productId, { file?, problem? }).
E.setPlan, E.getPlan, E.setPlanSource = P.set, P.get, P.setSource

function E.onEntitlementChanged(modId, fn)
    if type(fn) ~= "function" then return fail("invalid_args") end
    local list = listeners[modId]
    if not list then
        list = {}
        listeners[modId] = list
    end
    for _, have in ipairs(list) do
        if have == fn then return { ok = true } end
    end
    list[#list + 1] = fn
    return { ok = true }
end

-- ---------- scheduler ----------

local function lapse(ref, row, r, err, now)
    -- journaled like a cancel; owed while it cannot be written
    consentOff(ref, row, r, err == "limit_reached" and "lapsed_limit" or "lapsed_funds", now)
    row.notice = { code = "renewal_failed", at = now, error = err, rental = r.id }
end

-- A rental due now under a consent to the money terms the plan offers now, with no payment pending.
-- The consent must be proven saved, except for an instant product (header).
local function consented(r, planRow, now, w, instant)
    local auto, lease, plan = r.auto, r.lease, planRow.values
    return auto ~= nil and auto.on == true and r.pend == nil and lease ~= nil and now >= lease.paidUntil
        and (instant or verdict(auto, w) == "confirmed") and sameTerms(auto, plan) and plan.rentalEnabled
        and plan.autoRenewAllowed
end

-- One consented renewal attempt for a rental that is due (auto on, no pending payment).
local function tryRenew(ref, row, r, now, w)
    local id = r.id
    local k = rentalKey(ref, id)
    if nextRetry[k] and now < nextRetry[k] then return end
    local spec, planRow = P.product(ref.m, ref.p), P.row(ref.m, ref.p)
    if not planRow or systemBlock(ref.m, spec) then
        nextRetry[k] = now + E.SYSTEM_RETRY_MS
        return
    end
    -- paused_terms: the snapshot says so; nothing is charged on terms nobody agreed to
    if not consented(r, planRow, now, w, spec.instant) then return end
    local rev, auto = row.rev, r.auto
    local terms, err = priceOf(ref.m, planRow, row, ref.u, "rental", nil, now, w, id)
    if terms then
        err = consumerCheck(spec, ref.u, "rental", terms.q, projection(row, "rental", terms.q, now, w, id))
        if err == nil then
            -- the callback may have changed anything (cancelled and consented again, paid, switched the
            -- source off): charge only the very row revision, consent and terms it was asked about
            spec, planRow, row = P.product(ref.m, ref.p), P.row(ref.m, ref.p), rowOf(ref.m, ref.u, ref.p)
            r = rentalOf(row, id)
            w = S.durableStatus().seq
            if not row or not r or row.rev ~= rev or r.auto ~= auto or not planRow or systemBlock(ref.m, spec)
                or not consented(r, planRow, now, w, spec.instant) then
                return
            end
            terms, err = priceOf(ref.m, planRow, row, ref.u, "rental", nil, now, w, id)
            if terms then
                local res = settle(spec, planRow, ref.u, row, terms, S.newId(), "entitlement_renewal")
                if res.ok then
                    nextRetry[k] = nil
                    return
                end
                err = res.error
            end
        end
    end
    if err == "rate_limited" then return end
    row = rowOf(ref.m, ref.u, ref.p)
    r = rentalOf(row, id)
    if not r or not r.lease then return end
    if err == "insufficient_funds" or err == "limit_reached" then
        -- over the limit waits like missing money (another rental may end first); at the end of grace
        -- the consent lapses and this rental ends
        if now >= r.lease.paidUntil + r.lease.G then
            lapse(ref, row, r, err, now)
        else
            nextRetry[k] = now + E.FUNDS_RETRY_MS
            row.notice = { code = "renewal_failed", at = now, error = err, rental = id }
        end
    else
        nextRetry[k] = now + E.SYSTEM_RETRY_MS
        row.notice = { code = "renewal_failed", at = now, error = err, rental = id }
    end
    changed(ref.m, ref.u, ref.p)
end

-- A rental that ended for good: past grace, nothing paid on the way, no consent that could still
-- charge it (off and proven saved, no off line owed). Nothing is left to show or to renew. An
-- instant product's off consent needs no save: its off line is in the journal, so a crash brings the
-- rental back with the line that switches it off again, and it ends again.
local function ended(ref, r, now, w, instant)
    if r.pend or leaseLive(r.lease, now) then return false end
    local auto = r.auto
    if auto and (auto.on or (not instant and verdict(auto, w) ~= "confirmed")) then return false end
    return not offOwed[rentalKey(ref, r.id)]
end

-- Notices for phase changes and the reminder, then a due renewal, rental by rental; rentals that
-- ended for good leave the row. Returns whether the row still needs scanning.
local function visitLease(ref, now, w)
    local row = rowOf(ref.m, ref.u, ref.p)
    if not row or not row.rentals or #row.rentals == 0 then return false end
    local spec = P.product(ref.m, ref.p)
    local instant = spec ~= nil and spec.instant
    -- a renewal replaces the row: walk the ids and read the row again for each
    local ids = {}
    for i, r in ipairs(row.rentals) do ids[i] = r.id end
    for _, id in ipairs(ids) do
        row = rowOf(ref.m, ref.u, ref.p)
        local r = rentalOf(row, id)
        local lease = r and r.lease
        if lease then
            local phase = "expired"
            if now < lease.paidUntil then
                phase = "active"
            elseif now < lease.paidUntil + lease.G then
                phase = "grace"
            end
            local code = nil
            if phase ~= lease.phase then
                lease.phase = phase          -- bookkeeping of this lease only, no money, no units
                if phase ~= "active" then code = phase end
            end
            if phase == "active" and lease.R > 0 and now >= lease.paidUntil - lease.R and lease.reminded ~= lease.cycle then
                lease.reminded = lease.cycle
                code = "renewal_due"
            end
            if code then
                row.notice = { code = code, at = now, rental = id }
                changed(ref.m, ref.u, ref.p)
            end
            local auto = r.auto
            if auto and auto.on and not r.pend and now >= lease.paidUntil and (instant or verdict(auto, w) == "confirmed") then
                tryRenew(ref, row, r, now, w)
            end
        end
    end
    row = rowOf(ref.m, ref.u, ref.p)
    local kept = {}
    for _, r in ipairs(row.rentals) do
        if not ended(ref, r, now, w, instant) then kept[#kept + 1] = r end
    end
    if #kept ~= #row.rentals then
        -- no money, no units, nothing any quote priced (a renewal of it fails as rental_unknown): no
        -- journal and no new revision, or every open quote of the account would go stale
        row.rentals = kept
        changed(ref.m, ref.u, ref.p)
    end
    return #kept > 0
end

-- Promotions (pp proven saved) and activations (payment proven saved), then a refresh of every
-- row whose durability may have moved.
-- ponytail: walks every waiting row whenever the watermark moves (once a minute at most);
-- index by seq if an uptime ever carries thousands of unsaved rows.
local function settleWaiting(now, w)
    -- listeners may start new payments (which add rows here): walk a fixed copy of the set
    local keys = {}
    for k in pairs(waiting) do keys[#keys + 1] = k end
    for _, k in ipairs(keys) do
        local ref = waiting[k]
        local row = ref and rowOf(ref.m, ref.u, ref.p)
        if row then
            if row.pp and verdict(row.pp, w) == "confirmed" then row.pp = nil end
            for _, r in ipairs(row.rentals or {}) do
                if offOwed[rentalKey(ref, r.id)] then consentOff(ref, row, r, nil, now) end   -- the owed `off` line, again
                if r.pend and verdict(r.pend, w) == "confirmed" then startPeriod(ref, row, r, now) end
            end
            if not hasPending(row, w) then waiting[k] = nil end
            changed(ref.m, ref.u, ref.p)
        elseif ref then
            waiting[k] = nil
        end
    end
end

function E.onTick()
    if not ent then return end
    local now = EC.now()
    if now - lastStep < E.STEP_MS then return end
    lastStep = now
    local w = S.durableStatus().seq
    if journal.state ~= "ok" and now - journal.readAt >= E.JOURNAL_RETRY_MS and loadJournal(now) then dirty = true end
    if w ~= lastW or dirty then
        lastW, dirty = w, false
        settleWaiting(now, w)
    end
    if journal.state == "ok" and journal.lines > 0 and w ~= nil and w >= journal.needSeq then truncateJournal() end
    local expired = {}
    for _, q in pairs(quotes) do
        if now > q.expiresAt then expired[#expired + 1] = q end
    end
    for _, q in ipairs(expired) do closeQuote(q, nil) end
    local n = math.min(E.ROWS_PER_STEP, #leaseRefs)
    for _ = 1, n do
        if cursor > #leaseRefs then cursor = 1 end
        local ref = leaseRefs[cursor]
        if ref == nil then break end
        if visitLease(ref, now, w) then
            cursor = cursor + 1
        else
            leaseSet[rowKey(ref.m, ref.u, ref.p)] = nil
            table.remove(leaseRefs, cursor)
        end
    end
end

-- ---------- lifecycle ----------

function E.init(r)
    root = r
    r.entitlements = r.entitlements or {}
    ent = r.entitlements
    ent.rows = ent.rows or {}
    quotes, quoteOf, closed, closedRing, closedAt, waiting, offOwed = {}, {}, {}, {}, 0, {}, {}
    leaseRefs, leaseSet, cursor, nextRetry, cooldown = {}, {}, 1, {}, {}
    journal = { state = "ok", lines = 0, needSeq = 0, readAt = 0 }
    lastStep, lastW, dirty, saveMinutes = 0, nil, true, false
    P.init(ent)
    for modId in pairs(ent.plans) do rowsOf(modId) end
    for modId, byUser in pairs(ent.rows) do
        for username, byProduct in pairs(byUser) do
            for productId, row in pairs(byProduct) do
                local ref = { m = modId, u = username, p = productId }
                row.orders = row.orders or {}
                row.rentals = row.rentals or {}
                local leased, paying = false, row.pp ~= nil
                for _, r in ipairs(row.rentals) do
                    leased = leased or r.lease ~= nil
                    paying = paying or r.pend ~= nil
                end
                if leased then trackLease(ref) end
                if paying then wait(ref) end
            end
        end
    end
    loadJournal(EC.now())
end

-- Diagnostics for the E2E runner and the admin page. peek returns the live row: read only.
function E.peek(modId, username, productId)
    return rowOf(modId, username, productId)
end

function E.journalStatus()
    return { state = journal.state, lines = journal.lines, needSeq = journal.needSeq }
end

-- ---------- player commands (module MinidoracatEconomy; every reply echoes requestId) ----------

local function requestIdOf(args)
    local id = args.requestId
    if type(id) == "string" and id ~= "" and #id <= G.REQUEST_ID_MAX and not string.find(id, "%c") then return id end
    return nil
end

local function answer(player, command, args, res)
    res.requestId = requestIdOf(args)
    if res.ok == false then
        if res.sourceMod == nil and validMod(args.sourceMod) then res.sourceMod = args.sourceMod end
        if res.productId == nil and validProduct(args.productId) then res.productId = args.productId end
    end
    S.reply(player, command, res)
end

S.handlers["entitlement.state"] = function(player, args)
    answer(player, "entitlement.state", args, E.getEntitlement(args.sourceMod, S.login(player), args.productId))
end

S.handlers["entitlement.quote"] = function(player, args)
    answer(player, "entitlement.quote", args,
        E.quote(args.sourceMod, S.login(player), args.productId, args.kind, args.quantity, args.rental))
end

S.handlers["entitlement.purchase"] = function(player, args)
    answer(player, "entitlement.purchase", args, E.purchase(args.sourceMod, S.login(player), args.quoteId))
end

S.handlers["entitlement.autoRenew"] = function(player, args)
    answer(player, "entitlement.autoRenew", args, E.setAutoRenew(args.sourceMod, S.login(player), args.productId,
        args.enabled, args.expectedRevision, args.termsRevision, args.rental))
end

S.handlers["entitlement.order"] = function(player, args)
    answer(player, "entitlement.order", args,
        E.getOrder(args.sourceMod, S.login(player), args.productId, args.orderId))
end

-- ---------- admin.entitlements ----------

-- Every product this user has a row for (optionally one source / product), as envelopes.
local function accountEntries(username, modId, productId)
    local entries = {}
    for m, byUser in pairs(ent.rows) do
        if modId == nil or m == modId then
            for p in pairs(byUser[username] or {}) do
                if productId == nil or p == productId then entries[#entries + 1] = snapshot(m, username, p) end
            end
        end
    end
    if modId and productId and #entries == 0 then entries[1] = snapshot(modId, username, productId) end
    EC.sortSafe(entries, function(a, b)
        if a.sourceMod ~= b.sourceMod then return a.sourceMod < b.sourceMod end
        return a.productId < b.productId
    end)
    return entries
end

local function adminAccount(args)
    if not validUser(args.username) then return fail("invalid_args") end
    local modId = validMod(args.sourceMod) and args.sourceMod or nil
    local productId = validProduct(args.productId) and args.productId or nil
    return { ok = true, username = args.username, entries = accountEntries(args.username, modId, productId) }
end

local function adminRefund(player, args)
    local bad, reason = A.reasonError(args.reason)
    if bad then return fail(bad) end
    if not validUser(args.username) or not validMod(args.sourceMod) or not validProduct(args.productId) then
        return fail("invalid_args")
    end
    local res = E.refund(args.sourceMod, args.username, args.productId, args.orderId,
        { actor = S.principal(player), reason = reason })
    res.snapshot = nil
    res.username = args.username
    res.entries = accountEntries(args.username, nil, nil)
    return res
end

-- admin.entitlements {action = "plans" | "account" (read) | "refund" (write), ...}. Plans are read
-- only here: the source owns them (setPlan). There is no action that consents to auto-renew for a
-- player.
S.handlers["admin.entitlements"] = function(player, args)
    local action = args.action
    local write = action == "refund"
    local allowed = write and A.isAdmin(player) or (not write and A.canRead(player))
    if not allowed then
        EC.log("admin command admin.entitlements refused for " .. S.claimedName(player) .. " role=" .. A.roleName(player))
        S.reply(player, "admin.entitlements", { ok = false, error = "forbidden", requestId = requestIdOf(args), action = action })
        return
    end
    local res
    if action == "plans" then
        res = { ok = true }
    elseif action == "account" then
        res = adminAccount(args)
    elseif action == "refund" then
        res = adminRefund(player, args)
    else
        res = fail("invalid_args")
    end
    res.action, res.requestId = action, requestIdOf(args)
    res.perms = { read = true, write = A.isAdmin(player) }
    if action == "plans" then
        res.plans = P.list()
        res.journal = E.journalStatus()
    end
    S.reply(player, "admin.entitlements", res)
end

-- ---------- wiring ----------

-- A changed plan is public news without anybody's entitlement in it: clients that hold the
-- product read it again.
P.onChanged = function(modId, productId)
    S.broadcast("entitlement.changed", { sourceMod = modId, productId = productId })
end

S.Entitlements = E
S.onInit(E.init)
Events.OnTickEvenPaused.Add(E.onTick)

-- The facade grows to rev 2 only now that the entitlement half is loaded; `rentals` marks the
-- independent-rentals model (a row holds any number of rentals, see the header); `setPlan` marks
-- source-owned plans (setPlan / getPlan / setPlanSource), instant products and no sandbox mirror.
G.API_REVISION = 2
if EC.v1 then
    EC.v1.API_REVISION = 2
    EC.v1.CAPABILITIES.entitlements = true
    EC.v1.CAPABILITIES.subscriptions = true
    EC.v1.CAPABILITIES.rentals = true
    EC.v1.CAPABILITIES.setPlan = true
end

return E
