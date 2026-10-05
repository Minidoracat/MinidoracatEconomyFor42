-- MinidoracatEconomyFor42 - "take me to the nearest terminal" (client only).
--
-- Picks the nearest place the player can trade at, names it as a compass direction and a distance,
-- and on request points the vanilla direction arrow at it until the player is within trading range.
-- Nothing here is saved, sent or written to the player's map: the arrow lives in this client's
-- memory only, and whether a trade is allowed is still the server's call (ECTerminal.near).
--
-- Engine references (snapshot 42.20.4-20260826; .claude/skills/economy-dev/references/api-sources.md):
--   getWorldMarkers():addDirectionArrow(player, x, y, z, texname, r, g, b, a)
--                     LuaManager.java:11514-11520, WorldMarkers.java:181-201 - per player index,
--                     texname nil = media/textures/highlights/dir_arrow_up; arrow:remove() at :768-790
--   floors            WorldMarkers.java:301 draws the stairs-up glyph for a target downstairs too,
--                     so the words say upstairs / downstairs, never the arrow
--   world exit        IngameState.java:908 clears every arrow; OnGameStart drops our handle to it

require "MinidoracatEconomy/ECClient"

local EC = MinidoracatEconomy
local C = EC.Client

local N = {}
C.Navigate = N

local T = "IGUI_MinidoracatEconomy_"
local FLOOR_TILES = 6        -- one floor of height counts as this many tiles when ranking
local REFRESH_MS = 500       -- distance / direction refresh while navigating, and the hint cache
local MOVE_TILES = 2         -- ...or sooner, once the player moved this far
local TAN_22_5 = 0.41421356  -- the 8-way sector edge: |minor axis| < tan(22.5) * |major axis|

