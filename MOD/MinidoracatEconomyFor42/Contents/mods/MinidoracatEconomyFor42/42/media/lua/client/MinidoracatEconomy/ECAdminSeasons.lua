-- MinidoracatEconomyFor42 -- the season desk (client). Adds exactly one namespace:
-- C.AdminSeasons.
--
--   C.AdminSeasons.create(owner, isPending)   an initialised ISPanel child, NOT added by this
--                                             module: the admin controller adds it and gives it
--                                             the page area of the Seasons sub tab. Methods:
--                                             refresh(), resize(w, h), tick(now), layout(),
--                                             updateEnabled(), keyboardTargets(), onEscape(),
--                                             onReply(args, req), onOptionReply(args, req),
--                                             onTimeout(req), onLeave(), clear(), dispose().
--
-- The host reads the running season and the ones before it here, and makes the two writes that
-- belong to them: the real-world season length (SeasonDays, applied to the current season via
-- owner:sendOption), and starting a new season explicitly
-- (owner:openSeasonDialog + owner:sendSeasons, gated on the NATIVE role capability, never the
-- economy write role). The controller owns the admin.seasons slot, the requestId and the
-- timeout; this page owns what is drawn and the unsent draft.
--
-- The limits that are deliberate, not missing:
--   * no retry. A rotation whose answer never came is reported as unknown and never re-sent
--     from here: the next read is what says whether the season turned.
--   * no arithmetic. Every field is the server's SeasonState; a value the reply did not carry
--     is drawn as unknown, never as 0 (0 days really means "manual rotation only").
--   * no player ranking -- the public survival board answers that; this page holds metadata.
--
-- Engine references (snapshot 42.20.4-20260826):
--   UIElement.java:1626-1634   children paint between prerender and render: the backdrop this
--                              panel fills in prerender sits under its own list and chips.

require "ISUI/ISPanel"

if not MinidoracatEconomy or not MinidoracatEconomy.Client or not MinidoracatEconomy.Client.UI then
    require "MinidoracatEconomy/ECWidgets"
end
require "MinidoracatEconomy/ECDetailWindow"

local EC = MinidoracatEconomy
local C = EC.Client
local U = C.UI
local D = C.DetailWindow

local P = {}
C.AdminSeasons = P

local PAD, T = U.PAD, U.T
local CARD_TITLE_H = U.CARD_TITLE_H
local fontH = U.fontH
local text, fitText, textWidth = U.text, U.fitText, U.textWidth
local card, stampText = U.card, U.stampText
local newEntry, entryText, setEntryText = U.newEntry, U.entryText, U.setEntryText

local COMMAND = "admin.seasons"
-- The season length is this sandbox option and nothing else: manageOnly, 0 = manual only.
local DAYS_KEY = "SeasonDays"
local DAYS_CHARS = 4        -- 3650 is the schema's own ceiling
local GUTTER = 12           -- the list's scrollbar gutter

local function tr(key) return getText(T .. key) end
local function lineH() return fontH.small + 6 end
local function chipH() return math.max(24, fontH.small + 10) end
local function entryH() return math.max(22, fontH.small + 10) end

-- A field the reply may simply not carry. Nothing here defaults a missing number to zero: a
-- season the server said nothing about is shown as unknown, never as "nobody survived".
local function intOf(value)
    local n = tonumber(value)
    if n == nil or n ~= n then return nil end
    return math.floor(n)
end

local function str(value)
    if type(value) == "string" and value ~= "" then return value end
    return nil
end

local function numberText(meta)
    local n = intOf(meta.number)
    if n == nil then return "-" end
    return getText(T .. "Season_Number", tostring(n))
end

-- A real-world length in days, as this page is allowed to state it. 0 is the server's own
-- "manual rotation only"; a value the reply never carried (or a negative one, which the schema
-- does not allow) is unknown and is drawn as such -- printing it as "manual" would state a
-- rotation rule the server never sent.
local function daysText(value)
    local n = intOf(value)
    if n == nil or n < 0 then return "-" end
    if n == 0 then return tr("Season_Manual") end
    return getText(T .. "Admin_Set_Days", tostring(n))
