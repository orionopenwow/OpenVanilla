--[[
    Nodes.lua  -  Quests: map nodes per quest, and the realm's quest packets.

    A node is one spot on a zone map that belongs to a quest:
        { type = "OBJ" | "GIVER" | "TURNIN", title = quest title, zone = "Elwynn Forest",
          x = 0..1, y = 0..1, label = "Kobold Vermin" (optional), source = "CP" | "QZ" | "learned" | ... }
    The API is modelled on pfQuest's node store:
        Q:AddNode(key, node)              add a node to quest `key` (its title)
        Q:DeleteNode(key, type, source)   remove that quest's nodes (type and source optional)
        Q:GetNodes(key)                   the quest's nodes
        Q:ZoneNodes(zone)                 every node on a zone map
    Nodes are drawn on the minimap / ring here, on the world map in WorldMap.lua, and give the
    arrow its targets. Gold = objective, green = quest available, red = ready to turn in.

    Realm packets (all optional; without them the client still learns objective spots itself):
      CP <questId>,<x>,<y>,<OBJ|GIVER|TURNIN>[:m<creatureId>|:i<itemId>|:o<objectId>...][,<title>];...
         quest pins for the player's zone; an empty body clears them
      QZ <zoneId>;<questId>,<x>,<y>,<level>,<minLevel>,<giver>,<title>;...
         quests the player can pick up in this zone (asked with ".wnl qz")
      QM <questId>,<chainPos>,<chainLen>,<xp>,<turnInX>,<turnInY>,<turnInZoneId>,<turnInNpc>,<title>;...
         facts about the quests in the player's log (asked with ".wnl qm")
      QU ok,<title> | QU err,<reason>   reply to ".wnl qundo <title>" (restore an abandoned quest)
]]--

local W = WenillaCore
local UI = W.UI
local Q = Compass

Q.nodes = {}        -- [key] = { node, ... }
Q.pins = {}         -- the last CP packet, as received (kept for older code and tests)
Q.nearby = {}       -- QZ: quests to pick up in this zone
Q.meta = {}         -- QM: [title] = { id, chainPos, chainLen, xp, turnIn = { npc, zone, x, y } }
Q.itemIds = {}      -- CP item ids: [itemId] = quest title

Q.KIND_COLOR = {
    OBJ = { 1.00, 0.86, 0.15 },     -- objective: gold
    GIVER = { 0.25, 0.92, 0.35 },   -- quest available: green
    TURNIN = { 0.95, 0.25, 0.20 },  -- ready to turn in: red
}
Q.KIND_LABEL = { OBJ = "Objective", GIVER = "Quest available", TURNIN = "Ready to turn in" }
Q.KIND_SETTING = { OBJ = "showObjectives", GIVER = "showGivers", TURNIN = "showTurnins" }
Q.KIND_ART = { OBJ = "Quests_PinObjective", GIVER = "Quests_PinGiver", TURNIN = "Quests_PinTurnin" }

function Q:AddNode(key, node)
    if not key or not node or not node.x or not node.y then return nil end
    node.key = key
    node.type = node.type or "OBJ"
    node.title = node.title or key
    node.zone = node.zone or self:Zone()
    local list = self.nodes[key]
    if not list then
        list = {}
        self.nodes[key] = list
    end
    table.insert(list, node)
    self.nodesDirty = true
    return node
end

function Q:DeleteNode(key, ntype, source)
    if key == nil then
        -- every quest's nodes of this source
        for k in pairs(self.nodes) do self:DeleteNode(k, ntype, source) end
        return
    end
    local list = self.nodes[key]
    if not list then return end
    for i = table.getn(list), 1, -1 do
        local n = list[i]
        if (not ntype or n.type == ntype) and (not source or n.source == source) then table.remove(list, i) end
    end
    if not list[1] then self.nodes[key] = nil end
    self.nodesDirty = true
end

function Q:GetNodes(key) return self.nodes[key] or {} end

function Q:ZoneNodes(zone)
    zone = zone or self:Zone()
    local out = {}
    for _, list in pairs(self.nodes) do
        for _, n in ipairs(list) do
            if n.zone == zone then table.insert(out, n) end
        end
    end
    return out
