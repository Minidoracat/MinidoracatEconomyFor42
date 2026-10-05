-- MinidoracatEconomyFor42 — client UI toolkit shared by the Economy Center tabs (ECPanel,
-- ECAdminPanel): theme tokens, paint helpers over MinidoracatUIFor42 v1 (Theme/Skin), number/time
-- formatting, the skinned Button (chip / primary) and table cells for VirtualList.
--
-- U.init() resolves the framework once per session: every window calls it before it is built, and
-- C.ItemPicker.universe calls it for the item menu, which builds no window (anything else reached
-- before a window must do the same rather than read U.framework). Every helper reads U.theme /
-- U.Skin / U.fontH at call time, so files may alias them at load.
--
-- Engine references (snapshot 42.20.4-20260826):
--   getHourMinute()   LuaManager.java:8996-8998 -> getHourMinuteJava :1569-1576 (Calendar local zone)
--   getTextOrNull     LuaManager.java:8558-8560

require "ISUI/ISButton"
require "ISUI/ISPanel"
require "ISUI/ISTextEntryBox"

if not MinidoracatEconomy or not MinidoracatEconomy.Client then
    require "MinidoracatEconomy/ECClient"
end
local EC = MinidoracatEconomy
local C = EC.Client

local U = {}
C.UI = U

-- Spacing scale (a "comfortable" default; the admin panel additionally derives its row heights
-- from the font). Icons are 64 px textures drawn scaled, so larger sizes cost nothing.
U.PAD = 12
U.ROW = 28
U.CHIP_H = 26
U.COIN = 30
U.COIN_SMALL = 22
U.T = "IGUI_MinidoracatEconomy_"
local PAD, ROW, COIN, COIN_SMALL, T = U.PAD, U.ROW, U.COIN, U.COIN_SMALL, U.T

-- MOD-own theme tokens (framework tokens: surface/surfaceTitle/well/border/text/textMuted/
-- textFaint/accent/hover/selected/errorSurface/errorText — V1.lua DARK table)
local MOD_COLORS = {
    gold = { r = 0.76, g = 0.55, b = 0.12, a = 1 },
    goldHover = { r = 0.88, g = 0.66, b = 0.18, a = 1 },
    goldPressed = { r = 0.60, g = 0.42, b = 0.08, a = 1 },
    goldLight = { r = 1, g = 0.92, b = 0.65, a = 0.28 },   -- top highlight band
    goldDark = { r = 0.42, g = 0.28, b = 0.04, a = 1 },    -- border / bottom shade
    goldText = { r = 0.12, g = 0.08, b = 0.02, a = 1 },
    goldEmboss = { r = 1, g = 0.92, b = 0.65, a = 0.35 }, -- 1px text offset under the label
    coin = { r = 0.90, g = 0.70, b = 0.25, a = 1 },
    coinRim = { r = 0.55, g = 0.40, b = 0.10, a = 1 },
    positive = { r = 0.45, g = 0.85, b = 0.45, a = 1 },
    negative = { r = 0.95, g = 0.45, b = 0.40, a = 1 },
    warn = { r = 1, g = 0.72, b = 0.30, a = 1 },
    card = { r = 1, g = 1, b = 1, a = 0.04 },
    surface = { r = 0, g = 0, b = 0, a = 1 },    -- 100 % on the opacity slider means opaque (framework default is 0.8)
    track = { r = 1, g = 1, b = 1, a = 0.10 },
    -- a disabled control's label: dimmer than textFaint (#8C8C8C reads as enabled next to the
    -- idle textMuted #9E9E9E, 1.25:1), still legible on the opaque surface (#666, 3.66:1). The
    -- framework has the same token from rev 12; this copy keeps it under a rev 11 framework.
    textDisabled = { r = 0.40, g = 0.40, b = 0.40, a = 1 },
}

local color, fill, border, text, textWidth, fitText, textRight, textCentre, strike, drawCoin, clockText, dateText, stampText, durationText, amountText, signedText, hasBit, kindText, pad2

U.framework = nil   -- MinidoracatUI.v1 facade (set by U.init)
U.Skin = nil
U.theme = nil
U.fontH = { small = 0, medium = 0 }   -- filled by U.init (table identity is stable: alias freely)
local fontH = U.fontH

-- rev 10: the keyboard/controller focus engine (C.Keyboard, see ECKeyboard) is the framework's.
-- rev 11: so are the date field/calendar, the table shell and header, the filter bar, the item
-- picker overlay and the candidate box every Economy page builds on.
local REQUIRED = { "theme", "skin", "virtualList", "focus", "controls", "datePicker", "table", "filterBar",
    "itemPicker", "autocomplete" }
local function framework()
    local ui = MinidoracatUI and MinidoracatUI.v1
    if not (ui and ui.API_MAJOR == 1 and ui.API_REVISION >= 11 and ui.CAPABILITIES) then return nil end
    for _, cap in ipairs(REQUIRED) do
        if ui.CAPABILITIES[cap] ~= true then return nil end
    end
    return ui
end

