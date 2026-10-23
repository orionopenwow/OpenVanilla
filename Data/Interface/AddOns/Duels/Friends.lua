--[[
    Friends.lua  (Duels)
    Bring a friend: "Invite a friend" shows your link (duels.openvanilla.app/?friend=<your name>) to copy
    and send. Whoever opens it plays straight in; once in the world the page types "/duels friend <you>"
    (realm/www/openvanilla.js), their addon whispers you a short request, yours invites them to your
    party and both of you add each other as friends. "/duels friend <name>" does the same by hand.
    Parties then queue together for 2v2 and 3v3 (the leader presses the button).
    Both factions can group, whisper and befriend on the Duels realm (AllowTwoSide.*).
    Lua 5.0 rules: no #, no %, this/arg1 in scripts.
]]--

local W = WenillaCore
local UI = W.UI
local D = Duels

local FR = {}
D.Friends = FR
FR.TAG = "[Duels] invite me"
FR.SITE = "https://duels.openvanilla.app/"

local function say(msg) if D.Say then D.Say(msg) else W.Print(msg) end end

local function cap(name)
    name = W.Trim(name or "")
    if name == "" then return "" end
    return string.upper(string.sub(name, 1, 1)) .. string.lower(string.sub(name, 2))
end

function FR.Link(name) return FR.SITE .. "?farclip=177&friend=" .. (name or UnitName("player") or "") end

local win
function FR.ShowLink()
    if not win then
        win = UI.Window("DuelsInviteFrame", { width = 360, height = 150, title = "Invite a friend", skin = true,
            icon = "Interface\\Icons\\INV_Letter_15", point = { "CENTER", UIParent, "CENTER", 0, 120 } })
        if UISpecialFrames then table.insert(UISpecialFrames, "DuelsInviteFrame") end
        win.text = UI.Label(win, 10, UI.MUTED)
        win.text:SetPoint("TOPLEFT", win, "TOPLEFT", 14, -32)
        win.text:SetWidth(332)
        win.text:SetText("Send this link. Your friend plays free in the browser and lands in your party here. Ctrl+C copies it.")
        win.link = UI.SearchBox(win, { name = "DuelsInviteLink", width = 332, placeholder = "" })
        win.link:SetPoint("TOPLEFT", win, "TOPLEFT", 14, -70)
        win.note = UI.Label(win, 9, UI.MUTED)
        win.note:SetPoint("TOPLEFT", win, "TOPLEFT", 14, -98)
        win.note:SetWidth(332)
        win.note:SetText("Friend links are for playing together: unranked 2v2 and 3v3, or a practice duel. Ranked duels stay in the public queue.")
    end
    win.link:SetText(FR.Link())
    win:Show()
    if win.link.SetFocus then win.link:SetFocus() end
    if win.link.HighlightText then win.link:HighlightText() end
    return win
end

-- ask `name` for an invite (the link, or by hand)
function FR.Join(name)
    name = cap(name)
    if name == "" then say("/duels friend <name>: asks them for a party invite.") return false end
    if name == UnitName("player") then say("That's your own link: send it to a friend.") return false end
    SendChatMessage(FR.TAG, "WHISPER", nil, name)
    if AddFriend then AddFriend(name) end
    say("Asked " .. name .. " for a party invite. They're on your friends list now.")
    return true
end

-- a friend asked: invite them and befriend them (only the exact request, from a player)
local ev = CreateFrame("Frame")
ev:RegisterEvent("CHAT_MSG_WHISPER")
ev:SetScript("OnEvent", function()
    if not D.on or arg1 ~= FR.TAG or not arg2 or arg2 == "" then return end
    local who = arg2
    if GetNumPartyMembers and GetNumPartyMembers() >= 4 then
        SendChatMessage("[Duels] my party is full", "WHISPER", nil, who)
        return
    end
    if InviteByName then InviteByName(who) end
    if AddFriend then AddFriend(who) end
    say(who .. " came by your link: invited to your party and added as a friend.")
end)
