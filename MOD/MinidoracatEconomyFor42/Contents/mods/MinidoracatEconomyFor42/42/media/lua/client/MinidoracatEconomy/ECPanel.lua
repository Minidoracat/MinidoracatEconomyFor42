-- MinidoracatEconomyFor42 — Economy Center window (client). Stage B6: Wallet + Rewards tabs.
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

if not MinidoracatEconomy or not MinidoracatEconomy.Client then
    require "MinidoracatEconomy/ECClient"
end
local EC = MinidoracatEconomy
local C = EC.Client

local P = {}
C.Panel = P

local LAYOUT_NAME = "MinidoracatEconomyPanel"
local WIDTH, HEIGHT = 980, 600
local MIN_WIDTH, MIN_HEIGHT = 900, 480
local PAD = 8
local ROW = 22
local STATUS_H = 20
local STRIP_H = 44
local TAB_H = 30
local TAB_W = 130
local CHIP_H = 22
local CARD_TITLE_H = 32
local LEFT_W = 260
local COIN = 22
local COIN_SMALL = 18
local T = "IGUI_MinidoracatEconomy_"

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

local UI = nil      -- MinidoracatUI.v1 facade (resolved in P.instance)
local Skin = nil
local theme = nil
local fontH = nil   -- { small, medium }

local function framework()
    local ui = MinidoracatUI and MinidoracatUI.v1
    if ui and ui.API_MAJOR == 1 and ui.API_REVISION >= 3 and ui.CAPABILITIES
        and ui.CAPABILITIES.theme == true and ui.CAPABILITIES.skin == true
        and ui.CAPABILITIES.virtualList == true then
        return ui
    end
    return nil
end

local function color(token) return theme.colors[token] end

local function fill(el, x, y, w, h, token, shape)
    theme:fill(el, x, y, w, h, token, shape)
end

local function border(el, x, y, w, h, token, shape)
    theme:border(el, x, y, w, h, token, shape)
end

local function text(el, str, x, y, token, font)
    local c = color(token)
    el:drawText(str, x, y, c.r, c.g, c.b, c.a, font or UIFont.Small)
end

local function textWidth(str, font)
    return getTextManager():MeasureStringX(font or UIFont.Small, str)
end

-- Truncate to maxW with an ASCII ellipsis (bind-time only, never per frame). Kahlua strings are
-- UTF-16 code units, so string.sub is safe for BMP text (player names are BMP in practice).
local function fitText(str, maxW, font)
    if textWidth(str, font) <= maxW then return str end
    local n = string.len(str)
    while n > 0 do
        n = n - 1
        local cut = string.sub(str, 1, n) .. "..."
        if textWidth(cut, font) <= maxW then return cut end
    end
    return ""
end

local function textRight(el, str, rightX, y, token, font)
    text(el, str, rightX - textWidth(str, font), y, token, font)
end

local function textCentre(el, str, cx, y, token, font)
    local c = color(token)
    el:drawTextCentre(str, cx, y, c.r, c.g, c.b, c.a, font or UIFont.Small)
end

-- 1px line across the text (rolled-back rows)
local function strike(el, x, y, w, font)
    local c = color("textFaint")
    local h = font == UIFont.Medium and fontH.medium or fontH.small
    el:drawRect(x, y + math.floor(h / 2), w, 1, c.a, c.r, c.g, c.b)
end

-- Currency icon: stage B8 ships the textures (EC.CURRENCIES[id].iconDefault); until then (or when
-- the texture is missing) a gold dot stands in.
local coinTextures = {}
local function drawCoin(el, id, x, y, size)
    local tex = coinTextures[id]
    if tex == nil then
        local def = EC.CURRENCIES[id]
        local ok, t = pcall(getTexture, def and def.iconDefault or "")
        tex = (ok and t) or false
        coinTextures[id] = tex
    end
    if tex then
        el:drawTextureScaled(tex, x, y, size, size, 1, 1, 1, 1)
    else
        Skin.dot(el, x, y, size, color("coin"), color("coinRim"))
    end
end

-- ---------- time / number formatting ----------