-- Returns the facade or nil (logged once). Safe to call repeatedly.
function U.init()
    if U.framework then return U.framework end
    if not (MinidoracatUI and MinidoracatUI.v1) then
        pcall(require, "MinidoracatUI/V1")
    end
    for _, spec in ipairs({ { "virtualList", "VirtualList" }, { "focus", "Focus" }, { "controls", "Widgets/Controls" },
        { "datePicker", "Widgets/DatePicker" }, { "table", "Widgets/Table" }, { "filterBar", "Widgets/FilterBar" },
        { "itemPicker", "Widgets/ItemPicker" }, { "autocomplete", "Widgets/Autocomplete" } }) do
        local ui = MinidoracatUI and MinidoracatUI.v1
        if not (ui and ui.CAPABILITIES[spec[1]]) then pcall(require, "MinidoracatUI/" .. spec[2]) end
    end
    local ui = framework()
    if not ui then
        if not U.warned then
            EC.log("MinidoracatUI v1 (rev>=11 with focus, controls, datePicker, table, filterBar, itemPicker, autocomplete) missing: Economy Center UI disabled")
            U.warned = true
        end
        return nil
    end
    U.framework = ui
    U.Skin = ui.Skin
    U.theme = ui.Theme.create({ colors = MOD_COLORS })
    U.theme.alpha = U.alpha   -- a ModOptions value set before the first window
    fontH.small = getTextManager():getFontHeight(UIFont.Small)
    fontH.medium = getTextManager():getFontHeight(UIFont.Medium)
    return ui
end

-- Every word on screen comes from the four translation files. A code with no sentence (a newer
-- server, a value another mod added) is written to the log once and never shown.
local unknownLogged = {}
local function logUnknown(what, code)
    local tag = tostring(what) .. ": " .. tostring(code)
    if unknownLogged[tag] then return end
    unknownLogged[tag] = true
    EC.log("no translation for " .. tag)
end
-- A refusal with no sentence of its own reads as its page's generic one; the caller logs the code.
U.logUnknown = logUnknown

-- An enumerated value (state, kind, origin...) the translation files do not know.
function U.unknownText(what, code)
    logUnknown(what, code)
    return getText(T .. "Common_Unknown")
end

-- Shared by the admin controller and its transaction page. An integration source's refused
-- transfers are counted by code alone (ECIntegration reject); the player's transfer sentences that
-- take no argument read the same to an admin, the ones that quote an amount or a date have an
-- Admin_Error_* of their own.
local TRANSFER_ERROR = { transfer_disabled = true, currency_not_transferable = true, self_transfer = true,
    unknown_recipient = true, recipient_frozen = true, recipient_cap = true }
function U.adminErrorText(code)
    local key = tostring(code == nil and "unknown" or code)
    local s = getTextOrNull(T .. "Admin_Error_" .. key) or getTextOrNull(T .. "Market_Error_" .. key)
        or (TRANSFER_ERROR[key] and getTextOrNull(T .. "Transfer_Error_" .. key))
    if s then return s end
    logUnknown("admin error", key)
    return getText(T .. "Admin_Error_unknown")
end

-- A market record's reason: the one the server writes itself (an auction cancelled by downtime)
-- reads as words; anything else is what an admin typed and is shown as written.
local MARKET_REASON_KEY = { downtime = "Reason_auction_downtime" }
function U.marketReasonText(reason)
    local key = MARKET_REASON_KEY[reason]
    if key then return getText(T .. key) end
    return reason
end

-- An actor column names a player, or one of the server's own actors.
local ACTOR_KEY = { SYSTEM = "Actor_SYSTEM", COMPANION = "Actor_COMPANION" }
function U.actorText(actor)
    local key = ACTOR_KEY[actor]
    if key then return getText(T .. key) end
    return tostring(actor or "-")
end

-- A whitelist.json / catalog.json the server refused arrives as a code plus facts (ECCodec
-- stringSet, ECShop validateSku): every code's sentence names its arguments in this order. JSON
-- field names, the item id and an unregistered currency id stay as written - they are what the
-- host goes and finds in the file; the two currencies of an arbitrage pair are named.
local FILE_ERR_ARGS = {
    json = {}, unavailable = {}, row_not_object = {}, no_price = {}, duplicate_id = {},
    json_line = { "line" }, not_array = { "field" }, not_object = { "field" }, bad_scope = { "field" },
    not_boolean = { "field" }, mixed_prices = { "field" }, buyback_needs_bid = { "field" },
    no_items = { "field" }, too_many = { "field", "max" }, bad_entry = { "field", "entry", "max" },
    bad_id = { "field", "max" }, bad_text = { "field", "max" }, unknown_item = { "field", "item" },
    range = { "field", "min", "max" }, unknown_currency = { "currency" },
    arbitrage = { "id", "currency", "otherId", "otherCurrency" },
}

-- The sentence for one failure table, placed at its catalog row (id, else 1-based index) when it
-- has one; nil (logged) for a code this client does not know.
function U.fileErrorDetail(d)
    if type(d) ~= "table" then return nil end
    local code = d.code == "json" and d.line ~= nil and "json_line" or d.code
    local names = FILE_ERR_ARGS[code]
    if names == nil then
        logUnknown("file error", d.code)
        return nil
    end
    local a = {}
    for i, name in ipairs(names) do
        local v = d[name]
        if code == "arbitrage" and (name == "currency" or name == "otherCurrency") then v = U.currencyName(v) end
        a[i] = v == nil and "-" or tostring(v)
    end
    local key = T .. "Admin_FileErr_" .. code
    local s
    if #a == 0 then s = getText(key)
    elseif #a == 1 then s = getText(key, a[1])
    elseif #a == 2 then s = getText(key, a[1], a[2])
    elseif #a == 3 then s = getText(key, a[1], a[2], a[3])
    else s = getText(key, a[1], a[2], a[3], a[4]) end
    if code == "arbitrage" then return s end   -- names both rows itself
    if d.id ~= nil then return getText(T .. "Admin_FileErr_AtId", tostring(d.id), s) end
    if d.index ~= nil then return getText(T .. "Admin_FileErr_AtIndex", tostring(d.index), s) end
    return s
end

-- The refusal code's own sentence, followed by what the file got wrong when the server said.
function U.fileErrorText(code, detail)
    local head = U.adminErrorText(code)
    local tail = U.fileErrorDetail(detail)
    if tail == nil then return head end
    return getText(T .. "Admin_FileErr", head, tail)
