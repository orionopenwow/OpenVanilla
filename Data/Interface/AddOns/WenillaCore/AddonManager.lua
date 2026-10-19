--[[
    AddonManager.lua
    The Addons & Options window (/addons, Esc menu > AddOns): every Classic+ addon in a list on
    the left with its on/off switch, its settings on the right as switches, choices and sliders.

    Addons describe their settings with W:RegisterSchema(id, schema) (see WenillaCore.lua); the
    first eleven addons' schemas live below so their files stay as they were. Defaults come from
    each schema's `defaults`, plus the table below.
]]--

ClassicPlus_Manager = ClassicPlus_Manager or {}
local M = ClassicPlus_Manager
local W = WenillaCore
local UI = W.UI

local MAX_SWITCHES, MAX_CHOICES, MAX_SLIDERS = 16, 4, 3
local NAV_ROW, NAV_H = 22, 386

-- -- Defaults ------------------------------------------------------------------------------

local DEFAULT_SETTINGS = {
    Meters = { enabled = true, maxRows = 5, showDps = true, classColors = true, inspectOnClick = true },
    Quests = { enabled = true, showRing = true, showCoords = true, showObjectives = true, showGivers = true, showTurnins = true },
    Threat = { enabled = true, pullWarning = true, showDelta = true, warningThreshold = 110, soundAlert = true },
    Casting = { enabled = true, showTarget = true, showNameplate = true, showIcon = true, showTime = true },
    Guilds = { enabled = true, showChatTab = true, showAnnouncements = true, filterMinLevel = 1 },
    Bags = { enabled = true, replaceBags = true, showBagSilhouette = true, searchFilter = true, showCurrency = true, gearSets = true },
    Prices = { enabled = true, showMarket = true, showVendor = true, showSamples = true },
    Vendor = { enabled = true, autoSell = true, autoRepair = true, printSummary = true, showButton = true },
    Plates = { enabled = true, showDebuffs = true, showTimerText = true, coloredBorders = true, showHealthBar = true },
    Raid = { enabled = true, defaultPull = 10, soundAlert = true, showPoll = true },
    Persona = { enabled = true, showTooltip = true, rpNames = true, targetBadge = true, minimapButton = true, showListening = true },
}

function M:GetSettings(addonId)
    if not WenillaCore_Config then WenillaCore_Config = {} end
    if not WenillaCore_Config.settings then WenillaCore_Config.settings = {} end
    local s = WenillaCore_Config.settings[addonId]
    if not s then
        s = {}
        WenillaCore_Config.settings[addonId] = s
    end
    -- fill options added since the settings were saved
    for k, v in pairs(DEFAULT_SETTINGS[addonId] or {}) do
        if s[k] == nil then s[k] = v end
    end
    local schema = W.schemas and W.schemas[addonId]
    if schema then
        if s.enabled == nil then s.enabled = true end
        for k, v in pairs(schema.defaults or {}) do
            if s[k] == nil then s[k] = v end
        end
    end
    return s
end

function M:SetSetting(addonId, key, val)
    local s = M:GetSettings(addonId)
    s[key] = val
    M:ApplySettings(addonId)
end

function M:ApplySettings(addonId)
    -- Each addon registers a refresher with WenillaCore that applies its enabled state,
    -- Pure Vanilla mode and every option in one place.
    if W and W.Refresh then W:Refresh(addonId) end
end

-- -- The first eleven addons' settings --------------------------------------------------------

