--[[
    QuestData.lua  -  Quests: the quest log as data.

    Q:ScanLog() reads every quest (expanding collapsed headers first) into Q.quests:
        { index, key, title, level, tag, zone, complete, failed, objectives = {
            { text, type, name, have, need, done } }, done, total, class, group, dungeon, raid, elite }
    and compares it with the previous scan to fire:
        QuestsChanged()                    after every scan
        QuestAdded(q)  QuestRemoved(q, how)   how = "done" | "abandoned" | "gone"
        Progress(q, o)  ObjectiveDone(q, o)  QuestComplete(q)
    It also keeps the per-character history of turned-in and abandoned quests, remembers who
    gave each quest (and where), and where progress was made ("learned" objective spots).
]]--

local W = WenillaCore
local Q = Compass

local floor = math.floor

Q.quests = {}
Q.byKey = {}
Q.numQuests = 0
Q.MAX_QUESTS = 20

-- "Kobold Vermin slain: 4/8" -> name "Kobold Vermin", 4, 8
function Q:ParseObjective(text, otype, finished)
    local o = { text = text or "", type = otype or "", done = finished and true or false }
    local _, _, name, have, need = string.find(o.text, "^(.-):%s*(%d+)%s*/%s*(%d+)")
    if name then
        local _, _, mob = string.find(name, "^(.-) slain$")
        o.name = mob or name
        o.have, o.need = tonumber(have), tonumber(need)
        if o.have >= o.need then o.done = true end
    else
        local _, _, plain = string.find(o.text, "^(.-)%s*%(?[Cc]omplete%)?$")
        o.name = (plain and plain ~= "") and plain or o.text
        o.have, o.need = o.done and 1 or 0, 1
    end
    return o
end

local function tags(q, tag, playerClass)
    q.tag = tag
    q.elite = (tag == "Elite")
    q.dungeon = (tag == "Dungeon")
    q.raid = (tag == "Raid")
    q.pvp = (tag == "PVP")
    q.group = q.elite or q.dungeon or q.raid or (tag == "Group")
    -- 1.12 files class quests under a header named after the class
    q.class = (playerClass and q.zone == playerClass) and true or false
end

function Q:Tags(q)
    local out = {}
    if q.elite then table.insert(out, "Elite") end
    if q.dungeon then table.insert(out, "Dungeon") end
    if q.raid then table.insert(out, "Raid") end
    if q.pvp then table.insert(out, "PvP") end
    if q.tag == "Group" then table.insert(out, "Group") end
    if q.class then table.insert(out, "Class") end
    return out
end

function Q:ScanLog()
    if not GetNumQuestLogEntries then return end
    local entries, numQuests = GetNumQuestLogEntries()
    local playerClass = UnitClass("player")
    local list, by = {}, {}
    local zone = "Other"
    local i = 1
    while i <= (entries or 0) do
        local title, level, tag, isHeader, collapsed, complete = GetQuestLogTitle(i)
        if isHeader then
            zone = title or zone
            if collapsed and ExpandQuestHeader then
                ExpandQuestHeader(i)
                entries = GetNumQuestLogEntries()
            end
        elseif title then
            local q = { index = i, title = title, level = level or 0, zone = zone,
                complete = (complete == 1), failed = (complete == -1), objectives = {} }
            tags(q, tag, playerClass)
            local key = title
            if by[key] then key = title .. " (" .. (level or 0) .. ")" end
            q.key = key
            local done, total = 0, 0
            local n = GetNumQuestLeaderBoards and GetNumQuestLeaderBoards(i) or 0
            for j = 1, (n or 0) do
                local text, otype, finished = GetQuestLogLeaderBoard(j, i)
                local o = self:ParseObjective(text, otype, finished)
                table.insert(q.objectives, o)
                done = done + math.min(o.have, o.need)
                total = total + o.need
            end
            if total == 0 then total, done = 1, q.complete and 1 or 0 end
            q.done, q.total = done, total
            q.progress = done / total
            table.insert(list, q)
            by[key] = q
        end
        i = i + 1
    end
    local old = self.byKey
    local firstScan = not self.scanned
    self.quests, self.byKey = list, by
    self.numQuests = table.getn(list)
    self.scanned = true
    if not firstScan then self:Diff(old, by) end
    self:Fire("QuestsChanged")
end

function Q:Diff(old, new)
    for key, q in pairs(new) do
        local was = old[key]
        if not was then
            self:Fire("QuestAdded", q)
        else
            for j, o in ipairs(q.objectives) do
                local p = was.objectives[j]
                if p and o.have > p.have then
                    self:Fire("Progress", q, o)
                    if o.done and not p.done then self:Fire("ObjectiveDone", q, o) end
                end
            end
            if q.complete and not was.complete then self:Fire("QuestComplete", q) end
        end
    end
    for key, q in pairs(old) do
        if not new[key] then
            local how = "gone"
            if self.turningIn == q.title then how = "done"; self.turningIn = nil end
            if self.abandoning and self.abandoning[q.title] then how = "abandoned"; self.abandoning[q.title] = nil end
            self:Fire("QuestRemoved", q, how)
        end
    end
end

