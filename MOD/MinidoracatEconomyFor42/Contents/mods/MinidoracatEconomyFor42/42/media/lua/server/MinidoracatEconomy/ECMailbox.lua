-- MinidoracatEconomyFor42 - minimal mailbox (server authority; spec 12 stage C/D, 19.7).
--
-- Money and mailbox entries live in Global ModData and roll back together (rule one). Items
-- cross into the player save only through claim-in (rule two): mailbox entry `claiming` ->
-- rebuild + stamp item modData {mailId, txId, epoch, seq} -> `claimed`, and the player's own
-- modData keeps a claim witness {epoch, seq} per mailId. The witness is what lets the login
-- reconciliation (rule three) tell "player save older than the claim, redeliver" from "player
-- used the item, do nothing": a witness means the player save already saw the claim.
-- Stamped items whose entry no longer exists are taken back only when S.isRolledBack says the
-- claim itself was rolled back (money came back with the world save); anything older is settled.
-- Death (rule five, part one): every `claimed` entry of that username becomes `settled` and is
-- never redelivered - the items are on the corpse.
--
-- Engine references (snapshot 42.20.4-20260826):
--   instanceItem(fullType)          LuaManager.java:5610-5620 (A7: InventoryItemFactory is not a global)
--   inv:AddItem + sendAddItemsToContainer  ItemContainer.java:458 ; LuaManager.java:12316,
--                                   GameServer.java:2407 (A8: the send only ships the packet)
--   inv:hasRoomFor(chr, weight)     ItemContainer.java:233-237
--   item:getModData()               InventoryItem.java:433-437 (saved with the item, :1695-1696)
--   player:getModData()/transmitModData  saved with the player blob (A9/A10)
--   OnCharacterDeath                IsoGameCharacter.java:4866-4867 (OnPlayerDeath never fires here)

if not MinidoracatEconomy or not MinidoracatEconomy.Terminal then
    require "MinidoracatEconomy/ECTerminal"
end
local EC = MinidoracatEconomy
local S = EC and EC.Server
local X = EC and EC.Export
local T = EC and EC.Terminal
if not S or not S.AUTHORITY or not X or not T then
    return
end

EC.Mailbox = EC.Mailbox or {}
local M = EC.Mailbox

M.PER_ACCOUNT = 50           -- unclaimed entries per account (spec 12 stage D limits)
M.GLOBAL_MAX = 10000         -- unclaimed entries server-wide
M.ITEMS_MAX = 100            -- items per entry
M.CLAIMED_TTL_MS = 24 * 3600000
M.WITNESS_MAX = 64
M.LIST_MAX = 60
M.PRUNE_EVERY_MS = 60000

local md = nil
local lastPrune = 0

-- ---------- state ----------

local function owner(username, create)
    local o = md.mailbox.byOwner[username]
    if not o and create then
        o = { entries = {}, unclaimed = 0 }
        md.mailbox.byOwner[username] = o
    end
    return o
end

function M.unclaimed(username)
    local o = owner(username, false)
    return o and o.unclaimed or 0
end

function M.hasFreeSlot(username)
    return M.unclaimed(username) < M.PER_ACCOUNT and md.mailbox.unclaimed < M.GLOBAL_MAX
end

-- fields = { kind, item, qty, txId, price?, snapshot?, listingId? }. A snapshot entry rebuilds
-- `qty` copies through ECCodec; without one the entry is `qty` fresh items of `item` (system shop).
-- Caller checked hasFreeSlot (or is a system return allowed past the cap); this never fails.
function M.add(username, fields)
    local o = owner(username, true)
    local id = S.newId()
    local entry = {
        id = id, owner = username, kind = fields.kind, item = fields.item, qty = fields.qty,
        txId = fields.txId, price = fields.price, snapshot = fields.snapshot, listingId = fields.listingId,
        state = "ready", at = EC.now(),
    }
    o.entries[id] = entry
    o.unclaimed = o.unclaimed + 1
    md.mailbox.unclaimed = md.mailbox.unclaimed + 1
    return entry
