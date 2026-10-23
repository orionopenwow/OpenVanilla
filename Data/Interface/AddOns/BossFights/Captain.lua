--[[
    Captain.lua  (Open Vanilla / Boss Fights)
    Bot Captain: a small panel for the raid's leader in a Boss Fights run with bots in it (the realm's "rbots,<n>",
    patch 0054). Each button sends the bots' own chat commands (the playerbots module's ChatCommandHandlerStrategy)
    in raid chat, where the bots take orders from their master, the run's person:
      Stack on me       follow, then formation near
      Spread            formation circle
      Attack my target  attack            (everyone on the leader's target)
      Tank my target    tank attack       (the tanks take it)
      Stop              co +passive       (they stop attacking)
      Resume            co -passive
      Follow            follow
      Stay              stay
    The panel shows only then (it hides out of a run, or with no bots); /captain shows or hides it.
    Lua 5.0 rules: no #, no %, this/arg1 in scripts.
]]--

local W = WenillaCore
local UI = W and W.UI

BossFightsCaptain = BossFightsCaptain or {}
local C = BossFightsCaptain

C.hidden = false        -- the leader closed it this run
C.lastRun = nil

-- the buttons, in order: label, the command lines, the tooltip
C.ORDERS = {
    { "Stack on me", { "follow", "formation near" }, "Your bots come to you and stand close." },
    { "Spread", { "formation circle" }, "Your bots spread out in a circle around you." },
    { "Attack my target", { "attack" }, "Every bot attacks your target." },
    { "Tank my target", { "tank attack" }, "Your tank bots take your target." },
    { "Stop", { "co +passive" }, "Your bots stop attacking (Resume puts them back)." },
    { "Resume", { "co -passive" }, "Your bots fight again." },
    { "Follow", { "follow" }, "Your bots follow you." },
    { "Stay", { "stay" }, "Your bots stay where they stand." },
}

-- the chat the bots hear: raid when in a raid, else party
function C.Channel()
    if GetNumRaidMembers and GetNumRaidMembers() > 0 then return "RAID" end
    if GetNumPartyMembers and GetNumPartyMembers() > 0 then return "PARTY" end
    return nil
end

function C.Leader()
    if GetNumRaidMembers and GetNumRaidMembers() > 0 then return IsRaidLeader and IsRaidLeader() end
    return IsPartyLeader and IsPartyLeader()
end

-- Send one order's lines; false (and a word why) when there is nobody to hear it.
function C.Order(i)
    local o = C.ORDERS[i]
    if not o then return false end
    local ch = C.Channel()
    if not ch then
        if W and W.Print then W.Print("|cffff8000Bot Captain:|r you're not in a group with bots.") end
        return false
    end
    if (o[2][1] == "attack" or o[2][1] == "tank attack") and not (UnitExists and UnitExists("target")) then
        if W and W.Print then W.Print("|cffff8000Bot Captain:|r pick a target first.") end
        return false
    end
    for _, line in ipairs(o[2]) do SendChatMessage(line, ch) end
    C.lastOrder = o[1]
    return true
end

-- In a Boss Fights run with bots, as its leader.
function C.Wanted()
    local B = BossFights
    if not (B and B.on and B.run) then return false end
    if (B.run.bots or 0) < 1 then return false end
    return C.Leader() and true or false
end

function C.Build()
    if C.win then return C.win end
    local win
    if UI and UI.Window then
        win = UI.Window("BossFightsCaptainFrame", { width = 176, height = 236, title = "Bot Captain", skin = true,
            icon = "Interface\\Icons\\INV_Misc_Horn_01", point = { "RIGHT", UIParent, "RIGHT", -60, 40 },
            onClose = function() C.hidden = true end })
    else
        win = CreateFrame("Frame", "BossFightsCaptainFrame", UIParent)
        win:SetWidth(176); win:SetHeight(236)
        win:SetPoint("RIGHT", UIParent, "RIGHT", -60, 40)
    end
    win.buttons = {}
    for i, o in ipairs(C.ORDERS) do
        local idx = i
        local b
        if UI and UI.Button then
            b = UI.Button(win, o[1], 156, 22, function() C.Order(idx) end)
        else
            b = CreateFrame("Button", nil, win)
            b:SetWidth(156); b:SetHeight(22)
            b:SetScript("OnClick", function() C.Order(idx) end)
        end
        b:SetPoint("TOP", win, "TOP", 0, -30 - (i - 1) * 25)
        local tip = o[3]
        b:SetScript("OnEnter", function()
            GameTooltip:SetOwner(this, "ANCHOR_LEFT")
            GameTooltip:SetText(o[1])
            GameTooltip:AddLine(tip, 0.9, 0.9, 0.9, 1)
            GameTooltip:AddLine("Sent in raid chat; your bots obey you.", 0.6, 0.6, 0.6, 1)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        win.buttons[i] = b
    end
    win:Hide()
    C.win = win
    return win
end

-- every second: shown in a run with bots (unless closed this run), hidden otherwise
function C.Update()
    local B = BossFights
    local runId = B and B.run and B.run.id
    if runId ~= C.lastRun then
        C.lastRun = runId
        C.hidden = false          -- a new run: the panel may show again
    end
    if C.Wanted() and not C.hidden then
        C.Build():Show()
    elseif C.win then
        C.win:Hide()
    end
end

local tick = CreateFrame("Frame", "BossFightsCaptainTick")
local acc = 0
tick:SetScript("OnUpdate", function()
    acc = acc + (arg1 or 0)
    if acc < 1 then return end
    acc = 0
    C.Update()
end)

SLASH_BOSSFIGHTSCAPTAIN1 = "/captain"
SlashCmdList["BOSSFIGHTSCAPTAIN"] = function()
    if C.win and C.win:IsShown() then
        C.win:Hide()
        C.hidden = true
    elseif C.Wanted() then
        C.hidden = false
        C.Build():Show()
    elseif W and W.Print then
        W.Print("|cffff8000Bot Captain:|r only in a Boss Fights run with bots, as its leader.")
    end
end