local BUILTIN = {
    Meters = {
        icon = "Interface\\Icons\\Ability_Warrior_SavageBlow",
        title = "Meters - Damage & Healing",
        desc = "Damage and healing for you, your group and your pets. Uses the realm's numbers when it sends them, otherwise your own combat log.",
        options = {
            { key = "classColors", label = "Class-coloured bars", sub = "Colour each bar by the player's class." },
            { key = "showDps", label = "Show DPS", sub = "Per-second damage next to each total." },
            { key = "inspectOnClick", label = "Click a bar for its breakdown", sub = "Clicking a player shows their top abilities." },
        },
    },
    Quests = {
        icon = "Interface\\Icons\\INV_Misc_Map_01",
        title = "Quests - Map, Ring & Pins",
        desc = "Quest pins on a carved ring around the minimap, coordinates under it, and objectives, givers and turn-ins from the realm.",
        options = {
            { key = "showRing", label = "Show the minimap ring", sub = "The carved ring around the minimap. Right-click the compass rose (or /compass theme) for Wildwood, Stone & Leather, Iron & Oak, Runestone or Dwarven Bronze." },
            { key = "showCoords", label = "Show coordinates", sub = "Your zone X/Y under the minimap." },
            { key = "showObjectives", label = "Objective pins", sub = "Gold pins toward your quest objectives." },
            { key = "showGivers", label = "Quest giver pins", sub = "Green pins for quests you can pick up." },
            { key = "showTurnins", label = "Turn-in pins", sub = "Red pins for quests ready to hand in." },
        },
    },
    Threat = {
        icon = "Interface\\Icons\\Ability_Warrior_DefensiveStance",
        title = "Threat",
        desc = "The creature's threat table, read from the realm: who it is on, and how close you are to pulling it.",
        options = {
            { key = "pullWarning", label = "Pull warning", sub = "Warn when you pass 110% (melee) or 130% (ranged) of the tank's threat." },
            { key = "showDelta", label = "Show the gap to the tank", sub = "A bar for how far you are behind the top threat." },
            { key = "soundAlert", label = "Warning sound", sub = "Play a sound as you near the pull threshold." },
        },
    },
    Casting = {
        icon = "Interface\\Icons\\Spell_Fire_Fireball02",
        title = "Casting - Cast Bars",
        desc = "Cast bars for your target and on enemy nameplates, from the realm's spell-cast events.",
        options = {
            { key = "showTarget", label = "Target cast bar", sub = "A cast bar under the target frame." },
            { key = "showNameplate", label = "Nameplate cast bars", sub = "Cast bars over enemy nameplates." },
            { key = "showIcon", label = "Spell icon", sub = "The spell's icon next to the bar." },
            { key = "showTime", label = "Cast time", sub = "Elapsed and total seconds, for example 1.4 / 3.0." },
        },
    },
    Guilds = {
        icon = "Interface\\Icons\\INV_Shirt_GuildTabard_01",
        title = "Guilds - Guild Finder",
        desc = "A recruitment board every player shares. Officers list their guild; anyone can browse, filter and ask to join with one click.",
        options = {
            { key = "showChatTab", label = "Guild chat tab", sub = "The Guild button by the chat tabs. Right-click it to hide it." },
            { key = "showAnnouncements", label = "Guild announcements", sub = "Show recruitment and guild news in chat." },
        },
    },
    Bags = {
        icon = "Interface\\Icons\\INV_Misc_Bag_10",
        title = "Bags - Bags & Bank",
        desc = "Every bag in one window with live search. Your bank is remembered each time you visit a banker, so you can browse it anywhere.",
        options = {
            { key = "replaceBags", label = "Open with B and the bag buttons", sub = "B and the bag bar open this window instead of the separate bags." },
            { key = "showBagSilhouette", label = "Empty slot art", sub = "A faint bag outline in empty slots." },
            { key = "searchFilter", label = "Search dims other items", sub = "While you type, items that don't match fade out." },
            { key = "showCurrency", label = "Money in the footer", sub = "Gold, silver and copper at the bottom of the window." },
            { key = "gearSets", label = "Gear sets", sub = "Save what you wear as named sets (tank, PvP, fishing) and swap with one click from the bags or character window. /gear" },
        },
    },
    Prices = {
        icon = "Interface\\Icons\\INV_Misc_Coin_01",
        title = "Prices - Tooltip Prices",
        desc = "Market prices on item tooltips without auction scans: every auction page you browse is remembered for 7 days, plus the realm's medians and vendor prices.",
        options = {
            { key = "showMarket", label = "Market price", sub = "The 7-day median buyout." },
            { key = "showVendor", label = "Vendor price", sub = "What a merchant pays, for one and for the stack." },
            { key = "showSamples", label = "Sample count", sub = "How many auctions the median is based on." },
        },
    },
    Vendor = {
        icon = "Interface\\Icons\\INV_Ore_Copper_01",
        title = "Vendor - Junk & Repairs",
        desc = "Sells your grey items and repairs your gear at every merchant, with an exact summary.",
        options = {
            { key = "autoSell", label = "Sell grey items", sub = "Sell every grey item when you open a merchant." },
            { key = "autoRepair", label = "Repair gear", sub = "Repair your gear at merchants who can." },
            { key = "printSummary", label = "Summary in chat", sub = "How many items were sold and for how much." },
            { key = "showButton", label = "Scrap button", sub = "A button on the merchant window to sell greys by hand." },
        },
    },
    Plates = {
        icon = "Interface\\Icons\\Spell_Nature_NullifyPoison",
        title = "Plates - Nameplates",
        desc = "Clean enemy nameplates: a dark-cased health bar, the level in a grey cap, and timers for your own debuffs.",
        options = {
            { key = "showDebuffs", label = "Your debuffs", sub = "Icons for your debuffs above each nameplate." },
            { key = "showTimerText", label = "Countdown numbers", sub = "Seconds left on each debuff." },
            { key = "coloredBorders", label = "Coloured debuff borders", sub = "Poison green, curse purple, magic blue, disease brown." },
            { key = "showHealthBar", label = "Styled health bar", sub = "The cased health bar and level cap." },
        },
    },
    Raid = {
        icon = "Interface\\Icons\\Ability_Warrior_BattleShout",
        title = "Raid - Group Tools",
        desc = "Raid markers, a ready check with a live board, and a pull timer the whole group sees.",
        options = {
            { key = "soundAlert", label = "Countdown sound", sub = "Ticks during the pull countdown." },
            { key = "showPoll", label = "Ready check board", sub = "A live list of who is ready." },
        },
    },
    Persona = {
        icon = "Interface\\Icons\\INV_Misc_Book_09",
        title = "Persona - Roleplay Profiles",
        desc = "Write a roleplay profile (name, title, appearance, bio, status) and read anyone else's: on tooltips, a badge on your target, and a directory of everyone you've met. /rp",
        options = {
            { key = "showTooltip", label = "Profiles in tooltips", sub = "Title, status, a glance line and 'currently' when you mouse over a player." },
            { key = "rpNames", label = "Roleplay names in tooltips", sub = "Show their roleplay name when they have set one." },
            { key = "targetBadge", label = "Status badge on your target", sub = "A small IC/OOC/LFRP gem; click it to read their profile." },
            { key = "minimapButton", label = "Minimap button", sub = "Left-click for your profile, right-click to change your status." },
            { key = "showListening", label = "Show what others listen to", sub = "Their 'Listening: Title - Artist' line, when they chose to share it (sharing your own is off unless you turn it on in the launcher or the web page's menu)." },
        },
    },
}

