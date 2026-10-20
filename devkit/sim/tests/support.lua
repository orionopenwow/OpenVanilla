-- WenillaCore/Support.lua: the stock help window explains help in Open Vanilla.
local T, api = ...

-- a stand-in for the stock HelpFrame's home page, with its 1.12 enUS text
local function helpFrame(env)
    local f = env.CreateFrame("Frame", "HelpFrame", env.UIParent)
    local function fs(parent, text) local s = parent:CreateFontString(nil, "ARTWORK"); s:SetText(text); return s end
    f.title = fs(f, "WoW Customer Support")
    local home = env.CreateFrame("Frame", "HelpFrameHome", f)
    home.head = fs(home, "Petition a Game Master")
    home.body = fs(home, "Game Masters are normally available to assist you 24 hours a day, 7 days a week.")
    home.h1 = fs(home, "Game Hints")
    home.t1 = fs(home, "When it comes to quests, Non-Player Characters (NPCs), item information...")
    home.h3 = fs(home, "PvP")
    home.url = fs(home, "http://www.wow-europe.com/en/policy/")
    home.more = fs(home, "Additionally, we encourage all players to first utilize the forums")
    home.other = fs(home, "Cancel")
    local b = env.CreateFrame("Button", "HelpFrameGMButton", home)
    b:SetText("Issues that GMs can assist with")
    f.home, f.button = home, b
    f:Hide()
    return f
end

T.test("Support: the help window says how help works here, and keeps its buttons", function()
    local env = T.addon("WenillaCore")
    local f = helpFrame(env)
    T.no(env.WenillaCore.Support.hooked, "no help window at load")
    api.fire(env, "PLAYER_LOGIN")                      -- the catch-up hook
    f:Show()
    T.eq(f.title:GetText(), "Open Vanilla Support")
    T.eq(f.home.head:GetText(), "Getting help in Open Vanilla")
    T.has(f.home.body:GetText(), "Discord")
    T.has(f.home.t1:GetText(), "ticket")
    T.eq(f.home.h3:GetText(), "Someone bothering you?")
    T.eq(f.home.url:GetText() or "", "", "Blizzard's link is gone")
    T.has(f.home.more:GetText(), "openvanilla.app/manual")
    T.eq(f.home.other:GetText(), "Cancel", "other text untouched")
    T.eq(f.button:GetText(), "Send a ticket to the staff")
    f:Hide(); f:Show()
    T.eq(f.title:GetText(), "Open Vanilla Support", "still right the second time")
end)

T.test("Support: a client without the help window is fine", function()
    local env = T.addon("WenillaCore")
    T.eq(env.WenillaCore.Support.Rewrite(nil), 0)
end)
