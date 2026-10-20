--[[
    Defaults.lua  (Classic+ / Open Vanilla)
    Quality-of-life defaults. Each one is applied once (a new DEFAULTS_VERSION re-applies the
    whole set once to everyone) and afterwards it is a normal setting: change it in Interface
    Options or with /cpdefaults and it is never forced back.

        * instant quest text           QUEST_FADING_DISABLE = "1". That box is a plain global the
                                       client does not save, so we keep it ourselves and put it
                                       back on every login (and read it back at logout, so a change
                                       made in Interface Options sticks).
        * auto-accept quests           QUEST_DETAIL -> AcceptQuest; hold Shift to read instead
        * auto turn-in (off)           QUEST_PROGRESS -> CompleteQuest, QUEST_COMPLETE -> GetQuestReward
                                       when there is at most one reward to choose; Shift skips
        * auto loot                    autoLootDefault = 1, plus a Lua fallback: on LOOT_OPENED take
                                       every slot (Shift held = loot by hand). Bind-on-pickup items
                                       are confirmed for you only when you are not in a group.
        * camera zoom                  cameraDistanceMax 25 x cameraDistanceMaxFactor 2 = 50 yards
        * floating names               UnitNameNPC, UnitNamePlayer, UnitNameOwn = 1 (guild names and
                                       titles stay on)
        * nameplates off               V / Shift-V still toggle them; what you choose is remembered.
                                       1.12 forgets plate state at logout, so we restore it.
        * enemy plates in combat (off) Plates setting "combatOnly": enemy plates show when combat
                                       starts and hide when it ends.

    Lua 5.0 rules (1.12.1 client): no '#', no '%', handlers read this/event/arg1.
]]--

ClassicPlus_Defaults = ClassicPlus_Defaults or nil  -- SavedVariables (account-wide)

local DEFAULTS_VERSION = 2

local function Print(msg)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100Classic+|r " .. msg)
    end
end

local function setCVar(name, value)
    if SetCVar then pcall(SetCVar, name, value) end
end

local function getCVar(name)
    if not GetCVar then return nil end
    local ok, v = pcall(GetCVar, name)
    if ok then return v end
end

local function db()
    if type(ClassicPlus_Defaults) ~= "table" then ClassicPlus_Defaults = {} end
    return ClassicPlus_Defaults
end

-- -- Floating names & nameplates ----------------------------------------------------------

local NAME_CVARS = { "UnitNameNPC", "UnitNamePlayer", "UnitNameOwn" }

local function setNames(on)
    for _, c in ipairs(NAME_CVARS) do setCVar(c, on and "1" or "0") end
    if on then
        setCVar("UnitNamePlayerGuild", "1")
        setCVar("UnitNamePlayerPVPTitle", "1")
    end
end

local function namesOn()
    for _, c in ipairs(NAME_CVARS) do
        if getCVar(c) ~= "1" then return false end
    end
    return true
end

-- While we drive the plates ourselves (login, combat) the toggle is not the player's choice.
local driving = false

local function showPlates(on)
    driving = true
    if on then
        if ShowNameplates then ShowNameplates() end
        if ShowFriendNameplates then ShowFriendNameplates() end
        NAMEPLATES_ON, FRIENDNAMEPLATES_ON = 1, 1
    else
        if HideNameplates then HideNameplates() end
        if HideFriendNameplates then HideFriendNameplates() end
        NAMEPLATES_ON, FRIENDNAMEPLATES_ON = nil, nil
    end
    driving = false
end

local function showEnemyPlates(on)
    driving = true
    if on then
        if ShowNameplates then ShowNameplates() end
        NAMEPLATES_ON = 1
    else
        if HideNameplates then HideNameplates() end
        NAMEPLATES_ON = nil
    end
    driving = false
end

local function combatOnly()
    local W = WenillaCore
    return W and W.Setting and W:Setting("Plates", "combatOnly", false) and true or false
end

-- V and Shift-V call these globals (Bindings.xml); remember what the player chose.
local function wrapPlates()
    local function wrap(fname, key, value)
        local orig = getglobal(fname)
        if not orig then return end
        setglobal(fname, function(a1, a2)
            if not driving and type(ClassicPlus_Defaults) == "table" then ClassicPlus_Defaults[key] = value end
            return orig(a1, a2)
        end)
    end
    wrap("ShowNameplates", "plates", true)
    wrap("HideNameplates", "plates", false)
    wrap("ShowFriendNameplates", "friendPlates", true)
    wrap("HideFriendNameplates", "friendPlates", false)
