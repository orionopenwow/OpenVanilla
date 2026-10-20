--[[
    Tracker.lua  -  Quests: the objective tracker (replaces the stock quest watch).

    A movable list on the right of the screen: each tracked quest with its level, difficulty
    colour and progress, and its objectives underneath ("Kobold Vermin: 4/8").
      click a quest         pin it to the ring (the arrow points to it; click again to unpin)
      Shift-click           stop tracking it
      right-click           open it in the quest log, show it on the map, pin, untrack
      the +/- by a quest    fold its objectives away
    New quests are tracked automatically (an option). The stock QuestWatchFrame stays hidden
    while the tracker is on.

    Look: a dimmed parchment page in a dark iron frame with filigree corners, a gold rule over the
    header, a green ! by "Quests", red seals by each quest (a shield once it is done). Text as the
    stock quest tracker: yellow quest titles, light objectives, green when done, all with a dark
    shadow (dark ink on the parchment was unreadable in the game, where the page renders darker). Art: Interface\ClassicPlus\Quests_*.blp; without it the tracker keeps the
    plain dark panel.
]]--

local W = WenillaCore
local UI = W.UI
local Q = Compass

local WIDTH = 262
local INK = { 0.95, 0.92, 0.85 }          -- objectives and counts: light, as the stock tracker
local TITLE = { 1, 0.82, 0 }              -- quest titles: the stock tracker's yellow
local DONE = { 0.45, 1, 0.45 }            -- "Done" and ready-to-turn-in lines
local FAIL = { 1, 0.35, 0.3 }
local ROW_H, LINE_H = 18, 14

local tracker = CreateFrame("Frame", "Compass_Tracker", UIParent)
tracker:SetWidth(WIDTH)
tracker:SetHeight(40)
tracker.defaultPoint = { "TOPRIGHT", UIParent, "TOPRIGHT", -26, -262 }
tracker:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -26, -262)
tracker:SetFrameStrata("LOW")
tracker:SetMovable(true)
if tracker.SetClampedToScreen then tracker:SetClampedToScreen(true) end
tracker:Hide()
Q.tracker = tracker

-- Parchment and frame. The frame art (256x256) is cut nine ways: corners at their own size,
-- edges stretched.
local parch = tracker:CreateTexture(nil, "BACKGROUND")
parch:SetPoint("TOPLEFT", tracker, "TOPLEFT", 6, -6)
parch:SetPoint("BOTTOMRIGHT", tracker, "BOTTOMRIGHT", -6, 6)
local skinned = W:Art(parch, "Quests_Parchment", nil)
tracker.skinned = skinned
if skinned then parch:SetVertexColor(0.55, 0.5, 0.45) end   -- dimmed, so light text stands out
local C, CS = 40 / 256, 26       -- slice in the art, corner size on screen
local function piece(l, r, t, b)
    local x = tracker:CreateTexture(nil, "BORDER")
    W:Art(x, "Quests_Frame", nil)
    x:SetTexCoord(l, r, t, b)
    return x
end
if skinned then
    local tl, tr = piece(0, C, 0, C), piece(1 - C, 1, 0, C)
    local bl, br = piece(0, C, 1 - C, 1), piece(1 - C, 1, 1 - C, 1)
    for _, x in ipairs({ tl, tr, bl, br }) do x:SetWidth(CS); x:SetHeight(CS) end
    tl:SetPoint("TOPLEFT", tracker, "TOPLEFT", 0, 0); tr:SetPoint("TOPRIGHT", tracker, "TOPRIGHT", 0, 0)
    bl:SetPoint("BOTTOMLEFT", tracker, "BOTTOMLEFT", 0, 0); br:SetPoint("BOTTOMRIGHT", tracker, "BOTTOMRIGHT", 0, 0)
    local top, bot = piece(C, 1 - C, 0, C), piece(C, 1 - C, 1 - C, 1)
    local lef, rig = piece(0, C, C, 1 - C), piece(1 - C, 1, C, 1 - C)
    top:SetPoint("TOPLEFT", tl, "TOPRIGHT"); top:SetPoint("BOTTOMRIGHT", tr, "BOTTOMLEFT")
    bot:SetPoint("TOPLEFT", bl, "TOPRIGHT"); bot:SetPoint("BOTTOMRIGHT", br, "BOTTOMLEFT")
    lef:SetPoint("TOPLEFT", tl, "BOTTOMLEFT"); lef:SetPoint("BOTTOMRIGHT", bl, "TOPRIGHT")
    rig:SetPoint("TOPLEFT", tr, "BOTTOMLEFT"); rig:SetPoint("BOTTOMRIGHT", br, "TOPRIGHT")
