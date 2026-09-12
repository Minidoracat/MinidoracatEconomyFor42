-- MinidoracatEconomyFor42 - economy census, per currency (server authority).
--
-- One pass over the accounts the economy already knows answers three different questions, so
-- they are answered from one snapshot instead of three scans:
--
--   St.supply(ms)          per currency: player available / reserved / total, holders, the system
--                          side and the top holders (admin dashboard, currency page)
--   St.accounts(args)      the paged, sorted, filtered account list behind admin.accounts
--   St.leaderboard(...)    the public boards behind the `leaderboard` command: total holdings of
--                          one currency, or one season's longest single lives (ECSeasons' record)
--
-- Four properties this file owns:
--
--   * the population is every account the economy knows: a wallet, a reward claim record, a
--     freeze mark, or a session online right now. System accounts are excluded, offline and
--     zero-balance accounts are not - "this account holds nothing" is an answer, and a list that
--     silently drops dormant accounts is not the server's ledger. Nothing here is truncated to a
--     scan limit: admin.players' 30/200 candidate bound answers a search box, not an audit.
--   * reads create nothing. Wallets, claim records and day buckets are read as they are; a
--     username that was only typed into a filter leaves no record behind.
--   * the public ranking is public data only: rank, username and - when the server allows it -
--     the amount. Never online, frozen, available, reserved or any administrative field. A
--     player always learns their own number, because it is theirs.
--   * issuance is counted per currency. A day recorded before per-currency rollups existed is
--     survivor's by construction (every writer of that era wrote survivor only) and unrecorded
--     for every other currency: those days are counted in `unknownDays`, never as 0.

if not MinidoracatEconomy or not MinidoracatEconomy.Rewards then
    require "MinidoracatEconomy/ECRewards"
end
if not MinidoracatEconomy or not MinidoracatEconomy.Config then
    require "MinidoracatEconomy/ECConfig"
end
local EC = MinidoracatEconomy
local S = EC and EC.Server
local L = EC and EC.Ledger
local R = EC and EC.Rewards
local Cfg = EC and EC.Config
local Se = EC and EC.Seasons
if not S or not S.AUTHORITY or not L or not R or not Cfg or not Se then
    return
end

EC.Stats = EC.Stats or {}
local St = EC.Stats

St.ACCOUNTS_PER_PAGE = 20
St.LEADERBOARD_PER_PAGE = 20
St.TOP_HOLDERS = 5
St.CACHE_MS = 3000                -- one census serves every page opened within this window
St.QUERY_CHARS = 64               -- account filter, as the client sends it
St.REQUEST_ID_MAX = 96
St.PAGE_MAX = 1000000             -- a page number, not an arithmetic expression
St.DAY_MS = 86400000

local md = nil
local cache = nil

-- ---------- sorting ----------
--
-- Kahlua's table.sort recurses (verify_mod.py refuses it) and EC.sortSafe is an insertion sort:
-- right for a page of rows, quadratic for a whole server's accounts. Bottom-up merge sort:
-- iterative, stable (a run only yields when the right element is strictly smaller), so the
-- username tie-break inside `less` is what decides equal balances - never the hash order of
-- pairs(). O(n log n) is what makes "sort everything, then page" affordable on a big realm.
local function sortRows(list, less)
    local n = #list
    if n < 2 then return list end
    local src, dst = list, {}
    local width = 1
    while width < n do
        local i = 1
        while i <= n do
            local mid = math.min(i + width - 1, n)
            local hi = math.min(i + 2 * width - 1, n)
            local a, b, k = i, mid + 1, i
            while a <= mid and b <= hi do
                if less(src[b], src[a]) then
                    dst[k] = src[b]; b = b + 1
                else
                    dst[k] = src[a]; a = a + 1
                end
                k = k + 1
            end
            while a <= mid do dst[k] = src[a]; a = a + 1; k = k + 1 end
            while b <= hi do dst[k] = src[b]; b = b + 1; k = k + 1 end
            i = hi + 1
        end
        src, dst = dst, src
        width = width * 2
    end
    if src ~= list then
        for i = 1, n do list[i] = src[i] end
    end
    return list