local function schemaFor(id)
    return (W.schemas and W.schemas[id]) or BUILTIN[id]
end

-- -- Window ----------------------------------------------------------------------------------

local mainFrame = CreateFrame("Frame", "ClassicPlus_SettingsWindow", UIParent)
mainFrame:SetWidth(600)
mainFrame:SetHeight(500)
mainFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 10)
mainFrame:SetFrameStrata("DIALOG")
table.insert(UISpecialFrames, "ClassicPlus_SettingsWindow")
UI.Skin(mainFrame, "panel")
mainFrame:EnableMouse(true)
mainFrame:SetMovable(true)
mainFrame:RegisterForDrag("LeftButton")
mainFrame:SetScript("OnDragStart", function() mainFrame:StartMoving() end)
mainFrame:SetScript("OnDragStop", function() mainFrame:StopMovingOrSizing() end)
mainFrame:Hide()

local titleBg = mainFrame:CreateTexture(nil, "ARTWORK")
titleBg:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 3, -3)
titleBg:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -3, -3)
titleBg:SetHeight(26)
UI.Gradient(titleBg, 0.21, 0.21, 0.23, 0.11, 0.11, 0.12)

local shieldIcon = mainFrame:CreateTexture(nil, "OVERLAY")
shieldIcon:SetWidth(16)
shieldIcon:SetHeight(16)
shieldIcon:SetPoint("LEFT", titleBg, "LEFT", 8, 0)
shieldIcon:SetTexture("Interface\\Icons\\INV_Shield_06")
shieldIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

