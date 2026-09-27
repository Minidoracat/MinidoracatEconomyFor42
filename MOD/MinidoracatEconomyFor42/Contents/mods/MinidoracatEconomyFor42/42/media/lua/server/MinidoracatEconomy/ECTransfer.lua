-- MinidoracatEconomyFor42 - player-to-player transfer (server authority).
-- Design: docs/design-proposals/player-transfer.md (sections 2-3 are the rules enforced here).
--
--   transfer.info{requestId}                      what this player may send right now
--   transfer.recipients{query, requestId}         candidate recipients (at most 20)
--   wallet.transfer{to, currency, amount, fee, memo?, requestId}
--   wallet.transferReceived (push)                to an online recipient after the commit
--
-- One L.post of kind "transfer" per transfer: payer -(amount+fee), payee +amount, SYSTEM_BURN
-- +fee (no fee posting when the fee is 0). No item moves, so a world rollback takes both sides
-- back to the same save together. Every check runs before the post and a refusal changes
-- nothing: no wallet row, no day bucket, no recent-counterparty entry.
--
-- Account age (TransferMinAccountDays): md.firstSeen[username] is the ms this server first saw
-- the account in `hello`. The boot that creates the table grandfathers every account the economy
-- already knew (wallet, reward claim record, freeze mark - ECStats' population) with 0, so an
-- upgrade never locks existing players out.
--
-- The integration half (src.transfer / E.transfer) lives in ECIntegration and calls Tr.execute;
-- this file raises the facade to rev 3 once it has loaded.

if not MinidoracatEconomy or not MinidoracatEconomy.Entitlements then
    require "MinidoracatEconomy/ECEntitlements"
end
local EC = MinidoracatEconomy
local S = EC and EC.Server
local L = EC and EC.Ledger
local R = EC and EC.Rewards
local T = EC and EC.Terminal
local A = EC and EC.Admin
local Cfg = EC and EC.Config
local G = EC and EC.Integration
if not S or not S.AUTHORITY or not L or not R or not T or not A or not Cfg or not G then
    return
end

EC.Transfer = EC.Transfer or {}
local Tr = EC.Transfer

Tr.MEMO_MAX = 64                -- characters (A.charCount), same bound as the API's reasonText
Tr.NAME_MAX = 64                -- ledger account length
Tr.REQUEST_ID_MAX = 96
Tr.QUERY_MAX = 64
Tr.RECIPIENTS_MAX = 20
Tr.RECENT_MAX = 10
Tr.DAILY_KEEP_DAYS = 31
Tr.DAY_MS = 86400000
Tr.REASON_CODE = "player_transfer"
Tr.BURN_ACCOUNT = "SYSTEM_BURN"

local md = nil

-- ---------- settings ----------

local function int(key, default)
    return math.floor(tonumber(EC.sandbox(key, default)) or default)
end

function Tr.settings()
    return {
        enabled = EC.sandbox("TransferEnabled", false) == true,
        remote = EC.sandbox("TransferRemote", false) == true,
        feePercent = int("TransferFeePercent", 5),
        min = int("TransferMin", 1),
        maxPerTx = int("TransferMaxPerTx", 5000),
        daily = int("TransferDailyPerAccount", 10000),     -- 0 = unlimited
        minDays = int("TransferMinAccountDays", 3),        -- 0 = no threshold
    }
end

-- ceil(amount * pct / 100), at least 1 while a fee is on. Integers only, no float rounding.
function Tr.fee(amount, pct)
    if pct <= 0 then return 0 end
    return math.max(1, math.floor((amount * pct + 99) / 100))
end

function Tr.transferable(id)
    local cur = Cfg.currency(id)
    return cur ~= nil and cur.enabled and cur.directTransfer == true
end

function Tr.currencies()
    local out = {}
    for _, id in ipairs(EC.CURRENCY_ORDER) do
        if Tr.transferable(id) then out[#out + 1] = id end
    end
    return out
end

-- ---------- accounts ----------

local function validName(v)
    return type(v) == "string" and v ~= "" and #v <= Tr.NAME_MAX and not string.find(v, "%c")
end

-- Known to the economy (the ECStats population plus the accounts seen in hello). Exact match:
-- case and blanks count. System accounts are never a recipient.
function Tr.known(username)
    if not validName(username) or L.isSystemAccount(username) then return false end
    return md.wallets[username] ~= nil or md.claims[username] ~= nil or md.frozen[username] ~= nil
        or md.firstSeen[username] ~= nil or S.onlinePlayer(username) ~= nil
end

-- When `username` may start sending, or nil when it already may. An account the server has not
-- seen in hello yet has not started its clock: skipping hello never skips the wait.
function Tr.readyAt(username, s, now)
    if s.minDays <= 0 then return nil end
    local first = md.firstSeen[username]
    local at = (type(first) == "number" and first or now) + s.minDays * Tr.DAY_MS
    if at <= now then return nil end
    return at
end

function Tr.noteSeen(username)
    if md and validName(username) and not L.isSystemAccount(username) and type(md.firstSeen[username]) ~= "number" then
        md.firstSeen[username] = EC.now()
    end
end

-- ---------- per-day principal sent ----------

function Tr.sentOn(day, username)
    local byDay = md.transferDaily[day]
    return byDay and byDay[username] or 0
end

local function addSent(day, username, amount)
    local byDay = md.transferDaily[day]
    if not byDay then
        byDay = {}
        md.transferDaily[day] = byDay
        local oldest = R.dayKey(EC.now() - Tr.DAILY_KEEP_DAYS * Tr.DAY_MS)
        local stale = {}
        for k in pairs(md.transferDaily) do if k < oldest then stale[#stale + 1] = k end end
        for _, k in ipairs(stale) do md.transferDaily[k] = nil end
    end
    byDay[username] = (byDay[username] or 0) + amount
end

-- Newest first, at most RECENT_MAX, no duplicates.
local function noteRecent(username, other)
    local list = { other }
    for _, name in ipairs(md.transferRecent[username] or {}) do
        if name ~= other and #list < Tr.RECENT_MAX then list[#list + 1] = name end
    end
    md.transferRecent[username] = list
end

-- ---------- the transfer ----------

local function fail(code, extra)
    local out = extra or {}
    out.ok, out.error = false, code
    return out
end

local function isAmount(v)
    return type(v) == "number" and v == math.floor(v) and v >= 1 and v <= L.MAX_ABS_AMOUNT
end

-- req = { from, to, currency, amount, key, reasonCode, reasonText?, actor?, payload?,
--         fee? (what the player confirmed; nil for the API), memo?, player? (terminal check) }
-- Check order is design section 3.1. -> { ok, txId, fee, total, sentToday, duplicate? } or
-- { ok=false, error, <detail> }.
function Tr.execute(req)
    if not md then return fail("not_ready") end
    local from, to, currency, amount = req.from, req.to, req.currency, req.amount
    if not validName(from) or L.isSystemAccount(from) or not validName(to) or not EC.CURRENCIES[currency]
        or not isAmount(amount) then
        return fail("invalid_args")
    end
    if not L.validRequestKey(req.key) then return fail("request_too_long") end
    local order = { kind = "transfer", from = from, to = to, currency = currency, amount = amount,
        quoted = req.fee or -1, memo = req.memo or "" }
    local prior = L.priorResult(req.key)
    if prior then
        local meta = prior.meta or {}
        for k, v in pairs(order) do
            if meta[k] ~= v then return fail("request_conflict") end
        end
        return { ok = prior.ok, txId = prior.txId, fee = meta.fee, total = meta.total, duplicate = true }
    end

    local s = Tr.settings()
    if not s.enabled then return fail("transfer_disabled") end
    if not Tr.transferable(currency) then return fail("currency_not_transferable") end
    if from == to then return fail("self_transfer") end
    if not Tr.known(to) then return fail("unknown_recipient") end
    if L.isFrozen(from) then return fail("account_frozen") end
    if L.isFrozen(to) then return fail("recipient_frozen") end
    if req.player ~= nil and not s.remote and not T.near(req.player) then return fail("not_at_terminal") end
    local now = EC.now()
    local ready = Tr.readyAt(from, s, now)
    if ready then return fail("account_too_new", { availableAt = ready }) end
    if amount < s.min or amount > s.maxPerTx then return fail("amount_range", { min = s.min, max = s.maxPerTx }) end
    local fee = Tr.fee(amount, s.feePercent)
    if req.fee ~= nil and req.fee ~= fee then return fail("fee_changed", { feeNow = fee }) end
    local day = R.dayKey(now)
    local sent = Tr.sentOn(day, from)
    if s.daily > 0 and sent + amount > s.daily then
        return fail("daily_limit", { remainingToday = math.max(0, s.daily - sent) })
    end
    -- never the recipient's balance: only that this amount does not fit
    if L.getBalance(to, currency).available + amount > L.currency(currency).balanceMax then return fail("recipient_cap") end
    local total = amount + fee
    local have = L.getBalance(from, currency).available
    if have < total then return fail("insufficient_funds", { needed = total - have }) end

    local postings = {
        { account = from, currency = currency, amount = -total },
        { account = to, currency = currency, amount = amount },
    }
    if fee > 0 then postings[3] = { account = Tr.BURN_ACCOUNT, currency = currency, amount = fee } end
    local payload = req.payload or {}
    payload.from, payload.to, payload.memo = from, to, req.memo
    local meta = { fee = fee, total = total }
    for k, v in pairs(order) do meta[k] = v end
    local res = L.post({
        kind = "transfer", requestId = req.key, reasonCode = req.reasonCode, reasonText = req.reasonText,
        actor = req.actor or from, idemMeta = meta, payload = payload, postings = postings,
    })
    if not res.ok then return fail(res.error) end
    addSent(day, from, amount)
    noteRecent(from, to)
    noteRecent(to, from)
    local target = S.onlinePlayer(to)
    if target ~= nil then
        S.reply(target, "wallet.transferReceived", { from = from, currency = currency, amount = amount,
            memo = req.memo, txId = res.txId, balance = L.getBalance(to, currency).available })
    end
    return { ok = true, txId = res.txId, fee = fee, total = total, sentToday = sent + amount }
end

-- ---------- commands ----------

local function requestId(v)
    if type(v) == "string" and v ~= "" and #v <= Tr.REQUEST_ID_MAX and not string.find(v, "%c") then return v end
    return nil
end

local function remaining(s, sent)
    if s.daily <= 0 then return nil end
    return math.max(0, s.daily - sent)
end

S.handlers["transfer.info"] = function(player, args)
    local username = player:getUsername()
    local s, now = Tr.settings(), EC.now()
    local sent = Tr.sentOn(R.dayKey(now), username)
    S.reply(player, "transfer.info", {
        requestId = requestId(args.requestId), ok = true, enabled = s.enabled, remote = s.remote,
        atTerminal = T.near(player), feePercent = s.feePercent, min = s.min, maxPerTx = s.maxPerTx,
        dailyLimit = s.daily, sentToday = sent, remainingToday = remaining(s, sent),
        readyAt = Tr.readyAt(username, s, now), currencies = Tr.currencies(),
    })
end

-- Online players whose name contains the query (case-insensitive), the caller's last 10
-- counterparties, and an exact case-sensitive match of any known account; never the caller.
S.handlers["transfer.recipients"] = function(player, args)
    local me = player:getUsername()
    local query = args.query
    if type(query) ~= "string" or #query > Tr.QUERY_MAX or string.find(query, "%c") then query = nil end
    local out = { requestId = requestId(args.requestId), query = query or "", items = {} }
    if query ~= nil and Tr.settings().enabled then
        local needle = string.lower(query)
        local online = {}
        S.forEachOnline(function(p)
            local u = p:getUsername()
            if validName(u) then online[u] = true end
        end)
        local seen = { [me] = true }
        local function add(u)
            if #out.items >= Tr.RECIPIENTS_MAX or seen[u] or L.isSystemAccount(u) then return end
            seen[u] = true
            out.items[#out.items + 1] = { username = u, online = online[u] == true }
        end
        local function matches(u)
            return needle == "" or string.find(string.lower(u), needle, 1, true) ~= nil
        end
        if query ~= "" and Tr.known(query) then add(query) end
        for _, u in ipairs(md.transferRecent[me] or {}) do
            if matches(u) then add(u) end
        end
        local names = {}
        for u in pairs(online) do
            if matches(u) then names[#names + 1] = u end
        end
        -- ponytail: insertion sort over the online players only (tens, not the whole ledger)
        EC.sortSafe(names, function(a, b)
            local al, bl = string.lower(a), string.lower(b)
            if al ~= bl then return al < bl end
            return a < b
        end)
        for _, u in ipairs(names) do add(u) end
    end
    S.reply(player, "transfer.recipients", out)
end

S.handlers["wallet.transfer"] = function(player, args)
    local username = player:getUsername()
    local id = requestId(args.requestId)
    local memo = args.memo
    if memo == "" then memo = nil end
    local res
    if id == nil or not validName(args.to) or type(args.currency) ~= "string" or not isAmount(args.amount)
        or type(args.fee) ~= "number" or args.fee ~= math.floor(args.fee) or args.fee < 0
        or (memo ~= nil and (type(memo) ~= "string" or A.charCount(memo) > Tr.MEMO_MAX or string.find(memo, "%c"))) then
        res = fail("invalid_args")
    else
        res = Tr.execute({ from = username, to = args.to, currency = args.currency, amount = args.amount,
            fee = args.fee, memo = memo, key = "transfer:" .. username .. ":" .. id, player = player,
            reasonCode = Tr.REASON_CODE, reasonText = memo })
    end
    res.requestId = id
    res.to = validName(args.to) and args.to or nil
    res.currency = type(args.currency) == "string" and EC.CURRENCIES[args.currency] and args.currency or nil
    res.amount = type(args.amount) == "number" and args.amount or nil
    res.fee = res.fee or (type(args.fee) == "number" and args.fee or nil)
    if res.ok then
        local s = Tr.settings()
        local sent = Tr.sentOn(R.dayKey(EC.now()), username)
        res.balance = L.getBalance(username, args.currency).available
        res.sentToday, res.remainingToday = sent, remaining(s, sent)
    end
    S.reply(player, "wallet.transfer", res)
end

-- The first sighting of an account starts its clock (the client's first command is hello).
local prevHello = S.handlers.hello
S.handlers.hello = function(player, args)
    Tr.noteSeen(player:getUsername())
    prevHello(player, args)
end

-- ---------- lifecycle ----------

function Tr.init(root)
    md = root
    md.transferDaily = md.transferDaily or {}
    md.transferRecent = md.transferRecent or {}
    if type(md.firstSeen) ~= "table" then
        -- First boot of the build that tracks account age: everyone the economy already knows is
        -- old enough. A world rolled back to a save from before this boot runs this again over
        -- that save's population, which is the same set or a smaller one - never a larger one.
        local seen, n = {}, 0
        local function grandfather(u)
            if validName(u) and not L.isSystemAccount(u) and seen[u] == nil then
                seen[u] = 0
                n = n + 1
            end
        end
        for u in pairs(md.wallets) do grandfather(u) end
        for u in pairs(md.claims) do grandfather(u) end
        for u in pairs(md.frozen) do grandfather(u) end
        md.firstSeen = seen
        EC.log("transfer: account age tracking starts; " .. n .. " existing accounts grandfathered")
    end
end

S.Transfer = Tr
S.onInit(Tr.init)

-- The facade grows to rev 3 only now that the transfer half is loaded (ECEntitlements, required
-- above, has already made it rev 2).
G.API_REVISION = 3
if EC.v1 then
    EC.v1.API_REVISION = 3
    EC.v1.CAPABILITIES.transfer = true
    EC.v1.transfer = G.transfer
end

return Tr
