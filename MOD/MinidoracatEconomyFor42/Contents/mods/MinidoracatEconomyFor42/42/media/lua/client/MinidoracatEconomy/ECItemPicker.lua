-- MinidoracatEconomyFor42 -- shared "pick an item" overlay (client). Adds exactly one namespace:
-- C.ItemPicker.
--
--   C.ItemPicker.universe()
--       every item script this server loaded (base game and MODs alike), read once per session:
--       { items = { record, ... }, byType = { [fullType] = record }, cats = { [category] = n } },
--       record = { fullType, name (C.itemLabel: the player's own language, a car part's vehicle
--       class included), original (the real English name with that class, C.ItemNames.label; ""
--       when no shipped or MOD dictionary has one for this type), category, script, search,
--       fixed = EC.isFixedType(script) }. The scan itself is the framework's
--       (UI.ItemPicker.universe, which leaves out hidden / obsolete scripts); `fixed` is a flag on
--       the record, never a reason to drop it, so the shop (which sells anything) and the market
--       whitelist (which cannot list the fixed classes) read one universe and apply their own
--       policy. Never sorted: this list is thousands of rows long; consumers order the slice they
--       show. `original` and `search` come from C.ItemNames, whose files load over a few ticks:
--       this call starts that load, and refills those two fields in place on the records every
--       page already holds once it is ready. There is never a second index of the universe.
--
--   C.ItemPicker.queryTypes(query)
--       the item types a keyword names through that same `search` text: list (sent with every
--       item keyword search, at most 200) and set (for a page's own filter); nil, {} for none.
--
--   C.ItemPicker.create(owner, policy, onPick, onCancel, noDrag)
--       the framework's UI.ItemPicker overlay (rev 11), NOT added: the owning page adds it last
--       (so it paints over its own content), positions it at (0, 0) and resizes it to the whole
--       page (`noDrag`: the host takes no dropped item, so the hint line does not offer it).
--       policy is 'shop' (the whole universe) or 'market' (fixed classes skipped).
--       onPick(record) and onCancel() are plain functions, called after the overlay has closed
--       itself; neither sends a command. Methods: open(), close(), isOpen(), cancel(),
--       resize(w, h), keyboardTargets(), dispose(). The overlay debounces its own search and
--       re-asks when the English index lands (revision), so no host ticks it.

require "MinidoracatEconomy/ECWidgets"
require "MinidoracatEconomy/ECItemNames"

local EC = MinidoracatEconomy
local C = EC.Client
local U = C.UI
local Names = C.ItemNames

local P = {}
C.ItemPicker = P

local T = U.T

local function tr(key) return getText(T .. key) end

-- ---------- the universe ----------

local universe = nil

-- The two fields a search reads, filled from the English index: `original` is the real English
-- name (the shipped dictionary, then what an activated MOD's own EN ItemName.json says, with a car
-- part's vehicle class: Names.label), and `search` is what one keystroke matches on -- the
-- player's own language, that English, the English a MOD renamed away from, and the id itself.
-- Lowercased here, never per keystroke.
-- Called on every universe() so the records already handed out gain their English in place the
-- tick the index is ready; the revision guard makes the walk happen once per change, not per
-- call. An unknown type keeps original = "": no name is invented for it anywhere.
local function applyEnglish(uni)
    local rev = Names.revision
    if uni.namesRev == rev then return end
    uni.namesRev = rev
    for _, rec in ipairs(uni.items) do
        local _, alt, also = Names.english(rec.fullType)
        rec.original = Names.label(rec.fullType) or ""
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
    -- every window resolves the framework before it is built, but the item menu builds none: an
    -- administrator's first right-click of the session gets here with nothing resolved, so this
    -- asks itself (U.init answers the same facade every time). Without a framework there is
    -- nothing to scan, and that empty answer is not cached either.
    local ui = U.init()
    if ui == nil then return uni end
    -- the framework's records are shared with every consumer and read-only: this mod builds its
    -- own on top (the English fields and the listing policy are Economy's, not the scan's). The
    -- category is the server whitelist's own (EC.itemCategory): the framework writes "Item" for a
    -- MOD script that sets no DisplayCategory, where vanilla and the server go by the item class.
    -- The name is the one every Economy row shows (C.itemLabel): the framework's names a car
    -- part's vehicle class only from rev 20 (itemPickerVehicleClass), and this mod runs on rev 11.
    for _, src in ipairs(ui.ItemPicker.universe().items) do
        local category = EC.itemCategory(src.script) or src.category
        local record = {
            fullType = src.fullType, name = C.itemLabel(src.fullType), category = category, script = src.script,
            original = "", search = "",       -- applyEnglish below owns both
            fixed = EC.isFixedType(src.script),
        }
        uni.byType[src.fullType] = record
        uni.items[#uni.items + 1] = record
        uni.cats[category] = (uni.cats[category] or 0) + 1
    end
    -- an empty answer is not cached: the script manager had nothing to say yet, and caching that
    -- would leave every picker on this session permanently empty
    if #uni.items > 0 then universe = uni end
    applyEnglish(uni)
    return uni
end

-- The item types a typed keyword names in the player's own language: every record whose
-- `search` (translated name, English names, fullType) holds it, fixed classes skipped (they are
-- never listed, auctioned or ordered), at most TYPES_MAX. Every item keyword search sends the
-- list with its query and the server matches those types before it pages (ECMarket Mk.typesOf),
-- because it never sees the translated names; the set lets a page filter the snapshot on screen
-- the same way. Returns nil, {} for no keyword. Cached per keyword until the index changes.
P.TYPES_MAX = 200
local NO_TYPES = {}
local typesCache, typesRev, typesCount = {}, nil, 0
function P.queryTypes(query)
    local q = type(query) == "string" and string.lower(string.match(query, "^%s*(.-)%s*$") or "") or ""
    if q == "" then return nil, NO_TYPES end
    local uni = P.universe()
    if typesRev ~= Names.revision or typesCount >= 32 then
        typesCache, typesRev, typesCount = {}, Names.revision, 0
    end
    local hit = typesCache[q]
    if hit then return hit.list, hit.set end
    local list, set = {}, {}
    for _, rec in ipairs(uni.items) do
        local t = rec.fullType
        if not rec.fixed and not set[t] and string.find(rec.search, q, 1, true) then
            list[#list + 1], set[t] = t, true
            if #list >= P.TYPES_MAX then break end
        end
    end
    -- an empty universe is not cached (P.universe does not cache it either)
    if #uni.items > 0 then
        typesCache[q], typesCount = { list = list, set = set }, typesCount + 1
    end
    return list, set
end

-- ---------- the overlay ----------

local function notFixed(rec) return not rec.fixed end

-- What the English half of `search` is worth right now. It goes first on the hint line, because
-- the hint is fitted to one line: the count may be cut, the reason a name is missing may not.
-- With the index complete, the line says the other way in: drag the item onto the page -- unless
-- the page takes no drop (`noDrag`), where it says nothing more.
local function namesNote(noDrag)
    local names = Names.status()
    if names == "loading" or names == "idle" then return tr("Admin_Pick_NamesLoading") end
    if names == "partial" then return tr("Admin_Pick_NamesPartial") end
    if noDrag then return nil end
    return tr("Admin_Pick_DragHint")
end

function P.create(owner, policy, onPick, onCancel, noDrag)
    return U.framework.ItemPicker.new({
        theme = U.theme, placeholder = tr("Admin_Pick_Search"),
        items = function() return P.universe().items end,
        filter = policy == "market" and notFixed or nil,
        revision = function() return Names.revision end,
        note = function() return namesNote(noDrag) end,
        onPick = function(_, rec) onPick(rec) end,
        onCancel = function() if onCancel then onCancel() end end,
    })
end

return P
