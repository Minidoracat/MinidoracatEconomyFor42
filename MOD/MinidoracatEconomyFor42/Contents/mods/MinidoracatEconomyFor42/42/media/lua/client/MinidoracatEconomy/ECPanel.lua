-- MinidoracatEconomyFor42 — Economy Center window (client). Stage D: Wallet / Rewards / Shop /
-- Market / Mailbox tabs (Admin stays in ECAdminPanel).
--
-- Layout follows docs/design-proposals/images/05b-wallet-rewards.png and 20-wallet-statement.png:
-- skinned title bar, status line, balance strip, tab bar, two-column cards. Everything is painted
-- through MinidoracatUIFor42 v1 (Theme/Skin rounded surfaces, VirtualList statement, Icons) —
-- the framework is a hard dependency (mod.info require=), so without it the window simply does
-- not open (logged), the family fail-soft rule: never a half-drawn window.
--
-- Window chrome = vanilla ISCollapsableWindow (drag, close/pin/collapse buttons, resize widget,
-- ISLayoutManager persistence) with prerender/render overridden the same way NBPanel and the
-- Cleaner picker do (rounded fill instead of Panel_TitleBar.png).
--
-- Engine references (snapshot 42.20.4-20260826):
--   getHourMinute()        LuaManager.java:8996-8998 -> getHourMinuteJava :1569-1576
--                          (Calendar.getInstance() = local zone) -> local UTC offset for timestamps
--   getTextOrNull(key)     LuaManager.java:8558-8560
--   IsoGameCharacter.getHoursSurvived (client copy, display only; the server grants milestones)
--   UIElement anchors      UIElement.java:1411-1430 (children shift with the parent size; every
--                          child here is positioned explicitly in layout(), anchors stay default)

require "ISUI/ISCollapsableWindow"
require "ISUI/ISButton"
require "ISUI/ISLayoutManager"
require "ISUI/ISPanel"
require "ISUI/ISTextEntryBox"

if not MinidoracatEconomy or not MinidoracatEconomy.Client or not MinidoracatEconomy.Client.UI then
    require "MinidoracatEconomy/ECWidgets"
end
local EC = MinidoracatEconomy
local C = EC.Client
local U = C.UI
require "MinidoracatEconomy/ECAdminPanel"
require "MinidoracatEconomy/ECIconCache"

local P = {}
C.Panel = P

local LAYOUT_NAME = "MinidoracatEconomyPanel"
local MIN_WIDTH, MIN_HEIGHT = 1000, 560
local PAD, ROW, CHIP_H, COIN, COIN_SMALL, T = U.PAD, U.ROW, U.CHIP_H, U.COIN, U.COIN_SMALL, U.T
local STATUS_H = 24
local STRIP_H = 60
local COIN_STRIP = 36            -- the balance strip is the one place the icon is the hero
local TAB_H = 36
local TAB_W = 140
local CARD_TITLE_H = U.CARD_TITLE_H
local LEFT_W = 300
local fontH = U.fontH
local color, fill, border, text, textWidth, fitText, textRight, textCentre, strike, drawCoin = U.color, U.fill, U.border, U.text, U.textWidth, U.fitText, U.textRight, U.textCentre, U.strike, U.drawCoin
local clockText, stampText, durationText, amountText, signedText, hasBit, kindText, card = U.clockText, U.stampText, U.durationText, U.amountText, U.signedText, U.hasBit, U.kindText, U.card
local localOffsetMinutes = U.localOffsetMinutes
local Button, Cell = U.Button, U.StatementCell


-- ---------- shop / mailbox pieces ----------

local TIMEOUT_MS = 8000            -- one write in flight per page, same window as the admin dialog
local SHOP_POLL_MS = 30000         -- a catalog snapshot older than this is asked for again
local ITEM_ICON = 32

-- Two text lines plus the item icon; the font scale decides, not a constant (fontH is filled by
-- U.init, so this is a function and not a load-time number).
local function itemRowHeight()
    return math.max(math.floor(ROW * 1.6), fontH.small * 2 + 16)
end

-- Picker tile (the backpack grid): a 48px icon over one fitted name line, the way the vanilla
-- inventory paints an item. 72x88 at the default font, taller when the player scales the UI font.
local TILE_ICON = 48
local function tileSize()
    return 72, math.max(88, TILE_ICON + fontH.small + 26)
end

local function newEntry(width, height, placeholder, numbers)
    local e = ISTextEntryBox:new("", 0, 0, width, height)
    e:initialise()
    e:instantiate()
    local bg, br = color("well"), color("border")
    e.backgroundColor = { r = bg.r, g = bg.g, b = bg.b, a = 0.9 }
    e.borderColor = { r = br.r, g = br.g, b = br.b, a = 1 }
    if e.setMaxTextLength then e:setMaxTextLength(32) end
    if e.setClearButton then e:setClearButton(true) end
    if placeholder and e.setPlaceholderText then e:setPlaceholderText(placeholder) end
    if numbers and e.setOnlyNumbers then e:setOnlyNumbers(true) end
    return e
end

local function entryText(e)
    local ok, value = pcall(function() return e:getInternalText() end)
    if ok and type(value) == "string" then return value end
    return ""
end

local function setEntryText(e, str)
    if not e then return end
    pcall(function() e:setText(str or "") end)
end

-- Item display: the engine name (getItemNameFromFullType, LuaManager.java:8579-8583) and the item
-- script's inventory texture (ScriptManager.instance:FindItem -> getNormalTexture; a script may
-- ship none). Both are cached per fullType: a catalog reply must not walk the script list again,
-- and neither call belongs in a per-frame paint.
local itemNames, itemTextures = {}, {}

local function itemName(fullType)
    local name = itemNames[fullType]
    if name == nil then
        local ok, value = pcall(getItemNameFromFullType, fullType)
        name = (ok and type(value) == "string" and value ~= "") and value or tostring(fullType)
        itemNames[fullType] = name
    end
    return name
end

-- The script's own DisplayName (Item.java:493-495): the untranslated, usually English, name.
-- Shown next to the localised name (and searched) so players on any language can find "Nails";
-- nil when it is the same string as the localised name or the script is unknown.
local itemBaseNames = {}
local function itemBaseName(fullType)
    local base = itemBaseNames[fullType]
    if base == nil then
        base = false
        local ok, script = pcall(function() return ScriptManager.instance:FindItem(fullType) end)
        if ok and script then
            local okName, value = pcall(function() return script:getDisplayName() end)
            if okName and type(value) == "string" and value ~= "" then base = value end
        end
        itemBaseNames[fullType] = base
    end
    if not base or base == itemName(fullType) then return nil end
    return base
end

local function itemTexture(fullType)
    local tex = itemTextures[fullType]
    if tex == nil then
        tex = false
        local ok, script = pcall(function() return ScriptManager.instance:FindItem(fullType) end)
        if ok and script then
            local okTex, value = pcall(function() return script:getNormalTexture() end)
            if okTex and value then tex = value end
        end
        itemTextures[fullType] = tex
    end
    return tex or nil
end

local function drawIcon(el, tex, x, y, size)
    if tex then el:drawTextureScaled(tex, x, y, size, size, 1, 1, 1, 1) end
end

-- shop.buy and mail.claim share one error key space (Shop_Error_<code>, timeout included)
local function shopError(code)
    if code == nil then code = "unknown" end
    return getTextOrNull(T .. "Shop_Error_" .. tostring(code)) or getText(T .. "Rewards_Error_generic", tostring(code))
end

-- market.* answers stack their own code space on top of the shop one: a listing error
-- (Market_Error_*), a whitelist refusal the picker also paints per row (Market_Reason_*),
-- then the shared codes (not_at_terminal, account_frozen, insufficient_funds, timeout...).
-- Takes the whole reply, not just the code: price_range carries the bounds.
local function marketError(args)
    local code = tostring((args and args.error) or "unknown")
    if code == "price_range" then
        return getText(T .. "Market_Error_price_range",
            amountText(args.min), amountText(args.max))
    end
    return getTextOrNull(T .. "Market_Error_" .. code) or getTextOrNull(T .. "Market_Reason_" .. code)
        or getTextOrNull(T .. "Shop_Error_" .. code) or getText(T .. "Rewards_Error_generic", code)
end

