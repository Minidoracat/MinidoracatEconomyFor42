-- 階段 A 拋棄式原型（A1 檔案寫讀、A2 每 tick 合併寫成本、A3 空服 OnTickEvenPaused 頻率）。
-- 只在 {cachedir}/Lua/MinidoracatEconomy/proto/enable.txt 存在時執行；正式版前整個 proto/ 目錄刪除。
-- API 出處：getFileWriter LuaManager.java:6726-6778（副檔名白名單 :1034、mkdirs :6738）、
-- getFileReader :5937-5965（BufferedReader；不存在且不建立→nil）、getTimestampMs :9267、
-- OnServerStarted LuaEventManager.java:744、OnTickEvenPaused :594、
-- listFilesInZomboidLuaDirectory LuaManager.java:6024-6068。

if not isServer() then return end

local TAG = "[MinidoracatEconomyFor42][A1]"
local DIR = "MinidoracatEconomy/proto"
local SENTINEL = "#"           -- 每行結尾記號：崩潰截斷的半行不會有它
local BATCH_LINES = 100        -- A2：每 tick 每檔寫幾行
local BATCH_TICKS = 10         -- A2：寫幾個 tick 的批次（10 × 100 = 1,000 行）
local HEARTBEAT_MS = 1000      -- 之後每秒一行，供 kill -9 測試

local function log(msg)
    print(TAG .. " " .. tostring(msg))
end

local function readerEnabled()
    local ok, r = pcall(getFileReader, DIR .. "/enable.txt", false)
    if ok and r then
        pcall(function() r:close() end)
        return true
    end
    return false
end

if not readerEnabled() then
    log("disabled (no proto/enable.txt)")
    return
end

local state = {
    runId = nil,
    file = nil,
    seq = 0,
    batchTick = 0,
    batchMsTotal = 0,
    batchMsMax = 0,
    lastHeartbeat = 0,
    tickCount = 0,
    minuteStart = 0,
    ticksThisMinute = 0,
    done = false,
}

-- 讀一個 run 檔：回傳 總行數、最後完整行的 seq、是否有半行
local function inspectRunFile(name)
    local ok, reader = pcall(getFileReader, DIR .. "/" .. name, false)
    if not ok or not reader then
        return nil
    end
    local lines, lastSeq, partial = 0, -1, false
    while true do
        local line = reader:readLine()
        if line == nil then break end
        lines = lines + 1
        if string.sub(line, -1) == SENTINEL then
            local s = string.match(line, '"seq":(%d+)')
            if s then lastSeq = tonumber(s) end
        else
            partial = true
        end
    end
    reader:close()
    return lines, lastSeq, partial
end

local function reportPreviousRuns()
    local ok, files = pcall(listFilesInZomboidLuaDirectory, DIR)
    if not ok or not files then
        log("previous-run scan: listFilesInZomboidLuaDirectory failed err=" .. tostring(files))
        return
    end
    local count = files:size()
    log("previous-run scan: " .. count .. " entries in " .. DIR)
    for i = 0, count - 1 do
        local name = tostring(files:get(i))
        if string.match(name, "^a1%-run%-%d+%.json$") then
            local lines, lastSeq, partial = inspectRunFile(name)
            log(string.format("previous run %s: lines=%s lastSeq=%s partialLine=%s",
                name, tostring(lines), tostring(lastSeq), tostring(partial)))
        end
    end
end

local function probeExtensionWhitelist()
    local ok1, w1 = pcall(getFileWriter, DIR .. "/probe.ndjson", true, false)
    log("ext .ndjson writer=" .. tostring(ok1 and w1 or nil) .. " (expect nil)")
    if ok1 and w1 then pcall(function() w1:close() end) end
    local ok2, w2 = pcall(getFileWriter, DIR .. "/sub/deeper/probe.json", true, false)
    log("ext .json + nested subdir writer=" .. tostring(ok2 and w2 and "ok" or "nil") .. " (expect ok)")
    if ok2 and w2 then
        w2:writeln("{\"probe\":true}" .. SENTINEL)
        w2:close()
    end
    -- append 兩次後應有 2 行
    local a1 = getFileWriter(DIR .. "/append.json", true, true)
    a1:writeln("{\"n\":1}" .. SENTINEL); a1:close()
    local a2 = getFileWriter(DIR .. "/append.json", true, true)
    a2:writeln("{\"n\":2}" .. SENTINEL); a2:close()
    local lines = inspectRunFile("append.json")
    log("append.json lines=" .. tostring(lines) .. " (grows by 2 each start)")
    -- 截斷覆寫：append=false 應只剩 1 行
    local t = getFileWriter(DIR .. "/truncate.json", true, false)
    t:writeln("{\"only\":1}" .. SENTINEL); t:close()
    local tl = inspectRunFile("truncate.json")
    log("truncate.json lines=" .. tostring(tl) .. " (expect 1)")
