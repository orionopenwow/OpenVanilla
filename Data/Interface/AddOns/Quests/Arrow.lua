--[[
    Arrow.lua  -  Quests: the waypoint arrow.

    A gold arrow (drag to move, right-click for options) that turns to point at, in order:
      1. your corpse while you are dead or a ghost (GetCorpseMapPosition), with the yards left;
      2. a spot you clicked (a quest pin, a service icon, a nearby quest);
      3. the quest you pinned in the tracker (its turn-in once complete, else its nearest objective);
      4. otherwise the nearest objective or turn-in of your tracked quests (can be turned off).
    The 1.12 client has no facing API: the arrow reads the minimap's player-arrow model (the
    ninth model child of Minimap, as Questie does), and otherwise the direction you last moved in.
    Next to the yards: the time to arrive at your current speed. A chime when you get there.
    Set a spot with /way x y [name] or Ctrl-click on the world map; /way clear drops it.
]]--

local W = WenillaCore
local UI = W.UI
local Q = Compass

local floor = math.floor
local atan2 = math.atan2 or math.atan
local PI = math.pi

local arrow = CreateFrame("Button", "Compass_Arrow", UIParent)
arrow:SetWidth(56)
arrow:SetHeight(56)
arrow.defaultPoint = { "TOP", UIParent, "TOP", 0, -110 }
arrow:SetPoint("TOP", UIParent, "TOP", 0, -110)
arrow:SetFrameStrata("MEDIUM")
arrow:SetMovable(true)
arrow:EnableMouse(true)
arrow:RegisterForDrag("LeftButton")
arrow:RegisterForClicks("LeftButtonUp", "RightButtonUp")
arrow:SetScript("OnDragStart", function() this:StartMoving() end)
arrow:SetScript("OnDragStop", function()
    this:StopMovingOrSizing()
    W:SavePosition(this)
end)
arrow:Hide()
Q.arrow = arrow

local head = arrow:CreateTexture("Compass_ArrowTexture", "ARTWORK")
head:SetAllPoints(arrow)
arrow.head = head
arrow.hasArt = W:Art(head, "Quests_Arrow", "Interface\\Minimap\\MinimapArrow")

local title = UI.Label(arrow, 11, { 1, 1, 1 }, "OUTLINE")
title:SetPoint("TOP", arrow, "BOTTOM", 0, -2)
title:SetJustifyH("CENTER")
title:SetWidth(220)
arrow.title = title
local dist = UI.Label(arrow, 12, UI.ACCENT, "OUTLINE")
dist:SetPoint("TOP", title, "BOTTOM", 0, -2)
dist:SetJustifyH("CENTER")
dist:SetWidth(160)
arrow.dist = dist

-- Rotate the arrow texture clockwise by a radians (the art points up).
local function rotate(a)
    local c, s = math.cos(a), math.sin(a)
    local function at(x, y) return 0.5 + x * c + y * s, 0.5 - x * s + y * c end
    local ulx, uly = at(-0.5, -0.5)
    local llx, lly = at(-0.5, 0.5)
    local urx, ury = at(0.5, -0.5)
    local lrx, lry = at(0.5, 0.5)
    head:SetTexCoord(ulx, uly, llx, lly, urx, ury, lrx, lry)
end

-- -- Facing ------------------------------------------------------------------------------------

local model, modelLook = nil, 0
local heading                       -- radians clockwise from north, from movement
local lastX, lastY

-- The player's own minimap arrow: the client builds nine models on the minimap before anything
-- else, eight "Rotating-MinimapArrow" (party and POI arrows, which never turn with you) and,
-- ninth, "MinimapArrow", which the client turns to your facing every frame. Questie and pfQuest
-- read ({Minimap:GetChildren()})[9]. Matching on "minimaparrow" alone picked the first rotating
-- arrow, which always faces north: the arrow then pointed as if you always faced north.
local function isPlayerArrow(k)
    if not (k and k.GetObjectType and k:GetObjectType() == "Model" and k.GetFacing) then return false end
    local m = k.GetModel and k:GetModel()
    if type(m) ~= "string" then return nil end          -- unknown path: only trusted as the 9th child
    m = string.lower(m)
    return string.find(m, "minimaparrow", 1, true) ~= nil and string.find(m, "rotating", 1, true) == nil
end