else
    tracker:SetBackdrop(UI.THIN)
    tracker:SetBackdropColor(0.03, 0.035, 0.045, 0.55)
    tracker:SetBackdropBorderColor(UI.EDGE[1], UI.EDGE[2], UI.EDGE[3], 0.45)
end

-- A label on the parchment: a game font, the colour, and a dark shadow so it reads on any page.
local function ink(fs, font, size, color, light)
    if skinned and fs.SetFont then fs:SetFont(font, size) end
    if skinned then
        fs:SetTextColor(color[1], color[2], color[3])
        if fs.SetShadowColor then fs:SetShadowColor(0, 0, 0, light and 1 or 0.8) end
        if fs.SetShadowOffset then fs:SetShadowOffset(1, -1) end
    end
end
local FRIZ, MORPH = "Fonts\\FRIZQT__.TTF", "Fonts\\MORPHEUS.TTF"

-- header: drag handle, title, count, fold-all
local head = CreateFrame("Button", "Compass_TrackerHeader", tracker)
head:SetHeight(skinned and 26 or 18)
head:SetPoint("TOPLEFT", tracker, "TOPLEFT", skinned and 16 or 4, skinned and -18 or -3)
head:SetPoint("TOPRIGHT", tracker, "TOPRIGHT", skinned and -16 or -4, skinned and -18 or -3)
if skinned then
    local rule = tracker:CreateTexture(nil, "ARTWORK")
    W:Art(rule, "Quests_Bar", nil)
    rule:SetHeight(12)
    rule:SetPoint("BOTTOMLEFT", head, "TOPLEFT", -2, -3)
    rule:SetPoint("BOTTOMRIGHT", head, "TOPRIGHT", 2, -3)
    -- no band behind the header: "Quests" and the count are ink on the parchment, like the rows
    -- (the band showed as a white bar in the game client)
end
head:RegisterForDrag("LeftButton")
head:RegisterForClicks("LeftButtonUp", "RightButtonUp")
head:SetScript("OnDragStart", function() tracker:StartMoving() end)
head:SetScript("OnDragStop", function()
    tracker:StopMovingOrSizing()
    W:SavePosition(tracker)
end)
head:SetScript("OnClick", function()
    if arg1 == "RightButton" then
        UI.Menu(this, {
            { text = "Objective tracker", title = true },
            { text = "Open the quest log", func = function() Q.Log:Open() end },
            { text = "Track every quest", func = function() for _, q in ipairs(Q.quests) do Q:SetTracked(q.key, true) end end },
            { text = "Track new quests", checked = Q:Get("autoTrack"), func = function() Q:Set("autoTrack", not Q:Get("autoTrack")) end },
            { text = "Hide the tracker", func = function() Q:Set("showTracker", false); Q:Print("Tracker hidden. /quests tracker brings it back.") end },
        })
    else
        Q.Log:Toggle()
    end
end)
local headIcon = head:CreateTexture(nil, "ARTWORK")
headIcon:SetWidth(skinned and 24 or 13)
headIcon:SetHeight(skinned and 24 or 13)
headIcon:SetPoint("LEFT", head, "LEFT", 1, 0)
if not (skinned and W:Art(headIcon, "Quests_HeadIcon", nil)) and not W:Art(headIcon, "Quests_PinGiver", nil) then
    headIcon:SetTexture("Interface\\GossipFrame\\AvailableQuestIcon")
