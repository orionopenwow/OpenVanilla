--[[
    Automation.lua  -  Quests: chimes, banners and the optional automatic turn-in.

    Chimes (on by default): a soft ping when an objective is done, the quest-complete sound and a
    banner when a whole quest is ready to turn in.
    Automatic turn-in (off by default): finished quests are handed in when you talk to the NPC,
    but only when there is one reward to take, or "Pick the best reward" is on (then the
    biggest upgrade for you is chosen, see LogDetail.lua).
]]--

local W = WenillaCore
local UI = W.UI
local Q = Compass

Q:Listen("ObjectiveDone", function(q, o)
    if not Q:Get("chimes") or q.complete then return end
    if PlaySound then PlaySound("MapPing") end
end)

Q:Listen("QuestComplete", function(q)
    if not Q:Get("chimes") then return end
    if PlaySound then PlaySound("igQuestListComplete") end
    UI.Toast({ icon = "Interface\\Icons\\INV_Misc_Note_01", title = "Quest complete", text = q.title,
        color = { 0.45, 1, 0.45 }, duration = 4, onClick = function() Q.Log:Open(q.key) end })
end)

-- The suite's Defaults (WenillaCore/Defaults.lua) has its own auto turn-in for quests with at
-- most one reward; when that is on it does the simple cases and this file only adds auto-pick.
local function defaultsTurnIn() return type(ClassicPlus_Defaults) == "table" and ClassicPlus_Defaults.autoTurnIn == true end
local function wanted() return Q:Get("autoTurnIn") and not (IsShiftKeyDown and IsShiftKeyDown()) end

-- Talking to the NPC with a finished quest: "Continue" on the progress page.
Q:On("QUEST_PROGRESS", function()
    if not wanted() or defaultsTurnIn() then return end
    if IsQuestCompletable and IsQuestCompletable() and CompleteQuest then CompleteQuest() end
end)

-- The reward page: take the single reward, or the best one when auto-pick is on.
Q:On("QUEST_COMPLETE", function()
    if not wanted() then return end
    local n = GetNumQuestChoices and GetNumQuestChoices() or 0
    local title = GetTitleText and GetTitleText() or "the quest"
    if n <= 1 then
        if defaultsTurnIn() then return end
        GetQuestReward(n)          -- 1 for the one reward, 0 when there is none (as the stock button)
        Q:Print("Turned in \"" .. title .. "\".")
    elseif Q:Get("autoPick") then
        local pick = Q:BestChoice(n, function(i)
            local name, texture, count, quality, usable = GetQuestItemInfo("choice", i)
            return name, texture, count, quality, usable, GetQuestItemLink and GetQuestItemLink("choice", i)
        end)
        local name = GetQuestItemInfo("choice", pick)
        GetQuestReward(pick)
        Q:Print("Turned in \"" .. title .. "\" and took " .. (name or "the best reward") .. ".")
    else
        Q:Print("\"" .. title .. "\" has " .. n .. " rewards to choose from, so it was not turned in automatically.")
    end
end)