function Q:FindQuest(title)
    if not title then return nil end
    if self.byKey[title] then return self.byKey[title] end
    for _, q in ipairs(self.quests) do
        if q.title == title then return q end
    end
    -- the realm cuts long titles to 48 characters in CP packets
    local n = string.len(title)
    if n >= 48 then
        for _, q in ipairs(self.quests) do
            if string.sub(q.title, 1, n) == title then return q end
        end
    end
end

-- Quest log index by title (indices shift when quests come and go).
function Q:IndexOf(title)
    local q = self:FindQuest(title)
    if not q then return nil end
    local t = GetQuestLogTitle(q.index)
    if t == q.title then return q.index end
    local n = GetNumQuestLogEntries()
    for i = 1, n or 0 do
        local t2, _, _, header = GetQuestLogTitle(i)
        if not header and t2 == q.title then return i end
    end
end

-- Run fn with the quest selected in the log, then put the selection back.
function Q:WithSelected(title, fn)
    local idx = self:IndexOf(title)
    if not idx or not SelectQuestLogEntry then return nil end
    local prev = GetQuestLogSelection and GetQuestLogSelection() or 0
    SelectQuestLogEntry(idx)
    local ok, a, b, c = pcall(fn, idx)
    if prev and prev > 0 and prev ~= idx then SelectQuestLogEntry(prev) end
    if not ok then W:Error(self.ID .. " select", a) return nil end
    return a, b, c
end

-- -- Tracking state (per character) --------------------------------------------------------

function Q:IsTracked(key) return self:DB().tracked[key] and true or false end

function Q:SetTracked(key, on)
    self:DB().tracked[key] = on and true or nil
    if not on and self.pinnedKey == key then self.pinnedKey = nil end
    self:Fire("TrackingChanged", key)
end

function Q:TrackedQuests()
    local out = {}
    for _, q in ipairs(self.quests) do
        if self:IsTracked(q.key) then table.insert(out, q) end
    end
    return out
end

-- -- History, givers, learned spots -----------------------------------------------------------

function Q:AddHistory(q, how)
    local db = self:DB()
    table.insert(db.history, 1, { title = q.title, level = q.level, zone = q.zone, t = time(), how = how,
        giver = db.givers[q.title] })
    while table.getn(db.history) > 300 do table.remove(db.history) end
    db.learned[q.title] = nil
    db.tracked[q.key] = nil
    db.collapsed[q.key] = nil
end

-- Progress happened here: remember the spot (a few per quest) as a likely objective location.
function Q:Learn(q)
    local x, y = self:PlayerPos()
    if x == 0 and y == 0 then return end
    local db = self:DB()
    local list = db.learned[q.title] or {}
    db.learned[q.title] = list
    local zone = self:Zone()
    for _, s in ipairs(list) do
        if s.zone == zone and self:Yards(s.x, s.y, x, y, zone) < 40 then return end
    end
    table.insert(list, { zone = zone, x = x, y = y })
    while table.getn(list) > 4 do table.remove(list, 1) end
    self:Fire("LearnedSpot", q)
end

Q:Listen("QuestRemoved", function(q, how)
    if how == "done" or how == "abandoned" then Q:AddHistory(q, how) end
end)

Q:Listen("QuestAdded", function(q)
    if Q:Get("autoTrack") then Q:SetTracked(q.key, true) end
end)

Q:Listen("Progress", function(q) Q:Learn(q) end)

-- Who gave the quest, and where (for "talk to them again" after an abandon, and the detail pane).
local function rememberGiver()
    local title = GetTitleText and GetTitleText()
    if not title or title == "" then return end
    local x, y = Q:PlayerPos()
    Q:DB().givers[title] = { npc = UnitName("npc"), zone = Q:Zone(), x = x, y = y }
end

-- The stock functions are wrapped, never replaced: the wrapper notes what is happening, then
-- calls the original.
local origAccept = AcceptQuest
if origAccept then
    function AcceptQuest()
        if Q:Active() then pcall(rememberGiver) end
        return origAccept()
    end
end

local origReward = GetQuestReward
if origReward then
    function GetQuestReward(choice)
        if GetTitleText then Q.turningIn = GetTitleText() end
        return origReward(choice)
    end
end

local origAbandon = AbandonQuest
if origAbandon then
    function AbandonQuest()
        local name = GetAbandonQuestName and GetAbandonQuestName()
        if name then
            Q.abandoning = Q.abandoning or {}
            Q.abandoning[name] = true
        end
        return origAbandon()
    end
end

-- -- Events --------------------------------------------------------------------------------

local pending = false
Q:On("QUEST_LOG_UPDATE", function() pending = true end)
Q:On("PLAYER_ENTERING_WORLD", function() pending = true end)
Q:On("PLAYER_LEVEL_UP", function() Q:Fire("QuestsChanged") end)
Q:On("UNIT_QUEST_LOG_CHANGED", function() if arg1 == "player" then pending = true end end)

-- Scan at most five times a second; QUEST_LOG_UPDATE comes in bursts.
Q:Every(0.2, function()
    if pending then
        pending = false
        Q:ScanLog()
    end
end)

function Q:RequestScan() pending = true end
