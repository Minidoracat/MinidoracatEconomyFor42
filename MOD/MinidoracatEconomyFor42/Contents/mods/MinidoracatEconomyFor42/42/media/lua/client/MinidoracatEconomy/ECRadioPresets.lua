-- MinidoracatEconomyFor42 - a session-wide market preset in the native RWMChannel dropdown.
-- Reads C.radio (hello/config); never writes DevicePresets or auto-retunes the device.
-- The extra row does not consume the player's ten slots (DevicePresets.java:14-56).
-- Tune In uses the native action and networking, with the exact displayed kHz value.
--
-- RWMChannel serves inventory, world and vehicle radios (ISRadioWindow.lua:219-232); native
-- readFromObject excludes televisions/media-only players. Out-of-band devices get no shared row.
-- A changed setting invalidates a stale displayed row, but already queued actions keep their value.
-- The station's own device window remains guarded by ECTerminalMenu.

if not MinidoracatEconomy or not MinidoracatEconomy.Client or not MinidoracatEconomy.Client.toast then
    require "MinidoracatEconomy/ECClient"
end
require "RadioCom/RadioWindowModules/RWMChannel"
require "RadioCom/ISRadioAction"

local C = MinidoracatEconomy.Client
local T = "IGUI_MinidoracatEconomy_"
local function tr(key, ...) return getText(T .. key, ...) end

-- Kept in the native option's own data field, so the row is known by identity instead of by an
-- index -- a preset list that changes behind the panel (a transmitPresets from elsewhere) shifts
-- indexes, and an index alone would let the vanilla edit/delete path take this row for a preset.
local SHARED = "MinidoracatEconomySharedPreset"

-- The device's preset list, read exactly the way native readPresets reads it, so a panel that is
-- being reused for another device cannot answer with the previous device's list.
local function presetList(panel)
    local data = panel.deviceData
    local presets = data and data:getDevicePresets()
    return presets and presets:getPresets() or nil
end

-- The frequency this device could really be tuned to right now, or nil.
local function sharedFrequency(deviceData)
    local info = C.radio
    if not info or not info.enabled then return nil end
    local frequency = tonumber(info.frequency)
    if not frequency then return nil end
    if frequency < deviceData:getMinChannelRange() or frequency > deviceData:getMaxChannelRange() then
        return nil
    end
    return frequency
end

local function isShared(panel)
    local box = panel.comboBox
    if not box or box.selected ~= panel.ecSharedIndex then return false end
    return box:getOptionData(box.selected) == SHARED
end

-- Keep the full label in the native combo item and tooltip. Its stencil clips the display;
-- RWMChannel.addComboOption would round the frequency and cut the stored string itself.
local function appendShared(panel, frequency)
    local label = tr("Radio_Channel") .. " - " .. tostring(frequency / 1000) .. " MHz"
    panel.comboBox:addOptionWithData(label, SHARED, label .. " - " .. tr("Radio_Preset_Hint"))
    return panel.comboBox:getOptionCount()
end

local function refresh(panel, keepShared)
    panel.ecSharedIndex, panel.ecSharedFreq = nil, nil
    local list = presetList(panel)
    panel.ecSharedCount = list and list:size() or nil
    if not list then return end
    local frequency = sharedFrequency(panel.deviceData)
    if not frequency then return end
    panel.ecSharedIndex, panel.ecSharedFreq = appendShared(panel, frequency), frequency
    -- Only this file's own rebuild asks for the market row back, and it says so with keepShared.
    -- The numeric _selected that native hands readPresets keeps its native meaning untouched --
    -- "the preset just added or edited" (onChildSave: RWMChannel.lua:88-108, where a freshly
    -- added n+1st preset carries the very index the market row had a moment earlier) and "the
    -- one left after a delete" -- so a new player preset is never mistaken for this row, and a
    -- rebuild never moves a normal choice onto it.
    if keepShared then panel.comboBox.selected = panel.ecSharedIndex end
    -- selectedPreset is native's pointer at a player preset; this row is not one, and a pointer
    -- left over from the previously opened device is how a stale entry reaches an edit.
    if panel.comboBox.selected == panel.ecSharedIndex then panel.selectedPreset = nil end
