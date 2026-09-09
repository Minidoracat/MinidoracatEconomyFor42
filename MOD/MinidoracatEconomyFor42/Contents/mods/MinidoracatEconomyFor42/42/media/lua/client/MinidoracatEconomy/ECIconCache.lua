-- MinidoracatEconomyFor42 - client cache for admin-supplied currency icons (stage B8).
--
-- config / hello.ack carry {iconHash, iconBytes} per currency. For each hash this file
--   1. checks the disk: Lua/MinidoracatEconomy/cache/<server>_<id>_<hash>.png with the right byte
--      count plus a <...>.ok marker of 8 bytes -> ready, getTexture(absolute path);
--   2. otherwise asks the server (icon.get) for the byte-string chunks (icon.data), writes them a
--      small batch per tick, verifies count + DJB2, writes the marker, marks ready.
-- U.drawCoin draws IC.texture(id) when present and the shipped icon otherwise, so a failure at
-- any step only means "default icon".
--
-- Self-contained copy of the NoticeBoard pipeline (NBImageCache.lua) trimmed to two icons; the
-- engine facts it relies on are the ones NoticeBoard verified in production:
--   * getFileOutput(name) is an UNBUFFERED FileOutputStream rooted at {cachedir}/Lua
--     (LuaManager.java:5818-5840): it truncates, has no append, and on an open failure returns
--     a shell over the previous stream instead of nil -> every write is read back with
--     getFileInput():available() before it counts. writeBytes(String) stores the low 8 bits of
--     each char; 8192 chars cost ~13 ms, so WRITE_PER_TICK keeps a tick around 2-3 ms.
--   * there is no delete API; discarding = truncating to 0 bytes.
--   * Texture.getSharedTexture caches by path (Texture.java:483-485): the file name must change
--     with the content, hence the hash in the name.
--   * the cache directory is shared by every server the player joins and DJB2 is linear, so the
--     file name is namespaced by the address the player typed (getServerIP/getServerPort,
--     LuaManager.java:4112,4124 -> GameClient.ip, never a server-declared value) with an
--     injective escape (pz.example.com and pz-example.com must not share a prefix).
-- ponytail: no LRU; growth is bounded by MAX_DOWNLOADS_PER_SESSION x ICON_MAX_BYTES (1 MB) per
-- session. Add eviction only if a hostile server ever makes that matter.

if not MinidoracatEconomy or not MinidoracatEconomy.Client then
    require "MinidoracatEconomy/ECClient"
end
local EC = MinidoracatEconomy
local C = EC and EC.Client
if not C then
    error("MinidoracatEconomy client failed to load")
end

EC.IconCache = EC.IconCache or {}
local IC = EC.IconCache

IC.CACHE_DIR = "MinidoracatEconomy/cache"     -- relative to {cachedir}/Lua
IC.WRITE_PER_TICK = 1536
IC.REQUEST_INTERVAL_MS = 15000
IC.PENDING_TIMEOUT_MS = 30000
IC.MAX_ATTEMPTS = 3
IC.MAX_DOWNLOADS_PER_SESSION = 16
IC.MAX_CHUNKS = math.ceil(EC.ICON_MAX_BYTES / EC.ICON_CHUNK_CHARS)
local MAX_TOKEN_CHARS = 120

local state = nil
local function reset()
    state = {
        token = nil, address = nil, tokenLogged = false,
        entries = {},            -- id -> { hash, bytes, checked, ready, texture, pending, attempts, nextAt }
        writeJob = nil,
        downloads = 0,
    }
end
reset()

-- ---------- paths ----------

-- Injective escape (see header): lower-case, every char outside [a-z0-9] -> _<byte>_.
local function sanitizeToken(text)
    local clean = string.gsub(string.lower(text), "[^a-z0-9]", function(ch)
        return "_" .. tostring(string.byte(ch)) .. "_"
    end)
    if #clean > MAX_TOKEN_CHARS then return nil end
    return clean
end

local function serverToken()
    local address = nil
    pcall(function() address = tostring(getServerIP()) .. "_" .. tostring(getServerPort()) end)
    if type(address) ~= "string" or string.match(address, "[a-zA-Z0-9]") == nil then return nil end
    if address ~= state.address then
        state.address = address
        state.token = sanitizeToken(address)
        if not state.token and not state.tokenLogged then
            state.tokenLogged = true
            EC.log("icon cache disabled: server address too long to namespace safely")
        end
    end
    return state.token
end

local function stem(id, hash)
    local token = serverToken()
    if not token then return nil end
    return token .. "_" .. id .. "_" .. hash
end

local function pngRel(s) return IC.CACHE_DIR .. "/" .. s .. ".png" end
local function okRel(s) return IC.CACHE_DIR .. "/" .. s .. ".ok" end

