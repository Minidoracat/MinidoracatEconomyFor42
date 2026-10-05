-- MinidoracatEconomyFor42 -- the identity desk (client). Adds exactly one namespace:
-- C.AdminIdentity.
--
--   C.AdminIdentity.collectRows(done)   the whitelist as admin.identity{action="import"} wants it:
--       done(rows, nil) with rows = { { u = name, s = "" | exact SteamID64 text }, ... }, or
--       done(nil, code) with code no_users_capability | busy | users_timeout | no_whitelist_rows.
--       Needs no UI (the E2E scenarios call it directly). One collection at a time.
--   C.AdminIdentity.create(owner, send, isPending, newRequestId)
--       an initialised ISPanel child, NOT added (the admin controller addChild's it). The three
--       transport functions are the controller's own, called as self.send(...) -- never with ":".
--       Methods: refresh(), resize(w, h), tick(now), layout(), updateEnabled(), keyboardTargets(),
--       matchesReply(args), onReply(args), onTimeout(), sendRebind(reason, dlg), clear(), dispose().
--
-- Two views. The overview puts its numbers in pills (Steam mode, conflicts, alerts, bindings and
-- imports, the one-account policy, the merge plan) and under them reads like a report, what needs
-- a decision first: a binding file the server cannot read, the conflicts the rebind button
-- confirms, why merges wait, the alerts, the companion's file, the last import; the policy, the
-- binding rule and the terms are spelled out in the help window. The logins list is a table of every login
-- that shares a Steam account with another (one row each; the Steam account's main account is
-- the row's second column): what the one-account policy makes of it and what the merge plan
-- says, searched, filtered and paged BY THE SERVER (admin.identity logins = { query, filter,
-- page }), so a server with thousands of logins is read a page at a time and nothing is cut.
-- Picking a row spells the login out in the shared detail window.
--
-- The page sends admin.identity and nothing else, and reads nothing from the session (hello.ack):
-- the server answers it even while this administrator's own name is unverified, so the desk that
-- fixes a refused identity must not depend on anything a refused client never receives.
--
-- Engine references (snapshot 42.21.0-20260928):
--   LuaManager.java:3276-3284, 3306-3312   requestUsers() (client only) / getUsers() -> the live
--                                          NetworkUsers.instance list (NetworkUsers.java:12-14,34-35:
--                                          cleared and refilled on every NetworkUsers packet)
--   RequestNetworkUsersPacket.java:15-33   requiredCapability = Capability.SeeNetworkUsers; the server
--                                          answers only a connection that has it
--   NetworkUsersPacket.java:25-56, 80-93   whitelist rows + online players (those get
--                                          setInWhitelist(false)); OnNetworkUsersReceived fires in
--                                          processClient, again only with SeeNetworkUsers
--   ServerWorldDatabase.java:60-86         whitelist rows carry the DB `steamid` text, setInWhitelist(true)
--   NetworkUser.java:79-81, 99-101, 151-153   getUsername / getSteamid (String, may be null) / isInWhitelist
--   LuaEventManager.java:840               OnNetworkUsersReceived; LuaManager.java:2460 exposes Capability
--   Role.java:185-191                      hasCapability
-- Vanilla usage: ISUsersList.lua:154-171 (getUsers loop, requestUsers), :268 (isInWhitelist);
-- ISAdminPanelUI.lua:216 (SeeNetworkUsers gate), :297, :423-429 (the event);
-- FishingManager.lua:53 (Events.OnTick.Remove).

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
C.AdminIdentity = P

local PAD, T = U.PAD, U.T
local CARD_TITLE_H = U.CARD_TITLE_H
local fontH = U.fontH
local fill, text, fitText, textWidth = U.fill, U.text, U.fitText, U.textWidth
local entryText, setEntryEditable = U.entryText, U.setEntryEditable

local COMMAND = "admin.identity"
local HELP_KEY = "identity-help"   -- not "identity:<name>": a login may be called "help"
local SID_EXACT = "^7656119%d%d%d%d%d%d%d%d%d%d$"   -- the server's Id.SID_EXACT
local USERS_TIMEOUT_MS = 15000
local QUERY_DEBOUNCE_MS = 650   -- one read per pause in the search box (the server throttles at 500)
local QUERY_MAX = 64            -- the server's Id.NAME_MAX
local GUTTER = 12               -- the list's scrollbar
local FILTERS = { "all", "blocked", "ready", "waiting", "ineligible", "merged" }
-- the four columns' shares of the row: login, main account, economy, merge
local SHARES = { 0.24, 0.24, 0.18, 0.34 }
local POLICY_TOKENS = { blocked = "warn" }
local MERGE_TOKENS = { ready = "positive", blocked = "warn", ineligible = "textFaint" }

local function tr(key) return getText(T .. key) end
local function lineH() return fontH.small + 6 end
local function chipH() return math.max(24, fontH.small + 10) end
local function entryH() return math.max(26, fontH.small + 12) end

-- ---------- the whitelist, read through the native users list ----------

local collecting = nil     -- { done, at } while one collection waits for the engine
local onUsers, onTick

local function finish(rows, err)
    local c = collecting
    collecting = nil
    Events.OnNetworkUsersReceived.Remove(onUsers)
    Events.OnTick.Remove(onTick)
    if c ~= nil then c.done(rows, err) end
end

-- The event also fires for vanilla's own users list; it is only listened to while a collection
-- is waiting, and the first list after the request is the answer.
onUsers = function()
    if collecting == nil then return end
    local rows = {}
    local users = getUsers()
    for i = 0, users:size() - 1 do
        local user = users:get(i)
        if user:isInWhitelist() then
            local sid = user:getSteamid()
            if type(sid) ~= "string" or not string.match(sid, SID_EXACT) then sid = "" end
            rows[#rows + 1] = { u = user:getUsername(), s = sid }
        end
    end
    if #rows == 0 then return finish(nil, "no_whitelist_rows") end
    finish(rows, nil)
end

onTick = function()
    if collecting ~= nil and EC.now() - collecting.at > USERS_TIMEOUT_MS then finish(nil, "users_timeout") end
end

function P.canSeeUsers()
    local ok, yes = pcall(function() return getPlayer():getRole():hasCapability(Capability.SeeNetworkUsers) end)
    return ok and yes == true
end

function P.collectRows(done)
    if not P.canSeeUsers() then done(nil, "no_users_capability"); return false end
    if collecting ~= nil then done(nil, "busy"); return false end
    collecting = { done = done, at = EC.now() }
    Events.OnNetworkUsersReceived.Add(onUsers)
    Events.OnTick.Add(onTick)
    requestUsers()
    return true
end

-- ---------- the page ----------

local Page = ISPanel:derive("MinidoracatEconomyAdminIdentity")

function Page:createChildren()
    local function chip(label, handler, style, internal)
        local b = U.Button.create(0, 0, textWidth(label) + 24, chipH(), label, self, handler, style)
        b.internal = internal
        self:addChild(b)
        return b
    end
    self.viewButtons = {
        chip(tr("Admin_Id_View_overview"), Page.onView, "chip", "overview"),
        chip(tr("Admin_Id_View_logins"), Page.onView, "chip", "logins"),
    }
    for _, b in ipairs(self.viewButtons) do b.active = b.internal == self.view end
    self.helpButton = chip(tr("Admin_Help"), Page.onHelp, "chip")
    -- the import is routine (the companion does it on its own); confirming conflicts is the
    -- decision this page exists for, so that one carries the fill
    self.importButton = chip(tr("Admin_Id_Import"), Page.onImport, "normal")
    self.rebindButton = chip(getText(T .. "Admin_Id_Rebind", "0"), Page.onRebind, "primary")
    self.reader = U.newReader(self, 400, 200)

    self.searchEntry = U.newEntry(240, entryH(), { maxLen = QUERY_MAX, clear = true,
        placeholder = tr("Admin_Id_Search") })
    self.searchEntry.target = self
    self.searchEntry.onTextChangeFunction = Page.onSearchTyped
    self.searchEntry.onCommandEntered = function() self:applyQuery() end
    self:addChild(self.searchEntry)
    self.filterButtons = {}
    for _, id in ipairs(FILTERS) do
        local b = chip(getText(T .. "Admin_Id_Filter_" .. id, "-"), Page.onFilter, "chip", id)
        b.active = id == self.filter
        self.filterButtons[#self.filterButtons + 1] = b
    end
    self.prevButton = chip(tr("Market_Prev"), Page.onPage, "chip", -1)
    self.nextButton = chip(tr("Market_Next"), Page.onPage, "chip", 1)
    self.list = U.newTable(U.framework.Table.TextCell, lineH() + 8)
    -- a row only reads: setSelectedIndex does not fire onSelect, so the arrows walk the rows for
    -- free, and the click and Enter (Focus listActivate) open the record
    self.list.onSelect = function(_, item) self:onRow(item) end
    self:addChild(self.list)
    self:layout()
end

function Page:invalidateKeyboard()
    if C.Keyboard and C.Keyboard.invalidate then pcall(C.Keyboard.invalidate, self.owner.owner) end
end

function Page:errorText(code, name)
    if code == "invalid_steamid" or code == "merged_name" then
        return getText(T .. "Admin_Error_" .. code, tostring(name or "-"))
    end
    return U.adminErrorText(code)
end

function Page:say(body, isError)
    self.result = { text = body, error = isError == true }
    self.owner.message = self.result
    self:rebuild()
end

function Page:conflicts()
    local s = self.status
    return s ~= nil and type(s.conflicts) == "table" and s.conflicts or {}
end

-- ----- transport -----

-- The logins condition on screen, as one string: a read carrying another one is re-asked.
function Page:loginsKey()
    return tostring(self.query or "") .. "\1" .. tostring(self.filter) .. "\1" .. tostring(self.page)
end

-- Every read carries the logins condition while the list is the view, so a page turn, the poll and
-- the answer to an import all come back with the rows that are on screen.
function Page:sendAction(args)
    if self.isPending(COMMAND) then return false end
    args.requestId = self.newRequestId()
    local withLogins = self.view == "logins"
    if withLogins then args.logins = { query = self.query, filter = self.filter, page = self.page } end
    if not self.send(COMMAND, args) then return false end
    self.sent = { requestId = args.requestId, action = args.action, logins = withLogins }
    if withLogins then self.askedKey = self:loginsKey() end
    self.owner:updateEnabled()
    return true
end

function Page:live()
    return self:getIsVisible() and self.owner:readAllowed()
end

-- The read this page is owed goes out when the shared slot is free; a collection in progress
-- holds it back, so the import it is gathering for never finds the slot taken. A logins condition
-- the last read did not carry is owed a read too.
function Page:pump()
    if self.collectToken ~= nil or not self:live() then return end
    if self.view == "logins" and self.askedKey ~= self:loginsKey() then self.wanted = true end
    if not self.wanted then return end
    if self:sendAction({ action = "status" }) then self.wanted = false end
end

function Page:refresh()
    self.wanted = true
    self:pump()
end

-- The controller's frame callback is this page's clock: the search box's pause, and the read.
function Page:tick(now)
    if self.view == "logins" then
        if entryText(self.searchEntry) ~= self.querySeen and self.queryAt == nil then self.queryAt = now end
        if self.queryAt ~= nil and now - self.queryAt > QUERY_DEBOUNCE_MS then self:applyQuery() end
    end
    self:pump()
end

-- ----- views and the list's conditions -----

function Page:onView(button)
    local view = button.internal
    if view == self.view then return end
    self.view = view
    for _, b in ipairs(self.viewButtons) do b.active = b.internal == view end
    self.selectedName = nil
    D.close(self)
    if view ~= "logins" then pcall(self.searchEntry.unfocus, self.searchEntry) end
    self:layout()
    self:invalidateKeyboard()
    self:pump()
end

-- A condition moved: the rows on screen are a slice of a complete sort, so the new condition starts
-- at its first page, and the record window of a row that may no longer be listed closes.
function Page:conditionChanged()
    self.page = 1
    self.selectedName = nil
    D.close(self)
    self.owner.message = nil
    self:layout()
    self:pump()
end

function Page:onSearchTyped()
    self.queryAt = EC.now()
end

-- The box's text, trimmed, sent as typed (the server folds case for the match); refused when it
-- carries a control character or runs past the server's bound, instead of silently dropping it.
function Page:applyQuery()
    self.queryAt = nil
    self.querySeen = entryText(self.searchEntry)
    local raw = string.match(self.querySeen, "^%s*(.-)%s*$")
    if #raw > QUERY_MAX or string.find(raw, "%c") then
        self.owner.message = { text = tr("Admin_Accounts_QueryBad"), error = true }
        return
    end
    local query = raw ~= "" and raw or nil
    if query == self.query then return end
    self.query = query
    self:conditionChanged()
end

function Page:onFilter(button)
    if self.filter == button.internal then return end
    self.filter = button.internal
    for _, b in ipairs(self.filterButtons) do b.active = b.internal == self.filter end
    self:conditionChanged()
end

function Page:onPage(button)
    local pages = self.logins and math.max(1, math.floor(tonumber(self.logins.pages) or 1)) or 1
    local target = math.max(1, math.min(pages, self.page + button.internal))
    if target == self.page then return end
    self.page = target
    self.selectedName = nil
    D.close(self)
    self:layout()
    self:pump()
end

-- ----- import -----

function Page:onImport()
    if self.owner.dialog ~= nil or self.collectToken ~= nil or self.isPending(COMMAND) then return end
    if not self.owner:writeAllowed() then return self:say(self:errorText("forbidden"), true) end
    if not P.canSeeUsers() then return self:say(tr("Admin_Id_Err_no_users_capability"), true) end
    local token = {}
    self.collectToken = token
    self:say(tr("Admin_Id_Collecting"), false)
    self:updateEnabled()
    P.collectRows(function(rows, err)
        if self.collectToken ~= token then return end   -- cleared: the right or the window went away
        self.collectToken = nil
        if rows == nil then
            self:say(getTextOrNull(T .. "Admin_Id_Err_" .. tostring(err)) or self:errorText(err), true)
        elseif not self.owner:writeAllowed() then
            self:say(self:errorText("forbidden"), true)
        elseif self:sendAction({ action = "import", rows = rows }) then
            self:say(getText(T .. "Admin_Id_Sending", tostring(#rows)), false)
        else
            self:say(tr("Admin_Throttled"), true)
        end
        self:updateEnabled()
    end)
end

-- ----- rebind -----

function Page:conflictLine(c)
    local bound = type(c.bound) == "string" and c.bound or ""
    if bound == "" then
        bound = tr("Admin_Id_BoundNone")
    elseif c.boundExact ~= true then
        bound = getText(T .. "Admin_Id_Approx", bound)
    end
    local reason = getTextOrNull(T .. "Admin_Id_Reason_" .. tostring(c.reason)) or U.unknownText("identity conflict", c.reason)
    return getText(T .. "Admin_Id_ConflictLine", tostring(c.name), bound, tostring(c.whitelist), reason)
end

function Page:onRebind()
    local list = self:conflicts()
    if #list == 0 or self.owner.dialog ~= nil or self.isPending(COMMAND) then return end
    local names, parts = {}, {}
    for i, c in ipairs(list) do
        names[i] = tostring(c.name)
        parts[i] = self:conflictLine(c)
    end
    local warn = tr("Admin_Id_RebindWarn")
    local total = tonumber(self.status.conflictCount) or #list
    if total > #list then warn = warn .. "  " .. getText(T .. "Admin_Id_RebindPartial", tostring(#list), tostring(total)) end
    -- the warning box breaks at every newline (U.setWrappedText): one conflict per line
    local dlg = self.owner:openDialog("identity", {
        title = tr("Admin_Id_RebindTitle"),
        confirm = getText(T .. "Admin_Id_Rebind", tostring(#names)),
        warn = warn .. "\n" .. table.concat(parts, "\n"),
    })
    if dlg ~= nil then dlg.identityNames = names end
end

-- The controller's dialog confirmed with a valid reason. The names are the ones the box listed.
function Page:sendRebind(reason, dlg)
    if not self:sendAction({ action = "rebind", names = dlg.identityNames, reason = reason }) then
        return self.owner:dialogError(dlg, tr("Admin_Throttled"))
    end
    self.sent.dialog = dlg
    dlg.message = nil
    self.owner:layoutDialog()
end

-- ----- replies -----

function Page:matchesReply(args)
    local s = self.sent
    return type(args) == "table" and s ~= nil and not s.answered and args.requestId == s.requestId
end

-- The logins page a reply carried, kept only when it answers the condition on screen: the query
-- (folded the way the server matches it) and the filter. The server clamps the page, so the page
-- is taken from the reply and becomes the question asked.
function Page:adoptLogins(l)
    if type(l) ~= "table" then return end
    if l.error ~= nil then
        self.loginsError = l.error
        return
    end
    if string.lower(tostring(l.query or "")) ~= string.lower(tostring(self.query or ""))
        or l.filter ~= self.filter or type(l.rows) ~= "table" then return end
    self.logins = l
    self.loginsError = nil
    self.page = math.max(1, math.floor(tonumber(l.page) or 1))
    self.askedKey = self:loginsKey()
end

function Page:onReply(args)
    if not self:matchesReply(args) then return end
    local req = self.sent
    req.answered = true
    if type(args.status) == "table" then
        self.status = args.status
        self.last = type(args.last) == "table" and args.last or nil
        self.updatedAt = EC.now()
        self.timedOut = false
    end
    if req.logins then self:adoptLogins(args.logins) end
    local dlg = req.dialog
    local open = dlg ~= nil and self.owner.dialog == dlg
    if args.ok == false then
        local body = self:errorText(args.error, args.name)
        if open then
            self.owner:dialogError(dlg, body)
        else
            self.result = { text = body, error = true }
            self.owner.message = self.result
        end
    elseif req.action == "import" then
        self.result = { text = tr("Admin_Id_ImportDone"), error = false }
        self.owner.message = self.result
    elseif req.action == "rebind" then
        if open then self.owner:closeDialog() end
        local stale = type(args.stale) == "table" and args.stale or {}
        local rebound = tostring(tonumber(args.rebound) or 0)
        -- the skipped part is only said when something was skipped, and then with the names
        local body = getText(T .. "Admin_Id_RebindDoneAll", rebound)
        if #stale > 0 then
            body = getText(T .. "Admin_Id_RebindDone", rebound, tostring(#stale))
                .. "\n" .. tr("Admin_Id_Stale") .. " " .. table.concat(stale, ", ")
        end
        self.result = { text = body, error = #stale > 0 }
        self.owner.message = self.result
    end
    -- the counts on the filter chips and the rows may have moved: the whole page is placed again
    self:layout()
end

-- An answer that never came: its outcome is unknown and it is never re-sent. The next read (asked
-- for here) is what says whether an import or a confirmation went through.
function Page:onTimeout()
    local req = self.sent
    if req == nil or req.answered then return end
    req.timedOut = true
    self.timedOut = true
    self.wanted = true
    self:rebuild()
    self:updateEnabled()
end

-- ----- the overview -----

local function yesNo(v) return tr(v and "Admin_Id_Yes" or "Admin_Id_No") end

-- A server code with its translation; a code this client has no words for reads as "unknown"
-- and goes to the log.
local function codeText(prefix, code)
    return getTextOrNull(T .. prefix .. tostring(code)) or U.unknownText(prefix, code)
end

local function numText(v) return tostring(tonumber(v) or 0) end

-- a blank line between two sections of the reader, never above the first
local function gap(lines) if #lines > 0 then lines[#lines + 1] = "" end end

-- status.merge.blocked reasons in reading order; a code this list lacks is still listed after them
local MERGE_BLOCKERS = { "alias_online", "merge_failed", "frozen", "conflict", "reserved", "unknown_currency",
    "reserved_funds", "live_listing", "auction", "mail_pending", "canonical_moved" }

function Page:stamp(ms)
    return type(ms) == "number" and U.stampText(ms, self.owner.offsetMin) or "-"
end

-- One named list, complete as the reply carried it, with the server's full count and a
-- truncation note when the reply was capped.
function Page:nameList(lines, key, names, count, truncated)
    names = type(names) == "table" and names or {}
    count = tonumber(count) or #names
    lines[#lines + 1] = getText(T .. key, tostring(count))
    if #names > 0 then lines[#lines + 1] = "  " .. table.concat(names, ", ") end
    if truncated then lines[#lines + 1] = "  " .. getText(T .. "Admin_Id_Truncated", tostring(#names), tostring(count)) end
end

-- status.conflicts: what the rebind button confirms, one per line (the count is a pill).
function Page:conflictLines(lines, s)
    local list = self:conflicts()
    local total = tonumber(s.conflictCount) or #list
    if total <= 0 and #list == 0 then return end
    gap(lines)
    lines[#lines + 1] = getText(T .. "Admin_Id_Conflicts", tostring(total))
    for _, c in ipairs(list) do lines[#lines + 1] = "  " .. self:conflictLine(c) end
    if s.conflictsTruncated then
        lines[#lines + 1] = "  " .. getText(T .. "Admin_Id_Truncated", tostring(#list), tostring(total))
    end
end

-- Why the server refused (or only partly took) the companion's export: { code, facts }. The
-- facts are numbers and the file's own field names, which locate the problem in the file.
local EXPORT_DETAIL_ARGS = {
    no_trailer = { "rows" }, bad_line = { "line" }, rows = { "rows", "count" }, bad_row = { "line", "field" },
    reserved = { "skipped", "dropped" }, header_field = { "field" },
}
function P.exportDetailText(r)
    if type(r) ~= "table" or type(r.code) ~= "string" then return nil end
    if r.code == "import_failed" then
        return getText(T .. "Admin_Id_ExportDetail_import_failed", U.adminErrorText(r.error))
    end
    local key = T .. "Admin_Id_ExportDetail_" .. r.code
    -- one lookup with the arguments: probing a %1 key bare makes the Translator log it as missing
    -- its arguments
    local args = {}
    for i, name in ipairs(EXPORT_DETAIL_ARGS[r.code] or {}) do args[i] = tostring(r[name] or "-") end
    local text
    if #args == 2 then text = getTextOrNull(key, args[1], args[2])
    elseif #args == 1 then text = getTextOrNull(key, args[1])
    else text = getTextOrNull(key) end
    return text or U.unknownText("identity export detail", r.code)
end

-- status.export: what the server made of the companion's whitelist file (identity/whitelist.json).
function Page:exportLines(lines, e)
    if type(e) ~= "table" then return end
    gap(lines)
    lines[#lines + 1] = getText(T .. "Admin_Id_Export", codeText("Admin_Id_Export_", e.status or "none"))
    if e.generatedAt ~= nil or e.count ~= nil then
        lines[#lines + 1] = "  " .. getText(T .. "Admin_Id_ExportFile", self:stamp(e.generatedAt), numText(e.count))
    end
    if e.acceptedAt ~= nil then
        lines[#lines + 1] = "  " .. getText(T .. "Admin_Id_ExportAccepted", self:stamp(e.acceptedAt))
    end
    local detail = P.exportDetailText(e.reason)
    if detail ~= nil then
        lines[#lines + 1] = "  " .. getText(T .. "Admin_Id_ExportReason", detail)
    end
end

-- A sandbox option by its translated label (the settings page shows the same one).
local function optionLabel(key)
    return getTextOrNull("Sandbox_MinidoracatEconomy_" .. key) or U.unknownText("sandbox option", key)
end

-- status.merge.blocked: the waiting logins by reason, in reading order, and how many in all.
local function mergeWaiting(m)
    local blocked = type(m.blocked) == "table" and m.blocked or {}
    local parts, listed, total = {}, {}, 0
    local function part(code, n)
        n = tonumber(n) or 0
        listed[code] = true
        if n <= 0 then return end
        total = total + n
        parts[#parts + 1] = getText(T .. "Admin_Tx_Pair", codeText("Admin_Id_Why_", code), tostring(n))
    end
    for _, code in ipairs(MERGE_BLOCKERS) do part(code, blocked[code]) end
    for code, n in pairs(blocked) do
        if not listed[code] then part(code, n) end
    end
    return parts, total
end

-- The overview's numbers as pills, one row per topic in the order a host acts on them: what
-- stops identities, the bindings and imports, the one-account policy, the merge plan. Built with
-- the layout (which places them, wrapping a row instead of cutting a pill); prerender only draws.
function Page:buildPills()
    local pills, s = {}, self.status
    self.pills = pills
    if s == nil then return end
    local row = 1
    local function add(id, label, value, token)
        pills[#pills + 1] = { id = id, row = row, label = label, value = value, token = token or "text" }
    end
    local conflicts = tonumber(s.conflictCount) or #self:conflicts()
    local alerts = tonumber(s.alertCount) or 0
    add("steam", tr("Admin_Id_Steam"), yesNo(s.steam == true))
    add("conflicts", tr("Admin_Id_PillConflicts"), tostring(conflicts), conflicts > 0 and "warn" or nil)
    add("alerts", tr("Admin_Id_PillAlerts"), tostring(alerts), alerts > 0 and "warn" or nil)
    row = 2
    add("bound", tr("Admin_Id_PillBound"), numText(s.bound))
    add("reserved", tr("Admin_Id_PillReserved"), numText(s.reserved))
    if s.imported then
        add("imported", tr("Admin_Id_PillImported"),
            getText(T .. "Admin_Id_PillWhen", self:stamp(s.importedAt), U.actorText(s.importedBy or "-")))
        add("lastImport", tr("Admin_Id_PillLastImport"),
            getText(T .. "Admin_Id_PillWhen", self:stamp(s.lastImportAt), U.actorText(s.lastImportBy or "-")))
    else
        add("imported", tr("Admin_Id_PillImported"), tr("Admin_Id_PillNever"), "warn")
    end
    row = 3
    add("policy", tr("Admin_Id_PillPolicy"), tr(s.multiAccount == true and "Admin_Id_PillPolicyMulti" or "Admin_Id_PillPolicyOne"))
    local m = type(s.multi) == "table" and s.multi or {}
    if (tonumber(m.steamIds) or 0) > 0 then
        local blocked = tonumber(m.blocked) or 0
        add("multiSteam", tr("Admin_Id_PillMultiSteam"), numText(m.steamIds))
        add("multiLogins", tr("Admin_Id_PillMultiLogins"), numText(m.logins))
        add("multiBlocked", tr("Admin_Id_Policy_blocked"), tostring(blocked), blocked > 0 and "warn" or nil)
    end
    local g = s.merge
    if type(g) ~= "table" then return end
    row = 4
    local _, waiting = mergeWaiting(g)
    local ready = tonumber(g.ready) or 0
    add("merge", tr("Admin_Id_PillMerge"), tr(g.enabled == true and "Admin_Id_PillMergeAuto" or "Admin_Id_PillMergePreview"))
    add("mergeGroups", tr("Admin_Id_PillMergeGroups"), numText(g.groups))
    add("merged", tr("Admin_Id_Merge_merged"), numText(g.merged))
    add("ready", tr("Admin_Id_Merge_ready"), tostring(ready), ready > 0 and "positive" or nil)
    add("waiting", tr("Admin_Id_Merge_blocked"), tostring(waiting), waiting > 0 and "warn" or nil)
    add("ineligible", tr("Admin_Id_Merge_ineligible"), numText(g.ineligible))
    if g.planAt ~= nil then add("planAt", tr("Admin_Id_PillPlanAt"), self:stamp(g.planAt)) end
end

-- The pills in one line, for the keyboard caption of the overview (a screen reader never sees
-- the painted pills).
function Page:pillsCaption()
    local parts = {}
    for _, p in ipairs(self.pills or {}) do parts[#parts + 1] = getText(T .. "Admin_Tx_Pair", p.label, p.value) end
    return table.concat(parts, tr("Admin_Id_Sep"))
end

-- status.alerts: the server's last identity alerts, newest first (this uptime only; the count is
-- a pill).
function Page:alertLines(lines, s)
    local list = type(s.alerts) == "table" and s.alerts or {}
    if #list == 0 then return end
    gap(lines)
    lines[#lines + 1] = getText(T .. "Admin_Id_Alerts", numText(s.alertCount), tostring(#list))
    for _, a in ipairs(list) do
        local kind = codeText("Admin_Id_Alert_", a.kind)
        lines[#lines + 1] = "  " .. (a.other ~= nil
            and getText(T .. "Admin_Id_AlertLineOther", self:stamp(a.at), kind, tostring(a.name), tostring(a.other))
            or getText(T .. "Admin_Id_AlertLine", self:stamp(a.at), kind, tostring(a.name)))
    end
end

-- This uptime's last import summary with its name lists, when there was one.
function Page:lastImportLines(lines)
    local last = self.last
    if last == nil then return end
    gap(lines)
    lines[#lines + 1] = getText(T .. "Admin_Id_LastTitle", self:stamp(last.at), U.actorText(last.by or "-"))
    lines[#lines + 1] = getText(T .. "Admin_Id_LastCounts", tostring(last.rows or 0), tostring(last.bound or 0),
        tostring(last.same or 0), tostring(last.ignored or 0), tostring(last.conflicts or 0))
    self:nameList(lines, "Admin_Id_Missing", last.missing, last.missingCount, last.missingTruncated)
    self:nameList(lines, "Admin_Id_Reserved", last.reserved, last.reservedCount, last.reservedTruncated)
    self:nameList(lines, "Admin_Id_Collisions", last.collisions, last.collisionCount, last.collisionsTruncated)
end

-- The reader under the pills: only what has to be read whole, in the order a host acts on it --
-- a binding file the server cannot read, the conflicts the rebind button confirms, why merges
-- wait, the alerts, the companion's file, the last import. The policy and terms are in the help.
function Page:overviewText()
    local lines = {}
    if self.result ~= nil then lines[#lines + 1] = self.result.text end
    local s = self.status
    if s == nil then
        gap(lines)
        lines[#lines + 1] = tr(self.timedOut and "Admin_Accounts_Timeout" or "Admin_Loading")
        return table.concat(lines, "\n")
    end
    if s.unreadable then gap(lines); lines[#lines + 1] = tr("Admin_Id_Unreadable") end
    if s.damaged then gap(lines); lines[#lines + 1] = tr("Admin_Id_Damaged") end
    self:conflictLines(lines, s)
    if type(s.merge) == "table" then
        local parts = mergeWaiting(s.merge)
        if #parts > 0 then gap(lines); lines[#lines + 1] = getText(T .. "Admin_Id_MergeBlocked", table.concat(parts, tr("Admin_Id_Sep"))) end
    end
    local multi = type(s.multi) == "table" and tonumber(s.multi.steamIds) or 0
    local merge = type(s.merge) == "table" and tonumber(s.merge.groups) or 0
    if (multi or 0) > 0 or (merge or 0) > 0 then
        gap(lines)
        lines[#lines + 1] = getText(T .. "Admin_Id_SeeLogins", tr("Admin_Id_View_logins"))
    end
    self:alertLines(lines, s)
    self:exportLines(lines, s.export)
    self:lastImportLines(lines)
    return table.concat(lines, "\n")
end

-- The help window: the policy and merge mode in full sentences with their sandbox options, what
-- to change for several accounts per person, how names are bound before an import, the terms.
function Page:helpParts()
    local multi, merge = optionLabel("IdentityMultiAccount"), optionLabel("IdentityAutoMerge")
    local s = self.status
    local policy, mergeMode
    if s ~= nil then
        policy = getText(T .. (s.multiAccount == true and "Admin_Id_PolicyMulti" or "Admin_Id_PolicyOne"), multi)
        if type(s.merge) == "table" then
            mergeMode = getText(T .. (s.merge.enabled == true and "Admin_Id_MergeOn" or "Admin_Id_MergeOff"), merge)
        end
    end
    return policy, mergeMode, getText(T .. "Admin_Id_MultiHint", multi, merge)
end

function Page:helpText()
    local policy, mergeMode, hint = self:helpParts()
    local parts = {}
    if policy ~= nil then parts[#parts + 1] = policy end
    if mergeMode ~= nil then parts[#parts + 1] = mergeMode end
    parts[#parts + 1] = hint
    parts[#parts + 1] = tr("Admin_Id_HelpBinding")
    parts[#parts + 1] = tr("Admin_Id_HelpTerms")
    return table.concat(parts, "\n\n")
end

function Page:helpCard()
    local policy, mergeMode, hint = self:helpParts()
    local sections = {}
    if policy ~= nil then sections[#sections + 1] = { title = tr("Admin_Id_Col_Policy"), lines = { { text = policy } } } end
    if mergeMode ~= nil then sections[#sections + 1] = { title = tr("Admin_Id_Col_Merge"), lines = { { text = mergeMode } } } end
    sections[#sections + 1] = { title = tr("PCard_Id_Multi"), lines = { { text = hint } } }
    sections[#sections + 1] = { title = tr("PCard_Id_Binding"), lines = { { text = tr("Admin_Id_HelpBinding") } } }
    sections[#sections + 1] = { title = tr("PCard_Id_Terms"), lines = { { text = tr("Admin_Id_HelpTerms") } } }
    return { source = tr("Admin_Id_HelpTitle"), sourceIcon = "document", sections = sections, techOpen = true }
end

function Page:onHelp()
    if D.isOpen(self, HELP_KEY) then
        D.close(self)
    else
        -- the shared window leaves the row it showed: a later reply must not touch it as a record
        self.selectedName = nil
        D.open(self, HELP_KEY, tr("Admin_Id_HelpTitle"), self:helpText(), nil, self:helpCard())
    end
    self:invalidateKeyboard()
end

-- ----- the logins list -----

local function policyText(state)
    if state == nil then return tr("Admin_Id_BoundNone") end
    return codeText("Admin_Id_Policy_", state)
end

-- The merge cell: the state, and for a wait or a refusal its first reason (and how many more).
local function mergeText(rec)
    local state = rec.merge
    if state == nil then return tr("Admin_Id_BoundNone") end
    local why = type(rec.why) == "table" and rec.why or {}
    if (state == "blocked" or state == "ineligible") and #why > 0 then
        local first = codeText("Admin_Id_Why_", why[1])
        if #why > 1 then return getText(T .. "Admin_Id_Merge_" .. state .. "More", first, tostring(#why - 1)) end
        return getText(T .. "Admin_Id_Merge_" .. state .. "Why", first)
    end
    return codeText("Admin_Id_Merge_", state)
end

-- What the policy and the merge plan make of one login, as full sentences: the detail text and
-- the detail card both read these.
function Page:policySentence(rec, account)
    local multiOption = optionLabel("IdentityMultiAccount")
    if rec.policy == "blocked" then
        return getText(T .. "Admin_Id_Detail_Policy_blocked", multiOption, account)
    elseif rec.policy == "allowed" then
        return getText(T .. "Admin_Id_Detail_Policy_allowed", multiOption)
    elseif rec.policy == "merged" then
        return getText(T .. "Admin_Id_Detail_Policy_merged", account)
    elseif rec.policy == "primary" then
        return tr("Admin_Id_Detail_Policy_primary")
    end
    return tr("Admin_Id_Detail_Policy_none")
end

function Page:mergeSentences(rec)
    local lines = {}
    local target = rec.into or rec.account or tr("Admin_Id_BoundNone")
    local why = {}
    for i, code in ipairs(type(rec.why) == "table" and rec.why or {}) do why[i] = codeText("Admin_Id_Why_", code) end
    local whyText = table.concat(why, tr("Admin_Id_Sep"))
    if rec.merge == "ready" then
        lines[#lines + 1] = getText(T .. "Admin_Id_Detail_Merge_ready", target)
    elseif rec.merge == "blocked" then
        lines[#lines + 1] = getText(T .. "Admin_Id_Detail_Merge_blocked", whyText)
    elseif rec.merge == "ineligible" then
        lines[#lines + 1] = getText(T .. "Admin_Id_Detail_Merge_ineligible", whyText)
    elseif rec.merge == "merged" then
        lines[#lines + 1] = getText(T .. "Admin_Id_Detail_Merge_merged", target)
    elseif rec.merge == "canonical" then
        lines[#lines + 1] = tr("Admin_Id_Detail_Merge_canonical")
    else
        lines[#lines + 1] = tr("Admin_Id_Detail_Merge_none")
    end
    if rec.into ~= nil then lines[#lines + 1] = getText(T .. "Admin_Id_Detail_Into", tostring(rec.into)) end
    if (rec.merge == "ready" or rec.merge == "blocked") and not self:merging() then
        lines[#lines + 1] = getText(T .. "Admin_Id_Detail_Preview", optionLabel("IdentityAutoMerge"))
    end
    return lines
end

function Page:merging()
    return self.status ~= nil and type(self.status.merge) == "table" and self.status.merge.enabled == true
end

function Page:planAtText()
    local planAt = self.logins and self.logins.planAt or nil
    if planAt == nil then return nil end
    return getText(T .. "Admin_Id_MergePlanAt", self:stamp(planAt))
end

-- One login spelled out for the detail window: its Steam account's logins, what the policy and
-- the merge plan make of it, and the plan's time. Every reason in full, none cut.
function Page:detailText(rec)
    local lines = {}
    local account = rec.account or tr("Admin_Id_BoundNone")
    lines[#lines + 1] = getText(T .. "Admin_Id_Detail_Account", account)
    local group = type(rec.group) == "table" and rec.group or {}
    local count = tonumber(rec.logins) or #group
    lines[#lines + 1] = getText(T .. "Admin_Id_Detail_Logins", tostring(count))
    for _, name in ipairs(group) do
        lines[#lines + 1] = "  " .. (name == rec.account and getText(T .. "Admin_Id_Detail_Primary", name) or tostring(name))
    end
    if count > #group then lines[#lines + 1] = "  " .. getText(T .. "Admin_Id_Truncated", tostring(#group), tostring(count)) end
    lines[#lines + 1] = ""
    lines[#lines + 1] = self:policySentence(rec, account)
    lines[#lines + 1] = ""
    for _, line in ipairs(self:mergeSentences(rec)) do lines[#lines + 1] = line end
    local planAt = self:planAtText()
    if planAt ~= nil then lines[#lines + 1] = planAt end
    return table.concat(lines, "\n")
end

-- The same login as a detail card: the main account and the Steam account's logins as rows, the
-- two states as chips, and the policy and merge sentences as sections.
function Page:detailCard(rec)
    local account = rec.account or tr("Admin_Id_BoundNone")
    local group = type(rec.group) == "table" and rec.group or {}
    local count = tonumber(rec.logins) or #group
    local names = {}
    for i, name in ipairs(group) do
        names[i] = name == rec.account and getText(T .. "Admin_Id_Detail_Primary", name) or tostring(name)
    end
    local mergeTitle = tr(self:merging() and "Admin_Id_Col_Merge" or "Admin_Id_Col_MergePreview")
    local mergeLines = {}
    for i, line in ipairs(self:mergeSentences(rec)) do mergeLines[i] = { text = line } end
    return {
        sourceIcon = "lock", iconKey = "users", name = tostring(rec.name),
        chips = {
            { label = tr("Admin_Id_Col_Policy"), value = policyText(rec.policy), token = POLICY_TOKENS[rec.policy] or "text" },
            { label = mergeTitle, value = mergeText(rec), token = MERGE_TOKENS[rec.merge] or "text" },
        },
        rows = {
            { label = tr("Admin_Id_Col_Account"), value = account },
            { label = tr("Admin_Id_Col_Login"), value = #names > 0 and table.concat(names, tr("Admin_Id_Sep")) or tostring(count),
                note = count > #group and getText(T .. "Admin_Id_Truncated", tostring(#group), tostring(count)) or nil },
        },
        sections = {
            { title = tr("Admin_Id_Col_Policy"), lines = { { text = self:policySentence(rec, account) } } },
            { title = mergeTitle, lines = mergeLines },
        },
        note = self:planAtText(),
        techOpen = true,
    }
end

local function detailKey(name) return "identity:" .. tostring(name) end

function Page:onRow(item)
    if item == nil or not self.owner:readAllowed() then return end
    self.selectedName = item.id
    D.open(self, detailKey(item.id), getText(T .. "Admin_Id_Detail_Title", item.id), self:detailText(item.rec),
        nil, self:detailCard(item.rec))
end

-- The merge column's title says whether merging is on: off, every state in it is a preview.
function Page:columnTitles()
    local merging = self.status ~= nil and type(self.status.merge) == "table" and self.status.merge.enabled == true
    return { tr("Admin_Id_Col_Login"), tr("Admin_Id_Col_Account"), tr("Admin_Id_Col_Policy"),
        tr(merging and "Admin_Id_Col_Merge" or "Admin_Id_Col_MergePreview") }
end

-- Four columns sharing the row; a cell longer than its column is cut on screen and read whole in
-- the detail window.
function Page:columns(inner)
    local titles = self:columnTitles()
    local avail = math.max(80, inner - PAD)
    local cols, x = {}, PAD
    for i, share in ipairs(SHARES) do
        local width = math.max(24, math.floor(avail * share))
        cols[i] = { x = x, width = math.max(16, width - 8), title = titles[i] }
        x = x + width
    end
    return cols
end

function Page:rebuildRows()
    local l = self.logins
    local rows, selected = {}, nil
    for _, rec in ipairs(l ~= nil and l.rows or {}) do
        if type(rec) == "table" and type(rec.name) == "string" then
            rows[#rows + 1] = {
                id = rec.name, rec = rec,
                cells = { rec.name, rec.account or tr("Admin_Id_BoundNone"), policyText(rec.policy), mergeText(rec) },
                tokens = { "text", "textMuted", POLICY_TOKENS[rec.policy] or "textMuted", MERGE_TOKENS[rec.merge] or "textMuted" },
            }
            if rec.name == self.selectedName then selected = #rows end
        end
    end
    self.rows = rows
    self.list:setItems(rows)
    self.list:setSelectedIndex(selected)
    -- the record window belongs to the row that opened it: a login no longer on this page takes
    -- the window with it, one still listed has its text replaced while the window is open
    if self.selectedName ~= nil then
        if selected == nil then
            self.selectedName = nil
            D.close(self)
        else
            D.update(self, detailKey(self.selectedName), getText(T .. "Admin_Id_Detail_Title", self.selectedName),
                self:detailText(rows[selected].rec), self:detailCard(rows[selected].rec))
        end
    end
end

function Page:rebuild()
    U.setWrappedText(self.reader, self:overviewText(), self.reader.width)
    U.setButtonTitle(self.rebindButton, getText(T .. "Admin_Id_Rebind", tostring(#self:conflicts())))
    self:rebuildRows()
    if D.isOpen(self, HELP_KEY) then D.update(self, HELP_KEY, tr("Admin_Id_HelpTitle"), self:helpText(), self:helpCard()) end
end

-- What the list area says when it has no row to show, as exactly one state.
function Page:listStatus()
    if self.loginsError ~= nil then return "failed" end
    local l = self.logins
    if l == nil then return self.timedOut and "timeout" or "loading" end
    if #(self.rows or {}) > 0 then return "rows" end
    if self.status ~= nil and self.status.steam ~= true then return "notSteam" end
    if l.query == nil and type(l.counts) == "table" and tonumber(l.counts.all) == 0 then return "none" end
    return "empty"
end

function Page:statusText(state)
    if state == "loading" then return tr("Admin_Loading") end
    if state == "timeout" then return tr("Admin_Accounts_Timeout") end
    if state == "failed" then return U.adminErrorText(self.loginsError) end
    if state == "notSteam" then return tr("Admin_Id_Logins_NotSteam") end
    if state == "none" then return tr("Admin_Id_Logins_None") end
    if state == "empty" then return tr("Admin_Accounts_Empty") end
    return nil
end

-- "1-50 of 643 (page 1/13)": which slice of the complete sort is on screen, in the reply's numbers.
function Page:summaryText()
    local l = self.logins
    if l == nil then return nil end
    local shown = #(self.rows or {})
    local per = math.max(1, math.floor(tonumber(l.per) or 50))
    local first = shown > 0 and ((self.page - 1) * per + 1) or 0
    local last = shown > 0 and (first + shown - 1) or 0
    return getText(T .. "Admin_Accounts_Summary", tostring(first), tostring(last), tostring(tonumber(l.total) or 0),
        tostring(self.page), tostring(math.max(1, math.floor(tonumber(l.pages) or 1))))
end

-- ----- geometry / painting -----

-- Chips placed left to right at their natural width, starting a new line instead of cutting a
-- label: a count on a chip is never the part that gets lost. Returns the bottom of the last line.
local function flowChips(buttons, visible, x0, y, right, height)
    local x, rowY = x0, y
    for _, b in ipairs(buttons) do
        b:setVisible(visible)
        if visible then
            local bw = math.min(textWidth(b.fullTitle) + 20, math.max(24, right - x0))
            if x > x0 and x + bw > right then
                x, rowY = x0, rowY + height + 4
            end
            b:setWidth(bw); b:setHeight(height); b:setX(x); b:setY(rowY)
            U.setButtonTitle(b, b.fullTitle)
            x = x + bw + 6
        end
    end
    return rowY + height
end

function Page:layout()
    local w, h = self.width, self.height
    local visible = self:getIsVisible()
    local ch, eh = chipH(), entryH()
    local g = {}
    self.g = g
    self.titleH = math.max(CARD_TITLE_H, fontH.medium + 8)
    local y = self.titleH + 4
    local inner = math.max(80, w - PAD * 2)
    -- row 1: the two views and the help at the leading edge, the page's two actions at the trailing
    -- one; no chip takes more than a quarter of the row, so one long translation cannot push another off
    local quarter = math.max(40, math.floor((inner - 18) / 4))
    local function place(b, label, x)
        local bw = math.min(textWidth(label) + 24, quarter)
        b:setVisible(visible)
        b:setWidth(bw); b:setHeight(ch)
        b:setX(x); b:setY(y)
        U.setButtonTitle(b, b.fullTitle)
        return bw
    end
    local x = PAD
    for _, b in ipairs(self.viewButtons) do x = x + place(b, b.fullTitle, x) + 6 end
    place(self.helpButton, self.helpButton.fullTitle, x + 6)
    local rw = math.min(textWidth(getText(T .. "Admin_Id_Rebind", "000")) + 24, quarter)
    local iw = math.min(textWidth(self.importButton.fullTitle) + 24, quarter)
    place(self.rebindButton, getText(T .. "Admin_Id_Rebind", "000"), w - PAD - rw)
    place(self.importButton, self.importButton.fullTitle, w - PAD - rw - 6 - iw)
    local top = y + ch + 6

    local overview = self.view ~= "logins"
    self.reader:setVisible(visible and overview)
    if overview then
        -- the pills: a topic starts a new row, a pill that does not fit starts the next one
        self:buildPills()
        local px, py, row = PAD, top, nil
        for _, p in ipairs(self.pills) do
            p.w = U.pillWidth(p.label, p.value)
            if row ~= nil and (p.row ~= row or px + p.w > w - PAD) then px, py = PAD, py + U.CHIP_H + 6 end
            p.x, p.y, row = px, py, p.row
            px = px + p.w + 6
        end
        local readerY = row ~= nil and py + U.CHIP_H + 8 or top
        self.reader:setX(PAD); self.reader:setY(readerY)
        self.reader:setWidth(inner)
        self.reader:setHeight(math.max(lineH() * 2, h - PAD - readerY))
    end

    -- the logins list: search and the slice with the page chips, the filter chips, the table
    local on = visible and not overview
    if not on and self.searchEntry:isFocused() then self.searchEntry:unfocus() end
    self.searchEntry:setVisible(on)
    self.searchEntry:setX(PAD); self.searchEntry:setY(top)
    -- the placeholder is the field's only label: room for all of it, up to 40% of the page
    local searchW = math.max(math.min(280, math.floor(w * 0.3)), textWidth(tr("Admin_Id_Search")) + 30)
    self.searchEntry:setWidth(math.max(120, math.min(searchW, math.floor(w * 0.4))))
    self.searchEntry:setHeight(eh)
    local nextW = math.min(textWidth(self.nextButton.fullTitle) + 24, math.floor(w * 0.2))
    local prevW = math.min(textWidth(self.prevButton.fullTitle) + 24, math.floor(w * 0.2))
    local chipY = top + math.floor((eh - ch) / 2)
    self.nextButton:setVisible(on)
    self.nextButton:setWidth(nextW); self.nextButton:setHeight(ch)
    self.nextButton:setX(w - PAD - nextW); self.nextButton:setY(chipY)
    U.setButtonTitle(self.nextButton, self.nextButton.fullTitle)
    self.prevButton:setVisible(on)
    self.prevButton:setWidth(prevW); self.prevButton:setHeight(ch)
    self.prevButton:setX(self.nextButton.x - 6 - prevW); self.prevButton:setY(chipY)
    U.setButtonTitle(self.prevButton, self.prevButton.fullTitle)
    g.summaryX = PAD + self.searchEntry.width + PAD
    g.summaryY = top + math.floor((eh - fontH.small) / 2)
    g.summaryW = math.max(0, self.prevButton.x - PAD - g.summaryX)

    -- the counts on the chips change their width: the labels are set before the chips are measured
    local counts = self.logins ~= nil and type(self.logins.counts) == "table" and self.logins.counts or {}
    for _, b in ipairs(self.filterButtons) do
        local n = counts[b.internal]
        b.fullTitle = getText(T .. "Admin_Id_Filter_" .. b.internal, n ~= nil and tostring(n) or "-")
    end
    local filterY = top + eh + 6
    local labelW = textWidth(tr("Admin_Id_FilterLabel")) + 8
    g.filterLabelX, g.filterLabelY = PAD, filterY + math.floor((ch - fontH.small) / 2)
    local filterBottom = flowChips(self.filterButtons, on, PAD + labelW, filterY, w - PAD, ch)

    g.headerY = filterBottom + 6
    g.headerH = lineH() + 4
    local listY = g.headerY + g.headerH
    local listH = math.max(self.list.rowHeight, h - PAD - listY)
    U.placeList(self.list, on, PAD, listY, inner, listH)
    self.list.cols = self:columns(inner - GUTTER)
    self:rebuild()
    self:updateEnabled()
end

function Page:resize(width, height)
    if self.width ~= width then self:setWidth(width) end
    if self.height ~= height then self:setHeight(height) end
    self:layout()
end

-- Hidden, the page gives up its text focus and its record window; what it read is kept, so coming
-- back finds the same view, condition and page.
function Page:setVisible(visible)
    local was = self:getIsVisible()
    ISPanel.setVisible(self, visible)
    -- P.create hides the page before instantiate built the controls
    if self.list == nil then return end
    if not visible then
        pcall(self.searchEntry.unfocus, self.searchEntry)
        self.selectedName = nil
        D.close(self)
    end
    if was ~= visible then self:layout() end
end

function Page:prerender()
    local w, h = self.width, self.height
    U.theme:fill(self, 0, 0, w, h, "surface", "rect", 1)
    U.card(self, 0, 0, w, h, fitText(tr("Admin_Tab_Identity"), math.max(20, w - PAD * 2), UIFont.Medium), self.titleH)
    if self.view ~= "logins" then
        local pills = self.pills
        if pills == nil then return end
        for i = 1, #pills do
            local p = pills[i]
            U.drawPill(self, p.x, p.y, p.label, p.value, p.token)
        end
        return
    end
    if self.g == nil then return end
    local g = self.g
    local summary = self:summaryText()
    if summary then text(self, fitText(summary, g.summaryW), g.summaryX, g.summaryY, "textFaint") end
    text(self, tr("Admin_Id_FilterLabel"), g.filterLabelX, g.filterLabelY, "textMuted")
    local list = self.list
    fill(self, list.x, g.headerY, list.width, g.headerH, "well", "rect")
    local hy = g.headerY + math.floor((g.headerH - fontH.small) / 2)
    for _, col in ipairs(list.cols or {}) do
        text(self, fitText(col.title, col.width), list.x + col.x, hy, "textMuted")
    end
    -- an empty list says why, wrapped rather than cut
    local state = self:listStatus()
    local body = self:statusText(state)
    if body then
        local token = (state == "failed" or state == "timeout") and "errorText" or "textFaint"
        local ty = list.y + 4
        for _, line in ipairs(U.wrapText(body, math.max(40, list.width - PAD * 2), 4)) do
            text(self, line, list.x + PAD, ty, token)
            ty = ty + lineH()
        end
    end
end

function Page:render() end

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
    local free = not modal and not busy and self.collectToken == nil
    local write = owner:writeAllowed()
    local live = owner:readAllowed() and not modal
    self.importButton:setEnable(write and free)
    self.rebindButton:setEnable(write and free and #self:conflicts() > 0)
    for _, b in ipairs(self.viewButtons) do b:setEnable(live) end
    self.helpButton:setEnable(not modal)
    setEntryEditable(self.searchEntry, live)
    for _, b in ipairs(self.filterButtons) do b:setEnable(live and not busy) end
    local pages = self.logins and math.max(1, math.floor(tonumber(self.logins.pages) or 1)) or 1
    self.prevButton:setEnable(live and not busy and self.page > 1)
    self.nextButton:setEnable(live and not busy and self.page < pages)
    self.list.optionsDisabled = not live
end

function Page:keyboardTargets()
    if not self:getIsVisible() then return {} end
    local out = {
        { kind = "group", label = tr("Admin_Id_Views"), controls = self.viewButtons },
        { kind = "group", label = tr("Admin_Tab_Identity"), controls = { self.helpButton, self.importButton, self.rebindButton } },
    }
    if self.view ~= "logins" then
        local caption = tr("Admin_Id_View_overview")
        local pills = self:pillsCaption()
        if pills ~= "" then caption = caption .. "  " .. pills end
        out[#out + 1] = { kind = "scroll", label = caption, control = self.reader, focusable = false }
        return out
    end
    out[#out + 1] = { kind = "entry", label = tr("Admin_Id_Search"), control = self.searchEntry }
    out[#out + 1] = { kind = "group", label = tr("Admin_Id_FilterLabel"), controls = self.filterButtons }
    out[#out + 1] = { kind = "group", label = tr("Filter_PageNav"), controls = { self.prevButton, self.nextButton } }
    -- the caption carries the slice in full: a keyboard user never sees the fitted line
    local caption = tr("Admin_Id_View_logins")
    local summary = self:summaryText()
    if summary ~= nil then caption = caption .. "  " .. summary end
    out[#out + 1] = { kind = "list", label = caption, control = self.list }
    return out
end

-- ----- lifecycle -----

-- The right to read went away: everything read goes, and a collection still waiting is disowned
-- (its rows are never sent).
function Page:clear()
    self.status, self.last, self.result, self.updatedAt = nil, nil, nil, nil
    self.sent, self.collectToken, self.wanted = nil, nil, nil
    self.logins, self.loginsError, self.askedKey, self.timedOut = nil, nil, nil, false
    self.page, self.selectedName = 1, nil
    D.close(self)
    self:layout()
end

function Page:dispose()
    self:clear()
    pcall(self.searchEntry.unfocus, self.searchEntry)
end

function P.create(owner, send, isPending, newRequestId)
    local o = ISPanel:new(0, 0, 600, 400)
    setmetatable(o, Page)
    o.background = false
    o.owner = owner
    o.send, o.isPending, o.newRequestId = send, isPending, newRequestId
    o.view = "overview"
    o.filter = "all"
    o.page = 1
    o.querySeen = ""
    o.timedOut = false
    o:initialise()
    o:instantiate()
    o:setVisible(false)
    return o
end

return P