end

-- ---------- the page ----------

local Page = ISPanel:derive("MinidoracatEconomyAdminSeasons")

function Page:createChildren()
    self.list = U.newTable(U.TableCell, lineH() + 8)
    self.list.onSelect = function(_, item) self:onRow(item) end
    self:addChild(self.list)

    -- Season length is a draft until Apply or Enter; a half-typed number is never sent.
    self.daysEntry = newEntry(80, entryH(), { maxLen = DAYS_CHARS })
    self.daysEntry.target = self
    self.daysEntry.onTextChangeFunction = Page.onDaysTyped
    self.daysEntry.onCommandEntered = function() self:onApplyDays() end
    self:addChild(self.daysEntry)

    local function chip(label, handler, style)
        local b = U.Button.create(0, 0, 100, chipH(), label, self, handler, style or "chip")
        self:addChild(b)
        return b
    end
    self.applyButton = chip(tr("Season_ApplyDays"), Page.onApplyDays, "primary")
    self.startButton = chip(tr("Season_StartNext"), Page.onStartNext, "primary")
    self:layout()
end

-- ----- the snapshot -----

function Page:currentMeta()
    local state = self.state
    if state == nil then return nil end
    local id = str(state.currentId)
    if id == nil then return nil end
    for _, meta in ipairs(self.metas or {}) do
        if meta.id == id then return meta end
    end
    return nil
end

-- The configured real-world length, or nil when it has not been read.
-- Never 0 for those: 0 is the server saying "manual rotation only", and a page that is merely
-- still loading must not say that.
function Page:configuredDays()
    local state = self.state
    local days = state ~= nil and intOf(state.configuredDays) or nil
    if days == nil or days < 0 then return nil end
    return days
end

