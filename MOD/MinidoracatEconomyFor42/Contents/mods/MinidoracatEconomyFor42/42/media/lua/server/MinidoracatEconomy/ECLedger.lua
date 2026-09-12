-- MinidoracatEconomyFor42 — ledger core (server authority).
--
-- Model (spec sections 10-11, 19.3, 19.5, 20):
--   * every mutation is one Transaction with N Postings; per currency the postings sum to 0,
--     so the sum of all accounts (players + system accounts) is always 0 (global conservation);
--   * player accounts are usernames; system accounts carry a prefix (SYSTEM_*, EXTERNAL_*, MOD:*)
--     and may go negative (they are the mint / burn / liability side);
--   * each posting stores the account balance before and after (balance chain, spec 19.5);
--   * requestId makes a transaction idempotent: a resend returns the first result;
--   * nothing here talks to the network or files; ECServer owns commands, ECExport owns files.
--
-- Global ModData is saved only with the world (ServerMap.java:409) and is readable by any
-- logged-in client (GlobalModDataRequestPacket.java:15): current state only, no secrets.

if not MinidoracatEconomy or not MinidoracatEconomy.Server then
    require "MinidoracatEconomy/ECServer"
end
local EC = MinidoracatEconomy
local S = EC and EC.Server
if not S or not S.AUTHORITY then
    return
end

EC.Ledger = EC.Ledger or {}
local L = EC.Ledger

L.RECEIPT_RING = 5              -- per account, spec 20 revision (full history lives in receipt files)
L.IDEMPOTENCY_MAX = 2000        -- LRU, spec 20
L.MAX_ABS_AMOUNT = 1000000000000
L.DEFAULT_BALANCE_MAX = 10000000   -- spec 18 caps.balanceMax default
L.SYSTEM_PREFIXES = { "SYSTEM_", "EXTERNAL_", "MOD:" }
L.BATCH_MAX = 100               -- item ids one operation may name (Shop.ITEMS_PER_BUY_MAX)
L.REQUEST_KEY_MAX = 128         -- the whole namespaced key a transaction is stored under

-- Every caller builds "<what>:<account>:<client id>" and hands that to the ledger, so the
-- length that matters is the whole key, not the client's part of it. Callers check it before
-- they move anything: a key the window cannot store must never end in a completed operation
-- with no idempotency record (report CORE-M2).
function L.validRequestKey(key)
    return type(key) == "string" and key ~= "" and #key <= L.REQUEST_KEY_MAX
end

