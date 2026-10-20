--[[
    Support.lua  (WenillaCore)
    The stock help window ("WoW Customer Support" / "Petition a Game Master") says how help works
    in Open Vanilla instead of Blizzard's 2006 text and wow-europe.com links.

    Tickets sent from it ("Issues that GMs can assist with" -> the stock ticket form) already reach
    the staff: Herald's support desk (bot/herald_support.py) posts each one to #support-queue in
    Discord with fix buttons. This file only changes the words, matched by the stock text, so a
    client in another language (or a later stock layout) is simply left as it was.
]]--

local W = WenillaCore
local S = {}
W.Support = S

-- stock text (start of the line, plain find) -> ours
S.TEXT = {
    { "WoW Customer Support", "Open Vanilla Support" },
    { "Petition a Game Master", "Getting help in Open Vanilla" },
    { "Game Masters are normally", "Real people help here, and they work from our Discord. Pick the quickest way for what happened:" },
    { "Game Hints", "Stuck, dead, or a quest that won't finish?" },
    { "When it comes to quests", "Press the button below and send a ticket. It goes straight to the staff in Discord, who can move you, revive you or fix the quest, and you get an answer in game." },
    { "Meta-Game Hints", "Found a bug?" },
    { "This includes information about", "Use the blue bug button beside the chat (or type /bug). It goes to #bug-reports in Discord, with where you are." },
    { "PvP", "Someone bothering you?" },
    { "Most PVP issues", "Right-click their name and choose Report... The moderators see it with the chat around it." },
    { "Additionally, we encourage", "Questions about playing are answered fastest in the guide, openvanilla.app/manual, and by other players in Discord, #help." },
    { "Issues that GMs can assist with", "Send a ticket to the staff" },
}
-- lines that only carried Blizzard's links
S.BLANK = { "wow-europe.com/", "worldofwarcraft.com/", "blizzard.com/" }

local function startsWith(s, p) return string.sub(s, 1, string.len(p)) == p end

local function rewriteText(t)
    if not t or t == "" then return nil end
    for _, pair in ipairs(S.TEXT) do
        if startsWith(t, pair[1]) and t ~= pair[2] then return pair[2] end
    end
    for _, link in ipairs(S.BLANK) do
        if string.find(t, link, 1, 1) and not string.find(t, " ", 1, 1) then return "" end
        if string.find(t, link, 1, 1) and string.len(t) < 80 then return "" end
    end
    return nil
end

-- Walk a frame and its children; change every font string (and button label) that matches.
function S.Rewrite(frame, depth)
    if not frame then return 0 end
    depth = depth or 0
    if depth > 6 then return 0 end
    local n = 0
    local regions = frame.GetRegions and { frame:GetRegions() } or {}
    for _, r in ipairs(regions) do
        if r.GetText and r.SetText and r.GetObjectType and r:GetObjectType() == "FontString" then
            local new = rewriteText(r:GetText())
            if new then r:SetText(new); n = n + 1 end
        end
    end
    if frame.GetText and frame.SetText and frame.GetObjectType and frame:GetObjectType() == "Button" then
        local new = rewriteText(frame:GetText())
        if new then frame:SetText(new); n = n + 1 end
    end
    local kids = frame.GetChildren and { frame:GetChildren() } or {}
    for _, k in ipairs(kids) do n = n + S.Rewrite(k, depth + 1) end
    return n
end

function S.Hook()
    local f = HelpFrame
    if not f or S.hooked then return end
    S.hooked = true
    S.Rewrite(f)
    local orig = f:GetScript("OnShow")
    f:SetScript("OnShow", function()
        if orig then orig() end
        S.Rewrite(HelpFrame)
    end)
end

S.Hook()
-- HelpFrame comes with the stock UI; a client that builds it later gets it on first login too
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function() S.Hook() end)
