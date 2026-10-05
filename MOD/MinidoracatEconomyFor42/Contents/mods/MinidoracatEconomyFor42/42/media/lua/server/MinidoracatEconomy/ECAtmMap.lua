-- MinidoracatEconomyFor42 - the vanilla map ATMs this server has seen (navigation targets only).
--
-- Map ATMs (EC.ATM_SPRITES) stand where the map put them and nobody registers them: EC.nearMapAtm
-- already opens the trade gate next to one. To point a player at one far away, the server records
-- each ATM as its chunk loads. MapObjects.OnLoadWithSprite is a sprite-keyed lookup the engine makes
-- for every object a loading chunk holds (IsoChunk.java:3829, MapObjects.java:184-218), so Lua runs
-- for the ATMs only, on every load, not just a chunk's first. Known means seen: a fresh world knows
-- none until players have been near them. A record is a hint, never a gate (ECTerminal T.near still
-- asks the square). An ATM taken down later stays recorded: the engine has no event for it, and
-- Events.LoadChunk (IsoChunk.java:3969) hands Lua a chunk whose coordinates are bare public fields
-- with no getter, so there is no cheap re-check; each client drops one it finds gone (ECNavigate).
-- A same-priority registration on the same sprite replaces the earlier one (MapObjects.java:148-151),
-- hence a priority of our own, apart from ECTerminal's 5.
--
-- ModData: root.mapAtms = { {x, y, z}, ... }, never transmitted. Clients get it flat,
-- {x1, y1, z1, x2, ...}, in hello.ack.atms and in the `atms` push: at most once per A.PUSH_MS and
-- only after something new was recorded.

if not MinidoracatEconomy or not MinidoracatEconomy.Terminal then
    require "MinidoracatEconomy/ECTerminal"
end
local EC = MinidoracatEconomy
local S = EC and EC.Server
if not S or not S.AUTHORITY then
    return
end

local A = {}
S.AtmMap = A

-- A record is three numbers on the wire, 54 bytes by S.wireBytes: the cap keeps the list near
-- 216 KB, a quarter of S.REPLY_MAX_BYTES, inside hello.ack as well as alone in the push.
A.MAX = 4000
A.PUSH_MS = 10000
A.PRIORITY = 7429

local md = nil
local seen = {}            -- seen[x][y][z] = true for every record (coordinates + 0, see ECTradeRadioRelay coordId)
local flat = nil           -- the wire form, rebuilt after a change
local dirty, pushedAt, fullLogged = false, 0, false

local function remember(x, y, z)
    local col = seen[x]
    if not col then
        col = {}
        seen[x] = col
    end
    local row = col[y]
    if not row then
        row = {}
        col[y] = row
    end
    row[z] = true
end

function A.onLoad(obj)
    if not md then return end
    local sq = obj:getSquare()
    if not sq then return end
    local x, y, z = sq:getX() + 0, sq:getY() + 0, sq:getZ() + 0
    local col = seen[x]
    local row = col and col[y]
    if row and row[z] then return end
    local list = md.mapAtms
    if #list >= A.MAX then
        if not fullLogged then
            fullLogged = true
            EC.log("map ATMs: " .. A.MAX .. " recorded, later ones are not kept")
        end
        return
    end
    list[#list + 1] = { x = x, y = y, z = z }
    remember(x, y, z)
    flat, dirty = nil, true
end

-- { x1, y1, z1, x2, ... }: the same table until the next record.
function A.flat()
    if flat == nil then
        flat = {}
        for _, a in ipairs(md and md.mapAtms or {}) do
            flat[#flat + 1] = a.x
            flat[#flat + 1] = a.y
            flat[#flat + 1] = a.z
        end
    end
    return flat
end

function A.onTick()
    if not dirty then return end
    local now = EC.now()
    if now - pushedAt < A.PUSH_MS then return end
    dirty, pushedAt = false, now
    S.broadcast("atms", { list = A.flat() })
end

function A.init(root)
    md = root
    md.mapAtms = md.mapAtms or {}
    seen, flat, dirty, pushedAt, fullLogged = {}, nil, false, 0, false
    for _, a in ipairs(md.mapAtms) do remember(a.x, a.y, a.z) end
end

local names = {}
for name in pairs(EC.ATM_SPRITES) do names[#names + 1] = name end
MapObjects.OnLoadWithSprite(names, A.onLoad, A.PRIORITY)
Events.OnTickEvenPaused.Add(A.onTick)
S.onInit(A.init)
return A
