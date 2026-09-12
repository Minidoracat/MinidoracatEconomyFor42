-- MinidoracatEconomyFor42 — client UI toolkit shared by the Economy Center tabs (ECPanel,
-- ECAdminPanel): theme tokens, paint helpers over MinidoracatUIFor42 v1 (Theme/Skin), number/time
-- formatting, the skinned Button (tab / chip / primary) and the statement/table cells for VirtualList.
--
-- U.init() resolves the framework once per session (called by ECPanel before any window exists);
-- every helper reads U.theme / U.Skin / U.fontH at call time, so files may alias them at load.
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
}

local color, fill, border, text, textWidth, fitText, textRight, textCentre, strike, drawCoin, clockText, dateText, stampText, durationText, amountText, signedText, hasBit, kindText, pad2

U.framework = nil   -- MinidoracatUI.v1 facade (set by U.init)
U.Skin = nil
U.theme = nil
U.fontH = { small = 0, medium = 0 }   -- filled by U.init (table identity is stable: alias freely)
local fontH = U.fontH

local function framework()
    local ui = MinidoracatUI and MinidoracatUI.v1
    if ui and ui.API_MAJOR == 1 and ui.API_REVISION >= 6 and ui.CAPABILITIES
        and ui.CAPABILITIES.theme == true and ui.CAPABILITIES.skin == true
        and ui.CAPABILITIES.virtualList == true then
        return ui
    end
    return nil
end

-- Returns the facade or nil (logged once). Safe to call repeatedly.
function U.init()
    if U.framework then return U.framework end
    if not (MinidoracatUI and MinidoracatUI.v1) then
        pcall(require, "MinidoracatUI/V1")
    end
    if not (MinidoracatUI and MinidoracatUI.v1 and MinidoracatUI.v1.CAPABILITIES.virtualList) then
        pcall(require, "MinidoracatUI/VirtualList")
    end
    local ui = framework()
    if not ui then
        if not U.warned then
            EC.log("MinidoracatUI v1 (rev>=6, virtualList) missing: Economy Center UI disabled")
            U.warned = true
        end
        return nil
    end
    U.framework = ui
    U.Skin = ui.Skin
    U.theme = ui.Theme.create({ colors = MOD_COLORS })
    fontH.small = getTextManager():getFontHeight(UIFont.Small)
    fontH.medium = getTextManager():getFontHeight(UIFont.Medium)
    return ui
end

-- Shared by the admin controller and its transaction page.
function U.adminErrorText(code)
    local key = tostring(code == nil and "unknown" or code)
    return getTextOrNull(T .. "Admin_Error_" .. key) or getTextOrNull(T .. "Market_Error_" .. key)
        or getText(T .. "Admin_Error_generic", key)
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
    if type(getItemNameFromFullType) == "function" then
        local ok, name = pcall(getItemNameFromFullType, fullType)
        if ok and type(name) == "string" and name ~= "" then return name end
    end
    return tostring(fullType or "-")
end

