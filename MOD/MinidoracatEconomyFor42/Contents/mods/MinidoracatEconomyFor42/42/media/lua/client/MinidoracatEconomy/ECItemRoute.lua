-- MinidoracatEconomyFor42 - where an item the player pointed at is, and the vanilla move that puts
-- it where the market reads (client). Adds exactly one namespace: C.ItemRoute.
--
-- The server takes listings, auctions and buyback sales only from the top level of the main
-- inventory (ECMarket candidates, ECShop sell candidates); a force-drop heavy item counts there
-- while both hands hold it (ECCodec stateCheck). An item anywhere else is moved there first with
-- vanilla's own actions, the ones a double click on its row queues (ISInventoryPane.lua:1199-1206):
--   heavy -> ISInventoryPaneContextMenu.equipHeavyItem (ISInventoryPaneContextMenu.lua:4157-4173):
--            both hands, from wherever it lies
--   other -> ISInventoryPaneContextMenu.transferIfNeeded (:1910-1930): walk to the container,
--            transfer to the main inventory
-- A generator never lies on the floor as an item: dropping one stands it up as an IsoGenerator
-- (IsoGridSquare.java:6080-6083, 6147-6150). It is taken back with the generator menu's own
-- "Take Generator" (ISWorldObjectContextMenuLogic.java:2218-2225 -> ISWorldObjectContextMenu.
-- onTakeGenerator, :665-678 -> ISTakeGenerator), which puts a new item into both hands.
--
-- Nothing here sends a command or trusts an outcome. The caller waits for the item to show up in
-- the main inventory (or for vanilla to give up) and then asks the server, which judges it.

require "ISUI/ISInventoryPane"
require "ISUI/ISInventoryPaneContextMenu"
require "ISUI/ISWorldObjectContextMenu"

local EC = MinidoracatEconomy
local C = EC.Client

local R = {}
C.ItemRoute = R

-- How long a queued move may take, and how long an empty action queue is believed before the
-- move counts as given up (a cancelled walk, a full backpack, an action vanilla refused). An MP
-- action leaves the queue before the server's packets land, hence the grace.
-- ponytail: fixed timings, a setting when a server with slow actions proves them short
R.WAIT_MS = 60000
R.IDLE_MS = 3000

local job = nil

local function now() return getTimestampMs() end

-- Vanilla's own predicate (ISEquipWeaponAction.lua:71-73): generators, corpses, animals and every
-- base:heavyitem (InventoryItem.java:534-540).
function R.isHeavy(item)
    return item ~= nil and isForceDropHeavyItem(item) == true
end

