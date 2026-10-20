-- A small, well-behaved vanilla addon (Lua 5.0, 1.12 API).
local f = CreateFrame("Frame", "GoodAddonFrame", UIParent)
f:RegisterEvent("VARIABLES_LOADED")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:SetScript("OnEvent", function()
    if event == "VARIABLES_LOADED" then
        GoodAddonDB = GoodAddonDB or { locked = false, shown = true }
    elseif event == "PLAYER_ENTERING_WORLD" then
        DEFAULT_CHAT_FRAME:AddMessage("Good Addon loaded for " .. (UnitName("player") or "?"))
    end
end)

SLASH_GOODADDON1 = "/goodaddon"
SlashCmdList["GOODADDON"] = function(msg)
    if msg == "lock" then
        GoodAddonDB.locked = true
    elseif msg == "unlock" then
        GoodAddonDB.locked = false
    elseif msg == "show" then
        f:Show()
    elseif msg == "hide" then
        f:Hide()
    elseif msg == "reset" then
        GoodAddonDB = { locked = false, shown = true }
    end
end
