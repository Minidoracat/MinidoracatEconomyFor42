-- MinidoracatEconomyFor42 -- admin listing-whitelist page (client). Adds exactly one namespace:
-- C.AdminWhitelist.
--
--   C.AdminWhitelist.create(owner, isPending)
--       an initialised ISPanel child, NOT added (the admin controller addChild's it) and never
--       sends a command of its own. isPending is the controller's plain function, always called
--       as self.isPending(...), never with ":".
--
-- The controller owns the window chrome, the sub tab bar, the footer, the permission gate and the
-- one in-flight admin.whitelist slot; it positions this child at (0, bodyY, width, bodyH) and
-- keeps it visible exactly while the Whitelist tab is open and reading is allowed. Everything
-- from the card frame down belongs here. What it borrows, and nothing else:
--   owner:readAllowed() / owner:writeAllowed()   the two permission gates
--   owner:sendWhitelist(args)                    the only way a write leaves this page; the
--                                                controller stamps args.requestId into the table
--                                                it was handed, so the page can match its reply
--   owner:requestWhitelist()                     the read-only refresh
--   owner.message / owner.offsetMin              the shared footer line / the window's timezone
--   owner.dialog                                 a controller dialog owns the panel (modal)
--   owner.owner                                  the root window, the only thing
--                                                C.Keyboard.invalidate accepts
--
-- Two views, never mixed into one list, because they answer two different questions:
--   "cats"   the display categories of this server: a checkbox per category and the number of
--            listable items it holds. The search box searches category names only.
--   "items"  the items the file singles out -- the explicit rules, and only those. Each row is a
--            three-state editor (allow / exclude / by category), NOT a binary switch, plus what
--            is actually in force and where that verdict comes from. The search box searches the
--            set rules only; searching the whole item universe is what the picker does.
-- A rule for an item whose mod is gone keeps its row (the file still carries the line, and it
-- still counts): its category is unknown, and "by category" is the way to drop it.
--
-- The item picker is the shop slice's shared one (C.ItemPicker, policy "market": items no listing
-- may ever carry are not offered at all). Picking never writes: the picked item joins the rules
-- list as a row with no rule yet, and the admin presses one of its three chips.
--
-- Rows and truncation are rebuilt when a reply lands, when the search text changes and when the
-- geometry changes -- never per frame. No Events hook and no timer of its own: the controller
-- calls tick(now) while this page is up.

require "ISUI/ISPanel"
require "MinidoracatEconomy/ECWidgets"
require "MinidoracatEconomy/ECItemPicker"
require "MinidoracatEconomy/ECDetailWindow"

local EC = MinidoracatEconomy
local C = EC.Client
local U = C.UI
local ItemPicker = C.ItemPicker
local Detail = C.DetailWindow

local P = {}
C.AdminWhitelist = P

local PAD, T = U.PAD, U.T
local CARD_TITLE_H = U.CARD_TITLE_H
local fontH = U.fontH
local fill, border, text = U.fill, U.border, U.text
local textWidth, fitText, textCentre = U.textWidth, U.fitText, U.textCentre
local card, stampText = U.card, U.stampText
local Button = U.Button
local newEntry, entryText, setEntryEditable = U.newEntry, U.entryText, U.setEntryEditable
local errorText, itemName, itemTexture = U.adminErrorText, U.itemName, U.itemTexture

-- Rows one list ever paints. A file may hold more rules than this (nothing stops a host from
-- writing thousands): the extra ones are counted and said out loud instead of being silently
-- dropped or turned into an unbounded row list.
local WL_VISIBLE_MAX = 200

local MODES = { "allow", "exclude", "inherit" }
local MODE_KEY = { allow = "Admin_Wl_ModeAllow", exclude = "Admin_Wl_ModeExclude",
    inherit = "Admin_Wl_ModeInherit" }
local VIEWS = { "cats", "items" }
local VIEW_KEY = { cats = "Admin_Wl_ViewCats", items = "Admin_Wl_ViewItems" }

local function tr(key) return getText(T .. key) end
local function lineH() return fontH.small + 6 end
local function entryH() return math.max(26, fontH.small + 12) end
local function chipH() return math.max(24, fontH.small + 6) end

-- DisplayCategory name the way the vanilla inventory paints it (ISInventoryPane.lua:2533): the
-- engine's own IGUI_ItemCat_* key, falling back to the raw script category.
local function itemCategoryName(category)
    local key = tostring(category or "-")
    return getTextOrNull("IGUI_ItemCat_" .. key) or key
end

local function paintIcon(cell, e)
    if not e.icon then return end
    local ok = pcall(cell.drawTextureScaled, cell, e.icon, PAD, e.iconY, e.iconSize, e.iconSize, 1, 1, 1, 1)
    if not ok then e.icon = nil end
end

-- The checkbox of a category row. A box, and a filled core when the category is allowed; the word
-- beside it says the same thing, so the state never depends on reading a shape.
local function paintCheck(el, x, y, size, on, off)
    fill(el, x, y, size, size, on and "selected" or "well", "round")
    border(el, x, y, size, size, off and "border" or "accent", "round")
    if on then fill(el, x + 4, y + 4, math.max(2, size - 8), math.max(2, size - 8), "accent", "round") end
end

-- ---------- the rules themselves (pure; no UI, no engine) ----------

local function setOf(list)
    local set = {}
    if type(list) == "table" then
        for _, v in ipairs(list) do
            if type(v) == "string" then set[v] = true end
        end
    end
    return set
end

-- The file's three lists as sets. One snapshot in, one derived table out: the page never keeps a
-- second copy of what the server holds, only this index of it.
local function wlSets(wl)
    if type(wl) ~= "table" then return { categories = {}, allow = {}, exclude = {} } end
    return { categories = setOf(wl.categories), allow = setOf(wl.types), exclude = setOf(wl.excludeTypes) }
