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

local EC = MinidoracatEconomy
local C = EC.Client
local U = C.UI

local P = {}
C.AdminIdentity = P

local PAD, T = U.PAD, U.T
local CARD_TITLE_H = U.CARD_TITLE_H
local fontH = U.fontH
local text, fitText, textWidth = U.text, U.fitText, U.textWidth

local COMMAND = "admin.identity"
local SID_EXACT = "^7656119%d%d%d%d%d%d%d%d%d%d$"   -- the server's Id.SID_EXACT
local USERS_TIMEOUT_MS = 15000

local function tr(key) return getText(T .. key) end
local function lineH() return fontH.small + 6 end
local function chipH() return math.max(24, fontH.small + 10) end

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
    local function chip(label, handler)
        local b = U.Button.create(0, 0, 100, chipH(), label, self, handler, "primary")
        self:addChild(b)
        return b
    end
    self.importButton = chip(tr("Admin_Id_Import"), Page.onImport)
    self.rebindButton = chip(getText(T .. "Admin_Id_Rebind", "0"), Page.onRebind)
    self.reader = U.newReader(self, 400, 200)
    self:layout()
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

function Page:sendAction(args)
    if self.isPending(COMMAND) then return false end
    args.requestId = self.newRequestId()
    if not self.send(COMMAND, args) then return false end
    self.sent = { requestId = args.requestId, action = args.action }
    self.owner:updateEnabled()
    return true
end

function Page:live()
    return self:getIsVisible() and self.owner:readAllowed()
end

-- The read this page is owed goes out when the shared slot is free; a collection in progress
-- holds it back, so the import it is gathering for never finds the slot taken.
function Page:pump()
    if not self.wanted or self.collectToken ~= nil or not self:live() then return end
    if self:sendAction({ action = "status" }) then self.wanted = false end
end

function Page:refresh()
    self.wanted = true
    self:pump()
end

