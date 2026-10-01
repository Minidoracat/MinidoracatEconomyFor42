-- Terminal objects nobody but a terminal manager may take down, checked on both sides: the mod's
-- own terminal tiles always, a vanilla console (EC.TERMINAL_SPRITES) while its square is a
-- registered terminal, and native map ATMs unless MapATMAllowDestruction opens them. Refused: the
-- sledgehammer, furniture scrap and moveable pickup. NetTimedAction.perform calls complete, not
-- isValid (NetTimedAction.java:118-138). Only the vanilla consoles are IsMoveAble, and none of
-- these sprites has the facing offsets a rotation needs; a forced rotation picks up through
-- pickUpMoveableInternal, which refuses here. They have no attached flags or SpriteGrid either:
-- removing a wall does not remove them. The own tiles take no damage at all (ECTerminal keeps
-- them plain IsoObjects, which zombies, melee and animals cannot hit) and fire skips them
-- (tiledef firerequirement); for consoles and map ATMs, fire, explosions and other mods' world
-- edits are outside this guard.
require "MinidoracatEconomy/ECCore"
require "TimedActions/ISDestroyStuffAction"
require "Moveables/ISMoveableSpriteProps"

local EC = MinidoracatEconomy
if EC.AtmProtection then return end
local P = {}

-- Is this vanilla console's square a registered terminal? The server asks its own registry
-- (ECTerminal); a client asks the list the server pushed to it (ECClient).
local function registered(object)
    local sq = object:getSquare()
    if not sq then return false end
    local x, y, z = sq:getX(), sq:getY(), sq:getZ()
    local S = EC.Server
    if S and S.AUTHORITY then return S.Terminal ~= nil and S.Terminal.at(x, y, z) ~= nil end
    local C = EC.Client
    return C ~= nil and C.terminalAt ~= nil and C.terminalAt(x, y, z) ~= nil
end

function P.blocked(player, object)
    local sprite = object and object:getSprite()
    local name = sprite and sprite:getName()
    if name and EC.TERMINAL_SPRITES[name] then
        if EC.isOwnTerminalSprite(name) or registered(object) then return not EC.canManageTerminals(player) end
        return false
    end
    if not EC.isAtmObject(object) then return false end
    local option = isClient() and EC.Client and EC.Client.options and EC.Client.options.MapATMAllowDestruction
    local allowed
    if type(option) == "table" and type(option.value) == "boolean" then allowed = option.value
    else allowed = EC.sandbox("MapATMAllowDestruction", false) end
    return not allowed and not EC.canManageTerminals(player)
end

local valid = ISDestroyStuffAction.isValid
ISDestroyStuffAction.isValid = function(self)
    if P.blocked(self.character, self.item) then return false end
    return valid(self)
end

-- Check again before sounds, dumped contents or object removal, including queued actions.
local complete = ISDestroyStuffAction.complete
ISDestroyStuffAction.complete = function(self)
    if P.blocked(self.character, self.item) then return false end
    return complete(self)
end

local props = ISMoveableSpriteProps
local canScrap = props.canScrapObject
props.canScrapObject = function(self, character)
    local result, chance, perk = canScrap(self, character)
    if P.blocked(character, self.object) then
        result.canScrap = false
        return result, 0, perk
    end
    return result, chance, perk
end

-- Both ISMoveablesAction.complete and TransactionProcessor reach this execution point.
local scrap = props.scrapObjectInternal
props.scrapObjectInternal = function(self, character, definition, square, object, ...)
    if P.blocked(character, object) then return 0 end
    return scrap(self, character, definition, square, object, ...)
end

-- Pickup: the menu and cursor gate, then the only place the item is made and the object leaves
-- the square. pickUpMoveable skips the gate with _forceAllow (a rotation does), so the execution
-- point refuses as well; nil is what vanilla returns when nothing was picked up. The shared timed
-- action and the server transaction both land here (ISMoveablesAction.lua:236-246,
-- TransactionProcessor.lua:6-14 -> ISMoveableSpriteProps.lua:1265-1304).
local canPickUp = props.canPickUpMoveable
props.canPickUpMoveable = function(self, character, square, object, ...)
    if P.blocked(character, object) then return false end
    return canPickUp(self, character, square, object, ...)
end
local pickUp = props.pickUpMoveableInternal
props.pickUpMoveableInternal = function(self, character, square, object, ...)
    if P.blocked(character, object) then return nil end
    return pickUp(self, character, square, object, ...)
end

EC.AtmProtection = P
return P