end
St.sortRows = sortRows

-- Stable account order: case-insensitive first (what a reader expects), exact bytes to break a
-- case-only tie, so two accounts never compare equal. One rule for every list this file builds -
-- the top holders, the account page and the public board must not disagree about who comes
-- first when two accounts hold the same amount.
local function beforeByName(a, b)
    local al, bl = string.lower(a), string.lower(b)
    if al ~= bl then return al < bl end
    return a < b
end

local function nameLess(a, b)
    return beforeByName(a.username, b.username)
end

-- ---------- census ----------

-- An account with no wallet row for a currency really holds nothing of it: 0 is a fact here.
-- A wallet row that exists but cannot be read is a different answer and never lands in these
-- zeros (see unreadableBalance).
local function blankBalances()
    local out = {}
    for _, id in ipairs(EC.CURRENCY_ORDER) do
        out[id] = { available = 0, reserved = 0, total = 0 }
    end
    return out
end

-- A balance number as the ledger writes them: a finite integer. Anything else (nil, a string,
-- NaN, an infinity, a fraction) is not a balance, and reading it as 0 would turn a corrupt
-- wallet into a poor but healthy account - in the supply, in the account page and in the
-- conservation difference all at once.
local function isBalance(v)
    return type(v) == "number" and v == v and v > -math.huge and v < math.huge and v == math.floor(v)
end

-- What one currency of one account looks like when its wallet row is unreadable: no numbers at
-- all, so every consumer has to say "unknown" instead of printing a zero.
local function unreadableBalance(b)
    b.available, b.reserved, b.total, b.unknown = nil, nil, nil, true
end

-- Top holders of one currency, highest first, equal amounts ordered by account name so the list
-- is the same on every call. Only the first TOP_HOLDERS are kept.
local function offerTop(top, username, amount)
    local pos = #top + 1
    while pos > 1 do
        local e = top[pos - 1]
        if amount > e.amount or (amount == e.amount and beforeByName(username, e.account)) then
            pos = pos - 1
        else
            break
        end
    end
    if pos > St.TOP_HOLDERS then return end
    table.insert(top, pos, { account = username, amount = amount })
    if #top > St.TOP_HOLDERS then table.remove(top) end
end