local title = UI.Label(mainFrame, 12, UI.ACCENT, "OUTLINE")
title:SetPoint("LEFT", shieldIcon, "RIGHT", 8, 0)
title:SetText("Addons & Options")

local closeBtn = UI.CloseButton(mainFrame, function() mainFrame:Hide() end, 24)
closeBtn:SetPoint("RIGHT", titleBg, "RIGHT", 3, 0)

-- -- Experience bar (Classic+ vs Pure Vanilla) -------------------------------------------------

local modeBar = CreateFrame("Frame", nil, mainFrame)
modeBar:SetPoint("TOPLEFT", titleBg, "BOTTOMLEFT", 4, -6)
modeBar:SetPoint("TOPRIGHT", titleBg, "BOTTOMRIGHT", -4, -6)
modeBar:SetHeight(28)
UI.Skin(modeBar, "inset")

local modeLabel = UI.Label(modeBar, 11, UI.MUTED)
modeLabel:SetPoint("LEFT", modeBar, "LEFT", 10, 0)
modeLabel:SetText("Experience")

local function modeButton(name, text, anchor, x)
    local b = CreateFrame("Button", name, modeBar)
    UI.Skin(b, "inset")
    b:SetWidth(150)
    b:SetHeight(20)
    b:SetPoint("LEFT", anchor, "RIGHT", x, 0)
    b.text = UI.Label(b, 11)
    b.text:SetPoint("CENTER", b, "CENTER", 0, 0)
    b.text:SetJustifyH("CENTER")
    b.text:SetText(text)
    return b
end
local btnClassicPlus = modeButton("ClassicPlus_BtnCP", "Classic+ Enhanced", modeLabel, 14)
local btnVanilla = modeButton("ClassicPlus_BtnVan", "Pure Vanilla", btnClassicPlus, 8)

btnClassicPlus:SetScript("OnClick", function()
    W:SetVanillaMode(false)
    M:UpdateModeButtons()
end)
btnVanilla:SetScript("OnClick", function()
    W:SetVanillaMode(true)
    M:UpdateModeButtons()
end)

local demoSwitch, demoLabel

function M:UpdateModeButtons()
    local function paint(b, on, r, g, bl)
        if on then
            b:SetBackdropColor(r * 0.35, g * 0.35, bl * 0.35, 0.95)
            b:SetBackdropBorderColor(r, g, bl, 1)
            b.text:SetTextColor(r, g, bl)
        else
            b:SetBackdropColor(UI.INSET[1], UI.INSET[2], UI.INSET[3], UI.INSET[4])
            b:SetBackdropBorderColor(UI.EDGE[1], UI.EDGE[2], UI.EDGE[3], 0.6)
            b.text:SetTextColor(UI.MUTED[1], UI.MUTED[2], UI.MUTED[3])
        end
    end
    paint(btnClassicPlus, not W.isVanillaMode, 0.35, 0.90, 0.40)
    paint(btnVanilla, W.isVanillaMode, 1.0, 0.82, 0.20)
    if demoSwitch then demoSwitch:SetOn(W.demoRunning and true or false, true) end
end

-- -- Left: the addon list --------------------------------------------------------------------

local sidebar = CreateFrame("Frame", nil, mainFrame)
sidebar:SetPoint("TOPLEFT", modeBar, "BOTTOMLEFT", 0, -6)
sidebar:SetWidth(170)
sidebar:SetHeight(NAV_H)
UI.Skin(sidebar, "inset")
sidebar:EnableMouseWheel(true)

local navButtons = {}
M.navOffset = 0
M.currentAddon = "Meters"

local function navItems()
    local out = {}
    for _, id in ipairs(W.ADDONS) do
        if schemaFor(id) then table.insert(out, id) end
    end
    return out
end

local function addonEnabled(id)
    return M:GetSettings(id).enabled and true or false
end

local function setAddon(id, on)
    M:SetSetting(id, "enabled", on)
    W:SetAddonEnabled(id, on)
    M:RefreshSidebar()
    if id == M.currentAddon then M:SelectAddon(id) end