end

-- The audit page's change column for a catalog / whitelist line the server wrote as facts
-- (ECShop.add, ECShop.reload, ECCodec.reload): a new SKU's item, lot size and every quote; a
-- reload's outcome, or the same refusal the page shows. nil for anything else, including the
-- older lines that carried a sentence in `after` - those read as they were stored.
function U.catalogAuditText(e)
    if type(e) ~= "table" or (e.action ~= "catalog" and e.action ~= "whitelist") then return nil end
    if e.field == "reload" and type(e.ok) == "boolean" then
        if not e.ok then return U.fileErrorText(e.errorCode, e.errorDetail) end
        if e.action == "catalog" then return getText(T .. "Admin_Shop_Reloaded", tostring(tonumber(e.count) or 0)) end
        return getText(T .. "Admin_Wl_Reloaded")
    end
    if e.action == "catalog" and e.field == "add" and type(e.quotes) == "table" then
        local parts = {}
        for _, q in ipairs(e.quotes) do
            if type(q) == "table" then
                parts[#parts + 1] = getText(T .. "Admin_Audit_CatalogQuote", U.currencyName(q.currency),
                    U.amountText(q.price), U.amountText(q.bidPrice))
            end
        end
        return getText(T .. "Admin_Audit_CatalogAdd", U.itemName(e.item), tostring(tonumber(e.qty) or 1),
            #parts > 0 and table.concat(parts, getText(T .. "Admin_Set_ListSep")) or "-")
    end
    return nil
end

function U.currencyDefs()
    return C.currencies or (C.session and C.session.currencies) or nil
end

function U.currencyDef(id)
    for _, cur in ipairs(U.currencyDefs() or {}) do
        if cur.id == id then return cur end
    end
    return nil
end

function U.currencyName(id)
    local cur = U.currencyDef(id)
    if cur and type(cur.nameOverride) == "string" and cur.nameOverride ~= "" then return cur.nameOverride end
    local static = EC.CURRENCIES[id]
    if static then return getText(static.nameKey) end
    return tostring(id)
end

function U.itemName(fullType)
    if type(fullType) ~= "string" then return tostring(fullType or "-") end
    return C.itemLabel(fullType)
end

-- Item icon (Item.java:1650-1652), cached per fullType for the whole session; false = asked and
-- missing. Every geometry change rebuilds every row, and ScriptManager lookups are not free.
-- Picked-up furniture (C.moveableSprite) has no script: its icon is the sprite cut to an icon, or
-- the flat-pack box for a piece of a multi-tile object, as the inventory paints it
-- (Moveable.java:175-227).
local itemTextures = {}
function U.itemTexture(fullType)
    if type(fullType) ~= "string" then return nil end
    local cached = itemTextures[fullType]
    if cached ~= nil then return cached or nil end
    local tex = nil
    local sprite = C.moveableSprite(fullType)
    pcall(function()
        if sprite then
            local grid = getSprite(sprite):getSpriteGrid()
            tex = grid and getTexture("Item_Flatpack") or getTexture(sprite)
            if tex and not grid then tex = tex:splitIcon() end
            return
        end
        local script = ScriptManager and ScriptManager.instance and ScriptManager.instance:FindItem(fullType)
        if script then tex = script:getNormalTexture() end
    end)
    itemTextures[fullType] = tex or false
    return tex
end

-- Shop catalog category: the mod's own label, falling back to the raw key the file wrote.
function U.categoryText(category)
    return getTextOrNull(T .. "Shop_Cat_" .. tostring(category)) or tostring(category or "-")
end

-- An item's own category (EC.itemCategory), named the way vanilla's inventory names it
-- (IGUI_ItemCat_*, ISInventoryPane.lua:2547); a MOD category with no translation shows its key.
-- The engine's misspelt "VehicleMantenance" reads vanilla's correctly spelt key.
function U.itemCategoryText(category)
    local key = tostring(category or "-")
    if key == "VehicleMantenance" then key = "VehicleMaintenance" end
    return getTextOrNull("IGUI_ItemCat_" .. key) or key
end

function U.newEntry(width, height, opts)
    local e = ISTextEntryBox:new("", 0, 0, width, height)
    e:initialise()
    e:instantiate()
    local bg, br = color("well"), color("border")
    e.backgroundColor = { r = bg.r, g = bg.g, b = bg.b, a = 0.9 }
    e.borderColor = { r = br.r, g = br.g, b = br.b, a = 1 }
    opts = opts or {}
    if opts.maxLen and e.setMaxTextLength then e:setMaxTextLength(opts.maxLen) end
    if opts.multiline and e.setMultipleLine then
        e:setMultipleLine(true)
        if e.setMaxLines then e:setMaxLines(opts.maxLines or 4) end
    end
    if opts.clear and e.setClearButton then e:setClearButton(true) end
    if opts.placeholder and e.setPlaceholderText then e:setPlaceholderText(opts.placeholder) end
    return e
end

function U.entryText(entry)
    if not entry then return "" end
    local ok, value = pcall(function() return entry:getInternalText() end)
    if ok and type(value) == "string" then return value end
    return ""
end

function U.setEntryText(entry, value)
    if entry then pcall(function() entry:setText(value or "") end) end
end

function U.setEntryEditable(entry, editable)
    if not entry then return end
    pcall(function() entry:setEditable(editable == true) end)
    if not editable then pcall(function() entry:unfocus() end) end
end

function U.setButtonTitle(button, full, font)
    button.fullTitle = full
    button:setTitle(fitText(full, math.max(8, button.width - 12), font))
end

function U.placeList(list, visible, x, y, width, height)
    list:setVisible(visible)
    list:setX(x); list:setY(y)
    if list.width ~= width or list.height ~= height then list:resize(width, height) end
end

function U.color(token) return U.theme.colors[token] end

-- Panel opacity (the "chrome"): every fill/border the panels paint is scaled by U.alpha, text
-- and icons stay solid. Set from ECOptions (ModOptions slider) and the title-row slider. The
-- framework's own controls (rev 11 theme.alpha) read the same value off the theme.
U.alpha = 1
function U.setAlpha(v)
    v = tonumber(v) or 1
    if v < 0.2 then v = 0.2 elseif v > 1 then v = 1 end
    U.alpha = v
    if U.theme then U.theme.alpha = v end
end

function U.fill(el, x, y, w, h, token, shape)
    U.theme:fill(el, x, y, w, h, token, shape, U.alpha)
end

function U.border(el, x, y, w, h, token, shape)
    U.theme:border(el, x, y, w, h, token, shape, U.alpha)
end

function U.text(el, str, x, y, token, font)
    local c = color(token)
    el:drawText(str, x, y, c.r, c.g, c.b, c.a, font or UIFont.Small)
end

function U.textWidth(str, font)
    return getTextManager():MeasureStringX(font or UIFont.Small, str)
end

-- StringLib.java:760-768 uses Java char in Kahlua; ordinary Lua uses UTF-8 bytes.
-- Binary search keeps long account names cheap and never cuts a surrogate pair/codepoint.
local charOK, char256 = pcall(string.char, 256)
local utf16 = charOK and string.byte(char256) == 256
function U.fitText(str, maxW, font)
    if maxW <= 0 then return "" end
    if textWidth(str, font) <= maxW then return str end
    if textWidth("...", font) > maxW then return "" end
    local low, high, best = 0, #str, "..."
    while low <= high do
        local mid = math.floor((low + high) / 2)
        local n = mid
        if utf16 then
            local unit = n > 0 and string.byte(str, n) or 0
            if unit >= 55296 and unit <= 56319 then n = n - 1 end
        else
            while n > 0 do
                local unit = string.byte(str, n + 1)
                if not unit or unit < 128 or unit >= 192 then break end
                n = n - 1
            end
        end
        local cut = string.sub(str, 1, n) .. "..."
        if textWidth(cut, font) <= maxW then
            best = cut
            low = mid + 1
        else
            high = mid - 1
        end
    end
    return best
end

-- A transaction may have several receipt lines. Key the immutable record, not its txId;
-- rollback status and local sort position are annotations, not record identity.
function U.recordKey(record)
    local immutable = {}
    for key, value in pairs(record) do
        if key ~= "rolledBack" and key ~= "ord" then immutable[key] = value end
    end
    return EC.jsonEncode(immutable)
end

-- Split on the same UTF-16/UTF-8 boundaries as fitText. Used by scrolling detail views;
-- the unwrapped value is retained separately for copying. A line that would end inside a word
-- breaks at its last space instead, as long as that keeps at least a third of the line (English
-- and other spaced text; CJK, which carries no spaces, still breaks at the character that fits).
-- CJK closing punctuation never starts a line: the character before it moves down with it.
-- Kahlua strings are UTF-16, so each of these is one code unit (under standard Lua's UTF-8 they
-- never match, and the plain cut stands): U+3001 U+3002 U+FF0C U+FF0E U+FF09 U+300D U+300F
-- U+3011 U+3009 U+300B U+FF1A U+FF1B U+FF01 U+FF1F U+30FB.
U.NO_LINE_START = { [12289] = true, [12290] = true, [65292] = true, [65294] = true, [65289] = true,
    [12301] = true, [12303] = true, [12305] = true, [12297] = true, [12299] = true, [65306] = true,
    [65307] = true, [65281] = true, [65311] = true, [12539] = true }
function U.wrapText(s, w, maxLines)
    local out, rest = {}, tostring(s or "")
    while rest ~= "" and #out < maxLines do
        local cut = fitText(rest, w)
        if cut == rest or string.sub(cut, -3) ~= "..." then
            out[#out + 1] = rest
            rest = ""
        else
            local n = #cut - 3
            if n <= 0 then
                out[#out + 1] = cut
                rest = ""
            else
                -- English breaks at the last space; Chinese / Japanese break at any character, so
                -- a cut touching a non-ASCII character is taken as it is (a space beside a number
                -- or "ATM" in a CJK sentence must not push the rest of the line down)
                local space = nil
                local a, b = string.byte(rest, n), string.byte(rest, n + 1)
                if a and b and a < 128 and b < 128 and a ~= 32 and b ~= 32 then
                    for i = n, math.floor(n / 3) + 1, -1 do
                        if string.byte(rest, i) == 32 then space = i; break end
                    end
                end
                if space then
                    out[#out + 1] = string.sub(rest, 1, space - 1)
                    rest = string.sub(rest, space + 1)
                else
                    if n > 1 and U.NO_LINE_START[string.byte(rest, n + 1)] then n = n - 1 end
                    out[#out + 1] = string.sub(rest, 1, n)
                    rest = string.sub(rest, n + 1)
                end
                while string.byte(rest, 1) == 32 do rest = string.sub(rest, 2) end
            end
        end
    end
    return out
end

function U.setWrappedText(box, value, width)
    -- UITextBox2.update does not run UIElement's deferred resize pass. Place its scrollbar
    -- explicitly after the caller assigned the final box size, even when the text is unchanged.
    local scroll = box.vscroll
    if scroll then
        if scroll.anchorRight then scroll:setAnchorRight(false) end
        if scroll.anchorBottom then scroll:setAnchorBottom(false) end
        local x = math.max(0, box.width - scroll.width)
        if scroll.x ~= x then scroll:setX(x) end
        if scroll.y ~= 0 then scroll:setY(0) end
        if scroll.height ~= box.height then scroll:setHeight(box.height) end
    end
    value = tostring(value or "")
    width = math.max(80, width - 20)
    if box.ecRawText == value and box.ecWrapWidth == width then return end
    local changed = box.ecRawText ~= value
    local lines = {}
    for line in (string.gsub(value, "\r\n", "\n") .. "\n"):gmatch("(.-)\n") do
        if line == "" then lines[#lines + 1] = ""
        else
            for _, part in ipairs(U.wrapText(line, width, math.huge)) do lines[#lines + 1] = part end
        end
    end
    box.ecRawText, box.ecWrapWidth = value, width
    U.setEntryText(box, table.concat(lines, "\n"))
    if changed then box:setYScroll(0) end
end

function U.textRight(el, str, rightX, y, token, font)
    text(el, str, rightX - textWidth(str, font), y, token, font)
end

function U.textCentre(el, str, cx, y, token, font)
    local c = color(token)
    el:drawTextCentre(str, cx, y, c.r, c.g, c.b, c.a, font or UIFont.Small)
end

-- 1px line across the text (rolled-back rows)
function U.strike(el, x, y, w, font)
    local c = color("textFaint")
    local h = font == UIFont.Medium and fontH.medium or fontH.small
    el:drawRect(x, y + math.floor(h / 2), w, 1, c.a, c.r, c.g, c.b)
end

-- Currency icon: the admin-supplied texture (ECIconCache) when one is cached, else the shipped
-- 64 px texture (EC.CURRENCIES[id].iconDefault), else a gold dot.
local coinTextures = {}
function U.drawCoin(el, id, x, y, size)
    if type(id) ~= "string" or EC.CURRENCIES[id] == nil then return end
    local cache = EC.IconCache
    local tex = cache and cache.texture(id) or nil
    if not tex then
        tex = coinTextures[id]
        if tex == nil then
            local def = EC.CURRENCIES[id]
            local ok, t = pcall(getTexture, def and def.iconDefault or "")
            tex = (ok and t) or false
            coinTextures[id] = tex
        end
    end
    if tex then
        el:drawTextureScaled(tex, x, y, size, size, 1, 1, 1, 1)
    else
        U.Skin.dot(el, x, y, size, U.color("coin"), U.color("coinRim"))
    end
end

-- ---------- time / number formatting ----------

-- Local zone offset in minutes, derived once per open from getHourMinute() (local) vs UTC ms.
function U.localOffsetMinutes()
    local ok, hm = pcall(getHourMinute)
    if not ok or type(hm) ~= "string" then return 0 end
    local h, m = string.match(hm, "^(%d+):(%d+)$")
    if not h then return 0 end
    local utcMin = math.floor((EC.now() % 86400000) / 60000)
    local diff = (tonumber(h) * 60 + tonumber(m)) - utcMin
    if diff > 840 then diff = diff - 1440 elseif diff < -720 then diff = diff + 1440 end
    return math.floor((diff + 7) / 15) * 15 -- zones are 15-minute multiples; absorbs the second drift
end

function U.pad2(n) return n < 10 and ("0" .. n) or tostring(n) end

-- Shared four-digit year padding for timestamps and calendar labels.
function U.pad4(y)
    if y >= 1000 then return tostring(y) end
    if y >= 100 then return "0" .. y end
    if y >= 10 then return "00" .. y end
    if y >= 0 then return "000" .. y end
    return tostring(y)
end
local pad4 = U.pad4

-- Fixed timestamp columns reserve room for a full four-digit year and hours/minutes.
U.STAMP_SAMPLE = "0000-00-00 00:00"

function U.clockText(ms, offsetMin)
    if type(ms) ~= "number" then return "?" end
    local minutes = math.floor((ms + (tonumber(offsetMin) or 0) * 60000) / 60000)
    minutes = minutes - math.floor(minutes / 1440) * 1440
    return pad2(math.floor(minutes / 60)) .. ":" .. pad2(minutes % 60)
end

-- "YYYY-MM-DD": the civil day that instant falls on for a clock offsetMin ahead of UTC, so a
-- row near midnight reads as the player's own day (the storage keys stay UTC, EC.dayKey).
function U.dateText(ms, offsetMin)
    if type(ms) ~= "number" then return "?" end
    local y, mo, d = EC.utcDate(ms + (tonumber(offsetMin) or 0) * 60000)
    return pad4(y) .. "-" .. pad2(mo) .. "-" .. pad2(d)
end

function U.stampText(ms, offsetMin)   -- "YYYY-MM-DD HH:MM"
    if type(ms) ~= "number" then return "?" end
    return dateText(ms, offsetMin) .. " " .. clockText(ms, offsetMin)
end

function U.durationText(ms)
    local minutes = math.max(0, math.floor(ms / 60000))
    if minutes >= 60 then
        return getText(T .. "Time_HM", tostring(math.floor(minutes / 60)), tostring(minutes % 60))
    end
    return getText(T .. "Time_Minutes", tostring(minutes))
end

function U.realDurationText(ms)
    if type(ms) ~= "number" or ms ~= ms or ms < 0 or ms == math.huge then
        return getText(T .. "Rewards_SeasonUnknown")
    end
    local minutes = math.ceil(ms / 60000)
    return getText(T .. "Season_RealDuration", tostring(math.floor(minutes / 1440)),
        tostring(math.floor(minutes / 60) % 24), tostring(minutes % 60))
end

function U.survivalText(minutes)
    if type(minutes) ~= "number" or minutes ~= minutes or minutes < 0 or minutes == math.huge then
        return getText(T .. "Season_SurvivalUnknown")
    end
    minutes = math.floor(minutes)
    return getText(T .. "Season_SurvivalTime", tostring(math.floor(minutes / 1440)),
        tostring(math.floor(minutes / 60) % 24), tostring(minutes % 60))
end

function U.amountText(n)
    n = tonumber(n) or 0
    local s = string.format("%.0f", math.abs(n))
    local rev = string.gsub(string.reverse(s), "(%d%d%d)", "%1,")
    local out = string.reverse(rev)
    if string.sub(out, 1, 1) == "," then out = string.sub(out, 2) end
    return (n < 0 and "-" or "") .. out
end

function U.signedText(n)
    n = tonumber(n) or 0
    return (n >= 0 and "+" or "-") .. amountText(math.abs(n))
end

function U.hasBit(mask, index)
    return math.floor((tonumber(mask) or 0) / (2 ^ (index - 1))) % 2 == 1
end

function U.kindText(kind)
    return getTextOrNull(T .. "Kind_" .. tostring(kind)) or getText(T .. "Kind_other")
end

-- ---------- account / reason labels ----------
--
-- The ledger's account namespace is flat and its internal accounts are raw keys (SYSTEM_MINT,
-- MOD:<modId>, EXTERNAL_DISCORD_<currency>). A player account is the username itself and is
-- never translated; everything else reads as words and the raw key never reaches the screen
-- (an integration names itself by its mod ID, which is data).
local ACCOUNT_KEY = { SYSTEM_MINT = "Account_mint", SYSTEM_BURN = "Account_burn", SYSTEM_ADJUST = "Account_adjust" }
local MOD_PREFIX_LEN = #"MOD:"
local DISCORD_PREFIX_LEN = #"EXTERNAL_DISCORD_"

function U.accountName(account)
    if type(account) ~= "string" or account == "" then return "-" end
    local cls = EC.accountClass(account)
    if cls == "player" then return account end
    local key = ACCOUNT_KEY[account]
    if key then return getText(T .. key) end
    if cls == "mod" then return getText(T .. "Account_mod", string.sub(account, MOD_PREFIX_LEN + 1)) end
    if cls == "discord" then
        return getText(T .. "Account_discord", C.currencyName(string.sub(account, DISCORD_PREFIX_LEN + 1)))
    end
    -- an unmapped SYSTEM_/EXTERNAL_ account
    logUnknown("account", account)
    return getText(T .. "Account_system")
end

-- One short word per account class (EC.ACCOUNT_CLASSES); nil / "all" is the "every account"
-- option of a filter row.
function U.accountClassName(cls)
    if type(cls) ~= "string" or cls == "" or cls == "all" then
        return getText(T .. "Admin_Tx_Class_all")
    end
    return getTextOrNull(T .. "Admin_Tx_Class_" .. cls) or U.unknownText("account class", cls)
end

-- Reason of a transaction. Free text the caller wrote (an admin's adjustment reason, a mod's own
-- wording) is shown exactly as written; one of this mod's own codes reads as words. Any other code
-- is one an integration registered (ECIntegration registerSource): another mod's identifier, not
-- text this mod can translate, so it is shown inside a translated frame (and logged once).
-- nil when neither is supplied.
local REASON_KEY = { daily_checkin = "Kind_checkin", survival_milestone = "Kind_milestone",
    player_transfer = "Kind_transfer" }

function U.reasonText(code, written)
    if type(written) == "string" and written ~= "" then return written end
    if type(code) ~= "string" or code == "" then return nil end
    local name = getTextOrNull(T .. (REASON_KEY[code] or ("Kind_" .. code))) or getTextOrNull(T .. "Reason_" .. code)
    if name then return name end
    logUnknown("reason", code)
    return getText(T .. "Reason_custom", code)
end

-- The kinds whose SYSTEM_BURN posting is a charge on one party, and the word for it: a transfer's
-- sender pays a fee, a sale's seller a tax. Labels the statement's fee line and the admin record.
U.FEE_KEY = { transfer = "Wallet_Col_Fee", market_buy = "Wallet_Tax", auction_sale = "Wallet_Tax" }

color, fill, border, text, textWidth, fitText, textRight, textCentre, strike, drawCoin, clockText, dateText, stampText, durationText, amountText, signedText, hasBit, kindText, pad2 = U.color, U.fill, U.border, U.text, U.textWidth, U.fitText, U.textRight, U.textCentre, U.strike, U.drawCoin, U.clockText, U.dateText, U.stampText, U.durationText, U.amountText, U.signedText, U.hasBit, U.kindText, U.pad2

-- ---------- skinned button (chip / primary) ----------

local Button = ISButton:derive("MinidoracatEconomyButton")
U.Button = Button

function Button.create(x, y, w, h, title, target, onClick, style)
    local o = ISButton:new(x, y, w, h, title, target, onClick)
    setmetatable(o, Button)
    o.style = style or "chip"
    o.active = false
    o.fullTitle = title  -- untruncated label; consumers fit `title` to the budgeted width
    o:initialise()
    return o
end

-- Vanilla runs the tooltip pass from ISButton:prerender (:176); this class replaced that pass, so
-- it is re-run here for the two cases a label alone cannot answer:
--   * a manual tooltip (the calendar glyph, an icon chip) — shown exactly as the owner set it
--   * a title the owner fitted to its column (`title ~= fullTitle`) — the full label is offered
--     instead of being lost with the cut characters. `autoTooltip` marks ours, so a manual one is
--     never overwritten and the auto one is dropped again once the button gets its full width.
-- ISButton:updateTooltip (ISButton.lua:316-346) only builds the ISToolTip while the mouse (or a
-- joypad focus) is over the button, so an unhovered button costs one comparison per frame.
function Button:prerender()
    local full = self.fullTitle
    if full ~= nil and full ~= "" and self.title ~= full then
        if self.tooltip == nil or self.autoTooltip then
            self.tooltip = full
            self.autoTooltip = true
        end
    elseif self.autoTooltip then
        self.tooltip = nil
        self.autoTooltip = nil
    end
    if self.tooltip or self.tooltipUI then self:updateTooltip() end
end

function Button:render()
    local w, h = self.width, self.height
    local hovered = self.enable and self.mouseOver and self:isMouseOver()
    local font = self.font
    local textToken
    if self.style == "primary" then
        if self.enable then
            local pressed = self.pressed and hovered
            fill(self, 0, 0, w, h, pressed and "goldPressed" or (hovered and "goldHover" or "gold"))
            if not pressed then
                fill(self, 1, 1, w - 2, math.floor(h / 2), "goldLight", "roundTop") -- bevel highlight
                local c = color("goldDark")
                self:drawRect(3, h - 3, w - 6, 1, 0.5, c.r, c.g, c.b)                -- bottom shade
            end
            border(self, 0, 0, w, h, "goldDark")
            textToken = "goldText"
        else
            fill(self, 0, 0, w, h, "well")
            border(self, 0, 0, w, h, "border")
            textToken = "textFaint"
        end
    elseif self.style == "danger" then
        -- an action that cannot be undone (delist, cancel an auction, start the next season): its
        -- own red surface, so it never reads like the routine chip or the gold primary beside it
        if self.enable then
            fill(self, 0, 0, w, h, hovered and "errorSurface" or "well", "pill")
            border(self, 0, 0, w, h, "errorText", "pill")
            textToken = "errorText"
        else
            U.theme:border(self, 0, 0, w, h, "border", "pill", U.alpha * 0.45)
        end
    else -- chip
        local stateToken = self.enable and self.stateToken or nil
        if self.active then
            fill(self, 0, 0, w, h, "selected", "pill")
            border(self, 0, 0, w, h, stateToken or "accent", "pill")
            textToken = stateToken or "accent"
        elseif not self.enable then
            -- a disabled chip fades its outline as well as its label: the label colour alone
            -- (textFaint against the idle textMuted) is too close to tell the two apart
            U.theme:border(self, 0, 0, w, h, "border", "pill", U.alpha * 0.45)
        else
            if hovered then fill(self, 0, 0, w, h, "hover", "pill") end
            border(self, 0, 0, w, h, stateToken or "border", "pill")
            textToken = stateToken or (hovered and "text" or "textMuted")
        end
    end
    if not self.enable then textToken = "textDisabled" end
    if self.joypadFocused then border(self, 1, 1, w - 2, h - 2, "accent") end
    local fh = font == UIFont.Medium and fontH.medium or fontH.small
    local ty = math.floor((h - fh) / 2)
    if self.style == "primary" and self.enable then
        -- label + coin icon centred as one group; emboss = light copy 1px below
        local tw = textWidth(self.title, font)
        local coinW = self.coinId and (COIN_SMALL + 6) or 0
        local x = math.floor((w - tw - coinW) / 2)
        local c = color("goldEmboss")
        self:drawText(self.title, x, ty + 1, c.r, c.g, c.b, c.a, font)
        text(self, self.title, x, ty, textToken, font)
        if self.coinId then
            drawCoin(self, self.coinId, x + tw + 6, math.floor((h - COIN_SMALL) / 2), COIN_SMALL)
        end
    else
        textCentre(self, self.title, w / 2, ty, textToken, font)
    end
end

-- The base cell owns the background; derived rows add their explicit action buttons afterwards.
local AdminHistoryCell = ISPanel:derive("MinidoracatEconomyAdminHistoryCell")
U.AdminHistoryCell = AdminHistoryCell

function AdminHistoryCell:render()
    local e = self.entry
    if not e then return end
    local lit = U.framework.Table.rowBackground(self)
    local secondary = lit and "text" or "textMuted"
    text(self, e.headText, PAD, e.line1Y, e.rolled and secondary or "text")
    textRight(self, e.amountLabel, e.amountRight, e.line1Y, e.rolled and secondary or (e.amountToken or "accent"))
    text(self, e.metaText, PAD, e.line2Y, secondary)
    if e.rolled then
        U.strike(self, PAD, e.line1Y, e.headW)
        textRight(self, e.rolledLabel, e.amountRight, e.line2Y, secondary)
    end
end

-- Every modal this window puts over itself (the buy / sell dialog, the one trade dialog the
-- market and auction pages share with its backpack picker, the preference popover) is a small
-- panel in the middle of a page that stays fully painted underneath. Without a backdrop the
-- page's own chips and tables keep taking every click that lands beside the dialog: a claim, a
-- listing or a page switch fired while a purchase is still waiting for its confirm. This guard
-- is one child that covers the workspace, dims what it covers so the dialog reads against it,
-- and swallows every mouse event. The title row is left out on purpose — the window can still
-- be moved, collapsed and closed. It is raised under whichever modal is up
-- (Panel:updateModalGuard), never over it, and it is no alwaysOnTop root: it lives inside this
-- window and covers nothing else on screen.
local ModalGuard = ISPanel:derive("MinidoracatEconomyModalGuard")

function ModalGuard:prerender()
    U.theme:fill(self, 0, 0, self.width, self.height, "surface", nil, 0.55)
end

function ModalGuard:render() end
function ModalGuard:onMouseDown() return true end
function ModalGuard:onMouseUp() return true end
function ModalGuard:onRightMouseDown() return true end
function ModalGuard:onRightMouseUp() return true end
function ModalGuard:onMouseMove() return true end
function ModalGuard:onMouseWheel() return true end

-- Child bringToTop is deferred and preserves old sibling order (UIElement.java:1663-1673).
-- The parent's BringToTop is immediate, so the backdrop cannot overtake its dialog.
function ModalGuard:raise(top)
    self.parent.javaObject:BringToTop(self.javaObject)
    self.parent.javaObject:BringToTop(top.javaObject)
end

-- One read-only, scrollable surface for player and administrative details.
function U.newReader(owner, width, height)
    local box = U.newEntry(width, height, { multiline = true, maxLines = 12 })
    box.target = owner
    local bg, fg = color("well"), color("text")
    box.backgroundColor = { r = bg.r, g = bg.g, b = bg.b, a = 1 }
    U.setEntryEditable(box, false)
    box:setSelectable(false)
    box:setTextRGBA(fg.r, fg.g, fg.b, fg.a)
    owner:addChild(box)
    box:addScrollBars()
    return box
end

function U.newModalGuard(owner)
    local guard = ISPanel.new(ModalGuard, 0, 0, 1, 1)
    guard.background = false
    guard:initialise()
    owner:addChild(guard)
    guard:setVisible(false)
    return guard
end

-- Every table: the framework's table shell (rev 11) bound to this mod's theme and its own scroll
-- track colour. Rows are plain item tables, cells bind by reference; a cell's onBind / onUnbind
-- (ECRowActions) runs on every rebind.
function U.newTable(cellClass, rowHeight)
    return U.framework.Table.new({ cell = cellClass, rowHeight = rowHeight or ROW, theme = U.theme,
        colors = { thumb = color("textFaint"), thumbHover = color("textMuted"), track = color("track") } })
end

-- Card frame with an optional title row; callers may allocate a taller heading.
U.CARD_TITLE_H = 36
function U.card(el, x, y, w, h, title, titleHeight)
    fill(el, x, y, w, h, "card")
    border(el, x, y, w, h, "border")
    if title then
        titleHeight = titleHeight or U.CARD_TITLE_H
        text(el, title, x + PAD, y + math.floor((titleHeight - fontH.medium) / 2), "text", UIFont.Medium)
        local c = color("border")
        el:drawRect(x + 1, y + titleHeight, w - 2, 1, c.a * U.alpha, c.r, c.g, c.b)
    end
end

-- ---------- stat pill / empty state (UI refresh 2026-10-05) ----------

-- A number that changes, shown as a short labelled pill instead of inside a sentence (design
-- principle "會變的數字做成膠囊"): muted label, optional coin, value. Height CHIP_H; the return
-- value is the width taken, so a caller lays a row of pills out left to right and wraps the row
-- itself when it runs out of width (a pill is never cut: the numbers are the point of it).
local PILL_PAD, PILL_GAP, PILL_COIN = 10, 6, 16
function U.pillWidth(label, value, coinId)
    local w = PILL_PAD * 2 + textWidth(value or "")
    if label ~= nil and label ~= "" then w = w + textWidth(label) + PILL_GAP end
    if coinId ~= nil then w = w + PILL_COIN + 4 end
    return w
end

function U.drawPill(el, x, y, label, value, token, coinId)
    local w = U.pillWidth(label, value, coinId)
    local h = U.CHIP_H
    fill(el, x, y, w, h, "selected", "pill")
    local ty = y + math.floor((h - fontH.small) / 2)
    local tx = x + PILL_PAD
    if label ~= nil and label ~= "" then
        text(el, label, tx, ty, "textMuted")
        tx = tx + textWidth(label) + PILL_GAP
    end
    if coinId ~= nil then
        drawCoin(el, coinId, tx, y + math.floor((h - PILL_COIN) / 2), PILL_COIN)
        tx = tx + PILL_COIN + 4
    end
    text(el, value or "", tx, ty, token or "text")
    return w
end

-- An empty list says what the place is for and what to do next (design principle "空的時候指
-- 路"). U.emptyState measures one named slot of an element (title, body wrapped to at most four
-- lines, kept per body and width so the per-frame draw allocates nothing) and returns the y where
-- the caller places its one action button, centred on the same column; U.drawEmptyState paints
-- what the last measurement of that slot holds. The button stays a real Button the caller owns,
-- so keyboard and controller reach it like any other control.
function U.emptyState(el, slot, x, y, w, h, title, body)
    local states = el.ecEmptyStates
    if states == nil then states = {}; el.ecEmptyStates = states end
    local s = states[slot]
    if s == nil then s = {}; states[slot] = s end
    local cw = math.max(60, math.min(w - PAD * 4, 520))
    if s.body ~= body or s.cw ~= cw then
        s.body, s.cw = body, cw
        s.lines = (type(body) == "string" and body ~= "") and U.wrapText(body, cw, 4) or {}
    end
    s.title = title or ""
    s.lh = fontH.small + 2
    local blockH = fontH.medium + 6 + #s.lines * s.lh + U.CHIP_H + 10
    s.top = y + math.max(PAD, math.floor((h - blockH) / 2))
    s.cx = x + math.floor(w / 2)
    return s.top + fontH.medium + 6 + #s.lines * s.lh + 10
end

function U.drawEmptyState(el, slot)
    local s = el.ecEmptyStates and el.ecEmptyStates[slot]
    if s == nil then return end
    textCentre(el, s.title, s.cx, s.top, "text", UIFont.Medium)
    local ly = s.top + fontH.medium + 6
    for i = 1, #s.lines do
        textCentre(el, s.lines[i], s.cx, ly, "textMuted")
        ly = ly + s.lh
    end
end

return U
