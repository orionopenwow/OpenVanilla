--[[
    UnitMenu.lua  (Classic+ / Open Vanilla)
    The stock right-click unit menu (Whisper, Invite, Inspect, Trade, ...) for frames that are
    not Blizzard's own: our unit frames, nameplates and chat names.

    The stock PlayerFrameDropDown / TargetFrameDropDown / PartyMemberFrameNDropDown get their
    initialise function in Blizzard's PlayerFrame / TargetFrame / PartyFrame OnLoad. A frame
    that replaces those (the UI Repack's) and toggles the stock dropdown opens an empty menu.
    So every caller here gets its own named dropdown, initialised the way 1.12 FrameXML does it
    (PlayerFrameDropDown_Initialize, TargetFrameDropDown_Initialize, ...): UIDropDownMenu_Initialize
    with an init function that calls UnitPopup_ShowMenu with the right menu for the unit.

        W.UnitMenu.Open(unit [, anchor])   SELF, PET, PARTY, RAID_PLAYER, PLAYER or (NPCs) TARGET
        W.UnitMenu.OpenName(name)          the FRIEND menu for a name (chat links)
        W.UnitMenu.Which(unit)             the menu type Open would use

    Chat names: FriendsFrame_ShowDropdown opens FriendsDropDown, which FriendsFrame.xml defines.
    When that frame (or the function) is missing, the same menu opens from our own dropdown.

    Lua 5.0 rules (1.12.1 client): no '#', no '%', handlers read this/event/arg1.
]]--

local W = WenillaCore
local UM = {}
W.UnitMenu = UM

local DROPDOWN = "ClassicPlusUnitDropDown"

-- NPCs: 1.12 offers only the raid icons for them (TargetFrameDropDown_Initialize). Ours adds
-- Cancel so the menu is never a bare sub-menu arrow.
local function ensureMenus()
    if not (UnitPopupMenus and UnitPopupButtons) then return end
    if not UnitPopupMenus["TARGET"] then
        UnitPopupMenus["TARGET"] = { "RAID_TARGET_ICON", "CANCEL" }
    end
    if not UnitPopupMenus["RAID_PLAYER"] then
        -- the player rows, then the raid leader's rows (RAID ends with Cancel)
        local m = {}
        for _, v in ipairs({ "WHISPER", "INSPECT", "TRADE", "FOLLOW", "DUEL", "RAID_TARGET_ICON" }) do
            if UnitPopupButtons[v] then table.insert(m, v) end
        end
        for _, v in ipairs(UnitPopupMenus["RAID"] or { "CANCEL" }) do table.insert(m, v) end
        UnitPopupMenus["RAID_PLAYER"] = m
    end
    -- Persona's "View Persona" joins the player menus it knows; the raid one too. Report.lua's
    -- "Report..." joins the menus for other players (never SELF).
    local EXTRA = {
        { "PERSONA_VIEW", { "RAID_PLAYER", "PARTY", "PLAYER", "FRIEND", "SELF" } },
        { "WNL_REPORT", { "RAID_PLAYER", "PARTY", "PLAYER", "FRIEND" } },
    }
    for _, x in ipairs(EXTRA) do
        local key = x[1]
        if UnitPopupButtons[key] then
            for _, which in ipairs(x[2]) do
                local m = UnitPopupMenus[which]
                if m then
                    local has = false
                    for _, v in ipairs(m) do if v == key then has = true end end
                    if not has then
                        -- above Cancel and above the entries other addons put there (View Persona,
                        -- Compare achievements), so theirs stay "just above Cancel"
                        local pos = table.getn(m) + 1
                        for i, v in ipairs(m) do
                            if v == "CANCEL" or (key == "WNL_REPORT" and (v == "PERSONA_VIEW" or v == "ACHIEVEMENTS_COMPARE")) then
                                pos = i
                                break
                            end
                        end
                        table.insert(m, pos, key)
                    end
                end
            end
        end
    end
end

local function inRaid(unit)
    if not (GetNumRaidMembers and GetNumRaidMembers() > 0) then return false end
    if string.find(unit, "^raid%d") then return true end
    local name = UnitName(unit)
    for i = 1, GetNumRaidMembers() do
        if UnitName("raid" .. i) == name then return true end
    end
    return false
end

local function inParty(unit)
    if string.find(unit, "^party%d") then return true end
    local name = UnitName(unit)
    for i = 1, 4 do
        if UnitExists("party" .. i) and UnitName("party" .. i) == name then return true end
    end
    return false
end

function UM.Which(unit)
    if not unit or not UnitExists(unit) then return nil end
    if UnitIsUnit(unit, "player") then return "SELF" end
    if UnitExists("pet") and UnitIsUnit(unit, "pet") then return "PET" end
    if UnitIsPlayer(unit) then
        if inRaid(unit) then return "RAID_PLAYER" end
        if inParty(unit) then return "PARTY" end
        return "PLAYER"
    end
    return "TARGET"
end

local dropdown
local function dd()
    if dropdown then return dropdown end
    dropdown = CreateFrame("Frame", DROPDOWN, UIParent, "UIDropDownMenuTemplate")
    dropdown:Hide()
    return dropdown
end

local function init()
    local f = dropdown
    if not (f and f.cpWhich and UnitPopup_ShowMenu) then return end
    UnitPopup_ShowMenu(f, f.cpWhich, f.cpUnit, f.cpName)
end

local function open(which, unit, name, anchor)
    if not (UIDropDownMenu_Initialize and ToggleDropDownMenu and UnitPopup_ShowMenu) then return false end
    ensureMenus()
    local f = dd()
    local same = f.cpWhich == which and f.cpUnit == unit and f.cpName == name
    if not same and DropDownList1 and DropDownList1:IsShown() then
        if CloseDropDownMenus then CloseDropDownMenus() end
    end
    f.cpWhich, f.cpUnit, f.cpName = which, unit, name
    UIDropDownMenu_Initialize(f, init, "MENU")
    ToggleDropDownMenu(1, nil, f, anchor or "cursor")
    return true
end

-- The unit menu for a unit token ("player", "target", "party2", "pet", ...).
function UM.Open(unit, anchor)
    local which = UM.Which(unit)
    if not which then return false end
    return open(which, unit, nil, anchor)
end

-- The FRIEND menu for a player name (chat names, lists without a unit).
function UM.OpenName(name, anchor)
    if not name or name == "" then return false end
    return open("FRIEND", nil, name, anchor)
end

-- Chat names: keep the stock path when FriendsFrame.xml is there, ours otherwise.
local function hookChatNames()
    if UM.chatHooked then return end
    UM.chatHooked = true
    local orig = FriendsFrame_ShowDropdown
    FriendsFrame_ShowDropdown = function(name, connected, a3, a4)
        if orig and FriendsDropDown and (FriendsFrameDropDown_Initialize or FriendsDropDown.initialize) then
            ensureMenus()
            return orig(name, connected, a3, a4)
        end
        if connected then UM.OpenName(name) end
    end
end
hookChatNames()

local ev = CreateFrame("Frame")
ev:RegisterEvent("VARIABLES_LOADED")
ev:SetScript("OnEvent", function() ensureMenus() end)
