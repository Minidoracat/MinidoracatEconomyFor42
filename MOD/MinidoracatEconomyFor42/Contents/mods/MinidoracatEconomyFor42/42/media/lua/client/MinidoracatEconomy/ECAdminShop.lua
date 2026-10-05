-- MinidoracatEconomyFor42 -- admin shop catalog page (client). Adds exactly one namespace:
-- C.AdminShop.
--
--   C.AdminShop.create(owner, isPending)
--       an initialised ISPanel child, NOT added (the admin controller addChild's it). Nothing
--       here sends a command: every write leaves through owner:sendCatalog(args) /
--       owner:sendOption(key, value) and every read through owner:requestCatalog(), so the shared
--       cooldown, the pending slots and the footer line stay in one place. isPending is the
--       controller's plain function. No Events hook and no timer of its own: the controller calls
--       tick(now) while this page is the one on screen.
--
-- A list plus one editor. The picked SKU is edited as a form whose groups are always in the same
-- order -- what the item IS (unit count, category), the shared limits (listed, daily shares,
-- whose shares they are, buyback shares), the quotes (one row per currency: a sell switch, a
-- sell price, a buyback switch and a buyback price, every currency over the same column
-- boundaries) and last the read-only buyback status the server reported -- and committed with
-- one Apply that carries every changed column in a single admin.catalog write. Cancel puts the
-- fields back to the snapshot's values. The order is fixed on purpose: it is never decided by
-- how tall the sentence above a field happens to be, and the standing rules about what a column
-- means are read in full in the detail window instead of beside every box.
--
-- Only columns the admin really moved travel. A per-currency column travels nested, so a write
-- that raises the survivor price leaves the cat quote exactly as it is:
--   { action="set", id=..., revision=..., qty?, category?, enabled?, dailyCap?, dailyCapScope?,
--     buybackCap?, prices = { [currency] = { price?, bidPrice?, enabled?, buyback? } } }
-- and a batch is the same columns under `fields` with the list of ids. An explicit 0 or "off" is
-- a value like any other; a column nobody touched is absent from the write, currency sub-tables
-- included -- and a form that would change nothing sends no command at all.
--
-- A currency with no quote is NOT a free item and NOT a zero: its price box is empty, its two
-- direction switches say "not offered" and nothing about it travels. Typing a price is what
-- creates the quote (all four of its leaves travel at once, so the server never sees half a
-- quote). Emptying the price of a quote that exists is refused: stopping a direction is what the
-- switches are for, and a disabled quote keeps its price.
--
-- Identity is never hidden behind a detail window: the localised name, the script's own (English)
-- name, the item's fullType and the SKU id with its category and unit count stay pinned over the
-- scrolling field area at every window size. The Apply / Cancel bar is pinned under it for the
-- same reason. The quotes themselves are not repeated up there: they are the table in the form.
--
-- A draft is never thrown away behind the admin's back: leaving the page or the window asks first
-- (requestLeave), a save still in flight keeps the page where it is, and a refusal, a timeout and
-- a catalog push another admin caused all leave the typed values exactly as they are -- a
-- background snapshot only moves the base the next write is compared against, and says so on
-- screen. Only losing the admin right (clear/dispose) drops a draft unasked.
--
-- The buyback master switch is the sandbox switch, read from the server snapshot alone: its state
-- ("enabled" / "disabled") and its action ("turn buyback off" / "turn buyback on") are two
-- separate things on screen, and an item that has buyback configured while the master is off says
-- that its settings are kept but not in force. Why a currency is not buying is told apart in the
-- read-only status group, because they are different facts: the master switch is off (said once,
-- never per currency), a coin cap really configured to 0, a currency the server reports as
-- unavailable for trade although its caps allow it, and one whose room for today is used up. The
-- configured caps and the room left are always shown as the server reported them, separately,
-- with "-" where no snapshot carried one.
--
-- Adding a SKU searches every item script the server loaded (C.ItemPicker, MOD items included);
-- the picked record only fills a new-item form the admin can still edit before the one
-- admin.catalog{action="add"} write leaves. A new SKU's category is "other" -- always, never
-- guessed from the script's DisplayCategory, which is shown beside the field as a reference only.
-- New SKUs start with buyback off.
--
-- Category is a plain native dropdown, twice over: the editor's own (the five categories the shop
-- itself pages by, plus every category the catalog on screen already uses) and the list's filter
-- above it (the same list with "all categories" in front). The filter narrows the list on top of
-- the keyword search, and changing either of them drops the picked set -- a row that scrolled out
-- of the filter is not something to be edited by accident.
--
-- Caps count shares (qty pieces each): player/global reset daily; lifetime does not.
-- Modes are exclusive and 0 is unlimited. Display draft settings separately from the
-- server's used/remaining snapshot, which still belongs to the saved mode.
--
-- More than one SKU at a time: the picked set is what the editor edits. Ctrl toggles a row into
-- it, Shift takes the range over the list *as filtered right now*, and a plain pick drops the
-- set and opens that one row. Two or more picked rows ARE the batch form -- there is no chip to
-- press afterwards, and a row opened on its own counts as picked, so "open A, Ctrl-pick B" edits
-- both -- and dropping back to one row is that row's own editor again. Every one of those
-- changes goes through the same unsaved-work gate: a refusal leaves the editor AND the set
-- exactly as they were.
--
-- Changing a column IS asking for it: every column the admin really moved off what the picked
-- rows already hold travels, and a column they left alone travels nowhere -- so an explicit 0 or
-- "off" is written like any other value, while a column the rows disagree on is never guessed.
-- One admin.catalog{action="batch"} write carries the ids, those columns and one revision, so the
-- server validates every row before any of them is written.
--
-- Delete removes what the editor holds -- the open SKU, or the batch set -- and only ever asks
-- first: the controller's confirmation names every row and what it is still doing, takes a
-- reason, and sends one admin.catalog{action="remove"} with the ids and the revision on screen.
-- Taking a row off the shelf is not removing it: a delisted row keeps its buyback quotes and
-- the player's shop still offers what they buy back (appendRuleText says so in full).

-- Geometry is page relative (y = 0 .. self.height) and font aware: a narrow or short window shows
-- the list and the editor one at a time, the editor's field area scrolls, and the Apply / Cancel
-- bar is pinned to the bottom of the editor so the primary action is reachable at every size.

require "ISUI/ISPanel"
require "ISUI/ISScrollBar"
require "ISUI/ISComboBox"
require "MinidoracatEconomy/ECWidgets"
require "MinidoracatEconomy/ECItemPicker"
require "MinidoracatEconomy/ECDetailWindow"

local EC = MinidoracatEconomy
local C = EC.Client
local U = C.UI
local Picker = C.ItemPicker
local Detail = C.DetailWindow

local P = {}
C.AdminShop = P

local PAD, T = U.PAD, U.T
local CARD_TITLE_H = U.CARD_TITLE_H
local fontH = U.fontH
local fill, border, text, textRight = U.fill, U.border, U.text, U.textRight
local fitText, textWidth, card = U.fitText, U.textWidth, U.card
local amountText, stampText = U.amountText, U.stampText
local dateText, clockText, durationText = U.dateText, U.clockText, U.durationText
local Button = U.Button
local newEntry, entryText, setEntryText, setEntryEditable = U.newEntry, U.entryText, U.setEntryText, U.setEntryEditable
local errorText, itemName, currencyName = U.adminErrorText, U.itemName, U.currencyName
local itemTexture, categoryText = U.itemTexture, U.categoryText

-- The server's own ceilings (ECShop.PRICE_MAX / CAP_MAX / QTY_MAX / ID_MAX / CATEGORY_MAX): the
-- page refuses out of range before the round trip and quotes the range it wanted. The server
-- re-validates every one of them regardless. How many rows the catalog may hold is not one of
-- them: the host sets it (ShopMaxItems) and every snapshot carries it (Page:maxItems).
local PRICE_MAX, CAP_MAX, QTY_MAX = 1000000000, 1000000, 50
local ID_MAX, CATEGORY_MAX = 32, 32

-- The five categories the shop itself pages by. Every other category the dropdown offers is one
-- the catalog on screen already uses: this page edits a SKU's category, it does not manage a
-- category system.
local BUILTIN_CATEGORIES = { "medical", "food", "material", "tool", "other" }
local DEFAULT_CATEGORY = "other"

-- The one value that means "leave this column alone" in the batch form's dropdown. A table, so no
-- category string can ever collide with it.
local MIXED = {}

-- At most this many target names are spelled out: a set of 200 SKUs is a count plus a sample, not
-- a block nobody reads.
local BATCH_NAMES_MAX = 12

local function tr(key) return getText(T .. key) end
local function lineH() return fontH.small + 6 end
local function chipH() return math.max(20, fontH.small + 6) end
local function entryH() return math.max(26, fontH.small + 12) end

local function numberHint(min, max)
    return getText(T .. "Admin_Set_NumberHint", tostring(min), tostring(max))
end

-- The script's own (untranslated) name, so a host can match what they read against the item id on
-- any language. nil when it says the same thing as the localised name.
local function itemOriginal(fullType)
    local rec = Picker.universe().byType[fullType]
    local original = rec and rec.original or nil
    if type(original) ~= "string" or original == "" or original == itemName(fullType) then return nil end
    return original
end

-- The item script's own DisplayCategory, in the words the vanilla inventory uses. A reference
-- beside the category field and nothing else: the shop's category is the admin's choice, never
-- derived from this.
local function itemDisplayCategory(fullType)
    local rec = Picker.universe().byType[fullType]
    local cat = rec and rec.category or nil
    if type(cat) ~= "string" or cat == "" then return "-" end
    return U.itemCategoryText(cat)
end

local function trimText(s)
    return string.match(tostring(s or ""), "^%s*(.-)%s*$") or ""
end

-- Every number this page edits is a whole count of coins or units: no sign, no decimals.
local function parseCount(s)
    local digits = string.match(tostring(s or ""), "^%s*(%d+)%s*$")
    if not digits then return nil end
    return tonumber(digits)
end

local function amountOr(value)
    local n = tonumber(value)
    if n == nil then return "-" end
    return amountText(math.floor(n))
end

