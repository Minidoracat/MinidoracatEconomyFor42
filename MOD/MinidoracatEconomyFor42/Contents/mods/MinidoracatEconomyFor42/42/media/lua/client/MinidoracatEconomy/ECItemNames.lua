-- Real English item names: the shipped EN dictionary, then activated MOD overrides.
-- ScriptItem.getDisplayName is already translated (Item.java:3053), not an English source.
-- UTF-8 readers: LuaManager.java:5971-6016; active MOD ids: LuaManager.java:7434-7440.
-- Flat JSON is consumed a bounded number of tokens per tick, regardless of line formatting.
-- A source that cannot be read does not silence the ones that can: the index finishes as
-- 'partial', keeps every real name it did read, and names the MODs it could not read, so a
-- search still runs and an empty answer is never presented as a complete negative.
require "MinidoracatEconomy/ECClient"
local EC = MinidoracatEconomy
local C = EC.Client
local N = { FILE = "media/MinidoracatEconomy_item_names_en.json",
    MOD_FILE = "media/lua/shared/Translate/EN/ItemName.json",
    MOD_DIR = "media/lua/shared/Translate/EN", MOD_NAME = "ItemName.json",
    MATCH_MAX = 256, PROBES_PER_STEP = 6,
    LINES_PER_STEP = 800, TOKENS_PER_STEP = 4000, MAX_CHARS = 524288, revision = 0 }
C.ItemNames = N

local base, over, aliases = {}, {}, {}
local state, failure = "idle", nil
-- Every gap this index knows about: one entry per MOD, appended once and never rewritten, so
-- the list is bounded by the activated MOD count and a broken MOD cannot flood it per tick.
local incomplete, flagged = {}, {}
local job, mods, modIndex, step

