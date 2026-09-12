-- MinidoracatEconomyFor42 -- shared "pick an item" overlay (client). Adds exactly one namespace:
-- C.ItemPicker.
--
--   C.ItemPicker.universe()
--       every item script this server loaded (base game and MODs alike), read once per session:
--       { items = { record, ... }, byType = { [fullType] = record }, cats = { [category] = n } },
--       record = { fullType, name (the player's own language), original (the real English name,
--       "" when no shipped or MOD dictionary has one for this type), category, search,
--       fixed = EC.isFixedType(script) }. Only hidden / obsolete scripts are left out:
--       `fixed` is a flag on the record, never a reason to drop it, so the shop (which sells
--       anything) and the market whitelist (which cannot list the fixed classes) read one
--       universe and apply their own policy. Never sorted -- EC.sortSafe is an insertion sort and
--       this list is thousands of rows long; consumers order the slice they show.
--       `original` and `search` come from C.ItemNames, whose files load over a few ticks: this
--       call starts that load, and refills those two fields in place on the records every page
--       already holds once it is ready. There is never a second index of the universe.
--
--   C.ItemPicker.create(owner, policy, onPick, onCancel)
--       an initialised ISPanel child, NOT added: the owning page adds it last (so it paints over
--       its own content), positions it at (0, 0) and resizes it to the whole page. policy is
--       'shop' (the whole universe) or 'market' (fixed classes skipped). onPick(record) and
--       onCancel() are plain functions, called after the overlay has closed itself; neither sends
--       a command. Methods: open(), close(), resize(w, h), tick(now), keyboardTargets(),
--       dispose(). No Events hook, no singleton: the host page reports it as its modal state and
--       routes Escape into cancel().
--
-- Engine references (snapshot 42.20.4-20260826):
--   getAllItems          ScriptManager.java:715-717 (java.util.ArrayList of ScriptItem)
--   isHidden/getObsolete Item.java:2010-2012, 1194-1196
--   getDisplayName       Item.java:493-495 -- NOT used here and not an English name: after the
--                        scripts are loaded it returns the Translator's name, so on a Chinese
--                        client it is the same string as name. English comes from C.ItemNames.

require "ISUI/ISPanel"
require "MinidoracatEconomy/ECWidgets"
require "MinidoracatEconomy/ECItemNames"

local EC = MinidoracatEconomy
local C = EC.Client
local U = C.UI
local Names = C.ItemNames

local P = {}
C.ItemPicker = P

local PAD, T = U.PAD, U.T
local CARD_TITLE_H = U.CARD_TITLE_H
local fontH = U.fontH
local fill, text, fitText, textWidth, card = U.fill, U.text, U.fitText, U.textWidth, U.card
local Button = U.Button
local newEntry, entryText, setEntryText = U.newEntry, U.entryText, U.setEntryText
local itemName, itemTexture, categoryText = U.itemName, U.itemTexture, U.categoryText

-- The most rows one search ever paints: a single letter matches most of the game, and the hint
-- line always says how many matched in total so the number on screen is never mistaken for all.
P.MAX_RESULTS = 200
local SEARCH_DEBOUNCE_MS = 120

local function tr(key) return getText(T .. key) end
local function lineH() return fontH.small + 6 end
local function chipH() return math.max(20, fontH.small + 6) end
local function entryH() return math.max(26, fontH.small + 12) end

-- ---------- the universe ----------

local universe = nil