end

local function writeBatch(nLines)
    -- 模擬 events／receipts／audit 三個檔各寫 nLines 行，一次 open → writeln×n → close
    local t0 = getTimestampMs()
    local names = { state.file, DIR .. "/a1-receipts-" .. state.runId .. ".json", DIR .. "/a1-audit-" .. state.runId .. ".json" }
    for f = 1, 3 do
        local w = getFileWriter(names[f], true, true)
        if not w then
            log("writer nil for " .. names[f])
            return nil
        end
        for i = 1, nLines do
            state.seq = state.seq + 1
            w:writeln(string.format('{"epoch":%s,"seq":%d,"ts":%d,"type":"proto.batch","payload":"%s"}%s',
                state.runId, state.seq, t0, string.rep("x", 120), SENTINEL))
        end
        w:close()
    end
    return getTimestampMs() - t0
end

local function onTick()
    if state.done then return end
    state.tickCount = state.tickCount + 1
    local now = getTimestampMs()
    if state.minuteStart == 0 then state.minuteStart = now end
    state.ticksThisMinute = state.ticksThisMinute + 1
    if now - state.minuteStart >= 60000 then
        log(string.format("A3 empty-server OnTickEvenPaused: %d ticks in last %d ms (players=%d)",
            state.ticksThisMinute, now - state.minuteStart, getOnlinePlayers() and getOnlinePlayers():size() or -1))
        state.minuteStart = now
        state.ticksThisMinute = 0
    end

    if state.batchTick < BATCH_TICKS then
        state.batchTick = state.batchTick + 1
        local ms = writeBatch(BATCH_LINES)
        if ms then
            state.batchMsTotal = state.batchMsTotal + ms
            if ms > state.batchMsMax then state.batchMsMax = ms end
        end
        if state.batchTick == BATCH_TICKS then
            log(string.format("A2 batch write: %d ticks x %d lines x 3 files; avg %.1f ms/tick, max %d ms",
                BATCH_TICKS, BATCH_LINES, state.batchMsTotal / BATCH_TICKS, state.batchMsMax))
            local lines, lastSeq, partial = inspectRunFile("a1-run-" .. state.runId .. ".json")
            log(string.format("A1 read-back after batch: lines=%s lastSeq=%s partial=%s (expect %d)",
                tostring(lines), tostring(lastSeq), tostring(partial), BATCH_LINES * BATCH_TICKS))
        end
        return
    end

    -- 心跳：每秒一行，供外部 kill -9 後檢查最後完整行；同時量單次 open→writeln→close 成本
    if now - state.lastHeartbeat >= HEARTBEAT_MS then
        state.lastHeartbeat = now
        local t0 = getTimestampMs()
        local w = getFileWriter(state.file, true, true)
        if w then
            state.seq = state.seq + 1
            w:writeln(string.format('{"epoch":%s,"seq":%d,"ts":%d,"type":"proto.heartbeat"}%s', state.runId, state.seq, now, SENTINEL))
            w:close()
        end
        local ms = getTimestampMs() - t0
        state.hbMsTotal = (state.hbMsTotal or 0) + ms
        state.hbCount = (state.hbCount or 0) + 1
        if state.hbMsMax == nil or ms > state.hbMsMax then state.hbMsMax = ms end
        if state.hbCount % 30 == 0 then
            log(string.format("heartbeat seq=%d; single open+1line+close avg %.2f ms, max %d ms (n=%d)",
                state.seq, state.hbMsTotal / state.hbCount, state.hbMsMax, state.hbCount))
        end
    end
end

local function onServerStarted()
    state.runId = tostring(getTimestampMs())
    state.file = DIR .. "/a1-run-" .. state.runId .. ".json"
    log("start runId=" .. state.runId .. " file=" .. state.file)
    reportPreviousRuns()
    local ok, err = pcall(probeExtensionWhitelist)
    if not ok then log("probe error: " .. tostring(err)) end
    Events.OnTickEvenPaused.Add(onTick)
    log("ticking; batch phase " .. BATCH_TICKS .. " ticks, then 1 heartbeat/s")
end

Events.OnServerStarted.Add(onServerStarted)