-- A new SKU's id is offered, not imposed: derived from the fullType, made collision free against
-- the catalog that is on screen, and editable in the form before the write leaves.
local function defaultId(fullType, taken)
    local base = string.match(tostring(fullType or ""), "%.([^%.]+)$") or tostring(fullType or "")
    base = string.lower(base)
    base = string.gsub(base, "[^a-z0-9_%-]", "_")
    if base == "" then base = "item" end
    if #base > ID_MAX then base = string.sub(base, 1, ID_MAX) end
    local id, n = base, 1
    while taken[id] do
        n = n + 1
        local suffix = "_" .. tostring(n)
        id = string.sub(base, 1, ID_MAX - #suffix) .. suffix
    end
    return id
end

-- Ctrl / Shift, read the one way that still answers while a text box owns text entry: the global
-- isCtrlKeyDown / isShiftKeyDown are GameKeyboard.isKeyDown, which returns false for every key
-- while Core.currentTextEntryBox is typing (GameKeyboard.java:122-127, LuaManager.java:7187-7200)
-- -- and the search box above this list is focused exactly when an admin starts Ctrl-picking
-- rows. org.lwjglx.input.Keyboard.isKeyDown is exposed to Lua (LuaManager.java:2491), ungated
-- (Keyboard.java:232-240, straight to GLFW) and what vanilla reads modifiers with
-- (ISSetKeybindDialog.lua:108-110); ECKeyboard reads them the same way. The gated global is the
-- fallback for a build that does not expose the raw reader at all, never a substitute for it.
local function rawDown(left, right)
    if Keyboard == nil or Keyboard.isKeyDown == nil or left == nil then return nil end
    -- the call sits inside the closure, so pcall is only ever handed plain Lua
    local ok, down = pcall(function() return Keyboard.isKeyDown(left) or (right ~= nil and Keyboard.isKeyDown(right)) end)
    if not ok then return nil end
    return down == true
end

local function gatedDown(fn)
    if fn == nil then return false end
    local ok, down = pcall(fn)
    return ok and down == true
end

local function ctrlDown()
    local raw = rawDown(Keyboard and Keyboard.KEY_LCONTROL, Keyboard and Keyboard.KEY_RCONTROL)
    if raw ~= nil then return raw end
    return gatedDown(isCtrlKeyDown)
end

local function shiftDown()
    local raw = rawDown(Keyboard and Keyboard.KEY_LSHIFT, Keyboard and Keyboard.KEY_RSHIFT)
    if raw ~= nil then return raw end
    return gatedDown(isShiftKeyDown)
end

-- Missing scope retains the published per-player daily default.
local function scopeOf(value)
    if value == "global" then return "global" end
    if value == "lifetime" then return "lifetime" end
    return "player"
end

local function scopeText(scope)
    scope = scopeOf(scope)
    return tr(scope == "global" and "Admin_Shop_ScopeGlobal"
        or (scope == "lifetime" and "Admin_Shop_ScopeLifetime" or "Admin_Shop_ScopePlayer"))
end

local function scopeDailyText(scope)
    scope = scopeOf(scope)
    return tr(scope == "global" and "Admin_Shop_ScopeDailyGlobal"
        or (scope == "lifetime" and "Admin_Shop_ScopeDailyLifetime" or "Admin_Shop_ScopeDailyPlayer"))
end

-- The cap in the two units it is read in: the units the server counts, and the pieces they are.
local function capText(cap, qty)
    if cap == nil or cap <= 0 then return tr("Admin_Shop_CapNone") end
    return getText(T .. "Admin_Shop_CapSummary", tostring(cap), tostring(cap * math.max(1, qty)), tostring(qty))
end

-- ---------- quotes ----------

-- One SKU's per-currency quotes as the text the boxes hold. A currency the SKU has no quote for
-- is `exists = false` with EMPTY price and bid: no 0 is invented for it anywhere, and its two
-- direction flags are only the values a quote the admin creates would start from (sell on,
-- buyback off).
local function quoteTable(sku)
    local prices = type(sku.prices) == "table" and sku.prices or nil
    local out = {}
    for _, cur in ipairs(EC.CURRENCY_ORDER) do
        local q = prices ~= nil and type(prices[cur]) == "table" and prices[cur] or nil
        if q == nil then
            out[cur] = { exists = false, price = "", bidPrice = "", enabled = true, buyback = false }
        else
            out[cur] = {
                exists = true,
                price = tostring(math.floor(tonumber(q.price) or 0)),
                bidPrice = tostring(math.floor(tonumber(q.bidPrice) or 0)),
                enabled = q.enabled ~= false,
                buyback = q.buyback == true,
            }
        end
    end
    return out
end

local function skuQuote(sku, cur)
    local prices = type(sku.prices) == "table" and sku.prices or nil
    if prices == nil or type(prices[cur]) ~= "table" then return nil end
    return prices[cur]
end

-- Whether any currency sells this SKU, and whether any buys it back.
local function skuDirections(sku)
    local sell, buy = false, false
    for _, cur in ipairs(EC.CURRENCY_ORDER) do
        local q = skuQuote(sku, cur)
        if q ~= nil then
            if q.enabled ~= false then sell = true end
            if q.buyback == true then buy = true end
        end
    end
    return sell, buy
end

-- What one row is still doing, in the words the list uses: off the shelf, selling or with no
-- currency that sells it, and buying back. The delete confirmation names it per row, so a row
-- that is live in either direction is never removed unnoticed.
local function skuStateText(sku)
    local sell, buy = skuDirections(sku)
    local state = sku.enabled == false and "Shop_Disabled" or (sell and "Admin_Shop_QuoteSellOn" or "Admin_Shop_NoSale")
    if buy then return tr(state) .. " / " .. tr("Admin_Shop_QuoteBuyOn") end
    return tr(state)
end

-- The row's price column, language-neutral: the coin and the amount of every currency that
-- quotes this SKU (the currency order), packed right-aligned against `right`. What does not fit
-- in `room` is counted as one "+N" -- the editor and the detail window carry the whole quote
-- table -- and the first quote always shows whole. No quote at all reads "-", never a 0.
-- Returns the segments ({ cur, text, coinX, textX }, plus `more` / `moreX`) and their width.
local function rowPrices(sku, right, room, coin)
    local all = {}
    for _, cur in ipairs(EC.CURRENCY_ORDER) do
        local q = skuQuote(sku, cur)
        local price = q ~= nil and tonumber(q.price) or nil
        if price ~= nil then
            local s = { cur = cur, text = amountText(math.floor(price)) }
            s.w = coin + 4 + textWidth(s.text)
            all[#all + 1] = s
        end
    end
    local gap = 10
    local out, used = {}, 0
    for i, s in ipairs(all) do
        local add = (i > 1 and gap or 0) + s.w
        local rest = #all - i
        local tail = rest > 0 and (gap + textWidth("+" .. rest)) or 0
        if i > 1 and used + add + tail > room then break end
        out[i], used = s, used + add
    end
    if #all == 0 then
        out.more = "-"
    elseif #out < #all then
        out.more = "+" .. (#all - #out)
        used = used + gap
    end
    if out.more then used = used + textWidth(out.more) end
    local x = right - used
    for _, s in ipairs(out) do
        s.coinX, s.textX = x, x + coin + 4
        x = x + s.w + gap
    end
    if out.more then out.moreX = right - textWidth(out.more) end
    return out, used
end

-- ---------- the draft's shape ----------

-- Every editable column of one SKU as the text the boxes hold, so "did the admin change
-- anything" is one comparison against the same shape.
local function draftFromSku(sku)
    return {
        id = sku.id, item = sku.item,
        qty = tostring(math.floor(tonumber(sku.qty) or 1)),
        category = tostring(sku.category or DEFAULT_CATEGORY),
        enabled = sku.enabled ~= false,
        dailyCap = tostring(math.floor(tonumber(sku.dailyCap) or 0)),
        dailyCapScope = scopeOf(sku.dailyCapScope),
        buybackCap = tostring(math.floor(tonumber(sku.buybackCap) or 0)),
        quotes = quoteTable(sku),
    }
end

-- One column's value out of such a shape. A per-currency column reads out of that currency's
-- quote; `false` is a value, so it is never collapsed into nil by an `and/or`.
local function baseValue(base, spec)
    if base == nil then return nil end
    if spec.currency ~= nil then
        local quotes = base.quotes
        local q = quotes ~= nil and quotes[spec.currency] or nil
        if q == nil then return nil end
        return q[spec.leaf]
    end
    return base[spec.key]
end

-- ---------- native dropdown helpers ----------

-- The popup is added to the UIManager (ISComboBox.lua:200-215), so a box that is hidden, scrolled
-- out of the field area or refilled has to take its popup with it.
local function closeCombo(combo)
    if combo == nil or combo.expanded ~= true then return end
    combo.expanded = false
    if combo.popup ~= nil and combo.popup.parentCombo == combo and combo.hidePopup ~= nil then
        pcall(combo.hidePopup, combo)
    end
end

local function comboSelect(combo, data)
    for i = 1, #combo.options do
        if combo:getOptionData(i) == data then
            combo.selected = i
            return true
        end
    end
    combo.selected = 1
    return false
end

local function comboData(combo)
    if combo.selected == nil then return nil end
    return combo:getOptionData(combo.selected)
end

-- One native dropdown, skinned with the mod's own tokens (the same lines ECAdminTransactions'
-- own combo uses). A short list of words is exactly what ISComboBox is for -- and unlike a row
-- of chips it costs one control at any font size, with every option reachable from the keyboard.
local function newCombo(owner, onChange)
    local c = ISComboBox:new(0, 0, 140, entryH(), owner, onChange)
    c:initialise()
    c:instantiate()
    -- Restore the parent's stencil pixels after the native text clip (ISComboBox.lua:284-299).
    c.doRepaintStencil = true
    c.backgroundColor = U.color("well")
    c.borderColor = U.color("border")
    c.textColor = U.color("text")
    c.backgroundColorMouseOver = U.color("hover")
    return c
end

-- ISComboBox paints its selected option unfitted, so a box is measured from its own widest
-- option instead of a constant: a translated category never runs past the border.
local function comboWidth(combo, minW)
    local wanted = minW
    for i = 1, #combo.options do
        local w = textWidth(combo:getOptionText(i)) + 30
        if w > wanted then wanted = w end
    end
    return wanted
end

-- ---------- catalog row ----------

-- One SKU as two lines: icon plus localised name (and the script's own) over
-- "id / category / per-unit count", the per-currency prices and the two states on the right. The
-- row carries no control -- picking it opens the editor -- so the click test stays the list's own.
local ShopCell = ISPanel:derive("MinidoracatEconomyShopCell")

function ShopCell:render()
    local e = self.entry
    if not e then return end
    local w, h = self.width, self.height
    -- zebra / selected / hover are the shared helper's, painted once (UI.Table.rowBackground): a lit row
    -- moves the secondary lines (the script's own name, "id / category / per unit", a state that
    -- is not "listed") to the opaque text token, so the row being read is the one that reads best.
    local lit = U.framework.Table.rowBackground(self)
    -- A row in the batch set is lit the same way and carries a bar down its left edge, so the set
    -- stays readable while the highlight is on whichever row the arrows last walked to. The set is
    -- keyed by SKU id and read live off the list, so showing a pick needs no rebind.
    local picked = self.list.ecPicked
    local marked = picked ~= nil and e.id ~= nil and picked[e.id] == true
    if marked then
        if not lit then fill(self, 0, 0, w, h, "selected", "rect") end
        fill(self, 0, 0, 3, h, "accent", "rect")
    end
    local hot = lit or marked
    if e.icon then
        local ok = pcall(self.drawTextureScaled, self, e.icon, PAD, e.iconY, e.iconSize, e.iconSize, 1, 1, 1, 1)
        if not ok then e.icon = nil end
    end
    local faint = hot and "text" or "textFaint"
    text(self, e.nameText, e.nameX, e.line1Y, e.listed and "text" or faint)
    if e.altText then text(self, e.altText, e.altX, e.line1Y, faint) end
    text(self, e.metaText, e.nameX, e.line2Y, faint)
    local priceToken = e.listed and "accent" or faint
    local prices = e.prices
    for i = 1, #prices do
        local s = prices[i]
        U.drawCoin(self, s.cur, s.coinX, e.coinY, e.coin)
        text(self, s.text, s.textX, e.line1Y, priceToken)
    end
    if prices.more then text(self, prices.more, prices.moreX, e.line1Y, priceToken) end
    textRight(self, e.stateText, e.rightX, e.line2Y,
        e.listed and "positive" or (hot and "text" or "textMuted"))
    if e.buybackText then text(self, e.buybackText, e.buybackX, e.line2Y, e.buybackToken) end
end

-- ---------- the discard prompt ----------

-- An unsaved draft is never dropped by a navigation: this overlay asks, owns the whole page while
-- it is up (nothing behind it is clickable) and hands the answer back to the page.
local Confirm = ISPanel:derive("MinidoracatEconomyShopConfirm")

function Confirm:createChildren()
    local discard, keep = tr("Admin_Shop_Discard"), tr("Admin_Shop_Continue")
    self.discardButton = Button.create(0, 0, textWidth(discard) + 24, chipH(), discard, self, Confirm.onDiscard, "primary")
    self.keepButton = Button.create(0, 0, textWidth(keep) + 24, chipH(), keep, self, Confirm.onKeep, "chip")
    self:addChild(self.discardButton)
    self:addChild(self.keepButton)
end

function Confirm:onDiscard()
    local page, done = self.page, self.pendingLeave
    self:close()
    if page then page:dropDraft() end
    if done then done() end
end

function Confirm:onKeep()
    self:close()
    if self.page then self.page:layout() end
end

function Confirm:open(pendingLeave)
    self.pendingLeave = pendingLeave
    ISPanel.setVisible(self, true)
    self.discardButton:setVisible(true)
    self.keepButton:setVisible(true)
    self:layout()
    if C.Keyboard then
        pcall(C.Keyboard.focusControl, self.keepButton, true)
        pcall(C.Keyboard.invalidate, self.page and self.page.owner and self.page.owner.owner or nil)
    end
end

function Confirm:close()
    if not self:getIsVisible() then return end
    self.pendingLeave = nil
    ISPanel.setVisible(self, false)
    self.discardButton:setVisible(false)
    self.keepButton:setVisible(false)
    if C.Keyboard then
        pcall(C.Keyboard.invalidate, self.page and self.page.owner and self.page.owner.owner or nil)
    end
end

function Confirm:layout()
    local w, h = self.width, self.height
    local ch, lh = chipH(), lineH()
    -- measured in the fonts the box really paints in (the title is Medium): a prompt that asks a
    -- yes/no question must never have the question itself cut
    local titleW = textWidth(tr("Admin_Shop_DiscardTitle"), UIFont.Medium)
    local noteW = textWidth(tr("Admin_Shop_DiscardNote"))
    local roomW = math.max(120, w - PAD * 2)
    local bodyW = math.min(math.max(240, math.max(titleW, noteW) + PAD * 2), roomW)
    self.noteLines = U.wrapText(tr("Admin_Shop_DiscardNote"), bodyW - PAD * 2, 3)
    self.titleText = fitText(tr("Admin_Shop_DiscardTitle"), bodyW - PAD * 2, UIFont.Medium)
    local bodyH = CARD_TITLE_H + #self.noteLines * lh + ch + PAD * 2
    local x = math.floor((w - bodyW) / 2)
    local y = math.max(PAD, math.floor((h - bodyH) / 2))
    self.box = { x = x, y = y, w = bodyW, h = math.min(bodyH, math.max(60, h - y - PAD)) }
    self.noteY = y + CARD_TITLE_H + 6
    local buttonY = y + self.box.h - PAD - ch
    local keepW = math.min(textWidth(self.keepButton.fullTitle) + 24, math.floor(bodyW / 2) - PAD)
    local discardW = math.min(textWidth(self.discardButton.fullTitle) + 24, math.floor(bodyW / 2) - PAD)
    self.keepButton:setWidth(keepW); self.keepButton:setHeight(ch)
    self.keepButton:setX(x + PAD); self.keepButton:setY(buttonY)
    self.discardButton:setWidth(discardW); self.discardButton:setHeight(ch)
    self.discardButton:setX(x + bodyW - PAD - discardW); self.discardButton:setY(buttonY)
    U.setButtonTitle(self.keepButton, self.keepButton.fullTitle)
    U.setButtonTitle(self.discardButton, self.discardButton.fullTitle)
end

function Confirm:resize(width, height)
    if self.width ~= width then self:setWidth(width) end
    if self.height ~= height then self:setHeight(height) end
    if self:getIsVisible() then self:layout() end
end

function Confirm:prerender()
    local b = self.box
    if not b then return end
    U.theme:fill(self, 0, 0, self.width, self.height, "surface", nil, 0.75)
    U.theme:fill(self, b.x, b.y, b.w, b.h, "surface", nil, 1)
    border(self, b.x, b.y, b.w, b.h, "accent")
    text(self, self.titleText, b.x + PAD, b.y + math.floor((CARD_TITLE_H - fontH.medium) / 2), "text", UIFont.Medium)
    local y = self.noteY
    for _, line in ipairs(self.noteLines or {}) do
        text(self, line, b.x + PAD, y, "textMuted")
        y = y + lineH()
    end
end

function Confirm:render() end
function Confirm:onMouseDown() return true end
function Confirm:onMouseUp() return true end
function Confirm:onRightMouseDown() return true end
function Confirm:onRightMouseUp() return true end
function Confirm:onMouseMove() return true end
function Confirm:onMouseWheel() return true end

-- ---------- the editor's field area ----------

-- A plain host for the editor's controls with one scroll offset, so a large font (or the extra
-- groups the currencies carry) never pushes a field out of reach. The page computes every
-- position; this paints the labels and answers the keyboard's scroll contract (scrollOffset /
-- setScrollOffset / maxScrollOffset, MinidoracatUI/Focus.lua scrollBy).
local Form = ISPanel:derive("MinidoracatEconomyShopForm")

function Form:maxScrollOffset()
    return math.max(0, (self.contentH or 0) - self.height)
end

-- Native ISScrollBar speaks in negative offsets; children here are positioned explicitly.
function Form:getScrollHeight() return self.contentH or 0 end
function Form:getScrollAreaHeight() return self.height end
function Form:getYScroll() return -(self.scrollOffset or 0) end
function Form:setYScroll(value) self:setScrollOffset(-value) end

function Form:setScrollOffset(offset)
    local clamped = math.max(0, math.min(offset, self:maxScrollOffset()))
    if clamped == self.scrollOffset then return end
    self.scrollOffset = clamped
    if self.page then self.page:placeForm() end
end

-- Bring one field into the viewport, and nothing else. ecFormY / ecFormLabelY / ecFormH are set
-- for EVERY row of the open editor, whether it ended up inside the viewport or not, so a row
-- under the fold can be revealed without it ever having been visible.
--
-- What must end up visible is the CONTROL: a field the page placed (placeGroup) is only shown
-- when the whole control fits inside the viewport, so aligning a stacked row by its label -- the
-- label is a separate line above the box -- would leave the box itself hanging over the bottom
-- edge and hidden. The label comes along only when the whole row fits; otherwise the control
-- alone is what is aligned. Beyond that the scroll is minimal: a field already inside the
-- viewport does not move the form at all, one above it comes to the top edge, one below it to the
-- bottom edge. Returns whether the control is inside the viewport once this has run, so a caller
-- can tell a reveal it cannot have (no logical row recorded: the control is not part of the open
-- editor, or the viewport is shorter than one control) from one it now has.
function Form:scrollTo(control)
    if type(control) ~= "table" or control.ecFormY == nil then return false end
    local h = self.height
    local ctlTop = control.ecFormY
    local ctlBottom = ctlTop + (control.ecFormH or 0)
    -- the label is part of what is revealed only while the pair of them fits
    local top = control.ecFormLabelY or ctlTop
    if ctlBottom - top > h then top = ctlTop end
    local offset = self.scrollOffset or 0
    if ctlBottom - ctlTop >= h or top < offset then
        self:setScrollOffset(top)
    elseif ctlBottom > offset + h then
        self:setScrollOffset(ctlBottom - h)
    end
    offset = self.scrollOffset or 0
    return ctlTop >= offset and ctlBottom <= offset + h
end

function Form:onMouseWheel(del)
    self:setScrollOffset((self.scrollOffset or 0) + del * lineH() * 3)
    return true
end

function Form:prerender()
    local paint = self.paint
    if not paint then return end
    self.vscroll:updatePos()
    local c = U.color("border")
    for _, e in ipairs(paint.heads) do
        text(self, e.text, e.x, e.y, "text", UIFont.Medium)
        self:drawRect(e.x, e.y + fontH.medium + 3, e.w, 1, c.a * U.alpha, c.r, c.g, c.b)
    end
    for _, e in ipairs(paint.labels) do text(self, e.text, e.x, e.y, "textMuted") end
    for _, e in ipairs(paint.notes) do text(self, e.text, e.x, e.y, e.token) end
end

function Form:render() end

-- ---------- the page ----------

local Page = ISPanel:derive("MinidoracatEconomyAdminShopPage")

-- ----- controls -----

-- Every column one write may carry, in the order the editor shows them. The shared columns are
-- flat on the write; a currency's four are nested under prices[currency], and the `key` here
-- ("q:<currency>:<leaf>") is only what the form and the batch bookkeeping name them by. The
-- controls are created once, so a spec holds its own control: the set of currencies is
-- EC.CURRENCY_ORDER and nothing else.
function Page:buildFields()
    local fields = {}
    local function add(spec)
        fields[#fields + 1] = spec
    end
    add({ key = "qty", label = "Admin_Shop_Qty", kind = "int", min = 1, max = QTY_MAX,
        entry = true, control = self.qtyEntry })
    add({ key = "category", label = "Admin_Shop_Category", kind = "category",
        combo = true, control = self.categoryCombo })
    add({ key = "enabled", label = "Admin_Shop_Enabled", kind = "bool",
        on = "Admin_Shop_Listed", off = "Shop_Disabled", chip = true, control = self.enabledButton })
    add({ key = "dailyCap", label = "Admin_Shop_Cap", kind = "int", min = 0, max = CAP_MAX,
        entry = true, control = self.capEntry })
    add({ key = "dailyCapScope", label = "Admin_Shop_CapScope", kind = "scope",
        chip = true, control = self.scopeButton })
    add({ key = "buybackCap", label = "Admin_Shop_BuybackCap", kind = "int", min = 0, max = CAP_MAX,
        entry = true, control = self.bcapEntry })
    for _, cur in ipairs(EC.CURRENCY_ORDER) do
        local q = self.quotes[cur]
        add({ key = "q:" .. cur .. ":enabled", currency = cur, leaf = "enabled", kind = "bool",
            label = "Admin_Shop_QuoteSell", on = "Admin_Shop_QuoteSellOn", off = "Admin_Shop_QuoteSellOff",
            chip = true, control = q.sellButton })
        add({ key = "q:" .. cur .. ":price", currency = cur, leaf = "price", kind = "int",
            min = 1, max = PRICE_MAX, label = "Admin_Shop_Price", entry = true, control = q.priceEntry })
        add({ key = "q:" .. cur .. ":buyback", currency = cur, leaf = "buyback", kind = "bool",
            label = "Admin_Shop_QuoteBuy", on = "Admin_Shop_QuoteBuyOn", off = "Admin_Shop_QuoteBuyOff",
            chip = true, control = q.buyButton })
        add({ key = "q:" .. cur .. ":bidPrice", currency = cur, leaf = "bidPrice", kind = "int",
            min = 0, max = PRICE_MAX, label = "Admin_Shop_BidPrice", entry = true, control = q.bidEntry })
    end
    self.fields = fields
    self.fieldByKey = {}
    for _, spec in ipairs(fields) do self.fieldByKey[spec.key] = spec end
end

function Page:createChildren()
    local function chip(label, handler, style)
        local b = Button.create(0, 0, textWidth(label) + 24, chipH(), label, self, handler, style or "chip")
        self:addChild(b)
        return b
    end
    self.searchEntry = newEntry(220, entryH(), { maxLen = 48, clear = true, placeholder = tr("Admin_Shop_Search") })
    self.searchEntry.target = self
    self.searchEntry.onTextChangeFunction = Page.onSearch
    self:addChild(self.searchEntry)
    self.list = U.newTable(ShopCell, lineH() * 2 + 12)
    -- the row index is what a Shift range is measured in, and VirtualList hands it to onSelect
    -- (mouse press and the keyboard's Enter both come through here)
    self.list.onSelect = function(_, item, index) self:onRow(item, index) end
    -- the batch set, read straight off the list while a cell paints: one table for the page's
    -- lifetime, so a cell never holds a stale copy of it
    self.list.ecPicked = self.picked
    self:addChild(self.list)

    self.reloadButton = chip(tr("Admin_Shop_Reload"), Page.onReload)
    self.addButton = chip(tr("Admin_Shop_Add"), Page.onAdd)
    self.masterButton = chip(tr("Admin_Shop_BuybackOn"), Page.onMaster)
    self.salesButton = chip(tr("Admin_Tx_Sales"), Page.onSales)
    self.buysButton = chip(tr("Admin_Tx_Buybacks"), Page.onBuys)
    -- the two chips the batch set is operated with, and the category filter: all three are
    -- ordinary chips, so the keyboard reaches them exactly like the rest of the header
    self.batchButton = chip(tr("Admin_Shop_Batch"), Page.onBatch)
    self.clearSelButton = chip(tr("Admin_Shop_BatchClear"), Page.onClearPicks)
    -- the list's category filter: one native dropdown beside the search box (all categories, or
    -- exactly one), so every option is reachable from the keyboard at every font size
    self.catCombo = newCombo(self, Page.onCategoryFilterPicked)
    self:addChild(self.catCombo)
    self:fillFilterCombo()

    -- the editor's own controls live in the scrolling field area; Apply / Cancel / Back stay on
    -- the page, pinned under it, so the primary action never scrolls away
    self.form = ISPanel:new(0, 0, 200, 100)
    setmetatable(self.form, Form)
    self.form.background = false
    self.form.page = self
    self.form.scrollOffset = 0
    self.form:initialise()
    self.form:instantiate()
    self:addChild(self.form)
    self.form.vscroll = ISScrollBar:new(self.form, true)
    self.form.vscroll:initialise()
    self.form:addChild(self.form.vscroll)
    self.form.vscroll:setAnchorLeft(true)
    self.form.vscroll:setAnchorRight(false)
    self.form.vscroll:setAnchorBottom(false)

    local function field(opts)
        local e = newEntry(120, entryH(), opts)
        e.target = self
        e.onTextChangeFunction = Page.onFieldEdit
        self.form:addChild(e)
        return e
    end
    self.idEntry = field({ maxLen = ID_MAX })
    self.qtyEntry = field({ maxLen = 2 })
    self.capEntry = field({ maxLen = 7 })
    self.bcapEntry = field({ maxLen = 7 })

    local function formChip(label, handler)
        local b = Button.create(0, 0, textWidth(label) + 24, chipH(), label, self, handler, "chip")
        self.form:addChild(b)
        return b
    end
    self.enabledButton = formChip(tr("Admin_On"), Page.onToggleEnabled)
    self.scopeButton = formChip(tr("Admin_Shop_ScopePlayer"), Page.onToggleScope)

    -- the category dropdown: the five shop categories plus whatever the catalog already uses
    self.categoryCombo = newCombo(self, Page.onCategoryPicked)
    self.form:addChild(self.categoryCombo)

    -- one quote per currency: two prices and one switch per direction
    self.quotes = {}
    for _, cur in ipairs(EC.CURRENCY_ORDER) do
        local sell = formChip(tr("Admin_Shop_QuoteSellOn"), Page.onToggleQuoteSell)
        local buy = formChip(tr("Admin_Shop_QuoteBuyOff"), Page.onToggleQuoteBuy)
        sell.ecCurrency, buy.ecCurrency = cur, cur
        self.quotes[cur] = {
            priceEntry = field({ maxLen = 10 }),
            bidEntry = field({ maxLen = 10 }),
            sellButton = sell,
            buyButton = buy,
        }
    end

    self:buildFields()

    -- The standing rule behind six fields, as one small "?" beside its label instead of a block of
    -- prose in the form: the title stays the glyph and fullTitle is the short rule, so the mouse
    -- reads it as the button's tooltip and the keyboard ring as its caption (MinidoracatUI Focus
    -- captionOf). Pressing it opens the detail window, which keeps every rule in full
    -- (appendRuleText). A currency's two price rules sit on the first currency's columns: once,
    -- beside the quote table's column titles, or beside the first stacked group's labels.
    self.tips = {}
    local function tip(key)
        local b = formChip(tr("Admin_Shop_TipMark"), Page.onShowDetail)
        b.fullTitle = tr(key)
        self.tips[#self.tips + 1] = b
        return b
    end
    local first = EC.CURRENCY_ORDER[1]
    self.fieldByKey.qty.tip = tip("Admin_Shop_TipQty")
    self.fieldByKey.enabled.tip = tip("Admin_Shop_TipEnabled")
    self.fieldByKey.dailyCapScope.tip = tip("Admin_Shop_TipScope")
    self.fieldByKey["q:" .. first .. ":price"].tip = tip("Admin_Shop_TipPrice")
    self.fieldByKey["q:" .. first .. ":bidPrice"].tip = tip("Admin_Shop_TipBid")
    self.batchTip = tip("Admin_Shop_TipBatch")

    -- every box the editor may make editable; the id is a new SKU's alone
    self.entryFields = { self.qtyEntry, self.capEntry, self.bcapEntry }
    for _, cur in ipairs(EC.CURRENCY_ORDER) do
        self.entryFields[#self.entryFields + 1] = self.quotes[cur].priceEntry
        self.entryFields[#self.entryFields + 1] = self.quotes[cur].bidEntry
    end
    self.newFields = { self.idEntry }
    -- everything that lives inside the scrolling field area, so placeForm hides what scrolled out
    -- of it in one pass
    self.formControls = { self.idEntry }
    for _, spec in ipairs(self.fields) do self.formControls[#self.formControls + 1] = spec.control end
    for _, b in ipairs(self.tips) do self.formControls[#self.formControls + 1] = b end

    self.applyButton = chip(tr("Admin_Shop_Apply"), Page.onApply, "primary")
    self.cancelButton = chip(tr("Admin_Cancel"), Page.onCancelEdit)
    self.detailButton = chip(tr("Admin_Shop_Detail"), Page.onShowDetail)
    self.backButton = chip(tr("Admin_Shop_Back"), Page.onBack)
    -- the one irreversible action on this page: placed on the editor's title row (layout), never
    -- beside Apply, in the danger style, and it only ever opens a confirmation
    self.deleteButton = chip(tr("Admin_Shop_Delete"), Page.onDelete, "danger")
    self.editorButtons = { self.applyButton, self.cancelButton, self.detailButton, self.backButton,
        self.deleteButton }

    self.confirm = ISPanel:new(0, 0, self.width, self.height)
    setmetatable(self.confirm, Confirm)
    self.confirm.background = false
    self.confirm.page = self
    self.confirm:initialise()
    self.confirm:instantiate()
    self.confirm:setVisible(false)
    self.confirm.discardButton:setVisible(false)
    self.confirm.keepButton:setVisible(false)
    self:addChild(self.confirm)

    -- the picker is added last: it paints over everything this page owns
    self.picker = Picker.create(self, "shop",
        function(record) self:onPicked(record) end,
        function() self:onPickCancelled() end)
    self:addChild(self.picker)

    self:layout()
end

-- ----- snapshot -----

function Page:skus()
    local snap = self.catalog
    if type(snap) == "table" and type(snap.items) == "table" then return snap.items end
    return nil
end

function Page:sku(id)
    for _, s in ipairs(self:skus() or {}) do
        if s.id == id then return s end
    end
    return nil
end

function Page:takenIds()
    local taken = {}
    for _, s in ipairs(self:skus() or {}) do taken[s.id] = true end
    return taken
end

-- The effective switch the server reports, from whichever snapshot is newer to hand. nil means
-- "not known yet": the page says so instead of drawing a guess.
function Page:masterState()
    local snap = C.shop or self.catalog
    if type(snap) == "table" and type(snap.buyback) == "table" then return snap.buyback.enabled == true end
    return nil
end

-- How many rows the server lets the catalog grow to (ECShop.maxItems: the host's ShopMaxItems),
-- off the same snapshots as the switch: a settings change reaches C.shop in the push it causes.
-- nil while neither snapshot carried it.
function Page:maxItems()
    local snap = C.shop or self.catalog
    return type(snap) == "table" and tonumber(snap.maxItems) or nil
end

-- What the server said about one currency's buyback: its own switch, the caps in force and the
-- room left today. nil when no snapshot carried it -- the page says "-" rather than a 0.
function Page:buybackInfo(cur)
    local snap = C.shop or self.catalog
    if type(snap) ~= "table" or type(snap.buyback) ~= "table" then return nil end
    local by = snap.buyback.byCurrency
    if type(by) ~= "table" or type(by[cur]) ~= "table" then return nil end
    return by[cur]
end

-- Only daily modes use the server's reset time; lifetime has no scheduled reset.
-- The batch/page overview passes no scope and labels this explicitly as the daily reset.
function Page:resetNote(scope)
    if scope ~= nil and scopeOf(scope) == "lifetime" then return tr("Admin_Shop_NoReset") end
    local snap = self.catalog
    local ends = type(snap) == "table" and tonumber(snap.dayEndsMs) or nil
    if ends == nil then return tr("Admin_Shop_ResetUnknown") end
    local off = self.owner.offsetMin
    return getText(T .. "Admin_Shop_ResetAt", dateText(ends, off), clockText(ends, off),
        durationText(math.max(0, ends - EC.now())))
end

-- ----- the draft -----

-- Dirty is one comparison against the base the editor opened on, column by column: the numbers
-- exactly as they are typed, the switches, the category and every currency's quote. The batch
-- form answers for itself: any column whose value is no longer what every picked row already
-- holds -- an explicit switch, a typed number, an emptied box -- is all a leave has to ask about.
function Page:isDirty()
    if self.batch ~= nil then return self:batchDirty() end
    local d = self.draft
    if d == nil then return false end
    if d.isNew then return true end   -- a SKU that was never saved is a draft by itself
    local base = self.draftBase
    if base == nil then return false end
    for _, spec in ipairs(self.fields) do
        local now, was = self:draftValue(spec), baseValue(base, spec)
        if spec.entry then
            if tostring(now or "") ~= tostring(was or "") then return true end
        elseif now ~= was then
            return true
        end
    end
    return false
end

-- The value one column holds on screen right now. A number is whatever its box holds (a string,
-- exactly as typed); everything else lives in the draft, per currency where it belongs.
function Page:draftValue(spec)
    if spec.entry then return trimText(entryText(spec.control)) end
    local d = self.draft
    if d == nil then return nil end
    if spec.currency ~= nil then
        local q = d.quotes[spec.currency]
        if q == nil then return nil end
        return q[spec.leaf]
    end
    return d[spec.key]
end

-- One currency's column, word order left to the translation ("%1 (%2)": field, currency).
local function curLabel(cur, key)
    return getText(T .. "Admin_Audit_FieldCur", tr(key), currencyName(cur))
end

function Page:specLabel(spec)
    if spec.currency ~= nil then return curLabel(spec.currency, spec.label) end
    return tr(spec.label)
end

-- A currency is offered exactly while its price box holds something. An empty box is "no quote":
-- not a free item, not a 0, and its two direction switches are not readable values at all.
function Page:quoteOffered(cur)
    return trimText(entryText(self.quotes[cur].priceEntry)) ~= ""
end

-- One column turned into the value that would travel, plus how it reads on screen and -- when it
-- cannot travel -- the range or rule it wanted. A nil first return means "nothing to write here".
function Page:specOut(spec, value)
    if value == nil then return nil, nil, nil end
    if spec.kind == "int" then
        local raw = tostring(value)
        if raw == "" then return nil, nil, nil end
        local n = parseCount(raw)
        local min, max = spec.min or 0, spec.max or PRICE_MAX
        if n == nil or n < min or n > max then return nil, nil, numberHint(min, max) end
        return n, amountText(n)
    end
    if spec.kind == "scope" then return scopeOf(value), scopeText(value) end
    if spec.kind == "bool" then return value == true, tr(value == true and spec.on or spec.off) end
    if value == MIXED then return nil, nil, nil end
    local s = trimText(tostring(value))
    if s == "" or #s > CATEGORY_MAX then return nil, nil, tr("Admin_Shop_CatInvalid") end
    return s, categoryText(s)
end

function Page:fillEntries(d)
    setEntryText(self.idEntry, d.id)
    setEntryText(self.qtyEntry, d.qty)
    setEntryText(self.capEntry, d.dailyCap)
    setEntryText(self.bcapEntry, d.buybackCap)
    for _, cur in ipairs(EC.CURRENCY_ORDER) do
        local q, ctl = d.quotes[cur], self.quotes[cur]
        setEntryText(ctl.priceEntry, q.price)
        setEntryText(ctl.bidEntry, q.bidPrice)
    end
    self:fillCategoryCombo(d.category, false)
end

-- The categories the dropdown offers: the five the shop pages by, then every other category the
-- catalog on screen uses, so an existing custom category can be picked again without this page
-- becoming a category manager.
function Page:categoryKeys()
    local keys, seen = {}, {}
    for _, key in ipairs(BUILTIN_CATEGORIES) do
        keys[#keys + 1] = key
        seen[key] = true
    end
    local extra = {}
    for _, sku in ipairs(self:skus() or {}) do
        local key = tostring(sku.category or DEFAULT_CATEGORY)
        if not seen[key] then
            seen[key] = true
            extra[#extra + 1] = key
        end
    end
    EC.sortSafe(extra, function(a, b) return a < b end)
    for _, key in ipairs(extra) do keys[#keys + 1] = key end
    return keys
end

local function keySignature(keys)
    return table.concat(keys, "\1")
end

-- Refill the dropdown and land it on the value in force. `allowMixed` is the batch form's own
-- first option: a column the picked rows disagree on starts on "leave it alone", and that is the
-- only way a category column can be left untouched.
function Page:fillCategoryCombo(selected, allowMixed)
    local combo = self.categoryCombo
    closeCombo(combo)
    combo:clear()
    if allowMixed then combo:addOptionWithData(tr("Admin_Shop_BatchMixed"), MIXED) end
    local keys = self:categoryKeys()
    local found = false
    for _, key in ipairs(keys) do
        combo:addOptionWithData(categoryText(key), key)
        if key == selected then found = true end
    end
    -- a SKU whose category the catalog no longer holds is still its own option: the editor must
    -- be able to show what the row really is
    if type(selected) == "string" and not found then
        combo:addOptionWithData(categoryText(selected), selected)
    end
    self.catSignature = keySignature(keys)
    comboSelect(combo, selected == nil and MIXED or selected)
end

-- A catalog push may add or drop a category while the page is open. Both dropdowns follow it --
-- the filter above the list and the editor's own -- and neither value in force moves.
function Page:syncCategoryCombo()
    local signature = keySignature(self:categoryKeys())
    if self.catFilterSignature ~= signature then self:fillFilterCombo() end
    if self.draft == nil and self.batch == nil then return end
    if self.catSignature == signature then return end
    if self.batch ~= nil then
        local spec = self.fieldByKey.category
        self:fillCategoryCombo(self:batchValue(spec), self.batch.start.category == nil)
    else
        self:fillCategoryCombo(self.draft.category, false)
    end
end

-- Open the editor on one SKU of the snapshot. draftBase is the copy every "did anything change"
-- question is answered against, so a catalog that moves underneath is noticed (baseMoved) instead
-- of quietly becoming the thing the admin is believed to have typed.
function Page:startEdit(id)
    local sku = self:sku(id)
    if sku == nil then return false end
    local d = draftFromSku(sku)
    self.batch = nil          -- one editor at a time: the batch form is not a second draft
    self.batchSent = nil
    self.draft = d
    self.draftBase = draftFromSku(sku)
    self.draftRevision = self.catalog.revision
    self.selectedId = id
    self.baseMoved = false
    self.saveError = nil
    self:fillEntries(d)
    self.view = "editor"
    self.form.scrollOffset = 0
    return true
end

function Page:startNew(record)
    local quotes = {}
    for _, cur in ipairs(EC.CURRENCY_ORDER) do
        -- no price is typed yet, so no currency is offered yet: the admin fills in the one (or
        -- both) they mean to sell for, and typing a price is what creates that quote
        quotes[cur] = { exists = false, price = "", bidPrice = "", enabled = true, buyback = false }
    end
    local d = {
        isNew = true, id = defaultId(record.fullType, self:takenIds()), item = record.fullType,
        qty = "1", category = DEFAULT_CATEGORY, enabled = true, dailyCapScope = "player",
        dailyCap = "0", buybackCap = "0", quotes = quotes,
    }
    self.batch = nil
    self.batchSent = nil
    self.draft = d
    self.draftBase = nil
    self.draftRevision = self.catalog.revision
    self.selectedId = nil
    self.cursorId = nil       -- a SKU that is not in the list yet owns no row
    self.baseMoved = false
    self.saveError = nil
    self:fillEntries(d)
    self.list:setSelectedIndex(nil)
    self.view = "editor"
    self.form.scrollOffset = 0
end

function Page:unfocusFields()
    for _, e in ipairs(self.entryFields) do pcall(e.unfocus, e) end
    for _, e in ipairs(self.newFields) do pcall(e.unfocus, e) end
    closeCombo(self.categoryCombo)
end

function Page:unfocusAll()
    self:unfocusFields()
    pcall(self.searchEntry.unfocus, self.searchEntry)
end

-- Drop whatever the editor holds -- one SKU's draft or the batch form. Only a confirmed discard,
-- a successful save and the permission collapse reach this. The batch *set* is not a draft: it
-- survives, so a refused write can be tried again on the same rows.
function Page:dropDraft()
    self.draft = nil
    self.draftBase = nil
    self.draftRevision = nil
    self.batch = nil
    self.batchSent = nil
    self.baseMoved = false
    self.saveError = nil
    self.view = "list"
    self:unfocusFields()
    self:layout()
end

-- ----- the batch set -----

-- Picking is by SKU id, not by row index: a catalog push that reorders or filters the list leaves
-- the set pointing at the same SKUs. Reading it back is always in catalog order, so the write and
-- everything on screen name the rows in the order the admin sees them. `set` lets a candidate set
-- be ordered before it is committed.
function Page:pickIds(set)
    set = set or self.picked
    local ids = {}
    for _, sku in ipairs(self:skus() or {}) do
        if set[sku.id] == true then ids[#ids + 1] = sku.id end
    end
    return ids
end

-- The set, replaced whole. The table itself is never swapped: the list paints the marks straight
-- off it.
function Page:setPicks(ids)
    for id in pairs(self.picked) do self.picked[id] = nil end
    self.pickedCount = 0
    for _, id in ipairs(ids) do
        if self.picked[id] == nil then
            self.picked[id] = true
            self.pickedCount = self.pickedCount + 1
        end
    end
end

-- The explicit way out, on a chip of its own so the set is never something only a modifier can
-- undo. Never while the batch form is open: that form has its own Cancel and Back.
function Page:clearPicks()
    if self.pickedCount == 0 then return end
    for id in pairs(self.picked) do self.picked[id] = nil end
    self.pickedCount = 0
    self.pickAnchor = nil
end

function Page:onClearPicks()
    if self.batch ~= nil then return end
    self:clearPicks()
    self:layout()
end

-- ----- filtering -----

-- A filter that hides rows must not leave them in the batch set: the next write would change SKUs
-- the admin cannot see. While the batch form is up its targets are already fixed, so both filters
-- are frozen with them (updateEnabled greys the box and the chip out) instead of quietly hiding a
-- target.
function Page:onSearch()
    if self.batch ~= nil then
        setEntryText(self.searchEntry, self.searchSeen or "")
        return
    end
    self.searchSeen = entryText(self.searchEntry)
    if self.pickedCount > 0 then self:clearPicks() end
    self:rebuildRows()
end

function Page:clearCategoryFilter()
    self.catFilterKey = nil
    if self.catCombo ~= nil then comboSelect(self.catCombo, "") end
end

-- "All categories" plus every category the catalog uses. Refilled whenever that set moves; the
-- category in force keeps its own option even after the last SKU using it is gone, so the filter
-- can never widen itself behind the admin's back.
function Page:fillFilterCombo()
    local combo = self.catCombo
    closeCombo(combo)
    combo:clear()
    combo:addOptionWithData(tr("Admin_Shop_CatAll"), "")
    local keys = self:categoryKeys()
    local found = false
    for _, key in ipairs(keys) do
        combo:addOptionWithData(categoryText(key), key)
        if key == self.catFilterKey then found = true end
    end
    if type(self.catFilterKey) == "string" and not found then
        combo:addOptionWithData(categoryText(self.catFilterKey), self.catFilterKey)
    end
    self.catFilterSignature = keySignature(keys)
    comboSelect(combo, self.catFilterKey or "")
end

-- The category in force changed: exactly the same safety as the search box, because it hides rows
-- the same way -- the picked set is dropped, because a row that scrolled out of the filter is not
-- something to be edited by accident. While a batch form is up the filter is frozen with its
-- targets: the dropdown is disabled, and a selection that still arrived is put back.
function Page:onCategoryFilterPicked(combo)
    if self.batch ~= nil then
        comboSelect(combo, self.catFilterKey or "")
        return
    end
    local data = comboData(combo)
    local key = (type(data) == "string" and data ~= "") and data or nil
    if key == self.catFilterKey then return end
    self.catFilterKey = key
    if self.pickedCount > 0 then self:clearPicks() end
    self:layout()
end

-- Whether a SKU survives the filter in force: no category picked means every category.
function Page:categoryAllowed(category)
    if self.catFilterKey == nil then return true end
    return tostring(category or DEFAULT_CATEGORY) == self.catFilterKey
end

-- ----- actions -----

-- Where a SKU id sits in the list as it is filtered now. The range anchor and the keyboard's
-- current row are both ids: a stored row index would point at another SKU as soon as a catalog
-- push reordered the list or a filter changed under it.
function Page:rowIndex(id)
    if id == nil then return nil end
    for i, row in ipairs(self.rows) do
        if row.id == id then return i end
    end
    return nil
end

-- What a modifier pick starts from: the marked set, or -- when nothing is marked and one SKU is
-- open in the editor -- that SKU. Opening a row and then Ctrl-picking a second one means both of
-- them, which is what an admin who can see the first one on the right has every reason to expect.
function Page:seedPicks()
    local ids = self:pickIds()
    if #ids == 0 and self.batch == nil and self.draft ~= nil and self.draft.isNew ~= true
        and self:sku(self.draft.id) ~= nil then
        ids[1] = self.draft.id
    end
    return ids
end

local function sameIds(a, b)
    if a == nil or #a ~= #b then return false end
    for i = 1, #a do
        if a[i] ~= b[i] then return false end
    end
    return true
end

-- Every change of the picked set goes through here, because the set is what the editor edits:
-- two or more rows ARE the batch form -- no second chip to press, which is the whole of "I picked
-- three rows and my change only reached one of them" -- and a plain pick is that one row's
-- editor. `openId` marks a plain pick: it drops the set and opens that row.
--
-- Unsaved work is asked about first (requestLeave), and a refusal leaves BOTH the editor and the
-- set exactly as they were: the pick is only written once the navigation is really allowed. A
-- save still in flight blocks it the same way, so a reply can never land on a target the form has
-- since been pointed at. A pick that leaves the editor on the very thing it already holds --
-- pressing the open row again, taking the same Shift range again, marking a row while a single
-- SKU stays open -- is not a navigation at all: it never asks, because there is nothing it could
-- lose.
function Page:choosePicks(ids, anchor, openId)
    local hadIds = self.batch ~= nil and self.batch.ids or nil
    local kept
    if openId ~= nil then
        kept = self.batch == nil and self.draft ~= nil and self.draft.isNew ~= true
            and self.draft.id == openId
    elseif #ids > 1 then
        kept = sameIds(hadIds, ids)
    else
        kept = hadIds == nil          -- the editor is not the batch form: the marks alone move
    end
    local function commit()
        self:setPicks(openId ~= nil and {} or ids)
        self.pickAnchor = anchor
        if openId ~= nil then
            -- the row already open keeps its draft: a press on it is "show me the editor", never
            -- a reason to re-read the SKU under the typing
            if not kept then self:startEdit(openId) end
            self.view = "editor"
        elseif #ids > 1 then
            -- the same rows again (a repeated Shift range) is not a reason to throw the form
            -- away; anything else is a new set to edit. Read off the live form, because a
            -- confirmed discard has already closed whatever was open.
            if self.batch == nil or not sameIds(self.batch.ids, ids) then self:startBatch(ids) end
        elseif hadIds ~= nil then
            -- the form was opened on a set that is not the set any more
            if #ids == 1 then self:startEdit(ids[1]) else self:dropDraft() end
        end
        self:layout()
    end
    if kept or not self:isDirty() then commit() else self:requestLeave(commit) end
end

-- One press on a row, from the mouse or from the keyboard's Enter (both arrive here through
-- VirtualList's onSelect, so the modifiers decide the same thing either way):
--   Ctrl   toggle this row in the set
--   Shift  take the range from the anchor over the list *as it is filtered now*
--   plain  drop the set and open this one row
-- Whatever the set becomes, the editor follows it: two or more rows are edited as a batch.
function Page:onRow(item, index)
    if item == nil or item.id == nil then return end
    self.cursorId = item.id     -- where the keyboard is, whichever branch below runs
    if type(index) == "number" and (ctrlDown() or shiftDown()) then
        local set = {}
        for _, id in ipairs(self:seedPicks()) do set[id] = true end
        local anchor = shiftDown() and self:rowIndex(self.pickAnchor) or nil
        if anchor ~= nil then
            local from, to = anchor, index
            if from > to then from, to = to, from end
            for i = from, to do
                local row = self.rows[i]
                if row ~= nil then set[row.id] = true end
            end
            return self:choosePicks(self:pickIds(set), self.pickAnchor, nil)
        end
        set[item.id] = set[item.id] ~= true or nil
        return self:choosePicks(self:pickIds(set), item.id, nil)
    end
    return self:choosePicks({ item.id }, item.id, item.id)
end

-- The gate every navigation goes through, and the controller's own hook: leaving the Shop tab
-- and closing the window ask here first. Pristine passes straight, a save in flight stays put
-- (the answer decides what the draft becomes), a dirty draft asks. A forced permission loss does
-- NOT come here -- that goes through clear().
function Page:requestLeave(callback)
    if not self:isDirty() then
        callback()
        return
    end
    if self.saveRequestId ~= nil then
        self.owner.message = { text = tr("Admin_Shop_SavePending"), error = true }
        return
    end
    self.confirm:open(callback)
    self:layout()
end

function Page:onBack()
    self:requestLeave(function() self:dropDraft() end)
end

-- What stops a new SKU right now, as the refusal the page shows, or nil. The limit is the host's,
-- and the server refuses past it anyway (catalog_full): this only saves the picker round trip and
-- says where the limit is set.
function Page:addRefusal()
    if self.catalog == nil then return tr("Admin_Loading") end
    if not self.owner:writeAllowed() then return errorText("forbidden") end
    local rows, max = self:skus(), self:maxItems()
    if rows ~= nil and max ~= nil and #rows >= max then
        return getText(T .. "Admin_Shop_Full", tostring(max), tostring(EC.OPTION_BY_KEY.ShopMaxItems.max))
    end
    return nil
end

function Page:onAdd()
    if self.catalog == nil then return end
    local refusal = self:addRefusal()
    if refusal then
        self.owner.message = { text = refusal, error = true }
        return
    end
    self:requestLeave(function()
        self.picker:open()
        self:layout()
    end)
end

-- An item dragged onto the page or sent from the item menu: the same new SKU the picker makes,
-- with the same checks and the same draft guard, without the search.
function Page:addRecord(record)
    local refusal = self:addRefusal()
    if refusal then
        self.owner.message = { text = refusal, error = true }
        return
    end
    self:requestLeave(function()
        if self.picker:isOpen() then self.picker:close() end
        self:onPicked(record)
    end)
end

-- What Delete removes: the batch set, or the one existing SKU open in the editor. A new SKU's
-- draft has no row to remove. nil when there is nothing to remove.
function Page:deleteTargets()
    if self.batch ~= nil then return self.batch.ids end
    local d = self.draft
    if d == nil or d.isNew == true or self:sku(d.id) == nil then return nil end
    return { d.id }
end

-- Delete only ever asks. The confirmation names the rows it removes and what each is still doing
-- (selling, buying back), says what removal does and does not touch, and takes a reason like every
-- other destructive admin write. The write leaves from that dialog (ECAdminPanel, catalogRemove)
-- against the revision of the catalog on screen: a catalog another admin changed meanwhile is
-- refused (catalog_stale) instead of losing rows the admin never saw.
function Page:onDelete()
    local ids = self:deleteTargets()
    if ids == nil or #ids == 0 or self.catalog == nil then return end
    if not self.owner:writeAllowed() then
        self.owner.message = { text = errorText("forbidden"), error = true }
        return
    end
    if self.saveRequestId ~= nil then
        self.owner.message = { text = tr("Admin_Shop_SavePending"), error = true }
        return
    end
    -- the same refusal applyBatch gives: the set may point at rows another admin removed
    local missing = 0
    for _, id in ipairs(ids) do
        if self:sku(id) == nil then missing = missing + 1 end
    end
    if missing > 0 then
        self.owner.message = { text = getText(T .. "Admin_Shop_BatchMissing", tostring(missing)), error = true }
        return
    end
    local lines = { getText(T .. "Admin_Shop_DeleteWarn", tostring(#ids)) }
    local shown = math.min(#ids, BATCH_NAMES_MAX)
    for i = 1, shown do
        local sku = self:sku(ids[i])
        lines[#lines + 1] = getText(T .. "Admin_Shop_DeleteRow", tostring(ids[i]), itemName(sku.item), skuStateText(sku))
    end
    if #ids > shown then lines[#lines + 1] = getText(T .. "Admin_Shop_BatchMore", tostring(#ids - shown)) end
    lines[#lines + 1] = ""
    lines[#lines + 1] = tr("Admin_Shop_DeleteNote")
    if self:isDirty() then lines[#lines + 1] = tr("Admin_Shop_DeleteDraft") end
    self.owner:openDialog("catalogRemove", {
        title = getText(T .. "Admin_Shop_DeleteTitle", tostring(#ids)),
        confirm = tr("Admin_Shop_DeleteConfirm"),
        warn = table.concat(lines, "\n"),
        catalogIds = ids,
        catalogRevision = self.catalog.revision, danger = true,
    })
end

function Page:onPicked(record)
    self:startNew(record)
    self:layout()
end

function Page:onPickCancelled()
    self:layout()
    if C.Keyboard then C.Keyboard.refocus(self.addButton) end
end

function Page:onReload()
    self.owner:sendCatalog({ action = "reload" }, nil)
end

-- The master switch is the sandbox option, and the page shows what the server says it is: the
-- click asks for the other state and nothing changes on screen until the reply lands.
function Page:onMaster()
    local enabled = self:masterState()
    if enabled == nil then return end
    self.owner:sendOption("ShopBuybackEnabled", not enabled, nil)
end

-- The money page filtered to what the system sold, or to what it bought back. The context is
-- what the editor on the right is *showing*: an existing item's draft narrows the read to that
-- very item, and it travels as the money page's own `item` filter -- the exact fullType the
-- server matches a posting's item against, not a name to be searched for (a localised name would
-- match nothing, and a keyword would match every SKU whose text happens to contain it).
--
-- The list's selection is deliberately NOT the source: a search that filters the left column
-- empty leaves the item on the right open and being worked on, and that shortcut still belongs
-- to it. Only a page with no existing-item editor context -- nothing open, or a new item's draft,
-- which has no catalog row at all -- reads the whole group.
function Page:txContext()
    local d = self.draft
    if d == nil or d.isNew == true then return nil end
    if type(d.item) ~= "string" or d.item == "" then return nil end
    return d.item
end

-- Match the visible editor context; the filters narrow the list, not this shortcut.
function Page:refreshTxHint()
    local context = self:txContext()
    local hint = context and getText(T .. "Admin_Shop_TxItem", itemName(context)) or nil
    for _, b in ipairs({ self.salesButton, self.buysButton }) do
        b.tooltip = hint
        b.autoTooltip = nil
    end
end

function Page:onSales()
    self.owner:showTransactions("shop_buy", { item = self:txContext() })
end

function Page:onBuys()
    self.owner:showTransactions("shop_sell", { item = self:txContext() })
end

-- Typing only moves the draft; nothing is sent until Apply. The line over the form, the pinned
-- identity block, the switches that follow a price box and the state of Apply / Cancel follow the
-- keystroke, and nothing else does: a full layout on every key would re-place (and blink) the
-- very box being typed into.
function Page:onFieldEdit()
    self:refreshNote()
    self:refreshIdent()
    self:refreshEditorChips()
    self:updateEnabled()
    -- Live summaries follow each edit; keep its native input visible if they grow above it.
    self:buildDetailText()
    self:placeForm(true)
end

function Page:onToggleEnabled()
    if self.batch ~= nil then return self:cycleBatchValue("enabled") end
    if self.draft == nil then return end
    self.draft.enabled = not self.draft.enabled
    self:layout()
end

function Page:onToggleScope()
    if self.batch ~= nil then return self:cycleBatchValue("dailyCapScope") end
    local d = self.draft
    if d == nil then return end
    local scope = scopeOf(d.dailyCapScope)
    d.dailyCapScope = scope == "player" and "global" or (scope == "global" and "lifetime" or "player")
    self:layout()
end

-- One direction of one currency. A currency with no price typed has no direction to switch: the
-- chip is disabled and says "not offered", so an "off" is never mistaken for "no quote".
function Page:onToggleQuoteSell(button)
    local cur = button.ecCurrency
    if cur == nil then return end
    if self.batch ~= nil then return self:cycleBatchValue("q:" .. cur .. ":enabled") end
    local d = self.draft
    if d == nil or not self:quoteOffered(cur) then return end
    local q = d.quotes[cur]
    q.enabled = not (q.enabled == true)
    self:layout()
end

function Page:onToggleQuoteBuy(button)
    local cur = button.ecCurrency
    if cur == nil then return end
    if self.batch ~= nil then return self:cycleBatchValue("q:" .. cur .. ":buyback") end
    local d = self.draft
    if d == nil or not self:quoteOffered(cur) then return end
    local q = d.quotes[cur]
    q.buyback = not (q.buyback == true)
    self:layout()
end

function Page:onCategoryPicked(combo)
    local data = comboData(combo)
    if self.batch ~= nil then
        -- MIXED is the batch form's "leave it alone": stored as the sentinel, read back as nil
        self.batch.value.category = data == nil and MIXED or data
        self:layout()
        return
    end
    if self.draft == nil or data == nil or data == MIXED then return end
    self.draft.category = data
    self:layout()
end

function Page:onCancelEdit()
    if self.batch ~= nil then
        -- back to "nothing marked", on the same rows: the batch equivalent of re-reading the SKU
        self:startBatch(self.batch.ids)
        self:layout()
        return
    end
    local d = self.draft
    if d == nil or d.isNew or not self:startEdit(d.id) then self:dropDraft()
    else self:layout() end
end

-- The read-only side of one SKU -- everything the row had to cut, plus the batch's whole target
-- list -- belongs in the shared detail window: it is dragged, scrolled, copied whole and closed
-- like any other window, and the editor keeps every field it edits. The form never gives up a
-- control for it, and the identity block over the form says the same four things without it.
function Page:detailKey()
    local b = self.batch
    if b ~= nil then return "batch:" .. table.concat(b.ids, ",") end
    local d = self.draft
    if d == nil then return nil end
    return "sku:" .. (d.isNew and "new" or tostring(d.id))
end

function Page:detailWindowTitle()
    local b = self.batch
    if b ~= nil then return getText(T .. "Admin_Shop_BatchTitle", tostring(#b.ids)) end
    local d = self.draft
    if d == nil then return tr("Admin_Shop_Detail") end
    return d.isNew and tr("Admin_Shop_NewTitle") or itemName(d.item)
end

-- The chip is the only thing that opens it.
function Page:onShowDetail()
    local key = self:detailKey()
    if key == nil or self.detailText == nil then return end
    Detail.open(self, key, self:detailWindowTitle(), self.detailText, nil, self.detailCard)
end

-- The window follows what the editor holds: a typed cap, a marked batch column, a catalog push
-- another admin caused. It is never opened from here -- a window the admin closed stays closed
-- -- and a window that was describing a row the editor has since left is closed instead of
-- quietly going on describing it.
function Page:refreshDetailWindow()
    local key = self:detailKey()
    if key ~= nil and Detail.isOpen(self, key) then
        Detail.update(self, key, self:detailWindowTitle(), self.detailText, self.detailCard)
        return
    end
    Detail.close(self)
end

-- ----- the batch form -----

-- What the picked rows already hold, per column: a value when every one of them agrees, nil when
-- they do not. This is the whole difference between "the admin left it alone" and "the admin
-- wants a 0 / an off" -- a column they disagree on starts empty and stays empty until it is set.
-- Every value here is a string or a boolean, so nil can only ever mean "they disagree".
function Page:batchBase(ids)
    -- `quoted[cur]`: does any picked row quote that currency at all? A currency none of them
    -- quotes shows "not offered", the way the single editor does, not the switches' defaults.
    local base = { count = 0, missing = 0, values = {}, quoted = {} }
    for _, id in ipairs(ids) do
        local sku = self:sku(id)
        if sku == nil then
            base.missing = base.missing + 1
        else
            local row = draftFromSku(sku)
            base.count = base.count + 1
            for _, cur in ipairs(EC.CURRENCY_ORDER) do
                if skuQuote(sku, cur) ~= nil then base.quoted[cur] = true end
            end
            for _, spec in ipairs(self.fields) do
                local value = baseValue(row, spec)
                if base.count == 1 then base.values[spec.key] = value
                elseif base.values[spec.key] ~= value then base.values[spec.key] = nil end
            end
        end
    end
    return base
end

-- Open the batch form on a fixed set of ids. Every column starts on what the picked rows already
-- hold (so the admin reads what they are changing *from*), a column they disagree on is left
-- empty and says so, and only a column that is really moved off that start travels.
--
-- `start` is that opening value, frozen: the boxes keep what they were given, so the switches and
-- the dropdown must too. A catalog another admin pushed moves `base` (what the rows hold *now*,
-- which is all the "this would change nothing" test needs) and says so on screen -- it may never
-- turn a column nobody touched into a write.
function Page:startBatch(ids)
    -- the filters are frozen with the set: a search still being typed into, or the category
    -- dropdown, must not go on hiding rows this write is about to change. The dropdown's popup is
    -- dropped here too -- it floats over the whole UI, and the box behind it is about to go grey.
    pcall(self.searchEntry.unfocus, self.searchEntry)
    closeCombo(self.catCombo)
    local base = self:batchBase(ids)
    self.draft = nil
    self.draftBase = nil
    self.draftRevision = nil
    self.batchSent = nil
    self.selectedId = nil     -- no single row is being edited: the set is what is on screen
    local start = {}
    for _, spec in ipairs(self.fields) do start[spec.key] = base.values[spec.key] end
    self.batch = { ids = ids, base = base, start = start, value = {} }
    self.batchRevision = self.catalog and self.catalog.revision or nil
    self.baseMoved = false
    self.saveError = nil
    for _, spec in ipairs(self.fields) do
        if spec.entry then setEntryText(spec.control, start[spec.key] or "") end
    end
    setEntryText(self.idEntry, "")
    self:fillCategoryCombo(start.category, start.category == nil)
    self.view = "editor"
    self.form.scrollOffset = 0
end

function Page:onBatch()
    if self.catalog == nil or self.pickedCount == 0 or self.batch ~= nil then return end
    if not self.owner:writeAllowed() then
        self.owner.message = { text = errorText("forbidden"), error = true }
        return
    end
    local ids = self:pickIds()
    if #ids == 0 then return end
    -- the open draft is asked about first: a batch is a navigation like any other
    self:requestLeave(function()
        self:startBatch(ids)
        self:layout()
    end)
end

-- The value a column shows, and would write. A number column is whatever its box holds right now
-- (empty means "nothing left to write here": nil, never 0); a switch or the dropdown is what the
-- admin set explicitly, or -- while they set nothing -- the value the form opened on. Never a
-- fallback 0 or false, and never a value a background push slid under the admin's hand.
function Page:batchValue(spec)
    local b = self.batch
    if b == nil then return nil end
    if spec.entry then
        local typed = trimText(entryText(spec.control))
        if typed == "" then return nil end
        return typed
    end
    local set = b.value[spec.key]
    if set ~= nil then
        if set == MIXED then return nil end
        return set
    end
    return b.start[spec.key]
end

-- A switch column: press it and it says what it will write. Pressing it IS asking for it -- no
-- second switch marks the column -- so on a column the picked rows agree on the presses walk
-- through its states, and on one they disagree on the walk ends on "leave it alone", so the way
-- back to touching nothing is always a press away. A blank can never turn into an accidental
-- activation of the whole set: the first press from "mixed" is the safe state -- off, and the
-- per-player daily cap. The scope walks all three modes (per player -> whole server -> per
-- player for good) before it comes back round.
function Page:cycleBatchValue(key)
    local b = self.batch
    if b == nil then return end
    local spec = self.fieldByKey[key]
    if spec == nil then return end
    local current = self:batchValue(spec)
    local mixed = b.start[key] == nil
    if spec.kind == "scope" then
        local scope = current ~= nil and scopeOf(current) or nil
        if scope == nil then b.value[key] = "player"
        elseif scope == "player" then b.value[key] = "global"
        elseif scope == "global" then b.value[key] = "lifetime"
        elseif mixed then b.value[key] = MIXED
        else b.value[key] = "player" end
    elseif current == nil then
        b.value[key] = false
    elseif current ~= true then
        b.value[key] = true
    elseif mixed then
        b.value[key] = MIXED
    else
        b.value[key] = false
    end
    self:layout()
end

-- The columns that really travel. Two questions, two baselines:
--   did the admin move this column at all -- against `start`, what the form opened on, so a
--     catalog another admin pushed can never make an untouched column into a write; and
--   would writing it change anything -- against `base`, what the picked rows hold right now, so
--     a column that already holds the typed value is dropped instead of written back.
-- Editing a column is the whole of "apply it": a box that was typed into, a switch that was
-- pressed, a category that was chosen. `false` and `0` are values like any other -- the
-- comparison is against a value, never against a blank -- so "turn this whole set off" is a write
-- of false while "they are all off already" is nothing at all.
--
-- Returns the write's field table (shared columns flat, a currency's nested under
-- prices[currency]), the summary lines, the first column that was moved but has no usable value
-- (an emptied, unreadable or out-of-range box) together with the hint it wanted, and how many
-- columns were touched at all.
function Page:batchChanges()
    local b = self.batch
    if b == nil then return nil, {}, nil, 0 end
    local fields, lines, blank, touched = {}, {}, nil, 0
    local prices = nil
    for _, spec in ipairs(self.fields) do
        local start, value = b.start[spec.key], self:batchValue(spec)
        local moved
        if spec.entry then
            -- a box the admin emptied is not a 0: it is a column with no value left to write
            moved = (value or "") ~= (start or "")
        else
            moved = value ~= start
        end
        if moved then
            touched = touched + 1
            local out, shown, hint = self:specOut(spec, value)
            local live = b.base.values[spec.key]
            if out == nil then
                blank = blank or { spec = spec, hint = hint }
            else
                local same
                if spec.kind == "int" then same = live ~= nil and tostring(live) == tostring(out)
                else same = live ~= nil and live == out end
                if not same then
                    if spec.currency ~= nil then
                        prices = prices or {}
                        prices[spec.currency] = prices[spec.currency] or {}
                        prices[spec.currency][spec.leaf] = out
                    else
                        fields[spec.key] = out
                    end
                    lines[#lines + 1] = self:specLabel(spec) .. ": " .. shown
                end
            end
        end
    end
    fields.prices = prices
    return fields, lines, blank, touched
end

-- Any column that is no longer what the form opened on is work the admin would lose, so
-- requestLeave has to ask about it -- an emptied box, and a value the rows have meanwhile caught
-- up with, included.
function Page:batchDirty()
    local _, _, _, touched = self:batchChanges()
    return touched > 0
end

-- ----- the write -----

function Page:reject(label, hint)
    self.owner.message = { text = getText(T .. "Admin_Tx_Pair", label, hint), error = true }
end

-- One Apply, one command: every column the form holds travels in the same admin.catalog write,
-- against the revision the draft was opened on. Nothing here is applied optimistically -- the
-- reply carries the whole catalog and that is what the page redraws from.
function Page:onApply()
    if self.batch ~= nil then return self:applyBatch() end
    local d = self.draft
    if d == nil then return end
    if not self.owner:writeAllowed() then
        self.owner.message = { text = errorText("forbidden"), error = true }
        return
    end
    if self.saveRequestId ~= nil then
        self.owner.message = { text = tr("Admin_Shop_SavePending"), error = true }
        return
    end
    -- every column that is really on screen, in range. A currency with no price typed is not
    -- offered at all: none of its four columns is read, and none of them travels.
    local value = {}
    for _, spec in ipairs(self.fields) do
        local skip = spec.currency ~= nil and not self:quoteOffered(spec.currency)
        if not skip then
            local raw = self:draftValue(spec)
            -- a quote being created has no bid yet: an empty bid is "pays nothing back", 0
            if spec.leaf == "bidPrice" and (raw == nil or raw == "") then raw = "0" end
            local out, _, hint = self:specOut(spec, raw)
            if out == nil then
                return self:reject(self:specLabel(spec), hint or tr("Admin_Shop_BatchNoValue"))
            end
            value[spec.key] = out
        end
    end
    -- the quotes, one currency at a time: the bid is the one number whose ceiling is another
    -- column, and a quote that exists may not be emptied (a direction is what gets switched off)
    local offered = 0
    local base = self.draftBase
    for _, cur in ipairs(EC.CURRENCY_ORDER) do
        local price = value["q:" .. cur .. ":price"]
        if price ~= nil then
            offered = offered + 1
            local bid = value["q:" .. cur .. ":bidPrice"] or 0
            local buy = value["q:" .. cur .. ":buyback"] == true
            if bid > price - 1 then
                return self:reject(curLabel(cur, "Admin_Shop_BidPrice"),
                    numberHint(0, price - 1))
            end
            if buy and bid < 1 then
                return self:reject(curLabel(cur, "Admin_Shop_BidPrice"),
                    tr("Admin_Shop_BuybackHint"))
            end
        else
            local was = base ~= nil and base.quotes[cur] or nil
            if was ~= nil and was.exists then
                return self:reject(curLabel(cur, "Admin_Shop_Price"),
                    tr("Admin_Shop_QuoteKeepPrice"))
            end
        end
    end
    if offered == 0 then
        return self:reject(tr("Admin_Shop_Price"), tr("Admin_Shop_QuoteNeedAny"))
    end

    local args = { action = d.isNew and "add" or "set", id = d.id, revision = self.draftRevision }
    local function quoteLeaves(cur)
        return {
            price = value["q:" .. cur .. ":price"],
            bidPrice = value["q:" .. cur .. ":bidPrice"] or 0,
            enabled = value["q:" .. cur .. ":enabled"] == true,
            buyback = value["q:" .. cur .. ":buyback"] == true,
        }
    end
    if d.isNew then
        local id = trimText(entryText(self.idEntry))
        if id == "" or #id > ID_MAX or string.match(id, "^[A-Za-z0-9_%-]+$") == nil then
            return self:reject(tr("Admin_Shop_Id"), tr("Admin_Shop_IdHint"))
        end
        if self:takenIds()[id] then
            return self:reject(tr("Admin_Shop_Id"), tr("Admin_Shop_IdTaken"))
        end
        d.id = id
        args.id, args.item = id, d.item
        args.qty, args.category = value.qty, value.category
        args.enabled = value.enabled == true
        args.dailyCap, args.dailyCapScope = value.dailyCap, scopeOf(value.dailyCapScope)
        args.buybackCap = value.buybackCap
        local prices = {}
        for _, cur in ipairs(EC.CURRENCY_ORDER) do
            if value["q:" .. cur .. ":price"] ~= nil then prices[cur] = quoteLeaves(cur) end
        end
        args.prices = prices
    else
        -- only the leaves that really moved. A currency the admin never touched is absent from
        -- the write, sub-table and all; a quote being created carries all four of its leaves at
        -- once, so the server never has to invent one.
        local moved = 0
        if tostring(value.qty) ~= base.qty then args.qty = value.qty; moved = moved + 1 end
        if value.category ~= base.category then args.category = value.category; moved = moved + 1 end
        if (value.enabled == true) ~= base.enabled then
            args.enabled = value.enabled == true
            moved = moved + 1
        end
        if tostring(value.dailyCap) ~= base.dailyCap then
            args.dailyCap = value.dailyCap
            moved = moved + 1
        end
        if scopeOf(value.dailyCapScope) ~= base.dailyCapScope then
            args.dailyCapScope = scopeOf(value.dailyCapScope)
            moved = moved + 1
        end
        if tostring(value.buybackCap) ~= base.buybackCap then
            args.buybackCap = value.buybackCap
            moved = moved + 1
        end
        local prices = nil
        for _, cur in ipairs(EC.CURRENCY_ORDER) do
            if value["q:" .. cur .. ":price"] ~= nil then
                local was = base.quotes[cur]
                local q = quoteLeaves(cur)
                local leaves = nil
                if not was.exists then
                    -- a quote being created carries all four of its leaves at once
                    leaves = q
                else
                    -- counted, not asked for afterwards: how many leaves moved is the only
                    -- question, and an empty patch must not become an empty sub-table on the wire
                    local patch, touched = {}, 0
                    if tostring(q.price) ~= was.price then patch.price = q.price; touched = touched + 1 end
                    if tostring(q.bidPrice) ~= was.bidPrice then patch.bidPrice = q.bidPrice; touched = touched + 1 end
                    if q.enabled ~= was.enabled then patch.enabled = q.enabled; touched = touched + 1 end
                    if q.buyback ~= was.buyback then patch.buyback = q.buyback; touched = touched + 1 end
                    if touched > 0 then leaves = patch end
                end
                if leaves ~= nil then
                    prices = prices or {}
                    prices[cur] = leaves
                    moved = moved + 1
                end
            end
        end
        args.prices = prices
        if moved == 0 then
            self.owner.message = { text = tr("Admin_Shop_BatchNoChange"), error = true }
            return
        end
    end
    if not self.owner:sendCatalog(args, nil) then return end
    self.saveRequestId = args.requestId
    self.saveError = nil
    self:layout()
end

-- One batch, one command: the ids, the marked columns and the one revision the form opened on.
-- Everything that could make the write partial is refused *here*, before it leaves: a row that is
-- no longer in the catalog, a marked column with no value, a bid that is not under the price the
-- row will end up with, and a currency column aimed at rows that have no quote for it and no
-- price in this very write. The server validates every row again and writes all or nothing, so a
-- refusal never leaves half the picked SKUs changed.
function Page:applyBatch()
    local b = self.batch
    if b == nil then return end
    if not self.owner:writeAllowed() then
        self.owner.message = { text = errorText("forbidden"), error = true }
        return
    end
    if self.saveRequestId ~= nil then
        self.owner.message = { text = tr("Admin_Shop_SavePending"), error = true }
        return
    end
    local rows, missing = {}, 0
    for _, id in ipairs(b.ids) do
        local sku = self:sku(id)
        if sku == nil then missing = missing + 1 else rows[#rows + 1] = sku end
    end
    if missing > 0 then
        self.owner.message = { text = getText(T .. "Admin_Shop_BatchMissing", tostring(missing)), error = true }
        return
    end
    if #rows == 0 then return end
    local fields, lines, blank = self:batchChanges()
    if blank ~= nil then
        return self:reject(self:specLabel(blank.spec), blank.hint or tr("Admin_Shop_BatchNoValue"))
    end
    if #lines == 0 then
        self.owner.message = { text = tr("Admin_Shop_BatchNoChange"), error = true }
        return
    end
    local prices = fields.prices
    for _, sku in ipairs(rows) do
        local name = itemName(sku.item)
        local quotes = quoteTable(sku)
        for _, cur in ipairs(EC.CURRENCY_ORDER) do
            local patch = prices ~= nil and prices[cur] or nil
            local was = quotes[cur]
            if patch ~= nil and not was.exists and patch.price == nil then
                -- writing a direction or a bid onto a row that has no quote for this currency
                -- would be half a quote: the price has to travel with it
                return self:reject(currencyName(cur),
                    getText(T .. "Admin_Shop_QuoteNeedPrice", name, currencyName(cur)))
            end
            local hasQuote = was.exists or (patch ~= nil and patch.price ~= nil)
            if hasQuote then
                local price = (patch ~= nil and patch.price) or tonumber(was.price) or 0
                local bid = (patch ~= nil and patch.bidPrice) or tonumber(was.bidPrice) or 0
                local buy = patch ~= nil and patch.buyback
                if buy == nil then buy = was.buyback end
                if bid > price - 1 then
                    return self:reject(curLabel(cur, "Admin_Shop_BidPrice"),
                        getText(T .. "Admin_Shop_BatchRow", name, numberHint(0, price - 1)))
                end
                if buy == true and bid < 1 then
                    return self:reject(curLabel(cur, "Admin_Shop_BidPrice"),
                        getText(T .. "Admin_Shop_BatchRow", name, tr("Admin_Shop_BuybackHint")))
                end
            end
        end
    end
    local ids = {}
    for i, sku in ipairs(rows) do ids[i] = sku.id end
    local args = { action = "batch", ids = ids, fields = fields, revision = self.batchRevision }
    if not self.owner:sendCatalog(args, nil) then return end
    self.saveRequestId = args.requestId
    self.saveError = nil
    self.batchSent = { count = #ids, lines = lines }
    self:layout()
end

-- ----- transport -----

-- Which column the server refused, said in the words the form uses. A nested column arrives as
-- "prices.<currency>.<leaf>" (the server's own field path), so it is read back as the very
-- control the admin typed into; a path the form has no control for is shown as the server wrote
-- it, the JSON name a host finds in the file (it only ever appears inside Admin_Shop_ErrorAt).
function Page:errorFieldLabel(field)
    local cur, leaf = string.match(tostring(field), "^prices%.([^%.]+)%.(.+)$")
    local spec = cur ~= nil and self.fieldByKey["q:" .. cur .. ":" .. leaf] or self.fieldByKey[tostring(field)]
    if spec ~= nil then return self:specLabel(spec) end
    return tostring(field)
end

-- `req` is the controller's own record of the catalog write this reply answers (nil when it
-- answers none): a removal leaves from the controller's dialog, not from this page, so this is
-- how the page knows the rows that just went are the ones its own Delete asked for.
function Page:onReply(kind, args, req)
    if kind == "option" then
        -- the master switch is read off the snapshot, never off this reply: all that changes here
        -- is that the command slot is free again
        self:layout()
        return
    end
    if kind ~= "catalog" then return end
    local mine = self.saveRequestId ~= nil and args.requestId ~= nil and args.requestId == self.saveRequestId
    if mine then
        self.saveRequestId = nil
        if args.ok then
            self.saveError = nil
        else
            -- the server points at the row, the column and the currency it refused, when it can:
            -- that is the only way an admin knows which of the picked SKUs to go and look at. It
            -- is ONE place: reply.extra, the table the shop itself returned -- reply's own top
            -- level carries the catalog snapshot (its `id` is the echo of the SKU this request was
            -- about, its `count` the catalog's size), so nothing here is read off it. A failure
            -- with a code of its own (a refused reload's `detail`, an arbitrage pair, which names
            -- both sides) is worded by U.fileErrorText; no extra means the code says it all.
            local extra = type(args.extra) == "table" and args.extra or nil
            local failure = type(args.detail) == "table" and args.detail
                or (extra ~= nil and extra.code ~= nil and extra) or nil
            local body
            if failure ~= nil then
                body = U.fileErrorText(args.error, failure)
            else
                body = errorText(args.error)
                local where = {}
                if extra ~= nil then
                    if type(extra.field) == "string" then where[#where + 1] = self:errorFieldLabel(extra.field) end
                    if type(extra.id) == "string" then where[#where + 1] = tostring(extra.id) end
                    if type(extra.currency) == "string" then where[#where + 1] = currencyName(extra.currency) end
                end
                if #where > 0 then body = getText(T .. "Admin_Shop_ErrorAt", body, table.concat(where, " / ")) end
            end
            self.saveError = body
        end
    end
    if type(args.items) == "table" then
        self.catalog = args
        self.updatedAt = EC.now()
        -- our own removal took exactly the rows the editor and the set named: they leave quietly,
        -- they are not reported as another admin's doing
        local removed = req ~= nil and req.action == "remove" and args.ok == true
        -- a SKU another admin removed is not a target any more: the set never points at a row
        -- that is not in the catalog on screen
        local dropped = 0
        for id in pairs(self.picked) do
            if self:sku(id) == nil then
                self.picked[id] = nil
                self.pickedCount = math.max(0, self.pickedCount - 1)
                dropped = dropped + 1
            end
        end
        if dropped > 0 and not removed then
            self.owner.message = { text = getText(T .. "Admin_Shop_BatchMissing", tostring(dropped)), error = true }
        end
        if removed then
            -- the editor was on what is gone (the open SKU, or any row of the batch form): back to
            -- the list, where dropDraft lays the page out
            local gone = self.draft ~= nil and self.draft.isNew ~= true and self:sku(self.draft.id) == nil
            for _, id in ipairs(self.batch ~= nil and self.batch.ids or {}) do
                if self:sku(id) == nil then gone = true end
            end
            if gone then
                self.pickAnchor, self.selectedId, self.cursorId = nil, nil, nil
                self:dropDraft()
                return
            end
        end
        if mine and args.ok and self.batch ~= nil then
            -- the batch landed: the form has nothing left to apply, the set stays lit so the rows
            -- that were just written are the ones on screen. The count is the one this page sent
            -- -- the reply's own `count` is the catalog's size.
            local sent = self.batchSent
            if sent ~= nil then
                -- the controller's own "catalog saved" line does not say how many rows it was
                self.owner.message = { text = getText(T .. "Admin_Shop_BatchSaved", tostring(sent.count)) }
            end
            self:dropDraft()
            return
        end
        if mine and args.ok then
            -- the write landed: the editor re-reads the SKU from the catalog the server just sent,
            -- so the form is pristine against the new base (and a new SKU is the one selected)
            local id = (type(args.id) == "string" and args.id) or (self.draft and self.draft.id) or nil
            if id ~= nil and self:sku(id) ~= nil then
                self:startEdit(id)
            else
                self:dropDraft()
            end
        elseif self.batch ~= nil then
            -- the typed columns are kept exactly as they are; only the base the "did this really
            -- change anything" test compares against follows the new catalog
            self.batch.base = self:batchBase(self.batch.ids)
            if self.batchRevision ~= args.revision then self.baseMoved = true end
        elseif self.draft ~= nil and self.draftRevision ~= args.revision then
            self.baseMoved = true
        end
    end
    self:layout()
end

-- The controller owns the shared timeout and its footer line. A write that never came back frees
-- the form again; the typed values are kept, because nothing here knows whether the server took
-- them or not -- Apply is what asks again.
function Page:onTimeout(command)
    if command == "admin.catalog" then
        self.saveRequestId = nil
        self.saveError = nil
        self:layout()
    elseif command == "admin.option" then
        self:layout()
    end
end

-- ----- rows -----

function Page:rebuildRows()
    local rows = {}
    local list = self.list
    local skus = self:skus()
    if skus ~= nil then
        local query = string.lower(trimText(entryText(self.searchEntry)))
        local width = math.max(120, list.width - 12)   -- 12 = the scrollbar gutter
        local size = math.min(math.max(12, list.rowHeight - 14), 28)
        local lh = lineH()
        local nameX = PAD + size + 8
        local rightX = width - PAD
        -- the price coins, the same size as the admin market rows' price coin
        local coin = math.max(12, math.min(fontH.small + 2, 20))
        local coinY = 5 + math.floor((fontH.small - coin) / 2)
        for _, sku in ipairs(skus) do
            local name = itemName(sku.item)
            local alt = itemOriginal(sku.item)
            local hay = string.lower(name .. " " .. tostring(alt or "") .. " " .. tostring(sku.item)
                .. " " .. tostring(sku.id) .. " " .. categoryText(sku.category))
            -- both filters, one row test: the category set narrows what the keyword searches
            local keep = self:categoryAllowed(sku.category)
                and (query == "" or string.find(hay, query, 1, true) ~= nil)
            if keep then
                local sell, buyback = skuDirections(sku)
                local listed = sku.enabled ~= false and sell
                -- three states, not two: a SKU may be listed and still have no currency that
                -- sells it, and that is not the same thing as being switched off
                local stateText
                if sku.enabled == false then stateText = tr("Shop_Disabled")
                elseif not sell then stateText = tr("Admin_Shop_NoSale")
                else stateText = tr("Admin_Shop_Listed") end
                -- buyback that the master switch is holding shut says so in words, not only in
                -- the colour, and reads exactly like the editor's own chip
                local paused = buyback and self:masterState() == false
                local buybackText = buyback
                    and tr(paused and "Admin_Shop_StatePaused" or "Admin_Shop_Buyback") or nil
                -- The name is what a row is FOR: it gets the width first, and the price summary
                -- is packed into what is left over (never more than a third of the row); quotes
                -- that do not fit become "+N". The whole quote table is in the editor and in the
                -- detail window, so nothing is lost by counting them here.
                local room = math.max(40, rightX - nameX - PAD)
                local prices, priceW = rowPrices(sku, rightX, math.floor(room / 3), coin)
                local nameW = math.max(40, room - priceW - PAD)
                if alt then nameW = math.floor(nameW * 0.55) end
                local item = {
                    id = sku.id, sku = sku, listed = listed,
                    icon = itemTexture(sku.item), iconSize = size,
                    iconY = math.max(0, math.floor(6 + lh - size / 2)),
                    nameText = fitText(name, nameW), nameX = nameX,
                    line1Y = 5, line2Y = 5 + lh, rightX = rightX,
                    prices = prices, coin = coin, coinY = coinY,
                    stateText = stateText,
                    buybackText = buybackText,
                    buybackToken = paused and "warn" or "positive",
                    metaText = fitText(tostring(sku.id) .. "  /  " .. categoryText(sku.category) .. "  /  "
                        .. getText(T .. "Shop_QtyPer", tostring(math.floor(tonumber(sku.qty) or 1)))
                        .. (scopeOf(sku.dailyCapScope) ~= "player"
                            and ("  /  " .. scopeText(sku.dailyCapScope)) or ""),
                        math.max(20, rightX - nameX - textWidth(stateText) - PAD * 2
                            - (buybackText and textWidth(buybackText) + PAD or 0))),
                }
                if alt then
                    item.altX = nameX + nameW + 8
                    item.altText = fitText(alt, math.max(0, rightX - priceW - PAD - item.altX))
                end
                if buybackText then
                    item.buybackX = rightX - textWidth(stateText) - PAD - textWidth(buybackText)
                end
                rows[#rows + 1] = item
            end
        end
    end
    self.rows = rows
    list:setItems(rows)
    -- the keyboard's current row, not the editor's target: a Ctrl / Shift pick moves the cursor
    -- without opening anything, and it has to still be there after the rebuild
    list:setSelectedIndex(self:rowIndex(self.cursorId or self.selectedId))
    self:refreshTxHint()
end

-- ----- the editor's read-only text (the detail window's) -----

-- Everything the row had to cut, in full: the localised name, the script's own name, the item
-- id, how many pieces one unit is, the category, the whole quote table per currency with the
-- server's own buyback room, and the daily cap in both the units the server counts and the pieces
-- they add up to. It is shown in the shared detail window, where it scrolls and CopyAll hands the
-- whole block to the clipboard, so a name too long for the column is never lost.
--
-- The batch form's block is the same idea for a set: how many rows the write would touch, which
-- rows they are, and exactly which columns would be written with which value. The set's summary
-- is *also* a standing part of the form (batchGroups), so closing the window never hides what
-- an Apply is about to do.
function Page:buildDetailText()
    if self.batch ~= nil then
        self:buildBatchText()
        self:appendMessageText()
        self:refreshDetailWindow()
        return
    end
    local d = self.draft
    if d == nil then
        self.detailText, self.detailCard = nil, nil
        self:refreshDetailWindow()
        return
    end
    local qty = math.max(1, parseCount(trimText(entryText(self.qtyEntry))) or 1)
    local cap = parseCount(trimText(entryText(self.capEntry)))
    local master = self:masterState()
    local masterText = getText(T .. "Admin_Shop_Master", master == nil and tr("Admin_Loading")
        or tr(master and "Admin_Shop_StateOn" or "Admin_Shop_StateOff"))
    local lines = {
        tr("Admin_Shop_Id") .. ": " .. tostring(d.id),
        getText(T .. "Admin_Shop_DetailName", itemName(d.item)),
        getText(T .. "Admin_Shop_DetailOriginal", itemOriginal(d.item) or itemName(d.item)),
        getText(T .. "Admin_Shop_DetailType", tostring(d.item)),
        getText(T .. "Admin_Shop_DetailQty", tostring(qty)),
        getText(T .. "Admin_Shop_DetailCategory", categoryText(d.category)),
        capText(cap, qty) .. "  /  " .. scopeDailyText(d.dailyCapScope),
        self:resetNote(d.dailyCapScope),
        -- the master switch, once: the per-currency lines below are the caps and the room the
        -- server reported, never a verdict the switch alone decides
        masterText,
    }
    -- the card says the same things: the facts as rows, the switch as a chip, the rules as text
    local rows = {
        { label = tr("PCard_Shop_Qty"), value = tostring(qty) },
        { label = tr("PCard_Shop_Category"), value = categoryText(d.category) },
        { label = tr("PCard_Shop_Cap"), value = capText(cap, qty), note = scopeDailyText(d.dailyCapScope) },
        { label = tr("PCard_Shop_Reset"), value = self:resetNote(d.dailyCapScope) },
    }
    local paras = {}
    if master == false then
        lines[#lines + 1] = tr("Shop_BuybackPaused")
        paras[#paras + 1] = tr("Shop_BuybackPaused")
    end
    -- the quote table, currency by currency, exactly as the form holds it right now
    for _, cur in ipairs(EC.CURRENCY_ORDER) do
        local ctl = self.quotes[cur]
        local price = trimText(entryText(ctl.priceEntry))
        local q = d.quotes[cur]
        if price == "" then
            lines[#lines + 1] = getText(T .. "Admin_Shop_IdentQuoteNone", currencyName(cur))
            rows[#rows + 1] = { label = currencyName(cur), coin = cur, value = tr("Admin_Shop_QuoteNone"), token = "textFaint" }
        else
            local bid = trimText(entryText(ctl.bidEntry))
            local sellState = tr(q.enabled == true and "Admin_Shop_QuoteSellOn" or "Admin_Shop_QuoteSellOff")
            local buyState = tr(q.buyback == true and "Admin_Shop_QuoteBuyOn" or "Admin_Shop_QuoteBuyOff")
            lines[#lines + 1] = getText(T .. "Admin_Shop_DetailQuote", currencyName(cur), price,
                sellState, bid == "" and "0" or bid, buyState)
            rows[#rows + 1] = { label = currencyName(cur), coin = cur,
                value = getText(T .. "PCard_Shop_Quote", price, sellState, bid == "" and "0" or bid, buyState) }
        end
        -- the configured caps and what is left of them today, as they came: two separate facts,
        -- "-" while no snapshot carried one
        local info = self:buybackInfo(cur) or {}
        lines[#lines + 1] = getText(T .. "Admin_Shop_QuoteRoomCap", currencyName(cur),
            amountOr(info.accountCap), amountOr(info.serverCap))
        lines[#lines + 1] = getText(T .. "Admin_Shop_QuoteRoom", currencyName(cur),
            amountOr(info.accountRemaining), amountOr(info.serverRemaining))
        local why = master == true and self:currencyStatusNote(cur, info) or nil
        if why ~= nil then lines[#lines + 1] = why end
        rows[#rows + 1] = { label = tr("PCard_Shop_RoomCap"), coin = cur,
            value = getText(T .. "PCard_Shop_AcctServer", amountOr(info.accountCap), amountOr(info.serverCap)) }
        rows[#rows + 1] = { label = tr("PCard_Shop_RoomLeft"), coin = cur,
            value = getText(T .. "PCard_Shop_AcctServer", amountOr(info.accountRemaining), amountOr(info.serverRemaining)),
            note = why, token = why ~= nil and "warn" or nil }
    end
    -- What the server itself reported: how much of the count in force is left, and how much of
    -- it is already spent. nil remaining means the snapshot carried none (an unlimited SKU): no
    -- line rather than a guessed number, and a snapshot with no spent count says "-", not 0.
    local sku = not d.isNew and self:sku(d.id) or nil
    local remaining = sku and tonumber(sku.remaining) or nil
    if remaining ~= nil then
        local left = getText(T .. "Admin_Shop_CapRemaining", tostring(math.floor(remaining)),
            tostring(math.floor(remaining) * qty), scopeDailyText(sku.dailyCapScope),
            amountOr(sku.used))
        lines[#lines + 1] = left
        rows[#rows + 1] = { label = tr("PCard_Shop_Remaining"), value = left }
    end
    local skuRoom = sku and tonumber(sku.buybackRemaining) or nil
    if skuRoom ~= nil then
        local room = getText(T .. "Admin_Shop_BuybackRoomSku", tostring(math.floor(skuRoom)))
        lines[#lines + 1] = room
        rows[#rows + 1] = { label = tr("PCard_Shop_SkuRoom"), value = room }
    end
    -- the rules and the long explanations, whole: the form stopped repeating them beside every
    -- box, it did not drop them
    lines[#lines + 1] = ""
    local rules = {}
    self:appendRuleText(rules)
    for _, line in ipairs(rules) do lines[#lines + 1] = line end
    paras[#paras + 1] = table.concat(rules, "\n\n")
    self.detailText = table.concat(lines, "\n")
    local original = itemOriginal(d.item)
    self.detailCard = {
        source = tr("Admin_Shop_Detail"), sourceIcon = "shop", item = d.item,
        name = d.item ~= nil and itemName(d.item) or tr("Admin_Shop_NewTitle"),
        sub = d.isNew and (original ~= nil and getText(T .. "Ent_Pair", original, tr("Admin_Shop_NewTitle"))
            or tr("Admin_Shop_NewTitle")) or original,
        chips = { { value = masterText, token = master == nil and "textFaint" or (master and "text" or "warn"), dot = true } },
        rows = rows, text = table.concat(paras, "\n\n"),
        tech = { { label = tr("Admin_Shop_Id"), value = tostring(d.id) },
            { label = tr("Detail_ItemCode"), value = tostring(d.item) } },
        techOpen = true,
    }
    self:appendMessageText()
    self:refreshDetailWindow()
end

-- The server's own refusal and the master-switch warning, IN FULL, in the one surface that
-- scrolls and copies. They are read off the page's own state, not off what the pinned line
-- managed to paint: at a large font in a short window the budget over the field area can be zero
-- lines, and that is exactly when the whole text must still be somewhere. So a refusal travels
-- here whether the line above the form showed three lines of it, one, or none.
function Page:appendMessageText()
    if self.detailText == nil then return end
    local parts = {}
    if type(self.saveError) == "string" and self.saveError ~= "" then
        parts[#parts + 1] = self.saveError
    end
    local g = self.g
    if g ~= nil and g.warnActive == true then parts[#parts + 1] = tr("Admin_Shop_MasterWarn") end
    if #parts == 0 then return end
    local message = tr("Admin_Shop_DetailMessage") .. "\n" .. table.concat(parts, "\n")
    self.detailText = self.detailText .. "\n\n" .. message
    -- on the card the server's words come first, above the standing rules
    local card = self.detailCard
    if card ~= nil then
        card.text = (card.text ~= nil and card.text ~= "") and (message .. "\n\n" .. card.text) or message
    end
end

function Page:buildBatchText()
    local b = self.batch
    local lines = { getText(T .. "Admin_Shop_BatchTargets", tostring(#b.ids)) }
    local rows = {}
    local shown = 0
    for _, id in ipairs(b.ids) do
        if shown >= BATCH_NAMES_MAX then break end
        local sku = self:sku(id)
        local name = sku and itemName(sku.item) or tr("Admin_Shop_BatchGone")
        lines[#lines + 1] = "- " .. tostring(id) .. "  /  " .. name
        rows[#rows + 1] = { label = tostring(id), value = name, token = sku == nil and "textFaint" or nil }
        shown = shown + 1
    end
    local more
    if #b.ids > shown then
        more = getText(T .. "Admin_Shop_BatchMore", tostring(#b.ids - shown))
        lines[#lines + 1] = more
    end
    local paras = {}
    local mixed = {}
    for _, spec in ipairs(self.fields) do
        if b.start[spec.key] == nil then mixed[#mixed + 1] = self:specLabel(spec) end
    end
    if #mixed > 0 then
        local text = getText(T .. "Admin_Shop_BatchMixedFields", table.concat(mixed, tr("Admin_Set_ListSep")))
        lines[#lines + 1] = text
        paras[#paras + 1] = text
    end
    local _, changes, blank = self:batchChanges()
    lines[#lines + 1] = tr("Admin_Shop_BatchSummaryHead")
    local changeLines = {}
    if #changes == 0 then
        local none = tr(blank ~= nil and "Admin_Shop_BatchNoValue" or "Admin_Shop_BatchNone")
        lines[#lines + 1] = "- " .. none
        changeLines[1] = { text = none }
    else
        for i, line in ipairs(changes) do
            lines[#lines + 1] = "- " .. line
            changeLines[i] = { text = line }
        end
    end
    lines[#lines + 1] = ""
    local rules = {}
    self:appendRuleText(rules)
    for _, line in ipairs(rules) do lines[#lines + 1] = line end
    paras[#paras + 1] = table.concat(rules, "\n\n")
    self.detailText = table.concat(lines, "\n")
    self.detailCard = {
        source = getText(T .. "Admin_Shop_BatchTitle", tostring(#b.ids)), sourceIcon = "shop", iconKey = "layers",
        name = getText(T .. "Admin_Shop_BatchTargets", tostring(#b.ids)),
        rows = rows, note = more,
        sections = { { title = tr("PCard_Shop_Changes"), lines = changeLines } },
        text = table.concat(paras, "\n\n"),
        techOpen = true,
    }
end

-- ----- enabling -----

function Page:updateEnabled()
    local read = self.owner:readAllowed()
    if not read then
        -- the right is gone: nothing this page learned stays on screen, draft and batch set included
        if self.catalog ~= nil or self.draft ~= nil or self.batch ~= nil or self.pickedCount > 0 then
            self:clear()
        end
    end
    local write = self.owner:writeAllowed()
    local modal = self.owner.dialog ~= nil or self:isModal()
    local saving = self.saveRequestId ~= nil
    local browse = read and not modal
    local catWrite = write and not modal and not self.isPending("admin.catalog")
    setEntryEditable(self.searchEntry, browse and self.batch == nil)
    self.reloadButton:setEnable(catWrite)
    self.addButton:setEnable(catWrite and self.catalog ~= nil)
    self.masterButton:setEnable(write and not modal and not self.isPending("admin.option")
        and self:masterState() ~= nil)
    -- the category filter is a read, frozen with a batch form exactly like the search box
    self.catCombo:setEnabled(read and self.owner.dialog == nil and not self:isModal()
        and self.batch == nil)
    if self.batch ~= nil or not read then closeCombo(self.catCombo) end
    -- the two money-page shortcuts are reads: they follow read permission, never the catalog write
    self.salesButton:setEnable(browse)
    self.buysButton:setEnable(browse)
    -- the batch set is operated from the list: picking two rows already IS the form, so this chip
    -- is only the way back to it (after a write closed it), never the thing that opens it in the
    -- first place. Dropping the set is not a write, and neither is offered while the form is up.
    self.batchButton:setEnable(catWrite and self.catalog ~= nil and self.batch == nil and self.pickedCount > 1)
    self.clearSelButton:setEnable(browse and self.batch == nil and self.pickedCount > 0)

    local target = self.draft ~= nil or self.batch ~= nil
    local edit = write and not modal and target and not saving
    for _, e in ipairs(self.entryFields) do setEntryEditable(e, edit) end
    -- the id is the one column only a new SKU may set; the unit count and the category are not
    local new = self.draft ~= nil and self.draft.isNew == true
    for _, e in ipairs(self.newFields) do setEntryEditable(e, edit and new) end
    self.categoryCombo:setEnabled(edit)
    if not edit then closeCombo(self.categoryCombo) end
    for _, spec in ipairs(self.fields) do
        if spec.chip then
            -- a currency with no price typed has no direction to switch: the chip says "not
            -- offered" and cannot be pressed. The batch form always may: a column the rows
            -- disagree on is a value the admin is allowed to set for the whole set.
            local live = edit
            if spec.currency ~= nil and self.batch == nil then
                live = edit and self:quoteOffered(spec.currency)
            end
            spec.control:setEnable(live)
        end
    end
    self.applyButton:setEnable(edit and self:isDirty())
    self.cancelButton:setEnable(edit)
    self.detailButton:setEnable(target and self.detailText ~= nil)
    self.backButton:setEnable(target)
    -- a write like any other (the right, no open overlay, no catalog write in flight, no save of
    -- this form waiting), and only over rows that exist: a new SKU's draft has nothing to remove
    self.deleteButton:setEnable(catWrite and not saving and self:deleteTargets() ~= nil)
end

-- ----- geometry -----

-- Every state a switch chip may have to say, in full: the value column is what reserves the room
-- for them, so a state is never the thing an admin has to hover to read.
local FORM_STATES = { "Admin_Shop_Listed", "Shop_Disabled", "Admin_Shop_StateOn",
    "Admin_Shop_StateOff", "Admin_Shop_StatePaused", "Admin_Shop_ScopePlayer",
    "Admin_Shop_ScopeGlobal", "Admin_Shop_ScopeLifetime", "Admin_Shop_BatchMixed",
    "Admin_Shop_QuoteNone", "Admin_Shop_QuoteSellOn", "Admin_Shop_QuoteSellOff", "Admin_Shop_QuoteBuyOn",
    "Admin_Shop_QuoteBuyOff" }

-- The states a direction chip inside the quote table may say. One shared width for both
-- direction columns, so every currency's row breaks at the same boundary.
local QUOTE_STATES = { "Admin_Shop_QuoteSellOn", "Admin_Shop_QuoteSellOff", "Admin_Shop_QuoteBuyOn",
    "Admin_Shop_QuoteBuyOff", "Admin_Shop_QuoteNone", "Admin_Shop_BatchMixed",
    "Admin_Shop_StatePaused" }

-- The widest label the form has to reserve room for, and the widest value box it wants. Both are
-- font aware: a large UI font simply moves the boxes right instead of cutting the digits.
-- `quoteLabels` is the stacked fallback's own question: while the currencies are a table their
-- labels are column titles, and a title must not widen the label column of the plain rows.
function Page:formMetrics(quoteLabels)
    local labelW = textWidth(tr("Admin_Shop_Id"))
    for _, spec in ipairs(self.fields) do
        if quoteLabels or spec.currency == nil then
            -- a field with a "?" beside its label needs the marker's room in the label column too
            local w = textWidth(self:specLabel(spec)) + (spec.tip and self:tipSize() + 4 or 0)
            if w > labelW then labelW = w end
        end
    end
    local valueW = textWidth("1000000000")
    for _, key in ipairs(FORM_STATES) do
        local w = textWidth(tr(key))
        if w > valueW then valueW = w end
    end
    -- the dropdown paints its selected option unfitted, so its widest option is part of the value
    -- column's budget -- capped, so one long custom category cannot push the labels off screen
    local combo = self.categoryCombo
    for i = 1, #combo.options do
        local w = math.min(textWidth(combo:getOptionText(i)) + 30, 260)
        if w > valueW then valueW = w end
    end
    return labelW, math.max(90, valueW + 24)
end

-- The quote table's column boundaries, shared by every currency: the currency column, the two
-- direction chips and the two price boxes, each wide enough for its own column title as well.
-- `total` is what the whole table wants -- under that width the currencies go back to one
-- stacked group each, in the same place in the reading order.
function Page:quoteColumns()
    local curW = textWidth(tr("Market_Col_Currency"))
    for _, cur in ipairs(EC.CURRENCY_ORDER) do
        local w = textWidth(currencyName(cur))
        if w > curW then curW = w end
    end
    local chipW = 0
    for _, key in ipairs(QUOTE_STATES) do
        local w = textWidth(tr(key))
        if w > chipW then chipW = w end
    end
    chipW = chipW + 24
    local priceW = textWidth("1000000000") + 24
    -- the two price titles carry the first currency's "?" markers
    local tipW = self:tipSize() + 4
    local cols = {
        cur = curW,
        sell = math.max(chipW, textWidth(tr("Admin_Shop_QuoteSell"))),
        price = math.max(priceW, textWidth(tr("Admin_Shop_Price")) + tipW),
        buy = math.max(chipW, textWidth(tr("Admin_Shop_QuoteBuy"))),
        bid = math.max(priceW, textWidth(tr("Admin_Shop_BidPrice")) + tipW),
    }
    cols.total = cols.cur + cols.sell + cols.price + cols.buy + cols.bid + 8 * 4
    return cols
end

-- The "?" marker's size: one line of small text tall, so it sits inside a label's own line.
function Page:tipSize()
    local h = fontH.small + 4
    return math.max(h, textWidth(tr("Admin_Shop_TipMark")) + 12), h
end

-- One "?" marker at content y `cy`, recorded for Form:scrollTo whether it is inside the viewport
-- or not, and shown only when it fits whole -- exactly like a field's control.
function Page:placeTip(tip, x, cy)
    local tw, th = self:tipSize()
    tip.ecFormY, tip.ecFormH, tip.ecFormLabelY = cy, th, cy
    local ay = cy - (self.form.scrollOffset or 0)
    if ay >= 0 and ay + th <= self.form.height then
        tip:setVisible(true)
        tip:setX(x); tip:setY(ay)
        tip:setWidth(tw); tip:setHeight(th)
    end
end

-- A label fitted to `maxW` with the marker (if any) right after the words it explains. `ay` is
-- where the label paints (nil: not inside the viewport), `cy` the marker's content y.
function Page:placeLabel(label, tip, x, ay, cy, maxW)
    local tipW = tip and self:tipSize() + 4 or 0
    local shown = fitText(label, math.max(0, maxW - tipW))
    if ay ~= nil then
        local paint = self.form.paint
        paint.labels[#paint.labels + 1] = { text = shown, x = x, y = ay }
    end
    if tip then self:placeTip(tip, x + textWidth(shown) + 4, cy) end
end

-- One group's heading and the rule under it, with the group's own marker after the words.
-- Returns the y its first row starts at.
function Page:placeHead(head, x, top, colW, tip)
    local paint = self.form.paint
    local scroll = self.form.scrollOffset or 0
    local headH = fontH.medium + 4
    local ay = top - scroll
    local tipW, th = self:tipSize()
    local shown = fitText(head, math.max(0, colW - (tip and tipW + 6 or 0)), UIFont.Medium)
    if ay >= 0 and ay + headH <= self.form.height then
        paint.heads[#paint.heads + 1] = { text = shown, x = x, y = ay, w = colW }
    end
    if tip then
        self:placeTip(tip, x + textWidth(shown, UIFont.Medium) + 6, top + math.floor((headH - th) / 2))
    end
    return top + headH + 4
end

-- The columns of one currency's row, left to right. The order is the order the keyboard walks
-- them in (Page.fields), so Tab and the eye agree.
local QUOTE_COLUMNS = {
    { leaf = "enabled", width = "sell", chip = true, title = "Admin_Shop_QuoteSell" },
    { leaf = "price", width = "price", title = "Admin_Shop_Price" },
    { leaf = "buyback", width = "buy", chip = true, title = "Admin_Shop_QuoteBuy" },
    { leaf = "bidPrice", width = "bid", title = "Admin_Shop_BidPrice" },
}

-- The quote section as one table: the column titles once, then one row per currency over the
-- same boundaries. Every control records the logical row it sits in whether it ended up inside
-- the viewport or not, exactly like a plain field row, so a control under the fold can still be
-- revealed (Form:scrollTo) by whoever focuses it.
function Page:placeQuoteTable(x, top, cols)
    local paint = self.form.paint
    local scroll = self.form.scrollOffset or 0
    local h = self.form.height
    local rowH = math.max(chipH(), entryH())
    local titleH = fontH.small + 4
    local y = top
    local ay = y - scroll
    local titled = ay >= 0 and ay + titleH <= h
    if titled then
        paint.labels[#paint.labels + 1] = { text = tr("Market_Col_Currency"),
            x = x, y = ay }
    end
    -- the column titles, the two price titles with the first currency's markers after them
    local first = EC.CURRENCY_ORDER[1]
    local tx = x + cols.cur + 8
    for _, col in ipairs(QUOTE_COLUMNS) do
        local w = cols[col.width]
        local tip = self.fieldByKey["q:" .. first .. ":" .. col.leaf].tip
        self:placeLabel(tr(col.title), tip, tx, titled and ay or nil, y, w)
        tx = tx + w + 8
    end
    y = y + titleH
    for _, cur in ipairs(EC.CURRENCY_ORDER) do
        ay = y - scroll
        local fits = ay >= 0 and ay + rowH <= h
        if fits then
            paint.labels[#paint.labels + 1] = { text = currencyName(cur), x = x,
                y = ay + math.floor((rowH - fontH.small) / 2) }
        end
        local cx = x + cols.cur + 8
        for _, col in ipairs(QUOTE_COLUMNS) do
            local w = cols[col.width]
            local control = self.fieldByKey["q:" .. cur .. ":" .. col.leaf].control
            control.ecFormY, control.ecFormH = y, rowH
            control.ecFormLabelY = y
            if fits then
                control:setVisible(true)
                control:setX(cx)
                control:setY(ay + (col.chip and math.floor((rowH - chipH()) / 2) or 0))
                control:setWidth(w)
                control:setHeight(col.chip and chipH() or entryH())
                if col.chip then U.setButtonTitle(control, control.fullTitle) end
            end
            cx = cx + w + 8
        end
        y = y + rowH + 4
    end
    return y
end

-- One group of the editor: a heading and its rows, at the place the fixed order gave it.
-- Returns the new bottom of the column.
function Page:placeGroup(group, x, top, colW, labelW, valueW)
    local paint = self.form.paint
    local scroll = self.form.scrollOffset or 0
    local h = self.form.height
    local rowH = math.max(chipH(), entryH())
    local y = self:placeHead(group.head, x, top, colW, group.tip)
    if group.quotes then return self:placeQuoteTable(x, y, self.quoteCols) + PAD end
    local ay
    -- a column too narrow to hold "label  control" side by side stacks them instead of squeezing
    -- the control down to a stub: every field stays operable at every window width, and the
    -- field area scrolls for the height it costs
    local stacked = colW - labelW - 8 < 72
    local paired = group.paired and colW >= 2 * (labelW + valueW + 8) + PAD
    local fieldW = paired and math.floor((colW - PAD) / 2) or colW
    local slot = 0
    for _, row in ipairs(group.rows) do
        ay = y - scroll
        if row.note then
            if slot > 0 then y, slot = y + rowH + 4, 0 end
            -- a fact is wrapped whole, never cut to three lines: half a sentence about what this
            -- form would write (or about what the server reported) is worse than the room it
            -- costs, and the area this sits in scrolls
            local noteH = lineH()
            for _, line in ipairs(U.wrapText(row.note, colW, math.huge)) do
                ay = y - scroll
                if ay >= 0 and ay + noteH <= h then
                    paint.notes[#paint.notes + 1] = { text = line, x = x, y = ay, token = row.token or "warn" }
                end
                y = y + noteH
            end
            y = y + 4
        elseif stacked then
            local control = row.control
            local labelH = fontH.small + 4
            self:placeLabel(row.label, row.tip, x, (ay >= 0 and ay + labelH <= h) and ay or nil, y, colW)
            y = y + labelH
            ay = y - scroll
            -- where this row sits in the content, scroll aside: recorded for every row, visible
            -- or not, because that is what a reveal needs (Form:scrollTo) -- the keyboard asks for
            -- the row it is about to focus, so a field under the fold is reachable by Tab too
            control.ecFormY, control.ecFormH = y, rowH
            control.ecFormLabelY = y - labelH
            if ay >= 0 and ay + rowH <= h then
                control:setVisible(true)
                control:setX(x)
                control:setY(ay + (row.chip and math.floor((rowH - chipH()) / 2) or 0))
                control:setWidth(math.max(48, colW))
                control:setHeight(row.chip and chipH() or entryH())
                if row.chip then U.setButtonTitle(control, control.fullTitle) end
            end
            y = y + rowH + 4
        else
            local fieldX = x + slot * (fieldW + PAD)
            local control = row.control
            control.ecFormY, control.ecFormH = y, rowH
            control.ecFormLabelY = y
            local fits = ay >= 0 and ay + rowH <= h
            local _, th = self:tipSize()
            self:placeLabel(row.label, row.tip, fieldX,
                fits and ay + math.floor((rowH - fontH.small) / 2) or nil, y + math.floor((rowH - th) / 2), labelW)
            if fits then
                control:setVisible(true)
                control:setX(fieldX + labelW + 8)
                control:setY(ay)
                control:setWidth(math.max(48, math.min(valueW, fieldW - labelW - 8)))
                control:setHeight(row.chip and chipH() or entryH())
                if row.chip then
                    control:setY(ay + math.floor((rowH - chipH()) / 2))
                    U.setButtonTitle(control, control.fullTitle)
                end
            end
            slot = paired and (1 - slot) or 0
            if slot == 0 then y = y + rowH + 4 end
        end
    end
    if slot > 0 then y = y + rowH + 4 end
    return y + PAD
end

-- The one line over the form: what the write is doing, or what happened to it. Recomputed on
-- every keystroke as well as on layout, so the unsaved marker appears with the character that
-- caused it.
function Page:refreshNote()
    local g = self.g
    if g == nil then return end
    local note, token = nil, "textFaint"
    if self.draft ~= nil or self.batch ~= nil then
        if self.saveError ~= nil then note, token = self.saveError, "errorText"
        elseif self.saveRequestId ~= nil then note, token = tr("Admin_Shop_Saving"), "textFaint"
        elseif self.baseMoved then note, token = tr("Admin_Shop_Changed"), "warn"
        elseif self:isDirty() then note, token = tr("Admin_Shop_Dirty"), "accent" end
    end
    local width = g.noteW or self.width
    local all = note and U.wrapText(note, width, math.huge) or {}
    -- the budget layout reserved: a long refusal may cost the pinned area lines, never the field
    -- area's own control row. What does not fit says so and travels to the detail window whole.
    local max = g.noteMax or #all
    local shown = {}
    for i = 1, math.min(#all, max) do shown[i] = all[i] end
    if #all > max then
        g.noteFull = note
        if max > 0 then shown[max] = fitText(tr("Admin_Shop_MoreInDetail"), width) end
    else
        g.noteFull = nil
    end
    g.noteLines = shown
    g.noteToken = token
end

-- The identity block, pinned over the scrolling field area: what this row IS, in the things a
-- host needs to match it against anything else -- the localised name (the title over it), the
-- script's own name, fullType, SKU id, category and unit count. Quotes stay in the editable form.
function Page:refreshIdent()
    local g = self.g
    if g == nil or g.identLines == nil then return end
    local lines = g.identLines
    local w = g.editorW or self.width
    local function set(i, value)
        local e = lines[i]
        if e == nil then return end
        e.text = fitText(value, w)
    end
    if self.batch ~= nil then
        local b = self.batch
        set(1, getText(T .. "Admin_Shop_BatchTargets", tostring(#b.ids)))
        local names, shown = {}, 0
        for _, id in ipairs(b.ids) do
            if shown >= 4 then break end
            local sku = self:sku(id)
            names[#names + 1] = sku and itemName(sku.item) or tostring(id)
            shown = shown + 1
        end
        local body = table.concat(names, ", ")
        if #b.ids > shown then body = body .. "  +" .. tostring(#b.ids - shown) end
        set(2, body)
        return
    end
    local d = self.draft
    if d == nil then return end
    set(1, getText(T .. "Admin_Shop_IdentOriginal", itemOriginal(d.item) or itemName(d.item)))
    set(2, getText(T .. "Admin_Shop_IdentType", tostring(d.item)))
    -- the id and how many pieces one unit is are the two facts a host cannot work without (a
    -- price is per unit), so they come first and the category is what a narrow line gives up
    set(3, getText(T .. "Admin_Shop_IdentSku", tostring(d.id),
        tostring(math.max(1, parseCount(trimText(entryText(self.qtyEntry))) or 1)),
        categoryText(d.category)))
end

-- ----- the editor's groups -----

function Page:fieldRow(key)
    local spec = self.fieldByKey[key]
    return { label = self:specLabel(spec), control = spec.control, chip = spec.chip == true, tip = spec.tip }
end

-- One currency's quote as four stacked rows: the two directions and the two prices. The narrow
-- (or large font) fallback for the table -- what the server reported about this currency is NOT
-- in here: it is read-only and belongs in the status group, never between two price boxes.
function Page:quoteRows(cur)
    return {
        self:fieldRow("q:" .. cur .. ":enabled"),
        self:fieldRow("q:" .. cur .. ":price"),
        self:fieldRow("q:" .. cur .. ":buyback"),
        self:fieldRow("q:" .. cur .. ":bidPrice"),
    }
end

-- The quote section: one table with a row per currency while the width allows it (every currency
-- over the same column boundaries), one stacked group per currency when it does not. Its place in
-- the reading order is the same either way.
function Page:quoteGroups()
    if self.quoteGrid then
        return { { head = tr("Shop_Quotes"), quotes = true } }
    end
    local out = {}
    for _, cur in ipairs(EC.CURRENCY_ORDER) do
        out[#out + 1] = { head = getText(T .. "Admin_Shop_GroupQuote", currencyName(cur)),
            rows = self:quoteRows(cur) }
    end
    return out
end

-- Why one currency is not buying right now, told apart -- and only ever asked while the master
-- switch is ON, because that switch is said once, above, and is not a statement about any
-- currency's caps. A coin cap really configured to 0 is not the same thing as a currency the
-- server reports as unavailable for trade, and neither is the same thing as a cap that exists and
-- is used up for today. nil means the server reported nothing that says a direction is shut.
function Page:currencyStatusNote(cur, info)
    local accountCap, serverCap = tonumber(info.accountCap), tonumber(info.serverCap)
    if (accountCap ~= nil and accountCap <= 0) or (serverCap ~= nil and serverCap <= 0) then
        return getText(T .. "Admin_Shop_QuoteCurOff", currencyName(cur))
    end
    if accountCap == nil or serverCap == nil then return nil end
    if info.enabled == false then
        return getText(T .. "Admin_Shop_QuoteCurrencyUnavailable", currencyName(cur))
    end
    local account, server = tonumber(info.accountRemaining), tonumber(info.serverRemaining)
    if info.enabled == true and ((account ~= nil and account <= 0) or (server ~= nil and server <= 0)) then
        return getText(T .. "Admin_Shop_QuoteExhausted", currencyName(cur))
    end
    return nil
end

-- The read-only end of the form: what the SERVER says about buying back, never a column this
-- page writes. The master switch first and once; then, per currency, the configured caps and the
-- room left today as two separate lines exactly as they came ("-" while nothing carried them),
-- and at most one line saying why that currency is shut. With the master off nothing per currency
-- claims a 0 cap: the switch is the reason, and it is already on screen.
function Page:statusGroup()
    local master = self:masterState()
    local rows = { { note = getText(T .. "Admin_Shop_Master", master == nil and tr("Admin_Loading")
        or tr(master and "Admin_Shop_StateOn" or "Admin_Shop_StateOff")),
        token = master == nil and "textFaint" or (master and "text" or "warn") } }
    if master == false then
        rows[#rows + 1] = { note = tr("Shop_BuybackPaused"), token = "warn" }
    end
    for _, cur in ipairs(EC.CURRENCY_ORDER) do
        local info = self:buybackInfo(cur) or {}
        rows[#rows + 1] = { note = getText(T .. "Admin_Shop_QuoteRoomCap", currencyName(cur),
            amountOr(info.accountCap), amountOr(info.serverCap)), token = "textFaint" }
        rows[#rows + 1] = { note = getText(T .. "Admin_Shop_QuoteRoom", currencyName(cur),
            amountOr(info.accountRemaining), amountOr(info.serverRemaining)), token = "text" }
        local why = master == true and self:currencyStatusNote(cur, info) or nil
        if why ~= nil then rows[#rows + 1] = { note = why, token = "warn" } end
    end
    -- this SKU's own share room, which is one pool across the currencies
    local d = self.draft
    local sku = d ~= nil and d.isNew ~= true and self:sku(d.id) or nil
    local skuRoom = sku and tonumber(sku.buybackRemaining) or nil
    if skuRoom ~= nil then
        rows[#rows + 1] = { note = getText(T .. "Admin_Shop_BuybackRoomSku",
            tostring(math.floor(skuRoom))), token = "text" }
    end
    return { head = tr("Admin_Shop_GroupBuybackStatus"), rows = rows }
end

-- The standing rules -- what a unit count means, whose count a cap is, what a buyback price may
-- be, what a batch really writes -- in the one surface that scrolls and copies whole. These are
-- the same sentences the form used to squeeze in beside every box and once per currency: the form
-- stopped repeating them, it did not drop them.
function Page:appendRuleText(lines)
    if self.batch ~= nil then
        lines[#lines + 1] = tr("Admin_Shop_BatchScopeNote")
        lines[#lines + 1] = tr("Admin_Shop_BatchHint")
        -- the batch form's "?" says how a set is picked in short; this is the whole rule
        lines[#lines + 1] = tr("Admin_Shop_BatchSelectHint")
        lines[#lines + 1] = tr("Admin_Shop_BatchQuoteNote")
        lines[#lines + 1] = tr("Admin_Shop_QtyNote")
        lines[#lines + 1] = tr("Admin_Shop_QuoteHint")
        lines[#lines + 1] = tr("Admin_Shop_BcapNote")
        lines[#lines + 1] = tr("Admin_Shop_EnabledNote")
        return
    end
    local d = self.draft
    if d == nil then return end
    local qty = math.max(1, parseCount(trimText(entryText(self.qtyEntry))) or 1)
    if d.isNew then lines[#lines + 1] = tr("Admin_Shop_IdHint") end
    lines[#lines + 1] = getText(T .. "Admin_Shop_SellHint", tostring(qty))
    lines[#lines + 1] = tr("Admin_Shop_QtyNote")
    lines[#lines + 1] = getText(T .. "Admin_Shop_CatNote", itemDisplayCategory(d.item))
    lines[#lines + 1] = getText(T .. "Admin_Shop_CapScopeHint", scopeText(d.dailyCapScope))
    lines[#lines + 1] = tr("Admin_Shop_BcapNote")
    lines[#lines + 1] = tr("Admin_Shop_QuoteHint")
    -- taking a row off the shelf stops the sale only (ECShop): said once, here, in full
    lines[#lines + 1] = tr("Admin_Shop_EnabledNote")
    for _, cur in ipairs(EC.CURRENCY_ORDER) do
        if not self:quoteOffered(cur) then
            lines[#lines + 1] = tr("Admin_Shop_QuoteNoneHint")
            break
        end
    end
end

-- The groups the open draft needs, in one fixed reading order: what the item IS, the listing with
-- its daily shares, the quotes and last the read-only buyback status. Nothing here is ordered by
-- how tall a sentence is, so a field never moves because the text above it grew, and what stays
-- beside a box is only what THIS form would write or what the server reported -- the standing
-- rules are read in full in the detail window. The id is a new SKU's only extra field: it is the
-- one column an existing SKU may not change.
function Page:formGroups()
    if self.batch ~= nil then return self:batchGroups() end
    local d = self.draft
    if d == nil then return {} end
    local qty = math.max(1, parseCount(trimText(entryText(self.qtyEntry))) or 1)
    local cap = parseCount(trimText(entryText(self.capEntry)))
    local groups = {}

    local itemRows = {}
    if d.isNew then
        itemRows[#itemRows + 1] = { label = tr("Admin_Shop_Id"), control = self.idEntry }
    end
    itemRows[#itemRows + 1] = self:fieldRow("qty")
    itemRows[#itemRows + 1] = self:fieldRow("category")
    if d.isNew then
        -- the one rule that stays in the form: the id is only editable here, and it is what the
        -- write would be refused for
        itemRows[#itemRows + 1] = { note = tr("Admin_Shop_IdHint"), token = "textFaint" }
    end
    -- changing the unit count is a promise about future orders only, and this is the preview of
    -- what this very form would write: it stays on screen
    local wasQty = self.draftBase ~= nil and self.draftBase.qty or nil
    if wasQty ~= nil and tostring(qty) ~= wasQty then
        itemRows[#itemRows + 1] = { note = getText(T .. "Admin_Shop_QtyPreview", wasQty, tostring(qty),
            tostring(cap or 0), tostring((cap or 0) * qty)), token = "warn" }
    end
    groups[#groups + 1] = { head = tr("Admin_Shop_GroupItem"), rows = itemRows, paired = true }

    local limitRows = { self:fieldRow("enabled"), self:fieldRow("dailyCap"),
        self:fieldRow("dailyCapScope"), self:fieldRow("buybackCap") }
    limitRows[#limitRows + 1] = { note = capText(cap, qty) .. "  /  " .. scopeDailyText(d.dailyCapScope),
        token = "text" }
    local sku = not d.isNew and self:sku(d.id) or nil
    local remaining = sku and tonumber(sku.remaining) or nil
    if remaining ~= nil then
        limitRows[#limitRows + 1] = { note = getText(T .. "Admin_Shop_CapRemaining",
            tostring(math.floor(remaining)), tostring(math.floor(remaining) * qty),
            scopeDailyText(sku.dailyCapScope), amountOr(sku.used)), token = "text" }
    end
    if not self.wide then
        limitRows[#limitRows + 1] = { note = self:resetNote(d.dailyCapScope), token = "text" }
    end
    groups[#groups + 1] = { head = tr("Admin_Shop_GroupLimits"), rows = limitRows, paired = true }

    for _, group in ipairs(self:quoteGroups()) do groups[#groups + 1] = group end
    groups[#groups + 1] = self:statusGroup()
    return groups
end

-- The batch editor follows the same field order as a single SKU. Targets stay pinned;
-- the form shows current changes and Detail names every mixed field.
function Page:batchGroups()
    local b = self.batch
    local head = {}
    for _, spec in ipairs(self.fields) do
        if b.start[spec.key] == nil then
            head[#head + 1] = { note = tr("Admin_Shop_BatchMixedHint"), token = "textFaint" }
            break
        end
    end
    local _, changes, blank = self:batchChanges()
    if #changes == 0 then
        head[#head + 1] = { note = "- " .. tr(blank ~= nil and "Admin_Shop_BatchNoValue" or "Admin_Shop_BatchNone"),
            token = "textFaint" }
    else
        for _, line in ipairs(changes) do
            head[#head + 1] = { note = "- " .. line, token = "accent" }
        end
    end
    local groups = {
        { head = tr("Admin_Shop_BatchSummaryHead"), rows = head, tip = self.batchTip },
        { head = tr("Admin_Shop_GroupItem"), paired = true, rows = {
            self:fieldRow("qty"), self:fieldRow("category"),
        } },
        { head = tr("Admin_Shop_GroupLimits"), paired = true, rows = {
            self:fieldRow("enabled"), self:fieldRow("dailyCap"), self:fieldRow("dailyCapScope"),
            self:fieldRow("buybackCap"),
            { note = self:resetNote(), token = "text" },
        } },
    }
    for _, group in ipairs(self:quoteGroups()) do groups[#groups + 1] = group end
    groups[#groups + 1] = self:statusGroup()
    return groups
end

-- Place the field area from the geometry the layout pass settled on, at the current scroll
-- offset. Called again -- and only this much -- when the offset moves.
function Page:placeForm(preserveFocus)
    local form = self.form
    local focused
    for _, c in ipairs(self.formControls) do
        if preserveFocus and c.isFocused and c:isFocused() then focused = c end
        c:setVisible(false)
        -- the logical row this pass gave it, cleared first: a control that is not in the open
        -- draft's groups at all (the id of an existing SKU) must not keep the row it had
        c.ecFormY, c.ecFormH, c.ecFormLabelY = nil, nil, nil
    end
    form.paint = { heads = {}, labels = {}, notes = {} }
    if (self.draft == nil and self.batch == nil) or not form:getIsVisible() then
        form.contentH = 0
        closeCombo(self.categoryCombo)
        return
    end
    local w, h = form.width - 22, form.height
    -- The reading order is FIXED -- the item, the listing and its daily shares, the quotes, the
    -- read-only buyback status -- so the one thing the width decides here is whether every
    -- currency gets a row of its own inside the quote table or a stacked group. A group is never
    -- moved into another column because the sentence above it grew: one column, top to bottom,
    -- and the field area scrolls for the height it costs.
    self.quoteCols = self:quoteColumns()
    self.quoteGrid = w >= self.quoteCols.total
    local labelW, valueW = self:formMetrics(not self.quoteGrid)
    local groups = self:formGroups()
    local scroll = form.scrollOffset or 0
    local contentH = 0
    for _, group in ipairs(groups) do
        contentH = self:placeGroup(group, 0, contentH, w, labelW, math.min(valueW, w - labelW - 8))
    end
    form.contentH = contentH
    form.vscroll:setX(form.width - 17)
    form.vscroll:setY(0)
    form.vscroll:setWidth(17)
    form.vscroll:setHeight(h)
    form.vscroll:setVisible(contentH > h)
    local maxOffset = form:maxScrollOffset()
    if scroll > maxOffset then
        form.scrollOffset = maxOffset
        return self:placeForm(preserveFocus)
    end
    if focused then form:scrollTo(focused) end
    -- a box that scrolled out of the viewport must not keep the engine's keyboard: it is off the
    -- descriptor list from here, and the next Tab would have nothing to give it back to. The
    -- dropdown takes its popup with it for the same reason -- the popup floats over the whole UI.
    for _, c in ipairs(self.formControls) do
        if not c:getIsVisible() then
            if c.unfocus then pcall(c.unfocus, c) end
            if c == self.categoryCombo then closeCombo(c) end
        end
    end
end

-- The switches carry what they will write, in words: the chip is the control and the label beside
-- it says which column it belongs to. A batch column the picked rows disagree on says exactly
-- that instead of borrowing one row's value, a currency with no price says "not offered", and
-- moving a switch is the whole of making it travel.
-- Returns whether a buyback direction on screen is one the master switch is holding shut.
function Page:refreshEditorChips()
    if self.draft == nil and self.batch == nil then return false end
    local master = self:masterState()
    local mixed = tr("Admin_Shop_BatchMixed")
    local paused = false
    for _, spec in ipairs(self.fields) do
        if spec.chip then
            local value
            if self.batch ~= nil then value = self:batchValue(spec) else value = self:draftValue(spec) end
            local title, token
            local notOffered
            if self.batch ~= nil then
                -- untouched, and none of the picked rows quotes this currency
                notOffered = spec.currency ~= nil and self.batch.base.quoted[spec.currency] ~= true
                    and self.batch.value[spec.key] == nil
            else
                notOffered = spec.currency ~= nil and not self:quoteOffered(spec.currency)
            end
            if notOffered then
                title, token = tr("Admin_Shop_QuoteNone"), "textFaint"
            elseif value == nil then
                title, token = mixed, "warn"
            elseif spec.kind == "scope" then
                title = scopeText(value)
                token = scopeOf(value) == "global" and "accent" or "textMuted"
            else
                local on = value == true
                local shut = on and spec.leaf == "buyback" and master == false
                if shut then paused = true end
                title = tr(on and (shut and "Admin_Shop_StatePaused" or spec.on) or spec.off)
                token = on and (shut and "warn" or "positive") or "textMuted"
            end
            U.setButtonTitle(spec.control, title)
            -- the chip carries the business state as words *and* colour; setEnable stays the
            -- permission / pending gate and is never what says "on" or "off"
            spec.control.stateToken = token
        end
    end
    return paused
end

-- The header's facts as pills on one row that wraps instead of cutting a number: the catalog
-- file's count against the host's limit and when it was read (or the file's error, which wins:
-- the server is still running with the previous catalog), the buyback master switch with the chip
-- that flips it (what the switch is, is the chip's tooltip), and the daily reset with its
-- countdown. Run by layout, and again from the paint pass when the minute, the catalog request's
-- pending state or the host's limit moves; the rows it took are what the search row sits under.
function Page:placeHeader()
    local g = self.g
    local w = self.width
    local snap = self.catalog
    local file = type(snap) == "table" and type(snap.file) == "table" and snap.file or nil
    local fileError = file and type(file.errorCode) == "string" and file.errorCode ~= ""
        and (U.fileErrorDetail(file.errorDetail) or errorText(file.errorCode)) or nil
    local pending = self.isPending("admin.catalog") and true or false
    local pills = {}
    if fileError then
        pills[1] = { value = getText(T .. "Admin_Shop_FileError", fileError), token = "errorText" }
    elseif file then
        -- at or past the host's limit no item can be added: the figure says so in the warn colour
        local count, limit = tonumber(file.count) or 0, tonumber(self:maxItems())
        pills[1] = { label = tr("Admin_Shop_PillCatalog"), value = getText(T .. "Admin_Shop_PillCount",
            tostring(count), tostring(limit or "-")), token = (limit ~= nil and count >= limit) and "warn" or "text" }
        pills[2] = { label = tr("Admin_Shop_PillLoaded"),
            value = stampText(file.loadedAt, self.owner.offsetMin), token = "textMuted" }
    else
        pills[1] = { label = tr("Admin_Shop_PillCatalog"),
            value = pending and tr("Admin_Loading") or tr("Admin_Dash_Empty"), token = "textFaint" }
    end
    local state = self:masterState()
    local master = { label = tr("Admin_Shop_MasterLabel"),
        value = state == nil and tr("Admin_Loading") or tr(state and "Admin_Shop_StateOn" or "Admin_Shop_StateOff"),
        token = state == nil and "textFaint" or (state and "positive" or "textMuted") }
    pills[#pills + 1] = master
    local ends = type(snap) == "table" and tonumber(snap.dayEndsMs) or nil
    local off = self.owner.offsetMin
    pills[#pills + 1] = { label = tr("Admin_Shop_PillReset"), token = "textMuted",
        value = ends and getText(T .. "Admin_Shop_PillResetValue", dateText(ends, off), clockText(ends, off),
            durationText(math.max(0, ends - EC.now()))) or "-" }

    local mb = self.masterButton
    mb.fullTitle = tr(state == true and "Admin_Shop_BuybackOff" or "Admin_Shop_BuybackOn")
    mb.tooltip, mb.autoTooltip = tr("Admin_Shop_MasterHint"), nil
    mb:setWidth(math.min(textWidth(mb.fullTitle) + 24, math.floor(w * 0.34)))
    U.setButtonTitle(mb, mb.fullTitle)

    local ch = chipH()
    local rowH = math.max(ch, U.CHIP_H)
    local maxW = math.max(40, w - PAD * 2)
    local x, y, right, rows = PAD, g.headTop, g.headRight, 1
    -- the first row ends at Add / Reload; a pill that does not fit starts the next full-width row
    local function slot(iw)
        if x + iw > right and (x > PAD or right < w - PAD) then
            x, y, right, rows = PAD, y + rowH + 4, w - PAD, rows + 1
        end
        local at = x
        x = x + iw + 6
        return at
    end
    for _, p in ipairs(pills) do
        local pw = U.pillWidth(p.label, p.value)
        if pw > maxW then
            -- only a file error is ever this long: the one pill fitted to a whole row
            p.value = fitText(p.value, math.max(0, maxW - (pw - textWidth(p.value))))
            pw = U.pillWidth(p.label, p.value)
        end
        p.x = slot(pw)
        p.y = y + math.floor((rowH - U.CHIP_H) / 2)
        if p == master then
            mb:setVisible(true); mb:setHeight(ch)
            mb:setX(slot(mb.width)); mb:setY(y + math.floor((rowH - ch) / 2))
        end
    end
    g.pills, g.headRows, g.headBottom = pills, rows, y + rowH
    self.headRows = rows
    g.headMinute, g.headPending, g.headMax = math.floor(EC.now() / 60000), pending, self:maxItems()
end

function Page:layout()
    local w, h = self.width, self.height
    local eh, ch, lh = entryH(), chipH(), lineH()
    local on = self:getIsVisible()
    local g = {}
    self.g = g
    -- the switch state this pass was built against (the paint pass re-lays out when it moves)
    self.masterShown = self:masterState()
    self:syncCategoryCombo()

    self.picker:setX(0); self.picker:setY(0)
    self.picker:resize(w, h)
    self.confirm:setX(0); self.confirm:setY(0)
    self.confirm:resize(w, h)

    -- the gate reads the label column the plain rows need; the currencies' own labels are the
    -- quote table's column titles, which placeForm measures for itself
    local labelW, valueW = self:formMetrics(false)
    local editorMinW = math.max(labelW + valueW + PAD * 4, self:quoteColumns().total + 22)
    local listMinW = math.max(200, textWidth("MMMMMMMMMMMMMMMMMMMM"))
    -- the batch form is an editor like any other: it owns the same half of the page, asks before
    -- it is left, and takes the whole page when there is no room for two columns
    local editing = self.draft ~= nil or self.batch ~= nil
    -- the identity block is pinned, so it is part of what an editor needs room for. Side by side
    -- needs room in BOTH directions: with the four header rows above it, a short window would
    -- leave the editor a peephole. Too small either way, the page discloses instead -- the editor
    -- takes the page and the list comes back with the Back chip.
    -- the identity block: the script's own name, the item type and the SKU line. The quotes are
    -- NOT repeated here -- they are the table in the form.
    local identCount = self.batch ~= nil and 2 or 3
    -- side by side is only worth it when the editor really gets a working editor: its title, the
    -- pinned identity lines, one whole label-plus-control row and the action bar. A field below
    -- the fold is reached by scrolling it into view (Form:scrollTo, driven by whoever focuses it),
    -- never by this gate reserving room for it.
    local minFormH = math.max(ch, eh) + fontH.small + 8
    local editorMinH = fontH.medium + 4 + lh * identCount + minFormH + ch + PAD * 2
    -- the pill rows the header took last pass (one unless a narrow window wrapped them) and the
    -- search row under them
    local headerRoom = (math.max(ch, U.CHIP_H) + 4) * (self.headRows or 1) + eh + 16
    local wide = w >= listMinW + editorMinW + PAD * 3
        and (not editing or h - PAD - (CARD_TITLE_H + 4 + headerRoom) >= editorMinH)
    local showList = on and (wide or not editing or self.view ~= "editor")
    local showEditor = on and editing and (wide or self.view == "editor")
    self.wide = wide

    local top = CARD_TITLE_H + 4
    local headerH = 0
    if showList then
        local x = w - PAD
        for _, b in ipairs({ self.addButton, self.reloadButton }) do
            local bw = math.min(textWidth(b.fullTitle) + 24, math.floor(w * 0.34))
            b:setVisible(true); b:setWidth(bw); b:setHeight(ch)
            b:setX(math.max(PAD, x - bw)); b:setY(top)
            U.setButtonTitle(b, b.fullTitle)
            x = x - bw - 6
        end
        -- the catalog, the buyback master switch and the daily reset: one row of pills left of
        -- Add / Reload, wrapping under them when it runs out (placeHeader)
        g.headTop, g.headRight = top, x - PAD
        self:placeHeader()

        local searchY = g.headBottom + 6
        local sx = w - PAD
        -- right to left over the search row: the two money shortcuts, then the two chips the batch
        -- set is operated with (the count of picked rows is painted beside the row count)
        U.setButtonTitle(self.batchButton, self.pickedCount > 0
            and getText(T .. "Admin_Shop_BatchN", tostring(self.pickedCount)) or tr("Admin_Shop_Batch"))
        self.batchButton.tooltip = tr("Admin_Shop_BatchSelectHint")
        self.batchButton.autoTooltip = nil
        for _, b in ipairs({ self.buysButton, self.salesButton, self.clearSelButton, self.batchButton }) do
            local bw = math.min(textWidth(b.fullTitle) + 24, math.floor(w * 0.28))
            b:setVisible(true); b:setWidth(bw); b:setHeight(ch)
            b:setX(math.max(PAD, sx - bw)); b:setY(searchY + math.floor((eh - ch) / 2))
            U.setButtonTitle(b, b.fullTitle)
            sx = sx - bw - 6
        end
        -- The search box, the category filter and the row count share ONE budget, left to right,
        -- and the chips already took the right end (sx). The dropdown is measured from its own
        -- widest option (a translated category is long in some languages), but it may never eat
        -- the search box or the count beside it: what it asks for is capped, and if the row is
        -- still too tight the box shrinks first, then the dropdown, and the count simply has no
        -- room left and is not painted.
        self.catCombo.tooltip = tr("Admin_Shop_CatFilterHint")
        local rowW = math.max(120, sx - PAD * 2)
        local countW = math.min(160, math.floor(rowW * 0.25))
        local fw = math.min(comboWidth(self.catCombo, 110), math.floor(rowW * 0.4))
        local searchW = math.min(260, rowW - fw - countW - 12)
        if searchW < 120 then
            -- too tight for all three: the box keeps a usable width, the dropdown gives way
            searchW = math.max(80, math.min(160, rowW - 60 - 12))
            fw = math.max(60, rowW - searchW - countW - 12)
        end
        self.searchEntry:setVisible(true)
        self.searchEntry:setX(PAD); self.searchEntry:setY(searchY)
        self.searchEntry:setWidth(searchW)
        self.searchEntry:setHeight(eh)
        self.catCombo:setVisible(true)
        self.catCombo:setWidth(fw); self.catCombo:setHeight(eh)
        self.catCombo:setX(PAD + searchW + 6)
        self.catCombo:setY(searchY)
        g.countX = self.catCombo.x + fw + PAD
        g.countY = searchY + math.floor((eh - fontH.small) / 2)
        g.countW = math.max(0, sx - PAD - g.countX)
        headerH = searchY + eh + 6 - top
    else
        for _, b in ipairs({ self.addButton, self.reloadButton, self.masterButton, self.salesButton,
            self.buysButton, self.batchButton, self.clearSelButton }) do
            b:setVisible(false)
        end
        closeCombo(self.catCombo)
        self.catCombo:setVisible(false)
        if self.searchEntry:isFocused() then pcall(self.searchEntry.unfocus, self.searchEntry) end
        self.searchEntry:setVisible(false)
    end

    local bodyY = top + headerH
    local bodyH = math.max(lh, h - PAD - bodyY)
    local listW = wide and math.max(listMinW, math.min(math.floor((w - PAD * 3) * 0.42),
        w - PAD * 3 - editorMinW)) or math.max(80, w - PAD * 2)
    U.placeList(self.list, showList, PAD, bodyY, listW, bodyH)
    g.emptyX, g.emptyY = PAD + PAD, bodyY + 4

    if showEditor then
        local ex = wide and (PAD * 2 + listW) or PAD
        local ew = wide and math.max(120, w - PAD - ex) or math.max(120, w - PAD * 2)
        local ey = wide and bodyY or top
        local eBottom = h - PAD
        g.editorX, g.editorY, g.editorW = ex, ey, ew
        g.titleY = ey
        -- Delete owns the right end of the title row: away from Apply on purpose, and it names how
        -- much it removes (the batch form's count). A new SKU's draft has nothing to remove.
        local del, delW = self.deleteButton, 0
        if self.batch ~= nil or not self.draft.isNew then
            U.setButtonTitle(del, self.batch ~= nil
                and getText(T .. "Admin_Shop_DeleteN", tostring(#self.batch.ids)) or tr("Admin_Shop_Delete"))
            delW = math.min(textWidth(del.fullTitle) + 24, math.floor(ew * 0.4))
            del:setVisible(true); del:setWidth(delW); del:setHeight(ch)
            del:setX(ex + ew - delW)
            del:setY(ey + math.max(0, math.floor((fontH.medium + 4 - ch) / 2)))
            U.setButtonTitle(del, del.fullTitle)
        else
            del:setVisible(false)
        end
        g.titleText = fitText(self.batch ~= nil
            and getText(T .. "Admin_Shop_BatchTitle", tostring(#self.batch.ids))
            or (self.draft.isNew and tr("Admin_Shop_NewTitle") or itemName(self.draft.item)),
            math.max(0, ew - (delW > 0 and delW + 6 or 0)), UIFont.Medium)
        -- the identity block: pinned, never scrolled, never traded away for a field. The SKU line
        -- (the batch form's target count) is the load-bearing one; the names above it are the
        -- secondary text.
        local titleH = fontH.medium + 4
        local strong = self.batch ~= nil and 1 or identCount
        local lines = {}
        for i = 1, identCount do
            lines[i] = { text = "", token = i >= strong and "text" or "textMuted" }
        end
        g.identLines = lines
        g.identY = ey + titleH
        self:refreshIdent()
        -- The pinned block is BOUNDED. One whole label-plus-control row is reserved for the field
        -- area first, and the note and the warning share only what is left over: a four-line
        -- server refusal plus a two-line master warning may never be the reason that no field is
        -- on screen at all. What does not fit is marked and shown whole in the detail window.
        local actionY = eBottom - ch
        -- the same row the wide gate reserved: the note and the warning only ever get what is
        -- left over, because a field on screen is worth more than a line of prose the detail
        -- window holds in full
        local minFormH = math.max(ch, eh) + fontH.small + 8
        local textTop = g.identY + identCount * lh + 2
        local maxLines = math.max(0, math.floor((actionY - 6 - minFormH - 4 - textTop) / lh))
        g.noteY, g.noteW = textTop, ew
        g.noteMax = math.min(maxLines, 3)
        self:refreshNote()
        local used = #g.noteLines
        local paused = self:refreshEditorChips()
        -- configured buyback the master switch is holding shut: pinned above the scrolling field
        -- area, so it is never the line that scrolled out of sight -- within the same budget
        g.warnY = textTop + used * lh
        g.warnLines, g.warnFull = nil, nil
        -- whether the warning is in force at all (the detail text carries it whole either way);
        -- warnFull stays the "and the pinned line could not show all of it" marker
        g.warnActive = paused == true
        if paused then
            local full = tr("Admin_Shop_MasterWarn")
            local left = math.max(0, maxLines - used)
            local all = U.wrapText(full, ew, math.huge)
            if left > 0 then
                local shown = {}
                for i = 1, math.min(#all, left) do shown[i] = all[i] end
                if #all > left then shown[left] = fitText(tr("Admin_Shop_MoreInDetail"), ew) end
                g.warnLines = shown
            end
            if g.warnLines == nil or #all > #g.warnLines then g.warnFull = full end
        end

        local buttons = { self.applyButton, self.cancelButton, self.detailButton }
        if not wide then buttons[#buttons + 1] = self.backButton end
        self.backButton:setVisible(not wide)
        local bx = ex
        local room = math.floor((ew - 6 * (#buttons - 1)) / #buttons)
        for _, b in ipairs(buttons) do
            local bw = math.min(textWidth(b.fullTitle) + 24, room)
            b:setVisible(true); b:setWidth(bw); b:setHeight(ch)
            b:setX(bx); b:setY(actionY)
            U.setButtonTitle(b, b.fullTitle)
            bx = bx + room + 6
        end

        -- The field area takes everything under the pinned block, and the action bar is pinned
        -- under it. Two clamps, and the comment above the budget depends on both being true: the
        -- pinned block may never push the field area below ONE WHOLE CONTROL ROW (a viewport
        -- shorter than a row can show no field at all -- placeGroup only shows a control that
        -- fits whole, so Form:scrollTo could not reveal one either), and the field area may never
        -- run into the action bar. When even the title plus one row does not fit, the page is
        -- smaller than anything it could honestly lay out and the row wins over the prose.
        local formBottom = actionY - 6
        local rowMin = math.max(ch, eh) + 4
        local formY = math.min(g.warnY + (g.warnLines and #g.warnLines * lh or 0) + 4,
            math.max(ey + fontH.medium + 4, formBottom - minFormH))
        self.form:setVisible(true)
        self.form:setX(ex); self.form:setY(formY)
        self.form:setWidth(ew); self.form:setHeight(math.max(rowMin, formBottom - formY))
    else
        self.form:setVisible(false)
        for _, b in ipairs(self.editorButtons) do b:setVisible(false) end
    end

    self:buildDetailText()
    self:placeForm()
    self:rebuildRows()
    self:updateEnabled()
end

function Page:resize(width, height)
    if self.width ~= width then self:setWidth(width) end
    if self.height ~= height then self:setHeight(height) end
    self:layout()
end

-- Hiding the page takes its controls off the keyboard's list and closes what floats over it -- the
-- native dropdown's popup included, because that one is added to the UIManager. The draft is NOT
-- touched: only a confirmed discard or a lost right may drop it.
function Page:setVisible(visible)
    local was = self:getIsVisible()
    ISPanel.setVisible(self, visible)
    if not visible then
        self.picker:close()
        self.confirm:close()
        closeCombo(self.catCombo)
        closeCombo(self.categoryCombo)
        self:unfocusAll()
        Detail.close(self)
    end
    if self.list ~= nil and was ~= visible then self:layout() end
end

-- ----- painting -----

function Page:prerender()
    -- Another admin's change reaches this client as a shop push (C.shop), with no admin.catalog
    -- reply of our own and no poll: the switch, the row markers and the editor's warning all read
    -- off that state, so a change in it is the one thing worth a re-layout from the paint pass.
    if self:masterState() ~= self.masterShown then self:layout() end
    local g = self.g
    if not g then return end
    card(self, 0, 0, self.width, self.height, tr("Admin_Shop_Title"))
    if self.searchEntry:getIsVisible() then
        -- the header pills: placed again only when what they say moved (the reset countdown is
        -- whole minutes), and a re-layout only when that changed how many rows they take
        if math.floor(EC.now() / 60000) ~= g.headMinute or self:maxItems() ~= g.headMax
            or (self.isPending("admin.catalog") and true or false) ~= g.headPending then
            local rows = g.headRows
            self:placeHeader()
            if g.headRows ~= rows then
                self:layout()
                g = self.g
            end
        end
        if g.pills then
            for _, p in ipairs(g.pills) do U.drawPill(self, p.x, p.y, p.label, p.value, p.token) end
        end
        if g.countW > 0 then
            -- how many rows the filters left, and how many of them are in the batch set: the set
            -- is a number on screen, not something only the highlight tells
            local count = getText(T .. "Admin_Shop_Count", tostring(#(self.rows or {})))
            if self.pickedCount > 0 then
                count = count .. "  /  " .. getText(T .. "Admin_Shop_SelCount", tostring(self.pickedCount))
            end
            text(self, fitText(count, g.countW), g.countX, g.countY,
                self.pickedCount > 0 and "accent" or "textFaint")
        end
    end
    if self.list:getIsVisible() and #(self.rows or {}) == 0 then
        local empty
        if self.catalog == nil then
            empty = self.isPending("admin.catalog") and tr("Admin_Loading") or tr("Admin_Dash_Empty")
        elseif trimText(entryText(self.searchEntry)) ~= "" or self.catFilterKey ~= nil then
            empty = tr("Admin_Shop_NoMatch")
        else
            empty = tr("Admin_Shop_Empty")
        end
        text(self, empty, g.emptyX, g.emptyY, "textFaint")
    end
    if self.form:getIsVisible() then
        text(self, g.titleText, g.editorX, g.titleY, "text", UIFont.Medium)
        local y = g.identY
        for _, line in ipairs(g.identLines or {}) do
            -- the identity lines own their reserved rows; the clamp is what keeps a very short
            -- editor from painting them over the note beneath them
            if y + fontH.small > g.noteY then break end
            text(self, line.text, g.editorX, y, line.token)
            y = y + lineH()
        end
        local noteY = g.noteY
        for _, line in ipairs(g.noteLines or {}) do
            text(self, line, g.editorX, noteY, g.noteToken)
            noteY = noteY + lineH()
        end
        if g.warnLines then
            local wy = g.warnY
            for _, line in ipairs(g.warnLines) do
                text(self, line, g.editorX, wy, "warn")
                wy = wy + lineH()
            end
        end
    elseif self.list:getIsVisible() and self.wide then
        local x = PAD * 2 + self.list.width
        -- wrapped, never cut: the drag hint is its second half. Cached per width (no per-frame table).
        local w = math.max(0, self.width - PAD - x)
        if self.selectW ~= w then
            self.selectW, self.selectLines = w, U.wrapText(tr("Admin_Shop_Select"), w, math.huge)
        end
        local y = self.list.y + 4
        for _, line in ipairs(self.selectLines) do
            text(self, line, x, y, "textFaint")
            y = y + lineH()
        end
    end
end

function Page:render() end

-- ----- keyboard -----

function Page:isModal()
    return self.picker:isOpen() or self.confirm:getIsVisible()
end

-- Escape belongs to whatever this page put over itself, and to nothing else: the root only eats
-- the key when one of them really closed. An open dropdown is ECKeyboard's own (it drops the
-- popup and leaves the value alone), so it is not answered here.
function Page:onEscape()
    if self.picker:isOpen() then
        self.picker:cancel()
        self:layout()
        return true
    end
    if self.confirm:getIsVisible() then
        self.confirm:close()
        self:layout()
        return true
    end
    return false
end

function Page:keyboardTargets()
    if self.picker:isOpen() then return self.picker:keyboardTargets() end
    local out = {}
    local function add(kind, label, control)
        out[#out + 1] = { kind = kind, label = label, control = control }
    end
    local function group(label, buttons)
        local shown = {}
        for _, b in ipairs(buttons) do
            if b:getIsVisible() then shown[#shown + 1] = b end
        end
        if #shown > 0 then out[#out + 1] = { kind = "group", label = label, controls = shown } end
    end
    if self.confirm:getIsVisible() then
        group(tr("Admin_Shop_DiscardTitle"), { self.confirm.keepButton, self.confirm.discardButton })
        return out
    end
    if self.searchEntry:getIsVisible() then
        add("entry", tr("Admin_Shop_Search"), self.searchEntry)
        if self.catCombo:getIsVisible() then add("combo", tr("Admin_Shop_CatFilter"), self.catCombo) end
        group(tr("Admin_Shop_Title"), { self.reloadButton, self.addButton, self.masterButton,
            self.salesButton, self.buysButton, self.batchButton, self.clearSelButton })
    end
    -- Enter picks the row (opens it), Ctrl+Enter puts it in the batch set and Shift+Enter takes
    -- the range: all three arrive at onRow, so the keyboard picks a set exactly like the mouse
    if self.list:getIsVisible() then add("list", tr("Admin_Shop_SelectKb"), self.list) end
    if self.form:getIsVisible() then
        if self.form:maxScrollOffset() > 0 then
            out[#out + 1] = { kind = "scroll", label = tr("Admin_Shop_Editor"), control = self.form,
                focusable = false }
        end
        -- EVERY field of the open editor, whether it is inside the scrolling viewport right now or
        -- not: what the ring may reach is a property of the draft, not of the current scroll
        -- offset. `scrollOwner` is the field area that can bring one into view (Form:scrollTo),
        -- so a reveal belongs to whoever focuses the target -- this page never guesses a scroll
        -- offset from the ring's position. A build that ignores the hint behaves exactly as
        -- before: ECKeyboard drops a control that is not visible (MinidoracatUI/Focus.lua usable).
        local function field(kind, label, control)
            out[#out + 1] = { kind = kind, label = label, control = control,
                scrollOwner = self.form }
        end
        -- a "?" marker is reached right before the field it explains, and only while the open
        -- form placed it (placeTip records its row). Its caption is the short rule itself
        -- (fullTitle), drawn under the ring and kept inside the window by the framework.
        local function tip(b)
            if b ~= nil and b.ecFormY ~= nil then
                out[#out + 1] = { kind = "button", label = b.fullTitle, control = b,
                    scrollOwner = self.form, captionSide = "below" }
            end
        end
        tip(self.batchTip)
        if self.draft ~= nil and self.draft.isNew == true then
            field("entry", tr("Admin_Shop_Id"), self.idEntry)
        end
        -- every column, in the order the form paints them: a box, the native dropdown (which the
        -- ring opens and commits through its own API) or a switch
        for _, spec in ipairs(self.fields) do
            local kind = "button"
            if spec.entry then kind = "entry" elseif spec.combo then kind = "combo" end
            tip(spec.tip)
            field(kind, self:specLabel(spec), spec.control)
        end
        group(tr("Admin_Shop_Editor"), self.editorButtons)
    end
    return out
end

-- ----- lifecycle -----

function Page:refresh()
    self.owner:requestCatalog()
end

-- The clock the controller drives while this page is on screen. Two things need it: the picker's
-- search debounce, and the editor's boxes -- an IME commit writes the box without firing
-- onTextChangeFunction, so the open draft's editable fields are polled for it.
function Page:tick(now)
    if entryText(self.searchEntry) ~= self.searchSeen then self:onSearch() end
    if self.draft ~= nil or self.batch ~= nil then
        local changed = false
        for _, e in ipairs(self.form.childrenInOrder) do
            if e.getInternalText and e.isEditable and e:isEditable() then
                local value = entryText(e)
                if e.ecSeenText ~= value then e.ecSeenText = value; changed = true end
            end
        end
        if changed then self:onFieldEdit() end
    end
end

-- Everything this page learned or typed, dropped. Reached by the controller when the admin right
-- is gone and by dispose(); never by a plain hide.
function Page:clear()
    self.catalog = nil
    self.updatedAt = nil
    self.selectedId = nil
    self.cursorId = nil
    self.saveRequestId = nil
    self.rows = {}
    self.list:setItems({})
    self.list:setSelectedIndex(nil)
    self.picker:close()
    self.confirm:close()
    closeCombo(self.catCombo)
    closeCombo(self.categoryCombo)
    Detail.close(self)
    self.draft = nil
    self.draftBase = nil
    self.draftRevision = nil
    self.batch = nil
    self.batchSent = nil
    self.batchRevision = nil
    self:clearPicks()
    self:clearCategoryFilter()
    self.baseMoved = false
    self.saveError = nil
    self.view = "list"
    self.form.scrollOffset = 0
    setEntryText(self.searchEntry, "")
    self.searchSeen = ""
    self:refreshTxHint()
end

function Page:dispose()
    self:clear()
    self:unfocusAll()
    self.picker:dispose()
end

-- ---------- module API ----------

-- owner: the admin controller. Returns an initialised child the owner adds, positions and
-- resizes. No command is sent from here; isPending is the owner's own plain function.
function P.create(owner, isPending)
    local o = ISPanel:new(0, 0, 600, 300)
    setmetatable(o, Page)
    o.background = false
    o.owner = owner
    o.isPending = isPending
    o.view = "list"
    o.rows = {}
    -- the batch set exists before the children do: the list is handed this very table
    o.picked = {}
    o.pickedCount = 0
    -- the category filter: no category picked means every category
    o.catFilterKey = nil
    o:initialise()
    o:instantiate()   -- builds the children now; the owner only has to addChild/resize
    o:setVisible(false)
    return o
end

return P