end
wrapPlates()

-- -- One-time steps ----------------------------------------------------------------------

-- Each step: the version it arrived in, and what it does. v2 re-applies everything once.
local STEPS = {
    { v = 1, run = function(d)
        d.instantText = true
        setCVar("cameraDistanceMax", "25")
        setCVar("cameraDistanceMaxFactor", "2")
        setCVar("autoLootDefault", "1")
    end },
    { v = 2, run = function(d)
        d.instantText = true
        d.autoAccept = true
        if d.autoTurnIn == nil then d.autoTurnIn = false end
        d.lootFallback = true
        setCVar("cameraDistanceMax", "25")
        setCVar("cameraDistanceMaxFactor", "2")
        setCVar("autoLootDefault", "1")
        setNames(true)
        d.plates = false
        d.friendPlates = false
    end },
}

local function apply()
    local d = db()
    local done = d.version or 0
    if done >= DEFAULTS_VERSION then return end
    for _, step in ipairs(STEPS) do
        if step.v > done then step.run(d) end
    end
    d.version = DEFAULTS_VERSION
    Print("Instant quest text, auto-accept quests, auto loot, full camera zoom and floating names are on; "
        .. "nameplates start hidden (V shows them). /cpdefaults to change.")
end

-- Every login: the settings the client itself does not keep.
local function restore()
    local d = db()
    if d.instantText ~= false then QUEST_FADING_DISABLE = "1" else QUEST_FADING_DISABLE = "0" end
    local plates = d.plates and true or false
    if combatOnly() and not (UnitAffectingCombat and UnitAffectingCombat("player")) then plates = false end
    showEnemyPlates(plates)
    driving = true
    if d.friendPlates then
        if ShowFriendNameplates then ShowFriendNameplates() end
        FRIENDNAMEPLATES_ON = 1
    else
        if HideFriendNameplates then HideFriendNameplates() end
        FRIENDNAMEPLATES_ON = nil
    end
    driving = false
end

-- -- Quests --------------------------------------------------------------------------------

local function shift() return IsShiftKeyDown and IsShiftKeyDown() end

local function autoAcceptOn() return type(ClassicPlus_Defaults) == "table" and ClassicPlus_Defaults.autoAccept ~= false end
local function autoTurnInOn() return type(ClassicPlus_Defaults) == "table" and ClassicPlus_Defaults.autoTurnIn == true end

-- -- Loot ----------------------------------------------------------------------------------

local function autoLootOn() return getCVar("autoLootDefault") == "1" end
local function lootFallbackOn() return type(ClassicPlus_Defaults) == "table" and ClassicPlus_Defaults.lootFallback ~= false end

-- The Loot addon takes everything itself when it is on; the fallback is for the stock window.
local function lootAddonOn()
    local W = WenillaCore
    return W and W.refreshers and W.refreshers["Loot"] and W:IsActive("Loot") and true or false
end

local function solo()
    local party = GetNumPartyMembers and GetNumPartyMembers() or 0
    local raid = GetNumRaidMembers and GetNumRaidMembers() or 0
    return party == 0 and raid == 0
end

local function lootAll()
    if not (LootSlot and GetNumLootItems) then return end
    for i = GetNumLootItems(), 1, -1 do
        if GetLootSlotInfo(i) then LootSlot(i) end
    end
end

-- -- Events --------------------------------------------------------------------------------

