-- Economy Center controls and row presentation shared by its window, dialogs and layout.
-- Owns cached item labels, row formatting, cells and geometry helpers; no window or requests.
require "ISUI/ISComboBox"
require "MinidoracatEconomy/ECWidgets"
require "MinidoracatEconomy/ECKeyboard"
require "MinidoracatEconomy/ECRowActions"
require "MinidoracatEconomy/ECItemNames"
local EC = MinidoracatEconomy
local C = EC.Client
local U = C.UI
local Keys = C.Keyboard
local R = C.RowActions
local Names = C.ItemNames
local W = {}
C.PanelWidgets = W

local PAD, ROW, CHIP_H, COIN_SMALL, T = U.PAD, U.ROW, U.CHIP_H, U.COIN_SMALL, U.T
local fontH = U.fontH
local color, fill, text, textWidth, fitText = U.color, U.fill, U.text, U.textWidth, U.fitText
local textRight, textCentre, strike, drawCoin = U.textRight, U.textCentre, U.strike, U.drawCoin
local stampText, durationText, amountText = U.stampText, U.durationText, U.amountText
local rowBackground = U.rowBackground

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

-- "Label: value", the line shape every reader in this window uses.
local function detailLine(key, value)
    return getText(T .. key) .. ": " .. tostring(value)
end

-- How tall `lines` becomes inside a reader `width` wide: the same wrap U.setWrappedText applies
-- (one line per wrapped part, at the small font), so a dialog can size its reader to its own
-- text before writing it. Layout only.
local function readerHeight(lines, width)
    local w, n = math.max(80, width - 20), 0
    for i = 1, #lines do
        local s = lines[i]
        if s == "" then n = n + 1 else n = n + #U.wrapText(s, w, math.huge) end
    end
    return n * fontH.small + 12
end

local function setSummary(dlg, lines)
    local box = dlg.summaryBox
    U.setWrappedText(box, table.concat(lines, "\n"), box.width)
end

-- The per-frame guard in front of that: no allocation and no string work while every value the
-- summary names is where it was. Cleared by nothing -- a layout writes the summary itself.
local function summaryMoved(dlg, a, b, c, d, e)
    if dlg.sumA == a and dlg.sumB == b and dlg.sumC == c and dlg.sumD == d and dlg.sumE == e then
        return false
    end
    dlg.sumA, dlg.sumB, dlg.sumC, dlg.sumD, dlg.sumE = a, b, c, d, e
    return true
end

-- One "label ... field" row: the field keeps the right edge and at most half the row, so a long
-- label at the largest UI font shrinks the field instead of painting over it. Returns the room
-- left for the label, which the paint fits its text into.
local function placeField(control, w, y, want)
    local width = math.max(60, math.min(want, math.floor((w - PAD * 3) / 2)))
    control:setWidth(width)
    control:setX(w - PAD - width)
    control:setY(y)
    return math.max(0, control.x - PAD * 2)
end

-- One box, two pages (the auction search and the record search): the hint follows the mode.
local function setPlaceholder(e, str)
    if not e or not e.setPlaceholderText then return end
    pcall(function() e:setPlaceholderText(str) end)
end

-- Item display: the localised engine name (getItemNameFromFullType, LuaManager.java:8579-8583)
-- and the item script's inventory texture (ScriptManager.instance:FindItem -> getNormalTexture;
-- a script may ship none). Both are cached per fullType: a catalog reply must not walk the
-- script list again, and neither call belongs in a per-frame paint.

local itemName = C.itemLabel

-- The item's real English name, from the mod's own EN dictionary plus every activated MOD's own
-- EN ItemName.json (C.ItemNames). Shown next to the localised name (and searched) so a player on
-- any language can find "Nails"; nil while the index has no English for this type, and nil when
-- English is the very string the localised name already is. The index loads in frames, so the
-- cache is dropped once its revision moves - the rows a page has already built pick the English
-- up on their next rebuild, and nothing is invented while the load is still running.
local itemBaseNames = {}
local baseRevision = -1
local function itemBaseName(fullType)
    -- the first row of the session starts the load; every later call is a plain state read
    Names.ensure()
    local revision = Names.revision or 0
    if revision ~= baseRevision then
        baseRevision = revision
        itemBaseNames = {}
    end
    local base = itemBaseNames[fullType]
    if base == nil then
        base = Names.english(fullType) or false
        itemBaseNames[fullType] = base
    end
    if not base or base == itemName(fullType) then return nil end
    return base
end

local itemTexture = U.itemTexture

local function drawIcon(el, tex, x, y, size)
    if tex then el:drawTextureScaled(tex, x, y, size, size, 1, 1, 1, 1) end
end

