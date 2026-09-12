-- MinidoracatEconomyFor42 - the read gate the three history pages of the Economy Center share.
--
-- A history page is a file read on the server, and all three of them (the wallet statement, the
-- market ring, the auction record) need the very same four rules:
--
--   * the server drops a second command from the same player inside its own window
--     (ECServer COMMAND_COOLDOWN_MS), so a wish made too soon waits instead of being lost;
--   * only one read may be in flight, and only the newest question is ever remembered;
--   * a page that is not on screen reads nothing at all -- it only owes a read, which goes out
--     the moment it is looked at again (views.changed never makes a hidden page talk);
--   * a reply is matched to the question it answers. A reply for another month, another pinned
--     auction or another search text is dropped; an older reply for the question still in force
--     may be shown at once and the newer read is still expected, so a page under a stream of
--     updates shows something instead of staying empty forever.
--
-- No event of its own, no window, no snapshot: the page owns its data, this owns the timing.

local EC = MinidoracatEconomy
local C = EC.Client
local G = {}
C.ReadGate = G

local MIN_MS = 650
local TIMEOUT_MS = 8000

G.MIN_MS = MIN_MS
G.TIMEOUT_MS = TIMEOUT_MS

local Gate = {}
Gate.__index = Gate

-- `send(query, requestId)` is the page's own request call. `query` is whatever identifies the
-- question this page asks: a month key, a pinned auction, a search text, or a constant for a
-- page that takes no parameters at all.
function G.create(send)
    local gate = { send = send }
    return setmetatable(gate, Gate)
end

-- The page wants `query` read. Only the newest question survives, and while the page is not
-- visible the wish is kept without a command being sent.
function Gate:want(query, visible)
    self.query = query
    self.wanted = true
    self:pump(visible)
end

-- Called every frame by the page, visible or not: a read that never came back has to free the
-- gate wherever the player is, and the wish of a page that just came back on screen goes out here.
function Gate:pump(visible)
    local now = EC.now()
    local pending = self.pending
    if pending ~= nil then
        if now - pending.at <= TIMEOUT_MS then return end
        self.pending = nil
        self.timedOut = true
    end
    if not self.wanted or visible ~= true then return end
    if self.sentAt ~= nil and now - self.sentAt < MIN_MS then return end
    local query = self.query
    local requestId = C.newRequestId()
    self.wanted, self.settled = nil, nil
    self.sentAt, self.sentId = now, requestId
    self.pending = { at = now }
    self.send(query, requestId)
end

-- A reply landed. `query` is the question the reply itself carries, as the page reads it back
-- from the answer; nil means the answer names none and only the request id can tell.
--   "stale" - another question, or an older read after the newest one already answered: drop it
--   "late"  - the current question, an older read: show it, the newest read is still expected
--   "ok"    - the read this gate was waiting for
--
-- The one bit of memory this needs is the high-water mark: once the newest read has answered
-- with real data, an older reply for the same question would put the page *back*, so it is
-- dropped instead of shown. A refusal never raises the mark -- the page kept its older data,
-- and a read that still arrives may fill it.
function Gate:accept(args, query)
    local current = self.query
    local id = args ~= nil and args.requestId or nil
    local owns = id ~= nil and id == self.sentId
    if owns then self.pending, self.timedOut = nil, nil end
    if query ~= nil and current ~= nil and query ~= current then return "stale" end
    if not owns then
        if id == nil or self.settled == true then return "stale" end
        return "late"
    end
    if args.error == nil then self.settled = true end
    return "ok"
end

-- The page was left. Whatever was queued is dropped; the read that really owns the command is
-- remembered until its reply or its timeout, so coming back cannot start a second one.
function Gate:clear()
    self.wanted = nil
end

-- A read is in flight or owed: the page's own "loading" note.
function Gate:busy()
    return self.pending ~= nil or self.wanted == true
end

-- A read that never came back, reported once. The page turns it into the timeout note its retry
-- chip sits next to; the next read repairs the page on its own.
function Gate:expired()
    local flag = self.timedOut
    self.timedOut = nil
    return flag == true
end

return G