-- Whatever the reply carried becomes the state, exactly as the server stated it. Nothing is
-- merged with what was on screen: the server recomputes the whole SeasonState per read.
function Page:adopt(args)
    local state = type(args.seasonState) == "table" and args.seasonState or nil
    if state == nil then
        self.readError = "data_unreadable"
        self.owner.message = { text = U.adminErrorText("data_unreadable"), error = true }
        self:updateEnabled()
        return
    end
    self.state = state
    self.sentRead = true -- this full snapshot satisfies the page's outstanding read
    self.owner.seasonUnknown = nil -- a newer complete answer supersedes a previously unknown outcome
    self.readError = nil
    self.updatedAt = EC.now()
    local metas = {}
    for _, meta in ipairs(type(state.seasons) == "table" and state.seasons or {}) do
        -- a malformed entry is dropped rather than painted as a season with no identity
        if type(meta) == "table" and str(meta.id) ~= nil then metas[#metas + 1] = meta end
    end
    self.metas = metas
    -- a draft that is being edited is never overwritten by a fresh snapshot: the host is in the
    -- middle of typing a number, and a background read must not take it away. A length the
    -- server did not state leaves the box empty rather than seeding it with a number nobody
    -- configured.
    if self.draftDirty ~= true then
        local days = self:configuredDays()
        setEntryText(self.daysEntry, days ~= nil and tostring(days) or "")
    end
    self:rebuild()
    self:layout()
end

-- ----- reads -----

function Page:live()
    return self:getIsVisible() and self.owner:readAllowed()
end

-- The read the page is owed. The shared command slot may be busy (another page's read, the
-- rotation itself, the server's own 500 ms window), so the wish is recorded and tick() asks
-- again -- entering the tab is never silently dropped, and never turns into two commands either.
function Page:pump()
    if not self:live() then return end
    if self.owner.dialog ~= nil then return end
    if self.isPending(COMMAND) then return end
    if self.sentRead == true then return end
    if self.owner:sendSeasons({ action = "list" }) then self.sentRead = true end
end

-- The refresh chip, the tab being entered, and the 30 s backstop that is how an automatic
-- rotation reaches a page that is already open.
function Page:refresh()
    self.sentRead = nil
    self:pump()
end

-- ----- the season length (admin.option) -----

function Page:onDaysTyped()
    self.draftDirty = true
    self.owner:updateEnabled()
end

-- The draft as a value the option schema would accept, or nil. The page enforces "a whole
-- number of days, never negative" on its own and the schema's bounds when the schema is there;
-- the server re-validates either way, so nothing here is the only gate.
function Page:draftDays()
    local raw = string.match(entryText(self.daysEntry), "^%s*(.-)%s*$")
    local n = tonumber(raw)
    if raw == "" or n == nil or n ~= n or n ~= math.floor(n) or n < 0 then return nil end
    local spec = EC.OPTION_BY_KEY[DAYS_KEY]
    if spec ~= nil and (n < spec.min or n > spec.max) then return nil end
    return n
end

function Page:onApplyDays()
    if self.owner.dialog ~= nil or self.isPending("admin.option") then return end
    local value = self:draftDays()
    if value == nil then
        self.owner.message = { text = U.adminErrorText("invalid_args"), error = true }
        return
    end
    -- sendOption owns the manageOnly gate, the requestId and the shared admin.option slot (and
    -- re-runs updateEnabled for the whole window). A refusal keeps the draft exactly as typed:
    -- the host's number is theirs until it is applied.
    if not self.owner:sendOption(DAYS_KEY, value, nil) then return end
    -- which write is this desk's own. SeasonDays is an ordinary option, so the settings page
    -- (or a group reset) can write the very same key: without this, their success would clear
    -- a draft this desk never sent.
    local sent = self.owner.pendingOption
    self.sentOption = sent ~= nil and sent.requestId or nil
end

-- The option write's reply, handed over by the controller (which owns that slot). Only this
-- key says anything about the season, and only the write this desk itself sent may touch the
-- draft: another page's success on SeasonDays moves the server's baseline, which is re-read,
-- and leaves the number the host is typing exactly where it is.
function Page:onOptionReply(args, req)
    if req == nil or req.key ~= DAYS_KEY then return end
    local mine = self.sentOption ~= nil and req.requestId == self.sentOption
    if mine then self.sentOption = nil end
    if args.ok ~= true then return end       -- the draft stays; the controller reported the refusal
    if mine then self.draftDirty = nil end
    -- the option snapshot is not the season state: the length that is now configured is read
    -- back from the server's own SeasonState rather than guessed from the write that just went
    self.sentRead = nil
    self:pump()
end

-- ----- the rotation (admin.seasons{action="start"}) -----

function Page:onStartNext()
    if self.owner.dialog ~= nil or self.isPending(COMMAND) then return end
    local meta = self:currentMeta()
    if meta == nil then
        -- no current season means there is nothing to replace: the server would refuse, and
        -- guessing an id here is exactly how a rotation lands on the wrong season
        self.owner.message = { text = U.adminErrorText("not_ready"), error = true }
        return
    end
    self.owner.message = nil
    self.owner:openSeasonDialog({ expectedSeason = meta.id, number = intOf(meta.number) })
end

-- The outcome of the one rotation that was confirmed. It is answered whether or not the page is
-- on screen: a host pressed it, the dialog is the controller's and the state the server sent
-- back is this page's own answer, not a stale one.
function Page:onStartReply(args, req)
    local owner = self.owner
    -- the confirmation may have been cancelled and another one opened in its place: only the
    -- box that asked this question is written into or closed
    local dlg = owner.dialog
    if dlg ~= (req and req.dialog) then dlg = nil end
    if dlg ~= nil and dlg.mode ~= "season" then dlg = nil end
    if args.ok ~= true then
        local body = U.adminErrorText(args.error)
        if dlg ~= nil then owner:dialogError(dlg, body) else owner.message = { text = body, error = true } end
        -- A refusal normally carries the state the server is running with -- season_changed is
        -- the whole point of the expected-season check -- so the page shows what really is
        -- current. One that carries none leaves the screen alone: overwriting the refusal with
        -- "unreadable" would hide the reason the write was turned down.
        if type(args.seasonState) == "table" then self:adopt(args) end
        self.sentRead = nil
        self:updateEnabled()
        return
    end
    -- duplicate means this very requestId had already been carried out: the season turned once,
    -- which is exactly what the host asked for, so it is reported as the rotation it was.
    -- publication_failed is a committed rotation whose records or notices did not all go out:
    -- the season really did turn, so it is neither a refusal nor anything to send again -- it
    -- is said out loud instead of being reported as a clean success.
    if str(args.warning) == "publication_failed" then
        owner.message = { text = tr("Season_PublicationFailed"), error = true }
    else
        owner.message = { text = tr("Season_Started") }
    end
    if dlg ~= nil then owner:closeDialog() end
    self:adopt(args)
    self:updateEnabled()
end

-- ----- replies -----

-- A reply the controller has already matched to the request that was open (requestId), so what
-- arrives here is this page's own answer. `req` is that request, which is how a read and a
-- rotation are told apart without trusting the reply to say.
function Page:onReply(args, req)
    if req ~= nil and req.action == "start" then return self:onStartReply(args, req) end
    -- a page nobody is looking at applies nothing: this answer only freed the command slot
    if not self:getIsVisible() then return end
    if args.ok == false then
        -- a refusal is a message and nothing else: the state that is up stays up, so a busy or
        -- unreadable server never reads as "there is no season". It is not asked for again on
        -- its own either -- the refresh chip and the tab's own poll are the way back.
        self.owner.message = { text = U.adminErrorText(args.error), error = true }
        self.readError = args.error
        self:updateEnabled()
        return
    end
    self:adopt(args)
end

function Page:onTimeout(req)
    -- A rotation whose answer never came has a genuinely unknown outcome: it is reported as
    -- unknown by the controller's own timeout line and is NEVER sent again on its own. Either
    -- way the page is owed its question again -- and that question is a read, not the write.
    self.sentRead = nil
    self:updateEnabled()
end

-- ----- rows -----

function Page:endText(meta, closed)
    if closed then
        local at = intOf(meta.endedAt)
        if at ~= nil then return stampText(at, self.owner.offsetMin) end
        return "-"
    end
    local at = intOf(meta.endsAt)
    if at ~= nil then return stampText(at, self.owner.offsetMin) end
    return tr("Season_Manual")
end

-- The whole season, as the reader window shows it: every field the server sent, nothing
-- shortened. A field the reply does not carry is left out instead of printed as a value.
function Page:seasonText(meta, closed)
    local lines = { numberText(meta) }
    lines[#lines + 1] = closed and tr("Season_Status_Closed") or tr("Season_Status_Current")
    local started = intOf(meta.startedAt)
    if started ~= nil then
        lines[#lines + 1] = tr("Season_StartAt") .. "  " .. stampText(started, self.owner.offsetMin)
    end
    local ends = intOf(meta.endsAt)
    lines[#lines + 1] = tr("Season_EndAt") .. "  "
        .. (ends ~= nil and stampText(ends, self.owner.offsetMin) or tr("Season_Manual"))
    local ended = intOf(meta.endedAt)
    if ended ~= nil then
        lines[#lines + 1] = tr("Season_ClosedAt") .. "  " .. stampText(ended, self.owner.offsetMin)
    end
    lines[#lines + 1] = tr("Season_Duration") .. "  " .. daysText(meta.durationDays)
    local people = intOf(meta.participants)
    if people ~= nil then
        lines[#lines + 1] = getText(T .. "Season_Participants", tostring(people))
    end
    if meta.partial == true then lines[#lines + 1] = tr("Season_Partial") end
    lines[#lines + 1] = ""
    -- an ASCII tag for the opaque identifier: this is what gets pasted into a ticket or read
    -- back to the server, and a localised label in front of it would only be in the way
    lines[#lines + 1] = "season   " .. tostring(meta.id)
    return table.concat(lines, "\n")
end

function Page:rebuild()
    local currentId = self.state ~= nil and str(self.state.currentId) or nil
    local keep = self.selectedId
    local rows, selected = {}, nil
    for _, meta in ipairs(self.metas or {}) do
        local closed = meta.id ~= currentId
        local people = intOf(meta.participants)
        local row = {
            id = meta.id,
            cells = {
                numberText(meta),
                closed and tr("Season_Status_Closed") or tr("Season_Status_Current"),
                intOf(meta.startedAt) ~= nil and stampText(intOf(meta.startedAt), self.owner.offsetMin) or "-",
                self:endText(meta, closed),
                people ~= nil and getText(T .. "Season_Participants", tostring(people)) or "-",
                meta.partial == true and tr("Season_Partial") or "-",
            },
            tokens = { "text", closed and "textMuted" or "text", "textMuted", "textMuted",
                "textMuted", meta.partial == true and "negative" or "textFaint" },
            detailText = self:seasonText(meta, closed),
        }
        rows[#rows + 1] = row
        if row.id == keep then selected = #rows end
    end
    self.rows = rows
    self.list:setItems(rows)
    self.list:setSelectedIndex(selected)
    -- the record window belongs to the row that opened it: a season that is no longer listed
    -- takes its reader with it, and one that is still there has its text replaced only while
    -- that reader is really open (D.update answers false once the host closed it)
    if selected == nil then
        if keep ~= nil then
            self.selectedId = nil
            D.close(self)
        end
    else
        D.update(self, "season:" .. tostring(keep), tr("Season_History"), rows[selected].detailText)
    end
end

function Page:onRow(item)
    if item == nil or not self.owner:readAllowed() then return end
    self.selectedId = item.id
    D.open(self, "season:" .. tostring(item.id), tr("Season_History"), item.detailText)
end

-- ----- the summary band -----

-- What the band says about the season that is running, rebuilt when the state, the permission,
-- the command or the minute moves -- never per frame.
function Page:refreshSummary()
    local state = self.state
    local busy = self.isPending(COMMAND)
    local manage = self.owner:manageAllowed()
    local minute = math.floor(EC.now() / 60000)
    if self.sumState == state and self.sumBusy == busy and self.sumManage == manage
        and self.sumMinute == minute and self.summary ~= nil then return end
    self.sumState, self.sumBusy, self.sumManage, self.sumMinute = state, busy, manage, minute
    local lines = {}
    local meta = self:currentMeta()
    if meta ~= nil then
        local head = tr("Season_Current") .. "  " .. numberText(meta) .. "  " .. tr("Season_Status_Current")
        if meta.partial == true then head = head .. "  " .. tr("Season_Partial") end
        lines[#lines + 1] = head
        local started = intOf(meta.startedAt)
        if started ~= nil then
            lines[#lines + 1] = tr("Season_StartAt") .. "  " .. stampText(started, self.owner.offsetMin)
        end
        local ends = intOf(meta.endsAt)
        local endLine = tr("Season_EndAt") .. "  "
            .. (ends ~= nil and stampText(ends, self.owner.offsetMin) or tr("Season_Manual"))
        if ends ~= nil then
            local left = ends - EC.now()
            -- a deadline that has already passed is not counted down: the server closes the
            -- season, and a negative remainder would read as a season that is still running
            if left > 0 then
                endLine = endLine .. "  " .. getText(T .. "Season_Remaining", U.realDurationText(left))
            end
        end
        lines[#lines + 1] = endLine
        lines[#lines + 1] = tr("Season_Duration") .. "  " .. daysText(meta.durationDays)
        local people = intOf(meta.participants)
        if people ~= nil then
            lines[#lines + 1] = getText(T .. "Season_Participants", tostring(people))
        end
    elseif state ~= nil then
        lines[#lines + 1] = tr("Season_Empty")
    elseif self.readError ~= nil then
        lines[#lines + 1] = U.adminErrorText(self.readError)
    else
        lines[#lines + 1] = busy and tr("Admin_Loading") or tr("Season_Empty")
    end
    -- Keep the saved setting separate from an unsent draft. Missing is not the manual value 0.
    lines[#lines + 1] = tr("Season_ConfigDays") .. "  " .. daysText(self:configuredDays())
    lines[#lines + 1] = tr("Season_DaysHint")
    if not manage then lines[#lines + 1] = tr("Admin_Set_ManageOnly") end
    self.summary = lines
    if self.layoutW ~= nil and math.max(1, #lines) ~= self.summaryLines then self:layout() end
end

-- ----- geometry -----

-- Six columns, each measured from the widest thing it can really print, shrunk together when the
-- window (or the UI font) leaves less than they asked for. Every column keeps a width, so the
-- cell fits its own text instead of painting over its neighbour; the whole row is in the reader.
function Page:columns(inner)
    local stamp = math.max(textWidth(U.STAMP_SAMPLE), textWidth(tr("Season_StartAt")),
        textWidth(tr("Season_EndAt")), textWidth(tr("Season_Manual")))
    local specs = {
        math.max(textWidth(tr("Season_Title")), textWidth(getText(T .. "Season_Number", "99"))),
        math.max(textWidth(tr("Season_Status_Current")), textWidth(tr("Season_Status_Closed"))),
        stamp, stamp,
        textWidth(getText(T .. "Season_Participants", "9999")),
        textWidth(tr("Season_Partial")),
    }
    local need = 0
    for _, value in ipairs(specs) do need = need + value + PAD end
    local scale = 1
    if need > inner and need > 0 then scale = inner / need end
    local cols, x = {}, PAD
    for i, value in ipairs(specs) do
        local width = math.max(24, math.floor((value + PAD) * scale))
        cols[i] = { x = x, width = math.max(16, width - 6) }
        x = x + width
    end
    return cols
end

function Page:layout()
    local w, h = self.width, self.height
    local visible = self:getIsVisible()
    local title = math.max(CARD_TITLE_H, fontH.medium + 8)
    self.titleH = title
    local lh, eh, ch = lineH(), entryH(), chipH()

    -- the length row: the label, the draft, the chip that applies it and the rotation itself.
    -- A window too narrow for one row puts the rotation on its own line rather than clipping
    -- it, and the band above is budgeted against whichever of the two it turned out to be.
    local labelW = textWidth(tr("Season_ConfigDays")) + 6
    local daysW = math.max(48, math.min(90, textWidth("00000") + 20))
    local applyW = math.min(textWidth(self.applyButton.fullTitle) + 24, math.max(60, math.floor(w * 0.3)))
    local startW = math.min(textWidth(self.startButton.fullTitle) + 24, math.max(60, math.floor(w * 0.3)))
    local oneRow = PAD + labelW + daysW + 6 + applyW + 6 + startW <= w
    local bandRow = math.max(eh, ch)
    local controlsH = (oneRow and bandRow or (bandRow * 2 + 4)) + 6

    self:refreshSummary()
    local bandY = title + 2
    self.bandY = bandY
    -- the band never eats the rows: it takes only what is left over a minimum list height, down
    -- to no line at all, and the controls under it are never the thing that gives way
    local headerH = lh + 2
    local roomH = h - PAD - bandY - controlsH - headerH - self.list.rowHeight
    local bandMax = roomH > 0 and math.floor(roomH / lh) or 0
    self.summaryLines = math.max(1, #(self.summary or {}))
    self.bandLines = math.min(self.summaryLines, bandMax)
    local bandH = self.bandLines > 0 and (lh * self.bandLines + 4) or 0

    local rowY = bandY + bandH
    self.labelX, self.labelY = PAD, rowY + math.floor((math.max(eh, ch) - fontH.small) / 2)
    self.daysEntry:setVisible(visible)
    self.daysEntry:setWidth(daysW)
    self.daysEntry:setHeight(eh)
    self.daysEntry:setX(PAD + labelW)
    self.daysEntry:setY(rowY)
    self.applyButton:setVisible(visible)
    self.applyButton:setWidth(applyW)
    self.applyButton:setHeight(ch)
    self.applyButton:setX(PAD + labelW + daysW + 6)
    self.applyButton:setY(rowY + math.floor((eh - ch) / 2))
    U.setButtonTitle(self.applyButton, self.applyButton.fullTitle)
    self.startButton:setVisible(visible)
    self.startButton:setWidth(startW)
    self.startButton:setHeight(ch)
    if oneRow then
        self.startButton:setX(self.applyButton.x + applyW + 6)
        self.startButton:setY(self.applyButton.y)
    else
        self.startButton:setX(PAD)
        self.startButton:setY(rowY + math.max(eh, ch) + 4)
    end
    U.setButtonTitle(self.startButton, self.startButton.fullTitle)
    local controlsBottom = math.max(self.startButton.y + ch, rowY + math.max(eh, ch)) + 6

    self.headerY = controlsBottom
    local listY = self.headerY + headerH
    local listW = math.max(120, w - PAD * 2)
    local listH = math.max(self.list.rowHeight, h - PAD - listY)
    U.placeList(self.list, visible, PAD, listY, listW, listH)
    self.listY = listY
    self.list.cols = self:columns(math.max(80, listW - GUTTER))
    self.layoutW, self.layoutH = w, h
    self:updateEnabled()
end

function Page:resize(width, height)
    if self.width ~= width then self:setWidth(width) end
    if self.height ~= height then self:setHeight(height) end
    self:layout()
end

-- ----- painting -----

function Page:prerender()
    local w, h = self.width, self.height
    -- an opaque surface: this page is read against stamps and counts, and nothing behind it must
    -- show through the rows they are compared with
    U.theme:fill(self, 0, 0, w, h, "surface", "rect", 1)
    card(self, 0, 0, w, h, fitText(tr("Season_Title"), math.max(20, w - PAD * 2), UIFont.Medium), self.titleH)

    self:refreshSummary()
    local lh = lineH()
    local y = self.bandY or (CARD_TITLE_H + 2)
    local shown = 0
    for _, line in ipairs(self.summary or {}) do
        if shown >= (self.bandLines or 0) then break end
        text(self, fitText(line, math.max(20, w - PAD * 2)), PAD, y, "textMuted")
        y = y + lh
        shown = shown + 1
    end

    text(self, fitText(tr("Season_ConfigDays"), math.max(20, self.daysEntry.x - PAD)),
        self.labelX or PAD, self.labelY or 0, "text")

    -- the table header, painted by the page (this table is not sortable: the server orders the
    -- seasons newest first, and that order is the record itself)
    local cols = self.list.cols
    local hy = self.headerY or 0
    U.fill(self, PAD, hy, self.list.width, lh, "well", "rect")
    local headers = { tr("Season_Title"), "", tr("Season_StartAt"), tr("Season_EndAt"), "", "" }
    for i, label in ipairs(headers) do
        local col = cols[i]
        if col ~= nil and label ~= "" then
            text(self, fitText(label, col.width), self.list.x + col.x, hy + 1, "textMuted")
        end
    end

    if #(self.rows or {}) == 0 then
        local body
        if self.readError ~= nil then
            body = U.adminErrorText(self.readError)
        elseif self.isPending(COMMAND) or self.state == nil then
            body = tr("Admin_Loading")
        else
            body = tr("Season_Empty")
        end
        text(self, fitText(body, math.max(20, w - PAD * 2)), PAD * 2, (self.listY or 0) + 4, "textFaint")
    end
end

function Page:render() end

-- Nothing behind this page is clickable while it is up: every mouse event that reaches its own
-- surface stops here (the children are asked first, so the list and the chips still work).
function Page:onMouseDown() return true end
function Page:onMouseUp() return true end
function Page:onRightMouseDown() return true end
function Page:onRightMouseUp() return true end
function Page:onMouseMove() return true end
function Page:onMouseWheel() return true end

-- ----- enable / keyboard -----

function Page:updateEnabled()
    local owner = self.owner
    local modal = owner.dialog ~= nil
    local busy = self.isPending(COMMAND)
    -- Both season length and explicit rotation take the native role capability.
    local manage = owner:manageAllowed() and not modal
    local optionBusy = self.isPending("admin.option")
    U.setEntryEditable(self.daysEntry, manage and not optionBusy)
    self.applyButton:setEnable(manage and not optionBusy and self:draftDays() ~= nil)
    self.startButton:setEnable(manage and not busy and self:currentMeta() ~= nil)
end

function Page:keyboardTargets()
    if not self:getIsVisible() then return {} end
    local out = {}
    out[#out + 1] = { kind = "entry", label = tr("Season_ConfigDays"), control = self.daysEntry }
    local chips = {}
    for _, b in ipairs({ self.applyButton, self.startButton }) do
        if b:getIsVisible() then chips[#chips + 1] = b end
    end
    if #chips > 0 then
        out[#out + 1] = { kind = "group", label = tr("Season_Title"), controls = chips }
    end
    out[#out + 1] = { kind = "list", label = tr("Season_History"), control = self.list }
    return out
end

-- Escape: this page holds no popup of its own (the confirmation belongs to the controller and
-- the reader to the session), so the key is handed straight back to the ring and the window.
function Page:onEscape() return false end

-- ----- lifecycle -----

-- Driven by the admin page's own prerender: the read that was owed while the shared slot was
-- busy goes out from here. Nothing polls.
function Page:tick(now)
    if not self:live() then return end
    self:pump()
end

-- Leaving the tab, hiding the window, losing the right, closing the window. The draft survives
-- (it is the host's own unsent number, not server data); a read still in flight keeps the slot
-- it owns and is simply not applied when it comes back.
function Page:onLeave()
    self.sentRead = nil
    pcall(self.daysEntry.unfocus, self.daysEntry)
    D.close(self)
end

function Page:clear()
    D.close(self)
    self.state = nil
    self.metas = {}
    self.rows = {}
    self.readError = nil
    self.updatedAt = nil
    self.sentRead = nil
    self.selectedId = nil
    self.summary, self.sumState, self.sumMinute = nil, nil, nil
    self.draftDirty = nil
    -- the length write this desk was waiting for belonged to the data that is now gone: a
    -- reply for it must not come back and clear a draft typed after the right returned
    self.sentOption = nil
    setEntryText(self.daysEntry, "")
    self.list:setItems({})
    self.list:setSelectedIndex(nil)
end

function Page:dispose()
    D.close(self)
    self.list:setItems({})
    self.state = nil
    self.metas = {}
    self.rows = {}
end

-- ---------- module API ----------

-- owner: the admin controller (ECAdminPanel), which owns the command slot, the confirmation
-- dialog and every permission gate. isPending: that controller's own "is this command in
-- flight" reader.
function P.create(owner, isPending)
    local o = ISPanel:new(0, 0, 600, 400)
    setmetatable(o, Page)
    o.background = false
    o.owner = owner
    o.isPending = isPending
    o.rows = {}
    o.metas = {}
    o:initialise()
    o:instantiate()
    o:setVisible(false)
    return o
end

return P
