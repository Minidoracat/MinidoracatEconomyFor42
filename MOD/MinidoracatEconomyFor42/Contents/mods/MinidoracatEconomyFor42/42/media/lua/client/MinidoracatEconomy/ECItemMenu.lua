-- MinidoracatEconomyFor42 - the "Economy" entry of the inventory item menu and of a standing
-- generator's world menu (client). Adds no namespace and registers two events.
--
-- One option of this mod's own, holding a submenu; nothing else in either menu is added to, moved
-- or removed, and no vanilla function is replaced, so the mods that build or prune these menus
-- (CleanUI's own inventory, tsarslib's removeOptionTsar, translation packs wrapping addOption) see
-- exactly one more option. An entry that cannot be used now stays in the submenu, disabled, with
-- the reason on its tooltip; every usable one says on its tooltip what it is about to do. The menu
-- reads only what the client already holds (the shop catalog, the terminal list, the rights) and
-- sends nothing; a click hands the items to the window that does the rest (ECPanel P.takeItems /
-- P.takeGenerator, ECAdminWindow AW.addItem), which judges them again, as the server does after it.
-- Only the first local player (split screen is not served by this mod).
--
-- Engine references (42.21):
--   OnFillInventoryObjectContextMenu (player, context, items)  ISInventoryPaneContextMenu.lua:935;
--     the same createMenu serves the backpack, every container and the floor (:26) and the
--     controller (ISInventoryPane.lua:1542-1593)
--   OnFillWorldObjectContextMenu (player, context, worldobjects, test)  ISWorldObjectContextMenu.lua:213
--   ISContextMenu:addOption / addSubMenu / getNew  ISContextMenu.lua:873, 1075, 1199
--   ISInventoryPaneContextMenu.addToolTip (pooled, returned when the menu closes)  :3417-3426

require "ISUI/ISInventoryPaneContextMenu"
require "MinidoracatEconomy/ECItemRoute"
require "MinidoracatEconomy/ECPanelWidgets"

local EC = MinidoracatEconomy
local C = EC.Client
local Route = C.ItemRoute
local T = "IGUI_MinidoracatEconomy_"
local W = C.PanelWidgets

local function tr(key, ...) return getText(T .. key, ...) end

-- Each menu lends its tooltips from its own pool and takes them back when it is rebuilt
-- (ISInventoryPaneContextMenu.lua:3417-3426, ISWorldObjectContextMenu.addToolTip): the handler
-- of the menu being built sets which one.
local newTip = nil

-- One entry: enabled with what it does, or disabled with why not. The native option calls
-- fn(target, ...) - the target first, as the mouse and the controller both dispatch it
-- (ISContextMenu.lua:70, 259).
local function entry(sub, label, why, says, fn, target, a, b)
    local option = sub:addOption(label, target, fn, a, b)
    local tip = newTip()
    tip:setVisible(false)
    tip.description = why or says
    tip.maxLineWidth = 420
    option.toolTip = tip
    if why then option.notAvailable = true end
    return option
end

