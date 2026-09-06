-- MinidoracatEconomyFor42 - admin-supplied currency icons (server authority, stage B8).
--
-- The host drops `<currencyId>.png` (survivor.png / cat.png) into
-- {cachedir}/Lua/MinidoracatEconomy/icons/ and presses "reload icons" in the admin panel (or
-- restarts). Each file is read a batch per tick, hashed (EC.hashUpdate) and pre-split into
-- byte-string chunks kept in memory; the hash + byte count go through Cfg.setIconHash, which
-- broadcasts `config` so every client sees the new hash and asks for the chunks it lacks
-- (icon.get -> icon.data). Nothing about the image is stored in ModData.
--
-- A self-contained copy of the NoticeBoard pipeline reduced to what two small icons need (spec
-- decision 13); the engine facts below are the ones NoticeBoard verified in production:
--   * getFileInput(name) is a DataInputStream over {cachedir}/Lua/<name> (LuaManager.java:6863-6881)
--     and available() is the remaining byte count; read() returns 0..255 or -1 at EOF. On an open
--     failure it does NOT return nil but a stream over the previous successful open, so only one
--     job is ever in flight and the size is re-checked against what the job actually read.
--   * getFileWriter's extension whitelist does not matter here (icons are read, never written).
--   * per-tick budget: a read() is one reflective call; ICON_READ_PER_TICK keeps a tick under ~1 ms.

if not MinidoracatEconomy or not MinidoracatEconomy.Config then
    require "MinidoracatEconomy/ECConfig"
end
local EC = MinidoracatEconomy
local S = EC and EC.Server
local X = EC and EC.Export
local Cfg = EC and EC.Config
if not S or not S.AUTHORITY or not X or not Cfg then
    return
end

EC.Icons = EC.Icons or {}
local I = EC.Icons

I.DIR = X.ROOT .. "/icons"
I.READ_PER_TICK = 4096
I.CHUNKS_PER_REPLY = 8            -- 8 x 8192 chars covers the 64 KB cap in one tick

local icons = {}                  -- id -> { hash, bytes, chunks = { byteString... } }
local queue = {}                  -- currency ids waiting for a read job
local job = nil                   -- { id, input, size, read, hash, parts = {}, partLen }
local lastResult = {}             -- id -> { hash, bytes, error } for the admin reply
local actor, reason = nil, nil    -- who asked for the current reload (audit)

function I.path(id)
    return I.DIR .. "/" .. id .. ".png"
end

local function closeInput(input)
    if input then pcall(function() input:close() end) end
end

local function openIcon(id)
    local input = nil
    local ok, size = pcall(function()
        input = getFileInput(I.path(id))
        if not input then return nil end
        return input:available()
    end)
    if not ok or input == nil then
        closeInput(input)
        return nil, nil
    end
    if type(size) ~= "number" then
        closeInput(input)
        return nil, "unreadable"
    end
    return input, math.floor(size)
end

local function clearIcon(id, why)
    icons[id] = nil
    lastResult[id] = { error = why }
    Cfg.setIconHash(id, nil, nil, actor, reason)
end

