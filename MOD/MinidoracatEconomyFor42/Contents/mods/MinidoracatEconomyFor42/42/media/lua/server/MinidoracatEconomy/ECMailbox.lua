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
-- A letter is built whole before anything is handed over (M.prepare, reused by M.claim): a copy
-- the server cannot create costs the buyer nothing, and a copy it cannot weigh is refused before
-- any money moves instead of being weighed as zero. A failed handover takes back every object of
-- that attempt by identity and then reads the container again - a call that did not throw is not
-- proof of anything - and what the container says is what was delivered: everything back = the
-- entry stays `ready`, everything still in there = a plain `claimed`, and part of it stuck in the
-- backpack is the exception the operator approved (19, 2026-09-11): that confirmed subset is
-- re-stamped onto its own `claimed` child letter (same claim seq, its own witness) and the parent
-- keeps only the rest as `ready`. Nothing is ever decided by "the player relogged" or "the player
-- died": what was delivered is what this server saw in the container at that moment. Nothing here
-- is network-atomic: the durable pair is the item stamp plus the claim witness, and the login
-- reconcile is the convergence.
-- Death (rule five, part one): every `claimed` entry of that username becomes `settled` and is
-- never redelivered - the items are on the corpse. A `ready` entry (the remainder of a split
-- included) is world state and survives the death untouched.
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
if not MinidoracatEconomy or not MinidoracatEconomy.Recovery then
    require "MinidoracatEconomy/ECRecovery"
end
if not MinidoracatEconomy or not MinidoracatEconomy.RecoveryJournal then
    require "MinidoracatEconomy/ECRecoveryJournal"
end
local EC = MinidoracatEconomy
local S = EC and EC.Server
local L = EC and EC.Ledger
local X = EC and EC.Export
local T = EC and EC.Terminal
local R = EC and EC.Recovery
if not S or not S.AUTHORITY or not L or not X or not T or not R then
    return
end

EC.Mailbox = EC.Mailbox or {}
local M = EC.Mailbox