local function absolutePath(s)
    local ok, root = pcall(getMyDocumentFolder)
    if not ok or type(root) ~= "string" or root == "" then return nil end
    local sep = getFileSeparator()
    return root .. sep .. "Lua" .. sep .. "MinidoracatEconomy" .. sep .. "cache" .. sep .. s .. ".png"
end

-- ---------- disk primitives ----------

local function fileSize(rel)
    local input = nil
    local ok, size = pcall(function()
        input = getFileInput(rel)
        if not input then return nil end
        return input:available()
    end)
    if input then pcall(function() input:close() end) end
    if not ok or type(size) ~= "number" then return nil end
    return math.floor(size)
end

-- Truncate to 0 bytes and confirm by reading the size back (the writer handle proves nothing).
local function truncate(rel)
    local writer = nil
    pcall(function() writer = getFileOutput(rel) end)
    if writer then pcall(function() writer:close() end) end
    return fileSize(rel) == 0
end

local function cacheValid(s, bytes)
    return fileSize(pngRel(s)) == bytes and fileSize(okRel(s)) == EC.ICON_HASH_LEN
end

local function writeMarker(s, hash)
    local writer = nil
    local ok = pcall(function() writer = getFileOutput(okRel(s)) end)
    if not ok or not writer then return false end
    local wrote = pcall(function()
        for i = 1, EC.ICON_HASH_LEN do writer:write(string.byte(hash, i)) end
    end)
    pcall(function() writer:close() end)
    return wrote and fileSize(okRel(s)) == EC.ICON_HASH_LEN
end

-- ---------- entries ----------

local function entryFor(id, hash, bytes)
    local e = state.entries[id]
    if not e or e.hash ~= hash or e.bytes ~= bytes then
        e = { hash = hash, bytes = bytes, checked = false, ready = false, texture = nil, pending = nil, attempts = 0, nextAt = 0 }
        state.entries[id] = e
    end
    return e
end

local function markReady(id, e, s)
    e.ready = true
    local abs = absolutePath(s)
    local ok, tex = pcall(getTexture, abs or "")
    e.texture = (ok and tex) or nil
    if not e.texture then EC.log("icon " .. id .. " cached but getTexture failed for " .. tostring(abs)) end
end

-- Drop the in-flight state and schedule a retry; `attempts` is charged by request() alone, so a
-- failure at any step costs exactly one of MAX_ATTEMPTS downloads.
local function fail(e, why)
    e.pending = nil
    e.nextAt = EC.now() + IC.REQUEST_INTERVAL_MS
    EC.log("icon " .. tostring(why) .. " attempts=" .. tostring(e.attempts))
end

-- Stalled downloads are resumed from the first missing chunk; `from` is advisory for the server
-- and a resend of chunks already held just overwrites them.
local function request(id, e, now)
    local from = 1
    if e.pending then
        while e.pending.chunks[from] do from = from + 1 end
    end
    local ok, err = pcall(function()
        sendClientCommand(getPlayer(), EC.COMMAND_MODULE, "icon.get", { currency = id, from = from })
    end)
    if not ok then
        EC.log("icon.get failed: " .. tostring(err))
        return
    end
    e.pending = e.pending or { chunks = {}, n = nil }
    e.pending.at = now
    e.attempts = e.attempts + 1
    state.downloads = state.downloads + 1
end

-- ---------- write job ----------

local function startWrite(id, e, s)
    truncate(okRel(s))
    local writer = nil
    local ok, err = pcall(function() writer = getFileOutput(pngRel(s)) end)
    if not ok or not writer then
        fail(e, id .. " write open failed: " .. tostring(ok and "nil writer" or err))
        return
    end
    local method = "write"
    if pcall(function() writer:writeBytes("") end) then method = "writeBytes" end
    local parts = e.pending.chunks
    local text = table.concat(parts, "", 1, e.pending.n)
    e.pending = nil
    state.writeJob = { id = id, e = e, stem = s, writer = writer, method = method, text = text, pos = 1, hash = EC.hashInit() }
end

local function closeWriter(job)
    pcall(function() job.writer:close() end)
end

local function finishWrite(job)
    closeWriter(job)
    state.writeJob = nil
    local e, s = job.e, job.stem
    local hex = EC.hashHex(job.hash)
    if job.pos - 1 ~= e.bytes or hex ~= e.hash or fileSize(pngRel(s)) ~= e.bytes then
        truncate(pngRel(s))
        fail(e, job.id .. " verify failed digest=" .. hex .. " expected=" .. tostring(e.hash) .. " size=" .. tostring(fileSize(pngRel(s))))
        return
    end
    if not writeMarker(s, e.hash) then
        EC.log("icon " .. job.id .. " marker write failed; the icon is used now and re-downloaded next session")
    end
    markReady(job.id, e, s)
    EC.log("icon " .. job.id .. " cached hash=" .. e.hash .. " bytes=" .. tostring(e.bytes) .. " method=" .. job.method)
