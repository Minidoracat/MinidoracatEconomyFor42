-- 階段 A 拋棄式原型 A5：inbox 重放自癒。companion（測試時由 Python 扮演）寫 inbox/<orderId>.json，
-- Lua 節流輪詢 → tombstone 冪等 → 入帳 ModData → 事件檔回報。存檔前崩潰後 inbox 仍在、tombstone 回滾 → 重放恰一次。
-- API 出處：listFilesInZomboidLuaDirectory LuaManager.java:6024-6068；getFileReader :5937-5965；ModData.java:16-49。

if not isServer() then return end

local TAG = "[MinidoracatEconomyFor42][A5]"
local DIR = "MinidoracatEconomy/proto"
local INBOX = DIR .. "/inbox"
local POLL_MS = 2000

local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function enabled()
    local ok, r = pcall(getFileReader, DIR .. "/enable.txt", false)
    if ok and r then pcall(function() r:close() end); return true end
    return false
end
if not enabled() then return end

local state = { md = nil, lastPoll = 0, runId = nil, events = nil, seq = 0 }

local function readOrder(name)
    local ok, reader = pcall(getFileReader, INBOX .. "/" .. name, false)
    if not ok or not reader then return nil end
    local line = reader:readLine()
    reader:close()
    if not line then return nil end
    -- 原型格式：orderId=...;username=...;amount=...
    local orderId = string.match(line, "orderId=([%w%-]+)")
    local username = string.match(line, "username=([%w_]+)")
    local amount = tonumber(string.match(line, "amount=(%d+)"))
    if orderId and username and amount then
        return { orderId = orderId, username = username, amount = amount }
    end
    return nil
end

local function emit(kind, order, balance)
    state.seq = state.seq + 1
    local w = getFileWriter(state.events, true, true)
    if w then
        w:writeln(string.format('{"epoch":%s,"seq":%d,"type":"%s","orderId":"%s","username":"%s","amount":%d,"balanceAfter":%d}#',
            state.runId, state.seq, kind, order.orderId, order.username, order.amount, balance))
        w:close()
    end
end

local function poll()
    local ok, files = pcall(listFilesInZomboidLuaDirectory, INBOX)
    if not ok or not files then return end
    local md = state.md
    for i = 0, files:size() - 1 do
        local name = tostring(files:get(i))
        if string.match(name, "%.json$") then
            local order = readOrder(name)
            if order then
                if md.tombstones[order.orderId] then
                    -- 已處理：靜默略過（companion 尚未刪檔）
                else
                    md.wallet[order.username] = (md.wallet[order.username] or 0) + order.amount
                    md.tombstones[order.orderId] = { creditSeq = state.seq + 1 }
                    emit("exchange.deposited", order, md.wallet[order.username])
                    log(string.format("deposited %s -> %s +%d balance=%d", order.orderId, order.username, order.amount, md.wallet[order.username]))
                end
            else
                log("unreadable inbox file " .. name)
            end
        end
    end
end

local function onServerStarted()
    state.runId = tostring(getTimestampMs())
    state.events = DIR .. "/a5-events-" .. state.runId .. ".json"
    local md = ModData.getOrCreate("MinidoracatEconomyProtoInbox")
    md.wallet = md.wallet or {}
    md.tombstones = md.tombstones or {}
    state.md = md
    local wallets, tombs = "", 0
    for u, v in pairs(md.wallet) do wallets = wallets .. u .. "=" .. tostring(v) .. " " end
    for _ in pairs(md.tombstones) do tombs = tombs + 1 end
    log("loaded wallet{ " .. wallets .. "} tombstones=" .. tombs)
    Events.OnTickEvenPaused.Add(function()
        local now = getTimestampMs()
        if now - state.lastPoll < POLL_MS then return end
        state.lastPoll = now
        poll()
    end)
end

Events.OnServerStarted.Add(onServerStarted)
