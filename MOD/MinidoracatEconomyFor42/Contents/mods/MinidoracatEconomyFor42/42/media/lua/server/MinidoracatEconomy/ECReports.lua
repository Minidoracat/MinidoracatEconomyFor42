-- MinidoracatEconomyFor42 - economy reports (server authority).
--
--   admin.report {requestId, currency, days | season | fromMs+toMs}            read   summary
--   admin.report {requestId, action = "market", currency, days = 7|30, refresh} read   top items
--   market.priceRef {requestId, item}                                           public price reference
--
-- Three stages of data, nothing here invents a second ledger:
--   1. what the server already keeps: the 60-day rollups (issuance), the census (now, wealth),
--      md.shopDaily / md.shopBuyback (shares bought, buyback use), 31 days each;
--   2. the per-kind / per-SKU breakdown and the day's opening supply that ECStats writes on the
--      same rollup rows (St.flows decides every in / out / turnover in the whole server);
--   3. a market scan of the daily events files (W.tail, an internal job with no player): trades
--      (market_buy, auction_sale) and transfers of the last 30 reward days, rolled-back lines
--      excluded. Its result lives in memory only - it is a statistic, the files are the record.
--
-- The scan runs about three minutes after the start and every six hours after that, on
-- OnTickEvenPaused (an empty PauseEmpty server keeps that tick; the file job reads a bounded
-- number of lines and bytes per tick), or when an administrator asks for a fresh one. A player
-- never starts it: market.priceRef only reads what the last scan left.
--
-- Every reply has a row bound; every argument is checked here; a refusal is a code, never prose.

if not MinidoracatEconomy or not MinidoracatEconomy.Admin then
    require "MinidoracatEconomy/ECAdmin"
end
local EC = MinidoracatEconomy
local S = EC and EC.Server
local R = EC and EC.Rewards
local W = EC and EC.Wallet
local St = EC and EC.Stats
local A = EC and EC.Admin
local Shop = EC and EC.Shop
local Se = EC and EC.Seasons
local L = EC and EC.Ledger
if not S or not S.AUTHORITY or not R or not W or not St or not A or not A.gate or not Shop or not Se or not L then
    return
end

EC.Reports = EC.Reports or {}
local Rp = EC.Reports

Rp.RANGE_DAYS_MAX = 60            -- the rollups' retention: a summary never reaches past it
Rp.SCAN_DAYS = 30
Rp.SPARK_DAYS = 14
Rp.SAMPLES_MAX = 400              -- newest unit prices kept per item and currency
Rp.ITEMS_MAX = 500                -- distinct items followed per currency; later ones are dropped
Rp.TOP_ITEMS = 20
Rp.SHOP_ROWS = 20
Rp.SOURCES_MAX = 40
Rp.FIRST_SCAN_MS = 180000
Rp.SCAN_EVERY_MS = 6 * 3600000
Rp.RETRY_MS = 10000               -- the file readers were all busy: try again shortly
Rp.REFRESH_MIN_MS = 60000
Rp.BYTES_PER_TICK = 65536
Rp.TICK_MS = 1000
Rp.ITEM_CHARS = 128
Rp.MARKET_DAYS = { [7] = true, [30] = true }

local DAY_MS = 86400000
local SCAN_KINDS = { market_buy = true, auction_sale = true, transfer = true }
local OWNER = "SYSTEM:reports"
local COMMAND = "report.market"

local md = nil
local scan = nil                  -- the scan in flight (accumulators), nil when none
local result = nil                -- the last finished scan
local state = "none"              -- none | running | ready | failed
local nextAt = 0
local lastTick = 0

local function isInt(v)
    return type(v) == "number" and v == v and v > -math.huge and v < math.huge and v == math.floor(v)
end

local function num(v)
    return tonumber(v) or 0
end

local function round2(v)
    return math.floor(v * 100 + 0.5) / 100
end

-- ---------- summary: the period ----------

