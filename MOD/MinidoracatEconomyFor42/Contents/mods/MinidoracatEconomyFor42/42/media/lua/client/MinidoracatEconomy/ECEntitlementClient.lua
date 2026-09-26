-- MinidoracatEconomyFor42 -- client half of the entitlement API (rev 2). Adds exactly one
-- namespace: C.Entitlements, published as MinidoracatEconomy.v1.Client.Entitlements.
--
-- Every consumer mod (VehicleManager first) talks to the server through these functions and
-- never sends an entitlement.* command of its own. All prices, quantities, times and the paying
-- account are the server's; the client names a product, a kind and a quantity, or a quote id.
--
--   requestState(sourceMod, productId, cb?)                          -> requestId | nil, why
--   getState(sourceMod, productId)                                   -> last accepted envelope | nil
--   quote(sourceMod, productId, kind, quantity, cb)                  -> requestId | nil, why
--   purchase(sourceMod, quoteId, cb)                                 -> requestId | nil, why
--   setAutoRenew(sourceMod, productId, enabled, revision, termsRevision, cb) -> requestId | nil, why
--   getOrder(sourceMod, productId, orderId, cb)                      -> requestId | nil, why
--   onChanged(fn)                                                    fn(envelope)
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
--   * entitlement.sandbox is server-authoritative: registered options are set and projected into
--     SandboxVars (toLua); nothing is ever sent back, so the sync cannot loop.
--
-- Engine references (snapshot 42.20.4-20260826):
--   getSandboxOptions()      LuaManager.java:5806-5812
--   SandboxOptions.getOptionByName / set / toLua   SandboxOptions.java:565-583, 279-285

local EC = MinidoracatEconomy
local C = EC.Client

local E = {}
C.Entitlements = E

local T = "IGUI_MinidoracatEconomy_"
local GAP_MS = (C.ReadGate and C.ReadGate.MIN_MS) or 650
local TIMEOUT_MS = 10000
local QUEUE_MAX = 32          -- per command: a runaway caller is refused instead of flooding the server
local LATE_MAX = 32           -- timed-out requests whose late answer may still carry a snapshot

local STATE, QUOTE, PURCHASE, AUTORENEW, ORDER =
    "entitlement.state", "entitlement.quote", "entitlement.purchase", "entitlement.autoRenew", "entitlement.order"
local COMMANDS = { STATE, QUOTE, PURCHASE, AUTORENEW, ORDER }

local cache = {}        -- key -> envelope
local appliedSeq = {}   -- key -> sequence of the newest request / push that wrote the cache
local listeners = {}
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
        return
    end
    -- A public signal names nobody's entitlement: the products this client already holds read
    -- themselves again, and onChanged fires when those answers land.
    for _, old in pairs(cache) do
        if (args.sourceMod == nil or args.sourceMod == old.sourceMod)
            and (args.productId == nil or args.productId == old.productId) then
            E.requestState(old.sourceMod, old.productId)
        end
    end
end

local function setOption(options, name, value)
    options:set(name, value)
end

local function projectOptions(options)
    options:toLua()
end

C.handlers["entitlement.sandbox"] = function(args)
    local values = type(args) == "table" and args.values or nil
    if type(values) ~= "table" or type(getSandboxOptions) ~= "function" then return end
    local options = getSandboxOptions()
    if options == nil then return end
    local changed = false
    for name, value in pairs(values) do
        local kind = type(value)
        if type(name) == "string" and (kind == "number" or kind == "boolean" or kind == "string")
            and options:getOptionByName(name) ~= nil then
            local ok, err = pcall(setOption, options, name, value)
            if ok then changed = true else EC.log("sandbox sync " .. name .. " failed: " .. tostring(err)) end
        end
    end
    if changed then
        local ok, err = pcall(projectOptions, options)
        if not ok then EC.log("sandbox sync toLua failed: " .. tostring(err)) end
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

function E.quote(sourceMod, productId, kind, quantity, cb)
    if not validSource(sourceMod) or not validProduct(productId)
        or (kind ~= "permanent" and kind ~= "rental")
        or (quantity ~= nil and not whole(quantity, 1, 1000)) then
        return nil, "invalid_args"
    end
    return enqueue(QUOTE, { sourceMod = sourceMod, productId = productId, kind = kind, quantity = quantity }, cb,
        { sourceMod = sourceMod, productId = productId, kind = kind, quantity = quantity })
end

function E.purchase(sourceMod, quoteId, cb)
    if not validSource(sourceMod) or not validId(quoteId) then return nil, "invalid_args" end
    if pendingWrite(PURCHASE, sourceMod, "quoteId", quoteId) then return nil, "pending" end
    local memo = quotes[keyOf(sourceMod, quoteId)]
    return enqueue(PURCHASE, { sourceMod = sourceMod, quoteId = quoteId }, cb,
        { sourceMod = sourceMod, quoteId = quoteId, productId = memo and memo.productId or nil,
            orderId = memo and memo.orderId or nil })
end

function E.setAutoRenew(sourceMod, productId, enabled, revision, termsRevision, cb)
    if not validSource(sourceMod) or not validProduct(productId) or type(enabled) ~= "boolean"
        or not whole(revision, 0, 1e15) or not whole(termsRevision, 0, 1e15) then
        return nil, "invalid_args"
    end
    if pendingWrite(AUTORENEW, sourceMod, "productId", productId) then return nil, "pending" end
    return enqueue(AUTORENEW, { sourceMod = sourceMod, productId = productId, enabled = enabled,
        expectedRevision = revision, termsRevision = termsRevision }, cb,
        { sourceMod = sourceMod, productId = productId, enabled = enabled })
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

-- ---------- wording (every text a consumer shows comes from the four translation files) ----------

function E.errorText(code)
    local key = tostring(code == nil and "unknown" or code)
    return getTextOrNull(T .. "Ent_Error_" .. key) or getTextOrNull(T .. "Admin_Error_" .. key)
        or getText(T .. "Ent_Error_generic", key)
end

local function enumText(prefix, value)
    if value == nil then return "-" end
    return getTextOrNull(T .. prefix .. tostring(value)) or tostring(value)
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
--   "paid" / "refunded"  known, and its save is confirmed
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
    if durable ~= "confirmed" then return "processing" end
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

-- ---------- session ----------

-- A new world: nothing learned from the previous server survives, and nothing it owed is waited
-- for. Listeners are the consumers' own registrations and stay.
Events.OnGameStart.Add(function()
    cache, appliedSeq, late, lateOrder = {}, {}, {}, {}
    quotes, quoteOrder = {}, {}
    resetLanes()
    if pumping then
        pumping = false
        Events.OnTick.Remove(pump)
    end
end)

return E