-- The whole economic population plus the per-currency supply, taken once and reused for
-- St.CACHE_MS. Every command that needs it asks for it; nothing here runs on a tick.
local function census(ms, force)
    if not force and cache and ms - cache.at >= 0 and ms - cache.at < St.CACHE_MS then return cache end
    local rows, byName = {}, {}
    local supply = {}
    for _, id in ipairs(EC.CURRENCY_ORDER) do
        supply[id] = { players = 0, reserved = 0, total = 0, system = 0, systemReserved = 0,
            accounts = 0, holders = 0, unreadable = 0, top = {} }
    end
    local function row(username)
        local r = byName[username]
        if not r then
            r = { username = username, online = false, frozen = md.frozen[username] ~= nil,
                balances = blankBalances() }
            byName[username] = r
            rows[#rows + 1] = r
        end
        return r
    end
    for account, byCurrency in pairs(md.wallets) do
        local named = type(account) == "string" and account ~= ""
        local system = named and L.isSystemAccount(account)
        local r = (named and not system) and row(account) or nil
        if not named or type(byCurrency) ~= "table" then
            -- The account's whole wallet is unreadable (a key that is not a name, a root that
            -- is not a table). It is still listed - dropping it would read as "this account has
            -- nothing" - but not one of its currencies may be initialised to zero, and every
            -- currency of this server loses its proof of conservation, not just one.
            for _, id in ipairs(EC.CURRENCY_ORDER) do
                supply[id].unreadable = supply[id].unreadable + 1
                if r then unreadableBalance(r.balances[id]) end
            end
        else
            for id, w in pairs(byCurrency) do
                local s = supply[id]
                if s then
                    local ok = type(w) == "table" and isBalance(w.available) and isBalance(w.reserved)
                    if not ok then
                        -- Counted, never summed: the page and the dashboard learn that this
                        -- currency has rows nobody could read, and the conservation difference
                        -- below stops being a proof.
                        s.unreadable = s.unreadable + 1
                        if r then unreadableBalance(r.balances[id]) end
                    elseif system then
                        s.system = s.system + w.available
                        s.systemReserved = s.systemReserved + w.reserved
                    else
                        local total = w.available + w.reserved
                        s.players = s.players + w.available
                        s.reserved = s.reserved + w.reserved
                        s.accounts = s.accounts + 1
                        local b = r.balances[id]
                        b.available, b.reserved, b.total = w.available, w.reserved, total
                        -- "Holder" means the account holds some of this currency, in the top
                        -- list exactly as in the count and on the public board: an account
                        -- with a wallet row and nothing in it is not one of the top holders.
                        if total > 0 then
                            s.holders = s.holders + 1
                            offerTop(s.top, account, total)
                        end
                    end
                end
            end
        end
    end
    -- Known to the economy without holding money right now: a reward claim record, a freeze
    -- mark, or a session online at this instant.
    for username in pairs(md.claims or {}) do
        if type(username) == "string" and username ~= "" and not L.isSystemAccount(username) then row(username) end
    end
    for username in pairs(md.frozen or {}) do
        if type(username) == "string" and username ~= "" and not L.isSystemAccount(username) then row(username) end
    end
    S.forEachOnline(function(p)
        local username = p:getUsername()
        if type(username) == "string" and username ~= "" and not L.isSystemAccount(username) then
            row(username).online = true
        end
    end)
    for _, id in ipairs(EC.CURRENCY_ORDER) do
        local s = supply[id]
        s.total = s.players + s.reserved
        -- Conservation difference: players + their reserved + the system side. It must be 0 -
        -- but only when every wallet row of this currency could be read. With unreadable > 0
        -- the sums are a lower bound and `net` proves nothing, which is what `complete` says.
        s.net = s.players + s.reserved + s.system + s.systemReserved
        s.complete = s.unreadable == 0
    end
    cache = { at = ms, rows = rows, byName = byName, supply = supply, boards = {} }
    return cache
end

-- Balances changed (a commit, a freeze, a restart): the next reader takes a fresh census.
function St.invalidate()
    cache = nil
end

-- Returns the per-currency supply and the instant the census behind it was taken: a caller
-- that prints the numbers must be able to print when they were true, not when it asked.
--
-- This one always recounts. The dashboard's supply is a statement about the whole economy at
-- a moment, and it is read once per page refresh - exactly the cost the old single-pass
-- supply() had. The cache exists for the paging reads (an account list walked page by page,
-- a leaderboard), where re-walking every wallet per page would be the real waste. It is also
-- the honest choice: a wallet changed by something that commits no transaction - a migration,
-- another mod, an operator's edit - would otherwise sit behind a stale snapshot for seconds
-- while the page claims to be showing the economy as it is.
function St.supply(ms)
    local snap = census(ms or EC.now(), true)
    return snap.supply, snap.at
end

-- ---------- admin.accounts ----------

local STATUS = { all = true, online = true, offline = true, frozen = true }

local function matchStatus(r, status)
    if status == "all" then return true end
    if status == "online" then return r.online end
    if status == "offline" then return not r.online end
    return r.frozen
end

local function validPage(v)
    if v == nil then return 1 end
    if type(v) ~= "number" or v ~= math.floor(v) or v < 1 or v > St.PAGE_MAX then return nil end
    return v
end

function St.requestId(v)
    if v == nil then return nil, true end
    if type(v) ~= "string" or v == "" or #v > St.REQUEST_ID_MAX or string.find(v, "%c") then return nil, false end
    return v, true
end

