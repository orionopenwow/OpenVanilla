--[[
    Core.lua  -  Quests: shared state, settings, events, timers and map geometry.

    The addon is split by feature; every file adds to the one global table `Compass` (the name
    from before 1.15, kept so saved macros and other addons still find it):

        Core.lua      this file: settings, the event/timer hub, yards and directions
        NpcData.lua   built-in service NPCs for the capitals and starting zones (generated)
        Data.lua      zone sizes, zone ids, ring themes
        QuestData.lua reads the quest log, notices progress, keeps the history
        Ring.lua      the carved minimap ring, the compass rose, coordinates, markers
        Nodes.lua     map nodes per quest (Q:AddNode / Q:DeleteNode), server quest packets
        WorldMap.lua  quest pins on the world map
        Tracking.lua  repair / sell / flight / inn / trainer / bank icons and the tracking menu
        Arrow.lua     the waypoint arrow (quests, your corpse)
        Tracker.lua   the objective tracker that replaces the stock quest watch
        Tooltip.lua   "Kobold Vermin: 4/8" on mobs and items your quests need
        Group.lua     party progress and share replies
        Log.lua       the two-pane quest log (L), LogDetail.lua its right pane,
                      LogPages.lua the Nearby / Completed / Options pages
        Init.lua      registration, slash commands

    Lua 5.0 rules throughout (the 1.12 client): no '#', no '%', no select(), arg tables.
]]--

local W = WenillaCore
local UI = W.UI

Compass = Compass or {}
local Q = Compass
Q.ID = "Quests"
local ID = Q.ID

local floor, sqrt = math.floor, math.sqrt
local atan2 = math.atan2 or math.atan

-- -- Settings ------------------------------------------------------------------------------

-- Every option, with its default (the schema in Init.lua describes them for the Addons window).
Q.DEFAULTS = {
    -- minimap
    showRing = true, ringTheme = "wildwood", replaceBorder = true, showCoords = true,
    showObjectives = true, showGivers = true, showTurnins = true, minimapPins = true,
    -- tracking (the compass rose menu)
    trackRepair = true, trackSell = true, trackFlight = false, trackInn = false,
    trackTrainer = false, trackBank = false,
    -- arrow
    showArrow = true, arrowAuto = true, corpseArrow = true, arrowChime = true, arrowScale = 1,
    -- tracker
    showTracker = true, autoTrack = true, trackerMax = 8,
    -- quest log
    replaceLog = true, hideGrey = false, autoPick = false, autoTurnIn = false,
    chimes = true, tooltips = true, worldMapPins = true, groupProgress = true,
    -- log view state (not shown as options)
    sortBy = "zone", filterZone = false, filterComplete = false, filterGroup = false, filterDungeon = false,
}

function Q:Get(key)
    local v = W:Settings(ID)[key]
    if v == nil then v = self.DEFAULTS[key] end
    return v
end

function Q:Set(key, value, quiet)
    W:Settings(ID)[key] = value
    if not quiet then W:Refresh(ID) end
end

function Q:Active() return W:IsActive(ID) end

-- Per-character data (SavedVariablesPerCharacter: Compass_CharDB). Restored after the files
-- run, so it is always looked up through here, never cached at load.
function Q:DB()
    if type(Compass_CharDB) ~= "table" then Compass_CharDB = {} end
    local d = Compass_CharDB
    d.tracked = d.tracked or {}         -- [title] = true
    d.collapsed = d.collapsed or {}     -- tracker: [title] = true
    d.zones = d.zones or {}             -- quest log: collapsed zone headers [zone] = true
    d.history = d.history or {}         -- { title, level, zone, t, how = "done"|"abandoned", giver }
    d.givers = d.givers or {}           -- [title] = { npc, zone, x, y }
    d.learned = d.learned or {}         -- [title] = { { zone, x, y }, ... } where progress happened
    return d
end

-- -- Events, internal signals, timers ------------------------------------------------------

local hub = CreateFrame("Frame", "Compass_Events")
Q.handlers = {}