-- Where the player could go: { {x, y, z, kind, id}, ... }: the registered terminals, then (sandbox
-- MapATMAsTerminal on) the map ATMs the server has seen (C.mapAtms, kind "map_atm", no id) minus
-- the ones this client found gone. The same table until one of those inputs changes.
N.MAP_ATM = "map_atm"
N.stale = {}          -- "x,y,z" = true: a map ATM whose square this client loaded without one
N.staleRev = 0
local EMPTY = {}
local merged = { list = EMPTY }
function N.candidates()
    local terminals, atms, on = C.terminals or EMPTY, C.mapAtms or EMPTY, EC.mapAtmEnabled()
    if merged.terminals == terminals and merged.atms == atms and merged.on == on and merged.rev == N.staleRev then
        return merged.list
    end
    local list = {}
    for _, t in ipairs(terminals) do list[#list + 1] = t end
    if on then
        for _, a in ipairs(atms) do
            if not N.stale[a.x .. "," .. a.y .. "," .. a.z] then list[#list + 1] = a end
        end
    end
    merged.terminals, merged.atms, merged.on, merged.rev, merged.list = terminals, atms, on, N.staleRev, list
    return list
end

-- A map ATM whose square is loaded here and carries no ATM (taken down since the server saw it,
-- which the server cannot tell; ECAtmMap): dropped for this session. An unloaded square says nothing.
local function gone(t)
    if t.kind ~= N.MAP_ATM then return false end
    local cell = getCell()
    local sq = cell and cell:getGridSquare(t.x, t.y, t.z)
    if sq == nil or sq:getObjects():size() == 0 or EC.isAtmSquare(sq) then return false end
    N.stale[t.x .. "," .. t.y .. "," .. t.z] = true
    N.staleRev = N.staleRev + 1
    return true
end

local function isAtm(t) return t.kind == N.MAP_ATM end

local function sameTarget(a, b)
    if a.id ~= nil or b.id ~= nil then return a.id == b.id end
    return a.x == b.x and a.y == b.y and a.z == b.z
end

-- 8-way compass from world deltas: north is -y, east is +x (the isometric screen's top is NW).
local function dirKey(dx, dy)
    local ax, ay = math.abs(dx), math.abs(dy)
    if ax < ay * TAN_22_5 then return dy < 0 and "N" or "S" end
    if ay < ax * TAN_22_5 then return dx < 0 and "W" or "E" end
    return (dy < 0 and "N" or "S") .. (dx < 0 and "W" or "E")
end

-- One candidate as seen from the player: whole-tile 2D distance, direction and floor difference.
function N.measure(t, player)
    local dx, dy = t.x + 0.5 - player:getX(), t.y + 0.5 - player:getY()
    local dz = (tonumber(t.z) or 0) - math.floor(player:getZ())
    return { x = t.x, y = t.y, z = t.z, kind = t.kind, id = t.id, dz = dz,
        dist = math.floor(math.sqrt(dx * dx + dy * dy) + 0.5), dirKey = dirKey(dx, dy) }
end

local function rank(info) return info.dist + FLOOR_TILES * math.abs(info.dz) end

-- "NW 120 tiles (upstairs)" in the player's language.
function N.where(info)
    local key = info.dz > 0 and "Nav_WhereUp" or info.dz < 0 and "Nav_WhereDown" or "Nav_Where"
    return getText(T .. key, getText(T .. "Nav_Dir_" .. info.dirKey), tostring(info.dist))
end

local cache = { at = -1 }

-- The nearest candidate, or nil. Kept for REFRESH_MS (a new candidate list or player drops it), so
-- a page may ask every frame. A nearest map ATM this client sees gone is dropped and the next one
-- taken.
function N.nearest()
    local player = getPlayer()
    if not player then return nil end
    local list, now = N.candidates(), EC.now()
    if cache.list == list and cache.player == player and now - cache.at < REFRESH_MS then return cache.info end
    local best
    repeat
        list, best = N.candidates(), nil
        for _, t in ipairs(list) do
            local info = N.measure(t, player)
            if best == nil or rank(info) < rank(best) then best = info end
        end
    until best == nil or not gone(best)
    cache.list, cache.player, cache.at, cache.info = list, player, now, best
    cache.hint = best and getText(T .. (isAtm(best) and "Nav_HintAtm" or "Nav_Hint"), N.where(best)) or nil
    return best
end

-- "Nearest terminal: 120 tiles northwest, upstairs" (or "Nearest ATM: ..."), or nil when there is none.
function N.hintText()
    N.nearest()
    return cache.hint
end

-- A location refusal plus the way to the nearest terminal; unchanged when there is none. The last
-- answer is kept, so a gate read every frame builds no new string.
function N.withHint(text)
    local hint = N.hintText()
    if hint == nil then return text end
    if cache.withIn ~= text or cache.withHint ~= hint then
        cache.withIn, cache.withHint = text, hint
        cache.withOut = getText(T .. "Nav_WithHint", text, hint)
    end
    return cache.withOut
end

-- ---------- the arrow ----------

local function dropArrow()
    if N.arrow ~= nil then N.arrow:remove() end
    N.arrow, N.arrowPlayer = nil, nil
end

local function placeArrow()
    dropArrow()
    local player, t = getPlayer(), N.target
    if not player or player:isDead() or t == nil then return end
    N.arrow = getWorldMarkers():addDirectionArrow(player, t.x, t.y, t.z, nil, 1, 0.85, 0.4, 1)
    N.arrowPlayer = player
end

local function refresh()
    local player = getPlayer()
    if not player then return end
    N.track = N.measure(N.target, player)
    N.trackWhere = N.where(N.track)
    N.trackText = getText(T .. (isAtm(N.target) and "Nav_TargetAtm" or "Nav_Target"), N.trackWhere)
    N.lastAt, N.lastX, N.lastY = EC.now(), player:getX(), player:getY()
end

function N.active() return N.target ~= nil end

-- The target as the location row names it: "Terminal: 86 tiles northwest" / "ATM: ...", or nil.
function N.targetText() return N.target ~= nil and N.trackText or nil end

-- The toast for a window refused away from a terminal, once `target` is being navigated to.
function N.refusalText(target)
    return getText(T .. (isAtm(target) and "Toast_NeedTerminalNavAtm" or "Toast_NeedTerminalNav"), N.where(target))
end

-- Points the arrow at `target` ({x, y, z, kind?, id?}; default the nearest). false = nowhere to go.
function N.start(target)
    target = target or N.nearest()
    if target == nil then return false end
    N.target = { x = target.x, y = target.y, z = target.z, kind = target.kind, id = target.id }
    placeArrow()
    refresh()
    return true
end

function N.stop()
    dropArrow()
    N.target, N.track, N.trackText, N.trackWhere = nil, nil, nil, nil
end

-- Whether the target is still one of the candidates (an admin may have unregistered it).
local function stillThere()
    for _, t in ipairs(N.candidates()) do
        if sameTarget(t, N.target) then return true end
    end
    return false
end

local function onTick()
    if N.target == nil then return end
    local player = getPlayer()
    if not player then return end
    if player:isDead() then
        if N.arrow ~= nil then dropArrow() end
        return
    end
    -- a respawn is a new player object: its arrow is a new one too
    if N.arrowPlayer ~= player then placeArrow() end
    local moved = math.abs(player:getX() - N.lastX) + math.abs(player:getY() - N.lastY)
    if EC.now() - N.lastAt < REFRESH_MS and moved < MOVE_TILES then return end
    if C.nearTerminal() then
        local atm = isAtm(N.target)
        N.stop()
        C.toast(getText(T .. (atm and "Nav_ArrivedAtm" or "Nav_Arrived")))
        return
    end
    if gone(N.target) or not stillThere() then
        local atm = isAtm(N.target)
        N.stop()
        local nearest = N.nearest()
        if nearest ~= nil and N.start(nearest) then
            C.toast(getText(T .. (atm and "Nav_RetargetAtm" or "Nav_Retarget"), cache.hint))
        else
            C.toast(getText(T .. (atm and "Nav_LostAtm" or "Nav_Lost")))
        end
        return
    end
    refresh()
end
Events.OnTick.Add(onTick)

-- A new world: the engine already cleared every arrow of the old one (IngameState.java:908).
Events.OnGameStart.Add(function()
    N.arrow, N.arrowPlayer, N.target, N.track, N.trackText, N.trackWhere = nil, nil, nil, nil, nil, nil
    N.stale = {}
    N.staleRev = N.staleRev + 1
    cache = { at = -1 }
end)

return N