local function findModel()
    if model then return model end
    if GetTime() < modelLook then return nil end
    modelLook = GetTime() + 5
    if not (Minimap and Minimap.GetChildren) then return nil end
    local kids = { Minimap:GetChildren() }
    if kids[9] and isPlayerArrow(kids[9]) ~= false then
        model = kids[9]
        return model
    end
    for _, k in ipairs(kids) do
        if not (k.GetName and k:GetName()) and isPlayerArrow(k) then
            model = k
            return k
        end
    end
end
Q.FindFacingModel = function() model = nil; modelLook = 0; return findModel() end

-- Heading in radians clockwise from north, or nil when unknown.
function Q:Heading()
    if GetPlayerFacing then                 -- later clients, or a client that adds it
        local f = GetPlayerFacing()
        if f then return -f end             -- facing turns counter-clockwise from north
    end
    local m = findModel()
    if m and m.GetFacing then
        local f = m:GetFacing()
        if f then return -f end         -- facing turns counter-clockwise from north
    end
    return heading
end

-- Walking speed in yards a second, smoothed, for the time-to-arrive; 0 when standing still.
local speed, spX, spY, spT = 0, nil, nil, nil
local function trackSpeed(x, y)
    local now = GetTime()
    if not spT then spX, spY, spT = x, y, now; return end
    local dt = now - spT
    if dt < 0.5 then return end
    local d = Q:Yards(spX, spY, x, y)
    local v = d / dt
    if v > 60 then v = speed end                         -- a teleport or a zone change, not walking
    speed = speed * 0.5 + v * 0.5
    if speed < 0.3 then speed = 0 end
    spX, spY, spT = x, y, now
end
function Q:Speed() return speed end

-- "25 s", "1 min 40 s", "12 min"; nil when you are not moving.
function Q:EtaText(yards)
    if not yards or speed < 1 then return nil end
    local s = floor(yards / speed + 0.5)
    if s < 60 then return s .. " s" end
    local m = floor(s / 60)
    if m >= 10 then return m .. " min" end
    local r = s - m * 60
    return m .. " min" .. (r > 0 and (" " .. r .. " s") or "")
end

local function trackMovement()
    local x, y = Q:PlayerPos()
    if x == 0 and y == 0 then return end
    trackSpeed(x, y)
    if lastX then
        local d, dx, dy = Q:Yards(lastX, lastY, x, y)
        if d > 0.7 then
            heading = atan2(dx, -dy)
            lastX, lastY = x, y
        end
    else
        lastX, lastY = x, y
    end
end

-- -- Targets -------------------------------------------------------------------------------------

-- A spot to point at: { x, y, zone, title, kind = "NPC" | "OBJ" | "TURNIN" | "GIVER" | "SPOT", label }
function Q:SetWaypoint(t)
    if not t then return self:ClearWaypoint() end
    self.waypoint = { x = t.x, y = t.y, zone = t.zone or self:Zone(), title = t.title or "Waypoint",
        kind = t.kind or t.type or "SPOT", label = t.label }
    self.arrived = nil
    if self.waypoint.zone ~= self:Zone() then
        self:Print("Waypoint set in " .. self.waypoint.zone .. ". The arrow points there once you are in "
            .. self.waypoint.zone .. ".")
    end
    self:UpdateArrow()
end

function Q:ClearWaypoint()
    self.waypoint = nil
    self.arrived = nil
    self:UpdateArrow()
end

function Q:PinQuest(key)
    if self.pinnedKey == key then
        self.pinnedKey = nil
    else
        self.pinnedKey = key
        self.waypoint = nil
        if not self:BestNode(key) then
            self:Print("No location known for \"" .. key .. "\" yet. It is pinned and the arrow will point there once a spot is known.")
        end
    end
    self:Fire("TrackingChanged", key)
    self:UpdateArrow()
end

