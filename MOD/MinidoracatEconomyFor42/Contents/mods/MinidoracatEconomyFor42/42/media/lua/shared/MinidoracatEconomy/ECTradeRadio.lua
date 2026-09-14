-- MinidoracatEconomyFor42 - trade terminal radio: native identity and operation guards (shared).
--
-- The trade terminal's companion transmitter is a real Base.HamRadio1 IsoRadio placed on the
-- terminal's own square (server side: ECTradeRadioRelay). This module is the identity half both
-- sides agree on, plus the guards that keep a player from walking away with a server-owned
-- device. It owns no world state, no ModData and no persistence.
--
-- Identity is the device's own DeviceData name (DeviceData.java:435-441; saved and loaded with
-- the device: DeviceData.java:1237, 1278, carried by IsoWaveSignal.save/load :308-330), never
-- ModData and never the IsoObject name: vanilla placement writes obj:setName from a
-- player-controlled item ModData key with no class check (ISMoveableSpriteProps.lua:2273-2281),
-- while deviceName has no client-reachable writer in this build (script display name at item
-- load, Item.java:1778; server-side vehicle radios, Vehicles.lua:302-356; AddItemToMapPacket -
-- the only packet carrying a whole DeviceData - has no server handler, AddItemToMapPacket.java
-- :60-102).
--
-- Invariants every caller depends on:
--   * a vanilla radio is never refused and never removed, whatever its name or ModData says;
--   * an owned device stays recognisable as an orphan wherever it stands, even unregistered;
--   * a failing native getter is an error, not "not ours". isOwned and ownedOnSquare let it
--     raise: the caller aborts that operation instead of treating an unreadable device as
--     absent (which would add a second one) or as a normal radio (which would let it be taken).
--
-- Deliberately not handled here: a client can point a dropped Radio item's ModData RadioItemID
-- at an owned device, and the vanilla server handler (RemoveItemFromSquarePacket
-- .handleRemoveRadio) will then delete the carrier. That is a packet the server accepts by
-- itself; the relay's verified rebuild is the answer, and no wrapper in this shared file would
-- change it.
--
-- Engine references (decompiled snapshot 42.20.4-20260826; vanilla Lua from the same build):
--   IsoRadio(cell, square, sprite), getObjectName() = "Radio"   IsoRadio.java:10-21
--   DeviceData.getDeviceName / setDeviceName, getParent()       DeviceData.java:435-441, 205-207
--   appliances_com_01_0..3 = Premium Technologies Ham, four facings, CustomItem=Base.HamRadio1,
--     IsoType=IsoRadio, IsMoveAble, CanScrap    media/newtiledefinitions.tiles.txt:988-1060
--   pickup: canPickUpMoveable is the UI gate; pickUpMoveableInternal is the only place the item
--     is created and the object leaves the square; pickUpMoveable can skip the gate with
--     _forceAllow                              ISMoveableSpriteProps.lua:1167-1202, 1274-1420
--   rotate: rotateMoveable is the execution entry (cursor, the shared timed action and the
--     server transaction all land here) and never calls canRotateMoveable - it picks the object
--     up with _forceAllow and then unconditionally places a same-sprite item. findOnSquare is
--     how it resolves the target; only rotateMoveableInternal consults canRotateMoveable.
--                                              ISMoveableSpriteProps.lua:2705-2727, 2730-2766,
--                                                                       922-945
--   scrap: canScrapObject is the UI gate (overridden by the movables cheat), scrapObjectInternal
--     destroys the object and spawns the scrap
--                                              ISMoveableSpriteProps.lua:3258-3308, 3476-3588
--   device battery / media: invoke() runs only when isValid() agrees
--                                              ISDeviceBatteryAction.lua:5-27 ;
--                                              ISDeviceMediaAction.lua:5-32

if not MinidoracatEconomy or not MinidoracatEconomy.makeId then
    require "MinidoracatEconomy/ECCore"
end
local EC = MinidoracatEconomy
if not EC then return end

EC.TradeRadio = EC.TradeRadio or {}
local TR = EC.TradeRadio

-- The one string that decides ownership. It lives in the device's DeviceData name, never in
-- ModData, never in the object's own name field, and is never derived or translated.
TR.NAME = "MinidoracatEconomyTradeRadio"


-- ---------- identity ----------

-- True only for a real IsoRadio whose DeviceData name is exactly TR.NAME; false for anything
-- else, including an object whose IsoObject name or ModData was made to read TR.NAME. A getter
-- that fails raises: see the invariants above.
function TR.isOwned(object)
    if object == nil then return false end
    if not instanceof(object, "IsoRadio") then return false end
    local data = object:getDeviceData()
    return data:getDeviceName() == TR.NAME
end

