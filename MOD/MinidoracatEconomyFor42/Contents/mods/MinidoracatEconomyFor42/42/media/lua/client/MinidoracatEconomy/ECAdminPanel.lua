-- MinidoracatEconomyFor42 -- admin panel (client, stage B7). Adds exactly one namespace:
-- C.AdminPanel.
--
--   C.AdminPanel.canRead() / canWrite()   pure functions, callable before any UI exists
--   C.AdminPanel.create(owner)            initialised ISPanel child, NOT added (owner addChild's
--                                         it); never sends a command
--   instance:resize(w, h) / :refresh() / :dispose() / :setVisible(v)
--
-- ECPanel owns the window chrome plus the "Admin" tab button and positions this child; this file
-- owns everything below it: ten sub pages (Player / Dashboard / Currencies / Sources / Shop /
-- Whitelist / Listings / Audit / System / Settings, the last one an editor for this mod's sandbox
-- options -- group nav on the left, one control per option on the right, backed by admin.option
-- runtime overrides; Shop is the same shape for the system shop's catalog.json, backed by
-- admin.catalog; Whitelist edits the market's whitelist.json in place -- one switch per item
-- category, allow / deny per item, over a local search of every script item this server knows,
-- backed by admin.whitelist; Listings is a paged, searchable view of every active listing,
-- backed by admin.listings) and the
-- write dialogs (adjust / freeze / rename / enable / exchange / source caps / option /
-- catalog price / catalog cap / delist). The
-- player page also owns the account search dropdown: a debounced admin.players query whose
-- candidates are drawn by a child panel floating under the search box.
--
-- Permission gate mirrors the server (ECAdmin.lua gate()): sandbox role *name* lists, read through
-- the client-only getAccessLevel(). The server re-checks every command; this side only decides
-- what to draw and what to enable, and collapses immediately when the role is taken away.
--
-- Transport rules (no framework, ECClient stays untouched):
--   * replies land in C.handlers["admin.*"] (registered at the bottom of this file) and are routed
--     to the live instance only;
--   * one in-flight request per command, 500 ms client cooldown per command (the server throttles
--     the same way, ECServer.lua COMMAND_COOLDOWN_MS) and a visible timeout after TIMEOUT_MS;
--   * every reply is matched against the request that is still open (username / requestId), so a
--     late answer cannot land on a different player or a closed dialog.
--
-- Painting rules: prerender only draws. Table rows and truncation are rebuilt when data arrives,
-- when the filter changes or when the geometry changes -- never per frame.
--
-- Engine references (snapshot 42.20.4-20260826):
--   getAccessLevel()             LuaManager.java:4435-4436 (client only; "" when unavailable)
--   Clipboard.setClipboard(str)  core/Clipboard.java:52-59
--   ISTextEntryBox               ISUI/ISTextEntryBox.lua:321-341 (new -> initialise ->
--                                instantiate; family-verified use in
--                                MinidoracatMiniMap_Search.lua:393-395), setMultipleLine :85-95,
--                                setMaxTextLength :170-172, getInternalText :158-160
--   #string under Kahlua counts UTF-16 units, the same unit the server counts reason chars in
--   (StringLib.java:760-768), so the local reason length check matches ECAdmin.reasonError.

require "ISUI/ISPanel"
require "ISUI/ISTextEntryBox"

if not MinidoracatEconomy or not MinidoracatEconomy.Client or not MinidoracatEconomy.Client.UI then
    require "MinidoracatEconomy/ECWidgets"
end
local EC = MinidoracatEconomy
local C = EC.Client
local U = C.UI

local P = {}
C.AdminPanel = P

local PAD, T = U.PAD, U.T
local CARD_TITLE_H = U.CARD_TITLE_H
local fontH = U.fontH
local color, fill, border, text, textWidth, fitText, textRight, textCentre = U.color, U.fill, U.border, U.text, U.textWidth, U.fitText, U.textRight, U.textCentre
local stampText, amountText, signedText, hasBit, kindText, card, drawCoin = U.stampText, U.amountText, U.signedText, U.hasBit, U.kindText, U.card, U.drawCoin
local Button, TableCell = U.Button, U.TableCell

local TABS = { "Player", "Dashboard", "Currencies", "Sources", "Shop", "Whitelist", "Listings", "Audit", "System", "Settings" }
local COMMANDS = { "admin.lookup", "admin.adjust", "admin.freeze", "admin.config", "admin.audit", "admin.auditFile", "admin.system", "admin.icons", "admin.sources", "admin.players", "admin.receipts", "admin.option", "admin.catalog", "admin.listings", "admin.whitelist" }
local PATH_KEYS = { "root", "events", "receipts", "audit", "heartbeat", "icons" }
local EXCHANGE_FIELDS = { "pointsPerCoin", "perOrderMin", "perOrderMax", "perAccountDaily", "serverDaily" }
local AUDIT_FILTERS = { "all", "adjust", "freeze", "config", "rolled" }   -- rolled = the audit files, rolled-back lines only

local COOLDOWN_MS = 500
local TIMEOUT_MS = 8000
local POLL_MS = 30000
local PERM_POLL_MS = 500
local ICONS_RECHECK_MS = 2500   -- an icon reload reads a few KB per tick; the outcome is asked for after this
local AUDIT_LIMIT = 500
local PLAYERS_DEBOUNCE_MS = 250   -- keystrokes are coalesced; the server also throttles per command
local PLAYERS_ROWS_MAX = 8        -- rows the dropdown ever draws, the "type more" line included
local PLAYERS_MIN_W = 260
local REASON_MAX = 1000
local NAME_MAX = 24
local USERNAME_MAX = 64

-- ---------- permissions (no UI, no session required) ----------

local function accessLevel()
    if type(getAccessLevel) ~= "function" then return "" end
    local ok, level = pcall(getAccessLevel)
    if not ok or type(level) ~= "string" then return "" end
    return string.lower(level)
end

function P.canWrite()
    local level = accessLevel()
    if level == "" then return false end
    return EC.roleSet(EC.sandbox("AdminRoles", "admin"))[level] == true
end

function P.canRead()
    if P.canWrite() then return true end
    local level = accessLevel()
    if level == "" then return false end
    return EC.roleSet(EC.sandbox("ReadOnlyRoles", "moderator"))[level] == true
end

-- ---------- transport ----------

local sentAt = {}        -- command -> ms of the last send (client cooldown)
local pendingAt = {}     -- command -> ms of the request still waiting for a reply
local deferred = {}      -- command -> { args, at }: held until the server's 500 ms window has passed
local requestSeq = 0

-- The server drops a repeat of the same command from the same player inside 500 ms
-- (ECServer COMMAND_COOLDOWN_MS) without replying. A click that lands right after an automatic
-- request (status re-check, page poll) used to be refused with a red "too fast": instead the
-- request is held and sent when the window has passed. `pendingAt` is set at once so the
-- buttons disable and the timeout clock starts from the click.
local function send(command, args)
    local player = getPlayer()
    if not player then return false, "no_player" end
    local now = EC.now()
    if pendingAt[command] then return false, "busy" end
    pendingAt[command] = now
    local last = sentAt[command]
    if last and now - last < COOLDOWN_MS then
        deferred[command] = { args = args or {}, at = last + COOLDOWN_MS }
        return true
    end
    sentAt[command] = now
    sendClientCommand(player, EC.COMMAND_MODULE, command, args or {})
    return true
end

local function flushDeferred(now)
    local player = getPlayer()
    if not player then return end
    for command, d in pairs(deferred) do
        if now >= d.at then
            deferred[command] = nil
            sentAt[command] = now
            sendClientCommand(player, EC.COMMAND_MODULE, command, d.args)
        end
    end
end

local function isPending(command)
    return pendingAt[command] ~= nil
end

local function newRequestId()
    requestSeq = requestSeq + 1
    return "b7-" .. tostring(EC.now()) .. "-" .. tostring(requestSeq)
end

-- Kahlua strings are UTF-16 units (#s counts characters); standard Lua holds UTF-8 bytes, so
-- count non-continuation bytes there. Mirrors ECAdmin.reasonError.
local WIDE_STRINGS = pcall(string.char, 19981)
local function charCount(s)
    if WIDE_STRINGS then return #s end
    local n = 0
    for i = 1, #s do
        local b = string.byte(s, i)
        if b < 128 or b >= 192 then n = n + 1 end
    end
    return n
end

-- ---------- small helpers ----------

local function lineH() return fontH.small + 6 end
local function rowH() return math.max(26, fontH.small + 12) end
local function entryH() return math.max(26, fontH.small + 12) end
local function btnH() return math.max(28, fontH.medium + 10) end

local function tr(key) return getText(T .. key) end

-- shared, allocation-free label lookups
local ISSUE_PERIODS = { "today", "week", "month" }

local function exchangeLabel(field)
    return tr("Admin_Cur_" .. string.upper(string.sub(field, 1, 1)) .. string.sub(field, 2))
end

local function errorText(code)
    if code == nil then code = "unknown" end
    local key = T .. "Admin_Error_" .. tostring(code)
    return getTextOrNull(key) or getText(T .. "Admin_Error_generic", tostring(code))
end

local function currencyDefs()
    return C.currencies or (C.session and C.session.currencies) or nil
end

local function currencyDef(id)
    for _, cur in ipairs(currencyDefs() or {}) do
        if cur.id == id then return cur end
    end
    return nil
end

local function currencyName(id)
    local cur = currencyDef(id)
    if cur and type(cur.nameOverride) == "string" and cur.nameOverride ~= "" then
        return cur.nameOverride
    end
    local static = EC.CURRENCIES[id]
    if static then return getText(static.nameKey) end
    return tostring(id)
end

-- Source display names arrive as { CH = ..., EN = ... }. The language option cannot change
-- without a restart, so it is read once; getOptionLanguageName is absent on old builds.
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

local function sourceName(src)
    local names = src and src.displayName
    if type(names) == "table" then
        local lang = gameLanguage()
        local pick = (lang == "CH" or lang == "CN") and names.CH or names.EN
        if type(pick) ~= "string" or pick == "" then pick = names.EN or names.CH end
        if type(pick) == "string" and pick ~= "" then return pick end
    end
    return tostring(src and src.modId or "-")
end

-- a missing daily burn cap means "no limit" (ECIntegration.setSource stores nil for it)
local function capText(value)
    if value == nil then return tr("Admin_Src_Unlimited") end
    return amountText(value)
end

local function currencyOrder(lookup)
    if lookup and type(lookup.currencies) == "table" and #lookup.currencies > 0 then
        return lookup.currencies
    end
    return EC.CURRENCY_ORDER
end

local function sizeText(bytes)
    local n = tonumber(bytes) or 0
    if n >= 1048576 then return string.format("%.1f MB", n / 1048576) end
    if n >= 1024 then return string.format("%.0f KB", n / 1024) end
    return tostring(math.floor(n)) .. " B"
end

local function agoText(ms, now)
    local diff = math.max(0, (now or EC.now()) - (tonumber(ms) or 0))
    return U.durationText(diff)
end

-- Display form of a server path: everything before the Lua data dir becomes "..." (the cache dir
-- carries the host's user name, which a streaming admin may not want on screen), and when the
-- rest still does not fit the *head* is trimmed so the file name stays readable. The copy button
-- always copies the full path. Cached per (path, width): drawn every frame.
local pathCache = {}
local function pathDisplay(value, maxW)
    local key = value .. "\1" .. tostring(maxW)
    local cached = pathCache[key]
    if cached then return cached end
    local s = value
    local i = string.find(s, "[/\\]Lua[/\\]")
    if i then s = string.sub(s, i) end
    local shown = "..." .. s
    if textWidth(shown) > maxW then
        local low, high, best = 1, #s, ""
        while low <= high do
            local mid = math.floor((low + high) / 2)
            local cut = "..." .. string.sub(s, mid)
            if textWidth(cut) <= maxW then
                best = cut
                high = mid - 1
            else
                low = mid + 1
            end
        end
        shown = best
    end
    pathCache[key] = shown
    return shown
end

-- integer parse for the dialog fields: "-500" / "+30" / "12" only
local function parseInt(str)
    local digits = string.match(tostring(str or ""), "^%s*([%+%-]?%d+)%s*$")
    if not digits then return nil end
    local n = tonumber(digits)
    if not n or n ~= math.floor(n) then return nil end
    return n
end

local function newEntry(width, height, opts)
    local e = ISTextEntryBox:new("", 0, 0, width, height)
    e:initialise()
    e:instantiate()
    local bg, br = color("well"), color("border")
    e.backgroundColor = { r = bg.r, g = bg.g, b = bg.b, a = 0.9 }
    e.borderColor = { r = br.r, g = br.g, b = br.b, a = 1 }
    opts = opts or {}
    if opts.maxLen and e.setMaxTextLength then e:setMaxTextLength(opts.maxLen) end
    if opts.multiline and e.setMultipleLine then
        e:setMultipleLine(true)
        if e.setMaxLines then e:setMaxLines(opts.maxLines or 4) end
    end
    if opts.clear and e.setClearButton then e:setClearButton(true) end
    if opts.placeholder and e.setPlaceholderText then e:setPlaceholderText(opts.placeholder) end
    return e
end

local function entryText(e)
    if not e then return "" end
    local ok, value = pcall(function() return e:getInternalText() end)
    if ok and type(value) == "string" then return value end
    return ""
end

local function setEntryText(e, str)
    if not e then return end
    pcall(function() e:setText(str or "") end)
end

local function setEntryEditable(e, editable)
    if not e then return end
    pcall(function() e:setEditable(editable == true) end)
    if not editable then pcall(function() e:unfocus() end) end
end

-- Column layout for a TableCell table: spec = { { key, header, sample, flex } , ... }.
-- Every column gets max(header, sample) + PAD; one flex column absorbs the rest and carries a
-- width for fitText. `right` columns are measured from their right edge.
local function layoutColumns(list, spec, innerWidth)
    local cols = list.cols
    for i = #cols, 1, -1 do cols[i] = nil end
    local fixed, flexIndex = 0, nil
    local widths = {}
    for i, c in ipairs(spec) do
        if c.flex then
            flexIndex = i
            widths[i] = 0
        else
            widths[i] = math.max(textWidth(c.header), textWidth(c.sample or "")) + PAD
            fixed = fixed + widths[i]
        end
    end
    if flexIndex then
        widths[flexIndex] = math.max(40, innerWidth - PAD - fixed)
    end
    local x = PAD
    for i, c in ipairs(spec) do
        if c.right then
            cols[i] = { x = x + widths[i] - PAD, right = true, width = widths[i] }
        else
            cols[i] = { x = x, width = widths[i] }
        end
        x = x + widths[i]
    end
    return cols
end

local function drawColumnHeaders(el, list, spec, x, y, h)
    fill(el, x, y, list.width, h, "well", "rect")
    local ty = y + math.floor((h - fontH.small) / 2)
    for i, c in ipairs(spec) do
        local col = list.cols[i]
        if col then
            local label = fitText(c.header, col.width)
            if col.right then
                textRight(el, label, x + col.x, ty, "textMuted")
            else
                text(el, label, x + col.x, ty, "textMuted")
            end
        end
    end
end

local RECEIPT_COLS = nil
local AUDIT_COLS = nil

local function receiptSpec()
    RECEIPT_COLS = {
        { header = tr("Wallet_Col_Time"), sample = "00-00 00:00" },
        { header = tr("Admin_Col_Currency"), sample = currencyName(EC.CURRENCY_ORDER[1]) },
        { header = tr("Wallet_Col_Amount"), sample = "+999,999", right = true },
        { header = tr("Wallet_Col_Kind"), sample = kindText("admin_adjust") },
        { header = tr("Wallet_Col_Balance"), sample = "999,999,999", right = true },
        { header = tr("Admin_Col_Tx"), sample = "", flex = true },
    }
    return RECEIPT_COLS
end

local function auditSpec()
    AUDIT_COLS = {
        { header = tr("Wallet_Col_Time"), sample = "00-00 00:00" },
        { header = tr("Admin_Audit_Col_Admin"), sample = "admin0000" },
        { header = tr("Admin_Audit_Col_Action"), sample = tr("Admin_Audit_Action_unfreeze") },
        { header = tr("Admin_Audit_Col_Target"), sample = "playerName00" },
        { header = tr("Admin_Col_Currency"), sample = currencyName(EC.CURRENCY_ORDER[1]) },
        { header = tr("Admin_Audit_Col_Change"), sample = "-999,999", right = true },
        { header = tr("Admin_Audit_Col_Reason"), sample = "", flex = true },
        { header = tr("Admin_Col_Tx"), sample = "0000000000000:0000" },
    }
    return AUDIT_COLS
end

local function auditActionText(action)
    return getTextOrNull(T .. "Admin_Audit_Action_" .. tostring(action)) or tostring(action)
end

local function configValueText(v)
    local t = type(v)
    if t == "table" then
        if v.rateVersion then return "v" .. tostring(v.rateVersion) end
        return tr("Admin_Cur_Title")
    end
    if t == "boolean" then return v and tr("Admin_On") or tr("Admin_Off") end
    if t == "number" then return amountText(v) end
    if t == "string" and v ~= "" then return v end
    return "-"
end

-- ---------- settings page (runtime option editor) ----------

-- Control strip on the right of every option row: a fixed width, so the name / description
-- column is the one that reflows and every row's controls line up (the MiniMap settings window
-- shape). Step buttons and the toggle are painted by the cell and hit-tested from the same
-- numbers, which are computed once per rebuild.
local OPTION_CTRL_W = 240
local OPTION_STEP_W = 26
local OPTION_TOGGLE_W = 44
local OPTION_TEXT_MAX = 200   -- ECConfig.validateOption's limit for kind = "text"

-- ";" separated sandbox lists read as a sentence ("1, 3, 7"); the separator is per language.
local function listText(value, coins)
    local out = nil
    for part in string.gmatch(tostring(value), "[^;]+") do
        local item = string.match(part, "^%s*(.-)%s*$")
        if item ~= "" then
            if coins then item = amountText(tonumber(item) or 0) end
            out = out and (out .. tr("Admin_Set_ListSep") .. item) or item
        end
    end
    return out or tostring(value)
end

-- UTC offset in hours: "+8" for 8.0, "+5:30" for 5.5, "-5" for -5
local function offsetText(n)
    local whole = math.floor(math.abs(n))
    local minutes = math.floor((math.abs(n) - whole) * 60 + 0.5)
    local body = (n < 0 and "-" or "+") .. tostring(whole)
    if minutes > 0 then body = body .. ":" .. (minutes < 10 and "0" or "") .. tostring(minutes) end
    return getText(T .. "Admin_Set_Timezone", body)
end

-- Display form of an option value; the schema's unit decides. Serves the rows, the
-- "overridden (default X)" note and the range hint of the edit dialog.
local function optionValueText(spec, value)
    if value == nil then return tr("Admin_Set_Missing") end
    if spec.kind == "bool" then return tr(value == true and "Admin_On" or "Admin_Off") end
    if spec.kind == "list_int" then return listText(value, spec.unit == "coin") end
    if spec.kind == "text" then return listText(value, false) end
    local n = tonumber(value)
    if n == nil then return tostring(value) end
    if spec.zeroUnlimited and n <= 0 then return tr("Admin_Set_Unlimited") end
    if spec.unit == "minutes" then return getText(T .. "Admin_Set_Minutes", amountText(n)) end
    if spec.unit == "hour" then return getText(T .. "Admin_Set_Hour", tostring(math.floor(n))) end
    if spec.unit == "percent" then return getText(T .. "Admin_Set_Percent", tostring(math.floor(n))) end
    if spec.unit == "days" then return getText(T .. "Admin_Set_Days", tostring(math.floor(n))) end
    if spec.unit == "tz" then return offsetText(n) end
    return amountText(n)
end

-- What the edit dialog's box is prefilled with (and what the range hint quotes): the raw value,
-- never its decorated display form -- the box is parsed back with tonumber / EC.parseIntList.
local function optionInputText(spec, value)
    if spec.kind == "list_int" or spec.kind == "text" then return tostring(value or "") end
    local n = tonumber(value)
    if n == nil then return "" end
    if n == math.floor(n) then return tostring(math.floor(n)) end
    return string.format("%.1f", n)
end

-- Toggle colours are the mod's own tokens (the framework's defaults are grey); built once, since
-- the painter takes the table every frame.
local toggleColors = nil
local function optionToggleColors()
    if not toggleColors then
        toggleColors = { on = color("gold"), off = color("well"), knob = color("text"), border = color("border") }
    end
    return toggleColors
end

-- One option row: name over description on the left, the control strip on the right. Every
-- string, hit box and y is computed in Admin:optionRow (the row width is known there), so the
-- cell only paints and the click test reads exactly the numbers the paint used.
local OptionCell = ISPanel:derive("MinidoracatEconomyOptionCell")

function OptionCell:render()
    local e = self.entry
    if not e then return end
    local w, h = self.width, self.height
    if self.index % 2 == 0 then fill(self, 0, 0, w, h, "card", "rect") end
    local off = self.list.optionsDisabled == true
    if e.prefixText then text(self, e.prefixText, PAD, e.line1Y, "textFaint") end
    text(self, e.nameText, e.nameX, e.line1Y, "text")
    if e.overText then text(self, e.overText, PAD, e.line2Y, "warn") end
    if e.descText ~= "" then text(self, e.descText, e.descX, e.line2Y, "textFaint") end
    if e.runtimeText then text(self, e.runtimeText, e.runtimeX, e.line2Y, "warn") end
    if e.lockedText then textRight(self, e.lockedText, w - PAD, e.line2Y, "textFaint") end
    if e.valueText then
        local token = e.missing and "textFaint" or "accent"
        if e.valueCentre then
            textCentre(self, e.valueText, e.valueX + e.valueW / 2, e.valueY, token)
        else
            textRight(self, e.valueText, e.valueX + e.valueW, e.valueY, token)
        end
    end
    if e.toggle then
        local th = math.max(20, fontH.small + 6)
        local ty = math.floor((h - th) / 2)
        -- Skin.toggle is a rev >= 3 painter: an older framework has no such key, and the painter
        -- itself answers false when it declines the geometry. Both fall back to a labelled pill.
        local painted = false
        if U.Skin and U.Skin.toggle then
            local pok, res = pcall(U.Skin.toggle, self, e.toggle.x, ty, e.toggle.w, th, e.toggleOn, optionToggleColors(), off and 0.5 or 1)
            painted = pok and res ~= false
        end
        if not painted then
            fill(self, e.toggle.x, ty, e.toggle.w, th, e.toggleOn and "selected" or "well", "pill")
            border(self, e.toggle.x, ty, e.toggle.w, th, off and "border" or "accent", "pill")
            textCentre(self, e.toggleLabel, e.toggle.x + e.toggle.w / 2, e.valueY, off and "textFaint" or "text")
        end
    end
    for _, hit in ipairs(e.hits) do
        if hit.label then
            local cy = math.floor((h - e.chipH) / 2)
            border(self, hit.x, cy, hit.w, e.chipH, off and "border" or "accent", "pill")
            textCentre(self, hit.label, hit.x + hit.w / 2, e.valueY, off and "textFaint" or "text")
        end
    end
end

-- ---------- shop catalog page ----------

-- Control strip on the right of every catalog row: the option row's shape, doubled -- the
-- "listed" toggle plus the price steppers on the first line, the daily cap steppers plus the
-- "back to the file value" chip on the second. Every string and hit box is computed once per
-- rebuild (Admin:catalogGeometry / Admin:catalogRow), so the cell only paints and the click test
-- reads exactly the numbers the paint used.
local CATALOG_STEP_W = 26
local CATALOG_VALUE_MIN_W = 64
local CATALOG_TOGGLE_W = 44
local PRICE_MAX = 1000000000   -- ECShop's own price ceiling
local CAP_MAX = 1000000

-- A stepper moves by what the admin would type next: single coins under 100, tens under 1000,
-- hundreds above. Anything else is what the edit chip is for.
local function priceStep(value)
    if value < 100 then return 1 end
    if value < 1000 then return 10 end
    return 100
end

-- Item display name through the engine's own lookup (LuaManager.java:8579-8583), so the admin
-- reads the same translated name a player sees; an unknown fullType falls back to itself.
local function itemName(fullType)
    if type(getItemNameFromFullType) == "function" then
        local ok, name = pcall(getItemNameFromFullType, fullType)
        if ok and type(name) == "string" and name ~= "" then return name end
    end
    return tostring(fullType or "-")
end

-- Item icon: the script item's normal texture, cached per fullType (false = asked and missing).
-- A geometry change rebuilds every row, and ScriptManager lookups are not free.
-- The script's untranslated DisplayName (Item.java:493-495), shown faint after the localised
-- name so the host can match a row against the item id on any language; nil when identical.
local itemBaseNames = {}
local function itemBaseName(fullType)
    local base = itemBaseNames[fullType]
    if base == nil then
        base = false
        local ok, script = pcall(function() return ScriptManager.instance:FindItem(fullType) end)
        if ok and script then
            local okName, value = pcall(function() return script:getDisplayName() end)
            if okName and type(value) == "string" and value ~= "" then base = value end
        end
        itemBaseNames[fullType] = base
    end
    if not base or base == itemName(fullType) then return nil end
    return base
end

local itemTextures = {}
local function itemTexture(fullType)
    if type(fullType) ~= "string" then return nil end
    local cached = itemTextures[fullType]
    if cached ~= nil then return cached or nil end
    local tex = nil
    pcall(function()
        local script = ScriptManager and ScriptManager.instance and ScriptManager.instance:FindItem(fullType)
        if script then tex = script:getNormalTexture() end
    end)
    itemTextures[fullType] = tex or false
    return tex
end

local function categoryText(category)
    return getTextOrNull(T .. "Shop_Cat_" .. tostring(category)) or tostring(category or "-")
end

