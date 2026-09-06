-- 階段 A 拋棄式原型 A4：Global ModData 規模、存檔耗時、回滾點與 .bin 水位。
-- 只在 proto/enable.txt 存在時執行。API 出處：ModData.getOrCreate ModData.java:16-49；
-- 落盤 ServerMap.java:409、"Saving took" :427；格式 GlobalModData.java:290-299 + KahluaTableImpl.java:292-327。

if not isServer() then return end

local TAG = "[MinidoracatEconomyFor42][A4]"
local DIR = "MinidoracatEconomy/proto"
local MD_KEY = "MinidoracatEconomyProto"

local function log(msg) print(TAG .. " " .. tostring(msg)) end

local function enabled()
    local ok, r = pcall(getFileReader, DIR .. "/enable.txt", false)
    if ok and r then pcall(function() r:close() end); return true end
    return false
end
if not enabled() then return end

local state = { md = nil, runId = nil, lastBeat = 0, file = nil }

local function snapshot(i)
    return {
        type = "Base.Axe", condition = (i % 10) + 1, uses = 1, age = i % 100,
        modData = { k1 = "v" .. i, k2 = "second value string", k3 = i * 2, k4 = true },
    }
end

local function fill(md)
    local t0 = getTimestampMs()
    md.wallets, md.stats, md.claims = {}, {}, {}
    for i = 1, 5000 do
        local u = string.format("user%04d", i)
        md.wallets[u] = { survivor = { available = i * 3, reserved = i % 7 }, cat = { available = i % 50, reserved = 0 } }
        md.stats[u] = {
            survivor = { earned = i * 10, spent = i * 4, monthKey = "202609", monthEarned = i, monthSpent = i % 9 },
            cat = { earned = i, spent = 0, monthKey = "202609", monthEarned = 0, monthSpent = 0 },
        }
        md.claims[u] = { dayKey = "2026-09-06", milestones = { d1 = true, d3 = true, d7 = i % 2 == 0 } }
    end
    md.receipts = {}
    for i = 1, 500 do
        local u = string.format("user%04d", i)
        local ring = {}
        for j = 1, 10 do
            ring[j] = { seq = i * 10 + j, ts = 1788684000000 + j, type = "purchase", currency = "survivor",
                delta = -450, before = 12790, after = 12340, cp = "user0002", tx = "TX-" .. i .. "-" .. j }
        end
        md.receipts[u] = ring
    end
    md.listings = {}
    for i = 1, 2000 do
        md.listings["L" .. i] = { id = "L" .. i, seller = string.format("user%04d", i % 5000 + 1), price = 450,
            currency = "survivor", createdAt = 1788684000000, snapshot = snapshot(i) }
    end
    md.mailbox = {}
    for i = 1, 3000 do
        md.mailbox["M" .. i] = { owner = string.format("user%04d", i % 5000 + 1), kind = "purchase",
            createdAt = 1788684000000, snapshot = snapshot(i) }
    end
    md.tombstones = {}
    for i = 1, 4096 do md.tombstones["ord-" .. i] = { creditSeq = i, hash = "0123456789abcdef" } end
    md.idempotency = {}
    for i = 1, 2000 do md.idempotency["req-" .. i] = { ok = true, txId = "TX-" .. i } end
    md.filled = true
    return getTimestampMs() - t0
end

local function onServerStarted()
    state.runId = tostring(getTimestampMs())
    state.file = DIR .. "/a4-seq-" .. state.runId .. ".json"
    local md = ModData.getOrCreate(MD_KEY)
    state.md = md
    if md.meta then
        log(string.format("loaded: epoch=%s seq=%s filled=%s (this is the rollback point)",
            tostring(md.meta.epoch), tostring(md.meta.seq), tostring(md.filled)))
    else
        log("loaded: no meta (fresh table)")
    end
    if not md.filled then
        local ms = fill(md)
        log("filled synthetic dataset in " .. ms .. " ms")
    end
    md.meta = { epoch = state.runId, seq = (md.meta and md.meta.seq) or 0, loadedSeq = (md.meta and md.meta.seq) or 0 }
    log("start epoch=" .. state.runId .. " seq=" .. md.meta.seq)
    Events.OnTickEvenPaused.Add(function()
        local now = getTimestampMs()
        if now - state.lastBeat < 1000 then return end
        state.lastBeat = now
        md.meta.seq = md.meta.seq + 1
        local w = getFileWriter(state.file, true, true)
        if w then
            w:writeln(string.format('{"epoch":%s,"seq":%d,"ts":%d}#', state.runId, md.meta.seq, now))
            w:close()
        end
        if md.meta.seq % 30 == 0 then log("seq=" .. md.meta.seq) end
    end)
end

Events.OnServerStarted.Add(onServerStarted)