end

local function pumpWrite()
    local job = state.writeJob
    if not job then return end
    local ok, err = pcall(function()
        local last = math.min(#job.text, job.pos + IC.WRITE_PER_TICK - 1)
        local piece = string.sub(job.text, job.pos, last)
        if job.method == "writeBytes" then
            job.writer:writeBytes(piece)
        else
            for i = 1, #piece do job.writer:write(string.byte(piece, i)) end
        end
        job.hash = EC.hashUpdate(job.hash, piece)
        job.pos = last + 1
    end)
    if not ok then
        closeWriter(job)
        state.writeJob = nil
        truncate(pngRel(job.stem))
        fail(job.e, job.id .. " write failed: " .. tostring(err))
        return
    end
    if job.pos > #job.text then finishWrite(job) end
end

-- ---------- network ----------

C.handlers["icon.data"] = function(args)
    if type(args) ~= "table" or type(args.currency) ~= "string" then return end
    local e = state.entries[args.currency]
    if not e or e.ready or not e.pending then return end
    if args.hash == nil then
        -- The server has no chunks for this currency (a reload is still reading, or the file is
        -- gone and the config push is on its way). Ask again later while the config still says so.
        e.pending = nil
        e.nextAt = EC.now() + IC.REQUEST_INTERVAL_MS
        return
    end
    if args.hash ~= e.hash or args.bytes ~= e.bytes then return end  -- stale: config moved on
    local n, i, text = args.n, args.i, args.text
    if type(n) ~= "number" or n < 1 or n > IC.MAX_CHUNKS or n ~= math.floor(n) then return end
    if type(i) ~= "number" or i < 1 or i > n or i ~= math.floor(i) then return end
    if type(text) ~= "string" or #text == 0 or #text > EC.ICON_CHUNK_CHARS then return end
    e.pending.n = n
    e.pending.chunks[i] = text
    e.pending.at = EC.now()
    local total = 0
    for k = 1, n do
        local part = e.pending.chunks[k]
        if not part then return end
        total = total + #part
    end
    if total ~= e.bytes then
        fail(e, args.currency .. " chunk total " .. tostring(total) .. " != " .. tostring(e.bytes))
        return
    end
    if state.writeJob then return end -- pumpTick starts it once the current write finishes
    local s = stem(args.currency, e.hash)
    if s then startWrite(args.currency, e, s) end
end

-- ---------- tick ----------

local function pumpEntry(id, e, now)
    if e.ready then return end
    local s = stem(id, e.hash)
    if not s then return end
    if not e.checked then
        e.checked = true
        if cacheValid(s, e.bytes) then
            markReady(id, e, s)
            return
        end
    end
    if e.pending then
        if e.pending.n and not state.writeJob then
            -- fully received while another write was running
            local complete = true
            for k = 1, e.pending.n do if not e.pending.chunks[k] then complete = false break end end
            if complete then startWrite(id, e, s) return end
        end
        if now - e.pending.at > IC.PENDING_TIMEOUT_MS then
            fail(e, id .. " download stalled")
        end
        return
    end
    if state.writeJob and state.writeJob.e == e then return end  -- bytes are on their way to disk
    if e.attempts >= IC.MAX_ATTEMPTS or now < e.nextAt then return end
    if state.downloads >= IC.MAX_DOWNLOADS_PER_SESSION then return end
    request(id, e, now)
end

function IC.onTick()
    local ok, err = pcall(function()
        local list = C.currencies
        if type(list) ~= "table" then return end
        local now = EC.now()
        local seen = {}
        for _, cur in ipairs(list) do
            if type(cur) == "table" and type(cur.id) == "string" then
                if EC.isIconHash(cur.iconHash) and type(cur.iconBytes) == "number"
                    and cur.iconBytes > 0 and cur.iconBytes <= EC.ICON_MAX_BYTES then
                    seen[cur.id] = true
                    pumpEntry(cur.id, entryFor(cur.id, cur.iconHash, cur.iconBytes), now)
                end
            end
        end
        for id, e in pairs(state.entries) do
            if not seen[id] then
                -- override cleared (or a malformed one): back to the shipped icon
                if state.writeJob and state.writeJob.e == e then
                    closeWriter(state.writeJob)
                    truncate(pngRel(state.writeJob.stem))
                    state.writeJob = nil
                end
                state.entries[id] = nil
            end
        end
        pumpWrite()
    end)
    if not ok then EC.log("icon cache tick failed: " .. tostring(err)) end
end

-- Override texture for a currency, or nil for the shipped one. Cheap: one table lookup.
function IC.texture(id)
    local e = state.entries[id]
    return e and e.ready and e.texture or nil
end

function IC.state() return state end

local function onGameStart()
    if not isClient() then return end
    reset()
end

Events.OnGameStart.Add(onGameStart)
Events.OnTick.Add(IC.onTick)

return IC