-- Q:On("EVENT", fn): fn(event) runs with the usual this/event/arg1.. globals.
function Q:On(ev, fn)
    if not self.handlers[ev] then
        self.handlers[ev] = {}
        hub:RegisterEvent(ev)
    end
    table.insert(self.handlers[ev], fn)
end

hub:SetScript("OnEvent", function()
    local list = Q.handlers[event]
    if not list or not Q:Active() then return end
    for _, fn in ipairs(list) do
        local ok, err = pcall(fn, event)
        if not ok then W:Error(ID .. " " .. tostring(event), err) end
    end
end)

-- Signals between the files: Q:Listen("QuestsChanged", fn), Q:Fire("QuestsChanged", ...).
Q.listeners = {}
function Q:Listen(name, fn)
    self.listeners[name] = self.listeners[name] or {}
    table.insert(self.listeners[name], fn)
end
function Q:Fire(name, a1, a2, a3)
    for _, fn in ipairs(self.listeners[name] or {}) do
        local ok, err = pcall(fn, a1, a2, a3)
        if not ok then W:Error(ID .. " " .. name, err) end
    end
end

-- Q:Every(seconds, fn): fn(elapsed) on a shared updater while the addon is on.
Q.timers = {}
function Q:Every(interval, fn)
    table.insert(self.timers, { every = interval, fn = fn, acc = 0 })
end
-- Q:After(seconds, fn): once.
Q.later = {}
function Q:After(delay, fn)
    table.insert(self.later, { at = GetTime() + delay, fn = fn })
end

local updater = CreateFrame("Frame", "Compass_Updater")
Q.updater = updater
updater:SetScript("OnUpdate", function()
    local dt = arg1 or 0
    for _, t in ipairs(Q.timers) do
        t.acc = t.acc + dt
        if t.acc >= t.every then
            local e = t.acc
            t.acc = 0
            local ok, err = pcall(t.fn, e)
            if not ok then W:Error(ID .. " timer", err) end
        end
    end
    if Q.later[1] then
        local now, due = GetTime(), {}
        for i = table.getn(Q.later), 1, -1 do
            if Q.later[i].at <= now then
                table.insert(due, Q.later[i].fn)
                table.remove(Q.later, i)
            end
        end
        for _, fn in ipairs(due) do
            local ok, err = pcall(fn)
            if not ok then W:Error(ID .. " after", err) end
        end
    end
end)

-- Refresh hooks: Q:OnRefresh(fn(active)) runs when settings change or the addon is toggled.
Q.refreshers = {}
function Q:OnRefresh(fn) table.insert(self.refreshers, fn) end

-- -- Map geometry -----------------------------------------------------------------------------

local lastX, lastY = 0, 0

-- GetPlayerMapPosition answers for whatever map the world map was last left on. Left on a
-- continent (or another zone) it returns continent coordinates, or 0, 0, which put every pin,
-- ring marker and the arrow somewhere else entirely. So while the world map is closed, keep
-- the map on the player's zone: remember which map SetMapToCurrentZone picked for this zone
-- and set it again whenever the map is on anything else.
local mapFor, mapC, mapZ, mapCheck = nil, nil, nil, 0
function Q:EnsureZoneMap(force)
    if not (SetMapToCurrentZone and GetCurrentMapContinent and GetCurrentMapZone) then return end
    if WorldMapFrame and WorldMapFrame:IsVisible() then return end
    local now = GetTime()
    if not force and now < mapCheck then return end
    mapCheck = now + 0.5
    local zone = self:Zone()
    local c, z = GetCurrentMapContinent(), GetCurrentMapZone()
    if not force and mapFor == zone and c == mapC and z == mapZ then return end
    SetMapToCurrentZone()
    mapFor, mapC, mapZ = zone, GetCurrentMapContinent(), GetCurrentMapZone()
end

