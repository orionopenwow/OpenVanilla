--[[
    Init.lua  -  Quests: registration with WenillaCore, and the slash commands.

    /quests                 open or close the quest log
    /quests log | completed | options     open the log on that page
    /quests tracker | arrow | coords      switch the tracker, arrow or coordinates on or off
    /quests way <x> <y> [name]            point the arrow at a spot on this zone's map
    /quests clear           clear the arrow's target and the pinned quest
    /quests track           the tracking menu (repair, sell, flight masters ...)
    /compass                show or hide the minimap ring (as before 1.15)
    /compass theme [name]   next ring style, or a named one
]]--

local W = WenillaCore
local UI = W.UI
local Q = Compass
local ID = Q.ID

-- -- Schema --------------------------------------------------------------------------------------

local defaults = {}
for k, v in pairs(Q.DEFAULTS) do defaults[k] = v end
local options = {}
for _, o in ipairs(Q.OPTIONS) do
    table.insert(options, { key = o.key, label = o.label, sub = o.sub, type = o.type, choices = o.choices,
        min = o.min, max = o.max, step = o.step, fmt = o.fmt })
end

W:RegisterSchema(ID, {
    title = "Quests - Log, Tracker, Map & Ring",
    icon = "Interface\\Icons\\INV_Misc_Map_01",
    desc = "A two-pane quest log on L, an objective tracker, quest pins on the world map, minimap and a carved minimap ring, "
        .. "an arrow with yards to your next objective (or your corpse), progress in tooltips, and repair, vendor, "
        .. "flight, inn, trainer and bank icons. Uses the realm's quest data when it sends it.",
    defaults = defaults,
    options = options,
})

-- -- Registration ----------------------------------------------------------------------------------

W:RegisterAddon(ID, function(active)
    if active then
        Q.updater:Show()
        Q:RequestScan()
    else
        Q.updater:Hide()
    end
    for _, fn in ipairs(Q.refreshers) do
        local ok, err = pcall(fn, active)
        if not ok then W:Error(ID .. " refresh", err) end
    end
end)

-- -- Slash commands -------------------------------------------------------------------------------

local function toggle(key, label)
    local on = not Q:Get(key)
    Q:Set(key, on)
    Q:Print(label .. (on and " on." or " off."))
end

local function themeCommand(word)
    if word == "" then return Q:NextRingTheme() end
    for _, t in ipairs(Q.RING_THEMES) do
        if t.key == word or string.lower(t.label) == word then return Q:SetRingTheme(t.key) end
    end
    local names = {}
    for _, t in ipairs(Q.RING_THEMES) do table.insert(names, t.key) end
    Q:Print("Minimap ring themes: " .. table.concat(names, ", ") .. ".")
end

local function toggleRing()
    local s = W:Settings(ID)
    s.showRing = not Q:Get("showRing")
    W:Refresh(ID)
    Q:Print("Minimap ring " .. (s.showRing and "shown" or "hidden") .. ". /compass theme changes its look.")
end

local function help()
    Q:Print("/quests: the quest log  |  /quests completed, options  |  /quests tracker, arrow, coords  |  "
        .. "/quests way 42 65  |  /quests clear  |  /compass: the minimap ring  |  /compass theme")
end

local function command(msg, bare)
    if not Q:Active() then
        Q:Print("Quests is switched off. Turn it on in /addons.")
        return
    end
    msg = W.Trim(msg or "")
    local _, _, word, rest = string.find(msg, "^(%S*)%s*(.-)$")
    word = string.lower(word or "")
    rest = rest or ""
    if word == "" then
        bare()
    elseif word == "theme" then
        themeCommand(string.lower(rest))
    elseif word == "ring" then
        toggleRing()
    elseif word == "log" or word == "show" then
        Q.Log:Open()
        Q.Log:SetPage("quests")
    elseif word == "completed" or word == "history" then
        Q.Log:Open()
        Q.Log:SetPage("history")
    elseif word == "options" or word == "settings" then
        Q.Log:Open()
        Q.Log:SetPage("options")
    elseif word == "tracker" then
        toggle("showTracker", "Objective tracker")
    elseif word == "arrow" then
        toggle("showArrow", "Waypoint arrow")
    elseif word == "coords" then
        toggle("showCoords", "Coordinates")
    elseif word == "track" then
        Q:TrackingMenu(Compass_Rose)
    elseif word == "clear" then
        Q.pinnedKey = nil
        Q:ClearWaypoint()
        Q:Fire("TrackingChanged")
        Q:Print("Arrow cleared.")
    elseif word == "way" then
        Q:WayCommand(rest)
    elseif word == "reset" then
        W:ResetPositions()
    else
        help()
    end
end

SLASH_QUESTS1 = "/quests"
SlashCmdList["QUESTS"] = function(msg) command(msg, function() Q.Log:Toggle() end) end

-- /way 42.5 65 Goldshire · /way 42.5, 65 · /way clear  (as TomTom; also /quests way)
function Q:WayCommand(rest)
    rest = rest or ""
    if string.find(string.lower(rest), "^%s*clear") or string.find(rest, "^%s*$") and self.waypoint then
        self:ClearWaypoint()
        self:Print("Waypoint cleared.")
        return
    end
    local _, _, x, y, name = string.find(rest, "^%s*([%d%.]+)[,%s]+([%d%.]+)%s*(.-)$")
    x, y = tonumber(x), tonumber(y)
    if x and y and x >= 0 and x <= 100 and y >= 0 and y <= 100 then
        self:SetWaypoint({ x = x / 100, y = y / 100, title = (name and name ~= "") and name or ("Waypoint " .. x .. ", " .. y) })
        self:Print("Arrow set to " .. x .. ", " .. y .. ".")
    else
        self:Print("Usage: /way <x> <y> [name], for example /way 42.5 65 Goldshire. /way clear drops it.")
    end
end

SLASH_COMPASSWAY1 = "/way"
SlashCmdList["COMPASSWAY"] = function(msg) Q:WayCommand(msg) end

SLASH_COMPASS1 = "/compass"
SlashCmdList["COMPASS"] = function(msg) command(msg, toggleRing) end