end

-- The rule this item has of its own: exclude wins over allow (Codec.check), and "inherit" means
-- the file says nothing about it.
local function ruleMode(sets, fullType)
    if sets.exclude[fullType] then return "exclude" end
    if sets.allow[fullType] then return "allow" end
    return "inherit"
end

-- What is actually in force, and why. `fixed` is the item class the market refuses whatever the
-- file says (EC.isFixedType): that verdict is above the file and is reported as its own source,
-- never as "denied by a rule the admin could change".
local function effectiveState(sets, fullType, category, fixed)
    if fixed then return false, "fixed" end
    local mode = ruleMode(sets, fullType)
    if mode == "exclude" then return false, "rule" end
    if mode == "allow" then return true, "rule" end
    if type(category) == "string" and sets.categories[category] == true then return true, "category" end
    return false, "none"
end

-- Listable items per display category. The fixed classes are left out: counting items no listing
-- may ever carry would promise a category more than it can deliver.
local function categoryCounts(universe)
    local counts = {}
    for _, rec in ipairs(universe and universe.items or {}) do
        if not rec.fixed and type(rec.category) == "string" and rec.category ~= "" then
            counts[rec.category] = (counts[rec.category] or 0) + 1
        end
    end
    return counts
end

-- ---------- cells ----------

-- One category: the checkbox, the localised name over the raw name and the item count, and the
-- state word on the right. Every string and hit box is computed once per rebuild.
local CatCell = ISPanel:derive("MinidoracatEconomyWlCatCell")

function CatCell:render()
    local e = self.entry
    if not e then return end
    if self.list:isSelected(self.index) then fill(self, 0, 0, self.width, self.height, "selected", "rect")
    elseif self.index % 2 == 0 then fill(self, 0, 0, self.width, self.height, "card", "rect") end
    local off = self.list.optionsDisabled == true
    paintCheck(self, e.boxX, e.boxY, e.boxSize, e.allowed, off)
    text(self, e.nameText, e.nameX, e.line1Y, "text")
    text(self, e.metaText, e.nameX, e.line2Y, "textFaint")
    text(self, e.stateText, e.stateX, e.stateY,
        off and "textFaint" or (e.allowed and "positive" or "textMuted"))
end

-- One explicit rule: the item on the left, the verdict in force in the middle, the three-state
-- editor on the right. The three chips are the state: the one that is set is filled, so no chip
-- ever has to be read as "the opposite of what you see".
local RuleCell = ISPanel:derive("MinidoracatEconomyWlRuleCell")

function RuleCell:render()
    local e = self.entry
    if not e then return end
    if self.list:isSelected(self.index) then fill(self, 0, 0, self.width, self.height, "selected", "rect")
    elseif self.index % 2 == 0 then fill(self, 0, 0, self.width, self.height, "card", "rect") end
    local off = self.list.optionsDisabled == true
    paintIcon(self, e)
    text(self, e.nameText, e.nameX, e.line1Y, "text")
    if e.altText then text(self, e.altText, e.altX, e.line1Y, "textFaint") end
    text(self, e.metaText, e.nameX, e.line2Y, e.orphan and "warn" or "textFaint")
    text(self, e.stateText, e.effX, e.line1Y,
        off and "textFaint" or (e.allowed and "positive" or "textMuted"))
    text(self, e.sourceText, e.effX, e.line2Y, "textFaint")
    for _, hit in ipairs(e.hits) do
        if hit.label then
            local active = hit.id == e.mode
            fill(self, hit.x, hit.y, hit.w, hit.h, active and "selected" or "well", "pill")
            border(self, hit.x, hit.y, hit.w, hit.h, off and "border" or "accent", "pill")
            textCentre(self, hit.label, hit.x + hit.w / 2, hit.y + e.chipTextY,
                off and "textFaint" or (active and "text" or "textMuted"))
        end
    end
end

local Page = ISPanel:derive("MinidoracatEconomyAdminWhitelistPage")

-- One chip row. The slot is budgeted, never natural: a long translation truncates its own label
-- instead of pushing a chip off the card.
local function chipRow(buttons, visible, x, y, width, height)
    local shown = 0
    for _, b in ipairs(buttons) do
        if b.wanted then shown = shown + 1 end
    end
    local cap = math.max(24, (width - math.max(0, shown - 1) * 6) / math.max(1, shown))
    for _, b in ipairs(buttons) do
        local want = visible and b.wanted == true
        b:setVisible(want)
        if want then
            b:setWidth(math.floor(math.min(textWidth(b.fullTitle) + 20, cap)))
            b:setHeight(height); b:setX(math.floor(x)); b:setY(y)
            U.setButtonTitle(b, b.fullTitle)
            x = x + b.width + 6
        end
    end
end

local function selectedRow(list)
    if list == nil or list.getSelectedIndex == nil then return nil end
    local index = list:getSelectedIndex()
    if type(index) ~= "number" then return nil end
    local rows = list.items
    if type(rows) ~= "table" then return nil end
    return rows[index]
end

-- ----- controls -----

