-- Native map ATMs and the mod's own terminal tiles: reject ordinary sledgehammer and furniture-scrap
-- operations on both sides. The own tiles are always held back for anyone but a terminal manager;
-- map ATMs follow MapATMAllowDestruction. NetTimedAction.perform calls complete, not isValid
-- (NetTimedAction.java:118-138). Pickup/rotation already require IsMoveAble, absent on all of
-- these sprites. They also have no attached flags or SpriteGrid: removing a wall does not remove
-- them. The own tiles take no damage at all (ECTerminal keeps them plain IsoObjects, which
-- zombies, melee and animals cannot hit) and fire skips them (tiledef firerequirement); for map
-- ATMs, fire, explosions and other mods' world edits are outside this guard.
require "MinidoracatEconomy/ECCore"
require "TimedActions/ISDestroyStuffAction"
require "Moveables/ISMoveableSpriteProps"

local EC = MinidoracatEconomy
if EC.AtmProtection then return end
local P = {}

function P.blocked(player, object)
    local sprite = object and object:getSprite()
    if sprite and EC.isOwnTerminalSprite(sprite:getName()) then return not EC.canManageTerminals(player) end
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

EC.AtmProtection = P
return P
