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
local WIDTH, HEIGHT = 1120, 700
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
    for _, tab in ipairs({ "Wallet", "Rewards", "Admin" }) do
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

    self.list = U.newTable(Cell, ROW)
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
    if tab == "Admin" and not C.AdminPanel.canRead() then tab = "Wallet" end
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
    elseif self.tab == "Admin" then
        if self.adminPanel and C.AdminPanel.canRead() then self.adminPanel:refresh() end
    else
        self.rewardsPolledMs = EC.now()
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
        -- integration postings (spec 21.3): the mod id plus its own wording when it gave one
        desc = tostring(e.sourceMod)
        if type(e.reasonText) == "string" and e.reasonText ~= "" then desc = desc .. " - " .. e.reasonText end
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
    g.footerH = (self.tab == "Rewards" and st and (tonumber(st.serverCap) or 0) > 0) and ROW or 0
    g.contentH = h - g.contentY - rh - PAD - g.footerH
    g.leftX, g.leftW = PAD, LEFT_W
    g.rightX = PAD + LEFT_W + PAD
    g.rightW = w - g.rightX - PAD
    self.g = g

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
        U.Skin.dot(self, PAD * 2, g.statusY + math.floor((STATUS_H - 8) / 2), 8, color("warn"))
        text(self, getText(T .. "Band_RemoteReadOnly"), PAD * 2 + 14, g.statusY + math.floor((STATUS_H - fontH.small) / 2), "warn")
    end
    self:drawStrip()
    fill(self, PAD, g.tabsY, w - PAD * 2, TAB_H, "well", "rect")
    if self.tab == "Wallet" then
        self:drawWallet()
    elseif self.tab == "Rewards" then
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
    U.Skin.border(self, 0, 0, w, h, color("border"))
end

function Panel:close()
    self:setVisible(false)
end

function Panel:setVisible(visible)
    ISCollapsableWindow.setVisible(self, visible)
    self.shown = visible == true
    if self.adminPanel and not visible then self.adminPanel:setVisible(false) end
    if visible then
        self.offsetMin = localOffsetMinutes()
        self:bringToTop()
        self:layout()
        self:refresh()
    end
end

-- ISLayoutManager: keep position/size, never auto-show on login
function Panel:RestoreLayout(name, layout)
    local visible = layout.visible
    layout.visible = nil
    ISCollapsableWindow.RestoreLayout(self, name, layout)
    self:setWidth(math.min(getCore():getScreenWidth(), math.max(MIN_WIDTH, self.width)))
    self:setHeight(math.min(getCore():getScreenHeight(), math.max(MIN_HEIGHT, self.height)))
    self:setX(math.max(0, math.min(self.x, getCore():getScreenWidth() - self.width)))
    self:setY(math.max(0, math.min(self.y, getCore():getScreenHeight() - self.height)))
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
    if not U.init() then return nil end
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
        if P.window.adminPanel then P.window.adminPanel:dispose() end
        P.window:removeFromUIManager()
        P.window = nil
    end
end
Events.OnGameStart.Add(onGameStart)

return P
