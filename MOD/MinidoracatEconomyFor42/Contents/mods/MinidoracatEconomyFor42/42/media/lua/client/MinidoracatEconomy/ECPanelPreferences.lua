-- MinidoracatEconomyFor42 — Economy Center preferences (client). The popover the navigation's
-- Settings entry opens, and the slider class it is built from. The preferences themselves stay
-- ECOptions' own (ModOptions.ini): nothing here keeps a copy, and nothing here registers an
-- event. The window owns the popover (Panel:showPrefs) and the popover only calls back into it.

require "ISUI/ISPanel"

if not MinidoracatEconomy or not MinidoracatEconomy.Client or not MinidoracatEconomy.Client.UI then
    require "MinidoracatEconomy/ECWidgets"
end

local EC = MinidoracatEconomy
local C = EC.Client
local U = C.UI

local Prefs = {}
C.PanelPreferences = Prefs

local PAD, CHIP_H, T = U.PAD, U.CHIP_H, U.T
local fontH = U.fontH
local Button = U.Button
local color, fill, text, textWidth, fitText, textRight = U.color, U.fill, U.text, U.textWidth, U.fitText, U.textRight

-- ---------- preference sliders ----------
-- Skin.slider is a stateless painter, so the drag lives here: the press remembers where it
-- landed inside the track and onMouseMove walks that x with the engine's deltas (ISUIElement
-- hands over dx/dy, not a point). One class, two specs: the title-row chrome opacity and the
-- toast seconds in the preference popover. spec = { min, max, get(), set(v, dragging), flush() }.
-- 5 % per chip, the step the ModOptions slider uses too; the bounds are ECOptions' own
local OPACITY_STEP = 5
local OPACITY_MIN = (EC.Options and EC.Options.OPACITY_MIN) or 30
local OPACITY_MAX = (EC.Options and EC.Options.OPACITY_MAX) or 100

local function opacityPercent()
    local O = EC.Options
    local v = (O and O.panelOpacity) and O.panelOpacity() or 1
    v = math.floor((tonumber(v) or 1) * 100 + 0.5)
    if v < OPACITY_MIN then v = OPACITY_MIN elseif v > OPACITY_MAX then v = OPACITY_MAX end
    return v
end

local function setOpacityPercent(v, dragging)
    if v < OPACITY_MIN then v = OPACITY_MIN elseif v > OPACITY_MAX then v = OPACITY_MAX end
    local O = EC.Options
    if O and O.setPanelOpacity then O.setPanelOpacity(v, dragging == true) else U.setAlpha(v / 100) end
end

local function optionsFlush()
    if EC.Options and EC.Options.flush then EC.Options.flush() end   -- one ini write per drag
end

local OPACITY_SPEC = { min = OPACITY_MIN, max = OPACITY_MAX, get = opacityPercent, set = setOpacityPercent, flush = optionsFlush }

local function toastSeconds()
    local O = EC.Options
    if O and O.toastSeconds then return O.toastSeconds() end
    return 5
end

local TOAST_SPEC = {
    min = (EC.Options and EC.Options.TOAST_MIN) or 2, max = (EC.Options and EC.Options.TOAST_MAX) or 10,
    get = toastSeconds,
    set = function(v, dragging)
        if EC.Options and EC.Options.setToastSeconds then EC.Options.setToastSeconds(v, dragging == true) end
    end,
    flush = optionsFlush,
}

local PrefSlider = ISPanel:derive("MinidoracatEconomyPrefSlider")

function PrefSlider:valueAt(x)
    local ratio = x / math.max(1, self.width - 1)
    if ratio < 0 then ratio = 0 elseif ratio > 1 then ratio = 1 end
    local s = self.spec
    return s.min + math.floor(ratio * (s.max - s.min) + 0.5)
end

function PrefSlider:onMouseDown(x)
    self.dragging = true
    self.dragX = x
    self.spec.set(self:valueAt(x), true)
    return true
end

function PrefSlider:onMouseMove(dx)
    if not self.dragging then return end
    self.dragX = (self.dragX or 0) + (tonumber(dx) or 0)
    self.spec.set(self:valueAt(self.dragX), true)
end
PrefSlider.onMouseMoveOutside = PrefSlider.onMouseMove   -- the pointer leaves the track mid-drag

function PrefSlider:onMouseUp()
    if self.dragging then self.spec.flush() end
    self.dragging = false
    return true
end
PrefSlider.onMouseUpOutside = PrefSlider.onMouseUp

function PrefSlider:render()
    local s = self.spec
    U.Skin.slider(self, 0, 0, self.width, self.height, (s.get() - s.min) / math.max(1, s.max - s.min),
        { track = color("track"), fill = color("gold"), knob = color("text"), border = color("border") }, U.alpha)
end

local function newPrefSlider(width, height, spec)
    local s = ISPanel:new(0, 0, width, height)
    setmetatable(s, PrefSlider)
    s.background = false
    s.spec = spec
    s:initialise()
    return s
end

