-- MinidoracatEconomyFor42 - market radio (server; spec 17.3, stage E).
--
-- Every trade terminal (kind "trade") is a transmitter on one fixed frequency: every
-- RadioIntervalMinutes real minutes the server composes one market summary (listing count,
-- sellers, the newest listings) and sends it from each trade terminal's square. Radios in range
-- tuned to the frequency print it as device text (subtitle / chat line). ATMs do not broadcast:
-- this is the one functional difference between the two terminal kinds.
--
-- Engine (snapshot 42.20.4-20260826, exercised in stage A14 on this dedicated server):
--   getZomboidRadio()                            LuaManager.java:2909-2911 (nil without an instance)
--   ZomboidRadio.SendTransmission(x, y, channel, msg, guid, codes, r, g, b, strength, isTV)
--                                                ZomboidRadio.java:894-923 (Server: weather
--                                                interference, then GameServer.sendIsoWaveSignal)
--   range: player distance > 3 and < strength, strength < 0 = everyone   ZomboidRadio.java:690-701
--   addChannelName(name, freq, category)         ZomboidRadio.java:135-139 (client keeps its own
--                                                registry: ECClient registers it too, translated)
--   getModFileReader(modId, path, create)        LuaManager.java:5971-6000 (the mod's own
--                                                Translate/<lang>/IG_UI.json for RadioLanguage)
--
-- Text is composed on the server, so its language is the server's (Translator) unless the
-- sandbox RadioLanguage names one of the mod's languages: then the templates come from the mod's
-- own translation file. Item names still come from the server's Translator.

if not MinidoracatEconomy or not MinidoracatEconomy.Market then
    require "MinidoracatEconomy/ECMarket"
end
local EC = MinidoracatEconomy
local S = EC and EC.Server
local X = EC and EC.Export
local T = EC and EC.Terminal
local Mk = EC and EC.Market
if not S or not S.AUTHORITY or not X or not T or not Mk then
    return
end

EC.Radio = EC.Radio or {}
local Rd = EC.Radio

Rd.CATEGORY = "Economy"
Rd.LATEST_MAX = 3               -- listings named per broadcast
Rd.MESSAGE_MAX = 200            -- spec 17.3: one short line, never a wall of text
Rd.LANGUAGES = { CH = true, CN = true, EN = true, JP = true }
Rd.TEMPLATE_KEYS = { "Radio_Empty", "Radio_Summary", "Radio_Latest", "Radio_Item", "Radio_ItemQty", "Radio_Sep", "Radio_Auctions", "Radio_Channel" }

local md = nil
local lastBroadcast = 0
local templates = {}            -- lang -> { key = text } (loaded once per language)
local channelRegistered = nil   -- frequency the server registered its channel name for

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

function Rd.language()
    local v = EC.sandbox("RadioLanguage", "auto")
    if Rd.LANGUAGES[v] then return v end
    return nil
end

-- ---------- templates ----------

