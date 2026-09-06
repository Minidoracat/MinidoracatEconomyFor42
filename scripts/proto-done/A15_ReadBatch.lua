-- 階段 A 拋棄式原型 A15：面板「更多歷史」的收據檔分批讀取成本。
-- 產生 5,000 行月檔 → 跨 tick 保持 BufferedReader 開啟、每 tick 讀 200 行 → 量單 tick 最大耗時與總時長。
-- API 出處：getFileReader LuaManager.java:5937-5965（BufferedReader.readLine）；getTimestampMs :9267。

if not isServer() then return end

local TAG = "[MinidoracatEconomyFor42][A15]"
local DIR = "MinidoracatEconomy/proto"
local FILE = DIR .. "/a15-receipts-202609.json"
local TOTAL, PER_TICK = 5000, 200

local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function enabled()
    local ok, r = pcall(getFileReader, DIR .. "/enable.txt", false)
    if ok and r then pcall(function() r:close() end); return true end
    return false
end
if not enabled() then return end

local state = { reader = nil, lines = 0, ticks = 0, msMax = 0, msTotal = 0, t0 = 0, parsed = 0 }

local function generate()
    local t0 = getTimestampMs()
    local w = getFileWriter(FILE, true, false)
    for i = 1, TOTAL do
        w:writeln(string.format('{"epoch":1788684000000,"seq":%d,"ts":%d,"type":"purchase","currency":"survivor","delta":-450,"availableBefore":12790,"availableAfter":12340,"reservedBefore":800,"reservedAfter":800,"cp":"user0002","txId":"TX-%06d"}#', i, 1788684000000 + i, i))
    end
    w:close()
    log("generated " .. TOTAL .. " lines in " .. (getTimestampMs() - t0) .. " ms")
end

local function onTick()
    if not state.reader then return end
    local t0 = getTimestampMs()
    local n = 0
    while n < PER_TICK do
        local line = state.reader:readLine()
        if line == nil then
            state.reader:close(); state.reader = nil
            break
        end
        n = n + 1
        state.lines = state.lines + 1
        -- 模擬解析：抽出 seq 與 delta（正式版會做完整 JSON 解析，成本更高）
        local seq = string.match(line, '"seq":(%d+)')
        if seq then state.parsed = state.parsed + 1 end
    end
    local ms = getTimestampMs() - t0
    state.ticks = state.ticks + 1
    state.msTotal = state.msTotal + ms
    if ms > state.msMax then state.msMax = ms end
    if not state.reader then
        log(string.format("read %d lines (parsed %d) in %d ticks, %d ms wall; per tick avg %.2f ms max %d ms",
            state.lines, state.parsed, state.ticks, getTimestampMs() - state.t0, state.msTotal / state.ticks, state.msMax))
        Events.OnTickEvenPaused.Remove(onTick)
    end
end

Events.OnServerStarted.Add(function()
    local ok, err = pcall(generate)
    if not ok then log("generate error: " .. tostring(err)); return end
    state.reader = getFileReader(FILE, false)
    state.t0 = getTimestampMs()
    Events.OnTickEvenPaused.Add(onTick)
end)