-- Item icon (Item.java:1650-1652), cached per fullType for the whole session; false = asked and
-- missing. Every geometry change rebuilds every row, and ScriptManager lookups are not free.
local itemTextures = {}
function U.itemTexture(fullType)
    if type(fullType) ~= "string" then return nil end
    local cached = itemTextures[fullType]
    if cached ~= nil then return cached or nil end
    local tex = nil
    pcall(function()
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
-- and icons stay solid. Set from ECOptions (ModOptions slider) and the title-row slider.
U.alpha = 1
function U.setAlpha(v)
    v = tonumber(v) or 1
    if v < 0.2 then v = 0.2 elseif v > 1 then v = 1 end
    U.alpha = v
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
-- the unwrapped value is retained separately for copying.
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
                out[#out + 1] = string.sub(rest, 1, n)
                rest = string.sub(rest, n + 1)
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
-- never translated; everything else reads as words, with the raw key kept wherever an admin
-- reconciles against the event files (withId).
local ACCOUNT_KEY = { SYSTEM_MINT = "Account_mint", SYSTEM_BURN = "Account_burn", SYSTEM_ADJUST = "Account_adjust" }
local MOD_PREFIX_LEN = #"MOD:"
local DISCORD_PREFIX_LEN = #"EXTERNAL_DISCORD_"

function U.accountName(account, withId)
    if type(account) ~= "string" or account == "" then return "-" end
    local cls = EC.accountClass(account)
    if cls == "player" then return account end
    local name
    local key = ACCOUNT_KEY[account]
    if key then
        name = getText(T .. key)
    elseif cls == "mod" then
        name = getText(T .. "Account_mod", string.sub(account, MOD_PREFIX_LEN + 1))
    elseif cls == "discord" then
        name = getText(T .. "Account_discord", C.currencyName(string.sub(account, DISCORD_PREFIX_LEN + 1)))
    else
        -- an unmapped SYSTEM_/EXTERNAL_ account: say it is one and show which
        name = getText(T .. "Account_system", account)
    end
    if withId and not string.find(name, account, 1, true) then
        name = name .. " (" .. account .. ")"
    end
    return name
end

-- One short word per account class (EC.ACCOUNT_CLASSES); nil / "all" is the "every account"
-- option of a filter row.
function U.accountClassName(cls)
    if type(cls) ~= "string" or cls == "" or cls == "all" then
        return getText(T .. "Admin_Tx_Class_all")
    end
    return getTextOrNull(T .. "Admin_Tx_Class_" .. cls) or cls
end

-- Reason of a transaction. Free text the caller wrote (an admin's adjustment reason, a mod's own
-- wording) is shown exactly as written; a bare code we know reads as words with the code kept
-- beside it, so a search over the raw code still matches what the eye sees. Codes without a
-- known label stay unchanged, including custom integration codes. nil when neither is supplied.
local REASON_KEY = { daily_checkin = "Kind_checkin", survival_milestone = "Kind_milestone" }

function U.reasonText(code, written)
    if type(written) == "string" and written ~= "" then return written end
    if type(code) ~= "string" or code == "" then return nil end
    local name = getTextOrNull(T .. (REASON_KEY[code] or ("Kind_" .. code)))
        or getTextOrNull(T .. "Reason_" .. code)
    if not name then return code end
    return name .. " (" .. code .. ")"
end

color, fill, border, text, textWidth, fitText, textRight, textCentre, strike, drawCoin, clockText, dateText, stampText, durationText, amountText, signedText, hasBit, kindText, pad2 = U.color, U.fill, U.border, U.text, U.textWidth, U.fitText, U.textRight, U.textCentre, U.strike, U.drawCoin, U.clockText, U.dateText, U.stampText, U.durationText, U.amountText, U.signedText, U.hasBit, U.kindText, U.pad2

-- ---------- skinned button (tab / chip / primary) ----------

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
    elseif self.style == "tab" then
        if hovered then fill(self, 0, 0, w, h, "hover", "rect") end
        if self.active then
            fill(self, 0, h - 2, w, 2, "accent", "rect")
            textToken = "accent"
        else
            textToken = hovered and "text" or "textMuted"
        end
    else -- chip
        local stateToken = self.enable and self.stateToken or nil
        if self.active then
            fill(self, 0, 0, w, h, "selected", "pill")
            border(self, 0, 0, w, h, stateToken or "accent", "pill")
            textToken = stateToken or "accent"
        else
            if hovered then fill(self, 0, 0, w, h, "hover", "pill") end
            border(self, 0, 0, w, h, stateToken or "border", "pill")
            textToken = stateToken or (hovered and "text" or "textMuted")
        end
    end
    if not self.enable then textToken = "textFaint" end
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

-- ---------- keyboard focus painter ----------
-- One ring for the whole mod (ECKeyboard paints it on the window, after the children had their
-- render pass, so it is never covered by the control it marks).
--
-- The ring lives *outside* the control: FOCUS_GAP px of untouched control edge, then FOCUS_W px of
-- ring. An opaque surface halo keeps it distinct even over bright scenes with faded chrome.
-- Neither the halo nor the ring follows U.alpha.
U.FOCUS_GAP = 2
U.FOCUS_W = 2

function U.drawFocus(el, x, y, w, h, token)
    local c = color(token or "accent")
    local o = U.FOCUS_GAP + U.FOCUS_W
    local rx, ry = x - o, y - o
    local rw, rh = w + o * 2, h + o * 2
    if rw <= 0 or rh <= 0 then return end
    local bg = color("surface")
    for i = 1, U.FOCUS_W do
        el:drawRectBorder(rx - i, ry - i, rw + i * 2, rh + i * 2, 1, bg.r, bg.g, bg.b)
    end
    for i = 0, U.FOCUS_W - 1 do
        el:drawRectBorder(rx + i, ry + i, rw - i * 2, rh - i * 2, c.a, c.r, c.g, c.b)
    end
end

-- Caption under the ring: the whole label of a control whose own paint cannot carry it (an icon
-- chip, a title the owner had to cut). Placed under the ring, flipped above when the ring sits at
-- the bottom edge of `el`, and always inside el's width so it can never be clipped away.
function U.drawFocusCaption(el, x, y, w, h, caption)
    if type(caption) ~= "string" or caption == "" then return end
    local o = U.FOCUS_GAP + U.FOCUS_W
    local tw = textWidth(caption)
    local bw = tw + 10
    local bh = fontH.small + 6
    local bx = x + math.floor((w - bw) / 2)
    local by = y + h + o + 2
    if by + bh > el.height then by = y - o - 2 - bh end
    if by < 0 then by = 0 end
    if bx + bw > el.width then bx = el.width - bw end
    if bx < 0 then bx = 0 end
    local bg, bd = color("surface"), color("accent")
    el:drawRect(bx, by, bw, bh, 1, bg.r, bg.g, bg.b)
    el:drawRectBorder(bx, by, bw, bh, bd.a, bd.r, bd.g, bd.b)
    text(el, caption, bx + 5, by + 3, "text")
end

-- ---------- statement cell (VirtualList) ----------

local Cell = ISPanel:derive("MinidoracatEconomyStatementCell")
U.StatementCell = Cell

function Cell:render()
    local e = self.entry
    if not e then return end
    local cols = self.list.cols
    local w, h = self.width, self.height
    if self.index % 2 == 0 then fill(self, 0, 0, w, h, "card", "rect") end
    if self:isMouseOver() then fill(self, 0, 0, w, h, "hover", "rect") end
    local ty = math.floor((h - fontH.small) / 2)
    local muted = e.rolledBack
    local tokenText = muted and "textFaint" or "text"
    local tokenMuted = muted and "textFaint" or "textMuted"
    text(self, e.time, cols.time, ty, tokenMuted)
    text(self, e.kindText, cols.kind, ty, tokenText)
    text(self, self.descText or e.desc, cols.desc, ty, tokenMuted)
    textRight(self, e.amountText, cols.amountR, ty, muted and "textFaint" or (e.amount >= 0 and "positive" or "negative"))
    textRight(self, amountText(e.after), cols.balanceR, ty, tokenText)
    if muted then
        text(self, getText(T .. "Wallet_RolledBack"), cols.status, ty, "textFaint")
        strike(self, cols.time, ty, cols.balanceR - cols.time)
    else
        text(self, "-", cols.status, ty, "textFaint")
    end
end


-- ---------- generic table cell (admin tables) ----------
-- item = { cells = { "text", ... }, tokens = { "text"|"positive"|..., ... } (optional), muted = bool }
-- list.cols = { { x = number, right = bool }, ... } (one per cell, x relative to the cell)

local TableCell = ISPanel:derive("MinidoracatEconomyTableCell")
U.TableCell = TableCell

function TableCell:render()
    local e = self.entry
    if not e then return end
    local cols = self.list.cols
    local w, h = self.width, self.height
    if not self.cellText or self.cellCols ~= cols or self.cellWidth ~= w then
        self.cellText = {}
        for i, value in ipairs(e.cells) do
            local col = cols[i]
            self.cellText[i] = col and col.width and fitText(tostring(value), col.width) or tostring(value)
        end
        self.cellCols, self.cellWidth = cols, w
    end
    local lit = U.rowBackground(self)
    local ty = math.floor((h - fontH.small) / 2)
    for i, str in ipairs(self.cellText) do
        local col = cols[i]
        if col then
            local token = e.muted and "textFaint" or ((e.tokens and e.tokens[i]) or "text")
            if lit and (token == "textFaint" or token == "textMuted") then token = "text" end
            if col.right then textRight(self, str, col.x, ty, token) else text(self, str, col.x, ty, token) end
        end
    end
    if e.muted then strike(self, cols[1].x, ty, w - cols[1].x - PAD) end
end

-- The base cell owns the background; derived rows add their explicit action buttons afterwards.
local AdminHistoryCell = ISPanel:derive("MinidoracatEconomyAdminHistoryCell")
U.AdminHistoryCell = AdminHistoryCell

function AdminHistoryCell:render()
    local e = self.entry
    if not e then return end
    local lit = U.rowBackground(self)
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

function U.detailHeight(availableH, rowHeight, chromeH, controlsH)
    local height = math.min(fontH.small * 8 + 12,
        availableH - controlsH - chromeH - rowHeight * 3)
    if height < fontH.small * 6 + 12 then return 0, true end
    return height, false
end

function U.rowBackground(cell)
    if cell.index and cell.index % 2 == 0 then
        fill(cell, 0, 0, cell.width, cell.height, "card", "rect")
    end
    local lit = cell.list and cell.list:isSelected(cell.index) or false
    if lit then fill(cell, 0, 0, cell.width, cell.height, "selected", "rect") end
    if cell:isMouseOver() then
        fill(cell, 0, 0, cell.width, cell.height, "hover", "rect")
        lit = true
    end
    return lit
end

-- VirtualList factory shared by every table: rows are plain item tables, cells bind by reference.
function U.newTable(cellClass, rowHeight)
    local list = U.framework.VirtualList.new({
        x = 0, y = 0, width = 100, height = 100, rowHeight = rowHeight or ROW, padding = 0,
        createCell = function(l)
            local cell = ISPanel.new(cellClass, 0, 0, 0, 0)
            cell.background = false -- ISPanel:prerender would paint a 0.5 alpha black box + border
            cell.list = l
            return cell
        end,
        bindCell = function(l, cell, item, index)
            if cell.ecResetActions then cell:ecResetActions() end
            cell.entry = item
            cell.index = index
            cell.cellText = nil
            if cellClass == Cell then cell.descText = fitText(item.desc, l.cols.descW or 9999) end
        end,
        unbindCell = function(_, cell)
            if cell.ecResetActions then cell:ecResetActions() end
            cell.entry = nil
        end,
        colors = { thumb = color("textFaint"), thumbHover = color("textMuted"), track = color("track") },
    })
    list.cols = {}
    list:initialise()
    return list
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

return U