end

local function makeNav(i)
    local btn = CreateFrame("Button", "ClassicPlus_NavBtn" .. i, sidebar)
    btn:SetWidth(162)
    btn:SetHeight(NAV_ROW - 1)
    btn.bg = btn:CreateTexture(nil, "BACKGROUND")
    btn.bg:SetAllPoints(btn)
    btn.mark = btn:CreateTexture(nil, "ARTWORK")
    btn.mark:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0)
    btn.mark:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 0, 0)
    btn.mark:SetWidth(2)
    btn.mark:SetTexture(UI.ACCENT[1], UI.ACCENT[2], UI.ACCENT[3], 1)
    btn.icon = btn:CreateTexture(nil, "ARTWORK")
    btn.icon:SetWidth(16)
    btn.icon:SetHeight(16)
    btn.icon:SetPoint("LEFT", btn, "LEFT", 7, 0)
    btn.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    btn.txt = UI.Label(btn, 11)
    btn.txt:SetPoint("LEFT", btn.icon, "RIGHT", 6, 0)
    btn.switch = UI.Switch(btn, {
        name = "ClassicPlus_NavSwitch" .. i, width = 28,
        get = function() return btn.addonId and addonEnabled(btn.addonId) end,
        set = function(on) if btn.addonId then setAddon(btn.addonId, on) end end,
    })
    btn.switch:SetPoint("RIGHT", btn, "RIGHT", -4, 0)
    btn:SetScript("OnClick", function() if btn.addonId then M:SelectAddon(btn.addonId) end end)
    navButtons[i] = btn
    return btn
end

function M:RefreshSidebar()
    local items = navItems()
    local rows = math.floor(NAV_H / NAV_ROW)
    local maxOff = math.max(0, table.getn(items) - rows)
    if M.navOffset > maxOff then M.navOffset = maxOff end
    if M.navOffset < 0 then M.navOffset = 0 end
    for i = 1, math.max(table.getn(items), table.getn(navButtons)) do
        local id = items[i]
        local btn = navButtons[i] or (id and makeNav(i))
        if btn then
            local slot = i - M.navOffset
            if id and slot >= 1 and slot <= rows then
                local sc = schemaFor(id)
                btn.addonId = id
                btn:ClearAllPoints()
                btn:SetPoint("TOPLEFT", sidebar, "TOPLEFT", 4, -4 - (slot - 1) * NAV_ROW)
                btn.icon:SetTexture(sc.icon or UI.UNKNOWN_ICON)
                btn.txt:SetText(id)
                local sel = (id == M.currentAddon)
                local on = addonEnabled(id) and not W.isVanillaMode
                btn.bg:SetTexture(sel and 0.15 or 0, sel and 0.155 or 0, sel and 0.19 or 0, sel and 0.95 or 0)
                btn.mark:SetAlpha(sel and 1 or 0)
                if sel then btn.txt:SetTextColor(1, 0.85, 0.3)
                elseif on then btn.txt:SetTextColor(0.92, 0.92, 0.95)
                else btn.txt:SetTextColor(0.45, 0.46, 0.50) end
                btn.icon:SetAlpha(on and 1 or 0.4)
                btn.switch:SetOn(addonEnabled(id), true)
                btn.switch:SetEnabled(not W.isVanillaMode)
                btn:Show()
            else
                btn.addonId = id
                btn:Hide()
            end
        end
    end
end

sidebar:SetScript("OnMouseWheel", function()
    M.navOffset = M.navOffset - (arg1 or 0) * 2
    M:RefreshSidebar()
end)

-- -- Right: the selected addon's settings -----------------------------------------------------

local contentPane = CreateFrame("Frame", nil, mainFrame)
contentPane:SetPoint("TOPLEFT", sidebar, "TOPRIGHT", 6, 0)
contentPane:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -8, 40)
UI.Skin(contentPane, "inset")
contentPane:EnableMouseWheel(true)

local contentIcon = UI.IconBox(contentPane, 30)
contentIcon:SetPoint("TOPLEFT", contentPane, "TOPLEFT", 12, -12)