-- The two fields a search reads, filled from the English index: `original` is the real English
-- name (the shipped dictionary, then what an activated MOD's own EN ItemName.json says), and
-- `search` is what one keystroke matches on -- the player's own language, that English, the
-- English a MOD renamed away from, and the id itself. Lowercased here, never per keystroke.
-- Called on every universe() so the records already handed out gain their English in place the
-- tick the index is ready; the revision guard makes the walk happen once per change, not per
-- call. An unknown type keeps original = "": no name is invented for it anywhere.
local function applyEnglish(uni)
    local rev = Names.revision
    if uni.namesRev == rev then return end
    uni.namesRev = rev
    for _, rec in ipairs(uni.items) do
        local en, alt, also = Names.english(rec.fullType)
        rec.original = type(en) == "string" and en or ""
        local search = string.lower(rec.name .. " " .. rec.original .. " " .. rec.fullType)
        if type(alt) == "string" and alt ~= "" then search = search .. " " .. string.lower(alt) end
        -- and every name an earlier MOD gave this type before another renamed it again: they are
        -- all names some file really declared, so all of them answer one keystroke
        if type(also) == "table" then
            for _, name in ipairs(also) do
                if type(name) == "string" and name ~= "" then search = search .. " " .. string.lower(name) end
            end
        end
        rec.search = search
    end
end

function P.universe()
    Names.ensure()
    if universe then
        applyEnglish(universe)
        return universe
    end
    local uni = { items = {}, byType = {}, cats = {} }
    local all = nil
    pcall(function() all = getScriptManager():getAllItems() end)
    local count = 0
    if all then pcall(function() count = all:size() end) end
    for i = 0, count - 1 do
        local script = nil
        pcall(function() script = all:get(i) end)
        local skip = script == nil
        if not skip then
            pcall(function()
                if script:isHidden() or script:getObsolete() then skip = true end
            end)
        end
        if not skip then
            local fullType, category = nil, nil
            pcall(function() fullType = script:getFullName() end)
            pcall(function() category = script:getDisplayCategory() end)
            if type(fullType) == "string" and fullType ~= "" and uni.byType[fullType] == nil then
                if type(category) ~= "string" or category == "" then category = "Item" end
                local record = {
                    fullType = fullType, name = itemName(fullType), category = category,
                    original = "", search = "",       -- applyEnglish below owns both
                    fixed = EC.isFixedType(script),
                }
                uni.byType[fullType] = record
                uni.items[#uni.items + 1] = record
                uni.cats[category] = (uni.cats[category] or 0) + 1
            end
        end
    end
    -- an empty answer is not cached: it means the script manager had nothing to say (a stub-thin
    -- environment, or a call made before the scripts were loaded), and caching that would leave
    -- every picker on this session permanently empty
    if #uni.items > 0 then universe = uni end
    applyEnglish(uni)
    return uni
end

-- ---------- result row ----------

local PickCell = ISPanel:derive("MinidoracatEconomyPickCell")

function PickCell:render()
    local e = self.entry
    if not e then return end
    local w, h = self.width, self.height
    if self.index % 2 == 0 then fill(self, 0, 0, w, h, "card", "rect") end
    if self:isMouseOver() then fill(self, 0, 0, w, h, "hover", "rect") end
    if e.icon then
        local ok = pcall(self.drawTextureScaled, self, e.icon, PAD, e.iconY, e.iconSize, e.iconSize, 1, 1, 1, 1)
        if not ok then e.icon = nil end
    end
    text(self, e.nameText, e.nameX, e.line1Y, "text")
    if e.altText then text(self, e.altText, e.altX, e.line1Y, "textFaint") end
    text(self, e.metaText, e.nameX, e.line2Y, "textFaint")
end

-- ---------- the overlay ----------

local Picker = ISPanel:derive("MinidoracatEconomyItemPicker")

-- The root window is the only thing C.Keyboard.invalidate accepts; the host page hangs under the
-- admin controller, which hangs under it.
local function keyboardRoot(page)
    local admin = page ~= nil and page.owner or nil
    return admin ~= nil and admin.owner or nil
end

function Picker:createChildren()
    self.entry = newEntry(240, entryH(), { maxLen = 48, clear = true, placeholder = tr("Admin_Pick_Search") })
    self.entry.target = self
    self.entry.onTextChangeFunction = Picker.onSearch
    self:addChild(self.entry)
    self.list = U.newTable(PickCell, lineH() * 2 + 10)
    self.list.onSelect = function(_, item) self:choose(item) end
    self:addChild(self.list)
    local cancel = tr("Admin_Cancel")
    self.cancelButton = Button.create(0, 0, textWidth(cancel) + 24, chipH(), cancel, self, Picker.cancel, "chip")
    self:addChild(self.cancelButton)
    self:layout()
end

-- ----- searching -----

-- A keystroke only arms the clock tick() owns: the universe is thousands of records long, so the
-- scan runs once per pause in the typing instead of once per key.
function Picker:onSearch()
    self.searchSeen = entryText(self.entry)
    self.searchAt = EC.now()
end

function Picker:rebuild()
    local query = string.lower(string.match(entryText(self.entry), "^%s*(.-)%s*$") or "")
    local market = self.policy == "market"
    local uni = P.universe()
    self.namesRev = Names.revision
    local rows, total = {}, 0
    local width = math.max(80, self.list.width - 12)   -- 12 = the scrollbar gutter
    local size = math.min(math.max(12, self.list.rowHeight - 12), 28)
    local lh = lineH()
    local nameX = PAD + size + 8
    for _, rec in ipairs(uni.items) do
        if not (market and rec.fixed) and (query == "" or string.find(rec.search, query, 1, true) ~= nil) then
            total = total + 1
            if #rows < P.MAX_RESULTS then
                local alt = (rec.original ~= "" and rec.original ~= rec.name) and rec.original or nil
                local nameW = math.max(40, math.floor((width - nameX) * (alt and 0.55 or 1)))
                local item = {
                    record = rec,
                    icon = itemTexture(rec.fullType), iconSize = size,
                    iconY = math.max(0, math.floor(4 + lh - size / 2)),
                    nameText = fitText(rec.name, nameW), nameX = nameX,
                    line1Y = 4, line2Y = 4 + lh,
                    metaText = fitText(rec.fullType .. "  /  " .. categoryText(rec.category), math.max(20, width - nameX)),
                }
                if alt then
                    item.altX = nameX + nameW + 8
                    item.altText = fitText(alt, math.max(0, width - item.altX))
                end
                rows[#rows + 1] = item
            end
        end
    end
    self.total = total
    self.shown = #rows
    self.list:setItems(rows)
    self.list:setSelectedIndex(nil)
    local count
    if total == 0 then
        count = tr("Admin_Pick_Empty")
    elseif total > #rows then
        count = getText(T .. "Admin_Pick_More", tostring(#rows), tostring(total))
    else
        count = getText(T .. "Admin_Pick_Count", tostring(total))
    end
    -- What the English half of `search` is worth right now. It goes first, because the hint is
    -- fitted to one line: the count may be cut, the reason a name is missing may not. No name
    -- is ever invented to paper over this -- an unknown type simply has no English.
    local names = Names.status()
    if names == "loading" or names == "idle" then
        self.hintText = tr("Admin_Pick_NamesLoading") .. "  " .. count
    elseif names == "partial" then
        self.hintText = tr("Admin_Pick_NamesPartial") .. "  " .. count
    else
        self.hintText = count
    end
end

-- A pick is a plain answer to the page that opened this: the overlay closes first, so the page
-- gets the keyboard and the screen back before it decides what to do with the record.
function Picker:choose(item)
    if item == nil or item.record == nil then return end
    local record = item.record
    self:close()
    if self.onPick then self.onPick(record) end
end

function Picker:cancel()
    self:close()
    if self.onCancel then self.onCancel() end
end

-- ----- open / close -----

function Picker:open()
    if self:getIsVisible() then return end
    setEntryText(self.entry, "")
    self.searchAt = nil
    self.searchSeen = ""
    ISPanel.setVisible(self, true)
    self.entry:setVisible(true)
    self.list:setVisible(true)
    self.cancelButton:setVisible(true)
    self:layout()
    -- the overlay owns the keyboard while it is up: the search box is where typing belongs, and
    -- the ring says so instead of staying on a control the page no longer offers
    if C.Keyboard then
        pcall(C.Keyboard.focusControl, self.entry, true)
        pcall(C.Keyboard.invalidate, keyboardRoot(self.owner))
    end
end

function Picker:close()
    if not self:getIsVisible() then return end
    pcall(self.entry.unfocus, self.entry)
    ISPanel.setVisible(self, false)
    self.entry:setVisible(false)
    self.list:setVisible(false)
    self.cancelButton:setVisible(false)
    if C.Keyboard then pcall(C.Keyboard.invalidate, keyboardRoot(self.owner)) end
end

-- ----- geometry -----

function Picker:layout()
    local w, h = self.width, self.height
    local eh, ch = entryH(), chipH()
    local inner = PAD
    local top = inner + CARD_TITLE_H + 4
    local cancelW = math.min(textWidth(self.cancelButton.fullTitle) + 24, math.max(48, math.floor(w * 0.3)))
    self.cancelButton:setWidth(cancelW)
    self.cancelButton:setHeight(ch)
    self.cancelButton:setX(w - inner - PAD - cancelW)
    self.cancelButton:setY(top)
    U.setButtonTitle(self.cancelButton, self.cancelButton.fullTitle)
    local entryW = math.max(80, w - inner * 2 - PAD * 3 - cancelW)
    self.entry:setX(inner + PAD)
    self.entry:setY(top)
    self.entry:setWidth(entryW)
    self.entry:setHeight(eh)
    self.hintY = top + math.max(eh, ch) + 6
    local listY = self.hintY + lineH() + 4
    U.placeList(self.list, self:getIsVisible(), inner + PAD, listY,
        math.max(80, w - inner * 2 - PAD * 2), math.max(lineH(), h - inner - PAD - listY))
    self:rebuild()
end

function Picker:resize(width, height)
    if self.width ~= width then self:setWidth(width) end
    if self.height ~= height then self:setHeight(height) end
    self:layout()
end

-- ----- painting -----

function Picker:prerender()
    local w, h = self.width, self.height
    -- an opaque backdrop over the whole page: the overlay is read against itself, never against
    -- the rows it covers
    U.theme:fill(self, 0, 0, w, h, "surface", nil, 1)
    card(self, PAD, PAD, math.max(1, w - PAD * 2), math.max(1, h - PAD * 2), tr("Admin_Pick_Title"))
    if self.hintText then
        text(self, fitText(self.hintText, math.max(0, w - PAD * 4)), PAD * 2, self.hintY, "textFaint")
    end
end

function Picker:render() end

-- Nothing behind the overlay is clickable while it is up: every mouse event that reaches the
-- backdrop stops here (the children are asked first, so the search box and the list still work).
function Picker:onMouseDown() return true end
function Picker:onMouseUp() return true end
function Picker:onRightMouseDown() return true end
function Picker:onRightMouseUp() return true end
function Picker:onMouseMove() return true end
function Picker:onMouseWheel() return true end

-- ----- lifecycle -----

function Picker:tick(now)
    if not self:getIsVisible() then return end
    if entryText(self.entry) ~= self.searchSeen then self:onSearch() end
    if self.searchAt ~= nil and now - self.searchAt > SEARCH_DEBOUNCE_MS then
        self.searchAt = nil
        self:rebuild()
    elseif self.namesRev ~= Names.revision then
        -- the English index landed while this overlay was open: the same query has a new answer
        -- (an English keyword that matched nothing a moment ago now matches), so it is asked once
        self:rebuild()
    end
end

function Picker:keyboardTargets()
    if not self:getIsVisible() then return {} end
    return {
        { kind = "entry", label = tr("Admin_Pick_Search"), control = self.entry },
        { kind = "list", label = tr("Admin_Pick_Title"), control = self.list },
        { kind = "button", label = tr("Admin_Cancel"), control = self.cancelButton },
    }
end

function Picker:dispose()
    self:close()
    self.onPick, self.onCancel = nil, nil
    self.list:setItems({})
end

-- ---------- module API ----------

function P.create(owner, policy, onPick, onCancel)
    local o = ISPanel:new(0, 0, 600, 400)
    setmetatable(o, Picker)
    o.background = false          -- the backdrop is painted by prerender, at full opacity
    o.owner = owner
    o.policy = policy == "market" and "market" or "shop"
    o.onPick, o.onCancel = onPick, onCancel
    o.total, o.shown = 0, 0
    o:initialise()
    o:instantiate()
    o:setVisible(false)
    o.entry:setVisible(false)
    o.list:setVisible(false)
    o.cancelButton:setVisible(false)
    return o
end

return P