function Q:CurrentTarget()
    if UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") then
        -- dead and not yet released: you are lying on your corpse, nothing to point at; after
        -- releasing, only the corpse (when that option is on), never a quest
        if UnitIsGhost and not UnitIsGhost("player") then return nil end
        if not self:Get("corpseArrow") then return nil end
        local x, y = 0, 0
        if GetCorpseMapPosition then x, y = GetCorpseMapPosition() end
        return { corpse = true, x = x or 0, y = y or 0, zone = self:Zone(), title = "Your corpse", kind = "CORPSE" }
    end
    if not self:Get("showArrow") then return nil end
    local zone = self:Zone()
    if self.waypoint and self.waypoint.zone == zone then return self.waypoint end
    if self.pinnedKey then
        local n = self:BestNode(self.pinnedKey)
        if n then return { x = n.x, y = n.y, zone = n.zone, title = n.title, kind = n.type, label = n.label } end
    end
    if self:Get("arrowAuto") then
        local px, py = self:PlayerPos()
        local best, bestD
        for _, q in ipairs(self:TrackedQuests()) do
            local n, d = self:BestNode(q.key)
            if n and (not bestD or d < bestD) then best, bestD = n, d end
        end
        if best then return { x = best.x, y = best.y, zone = best.zone, title = best.title, kind = best.type, label = best.label } end
    end
end

-- -- Drawing -------------------------------------------------------------------------------------
-- Q:UpdateArrow (5 times a second, and at once when the target changes) picks the target, sets
-- the name, the yards and the colour, and says whether the arrow should show. The arrow's own
-- OnUpdate turns it every frame: the shown angle eases toward the wanted one the short way
-- round, at the same speed whatever the frame rate, and the arrow fades in and out.

local TURN_RATE = 9         -- per second: about 60 per cent of a turn is made in 0.1 s
local FADE_RATE = 8

local function wrap(a)
    while a > PI do a = a - 2 * PI end
    while a < -PI do a = a + 2 * PI end
    return a
end

-- The angle to turn the arrow to (radians clockwise from straight ahead), or nil.
local function targetAngle(t)
    local px, py = Q:PlayerPos()
    if px == 0 and py == 0 then return nil end
    local _, dx, dy = Q:Yards(px, py, t.x, t.y, t.zone)
    if dx == 0 and dy == 0 then return nil end
    return wrap(atan2(dx, -dy) - (Q:Heading() or 0))      -- bearing is clockwise from north
end

-- One frame of easing: from the shown angle `cur` toward `want` over dt seconds.
function Q.EaseAngle(cur, want, dt)
    if not cur then return want end
    local d = wrap(want - cur)
    if math.abs(d) < 0.002 then return want end
    return wrap(cur + d * (1 - math.exp(-dt * TURN_RATE)))
end

function Q:UpdateArrow()
    trackMovement()                     -- keeps the heading current while the arrow is hidden too
    local t = self:Active() and self:CurrentTarget() or nil
    local px, py = self:PlayerPos()
    -- no coordinates here (an instance, a taxi to nowhere): nothing sensible to point at
    if t and px == 0 and py == 0 then t = nil end
    self.arrowTarget = t
    if not t then
        self.arrowYards = nil
        arrow.want = false
        return
    end
    if not arrow:IsShown() then
        -- appear already pointing the right way, then fade in
        arrow.disp = nil
        arrow.alpha = 0
        arrow:SetAlpha(0)
    end
    arrow.want = true
    arrow:SetScale(tonumber(self:Get("arrowScale")) or 1)
    arrow:Show()
    if t.corpse and t.x == 0 and t.y == 0 then
        head:Hide()
        title:SetText("Your corpse")
        dist:SetText("Not on this map")
        self.arrowYards = nil
        return
    end
    head:Show()
    local yards = self:Yards(px, py, t.x, t.y, t.zone)
    self.arrowYards = yards
    title:SetText(t.title .. ((t.label and t.kind ~= "CORPSE") and ("\n|cffb0b0b0" .. t.label .. "|r") or ""))
    if yards < 8 then
        dist:SetText(t.corpse and "You are at your corpse" or "You are here")
        if self.waypoint == t and not self.arrived then
            self.arrived = true
            if PlaySound and self:Get("arrowChime") then PlaySound("MapPing") end
            self:After(3, function() if Q.waypoint == t then Q:ClearWaypoint() end end)
        end
    else
        local eta = self:EtaText(yards)
        dist:SetText(self:YardText(yards) .. (eta and ("  |cffb0b0b0" .. eta .. "|r") or ""))
    end
    local rel = targetAngle(t) or 0
    self.arrowAngle = rel
    if not arrow.disp then
        arrow.disp = rel
        rotate(rel)
    end
    -- straight ahead turns green, behind you red, otherwise gold
    local ahead = math.abs(rel)
    if t.corpse then
        head:SetVertexColor(0.85, 0.9, 1)
    elseif ahead < 0.35 then
        head:SetVertexColor(0.55, 1, 0.45)
    elseif ahead > 2.6 then
        head:SetVertexColor(1, 0.45, 0.35)
    else
        head:SetVertexColor(1, 1, 1)
    end
