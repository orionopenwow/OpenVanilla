--[[
    Options.lua  -  Quests: every option, and the quest log's Options page.

    Q.OPTIONS is the one list of options: Init.lua registers it as the addon's schema (the
    Addons window), and the Options tab of the quest log shows all of it in two columns.
]]--

local W = WenillaCore
local UI = W.UI
local Q = Compass
local Log = Q.Log
local win = Log.win

local THEMES = {}
for _, t in ipairs(Q.RING_THEMES) do table.insert(THEMES, { value = t.key, label = t.label }) end

-- Schema order: the Addons window has room for the first ten switches, so they come first.
Q.OPTIONS = {
    { key = "showRing", label = "Minimap ring", sub = "The carved ring around the minimap. Right-click the compass rose (or /compass theme) to change its look." },
    { key = "replaceBorder", label = "Ring replaces the stock border", sub = "Hide the gold minimap border and set the zoom buttons, zone name and tracking button around the ring." },
    { key = "showCoords", label = "Coordinates", sub = "Your zone X/Y under the minimap." },
    { key = "replaceLog", label = "Open with L", sub = "L and the quest button open this quest log. Off: the classic one." },
    { key = "showTracker", label = "Objective tracker", sub = "Tracked quests and their objectives on the right of the screen, instead of the stock quest watch." },
    { key = "showArrow", label = "Waypoint arrow", sub = "An arrow with the distance in yards to your pinned quest or the nearest objective." },
    { key = "tooltips", label = "Progress in tooltips", sub = "\"Kobold Vermin: 4/8\" on mobs and items your quests need." },
    { key = "minimapPins", label = "Icons on the minimap", sub = "Quest pins and tracked NPCs on the minimap itself while they are in view; farther ones sit on the ring." },
    { key = "showObjectives", label = "Objective pins", sub = "Gold pins toward your quest objectives." },
    { key = "chimes", label = "Chimes and banners", sub = "A sound when an objective is done and a banner when a quest is complete." },
    { key = "ringTheme", label = "Ring style", type = "choice", choices = THEMES },
    { key = "trackerMax", label = "Quests in the tracker", type = "slider", min = 3, max = 20, step = 1,
        choices = { { value = 3, label = "3" }, { value = 5, label = "5" }, { value = 8, label = "8" }, { value = 12, label = "12" }, { value = 20, label = "20" } } },
    { key = "arrowScale", label = "Arrow size", type = "slider", min = 0.6, max = 1.6, step = 0.1, fmt = "%.1fx",
        choices = { { value = 0.8, label = "Small" }, { value = 1, label = "Normal" }, { value = 1.3, label = "Large" }, { value = 1.6, label = "Huge" } } },
    { key = "showGivers", label = "Quest giver pins", sub = "Green pins for quests you can pick up." },
    { key = "showTurnins", label = "Turn-in pins", sub = "Red pins for quests ready to hand in." },
    { key = "worldMapPins", label = "Pins on the world map", sub = "Objective, giver and turn-in pins on the world map." },
    { key = "autoTrack", label = "Track new quests", sub = "Add every quest you accept to the tracker." },
    { key = "hideGrey", label = "Hide grey quests", sub = "Leave low-level quests out of the list (the Filter menu can abandon them all)." },
    { key = "groupProgress", label = "Party progress", sub = "Tell your party how far you are on shared quests and show theirs." },
    { key = "autoPick", label = "Pick the best reward", sub = "Mark the reward that is the biggest upgrade for you, and choose it when turning in automatically." },
    { key = "autoTurnIn", label = "Turn in automatically", sub = "Hand in finished quests when you talk to the NPC (only with one reward, or with Pick the best reward on)." },
    { key = "arrowAuto", label = "Point at the nearest objective", sub = "Without a pinned quest the arrow points at the nearest objective or turn-in of your tracked quests." },
    { key = "corpseArrow", label = "Point at my corpse", sub = "While you are dead the arrow shows the way back to your corpse." },
    { key = "arrowChime", label = "Chime on arrival", sub = "A soft ping when you reach a spot you set." },
    { key = "trackRepair", label = "Repair", sub = "Anvil icons for NPCs who repair." },
    { key = "trackSell", label = "Sell", sub = "Coin bags for merchants who buy your items." },
    { key = "trackFlight", label = "Flight masters", sub = "Wing icons for flight masters." },
    { key = "trackInn", label = "Innkeepers", sub = "Tankards for innkeepers." },
    { key = "trackTrainer", label = "Trainers", sub = "Books for your class trainers." },
    { key = "trackBank", label = "Bankers", sub = "Chests for bankers." },
}

-- The Options page: sections in two columns.
local PAGE = {
    { "Minimap", { "showRing", "replaceBorder", "ringTheme", "showCoords", "minimapPins", "showObjectives", "showGivers", "showTurnins" } },
    { "On the minimap", { "trackRepair", "trackSell", "trackFlight", "trackInn", "trackTrainer", "trackBank" } },
    { "Quest log", { "replaceLog", "showTracker", "trackerMax", "autoTrack", "tooltips", "hideGrey", "chimes", "worldMapPins", "groupProgress", "autoPick", "autoTurnIn" }, true },
    { "Arrow", { "showArrow", "arrowAuto", "corpseArrow", "arrowChime", "arrowScale" } },
}

