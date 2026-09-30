-- MinidoracatEconomyFor42 - market radio summaries in this client's own language.
--
-- The server pushes radio.summary as data (ECRadio.lua): listing count, sellers, the newest
-- listings (item fullType, qty, price, currency), auctions about to end, and the trade terminal
-- squares with the frequency and strength of that moment. This client words it with its own
-- translation, item names and the admin's currency names from `config`, then hands the line to
-- the native radio code once per terminal. DistributeTransmission is the very call the engine
-- makes when a wave signal arrives from the server (WaveSignalPacket.processClient,
-- ZomboidRadio.java:718-733), so the listening radios, the range (> 3 and < strength, :690-716),
-- the edge-of-range scrambling, the subtitle and the chat line all stay native. Weather
-- interference is added the way SendTransmission adds it on a server (:903-913), because this
-- line never passes through SendTransmission.

if not MinidoracatEconomy or not MinidoracatEconomy.Client or not MinidoracatEconomy.Client.currencyName then
    require "MinidoracatEconomy/ECClient"
end
local C = MinidoracatEconomy.Client

local MESSAGE_MAX = 200         -- spec 17.3: one short line, never a wall of text
local COLOR_R, COLOR_G, COLOR_B = 1.0, 0.85, 0.4
local T = "IGUI_MinidoracatEconomy_"
local function tr(key, ...) return getText(T .. key, ...) end

-- Count and sellers, then the newest listings while they still fit the budget, then the
-- auctions about to end.
local function summaryText(s)
    local money = C.UI and C.UI.amountText or tostring
    local text
    if (tonumber(s.listings) or 0) <= 0 then
        text = tr("Radio_Empty")
    else
        text = tr("Radio_Summary", tostring(s.listings), tostring(s.sellers))
        local parts = {}
        for _, l in ipairs(s.latest or {}) do
            local name, price, qty = C.itemLabel(l.item), money(l.price), tonumber(l.qty) or 1
            local currency = l.currency and C.currencyName(l.currency) or nil
            if qty > 1 then
                parts[#parts + 1] = currency and tr("Radio_ItemQtyCur", name, tostring(qty), price, currency)
                    or tr("Radio_ItemQty", name, tostring(qty), price)
            else
                parts[#parts + 1] = currency and tr("Radio_ItemCur", name, price, currency)
                    or tr("Radio_Item", name, price)
            end
        end
        if #parts > 0 then
            local latest = tr("Radio_Latest", table.concat(parts, tr("Radio_Sep")))
            if #text + #latest <= MESSAGE_MAX then text = text .. latest end
        end
    end
    if (tonumber(s.auctions) or 0) > 0 then text = text .. tr("Radio_Auctions", tostring(s.auctions)) end
    if #text > MESSAGE_MAX then text = string.sub(text, 1, MESSAGE_MAX) end
    return text
end

-- The listening half of SendTransmission for this client: weather interference first
-- ((int)(interference * 100); grey only while 0 < intensity < 100, ZomboidRadio.java:805-827),
-- then the native distribution to this client's radios.
local function transmit(radio, x, y, frequency, strength, text)
    local r, g, b = COLOR_R, COLOR_G, COLOR_B
    local climate = getClimateManager()
    local intensity = climate and math.floor(climate:getWeatherInterference() * 100) or 0
    if intensity > 0 then
        text = radio:scrambleString(text, intensity, strength == -1, nil)
        if intensity < 100 then r, g, b = 0.5, 0.5, 0.5 end
    end
    radio:DistributeTransmission(x, y, frequency, text, "", "", r, g, b, strength, false)
end

C.handlers["radio.summary"] = function(s)
    -- A session means this client is in the game, well past the chat handshake the engine waits
    -- for before it plays any wave signal (ChatManager.isWorking in WaveSignalPacket; the server
    -- starts the player's chat on connect, GameServer.java:2849).
    if not C.session then return end
    local radio = getZomboidRadio()
    local frequency, strength = tonumber(s.frequency), tonumber(s.strength)
    if not radio or not frequency or not strength or type(s.sources) ~= "table" then return end
    local text = summaryText(s)
    for _, src in ipairs(s.sources) do
        local x, y = tonumber(src.x), tonumber(src.y)
        if x and y then transmit(radio, x, y, frequency, strength, text) end
    end
end