-- Local zone offset in minutes, derived once per open from getHourMinute() (local) vs UTC ms.
local function localOffsetMinutes()
    local ok, hm = pcall(getHourMinute)
    if not ok or type(hm) ~= "string" then return 0 end
    local h, m = string.match(hm, "^(%d+):(%d+)$")
    if not h then return 0 end
    local utcMin = math.floor((EC.now() % 86400000) / 60000)
    local diff = (tonumber(h) * 60 + tonumber(m)) - utcMin
    if diff > 840 then diff = diff - 1440 elseif diff < -720 then diff = diff + 1440 end
    return math.floor((diff + 7) / 15) * 15 -- zones are 15-minute multiples; absorbs the second drift
end

local function pad2(n) return n < 10 and ("0" .. n) or tostring(n) end

local function clockText(ms, offsetMin)
    local minutes = math.floor(((ms + offsetMin * 60000) % 86400000) / 60000)
    return pad2(math.floor(minutes / 60)) .. ":" .. pad2(minutes % 60)
end

local function stampText(ms, offsetMin)   -- "MM-DD HH:MM"
    if type(ms) ~= "number" then return "?" end
    local shifted = ms + offsetMin * 60000
    local _, mo, d = EC.utcDate(shifted)
    return pad2(mo) .. "-" .. pad2(d) .. " " .. clockText(ms, offsetMin)
end

local function durationText(ms)
    local minutes = math.max(0, math.floor(ms / 60000))
    if minutes >= 60 then
        return getText(T .. "Time_HM", tostring(math.floor(minutes / 60)), tostring(minutes % 60))
    end
    return getText(T .. "Time_Minutes", tostring(minutes))
end

local function amountText(n)
    n = tonumber(n) or 0
    local s = string.format("%.0f", math.abs(n))
    local rev = string.gsub(string.reverse(s), "(%d%d%d)", "%1,")
    local out = string.reverse(rev)
    if string.sub(out, 1, 1) == "," then out = string.sub(out, 2) end
    return (n < 0 and "-" or "") .. out
end

local function signedText(n)
    n = tonumber(n) or 0
    return (n >= 0 and "+" or "-") .. amountText(math.abs(n))
end

local function hasBit(mask, index)
    return math.floor((tonumber(mask) or 0) / (2 ^ (index - 1))) % 2 == 1
end

local function kindText(kind)
    return getTextOrNull(T .. "Kind_" .. tostring(kind)) or getText(T .. "Kind_other")
end

-- ---------- skinned button (tab / chip / primary) ----------

local Button = ISButton:derive("MinidoracatEconomyButton")

function Button.create(x, y, w, h, title, target, onClick, style)
    local o = ISButton:new(x, y, w, h, title, target, onClick)
    setmetatable(o, Button)
    o.style = style or "chip"
    o.active = false
    o.displayBackground = false
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

-- ---------- window ----------

local Panel = ISCollapsableWindow:derive("MinidoracatEconomyPanel")

-- Taller than vanilla (max(16, small font + 1)) so the Medium title fits; the vanilla
-- close/pin/collapse buttons and the drag region size themselves from this value.
function Panel:titleBarHeight()
    return 28
end

