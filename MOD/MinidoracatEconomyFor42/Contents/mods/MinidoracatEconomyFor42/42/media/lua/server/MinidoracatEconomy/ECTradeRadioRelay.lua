-- MinidoracatEconomyFor42 - trade terminal two-way radio (server authority).
--
-- With the sandbox option RadioRelayEnabled on, every registered trade terminal gets a real
-- Base.HamRadio1 IsoRadio on its own square, wearing this mod's own small speaker instead of the
-- vanilla ham set: tuned to the market frequency, two-way, powered, with its microphone open.
-- The native engine handles nearby voice/chat routing and receiver range; this module only
-- places and maintains the device. It does not bypass PTT/VAD or prove that anyone heard it.
--
-- The speaker is appearance, and appearance only: it is the device's sprite (Rl.SPEAKERS,
-- tilesets 3 and 4 of MinidoracatEconomy_tiles) and changes nothing else. The device still
-- stands on the terminal's own square, so the voice source coordinates are exactly what they
-- were; the offset that puts the speaker on the catgirl's shoulder or on a machine's upper edge
-- lives inside the 128x256 cell, because IsoGridSquare.fixPlacedItemRenderOffsets:10213-10249
-- only repositions IsoWorldInventoryObject and never an IsoRadio.
--
-- What it is NOT: this module never claims a transmission was heard. It reports what it placed
-- and configured (radioState / radioInfo), and nothing more. ATM terminals never get a device.
--
-- How the pieces meet the engine (decompiled snapshot 42.20.4-20260826, vanilla Lua same build):
--   IsoRadio.new(cell, square, sprite)             IsoRadio.java:14-16 ; vanilla use
--                                                  ISMoveableSpriteProps.lua:2133
--   cloneDeviceDataFromItem("Base.HamRadio1")      IsoWaveSignal.java:98-115 (returns a CLONE and
--                                                  does not install it: setDeviceData does)
--   Speaker sprites have no CustomItem. The constructor leaves blank DeviceData; the explicit
--   clone supplies the HAM configuration before AddSpecialObject (IsoWaveSignal.java:64-115).
--   square:AddSpecialObject(obj) -> obj:addToWorld() -> ZomboidRadio.RegisterDevice
--                                                  IsoGridSquare.java:6181-6199 ;
--                                                  IsoWaveSignal.java:332-340
--   RegisterDevice only puts a device on the broadcast list when its DeviceData says two-way at
--   that moment, and the clients register their own copy when the object arrives
--                                                  ZomboidRadio.java:936-947 -> that is why a
--   changed setting is a remove + add, never a state packet on the same object.
--   obj:transmitCompleteItemToClients()            IsoObject.java:4552-4560 (AddItemToMap)
--   square:transmitRemoveItemFromSquare(obj)       IsoGridSquare.java:6315-6362 ->
--                                                  GameServer.RemoveItemFromMap
--   chat pickup: a turned-on, two-way, unmuted device within getMicRange of the speaker relays
--   the spoken line on its channel with its own transmitRange
--                                                  ZomboidRadio.java:556-594 (client/SP loop:
--                                                  the speaking player's own client evaluates it)
--   HasPlayerInRange is also required there; on a client it is true whenever the device is on,
--   because playerWithinBounds compares with || and no finite coordinate can fail both halves,
--   and the device's own audible range starts at 5 + 15 * volume tiles
--                                                  IsoWaveSignal.java:259-264, 275-289 ;
--                                                  DeviceData.java:60, 875-877
--   power: canBePoweredHere() returns true immediately for a battery-powered device, and
--   update() only switches a device off when power ran out - useDelta 0 means it never does
--                                                  DeviceData.java:512-532, 761-800
--   setUseDelta stores f/60, setChannelRaw skips the bounds check and the RadioZap sound, and the
--   *Raw setters do not transmit a state packet (there is no client to answer at build time)
--                                                  DeviceData.java:502-511, 576-590
--
-- Security limits, stated plainly (no journal, no retry framework, no recovery store):
--   * a logged-in client may send device state packets (channel, volume, power, turned off) for a
--     world device; nothing in the engine locks that. The answer here is a bounded sweep that
--     puts the device back to the configured values, at most once per Rl.REPAIR_MS (30 s) per
--     square, plus an immediate sync on registration and on an admin setting change. Nothing
--     here runs on a chunk load, so loading and unloading a chunk is no client-driven way around
--     that rate limit.
--   * placing the device cannot be made atomic with the registration: the terminal may be
--     registered while the device fails. The registration result is reported as it happened and
--     carries warning = "radio_unavailable"; the sweep retries later.
--   * "active" is what this server can see locally: the object stands on the square and its
--     device data is what was asked for. It is not a delivery acknowledgement. The engine's own
--     publish path logs and discards its transport and serialisation errors and returns nothing
--     (IsoObject.java:4552-4559, INetworkPacket.java:59-74, 124-132), so nothing on this side
--     can turn a call that returned into proof that a client received the device.

if not MinidoracatEconomy or not MinidoracatEconomy.Radio then
    require "MinidoracatEconomy/ECRadio"
end
require "MinidoracatEconomy/ECTradeRadio"
local EC = MinidoracatEconomy
local S = EC and EC.Server
local Rd = EC and EC.Radio
local T = EC and EC.Terminal
local TR = EC and EC.TradeRadio
if not S or not S.AUTHORITY or not Rd or not T or not TR then
    return
end

EC.TradeRadioRelay = EC.TradeRadioRelay or {}
local Rl = EC.TradeRadioRelay

-- This mod's own speaker, four facings each in facing order S, E, N, W: one shaped for the
-- catgirl android (it sits on her shoulder) and one for a console (it sits on the machine's
-- upper edge). Both sets are built by scripts/build_tiles.py into MinidoracatEconomy.pack and
-- MinidoracatEconomy_tiles (tilesets 3 and 4) and carry no CustomItem and no moveable, solid or
-- surface property. The terminal tiles number their facings the same way, so the trailing index
-- carries over and the speaker faces the way the terminal does.
Rl.SPEAKERS = {
    catgirl = { "MinidoracatEconomy_speaker_catgirl_0", "MinidoracatEconomy_speaker_catgirl_1",
                "MinidoracatEconomy_speaker_catgirl_2", "MinidoracatEconomy_speaker_catgirl_3" },
    terminal = { "MinidoracatEconomy_speaker_terminal_0", "MinidoracatEconomy_speaker_terminal_1",
                 "MinidoracatEconomy_speaker_terminal_2", "MinidoracatEconomy_speaker_terminal_3" },
}
Rl.ITEM = "Base.HamRadio1"
Rl.MIC_RANGE = 5                 -- tiles; the engine compares int distance < micRange
Rl.VOLUME = 0.5                  -- device volume: 0 would mute the device and kill the relay
Rl.MIN_VOLUME = 0.05             -- below this the device counts as broken and is rebuilt
Rl.REPAIR_MS = 30000             -- slowest allowed rebuild rate per square (contract: >= 30 s)
Rl.SWEEP_MS = 1000               -- one sweep per real second
Rl.SWEEP_BUDGET = 8              -- registered squares examined per sweep (<= T.MAX per cycle)

local md = nil
local states = {}                -- "x,y,z" -> { state, at = ms, err, needsReplace = true|nil }
-- x -> y -> z -> terminal id (rebuilt on every registration change). Numbers, not the "x,y,z"
-- string: the orphan sweep looks a device's square up by the engine's own coordinates.
local coordIds = {}
local queue = {}                 -- the current sweep cycle, T.list() order
local queueAt = 1
local lastSweepAt = 0
local dirty = false              -- a reported state changed: push the terminal list once per sweep
local deviceAt = 0               -- orphan sweep cursor: 0-based index into ZomboidRadio.getDevices()
local scanAt = 0                 -- the entry the current orphan scan is reading
local noRadioLogged = false      -- "no ZomboidRadio instance" is logged once per init

local function key(x, y, z)
    return tostring(x) .. "," .. tostring(y) .. "," .. tostring(z)
end

-- `+ 0` turns a -0.0 into 0.0: ECTerminal's isInt accepts -0.0 and T.at compares with ==, so a
-- registration may carry one, while the engine's coordinates never do. The string key this
-- replaced matched the two as well (Kahlua's tostring drops the sign of an integral -0.0).
local function coordId(x, y, z)
    local byY = coordIds[x + 0]
    local byZ = byY and byY[y + 0]
    return byZ and byZ[z + 0]
end

local function record(k)
    local rec = states[k]
    if not rec then
        -- bounded memory: one record per registered terminal, never one per loaded square
        if EC.countKeys(states) >= T.MAX then return nil end
        rec = {}
        states[k] = rec
    end
    return rec
end

local function setState(k, state, err)
    local rec = record(k)
    if not rec then return state end
    if rec.state ~= state then dirty = true end
    rec.state = state
    rec.err = err
    return state
end

-- ---------- options ----------

local function relayOn() return Rd.relayEnabled() end

-- ---------- square helpers ----------
--
-- Nothing below swallows an engine error. Every public entry has exactly one pcall boundary and
-- turns a raised error into that square's "error" state with the engine's own text, because the
-- same failed read means a different wrong thing to each caller: an unreadable object list is
-- not an empty square (a second device would be added on top of the first), and an unreadable
-- sprite is not a demolished terminal (a working device would be deleted).

-- nil means the chunk is not loaded - the one absence that is normal here. A cell or a lookup
-- that raises is a failure and stays one.
local function squareAt(x, y, z)
    return getCell():getGridSquare(x, y, z)
end

-- Is `obj` still one of this square's objects? The engine's removal reports an index, and an
-- index is not proof that the object left the list.
local function onSquare(sq, obj)
    local objects = sq:getObjects()
    if objects == nil then error("trade radio: the square has no object list") end
    for i = 0, objects:size() - 1 do
        if objects:get(i) == obj then return true end
    end
    return false
end

-- The registered terminal tile that is actually standing on the square, by sprite name, or nil
-- when the entity is gone (demolished, or removed by something else). Same sprite set the
-- registration check uses, so the two can never disagree.
local function terminalSprite(sq)
    local objects = sq:getObjects()
    -- a loaded square always has a list; no list is a failure, not "the terminal is gone"
    if objects == nil then error("trade radio: the square has no object list") end
    for i = 0, objects:size() - 1 do
        local o = objects:get(i)
        local sprite = o and o:getSprite()
        local name = sprite and sprite:getName()
        if name and EC.TERMINAL_SPRITES[name] then return name end
    end
    return nil
end

-- The speaker sprite for a terminal: the catgirl set for the catgirl android, the machine set for
-- every other registered tile (this mod's own console and the vanilla "Terminal" consoles), and
-- the facing from the trailing index modulo four - every tile set numbers its four facings in the
-- same order (terminal_0..3, catgirl_0..3, appliances_com_01_52..55, security_01_0..3).
--
-- There is no fallback: a name this does not recognise is a machine facing S, and a sprite that
-- is not loaded makes the build fail loudly (createRadio). Returning the old ham set or nothing
-- would either put the large radio back on the tile or publish an invisible device.
function Rl.radioSprite(terminalSpriteName)
    local index = 0
    local set = Rl.SPEAKERS.terminal
    if type(terminalSpriteName) == "string" then
        local digits = string.match(terminalSpriteName, "_(%d+)$")
        local n = tonumber(digits)
        if n then index = math.floor(n) % 4 end
        if string.find(terminalSpriteName, "^MinidoracatEconomy_catgirl") then
            set = Rl.SPEAKERS.catgirl
        end
    end
    return set[index + 1]
end

-- ---------- device data ----------

-- Every field the relay depends on, written before the object joins the world: an added object is
-- registered as a broadcast device by the engine using the values it has at that moment. The
-- device name is the ownership tag itself (see ECTradeRadio): it is written here, with the rest
-- of the device data, and saved with the object.
local function applyDeviceData(data, freq, range)
    data:setDeviceName(TR.NAME)        -- ownership, and the only thing that decides it
    data:setIsTwoWay(true)             -- the microphone half; also what RegisterDevice checks
    data:setIsPortable(false)          -- a world device, not an equipped walkie-talkie
    data:setIsTelevision(false)
    data:setNoTransmit(false)
    data:setMinChannelRange(freq)      -- min = max = the market frequency: it cannot be retuned
    data:setMaxChannelRange(freq)      -- by a legitimate setChannel, which honours these bounds
    data:setChannelRaw(freq)
    data:setTransmitRange(range)
    data:setMicRange(Rl.MIC_RANGE)
    data:setMicIsMuted(false)
    data:setIsBatteryPowered(true)     -- power is decided by getPower alone for a battery device
    data:setHasBattery(false)          -- no physical battery: nothing to take out of it
    data:setPower(1)
    data:setUseDelta(0)                -- and it never drains, so it never switches itself off
    data:setDeviceVolumeRaw(Rl.VOLUME)
    data:setTurnedOnRaw(true)
end

-- Relay-critical settings and minimum usable power/volume; a failed check requires rebuilding.
local function deviceOk(data, freq, range)
    if data == nil then return false end
    if not data:getIsTwoWay() then return false end
    if data:getIsPortable() then return false end
    if data:getIsTelevision() then return false end
    if data:isNoTransmit() then return false end
    if data:getChannel() ~= freq then return false end
    if data:getMinChannelRange() ~= freq or data:getMaxChannelRange() ~= freq then return false end
    if data:getTransmitRange() ~= range then return false end
    if data:getMicRange() ~= Rl.MIC_RANGE then return false end
    if data:getMicIsMuted() then return false end
    if not data:getIsBatteryPowered() then return false end
    if data:getHasBattery() then return false end
    if not (data:getPower() > 0) then return false end
    if data:getUseDelta() > 0 then return false end
    if not (data:getDeviceVolume() > Rl.MIN_VOLUME) then return false end
    if not data:getIsTurnedOn() then return false end
    return true
end

-- ---------- world object ----------

-- Takes the one verified companion out of the world. Raises on every failure, so no caller can
-- add a second device, report "disabled", or call a square healthy while a device it wanted gone
-- is still standing.
--
-- safelyRemove = false is deliberate and load-bearing. The default overload expands a
-- multi-square sprite and deletes every tile of it (IsoGridSquare.java:6319-6357 ->
-- IsoObjectUtils.getAllMultiTileObjects), and that expansion matches by sprite alone: it never
-- looks at IsoRadio or at the device name this mod decides ownership by. A client can change a
-- world object's sprite (GameServer.java:1879-1907), so with the default overload a normal radio
-- or a piece of furniture on a neighbouring grid member would be deleted along with the
-- companion, and an incomplete grid would return -1 having removed nothing. Both halves were
-- reproduced on the real jar (Main's native-removal-proof.json): the default deletes the plain
-- grid member, this overload does not, and removing an object that is not in the list returns -1.
local function removeRadio(sq, obj)
    local index = sq:transmitRemoveItemFromSquare(obj, false)
    if type(index) ~= "number" or index < 0 then
        error("trade radio: the engine removed nothing (index " .. tostring(index) .. ")")
    end
    if onSquare(sq, obj) then
        error("trade radio: the device is still on the square after its removal")
    end
    sq:RecalcProperties()
    sq:RecalcAllWithNeighbours(true)
end

-- Builds, configures and publishes one device. Returns the object, or nil plus the engine's own
-- error text plus `incomplete` = true when something of ours is known to be left behind.
--
-- AddSpecialObject puts the object into the square's two lists before it calls addToWorld and
-- the recalculations (IsoGridSquare.java:6189-6224), so a failure after that point leaves a real
-- object standing that never reached ZomboidRadio.RegisterDevice and never reached the clients.
-- The catch therefore asks the square what is actually there instead of trusting how far the
-- call got; when the leftover cannot be taken back out, `incomplete` tells the caller that the
-- next pass has to replace it instead of reading its (perfectly correct) device data and
-- calling the square active.
local function createRadio(sq, terminalSpriteName, freq, range)
    local spriteName = Rl.radioSprite(terminalSpriteName)
    local obj = nil
    local ok, err = pcall(function()
        local sprite = getSprite(spriteName)
        -- getSprite also creates empty placeholders (IsoSpriteManager.java:47-48,77-81).
        -- Require our loaded tiledef metadata, not merely a non-nil sprite with the right name.
        local props = sprite and sprite:getProperties()
        if not props or props:get("GroupName") ~= "Economy" or props:get("CustomName") ~= "Economy Speaker" then
            error("speaker tiledef " .. tostring(spriteName) .. " not loaded")
        end
        obj = IsoRadio.new(getCell(), sq, sprite)
        -- explicit clone, and a clone that failed is a failure: the contract is a real
        -- Base.HamRadio1 device, not whatever the constructor happened to leave on the object.
        -- The object's own name field is deliberately left alone - it is player-writable
        -- (ECTradeRadio header).
        local data = obj:cloneDeviceDataFromItem(Rl.ITEM)
        if data == nil then error("could not clone the device data of " .. tostring(Rl.ITEM)) end
        obj:setDeviceData(data)
        applyDeviceData(obj:getDeviceData(), freq, range)
        sq:AddSpecialObject(obj)
        obj:transmitCompleteItemToClients()
        sq:RecalcProperties()
        sq:RecalcAllWithNeighbours(true)
    end)
    if ok then
        return obj, nil
    end
    if obj == nil then return nil, tostring(err) end
    local readable, present = pcall(onSquare, sq, obj)
    if not readable then
        return nil, tostring(err) .. "; the square could not be read back: " .. tostring(present), true
    end
    if present ~= true then return nil, tostring(err) end
    local cleaned, cleanErr = pcall(removeRadio, sq, obj)
    if not cleaned then
        return nil, tostring(err) .. "; the half-built device could not be removed: " .. tostring(cleanErr), true
    end
    return nil, tostring(err)
end

-- ---------- sync ----------

local function clearLoadedSquare(sq)
    if sq == nil then return end
    for _, o in ipairs(TR.ownedOnSquare(sq)) do removeRadio(sq, o) end
end

-- Drops every owned radio from a square that must not carry one. Used for an unregistered
-- square, a kind change and the relay being switched off. Returns
-- true only when the square is verified clear - a genuinely unloaded chunk counts, because it
-- holds nothing the caller can act on - or false plus the engine's own text. A read or a removal
-- that raised is never reported as "there was nothing there".
function Rl.clearSquare(x, y, z)
    local ok, err = pcall(function()
        clearLoadedSquare(squareAt(x, y, z))
    end)
    if not ok then
        EC.log("trade radio: could not clear " .. key(x, y, z) .. ": " .. tostring(err))
        return false, tostring(err)
    end
    return true
end

-- One square's sync. Raises on any engine failure; Rl.syncSquare is the boundary that catches it.
local function sync(t, k, force)
    local sq = squareAt(t.x, t.y, t.z)
    if sq == nil then
        -- an unloaded chunk is not a failure and not a reason to hold the chunk in memory
        return setState(k, relayOn() and t.kind == "trade" and "waiting" or "disabled")
    end
    local owned = TR.ownedOnSquare(sq)
    local sprite = terminalSprite(sq)
    if t.kind ~= "trade" or not relayOn() or sprite == nil then
        -- Wanted state is "no device here": an ATM, the relay switched off, or a registration
        -- whose physical terminal is gone. Loaded owned devices go, including while disabled,
        -- and one that will not go is what this square reports - a square that still carries a
        -- listening device must never answer "disabled".
        for _, o in ipairs(owned) do removeRadio(sq, o) end
        if t.kind ~= "trade" or not relayOn() then return setState(k, "disabled") end
        return setState(k, "waiting", "no terminal object")
    end

    -- A device is wanted here, so the operation guards are the precondition for having one. With
    -- the vanilla moveable and device entry points unwrapped, a player picks the device up, gets
    -- a real ham radio item out of it and the sweep puts another one down: a repeatable free
    -- item source, which is worse than having no relay at all. Retried on every pass because
    -- installGuards is idempotent and its failure can be a load order accident.
    local protected, guardErr = TR.installGuards()
    if not protected then
        for _, o in ipairs(owned) do removeRadio(sq, o) end
        return setState(k, "error", "operation guards unavailable: " .. tostring(guardErr))
    end

    local freq, range = Rd.frequency(), Rd.nativeRange()
    -- duplicates: one device per square, extras are removed whatever created them
    for i = 2, #owned do removeRadio(sq, owned[i]) end
    local rec = record(k)
    local obj = owned[1]
    if obj ~= nil then
        -- needsReplace: an earlier build left this object behind without finishing it. Its
        -- device data can be exactly right and the object can still never have reached
        -- RegisterDevice or the clients, so the data check is not allowed to clear that.
        local appearance = obj:getSprite()
        if not (rec and rec.needsReplace) and appearance
            and appearance:getName() == Rl.radioSprite(sprite)
            and deviceOk(obj:getDeviceData(), freq, range) then
            return setState(k, "active")
        end
        if not force and rec and rec.at and EC.now() - rec.at < Rl.REPAIR_MS then
            return setState(k, rec.state == "error" and "error" or "waiting", rec.err)
        end
        -- a setting change or a repair is always remove + add: re-sending the add packet for the
        -- same object is not an update, and the clients only register a device when it arrives
        removeRadio(sq, obj)
    end

    if not force and rec and rec.at and EC.now() - rec.at < Rl.REPAIR_MS then
        return setState(k, rec.state == "error" and "error" or "waiting", rec.err)
    end
    if rec then rec.at = EC.now() end   -- stamped before the attempt: a failing build is throttled too
    local created, err, incomplete = createRadio(sq, sprite, freq, range)
    if not created then
        if rec then rec.needsReplace = incomplete == true or nil end
        EC.log("trade radio: could not attach a device at " .. k .. ": " .. tostring(err))
        return setState(k, "error", err)
    end
    if rec then rec.needsReplace = nil end
    return setState(k, "active")
end

-- The one entry every path goes through. `force` skips the repair throttle (registration and
-- admin setting changes are allowed to act at once; the tick sweep is not).
-- Returns the square's state: "active" | "waiting" | "error" | "disabled". "active" means the
-- device stands here configured as asked - see the header: not that anybody was heard, and not
-- that every client received it.
function Rl.syncSquare(t, force)
    if type(t) ~= "table" then return nil end
    local k = key(t.x, t.y, t.z)
    local ok, state = pcall(sync, t, k, force)
    if ok then return state end
    EC.log("trade radio: sync failed at " .. k .. ": " .. tostring(state))
    return setState(k, "error", tostring(state))
end

-- Sweeps every registered terminal once. Used by registration changes and by radio setting
-- changes, so a change reaches the already loaded devices without anybody reconnecting. Returns
-- true, or false plus the first failure's own text. An unloaded chunk is "waiting", not a
-- failure: nothing is wrong with it and nothing can be done about it from here.
function Rl.syncAll(force)
    if not md then return false, "the relay is not initialised" end
    local err = nil
    for _, t in pairs(md.terminals) do
        if Rl.syncSquare(t, force) == "error" and err == nil then
            local rec = states[key(t.x, t.y, t.z)]
            err = rec and rec.err or "sync failed"
        end
    end
    if err ~= nil then return false, tostring(err) end
    return true
end

local function rebuildCoords()
    coordIds = {}
    if not md then return end
    for id, t in pairs(md.terminals) do
        local x, y = t.x + 0, t.y + 0
        local byY = coordIds[x]
        if byY == nil then byY = {}; coordIds[x] = byY end
        local byZ = byY[y]
        if byZ == nil then byZ = {}; byY[y] = byZ end
        byZ[t.z + 0] = id
    end
end

-- Registration changed (register / unregister / demolish). The touched square is handled at
-- once; the returned state is what the registration reply reports.
function Rl.onTerminalsChanged(x, y, z)
    if not md then return nil end
    rebuildCoords()
    if x == nil then return nil end
    local k = key(x, y, z)
    local id = coordId(x, y, z)
    if id and md.terminals[id] then return Rl.syncSquare(md.terminals[id], true) end
    -- No registration here any more. The state record is this square's only entry in the
    -- bounded sweep, so it is dropped only once the square really is clear. ECTerminal refuses
    -- to give up a registration whose device would not go, so arriving here with a leftover
    -- means a race, and the orphan sweep over the engine's device registry is what collects it.
    local cleared, err = Rl.clearSquare(x, y, z)
    if not cleared then return setState(k, "error", err) end
    states[k] = nil
    return nil
end

-- An admin changed a radio setting: frequency, range, or the relay switch itself. Returns true,
-- or false plus the reason, so the settings page can say the value was stored and the devices
-- standing in the world were not reached.
function Rl.onConfigChanged()
    if not md then return false, "the relay is not initialised" end
    return Rl.syncAll(true)
end

-- What the terminal list reports for a trade terminal. Never "already heard by somebody": it is
-- the placement state of this uptime.
function Rl.state(x, y, z)
    local rec = states[key(x, y, z)]
    if rec and rec.state then return rec.state end
    if not relayOn() then return "disabled" end
    return "waiting"
end

-- ---------- orphan sweep ----------
--
-- An orphan is an owned device on a square nobody registered any more (a world rollback: Global
-- ModData goes back, the chunk does not). It is found through the engine's own device registry,
-- not through a chunk-load hook: every world radio and TV joins ZomboidRadio.devices when it is
-- added to the world and leaves it when it is removed or its chunk unloads
-- (IsoWaveSignal.java:332-352 -> ZomboidRadio.RegisterDevice/UnRegisterDevice :936-958; chunk
-- load IsoChunk.java:3800-3803, unload :3244-3247 -> IsoObject.removeFromWorldToMeta :4527-4534;
-- removal RemoveItemFromSquarePacket.java:173), and vehicle radio parts do the same
-- (VehicleParts.java:415-440). A device a chunk load brings in is appended at the end of the list
-- (ArrayList.add), so a cursor walking to the end always reaches it.
--
-- Cost: LoadGridsquare fired a Lua call, a pcall and three or more Java calls for every square
-- with objects of every chunk load (IsoChunk.java:3796-3835) - 10^5 to 10^6 squares in a load
-- spike, and 2.1% of the production main thread on 2026-09-28. This reads at most ORPHAN_BUDGET
-- registry entries per tick: get + instanceof, plus getDeviceData + getDeviceName for an IsoRadio,
-- so at most 3 + 4 * 32 Java calls a tick whatever the players load (an owned device adds its
-- square and coordinates, and its removal - both rare). A full cycle over N devices
-- takes ceil(N / 32) ticks: at the dedicated server's 10 ticks a second (GameServer.java:229, 826)
-- 2,000 devices are covered in under 7 s, and a new orphan is removed at most one cycle after its
-- chunk loaded.
Rl.ORPHAN_BUDGET = 32

-- The scan half: read only, and it raises on the first getter that fails. The class is checked
-- first and never the sprite (TR.isOwned): a client can give any object any sprite
-- (GameServer.java:1879-1907), not another class, so a TV and a vehicle part end at instanceof.
-- scanAt is module state so the caller knows which entry raised.
local function scanDevices(radio, out)
    local devices = radio:getDevices()                -- ZomboidRadio.java:123-125, the live list
    local size = devices:size()
    if deviceAt >= size then deviceAt = 0 end          -- a cycle ended (or the list shrank): start over
    scanAt = deviceAt
    local stop = math.min(size, deviceAt + Rl.ORPHAN_BUDGET)
    while scanAt < stop do
        local o = devices:get(scanAt)
        if TR.isOwned(o) then
            local sq = o:getSquare()                   -- IsoObject.java:1006-1008
            if sq == nil then error("trade radio: a registered device has no square") end
            local x, y, z = sq:getX(), sq:getY(), sq:getZ()
            local id = coordId(x, y, z)
            -- a registered square belongs to the registered sweep, duplicates and all
            if not (id and md.terminals[id]) then out[#out + 1] = { obj = o, sq = sq, k = key(x, y, z) } end
        end
        scanAt = scanAt + 1
    end
end

-- The registry says the device is in the world; its square has to say so too before anything is
-- removed, and an unreadable object list is a failure, not an empty square.
local function removeOrphan(sq, obj)
    if not onSquare(sq, obj) then error("trade radio: the device is not on its square") end
    removeRadio(sq, obj)
end

-- One slice per tick. Orphans are collected first and removed after the scan: a removal
-- unregisters the device and shifts the list under the cursor, and a getter that raises aborts
-- the slice before anything in it is removed. A vanilla device is never touched, and an orphan
-- that is not removed stays in the list, so the next cycle finds it again.
-- ponytail: a getter that raises on every read blocks the orphans scanned ahead of it in the
-- same slice until the list shifts (any chunk load or unload does); skip the bad entry by
-- identity if that ever shows up in the logs.
local function sweepOrphans()
    local radio = getZomboidRadio()                    -- nil without an instance: LuaManager.java:2909-2911
    if radio == nil then
        if not noRadioLogged then
            noRadioLogged = true
            EC.log("trade radio: no ZomboidRadio instance, the orphan sweep waits for one")
        end
        return
    end
    local orphans = {}
    scanAt = deviceAt
    local ok, err = pcall(scanDevices, radio, orphans)
    if not ok then
        EC.log("trade radio: orphan sweep could not read registry entry " .. tostring(scanAt) .. ": " .. tostring(err))
        deviceAt = scanAt + 1
        return
    end
    deviceAt = scanAt
    for _, f in ipairs(orphans) do
        local removed, removeErr = pcall(removeOrphan, f.sq, f.obj)
        if removed then
            deviceAt = deviceAt - 1   -- it left the list behind the cursor: what follows moved down one
        else
            EC.log("trade radio: could not remove the orphan at " .. f.k .. ": " .. tostring(removeErr))
        end
    end
end

-- ---------- tick ----------

-- Bounded rotating sweep: at most SWEEP_BUDGET registered squares per second, so a full cycle
-- over the 200 terminals a server may register costs 25 seconds of one small square lookup each.
-- That is also the longest a registered device waits to come up after its chunk loaded: 25 s,
-- plus Rl.REPAIR_MS when an earlier attempt on that square failed. Unloaded squares cost a nil
-- lookup and are left alone. The orphan sweep runs first, every tick, on its own budget.
function Rl.onTick()
    if not md then return end
    sweepOrphans()
    local now = EC.now()
    if now - lastSweepAt < Rl.SWEEP_MS then return end
    lastSweepAt = now
    if queueAt > #queue then
        queue = T.list()
        queueAt = 1
        -- prune the state of terminals that no longer exist, once per cycle
        local live = {}
        for _, t in ipairs(queue) do live[key(t.x, t.y, t.z)] = true end
        for k in pairs(states) do
            if not live[k] then states[k] = nil end
        end
    end
    local n = 0
    while queueAt <= #queue and n < Rl.SWEEP_BUDGET do
        local t = queue[queueAt]
        queueAt = queueAt + 1
        n = n + 1
        local entry = t.id and md.terminals[t.id] or nil   -- unregistered mid-cycle: skip it
        if entry then Rl.syncSquare(entry, false) end
    end
    -- A state that changed outside a registration change - a repair, a failure -
    -- would otherwise only reach a client on hello or on its next request, so an open window
    -- would show the old state indefinitely. One aggregated push per sweep second through the
    -- list every other caller already sends: not one broadcast per square, and no new command.
    if dirty then
        dirty = false
        local pushed, pushErr = pcall(T.pushList)
        if not pushed then EC.log("trade radio: terminal list push failed: " .. tostring(pushErr)) end
    end
end

function Rl.init(root)
    md = root
    md.terminals = md.terminals or {}
    states = {}
    queue = {}
    queueAt = 1
    lastSweepAt = 0
    dirty = false
    deviceAt = 0
    noRadioLogged = false
    rebuildCoords()
    -- boot: most chunks are not loaded yet, so this mostly records "waiting" and costs one
    -- square lookup per registered terminal. The two sweeps do the rest.
    Rl.syncAll(true)
    EC.log("trade radio relay: " .. (relayOn() and "on" or "off")
        .. ", " .. tostring(EC.countKeys(md.terminals)) .. " terminals, range "
        .. tostring(Rd.nativeRange()) .. ", guards "
        .. (TR.guardsInstalled() and "installed" or "MISSING"))
end

S.TradeRadio = Rl
S.onInit(Rl.init)
Events.OnTickEvenPaused.Add(Rl.onTick)
return Rl