local function readModJson(lang)
    local reader = nil
    local ok = pcall(function() reader = getModFileReader(EC.MOD_ID, "media/lua/shared/Translate/" .. lang .. "/IG_UI.json", false) end)
    if not ok or not reader then return nil end
    local lines = {}
    pcall(function()
        for _ = 1, 5000 do
            local line = reader:readLine()
            if line == nil then break end
            lines[#lines + 1] = line
        end
    end)
    pcall(function() reader:close() end)
    return table.concat(lines, "\n")
end

local function loadTemplates(lang)
    if templates[lang] then return templates[lang] end
    local out = {}
    local text = readModJson(lang)
    local doc = text and EC.jsonDecode(text) or nil
    if type(doc) == "table" then
        for _, key in ipairs(Rd.TEMPLATE_KEYS) do
            local v = doc["IGUI_MinidoracatEconomy_" .. key]
            if type(v) == "string" then out[key] = v end
        end
    end
    templates[lang] = out
    return out
end

-- %1..%9 substitution on a template; the engine's getText does the same for the server language.
local function fill(tpl, ...)
    local args = { ... }
    return (string.gsub(tpl, "%%([1-9])", function(i)
        local v = args[tonumber(i)]
        return v ~= nil and tostring(v) or ""
    end))
end

function Rd.text(key, ...)
    local lang = Rd.language()
    if lang then
        local tpl = loadTemplates(lang)[key]
        if tpl then return fill(tpl, ...) end
    end
    return getText("IGUI_MinidoracatEconomy_" .. key, ...)
end

local function itemLabel(fullType)
    local ok, name = pcall(getItemNameFromFullType, fullType)
    if ok and type(name) == "string" and name ~= "" then return name end
    return tostring(fullType)
end

-- ---------- message ----------

-- One line: listing count + sellers, then the newest listings (name, qty, price).
function Rd.compose()
    local listings = md.market and md.market.listings or {}
    local rows, sellers, sellerCount = {}, {}, 0
    for _, l in pairs(listings) do
        rows[#rows + 1] = l
        if not sellers[l.seller] then
            sellers[l.seller] = true
            sellerCount = sellerCount + 1
        end
    end
    if #rows == 0 then return Rd.text("Radio_Empty") .. Rd.auctionLine() end
    EC.sortSafe(rows, function(a, b)
        if a.at ~= b.at then return a.at > b.at end
        return a.id < b.id
    end)
    local msg = Rd.text("Radio_Summary", tostring(#rows), tostring(sellerCount))
    local parts = {}
    for i = 1, math.min(Rd.LATEST_MAX, #rows) do
        local l = rows[i]
        local name = itemLabel(l.item)
        local price = EC.amountText and EC.amountText(l.price) or tostring(l.price)
        if (l.qty or 1) > 1 then
            parts[#parts + 1] = Rd.text("Radio_ItemQty", name, tostring(l.qty), price)
        else
            parts[#parts + 1] = Rd.text("Radio_Item", name, price)
        end
    end
    local latest = Rd.text("Radio_Latest", table.concat(parts, Rd.text("Radio_Sep")))
    if #msg + #latest <= Rd.MESSAGE_MAX then msg = msg .. latest end
    msg = msg .. Rd.auctionLine()
    if #msg > Rd.MESSAGE_MAX then msg = string.sub(msg, 1, Rd.MESSAGE_MAX) end
    return msg
end

-- Auctions that end before the next broadcast (stage F): "N auctions end within the hour".
function Rd.auctionLine()
    local items = md.auctions and md.auctions.items or nil
    if not items then return "" end
    local now, horizon, n = EC.now(), Rd.intervalMs(), 0
    for _, a in pairs(items) do
        if (a.expiresAt or 0) > now and (a.expiresAt or 0) - now <= horizon then n = n + 1 end
    end
    if n == 0 then return "" end
    return Rd.text("Radio_Auctions", tostring(n))
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
    pcall(function() radio:addChannelName(Rd.text("Radio_Channel"), freq, Rd.CATEGORY) end)
    channelRegistered = freq
end

-- Sends `msg` from every trade terminal; returns how many transmissions went out.
function Rd.broadcast(msg)
    local radio = Rd.radio()
    if not radio then return 0 end
    Rd.registerChannel(radio)
    local freq, strength = Rd.frequency(), Rd.strength()
    local n = 0
    for _, t in ipairs(T.list()) do
        if t.kind == "trade" then
            local ok = pcall(function()
                radio:SendTransmission(t.x, t.y, freq, msg, "", "", 1.0, 0.85, 0.4, strength, false)
            end)
            if ok then n = n + 1 end
        end
    end
    if n > 0 then
        X.emit("radio.broadcast", { terminals = n, frequency = freq, strength = strength, chars = #msg })
    end
    return n
end

-- The clock: real minutes on OnTickEvenPaused (an empty server keeps broadcasting to nobody,
-- which costs one composed string per interval; fine).
function Rd.onTick()
    if not md then return end
    if not Rd.enabled() then return end
    local ms = EC.now()
    if lastBroadcast == 0 then lastBroadcast = ms return end   -- first interval starts at boot
    if ms - lastBroadcast < Rd.intervalMs() then return end
    lastBroadcast = ms
    Rd.broadcast(Rd.compose())
end

-- What the client needs to register the channel name on its side (hello.ack).
function Rd.clientInfo()
    return { frequency = Rd.frequency(), enabled = Rd.enabled(), category = Rd.CATEGORY }
end

function Rd.init(root)
    md = root
    lastBroadcast = 0
    templates = {}
    channelRegistered = nil
    local radio = Rd.radio()
    if radio then Rd.registerChannel(radio) end
    EC.log("radio: " .. (radio and "available" or "no instance") .. ", " .. (Rd.enabled() and ("every " .. tostring(EC.sandbox("RadioIntervalMinutes", 10)) .. " min") or "off")
        .. ", " .. tostring(Rd.frequency() / 1000) .. " MHz, range " .. tostring(EC.sandbox("RadioRange", 500)))
end

S.Radio = Rd
S.onInit(Rd.init)
Events.OnTickEvenPaused.Add(Rd.onTick)
return Rd