end

function Q:CountZonePins()
    local n = 0
    for _, node in ipairs(self:ZoneNodes()) do
        if node.source ~= "learned" then n = n + 1 end
    end
    return n
end

-- The node of a quest the player most likely wants next: the turn-in when complete, else the
-- nearest objective. Only nodes on the current zone map count.
function Q:BestNode(key)
    local q = self.byKey[key] or self:FindQuest(key)
    local zone = self:Zone()
    local px, py = self:PlayerPos()
    local best, bestD
    local want = (q and q.complete) and "TURNIN" or "OBJ"
    for pass = 1, 2 do
        for _, n in ipairs(self:GetNodes(key)) do
            -- a turn-in shown only once the quest is done is no target before that
            local usable = not (n.onlyComplete and not (q and q.complete))
            if n.zone == zone and usable and (pass == 2 or n.type == want) then
                local d = self:Yards(px, py, n.x, n.y, zone)
                if not bestD or d < bestD then best, bestD = n, d end
            end
        end
        if best then return best, bestD end
    end
end

-- -- Learned spots become objective nodes ------------------------------------------------------

function Q:SyncLearned()
    self:DeleteNode(nil, nil, "learned")
    local db = self:DB()
    for title, spots in pairs(db.learned) do
        local q = self:FindQuest(title)
        if q and not q.complete then
            for _, s in ipairs(spots) do
                self:AddNode(q.key, { type = "OBJ", title = title, zone = s.zone, x = s.x, y = s.y,
                    source = "learned", label = "Where you made progress" })
            end
        end
    end
end

Q:Listen("QuestsChanged", function() Q:SyncLearned() end)
Q:Listen("LearnedSpot", function() Q:SyncLearned() end)

-- -- CP: quest pins from the realm ----------------------------------------------------------------

function Q:HandlePins(body)
    local pins = {}
    self:DeleteNode(nil, nil, "CP")
    local zone = self:Zone()
    local recs, n = W.Split(body or "", ";")
    for i = 1, n do
        local f = W.Split(recs[i], ",")
        local x, y = tonumber(f[2]), tonumber(f[3])
        if x and y then
            local kindField = W.Split(string.upper(f[4] or "OBJ"), ":")
            local kind = kindField[1]
            if not self.KIND_COLOR[kind] then kind = "OBJ" end
            local title = f[5]
            if title then
                -- a title may itself contain commas
                for j = 6, table.getn(f) do title = title .. "," .. f[j] end
                if title == "" then title = nil end
            end
            local p = { id = f[1], x = x, y = y, kind = kind, title = title, targets = {} }
            for j = 2, table.getn(kindField) do
                local t, num = string.sub(kindField[j], 1, 1), tonumber(string.sub(kindField[j], 2))
                if num then
                    table.insert(p.targets, { kind = string.lower(t), id = num })
                    if t == "I" and title then self.itemIds[num] = title end
                end
            end
            table.insert(pins, p)
            local key = title or ("Quest #" .. tostring(f[1]))
            local q = title and self:FindQuest(title)
            self:AddNode(q and q.key or key, { type = kind, title = (q and q.title) or title or key, zone = zone, x = x, y = y,
                source = "CP", questId = f[1] })
        end
    end
    self.pins = pins
    self:LayoutPins()
end

W:RegisterModule("CP", function(body) Q:HandlePins(body) end)

-- -- QZ: quests to pick up nearby -------------------------------------------------------------------