-- ---------- preference popover ----------
-- The panel the navigation's Settings entry opens: the preferences that are the player's own
-- (ECOptions keeps them in ModOptions.ini). The chrome opacity used to be a slider plus two step
-- chips in the title row; it lives here now, beside the toast seconds.
--
-- Every row is a label, a track, a pair of step chips and the value. The chips are not decoration:
-- Skin.slider is a stateless painter, so a slider is mouse-only, and the chips are what a keyboard
-- user presses — no new ECKeyboard descriptor kind needed for either row.
local PREFS_W = 340
local TOAST_STEP = 1
local PrefsPopover = ISPanel:derive("MinidoracatEconomyPrefsPopover")

function PrefsPopover:onStep(button)
    local spec = button.spec
    local v = spec.get() + button.internal
    if v < spec.min then v = spec.min elseif v > spec.max then v = spec.max end
    spec.set(v, false)
    spec.flush()
end

function PrefsPopover:onClose()
    self.panel:showPrefs(false)
end

function PrefsPopover:addRow(spec, labelKey, step, readout)
    local chipH = math.max(CHIP_H, fontH.small + 10)
    local row = { spec = spec, labelKey = labelKey, readout = readout }
    for _, sign in ipairs({ -step, step }) do
        local title = (sign < 0 and "-" or "+") .. tostring(math.abs(sign))
        local b = Button.create(0, 0, textWidth(title) + 16, chipH, title, self, PrefsPopover.onStep, "chip")
        b.internal = sign
        b.spec = spec
        -- the label alone is "-5": the full text is what the tooltip and the keyboard caption show
        b.fullTitle = getText(T .. labelKey) .. " " .. title
        self:addChild(b)
        if sign < 0 then row.minus = b else row.plus = b end
    end
    row.slider = newPrefSlider(60, fontH.small + 8, spec)
    self:addChild(row.slider)
    self.rows[#self.rows + 1] = row
end

function PrefsPopover:createChildren()
    self.rows = {}
    self:addRow(OPACITY_SPEC, "Prefs_Opacity", OPACITY_STEP,
        function(v) return tostring(v) .. "%" end)
    self:addRow(TOAST_SPEC, "Prefs_Toast", TOAST_STEP,
        function(v) return getText(T .. "Prefs_Seconds", tostring(v)) end)
    local close = getText(T .. "Prefs_Close")
    self.closeButton = Button.create(0, 0, textWidth(close) + 24, math.max(CHIP_H, fontH.small + 10),
        close, self, PrefsPopover.onClose, "chip")
    self:addChild(self.closeButton)
    self:layoutInside()
end

function PrefsPopover:layoutInside()
    local w = PREFS_W
    local y = PAD + fontH.medium + PAD
    local readoutW = math.max(textWidth("100%"), textWidth(getText(T .. "Prefs_Seconds", "00"))) + 4
    for _, row in ipairs(self.rows) do
        row.labelY = y
        y = y + fontH.small + 4
        local band = math.max(row.slider.height, row.minus.height)
        local minus, plus = row.minus, row.plus
        minus:setX(PAD); minus:setY(y + math.floor((band - minus.height) / 2))
        plus:setX(w - PAD - readoutW - 6 - plus.width); plus:setY(minus.y)
        row.slider:setX(minus.x + minus.width + 6)
        row.slider:setWidth(math.max(40, plus.x - 6 - (minus.x + minus.width + 6)))
        row.slider:setY(y + math.floor((band - row.slider.height) / 2))
        row.readoutR = w - PAD
        row.valueY = y + math.floor((band - fontH.small) / 2)
        y = y + band + PAD
    end
    self.noteY = y
    y = y + fontH.small + PAD
    self.closeButton:setX(w - PAD - self.closeButton.width)
    self.closeButton:setY(y)
    self:setWidth(w)
    self:setHeight(y + self.closeButton.height + PAD)
end

function PrefsPopover:prerender()
    local w, h = self.width, self.height
    fill(self, 0, 0, w, h, "surface")
    U.Skin.border(self, 0, 0, w, h, color("border"))
    text(self, getText(T .. "Prefs_Title"), PAD, PAD, "text", UIFont.Medium)
    for _, row in ipairs(self.rows) do
        text(self, fitText(getText(T .. row.labelKey), w - PAD * 2), PAD, row.labelY, "textMuted")
        textRight(self, row.readout(row.spec.get()), row.readoutR, row.valueY, "text")
    end
    text(self, fitText(getText(T .. "Prefs_ModOptionsNote"), w - PAD * 2), PAD, self.noteY, "textFaint")
end

function PrefsPopover:keyboardTargets()
    local out = {}
    for _, row in ipairs(self.rows) do
        out[#out + 1] = { kind = "group", controls = { row.minus, row.plus },
            label = getText(T .. row.labelKey) }
    end
    out[#out + 1] = { kind = "button", control = self.closeButton, label = getText(T .. "Prefs_Close") }
    return out
end

function PrefsPopover:onMouseDown() return true end   -- clicks inside never fall through to the window
function PrefsPopover:onMouseUp() return true end

Prefs.PrefsPopover = PrefsPopover
Prefs.PREFS_W = PREFS_W
Prefs.opacityPercent = opacityPercent

return Prefs
