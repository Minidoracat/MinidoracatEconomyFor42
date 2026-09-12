-- MinidoracatEconomyFor42 -- the asset reconciliation page (client). Adds exactly one
-- namespace: C.AdminRecovery.
--
--   C.AdminRecovery.create(owner, isPending)   an initialised ISPanel child, NOT added by this
--                                              module: the admin controller adds it and gives it
--                                              the page area of the Recovery sub tab. Methods:
--                                              showAll(), showUser(username), refresh(),
--                                              resize(w, h), tick(now), layout(), updateEnabled(),
--                                              keyboardTargets(), onEscape(), onReply(args, req),
--                                              onTimeout(req), onLeave(), clear(), dispose().
--
-- Why this exists, and why it is a page and no longer an overlay: the first version of this desk
-- could only be reached from a player lookup, so "which accounts on this server are waiting" was
-- a question a host could only answer by typing every name they could think of. It is now a sub
-- tab of its own: the server-wide overview is what opens, the account column says whose record
-- each row is, and the old per-account view is the same page narrowed to one name (with the way
-- back to the whole server on a chip). There is exactly one page -- no second overlay, no alias.
--
-- What the owner (ECAdminPanel) keeps, and why it is not here:
--   owner:sendRecovery(args)       the one way a command leaves this page. The controller owns the
--                                  shared admin.recovery slot, the requestId, the scope / account
--                                  echo check and the timeout: a reply for another request, another
--                                  account or another scope must neither land here nor free the
--                                  slot.
--   owner:openRecoveryDialog(rec)          the reason + confirmation step for one record.
--   owner:openRecoveryBatchDialog(ctx)     the same step for a batch: the count, the accounts, the
--                                  units and the complete per-decision safety warning, over the
--                                  very same mandatory reason box. This page never writes without
--                                  going through one of the two.
--   owner:readAllowed() / writeAllowed() / owner.message / owner.offsetMin / owner.dialog
--
-- What this page deliberately does not do:
--   * no action it was not told about -- actions.approve / remove / restore / discard arrive per
--     record and default to false, so a button the server did not offer does not exist. Nothing is
--     derived from the reason, the quantity, the online state or the save verdict on this side;
--   * no batch back end -- a batch is the very same admin.recovery{action="resolve"} command sent
--     once per record, one in flight at a time, each one carrying that record's own key, revision
--     and account, and each one re-validated by the server. There is no bulk write, no persisted
--     job and no client-side retry: a write that timed out is reported as "result unknown", never
--     sent again on its own;
--   * no automatic choice between operations: the selected set may be mixed, but each batch
--     contains only records permitting the chosen action. Other picks remain untouched;
--   * no server scanner -- "re-check everything" walks the accounts the overview reply listed as
--     online and sends each one the existing recheck. Offline accounts are named as skipped;
--   * no second record window -- a picked row is spelled out in the session's C.DetailWindow.
--
-- The copied block keeps ASCII tags for the opaque identifiers (key / mail / op / tx / epoch /
-- seq / native / revision): those are pasted into a ticket or read back to the server, and a
-- localised tag in front of them is noise. Everything a human judges -- the account, the reason,
-- the source state, the save verdict, the item, the quantities, the time -- is translated.
--
-- Engine references (snapshot 42.20.4-20260826):
--   UIElement.java:1069-1092   children are hit-tested back to front, so a row's own buttons take
--                              the press before the row body underneath them.
--   UIElement.java:1626-1634   children paint between prerender and render: the backdrop this
--                              panel fills in prerender sits under its own list and chips.

require "ISUI/ISPanel"

if not MinidoracatEconomy or not MinidoracatEconomy.Client or not MinidoracatEconomy.Client.UI then
    require "MinidoracatEconomy/ECWidgets"
end
require "MinidoracatEconomy/ECRowActions"
require "MinidoracatEconomy/ECKeyboard"
require "MinidoracatEconomy/ECDetailWindow"

local EC = MinidoracatEconomy
local C = EC.Client
local U = C.UI
local R = C.RowActions
local D = C.DetailWindow

local P = {}
C.AdminRecovery = P

local PAD, T = U.PAD, U.T
local CARD_TITLE_H = U.CARD_TITLE_H
local fontH = U.fontH
local text, textRight, fitText, textWidth = U.text, U.textRight, U.fitText, U.textWidth
local card, stampText, amountText, itemName = U.card, U.stampText, U.amountText, U.itemName
local newEntry, entryText, setEntryText = U.newEntry, U.entryText, U.setEntryText

-- Stable action order; each batch uses only selected records permitting that action.
local DECISIONS = { "approve", "restore", "remove", "discard" }

local ROW_ACTION_GAP = 6
local QUERY_DEBOUNCE_MS = 650   -- the account filter asks once the typing stops, never per key
local QUERY_MAX = 64            -- ECAdmin's own bound for an account name

-- What one queued write ended as. Every bucket is a real outcome and only a bucket that really
-- happened is worded, so a run where everything came through says exactly that instead of also
-- claiming "0 refused" -- and a run that was cut short can never read as a whole one.
local STATES = { "done", "duplicate", "partial", "refused", "unknown", "notsent", "excluded", "offline", "notallowed" }

local function tr(key) return getText(T .. key) end
local function lineH() return fontH.small + 6 end
local function chipH() return math.max(24, fontH.small + 10) end
local function entryH() return math.max(22, fontH.small + 10) end

-- Every value the server may put in one of these fields is shown by its own translated line
-- when we have one, and by the raw token when we do not: a reason, a source state or a save
-- verdict this build has never seen is still readable instead of blank.
local function reasonText(reason)
    local raw = tostring(reason or "unknown")
    return getTextOrNull(T .. "Admin_Rec_Reason_" .. raw) or raw
end

local function sourceText(state)
    local raw = tostring(state or "unknown")
    return getTextOrNull(T .. "Admin_Rec_Source_" .. raw) or raw
end

local function verdictText(verdict)
    local raw = tostring(verdict or "unknown")
    return getTextOrNull(T .. "Admin_Rec_Verdict_" .. raw) or raw
end

local function decisionLabel(id)
    return getTextOrNull(T .. "Admin_Rec_Do_" .. tostring(id)) or tostring(id)
end

local function stateLabel(state)
    return getTextOrNull(T .. "Admin_Rec_State_" .. tostring(state)) or tostring(state)
end

-- Where a record's economic content comes from. "journal" is the server's own authoritative
-- evidence for that operation; "player_claim" is the opposite -- there is no evidence, only what
-- the player's save says about itself. Every summary, row and confirmation states this, because a
-- decision taken on the second kind is a human accepting unproven data and must never be worded
-- as a reconciliation the server carried out. nil means the field does not apply to this record.
local function proofText(source)
    if type(source) ~= "string" or source == "" then return nil end
    return getTextOrNull(T .. "Admin_Rec_Proof_" .. source) or source
end

-- Why a record permits nothing, in the server's own words. `rec.actions` is the only truth about
-- what may be pressed -- this is only the explanation beside it, so nothing here is ever derived
-- from the reason string: the judgement that produced a reason and the verdict on whether the
-- record can be acted on are two different questions, and a mismatch (for one) can be either.
local function blockedText(code)
    local raw = tostring(code or "")
    if raw == "" then return nil end
    return getTextOrNull(T .. "Admin_Rec_Blocked_" .. raw)
        or getTextOrNull(T .. "Admin_Rec_Reason_" .. raw) or raw
end