local contentTitle = UI.Label(contentPane, 13, UI.ACCENT, "OUTLINE")
contentTitle:SetPoint("LEFT", contentIcon, "RIGHT", 10, 0)
contentTitle:SetWidth(240)

local contentDesc = UI.Label(contentPane, 11, { 0.86, 0.80, 0.62 })
contentDesc:SetPoint("TOPLEFT", contentIcon, "BOTTOMLEFT", 0, -8)
contentDesc:SetWidth(370)

-- the master switch (named for the tests and macros that click it)
local masterLbl = UI.Label(contentPane, 11, { 1, 1, 1 })
masterLbl:SetText("Enabled")
local masterCb = UI.Switch(contentPane, {
    name = "ClassicPlus_MasterCB", width = 40,
    get = function() return addonEnabled(M.currentAddon) end,
    set = function(on) setAddon(M.currentAddon, on) end,
})
masterCb:SetPoint("TOPRIGHT", contentPane, "TOPRIGHT", -14, -16)
masterLbl:SetPoint("RIGHT", masterCb, "LEFT", -8, 0)

local body = CreateFrame("Frame", nil, contentPane)
body:SetPoint("TOPLEFT", contentDesc, "BOTTOMLEFT", 0, -14)
body:SetWidth(370)
body:SetHeight(300)
M.scroll = 0

local switchRows, choiceRows, sliderRows = {}, {}, {}

for i = 1, MAX_SWITCHES do
    local r = CreateFrame("Frame", nil, body)
    r:SetWidth(370)
    r:SetHeight(28)
    r.label = UI.Label(r, 11, { 1, 1, 1 })
    r.label:SetPoint("TOPLEFT", r, "TOPLEFT", 0, 0)
    r.label:SetWidth(320)
    r.sub = UI.Label(r, 10, UI.MUTED)
    r.sub:SetPoint("TOPLEFT", r.label, "BOTTOMLEFT", 0, -2)
    r.sub:SetWidth(320)
    r.switch = UI.Switch(r, {
        name = "ClassicPlus_OptCB" .. i, width = 34,
        get = function() return r.key and M:GetSettings(M.currentAddon)[r.key] and true or false end,
        set = function(on) if r.key then M:SetSetting(M.currentAddon, r.key, on) end end,
    })
    r.switch:SetPoint("TOPRIGHT", r, "TOPRIGHT", 0, -1)
    switchRows[i] = r
end

for i = 1, MAX_CHOICES do
    local r = CreateFrame("Frame", nil, body)
    r:SetWidth(370)
    r:SetHeight(22)
    r.label = UI.Label(r, 11, { 1, 1, 1 })
    r.label:SetPoint("LEFT", r, "LEFT", 0, 0)
    local b = CreateFrame("Button", "ClassicPlus_OptChoice" .. i, r)
    UI.Skin(b, "inset")
    b:SetWidth(120)
    b:SetHeight(18)
    b:SetPoint("RIGHT", r, "RIGHT", 0, 0)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b.value = UI.Label(b, 10, UI.ACCENT)
    b.value:SetPoint("CENTER", b, "CENTER", 0, 0)
    b.value:SetJustifyH("CENTER")
    b:SetScript("OnClick", function()
        local o = r.opt
        if not o then return end
        local s = M:GetSettings(M.currentAddon)
        local n, at = table.getn(o.choices), 1
        for k, c in ipairs(o.choices) do if c.value == s[o.key] then at = k end end
        at = at + ((arg1 == "RightButton") and -1 or 1)
        if at > n then at = 1 elseif at < 1 then at = n end
        M:SetSetting(M.currentAddon, o.key, o.choices[at].value)
        b.value:SetText(o.choices[at].label)
    end)
    r.button = b
    choiceRows[i] = r
end