-- Why no trade can go out from here now (the window's own write gate, ECPanel tradeAllowed).
local function tradeRefusal()
    if C.wallet and C.wallet.frozen then return W.shopError("account_frozen") end
    if not C.nearTerminal() then return W.shopError("not_at_terminal") end
    return nil
end

local function onTake(items, target) C.Panel.takeItems(target, items) end
local function onTakeGenerator(obj, target) C.Panel.takeGenerator(target, obj) end
local function onAdmin(item, tab) C.AdminWindow.addItem(tab, item) end

-- The administrator's two entries, for an item or a generator's full type.
local function adminEntries(sub, item, fullType)
    if not (C.AdminPanel and C.AdminPanel.canRead()) then return end
    local record = C.ItemPicker and C.ItemPicker.universe().byType[fullType] or nil
    local hidden = record == nil and tr("Drop_Hidden") or nil
    entry(sub, tr("Menu_AddSku"), hidden or (not C.AdminPanel.canWrite() and C.UI.adminErrorText("forbidden")) or nil,
        tr("Menu_AddSku_Tip"), onAdmin, item, "Shop")
    entry(sub, tr("Menu_AddRule"), hidden or (record and record.fixed and tr("Drop_Fixed")) or nil,
        tr("Menu_AddRule_Tip"), onAdmin, item, "Whitelist")
end

local function group(context)
    local parent = context:addOption(tr("Menu_Group"), nil, nil)
    local sub = ISContextMenu:getNew(context)
    context:addSubMenu(parent, sub)
    return sub
end

local function onFillInventory(playerNum, context, items)
    if playerNum ~= 0 or not isClient() or C.session == nil then return end
    local player = getSpecificPlayer(playerNum)
    local list = Route.items(items)
    local item = list[1]
    if player == nil or item == nil then return end
    newTip = ISInventoryPaneContextMenu.addToolTip
    local sub = group(context)
    local blocked = Route.blocked(item, player)
    local gate = tradeRefusal()
    local listWhy = gate or (blocked and W.marketError({ error = blocked })) or nil
    local moving = Route.move(item, player)
    local note = moving == "hands" and tr("Menu_Hands") or (moving == "main" and tr("Menu_Move")) or nil
    local function says(key) return note and (tr(key) .. " " .. note) or tr(key) end
    entry(sub, tr("Menu_List"), listWhy, says("Menu_List_Tip"), onTake, list, "list")
    entry(sub, tr("Menu_Auction"), listWhy, says("Menu_Auction_Tip"), onTake, list, "auction")
    -- offered only where the shop really buys this item back; the catalog is read at login
    if W.buybackRow(C.shop, item:getFullType()) ~= nil then
        entry(sub, tr("Menu_Sell"), gate or (blocked and W.shopError(blocked)) or nil, says("Menu_Sell_Tip"),
            onTake, list, "sell")
    end
    adminEntries(sub, item, item:getFullType())
end

-- The standing generator under the cursor, if any (it is a special object of its square).
local function generatorAt(worldobjects)
    for _, o in ipairs(worldobjects) do
        if instanceof(o, "IsoGenerator") then return o end
        local square = o.getSquare and o:getSquare()
        local objects = square and square:getObjects()
        for i = 0, (objects and objects:size() or 0) - 1 do
            local obj = objects:get(i)
            if instanceof(obj, "IsoGenerator") then return obj end
        end
    end
    return nil
end

local function onFillWorld(playerNum, context, worldobjects, test)
    if test or playerNum ~= 0 or not isClient() or C.session == nil then return end
    local player = getSpecificPlayer(playerNum)
    local obj = player and generatorAt(worldobjects)
    if obj == nil then return end
    local ok, fullType = pcall(function() return obj:getGeneratorItemType() end)
    if not ok or type(fullType) ~= "string" then return end
    newTip = ISWorldObjectContextMenu.addToolTip
    local sub = group(context)
    -- vanilla takes a generator only while nothing is plugged in (ECItemRoute.canTakeGenerator):
    -- when it would refuse, so does every trade entry, and the tooltip says what to do first
    local why = tradeRefusal() or (not Route.canTakeGenerator(obj, player) and tr("Menu_GeneratorRefused")) or nil
    local says = function(key) return tr(key) .. " " .. tr("Menu_GeneratorTip") end
    entry(sub, tr("Menu_List"), why, says("Menu_List_Tip"), onTakeGenerator, obj, "list")
    entry(sub, tr("Menu_Auction"), why, says("Menu_Auction_Tip"), onTakeGenerator, obj, "auction")
    if W.buybackRow(C.shop, fullType) ~= nil then
        entry(sub, tr("Menu_Sell"), why, says("Menu_Sell_Tip"), onTakeGenerator, obj, "sell")
    end
    adminEntries(sub, fullType, fullType)
end

Events.OnFillInventoryObjectContextMenu.Add(onFillInventory)
Events.OnFillWorldObjectContextMenu.Add(onFillWorld)
