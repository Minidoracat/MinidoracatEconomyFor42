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
            if not cur.enabled and p.amount > 0 then return "currency_disabled" end
            if L.isFrozen(p.account) and not tx.allowFrozen then return "account_frozen" end
            local w = wallet(p.account, p.currency, false)
            if bucket == "reserved" then
                local reserved = w and w.reserved or 0
                if reserved + p.amount < 0 then return "insufficient_reserved" end
            else
                local available = w and w.available or 0
                if available + p.amount < 0 then return "insufficient_funds" end
                if available + p.amount > cur.balanceMax then return "balance_cap" end
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