for i = 1, MAX_SLIDERS do
    local r = CreateFrame("Frame", nil, body)
    r:SetWidth(370)
    r:SetHeight(32)
    r.label = UI.Label(r, 11, { 1, 1, 1 })
    r.label:SetPoint("TOPLEFT", r, "TOPLEFT", 0, 0)
    r.value = UI.Label(r, 10, UI.ACCENT)
    r.value:SetPoint("TOPRIGHT", r, "TOPRIGHT", 0, 0)
    r.value:SetJustifyH("RIGHT")
    local sl = CreateFrame("Slider", "ClassicPlus_OptSlider" .. i, r)
    sl:SetOrientation("HORIZONTAL")
    sl:SetWidth(370)
    sl:SetHeight(10)
    sl:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", 0, 2)
    local track = sl:CreateTexture(nil, "BACKGROUND")
    track:SetPoint("LEFT", sl, "LEFT", 0, 0)
    track:SetPoint("RIGHT", sl, "RIGHT", 0, 0)
    track:SetHeight(4)
    track:SetTexture(0.16, 0.17, 0.20, 1)
    local thumb = sl:CreateTexture(nil, "OVERLAY")
    thumb:SetWidth(12)
    thumb:SetHeight(12)
    if not W:Art(thumb, "Switch_Knob", nil) then thumb:SetTexture(1, 0.82, 0, 1) end
    sl:SetThumbTexture(thumb)
    sl:SetScript("OnValueChanged", function()
        local o = r.opt
        if not o or r.loading then return end
        local v = sl:GetValue()
        local step = o.step or 1
        v = math.floor(v / step + 0.5) * step
        r.value:SetText(o.fmt and string.format(o.fmt, v) or tostring(v))
        M:SetSetting(M.currentAddon, o.key, v)
    end)
    r.slider = sl
    sliderRows[i] = r
end

local function rowHeight(sub)
    local chars = string.len(sub or "")
    if chars == 0 then return 20 end
    return 18 + (math.floor(chars * 5.3 / 320) + 1) * 12
end

function M:LayoutOptions()
    local schema = schemaFor(M.currentAddon)
    local s = M:GetSettings(M.currentAddon)
    local nsw, nch, nsl = 0, 0, 0
    local y = 0
    local active = addonEnabled(M.currentAddon) and not W.isVanillaMode
    for _, r in ipairs(switchRows) do r:Hide(); r.key = nil end
    for _, r in ipairs(choiceRows) do r:Hide(); r.opt = nil end
    for _, r in ipairs(sliderRows) do r:Hide(); r.opt = nil end
    local total = 0
    for _, o in ipairs((schema and schema.options) or {}) do
        local r, h
        if o.type == "choice" and nch < MAX_CHOICES then
            nch = nch + 1
            r = choiceRows[nch]
            r.opt = o
            r.label:SetText(o.label)
            local text = o.choices[1] and o.choices[1].label or ""
            for _, c in ipairs(o.choices) do if c.value == s[o.key] then text = c.label end end
            r.button.value:SetText(text)
            h = 26
        elseif o.type == "slider" and nsl < MAX_SLIDERS then
            nsl = nsl + 1
            r = sliderRows[nsl]
            r.opt = o
            r.label:SetText(o.label)
            r.loading = true
            r.slider:SetMinMaxValues(o.min or 0, o.max or 100)
            if r.slider.SetValueStep then r.slider:SetValueStep(o.step or 1) end
            local v = s[o.key] or o.min or 0
            r.slider:SetValue(v)
            r.value:SetText(o.fmt and string.format(o.fmt, v) or tostring(v))
            r.loading = nil
            h = 36
        elseif (o.type == nil or o.type == "switch") and nsw < MAX_SWITCHES then
            nsw = nsw + 1
            r = switchRows[nsw]
            r.key = o.key
            r.label:SetText(o.label)
            r.sub:SetText(o.sub or "")
            local v = s[o.key]
            if v == nil then v = true end
            r.switch:SetOn(v, true)
            r.switch:SetEnabled(active)
            h = rowHeight(o.sub)
            r:SetHeight(h)
        end
        if r then
            local top = y - M.scroll
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -top)
            if top >= 0 and top + h <= body:GetHeight() + 1 then r:Show() else r:Hide() end
            y = y + h + 8
            total = total + h + 8
        end
    end
    M.contentHeight = total
end

contentPane:SetScript("OnMouseWheel", function()
    local maxScroll = math.max(0, (M.contentHeight or 0) - body:GetHeight())
    M.scroll = math.max(0, math.min(maxScroll, M.scroll - (arg1 or 0) * 24))
    M:LayoutOptions()
end)

