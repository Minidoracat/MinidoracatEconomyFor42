-- 階段 A 拋棄式原型 A7：中央託管的物品快照 → 重建 round-trip（同輪、以及存檔重啟後）。
-- API 出處：instanceItem LuaManager.java:5610-5620（→ InventoryItemFactory.CreateItem；InventoryItemFactory 本身不是 Lua 全域）；setCondition InventoryItem.java:2818；
-- setCurrentUses :2577（Drainable DrainableComboItem.java:72）；setAge :2629；getModData :433；
-- Literature.setAlreadyReadPages Literature.java:456；FluidContainer GameEntity.java:183，addFluid FluidContainer.java:921，
-- Empty :867，getAmount :558，getPrimaryFluid :792；Fluid.Get Fluid.java:99；HandWeapon 配件 HandWeapon.java:1690,1768,1807；
-- Food.isRotten Food.java:1859。

if not isServer() then return end

local TAG = "[MinidoracatEconomyFor42][A7]"
local DIR = "MinidoracatEconomy/proto"
local function log(msg) print(TAG .. " " .. tostring(msg)) end
local function enabled()
    local ok, r = pcall(getFileReader, DIR .. "/enable.txt", false)
    if ok and r then pcall(function() r:close() end); return true end
    return false
end
if not enabled() then return end

local CASES = {
    { name = "axe",     type = "Base.Axe",           condition = 3 },
    { name = "tape",    type = "Base.DuctTape",      uses = 4 },
    { name = "book",    type = "Base.BookCarpentry1", readPages = 0 },
    { name = "petrol",  type = "Base.PetrolCan",     fluid = { name = "Petrol", amount = 3.5 } },
    { name = "beans",   type = "Base.CannedCorn",   age = 12 },
    { name = "apple",   type = "Base.Apple",         age = 2 },   -- 預期不在白名單，只觀察腐敗欄位
    { name = "rifle",   type = "Base.HuntingRifle",  part = "Base.x2Scope" },
}

local function fluidInfo(item)
    local fc = item.getFluidContainer and item:getFluidContainer()
    if not fc then return nil end
    local f = fc:getPrimaryFluid()
    return { name = f and f:getFluidTypeString() or "", amount = fc:getAmount() }
end

local function snapshot(item)
    local s = { type = item:getFullType(), condition = item:getCondition(), uses = item:getCurrentUses(), age = item:getAge() }
    if item.getAlreadyReadPages then s.readPages = item:getAlreadyReadPages() end
    local fi = fluidInfo(item)
    if fi then s.fluidName, s.fluidAmount = fi.name, fi.amount end
    if item.isRotten then s.rotten = item:isRotten() end
    if item.getAllWeaponParts then s.parts = item:getAllWeaponParts():size() end
    local md = item:getModData()
    s.modData = { econTest = md.econTest }
    return s
end

local function rebuild(s)
    local item = instanceItem(s.type)
    if not item then return nil, "CreateItem nil" end
    item:setCondition(s.condition)
    item:setCurrentUses(s.uses)
    item:setAge(s.age)
    if s.readPages and item.setAlreadyReadPages then item:setAlreadyReadPages(s.readPages) end
    if s.fluidName then
        local fc = item:getFluidContainer()
        if fc then
            fc:Empty()
            local fl = Fluid.Get(s.fluidName)
            if fl and s.fluidAmount > 0 then fc:addFluid(fl, s.fluidAmount) end
        end
    end
    if s.modData and s.modData.econTest then item:getModData().econTest = s.modData.econTest end
    return item
end

local function same(a, b)
    local fields = { "type", "condition", "uses", "readPages", "fluidName", "rotten", "parts" }
    for _, f in ipairs(fields) do
        if tostring(a[f]) ~= tostring(b[f]) then return false, f .. ": " .. tostring(a[f]) .. " vs " .. tostring(b[f]) end
    end
    if math.abs((a.age or 0) - (b.age or 0)) > 0.001 then return false, "age" end
    if math.abs((a.fluidAmount or 0) - (b.fluidAmount or 0)) > 0.001 then return false, "fluidAmount" end
    if tostring(a.modData and a.modData.econTest) ~= tostring(b.modData and b.modData.econTest) then return false, "modData" end
    return true
end

local function makeOriginal(c)
    local item = instanceItem(c.type)
    if not item then return nil end
    if c.condition then item:setCondition(c.condition) end
    if c.uses then item:setCurrentUses(c.uses) end
    if c.age then item:setAge(c.age) end
    if c.readPages and item.setAlreadyReadPages then item:setAlreadyReadPages(c.readPages) end
    if c.fluid then
        local fc = item:getFluidContainer()
        if fc then fc:Empty(); fc:addFluid(Fluid.Get(c.fluid.name), c.fluid.amount) end
    end
    if c.part then
        local part = instanceItem(c.part)
        if part then item:attachWeaponPart(part) end
    end
    item:getModData().econTest = "hello-" .. c.name
    return item
end

local function detachAll(item)
    local parts = item:getAllWeaponParts()
    local names = {}
    -- 先複製清單再拆，避免邊拆邊迭代
    local list = {}
    for i = 0, parts:size() - 1 do list[#list + 1] = parts:get(i) end
    for _, p in ipairs(list) do
        item:detachWeaponPart(p)
        names[#names + 1] = p:getFullType()
    end
    return names
end

local function run()
    local md = ModData.getOrCreate("MinidoracatEconomyProtoCodec")
    if md.snapshots then
        log("phase 2: rebuilding from saved snapshots (after restart)")
        for _, c in ipairs(CASES) do
            local s = md.snapshots[c.name]
            if s then
                local ok, item = pcall(rebuild, s)
                if ok and item then
                    local eq, why = same(s, snapshot(item))
                    log(string.format("restart round-trip %-6s %s%s", c.name, eq and "OK" or "MISMATCH", eq and "" or (" (" .. tostring(why) .. ")")))
                else
                    log("restart rebuild failed " .. c.name .. ": " .. tostring(item))
                end
            end
        end
        md.snapshots = nil
        return
    end
    log("phase 1: capture + same-run rebuild")
    md.snapshots = {}
    for _, c in ipairs(CASES) do
        local ok, orig = pcall(makeOriginal, c)
        if not ok or not orig then
            log("create failed " .. c.name .. ": " .. tostring(orig))
        else
            if c.part then
                local names = detachAll(orig)
                log("rifle parts detached: " .. table.concat(names, ",") .. " remaining=" .. orig:getAllWeaponParts():size())
            end
            local s = snapshot(orig)
            md.snapshots[c.name] = s
            log(string.format("captured %-6s cond=%s uses=%s age=%.2f pages=%s fluid=%s/%s rotten=%s parts=%s",
                c.name, tostring(s.condition), tostring(s.uses), s.age or -1, tostring(s.readPages),
                tostring(s.fluidName), tostring(s.fluidAmount), tostring(s.rotten), tostring(s.parts)))
            local ok2, re = pcall(rebuild, s)
            if ok2 and re then
                local eq, why = same(s, snapshot(re))
                log(string.format("same-run round-trip %-6s %s%s", c.name, eq and "OK" or "MISMATCH", eq and "" or (" (" .. tostring(why) .. ")")))
            else
                log("same-run rebuild failed " .. c.name .. ": " .. tostring(re))
            end
        end
    end
    log("snapshots stored in ModData; restart after a save to run phase 2")
end

Events.OnServerStarted.Add(function()
    local ok, err = pcall(run)
    if not ok then log("error: " .. tostring(err)) end
end)