local function recoveryError(detail, recovery)
    if type(detail) ~= "table" or type(detail.reason) ~= "string" then return nil end
    local reason = getTextOrNull(T .. "Recovery_Reason_" .. detail.reason)
        or getTextOrNull(T .. "Admin_Rec_Reason_" .. detail.reason)
        or getText(T .. "Recovery_Reason_unavailable")
    local lines = { getText(T .. "Recovery_Refused", reason) }
    if type(detail.index) == "number" then
        lines[#lines + 1] = getText(T .. "Recovery_RefusedItem", tostring(detail.index))
    end
    if type(detail.mailId) == "string" then
        lines[#lines + 1] = getText(T .. "Recovery_SourceMail", detail.mailId)
    end
    if type(detail.opId) == "string" then
        lines[#lines + 1] = getText(T .. "Recovery_SourceOperation", detail.opId)
    end
    if type(detail.verdict) == "string" then
        local verdict = getTextOrNull(T .. "Admin_Rec_Verdict_" .. detail.verdict)
        if verdict then lines[#lines + 1] = getText(T .. "Recovery_SourceVerdict", verdict) end
    end
    local action = type(detail.action) == "string" and getTextOrNull(T .. "Recovery_Next_" .. detail.action)
    if action then lines[#lines + 1] = action end
    if detail.action == "wait_save" and type(recovery) == "table"
        and recovery.durableSource ~= "companion" then
        lines[#lines + 1] = getText(T .. "Recovery_NoWatermark")
    end
    return table.concat(lines, "\n")
end

-- shop.buy and mail.claim share one error key space (Shop_Error_<code>, timeout included)
local function shopError(code, recovery, detail)
    local explained = recoveryError(detail, recovery)
    if explained then return explained end
    if code == nil then code = "unknown" end
    if code == "recovery_pending" and type(recovery) == "table" then
        local open, maximum = tonumber(recovery.open), tonumber(recovery.max)
        if open and maximum and open >= maximum then
            local message = getText(T .. "Recovery_WaitingSave", tostring(open), tostring(maximum))
            if recovery.durableSource ~= "companion" then message = message .. "\n" .. getText(T .. "Recovery_NoWatermark") end
            return message
        end
    end
    return getTextOrNull(T .. "Shop_Error_" .. tostring(code)) or getText(T .. "Rewards_Error_generic", tostring(code))
end

-- market.* answers stack their own code space on top of the shop one: a listing error
-- (Market_Error_*), a whitelist refusal the picker also paints per row (Market_Reason_*),
-- then the shared codes (not_at_terminal, account_frozen, insufficient_funds, timeout...).
-- Takes the whole reply, not just the code: price_range/bid_too_low/hours_range carry bounds.
local function marketError(args)
    local code = tostring((args and args.error) or "unknown")
    local explained = recoveryError(args and args.recoveryDetail, args and args.recovery)
    if explained then return explained end
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
        or shopError(code, args and args.recovery)
end

-- A history read is a read, never a claim: wallet.history / market.history / auction.history all
-- answer with the same kind of refusal, and "領取失敗" (the reward claim's wording) is not what
-- happened. `read_failed` is the file read itself; busy / server_busy are the "come back in a
-- moment" codes the admin pages already word, and an unknown code is kept for a bug report.
-- Every one of them is retried by hand (Panel:onHistoryRetry), never in a loop.
local function historyError(code)
    local key = tostring(code == nil and "unknown" or code)
    if key == "read_failed" then return getText(T .. "History_ReadFailed") end
    return getTextOrNull(T .. "Admin_Error_" .. key) or getTextOrNull(T .. "Market_Error_" .. key)
        or getTextOrNull(T .. "Shop_Error_" .. key) or getText(T .. "History_ReadError", key)
end

-- The lines a buy confirmation spends on the room the player has, from C.deliveryPreview. It is
-- a client-side estimate over the item's own weight: the server re-checks it before it debits
-- anything, and an item whose weight this client does not know says so instead of quoting a
-- number it invented. Being over the encumbrance limit is not a refusal - carrying too much is
-- the player's own business - so only what the container cannot hold is ever mailed.
local function capacityLines(out, preview)
    if preview == nil then return out end
    if preview.known ~= true then
        out[#out + 1] = getText(T .. "Delivery_Unknown")
        return out
    end
    local qty = math.floor(tonumber(preview.qty) or 0)
    local fit = math.floor(tonumber(preview.fitQty) or 0)
    out[#out + 1] = detailLine("Delivery_Fits", getText(T .. "Delivery_FitsCount", tostring(fit), tostring(qty)))
    out[#out + 1] = detailLine("Delivery_Weight", getText(T .. "Delivery_WeightPair",
        string.format("%.1f", tonumber(preview.totalWeight) or 0),
        string.format("%.1f", tonumber(preview.freeCapacity) or 0)))
    local limit = tonumber(preview.encumbranceLimit)
    if limit ~= nil then
        out[#out + 1] = detailLine("Delivery_Carried", getText(T .. "Delivery_WeightPair",
            string.format("%.1f", tonumber(preview.carriedWeight) or 0), string.format("%.1f", limit)))
    end
    if preview.willMail == true then out[#out + 1] = getText(T .. "Delivery_WillMail") end
    return out
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

-- ---------- currencies ----------
-- The registered set in the server's own order. Every per-currency control, quote table and row
-- reads this one list: nothing here assumes the two built-in ids, and nothing picks "the first
-- currency a record happened to name".
local function currencyIds()
    local out = {}
    for _, cur in ipairs(C.currencies or {}) do
        if type(cur.id) == "string" and cur.id ~= "" then out[#out + 1] = cur.id end
    end
    if #out == 0 then
        for i = 1, #EC.CURRENCY_ORDER do out[i] = EC.CURRENCY_ORDER[i] end
    end
    return out
end

-- The currency a page starts on: survivor while it is registered, else the first registered one.
local function defaultCurrency()
    local ids = currencyIds()
    for _, want in ipairs(EC.CURRENCY_ORDER) do
        for _, id in ipairs(ids) do
            if id == want then return id end
        end
    end
    return ids[1]
end

-- A record without a currency is not silently read as the default one: it says it is unknown.
local function currencyLabel(id)
    if type(id) ~= "string" or id == "" then return getText(T .. "Market_CurrencyUnknown") end
    return C.currencyName(id)
end

-- An amount together with the currency it is in. nil is not zero: a quote that does not exist
-- says so instead of quoting a free item.
local function moneyText(amount, currency)
    local n = tonumber(amount)
    if n == nil then return getText(T .. "Shop_NoQuote") end
    return amountText(n) .. " " .. currencyLabel(currency)
end

-- The widest registered currency name: what a column or a sample is measured against.
local function currencySample()
    local widest = getText(T .. "Market_CurrencyUnknown")
    for _, id in ipairs(currencyIds()) do
        local name = currencyLabel(id)
        if textWidth(name) > textWidth(widest) then widest = name end
    end
    return widest
end

-- One sku's quote in one currency, or nil when that currency is not offered for it at all.
local function quoteOf(sku, currency)
    local prices = sku and sku.prices
    if type(prices) ~= "table" then return nil end
    local q = prices[currency]
    if type(q) ~= "table" then return nil end
    return q
end

-- One market row (browse page or own listings). `mine` is the page, `own` the seller test: the
-- browse page shows the player their own listing (so they see their price next to the others)
-- but offers Market_Own instead of a buy chip.
-- A lot of N identical items is one listing, and both listing tables carry a lot column of their
-- own, so the count is never repeated in the painted name (`Market_Lot` stays with the tables that
-- have no such column: the auction rows and the backpack picker).
local function lotText(qty)
    if qty <= 1 then return nil end
    return getText(T .. "Market_Lot", tostring(qty))
end

local function listingRow(it, username, offsetMin, mine)
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
    local currency = type(it.currency) == "string" and it.currency or nil
    -- A record the server cannot settle (its currency cannot be proven) is held, not priced at
    -- zero: buying it is off, the row says why, and pulling an own one back is still allowed.
    local blocked = type(it.blocked) == "string" and it.blocked ~= "" and it.blocked or nil
    return {
        id = it.id, item = it.item, seller = seller, price = price, currency = currency,
        currencyText = currencyLabel(currency), qty = qty,
        -- `nameText` is what the table paints (its lot column already carries the count); `lotName`
        -- is the one-line label a dialog needs, where there is no column to read the count from
        name = name, nameText = name, lotName = lot and (name .. " " .. lot) or name,
        altName = alt, texture = itemTexture(it.item),
        -- one item's own weight, as the server quoted it: the buy dialog's capacity estimate
        -- needs it, and an older reply that carries none must not be guessed at
        weight = tonumber(it.weight),
        statusText = listingStatus(it), priceText = amountText(price), expiresText = expiresText,
        own = own, mine = mine,
        blocked = blocked,
        -- the id of the one action button this row carries, or nil for a row that offers none
        -- (an own listing on the browse page, or a held one: the label is plain text instead)
        actionId = mine and "cancel" or ((not own and blocked == nil) and "buy" or nil),
        actionLabel = mine and getText(T .. "Market_Cancel")
            or (blocked and marketError({ error = blocked }))
            or (own and getText(T .. "Market_Own") or getText(T .. "Market_Buy")),
        actionToken = blocked and "warn" or nil,
    }
end

-- One auction row, painted by the very same ListingCell as a market listing. An auction runs
-- for hours, so the "ends" column is always a countdown; the current bid replaces the price
-- (an auction without a bid quotes its opening price instead) and the bid count is a column of
-- its own. That extra column costs the seller column: the seller shares the second line with
-- the condition/uses/fluid text, the way the buy dialog already names it.
-- `context` picks the action column: "browse" | "selling" | "bidding".
local function auctionRow(it, context)
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
    -- The action column: the one button this row offers the player, or - when there is nothing
    -- to press - the state of this auction for them as plain text. `actionId` is what the row
    -- button reports back (Panel:onAuctionAction); nil means no button at all.
    local canBid, label, token, off = false, nil, "textFaint", false
    local actionId, state = nil, nil
    if context == "selling" then
        -- an own auction may be pulled back only while nobody has bid on it (the server refuses
        -- `has_bids` too): the button stays on the row, disabled, so it still says why
        label, off, actionId = getText(T .. "Auction_CancelTitle"), bids > 0, "acancel"
    elseif context == "bidding" then
        -- the player is already in this auction: whether they lead is a state, and it belongs on
        -- the row's own second line - the button is the raise they may still press
        canBid = not ended
        state = leading and getText(T .. "Auction_Leading") or getText(T .. "Auction_Outbid")
        if canBid then
            label, actionId = getText(T .. "Auction_Raise"), "bid"
        else
            label, token = getText(T .. "Auction_Ended"), "warn"
        end
    elseif mine then
        label = getText(T .. "Auction_Own")
    elseif ended then
        label, token = getText(T .. "Auction_Ended"), "warn"
    elseif leading then
        label, token = getText(T .. "Auction_Leading"), "positive"
    else
        canBid, label, actionId = true, getText(T .. "Auction_Bid"), "bid"
    end
    -- An auction the server cannot settle (its currency cannot be proven, or the leading bid
    -- disagrees with it) is held: no bid may be placed on it, and the row says so instead of
    -- offering a price of zero. Pulling an own one back stays where it was.
    local blocked = type(it.blocked) == "string" and it.blocked ~= "" and it.blocked or nil
    if blocked and context ~= "selling" then
        canBid, actionId = false, nil
        label, token = marketError({ error = blocked }), "warn"
    end
    if state ~= nil then sub = sub and (sub .. " - " .. state) or state end
    return {
        id = it.id, item = it.item, seller = seller, qty = qty,
        currency = type(it.currency) == "string" and it.currency or nil,
        currencyText = currencyLabel(it.currency),
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
        blocked = blocked,
        actionId = actionId,
        actionLabel = label, actionToken = token, actionOff = off,
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

-- One catalog row, in the currency the page is trading in: every string the cell paints is built
-- here (they change with the snapshot, never per frame), `remaining` keeps the raw number the buy
-- dialog clamps its count with and `used` the count already spent against the cap (nil when the
-- snapshot carried none -- unknown, never 0). `buyback` is the snapshot's own buyback block, so
-- the per-currency switch and the shared unit quota are read from the server, never inferred
-- from a price.
--
-- A sku that is not quoted in this currency is not free and not zero: it has no price at all, its
-- buy button is closed and the row says so. The quotes it does carry are named on the second line,
-- so both prices are readable without switching the page first.
local function shopRow(it, currency, buyback)
    local cap = tonumber(it.dailyCap) or 0
    local remaining = tonumber(it.remaining)
    -- Three cap modes share this one column, and the scope is what says which sentence "used
    -- up" is: a per-day count (this account's or the whole server's) or one that never resets.
    -- An older snapshot carries no `used` count at all, and none is not zero.
    local scope = it.dailyCapScope
    scope = (scope == "global" or scope == "server") and "global"
        or (scope == "lifetime" and "lifetime" or "player")
    local used = tonumber(it.used)
    local remainText, remainToken, soldOut = getText(T .. "Shop_Unlimited"), "textMuted", false
    if cap > 0 then
        local left = remaining or cap
        soldOut = left <= 0
        remainText = soldOut
            and getText(T .. (scope == "lifetime" and "Shop_SoldOutLifetime" or "Shop_SoldOut"))
            or (tostring(left) .. " / " .. tostring(cap))
        remainToken = soldOut and "warn" or "text"
    end
    local qty = tonumber(it.qty) or 1
    local q = quoteOf(it, currency)
    local price = q and tonumber(q.price) or nil
    local hasQuote = price ~= nil and q.enabled ~= false
    local bid = q and tonumber(q.bidPrice) or nil
    -- the buyback of this currency: the sku's own direction switch, the server-wide switch and
    -- this currency's own cap block all have to be open
    local byCurrency = (type(buyback) == "table" and type(buyback.byCurrency) == "table")
        and buyback.byCurrency[currency] or nil
    local canBuyback = q ~= nil and q.buyback == true and bid ~= nil
    local buybackOpen = canBuyback and type(buyback) == "table" and buyback.enabled == true
        and byCurrency ~= nil and byCurrency.enabled == true
    -- every other currency this sku quotes, named on the second line
    local alt, quotes = {}, {}
    for _, id in ipairs(currencyIds()) do
        local other = quoteOf(it, id)
        local otherPrice = other and tonumber(other.price) or nil
        if otherPrice ~= nil then
            quotes[#quotes + 1] = { currency = id, price = otherPrice,
                bidPrice = tonumber(other.bidPrice), enabled = other.enabled ~= false,
                buyback = other.buyback == true }
            if id ~= currency and other.enabled ~= false then
                alt[#alt + 1] = currencyLabel(id) .. " " .. amountText(otherPrice)
            end
        end
    end
    local qtyText = getText(T .. "Shop_QtyPer", tostring(qty))
    -- a cap that never resets is the unusual one, and the numeric column has no room to say so:
    -- the row names it on the same line the lot size is read on
    if cap > 0 and scope == "lifetime" then
        qtyText = qtyText .. "   " .. getText(T .. "Shop_Scope_lifetime")
    end
    if #alt > 0 then qtyText = qtyText .. "   " .. getText(T .. "Shop_AltQuote", table.concat(alt, "  ")) end
    return {
        id = it.id, item = it.item, qty = qty, price = price, hasQuote = hasQuote,
        dailyCap = cap, dailyCapScope = scope,
        -- whose count this cap is, and how much of it this account has spent: the detail window
        -- and the buy dialog both read these, so the sentence is built once
        capScopeText = getText(T .. "Shop_Scope_" .. scope),
        usedText = used ~= nil and tostring(math.floor(used))
            or getText(T .. "Shop_NoQuote"),
        remaining = remaining, soldOut = soldOut, currency = currency,
        currencyText = currencyLabel(currency), quotes = quotes,
        name = itemName(it.item), altName = itemBaseName(it.item), texture = itemTexture(it.item),
        qtyText = qtyText,
        -- one item's own weight as the catalog quoted it: what the buy dialog estimates the
        -- backpack room with. An older snapshot carries none, and none is not zero.
        weight = tonumber(it.weight),
        priceText = price ~= nil and amountText(price) or getText(T .. "Shop_NoQuote"),
        remainText = remainText, remainToken = remainToken,
        buyLabel = getText(T .. "Shop_Buy"),
        -- Keep the configured price visible while the server-wide switch pauses buyback.
        bidPrice = bid, buyback = canBuyback, buybackOpen = buybackOpen,
        buybackCap = tonumber(it.buybackCap) or 0, buybackRemaining = tonumber(it.buybackRemaining),
        sellLabel = getText(T .. "Shop_Sell", bid ~= nil and amountText(bid) or getText(T .. "Shop_NoQuote")),
    }
end

-- Shop row: icon + name over "N per lot", the unit price, the share the cap has left, and the two
-- real action buttons of the row (buy, and sell on a buyback sku). The row body itself only
-- selects and reads: ECRowActions owns those buttons, so a press is a press and never a
-- hit-tested area of the row. Column edges come from Panel:layout (list.cols) and
-- `list.buyDisabled` closes both buttons while the write gate is shut (frozen account, no
-- terminal within reach, a write in flight).
local ShopCell = ISPanel:derive("MinidoracatEconomyShopCell")

function ShopCell:render()
    local e = self.entry
    if not e then return end
    local cols = self.list.cols
    local h = self.height
    rowBackground(self)
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
    textRight(self, e.priceText, cols.priceR, ty, e.hasQuote and "accent" or "textFaint")
    local coinX = cols.priceR - textWidth(e.priceText) - COIN_SMALL - 4
    if e.hasQuote and coinX > cols.name + cols.nameW then
        drawCoin(self, e.currency, coinX, math.floor((h - COIN_SMALL) / 2), COIN_SMALL)
    end
    textRight(self, e.remainText, cols.remainR, ty, e.remainToken)
    local chipY, chipH = math.floor((h - CHIP_H) / 2), CHIP_H
    R.begin(self)
    if e.buyback then
        R.put(self, "sell", e.sellLabel, cols.sellX, chipY, cols.sellW, chipH,
            e.buybackOpen == true and self.list.buyDisabled ~= true and e.buybackRemaining ~= 0)
    end
    R.put(self, "buy", e.buyLabel, cols.buyX, chipY, cols.buyW, chipH,
        self.list.buyDisabled ~= true and not e.soldOut and e.hasQuote)
    R.finish(self)
end

-- Mailbox row: icon + name x count over its source, the timestamp, and the row's own claim
-- button. A click on the row body only reads it (reading a record must never take anything);
-- the button is the one claim path a single letter has, and the toolbar's own chip claims every
-- ready letter at once. Every listed letter is claimable: the server either delivers a letter,
-- leaves it exactly where it was, or splits off the part it confirmed into its own claimed
-- child - so a row is never a locked one and never a silently emptied one.
local MailCell = ISPanel:derive("MinidoracatEconomyMailCell")

function MailCell:render()
    local e = self.entry
    if not e then return end
    local cols = self.list.cols
    local h = self.height
    local lit = rowBackground(self)
    drawIcon(self, e.texture, cols.icon, math.floor((h - ITEM_ICON) / 2), ITEM_ICON)
    local half = math.floor(h / 2)
    local faint = lit and "text" or "textFaint"
    local nameText = fitText(e.nameText, cols.nameW)
    text(self, nameText, cols.name, half - fontH.small - 2, "text")
    if e.altName then
        local altX = cols.name + textWidth(nameText) + 8
        local altW = cols.name + cols.nameW - altX
        if altW > 20 then text(self, fitText(e.altName, altW), altX, half - fontH.small - 2, faint) end
    end
    text(self, fitText(e.fromText, cols.nameW), cols.name, half + 2, faint)
    textRight(self, e.timeText, cols.timeR, math.floor((h - fontH.small) / 2), faint)
    R.begin(self)
    R.put(self, "claim", e.claimLabel, cols.claimX, math.floor((h - CHIP_H) / 2), cols.claimW, CHIP_H,
        e.claimable == true and self.list.actionDisabled ~= true)
    R.finish(self)
end

-- Statement row (the wallet ledger): the six columns the header paints, plus the selection band
-- every table in this window carries. The picked row is what the full-value strip spells out, so a
-- keyboard user has to be able to see which row that is. The counterparty/note column is the one
-- that truncates, so its fitted text is cached per row and per column width instead of measured
-- again on every frame of every visible row.
local StatementCell = ISPanel:derive("MinidoracatEconomyPlayerStatementCell")

function StatementCell:render()
    local e = self.entry
    if not e then return end
    local cols = self.list.cols
    local h = self.height
    if self.descEntry ~= e or self.descBudget ~= cols.descW or self.timeBudget ~= cols.timeW then
        self.descEntry, self.descBudget, self.timeBudget = e, cols.descW, cols.timeW
        self.descText = fitText(e.desc, cols.descW or 0)
        self.timeText = cols.compact and fitText(e.time, cols.timeW) or e.time
    end
    local lit = rowBackground(self)
    local ty = math.floor((h - fontH.small) / 2)
    local muted = e.rolledBack
    -- The selection band and the hover fill are bright: on such a row the secondary text, the
    -- rolled-back text and a negative amount all move to the readable token instead of staying
    -- faint or red on light. The sign, the rollback words and the strike stay exactly where they
    -- were -- nothing here ever leans on colour alone.
    local tokenText = (muted and not lit) and "textFaint" or "text"
    local tokenMuted = lit and "text" or (muted and "textFaint" or "textMuted")
    local amountToken = muted and tokenText
        or ((e.amount >= 0 and "positive") or (lit and "text" or "negative"))
    if cols.compact then
        text(self, self.timeText, cols.time, ty, tokenMuted)
        local coinX = cols.amountR - textWidth(e.valueText) - COIN_SMALL - 6
        drawCoin(self, e.currency, coinX, math.floor((h - COIN_SMALL) / 2), COIN_SMALL)
        textRight(self, e.valueText, cols.amountR, ty, amountToken)
        if muted then strike(self, cols.time, ty, cols.amountR - cols.time) end
        return
    end
    text(self, e.time, cols.time, ty, tokenMuted)
    text(self, e.kindText, cols.kind, ty, tokenText)
    text(self, self.descText, cols.desc, ty, tokenMuted)
    textRight(self, e.amountText, cols.amountR, ty, amountToken)
    textRight(self, amountText(e.after), cols.balanceR, ty, tokenText)
    if muted then
        text(self, getText(T .. "Wallet_RolledBack"), cols.status, ty, lit and "text" or "textFaint")
        strike(self, cols.time, ty, cols.balanceR - cols.time)
    else
        text(self, "-", cols.status, ty, lit and "textMuted" or "textFaint")
    end
end


-- Market row: icon + name over the condition/uses/fluid line, the seller, the price, what is
-- left of the listing window, and the row's own action button (buy / cancel / bid / pull back).
-- The row body only selects and reads: ECRowActions owns those buttons, so there is no
-- hit-tested area of a row that spends money any more. `list.actionDisabled` closes every
-- button at once (frozen, no terminal in reach, a write in flight); a row that offers nothing
-- (an own listing on the browse page, an auction that ended) paints its state as plain text.
-- The auction tables share the cell: their `cols` drops the qty/seller columns (both live in
-- the name block), adds the bid-count one and adds the record button, so every column here is
-- painted only when the owning table asked for it.
local ListingCell = ISPanel:derive("MinidoracatEconomyListingCell")

function ListingCell:render()
    local e = self.entry
    if not e then return end
    local cols = self.list.cols
    local h = self.height
    rowBackground(self)
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
    -- Every value paints inside the column it belongs to (cols.<key>W is that slot): a strip
    -- that ran out of room -- a big font in a narrow window -- truncates here instead of
    -- letting two columns overlap, and the row's record window still spells it out in full.
    if cols.qtyR then
        textRight(self, fitText(tostring(e.qty), cols.qtyW), cols.qtyR, ty,
            e.qty > 1 and "accent" or "textFaint")
    end
    if cols.sellerX then
        text(self, fitText(e.seller, cols.sellerW), cols.sellerX, ty, "textMuted")
        rightOfName = cols.sellerX + cols.sellerW
    end
    local priceText = fitText(e.priceText, cols.priceW)
    textRight(self, priceText, cols.priceR, ty, "accent")
    local coinX = cols.priceR - textWidth(priceText) - COIN_SMALL - 4
    if coinX > rightOfName then
        drawCoin(self, e.currency, coinX, math.floor((h - COIN_SMALL) / 2), COIN_SMALL)
    end
    -- The currency of this very record, spelled out next to the coin: an icon alone cannot say
    -- which currency a mixed page is quoting, and a record that carries none says "unknown"
    -- instead of being read as the default one.
    if cols.curR then
        textRight(self, fitText(e.currencyText, cols.curW), cols.curR, ty,
            e.currency and "textMuted" or "warn")
    end
    if cols.bidsR then
        textRight(self, fitText(e.bidsText, cols.bidsW), cols.bidsR, ty, e.bidsToken or "textFaint")
    end
    if cols.wrapDate and string.match(e.expiresText, "^%d%d%d%d%-%d%d%-%d%d ") then
        textRight(self, string.sub(e.expiresText, 1, 10), cols.expiresR, half - fontH.small - 2, "textFaint")
        textRight(self, string.sub(e.expiresText, 12), cols.expiresR, half + 2, "textFaint")
    else
        textRight(self, fitText(e.expiresText, cols.expiresW), cols.expiresR, ty, e.expiresToken or "textFaint")
    end
    -- The record button of the auction tables, left of the action one: it opens this auction's
    -- own timeline. A record is a read, so the write gate (list.actionDisabled) never closes it.
    local chipY = math.floor((h - CHIP_H) / 2)
    R.begin(self)
    if cols.histX then
        R.put(self, "history", cols.histLabel, cols.histX, chipY, cols.histW, CHIP_H, true)
    end
    if e.actionId ~= nil then
        R.put(self, e.actionId, e.actionLabel, cols.actionX, chipY, cols.actionW, CHIP_H,
            self.list.actionDisabled ~= true and e.actionOff ~= true)
    else
        textCentre(self, e.actionLabel, cols.actionX + cols.actionW / 2, ty, e.actionToken or "textFaint")
    end
    R.finish(self)
end

-- Picker strip (list dialog): the picker is a grid, but VirtualList is a one-column list, so one
-- list row carries a whole strip of tiles (entry = the array of candidates on this line) and
-- paints them itself. Hit testing reads the same cols.tileW, so the click and the paint can never
-- disagree; hover comes from the list (cols.tileW + list.hoverIndex/hoverCol, resolved once per
-- frame by the dialog) instead of the cell's own mouse, which only knows the whole strip.
local function gridCandidate(list)
    local row = list:getSelectedIndex()
    local strip = row and list.items[row]
    return strip and strip[math.min(list.ecColumn or 1, #strip)] or nil
end

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
        if Keys.isKeyboardFocused(self.list) and self.list:isSelected(self.index)
            and i == math.min(self.list.ecColumn or 1, #tiles) then
            fill(self, x + 2, 2, tw - 4, th - 4, "selected")
            U.drawFocus(self, x + 6, 6, tw - 12, th - 12)
        end
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
-- winner paid) is negative, and everything else is the price as it stood. It is always named
-- with the currency the record itself was written in; a record that moved no money at all
-- (a listing that was pulled back, an expiry) keeps a dash instead of a zero.
local function historyRow(rec, offsetMin)
    local kind = tostring(rec.kind or "")
    local qty = math.max(1, math.floor(tonumber(rec.qty) or 1))
    local price = tonumber(rec.price)
    local amount = price
    if amount ~= nil then
        if kind == "sold" or kind == "auction_sold" then amount = price - (tonumber(rec.tax) or 0)
        elseif kind == "bought" or kind == "auction_bid" or kind == "auction_won" then amount = -price end
    end
    local name = itemName(rec.item)
    local lot = lotText(qty)
    local parts = { stampText(tonumber(rec.ts) or 0, offsetMin) }
    if type(rec.other) == "string" and rec.other ~= "" then
        parts[#parts + 1] = getText(T .. "Market_History_Other", rec.other)
    end
    if type(rec.reason) == "string" and rec.reason ~= "" then parts[#parts + 1] = rec.reason end
    local label = getTextOrNull(T .. "Market_Kind_" .. kind) or kind
    local detail = table.concat(parts, "  ")
    return {
        recordKey = U.recordKey(rec),
        kind = kind,
        ts = tonumber(rec.ts) or 0,           -- the filter bar pages/sorts on the raw numbers
        amount = amount or 0,                 -- the sort key; the painted value is below
        currency = type(rec.currency) == "string" and rec.currency or nil,
        kindText = label,
        kindToken = HISTORY_TOKENS[kind] or "text",
        nameText = lot and (name .. " " .. lot) or name,
        amountText = amount ~= nil and (amountText(amount) .. " " .. currencyLabel(rec.currency)) or "-",
        detailText = detail,
        rolledBack = rec.rolledBack == true,
        -- what the page's keyword box searches: the item (localised name and raw fullType), the
        -- kind, and the whole detail line -- which is where the counterparty and the reason are
        searchText = string.lower(table.concat({ name, tostring(rec.item or ""), label, detail }, " ")),
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
        recordKey = U.recordKey(rec),
        kind = kind,
        ts = tonumber(rec.ts) or 0,           -- the filter bar pages/sorts on the raw numbers
        amount = price or 0,
        kindText = getTextOrNull(T .. "Market_Kind_" .. kind) or kind,
        kindToken = HISTORY_TOKENS[kind] or "text",
        nameText = lot and (name .. " " .. lot) or name,
        currency = type(rec.currency) == "string" and rec.currency or nil,
        amountText = price and (amountText(price) .. " " .. currencyLabel(rec.currency)) or "-",
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
    local lit = rowBackground(self)
    local line = historyLine()
    local top = math.max(0, math.floor((h - line * 2) / 2))
    local muted = e.rolledBack
    -- the statement's rule, here too: on a selected or hovered row the faint texts read in the
    -- readable token, and the rollback words and the strike stay put
    local faint = lit and "text" or "textFaint"
    local kindToken = e.kindToken == "textFaint" and faint or e.kindToken
    text(self, e.kindText, cols.kind, top, muted and faint or kindToken)
    text(self, fitText(e.nameText, cols.nameW), cols.name, top, muted and faint or "text")
    textRight(self, e.amountText, cols.amountR, top, muted and faint or "accent")
    if muted then
        text(self, getText(T .. "Wallet_RolledBack"), cols.status, top, faint)
        strike(self, cols.kind, top, cols.amountR - cols.kind)
    end
    text(self, fitText(e.detailText, w - cols.kind - PAD), cols.kind, top + line, faint)
end


local ARROW_W, ARROW_H = 7, 4
-- A sortable column reserves this much of its right edge for the arrow, whether or not the sort
-- currently sits on it: a number that jumps sideways when the player sorts by it is unreadable.
local SORT_GUTTER = ARROW_W + 4
local function sortGutter(c) return (c.sortable ~= false) and SORT_GUTTER or 0 end

-- One strip of table columns, shared by the cells that paint the rows and by the sortable header
-- over them: an edge is computed once, so the two can never disagree about where a column is.
-- specs[1] is flexible. Other columns reserve their title/sample, padding and arrow separately;
-- deadline columns also measure the actual rows, since a zero-filled sample is not a widest date.
-- Each entry returns x / w (header hit area), textR and textW (value slot, gutter excluded).
--
-- The strip has a budget -- leftX to rightX, the row's action button starts there -- and it never
-- overruns it. What the measured columns cost over that budget is handed back in the order the
-- page can best afford: a sample-measured text column reads "..." (the seller), the coin beside a
-- price goes, a narrow market date wraps to two lines before any numeric column is touched (the
-- year is never cut), a `soft` column keeps its own title and nothing more, and only if even the
-- titles do not fit does every column shrink in proportion. Names and soft values may truncate;
-- money and the date keep their measured width while the budget allows, and the full value of
-- every column is in the row's record window.
local function listingColumns(specs, leftX, rightX, nameMin, rows, moreRows)
    local budget = math.max(0, rightX - leftX)
    local ellipsis = textWidth("...")
    -- the name column is what the table is about: a recognisable prefix, or at least its own title
    local nameFloor = math.max(ellipsis, textWidth(specs[1].title) + sortGutter(specs[1]))
    local used = 0
    for i = 2, #specs do
        local c = specs[i]
        local valueW = c.sample and textWidth(c.sample) or 0
        local dateW = c.key == "expires" and math.max(textWidth(string.sub(U.STAMP_SAMPLE, 1, 10)),
            textWidth(string.sub(U.STAMP_SAMPLE, 12))) or nil
        if c.key == "expires" or c.key == "ending" then
            local count = rows and #rows or 0
            local total = count + (moreRows and #moreRows or 0)
            for index = 1, total do
                local row = index <= count and rows[index] or moreRows[index - count]
                local value = row.expiresText
                if type(value) == "string" then
                    valueW = math.max(valueW, textWidth(value))
                    if dateW then
                        if string.match(value, "^%d%d%d%d%-%d%d%-%d%d ") then
                            dateW = math.max(dateW, textWidth(string.sub(value, 1, 10)),
                                textWidth(string.sub(value, 12)))
                        else
                            dateW = math.max(dateW, textWidth(value))
                        end
                    end
                end
            end
        end
        local gutter, titleW = sortGutter(c), textWidth(c.title)
        c.w = PAD + (c.extra or 0) + gutter + math.max(titleW, valueW)
        c.dateW = dateW and (PAD + gutter + math.max(titleW, dateW)) or nil
        used = used + c.w
    end
    local nameW = budget - used
    -- Give the name column back what `low(c)` says column c can spare, while it is under `want`.
    local function reclaim(want, low)
        for i = 2, #specs do
            if nameW >= want then return end
            local c = specs[i]
            local floor = low(c)
            if floor and floor < c.w then
                local take = math.min(want - nameW, c.w - floor)
                c.w, nameW, used = c.w - take, nameW + take, used - take
            end
        end
    end
    reclaim(nameMin, function(c) return (c.sample and not c.right) and (PAD + ellipsis) or nil end)
    reclaim(nameFloor, function(c) return c.extra and (c.w - c.extra) or nil end)
    for i = 2, #specs do
        local c = specs[i]
        if nameW < nameMin and c.dateW then
            local take = math.min(nameMin - nameW, math.max(0, c.w - c.dateW))
            c.w, nameW, used = c.w - take, nameW + take, used - take
            c.wrapDate = take > 0
        end
    end
    reclaim(nameFloor, function(c) return c.soft and (textWidth(c.title) + sortGutter(c)) or nil end)
    if nameW < nameFloor and used > 0 then
        local room, total = math.max(0, budget - nameFloor), used
        used = 0
        for i = 2, #specs do
            local c = specs[i]
            c.w = math.floor(c.w * room / total)
            c.wrapDate = false -- proportional fallback no longer guarantees the full date width
            used = used + c.w
        end
        nameW = budget - used
    end
    specs[1].x, specs[1].w = leftX, math.max(0, nameW)
    local x = leftX + specs[1].w
    for i = 2, #specs do
        local c = specs[i]
        c.x = x
        c.textR = x + c.w - sortGutter(c)
        c.textW = math.max(0, c.w - sortGutter(c))
        x = x + c.w
    end
    return specs
end

-- Sort direction marker next to the active column/chip: a 7x4 stair of drawRect lines, so it
-- needs no asset (Icons ships chevron_down but no chevron_up).
local function drawArrow(el, x, y, up, token)
    local c = color(token or "accent")
    for i = 0, ARROW_H - 1 do
        local w = up and (i * 2 + 1) or (ARROW_W - i * 2)
        el:drawRect(x + math.floor((ARROW_W - w) / 2), y + i, w, 1, c.a * U.alpha, c.r, c.g, c.b)
    end
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
        -- a column the page cannot sort by (the own-listings table sorts by nothing) never lights
        -- up and never reserves a gutter: it is a caption over the very same edges
        local sortable = c.sortable ~= false
        local active = sortable and c.key == sortKey
        local token = active and "accent" or (live and "textMuted" or "textFaint")
        if c.right then
            local rx = c.textR or (c.x + c.w - (sortable and SORT_GUTTER or 0))
            textRight(self, fitText(c.title, math.max(0, rx - c.x)), rx, ty, token)
            if active then drawArrow(self, c.x + c.w - ARROW_W, ay, not desc, token) end
        else
            local label = fitText(c.title, c.w - (sortable and SORT_GUTTER or 0))
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

-- ---------- toolbar helpers ----------

-- One wrapped row of toolbar controls between x and right; returns the y under the last row.
-- Wrapping is what keeps a toolbar inside the workspace at every font scale and in every language
-- (a Japanese "Refresh" is not an English one), and `gap` is the room a caption over the next row
-- needs. Each control is centred in the band, so a tall entry and a short chip line up.
local function placeRow(items, x, y, right, band, gap)
    local cx, cy = x, y
    for i = 1, #items do
        local el = items[i]
        if cx > x and cx + el.width > right then
            cx = x
            cy = cy + band + gap
        end
        el:setX(cx)
        el:setY(cy + math.floor((band - el.height) / 2))
        cx = cx + el.width + 6
    end
    return cy + band
end

-- Native combo box, skinned with the mod's own tokens: a category or sort set is a short list of
-- words, which is exactly what ISComboBox is for. A chip per category, wrapped into three rows at
-- a large font, was the old cost of the very same choice.
local function newCombo(owner, width, onChange)
    local c = ISComboBox:new(0, 0, width, math.max(26, fontH.small + 12), owner, onChange)
    c:initialise()
    c:instantiate()
    -- Restore the parent's stencil pixels after the native text clip (ISComboBox.lua:284-299).
    c.doRepaintStencil = true
    c.backgroundColor = color("well")
    c.borderColor = color("border")
    c.textColor = color("text")
    c.backgroundColorMouseOver = color("hover")
    owner:addChild(c)
    return c
end

-- The index whose data is `value`, so the box always shows the filter that is really in force (the
-- sortable table header sets the same value from a click).
local function comboSelect(combo, value)
    for i = 1, #combo.options do
        if combo:getOptionData(i) == value then
            combo.selected = i
            return true
        end
    end
    return false
end

-- Refill a box from a key list: the label comes from the caller, the data is the key the filter
-- itself sends, and the box lands back on the value in force. An open popup goes with the old
-- options — it is added to the UIManager, so it would outlive them.
local function comboFill(combo, keys, label, selected)
    if combo.expanded == true then
        combo.expanded = false
        if combo.popup and combo.popup.parentCombo == combo then combo:hidePopup() end
    end
    combo:clear()
    for i = 1, #keys do combo:addOptionWithData(label(keys[i]), keys[i]) end
    comboSelect(combo, selected)
end

-- ISComboBox paints its selected option unfitted, so the box is measured from its own widest
-- option instead of a constant: a translated category never runs past the border.
local function comboWidth(combo, minW, maxW)
    local wanted = minW
    for i = 1, #combo.options do
        wanted = math.max(wanted, textWidth(combo:getOptionText(i)) + 30)
    end
    return math.max(minW, math.min(maxW, wanted))
end

-- Browse sort options. Every key here is one the server accepts (ECMarket.SORTS / ECAuction.SORTS)
-- *and* one the sortable header can produce, so the box and the header arrow can never disagree.
-- A key the server does not know is answered with the *default* page, and the page then sees an
-- answer for a sort it did not ask for and asks again — an endless resend. So this list is the one
-- place either page names a sort. A spec without a title key keeps the string it already had.
local MARKET_SORTS = {
    { "time" }, { "time_asc" }, { "price" }, { "price_desc" },
    { "name", "Market_Col_Item" }, { "name_desc", "Market_Col_Item" },
    { "qty", "Market_Col_Qty" }, { "qty_desc", "Market_Col_Qty" },
    { "seller", "Market_Col_Seller" }, { "seller_desc", "Market_Col_Seller" },
    { "expires", "Market_Col_Expires" }, { "expires_desc", "Market_Col_Expires" },
}
local AUCTION_SORTS = {
    { "ending", "Auction_Col_Ends" }, { "ending_desc", "Auction_Col_Ends" },
    { "price", "Auction_Col_Bid" }, { "price_desc", "Auction_Col_Bid" },
    { "bids", "Auction_Col_Bids" }, { "bids_desc", "Auction_Col_Bids" },
    { "name", "Market_Col_Item" }, { "name_desc", "Market_Col_Item" },
}

-- Comparing prices across currencies is not a comparison at all, so the server refuses a price
-- sort while the browse filter is "every currency" (error currency_required). The box simply
-- does not offer those keys there: a control that cannot be honoured must not be pressable.
local PRICE_SORTS = { price = true, price_desc = true }

local function isPriceSort(key) return PRICE_SORTS[tostring(key)] == true end

local function sortKeysFor(specs, allowPrice)
    local keys = {}
    for i = 1, #specs do
        local key = specs[i][1]
        if allowPrice or not isPriceSort(key) then keys[#keys + 1] = key end
    end
    return keys
end


-- A sort option's label: its own string when it has one, else the column's own title plus the
-- direction, so a new sortable column costs no new translation key.
local function sortLabel(specs)
    local titleOf = {}
    for i = 1, #specs do titleOf[specs[i][1]] = specs[i][2] end
    return function(key)
        local titleKey = titleOf[key]
        if titleKey == nil then return getText(T .. "Market_Sort_" .. key) end
        local _, desc = sortParts(key)
        return getText(T .. (desc and "Sort_Desc" or "Sort_Asc"), getText(T .. titleKey))
    end
end

W.ITEM_ICON = ITEM_ICON
W.ARROW_W = ARROW_W
W.ARROW_H = ARROW_H
W.currencyIds = currencyIds
W.defaultCurrency = defaultCurrency
W.currencyLabel = currencyLabel
W.moneyText = moneyText
W.currencySample = currencySample
W.quoteOf = quoteOf
W.isPriceSort = isPriceSort
W.sortKeysFor = sortKeysFor
W.itemRowHeight = itemRowHeight
W.tileSize = tileSize
W.newEntry = newEntry
W.detailLine = detailLine
W.readerHeight = readerHeight
W.setSummary = setSummary
W.summaryMoved = summaryMoved
W.placeField = placeField
W.setPlaceholder = setPlaceholder
W.itemBaseName = itemBaseName
W.drawIcon = drawIcon
W.shopError = shopError
W.marketError = marketError
W.historyError = historyError
W.capacityLines = capacityLines
W.ceilPercent = ceilPercent
W.listingFee = listingFee
W.listingRow = listingRow
W.auctionRow = auctionRow
W.candidateRow = candidateRow
W.shopRow = shopRow
W.ShopCell = ShopCell
W.MailCell = MailCell
W.StatementCell = StatementCell
W.ListingCell = ListingCell
W.gridCandidate = gridCandidate
W.CandidateCell = CandidateCell
W.historyRowHeight = historyRowHeight
W.HISTORY_KINDS = HISTORY_KINDS
W.AUCTION_HISTORY_KINDS = AUCTION_HISTORY_KINDS
W.historyRow = historyRow
W.auctionHistoryRow = auctionHistoryRow
W.HistoryCell = HistoryCell
W.listingColumns = listingColumns
W.drawArrow = drawArrow
W.drawBadge = drawBadge
W.newHeader = newHeader
W.placeRow = placeRow
W.newCombo = newCombo
W.comboSelect = comboSelect
W.comboFill = comboFill
W.comboWidth = comboWidth
W.sortLabel = sortLabel
W.MARKET_SORTS = MARKET_SORTS
W.AUCTION_SORTS = AUCTION_SORTS

return W
