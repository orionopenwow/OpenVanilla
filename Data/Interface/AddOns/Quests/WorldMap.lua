--[[
    WorldMap.lua  -  Quests: quest pins on the world map.

    An overlay on the world map's detail frame draws every node of the zone the map shows, in
    the same colours as the minimap (gold objective, green giver, red turn-in). Hover a pin for
    the quest and its progress; click it to point the arrow there. "Show on map" in the quest
    log opens the map on the player's zone and highlights that quest's pins.
    Ctrl-click anywhere on a zone map to point the arrow at that spot.
]]--

local W = WenillaCore
local Q = Compass

local host = WorldMapButton or WorldMapDetailFrame or WorldMapFrame
local overlay = CreateFrame("Frame", "Compass_MapOverlay", host)
overlay:SetAllPoints(host)
if host and host.GetFrameLevel then overlay:SetFrameLevel((host:GetFrameLevel() or 1) + 3) end
Q.mapOverlay = overlay
Q.mapPool = {}

-- The name of the zone the world map shows ("" for a continent or the whole world).
function Q:MapZoneName()
    if not (GetCurrentMapContinent and GetCurrentMapZone and GetMapZones) then return self:Zone() end
    local c, z = GetCurrentMapContinent(), GetCurrentMapZone()
    if not c or c <= 0 or not z or z <= 0 then return "" end
    local zones = { GetMapZones(c) }
    return zones[z] or ""
end

local function newMapPin(i)
    local p = CreateFrame("Button", "Compass_MapPin" .. i, overlay)
    p:SetWidth(18)
    p:SetHeight(18)
    p.tex = p:CreateTexture(nil, "OVERLAY")
    p.tex:SetAllPoints(p)
    p:SetScript("OnEnter", function()
        local n = this.node
        if not n then return end
        local tip = GameTooltip
        tip:SetOwner(this, "ANCHOR_RIGHT")
        tip:SetText(n.title or "Quest", 1, 0.82, 0)
        local c = Q.KIND_COLOR[n.type] or Q.KIND_COLOR.OBJ
        tip:AddLine(Q.KIND_LABEL[n.type] or n.type, c[1], c[2], c[3])
        if n.label then tip:AddLine(n.label, 0.85, 0.85, 0.85) end
        local q = Q:FindQuest(n.title)
        if q then
            for _, o in ipairs(q.objectives) do
                tip:AddLine("  " .. o.name .. ((o.need > 1 or o.have > 0) and (": " .. o.have .. "/" .. o.need) or ""), 1, 1, 1)
            end
        end
        tip:AddLine("Click to point the arrow here.", 0.5, 0.5, 0.5)
        tip:Show()
    end)
    p:SetScript("OnLeave", function() GameTooltip:Hide() end)
    p:SetScript("OnClick", function() if this.node then Q:SetWaypoint(this.node) end end)
    return p
end

function Q:DrawWorldMap()
    local used = 0
    if self:Active() and self:Get("worldMapPins") and WorldMapFrame and WorldMapFrame:IsVisible() then
        local zone = self:MapZoneName()
        local w, h = overlay:GetWidth() or 0, overlay:GetHeight() or 0
        if w <= 0 and host then w, h = host:GetWidth() or 0, host:GetHeight() or 0 end
        for _, n in ipairs(self:ZoneNodes(zone)) do
            local q = self:FindQuest(n.title)
            local show = self:Get(self.KIND_SETTING[n.type] or "showObjectives")
            if n.onlyComplete and not (q and q.complete) then show = false end
            if n.type == "OBJ" and q and q.complete then show = false end
            if show then
                used = used + 1
                local p = self.mapPool[used] or newMapPin(used)
                self.mapPool[used] = p
                p.node = n
                if not W:Art(p.tex, self.KIND_ART[n.type] or "Quests_PinObjective", nil) then
                    local c = self.KIND_COLOR[n.type] or self.KIND_COLOR.OBJ
                    p.tex:SetTexture(c[1], c[2], c[3], 1)
                    p:SetWidth(8)
                    p:SetHeight(8)
                end
                local focus = self.mapFocus
                local dim = focus and n.key ~= focus
                p:SetAlpha(dim and 0.35 or ((n.source == "learned") and 0.75 or 1))
                local big = focus and n.key == focus
                if p:GetWidth() > 8 then
                    p:SetWidth(big and 24 or 18)
                    p:SetHeight(big and 24 or 18)
                end
                p:ClearAllPoints()
                -- the pin's tip (bottom centre of the art) sits on the spot
                p:SetPoint("BOTTOM", overlay, "TOPLEFT", n.x * w, -n.y * h)
                p:Show()
            end
        end
    end
    for i = used + 1, table.getn(self.mapPool) do
        self.mapPool[i]:Hide()
        self.mapPool[i].node = nil
    end
    self.mapPinsShown = used
end

-- Open the map on the player's zone with this quest's pins highlighted.
function Q:ShowOnMap(key)
    self.mapFocus = key
    if WorldMapFrame and not WorldMapFrame:IsVisible() then
        if ShowUIPanel then ShowUIPanel(WorldMapFrame) else WorldMapFrame:Show() end
    end
    if SetMapToCurrentZone then SetMapToCurrentZone() end
    self:DrawWorldMap()
    local n = 0
    for _, node in ipairs(self:GetNodes(key)) do if node.zone == self:Zone() then n = n + 1 end end
    return n
end

Q:On("WORLD_MAP_UPDATE", function() Q:DrawWorldMap() end)
Q:Listen("QuestsChanged", function() Q:DrawWorldMap() end)
Q:OnRefresh(function() Q:DrawWorldMap() end)

if WorldMapFrame then
    local origShow = WorldMapFrame:GetScript("OnShow")
    WorldMapFrame:SetScript("OnShow", function()
        if origShow then origShow() end
        Q:DrawWorldMap()
    end)
    local origHide = WorldMapFrame:GetScript("OnHide")
    WorldMapFrame:SetScript("OnHide", function()
        if origHide then origHide() end
        Q.mapFocus = nil
    end)
end

-- -- Ctrl-click: a waypoint where you click --------------------------------------------------------

-- The cursor as a spot on the map the world map shows (0-1 each way), or nil when outside it.
function Q:MapCursor()
    local b = WorldMapButton
    if not (b and GetCursorPosition) then return nil end
    local cx, cy = GetCursorPosition()
    local sc = b:GetEffectiveScale() or 1
    local w, h = b:GetWidth() or 0, b:GetHeight() or 0
    if w <= 0 or h <= 0 then return nil end
    local x = (cx / sc - (b:GetLeft() or 0)) / w
    local y = ((b:GetTop() or 0) - cy / sc) / h
    if x < 0 or x > 1 or y < 0 or y > 1 then return nil end
    return x, y
end

if WorldMapButton and WorldMapButton.GetScript then
    local stock = WorldMapButton:GetScript("OnClick")
    WorldMapButton:SetScript("OnClick", function()
        if arg1 == "LeftButton" and IsControlKeyDown and IsControlKeyDown() and Q:Active() then
            local zone = Q:MapZoneName()
            local x, y = Q:MapCursor()
            if zone ~= "" and x then
                Q:SetWaypoint({ x = x, y = y, zone = zone,
                    title = string.format("Waypoint %.1f, %.1f", x * 100, y * 100) })
                return
            end
            Q:Print("Open a zone map (not a continent) to set a waypoint.")
            return
        end
        if stock then stock() end
    end)
end