end
local headText = UI.Label(head, 11, UI.ACCENT, skinned and nil or "OUTLINE")
headText:SetPoint("LEFT", headIcon, "RIGHT", 4, 0)
headText:SetText("Quests")
-- "Quests" in the quest log's Friz Quadrata, gold with a dark shadow
if skinned then
    if headText.SetFont then headText:SetFont(FRIZ, 15) end
    headText:SetTextColor(TITLE[1], TITLE[2], TITLE[3])
    if headText.SetShadowColor then headText:SetShadowColor(0, 0, 0, 1); headText:SetShadowOffset(1, -1) end
end
local headCount = UI.Label(head, 10, UI.MUTED, skinned and nil or "OUTLINE")
headCount:SetPoint("RIGHT", head, "RIGHT", skinned and -28 or -18, 0)
-- the count: light, a quieter partner to the "Quests" title
if skinned then
    if headCount.SetFont then headCount:SetFont(FRIZ, 12) end
    headCount:SetTextColor(INK[1], INK[2], INK[3])
    if headCount.SetShadowColor then headCount:SetShadowColor(0, 0, 0, 1); headCount:SetShadowOffset(1, -1) end
end
if skinned then
    headCount:SetWidth(120)
    headText:SetWidth(90)
    if headText.SetNonSpaceWrap then headText:SetNonSpaceWrap(false) end
end
headCount:SetJustifyH("RIGHT")
tracker.count = headCount

local fold = CreateFrame("Button", "Compass_TrackerFold", tracker)
fold:SetWidth(skinned and 18 or 14)
fold:SetHeight(skinned and 18 or 14)
fold:SetPoint("RIGHT", head, "RIGHT", skinned and -4 or 0, 0)
fold.tex = fold:CreateTexture(nil, "ARTWORK")
fold.tex:SetAllPoints(fold)
fold:SetHighlightTexture("Interface\\Buttons\\UI-PlusButton-Hilight")
local function foldArt(folded)
    if skinned then
        W:Art(fold.tex, folded and "Quests_FoldPlus" or "Quests_FoldMinus", nil)
    else
        fold.tex:SetTexture(folded and "Interface\\Buttons\\UI-PlusButton-Up" or "Interface\\Buttons\\UI-MinusButton-Up")
    end
end
foldArt(false)
-- the close seal in the frame's corner: hides the tracker (the quest log and /quests bring it back)
if skinned then
    local close = CreateFrame("Button", "Compass_TrackerClose", tracker)
    close:SetWidth(22); close:SetHeight(22)
    close:SetPoint("TOPRIGHT", tracker, "TOPRIGHT", -4, -4)   -- inside the corner trim, not on it
    close:SetFrameLevel(tracker:GetFrameLevel() + 8)
    local ct = close:CreateTexture(nil, "ARTWORK"); ct:SetAllPoints(close); W:Art(ct, "Quests_Close", nil)
    close:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight")
    close:SetScript("OnClick", function()
        Q:Set("showTracker", false)
        Q:Print("Tracker hidden. /quests tracker brings it back.")
    end)
end
fold:SetScript("OnClick", function()
    Q.trackerFolded = not Q.trackerFolded
    Q:UpdateTracker()
end)

-- -- Rows ----------------------------------------------------------------------------------------

local questRows, lineRows = {}, {}

