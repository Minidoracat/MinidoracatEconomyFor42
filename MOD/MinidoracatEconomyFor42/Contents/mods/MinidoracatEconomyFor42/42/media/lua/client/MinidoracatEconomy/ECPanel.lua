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
require "MinidoracatEconomy/ECKeyboard"
require "MinidoracatEconomy/ECDatePicker"
local EC = MinidoracatEconomy
local C = EC.Client
local U = C.UI
local DatePicker = C.DatePicker
local Keys = C.Keyboard
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
local stampText, durationText, amountText, signedText, hasBit, kindText, card = U.stampText, U.durationText, U.amountText, U.signedText, U.hasBit, U.kindText, U.card
local accountName = U.accountName
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
    local e = U.newEntry(width, height, { maxLen = 32, clear = true, placeholder = placeholder })
    if numbers and e.setOnlyNumbers then e:setOnlyNumbers(true) end
    return e
end

local entryText, setEntryText = U.entryText, U.setEntryText

-- One box, two pages (the auction search and the record search): the hint follows the mode.
local function setPlaceholder(e, str)
    if not e or not e.setPlaceholderText then return end
    pcall(function() e:setPlaceholderText(str) end)
end

-- Item display: the engine name (getItemNameFromFullType, LuaManager.java:8579-8583) and the item
-- script's inventory texture (ScriptManager.instance:FindItem -> getNormalTexture; a script may
-- ship none). Both are cached per fullType: a catalog reply must not walk the script list again,
-- and neither call belongs in a per-frame paint.
local itemTextures = {}

local itemName = C.itemLabel

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
-- Takes the whole reply, not just the code: price_range/bid_too_low/hours_range carry bounds.
local function marketError(args)
    local code = tostring((args and args.error) or "unknown")
    if code == "price_range" then
        return getText(T .. "Market_Error_price_range",
            amountText(args.min), amountText(args.max))
    end
    if code == "bid_too_low" then
        return getText(T .. "Market_Error_bid_too_low", amountText(args.min))
    end
    if code == "hours_range" then
        return getText(T .. "Market_Error_hours_range", tostring(args.min), tostring(args.max))
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
-- A lot of N identical items is one listing: `Market_Lot` is appended to the painted name
-- (`nameText`), never to `name` — the search and the toasts want the bare item name.
local function lotText(qty)
    if qty <= 1 then return nil end
    return getText(T .. "Market_Lot", tostring(qty))
end

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
    local qty = math.max(1, math.floor(tonumber(it.qty) or 1))
    local lot = lotText(qty)
    return {
        id = it.id, item = it.item, seller = seller, price = price, currency = currency, qty = qty,
        name = name, nameText = lot and (name .. " " .. lot) or name,
        altName = alt, texture = itemTexture(it.item),
        statusText = listingStatus(it), priceText = amountText(price), expiresText = expiresText,
        own = own, mine = mine, actionMuted = own and not mine,
        actionLabel = mine and getText(T .. "Market_Cancel")
            or (own and getText(T .. "Market_Own") or getText(T .. "Market_Buy")),
    }
end