-- The one diagnostic a malformed record can offer: which part of the evidence is wrong. The
-- server's values are internal identifiers, not prose -- "chain.order" (the server seq for one
-- operation went backwards), "chain.duplicate" (one epoch and seq carrying two different
-- contents) or a replay field name such as "replay.origins" (that single line's shape is wrong).
-- The first two are faults in the chain itself, the last is one broken line, and an operator
-- looks in different places for them -- which is the whole reason this is shown.
--
-- Only the two fixed values get a sentence of their own (dots become underscores, because a
-- translation key is an identifier); anything else prints the identifier verbatim, because a
-- field name this build has never seen is still exactly what an operator needs to grep for. It
-- is never blank.
local function proofFieldText(value)
    local raw = tostring(value or "")
    if raw == "" then return nil end
    local key = string.gsub(raw, "%.", "_")
    return getTextOrNull(T .. "Admin_Rec_Field_" .. key) or raw
end

-- The states in which the evidence simply has not been read: still loading, unreadable, present
-- but malformed, the journal module absent, or the server declining to judge without proof. These
-- are the only ones where asking again can change the answer, so they are the only ones that get
-- the "re-check" wording. Everything else that blocks a record is a settled verdict -- notably
-- legacy_outcome_unverified, where the server DOES hold a record and that record says the
-- operation cannot be rebuilt -- and must never be worded as "still loading" or offered a manual
-- exit.
local RECHECK_BLOCKED = { journal_pending = true, journal_unreadable = true,
    journal_malformed = true, journal_unavailable = true, proof_required = true }

local function recheckable(code)
    return RECHECK_BLOCKED[tostring(code or "")] == true
end

local function blockedRecheck(rec)
    if rec.pending == true then return true end
    -- A record found on another account's line is re-check only as well: it permits no decision
    -- at all, and asking again is the one thing left. It is not offered the manual exit -- that
    -- is disproof, not absence (see unprovenText).
    if rec.foreign == true then return true end
    return recheckable(rec.blocked)
end

-- A field the reply may simply not carry. nil and "" are the same thing here: the line is left
-- out rather than printed as a dash that could be read as a real value.
local function str(value)
    if type(value) == "string" and value ~= "" then return value end
    if type(value) == "number" then return tostring(value) end
    return nil
end

local function intOf(value)
    local n = tonumber(value)
    if n == nil or n ~= n then return nil end
    return math.floor(n)
end

-- One row's identity across pages and reads: the account it belongs to and the record key inside
-- it. A selection outlives a page switch, a filter change and a refresh, so it can never be an
-- index -- and it is never the key alone, because two accounts may hold the very same legacy key.
local function rowId(username, key)
    local name = tostring(username)
    return tostring(#name) .. ":" .. name .. tostring(key)
end

-- ---------- one record row ----------
-- Two lines plus the record's own buttons on the right: the account, the judgement and the item
-- on top, the evidence trail (source state / save verdict / when / key) under it. The rightmost
-- chip is always the selection toggle, so it sits in the same column on every row. Every string
-- is built once per rebuild (Page:recordRow), never per frame.

local RecoveryCell = ISPanel:derive("MinidoracatEconomyRecoveryCell")

function RecoveryCell:render()
    local e = self.entry
    if e == nil then return end
    local list = self.list
    local lit = U.rowBackground(self)
    -- A selected row is lit the same way and carries a bar down its left edge, so the set stays
    -- readable while the highlight is on whichever row the arrows last walked to. The set is
    -- keyed by account + record and read live off the list, so showing a pick needs no rebind.
    local picked = list.ecPicked
    local marked = picked ~= nil and picked[e.id] ~= nil
    if marked then
        if not lit then U.fill(self, 0, 0, self.width, self.height, "selected", "rect") end
        U.fill(self, 0, 0, 3, self.height, "accent", "rect")
    end
    local hot = lit or marked
    text(self, e.line1, PAD, e.line1Y, e.warn and "warn" or "text")
    text(self, e.line2, PAD, e.line2Y, hot and "text" or "textFaint")
    textRight(self, e.qtyText, e.qtyRight, e.line1Y, "accent")
    R.begin(self)
    if e.pick ~= nil then
        -- selecting is a read: a read-only host may count what is waiting, and only the decision
        -- buttons below are gated on the write right
        R.put(self, "pick", marked and e.unpickLabel or e.pickLabel,
            e.pick.x, e.pick.y, e.pick.w, e.pick.h, list.picksDisabled ~= true)
    end
    -- the write gate is the list's (permission, a command in flight, a batch running, the modal
    -- dialog); the row's own `actions` flags decide which decisions exist at all
    local write = list.optionsDisabled ~= true
    for _, a in ipairs(e.actions) do
        R.put(self, a.id, a.label, a.x, a.y, a.w, a.h, write)
    end
    R.finish(self)
end

-- ---------- the page ----------

local Page = ISPanel:derive("MinidoracatEconomyAdminRecovery")

-- C.Keyboard.invalidate only accepts the root window; this page hangs under the admin
-- controller, which hangs under it.
local function keyboardRoot(page)
    local admin = page ~= nil and page.owner or nil
    return admin ~= nil and admin.owner or nil
end

local function invalidateKeyboard(page)
    if C.Keyboard and C.Keyboard.invalidate then pcall(C.Keyboard.invalidate, keyboardRoot(page)) end
end

-- How wide a chip gets. Its whole label when that fits, and at most a third of the strip when it
-- does not: at a 45 px UI font one English label is wider than the whole strip, and a chip per
-- row would push the last controls off the bottom of the page. A cut label keeps its full text in
-- the tooltip the skinned Button offers for exactly this case (U.setButtonTitle / autoTooltip),
-- which is the same trade every other table header here makes.
local function chipNeed(button, limit, columns)
    local share = math.max(60, math.floor((limit - ROW_ACTION_GAP * (columns - 1)) / columns))
    return math.max(40, math.min(limit, math.min(textWidth(button.fullTitle) + 24, share)))
end

-- The foot strip. One row while everything fits, wrapping onto further rows when a large UI font
-- or a narrow window means it does not -- never clipped, never overlapping.
local function packHeight(chips, inner, h, columns)
    local x, rows = 0, 1
    for _, b in ipairs(chips) do
        local need = chipNeed(b, inner, columns)
        if x > 0 and x + need > inner then
            rows = rows + 1
            x = 0
        end
        x = x + need + ROW_ACTION_GAP
    end
    return rows * h + (rows - 1) * 4
end

local function packChips(chips, left, top, inner, h, columns)
    local x, y = left, top
    for _, b in ipairs(chips) do
        local need = chipNeed(b, inner, columns)
        if x > left and (x - left) + need > inner then
            x = left
            y = y + h + 4
        end
        b:setWidth(need)
        b:setHeight(h)
        b:setX(x)
        b:setY(y)
        U.setButtonTitle(b, b.fullTitle)
        x = x + need + ROW_ACTION_GAP
    end
end

function Page:createChildren()
    self.list = U.newTable(RecoveryCell, lineH() * 2 + 12)
    -- Plain activation reads; Ctrl toggles a pick and Shift adds the visible range.
    self.list.onSelect = function(_, item, index) self:onRow(item, index) end
    self.list.onRowAction = function(_, item, id) self:onRowAction(item, id) end
    self.list.ecPicked = self.picked
    self:addChild(self.list)

    -- the account filter: one read per pause in the typing (or on Enter), never one per key
    self.searchEntry = newEntry(200, entryH(), { maxLen = QUERY_MAX, clear = true,
        placeholder = tr("Admin_Rec_SearchHint") })
    self.searchEntry.target = self
    self.searchEntry.onTextChangeFunction = Page.onSearchTyped
    self.searchEntry.onCommandEntered = function() self:applyQuery() end
    self:addChild(self.searchEntry)

    local function chip(label, handler, style)
        local b = U.Button.create(0, 0, 100, chipH(), label, self, handler, style or "chip")
        self:addChild(b)
        return b
    end

    self.pickPageButton = chip(tr("Admin_Rec_PickPage"), Page.onPickPage)
    self.clearPicksButton = chip(tr("Admin_Rec_ClearPicks"), Page.onClearPicks)
    self.batchButtons = {}
    for _, id in ipairs(DECISIONS) do
        local b = chip(decisionLabel(id), Page.onBatch, "primary")
        b.internal = id
        self.batchButtons[#self.batchButtons + 1] = b
    end
    self.reportButton = chip(tr("Admin_Rec_BatchReport"), Page.onReport)
    self.statusButton = chip(tr("Admin_Rec_StatusDetails"), Page.onStatus)
    self.stopButton = chip(tr("Admin_Rec_Stop"), Page.onStop)
    self.recheckAllButton = chip(tr("Admin_Rec_RecheckAll"), Page.onRecheckAll, "primary")
    self.recheckButton = chip(tr("Admin_Rec_Recheck"), Page.onRecheck, "primary")
    self.backButton = chip(tr("Admin_Rec_Back"), Page.onBack)
    self.prevButton = chip(tr("Market_Prev"), Page.onPage)
    self.prevButton.internal = -1
    self.nextButton = chip(tr("Market_Next"), Page.onPage)
    self.nextButton.internal = 1
    self:layout()
end

-- ----- which question the page is asking -----

-- The whole server. The page opens here and every account view can come back to it: the counter
-- on a player card is a summary of one lookup, this is the list of everything that is waiting.
function Page:showAll()
    if self.scope ~= "all" then
        D.close(self)
        self.list:setSelectedIndex(nil)
        self.selected = nil
        self.snapshot = nil
        self.readError = nil
        self.rows = {}
        self.list:setItems({})
    end
    self.scope = "all"
    self.username = nil
    self.page = 1
    self.pickAnchor = nil
    self.sentScope, self.sentPage, self.sentQuery = nil, nil, nil
    self:pump()
    self:layout()
    invalidateKeyboard(self)
end

-- One account, which is what the player page's chip asks for. Same page, same rows, same
-- decisions -- only narrowed, and the way back is a chip in the foot strip.
function Page:showUser(username)
    if type(username) ~= "string" or username == "" then return false end
    if self.scope ~= "user" or self.username ~= username then
        D.close(self)
        self.list:setSelectedIndex(nil)
        self.selected = nil
        self.snapshot = nil
        self.readError = nil
        self.rows = {}
        self.list:setItems({})
    end
    self.scope = "user"
    self.username = username
    self.page = 1
    self.pickAnchor = nil
    self.sentScope, self.sentPage = nil, nil
    self:pump()
    self:layout()
    invalidateKeyboard(self)
    return true
end

-- The refresh chip, and the tab being entered: ask the question again from the top.
function Page:refresh()
    self.sentScope, self.sentPage, self.sentQuery = nil, nil, nil
    self:pump()
end

function Page:live()
    return self:getIsVisible() and self.owner:readAllowed()
end

-- ----- reads -----

-- The read the page is owed. The shared command slot may be busy (another page's read, a queued
-- write, the server's own 500 ms window), so the wish is recorded and tick() asks again -- a page
-- chip is never silently dropped, and never turns into two commands either.
function Page:pump()
    if not self:live() then return end
    if self.job ~= nil then return end     -- a running queue owns the slot until it is done
    if self.owner.dialog ~= nil then return end
    if self.isPending("admin.recovery") then return end
    if self.scope == "all" then
        if self.sentScope == "all" and self.sentPage == self.page and self.sentQuery == self.query then return end
        if self.owner:sendRecovery({ action = "overview", page = self.page, query = self.query }) then
            self.sentScope, self.sentPage, self.sentQuery = "all", self.page, self.query
        end
        return
    end
    if self.username == nil then return end
    if self.sentScope == self.username and self.sentPage == self.page then return end
    if self.owner:sendRecovery({ action = "list", username = self.username, page = self.page }) then
        self.sentScope, self.sentPage = self.username, self.page
    end
end

function Page:onSearchTyped()
    self.queryAt = EC.now()
end

-- Trimmed, folded and bounded exactly as the server does it, so the value the page remembers is
-- the value the reply echoes and one filter can never turn into an endless pair of reads.
local function normalQuery(raw)
    local value = string.match(tostring(raw or ""), "^%s*(.-)%s*$")
    if value == "" then return nil end
    if string.find(value, "%c") then return nil end
    if #value > QUERY_MAX then value = string.sub(value, 1, QUERY_MAX) end
    return string.lower(value)
end

function Page:applyQuery()
    self.queryAt = nil
    if self.scope ~= "all" then return end
    local value = normalQuery(entryText(self.searchEntry))
    if value == self.query then return end
    self.query = value
    self.page = 1
    self.pickAnchor = nil
    -- a new question: the row that was being read belonged to the old answer. The selection is
    -- deliberately kept -- it is what "selected across pages" means, and the confirmation says
    -- how many records and how many accounts it really covers.
    D.close(self)
    self.selected = nil
    self.list:setSelectedIndex(nil)
    self:pump()
    self:updateEnabled()
end

function Page:onRecheck()
    if self.scope ~= "user" then return end
    if not self:guardWrite() then return end
    if not self:online() then
        self.owner.message = { text = U.adminErrorText("player_offline"), error = true }
        return
    end
    self.owner.message = nil
    -- the recheck re-runs the server's own reconcile and answers with the fresh list: the page
    -- the host is on travels with it, so the answer lands where they are looking
    if self.owner:sendRecovery({ action = "recheck", username = self.username, page = self.page }) then
        self.sentScope, self.sentPage = self.username, self.page
    else
        self.owner.message = { text = tr("Admin_Throttled"), error = true }
    end
end

function Page:onPage(button)
    if self.owner.dialog ~= nil or self.job ~= nil then return end
    local pages = self:pageCount()
    local target = math.max(1, math.min(pages, (self.page or 1) + (button.internal or 0)))
    if target == self.page then return end
    self.owner.message = nil
    -- a page switch is a new question: the row that was picked for reading belonged to the old
    -- one. The selection set is not a reading pick and stays exactly as it is.
    D.close(self)
    self.selected = nil
    self.list:setSelectedIndex(nil)
    self.page = target
    self.pickAnchor = nil
    self:pump()
    self:updateEnabled()
end

function Page:onBack()
    if self.scope == "all" then return end
    self.owner.message = nil
    self:showAll()
end

-- Escape: the queue answers first. Nothing else on this page is a popup, so the key is handed
-- back to the ring (and to the window) when there is no queue to stop.
function Page:onEscape()
    if self.job ~= nil then
        self:stopJob("stopped")
        return true
    end
    return false
end

-- ----- snapshot -----

function Page:online()
    local snap = self.snapshot
    return snap ~= nil and snap.online == true
end

function Page:pageCount()
    local snap = self.snapshot
    return math.max(1, intOf(snap and snap.pages) or 1)
end

function Page:summary()
    local snap = self.snapshot
    if snap == nil then return nil end
    return type(snap.summary) == "table" and snap.summary or nil
end

-- A reply the controller has already matched to the request that was open (requestId, plus the
-- account for an account-scoped command or scope="all" for the overview), so what arrives here is
-- this page's own answer. `req` is that request, which is how a read, a single decision and a
-- queued one are told apart without trusting the reply to say.
function Page:onReply(args, req)
    local job = self.job
    local sent = job ~= nil and job.sent or nil
    if sent ~= nil and req.requestId == sent.requestId then
        self:onJobReply(args, req, job)
        return
    end
    -- a page nobody is looking at applies nothing: whatever it had in flight was already
    -- accounted for when it was left (onLeave), and this answer only freed the command slot
    if not self:getIsVisible() then return end
    local action = req.action or "list"
    if action == "resolve" then return self:onResolveReply(args, req) end
    if action == "overview" then
        if args.scope ~= "all" or self.scope ~= "all" or (req.query or "") ~= (self.query or "")
            or (req.page or 1) ~= self.page then return end
    elseif self.scope ~= "user" or self.username ~= req.username or (req.page or 1) ~= self.page then
        return
    end
    if args.ok == false then
        -- a refusal is a message and nothing else: the snapshot that is up stays up, so a busy or
        -- unreadable server never reads as "nothing is waiting". And it is not asked for again on
        -- its own: a server that refused once is reported once, not hammered. The recheck action,
        -- the page chips and the refresh chip are the way back.
        self.owner.message = { text = U.adminErrorText(args.error), error = true }
        self.readError = args.error
        self:updateEnabled()
        return
    end
    self:adopt(args)
    if action == "recheck" then
        self.owner.message = { text = getText(T .. "Admin_Rec_Rechecked",
            tostring(intOf(args.total) or #self.rows)) }
    end
end

-- The outcome of one decision taken on its own. The dialog always closes: the server has just
-- recomputed this record's evidence and its revision, so the box that was open was asking about a
-- state that no longer exists. A retry re-opens it over the refreshed row, which is exactly what
-- keeps a stale revision from being re-sent.
function Page:onResolveReply(args, req)
    local dialog = self.owner.dialog
    if dialog and dialog.mode == "recovery" and dialog.recovery
        and req and dialog.recovery.key == req.key then self.owner:closeDialog() end
    if self.scope == "user" and self.username == req.username and type(args.records) == "table" then
        self:adopt(args)
    else
        -- the overview asks a different question, so one account's list is never adopted as the
        -- answer to it: the server-wide read is simply owed again
        self.sentScope = nil
    end
    if args.ok == false then
        -- A press the newest judgement no longer permits is answered with that record's own
        -- blocked code, so the message says which of the two it was: evidence still being read
        -- (worth asking again) or a settled verdict that nothing can rebuild this. Anything the
        -- blocked namespace does not know -- a stale revision, a refusal to act on unproven data
        -- without the acceptance -- is an ordinary error code and reads as one.
        local code = str(args.blocked) or str(args.error)
        local body = (getTextOrNull(T .. "Admin_Rec_Blocked_" .. tostring(code))
            or getTextOrNull(T .. "Admin_Rec_Reason_" .. tostring(code)))
        if body == nil then
            body = U.adminErrorText(args.error)
        elseif recheckable(code) or args.pending == true then
            body = body .. "  " .. tr("Admin_Rec_JournalRecheck")
        end
        self.owner.message = { text = body, error = true }
        self:updateEnabled()
        return
    end
    if req.username ~= nil and req.key ~= nil then
        self:unpick(rowId(req.username, req.key))
    end
    local decision = req and req.decision or nil
    local body
    if args.duplicate == true then
        body = tr("Admin_Rec_Duplicate")
    else
        body = getTextOrNull(T .. "Admin_Rec_Ok_" .. tostring(decision)) or tr("Admin_Rec_Done")
    end
    local token = str(args.approvalToken)
    if token then body = body .. "  " .. getText(T .. "Admin_Rec_Token", token) end
    self.owner.message = { text = body }
    self:updateEnabled()
end

-- Whatever the reply carried becomes the snapshot: the page, the totals, the status, the accounts
-- and the records, exactly as the server stated them. Nothing is merged with what was on screen --
-- the server recomputes every record's permitted decisions and its revision on each read, and this
-- side never keeps a decision the newest read no longer offers.
function Page:adopt(args)
    self.snapshot = args
    self.readError = nil
    self.page = math.max(1, intOf(args.page) or 1)
    self.sentPage = self.page
    self.sentScope = (self.scope == "all") and "all" or self.username
    self.sentQuery = self.query
    self.updatedAt = EC.now()
    self:dropStalePicks(args)
    self:rebuild()
    self:layout()
end

-- A record whose revision moved since it was selected is no longer the record the host judged:
-- its authorisation is dropped rather than quietly re-pointed at the new evidence, and the band
-- says how many went. The server refuses a stale revision as well; this is so a host is told
-- before they press, not after.
function Page:dropStalePicks(args)
    if self.pickedCount == 0 then return end
    local records = type(args.records) == "table" and args.records or nil
    if records == nil then return end
    local dropped = 0
    for _, rec in ipairs(records) do
        local key, user = str(rec.key), str(rec.username) or self.username
        if key ~= nil and user ~= nil then
            local entry = self.picked[rowId(user, key)]
            if entry ~= nil and entry.revision ~= str(rec.revision) then
                self:unpick(entry.id)
                dropped = dropped + 1
            end
        end
    end
    if dropped > 0 then self.staleDropped = (self.staleDropped or 0) + dropped end
end

function Page:onTimeout(req)
    local job = self.job
    local sent = job ~= nil and job.sent or nil
    if sent ~= nil and (req == nil or req.requestId == sent.requestId) then
        -- a write whose answer never came: this one record's outcome is genuinely unknown, so the
        -- queue stops there. It is never sent again on its own.
        self:stopJob("timeout")
        return
    end
    -- the read is never coming: the page is owed its question again, and a chip (or the tab's own
    -- refresh) is what asks
    self.sentScope = nil
    self:updateEnabled()
end

function Page:clear()
    self:stopJob(nil, true)
    D.close(self)
    self.snapshot = nil
    self.readError = nil
    self.rows = {}
    self.selected = nil
    self.statusText = nil
    self.updatedAt = nil
    self.sentScope, self.sentPage, self.sentQuery = nil, nil, nil
    self.staleDropped = nil
    self.batchReport = nil
    self:clearPicks()
    self.list:setItems({})
    self.list:setSelectedIndex(nil)
end

-- Leaving the tab, hiding the window, losing the right, closing the window: whatever has not been
-- sent yet is dropped, and a write that is in flight is reported as unknown rather than silently
-- abandoned or automatically resumed.
function Page:onLeave()
    if self.job ~= nil then self:stopJob("left") end
    self.queryAt = nil
    self.pickAnchor = nil
    pcall(function() self.searchEntry:unfocus() end)
    D.close(self)
end

-- ----- the selection -----

function Page:pick(row)
    if row == nil or row.key == nil or row.revision == nil or row.username == nil then return false end
    if self.picked[row.id] ~= nil then return false end
    -- what was authorised, captured as it was read: the account, the record, the revision the
    -- server stated and the decisions it offered. A later read never replaces these silently --
    -- it either matches, or the pick is dropped (dropStalePicks).
    local actions = {}
    for _, id in ipairs(DECISIONS) do
        actions[id] = row.record ~= nil and type(row.record.actions) == "table"
            and row.record.actions[id] == true or false
    end
    -- Whether this record's content was ever proven travels with the authorisation: accepting
    -- unproven data is a per-record act, so pickedFor never carries such a pick into a batch and
    -- the confirmation counts it as excluded. `foreign` travels for the same reason and is even
    -- stricter -- it disproves this account's claim. The blocked code rides along only to explain
    -- the exclusion; what may be pressed is the action flags above.
    self.picked[row.id] = { id = row.id, username = row.username, key = row.key,
        revision = row.revision, actions = actions, qty = row.qty, presentQty = row.presentQty,
        headText = row.headText, unproven = row.unproven == true,
        foreign = row.foreign == true, blocked = row.blocked }
    self.pickOrder[#self.pickOrder + 1] = row.id
    self.pickedCount = self.pickedCount + 1
    self.actionCounts = nil
    return true
end

function Page:unpick(id)
    if id == nil or self.picked[id] == nil then return false end
    self.picked[id] = nil
    self.pickedCount = math.max(0, self.pickedCount - 1)
    self.actionCounts = nil
    -- compacted in place: the array is the order the host built, and it is walked far more often
    -- than it is edited
    local order = self.pickOrder
    local kept = 0
    for i = 1, #order do
        if order[i] ~= id then
            kept = kept + 1
            order[kept] = order[i]
        end
    end
    for i = #order, kept + 1, -1 do order[i] = nil end
    return true
end

-- The table itself is never swapped: the list paints the marks straight off it.
function Page:clearPicks()
    for id in pairs(self.picked) do self.picked[id] = nil end
    for i = #self.pickOrder, 1, -1 do self.pickOrder[i] = nil end
    self.pickedCount = 0
    self.staleDropped = nil
    self.actionCounts, self.pickAnchor = nil, nil
end

function Page:onClearPicks()
    if self.job ~= nil or self.pickedCount == 0 then return end
    self.owner.message = nil
    self:clearPicks()
    self:layout()
end

-- Everything the page is showing right now. The set is cross-page on purpose, so this adds and
-- never replaces: a host builds one set out of several pages and one filter after another.
function Page:onPickPage()
    if self.job ~= nil or self.owner.dialog ~= nil then return end
    if not self.owner:readAllowed() then return end
    self.owner.message = nil
    for _, row in ipairs(self.rows or {}) do self:pick(row) end
    self:layout()
end

-- An anchor is a row identity in the current page, never an index into an older query.
function Page:selectRow(item, index, range)
    if not self.owner:readAllowed() or self.owner.dialog ~= nil or self.job ~= nil then return end
    if item == nil or self.rows[index] ~= item then return end
    local anchor
    if range then
        for i, row in ipairs(self.rows) do
            if row.id == self.pickAnchor then anchor = i; break end
        end
    end
    local failed = false
    if anchor then
        for i = math.min(anchor, index), math.max(anchor, index) do
            local row = self.rows[i]
            if self.picked[row.id] == nil and not self:pick(row) then failed = true end
        end
    else
        if not range and self.picked[item.id] ~= nil then self:unpick(item.id)
        elseif self.picked[item.id] == nil and not self:pick(item) then failed = true end
        self.pickAnchor = item.id
    end
    self.owner.message = failed and { text = U.adminErrorText("recovery_stale"), error = true } or nil
    self:layout()
end

-- The selection in the order it was built, with the accounts and the units it really covers. Only
-- the records that still allow `decision` are carried: a set the server permits different things
-- for is never dispatched as several different operations behind one press.
--
-- A record that was never proven is left out whatever it permits: accepting unproven data is one
-- deliberate act per record and must not ride along inside a set. A `foreign` record is excluded
-- on its own account -- it disproves this account's claim, so it must not be reachable through a
-- set either. A record the server blocked needs no filter of its own: its four action flags are
-- all false, so the test below already excludes it, and the blocked code is kept on the pick only
-- to explain that exclusion.
local function batchable(entry)
    return entry ~= nil and entry.unproven ~= true and entry.foreign ~= true
end

function Page:pickedFor(decision)
    local items, seen, accounts, units = {}, {}, 0, 0
    local known = true
    for _, id in ipairs(self.pickOrder) do
        local entry = self.picked[id]
        if batchable(entry) and (decision == nil or entry.actions[decision] == true) then
            items[#items + 1] = entry
            local qty = entry.qty
            if decision == "remove" or decision == "approve" then qty = entry.presentQty end
            if qty == nil then known = false else units = units + qty end
            if seen[entry.username] == nil then
                seen[entry.username] = true
                accounts = accounts + 1
            end
        end
    end
    return items, accounts, known and units or nil
end

-- Recomputed only when the frozen selection changes, not on every render or key press.
function Page:decisionCounts()
    if self.actionCounts ~= nil then return self.actionCounts end
    local counts = {}
    for _, entry in pairs(self.picked) do
        -- the same filter pickedFor applies, so a batch chip never offers a count it would then
        -- refuse to send
        if batchable(entry) then
            for _, id in ipairs(DECISIONS) do
                if entry.actions[id] == true then counts[id] = (counts[id] or 0) + 1 end
            end
        end
    end
    self.actionCounts = counts
    return counts
end

-- ----- writes -----

function Page:guardWrite()
    if self.owner.dialog ~= nil then return false end
    if self.job ~= nil then
        self.owner.message = { text = tr("Admin_Rec_JobBusy"), error = true }
        return false
    end
    if not self.owner:writeAllowed() then
        self.owner.message = { text = U.adminErrorText("forbidden"), error = true }
        return false
    end
    return true
end

-- A decision button inside a row. Nothing is sent here: the controller's write dialog is opened
-- over the record, and the reason it demands plus its explicit confirmation are what finally
-- sends the command. The row's own flag is re-read at the click, so a button left over from an
-- older snapshot cannot arm a decision the newest read does not offer.
function Page:onRowAction(item, id)
    if item == nil then return end
    if id == "pick" then
        local _, shift = C.Keyboard.modifiers()
        self:selectRow(item, self.list:getSelectedIndex(), shift)
        return
    end
    if not self:guardWrite() then return end
    if item.online ~= true then
        self.owner.message = { text = U.adminErrorText("player_offline"), error = true }
        return
    end
    local rec = item.record
    local flags = type(rec) == "table" and type(rec.actions) == "table" and rec.actions or nil
    -- `rec.actions` decides; `rec.blocked` only explains. A record the newest read permits
    -- nothing for says why in the server's own code -- evidence still being read (ask again) or
    -- a record that refuses a rebuild (nothing will change that) -- instead of the generic
    -- "not actionable" that used to cover both.
    -- A record that turned up on another account's line is refused outright, before the flags
    -- are even consulted: acting on it would build this account a receipt out of somebody
    -- else's operation. The server says restorable=false for it; this is the second lock.
    if item.foreign then
        self.owner.message = { text = tr("Admin_Rec_Foreign"), error = true }
        return
    end
    if flags == nil or flags[id] ~= true then
        local body = blockedText(item.blocked)
        if body == nil then
            body = U.adminErrorText("recovery_not_actionable")
        elseif item.blockedRecheck then
            body = body .. "  " .. tr("Admin_Rec_JournalRecheck")
        end
        self.owner.message = { text = body, error = true }
        return
    end
    if item.key == nil or item.revision == nil or item.username == nil then
        self.owner.message = { text = U.adminErrorText("recovery_stale"), error = true }
        return
    end
    self.owner.message = nil
    self.owner:openRecoveryDialog({
        key = item.key, revision = item.revision, decision = id, username = item.username,
        headText = item.headText, detailText = item.detailText,
        -- the confirmation needs both: the flag that adds the acceptance gate and puts
        -- acceptUnproven on the command, and the full disclosure it shows above it -- built for
        -- the decision being taken, because a restore generates something and a discard does not.
        -- `foreign` can never arm the gate: it is disproof of this account's claim, so there is
        -- nothing to accept (the refusal above already returned, and this is belt and braces).
        unproven = item.unproven and not item.foreign,
        unprovenText = self:unprovenText(rec, id),
    })
end

-- The batch strip. Same shape as a single decision: the confirmation names the count, the
-- accounts and the units, carries the complete per-decision warning and demands the one
-- mandatory reason -- and only then does the queue start.
function Page:onBatch(button)
    local decision = button.internal
    if not self:guardWrite() then return end
    local items, accounts, units = self:pickedFor(decision)
    if #items == 0 then
        self.owner.message = { text = tr("Admin_Rec_NoApplicable"), error = true }
        return
    end
    self.owner.message = nil
    self.owner:openRecoveryBatchDialog({ decision = decision, items = items,
        count = #items, accounts = accounts, units = units,
        selectedCount = self.pickedCount, excludedCount = self.pickedCount - #items })
end

-- Started by the controller once the reason and the confirmation are in. The queue holds its own
-- copy of what was confirmed: a refresh afterwards may drop those records from the selection, and
-- what is being written stays exactly what the host agreed to (and is re-checked per record at
-- send time against the authorisation that was captured).
function Page:startBatch(decision, note, items, excludedCount)
    if self.job ~= nil or type(items) ~= "table" or #items == 0 then return false end
    self.batchReport = nil
    self.job = { kind = "batch", decision = decision, note = note, items = items,
        i = 1, total = #items, counts = { excluded = excludedCount }, lines = {}, sent = nil }
    self.owner.message = nil
    self:layout()
    return true
end

-- "Re-check everything": the accounts the overview reply listed, each one given the very same
-- recheck a single account gets. Offline accounts are named as skipped instead of being sent a
-- command that cannot be proven against an inventory that is not loaded. No scanner, no job, no
-- ledger, and nothing here re-issues anything.
function Page:onRecheckAll()
    if not self:guardWrite() then return end
    local snap = self.snapshot
    local accounts = (snap ~= nil and type(snap.accounts) == "table") and snap.accounts or nil
    if accounts == nil or #accounts == 0 then
        self.owner.message = { text = tr("Admin_Rec_EmptyAll"), error = true }
        return
    end
    local items = {}
    for _, a in ipairs(accounts) do
        local user = str(a.username)
        if user ~= nil then
            items[#items + 1] = { id = user, username = user, key = "-", online = a.online == true }
        end
    end
    if #items == 0 then
        self.owner.message = { text = tr("Admin_Rec_EmptyAll"), error = true }
        return
    end
    self.batchReport = nil
    self.job = { kind = "sweep", items = items, i = 1, total = #items,
        counts = {}, lines = {}, sent = nil }
    self.owner.message = nil
    self:layout()
end

function Page:onStop()
    if self.job == nil then return end
    self:stopJob("stopped")
end

function Page:recordResult(item, state, code, result)
    local job = self.job
    if job == nil or item == nil then return end
    job.counts[state] = (job.counts[state] or 0) + 1
    local line = tostring(item.username) .. "  " .. tostring(item.key or "-") .. "  " .. stateLabel(state)
    if code ~= nil then line = line .. "  (" .. tostring(code) .. ")" end
    if type(result) == "table" then
        for _, key in ipairs({ "removed", "stuck", "refused", "qty" }) do
            if type(result[key]) == "number" then
                line = line .. "  " .. getText(T .. "Admin_Rec_Result_" .. key, tostring(result[key]))
            end
        end
        if str(result.approvalToken) then line = line .. "  " .. getText(T .. "Admin_Rec_Token", result.approvalToken) end
        if str(result.mailId) then line = line .. "  mail " .. result.mailId end
    end
    job.lines[#job.lines + 1] = line
end

-- One queued write at a time, paced by the controller's own 650 ms cooldown (send() holds a
-- request that lands inside the server's 500 ms window and lets it out afterwards, so nothing
-- here needs a clock of its own). Every record is re-checked against the authorisation that was
-- captured for it, and the write right is re-read before each one leaves.
function Page:pumpJob()
    local job = self.job
    if job == nil then return end
    if not self.owner:writeAllowed() then return self:stopJob("forbidden") end
    if job.sent ~= nil or self.isPending("admin.recovery") then return end
    while job.i <= #job.items do
        local item = job.items[job.i]
        if job.kind == "sweep" and item.online ~= true then
            self:recordResult(item, "offline")
            job.i = job.i + 1
        elseif job.kind == "batch" and item.actions[job.decision] ~= true then
            self:recordResult(item, "notallowed")
            job.i = job.i + 1
        else
            break
        end
    end
    if job.i > #job.items then return self:finishJob(nil) end
    local item = job.items[job.i]
    local args
    if job.kind == "batch" then
        args = { action = "resolve", username = item.username, key = item.key,
            revision = item.revision, decision = job.decision, note = job.note }
    else
        args = { action = "recheck", username = item.username, page = 1 }
    end
    -- the write right was just re-read, so a refusal here is the transport saying no: the queue
    -- stops where it is rather than skipping a record and carrying on
    if not self.owner:sendRecovery(args) then return self:stopJob("stopped") end
    job.sent = { requestId = self.owner.recRequestId, index = job.i }
end

function Page:onJobReply(args, req, job)
    local item = job.items[job.sent.index]
    job.sent = nil
    local stop = false
    if args.ok == false then
        local partial = (tonumber(args.removed) or 0) > 0 or str(args.approvalToken) ~= nil
        self:recordResult(item, partial and "partial" or "refused", args.error, args)
        -- a single refusal is that record's own outcome and the queue goes on; losing the right
        -- is not, because every remaining write would be refused for the same reason
        stop = args.error == "forbidden"
    elseif args.duplicate == true then
        self:recordResult(item, "duplicate", nil, args)
    else
        self:recordResult(item, "done", nil, args)
    end
    if job.kind == "batch" and args.ok ~= false then self:unpick(item.id) end
    job.i = job.i + 1
    if stop then return self:stopJob("forbidden") end
    if job.i > #job.items then return self:finishJob(nil) end
    self:layout()
end

-- Everything that has not left the client is dropped, and a write that is in flight is recorded as
-- unknown: it may well have completed on the server, so it is neither claimed as done nor sent
-- again. `silent` is the data wipe, which has no one left to tell.
function Page:stopJob(reason, silent)
    local job = self.job
    if job == nil then return end
    local from = job.i
    if job.sent ~= nil then
        local cancelled = self.owner:cancelDeferredRecovery(job.sent.requestId)
        self:recordResult(job.items[job.sent.index], cancelled and "notsent" or "unknown")
        from = job.sent.index + 1
        job.sent = nil
    end
    for k = from, #job.items do
        self:recordResult(job.items[k], "notsent")
    end
    job.i = #job.items + 1
    self:finishJob(reason, silent)
end

function Page:finishJob(reason, silent)
    local job = self.job
    if job == nil then return end
    self.job = nil
    local parts = {}
    for _, state in ipairs(STATES) do
        local n = job.counts[state]
        if n ~= nil and n > 0 then
            parts[#parts + 1] = stateLabel(state) .. " " .. tostring(n)
        end
    end
    local tally = #parts > 0 and table.concat(parts, "  /  ") or "-"
    self.batchReport = table.concat(job.lines, "\n")
    if not silent then
        local head = job.kind == "batch" and getText(T .. "Admin_Rec_BatchDone", tally)
            or getText(T .. "Admin_Rec_SweepDone", tally)
        -- every note that applies, not just the first: a run that was stopped AND left one write
        -- with an unknown outcome has to say both, or the more urgent half goes missing
        if (job.counts.unknown or 0) > 0 then head = head .. "  " .. tr("Admin_Rec_Unknown") end
        if reason == "forbidden" then head = head .. "  " .. U.adminErrorText("forbidden") end
        if reason == "stopped" or reason == "left" then
            head = head .. "  " .. tr("Admin_Rec_Stopped")
        end
        self.batchReport = head .. "\n\n" .. self.batchReport
        self.owner.message = { text = head, error = (job.counts.unknown or 0) > 0
            or (job.counts.partial or 0) > 0 or (job.counts.refused or 0) > 0 or reason == "forbidden" }
        -- the queue is over, so the view it was working on is asked for again once
        self.sentScope = nil
    end
    self:layout()
end

function Page:onReport()
    if self.batchReport == nil then return end
    D.open(self, "recovery:report", tr("Admin_Rec_BatchReport"), self.batchReport)
end

-- ----- rows -----

-- Where this row's buttons sit. Computed per row (each record offers its own decisions), once per
-- rebuild: twenty rows of at most five chips is a handful of measurements, not a per-frame cost,
-- and it is the only way a row without a decision really has no button. The selection toggle is
-- always the rightmost chip, so it is in the same column on every row whatever the row allows.
function Page:statusDetails()
    local lines = {}
    local message = self.owner.message
    if message and message.text then lines[#lines + 1] = message.text end
    for _, line in ipairs(self.statusText or {}) do lines[#lines + 1] = line end
    for _, account in ipairs(self.snapshot and self.snapshot.accounts or {}) do
        local name = tostring(account.username) .. " (" .. tr(account.online and "Admin_Player_Online" or "Admin_Player_Offline") .. ")"
        lines[#lines + 1] = getText(T .. "Admin_Rec_AccountLine", name, tostring(account.held or 0),
            account.open ~= nil and tostring(account.open) or tr("Admin_Rec_QuantityUnknown"))
    end
    return table.concat(lines, "\n")
end

function Page:onStatus()
    self:refreshStatus()
    D.open(self, "recovery:status", tr("Admin_Rec_StatusDetails"), self:statusDetails())
end

function Page:rowStrip(rec, width, height, pickW)
    local h = math.max(20, math.min(height - 8, fontH.small + 8))
    local y = math.max(3, math.floor((height - h) / 2))
    -- `rec.actions` is the whole truth about what may be pressed, and the server recomputes it on
    -- every read: a record whose evidence is unread, or whose own record refuses a rebuild, comes
    -- back with all four false and therefore with no chip. Nothing is inferred here from the
    -- reason -- a commit-point mismatch, for one, may be perfectly actionable off the server's
    -- own record, so second-guessing the flags would hide a decision the server does offer.
    local flags = type(rec.actions) == "table" and rec.actions or {}
    local count = 1
    for _, id in ipairs(DECISIONS) do if flags[id] == true then count = count + 1 end end
    local budget = width - PAD - math.max(60, math.floor(width * 0.3)) - ROW_ACTION_GAP * (count - 1)
    local cap = math.max(8, math.floor(budget / count))
    pickW = math.min(pickW, cap)
    local x = width - PAD - pickW
    local pick = { x = x, y = y, w = pickW, h = h }
    x = x - ROW_ACTION_GAP
    local out = {}
    for i = #DECISIONS, 1, -1 do
        local id = DECISIONS[i]
        if flags[id] == true then
            local label = decisionLabel(id)
            local bw = math.min(textWidth(label) + 20, cap)
            x = x - bw
            out[#out + 1] = { id = id, label = label, x = x, y = y, w = bw, h = h }
            x = x - ROW_ACTION_GAP
        end
    end
    for i = 1, math.floor(#out / 2) do out[i], out[#out - i + 1] = out[#out - i + 1], out[i] end
    return out, x + ROW_ACTION_GAP, pick
end

function Page:recordRow(rec, width, rowHeight, pickW, labels)
    local lh = lineH()
    local actions, limit, pick = self:rowStrip(rec, width, rowHeight, pickW)
    local qty, present = intOf(rec.qty), intOf(rec.presentQty)
    local qtyText = qty ~= nil and amountText(qty) or "-"
    if present ~= nil and present ~= qty then
        qtyText = qtyText .. " / " .. amountText(present)
    end
    local qtyW = math.max(40, textWidth(qtyText) + 8)
    local textW = math.max(40, (limit or (width - PAD)) - qtyW - PAD * 2)

    local user = str(rec.username) or self.username
    local reason = reasonText(rec.reason)
    local head = reason
    local item = str(rec.item)
    if item then
        local name = itemName(item)
        if qty ~= nil and qty > 1 then name = name .. "  " .. getText(T .. "Market_Lot", tostring(qty)) end
        head = head .. "  /  " .. name
    end
    -- the account first on the server-wide view: it is the column a host reads down
    if self.scope == "all" and user ~= nil then head = tostring(user) .. "  /  " .. head end

    local readError = rec.readError ~= nil and rec.readError ~= false
    local online = rec.online
    if online == nil then online = self:online() end
    local parts = {}
    -- a short tag on the row, because the row is one truncated line: the whole sentence is in the
    -- band (Admin_Rec_ReadErrorNote) and in the record itself, where it cannot be cut away
    if readError then parts[#parts + 1] = tr("Admin_Rec_ReadErrorTag") end
    if online ~= true then parts[#parts + 1] = tr("Admin_Rec_RowOffline") end
    -- Where the content came from goes on the row itself: the contract wants every summary to
    -- say whether this is server evidence or only the player's own claim, and a host reading the
    -- list down must not have to open a record to find out which.
    local proof = proofText(rec.source)
    if proof ~= nil then parts[#parts + 1] = proof end
    -- why nothing can be done, when that is the case: the server's own code, so "the evidence is
    -- still being read" and "the record says this cannot be rebuilt" never read alike
    local blocked = blockedText(rec.blocked)
    if blocked ~= nil then parts[#parts + 1] = blocked end
    -- Two facts the blocked code alone cannot carry, each a short tag here and a whole sentence
    -- in the record. They are independent of the code, not a rewrite of it: the server reports
    -- proofState verbatim (journal_malformed stays journal_malformed) and states these beside it,
    -- so a host reading a log or an audit line still finds the same words.
    if rec.duplicate == true then parts[#parts + 1] = tr("Admin_Rec_EvidenceConflictTag") end
    if rec.foreign == true then parts[#parts + 1] = tr("Admin_Rec_ForeignTag") end
    parts[#parts + 1] = sourceText(rec.sourceState)
    parts[#parts + 1] = verdictText(rec.verdict)
    local at = intOf(rec.at)
    if at then parts[#parts + 1] = stampText(at, self.owner.offsetMin) end
    parts[#parts + 1] = tostring(rec.key or "-")

    return {
        id = rowId(user, rec.key),
        username = user,
        key = str(rec.key),
        revision = str(rec.revision),
        qty = qty, presentQty = present,
        online = online == true and not readError,
        readError = readError,
        record = rec,
        actions = actions,
        pick = pick,
        pickLabel = labels.pick,
        unpickLabel = labels.unpick,
        source = str(rec.source),
        unproven = rec.unproven == true,
        mismatch = type(rec.mismatch) == "table" and rec.mismatch or nil,
        blocked = str(rec.blocked),
        blockedRecheck = blockedRecheck(rec),
        proofState = str(rec.proofState),
        duplicate = rec.duplicate == true,
        foreign = rec.foreign == true,
        -- an unproven record is a warning row: it is acted on by a human accepting data nobody
        -- verified, which is exactly as notable as a rolled-back or ambiguous source
        warn = rec.sourceState == "rolledback" or rec.sourceState == "ambiguous" or readError
            or rec.unproven == true,
        line1Y = 5, line2Y = 5 + lh,
        line1 = fitText(head, textW),
        line2 = fitText(table.concat(parts, "  /  "), textW),
        qtyText = qtyText,
        qtyRight = math.max(qtyW, (limit or width) - PAD),
        headText = head,
        detailText = self:recordText(rec, user),
    }
end

-- Exactly what accepting this record would put back: the item, how many, and every origin the
-- server named for it. The contract requires the confirmation to show this in full rather than
-- report a reconciliation as done, so nothing here is summarised and nothing is invented -- a
-- field the preview does not carry is said to be missing, never defaulted to 1 or to survivor.
--
-- The server only sends a preview where something really would be generated, which is the restore
-- path: a discard creates nothing at all and carries none. Returned as a list of lines; the
-- caller joins them (the record reader wraps on newlines, the dialog's warning box wraps on width
-- and needs two spaces).
function Page:previewLines(rec)
    local preview = type(rec.preview) == "table" and rec.preview or nil
    if preview == nil then return nil end
    local out = { tr("Admin_Rec_PreviewTitle") }
    local item = str(preview.item)
    if item ~= nil then
        local name = itemName(item)
        out[#out + 1] = getText(T .. "Admin_Rec_PreviewItem",
            (name == item) and item or (name .. "  (" .. item .. ")"))
    else
        out[#out + 1] = getText(T .. "Admin_Rec_PreviewItem", tr("Admin_Rec_PreviewMissing"))
    end
    local qty = intOf(preview.qty)
    out[#out + 1] = getText(T .. "Admin_Rec_PreviewQty",
        qty ~= nil and amountText(qty) or tr("Admin_Rec_PreviewMissing"))
    local origins = type(preview.origins) == "table" and preview.origins or nil
    if origins == nil or #origins == 0 then
        out[#out + 1] = getText(T .. "Admin_Rec_PreviewOrigins", tr("Admin_Rec_PreviewMissing"))
    else
        -- every origin by its native id and the source it was taken from: an origin the reply
        -- named without either is said to be missing rather than counted silently
        local ids = {}
        for _, origin in ipairs(origins) do
            local id = type(origin) == "table" and (str(origin.nativeId) or str(origin.id)) or str(origin)
            local src = type(origin) == "table" and str(origin.src) or nil
            id = id or tr("Admin_Rec_PreviewMissing")
            ids[#ids + 1] = src ~= nil and (id .. " (" .. src .. ")") or id
        end
        out[#out + 1] = getText(T .. "Admin_Rec_PreviewOrigins", table.concat(ids, ", "))
    end
    -- the preview states its own provenance, and it is the one that decides the wording: an
    -- authoritative preview is the server's record, a player_claim one is the save's own account
    -- of itself
    local source = proofText(preview.source)
    if source ~= nil then out[#out + 1] = getText(T .. "Admin_Rec_PreviewSource", source) end
    return out
end

-- The server's commit point against the one the pending record claims, side by side: a mismatch
-- is exactly the disagreement between these two, so both are shown rather than summarised into
-- "does not match".
--
-- `serverEpoch/serverSeq` is the authoritative commit point out of the journal line;
-- `claimedEpoch/claimedSeq` is what the player's save says it was (the journal layer calls that
-- pair expectedEpoch/expectedSeq, but its detail never crosses to a client -- the admin reply is
-- the renamed shape, confirmed by both the journal and the admin slice, so only that is read
-- here). A pair that is only half stated prints dashes rather than inventing the missing half:
-- the whole point of this block is to show the disagreement, so a fabricated number defeats it.
function Page:mismatchLines(rec)
    local m = type(rec.mismatch) == "table" and rec.mismatch or nil
    if m == nil then return nil end
    local function point(epoch, seq)
        return tostring(str(epoch) or "-") .. " / " .. tostring(intOf(seq) or "-")
    end
    return {
        getText(T .. "Admin_Rec_MismatchServer", point(m.serverEpoch, m.serverSeq)),
        getText(T .. "Admin_Rec_MismatchClaimed", point(m.claimedEpoch, m.claimedSeq)),
    }
end

-- The whole unproven disclosure as the confirmation shows it, for the decision that is actually
-- being taken: the warning in words, then either what a restore would generate or -- for a
-- discard, which generates nothing and carries no preview -- that it destroys the claim outright.
-- Two spaces join the parts on purpose (see previewLines).
function Page:unprovenText(rec, decision)
    -- `foreign` is DISPROOF, not absence: the operation id was found on another account's line,
    -- which says this account's claim is wrong -- not that nothing is known about it. Accepting
    -- it would mint a receipt out of somebody else's operation, so it can never reach the manual
    -- path whatever else the reply says. The server states this with restorable=false and
    -- unproven=false; refusing it here as well means a server regression cannot reopen it.
    if rec.foreign == true then return nil end
    -- Otherwise driven by `rec.unproven` and nothing else. A commit-point mismatch where the
    -- server still found its own record is NOT unproven: the decision runs off that record,
    -- needs no acceptance and must not be shown this warning.
    if rec.unproven ~= true then return nil end
    local out = tr("Admin_Rec_UnprovenWarn")
    local mismatch = self:mismatchLines(rec)
    if mismatch ~= nil then out = out .. "  " .. table.concat(mismatch, "  ") end
    if decision == "discard" then
        return out .. "  " .. tr("Admin_Rec_DiscardNothing")
    end
    local lines = self:previewLines(rec)
    if lines ~= nil then out = out .. "  " .. table.concat(lines, "  ") end
    return out
end

-- The whole record, as the reader window shows it and as CopyAll hands it over: every field the
-- server sent, nothing shortened, nothing invented. A field the reply does not carry is left out
-- instead of being printed as a dash a host could read as a real value.
function Page:recordText(rec, user)
    local lines = {}
    if user ~= nil then lines[#lines + 1] = getText(T .. "Admin_Rec_Title", tostring(user)) end
    if rec.readError ~= nil and rec.readError ~= false then
        lines[#lines + 1] = tr("Admin_Rec_ReadError")
    end
    lines[#lines + 1] = reasonText(rec.reason)
    -- Why nothing may be done, in the server's own code, and -- only where asking again could
    -- change the answer -- that it is worth asking again. A record whose own evidence refuses a
    -- rebuild is a settled verdict and gets no such invitation.
    local blocked = blockedText(rec.blocked)
    if blocked ~= nil then lines[#lines + 1] = blocked end
    if blockedRecheck(rec) then lines[#lines + 1] = tr("Admin_Rec_JournalRecheck") end
    -- What the code alone cannot say. None of these changes the verdict (`actions` decides that)
    -- but each sends a host somewhere different: a reviewable previous record means the rebuild
    -- has real server evidence behind it, a contradiction between two journal lines is an
    -- investigation, and a foreign line disproves this account's claim outright.
    if rec.previous == true then lines[#lines + 1] = tr("Admin_Rec_Previous") end
    if rec.duplicate == true then lines[#lines + 1] = tr("Admin_Rec_EvidenceConflict") end
    if rec.foreign == true then lines[#lines + 1] = tr("Admin_Rec_Foreign") end
    -- which part of the evidence is wrong: the chain's own order, one commit point carrying two
    -- contents, or a single line's shape. Same verdict either way, different place to look.
    local proofField = proofFieldText(rec.proofField)
    if proofField ~= nil then
        lines[#lines + 1] = getText(T .. "Admin_Rec_ProofField", proofField)
    end
    -- Where the content came from, said before anything derived from it is read
    local proof = proofText(rec.source)
    if proof ~= nil then lines[#lines + 1] = proof end
    if rec.unproven == true then lines[#lines + 1] = tr("Admin_Rec_UnprovenWarn") end
    -- A mismatch is a disagreement between two commit points: both are printed. Where the server
    -- found its own record anyway, that record is what any decision uses -- so this is a note
    -- about provenance, not a reason to distrust what is about to happen.
    local mismatchLines = self:mismatchLines(rec)
    if mismatchLines ~= nil then
        for _, line in ipairs(mismatchLines) do lines[#lines + 1] = line end
        if rec.source == "journal" then
            lines[#lines + 1] = tr("Admin_Rec_MismatchAuthoritative")
        end
    end
    local proofState = str(rec.proofState)
    if proofState ~= nil then
        lines[#lines + 1] = getText(T .. "Admin_Rec_ProofState", reasonText(proofState))
    end
    local outcome = str(rec.outcome)
    if outcome ~= nil then
        lines[#lines + 1] = getText(T .. "Admin_Rec_Outcome", verdictText(outcome))
    end
    local previewLines = self:previewLines(rec)
    if previewLines ~= nil then
        lines[#lines + 1] = ""
        for _, line in ipairs(previewLines) do lines[#lines + 1] = line end
    end
    local item = str(rec.item)
    if item then
        local name = itemName(item)
        lines[#lines + 1] = (name == item) and item or (name .. "  (" .. item .. ")")
    end
    local qty, present = intOf(rec.qty), intOf(rec.presentQty)
    if qty ~= nil then lines[#lines + 1] = getText(T .. "Admin_Rec_DQty", amountText(qty)) end
    if present ~= nil then lines[#lines + 1] = getText(T .. "Admin_Rec_DPresent", amountText(present)) end
    lines[#lines + 1] = sourceText(rec.sourceState) .. "  /  " .. verdictText(rec.verdict)
    local at = intOf(rec.at)
    if at then lines[#lines + 1] = getText(T .. "Admin_Rec_DAt", stampText(at, self.owner.offsetMin)) end
    lines[#lines + 1] = ""
    -- ASCII tags from here down: these are the identifiers a host pastes into a ticket or reads
    -- back to the server, and a localised label in front of them would only be in the way
    lines[#lines + 1] = "key      " .. tostring(rec.key or "-")
    local mail, op, tx, kind = str(rec.mailId), str(rec.opId), str(rec.txId), str(rec.kind)
    if mail then lines[#lines + 1] = "mail     " .. mail end
    if op then lines[#lines + 1] = "op       " .. op end
    if tx then lines[#lines + 1] = "tx       " .. tx end
    if kind then lines[#lines + 1] = "kind     " .. kind end
    local epoch, seq = str(rec.epoch), intOf(rec.seq)
    if epoch or seq then
        lines[#lines + 1] = "epoch    " .. tostring(epoch or "-") .. " / seq " .. tostring(seq or "-")
    end
    if type(rec.nativeIds) == "table" and #rec.nativeIds > 0 then
        local ids = {}
        for i, id in ipairs(rec.nativeIds) do ids[i] = tostring(id) end
        lines[#lines + 1] = "native   " .. table.concat(ids, ", ")
    end
    local detail = str(rec.detail)
    if detail then lines[#lines + 1] = "detail   " .. detail end
    local revision = str(rec.revision)
    if revision then lines[#lines + 1] = "revision " .. revision end
    -- A record with nothing to do is the honest answer to "why can I not fix this": the reason
    -- above says what is missing, and no fallback decision is offered in its place.
    local flags = type(rec.actions) == "table" and rec.actions or nil
    local any = false
    if flags then
        for _, id in ipairs(DECISIONS) do
            if flags[id] == true then any = true end
        end
    end
    if not any then
        lines[#lines + 1] = ""
        lines[#lines + 1] = tr("Admin_Rec_NoAction")
    end
    return table.concat(lines, "\n")
end

function Page:rebuild()
    local current = self.rows and self.rows[self.list:getSelectedIndex() or 0]
    local focusId = current and current.id
    local readingId = self.selected and self.selected.id
    local anchorFound = false
    local rows = {}
    local snap = self.snapshot
    if snap ~= nil and type(snap.records) == "table" then
        local list = self.list
        local width = math.max(120, list.width - 12)   -- 12 = the scrollbar gutter
        local labels = { pick = tr("Admin_Rec_Pick"), unpick = tr("Admin_Rec_Unpick") }
        local pickW = math.max(textWidth(labels.pick), textWidth(labels.unpick)) + 20
        for _, rec in ipairs(snap.records) do
            if type(rec) == "table" and str(rec.key) then
                rows[#rows + 1] = self:recordRow(rec, width, list.rowHeight, pickW, labels)
            end
        end
    end
    self.rows = rows
    self.list:setItems(rows)
    self.rowsWidth, self.rowsHeight = self.list.width, self.list.rowHeight
    self.list:setSelectedIndex(nil)
    self.selected = nil
    for i, row in ipairs(rows) do
        if row.id == self.pickAnchor then anchorFound = true end
        if row.id == focusId then self.list:setSelectedIndex(i) end
        if row.id == readingId then
            self.selected = row
            D.update(self, "recovery:" .. row.id, tr("Admin_Rec_List"), row.detailText)
        end
    end
    if not anchorFound then self.pickAnchor = nil end
    if self.selected or D.isOpen(self, "recovery:report") or D.isOpen(self, "recovery:status") then return end
    D.close(self)
end

function Page:onRow(item, index)
    local ctrl, shift = C.Keyboard.modifiers()
    if item ~= nil and (ctrl or shift) then
        self:selectRow(item, index, shift)
        return
    end
    self.pickAnchor = item and item.id or nil
    self.selected = item
    if item == nil then
        D.close(self)
        self:updateEnabled()
        return
    end
    D.open(self, "recovery:" .. item.id, tr("Admin_Rec_List"), item.detailText)
    self:updateEnabled()
end

-- ----- geometry -----

-- Which chips the foot strip carries right now, in reading order: what the selection is, what may
-- be done with it, and how to move. A chip that cannot apply is not greyed out in place -- it is
-- left out, so the strip a host reads is the strip they can use.
function Page:footChips()
    local all = self.scope == "all"
    local chips = {}
    chips[#chips + 1] = self.statusButton
    chips[#chips + 1] = self.pickPageButton
    chips[#chips + 1] = self.clearPicksButton
    local counts = self:decisionCounts()
    for _, b in ipairs(self.batchButtons) do
        local count = counts[b.internal] or 0
        if count > 0 then
            chips[#chips + 1] = b
        end
    end
    if self.batchReport ~= nil then chips[#chips + 1] = self.reportButton end
    if self.job ~= nil then chips[#chips + 1] = self.stopButton end
    if all then
        chips[#chips + 1] = self.recheckAllButton
    else
        chips[#chips + 1] = self.recheckButton
        chips[#chips + 1] = self.backButton
    end
    chips[#chips + 1] = self.prevButton
    chips[#chips + 1] = self.nextButton
    return chips
end

function Page:layout()
    local w, h = self.width, self.height
    local ch = chipH()
    local lh = lineH()
    local title = math.max(CARD_TITLE_H, entryH() + 8, fontH.medium + 8)
    self.titleH = title
    local visible = self:getIsVisible()
    local all = self.scope == "all"
    local inner = math.max(80, w - PAD * 2)

    -- the account filter sits in the card's own title row, right-aligned: it is the one control
    -- the server-wide view is driven from, and it keeps its place whatever the font scale does
    local searchW = math.max(80, math.min(math.floor(w * 0.4), 260))
    local eh = entryH()
    self.searchEntry:setVisible(visible and all)
    self.searchEntry:setWidth(searchW)
    self.searchEntry:setHeight(eh)
    self.searchEntry:setX(math.max(0, w - PAD - searchW))
    self.searchEntry:setY(math.max(0, math.floor((title - eh) / 2)))

    local counts = self:decisionCounts()
    for _, b in ipairs(self.batchButtons) do
        b.fullTitle = getText(T .. "Admin_Rec_BatchAction", tostring(counts[b.internal] or 0), decisionLabel(b.internal))
    end
    local chips = self:footChips()
    for _, b in ipairs({ self.pickPageButton, self.clearPicksButton, self.reportButton,
        self.stopButton, self.recheckAllButton, self.recheckButton, self.backButton,
        self.prevButton, self.nextButton, self.statusButton }) do
        b:setVisible(false)
    end
    for _, b in ipairs(self.batchButtons) do b:setVisible(false) end
    local columns = 3
    local footH = packHeight(chips, inner, ch, columns)
    local availableH = h - PAD - title - self.list.rowHeight - lh - 10
    while footH > availableH and columns < #chips do
        columns = columns + 1
        footH = packHeight(chips, inner, ch, columns)
    end
    -- the strip is pinned to the foot and is the last thing to give way: a control a host cannot
    -- reach is worse than a band line or a row they have to scroll to
    local footY = math.max(0, h - PAD - footH)
    packChips(chips, PAD, footY, inner, ch, columns)
    for _, b in ipairs(chips) do b:setVisible(visible) end
    self.footY = footY
    self.pagerY = footY - lh - 4

    -- Status band under the title: the server-wide totals, the selection, a queue in progress,
    -- the save watermark and, when they apply, the offline / read-only / read-failure limits. The
    -- band never eats the rows: it takes only what is left over a minimum list height, down to no
    -- line at all, and its lines are ordered so the hints are what a very large font drops first.
    local bandY = title + 2
    local roomH = self.pagerY - 8 - bandY - self.list.rowHeight
    local bandMax = roomH > 0 and math.floor(roomH / lh) or 0
    -- `statusLines` is what the band asked for, `bandLines` what it got: refreshStatus compares
    -- against the former, so one relayout settles it and a capped band never loops
    self.statusLines = math.max(2, #(self.statusText or {}))
    self.bandLines = math.min(self.statusLines, bandMax)
    local bandH = self.bandLines > 0 and (lh * self.bandLines + 4) or 0
    self.bandY = bandY

    local listY = bandY + bandH
    local listH = math.max(self.list.rowHeight, self.pagerY - 4 - listY)
    -- the rows follow the page: a list left "visible" inside a hidden page would still be offered
    -- to the keyboard walk and to C.RowActions
    U.placeList(self.list, visible, PAD, listY, math.max(120, w - PAD * 2), listH)
    self.listY, self.listH = listY, listH
    if self.snapshot ~= nil and (self.rowsWidth ~= self.list.width or self.rowsHeight ~= self.list.rowHeight) then self:rebuild() end
    self.layoutW, self.layoutH = w, h
    self:updateEnabled()
end

function Page:resize(width, height)
    if self.width ~= width then self:setWidth(width) end
    if self.height ~= height then self:setHeight(height) end
    self:layout()
end

-- ----- painting -----

-- What the band says, rebuilt when the snapshot, the selection, the queue or the permission moves
-- -- never per frame.
function Page:refreshStatus()
    local snap = self.snapshot
    local perm = self.owner:writeAllowed()
    local busy = self.isPending("admin.recovery")
    local jobDone = self.job ~= nil and self.job.i or -1
    local picked, dropped = self.pickedCount, self.staleDropped or 0
    if self.statusSnapshot == snap and self.statusPerm == perm and self.statusBusy == busy
        and self.statusPicked == picked and self.statusDropped == dropped and self.statusJob == self.job
        and self.statusJobDone == jobDone and self.statusMessage == self.owner.message and self.statusText ~= nil then return end
    self.statusSnapshot, self.statusPerm, self.statusBusy = snap, perm, busy
    self.statusPicked, self.statusDropped, self.statusJob, self.statusJobDone = picked, dropped, self.job, jobDone
    self.statusMessage = self.owner.message
    local lines = {}
    local job = self.job
    if job ~= nil then
        local key = job.kind == "batch" and "Admin_Rec_BatchProgress" or "Admin_Rec_SweepProgress"
        lines[#lines + 1] = getText(T .. key, tostring(math.min(job.i - 1, job.total)), tostring(job.total))
    end
    if self.pickedCount > 0 then
        local _, accounts = self:pickedFor(nil)
        lines[#lines + 1] = getText(T .. "Admin_Rec_Selected", tostring(self.pickedCount), tostring(accounts))
        if EC.countKeys(self:decisionCounts()) == 0 then lines[#lines + 1] = tr("Admin_Rec_NoApplicable") end
    end
    if (self.staleDropped or 0) > 0 then
        lines[#lines + 1] = getText(T .. "Admin_Rec_StaleDropped", tostring(self.staleDropped))
    end
    local summary = self:summary()
    if summary ~= nil then
        lines[#lines + 1] = getText(T .. "Admin_Rec_SumHeld",
            tostring(intOf(summary.accounts) or 0), tostring(intOf(summary.held) or 0))
        lines[#lines + 1] = getText(T .. "Admin_Rec_SumOnline",
            tostring(intOf(summary.onlineAccounts) or 0), tostring(intOf(summary.offlineAccounts) or 0))
        local open = intOf(summary.open)
        if open ~= nil then
            lines[#lines + 1] = getText(T .. "Admin_Rec_SumOpen", tostring(open))
        else
            lines[#lines + 1] = tr("Admin_Rec_SumOpenUnknown")
        end
    end
    local status = snap and type(snap.status) == "table" and snap.status or nil
    if status then
        local held = intOf(status.held)
        if held ~= nil and self.scope ~= "all" then
            lines[#lines + 1] = getText(T .. "Admin_Player_Recovery", tostring(held))
        end
        local open, maximum = intOf(status.open), intOf(status.max)
        if open and maximum and open > 0 then
            lines[#lines + 1] = getText(T .. "Recovery_WaitingSave", tostring(open), tostring(maximum))
        end
        local seq = intOf(status.durableSeq)
        lines[#lines + 1] = tr("Admin_Sys_Durable") .. ": "
            .. (seq ~= nil and amountText(seq) or tr("Admin_Sys_DurableNone"))
            .. "  (" .. tostring(status.durableStatus or "-") .. ")"
        if status.durableSource ~= "companion" then lines[#lines + 1] = tr("Recovery_NoWatermark") end
    elseif busy then
        lines[#lines + 1] = tr("Admin_Loading")
    end
    if snap ~= nil and self.scope ~= "all" and snap.online ~= true then
        lines[#lines + 1] = tr("Admin_Rec_Offline")
    end
    if self:anyReadError() then lines[#lines + 1] = tr("Admin_Rec_ReadErrorNote") end
    if not perm then lines[#lines + 1] = tr("Admin_Rec_ReadOnlyNote") end
    if self.scope == "all" then lines[#lines + 1] = tr("Admin_Rec_AccountsHint") end
    lines[#lines + 1] = tr("Admin_Rec_Hint")
    lines[#lines + 1] = tr("Admin_Rec_BatchHint")
    self.statusText = lines
    if self.layoutW ~= nil and math.max(2, #lines) ~= self.statusLines then self:layout() end
end

function Page:anyReadError()
    for _, row in ipairs(self.rows or {}) do
        if row.readError then return true end
    end
    return false
end

function Page:prerender()
    local w, h = self.width, self.height
    -- an opaque surface: this page is read against identifiers and quantities, and nothing behind
    -- it must show through the rows it is being compared with
    U.theme:fill(self, 0, 0, w, h, "surface", "rect", 1)
    local heading = tr("Admin_Rec_All")
    if self.scope ~= "all" then
        heading = getText(T .. "Admin_Rec_Title", tostring(self.username or "-"))
    end
    local right = self.searchEntry:getIsVisible() and self.searchEntry.x or w
    card(self, 0, 0, w, h, fitText(heading, math.max(20, right - PAD * 2), UIFont.Medium), self.titleH)

    self:refreshStatus()
    local lh = lineH()
    local y = self.bandY or (CARD_TITLE_H + 2)
    local shown = 0
    for _, line in ipairs(self.statusText or {}) do
        if shown >= (self.bandLines or 2) or y + lh > (self.listY or h) then break end
        text(self, fitText(line, math.max(20, w - PAD * 2)), PAD, y, "textMuted")
        y = y + lh
        shown = shown + 1
    end

    if #(self.rows or {}) == 0 then
        local body
        if self.readError ~= nil then
            body = U.adminErrorText(self.readError)
        elseif self.isPending("admin.recovery") or self.snapshot == nil then
            body = tr("Admin_Loading")
        elseif self.scope == "all" then
            body = self.query ~= nil and getText(T .. "Admin_Rec_NoMatch", self.query)
                or tr("Admin_Rec_EmptyAll")
        else
            body = tr("Admin_Rec_Empty")
        end
        text(self, fitText(body, math.max(20, w - PAD * 2)), PAD * 2, (self.listY or 0) + 4, "textFaint")
    end

    local snap = self.snapshot
    local label = getText(T .. "Filter_Page", tostring(self.page or 1), tostring(self:pageCount()))
    if snap ~= nil then
        label = label .. "  " .. getText(T .. "Filter_Count", tostring(intOf(snap.total) or #self.rows))
    end
    textRight(self, label, w - PAD, self.pagerY or 0, "textMuted")
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
    local busy = self.isPending("admin.recovery")
    local job = self.job ~= nil
    local read = owner:readAllowed() and not modal
    local write = owner:writeAllowed() and not modal and not busy and not job
    local all = self.scope == "all"
    -- a read-only role browses the whole page and never arms a decision; an offline account is the
    -- same, because neither a rescan nor a removal can be proven against an inventory that is not
    -- there. On the server-wide view that is per row: an offline account's record arrives with no
    -- permitted decision at all, so it has no button to arm.
    self.list.optionsDisabled = not (write and (all or self:online()))
    -- selecting is a read, so it survives a read-only role; a running queue freezes the set it is
    -- working through
    self.list.picksDisabled = not read or job
    U.setEntryEditable(self.searchEntry, read and all and not job)
    self.pickPageButton:setEnable(read and not job and #(self.rows or {}) > 0)
    self.clearPicksButton:setEnable(read and not job and self.pickedCount > 0)
    local counts = self:decisionCounts()
    for _, b in ipairs(self.batchButtons) do
        b:setEnable(write and (counts[b.internal] or 0) > 0)
    end
    self.reportButton:setEnable(self.batchReport ~= nil and not modal)
    self.statusButton:setEnable(read)
    self.stopButton:setEnable(job)
    self.recheckAllButton:setEnable(write and self.snapshot ~= nil
        and type(self.snapshot.accounts) == "table" and #self.snapshot.accounts > 0)
    self.recheckButton:setEnable(write and not all and self:online())
    self.backButton:setEnable(read and not job)
    local pages = self:pageCount()
    local page = self.page or 1
    self.prevButton:setEnable(read and not busy and not job and page > 1)
    self.nextButton:setEnable(read and not busy and not job and page < pages)
end

function Page:keyboardTargets()
    if not self:getIsVisible() then return {} end
    local out = {}
    if self.searchEntry:getIsVisible() then
        out[#out + 1] = { kind = "entry", label = tr("Admin_Rec_SearchHint"), control = self.searchEntry }
    end
    out[#out + 1] = { kind = "list", label = tr("Admin_Rec_List"), control = self.list }
    local actions = R.targets(self.list)
    if #actions > 0 then
        out[#out + 1] = { kind = "group", label = tr("Admin_Rec_Actions"), controls = actions }
    end
    local chips = {}
    for _, b in ipairs(self:footChips()) do
        if b:getIsVisible() then chips[#chips + 1] = b end
    end
    if #chips > 0 then
        out[#out + 1] = { kind = "group", label = tr("Admin_Rec_Nav"), controls = chips }
    end
    return out
end

-- ----- lifecycle -----

-- Driven by the admin page's own prerender: the read a host asked for while the shared slot was
-- busy goes out here, the account filter's pause is measured here, and a queued write leaves here.
-- Nothing polls.
function Page:tick(now)
    if not self:live() then return end
    if self.queryAt ~= nil and now - self.queryAt > QUERY_DEBOUNCE_MS then
        self:applyQuery()
    end
    self:pumpJob()
    self:pump()
end

function Page:dispose()
    self:stopJob(nil, true)
    D.close(self)
    self.list:setItems({})
    self.snapshot = nil
    self.rows = {}
    self:clearPicks()
end

-- ---------- module API ----------

-- owner: the admin controller (ECAdminPanel), which owns the command slot, the two write dialogs
-- and both permission gates. isPending: that controller's own "is this command in flight" reader.
function P.create(owner, isPending)
    local o = ISPanel:new(0, 0, 600, 400)
    setmetatable(o, Page)
    o.background = false
    o.owner = owner
    o.isPending = isPending
    o.scope = "all"
    o.page = 1
    o.rows = {}
    o.picked = {}
    o.pickOrder = {}
    o.pickedCount = 0
    o:initialise()
    o:instantiate()
    o:setVisible(false)
    return o
end

return P