local function finishJob(j)
    closeInput(j.input)
    local data = table.concat(j.parts)
    if #data ~= j.size or #data == 0 then
        EC.log("icon " .. j.id .. " short read: expected " .. tostring(j.size) .. " got " .. tostring(#data))
        clearIcon(j.id, "short_read")
        return
    end
    local chunks = {}
    for from = 1, #data, EC.ICON_CHUNK_CHARS do
        chunks[#chunks + 1] = string.sub(data, from, from + EC.ICON_CHUNK_CHARS - 1)
    end
    local hash = EC.hashHex(j.hash)
    icons[j.id] = { hash = hash, bytes = #data, chunks = chunks }
    lastResult[j.id] = { hash = hash, bytes = #data }
    Cfg.setIconHash(j.id, hash, #data, actor, reason)
    EC.log("icon " .. j.id .. " loaded bytes=" .. tostring(#data) .. " hash=" .. hash .. " chunks=" .. tostring(#chunks))
end

local function startNext()
    while #queue > 0 do
        local id = table.remove(queue, 1)
        local input, size = openIcon(id)
        if not input then
            if size == "unreadable" then
                EC.log("icon " .. id .. " unreadable; keeping the shipped icon")
                clearIcon(id, "unreadable")
            elseif icons[id] or Cfg.currency(id).iconHash then
                EC.log("icon " .. id .. " file removed; back to the shipped icon")
                clearIcon(id, nil)
            else
                lastResult[id] = {}
            end
        elseif size <= 0 or size > EC.ICON_MAX_BYTES then
            closeInput(input)
            EC.log("icon " .. id .. " refused: " .. tostring(size) .. " bytes (max " .. tostring(EC.ICON_MAX_BYTES) .. ")")
            clearIcon(id, size <= 0 and "empty" or "too_large")
        else
            job = { id = id, input = input, size = size, read = 0, hash = EC.hashInit(), parts = {} }
            return true
        end
    end
    return false
end

local function pumpRead()
    local j = job
    local buf = {}
    local ok, err = pcall(function()
        local want = math.min(I.READ_PER_TICK, j.size - j.read)
        for _ = 1, want do
            local b = j.input:read()
            if type(b) ~= "number" or b < 0 then break end
            buf[#buf + 1] = string.char(b % 256)
        end
    end)
    local part = table.concat(buf)
    if not ok then
        EC.log("icon " .. j.id .. " read failed: " .. tostring(err))
        job = nil
        closeInput(j.input)
        clearIcon(j.id, "read_failed")
        return
    end
    if #part > 0 then
        j.parts[#j.parts + 1] = part
        j.read = j.read + #part
        j.hash = EC.hashUpdate(j.hash, part)
    end
    if #part == 0 or j.read >= j.size then
        job = nil
        finishJob(j)
    end
end

-- Queue every currency for a (re)read. Returns false while a previous reload is still running.
function I.reload(who, why)
    if job or #queue > 0 then return false end
    actor, reason = who, why
    for _, id in ipairs(EC.CURRENCY_ORDER) do
        queue[#queue + 1] = id
    end
    return true
end

function I.busy()
    return job ~= nil or #queue > 0
end

-- Per-currency status for the admin panel: {hash, bytes, error}; `{}` means "no file".
function I.status()
    local out = {}
    for _, id in ipairs(EC.CURRENCY_ORDER) do
        local r = lastResult[id] or {}
        out[id] = { hash = r.hash, bytes = r.bytes, error = r.error }
    end
    return out
end

function I.onTick()
    if job then
        pumpRead()
    elseif #queue > 0 then
        startNext()
    end
end

-- icon.get {currency, from}: chunks from index `from` (1-based) of the current icon. The reply
-- carries the hash so a client that raced a reload can discard stale chunks.
S.handlers["icon.get"] = function(player, args)
    if type(args) ~= "table" or not EC.CURRENCIES[args.currency] then return end
    local icon = icons[args.currency]
    if not icon then
        S.reply(player, "icon.data", { currency = args.currency, hash = nil })
        return
    end
    local from = 1
    if type(args.from) == "number" and args.from >= 1 and args.from == math.floor(args.from) then
        from = args.from
    end
    local n = #icon.chunks
    local last = math.min(n, from + I.CHUNKS_PER_REPLY - 1)
    for i = from, last do
        S.reply(player, "icon.data", { currency = args.currency, hash = icon.hash, bytes = icon.bytes, n = n, i = i, text = icon.chunks[i] })
    end
end

function I.init(root)
    icons, queue, job, lastResult = {}, {}, nil, {}
    actor, reason = nil, "server_start"
    I.reload(nil, "server_start")
end

S.Icons = I
S.onInit(I.init)
Events.OnTickEvenPaused.Add(I.onTick)

return I
