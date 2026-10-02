-- MinidoracatEconomyFor42 - account merge (server authority).
--
-- One Steam account may own several login names. The names bound EXACTLY (a whitelist text,
-- ECIdentity) to one SteamID, not reserved and without an unresolved conflict, form a group. One
-- of them is the group's account - the canonical, decided once by (md.firstSeen, whitelist id,
-- name) and kept in the identity file - and every other name becomes an alias of it: its money,
-- counters, claims and clean letters move into the account in ONE Lua call (Mg.mergeOne), and
-- md.identity.merged[alias] = { into, mergeId, epoch, seq, at } is written last. S.accountOf
-- reads only that marker, and it lives in Global ModData next to the data it moved, so a world
-- rollback undoes both together (ServerMap.java:373-409 saves them in one pass) and the next start
-- merges again, conserved. Packet handling, the save (ServerMap.preupdate) and Lua ticks share
-- one main-loop thread (GameServer.java:938-972): nothing observes a merge half done.
--
-- Stays with each login (one character save each): recovery receipts, holds and journal, pending
-- outs, which save claimed a letter, the season survival base keys and entitlement rows.
--
-- IdentityAutoMerge (sandbox, default false) decides whether anything merges. The plan is
-- computed and published either way, on start and after every accepted import:
-- Lua/MinidoracatEconomy/identity/merge-plan.json (server-private; holds exact SteamIDs) - a
-- summary line, then one line per group - admin.identity status.merge (the counts) and the
-- merge column of the identity page's logins list (ECIdentity Id.loginsPage, via Mg.planGroups).
-- Merges run in a start-up pass (every ready alias; OnServerStarted fires inside startServer
-- before any packet, GameServer.java:828, 1533 vs :894, 910, 939) and then every Mg.TICK_MS on
-- OnTickEvenPaused (IngameState.java:1317), at most Mg.TICK_MAX aliases a pass.

if not MinidoracatEconomy or not MinidoracatEconomy.Identity then
    require "MinidoracatEconomy/ECIdentity"
end
local EC = MinidoracatEconomy
local S = EC and EC.Server
local L = EC and EC.Ledger
local X = EC and EC.Export
local Id = EC and EC.Identity
if not S or not S.AUTHORITY or not L or not X or not Id then
    return
end

EC.Merge = EC.Merge or {}
local Mg = EC.Merge

Mg.PLAN_FILE = "MinidoracatEconomy/identity/merge-plan.json"
Mg.VERSION = 1
Mg.TICK_MS = 60000
Mg.TICK_MAX = 10          -- aliases merged per running pass; the start-up pass has no limit

local plan = nil
local lastTick = 0
local failed = {}        -- alias -> the error of a merge that stopped midway (this uptime)

function Mg.enabled()
    return EC.sandbox("IdentityAutoMerge", false) == true
end

local function byName(a, b) return a < b end

-- ---------- blockers ----------

