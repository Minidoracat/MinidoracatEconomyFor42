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
    track = { r = 1, g = 1, b = 1, a = 0.10 },
}

local color, fill, border, text, textWidth, fitText, textRight, textCentre, strike, drawCoin, clockText, stampText, durationText, amountText, signedText, hasBit, kindText, pad2

U.framework = nil   -- MinidoracatUI.v1 facade (set by U.init)
U.Skin = nil
U.theme = nil
U.fontH = { small = 0, medium = 0 }   -- filled by U.init (table identity is stable: alias freely)
local fontH = U.fontH

local function framework()
    local ui = MinidoracatUI and MinidoracatUI.v1
    if ui and ui.API_MAJOR == 1 and ui.API_REVISION >= 3 and ui.CAPABILITIES
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
            EC.log("MinidoracatUI v1 (rev>=3, virtualList) missing: Economy Center UI disabled")
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

function U.color(token) return U.theme.colors[token] end

function U.fill(el, x, y, w, h, token, shape)
    U.theme:fill(el, x, y, w, h, token, shape)
end

function U.border(el, x, y, w, h, token, shape)
    U.theme:border(el, x, y, w, h, token, shape)
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

function U.clockText(ms, offsetMin)
    local minutes = math.floor(((ms + offsetMin * 60000) % 86400000) / 60000)
    return pad2(math.floor(minutes / 60)) .. ":" .. pad2(minutes % 60)
end

function U.stampText(ms, offsetMin)   -- "MM-DD HH:MM"
    if type(ms) ~= "number" then return "?" end
    local shifted = ms + offsetMin * 60000
    local _, mo, d = EC.utcDate(shifted)
    return pad2(mo) .. "-" .. pad2(d) .. " " .. clockText(ms, offsetMin)
end

function U.durationText(ms)
    local minutes = math.max(0, math.floor(ms / 60000))
    if minutes >= 60 then
        return getText(T .. "Time_HM", tostring(math.floor(minutes / 60)), tostring(minutes % 60))
    end
    return getText(T .. "Time_Minutes", tostring(minutes))
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

color, fill, border, text, textWidth, fitText, textRight, textCentre, strike, drawCoin, clockText, stampText, durationText, amountText, signedText, hasBit, kindText, pad2 = U.color, U.fill, U.border, U.text, U.textWidth, U.fitText, U.textRight, U.textCentre, U.strike, U.drawCoin, U.clockText, U.stampText, U.durationText, U.amountText, U.signedText, U.hasBit, U.kindText, U.pad2

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

function Button:prerender() end

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
        if self.active then
            fill(self, 0, 0, w, h, "selected", "pill")
            border(self, 0, 0, w, h, "accent", "pill")
            textToken = "accent"
        else
            if hovered then fill(self, 0, 0, w, h, "hover", "pill") end
            border(self, 0, 0, w, h, "border", "pill")
            textToken = hovered and "text" or "textMuted"
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
    if self.index % 2 == 0 then fill(self, 0, 0, w, h, "card", "rect") end
    if self:isMouseOver() then fill(self, 0, 0, w, h, "hover", "rect") end
    local ty = math.floor((h - fontH.small) / 2)
    for i, str in ipairs(self.cellText) do
        local col = cols[i]
        if col then
            local token = e.muted and "textFaint" or ((e.tokens and e.tokens[i]) or "text")
            if col.right then textRight(self, str, col.x, ty, token) else text(self, str, col.x, ty, token) end
        end
    end
    if e.muted then strike(self, cols[1].x, ty, w - cols[1].x - PAD) end
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
            cell.entry = item
            cell.index = index
            cell.cellText = nil
            if cellClass == Cell then cell.descText = fitText(item.desc, l.cols.descW or 9999) end
        end,
        unbindCell = function(_, cell) cell.entry = nil end,
        colors = { thumb = color("textFaint"), thumbHover = color("textMuted"), track = color("track") },
    })
    list.cols = {}
    list:initialise()
    return list
end

-- Card frame with an optional title row (CARD_TITLE_H tall).
U.CARD_TITLE_H = 36
function U.card(el, x, y, w, h, title)
    fill(el, x, y, w, h, "card")
    border(el, x, y, w, h, "border")
    if title then
        text(el, title, x + PAD, y + math.floor((U.CARD_TITLE_H - fontH.medium) / 2), "text", UIFont.Medium)
        local c = color("border")
        el:drawRect(x + 1, y + U.CARD_TITLE_H, w - 2, 1, c.a, c.r, c.g, c.b)
    end
end

return U