-- One auction row, painted by the very same ListingCell as a market listing. An auction runs
-- for hours, so the "ends" column is always a countdown; the current bid replaces the price
-- (an auction without a bid quotes its opening price instead) and the bid count is a column of
-- its own. That extra column costs the seller column: the seller shares the second line with
-- the condition/uses/fluid text, the way the buy dialog already names it.
-- `context` picks the action column: "browse" | "selling" | "bidding".
local function auctionRow(it, currency, context)
    local start = tonumber(it.startPrice) or 0
    local bid = tonumber(it.bid)
    local bids = math.max(0, math.floor(tonumber(it.bids) or 0))
    local name = itemName(it.item)
    local alt = it.name
    if type(alt) ~= "string" or alt == "" or alt == name then alt = itemBaseName(it.item) end
    local seller = tostring(it.seller or "")
    local left = (tonumber(it.expiresAt) or 0) - EC.now()
    local ended = left <= 0
    local qty = math.max(1, math.floor(tonumber(it.qty) or 1))
    local lot = lotText(qty)
    local mine, leading = it.mine == true, it.leading == true
    local status = listingStatus(it)
    local sub = status
    if context ~= "selling" then
        sub = getText(T .. "Market_BuyFrom", seller)
        if status then sub = sub .. " - " .. status end
    end
    -- the action column: a chip the player may press, or the state of this auction for them
    local canBid, muted, label, token, off = false, true, nil, "textFaint", false
    if context == "selling" then
        muted, label, off = false, getText(T .. "Auction_CancelTitle"), bids > 0
    elseif context == "bidding" then
        canBid = not ended
        label = leading and getText(T .. "Auction_Leading") or getText(T .. "Auction_Outbid")
        token = leading and "positive" or "warn"
    elseif mine then
        label = getText(T .. "Auction_Own")
    elseif ended then
        label, token = getText(T .. "Auction_Ended"), "warn"
    elseif leading then
        label, token = getText(T .. "Auction_Leading"), "positive"
    else
        canBid, muted, label = true, false, getText(T .. "Auction_Bid")
    end
    return {
        id = it.id, item = it.item, seller = seller, qty = qty, currency = currency,
        price = bid or start, startPrice = start, bid = bid, bids = bids,
        minNext = math.max(1, math.floor(tonumber(it.minNext) or start)),
        mine = mine, leading = leading, ended = ended, canBid = canBid,
        name = name, nameText = lot and (name .. " " .. lot) or name,
        altName = alt, texture = itemTexture(it.item), statusText = sub,
        priceText = bid and amountText(bid) or getText(T .. "Auction_StartsAt", amountText(start)),
        bidsText = bids > 0 and tostring(bids) or getText(T .. "Auction_NoBids"),
        bidsToken = bids > 0 and "accent" or "textFaint",
        expiresText = ended and getText(T .. "Auction_Ended")
            or getText(T .. "Auction_Ends_In", durationText(left)),
        expiresToken = ended and "warn" or "textFaint",
        actionMuted = muted, actionLabel = label, actionToken = token, actionOff = off,
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
    -- the server merges same-state stacks into one row: itemIds is the whole lot
    local ids = type(it.itemIds) == "table" and it.itemIds or { it.itemId }
    local count = math.max(1, math.floor(tonumber(it.count) or #ids))
    local lot = lotText(count)
    local detail = alt and (name .. " (" .. alt .. ")") or name
    if lot then detail = lot .. " " .. detail end
    if status then detail = detail .. " - " .. status end
    if reason then detail = detail .. " - " .. reason end
    return {
        itemId = it.itemId, itemIds = ids, count = count, item = it.item, ok = ok,
        name = name, altName = alt, texture = itemTexture(it.item),
        qtyText = lot, detailText = detail,
    }
end

-- One catalog row: every string the cell paints is built here (they change with the snapshot,
-- never per frame), `remaining` keeps the raw number the buy dialog clamps its count with.
local function shopRow(it, currency, buybackOpen)
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
        -- Keep the configured price visible while the server-wide switch pauses buyback.
        bidPrice = tonumber(it.bidPrice) or 0, buyback = it.buyback == true, buybackOpen = buybackOpen == true,
        buybackCap = tonumber(it.buybackCap) or 0, buybackRemaining = tonumber(it.buybackRemaining),
        sellLabel = getText(T .. "Shop_Sell", amountText(it.bidPrice or 0)),
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
    if e.buyback then
        local soff = not e.buybackOpen or self.list.buyDisabled == true or e.buybackRemaining == 0
        border(self, cols.sellX, math.floor((h - CHIP_H) / 2), cols.sellW, CHIP_H, soff and "border" or "accent", "pill")
        textCentre(self, fitText(e.sellLabel, cols.sellW - 6), cols.sellX + cols.sellW / 2, ty, soff and "textFaint" or "text")
    end
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
-- The auction tables share the cell: their `cols` drops the qty/seller columns (both live in
-- the name block) and adds the bid-count one, so every column here is painted only when the
-- owning table asked for it.
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
    local nameText = fitText(e.nameText, cols.nameW)
    text(self, nameText, cols.name, half - fontH.small - 2, "text")
    if e.altName then
        local altX = cols.name + textWidth(nameText) + 8
        local altW = cols.name + cols.nameW - altX
        if altW > 20 then text(self, fitText(e.altName, altW), altX, half - fontH.small - 2, "textFaint") end
    end
    if e.statusText then text(self, fitText(e.statusText, cols.nameW), cols.name, half + 2, "textFaint") end
    local ty = math.floor((h - fontH.small) / 2)
    local rightOfName = cols.name + cols.nameW
    if cols.qtyR then textRight(self, tostring(e.qty), cols.qtyR, ty, e.qty > 1 and "accent" or "textFaint") end
    if cols.sellerX then
        text(self, fitText(e.seller, cols.sellerW), cols.sellerX, ty, "textMuted")
        rightOfName = cols.sellerX + cols.sellerW
    end
    textRight(self, e.priceText, cols.priceR, ty, "accent")
    local coinX = cols.priceR - textWidth(e.priceText) - COIN_SMALL - 4
    if coinX > rightOfName then
        drawCoin(self, e.currency, coinX, math.floor((h - COIN_SMALL) / 2), COIN_SMALL)
    end
    if cols.bidsR then textRight(self, e.bidsText, cols.bidsR, ty, e.bidsToken or "textFaint") end
    textRight(self, e.expiresText, cols.expiresR, ty, e.expiresToken or "textFaint")
    -- the auction tables carry a second chip left of the action one: it opens this auction's
    -- record. It is a read, so the terminal gate (list.actionDisabled) never touches it, and it
    -- is hit-tested against these very numbers (Panel:onAuctionRow reads the same cols).
    if cols.histX then
        border(self, cols.histX, math.floor((h - CHIP_H) / 2), cols.histW, CHIP_H, "border", "pill")
        textCentre(self, cols.histLabel, cols.histX + cols.histW / 2, ty, "textMuted")
    end
    if e.actionMuted then
        textCentre(self, e.actionLabel, cols.actionX + cols.actionW / 2, ty, e.actionToken or "textFaint")
        return
    end
    local off = self.list.actionDisabled == true or e.actionOff == true
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
        -- the refusal dot owns the far corner; the lot count sits to its left
        local rightX = x + tw - 4
        if not e.ok then
            Skin.dot(self, x + tw - 12, 5, 7, color("negative"))
            rightX = x + tw - 14
        end
        if e.qtyText then textRight(self, e.qtyText, rightX, 4, e.ok and "accent" or "textFaint") end
        local label = fitText(e.name, tw - 8)
        textCentre(self, label, x + tw / 2, 6 + TILE_ICON + 6, e.ok and "text" or "textFaint")
    end
end

-- ---------- market history ----------
-- The player's own market ring (market.history): two lines per row, so the row height follows
-- the font the way itemRowHeight does.
local function historyLine() return fontH.small + 8 end
local function historyRowHeight() return historyLine() * 2 + 8 end

local HISTORY_KINDS = { "listed", "sold", "bought", "cancelled", "expired", "delisted", "restored",
    "auction_created", "auction_bid", "auction_outbid", "auction_sold", "auction_won",
    "auction_unsold", "auction_cancelled", "auction_restored" }
local HISTORY_TOKENS = { sold = "positive", bought = "positive", delisted = "warn", expired = "warn",
    auction_sold = "positive", auction_won = "positive", auction_outbid = "warn",
    auction_unsold = "warn", auction_cancelled = "warn", auction_created = "textFaint" }

-- One history line. The amount is what the record moved for this player: a sale nets the tax
-- off, money leaving the account (a purchase, a bid the auction now holds, the price the
-- winner paid) is negative, and everything else is the price as it stood.
local function historyRow(rec, offsetMin)
    local kind = tostring(rec.kind or "")
    local qty = math.max(1, math.floor(tonumber(rec.qty) or 1))
    local price = tonumber(rec.price) or 0
    local amount = price
    if kind == "sold" or kind == "auction_sold" then amount = price - (tonumber(rec.tax) or 0)
    elseif kind == "bought" or kind == "auction_bid" or kind == "auction_won" then amount = -price end
    local name = itemName(rec.item)
    local lot = lotText(qty)
    local parts = { stampText(tonumber(rec.ts) or 0, offsetMin) }
    if type(rec.other) == "string" and rec.other ~= "" then
        parts[#parts + 1] = getText(T .. "Market_History_Other", rec.other)
    end
    if type(rec.reason) == "string" and rec.reason ~= "" then parts[#parts + 1] = rec.reason end
    return {
        kind = kind,
        ts = tonumber(rec.ts) or 0,           -- the filter bar pages/sorts on the raw numbers
        amount = amount,
        kindText = getTextOrNull(T .. "Market_Kind_" .. kind) or kind,
        kindToken = HISTORY_TOKENS[kind] or "text",
        nameText = lot and (name .. " " .. lot) or name,
        amountText = amountText(amount),
        detailText = table.concat(parts, "  "),
        rolledBack = rec.rolledBack == true,
    }
end

-- ---------- auction history ----------
-- The auction ring (auction.history) is painted by the very same HistoryCell: the kinds the
-- server can write are a fixed set, so the kind column is measured from them.
local AUCTION_HISTORY_KINDS = { "auction_created", "auction_bid", "auction_sold", "auction_unsold",
    "auction_cancelled", "auction_restored" }

-- The accounts an entry names, in the order they matter: who sold it, who bid, who won, and
-- (on a bid) who was overtaken. Each has a label key of its own.
local ACCOUNT_KEYS = { { "Seller", "seller" }, { "Bidder", "bidder" }, { "Buyer", "buyer" },
    { "Previous", "previous" } }

-- One auction-history line. The amount is the auction's own price - the opening bid, one bid,
-- or what the item went for - and never a wallet delta: two bids in a row are two amounts, not
-- a charge taken twice, so nothing here is ever painted with a minus sign. An old auction.bid
-- event carries neither qty nor item; an unknown field is left out instead of invented.
local function auctionHistoryRow(rec, offsetMin)
    local kind = tostring(rec.kind or "")
    local price = tonumber(rec.price)
    local qty = tonumber(rec.qty)
    local lot = qty and lotText(math.max(1, math.floor(qty))) or nil
    local name = (type(rec.item) == "string" and rec.item ~= "") and itemName(rec.item) or "-"
    local id = tostring(rec.auctionId or rec.listingId or "-")
    -- the id sits right behind the time: the detail line is fitted to the card, and the id is
    -- the one thing on it the player may have to read out loud
    local parts = { stampText(tonumber(rec.ts) or 0, offsetMin), getText(T .. "Auction_History_Id", id) }
    for _, spec in ipairs(ACCOUNT_KEYS) do
        local who = rec[spec[2]]
        if type(who) == "string" and who ~= "" then
            parts[#parts + 1] = getText(T .. "Auction_History_" .. spec[1], who)
        end
    end
    return {
        kind = kind,
        ts = tonumber(rec.ts) or 0,           -- the filter bar pages/sorts on the raw numbers
        amount = price or 0,
        kindText = getTextOrNull(T .. "Market_Kind_" .. kind) or kind,
        kindToken = HISTORY_TOKENS[kind] or "text",
        nameText = lot and (name .. " " .. lot) or name,
        amountText = price and amountText(price) or "-",
        detailText = table.concat(parts, "  "),
        rolledBack = rec.rolledBack == true,
    }
end

local HistoryCell = ISPanel:derive("MinidoracatEconomyMarketHistoryCell")

function HistoryCell:render()
    local e = self.entry
    if not e then return end
    local cols = self.list.cols
    local w, h = self.width, self.height
    if self.index % 2 == 0 then fill(self, 0, 0, w, h, "card", "rect") end
    if self:isMouseOver() then fill(self, 0, 0, w, h, "hover", "rect") end
    local line = historyLine()
    local top = math.max(0, math.floor((h - line * 2) / 2))
    local muted = e.rolledBack
    text(self, e.kindText, cols.kind, top, muted and "textFaint" or e.kindToken)
    text(self, fitText(e.nameText, cols.nameW), cols.name, top, muted and "textFaint" or "text")
    textRight(self, e.amountText, cols.amountR, top, muted and "textFaint" or "accent")
    if muted then
        text(self, getText(T .. "Wallet_RolledBack"), cols.status, top, "textFaint")
        strike(self, cols.kind, top, cols.amountR - cols.kind)
    end
    text(self, fitText(e.detailText, w - cols.kind - PAD), cols.kind, top + line, "textFaint")
end

-- ---------- filter bar (market history + wallet statement) ----------
-- The two client-paged lists (the market ring and the wallet statement) get the same toolbar:
-- kind chips (multi-select; "all" clears the set), a from/to day pair, a time/amount sort pair
-- (a second click on the active chip flips the direction) and a pager under the list. Every
-- filter is local — the reply is at most a few hundred rows, so nothing here talks to the
-- server. The owner supplies the kind labeller and the field the amount sort reads.
local PER_PAGE = 25
local ARROW_W, ARROW_H = 7, 4

-- Sort direction marker next to the active column/chip: a 7x4 stair of drawRect lines, so it
-- needs no asset (Icons ships chevron_down but no chevron_up).
local function drawArrow(el, x, y, up, token)
    local c = color(token or "accent")
    for i = 0, ARROW_H - 1 do
        local w = up and (i * 2 + 1) or (ARROW_W - i * 2)
        el:drawRect(x + math.floor((ARROW_W - w) / 2), y + i, w, 1, c.a * U.alpha, c.r, c.g, c.b)
    end
end

local FilterBar = {}
FilterBar.__index = FilterBar

-- `label(kind)` names a kind chip, `amountField` is the row field the amount sort reads, and
-- `onChange(panel)` rebuilds the owner's rows. Chips/entries are children of the window (the
-- layout places them in window coordinates), so the bar only remembers them.
function FilterBar.new(panel, label, amountField, onChange)
    local bar = setmetatable({ panel = panel, label = label, amountField = amountField,
        onChange = onChange, kinds = {}, kindCount = 0, kindButtons = {}, labels = {},
        sortKey = "time", desc = true, page = 1, pages = 1, total = 0 }, FilterBar)
    local entryH = math.max(26, fontH.small + 12)
    bar.dateW = math.max(textWidth("0000-00-00"), textWidth(getText(T .. "Filter_DateHint"))) + 24
    for _, which in ipairs({ "from", "to" }) do
        local e = newEntry(bar.dateW, entryH, getText(T .. "Filter_DateHint"))
        e.target = bar
        e.onTextChangeFunction = FilterBar.onDate
        panel:addChild(e)
        bar[which .. "Entry"] = e
        DatePicker.attach(e, panel)
    end
    bar.sortButtons = {}
    for _, key in ipairs({ "time", "amount" }) do
        local title = getText(T .. "Filter_Sort_" .. key)
        local b = Button.create(0, 0, textWidth(title) + 22 + ARROW_W + 4, CHIP_H, title, bar, FilterBar.onSort, "chip")
        b.internal = key
        b.active = key == bar.sortKey
        panel:addChild(b)
        bar.sortButtons[#bar.sortButtons + 1] = b
    end
    for _, spec in ipairs({ { "Prev", -1 }, { "Next", 1 } }) do
        local title = getText(T .. "Market_" .. spec[1])
        local b = Button.create(0, 0, textWidth(title) + 22, CHIP_H, title, bar, FilterBar.onPage, "chip")
        b.internal = spec[2]
        panel:addChild(b)
        bar[string.lower(spec[1]) .. "Button"] = b
    end
    return bar
end

function FilterBar:changed()
    self.page = 1
    self.onChange(self.panel)
end

function FilterBar:onDate() self:changed() end

function FilterBar:onKind(button)
    local kind = button.internal
    if kind == "" then
        self.kinds, self.kindCount = {}, 0
    elseif self.kinds[kind] then
        self.kinds[kind] = nil
        self.kindCount = self.kindCount - 1
    else
        self.kinds[kind] = true
        self.kindCount = self.kindCount + 1
    end
    for _, b in ipairs(self.kindButtons) do
        b.active = b.internal == "" and self.kindCount == 0 or self.kinds[b.internal] == true
    end
    self:changed()
end

function FilterBar:onSort(button)
    if self.sortKey == button.internal then
        self.desc = not self.desc
    else
        self.sortKey = button.internal
        self.desc = true          -- newest / largest first, both ways round
    end
    for _, b in ipairs(self.sortButtons) do b.active = b.internal == self.sortKey end
    self:changed()
end

function FilterBar:onPage(button)
    local page = self.page + button.internal
    if page < 1 or page > self.pages then return end
    self.page = page
    self.onChange(self.panel)
end

-- The chips are the kinds the reply actually carries (plus "all"), the rule the shop/market
-- category chips follow. Rebuilt only when that set changes; the caller re-runs layout.
function FilterBar:syncKinds(rows)
    local seen, order, sig = {}, { "" }, ""
    for _, e in ipairs(rows) do
        local kind = e.kind
        if type(kind) == "string" and kind ~= "" and not seen[kind] then
            seen[kind] = true
            order[#order + 1] = kind
            sig = sig .. kind .. ","
        end
    end
    -- a kind that left the data must not stay selected (its chip is gone). The stale keys are
    -- collected first: Kahlua is not promised to survive a delete mid-traversal.
    local stale = {}
    for kind in pairs(self.kinds) do
        if not seen[kind] then stale[#stale + 1] = kind end
    end
    for _, kind in ipairs(stale) do
        self.kinds[kind] = nil
        self.kindCount = self.kindCount - 1
    end
    if sig == self.kindSig then return false end
    self.kindSig = sig
    for _, b in ipairs(self.kindButtons) do
        b:setVisible(false)
        self.panel:removeChild(b)
    end
    self.kindButtons = {}
    for _, kind in ipairs(order) do
        local title = kind == "" and getText(T .. "Filter_All") or self.label(kind)
        local b = Button.create(0, 0, textWidth(title) + 22, CHIP_H, title, self, FilterBar.onKind, "chip")
        b.internal = kind
        b.active = kind == "" and self.kindCount == 0 or self.kinds[kind] == true
        self.panel:addChild(b)
        self.kindButtons[#self.kindButtons + 1] = b
    end
    return true
end

-- EC.filterPage options for the current filter state. A malformed date is "no bound" (the
-- player is still typing); "to" is the end of that day, so the day itself is included.
function FilterBar:opts(timeField)
    local offset = self.panel.offsetMin or 0
    local from = EC.parseDay(entryText(self.fromEntry), offset)
    local to = EC.parseDay(entryText(self.toEntry), offset)
    return {
        kinds = self.kindCount > 0 and self.kinds or nil,
        fromMs = from, toMs = to and (to + 86400000) or nil,
        timeField = timeField or "ts",
        sortKey = self.sortKey == "amount" and self.amountField or (timeField or "ts"),
        desc = self.desc, page = self.page, perPage = PER_PAGE,
    }
end

function FilterBar:setPage(page, pages, total)
    self.page, self.pages, self.total = page, pages, total
end

-- One wrapped row of widgets between x and right; returns the y under the last row. Wrapping
-- (the shop's chip rule) is what keeps the bar inside the card at every font scale.
function FilterBar:layout(x, y, right, visible)
    local labels = {}
    local cx, cy = x, y
    local band = math.max(CHIP_H, self.fromEntry.height)
    local ty = math.floor((band - fontH.small) / 2)
    local function place(w)
        if cx > x and cx + w > right then
            cx = x
            cy = cy + band + 6
        end
        local at = cx
        cx = cx + w + 6
        return at
    end
    local function labelAt(key)
        local str = getText(T .. key)
        local x = place(textWidth(str))     -- place() may open a new row: read cy after it
        labels[#labels + 1] = { text = str, x = x, y = cy + ty }
    end
    local function dateAt(entry, key)
        local label = getText(T .. key)
        local labelW = textWidth(label)
        local button = entry.calendarButton
        local at = place(labelW + 4 + self.dateW + 4 + band)
        labels[#labels + 1] = { text = label, x = at, y = cy + ty }
        entry:setVisible(visible)
        entry:setWidth(self.dateW)
        entry:setX(at + labelW + 4); entry:setY(cy + math.floor((band - entry.height) / 2))
        button:setVisible(visible)
        button:setWidth(band); button:setHeight(band)
        button:setX(entry.x + self.dateW + 4); button:setY(cy)
    end
    labelAt("Filter_Kind")
    for _, b in ipairs(self.kindButtons) do
        b:setVisible(visible)
        b:setX(place(b.width)); b:setY(cy + math.floor((band - b.height) / 2))
    end
    dateAt(self.fromEntry, "Filter_From")
    dateAt(self.toEntry, "Filter_To")
    labelAt("Filter_Sort")
    for _, b in ipairs(self.sortButtons) do
        b:setVisible(visible)
        b:setX(place(b.width)); b:setY(cy + math.floor((band - b.height) / 2))
    end
    self.labels = labels
    return cy + band
end

-- Pager strip under the list: the page counter on the left, the two chips, the row count right.
function FilterBar:layoutPager(x, y, right, visible)
    local cx = x + textWidth(getText(T .. "Filter_Page", "99", "99")) + PAD
    self.pagerY = y
    self.pagerRight = right
    for _, b in ipairs({ self.prevButton, self.nextButton }) do
        b:setVisible(visible)
        b:setX(cx); b:setY(y + math.floor((ROW - CHIP_H) / 2))
        cx = cx + b.width + 6
    end
end

function FilterBar:draw(el)
    for _, l in ipairs(self.labels) do text(el, l.text, l.x, l.y, "textMuted") end
    for _, b in ipairs(self.sortButtons) do
        if b.active then
            drawArrow(el, b.x + b.width - ARROW_W - 8, b.y + math.floor((CHIP_H - ARROW_H) / 2), not self.desc)
        end
    end
end

function FilterBar:drawPager(el, x)
    local ty = self.pagerY + math.floor((ROW - fontH.small) / 2)
    text(el, getText(T .. "Filter_Page", tostring(self.page), tostring(self.pages)), x, ty, "textMuted")
    textRight(el, getText(T .. "Filter_Count", tostring(self.total)), self.pagerRight, ty, "textMuted")
    self.prevButton:setEnable(self.page > 1)
    self.nextButton:setEnable(self.page < self.pages)
end

-- Count bubble on the top-right corner of a tab button (the Mail tab): a red circle through the
-- framework's dot texture, widened into a pill from two digits on. The float button paints the
-- same shape without the toolkit (U.init has not run before the first window opens).
local BADGE_FILL = { r = 0.85, g = 0.2, b = 0.2, a = 1 }
local BADGE_RIM = { r = 1, g = 1, b = 1, a = 1 }
local function drawBadge(el, rightX, y, n)
    local label = n > 99 and "99+" or tostring(n)
    local size = math.max(18, fontH.small + 6)
    local w = math.max(size, textWidth(label) + 8)
    local x = rightX - w
    if w <= size then
        U.Skin.dot(el, x, y, size, BADGE_FILL, BADGE_RIM)
    else
        U.Skin.fill(el, x, y, w, size, BADGE_FILL, "pill")
        U.Skin.border(el, x, y, w, size, BADGE_RIM, "pill")
    end
    el:drawTextCentre(label, x + w / 2, y + math.floor((size - fontH.small) / 2), 1, 1, 1, 1, UIFont.Small)
end

-- ---------- sortable table header ----------
-- A server-sorted page needs the header to be a control, not a caption: one transparent panel
-- over the header row, hit-tested against the same column numbers the cells paint with. The
-- market table and the auction table each own one instance; the panel fields it reads (the hit
-- list, the current sort, whether clicks are live) come from the instance, so one class serves
-- both without either page knowing about the other.

-- "price_desc" -> "price", true. The default time sort is newest first and its ascending twin
-- is a server key of its own ("time_asc"), so no column ever resolves to an ascending "time".
local function sortParts(sort)
    local key = tostring(sort or "")
    local base = string.match(key, "^(.*)_desc$")
    if base then return base, true end
    return key, false
end

local MarketHeader = ISPanel:derive("MinidoracatEconomyMarketHeader")

function MarketHeader:render()
    local panel = self.panel
    local w, h = self.width, self.height
    fill(self, 0, 0, w, h, "well", "rect")
    local ty = math.floor((h - fontH.small) / 2)
    local ay = ty + math.floor((fontH.small - ARROW_H) / 2)
    local sortKey, desc = sortParts(panel[self.sortField])
    local live = self.isLive(panel)
    for _, c in ipairs(panel[self.hitsField] or {}) do
        local active = c.key == sortKey
        local token = active and "accent" or (live and "textMuted" or "textFaint")
        local room = c.w - (active and (ARROW_W + 4) or 0)
        local label = fitText(c.title, room)
        if c.right then
            local rx = c.x + c.w
            if active then
                drawArrow(self, rx - ARROW_W, ay, not desc, token)
                rx = rx - ARROW_W - 4
            end
            textRight(self, label, rx, ty, token)
        else
            text(self, label, c.x, ty, token)
            if active then drawArrow(self, c.x + textWidth(label) + 4, ay, not desc, token) end
        end
    end
end

function MarketHeader:onMouseDown(x)
    self.onHit(self.panel, x)
    return true
end

local function newHeader(panel, sortField, hitsField, isLive, onHit)
    local h = ISPanel:new(0, 0, 100, ROW)
    setmetatable(h, MarketHeader)
    h.background = false
    h.panel = panel
    h.sortField, h.hitsField, h.isLive, h.onHit = sortField, hitsField, isLive, onHit
    h:initialise()
    return h
end

-- ---------- preference sliders ----------
-- Skin.slider is a stateless painter, so the drag lives here: the press remembers where it
-- landed inside the track and onMouseMove walks that x with the engine's deltas (ISUIElement
-- hands over dx/dy, not a point). One class, two specs: the title-row chrome opacity and the
-- toast seconds in the preference popover. spec = { min, max, get(), set(v, dragging), flush() }.
local OPACITY_W = 120
-- 5 % per chip, the step the ModOptions slider uses too; the bounds are ECOptions' own
local OPACITY_STEP = 5
local OPACITY_MIN = (EC.Options and EC.Options.OPACITY_MIN) or 30
local OPACITY_MAX = (EC.Options and EC.Options.OPACITY_MAX) or 100
local OPACITY_SPAN = OPACITY_MAX - OPACITY_MIN

local function opacityPercent()
    local O = EC.Options
    local v = (O and O.panelOpacity) and O.panelOpacity() or 1
    v = math.floor((tonumber(v) or 1) * 100 + 0.5)
    if v < OPACITY_MIN then v = OPACITY_MIN elseif v > OPACITY_MAX then v = OPACITY_MAX end
    return v
end

local function setOpacityPercent(v, dragging)
    if v < OPACITY_MIN then v = OPACITY_MIN elseif v > OPACITY_MAX then v = OPACITY_MAX end
    local O = EC.Options
    if O and O.setPanelOpacity then O.setPanelOpacity(v, dragging == true) else U.setAlpha(v / 100) end
end

local function optionsFlush()
    if EC.Options and EC.Options.flush then EC.Options.flush() end   -- one ini write per drag
end

local OPACITY_SPEC = { min = OPACITY_MIN, max = OPACITY_MAX, get = opacityPercent, set = setOpacityPercent, flush = optionsFlush }

local function toastSeconds()
    local O = EC.Options
    if O and O.toastSeconds then return O.toastSeconds() end
    return 5
end

local TOAST_SPEC = {
    min = (EC.Options and EC.Options.TOAST_MIN) or 2, max = (EC.Options and EC.Options.TOAST_MAX) or 10,
    get = toastSeconds,
    set = function(v, dragging)
        if EC.Options and EC.Options.setToastSeconds then EC.Options.setToastSeconds(v, dragging == true) end
    end,
    flush = optionsFlush,
}

local PrefSlider = ISPanel:derive("MinidoracatEconomyPrefSlider")

function PrefSlider:valueAt(x)
    local ratio = x / math.max(1, self.width - 1)
    if ratio < 0 then ratio = 0 elseif ratio > 1 then ratio = 1 end
    local s = self.spec
    return s.min + math.floor(ratio * (s.max - s.min) + 0.5)
end

function PrefSlider:onMouseDown(x)
    self.dragging = true
    self.dragX = x
    self.spec.set(self:valueAt(x), true)
    return true
end

function PrefSlider:onMouseMove(dx)
    if not self.dragging then return end
    self.dragX = (self.dragX or 0) + (tonumber(dx) or 0)
    self.spec.set(self:valueAt(self.dragX), true)
end
PrefSlider.onMouseMoveOutside = PrefSlider.onMouseMove   -- the pointer leaves the track mid-drag

function PrefSlider:onMouseUp()
    if self.dragging then self.spec.flush() end
    self.dragging = false
    return true
end
PrefSlider.onMouseUpOutside = PrefSlider.onMouseUp

function PrefSlider:render()
    local s = self.spec
    U.Skin.slider(self, 0, 0, self.width, self.height, (s.get() - s.min) / math.max(1, s.max - s.min),
        { track = color("track"), fill = color("gold"), knob = color("text"), border = color("border") }, U.alpha)
end

local function newPrefSlider(width, height, spec)
    local s = ISPanel:new(0, 0, width, height)
    setmetatable(s, PrefSlider)
    s.background = false
    s.spec = spec
    s:initialise()
    return s
end

-- ---------- window chrome buttons ----------
-- The vanilla title buttons (Button_Close / Button_Pin / Button_Collapse textures) restyled
-- with the framework's line icons: the button keeps its click, only the paint changes. Without
-- the icon capability the vanilla textures stay.
local CHROME_ICON = 16
local function iconButton(btn, name)
    local Icons = U.framework and U.framework.Icons
    if not (Icons and Icons.get and Icons.get(name)) then return end
    btn.image = nil
    btn.iconName = name
    btn.render = function(b)
        local hot = b:isMouseOver()
        Icons.draw(b, b.iconName, math.floor((b.width - CHROME_ICON) / 2), math.floor((b.height - CHROME_ICON) / 2),
            CHROME_ICON, color(hot and "text" or "textMuted"), 1)
    end
end

-- ---------- preference popover ----------
-- A small panel under the title-row gear: the preferences that are the player's own (kept by
-- ECOptions in ModOptions.ini). Opens/closes with the gear, closes with the tab and the window.
local PREFS_W = 300
local PrefsPopover = ISPanel:derive("MinidoracatEconomyPrefsPopover")

function PrefsPopover:createChildren()
    local lineH = fontH.small + 8
    self.toastSlider = newPrefSlider(PREFS_W - PAD * 2 - textWidth("10 s") - 8, lineH, TOAST_SPEC)
    self:addChild(self.toastSlider)
    self.toastY = PAD + fontH.medium + PAD + fontH.small + 4
    self.toastSlider:setX(PAD)
    self.toastSlider:setY(self.toastY)
    self.noteY = self.toastY + lineH + PAD
    self:setHeight(self.noteY + fontH.small + PAD)
end

function PrefsPopover:prerender()
    local w, h = self.width, self.height
    fill(self, 0, 0, w, h, "surface")
    U.Skin.border(self, 0, 0, w, h, color("border"))
    text(self, getText(T .. "Prefs_Title"), PAD, PAD, "text", UIFont.Medium)
    local y = PAD + fontH.medium + PAD
    text(self, fitText(getText("UI_MinidoracatEconomy_ToastSeconds"), w - PAD * 2), PAD, y - 2, "textMuted")
    textRight(self, getText(T .. "Prefs_Seconds", tostring(toastSeconds())), w - PAD, self.toastY + math.floor((self.toastSlider.height - fontH.small) / 2), "text")
    text(self, fitText(getText(T .. "Prefs_ModOptionsNote"), w - PAD * 2), PAD, self.noteY, "textFaint")
end

function PrefsPopover:onMouseDown() return true end   -- clicks inside never fall through to the window
function PrefsPopover:onMouseUp() return true end

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
    local buy = getText(T .. (self.sell and "Shop_SellConfirm" or "Shop_Buy"))
    local bh = math.max(28, fontH.medium + 10)
    self.confirmButton = Button.create(0, 0, math.max(120, textWidth(buy, UIFont.Medium) + 40), bh, buy, self, BuyDialog.onConfirm, "primary")
    self.confirmButton.font = UIFont.Medium
    self:addChild(self.confirmButton)
    local cancel = getText(T .. "Admin_Cancel")
    self.cancelButton = Button.create(0, 0, textWidth(cancel) + 30, bh, cancel, self, BuyDialog.onCancel, "chip")
    self:addChild(self.cancelButton)
end

-- Lots per purchase: the server cap, and never more than today's remaining share. Selling: whole
-- SKU units the backpack holds, within every remaining cap the server reported (units for the
-- SKU, coins for the account and the server); 0 when there is nothing to sell.
function BuyDialog:maxCount()
    local max = math.max(1, tonumber(C.shop and C.shop.countMax) or 1)
    local row = self.row
    if self.sell then
        local c = self.cand
        if not c then return 0 end
        local unitQty = math.max(1, math.floor(tonumber(c.unitQty) or 1))
        local units = math.floor((tonumber(c.count) or 0) / unitQty)
        local bb = c.buyback or {}
        local bid = math.max(1, math.floor(tonumber(c.bidPrice) or row.bidPrice or 1))
        if bb.skuRemaining ~= nil then units = math.min(units, math.floor(tonumber(bb.skuRemaining) or 0)) end
        if bb.accountRemaining ~= nil then units = math.min(units, math.floor((tonumber(bb.accountRemaining) or 0) / bid)) end
        if bb.serverRemaining ~= nil then units = math.min(units, math.floor((tonumber(bb.serverRemaining) or 0) / bid)) end
        return math.max(0, math.min(max, units))
    end
    if row.dailyCap > 0 and row.remaining then max = math.min(max, math.max(1, row.remaining)) end
    return max
end

function BuyDialog:total()
    if self.sell then return self.count * math.floor(tonumber(self.cand and self.cand.bidPrice) or self.row.bidPrice or 0) end
    return self.count * self.row.price
end

function BuyDialog:available()
    local bal = C.wallet and C.wallet.balances and C.wallet.balances[self.row.currency]
    return bal and tonumber(bal.available) or 0
end

function BuyDialog:onStep(button)
    self.count = math.max(1, math.min(self:maxCount(), self.count + button.internal))
    self.message = nil
end

function BuyDialog:onCancel() self.panel:closeBuy() end
function BuyDialog:onConfirm()
    if self.sell then self.panel:submitSell(self) else self.panel:submitBuy(self) end
end

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
    if self.sell then self.roomY = y; y = y + line * 2 + 4 end
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
    local sell = self.sell == true
    fill(self, 0, 0, w, h, "surface")
    border(self, 0, 0, w, h, "accent")
    text(self, fitText(getText(T .. (sell and "Shop_SellTitle" or "Shop_BuyTitle"), row.name), w - PAD * 2, UIFont.Medium), PAD, self.titleY, "text", UIFont.Medium)
    drawIcon(self, row.texture, PAD, self.itemY, ITEM_ICON)
    local tx = PAD + ITEM_ICON + PAD
    text(self, fitText(row.name, w - tx - PAD), tx, self.itemY, "text")
    local c = self.cand
    if sell then
        -- what the backpack holds, in the server's words (only canonical copies count)
        local have
        if not c then have = getText(T .. "Wallet_Loading")
        elseif (tonumber(c.count) or 0) < 1 then have = getText(T .. "Shop_SellNone")
        else have = getText(T .. "Shop_SellHave", tostring(math.floor(tonumber(c.count) or 0)), tostring(math.floor(tonumber(c.unitQty) or 1)), amountText(c.bidPrice)) end
        text(self, fitText(have, w - tx - PAD), tx, self.itemY + fontH.small + 4, (c and (tonumber(c.count) or 0) < 1) and "warn" or "textFaint")
    else
        text(self, row.qtyText, tx, self.itemY + fontH.small + 4, "textFaint")
    end
    local max = self:maxCount()
    if self.count > max then self.count = max end
    if sell and self.count < 1 and max >= 1 then self.count = 1 end
    local stepH = self.minusButton.height
    text(self, getText(T .. (sell and "Shop_SellUnits" or "Shop_Count")), PAD, self.countY + math.floor((stepH - fontH.small) / 2), "textMuted")
    textCentre(self, tostring(self.count), self.numX + self.numW / 2, self.countY + math.floor((stepH - fontH.medium) / 2), "text", UIFont.Medium)
    local total = self:total()
    local after = sell and (self:available() + total) or (self:available() - total)
    local totalText = amountText(total)
    text(self, getText(T .. (sell and "Shop_SellTotal" or "Shop_Total")), PAD, self.totalY, "textMuted")
    textRight(self, totalText, w - PAD, self.totalY, sell and "positive" or "accent")
    drawCoin(self, row.currency, w - PAD - textWidth(totalText) - COIN_SMALL - 4, self.totalY + math.floor((fontH.small - COIN_SMALL) / 2), COIN_SMALL)
    text(self, getText(T .. "Shop_AfterBalance"), PAD, self.afterY, "textMuted")
    textRight(self, amountText(after), w - PAD, self.afterY, after < 0 and "warn" or "text")
    if sell and c and type(c.buyback) == "table" then
        local bb = c.buyback
        text(self, fitText(getText(T .. "Shop_SellRoom", amountText(bb.accountRemaining or 0), amountText(bb.serverRemaining or 0)), w - PAD * 2), PAD, self.roomY, "textFaint")
        if bb.skuRemaining ~= nil then
            text(self, fitText(getText(T .. "Shop_SellRoomSku", tostring(math.floor(tonumber(bb.skuRemaining) or 0))), w - PAD * 2), PAD, self.roomY + fontH.small + 4, "textFaint")
        end
    end
    if self.message then text(self, fitText(self.message, w - PAD * 2), PAD, self.messageY, "errorText") end
    local pending = self.panel.buyPending ~= nil
    self.minusButton:setEnable(self.count > 1 and not pending)
    self.plusButton:setEnable(self.count < max and not pending)
    local ok = sell and (max >= 1 and self.count >= 1) or (not sell and after >= 0)
    self.confirmButton:setEnable(ok and not pending and self.panel:tradeAllowed())
end

function BuyDialog:render() end

-- the page underneath must not be operable while the dialog is open
function BuyDialog:onMouseDown() return true end
function BuyDialog:onMouseUp() return true end
function BuyDialog:onMouseMove() return true end

-- ---------- market / auction dialog ----------
-- Same shape as BuyDialog (a child panel centred over the content, swallowing the page's
-- clicks), with every step of both trade pages on one panel: the purchase, the cancel
-- confirmation, the backpack picker and the pricing step the picker hands over to (the picker
-- switches its own content instead of stacking a second dialog on top of itself), plus the
-- auction bid, the auction create step the same picker hands over to, and its cancel.
local MarketDialog = ISPanel:derive("MinidoracatEconomyMarketDialog")

-- The durations offered when the sandbox range allows them; a range that holds none of them
-- (a server that only permits 10..30 h, say, still keeps 12 and 24) falls back to its bounds.
local HOUR_PRESETS = { 6, 12, 24, 48, 72 }
local HOUR_DEFAULT = 24

local function hourChoices(minH, maxH)
    local out = {}
    for _, hrs in ipairs(HOUR_PRESETS) do
        if hrs >= minH and hrs <= maxH then out[#out + 1] = hrs end
    end
    if #out == 0 then
        out[1] = minH
        if maxH > minH then out[2] = maxH end
    end
    return out
end

-- the auction steps confirm through Panel:submitAuction, the market ones through submitMarket
local AUCTION_MODES = { bid = true, auction = true, acancel = true }

local function confirmLabel(mode)
    if mode == "buy" then return getText(T .. "Market_Buy") end
    if mode == "cancel" then return getText(T .. "Market_Cancel") end
    if mode == "price" then return getText(T .. "Market_List") end
    if mode == "bid" then return getText(T .. "Auction_Bid") end
    if mode == "auction" then return getText(T .. "Auction_Create") end
    if mode == "acancel" then return getText(T .. "Auction_CancelTitle") end
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
    -- the lot size: only shown when the picked row carries more than one item
    self.qtyEntry = newEntry(140, math.max(26, fontH.small + 12), nil, true)
    self.qtyEntry.target = self
    self.qtyEntry.onTextChangeFunction = MarketDialog.onPriceChanged
    self:addChild(self.qtyEntry)
    local only = getText(T .. "Market_OnlyListable")
    self.onlyButton = Button.create(0, 0, textWidth(only) + 30, math.max(CHIP_H, fontH.small + 10),
        only, self, MarketDialog.onOnlyListable, "chip")
    self.onlyListable = true             -- the backpack is mostly unlistable: start on the useful half
    self.onlyButton.active = true
    self:addChild(self.onlyButton)
    -- auction duration chips: one per preset, retitled when the create step opens (the sandbox
    -- range decides which of them exist, so they are built once and hidden until then)
    self.hourButtons = {}
    for i = 1, #HOUR_PRESETS do
        local b = Button.create(0, 0, 60, math.max(CHIP_H, fontH.small + 10), "", self, MarketDialog.onHours, "chip")
        b:setVisible(false)
        self:addChild(b)
        self.hourButtons[i] = b
    end
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
function MarketDialog:onConfirm()
    if AUCTION_MODES[self.mode] then self.panel:submitAuction(self) else self.panel:submitMarket(self) end
end

function MarketDialog:onHours(button)
    self.hours = button.internal
    for _, b in ipairs(self.hourButtons) do b.active = b.internal == self.hours end
    self.message = nil
end

-- The create step opens: build the chip set the sandbox range allows and preselect the one
-- closest to a day (the duration a player picks by default on every auction house there is).
function MarketDialog:setHourRange(minH, maxH)
    local choices = hourChoices(minH, maxH)
    local best = choices[1]
    for _, hrs in ipairs(choices) do
        if math.abs(hrs - HOUR_DEFAULT) < math.abs(best - HOUR_DEFAULT) then best = hrs end
    end
    self.hours = best
    for i, b in ipairs(self.hourButtons) do
        b.internal = choices[i]
        if b.internal then
            local title = getText(T .. "Auction_Hours", tostring(b.internal))
            b:setTitle(title)
            b:setWidth(textWidth(title) + 22)
            b.active = b.internal == best
        end
    end
end
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

-- The lot size to list, 1..count. nil = not a usable number: the confirm stays closed instead
-- of the server refusing a request the client could already tell was wrong.
function MarketDialog:lotCount()
    return (self.cand and self.cand.count) or 1
end

function MarketDialog:qtyValue()
    local max = self:lotCount()
    if max <= 1 then return 1 end
    local raw = string.match(entryText(self.qtyEntry), "^%s*(.-)%s*$")
    if not string.match(raw, "^%d+$") then return nil end
    local n = tonumber(raw)
    if not n or n < 1 or n > max then return nil end
    return math.floor(n)
end

function MarketDialog:available()
    local currency = (self.row and self.row.currency) or (C.market and C.market.currency)
        or (C.auction and C.auction.currency)
    local bal = C.wallet and C.wallet.balances and C.wallet.balances[currency]
    return bal and tonumber(bal.available) or 0
end

-- Raising an own leading bid only reserves the difference: the server holds the first amount
-- already (ECAuction.bid takes `delta` off the available balance, not the whole new bid).
function MarketDialog:bidReserve(amount)
    local row = self.row
    local held = (row and row.leading and tonumber(row.bid)) or 0
    return math.max(0, amount - held)
end

function MarketDialog:layoutInside(maxW, maxH)
    local line = fontH.small + 8
    local mode = self.mode
    local w
    if mode == "pick" then
        -- the grid is the page: 90% of the content area, never under a readable minimum
        w = math.min(maxW, math.max(640, math.floor(maxW * 0.9)))
    elseif mode == "cancel" or mode == "acancel" then
        w = math.max(340, math.min(maxW, 480))
    elseif mode == "auction" then
        -- the duration chips share a line with their label: wide enough for all five presets
        w = math.max(340, math.min(maxW, 560))
    else
        w = math.max(340, math.min(maxW, 440))
    end
    local y = PAD
    self.titleY = y
    self.priceEntry:setVisible(mode == "price" or mode == "auction" or mode == "bid")
    local multi = (mode == "price" or mode == "auction") and self:lotCount() > 1
    self.qtyEntry:setVisible(multi)
    local hourChips = mode == "auction"
    for _, b in ipairs(self.hourButtons) do b:setVisible(hourChips and b.internal ~= nil) end
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
    elseif mode == "acancel" then
        self.bodyY = y; y = y + line
        self.hintY = y; y = y + line + 6
    elseif mode == "bid" then
        self.itemY = y; y = y + math.max(ITEM_ICON, line * 2) + PAD
        self.minNextY = y; y = y + line
        self.priceY = y; y = y + math.max(self.priceEntry.height, line) + 4
        self.reserveY = y; y = y + line
        self.afterY = y; y = y + line + 6
        self.priceEntry:setX(w - PAD - self.priceEntry.width)
        self.priceEntry:setY(self.priceY)
    elseif mode == "auction" then
        self.itemY = y; y = y + math.max(ITEM_ICON, line) + PAD
        self.qtyY, self.qtyHintY = nil, nil
        if multi then
            self.qtyY = y; y = y + math.max(self.qtyEntry.height, line) + 4
            self.qtyHintY = y; y = y + line + 6
            self.qtyEntry:setX(w - PAD - self.qtyEntry.width)
            self.qtyEntry:setY(self.qtyY)
        end
        self.priceY = y; y = y + math.max(self.priceEntry.height, line) + 4
        self.hintY = y; y = y + line + 6
        self.priceEntry:setX(w - PAD - self.priceEntry.width)
        self.priceEntry:setY(self.priceY)
        -- the duration chips sit next to their own label (the hint for the range shares the
        -- price hint line above): the create step is the tallest of the six, and the content
        -- area of a 1000x560 window at the largest UI font is all it has
        self.hoursY = y
        local chipH = self.hourButtons[1].height
        local cx, cy = PAD + textWidth(getText(T .. "Auction_Duration")) + PAD, y
        for _, b in ipairs(self.hourButtons) do
            if b.internal then
                if cx + b.width > w - PAD then
                    cx = PAD
                    cy = cy + chipH + 4
                end
                b:setX(cx); b:setY(cy)
                cx = cx + b.width + 6
            end
        end
        y = cy + math.max(chipH, line) + 6
        self.feeY = y; y = y + line + 6
    elseif mode == "price" then
        self.itemY = y; y = y + math.max(ITEM_ICON, line) + PAD
        self.qtyY, self.qtyHintY = nil, nil
        if multi then
            self.qtyY = y; y = y + math.max(self.qtyEntry.height, line) + 4
            self.qtyHintY = y; y = y + line + 6
            self.qtyEntry:setX(w - PAD - self.qtyEntry.width)
            self.qtyEntry:setY(self.qtyY)
        end
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
    if mode == "buy" then title = getText(T .. "Market_BuyTitle", self.row.nameText)
    elseif mode == "cancel" then title = getText(T .. "Market_Cancel")
    elseif mode == "bid" then title = getText(T .. "Auction_BidTitle", self.row.nameText)
    elseif mode == "auction" then title = getText(T .. "Auction_CreateTitle")
    elseif mode == "acancel" then title = getText(T .. "Auction_CancelTitle") end
    local titleW = w - PAD * 2
    if mode == "pick" then
        -- title, counter and filter chip share the head line: the counter takes its width first
        self.countText = getText(T .. "Market_PickCount", tostring(self.candListable or 0),
            tostring(self.candTotal or 0))
        local info = self.panel.marketInfo or {}
        if info.mailCapacity then
            -- a listing takes a mailbox slot: the counter says how many are left
            self.countText = getText(T .. "Market_MailUsage", tostring(info.mailUsed or 0), tostring(info.mailCapacity))
                .. "   " .. self.countText
        end
        titleW = self.countR - PAD - textWidth(self.countText) - PAD
    end
    text(self, fitText(title, titleW, UIFont.Medium), PAD, self.titleY, "text", UIFont.Medium)
    if mode == "buy" then
        local row = self.row
        drawIcon(self, row.texture, PAD, self.itemY, ITEM_ICON)
        local tx = PAD + ITEM_ICON + PAD
        text(self, fitText(row.nameText, w - tx - PAD), tx, self.itemY, "text")
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
    elseif mode == "acancel" then
        text(self, fitText(self.row.nameText, w - PAD * 2), PAD, self.bodyY, "text")
        text(self, fitText(getText(T .. "Auction_CancelHint"), w - PAD * 2), PAD, self.hintY, "textFaint")
        self.confirmButton:setEnable(not busy and panel:tradeAllowed())
    elseif mode == "bid" then
        local row = self.row
        drawIcon(self, row.texture, PAD, self.itemY, ITEM_ICON)
        local tx = PAD + ITEM_ICON + PAD
        text(self, fitText(row.nameText, w - tx - PAD), tx, self.itemY, "text")
        if row.statusText then
            text(self, fitText(row.statusText, w - tx - PAD), tx, self.itemY + fontH.small + 4, "textFaint")
        end
        text(self, fitText(getText(T .. "Auction_MinNext", amountText(row.minNext)), w - PAD * 2),
            PAD, self.minNextY, "textMuted")
        text(self, getText(T .. "Auction_YourBid"), PAD,
            self.priceY + math.floor((self.priceEntry.height - fontH.small) / 2), "textMuted")
        local amount = self:priceValue() or 0
        local reserve = self:bidReserve(amount)
        local reserveText = amountText(reserve)
        text(self, getText(T .. "Auction_WillReserve"), PAD, self.reserveY, "textMuted")
        textRight(self, reserveText, w - PAD, self.reserveY, "accent")
        drawCoin(self, row.currency, w - PAD - textWidth(reserveText) - COIN_SMALL - 4,
            self.reserveY + math.floor((fontH.small - COIN_SMALL) / 2), COIN_SMALL)
        local after = self:available() - reserve
        text(self, getText(T .. "Shop_AfterBalance"), PAD, self.afterY, "textMuted")
        textRight(self, amountText(after), w - PAD, self.afterY, after < 0 and "warn" or "text")
        self.confirmButton:setEnable(amount >= row.minNext and after >= 0 and not busy
            and not row.ended and panel:tradeAllowed())
    elseif mode == "auction" then
        local cand = self.cand
        drawIcon(self, cand.texture, PAD, self.itemY, ITEM_ICON)
        local tx = PAD + ITEM_ICON + PAD
        local count = self:lotCount()
        local candName = count > 1 and (cand.name .. " " .. cand.qtyText) or cand.name
        text(self, fitText(candName, w - tx - PAD), tx, self.itemY + math.floor((ITEM_ICON - fontH.small) / 2), "text")
        if self.qtyY then
            text(self, getText(T .. "Market_Qty"), PAD,
                self.qtyY + math.floor((self.qtyEntry.height - fontH.small) / 2), "textMuted")
            text(self, fitText(getText(T .. "Market_QtyHint", tostring(count), tostring(count)), w - PAD * 2),
                PAD, self.qtyHintY, "textFaint")
        end
        text(self, getText(T .. "Auction_StartPrice"), PAD,
            self.priceY + math.floor((self.priceEntry.height - fontH.small) / 2), "textMuted")
        -- the two ranges share the hint line: the price bounds left, the duration bounds right
        local hours = panel.auctionInfo or {}
        local hoursHint = getText(T .. "Auction_HoursHint", tostring(hours.minHours or 0),
            tostring(hours.maxHours or 0))
        textRight(self, hoursHint, w - PAD, self.hintY, "textFaint")
        text(self, fitText(getText(T .. "Market_PriceHint", amountText(info.priceMin), amountText(info.priceMax)),
            w - PAD * 2 - textWidth(hoursHint) - PAD), PAD, self.hintY, "textFaint")
        text(self, getText(T .. "Auction_Duration"), PAD,
            self.hoursY + math.floor((self.hourButtons[1].height - fontH.small) / 2), "textMuted")
        local price = self:priceValue() or 0
        text(self, getText(T .. "Market_Fee"), PAD, self.feeY, "textMuted")
        textRight(self, amountText(listingFee(price, info.feePercent)), w - PAD, self.feeY, "warn")
        self.confirmButton:setEnable(price > 0 and self:qtyValue() ~= nil and self.hours ~= nil
            and not busy and panel:tradeAllowed())
    elseif mode == "price" then
        local cand = self.cand
        drawIcon(self, cand.texture, PAD, self.itemY, ITEM_ICON)
        local tx = PAD + ITEM_ICON + PAD
        local count = self:lotCount()
        local candName = count > 1 and (cand.name .. " " .. cand.qtyText) or cand.name
        text(self, fitText(candName, w - tx - PAD), tx, self.itemY + math.floor((ITEM_ICON - fontH.small) / 2), "text")
        if self.qtyY then
            text(self, getText(T .. "Market_Qty"), PAD,
                self.qtyY + math.floor((self.qtyEntry.height - fontH.small) / 2), "textMuted")
            text(self, fitText(getText(T .. "Market_QtyHint", tostring(count), tostring(count)), w - PAD * 2),
                PAD, self.qtyHintY, "textFaint")
        end
        text(self, getText(T .. "Market_Price"), PAD,
            self.priceY + math.floor((self.priceEntry.height - fontH.small) / 2), "textMuted")
        text(self, getText(T .. "Market_PriceHint", amountText(info.priceMin), amountText(info.priceMax)),
            PAD, self.hintY, "textFaint")
        local price = self:priceValue() or 0
        text(self, getText(T .. "Market_Fee"), PAD, self.feeY, "textMuted")
        textRight(self, amountText(listingFee(price, info.feePercent)), w - PAD, self.feeY, "warn")
        text(self, getText(T .. "Market_YouGet"), PAD, self.youGetY, "textMuted")
        textRight(self, amountText(price - ceilPercent(price, info.taxPercent)), w - PAD, self.youGetY, "positive")
        self.confirmButton:setEnable(price > 0 and self:qtyValue() ~= nil and not busy and panel:tradeAllowed())
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
        local panelInfo = self.panel.marketInfo or {}
        if panelInfo.mailCapacity and (panelInfo.mailUsed or 0) >= panelInfo.mailCapacity then
            status, token = getText(T .. "Market_Error_mailbox_full"), "errorText"
        elseif hover then
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
    for _, tab in ipairs({ "Wallet", "Rewards", "Shop", "Market", "Auction", "Mail", "Admin" }) do
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
    -- the statement is paged on the client (the reply is the whole month): kind chips, a day
    -- range, a time/amount sort and the pager, all local
    self.walletBar = FilterBar.new(self, kindText, "amount", Panel.rebuildList)

    -- shop page: the category chips are rebuilt per snapshot (Panel:rebuildCategories), the
    -- search box filters the table by item name or sku id
    self.catButtons = {}
    self.shopEntry = newEntry(200, math.max(26, fontH.small + 12), getText(T .. "Shop_Search"))
    self.shopEntry.target = self
    self.shopEntry.onTextChangeFunction = Panel.onShopSearch
    self:addChild(self.shopEntry)
    self.shopList = U.newTable(ShopCell, itemRowHeight())
    self.shopList.onSelect = function(_, item) self:onShopRow(item) end
    local shopDown = self.shopList.onMouseDown
    self.shopList.onMouseDown = function(list, x, y)
        self.shopClickX = x    -- which chip of the row was hit (buy / sell)
        return shopDown(list, x, y)
    end
    self:addChild(self.shopList)

    -- mailbox page
    self.mailList = U.newTable(MailCell, itemRowHeight())
    self.mailList.onSelect = function(_, item) self:onMailRow(item) end
    self:addChild(self.mailList)

    -- market page: mode/refresh bar over either the browse cards (category + search + sort on
    -- the left, the listing table on the right) or the single "my listings" / "history" card
    local MODE_KEYS = { browse = "Browse", mine = "Mine", history = "History" }
    self.marketModeButtons = {}
    for _, mode in ipairs({ "browse", "mine", "history" }) do
        local title = getText(T .. "Market_" .. MODE_KEYS[mode])
        local b = Button.create(0, 0, textWidth(title) + 22, CHIP_H, title, self, Panel.onMarketMode, "chip")
        b.internal = mode
        b.active = mode == self.marketMode
        self:addChild(b)
        self.marketModeButtons[#self.marketModeButtons + 1] = b
        if mode == "mine" then self.marketMineButton = b end
    end
    self.marketSortButtons = {}
    for _, sort in ipairs({ "time", "time_asc", "price", "price_desc" }) do
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
    self.marketHistoryList = U.newTable(HistoryCell, historyRowHeight())
    self:addChild(self.marketHistoryList)
    self.marketHeader = newHeader(self, "marketSort", "marketHeaderHits",
        function(panel) return panel.marketMode == "browse" and not panel.browseBusy end,
        Panel.onMarketHeader)
    self:addChild(self.marketHeader)
    self.historyBar = FilterBar.new(self,
        function(kind) return getTextOrNull(T .. "Market_Kind_" .. kind) or kind end,
        "amount", Panel.rebuildMarketHistory)
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

    -- auction page: the same mode bar, one full-width card, and the browse/mine tables built
    -- from the very same ListingCell (their columns drop the seller and add the bid count)
    self.auctionModeButtons = {}
    for _, spec in ipairs({ { "browse", "Auction_Browse" }, { "mine", "Auction_Mine" },
        { "history", "Auction_History" } }) do
        local title = getText(T .. spec[2], "0", "0")
        local b = Button.create(0, 0, textWidth(title) + 22, CHIP_H, title, self, Panel.onAuctionMode, "chip")
        b.internal = spec[1]
        b.active = spec[1] == self.auctionMode
        self:addChild(b)
        self.auctionModeButtons[#self.auctionModeButtons + 1] = b
        if spec[1] == "mine" then self.auctionMineButton = b end
    end
    self.auctionEntry = newEntry(200, math.max(26, fontH.small + 12), getText(T .. "Market_Search"))
    self.auctionEntry.target = self
    self.auctionEntry.onTextChangeFunction = Panel.onAuctionSearch
    self:addChild(self.auctionEntry)
    -- the three auction tables carry two chips per row (the action and the record one), so the
    -- x of the press is remembered the way the shop rows do it
    self.auctionList = U.newTable(ListingCell, itemRowHeight())
    self.auctionList.onSelect = function(_, item) self:onAuctionRow(item, "browse") end
    self:addChild(self.auctionList)
    self.auctionSellList = U.newTable(ListingCell, itemRowHeight())
    self.auctionSellList.onSelect = function(_, item) self:onAuctionRow(item, "selling") end
    self:addChild(self.auctionSellList)
    self.auctionBidList = U.newTable(ListingCell, itemRowHeight())
    self.auctionBidList.onSelect = function(_, item) self:onAuctionRow(item, "bidding") end
    self:addChild(self.auctionBidList)
    for _, list in ipairs({ self.auctionList, self.auctionSellList, self.auctionBidList }) do
        local down = list.onMouseDown
        list.onMouseDown = function(l, x, y)
            self.auctionClickX = x
            return down(l, x, y)
        end
    end
    -- the three tables are always the same width, so they read one column set (Panel:layout
    -- fills the browse table's own; the identity is what keeps them in step)
    self.auctionSellList.cols = self.auctionList.cols
    self.auctionBidList.cols = self.auctionList.cols
    self.auctionHeader = newHeader(self, "auctionSort", "auctionHeaderHits",
        function(panel) return panel.auctionMode == "browse" and not panel.auctionBusy end,
        Panel.onAuctionHeader)
    self:addChild(self.auctionHeader)
    -- the record page: the same two-line cell and the same client-side filter bar the market
    -- ring uses, over the snapshot the server filtered for this player (or for one auction)
    self.auctionHistoryList = U.newTable(HistoryCell, historyRowHeight())
    self:addChild(self.auctionHistoryList)
    self.auctionHistoryBar = FilterBar.new(self,
        function(kind) return getTextOrNull(T .. "Market_Kind_" .. kind) or kind end,
        "amount", Panel.rebuildAuctionHistory)
    for _, spec in ipairs({ { "Refresh", "Market_Refresh", Panel.onAuctionRefresh },
        { "Create", "Auction_Create", Panel.onAuctionCreate },
        { "Prev", "Market_Prev", Panel.onAuctionPage }, { "Next", "Market_Next", Panel.onAuctionPage } }) do
        local title = getText(T .. spec[2])
        local b = Button.create(0, 0, textWidth(title) + 22, CHIP_H, title, self, spec[3], "chip")
        self:addChild(b)
        self["auction" .. spec[1] .. "Button"] = b
    end
    self.auctionPrevButton.internal = -1
    self.auctionNextButton.internal = 1
    self:updateAuctionInfo()

    self.claimButton = Button.create(0, 0, 200, 40, "", self, Panel.onClaim, "primary")
    self.claimButton.font = UIFont.Medium
    self:addChild(self.claimButton)

    local more = getText(T .. "Wallet_MoreHistory")
    self.moreButton = Button.create(0, 0, textWidth(more) + 24, CHIP_H, more, self, Panel.onMore, "chip")
    self:addChild(self.moreButton)

    local reset = getText(T .. "Window_ResetSize")
    self.resetSizeButton = Button.create(0, 0, textWidth(reset) + 20, self:titleBarHeight() - 8, reset, self, Panel.onResetSize, "chip")
    self:addChild(self.resetSizeButton)

    -- title row: the chrome opacity (a stateless Skin.slider plus two step chips), left of the
    -- reset chip and the vanilla pin/collapse buttons
    self.opacitySlider = newPrefSlider(OPACITY_W, self:titleBarHeight() - 8, OPACITY_SPEC)
    self:addChild(self.opacitySlider)
    -- the labels carry the step ("-5" / "+5"): the buy/list dialogs already own a bare
    -- "-" / "+" pair, and two chips with the same title in one window is a trap
    for _, spec in ipairs({ { "Minus", -OPACITY_STEP }, { "Plus", OPACITY_STEP } }) do
        local title = (spec[2] < 0 and "-" or "+") .. tostring(math.abs(spec[2]))
        local b = Button.create(0, 0, textWidth(title) + 14, self:titleBarHeight() - 8, title,
            self, Panel.onOpacityStep, "chip")
        b.internal = spec[2]
        self:addChild(b)
        self["opacity" .. spec[1] .. "Button"] = b
    end

    -- the vanilla title buttons wear the framework icons: close, and lock/unlock for the pin
    -- state (collapseButton shows while pinned, pinButton while not - ISCollapsableWindow.pin/collapse)
    iconButton(self.closeButton, "close")
    iconButton(self.collapseButton, "lock")
    iconButton(self.pinButton, "unlock")

    -- preferences: a gear left of the opacity group that opens the popover
    local gear = self:titleBarHeight() - 8
    self.prefsButton = Button.create(0, 0, gear, gear, "", self, Panel.onPrefs, "chip")
    iconButton(self.prefsButton, "sliders")
    self:addChild(self.prefsButton)
    self.prefsPopover = ISPanel:new(0, 0, PREFS_W, 100)
    setmetatable(self.prefsPopover, PrefsPopover)
    self.prefsPopover.background = false
    self.prefsPopover:initialise()
    self.prefsPopover:instantiate()
    self.prefsPopover:setVisible(false)
    self:addChild(self.prefsPopover)

    self:setTab("Wallet")
end

function Panel:onPrefs()
    self:showPrefs(not self.prefsPopover:getIsVisible())
end

function Panel:showPrefs(show)
    local pop = self.prefsPopover
    if not pop then return end
    pop:setVisible(show == true and not self.isCollapsed)
    if pop:getIsVisible() then
        pop:bringToTop()
        Keys.clear(self)    -- the popover owns the window: no ring is left behind it
    end
end

-- The text boxes that only exist on one page: a hidden one must not keep the keyboard.
function Panel:unfocusEntries()
    for _, e in ipairs({ self.shopEntry, self.marketEntry, self.auctionEntry,
        self.walletBar.fromEntry, self.walletBar.toEntry,
        self.historyBar.fromEntry, self.historyBar.toEntry,
        self.auctionHistoryBar.fromEntry, self.auctionHistoryBar.toEntry }) do
        pcall(function() e:unfocus() end)
    end
end

-- ----- keyboard -----
-- The ordered targets ECKeyboard walks (Tab / Shift+Tab). This window owns the two strips of tabs;
-- the money pages then hand over their own descriptors, so a page that has no keyboard flow of its
-- own offers exactly what it really has -- its tab -- and never claims more.
--
-- nil means "no keyboard right now": while one of this window's own modal dialogs (buy / list /
-- bid) or the preferences popover is open, its own mouse flow owns the window and a background
-- hotkey pressing a chip behind it would be a trap.
function Panel:keyboardTargets()
    if not self.shown or self.isCollapsed then return nil end
    if self.buyDialog or self.marketDialog then return nil end
    if self.prefsPopover and self.prefsPopover:getIsVisible() then return nil end
    local tabs = {}
    for _, b in ipairs(self.tabButtons) do
        if b:getIsVisible() then tabs[#tabs + 1] = b end
    end
    local out = { { kind = "group", controls = tabs, label = getText(T .. "Kb_Group_Tabs") } }
    local admin = self.adminPanel
    if self.tab ~= "Admin" or not self.adminAccess or admin == nil then return out end
    if admin.dialog then return nil end     -- the admin page's own modal owns the window as well
    local subs = {}
    for _, b in ipairs(admin.subTabButtons or {}) do
        if b:getIsVisible() then subs[#subs + 1] = b end
    end
    if #subs > 0 then
        out[#out + 1] = { kind = "group", controls = subs, label = getText(T .. "Kb_Group_AdminTabs") }
    end
    if admin.keyboardTargets == nil then return out end
    local ok, list = pcall(admin.keyboardTargets, admin)
    if ok and type(list) == "table" then
        for _, desc in ipairs(list) do out[#out + 1] = desc end
    end
    return out
end

-- UIManager offers key events to top-level UI only, and asks isKeyConsumed *after* the handler ran
-- (UIElement.java:2185-2214): all four hooks go to the one engine, which keeps the ledger.
function Panel:onKeyPress(key) Keys.onKeyPress(self, key) end
function Panel:onKeyRepeat(key) Keys.onKeyRepeat(self, key) end
function Panel:onKeyRelease(key) Keys.onKeyRelease(self, key) end
function Panel:isKeyConsumed(key) return Keys.isKeyConsumed(self, key) end

-- ----- actions -----

function Panel:onTab(button) self:setTab(button.internal) end

function Panel:setTab(tab)
    if tab == "Admin" and not C.AdminPanel.canRead() then tab = "Wallet" end
    if tab ~= self.tab then
        DatePicker.close()
        self:closeBuy()
        self:closeMarketDialog()
        self:unfocusEntries()
        self:cancelAuctionHistory()
        self:showPrefs(false)
    end
    self.tab = tab
    for _, b in ipairs(self.tabButtons) do b.active = b.internal == tab end
    self:layout()
    -- the page under the ring changed: the tab strips survive it, everything the old page offered
    -- does not, so the focus is revalidated instead of pointing at a hidden control
    Keys.invalidate(self)
    if self.shown then self:refresh() end
end


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
        elseif self.marketMode == "history" then
            C.requestMarketHistory()
        elseif not C.market or EC.now() - (self.marketAt or 0) > SHOP_POLL_MS then
            self:requestBrowse(1)
        end
        if not C.wallet then C.requestWallet() end
    elseif self.tab == "Auction" then
        -- an auction is a countdown: the page is always asked for again, both modes are short
        self:requestAuctionMode()
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
    self.walletBar.page = 1        -- another month starts on its own first page
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
    local cpClass = type(cp) == "string" and EC.accountClass(cp) or nil
    local desc = "-"
    if cpClass == "player" then
        desc = cp
    elseif cpClass == "discord" then
        desc = accountName(cp)
    elseif e.sourceMod then
        -- integration postings (spec 21.3): the mod's own account plus its own wording when it gave one
        desc = accountName("MOD:" .. tostring(e.sourceMod))
        if type(e.reasonText) == "string" and e.reasonText ~= "" then desc = desc .. " - " .. e.reasonText end
    elseif type(e.item) == "string" then
        -- shop purchases carry the item and count (ring and receipt files alike)
        desc = itemName(e.item) .. " x" .. tostring(math.floor(tonumber(e.qty) or 1))
    elseif cpClass ~= nil then
        -- the faucet, the burn drain, a Discord deposit: name what moved the money, not a dash
        desc = accountName(cp)
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

-- self.rows = the visible statement page, self.allRows = the whole period (the filter bar
-- filters/sorts/pages it locally), self.recentRows = the server receipt ring (rewards page
-- "recent ledger"). All rebuilt only when data or a filter changes, never per frame.
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
            self.allRows = rows
        else
            self.allRows = self.recentRows
        end
    else
        self.allRows = newestFirst(self.history and self.history.entries or {}, self.offsetMin)
    end
    local bar = self.walletBar
    if bar:syncKinds(self.allRows) and self.g then self:layout() end
    local rows, page, pages, total = EC.filterPage(self.allRows, bar:opts("ts"))
    bar:setPage(page, pages, total)
    self.rows = rows
    self.list:setItems(rows)
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
-- (shop.list, shop.buy, mail.list, mail.claim, market.buy/cancel/notice) passes it here; the
-- number itself is painted as a corner bubble in prerender, so the tab keeps its width.
function Panel:updateMailTab(unclaimed)
    local n = tonumber(unclaimed)
    if not n then return end
    self.unclaimedCount = math.max(0, math.floor(n))
    C.unclaimed = self.unclaimedCount
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
    self.shopHasBuyback = false
    for _, it in ipairs(shop and shop.items or {}) do
        if it.enabled ~= false and it.buyback == true then self.shopHasBuyback = true end
        if it.enabled ~= false and (self.shopCat == nil or it.category == self.shopCat) then
            local row = shopRow(it, shop.currency, shop.buyback and shop.buyback.enabled == true)
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


function Panel:onShopRow(row)
    if not row or self.buyDialog or self.buyPending or not self:tradeAllowed() then return end
    local cols = self.shopList.cols
    local x = self.shopClickX
    if row.buyback and x and x >= cols.sellX and x < cols.sellX + cols.sellW then
        if row.buybackOpen and row.buybackRemaining ~= 0 then self:openBuy(row, true) end
        return
    end
    if not row.soldOut then self:openBuy(row) end
end

-- sell = the buyback dialog: same panel, count in SKU units, the candidates come from the server
function Panel:openBuy(row, sell)
    self:closeBuy()
    local dlg = ISPanel:new(0, 0, 360, 200)
    setmetatable(dlg, BuyDialog)
    dlg.background = false
    dlg.panel = self
    dlg.row = row
    dlg.sell = sell == true
    dlg.cand = nil
    dlg.count = 1
    dlg.message = nil
    dlg:initialise()
    self:addChild(dlg)      -- the buttons exist from here on (instantiate -> createChildren)
    self.buyDialog = dlg
    self:layoutBuy()
    if dlg.sell then C.requestSellCandidates(row.id) end
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

function Panel:submitSell(dlg)
    local shop, c = C.shop, dlg.cand
    if not shop or not c or self.buyPending then return end
    if not self:tradeAllowed() then
        self:buyMessage(shopError("not_at_terminal"))
        return
    end
    local unitQty = math.max(1, math.floor(tonumber(c.unitQty) or 1))
    local n = dlg.count * unitQty
    local ids = {}
    for i = 1, n do ids[i] = c.itemIds[i] end
    if #ids < 1 or #ids ~= n then return end
    dlg.message = nil
    self.buyPending = { requestId = C.newRequestId(), at = EC.now(), name = dlg.row.name, sell = true }
    C.sell(dlg.row.id, ids, shop.revision, self.buyPending.requestId)
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
                if it.id == dlg.row.id and it.enabled ~= false then fresh = shopRow(it, args.currency, args.buyback and args.buyback.enabled == true) end
            end
            if fresh and (not dlg.sell or (fresh.buyback and fresh.buybackOpen)) then
                dlg.row = fresh
                self:layoutBuy()
            else
                self:closeBuy()
                C.toast(shopError(dlg.sell and "buyback_disabled" or "unknown_sku"))
            end
        end
        return
    end
    if kind == "candidates" then
        local dlg = self.buyDialog
        if dlg and dlg.sell and args.id == dlg.row.id then
            dlg.cand = args.ok ~= false and args or { count = 0, itemIds = {}, unitQty = 1, bidPrice = dlg.row.bidPrice, buyback = args.buyback }
            if args.ok == false then dlg.message = shopError(args.error) end
            self:layoutBuy()
        end
        return
    end
    -- shop.buy / shop.sell: only the reply this page is waiting for (the server echoes the requestId)
    local pending = self.buyPending
    if pending and args.requestId ~= nil and args.requestId ~= pending.requestId then return end
    self.buyPending = nil
    if args.ok then
        local name = (args.item and itemName(args.item)) or (pending and pending.name) or ""
        self:closeBuy()
        if kind == "sell" then
            C.toast(getText(T .. "Shop_Sold", name, tostring(tonumber(args.qty) or 0), amountText(args.total)))
            return
        end
        C.toast(getText(T .. "Shop_Bought", name, tostring(tonumber(args.qty) or 0)))
        if args.delivered == false then C.toast(getText(T .. "Shop_Parked")) end
        return
    end
    if args.error == "catalog_changed" then C.requestShop() end
    -- the buyback cap refusals carry how much room is left today
    local code = tostring(args.error or "unknown")
    if args.remaining ~= nil and getTextOrNull(T .. "Shop_Error_" .. code) then
        self:buyMessage(getText(T .. "Shop_Error_" .. code, tostring(math.floor(tonumber(args.remaining) or 0))))
    else
        self:buyMessage(shopError(args.error))
    end
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
    -- mailbox slots (candidates reply): a listing needs one, so the picker says when there is none
    local usage = cand and cand.usage or nil
    if type(usage) == "table" and tonumber(usage.capacity) then
        info.mailUsed = (tonumber(usage.unclaimed) or 0) + (tonumber(usage.listings) or 0)
        info.mailCapacity = tonumber(usage.capacity) or 0
    else
        info.mailUsed, info.mailCapacity = nil, nil   -- an older server: no gate on this side
    end
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

-- The server drops a second market.browse from the same player inside its 500 ms command
-- window without answering it (ECServer COMMAND_COOLDOWN_MS), so flipping two sort chips in a
-- row used to lose the second one for good. Every request goes through this gate: inside the
-- window nothing is sent, the wish is remembered, and prerender sends the *current* chip state
-- once the window is over (only the newest state can ever be wanted).
--
-- On top of that the page is `browseBusy` from the moment a request is wanted until the answer
-- lands (or BROWSE_TIMEOUT_MS passes): the sort chips, the sortable header and the pager are
-- disabled, so the player cannot queue a wish they can no longer see the state of.
local BROWSE_MIN_MS = 650
local BROWSE_TIMEOUT_MS = 5000

function Panel:sendBrowse()
    self.browseWanted = nil
    self.browseSentAt = EC.now()
    self.marketAt = self.browseSentAt
    C.requestMarket({ category = self.marketCat, query = self.marketQuery,
        sort = self.marketSort, page = self.marketPage })
end

function Panel:requestBrowse(page)
    self.marketPage = math.max(1, tonumber(page) or 1)
    self.marketQueryAt = nil
    self.browseBusy = true
    self.browseBusyAt = EC.now()
    if self.browseSentAt and EC.now() - self.browseSentAt < BROWSE_MIN_MS then
        self.browseWanted = true
        return
    end
    self:sendBrowse()
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
        -- DisplayCategory names come from the item scripts: vanilla translates them under
        -- IGUI_ItemCat_<cat> (ISInventoryPane.lua:2533), an unknown one shows the raw name
        local title = cat == "" and getText(T .. "Shop_All") or (getTextOrNull("IGUI_ItemCat_" .. cat) or cat)
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

-- The server keeps the ring oldest first (it appends); the filter bar sorts, filters and pages
-- it (newest first by default). The whole ring stays in marketHistoryAll: every chip and every
-- date keystroke re-pages that list without another round trip.
function Panel:rebuildMarketHistory()
    local snap = C.marketHistory
    local src = (snap and snap.entries) or {}
    local rows = {}
    for i = #src, 1, -1 do
        rows[#rows + 1] = historyRow(src[i], self.offsetMin)
    end
    self.marketHistoryAll = rows
    local bar = self.historyBar
    if bar:syncKinds(rows) and self.g then self:layout() end
    local page, pages, total
    rows, page, pages, total = EC.filterPage(rows, bar:opts("ts"))
    bar:setPage(page, pages, total)
    self.marketHistoryRows = rows
    self.marketHistoryList:setItems(rows)
end

-- Whatever the visible mode wants from the server (mode chips, refresh chip, seller notice).
function Panel:requestMarketMode()
    if self.marketMode == "mine" then
        C.requestMyListings()
    elseif self.marketMode == "history" then
        C.requestMarketHistory()
    else
        self:requestBrowse(self.marketPage)
    end
end

function Panel:onMarketMode(button)
    if self.marketMode == button.internal then return end
    self.marketMode = button.internal
    for _, b in ipairs(self.marketModeButtons) do b.active = b.internal == self.marketMode end
    self:closeMarketDialog()
    self:rebuildMarket()
    self:rebuildMarketHistory()
    self:layout()
    self:requestMarketMode()
end

function Panel:onMarketSort(button)
    if self.browseBusy or self.marketSort == button.internal then return end
    self.marketSort = button.internal
    for _, b in ipairs(self.marketSortButtons) do b.active = b.internal == self.marketSort end
    self:requestBrowse(1)
end

-- A click on the table header: the same column again flips the direction, a new one starts
-- ascending. Anything that is not a column (the icon column left of the item name, the gaps
-- between two columns) is the plain default sort, newest listing first.
function Panel:onMarketHeader(x)
    if self.marketMode ~= "browse" or self.browseBusy then return end
    local key = "time"
    for _, c in ipairs(self.marketHeaderHits or {}) do
        if x >= c.x and x < c.x + c.w then key = c.key end
    end
    if key ~= "time" and self.marketSort == key then key = key .. "_desc" end
    if key == self.marketSort then return end
    self.marketSort = key
    for _, b in ipairs(self.marketSortButtons) do b.active = b.internal == key end
    self:requestBrowse(1)
end

function Panel:onMarketCat(button)
    if self.browseBusy then return end
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
    self.marketHistoryError = nil
    self:requestMarketMode()
end

function Panel:onMarketPage(button)
    if self.browseBusy then return end
    local page = self.marketPage + button.internal
    if page < 1 or page > self.marketInfo.pages then return end
    self:requestBrowse(page)
end

function Panel:onOpacityStep(button)
    setOpacityPercent(opacityPercent() + button.internal)
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
    local info = self.marketInfo or {}
    if info.mailCapacity and (info.mailUsed or 0) >= info.mailCapacity then return end   -- no slot for the listing
    if not cand.ok then
        dlg.pickNote = cand.detailText   -- the refusal belongs on the status line, not in a step
        return
    end
    -- the picker is shared: which page opened it decides the step it hands over to
    dlg.mode = dlg.forAuction and "auction" or "price"
    if dlg.forAuction then
        local info = self.auctionInfo
        dlg:setHourRange(info.minHours, info.maxHours)
    end
    dlg.cand = cand
    dlg.message = nil
    dlg.pickNote = nil
    setEntryText(dlg.priceEntry, "")
    setEntryText(dlg.qtyEntry, tostring(cand.count or 1))   -- the whole lot by default
    self:layoutMarketDialog()
end

-- `forAuction` marks the picker (and the step it hands over to) as the auction page's own; the
-- auction steps ("bid", "auction", "acancel") set it too, so the dialog never has to guess.
function Panel:openMarketDialog(mode, row, forAuction)
    self:closeMarketDialog()
    local dlg = ISPanel:new(0, 0, 360, 200)
    setmetatable(dlg, MarketDialog)
    dlg.background = false
    dlg.panel = self
    dlg.mode = mode
    dlg.row = row
    dlg.forAuction = forAuction == true or AUCTION_MODES[mode] == true
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
    pcall(function() dlg.qtyEntry:unfocus() end)
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
    local mode, price, itemIds, qty, listingId, name = dlg.mode, nil, nil, 1, nil, nil
    if mode == "price" then
        local info = self.marketInfo
        price = dlg:priceValue()
        if price == nil or price < info.priceMin or (info.priceMax > 0 and price > info.priceMax) then
            dlg.message = getText(T .. "Market_Error_price_range", amountText(info.priceMin), amountText(info.priceMax))
            return
        end
        local count = dlg:lotCount()
        qty = dlg:qtyValue()
        if qty == nil then
            dlg.message = getText(T .. "Market_QtyHint", tostring(count), tostring(count))
            return
        end
        -- the lot the player asked for, taken off the front of the server's own id list
        itemIds, name = {}, dlg.cand.name
        for i = 1, qty do itemIds[i] = dlg.cand.itemIds[i] end
    else
        listingId, price, name = dlg.row.id, dlg.row.price, dlg.row.name
    end
    dlg.message = nil
    self.marketPending = { requestId = C.newRequestId(), at = EC.now(), kind = mode, name = name, qty = qty }
    if mode == "buy" then
        C.buyListing(listingId, price, self.marketPending.requestId)
    elseif mode == "cancel" then
        C.cancelListing(listingId, self.marketPending.requestId)
    else
        C.listItem(itemIds, price, self.marketPending.requestId)
    end
end

function Panel:onMarket(kind, args)
    -- the auction pages ride this listener: their kinds carry the "auction." prefix
    local auctionKind = string.match(kind, "^auction%.(.+)$")
    if auctionKind then return self:onAuction(auctionKind, args) end
    if kind == "notice" then
        -- the server told an online seller their listing left the market (or moved an auction
        -- under its bidders): the page it is on is now out of date, and ECClient already
        -- raised the toast
        self:updateMailTab(args.unclaimed)
        if not self.shown or self.isCollapsed then return end
        if self.tab == "Market" then self:requestMarketMode()
        elseif self.tab == "Auction" then self:requestAuctionMode() end
        return
    end
    if kind == "whitelist" then
        local open = self.marketDialog
        if open and open.mode == "pick" then C.requestCandidates() end
        return
    end
    if kind == "history" then
        self.marketHistoryError = args.error and marketError(args) or nil
        self:rebuildMarketHistory()
        self:layout()   -- the kind chips of the bar (and with them the table) may have moved
        return
    end
    if kind == "browse" or kind == "mine" or kind == "candidates" then
        if kind == "browse" then
            self.marketAt = EC.now()
            self.browseBusy = nil
            -- an answer to a request the player has already moved past (the throttle window
            -- swallowed the newer one): keep the chips as they are and ask again
            local page = tonumber(args.page)
            if (args.sort ~= nil and args.sort ~= self.marketSort)
                or ((args.category or "") ~= (self.marketCat or ""))
                or (page ~= nil and page ~= self.marketPage) then
                self.browseWanted = true
            else
                self.marketPage = math.max(1, page or self.marketPage)
            end
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
            local listed = math.max(1, math.floor(tonumber(args.qty) or (pending and pending.qty) or 1))
            if listed > 1 then
                C.toast(getText(T .. "Market_ListedQty", name, tostring(listed), amountText(args.fee)))
            else
                C.toast(getText(T .. "Market_Listed", name, amountText(args.fee)))
            end
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
    elseif self.tab == "Auction" then
        self:onAuctionRefresh()
    end
end

-- ----- auction -----
-- The auction page mirrors the market one: a throttled browse (the server drops a second
-- command inside its 500 ms window), a busy flag that closes the header and the pager until
-- the answer lands, and one write in flight at a time (the market's `marketPending`, shared:
-- one window can only ever hold one dialog).

function Panel:updateAuctionInfo()
    local a, mine = C.auction, C.myAuctions
    local info = self.auctionInfo or {}
    info.taxPercent = tonumber(a and a.taxPercent) or 0
    info.feePercent = tonumber(a and a.feePercent) or 0
    info.minHours = math.max(1, tonumber(a and a.minHours) or 1)
    info.maxHours = math.max(info.minHours, tonumber(a and a.maxHours) or info.minHours)
    info.pages = math.max(1, tonumber(a and a.pages) or 1)
    info.total = tonumber(a and a.total) or 0
    info.maxAuctions = tonumber(mine and mine.maxAuctions) or tonumber(a and a.maxAuctions) or 0
    info.mine = (mine and mine.selling and #mine.selling) or tonumber(a and a.mine) or 0
    self.auctionInfo = info
    local b = self.auctionMineButton
    if b then
        local title = getText(T .. "Auction_Mine", tostring(info.mine), tostring(info.maxAuctions))
        if b.title ~= title then
            b:setTitle(title)
            b:setWidth(textWidth(title) + 22)
        end
    end
end

function Panel:sendAuctionBrowse()
    self.auctionWanted = nil
    self.auctionSentAt = EC.now()
    C.requestAuctions({ query = self.auctionQuery, sort = self.auctionSort, page = self.auctionPage })
end

function Panel:requestAuctionBrowse(page)
    self.auctionPage = math.max(1, tonumber(page) or 1)
    self.auctionQueryAt = nil
    self.auctionBusy = true
    self.auctionBusyAt = EC.now()
    if self.auctionSentAt and EC.now() - self.auctionSentAt < BROWSE_MIN_MS then
        self.auctionWanted = true
        return
    end
    self:sendAuctionBrowse()
end

-- ----- auction history -----
-- Debounce typing and keep one file read in flight. A newer query waits for that read to finish
-- instead of receiving busy and discarding the only successful answer. Only the latest queued
-- query is sent next; explicit server errors remain visible rather than retried in a loop.
local HISTORY_DEBOUNCE_MS = 650

function Panel:sendAuctionHistory()
    self.auctionHistoryWanted = nil
    self.auctionHistoryQueryAt = nil
    self.auctionHistoryError = nil
    self.auctionHistorySentAt = EC.now()
    -- a pinned auction is an exact lookup: the box only holds its id so the player can see it
    local pinned = self.auctionHistoryId
    local id = C.requestAuctionHistory({ auctionId = pinned,
        query = (pinned == nil) and self.auctionHistoryQuery or nil })
    self.auctionHistorySentId = id
    self.auctionHistoryPending = { at = self.auctionHistorySentAt }
end

function Panel:requestAuctionHistory()
    self.auctionHistoryQueryAt = nil
    if self.auctionHistoryPending and EC.now() - self.auctionHistoryPending.at > TIMEOUT_MS then
        self.auctionHistoryPending = nil
    end
    if self.auctionHistoryPending
        or (self.auctionHistorySentAt and EC.now() - self.auctionHistorySentAt < HISTORY_DEBOUNCE_MS) then
        self.auctionHistoryWanted = true
        return
    end
    self:sendAuctionHistory()
end

-- Drop queued work when leaving, but remember the real in-flight reader until its reply or
-- timeout. Reopening must not submit a second job while that reader still owns the command.
function Panel:cancelAuctionHistory()
    self.auctionHistoryQueryAt = nil
    self.auctionHistoryWanted = nil
end

-- The reply is oldest first (the server appends); the filter bar sorts, filters and pages it
-- newest first, exactly the way the market ring is paged, and the whole snapshot stays in
-- auctionHistoryAll so a chip or a date keystroke costs no round trip.
function Panel:rebuildAuctionHistory()
    local snap = C.auctionHistory
    local src = (snap and snap.entries) or {}
    local rows = {}
    for i = #src, 1, -1 do
        rows[#rows + 1] = auctionHistoryRow(src[i], self.offsetMin)
    end
    self.auctionHistoryAll = rows
    local bar = self.auctionHistoryBar
    if bar:syncKinds(rows) and self.g then self:layout() end
    local page, pages, total
    rows, page, pages, total = EC.filterPage(rows, bar:opts("ts"))
    bar:setPage(page, pages, total)
    self.auctionHistoryRows = rows
    self.auctionHistoryList:setItems(rows)
end

-- Both the mode chips and a row's record chip land here: the mode, its chips, the open dialog
-- and the tables - never the search box, because the caller owns what the box asks next.
function Panel:switchAuctionMode(mode)
    self.auctionMode = mode
    for _, b in ipairs(self.auctionModeButtons) do b.active = b.internal == mode end
    self:closeMarketDialog()
    self:rebuildAuctions()
    if mode == "history" then self:rebuildAuctionHistory() end
    self:layout()
end

-- The record chip of one row: the page switches to the record mode and asks for that auction's
-- own timeline (a read: no terminal, no dialog and no cancel needed to look at it). The box
-- shows the pinned id, so the player sees what is pinned and drops it by typing over it.
function Panel:openAuctionHistory(auctionId)
    if auctionId == nil then return end
    self.auctionMode = "history"         -- set first: the box change below routes on the mode
    self.auctionQuery, self.auctionQueryAt = nil, nil
    self.auctionHistoryId = tostring(auctionId)
    self.auctionHistoryQuery = nil
    setPlaceholder(self.auctionEntry, getText(T .. "Auction_History_Search"))
    setEntryText(self.auctionEntry, self.auctionHistoryId)
    self.auctionHistoryQueryAt = nil     -- the box change must not queue a second, unpinned read
    self:switchAuctionMode("history")
    self:requestAuctionHistory()
end

function Panel:requestAuctionMode()
    if self.auctionMode == "mine" then
        C.requestMyAuctions()
    elseif self.auctionMode == "history" then
        self:requestAuctionHistory()
    else
        self:requestAuctionBrowse(self.auctionPage)
    end
end

-- The server matched the untranslated name; the localised one is the client's own job, the
-- way the market page filters its page a second time.
local function auctionMatch(row, query)
    if query == nil then return true end
    return string.find(string.lower(row.name), query, 1, true) ~= nil
        or (row.altName ~= nil and string.find(string.lower(row.altName), query, 1, true) ~= nil)
        or string.find(string.lower(tostring(row.item)), query, 1, true) ~= nil
        or string.find(string.lower(row.seller), query, 1, true) ~= nil
end

function Panel:rebuildAuctions()
    local currency = (C.auction and C.auction.currency) or EC.CURRENCY_ORDER[1]
    local src = (C.auction and C.auction.items) or {}
    local query = self.auctionQuery
    local rows = {}
    for _, it in ipairs(src) do
        local row = auctionRow(it, currency, "browse")
        if auctionMatch(row, query) then rows[#rows + 1] = row end
    end
    self.auctionNoMatch = #rows == 0 and #src > 0
    self.auctionRows = rows
    self.auctionList:setItems(rows)
    local selling, bidding = {}, {}
    for _, it in ipairs(C.myAuctions and C.myAuctions.selling or {}) do
        selling[#selling + 1] = auctionRow(it, currency, "selling")
    end
    for _, it in ipairs(C.myAuctions and C.myAuctions.bidding or {}) do
        bidding[#bidding + 1] = auctionRow(it, currency, "bidding")
    end
    self.auctionSellRows, self.auctionBidRows = selling, bidding
    self.auctionSellList:setItems(selling)
    self.auctionBidList:setItems(bidding)
end

-- The search box is shared by the browse and the record pages, so a mode change starts it empty
-- (and drops whatever the other page had queued): one box may only ever ask one question.
function Panel:onAuctionMode(button)
    if self.auctionMode == button.internal then return end
    self.auctionMode = button.internal   -- set first: the box change below routes on the mode
    self.auctionQuery, self.auctionHistoryQuery, self.auctionHistoryId = nil, nil, nil
    setPlaceholder(self.auctionEntry, getText(T .. (self.auctionMode == "history"
        and "Auction_History_Search" or "Market_Search")))
    setEntryText(self.auctionEntry, "")
    self.auctionQueryAt, self.auctionHistoryQueryAt = nil, nil
    self.auctionHistoryWanted = nil
    self:switchAuctionMode(button.internal)
    self:requestAuctionMode()
end

-- A click on the auction table header: the same column again flips the direction, a new one
-- starts ascending. Anything that is not a column falls back to the page default (the auctions
-- closest to their end first) — that is `ending`, not the market's `time`.
function Panel:onAuctionHeader(x)
    if self.auctionMode ~= "browse" or self.auctionBusy then return end
    local key = "ending"
    for _, c in ipairs(self.auctionHeaderHits or {}) do
        if x >= c.x and x < c.x + c.w then key = c.key end
    end
    if self.auctionSort == key then key = key .. "_desc" end
    if key == self.auctionSort then return end
    self.auctionSort = key
    self:requestAuctionBrowse(1)
end

function Panel:onAuctionSearch()
    local raw = string.match(entryText(self.auctionEntry), "^%s*(.-)%s*$")
    if self.auctionMode == "history" then
        -- the pinned auction stays pinned only while the box still holds its id: the first
        -- keystroke that changes the text turns the lookup back into a free search
        if self.auctionHistoryId ~= nil and raw ~= self.auctionHistoryId then
            self.auctionHistoryId = nil
        end
        self.auctionHistoryQuery = raw ~= "" and raw or nil     -- the server matches it, not us
        self.auctionHistoryQueryAt = EC.now() + HISTORY_DEBOUNCE_MS
        return
    end
    local query = string.lower(raw)
    self.auctionQuery = query ~= "" and query or nil
    self.auctionQueryAt = EC.now() + 600
    self:rebuildAuctions()
end

function Panel:onAuctionRefresh()
    self:requestAuctionMode()
end

function Panel:onAuctionPage(button)
    if self.auctionBusy then return end
    local page = self.auctionPage + button.internal
    if page < 1 or page > self.auctionInfo.pages then return end
    self:requestAuctionBrowse(page)
end

-- A row was clicked. The record chip is a read, so it answers before any of the trade gates;
-- browsing and the "bidding on" list then open the bid step, and an own auction may be pulled
-- back only while nobody has bid on it (the server refuses `has_bids` anyway).
function Panel:onAuctionRow(row, context)
    if not row then return end
    local cols = self.auctionList.cols
    local x = self.auctionClickX
    if cols.histX and x ~= nil and x >= cols.histX and x < cols.histX + cols.histW then
        self:openAuctionHistory(row.id)
        return
    end
    if self.marketDialog or self.marketPending or not self:tradeAllowed() then return end
    if context == "selling" then
        if row.bids == 0 then self:openMarketDialog("acancel", row) end
        return
    end
    if row.canBid then
        local dlg = self:openMarketDialog("bid", row)
        setEntryText(dlg.priceEntry, tostring(row.minNext))
    end
end

function Panel:onAuctionCreate()
    if self.marketDialog or self.marketPending or not self:tradeAllowed() then return end
    local info = self.auctionInfo
    if info.maxAuctions > 0 and info.mine >= info.maxAuctions then return end
    self:openMarketDialog("pick", nil, true)
end

function Panel:submitAuction(dlg)
    if self.marketPending then return end
    if not self:tradeAllowed() then
        dlg.message = marketError({ error = "not_at_terminal" })
        return
    end
    local mode = dlg.mode
    local pending = { requestId = C.newRequestId(), at = EC.now(), kind = mode }
    if mode == "bid" then
        local amount = dlg:priceValue()
        if amount == nil or amount < dlg.row.minNext then
            dlg.message = marketError({ error = "bid_too_low", min = dlg.row.minNext })
            return
        end
        dlg.message = nil
        pending.name, pending.amount = dlg.row.name, amount
        self.marketPending = pending
        C.bidAuction(dlg.row.id, amount, pending.requestId)
        return
    end
    if mode == "acancel" then
        dlg.message = nil
        pending.name = dlg.row.name
        self.marketPending = pending
        C.cancelAuction(dlg.row.id, pending.requestId)
        return
    end
    -- the create step: the price bounds are the picker's own (market.candidates quotes them)
    local info, aInfo = self.marketInfo, self.auctionInfo
    local price = dlg:priceValue()
    if price == nil or price < info.priceMin or (info.priceMax > 0 and price > info.priceMax) then
        dlg.message = getText(T .. "Market_Error_price_range", amountText(info.priceMin), amountText(info.priceMax))
        return
    end
    local hours = dlg.hours
    if hours == nil or hours < aInfo.minHours or hours > aInfo.maxHours then
        dlg.message = marketError({ error = "hours_range", min = aInfo.minHours, max = aInfo.maxHours })
        return
    end
    local count = dlg:lotCount()
    local qty = dlg:qtyValue()
    if qty == nil then
        dlg.message = getText(T .. "Market_QtyHint", tostring(count), tostring(count))
        return
    end
    local itemIds = {}
    for i = 1, qty do itemIds[i] = dlg.cand.itemIds[i] end
    dlg.message = nil
    pending.name, pending.qty, pending.price = dlg.cand.name, qty, price
    self.marketPending = pending
    C.createAuction(itemIds, price, hours, pending.requestId)
end

function Panel:onAuction(kind, args)
    if kind == "browse" or kind == "mine" then
        if kind == "browse" then
            self.auctionBusy = nil
            -- an answer to a request the player has already moved past (the throttle window
            -- swallowed the newer one): keep the state as it is and ask again
            local page = tonumber(args.page)
            if (args.sort ~= nil and args.sort ~= self.auctionSort)
                or (page ~= nil and page ~= self.auctionPage) then
                self.auctionWanted = true
            else
                self.auctionPage = math.max(1, page or self.auctionPage)
            end
        end
        self:updateAuctionInfo()
        self:rebuildAuctions()
        self:layout()   -- the mine counter's own width may have moved
        return
    end
    -- the record page: a read, never a write, so it answers on its own requestId. An answer to
    -- a question the player has already typed past is dropped (the newer one is still coming),
    -- a refusal keeps the snapshot on screen instead of pretending the record is empty, and a
    -- reply that arrives after its own timeout still repairs the page.
    if kind == "history" then
        if args.requestId ~= nil and self.auctionHistorySentId ~= nil
            and args.requestId ~= self.auctionHistorySentId then
            return
        end
        self.auctionHistoryPending = nil
        if self.auctionHistoryWanted and self.tab == "Auction" and self.auctionMode == "history" then return end
        if args.error then
            -- a read has its own refusals: the file that could not be read, and the two "come
            -- back in a moment" codes the admin pages already word (busy / server_busy)
            self.auctionHistoryError = (args.error == "read_failed"
                and getText(T .. "Auction_History_ReadFailed"))
                or getTextOrNull(T .. "Admin_Error_" .. tostring(args.error))
                or marketError(args)
        else
            self.auctionHistoryError = nil
            self.auctionHistoryTruncated = args.truncated == true
            self:rebuildAuctionHistory()
        end
        self:layout()   -- the kind chips of the bar (and with them the table) may have moved
        return
    end
    -- a write answer: only the one this page is waiting for
    self:updateMailTab(args.unclaimed)
    local pending = self.marketPending
    if pending and args.requestId ~= nil and args.requestId ~= pending.requestId then return end
    self.marketPending = nil
    self:updateAuctionInfo()
    self:rebuildAuctions()
    if args.ok then
        local name = (pending and pending.name) or ""
        self:closeMarketDialog()
        if kind == "bid" then
            C.toast(getText(T .. "Auction_Placed", amountText(args.amount), name))
            self:requestAuctionMode()
        elseif kind == "create" then
            C.toast(getText(T .. "Auction_Created", name,
                amountText(pending and pending.price), amountText(args.fee)))
            self:setAuctionMode("mine")
        else
            C.toast(getText(T .. "Auction_Cancelled"))
            if args.delivered == false then C.toast(getText(T .. "Shop_Parked")) end
        end
        self:layout()
        return
    end
    self:marketMessage(marketError(args))
end

-- The create step lands the player on their own auctions: the row they just made is there.
function Panel:setAuctionMode(mode)
    if self.auctionMode ~= mode then
        self.auctionMode = mode
        for _, b in ipairs(self.auctionModeButtons) do b.active = b.internal == mode end
    end
    self:requestAuctionMode()
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

    -- opacity group, right to left: the percent readout, "+", the track, "-"; it shares the
    -- title row with the reset chip and collapses with the window
    local barVisible = not self.isCollapsed
    local opacityY = math.floor((th - self.opacitySlider.height) / 2)
    g.opacityR = (rb:getIsVisible() and rb.x or (w - 1 - (th - 2))) - 6
    g.opacityTextY = math.floor((th - fontH.small) / 2)
    local plus, minus = self.opacityPlusButton, self.opacityMinusButton
    for _, el in ipairs({ plus, minus, self.opacitySlider }) do
        el:setVisible(barVisible)
        el:setY(el == self.opacitySlider and opacityY or math.floor((th - el.height) / 2))
    end
    plus:setX(g.opacityR - textWidth("100%") - 6 - plus.width)
    self.opacitySlider:setX(plus.x - 4 - self.opacitySlider.width)
    minus:setX(self.opacitySlider.x - 4 - minus.width)
    local gearBtn = self.prefsButton
    gearBtn:setVisible(barVisible)
    gearBtn:setX(minus.x - 8 - gearBtn.width)
    gearBtn:setY(math.floor((th - gearBtn.height) / 2))
    local pop = self.prefsPopover
    pop:setX(math.max(PAD, math.min(w - PAD - pop.width, gearBtn.x + gearBtn.width - pop.width)))
    pop:setY(th + 2)
    if self.isCollapsed then pop:setVisible(false) end

    local isWallet = self.tab == "Wallet"
    self.adminAccess = C.AdminPanel.canRead()
    -- seven tabs at the full TAB_W would run past the tab strip on the narrowest window the
    -- player may resize to, so the width is the strip's own share when it has to be
    local tabCount = self.adminAccess and #self.tabButtons or (#self.tabButtons - 1)
    local tabW = math.min(TAB_W, math.floor((w - PAD * 2) / math.max(1, tabCount)))
    local x = PAD
    for _, b in ipairs(self.tabButtons) do
        local visible = b.internal ~= "Admin" or self.adminAccess
        b:setVisible(visible)
        if visible then
            b:setWidth(tabW)
            b:setX(x)
            b:setY(g.tabsY)
            x = x + tabW
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

    -- wallet: period chips, the filter bar, then the statement table inside the right card
    local chipY = g.contentY + CARD_TITLE_H + 4
    x = g.rightX + PAD + textWidth(getText(T .. "Wallet_Period")) + PAD
    for _, b in ipairs(self.periodButtons) do
        b:setVisible(isWallet)
        b:setX(x); b:setY(chipY)
        x = x + b.width + 6
    end
    g.tableHeaderY = self.walletBar:layout(g.rightX + PAD, chipY + CHIP_H + 6,
        g.rightX + g.rightW - PAD, isWallet) + 6
    local listY = g.tableHeaderY + ROW
    local listX = g.rightX + 1
    local listW = g.rightW - 2
    -- two rows are kept under the table: the pager, then the note line
    local listH = math.max(ROW * 2, g.contentY + g.contentH - listY - ROW * 2 - 2)
    self.list:setVisible(isWallet)
    self.list:setX(listX); self.list:setY(listY)
    local listResized = self.list.width ~= listW or self.list.height ~= listH
    -- Columns are measured from the header/typical texts so the player's UI font scale cannot
    -- make them collide; the description column takes whatever is left (truncated at bind time).
    local cols = self.list.cols
    local inner = listW - 12 -- keep clear of the scrollbar
    local function colW(header, sample) return math.max(textWidth(getText(T .. header)), textWidth(sample)) + PAD * 2 end
    cols.time = PAD
    cols.kind = cols.time + colW("Wallet_Col_Time", U.STAMP_SAMPLE)
    cols.desc = cols.kind + colW("Wallet_Col_Kind", kindText("admin_adjust"))
    cols.status = inner - colW("Wallet_Col_Status", getText(T .. "Wallet_RolledBack")) + PAD
    cols.balanceR = cols.status - PAD
    cols.amountR = cols.balanceR - colW("Wallet_Col_Balance", "999,999,999")
    cols.descW = math.max(0, cols.amountR - colW("Wallet_Col_Amount", "+999,999 " .. C.currencyName(EC.CURRENCY_ORDER[1])) - cols.desc)
    if listResized then self.list:resize(listW, listH) end
    g.listBottom = listY + listH
    self.walletBar:layoutPager(listX + PAD, g.listBottom + 2, listX + listW - PAD, isWallet)
    g.walletNoteY = g.listBottom + 2 + ROW

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
    -- the sell chip (only painted on buyback rows) sits left of the buy chip; its width fits
    -- "Sell 1,000,000" so the columns never move when the faucet opens
    shopCols.sellW = textWidth(getText(T .. "Shop_Sell", "1,000,000")) + 16
    shopCols.sellX = math.max(shopCols.name, shopCols.buyX - 6 - shopCols.sellW)
    shopCols.remainR = shopCols.sellX - PAD
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
    mailCols.nameW = math.max(0, mailCols.timeR - textWidth(U.STAMP_SAMPLE) - PAD - mailCols.name)
    if self.mailList.width ~= mailListW or self.mailList.height ~= mailListH then
        self.mailList:resize(mailListW, mailListH)
    end

    -- market: a mode/refresh bar over the page. Browsing keeps the shop's two-card split
    -- (filters left, listings right) and adds the pager strip under the table; the own-listings
    -- and history pages have nothing to filter, so they take one card across the whole width.
    local isMarket = self.tab == "Market"
    local mineMode = self.marketMode == "mine"
    local historyMode = self.marketMode == "history"
    local wideMode = mineMode or historyMode
    local browseMode = isMarket and not wideMode
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

    g.marketCardX = wideMode and g.leftX or g.rightX
    g.marketCardW = wideMode and (w - PAD * 2) or g.rightW
    g.marketHeaderY = g.marketCardY + CARD_TITLE_H + ROW
    local mktListY = g.marketHeaderY + ROW
    local mktFooterH = mineMode and 0 or ROW
    local mktListW = g.marketCardW - 2
    local mktListH = math.max(ROW * 2, g.marketCardY + g.marketCardH - mktListY - PAD - mktFooterH)
    self.marketList:setVisible(isMarket and not historyMode)
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
        - math.max(textWidth(getText(T .. "Market_Col_Expires")), textWidth(U.STAMP_SAMPLE)) - PAD)
    -- The lot column is the narrow one between the name and the seller (a count, never a name).
    local qtyW = math.max(textWidth(getText(T .. "Market_Col_Qty")), textWidth("999"))
    -- Reserve eight characters for the item name before allocating the seller column. The
    -- seller still needs its header width, so very tight layouts may borrow from that reserve.
    local sellerRoom = mktCols.priceR - COIN_SMALL - 4 - textWidth("999,999") - PAD
        - (mktCols.name + qtyW + PAD + textWidth("mmmmmmmm"))
    mktCols.sellerW = math.max(textWidth(getText(T .. "Market_Col_Seller")),
        math.min(textWidth("mmmmmmmm"), sellerRoom))
    mktCols.sellerX = math.max(mktCols.name, mktCols.priceR - COIN_SMALL - 4 - textWidth("999,999") - PAD - mktCols.sellerW)
    mktCols.qtyR = math.max(mktCols.name + qtyW, mktCols.sellerX - PAD)
    mktCols.nameW = math.max(0, mktCols.qtyR - qtyW - PAD - mktCols.name)
    if self.marketList.width ~= mktListW or self.marketList.height ~= mktListH then
        self.marketList:resize(mktListW, mktListH)
    end

    -- the sortable header sits over the header row of the listing table and hit-tests against
    -- these very column edges (paint and click can never disagree)
    self.marketHeaderHits = {
        { key = "name", title = getText(T .. "Market_Col_Item"), x = mktCols.name,
          w = math.max(0, mktCols.qtyR - qtyW - mktCols.name) },
        { key = "qty", title = getText(T .. "Market_Col_Qty"), x = mktCols.qtyR - qtyW,
          w = qtyW, right = true },
        { key = "seller", title = getText(T .. "Market_Col_Seller"), x = mktCols.sellerX,
          w = mktCols.sellerW },
        { key = "price", title = getText(T .. "Market_Col_Price"),
          x = mktCols.sellerX + mktCols.sellerW, w = mktCols.priceR - mktCols.sellerX - mktCols.sellerW,
          right = true },
        { key = "expires", title = getText(T .. "Market_Col_Expires"), x = mktCols.priceR,
          w = mktCols.expiresR - mktCols.priceR, right = true },
    }
    local header = self.marketHeader
    header:setVisible(isMarket and not historyMode)
    header:setX(self.marketList.x); header:setY(g.marketHeaderY)
    header:setWidth(mktListW); header:setHeight(ROW)

    -- history: the same card with the filter bar under the note line, two lines per row, no
    -- icon column (kind, item, amount, status) and the bar's own pager under the table
    local hist = self.marketHistoryList
    hist:setVisible(isMarket and historyMode)
    local histY = self.historyBar:layout(g.marketCardX + PAD, g.marketHeaderY,
        g.marketCardX + g.marketCardW - PAD, isMarket and historyMode) + 6
    local histH = math.max(ROW * 2, g.marketCardY + g.marketCardH - histY - PAD - ROW)
    hist:setX(g.marketCardX + 1); hist:setY(histY)
    local hCols = hist.cols
    local hInner = mktListW - 12
    local kindW = 0
    for _, k in ipairs(HISTORY_KINDS) do
        kindW = math.max(kindW, textWidth(getTextOrNull(T .. "Market_Kind_" .. k) or k))
    end
    hCols.kind = PAD
    hCols.name = hCols.kind + kindW + PAD
    hCols.status = math.max(hCols.name, hInner - textWidth(getText(T .. "Wallet_RolledBack")) - PAD)
    hCols.amountR = hCols.status - PAD
    hCols.nameW = math.max(0, hCols.amountR - textWidth("-999,999") - PAD - hCols.name)
    if hist.width ~= mktListW or hist.height ~= histH then hist:resize(mktListW, histH) end
    g.historyFooterY = histY + histH + 2
    self.historyBar:layoutPager(g.marketCardX + PAD, g.historyFooterY,
        g.marketCardX + g.marketCardW - PAD, isMarket and historyMode)

    -- browse pager: the server's own paging, under the listing table
    g.marketFooterY = mktListY + mktListH + 2
    local pageW = textWidth(getText(T .. "Market_Page", "99", "99"))
    x = g.marketCardX + PAD + pageW + PAD
    for _, b in ipairs({ self.marketPrevButton, self.marketNextButton }) do
        b:setVisible(browseMode)
        b:setX(x); b:setY(g.marketFooterY + math.floor((ROW - CHIP_H) / 2))
        x = x + b.width + 6
    end
    -- auction: the same mode bar over one card that always spans the window. Browsing is a
    -- sortable table with the server's pager under it; "my auctions" splits the card into the
    -- two lists (what the player sells, what they bid on), and the record page swaps the whole
    -- table for the two-line history list with its own filter bar. All three item tables read
    -- one column set (they are the same width), so the numbers below are computed once.
    local isAuction = self.tab == "Auction"
    local aucMine = self.auctionMode == "mine"
    local aucHistory = self.auctionMode == "history"
    local aucTable = isAuction and not aucMine and not aucHistory
    local aucBarH = math.max(CHIP_H, self.auctionEntry.height)
    g.auctionBarY = g.contentY
    g.auctionCardY = g.contentY + aucBarH + PAD
    g.auctionCardH = math.max(CARD_TITLE_H + ROW * 3, g.contentH - aucBarH - PAD)
    g.auctionCardX, g.auctionCardW = g.leftX, w - PAD * 2
    x = PAD
    for _, b in ipairs(self.auctionModeButtons) do
        b:setVisible(isAuction)
        b:setX(x); b:setY(g.auctionBarY + math.floor((aucBarH - CHIP_H) / 2))
        x = x + b.width + 6
    end
    for _, b in ipairs({ self.auctionRefreshButton, self.auctionCreateButton }) do
        b:setVisible(isAuction)
        b:setY(g.auctionBarY + math.floor((aucBarH - CHIP_H) / 2))
    end
    self.auctionRefreshButton:setX(w - PAD - self.auctionRefreshButton.width)
    self.auctionCreateButton:setX(self.auctionRefreshButton.x - 6 - self.auctionCreateButton.width)
    self.auctionEntry:setVisible(isAuction and not aucMine)
    self.auctionEntry:setWidth(math.max(120, math.min(240, self.auctionCreateButton.x - 12 - x)))
    self.auctionEntry:setX(self.auctionCreateButton.x - 12 - self.auctionEntry.width)
    self.auctionEntry:setY(g.auctionBarY + math.floor((aucBarH - self.auctionEntry.height) / 2))

    local aucListW = g.auctionCardW - 2
    local aCols = self.auctionList.cols
    aCols.icon = PAD
    aCols.name = PAD + ITEM_ICON + PAD
    aCols.qtyR, aCols.sellerX, aCols.sellerW = nil, nil, nil   -- both live in the name block
    aCols.actionW = math.max(textWidth(getText(T .. "Auction_Bid")), textWidth(getText(T .. "Auction_Own")),
        textWidth(getText(T .. "Auction_Leading")), textWidth(getText(T .. "Auction_Outbid")),
        textWidth(getText(T .. "Auction_Ended")), textWidth(getText(T .. "Auction_CancelTitle"))) + 22
    aCols.actionX = math.max(aCols.name, aucListW - 12 - aCols.actionW - PAD)
    -- the record chip lives left of the action one on every auction row (browse and mine alike):
    -- one column set, so the paint and Panel:onAuctionRow can never disagree about where it is
    aCols.histLabel = getText(T .. "Auction_History")
    aCols.histW = textWidth(aCols.histLabel) + 22
    aCols.histX = math.max(aCols.name, aCols.actionX - 6 - aCols.histW)
    aCols.expiresR = aCols.histX - PAD
    aCols.bidsR = math.max(aCols.name + PAD, aCols.expiresR - PAD
        - math.max(textWidth(getText(T .. "Auction_Col_Ends")),
            textWidth(getText(T .. "Auction_Ends_In", getText(T .. "Time_HM", "99", "59")))))
    aCols.priceR = math.max(aCols.name + PAD, aCols.bidsR - PAD
        - math.max(textWidth(getText(T .. "Auction_Col_Bids")), textWidth(getText(T .. "Auction_NoBids"))))
    aCols.nameW = math.max(0, aCols.priceR - COIN_SMALL - 4
        - textWidth(getText(T .. "Auction_StartsAt", "999,999")) - PAD - aCols.name)
    self.auctionHeaderHits = {
        { key = "name", title = getText(T .. "Market_Col_Item"), x = aCols.name, w = aCols.nameW },
        { key = "price", title = getText(T .. "Auction_Col_Bid"), x = aCols.name + aCols.nameW,
          w = aCols.priceR - aCols.name - aCols.nameW, right = true },
        { key = "bids", title = getText(T .. "Auction_Col_Bids"), x = aCols.priceR,
          w = aCols.bidsR - aCols.priceR, right = true },
        { key = "ending", title = getText(T .. "Auction_Col_Ends"), x = aCols.bidsR,
          w = aCols.expiresR - aCols.bidsR, right = true },
    }

    g.auctionHeaderY = g.auctionCardY + CARD_TITLE_H + ROW
    g.auctionListY = g.auctionHeaderY + ROW
    g.auctionFooterY = g.auctionCardY + g.auctionCardH - ROW
    self.auctionHeader:setVisible(aucTable)
    self.auctionHeader:setX(g.auctionCardX + 1); self.auctionHeader:setY(g.auctionHeaderY)
    self.auctionHeader:setWidth(aucListW); self.auctionHeader:setHeight(ROW)
    self.auctionList:setVisible(aucTable)
    self.auctionList:setX(g.auctionCardX + 1); self.auctionList:setY(g.auctionListY)
    if self.auctionList.width ~= aucListW or self.auctionList.height ~= math.max(ROW * 2, g.auctionFooterY - g.auctionListY - 2) then
        self.auctionList:resize(aucListW, math.max(ROW * 2, g.auctionFooterY - g.auctionListY - 2))
    end
    -- "my auctions": the selling half over the bidding half, one section label each
    g.aucSellLabelY = g.auctionCardY + CARD_TITLE_H + ROW
    g.aucSellY = g.aucSellLabelY + ROW
    g.aucSellH = math.max(ROW, math.floor((g.auctionCardY + g.auctionCardH - PAD - g.aucSellY - ROW) / 2))
    g.aucBidLabelY = g.aucSellY + g.aucSellH
    g.aucBidY = g.aucBidLabelY + ROW
    g.aucBidH = math.max(ROW, g.auctionCardY + g.auctionCardH - PAD - g.aucBidY)
    for _, spec in ipairs({ { self.auctionSellList, g.aucSellY, g.aucSellH },
        { self.auctionBidList, g.aucBidY, g.aucBidH } }) do
        spec[1]:setVisible(isAuction and aucMine)
        spec[1]:setX(g.auctionCardX + 1); spec[1]:setY(spec[2])
        if spec[1].width ~= aucListW or spec[1].height ~= spec[3] then spec[1]:resize(aucListW, spec[3]) end
    end
    -- the record page: the note line, the filter bar, the two-line list and the bar's own pager
    -- (the snapshot is paged on the client, exactly like the market ring)
    local ahist = self.auctionHistoryList
    ahist:setVisible(isAuction and aucHistory)
    local ahY = self.auctionHistoryBar:layout(g.auctionCardX + PAD, g.auctionHeaderY,
        g.auctionCardX + g.auctionCardW - PAD, isAuction and aucHistory) + 6
    local ahH = math.max(ROW * 2, g.auctionCardY + g.auctionCardH - ahY - PAD - ROW)
    ahist:setX(g.auctionCardX + 1); ahist:setY(ahY)
    local ahCols = ahist.cols
    local ahInner = aucListW - 12
    local aKindW = 0
    for _, k in ipairs(AUCTION_HISTORY_KINDS) do
        aKindW = math.max(aKindW, textWidth(getTextOrNull(T .. "Market_Kind_" .. k) or k))
    end
    ahCols.kind = PAD
    ahCols.name = ahCols.kind + aKindW + PAD
    ahCols.status = math.max(ahCols.name, ahInner - textWidth(getText(T .. "Wallet_RolledBack")) - PAD)
    ahCols.amountR = ahCols.status - PAD
    ahCols.nameW = math.max(0, ahCols.amountR - textWidth("999,999,999") - PAD - ahCols.name)
    if ahist.width ~= aucListW or ahist.height ~= ahH then ahist:resize(aucListW, ahH) end
    g.aucHistoryFooterY = ahY + ahH + 2
    self.auctionHistoryBar:layoutPager(g.auctionCardX + PAD, g.aucHistoryFooterY,
        g.auctionCardX + g.auctionCardW - PAD, isAuction and aucHistory)
    x = g.auctionCardX + PAD + textWidth(getText(T .. "Market_Page", "99", "99")) + PAD
    for _, b in ipairs({ self.auctionPrevButton, self.auctionNextButton }) do
        b:setVisible(aucTable)
        b:setX(x); b:setY(g.auctionFooterY + math.floor((ROW - CHIP_H) / 2))
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
    self.walletBar:draw(self)
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
    -- pager, then the footer note
    self.walletBar:drawPager(self, hx + PAD)
    local note
    local n = #self.list:getItems()
    local all = #(self.allRows or {})
    if n == 0 and all > 0 then
        note = getText(T .. "Filter_NoMatch")
    elseif self.period == "Recent" then
        if all == 0 then note = getText(T .. "Wallet_Empty") end
    elseif self.historyLoading then
        note = getText(T .. "Wallet_Loading")
    elseif self.historyError then
        note = getText(T .. "Rewards_Error_generic", tostring(self.historyError))
    elseif self.history then
        if all == 0 then
            note = getText(T .. "Wallet_Empty")
        elseif self.history.truncated then
            note = getText(T .. "Wallet_Truncated", tostring(all), tostring(self.history.total or all))
        end
    end
    if note then
        text(self, note, hx + PAD, g.walletNoteY + math.floor((ROW - fontH.small) / 2), "textMuted")
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
    text(self, getText(T .. "Rewards_NextDay", stampText(tonumber(st.nextResetMs) or 0, self.offsetMin), durationText(remain)), x + PAD, ly + 3, "textMuted")
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
    local note = getText(T .. "Shop_Note", C.currencyName(shop.currency))
    local noteToken = "textMuted"
    if shop.buyback and shop.buyback.enabled == true then
        if self.shopHasBuyback then
            note = getText(T .. "Shop_BuybackNote", amountText(shop.buyback.accountRemaining or 0)) .. "  " .. note
        else
            note = getText(T .. "Shop_BuybackNone")
        end
    elseif self.shopHasBuyback then
        note, noteToken = getText(T .. "Shop_BuybackPaused"), "warn"
    end
    text(self, fitText(note, g.rightW - PAD * 2), g.rightX + PAD, ty, noteToken)
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
    local usage = mail and mail.usage or nil
    local titleY = g.contentY + math.floor((CARD_TITLE_H - fontH.small) / 2)
    local rightX = x + w - PAD
    if usage and tonumber(usage.capacity) then
        -- slots: unclaimed entries + active listings out of the sandbox capacity
        local used = (tonumber(usage.unclaimed) or 0) + (tonumber(usage.listings) or 0)
        local cap = tonumber(usage.capacity) or 0
        local capText = getText(T .. "Mail_Capacity", tostring(used), tostring(cap))
        textRight(self, capText, rightX, titleY, used >= cap and "negative" or "textMuted")
        rightX = rightX - textWidth(capText) - PAD
    end
    textRight(self, getText(T .. "Mail_Count", tostring(unclaimed)), rightX, titleY, unclaimed > 0 and "accent" or "textMuted")
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

-- History page: one card, the note line, the filter bar and the ring (newest first by default).
-- No column header (the kind label already names each line); the ring is paged on the client,
-- so the pager under the table is the bar's own.
function Panel:drawMarketHistory()
    local g = self.g
    local list = self.marketHistoryList
    card(self, g.marketCardX, g.marketCardY, g.marketCardW, g.marketCardH, getText(T .. "Market_History_Title"))
    local ty = g.marketCardY + CARD_TITLE_H + math.floor((ROW - fontH.small) / 2)
    local noteW = g.marketCardW - PAD * 2
    if self.marketHistoryError then
        text(self, fitText(self.marketHistoryError, noteW), g.marketCardX + PAD, ty, "errorText")
        return
    end
    if not C.marketHistory then
        text(self, getText(T .. "Wallet_Loading"), g.marketCardX + PAD, ty, "textMuted")
        return
    end
    text(self, fitText(getText(T .. "Market_History_Note"), noteW), g.marketCardX + PAD, ty, "textMuted")
    self.historyBar:draw(self)
    self.historyBar:drawPager(self, g.marketCardX + PAD)
    if #list:getItems() == 0 then
        local all = #(self.marketHistoryAll or {})
        text(self, getText(T .. (all > 0 and "Filter_NoMatch" or "Market_History_Empty")), list.x + PAD,
            list.y + math.floor((ROW - fontH.small) / 2), "textMuted")
    end
end

function Panel:drawMarket()
    local g = self.g
    local mine = self.marketMode == "mine"
    local info = self.marketInfo
    if self.marketMode == "history" then return self:drawMarketHistory() end
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
    -- the header row is a child (MarketHeader): it paints the column names and takes the clicks
    if #self.marketList:getItems() == 0 then
        text(self, getText(T .. (self.marketNoMatch and "Market_NoMatch" or "Market_Empty")),
            self.marketList.x + PAD, self.marketList.y + math.floor((ROW - fontH.small) / 2), "textMuted")
    end
    if mine then return end
    -- pager strip: the page counter, the two chips (children), the server's total on the right
    local fy = g.marketFooterY + math.floor((ROW - fontH.small) / 2)
    text(self, getText(T .. "Market_Page", tostring(self.marketPage), tostring(info.pages)),
        g.marketCardX + PAD, fy, "textMuted")
    textRight(self, getText(T .. "Market_Total", tostring(info.total)),
        g.marketCardX + g.marketCardW - PAD, fy, "textMuted")
end

-- Record page: one card, one note line and the client-paged ring. The note line is the page's
-- whole state in one place, most urgent first: a refusal (the snapshot underneath stays on
-- screen - an error is not an empty record), the first read of all, the "only the newest 200"
-- warning, and otherwise the note that these amounts are bids and not wallet movements. A read
-- that is still in flight over a snapshot says so on the right, without hiding anything.
function Panel:drawAuctionHistory()
    local g = self.g
    local list = self.auctionHistoryList
    card(self, g.auctionCardX, g.auctionCardY, g.auctionCardW, g.auctionCardH,
        getText(T .. "Auction_History_Title"))
    local ty = g.auctionCardY + CARD_TITLE_H + math.floor((ROW - fontH.small) / 2)
    local noteW = g.auctionCardW - PAD * 2
    local pending = self.auctionHistoryPending ~= nil or self.auctionHistoryWanted == true
    local snap = C.auctionHistory
    if self.auctionHistoryError then
        text(self, fitText(self.auctionHistoryError, noteW), g.auctionCardX + PAD, ty, "errorText")
    elseif not snap then
        text(self, getText(T .. (pending and "Wallet_Loading" or "Auction_History_Empty")),
            g.auctionCardX + PAD, ty, "textMuted")
        return                       -- nothing read yet: no bar, no pager, no empty-filter line
    elseif self.auctionHistoryTruncated then
        text(self, fitText(getText(T .. "Auction_History_Truncated"), noteW), g.auctionCardX + PAD, ty, "warn")
    else
        text(self, fitText(getText(T .. "Auction_History_Note"), noteW), g.auctionCardX + PAD, ty, "textMuted")
    end
    if pending then
        textRight(self, getText(T .. "Wallet_Loading"), g.auctionCardX + g.auctionCardW - PAD, ty, "textMuted")
    end
    self.auctionHistoryBar:draw(self)
    self.auctionHistoryBar:drawPager(self, g.auctionCardX + PAD)
    if #list:getItems() == 0 then
        local all = #(self.auctionHistoryAll or {})
        text(self, getText(T .. (all > 0 and "Filter_NoMatch" or "Auction_History_Empty")), list.x + PAD,
            list.y + math.floor((ROW - fontH.small) / 2), "textMuted")
    end
end

-- Auction page: one card, the note line (the tax and the listing fee the server quoted), then
-- either the sortable browse table with its pager or the two "my auctions" sections.
function Panel:drawAuction()
    if self.auctionMode == "history" then return self:drawAuctionHistory() end
    local g = self.g
    local info = self.auctionInfo
    local mine = self.auctionMode == "mine"
    card(self, g.auctionCardX, g.auctionCardY, g.auctionCardW, g.auctionCardH, getText(T .. "Auction_Title"))
    local ty = g.auctionCardY + CARD_TITLE_H + math.floor((ROW - fontH.small) / 2)
    if (mine and not C.myAuctions) or (not mine and not C.auction) then
        text(self, getText(T .. "Wallet_Loading"), g.auctionCardX + PAD, ty, "textMuted")
        return
    end
    text(self, fitText(getText(T .. "Auction_Note", tostring(info.taxPercent), tostring(info.feePercent)),
        g.auctionCardW - PAD * 2), g.auctionCardX + PAD, ty, "textMuted")
    if mine then
        local labelX = g.auctionCardX + PAD
        text(self, getText(T .. "Auction_Mine", tostring(info.mine), tostring(info.maxAuctions)),
            labelX, g.aucSellLabelY + math.floor((ROW - fontH.small) / 2), "text")
        text(self, getText(T .. "Auction_Bidding"), labelX,
            g.aucBidLabelY + math.floor((ROW - fontH.small) / 2), "text")
        if #self.auctionSellList:getItems() == 0 and #self.auctionBidList:getItems() == 0 then
            text(self, getText(T .. "Auction_MineEmpty"), labelX,
                g.aucSellY + math.floor((ROW - fontH.small) / 2), "textMuted")
        end
        return
    end
    -- the header row is a child (MarketHeader): it paints the column names and takes the clicks
    if #self.auctionList:getItems() == 0 then
        text(self, getText(T .. (self.auctionNoMatch and "Market_NoMatch" or "Auction_Empty")),
            self.auctionList.x + PAD, self.auctionList.y + math.floor((ROW - fontH.small) / 2), "textMuted")
    end
    local fy = g.auctionFooterY + math.floor((ROW - fontH.small) / 2)
    text(self, getText(T .. "Market_Page", tostring(self.auctionPage), tostring(info.pages)),
        g.auctionCardX + PAD, fy, "textMuted")
    textRight(self, getText(T .. "Market_Total", tostring(info.total)),
        g.auctionCardX + g.auctionCardW - PAD, fy, "textMuted")
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
    -- a browse the 500 ms server throttle would have eaten: send the newest chip state now
    if self.browseWanted and EC.now() - (self.browseSentAt or 0) >= BROWSE_MIN_MS then
        self:sendBrowse()
    end
    -- a browse whose answer never came: the sort chips, the header and the pager come back
    if self.browseBusy and EC.now() - (self.browseBusyAt or 0) > BROWSE_TIMEOUT_MS then
        self.browseBusy = nil
    end
    -- the auction page runs the same three gates on its own state
    if self.auctionQueryAt and EC.now() >= self.auctionQueryAt and self.tab == "Auction" then
        self:requestAuctionBrowse(1)
    end
    if self.auctionWanted and EC.now() - (self.auctionSentAt or 0) >= BROWSE_MIN_MS then
        self:sendAuctionBrowse()
    end
    if self.auctionBusy and EC.now() - (self.auctionBusyAt or 0) > BROWSE_TIMEOUT_MS then
        self.auctionBusy = nil
    end
    -- the record page: the typed query goes out once the player stops, a read the throttle
    -- window would have eaten goes out as soon as it may, and a read that never came back gives
    -- the page an error instead of a spinner that never ends (the next read repairs it)
    if self.auctionHistoryQueryAt and EC.now() >= self.auctionHistoryQueryAt
        and self.tab == "Auction" and self.auctionMode == "history" then
        self:requestAuctionHistory()
    end
    if self.auctionHistoryWanted and not self.auctionHistoryPending
        and self.tab == "Auction" and self.auctionMode == "history"
        and EC.now() - (self.auctionHistorySentAt or 0) >= HISTORY_DEBOUNCE_MS then
        self:sendAuctionHistory()
    end
    if self.auctionHistoryPending and EC.now() - self.auctionHistoryPending.at > TIMEOUT_MS then
        self.auctionHistoryPending = nil
        self.auctionHistoryWanted = nil
        self.auctionHistoryError = shopError("timeout")
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
    -- the chrome opacity readout, next to its slider in the title row
    textRight(self, tostring(opacityPercent()) .. "%", g.opacityR, g.opacityTextY, "textMuted")
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
    local browseBusy = self.browseBusy == true
    for _, b in ipairs(self.marketSortButtons) do b:setEnable(not browseBusy) end
    for _, b in ipairs(self.marketCatButtons or {}) do b:setEnable(not browseBusy) end
    self.marketPrevButton:setEnable(self.marketPage > 1 and not browseBusy)
    self.marketNextButton:setEnable(self.marketPage < info.pages and not browseBusy)
    local aucInfo = self.auctionInfo
    local aucBusy = self.auctionBusy == true
    for _, l in ipairs({ self.auctionList, self.auctionSellList, self.auctionBidList }) do
        l.actionDisabled = gateClosed or self.marketPending ~= nil
    end
    self.auctionCreateButton:setEnable(not gateClosed and self.marketPending == nil and self.marketDialog == nil
        and (aucInfo.maxAuctions <= 0 or aucInfo.mine < aucInfo.maxAuctions))
    self.auctionPrevButton:setEnable(self.auctionPage > 1 and not aucBusy)
    self.auctionNextButton:setEnable(self.auctionPage < aucInfo.pages and not aucBusy)
    if self.tab == "Wallet" then
        self:drawWallet()
    elseif self.tab == "Rewards" then
        self:drawRewards()
    elseif self.tab == "Shop" then
        self:drawShop()
    elseif self.tab == "Market" then
        self:drawMarket()
    elseif self.tab == "Auction" then
        self:drawAuction()
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
    -- Pending mailbox count as a corner bubble on the Mail tab: painted here, after the tab
    -- buttons had their own render pass, so a hover fill cannot cover it.
    local mailTab = self.mailTabButton
    local unclaimed = math.floor(tonumber(C.unclaimed) or 0)
    if not self.isCollapsed and mailTab and unclaimed > 0 and mailTab:getIsVisible() then
        drawBadge(self, mailTab.x + mailTab.width - 2, mailTab.y + 2, unclaimed)
    end
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
    -- last, and after the stencil was cleared: the children were rendered between prerender and
    -- this call (UIElement.java:1626-1634), so the ring is painted over the control it marks
    Keys.render(self)
end

function Panel:close()
    self:setVisible(false)
end

function Panel:setVisible(visible)
    ISCollapsableWindow.setVisible(self, visible)
    self.shown = visible == true
    if not visible then self:showPrefs(false) end
    if self.adminPanel and not visible then self.adminPanel:setVisible(false) end
    if not visible then
        DatePicker.close()
        self:closeBuy()
        self:closeMarketDialog()
        self:unfocusEntries()
        self:cancelAuctionHistory()   -- a closed window asks the server for nothing
        Keys.clear(self)              -- no ring waiting behind a closed window
    end
    if visible then
        self.offsetMin = localOffsetMinutes()
        U.setAlpha(opacityPercent() / 100)   -- ModOptions may have changed it since the last open
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
    o.auctionMode = "browse"
    o.auctionSort = "ending"    -- the auctions closest to their end are the ones that matter
    o.auctionPage = 1
    o:initialise()
    -- UIManager offers key events to top-level UI that asked for them (UIManager.java:1435-1466);
    -- without this the window's four key hooks are never called
    o:setWantKeyEvents(true)
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
    DatePicker.close()
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