function Page:tick(now)
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
    local reason = getTextOrNull(T .. "Admin_Id_Reason_" .. tostring(c.reason)) or tostring(c.reason)
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
    -- the warning box wraps on width; a literal newline is not a line break to it
    local dlg = self.owner:openDialog("identity", {
        title = tr("Admin_Id_RebindTitle"),
        confirm = getText(T .. "Admin_Id_Rebind", tostring(#names)),
        warn = warn .. "  " .. table.concat(parts, "  |  "),
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

function Page:onReply(args)
    if not self:matchesReply(args) then return end
    local req = self.sent
    req.answered = true
    if type(args.status) == "table" then
        self.status = args.status
        self.last = type(args.last) == "table" and args.last or nil
        self.updatedAt = EC.now()
    end
    local dlg = req.dialog
    local open = dlg ~= nil and self.owner.dialog == dlg
    if args.ok == false then
        local body = self:errorText(args.error, args.name)
        if open then
            self.owner:dialogError(dlg, body)
        else
            self:say(body, true)
        end
    elseif req.action == "import" then
        self:say(tr("Admin_Id_ImportDone"), false)
    elseif req.action == "rebind" then
        if open then self.owner:closeDialog() end
        local stale = type(args.stale) == "table" and args.stale or {}
        local body = getText(T .. "Admin_Id_RebindDone", tostring(tonumber(args.rebound) or 0), tostring(#stale))
        if #stale > 0 then body = body .. "\n" .. tr("Admin_Id_Stale") .. " " .. table.concat(stale, ", ") end
        self:say(body, #stale > 0)
    end
    self:rebuild()
    self:updateEnabled()
end

-- An answer that never came: its outcome is unknown and it is never re-sent. The next read (asked
-- for here) is what says whether an import or a confirmation went through.
function Page:onTimeout()
    local req = self.sent
    if req == nil or req.answered then return end
    req.timedOut = true
    self.wanted = true
    self:updateEnabled()
end

-- ----- the reader -----

local function yesNo(v) return tr(v and "Admin_Id_Yes" or "Admin_Id_No") end

-- A server code with its translation, or the code itself when this client has none for it.
local function codeText(prefix, code)
    return getTextOrNull(T .. prefix .. tostring(code)) or tostring(code)
end

local function numText(v) return tostring(tonumber(v) or 0) end

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

-- status.export: what the server made of the companion's whitelist file (identity/whitelist.json).
function Page:exportLines(lines, e)
    if type(e) ~= "table" then return end
    lines[#lines + 1] = ""
    lines[#lines + 1] = getText(T .. "Admin_Id_Export", codeText("Admin_Id_Export_", e.status or "none"))
    if e.generatedAt ~= nil or e.count ~= nil then
        lines[#lines + 1] = "  " .. getText(T .. "Admin_Id_ExportFile", self:stamp(e.generatedAt), numText(e.count))
    end
    if e.acceptedAt ~= nil then
        lines[#lines + 1] = "  " .. getText(T .. "Admin_Id_ExportAccepted", self:stamp(e.acceptedAt))
    end
    if e.reason ~= nil and e.reason ~= "" then
        lines[#lines + 1] = "  " .. getText(T .. "Admin_Id_ExportReason", tostring(e.reason))
    end
end

-- status.merge: the account merge plan. With IdentityAutoMerge off it is a preview only; the
-- group list is capped by the server and says so when it is.
function Page:mergeLines(lines, m)
    if type(m) ~= "table" then return end
    local option = getTextOrNull("Sandbox_MinidoracatEconomy_IdentityAutoMerge") or "IdentityAutoMerge"
    lines[#lines + 1] = ""
    lines[#lines + 1] = getText(T .. (m.enabled == true and "Admin_Id_MergeOn" or "Admin_Id_MergeOff"), option)
    local blocked = type(m.blocked) == "table" and m.blocked or {}
    local parts, listed, total = {}, {}, 0
    local function part(code, n)
        n = tonumber(n) or 0
        listed[code] = true
        if n <= 0 then return end
        total = total + n
        parts[#parts + 1] = codeText("Admin_Id_Why_", code) .. " " .. tostring(n)
    end
    for _, code in ipairs(MERGE_BLOCKERS) do part(code, blocked[code]) end
    for code, n in pairs(blocked) do
        if not listed[code] then part(code, n) end
    end
    lines[#lines + 1] = "  " .. getText(T .. "Admin_Id_MergeCounts", numText(m.groups), numText(m.aliases),
        numText(m.merged), numText(m.ready), tostring(total), numText(m.ineligible))
    if #parts > 0 then lines[#lines + 1] = "  " .. getText(T .. "Admin_Id_MergeBlocked", table.concat(parts, ", ")) end
    if m.planAt ~= nil then lines[#lines + 1] = "  " .. getText(T .. "Admin_Id_MergePlanAt", self:stamp(m.planAt)) end
    local list = type(m.list) == "table" and m.list or {}
    for _, g in ipairs(list) do
        local members = {}
        for _, mem in ipairs(type(g.members) == "table" and g.members or {}) do
            local state = codeText("Admin_Id_State_", mem.state)
            members[#members + 1] = mem.reason ~= nil
                and getText(T .. "Admin_Id_MemberWhy", tostring(mem.name), state, codeText("Admin_Id_Why_", mem.reason))
                or getText(T .. "Admin_Id_Member", tostring(mem.name), state)
        end
        lines[#lines + 1] = "  " .. getText(T .. "Admin_Id_MergeGroup", tostring(g.account), table.concat(members, ", "))
    end
    local groups = tonumber(m.groups) or #list
    if m.truncated or #list < groups then
        lines[#lines + 1] = "  " .. getText(T .. "Admin_Id_Truncated", tostring(#list), tostring(groups))
    end
end

function Page:rebuild()
    local lines = {}
    if self.result ~= nil then
        lines[#lines + 1] = self.result.text
        lines[#lines + 1] = ""
    end
    local s = self.status
    if s == nil then
        lines[#lines + 1] = tr("Admin_Loading")
    else
        lines[#lines + 1] = getText(T .. "Admin_Id_Steam", yesNo(s.steam == true))
        if s.unreadable then lines[#lines + 1] = tr("Admin_Id_Unreadable") end
        if s.damaged then lines[#lines + 1] = tr("Admin_Id_Damaged") end
        if s.imported then
            lines[#lines + 1] = getText(T .. "Admin_Id_Imported", self:stamp(s.importedAt), tostring(s.importedBy or "-"))
            lines[#lines + 1] = getText(T .. "Admin_Id_LastImport", self:stamp(s.lastImportAt), tostring(s.lastImportBy or "-"))
        else
            lines[#lines + 1] = tr("Admin_Id_NotImported")
        end
        lines[#lines + 1] = getText(T .. "Admin_Id_Counts", tostring(s.bound or 0), tostring(s.reserved or 0))
        self:exportLines(lines, s.export)
        local last = self.last
        lines[#lines + 1] = ""
        if last == nil then
            lines[#lines + 1] = tr("Admin_Id_NoLast")
        else
            lines[#lines + 1] = getText(T .. "Admin_Id_LastTitle", self:stamp(last.at), tostring(last.by or "-"))
            lines[#lines + 1] = getText(T .. "Admin_Id_LastCounts", tostring(last.rows or 0), tostring(last.bound or 0),
                tostring(last.same or 0), tostring(last.ignored or 0), tostring(last.conflicts or 0))
            self:nameList(lines, "Admin_Id_Missing", last.missing, last.missingCount, last.missingTruncated)
            self:nameList(lines, "Admin_Id_Reserved", last.reserved, last.reservedCount, last.reservedTruncated)
            self:nameList(lines, "Admin_Id_Collisions", last.collisions, last.collisionCount, last.collisionsTruncated)
        end
        local list = self:conflicts()
        local total = tonumber(s.conflictCount) or #list
        lines[#lines + 1] = ""
        lines[#lines + 1] = getText(T .. "Admin_Id_Conflicts", tostring(total))
        for _, c in ipairs(list) do lines[#lines + 1] = "  " .. self:conflictLine(c) end
        if s.conflictsTruncated then
            lines[#lines + 1] = "  " .. getText(T .. "Admin_Id_Truncated", tostring(#list), tostring(total))
        end
        self:mergeLines(lines, s.merge)
    end
    U.setWrappedText(self.reader, table.concat(lines, "\n"), self.reader.width)
    U.setButtonTitle(self.rebindButton, getText(T .. "Admin_Id_Rebind", tostring(#self:conflicts())))
end

-- ----- geometry / painting -----

function Page:layout()
    local w, h = self.width, self.height
    local visible = self:getIsVisible()
    local ch = chipH()
    self.titleH = math.max(CARD_TITLE_H, fontH.medium + 8)
    local y = self.titleH + 4
    local x = PAD
    for _, b in ipairs({ self.importButton, self.rebindButton }) do
        local label = b == self.rebindButton and getText(T .. "Admin_Id_Rebind", "000") or b.fullTitle
        local bw = math.min(textWidth(label) + 24, math.max(60, math.floor((w - PAD * 3) / 2)))
        b:setVisible(visible)
        b:setWidth(bw); b:setHeight(ch)
        b:setX(x); b:setY(y)
        U.setButtonTitle(b, b.fullTitle)
        x = x + bw + 6
    end
    local ry = y + ch + 6
    self.reader:setVisible(visible)
    self.reader:setX(PAD); self.reader:setY(ry)
    self.reader:setWidth(math.max(80, w - PAD * 2))
    self.reader:setHeight(math.max(lineH() * 2, h - PAD - ry))
    self:rebuild()
    self:updateEnabled()
end

function Page:resize(width, height)
    if self.width ~= width then self:setWidth(width) end
    if self.height ~= height then self:setHeight(height) end
    self:layout()
end

function Page:prerender()
    local w, h = self.width, self.height
    U.theme:fill(self, 0, 0, w, h, "surface", "rect", 1)
    U.card(self, 0, 0, w, h, fitText(tr("Admin_Tab_Identity"), math.max(20, w - PAD * 2), UIFont.Medium), self.titleH)
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
    local free = owner.dialog == nil and not self.isPending(COMMAND) and self.collectToken == nil
    local write = owner:writeAllowed()
    self.importButton:setEnable(write and free)
    self.rebindButton:setEnable(write and free and #self:conflicts() > 0)
end

function Page:keyboardTargets()
    if not self:getIsVisible() then return {} end
    return {
        { kind = "group", label = tr("Admin_Tab_Identity"), controls = { self.importButton, self.rebindButton } },
        { kind = "scroll", label = tr("Admin_Tab_Identity"), control = self.reader, focusable = false },
    }
end

-- ----- lifecycle -----

-- The right to read went away: everything read goes, and a collection still waiting is disowned
-- (its rows are never sent).
function Page:clear()
    self.status, self.last, self.result, self.updatedAt = nil, nil, nil, nil
    self.sent, self.collectToken, self.wanted = nil, nil, nil
    self:rebuild()
end

function Page:dispose()
    self:clear()
end

function P.create(owner, send, isPending, newRequestId)
    local o = ISPanel:new(0, 0, 600, 400)
    setmetatable(o, Page)
    o.background = false
    o.owner = owner
    o.send, o.isPending, o.newRequestId = send, isPending, newRequestId
    o:initialise()
    o:instantiate()
    o:setVisible(false)
    return o
end

return P
