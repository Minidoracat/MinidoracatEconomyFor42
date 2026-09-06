-- 階段 A 拋棄式原型（需 client 的項目)：伺服器端。只在 proto/enable.txt 存在時執行。
-- API 出處：OnClientCommand LuaEventManager.java:729；sendServerCommand LuaManager.java:8942；
-- sendAddItemToContainer :12306／sendRemoveItemFromContainer :12346（只發封包給 client，GameServer.java:2389-2391；伺服器端容器要自己 AddItem／Remove，原版 ClientCommands.lua:185-188）；instanceItem :5610；
-- hasCapability 用法 ClientCommands.lua:640；OnNewGame/OnCharacterDeath/OnPlayerDeath/OnCreatePlayer LuaEventManager.java:682-695；
-- getZomboidRadio :2909；ZomboidRadio.addChannelName ZomboidRadio.java:135；SendTransmission :894；
-- ItemContainer.getItemWithID ItemContainer.java:3083；IsoObject.transmitModData IsoObject.java:4805。

if not isServer() then return end

local TAG = "[MinidoracatEconomyFor42][A*]"
local MODULE = "MinidoracatEconomyProto"
local DIR = "MinidoracatEconomy/proto"
local RADIO_FREQ = 92400

local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function enabled()
    local ok, r = pcall(getFileReader, DIR .. "/enable.txt", false)
    if ok and r then pcall(function() r:close() end); return true end
    return false
end
if not enabled() then return end

local md = nil        -- Global ModData：mailbox／listings／terminals／wallet／meta{seq, loadedSeq, epoch}
local function nextSeq() md.meta.seq = md.meta.seq + 1; return md.meta.seq end

local function pmd(player)
    local t = player:getModData()
    t.MinidoracatEconomy = t.MinidoracatEconomy or { pendingClaims = {}, pendingOuts = {}, seq = 0 }
    return t.MinidoracatEconomy
end

local function giveItem(inv, item)
    inv:AddItem(item)
    sendAddItemToContainer(inv, item)
end
local function takeItem(inv, item)
    inv:Remove(item)
    sendRemoveItemFromContainer(inv, item)
end

local function reply(player, cmd, args)
    sendServerCommand(player, MODULE, cmd, args or {})
end

local function stamp(item, mailId, txId)
    local m = item:getModData()
    m.MinidoracatEconomy = { mailId = mailId, txId = txId, epoch = md.meta.epoch, seq = nextSeq() }
end

local function findStamped(inv, mailId)
    local items = inv:getItems()
    for i = 0, items:size() - 1 do
        local it = items:get(i)
        local m = it:getModData().MinidoracatEconomy
        if m and m.mailId == mailId then return it end
    end
    return nil
end

local function snapshotOf(item)
    return { type = item:getFullType(), condition = item:getCondition(), uses = item:getCurrentUses(), age = item:getAge() }
end

local function rebuild(s)
    local item = instanceItem(s.type)
    item:setCondition(s.condition); item:setCurrentUses(s.uses); item:setAge(s.age)
    return item
end

-- ---------- A9：claim-in ----------
local function claimIn(player, mailId)
    local entry = md.mailbox[mailId]
    if not entry then log("claim-in: no mailbox entry " .. mailId); return end
    local p = pmd(player)
    entry.state = "claiming"
    p.pendingClaims[mailId] = { txId = entry.txId }
    log("claim-in phase1 " .. mailId .. " state=claiming, pending recorded (player modData)")
    local item = rebuild(entry.snapshot)
    stamp(item, mailId, entry.txId)
    giveItem(player:getInventory(), item)
    log("claim-in phase2 " .. mailId .. " item delivered id=" .. item:getID())
    entry.state = "claimed"
    p.pendingClaims[mailId] = nil
    p.seq = nextSeq()
    pcall(function() player:transmitModData() end)
    log("claim-in phase3 " .. mailId .. " state=claimed, pending cleared")
end

-- ---------- A9：list-out ----------
local function listOut(player, itemId)
    local inv = player:getInventory()
    local item = inv:getItemWithID(itemId)
    if not item then log("list-out: item " .. tostring(itemId) .. " not in inventory"); reply(player, "toast", { text = "item not in backpack" }); return end
    local p = pmd(player)
    local s = nextSeq()
    local opId = "op-" .. s
    p.pendingOuts[opId] = { itemId = itemId, snapshot = snapshotOf(item), kind = "listing", seq = s }
    log("list-out phase1 " .. opId .. " pending recorded itemId=" .. itemId)
    takeItem(inv, item)
    log("list-out phase2 " .. opId .. " item removed from backpack")
    md.listings[opId] = { seller = player:getUsername(), itemId = itemId, snapshot = p.pendingOuts[opId].snapshot, sold = false, seq = s }
    p.seq = nextSeq()
    pcall(function() player:transmitModData() end)
    log("list-out phase3 " .. opId .. " listing created; pending KEPT until durable (seq=" .. s .. ")")