local frame = CreateFrame("Frame", "ClassicPlusDefaultsFrame")
for _, e in ipairs({ "VARIABLES_LOADED", "PLAYER_ENTERING_WORLD", "PLAYER_LOGOUT", "QUEST_DETAIL", "QUEST_PROGRESS",
    "QUEST_COMPLETE", "LOOT_OPENED", "LOOT_BIND_CONFIRM", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED" }) do
    frame:RegisterEvent(e)
end
local entered = false
frame:SetScript("OnEvent", function()
    if event == "VARIABLES_LOADED" then
        db()
        apply()
        restore()
    elseif event == "PLAYER_ENTERING_WORLD" then
        if not entered then entered = true; restore() end
    elseif event == "PLAYER_LOGOUT" then
        -- the Interface Options box may have changed the global: keep what it says now
        if type(ClassicPlus_Defaults) == "table" then ClassicPlus_Defaults.instantText = (QUEST_FADING_DISABLE == "1") end
    elseif event == "QUEST_DETAIL" then
        if autoAcceptOn() and not shift() and AcceptQuest then AcceptQuest() end
    elseif event == "QUEST_PROGRESS" then
        if autoTurnInOn() and not shift() and IsQuestCompletable and IsQuestCompletable() and CompleteQuest then
            CompleteQuest()
        end
    elseif event == "QUEST_COMPLETE" then
        if autoTurnInOn() and not shift() and GetQuestReward then
            local n = GetNumQuestChoices and GetNumQuestChoices() or 0
            if n <= 1 then GetQuestReward(n) end
        end
    elseif event == "LOOT_OPENED" then
        -- autoLootDefault inverts Shift: with it on, Shift-looting opens the window instead
        if lootFallbackOn() and autoLootOn() and not shift() and not lootAddonOn() then lootAll() end
    elseif event == "LOOT_BIND_CONFIRM" then
        -- a bind-on-pickup item can only be yours when you are alone: confirm it for you
        if lootFallbackOn() and autoLootOn() and solo() and arg1 and LootSlot then
            LootSlot(arg1)
            if StaticPopup_Hide then StaticPopup_Hide("LOOT_BIND") end
        end
    elseif event == "PLAYER_REGEN_DISABLED" then
        if combatOnly() then showEnemyPlates(true) end
    elseif event == "PLAYER_REGEN_ENABLED" then
        if combatOnly() then showEnemyPlates(db().plates and true or false) end
    end
end)

-- -- /cpdefaults ---------------------------------------------------------------------------

local function onoff(b) return b and "|cff40ff40on|r" or "|cffff4040off|r" end

local function status()
    local d = db()
    local cam = tonumber(getCVar("cameraDistanceMaxFactor") or "1") or 1
    Print("instant quest text " .. onoff(QUEST_FADING_DISABLE == "1")
        .. ", auto-accept " .. onoff(autoAcceptOn())
        .. ", auto turn-in " .. onoff(autoTurnInOn())
        .. ", auto loot " .. onoff(autoLootOn())
        .. ", camera zoom x" .. cam
        .. ", floating names " .. onoff(namesOn())
        .. ", nameplates " .. onoff(d.plates)
        .. ", plates in combat only " .. onoff(combatOnly()))
    Print("/cpdefaults text | accept | turnin | loot | camera | names | plates | combat  toggles one;  /cpdefaults reset  re-applies all.")
end

SLASH_CPDEFAULTS1 = "/cpdefaults"
SlashCmdList["CPDEFAULTS"] = function(msg)
    msg = string.lower(msg or "")
    local d = db()
    if msg == "text" then
        if QUEST_FADING_DISABLE == "1" then QUEST_FADING_DISABLE = "0" else QUEST_FADING_DISABLE = "1" end
        d.instantText = (QUEST_FADING_DISABLE == "1")
    elseif msg == "accept" then
        d.autoAccept = not autoAcceptOn()
    elseif msg == "turnin" then
        d.autoTurnIn = not autoTurnInOn()
    elseif msg == "loot" then
        if autoLootOn() then setCVar("autoLootDefault", "0") else setCVar("autoLootDefault", "1") end
    elseif msg == "camera" then
        if (tonumber(getCVar("cameraDistanceMaxFactor") or "1") or 1) > 1 then
            setCVar("cameraDistanceMax", "15"); setCVar("cameraDistanceMaxFactor", "1")
        else
            setCVar("cameraDistanceMax", "25"); setCVar("cameraDistanceMaxFactor", "2")
        end
    elseif msg == "names" then
        setNames(not namesOn())
    elseif msg == "plates" then
        d.plates = not d.plates
        d.friendPlates = d.plates
        showPlates(d.plates)
    elseif msg == "combat" then
        local on = not combatOnly()
        if ClassicPlus_Manager and ClassicPlus_Manager.SetSetting then ClassicPlus_Manager:SetSetting("Plates", "combatOnly", on) end
        if on and not (UnitAffectingCombat and UnitAffectingCombat("player")) then showEnemyPlates(false)
        elseif not on then showEnemyPlates(d.plates and true or false) end
    elseif msg == "reset" then
        d.version = 0
        d.autoAccept = true
        d.autoTurnIn = false
        apply()
        restore()
    end
    status()
end
