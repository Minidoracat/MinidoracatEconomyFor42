-- MinidoracatEconomyFor42 - places to trade on the maps (client only; nothing saved or sent).
--
-- With MinidoracatMiniMap (its docs/addon-api.md 3.14, markerApiVersion >= 1): one marker provider
-- draws every registered terminal and every known map ATM on its minimap and world map, and the
-- navigation target once more on top, larger, ringed (v2) and labelled with its way.
-- Without it: only the navigation target, as a vanilla map marker on the world map and on the
-- vanilla minimap. Each UIWorldMap keeps its own markers in memory (UIWorldMap.java:68, 190;
-- WorldMapMarkersV1.java:19-35 via UIWorldMapV1.getMarkersAPI :54-60) and the two maps are separate
-- instances (ISWorldMap.lua:267, ISMiniMap.lua:191), so one marker goes on each map that exists,
-- placed when it appears and removed (ours only) when navigation ends. Precedent ISWorldMap.lua:1456-1457.
-- Never the Symbols API: those symbols are written to the player's map_symbols.bin
-- (terminal-radio.md, user ruling 2026-10-05).

require "MinidoracatEconomy/ECNavigate"

local EC = MinidoracatEconomy
local C = EC.Client
local N = C.Navigate

local M = {}
C.NavMarkers = M

M.OWNER = "MinidoracatEconomyFor42"
local TERMINAL_TEX = "media/ui/MinidoracatEconomy/terminal_icon.png"
local ATM_TEX = "media/ui/MinidoracatUI/mui_art_coins.png"
local BADGE_TEX = "media/ui/MinidoracatUI/mui_dot.png"
local FOCUS_SCALE = 1.75
local VANILLA_RADIUS = 3       -- squares; the engine draws at least 64 px (WorldMapGridSquareMarker.java:21-22)

-- ---------- MiniMap provider ----------

local textures = {}
local function texture(path)
    local t = textures[path]
    if t == nil then
        t = getTexture(path) or false
        textures[path] = t
    end
    return t or nil
end

local function v2()
    local API = MinidoracatMiniMapAPI
    return API ~= nil and type(API.markerApiVersion) == "number" and API.markerApiVersion >= 2
end

M.out = { revision = 0, markers = {} }
local built = {}           -- what M.out was built from: list, target, label

-- Every candidate, then the target as its own marker on top (drawn after, so it covers its place).
function M.build(list, target)
    local markers = {}
    for i, t in ipairs(list) do
        local atm = t.kind == N.MAP_ATM
        markers[#markers + 1] = { id = atm and ("atm" .. i) or ("t:" .. tostring(t.id)), x = t.x + 0.5, y = t.y + 0.5,
            texture = texture(atm and ATM_TEX or TERMINAL_TEX), state = "live" }
    end
    local focus = nil
    if target ~= nil then
        focus = { id = "target", x = target.x + 0.5, y = target.y + 0.5,
            texture = texture(target.kind == N.MAP_ATM and ATM_TEX or TERMINAL_TEX), state = "live" }
        local badge = v2() and texture(BADGE_TEX)
        if badge then
            focus.scale = FOCUS_SCALE
            focus.badge = { texture = badge, r = 0.06, g = 0.06, b = 0.07, a = 0.92 }
            focus.ring = { r = 1, g = 0.85, b = 0.4, a = 1 }   -- the arrow's colour (ECNavigate placeArrow)
            focus.labelColor = { r = 1, g = 0.85, b = 0.4 }
        end
        markers[#markers + 1] = focus
    end
    M.out = { revision = M.out.revision + 1, markers = markers }
    M.focus = focus
end

-- providerFn(playerNum, surface): every frame, so the table is rebuilt only when the candidates or
-- the target change; the target's label (its way, refreshed by ECNavigate) is set in place.
function M.provider(playerNum)
    if playerNum ~= 0 then return nil end      -- ECNavigate follows getPlayer(), the first player
    local list, target = N.candidates(), N.target
    local label = target ~= nil and N.trackWhere or nil
    if built.list ~= list or built.target ~= target then
        M.build(list, target)
        built.list, built.target, built.label = list, target, nil
    end
    if built.label ~= label then
        built.label = label
        if M.focus then M.focus.label = label end
        M.out.revision = M.out.revision + 1
    end
    return M.out
end

-- ---------- vanilla fallback: the target only ----------

M.placed = {}              -- { {api, markers, marker}, ... }: our markers, one per map instance
local placedTarget = nil

local function clearVanilla()
    for i = #M.placed, 1, -1 do
        local p = M.placed[i]
        p.markers:removeMarker(p.marker)
        M.placed[i] = nil
    end
    placedTarget = nil
end

local function mark(api, t)
    if api == nil then return end
    for _, p in ipairs(M.placed) do
        if p.api == api then return end
    end
    local markers = api:getMarkersAPI()
    M.placed[#M.placed + 1] = { api = api, markers = markers,
        marker = markers:addGridSquareMarker(t.x, t.y, VANILLA_RADIUS, 1, 0.85, 0.4, 1) }
end

-- Per tick, allocation-free while nothing changes: a new or finished target, or a map that was
-- opened (the world map is built on first open, ISWorldMap.ShowWorldMap; the minimap may be rebuilt,
-- ISMiniMap.lua:779-780).
function M.tick()
    if M.registered then return end
    local t = N.target
    if t ~= placedTarget then clearVanilla() end
    if t == nil then return end
    placedTarget = t
    mark(ISWorldMap_instance and ISWorldMap_instance.mapAPI, t)
    local mini = getPlayerMiniMap and getPlayerMiniMap(0)
    mark(mini and mini.inner and mini.inner.mapAPI, t)
end
Events.OnTick.Add(M.tick)

-- MiniMap is not a require of this mod, so its API is looked up once every client file has loaded.
function M.register()
    M.placed, placedTarget, built = {}, nil, {}
    if M.registered then return end
    local API = MinidoracatMiniMapAPI
    if API and type(API.markerApiVersion) == "number" and API.markerApiVersion >= 1
        and type(API.registerMarkerProvider) == "function" then
        API.registerMarkerProvider(M.OWNER, M.provider)
        M.registered = true
        EC.log("map markers: MiniMap marker provider registered")
    else
        EC.log("map markers: no MiniMap marker API; the navigation target is marked on the vanilla maps")
    end
end
Events.OnGameStart.Add(M.register)

return M