function Q:HandleNearby(body)
    local recs, n = W.Split(body or "", ";")
    local zone = self.ZONE_IDS[tonumber(recs[1] or "")] or self:Zone()
    self:DeleteNode(nil, nil, "QZ")
    local list = {}
    for i = 2, n do
        local f = W.Split(recs[i], ",")
        local x, y = tonumber(f[2]), tonumber(f[3])
        if x and y and f[7] then
            local title = f[7]
            for j = 8, table.getn(f) do title = title .. "," .. f[j] end
            local e = { id = tonumber(f[1]), x = x, y = y, level = tonumber(f[4]) or 0, minLevel = tonumber(f[5]) or 0,
                giver = (f[6] ~= "" and f[6]) or nil, title = title, zone = zone }
            table.insert(list, e)
            if not self:FindQuest(title) then
                self:AddNode(title, { type = "GIVER", title = title, zone = zone, x = x, y = y, source = "QZ", label = e.giver })
            end
        end
    end
    self.nearby = list
    self.nearbyZone = zone
    self:LayoutPins()
    self:Fire("NearbyChanged")
end

W:RegisterModule("QZ", function(body) Q.realmPlus = true; Q:HandleNearby(body) end)

-- -- QM: quest facts (chains, xp, turn-in NPC) --------------------------------------------------

function Q:HandleMeta(body)
    local recs, n = W.Split(body or "", ";")
    for i = 1, n do
        local f = W.Split(recs[i], ",")
        if f[9] then
            local title = f[9]
            for j = 10, table.getn(f) do title = title .. "," .. f[j] end
            local m = { id = tonumber(f[1]), chainPos = tonumber(f[2]), chainLen = tonumber(f[3]), xp = tonumber(f[4]) }
            local tx, ty = tonumber(f[5]), tonumber(f[6])
            if (f[8] and f[8] ~= "") or tx then
                m.turnIn = { npc = (f[8] ~= "" and f[8]) or nil, x = tx, y = ty,
                    zone = self.ZONE_IDS[tonumber(f[7] or "")] or nil }
            end
            self.meta[title] = m
            local q = self:FindQuest(title)
            if q and m.turnIn and m.turnIn.x and m.turnIn.zone then
                self:DeleteNode(q.key, "TURNIN", "QM")
                self:AddNode(q.key, { type = "TURNIN", title = title, zone = m.turnIn.zone, x = m.turnIn.x,
                    y = m.turnIn.y, source = "QM", label = m.turnIn.npc, onlyComplete = true })
            end
        end
    end
    self:Fire("MetaChanged")
end

W:RegisterModule("QM", function(body) Q.realmPlus = true; Q:HandleMeta(body) end)

W:RegisterModule("QU", function(body)
    local f = W.Split(body or "", ",")
    if f[1] == "ok" then
        Q:Print("Restored: " .. (f[2] or "your quest") .. ".")
        Q:RequestScan()
    else
        Q:Print("The realm could not restore that quest" .. ((f[2] and f[2] ~= "") and (": " .. f[2]) or "") .. ".")
    end
end)

-- Ask the realm about this zone (only once it has greeted us; see W:SendCommand).
function Q:AskRealm(what)
    if not W.connected then return end
    if what == nil or what == "zone" then
        W:SendCommand("np")
        W:SendCommand("qz")
    end
    if what == nil or what == "meta" then W:SendCommand("qm") end
end

Q:On("ZONE_CHANGED_NEW_AREA", function()
    Q.pins = {}
    Q.nearby = {}
    Q:DeleteNode(nil, nil, "CP")
    Q:DeleteNode(nil, nil, "QZ")
    if SetMapToCurrentZone and not (WorldMapFrame and WorldMapFrame:IsVisible()) then SetMapToCurrentZone() end
    Q:AskRealm("zone")
    Q:LayoutPins()
    Q:Fire("NearbyChanged")
end)
Q:On("PLAYER_ENTERING_WORLD", function() Q:AskRealm() end)
Q:Listen("QuestAdded", function() if not Q.metaAsked then Q.metaAsked = true; Q:After(1, function() Q.metaAsked = nil; Q:AskRealm("meta") end) end end)

-- -- Pins on the minimap and the ring ---------------------------------------------------------------

Q.pinPool = {}

