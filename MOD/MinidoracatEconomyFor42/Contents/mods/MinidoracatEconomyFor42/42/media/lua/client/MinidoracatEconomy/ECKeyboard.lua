-- MinidoracatEconomyFor42 -- keyboard navigation for the mod's windows.
--
-- One engine per session, no dispatcher of its own anywhere else: a window forwards the four native
-- key hooks here, this file walks an ordered list of *descriptors* that window builds, paints the
-- focus ring, and eats every key it acted on so nothing leaks into the game bindings. Two windows
-- may be up at once (the Economy Center -> its main tabs, and the administration window -> the
-- admin sub tabs then Admin:keyboardTargets); the ring belongs to exactly one of them at a time.
--
-- Descriptor (the owner of a page builds them; nothing here is hard-coded per page):
--   { kind = "group",  controls = { button, ... }, label = string }  -- arrows walk, Enter presses
--   { kind = "button", control = button,           label = string }
--   { kind = "entry",  control = ISTextEntryBox,   label = string }
--   { kind = "combo",  control = ISComboBox,       label = string }
--   { kind = "list",   control = VirtualList,      label = string }
--   { kind = "scroll", control = element,          label = string }
-- Two optional fields, for what a widget cannot be asked:
--   focusable = false     never hand this control the engine's text focus (a selectable but
--                         non-editable box would swallow every key -- see the read-only trap)
--   copyAll = button      Ctrl+C over this target presses that chip instead of copying here
-- One optional method on the *root* (never on a descriptor):
--   root:onEscape() -> true   an overlay the root owns closed on this Escape; the ring is left
--                             alone and the key is claimed for that root only
--
-- Tab / Shift+Tab walk descriptors; arrows move inside a group. Enter activates a control;
-- Space activates buttons/groups, not an entry that has finished typing. Escape gives the
-- keyboard back. Home/End/PageUp/PageDown scroll; Ctrl+C uses an offered CopyAll action.
--
-- Engine references (snapshot 42.20.4-20260826):
--   dispatch order      UIElement.java:2185-2214 -- onConsumeKeyPress calls onKeyPress *first* and
--                       asks isKeyConsumed afterwards, so a handler that just closed the focus must
--                       still answer "mine" for that key. Hence the ledger below.
--   top-level only      UIManager.java:1435-1466 (visible + isWantKeyEvents, last added asked first)
--   what a leak costs   GameKeyboard.java:35-60 -- an unconsumed release reaches OnKeyPressed (the
--                       mod's own [ hotkey and every other mod's), an unconsumed press reaches
--                       OnKeyStartPressed / the game bindings (:72-84).
--   text focus wins     GameKeyboard.java:32 reads Core.currentTextEntryBox:isDoingTextEntry(): while
--                       a box is focused the whole UIManager key path is skipped (press, repeat and
--                       release alike), so Tab/Escape come back through the box's own onOtherKey and
--                       Enter through onCommandEntered (Core.java:2044-2053, UITextBox2.java:841-856).
--   read-only trap      Core.java:2036-2040 -- Core.updateKeyboard requires isEditable(), while
--                       GameKeyboard only tests isDoingTextEntry(): focusing a non-editable box
--                       swallows every key and handles none. Such a box is never focused here.
--   mouse focus         UITextBox2.java:710-724 -- a click focuses the box itself and drops the
--                       previous box's text entry, with no key hook and no Lua of ours involved. So
--                       an editable target is hooked while it is merely *on screen* (observe below),
--                       and the hook adopts the box the player really focused.
--   modifiers lie       GameKeyboard.java:122-127 -- isKeyDown returns false outright while a box is
--                       doing text entry (wasKeyDown too, :157-162), and the global isShiftKeyDown /
--                       isCtrlKeyDown are exactly those calls (LuaManager.java:7187-7200): read from
--                       inside a focused field, Shift+Tab would walk *forwards*. org.lwjglx.input
--                       .Keyboard is exposed to Lua as well (LuaManager.java:2491) and its isKeyDown
--                       asks GLFW directly (Keyboard.java:232-240) -- the ungated reader vanilla uses
--                       for modifiers (ISSetKeybindDialog.lua:108-110) and the Java twin of what Core
--                       does for the same reason (Core.java:2045, isKeyDownRaw).
--   who owns the hold   Core.java:2049-2050 -- Escape is answered *and* eaten for the engine
--                       (eatKeyPress(1), swallowed again at GameKeyboard.java:38-39), so this file
--                       must not claim it. Tab (:2052-2053) and Enter (:2046-2047) are not eaten:
--                       once the box lets the keyboard go their release reaches the root, and an
--                       unclaimed release is an OnKeyPressed leak.
--   button press path   ISButton.lua:70-79 (forceClick: visible+enable tested, one onclick call)
--   combo               ISComboBox.lua:200-215 (showPopup/hidePopup), :236-257 (forceClick commits
--                       and fires onChange once), :159-179 (popup.selected / ensureVisible)
--   list                MinidoracatUI/VirtualList.lua:106-131 (setSelectedIndex does not fire
--                       onSelect: moving the highlight has no side effect), :259-286 (onSelect is
--                       what a mouse press calls)
--   element scroll      ISUIElement.lua:332-336, :1639-1700 (getYScroll is 0 at the top and goes
--                       negative downwards, the direction ISTextEntryBox's own wheel uses :242)
--   clipboard           core/Clipboard.java:52-59

if not MinidoracatEconomy or not MinidoracatEconomy.Client or not MinidoracatEconomy.Client.UI then
    require "MinidoracatEconomy/ECWidgets"
end
local EC = MinidoracatEconomy
local C = EC.Client
local U = C.UI

local K = {}
C.Keyboard = K

local T = U.T

-- ---------- the consumption ledger ----------
-- Everything a handler took, keyed by the key itself. The entry outlives the handler (the mode may
-- have closed, the popup may already be gone) and is dropped one call after the release, so the
-- press, every repeat and the release of one physical hold are all consumed.

local eaten = {}
local releasing = {}

function K.eat(key)
    if key == nil then return end
    eaten[key] = true
end

-- Answer for isKeyConsumed. Reading the release closes the hold.
function K.consumed(key)
    local mine = eaten[key] == true
    if releasing[key] then
        eaten[key] = nil
        releasing[key] = nil
    end
    return mine
end

function K.release(key)
    if eaten[key] then releasing[key] = true end
end

-- Every press that really reaches the root starts a fresh hold, so nothing an earlier hold left
-- behind can answer for it. Two ways a hold ends without its release ever coming here: another
-- element answered it (the calendar popup closes on the press and leaves the UI list), or the
-- engine never offered it at all -- a key taken inside a focused text box is answered through the
-- box's own callbacks, and while that box types, GameKeyboard.java:32-42 skips the release too.
local function startHold(key)
    eaten[key] = nil
    releasing[key] = nil
end

-- ---------- focus state ----------
-- Two roots can be on screen at once (the Economy Center and the administration window), but only
-- one of them holds the ring: this is that root, which descriptor of its list, and which control
-- inside it. A key offered to the other root never moves it (see ownsFocus), and neither does the
-- other root's render pass (see nativeRoot). `native` is set while an editable text box holds the
-- engine's own text focus, `ring` is false when the focus was moved for the mouse.

K.root = nil
K.activeRoot = nil
local st = { index = 0, sub = 0, control = nil, kind = nil, label = nil, native = nil, ring = true }

-- Modifiers, read the one way that still works while a text box types: the global isShiftKeyDown /
-- isCtrlKeyDown are GameKeyboard.isKeyDown, which answers false for *every* key while
-- Core.currentTextEntryBox is doing text entry (GameKeyboard.java:122-127,
-- LuaManager.java:7187-7200) -- so Shift+Tab out of a focused field would walk forwards. The raw
-- reader is org.lwjglx.input.Keyboard.isKeyDown, exposed to Lua (LuaManager.java:2491), ungated
-- (Keyboard.java:232-240, straight to GLFW) and what vanilla itself reads modifiers with
-- (ISSetKeybindDialog.lua:108-110). The gated globals stay as the fallback, for a build that does
-- not expose the raw one.
local function rawDown(left, right)
    if Keyboard.isKeyDown == nil or left == nil then return nil end
    -- the call sits inside the closure, so pcall is only ever handed plain Lua and never the
    -- exposed Java function itself
    local ok, down = pcall(function() return Keyboard.isKeyDown(left) or (right ~= nil and Keyboard.isKeyDown(right)) end)
    if not ok then return nil end
    return down == true
end

local function gatedDown(fn)
    if fn == nil then return false end
    local ok, down = pcall(fn)
    return ok and down == true
end

local function shiftDown()
    local raw = rawDown(Keyboard.KEY_LSHIFT, Keyboard.KEY_RSHIFT)
    if raw ~= nil then return raw end
    return gatedDown(isShiftKeyDown)
end

local function ctrlDown()
    local raw = rawDown(Keyboard.KEY_LCONTROL, Keyboard.KEY_RCONTROL)
    if raw ~= nil then return raw end
    return gatedDown(isCtrlKeyDown)
end

-- Use the same ungated modifier path for mouse selection and keyboard navigation.
function K.modifiers()
    return ctrlDown(), shiftDown()
end

-- Visible, enabled, still attached: a control that lost its page, its right or its window is not a
-- keyboard target, and never keeps the ring.
local function usable(c)
    if type(c) ~= "table" then return false end
    if c.javaObject == nil then return false end
    if c.getIsVisible and not c:getIsVisible() then return false end
    if c.isReallyVisible and not c:isReallyVisible() then return false end
    if c.enable == false then return false end
    if c.disabled == true then return false end
    return true
end

local function ready(root)
    if type(root) ~= "table" then return false end
    if root.getIsVisible and not root:getIsVisible() then return false end
    if root.isCollapsed == true then return false end
    return true
end

-- nil (not an empty list) means "no keyboard here": a modal dialog owns the window, or the page
-- offers nothing. The focus is dropped instead of pointing at something behind the dialog.
local function targets(root)
    if type(root) ~= "table" or root.keyboardTargets == nil then return nil end
    local ok, list = pcall(root.keyboardTargets, root)
    if not ok or type(list) ~= "table" then return nil end
    return list
end

-- The reachable controls of one descriptor, in the owner's order.
local function items(desc)
    local out = {}
    if type(desc) ~= "table" then return out end
    if desc.kind == "group" then
        if type(desc.controls) == "table" then
            for _, c in ipairs(desc.controls) do
                if usable(c) then out[#out + 1] = c end
            end
        end
    elseif usable(desc.control) then
        out[1] = desc.control
    end
    return out
end

-- The root is the *outermost* element that answers keyboardTargets: the Keyboard walks ancestors to
-- find it and never touches the framework or the window class. The walk cannot stop at the first
-- match -- a page inside the window answers keyboardTargets too, and its own list is only a part of
-- the window's, so stopping there would leave the focus on a root the key hooks never mention.
local function rootOf(control)
    local el = control
    local root = nil
    for _ = 1, 32 do
        if type(el) ~= "table" then return root end
        if el.keyboardTargets ~= nil then root = el end
        el = el.parent
    end
    return root
end

-- ---------- native text focus ----------

local function nativeFocused(e)
    if e == nil or e.isFocused == nil then return false end
    local ok, focused = pcall(e.isFocused, e)
    return ok and focused == true
end

-- Native text events and held-state UI events use two independent queues.
-- Compare their Java identities only: KeyEventQueue itself is not exposed to Lua.
-- GameKeyboard.java:189-192, Keyboard.java:257-270, KeyboardStateCache.java:18-27.
-- `nativeRoot` is the root whose box holds that focus: Core.currentTextEntryBox is one per game, so
-- this bookkeeping is global, and with two roots rendering every frame only its owner may reset it
-- (the other one's render would otherwise re-drain the queue under the box being typed into).
local wasOurs, handoff, firstQueue, rootPressKey, nativeRoot = false, false, nil, nil, nil
local function beginHandoff()
    if handoff then return end
    handoff, firstQueue = true, nil
end
local function drainHandoff()
    if not handoff then return true end
    local queue = GameKeyboard.getEventQueue()
    if queue == nil then
        handoff, firstQueue = false, nil
        EC.log("native keyboard queue unavailable")
        return false
    end
    if queue == firstQueue then return true end
    while Keyboard.next() do end
    if firstQueue == nil then firstQueue = queue else handoff = false end
    return true
end
local function triggerHeld(key)
    if st.triggerHold == nil then return false end
    if not rawDown(st.triggerHold) then st.triggerHold = nil; return false end
    return key == st.triggerHold
end

local function unfocusNative()
    local e = st.native
    st.native, st.triggerHold = nil, nil
    if e ~= nil and e.unfocus ~= nil then pcall(e.unfocus, e) end
end

-- Leaving an open combo takes its popup with it: a native popup floating over a page the ring has
-- already left is a trap. The popup is shared between combo boxes (ISComboBox.SharedPopup), so it
-- is only hidden while it still belongs to this one.
local function closeCombo()
    if st.kind ~= "combo" then return end
    local combo = st.control
    if type(combo) ~= "table" or combo.expanded ~= true then return end
    combo.expanded = false
    local popup = combo.popup
    if popup ~= nil and popup.parentCombo == combo and combo.hidePopup ~= nil then
        pcall(combo.hidePopup, combo)
    end
end

-- Everything the old focus still owns, given back before the ring moves on.
local function releaseFocus()
    closeCombo()
    unfocusNative()
end

-- The two callbacks the engine talks to a focused box through, wrapped once, ahead of whatever the
-- owner already put there (the search field's own onCommandEntered runs the query; it keeps running
-- first, this is only what happens to the keyboard afterwards).
local function hookEntry(root, e)
    if e.kbHooked then return end
    e.kbHooked = true
    local previousKey = e.onOtherKey
    e.onOtherKey = function(box, key)
        if triggerHeld(key) then return end
        if previousKey then previousKey(box, key) end
        K.entryKey(root, box, key)
    end
    -- Enter inside a focused box never reaches a key hook either: the engine calls onKeyEnter ->
    -- onCommandEntered (UITextBox2.java:1051-1080, :841-848, Core.java:2046-2047).
    local previousEnter = e.onCommandEntered
    e.onCommandEntered = function(box)
        if triggerHeld(Keyboard.KEY_RETURN) or triggerHeld(Keyboard.KEY_NUMPADENTER) then return end
        if previousEnter then previousEnter(box) end
        K.entryCommit(root, box)
    end
end

-- Hooks belong on an editable target while it is merely *on screen*, not only once the ring has
-- reached it: a click focuses the box inside the engine (UITextBox2.java:710-724) without telling
-- this file anything, and from that moment Tab / Escape / Enter are delivered to that box's
-- callbacks alone (GameKeyboard.java:32, Core.java:2044-2053). An unhooked box would swallow all
-- three and leave the player with no way out of the field. Idempotent per box, and the owner's
-- `focusable = false` veto is honoured here too.
local function observe(root, list)
    local ours = nil
    if type(list) ~= "table" then return nil end
    for _, desc in ipairs(list) do
        if type(desc) == "table" and desc.kind == "entry" and desc.focusable ~= false
            and type(desc.control) == "table" then
            hookEntry(root, desc.control)
            if usable(desc.control) and nativeFocused(desc.control) then ours = desc.control end
        end
    end
    return ours
end

-- Only an editable box the owner did not mark unfocusable is focused: see the read-only trap in the
-- header. `remember` has already run for this descriptor, so st.focusable is the owner's answer.
local function focusEntry(root, e)
    if type(e) ~= "table" or e.focus == nil or e.isEditable == nil then return false end
    if st.focusable == false then return false end
    local ok, editable = pcall(e.isEditable, e)
    if not ok or editable ~= true then return false end
    hookEntry(root, e)
    st.native = e
    pcall(e.focus, e)
    if rootPressKey ~= nil or not wasOurs then
        st.triggerHold = rootPressKey
        beginHandoff()
        if not drainHandoff() then unfocusNative(); return false end
    end
    return true
end

-- What the whole descriptor says about the control now under the ring. Two optional fields let an
-- owner state what its own widget cannot be asked:
--   focusable = false  the control must never be given the engine's text focus (a selectable but
--                      non-editable box would swallow every key -- see the read-only trap)
--   copyAll = button   Ctrl+C over this target presses that chip instead of copying here, so the
--                      owner's own copy path (message line, full record, clipboard failure text)
--                      stays the single implementation
local function remember(desc)
    st.kind = desc.kind or "button"
    st.label = desc.label
    st.focusable = desc.focusable
    st.copyAll = desc.copyAll
end

local function forget()
    st.index, st.sub = 0, 0
    st.control, st.kind, st.label, st.focusable, st.copyAll = nil, nil, nil, nil, nil
end

-- Which box the engine is really talking to. A hook fires for whatever box holds the text focus,
-- and that is often not the one the ring left behind: the player clicked straight into it, or the
-- ring gave the keyboard back (Escape, Enter) and the mouse then clicked the same field again.
-- Taking it over is allowed only for a box this root offers as an entry target *right now* and that
-- truly holds the focus, so a hidden field, a page that was switched away, or another window's box
-- is never adopted -- the key is left alone instead.
local function adopt(root, box)
    if st.native == box and K.root == root then return true end
    if type(box) ~= "table" or not ready(root) then return false end
    if not usable(box) or not nativeFocused(box) then return false end
    local list = targets(root)
    if list == nil then return false end
    for i, desc in ipairs(list) do
        if desc.kind == "entry" and desc.control == box and desc.focusable ~= false then
            releaseFocus()      -- an older ring may still hold a combo popup, or another box open
            K.root = root
            K.activeRoot = root
            st.index, st.sub, st.control = i, 1, box
            remember(desc)
            st.ring = true
            st.native = box
            return true
        end
    end
    return false
end

-- While the engine owns the keyboard these are the only ways back out: Core routes Escape and Tab
-- to the focused box's onOtherKey (Core.java:2049-2053). Tab additionally triggers the vanilla
-- SwitchChatStream event from Core.java:2053 -- an engine side effect of typing in any text box,
-- not something a mod can suppress from Lua.
function K.entryKey(root, box, key)
    if not adopt(root, box) then return end
    local k = Keyboard
    if key == k.KEY_TAB then
        K.step(root, shiftDown() and -1 or 1)
        -- Nothing eats Tab for us (Core.java:2052-2053 has no eatKeyPress): the step above may have
        -- given the keyboard back, and then the release of this hold reaches the root, where an
        -- unclaimed release is an OnKeyPressed leak. Escape is the opposite -- Core.java:2050 eats
        -- its press and GameKeyboard.java:38-39 swallows the release with it -- so claiming Escape
        -- would only leave a hold behind that no release ever closes.
        K.eat(key)
    elseif key == k.KEY_ESCAPE then
        if not (root.onEscape and root:onEscape()) then K.clear(root) end
    end
end

-- Enter finished the text: the field keeps the ring (so Tab carries on from here) but gives the
-- keyboard back, instead of leaving the player typing into a field they thought they had left.
-- Enter is not eaten for us either (Core.java:2046-2047), and the box has just let go, so this
-- hold's release does reach the root. onCommandEntered is not told which key produced it, so both
-- Enter keys are claimed; a later press of either starts a fresh hold anyway (startHold).
function K.entryCommit(root, box)
    if not adopt(root, box) then return end
    unfocusNative()
    K.eat(Keyboard.KEY_RETURN)
    K.eat(Keyboard.KEY_NUMPADENTER)
end

-- ---------- navigation ----------

local function land(root, list, index, fromEnd)
    local desc = list[index]
    -- Reveal only the next field, then apply the normal visibility and focus guards.
    if type(desc) == "table" then
        local owner, control = desc.scrollOwner, desc.control
        if usable(owner) and type(owner.scrollTo) == "function"
            and type(control) == "table" and control.parent == owner
            and control.javaObject ~= nil and control.enable ~= false and control.disabled ~= true then
            owner:scrollTo(control)
        end
    end
    local subs = items(desc)
    if #subs == 0 then return false end
    local sub = 1
    if fromEnd then sub = #subs end
    K.root = root
    K.activeRoot = root
    st.index, st.sub, st.control = index, sub, subs[sub]
    remember(desc)
    if st.kind == "entry" then focusEntry(root, st.control) end
    return true
end

-- Tab / Shift+Tab: the next descriptor that has anything reachable, wrapping once. Returns false
-- when the window offers no keyboard at all, so the key is left to whoever else wants it.
function K.step(root, delta)
    local list = targets(root)
    if list == nil then
        K.clear(root)
        return false
    end
    releaseFocus()
    local count = #list
    if count == 0 then return false end
    local start = 0
    if K.root == root and st.index >= 1 and st.index <= count then start = st.index end
    if start == 0 and delta < 0 then start = count + 1 end
    for offset = 1, count do
        local i = start + delta * offset
        while i < 1 do i = i + count end
        while i > count do i = i - count end
        if land(root, list, i, delta < 0) then
            st.ring = true
            return true
        end
    end
    forget()
    return false
end

-- Arrows inside one group (the tab strip, a chip row): wraps, never leaves the group.
local function moveInGroup(root, delta)
    local list = targets(root)
    if list == nil then return false end
    local subs = items(list[st.index])
    local count = #subs
    if count < 2 then return false end
    local i = st.sub + delta
    while i < 1 do i = i + count end
    while i > count do i = i - count end
    st.sub, st.control = i, subs[i]
    st.ring = true
    return true
end

-- ---------- kind handlers ----------

local function listKey(root, key)
    local list = st.control
    if list.ecKey and list:ecKey(key) then return true end
    local k = Keyboard
    local rows = list.items
    local count = 0
    if type(rows) == "table" then count = #rows end
    if count == 0 then return false end
    local current = nil
    if list.getSelectedIndex then current = list:getSelectedIndex() end
    if type(current) ~= "number" then current = nil end
    local stride = (list.rowHeight or 0) + (list.padding or 0)
    local page = 1
    if stride > 0 then page = math.max(1, math.floor((list.height or 0) / stride)) end
    local target
    if key == k.KEY_UP then target = (current or 1) - 1
    elseif key == k.KEY_DOWN then target = (current or 0) + 1
    elseif key == k.KEY_PRIOR then target = (current or 1) - page
    elseif key == k.KEY_NEXT then target = (current or 1) + page
    elseif key == k.KEY_HOME then target = 1
    elseif key == k.KEY_END then target = count
    else return false end
    if target < 1 then target = 1 end
    if target > count then target = count end
    list:setSelectedIndex(target)
    if list.scrollToIndex then list:scrollToIndex(target) end
    return true
end

-- Enter on a list row: the very handler a mouse press calls, once.
local function listActivate(list)
    if list.getSelectedIndex == nil or list.onSelect == nil then return false end
    local index = list:getSelectedIndex()
    if type(index) ~= "number" then return false end
    local item = type(list.items) == "table" and list.items[index] or nil
    if item == nil then return false end
    list.onSelect(list, item, index)
    return true
end

local function scrollBy(c, delta)
    if c.setScrollOffset and c.maxScrollOffset then
        local maxOffset = c:maxScrollOffset()
        if maxOffset <= 0 then return false end
        local offset = c.scrollOffset or 0
        if delta == "top" then offset = 0
        elseif delta == "bottom" then offset = maxOffset
        else offset = offset + delta end
        c:setScrollOffset(offset)
        return true
    end
    if c.setYScroll and c.getYScroll and c.getScrollHeight then
        local room = math.max(0, c:getScrollHeight() - (c.height or 0))
        if room <= 0 then return false end
        local y = c:getYScroll() or 0
        if delta == "top" then y = 0
        elseif delta == "bottom" then y = -room
        else y = y - delta end
        if y > 0 then y = 0 end
        if y < -room then y = -room end
        c:setYScroll(y)
        return true
    end
    return false
end

-- Ctrl+C over a text target. When the descriptor named a copy chip (`copyAll`), that chip is
-- pressed: the page already owns what "the whole record" means and what its failure reads like, so
-- the keyboard must not grow a second copy path beside it.
local function copyTarget(c)
    local chip = st.copyAll
    if usable(chip) and chip.forceClick ~= nil then
        pcall(chip.forceClick, chip)
        return true
    end
    if c.getInternalText == nil then return false end
    local ok, value = pcall(c.getInternalText, c)
    if not ok or type(value) ~= "string" or value == "" then return false end
    local copied = false
    if Clipboard and Clipboard.setClipboard then
        copied = pcall(Clipboard.setClipboard, value)
    end
    C.toast(getText(T .. (copied and "Kb_Copied" or "Kb_CopyFailed")))
    return true
end

-- Read-only text and scrolling content: scrolled and copied here, never handed to the engine's text
-- focus (a non-editable box would take the keyboard and handle nothing).
local function textKey(root, key)
    local c = st.control
    local k = Keyboard
    if key == k.KEY_C and ctrlDown() then return copyTarget(c) end
    local line = math.max(16, U.fontH.small + 4)
    local page = math.max(line, (c.height or 0) - line)
    local delta
    if key == k.KEY_UP then delta = -line
    elseif key == k.KEY_DOWN then delta = line
    elseif key == k.KEY_PRIOR then delta = -page
    elseif key == k.KEY_NEXT then delta = page
    elseif key == k.KEY_HOME then delta = "top"
    elseif key == k.KEY_END then delta = "bottom"
    else return false end
    return scrollBy(c, delta)
end

local function comboHighlight(combo)
    local popup = combo.popup
    local i = nil
    if popup then i = popup.selected end
    if type(i) ~= "number" then i = combo.selected end
    if type(i) ~= "number" then i = 1 end
    return i
end

-- The native combo through its own API only: Enter opens it, the arrows move the popup highlight,
-- Enter again commits it (forceClick is what fires onChange, exactly once), Escape drops the popup
-- and leaves the value alone.
local function comboKey(root, key)
    local combo = st.control
    local k = Keyboard
    local count = 0
    if combo.getOptionCount then count = combo:getOptionCount() end
    if key == k.KEY_RETURN or key == k.KEY_NUMPADENTER or key == k.KEY_SPACE then
        if count == 0 or combo.forceClick == nil then return false end
        pcall(combo.forceClick, combo)
        K.invalidate(root)
        return true
    end
    if combo.expanded ~= true then return false end
    local popup = combo.popup
    if popup == nil or popup.parentCombo ~= combo then return false end
    if key == k.KEY_ESCAPE then
        combo.expanded = false
        if combo.hidePopup then pcall(combo.hidePopup, combo) end
        return true
    end
    local i = comboHighlight(combo)
    if key == k.KEY_UP then i = i - 1
    elseif key == k.KEY_DOWN then i = i + 1
    elseif key == k.KEY_HOME then i = 1
    elseif key == k.KEY_END then i = count
    else return false end
    if i < 1 then i = 1 end
    if i > count then i = count end
    popup.selected = i
    if popup.ensureVisible then pcall(popup.ensureVisible, popup, i) end
    return true
end

local function activate(root)
    local c = st.control
    if not usable(c) then return false end
    if st.kind == "list" then return listActivate(c) end
    if st.kind == "entry" then return focusEntry(root, c) end
    if st.kind == "scroll" then return false end
    if c.forceClick == nil then return false end
    pcall(c.forceClick, c)
    K.invalidate(root)
    return true
end

-- ---------- public focus API ----------

-- Used by a page that swaps its view: the ring follows the new content instead of staying on a
-- control the view no longer paints. showRing == false moves the focus without painting it (the
-- mouse is driving; the next Tab starts from there).
function K.focusControl(control, showRing)
    if not usable(control) then return false end
    local root = rootOf(control)
    local list = targets(root)
    if list == nil then return false end
    for i, desc in ipairs(list) do
        local subs = items(desc)
        for j, c in ipairs(subs) do
            if c == control then
                releaseFocus()
                K.root = root
                K.activeRoot = root
                st.index, st.sub, st.control = i, j, control
                remember(desc)
                st.ring = showRing ~= false
                if st.kind == "entry" then focusEntry(root, control) end
                return true
            end
        end
    end
    return false
end

-- Give the ring back to the control a popup was opened from, but only while the keyboard is the one
-- driving: a mouse user must not suddenly grow a focus ring.
function K.refocus(control)
    if K.root == nil or st.control == nil then return false end
    return K.focusControl(control, true)
end

function K.focused()
    return st.control
end

function K.isKeyboardFocused(control)
    return control ~= nil and st.control == control and (st.ring == true or rootPressKey ~= nil)
end

-- Keep the actual control when dynamic descriptor groups move. Only choose a replacement
-- after the focused control is no longer reachable anywhere in the current target list.
function K.invalidate(window)
    local root = K.root
    if root == nil then return end
    if window ~= nil and window ~= root then return end
    local list = targets(root)
    if list == nil then
        K.clear(root)
        return
    end
    if st.native ~= nil and not usable(st.native) then unfocusNative() end
    local desc = list[st.index]
    local subs = items(desc)
    local found = 0
    for i, c in ipairs(subs) do
        if c == st.control then found = i end
    end
    if found == 0 and st.control ~= nil then
        for index, candidate in ipairs(list) do
            if index ~= st.index then
                for sub, control in ipairs(items(candidate)) do
                    if control == st.control then
                        st.index, st.sub = index, sub
                        remember(candidate)
                        return
                    end
                end
            end
        end
    end
    if #subs == 0 then
        forget()
        K.step(root, 1)
        return
    end
    if found == 0 then
        found = st.sub
        if found < 1 then found = 1 end
        if found > #subs then found = #subs end
    end
    local changed = st.control ~= subs[found]
    if changed then releaseFocus() end
    st.sub, st.control = found, subs[found]
    remember(desc)
    if changed and st.kind == "entry" then focusEntry(root, st.control) end
end

-- Cold path: mouse focus may not have reached an entry callback or even a render yet.
-- Only descendants of the window losing focus are touched, never another mod's text box.
function K.blurInputs(root)
    if root.getInternalText and root.isFocused and root:isFocused() then root:unfocus() end
    if root.childrenInOrder then
        for _, child in ipairs(root.childrenInOrder) do K.blurInputs(child) end
    end
end

-- The window hid, collapsed, switched tab, lost the admin right: no ring is left behind and no text
-- box keeps the engine's keyboard.
function K.clear(root)
    if root ~= nil and K.root ~= nil and root ~= K.root then return end
    local owner = root or K.root or K.activeRoot or nativeRoot
    if owner then K.blurInputs(owner) end
    releaseFocus()
    if root == nil or nativeRoot == root then
        nativeRoot, handoff, firstQueue, wasOurs = nil, false, nil, false
    end
    if root == nil then K.activeRoot = nil end
    K.root = nil
    forget()
    st.ring = true
end

-- UIElement.onMouseDown calls onFocus before dispatching to any child (UIElement.java:1056-1065).
-- Opening a window uses the same path, so the window brought forward owns the next Tab.
function K.onFocus(root)
    root:bringToTop()
    if K.activeRoot ~= root then K.clear() end
    K.activeRoot = root
    st.ring = false
end

-- Keep the last visible root alive until the activation key's release is consumed.
-- A release skipped by native text input is observed from GameKeyboard's sampled down state.
function K.close(root)
    if root.ecCloseKey ~= nil then return end
    if rootPressKey ~= nil and K.root == root then root.ecCloseKey = rootPressKey
    else root:setVisible(false) end
end

-- ---------- key hooks (the window forwards all four) ----------

local function validate(root)
    if K.root ~= nil and K.root ~= root then return end
    if st.native ~= nil and (not usable(st.native) or not nativeFocused(st.native)) then
        st.native = nil     -- the player clicked away: the keys come back to us, the ring stays
    end
    if st.control == nil then return end
    if targets(root) == nil then
        K.clear(root)
        return
    end
    if not usable(st.control) then K.invalidate(root) end
end

-- An overlay the root itself owns (an item picker, an unsaved-changes prompt) answers Escape before
-- the ring does, and only the root the engine handed the key to is asked: one window can never
-- close the popup of the other. The root says whether it really closed something.
local function escapeOverlay(root)
    if type(root) ~= "table" or root.onEscape == nil then return false end
    local ok, closed = pcall(root.onEscape, root)
    return ok and closed == true
end

-- The ring belongs to one root. The engine offers a key to the front window first and stops at the
-- first consumer (UIManager.java:1435-1466), so a background root only ever sees what the focused
-- one left alone -- Tab included, which would otherwise pull the ring out of a window that is busy
-- with a modal. It may start a ring of its own only while no other *ready* root holds one.
local function ownsInput(root)
    if not ready(K.activeRoot) then K.activeRoot = root end
    return K.activeRoot == root
end

local function handle(root, key)
    local k = Keyboard
    if key == k.KEY_ESCAPE and escapeOverlay(root) then return true end
    if key == k.KEY_TAB then
        return K.step(root, shiftDown() and -1 or 1) or (root.isModal and root:isModal()) or false
    end
    if st.control == nil or K.root ~= root then return false end
    local taken = false
    if st.kind == "combo" then taken = comboKey(root, key)
    elseif st.kind == "list" then taken = listKey(root, key)
    elseif st.kind == "scroll" or st.kind == "entry" then taken = textKey(root, key) end
    if taken then return true end
    if key == k.KEY_ESCAPE then
        K.clear(root)
        return true
    end
    if key == k.KEY_RETURN or key == k.KEY_NUMPADENTER or key == k.KEY_SPACE then
        if st.kind == "entry" and key == k.KEY_SPACE then return true end
        activate(root)
        return true             -- Enter/Space belong to the ring, not to the chat box behind it
    end
    if key == k.KEY_LEFT or key == k.KEY_UP then
        moveInGroup(root, -1)
    elseif key == k.KEY_RIGHT or key == k.KEY_DOWN then
        moveInGroup(root, 1)
    elseif key ~= k.KEY_HOME and key ~= k.KEY_END and key ~= k.KEY_PRIOR and key ~= k.KEY_NEXT then
        return false
    end
    -- A ring is up, so the navigation keys are the panel's whether or not this one moved anything:
    -- an arrow that fell through would walk the character around while the player reads a table.
    return true
end

function K.onKeyPress(root, key)
    if not ready(root) or not ownsInput(root) then return end
    startHold(key)
    if st.native ~= nil and nativeFocused(st.native) then return end
    validate(root)
    rootPressKey = key
    local handled = handle(root, key)
    rootPressKey = nil
    if handled then st.ring = true; K.eat(key) end
end

-- A held arrow keeps walking; a hold we did not take at the press is never taken later, and one we
-- did take stays consumed even when the action itself is no longer possible.
local repeatKeys
local function repeatable(key)
    if repeatKeys == nil then
        local k = Keyboard
        repeatKeys = {}
        for _, code in ipairs({ k.KEY_UP, k.KEY_DOWN, k.KEY_LEFT, k.KEY_RIGHT, k.KEY_PRIOR, k.KEY_NEXT }) do
            if code ~= nil then repeatKeys[code] = true end
        end
    end
    return repeatKeys[key] == true
end

function K.onKeyRepeat(root, key)
    if eaten[key] == nil then return end
    if not ownsInput(root) then return end
    if not repeatable(key) then return end
    if not ready(root) then return end
    if st.native ~= nil and nativeFocused(st.native) then return end
    validate(root)
    handle(root, key)
end

function K.onKeyRelease(root, key)
    K.release(key)
    if root.ecCloseKey == key then
        root.ecCloseKey = nil
        root:setVisible(false)
    end
end

function K.isKeyConsumed(root, key)
    return K.consumed(key)
end

-- ---------- the ring ----------

-- A control that paints its whole label needs no caption; one that paints none (an icon chip) or a
-- title its owner had to cut needs the full text somewhere, and this is the only place a keyboard
-- user can read it.
local function captionOf(c, label)
    local full = c.fullTitle
    local title = c.title
    if type(full) == "string" and full ~= "" and title ~= full then return full end
    if type(title) == "string" and title ~= "" then return nil end
    if type(c.tooltip) == "string" and c.tooltip ~= "" then return c.tooltip end
    return label
end

-- Called from the owner's render: the children had their pass by then (UIElement.java:1626-1630),
-- so the ring is painted over the control it marks and never under it.
--
-- This is also the one call that runs whether or not a ring exists, so it is where the editable
-- targets of what is on screen get their hooks (see observe): the mouse can focus a box at any
-- frame, and from then on the engine talks to that box only.
function K.render(el)
    if el.ecCloseKey ~= nil and not GameKeyboard.isKeyDownRaw(el.ecCloseKey) then
        el.ecCloseKey = nil
        el:setVisible(false)
        return
    end
    local ours = ready(el) and observe(el, targets(el)) or nil
    if ours then
        nativeRoot = el
        if not wasOurs then beginHandoff() end
        if not drainHandoff() then
            if st.native == ours then unfocusNative() else ours:unfocus() end
            ours = nil
            nativeRoot = nil
        end
        wasOurs = ours ~= nil
    elseif nativeRoot == el or not ready(nativeRoot) then
        -- the box that held the keyboard was this root's (or its window is gone): nobody is typing
        nativeRoot = nil
        handoff, firstQueue = false, nil
        wasOurs = false
    end
    if st.triggerHold and not rawDown(st.triggerHold) then st.triggerHold = nil end
    if K.root ~= el then return end
    local c = st.control
    if c == nil or not st.ring then return end
    if not usable(c) then
        K.invalidate(el)
        c = st.control
        if c == nil or not st.ring then return end
    end
    local x = c:getAbsoluteX() - el:getAbsoluteX()
    local y = c:getAbsoluteY() - el:getAbsoluteY()
    local w = c.width or 0
    local h = c.height or 0
    U.drawFocus(el, x, y, w, h)
    U.drawFocusCaption(el, x, y, w, h, captionOf(c, st.label))
end

return K