end

-- ---------- A9 規則三：登入收斂 ----------
local function reconcile(player)
    local u = player:getUsername()
    local inv = player:getInventory()
    local p = pmd(player)
    local actions = {}
    for mailId, entry in pairs(md.mailbox) do
        if entry.owner == u then
            local has = findStamped(inv, mailId)
            if entry.state == "claimed" and not has then
                local item = rebuild(entry.snapshot); stamp(item, mailId, entry.txId)
                giveItem(inv, item)
                actions[#actions + 1] = "redeliver " .. mailId
            elseif entry.state ~= "claimed" and has then
                entry.state = "claimed"; p.pendingClaims[mailId] = nil
                actions[#actions + 1] = "mark-claimed " .. mailId
            end
        end
    end
    local items = inv:getItems()
    local orphans = {}
    for i = 0, items:size() - 1 do
        local it = items:get(i)
        local m = it:getModData().MinidoracatEconomy
        if m and m.mailId and not md.mailbox[m.mailId] then orphans[#orphans + 1] = it end
    end
    for _, it in ipairs(orphans) do
        takeItem(inv, it)
        actions[#actions + 1] = "remove-orphan " .. tostring(it:getModData().MinidoracatEconomy.mailId)
    end
    local loadedSeq = md.meta.loadedSeq or 0
    for opId, pend in pairs(p.pendingOuts) do
        if md.listings[opId] then
            p.pendingOuts[opId] = nil; actions[#actions + 1] = "clear-pending(listing present) " .. opId
        elseif inv:getItemWithID(pend.itemId) then
            p.pendingOuts[opId] = nil; actions[#actions + 1] = "clear-pending(item still here) " .. opId
        elseif (pend.seq or 0) > loadedSeq then
            md.listings[opId] = { seller = u, itemId = pend.itemId, snapshot = pend.snapshot, sold = false, seq = pend.seq }
            if pend.seq > md.meta.seq then md.meta.seq = pend.seq end -- rule four: never reuse a seq from the rolled-back branch
            p.pendingOuts[opId] = nil; actions[#actions + 1] = "recreate-listing(rolled back: seq " .. tostring(pend.seq) .. " > loadedSeq " .. loadedSeq .. ") " .. opId
        else
            p.pendingOuts[opId] = nil; actions[#actions + 1] = "clear-pending(durable then legitimately gone) " .. opId
        end
    end
    for opId, l in pairs(md.listings) do
        if l.seller == u then
            local dup = inv:getItemWithID(l.itemId)
            if dup then takeItem(inv, dup); actions[#actions + 1] = "remove-dup-original " .. opId end
        end
    end
    pcall(function() player:transmitModData() end)
    log("reconcile " .. u .. ": " .. (#actions == 0 and "nothing to do" or table.concat(actions, "; ")))
    reply(player, "toast", { text = "reconcile: " .. (#actions == 0 and "no-op" or table.concat(actions, "; ")) })
end

-- ---------- A12：終端距離 ----------
local function nearTerminal(player)
    local px, py, pz = player:getX(), player:getY(), player:getZ()
    local best = nil
    for id, t in pairs(md.terminals) do
        if t.z == pz then
            local d = math.max(math.abs(px - t.x), math.abs(py - t.y))
            if not best or d < best then best = d end
        end
    end
    return best
end

-- ---------- A19：整合 API 假 consumer ----------
local function integrationSmoke(player)
    local u = player:getUsername()
    local sources = { MiniMapProto = { dailyMintCap = 0, dailyBurnCap = 1000000, used = { mint = 0, burn = 0 } } }
    local seen = {}
    local function post(src, kind, username, amount, requestId)
        local s = sources[src]
        if not s then return { ok = false, error = "unknown_source" } end
        if seen[requestId] then return { ok = true, duplicate = true } end
        if kind == "credit" and s.used.mint + amount > s.dailyMintCap then return { ok = false, error = "cap_exceeded" } end
        local bal = md.wallet[username] or 0
        if kind == "debit" and bal < amount then return { ok = false, error = "insufficient_funds" } end
        md.wallet[username] = bal + (kind == "credit" and amount or -amount)
        s.used[kind == "credit" and "mint" or "burn"] = s.used[kind == "credit" and "mint" or "burn"] + amount
        seen[requestId] = true
        return { ok = true, txId = "TX-" .. nextSeq() }
    end
    md.wallet[u] = 500
    local r = {}
    r[#r + 1] = "credit unregistered=" .. tostring(post("Nobody", "credit", u, 10, "r1").error)
    r[#r + 1] = "credit cap0=" .. tostring(post("MiniMapProto", "credit", u, 10, "r2").error)
    r[#r + 1] = "debit 120 ok=" .. tostring(post("MiniMapProto", "debit", u, 120, "r3").ok) .. " bal=" .. md.wallet[u]
    r[#r + 1] = "debit dup=" .. tostring(post("MiniMapProto", "debit", u, 120, "r3").duplicate) .. " bal=" .. md.wallet[u]
    r[#r + 1] = "debit 9999=" .. tostring(post("MiniMapProto", "debit", u, 9999, "r4").error)
    log("A19 " .. table.concat(r, " | "))
    reply(player, "toast", { text = "A19: " .. table.concat(r, " | ") })
end

-- ---------- 指令分派 ----------
local handlers = {}

handlers.reconcile = function(player, args)
    log("A18 reconcile received from " .. player:getUsername() .. " (client first tick) hoursSurvived=" .. tostring(player:getHoursSurvived()))
    reconcile(player)
end

handlers.give = function(player, args)
    local item = instanceItem("Base.Axe"); item:setCondition(3)
    giveItem(player:getInventory(), item)
    log("A8 give axe id=" .. item:getID() .. " to " .. player:getUsername())
    reply(player, "toast", { text = "axe given id=" .. item:getID() })
end

handlers.take = function(player, args)
    local item = player:getInventory():getFirstTypeRecurse("Base.Axe")
    if not item then reply(player, "toast", { text = "no axe in backpack" }); return end
    takeItem(player:getInventory(), item)
    log("A8 take axe id=" .. item:getID())
    reply(player, "toast", { text = "axe taken" })
end

handlers.listout = function(player, args)
    listOut(player, tonumber(args.itemId))
    reply(player, "toast", { text = "list-out done (see server log)" })
end

handlers.mailclaim = function(player, args)
    local mailId = "M-" .. nextSeq()
    md.mailbox[mailId] = { owner = player:getUsername(), state = "ready", txId = "TX-" .. md.meta.seq, snapshot = { type = "Base.Axe", condition = 7, uses = 1, age = 0 } }
    log("A9 mailbox entry " .. mailId .. " created (ready)")
    claimIn(player, mailId)
    reply(player, "toast", { text = "claim-in done " .. mailId })
end

handlers.mark = function(player, args)
    local p = pmd(player)
    p.seq = nextSeq(); p.markedAt = getTimestampMs()
    local ok, err = pcall(function() player:transmitModData() end)
    log("A10 mark player modData seq=" .. p.seq .. " transmitModData=" .. tostring(ok) .. " " .. tostring(err or ""))
    reply(player, "toast", { text = "watermark seq=" .. p.seq })
end

handlers.readmark = function(player, args)
    local p = player:getModData().MinidoracatEconomy
    log("A10 readmark: " .. (p and ("seq=" .. tostring(p.seq) .. " markedAt=" .. tostring(p.markedAt)) or "nil"))
    reply(player, "toast", { text = "watermark read: " .. (p and tostring(p.seq) or "nil") })
end

handlers["terminal.register"] = function(player, args)
    local ok = player:getRole():hasCapability(Capability.AddItem)
    log(string.format("A11 terminal.register by %s role=%s hasCapability(AddItem)=%s at %s,%s,%s",
        player:getUsername(), tostring(player:getRole():getName()), tostring(ok), tostring(args.x), tostring(args.y), tostring(args.z)))
    if not ok then reply(player, "toast", { text = "REJECT: no capability" }); return end
    local id = "T-" .. nextSeq()
    md.terminals[id] = { x = args.x, y = args.y, z = args.z, type = args.kind or "trade" }
    reply(player, "terminals", { list = md.terminals })
    reply(player, "toast", { text = "terminal registered " .. id })
end

handlers.terminals = function(player, args) reply(player, "terminals", { list = md.terminals }) end

handlers.buy = function(player, args)
    local d = nearTerminal(player)
    local ok = d ~= nil and d <= 2
    log(string.format("A12 buy by %s nearest terminal distance=%s -> %s", player:getUsername(), tostring(d), ok and "ACCEPT" or "REJECT"))
    reply(player, "toast", { text = ok and ("BUY ACCEPT (dist " .. d .. ")") or ("BUY REJECT not near terminal (dist " .. tostring(d) .. ")") })
end

handlers.role = function(player, args)
    local role = player:getRole()
    local caps = {}
    for _, name in ipairs({ "AddItem", "SaveWorld", "ToggleGodModHimself", "LoginOnServer" }) do
        caps[#caps + 1] = name .. "=" .. tostring(role:hasCapability(Capability[name]))
    end
    log("A13 role of " .. player:getUsername() .. ": " .. tostring(role:getName()) .. " " .. table.concat(caps, " ") .. " | client said accessLevel=" .. tostring(args.accessLevel))
    reply(player, "toast", { text = "server role=" .. tostring(role:getName()) })
end

handlers.radio = function(player, args)
    local radio = getZomboidRadio()
    if not radio then log("A14 getZomboidRadio() is nil on server"); reply(player, "toast", { text = "radio nil" }); return end
    local ok1, e1 = pcall(function() radio:addChannelName("MarketRadio", RADIO_FREQ, "Economy") end)
    -- source must be > 3 tiles from the listener (ZomboidRadio.java:698-701): use the nearest registered terminal, else offset
    local x, y = math.floor(player:getX()), math.floor(player:getY())
    local best, bestD = nil, nil
    for _, t in pairs(md.terminals) do
        local d = math.abs(t.x - x) + math.abs(t.y - y)
        if not bestD or d < bestD then best, bestD = t, d end
    end
    if best then x, y = best.x, best.y else x = x + 10 end
    local ok2, e2 = pcall(function()
        radio:SendTransmission(x, y, RADIO_FREQ, "TEST BROADCAST fire axe 450 survivor coins", nil, nil, 1.0, 0.85, 0.4, tonumber(args.strength) or 50, false)
    end)
    log(string.format("A14 radio addChannelName=%s %s SendTransmission=%s %s from %d,%d strength=%s", tostring(ok1), tostring(e1 or ""), tostring(ok2), tostring(e2 or ""), x, y, tostring(args.strength)))
    reply(player, "toast", { text = "broadcast 92.4 (strength " .. tostring(args.strength) .. ")" })
end

handlers.integ = function(player, args) integrationSmoke(player) end
-- A6: B42 MP body damage is server-authoritative (client BodyDamage.Update returns early for alive players, BodyDamage.java:2099-2107)
handlers.suicide = function(player, args)
    local bd = player:getBodyDamage()
    bd:ReduceGeneralHealth(100000)
    log("A6 server-side ReduceGeneralHealth applied to " .. player:getUsername() .. " overall=" .. tostring(bd:getOverallBodyHealth()))
end


Events.OnClientCommand.Add(function(module, command, player, args)
    if module ~= MODULE then return end
    local h = handlers[command]
    if not h then log("unknown command " .. tostring(command)); return end
    local ok, err = pcall(h, player, args or {})
    if not ok then log("command " .. command .. " error: " .. tostring(err)) end
end)

-- ---------- A6：玩家生命週期事件 ----------
Events.OnNewGame.Add(function(player, square)
    log("A6 OnNewGame player=" .. tostring(player and player:getUsername()) .. " square=" .. tostring(square))
end)
Events.OnCreatePlayer.Add(function(index, player)
    log("A6 OnCreatePlayer index=" .. tostring(index) .. " player=" .. tostring(player and player:getUsername()))
end)
Events.OnCharacterDeath.Add(function(character)
    log("A6 OnCharacterDeath character=" .. tostring(character) .. " username=" .. tostring(character and character.getUsername and character:getUsername()))
end)
Events.OnPlayerDeath.Add(function(player)
    log("A6 OnPlayerDeath fired on server (unexpected) player=" .. tostring(player and player:getUsername()))
end)

-- ---------- A20：生存時數 vs 壁鐘 ----------
local lastA20 = 0
Events.OnTickEvenPaused.Add(function()
    local now = getTimestampMs()
    if now - lastA20 < 60000 then return end
    lastA20 = now
    local players = getOnlinePlayers()
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        log(string.format("A20 %s hoursSurvived=%.3f wall=%d", p:getUsername(), p:getHoursSurvived(), now))
    end
end)

Events.OnServerStarted.Add(function()
    md = ModData.getOrCreate("MinidoracatEconomyProtoClient")
    md.mailbox = md.mailbox or {}
    md.listings = md.listings or {}
    md.terminals = md.terminals or {}
    md.wallet = md.wallet or {}
    local prevSeq = (md.meta and md.meta.seq) or 0
    md.meta = { epoch = tostring(getTimestampMs()), seq = prevSeq, loadedSeq = prevSeq }
    local n, nl, nm = 0, 0, 0
    for _ in pairs(md.terminals) do n = n + 1 end
    for _ in pairs(md.listings) do nl = nl + 1 end
    -- A16: server-side absolute cache path for the admin panel's "copy path" (LuaManager.java:8835-8837)
    local okDoc, doc = pcall(getMyDocumentFolder)
    log("A16 getMyDocumentFolder ok=" .. tostring(okDoc) .. " value=" .. tostring(doc))
    for _ in pairs(md.mailbox) do nm = nm + 1 end
    log("client-proto server ready; terminals=" .. n .. " listings=" .. nl .. " mailbox=" .. nm .. " loadedSeq=" .. prevSeq .. " (rollback point)")
end)
