-- MinidoracatEconomyFor42 -- keyboard and controller focus for the mod's windows.
--
-- The engine that lived here moved into MinidoracatUIFor42 as UI.Focus (API rev 10,
-- CAPABILITIES.focus): one session has exactly one focus engine and one held-key ledger, so a
-- second copy here would fight the framework's own windows for every key, and the controller
-- support grew on top of the same focus state there. C.Keyboard *is* that table (not a wrapper),
-- so every window, page and the `Keys.activeRoot` reads keep working unchanged.
--
-- The descriptor contract (kinds, focusable / copyAll / frame / scrollOwner, control:onFocusKey,
-- root:onEscape / isModal / onFocusShoulder) and every engine reference are documented once, in
-- the header of MinidoracatUI/Focus.lua.
--
-- Load order: this mod's client files load before MinidoracatUI's (path order), hence the require.
-- A framework without the capability leaves C.Keyboard nil; U.init() then refuses to build any
-- window (ECWidgets), so nothing reaches it.

if not MinidoracatEconomy or not MinidoracatEconomy.Client or not MinidoracatEconomy.Client.UI then
    require "MinidoracatEconomy/ECWidgets"
end
local C = MinidoracatEconomy.Client

if not (MinidoracatUI and MinidoracatUI.v1 and MinidoracatUI.v1.Focus) then
    pcall(require, "MinidoracatUI/Focus")
end
local ui = MinidoracatUI and MinidoracatUI.v1
C.Keyboard = ui and ui.CAPABILITIES and ui.CAPABILITIES.focus == true and ui.Focus or nil

return C.Keyboard