local function capValueText(cap)
    local n = math.floor(tonumber(cap) or 0)
    if n <= 0 then return tr("Admin_Set_Unlimited") end
    return amountText(n)
end

local CatalogCell = ISPanel:derive("MinidoracatEconomyCatalogCell")

function CatalogCell:render()
    local e = self.entry
    if not e then return end
    local w, h = self.width, self.height
    if self.index % 2 == 0 then fill(self, 0, 0, w, h, "card", "rect") end
    local off = self.list.optionsDisabled == true
    if e.icon then
        -- a texture the engine handed out can still be refused by the renderer: ask once
        local ok = pcall(self.drawTextureScaled, self, e.icon, PAD, e.iconY, e.iconSize, e.iconSize, 1, 1, 1, 1)
        if not ok then e.icon = nil end
    end
    text(self, e.nameText, e.nameX, e.line1Y, e.toggleOn and "text" or "textFaint")
    if e.altText then text(self, e.altText, e.altX, e.line1Y, "textFaint") end
    text(self, e.metaText, e.metaX, e.line2Y, "textFaint")
    local labelToken = off and "textFaint" or "textMuted"
    text(self, e.enabledLabel, e.labelLeftX, e.textY1, labelToken)
    text(self, e.priceLabel, e.labelX, e.textY1, labelToken)
    text(self, e.capLabel, e.labelX, e.textY2, labelToken)
    local valueToken = off and "textFaint" or "accent"
    textCentre(self, e.priceText, e.valueX + e.valueW / 2, e.textY1, valueToken)
    textCentre(self, e.capText, e.valueX + e.valueW / 2, e.textY2, valueToken)
    -- Skin.toggle is a rev >= 3 painter (see OptionCell): both its absence and its refusal fall
    -- back to the labelled pill
    local t = e.toggle
    local painted = false
    if U.Skin and U.Skin.toggle then
        local pok, res = pcall(U.Skin.toggle, self, t.x, t.y, t.w, t.h, e.toggleOn, optionToggleColors(), off and 0.5 or 1)
        painted = pok and res ~= false
    end
    if not painted then
        fill(self, t.x, t.y, t.w, t.h, e.toggleOn and "selected" or "well", "pill")
        border(self, t.x, t.y, t.w, t.h, off and "border" or "accent", "pill")
        textCentre(self, e.toggleLabel, t.x + t.w / 2, e.textY1, off and "textFaint" or "text")
    end
    for _, hit in ipairs(e.hits) do
        if hit.label then
            border(self, hit.x, hit.y, hit.w, hit.h, off and "border" or "accent", "pill")
            textCentre(self, hit.label, hit.x + hit.w / 2, hit.y + e.chipTextY, off and "textFaint" or "text")
        end
    end
end

-- ---------- market listings page ----------

-- One listing row: the item's icon plus its translated name (and the script's own name) over
-- "seller / category / expiry" on the left, the price and the forced-delist chip on the right.
-- Every string and hit box is computed once per rebuild (Admin:listingGeometry /
-- Admin:listingRow), so the cell only paints and the click test reads the numbers the paint used.
local ListingCell = ISPanel:derive("MinidoracatEconomyListingCell")

function ListingCell:render()
    local e = self.entry
    if not e then return end
    local w, h = self.width, self.height
    if self.index % 2 == 0 then fill(self, 0, 0, w, h, "card", "rect") end
    local off = self.list.optionsDisabled == true
    if e.icon then
        -- a texture the engine handed out can still be refused by the renderer: ask once
        local ok = pcall(self.drawTextureScaled, self, e.icon, PAD, e.iconY, e.iconSize, e.iconSize, 1, 1, 1, 1)
        if not ok then e.icon = nil end
    end
    text(self, e.nameText, e.nameX, e.line1Y, "text")
    if e.altText then text(self, e.altText, e.altX, e.line1Y, "textFaint") end
    text(self, e.metaText, e.nameX, e.line2Y, "textFaint")
    textRight(self, e.priceText, e.priceRight, e.line1Y, "accent")
    local hit = e.delist
    border(self, hit.x, hit.y, hit.w, hit.h, off and "border" or "accent", "pill")
    textCentre(self, e.delistLabel, hit.x + hit.w / 2, hit.y + e.chipTextY, off and "textFaint" or "text")
end

-- ---------- upload whitelist page ----------

-- DisplayCategory name the way the vanilla inventory paints it (ISInventoryPane.lua:2533): the
-- engine's own IGUI_ItemCat_* key, falling back to the raw script category.
local function itemCategoryName(category)
    local key = tostring(category or "-")
    return getTextOrNull("IGUI_ItemCat_" .. key) or key
end

local function wlSet(list)
    local set = {}
    if type(list) == "table" then
        for _, v in ipairs(list) do
            if type(v) == "string" then set[v] = true end
        end
    end
    return set
end

local WL_ITEM_MAX = 200   -- rows one search ever adds: a single letter matches most of the game