local function questRow(i)
    if questRows[i] then return questRows[i] end
    local r = CreateFrame("Button", "Compass_TrackerQuest" .. i, tracker)
    r:SetHeight(skinned and ROW_H or 15)
    r:SetWidth(WIDTH - (skinned and 26 or 10))
    r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local hl = r:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(r)
    hl:SetTexture(skinned and 0.45 or 1, skinned and 0.30 or 0.82, 0, skinned and 0.10 or 0.08)
    r.toggle = CreateFrame("Button", "Compass_TrackerToggle" .. i, r)
    r.toggle:SetWidth(skinned and 16 or 12)
    r.toggle:SetHeight(skinned and 16 or 12)
    r.toggle:SetPoint("LEFT", r, "LEFT", 0, 0)
    r.toggleTex = r.toggle:CreateTexture(nil, "ARTWORK")
    r.toggleTex:SetAllPoints(r.toggle)
    r.toggle:SetScript("OnClick", function()
        local key = this:GetParent().key
        local db = Q:DB()
        db.collapsed[key] = (not db.collapsed[key]) and true or nil
        Q:UpdateTracker()
    end)
    r.pin = r:CreateTexture(nil, "OVERLAY")
    r.pin:SetWidth(8)
    r.pin:SetHeight(8)
    r.pin:SetPoint("LEFT", r.toggle, "RIGHT", 2, 0)
    if not W:Art(r.pin, "PinDot", nil) then r.pin:SetTexture(1, 1, 1, 1) end
    r.pin:SetVertexColor(1, 0.86, 0.15)
    r.label = UI.Label(r, 11, nil, skinned and nil or "OUTLINE")
    r.label:SetPoint("LEFT", r.toggle, "RIGHT", 3, 0)
    r.label:SetWidth(WIDTH - (skinned and 86 or 62))
    r.label:SetHeight(skinned and 16 or 14)          -- one line; long titles are cut, not wrapped
    if r.label.SetNonSpaceWrap then r.label:SetNonSpaceWrap(false) end
    ink(r.label, FRIZ, 13, TITLE, true)
    r.right = UI.Label(r, 10, nil, skinned and nil or "OUTLINE")
    ink(r.right, FRIZ, 12, INK, true)
    r.right:SetPoint("RIGHT", r, "RIGHT", -2, 0)
    r.right:SetJustifyH("RIGHT")
    r:SetScript("OnClick", function()
        local key = this.key
        if not key then return end
        if arg1 == "RightButton" then
            Q:QuestMenu(this, key)
        elseif IsShiftKeyDown() then
            Q:SetTracked(key, false)
            Q:Print("Stopped tracking \"" .. key .. "\".")
        else
            Q:PinQuest(key)
        end
    end)
    r:SetScript("OnEnter", function()
        local q = Q.byKey[this.key]
        if not q then return end
        GameTooltip:SetOwner(this, "ANCHOR_LEFT")
        GameTooltip:SetText(q.title, Q:DiffColor(q.level))
        GameTooltip:AddLine("Level " .. q.level .. " · " .. q.zone, 0.8, 0.8, 0.8)
        local n, d = Q:BestNode(q.key)
        if d then GameTooltip:AddLine((q.complete and "Turn-in: " or "Nearest objective: ") .. Q:YardText(d), 1, 1, 1) end
        GameTooltip:AddLine(Q.pinnedKey == q.key and "Click to unpin from the ring." or "Click to pin it to the ring.", 0.6, 0.6, 0.6)
        GameTooltip:AddLine("Shift-click to stop tracking. Right-click for more.", 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    questRows[i] = r
    return r
end

local function lineRow(i)
    if lineRows[i] then return lineRows[i] end
    local fs = UI.Label(tracker, 10, nil, nil)
    fs:SetWidth(WIDTH - (skinned and 52 or 28))       -- ends inside the right border
    fs:SetHeight(skinned and LINE_H or 12)
    ink(fs, FRIZ, 11, INK, true)
    if fs.SetNonSpaceWrap then fs:SetNonSpaceWrap(false) end
    lineRows[i] = fs
    return fs
end

local more = CreateFrame("Button", "Compass_TrackerMore", tracker)
more:SetHeight(14)
more:SetWidth(WIDTH - 10)
more.text = UI.Label(more, 10, UI.MUTED, nil)
more.text:SetPoint("LEFT", more, "LEFT", 4, 0)
ink(more.text, FRIZ, 11, { 0.8, 0.78, 0.72 }, true)
more:SetScript("OnClick", function() Q.Log:Open() end)

-- Right-click menu for a quest (tracker and quest log share it).
function Q:QuestMenu(anchor, key)
    local q = self.byKey[key]
    if not q then return end
    UI.Menu(anchor, {
        { text = q.title, title = true },
        { text = "Open in the quest log", func = function() Q.Log:Open(key) end },
        { text = "Show on the map", func = function()
            if Q:ShowOnMap(key) == 0 then Q:Print("No map pins for \"" .. key .. "\" yet.") end
        end },
        { text = (Q.pinnedKey == key) and "Unpin from the ring" or "Pin to the ring", func = function() Q:PinQuest(key) end },
        { text = Q:IsTracked(key) and "Stop tracking" or "Track", func = function() Q:SetTracked(key, not Q:IsTracked(key)) end },
    })
end

-- -- Layout -------------------------------------------------------------------------------------

function Q:TrackerOn() return self:Active() and self:Get("showTracker") and true or false end

local function sortTracked(list)
    local zone = Q:Zone()
    table.sort(list, function(a, b)
        local pa, pb = (a.key == Q.pinnedKey), (b.key == Q.pinnedKey)
        if pa ~= pb then return pa end
        local za, zb = (a.zone == zone), (b.zone == zone)
        if za ~= zb then return za end
        if a.complete ~= b.complete then return a.complete end
        if a.level ~= b.level then return a.level < b.level end
        return a.title < b.title
    end)
end

function Q:UpdateTracker()
    for _, r in ipairs(questRows) do r:Hide(); r.key = nil end
    for _, l in ipairs(lineRows) do l:Hide() end
    more:Hide()
    if not self:TrackerOn() then
        tracker:Hide()
        return
    end
    if QuestWatchFrame then QuestWatchFrame:Hide() end
    local list = self:TrackedQuests()
    if not list[1] then
        tracker:Hide()
        return
    end
    sortTracked(list)
    headCount:SetText(table.getn(list) .. " tracked · " .. self.numQuests .. "/" .. self.MAX_QUESTS)
    foldArt(self.trackerFolded)
    local y = skinned and -50 or -23
    local x0 = skinned and 14 or 6
    local db = self:DB()
    local maxQ = tonumber(self:Get("trackerMax")) or 8
    local nl = 0
    if not self.trackerFolded then
        for i, q in ipairs(list) do
            if i > maxQ then break end
            local r = questRow(i)
            r.key = q.key
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", tracker, "TOPLEFT", x0, y)
            local collapsed = db.collapsed[q.key]
            if skinned then
                -- the seal: a shield once the quest is done (folded or not), else - / +
                W:Art(r.toggleTex, q.complete and "Quests_Shield" or (collapsed and "Quests_RowPlus" or "Quests_RowMinus"), nil)
            else
                r.toggleTex:SetTexture(collapsed and "Interface\\Buttons\\UI-PlusButton-Up" or "Interface\\Buttons\\UI-MinusButton-Up")
            end
            local pinned = (self.pinnedKey == q.key)
            if pinned then r.pin:Show() else r.pin:Hide() end
            r.label:ClearAllPoints()
            r.label:SetPoint("LEFT", pinned and r.pin or r.toggle, "RIGHT", 3, 0)
            r.label:SetText("[" .. q.level .. "] " .. q.title)
            if skinned then
                r.label:SetTextColor(TITLE[1], TITLE[2], TITLE[3])   -- yellow, as the stock tracker
            else
                r.label:SetTextColor(self:DiffColor(q.level))
            end
            if q.failed then
                r.right:SetText("Failed")
                if skinned then r.right:SetTextColor(FAIL[1], FAIL[2], FAIL[3]) else r.right:SetTextColor(1, 0.3, 0.25) end
            elseif q.complete then
                r.right:SetText("Done")
                if skinned then r.right:SetTextColor(DONE[1], DONE[2], DONE[3]) else r.right:SetTextColor(0.45, 1, 0.45) end
            else
                r.right:SetText(q.done .. "/" .. q.total)
                if skinned then r.right:SetTextColor(INK[1], INK[2], INK[3]) else r.right:SetTextColor(0.9, 0.9, 0.9) end
            end
            r:Show()
            y = y - (skinned and ROW_H or 15)
            if not collapsed then
                y = y - (skinned and 4 or 1)                      -- air between the title and its lines
                local lines = {}
                if q.complete then
                    local m = self.meta[q.title]
                    local who = (m and m.turnIn and m.turnIn.npc) and (" to " .. m.turnIn.npc) or ""
                    if skinned then table.insert(lines, { "Ready to turn in" .. who, DONE[1], DONE[2], DONE[3] })
                    else table.insert(lines, { "Ready to turn in" .. who, 0.45, 1, 0.45 }) end
                elseif q.failed then
                    if skinned then table.insert(lines, { "Failed - abandon it and pick it up again", FAIL[1], FAIL[2], FAIL[3] })
                    else table.insert(lines, { "Failed - abandon it and pick it up again", 1, 0.35, 0.3 }) end
                else
                    for _, o in ipairs(q.objectives) do
                        local text = o.name
                        if o.need > 1 or o.type == "item" or o.type == "monster" then text = o.name .. ": " .. o.have .. "/" .. o.need end
                        if o.done then
                            if skinned then table.insert(lines, { text, DONE[1], DONE[2], DONE[3] })
                            else table.insert(lines, { text, 0.5, 0.75, 0.5 }) end
                        else
                            if skinned then table.insert(lines, { text, INK[1], INK[2], INK[3] })
                            else table.insert(lines, { text, 0.92, 0.92, 0.92 }) end
                        end
                    end
                end
                for _, l in ipairs(lines) do
                    nl = nl + 1
                    local fs = lineRow(nl)
                    fs:ClearAllPoints()
                    fs:SetPoint("TOPLEFT", tracker, "TOPLEFT", x0 + (skinned and 22 or 16), y)
                    fs:SetText("- " .. l[1])
                    fs:SetTextColor(l[2], l[3], l[4])
                    fs:Show()
                    y = y - (skinned and LINE_H or 12)
                end
            end
            y = y - (skinned and 6 or 3)
        end
        local extra = table.getn(list) - maxQ
        if extra > 0 then
            more:ClearAllPoints()
            more:SetPoint("TOPLEFT", tracker, "TOPLEFT", x0, y)
            more.text:SetText("+" .. extra .. " more in the quest log")
            more:Show()
            y = y - 15
        end
    end
    tracker:SetHeight(-y + (skinned and 16 or 6))
    tracker:Show()
end

-- Keep the stock watch frame hidden while ours is on.
local origWatch = QuestWatch_Update
if origWatch then
    function QuestWatch_Update()
        origWatch()
        if Q:TrackerOn() and QuestWatchFrame then QuestWatchFrame:Hide() end
    end
end

-- First login with this addon: track whatever is in the log.
Q:Listen("QuestsChanged", function()
    local db = Q:DB()
    if not db.trackInit then
        db.trackInit = true
        for _, q in ipairs(Q.quests) do db.tracked[q.key] = true end
    end
    Q:UpdateTracker()
end)
Q:Listen("TrackingChanged", function() Q:UpdateTracker() end)
Q:Listen("MetaChanged", function() Q:UpdateTracker() end)
Q:On("ZONE_CHANGED_NEW_AREA", function() Q:UpdateTracker() end)
Q:OnRefresh(function(active)
    Q:UpdateTracker()
    if not Q:TrackerOn() and QuestWatchFrame and origWatch then
        origWatch()         -- hand the stock watch frame back
    end
end)
W:TrackPosition(tracker)