-- Why `alias` cannot be merged into `into` right now (codes in order); empty when it can. The
-- plan and Mg.mergeOne share it, so the preview says exactly what a merge would do.
function Mg.blockers(alias, into, online)
    local md, out = S.modData(), {}
    online = online or S.onlineNames()
    -- an online alias may be mid-request under a key that names it (idempotency keys carry the
    -- account name) and its client holds the old account; the canonical may be online
    if online[alias] then out[#out + 1] = "alias_online" end
    -- a merge that failed midway waits for a restart instead of failing again every pass
    if failed[alias] then out[#out + 1] = "merge_failed" end
    if md.frozen[alias] ~= nil or md.frozen[into] ~= nil then out[#out + 1] = "frozen" end
    local money = L.mergeBlocker(alias)
    if money then out[#out + 1] = money end
    local listing, auction, mail = S.Market.mergeBlocker(alias), S.Auction.mergeBlocker(alias), S.Mailbox.mergeBlocker(alias)
    if listing then out[#out + 1] = listing end
    if auction then out[#out + 1] = auction end
    if mail then out[#out + 1] = mail end
    return out
end

-- ---------- groups ----------

-- Every exact SteamID text with at least two names attached: its exact members, the names whose
-- recorded conflict points at it (blocked: conflict or reserved) and the names bound only by a
-- rounded OnNewGame double that equals it (ineligible: not_exact). Two texts rounding to one
-- double never merge (ineligible: collision).
local function buildGroups()
    local v = Id.view()
    local groups, byDouble = {}, {}
    local function member(g, name, state, reason)
        if g.byName[name] then return end
        local m = { name = name, state = state, reason = reason }
        g.byName[name] = m
        g.members[#g.members + 1] = m
    end
    for text, set in pairs(v.byText) do
        local g = { sid = text, members = {}, byName = {} }
        groups[text] = g
        local d = Id.sidDouble(text)
        if d then
            byDouble[d] = byDouble[d] or {}
            byDouble[d][#byDouble[d] + 1] = text
        end
        local collided = Id.collides(text)
        for name in pairs(set.names) do
            if collided then
                member(g, name, "ineligible", "collision")
            elseif Id.unresolved(name) then
                member(g, name, "blocked", "conflict")
            else
                member(g, name, "eligible")
            end
        end
    end
    for name, d in pairs(v.disputes) do
        local reason = Id.unresolved(name)
        local g = reason and groups[d.text] or nil
        if g then member(g, name, "blocked", reason == "RESERVED" and "reserved" or "conflict") end
    end
    for name, b in pairs(v.bindings) do
        if not b.reserved and not b.exact then
            for _, text in ipairs(byDouble[b.sid] or {}) do member(groups[text], name, "ineligible", "not_exact") end
        end
    end
    local out = {}
    for _, g in pairs(groups) do
        if #g.members >= 2 then out[#out + 1] = g end
    end
    return out
end

-- The group's account and every member's state. A completed merge names the account (its
-- `into` wins over everything); otherwise the recorded decision; otherwise, with two eligible
-- names, a decision is made now and recorded for good: the one-account primary ECIdentity
-- already recorded for this Steam account when it is eligible (rule "primary": the canonical then
-- never takes the policy's primary away from a player who was told it is theirs), else
-- Id.pickCanonical. A later member is an alias of it.
local function decide(g, md, online, ms)
    local merged, v = md.identity.merged, Id.view()
    local eligible, account, rule = {}, nil, nil
    for _, m in ipairs(g.members) do
        if m.state == "eligible" then eligible[#eligible + 1] = m.name end
        local rec = merged[m.name]
        if type(rec) == "table" and type(rec.into) == "string" and (account == nil or rec.into < account) then
            account, rule = rec.into, "merged"
        end
    end
    EC.sortSafe(eligible, byName)
    local c = v.canon[g.sid]
    if account == nil and c ~= nil then account, rule = c.name, c.rule end
    if account == nil and #eligible >= 2 then
        local primary = Id.recordedPrimary(g.sid)
        for _, name in ipairs(eligible) do
            if name == primary then account, rule = name, "primary" end
        end
        if account == nil then account, rule = Id.pickCanonical(md, eligible) end
        local b = v.bindings[account]
        Id.recordCanon(g.sid, account, rule, b and b.src or "?", ms)
    end
    if account == nil and #eligible == 1 then account, rule = eligible[1], "only" end
    local canonical = account and g.byName[account] or nil
    -- the canonical left the group (rebound elsewhere, a conflict, merged itself): frozen for a human
    g.account, g.rule = account, rule
    g.moved = account ~= nil and (canonical == nil or canonical.state ~= "eligible" or merged[account] ~= nil) or nil
    for _, m in ipairs(g.members) do
        local rec = merged[m.name]
        if m.name ~= account and type(rec) == "table" and rec.into == account then
            m.state, m.reason = "merged", nil
        elseif m.state == "eligible" then
            if m.name == account then
                m.state = "canonical"
            else
                local reasons = Mg.blockers(m.name, account, online)
                if g.moved then table.insert(reasons, 1, "canonical_moved") end
                m.reasons = #reasons > 0 and reasons or nil
                m.state, m.reason = #reasons == 0 and "ready" or "blocked", reasons[1]
            end
        end
    end
    EC.sortSafe(g.members, function(a, b)
        if (a.state == "canonical") ~= (b.state == "canonical") then return a.state == "canonical" end
        return a.name < b.name
    end)
end

-- Recomputes the plan (recording a canonical where a group is new). Returns it.
function Mg.plan(ms)
    local md = S.modData()
    local online = S.onlineNames()
    local groups = buildGroups()
    for _, g in ipairs(groups) do decide(g, md, online, ms) end
    EC.sortSafe(groups, function(a, b) return (a.account or a.sid) < (b.account or b.sid) end)
    local p = { at = ms, groups = groups, aliases = 0, merged = 0, ready = 0, blocked = {}, ineligible = 0 }
    for _, g in ipairs(groups) do
        for _, m in ipairs(g.members) do
            if m.state == "merged" then
                p.merged, p.aliases = p.merged + 1, p.aliases + 1
            elseif m.state == "ready" then
                p.ready, p.aliases = p.ready + 1, p.aliases + 1
            elseif m.state == "blocked" then
                p.blocked[m.reason] = (p.blocked[m.reason] or 0) + 1
                p.aliases = p.aliases + 1
            elseif m.state == "ineligible" then
                p.ineligible = p.ineligible + 1
            end
        end
    end
    plan = p
    return p
end

-- ---------- the merge ----------

-- Merges `alias` into `into` in this one call, or changes nothing and says why. The stores go
-- first and the money after them: a Lua error in a store (or a refused posting) stops the merge
-- with the money still in the alias's own wallet, where that login sees it, and without the
-- marker. Every step only moves what is still under the alias, so the next attempt (after a
-- restart: Mg.blockers says merge_failed until then) finishes what is left, the money under a
-- fresh ledger key. The marker is the last write.
function Mg.mergeOne(alias, into, ms)
    local md = S.modData()
    local merged = md.identity.merged
    ms = ms or EC.now()
    if type(alias) ~= "string" or type(into) ~= "string" or alias == into then return nil, "invalid_args" end
    if merged[alias] ~= nil then return nil, "already_merged" end
    if merged[into] ~= nil then return nil, "canonical_moved" end
    local v = Id.view()
    local ba, bi = v.bindings[alias], v.bindings[into]
    if not (ba and bi and ba.exact and bi.exact and not ba.reserved and not bi.reserved) then return nil, "not_exact" end
    if ba.text ~= bi.text or Id.unresolved(into) then return nil, "canonical_moved" end
    if Id.collides(ba.text) then return nil, "collision" end
    if Id.unresolved(alias) then return nil, "conflict" end
    local account = nil
    for name in pairs(v.byText[ba.text].names) do
        local rec = merged[name]
        if type(rec) == "table" and type(rec.into) == "string" and (account == nil or rec.into < account) then account = rec.into end
    end
    if account == nil and v.canon[ba.text] then account = v.canon[ba.text].name end
    if account ~= into then return nil, "canonical_moved" end
    local reasons = Mg.blockers(alias, into)
    if #reasons > 0 then return nil, reasons[1] end
    if (md.claims[alias] ~= nil and type(md.claims[alias]) ~= "table")
        or (md.claims[into] ~= nil and type(md.claims[into]) ~= "table") then return nil, "data_unreadable" end
    -- 1. every per-account store
    local ok, claims, age, letters = pcall(function()
        local c, err = S.Rewards.mergeAccount(alias, into, ms)
        if c == nil and err ~= nil then error("claims: " .. tostring(err)) end
        local a = S.Transfer.mergeAccount(alias, into)
        S.Shop.mergeAccount(alias, into)
        S.Exchange.mergeAccount(alias, into)
        S.Admin.mergeAccount(alias, into)
        return c, a, S.Mailbox.mergeAccount(alias, into)
    end)
    if not ok then
        failed[alias] = tostring(claims)
        EC.log("account merge " .. alias .. " -> " .. into .. " stopped before the money: " .. failed[alias])
        return nil, "merge_failed"
    end
    -- 2. the money: one account_merge tx, every currency's available balance (reserved is 0)
    local wallets, currencies, postings, moved = md.wallets[alias] or {}, {}, {}, {}
    for currency in pairs(wallets) do currencies[#currencies + 1] = currency end
    EC.sortSafe(currencies, byName)
    for _, currency in ipairs(currencies) do
        local amount = tonumber(wallets[currency].available) or 0
        if amount > 0 then
            postings[#postings + 1] = { account = alias, currency = currency, amount = -amount }
            postings[#postings + 1] = { account = into, currency = currency, amount = amount }
            moved[currency] = amount
        end
    end
    local txId = nil
    if #postings > 0 then
        local res = L.post({ kind = "account_merge", requestId = "merge:" .. alias .. ":" .. S.newId(),
            reasonCode = "account_merge", actor = "SYSTEM", merge = true, payload = { alias = alias, into = into },
            postings = postings })
        if not res.ok then
            failed[alias] = tostring(res.error)
            EC.log("account merge " .. alias .. " -> " .. into .. " stopped at the money: " .. failed[alias])
            return nil, res.error or "ledger"
        end
        txId = res.txId
    end
    -- 3. the alias's emptied keys
    local empty = true
    for _, w in pairs(md.wallets[alias] or {}) do
        if (w.available or 0) ~= 0 or (w.reserved or 0) ~= 0 then empty = false end
    end
    if empty then md.wallets[alias] = nil end
    md.receipts[alias] = nil
    -- 4. the marker, last
    local mergeId = S.newId()
    local rec = { into = into, mergeId = mergeId, epoch = md.meta.epoch, seq = md.meta.seq, at = ms }
    merged[alias] = rec
    -- 5. the event; the SteamID only in its private block (the events file is server-private too)
    X.emit("identity.merged", { mergeId = mergeId, alias = alias, into = into, txId = txId, moved = moved,
        claims = claims, firstSeen = age, letters = letters,
        participantsDelta = type(claims) == "table" and claims.participantsDelta or 0,
        markerEpoch = rec.epoch, markerSeq = rec.seq, private = { steamId = ba.text } })
    EC.log("account merge " .. alias .. " -> " .. into .. " (" .. mergeId .. ")")
    return rec
end

-- One pass: recompute the plan, then (IdentityAutoMerge, and only in Steam mode: without Steam no
-- SteamID proves who a name is) merge its ready aliases, at most `limit` of them (nil = all).
-- One ACCOUNT_MERGE_PASS audit line for a pass that merged anything (the ModData ring holds 500
-- lines; the first pass may merge hundreds). A canonical the plan records decides the Steam
-- account's one-account primary, so every online seat whose standing the pass changed is told.
local function mergePass(ms, limit)
    local p = Mg.plan(ms)
    if not Mg.enabled() or not Id.steamMode() then return 0 end
    local n = 0
    for _, g in ipairs(p.groups) do
        for _, m in ipairs(g.members) do
            if m.state == "ready" and (limit == nil or n < limit) then
                local ok, err = Mg.mergeOne(m.name, g.account, ms)
                if ok then
                    n = n + 1
                else
                    EC.log("account merge " .. m.name .. " -> " .. tostring(g.account) .. " refused: " .. tostring(err))
                end
            end
        end
    end
    if n > 0 then
        X.audit({ action = "ACCOUNT_MERGE_PASS", target = "identity", field = limit and "tick" or "start",
            admin = "SYSTEM", after = n })
        Mg.plan(ms)
        Mg.writePlan()
    end
    return n
end

function Mg.pass(ms, limit)
    local before = Id.onlineVerdicts()
    local n = mergePass(ms, limit)
    Id.announce(before)
    return n
end

-- ---------- the plan file and the status ----------

-- Replaces merge-plan.json: the summary first, then one line per group with each member's
-- state, reasons, firstSeen, whitelist id, balances and letters.
function Mg.writePlan()
    local p = plan
    if p == nil then return false end
    local md = S.modData()
    local byOwner = md.mailbox and md.mailbox.byOwner or {}
    local moving, lines = {}, {}
    for _, g in ipairs(p.groups) do
        local members = {}
        for i, m in ipairs(g.members) do
            local row = { name = m.name, state = m.state, reason = m.reason, reasons = m.reasons,
                firstSeen = md.firstSeen and md.firstSeen[m.name], whitelistId = Id.whitelistId(m.name) }
            if m.state == "ready" or m.state == "blocked" then
                local balances = {}
                for currency, w in pairs(md.wallets[m.name] or {}) do
                    balances[currency] = { available = w.available, reserved = w.reserved }
                    if m.state == "ready" then moving[currency] = (moving[currency] or 0) + (tonumber(w.available) or 0) end
                end
                row.balances = balances
                row.letters = byOwner[m.name] and EC.countKeys(byOwner[m.name].entries) or 0
            end
            members[i] = row
        end
        lines[#lines + 1] = EC.jsonEncode({ type = "group", sid = g.sid, account = g.account, rule = g.rule,
            moved = g.moved, members = members })
    end
    local summary = EC.jsonEncode({ type = "merge-plan", v = Mg.VERSION, at = p.at, enabled = Mg.enabled(),
        groups = #p.groups, aliases = p.aliases, merged = p.merged, ready = p.ready, blocked = p.blocked,
        ineligible = p.ineligible, moving = moving })
    local writer = nil
    local opened = pcall(function() writer = getFileWriter(Mg.PLAN_FILE, true, false) end)
    if not opened or writer == nil then
        EC.log("merge plan " .. Mg.PLAN_FILE .. " could not be opened for writing")
        return false
    end
    local written = pcall(function()
        writer:writeln(summary)
        for _, line in ipairs(lines) do writer:writeln(line) end
    end)
    local closed = pcall(function() writer:close() end)
    return written and closed
end

-- admin.identity status.merge: the counts. The members are listed by the logins page.
function Mg.status()
    local p = plan
    local out = { enabled = Mg.enabled(), groups = 0, aliases = 0, merged = 0, ready = 0, blocked = {}, ineligible = 0 }
    if p == nil then return out end
    out.groups, out.aliases, out.merged, out.ready, out.ineligible, out.planAt =
        #p.groups, p.aliases, p.merged, p.ready, p.ineligible, p.at
    for reason, n in pairs(p.blocked) do out.blocked[reason] = n end
    return out
end

-- The plan's groups as Mg.plan computed them ({ account, members = { name, state, reason,
-- reasons } }) and when, for the logins list; read only. No plan yet: none, nil.
function Mg.planGroups()
    if plan == nil then return {}, nil end
    return plan.groups, plan.at
end

-- ---------- lifecycle ----------

-- After every module's init and the durable poll (ECServer.onServerStarted): the companion
-- export is read whole (an accepted one recomputes the plan), then the unlimited start-up pass.
function Mg.onStarted()
    local ms = EC.now()
    lastTick = ms
    Id.startExport(ms)
    Mg.pass(ms, nil)
    Mg.writePlan()
end

-- An import was accepted (ECIdentity): the plan follows it.
function Mg.onImport(ms)
    Mg.plan(ms)
    Mg.writePlan()
end

function Mg.onTick()
    if S.modData() == nil then return end
    local ms = EC.now()
    if ms - lastTick < Mg.TICK_MS then return end
    lastTick = ms
    if not Mg.enabled() then return end
    local ok, err = pcall(Mg.pass, ms, Mg.TICK_MAX)
    if not ok then EC.log("account merge pass failed: " .. tostring(err)) end
end

function Mg.init()
    plan, lastTick, failed = nil, 0, {}
end

S.Merge = Mg
S.onInit(Mg.init)
Events.OnTickEvenPaused.Add(Mg.onTick)

return Mg
