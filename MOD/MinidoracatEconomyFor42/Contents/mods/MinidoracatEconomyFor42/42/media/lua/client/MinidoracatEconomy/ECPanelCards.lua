-- MinidoracatEconomyFor42 - the detail cards of the Economy Center window (client).
--
-- Every record the player window opens in the session's detail window (ECDetailWindow, contract
-- `card`) is built here from the row the page already holds: the statement, a shop sku, a market
-- listing, an auction, a letter, a market or auction record, the identity row, and the rules of
-- every page (market, auction, shop, mailbox, rewards) as short sections. Built when a record is
-- opened or its source refreshes, never per frame. The copy text stays Panel:detailText.
--
-- Card actions run the row's own button: `run` asks Panel:onDetailAction to find the row again
-- and press it through the list's onRowAction, so a card never trades on its own.
--
-- Also the wallet's "this month" view (K.monthView): income and spending of the loaded month by
-- kind, worded once per data change for ECPanelLayout to place and paint.

if not MinidoracatEconomy or not MinidoracatEconomy.Client or not MinidoracatEconomy.Client.UI then
    require "MinidoracatEconomy/ECWidgets"
end
require "MinidoracatEconomy/ECPanelWidgets"

local EC = MinidoracatEconomy
local C = EC.Client
local U = C.UI
local W = C.PanelWidgets

local K = {}
C.PanelCards = K

local T = U.T
local function tr(key, ...) return getText(T .. key, ...) end
local function itemName(fullType) return C.itemLabel(fullType) end

-- "a / b / c" joined by the translation's own separator (Card_Join2), so no glyph sits in a literal.
local function join(parts)
    local s = parts[1] or ""
    for i = 2, #parts do s = tr("Card_Join2", s, parts[i]) end
    return s
end

-- "UTC+08:00": the player's own zone, beside a real-world moment.
function K.zoneText(offsetMin)
    local off = offsetMin or 0
    local abs = math.abs(off)
    return "UTC" .. (off < 0 and "-" or "+") .. U.pad2(math.floor(abs / 60)) .. ":" .. U.pad2(abs % 60)
end

-- One card button: pressing it finds the row again and presses the row's own button. `enabled`
-- is a boolean or a function the window asks every frame (see live).
local function action(panel, kind, key, id, label, style, enabled, coin, tooltip)
    if type(enabled) ~= "function" then enabled = enabled == true end
    return { id = id, label = label, style = style, enabled = enabled, coin = coin, tooltip = tooltip,
        run = function() panel:onDetailAction(kind, key, id) end }
end

-- What the row allows, gated by the list's own switch (not at a terminal, a write on the wire)
-- as it stands when the window asks, so the card button turns on and off with the row's.
local function live(list, flag, rowOk)
    return function() return rowOk == true and not (list ~= nil and list[flag] == true) end
end