local function pinTip(self, tip)
    local n = self.node
    if not n then return end
    tip:SetText(n.title or "Quest", 1, 0.82, 0)
    local c = Q.KIND_COLOR[n.type] or Q.KIND_COLOR.OBJ
    tip:AddLine(Q.KIND_LABEL[n.type] or n.type, c[1], c[2], c[3])
    if n.label then tip:AddLine(n.label, 0.85, 0.85, 0.85) end
    local q = Q:FindQuest(n.title)
    if q then
        for _, o in ipairs(q.objectives) do
            if o.need > 1 or o.have > 0 then
                tip:AddLine("  " .. o.name .. ": " .. o.have .. "/" .. o.need, o.done and 0.5 or 1, 1, o.done and 0.5 or 1)
            else
                tip:AddLine("  " .. o.name, 1, 1, 1)
            end
        end
    end
    if self.yards then tip:AddLine(Q:YardText(self.yards) .. " away", 0.7, 0.7, 0.7) end
    tip:AddLine("Click to point the arrow here.", 0.5, 0.5, 0.5)
end

local function newPin(i)
    local pin = Q:NewMarker("Compass_Pin" .. i, 11)
    pin.dot = pin.tex
    pin.OnTip = pinTip
    pin.OnClickMarker = function(self) if self.node then Q:SetWaypoint(self.node) end end
    return pin
end

local function paint(pin, node, where)
    local c = Q.KIND_COLOR[node.type] or Q.KIND_COLOR.OBJ
    local pinned = (Q.pinnedKey and node.key == Q.pinnedKey)
    if where == "map" and W:Art(pin.tex, Q.KIND_ART[node.type] or "Quests_PinObjective", nil) then
        pin:SetWidth(16)
        pin:SetHeight(16)
        pin.tex:SetVertexColor(1, 1, 1)
    else
        local s = pinned and 15 or 11
        pin:SetWidth(s)
        pin:SetHeight(s)
        if not W:Art(pin.tex, "PinDot", { 1, 1, 1, 1 }) then
            pin:SetWidth(s - 3)
            pin:SetHeight(s - 3)
        end
        pin.tex:SetVertexColor(c[1], c[2], c[3])
    end
    pin:SetAlpha(node.source == "learned" and 0.75 or 1)
    pin:SetFrameLevel(Q.ring:GetFrameLevel() + (pinned and 3 or 2))
end

-- Show this zone's nodes: each on the minimap when in view, else the nearest one per quest and
-- kind on the ring (learned spots stay off the ring unless the quest is pinned).
function Q:LayoutPins()
    local used = 0
    if self:Active() then
        local zone = self:Zone()
        local px, py = self:PlayerPos()
        local nodes = self:ZoneNodes(zone)
        local ringBest = {}
        for _, n in ipairs(nodes) do
            local q = self:FindQuest(n.title)
            local show = self:Get(self.KIND_SETTING[n.type] or "showObjectives")
            if n.onlyComplete and not (q and q.complete) then show = false end
            if n.type == "OBJ" and q and q.complete then show = false end
            if show then
                n.dist = self:Yards(px, py, n.x, n.y, zone)
                local k = n.key .. "|" .. n.type
                if n.source ~= "learned" or n.key == self.pinnedKey then
                    if not ringBest[k] or n.dist < ringBest[k].dist then ringBest[k] = n end
                end
                n.show = true
            else
                n.show = false
            end
        end
        if px ~= 0 or py ~= 0 then
            for _, n in ipairs(nodes) do
                if n.show then
                    local pin = self.pinPool[used + 1] or newPin(used + 1)
                    self.pinPool[used + 1] = pin
                    pin.node = n
                    local k = n.key .. "|" .. n.type
                    local where = self:PlaceMarker(pin, n.x, n.y, ringBest[k] == n, zone)
                    if where then
                        used = used + 1
                        paint(pin, n, where)
                    end
                end
            end
        end
    end
    for i = used + 1, table.getn(self.pinPool) do
        self.pinPool[i]:Hide()
        self.pinPool[i].node = nil
    end
    self.nodesDirty = false
end

Q:Every(0.2, function() Q:LayoutPins() end)
Q:Listen("QuestsChanged", function() Q:LayoutPins() end)
Q:Listen("TrackingChanged", function() Q:LayoutPins() end)
Q:OnRefresh(function() Q:LayoutPins() end)