-- The player's position on the current zone map, 0..1 (0, 0 in instances and on taxis to
-- nowhere). While the world map is open on another zone the last known position is used.
function Q:PlayerPos()
    if WorldMapFrame and WorldMapFrame:IsVisible() then return lastX, lastY end
    self:EnsureZoneMap()
    local x, y = GetPlayerMapPosition("player")
    if (not x or (x == 0 and y == 0)) and SetMapToCurrentZone and GetTime() >= (self.nextMapReset or 0) then
        -- the map was left on another zone or a continent (in instances it stays 0, 0: retry slowly)
        self.nextMapReset = GetTime() + 2
        SetMapToCurrentZone()
        x, y = GetPlayerMapPosition("player")
    end
    lastX, lastY = x or 0, y or 0
    return lastX, lastY
end

function Q:Zone()
    local z = GetRealZoneText and GetRealZoneText() or ""
    if z == "" and GetZoneText then z = GetZoneText() or "" end
    return z
end

-- Width and height of a zone map in yards (Data.lua); a sensible guess for unknown zones.
function Q:ZoneSize(zone)
    local s = self.ZONE_SIZE and self.ZONE_SIZE[zone or self:Zone()]
    if s then return s[1], s[2], true end
    return 4000, 2667, false
end

-- Yards from (x1, y1) to (x2, y2) on one zone map, plus the east and south offsets in yards.
function Q:Yards(x1, y1, x2, y2, zone)
    local w, h = self:ZoneSize(zone)
    local dx, dy = (x2 - x1) * w, (y2 - y1) * h
    return sqrt(dx * dx + dy * dy), dx, dy
end

-- Screen angle (radians, 0 = east, counter-clockwise) from yard offsets east/south.
function Q:ScreenAngle(dx, dy) return atan2(-dy, dx) end

function Q:YardText(yards)
    yards = floor((yards or 0) + 0.5)
    if yards >= 10000 then return string.format("%.1fk yd", yards / 1000) end
    return yards .. " yd"
end

function Q:CoordText(x, y) return string.format("%.1f, %.1f", (x or 0) * 100, (y or 0) * 100) end

-- -- Difficulty colours (as the stock quest log) -------------------------------------------

Q.DIFF = {
    red = { 1, 0.10, 0.10 }, orange = { 1, 0.50, 0.25 }, yellow = { 1, 0.82, 0 },
    green = { 0.25, 0.75, 0.25 }, grey = { 0.50, 0.50, 0.50 },
}

function Q:GreyLevel(pl)
    pl = pl or UnitLevel("player") or 1
    if pl <= 5 then return 0 end
    if pl <= 39 then return pl - 5 - floor(pl / 10) end
    return pl - 1 - floor(pl / 5)
end

function Q:IsGrey(level)
    return (level or 0) > 0 and level <= self:GreyLevel()
end

function Q:DiffKey(level)
    local pl = UnitLevel("player") or 1
    local d = (level or pl) - pl
    if d >= 5 then return "red" end
    if d >= 3 then return "orange" end
    if d >= -2 then return "yellow" end
    if self:IsGrey(level) then return "grey" end
    return "green"
end

function Q:DiffColor(level)
    local c = self.DIFF[self:DiffKey(level)]
    return c[1], c[2], c[3]
end

function Q:Hex(r, g, b)
    return string.format("|cff%02x%02x%02x", floor(r * 255 + 0.5), floor(g * 255 + 0.5), floor(b * 255 + 0.5))
end

function Q:DiffHex(level) return self:Hex(self:DiffColor(level)) end

-- -- Small helpers -----------------------------------------------------------------------------

function Q:Print(msg) W.Print(msg) end

function Q:Lower(s) return string.lower(s or "") end

-- Plain-text "contains", case-insensitive.
function Q:Has(hay, needle)
    if not needle or needle == "" then return true end
    return string.find(string.lower(hay or ""), string.lower(needle), 1, true) and true or false
end

-- Insert text into an open chat edit box (Shift-click); returns true when it did.
function Q:InsertChat(text)
    if ChatFrameEditBox and ChatFrameEditBox:IsVisible() then
        ChatFrameEditBox:Insert(text)
        return true
    end
    return false
end