end

arrow:SetScript("OnUpdate", function()
    local dt = arg1 or 0
    if dt > 0.5 then dt = 0.5 end
    trackMovement()
    local a = this.alpha or 1
    local wantA = this.want and 1 or 0
    a = a + (wantA - a) * (1 - math.exp(-dt * FADE_RATE))
    if not this.want and a < 0.03 then
        this.alpha = 0
        this:SetAlpha(0)
        this:Hide()
        return
    end
    if this.want and a > 0.99 then a = 1 end
    if a ~= this.alpha then
        this.alpha = a
        this:SetAlpha(a)
    end
    local t = Q.arrowTarget
    if not (this.want and t and head:IsShown()) then return end
    local want = targetAngle(t)
    if not want then return end
    local d = Q.EaseAngle(this.disp, want, dt)
    if d ~= this.disp then
        this.disp = d
        rotate(d)
    end
end)

arrow:SetScript("OnClick", function()
    if arg1 ~= "RightButton" then return end
    UI.Menu(this, {
        { text = "Arrow", title = true },
        { text = "Clear this target", disabled = not (Q.waypoint or Q.pinnedKey),
            func = function() Q.pinnedKey = nil; Q:ClearWaypoint(); Q:Fire("TrackingChanged") end },
        { text = "Point at nearest objective", checked = Q:Get("arrowAuto"), func = function() Q:Set("arrowAuto", not Q:Get("arrowAuto")) end },
        { text = "Point at my corpse", checked = Q:Get("corpseArrow"), func = function() Q:Set("corpseArrow", not Q:Get("corpseArrow")) end },
        { text = "Chime on arrival", checked = Q:Get("arrowChime"), func = function() Q:Set("arrowChime", not Q:Get("arrowChime")) end },
        { text = "Hide the arrow", func = function() Q:Set("showArrow", false); Q:Print("Arrow hidden. /quests arrow brings it back.") end },
    })
end)
arrow:SetScript("OnEnter", function()
    local t = Q.arrowTarget
    if not t then return end
    GameTooltip:SetOwner(this, "ANCHOR_BOTTOM")
    GameTooltip:SetText(t.title, 1, 0.82, 0)
    if Q.arrowYards then GameTooltip:AddLine(Q:YardText(Q.arrowYards) .. " away", 1, 1, 1) end
    if not Q:Heading() then GameTooltip:AddLine("Walk a few steps so the arrow knows which way you face.", 0.6, 0.6, 0.6, 1) end
    GameTooltip:AddLine("Drag to move. Right-click for options. /way x y sets a spot; Ctrl-click the world map too.", 0.6, 0.6, 0.6, 1)
    GameTooltip:Show()
end)
arrow:SetScript("OnLeave", function() GameTooltip:Hide() end)
W:TrackPosition(arrow)

-- The corpse on the ring / minimap too.
local corpsePin = Q:NewMarker("Compass_CorpsePin", 16)
W:Art(corpsePin.tex, "Quests_Corpse", { 0.8, 0.85, 1, 1 })
corpsePin.OnTip = function(self, tip)
    tip:SetText("Your corpse", 1, 1, 1)
    if self.yards then tip:AddLine(Q:YardText(self.yards) .. " away", 0.7, 0.7, 0.7) end
end

local function layoutCorpse()
    local t = Q.arrowTarget
    if t and t.corpse and (t.x ~= 0 or t.y ~= 0) then
        Q:PlaceMarker(corpsePin, t.x, t.y, true)
    else
        corpsePin:Hide()
    end
end

Q:Every(0.2, function() Q:UpdateArrow() end)
Q:Every(0.2, layoutCorpse)
Q:On("PLAYER_DEAD", function() Q:UpdateArrow(); layoutCorpse() end)
Q:On("PLAYER_ALIVE", function() Q:UpdateArrow(); layoutCorpse() end)
Q:On("PLAYER_UNGHOST", function() Q:UpdateArrow(); layoutCorpse() end)
Q:On("ZONE_CHANGED_NEW_AREA", function() lastX, lastY = nil, nil end)
Q:OnRefresh(function(active)
    if not active then arrow:Hide(); corpsePin:Hide() else Q:UpdateArrow() end
end)
