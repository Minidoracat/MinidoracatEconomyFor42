-- MinidoracatEconomyFor42 -- shared account candidate picker (client). Adds exactly one
-- namespace: C.PlayerPicker.
--
--   C.PlayerPicker.create(owner, send, isPending, newRequestId, onPick, context, command, onEnter)
--
-- The box and its dropped candidate list are the framework's UI.Autocomplete (rev 11); this file
-- is only the Economy transport around it. It owns no command slot and no Events hook of its own:
-- the host hands it the very send / isPending / newRequestId the rest of that window already uses,
-- so the candidate read shares the one in-flight admin.players (or market.sellers) slot and the
-- one client cooldown instead of opening a scan of its own.
--
--   picker.entry                        the framework TextField (x / y / width for the host's layout)
--   picker:setText(s) / :getText()      the box, trimmed on the way out
--   picker:setVisible(v)                hides the box and folds the list away
--   picker:setEditable(v)               a read-only role still sees the box, greyed
--   picker:layout(x, y, w, maxH)        the box at (x, y, w); the list drops below it, capped
--   picker:anchorDrop(maxH)             the host placed the box itself: re-hang the list under it
--   picker:onReply(args) -> bool        true when this picker owned the reply (context and the
--                                       requestId it is still waiting for)
--   picker:owns(args) -> bool           the same match without consuming it: the host asks before
--                                       it releases the shared command slot
--   picker:onTimeout()                  the read never came back: ask again while the box is in use
--   picker:keyboardTargets()            the box, and the list while it is open
--   picker:isOpen() / :close() / :blur() / :dispose()
--
-- The debounce, the first read on focus, the IME read-back and the list geometry all run inside
-- the framework field's own prerender, so no host ticks it any more.
--
-- `context` travels with every request and comes back on the reply, so two pickers may share one
-- command without ever reading each other's answer. Four are known: "player" / "transactions"
-- (the admin account box) and "market" / "auction" (the seller box).

if not MinidoracatEconomy or not MinidoracatEconomy.Client or not MinidoracatEconomy.Client.UI then
    require "MinidoracatEconomy/ECWidgets"
end
local EC = MinidoracatEconomy
local C = EC.Client
local U = C.UI

local P = {}
C.PlayerPicker = P

local T = U.T
local USERNAME_MAX = 64

-- What the box calls itself, per context: the admin pages ask for an account, the market and the
-- auction pages for a seller. The labels are the only thing the two uses differ in.
local ACCOUNT_LABELS = { hint = "Admin_Player_Hint", account = "Admin_Player_Account",
    candidates = "Admin_Player_Candidates" }
local SELLER_LABELS = { hint = "Market_Seller_Hint", account = "Market_Seller",
    candidates = "Market_Seller_Candidates" }
local CONTEXTS = {
    player = ACCOUNT_LABELS, transactions = ACCOUNT_LABELS,
    market = SELLER_LABELS, auction = SELLER_LABELS,
}

local function tr(key) return getText(T .. key) end

local Picker = {}
Picker.__index = Picker

function Picker:setText(value) self.ac:setText(value) end
function Picker:getText() return self.ac:getText() end
function Picker:setVisible(visible) self.ac:setVisible(visible == true) end
function Picker:setEditable(editable) self.ac:setEnabled(editable ~= false) end
function Picker:layout(x, y, w, maxH) self.ac:layout(x, y, w, maxH) end
function Picker:anchorDrop(maxH) self.ac:anchorList(maxH) end
function Picker:isOpen() return self.ac:isOpen() end
function Picker:close() self.ac:close() end
function Picker:blur() self.ac:blur() end
function Picker:dispose() self.ac:dispose() end

-- The reply this picker is still waiting for: its own context, and the requestId it sent. Asked
-- (without consuming) by the host before it releases the shared command slot.
function Picker:owns(args)
    if type(args) ~= "table" then return false end
    if tostring(args.context or "") ~= self.context then return false end
    return self.sentRequestId ~= nil and args.requestId == self.sentRequestId
end

-- A refusal is silent: the candidate list is a convenience, never a result. An answer for a text
-- the box no longer holds is dropped by the framework (setResults) and the next query goes out.
function Picker:onReply(args)
    if not self:owns(args) then return false end
    self.sentRequestId = nil
    if args.ok == false then
        self.ac:queryFailed(false)
    else
        self.ac:setResults(self.sentText, args.players, args.total, args.truncated)
    end
    return true
end

function Picker:onTimeout()
    self.sentRequestId = nil
    self.ac:queryFailed(true)
end

-- One cached out array: the host copies the descriptors into its own list every call.
function Picker:keyboardTargets()
    local out = self.targets
    for i = #out, 1, -1 do out[i] = nil end
    return self.ac:appendTargets(out, self.accountLabel, self.candidatesLabel)
end

-- The framework asks from the field's prerender; false keeps the query armed for the next frame
-- (the shared slot is busy, or the host's send refused it).
local function onQuery(o, text)
    if o.isPending(o.command) then return false end
    local id = o.newRequestId()
    if not o.send(o.command, { query = text, requestId = id, context = o.context }) then return false end
    o.sentText, o.sentRequestId = text, id
    return true
end

-- owner: the page that hosts this picker. Both children are added to it (the list last, so it
-- paints over the rows behind it); the owner positions them through layout(). `onEnter(text)` is
-- Enter pressed inside the box. No command is sent here.
function P.create(owner, send, isPending, newRequestId, onPick, context, command, onEnter)
    local o = setmetatable({}, Picker)
    o.owner = owner
    o.send, o.isPending, o.newRequestId = send, isPending, newRequestId
    o.context = CONTEXTS[context] and context or "player"
    local labels = CONTEXTS[o.context]
    o.accountLabel, o.candidatesLabel = tr(labels.account), tr(labels.candidates)
    -- the public seller candidates and the admin account candidates are the same box over two
    -- commands; nothing else in here knows the difference
    o.command = command == "market.sellers" and "market.sellers" or "admin.players"
    o.targets = {}
    local online = tr("Admin_Player_Online")
    o.ac = U.framework.Autocomplete.new({
        width = 180, theme = U.theme, placeholder = tr(labels.hint), maxLength = USERNAME_MAX,
        target = o, onQuery = onQuery,
        labelOf = function(r) return r.username end,
        tagOf = function(r) return r.online and online or nil end,
        onPick = function(_, row)
            if type(row.username) == "string" and row.username ~= "" then onPick(row) end
        end,
        onEnter = onEnter and function(_, text) onEnter(text) end or nil,
    })
    o.entry = o.ac.field
    o.ac:setVisible(false)
    o.ac:addTo(owner)
    return o
end

return P
