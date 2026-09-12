-- MinidoracatEconomyFor42 - the public leaderboard page of the Economy Center (client).
--
-- One page of its own, with its own controls, geometry and paint, so the window class does not
-- grow another dozen upvalues for it (ECPanel is already at the debug compiler's ceiling). The
-- window owns the instance (Panel.leaderboard), adds its controls as its own children and calls
-- into the five entry points below; nothing here reaches back for C.Panel.
--
-- The page reads one command and one command only: the public leaderboard
-- (C.requestLeaderboard / C.onLeaderboard). It never touches an administrative snapshot, and it
-- shows exactly what the server was willing to make public:
--
--   * amounts of other accounts only while the server says showAmounts; otherwise every foreign
--     amount is a dash. A hidden amount is never painted as 0 - a zero is a fact, and this is
--     the absence of one.
--   * the player's own line is always spelled out (rank and figure), because the server sends
--     their own figure whatever the public setting is. An account that is not on the board says
--     so instead of being given rank 0.
--   * one board at a time: one currency for the wealth board, one season for the survival board.
--     A rank across two currencies is not a rank, and neither is one across two seasons.
--
-- Two kinds share this one page, because they are the same board with another column: the
-- wealth board of a currency (live, paged by the server) and the longest single life recorded
-- in one season. The selectors follow the kind - a wealth board has no season and a survival
-- board has no currency - and the server is the only source of the seasons on offer.

require "ISUI/ISPanel"

if not MinidoracatEconomy or not MinidoracatEconomy.Client or not MinidoracatEconomy.Client.UI then
    require "MinidoracatEconomy/ECWidgets"
end
require "MinidoracatEconomy/ECPanelWidgets"
require "MinidoracatEconomy/ECDetailWindow"

local EC = MinidoracatEconomy
local C = EC.Client
local U = C.UI
local W = C.PanelWidgets

local LB = {}
C.Leaderboard = LB

local PAD, ROW, CHIP_H, COIN_SMALL, T = U.PAD, U.ROW, U.CHIP_H, U.COIN_SMALL, U.T
local CARD_TITLE_H = U.CARD_TITLE_H
local fontH = U.fontH
local fill, text, textWidth, fitText, textRight = U.fill, U.text, U.textWidth, U.fitText, U.textRight
local amountText, card, drawCoin = U.amountText, U.card, U.drawCoin
local rowBackground = U.rowBackground
local Button = U.Button
local newCombo, comboFill, comboSelect, comboWidth = W.newCombo, W.comboFill, W.comboSelect, W.comboWidth
local currencyIds, currencyLabel, defaultCurrency = W.currencyIds, W.currencyLabel, W.defaultCurrency
local placeRow = W.placeRow
local survivalText = U.survivalText

-- The two boards this page can read. The key is what the server is asked for, so a kind the
-- server does not know can never be selected here.
local KINDS = { "wealth", "survival" }
local SEASON_CURRENT = "current"

local function kindLabel(kind)
    return getText(T .. (kind == "survival" and "Leaderboard_Survival" or "Leaderboard_Wealth"))
end

-- The label of one season option: the season's own number, or "the season being played" for the
-- entry that follows the rotation. The dates are not in the label - they belong in the note
-- band, where a long date at a large font cannot squeeze the selectors off the toolbar.
local function seasonLabel(meta)
    local number = meta and tonumber(meta.number)
    if number == nil then return getText(T .. "Season_Current") end
    return getText(T .. "Season_Number", tostring(number))
end

-- The widest survival time a column has to hold: 999 days, 23 hours, 59 minutes.
local SURVIVAL_SAMPLE = 999 * 1440 + 23 * 60 + 59

-- The server pages the board itself (20 per page); this side never re-sorts and never re-pages.
local Page = {}
Page.__index = Page

-- One line: the rank, the account, and the amount when there is one to show.
local Cell = ISPanel:derive("MinidoracatEconomyLeaderCell")

function Cell:render()
    local e = self.entry
    if not e then return end
    local cols = self.list.cols
    local h = self.height
    rowBackground(self)
    local ty = math.floor((h - fontH.small) / 2)
    local token = e.mine and "accent" or "text"
    textRight(self, e.rankText, cols.rankR, ty, token)
    text(self, fitText(e.name, cols.nameW), cols.name, ty, token)
    -- a known amount gets its coin; a withheld one is a dash and nothing else, and a survival
    -- time is a duration of its own with no currency behind it
    if e.amount ~= nil then
        local coinX = cols.amountR - textWidth(e.valueText) - COIN_SMALL - 4
        if coinX > cols.name + cols.nameW then
            drawCoin(self, e.currency, coinX, math.floor((h - COIN_SMALL) / 2), COIN_SMALL)
        end
        textRight(self, e.valueText, cols.amountR, ty, token)
    else
        textRight(self, e.valueText, cols.amountR, ty, e.valueToken or token)
    end
end

-- ---------- construction ----------

function LB.create(panel)
    local page = setmetatable({ panel = panel, page = 1, kind = "wealth", season = SEASON_CURRENT,
        currency = defaultCurrency(), seasonState = C.seasonState }, Page)
    page.kindCombo = newCombo(panel, 120, function(_, combo) page:onKind(combo) end)
    comboFill(page.kindCombo, KINDS, kindLabel, page.kind)
    page.curCombo = newCombo(panel, 140, function(_, combo) page:onCurrency(combo) end)
    page:fillCurrencies()
    page.seasonCombo = newCombo(panel, 140, function(_, combo) page:onSeason(combo) end)
    page:fillSeasons()
    page.combos = { page.kindCombo, page.curCombo, page.seasonCombo }
    page.list = U.newTable(Cell, math.max(ROW, fontH.small + 10))
    panel:addChild(page.list)
    for _, spec in ipairs({ { "refresh", "Market_Refresh", Page.onRefresh },
        { "self", "Leaderboard_Self", Page.onSelf },
        { "info", "Detail_Title", Page.onInfo },
        { "prev", "Market_Prev", Page.onPage }, { "next", "Market_Next", Page.onPage } }) do
        local title = getText(T .. spec[2])
        local b = Button.create(0, 0, textWidth(title) + 22, CHIP_H, title, page, spec[3], "chip")
        panel:addChild(b)
        page[spec[1] .. "Button"] = b
    end
    page.prevButton.internal = -1
    page.nextButton.internal = 1
    page.rows = {}
    return page
end

-- The box offers the registered currencies and nothing else: "all" is not a rank.
function Page:fillCurrencies()
    local ids = currencyIds()
    -- the set and the names: a currency renamed at runtime must not leave an old label behind.
    -- Called when the page opens (and on a config push), never per frame.
    local parts = {}
    for i, id in ipairs(ids) do parts[i] = id .. "=" .. currencyLabel(id) end
    local sig = table.concat(parts, ",")
    if sig == self.curSig then return end
    self.curSig = sig
    local known = false
    for _, id in ipairs(ids) do
        if id == self.currency then known = true end
    end
    if not known then self.currency = defaultCurrency() end
    comboFill(self.curCombo, ids, currencyLabel, self.currency)
end

-- The season box offers "current" - whichever season the server is running, so the page follows
-- a rotation instead of freezing on the season that was current when it opened - and every
-- season the server says it closed. Nothing else: a season nobody recorded would be an empty
-- board about data that never existed, and this page invents no history.
function Page:seasonIds()
    local ids, metas = { SEASON_CURRENT }, {}
    for _, meta in ipairs((self.seasonState and self.seasonState.seasons) or {}) do
        local id = meta.id
        if type(id) == "string" and id ~= "" and tonumber(meta.endedAt) ~= nil then
            ids[#ids + 1] = id
            metas[id] = meta
        end
    end
    return ids, metas
end

-- Called when the page opens, when the server's season state moves under it and when a rotation
-- is announced - never per frame.
function Page:fillSeasons()
    local ids, metas = self:seasonIds()
    local parts = {}
    for i, id in ipairs(ids) do
        local meta = metas[id]
        parts[i] = id .. "=" .. tostring((meta and meta.number) or "")
    end
    local sig = table.concat(parts, ",")
    if sig == self.seasonSig then return end
    self.seasonSig = sig
    local known = false
    for _, id in ipairs(ids) do
        if id == self.season then known = true end
    end
    -- a selection the server no longer lists cannot be read: the box falls back to the season
    -- it is running, and says so, instead of showing a label for a board nobody can fetch
    if not known then self.season = SEASON_CURRENT end
    comboFill(self.seasonCombo, ids, function(id) return seasonLabel(metas[id]) end, self.season)
end

-- ---------- state ----------

-- A native popup is a UIManager root: it outlives the box it was opened from, so every path that
-- takes a selector off the screen (leaving the page, hiding the window, a read going out, the
-- kind changing under it) takes the popup with it.
function Page:closeCombos()
    for _, combo in ipairs(self.combos) do
        if combo.expanded == true then
            combo.expanded = false
            local popup = combo.popup
            if popup ~= nil and popup.parentCombo == combo and combo.hidePopup ~= nil then
                pcall(combo.hidePopup, combo)
            end
        end
    end
end

-- One selector at a time: the currency box belongs to the wealth board, the season box to the
-- survival board, and the box that is not on screen takes its popup with it.
function Page:setVisible(visible)
    self.kindCombo:setVisible(visible)
    self.curCombo:setVisible(visible and self.kind ~= "survival")
    self.seasonCombo:setVisible(visible and self.kind == "survival")
    self.list:setVisible(visible)
    for _, b in ipairs({ self.refreshButton, self.selfButton, self.infoButton, self.prevButton, self.nextButton }) do
        b:setVisible(visible)
    end
    if not visible then self:closeCombos() end
end

-- Another currency, another season, another kind: another board. The page number, the board on
-- screen and the last refusal all belonged to the selection that was left behind, so the read
-- starts at page 1 with nothing published under it.
function Page:reselect()
    self.page = 1
    self.snapshot = nil
    self.error = nil
    self:closeCombos()
    self:rebuild()
    self:request(1)
end

function Page:onCurrency(combo)
    local id = combo:getOptionData(combo.selected)
    if type(id) ~= "string" or id == self.currency then return end
    if C.leaderboardBusy() then
        comboSelect(combo, self.currency)   -- a read is in flight: put the box back
        return
    end
    self.currency = id
    self:reselect()
end

function Page:onSeason(combo)
    local id = combo:getOptionData(combo.selected)
    if type(id) ~= "string" or id == self.season then return end
    if C.leaderboardBusy() then
        comboSelect(combo, self.season)     -- a read is in flight: put the box back
        return
    end
    self.season = id
    self:reselect()
end

function Page:onKind(combo)
    local id = combo:getOptionData(combo.selected)
    if type(id) ~= "string" or id == self.kind then return end
    if C.leaderboardBusy() then
        comboSelect(combo, self.kind)       -- a read is in flight: put the box back
        return
    end
    self.kind = id
    self:reselect()
end

function Page:onRefresh()
    self.error = nil
    self:request(self.page)
end

function Page:infoKey()
    return "leaderboard:" .. self.kind .. ":" .. (self.kind == "survival" and self.season or self.currency)
end

function Page:infoText()
    local note = self:noteText()
    if self.error and self.snapshot and self.kind == "survival" then
        note = note .. "\n\n" .. self:survivalNote(self.snapshot)
    end
    return note
end

function Page:onInfo()
    self:closeCombos()
    C.DetailWindow.open(self.panel, self:infoKey(), self:title(), self:infoText())
end

-- The page the player's own line is on. The server sends it; nothing here computes a rank.
function Page:onSelf()
    local mine = self.snapshot and self.snapshot.self or nil
    local target = mine and tonumber(mine.page) or nil
    if target == nil or target == self.page then return end
    self:request(target)
end

function Page:onPage(button)
    if C.leaderboardBusy() then return end
    local target = math.max(1, math.min(self:pages(), self.page + button.internal))
    if target == self.page then return end
    self:request(target)
end

function Page:pages()
    return math.max(1, tonumber(self.snapshot and self.snapshot.pages) or 1)
end

-- One read, through the transport's own gate (650 ms window, one read in flight, newest wish
-- kept). The page number is only adopted once the answer that carries it lands. A wealth board
-- is asked for by currency and a survival board by season: neither is ever asked for both, so
-- no season can be made to look like a historical balance.
function Page:request(n)
    self.page = math.max(1, tonumber(n) or 1)
    if self.kind == "survival" then
        C.requestLeaderboard("survival", nil, self.season, self.page)
    else
        C.requestLeaderboard("wealth", self.currency, nil, self.page)
    end
end

function Page:leave()
    self:closeCombos()
    C.DetailWindow.close(self.panel)
    C.cancelLeaderboard()
end

-- A reply, a refusal, the public settings changing under the page, or a season ending.
--   loading - the read went out; the note says so and the board underneath stays
--   state   - this is the board now
--   error   - see below
--   config  - the server's public rules moved: whatever was read is no longer what it says
--   seasons - the server rotated its season: the box learns the set of seasons there now is
--
-- A refusal is not a hiccup: the server said this board may not be published (switched off,
-- a currency it does not know, a read it could not complete). Keeping the last one on screen
-- would go on telling every player who is richest after the server withdrew the right to say
-- so, so the snapshot, the rows and the player's own standing all go with it. Only a read
-- that never came back keeps its board, marked as the older data it is.
local KEEP_BOARD_ON = { timeout = true }

-- The state line is measured and wrapped by the layout, so anything that changes what it says
-- has to run one: a timeout over a board that stays, a read going out, a refusal. Without
-- this the page would go on showing the note of the last successful read.
function Page:refreshNote()
    if self.panel.g ~= nil then self.panel:layout() end
end

function Page:onReply(kind, args)
    if kind == "config" then
        -- the registry may have been renamed in the same push the public rules came in
        self:fillCurrencies()
        self.snapshot = nil
        self.error = nil
        self:rebuild()
        if self.panel:pageVisible("Leaderboard") then self:request(self.page) end
        return true
    end
    if kind == "seasons" then
        local state = args and args.seasonState
        if type(state) == "table" then self.seasonState = state end
        self:fillSeasons()
        -- Only the board that follows the running season moved. A closed season stays closed,
        -- so a player reading history is not dragged into the new one, and a wealth board never
        -- had a season to be moved out of.
        if self.kind ~= "survival" or self.season ~= SEASON_CURRENT then
            self:refreshNote()
            return true
        end
        -- what was read belongs to the season that just closed: "current" is another board now
        self.snapshot = nil
        self.error = nil
        self.page = 1
        self:rebuild()
        if self.panel:pageVisible("Leaderboard") then self:request(1) end
        return true
    end
    if kind == "error" then
        self.error = tostring((args and args.error) or C.leaderboardError or "unknown")
        if not KEEP_BOARD_ON[self.error] then
            self.snapshot = nil
            self.page = 1
            self:rebuild()
        end
        -- a board that stays (a read that never came back) is not rebuilt -- but what the
        -- page says about it has changed, so the band is measured again
        self:refreshNote()
        return true
    end
    if kind == "loading" then
        self:refreshNote()
        return true
    end
    if kind ~= "state" then return false end
    -- The transport matched the request id; this is the page's own check that the answer is
    -- about the board being looked at, so a wealth answer can never be read as a survival time
    -- and a closed season's board can never be shown as the running one.
    local mine = args.kind == self.kind
    if mine and self.kind == "survival" then
        mine = args.season == self.season
    elseif mine then
        mine = args.currency == self.currency
    end
    if not mine then
        -- an answer for a board the player has already moved past: what is on screen stays,
        -- including a refusal it has not been given an answer to yet
        self:refreshNote()
        return true
    end
    self.error = nil
    self.snapshot = args
    self.page = math.max(1, tonumber(args.page) or self.page)
    self:rebuild()
    return true
end

-- The rows the reply carries, exactly as it ordered them.
function Page:rebuild()
    local snap = self.snapshot
    local me = self.panel:username()
    local survival = self.kind == "survival"
    local hidden = getText(T .. "Leaderboard_Hidden")
    local rows = {}
    for _, e in ipairs((snap and snap.entries) or {}) do
        local name = tostring(e.username or "")
        local amount = nil
        if not survival then amount = tonumber(e.amount) end
        local row = {
            rank = tonumber(e.rank) or 0, name = name, mine = me ~= nil and name == me,
            currency = (not survival) and snap.currency or nil, amount = amount,
            rankText = tostring(tonumber(e.rank) or "-"),
        }
        if survival then
            -- whole game minutes, spelled out as days/hours/minutes. A row the server sent no
            -- time for says it is unknown; it never reads as a life that lasted no time at all
            row.valueText = survivalText(tonumber(e.survivalMinutes))
        elseif amount ~= nil then
            row.valueText = amountText(amount)
        else
            row.valueText = hidden
            row.valueToken = "textFaint"
        end
        rows[#rows + 1] = row
    end
    self.rows = rows
    self.list:setItems(rows)
    -- the state line above the table may have grown or shrunk with this reply (a refusal is
    -- longer than a rank), and it is the band the toolbar and the table sit under
    if self.panel.g ~= nil then self.panel:layout() end
end

-- ---------- geometry ----------

-- The whole page inside the workspace the window handed over. Own card, own toolbar, own pager.
function Page:layout(x, y, w, h)
    local right = x + w - PAD
    local bottom = y + h
    self.cardX, self.cardY, self.cardW, self.cardH = x, y, w, math.max(CARD_TITLE_H + ROW * 3, h)
    self.kindCombo:setWidth(comboWidth(self.kindCombo, 110, math.floor(w * 0.3)))
    self.curCombo:setWidth(comboWidth(self.curCombo, 120, math.floor(w * 0.3)))
    self.seasonCombo:setWidth(comboWidth(self.seasonCombo, 120, math.floor(w * 0.3)))
    local capH = fontH.small + 4
    local band = math.max(CHIP_H, self.kindCombo.height)
    self.noteY = y + CARD_TITLE_H
    -- The visible band stays short; the detail button keeps every date and error readable.
    local note, token = self:noteText()
    local lineH = fontH.small + 2
    -- Reserve the controls and list first; the full uncut note lives in the shared detail window.
    local selector = self.kind == "survival" and self.seasonCombo or self.curCombo
    local items = { self.kindCombo, selector, self.refreshButton, self.selfButton, self.infoButton }
    local toolH = placeRow(items, x + PAD, 0, right, band, capH + 6)
    local reserve = CARD_TITLE_H + capH * 2 + toolH + 12 + ROW * 4
    local maxNote = math.max(1, math.min(4, math.floor((h - reserve) / lineH)))
    self.noteLines = U.wrapText(note, math.max(60, w - PAD * 2), maxNote)
    self.noteToken = token
    self.noteH = math.max(ROW, #self.noteLines * lineH + 6)
    local toolY = self.noteY + self.noteH + capH
    for _, item in ipairs(items) do item:setY(item.y + toolY) end
    local listY = toolY + toolH + 6
    self.headerY = listY
    local footerY = bottom - ROW
    local listW = w - 2
    local listH = math.max(ROW * 2, footerY - (listY + ROW) - 2)
    self.list:setX(x + 1); self.list:setY(listY + ROW)
    self.list.ecChromeH = listY + ROW - y + ROW
    if self.list.width ~= listW or self.list.height ~= listH then self.list:resize(listW, listH) end
    local cols = self.list.cols
    cols.rankR = PAD + math.max(textWidth(getText(T .. "Leaderboard_Rank")), textWidth("9999"))
    cols.name = cols.rankR + PAD
    cols.amountR = listW - 12 - PAD
    local widest = textWidth("999,999,999")
    if self.kind == "survival" then
        widest = math.max(textWidth(survivalText(SURVIVAL_SAMPLE)),
            textWidth(getText(T .. "Leaderboard_SurvivalColumn")))
    end
    cols.nameW = math.max(0, cols.amountR - COIN_SMALL - 4
        - math.max(widest, textWidth(getText(T .. "Leaderboard_Hidden"))) - PAD - cols.name)
    self.footerY = footerY
    local px = x + PAD + textWidth(getText(T .. "Market_Page", "99", "99")) + PAD
    for _, b in ipairs({ self.prevButton, self.nextButton }) do
        b:setX(px); b:setY(footerY + math.floor((ROW - CHIP_H) / 2))
        px = px + b.width + 6
    end
    if C.DetailWindow.isOpen(self.panel, self:infoKey()) then
        C.DetailWindow.update(self.panel, self:infoKey(), self:title(), self:infoText())
    end
end

-- ---------- paint ----------

function Page:title()
    return getText(T .. (self.kind == "survival" and "Leaderboard_SurvivalTitle" or "Leaderboard_Title"))
end

-- Which season the board on screen is, exactly as the server labelled it: its number, whether it
-- is the one being played, whether its records are known to be incomplete, when it started, and
-- when it ends or ended (a season with no deadline is ended by hand and says so). A reply with
-- no season in it is a reply about no season at all, and is worded that way rather than
-- borrowing the dates of another one.
function Page:seasonNote(snap)
    local meta = snap.selectedSeason
    if type(meta) ~= "table" then return getText(T .. "Season_Empty") end
    local off = self.panel.offsetMin
    local closed = tonumber(meta.endedAt)
    local parts = { seasonLabel(meta),
        getText(T .. (closed ~= nil and "Season_Status_Closed" or "Season_Status_Current")) }
    if meta.partial == true then parts[#parts + 1] = getText(T .. "Season_Partial") end
    local started = tonumber(meta.startedAt)
    if started ~= nil then
        parts[#parts + 1] = getText(T .. "Season_StartAt") .. ": " .. U.stampText(started, off)
    end
    local ends = tonumber(meta.endsAt)
    if closed ~= nil then
        parts[#parts + 1] = getText(T .. "Season_ClosedAt") .. ": " .. U.stampText(closed, off)
    elseif ends ~= nil then
        parts[#parts + 1] = getText(T .. "Season_EndAt") .. ": " .. U.stampText(ends, off)
    else
        parts[#parts + 1] = getText(T .. "Season_Manual")
    end
    local ranked = tonumber(meta.participants)
    if ranked ~= nil then parts[#parts + 1] = getText(T .. "Season_Participants", tostring(ranked)) end
    return table.concat(parts, "  ")
end

-- The player's own standing on a survival board: the longest single life this season recorded
-- for them, and the life they are living now when the server sent one. No record at all is said
-- plainly - a life of zero minutes is a claim the server never made.
function Page:survivalNote(snap)
    local mine = snap.self or {}
    local rank = tonumber(mine.rank)
    local note
    if rank ~= nil then
        note = getText(T .. "Leaderboard_SurvivalSelf", tostring(rank),
            survivalText(tonumber(mine.survivalMinutes)))
    else
        note = getText(T .. "Leaderboard_SurvivalUnranked")
    end
    local live = tonumber(mine.currentMinutes)
    if live ~= nil then
        note = note .. "  " .. getText(T .. "Leaderboard_SurvivalCurrent", survivalText(live))
    end
    note = note .. "  " .. self:seasonNote(snap) .. "  " .. getText(T .. "Leaderboard_SurvivalNote")
    -- the moment of the server's own read, not of this request
    if tonumber(snap.at) then
        note = note .. "  " .. getText(T .. "Leaderboard_At",
            U.stampText(tonumber(snap.at), self.panel.offsetMin))
    end
    return note
end

-- What the page is, in one note band, most urgent first: a refusal (the board underneath stays,
-- marked), the first read of all, the public rule in force, and the player's own standing.
function Page:noteText()
    if self.error ~= nil then
        local key = T .. "Leaderboard_Error_" .. self.error
        local note = getTextOrNull(key) or getText(T .. "Leaderboard_Error_generic", self.error)
        if self.snapshot then
            note = getText(T .. "Leaderboard_Stale") .. "\n" .. note .. "\n" .. getText(T .. "History_Stale")
        end
        return note, "errorText"
    end
    local snap = self.snapshot
    if snap == nil then
        return getText(T .. (C.leaderboardBusy() and "Wallet_Loading" or "Leaderboard_Empty")), "textMuted"
    end
    if self.kind == "survival" then return self:survivalNote(snap), "textMuted" end
    local mine = snap.self or {}
    local rank = tonumber(mine.rank)
    local amount = tonumber(mine.amount)
    local note
    if amount == nil then
        -- The board only exists when every wallet of that currency could be read (the server
        -- refuses the whole read otherwise, data_unreadable), so this is a malformed reply.
        -- It is worded as the unreadable read it is: "0" would be a claim nobody made.
        note = getText(T .. "Leaderboard_Error_data_unreadable")
    elseif rank then
        note = getText(T .. "Leaderboard_SelfRank", tostring(rank),
            amountText(amount), currencyLabel(snap.currency))
    else
        note = getText(T .. "Leaderboard_SelfNone", amountText(amount), currencyLabel(snap.currency))
    end
    if snap.showAmounts ~= true then note = note .. "  " .. getText(T .. "Leaderboard_AmountsHidden") end
    -- the moment of the server's own census, not of this request: paging inside that window
    -- reads one and the same board, so no rank jumps between two pages
    if tonumber(snap.at) then
        note = note .. "  " .. getText(T .. "Leaderboard_At",
            U.stampText(tonumber(snap.at), self.panel.offsetMin))
    end
    return note, "textMuted"
end

function Page:draw(owner)
    card(owner, self.cardX, self.cardY, self.cardW, self.cardH, self:title())
    -- the band the layout measured: every line of it is painted, none is cut away
    local lineH = fontH.small + 2
    local lines = self.noteLines
    if lines == nil then
        lines = U.wrapText((self:noteText()), math.max(60, self.cardW - PAD * 2), 3)
    end
    for i = 1, #lines do
        text(owner, lines[i], self.cardX + PAD, self.noteY + 4 + (i - 1) * lineH,
            self.noteToken or "textMuted")
    end
    text(owner, getText(T .. "Leaderboard_Kind"), self.kindCombo.x,
        self.kindCombo.y - fontH.small - 2, "textMuted")
    local selector, caption = self.curCombo, "Leaderboard_Currency"
    if self.kind == "survival" then selector, caption = self.seasonCombo, "Season_Select" end
    text(owner, getText(T .. caption), selector.x, selector.y - fontH.small - 2, "textMuted")
    -- the column header, painted by the page (this table is not sortable: the server ranks it)
    local cols = self.list.cols
    local hx, hy = self.list.x, self.headerY
    fill(owner, hx, hy, self.list.width, ROW, "well", "rect")
    local hty = hy + math.floor((ROW - fontH.small) / 2)
    textRight(owner, getText(T .. "Leaderboard_Rank"), hx + cols.rankR, hty, "textMuted")
    text(owner, getText(T .. "Leaderboard_Player"), hx + cols.name, hty, "textMuted")
    textRight(owner, getText(T .. (self.kind == "survival" and "Leaderboard_SurvivalColumn"
        or "Leaderboard_Amount")), hx + cols.amountR, hty, "textMuted")
    if #self.rows == 0 and self.snapshot ~= nil then
        text(owner, getText(T .. "Leaderboard_Empty"), hx + PAD,
            self.list.y + math.floor((ROW - fontH.small) / 2), "textMuted")
    end
    local fy = self.footerY + math.floor((ROW - fontH.small) / 2)
    text(owner, getText(T .. "Market_Page", tostring(self.page), tostring(self:pages())),
        self.cardX + PAD, fy, "textMuted")
    -- the count belongs to a board: with none on screen (a refused read) there is nothing to
    -- count, and "0 ranked" would be a claim about the server's data. A board that really is
    -- empty answers total = 0 itself, and that zero is printed.
    local total = self.snapshot ~= nil and tonumber(self.snapshot.total) or nil
    if total ~= nil then
        textRight(owner, getText(T .. "Leaderboard_Total", tostring(total)),
            self.cardX + self.cardW - PAD, fy, "textMuted")
    end
end

-- Enable states, once per frame: everything closes while a read is in flight, so the player
-- cannot queue a wish they can no longer see the state of.
function Page:sync()
    local busy = C.leaderboardBusy()
    self.kindCombo:setEnabled(not busy)
    self.curCombo:setEnabled(not busy)
    self.seasonCombo:setEnabled(not busy)
    -- a box that can no longer be used does not keep an open popup over the page
    if busy then self:closeCombos() end
    -- the server's season state arrives with the greeting, which can be long before this page
    -- is first looked at; the box offers what the server has said, never a season of its own
    if C.seasonState ~= nil and C.seasonState ~= self.seasonState then
        self.seasonState = C.seasonState
        self:fillSeasons()
    end
    self.refreshButton:setEnable(not busy)
    self.infoButton:setEnable(self.snapshot ~= nil or self.error ~= nil)
    self.prevButton:setEnable(not busy and self.page > 1)
    self.nextButton:setEnable(not busy and self.page < self:pages())
    local mine = self.snapshot and self.snapshot.self or nil
    local target = mine and tonumber(mine.page) or nil
    self.selfButton:setEnable(not busy and target ~= nil and target ~= self.page)
end

-- The ring walks what is on screen: the selector of the other kind is not on the page, so it is
-- not in the ring either.
function Page:keyboardTargets(out)
    local title = self:title()
    out[#out + 1] = { kind = "combo", control = self.kindCombo, label = getText(T .. "Leaderboard_Kind") }
    if self.kind == "survival" then
        out[#out + 1] = { kind = "combo", control = self.seasonCombo,
            label = getText(T .. "Season_Select") }
    else
        out[#out + 1] = { kind = "combo", control = self.curCombo,
            label = getText(T .. "Leaderboard_Currency") }
    end
    out[#out + 1] = { kind = "group", controls = { self.refreshButton, self.selfButton, self.infoButton },
        label = title }
    out[#out + 1] = { kind = "list", control = self.list, label = title }
    out[#out + 1] = { kind = "group", controls = { self.prevButton, self.nextButton },
        label = getText(T .. "Kb_Market_Pager") }
    return out
end

LB.Page = Page

return LB