function M:SelectAddon(addonId)
    local schema = schemaFor(addonId)
    if not schema then return end
    if addonId ~= M.currentAddon then M.scroll = 0 end
    M.currentAddon = addonId
    contentTitle:SetText(schema.title or addonId)
    contentDesc:SetText(schema.desc or "")
    contentIcon.icon:SetTexture(schema.icon or UI.UNKNOWN_ICON)
    masterCb:SetOn(addonEnabled(addonId), true)
    masterCb:SetEnabled(not W.isVanillaMode)
    M:LayoutOptions()
    M:RefreshSidebar()
end

-- -- Footer ----------------------------------------------------------------------------------

local btnAllOn = UI.Button(mainFrame, "Enable All", 110, 22, function()
    W:SetVanillaMode(false)
    for _, id in ipairs(navItems()) do
        M:SetSetting(id, "enabled", true)
        W:SetAddonEnabled(id, true)
    end
    M:SelectAddon(M.currentAddon)
    M:UpdateModeButtons()
end)
btnAllOn:SetPoint("BOTTOMLEFT", mainFrame, "BOTTOMLEFT", 12, 10)

local btnAllOff = UI.Button(mainFrame, "Pure Vanilla", 140, 22, function()
    W:SetVanillaMode(true)
    M:SelectAddon(M.currentAddon)
    M:UpdateModeButtons()
end)
btnAllOff:SetPoint("LEFT", btnAllOn, "RIGHT", 8, 0)

demoLabel = UI.Label(mainFrame, 11, UI.MUTED)
demoLabel:SetPoint("LEFT", btnAllOff, "RIGHT", 16, 0)
demoLabel:SetText("Demo data")
demoSwitch = UI.Switch(mainFrame, {
    name = "ClassicPlus_DemoSwitch", width = 32,
    get = function() return W.demoRunning and true or false end,
    set = function() if W.ToggleDemoStream then W:ToggleDemoStream() end M:UpdateModeButtons() end,
})
demoSwitch:SetPoint("LEFT", demoLabel, "RIGHT", 8, 0)

local btnClose = UI.Button(mainFrame, "Close", 80, 22, function() mainFrame:Hide() end)
btnClose:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -12, 10)

-- -- Opening ---------------------------------------------------------------------------------

function W:UpdateManagerUI()
    if mainFrame:IsShown() then
        M:SelectAddon(M.currentAddon)
        M:UpdateModeButtons()
    end
end

function ClassicPlus_ToggleManager()
    if mainFrame:IsShown() then
        mainFrame:Hide()
    else
        mainFrame:Show()
        M:SelectAddon(M.currentAddon)
        M:UpdateModeButtons()
    end
end

mainFrame:SetScript("OnShow", function()
    M:RefreshSidebar()
end)

SLASH_CPADDONS1 = "/addons"
SLASH_CPADDONS2 = "/cpaddons"
SLASH_CPADDONS3 = "/cplus"
SlashCmdList["CPADDONS"] = function(msg)
    ClassicPlus_ToggleManager()
end

-- Esc menu and Interface Options get an "AddOns" button that opens this window.
local function hookOptionsAddons()
    W:GameMenuAdd("GameMenuButtonAddOns", "AddOns", function() ClassicPlus_ToggleManager() end, 10)

    if UIOptionsFrame and not UIOptionsFrameAddOns then
        local uiBtn = CreateFrame("Button", "UIOptionsFrameAddOns", UIOptionsFrame, "OptionsButtonTemplate")
        uiBtn:SetText("AddOns")
        uiBtn:SetWidth(90)
        uiBtn:SetHeight(21)
        if UIOptionsFrameDefaults then
            uiBtn:SetPoint("LEFT", UIOptionsFrameDefaults, "RIGHT", 10, 0)
        else
            uiBtn:SetPoint("BOTTOMLEFT", UIOptionsFrame, "BOTTOMLEFT", 16, 16)
        end
        uiBtn:SetScript("OnClick", function()
            PlaySound("igMainMenuOption")
            HideUIPanel(UIOptionsFrame)
            ClassicPlus_ToggleManager()
        end)
    end
end

hookOptionsAddons()