function Page:createChildren()
    local function chip(label, handler, internal)
        local b = Button.create(0, 0, textWidth(label) + 20, 22, label, self, handler, "chip")
        b.internal = internal
        self:addChild(b)
        return b
    end

    self.viewButtons = {}
    for _, view in ipairs(VIEWS) do
        local b = chip(tr(VIEW_KEY[view]), Page.onView, view)
        b.active = view == self.view
        self.viewButtons[#self.viewButtons + 1] = b
    end
    self.reloadButton = chip(tr("Admin_Wl_Reload"), Page.onReload, "reload")
    self.noteButton = chip(tr("Admin_Wl_Info"), Page.onNote, "note")

    self.searchEntry = newEntry(240, entryH(), { maxLen = 64, clear = true,
        placeholder = tr("Admin_Wl_CatSearch") })
    self.searchEntry.target = self
    self.searchEntry.onTextChangeFunction = Page.onSearch
    self:addChild(self.searchEntry)

    -- the keyboard's equal of every pointer path: the lists are selectable, and these act on the
    -- row that is selected. The category checkbox has no chip of its own -- Enter / Space over
    -- the category list is that checkbox (see catList.ecKey below), so the toolbar does not
    -- repeat a control the row already carries.
    self.addButton = chip(tr("Admin_Wl_AddItem"), Page.onAddItem, "add")
    self.allowButton = chip(tr("Admin_Wl_AllowSelected"), Page.onModeSelected, "allow")
    self.excludeButton = chip(tr("Admin_Wl_ExcludeSelected"), Page.onModeSelected, "exclude")
    self.inheritButton = chip(tr("Admin_Wl_InheritSelected"), Page.onModeSelected, "inherit")
    self.pickClearButton = chip(tr("Admin_Wl_PickClear"), Page.onPickClear, "pickClear")
    self.copyButton = chip(tr("Admin_Wl_CopySelected"), Page.onCopySelected, "copy")
    self.actionButtons = { self.addButton, self.allowButton, self.excludeButton,
        self.inheritButton, self.pickClearButton, self.copyButton }

    -- both lists carry controls inside their rows, so a press records where inside the row it
    -- landed; `clicked` is what tells the selection a mouse, not the keyboard, caused it
    local function newList(cellClass, rowHeight, onRow)
        local list = U.newTable(cellClass, rowHeight)
        local down = list.onMouseDown
        list.onMouseDown = function(l, x, y)
            self.clickX = x
            self.clickY = (y + l.scrollOffset) % (l.rowHeight + (l.padding or 0))
            self.clicked = true
            return down(l, x, y)
        end
        list.onSelect = function(_, item) onRow(self, item) end
        self:addChild(list)
        return list
    end
    self.catList = newList(CatCell, lineH() * 2 + 10, Page.onCatRow)
    self.ruleList = newList(RuleCell, lineH() * 2 + 12, Page.onRuleRow)
    -- Enter / Space over the category list *is* the row's checkbox. ECKeyboard offers every key
    -- to a list descriptor's own ecKey first (ECKeyboard.lua:485-487), so exactly these two are
    -- claimed here and the arrows keep walking the rows.
    self.catList.ecKey = function(list, key)
        if key ~= Keyboard.KEY_SPACE and key ~= Keyboard.KEY_RETURN
            and key ~= Keyboard.KEY_NUMPADENTER then return false end
        local row = selectedRow(list)
        if row == nil then
            self.owner.message = { text = tr("Admin_Wl_PickRowFirst"), error = true }
            return true
        end
        self:setCategory(row.cat, not row.allowed)
        return true
    end

    -- the shop slice's shared picker, hosted inside this page: policy "market" never offers an
    -- item class a listing could not carry. Added last, so it paints over everything above.
    self.picker = ItemPicker.create(self, "market",
        function(record) self:onPicked(record) end,
        function() self:onPickCancelled() end)
    self:addChild(self.picker)

    self:layout()
end

-- ----- actions -----

function Page:invalidateKeyboard()
    if C.Keyboard and C.Keyboard.invalidate then pcall(C.Keyboard.invalidate, self.owner.owner) end
end

function Page:onView(button)
    if self.view == button.internal then return end
    self.view = button.internal
    for _, b in ipairs(self.viewButtons) do b.active = b.internal == self.view end
    -- each view searches its own scope, so the box starts empty instead of carrying a query that
    -- meant something else on the other view
    self.query = nil
    U.setEntryText(self.searchEntry, "")
    pcall(self.searchEntry.unfocus, self.searchEntry)
    self:layout()
    self:invalidateKeyboard()
end

-- The standing notes (what this file is, and the classes no rule can ever allow) in the shared
-- detail window: it scrolls, CopyAll takes the whole block and closing it gives nothing up,
-- because every row of the list is still on screen behind it. Pressing the chip again while the
-- window is up closes it, so the one chip is the whole switch.
function Page:noteText()
    local detail = self.readError or (self.timedOut and tr("Admin_Wl_Timeout")) or self:fileStatusText()
    return detail .. "\n\n" .. tr("Admin_Wl_Note") .. "\n\n" .. tr("Admin_Wl_Fixed")
        .. "\n\n" .. tr("Admin_Wl_PickerNote") .. "\n\n" .. tr("Admin_Wl_KeyHint")
end

function Page:onNote()
    if Detail.isOpen(self, "whitelist:info") then
        Detail.close(self)
    else
        Detail.open(self, "whitelist:info", tr("Admin_Wl_Info"), self:noteText())
    end
    self:layout()
    self:invalidateKeyboard()
end

function Page:onSearch()
    self.searchSeen = entryText(self.searchEntry)
    local raw = string.match(self.searchSeen, "^%s*(.-)%s*$")
    self.query = raw ~= "" and string.lower(raw) or nil
    self:rebuild()
end

function Page:onReload()
    self.owner.message = nil
    self:send({ action = "reload" })
end

-- Every write goes out through the controller, which owns the one in-flight whitelist slot and
-- stamps the requestId into the very table handed to it; that is how the reply is matched here
-- without keeping a second idea of what is pending.
function Page:send(args, note)
    if self.owner:sendWhitelist(args) then
        self.sent = { requestId = args.requestId, action = args.action, note = note }
        self:updateEnabled()
        return true
    end
    return false
end

function Page:setCategory(cat, allowed)
    if cat == nil or self.catList.optionsDisabled then return end
    self.owner.message = nil
    self:send({ action = "set", category = cat, allowed = allowed })
end

function Page:setRule(fullType, mode)
    if fullType == nil or self.ruleList.optionsDisabled then return end
    self.owner.message = nil
    self:send({ action = "set", fullType = fullType, mode = mode }, fullType)
end

-- The hit box a mouse press landed in, or nil. A keyboard activation reaches the same handlers
-- with no click behind it (`clicked` is only set by a mouse press), so Enter selects the row and
-- the action chips are what change it.
function Page:clickedHit(item)
    local clicked = self.clicked
    self.clicked = false
    if item == nil or not clicked then return nil end
    local x, y = self.clickX or 0, self.clickY or 0
    for _, hit in ipairs(item.hits) do
        if x >= hit.x and x < hit.x + hit.w and y >= hit.y and y < hit.y + hit.h then return hit end
    end
    return nil
end

-- the checkbox column and the state word are the category row's control
function Page:onCatRow(item)
    if self:clickedHit(item) then self:setCategory(item.cat, not item.allowed) end
end

-- an item row's control is whichever of the three mode chips was pressed
function Page:onRuleRow(item)
    local hit = self:clickedHit(item)
    if hit then self:setRule(item.fullType, hit.id) end
end

function Page:onModeSelected(button)
    local row = selectedRow(self.ruleList)
    if row == nil then
        self.owner.message = { text = tr("Admin_Wl_PickRowFirst"), error = true }
        return
    end
    self:setRule(row.fullType, button.internal)
end

function Page:onCopySelected()
    local row = self.view == "cats" and selectedRow(self.catList) or selectedRow(self.ruleList)
    if row == nil then
        self.owner.message = { text = tr("Admin_Wl_PickRowFirst"), error = true }
        return
    end
    -- the whole record, never the truncated column: a name the row had to cut is still reachable
    local value = row.copyText
    if type(value) ~= "string" or value == "" then return end
    if not (Clipboard and Clipboard.setClipboard) then
        self.owner.message = { text = tr("Admin_Sys_CopyFailed"), error = true }
        return
    end
    local ok = pcall(Clipboard.setClipboard, value)
    self.owner.message = ok and { text = getText(T .. "Admin_Audit_Copied", value) }
        or { text = tr("Admin_Sys_CopyFailed"), error = true }
end

-- ----- the picker (hosted, never a singleton, never a write) -----

function Page:onAddItem()
    self.owner.message = nil
    self.picker:open()
    self:layout()
    self:invalidateKeyboard()
end

-- Picking sets nothing: the item joins the rules list as the row it would be, with the rule it
-- has now (usually none), and the admin presses one of its three chips. The list is where the
-- decision is made, so the picked item is edited exactly like every other rule.
function Page:onPicked(record)
    if type(record) ~= "table" then return end
    self.pick = record
    self.view = "items"
    for _, b in ipairs(self.viewButtons) do b.active = b.internal == self.view end
    self:layout()
    self.ruleList:setSelectedIndex(1)
    self:invalidateKeyboard()
end

function Page:onPickCancelled()
    self:layout()
    self:invalidateKeyboard()
    if C.Keyboard then C.Keyboard.refocus(self.addButton) end
end

function Page:onPickClear()
    self.pick = nil
    self:layout()
    self:invalidateKeyboard()
end

-- ----- overlay contract (the controller asks; the root obeys) -----

function Page:isModal()
    return self.picker:getIsVisible()
end

function Page:onEscape()
    if self:isModal() then
        self.picker:cancel()
        return true
    end
    return false
end

-- ----- keyboard targets (C.Keyboard walks these; this page owns no key dispatch) -----

function Page:keyboardTargets()
    if self:isModal() then return self.picker:keyboardTargets() end
    local out = {}
    local function add(kind, label, control, controls)
        out[#out + 1] = { kind = kind, label = label, control = control, controls = controls }
    end
    local function group(label, buttons)
        local shown = {}
        for _, b in ipairs(buttons) do
            if b:getIsVisible() then shown[#shown + 1] = b end
        end
        if #shown > 0 then add("group", label, nil, shown) end
    end
    group(tr("Admin_Wl_Views"), { self.viewButtons[1], self.viewButtons[2], self.noteButton,
        self.reloadButton })
    add("entry", tr(self.view == "cats" and "Admin_Wl_CatSearchLabel" or "Admin_Wl_ItemSearchLabel"),
        self.searchEntry)
    group(tr("Admin_Wl_Actions"), self.actionButtons)
    -- the standing notes are a window of their own now: its own keyboard root owns them
    if self.view == "cats" then
        add("list", tr("Admin_Wl_ViewCats"), self.catList)
    else
        add("list", tr("Admin_Wl_ViewItems"), self.ruleList)
    end
    return out
end

-- ----- transport -----

-- Every reply carries the file's whole state back, a refusal included, so the page always shows
-- what the server actually holds and never a guess about what a write did.
function Page:onReply(kind, args)
    if kind ~= "whitelist" or type(args) ~= "table" then return end
    if type(args.whitelist) == "table" then
        self.whitelist = args.whitelist
        self.sets = wlSets(args.whitelist)
        self.readError = nil
        self.timedOut = false
    end
    local sent = self.sent
    local mine = sent == nil or args.requestId == nil or sent.requestId == args.requestId
    if mine then
        self.sent = nil
        if args.ok == false then
            -- whitelist_invalid carries the file's own parse error: the code alone would not tell
            -- the host which line to go and fix
            local body = errorText(args.error)
            if type(args.detail) == "string" and args.detail ~= "" then body = body .. ": " .. args.detail end
            self.owner.message = { text = body, error = true }
            self.readError = body
        elseif sent ~= nil and sent.action == "reload" then
            self.owner.message = { text = tr("Admin_Wl_Reloaded") }
        elseif sent ~= nil and sent.action == "set" then
            self.owner.message = { text = tr("Admin_Wl_Saved") }
            -- the picked item now has a rule of its own: the list carries it, so the staged row
            -- has nothing left to say
            if sent.note ~= nil and self.pick ~= nil and self.pick.fullType == sent.note then
                self.pick = nil
            end
        end
    end
    self:layout()
end

function Page:onTimeout(command)
    if command ~= "admin.whitelist" then return end
    self.sent = nil
    if self.whitelist == nil then self.timedOut = true end
    self:layout()
end

-- ----- rows (data or geometry changes only) -----

function Page:catGeometry(width)
    local boxSize = math.min(math.max(14, fontH.small + 4), 24)
    local geo = { boxSize = boxSize, boxX = PAD }
    geo.nameX = PAD + boxSize + 8
    geo.stateW = math.max(textWidth(tr("Admin_Wl_On")), textWidth(tr("Admin_Wl_Off")))
    geo.stateX = math.max(geo.nameX + 40, width - PAD - geo.stateW)
    geo.textLimit = math.max(0, geo.stateX - 8)
    return geo
end

function Page:catRow(entry, allowed, geo, lh, rowHeight)
    local item = {
        kind = "category", cat = entry.cat, allowed = allowed, hits = {},
        line1Y = 5, line2Y = 5 + lh, nameX = geo.nameX, boxX = geo.boxX, boxSize = geo.boxSize,
        boxY = math.max(2, math.floor((rowHeight - geo.boxSize) / 2)),
        stateX = geo.stateX, stateY = math.floor((rowHeight - fontH.small) / 2),
        stateText = allowed and tr("Admin_Wl_On") or tr("Admin_Wl_Off"),
    }
    local textW = math.max(0, geo.textLimit - geo.nameX)
    item.nameText = fitText(entry.label, textW)
    local meta = entry.count > 0 and getText(T .. "Admin_Wl_Items", tostring(entry.count))
        or tr("Admin_Wl_Unknown")
    if entry.label ~= entry.cat then meta = entry.cat .. " / " .. meta end
    item.metaText = fitText(meta, textW)
    item.copyText = entry.cat
    -- the checkbox column and the state word are the control; the rest of the row only selects
    item.hits[#item.hits + 1] = { id = "toggle", x = 0, y = 0, w = geo.nameX, h = rowHeight }
    item.hits[#item.hits + 1] = { id = "toggle", x = math.max(0, geo.stateX - 6), y = 0,
        w = math.max(1, geo.stateW + 12), h = rowHeight }
    return item
end

-- Right to left: the three mode chips (always all three, in one order, so a row never moves its
-- controls when its state changes), then the verdict in force over the reason for it.
function Page:ruleGeometry(width, ch)
    local geo = { chipH = ch, chipTextY = math.floor((ch - fontH.small) / 2), labels = {},
        chipX = {}, chipW = {} }
    local total = 0
    for i, mode in ipairs(MODES) do
        local label = tr(MODE_KEY[mode])
        geo.labels[i] = label
        geo.chipW[i] = textWidth(label) + 16
        total = total + geo.chipW[i]
    end
    total = total + 8
    local x = math.max(60, width - PAD - total)
    for i = 1, #MODES do
        geo.chipX[i] = x
        x = x + geo.chipW[i] + 4
    end
    geo.effW = math.max(40, math.min(math.floor(width * 0.28),
        math.max(textWidth(tr("Admin_Wl_On")), textWidth(tr("Admin_Wl_Off")),
            textWidth(tr("Admin_Wl_FromRule")))))
    geo.effX = math.max(30, geo.chipX[1] - 8 - geo.effW)
    geo.textLimit = math.max(0, geo.effX - 8)
    return geo
end

local function ruleSourceText(source, category)
    if source == "fixed" then return tr("Admin_Wl_FromFixed") end
    if source == "rule" then return tr("Admin_Wl_FromRule") end
    if source == "category" then return getText(T .. "Admin_Wl_FromCategory", itemCategoryName(category)) end
    return tr("Admin_Wl_FromNone")
end

function Page:ruleRow(rec, geo, lh, rowHeight, staged)
    local size = math.min(math.max(12, rowHeight - 10), 28)
    local allowed, source = effectiveState(self.sets, rec.fullType, rec.category, rec.fixed)
    local item = {
        kind = "item", fullType = rec.fullType, hits = {}, orphan = rec.orphan,
        mode = ruleMode(self.sets, rec.fullType),
        line1Y = 5, line2Y = 5 + lh, chipTextY = geo.chipTextY, effX = geo.effX,
        icon = itemTexture(rec.fullType), iconSize = size,
        iconY = math.floor((rowHeight - size) / 2),
        allowed = allowed,
        stateText = fitText(allowed and tr("Admin_Wl_On") or tr("Admin_Wl_Off"), geo.effW),
        sourceText = fitText(ruleSourceText(source, rec.category), geo.effW),
    }
    item.nameX = PAD + size + 6
    local textW = math.max(0, geo.textLimit - item.nameX)
    item.nameText = fitText(rec.name, textW)
    if type(rec.original) == "string" and rec.original ~= "" and rec.original ~= rec.name then
        item.altX = item.nameX + textWidth(item.nameText) + 8
        local altW = geo.textLimit - item.altX
        if altW > 20 then item.altText = fitText(rec.original, altW) end
    end
    local meta = rec.fullType
    if rec.orphan then
        meta = meta .. " / " .. tr("Admin_Wl_Orphan")
    elseif staged then
        meta = meta .. " / " .. itemCategoryName(rec.category) .. " / " .. tr("Admin_Wl_Staged")
    elseif type(rec.category) == "string" and rec.category ~= "" then
        meta = meta .. " / " .. itemCategoryName(rec.category)
    end
    item.metaText = fitText(meta, textW)
    item.copyText = meta .. "\n" .. rec.name
    if type(rec.original) == "string" and rec.original ~= "" and rec.original ~= rec.name then
        item.copyText = item.copyText .. "\n" .. rec.original
    end
    item.copyText = item.copyText .. "\n" .. tr(MODE_KEY[item.mode]) .. "\n"
        .. tr(allowed and "Admin_Wl_On" or "Admin_Wl_Off") .. " / " .. ruleSourceText(source, rec.category)
    local chipY = math.max(3, math.floor((rowHeight - geo.chipH) / 2))
    for i, mode in ipairs(MODES) do
        item.hits[#item.hits + 1] = { id = mode, x = geo.chipX[i], y = chipY, w = geo.chipW[i],
            h = geo.chipH, label = geo.labels[i] }
    end
    return item
end

-- Every display category this server has listable items in, plus the ones only the file names (a
-- stale line can still be switched off from here).
function Page:rebuildCats()
    local rows = {}
    local total, allowedTotal = 0, 0
    if self.whitelist ~= nil then
        local list = self.catList
        local geo = self:catGeometry(math.max(120, list.width - 12))   -- 12 = the scrollbar gutter
        local lh = lineH()
        local counts = categoryCounts(ItemPicker.universe())
        for cat in pairs(self.sets.categories) do
            if counts[cat] == nil then counts[cat] = 0 end
        end
        local picked = {}
        for cat, n in pairs(counts) do
            if self.sets.categories[cat] == true then allowedTotal = allowedTotal + 1 end
            total = total + 1
            local label = itemCategoryName(cat)
            local query = self.query
            if query == nil or string.find(string.lower(label), query, 1, true) ~= nil
                or string.find(string.lower(cat), query, 1, true) ~= nil then
                picked[#picked + 1] = { cat = cat, label = label, count = n }
            end
        end
        EC.sortSafe(picked, function(a, b) return a.label < b.label end)
        self.catMatched = #picked
        for i, entry in ipairs(picked) do
            if i > WL_VISIBLE_MAX then break end
            rows[#rows + 1] = self:catRow(entry, self.sets.categories[entry.cat] == true, geo, lh,
                list.rowHeight)
        end
    else
        self.catMatched = 0
    end
    self.catTotal, self.catAllowed = total, allowedTotal
    self.catList:setItems(rows)
end

-- The items the file singles out, and only those: allow list, exclude list, plus the item that
-- was just picked (which has no rule yet). A rule whose item this server no longer has keeps its
-- row -- the line is still in the file, and "by category" is how it goes away.
function Page:rebuildRules()
    local rows = {}
    local total = 0
    if self.whitelist ~= nil then
        local list = self.ruleList
        local geo = self:ruleGeometry(math.max(120, list.width - 12), chipH())
        local lh = lineH()
        local uni = ItemPicker.universe()
        local query = self.query
        local picked, seen = {}, {}
        local staged = self.pick
        if staged ~= nil then
            seen[staged.fullType] = true
            total = total + 1
        end
        for _, field in ipairs({ "types", "excludeTypes" }) do
            for _, fullType in ipairs(self.whitelist[field] or {}) do
                if type(fullType) == "string" and not seen[fullType] then
                    seen[fullType] = true
                    total = total + 1
                    local rec = uni.byType[fullType]
                    if rec == nil then
                        local name = itemName(fullType)
                        rec = { fullType = fullType, name = name, orphan = true,
                            search = string.lower(name .. " " .. fullType) }
                    end
                    if query == nil or string.find(rec.search or "", query, 1, true) ~= nil then
                        picked[#picked + 1] = rec
                    end
                end
            end
        end
        EC.sortSafe(picked, function(a, b) return a.name < b.name end)
        self.ruleMatched = #picked + (staged ~= nil and 1 or 0)
        -- the staged row leads: it is the one thing on this page that is waiting for a decision
        if staged ~= nil then
            rows[#rows + 1] = self:ruleRow(staged, geo, lh, list.rowHeight, true)
        end
        for _, rec in ipairs(picked) do
            if #rows >= WL_VISIBLE_MAX then break end
            rows[#rows + 1] = self:ruleRow(rec, geo, lh, list.rowHeight, false)
        end
    else
        self.ruleMatched = 0
    end
    self.ruleTotal = total
    self.ruleList:setItems(rows)
end

function Page:rebuild()
    self:rebuildCats()
    self:rebuildRules()
end

-- ----- what each view is showing, as exactly one state -----

-- The state is read off the rows that are really up, never off a count kept beside them: a file
-- error still lets the rows the server last sent be read, so it is the status line's business,
-- not an overlay over the list.
function Page:listStatus()
    local list = self.view == "cats" and self.catList or self.ruleList
    local rows = list.items
    if type(rows) == "table" and #rows > 0 then return "ready" end
    if self.whitelist == nil then
        if self.timedOut then return "timeout" end
        if self.readError ~= nil then return "failed" end
        if self.isPending("admin.whitelist") then return "loading" end
        return "empty"
    end
    if self.query ~= nil then return "nomatch" end
    return "none"
end

function Page:statusText(state)
    if state == "loading" then return tr("Admin_Loading") end
    if state == "timeout" then return tr("Admin_Wl_Timeout") end
    if state == "failed" then return self.readError or tr("Admin_Dash_Empty") end
    if state == "empty" then return tr("Admin_Dash_Empty") end
    if state == "nomatch" then
        return tr(self.view == "cats" and "Admin_Wl_NoCatMatch" or "Admin_Wl_NoRuleMatch")
    end
    if state == "none" then
        return tr(self.view == "cats" and "Admin_Wl_NoCats" or "Admin_Wl_NoRules")
    end
    return nil
end

-- The line above the list: how much of the file this view is showing, the cap when the file holds
-- more rules than one list ever paints, and -- for a role that may only read -- why nothing here
-- can be pressed.
function Page:summaryText()
    local parts = nil
    local function add(s)
        if s == nil or s == "" then return end
        parts = parts and (parts .. "   " .. s) or s
    end
    if self.whitelist ~= nil then
        if self.view == "cats" then
            add(getText(T .. "Admin_Wl_CatSummary", tostring(self.catAllowed or 0),
                tostring(self.catTotal or 0)))
            if (self.catMatched or 0) > WL_VISIBLE_MAX then
                add(getText(T .. "Admin_Wl_More", tostring(WL_VISIBLE_MAX), tostring(self.catMatched)))
            elseif self.query ~= nil then
                add(getText(T .. "Admin_Wl_Shown", tostring(self.catMatched or 0),
                    tostring(self.catTotal or 0)))
            end
        else
            local counts = self.whitelist.counts or {}
            add(getText(T .. "Admin_Wl_RuleSummary", tostring(counts.types or 0),
                tostring(counts.excludeTypes or 0)))
            if (self.ruleMatched or 0) > WL_VISIBLE_MAX then
                add(getText(T .. "Admin_Wl_More", tostring(WL_VISIBLE_MAX), tostring(self.ruleMatched)))
            elseif self.query ~= nil then
                add(getText(T .. "Admin_Wl_Shown", tostring(self.ruleMatched or 0),
                    tostring(self.ruleTotal or 0)))
            end
        end
    end
    if not self.owner:writeAllowed() then add(tr("Admin_Wl_ReadOnly")) end
    return parts
end

function Page:fileStatusText()
    if self.readError then return self.readError, "errorText" end
    local wl = self.whitelist
    if wl == nil then
        return self.isPending("admin.whitelist") and tr("Admin_Loading") or tr("Admin_Dash_Empty"), "textFaint"
    end
    if type(wl.error) == "string" and wl.error ~= "" then
        return getText(T .. "Admin_Wl_Error", wl.error), "errorText"
    end
    local counts = wl.counts or {}
    return getText(T .. "Admin_Wl_Status", tostring(counts.categories or 0),
        tostring(counts.types or 0), tostring(counts.excludeTypes or 0),
        wl.loadedAt and stampText(wl.loadedAt, self.owner.offsetMin) or "-"), "text"
end

-- ----- enabling -----

function Page:updateEnabled()
    local read = self.owner:readAllowed()
    local modal = self.owner.dialog ~= nil or self:isModal()
    local busy = self.isPending("admin.whitelist")
    local write = self.owner:writeAllowed() and not modal and not busy
    self.catList.optionsDisabled = not write
    self.ruleList.optionsDisabled = not write
    self.reloadButton:setEnable(write)
    self.allowButton:setEnable(write)
    self.excludeButton:setEnable(write)
    self.inheritButton:setEnable(write)
    -- opening the picker is not a write: a read-only role may look up what an item is called, it
    -- simply cannot press a rule chip afterwards
    self.addButton:setEnable(read and not modal)
    self.pickClearButton:setEnable(read and not modal)
    self.copyButton:setEnable(read and not modal)
    self.noteButton:setEnable(read and not modal)
    for _, b in ipairs(self.viewButtons) do b:setEnable(read and not modal) end
    setEntryEditable(self.searchEntry, read and not modal)
end

-- ----- geometry -----

function Page:layout()
    local w, h = self.width, self.height
    local lh, eh, ch = lineH(), entryH(), chipH()
    local g = {}
    self.g = g
    local on = self:getIsVisible()
    local cats = on and self.view == "cats"
    local items = on and self.view == "items"
    local listW = math.max(160, w - PAD * 2)

    -- row A: what the file says about itself, and the chip that re-reads it
    local top = CARD_TITLE_H + 4
    local reloadW = math.min(textWidth(self.reloadButton.fullTitle) + 24, math.floor(w * 0.4))
    self.reloadButton:setVisible(on)
    self.reloadButton:setWidth(reloadW); self.reloadButton:setHeight(ch)
    self.reloadButton:setX(math.max(PAD, w - PAD - reloadW)); self.reloadButton:setY(top)
    U.setButtonTitle(self.reloadButton, self.reloadButton.fullTitle)
    g.statusY = top + math.floor((ch - fontH.small) / 2)
    g.statusW = math.max(0, self.reloadButton.x - PAD * 2)

    -- row B: the two views, and the disclosure for the standing notes
    local viewY = top + ch + 4
    local viewX = PAD
    for _, b in ipairs(self.viewButtons) do
        b:setVisible(on)
        b:setWidth(math.min(textWidth(b.fullTitle) + 24, math.max(40, math.floor(w * 0.3))))
        b:setHeight(ch); b:setX(viewX); b:setY(viewY)
        U.setButtonTitle(b, b.fullTitle)
        viewX = viewX + b.width + 6
    end
    local noteW = math.min(textWidth(self.noteButton.fullTitle) + 24, math.floor(w * 0.3))
    self.noteButton:setVisible(on)
    self.noteButton:setWidth(noteW); self.noteButton:setHeight(ch)
    self.noteButton:setX(math.max(viewX, w - PAD - noteW)); self.noteButton:setY(viewY)
    self.noteButton.active = Detail.isOpen(self, "whitelist:info")
    U.setButtonTitle(self.noteButton, self.noteButton.fullTitle)

    -- row C: the search box of this view, and the scope it searches said in words beside it
    local searchY = viewY + ch + 4
    g.scopeLabel = tr(self.view == "cats" and "Admin_Wl_CatScope" or "Admin_Wl_ItemScope")
    local hint = tr(self.view == "cats" and "Admin_Wl_CatSearch" or "Admin_Wl_ItemSearch")
    if self.searchHint ~= hint then
        self.searchHint = hint
        pcall(self.searchEntry.setPlaceholderText, self.searchEntry, hint)
    end
    if not on and self.searchEntry:isFocused() then self.searchEntry:unfocus() end
    self.searchEntry:setVisible(on)
    self.searchEntry:setX(PAD); self.searchEntry:setY(searchY)
    self.searchEntry:setWidth(math.max(120, math.min(280, math.floor(w * 0.32))))
    self.searchEntry:setHeight(eh)
    g.scopeX = PAD + self.searchEntry.width + PAD
    g.scopeY = searchY + math.floor((eh - fontH.small) / 2)
    g.scopeW = math.max(0, w - PAD - g.scopeX)

    -- row D: the actions of this view. The keyboard reaches every one of them, and each acts on
    -- the row the list has selected, so no control lives only inside a cell.
    local actionY = searchY + eh + 4
    self.addButton.wanted = items
    self.allowButton.wanted = items
    self.excludeButton.wanted = items
    self.inheritButton.wanted = items
    self.pickClearButton.wanted = items and self.pick ~= nil
    self.copyButton.wanted = on
    chipRow(self.actionButtons, on, PAD, actionY, listW, ch)

    -- the rows start right under the one-line summary: the standing notes are a window now, so
    -- nothing here is ever traded for them
    local summaryY = actionY + ch + 4
    local listTop = summaryY + lh + 2
    g.summaryY = summaryY
    g.emptyY = listTop + 4

    local listH = math.max(lh, h - PAD - listTop)
    U.placeList(self.catList, cats, PAD, listTop, listW, listH)
    U.placeList(self.ruleList, items, PAD, listTop, listW, listH)

    -- the picker covers the whole page: it paints its own backdrop and eats every click, so
    -- nothing behind it can be reached while it is open
    self.picker:setX(0); self.picker:setY(0)
    self.picker:resize(w, h)

    self:rebuild()
    self:updateEnabled()
end

function Page:resize(width, height)
    if self.width ~= width then self:setWidth(width) end
    if self.height ~= height then self:setHeight(height) end
    self:layout()
end

-- Hiding the page takes its controls off the keyboard's list and off the screen. The snapshot is
-- kept (coming back must not re-read what is already known), and so is the staged pick: only an
-- explicit clear, or the controller's own permission collapse, drops it.
function Page:setVisible(visible)
    local was = self:getIsVisible()
    ISPanel.setVisible(self, visible)
    if not visible then
        self.picker:close()
        pcall(self.searchEntry.unfocus, self.searchEntry)
        Detail.close(self)
    end
    if self.catList ~= nil and was ~= visible then self:layout() end
end

-- ----- drawing -----

function Page:prerender()
    local g = self.g
    card(self, 0, 0, self.width, self.height, tr("Admin_Wl_Title"))
    -- the file's own state wins over the counts: a parse error means the server is still running
    -- with the previous list
    local status, token = self:fileStatusText()
    text(self, fitText(status, g.statusW), PAD, g.statusY, token)
    text(self, fitText(g.scopeLabel, g.scopeW), g.scopeX, g.scopeY, "textFaint")
    local summary = self:summaryText()
    if summary then
        text(self, fitText(summary, math.max(0, self.width - PAD * 2)), PAD, g.summaryY, "textFaint")
    end
    local state = self:listStatus()
    local empty = self:statusText(state)
    if empty then
        text(self, fitText(empty, math.max(0, self.width - PAD * 2)), PAD, g.emptyY,
            (state == "failed" or state == "timeout") and "errorText" or "textFaint")
    end
end

function Page:render() end

-- ----- lifecycle -----

function Page:refresh()
    self.owner:requestWhitelist()
end

function Page:tick(now)
    -- a press that hit no row leaves the click flag standing; the frame after the event is where
    -- it is dropped, so a keyboard Enter can never be read as that click
    self.clicked = false
    if entryText(self.searchEntry) ~= self.searchSeen then self:onSearch() end
    self.picker:tick(now)
end

-- The permission collapse: everything this page learned from the server is dropped, the staged
-- pick with it, and the page reads as one that was never opened. No command is sent.
function Page:clear()
    self.picker:close()
    -- the standing notes quote this server's own file status: they go with the right to read it
    Detail.close(self)
    self.whitelist = nil
    self.sets = wlSets(nil)
    self.pick = nil
    self.sent = nil
    self.readError = nil
    self.timedOut = false
    self.query = nil
    U.setEntryText(self.searchEntry, "")
    self:rebuild()
end

function Page:dispose()
    self:clear()
    pcall(self.searchEntry.unfocus, self.searchEntry)
    Detail.close(self)
    self.picker:dispose()
end

-- ---------- module API ----------

-- owner: the admin controller. Returns an initialised child that the owner adds, positions and
-- resizes. No command is sent, and isPending is the owner's own plain function.
function P.create(owner, isPending)
    local o = ISPanel:new(0, 0, 600, 300)
    setmetatable(o, Page)
    o.background = false
    o.owner = owner
    o.isPending = isPending
    o.view = "cats"
    o.sets = wlSets(nil)
    o:initialise()
    o:instantiate()   -- builds the children now; the owner only has to addChild/resize
    o:setVisible(false)
    return o
end

return P
