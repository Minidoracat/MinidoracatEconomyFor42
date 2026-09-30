-- MinidoracatEconomyFor42 - market radio (server; spec 17.3, stage E).
--
-- Every trade terminal (kind "trade") is a transmitter on one fixed frequency: every
-- RadioIntervalMinutes real minutes the server takes one market summary (listing count,
-- sellers, the newest listings, auctions about to end) and pushes it to every online player as
-- data (radio.summary). Each client words it in its own language and plays it from each trade
-- terminal's square through the native radio code (client ECRadioSummary.lua), so radios in
-- range tuned to the frequency print it as device text (subtitle / chat line) in the listener's
-- language. ATMs do not broadcast: this is the one functional difference between the two
-- terminal kinds.
--
-- Why the server sends no text: SendTransmission carries one finished string to every client
-- (GameServer.sendIsoWaveSignal), so a server with players in several languages could reach
-- only one of them; and a dedicated server's Translator holds no mod keys at all unless some
-- other mod reloads it (Translator.loadFiles runs before loadMods, GameServer.java:601-603,1416).
--
-- Engine (snapshot 42.21.0-20260928):
--   getZomboidRadio()                            LuaManager.java:2915-2917 (nil without an instance)
--   addChannelName(name, freq, category)         ZomboidRadio.java:135-149 (also marks the
--                                                frequency known, so getRandomFrequency :175-182
--                                                never hands it to another channel; clients keep
--                                                their own registry: ECClient registers it too)
--   range: player distance > 3 and < strength, strength < 0 = everyone   ZomboidRadio.java:690-716

if not MinidoracatEconomy or not MinidoracatEconomy.Market then
    require "MinidoracatEconomy/ECMarket"
end
local EC = MinidoracatEconomy
local S = EC and EC.Server
local X = EC and EC.Export
local T = EC and EC.Terminal
local Mk = EC and EC.Market
local Cfg = EC and EC.Config
if not S or not S.AUTHORITY or not X or not T or not Mk or not Cfg then
    return
end
EC.Radio = EC.Radio or {}
local Rd = EC.Radio

Rd.CATEGORY = "Economy"
Rd.LATEST_MAX = 3               -- listings named per broadcast

local md = nil
local channelRegistered = nil   -- frequency the server registered its channel name for
local lastBroadcast = 0         -- ms of the last summary round (process memory, not ModData)

-- ---------- options ----------

function Rd.frequency() return EC.sandbox("RadioFrequency", 101100) end
function Rd.intervalMs() return EC.sandbox("RadioIntervalMinutes", 10) * 60000 end
-- strength < 0 means "everyone" for the engine; the sandbox uses 0 for that
function Rd.strength()
    local r = EC.sandbox("RadioRange", 500)
    if r <= 0 then return -1 end
    return r
end
function Rd.enabled() return EC.sandbox("RadioIntervalMinutes", 10) > 0 end

-- The two-way relay (ECTradeRadioRelay) is a separate switch from the summary broadcast: an
-- upgrade must not start listening to anybody just because the summary was already on.
function Rd.relayEnabled() return EC.sandbox("RadioRelayEnabled", false) end

-- The native transmitRange of the placed device. RadioRange is shared with the summary, where 0
-- means "everyone" through strength -1 (ZomboidRadio.java:690-701). A DeviceData range is not a
-- transmission strength and has no such sentinel: SetChannelsRouting / OnVoiceData keep the
-- float and compare sqrt(dx*dx+dy*dy) against it (native tail dump at
-- .omc/tmp/native-radio-tail.c:15963-16139), and a negative range would silence the device
-- instead of widening it. Unlimited is therefore expressed as a distance no pair of encodable
-- radio coordinates can reach: Java stores a radio's x/y as short, so the largest possible
-- separation is below 92700 tiles.
Rd.NATIVE_RANGE_UNLIMITED = 100000
function Rd.nativeRange()
    local r = EC.sandbox("RadioRange", 500)
    if r <= 0 then return Rd.NATIVE_RANGE_UNLIMITED end
    return r
end

-- ---------- summary ----------