-- Every item this server could ever put on the market: the script manager's whole list
-- (ScriptManager.java:715-717, a Java ArrayList) minus the hidden and obsolete scripts and the
-- classes the market refuses whatever the file says (EC.isFixedType). Read once per session and
-- cached on the panel; every engine call is guarded, so a stub-thin environment simply has no
-- items instead of throwing.
local function whitelistUniverse()
    local uni = { cats = {}, items = {}, byType = {} }
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
        if not skip and EC.isFixedType(script) then skip = true end
        if not skip then
            local fullType, base, cat = nil, nil, nil
            pcall(function() fullType = script:getFullName() end)
            pcall(function() base = script:getDisplayName() end)
            pcall(function() cat = script:getDisplayCategory() end)
            if type(fullType) == "string" and fullType ~= "" and uni.byType[fullType] == nil then
                local name = itemName(fullType)
                if type(cat) ~= "string" or cat == "" then cat = "Item" end
                local entry = { fullType = fullType, name = name, cat = cat,
                    key = string.lower(name .. " " .. tostring(base or "") .. " " .. fullType) }
                uni.byType[fullType] = entry
                uni.items[#uni.items + 1] = entry
                uni.cats[cat] = (uni.cats[cat] or 0) + 1
            end
        end
    end
    return uni
end

-- One whitelist row: either a category (its localised name over the raw name and the item count)
-- or a single item (icon, localised plus untranslated name, over "fullType / category"), with the
-- allow / deny chips on the right. Every string and hit box is computed once per rebuild
-- (Admin:whitelistGeometry / whitelistCategoryRow / whitelistItemRow), so the cell only paints
-- and the click test reads the numbers the paint used.
local WhitelistCell = ISPanel:derive("MinidoracatEconomyWhitelistCell")

function WhitelistCell:render()
    local e = self.entry
    if not e then return end
    if self.index % 2 == 0 then fill(self, 0, 0, self.width, self.height, "card", "rect") end
    local off = self.list.optionsDisabled == true
    if e.icon then
        -- a texture the engine handed out can still be refused by the renderer: ask once
        local ok = pcall(self.drawTextureScaled, self, e.icon, PAD, e.iconY, e.iconSize, e.iconSize, 1, 1, 1, 1)
        if not ok then e.icon = nil end
    end
    if e.labelText then text(self, e.labelText, PAD, e.line1Y, "textFaint") end
    text(self, e.nameText, e.nameX, e.line1Y, "text")
    if e.altText then text(self, e.altText, e.altX, e.line1Y, "textFaint") end
    text(self, e.metaText, e.metaX, e.line2Y, "textFaint")
    for _, hit in ipairs(e.hits) do
        fill(self, hit.x, hit.y, hit.w, hit.h, hit.active and "selected" or "well", "pill")
        border(self, hit.x, hit.y, hit.w, hit.h, off and "border" or "accent", "pill")
        textCentre(self, hit.label, hit.x + hit.w / 2, hit.y + e.chipTextY,
            off and "textFaint" or (hit.active and "text" or "textMuted"))
    end
end

-- ---------- write dialog ----------

local Dialog = ISPanel:derive("MinidoracatEconomyAdminDialog")

-- field descriptors per mode; `flex` marks the reason box that absorbs the leftover height
local function dialogFields(mode)
    -- one option value; no reason box (a per-click toggle must not demand an essay, and the
    -- server audits the change with the actor's name either way)
    if mode == "option" then
        return { { key = "value", label = tr("Admin_Set_Edit"), width = 220, maxLen = OPTION_TEXT_MAX } }
    end
    if mode == "optionReset" then return {} end   -- confirmation only: the warning line is the body
    -- one catalog number (price / daily cap); no reason box, exactly like the option editor
    if mode == "catalogPrice" then
        return { { key = "value", label = tr("Admin_Shop_Price"), width = 160, maxLen = 12 } }
    end
    if mode == "catalogCap" then
        return { { key = "value", label = tr("Admin_Shop_Cap"), width = 160, maxLen = 10 } }
    end
    if mode == "adjust" then
        return {
            { key = "amount", label = tr("Admin_Adjust_Amount"), width = 180, maxLen = 14, hint = tr("Admin_Adjust_AmountHint") },
            { key = "reversal", label = tr("Admin_Adjust_Reversal"), width = 300, maxLen = 40 },
            { key = "reason", label = "", multiline = true, flex = true, maxLen = REASON_MAX },
        }
    end
    if mode == "balanceMax" then
        return {
            { key = "balanceMax", label = tr("Admin_BalanceMax_Field"), width = 160, maxLen = 13, hint = tr("Admin_BalanceMax_Hint") },
            { key = "reason", label = "", multiline = true, flex = true, maxLen = REASON_MAX },
        }
    end
    if mode == "name" then
        return {
            { key = "name", label = getText(T .. "Admin_Name_Field", tostring(NAME_MAX)), width = 220, maxLen = NAME_MAX, hint = tr("Admin_Cur_NameNote") },
            { key = "reason", label = "", multiline = true, flex = true, maxLen = REASON_MAX },
        }
    end
    if mode == "exchange" then
        local list = {}
        for _, field in ipairs(EXCHANGE_FIELDS) do
            list[#list + 1] = { key = field, label = exchangeLabel(field), width = 110, maxLen = 12, half = true }
        end
        list[#list + 1] = { key = "reason", label = "", multiline = true, flex = true, maxLen = REASON_MAX }
        return list
    end
    if mode == "sourceCaps" then
        return {
            { key = "mintCap", label = tr("Admin_Src_MintCap"), width = 140, maxLen = 12 },
            { key = "burnCap", label = tr("Admin_Src_BurnCap"), width = 140, maxLen = 12, hint = tr("Admin_Src_BurnCapNote") },
            { key = "reason", label = "", multiline = true, flex = true, maxLen = REASON_MAX },
        }
    end
    -- freeze / enabled: reason only
    return { { key = "reason", label = "", multiline = true, flex = true, maxLen = REASON_MAX } }
end

function Dialog:createChildren()
    self.boxes = {}
    self.fields = dialogFields(self.mode)
    for _, f in ipairs(self.fields) do
        local box = newEntry(f.width or 200, f.multiline and (rowH() * 2) or entryH(), {
            maxLen = f.maxLen, multiline = f.multiline, maxLines = 4,
        })
        box.target = self
        box.onTextChangeFunction = Dialog.onFieldChanged
        self.boxes[f.key] = box
        self:addChild(box)
    end
    self.currencyButtons = {}
    if self.mode == "adjust" then
        for _, id in ipairs(currencyOrder(self.admin.lookup)) do
            local title = currencyName(id)
            local b = Button.create(0, 0, textWidth(title) + 22, math.max(20, fontH.small + 6), title, self, Dialog.onCurrency, "chip")
            b.internal = id
            b.active = id == self.currency
            self:addChild(b)
            self.currencyButtons[#self.currencyButtons + 1] = b
        end
    end
    self.confirmButton = Button.create(0, 0, 140, btnH(), self.confirmLabel, self, Dialog.onConfirm, "primary")
    self:addChild(self.confirmButton)
    local cancel = tr("Admin_Cancel")
    self.cancelButton = Button.create(0, 0, textWidth(cancel) + 30, btnH(), cancel, self, Dialog.onCancel, "chip")
    self:addChild(self.cancelButton)
end

function Dialog:onCurrency(button)
    self.currency = button.internal
    for _, b in ipairs(self.currencyButtons) do b.active = b.internal == self.currency end
    self:updateInfo()
end

function Dialog:onFieldChanged()
    local hadMessage = self.message ~= nil
    self.message = nil
    self:updateInfo()
    if hadMessage and self.admin then self.admin:layoutDialog() end
end

function Dialog:onCancel()
    self.admin:closeDialog()
end

function Dialog:onConfirm()
    self.admin:submitDialog(self)
end

-- Info lines are derived from the live lookup snapshot: rebuilt on open, on every field change
-- and whenever a fresh reply lands (never per frame).
function Dialog:updateInfo()
    local info = {}
    local lookup = self.admin.lookup
    if self.mode == "adjust" and lookup then
        local bal = lookup.balances and lookup.balances[self.currency]
        local available = bal and tonumber(bal.available) or 0
        local rev = bal and tonumber(bal.rev) or 0
        local delta = parseInt(entryText(self.boxes.amount)) or 0
        info[#info + 1] = { text = getText(T .. "Admin_Adjust_Balance", amountText(available), amountText(available + delta), tostring(rev)) }
        local today = lookup.adminToday or {}
        local mine = (type(today.currencies) == "table" and today.currencies[self.currency]) or today
        info[#info + 1] = { text = getText(T .. "Admin_Adjust_Daily", currencyName(self.currency),
            amountText(mine.add or 0), amountText(mine.sub or 0), amountText(today.cap or 0)) }
        -- adminToday.serverDaily = { cap, currencies[id] = { add, sub } } (ECAdmin.lookup)
        local server = today.serverDaily
        if type(server) == "table" then
            local used = (type(server.currencies) == "table" and server.currencies[self.currency]) or server
            info[#info + 1] = { text = getText(T .. "Admin_Adjust_Server", amountText(used.add or 0), amountText(used.sub or 0), amountText(server.cap or 0)) }
        end
        info[#info + 1] = { text = getText(T .. "Admin_Adjust_Snapshot", U.clockText(self.admin.lookupAt or EC.now(), self.admin.offsetMin)), token = "textFaint" }
    elseif self.mode == "exchange" then
        local def = currencyDef(self.currency)
        local ex = def and def.exchange
        if ex then
            info[#info + 1] = { text = getText(T .. "Admin_Cur_RateVersion", tostring(ex.rateVersion or 1)), token = "textFaint" }
        end
    elseif self.mode == "name" then
        local def = currencyDef(self.currency)
        local override = def and def.nameOverride
        if type(override) == "string" and override ~= "" then
            info[#info + 1] = { text = getText(T .. "Admin_Cur_Override", override), token = "textFaint" }
        else
            info[#info + 1] = { text = tr("Admin_Cur_NoOverride"), token = "textFaint" }
        end
    elseif self.hintText and (self.mode == "option" or self.mode == "catalogPrice" or self.mode == "catalogCap") then
        info[#info + 1] = { text = self.hintText, token = "textFaint" }
    end
    self.info = info
end

-- Row metrics per density level. Level 0 is the comfortable spacing used at the default UI font;
-- 1 and 2 are what a scaled-up font falls back to so the dialog still fits the child area.
local function dialogMetrics(level)
    local small, medium = fontH.small, fontH.medium
    if level == 1 then
        return { gap = 4, entry = math.max(20, small + 8), button = math.max(22, small + 10),
            line = small + 3, title = math.max(22, medium + 6), reason = 20, chip = math.max(18, small + 4) }
    end
    if level >= 2 then
        return { gap = 2, entry = math.max(18, small + 6), button = math.max(20, small + 8),
            line = small + 1, title = math.max(20, medium + 4), reason = 16, chip = math.max(16, small + 2) }
    end
    return { gap = 8, entry = entryH(), button = btnH(), line = lineH(),
        title = math.max(26, medium + 10), reason = math.max(24, rowH() * 3), chip = math.max(22, small + 8) }
end

local function planRowHeight(row, m)
    local kind = row.kind
    if kind == "currency" then return m.chip end
    if kind == "fields" then return m.entry end
    if kind == "reason" then return m.reason end
    if kind == "buttons" then return m.button end
    return m.line   -- reasonLabel / info / warn / message
end

function Dialog:layoutInside(maxW, maxH)
    local labelW = 0
    for _, f in ipairs(self.fields) do
        if f.key ~= "reason" then labelW = math.max(labelW, textWidth(f.label)) end
    end
    labelW = math.max(labelW, textWidth(tr("Admin_Adjust_Currency")))
    -- 560 wide by default, growing with the window up to 720: the dialog is the admin's main
    -- working surface, not a confirmation popup
    local width = math.min(maxW, math.max(560, math.min(720, math.floor(maxW * 0.7)), labelW + 380))
    -- a long label is truncated instead of pushing its field out of the dialog
    labelW = math.min(labelW, math.max(60, math.floor(width * 0.45)))
    local half = math.floor((width - PAD * 4 - labelW * 2) / 2)
    local pairable = half >= 90

    -- row plan: title, currency chips (adjust), one row per field (halves pair up when they fit),
    -- reason label + box, info lines, warning, message, buttons
    local rows = {}
    if self.mode == "adjust" then rows[#rows + 1] = { kind = "currency" } end
    local pendingHalf = nil
    for _, f in ipairs(self.fields) do
        if f.key == "reason" then
            if pendingHalf then
                rows[#rows + 1] = { kind = "fields", a = pendingHalf }
                pendingHalf = nil
            end
            rows[#rows + 1] = { kind = "reasonLabel" }
            rows[#rows + 1] = { kind = "reason", field = f }
        elseif f.half and pairable then
            if pendingHalf then
                rows[#rows + 1] = { kind = "fields", a = pendingHalf, b = f }
                pendingHalf = nil
            else
                pendingHalf = f
            end
        else
            rows[#rows + 1] = { kind = "fields", a = f }
        end
    end
    if pendingHalf then rows[#rows + 1] = { kind = "fields", a = pendingHalf } end
    for _ = 1, #(self.info or {}) do rows[#rows + 1] = { kind = "info" } end
    if self.warnText then rows[#rows + 1] = { kind = "warn" } end
    if self.message then rows[#rows + 1] = { kind = "message" } end
    rows[#rows + 1] = { kind = "buttons" }

    -- first density level whose core rows fit the area the child can give us. Info / warning /
    -- message lines are droppable (see the layout loop), so they do not force a denser level;
    -- the reason box keeps its full height as long as the fields and buttons fit.
    local m, core, total
    for level = 0, 2 do
        m = dialogMetrics(level)
        core, total = m.title + PAD * 2, m.title + PAD * 2
        for _, r in ipairs(rows) do
            local h = planRowHeight(r, m) + m.gap
            total = total + h
            if r.kind ~= "info" and r.kind ~= "warn" and r.kind ~= "message" then core = core + h end
        end
        if core <= maxH then break end
    end
    -- Reason box budget, in this order: (1) at least three lines when the core rows leave room,
    -- (2) the informational rows, (3) whatever is still spare, up to three more lines. The info
    -- rows are the droppable ones, so a tight window loses them before the reason box shrinks.
    local infoH = total - core
    local spare = math.max(0, maxH - core)
    local grow = math.min(spare, math.max(0, rowH() * 3 - m.reason))
    spare = spare - grow
    local shownInfo = math.min(spare, infoH)
    spare = spare - shownInfo
    grow = grow + math.min(spare, rowH() * 3)
    local reasonH = m.reason + grow
    local height = math.min(maxH, core + grow + shownInfo)

    self.rows = rows
    self.titleH = m.title
    self.gap = m.gap
    self.labelW = labelW
    self:setWidth(width)
    self:setHeight(height)

    -- buttons are anchored to the bottom so the controls are always reachable; the rows above are
    -- laid out top-down and an informational row that would collide with them is dropped.
    local buttonsY = height - PAD - m.button
    local y = m.title + PAD
    local infoIndex = 0
    local fieldX = PAD * 2 + labelW
    local fieldW = math.max(60, width - PAD - fieldX)
    for _, r in ipairs(rows) do
        local h = planRowHeight(r, m)
        if r.kind == "reason" then h = reasonH end
        if r.kind == "buttons" then
            r.y, r.h = buttonsY, m.button
            local slot = math.floor((width - PAD * 2 - 6) / 2)
            local confirmW = math.max(90, math.min(textWidth(self.confirmLabel, UIFont.Medium) + 40, slot))
            local cancelW = math.max(60, math.min(textWidth(tr("Admin_Cancel")) + 30, slot))
            self.confirmButton:setWidth(confirmW)
            self.confirmButton:setHeight(m.button)
            self.confirmButton:setX(width - PAD - confirmW)
            self.confirmButton:setY(buttonsY)
            self.admin:setButtonTitle(self.confirmButton, self.confirmLabel, UIFont.Medium)
            self.cancelButton:setWidth(cancelW)
            self.cancelButton:setHeight(m.button)
            self.cancelButton:setX(self.confirmButton.x - 6 - cancelW)
            self.cancelButton:setY(buttonsY)
            self.admin:setButtonTitle(self.cancelButton, tr("Admin_Cancel"))
        elseif y + h > buttonsY - m.gap and (r.kind == "info" or r.kind == "warn" or r.kind == "message") then
            r.skip = true
            r.h = 0
            if r.kind == "info" then infoIndex = infoIndex + 1; r.index = infoIndex end
        else
            r.y, r.h = y, h
            if r.kind == "currency" then
                local cx = fieldX
                local slot = math.floor((width - PAD - cx) / math.max(1, #self.currencyButtons)) - 4
                for _, b in ipairs(self.currencyButtons) do
                    b:setWidth(math.max(30, math.min(textWidth(b.fullTitle or b.title) + 22, slot)))
                    b:setHeight(h)
                    b:setX(cx); b:setY(y)
                    self.admin:setButtonTitle(b, b.fullTitle or b.title)
                    cx = cx + b.width + 4
                end
            elseif r.kind == "fields" then
                local box = self.boxes[r.a.key]
                box:setY(y); box:setHeight(h)
                if r.b then
                    box:setX(fieldX); box:setWidth(half)
                    local second = self.boxes[r.b.key]
                    second:setX(PAD * 3 + labelW * 2 + half); second:setY(y)
                    second:setWidth(half); second:setHeight(h)
                else
                    box:setX(fieldX)
                    box:setWidth(math.min(r.a.width or 200, fieldW))
                end
            elseif r.kind == "reason" then
                local box = self.boxes.reason
                box:setX(PAD); box:setY(y)
                box:setWidth(width - PAD * 2); box:setHeight(h)
            elseif r.kind == "info" then
                infoIndex = infoIndex + 1
                r.index = infoIndex
            end
            y = y + h + m.gap
        end
    end
end

function Dialog:prerender()
    local w, h = self.width, self.height
    fill(self, 0, 0, w, h, "surface")
    border(self, 0, 0, w, h, "accent")
    fill(self, 0, 0, w, self.titleH, "surfaceTitle", true)
    text(self, fitText(self.titleText, w - PAD * 2, UIFont.Medium), PAD, math.floor((self.titleH - fontH.medium) / 2), "text", UIFont.Medium)
    local labelX = PAD
    for _, r in ipairs(self.rows or {}) do
        if not r.skip then
            local ty = r.y + math.floor((r.h - fontH.small) / 2)
            if r.kind == "currency" then
                text(self, fitText(tr("Admin_Adjust_Currency"), self.labelW), labelX, ty, "textMuted")
            elseif r.kind == "fields" then
                text(self, fitText(r.a.label, self.labelW), labelX, ty, "textMuted")
                if r.b then
                    text(self, fitText(r.b.label, self.labelW), self.boxes[r.b.key].x - PAD - self.labelW, ty, "textMuted")
                elseif r.a.hint then
                    local box = self.boxes[r.a.key]
                    local hintX = box.x + box.width + PAD
                    text(self, fitText(r.a.hint, math.max(0, self.width - PAD - hintX)), hintX, ty, "textFaint")
                end
            elseif r.kind == "reasonLabel" then
                text(self, fitText(tr("Admin_Adjust_Reason"), self.width - PAD * 2), labelX, r.y, "textMuted")
            elseif r.kind == "info" then
                local info = self.info[r.index]
                if info then
                    text(self, fitText(info.text, self.width - PAD * 2), labelX, r.y, info.token or "text")
                end
            elseif r.kind == "warn" and self.warnText then
                text(self, fitText(self.warnText, self.width - PAD * 2), labelX, r.y, "warn")
            elseif r.kind == "message" and self.message then
                text(self, fitText(self.message.text, self.width - PAD * 2), labelX, r.y, self.message.error and "errorText" or "positive")
            end
        end
    end
end

function Dialog:render() end

-- swallow clicks so the page underneath cannot be operated while the dialog is open
function Dialog:onMouseDown(x, y) return true end
function Dialog:onMouseUp(x, y) return true end
function Dialog:onMouseMove(dx, dy) return true end

function Dialog:unfocusAll()
    for _, box in pairs(self.boxes or {}) do
        pcall(function() box:unfocus() end)
    end
end

-- ---------- account search dropdown ----------

-- Candidate list under the player page's search box. Owns no data: the rows are the reply the
-- panel is holding (admin.players) and the row plan the panel computed in layoutSuggest, so this
-- child only paints and turns a click into a lookup. It is added last, which puts it over every
-- sibling without a per-frame bringToTop (that reorders the parent's child list).
local Suggest = ISPanel:derive("MinidoracatEconomyAdminSuggest")

function Suggest:rowAt(y)
    local i = math.floor((y - 1) / rowH()) + 1
    if i < 1 or i > (self.admin.suggestShown or 0) then return nil end
    return (self.admin.players or {})[i]
end

function Suggest:prerender()
    local admin = self.admin
    local w, h = self.width, self.height
    fill(self, 0, 0, w, h, "surface")
    border(self, 0, 0, w, h, "accent")
    local rh = rowH()
    local hover = self:isMouseOver() and (math.floor(self:getMouseY() / rh) + 1) or 0
    local online = tr("Admin_Player_Online")
    local onlineW = textWidth(online) + PAD
    local players = admin.players or {}
    local shown = admin.suggestShown or 0
    local y = 1
    for i = 1, shown do
        local p = players[i]
        if hover == i then fill(self, 1, y, w - 2, rh, "selected", "rect") end
        local ty = y + math.floor((rh - fontH.small) / 2)
        text(self, fitText(tostring(p.username), w - PAD * 2 - (p.online and onlineW or 0)), PAD, ty, "text")
        if p.online then textRight(self, online, w - PAD, ty, "accent") end
        y = y + rh
    end
    local note = nil
    if admin.suggestMore then
        note = getText(T .. "Admin_Players_More", amountText(math.max(0, (tonumber(admin.playersTotal) or shown) - shown)))
    elseif admin.suggestEmpty then
        note = tr("Admin_Players_Empty")
    end
    if note then
        text(self, fitText(note, w - PAD * 2), PAD, y + math.floor((rh - fontH.small) / 2), "textFaint")
    end
end

function Suggest:render() end

function Suggest:onMouseDown(x, y)
    local p = self:rowAt(y)
    if p and type(p.username) == "string" and p.username ~= "" then
        self.admin:pickPlayer(p.username)
    end
    return true
end

function Suggest:onMouseUp(x, y) return true end

-- ---------- admin panel ----------

local Admin = ISPanel:derive("MinidoracatEconomyAdminPanel")

-- Keeps the untruncated label (fullTitle) and paints the fitted one; layout budgets the width.
function Admin:setButtonTitle(button, full, font)
    button.fullTitle = full
    button:setTitle(fitText(full, math.max(8, button.width - 12), font))
end

function Admin:createChildren()
    self.subTabButtons = {}
    for _, tab in ipairs(TABS) do
        local title = tr("Admin_Tab_" .. tab)
        local b = Button.create(0, 0, textWidth(title) + 28, 26, title, self, Admin.onSubTab, "tab")
        b.internal = tab
        b.active = tab == self.tab
        self:addChild(b)
        self.subTabButtons[#self.subTabButtons + 1] = b
    end

    local refresh = tr("Admin_Refresh")
    self.refreshButton = Button.create(0, 0, textWidth(refresh) + 24, 22, refresh, self, Admin.onRefreshClick, "chip")
    self:addChild(self.refreshButton)

    -- player page
    self.userEntry = newEntry(180, entryH(), { maxLen = USERNAME_MAX, clear = true, placeholder = tr("Admin_Player_Hint") })
    self.userEntry.target = self
    self.userEntry.onTextChangeFunction = Admin.onUserQueryChanged
    self:addChild(self.userEntry)
    local look = tr("Admin_Player_Search")
    self.lookupButton = Button.create(0, 0, textWidth(look) + 26, entryH(), look, self, Admin.onLookupClick, "chip")
    self:addChild(self.lookupButton)
    self.adjustButton = Button.create(0, 0, 150, btnH(), tr("Admin_Player_Adjust"), self, Admin.onAdjustClick, "primary")
    self:addChild(self.adjustButton)
    self.freezeButton = Button.create(0, 0, 150, btnH(), tr("Admin_Player_Freeze"), self, Admin.onFreezeClick, "chip")
    self:addChild(self.freezeButton)
    self.receiptList = U.newTable(TableCell, rowH())
    self.receiptList.onSelect = function(list, item)
        self.selectedReceipt = item
    end
    self:addChild(self.receiptList)

    -- currencies page
    self.renameButton = Button.create(0, 0, 120, btnH(), tr("Admin_Cur_Rename"), self, Admin.onRenameClick, "chip")
    self:addChild(self.renameButton)
    self.toggleButton = Button.create(0, 0, 120, btnH(), tr("Admin_Cur_Disable"), self, Admin.onToggleClick, "chip")
    self:addChild(self.toggleButton)
    self.rateButton = Button.create(0, 0, 120, btnH(), tr("Admin_Cur_EditRate"), self, Admin.onRateClick, "chip")
    self:addChild(self.rateButton)
    self.balanceMaxButton = Button.create(0, 0, 120, btnH(), tr("Admin_Cur_EditBalanceMax"), self, Admin.onBalanceMaxClick, "chip")
    self:addChild(self.balanceMaxButton)
    self.iconsButton = Button.create(0, 0, 120, btnH(), tr("Admin_Cur_ReloadIcons"), self, Admin.onIconsClick, "chip")
    self:addChild(self.iconsButton)

    -- sources page
    self.srcCapsButton = Button.create(0, 0, 120, btnH(), tr("Admin_Src_EditCaps"), self, Admin.onSourceCapsClick, "primary")
    self:addChild(self.srcCapsButton)
    self.srcToggleButton = Button.create(0, 0, 120, btnH(), tr("Admin_Src_Disable"), self, Admin.onSourceToggleClick, "chip")
    self:addChild(self.srcToggleButton)

    -- audit page
    self.auditEntry = newEntry(220, entryH(), { maxLen = 64, clear = true, placeholder = tr("Admin_Audit_Hint") })
    self.auditEntry.target = self
    self.auditEntry.onTextChangeFunction = Admin.onAuditQueryChanged
    self:addChild(self.auditEntry)
    self.auditFilterButtons = {}
    for _, key in ipairs(AUDIT_FILTERS) do
        local title = tr("Admin_Audit_" .. string.upper(string.sub(key, 1, 1)) .. string.sub(key, 2))
        local b = Button.create(0, 0, textWidth(title) + 22, 22, title, self, Admin.onAuditFilter, "chip")
        b.internal = key
        b.active = key == self.auditFilter
        self:addChild(b)
        self.auditFilterButtons[#self.auditFilterButtons + 1] = b
    end
    self.auditList = U.newTable(TableCell, rowH())
    self:addChild(self.auditList)

    -- system page: one copy button per path
    self.copyButtons = {}
    local copy = tr("Admin_Sys_Copy")
    for _, key in ipairs(PATH_KEYS) do
        local b = Button.create(0, 0, textWidth(copy) + 20, 20, copy, self, Admin.onCopyPath, "chip")
        b.internal = key
        self:addChild(b)
        self.copyButtons[#self.copyButtons + 1] = b
    end

    -- shop page: the reload chip rides the file status row, the catalog list sits below it. A
    -- row carries two control lines, so the click needs the row-local y as well as the x.
    local reload = tr("Admin_Shop_Reload")
    self.shopReloadButton = Button.create(0, 0, textWidth(reload) + 24, 22, reload, self, Admin.onShopReloadClick, "chip")
    self:addChild(self.shopReloadButton)
    self.catalogList = U.newTable(CatalogCell, lineH() * 2 + 12)
    local catalogDown = self.catalogList.onMouseDown
    self.catalogList.onMouseDown = function(list, x, y)
        self.catalogClickX = x
        self.catalogClickY = (y + list.scrollOffset) % (list.rowHeight + (list.padding or 0))
        return catalogDown(list, x, y)
    end
    self.catalogList.onSelect = function(_, item)
        self:onCatalogRow(item, self.catalogClickX or 0, self.catalogClickY or 0)
    end
    self:addChild(self.catalogList)

    -- whitelist page: the reload chip rides the file status row, the search box filters the rows
    -- locally (the file the server holds is already here), and the list carries one category or
    -- item per row. A row carries one control line, so the click needs the row-local y as well
    -- as the x.
    local wlReload = tr("Admin_Wl_Reload")
    self.wlReloadButton = Button.create(0, 0, textWidth(wlReload) + 24, 22, wlReload, self, Admin.onWhitelistReloadClick, "chip")
    self:addChild(self.wlReloadButton)
    self.wlEntry = newEntry(240, entryH(), { maxLen = 64, clear = true, placeholder = tr("Admin_Wl_Search") })
    self.wlEntry.target = self
    self.wlEntry.onTextChangeFunction = Admin.onWhitelistSearch
    self:addChild(self.wlEntry)
    self.whitelistList = U.newTable(WhitelistCell, lineH() * 2 + 12)
    local wlDown = self.whitelistList.onMouseDown
    self.whitelistList.onMouseDown = function(list, x, y)
        self.wlClickX = x
        self.wlClickY = (y + list.scrollOffset) % (list.rowHeight + (list.padding or 0))
        return wlDown(list, x, y)
    end
    self.whitelistList.onSelect = function(_, item)
        self:onWhitelistRow(item, self.wlClickX or 0, self.wlClickY or 0)
    end
    self:addChild(self.whitelistList)

    -- listings page: the search box, the listing list and the two page chips. A row carries one
    -- control, so the click needs the row-local x and y.
    self.lstEntry = newEntry(220, entryH(), { maxLen = 64, clear = true, placeholder = tr("Market_Search") })
    self.lstEntry.target = self
    self.lstEntry.onTextChangeFunction = Admin.onListingSearch
    self:addChild(self.lstEntry)
    self.lstPrevButton = Button.create(0, 0, 80, 22, tr("Market_Prev"), self, Admin.onListingPage, "chip")
    self.lstPrevButton.internal = -1
    self:addChild(self.lstPrevButton)
    self.lstNextButton = Button.create(0, 0, 80, 22, tr("Market_Next"), self, Admin.onListingPage, "chip")
    self.lstNextButton.internal = 1
    self:addChild(self.lstNextButton)
    self.listingsList = U.newTable(ListingCell, lineH() * 2 + 12)
    local lstDown = self.listingsList.onMouseDown
    self.listingsList.onMouseDown = function(list, x, y)
        self.lstClickX = x
        self.lstClickY = (y + list.scrollOffset) % (list.rowHeight + (list.padding or 0))
        return lstDown(list, x, y)
    end
    self.listingsList.onSelect = function(_, item)
        self:onListingRow(item, self.lstClickX or 0, self.lstClickY or 0)
    end
    self:addChild(self.listingsList)

    -- settings page: search box, the option list, the per-group reset button. The group nav is
    -- painted (name plus an override count per row) and its clicks are resolved in onMouseDown.
    self.setEntry = newEntry(200, entryH(), { maxLen = 32, clear = true, placeholder = tr("Admin_Set_Search") })
    self.setEntry.target = self
    self.setEntry.onTextChangeFunction = Admin.onSettingSearch
    self:addChild(self.setEntry)
    local resetLabel = tr("Admin_Set_ResetGroup")
    self.setResetButton = Button.create(0, 0, textWidth(resetLabel) + 24, 22, resetLabel, self, Admin.onResetGroupClick, "chip")
    self:addChild(self.setResetButton)
    self.settingsList = U.newTable(OptionCell, lineH() * 2 + 12)
    -- VirtualList hands onSelect the row but not the x it was hit at, and the controls of a row
    -- sit side by side: remember the x of the click that is about to select.
    local listDown = self.settingsList.onMouseDown
    self.settingsList.onMouseDown = function(list, x, y)
        self.settingClickX = x
        return listDown(list, x, y)
    end
    self.settingsList.onSelect = function(_, item)
        self:onSettingRow(item, self.settingClickX or 0)
    end
    self:addChild(self.settingsList)

    -- last child: the search dropdown paints over the page and takes the click before the row
    -- underneath it (the dialog is added later still, and hides the dropdown while it is open)
    local sug = ISPanel:new(0, 0, PLAYERS_MIN_W, rowH())
    setmetatable(sug, Suggest)
    sug.background = false
    sug.admin = self
    sug:initialise()
    sug:setVisible(false)
    self.suggestList = sug
    self:addChild(sug)

    self:layout()
end

-- ----- state / actions -----

function Admin:onSubTab(button)
    if self.tab == button.internal then return end
    self.tab = button.internal
    for _, b in ipairs(self.subTabButtons) do b.active = b.internal == self.tab end
    self.message = nil
    self:closeDialog()
    self:closeSuggest()
    pcall(function() self.userEntry:unfocus() end)   -- a hidden text box must not keep the keyboard
    pcall(function() self.setEntry:unfocus() end)
    self:layout()
    self:refresh()
end

function Admin:onRefreshClick()
    self.message = nil
    self:refresh()
end

function Admin:onLookupClick()
    local username = string.match(entryText(self.userEntry), "^%s*(.-)%s*$")
    if username == "" then
        self.message = { text = tr("Admin_Player_Hint"), error = true }
        return
    end
    local ok, why = self:requestLookup(username)
    if not ok and why == "throttled" then
        self.message = { text = tr("Admin_Throttled"), error = true }
    end
end

-- Never touches self.message: a background re-read must not overwrite the result of the write the
-- admin just did. A request blocked by the cooldown (or by a lookup still in flight for the old
-- target) is remembered and retried from prerender, so a click is never silently dropped.
function Admin:requestLookup(username)
    if username ~= self.lookupUser then
        -- switching target: drop the old snapshot and any dialog bound to it
        self:closeDialog()
        self.lookup = nil
        self.lookupError = nil
        self.selectedReceipt = nil
        self.receiptRows = {}
        self.receiptList:setItems({})
        self.receiptList:setSelectedIndex(nil)
        self.pendingAdjust = nil
        self.pendingFreeze = nil
        self.message = nil
    end
    self:closeSuggest()
    self.lookupUser = username
    local ok, why = send("admin.lookup", { username = username })
    self.lookupRetryUser = (not ok) and username or nil
    self:updateEnabled()
    return ok, why
end

-- ----- account search candidates -----

-- A keystroke only arms the debounce; the request itself goes out from prerender, so a fast
-- typist costs one command per PLAYERS_DEBOUNCE_MS instead of one per key.
function Admin:onUserQueryChanged()
    self.playersQueryAt = EC.now()
    self.playersOpen = true
end

-- Forget the candidates: a pick, a lookup, Escape, a tab switch and a permission collapse all
-- invalidate them, and the next focus asks again.
function Admin:closeSuggest()
    self.playersOpen = false
    self.players = nil
    self.playersTotal = nil
    self.playersTruncated = nil
    self.playersSentQuery = nil
    self.playersQueryAt = nil
    self.suggestShown = 0
    self.suggestMore = false
    self.suggestEmpty = false
    if self.suggestList then self.suggestList:setVisible(false) end
end

function Admin:pickPlayer(username)
    setEntryText(self.userEntry, username)
    pcall(function() self.userEntry:unfocus() end)
    self:requestLookup(username)   -- closes the dropdown
end

-- Row plan and geometry of the dropdown. Called per frame from tickPlayers, so it only does
-- arithmetic: no row tables, no text measuring, and no bringToTop (the panel is the last child).
function Admin:layoutSuggest()
    local list, g = self.suggestList, self.g
    if not (list and g) then return end
    local rh = rowH()
    -- the dropdown never runs past the panel: the room below the search box caps the row count
    local cap = math.min(PLAYERS_ROWS_MAX, math.floor((self.height - g.suggestY - 2) / rh))
    local players = self.players
    local shown, more, empty = 0, false, false
    if players and cap > 0 then
        local n = #players
        if n == 0 then
            empty = self.playersSentQuery ~= nil and self.playersSentQuery ~= ""
        else
            shown = math.min(n, cap)
            local total = tonumber(self.playersTotal) or n
            more = shown < n or total > n or self.playersTruncated == true
            if more and shown >= cap then shown = cap - 1 end
            if shown < 1 then shown, more = 1, false end
        end
    end
    self.suggestShown = shown
    self.suggestMore = more
    self.suggestEmpty = empty
    local rows = shown + ((more or empty) and 1 or 0)
    local open = rows > 0 and self.playersOpen == true and self.dialog == nil
        and self.tab == "Player" and self.hadRead == true
        and (self.playersFocused == true or list:isMouseOver())
    list:setVisible(open)
    if not open then return end
    list:setX(0)
    list:setY(g.suggestY)
    list:setWidth(g.suggestW)
    list:setHeight(rows * rh + 2)
end

-- Debounce clock, the focus-driven first query and the dropdown's visibility.
function Admin:tickPlayers(now)
    local focused = false
    local ok, v = pcall(function() return self.userEntry:isFocused() end)
    if ok and v == true then focused = true end
    if focused and not self.playersFocused then
        self.playersOpen = true
        -- nothing cached yet: an empty query lists whoever is online
        if self.players == nil then self.playersQueryAt = now - PLAYERS_DEBOUNCE_MS end
    end
    self.playersFocused = focused
    local at = self.playersQueryAt
    -- a query still in flight is left to finish: nothing is measured, cut or allocated per frame
    if at and now - at >= PLAYERS_DEBOUNCE_MS and not isPending("admin.players") then
        local q = string.match(entryText(self.userEntry), "^%s*(.-)%s*$")
        if q == self.playersSentQuery then
            self.playersQueryAt = nil
        elseif send("admin.players", { query = q }) then
            self.playersSentQuery = q
            self.playersQueryAt = nil
        end
    end
    self:layoutSuggest()
end

function Admin:onAuditQueryChanged()
    local q = string.match(entryText(self.auditEntry), "^%s*(.-)%s*$")
    self.auditQuery = q ~= "" and string.lower(q) or nil
    self:rebuildAudit()
end

function Admin:onAuditFilter(button)
    self.auditFilter = button.internal
    for _, b in ipairs(self.auditFilterButtons) do b.active = b.internal == self.auditFilter end
    if self.auditFile == nil then
        send("admin.auditFile", {})
        self:updateEnabled()
    end
    self:rebuildAudit()
end

function Admin:onCopyPath(button)
    local paths = self.system and self.system.paths
    local path = paths and paths[button.internal]
    if type(path) ~= "string" or path == "" then return end
    if not (Clipboard and Clipboard.setClipboard) then
        self.message = { text = tr("Admin_Sys_CopyFailed"), error = true }
        return
    end
    local ok = pcall(Clipboard.setClipboard, path)
    self.message = { text = ok and tr("Admin_Sys_Copied") or tr("Admin_Sys_CopyFailed"), error = not ok }
end

function Admin:selectedCurrency()
    return self.cfgSelected or EC.CURRENCY_ORDER[1]
end

-- The integration row the action buttons operate on: the clicked one, else the first the
-- server sent (the list is already sorted by modId).
function Admin:selectedSource()
    local list = self.sources or {}
    for _, s in ipairs(list) do
        if s.modId == self.srcSelected then return s end
    end
    return list[1]
end

-- Icon status for a currency: the hash/bytes come from the config snapshot (what every client
-- sees); the error comes from the last admin.icons reply (host-only detail).
function Admin:iconLines(def)
    local status = self.icons and self.icons[def.id] or nil
    if EC.isIconHash(def.iconHash) and type(def.iconBytes) == "number" then
        self:line(getText(T .. "Admin_Cur_IconCustom", def.iconHash, tostring(math.floor((def.iconBytes + 1023) / 1024))), "textMuted")
    else
        self:line(tr("Admin_Cur_IconDefault"), "textMuted")
        self:line(getText(T .. "Admin_Cur_IconHint", def.id .. ".png"), "textFaint")
    end
    if status and status.error then
        local code = tostring(status.error)
        self:line(getText(T .. "Admin_Cur_IconError", getTextOrNull(T .. "Admin_IconErr_" .. code) or code), "errorText")
    end
end

function Admin:onIconsClick()
    self.message = nil
    local ok, err = send("admin.icons", { action = "reload" })
    if not ok then self.message = { text = errorText(err), error = true } end
    self:updateEnabled()
end

function Admin:onRenameClick()
    local id = self:selectedCurrency()
    local dlg = self:openDialog("name", { currency = id, title = getText(T .. "Admin_Name_Title", currencyName(id)), confirm = tr("Admin_Name_Confirm") })
    if dlg then
        local def = currencyDef(id)
        setEntryText(dlg.boxes.name, def and def.nameOverride or "")
    end
end

function Admin:onToggleClick()
    local id = self:selectedCurrency()
    local def = currencyDef(id)
    local target = not (def == nil or def.enabled ~= false)
    self:openDialog("enabled", {
        currency = id, enabledTarget = target,
        title = getText(T .. "Admin_Enable_Title", currencyName(id)),
        confirm = tr("Admin_Enable_Confirm"), warn = tr("Admin_Enable_Warn"),
    })
end

function Admin:onBalanceMaxClick()
    local id = self:selectedCurrency()
    local def = currencyDef(id)
    local dlg = self:openDialog("balanceMax", {
        currency = id, title = getText(T .. "Admin_BalanceMax_Title", currencyName(id)),
        confirm = tr("Admin_BalanceMax_Confirm"), warn = tr("Admin_BalanceMax_Warn"),
    })
    if dlg and def and def.balanceMaxOverride then
        setEntryText(dlg.boxes.balanceMax, tostring(def.balanceMaxOverride))
    end
end

function Admin:onRateClick()
    local id = self:selectedCurrency()
    local def = currencyDef(id)
    if not (def and type(def.exchange) == "table") then
        self.message = { text = tr("Admin_Cur_NoExchange"), error = true }
        return
    end
    local dlg = self:openDialog("exchange", {
        currency = id, title = getText(T .. "Admin_Exchange_Title", currencyName(id)),
        confirm = tr("Admin_Exchange_Confirm"), warn = tr("Admin_Exchange_Warn"),
    })
    if dlg then
        for _, field in ipairs(EXCHANGE_FIELDS) do
            setEntryText(dlg.boxes[field], tostring(def.exchange[field] or ""))
        end
    end
end

function Admin:onSourceCapsClick()
    local src = self:selectedSource()
    if not src then return end
    local dlg = self:openDialog("sourceCaps", {
        modId = src.modId, title = getText(T .. "Admin_Src_CapsTitle", tostring(src.modId)),
        confirm = tr("Admin_Src_CapsConfirm"),
    })
    if dlg then
        setEntryText(dlg.boxes.mintCap, tostring(src.dailyMintCap or 0))
        setEntryText(dlg.boxes.burnCap, src.dailyBurnCap ~= nil and tostring(src.dailyBurnCap) or "")
    end
end

function Admin:onSourceToggleClick()
    local src = self:selectedSource()
    if not src then return end
    local target = not (src.enabled ~= false)
    self:openDialog("sourceEnabled", {
        modId = src.modId, enabledTarget = target,
        title = getText(T .. (target and "Admin_Src_EnableTitle" or "Admin_Src_DisableTitle"), tostring(src.modId)),
        confirm = tr(target and "Admin_Src_EnableConfirm" or "Admin_Src_DisableConfirm"),
        warn = (not target) and tr("Admin_Src_DisableWarn") or nil,
    })
end

function Admin:onAdjustClick()
    if not self.lookup then return end
    local currency = (self.selectedReceipt and self.selectedReceipt.currency) or currencyOrder(self.lookup)[1]
    local dlg = self:openDialog("adjust", {
        currency = currency,
        title = getText(T .. "Admin_Adjust_Title", tostring(self.lookupUser)),
        confirm = tr("Admin_Adjust_Confirm"), warn = tr("Admin_Adjust_Warn"),
    })
    if dlg and self.selectedReceipt and self.selectedReceipt.txId then
        setEntryText(dlg.boxes.reversal, self.selectedReceipt.txId)
        dlg:updateInfo()
    end
end

function Admin:onFreezeClick()
    if not self.lookup then return end
    local target = not (self.lookup.frozen == true)
    self:openDialog("freeze", {
        frozenTarget = target,
        title = getText(T .. (target and "Admin_Freeze_Title" or "Admin_Unfreeze_Title"), tostring(self.lookupUser)),
        confirm = tr(target and "Admin_Freeze_Confirm" or "Admin_Unfreeze_Confirm"),
        warn = target and tr("Admin_Freeze_Warn") or nil,
    })
end

-- ----- settings page actions -----

-- Options of one group: how many there are and how many carry a runtime override. Drives the
-- nav counters and the "reset this group" button; locked options can never be overridden here.
function Admin:optionGroupCount(group)
    local snap = self.options
    local total, overrides = 0, 0
    for _, spec in ipairs(EC.OPTIONS) do
        if spec.group == group then
            total = total + 1
            local state = snap and snap[spec.key]
            if state and state.override == true and spec.locked ~= true and state.locked ~= true then
                overrides = overrides + 1
            end
        end
    end
    return total, overrides
end

function Admin:overriddenKeys(group)
    local keys = {}
    local snap = self.options
    for _, spec in ipairs(EC.OPTIONS) do
        if spec.group == group and spec.locked ~= true then
            local state = snap and snap[spec.key]
            if state and state.override == true and state.locked ~= true then keys[#keys + 1] = spec.key end
        end
    end
    return keys
end

-- Search is a filter over the rows, not a request: the whole option schema is local.
function Admin:onSettingSearch()
    local raw = string.match(entryText(self.setEntry), "^%s*(.-)%s*$")
    local query = raw ~= "" and string.lower(raw) or nil
    if query == self.setQuery then return end
    self.setQuery = query
    self.setResetButton:setVisible(self.tab == "Settings" and self:readAllowed() and query == nil)
    self:rebuildSettings()
    self:updateEnabled()
end

-- Nav rows are painted, so the click is resolved from the row height instead of stored rects.
function Admin:onSettingNav(y)
    local g = self.g
    local rowHeight = g and g.setNavRowH
    if not rowHeight or y < g.setNavY then return end
    local index = math.floor((y - g.setNavY) / rowHeight) + 1
    local group = EC.OPTION_GROUPS[index]
    if not group or group == self.setGroup then return end
    self.setGroup = group
    self:rebuildSettings()
    self:updateEnabled()
end

-- A click inside the option list: the row's own hit boxes first, then the value text of an
-- editable row (a wide, obvious target for the dialog).
function Admin:onSettingRow(item, x)
    if item == nil or self.settingsList.optionsDisabled then return end
    for _, hit in ipairs(item.hits) do
        if x >= hit.x and x < hit.x + hit.w then
            self:onOptionAction(item, hit.id)
            return
        end
    end
    if item.editable and x >= item.valueX and x < item.valueX + item.valueW then
        self:onOptionAction(item, "edit")
    end
end

function Admin:onOptionAction(item, id)
    local spec = item.spec
    local state = (self.options or {})[spec.key]
    local value = state and state.value
    if id == "reset" then
        self:sendOption(spec.key, nil, nil)
    elseif id == "toggle" then
        self:sendOption(spec.key, value ~= true, nil)
    elseif id == "minus" or id == "plus" then
        local base = tonumber(value)
        if base == nil then base = tonumber(spec.default) or spec.min or 0 end
        local target = base + (id == "plus" and (spec.step or 1) or -(spec.step or 1))
        if target < spec.min then target = spec.min end
        if target > spec.max then target = spec.max end
        if target ~= base then self:sendOption(spec.key, target, nil) end
    elseif id == "edit" then
        local hint = nil
        if spec.kind == "list_int" then
            hint = tr("Admin_Set_ListHint")
        elseif spec.kind == "int" or spec.kind == "number" then
            hint = getText(T .. "Admin_Set_NumberHint", optionInputText(spec, spec.min), optionInputText(spec, spec.max))
        end
        self:openDialog("option", {
            title = getText(T .. "Admin_Set_EditTitle", item.plainName),
            confirm = tr("Admin_Set_Edit"),
            optionKey = spec.key,
            hint = hint,
            value = optionInputText(spec, value),
        })
    end
end

-- One write per click. `value == nil` drops the runtime override, so the sandbox file's value is
-- what the server runs with again (Lua tables have no nil member: the key is simply absent).
function Admin:sendOption(key, value, dlg)
    if not self:writeAllowed() then
        local msg = { text = errorText("forbidden"), error = true }
        if dlg then dlg.message = msg; self:layoutDialog() else self.message = msg end
        return false
    end
    local args = { key = key, requestId = newRequestId() }
    if value ~= nil then args.value = value end
    if not send("admin.option", args) then
        local msg = { text = tr("Admin_Throttled"), error = true }
        if dlg then dlg.message = msg; self:layoutDialog() else self.message = msg end
        return false
    end
    self.pendingOption = { requestId = args.requestId, key = key }
    if not dlg then self.message = nil end
    self:updateEnabled()
    return true
end

-- Group reset is one command per key: the queue advances on every reply, so the client cooldown
-- (and the server's) is never fought against.
function Admin:nextOptionReset()
    local queue = self.resetQueue
    if queue == nil then return end
    if queue.i > #queue.keys then
        self.resetQueue = nil
        return
    end
    local key = queue.keys[queue.i]
    queue.i = queue.i + 1
    if not self:sendOption(key, nil, nil) then self.resetQueue = nil end
end

function Admin:onResetGroupClick()
    local keys = self:overriddenKeys(self.setGroup)
    if #keys == 0 then return end
    self:openDialog("optionReset", {
        title = tr("Admin_Set_ResetGroup"),
        confirm = tr("Admin_Set_Reset"),
        warn = getText(T .. "Admin_Set_ResetConfirm", tr("Admin_Set_Group_" .. self.setGroup), tostring(#keys)),
        optionGroup = self.setGroup,
    })
end

-- ----- shop catalog actions -----

function Admin:onShopReloadClick()
    self.message = nil
    self:sendCatalog({ action = "reload" }, nil)
end

-- A click inside the catalog list: the row's own hit boxes. Rows carry two control lines, so the
-- test needs the row-local y as well as the x (both captured in createChildren).
function Admin:onCatalogRow(item, x, y)
    if item == nil or self.catalogList.optionsDisabled then return end
    for _, hit in ipairs(item.hits) do
        if x >= hit.x and x < hit.x + hit.w and y >= hit.y and y < hit.y + hit.h then
            self:onCatalogAction(item, hit.id)
            return
        end
    end
end

function Admin:onCatalogAction(item, id)
    local sku = item.sku
    local price = math.floor(tonumber(sku.price) or 0)
    local cap = math.floor(tonumber(sku.dailyCap) or 0)
    if id == "toggle" then
        self:sendCatalog({ action = "set", id = sku.id, enabled = sku.enabled == false }, nil)
    elseif id == "priceMinus" or id == "pricePlus" then
        local step = priceStep(price)
        local target = price + (id == "pricePlus" and step or -step)
        if target < 1 then target = 1 end
        if target > PRICE_MAX then target = PRICE_MAX end
        if target ~= price then self:sendCatalog({ action = "set", id = sku.id, price = target }, nil) end
    elseif id == "capMinus" or id == "capPlus" then
        local target = cap + (id == "capPlus" and 1 or -1)
        if target < 0 then target = 0 end
        if target > CAP_MAX then target = CAP_MAX end
        if target ~= cap then self:sendCatalog({ action = "set", id = sku.id, dailyCap = target }, nil) end
    elseif id == "priceEdit" then
        self:openDialog("catalogPrice", {
            title = getText(T .. "Admin_Shop_EditPrice", item.plainName),
            confirm = tr("Admin_Set_Edit"), catalogId = sku.id,
            hint = getText(T .. "Admin_Set_NumberHint", "1", tostring(PRICE_MAX)),
            value = tostring(price),
        })
    elseif id == "capEdit" then
        self:openDialog("catalogCap", {
            title = getText(T .. "Admin_Shop_EditCap", item.plainName),
            confirm = tr("Admin_Set_Edit"), catalogId = sku.id,
            hint = getText(T .. "Admin_Set_NumberHint", "0", tostring(CAP_MAX)),
            value = tostring(cap),
        })
    end
end

-- One write per click; every reply carries the whole catalog back, so nothing is guessed here.
function Admin:sendCatalog(args, dlg)
    if not self:writeAllowed() then
        local msg = { text = errorText("forbidden"), error = true }
        if dlg then dlg.message = msg; self:layoutDialog() else self.message = msg end
        return false
    end
    args.requestId = newRequestId()
    if not send("admin.catalog", args) then
        local msg = { text = tr("Admin_Throttled"), error = true }
        if dlg then dlg.message = msg; self:layoutDialog() else self.message = msg end
        return false
    end
    self.pendingCatalog = { requestId = args.requestId, id = args.id, action = args.action }
    if not dlg then self.message = nil end
    self:updateEnabled()
    return true
end

-- ----- market listings actions -----

function Admin:onWhitelistReloadClick()
    self.message = nil
    self:sendWhitelist({ action = "reload" })
end

-- The page and the search text are state, not a request: the read goes out from here when the
-- command is free and is retried from prerender when the cooldown (or an older answer) held it,
-- so a keystroke is never silently dropped.
function Admin:requestListings()
    local args = { action = "list", page = self.lstPage or 1, query = self.lstQuery }
    if not send("admin.listings", args) then return false end
    self.lstSentQuery = self.lstQuery
    self.lstSentPage = args.page
    self:updateEnabled()
    return true
end

function Admin:onListingSearch()
    local raw = string.match(entryText(self.lstEntry), "^%s*(.-)%s*$")
    self.lstQuery = raw ~= "" and string.lower(raw) or nil
    self.lstPage = 1
    self:requestListings()
end

function Admin:onListingPage(button)
    local pages = 1
    if self.listings then pages = math.max(1, math.floor(tonumber(self.listings.pages) or 1)) end
    local page = math.max(1, math.min(pages, (self.lstPage or 1) + button.internal))
    if page == (self.lstPage or 1) then return end
    self.lstPage = page
    self.message = nil
    self:requestListings()
end

-- A click inside the listing list: the row's own delist chip.
function Admin:onListingRow(item, x, y)
    if item == nil or self.listingsList.optionsDisabled then return end
    local hit = item.delist
    if x >= hit.x and x < hit.x + hit.w and y >= hit.y and y < hit.y + hit.h then
        self:openDialog("delist", {
            title = getText(T .. "Admin_Lst_DelistTitle", item.plainName, item.seller),
            confirm = tr("Admin_Lst_Delist"), listingId = item.id,
        })
    end
end

-- One write per click; every reply carries the current page back, so nothing is guessed here.
function Admin:sendListings(args, dlg)
    if not self:writeAllowed() then
        local msg = { text = errorText("forbidden"), error = true }
        if dlg then dlg.message = msg; self:layoutDialog() else self.message = msg end
        return false
    end
    args.requestId = newRequestId()
    args.page = self.lstPage or 1
    args.query = self.lstQuery
    if not send("admin.listings", args) then
        local msg = { text = tr("Admin_Throttled"), error = true }
        if dlg then dlg.message = msg; self:layoutDialog() else self.message = msg end
        return false
    end
    self.pendingListings = { requestId = args.requestId, action = args.action, listingId = args.listingId }
    if not dlg then self.message = nil end
    self:updateEnabled()
    return true
end

function Admin:sendWhitelist(args)
    if not self:writeAllowed() then
        self.message = { text = errorText("forbidden"), error = true }
        return false
    end
    args.requestId = newRequestId()
    if not send("admin.whitelist", args) then
        self.message = { text = tr("Admin_Throttled"), error = true }
        return false
    end
    self.pendingWhitelist = { requestId = args.requestId, action = args.action }
    self:updateEnabled()
    return true
end

-- ----- upload whitelist actions -----

-- The item universe is a session-long read (every script item the server knows): built on the
-- first rebuild that needs it, dropped when the panel closes.
function Admin:whitelistUniverse()
    if self.wlUniverse == nil then self.wlUniverse = whitelistUniverse() end
    return self.wlUniverse
end

-- Local filter only: the file's state is already on this side, so a keystroke never leaves the
-- client.
function Admin:onWhitelistSearch()
    local raw = string.match(entryText(self.wlEntry), "^%s*(.-)%s*$")
    self.wlQuery = raw ~= "" and string.lower(raw) or nil
    self:rebuildWhitelist()
end

-- A click inside the whitelist list: the row's own chips. A category row carries one (it reads
-- allow while the category is on the list, deny otherwise); an item row carries both, and
-- clicking the chip that is already lit clears the per-item entry so the item follows its
-- category again.
function Admin:onWhitelistRow(item, x, y)
    if item == nil or self.whitelistList.optionsDisabled then return end
    for _, hit in ipairs(item.hits) do
        if x >= hit.x and x < hit.x + hit.w and y >= hit.y and y < hit.y + hit.h then
            self.message = nil
            if item.kind == "category" then
                self:sendWhitelist({ action = "set", category = item.cat, allowed = not item.allowed })
            else
                self:sendWhitelist({ action = "set", fullType = item.fullType,
                    mode = hit.active and "inherit" or hit.id })
            end
            return
        end
    end
end

-- ----- dialog lifecycle -----

function Admin:openDialog(mode, ctx)
    if not self:writeAllowed() then
        self.message = { text = errorText("forbidden"), error = true }
        return nil
    end
    self:closeDialog()
    local dlg = ISPanel:new(0, 0, 360, 200)
    setmetatable(dlg, Dialog)
    dlg.background = false
    dlg.admin = self
    dlg.mode = mode
    dlg.currency = ctx.currency
    dlg.modId = ctx.modId
    dlg.frozenTarget = ctx.frozenTarget
    dlg.enabledTarget = ctx.enabledTarget
    dlg.titleText = ctx.title
    dlg.confirmLabel = ctx.confirm
    dlg.warnText = ctx.warn
    dlg.optionKey = ctx.optionKey
    dlg.optionGroup = ctx.optionGroup
    dlg.catalogId = ctx.catalogId
    dlg.listingId = ctx.listingId
    dlg.hintText = ctx.hint
    dlg.info = {}
    dlg.message = nil
    dlg:initialise()
    self:addChild(dlg)      -- the boxes exist from here on (instantiate -> createChildren)
    self.dialog = dlg
    if ctx.value ~= nil then setEntryText(dlg.boxes.value, ctx.value) end
    dlg:updateInfo()
    self:layoutDialog()
    self:updateEnabled()
    return dlg
end

function Admin:layoutDialog()
    local dlg = self.dialog
    if not dlg then return end
    dlg:layoutInside(math.max(320, self.width - PAD * 4), math.max(160, self.height - PAD * 2))
    dlg:setX(math.max(0, math.floor((self.width - dlg.width) / 2)))
    dlg:setY(math.max(0, math.floor((self.height - dlg.height) / 2)))
end

function Admin:closeDialog()
    local dlg = self.dialog
    if not dlg then return end
    self.dialog = nil
    dlg:unfocusAll()
    dlg:setVisible(false)
    self:removeChild(dlg)
    self:updateEnabled()
end

-- Local validation first (the server re-validates everything); then one command with a fresh
-- requestId and the wallet revision the dialog was showing.
-- The option dialog carries no reason box and the group reset carries no field at all, so both
-- are answered before the reason gate every other write has to pass.
function Admin:submitDialog(dlg)
    if dlg.mode == "option" then return self:submitOption(dlg) end
    if dlg.mode == "catalogPrice" or dlg.mode == "catalogCap" then return self:submitCatalogValue(dlg) end
    if dlg.mode == "optionReset" then
        local keys = self:overriddenKeys(dlg.optionGroup)
        self:closeDialog()
        if #keys == 0 then return end
        self.resetQueue = { keys = keys, i = 1 }
        self:nextOptionReset()
        return
    end
    local reason = string.match(entryText(dlg.boxes.reason), "^%s*(.-)%s*$")
    local reasonChars = charCount(reason)
    -- any non-empty reason is accepted; REASON_MAX only guards the one-line JSON files
    if reasonChars < 1 or string.find(reason, "%c") then
        dlg.message = { text = tr("Admin_Adjust_BadReason"), error = true }
        self:layoutDialog()
        return
    elseif reasonChars > REASON_MAX then
        dlg.message = { text = errorText("reason_too_long"), error = true }
        self:layoutDialog()
        return
    end
    if dlg.mode == "adjust" then
        local delta = parseInt(entryText(dlg.boxes.amount))
        if not delta or delta == 0 then
            dlg.message = { text = tr("Admin_Adjust_BadAmount"), error = true }
            self:layoutDialog()
            return
        end
        local maxPerTx = self.lookup and tonumber(self.lookup.maxPerTx)
        if maxPerTx and math.abs(delta) > maxPerTx then
            dlg.message = { text = errorText("over_max_per_tx"), error = true }
            self:layoutDialog()
            return
        end
        local bal = self.lookup and self.lookup.balances and self.lookup.balances[dlg.currency]
        local rev = bal and tonumber(bal.rev) or 0
        local reversal = string.match(entryText(dlg.boxes.reversal), "^%s*(.-)%s*$")
        local requestId = newRequestId()
        local ok, why = send("admin.adjust", {
            username = self.lookupUser, currency = dlg.currency, delta = delta, reason = reason,
            expectedRev = rev, requestId = requestId,
            reversalOfTxId = reversal ~= "" and reversal or nil,
        })
        if not ok then
            dlg.message = { text = tr("Admin_Throttled"), error = true }
            self:layoutDialog()
            return
        end
        self.pendingAdjust = { username = self.lookupUser, currency = dlg.currency, delta = delta, requestId = requestId }
    elseif dlg.mode == "freeze" then
        local ok = send("admin.freeze", { username = self.lookupUser, frozen = dlg.frozenTarget == true, reason = reason })
        if not ok then
            dlg.message = { text = tr("Admin_Throttled"), error = true }
            self:layoutDialog()
            return
        end
        self.pendingFreeze = { username = self.lookupUser, frozen = dlg.frozenTarget == true }
    elseif dlg.mode == "sourceCaps" or dlg.mode == "sourceEnabled" then
        if type(dlg.modId) ~= "string" or dlg.modId == "" then
            dlg.message = { text = errorText("invalid_args"), error = true }
            self:layoutDialog()
            return
        end
        local payload = { action = "set", modId = dlg.modId, reason = reason }
        if dlg.mode == "sourceCaps" then
            local mint = parseInt(entryText(dlg.boxes.mintCap))
            if not mint or mint < 0 then
                dlg.message = { text = tr("Admin_Src_BadCap"), error = true }
                self:layoutDialog()
                return
            end
            payload.dailyMintCap = mint
            -- an empty burn field is an explicit "no limit": the server only clears the stored
            -- cap when it is told `false` (nil would mean "leave it alone")
            local raw = string.match(entryText(dlg.boxes.burnCap), "^%s*(.-)%s*$")
            if raw == "" then
                payload.dailyBurnCap = false
            else
                local burn = parseInt(raw)
                if not burn or burn < 0 then
                    dlg.message = { text = tr("Admin_Src_BadCap"), error = true }
                    self:layoutDialog()
                    return
                end
                payload.dailyBurnCap = burn
            end
        else
            payload.enabled = dlg.enabledTarget == true
        end
        payload.requestId = newRequestId()
        if not send("admin.sources", payload) then
            dlg.message = { text = tr("Admin_Throttled"), error = true }
            self:layoutDialog()
            return
        end
        self.pendingSource = { requestId = payload.requestId, modId = dlg.modId }
    elseif dlg.mode == "delist" then
        if dlg.listingId == nil then
            dlg.message = { text = errorText("invalid_args"), error = true }
            self:layoutDialog()
            return
        end
        if not self:sendListings({ action = "delist", listingId = dlg.listingId, reason = reason }, dlg) then return end
    else
        local field, value
        if dlg.mode == "name" then
            field = "name"
            value = string.match(entryText(dlg.boxes.name), "^%s*(.-)%s*$")
            if #value > NAME_MAX then
                dlg.message = { text = errorText("invalid_args"), error = true }
                self:layoutDialog()
                return
            end
        elseif dlg.mode == "enabled" then
            field = "enabled"
            value = dlg.enabledTarget == true
        elseif dlg.mode == "balanceMax" then
            field = "balanceMax"
            local raw = string.match(entryText(dlg.boxes.balanceMax), "^%s*(.-)%s*$")
            if raw ~= "" then
                local n = parseInt(raw)
                if not n or n < 1000 then
                    dlg.message = { text = tr("Admin_BalanceMax_BadValue"), error = true }
                    self:layoutDialog()
                    return
                end
                value = n
            end
        else
            field = "exchange"
            local values = {}
            for _, key in ipairs(EXCHANGE_FIELDS) do
                local n = parseInt(entryText(dlg.boxes[key]))
                if not n or n <= 0 then
                    dlg.message = { text = tr("Admin_Exchange_BadValue"), error = true }
                    self:layoutDialog()
                    return
                end
                values[key] = n
            end
            if values.perOrderMin > values.perOrderMax then
                dlg.message = { text = tr("Admin_Exchange_BadValue"), error = true }
                self:layoutDialog()
                return
            end
            value = values
        end
        local ok = send("admin.config", { currency = dlg.currency, field = field, value = value, reason = reason })
        if not ok then
            dlg.message = { text = tr("Admin_Throttled"), error = true }
            self:layoutDialog()
            return
        end
        self.pendingConfig = { currency = dlg.currency, field = field }
    end
    dlg.message = nil
    self:updateEnabled()
end

-- The same checks ECConfig.validateOption runs, so a typo never costs a round trip; the hint
-- line (the range / the list format) doubles as the error message, because it says what is
-- accepted. The server re-validates everything regardless.
function Admin:submitOption(dlg)
    local spec = EC.OPTION_BY_KEY[dlg.optionKey]
    if spec == nil then
        dlg.message = { text = errorText("unknown_option"), error = true }
        self:layoutDialog()
        return
    end
    local raw = string.match(entryText(dlg.boxes.value), "^%s*(.-)%s*$")
    local value
    if spec.kind == "list_int" then
        if EC.parseIntList(raw, spec) == nil then
            dlg.message = { text = dlg.hintText or errorText("invalid_args"), error = true }
            self:layoutDialog()
            return
        end
        value = raw
    elseif spec.kind == "text" then
        if raw == "" or charCount(raw) > OPTION_TEXT_MAX or string.find(raw, "%c") then
            dlg.message = { text = errorText("invalid_args"), error = true }
            self:layoutDialog()
            return
        end
        value = raw
    else
        local n = tonumber(raw)
        local bad = n == nil or n ~= n or n < spec.min or n > spec.max
        if not bad and spec.kind == "int" and n ~= math.floor(n) then bad = true end
        if not bad and spec.kind == "number" and spec.step then
            local steps = n / spec.step
            if math.abs(steps - math.floor(steps + 0.5)) > 1e-9 then bad = true end
        end
        if bad then
            dlg.message = { text = dlg.hintText or errorText("invalid_args"), error = true }
            self:layoutDialog()
            return
        end
        value = n
    end
    self:sendOption(dlg.optionKey, value, dlg)
end

-- The catalog dialog carries one integer and no reason box; the range the server enforces is
-- checked here too, and the hint line doubles as the refusal message because it says what is
-- accepted. The server re-validates regardless.
function Admin:submitCatalogValue(dlg)
    local price = dlg.mode == "catalogPrice"
    local n = parseInt(entryText(dlg.boxes.value))
    if n == nil or n < (price and 1 or 0) or n > (price and PRICE_MAX or CAP_MAX) then
        dlg.message = { text = dlg.hintText or errorText("invalid_args"), error = true }
        self:layoutDialog()
        return
    end
    local args = { action = "set", id = dlg.catalogId }
    if price then args.price = n else args.dailyCap = n end
    self:sendCatalog(args, dlg)
end

-- ----- replies -----

function Admin:onReply(kind, args)
    -- the server states the permission level it just enforced; it wins over the local role read
    if type(args.perms) == "table" then self.serverPerms = args.perms end
    if kind == "lookup" then
        if args.ok == false then
            if args.username and args.username ~= self.lookupUser then return end
            self.lookupError = args.error or "unknown"
            self.lookup = nil
            self.receiptRows = {}
            self.receiptList:setItems({})
        elseif args.username ~= self.lookupUser then
            return -- stale: the admin already asked about someone else
        else
            self.lookupError = nil
            self.lookup = args
            self.lookupAt = EC.now()
            self.lookupFile = nil
            self:rebuildReceipts()
            -- the ring paints first; the receipt files (with rolled-back lines) replace it
            send("admin.receipts", { username = self.lookupUser })
            if self.dialog then self.dialog:updateInfo(); self:layoutDialog() end
        end
    elseif kind == "adjust" then
        local req = self.pendingAdjust
        if not req or req.username ~= args.username then return end
        if args.requestId and req.requestId and args.requestId ~= req.requestId then return end
        self.pendingAdjust = nil
        if args.ok then
            local msg
            if args.replay or args.duplicate then
                -- the ledger recognised the requestId: nothing was posted twice
                msg = { text = args.verified == false and tr("Admin_Adjust_ReplayUnverified") or tr("Admin_Adjust_Duplicate"),
                    error = args.verified == false }
            else
                msg = { text = getText(T .. "Admin_Adjust_Ok", signedText(req.delta), currencyName(req.currency), tostring(args.txId or "-")) }
            end
            self.message = msg
            self:closeDialog()
            self:requestLookup(req.username)
        elseif args.error == "revision_mismatch" or args.error == "request_conflict" or args.error == "expected_rev_required" then
            -- never silently re-post: the next confirm mints a fresh requestId over fresh data
            local key = args.error == "request_conflict" and "Admin_Adjust_Conflict" or "Admin_Adjust_Stale"
            local msg = { text = tr(key), error = true }
            if self.dialog then self.dialog.message = msg else self.message = msg end
            self:requestLookup(req.username)
        else
            local msg = { text = errorText(args.error), error = true }
            if self.dialog then self.dialog.message = msg; self:layoutDialog() else self.message = msg end
        end
    elseif kind == "freeze" then
        local req = self.pendingFreeze
        if not req or req.username ~= args.username then return end
        self.pendingFreeze = nil
        if args.ok then
            self.message = { text = getText(T .. (args.frozen and "Admin_Freeze_Ok" or "Admin_Unfreeze_Ok"), tostring(req.username)) }
            self:closeDialog()
            self:requestLookup(req.username)
        else
            local msg = { text = errorText(args.error), error = true }
            if self.dialog then self.dialog.message = msg; self:layoutDialog() else self.message = msg end
        end
    elseif kind == "config" then
        local req = self.pendingConfig
        if not req then return end
        self.pendingConfig = nil
        if args.ok then
            if type(args.currencies) == "table" then C.currencies = args.currencies end
            self.message = { text = tr("Admin_Config_Ok") }
            self:closeDialog()
            self:layout()
        else
            local msg = { text = errorText(args.error), error = true }
            if self.dialog then self.dialog.message = msg; self:layoutDialog() else self.message = msg end
        end
    elseif kind == "option" then
        -- every reply carries the whole snapshot, a refusal included, so the page always shows
        -- what the server actually runs with
        if type(args.currencies) == "table" then C.currencies = args.currencies end
        if type(args.options) == "table" then
            self.options = args.options
            self.optionsSeen = C.options
        end
        local req = self.pendingOption
        local mine = req == nil or args.requestId == nil or req.requestId == args.requestId
        if mine then
            self.pendingOption = nil
            if args.ok then
                self.message = { text = tr("Admin_Set_Saved") }
                self:closeDialog()
            else
                self.resetQueue = nil   -- a group reset stops at the first refusal
                local msg = { text = errorText(args.error), error = true }
                if self.dialog then self.dialog.message = msg; self:layoutDialog() else self.message = msg end
            end
        end
        self:rebuildSettings()
        if mine and args.ok then self:nextOptionReset() end
    elseif kind == "catalog" then
        -- every reply carries the whole catalog, a refusal included, so the page always shows
        -- what the server actually sells
        if type(args.items) == "table" then
            self.catalog = args
            self.catalogAt = EC.now()
            self:rebuildCatalog()
        end
        local req = self.pendingCatalog
        local mine = req == nil or args.requestId == nil or req.requestId == args.requestId
        if mine then
            self.pendingCatalog = nil
            if not args.ok then
                -- catalog_invalid carries the file's own parse error: the code alone would not
                -- tell the host which line to go and fix
                local body = errorText(args.error)
                if type(args.detail) == "string" and args.detail ~= "" then body = body .. ": " .. args.detail end
                local msg = { text = body, error = true }
                if self.dialog then self.dialog.message = msg; self:layoutDialog() else self.message = msg end
            elseif req and req.action == "reload" then
                local file = args.file
                self.message = { text = getText(T .. "Admin_Shop_Reloaded", tostring((file and file.count) or args.count or 0)) }
            elseif req then
                self.message = { text = tr("Admin_Shop_Saved") }
                self:closeDialog()
            end
        end
    elseif kind == "listings" then
        -- every reply carries the page back, a refusal included, so the page always shows what
        -- the server actually holds
        if type(args.items) == "table" then
            self.listings = args
            self.listingsAt = EC.now()
            self.lstPage = math.max(1, math.floor(tonumber(args.page) or 1))
            self.lstSentPage = self.lstPage   -- the server clamps the page; adopt it, never re-ask
            self:rebuildListings()
        end
        local req = self.pendingListings
        local mine = req == nil or args.requestId == nil or req.requestId == args.requestId
        if mine then
            self.pendingListings = nil
            if not args.ok then
                local msg = { text = errorText(args.error), error = true }
                if self.dialog then self.dialog.message = msg; self:layoutDialog() else self.message = msg end
            elseif req and req.action == "delist" then
                self.message = { text = tr("Admin_Lst_Delisted") }
                self:closeDialog()
            end
        end
    elseif kind == "whitelist" then
        -- every reply carries the file's state back, a refusal included, so the page always
        -- shows what the server actually holds
        if type(args.whitelist) == "table" then
            self.whitelist = args.whitelist
            self:rebuildWhitelist()
        end
        local req = self.pendingWhitelist
        local mine = req == nil or args.requestId == nil or req.requestId == args.requestId
        if mine then
            self.pendingWhitelist = nil
            if not args.ok then
                -- whitelist_invalid carries the file's own parse error: the code alone would not
                -- tell the host which line to go and fix
                local body = errorText(args.error)
                if type(args.detail) == "string" and args.detail ~= "" then body = body .. ": " .. args.detail end
                self.message = { text = body, error = true }
            elseif req and req.action == "reload" then
                self.message = { text = tr("Admin_Wl_Reloaded") }
            elseif req and req.action == "set" then
                self.message = { text = tr("Admin_Wl_Saved") }
            end
        end
    elseif kind == "icons" then
        if args.ok == false then
            self.message = { text = errorText(args.error), error = true }
            return
        end
        if type(args.icons) == "table" then self.icons = args.icons end
        if args.started then
            self.iconsReloading = true
            self.message = { text = tr("Admin_Icons_Started") }
        elseif args.busy then
            self.message = { text = tr("Admin_Icons_Busy") }
        elseif self.iconsReloading then
            -- the status re-check after a reload: replace the "reading..." line with the outcome
            self.iconsReloading = nil
            self.message = { text = tr("Admin_Icons_Done") }
        end
        -- the read runs over the next ticks: ask for the outcome once it had time to finish
        if args.busy then self.iconsRecheckAt = EC.now() + ICONS_RECHECK_MS end
    elseif kind == "audit" then
        if args.ok == false then
            self.message = { text = errorText(args.error), error = true }
            return
        end
        self.audit = args.entries or {}
        self.auditAt = EC.now()
        self:rebuildAudit()
    elseif kind == "receipts" then
        if args.error or args.username ~= self.lookupUser then return end
        self.lookupFile = args.entries or {}
        self:rebuildReceipts()
    elseif kind == "auditFile" then
        if args.error then
            if args.error ~= "busy" then self.message = { text = errorText(args.error), error = true } end
            return
        end
        self.auditFile = args.entries or {}
        self.auditFileAt = EC.now()
        self:rebuildAudit()
    elseif kind == "system" then
        if args.ok == false then
            self.message = { text = errorText(args.error), error = true }
            return
        end
        self.system = args
        self.systemAt = EC.now()
        -- admin.system carries the option snapshot under `sandbox` (ECAdmin.system)
        if type(args.sandbox) == "table" then
            self.options = args.sandbox
            self.optionsSeen = C.options
        end
        self:layout()
    elseif kind == "sources" then
        -- every reply carries the full list, a write reply included
        if type(args.sources) == "table" then
            self.sources = args.sources
            self.sourcesAt = EC.now()
            self:rebuildSources()
        end
        local req = self.pendingSource
        if req and req.requestId == args.requestId then
            self.pendingSource = nil
            if args.ok then
                self.srcSelected = req.modId
                self.message = { text = tr("Admin_Src_Saved") }
                self:closeDialog()
            else
                local msg = { text = errorText(args.error), error = true }
                if self.dialog then self.dialog.message = msg; self:layoutDialog() else self.message = msg end
            end
        elseif args.ok == false then
            self.message = { text = errorText(args.error), error = true }
        end
    elseif kind == "players" then
        -- the server echoes the query it answered (trimmed and lowercased); anything that is not
        -- the answer to the text we last sent is a late reply and is dropped. A refusal is
        -- silent: the search box is a convenience, not a result.
        local sent = self.playersSentQuery
        if args.ok == false or sent == nil or string.lower(sent) ~= tostring(args.query or "") then
            return
        end
        self.players = type(args.players) == "table" and args.players or {}
        self.playersTotal = tonumber(args.total) or #self.players
        self.playersTruncated = args.truncated == true
    end
    self:updateEnabled()
end

function Admin:onTimeout(command)
    -- a candidate query is a background nicety: it never takes over the footer, and the same text
    -- may be asked for again
    if command == "admin.players" then
        self.playersSentQuery = nil
        self:updateEnabled()
        return
    end
    local label = getTextOrNull(T .. "Admin_Cmd_" .. string.sub(command, 7)) or command
    self.message = { text = getText(T .. "Admin_Timeout", label), error = true }
    if command == "admin.option" then
        -- the answer is never coming: forget the write, and stop a group reset where it stands
        self.pendingOption = nil
        self.resetQueue = nil
    end
    if command == "admin.catalog" then self.pendingCatalog = nil end
    if command == "admin.listings" then self.pendingListings = nil end
    if command == "admin.whitelist" then self.pendingWhitelist = nil end
    if command == "admin.adjust" or command == "admin.freeze" or command == "admin.config" or command == "admin.sources" or command == "admin.option" or command == "admin.catalog" or command == "admin.listings" then
        if self.dialog then
            self.dialog.message = { text = getText(T .. "Admin_Timeout", label), error = true }
            self:layoutDialog()
        end
    end
    self:updateEnabled()
end

-- ----- data normalisation (data or geometry changes only) -----

function Admin:rebuildReceipts()
    local rows = {}
    -- receipt file lines (delta / availableAfter) once they arrived, else the ring (amount / after)
    local src = self.lookupFile or (self.lookup and self.lookup.receipts) or {}
    for i = #src, 1, -1 do
        local e = src[i]
        local amount = tonumber(e.amount or e.delta) or 0
        if e.after == nil then e.after = e.availableAfter end
        if e.kind == nil then e.kind = e.type end
        rows[#rows + 1] = {
            txId = e.txId, currency = e.currency,
            cells = {
                stampText(e.ts, self.offsetMin), currencyName(e.currency), signedText(amount),
                kindText(e.kind), amountText(e.after),
                (type(e.item) == "string" and (itemName(e.item) .. " x" .. tostring(math.floor(tonumber(e.qty) or 1)) .. "  ") or "") .. tostring(e.txId or "-"),
            },
            tokens = { "textMuted", "text", amount >= 0 and "positive" or "negative", "text", "text", "textFaint" },
            muted = e.rolledBack == true,
        }
    end
    self.receiptRows = rows
    self.receiptList:setItems(rows)
    self.receiptList:setSelectedIndex(nil)
    self.selectedReceipt = nil
end

-- One audit action = one line in the files and one entry in the ring; the same fields identify it.
local function auditKey(e)
    return tostring(e.epoch) .. ":" .. tostring(e.seq) .. ":" .. tostring(e.ts) .. ":" .. tostring(e.action) .. ":" .. tostring(e.target or e.field)
end

function Admin:rebuildAudit()
    local rows = {}
    local filter = self.auditFilter
    -- Sources: the audit files (this and last month) carry full reasons and the rolled-back lines;
    -- the ModData ring (40-char reasons) only adds what the files do not have (older months).
    -- "rolled" shows the rolled-back file lines alone.
    local fromFile = filter == "rolled"
    local src, seen = {}, {}
    local file = self.auditFile or {}
    for i = #file, 1, -1 do
        local e = file[i]
        if type(e) == "table" and (not fromFile or e.rolledBack == true) then
            seen[auditKey(e)] = true
            src[#src + 1] = e
        end
    end
    if not fromFile then
        for _, e in ipairs(self.audit or {}) do
            if type(e) == "table" and not seen[auditKey(e)] then src[#src + 1] = e end
        end
        if #file > 0 then
            EC.sortSafe(src, function(a, b) return (tonumber(a.ts) or 0) > (tonumber(b.ts) or 0) end)
        end
    end
    local q = self.auditQuery
    for _, e in ipairs(src) do
        if type(e) == "table" then
            local action = tostring(e.action or "?")
            local keep
            if fromFile then keep = e.rolledBack == true
            elseif filter == "all" then keep = true
            elseif filter == "freeze" then keep = action == "freeze" or action == "unfreeze"
            else keep = action == filter end
            local target = e.target or e.field or "-"
            local delta = tonumber(e.delta)
            local change, changeToken
            if action == "config" then
                change = configValueText(e.before) .. " > " .. configValueText(e.after)
                changeToken = "text"
            elseif delta then
                change = signedText(delta)
                changeToken = delta >= 0 and "positive" or "negative"
            else
                change = "-"
                changeToken = "textFaint"
            end
            local reason = tostring(e.reason or "-")
            local txId = tostring(e.txId or "-")
            local admin = tostring(e.admin or "-")
            if keep and q then
                local hay = string.lower(admin .. " " .. action .. " " .. auditActionText(action) .. " " .. tostring(target) .. " " .. reason .. " " .. txId)
                keep = string.find(hay, q, 1, true) ~= nil
            end
            if keep then
                rows[#rows + 1] = {
                    cells = {
                        stampText(e.ts, self.offsetMin), admin, auditActionText(action), tostring(target),
                        e.currency and currencyName(e.currency) or "-", change, reason, txId,
                    },
                    tokens = { "textMuted", "text", "text", "text", "textMuted", changeToken, "textMuted", "textFaint" },
                    muted = e.rolledBack == true,
                }
            end
        end
    end
    self.auditRows = rows
    self.auditTotal = #src
    self.auditList:setItems(rows)
end

-- Rejection counters arrive as a map; the drawn order has to be stable, so the rows are built
-- and sorted when the reply lands, never per frame.
function Admin:rebuildSources()
    for _, s in ipairs(self.sources or {}) do
        local rows = {}
        local rejected = type(s.today) == "table" and s.today.rejected or nil
        if type(rejected) == "table" then
            for code, n in pairs(rejected) do
                if (tonumber(n) or 0) > 0 then rows[#rows + 1] = { code = tostring(code), n = tonumber(n) or 0 } end
            end
            EC.sortSafe(rows, function(a, b) return a.code < b.code end)
        end
        s.rejectedRows = rows
    end
end

-- One row of the settings page: the option's state (value / default / override / locked) turned
-- into fitted strings, control hit boxes and y positions. The list width is known here, so the
-- cell never measures anything -- and the click test reads the very numbers the paint used.
function Admin:optionRow(spec, name, desc, snap, searching, width, lh, chipH, valueY)
    local state = snap[spec.key]
    local value = state and state.value
    local locked = spec.locked == true or (state ~= nil and state.locked == true)
    local override = state ~= nil and state.override == true and not locked
    local item = {
        key = spec.key, spec = spec, plainName = name, missing = state == nil,
        locked = locked, override = override, hits = {},
        chipH = chipH, line1Y = 5, line2Y = 5 + lh, valueY = valueY,
    }
    local ctrlX = math.max(80, width - PAD - OPTION_CTRL_W)
    local right = width - PAD
    local valueRaw = nil
    -- the reset chip is pinned to the right edge, so the value column stays where it is
    if override then
        local label = tr("Admin_Set_Reset")
        local bw = textWidth(label) + 16
        right = right - bw
        item.hits[#item.hits + 1] = { id = "reset", x = right, w = bw, label = label }
        right = right - 4
    end
    if locked then
        valueRaw = optionValueText(spec, value)
        item.valueX, item.valueW = ctrlX, math.max(10, right - ctrlX)
        item.valueY = item.line1Y
        item.lockedText = fitText(tr("Admin_Set_Locked"), math.max(0, width - PAD - ctrlX))
    elseif spec.kind == "bool" then
        item.toggle = { x = ctrlX, w = OPTION_TOGGLE_W }
        item.toggleOn = value == true
        item.toggleLabel = tr(item.toggleOn and "Admin_On" or "Admin_Off")
        item.hits[#item.hits + 1] = { id = "toggle", x = ctrlX, w = OPTION_TOGGLE_W }
    else
        local label = tr("Admin_Set_Edit")
        local bw = textWidth(label) + 16
        right = right - bw
        item.hits[#item.hits + 1] = { id = "edit", x = right, w = bw, label = label }
        right = right - 4
        item.editable = true
        if spec.kind == "int" or spec.kind == "number" then
            item.hits[#item.hits + 1] = { id = "minus", x = ctrlX, w = OPTION_STEP_W, label = "-" }
            item.hits[#item.hits + 1] = { id = "plus", x = right - OPTION_STEP_W, w = OPTION_STEP_W, label = "+" }
            item.valueX = ctrlX + OPTION_STEP_W + 4
            item.valueW = math.max(10, right - OPTION_STEP_W - 8 - item.valueX)
            item.valueCentre = true
        else
            item.valueX = ctrlX
            item.valueW = math.max(10, right - ctrlX)
        end
        valueRaw = optionValueText(spec, value)
    end
    if valueRaw then item.valueText = fitText(valueRaw, item.valueW) end

    -- left column: [group] name over [overridden (default X)] description [runtime hint]
    local leftW = math.max(0, ctrlX - PAD * 2)
    item.nameX = PAD
    if searching then
        item.prefixText = fitText(tr("Admin_Set_Group_" .. spec.group), math.floor(leftW * 0.35))
        item.nameX = PAD + textWidth(item.prefixText) + 6
    end
    item.nameText = fitText(name, math.max(0, ctrlX - PAD - item.nameX))
    item.descX = PAD
    if override then
        item.overText = fitText(getText(T .. "Admin_Set_Overridden", optionValueText(spec, state.default)), math.floor(leftW * 0.5))
        item.descX = PAD + textWidth(item.overText) + 6
    end
    if spec.page then item.runtimeText = getText(T .. "Admin_Set_Runtime", tr("Admin_Tab_" .. spec.page)) end
    local runW = item.runtimeText and (textWidth(item.runtimeText) + 8) or 0
    item.descText = fitText(desc, math.max(0, ctrlX - PAD - item.descX - runW))
    if item.runtimeText then
        item.runtimeX = item.descX + textWidth(item.descText) + 8
        item.runtimeText = fitText(item.runtimeText, math.max(0, ctrlX - PAD - item.runtimeX))
    end
    return item
end

-- The selected group's options, or -- while the search box holds text -- every option whose
-- name, description or key contains it, across groups. Built when a snapshot lands, when the
-- search text or the group changes and when the geometry changes; never per frame.
function Admin:rebuildSettings()
    local rows = {}
    local snap = self.options
    if snap then
        local query = self.setQuery
        local list = self.settingsList
        local width = math.max(120, list.width - 12)   -- 12 = the scrollbar gutter
        local lh = lineH()
        local chipH = math.max(20, fontH.small + 6)
        local valueY = math.floor((list.rowHeight - fontH.small) / 2)
        for _, spec in ipairs(EC.OPTIONS) do
            local name = getTextOrNull("Sandbox_MinidoracatEconomy_" .. spec.key) or spec.key
            local desc = getTextOrNull("Sandbox_MinidoracatEconomy_" .. spec.key .. "_tooltip") or ""
            local take
            if query then
                take = string.find(string.lower(name), query, 1, true) ~= nil
                    or string.find(string.lower(desc), query, 1, true) ~= nil
                    or string.find(string.lower(spec.key), query, 1, true) ~= nil
            else
                take = spec.group == self.setGroup
            end
            if take then
                rows[#rows + 1] = self:optionRow(spec, name, desc, snap, query ~= nil, width, lh, chipH, valueY)
            end
        end
    end
    self.settingRows = rows
    self.settingsList:setItems(rows)
end

-- Geometry of a catalog row's control strip: identical for every row, so it is computed once per
-- rebuild and the rows only carry their own strings. The strip is as wide as its content (labels
-- in the player's font, two steppers, a value that fits "1,000,000", the edit chip) instead of a
-- fixed number: a fixed 300 px lost the price digits at large UI fonts.
function Admin:catalogGeometry(width, chipH)
    local labelW = math.max(textWidth(tr("Admin_Shop_Enabled")), textWidth(tr("Admin_Shop_Price")), textWidth(tr("Admin_Shop_Cap")))
    local editLabel = tr("Admin_Set_Edit")
    local geo = {
        chipH = chipH, chipTextY = math.floor((chipH - fontH.small) / 2), labelW = labelW,
        editLabel = editLabel, editW = textWidth(editLabel) + 16,
    }
    geo.valueW = math.max(CATALOG_VALUE_MIN_W, textWidth("1,000,000") + 8)
    geo.leftW = labelW + 4 + CATALOG_TOGGLE_W
    local stripW = geo.leftW + 8 + labelW + 6 + CATALOG_STEP_W + 4 + geo.valueW + 4 + CATALOG_STEP_W + 4 + geo.editW
    geo.ctrlX = math.max(70, width - PAD - stripW)
    geo.toggleX = geo.ctrlX + labelW + 4
    geo.labelX = geo.ctrlX + geo.leftW + 8
    geo.editX = width - PAD - geo.editW
    geo.plusX = geo.editX - 4 - CATALOG_STEP_W
    geo.valueX = geo.plusX - 4 - geo.valueW
    geo.minusX = geo.valueX - 4 - CATALOG_STEP_W
    return geo
end

-- One catalog row: icon plus item name (and its untranslated name) over "id / category /
-- per-unit count" on the left, the listed toggle and the price steppers on the right's first
-- line, the daily cap steppers on its second.
function Admin:catalogRow(sku, geo, lh, rowHeight, y1, y2)
    local name = itemName(sku.item)
    local size = math.min(math.max(12, rowHeight - 10), 28)
    local item = {
        id = sku.id, sku = sku, plainName = name, hits = {},
        line1Y = 5, line2Y = 5 + lh, chipTextY = geo.chipTextY,
        textY1 = y1 + geo.chipTextY, textY2 = y2 + geo.chipTextY,
        icon = itemTexture(sku.item), iconSize = size, iconY = math.floor((rowHeight - size) / 2),
        toggleOn = sku.enabled ~= false,
        toggle = { x = geo.toggleX, y = y1, w = CATALOG_TOGGLE_W, h = geo.chipH },
        valueX = geo.valueX, valueW = geo.valueW,
        labelLeftX = geo.ctrlX, labelX = geo.labelX,
        enabledLabel = fitText(tr("Admin_Shop_Enabled"), geo.labelW),
        priceLabel = fitText(tr("Admin_Shop_Price"), geo.labelW),
        capLabel = fitText(tr("Admin_Shop_Cap"), geo.labelW),
        priceText = fitText(amountText(sku.price), geo.valueW),
        capText = fitText(capValueText(sku.dailyCap), geo.valueW),
    }
    item.toggleLabel = tr(item.toggleOn and "Admin_On" or "Admin_Off")
    item.hits[#item.hits + 1] = { id = "toggle", x = geo.toggleX, y = y1, w = CATALOG_TOGGLE_W, h = geo.chipH }
    item.hits[#item.hits + 1] = { id = "priceMinus", x = geo.minusX, y = y1, w = CATALOG_STEP_W, h = geo.chipH, label = "-" }
    item.hits[#item.hits + 1] = { id = "pricePlus", x = geo.plusX, y = y1, w = CATALOG_STEP_W, h = geo.chipH, label = "+" }
    item.hits[#item.hits + 1] = { id = "priceEdit", x = geo.editX, y = y1, w = geo.editW, h = geo.chipH, label = geo.editLabel }
    item.hits[#item.hits + 1] = { id = "capMinus", x = geo.minusX, y = y2, w = CATALOG_STEP_W, h = geo.chipH, label = "-" }
    item.hits[#item.hits + 1] = { id = "capPlus", x = geo.plusX, y = y2, w = CATALOG_STEP_W, h = geo.chipH, label = "+" }
    item.hits[#item.hits + 1] = { id = "capEdit", x = geo.editX, y = y2, w = geo.editW, h = geo.chipH, label = geo.editLabel }

    item.nameX = PAD + size + 6
    local textW = math.max(0, geo.ctrlX - PAD - item.nameX)
    item.nameText = fitText(name, textW)
    local alt = itemBaseName(sku.item)
    if alt then
        item.altX = item.nameX + textWidth(item.nameText) + 8
        local altW = geo.ctrlX - PAD - item.altX
        if altW > 20 then item.altText = fitText(alt, altW) end
    end
    item.metaX = item.nameX   -- under the name, clear of the icon
    local meta = tostring(sku.id) .. " / " .. categoryText(sku.category) .. " / "
        .. getText(T .. "Shop_QtyPer", tostring(math.floor(tonumber(sku.qty) or 1)))
    item.metaText = fitText(meta, textW)
    return item
end

-- The catalog the server last sent, turned into rows (disabled SKUs included: the admin page is
-- where they are put back on the shelf). Built when a reply lands and when the geometry changes.
function Admin:rebuildCatalog()
    local rows = {}
    local snap = self.catalog
    if snap and type(snap.items) == "table" then
        local list = self.catalogList
        local width = math.max(120, list.width - 12)   -- 12 = the scrollbar gutter
        local chipH = math.max(20, fontH.small + 6)
        local y1 = 3
        local y2 = math.max(y1 + chipH + 1, list.rowHeight - chipH - 3)
        local geo = self:catalogGeometry(width, chipH)
        for _, sku in ipairs(snap.items) do
            rows[#rows + 1] = self:catalogRow(sku, geo, lineH(), list.rowHeight, y1, y2)
        end
    end
    self.catalogRows = rows
    self.catalogList:setItems(rows)
end

-- Geometry of a listing row's right-hand strip: identical for every row, so it is computed once
-- per rebuild and the rows only carry their own strings. The strip is as wide as its content (a
-- price that fits "1,000,000" plus the delist chip) instead of a fixed number, so a large UI
-- font cannot push the digits out of the row.
function Admin:listingGeometry(width, chipH)
    local label = tr("Admin_Lst_Delist")
    local geo = { chipH = chipH, chipTextY = math.floor((chipH - fontH.small) / 2), delistLabel = label }
    geo.delistW = textWidth(label) + 16
    geo.priceW = math.max(60, textWidth("1,000,000") + 8)
    geo.delistX = math.max(40, width - PAD - geo.delistW)
    geo.priceRight = geo.delistX - 8
    geo.textLimit = math.max(0, geo.priceRight - geo.priceW - PAD)
    return geo
end

-- One listing row: icon plus the localised item name (and its untranslated name) over
-- "seller / category / expiry", the price and the delist chip on the right.
function Admin:listingRow(l, geo, lh, rowHeight, chipY)
    local name = itemName(l.item)
    local size = math.min(math.max(12, rowHeight - 10), 28)
    local item = {
        id = l.id, seller = tostring(l.seller or "-"), plainName = name,
        line1Y = 5, line2Y = 5 + lh, chipTextY = geo.chipTextY,
        icon = itemTexture(l.item), iconSize = size, iconY = math.floor((rowHeight - size) / 2),
        priceRight = geo.priceRight, priceText = fitText(amountText(l.price), geo.priceW),
        delistLabel = geo.delistLabel,
        delist = { x = geo.delistX, y = chipY, w = geo.delistW, h = geo.chipH },
    }
    item.nameX = PAD + size + 6
    local textW = math.max(0, geo.textLimit - item.nameX)
    item.nameText = fitText(name, textW)
    local alt = itemBaseName(l.item)
    if alt then
        item.altX = item.nameX + textWidth(item.nameText) + 8
        local altW = geo.textLimit - item.altX
        if altW > 20 then item.altText = fitText(alt, altW) end
    end
    item.metaText = fitText(item.seller .. " / " .. categoryText(l.category) .. " / "
        .. tr("Market_Col_Expires") .. " " .. stampText(l.expiresAt, self.offsetMin), textW)
    return item
end

-- The page the server last sent, turned into rows. Built when a reply lands and when the
-- geometry changes; never per frame.
function Admin:rebuildListings()
    local rows = {}
    local snap = self.listings
    if snap and type(snap.items) == "table" then
        local list = self.listingsList
        local width = math.max(120, list.width - 12)   -- 12 = the scrollbar gutter
        local chipH = math.max(20, fontH.small + 6)
        local geo = self:listingGeometry(width, chipH)
        local chipY = math.max(3, math.floor((list.rowHeight - chipH) / 2))
        for _, l in ipairs(snap.items) do
            rows[#rows + 1] = self:listingRow(l, geo, lineH(), list.rowHeight, chipY)
        end
    end
    self.listingRows = rows
    self.listingsList:setItems(rows)
end

-- Geometry of a whitelist row's chip strip: identical for every row, so it is computed once per
-- rebuild. The category chip is as wide as the longer of the two labels, so the text budget does
-- not move when it flips; the item chips sit side by side against the same right edge.
function Admin:whitelistGeometry(width, chipH)
    local allow, deny = tr("Admin_Wl_Allow"), tr("Admin_Wl_Deny")
    local geo = { chipH = chipH, chipTextY = math.floor((chipH - fontH.small) / 2),
        allowLabel = allow, denyLabel = deny }
    geo.allowW = textWidth(allow) + 16
    geo.denyW = textWidth(deny) + 16
    geo.catW = math.max(geo.allowW, geo.denyW)
    geo.catX = math.max(40, width - PAD - geo.catW)
    geo.denyX = math.max(40, width - PAD - geo.denyW)
    geo.allowX = math.max(20, geo.denyX - 6 - geo.allowW)
    geo.textLimit = math.max(0, math.min(geo.catX, geo.allowX) - PAD)
    return geo
end

function Admin:whitelistCategoryRow(cat, label, count, allowed, geo, lh, chipY)
    local item = {
        kind = "category", cat = cat, allowed = allowed, hits = {},
        line1Y = 5, line2Y = 5 + lh, chipTextY = geo.chipTextY, metaX = PAD,
        labelText = tr("Admin_Wl_Category"),
    }
    item.nameX = PAD + textWidth(item.labelText) + 6
    item.nameText = fitText(label, math.max(0, geo.textLimit - item.nameX))
    -- a category the file names but this server has no item in still gets a row, so a stale
    -- line can be switched off from here
    local meta = count > 0 and getText(T .. "Admin_Wl_Items", tostring(count)) or tr("Admin_Wl_Unknown")
    if label ~= cat then meta = cat .. " / " .. meta end
    item.metaText = fitText(meta, math.max(0, geo.textLimit - PAD))
    item.hits[1] = { id = "category", x = geo.catX, y = chipY, w = geo.catW, h = geo.chipH,
        label = allowed and geo.allowLabel or geo.denyLabel, active = allowed }
    return item
end

function Admin:whitelistItemRow(entry, allow, deny, geo, lh, rowHeight, chipY)
    local size = math.min(math.max(12, rowHeight - 10), 28)
    local item = {
        kind = "item", fullType = entry.fullType, hits = {},
        line1Y = 5, line2Y = 5 + lh, chipTextY = geo.chipTextY,
        icon = itemTexture(entry.fullType), iconSize = size, iconY = math.floor((rowHeight - size) / 2),
    }
    item.nameX = PAD + size + 6
    item.metaX = item.nameX   -- under the name, clear of the icon
    local textW = math.max(0, geo.textLimit - item.nameX)
    item.nameText = fitText(entry.name, textW)
    local alt = itemBaseName(entry.fullType)
    if alt then
        item.altX = item.nameX + textWidth(item.nameText) + 8
        local altW = geo.textLimit - item.altX
        if altW > 20 then item.altText = fitText(alt, altW) end
    end
    local meta = entry.fullType
    if entry.cat then meta = meta .. " / " .. itemCategoryName(entry.cat) end
    if not allow and not deny then meta = meta .. " / " .. tr("Admin_Wl_ByCategory") end
    item.metaText = fitText(meta, textW)
    item.hits[1] = { id = "allow", x = geo.allowX, y = chipY, w = geo.allowW, h = geo.chipH,
        label = geo.allowLabel, active = allow }
    item.hits[2] = { id = "exclude", x = geo.denyX, y = chipY, w = geo.denyW, h = geo.chipH,
        label = geo.denyLabel, active = deny }
    return item
end

-- The file the server last sent, turned into rows: every category this server has items in (plus
-- the ones only the file names), then the items the file singles out -- or, while the search box
-- has text, whatever the whole item universe matches. Built when a reply lands, when the search
-- text changes and when the geometry changes; never per frame.
function Admin:rebuildWhitelist()
    local rows = {}
    local cats, items = 0, 0
    local wl = self.whitelist
    if wl then
        local list = self.whitelistList
        local width = math.max(120, list.width - 12)   -- 12 = the scrollbar gutter
        local chipH = math.max(20, fontH.small + 6)
        local geo = self:whitelistGeometry(width, chipH)
        local chipY = math.max(3, math.floor((list.rowHeight - chipH) / 2))
        local lh = lineH()
        local query = self.wlQuery
        local allowed = wlSet(wl.categories)
        local allowTypes = wlSet(wl.types)
        local denyTypes = wlSet(wl.excludeTypes)
        local uni = self:whitelistUniverse()

        local counts = {}
        for cat, n in pairs(uni.cats) do counts[cat] = n end
        for cat in pairs(allowed) do
            if counts[cat] == nil then counts[cat] = 0 end
        end
        local catRows = {}
        for cat, n in pairs(counts) do
            local label = itemCategoryName(cat)
            if query == nil or string.find(string.lower(label), query, 1, true) ~= nil
                or string.find(string.lower(cat), query, 1, true) ~= nil then
                catRows[#catRows + 1] = { cat = cat, label = label, count = n }
            end
        end
        EC.sortSafe(catRows, function(a, b) return a.label < b.label end)

        local itemRows, seen = {}, {}
        if query ~= nil then
            for _, entry in ipairs(uni.items) do
                if #itemRows >= WL_ITEM_MAX then break end
                if string.find(entry.key, query, 1, true) ~= nil and not seen[entry.fullType] then
                    seen[entry.fullType] = true
                    itemRows[#itemRows + 1] = entry
                end
            end
        end
        -- the items the file singles out are always reachable, even when this server has no
        -- script for them any more
        for _, set in ipairs({ allowTypes, denyTypes }) do
            for fullType in pairs(set) do
                local entry = uni.byType[fullType]
                if entry == nil then
                    local name = itemName(fullType)
                    entry = { fullType = fullType, name = name,
                        key = string.lower(name .. " " .. fullType) }
                end
                if not seen[entry.fullType]
                    and (query == nil or string.find(entry.key, query, 1, true) ~= nil) then
                    seen[entry.fullType] = true
                    itemRows[#itemRows + 1] = entry
                end
            end
        end
        EC.sortSafe(itemRows, function(a, b) return a.name < b.name end)

        for _, c in ipairs(catRows) do
            rows[#rows + 1] = self:whitelistCategoryRow(c.cat, c.label, c.count, allowed[c.cat] == true, geo, lh, chipY)
        end
        for _, entry in ipairs(itemRows) do
            rows[#rows + 1] = self:whitelistItemRow(entry, allowTypes[entry.fullType] == true,
                denyTypes[entry.fullType] == true, geo, lh, list.rowHeight, chipY)
        end
        cats, items = #catRows, #itemRows
    end
    self.wlRows = rows
    self.wlShown = { cats = cats, items = items }
    self.whitelistList:setItems(rows)
end

-- ----- enable state (permission, in-flight command, data presence) -----

-- Local role read (getAccessLevel + sandbox lists) AND, once a reply has told us, the level the
-- server actually enforced. Either side saying no means no.
function Admin:writeAllowed()
    if not P.canWrite() then return false end
    return not (self.serverPerms and self.serverPerms.write == false)
end

function Admin:readAllowed()
    if not P.canRead() then return false end
    return not (self.serverPerms and self.serverPerms.read == false)
end

function Admin:updateEnabled()
    local write = self:writeAllowed()
    local read = write or self:readAllowed()
    local modal = self.dialog ~= nil
    local me = getPlayer() and getPlayer():getUsername() or nil
    local found = self.lookup ~= nil and self.lookup.found == true
    local selfTarget = me ~= nil and self.lookupUser == me

    setEntryEditable(self.userEntry, read and not modal)
    self.lookupButton:setEnable(read and not modal and not isPending("admin.lookup"))
    self.refreshButton:setEnable(read and not modal)

    local canWriteTarget = write and found and not selfTarget and not modal
    self.adjustButton:setEnable(canWriteTarget and not isPending("admin.adjust"))
    self.freezeButton:setEnable(canWriteTarget and not isPending("admin.freeze"))
    self:setButtonTitle(self.freezeButton, self.lookup and self.lookup.frozen and tr("Admin_Player_Unfreeze") or tr("Admin_Player_Freeze"))

    local def = currencyDef(self:selectedCurrency())
    local cfgWrite = write and not modal and not isPending("admin.config")
    self.renameButton:setEnable(cfgWrite)
    self.toggleButton:setEnable(cfgWrite)
    self:setButtonTitle(self.toggleButton, (def == nil or def.enabled ~= false) and tr("Admin_Cur_Disable") or tr("Admin_Cur_Enable"))
    self.rateButton:setEnable(cfgWrite and def ~= nil and type(def.exchange) == "table")
    self.balanceMaxButton:setEnable(cfgWrite)
    self.iconsButton:setEnable(write and not modal and not isPending("admin.icons") and self.iconsRecheckAt == nil)

    local src = self:selectedSource()
    local srcWrite = write and not modal and not isPending("admin.sources") and src ~= nil
    self.srcCapsButton:setEnable(srcWrite)
    self.srcToggleButton:setEnable(srcWrite)
    self:setButtonTitle(self.srcToggleButton, (src == nil or src.enabled ~= false) and tr("Admin_Src_Disable") or tr("Admin_Src_Enable"))

    setEntryEditable(self.auditEntry, read and not modal)
    for _, b in ipairs(self.auditFilterButtons) do b:setEnable(read and not modal) end
    for _, b in ipairs(self.copyButtons) do
        local paths = self.system and self.system.paths
        b:setEnable(not modal and paths ~= nil and type(paths[b.internal]) == "string")
    end

    -- shop page: one in-flight catalog write at a time, the reload chip included
    local catWrite = write and not modal and not isPending("admin.catalog")
    self.catalogList.optionsDisabled = not catWrite
    self.shopReloadButton:setEnable(catWrite)

    -- listings page: one in-flight listings command at a time; the page chips follow the
    -- snapshot, and a read-only role browses without ever arming a delist
    local lstWrite = write and not modal and not isPending("admin.listings")
    self.listingsList.optionsDisabled = not lstWrite
    setEntryEditable(self.lstEntry, read and not modal)
    local lstPage, lstPages = 1, 1
    if self.listings then
        lstPage = math.max(1, math.floor(tonumber(self.listings.page) or 1))
        lstPages = math.max(1, math.floor(tonumber(self.listings.pages) or 1))
    end
    local lstRead = read and not modal and not isPending("admin.listings")
    self.lstPrevButton:setEnable(lstRead and lstPage > 1)
    self.lstNextButton:setEnable(lstRead and lstPage < lstPages)

    -- whitelist page: one in-flight whitelist command at a time, the reload chip included; a
    -- read-only role browses the file without ever arming a switch
    local wlWrite = write and not modal and not isPending("admin.whitelist")
    self.whitelistList.optionsDisabled = not wlWrite
    self.wlReloadButton:setEnable(wlWrite)
    setEntryEditable(self.wlEntry, read and not modal)

    -- settings page: one in-flight option write at a time; a read-only role sees every control
    -- greyed out instead of a page that pretends to be editable
    local optWrite = write and not modal and not isPending("admin.option")
    self.settingsList.optionsDisabled = not optWrite
    setEntryEditable(self.setEntry, read and not modal)
    local _, overrides = self:optionGroupCount(self.setGroup)
    self.setResetButton:setEnable(optWrite and overrides > 0)
    if self.dialog then
        local ok = write and not (isPending("admin.adjust") or isPending("admin.freeze") or isPending("admin.config") or isPending("admin.sources") or isPending("admin.option") or isPending("admin.catalog") or isPending("admin.listings"))
        self.dialog.confirmButton:setEnable(ok)
    end
end

-- ----- geometry -----

function Admin:layout()
    local w, h = self.width, self.height
    local sub = math.max(24, fontH.small + 12)
    local lh = lineH()
    local g = {}
    g.subH = sub
    g.footerH = lh + 2
    g.bodyY = sub + PAD
    g.bodyH = math.max(60, h - g.bodyY - g.footerH)
    g.footerY = h - g.footerH
    self.g = g

    -- Button rows are budgeted, never natural width: a long translation (or a large UI font)
    -- must truncate its own label instead of pushing a button out of the panel.
    local refreshW = math.min(textWidth(self.refreshButton.fullTitle) + 24, math.floor(w * 0.25))
    local tabsBudget = math.max(120, w - refreshW - PAD)
    local natural = 0
    for _, b in ipairs(self.subTabButtons) do natural = natural + textWidth(b.fullTitle) + 28 end
    local scale = natural > tabsBudget and (tabsBudget / natural) or 1
    local x = 0
    for i, b in ipairs(self.subTabButtons) do
        local bw = math.floor((textWidth(b.fullTitle) + 28) * scale)
        if i == #self.subTabButtons then bw = math.min(bw, tabsBudget - x) end
        b:setWidth(math.max(24, bw))
        b:setHeight(sub)
        b:setX(x); b:setY(0)
        self:setButtonTitle(b, b.fullTitle)
        x = x + b.width
    end
    self.refreshButton:setWidth(refreshW)
    self.refreshButton:setHeight(math.max(20, fontH.small + 6))
    self.refreshButton:setX(math.max(x + PAD, w - refreshW))
    self.refreshButton:setY(math.floor((sub - self.refreshButton.height) / 2))
    self:setButtonTitle(self.refreshButton, self.refreshButton.fullTitle)

    -- permission is re-read here (layout runs on size / tab / permission changes, never per frame)
    local read = self:readAllowed()
    self.hadWrite = self:writeAllowed()
    self.hadRead = read
    local player = read and self.tab == "Player"
    local currencies = read and self.tab == "Currencies"
    local audit = read and self.tab == "Audit"
    local system = read and self.tab == "System"
    local sources = read and self.tab == "Sources"
    local settings = read and self.tab == "Settings"
    local shop = read and self.tab == "Shop"
    local listings = read and self.tab == "Listings"
    local whitelist = read and self.tab == "Whitelist"
    for _, b in ipairs(self.subTabButtons) do b:setVisible(read) end
    self.refreshButton:setVisible(read)

    -- player page
    local eh = entryH()
    g.queryY = g.bodyY
    self.userEntry:setVisible(player)
    self.userEntry:setX(0); self.userEntry:setY(g.queryY)
    self.userEntry:setWidth(math.min(200, math.floor(w * 0.25))); self.userEntry:setHeight(eh)
    self.lookupButton:setVisible(player)
    self.lookupButton:setWidth(math.min(textWidth(self.lookupButton.fullTitle) + 26, math.floor(w * 0.2)))
    self.lookupButton:setHeight(eh)
    self.lookupButton:setX(self.userEntry.width + 6); self.lookupButton:setY(g.queryY)
    self:setButtonTitle(self.lookupButton, self.lookupButton.fullTitle)
    g.statusX = self.lookupButton.x + self.lookupButton.width + PAD
    -- the candidate dropdown hangs directly below the search box, never over it
    g.suggestY = g.queryY + eh
    g.suggestW = math.min(w, math.max(PLAYERS_MIN_W, self.userEntry.width))

    local actionH = btnH()
    g.cardsY = g.queryY + eh + 6
    g.actionY = g.bodyY + g.bodyH - actionH
    g.cardsH = math.max(60, g.actionY - 6 - g.cardsY)
    g.leftW = math.max(150, math.floor((w - PAD * 2) * 0.24))
    g.midW = math.max(150, math.floor((w - PAD * 2) * 0.26))
    g.midX = g.leftW + PAD
    g.rightX = g.midX + g.midW + PAD
    g.rightW = math.max(180, w - g.rightX)

    -- action row: adjust takes at most a third, freeze is sized for the longer of its two labels
    self.adjustButton:setVisible(player)
    self.adjustButton:setHeight(actionH)
    self.adjustButton:setWidth(math.min(math.max(140, textWidth(self.adjustButton.fullTitle, UIFont.Medium) + 40), math.floor(w * 0.34)))
    self.adjustButton:setX(0); self.adjustButton:setY(g.actionY)
    self:setButtonTitle(self.adjustButton, self.adjustButton.fullTitle, UIFont.Medium)
    self.freezeButton:setVisible(player)
    self.freezeButton:setHeight(actionH)
    local freezeW = math.max(textWidth(tr("Admin_Player_Unfreeze")), textWidth(tr("Admin_Player_Freeze"))) + 30
    self.freezeButton:setWidth(math.min(math.max(120, freezeW), math.floor(w * 0.3)))
    self.freezeButton:setX(self.adjustButton.width + 6); self.freezeButton:setY(g.actionY)
    self:setButtonTitle(self.freezeButton, self.freezeButton.fullTitle)
    g.actionNoteX = self.freezeButton.x + self.freezeButton.width + PAD

    -- receipts table inside the right card
    local rh = rowH()
    g.receiptHeaderY = g.cardsY + CARD_TITLE_H + lh
    local listY = g.receiptHeaderY + rh
    local listW = math.max(120, g.rightW - 2)
    local listH = math.max(rh, g.cardsY + g.cardsH - listY - 2)
    self.receiptList:setVisible(player)
    self.receiptList:setX(g.rightX + 1); self.receiptList:setY(listY)
    if self.receiptList.width ~= listW or self.receiptList.height ~= listH then
        self.receiptList:resize(listW, listH)
    end
    layoutColumns(self.receiptList, receiptSpec(), listW - 12)
    g.receiptBottom = listY + listH

    -- currencies page
    g.cfgTableW = math.max(240, math.floor((w - PAD) * 0.58))
    g.cfgDetailX = g.cfgTableW + PAD
    g.cfgDetailW = math.max(200, w - g.cfgDetailX)
    g.cfgRowY = g.bodyY + CARD_TITLE_H + rh
    local cfgBtnY = g.bodyY + g.bodyH - actionH
    g.cfgButtonY = cfgBtnY
    -- five config buttons share the detail column. Fair share with redistribution: buttons whose
    -- natural width is below their share keep it, and what they leave over goes to the wider ones
    -- (an equal fifth would truncate the longest label at the minimum window with large fonts).
    local toggleFull = math.max(textWidth(tr("Admin_Cur_Disable")), textWidth(tr("Admin_Cur_Enable"))) + 30
    local cfgItems = { { self.renameButton, textWidth(self.renameButton.fullTitle) + 30 },
        { self.toggleButton, toggleFull }, { self.rateButton, textWidth(self.rateButton.fullTitle) + 30 },
        { self.balanceMaxButton, textWidth(self.balanceMaxButton.fullTitle) + 30 },
        { self.iconsButton, textWidth(self.iconsButton.fullTitle) + 30 } }
    local byNeed = { cfgItems[1], cfgItems[2], cfgItems[3], cfgItems[4], cfgItems[5] }
    EC.sortSafe(byNeed, function(a, b) return a[2] < b[2] end)
    local remaining = g.cfgDetailW - 6 * (#cfgItems - 1)
    local cfgWidth = {}
    for i, item in ipairs(byNeed) do
        local share = math.floor(remaining / (#byNeed - i + 1))
        local bw = math.max(40, math.min(item[2], share))
        cfgWidth[item[1]] = bw
        remaining = remaining - bw
    end
    local cfgX = g.cfgDetailX
    for _, item in ipairs(cfgItems) do
        local b = item[1]
        b:setVisible(currencies)
        b:setHeight(actionH)
        b:setWidth(cfgWidth[b])
        b:setX(cfgX); b:setY(cfgBtnY)
        self:setButtonTitle(b, b.fullTitle)
        cfgX = cfgX + b.width + 6
    end

    -- sources page: table left, detail card plus two action buttons right (the currencies page
    -- shape, which a host already knows). Same fair share with redistribution for the buttons.
    g.srcTableW = math.max(240, math.floor((w - PAD) * 0.58))
    g.srcDetailX = g.srcTableW + PAD
    g.srcDetailW = math.max(200, w - g.srcDetailX)
    g.srcRowY = g.bodyY + CARD_TITLE_H + rh
    g.srcButtonY = g.bodyY + g.bodyH - actionH
    local srcToggleFull = math.max(textWidth(tr("Admin_Src_Disable")), textWidth(tr("Admin_Src_Enable"))) + 30
    local srcItems = { { self.srcCapsButton, textWidth(self.srcCapsButton.fullTitle) + 30 },
        { self.srcToggleButton, srcToggleFull } }
    local srcByNeed = { srcItems[1], srcItems[2] }
    EC.sortSafe(srcByNeed, function(a, b) return a[2] < b[2] end)
    local srcRemaining = g.srcDetailW - 6 * (#srcItems - 1)
    local srcWidth = {}
    for i, item in ipairs(srcByNeed) do
        local share = math.floor(srcRemaining / (#srcByNeed - i + 1))
        local bw = math.max(40, math.min(item[2], share))
        srcWidth[item[1]] = bw
        srcRemaining = srcRemaining - bw
    end
    local srcX = g.srcDetailX
    for _, item in ipairs(srcItems) do
        local b = item[1]
        b:setVisible(sources)
        b:setHeight(actionH)
        b:setWidth(srcWidth[b])
        b:setX(srcX); b:setY(g.srcButtonY)
        self:setButtonTitle(b, b.fullTitle)
        srcX = srcX + b.width + 6
    end

    -- audit page
    self.auditEntry:setVisible(audit)
    self.auditEntry:setX(0); self.auditEntry:setY(g.bodyY + CARD_TITLE_H + 2)
    self.auditEntry:setWidth(math.min(240, math.floor(w * 0.28))); self.auditEntry:setHeight(eh)
    local fx = self.auditEntry.width + PAD
    local filterSlot = math.floor((w - fx - PAD) / math.max(1, #self.auditFilterButtons)) - 4
    for _, b in ipairs(self.auditFilterButtons) do
        b:setVisible(audit)
        b:setWidth(math.max(30, math.min(textWidth(b.fullTitle) + 22, filterSlot)))
        b:setHeight(math.max(20, fontH.small + 6))
        b:setX(fx); b:setY(self.auditEntry.y + math.floor((eh - b.height) / 2))
        self:setButtonTitle(b, b.fullTitle)
        fx = fx + b.width + 4
    end
    g.auditCountX = fx + PAD
    g.auditHeaderY = self.auditEntry.y + eh + 6
    local auditListY = g.auditHeaderY + rh
    local auditW = math.max(200, w - 2)
    local auditH = math.max(rh, g.bodyY + g.bodyH - auditListY - lh - 4)
    self.auditList:setVisible(audit)
    self.auditList:setX(1); self.auditList:setY(auditListY)
    if self.auditList.width ~= auditW or self.auditList.height ~= auditH then
        self.auditList:resize(auditW, auditH)
    end
    layoutColumns(self.auditList, auditSpec(), auditW - 12)
    g.auditBottom = auditListY + auditH

    -- system page: state card left, paths card right. Each path is "label / value / copy": two
    -- lines when the card has the room, one line at the minimum window height with a large UI font
    -- (the rows must never run into the footer).
    g.sysLeftW = math.max(240, math.floor((w - PAD) * 0.5))
    g.sysRightX = g.sysLeftW + PAD
    g.sysRightW = math.max(220, w - g.sysRightX)
    local copyH = math.max(20, fontH.small + 6)
    local top = g.bodyY + CARD_TITLE_H + PAD
    local roomH = g.bodyY + g.bodyH - PAD - top
    g.sysStacked = #PATH_KEYS * (lh + copyH + 4) <= roomH
    g.sysLabelW = 0
    if not g.sysStacked then
        for _, key in ipairs(PATH_KEYS) do
            g.sysLabelW = math.max(g.sysLabelW, textWidth(tr("Admin_Sys_Path_" .. key)))
        end
        g.sysLabelW = math.min(g.sysLabelW, math.floor(g.sysRightW * 0.3))
    end
    local py = top
    for _, b in ipairs(self.copyButtons) do
        b:setVisible(system)
        b:setWidth(math.min(textWidth(b.fullTitle) + 20, math.max(30, g.sysRightW - PAD * 2)))
        b:setHeight(copyH)
        b:setX(g.sysRightX + g.sysRightW - PAD - b.width)
        b:setY(g.sysStacked and (py + lh) or py)
        py = py + copyH + 4 + (g.sysStacked and lh or 0)
    end
    g.sysPathY = top

    -- shop page: the file status row (status left, reload chip right) over the standing note,
    -- then the catalog list. Its rows are two lines tall, like the option rows.
    local shopTop = g.bodyY + CARD_TITLE_H + 4
    local reloadH = math.max(20, fontH.small + 6)
    local reloadW = math.min(textWidth(self.shopReloadButton.fullTitle) + 24, math.floor(w * 0.4))
    self.shopReloadButton:setVisible(shop)
    self.shopReloadButton:setWidth(reloadW)
    self.shopReloadButton:setHeight(reloadH)
    self.shopReloadButton:setX(math.max(PAD, w - PAD - reloadW))
    self.shopReloadButton:setY(shopTop)
    self:setButtonTitle(self.shopReloadButton, self.shopReloadButton.fullTitle)
    g.shopHeadY = shopTop + math.floor((reloadH - fontH.small) / 2)
    g.shopNoteY = shopTop + reloadH + 6
    local shopListY = g.shopNoteY + lh + 4
    local shopW = math.max(160, w - PAD * 2)
    local shopH = math.max(rowH(), g.bodyY + g.bodyH - PAD - shopListY)
    self.catalogList:setVisible(shop)
    self.catalogList:setX(PAD); self.catalogList:setY(shopListY)
    if self.catalogList.width ~= shopW or self.catalogList.height ~= shopH then
        self.catalogList:resize(shopW, shopH)
    end

    -- whitelist page: the file status row (status left, reload chip right), the two standing
    -- notes, the search row, then the list of category / item rows.
    local wlTop = g.bodyY + CARD_TITLE_H + 4
    local wlReloadW = math.min(textWidth(self.wlReloadButton.fullTitle) + 24, math.floor(w * 0.4))
    self.wlReloadButton:setVisible(whitelist)
    self.wlReloadButton:setWidth(wlReloadW)
    self.wlReloadButton:setHeight(reloadH)
    self.wlReloadButton:setX(math.max(PAD, w - PAD - wlReloadW))
    self.wlReloadButton:setY(wlTop)
    self:setButtonTitle(self.wlReloadButton, self.wlReloadButton.fullTitle)
    g.wlHeadY = wlTop + math.floor((reloadH - fontH.small) / 2)
    g.wlNoteY = wlTop + reloadH + 4
    g.wlFixedY = g.wlNoteY + lh
    local wlEntryY = g.wlFixedY + lh + 4
    self.wlEntry:setVisible(whitelist)
    self.wlEntry:setX(PAD); self.wlEntry:setY(wlEntryY)
    self.wlEntry:setWidth(math.max(120, math.min(280, math.floor(w * 0.32)))); self.wlEntry:setHeight(eh)
    g.wlSearchY = wlEntryY + math.floor((eh - fontH.small) / 2)
    local wlListY = wlEntryY + eh + 6
    local wlListW = math.max(160, w - PAD * 2)
    local wlListH = math.max(rowH(), g.bodyY + g.bodyH - PAD - wlListY)
    self.whitelistList:setVisible(whitelist)
    self.whitelistList:setX(PAD); self.whitelistList:setY(wlListY)
    if self.whitelistList.width ~= wlListW or self.whitelistList.height ~= wlListH then
        self.whitelistList:resize(wlListW, wlListH)
    end

    -- listings page: the listings card carries the search row, the list and the page chips along
    -- its bottom (the whitelist has its own page).
    g.lstY = g.bodyY
    g.lstH = math.max(CARD_TITLE_H + eh + rh, g.bodyY + g.bodyH - g.lstY)
    local lstTop = g.lstY + CARD_TITLE_H + 4
    self.lstEntry:setVisible(listings)
    self.lstEntry:setX(PAD); self.lstEntry:setY(lstTop)
    self.lstEntry:setWidth(math.max(120, math.min(240, math.floor(w * 0.28)))); self.lstEntry:setHeight(eh)
    g.lstNoteX = PAD + self.lstEntry.width + PAD
    g.lstHeadY = lstTop + math.floor((eh - fontH.small) / 2)
    local pageH = math.max(20, fontH.small + 6)
    local lstListY = lstTop + eh + 6
    g.lstPageY = math.max(lstListY + rh + 6, g.lstY + g.lstH - PAD - pageH)
    g.lstPageTextY = g.lstPageY + math.floor((pageH - fontH.small) / 2)
    local prevW = math.min(textWidth(self.lstPrevButton.fullTitle) + 24, math.floor(w * 0.2))
    local nextW = math.min(textWidth(self.lstNextButton.fullTitle) + 24, math.floor(w * 0.2))
    self.lstNextButton:setVisible(listings)
    self.lstNextButton:setWidth(nextW); self.lstNextButton:setHeight(pageH)
    self.lstNextButton:setX(math.max(PAD, w - PAD - nextW)); self.lstNextButton:setY(g.lstPageY)
    self:setButtonTitle(self.lstNextButton, self.lstNextButton.fullTitle)
    self.lstPrevButton:setVisible(listings)
    self.lstPrevButton:setWidth(prevW); self.lstPrevButton:setHeight(pageH)
    self.lstPrevButton:setX(math.max(PAD, self.lstNextButton.x - 6 - prevW)); self.lstPrevButton:setY(g.lstPageY)
    self:setButtonTitle(self.lstPrevButton, self.lstPrevButton.fullTitle)
    local lstW = math.max(160, w - PAD * 2)
    local lstListH = math.max(rh, g.lstPageY - 6 - lstListY)
    self.listingsList:setVisible(listings)
    self.listingsList:setX(PAD); self.listingsList:setY(lstListY)
    if self.listingsList.width ~= lstW or self.listingsList.height ~= lstListH then
        self.listingsList:resize(lstW, lstListH)
    end

    -- settings page: search row on top, the group nav down the left, the option list plus the
    -- "reset this group" button on the right. The reset row is reserved whether the button is
    -- shown or not, so typing in the search box never re-flows the list.
    local setTop = g.bodyY + CARD_TITLE_H + 4
    self.setEntry:setVisible(settings)
    self.setEntry:setX(PAD); self.setEntry:setY(setTop)
    self.setEntry:setWidth(math.max(120, math.min(260, math.floor(w * 0.3)))); self.setEntry:setHeight(eh)
    g.setCountX = PAD + self.setEntry.width + PAD
    g.setNavY = setTop + eh + 6
    g.setNavW = math.max(120, math.min(200, math.floor(w * 0.24)))
    g.setNavRowH = math.max(24, lh + 8)
    g.setNavH = math.max(g.setNavRowH, g.bodyY + g.bodyH - PAD - g.setNavY)
    g.setContentX = PAD + g.setNavW + PAD
    g.setContentW = math.max(160, w - g.setContentX - PAD)
    g.setHeadY = g.setNavY   -- the group heading; the standing note rides the search row instead
    local resetH = math.max(20, fontH.small + 6)
    g.setResetY = g.bodyY + g.bodyH - PAD - resetH
    local resetW = math.min(textWidth(self.setResetButton.fullTitle) + 24, g.setContentW)
    self.setResetButton:setVisible(settings and self.setQuery == nil)
    self.setResetButton:setWidth(resetW)
    self.setResetButton:setHeight(resetH)
    self.setResetButton:setX(g.setContentX + g.setContentW - resetW)
    self.setResetButton:setY(g.setResetY)
    self:setButtonTitle(self.setResetButton, self.setResetButton.fullTitle)
    local setListY = g.setHeadY + fontH.medium + 6
    local setW = math.max(120, g.setContentW)
    local setH = math.max(rowH(), g.setResetY - 6 - setListY)
    self.settingsList:setVisible(settings)
    self.settingsList:setX(g.setContentX); self.settingsList:setY(setListY)
    if self.settingsList.width ~= setW or self.settingsList.height ~= setH then
        self.settingsList:resize(setW, setH)
    end

    self:rebuildAudit()
    self:rebuildSettings()
    self:rebuildCatalog()
    self:rebuildListings()
    self:rebuildWhitelist()
    if self.lookup then self.receiptList:setItems(self.receiptRows or {}) end
    if self.dialog then self:layoutDialog() end
    self:layoutSuggest()
    self.layoutW, self.layoutH = w, h
    self:updateEnabled()
end

function Admin:resize(width, height)
    if self.width == width and self.height == height then return end
    self:setWidth(width)
    self:setHeight(height)
    self:layout()
end

-- ----- drawing -----

-- Vertical text cursor shared by the summary cards. State lives on the panel so the hot path
-- allocates nothing (the framework's per-frame-closure rule, V1.lua:138-139).
function Admin:beginLines(x, y, w, limit)
    self.lx, self.ly, self.lw, self.lLimit = x, y, w, limit
end

function Admin:line(str, token)
    local lh = lineH()
    if self.ly + lh > self.lLimit then return false end
    text(self, fitText(str, self.lw), self.lx, self.ly, token or "text")
    self.ly = self.ly + lh
    return true
end

-- label left, value right-aligned on the same line
function Admin:lineRow(label, value, token)
    local lh = lineH()
    if self.ly + lh > self.lLimit then return false end
    local valueText = tostring(value)
    local valueW = math.min(textWidth(valueText), math.floor(self.lw * 0.6))
    text(self, fitText(label, self.lw - valueW - PAD), self.lx, self.ly, "textMuted")
    textRight(self, fitText(valueText, valueW), self.lx + self.lw, self.ly, token or "text")
    self.ly = self.ly + lh
    return true
end

function Admin:lineGap(n)
    self.ly = self.ly + (n or 3)
end

function Admin:drawPlayer()
    local g = self.g
    local lh = lineH()
    local rh = rowH()
    local ty = g.queryY + math.floor((entryH() - fontH.small) / 2)
    if self.lookupError then
        text(self, fitText(errorText(self.lookupError), self.width - g.statusX), g.statusX, ty, "errorText")
    elseif self.lookup then
        local status = self.lookup.found and (self.lookup.online and tr("Admin_Player_Online") or tr("Admin_Player_Offline"))
            or tr("Admin_Player_NotFound")
        local label = tostring(self.lookupUser) .. "  " .. status
        if self.lookup.frozen then label = label .. "  " .. tr("Admin_Player_Frozen") end
        local stamp = getText(T .. "Admin_Updated", U.clockText(self.lookupAt or 0, self.offsetMin))
        local stampW = textWidth(stamp)
        text(self, fitText(label, self.width - g.statusX - stampW - PAD), g.statusX, ty, self.lookup.frozen and "warn" or "text")
        textRight(self, stamp, self.width, ty, "textFaint")
    elseif isPending("admin.lookup") then
        text(self, tr("Admin_Loading"), g.statusX, ty, "textMuted")
    end

    local bottom = g.cardsY + g.cardsH - 2
    local lookup = self.lookup

    -- account summary: available / reserved / wallet revision per currency
    card(self, 0, g.cardsY, g.leftW, g.cardsH, tr("Admin_Player_Summary"))
    local cy = g.cardsY + CARD_TITLE_H + 4
    local coin = math.max(24, fontH.medium + 8)
    for _, id in ipairs(currencyOrder(lookup)) do
        local blockH = rh + lh * 3 + 4
        if cy + blockH > bottom then break end
        local bal = lookup and lookup.balances and lookup.balances[id]
        fill(self, 4, cy, g.leftW - 8, blockH, "well")
        drawCoin(self, id, 8, cy + 3, coin)
        text(self, fitText(currencyName(id), g.leftW - 20 - coin, UIFont.Medium), 8 + coin + 6,
            cy + math.floor((rh - fontH.medium) / 2), "text", UIFont.Medium)
        self:beginLines(10, cy + rh, g.leftW - 20, cy + blockH)
        self:lineRow(tr("Wallet_Available"), amountText(bal and bal.available or 0), "accent")
        self:lineRow(tr("Wallet_Reserved"), amountText(bal and bal.reserved or 0))
        self:line(getText(T .. "Admin_Player_Rev", tostring(bal and bal.rev or 0)), "textFaint")
        cy = cy + blockH + 4
    end

    -- status, rewards and the daily adjustment budget
    card(self, g.midX, g.cardsY, g.midW, g.cardsH, tr("Admin_Player_Status"))
    self:beginLines(g.midX + PAD, g.cardsY + CARD_TITLE_H + 4, g.midW - PAD * 2, bottom)
    if not lookup then
        self:line(isPending("admin.lookup") and tr("Admin_Loading") or tr("Admin_Player_Hint"), "textMuted")
    else
        local rewards = lookup.rewards or {}
        if lookup.hoursSurvived ~= nil then
            self:line(getText(T .. "Admin_Player_Survived", string.format("%.1f", (tonumber(lookup.hoursSurvived) or 0) / 24)))
        else
            self:line(tr("Admin_Player_SurvivedOffline"), "textFaint")
        end
        self:lineRow(tr("Admin_Player_Checkin"), rewards.claimed and tr("Admin_Player_Claimed") or tr("Admin_Player_NotClaimed"),
            rewards.claimed and "positive" or "textMuted")
        self:line(getText(T .. "Admin_Player_Playtime", tostring(math.floor((tonumber(rewards.playedMs) or 0) / 60000))), "textMuted")
        if rewards.nextResetMs then
            self:line(getText(T .. "Admin_Player_NextReset", U.clockText(tonumber(rewards.nextResetMs) or 0, self.offsetMin)), "textFaint")
        end
        local done, total = 0, 0
        for _, m in ipairs(rewards.milestoneList or {}) do
            total = total + 1
            if hasBit(rewards.milestones, m.index) then done = done + 1 end
        end
        self:line(getText(T .. "Admin_Player_Milestones", tostring(done), tostring(total), tostring(rewards.season or "-")))
        self.frozenLink = nil
        if lookup.frozen then
            local info = lookup.frozenInfo or {}
            -- both lines are one click target: the audit page shows the full freeze reason
            local top = self.ly
            self:line(getText(T .. "Admin_Player_FrozenBy", tostring(info.by or "-"), stampText(info.ts, self.offsetMin)), "warn")
            if info.reason then self:line(getText(T .. "Admin_Player_FrozenReason", tostring(info.reason)), "warn") end
            self:line(tr("Admin_Player_FrozenLink"), "accent")
            self.frozenLink = { x = self.lx, y = top, w = self.lw, h = self.ly - top }
        end
        self:lineGap()
        self:line(tr("Admin_Player_MyDaily"), "textMuted")
        local today = lookup.adminToday or {}
        local perCurrency = type(today.currencies) == "table" and today.currencies or nil
        if perCurrency then
            for _, id in ipairs(currencyOrder(lookup)) do
                local t = perCurrency[id] or {}
                self:line(getText(T .. "Admin_Player_DailyRow", currencyName(id), amountText(t.add or 0), amountText(t.sub or 0)))
            end
        else
            self:line(getText(T .. "Admin_Player_DailyAll", amountText(today.add or 0), amountText(today.sub or 0)))
        end
        self:line(getText(T .. "Admin_Player_DailyCap", amountText(today.cap or 0)), "textFaint")
        local server = today.server or lookup.serverDaily
        if type(server) == "table" and server.cap ~= nil then
            self:line(getText(T .. "Admin_Player_ServerDaily", amountText(server.add or 0), amountText(server.sub or 0), amountText(server.cap)), "textFaint")
        end
        self:line(getText(T .. "Admin_Player_MaxPerTx", amountText(lookup.maxPerTx or 0)), "textFaint")
    end

    -- receipt ring (explicitly labelled as a ring, never presented as a full history)
    card(self, g.rightX, g.cardsY, g.rightW, g.cardsH, tr("Admin_Player_Receipts"))
    text(self, fitText(tr("Admin_Player_RingNote"), g.rightW - PAD * 2), g.rightX + PAD, g.cardsY + CARD_TITLE_H + 1, "textFaint")
    drawColumnHeaders(self, self.receiptList, RECEIPT_COLS, self.receiptList.x, g.receiptHeaderY, rh)
    if #(self.receiptRows or {}) == 0 then
        text(self, lookup and tr("Wallet_Empty") or tr("Admin_Player_Hint"), self.receiptList.x + PAD,
            g.receiptHeaderY + rh + 4, "textFaint")
    end

    -- note next to the action buttons
    local noteY = g.actionY + math.floor((btnH() - fontH.small) / 2)
    local noteW = self.width - g.actionNoteX
    if self.selectedReceipt and self.selectedReceipt.txId then
        text(self, fitText(getText(T .. "Admin_Player_SelectedTx", tostring(self.selectedReceipt.txId)), noteW), g.actionNoteX, noteY, "textFaint")
    elseif self.lookupUser and getPlayer() and self.lookupUser == getPlayer():getUsername() then
        text(self, fitText(tr("Admin_Player_SelfNote"), noteW), g.actionNoteX, noteY, "warn")
    elseif not self.hadWrite then
        text(self, fitText(tr("Admin_ReadOnly"), noteW), g.actionNoteX, noteY, "textFaint")
    end
end

function Admin:drawDashboard()
    local g = self.g
    local lh = lineH()
    local sys = self.system
    local leftW = math.max(220, math.floor((self.width - PAD) * 0.34))
    local bottom = g.bodyY + g.bodyH - 2
    card(self, 0, g.bodyY, leftW, g.bodyH, tr("Admin_Dash_Issued"))
    local y = g.bodyY + CARD_TITLE_H + 4
    if not sys then
        text(self, isPending("admin.system") and tr("Admin_Loading") or tr("Admin_Dash_Empty"), PAD, y, "textMuted")
    else
        local issued = sys.issued or {}
        local colW = math.floor((leftW - PAD * 2) / 3)
        textRight(self, tr("Admin_Dash_Checkin"), PAD + colW * 2, y, "textMuted")
        textRight(self, tr("Admin_Dash_Milestone"), PAD + colW * 3, y, "textMuted")
        y = y + lh + 2
        for _, period in ipairs(ISSUE_PERIODS) do
            local row = issued[period] or {}
            text(self, tr("Admin_Dash_" .. string.upper(string.sub(period, 1, 1)) .. string.sub(period, 2)), PAD, y, "text")
            textRight(self, "+" .. amountText(row.checkin or 0), PAD + colW * 2, y, "positive")
            textRight(self, "+" .. amountText(row.milestone or 0), PAD + colW * 3, y, "positive")
            y = y + lh
        end
        self:beginLines(PAD, y + 4, leftW - PAD * 2, bottom)
        self:line(tr("Admin_Dash_IssuedNote"), "textFaint")
    end

    -- one supply column per currency: player held / reserved / system accounts / top holders
    local order = EC.CURRENCY_ORDER
    local x = leftW + PAD
    local colW = math.max(180, math.floor((self.width - x - PAD * (#order - 1)) / math.max(1, #order)))
    for _, id in ipairs(order) do
        card(self, x, g.bodyY, colW, g.bodyH, getText(T .. "Admin_Dash_Supply", currencyName(id)))
        local s = sys and sys.supply and sys.supply[id]
        self:beginLines(x + PAD, g.bodyY + CARD_TITLE_H + 4, colW - PAD * 2, bottom)
        if not s then
            self:line(sys and tr("Admin_Dash_Empty") or tr("Admin_Loading"), "textMuted")
        else
            self:lineRow(tr("Admin_Dash_Players"), amountText(s.players or 0), "accent")
            self:lineRow(tr("Admin_Dash_Reserved"), amountText(s.reserved or 0))
            self:lineRow(tr("Admin_Dash_System"), amountText(s.system or 0))
            if s.systemReserved ~= nil then
                self:lineRow(tr("Admin_Dash_SystemReserved"), amountText(s.systemReserved))
            end
            if s.net ~= nil then
                self:lineRow(tr("Admin_Dash_Net"), amountText(s.net), "textMuted")
            end
            self:line(getText(T .. "Admin_Dash_Accounts", tostring(s.accounts or 0)), "textFaint")
            self:lineGap()
            local top = s.top or {}
            self:line(getText(T .. "Admin_Dash_Top", tostring(#top)), "textMuted")
            if #top == 0 then
                self:line(tr("Admin_Dash_Empty"), "textFaint")
            end
            for _, holder in ipairs(top) do
                if not self:lineRow(tostring(holder.account or "-"), amountText(holder.amount or 0)) then break end
            end
        end
        x = x + colW + PAD
    end
end

function Admin:drawCurrencies()
    local g = self.g
    local rh = rowH()
    card(self, 0, g.bodyY, g.cfgTableW, g.bodyH, tr("Admin_Cur_Title"))
    local headerY = g.bodyY + CARD_TITLE_H
    fill(self, 1, headerY, g.cfgTableW - 2, rh, "well", "rect")
    local hy = headerY + math.floor((rh - fontH.small) / 2)
    local c1, c2, c3, c4 = PAD, math.floor(g.cfgTableW * 0.24), math.floor(g.cfgTableW * 0.46), math.floor(g.cfgTableW * 0.76)
    text(self, tr("Admin_Cur_Col_Id"), c1, hy, "textMuted")
    text(self, tr("Admin_Cur_Col_Role"), c2, hy, "textMuted")
    text(self, tr("Admin_Cur_Col_Name"), c3, hy, "textMuted")
    text(self, tr("Admin_Cur_Col_State"), c4, hy, "textMuted")
    local y = g.cfgRowY
    local rects = self.cfgRowRects
    for i = #rects, 1, -1 do rects[i] = nil end
    for i, id in ipairs(EC.CURRENCY_ORDER) do
        if y + rh > g.bodyY + g.bodyH - 2 then break end
        local def = currencyDef(id)
        local selected = id == self:selectedCurrency()
        if selected then
            fill(self, 1, y, g.cfgTableW - 2, rh, "selected", "rect")
        elseif i % 2 == 0 then
            fill(self, 1, y, g.cfgTableW - 2, rh, "card", "rect")
        end
        local ty = y + math.floor((rh - fontH.small) / 2)
        text(self, id, c1, ty, selected and "accent" or "text")
        local static = EC.CURRENCIES[id]
        text(self, static and static.marketUnit and tr("Admin_Cur_RoleMarket") or tr("Admin_Cur_RoleExternal"), c2, ty, "textMuted")
        text(self, fitText(currencyName(id), c4 - c3 - PAD), c3, ty, "text")
        local enabled = def == nil or def.enabled ~= false
        text(self, enabled and tr("Admin_On") or tr("Admin_Off"), c4, ty, enabled and "positive" or "textFaint")
        rects[#rects + 1] = { id = id, y = y, h = rh }
        y = y + rh
    end
    if not currencyDefs() then
        text(self, tr("Admin_Loading"), PAD, y + 4, "textFaint")
    end

    -- detail card for the selected currency (exchange block only where the server has one)
    local id = self:selectedCurrency()
    local def = currencyDef(id)
    local detailH = math.max(60, g.cfgButtonY - 6 - g.bodyY)
    card(self, g.cfgDetailX, g.bodyY, g.cfgDetailW, detailH, getText(T .. "Admin_Cur_Detail", currencyName(id)))
    self:beginLines(g.cfgDetailX + PAD, g.bodyY + CARD_TITLE_H + 4, g.cfgDetailW - PAD * 2, g.bodyY + detailH - 2)
    if not def then
        self:line(tr("Admin_Loading"), "textMuted")
    else
        if type(def.nameOverride) == "string" and def.nameOverride ~= "" then
            self:line(getText(T .. "Admin_Cur_Override", def.nameOverride))
        else
            self:line(tr("Admin_Cur_NoOverride"), "textMuted")
        end
        self:line(getText(T .. (def.balanceMaxOverride and "Admin_Cur_BalanceMaxOverride" or "Admin_Cur_BalanceMaxDefault"), amountText(def.balanceMax or 0)), "textMuted")
        self:iconLines(def)
        local ex = def.exchange
        if type(ex) ~= "table" then
            self:line(tr("Admin_Cur_NoExchange"), "textFaint")
        else
            self:lineGap()
            self:line(getText(T .. "Admin_Cur_RateVersion", tostring(ex.rateVersion or 1)), "accent")
            for _, field in ipairs(EXCHANGE_FIELDS) do
                if not self:lineRow(exchangeLabel(field), amountText(ex[field] or 0)) then break end
            end
        end
    end
end

function Admin:drawSources()
    local g = self.g
    local rh = rowH()
    card(self, 0, g.bodyY, g.srcTableW, g.bodyH, tr("Admin_Src_Title"))
    local headerY = g.bodyY + CARD_TITLE_H
    fill(self, 1, headerY, g.srcTableW - 2, rh, "well", "rect")
    local hy = headerY + math.floor((rh - fontH.small) / 2)
    -- the mod id column takes the widest share: ids are long and identify the row
    local c1, c2, c3 = PAD, math.floor(g.srcTableW * 0.36), math.floor(g.srcTableW * 0.48)
    local c4, c5 = math.floor(g.srcTableW * 0.60), math.floor(g.srcTableW * 0.80)
    text(self, tr("Admin_Src_Col_Mod"), c1, hy, "textMuted")
    text(self, tr("Admin_Src_Col_Loaded"), c2, hy, "textMuted")
    text(self, tr("Admin_Src_Col_Enabled"), c3, hy, "textMuted")
    text(self, tr("Admin_Src_Col_Mint"), c4, hy, "textMuted")
    text(self, tr("Admin_Src_Col_Burn"), c5, hy, "textMuted")

    local list = self.sources or {}
    local selected = self:selectedSource()
    local y = g.srcRowY
    local rects = self.srcRowRects
    for i = #rects, 1, -1 do rects[i] = nil end
    for i, s in ipairs(list) do
        if y + rh > g.bodyY + g.bodyH - 2 then break end
        local isSelected = selected ~= nil and selected.modId == s.modId
        if isSelected then
            fill(self, 1, y, g.srcTableW - 2, rh, "selected", "rect")
        elseif i % 2 == 0 then
            fill(self, 1, y, g.srcTableW - 2, rh, "card", "rect")
        end
        local ty = y + math.floor((rh - fontH.small) / 2)
        local today = s.today or {}
        local enabled = s.enabled ~= false
        text(self, fitText(tostring(s.modId), c2 - c1 - PAD), c1, ty, isSelected and "accent" or "text")
        text(self, fitText(s.loaded and tr("Admin_Src_Loaded") or tr("Admin_Src_NotLoaded"), c3 - c2 - PAD), c2, ty,
            s.loaded and "textMuted" or "textFaint")
        text(self, fitText(enabled and tr("Admin_On") or tr("Admin_Off"), c4 - c3 - PAD), c3, ty, enabled and "positive" or "textFaint")
        text(self, fitText(amountText(today.mint or 0) .. " / " .. amountText(s.dailyMintCap or 0), c5 - c4 - PAD), c4, ty, "text")
        text(self, fitText(amountText(today.burn or 0) .. " / " .. capText(s.dailyBurnCap), g.srcTableW - c5 - PAD), c5, ty, "text")
        rects[#rects + 1] = { id = s.modId, y = y, h = rh }
        y = y + rh
    end
    if #list == 0 then
        text(self, isPending("admin.sources") and tr("Admin_Loading") or tr("Admin_Src_Empty"), PAD, y + 4, "textFaint")
    end

    -- detail card for the selected source (the MOD account balance is that mod's net take)
    local detailH = math.max(60, g.srcButtonY - 6 - g.bodyY)
    card(self, g.srcDetailX, g.bodyY, g.srcDetailW, detailH,
        getText(T .. "Admin_Src_Detail", selected and tostring(selected.modId) or "-"))
    self:beginLines(g.srcDetailX + PAD, g.bodyY + CARD_TITLE_H + 4, g.srcDetailW - PAD * 2, g.bodyY + detailH - 2)
    if not selected then
        self:line(isPending("admin.sources") and tr("Admin_Loading") or tr("Admin_Src_Empty"), "textMuted")
        return
    end
    self:lineRow(tr("Admin_Src_Name"), sourceName(selected))
    self:lineRow(tr("Admin_Src_RegisteredAt"),
        selected.registeredAt and U.clockText(tonumber(selected.registeredAt) or 0, self.offsetMin) or "-", "textFaint")
    self:lineGap()
    local bal = selected.balance or {}
    for _, id in ipairs(EC.CURRENCY_ORDER) do
        self:lineRow(getText(T .. "Admin_Src_Balance", currencyName(id)), amountText(bal[id] or 0))
    end
    self:line(tr("Admin_Src_BalanceNote"), "textFaint")
    self:lineGap()
    local today = selected.today or {}
    self:line(getText(T .. "Admin_Src_Calls", amountText(today.ok or 0), amountText(today.calls or 0)), "textMuted")
    for _, r in ipairs(selected.rejectedRows or {}) do
        if not self:lineRow(getText(T .. "Admin_Src_Rejected", errorText(r.code)), amountText(r.n), "warn") then break end
    end
end

function Admin:drawShop()
    local g = self.g
    local snap = self.catalog
    card(self, 0, g.bodyY, self.width, g.bodyH, tr("Admin_Shop_Title"))
    -- file status: a parse error wins over the count, because it says the server is still
    -- running with the previous catalog
    local file = type(snap) == "table" and type(snap.file) == "table" and snap.file or nil
    local status, token
    if file and type(file.error) == "string" and file.error ~= "" then
        status, token = getText(T .. "Admin_Shop_FileError", file.error), "errorText"
    elseif file then
        status, token = getText(T .. "Admin_Shop_File", tostring(file.count or 0), stampText(file.loadedAt, self.offsetMin)), "textMuted"
    else
        status, token = isPending("admin.catalog") and tr("Admin_Loading") or tr("Admin_Dash_Empty"), "textFaint"
    end
    text(self, fitText(status, math.max(0, self.shopReloadButton.x - PAD * 2)), PAD, g.shopHeadY, token)
    local rows = self.catalogRows or {}
    local countText = getText(T .. "Admin_Shop_Count", tostring(#rows))
    textRight(self, countText, self.width - PAD, g.shopNoteY, "textFaint")
    text(self, fitText(tr("Admin_Shop_Note"), math.max(0, self.width - PAD * 3 - textWidth(countText))),
        PAD, g.shopNoteY, "textFaint")
    if #rows == 0 then
        local empty
        if snap == nil then
            empty = isPending("admin.catalog") and tr("Admin_Loading") or tr("Admin_Dash_Empty")
        else
            empty = tr("Admin_Shop_Empty")
        end
        text(self, empty, self.catalogList.x + PAD, self.catalogList.y + 4, "textFaint")
    end
end

function Admin:drawWhitelist()
    local g = self.g
    card(self, 0, g.bodyY, self.width, g.bodyH, tr("Admin_Wl_Title"))
    -- file status: a parse error wins over the counts, because it says the server is still
    -- running with the previous file
    local wl = self.whitelist
    local status, token
    if wl and type(wl.error) == "string" and wl.error ~= "" then
        status, token = getText(T .. "Admin_Wl_Error", wl.error), "errorText"
    elseif wl then
        local c = type(wl.counts) == "table" and wl.counts or {}
        status = getText(T .. "Admin_Wl_Status", tostring(c.categories or 0), tostring(c.types or 0),
            tostring(c.excludeTypes or 0), tostring(c.modDataKeys or 0), stampText(wl.loadedAt, self.offsetMin))
        token = "textMuted"
    else
        status, token = isPending("admin.whitelist") and tr("Admin_Loading") or tr("Admin_Dash_Empty"), "textFaint"
    end
    text(self, fitText(status, math.max(0, self.wlReloadButton.x - PAD * 2)), PAD, g.wlHeadY, token)
    local noteW = math.max(0, self.width - PAD * 2)
    text(self, fitText(tr("Admin_Wl_Note"), noteW), PAD, g.wlNoteY, "textFaint")
    text(self, fitText(tr("Admin_Wl_Fixed"), noteW), PAD, g.wlFixedY, "textFaint")
    local shown = self.wlShown or { cats = 0, items = 0 }
    textRight(self, getText(T .. "Admin_Wl_Count", tostring(shown.cats), tostring(shown.items)),
        self.width - PAD, g.wlSearchY, "textFaint")
    local rows = self.wlRows or {}
    if #rows == 0 then
        local empty
        if wl == nil then
            empty = isPending("admin.whitelist") and tr("Admin_Loading") or tr("Admin_Dash_Empty")
        elseif self.wlQuery then
            empty = tr("Admin_Wl_NoMatch")
        else
            empty = tr("Admin_Wl_Hint")
        end
        text(self, fitText(empty, math.max(0, self.whitelistList.width - PAD * 2)),
            self.whitelistList.x + PAD, self.whitelistList.y + 4, "textFaint")
    end
end

function Admin:drawListings()
    local g = self.g
    card(self, 0, g.lstY, self.width, g.lstH, tr("Admin_Lst_Title"))
    local snap = self.listings
    local rows = self.listingRows or {}
    local countText = getText(T .. "Admin_Lst_Count", tostring((snap and snap.total) or 0))
    textRight(self, countText, self.width - PAD, g.lstHeadY, "textFaint")
    text(self, fitText(tr("Admin_Lst_Note"), math.max(0, self.width - PAD * 2 - g.lstNoteX - textWidth(countText))),
        g.lstNoteX, g.lstHeadY, "textFaint")
    if #rows == 0 then
        local empty
        if snap == nil then
            empty = isPending("admin.listings") and tr("Admin_Loading") or tr("Admin_Dash_Empty")
        else
            empty = tr("Admin_Lst_Empty")
        end
        text(self, empty, self.listingsList.x + PAD, self.listingsList.y + 4, "textFaint")
    end
    local page, pages = 1, 1
    if snap then
        page = math.max(1, math.floor(tonumber(snap.page) or 1))
        pages = math.max(1, math.floor(tonumber(snap.pages) or 1))
    end
    text(self, fitText(getText(T .. "Market_Page", tostring(page), tostring(pages)),
        math.max(0, self.lstPrevButton.x - PAD * 2)), PAD, g.lstPageTextY, "textFaint")
end

function Admin:drawAudit()
    local g = self.g
    local rh = rowH()
    card(self, 0, g.bodyY, self.width, g.bodyH, tr("Admin_Audit_Title"))
    local filterY = self.auditEntry.y + math.floor((entryH() - fontH.small) / 2)
    local stampW = 0
    if self.auditAt then
        local stamp = getText(T .. "Admin_Updated", U.clockText(self.auditAt, self.offsetMin))
        stampW = textWidth(stamp) + PAD
        textRight(self, stamp, self.width - PAD, filterY, "textFaint")
    end
    local rolled = self.auditFilter == "rolled"
    local total = self.auditTotal or 0
    text(self, fitText(getText(T .. "Admin_Audit_Count", tostring(#(self.auditRows or {})), tostring(total)),
        self.width - g.auditCountX - stampW), g.auditCountX, filterY, "textMuted")
    drawColumnHeaders(self, self.auditList, AUDIT_COLS, self.auditList.x, g.auditHeaderY, rh)
    if #(self.auditRows or {}) == 0 then
        text(self, (isPending("admin.audit") or isPending("admin.auditFile")) and tr("Admin_Loading") or tr("Admin_Audit_Empty"),
            self.auditList.x + PAD, g.auditHeaderY + rh + 4, "textFaint")
    end
    text(self, fitText(tr(rolled and "Admin_Audit_RolledNote" or "Admin_Audit_ReasonNote"), self.width - PAD * 2), PAD, g.auditBottom + 2, "textFaint")
end

function Admin:drawSystem()
    local g = self.g
    local lh = lineH()
    local sys = self.system
    card(self, 0, g.bodyY, g.sysLeftW, g.bodyH, tr("Admin_Sys_State"))
    self:beginLines(PAD, g.bodyY + CARD_TITLE_H + 4, g.sysLeftW - PAD * 2, g.bodyY + g.bodyH - 2)
    if not sys then
        self:line(isPending("admin.system") and tr("Admin_Loading") or tr("Admin_Dash_Empty"), "textMuted")
    else
        local now = EC.now()
        self:lineRow(tr("Admin_Sys_Seq"), amountText(sys.seq or 0), "accent")
        self:lineRow(tr("Admin_Sys_Epoch"), tostring(sys.epoch or "-"))
        self:lineRow(tr("Admin_Sys_LoadedSeq"), amountText(sys.loadedSeq or 0))
        self:line(tr("Admin_Sys_LoadedSeqNote"), "textFaint")
        self:lineRow(tr("Admin_Sys_Realm"), tostring(sys.realmId or "-"))
        self:line(getText(T .. "Admin_Sys_StartedAt", stampText(sys.startedAt, self.offsetMin)), "textFaint")
        self:line(getText(T .. "Admin_Sys_Version", tostring(sys.version or "-"), tostring(sys.schemaVersion or "-")), "textFaint")
        self:lineGap()
        self:line(getText(T .. "Admin_Sys_Accounts", tostring(sys.accounts or 0), tostring(sys.frozen or 0)))
        self:lineRow(tr("Admin_Sys_Terminals"), amountText(sys.terminals or 0))
        self:lineRow(tr("Admin_Sys_Mailbox"), amountText(sys.mailboxUnclaimed or 0),
            (tonumber(sys.mailboxUnclaimed) or 0) > 0 and "warn" or "text")
        local cat = sys.catalog
        if type(cat) == "table" and type(cat.error) == "string" and cat.error ~= "" then
            self:lineRow(tr("Admin_Sys_Catalog"), fitText(cat.error, math.floor(self.lw * 0.6)), "errorText")
        else
            self:lineRow(tr("Admin_Sys_Catalog"), getText(T .. "Admin_Shop_Count", tostring((type(cat) == "table" and cat.count) or 0)))
        end
        local mk = sys.market
        self:lineRow(tr("Admin_Sys_Listings"), amountText((type(mk) == "table" and mk.listings) or 0)
            .. " / " .. tostring((type(mk) == "table" and mk.max) or "?"))
        local wl = sys.whitelist
        if type(wl) == "table" and type(wl.error) == "string" and wl.error ~= "" then
            self:lineRow(tr("Admin_Sys_Whitelist"), fitText(wl.error, math.floor(self.lw * 0.6)), "errorText")
        else
            local counts = type(wl) == "table" and type(wl.counts) == "table" and wl.counts or {}
            self:lineRow(tr("Admin_Sys_Whitelist"), tostring(counts.categories or 0))
        end
        self:lineRow(tr("Admin_Sys_Size"), sizeText(sys.sizeEstimate))
        local parts = sys.sizeParts
        if type(parts) == "table" then
            self:line(getText(T .. "Admin_Sys_SizeParts", sizeText(parts.ledger), sizeText(parts.admin)), "textFaint")
        end
        self:line(tr("Admin_Sys_SizeNote"), "textFaint")
        if sys.auditCount ~= nil then
            self:lineRow(tr("Admin_Sys_AuditRing"), tostring(sys.auditCount) .. " / " .. tostring(sys.auditMax or "?"))
        end
        self:lineGap()
        self:line(tr("Admin_Sys_Export"))
        self:lineRow(tr("Admin_Sys_Queued"), amountText(sys.queuedLines or 0), (tonumber(sys.queuedLines) or 0) > 0 and "warn" or "text")
        local hb = tonumber(sys.heartbeatAt) or 0
        if hb > 0 then
            self:line(getText(T .. "Admin_Sys_Heartbeat", stampText(hb, self.offsetMin), agoText(hb, now)), "textFaint")
        else
            self:line(tr("Admin_Sys_HeartbeatNever"), "textFaint")
        end
        self:line(tr("Admin_Sys_HeartbeatNote"), "textFaint")
    end

    card(self, g.sysRightX, g.bodyY, g.sysRightW, g.bodyH, tr("Admin_Sys_Paths"))
    local py = g.sysPathY
    local paths = sys and sys.paths
    for i, key in ipairs(PATH_KEYS) do
        local button = self.copyButtons[i]
        local value = tostring(paths and paths[key] or "-")
        local label = tr("Admin_Sys_Path_" .. key)
        local vy = py + math.floor((button.height - fontH.small) / 2)
        if g.sysStacked then
            text(self, label, g.sysRightX + PAD, py, "textMuted")
            py = py + lh
            vy = py + math.floor((button.height - fontH.small) / 2)
            text(self, pathDisplay(value, button.x - 6 - (g.sysRightX + PAD)), g.sysRightX + PAD, vy, "text")
        else
            text(self, fitText(label, g.sysLabelW), g.sysRightX + PAD, vy, "textMuted")
            local vx = g.sysRightX + PAD + g.sysLabelW + PAD
            text(self, pathDisplay(value, button.x - 6 - vx), vx, vy, "text")
        end
        py = py + button.height + 4
    end
    -- the server omits paths entirely when it could not resolve the cache dir (pathsResolved)
    if sys and paths == nil and py + lh <= g.bodyY + g.bodyH - 2 then
        text(self, fitText(tr("Admin_Sys_PathsUnavailable"), g.sysRightW - PAD * 2), g.sysRightX + PAD, py, "warn")
    end
end

function Admin:drawSettings()
    local g = self.g
    card(self, 0, g.bodyY, self.width, g.bodyH, tr("Admin_Set_Title"))
    local searching = self.setQuery ~= nil
    local rows = self.settingRows or {}
    -- search row: the standing note fills the space beside the box, the row count sits far right
    local countText = getText(T .. "Admin_Set_Count", tostring(#rows))
    local headY = self.setEntry.y + math.floor((self.setEntry.height - fontH.small) / 2)
    textRight(self, countText, self.width - PAD, headY, "textFaint")
    text(self, fitText(tr("Admin_Set_Note"), math.max(0, self.width - PAD * 2 - g.setCountX - textWidth(countText))),
        g.setCountX, headY, "textFaint")

    -- group nav: name on the left, the override count (else the option count) on the right. The
    -- rows are painted, so a click is resolved from g.setNavRowH in onMouseDown.
    fill(self, PAD, g.setNavY, g.setNavW, g.setNavH, "well", "rect")
    local ny = g.setNavY
    for _, id in ipairs(EC.OPTION_GROUPS) do
        local total, overrides = self:optionGroupCount(id)
        local active = id == self.setGroup and not searching
        if active then
            fill(self, PAD, ny, g.setNavW, g.setNavRowH, "selected", "rect")
            fill(self, PAD, ny, 2, g.setNavRowH, "accent", "rect")
        end
        local ty = ny + math.floor((g.setNavRowH - fontH.small) / 2)
        local tail = overrides > 0 and getText(T .. "Admin_Set_OverrideCount", tostring(overrides))
            or getText(T .. "Admin_Set_Count", tostring(total))
        textRight(self, tail, PAD + g.setNavW - PAD, ty, overrides > 0 and "warn" or "textFaint")
        text(self, fitText(tr("Admin_Set_Group_" .. id), math.max(0, g.setNavW - PAD * 3 - textWidth(tail))),
            PAD * 2, ty, active and "accent" or "text")
        ny = ny + g.setNavRowH
    end

    -- content column: the group (or "search") as its heading, then the list
    local title = searching and tr("Admin_Set_Search") or tr("Admin_Set_Group_" .. self.setGroup)
    text(self, fitText(title, g.setContentW, UIFont.Medium), g.setContentX, g.setHeadY, "text", UIFont.Medium)
    if #rows == 0 then
        local empty
        if self.options == nil then
            empty = isPending("admin.system") and tr("Admin_Loading") or tr("Admin_Dash_Empty")
        else
            empty = tr("Admin_Set_NoMatch")
        end
        text(self, empty, self.settingsList.x + PAD, self.settingsList.y + 4, "textFaint")
    end
end

function Admin:prerender()
    if self.width ~= self.layoutW or self.height ~= self.layoutH then
        self:layout()
    end

    local now = EC.now()
    -- permission collapse: re-read the role at most twice a second
    if not self.permCheckedAt or now - self.permCheckedAt > PERM_POLL_MS then
        self.permCheckedAt = now
        -- the server's last verdict (serverPerms) is bound to the role it judged: once the local
        -- role changes, drop it so a re-promoted admin is not locked out until the window reopens
        local level = accessLevel()
        if level ~= self.lastLevel then
            self.lastLevel = level
            self.serverPerms = nil
        end
        local write, read = self:writeAllowed(), self:readAllowed()
        if write ~= self.hadWrite or read ~= self.hadRead then
            if not write then self:closeDialog() end
            if not read then self:closeSuggest() end
            if not read then self.catalog = nil; self.listings = nil; self.whitelist = nil end
            self:layout()   -- hides/shows the page children for the new permission level
        end
    end

    -- outcome of an icon reload started a moment ago
    if self.iconsRecheckAt and now >= self.iconsRecheckAt then
        self.iconsRecheckAt = nil
        if self:readAllowed() then send("admin.icons", { action = "status" }) end
        self:updateEnabled()
    end

    -- Another admin's change reaches us as a config broadcast (ECClient replaces C.options with
    -- a fresh table): adopt whichever snapshot arrived last, without a round trip of our own.
    if self.tab == "Settings" and C.options ~= nil and C.options ~= self.optionsSeen then
        self.optionsSeen = C.options
        self.options = C.options
        self:rebuildSettings()
        self:updateEnabled()
    end

    flushDeferred(now)

    -- one timed-out command per frame at most (pendingAt holds at most #COMMANDS keys)
    local stale = nil
    for command, at in pairs(pendingAt) do
        if now - at > TIMEOUT_MS then stale = command end
    end
    if stale then
        pendingAt[stale] = nil
        deferred[stale] = nil
        self:onTimeout(stale)
    end

    -- a target the admin asked for while the cooldown or an older lookup was still holding
    if self.lookupRetryUser and self.hadRead then
        if self.lookupRetryUser ~= self.lookupUser then
            self.lookupRetryUser = nil
        elseif send("admin.lookup", { username = self.lookupRetryUser }) then
            self.lookupRetryUser = nil
            self:updateEnabled()
        end
    end

    -- a page or a search text the admin changed while the cooldown (or an older answer) was
    -- still holding the command
    if self.tab == "Listings" and self.hadRead
        and (self.lstSentQuery ~= self.lstQuery or self.lstSentPage ~= (self.lstPage or 1)) then
        self:requestListings()
    end

    -- visible auto refresh of the open page (read permission only)
    if self.hadRead and (not self.polledAt or now - self.polledAt > POLL_MS) then
        self.polledAt = now
        self:refresh()
    end

    -- search candidates: debounce clock and the dropdown's own geometry
    if self.tab == "Player" and self.hadRead then self:tickPlayers(now) end

    local g = self.g
    fill(self, 0, 0, self.width, g.subH, "well", "rect")
    if not self.hadRead then
        text(self, tr("Admin_NoPermission"), PAD, g.bodyY, "errorText")
        return
    end
    -- the auto refresh has to be visible: the pages without their own stamp show it in the tab bar
    local stampAt = ((self.tab == "Dashboard" or self.tab == "System" or self.tab == "Settings") and self.systemAt)
        or (self.tab == "Sources" and self.sourcesAt) or (self.tab == "Shop" and self.catalogAt)
        or (self.tab == "Listings" and self.listingsAt) or nil
    if stampAt then
        textRight(self, getText(T .. "Admin_Updated", U.clockText(stampAt, self.offsetMin)),
            self.refreshButton.x - PAD, math.floor((g.subH - fontH.small) / 2), "textFaint")
    end
    if self.tab == "Player" then
        self:drawPlayer()
    elseif self.tab == "Dashboard" then
        self:drawDashboard()
    elseif self.tab == "Currencies" then
        self:drawCurrencies()
    elseif self.tab == "Sources" then
        self:drawSources()
    elseif self.tab == "Shop" then
        self:drawShop()
    elseif self.tab == "Whitelist" then
        self:drawWhitelist()
    elseif self.tab == "Listings" then
        self:drawListings()
    elseif self.tab == "Audit" then
        self:drawAudit()
    elseif self.tab == "Settings" then
        self:drawSettings()
    else
        self:drawSystem()
    end

    -- footer: message on the left, the standing audit note on the right
    local fy = g.footerY + 1
    local note = tr("Admin_AuditNote")
    local noteW = textWidth(note)
    if self.message then
        text(self, fitText(self.message.text, self.width - noteW - PAD * 2), 0, fy, self.message.error and "errorText" or "positive")
    end
    textRight(self, note, self.width, fy, "textFaint")
end

function Admin:render() end

-- row click selects the currency / integration source the action buttons operate on
-- Jump to the audit page filtered to one account's freeze history (full reasons come from the
-- audit files, which the page loads on open).
function Admin:showAuditFor(username, filter)
    for _, b in ipairs(self.subTabButtons) do
        if b.internal == "Audit" then self:onSubTab(b) end
    end
    setEntryText(self.auditEntry, username)
    self.auditQuery = string.lower(username)
    self.auditFilter = filter or "all"
    for _, b in ipairs(self.auditFilterButtons) do b.active = b.internal == self.auditFilter end
    self:rebuildAudit()
end

function Admin:onMouseDown(x, y)
    if self.dialog then return true end
    local link = self.frozenLink
    if self.tab == "Player" and link and self.lookupUser and x >= link.x and x < link.x + link.w and y >= link.y and y < link.y + link.h then
        self:showAuditFor(self.lookupUser, "freeze")
        return true
    end
    if self.tab == "Currencies" and x < (self.g and self.g.cfgTableW or 0) then
        for _, r in ipairs(self.cfgRowRects or {}) do
            if y >= r.y and y < r.y + r.h then
                self.cfgSelected = r.id
                self:updateEnabled()
                return true
            end
        end
    elseif self.tab == "Sources" and x < (self.g and self.g.srcTableW or 0) then
        for _, r in ipairs(self.srcRowRects or {}) do
            if y >= r.y and y < r.y + r.h then
                self.srcSelected = r.id
                self:updateEnabled()
                return true
            end
        end
    elseif self.tab == "Settings" then
        local g = self.g
        if g and x >= PAD and x < PAD + (g.setNavW or 0) and y >= (g.setNavY or 0) and y < (g.setNavY or 0) + (g.setNavH or 0) then
            self:onSettingNav(y)
            return true
        end
    end
    return true
end

function Admin:onMouseUp(x, y) return true end

-- ----- lifecycle -----

-- Server round trips for the page that is on screen. Commands are cooldown-guarded, so a rapid
-- tab switch simply skips the extra request.
function Admin:refresh()
    if not self:readAllowed() then return end
    if self.tab == "Player" then
        if self.lookupUser then send("admin.lookup", { username = self.lookupUser }) end
    elseif self.tab == "Audit" then
        send("admin.audit", { limit = AUDIT_LIMIT })
        send("admin.auditFile", {})
    elseif self.tab == "Dashboard" or self.tab == "System" or self.tab == "Settings" then
        send("admin.system", {})
    elseif self.tab == "Currencies" and self.icons == nil then
        send("admin.icons", { action = "status" })
    elseif self.tab == "Sources" then
        send("admin.sources", { action = "list" })
    elseif self.tab == "Shop" then
        send("admin.catalog", { action = "list" })
    elseif self.tab == "Listings" then
        self:requestListings()
    elseif self.tab == "Whitelist" then
        send("admin.whitelist", { action = "status" })
    end
    self:updateEnabled()
end

function Admin:setVisible(visible)
    ISPanel.setVisible(self, visible)
    if visible then
        self.offsetMin = U.localOffsetMinutes()
        self.permCheckedAt = nil
        self.polledAt = nil
    else
        self:closeDialog()
        self:closeSuggest()
        pcall(function() self.userEntry:unfocus() end)
        pcall(function() self.auditEntry:unfocus() end)
        pcall(function() self.setEntry:unfocus() end)
        pcall(function() self.lstEntry:unfocus() end)
        pcall(function() self.wlEntry:unfocus() end)
    end
end

function Admin:dispose()
    self:closeDialog()
    self:closeSuggest()
    pcall(function() self.userEntry:unfocus() end)
    pcall(function() self.auditEntry:unfocus() end)
    pcall(function() self.setEntry:unfocus() end)
    pcall(function() self.lstEntry:unfocus() end)
    pcall(function() self.wlEntry:unfocus() end)
    self.lookup = nil
    self.audit = nil
    self.system = nil
    self.pendingAdjust = nil
    self.pendingFreeze = nil
    self.pendingConfig = nil
    self.sources = nil
    self.pendingSource = nil
    self.options = nil
    self.pendingOption = nil
    self.resetQueue = nil
    self.catalog = nil
    self.pendingCatalog = nil
    self.listings = nil
    self.pendingListings = nil
    self.whitelist = nil
    self.pendingWhitelist = nil
    self.wlUniverse = nil
    self.wlRows = nil
    if P.instance == self then P.instance = nil end
end

-- ---------- module API ----------

-- owner: the ECPanel window (kept for reference only; the child never reaches into it).
-- Returns an initialised child that the owner adds, positions and resizes. No command is sent.
function P.create(owner)
    if not U.init() then return nil end
    local o = ISPanel:new(0, 0, 600, 300)
    setmetatable(o, Admin)
    o.background = false
    o.owner = owner
    o.tab = "Player"
    o.auditFilter = "all"
    o.lstPage = 1
    o.auditQuery = nil
    o.cfgSelected = EC.CURRENCY_ORDER[1]
    o.cfgRowRects = {}
    o.srcRowRects = {}
    o.setGroup = EC.OPTION_GROUPS[1]
    o.offsetMin = U.localOffsetMinutes()
    o.hadWrite = P.canWrite()
    o.hadRead = o.hadWrite or P.canRead()
    o:initialise()
    o:instantiate()   -- builds the children now; the owner only has to addChild/resize
    o:setVisible(false)
    P.instance = o
    return o
end

for _, command in ipairs(COMMANDS) do
    local kind = string.sub(command, 7)
    C.handlers[command] = function(args)
        pendingAt[command] = nil
        local inst = P.instance
        if inst then inst:onReply(kind, args or {}) end
    end
end

-- Escape folds the candidate dropdown away: a text entry has no key hook of its own, and ECPanel
-- reads its own hotkey the same way (ECPanel.lua:723-728).
Events.OnKeyPressed.Add(function(key)
    local inst = P.instance
    if inst and key ~= 0 and Keyboard and key == Keyboard.KEY_ESCAPE then inst:closeSuggest() end
end)

return P