end

local function install()
    if not RWMChannel or RWMChannel.MinidoracatEconomySharedPreset then return end
    RWMChannel.MinidoracatEconomySharedPreset = true


    local baseReadPresets = RWMChannel.readPresets
    function RWMChannel:readPresets(_selected, keepShared)
        baseReadPresets(self, _selected)
        refresh(self, keepShared)
    end

    -- The window keeps one panel per player and clears it before it reads the next device
    -- (ISRadioWindow.lua:205-220): the cache goes with it, so nothing of the previous device is
    -- still believed, and a reopened window cannot append a second copy of the row.
    local baseClear = RWMChannel.clear
    function RWMChannel:clear()
        self.ecSharedIndex, self.ecSharedFreq, self.ecSharedCount = nil, nil, nil
        baseClear(self)
    end

    local baseComboChange = RWMChannel.comboChange
    function RWMChannel:comboChange()
        if isShared(self) then
            self.selectedPreset = nil
            return
        end
        return baseComboChange(self)
    end

    local baseTuneIn = RWMChannel.doTuneInButton
    function RWMChannel:doTuneInButton()
        if not isShared(self) then return baseTuneIn(self) end
        if not (self.player and self.device and self.deviceData) then return end
        -- Read again at the press: the row may have been built before a config change, and a
        -- market that was switched off or moved out of this device's range must say so instead
        -- of queueing an action the engine would silently drop.
        local frequency = sharedFrequency(self.deviceData)
        if not frequency or frequency ~= self.ecSharedFreq or not self.deviceData:getIsTurnedOn() then
            C.toast(tr("Radio_Preset_Unavailable"))
            return
        end
        -- Same approach and same action as a native preset (RWMChannel.lua:122-131), with the
        -- exact kHz handed over as a plain number -- the vanilla edit panel's 0.2 MHz slider
        -- would round 101.125 to 101.2 before it ever reached the device
        -- (ISSliderPanel:setCurrentValue: ISSliderPanel.lua:181-192). The television remote
        -- branch native keeps there cannot apply here: a television never reaches this module.
        if self:doWalkTo() then
            ISTimedActionQueue.add(ISRadioAction:new("SetChannel", self.player, self.device, frequency))
        end
    end

    -- The row is nobody's device preset: it cannot be renamed, retuned or deleted from a single
    -- machine. Native already refuses while its own preset count is in step with the dropdown
    -- (isValidPresets, RWMChannel.lua:110-114); these keep it refused in the frame a foreign
    -- preset change makes the indexes overlap, and the buttons below say so on screen.
    local baseEdit = RWMChannel.doEditPresetButton
    function RWMChannel:doEditPresetButton()
        if isShared(self) then return end
        return baseEdit(self)
    end

    local baseDelete = RWMChannel.doDeletePresetButton
    function RWMChannel:doDeletePresetButton()
        if isShared(self) then return end
        return baseDelete(self)
    end

    -- Reuse native update (RWMChannel.lua:223-249): rebuild only when count/frequency changes.
    -- An open popup keeps its list until it closes; the next update then applies the change.
    local baseUpdate = RWMChannel.update
    function RWMChannel:update()
        baseUpdate(self)
        local list = presetList(self)
        local count = list and list:size() or nil
        local frequency = list and sharedFrequency(self.deviceData) or nil
        if (count ~= self.ecSharedCount or frequency ~= self.ecSharedFreq)
                and not self.comboBox.expanded then
            -- this rebuild is the only caller that may ask for the market row back, and only
            -- because the player was reading it a frame ago; the index itself is recomputed
            self:readPresets(self.comboBox.selected, isShared(self))
        end
        if isShared(self) then
            self.editPresetButton:setEnable(false)
            self.deletePresetButton:setEnable(false)
        end
    end
end

-- Installed at game start, like the window guard in ECTerminalMenu: the vanilla class is present
-- by then no matter how the game ordered the mod's files against its own.
Events.OnGameStart.Add(install)
