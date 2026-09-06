-- 階段 A 拋棄式原型 A11：建造選單的 OnAddToMenu 回呼（CraftRecipe.java:379-380；呼叫點 ISRecipeScrollingListBox.lua:344-347）。
-- 只在 client 有意義（getAccessLevel 讀 GameClient.connection，LuaManager.java:4435-4436）；刻意不理會 param.shouldShowAll。
function MinidoracatEconomyProto_AdminOnly(param)
    if isServer() then return false end
    local ok, level = pcall(getAccessLevel)
    local show = ok and level == "admin"
    print("[MinidoracatEconomyFor42][A11] OnAddToMenu called; accessLevel=" .. tostring(ok and level or "n/a") .. " show=" .. tostring(show))
    return show
end