-- Every owned radio standing on `square`, in the square's own object order (duplicates included:
-- the relay removes the extras). nil square -> empty, which is the normal "not loaded" answer.
-- A square whose object list cannot be read raises instead of returning a short list.
function TR.ownedOnSquare(square)
    local out = {}
    if square == nil then return out end
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        local o = objects:get(i)
        if TR.isOwned(o) then out[#out + 1] = o end
    end
    return out
end

-- ---------- operation guards ----------

local installed = false

local VANILLA_FILES = {
    "Moveables/ISMoveableSpriteProps",
    "TimedActions/ISDeviceBatteryAction",
    "TimedActions/ISDeviceMediaAction",
}

local PROPS_FUNCTIONS = {
    "canPickUpMoveable", "pickUpMoveableInternal",
    "rotateMoveable", "canRotateMoveable", "findOnSquare",
    "canScrapObject", "scrapObjectInternal",
}

local function deviceActionOwned(action)
    if action == nil then return false end
    local data = action.deviceData
    if data == nil then return false end
    return TR.isOwned(data:getParent())
end

-- Wraps the vanilla moveable and device entry points so an owned radio cannot be carried off,
-- rotated, scrapped, or fed a battery or a tape. Idempotent. Every symbol is checked before the
-- first wrapper is installed, so the result is all guards or none; returns false plus the real
-- require error or the missing symbol name, and the caller must treat that as "no owned device
-- may exist" rather than as a warning.
function TR.installGuards()
    if installed then return true end
    for _, file in ipairs(VANILLA_FILES) do
        local ok, err = pcall(require, file)
        if not ok then return false, "require " .. file .. ": " .. tostring(err) end
    end
    local props = ISMoveableSpriteProps
    if type(props) ~= "table" then return false, "ISMoveableSpriteProps" end
    for _, name in ipairs(PROPS_FUNCTIONS) do
        if type(props[name]) ~= "function" then return false, "ISMoveableSpriteProps:" .. name end
    end
    if type(ISDeviceBatteryAction) ~= "table" or type(ISDeviceBatteryAction.isValid) ~= "function" then
        return false, "ISDeviceBatteryAction:isValid"
    end
    if type(ISDeviceMediaAction) ~= "table" or type(ISDeviceMediaAction.isValid) ~= "function" then
        return false, "ISDeviceMediaAction:isValid"
    end

    -- pickup: the menu gate...
    local canPickUp = props.canPickUpMoveable
    props.canPickUpMoveable = function(self, _character, _square, _object)
        if TR.isOwned(_object) then return false end
        return canPickUp(self, _character, _square, _object)
    end
    -- ...and the only place the item is made and the object leaves the world. pickUpMoveable
    -- reaches here with _forceAllow (rotation does), so the gate above is not enough on its own.
    -- Returning nil is what vanilla returns when nothing was picked up: no item, object stays.
    local pickUpInternal = props.pickUpMoveableInternal
    props.pickUpMoveableInternal = function(self, _character, _square, _object, _sprInstance, _spriteName, _createItem, _rotating)
        if TR.isOwned(_object) then return nil end
        return pickUpInternal(self, _character, _square, _object, _sprInstance, _spriteName, _createItem, _rotating)
    end

    -- rotate: the outer entry, which is what a server transaction and the shared timed action
    -- actually run. It resolves its target with findOnSquare(_square, _origSpriteName), so this
    -- guard resolves the same object and refuses before the forced pickup and before the
    -- unconditional place. Refusing only the pickup half is not a side-effect-free refusal: the
    -- place step would still pull another ham radio out of the player's inventory onto this
    -- square. Vanilla returns nothing here.
    local findOnSquare = props.findOnSquare
    local rotate = props.rotateMoveable
    props.rotateMoveable = function(self, _character, _square, _origSpriteName)
        if TR.isOwned(findOnSquare(self, _square, _origSpriteName)) then return end
        return rotate(self, _character, _square, _origSpriteName)
    end
    -- ...and the sprite swap, so the cursor cannot re-face the device either.
    local canRotate = props.canRotateMoveable
    props.canRotateMoveable = function(self, _square, _object, _origProps)
        if TR.isOwned(_object) then return false end
        return canRotate(self, _square, _object, _origProps)
    end

    -- scrap: the gate first (its result table is what the info panel renders, so the original
    -- runs and only the verdict is overridden - that also beats the movables cheat, which sets
    -- canScrap = true at the end of the vanilla function)...
    local canScrap = props.canScrapObject
    props.canScrapObject = function(self, _character)
        local result, chance, perkName = canScrap(self, _character)
        if self ~= nil and TR.isOwned(self.object) then
            if type(result) ~= "table" then result = {} end
            result.canScrap = false
            return result, 0, perkName
        end
        return result, chance, perkName
    end
    -- ...then the execution point, which is what actually destroys the object and spawns scrap.
    local scrapInternal = props.scrapObjectInternal
    props.scrapObjectInternal = function(self, _character, _scrapDef, _square, _object, _scrapResult, _chance, _perkName)
        if TR.isOwned(_object) then return 0 end
        return scrapInternal(self, _character, _scrapDef, _square, _object, _scrapResult, _chance, _perkName)
    end

    -- device options: isValid is checked again inside invoke(), so refusing it blocks both the
    -- action starting and the effect. Nothing is consumed: inserting a battery or a tape into an
    -- owned device would eat the player's item for a device that is powered by the server.
    local batteryValid = ISDeviceBatteryAction.isValid
    ISDeviceBatteryAction.isValid = function(self)
        if deviceActionOwned(self) then return false end
        return batteryValid(self)
    end
    local mediaValid = ISDeviceMediaAction.isValid
    ISDeviceMediaAction.isValid = function(self)
        if deviceActionOwned(self) then return false end
        return mediaValid(self)
    end

    installed = true
    return true
end

function TR.guardsInstalled() return installed end

local ok, guardErr = TR.installGuards()
if not ok then
    EC.log("trade radio guards NOT installed (" .. tostring(guardErr)
        .. "); no owned device may be created or left operable until they are")
end

return TR