-- What one broadcast names, as data: listing count, distinct sellers and the newest listings
-- (item fullType, qty, price). Every client puts it into words itself, with its own item names.
function Rd.summary()
    local listings = md.market and md.market.listings or {}
    local rows, sellers, sellerCount = {}, {}, 0
    for _, l in pairs(listings) do
        rows[#rows + 1] = l
        if not sellers[l.seller] then
            sellers[l.seller] = true
            sellerCount = sellerCount + 1
        end
    end
    EC.sortSafe(rows, function(a, b)
        if a.at ~= b.at then return a.at > b.at end
        return a.id < b.id
    end)
    local latest = {}
    for i = 1, math.min(Rd.LATEST_MAX, #rows) do
        local l = rows[i]
        -- a listing whose currency this server could not prove is still on the board; its
        -- price goes out without a currency rather than with a borrowed one
        latest[i] = { item = l.item, qty = l.qty or 1, price = l.price,
            currency = EC.CURRENCIES[l.currency] ~= nil and l.currency or nil }
    end
    return { listings = #rows, sellers = sellerCount, latest = latest, auctions = Rd.auctionsEndingSoon() }
end

-- Auctions that end before the next broadcast (stage F): "N auctions end within the hour".
function Rd.auctionsEndingSoon()
    local items = md.auctions and md.auctions.items or nil
    if not items then return 0 end
    local now, horizon, n = EC.now(), Rd.intervalMs(), 0
    for _, a in pairs(items) do
        if (a.expiresAt or 0) > now and (a.expiresAt or 0) - now <= horizon then n = n + 1 end
    end
    return n
end

-- ---------- transmit ----------

function Rd.radio()
    local ok, r = pcall(getZomboidRadio)
    if ok and r then return r end
    return nil
end

function Rd.registerChannel(radio)
    local freq = Rd.frequency()
    if channelRegistered == freq then return end
    pcall(function() radio:addChannelName(getText("IGUI_MinidoracatEconomy_Radio_Channel"), freq, Rd.CATEGORY) end)
    channelRegistered = freq
end

-- Pushes one summary to every client, naming every trade terminal as a source with the
-- frequency and strength of this moment; returns how many sources it named (0: no trade
-- terminal, nothing sent).
function Rd.broadcast(summary)
    local sources = {}
    for _, t in ipairs(T.list()) do
        if t.kind == "trade" then sources[#sources + 1] = { x = t.x, y = t.y } end
    end
    if #sources == 0 then return 0 end
    local radio = Rd.radio()
    if radio then Rd.registerChannel(radio) end
    summary.frequency, summary.strength, summary.sources = Rd.frequency(), Rd.strength(), sources
    S.broadcast("radio.summary", summary)
    X.emit("radio.broadcast", { terminals = #sources, frequency = summary.frequency,
        strength = summary.strength, listings = summary.listings })
    return #sources
end

-- The clock: real minutes on OnTickEvenPaused (an empty server keeps taking a summary for
-- nobody, one small table per interval; fine).
function Rd.onTick()
    if not md then return end
    if not Rd.enabled() then return end
    local ms = EC.now()
    if lastBroadcast == 0 then lastBroadcast = ms return end   -- first interval starts at boot
    if ms - lastBroadcast < Rd.intervalMs() then return end
    lastBroadcast = ms
    Rd.broadcast(Rd.summary())
end

-- What the client needs to name the channel and to explain the station to a player (hello.ack
-- and every `config` push). `enabled` keeps its original meaning for the client that only wants
-- to know whether the channel exists at all: either half of the station being on is enough.
-- The two halves are reported separately next to it, so nothing has to be inferred from it.
function Rd.clientInfo()
    return {
        frequency = Rd.frequency(),
        category = Rd.CATEGORY,
        enabled = Rd.enabled() or Rd.relayEnabled(),
        summaryEnabled = Rd.enabled(),
        relayEnabled = Rd.relayEnabled(),
        range = Rd.nativeRange(),
    }
end

function Rd.init(root)
    md = root
    lastBroadcast = 0
    channelRegistered = nil
    local radio = Rd.radio()
    if radio then Rd.registerChannel(radio) end
    EC.log("radio: " .. (radio and "available" or "no instance") .. ", " .. (Rd.enabled() and ("every " .. tostring(EC.sandbox("RadioIntervalMinutes", 10)) .. " min") or "off")
        .. ", " .. tostring(Rd.frequency() / 1000) .. " MHz, range " .. tostring(EC.sandbox("RadioRange", 500))
        .. ", two-way relay " .. (Rd.relayEnabled() and "on" or "off"))
end

S.Radio = Rd
S.onInit(Rd.init)
Events.OnTickEvenPaused.Add(Rd.onTick)
return Rd