local function addRow(c, label, value, note, token, coin)
    c.rows[#c.rows + 1] = { label = label, value = value, note = note, token = token, coin = coin }
end

-- The technical facts (item code, ids) and the collapsed hint naming them.
local function addTech(c, labelKey, value)
    if value == nil or value == "" then return end
    local label = tr(labelKey)
    c.tech[#c.tech + 1] = { label = label, value = tostring(value) }
    c.techHint = c.techHint and (c.techHint .. tr("Admin_Set_ListSep") .. label) or label
end

-- The item's state: bars for what has a maximum, one row per other fact. Food in escrow keeps
-- ageing, which the market and the auction say under it.
local function addState(c, st, escrow)
    local meters = W.stateMeters(st)
    if #meters > 0 then c.meters = meters end
    local tokens = W.stateTokens(st, true)
    for i = 1, #tokens do addRow(c, i == 1 and tr("Card_State") or "", tokens[i]) end
    if escrow and type(st) == "table" and type(st.food) == "table" then c.text = tr("Market_State_FoodAging") end
end

-- The weight of the lot against the room left in the bags (the buy dialog's own estimate).
local function addWeight(c, item, qty, weight)
    local p = C.deliveryPreview(item, qty, weight)
    if p.known ~= true then return p end
    if p.heavy == true then
        c.note = tr(p.handsBusy and "Delivery_HandsBusy" or "Delivery_Hands")
        return p
    end
    addRow(c, tr("Card_Weight"), C.weightText(p.totalWeight),
        tr("Card_FreeNote", C.weightText(p.freeCapacity, "down")))
    return p
end

local function lotName(name, qty)
    return (qty or 1) > 1 and tr("Card_ItemQty", name, tostring(qty)) or name
end

-- ---------- the statement ----------
local KIND_ICONS = { checkin = "gift", milestone = "gift", transfer = "transactions", shop_buy = "shop",
    shop_sell = "shop", market_buy = "market", market_fee = "market", auction_bid = "auction",
    auction_refund = "auction", auction_sale = "auction", auction_fee = "auction", exchange_deposit = "plug",
    admin_adjust = "settings", account_merge = "users", mod = "plug" }

function K.statement(panel, e, title)
    local cur = e.currency
    local c = { source = title, sourceIcon = "wallet", item = e.item, rows = {}, tech = {} }
    -- who was on the other side: a deal with a player names what changed hands and with whom
    local detail = nil
    if e.cpClass == "player" then
        detail = e.item and tr(e.amount < 0 and "Card_BoughtFrom" or "Card_SoldTo", e.counterparty) or e.counterparty
    elseif e.item == nil and e.desc ~= "-" then
        detail = e.desc
    end
    if e.item then
        c.name = tr("Card_ItemQty", itemName(e.item), tostring(e.qty or 1))
        c.sub = detail and join({ e.kindText, detail }) or e.kindText
    else
        c.iconKey = KIND_ICONS[e.kind] or "coins"
        c.name, c.sub = e.kindText, detail
    end
    c.hero = { value = e.valueText, token = e.amount >= 0 and "positive" or "negative", coin = cur,
        unit = W.currencyLabel(cur), strike = e.rolledBack }
    if e.rolledBack then c.chips = { { value = tr("Wallet_RolledBack"), token = "negative", dot = true } } end
    addRow(c, tr("Wallet_Col_Time"), e.time)
    if e.after ~= nil then addRow(c, tr("Card_BalanceAfter"), U.amountText(e.after), nil, nil, cur) end
    if e.fee then addRow(c, tr(U.FEE_KEY[e.kind] or "Wallet_Col_Fee"), e.feeText, nil, nil, cur) end
    if e.reasonText and e.reasonText ~= "" then
        addRow(c, tr(e.kind == "transfer" and "Transfer_Memo" or "Admin_Tx_Field_Reason"), e.reasonText)
    end
    addTech(c, "Detail_TxId", e.txId)
    return c
end

-- ---------- the shop ----------
function K.shop(panel, e, list, key, title)
    local cur = e.currency
    local c = { source = title, sourceIcon = "shop", item = e.item, name = e.name, rows = {}, tech = {} }
    local per = tr("Shop_QtyPer", tostring(e.qty))
    c.sub = (e.altName and e.altName ~= e.name) and join({ e.altName, per }) or per
    if e.hasQuote then
        c.hero = { value = U.amountText(e.price), coin = cur, unit = tr("Card_PerLot", e.currencyText) }
    elseif e.delisted and e.bidPrice ~= nil then
        c.hero = { value = U.amountText(e.bidPrice), coin = cur, unit = tr("Card_BidUnit", e.currencyText) }
    else
        c.hero = { value = tr("Shop_NoQuote"), token = "textMuted" }
    end
    local chips = {}
    if e.delisted then
        chips[1] = { value = tr("Shop_Tag_BuybackOnly"), token = "warn", dot = true }
        c.note = e.statusText
    elseif e.dailyCap > 0 then
        local lifetime = e.dailyCapScope == "lifetime"
        if e.soldOut then
            chips[1] = { value = e.remainFull, token = "negative", dot = true }
        else
            chips[1] = { label = tr("Card_Left_" .. e.dailyCapScope),
                value = tr("Card_LotsOf", tostring(math.max(0, e.remaining or e.dailyCap)), tostring(e.dailyCap)) }
        end
        chips[#chips + 1] = { label = tr("Shop_CapScope"), value = e.capScopeText }
        local ends = C.shop and tonumber(C.shop.dayEndsMs)
        if ends ~= nil and not lifetime then
            chips[#chips + 1] = { label = tr("Shop_PillReset"),
                value = tr("Shop_ResetIn", U.durationText(math.max(0, ends - EC.now()))) }
        end
        addRow(c, tr(lifetime and "Card_BoughtEver" or "Card_BoughtToday"),
            tonumber(e.usedText) and tr("Card_Lots", e.usedText) or e.usedText)
    else
        chips[1] = { label = tr("Shop_Col_Remaining"), value = tr("Shop_Unlimited") }
    end
    c.chips = chips
    -- what switching the page's currency would cost, then what the shop pays back
    local first = true
    for _, q in ipairs(e.quotes or {}) do
        if q.currency ~= cur and q.enabled then
            addRow(c, first and tr("Card_AlsoIn") or "", U.amountText(q.price) .. " " .. W.currencyLabel(q.currency),
                nil, nil, q.currency)
            first = false
        end
    end
    if e.buyback and not e.delisted then
        addRow(c, tr("Shop_Col_Bid"), W.moneyText(e.bidPrice, cur),
            e.buybackOpen ~= true and tr("Card_Paren", tr("Shop_PillBuybackPaused")) or nil, nil, cur)
    end
    local acts = {}
    if not e.delisted then
        acts[1] = action(panel, "shop", key, "buy", e.buyLabel, "primary",
            live(list, "buyDisabled", not e.soldOut and e.hasQuote == true))
    end
    if e.buyback then
        acts[#acts + 1] = action(panel, "shop", key, "sell", e.sellLabel, "chip",
            live(list, "buyDisabled", e.buybackOpen == true and e.buybackRemaining ~= 0), cur)
    end
    c.actions = acts
    addTech(c, "Detail_ItemCode", e.item)
    return c
end

-- ---------- the market ----------
local function eachText(price, qty)
    local each = price / qty
    return each == math.floor(each) and U.amountText(each) or string.format("%.1f", each)
end

function K.market(panel, e, list, key, title)
    local cur = e.currency
    local c = { source = e.mine and join({ title, tr("Market_Own") }) or title, sourceIcon = "market",
        item = e.item, name = lotName(e.name, e.qty), rows = {}, tech = {} }
    local pcs = tr("Card_Pieces", tostring(e.qty))
    c.sub = e.altName and join({ e.altName, pcs }) or pcs
    c.hero = { value = e.priceText, coin = cur, unit = e.qty > 1
        and tr("Card_LotUnit", e.currencyText, tostring(e.qty), eachText(e.price, e.qty)) or e.currencyText }
    local chips = { { label = tr("Card_Left"), value = e.expiresText } }
    if e.mine then
        local tax = W.ceilPercent(e.price, tonumber(panel.marketInfo and panel.marketInfo.taxPercent) or 0)
        chips[2] = { label = tr("Card_NetOnSale"), value = U.amountText(e.price - tax), coin = cur }
    elseif e.blocked then
        chips[2] = { value = e.actionLabel, token = "warn", dot = true }
    elseif e.own then
        chips[2] = { value = tr("Market_Own"), dot = true }
    elseif not panel:tradeAllowed() then
        chips[2] = { value = tr((C.wallet and C.wallet.frozen) and "Card_Frozen" or "Card_NotHere"), token = "warn", dot = true }
    else
        chips[2] = { value = tr("Card_CanBuy"), token = "positive", dot = true }
    end
    c.chips = chips
    addState(c, e.state, true)
    if not e.mine then
        addRow(c, tr("Market_Col_Seller"), e.seller)
        addWeight(c, e.item, e.qty, e.weight)
    end
    if e.actionId == "buy" then
        c.actions = { action(panel, "market", key, "buy", tr("Card_BuyFor", e.priceText), "primary",
            live(list, "actionDisabled", true), cur) }
    elseif e.actionId == "cancel" then
        c.actions = { action(panel, "market", key, "cancel", e.actionLabel, "danger", live(list, "actionDisabled", true)) }
    end
    addTech(c, "Detail_ItemCode", e.item)
    addTech(c, "Card_ListingId", e.id)
    return c
end

-- ---------- auctions ----------
function K.auction(panel, e, list, key, title)
    local cur = e.currency
    local bidding = list ~= nil and list == panel.auctionBidList
    local mine = e.mine or (list ~= nil and list == panel.auctionSellList)
    local c = { source = mine and join({ title, tr("Auction_Own") }) or title, sourceIcon = "auction",
        item = e.item, name = lotName(e.name, e.qty), rows = {}, tech = {} }
    local parts = {}
    if e.altName then parts[1] = e.altName end
    parts[#parts + 1] = tr("Card_Pieces", tostring(e.qty))
    if not mine then parts[#parts + 1] = tr("Market_BuyFrom", e.seller) end
    c.sub = join(parts)
    c.hero = { value = U.amountText(e.price), coin = cur, unit = e.bid
        and tr("Card_BidUnit2", e.currencyText, tostring(e.bids)) or tr("Card_StartUnit", e.currencyText) }
    local chips = {}
    if e.blocked and not mine then
        chips[1] = { value = e.actionLabel, token = "warn", dot = true }
    elseif e.ended then
        chips[1] = { value = tr("Auction_Ended"), token = "warn", dot = true }
    elseif mine then
        chips[1] = { value = tr("Auction_Own"), dot = true }
    elseif e.leading then
        chips[1] = { value = tr("Auction_Leading"), token = "positive", dot = true }
    elseif bidding then
        chips[1] = { value = tr("Auction_Outbid"), token = "negative", dot = true }
    end
    if not e.ended then chips[#chips + 1] = { value = e.expiresText } end
    c.chips = chips
    addState(c, e.state, true)
    if e.bid then addRow(c, tr("Card_StartPrice"), U.amountText(e.startPrice), nil, nil, cur) end
    if e.canBid then addRow(c, tr("Card_NextMin"), U.amountText(e.minNext), nil, nil, cur) end
    if e.leading and e.bid and not e.ended then
        addRow(c, tr("Card_YouHold"), U.amountText(e.bid), tr("Card_HoldNote"), nil, cur)
    end
    local acts = {}
    if e.actionId == "bid" then
        acts[1] = action(panel, "auction", key, "bid", tr(bidding and "Card_RaiseTo" or "Card_BidAt",
            U.amountText(e.minNext)), "primary", live(list, "actionDisabled", true), cur)
    elseif e.actionId == "acancel" then
        acts[1] = action(panel, "auction", key, "acancel", e.actionLabel, "danger",
            live(list, "actionDisabled", e.actionOff ~= true))
    end
    if e.id ~= nil then acts[#acts + 1] = action(panel, "auction", key, "history", tr("Auction_History"), "chip", true) end
    c.actions = acts
    addTech(c, "Detail_ItemCode", e.item)
    addTech(c, "Auction_Col_Id", e.id)
    return c
end

-- ---------- the mailbox ----------
function K.mail(panel, e, list, key, title)
    local qty = tonumber(e.qty) or 1
    local c = { source = title, sourceIcon = "mail", item = e.item, name = tr("Card_ItemQty", e.name, tostring(qty)),
        sub = e.fromName, rows = {}, tech = {} }
    local p = addWeight(c, e.item, qty, e.weight)
    local fit = tonumber(p.fitQty)
    local chips = {}
    if p.known == true and fit ~= nil then
        if fit >= qty then
            chips[1] = { value = tr("Card_Fits"), token = "positive", dot = true }
        elseif fit > 0 then
            chips[1] = { value = tr("Card_FitsSome", tostring(fit)), token = "warn", dot = true }
        else
            chips[1] = { value = tr("Card_NoRoom"), token = "negative", dot = true }
        end
        -- what a claim does when not all of it fits (the record's own sentences)
        if p.heavy ~= true and fit < qty then
            c.note = fit > 0 and tr("Mail_DetailPartial", tostring(fit), tostring(qty - fit))
                or tr("Mail_DetailNoRoom", C.weightText(math.max(0, p.totalWeight / qty - p.freeCapacity), "up"))
        end
    elseif p.known ~= true then
        c.note = tr("Delivery_Unknown")
    end
    chips[#chips + 1] = { label = tr("Card_Received"), value = e.timeText }
    c.chips = chips
    addState(c, e.state, false)
    if e.price ~= nil then addRow(c, tr("Wallet_Col_Amount"), W.moneyText(e.price, e.currency), nil, nil, e.currency) end
    if e.seller ~= nil then addRow(c, tr("Market_Col_Seller"), e.seller) end
    local partial = p.known == true and p.heavy ~= true and fit ~= nil and fit > 0 and fit < qty
    c.actions = { action(panel, "mail", key, "claim", partial and tr("Card_ClaimSome", tostring(fit)) or e.claimLabel,
        "primary", live(list, "actionDisabled", e.claimable == true), nil, list and list.actionHint or nil) }
    addTech(c, "Detail_ItemCode", e.item)
    return c
end

-- ---------- market and auction records ----------
-- The kinds whose amount is a wallet movement of the player's own (historyRow signs them).
local SIGNED = { sold = true, auction_sold = true, bought = true, auction_bid = true, auction_won = true }
local ACCOUNT_KEYS = { { "Seller", "seller" }, { "Bidder", "bidder" }, { "Buyer", "buyer" }, { "Previous", "previous" } }

function K.history(panel, e, title, auction)
    local rec = e.rec or {}
    local cur = e.currency
    local c = { source = title, sourceIcon = auction and "auction" or "market", item = e.item, rows = {}, tech = {} }
    if e.item then
        c.name = tr("Card_KindItem", e.kindText, lotName(itemName(e.item), e.qty or 1))
    else
        c.iconKey, c.name = auction and "auction" or "market", e.kindText
    end
    local parts = {}
    if auction then
        for _, spec in ipairs(ACCOUNT_KEYS) do
            local who = rec[spec[2]]
            if type(who) == "string" and who ~= "" then parts[#parts + 1] = tr("Auction_History_" .. spec[1], who) end
        end
    elseif type(rec.other) == "string" and rec.other ~= "" then
        local k = (e.kind == "sold" or e.kind == "auction_sold") and "Card_Buyer"
            or ((e.kind == "bought" or e.kind == "auction_won") and "Market_BuyFrom" or "Market_History_Other")
        parts[1] = tr(k, rec.other)
    end
    if type(rec.reason) == "string" and rec.reason ~= "" then parts[#parts + 1] = U.marketReasonText(rec.reason) end
    if #parts > 0 then c.sub = join(parts) end
    local price = tonumber(rec.price)
    local signed = not auction and SIGNED[e.kind] == true and price ~= nil
    if signed then
        c.hero = { value = U.signedText(e.amount), token = e.amount >= 0 and "positive" or "negative", coin = cur,
            unit = W.currencyLabel(cur), strike = e.rolledBack }
        addRow(c, tr("Card_DealPrice"), U.amountText(price), nil, nil, cur)
    elseif price ~= nil then
        c.hero = { value = U.amountText(price), coin = cur, unit = W.currencyLabel(cur), strike = e.rolledBack }
    end
    if e.rolledBack then c.chips = { { value = tr("Wallet_RolledBack"), token = "negative", dot = true } } end
    local tax, fee = tonumber(rec.tax), tonumber(rec.fee)
    if tax and tax > 0 then addRow(c, tr("Trade_Tax"), "-" .. U.amountText(tax), nil, "negative", cur) end
    if fee and fee > 0 then addRow(c, tr("Market_Fee"), "-" .. U.amountText(fee), nil, "negative", cur) end
    addRow(c, tr("Wallet_Col_Time"), U.stampText(e.ts, panel.offsetMin))
    addTech(c, "Detail_TxId", rec.txId)
    if auction then addTech(c, "Auction_Col_Id", rec.auctionId or rec.listingId)
    else addTech(c, "Card_ListingId", rec.listingId) end
    addTech(c, "Detail_ItemCode", e.item)
    return c
end

-- The card of one row of `kind`, opened (or refreshed) from `panel.detailList`.
function K.build(panel, kind, e, key, title)
    local list = panel.detailList
    if kind == "statement" then return K.statement(panel, e, title) end
    if kind == "history" then return K.history(panel, e, title, panel.tab == "Auction") end
    if kind == "shop" then return K.shop(panel, e, list, key, title) end
    if kind == "market" then return K.market(panel, e, list, key, title) end
    if kind == "auction" then return K.auction(panel, e, list, key, title) end
    if kind == "mail" then return K.mail(panel, e, list, key, title) end
    return nil
end

-- The identity row: the economy account, the login it came in with, and why it is not answered.
function K.identity(panel, body)
    local account, login = panel:username(), C.login()
    local c = { sourceIcon = "users", iconKey = "users", name = account or login or "-" }
    if C.identityUnverified then
        c.name = login or c.name
        c.chips = { { value = tr("Player_IdentityUnverified"), token = "warn", dot = true } }
        c.text = body
    elseif account ~= nil and login ~= nil and account ~= login then
        c.sub = tr("Card_LoginAs", login)
        c.text = body
    end
    return c
end

-- ---------- rules ----------
local function rulesCard(panel)
    return { source = join({ tr("Tab_" .. tostring(panel.tab)), tr("Trade_Rules") }), sourceIcon = "document" }
end

-- Market and auction: what the page is, its two rates, and the listing rules. The record pages
-- only say what their record holds.
function K.tradeRules(panel, market, history)
    local c = rulesCard(panel)
    if history then
        c.text = tr(market and "Market_History_Note" or "Auction_History_Note")
        return c
    end
    local info = (market and panel.marketInfo) or ((not market) and panel.auctionInfo) or {}
    local tax, fee = tostring(info.taxPercent or 0) .. "%", tostring(info.feePercent or 0) .. "%"
    local how, rules = {}, {}
    if market then
        how[1] = { text = tr("Card_R_Market") }
        if (info.maxListings or 0) > 0 then rules[1] = { pill = tostring(info.maxListings), text = tr("Card_R_ListingMax") } end
        rules[#rules + 1] = { text = tr("Card_R_Lot") }
        rules[#rules + 1] = { text = tr("Card_R_Expire") }
        rules[#rules + 1] = { mark = "no", text = tr("Card_R_NoRefund") }
        rules[#rules + 1] = { text = tr("Card_R_ListingSlot") }
    else
        how[1] = { text = tr("Card_R_BidHold") }
        how[2] = { text = tr("Card_R_HighWins") }
        local minH, maxH = info.minHours or 0, info.maxHours or 0
        if (info.maxAuctions or 0) > 0 then rules[1] = { pill = tostring(info.maxAuctions), text = tr("Card_R_AuctionMax") } end
        rules[#rules + 1] = { pill = minH == maxH and tr("Auction_Hours", tostring(minH))
            or tr("Auction_HoursHint", tostring(minH), tostring(maxH)), text = tr("Card_R_AuctionRuns") }
        rules[#rules + 1] = { mark = "no", text = tr("Card_R_NoCancelBids") }
        rules[#rules + 1] = { mark = "no", text = tr("Card_R_NoRefundAuction") }
        rules[#rules + 1] = { text = tr("Card_R_Unsold") }
        rules[#rules + 1] = { text = tr("Card_R_AuctionSlot") }
    end
    c.sections = {
        { title = tr("Card_R_HowTitle"), lines = how },
        { title = tr("Card_R_FeesTitle"), lines = {
            { pill = tax, text = tr("Card_R_Tax") },
            { pill = fee, text = tr(market and "Card_R_Fee" or "Card_R_AuctionFee") } } },
        { title = tr(market and "Card_R_ListingTitle" or "Card_R_AuctionTitle"), lines = rules },
    }
    return c
end

-- The shop: the page's currency, how a limit's scope counts, when limits reset, what buyback takes.
function K.shopRules(panel)
    local c = rulesCard(panel)
    local cur = panel:shopCurrency()
    local secs = {
        { title = tr("Card_R_ShopTitle"), lines = {
            { pill = { value = C.currencyName(cur), coin = cur }, text = tr("Card_R_ShopCur") },
            { text = tr("Card_R_ShopPerItem") } } },
        { title = tr("Card_R_ScopeTitle"), lines = {
            { pill = tr("Shop_Scope_player"), text = tr("Card_R_ScopePlayer") },
            { pill = tr("Shop_Scope_global"), text = tr("Card_R_ScopeGlobal") },
            { pill = tr("Shop_Scope_lifetime"), text = tr("Card_R_ScopeLifetime") },
            { text = tr("Card_R_ScopeOpen") } } },
    }
    local ends = C.shop and tonumber(C.shop.dayEndsMs)
    if ends ~= nil then
        local off = panel.offsetMin or 0
        secs[#secs + 1] = { title = tr("Card_R_ResetTitle"), lines = {
            { pill = tr("Shop_ResetIn", U.durationText(math.max(0, ends - EC.now()))), text = tr("Card_R_ResetWhat"),
                note = tr("Card_R_RealAt", U.stampText(ends, off), K.zoneText(off)) } } }
    end
    local sell = {}
    local bb = C.shop and C.shop.buyback
    if panel.shopHasBuyback and not W.buybackOpen(bb, cur) then
        sell[1] = { mark = "no", text = (type(bb) == "table" and bb.enabled == true)
            and tr("Shop_BuybackOffCurrency", C.currencyName(cur)) or tr("Shop_BuybackPaused") }
    end
    sell[#sell + 1] = { mark = "ok", text = tr("Card_R_SellNew") }
    sell[#sell + 1] = { mark = "ok", text = tr("Card_R_SellFood") }
    sell[#sell + 1] = { mark = "no", text = tr("Card_R_SellNot") }
    sell[#sell + 1] = { text = tr("Card_R_SellQuota") }
    secs[#secs + 1] = { title = tr("Card_R_SellTitle"), lines = sell }
    c.sections = secs
    return c
end

-- The mailbox: where letters come from, where they are claimed, and what the slots are made of.
function K.mailRules(panel)
    local c = rulesCard(panel)
    local slots = {}
    local usage = C.mail and C.mail.usage
    if type(usage) == "table" and tonumber(usage.capacity) then
        slots[1] = { pill = tostring(tonumber(usage.used) or 0) .. " / " .. tostring(tonumber(usage.capacity)),
            text = tr("Card_R_SlotsUsed") }
        slots[2] = { pill = tostring(tonumber(usage.unclaimed) or 0), text = tr("Card_R_SlotsWaiting") }
        slots[3] = { pill = tostring(tonumber(usage.marketListings) or 0), text = tr("Card_R_SlotsListings") }
        slots[4] = { pill = tostring(tonumber(usage.auctions) or 0), text = tr("Card_R_SlotsAuctions") }
    end
    slots[#slots + 1] = { text = tr("Card_R_SlotsEach") }
    slots[#slots + 1] = { mark = "no", text = tr("Card_R_MailFull") }
    c.sections = {
        { title = tr("Card_R_MailTitle"), lines = { { text = tr("Card_R_MailSources") }, { text = tr("Card_R_MailWhere") },
            { text = tr("Card_R_MailPart") } } },
        { title = tr("Card_R_SlotsTitle"), lines = slots },
    }
    return c
end

-- Rewards: the daily claim, the season and its milestones, every fact Panel:rewardLines words
-- (`blocked` is that sentence for a refused claim, nil when none).
function K.rewardsRules(panel, st, blocked)
    local c = rulesCard(panel)
    local now = EC.now()
    local off = st.blockedReason == "checkin_disabled"
    local claimed = math.max(0, math.floor(tonumber(st.claimedCount) or 0))
    local limit = math.max(1, math.floor(tonumber(st.dailyLimit) or 1))
    local left = math.max(0, math.floor(tonumber(st.remainingClaims) or 0))
    local short = math.max(0, tonumber(st.remainingOnlineMs) or 0)
    local nextReset = tonumber(st.nextResetMs) or 0
    local daily = {}
    if off then
        daily[1] = { mark = "no", text = tr("Rewards_Error_checkin_disabled") }
    else
        daily[1] = { pill = tr("Rewards_PillTodayValue", tostring(claimed), tostring(limit)), text = tr("Card_R_RwToday") }
        daily[2] = { pill = tostring(left), text = tr("Card_R_RwLeft") }
        daily[3] = { pill = { value = U.amountText(st.amount) .. " " .. C.currencyName(st.currency), coin = st.currency },
            text = tr("Card_R_RwEach") }
        daily[4] = { pill = tr("Card_R_Minutes", tostring(math.floor(math.max(0, tonumber(st.playedMs) or 0) / 60000)),
            tostring(math.floor(math.max(0, tonumber(st.requiredOnlineMs) or 0) / 60000))), text = tr("Card_R_RwOnline") }
        if short > 0 then
            daily[5] = { pill = U.durationText(short), text = tr("Card_R_RwNextIn") }
        elseif left > 0 and st.canClaim == true then
            daily[5] = { mark = "ok", text = tr("Rewards_Ready") }
        end
    end
    if not off and blocked ~= nil then daily[#daily + 1] = { mark = "no", text = blocked } end
    daily[#daily + 1] = { pill = U.durationText(math.max(0, nextReset - now)), text = tr("Card_R_RwReset"),
        note = tr("Card_Paren", U.stampText(nextReset, panel.offsetMin)) }
    if panel.message then daily[#daily + 1] = { text = panel.message.text } end
    local season = {}
    local endsAt = panel:seasonDeadline(st)
    if type(endsAt) == "number" then
        local note = tr("Card_Paren", U.stampText(endsAt, panel.offsetMin))
        season[1] = endsAt > now and { pill = U.realDurationText(endsAt - now), text = tr("Card_R_SeasonLeft"), note = note }
            or { text = tr("Rewards_SeasonPending"), note = note }
    else
        season[1] = { text = tr(endsAt == "manual" and "Rewards_SeasonManual" or "Rewards_SeasonUnknown") }
    end
    c.sections = { { title = tr("Rewards_Daily"), lines = daily },
        { title = tr("Rewards_Milestones", tostring(st.seasonNumber or "-")), lines = season } }
    if st.survivalError ~= nil then
        local code = tostring(st.survivalError)
        season[#season + 1] = { mark = "no", text = tr("Season_SurvivalFailed",
            getTextOrNull(T .. "Rewards_Error_" .. code) or U.unknownText("survival error", code)) }
        return c
    end
    if st.survivalKnown == true and type(st.survivalHours) == "number" then
        season[#season + 1] = { pill = U.survivalText(st.survivalHours * 60), text = tr("Card_R_Survived") }
    else
        season[#season + 1] = { text = tr("Season_SurvivalUnknown") }
    end
    if type(st.bestSurvivalHours) == "number" then
        season[#season + 1] = { pill = U.survivalText(st.bestSurvivalHours * 60), text = tr("Card_R_Best") }
    end
    if st.survivalIncomplete == true then season[#season + 1] = { text = tr("Season_Incomplete") } end
    local nextM = nil
    local marks = {}
    for _, m in ipairs(st.milestoneList or {}) do
        local done = U.hasBit(st.milestones, m.index)
        if not done and nextM == nil then nextM = m end
        marks[#marks + 1] = {
            pill = { value = W.moneyText(m.amount, st.currency), coin = st.currency },
            text = tr("Rewards_MilestoneRow", tostring(m.days)),
            note = tr("Card_Paren", tr(done and "Rewards_Achieved" or "Rewards_Pending")) }
    end
    season[#season + 1] = { text = nextM and tr("Rewards_NextMilestone", tostring(nextM.days)) or tr("Rewards_AllMilestones") }
    if #marks > 0 then c.sections[3] = { title = tr("Rewards_MilestoneTitle"), lines = marks } end
    return c
end

-- ---------- the wallet's month ----------
-- How many kinds each side lists before the rest is summed into "other".
local MONTH_TOP = 3

local function monthSide(lines, byKind, inflow, maxOut)
    local list = {}
    for kind, amount in pairs(byKind) do
        if amount > 0 then list[#list + 1] = { kind = kind, amount = amount } end
    end
    EC.sortSafe(list, function(a, b) return a.amount > b.amount end)
    local rest = 0
    for i, it in ipairs(list) do
        if i <= MONTH_TOP then
            local label = it.kind == "transfer" and tr(inflow and "Kind_transfer_in" or "Kind_transfer_out")
                or U.kindText(it.kind)
            lines[#lines + 1] = { label = label, amount = it.amount, token = inflow and "positive" or "negative",
                amountText = (inflow and "+" or "-") .. U.amountText(it.amount) }
            maxOut.v = math.max(maxOut.v, it.amount)
        else
            rest = rest + it.amount
        end
    end
    if rest > 0 then
        lines[#lines + 1] = { label = tr("Kind_other"), amount = rest, token = inflow and "positive" or "negative",
            amountText = (inflow and "+" or "-") .. U.amountText(rest) }
        maxOut.v = math.max(maxOut.v, rest)
    end
end

-- panel.monthView = { title, note, noteToken, lines = { { head = true, coin, text, inText, outText }
-- | { label, amountText, token, frac } } }: rebuilt with the balances, read by the layout and paint.
function K.monthView(panel)
    local totals = panel.monthTotals
    local mv = { title = tr("Card_MonthTitle"), lines = {} }
    if totals == nil then
        mv.note, mv.noteToken = tr("Card_MonthNone"), "textMuted"
    elseif panel.monthComplete ~= true then
        mv.note, mv.noteToken = tr("Card_MonthPartial"), "warn"
    else
        local key = tostring(panel.monthLoaded or "")
        mv.note, mv.noteToken = tr("Card_MonthScope", string.sub(key, 1, 4) .. "-" .. string.sub(key, 5, 6)), "textFaint"
    end
    local lines = mv.lines
    for _, id in ipairs(panel:currencies()) do
        local t = totals and totals[id]
        if t and (t.inn > 0 or t.out > 0) then
            lines[#lines + 1] = { head = true, coin = id, text = C.currencyName(id),
                inText = tr("Card_MonthIn", "+" .. U.amountText(t.inn)),
                outText = tr("Card_MonthOut", "-" .. U.amountText(t.out)) }
            local from = #lines + 1
            local maxOut = { v = 0 }
            monthSide(lines, t.byIn or {}, true, maxOut)
            monthSide(lines, t.byOut or {}, false, maxOut)
            for i = from, #lines do lines[i].frac = maxOut.v > 0 and lines[i].amount / maxOut.v or 0 end
        end
    end
    if totals ~= nil and #lines == 0 then mv.empty = tr("Card_MonthEmpty") end
    panel.monthView = mv
end

return K
