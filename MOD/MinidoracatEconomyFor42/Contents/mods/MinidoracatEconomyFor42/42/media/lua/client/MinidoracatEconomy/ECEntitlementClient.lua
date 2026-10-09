-- MinidoracatEconomyFor42 -- client half of the entitlement API (rev 2). Adds exactly one
-- namespace: C.Entitlements, published as MinidoracatEconomy.v1.Client.Entitlements.
--
-- Every consumer mod (VehicleManager first) talks to the server through these functions and
-- never sends an entitlement.* command of its own. All prices, quantities, times and the paying
-- account are the server's; the client names a product, a kind and a quantity, or a quote id.
--
--   requestState(sourceMod, productId, cb?)                          -> requestId | nil, why
--   getState(sourceMod, productId)                                   -> last accepted envelope | nil
--   quote(sourceMod, productId, kind, quantity, cb, rental?)         -> requestId | nil, why
--   purchase(sourceMod, quoteId, cb)                                 -> requestId | nil, why
--   setAutoRenew(sourceMod, productId, enabled, revision, termsRevision, cb, rental) -> requestId | nil, why
--   getOrder(sourceMod, productId, orderId, cb)                      -> requestId | nil, why
--   onChanged(fn)                                                    fn(envelope)
--   requestList(cb?)                                                 -> requestId | nil, why
--   getList()                                                        -> { entries, more } | nil, error?
--   onPush(fn)                                                       fn(args) on every entitlement.changed
--
-- requestList reads every product of this login at once (entitlement.list, Economy's own wallet
-- tab): each envelope is adopted into the same cache as a state reply, and getList answers the
-- products of the last good read in the server's order (each as the cache's newest copy) with the
-- error of the last read (nil after a good one). onPush tells a page that lists them to read again.
--
-- `rental` is a rental id from entitlement.rentals[i].id (CAPABILITIES.rentals): a rental quote
-- without it opens a new rental, with it renews that one; auto-renew is always per rental.
--
-- Transport rules:
--   * one lane per command: a FIFO of requests, one in flight, sends spaced by the read gate's
--     650 ms (the server drops a repeat of the same command inside its 500 ms window without a
--     reply). Every request keeps its own callback; two consumers never share a pending slot.
--   * a callback is called exactly once with one table: the reply as the server sent it, or
--     { ok = false, error = "timeout", unknown = true, requestId, ... } when no answer came. A
--     timeout says "unknown" and nothing more: nothing is re-sent or re-quoted, a purchase is
--     never paid twice, and the outcome is read back with getOrder / requestState. A purchase
--     timeout keeps every identity it had: the quoteId, and the productId and orderId the quote
--     reply named (the server's order id exists before payment). getOrder answering
--     known = false is "not proven either way", never "not paid".
--   * a reply that lands after its timeout still carries the server's snapshot; the cache takes
--     it (it is the truth) but the callback is not called a second time.
--   * the cache keeps the newest envelope per source/product: an older entitlement revision (or
--     the same revision answering an older request) never overwrites a newer one.
--   * entitlement.changed is owner-only: an envelope is adopted like a reply; a public "refresh"
--     signal (no entitlement in it) only makes the products this client already holds re-read.

local EC = MinidoracatEconomy
local C = EC.Client

local E = {}
C.Entitlements = E

local T = "IGUI_MinidoracatEconomy_"
local GAP_MS = (C.ReadGate and C.ReadGate.MIN_MS) or 650
local TIMEOUT_MS = 10000
local QUEUE_MAX = 32          -- per command: a runaway caller is refused instead of flooding the server
local LATE_MAX = 32           -- timed-out requests whose late answer may still carry a snapshot

local STATE, QUOTE, PURCHASE, AUTORENEW, ORDER, LIST =
    "entitlement.state", "entitlement.quote", "entitlement.purchase", "entitlement.autoRenew", "entitlement.order",
    "entitlement.list"
local COMMANDS = { STATE, QUOTE, PURCHASE, AUTORENEW, ORDER, LIST }

local cache = {}        -- key -> envelope
local appliedSeq = {}   -- key -> sequence of the newest request / push that wrote the cache
local listeners = {}
local pushListeners = {}
local listKeys, listMore, listErr = nil, false, nil   -- the last list read: cache keys in server order
local listSeq = 0       -- sequence of the newest list request whose outcome set the three above
local lanes = {}        -- command -> { queue = { req, ... }, inflight = req | nil, sentAt = ms | nil }
local late = {}         -- requestId -> req
local lateOrder = {}
local quotes, quoteOrder = {}, {}   -- source/quote key -> { productId, orderId }
-- Contract: server quotes live for 120 seconds. Keep every quote the lane can issue in that window.
-- purchase() copies its identities into the request before this bounded cache can evict them.
local QUOTE_KEEP = math.ceil(120000 / GAP_MS) + QUEUE_MAX
local seq = 0
local pumping = false

local function resetLanes()
    for _, command in ipairs(COMMANDS) do lanes[command] = { queue = {} } end
end
resetLanes()

local function keyOf(sourceMod, productId)
    return tostring(sourceMod) .. "\1" .. tostring(productId)
end

-- ---------- argument checks (the server re-checks every one of them) ----------

local function validSource(s)
    return type(s) == "string" and #s >= 1 and #s <= 64 and string.match(s, "^[%w_%-]+$") ~= nil
end

local function validProduct(p)
    return type(p) == "string" and #p >= 1 and #p <= 32 and string.match(p, "^[a-z0-9_]+$") ~= nil
end

local function validId(s)
    return type(s) == "string" and #s >= 1 and #s <= 96 and string.find(s, "%c") == nil
end

local function whole(n, lo, hi)
    return type(n) == "number" and n == math.floor(n) and n >= lo and n <= hi
end

-- ---------- cache ----------

local function revisionOf(t)
    return type(t) == "table" and tonumber(t.revision) or -1
end

-- 1: env is newer than old, -1: older, 0: the same revisions
local function compare(old, env)
    local a, b = revisionOf(env.entitlement), revisionOf(old.entitlement)
    if a ~= b then return a > b and 1 or -1 end
    a, b = revisionOf(env.plan), revisionOf(old.plan)
    if a ~= b then return a > b and 1 or -1 end
    return 0
end

-- The snapshot a message carries: a state reply and a push are the envelope, every write reply
-- nests it under `snapshot`. A refusal or a bare refresh signal carries none.
local function envelopeOf(args)
    if type(args) ~= "table" then return nil end
    local env = type(args.snapshot) == "table" and args.snapshot or args
    if env.ok == false or type(env.sourceMod) ~= "string" or type(env.productId) ~= "string" then return nil end
    if type(env.entitlement) ~= "table" and type(env.plan) ~= "table" then return nil end
    return env
end

local function notify(env)
    for _, fn in ipairs(listeners) do
        local ok, err = pcall(fn, env)
        if not ok then EC.log("entitlement listener failed: " .. tostring(err)) end
    end
end

local function adopt(env, reqSeq)
    local key = keyOf(env.sourceMod, env.productId)
    local old = cache[key]
    local last = appliedSeq[key] or 0
    if old ~= nil then
        local order = compare(old, env)
        if order < 0 or (order == 0 and reqSeq < last) then return false end
    end
    cache[key] = env
    appliedSeq[key] = math.max(last, reqSeq)
    notify(env)
    return true
end

-- A list reply: every envelope goes into the cache like a state reply; the list keeps only the
-- keys, so a later push for one product shows through getList. A refusal keeps the old list.
-- Members, `more` and the error follow the newest request only: an older read answering late
-- (a success or a refusal) changes none of them, though its envelopes still go through adopt.
local function adoptList(args, reqSeq)
    local current = reqSeq >= listSeq
    if args.ok ~= true or type(args.entries) ~= "table" then
        if current then listSeq, listErr = reqSeq, tostring(args.error or "unknown") end
        return
    end
    local keys = {}
    for _, env in ipairs(args.entries) do
        if envelopeOf(env) ~= nil then
            adopt(env, reqSeq)
            keys[#keys + 1] = keyOf(env.sourceMod, env.productId)
        end
    end
    if current then listSeq, listKeys, listMore, listErr = reqSeq, keys, args.more == true, nil end
end

-- ---------- lanes ----------

local function finish(req, result)
    for _, cb in ipairs(req.cbs) do
        local ok, err = pcall(cb, result)
        if not ok then EC.log("entitlement callback failed: " .. tostring(err)) end
    end
end

local function timeoutResult(req)
    local out = { ok = false, error = "timeout", unknown = true, requestId = req.requestId }
    for k, v in pairs(req.echo) do out[k] = v end
    return out
end

local function rememberLate(req)
    late[req.requestId] = req
    lateOrder[#lateOrder + 1] = req.requestId
    if #lateOrder > LATE_MAX then
        late[table.remove(lateOrder, 1)] = nil
    end
end

local pump
local function ensurePump()
    if pumping then return end
    pumping = true
    Events.OnTick.Add(pump)
end

pump = function()
    local now = EC.now()
    local player = getPlayer()
    local busy = false
    for _, command in ipairs(COMMANDS) do
        local lane = lanes[command]
        local req = lane.inflight
        if req ~= nil and now - req.sentAt > TIMEOUT_MS then
            lane.inflight = nil
            rememberLate(req)
            if command == LIST and req.seq >= listSeq then listSeq, listErr = req.seq, "timeout" end
            finish(req, timeoutResult(req))
        end
        if lane.inflight == nil and #lane.queue > 0 and player ~= nil
            and (lane.sentAt == nil or now - lane.sentAt >= GAP_MS) then
            req = table.remove(lane.queue, 1)
            seq = seq + 1
            req.seq, req.sentAt = seq, now
            lane.inflight, lane.sentAt = req, now
            sendClientCommand(player, EC.COMMAND_MODULE, command, req.args)
        end
        if lane.inflight ~= nil or #lane.queue > 0 then busy = true end
    end
    if not busy and pumping then
        pumping = false
        Events.OnTick.Remove(pump)
    end
end

local function enqueue(command, args, cb, echo)
    local lane = lanes[command]
    if #lane.queue >= QUEUE_MAX then return nil, "queue_full" end
    local requestId = C.newRequestId()
    args.requestId = requestId
    local req = { command = command, requestId = requestId, args = args, cbs = {}, echo = echo }
    if type(cb) == "function" then req.cbs[1] = cb end
    lane.queue[#lane.queue + 1] = req
    ensurePump()
    pump()
    return requestId
end

-- Only writes to the same source and target share a pending identity.
local function pendingWrite(command, sourceMod, field, value)
    local lane = lanes[command]
    local req = lane.inflight
    if req ~= nil and req.args.sourceMod == sourceMod and req.args[field] == value then return true end
    for _, queued in ipairs(lane.queue) do
        if queued.args.sourceMod == sourceMod and queued.args[field] == value then return true end
    end
    return false
end

-- What a purchase must still be able to name when its answer never comes: the product the quote
-- was for and the order id the server gave it. Only a quote this client asked for is kept, and
-- nothing is inferred when the server named no order id.
local function rememberQuote(req, args)
    local q = args.ok == true and type(args.quote) == "table" and args.quote or nil
    if q == nil or not validId(q.id) then return end
    local key = keyOf(req.args.sourceMod, q.id)
    if quotes[key] == nil then
        quoteOrder[#quoteOrder + 1] = key
        if #quoteOrder > QUOTE_KEEP then quotes[table.remove(quoteOrder, 1)] = nil end
    end
    quotes[key] = { productId = req.args.productId,
        orderId = q.orderId ~= nil and tostring(q.orderId) or nil }
end

local function onReply(command, args)
    if type(args) ~= "table" then return end
    local lane = lanes[command]
    local req = lane.inflight
    local id = args.requestId
    if req ~= nil and id ~= nil and id == req.requestId then
        lane.inflight = nil
        if command == QUOTE then rememberQuote(req, args) end
        local env = envelopeOf(args)
        if env ~= nil then adopt(env, req.seq) end
        if command == LIST then adoptList(args, req.seq) end
        finish(req, args)
        if #lane.queue > 0 then
            ensurePump()
        end
        return
    end
    local lost = id ~= nil and late[id] or nil
    if lost ~= nil and lost.command == command then
        late[id] = nil
        local env = envelopeOf(args)
        if env ~= nil then adopt(env, lost.seq) end
        if command == LIST then adoptList(args, lost.seq) end
    end
end

for _, command in ipairs(COMMANDS) do
    C.handlers[command] = function(args) onReply(command, args) end
end

-- ---------- pushes ----------

C.handlers["entitlement.changed"] = function(args)
    if type(args) ~= "table" then return end
    local env = envelopeOf(args)
    if env ~= nil then
        seq = seq + 1
        adopt(env, seq)
    else
        -- A public signal names nobody's entitlement: the products this client already holds read
        -- themselves again, and onChanged fires when those answers land.
        for _, old in pairs(cache) do
            if (args.sourceMod == nil or args.sourceMod == old.sourceMod)
                and (args.productId == nil or args.productId == old.productId) then
                E.requestState(old.sourceMod, old.productId)
            end
        end
    end
    for _, fn in ipairs(pushListeners) do
        local ok, err = pcall(fn, args)
        if not ok then EC.log("entitlement push listener failed: " .. tostring(err)) end
    end
end

-- ---------- public API ----------

function E.requestState(sourceMod, productId, cb)
    if not validSource(sourceMod) or not validProduct(productId) then return nil, "invalid_args" end
    -- a read for the same product that has not left yet answers every caller that asks for it
    for _, req in ipairs(lanes[STATE].queue) do
        if req.args.sourceMod == sourceMod and req.args.productId == productId then
            if type(cb) == "function" then req.cbs[#req.cbs + 1] = cb end
            return req.requestId
        end
    end
    return enqueue(STATE, { sourceMod = sourceMod, productId = productId }, cb,
        { sourceMod = sourceMod, productId = productId })
end

function E.getState(sourceMod, productId)
    return cache[keyOf(sourceMod, productId)]
end

function E.quote(sourceMod, productId, kind, quantity, cb, rental)
    if not validSource(sourceMod) or not validProduct(productId)
        or (kind ~= "permanent" and kind ~= "rental")
        or (quantity ~= nil and not whole(quantity, 1, 1000))
        or (rental ~= nil and (kind ~= "rental" or not validId(rental))) then
        return nil, "invalid_args"
    end
    return enqueue(QUOTE, { sourceMod = sourceMod, productId = productId, kind = kind, quantity = quantity,
        rental = rental }, cb,
        { sourceMod = sourceMod, productId = productId, kind = kind, quantity = quantity, rental = rental })
end

function E.purchase(sourceMod, quoteId, cb)
    if not validSource(sourceMod) or not validId(quoteId) then return nil, "invalid_args" end
    if pendingWrite(PURCHASE, sourceMod, "quoteId", quoteId) then return nil, "pending" end
    local memo = quotes[keyOf(sourceMod, quoteId)]
    return enqueue(PURCHASE, { sourceMod = sourceMod, quoteId = quoteId }, cb,
        { sourceMod = sourceMod, quoteId = quoteId, productId = memo and memo.productId or nil,
            orderId = memo and memo.orderId or nil })
end

function E.setAutoRenew(sourceMod, productId, enabled, revision, termsRevision, cb, rental)
    if not validSource(sourceMod) or not validProduct(productId) or type(enabled) ~= "boolean"
        or not whole(revision, 0, 1e15) or not whole(termsRevision, 0, 1e15) or not validId(rental) then
        return nil, "invalid_args"
    end
    -- one consent write per product at a time: every rental's write names the product revision
    if pendingWrite(AUTORENEW, sourceMod, "productId", productId) then return nil, "pending" end
    return enqueue(AUTORENEW, { sourceMod = sourceMod, productId = productId, enabled = enabled,
        expectedRevision = revision, termsRevision = termsRevision, rental = rental }, cb,
        { sourceMod = sourceMod, productId = productId, enabled = enabled, rental = rental })
end

function E.getOrder(sourceMod, productId, orderId, cb)
    if not validSource(sourceMod) or not validProduct(productId) or not validId(orderId) then
        return nil, "invalid_args"
    end
    return enqueue(ORDER, { sourceMod = sourceMod, productId = productId, orderId = orderId }, cb,
        { sourceMod = sourceMod, productId = productId, orderId = orderId })
end

function E.onChanged(fn)
    if type(fn) == "function" then listeners[#listeners + 1] = fn end
end

function E.requestList(cb)
    -- a list read that has not left yet answers every caller that asks for one
    local queued = lanes[LIST].queue[1]
    if queued ~= nil then
        if type(cb) == "function" then queued.cbs[#queued.cbs + 1] = cb end
        return queued.requestId
    end
    return enqueue(LIST, {}, cb, {})
end

function E.getList()
    if listKeys == nil then return nil, listErr end
    local entries = {}
    for i, key in ipairs(listKeys) do entries[i] = cache[key] end
    return { entries = entries, more = listMore }, listErr
end

function E.onPush(fn)
    if type(fn) == "function" then pushListeners[#pushListeners + 1] = fn end
end

-- ---------- wording (every text a consumer shows comes from the four translation files) ----------

function E.errorText(code)
    local key = tostring(code == nil and "unknown" or code)
    local s = getTextOrNull(T .. "Ent_Error_" .. key) or getTextOrNull(T .. "Admin_Error_" .. key)
    if s ~= nil then return s end
    -- a code without a sentence is logged, never shown: the screen only carries translated words
    EC.log("entitlement error without a translation: " .. key)
    return getText(T .. "Ent_Error_unknown")
end

-- A value the translation files do not know reads as the shared "unknown" word; the value goes to
-- the log once (ECWidgets is not loaded yet when this file is, so it keeps its own record).
local unknownLogged = {}
local function enumText(prefix, value)
    if value == nil then return "-" end
    local s = getTextOrNull(T .. prefix .. tostring(value))
    if s ~= nil then return s end
    local key = prefix .. tostring(value)
    if not unknownLogged[key] then
        unknownLogged[key] = true
        EC.log("entitlement value without a translation: " .. key)
    end
    return getText(T .. "Common_Unknown")
end

function E.stateText(state) return enumText("Ent_State_", state) end
function E.autoRenewText(state) return enumText("Ent_Auto_", state) end
function E.durableText(status) return enumText("Ent_Durable_", status) end
function E.kindText(kind) return enumText("Ent_Kind_", kind) end
function E.orderStatusText(status) return enumText("Ent_OrderStatus_", status) end

-- entitlement.notice = { code, at, error? }: what happened last, worded for the player.
function E.noticeText(notice)
    if notice == nil then return nil end
    local kind = type(notice) == "table" and notice.code or notice
    local out = enumText("Ent_Notice_", kind)
    if type(notice) == "table" and notice.error ~= nil then out = out .. " (" .. E.errorText(notice.error) .. ")" end
    return out
end

function E.waitText(wait)
    if type(wait) ~= "table" or type(wait.code) ~= "string" then return nil end
    return enumText("Ent_Wait_", wait.code)
end

-- One reading of an entitlement.order reply for every consumer, so no window decides on its own
-- what an unknown purchase came to:
--   "paid" / "refunded"  known, and its save is confirmed -- or an instant product (reply.instant),
--                        which takes effect in the paying commit and has no save to wait for
--   "processing"         known paid / refunded, save not confirmed yet: still locked
--   "not_paid"           known, proven unpaid (unsubmitted | declined | rolledback, final)
--   "unknown"            everything else -- known = false (a quote still active, an order past
--                        the ring, a lookup across a restart), a refusal, a timeout
-- Only paid / refunded / not_paid may let a player pay again; nothing here ever re-sends.
function E.orderOutcome(reply)
    if type(reply) ~= "table" or reply.ok ~= true or reply.known ~= true then return "unknown" end
    local o = reply.order
    if type(o) ~= "table" then return "unknown" end
    if o.paid == false and o.final == true then return "not_paid" end
    if o.status ~= "paid" and o.status ~= "refunded" then return "unknown" end
    local durable = type(o.durable) == "table" and o.durable.status or nil
    if durable ~= "confirmed" and reply.instant ~= true then return "processing" end
    return o.status
end

-- The consumer owns its product's name: the key it registered, else the product id.
function E.productName(env)
    if type(env) ~= "table" then return "?" end
    local key = env.nameKey
    if type(key) == "string" and key ~= "" then
        local name = getTextOrNull(key)
        if name ~= nil and name ~= "" then return name end
    end
    return tostring(env.productId or "?")
end

function E.currencyName(id)
    return C.currencyName(id)
end

-- ---------- the wording Economy's own pages share (admin plan page, the wallet's list) ----------
-- Pure functions of a snapshot; ECWidgets (C.UI) is read when they are called, not at load.

local DAY_MS, HOUR_MS = 86400000, 3600000

local function num(v)
    local n = tonumber(v)
    return n ~= nil and tostring(n) or "-"
end

-- The language option cannot change without a restart, so it is read once; getOptionLanguageName
-- is absent on old builds.
local langCode = nil
local function gameLanguage()
    if langCode then return langCode end
    langCode = "EN"
    if type(getCore) == "function" then
        local ok, name = pcall(function() return getCore():getOptionLanguageName() end)
        if ok and type(name) == "string" and name ~= "" then langCode = name end
    end
    return langCode
end

-- A source's display name: its registered translation key, else its { CH, EN } display name,
-- else its mod id.
function E.sourceName(src)
    if type(src) ~= "table" then return "-" end
    local key = src.sourceNameKey
    local named = type(key) == "string" and key ~= "" and getTextOrNull(key) or nil
    if named ~= nil then return named end
    local names = src.sourceName or src.displayName
    if type(names) == "table" then
        local lang = gameLanguage()
        local pick = (lang == "CH" or lang == "CN") and names.CH or names.EN
        if type(pick) ~= "string" or pick == "" then pick = names.EN or names.CH end
        if type(pick) == "string" and pick ~= "" then return pick end
    end
    return tostring(src.modId or src.sourceMod or "-")
end

-- What an order bought: "buy outright", a new rental, a renewal or a scheduler renewal, and how
-- many slots. A rental the account no longer holds is named as removed.
function E.contentText(o)
    local q = num(o.quantity)
    if o.kind == "permanent" then return getText(T .. "Ent_Content_Permanent", q) end
    local which = (o.auto == true and "Auto") or ((o.renewal == true or o.kind == "renewal") and "Renewal") or "New"
    local n = tonumber(o.rentalNo)
    if n == nil then return getText(T .. "Ent_Content_" .. which .. "Gone", q) end
    return getText(T .. "Ent_Content_" .. which, tostring(n), q)
end

-- Paid / refunded; a product that waits for the world save says so while it waits -- for a refund
-- that is the refund's own save, not the payment's. An instant product takes effect in the paying
-- commit and never shows a save state.
function E.statusText(o, instant)
    local s = E.orderStatusText(o.status)
    if instant ~= true then
        local d = o.durable
        if o.status == "refunded" then d = type(o.refund) == "table" and o.refund.durable or nil end
        local saved = type(d) == "table" and d.status or nil
        if saved ~= nil and saved ~= "confirmed" then s = getText(T .. "Ent_StatusUnsaved", s) end
    end
    return s
end

-- One label for a rental's auto-renew, naming the one reason it is paused: the agreed terms no
-- longer match the plan's rent / currency / period, the account rents more than the limit, the
-- plan stopped renting, the plan does not allow auto-renew, or the server holds it.
function E.autoTag(r, plan, ent)
    local state = r.autoRenewState or (r.autoRenew == true and "on" or "off")
    if state == "on" or state == "pending_on" then return getText(T .. "Ent_AutoTag_on"), "textMuted" end
    if state == "off" or state == "pending_off" then return getText(T .. "Ent_AutoTag_off"), "textMuted" end
    if state == "paused_system" then return getText(T .. "Ent_AutoTag_system"), "warn" end
    local reason = "paused"
    if type(plan) == "table" then
        local a = r.autoTerms
        if type(a) == "table" and (tonumber(a.price) ~= tonumber(plan.rentalPrice)
            or a.currency ~= plan.rentalCurrency or tonumber(a.days) ~= tonumber(plan.rentalDays)) then
            reason = "terms"
        elseif type(ent) == "table" and (tonumber(ent.rentalCommitted) or 0) > (tonumber(plan.rentalLimit) or 0) then
            reason = "limit"
        elseif plan.rentalEnabled ~= true then
            reason = "stopped"
        elseif plan.autoRenewAllowed ~= true then
            reason = "disallowed"
        end
    end
    return getText(T .. "Ent_AutoTag_" .. reason), "warn"
end

-- Whole days while a day or more is left, hours below that.
function E.remainingText(ms)
    ms = math.max(0, tonumber(ms) or 0)
    if ms >= DAY_MS then return getText(T .. "Ent_Days", tostring(math.floor(ms / DAY_MS))) end
    return getText(T .. "Ent_Hours", tostring(math.max(1, math.ceil(ms / HOUR_MS))))
end

-- "#n, k slots, <state>": active with its end and what is left, in grace with the grace end,
-- expired, frozen (its product's mod is missing: what was left when it froze), or (a product that
-- waits for the save) a new rental not confirmed yet.
function E.rentalLine(i, r, now, offsetMin)
    local stampText = C.UI.stampText
    local n, q = tostring(i), num(r.quantity)
    local state, paid = r.state, tonumber(r.paidUntil)
    if state == "grace" then
        return getText(T .. "Ent_RentalLine_grace", n, q, stampText(tonumber(r.graceUntil), offsetMin))
    end
    if state == "expired" then return getText(T .. "Ent_RentalLine_expired", n, q) end
    if state == "pending" or paid == nil then return getText(T .. "Ent_RentalLine_pending", n, q) end
    if state == "frozen" then
        -- the server shows a frozen rental's times as if it came back now: what is left stays put
        if paid > now then return getText(T .. "Ent_RentalLine_frozen", n, q, E.remainingText(paid - now)) end
        return getText(T .. "Ent_RentalLine_frozenGrace", n, q, E.remainingText((tonumber(r.graceUntil) or now) - now))
    end
    return getText(T .. "Ent_RentalLine_active", n, q, stampText(paid, offsetMin), E.remainingText(paid - now))
end

-- ---------- session ----------

-- A new world: nothing learned from the previous server survives, and nothing it owed is waited
-- for. Listeners are the consumers' own registrations and stay.
Events.OnGameStart.Add(function()
    cache, appliedSeq, late, lateOrder = {}, {}, {}, {}
    quotes, quoteOrder = {}, {}
    listKeys, listMore, listErr, listSeq = nil, false, nil, 0
    resetLanes()
    if pumping then
        pumping = false
        Events.OnTick.Remove(pump)
    end
end)

return E