end

local function settle(o, entry, state, ms)
    if entry.state == "ready" or entry.state == "claiming" then
        o.unclaimed = math.max(0, o.unclaimed - 1)
        md.mailbox.unclaimed = math.max(0, md.mailbox.unclaimed - 1)
    end
    entry.state = state
    entry.claimedAt = ms
end

local function reopen(o, entry)
    if entry.state ~= "ready" then
        o.unclaimed = o.unclaimed + 1
        md.mailbox.unclaimed = md.mailbox.unclaimed + 1
    end
    entry.state = "ready"
    entry.claimedAt = nil
end

-- Ready entries newest first (client view).
function M.list(username)
    local out = {}
    local o = owner(username, false)
    if not o then return out end
    for _, e in pairs(o.entries) do
        if e.state == "ready" or e.state == "claiming" then
            out[#out + 1] = { id = e.id, kind = e.kind, item = e.item, qty = e.qty, price = e.price, txId = e.txId, at = e.at }
        end
    end
    EC.sortSafe(out, function(a, b) return a.at > b.at end)
    while #out > M.LIST_MAX do table.remove(out) end
    return out
end

-- ---------- player side (witness + stamps) ----------

local function playerData(player)
    local t = player:getModData()
    local p = t[EC.PLAYER_MODDATA_KEY]
    if type(p) ~= "table" then
        p = {}
        t[EC.PLAYER_MODDATA_KEY] = p
    end
    if type(p.claims) ~= "table" then p.claims = {} end
    if type(p.pendingOuts) ~= "table" then p.pendingOuts = {} end
    return p
end

local function transmit(player)
    pcall(function() player:transmitModData() end)
end

local function addWitness(p, mailId, epoch, seq)
    p.claims[mailId] = { epoch = epoch, seq = seq }
    local n, oldest, oldestSeq = 0, nil, nil
    for id, w in pairs(p.claims) do
        n = n + 1
        if not oldestSeq or (w.seq or 0) < oldestSeq then oldest, oldestSeq = id, w.seq or 0 end
    end
    if n > M.WITNESS_MAX and oldest then p.claims[oldest] = nil end
end

local function stampOf(item)
    local ok, m = pcall(function() return item:getModData()[EC.PLAYER_MODDATA_KEY] end)
    if ok and type(m) == "table" and type(m.mailId) == "string" then return m end
    return nil
end

-- mailId -> { stamp, items = { {item, container}, ... } } over the backpack and up to three levels
-- of carried bags. A purchase of N items carries N stamps with the same mailId: every one of them
-- belongs to the same decision (live: 2 + 3 bandages, one per purchase was taken back at first).
local function scanStamped(inv)
    local found = {}
    local function scan(container, depth)
        local ok, items = pcall(function() return container:getItems() end)
        if not ok or not items then return end
        for i = 0, items:size() - 1 do
            local it = items:get(i)
            local st = it and stampOf(it)
            if st then
                local rec = found[st.mailId]
                if not rec then
                    rec = { stamp = st, items = {} }
                    found[st.mailId] = rec
                end
                rec.items[#rec.items + 1] = { item = it, container = container }
            end
            if depth < 3 and it then
                local okc, inner = pcall(function() return it:getInventory() end)
                if okc and inner and inner ~= container then scan(inner, depth + 1) end
            end
        end
    end
    scan(inv, 0)
    return found
end

local function itemWeight(item)
    local ok, w = pcall(function() return item:getUnequippedWeight() end)
    if ok and type(w) == "number" then return w end
    local ok2, w2 = pcall(function() return item:getActualWeight() end)
    return ok2 and type(w2) == "number" and w2 or 0
end

-- Rebuild + stamp + hand over; returns ok, error. The entry is untouched on failure.
local function build(entry)
    if type(entry.snapshot) == "table" and S.Codec then
        return S.Codec.rebuild(entry.snapshot)
    end
    local item = instanceItem(entry.item)
    if not item then return nil, "item_unavailable" end
    return item
end

local function deliver(player, entry, claimSeq)
    local inv = player:getInventory()
    if not inv then return false, "no_inventory" end
    local first, err = build(entry)
    if not first then return false, err or "item_unavailable" end
    local n = math.max(1, math.min(M.ITEMS_MAX, entry.qty or 1))
    local okRoom, room = pcall(function() return inv:hasRoomFor(player, itemWeight(first) * n) end)
    if not okRoom or room ~= true then return false, "backpack_full" end
    local list = ArrayList.new()
    for i = 1, n do
        local item = i == 1 and first or build(entry)
        if not item then return false, "item_unavailable" end
        item:getModData()[EC.PLAYER_MODDATA_KEY] = { mailId = entry.id, txId = entry.txId, epoch = md.meta.epoch, seq = claimSeq }
        inv:AddItem(item)
        list:add(item)
    end
    sendAddItemsToContainer(inv, list)
    return true
end

local function anomaly(username, mailId, resolution, extra)
    local fields = { kind = "mailbox", username = username, mailId = mailId, resolution = resolution }
    for k, v in pairs(extra or {}) do fields[k] = v end
    X.emit("ledger.anomaly", fields)
    EC.log("mailbox reconcile " .. username .. " " .. mailId .. " -> " .. resolution)
end

-- ---------- claim-in (rule two) ----------

-- Returns { ok, mailId, item, qty } or { ok=false, error }.
function M.claim(player, mailId)
    local username = player:getUsername()
    local o = owner(username, false)
    local entry = o and type(mailId) == "string" and o.entries[mailId] or nil
    if not entry then return { ok = false, error = "unknown_mail" } end
    if entry.state ~= "ready" and entry.state ~= "claiming" then return { ok = false, error = "already_claimed" } end
    local ms = EC.now()
    entry.state = "claiming"
    local claimSeq = S.nextSeq()
    local ok, err = deliver(player, entry, claimSeq)
    if not ok then
        entry.state = "ready"
        return { ok = false, error = err }
    end
    local p = playerData(player)
    addWitness(p, mailId, md.meta.epoch, claimSeq)
    transmit(player)
    settle(o, entry, "claimed", ms)
    entry.claimSeq = claimSeq
    X.emit("mail.claimed", { mailId = mailId, username = username, item = entry.item, qty = entry.qty, txId = entry.txId, mailKind = entry.kind })
    return { ok = true, mailId = mailId, item = entry.item, qty = entry.qty }
end

-- ---------- login reconciliation (rule three) ----------

local reconcileOuts   -- rows 4-6 (list-out), defined below

function M.reconcile(player)
    local username = player:getUsername()
    local o = owner(username, false)
    local inv = player:getInventory()
    if not inv then return end
    local p = playerData(player)
    local stamped = scanStamped(inv)
    local changed = false
    if o then
        for mailId, entry in pairs(o.entries) do
            local witness = p.claims[mailId]
            local have = stamped[mailId]
            if entry.state == "claimed" and not witness and not have then
                -- player save predates the claim: the item never became durable, hand it over again
                local claimSeq = S.nextSeq()
                local ok, err = deliver(player, entry, claimSeq)
                if ok then
                    addWitness(p, mailId, md.meta.epoch, claimSeq)
                    entry.claimSeq = claimSeq
                    entry.claimedAt = EC.now()
                    anomaly(username, mailId, "redelivered")
                else
                    reopen(o, entry)
                    anomaly(username, mailId, "requeued", { reason = err })
                end
                changed = true
            elseif (entry.state == "ready" or entry.state == "claiming") and (witness or have) then
                -- player save is newer than the world save: the item is already there
                settle(o, entry, "claimed", EC.now())
                anomaly(username, mailId, "mark-claimed")
                changed = true
            end
        end
    end
    for mailId, rec in pairs(stamped) do
        if not (o and o.entries[mailId]) then
            local st = rec.stamp
            if S.isRolledBack(st.epoch, tonumber(st.seq) or 0) then
                -- the claim (and the purchase before it) rolled back with the world: money is back
                for _, r in ipairs(rec.items) do
                    pcall(function()
                        r.container:Remove(r.item)
                        sendRemoveItemFromContainer(r.container, r.item)
                    end)
                end
                p.claims[mailId] = nil
                anomaly(username, mailId, "removed-rolled-back", { txId = st.txId, count = #rec.items })
                changed = true
            end
        end
    end
    for mailId in pairs(p.claims) do
        if not (o and o.entries[mailId]) and not stamped[mailId] then
            p.claims[mailId] = nil
            changed = true
        end
    end
    if reconcileOuts(player, p, inv) then changed = true end
    if changed then transmit(player) end
end

-- ---------- login reconciliation of list-out (rule three rows 4-6) ----------

-- pendingOuts[listingId] = { itemIds (itemId = the first), qty, snapshot, price, seq, epoch, at }.
-- Cleared only here (or by an eviction): a listing is durable once it came from an earlier
-- epoch's save. A lot counts as "still in the backpack" when any of its items is.
reconcileOuts = function(player, p, inv)
    local Mk = S.Market
    if not Mk then return false end
    local username = player:getUsername()
    local changed = false
    for id, pend in pairs(p.pendingOuts) do
        local hasListing = Mk.hasListing(id)
        local originals = {}
        for _, itemId in ipairs(type(pend.itemIds) == "table" and pend.itemIds or { pend.itemId }) do
            pcall(function()
                local found = inv:getItemWithID(itemId)
                if found then originals[#originals + 1] = found end
            end)
        end
        local original = originals[1]
        local durable = pend.epoch ~= md.meta.epoch and not S.isRolledBack(pend.epoch, tonumber(pend.seq) or 0)
        if original and hasListing then
            -- row 6: the world has the listing, the (older) player save still has the item: the
            -- listing is authoritative, the original goes
            pcall(function()
                for _, o in ipairs(originals) do
                    inv:Remove(o)
                    sendRemoveItemFromContainer(inv, o)
                end
            end)
            anomaly(username, id, "removed-listed-original", { itemId = pend.itemId, qty = #originals })
            if durable then p.pendingOuts[id] = nil end
            changed = true
        elseif original and not hasListing then
            -- row 5: crashed before the removal (or the listing rolled back with the world while
            -- the player save still has the item): nothing left the backpack, forget the op
            p.pendingOuts[id] = nil
            anomaly(username, id, "pending-cleared-item-present")
            changed = true
        elseif not original and not hasListing then
            if S.isRolledBack(pend.epoch, tonumber(pend.seq) or 0) then
                -- row 4: the world rolled back below the listing while the player save already lost
                -- the item: rebuild the listing from the pending snapshot, never reuse the seq
                S.bumpSeq(tonumber(pend.seq) or 0)
                if Mk.restoreFromPending(username, id, pend) then
                    -- the pending now guards the rebuilt listing: durability is judged from here
                    pend.epoch = md.meta.epoch
                    pend.seq = S.nextSeq()
                    anomaly(username, id, "listing-restored", { price = pend.price })
                else
                    anomaly(username, id, "listing-restore-failed")
                    p.pendingOuts[id] = nil
                end
            else
                -- durable and gone = sold, cancelled, expired or delisted: the op completed
                p.pendingOuts[id] = nil
            end
            changed = true
        elseif durable then
            -- listing present and durable, item gone: the op completed
            p.pendingOuts[id] = nil
            changed = true
        end
    end
    return changed
end

-- ---------- death (rule five, part one) ----------

-- Rule five: the dead character's modData is gone with the corpse, but its pendingOuts are
-- still needed to rebuild listings after a rollback; keep them in memory until the next
-- character exists (OnNewGame) and write them into that one (spec 19.7 rule five, part two).
local carryOver = {}

function M.onDeath(character)
    if not md then return end
    local ok, username = pcall(function() return character:getUsername() end)
    if not ok or type(username) ~= "string" then return end
    local okData, data = pcall(function() return character:getModData()[EC.PLAYER_MODDATA_KEY] end)
    if okData and type(data) == "table" and type(data.pendingOuts) == "table" then
        local copy, n = {}, 0
        for id, pend in pairs(data.pendingOuts) do copy[id] = pend n = n + 1 end
        if n > 0 then
            carryOver[username] = copy
            X.emit("player.died", { username = username, pendingOuts = n })
        end
    end
    local o = owner(username, false)
    if not o then return end
    local n = 0
    for _, entry in pairs(o.entries) do
        if entry.state == "claimed" then
            entry.state = "settled"
            n = n + 1
        end
    end
    if n > 0 then
        X.emit("mailbox.settled", { username = username, count = n })
    end
end

function M.onNewGame(player)
    local ok, username = pcall(function() return player:getUsername() end)
    if not ok or type(username) ~= "string" then return end
    local pending = carryOver[username]
    if not pending then return end
    carryOver[username] = nil
    local p = playerData(player)
    for id, pend in pairs(pending) do p.pendingOuts[id] = pend end
    transmit(player)
end

-- ---------- retention ----------

-- ponytail: walks every owner once a minute; index by claimedAt if thousands of owners hurt.
function M.onTick()
    if not md then return end
    local ms = EC.now()
    if ms - lastPrune < M.PRUNE_EVERY_MS then return end
    lastPrune = ms
    for username, o in pairs(md.mailbox.byOwner) do
        local dead = {}
        local left = 0
        for id, e in pairs(o.entries) do
            if (e.state == "claimed" or e.state == "settled") and ms - (e.claimedAt or e.at or 0) > M.CLAIMED_TTL_MS then
                dead[#dead + 1] = id
            else
                left = left + 1
            end
        end
        for _, id in ipairs(dead) do o.entries[id] = nil end
        if left == 0 then md.mailbox.byOwner[username] = nil end
    end
end

-- ---------- commands ----------

S.handlers["mail.list"] = function(player, args)
    local username = player:getUsername()
    S.reply(player, "mail.list", { entries = M.list(username), unclaimed = M.unclaimed(username), atTerminal = T.near(player) })
end

S.handlers["mail.claim"] = function(player, args)
    local res
    if not T.near(player) then
        res = { ok = false, error = "not_at_terminal" }
    else
        res = M.claim(player, type(args) == "table" and args.mailId or nil)
    end
    res.requestId = type(args) == "table" and args.requestId or nil
    local username = player:getUsername()
    res.entries = M.list(username)
    res.unclaimed = M.unclaimed(username)
    S.reply(player, "mail.claim", res)
end

-- The client's first command after login is `hello`: reconcile right there (A18 shape).
local prevHello = S.handlers.hello
S.handlers.hello = function(player, args)
    prevHello(player, args)
    local ok, err = pcall(M.reconcile, player)
    if not ok then EC.log("mailbox reconcile failed for " .. tostring(player:getUsername()) .. ": " .. tostring(err)) end
end

function M.init(root)
    md = root
    md.mailbox = md.mailbox or { byOwner = {}, unclaimed = 0 }
    lastPrune = 0
end

S.Mailbox = M
S.onInit(M.init)
Events.OnTickEvenPaused.Add(M.onTick)
Events.OnCharacterDeath.Add(M.onDeath)
Events.OnNewGame.Add(M.onNewGame)
return M