-- -- The Options page --------------------------------------------------------------------------------

local page = CreateFrame("Frame", "Compass_LogOptions", win)
page:SetPoint("TOPLEFT", win, "TOPLEFT", 10, -56)
page:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -10, 10)
page:Hide()
Log.options = page

local COL_W, ROW_H = 330, 20
local rows = {}

local function tip(frame, o)
    frame:SetScript("OnEnter", function()
        if not o.sub then return end
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:SetText(o.label, 1, 1, 1)
        GameTooltip:AddLine(o.sub, 0.8, 0.8, 0.8, 1)
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function choiceValue(o)
    local cur = Q:Get(o.key)
    local best, bi = nil, 1
    for i, c in ipairs(o.choices) do
        if c.value == cur then return c, i end
        if type(cur) == "number" and type(c.value) == "number" then
            if not best or math.abs(c.value - cur) < math.abs(best.value - cur) then best, bi = c, i end
        end
    end
    return best or o.choices[1], bi
end

local byKey = {}
for _, o in ipairs(Q.OPTIONS) do byKey[o.key] = o end

local col, yy = 0, 0
for _, sec in ipairs(PAGE) do
    if sec[3] then col, yy = 1, 0 end
    local x = col * (COL_W + 16)
    if yy < 0 then yy = yy - 6 end
    local l = UI.Label(page, 10, UI.MUTED, "OUTLINE")
    l:SetPoint("TOPLEFT", page, "TOPLEFT", x, yy)
    l:SetText(string.upper(sec[1]))
    local d = UI.Divider(page)
    d:SetPoint("LEFT", l, "RIGHT", 6, 0)
    d:SetWidth(COL_W - 130)
    yy = yy - 16
    for _, key in ipairs(sec[2]) do
        local o = byKey[key]
        local opt = o
        local r = CreateFrame("Frame", nil, page)
        r:SetWidth(COL_W)
        r:SetHeight(ROW_H)
        r:SetPoint("TOPLEFT", page, "TOPLEFT", x, yy)
        r:EnableMouse(true)
        tip(r, o)
        r.label = UI.Label(r, 11, { 1, 1, 1 })
        r.label:SetPoint("LEFT", r, "LEFT", 4, 0)
        r.label:SetText(o.label)
        if o.type == "choice" or o.type == "slider" then
            local b = CreateFrame("Button", "Compass_Opt_" .. o.key, r)
            UI.Skin(b, "inset")
            b:SetWidth(110)
            b:SetHeight(18)
            b:SetPoint("RIGHT", r, "RIGHT", 0, 0)
            b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            b.value = UI.Label(b, 10, UI.ACCENT)
            b.value:SetPoint("CENTER", b, "CENTER", 0, 0)
            b.value:SetJustifyH("CENTER")
            b:SetScript("OnClick", function()
                local _, i = choiceValue(opt)
                local n = table.getn(opt.choices)
                i = i + ((arg1 == "RightButton") and -1 or 1)
                if i > n then i = 1 elseif i < 1 then i = n end
                Q:Set(opt.key, opt.choices[i].value)
                b.value:SetText(opt.choices[i].label)
            end)
            r.Refresh = function() b.value:SetText((choiceValue(opt)).label) end
        else
            local sw = UI.Switch(r, { name = "Compass_Opt_" .. o.key, width = 30,
                get = function() return Q:Get(opt.key) and true or false end,
                set = function(on) Q:Set(opt.key, on) end, tooltip = o.sub })
            sw:SetPoint("RIGHT", r, "RIGHT", 0, 0)
            r.Refresh = function() sw:Refresh() end
        end
        table.insert(rows, r)
        yy = yy - ROW_H
    end
end

local classic = Log.Flat(page, "Compass_LogClassic", "Open the classic quest log", 190, function() Q:OpenStockLog() end)
classic:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", 0, 0)
local reset = Log.Flat(page, "Compass_LogResetPos", "Reset tracker and arrow", 170, function()
    for _, f in ipairs({ Q.tracker, Q.arrow }) do
        if WenillaCore_Config and WenillaCore_Config.positions then WenillaCore_Config.positions[f:GetName()] = nil end
        local d = f.defaultPoint
        f:ClearAllPoints()
        f:SetPoint(d[1], d[2] or UIParent, d[3], d[4], d[5])
    end
    Q:Print("Tracker and arrow are back in their places.")
end)
reset:SetPoint("LEFT", classic, "RIGHT", 8, 0)

page:SetScript("OnShow", function()
    for _, r in ipairs(rows) do r.Refresh() end
end)
Q:OnRefresh(function() if page:IsVisible() then for _, r in ipairs(rows) do r.Refresh() end end end)
