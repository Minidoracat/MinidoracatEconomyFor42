-- MinidoracatEconomyFor42 - the words and the arithmetic of a buy order (client). Adds exactly one
-- namespace: C.WantedText.
--
-- Pure functions over the server's views (contract wanted-contract.md section 5): no control, no
-- event, no state. The page (ECPanelWanted), its dialogs (ECPanelWantedDialogs) and the offline
-- test (scripts/test_entitlement_client.lua) all read them from here, so a refusal, a condition
-- or a price is worded the same everywhere it appears.

require "MinidoracatEconomy/ECPanelWidgets"

local EC = MinidoracatEconomy
local C = EC.Client
local U = C.UI
local W = C.PanelWidgets

local X = {}
C.WantedText = X

local T = U.T
local function tr(key, ...) return getText(T .. key, ...) end
local function int(v) return math.floor(tonumber(v) or 0) end

-- Kahlua strings count UTF-16 units, standard Lua counts bytes: a memo bound is in characters.
local WIDE_STRINGS = pcall(string.char, 19981)
function X.charCount(s)
    if WIDE_STRINGS then return #s end
    local n = 0
    for i = 1, #s do
        local b = string.byte(s, i)
        if b < 128 or b >= 192 then n = n + 1 end
    end
    return n
end

-- The server's percentage (ECMarket pct): rounded up, at least 1 while the rate is on.
function X.pct(amount, percent)
    if percent <= 0 or amount <= 0 then return 0 end
    return math.max(1, math.ceil(amount * percent / 100))
end

-- What a seller keeps of `gross` coins: the sales tax is the market's, never the whole amount.
function X.net(gross, taxPercent)
    if gross <= 0 then return 0, 0 end
    local tax = math.min(gross - 1, X.pct(gross, taxPercent))
    return gross - tax, tax
end

function X.money(amount, currency)
    return U.amountText(int(amount)) .. " " .. W.currencyLabel(currency)
end

-- "new only" / "durability at least 80%", or nil for an order that takes any copy.
function X.condText(cond)
    if type(cond) ~= "table" then return nil end
    if cond.new == true then return tr("Wanted_Cond_New") end
    local pct = tonumber(cond.minPct)
    if pct then return tr("Wanted_Cond_Min", tostring(int(pct))) end
    return nil
end

-- One payment option, per unit of the order: "2 Survivor coins each" / "1 Bandage each".
function X.optionText(opt)
    if type(opt) ~= "table" then return "-" end
    if opt.kind == "coin" then return tr("Wanted_Each", X.money(opt.unitPrice, opt.currency)) end
    return tr("Wanted_EachItems", tostring(int(opt.perUnit)), C.itemLabel(opt.item))
end

-- Every option of an order on one line, in the order's own option order.
function X.optionsLine(options)
    local s
    for _, opt in ipairs(type(options) == "table" and options or {}) do
        local part = X.optionText(opt)
        s = s and tr("Card_Join2", s, part) or part
    end
    return s or "-"
end

-- What an own order holds right now: the coins of every coin option and the items in escrow.
function X.heldText(order)
    local coins, items
    for _, opt in ipairs(type(order.options) == "table" and order.options or {}) do
        local held = int(opt.held)
        if opt.kind == "coin" and held > 0 then
            local part = X.money(held, opt.currency)
            coins = coins and (coins .. tr("Admin_Set_ListSep") .. part) or part
        elseif opt.kind == "item" and held > 0 then
            items = tr("Wanted_HeldItems", tostring(held), C.itemLabel(opt.item))
        end
    end
    local parts = {}
    if coins then parts[1] = tr("Wanted_HeldCoins", coins) end
    if items then parts[#parts + 1] = items end
    if #parts == 0 then return tr("Wanted_HeldNone") end
    return #parts == 1 and parts[1] or tr("Card_Join2", parts[1], parts[2])
end

-- The state of an own order as a pill: open, partly filled, or held because a refund failed.
-- Returns the label and its token; colour only supports the words.
function X.status(order)
    if order.blocked ~= nil or order.closing ~= nil then return tr("Wanted_Status_blocked"), "negative" end
    if int(order.qty) < int(order.qtyTotal) then return tr("Wanted_Status_partial"), "warn" end
    return tr("Wanted_Status_open"), "positive"
end

-- Why one group of the seller's copies is not taken (wanted.candidates verdict).
function X.verdictText(row)
    local code = tostring(row.verdict or "unknown")
    if code == "worn" then return tr("Wanted_Verdict_worn", tostring(int(row.pct))) end
    if code == "not_new" then return tr("Wanted_Verdict_not_new") end
    return W.marketError({ error = code, rule = row.rule })
end

-- A refusal of any wanted.* command as words. The codes of a buy order come first, then the
-- market's (codec refusals, transfers, the shared not_at_terminal with its way to a terminal),
-- and a code nobody has a sentence for ends on the shop's generic one (W.marketError logs it).
function X.errorText(args)
    local code = tostring((args and args.error) or "unknown")
    if code == "price_range" then
        if tonumber(args.min) then
            return tr("Wanted_Error_price_range", U.amountText(int(args.min)), U.amountText(int(args.max)))
        end
        return tr("Wanted_Error_price_max", U.amountText(int(args.max)))
    end
    if code == "too_many_orders" then return tr("Wanted_Error_too_many_orders", tostring(int(args.max))) end
    if code == "insufficient_funds" and tonumber(args.needed) then
        return tr("Wanted_Error_insufficient_funds", X.money(args.needed, args.currency))
    end
    if code == "qty_exceeded" then return tr("Wanted_Error_qty_exceeded", tostring(int(args.qty))) end
    if code == "price_changed" or code == "offer_not_higher" or code == "price_not_higher" then
        return tr("Wanted_Error_" .. code, U.amountText(int(args.unitPrice)))
    end
    if code == "worn" then
        return tr("Wanted_Error_worn", tostring(int(args.pct)), tostring(int(args.minPct)))
    end
    if code == "mail_confirmation_required" then
        return tr(args.heavy and "Delivery_ConfirmMailHeavy" or "Delivery_ConfirmMail")
    end
    return getTextOrNull(T .. "Wanted_Error_" .. code) or W.marketError(args)
end

return X