-- Account kinds
function L.isSystemAccount(account)
    if type(account) ~= "string" then return false end
    for _, prefix in ipairs(L.SYSTEM_PREFIXES) do
        if string.sub(account, 1, #prefix) == prefix then return true end
    end
    return false
end

local function isValidAccount(account)
    return type(account) == "string" and account ~= "" and #account <= 64
end

local function isInteger(n)
    return type(n) == "number" and n == math.floor(n) and math.abs(n) <= L.MAX_ABS_AMOUNT
end

-- ---------- state ----------

local md = nil

function L.init()
    md = S.modData()
    md.wallets = md.wallets or {}
    md.receipts = md.receipts or {}
    md.frozen = md.frozen or {}
    md.idempotency = md.idempotency or { keys = {}, head = 1, count = 0, map = {} }
    md.config = md.config or {}
    md.config.currencies = md.config.currencies or {}
    return md
end

-- Runtime currency view: static registry + ModData overrides (ECConfig owns the override block).
function L.currency(id)
    local static = EC.CURRENCIES[id]
    if not static then return nil end
    local override = md.config.currencies[id] or {}
    return {
        id = id,
        enabled = override.enabled ~= false,
        marketUnit = static.marketUnit,
        balanceMax = type(override.balanceMax) == "number" and override.balanceMax or EC.sandbox("BalanceMax", L.DEFAULT_BALANCE_MAX),
    }
end

-- ---------- trade currency records (spec contract 12 / 13) ----------
--
-- A stored trade record (listing, auction, pending list-out, mailbox entry, buyback receipt)
-- names the currency its money moved in. A record that names one this server knows is that
-- currency; one that names something unknown is never guessed.
--
-- The absence of a currency is only evidence where the absence itself can be trusted. In the
-- server's own Global ModData a record with no currency and no schema mark was written by the
-- single-currency build, so it normalises to L.LEGACY_CURRENCY. A player save is not that: the
-- client can edit or delete fields in it, so a missing currency there proves nothing and a
-- missing schema mark is not a licence to read the record as legacy. Those fail closed and the
-- caller holds them (Main is coordinating what stronger evidence a player-side pending can
-- carry; until then nothing is paid out on a guess).
L.TRADE_SCHEMA = 2
L.LEGACY_CURRENCY = "survivor"
L.TRUST_SERVER = "server"      -- record lives in server-owned Global ModData
L.TRUST_PLAYER = "player"      -- record lives in a save the client can edit (the default)

function L.isCurrency(id)
    return type(id) == "string" and EC.CURRENCIES[id] ~= nil
end

-- The currency of a stored record, or nil when it cannot be proved. `trust` must be
-- L.TRUST_SERVER for the legacy reading to apply at all.
function L.recordCurrency(rec, trust)
    if type(rec) ~= "table" then return nil end
    if rec.currency ~= nil then
        if L.isCurrency(rec.currency) then return rec.currency end
        return nil
    end
    if trust ~= L.TRUST_SERVER then return nil end
    if rec.tradeSchema ~= nil then return nil end
    return L.LEGACY_CURRENCY
end

-- Read boundary (world load, login, restore): normalise in place and mark the record, so the
-- next read never takes a new record for a legacy one. Returns the currency, or nil when the
-- caller has to hold the record instead.
function L.normalizeRecord(rec, trust)
    local id = L.recordCurrency(rec, trust)
    if id == nil then return nil end
    rec.currency, rec.tradeSchema = id, L.TRADE_SCHEMA
    return id
end

-- The exact name of the batch of item ids an operation moves: "<count>:<ids, ascending>". The
-- same physical selection in any order gives the same string and two different selections can
-- never give the same one - this is money-side identity, so it is compared, not hashed.
-- It goes into idemMeta, so a requestId reused for a different batch is a request_conflict
-- instead of being answered with the first batch's result (spec contract 12).
-- `max` is the caller's own cap (<= 100 ids); the shape is checked before anything is sorted,
-- so an unvalidated table can never be walked as one.
function L.batchKey(ids, max)
    if type(ids) ~= "table" then return nil end
    local limit = tonumber(max)
    if limit == nil or limit < 1 or limit > L.BATCH_MAX then return nil end
    local n = #ids
    if n < 1 or n > limit or EC.countKeys(ids) ~= n then return nil end
    for i = 1, n do
        local id = ids[i]
        if type(id) ~= "number" or id ~= math.floor(id) or id < -2147483648 or id > 2147483647 then return nil end
    end
    local copy = {}
    for i = 1, n do copy[i] = ids[i] end
    EC.sortSafe(copy, function(a, b) return a < b end)
    local parts = {}
    for i = 1, n do parts[i] = string.format("%d", copy[i]) end
    return tostring(n) .. ":" .. table.concat(parts, ",")
end

local function wallet(account, currency, create)
    local byAccount = md.wallets[account]
    if not byAccount then
        if not create then return nil end
        byAccount = {}
        md.wallets[account] = byAccount
    end
    local w = byAccount[currency]
    if not w then
        if not create then return nil end
        w = { available = 0, reserved = 0, rev = 0 }
        byAccount[currency] = w
    end
    return w
end

function L.getBalance(account, currency)
    local w = wallet(account, currency, false)
    if not w then return { available = 0, reserved = 0, rev = 0 } end
    return { available = w.available, reserved = w.reserved, rev = w.rev }
end

function L.isFrozen(account)
    return md.frozen[account] ~= nil
end

-- ---------- idempotency (bounded LRU keyed by requestId) ----------

local function idemGet(key)
    return md.idempotency.map[key]
end

local function idemPut(key, value)
    local idem = md.idempotency
    if idem.map[key] then
        idem.map[key] = value
        return
    end
    if idem.count >= L.IDEMPOTENCY_MAX then
        local oldest = idem.keys[idem.head]
        idem.keys[idem.head] = key
        idem.map[oldest] = nil
        idem.head = idem.head % L.IDEMPOTENCY_MAX + 1
    else
        idem.count = idem.count + 1
        idem.keys[idem.count] = key
    end
    idem.map[key] = value
end

-- Read-only view of a recorded result (nil when this requestId is not in the window). A caller
-- that rate-limits or meters itself asks first, so a resend is answered from here instead of
-- being weighed against a quota it already paid; `meta` is whatever the original caller stored
-- in tx.idemMeta, which lets it tell a genuine resend from a reused id with a different payload.
function L.priorResult(requestId)
    if type(requestId) ~= "string" then return nil end
    local prior = idemGet(requestId)
    if not prior then return nil end
    local meta
    if prior.meta then
        meta = {}
        for k, v in pairs(prior.meta) do meta[k] = v end
    end
    return { ok = prior.ok, txId = prior.txId, seq = prior.seq, error = prior.error, meta = meta }
end

-- An operation that moved no money still has to answer a resend exactly like one that did: a
-- listing whose fee percent is 0 is a legal configuration, not a reason to forget what the
-- request was. Such an operation records its result in this very ring - no zero-amount
-- transaction is invented, no second registry exists - under the same requestId a paid one
-- would have used, with the operation's own id and the same meta the paid path puts in
-- idemMeta. A resend is then answered by L.priorResult, and a reused id carrying a different
-- order is a conflict, on both paths alike.
-- Call it only after the operation is committed, and only when L.priorResult said nothing:
-- returns false when this requestId is already recorded (the caller must not overwrite it).
function L.noteOperation(requestId, operationId, meta)
    if type(requestId) ~= "string" or requestId == "" or #requestId > 128 then return false end
    if type(operationId) ~= "string" or operationId == "" then return false end
    if idemGet(requestId) then return false end
    local copy
    if meta then
        copy = {}
        for k, v in pairs(meta) do copy[k] = v end
    end
    idemPut(requestId, { ok = true, txId = operationId, seq = md.meta.seq, meta = copy })
    return true
end

-- ---------- receipts ring (per player account) ----------

local function pushReceipt(account, entry)
    if L.isSystemAccount(account) then return end
    local ring = md.receipts[account]
    if not ring then
        ring = { items = {}, head = 1 }
        md.receipts[account] = ring
    end
    if #ring.items < L.RECEIPT_RING then
        ring.items[#ring.items + 1] = entry
    else
        ring.items[ring.head] = entry
        ring.head = ring.head % L.RECEIPT_RING + 1
    end
end

-- Oldest first.
function L.receipts(account)
    local ring = md.receipts[account]
    if not ring then return {} end
    local n = #ring.items
    local start = (n < L.RECEIPT_RING) and 1 or ring.head
    local out = {}
    for i = 0, n - 1 do
        out[#out + 1] = ring.items[(start - 1 + i) % n + 1]
    end
    return out
end

-- ---------- validation ----------

-- Wallets whose postings in this tx are exactly the release of their own reservation: -X on
-- the reserved bucket and +X on the available one, nothing else. That is a bucket move, not new
-- money - the wallet total does not change - so the two fuses that exist to stop money being
-- created (a disabled currency, the balance cap) do not apply to its available leg. Everything
-- else, including "the reservation is not there", still does (spec contract 11).
local function releaseWallets(tx)
    local moves = {}
    for _, p in ipairs(tx.postings) do
        if type(p) == "table" and type(p.account) == "string" and type(p.currency) == "string"
            and type(p.amount) == "number" then
            local key = p.account .. "\1" .. p.currency
            local m = moves[key]
            if not m then
                m = { available = 0, reserved = 0, n = 0 }
                moves[key] = m
            end
            if p.bucket == "reserved" then m.reserved = m.reserved + p.amount else m.available = m.available + p.amount end
            m.n = m.n + 1
        end
    end
    local out = {}
    for key, m in pairs(moves) do
        if m.n == 2 and m.reserved < 0 and m.available == -m.reserved then out[key] = true end
    end
    return out
end

-- Returns nil on success, otherwise an error code string.
local function validate(tx)
    if type(tx) ~= "table" or type(tx.postings) ~= "table" or #tx.postings == 0 then
        return "invalid_args"
    end
    if type(tx.kind) ~= "string" or tx.kind == "" then return "invalid_args" end
    if type(tx.requestId) ~= "string" or tx.requestId == "" or #tx.requestId > 128 then
        return "invalid_args"
    end
    if type(tx.reasonCode) ~= "string" or tx.reasonCode == "" then return "invalid_args" end

    local sums = {}
    local seen = {}
    local release = releaseWallets(tx)
    for _, p in ipairs(tx.postings) do
        if type(p) ~= "table" or not isValidAccount(p.account) or not isInteger(p.amount) or p.amount == 0 then
            return "invalid_args"
        end
        local cur = L.currency(p.currency)
        if not cur then return "unknown_currency" end
        -- bucket: "available" (default) or "reserved" (auction bids: money the player still owns
        -- but cannot spend; a reserve is one tx with -X available / +X reserved on the same wallet)
        local bucket = p.bucket or "available"
        if bucket ~= "available" and bucket ~= "reserved" then return "invalid_args" end
        if bucket == "reserved" and L.isSystemAccount(p.account) then return "invalid_args" end
        local key = p.account .. "\1" .. p.currency .. "\1" .. bucket
        if seen[key] then return "invalid_args" end     -- one posting per account+currency+bucket per tx
        seen[key] = true
        sums[p.currency] = (sums[p.currency] or 0) + p.amount
        if not L.isSystemAccount(p.account) then
            -- the exact release of this wallet's own reservation only moves buckets
            local moving = bucket == "available" and release[p.account .. "\1" .. p.currency] == true
            if not cur.enabled and p.amount > 0 and not moving then return "currency_disabled" end
            if L.isFrozen(p.account) and not tx.allowFrozen then return "account_frozen" end
            local w = wallet(p.account, p.currency, false)
            if bucket == "reserved" then
                local reserved = w and w.reserved or 0
                if reserved + p.amount < 0 then return "insufficient_reserved" end
            else
                local available = w and w.available or 0
                if available + p.amount < 0 then return "insufficient_funds" end
                -- the cap gates new money only: a balance already above a lowered cap must
                -- still be able to pay, and a release must still be able to come home
                if p.amount > 0 and not moving and available + p.amount > cur.balanceMax then return "balance_cap" end
            end
            if p.expectedRev ~= nil and (w and w.rev or 0) ~= p.expectedRev then return "revision_mismatch" end
        end
    end
    for _, sum in pairs(sums) do
        if sum ~= 0 then return "unbalanced" end
    end
    return nil
end

-- ---------- commit ----------

local listeners = {}
function L.onCommitted(fn)
    listeners[#listeners + 1] = fn
end

-- tx = { kind, requestId, reasonCode, reasonText?, actor?, payload?, allowFrozen?, idemMeta?,
--        postings = { { account, currency, amount, expectedRev? }, ... } }
-- idemMeta is a small flat table kept with the idempotency entry (see L.priorResult).
-- Returns { ok=true, txId, seq, duplicate=false } or { ok=false, error=code } or the first
-- result again when requestId was seen before (duplicate=true).
function L.post(tx)
    if type(tx) == "table" and type(tx.requestId) == "string" then
        local prior = idemGet(tx.requestId)
        if prior then
            return { ok = prior.ok, txId = prior.txId, seq = prior.seq, error = prior.error, duplicate = true }
        end
    end
    local err = validate(tx)
    if err then
        return { ok = false, error = err }
    end

    local txId = S.newId()
    local seq = md.meta.seq
    local ts = EC.now()
    local committed = {}
    for _, p in ipairs(tx.postings) do
        local w = wallet(p.account, p.currency, true)
        local reserved = p.bucket == "reserved"
        local availableBefore, reservedBefore = w.available, w.reserved
        if reserved then w.reserved = reservedBefore + p.amount else w.available = availableBefore + p.amount end
        w.rev = w.rev + 1
        local entry = {
            txId = txId, seq = seq, ts = ts, kind = tx.kind, reasonCode = tx.reasonCode,
            account = p.account, currency = p.currency, amount = p.amount, bucket = reserved and "reserved" or nil,
            availableBefore = availableBefore, availableAfter = w.available,
            reservedBefore = reservedBefore, reservedAfter = w.reserved,
        }
        committed[#committed + 1] = entry
        -- the receipt (statement) tells the story of the spendable balance: a reserve shows as the
        -- available line ("bid held -X"), the mirror line on the reserved bucket is only in the event
        if not reserved then pushReceipt(p.account, {
            txId = txId, seq = seq, ts = ts, kind = tx.kind, currency = p.currency, amount = p.amount,
            before = availableBefore, after = w.available, reservedAfter = w.reserved, counterparty = L.counterparty(tx.postings, p),
            sourceMod = tx.payload and tx.payload.sourceMod or nil, reasonText = tx.reasonText,
            item = tx.payload and tx.payload.item or nil, qty = tx.payload and tx.payload.qty or nil,
        }) end
    end

    local result = { ok = true, txId = txId, seq = seq, duplicate = false }
    local meta
    if tx.idemMeta then
        meta = {}
        for k, v in pairs(tx.idemMeta) do meta[k] = v end
    end
    idemPut(tx.requestId, { ok = true, txId = txId, seq = seq, meta = meta })

    local event = {
        txId = txId, seq = seq, ts = ts, epoch = md.meta.epoch,
        kind = tx.kind, reasonCode = tx.reasonCode, reasonText = tx.reasonText,
        actor = tx.actor, requestId = tx.requestId, payload = tx.payload, postings = committed,
    }
    for _, fn in ipairs(listeners) do
        local ok, e = pcall(fn, event)
        if not ok then EC.log("ledger listener failed: " .. tostring(e)) end
    end
    return result
end

-- The "other side" shown on a receipt: the first posting of the same currency on a different account.
function L.counterparty(postings, mine)
    for _, p in ipairs(postings) do
        if p ~= mine and p.currency == mine.currency then return p.account end
    end
    return nil
end

-- Sugar used by rewards / admin / integration: system account <-> player.
function L.credit(account, currency, amount, systemAccount, opts)
    opts = opts or {}
    return L.post({
        kind = opts.kind or "credit", requestId = opts.requestId, reasonCode = opts.reasonCode,
        reasonText = opts.reasonText, actor = opts.actor, payload = opts.payload, allowFrozen = opts.allowFrozen,
        idemMeta = opts.idemMeta,
        postings = {
            { account = account, currency = currency, amount = amount, expectedRev = opts.expectedRev },
            { account = systemAccount, currency = currency, amount = -amount },
        },
    })
end

function L.debit(account, currency, amount, systemAccount, opts)
    return L.credit(account, currency, -amount, systemAccount, opts)
end

-- ---------- invariants ----------

-- Sum of every account for a currency; 0 means conserved. Iterates all wallets: call from a
-- throttled background scan, never per command.
function L.conservation(currency)
    local total = 0
    for _, byAccount in pairs(md.wallets) do
        local w = byAccount[currency]
        if w then total = total + w.available + w.reserved end
    end
    return total
end

-- Counts-based size estimate (Kahlua cannot measure serialized bytes; constants from A4).
function L.sizeEstimate()
    local wallets, receipts = 0, 0
    for _, byAccount in pairs(md.wallets) do
        for _ in pairs(byAccount) do wallets = wallets + 1 end
    end
    for _, ring in pairs(md.receipts) do receipts = receipts + #ring.items end
    return wallets * 125 + receipts * 168 + md.idempotency.count * 39
end

S.Ledger = L
S.onInit(L.init)
return L