-- {query?, status?, sort?, descending?, page?} -> the reply body (the caller owns the gate, the
-- requestId echo and `perms`). The whole population is filtered and sorted before it is paged:
-- page 3 of a name search is page 3 of the matches, not of whatever a scan limit happened to see.
function St.accounts(args)
    local at = EC.now()
    local status = args.status
    if status == nil then status = "all" end
    if not STATUS[status] then return { ok = false, error = "invalid_args", at = at } end

    local query = args.query
    if query == nil then query = "" end
    if type(query) ~= "string" or #query > St.QUERY_CHARS or string.find(query, "%c") then
        return { ok = false, error = "invalid_args", at = at }
    end
    query = string.lower((string.gsub(query, "^%s*(.-)%s*$", "%1")))

    local sort = args.sort
    if sort == nil then sort = "username" end
    local currencySort = nil
    if sort ~= "username" and sort ~= "online" and sort ~= "frozen" then
        if type(sort) == "string" and EC.CURRENCIES[sort] then
            currencySort = sort
        else
            return { ok = false, error = "invalid_args", at = at }
        end
    end

    local descending = args.descending
    if descending == nil then descending = false end
    if type(descending) ~= "boolean" then return { ok = false, error = "invalid_args", at = at } end

    local page = validPage(args.page)
    if not page then return { ok = false, error = "invalid_args", at = at } end

    local snap = census(at)
    local rows = {}
    for _, r in ipairs(snap.rows) do
        if matchStatus(r, status)
            and (query == "" or string.find(string.lower(r.username), query, 1, true) ~= nil) then
            rows[#rows + 1] = r
        end
    end

    local less
    if currencySort then
        -- An account whose wallet row for this currency could not be read has no number to be
        -- sorted by. It keeps its place in the list (dropping it would hide the problem) and
        -- goes after every account that does have one, in both directions - placing it among
        -- the zeros would be the same lie as summing it as zero.
        less = function(a, b)
            local av, bv = a.balances[currencySort].total, b.balances[currencySort].total
            if av == nil or bv == nil then
                if av ~= nil then return true end
                if bv ~= nil then return false end
                return nameLess(a, b)
            end
            if av ~= bv then
                if descending then return av > bv end
                return av < bv
            end
            return nameLess(a, b)
        end
    elseif sort == "username" then
        less = function(a, b)
            if descending then return nameLess(b, a) end
            return nameLess(a, b)
        end
    else
        local field = sort
        less = function(a, b)
            local av, bv = a[field] == true, b[field] == true
            if av ~= bv then
                if descending then return bv end
                return av
            end
            return nameLess(a, b)
        end
    end
    sortRows(rows, less)

    local total = #rows
    local perPage = St.ACCOUNTS_PER_PAGE
    local pages = math.max(1, math.ceil(total / perPage))
    if page > pages then page = pages end
    local items = {}
    for i = (page - 1) * perPage + 1, math.min(total, page * perPage) do
        local r = rows[i]
        items[#items + 1] = { username = r.username, online = r.online, frozen = r.frozen,
            balances = r.balances }
    end
    return { ok = true, items = items, total = total, page = page, pages = pages,
        query = query, status = status, sort = sort, descending = descending, at = snap.at }
end

-- ---------- public leaderboard ----------

-- Total holdings of one currency, highest first: reserved money is still the holder's, and an
-- offline account is still a holder. Only accounts that actually hold something are ranked;
-- system accounts are not accounts of players. Equal totals share a rank (1, 1, 3) and are
-- ordered by name, so the board does not shuffle between two identical reads.
local function board(currency, at)
    local snap = census(at)
    local list = snap.boards[currency]
    if list then return list, snap end
    list = {}
    for _, r in ipairs(snap.rows) do
        local b = r.balances[currency]
        if b and b.total ~= nil and b.total > 0 then
            list[#list + 1] = { username = r.username, amount = b.total }
        end
    end
    sortRows(list, function(x, y)
        if x.amount ~= y.amount then return x.amount > y.amount end
        return nameLess(x, y)
    end)
    local rank, prev = 0, nil
    for i = 1, #list do
        local e = list[i]
        if prev == nil or e.amount ~= prev then
            rank, prev = i, e.amount
        end
        e.rank = rank
    end
    snap.boards[currency] = list
    return list, snap
end

-- A recorded survival time: whole game minutes, never negative, never a fraction of one. The
-- season module writes them; anything else in that map is a broken record, and a ranking built
-- on one would be a false statement about everybody ranked below it.
local function isMinutes(v)
    return type(v) == "number" and v == v and v >= 0 and v < math.huge and v == math.floor(v)
end

-- What a season looks like to everybody: identity, when it ran, how long it was meant to run,
-- whether its record is complete, how many took part. Copied field by field, so whatever the
-- season module keeps for itself (who started it, why) can never ride along into a public reply,
-- and no reply carries a live ModData table.
local function seasonMeta(m)
    if type(m) ~= "table" then return nil end
    return { id = m.id, number = m.number, startedAt = m.startedAt, endsAt = m.endsAt,
        endedAt = m.endedAt, durationDays = m.durationDays, partial = m.partial == true,
        participants = m.participants }
end

-- The season list every page needs to build a selector, in the same public shape. Used by the
-- login handshake and the admin page as well - one projection, so a field that is public on one
-- of them cannot be private on another. nil means the season module could not answer at all,
-- and a caller that was about to say "ok" has to stop saying it: a reply with no seasons in it
-- is not an empty history, it is an unread one.
function St.seasonState()
    local st, err = Se.state()
    if st == nil then return nil, err end
    if type(st) ~= "table" or type(st.currentId) ~= "string" or type(st.seasons) ~= "table" then
        return nil, "data_unreadable"
    end
    local out = { currentId = st.currentId, configuredDays = st.configuredDays, seasons = {} }
    local list = st.seasons
    if type(list) == "table" then
        for i = 1, #list do out.seasons[i] = seasonMeta(list[i]) end
    end
    return out
end

-- One season's ranking of longest single lives, longest first. The map belongs to the season
-- module and is read exactly as it stands: never sorted in place, never written to. Equal
-- minutes share a rank (1, 1, 3) and are ordered by name, so two identical reads agree.
local function survivalList(selector, username)
    local records, meta, err = Se.records(selector)
    if err ~= nil then return nil, nil, err end
    if type(records) ~= "table" or type(meta) ~= "table" or type(meta.id) ~= "string" then
        return nil, nil, "data_unreadable"
    end
    local list = {}
    for name, minutes in pairs(records) do
        -- One row nobody can read makes "nobody above you survived longer" unprovable, exactly
        -- as one unreadable wallet row does on the holdings board. Refuse the whole ranking.
        if type(name) ~= "string" or name == "" or not isMinutes(minutes) then
            return nil, nil, "data_unreadable"
        end
        if minutes > 0 and not L.isSystemAccount(name) then
            list[#list + 1] = { username = name, survivalMinutes = minutes }
        end
    end
    sortRows(list, function(x, y)
        if x.survivalMinutes ~= y.survivalMinutes then return x.survivalMinutes > y.survivalMinutes end
        return nameLess(x, y)
    end)
    local rank, prev = 0, nil
    for i = 1, #list do
        local e = list[i]
        if prev == nil or e.survivalMinutes ~= prev then rank, prev = i, e.survivalMinutes end
        e.rank = rank
    end
    return list, meta, nil, records[username]
end

-- The holdings board. Order of refusals is deliberate and unchanged: an unregistered currency is
-- unknown even while the boards are switched off, because the currency registry is public static
-- configuration and answering "disabled" there would hide a client bug behind an operator switch.
local function wealthReply(username, args, page, at, requestId)
    local currency = args.currency
    if type(currency) ~= "string" then
        return { ok = false, error = "invalid_args", kind = "wealth", at = at, requestId = requestId }
    end
    if not EC.CURRENCIES[currency] then
        return { ok = false, error = "unknown_currency", kind = "wealth", currency = currency,
            page = page, at = at, requestId = requestId }
    end
    -- A disabled currency is still readable: the coins people hold did not stop existing.
    if EC.sandbox("LeaderboardEnabled", true) ~= true then
        return { ok = false, error = "leaderboard_disabled", kind = "wealth", currency = currency,
            page = page, at = at, requestId = requestId }
    end
    -- A ranking is a claim about everyone at once: "nobody above you holds more". One wallet
    -- row of this currency that could not be read makes that claim unprovable, so the public
    -- board refuses instead of publishing a ranking with a hole in it. The refusal never says
    -- which account is unreadable - that is administrative detail (admin.accounts, read-gated),
    -- and the board is public.
    local snapshot = census(at)
    local s = snapshot.supply[currency]
    if s and s.unreadable > 0 then
        return { ok = false, error = "data_unreadable", kind = "wealth", currency = currency,
            page = page, at = snapshot.at, requestId = requestId }
    end
    local showAmounts = EC.sandbox("LeaderboardShowAmounts", false) == true
    local list, snap = board(currency, at)
    local perPage = St.LEADERBOARD_PER_PAGE
    local total = #list
    local pages = math.max(1, math.ceil(total / perPage))
    if page > pages then page = pages end
    local entries = {}
    for i = (page - 1) * perPage + 1, math.min(total, page * perPage) do
        local e = list[i]
        entries[#entries + 1] = { rank = e.rank, username = e.username,
            amount = (showAmounts or e.username == username) and e.amount or nil }
    end
    local mine = snap.byName[username]
    local balance = mine and mine.balances[currency]
    -- A player always learns their own number. It cannot be unreadable here: a single
    -- unreadable row of this currency refused the whole board above, so every balance this
    -- board was built from carries real figures and an absent wallet really is zero.
    local selfView = { amount = (balance and balance.total) or 0 }
    if selfView.amount > 0 then
        for i = 1, total do
            if list[i].username == username then
                selfView.rank, selfView.page = list[i].rank, math.ceil(i / perPage)
                break
            end
        end
    end
    return { ok = true, kind = "wealth", currency = currency, page = page, pages = pages,
        total = total, entries = entries, self = selfView, showAmounts = showAmounts,
        at = snap.at, requestId = requestId }
end

-- The survival board of one season ('current' follows whichever season is running). The off
-- switch comes before the data here, the other way round from the holdings board: which seasons
-- exist is recorded data, not static configuration, so a switched-off board reads nothing at all.
local function survivalReply(username, args, page, at, requestId)
    local season = args.season
    if season == nil then season = "current" end
    if type(season) ~= "string" or season == "" or #season > 64 or string.find(season, "%c") then
        return { ok = false, error = "invalid_args", kind = "survival", page = page, at = at,
            requestId = requestId }
    end
    if EC.sandbox("LeaderboardEnabled", true) ~= true then
        return { ok = false, error = "leaderboard_disabled", kind = "survival", season = season,
            page = page, at = at, requestId = requestId }
    end
    local state, stateErr = St.seasonState()
    if state == nil then
        -- Which season this board is about is part of the answer. Without it there is no board
        -- to publish, only a guess about which season the entries belong to.
        return { ok = false, error = stateErr or "data_unreadable", kind = "survival", season = season,
            page = page, at = at, requestId = requestId }
    end
    local list, meta, err, ownMinutes = survivalList(season, username)
    if list == nil then
        -- A season nobody ever recorded is unknown; a record that cannot be read says so. Neither
        -- is answered with an empty board, which would read as "nobody survived anything".
        return { ok = false, kind = "survival", season = season, page = page, at = at,
            requestId = requestId,
            error = err or "data_unreadable" }
    end
    local perPage = St.LEADERBOARD_PER_PAGE
    local total = #list
    local pages = math.max(1, math.ceil(total / perPage))
    if page > pages then page = pages end
    local entries = {}
    for i = (page - 1) * perPage + 1, math.min(total, page * perPage) do
        local e = list[i]
        entries[#entries + 1] = { rank = e.rank, username = e.username, survivalMinutes = e.survivalMinutes }
    end
    -- The asking player's own line, and nothing when there is none: an account with no recorded
    -- life in this season is not a zero on the board, it is simply not on it. Survival figures
    -- are public by nature (a rank is meaningless if the times are hidden), so LeaderboardShowAmounts
    -- - which is about money - does not apply, and no balance, freeze or session field is near this.
    local selfView = { survivalMinutes = ownMinutes }
    for i = 1, total do
        if list[i].username == username then
            selfView.survivalMinutes = list[i].survivalMinutes
            selfView.rank, selfView.page = list[i].rank, math.ceil(i / perPage)
            break
        end
    end
    -- The life being lived right now, only on the season it belongs to: a closed season's page
    -- must never grow a number after it ended.
    if meta.id == Se.currentId() then
        local prog, progressErr = Se.progress(username)
        if prog == nil then
            return { ok = false, kind = "survival", season = season, page = page, at = at,
                requestId = requestId, error = progressErr or "data_unreadable" }
        end
        if prog.known == true and type(prog.currentHours) == "number" then
            selfView.currentMinutes = math.floor(prog.currentHours * 60)
        end
    end
    return { ok = true, kind = "survival", season = season, selectedSeason = seasonMeta(meta),
        seasonState = state, page = page, pages = pages, total = total, at = at,
        entries = entries, self = selfView, requestId = requestId }
end

-- {kind, currency (wealth), season (survival), page?, requestId?} -> the public reply.
-- `username` is the asking player: they see their own figure and their own rank whatever the
-- server tells everyone else. The two boards share the page size, the tie rule and the
-- server-wide off switch, and nothing else: `season` never selects a historical balance (there
-- is no such record - holdings are what they are now), and the amount switch never hides a
-- survival time. `kind` is mandatory: there is no default board, so a client can never ask for
-- one ranking and be answered with another.
function St.leaderboard(username, args)
    local at = EC.now()
    local requestId, idOk = St.requestId(args.requestId)
    local page = validPage(args.page)
    local kind = args.kind
    if not idOk or not page or (kind ~= "wealth" and kind ~= "survival") then
        return { ok = false, error = "invalid_args", at = at, requestId = requestId,
            kind = (kind == "wealth" or kind == "survival") and kind or nil }
    end
    if kind == "survival" then return survivalReply(username, args, page, at, requestId) end
    return wealthReply(username, args, page, at, requestId)
end

S.handlers["leaderboard"] = function(player, args)
    S.reply(player, "leaderboard", St.leaderboard(player:getUsername(), type(args) == "table" and args or {}))
end

-- ---------- issuance rollups (per currency) ----------
--
-- md.rollups[day] = { v = 2, legacy?, byCurrency = { [id] = { checkinTotal, checkinCount,
-- milestoneTotal, mint, burn, buyback } } }. ECRewards owns the bucket (creation, the 60-day
-- trim, the check-in and milestone counters); this file adds mint / burn / buyback from the
-- ledger and reads the whole thing back for the dashboard.

-- One day as { [currency] = counters }, whether the day predates per-currency rollups, and the
-- set of currencies whose record of that day is known to be broken.
-- A bucket of the old shape is survivor's: every writer of that era wrote survivor and nothing
-- else (check-in and milestones were survivor-only, the commit hook filtered on it). What that
-- day did to any other currency was never written down - it is unknown, and unknown is not 0.
local function dayView(day)
    local r = md.rollups and md.rollups[day]
    if type(r) ~= "table" then return nil, false, nil end
    local broken = type(r.incomplete) == "table" and r.incomplete or nil
    if r.v == R.ROLLUP_VERSION and type(r.byCurrency) == "table" then
        return r.byCurrency, r.legacy == true, broken
    end
    return { [R.CURRENCY] = r }, true, broken
end

-- One currency of one day is missing issuance this process failed to record. The mark lives on
-- the day's own rollup bucket - the same record the numbers live on, not a second ledger - and
-- nothing ever clears it: a later commit that writes successfully adds what it moved, it does
-- not recover the amount that was lost, so the day stays a lower bound forever. When even the
-- bucket cannot be reached the mark is written on a fresh bucket of the canonical shape, so
-- the gap survives instead of disappearing with the exception that caused it.
local function markIncomplete(day, currency)
    local ok, err = pcall(function()
        local r = md.rollups[day]
        if type(r) ~= "table" then
            r = { v = R.ROLLUP_VERSION, byCurrency = {} }
            md.rollups[day] = r
        end
        if type(r.incomplete) ~= "table" then r.incomplete = {} end
        r.incomplete[currency] = true
    end)
    if not ok then
        EC.log("issuance gap for " .. tostring(currency) .. " on " .. tostring(day)
            .. " could not even be marked: " .. tostring(err))
    end
end

-- The last `days` days (today included) per currency and per source. Absent day buckets are a
-- real 0 (a bucket is written the moment money is issued, and the trim keeps 60 days - more
-- than the longest window here).
--
-- `unknownDays` counts the days this currency's record is *incomplete*, which is not the same
-- as "has no row". Two things make a day incomplete, and neither is ever undone by a later
-- successful write:
--   * it predates per-currency rollups: incomplete for every currency except survivor, for the
--     whole day. Appending a cat row to that bucket today does not record the cat mints the old
--     build never wrote down.
--   * this process failed to record an issuance on it (markIncomplete): the amount that was
--     lost is lost, so the day stays a lower bound even after the next commit records fine.
-- The known numbers are still added - they are known - and the day is still counted as unknown.
-- Presenting a partially recorded day as the whole truth is the one thing this must never do.
function St.issued(days, ms)
    local out = { days = days, byCurrency = {} }
    for _, id in ipairs(EC.CURRENCY_ORDER) do
        out.byCurrency[id] = { checkin = 0, milestone = 0, mint = 0, burn = 0, buyback = 0, unknownDays = 0 }
    end
    for i = 0, days - 1 do
        local view, legacy, broken = dayView(R.dayKey(ms - i * St.DAY_MS))
        for _, id in ipairs(EC.CURRENCY_ORDER) do
            local o = out.byCurrency[id]
            local c = view and view[id]
            if type(c) == "table" then
                o.checkin = o.checkin + (tonumber(c.checkinTotal) or 0)
                o.milestone = o.milestone + (tonumber(c.milestoneTotal) or 0)
                o.mint = o.mint + (tonumber(c.mint) or 0)
                o.burn = o.burn + (tonumber(c.burn) or 0)
                o.buyback = o.buyback + (tonumber(c.buyback) or 0)
            end
            if (legacy and id ~= R.CURRENCY) or (broken and broken[id]) then
                o.unknownDays = o.unknownDays + 1
            end
        end
    end
    return out
end

-- The faucet and the drains, per currency, as the ledger commits them. Incremental: never a
-- rescan. `buyback` is the part of the mint that paid for goods the shop bought back.
--
-- Every posting is recorded on its own. The ledger catches whatever a listener throws, so a
-- bucket this process cannot write (a corrupt counter, a rollup that refuses) would otherwise
-- abandon the rest of the event silently and leave the dashboard calling the day complete.
-- Instead the failure is written down as a gap on that day and that currency, and the
-- remaining postings are still recorded: what can be counted is counted, what was lost is
-- named. Money is not affected either way - this is the observability copy, the transaction
-- itself is already committed.
local function record(day, ev, p, id)
    if p.account == R.MINT_ACCOUNT and p.amount < 0 then
        local c = R.rollupCurrency(day, id)
        c.mint = (c.mint or 0) - p.amount
        if ev.kind == "shop_sell" then c.buyback = (c.buyback or 0) - p.amount end
    elseif p.account == "SYSTEM_BURN" and p.amount > 0 then
        local c = R.rollupCurrency(day, id)
        c.burn = (c.burn or 0) + p.amount
    end
end

L.onCommitted(function(ev)
    St.invalidate()
    local day = R.dayKey(ev.ts or EC.now())
    for _, p in ipairs(ev.postings or {}) do
        local id = p.currency
        if type(id) == "string" and EC.CURRENCIES[id] and type(p.amount) == "number" then
            local ok, err = pcall(record, day, ev, p, id)
            if not ok then
                EC.log("issuance rollup failed for " .. id .. " on " .. tostring(day) .. ": " .. tostring(err))
                markIncomplete(day, id)
            end
        end
    end
end)

function St.init(root)
    md = root
    cache = nil
end

S.Stats = St
S.onInit(St.init)

return St