function Panel:createChildren()
    ISCollapsableWindow.createChildren(self)
    self.tabButtons = {}
    for _, tab in ipairs({ "Wallet", "Rewards" }) do
        local b = Button.create(0, 0, TAB_W, TAB_H, getText(T .. "Tab_" .. tab), self, Panel.onTab, "tab")
        b.internal = tab
        self:addChild(b)
        self.tabButtons[#self.tabButtons + 1] = b
    end

    self.periodButtons = {}
    for _, f in ipairs({ "Recent", "ThisMonth", "LastMonth" }) do
        local title = getText(T .. "Wallet_" .. f)
        local b = Button.create(0, 0, textWidth(title) + 22, CHIP_H, title, self, Panel.onPeriod, "chip")
        b.internal = f
        self:addChild(b)
        self.periodButtons[#self.periodButtons + 1] = b
    end

    self.list = UI.VirtualList.new({
        x = 0, y = 0, width = 100, height = 100, rowHeight = ROW, padding = 0,
        createCell = function(list)
            local cell = ISPanel.new(Cell, 0, 0, 0, 0)
            cell.background = false -- ISPanel:prerender would paint a 0.5 alpha black box + border
            cell.list = list
            return cell
        end,
        bindCell = function(list, cell, item, index)
            cell.entry = item
            cell.index = index
            cell.descText = fitText(item.desc, list.cols.descW)
        end,
        unbindCell = function(_, cell) cell.entry = nil end,
        colors = { thumb = color("textFaint"), thumbHover = color("textMuted"), track = color("track") },
    })
    self.list.cols = {}
    self.list:initialise()
    self:addChild(self.list)

    self.claimButton = Button.create(0, 0, 200, 40, "", self, Panel.onClaim, "primary")
    self.claimButton.font = UIFont.Medium
    self:addChild(self.claimButton)

    local more = getText(T .. "Wallet_MoreHistory")
    self.moreButton = Button.create(0, 0, textWidth(more) + 24, CHIP_H, more, self, Panel.onMore, "chip")
    self:addChild(self.moreButton)

    self:setTab("Wallet")
end

-- ----- actions -----

function Panel:onTab(button) self:setTab(button.internal) end

function Panel:setTab(tab)
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
        if not self.history and self.period ~= "Recent" then self:loadHistory() end
    else
        C.requestRewards()
        if not C.wallet then C.requestWallet() end
    end
end

function Panel:onPeriod(button)
    self.period = button.internal
    for _, b in ipairs(self.periodButtons) do b.active = b.internal == self.period end
    self.history = nil
    self.historyError = nil
    if self.period ~= "Recent" then self:loadHistory() end
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
        desc = tostring(e.sourceMod)
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
function Panel:rebuildList()
    self.recentRows = newestFirst(C.wallet and C.wallet.receipts or {}, self.offsetMin)
    if self.period == "Recent" then
        self.rows = self.recentRows
    else
        self.rows = newestFirst(self.history and self.history.entries or {}, self.offsetMin)
    end
    self.list:setItems(self.rows)
end

-- Month in/out per currency from this month's receipt file (design: balance card "this month").
function Panel:updateMonthTotals(history)
    if history.month ~= EC.monthKey(EC.now()) then return end
    local totals = {}
    for _, e in ipairs(history.entries or {}) do
        if e.rolledBack ~= true then
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
        if self.period ~= "Recent" then self:loadHistory() end
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
    g.footerH = (st and (tonumber(st.serverCap) or 0) > 0) and ROW or 0
    g.contentH = h - g.contentY - rh - PAD - g.footerH
    g.leftX, g.leftW = PAD, LEFT_W
    g.rightX = PAD + LEFT_W + PAD
    g.rightW = w - g.rightX - PAD
    self.g = g

    local isWallet = self.tab == "Wallet"
    local x = PAD
    for _, b in ipairs(self.tabButtons) do
        b:setX(x); b:setY(g.tabsY); x = x + TAB_W
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
    if self.list.width ~= listW or self.list.height ~= listH then
        self.list:resize(listW, listH)
    end
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
    g.listBottom = listY + listH

    -- rewards: claim button inside the daily card, "more history" under the recent ledger
    g.dailyH = CARD_TITLE_H + ROW * 2 + 40 + ROW + PAD * 3
    self.claimButton:setVisible(not isWallet)
    self.claimButton:setX(g.rightX + PAD)
    self.claimButton:setY(g.contentY + CARD_TITLE_H + ROW * 2 + PAD)
    self.claimButton:setWidth(g.rightW - PAD * 2)
    self.moreButton:setVisible(not isWallet)
    self.moreButton:setX(g.leftX + PAD)
    self.moreButton:setY(g.contentY + g.contentH - CHIP_H - PAD)
    self.moreButton:setWidth(g.leftW - PAD * 2)
    self.layoutW, self.layoutH = w, h
end

-- ----- drawing -----

local function card(el, x, y, w, h, title)
    fill(el, x, y, w, h, "card")
    border(el, x, y, w, h, "border")
    if title then
        text(el, title, x + PAD, y + math.floor((CARD_TITLE_H - fontH.medium) / 2), "text", UIFont.Medium)
        local c = color("border")
        el:drawRect(x + 1, y + CARD_TITLE_H, w - 2, 1, c.a, c.r, c.g, c.b)
    end
end

function Panel:drawStrip()
    local g = self.g
    local w = self.width
    fill(self, PAD, g.stripY, w - PAD * 2, STRIP_H, "well")
    local x = PAD * 2
    local cy = g.stripY + math.floor((STRIP_H - COIN) / 2)
    local ty = g.stripY + math.floor((STRIP_H - fontH.medium) / 2)
    local sep = color("border")
    for i, id in ipairs(self:currencies()) do
        local bal = C.wallet and C.wallet.balances and C.wallet.balances[id]
        if i > 1 then
            self:drawRect(x, g.stripY + 8, 1, STRIP_H - 16, sep.a, sep.r, sep.g, sep.b)
            x = x + PAD * 2
        end
        drawCoin(self, id, x, cy, COIN)
        x = x + COIN + PAD
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
        drawCoin(self, id, x + PAD * 2, cy + 4, COIN)
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
    local canClaim = not st.claimed and played >= need and not self.claimPending
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
    if self.width ~= self.layoutW or self.height ~= self.layoutH
        or (C.rewards ~= nil) ~= self.hadRewards then
        self.hadRewards = C.rewards ~= nil
        self:layout()
    end
    -- Rewards state is a snapshot (playtime accrues server-side every 60 s, sandbox thresholds can
    -- change live): re-request while the tab is open instead of asking the player to reopen.
    if self.tab == "Rewards" then
        local now = EC.now()
        if not self.rewardsPolledMs or now - self.rewardsPolledMs > 30000 then
            self.rewardsPolledMs = now
            C.requestRewards()
        end
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

    -- status line
    local g = self.g
    if self:remoteReadOnly() then
        Skin.dot(self, PAD * 2, g.statusY + math.floor((STATUS_H - 8) / 2), 8, color("warn"))
        text(self, getText(T .. "Band_RemoteReadOnly"), PAD * 2 + 14, g.statusY + math.floor((STATUS_H - fontH.small) / 2), "warn")
    end
    self:drawStrip()
    fill(self, PAD, g.tabsY, w - PAD * 2, TAB_H, "well", "rect")
    if self.tab == "Wallet" then
        self:drawWallet()
    else
        self:drawRewards()
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
    Skin.border(self, 0, 0, w, h, color("border"))
end

function Panel:close()
    self:setVisible(false)
end

function Panel:setVisible(visible)
    ISCollapsableWindow.setVisible(self, visible)
    self.shown = visible == true
    if visible then
        self.offsetMin = localOffsetMinutes()
        self:bringToTop()
        self:refresh()
    end
end

-- ISLayoutManager: keep position/size, never auto-show on login
function Panel:RestoreLayout(name, layout)
    local visible = layout.visible
    layout.visible = nil
    ISCollapsableWindow.RestoreLayout(self, name, layout)
    layout.visible = visible
    self:setVisible(false)
end

function Panel.create()
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    local o = ISCollapsableWindow:new(math.floor((sw - WIDTH) / 2), math.floor((sh - HEIGHT) / 2), WIDTH, HEIGHT)
    setmetatable(o, Panel)
    o.title = getText(T .. "Toast_Title")
    o.resizable = true
    o.minimumWidth = MIN_WIDTH
    o.minimumHeight = MIN_HEIGHT
    o.period = "ThisMonth"
    o.offsetMin = localOffsetMinutes()
    o.monthTotals = nil
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
    UI = framework()
    if not UI then
        EC.log("MinidoracatUI v1 (rev>=3, virtualList) missing: Economy Center window disabled")
        return nil
    end
    Skin = UI.Skin
    theme = UI.Theme.create({ colors = MOD_COLORS })
    fontH = { small = getTextManager():getFontHeight(UIFont.Small), medium = getTextManager():getFontHeight(UIFont.Medium) }
    P.window = Panel.create()
    if not P.listening then
        P.listening = true
        C.onWallet(function(kind, args) if P.window then P.window:onWallet(kind, args) end end)
        C.onRewards(function(kind, args) if P.window then P.window:onRewards(kind, args) end end)
    end
    return P.window
end

function P.toggle()
    if not getPlayer() then return end
    local win = P.instance()
    if not win then return end
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
        P.window:removeFromUIManager()
        P.window = nil
    end
end
Events.OnGameStart.Add(onGameStart)

return P