local function markIncomplete(modId, reason)
    failure = failure or reason
    EC.log("item names: " .. tostring(modId) .. " " .. reason)
    if flagged[modId] then return end
    flagged[modId] = true
    incomplete[#incomplete + 1] = { modId = modId, reason = reason }
end

local function openReader(modId, path)
    local ok, reader = pcall(getModFileReader, modId, path, false)
    if not ok then markIncomplete(modId, "names_reader_failed"); return nil end
    return reader
end

-- How many ItemName.json this MOD ships in its EN directory: 0 (the normal case, no gap), 1, or
-- 2 when the same file exists in both the common and the version directory. Returns -1 when the
-- listing itself cannot answer, which is not evidence of anything either way.
-- LuaManager.java:6039-6055 lists common then version and returns bare file names.
local function countModFiles(modId)
    local total = -1
    local ok = pcall(function()
        local list = listFilesInModDirectory(modId, N.MOD_DIR)
        if list == nil then return end
        local found, size = 0, list:size()
        for i = 0, size - 1 do
            if string.lower(list:get(i)) == string.lower(N.MOD_NAME) then found = found + 1 end
        end
        total = found
    end)
    if not ok then return -1 end
    return total
end

local function closeReader()
    if job and job.reader then
        local ok, err = pcall(function() job.reader:close() end)
        -- a handle that will not close has already given up everything it held: logged, but
        -- never a claim that a name is missing
        if not ok then EC.log("item names: close failed " .. tostring(err)) end
        job.reader = nil
    end
end

local function newJob(modId, path, target)
    job = { modId = modId, reader = openReader(modId, path), target = target,
        phase = "open", pos = 1, chars = 0, entries = 0 }
end

local function collectMods()
    local out = {}
    local ok, err = pcall(function()
        local active = getActivatedMods()
        for i = 0, active:size() - 1 do
            local id = active:get(i)
            if type(id) ~= "string" or id == "" then error("invalid activated MOD id") end
            if id ~= EC.MOD_ID then out[#out + 1] = id end
        end
    end)
    if not ok then
        EC.log("item names: activated MOD list " .. tostring(err))
        markIncomplete(EC.MOD_ID, "names_scan_unavailable")
    end
    return out
end

-- JSON strings cannot contain literal newlines, so a quoted token must end on this line.
-- Escapes are decoded by the existing JSON decoder, never by a second Unicode implementation.
local function quoted(line, pos)
    if string.sub(line, pos, pos) ~= '"' then error("expected JSON string") end
    local last = pos
    while true do
        last = string.find(line, '"', last + 1, true)
        if not last then error("unfinished JSON string") end
        local before = last - 1
        while before > pos and string.sub(line, before, before) == "\\" do before = before - 1 end
        if (last - before - 1) % 2 == 0 then break end
    end
    local value = string.sub(line, pos + 1, last - 1)
    if string.find(value, "[%z\1-\31]") then error("invalid JSON string control") end
    if string.find(value, "\\", 1, true) then value = EC.jsonDecode(string.sub(line, pos, last)) end
    if type(value) ~= "string" then error("invalid JSON string") end
    return value, last + 1
end

local function store(key, value)
    if #key == 0 or #key > 128 then error("invalid item name key") end
    -- an entry that names nothing is still a well formed entry, but it never takes the place of
    -- a name that is already known
    if value == "" then job.entries = job.entries + 1; return end
    local old = job.target[key]
    if job.target == over and old and old ~= value then
        local names = aliases[key]
        if not names then names = {}; aliases[key] = names end
        local present = false
        for _, name in ipairs(names) do if name == old then present = true; break end end
        if not present then names[#names + 1] = old end
    end
    job.target[key] = value
    job.entries = job.entries + 1
end

local function stepReader()
    local lines = 0
    for _ = 1, N.TOKENS_PER_STEP do
        if job.line == nil then
            if lines >= N.LINES_PER_STEP then return false end
            job.line = job.reader:readLine()
            job.pos = 1
            if job.line == nil then
                if job.phase ~= "closed" then error("incomplete JSON object") end
                return true
            end
            lines = lines + 1
            job.chars = job.chars + #job.line + 1
            if job.chars > N.MAX_CHARS then error("item name file exceeds limit") end
        end
        local pos = string.find(job.line, "%S", job.pos)
        if not pos then
            job.line = nil
        else
            local char, phase = string.sub(job.line, pos, pos), job.phase
            job.pos = pos + 1
            if phase == "open" and char == "{" then
                job.phase = "first"
            elseif (phase == "first" or phase == "after") and char == "}" then
                job.phase = "closed"
            elseif (phase == "first" or phase == "key") and char == '"' then
                job.key, job.pos = quoted(job.line, pos)
                job.phase = "colon"
            elseif phase == "colon" and char == ":" then
                job.phase = "value"
            elseif phase == "value" and char == '"' then
                local value
                value, job.pos = quoted(job.line, pos)
                store(job.key, value)
                job.phase = "after"
            elseif phase == "after" and char == "," then
                job.phase = "key"
            else
                error("invalid item name JSON structure")
            end
        end
    end
    return false
end

local function finish()
    closeReader()
    job, mods = nil, nil
    Events.OnTick.Remove(step)
    -- 'ready' is a claim that every source was read. Anything less is said out loud.
    state = #incomplete > 0 and "partial" or "ready"
    N.revision = N.revision + 1
end

step = function()
    if job == nil then return end
    if job.reader then
        local ok, done = pcall(stepReader)
        if not ok then
            -- what was already read is real and stays; only this source is short
            markIncomplete(job.modId, job.target == base and "names_malformed" or "names_read_failed")
        end
        if ok and not done then return end
        if job.target == base and job.entries == 0 then markIncomplete(EC.MOD_ID, "names_unavailable") end
        closeReader()
    end
    if mods == nil then mods, modIndex = collectMods(), 0 end
    -- Missing translation files are the normal case, not a gap. One directory listing and at
    -- most one open per MOD, a bounded number of MODs per tick, once per session.
    for _ = 1, N.PROBES_PER_STEP do
        modIndex = modIndex + 1
        local id = mods[modIndex]
        if not id then finish(); return end
        local count = countModFiles(id)
        if count < 0 then markIncomplete(id, "names_scan_unavailable") end
        if count ~= 0 then
            newJob(id, N.MOD_FILE, over)
            if job.reader == nil then
                -- the directory says the file is there, so a reader that is not is a real gap
                if count >= 1 then markIncomplete(id, "names_reader_missing") end
            else
                -- both directories ship one: getModFileReader (LuaManager.java:5980-5985) opens
                -- the version copy and the common copy behind it cannot be reached at all. The
                -- readable one is still read; the hidden one is never guessed at.
                if count >= 2 then markIncomplete(id, "names_common_shadowed") end
                return
            end
        end
    end
end

function N.ensure()
    if state == "ready" or state == "partial" then return true, failure end
    if state == "idle" then
        state = "loading"
        newJob(EC.MOD_ID, N.FILE, base)
        if not job.reader then markIncomplete(EC.MOD_ID, "names_unavailable") end
        Events.OnTick.Add(step)
    end
    return false, nil
end

-- The third value is the live gap list: one { modId, reason } per MOD that could not be read in
-- full. A caller that has to stand by an answer copies it, because this table outlives the call.
function N.status() return state, failure, incomplete end

-- The name in force, the base English a MOD renamed away from (nil when there was none, or when
-- it is the same string), and every intermediate name an earlier MOD gave this type. All three
-- are names a source really declared: nothing here is derived from the other two, so a caller
-- can search on all of them without ever showing a name no file contains.
function N.english(fullType)
    local name = over[fullType] or base[fullType]
    local original = base[fullType]
    if original == name then original = nil end
    return name, original, aliases[fullType]
end

local function hit(query, exact, value)
    if type(value) ~= "string" or value == "" then return false end
    value = string.lower(value)
    if exact then return value == query end
    return string.find(value, query, 1, true) ~= nil
end

local function hitType(query, exact, fullType, localised)
    if hit(query, exact, fullType) or hit(query, exact, localised)
        or hit(query, exact, base[fullType]) or hit(query, exact, over[fullType]) then return true end
    local names = aliases[fullType]
    if names then
        for _, name in ipairs(names) do
            if hit(query, exact, name) then return true end
        end
    end
    return false
end

function N.resolve(query, mode, universe)
    if type(query) ~= "string" then return {} end
    query = string.lower(string.match(query, "^%s*(.-)%s*$") or "")
    if query == "" then return {} end
    if state == "idle" then N.ensure() end
    -- a finished index answers even when a source was missing: what it holds is real, and
    -- status() is what tells the caller the answer cannot be read as exhaustive
    if state ~= "ready" and state ~= "partial" then return nil, "names_not_ready" end
    local exact, out, seen = mode == "exact", {}, {}
    local function add(fullType, name)
        if seen[fullType] then return true end
        seen[fullType] = true
        if hitType(query, exact, fullType, name) then
            out[#out + 1] = fullType
            if #out > N.MATCH_MAX then return false end
        end
        return true
    end
    for _, rec in ipairs(universe and universe.items or {}) do
        if not add(rec.fullType, rec.name) then return nil, "item_query_too_broad" end
    end
    for fullType in pairs(base) do if not add(fullType) then return nil, "item_query_too_broad" end end
    for fullType in pairs(over) do if not add(fullType) then return nil, "item_query_too_broad" end end
    return out
end

return N