-- per-account slots come from the sandbox (MailboxPerAccount, default 50): M.capacity()
M.GLOBAL_MAX = 10000         -- unclaimed entries server-wide
M.ITEMS_MAX = 100            -- items per entry
M.CLAIMED_TTL_MS = 24 * 3600000
M.WITNESS_MAX = 64           -- claim witnesses kept per player; a split child takes one of these
M.LIST_MAX = 60
M.PRUNE_EVERY_MS = 60000
M.CLAIM_ALL_IDS_MAX = 60      -- ids one mail.claimAll may carry (the client's page is LIST_MAX)
M.CLAIM_ALL_ENTRIES_MAX = 20  -- entries looked at per call
M.CLAIM_ALL_ITEMS_MAX = 200  -- items prepared per call (a letter that failed spent its share too)

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

-- One letter by owner and id, for the recovery core: it marks the letters a committed transfer
-- consumed and reads their state when it judges the source of a unit. The live entry, not a
-- copy - the caller writes on it.
function M.entryOf(username, mailId)
    local o = owner(username, false)
    return o and type(mailId) == "string" and o.entries[mailId] or nil
end

-- One letter by id when the holder is not known. A generation zero delivery stamp never carried
-- an owner, so the recovery core cannot ask entryOf for it; only a globally unique id answers
-- here, because two accounts holding the same id is not an owner, it is an ambiguity (returned
-- as such, so a caller can refuse instead of picking one). The mailbox is bounded and the caller
-- caches per letter: this never runs per item.
function M.findEntry(mailId)
    if type(mailId) ~= "string" or mailId == "" then return nil, "missing" end
    local found = nil
    for _, o in pairs(md.mailbox.byOwner) do
        local entry = o.entries[mailId]
        if entry then
            if found then return nil, "ambiguous" end
            found = entry
        end
    end
    if not found then return nil, "missing" end
    return found
end

-- Slots per account (sandbox MailboxPerAccount). A slot is taken by an unclaimed mailbox entry
-- or by an active market listing (the listing turns into a mailbox entry when it comes back,
-- so a return never needs a free slot and the count never overshoots).
function M.capacity()
    return EC.sandbox("MailboxPerAccount", 50)
end

-- Held slots that are not mailbox entries: active market listings and active auctions. They are
-- counted apart (a screenshot of 1 waiting + 3 listings + 2 auctions is 6 of 50 held, not 6
-- letters), so the client can name the three kinds instead of one "listings" lump.
local function escrowCounts(username)
    local Mk, Au = S.Market, S.Auction
    local listings = (Mk and Mk.ownerCount) and Mk.ownerCount(username) or 0
    local auctions = (Au and Au.ownerCount) and Au.ownerCount(username) or 0
    return listings, auctions
end

function M.used(username)
    local listings, auctions = escrowCounts(username)
    return M.unclaimed(username) + listings + auctions
end

function M.hasFreeSlot(username)
    return M.used(username) < M.capacity() and md.mailbox.unclaimed < M.GLOBAL_MAX
end

-- What the client shows next to the mailbox count.
function M.usage(username)
    local listings, auctions = escrowCounts(username)
    local unclaimed = M.unclaimed(username)
    return { unclaimed = unclaimed, marketListings = listings, auctions = auctions,
        used = unclaimed + listings + auctions, capacity = M.capacity() }
end

-- fields = { kind, item, qty, txId, price?, snapshot?, listingId?, parentMailId?, units?, seller? }. A
-- snapshot entry rebuilds `qty` copies through ECCodec; without one the entry is `qty` fresh
-- items of `item` (system shop). Caller checked hasFreeSlot (or is a system return allowed past
-- the cap); this never fails.
-- `units` are the letter's unit tokens: one stable name per physical unit, minted here and kept
-- by that unit through every rebuild, redelivery and split. A native item id is a locator, not
-- an identity (Codec.rebuild mints new objects and an id can come back on another one), so the
-- token is what the recovery core matches on. A split child inherits the exact tokens of the
-- subset it took, which is why a rolled-back child can ask the parent for that very unit.
-- `seller` is the account on the other side of a real trade (the market listing's owner, the
-- auction's seller), written from the server's own record of the deal and from nowhere else. A
-- letter with no third party - a shop purchase, a return, anything written before this field -
-- simply has none: it is never guessed from a listing that is already gone.
function M.add(username, fields, restoredId)
    local o = owner(username, true)
    local id = restoredId or S.newId()
    if restoredId then
        if type(restoredId) ~= "string" or not EC.parseId(restoredId) then return nil, "recovery_unverified" end
        local existing = o.entries[id]
        if existing then
            if existing.item == fields.item and existing.listingId == fields.listingId then return existing end
            return nil, "recovery_conflict"
        end
    end
    local qty = math.max(0, tonumber(fields.qty) or 0)
    local units = {}
    if type(fields.units) == "table" then
        for _, t in ipairs(fields.units) do
            if type(t) == "string" then units[#units + 1] = t end
        end
    end
    for i = #units + 1, qty do units[i] = id .. "#" .. tostring(i) end
    local seller = type(fields.seller) == "string" and fields.seller ~= "" and fields.seller or nil
    local entry = {
        id = id, owner = username, kind = fields.kind, item = fields.item, qty = fields.qty,
        txId = fields.txId, price = fields.price, currency = fields.currency, seller = seller,
        -- every letter this build writes is a current-schema letter, including one whose
        -- currency is not known (a return from a held record): without the mark, the next read
        -- would take that missing currency for the single-currency era and invent one
        tradeSchema = L.TRADE_SCHEMA,
        snapshot = fields.snapshot, listingId = fields.listingId,
        parentMailId = fields.parentMailId, units = units, state = "ready", at = EC.now(),
    }
    o.entries[id] = entry
    o.unclaimed = o.unclaimed + 1
    md.mailbox.unclaimed = md.mailbox.unclaimed + 1
    return entry
end

-- The letter's unit tokens. A letter written before tokens existed gets them minted here,
-- appended and never renumbered: old data keeps its meaning and gains a name.
local function letterUnits(entry)
    if type(entry.units) ~= "table" then entry.units = {} end
    local qty = math.max(0, tonumber(entry.qty) or 0)
    for i = #entry.units + 1, qty do entry.units[i] = entry.id .. "#" .. tostring(i) end
    return entry.units
end

-- The tokens this letter still owes: its own, minus the ones a committed transfer already took
-- out of it (entry.outUnits[token], written by the recovery core when an operation commits).
-- This is the exact remainder a redelivery hands over - never a count.
local function availableUnits(entry)
    local out = {}
    local taken = type(entry.outUnits) == "table" and entry.outUnits or nil
    for _, t in ipairs(letterUnits(entry)) do
        if not (taken and taken[t] ~= nil) then out[#out + 1] = t end
    end
    return out
end

-- The states that still hold a slot.
local function counted(state)
    return state == "ready" or state == "claiming"
end

local function settle(o, entry, state, ms)
    if counted(entry.state) then
        o.unclaimed = math.max(0, o.unclaimed - 1)
        md.mailbox.unclaimed = math.max(0, md.mailbox.unclaimed - 1)
    end
    entry.state = state
    entry.claimedAt = ms
end

local function reopen(o, entry)
    if not counted(entry.state) then
        o.unclaimed = o.unclaimed + 1
        md.mailbox.unclaimed = md.mailbox.unclaimed + 1
    end
    entry.state = "ready"
    entry.qty = #availableUnits(entry)
    entry.claimedAt = nil
end

local function acceptClaimProof(username, mailId, token, ms)
    local o = owner(username, false)
    local entry = o and o.entries[mailId] or nil
    if not entry or not counted(entry.state) then return false end
    if token then
        local found = false
        for _, unit in ipairs(letterUnits(entry)) do if unit == token then found = true; break end end
        if not found or (entry.outUnits and entry.outUnits[token]) then return false end
    end
    settle(o, entry, "claimed", ms)
    return true
end

-- Entries still holding a slot, newest first (client view). `weight` is the script estimate of
-- one copy, so the client can size the delivery before asking for it. Every listed letter is
-- claimable: a handover either delivers it, leaves it exactly where it was, or splits off the
-- part this server confirmed into its own claimed child (see deliver). There is no locked row.
function M.list(username)
    local out = {}
    local o = owner(username, false)
    if not o then return out end
    for _, e in pairs(o.entries) do
        if counted(e.state) then
            out[#out + 1] = { id = e.id, kind = e.kind, item = e.item, qty = #availableUnits(e), price = e.price,
                currency = e.currency, seller = e.seller, txId = e.txId, at = e.at,
                state = "ready", claimable = true, weight = M.scriptWeight(e.item) }
        end
    end
    EC.sortSafe(out, function(a, b) return a.at > b.at end)
    while #out > M.LIST_MAX do table.remove(out) end
    return out
end

-- ---------- player side (witness + stamps) ----------

function M.findTopLevel(inv, itemId)
    local found = nil
    pcall(function() found = inv:getItemWithID(itemId) end)
    if not found then return nil end
    -- top level only: the item must be directly in the backpack (bags are not scanned by the picker)
    local ok, items = pcall(function() return inv:getItems() end)
    if not ok or not items then return nil end
    for i = 0, items:size() - 1 do
        if items:get(i) == found then return found end
    end
    return nil
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

-- A weight this server cannot read is nil, never 0: a zero makes any lot "fit", and a letter
-- would then be paid for and pushed into a backpack on an invented number. A NaN or a negative
-- is the same non-answer as a throw.
local function finiteWeight(w)
    return type(w) == "number" and w >= 0 and w < math.huge
end

function M.itemWeight(item)
    local ok, w = pcall(function() return item:getUnequippedWeight() end)
    if ok and finiteWeight(w) then return w end
    local ok2, w2 = pcall(function() return item:getActualWeight() end)
    if ok2 and finiteWeight(w2) then return w2 end
    return nil
end

-- Weight of one copy, cached per fullType: this is the estimate the mailbox rows, the shop
-- catalog and the market/auction views carry, so a view never builds items. The script knows it
-- (Item.getActualWeight, Item.java:533-535); when it does not, one instance is built once for
-- this fullType and weighed. `false` in the cache = no usable weight (nil to callers).
local scriptWeights = {}
function M.scriptWeight(fullType)
    if type(fullType) ~= "string" or fullType == "" then return nil end
    local cached = scriptWeights[fullType]
    if cached ~= nil then return cached ~= false and cached or nil end
    local w = nil
    pcall(function()
        local script = ScriptManager.instance:FindItem(fullType)
        if script then w = script:getActualWeight() end
    end)
    if not finiteWeight(w) then
        local sample = nil
        pcall(function() sample = instanceItem(fullType) end)
        w = (sample and M.itemWeight(sample)) or false
    end
    scriptWeights[fullType] = w
    return w ~= false and w or nil
end

-- One copy of the letter: the snapshot through ECCodec, a plain SKU through instanceItem.
-- Returns item or nil, error. Nothing but the returned item is touched.
local function build(entry)
    if type(entry.snapshot) == "table" and S.Codec then
        return S.Codec.rebuild(entry.snapshot)
    end
    local item = instanceItem(entry.item)
    if not item then return nil, "item_unavailable" end
    return item
end

-- entryLike = { item, qty, snapshot? }: build the whole letter and weigh it without touching
-- the inventory, the mailbox, the seq or the witness. Returns prepared or nil, error.
-- A prepared letter is private to the synchronous handler that made it: the items are detached
-- engine objects, they are not state, and they are never cached or carried across a request.
-- A purchase prepares before it debits, so an unbuildable letter costs nothing and the same
-- objects are the ones handed over (no second build). An object this server cannot weigh, and a
-- room test the container refuses to answer, are `item_unavailable` right here - before the
-- debit - instead of a `fits` that was decided from a guessed zero.
function M.prepare(player, entryLike)
    if type(entryLike) ~= "table" then return nil, "invalid_args" end
    local inv = player:getInventory()
    if not inv then return nil, "no_inventory" end
    local n = math.max(1, math.min(M.ITEMS_MAX, tonumber(entryLike.qty) or 1))
    local items, total = {}, 0
    for i = 1, n do
        local ok, item, err = pcall(build, entryLike)
        if not ok then
            EC.log("mailbox prepare " .. tostring(entryLike.item) .. " failed: " .. tostring(item))
            return nil, "item_unavailable"
        end
        if not item then return nil, err or "item_unavailable" end
        local w = M.itemWeight(item)
        if w == nil then
            EC.log("mailbox prepare " .. tostring(entryLike.item) .. ": no usable weight")
            return nil, "item_unavailable"
        end
        items[i] = item
        total = total + w
    end
    local okRoom, room = pcall(function() return inv:hasRoomFor(player, total) end)
    if not okRoom or type(room) ~= "boolean" then
        EC.log("mailbox prepare " .. tostring(entryLike.item) .. ": hasRoomFor gave no answer")
        return nil, "item_unavailable"
    end
    return { item = entryLike.item, qty = n, items = items, totalWeight = total, fits = room }
end

-- Native identity membership is the postcondition (ItemContainer.java:630-632). Only the
-- attempted objects are considered; an id collision must never remove the older object.
local function removeAll(inv, items)
    local kept = {}
    for _, obj in ipairs(items) do
        if inv:contains(obj) then
            pcall(function() inv:Remove(obj) end)
            if inv:contains(obj) then
                kept[#kept + 1] = obj
            else
                sendRemoveItemFromContainer(inv, obj)
            end
        end
    end
    return kept
end

local function sendItems(inv, items)
    local list = ArrayList.new()
    for _, item in ipairs(items) do list:add(item) end
    local ok, err = pcall(sendAddItemsToContainer, inv, list)
    if not ok then EC.log("mailbox item notification failed: " .. tostring(err)) end
end

-- Stamped items found by the recovery scan (they carry their own container: bags too).
local function removeStamped(rec)
    for _, r in ipairs(rec.items) do
        pcall(function()
            r.container:Remove(r.item)
            sendRemoveItemFromContainer(r.container, r.item)
        end)
    end
end

-- The delivery stamp (protocol 2). It is the only thing that later lets a list-out say where a
-- unit came from: the letter and its owner, the parent letter when this is a split delivery, the
-- record the letter came back from, and the epoch/seq of this claim so a rollback can be judged.
-- A stamp missing any of it is read as "legacy" and is never taken for a source-less native item.
local function stampFor(entry, claimSeq, unit)
    return { mailId = entry.id, unit = unit, txId = entry.txId, epoch = md.meta.epoch, seq = claimSeq,
        owner = entry.owner, parentMailId = entry.parentMailId, srcRef = entry.listingId,
        proto = R.PROTOCOL }
end

-- Update the existing item in its actual client container (SyncItemModDataPacket.java:32-60).
local function syncStamp(player, item)
    local ok, err = pcall(syncItemModData, player, item)
    if not ok then EC.log("recovery item metadata notification failed: " .. tostring(err)) end
end

-- Hand the letter over. The whole letter is built and weighed before anything is added, AddItem
-- has to give back the very object it was handed, and the container itself is what says whether
-- the objects arrived. Returns one of:
--   { ok = true, qty }              every object of the attempt is confirmed in the inventory
--   { ok = false, error }           nothing of this attempt is in the inventory any more
--   { ok = false, error, kept }     part of it could not be taken back: exactly those objects
--                                   are in the backpack, and the caller settles that subset
-- sendAddItemsToContainer only ships the packet (A8): the durable half is the item stamp plus
-- the claim witness, and the login reconcile is what converges. This is not a network-atomic
-- handover and does not pretend to be one.
local function deliver(player, entry, claimSeq, prepared)
    local inv = player:getInventory()
    if not inv then return { ok = false, error = "no_inventory" } end
    local tokens = availableUnits(entry)
    local n = math.max(1, math.min(M.ITEMS_MAX, entry.qty or 1))
    if #tokens < 1 then return { ok = false, error = "delivery_failed" } end
    if #tokens < n then n = #tokens end
    local letter = prepared
    if letter and (letter.used or letter.qty ~= n or letter.item ~= entry.item or #letter.items ~= n) then letter = nil end
    if not letter then
        local err
        letter, err = M.prepare(player, { item = entry.item, snapshot = entry.snapshot, qty = n })
        if not letter then return { ok = false, error = err or "item_unavailable" } end
    end
    letter.used = true
    local okRoom, room = pcall(function() return inv:hasRoomFor(player, letter.totalWeight) end)
    if not okRoom or room ~= true then return { ok = false, error = "backpack_full" } end
    local items = letter.items
    local list = ArrayList.new()
    local ok, perr = pcall(function()
        for i = 1, n do
            items[i]:getModData()[EC.PLAYER_MODDATA_KEY] = stampFor(entry, claimSeq, tokens[i])
            if inv:AddItem(items[i]) ~= items[i] then error("AddItem gave back another object") end
            list:add(items[i])
        end
        sendAddItemsToContainer(inv, list)
    end)
    if ok then
        local complete = true
        for _, item in ipairs(items) do
            if not inv:contains(item) then complete = false; break end
        end
        if complete then return { ok = true, qty = n } end
    end
    EC.log("mailbox deliver " .. tostring(entry.id) .. " incomplete: " .. tostring(perr))
    local kept = removeAll(inv, items)
    if #kept == 0 then return { ok = false, error = "delivery_failed" } end
    if #kept == n then
        sendItems(inv, kept)
        return { ok = true, qty = n, forced = true }
    end
    return { ok = false, error = "delivery_partial", kept = kept }
end

local function anomaly(username, mailId, resolution, extra)
    local fields = { kind = "mailbox", username = username, mailId = mailId, resolution = resolution }
    for k, v in pairs(extra or {}) do fields[k] = v end
    X.emit("ledger.anomaly", fields)
    EC.log("mailbox reconcile " .. username .. " " .. mailId .. " -> " .. resolution)
end

-- ---------- claim-in (rule two) ----------

-- The exception the operator approved (19, 2026-09-11). A handover failed and left part of the
-- letter in the backpack where the take-back could not reach it. That confirmed subset is what
-- was delivered, so it becomes its own `claimed` child letter: the kept objects are re-stamped
-- onto the child's id, the child gets one witness of its own under the same claim seq, and the
-- parent keeps only the rest and goes back to `ready`. The subset is settled from objects this
-- server just saw in the container - never from "the player relogged" or "the player died".
-- A claimed entry holds no slot, so the child costs the account nothing and the claimed TTL
-- prunes it. Re-stamping uses the native modData table, not a fallible external write
-- (InventoryItem.java:433-437); only confirmed objects receive a witness.
local function splitDelivered(player, o, entry, claimSeq, kept, ms, inPlace)
    -- The confirmed objects carry the unit tokens they were handed. The child takes those exact
    -- names with it and the parent stops owing them, so a rollback that loses the child asks the
    -- parent for that very unit instead of guessing from a count.
    local tokens, byToken, inherited = {}, {}, true
    for i, obj in ipairs(kept) do
        local stamp = R.stampOf(obj)
        local t = stamp and type(stamp.unit) == "string" and stamp.unit or nil
        tokens[i] = t
        if t then byToken[t] = true else inherited = false end
    end
    local child = M.add(entry.owner, { kind = entry.kind, item = entry.item, qty = #kept,
        txId = entry.txId, price = entry.price, currency = entry.currency, seller = entry.seller,
        snapshot = entry.snapshot, listingId = entry.listingId,
        parentMailId = entry.id, units = inherited and tokens or nil })
    for i, obj in ipairs(kept) do
        obj:getModData()[EC.PLAYER_MODDATA_KEY] = stampFor(child, claimSeq, child.units[i])
    end
    local p = R.playerData(player)
    addWitness(p, child.id, md.meta.epoch, claimSeq)
    settle(o, child, "claimed", ms)
    child.claimSeq = claimSeq
    R.transmit(player)
    local left = {}
    for _, t in ipairs(letterUnits(entry)) do
        if not byToken[t] then left[#left + 1] = t end
    end
    entry.units, entry.qty = left, #left
    entry.qty = #availableUnits(entry)
    reopen(o, entry)
    if inPlace then
        for _, item in ipairs(kept) do syncStamp(player, item) end
    else
        sendItems(player:getInventory(), kept)
    end
    return child
end

-- Returns { ok = true, mailId, item, qty, deliveredQty, remainingQty } or
-- { ok = false, error, deliveredQty, remainingQty, childMailId? }.
-- Item counts accompany, and never replace, the boolean delivery result.
-- `prepared` is an M.prepare result for this same letter made earlier in the same synchronous
-- handler (a purchase prepares before it debits): its objects are reused instead of built twice.
function M.claim(player, mailId, prepared)
    local username = player:getUsername()
    local o = owner(username, false)
    local entry = o and type(mailId) == "string" and o.entries[mailId] or nil
    if not entry then return { ok = false, error = "unknown_mail" } end
    if entry.state ~= "ready" and entry.state ~= "claiming" then return { ok = false, error = "already_claimed" } end
    local ms = EC.now()
    local total = #availableUnits(entry)
    if total < 1 then return { ok = false, error = "already_claimed" } end
    entry.qty = total
    entry.state = "claiming"
    local claimSeq = S.nextSeq()
    local res = deliver(player, entry, claimSeq, prepared)
    if res.ok then
        local p = R.playerData(player)
        addWitness(p, mailId, md.meta.epoch, claimSeq)
        R.transmit(player)
        settle(o, entry, "claimed", ms)
        entry.claimSeq = claimSeq
        if res.forced then anomaly(username, mailId, "delivery-kept-all", { qty = total }) end
        X.emit("mail.claimed", { mailId = mailId, username = username, item = entry.item, qty = entry.qty,
            price = entry.price, currency = entry.currency, txId = entry.txId, mailKind = entry.kind })
        local handedOver = tonumber(res.qty) or total
        return { ok = true, mailId = mailId, item = entry.item, qty = entry.qty,
            deliveredQty = handedOver, remainingQty = math.max(0, total - handedOver) }
    end
    if res.kept then
        local child = splitDelivered(player, o, entry, claimSeq, res.kept, ms)
        X.emit("mail.claimed", { mailId = child.id, username = username, item = child.item, qty = child.qty,
            price = child.price, currency = child.currency, txId = child.txId, mailKind = child.kind, partialOf = mailId })
        anomaly(username, mailId, "delivery-partial", { child = child.id, delivered = child.qty, remaining = entry.qty })
        return { ok = false, error = "delivery_partial", mailId = mailId, childMailId = child.id,
            item = entry.item, qty = total, deliveredQty = child.qty, remainingQty = entry.qty }
    end
    entry.state = "ready"
    return { ok = false, error = res.error, deliveredQty = 0, remainingQty = total }
end

-- Copy a claim result onto a reply or a notice. `delivered` stays the boolean it always was and
-- the item counts ride beside it, so nothing has to read a number out of a flag. claim = nil is
-- "no handover was attempted at all" (parked in the mailbox, winner not at a terminal).
function M.deliveryFields(out, claim, qty)
    if claim == nil then
        out.delivered, out.deliveredQty, out.remainingQty = false, 0, qty
        return out
    end
    out.delivered = claim.ok == true
    out.deliveryError = (not claim.ok) and claim.error or nil
    out.deliveredQty = claim.deliveredQty
    out.remainingQty = claim.remainingQty
    out.childMailId = claim.childMailId
    return out
end

-- One bounded synchronous chunk of the ids the client fixed when its batch started. A normal
-- claim takes the whole envelope (never a part of it); one that does not fit is skipped with its
-- own error and the next is still tried, and so is one whose handover ended in the partial
-- exception - only the ids that were never looked at come back as `more`. At most
-- CLAIM_ALL_ENTRIES_MAX entries are looked at and CLAIM_ALL_ITEMS_MAX items are *prepared* per
-- call (a letter that failed spent its share of that budget all the same), and the first
-- claimable entry is always processed (ITEMS_MAX <= CLAIM_ALL_ITEMS_MAX), so a big letter can
-- never starve behind the budget. Failed ids are not among `more`, so resending the same id list
-- can only ever collect already_claimed and never swallows a letter that arrived since.
-- The id list is the whole state: no server-side job and no requestId cache.
-- Freeze policy is the single claim's: claiming is item movement, not money, and a frozen
-- account may still empty its mailbox (ECLedger gates the money side).
-- Returns { ok=true, results, more } or { ok=false, error }.
function M.claimAll(player, mailIds)
    if type(mailIds) ~= "table" then return { ok = false, error = "invalid_args" } end
    local n = #mailIds
    if n < 1 or n > M.CLAIM_ALL_IDS_MAX or EC.countKeys(mailIds) ~= n then return { ok = false, error = "invalid_args" } end
    local seen = {}
    for i = 1, n do
        local id = mailIds[i]
        if type(id) ~= "string" or id == "" or #id > 96 or seen[id] then return { ok = false, error = "invalid_args" } end
        seen[id] = true
    end
    local username = player:getUsername()
    local o = owner(username, false)
    local results, items, checks, more = {}, 0, 0, false
    for i = 1, n do
        local mailId = mailIds[i]
        if checks >= M.CLAIM_ALL_ENTRIES_MAX then more = true break end
        local entry = o and o.entries[mailId] or nil
        local ready = entry ~= nil and (entry.state == "ready" or entry.state == "claiming")
        local qty = entry and math.max(1, math.min(M.ITEMS_MAX, entry.qty or 1)) or 0
        if ready and items > 0 and items + qty > M.CLAIM_ALL_ITEMS_MAX then more = true break end
        checks = checks + 1
        if not entry then
            results[#results + 1] = { mailId = mailId, ok = false, error = "unknown_mail" }
        elseif not ready then
            results[#results + 1] = { mailId = mailId, ok = false, error = "already_claimed" }
        else
            items = items + qty
            local res = M.claim(player, mailId)
            results[#results + 1] = { mailId = mailId, ok = res.ok == true, error = (not res.ok) and res.error or nil,
                item = res.item, qty = res.qty, deliveredQty = res.deliveredQty, remainingQty = res.remainingQty,
                childMailId = res.childMailId }
        end
    end
    return { ok = true, results = results, more = more }
end

-- ---------- list-out protocol (public API; contract recovery.publicApi) ----------

-- The three live list-outs (market listing, auction, system buyback) and every recovery path go
-- through these five calls; ECRecovery holds the state behind them. A live operation runs
-- beginOut -> remove the objects -> commit the listing / auction / mint -> finishOut, and
-- abortOut on any failure after the removal. Every refusal belongs to beginOut, before an object
-- or a coin has moved: a validation that fires after the commit is not a validation. A refusal
-- also carries a third return value - the detail of the one unit it was refused on (reason,
-- which item, which letter or operation, and the single next step) - which the callers put into
-- their reply as recoveryDetail. The first two return values are unchanged.
function M.beginOut(player, id, items, rec)
    return R.beginOut(player, id, items, rec)
end

function M.finishOut(username, id, rec, kind, ref)
    return R.finishOut(username, id, rec, kind, ref)
end

function M.abortOut(player, id, items)
    return R.abortOut(player, id, items)
end

function M.takeOut(player, id, items)
    local inv = player:getInventory()
    local ok, err = pcall(function()
        for _, item in ipairs(items) do
            inv:Remove(item)
            if inv:contains(item) then error("item removal was not confirmed") end
            sendRemoveItemFromContainer(inv, item)
        end
    end)
    if ok then return true end
    EC.log("list-out removal failed: " .. tostring(err))
    local returned = R.abortOut(player, id, items)
    return false, returned and "delivery_failed" or "recovery_pending"
end

-- True once the world holds a committed transfer receipt for this operation - including one that
-- has since been sold, cancelled, expired or delisted. This is what stops an older player save
-- from resurrecting a finished operation, however many restarts happen in between.
function M.hasOut(id)
    return R.hasOut(id)
end

-- Read-only (admin lookup and the owner's own notice): records waiting for reconciliation.
function M.recoveryStatus(username)
    return R.status(username)
end

-- ---------- login reconciliation (rule three) ----------

local reconcileOuts   -- rows 4-6 (list-out), defined below

-- Evidence first, decisions second. One inventory walk, the account's transfer receipts and its
-- letters are all read before anything is changed: a reconcile that cleaned up as it went would
-- be judging a world it had just edited. Every branch below either converges on proof or leaves
-- the record exactly as it found it and counts it (R.hold) - nothing is guessed into existence
-- and nothing unproven is deleted.
--
local function reconcileMissingLetters(username, p, scan, blockedLetters)
    local changed = false
    for mailId, stamped in pairs(scan.stamped) do
        local stamp = stamped.stamp
        -- The letter is looked for wherever it is. A generation zero stamp never carried an
        -- owner and an object this pass adopted now carries the letter's, so asking only the
        -- holder can miss a letter that is plainly in the world - and its objects are then not
        -- rolled-back leftovers at all. An id two accounts hold is an ambiguity, and an
        -- ambiguity is never a licence to delete.
        local source = M.entryOf(stamp.owner or username, mailId)
        local why = nil
        if not source then source, why = M.findEntry(mailId) end
        if not source and why ~= "ambiguous" and not blockedLetters[mailId] then
            -- One letter id can be worn by objects from different claims of it: an old
            -- generation zero delivery whose branch was rolled back, and a current protocol 2
            -- delivery of the very same letter. The group's first stamp is not a verdict on all
            -- of them - judging the whole letter by it deletes the live objects because an old
            -- one happened to be scanned first. Each object is judged by the stamp it is
            -- actually wearing.
            --
            -- Generation zero objects are never removed here whatever their verdict says. Their
            -- letter is the one record that could still name them, the group record already says
            -- so, and removing one is an administrator's decision with a written reason - never
            -- a side effect of a login. Holding them per unit here would also stack one record
            -- per nail beside the group record that already covers them.
            local removed, dropped, unknownAlive = true, 0, false
            for _, row in ipairs(stamped.items) do
                local rowStamp = row.stamp
                local verdict = (rowStamp and rowStamp.durable == true) and "survived"
                    or R.verdict(rowStamp and rowStamp.epoch, tonumber(rowStamp and rowStamp.seq))
                if R.gen0Stamp(rowStamp) then
                    removed = false
                elseif verdict == "rolledback" then
                    local unit = rowStamp and rowStamp.unit or row.nativeId
                    if R.removeUnit(username, "unit:" .. mailId .. ":" .. tostring(unit), row,
                        { opId = mailId, unit = unit }) then dropped = dropped + 1
                    else removed = false end
                else
                    removed = false
                    -- "could not ask" counts as alive here: an unreadable source is not proof
                    -- that the letter behind this object is gone (report ER-10)
                    if verdict == "unknown" and R.sourceAlive(rowStamp and rowStamp.srcRef) ~= false then unknownAlive = true end
                end
            end
            if dropped > 0 then
                anomaly(username, mailId, "removed-rolled-back", { count = dropped, txId = stamp.txId })
                changed = true
                -- The witness only goes when the whole letter's objects are accounted for: one
                -- of them still standing here is one this login did not settle.
                if removed then
                    p.claims[mailId] = nil
                    R.resolveHold(username, "stamp:" .. mailId, "removed")
                end
            end
            if unknownAlive then
                R.hold(username, "stamp:" .. mailId, "claim_epoch_unknown", { mailId = mailId, srcRef = stamp.srcRef })
            end
        end
    end
    return changed
end

-- Returns true when the whole pass ran, or false plus "read_failed" when it could not read what
-- it had to judge (no inventory, or a walk that threw halfway). A caller that only checks pcall
-- would otherwise read "the backpack is unreadable, the account is held" as a completed
-- reconciliation and report it as a successful recheck.
function M.reconcile(player)
    local username = player:getUsername()
    local inv = player:getInventory()
    if not inv then
        R.hold(username, "inventory", "inventory_unreadable", {})
        S.reply(player, "recovery.status", R.status(username))
        return false, "read_failed"
    end
    local p, ms = R.playerData(player), EC.now()
    local scan = R.scanUnits(inv)
    if scan.failed then
        R.hold(username, "inventory", "inventory_unreadable", {})
        S.reply(player, "recovery.status", R.status(username))
        return false, "read_failed"
    end
    R.resolveHold(username, "inventory", "readable")
    for token in pairs(scan.duplicates) do
        R.hold(username, "duplicate:" .. token, "duplicate_unit", { unit = token })
    end
    local o = owner(username, false)
    local receipts, changed = R.ownerReceipts(username), false
    local protected, blockedLetters = {}, {}
    -- An older player may have no pending at all. Insure current commitments before changing that save.
    for _, receipt in ipairs(receipts) do
        if R.receiptVerdict(receipt) == "current" and not p.pendingOuts[receipt.id] then
            if type(receipt.replay) == "table" and EC.countKeys(p.pendingOuts) < R.PENDING_MAX then
                p.pendingOuts[receipt.id] = R.copyReplay(receipt.replay)
                changed = true
            else
                protected[receipt.id] = true
                R.hold(username, "receipt:" .. receipt.id, "replay_unavailable", { opId = receipt.id })
                for _, unit in ipairs(receipt.units or {}) do
                    if unit.m then blockedLetters[unit.m] = true end
                end
            end
        end
    end
    if changed then R.transmit(player) end
    -- Reattach rolled-back split units before a later parent witness settles its remainder.
    local remapped = false
    for mailId, stamped in pairs(scan.stamped) do
        local stamp = stamped.stamp
        local parent = stamp.parentMailId and M.entryOf(stamp.owner or username, stamp.parentMailId)
        if not M.entryOf(stamp.owner or username, mailId) and parent then
            local available, kept = {}, {}
            for _, token in ipairs(availableUnits(parent)) do available[token] = true end
            for _, row in ipairs(stamped.items) do
                local token = row.stamp and row.stamp.unit
                if token and available[token] and not scan.duplicates[token] then kept[#kept + 1] = row.item end
            end
            if #kept > 0 and parent.owner == username then
                local claimSeq = S.nextSeq()
                if counted(parent.state) then
                    splitDelivered(player, o, parent, claimSeq, kept, ms, true)
                else
                    for _, item in ipairs(kept) do
                        local token = R.stampOf(item).unit
                        item:getModData()[EC.PLAYER_MODDATA_KEY] = stampFor(parent, claimSeq, token)
                        syncStamp(player, item)
                    end
                end
                p.claims[mailId] = nil
                anomaly(username, mailId, "child-reattached", { parent = parent.id, qty = #kept })
                remapped, changed = true, true
            elseif #kept > 0 then
                blockedLetters[mailId] = true
                R.hold(username, "stamp:" .. mailId, "foreign_split_owner", { mailId = mailId, owner = parent.owner })
            end
        end
    end
    if remapped then
        R.transmit(player)
        scan = R.scanUnits(inv)
        if scan.failed then
            R.hold(username, "inventory", "inventory_unreadable", {})
            S.reply(player, "recovery.status", R.status(username))
            return false, "read_failed"
        end
    end
    -- Keep a proven verdict with its unit before the bounded epoch history forgets it.
    for _, row in pairs(scan.byToken) do
        local stamp = row.stamp
        if stamp and stamp.proto == R.PROTOCOL and stamp.durable ~= true
            and R.verdict(stamp.epoch, tonumber(stamp.seq)) == "survived" then
            stamp.durable = true
            syncStamp(player, row.item)
        end
    end
    -- The mail's existence proves its creation survived; its later claim need not have survived.
    if o then
        for mailId, entry in pairs(o.entries) do
            if not blockedLetters[mailId] and (p.claims[mailId] or scan.stamped[mailId]) then
                if acceptClaimProof(username, mailId, nil, ms) then
                    anomaly(username, mailId, "mark-claimed")
                    changed = true
                end
            end
        end
    end
    for _, pending in pairs(p.pendingOuts) do
        if type(pending) == "table" and pending.protocol == R.PROTOCOL and not pending.abortIncomplete
            and R.verdict(pending.epoch, tonumber(pending.seq)) ~= "unknown" then
            for _, origin in ipairs(pending.origins or {}) do
                if origin.src == "mail" and not blockedLetters[origin.mailId] then
                    local consumed, _, proof = R.consumer(origin)
                    if proof == "unreadable" then
                        blockedLetters[origin.mailId] = true
                    elseif not consumed and acceptClaimProof(origin.owner, origin.mailId, origin.unit, ms) then
                        anomaly(username, origin.mailId, "mark-claimed", { owner = origin.owner })
                        changed = true
                    end
                end
            end
        end
    end
    local outChanged, handled = reconcileOuts(player, p, scan, username)
    changed = outChanged or changed
    -- Generation zero (report #2 / #4). Delivery stamps written before unit tokens existed, and
    -- the protocol 2 tokens this server adopted them under. Both are cold paths over the letters
    -- this one scan already grouped: one source lookup per letter, never one per object.
    --   adopt  - the letter is there, claimed under this very claim seq, with an unissued slot:
    --            the object is named for good and the refusal an administrator was looking at is
    --            resolved against an observation.
    --   rebind - the world went back below an adoption while the object kept its token: the same
    --            token goes into the letter again - never recomputed from the rebuilt object's
    --            new engine id - together with the consumption a surviving receipt recorded, so
    --            availableUnits still subtracts what was transferred out.
    --   hold   - one record per letter carrying its ids and the reason. A source that is gone has
    --            no quantity and no owner to infer, and this server does not invent either.
    local legacyCtx = { letters = {}, scan = scan }
    for mailId, stamped in pairs(scan.stamped) do
        local named, failure, rebound = {}, nil, 0
        for _, row in ipairs(stamped.items) do
            -- An object this pass already removed is not a source of anything.
            local stamp = (not row.gone) and row.stamp or nil
            if R.gen0Stamp(stamp) then
                local origin = R.originOf(row.item)
                if origin and origin.gen0 then
                    local bound, info = R.adoptGen0(player, row.item, origin, legacyCtx)
                    if bound then
                        named[#named + 1] = bound.unit
                        row.stamp = R.stampOf(row.item)
                        -- Two objects naming one token is a duplicate, not a replacement. The
                        -- group check refuses a letter whose objects share an engine id before
                        -- anything is written, so this only ever guards the snapshot itself.
                        local worn = scan.byToken[bound.unit]
                        if worn ~= nil and worn ~= row then
                            worn.duplicate, row.duplicate = true, true
                            scan.duplicates[bound.unit] = true
                        else
                            scan.byToken[bound.unit] = row
                        end
                    else
                        failure = info
                    end
                end
            elseif type(stamp) == "table" and R.gen0Unit(stamp.unit) then
                -- A world rollback below an adoption left the object wearing its token while the
                -- letter stopped listing it. Putting it back is the same decision as making it in
                -- the first place and goes through the same proof: the letter must still be that
                -- generation zero letter, claimed under this very claim seq, with a slot that was
                -- never issued to anyone else. A matching prefix proves none of that.
                local entry = M.entryOf(stamp.owner or username, mailId)
                if entry and R.gen0Admit(entry, stamp.unit, stamp.seq, scan, true) == "bound" then
                    rebound = rebound + 1
                end
            end
        end
        if #named > 0 then
            stamped.stamp = stamped.items[1].stamp
            R.resolveHold(username, "legacy:" .. mailId, "bound")
            R.resolveHold(username, "stamp:" .. mailId, "bound")
            anomaly(username, mailId, "legacy-bound", { qty = #named, units = table.concat(named, ",") })
            changed = true
        end
        if rebound > 0 then
            anomaly(username, mailId, "legacy-rebound", { qty = rebound })
            changed = true
        end
        if failure then R.holdGen0(username, failure) end
    end
    o = owner(username, false)
    local consumed = {}
    for token, row in pairs(scan.byToken) do
        local origin = R.originOf(row.item)
        local opId, receipt, proof = R.consumer(origin)
        local sourceKey = "unit:source:" .. token
        if proof == "unreadable" then
            if origin and origin.mailId then blockedLetters[origin.mailId] = true end
            R.hold(username, sourceKey, "source_state_unknown",
                { unit = token, item = row.fullType, mailId = origin and origin.mailId })
        else
            local held = R.heldRecord(username, sourceKey)
            if held and held.reason == "source_state_unknown" then
                R.resolveHold(username, sourceKey, "source_readable")
            end
        end
        if opId and proof == "locator" then
            if origin.mailId then
                blockedLetters[origin.mailId] = true
                R.holdGen0(username, { mailId = origin.mailId, reason = "legacy_unit_consumed",
                    opId = opId, item = row.fullType, epoch = origin.epoch, seq = origin.seq })
            else
                R.hold(username, "unit:" .. opId .. ":" .. tostring(row.nativeId), "stale_native_copy",
                    { opId = opId, unit = row.nativeId, item = row.fullType, qty = 1 })
            end
        elseif opId then
            local durable = R.receiptVerdict(receipt) == "survived"
            local insured = receipt and receipt.owner == username and p.pendingOuts[opId] ~= nil and not protected[opId]
            consumed[token] = { opId = opId, proof = durable or insured, origin = origin }
            if not durable and not insured and origin and origin.mailId then blockedLetters[origin.mailId] = true end
        end
    end
    if o then
        for mailId, entry in pairs(o.entries) do
            local witness, have = p.claims[mailId], scan.stamped[mailId]
            local avail = availableUnits(entry)
            if entry.state == "claimed" and not witness and not have and not blockedLetters[mailId] then
                if #avail > 0 then
                    local claimSeq = S.nextSeq()
                    local proxy = { id = entry.id, owner = entry.owner, kind = entry.kind, item = entry.item,
                        qty = #avail, units = avail, txId = entry.txId, snapshot = entry.snapshot,
                        listingId = entry.listingId, parentMailId = entry.parentMailId }
                    local result = deliver(player, proxy, claimSeq)
                    if result.ok then
                        addWitness(p, mailId, md.meta.epoch, claimSeq)
                        entry.claimSeq, entry.claimedAt = claimSeq, ms
                        anomaly(username, mailId, "redelivered", { qty = result.qty })
                    elseif result.kept then
                        local child = splitDelivered(player, o, entry, claimSeq, result.kept, ms)
                        anomaly(username, mailId, "redeliver-partial", { child = child.id, delivered = child.qty, remaining = entry.qty })
                    else
                        reopen(o, entry)
                        anomaly(username, mailId, "requeued", { reason = result.error })
                    end
                    changed = true
                end
            end
        end
    end
    changed = reconcileMissingLetters(username, p, scan, blockedLetters) or changed
    for token, info in pairs(consumed) do
        local row = scan.byToken[token]
        if row and not row.gone then
            local key = "unit:" .. info.opId .. ":" .. token
            if info.proof then
                if R.removeUnit(username, key, row, { opId = info.opId, unit = token }) then changed = true end
            else
                R.hold(username, key, "current_commitment_uninsured", { opId = info.opId, unit = token })
            end
        end
    end
    for _, receipt in ipairs(receipts) do
        for _, unit in ipairs(receipt.units or {}) do
            if unit.n ~= nil then
                for _, row in ipairs(scan.byId[unit.n] or {}) do
                    if not row.gone and row.stamp == nil and (receipt.item == nil or row.fullType == receipt.item) then
                        R.hold(username, "unit:" .. receipt.id .. ":" .. tostring(unit.n), "stale_native_copy",
                            { opId = receipt.id, unit = unit.n })
                    end
                end
            end
        end
    end
    for mailId in pairs(p.claims) do
        if not M.entryOf(username, mailId) and not scan.stamped[mailId] then p.claims[mailId] = nil; changed = true end
    end
    R.resolveObserved(username, p, scan)
    for _, receipt in ipairs(receipts) do
        -- The source is asked on every pass, whether or not the save still carries the pending
        -- record. Skipping the question while the record is insured is what made this evidence
        -- unreachable in the ordinary same-epoch case: an operator would never learn that the
        -- working set stopped shrinking because a lookup could not run (report ER-10).
        local key = "receipt:" .. receipt.id
        local alive = R.sourceAlive(receipt.ref)
        if alive == nil then
            -- held with its own opId, which also keeps the receipt from being retired by any
            -- other path while this account has an open question about it
            R.hold(username, key, "source_state_unknown", { opId = receipt.id, kind = receipt.kind })
        elseif alive == false then
            -- the probe answered this time, so the earlier "could not ask" is resolved against
            -- that observation and convergence resumes on its own. Only that one reason: this
            -- key also holds a receipt whose replay could not be insured, and a readable source
            -- must not clear a condition it says nothing about.
            local held = R.heldRecord(username, key)
            if held and not held.resolvedAt and held.reason == "source_state_unknown" then
                R.resolveHold(username, key, "source_readable")
            end
        end
        -- Retiring is a separate decision from reading: a save that still carries the pending
        -- record reopens the receipt (rule three), and only a receipt whose source this server
        -- established is gone, with no open question left on it, is filed.
        if p.pendingOuts[receipt.id] then
            R.reopenReceipt(username, receipt)
        elseif alive == false and not R.unresolvedOp(username, receipt.id) then
            R.closeReceipt(username, receipt, ms)
        end
    end
    if changed then R.transmit(player) end
    S.reply(player, "recovery.status", R.status(username))
    return true
end

-- ---------- login reconciliation of list-out (rule three rows 4-6) ----------

-- pendingOuts[opId] = { protocol = 2, origins = { {src, unit (token)?, nativeId, mailId?, owner?,
-- epoch?, seq?, parentMailId?, srcRef?}, ... }, itemIds, qty, lotQty, snapshot, price, kind,
-- seq, epoch, at } plus the kind's own fields (hours; sku/unitPrice/unitQty/count/txRequestId).
-- ECRecovery judges each record against the world, the receipts and one inventory snapshot;
-- this applies the verdict. Returns changed, handledKeys (the unit keys this pass owns).
reconcileOuts = function(player, p, scan, username)
    local Mk, changed, handled = S.Market, false, {}
    local pending = {}
    for id, record in pairs(p.pendingOuts) do
        local epoch, seq = EC.parseId(id)
        pending[#pending + 1] = { id = id, record = record, epoch = tonumber(epoch) or math.huge, seq = seq or math.huge }
    end
    EC.sortSafe(pending, function(a, b) return a.epoch == b.epoch and a.seq < b.seq or a.epoch < b.epoch end)
    for _, value in ipairs(pending) do
        local id, pend = value.id, value.record
        -- this pass is the repair pass, so a cold proof read may resume it when it completes
        local verdict = R.judgePending(username, id, pend, scan, { resume = true })
        for key in pairs(verdict.keys) do handled[key] = true end
        local holding = false
        if verdict.action == "removeOriginal" then
            local removed = true
            for _, row in ipairs(verdict.present) do
                local unit = row.stamp and row.stamp.unit or row.nativeId
                if not R.removeUnit(username, "unit:" .. id .. ":" .. tostring(unit), row, { opId = id, unit = unit }) then
                    removed = false
                end
            end
            if removed then
                if verdict.clear then p.pendingOuts[id] = nil end
                anomaly(username, id, "removed-listed-original", { qty = #verdict.present })
            else holding = true end
            changed = true
        elseif verdict.action == "clear" or verdict.action == "cancel" then
            p.pendingOuts[id] = nil
            R.releaseOut(id)
            R.resolveHold(username, "abort:" .. id, "returned")
            if verdict.reason == "item_present" then anomaly(username, id, "pending-cleared-item-present")
            elseif verdict.action == "cancel" then anomaly(username, id, "pending-cancelled-upstream", { qty = verdict.total }) end
            changed = true
        elseif verdict.action == "restore" or verdict.action == "partial" then
            -- Everything this branch rebuilds comes from the server's own journal record, which
            -- the judge has already matched to this operation's commit point. The player's
            -- pending is what made the server look for it and nothing else: its currency, price,
            -- quantity, snapshot and origins are never copied into the restore (report CORE-H1).
            local proof = verdict.replay
            if type(proof) ~= "table" then
                R.hold(username, "pend:" .. id, "proof_required", { opId = id })
                holding = true
            else
            local admitted, admissionError = R.reserveOut(username, id)
            if not admitted then
                R.hold(username, "pend:" .. id, admissionError, { opId = id, qty = proof.qty })
                holding = true
            else
                local partial = verdict.action == "partial"
                local returning = partial or proof.kind == "return"
                local record = R.copyReplay(proof)
                R.markProven(record)
                if partial then
                    record.originalKind, record.kind = proof.kind, "return"
                    record.origins, record.qty, record.lotQty = verdict.validOrigins, verdict.valid, verdict.valid
                end
                local ok, info
                -- the new commit point has to come after the journal's own successor, never
                -- after an ancestor the pending happened to match
                local successor = tonumber(verdict.serverSeq) or 0
                local recorded = tonumber(proof.seq) or 0
                S.bumpSeq(successor > recorded and successor or recorded)
                if returning then
                    local snapshot = record.snapshot
                    -- the letter says what the goods were worth and in which currency: a
                    -- record whose currency cannot be proved is held, never mailed back with a
                    -- price in a guessed one (spec contract 13)
                    local currency = L.normalizeRecord(record, L.TRUST_SERVER)
                    if currency == nil then
                        info = { reason = "currency_unknown" }
                    elseif type(snapshot) == "table" and type(snapshot.type) == "string" and record.qty >= 1 then
                        local entry, err = M.add(username, { kind = "return", item = snapshot.type,
                            qty = record.qty, price = record.price, currency = currency,
                            snapshot = snapshot, listingId = id }, record.returnMailId)
                        if entry then
                            record.returnMailId = entry.id
                            ok, info = true, { mailId = entry.id, reason = "return" }
                        else info = { reason = err } end
                    else info = { reason = "partial_unbuildable" } end
                else
                    ok, info = Mk.restoreFromPending(username, id, record)
                    if ok and type(info) == "table" and info.mailId then
                        record.originalKind, record.kind, record.returnMailId = record.kind, "return", info.mailId
                    end
                end
                if ok then
                    local ref = type(info) == "table" and (info.mailId or info.txId) or id
                    -- the marker only authorises this call; what the save keeps is the record
                    R.stripProven(record)
                    local committed, err = R.finishOut(username, id, record, record.kind, ref or id)
                    if committed then
                        p.pendingOuts[id] = record
                        anomaly(username, id, partial and "partial-returned" or "listing-restored",
                            { qty = record.qty, price = record.price, kind = record.kind, mailId = record.returnMailId })
                    else
                        R.hold(username, "pend:" .. id, err, { opId = id, qty = record.qty })
                        holding = true
                    end
                else
                    R.releaseOut(id)
                    R.hold(username, "pend:" .. id, type(info) == "table" and info.reason or "restore_failed",
                        { opId = id, qty = proof.qty })
                    holding = true
                end
                changed = true
            end
            end
        elseif verdict.action == "hold" then
            R.holdUpdate(username, "pend:" .. id, verdict.reason, { opId = id, kind = pend.kind,
                qty = tonumber(pend.qty), price = tonumber(pend.price), item = verdict.item,
                ids = verdict.ids, vanished = verdict.vanished, found = verdict.found, absent = verdict.absent,
                epoch = pend.epoch, seq = tonumber(pend.seq), outcome = verdict.outcome })
            holding = true
        end
        if not holding then R.resolveHold(username, "pend:" .. id, verdict.action) end
    end
    return changed, handled
end

-- ---------- death (rule five, part one) ----------

-- Rule five: the dead character's modData is gone with the corpse, but its pendingOuts are
-- still needed to rebuild listings after a rollback; keep them in memory until the next
-- character exists (OnNewGame) and write them into that one (spec 19.7 rule five, part two).
local carryOver = {}

function M.onDeath(character)
    if not md or not instanceof(character, "IsoPlayer") then return end
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
    local p = R.playerData(player)
    for id, pend in pairs(pending) do p.pendingOuts[id] = pend end
    R.transmit(player)
end

-- ---------- retention ----------

-- A generation zero letter is the only surviving record of what an old delivery was: it cannot
-- be rebuilt, there will never be more of them, and pruning one before its units are named
-- destroys the evidence a binding needs. It is kept while it still owes a slot no binding has
-- taken and no transfer has consumed; once every slot is named it prunes like any other claimed
-- letter. Protocol 2 retention is untouched.
local function gen0Pending(entry)
    if entry.gen0 ~= true or entry.gen0Closed == true then return false end
    local taken = type(entry.outUnits) == "table" and entry.outUnits or nil
    local units = type(entry.units) == "table" and entry.units or {}
    for i = 1, #units do
        local t = units[i]
        if t == entry.id .. "#" .. tostring(i) and not (taken and taken[t] ~= nil) then return true end
    end
    entry.gen0Closed = true
    return false
end

-- ---------- proof reads that finished after a repair pass (recovery-proof contract) ----------
--
-- A rollback that has to be rebuilt waits for the server's own journal line, and that read is
-- bounded per tick: the reconcile that needed it answered `journal_pending` and kept the record
-- untouched. When the read completes, the account is queued here and judged again on the NEXT
-- tick - against the world and the player as they are then, never against the verdict the read
-- started from. Nothing is applied inside the journal callback, so a busy reader can never
-- recurse back into a reconcile.
--
-- The same journal is also read when an administrator merely looks at a record. Such a read
-- leaves no resume ticket (R.judgePending only takes one for a caller that passed `resume`), and
-- without a ticket its completion notice updates nothing here: looking at a held operation must
-- never quietly become the instruction to repair it.
M.READY_MAX = 64
local readyQueue, readyCount = {}, 0

local function noteProofReady(username)
    if type(username) ~= "string" or username == "" then return end
    if not R.hasProofTicket(username) then return end
    if readyQueue[username] then return end
    if readyCount >= M.READY_MAX then
        EC.log("mailbox proof queue full; " .. username .. " will be judged at the next login")
        return
    end
    readyQueue[username] = true
    readyCount = readyCount + 1
end

local function drainProofReady()
    if readyCount == 0 then return end
    local names = {}
    for name in pairs(readyQueue) do names[#names + 1] = name end
    readyQueue, readyCount = {}, 0
    for _, name in ipairs(names) do
        -- identity is re-established here: the answer is only applied to the player who is
        -- actually online under that name now, and to their current save.
        --
        -- The ticket is retired AFTER that pass, never before: the pass is the one that needs
        -- to know what this server could see when the read started, and clearing first made
        -- that comparison read an empty memory (report: the read window duplication). `mark` is
        -- taken before the pass, so a ticket the pass took anew - a read that still has to
        -- finish - survives the retirement.
        local mark = R.proofMark()
        local player = S.onlinePlayer(name)
        local ok, err = true, nil
        if player and player:getUsername() == name then
            ok, err = pcall(M.reconcile, player)
        end
        R.clearProofTickets(name, mark)
        if not ok then
            EC.log("mailbox reconcile after a proof read failed for " .. name .. ": " .. tostring(err))
        end
    end
end

-- ponytail: walks every owner once a minute; index by claimedAt if thousands of owners hurt.
function M.onTick()
    if not md then return end
    local ms = EC.now()
    -- proof reads are drained every tick; the retention walk stays on its own minute clock
    drainProofReady()
    if ms - lastPrune < M.PRUNE_EVERY_MS then return end
    lastPrune = ms
    for username, o in pairs(md.mailbox.byOwner) do
        local dead = {}
        local left = 0
        for id, e in pairs(o.entries) do
            if (e.state == "claimed" or e.state == "settled") and ms - (e.claimedAt or e.at or 0) > M.CLAIMED_TTL_MS
                and not gen0Pending(e) then
                dead[#dead + 1] = id
            else
                left = left + 1
            end
        end
        for _, id in ipairs(dead) do o.entries[id] = nil end
        if left == 0 then md.mailbox.byOwner[username] = nil end
    end
    R.prune(ms)
end

-- ---------- commands ----------

-- The mailbox replies share one view: the rows, how many of them there are and the slot usage,
-- so the page redraws from a single source. Every listed letter is claimable (see M.list).
local function fillView(res, username)
    local entries = M.list(username)
    res.entries, res.ready = entries, #entries
    res.unclaimed = M.unclaimed(username)
    res.usage = M.usage(username)
    return res
end

S.handlers["mail.list"] = function(player, args)
    local res = fillView({}, player:getUsername())
    res.atTerminal = T.near(player)
    res.requestId = type(args.requestId) == "string" and #args.requestId <= 96 and args.requestId or nil
    S.reply(player, "mail.list", res)
end

S.handlers["mail.claim"] = function(player, args)
    local res
    if not T.near(player) then
        res = { ok = false, error = "not_at_terminal" }
    else
        res = M.claim(player, type(args) == "table" and args.mailId or nil)
    end
    res.requestId = type(args) == "table" and args.requestId or nil
    fillView(res, player:getUsername())
    S.reply(player, "mail.claim", res)
end

-- mail.claimAll { mailIds, requestId }: the batch the client drives one chunk at a time.
S.handlers["mail.claimAll"] = function(player, args)
    local requestId = type(args) == "table" and type(args.requestId) == "string" and args.requestId ~= "" and #args.requestId <= 96 and args.requestId or nil
    local res
    if not requestId then
        res = { ok = false, error = "invalid_args" }
    elseif not T.near(player) then
        res = { ok = false, error = "not_at_terminal" }
    else
        res = M.claimAll(player, type(args) == "table" and args.mailIds or nil)
    end
    res.requestId = requestId
    fillView(res, player:getUsername())
    S.reply(player, "mail.claimAll", res)
end

-- The client's first command after login is `hello`: reconcile right there (A18 shape).
local prevHello = S.handlers.hello
S.handlers.hello = function(player, args)
    prevHello(player, args)
    local ok, err = pcall(M.reconcile, player)
    if not ok then
        EC.log("mailbox reconcile failed for " .. tostring(player:getUsername()) .. ": " .. tostring(err))
    elseif err == false then
        -- The pass itself said it could not read what it had to judge; the account is held and
        -- the status reply already said so, but the line in the log is what an operator sees.
        EC.log("mailbox reconcile incomplete for " .. tostring(player:getUsername()) .. ": read_failed")
    end
end

-- A letter written before unit tokens existed has no `units` at all. Marking it once, here,
-- is what lets the retention above tell "old evidence a binding still needs" from "a claimed
-- letter whose TTL ran out", and minting its placeholders gives the binding the slots to take.
-- The same pass names the currency of a letter that carries a price from the single-currency
-- days (spec contract 13): a letter is not a payment, so this only fixes what the row says the
-- goods were worth; a letter with no price has no currency to name, and one that carries the
-- schema mark without a usable currency is left exactly as it is.
-- One pass over a bounded mailbox per server start; letters that already have tokens and a
-- currency are left exactly as they are.
local function markGen0(root)
    for _, o in pairs(root.mailbox.byOwner) do
        for _, entry in pairs(o.entries) do
            if entry.gen0 == nil and type(entry.units) ~= "table" and (tonumber(entry.qty) or 0) > 0 then
                entry.gen0 = true
                letterUnits(entry)
            end
            if entry.currency == nil and entry.tradeSchema == nil and tonumber(entry.price) ~= nil then
                L.normalizeRecord(entry, L.TRUST_SERVER)
            end
        end
    end
end

function M.init(root)
    md = root
    md.mailbox = md.mailbox or { byOwner = {}, unclaimed = 0 }
    lastPrune = 0
    readyQueue, readyCount = {}, 0
    markGen0(md)
    -- one consumer of the journal's completion notice, registered once the whole module set is
    -- loaded. Without it a proof read would finish with nobody to judge it again, so its absence
    -- is said out loud rather than waited on.
    local J = S.RecoveryJournal
    if J ~= nil and type(J.onReady) == "function" then
        J.onReady(function(username) noteProofReady(username) end)
    else
        EC.log("recovery journal notifications unavailable: proofs will be judged at the next login")
    end
end

S.Mailbox = M
S.onInit(M.init)
Events.OnTickEvenPaused.Add(M.onTick)
Events.OnCharacterDeath.Add(M.onDeath)
Events.OnNewGame.Add(M.onNewGame)
return M