-- The InventoryItems of a drag or a menu selection: rows are either items or vanilla's groups
-- (ISInventoryPane.getActualItems, ISInventoryPane.lua:912-934).
function R.items(list)
    if type(list) ~= "table" then return {} end
    local out = {}
    for _, item in ipairs(ISInventoryPane.getActualItems(list)) do
        if instanceof(item, "InventoryItem") then out[#out + 1] = item end
    end
    return out
end

-- "main" = the top level of the main inventory, the one place the server reads; "bag" = a container
-- the player carries; "floor" = the loot window's floor; "container" = any other container in
-- reach. nil = nowhere this player can take it from.
function R.where(item, player)
    local cont = item and item:getContainer()
    if cont == nil or player == nil then return nil end
    if cont == player:getInventory() then return "main" end
    if cont:isInCharacterInventory(player) then return "bag" end
    if cont:getType() == "floor" then return "floor" end
    return "container"
end

-- What one drop or one menu click moves: the first item and every other picked item of its type
-- (the server lists one group of identical items at a time). A heavy item travels alone - two
-- hands carry one.
function R.lot(items)
    local first = items[1]
    if first == nil then return {} end
    if R.isHeavy(first) then return { first } end
    local fullType, out = first:getFullType(), {}
    for _, item in ipairs(items) do
        if item:getFullType() == fullType then out[#out + 1] = item end
    end
    return out
end

-- What the player has to change before the item can go at all, as a reason key the market and the
-- shop already translate (Market_Reason_*). A heavy item in both hands is how it is carried, not
-- "equipped".
function R.blocked(item, player)
    if item:isFavorite() then return "favorite" end
    if item:getContainer() == player:getInventory() and player:isEquipped(item) and not R.isHeavy(item) then
        return "equipped"
    end
    return nil
end

-- Whether placing it in the main inventory takes a vanilla move first, and which one.
function R.move(item, player)
    if R.where(item, player) == "main" then return nil end
    return R.isHeavy(item) and "hands" or "main"
end

local function finish(arrived, why)
    local j = job
    job = nil
    Events.OnTick.Remove(R.tick)
    if j then j.done(arrived, why) end
end

-- The ids of the job that are on the top level of the main inventory now.
local function arrivedIds(j)
    local inv, out = j.player:getInventory(), {}
    if j.fresh then
        -- a taken generator is a new object (ISTakeGenerator.lua:39-55): of the generator's own
        -- type, not in the inventory before, and in both hands - not any heavy item that happened
        -- to arrive meanwhile (an auction won at the terminal is claimed straight in)
        local items, hand = inv:getItems(), j.player:getPrimaryHandItem()
        for i = 0, items:size() - 1 do
            local item = items:get(i)
            if item == hand and item:getFullType() == j.fullType and not j.before[item:getID()]
                and j.player:getSecondaryHandItem() == item then
                return { item:getID() }
            end
        end
        return out
    end
    for _, id in ipairs(j.ids) do
        if inv:getItemWithID(id) then out[#out + 1] = id end
    end
    return out
end

function R.tick()
    local j = job
    if j == nil then
        Events.OnTick.Remove(R.tick)
        return
    end
    local arrived = arrivedIds(j)
    if not j.fresh and #arrived == #j.ids then return finish(arrived) end
    if j.fresh and #arrived > 0 then return finish(arrived) end
    local t = now()
    local queue = ISTimedActionQueue.getTimedActionQueue(j.player)
    if queue and queue.queue and #queue.queue > 0 then
        j.idleAt = nil
    elseif j.idleAt == nil then
        j.idleAt = t
    end
    -- vanilla gave up (or did only part of it): what made it is still worth offering
    if (j.idleAt ~= nil and t - j.idleAt > R.IDLE_MS) or t > j.deadline then
        finish(arrived, t > j.deadline and "timeout" or "stopped")
    end
end

-- A move still under way, or nil.
function R.pending() return job end

-- Drop the waiting job without calling it back (the dialog that waited is gone). The vanilla
-- actions already queued run on: they are the player's own, and the item simply arrives.
function R.cancel()
    job = nil
    Events.OnTick.Remove(R.tick)
end

local function start(player, done, fields)
    R.cancel()
    job = fields
    job.player, job.done, job.deadline = player, done, now() + R.WAIT_MS
    Events.OnTick.Add(R.tick)
end

-- Put `items` on the top level of the main inventory with vanilla's actions, then call
-- done(arrivedIds, why). arrivedIds lists the ids that made it (all of them when why is nil);
-- why is "stopped" or "timeout" when vanilla gave up first. Items already there call back at once.
function R.bring(items, player, done)
    local ids, queued = {}, false
    for _, item in ipairs(items) do
        ids[#ids + 1] = item:getID()
        local how = R.move(item, player)
        if how == "hands" then
            ISInventoryPaneContextMenu.equipHeavyItem(player, item)
            queued = true
        elseif how == "main" then
            ISInventoryPaneContextMenu.transferIfNeeded(player, item)
            queued = true
        end
    end
    if not queued then
        R.cancel()
        return done(ids)
    end
    start(player, done, { ids = ids })
end

-- Whether vanilla's "Take Generator" would run now: offered only while nothing is plugged in
-- (ISWorldObjectContextMenuLogic.java:2218), refused from a vehicle (onTakeGenerator) and by the
-- action itself once connected (ISTakeGenerator.lua:5-9).
function R.canTakeGenerator(obj, player)
    return not obj:isConnected() and player:getVehicle() == nil
end

-- Take the generator with vanilla's own action (walk next to it, empty the hands, ISTakeGenerator),
-- then call done({ newItemId }) once the item it becomes is in the main inventory (or done({}, why)
-- when vanilla gave up first).
function R.takeGenerator(obj, player, done)
    if not R.canTakeGenerator(obj, player) then return done({}, "refused") end
    local before, items = {}, player:getInventory():getItems()
    for i = 0, items:size() - 1 do before[items:get(i):getID()] = true end
    ISWorldObjectContextMenu.onTakeGenerator(nil, obj, player:getPlayerNum())
    start(player, done, { fresh = true, before = before, fullType = obj:getGeneratorItemType() })
end

return R