-- Second row line: whatever of condition / uses / fluid the server sent for this item.
local function listingStatus(it)
    local parts = {}
    local cond = tonumber(it.condition)
    if cond then parts[#parts + 1] = getText(T .. "Market_Condition", tostring(cond)) end
    local uses = tonumber(it.uses)
    if uses then parts[#parts + 1] = getText(T .. "Market_Uses", tostring(uses)) end
    if type(it.fluid) == "string" and it.fluid ~= "" then
        parts[#parts + 1] = getText(T .. "Market_Fluid", it.fluid, tostring(tonumber(it.fluidAmount) or 0))
    end
    if #parts == 0 then return nil end
    return table.concat(parts, " / ")
end

-- Percentages the server quotes are applied the way the server applies them (round up, and a
-- listing fee is never zero unless the fee itself is switched off).
local function ceilPercent(value, percent)
    if percent <= 0 or value <= 0 then return 0 end
    return math.ceil(value * percent / 100)
end

local function listingFee(price, feePercent)
    if feePercent <= 0 or price <= 0 then return 0 end
    return math.max(1, ceilPercent(price, feePercent))
end

-- One market row (browse page or own listings). `mine` is the page, `own` the seller test: the
-- browse page shows the player their own listing (so they see their price next to the others)
-- but offers Market_Own instead of a buy chip.
local function listingRow(it, currency, username, offsetMin, mine)
    local price = tonumber(it.price) or 0
    local name = itemName(it.item)
    local alt = it.name
    if type(alt) ~= "string" or alt == "" or alt == name then alt = itemBaseName(it.item) end
    local seller = tostring(it.seller or "")
    local own = mine or (username ~= nil and seller == username)
    -- a listing runs for days: only the last day is worth counting down, before that the date
    -- says more than "168 hours"
    local expires = tonumber(it.expiresAt)
    local expiresText = "-"
    if expires then
        local left = expires - EC.now()
        expiresText = left > 86400000 and stampText(expires, offsetMin) or durationText(left)
    end
    return {
        id = it.id, item = it.item, seller = seller, price = price, currency = currency,
        name = name, altName = alt, texture = itemTexture(it.item),
        statusText = listingStatus(it), priceText = amountText(price), expiresText = expiresText,
        own = own, mine = mine, actionMuted = own and not mine,
        actionLabel = mine and getText(T .. "Market_Cancel")
            or (own and getText(T .. "Market_Own") or getText(T .. "Market_Buy")),
    }
end

-- One backpack candidate. The tile itself only has room for the name, so everything else the
-- player may want (the script name, the condition/uses line, and the server's refusal when the
-- item may not be listed) is joined once here for the picker's status line.
local function candidateRow(it)
    local ok = it.ok == true
    local name = itemName(it.item)
    local alt = itemBaseName(it.item)
    local status = listingStatus(it)
    local reason = nil
    if not ok then reason = marketError({ error = it.reason }) end
    local detail = alt and (name .. " (" .. alt .. ")") or name
    if status then detail = detail .. " - " .. status end
    if reason then detail = detail .. " - " .. reason end
    return {
        itemId = it.itemId, item = it.item, ok = ok,
        name = name, altName = alt, texture = itemTexture(it.item),
        detailText = detail,
    }
end

-- One catalog row: every string the cell paints is built here (they change with the snapshot,
-- never per frame), `remaining` keeps the raw number the buy dialog clamps its count with.
local function shopRow(it, currency)
    local cap = tonumber(it.dailyCap) or 0
    local remaining = tonumber(it.remaining)
    local remainText, remainToken, soldOut = getText(T .. "Shop_Unlimited"), "textMuted", false
    if cap > 0 then
        local left = remaining or cap
        soldOut = left <= 0
        remainText = soldOut and getText(T .. "Shop_SoldOut") or (tostring(left) .. " / " .. tostring(cap))
        remainToken = soldOut and "warn" or "text"
    end
    local qty = tonumber(it.qty) or 1
    return {
        id = it.id, item = it.item, qty = qty, price = tonumber(it.price) or 0,
        dailyCap = cap, remaining = remaining, soldOut = soldOut, currency = currency,
        name = itemName(it.item), altName = itemBaseName(it.item), texture = itemTexture(it.item),
        qtyText = getText(T .. "Shop_QtyPer", tostring(qty)),
        priceText = amountText(it.price), remainText = remainText, remainToken = remainToken,
        buyLabel = getText(T .. "Shop_Buy"),
    }
end

-- Shop row: icon + name over "N per lot", the unit price, today's remaining share, the buy chip.
-- Column edges come from Panel:layout (list.cols) and `list.buyDisabled` greys every chip while
-- the write gate is closed (frozen account, or no terminal within reach).
local ShopCell = ISPanel:derive("MinidoracatEconomyShopCell")

function ShopCell:render()
    local e = self.entry
    if not e then return end
    local cols = self.list.cols
    local w, h = self.width, self.height
    if self.index % 2 == 0 then fill(self, 0, 0, w, h, "card", "rect") end
    if self:isMouseOver() then fill(self, 0, 0, w, h, "hover", "rect") end
    drawIcon(self, e.texture, cols.icon, math.floor((h - ITEM_ICON) / 2), ITEM_ICON)
    local half = math.floor(h / 2)
    local nameText = fitText(e.name, cols.nameW)
    text(self, nameText, cols.name, half - fontH.small - 2, "text")
    if e.altName then
        local altX = cols.name + textWidth(nameText) + 8
        local altW = cols.name + cols.nameW - altX
        if altW > 20 then text(self, fitText(e.altName, altW), altX, half - fontH.small - 2, "textFaint") end
    end
    text(self, e.qtyText, cols.name, half + 2, "textFaint")
    local ty = math.floor((h - fontH.small) / 2)
    textRight(self, e.priceText, cols.priceR, ty, "accent")
    local coinX = cols.priceR - textWidth(e.priceText) - COIN_SMALL - 4
    if coinX > cols.name + cols.nameW then
        drawCoin(self, e.currency, coinX, math.floor((h - COIN_SMALL) / 2), COIN_SMALL)
    end
    textRight(self, e.remainText, cols.remainR, ty, e.remainToken)
    local off = self.list.buyDisabled == true or e.soldOut
    border(self, cols.buyX, math.floor((h - CHIP_H) / 2), cols.buyW, CHIP_H, off and "border" or "accent", "pill")
    textCentre(self, e.buyLabel, cols.buyX + cols.buyW / 2, ty, off and "textFaint" or "text")
end

-- Mailbox row: icon + name x count over its source, the timestamp, the claim chip.
local MailCell = ISPanel:derive("MinidoracatEconomyMailCell")

function MailCell:render()
    local e = self.entry
    if not e then return end
    local cols = self.list.cols
    local w, h = self.width, self.height
    if self.index % 2 == 0 then fill(self, 0, 0, w, h, "card", "rect") end
    if self:isMouseOver() then fill(self, 0, 0, w, h, "hover", "rect") end
    drawIcon(self, e.texture, cols.icon, math.floor((h - ITEM_ICON) / 2), ITEM_ICON)
    local half = math.floor(h / 2)
    local nameText = fitText(e.nameText, cols.nameW)
    text(self, nameText, cols.name, half - fontH.small - 2, "text")
    if e.altName then
        local altX = cols.name + textWidth(nameText) + 8
        local altW = cols.name + cols.nameW - altX
        if altW > 20 then text(self, fitText(e.altName, altW), altX, half - fontH.small - 2, "textFaint") end
    end
    text(self, e.fromText, cols.name, half + 2, "textFaint")
    local ty = math.floor((h - fontH.small) / 2)
    textRight(self, e.timeText, cols.timeR, ty, "textFaint")
    local off = self.list.claimDisabled == true
    border(self, cols.claimX, math.floor((h - CHIP_H) / 2), cols.claimW, CHIP_H, off and "border" or "accent", "pill")
    textCentre(self, e.claimLabel, cols.claimX + cols.claimW / 2, ty, off and "textFaint" or "text")
end

-- Market row: icon + name over the condition/uses/fluid line, the seller, the price, what is
-- left of the listing window, and the buy/cancel chip. `list.actionDisabled` closes every chip
-- at once (frozen, no terminal in reach, a write in flight); an own listing on the browse page
-- paints Market_Own as plain grey text — there is no chip to press at all.
local ListingCell = ISPanel:derive("MinidoracatEconomyListingCell")

function ListingCell:render()
    local e = self.entry
    if not e then return end
    local cols = self.list.cols
    local w, h = self.width, self.height
    if self.index % 2 == 0 then fill(self, 0, 0, w, h, "card", "rect") end
    if self:isMouseOver() then fill(self, 0, 0, w, h, "hover", "rect") end
    drawIcon(self, e.texture, cols.icon, math.floor((h - ITEM_ICON) / 2), ITEM_ICON)
    local half = math.floor(h / 2)
    local nameText = fitText(e.name, cols.nameW)
    text(self, nameText, cols.name, half - fontH.small - 2, "text")
    if e.altName then
        local altX = cols.name + textWidth(nameText) + 8
        local altW = cols.name + cols.nameW - altX
        if altW > 20 then text(self, fitText(e.altName, altW), altX, half - fontH.small - 2, "textFaint") end
    end
    if e.statusText then text(self, fitText(e.statusText, cols.nameW), cols.name, half + 2, "textFaint") end
    local ty = math.floor((h - fontH.small) / 2)
    text(self, fitText(e.seller, cols.sellerW), cols.sellerX, ty, "textMuted")
    textRight(self, e.priceText, cols.priceR, ty, "accent")
    local coinX = cols.priceR - textWidth(e.priceText) - COIN_SMALL - 4
    if coinX > cols.sellerX + cols.sellerW then
        drawCoin(self, e.currency, coinX, math.floor((h - COIN_SMALL) / 2), COIN_SMALL)
    end
    textRight(self, e.expiresText, cols.expiresR, ty, "textFaint")
    if e.actionMuted then
        textCentre(self, e.actionLabel, cols.actionX + cols.actionW / 2, ty, "textFaint")
        return
    end
    local off = self.list.actionDisabled == true
    border(self, cols.actionX, math.floor((h - CHIP_H) / 2), cols.actionW, CHIP_H, off and "border" or "accent", "pill")
    textCentre(self, e.actionLabel, cols.actionX + cols.actionW / 2, ty, off and "textFaint" or "text")
end

-- Picker strip (list dialog): the picker is a grid, but VirtualList is a one-column list, so one
-- list row carries a whole strip of tiles (entry = the array of candidates on this line) and
-- paints them itself. Hit testing reads the same cols.tileW, so the click and the paint can never
-- disagree; hover comes from the list (cols.tileW + list.hoverIndex/hoverCol, resolved once per
-- frame by the dialog) instead of the cell's own mouse, which only knows the whole strip.
local CandidateCell = ISPanel:derive("MinidoracatEconomyCandidateCell")

function CandidateCell:render()
    local tiles = self.entry
    if not tiles then return end
    local Skin = U.Skin
    local cols = self.list.cols
    local tw, th = cols.tileW, cols.tileH
    local hoverCol = self.list.hoverIndex == self.index and self.list.hoverCol or nil
    for i = 1, #tiles do
        local e = tiles[i]
        local x = (i - 1) * tw
        local alpha = e.ok and 1 or 0.4
        local iconX = x + math.floor((tw - TILE_ICON) / 2)
        Skin.fill(self, x + 2, 2, tw - 4, th - 4, color("card"), "round", alpha)
        if e.ok and hoverCol == i then
            Skin.fill(self, x + 2, 2, tw - 4, th - 4, color("hover"), "round", 1)
        end
        if e.texture then
            self:drawTextureScaled(e.texture, iconX, 6, TILE_ICON, TILE_ICON, alpha, 1, 1, 1)
        else
            Skin.border(self, iconX, 6, TILE_ICON, TILE_ICON, color("border"), "round", alpha)
        end
        if not e.ok then Skin.dot(self, x + tw - 12, 5, 7, color("negative")) end
        local label = fitText(e.name, tw - 8)
        textCentre(self, label, x + tw / 2, 6 + TILE_ICON + 6, e.ok and "text" or "textFaint")
    end
end

-- ---------- buy dialog ----------
-- Same shape as the admin write dialog (ECAdminPanel Dialog): a panel added to the window,
-- centred over the content area, swallowing the clicks of the page underneath. It never scrolls,
-- so the rows are simply stacked from the font height.
local BuyDialog = ISPanel:derive("MinidoracatEconomyBuyDialog")

function BuyDialog:createChildren()
    local step = math.max(CHIP_H, fontH.medium + 8)
    self.minusButton = Button.create(0, 0, step + 6, step, "-", self, BuyDialog.onStep, "chip")
    self.minusButton.internal = -1
    self:addChild(self.minusButton)
    self.plusButton = Button.create(0, 0, step + 6, step, "+", self, BuyDialog.onStep, "chip")
    self.plusButton.internal = 1
    self:addChild(self.plusButton)
    local buy = getText(T .. "Shop_Buy")
    local bh = math.max(28, fontH.medium + 10)
    self.confirmButton = Button.create(0, 0, math.max(120, textWidth(buy, UIFont.Medium) + 40), bh, buy, self, BuyDialog.onConfirm, "primary")
    self.confirmButton.font = UIFont.Medium
    self:addChild(self.confirmButton)
    local cancel = getText(T .. "Admin_Cancel")
    self.cancelButton = Button.create(0, 0, textWidth(cancel) + 30, bh, cancel, self, BuyDialog.onCancel, "chip")
    self:addChild(self.cancelButton)
end

-- Lots per purchase: the server cap, and never more than today's remaining share.
function BuyDialog:maxCount()
    local max = math.max(1, tonumber(C.shop and C.shop.countMax) or 1)
    local row = self.row
    if row.dailyCap > 0 and row.remaining then max = math.min(max, math.max(1, row.remaining)) end
    return max
end

function BuyDialog:total() return self.count * self.row.price end

function BuyDialog:available()
    local bal = C.wallet and C.wallet.balances and C.wallet.balances[self.row.currency]
    return bal and tonumber(bal.available) or 0
end

function BuyDialog:onStep(button)
    self.count = math.max(1, math.min(self:maxCount(), self.count + button.internal))
    self.message = nil
end

function BuyDialog:onCancel() self.panel:closeBuy() end
function BuyDialog:onConfirm() self.panel:submitBuy(self) end

function BuyDialog:layoutInside(maxW)
    local line = fontH.small + 8
    local step = self.minusButton.height
    local w = math.max(340, math.min(maxW, 440))
    local y = PAD
    self.titleY = y; y = y + fontH.medium + PAD
    self.itemY = y; y = y + math.max(ITEM_ICON, line * 2) + PAD
    self.countY = y; y = y + math.max(step, line) + 6
    self.totalY = y; y = y + line
    self.afterY = y; y = y + line + 6
    -- the error line is always reserved: an answer from the server must not make the dialog
    -- (and with it the confirm button under the cursor) jump
    self.messageY = y; y = y + line + 6
    self.buttonY = y
    self:setWidth(w)
    self:setHeight(y + self.confirmButton.height + PAD)
    self.numW = math.max(34, textWidth("99", UIFont.Medium) + 16)
    self.plusButton:setX(w - PAD - self.plusButton.width)
    self.plusButton:setY(self.countY)
    self.numX = self.plusButton.x - self.numW
    self.minusButton:setX(self.numX - self.minusButton.width)
    self.minusButton:setY(self.countY)
    self.confirmButton:setX(w - PAD - self.confirmButton.width)
    self.confirmButton:setY(self.buttonY)
    self.cancelButton:setX(self.confirmButton.x - 8 - self.cancelButton.width)
    self.cancelButton:setY(self.buttonY)
end

function BuyDialog:prerender()
    local row = self.row
    local w, h = self.width, self.height
    fill(self, 0, 0, w, h, "surface")
    border(self, 0, 0, w, h, "accent")
    text(self, fitText(getText(T .. "Shop_BuyTitle", row.name), w - PAD * 2, UIFont.Medium), PAD, self.titleY, "text", UIFont.Medium)
    drawIcon(self, row.texture, PAD, self.itemY, ITEM_ICON)
    local tx = PAD + ITEM_ICON + PAD
    text(self, fitText(row.name, w - tx - PAD), tx, self.itemY, "text")
    text(self, row.qtyText, tx, self.itemY + fontH.small + 4, "textFaint")
    local max = self:maxCount()
    if self.count > max then self.count = max end
    local stepH = self.minusButton.height
    text(self, getText(T .. "Shop_Count"), PAD, self.countY + math.floor((stepH - fontH.small) / 2), "textMuted")
    textCentre(self, tostring(self.count), self.numX + self.numW / 2, self.countY + math.floor((stepH - fontH.medium) / 2), "text", UIFont.Medium)
    local total = self:total()
    local after = self:available() - total
    local totalText = amountText(total)
    text(self, getText(T .. "Shop_Total"), PAD, self.totalY, "textMuted")
    textRight(self, totalText, w - PAD, self.totalY, "accent")
    drawCoin(self, row.currency, w - PAD - textWidth(totalText) - COIN_SMALL - 4, self.totalY + math.floor((fontH.small - COIN_SMALL) / 2), COIN_SMALL)
    text(self, getText(T .. "Shop_AfterBalance"), PAD, self.afterY, "textMuted")
    textRight(self, amountText(after), w - PAD, self.afterY, after < 0 and "warn" or "text")
    if self.message then text(self, fitText(self.message, w - PAD * 2), PAD, self.messageY, "errorText") end
    local pending = self.panel.buyPending ~= nil
    self.minusButton:setEnable(self.count > 1 and not pending)
    self.plusButton:setEnable(self.count < max and not pending)
    self.confirmButton:setEnable(after >= 0 and not pending and self.panel:tradeAllowed())
end

function BuyDialog:render() end

-- the page underneath must not be operable while the dialog is open
function BuyDialog:onMouseDown() return true end
function BuyDialog:onMouseUp() return true end
function BuyDialog:onMouseMove() return true end

-- ---------- market dialog ----------
-- Same shape as BuyDialog (a child panel centred over the content, swallowing the page's
-- clicks), with four modes on one panel: the purchase, the cancel confirmation, the backpack
-- picker and the pricing step the picker hands over to (the picker switches its own content
-- instead of stacking a second dialog on top of itself).
local MarketDialog = ISPanel:derive("MinidoracatEconomyMarketDialog")

local function confirmLabel(mode)
    if mode == "buy" then return getText(T .. "Market_Buy") end
    if mode == "cancel" then return getText(T .. "Market_Cancel") end
    if mode == "price" then return getText(T .. "Market_List") end
    return nil     -- the picker confirms by picking a row
end

function MarketDialog:createChildren()
    local bh = math.max(28, fontH.medium + 10)
    self.confirmButton = Button.create(0, 0, 120, bh, confirmLabel("buy"), self, MarketDialog.onConfirm, "primary")
    self.confirmButton.font = UIFont.Medium
    self:addChild(self.confirmButton)
    local cancel = getText(T .. "Admin_Cancel")
    self.cancelButton = Button.create(0, 0, textWidth(cancel) + 30, bh, cancel, self, MarketDialog.onCancel, "chip")
    self:addChild(self.cancelButton)
    self.priceEntry = newEntry(140, math.max(26, fontH.small + 12), nil, true)
    self.priceEntry.target = self
    self.priceEntry.onTextChangeFunction = MarketDialog.onPriceChanged
    self:addChild(self.priceEntry)
    local only = getText(T .. "Market_OnlyListable")
    self.onlyButton = Button.create(0, 0, textWidth(only) + 30, math.max(CHIP_H, fontH.small + 10),
        only, self, MarketDialog.onOnlyListable, "chip")
    self.onlyListable = true             -- the backpack is mostly unlistable: start on the useful half
    self.onlyButton.active = true
    self:addChild(self.onlyButton)
    local tw, th = tileSize()
    self.pickList = U.newTable(CandidateCell, th)
    self.pickList.cols.tileW, self.pickList.cols.tileH = tw, th
    -- VirtualList hands onSelect the row (a whole strip of tiles) and no x, so the tile is
    -- resolved here from the click's own x; the scrollbar keeps the framework's handler.
    local scrollDown = self.pickList.onMouseDown
    self.pickList.onMouseDown = function(list, x, y)
        local e = self:tileAt(x, y)
        if e then
            self.panel:onCandidate(e)
            return true
        end
        return scrollDown(list, x, y)
    end
    self:addChild(self.pickList)
end

function MarketDialog:onCancel() self.panel:closeMarketDialog() end
function MarketDialog:onConfirm() self.panel:submitMarket(self) end
function MarketDialog:onPriceChanged() self.message = nil end

function MarketDialog:onOnlyListable()
    self.onlyListable = not self.onlyListable
    self.onlyButton.active = self.onlyListable
    self.pickNote = nil
    self:rebuildGrid()
end

-- The candidate under (x, y), or nil outside the tiles (row gap, empty tail of a strip, the
-- scrollbar column). Returns the strip index and the column too: the paint reads them for hover.
function MarketDialog:tileAt(x, y)
    local list = self.pickList
    local tw = list.cols.tileW
    if not tw or x < 0 or x >= list:cellWidth() then return nil end
    local index = list:indexAt(x, y)
    if not index then return nil end
    local tiles = list:getItems()[index]
    local col = math.floor(x / tw) + 1
    local e = tiles and tiles[col]
    if not e then return nil end
    return e, index, col
end

-- Candidates -> strips of gridCols tiles, dropping the unlistable ones while the filter is on.
-- Called on a fresh snapshot, on the filter chip, and when a resize changes the column count.
function MarketDialog:rebuildGrid()
    local rows = self.panel.candidateRows or {}
    local perRow = math.max(1, self.gridCols or 1)
    local grid, strip, shown, listable = {}, nil, 0, 0
    for i = 1, #rows do
        local e = rows[i]
        if e.ok then listable = listable + 1 end
        if e.ok or not self.onlyListable then
            if not strip or #strip >= perRow then
                strip = {}
                grid[#grid + 1] = strip
            end
            strip[#strip + 1] = e
            shown = shown + 1
        end
    end
    self.candTotal, self.candListable, self.candShown = #rows, listable, shown
    self.pickList:setItems(grid)
end

-- Whole numbers only: the entry filters the keyboard, this filters a paste.
function MarketDialog:priceValue()
    local raw = string.match(entryText(self.priceEntry), "^%s*(.-)%s*$")
    if not string.match(raw, "^%d+$") then return nil end
    local n = tonumber(raw)
    if not n or n <= 0 then return nil end
    return math.floor(n)
end

function MarketDialog:available()
    local currency = (self.row and self.row.currency) or (C.market and C.market.currency)
    local bal = C.wallet and C.wallet.balances and C.wallet.balances[currency]
    return bal and tonumber(bal.available) or 0
end

function MarketDialog:layoutInside(maxW, maxH)
    local line = fontH.small + 8
    local mode = self.mode
    local w
    if mode == "pick" then
        -- the grid is the page: 90% of the content area, never under a readable minimum
        w = math.min(maxW, math.max(640, math.floor(maxW * 0.9)))
    else
        w = math.max(340, math.min(maxW, mode == "cancel" and 480 or 440))
    end
    local y = PAD
    self.titleY = y
    self.priceEntry:setVisible(mode == "price")
    self.pickList:setVisible(mode == "pick")
    self.onlyButton:setVisible(mode == "pick")
    if mode == "pick" then
        -- title, the listable counter and the filter chip share the top line
        local chipH = self.onlyButton.height
        local headH = math.max(fontH.medium, chipH)
        self.onlyButton:setX(w - PAD - self.onlyButton.width)
        self.onlyButton:setY(y + math.floor((headH - chipH) / 2))
        self.countR = self.onlyButton.x - 8
        y = y + headH + PAD
    else
        y = y + fontH.medium + PAD
    end
    if mode == "buy" then
        self.itemY = y; y = y + math.max(ITEM_ICON, line * 2) + PAD
        self.fromY = y; y = y + line
        self.payY = y; y = y + line
        self.afterY = y; y = y + line + 6
    elseif mode == "cancel" then
        self.bodyY = y; y = y + line + 6
    elseif mode == "price" then
        self.itemY = y; y = y + math.max(ITEM_ICON, line) + PAD
        self.priceY = y; y = y + math.max(self.priceEntry.height, line) + 4
        self.hintY = y; y = y + line + 6
        self.feeY = y; y = y + line
        self.youGetY = y; y = y + line + 6
        self.priceEntry:setX(w - PAD - self.priceEntry.width)
        self.priceEntry:setY(self.priceY)
    else
        local tw, th = tileSize()
        local listW = w - PAD * 2
        -- 90% of the content area tall: the tail (status line, error line, buttons) is taken off
        -- the grid so the dialog lands on that height instead of growing past the content area
        local tail = PAD + line + line + 6 + self.cancelButton.height + PAD
        local target = math.min(maxH, math.max(380, math.floor(maxH * 0.9)))
        local listH = math.max(th + 4, target - y - tail)
        self.pickList:setX(PAD); self.pickList:setY(y)
        if self.pickList.width ~= listW or self.pickList.height ~= listH then
            self.pickList:resize(listW, listH)
        end
        local cols = self.pickList.cols
        cols.tileW, cols.tileH = tw, th
        -- the scrollbar (10 wide + 2 margin) appears as soon as the grid overflows: budget for
        -- it always, so the strips never have to reflow when it does
        local perRow = math.max(1, math.floor((listW - 12) / tw))
        if self.gridCols ~= perRow then
            self.gridCols = perRow
            self:rebuildGrid()
        end
        y = y + listH + PAD
        self.statusY = y; y = y + line
    end
    -- the error line is always reserved: an answer from the server must not make the dialog
    -- (and with it the button under the cursor) jump
    self.messageY = y; y = y + line + 6
    self.buttonY = y
    self:setWidth(w)
    self:setHeight(y + self.cancelButton.height + PAD)
    local label = confirmLabel(mode)
    self.confirmButton:setVisible(label ~= nil)
    if label then
        if self.confirmButton.title ~= label then self.confirmButton:setTitle(label) end
        self.confirmButton:setWidth(math.max(120, textWidth(label, UIFont.Medium) + 40))
        self.confirmButton:setX(w - PAD - self.confirmButton.width)
        self.confirmButton:setY(self.buttonY)
        self.cancelButton:setX(self.confirmButton.x - 8 - self.cancelButton.width)
    else
        self.cancelButton:setX(w - PAD - self.cancelButton.width)
    end
    self.cancelButton:setY(self.buttonY)
end

function MarketDialog:prerender()
    local w, h = self.width, self.height
    local mode = self.mode
    local panel = self.panel
    local info = panel.marketInfo
    local busy = panel.marketPending ~= nil
    fill(self, 0, 0, w, h, "surface")
    border(self, 0, 0, w, h, "accent")
    local title = getText(T .. "Market_ListTitle")
    if mode == "buy" then title = getText(T .. "Market_BuyTitle", self.row.name)
    elseif mode == "cancel" then title = getText(T .. "Market_Cancel") end
    local titleW = w - PAD * 2
    if mode == "pick" then
        -- title, counter and filter chip share the head line: the counter takes its width first
        self.countText = getText(T .. "Market_PickCount", tostring(self.candListable or 0),
            tostring(self.candTotal or 0))
        titleW = self.countR - PAD - textWidth(self.countText) - PAD
    end
    text(self, fitText(title, titleW, UIFont.Medium), PAD, self.titleY, "text", UIFont.Medium)
    if mode == "buy" then
        local row = self.row
        drawIcon(self, row.texture, PAD, self.itemY, ITEM_ICON)
        local tx = PAD + ITEM_ICON + PAD
        text(self, fitText(row.name, w - tx - PAD), tx, self.itemY, "text")
        if row.statusText then
            text(self, fitText(row.statusText, w - tx - PAD), tx, self.itemY + fontH.small + 4, "textFaint")
        end
        text(self, fitText(getText(T .. "Market_BuyFrom", row.seller), w - PAD * 2), PAD, self.fromY, "textMuted")
        local priceText = amountText(row.price)
        text(self, getText(T .. "Market_YouPay"), PAD, self.payY, "textMuted")
        textRight(self, priceText, w - PAD, self.payY, "accent")
        drawCoin(self, row.currency, w - PAD - textWidth(priceText) - COIN_SMALL - 4,
            self.payY + math.floor((fontH.small - COIN_SMALL) / 2), COIN_SMALL)
        local after = self:available() - row.price
        text(self, getText(T .. "Shop_AfterBalance"), PAD, self.afterY, "textMuted")
        textRight(self, amountText(after), w - PAD, self.afterY, after < 0 and "warn" or "text")
        self.confirmButton:setEnable(after >= 0 and not busy and panel:tradeAllowed())
    elseif mode == "cancel" then
        text(self, fitText(getText(T .. "Market_CancelConfirm", self.row.name), w - PAD * 2), PAD, self.bodyY, "text")
        self.confirmButton:setEnable(not busy and panel:tradeAllowed())
    elseif mode == "price" then
        local cand = self.cand
        drawIcon(self, cand.texture, PAD, self.itemY, ITEM_ICON)
        local tx = PAD + ITEM_ICON + PAD
        text(self, fitText(cand.name, w - tx - PAD), tx, self.itemY + math.floor((ITEM_ICON - fontH.small) / 2), "text")
        text(self, getText(T .. "Market_Price"), PAD,
            self.priceY + math.floor((self.priceEntry.height - fontH.small) / 2), "textMuted")
        text(self, getText(T .. "Market_PriceHint", amountText(info.priceMin), amountText(info.priceMax)),
            PAD, self.hintY, "textFaint")
        local price = self:priceValue() or 0
        text(self, getText(T .. "Market_Fee"), PAD, self.feeY, "textMuted")
        textRight(self, amountText(listingFee(price, info.feePercent)), w - PAD, self.feeY, "warn")
        text(self, getText(T .. "Market_YouGet"), PAD, self.youGetY, "textMuted")
        textRight(self, amountText(price - ceilPercent(price, info.taxPercent)), w - PAD, self.youGetY, "positive")
        self.confirmButton:setEnable(price > 0 and not busy and panel:tradeAllowed())
    else
        -- one pass over the grid: the tile under the cursor decides the status line, and the
        -- strips read the same two numbers back when they paint their hover highlight
        local list = self.pickList
        local hover = nil
        list.hoverIndex, list.hoverCol = nil, nil
        if list:isMouseOver() then
            local e, index, col = self:tileAt(list:getMouseX(), list:getMouseY())
            if e then
                hover, list.hoverIndex, list.hoverCol = e, index, col
            end
        end
        textRight(self, self.countText, self.countR,
            self.titleY + math.floor((fontH.medium - fontH.small) / 2), "textMuted")
        -- the hovered tile, else the refusal of the last unlistable tile the player clicked,
        -- else the invitation to pick one
        local status, token = getText(T .. "Market_PickSelect"), "textMuted"
        if hover then
            status = hover.detailText
            if not hover.ok then token = "warn" end
        elseif self.pickNote then
            status, token = self.pickNote, "warn"
        end
        text(self, fitText(status, w - PAD * 2), PAD, self.statusY, token)
        if (self.candTotal or 0) == 0 then
            text(self, getText(T .. "Market_PickEmpty"), PAD * 2, list.y + 6, "textMuted")
        elseif (self.candShown or 0) == 0 then
            text(self, getText(T .. "Market_NoMatch"), PAD * 2, list.y + 6, "textMuted")
        end
    end
    if self.message then text(self, fitText(self.message, w - PAD * 2), PAD, self.messageY, "errorText") end
end

function MarketDialog:render() end

function MarketDialog:onMouseDown() return true end
function MarketDialog:onMouseUp() return true end
function MarketDialog:onMouseMove() return true end

-- ---------- window ----------

local Panel = ISCollapsableWindow:derive("MinidoracatEconomyPanel")

-- Default size follows the screen (about 3/4 of it, never below the minimum, never off-screen);
-- a size the player dragged to is kept by ISLayoutManager and only clamped back into the screen.
local function defaultSize()
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    local w = math.min(sw - 40, math.max(MIN_WIDTH, math.floor(sw * 0.74)))
    local h = math.min(sh - 40, math.max(MIN_HEIGHT, math.floor(sh * 0.78)))
    return math.max(320, w), math.max(240, h)
end

-- Taller than vanilla (max(16, small font + 1)) so the Medium title fits; the vanilla
-- close/pin/collapse buttons and the drag region size themselves from this value.
function Panel:titleBarHeight()
    return 28
end

-- Title-bar chip, shown only while the size differs from the default: back to the default size,
-- centred. One setWidth/setHeight per axis (see RestoreLayout); ISLayoutManager saves the result.
function Panel:onResetSize()
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    local w, h = defaultSize()
    self:setWidth(w)
    self:setHeight(h)
    self:setX(math.floor((sw - w) / 2))
    self:setY(math.floor((sh - h) / 2))
    self:layout()
end

function Panel:createChildren()
    ISCollapsableWindow.createChildren(self)
    self.tabButtons = {}
    for _, tab in ipairs({ "Wallet", "Rewards", "Shop", "Market", "Mail", "Admin" }) do
        local b = Button.create(0, 0, TAB_W, TAB_H, getText(T .. "Tab_" .. tab), self, Panel.onTab, "tab")
        b.internal = tab
        self:addChild(b)
        self.tabButtons[#self.tabButtons + 1] = b
        if tab == "Mail" then self.mailTabButton = b end
    end

    self.periodButtons = {}
    for _, f in ipairs({ "Recent", "ThisMonth", "LastMonth" }) do
        local title = getText(T .. "Wallet_" .. f)
        local b = Button.create(0, 0, textWidth(title) + 22, CHIP_H, title, self, Panel.onPeriod, "chip")
        b.internal = f
        self:addChild(b)
        self.periodButtons[#self.periodButtons + 1] = b
    end

    self.list = U.newTable(Cell, ROW)
    self:addChild(self.list)

    -- shop page: the category chips are rebuilt per snapshot (Panel:rebuildCategories), the
    -- search box filters the table by item name or sku id
    self.catButtons = {}
    self.shopEntry = newEntry(200, math.max(26, fontH.small + 12), getText(T .. "Shop_Search"))
    self.shopEntry.target = self
    self.shopEntry.onTextChangeFunction = Panel.onShopSearch
    self:addChild(self.shopEntry)
    self.shopList = U.newTable(ShopCell, itemRowHeight())
    self.shopList.onSelect = function(_, item) self:onShopRow(item) end
    self:addChild(self.shopList)

    -- mailbox page
    self.mailList = U.newTable(MailCell, itemRowHeight())
    self.mailList.onSelect = function(_, item) self:onMailRow(item) end
    self:addChild(self.mailList)

    -- market page: mode/refresh bar over either the browse cards (category + search + sort on
    -- the left, the listing table on the right) or the single "my listings" card
    self.marketModeButtons = {}
    for _, mode in ipairs({ "browse", "mine" }) do
        local title = getText(T .. "Market_" .. (mode == "browse" and "Browse" or "Mine"))
        local b = Button.create(0, 0, textWidth(title) + 22, CHIP_H, title, self, Panel.onMarketMode, "chip")
        b.internal = mode
        b.active = mode == self.marketMode
        self:addChild(b)
        self.marketModeButtons[#self.marketModeButtons + 1] = b
        if mode == "mine" then self.marketMineButton = b end
    end
    self.marketSortButtons = {}
    for _, sort in ipairs({ "time", "price", "price_desc" }) do
        local title = getText(T .. "Market_Sort_" .. sort)
        local b = Button.create(0, 0, textWidth(title) + 22, CHIP_H, title, self, Panel.onMarketSort, "chip")
        b.internal = sort
        b.active = sort == self.marketSort
        self:addChild(b)
        self.marketSortButtons[#self.marketSortButtons + 1] = b
    end
    self.marketCatButtons = {}
    self.marketEntry = newEntry(200, math.max(26, fontH.small + 12), getText(T .. "Market_Search"))
    self.marketEntry.target = self
    self.marketEntry.onTextChangeFunction = Panel.onMarketSearch
    self:addChild(self.marketEntry)
    self.marketList = U.newTable(ListingCell, itemRowHeight())
    self.marketList.onSelect = function(_, item) self:onMarketRow(item) end
    self:addChild(self.marketList)
    for _, spec in ipairs({ { "Refresh", Panel.onMarketRefresh }, { "List", Panel.onMarketList },
        { "Prev", Panel.onMarketPage }, { "Next", Panel.onMarketPage } }) do
        local title = getText(T .. "Market_" .. spec[1])
        local b = Button.create(0, 0, textWidth(title) + 22, CHIP_H, title, self, spec[2], "chip")
        self:addChild(b)
        self["market" .. spec[1] .. "Button"] = b
    end
    self.marketPrevButton.internal = -1
    self.marketNextButton.internal = 1
    self:updateMarketInfo()

    self.claimButton = Button.create(0, 0, 200, 40, "", self, Panel.onClaim, "primary")
    self.claimButton.font = UIFont.Medium
    self:addChild(self.claimButton)

    local more = getText(T .. "Wallet_MoreHistory")
    self.moreButton = Button.create(0, 0, textWidth(more) + 24, CHIP_H, more, self, Panel.onMore, "chip")
    self:addChild(self.moreButton)

    local reset = getText(T .. "Window_ResetSize")
    self.resetSizeButton = Button.create(0, 0, textWidth(reset) + 20, self:titleBarHeight() - 8, reset, self, Panel.onResetSize, "chip")
    self:addChild(self.resetSizeButton)

    self:setTab("Wallet")
end

-- ----- actions -----

function Panel:onTab(button) self:setTab(button.internal) end

function Panel:setTab(tab)
    if tab == "Admin" and not C.AdminPanel.canRead() then tab = "Wallet" end
    if tab ~= self.tab then
        self:closeBuy()
        self:closeMarketDialog()
        pcall(function() self.shopEntry:unfocus() end)   -- a hidden text box must not keep the keyboard
        pcall(function() self.marketEntry:unfocus() end)
    end
    self.tab = tab
    for _, b in ipairs(self.tabButtons) do b.active = b.internal == tab end
    self:layout()
    if self.shown then self:refresh() end
end

-- Server round trips for the visible tab (commands are throttled 500 ms per player per command,
-- ECServer.lua; each request here is a distinct command).
function Panel:refresh()
    if self.tab == "Wallet" then
        C.requestWallet()
        if not self.history then self:loadHistory() end
    elseif self.tab == "Rewards" then
        self.rewardsPolledMs = EC.now()
        C.requestRewards()
        if not C.wallet then C.requestWallet() end
    elseif self.tab == "Shop" then
        -- the catalog only changes when an admin edits it (and every purchase reply is followed
        -- by a fresh list from ECClient), so a recent snapshot is reused as it is
        if not C.shop or EC.now() - (self.shopAt or 0) > SHOP_POLL_MS then
            self.shopAt = EC.now()
            C.requestShop()
        end
        if not C.wallet then C.requestWallet() end
    elseif self.tab == "Market" then
        -- the browse page is a live market: a snapshot older than the shop's window is refetched,
        -- and the own-listings page is always asked for (it is short and it is the write side)
        if self.marketMode == "mine" then
            C.requestMyListings()
        elseif not C.market or EC.now() - (self.marketAt or 0) > SHOP_POLL_MS then
            self:requestBrowse(1)
        end
        if not C.wallet then C.requestWallet() end
    elseif self.tab == "Mail" then
        C.requestMail()
    elseif self.tab == "Admin" then
        if self.adminPanel and C.AdminPanel.canRead() then self.adminPanel:refresh() end
    end
end

function Panel:onPeriod(button)
    self.period = button.internal
    for _, b in ipairs(self.periodButtons) do b.active = b.internal == self.period end
    self.history = nil
    self.historyError = nil
    self:loadHistory()
    self:rebuildList()
end

function Panel:onMore()
    self:setTab("Wallet")
end

function Panel:onClaim()
    self.claimButton:setEnable(false)
    self.claimPending = true
    self.message = nil
    C.checkin()
end

function Panel:periodMonth()
    local ms = EC.now()
    if self.period == "Recent" then return "recent" end   -- server: previous + current month files
    if self.period == "LastMonth" then
        -- first day of this month minus one day, in UTC (receipt files are keyed by UTC month)
        local firstOfMonth = ms - ((tonumber(EC.dayKey(ms)) % 100) - 1) * 86400000
        return EC.monthKey(firstOfMonth - 86400000)
    end
    return EC.monthKey(ms)
end

function Panel:loadHistory()
    self.historyLoading = true
    self.historyError = nil
    C.requestHistory(self:periodMonth())
end

-- ----- data -----

local function normalize(e, offsetMin)
    local amount = tonumber(e.amount or e.delta) or 0
    local cp = e.counterparty
    local desc = "-"
    if cp and not (string.find(tostring(cp), "^SYSTEM_") or string.find(tostring(cp), "^EXTERNAL_") or string.find(tostring(cp), "^MOD:")) then
        desc = tostring(cp)
    elseif e.sourceMod then
        -- integration postings (spec 21.3): the mod id plus its own wording when it gave one
        desc = tostring(e.sourceMod)
        if type(e.reasonText) == "string" and e.reasonText ~= "" then desc = desc .. " - " .. e.reasonText end
    elseif type(e.item) == "string" then
        -- shop purchases carry the item and count (ring and receipt files alike)
        desc = itemName(e.item) .. " x" .. tostring(math.floor(tonumber(e.qty) or 1))
    end
    local kind = e.kind or e.type
    return {
        ts = e.ts, txId = e.txId, kind = kind, currency = e.currency, amount = amount,
        after = e.after or e.availableAfter, rolledBack = e.rolledBack == true,
        time = stampText(e.ts, offsetMin), kindText = kindText(kind), desc = desc,
        amountText = signedText(amount) .. " " .. C.currencyName(e.currency),
    }
end

local function newestFirst(src, offsetMin)
    local out = {}
    for i = #src, 1, -1 do out[#out + 1] = normalize(src[i], offsetMin) end
    return out
end

-- self.rows = statement rows for the selected period; self.recentRows = the server receipt ring
-- (rewards page "recent ledger"). Both are rebuilt only when data arrives, never per frame.
-- "Recent" is the newest RECENT_ROWS lines of the receipt files (they keep what a crash rolled
-- back); the ModData ring only paints the first frame until the file reply lands.
local RECENT_ROWS = 20
function Panel:rebuildList()
    self.recentRows = newestFirst(C.wallet and C.wallet.receipts or {}, self.offsetMin)
    if self.period == "Recent" then
        if self.history then
            local all = newestFirst(self.history.entries or {}, self.offsetMin)
            local rows = {}
            for i = 1, math.min(#all, RECENT_ROWS) do rows[i] = all[i] end
            self.rows = rows
        else
            self.rows = self.recentRows
        end
    else
        self.rows = newestFirst(self.history and self.history.entries or {}, self.offsetMin)
    end
    self.list:setItems(self.rows)
end

-- Month in/out per currency from this month's receipt file (design: balance card "this month").
function Panel:updateMonthTotals(history)
    local month = EC.monthKey(EC.now())
    if history.month ~= month and history.month ~= "recent" then return end
    local totals = {}
    for _, e in ipairs(history.entries or {}) do
        -- the recent window spans two months: only this month's lines count
        if e.rolledBack ~= true and EC.monthKey(tonumber(e.ts) or 0) == month then
            local t = totals[e.currency]
            if not t then t = { inn = 0, out = 0 }; totals[e.currency] = t end
            local d = tonumber(e.delta) or 0
            if d >= 0 then t.inn = t.inn + d else t.out = t.out - d end
        end
    end
    self.monthTotals = totals
end

function Panel:onWallet(kind, args)
    if kind == "state" then
        self:rebuildList()
    elseif kind == "changed" then
        self:loadHistory()
    elseif kind == "history" then
        if args.month ~= self:periodMonth() then return end
        self.historyLoading = false
        if args.error then
            self.historyError = args.error
        else
            self.history = args
            self:updateMonthTotals(args)
        end
        self:rebuildList()
    end
end

function Panel:onRewards(kind, args)
    self.claimPending = false
    if kind == "checkin" then
        if args.ok then
            self.message = { text = getText(T .. "Rewards_Granted", tostring(args.amount), C.currencyName(args.currency)) }
        else
            local key = T .. "Rewards_Error_" .. tostring(args.error)
            self.message = { text = getTextOrNull(key) or getText(T .. "Rewards_Error_generic", tostring(args.error)), error = true }
        end
        C.requestRewards()
    end
end

-- ----- shop / mailbox -----

-- The mailbox tab carries the pending count: a purchase that did not fit in the backpack is
-- otherwise invisible until the player opens the page. Every reply that knows the number
-- (shop.list, shop.buy, mail.list, mail.claim) passes it here.
function Panel:updateMailTab(unclaimed)
    local n = tonumber(unclaimed)
    if n then self.unclaimedCount = n end
    local b = self.mailTabButton
    if not b then return end
    local title = getText(T .. "Tab_Mail")
    if (self.unclaimedCount or 0) > 0 then title = title .. " (" .. tostring(self.unclaimedCount) .. ")" end
    if b.title ~= title then b:setTitle(title) end
end

-- Category chips are the categories the snapshot actually uses (plus "all"), so a server that
-- ships two categories does not show five empty filters. The buttons are rebuilt only when that
-- set changes (a snapshot lands every 30 s at most, a catalog edit is rarer still).
function Panel:rebuildCategories()
    local seen, cats, sig = {}, { "" }, ""
    for _, it in ipairs(C.shop and C.shop.items or {}) do
        local cat = it.category
        if it.enabled ~= false and type(cat) == "string" and cat ~= "" and not seen[cat] then
            seen[cat] = true
            cats[#cats + 1] = cat
            sig = sig .. cat .. ","
        end
    end
    if self.shopCat and not seen[self.shopCat] then self.shopCat = nil end
    if sig == self.catSig then return end
    self.catSig = sig
    for _, b in ipairs(self.catButtons or {}) do
        b:setVisible(false)
        self:removeChild(b)
    end
    self.catButtons = {}
    for _, cat in ipairs(cats) do
        local title = cat == "" and getText(T .. "Shop_All") or (getTextOrNull(T .. "Shop_Cat_" .. cat) or cat)
        local b = Button.create(0, 0, math.min(LEFT_W - PAD * 2, textWidth(title) + 22), CHIP_H, title, self, Panel.onShopCat, "chip")
        b.internal = cat
        b.active = (self.shopCat or "") == cat
        self:addChild(b)
        self.catButtons[#self.catButtons + 1] = b
    end
end

-- Rows for the selected category and search text. A disabled sku is not a row at all: a player
-- must not see what an admin took off the shelf.
function Panel:rebuildShop()
    local shop = C.shop
    local query = self.shopQuery
    local rows = {}
    for _, it in ipairs(shop and shop.items or {}) do
        if it.enabled ~= false and (self.shopCat == nil or it.category == self.shopCat) then
            local row = shopRow(it, shop.currency)
            if query == nil or string.find(string.lower(row.name), query, 1, true)
                or (row.altName and string.find(string.lower(row.altName), query, 1, true))
                or string.find(string.lower(tostring(row.id)), query, 1, true)
                or string.find(string.lower(tostring(row.item)), query, 1, true) then
                rows[#rows + 1] = row
            end
        end
    end
    self.shopRows = rows
    self.shopList:setItems(rows)
end

function Panel:rebuildMail()
    local rows = {}
    for _, e in ipairs(C.mail and C.mail.entries or {}) do
        local qty = tonumber(e.qty) or 1
        local name = itemName(e.item)
        rows[#rows + 1] = {
            id = e.id, item = e.item, qty = qty, name = name, altName = itemBaseName(e.item), texture = itemTexture(e.item),
            nameText = name .. " x" .. tostring(qty),
            fromText = getTextOrNull(T .. "Mail_From_" .. tostring(e.kind)) or tostring(e.kind),
            timeText = stampText(tonumber(e.at) or 0, self.offsetMin),
            claimLabel = getText(T .. "Mail_Claim"),
        }
    end
    self.mailRows = rows
    self.mailList:setItems(rows)
end

function Panel:onShopCat(button)
    self.shopCat = button.internal ~= "" and button.internal or nil
    for _, b in ipairs(self.catButtons) do b.active = (self.shopCat or "") == b.internal end
    self:rebuildShop()
end

function Panel:onShopSearch()
    local query = string.lower(string.match(entryText(self.shopEntry), "^%s*(.-)%s*$"))
    self.shopQuery = query ~= "" and query or nil
    self:rebuildShop()
end

-- The gate the server re-checks on every write (ECTerminal.near plus the freeze flag). The
-- terminal list is short (a server registers a handful), so the distance test per frame is
-- cheap — and with nothing registered there is nothing to measure against at all.
function Panel:tradeAllowed()
    if C.wallet and C.wallet.frozen then return false end
    if self:remoteReadOnly() and #(C.terminals or {}) == 0 then return false end
    return C.nearTerminal()
end

function Panel:canBuy(row)
    if self.buyDialog or self.buyPending then return false end
    if row and row.soldOut then return false end
    return self:tradeAllowed()
end

function Panel:onShopRow(row)
    if row and self:canBuy(row) then self:openBuy(row) end
end

function Panel:openBuy(row)
    self:closeBuy()
    local dlg = ISPanel:new(0, 0, 360, 200)
    setmetatable(dlg, BuyDialog)
    dlg.background = false
    dlg.panel = self
    dlg.row = row
    dlg.count = 1
    dlg.message = nil
    dlg:initialise()
    self:addChild(dlg)      -- the buttons exist from here on (instantiate -> createChildren)
    self.buyDialog = dlg
    self:layoutBuy()
end

function Panel:layoutBuy()
    local dlg = self.buyDialog
    if not dlg then return end
    dlg:layoutInside(math.max(320, self.width - PAD * 4))
    dlg:setX(math.max(0, math.floor((self.width - dlg.width) / 2)))
    dlg:setY(math.max(self.g and self.g.contentY or PAD, math.floor((self.height - dlg.height) / 2)))
end

function Panel:closeBuy()
    local dlg = self.buyDialog
    if not dlg then return end
    self.buyDialog = nil
    dlg:setVisible(false)
    self:removeChild(dlg)
end

-- An error belongs in the dialog that caused it; without one (a timeout after the player closed
-- it) the toast is the only place left.
function Panel:buyMessage(str)
    if self.buyDialog then
        self.buyDialog.message = str
    else
        C.toast(str)
    end
end

function Panel:submitBuy(dlg)
    local shop = C.shop
    if not shop or self.buyPending then return end
    if not self:tradeAllowed() then
        self:buyMessage(shopError("not_at_terminal"))
        return
    end
    dlg.message = nil
    self.buyPending = { requestId = C.newRequestId(), at = EC.now(), name = dlg.row.name }
    C.buy(dlg.row.id, dlg.count, shop.revision, self.buyPending.requestId)
end

function Panel:onMailRow(row)
    if not row or self.mailPending or not self:tradeAllowed() then return end
    self.mailPending = { requestId = C.newRequestId(), at = EC.now(), name = row.name }
    C.claimMail(row.id, self.mailPending.requestId)
end

function Panel:onShop(kind, args)
    self:updateMailTab(args.unclaimed)
    if kind == "list" then
        self:rebuildCategories()
        self:rebuildShop()
        self:layout()   -- the chip row (and with it the search box below it) may have moved
        -- keep an open dialog on the fresh price/remaining, or drop it if the sku is gone
        local dlg = self.buyDialog
        if dlg then
            local fresh = nil
            for _, it in ipairs(args.items or {}) do
                if it.id == dlg.row.id and it.enabled ~= false then fresh = shopRow(it, args.currency) end
            end
            if fresh then
                dlg.row = fresh
                self:layoutBuy()
            else
                self:closeBuy()
                C.toast(shopError("unknown_sku"))
            end
        end
        return
    end
    -- shop.buy: only the reply this page is waiting for (the server echoes the requestId)
    local pending = self.buyPending
    if pending and args.requestId ~= nil and args.requestId ~= pending.requestId then return end
    self.buyPending = nil
    if args.ok then
        local name = (args.item and itemName(args.item)) or (pending and pending.name) or ""
        self:closeBuy()
        C.toast(getText(T .. "Shop_Bought", name, tostring(tonumber(args.qty) or 0)))
        if args.delivered == false then C.toast(getText(T .. "Shop_Parked")) end
        return
    end
    if args.error == "catalog_changed" then C.requestShop() end
    self:buyMessage(shopError(args.error))
end

function Panel:onMail(kind, args)
    self:updateMailTab(args.unclaimed)
    self:rebuildMail()
    if kind == "list" then return end
    local pending = self.mailPending
    if pending and args.requestId ~= nil and args.requestId ~= pending.requestId then return end
    self.mailPending = nil
    if args.ok then
        local name = (args.item and itemName(args.item)) or (pending and pending.name) or ""
        C.toast(getText(T .. "Mail_Claimed", name, tostring(tonumber(args.qty) or 0)))
    else
        C.toast(shopError(args.error))
    end
end

-- ----- market -----

-- The player's own account name: an own listing must not be sold back to them, and the server
-- says so too (own_listing) — this only keeps the chip from lying.
function Panel:username()
    if self.playerName == nil then
        local ok, value = pcall(function() return getPlayer():getUsername() end)
        self.playerName = (ok and type(value) == "string" and value ~= "") and value or false
    end
    return self.playerName or nil
end

-- The market numbers live in three snapshots (browse, own listings, backpack candidates) and
-- every page needs a bit of each. One table, refilled in place: prerender reads it every frame.
function Panel:updateMarketInfo()
    local m, cand, mine = C.market, C.candidates, C.myListings
    local info = self.marketInfo or {}
    info.feePercent = tonumber(cand and cand.feePercent) or tonumber(m and m.feePercent) or 0
    info.taxPercent = tonumber(cand and cand.taxPercent) or tonumber(m and m.taxPercent) or 0
    info.priceMin = tonumber(cand and cand.priceMin) or tonumber(m and m.priceMin) or 1
    info.priceMax = tonumber(cand and cand.priceMax) or tonumber(m and m.priceMax) or 0
    info.pages = math.max(1, tonumber(m and m.pages) or 1)
    info.total = tonumber(m and m.total) or 0
    info.mine = (mine and mine.items and #mine.items)
        or tonumber(m and m.mine) or tonumber(cand and cand.mine) or 0
    info.maxListings = tonumber(mine and mine.maxListings) or tonumber(m and m.maxListings)
        or tonumber(cand and cand.maxListings) or 0
    self.marketInfo = info
    local b = self.marketMineButton
    if b then
        local title = getText(T .. "Market_MineCount", tostring(info.mine), tostring(info.maxListings))
        if b.title ~= title then
            b:setTitle(title)
            b:setWidth(textWidth(title) + 22)
        end
    end
end

function Panel:requestBrowse(page)
    self.marketPage = math.max(1, tonumber(page) or 1)
    self.marketAt = EC.now()
    self.marketQueryAt = nil
    C.requestMarket({ category = self.marketCat, query = self.marketQuery,
        sort = self.marketSort, page = self.marketPage })
end

-- The category chips are the categories the current page actually carries (plus "all"), the
-- same rule the shop follows; the server names them, the client only translates.
function Panel:rebuildMarketCategories()
    local seen, cats, sig = {}, { "" }, ""
    for _, cat in ipairs(C.market and C.market.categories or {}) do
        if type(cat) == "string" and cat ~= "" and not seen[cat] then
            seen[cat] = true
            cats[#cats + 1] = cat
            sig = sig .. cat .. ","
        end
    end
    if self.marketCat and not seen[self.marketCat] then self.marketCat = nil end
    if sig == self.marketCatSig then return end
    self.marketCatSig = sig
    for _, b in ipairs(self.marketCatButtons or {}) do
        b:setVisible(false)
        self:removeChild(b)
    end
    self.marketCatButtons = {}
    for _, cat in ipairs(cats) do
        local title = cat == "" and getText(T .. "Shop_All") or (getTextOrNull(T .. "Shop_Cat_" .. cat) or cat)
        local b = Button.create(0, 0, math.min(LEFT_W - PAD * 2, textWidth(title) + 22), CHIP_H, title, self, Panel.onMarketCat, "chip")
        b.internal = cat
        b.active = (self.marketCat or "") == cat
        self:addChild(b)
        self.marketCatButtons[#self.marketCatButtons + 1] = b
    end
end

-- The server paged and sorted this list already; the only thing it could not match is the
-- translated name (it never sees the player's language), so the search text runs over the page
-- once more here — that is also why an empty result says "no match" and not "empty market".
function Panel:rebuildMarket()
    local mine = self.marketMode == "mine"
    local snap = mine and C.myListings or C.market
    local src = (snap and snap.items) or {}
    local currency = (C.market and C.market.currency) or EC.CURRENCY_ORDER[1]
    local query = (not mine) and self.marketQuery or nil
    local username = self:username()
    local rows = {}
    for _, it in ipairs(src) do
        local row = listingRow(it, currency, username, self.offsetMin, mine)
        if query == nil or string.find(string.lower(row.name), query, 1, true)
            or (row.altName and string.find(string.lower(row.altName), query, 1, true))
            or string.find(string.lower(tostring(row.item)), query, 1, true)
            or string.find(string.lower(row.seller), query, 1, true) then
            rows[#rows + 1] = row
        end
    end
    self.marketNoMatch = #rows == 0 and #src > 0
    self.marketRows = rows
    self.marketList:setItems(rows)
end

function Panel:rebuildCandidates()
    local rows = {}
    for _, it in ipairs(C.candidates and C.candidates.items or {}) do
        rows[#rows + 1] = candidateRow(it)
    end
    self.candidateRows = rows
    local dlg = self.marketDialog
    if dlg and dlg.mode == "pick" then
        dlg.pickNote = nil     -- a fresh backpack: the refusal on the status line may be stale
        dlg:rebuildGrid()
    end
end

function Panel:onMarketMode(button)
    if self.marketMode == button.internal then return end
    self.marketMode = button.internal
    for _, b in ipairs(self.marketModeButtons) do b.active = b.internal == self.marketMode end
    self:closeMarketDialog()
    self:rebuildMarket()
    self:layout()
    if self.marketMode == "mine" then C.requestMyListings() else self:requestBrowse(self.marketPage) end
end

function Panel:onMarketSort(button)
    if self.marketSort == button.internal then return end
    self.marketSort = button.internal
    for _, b in ipairs(self.marketSortButtons) do b.active = b.internal == self.marketSort end
    self:requestBrowse(1)
end

function Panel:onMarketCat(button)
    self.marketCat = button.internal ~= "" and button.internal or nil
    for _, b in ipairs(self.marketCatButtons) do b.active = (self.marketCat or "") == b.internal end
    self:requestBrowse(1)
end

-- Typing filters the page at once; the server hears about it when the typing stops (a command
-- per keystroke would be dropped by the 500 ms throttle anyway).
function Panel:onMarketSearch()
    local query = string.lower(string.match(entryText(self.marketEntry), "^%s*(.-)%s*$"))
    self.marketQuery = query ~= "" and query or nil
    self.marketQueryAt = EC.now() + 500
    self:rebuildMarket()
end

function Panel:onMarketRefresh()
    if self.marketMode == "mine" then C.requestMyListings() else self:requestBrowse(self.marketPage) end
end

function Panel:onMarketPage(button)
    local page = self.marketPage + button.internal
    if page < 1 or page > self.marketInfo.pages then return end
    self:requestBrowse(page)
end

function Panel:onMarketRow(row)
    if not row or self.marketDialog or self.marketPending or not self:tradeAllowed() then return end
    if row.mine then
        self:openMarketDialog("cancel", row)
    elseif not row.own then
        self:openMarketDialog("buy", row)
    end
end

function Panel:onMarketList()
    if self.marketDialog or self.marketPending or not self:tradeAllowed() then return end
    local info = self.marketInfo
    if info.maxListings > 0 and info.mine >= info.maxListings then return end
    self:openMarketDialog("pick")
end

function Panel:onCandidate(cand)
    local dlg = self.marketDialog
    if not dlg or dlg.mode ~= "pick" or not cand then return end
    if not cand.ok then
        dlg.pickNote = cand.detailText   -- the refusal belongs on the status line, not in a step
        return
    end
    dlg.mode = "price"
    dlg.cand = cand
    dlg.message = nil
    dlg.pickNote = nil
    setEntryText(dlg.priceEntry, "")
    self:layoutMarketDialog()
end

function Panel:openMarketDialog(mode, row)
    self:closeMarketDialog()
    local dlg = ISPanel:new(0, 0, 360, 200)
    setmetatable(dlg, MarketDialog)
    dlg.background = false
    dlg.panel = self
    dlg.mode = mode
    dlg.row = row
    dlg.message = nil
    dlg:initialise()
    self:addChild(dlg)      -- the buttons exist from here on (instantiate -> createChildren)
    self.marketDialog = dlg
    if mode == "pick" then
        dlg:rebuildGrid()
        C.requestCandidates()
    end
    self:layoutMarketDialog()
    return dlg
end

function Panel:layoutMarketDialog()
    local dlg = self.marketDialog
    if not dlg then return end
    local g = self.g
    dlg:layoutInside(math.max(320, self.width - PAD * 4), math.max(200, (g and g.contentH or self.height) - PAD * 2))
    dlg:setX(math.max(0, math.floor((self.width - dlg.width) / 2)))
    dlg:setY(math.max(g and g.contentY or PAD, math.floor((self.height - dlg.height) / 2)))
end

function Panel:closeMarketDialog()
    local dlg = self.marketDialog
    if not dlg then return end
    self.marketDialog = nil
    pcall(function() dlg.priceEntry:unfocus() end)
    dlg:setVisible(false)
    self:removeChild(dlg)
end

function Panel:marketMessage(str)
    if self.marketDialog then
        self.marketDialog.message = str
    else
        C.toast(str)
    end
end

-- One write in flight for the whole page (buy, list, cancel): the server answers with the
-- requestId, and prerender gives up on it after TIMEOUT_MS.
function Panel:submitMarket(dlg)
    if self.marketPending then return end
    if not self:tradeAllowed() then
        dlg.message = marketError({ error = "not_at_terminal" })
        return
    end
    local mode, price, itemId, listingId, name = dlg.mode, nil, nil, nil, nil
    if mode == "price" then
        local info = self.marketInfo
        price = dlg:priceValue()
        if price == nil or price < info.priceMin or (info.priceMax > 0 and price > info.priceMax) then
            dlg.message = getText(T .. "Market_Error_price_range", amountText(info.priceMin), amountText(info.priceMax))
            return
        end
        itemId, name = dlg.cand.itemId, dlg.cand.name
    else
        listingId, price, name = dlg.row.id, dlg.row.price, dlg.row.name
    end
    dlg.message = nil
    self.marketPending = { requestId = C.newRequestId(), at = EC.now(), kind = mode, name = name }
    if mode == "buy" then
        C.buyListing(listingId, price, self.marketPending.requestId)
    elseif mode == "cancel" then
        C.cancelListing(listingId, self.marketPending.requestId)
    else
        C.listItem(itemId, price, self.marketPending.requestId)
    end
end

function Panel:onMarket(kind, args)
    if kind == "browse" or kind == "mine" or kind == "candidates" then
        if kind == "browse" then
            self.marketAt = EC.now()
            self.marketPage = math.max(1, tonumber(args.page) or self.marketPage)
            self:rebuildMarketCategories()
        end
        self:updateMarketInfo()
        if kind == "candidates" then self:rebuildCandidates() else self:rebuildMarket() end
        self:layout()   -- the chip rows (and the mine counter's own width) may have moved
        return
    end
    -- a write answer: only the one this page is waiting for
    self:updateMailTab(args.unclaimed)
    local pending = self.marketPending
    if pending and args.requestId ~= nil and args.requestId ~= pending.requestId then return end
    self.marketPending = nil
    self:updateMarketInfo()
    self:rebuildMarket()      -- market.list / market.cancel bring the fresh own listings with them
    if args.ok then
        local name = (pending and pending.name) or (args.item and itemName(args.item)) or ""
        self:closeMarketDialog()
        if kind == "buy" then
            C.toast(getText(T .. "Market_Bought", name, amountText(args.price)))
        elseif kind == "list" then
            C.toast(getText(T .. "Market_Listed", name, amountText(args.fee)))
        else
            C.toast(getText(T .. "Market_Cancelled"))
        end
        if args.delivered == false then C.toast(getText(T .. "Shop_Parked")) end
        if kind == "buy" then self:requestBrowse(self.marketPage)
        elseif kind == "list" then
            C.requestMyListings()
            if self.marketMode ~= "mine" then self:requestBrowse(self.marketPage) end   -- the new row belongs on the browse page too
        end
        self:layout()
        return
    end
    -- the price moved under the player: show why, and put the current page back on screen
    if kind == "buy" and args.error == "price_changed" then self:requestBrowse(self.marketPage) end
    self:marketMessage(marketError(args))
end

-- A terminal was registered or removed: the shop/mail snapshots carry the server's own
-- atTerminal flag, so the visible page asks again instead of trusting a stale gate.
function Panel:onTerminals()
    if not self.shown or self.isCollapsed then return end
    if self.tab == "Shop" then
        self.shopAt = EC.now()
        C.requestShop()
    elseif self.tab == "Mail" then
        C.requestMail()
    elseif self.tab == "Market" then
        self:onMarketRefresh()
    end
end

-- ----- geometry -----

function Panel:remoteReadOnly()
    return C.session ~= nil and C.session.remoteReadOnly == true
end

function Panel:currencies()
    return (C.wallet and C.wallet.currencies) or EC.CURRENCY_ORDER
end

-- All child positions derive from the current width/height; called when the size changes,
-- the tab changes, or the currency list arrives.
function Panel:layout()
    local w, h = self.width, self.height
    local th = self:titleBarHeight()
    local rh = self.resizable and self:resizeWidgetHeight() or 0
    local g = {}
    g.statusY = th
    g.stripY = th + STATUS_H + 2
    g.tabsY = g.stripY + STRIP_H + 4
    g.contentY = g.tabsY + TAB_H + PAD
    local st = C.rewards
    g.footerH = (self.tab == "Rewards" and st and (tonumber(st.serverCap) or 0) > 0) and ROW or 0
    g.contentH = h - g.contentY - rh - PAD - g.footerH
    g.leftX, g.leftW = PAD, LEFT_W
    g.rightX = PAD + LEFT_W + PAD
    g.rightW = w - g.rightX - PAD
    self.g = g

    -- title bar: left of the vanilla pin/collapse button (both are th-2 square at w-1-(th-2))
    local dw, dh = defaultSize()
    local rb = self.resetSizeButton
    rb:setVisible((w ~= dw or h ~= dh) and not self.isCollapsed)
    rb:setX(w - 1 - (th - 2) - 6 - rb.width)
    rb:setY(math.floor((th - rb.height) / 2))

    local isWallet = self.tab == "Wallet"
    self.adminAccess = C.AdminPanel.canRead()
    local x = PAD
    for _, b in ipairs(self.tabButtons) do
        local visible = b.internal ~= "Admin" or self.adminAccess
        b:setVisible(visible)
        if visible then
            b:setX(x)
            b:setY(g.tabsY)
            x = x + b.width
        end
    end
    if self.tab == "Admin" and self.adminAccess and not self.adminPanel then
        self.adminPanel = C.AdminPanel.create(self)
        self:addChild(self.adminPanel)
    end
    if self.adminPanel then
        self.adminPanel:setX(PAD)
        self.adminPanel:setY(g.contentY)
        self.adminPanel:resize(w - PAD * 2, g.contentH)
        self.adminPanel:setVisible(self.tab == "Admin" and self.adminAccess and self.shown == true and not self.isCollapsed)
    end

    -- wallet: period chips + statement table inside the right card
    local chipY = g.contentY + CARD_TITLE_H + 4
    x = g.rightX + PAD + textWidth(getText(T .. "Wallet_Period")) + PAD
    for _, b in ipairs(self.periodButtons) do
        b:setVisible(isWallet)
        b:setX(x); b:setY(chipY)
        x = x + b.width + 6
    end
    g.tableHeaderY = chipY + CHIP_H + 8
    local listY = g.tableHeaderY + ROW
    local listX = g.rightX + 1
    local listW = g.rightW - 2
    local listH = math.max(ROW * 2, g.contentY + g.contentH - listY - ROW - 2)
    self.list:setVisible(isWallet)
    self.list:setX(listX); self.list:setY(listY)
    local listResized = self.list.width ~= listW or self.list.height ~= listH
    -- Columns are measured from the header/typical texts so the player's UI font scale cannot
    -- make them collide; the description column takes whatever is left (truncated at bind time).
    local cols = self.list.cols
    local inner = listW - 12 -- keep clear of the scrollbar
    local function colW(header, sample) return math.max(textWidth(getText(T .. header)), textWidth(sample)) + PAD * 2 end
    cols.time = PAD
    cols.kind = cols.time + colW("Wallet_Col_Time", "00-00 00:00")
    cols.desc = cols.kind + colW("Wallet_Col_Kind", kindText("admin_adjust"))
    cols.status = inner - colW("Wallet_Col_Status", getText(T .. "Wallet_RolledBack")) + PAD
    cols.balanceR = cols.status - PAD
    cols.amountR = cols.balanceR - colW("Wallet_Col_Balance", "999,999,999")
    cols.descW = math.max(0, cols.amountR - colW("Wallet_Col_Amount", "+999,999 " .. C.currencyName(EC.CURRENCY_ORDER[1])) - cols.desc)
    if listResized then self.list:resize(listW, listH) end
    g.listBottom = listY + listH

    -- rewards: claim button inside the daily card, "more history" under the recent ledger
    g.dailyH = CARD_TITLE_H + ROW * 2 + 40 + ROW + PAD * 3
    self.claimButton:setVisible(self.tab == "Rewards")
    self.claimButton:setX(g.rightX + PAD)
    self.claimButton:setY(g.contentY + CARD_TITLE_H + ROW * 2 + PAD)
    self.claimButton:setWidth(g.rightW - PAD * 2)
    self.moreButton:setVisible(self.tab == "Rewards")
    self.moreButton:setX(g.leftX + PAD)
    self.moreButton:setY(g.contentY + g.contentH - CHIP_H - PAD)
    self.moreButton:setWidth(g.leftW - PAD * 2)

    -- shop: the category chips wrap inside the left card with the search box under them, the
    -- item table fills the right card below its note and header line
    local isShop = self.tab == "Shop"
    local chipX, chipRow = g.leftX + PAD, g.contentY + PAD
    local chipRight = g.leftX + g.leftW - PAD
    for _, b in ipairs(self.catButtons or {}) do
        b:setVisible(isShop)
        if chipX > g.leftX + PAD and chipX + b.width > chipRight then
            chipX = g.leftX + PAD
            chipRow = chipRow + CHIP_H + 6
        end
        b:setX(chipX); b:setY(chipRow)
        chipX = chipX + b.width + 6
    end
    g.shopSearchY = chipRow + CHIP_H + PAD + fontH.small + 4
    self.shopEntry:setVisible(isShop)
    self.shopEntry:setX(g.leftX + PAD)
    self.shopEntry:setY(g.shopSearchY)
    self.shopEntry:setWidth(g.leftW - PAD * 2)
    g.shopHeaderY = g.contentY + CARD_TITLE_H + ROW
    local shopListY = g.shopHeaderY + ROW
    local shopListH = math.max(ROW * 2, g.contentY + g.contentH - shopListY - PAD)
    self.shopList:setVisible(isShop)
    self.shopList:setX(listX); self.shopList:setY(shopListY)
    local shopCols = self.shopList.cols
    shopCols.icon = PAD
    shopCols.name = PAD + ITEM_ICON + PAD
    shopCols.buyW = textWidth(getText(T .. "Shop_Buy")) + 22
    shopCols.buyX = math.max(shopCols.name, inner - shopCols.buyW - PAD)
    shopCols.remainR = shopCols.buyX - PAD
    shopCols.priceR = math.max(shopCols.name + PAD, shopCols.remainR
        - math.max(textWidth(getText(T .. "Shop_Col_Remaining")), textWidth(getText(T .. "Shop_SoldOut"))) - PAD)
    shopCols.nameW = math.max(0, shopCols.priceR - COIN_SMALL - 4 - textWidth("999,999") - PAD - shopCols.name)
    if self.shopList.width ~= listW or self.shopList.height ~= shopListH then
        self.shopList:resize(listW, shopListH)
    end

    -- mailbox: one card across the whole content area, no column header (name, source, time)
    local isMail = self.tab == "Mail"
    local mailListY = g.contentY + CARD_TITLE_H + ROW
    local mailListW = w - PAD * 2 - 2
    local mailListH = math.max(ROW * 2, g.contentY + g.contentH - mailListY - PAD)
    self.mailList:setVisible(isMail)
    self.mailList:setX(g.leftX + 1); self.mailList:setY(mailListY)
    local mailCols = self.mailList.cols
    local mailInner = mailListW - 12
    mailCols.icon = PAD
    mailCols.name = PAD + ITEM_ICON + PAD
    mailCols.claimW = textWidth(getText(T .. "Mail_Claim")) + 22
    mailCols.claimX = math.max(mailCols.name, mailInner - mailCols.claimW - PAD)
    mailCols.timeR = mailCols.claimX - PAD
    mailCols.nameW = math.max(0, mailCols.timeR - textWidth("00-00 00:00") - PAD - mailCols.name)
    if self.mailList.width ~= mailListW or self.mailList.height ~= mailListH then
        self.mailList:resize(mailListW, mailListH)
    end

    -- market: a mode/refresh bar over the page. Browsing keeps the shop's two-card split
    -- (filters left, listings right) and adds the pager strip under the table; the own-listings
    -- page has nothing to filter, so it takes one card across the whole width.
    local isMarket = self.tab == "Market"
    local mineMode = self.marketMode == "mine"
    local browseMode = isMarket and not mineMode
    g.marketBarY = g.contentY
    g.marketCardY = g.contentY + CHIP_H + PAD
    g.marketCardH = math.max(CARD_TITLE_H + ROW * 3, g.contentH - CHIP_H - PAD)
    x = PAD
    for _, b in ipairs(self.marketModeButtons) do
        b:setVisible(isMarket)
        b:setX(x); b:setY(g.marketBarY)
        x = x + b.width + 6
    end
    self.marketRefreshButton:setVisible(isMarket)
    self.marketRefreshButton:setX(w - PAD - self.marketRefreshButton.width)
    self.marketRefreshButton:setY(g.marketBarY)
    self.marketListButton:setVisible(isMarket)   -- listing starts from either page
    self.marketListButton:setX(self.marketRefreshButton.x - 6 - self.marketListButton.width)
    self.marketListButton:setY(g.marketBarY)

    chipX, chipRow = g.leftX + PAD, g.marketCardY + PAD
    for _, b in ipairs(self.marketCatButtons or {}) do
        b:setVisible(browseMode)
        if chipX > g.leftX + PAD and chipX + b.width > chipRight then
            chipX = g.leftX + PAD
            chipRow = chipRow + CHIP_H + 6
        end
        b:setX(chipX); b:setY(chipRow)
        chipX = chipX + b.width + 6
    end
    g.marketSearchY = chipRow + CHIP_H + PAD + fontH.small + 4
    self.marketEntry:setVisible(browseMode)
    self.marketEntry:setX(g.leftX + PAD)
    self.marketEntry:setY(g.marketSearchY)
    self.marketEntry:setWidth(g.leftW - PAD * 2)
    chipX, chipRow = g.leftX + PAD, g.marketSearchY + self.marketEntry.height + PAD
    for _, b in ipairs(self.marketSortButtons) do
        b:setVisible(browseMode)
        if chipX > g.leftX + PAD and chipX + b.width > chipRight then
            chipX = g.leftX + PAD
            chipRow = chipRow + CHIP_H + 6
        end
        b:setX(chipX); b:setY(chipRow)
        chipX = chipX + b.width + 6
    end

    g.marketCardX = mineMode and g.leftX or g.rightX
    g.marketCardW = mineMode and (w - PAD * 2) or g.rightW
    g.marketHeaderY = g.marketCardY + CARD_TITLE_H + ROW
    local mktListY = g.marketHeaderY + ROW
    local mktFooterH = mineMode and 0 or ROW
    local mktListW = g.marketCardW - 2
    local mktListH = math.max(ROW * 2, g.marketCardY + g.marketCardH - mktListY - PAD - mktFooterH)
    self.marketList:setVisible(isMarket)
    self.marketList:setX(g.marketCardX + 1); self.marketList:setY(mktListY)
    local mktCols = self.marketList.cols
    local mktInner = mktListW - 12
    mktCols.icon = PAD
    mktCols.name = PAD + ITEM_ICON + PAD
    mktCols.actionW = math.max(textWidth(getText(T .. "Market_Buy")), textWidth(getText(T .. "Market_Cancel")),
        textWidth(getText(T .. "Market_Own"))) + 22
    mktCols.actionX = math.max(mktCols.name, mktInner - mktCols.actionW - PAD)
    mktCols.expiresR = mktCols.actionX - PAD
    mktCols.priceR = math.max(mktCols.name + PAD, mktCols.expiresR
        - math.max(textWidth(getText(T .. "Market_Col_Expires")), textWidth("00-00 00:00")) - PAD)
    mktCols.sellerW = math.max(textWidth(getText(T .. "Market_Col_Seller")), textWidth("mmmmmmmmmm"))
    mktCols.sellerX = math.max(mktCols.name, mktCols.priceR - COIN_SMALL - 4 - textWidth("999,999") - PAD - mktCols.sellerW)
    mktCols.nameW = math.max(0, mktCols.sellerX - PAD - mktCols.name)
    if self.marketList.width ~= mktListW or self.marketList.height ~= mktListH then
        self.marketList:resize(mktListW, mktListH)
    end
    g.marketFooterY = mktListY + mktListH + 2
    local pageW = textWidth(getText(T .. "Market_Page", "99", "99"))
    x = g.marketCardX + PAD + pageW + PAD
    for _, b in ipairs({ self.marketPrevButton, self.marketNextButton }) do
        b:setVisible(browseMode)
        b:setX(x); b:setY(g.marketFooterY + math.floor((ROW - CHIP_H) / 2))
        x = x + b.width + 6
    end
    self:layoutMarketDialog()
    self:layoutBuy()
    self.layoutW, self.layoutH = w, h
    self.layoutCollapsed = self.isCollapsed
end

-- ----- drawing -----

function Panel:drawStrip()
    local g = self.g
    local w = self.width
    fill(self, PAD, g.stripY, w - PAD * 2, STRIP_H, "well")
    local x = PAD * 2
    local cy = g.stripY + math.floor((STRIP_H - COIN_STRIP) / 2)
    local ty = g.stripY + math.floor((STRIP_H - fontH.medium) / 2)
    local sep = color("border")
    for i, id in ipairs(self:currencies()) do
        local bal = C.wallet and C.wallet.balances and C.wallet.balances[id]
        if i > 1 then
            self:drawRect(x, g.stripY + 8, 1, STRIP_H - 16, sep.a, sep.r, sep.g, sep.b)
            x = x + PAD * 2
        end
        drawCoin(self, id, x, cy, COIN_STRIP)
        x = x + COIN_STRIP + PAD
        local name = C.currencyName(id)
        text(self, name, x, ty, "text", UIFont.Medium)
        x = x + textWidth(name, UIFont.Medium) + PAD
        local avail = amountText(bal and bal.available or 0)
        text(self, avail, x, ty, "accent", UIFont.Medium)
        x = x + textWidth(avail, UIFont.Medium) + PAD * 2
        local reserved = bal and tonumber(bal.reserved) or 0
        if reserved > 0 then
            self:drawRect(x, g.stripY + 8, 1, STRIP_H - 16, sep.a, sep.r, sep.g, sep.b)
            x = x + PAD * 2
            local label = getText(T .. "Wallet_Reserved")
            text(self, label, x, ty, "textMuted", UIFont.Medium)
            x = x + textWidth(label, UIFont.Medium) + PAD
            local r = amountText(reserved)
            text(self, r, x, ty, "text", UIFont.Medium)
            x = x + textWidth(r, UIFont.Medium) + PAD * 2
        end
    end
end

function Panel:drawBalanceCard(x, y, w, h, withMonth)
    card(self, x, y, w, h, getText(T .. "Wallet_Balances"))
    local cy = y + CARD_TITLE_H + PAD
    local blockH = withMonth and (ROW * 4 + PAD) or (ROW * 3 + PAD)
    for _, id in ipairs(self:currencies()) do
        if cy + blockH > y + h then break end
        local bal = C.wallet and C.wallet.balances and C.wallet.balances[id]
        fill(self, x + PAD, cy, w - PAD * 2, blockH, "well")
        drawCoin(self, id, x + PAD * 2, cy + math.floor((ROW + 4 - COIN) / 2), COIN)
        text(self, C.currencyName(id), x + PAD * 2 + COIN + PAD, cy + math.floor((ROW + 4 - fontH.medium) / 2) + 1, "text", UIFont.Medium)
        local ry = cy + ROW + 6
        local right = x + w - PAD * 3
        text(self, getText(T .. "Wallet_Available"), x + PAD * 2, ry + 3, "textMuted")
        textRight(self, amountText(bal and bal.available or 0), right, ry + math.floor((ROW - fontH.medium) / 2), "accent", UIFont.Medium)
        ry = ry + ROW
        text(self, getText(T .. "Wallet_Reserved"), x + PAD * 2, ry + 3, "textMuted")
        textRight(self, amountText(bal and bal.reserved or 0), right, ry + 3, "text")
        if withMonth then
            ry = ry + ROW
            text(self, getText(T .. "Wallet_ThisMonth"), x + PAD * 2, ry + 3, "textMuted")
            local t = self.monthTotals and self.monthTotals[id]
            local outS = "-" .. amountText(t and t.out or 0)
            local inS = "+" .. amountText(t and t.inn or 0)
            textRight(self, outS, right, ry + 3, "negative")
            local slash = " / "
            local rx = right - textWidth(outS) - textWidth(slash)
            text(self, slash, rx, ry + 3, "textFaint")
            textRight(self, inS, rx, ry + 3, "positive")
        end
        cy = cy + blockH + PAD
    end
end

function Panel:drawWallet()
    local g = self.g
    self:drawBalanceCard(g.leftX, g.contentY, g.leftW, g.contentH, true)
    card(self, g.rightX, g.contentY, g.rightW, g.contentH, getText(T .. "Wallet_Statement"))
    text(self, getText(T .. "Wallet_Period"), g.rightX + PAD, g.contentY + CARD_TITLE_H + 4 + math.floor((CHIP_H - fontH.small) / 2), "textMuted")
    -- table header
    local cols = self.list.cols
    local hx = self.list.x
    local hy = g.tableHeaderY
    fill(self, hx, hy, self.list.width, ROW, "well", "rect")
    local ty = hy + math.floor((ROW - fontH.small) / 2)
    text(self, getText(T .. "Wallet_Col_Time"), hx + cols.time, ty, "textMuted")
    text(self, getText(T .. "Wallet_Col_Kind"), hx + cols.kind, ty, "textMuted")
    text(self, fitText(getText(T .. "Wallet_Col_Desc"), cols.descW), hx + cols.desc, ty, "textMuted")
    textRight(self, getText(T .. "Wallet_Col_Amount"), hx + cols.amountR, ty, "textMuted")
    textRight(self, getText(T .. "Wallet_Col_Balance"), hx + cols.balanceR, ty, "textMuted")
    text(self, getText(T .. "Wallet_Col_Status"), hx + cols.status, ty, "textMuted")
    -- footer note
    local note
    local n = #self.list:getItems()
    if self.period == "Recent" then
        if n == 0 then note = getText(T .. "Wallet_Empty") end
    elseif self.historyLoading then
        note = getText(T .. "Wallet_Loading")
    elseif self.historyError then
        note = getText(T .. "Rewards_Error_generic", tostring(self.historyError))
    elseif self.history then
        if n == 0 then
            note = getText(T .. "Wallet_Empty")
        elseif self.history.truncated then
            note = getText(T .. "Wallet_Truncated", tostring(n), tostring(self.history.total or n))
        end
    end
    if note then
        text(self, note, hx + PAD, g.listBottom + math.floor((ROW - fontH.small) / 2), "textMuted")
    end
end

function Panel:drawRecentLedger(x, y, w, h)
    card(self, x, y, w, h, getText(T .. "Wallet_RecentLedger"))
    local ry = y + CARD_TITLE_H + 4
    local items = self.recentRows or {}
    if #items == 0 then
        text(self, getText(T .. "Wallet_Empty"), x + PAD, ry + 3, "textFaint")
        return
    end
    for i = 1, math.min(#items, math.floor((h - CARD_TITLE_H - PAD) / ROW)) do
        local e = items[i]
        if i % 2 == 0 then fill(self, x + 1, ry, w - 2, ROW, "well", "rect") end
        local ty = ry + math.floor((ROW - fontH.small) / 2)
        local token = e.rolledBack and "textFaint" or (e.amount >= 0 and "positive" or "negative")
        text(self, signedText(e.amount), x + PAD, ty, token)
        text(self, e.kindText, x + PAD + 70, ty, e.rolledBack and "textFaint" or "text")
        textRight(self, e.time, x + w - PAD, ty, "textFaint")
        if e.rolledBack then strike(self, x + PAD, ty, w - PAD * 2) end
        ry = ry + ROW
    end
end

function Panel:drawRewards()
    local g = self.g
    local st = C.rewards
    -- left column: wallet summary + recent ledger + "more history"
    local balH = CARD_TITLE_H + (ROW * 3 + PAD * 2) * #self:currencies() + PAD
    local leftAvail = g.contentH - CHIP_H - PAD * 2
    balH = math.min(balH, math.floor(leftAvail / 2))
    self:drawBalanceCard(g.leftX, g.contentY, g.leftW, balH, false)
    local ledgerY = g.contentY + balH + PAD
    self:drawRecentLedger(g.leftX, ledgerY, g.leftW, self.moreButton.y - PAD - ledgerY)

    -- right column: daily reward card
    local x, y, w = g.rightX, g.contentY, g.rightW
    card(self, x, y, w, g.dailyH, getText(T .. "Rewards_Daily"))
    local ly = y + CARD_TITLE_H + PAD
    if not st then
        text(self, getText(T .. "Wallet_Loading"), x + PAD, ly, "textMuted")
        self.claimButton:setEnable(false)
        return
    end
    local played = tonumber(st.playedMs) or 0
    local need = math.max(0, tonumber(st.minPlaytimeMs) or 0)
    local playedMin = math.floor(played / 60000)
    local needMin = math.floor(need / 60000)
    -- badge
    local badge = st.claimed and getText(T .. "Rewards_Claimed") or getText(T .. "Rewards_Available")
    local bw = textWidth(badge) + 20
    local badgeToken = st.claimed and "textMuted" or "accent"
    fill(self, x + PAD, ly, bw, CHIP_H, "selected", "pill")
    border(self, x + PAD, ly, bw, CHIP_H, badgeToken, "pill")
    textCentre(self, badge, x + PAD + bw / 2, ly + math.floor((CHIP_H - fontH.small) / 2), badgeToken)
    textRight(self, "+" .. amountText(st.amount) .. " " .. C.currencyName(st.currency), x + w - PAD, ly + math.floor((CHIP_H - fontH.medium) / 2), "accent", UIFont.Medium)
    ly = ly + ROW + 2
    local ptText
    if played >= need then
        ptText = getText(T .. "Rewards_PlaytimeMet", tostring(playedMin), tostring(needMin))
    else
        ptText = getText(T .. "Rewards_PlaytimeShort", tostring(playedMin), tostring(needMin), tostring(math.ceil((need - played) / 60000)))
    end
    text(self, ptText, x + PAD, ly + 3, "textMuted")
    -- claim button sits at ly + ROW (positioned in layout); text below it
    self.claimButton:setTitle(getText(T .. "Rewards_ClaimButton", amountText(st.amount)))
    self.claimButton.coinId = st.currency
    local frozen = C.wallet ~= nil and C.wallet.frozen == true
    local canClaim = not st.claimed and played >= need and not self.claimPending and not frozen
    self.claimButton:setEnable(canClaim)
    ly = self.claimButton.y + self.claimButton.height + PAD
    local remain = math.max(0, (tonumber(st.nextResetMs) or 0) - EC.now())
    text(self, getText(T .. "Rewards_NextDay", clockText(tonumber(st.nextResetMs) or 0, self.offsetMin), durationText(remain)), x + PAD, ly + 3, "textMuted")
    if self.message then
        textRight(self, self.message.text, x + w - PAD, ly + 3, self.message.error and "errorText" or "positive")
    end

    -- milestones card
    y = y + g.dailyH + PAD
    local mh = g.contentY + g.contentH - y
    card(self, x, y, w, mh, getText(T .. "Rewards_Milestones", tostring(st.season)))
    ly = y + CARD_TITLE_H + PAD
    local player = getPlayer()
    local survivedDays = player and (player:getHoursSurvived() / 24) or 0
    text(self, getText(T .. "Rewards_Survived", string.format("%.1f", survivedDays)), x + PAD, ly + 3, "text")
    local nextM = nil
    for _, m in ipairs(st.milestoneList or {}) do
        if not hasBit(st.milestones, m.index) then nextM = m; break end
    end
    if nextM then
        textRight(self, getText(T .. "Rewards_NextMilestone", tostring(nextM.days)), x + w - PAD, ly + 3, "textMuted")
    else
        textRight(self, getText(T .. "Rewards_AllMilestones"), x + w - PAD, ly + 3, "positive")
    end
    ly = ly + ROW + 4
    local barW = w - PAD * 2
    fill(self, x + PAD, ly, barW, 10, "track", "rect")
    if nextM and nextM.days > 0 then
        fill(self, x + PAD, ly, math.floor(barW * math.min(1, survivedDays / nextM.days)), 10, "gold", "rect")
    elseif not nextM then
        fill(self, x + PAD, ly, barW, 10, "gold", "rect")
    end
    ly = ly + 10 + PAD
    for _, m in ipairs(st.milestoneList or {}) do
        if ly + ROW > y + mh - 4 then break end
        local done = hasBit(st.milestones, m.index)
        local ty = ly + math.floor((ROW - fontH.small) / 2)
        text(self, getText(T .. "Rewards_MilestoneRow", tostring(m.days)), x + PAD, ty, done and "text" or "textMuted")
        textRight(self, getText(T .. (done and "Rewards_Achieved" or "Rewards_Pending")), x + w - PAD, ty, done and "positive" or "textFaint")
        textRight(self, "+" .. amountText(m.amount) .. " " .. C.currencyName(st.currency), x + w - PAD - 90, ty, done and "accent" or "textMuted")
        ly = ly + ROW
    end
end

function Panel:drawShop()
    local g = self.g
    local shop = C.shop
    -- left card: category chips over the search box (the chips are children, positioned in layout)
    card(self, g.leftX, g.contentY, g.leftW, g.contentH)
    text(self, getText(T .. "Shop_Search"), g.leftX + PAD, g.shopSearchY - fontH.small - 4, "textMuted")

    card(self, g.rightX, g.contentY, g.rightW, g.contentH, getText(T .. "Shop_Title"))
    local ty = g.contentY + CARD_TITLE_H + math.floor((ROW - fontH.small) / 2)
    if not shop then
        text(self, getText(T .. "Wallet_Loading"), g.rightX + PAD, ty, "textMuted")
        return
    end
    text(self, fitText(getText(T .. "Shop_Note", C.currencyName(shop.currency)), g.rightW - PAD * 2),
        g.rightX + PAD, ty, "textMuted")
    local cols = self.shopList.cols
    local hx, hy = self.shopList.x, g.shopHeaderY
    fill(self, hx, hy, self.shopList.width, ROW, "well", "rect")
    local hty = hy + math.floor((ROW - fontH.small) / 2)
    text(self, getText(T .. "Shop_Col_Item"), hx + cols.name, hty, "textMuted")
    textRight(self, getText(T .. "Shop_Col_Price"), hx + cols.priceR, hty, "textMuted")
    textRight(self, getText(T .. "Shop_Col_Remaining"), hx + cols.remainR, hty, "textMuted")
    if #self.shopList:getItems() == 0 then
        text(self, getText(T .. "Shop_Empty"), hx + PAD, self.shopList.y + math.floor((ROW - fontH.small) / 2), "textMuted")
    end
end

function Panel:drawMail()
    local g = self.g
    local mail = C.mail
    local x, w = g.leftX, self.width - PAD * 2
    card(self, x, g.contentY, w, g.contentH, getText(T .. "Mail_Title"))
    local unclaimed = tonumber(mail and mail.unclaimed) or 0
    textRight(self, getText(T .. "Mail_Count", tostring(unclaimed)), x + w - PAD,
        g.contentY + math.floor((CARD_TITLE_H - fontH.small) / 2), unclaimed > 0 and "accent" or "textMuted")
    local ty = g.contentY + CARD_TITLE_H + math.floor((ROW - fontH.small) / 2)
    if not mail then
        text(self, getText(T .. "Wallet_Loading"), x + PAD, ty, "textMuted")
        return
    end
    text(self, fitText(getText(T .. "Mail_Note"), w - PAD * 2), x + PAD, ty, "textMuted")
    if #self.mailList:getItems() == 0 then
        text(self, getText(T .. "Mail_Empty"), x + PAD, self.mailList.y + math.floor((ROW - fontH.small) / 2), "textMuted")
    end
end

function Panel:drawMarket()
    local g = self.g
    local mine = self.marketMode == "mine"
    local info = self.marketInfo
    if not mine then
        -- left card: category chips, the search box, the sort chips (all children, placed in layout)
        card(self, g.leftX, g.marketCardY, g.leftW, g.marketCardH)
        text(self, getText(T .. "Market_Search"), g.leftX + PAD, g.marketSearchY - fontH.small - 4, "textMuted")
    end
    card(self, g.marketCardX, g.marketCardY, g.marketCardW, g.marketCardH, getText(T .. "Market_Title"))
    local ty = g.marketCardY + CARD_TITLE_H + math.floor((ROW - fontH.small) / 2)
    local snap = mine and C.myListings or C.market
    if not snap then
        text(self, getText(T .. "Wallet_Loading"), g.marketCardX + PAD, ty, "textMuted")
        return
    end
    local note = mine and getText(T .. "Market_MineCount", tostring(info.mine), tostring(info.maxListings))
        or getText(T .. "Market_Note", tostring(info.taxPercent), tostring(info.feePercent))
    text(self, fitText(note, g.marketCardW - PAD * 2), g.marketCardX + PAD, ty, "textMuted")
    local cols = self.marketList.cols
    local hx, hy = self.marketList.x, g.marketHeaderY
    fill(self, hx, hy, self.marketList.width, ROW, "well", "rect")
    local hty = hy + math.floor((ROW - fontH.small) / 2)
    text(self, getText(T .. "Market_Col_Item"), hx + cols.name, hty, "textMuted")
    text(self, getText(T .. "Market_Col_Seller"), hx + cols.sellerX, hty, "textMuted")
    textRight(self, getText(T .. "Market_Col_Price"), hx + cols.priceR, hty, "textMuted")
    textRight(self, getText(T .. "Market_Col_Expires"), hx + cols.expiresR, hty, "textMuted")
    if #self.marketList:getItems() == 0 then
        text(self, getText(T .. (self.marketNoMatch and "Market_NoMatch" or "Market_Empty")),
            hx + PAD, self.marketList.y + math.floor((ROW - fontH.small) / 2), "textMuted")
    end
    if mine then return end
    -- pager strip: the page counter, the two chips (children), the server's total on the right
    local fy = g.marketFooterY + math.floor((ROW - fontH.small) / 2)
    text(self, getText(T .. "Market_Page", tostring(self.marketPage), tostring(info.pages)),
        g.marketCardX + PAD, fy, "textMuted")
    textRight(self, getText(T .. "Market_Total", tostring(info.total)),
        g.marketCardX + g.marketCardW - PAD, fy, "textMuted")
end

function Panel:drawFooter()
    local g = self.g
    local st = C.rewards
    if g.footerH == 0 or not st then return end
    local cap = tonumber(st.serverCap) or 0
    local used = math.floor((tonumber(st.serverPaidToday) or 0) * 100 / cap)
    textCentre(self, getText(T .. "Rewards_ServerCap", tostring(used)), self.width / 2, g.contentY + g.contentH + math.floor((ROW - fontH.small) / 2), "textMuted")
end

-- prerender/render replace the parent versions (rounded surfaces; see NBPanel.lua:1826-1897)
function Panel:prerender()
    if self.adminAccess ~= C.AdminPanel.canRead() then
        if self.tab == "Admin" and not C.AdminPanel.canRead() then
            self:setTab("Wallet")
        else
            self:layout()
        end
    end
    if self.width ~= self.layoutW or self.height ~= self.layoutH
        or self.layoutCollapsed ~= self.isCollapsed or (C.rewards ~= nil) ~= self.hadRewards then
        self.hadRewards = C.rewards ~= nil
        self:layout()
    end
    -- Rewards state is a snapshot (playtime accrues server-side every 60 s, sandbox thresholds can
    -- change live): re-request while the tab is open instead of asking the player to reopen.
    if self.tab == "Rewards" and not self.isCollapsed then
        local now = EC.now()
        if not self.rewardsPolledMs or now - self.rewardsPolledMs > 30000 then
            self.rewardsPolledMs = now
            C.requestRewards()
        end
    end
    -- One write in flight per page: a server that never answers must not leave the buy dialog
    -- disabled forever (the admin pages use the same window).
    if self.buyPending and EC.now() - self.buyPending.at > TIMEOUT_MS then
        self.buyPending = nil
        self:buyMessage(shopError("timeout"))
    end
    if self.mailPending and EC.now() - self.mailPending.at > TIMEOUT_MS then
        self.mailPending = nil
        C.toast(shopError("timeout"))
    end
    if self.marketPending and EC.now() - self.marketPending.at > TIMEOUT_MS then
        self.marketPending = nil
        self:marketMessage(shopError("timeout"))
    end
    -- the search box filters the page as it is typed; the server hears the text once the
    -- player stops (its own throttle would drop a command per keystroke anyway)
    if self.marketQueryAt and EC.now() >= self.marketQueryAt and self.tab == "Market" then
        self:requestBrowse(1)
    end
    local w = self:getWidth()
    local h = self:getHeight()
    local th = self:titleBarHeight()
    if self.isCollapsed then h = th end
    fill(self, 0, 0, w, h, "surface")
    fill(self, 0, 0, w, th, "surfaceTitle", not self.isCollapsed)
    if not self.isCollapsed then
        local c = color("border")
        self:drawRect(0, th - 1, w, 1, c.a, c.r, c.g, c.b)
    end
    if self.clearStentil then
        self:setStencilRect(0, 0, self.width, h)
    end
    if self.title then
        text(self, self.title, th + PAD, math.floor((th - fontH.medium) / 2), "text", UIFont.Medium)
    end
    if self.isCollapsed then return end

    -- Status line, most restrictive first: a frozen account outranks everything (nothing moves
    -- until an admin unfreezes it). Then the remote gate: no terminal registered at all, the
    -- player standing at one, or the plain "walk to a terminal".
    local g = self.g
    local band, bandToken
    if C.wallet and C.wallet.frozen then
        band, bandToken = "Band_Frozen", "errorText"
    elseif self:remoteReadOnly() then
        if #(C.terminals or {}) == 0 then
            band, bandToken = "Band_NoTerminals", "warn"
        elseif C.nearTerminal() then
            band, bandToken = "Band_AtTerminal", "positive"
        else
            band, bandToken = "Band_RemoteReadOnly", "warn"
        end
    end
    if band then
        U.Skin.dot(self, PAD * 2, g.statusY + math.floor((STATUS_H - 8) / 2), 8, color(bandToken))
        text(self, getText(T .. band), PAD * 2 + 14, g.statusY + math.floor((STATUS_H - fontH.small) / 2), bandToken)
    end
    self:drawStrip()
    fill(self, PAD, g.tabsY, w - PAD * 2, TAB_H, "well", "rect")
    local gateClosed = not self:tradeAllowed()
    self.shopList.buyDisabled = gateClosed or self.buyPending ~= nil
    self.mailList.claimDisabled = gateClosed or self.mailPending ~= nil
    local info = self.marketInfo
    self.marketList.actionDisabled = gateClosed or self.marketPending ~= nil
    self.marketListButton:setEnable(not gateClosed and self.marketPending == nil and self.marketDialog == nil
        and (info.maxListings <= 0 or info.mine < info.maxListings))
    self.marketPrevButton:setEnable(self.marketPage > 1)
    self.marketNextButton:setEnable(self.marketPage < info.pages)
    if self.tab == "Wallet" then
        self:drawWallet()
    elseif self.tab == "Rewards" then
        self:drawRewards()
    elseif self.tab == "Shop" then
        self:drawShop()
    elseif self.tab == "Market" then
        self:drawMarket()
    elseif self.tab == "Mail" then
        self:drawMail()
    end
    self:drawFooter()
end

function Panel:render()
    local w = self:getWidth()
    local h = self:getHeight()
    local th = self:titleBarHeight()
    if self.isCollapsed then h = th end
    if not self.isCollapsed and self.resizable and self.resizeWidget:getIsVisible() then
        local rh = self:resizeWidgetHeight()
        local c = color("border")
        self:drawRect(0, h - rh, w, 1, c.a, c.r, c.g, c.b)
        self:drawTextureScaled(self.resizeimage, w - rh + 1, h - rh + 1, rh - 4, rh - 4, 1, 1, 1, 1)
    end
    if self.clearStentil then
        self:clearStencilRect()
    end
    U.Skin.border(self, 0, 0, w, h, color("border"))
end

function Panel:close()
    self:setVisible(false)
end

function Panel:setVisible(visible)
    ISCollapsableWindow.setVisible(self, visible)
    self.shown = visible == true
    if self.adminPanel and not visible then self.adminPanel:setVisible(false) end
    if not visible then
        self:closeBuy()
        self:closeMarketDialog()
        pcall(function() self.shopEntry:unfocus() end)
        pcall(function() self.marketEntry:unfocus() end)
    end
    if visible then
        self.offsetMin = localOffsetMinutes()
        self:bringToTop()
        self:layout()
        self:refresh()
    end
end

-- ISLayoutManager: keep position/size, never auto-show on login.
-- The saved numbers are clamped *before* the parent applies them: UIElement.setWidth/setHeight only
-- record lastwidth/lastheight (UIElement.java:1772-1779, 1813-1820) and the anchored children
-- (resize grips, pin button) are moved by width - lastwidth at the next update (:1411-1430), so a
-- second setWidth in the same frame would drop the first delta and leave the grip off the window.
function Panel:RestoreLayout(name, layout)
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    local w = math.min(sw, math.max(MIN_WIDTH, tonumber(layout.width) or self.width))
    local h = math.min(sh, math.max(MIN_HEIGHT, tonumber(layout.height) or self.height))
    layout.width, layout.height = w, h
    layout.x = math.max(0, math.min(tonumber(layout.x) or self.x, sw - w))
    layout.y = math.max(0, math.min(tonumber(layout.y) or self.y, sh - h))
    local visible = layout.visible
    layout.visible = nil
    ISCollapsableWindow.RestoreLayout(self, name, layout)
    layout.visible = visible
    self:setVisible(false)
end

function Panel.create()
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    local w, h = defaultSize()
    local o = ISCollapsableWindow:new(math.floor((sw - w) / 2), math.floor((sh - h) / 2), w, h)
    setmetatable(o, Panel)
    o.title = getText(T .. "Toast_Title")
    o.resizable = true
    o.minimumWidth = MIN_WIDTH
    o.minimumHeight = MIN_HEIGHT
    o.period = "ThisMonth"
    o.offsetMin = localOffsetMinutes()
    o.monthTotals = nil
    o.marketMode = "browse"     -- read by createChildren (initialise -> addToUIManager, below)
    o.marketSort = "time"
    o.marketPage = 1
    o:initialise()
    o:addToUIManager()
    for _, b in ipairs(o.periodButtons) do b.active = b.internal == o.period end
    o:setVisible(false)
    ISLayoutManager.RegisterWindow(LAYOUT_NAME, Panel, o)
    return o
end

-- ---------- module API ----------

function P.instance()
    if P.window then return P.window end
    if not U.init() then return nil end
    P.window = Panel.create()
    if not P.listening then
        P.listening = true
        C.onWallet(function(kind, args) if P.window then P.window:onWallet(kind, args) end end)
        C.onRewards(function(kind, args) if P.window then P.window:onRewards(kind, args) end end)
        C.onShop(function(kind, args) if P.window then P.window:onShop(kind, args) end end)
        C.onMail(function(kind, args) if P.window then P.window:onMail(kind, args) end end)
        C.onMarket(function(kind, args) if P.window then P.window:onMarket(kind, args) end end)
        C.onTerminals(function() if P.window then P.window:onTerminals() end end)
    end
    return P.window
end

-- Hotkey / floating button. With the sandbox option RemoteReadOnly off the window may only be
-- opened next to a terminal (the terminal's own right-click entry goes through P.instance).
function P.toggle()
    if not getPlayer() then return end
    local win = P.instance()
    if not win then return end
    if not win:getIsVisible() and C.session and C.session.remoteReadOnly == false and not C.nearTerminal() then
        C.toast(getText(T .. "Toast_NeedTerminal"))
        return
    end
    win:setVisible(not win:getIsVisible())
end

-- Hotkey: [ (Keyboard.KEY_LBRACKET = 26, org/lwjglx/input/Keyboard.java); vanilla binds ] for
-- "Toggle Moveable Panel Mode" (keyBinding.lua:178-179) and leaves [ free. Rebindable in
-- Options -> Key Bindings -> [MinidoracatEconomy].
local function initBinds()
    table.insert(keyBinding, { value = "[MinidoracatEconomy]" })
    table.insert(keyBinding, { value = "MinidoracatEconomy_Toggle", key = Keyboard.KEY_LBRACKET })
end
Events.OnGameBoot.Add(initBinds)

local function onKeyPressed(key)
    if key ~= 0 and key == getCore():getKey("MinidoracatEconomy_Toggle") and isClient() then
        P.toggle()
    end
end
Events.OnKeyPressed.Add(onKeyPressed)

-- Reset per world (UIManager elements survive a return to the main menu; a new session must
-- rebuild against the new server state).
local function onGameStart()
    if P.window then
        if P.window.adminPanel then P.window.adminPanel:dispose() end
        P.window:removeFromUIManager()
        P.window = nil
    end
end
Events.OnGameStart.Add(onGameStart)
-- A resolution change (or window-mode switch) must not leave the panel off-screen or larger
-- than the screen; the size the player chose is otherwise kept.
Events.OnResolutionChange.Add(function()
    local win = P.window
    if not win then return end
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    win:setWidth(math.max(MIN_WIDTH, math.min(sw, win.width)))
    win:setHeight(math.max(MIN_HEIGHT, math.min(sh, win.height)))
    win:setX(math.max(0, math.min(win.x, sw - win.width)))
    win:setY(math.max(0, math.min(win.y, sh - win.height)))
    win:layout()
end)

return P