-- Reward-day keys of the requested period, oldest first, `capped` (a season longer than the
-- retention starts at the oldest kept day) and the first day's start instant. nil, nil, code
-- when the request is not one.
local function periodKeys(args, ms)
    local todayStart = R.dayStartMs(ms)
    local oldestStart = todayStart - (Rp.RANGE_DAYS_MAX - 1) * DAY_MS
    local fromStart, toStart, capped = nil, todayStart, false
    if args.season ~= nil then
        if args.season ~= true then return nil, nil, "invalid_args" end
        local st = Se.state()
        local startedAt = nil
        for _, s in ipairs(st and st.seasons or {}) do
            if s.id == st.currentId then startedAt = s.startedAt end
        end
        if not isInt(startedAt) then return nil, nil, "read_failed" end
        fromStart = R.dayStartMs(math.min(startedAt, ms))
        if fromStart < oldestStart then fromStart, capped = oldestStart, true end
    elseif args.fromMs ~= nil or args.toMs ~= nil then
        local from, to = args.fromMs, args.toMs
        if not isInt(from) or not isInt(to) or from < 0 or to > 9007199254740991 then return nil, nil, "invalid_args" end
        if to <= from then return nil, nil, "invalid_range" end
        fromStart, toStart = R.dayStartMs(from), R.dayStartMs(to - 1)
        if fromStart < oldestStart or toStart > todayStart then return nil, nil, "invalid_range" end
    else
        local days = args.days
        if not isInt(days) then return nil, nil, "invalid_args" end
        if days < 1 or days > Rp.RANGE_DAYS_MAX then return nil, nil, "invalid_range" end
        fromStart = todayStart - (days - 1) * DAY_MS
    end
    local keys = {}
    for t = fromStart, toStart, DAY_MS do keys[#keys + 1] = R.dayKey(t) end
    return keys, capped, nil, fromStart
end

-- The first reward day the per-kind breakdown was recorded on (any currency: ECStats records it
-- for every commit since the build that added it). A later day without a row moved nothing: 0.
local function breakdownFrom()
    local first = nil
    for day, r in pairs(md.rollups or {}) do
        if type(day) == "string" and type(r) == "table" and type(r.byCurrency) == "table" then
            for _, c in pairs(r.byCurrency) do
                if type(c) == "table" and type(c.k) == "table" then
                    if first == nil or day < first then first = day end
                    break
                end
            end
        end
    end
    return first
end

-- One day of one currency as the reply carries it (copied: no ModData table leaves the server).
local function dayEntry(day, currency, firstK)
    local c, unknown = St.rollupRow(day, currency)
    local e = { mint = num(c and c.mint), burn = num(c and c.burn), checkin = num(c and c.checkinTotal),
        milestone = num(c and c.milestoneTotal), buyback = num(c and c.buyback), unknown = unknown }
    if firstK ~= nil and day >= firstK then
        local k = {}
        for kind, v in pairs(c and type(c.k) == "table" and c.k or {}) do
            if type(kind) == "string" and type(v) == "table" then
                k[kind] = { n = num(v.n), i = num(v.i), o = num(v.o), t = num(v.t) }
            end
        end
        e.k = k
    end
    local sup = c and c.sup
    if type(sup) == "table" then e.sup = { t = num(sup.t), p = num(sup.p), r = num(sup.r), h = num(sup.h) } end
    return e
end

-- Totals of a run of days: per kind (n, i, o) and the period's i / o / t / mint / burn. `known`
-- is false as soon as one day has no breakdown or an incomplete record.
local function periodTotals(days)
    local byKind, tot = {}, { i = 0, o = 0, t = 0, mint = 0, burn = 0, known = true }
    for _, e in ipairs(days) do
        tot.mint, tot.burn = tot.mint + e.mint, tot.burn + e.burn
        if e.unknown or e.k == nil then tot.known = false end
        for kind, v in pairs(e.k or {}) do
            local a = byKind[kind]
            if not a then
                a = { n = 0, i = 0, o = 0 }
                byKind[kind] = a
            end
            a.n, a.i, a.o = a.n + v.n, a.i + v.i, a.o + v.o
            tot.i, tot.o, tot.t = tot.i + v.i, tot.o + v.o, tot.t + v.t
        end
    end
    return byKind, tot
end

-- One row per kind and direction that moved money in the period, inflows first, largest first.
local function sourceRows(byKind, prevByKind)
    local rows = {}
    for kind, a in pairs(byKind) do
        local p = prevByKind and (prevByKind[kind] or { i = 0, o = 0 }) or nil
        if a.i > 0 then rows[#rows + 1] = { kind = kind, dir = "in", n = a.n, amount = a.i, prev = p and p.i or nil } end
        if a.o > 0 then rows[#rows + 1] = { kind = kind, dir = "out", n = a.n, amount = a.o, prev = p and p.o or nil } end
    end
    EC.sortSafe(rows, function(x, y)
        if x.dir ~= y.dir then return x.dir == "in" end
        if x.amount ~= y.amount then return x.amount > y.amount end
        return x.kind < y.kind
    end)
    while #rows > Rp.SOURCES_MAX do table.remove(rows) end
    return rows
end

-- ---------- summary: the shop ----------

local function skuInfo(cache, id)
    local info = cache[id]
    if info == nil then
        local sku = Shop.sku(id)
        info = sku and { item = sku.item, scope = sku.dailyCapScope, cap = sku.dailyCap } or false
        cache[id] = info
    end
    return info or nil
end

-- Shares sold per SKU (md.shopDaily: every account's shares of the day, across currencies - the
-- cap counts them that way), the days the current cap was reached (global: the server's shares;
-- player: at least one account's), and purchases / coins in `currency` from the breakdown.
local function shopRows(keys, currency)
    local rows, byId, infos = {}, {}, {}
    local function rowOf(id)
        local r = byId[id]
        if not r then
            local info = skuInfo(infos, id)
            r = { sku = id, item = info and info.item or nil, count = 0, units = 0, amount = 0, capDays = 0,
                scope = info and info.scope or nil, cap = info and info.cap or nil }
            byId[id] = r
            rows[#rows + 1] = r
        end
        return r
    end
    local daily = type(md.shopDaily) == "table" and md.shopDaily or {}
    for _, day in ipairs(keys) do
        local byDay = daily[day]
        if type(byDay) == "table" then
            local sum, most = {}, {}
            for _, row in pairs(byDay) do
                if type(row) == "table" then
                    for id, n in pairs(row) do
                        n = num(n)
                        sum[id] = (sum[id] or 0) + n
                        if n > (most[id] or 0) then most[id] = n end
                    end
                end
            end
            for id, total in pairs(sum) do
                if type(id) == "string" then
                    local r = rowOf(id)
                    r.units = r.units + total
                    local cap = r.cap or 0
                    if cap > 0 and ((r.scope == "global" and total >= cap) or (r.scope == "player" and most[id] >= cap)) then
                        r.capDays = r.capDays + 1
                    end
                end
            end
        end
        local c = St.rollupRow(day, currency)
        for id, s in pairs(c and type(c.sku) == "table" and c.sku or {}) do
            if type(id) == "string" and type(s) == "table" then
                local r = rowOf(id)
                r.count, r.amount = r.count + num(s.n), r.amount + num(s.a)
            end
        end
    end
    St.sortRows(rows, function(x, y)
        if x.units ~= y.units then return x.units > y.units end
        if x.amount ~= y.amount then return x.amount > y.amount end
        return x.sku < y.sku
    end)
    while #rows > Rp.SHOP_ROWS do table.remove(rows) end
    return rows
end

-- Average daily use of the server's buyback coin cap over the days of the period the buyback
-- buckets still cover (31 days), as a fraction 0..1; nil pct when the currency has no server cap.
local function buybackUse(keys, currency, ms)
    local status = Shop.buybackStatus(ms)
    local cap = status.byCurrency[currency] and status.byCurrency[currency].serverCap or 0
    local oldest = R.dayKey(ms - Shop.DAILY_KEEP_DAYS * DAY_MS)
    local days, used = 0, 0
    local store = type(md.shopBuyback) == "table" and md.shopBuyback or {}
    for _, day in ipairs(keys) do
        if day >= oldest then
            days = days + 1
            local t = store[day]
            if type(t) == "table" then
                if t.v == Shop.BUYBACK_DAY_VERSION and type(t.byCurrency) == "table" then
                    used = used + num(t.byCurrency[currency])
                elseif t.v == nil and currency == L.LEGACY_CURRENCY then
                    used = used + num(t.total)
                end
            end
        end
    end
    local pct = (cap > 0 and days > 0) and math.floor(used / (cap * days) * 10000 + 0.5) / 10000 or nil
    return { pct = pct, days = days }
end

function Rp.summary(args, requestId, currency)
    local ms = EC.now()
    local out = { ok = true, requestId = requestId, action = "summary", currency = currency }
    local keys, capped, err, fromStart = periodKeys(args, ms)
    if not keys then
        out.ok, out.error = false, err
        return out
    end
    local firstK = breakdownFrom()
    local days, prevDays = {}, {}
    for i, day in ipairs(keys) do days[i] = dayEntry(day, currency, firstK) end
    -- the period of the same length right before this one (older than the retention: unknown)
    local n = #keys
    for i = 1, n do prevDays[i] = dayEntry(R.dayKey(fromStart - (n - i + 1) * DAY_MS), currency, firstK) end
    local byKind, tot = periodTotals(days)
    local prevByKind, prev = periodTotals(prevDays)
    local wealth, supply = St.wealth(currency, ms)
    out.capped = capped
    out.keys, out.days = keys, days
    out.prev = { i = prev.i, o = prev.o, t = prev.t, mint = prev.mint, burn = prev.burn, known = prev.known }
    out.sources = sourceRows(byKind, prev.known and prevByKind or nil)
    for i, day in ipairs(keys) do
        if days[i].k ~= nil then out.kindsFrom = day; break end
    end
    supply = supply or {}
    out.now = { total = supply.total, players = supply.players, reserved = supply.reserved,
        holders = supply.holders, accounts = supply.accounts }
    out.wealth = wealth
    out.shop = { rows = shopRows(keys, currency), buyback = buybackUse(keys, currency, ms) }
    out.totals = { i = tot.i, o = tot.o, t = tot.t, mint = tot.mint, burn = tot.burn, known = tot.known }
    return out
end

-- ---------- the market scan ----------

local function currencyAcc(sc, currency)
    local a = sc.byCurrency[currency]
    if not a then
        a = { items = {}, itemCount = 0, itemsCapped = false, traders = {}, turnover = {} }
        for d = 1, Rp.SCAN_DAYS do
            a.traders[d] = {}
            a.turnover[d] = 0
        end
        sc.byCurrency[currency] = a
    end
    return a
end

local function itemAcc(a, item)
    local it = a.items[item]
    if it then return it end
    if a.itemCount >= Rp.ITEMS_MAX then
        a.itemsCapped = true
        return nil
    end
    it = { days = {}, samples = {}, head = 1 }
    a.items[item] = it
    a.itemCount = a.itemCount + 1
    return it
end

-- One trade of one item: the day's counters and the bounded ring of the newest unit prices.
local function noteTrade(it, d, price, qty, auction)
    local day = it.days[d]
    if not day then
        day = { n = 0, units = 0, amount = 0, auction = 0, sum = 0 }
        it.days[d] = day
    end
    local unit = price / qty
    day.n, day.units, day.amount, day.sum = day.n + 1, day.units + qty, day.amount + price, day.sum + unit
    if auction then day.auction = day.auction + 1 end
    if day.lo == nil or unit < day.lo then day.lo = unit end
    if day.hi == nil or unit > day.hi then day.hi = unit end
    local sample = { d = d, p = unit }
    if #it.samples < Rp.SAMPLES_MAX then
        it.samples[#it.samples + 1] = sample
    else
        it.samples[it.head] = sample
        it.head = it.head % Rp.SAMPLES_MAX + 1
    end
end

-- The tail projector: accumulates and keeps nothing in the job's ring.
local function project(sc, rec)
    if rec.type ~= "tx.committed" or not SCAN_KINDS[rec.kind] or rec.rolledBack == true then return nil end
    local ts = rec.ts
    if not isInt(ts) or ts < sc.from or ts >= sc.to then return nil end
    local d = math.floor((ts - sc.from) / DAY_MS) + 1
    local payload = type(rec.payload) == "table" and rec.payload or {}
    local postings = type(rec.postings) == "table" and rec.postings or {}
    local trade = St.TRADE_KINDS[rec.kind] == true
    local item = type(payload.item) == "string" and payload.item ~= "" and #payload.item <= Rp.ITEM_CHARS and payload.item or nil
    local qty = (isInt(payload.qty) and payload.qty >= 1) and payload.qty or 1
    for currency, f in pairs(St.flows(rec)) do
        if EC.CURRENCIES[currency] then
            local a = currencyAcc(sc, currency)
            a.turnover[d] = a.turnover[d] + f.t
            for _, p in ipairs(postings) do
                if type(p) == "table" and p.currency == currency and EC.accountClass(p.account) == "player" then
                    a.traders[d][p.account] = true
                end
            end
            if trade and item and f.t > 0 then
                local it = itemAcc(a, item)
                if it then noteTrade(it, d, f.t, qty, rec.kind == "auction_sale") end
            end
        end
    end
    return nil
end

-- Traders (distinct player accounts) and turnover of the last `days` days, per day.
local function windowView(a, days)
    local first = Rp.SCAN_DAYS - days + 1
    local seen, total, traders, turnover = {}, 0, {}, {}
    for d = first, Rp.SCAN_DAYS do
        local n = 0
        for name in pairs(a and a.traders[d] or {}) do
            n = n + 1
            if not seen[name] then
                seen[name] = true
                total = total + 1
            end
        end
        traders[#traders + 1] = n
        turnover[#turnover + 1] = a and a.turnover[d] or 0
    end
    return { traders = { total = total, daily = traders }, turnover = { daily = turnover } }
end

local function finish(sc, reply)
    if scan ~= sc then return end            -- a restart dropped this scan
    scan = nil
    local ms = EC.now()
    local err = reply and reply.error or nil
    if err == "busy" or err == "server_busy" then
        state = result and "ready" or "none"
        nextAt = ms + Rp.RETRY_MS
        return
    end
    nextAt = ms + Rp.SCAN_EVERY_MS
    if err ~= nil then
        EC.log("market report scan failed: " .. tostring(err))
        state = "failed"
        return
    end
    local out = { generatedAt = ms, byCurrency = {}, refs = {} }
    for currency, a in pairs(sc.byCurrency) do
        out.byCurrency[currency] = { acc = a, views = { [7] = windowView(a, 7), [30] = windowView(a, 30) } }
    end
    -- traders were only needed for the counts above; the names do not outlive the scan
    for _, a in pairs(sc.byCurrency) do a.traders = nil end
    result = out
    state = "ready"
end

-- Starts a scan unless one is running. The job's refusals come back through the same callback.
local function startScan(ms)
    if scan ~= nil then return false end
    local sc = { from = R.dayStartMs(ms) - (Rp.SCAN_DAYS - 1) * DAY_MS, to = ms + 1, byCurrency = {} }
    scan = sc
    state = "running"
    W.tail(nil, COMMAND, W.eventPaths(ms, sc.from, sc.to), {}, function(rec) return project(sc, rec) end, true,
        { owner = OWNER, bytesPerTick = Rp.BYTES_PER_TICK, onComplete = function(reply) finish(sc, reply) end })
    return true
end

-- Median of a list of numbers (sorted in place).
local function median(list)
    local n = #list
    if n == 0 then return nil end
    St.sortRows(list, function(x, y) return x < y end)
    local mid = math.floor((n + 1) / 2)
    if n % 2 == 1 then return list[mid] end
    return (list[mid] + list[mid + 1]) / 2
end

-- One item over the days first .. SCAN_DAYS: trades, units, coins, auctions and unit-price range.
local function itemWindow(item, it, first)
    local row = { item = item, n = 0, units = 0, amount = 0, auction = 0 }
    local lo, hi = nil, nil
    for d = first, Rp.SCAN_DAYS do
        local day = it.days[d]
        if day then
            row.n, row.units, row.amount, row.auction = row.n + day.n, row.units + day.units,
                row.amount + day.amount, row.auction + day.auction
            if lo == nil or day.lo < lo then lo = day.lo end
            if hi == nil or day.hi > hi then hi = day.hi end
        end
    end
    if row.n == 0 then return nil end
    row.lo, row.hi = round2(lo), round2(hi)
    return row
end

-- The median of the item's newest samples inside the window, onto the row. Only rows that are
-- answered get one: sorting every followed item's samples would stall the tick for nothing.
local function withMedian(row, it, first)
    local prices = {}
    for _, s in ipairs(it.samples) do
        if s.d >= first then prices[#prices + 1] = s.p end
    end
    local m = median(prices)
    row.median = m and round2(m) or nil
    return row
end

-- The top items of one currency and window, by coins traded; built once per scan and window.
local function topItems(entry, days)
    local view = entry.views[days]
    if view.items then return view.items end
    local first = Rp.SCAN_DAYS - days + 1
    local top = {}
    for item, it in pairs(entry.acc.items) do
        local row = itemWindow(item, it, first)
        if row then
            local pos = #top + 1
            while pos > 1 and (row.amount > top[pos - 1].amount
                or (row.amount == top[pos - 1].amount and row.item < top[pos - 1].item)) do
                pos = pos - 1
            end
            if pos <= Rp.TOP_ITEMS then
                table.insert(top, pos, row)
                if #top > Rp.TOP_ITEMS then table.remove(top) end
            end
        end
    end
    for _, row in ipairs(top) do
        local spark = {}
        local it = entry.acc.items[row.item]
        withMedian(row, it, first)
        for d = Rp.SCAN_DAYS - Rp.SPARK_DAYS + 1, Rp.SCAN_DAYS do
            local day = it.days[d]
            spark[#spark + 1] = day and round2(day.sum / day.n) or false
        end
        row.spark = spark
    end
    view.items = top
    return top
end

function Rp.market(args, requestId, currency)
    local ms = EC.now()
    local out = { ok = true, requestId = requestId, action = "market", currency = currency }
    local days = args.days
    if not isInt(days) then out.ok, out.error = false, "invalid_args"; return out end
    if not Rp.MARKET_DAYS[days] then out.ok, out.error = false, "invalid_range"; return out end
    if args.refresh ~= nil and type(args.refresh) ~= "boolean" then out.ok, out.error = false, "invalid_args"; return out end
    out.days = days
    if args.refresh == true and scan == nil and (result == nil or ms - result.generatedAt > Rp.REFRESH_MIN_MS) then
        startScan(ms)
    end
    out.state = state
    out.generatedAt = result and result.generatedAt or nil
    local entry = result and result.byCurrency[currency] or nil
    if entry then
        local view = entry.views[days]
        out.items = topItems(entry, days)
        out.traders, out.turnover = view.traders, view.turnover
        out.itemsCapped = entry.acc.itemsCapped
    else
        out.items = {}
        local empty = result and windowView(nil, days) or { traders = { total = 0, daily = {} }, turnover = { daily = {} } }
        out.traders, out.turnover = empty.traders, empty.turnover
    end
    return out
end

-- The 30-day reference of one item in every currency it traded in; read from the last scan only.
function Rp.priceRef(item, requestId)
    local out = { ok = true, requestId = requestId, item = item, state = state, days = Rp.SCAN_DAYS,
        generatedAt = result and result.generatedAt or nil, byCurrency = {} }
    if not result then return out end
    local cached = result.refs[item]
    if cached == nil then
        cached = {}
        local found = false
        for currency, entry in pairs(result.byCurrency) do
            local it = entry.acc.items[item]
            local row = it and itemWindow(item, it, 1) or nil
            if row then withMedian(row, it, 1) end
            if row then
                cached[currency] = { n = row.n, units = row.units, median = row.median, lo = row.lo, hi = row.hi }
                found = true
            end
        end
        -- only items the scan saw are kept: any other string a client sends is answered, not stored
        if found then result.refs[item] = cached end
    end
    out.byCurrency = cached
    return out
end

-- ---------- commands ----------

S.handlers["admin.report"] = function(player, args)
    args = type(args) == "table" and args or {}
    local requestId, idOk = St.requestId(args.requestId)
    if not A.gate(player, "admin.report", false, requestId) then return end
    local action = args.action == nil and "summary" or args.action
    local currency = type(args.currency) == "string" and EC.CURRENCIES[args.currency] and args.currency or nil
    local function fail(code)
        S.reply(player, "admin.report", { ok = false, requestId = requestId, error = code,
            action = (action == "summary" or action == "market") and action or nil, currency = currency })
    end
    if not idOk or (action ~= "summary" and action ~= "market") or currency == nil then return fail("invalid_args") end
    if action == "market" then
        S.reply(player, "admin.report", Rp.market(args, requestId, currency))
    else
        S.reply(player, "admin.report", Rp.summary(args, requestId, currency))
    end
end

-- Public: any verified player (the dispatcher's identity gate and per-command throttle), no
-- terminal needed - it reads a statistic, it moves nothing.
S.handlers["market.priceRef"] = function(player, args)
    args = type(args) == "table" and args or {}
    local requestId, idOk = St.requestId(args.requestId)
    local item = args.item
    if not idOk or type(item) ~= "string" or item == "" or #item > Rp.ITEM_CHARS or string.find(item, "%c") then
        S.reply(player, "market.priceRef", { ok = false, requestId = requestId, error = "invalid_args" })
        return
    end
    S.reply(player, "market.priceRef", Rp.priceRef(item, requestId))
end

-- ---------- lifecycle ----------

function Rp.onTick()
    if not md then return end
    local ms = EC.now()
    if ms >= lastTick and ms - lastTick < Rp.TICK_MS then return end
    lastTick = ms
    if scan == nil and ms >= nextAt then startScan(ms) end
end

-- Test and admin hook: the scan's state without its data.
function Rp.status()
    return { state = state, running = scan ~= nil, generatedAt = result and result.generatedAt or nil, nextAt = nextAt }
end

function Rp.init(root)
    md = root
    scan, result, state = nil, nil, "none"
    lastTick = 0
    nextAt = EC.now() + Rp.FIRST_SCAN_MS
end

S.Reports = Rp
S.onInit(Rp.init)
Events.OnTickEvenPaused.Add(Rp.onTick)

return Rp
