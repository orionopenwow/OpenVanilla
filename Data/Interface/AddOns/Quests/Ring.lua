--[[
    Ring.lua  -  Quests: the minimap frame.

    A carved ring (Wildwood by default, four more themes) replaces the stock gold minimap border:
    MinimapBorder and MinimapBorderTop are hidden while the ring art is showing, and the zoom
    buttons, the zone name, the tracking, mail and day/night buttons are set around the ring.
    Everything goes back to the stock layout when the ring is switched off, the addon is
    disabled or Pure Vanilla is on.

    Why the ring once did not show: the art resolver (W:Art) remembered the first art folder
    that loaded and never tried the other one, so a texture missing from that folder (an older
    patch with only some ring themes) failed silently, and the stock border was never hidden,
    so the minimap kept its plain gold frame. W:Art now falls back per texture, and this file
    hides the stock border and puts the ring above it.

    Markers: Q:NewMarker / Q:PlaceMarker put any icon at a zone map position, on the minimap
    while it is in view, otherwise on the ring at its bearing (quest pins, service NPCs, corpse).
]]--

local W = WenillaCore
local UI = W.UI
local Q = Compass

local floor = math.floor
local atan2 = math.atan2 or math.atan

-- Ring art geometry (tools/gen_compass_ring.py, 128 = the texture's half width): the minimap's
-- edge sits at radius 104, the carved band covers 101..128, so its middle line is 114.5.
local RING_SCALE = 128 / 104        -- ring size / minimap size
local PIN_FRAC = 114.5 / 128        -- pins ride the middle of the band
local EDGE_FRAC = 0.99              -- buttons sit on the outer rim
local mm = Minimap or UIParent

local ring = CreateFrame("Frame", "Compass_RingFrame", mm)
ring:SetPoint("CENTER", mm, "CENTER", 0, 0)
Q.ring = ring

-- Size the ring from the minimap as it is now (a repack or a theme may resize the minimap
-- after this file loads) and work out the radii every marker uses. All radii are in the ring's
-- own units, measured from the ring's centre, which is the minimap's centre.
function Q:RingGeometry()
    local w = mm:GetWidth() or 0
    if w <= 0 then w = 140 end
    local s = w * RING_SCALE
    if s ~= self.RING_SIZE then
        self.RING_SIZE = s
        ring:SetWidth(s)
        ring:SetHeight(s)
    end
    self.MAP_R = w / 2                      -- the visible minimap circle
    self.RING_PIN_R = s / 2 * PIN_FRAC
    self.RING_EDGE_R = s / 2 * EDGE_FRAC
    return s
end
local size = Q:RingGeometry()

local ringTex = ring:CreateTexture("Compass_RingTexture", "ARTWORK")
ringTex:SetAllPoints(ring)
Q.ringTex = ringTex

-- Above the minimap and the stock backdrop (which holds MinimapBorder), so the ring is never
-- drawn underneath the stock frame.
function Q:RingLevel()
    local lvl = mm:GetFrameLevel() or 1
    if MinimapBackdrop and MinimapBackdrop.GetFrameLevel then
        lvl = math.max(lvl, MinimapBackdrop:GetFrameLevel() or 1)
    end
    return lvl + 2
end
ring:SetFrameLevel(Q:RingLevel())

-- -- Themes ----------------------------------------------------------------------------------

function Q:RingTheme()
    local want = self:Get("ringTheme")
    for i, t in ipairs(self.RING_THEMES) do
        if t.key == want then return t, i end
    end
    return self.RING_THEMES[1], 1
end

function Q:ApplyRingTheme()
    local t = self:RingTheme()
    self.hasRingArt = W:Art(ringTex, t.tex, nil) or W:Art(ringTex, "CompassRing", nil)
    return self.hasRingArt
end

function Q:SetRingTheme(key)
    local s = W:Settings(self.ID)
    s.ringTheme = key
    s.showRing = true
    W:Refresh(self.ID)
    self:Print("Minimap ring: " .. self:RingTheme().label .. ".")
end

function Q:NextRingTheme()
    local _, i = self:RingTheme()
    local n = table.getn(self.RING_THEMES)
    self:SetRingTheme(self.RING_THEMES[(i >= n) and 1 or (i + 1)].key)
end

function Q:ThemeMenu(anchor)
    local items = { { text = "Minimap ring", title = true } }
    local cur = self:RingTheme()
    for _, t in ipairs(self.RING_THEMES) do
        local key = t.key
        table.insert(items, { text = t.label, checked = (t.key == cur.key and self:Get("showRing")),
            func = function() Q:SetRingTheme(key) end })
    end
    table.insert(items, { text = "Plain minimap (no ring)", checked = not self:Get("showRing"),
        func = function() Q:Set("showRing", false); Q:Print("Minimap ring hidden. /compass theme brings it back.") end })
    UI.Menu(anchor, items)
end

Q:ApplyRingTheme()

-- -- The stock minimap frame -------------------------------------------------------------------
-- Buttons that sit around the ring: name, angle in degrees (0 = east, counter-clockwise).
Q.AROUND_RING = {
    { "MinimapZoomIn", -20 }, { "MinimapZoomOut", -44 },
    { "MiniMapTrackingFrame", 136 }, { "MiniMapMailFrame", 162 },
    { "MiniMapBattlefieldFrame", 218 }, { "GameTimeFrame", 18 },
}

local saved = {}

local function remember(f)
    if saved[f] then return end
    local pts = {}
    for i = 1, (f.GetNumPoints and f:GetNumPoints() or 0) do
        local a, rel, b, x, y = f:GetPoint(i)
        pts[i] = { a, rel, b, x, y }
    end
    saved[f] = { points = pts, level = f.GetFrameLevel and f:GetFrameLevel() }
end

local function restore(f)
    local s = saved[f]
    if not s then return end
    f:ClearAllPoints()
    for _, p in ipairs(s.points) do f:SetPoint(p[1], p[2] or UIParent, p[3], p[4], p[5]) end
    if s.level and f.SetFrameLevel then f:SetFrameLevel(s.level) end
    saved[f] = nil
end

local function onRing(f, deg, level)
    remember(f)
    local a = math.rad(deg)
    f:ClearAllPoints()
    f:SetPoint("CENTER", ring, "CENTER", math.cos(a) * Q.RING_EDGE_R, math.sin(a) * Q.RING_EDGE_R)
    if f.SetFrameLevel then f:SetFrameLevel(level) end
end

-- on: the ring replaces the stock frame. Returns whether the stock border is hidden.
function Q:ApplyMinimapFrame(on)
    local top = ring:GetFrameLevel() + 3
    -- a UI repack that took the ring off the minimap (Repack's square map) owns the frame now:
    -- leave its layout alone
    if ring:GetParent() ~= mm then
        self.stockHidden = false
        for f in pairs(saved) do saved[f] = nil end
        return false
    end
    -- give back only what this file took: never re-show a border someone else hid
    if not on and not self.stockHidden then return false end
    self.stockHidden = on and true or false
    if on then
        if MinimapBorder then MinimapBorder:Hide() end
        if MinimapBorderTop then MinimapBorderTop:Hide() end
        for _, e in ipairs(self.AROUND_RING) do
            local f = getglobal(e[1])
            if f and f.ClearAllPoints then onRing(f, e[2], top) end
        end
        local z = MinimapZoneTextButton
        if z then
            remember(z)
            z:ClearAllPoints()
            z:SetPoint("BOTTOM", ring, "TOP", 0, 3)   -- clear of the ring's rim and the close button
            if z.SetFrameLevel then z:SetFrameLevel(top) end
            -- the close X sits at the right end of the zone name, not on the ring (it covered the name)
            local x = MinimapToggleButton
            if x and x.ClearAllPoints then
                remember(x)
                x:ClearAllPoints()
                x:SetPoint("LEFT", z, "RIGHT", -2, 0)
                if x.SetFrameLevel then x:SetFrameLevel(top + 1) end
            end
            if z.SetBackdrop then
                z:SetBackdrop(UI.THIN)
                z:SetBackdropColor(0.05, 0.05, 0.06, 0.88)
                z:SetBackdropBorderColor(0.72, 0.58, 0.30, 1)
            end
        end
    else
        if MinimapBorder then MinimapBorder:Show() end
        if MinimapBorderTop then MinimapBorderTop:Show() end
        for _, e in ipairs(self.AROUND_RING) do
            local f = getglobal(e[1])
            if f then restore(f) end
        end
        local z = MinimapZoneTextButton
        if z then
            restore(z)
            if z.SetBackdrop then z:SetBackdrop(nil) end
            if MinimapToggleButton then restore(MinimapToggleButton) end
        end
    end
    return self.stockHidden
end

-- -- Keep the minimap on screen ------------------------------------------------------------------
-- The stock cluster hugs the top-right corner (the minimap's centre 87 left of and 92 below it),
-- which suits the stock border but cuts off the bigger ring and the buttons set around it. While
-- the ring shows, the cluster moves so the ring, its buttons and the zone name end MINIMAP_MARGIN
-- from the top and right edges of UIParent. The sums are in screen units (a frame's units times
-- its effective scale, which includes UIParent's), so the margin is the same at every UI scale.
-- A cluster placed by hand with /move (Themes) is left where the player put it.

Q.MINIMAP_MARGIN = 14
local clusterSaved

-- How far the ring and everything set around it reach right of and above the minimap's centre,
-- in screen units.
function Q:RingReach()
    local rs = ring:GetEffectiveScale() or 1
    local half = (self.RING_SIZE or 172) / 2
    local right, up = half * rs, half * rs
    if self.stockHidden then
        for _, e in ipairs(self.AROUND_RING) do
            local f = getglobal(e[1])
            if f and f.GetWidth then
                local fs = (f.GetEffectiveScale and f:GetEffectiveScale()) or rs
                local a = math.rad(e[2])
                right = math.max(right, math.cos(a) * self.RING_EDGE_R * rs + (f:GetWidth() or 0) * fs / 2)
                up = math.max(up, math.sin(a) * self.RING_EDGE_R * rs + (f:GetHeight() or 0) * fs / 2)
            end
        end
        local z = MinimapZoneTextButton
        if z and z.GetHeight then
            local zs = (z.GetEffectiveScale and z:GetEffectiveScale()) or rs
            up = math.max(up, (half + 3) * rs + (z:GetHeight() or 12) * zs)
        end
    end
    return right, up
end

-- The minimap's centre measured from the cluster's top-right corner, in screen units.
local function centreOffset(cl)
    local ms, cs = mm:GetEffectiveScale() or 1, cl:GetEffectiveScale() or 1
    local mx, my
    if mm.GetCenter then mx, my = mm:GetCenter() end
    local cr, ct = cl:GetRight(), cl:GetTop()
    if mx and my and cr and ct then return mx * ms - cr * cs, my * ms - ct * cs end
    -- before the first layout: Minimap.xml puts the centre 9 right of the top middle of the
    -- 192 wide cluster and 92 down
    return (9 - (cl:GetWidth() or 192) / 2) * ms, -92 * ms
end

local function userPlaced()
    local d = ClassicPlus_UI
    return type(d) == "table" and type(d.pos) == "table" and d.pos.MinimapCluster and true or false
end

-- on: the ring is showing, so keep it inside the screen; off: give the cluster its old spot.
-- Returns the TOPRIGHT offsets used, or nil.
function Q:PlaceMinimap(on)
    local cl = MinimapCluster
    if not cl or not Minimap or mm:GetParent() ~= cl or ring:GetParent() ~= mm then on = false end
    if cl and userPlaced() then
        clusterSaved = nil
        return nil
    end
    if not on then
        if cl and clusterSaved then
            cl:ClearAllPoints()
            for _, p in ipairs(clusterSaved) do cl:SetPoint(p[1], p[2] or UIParent, p[3], p[4], p[5]) end
        end
        clusterSaved = nil
        return nil
    end
    if not clusterSaved then
        clusterSaved = {}
        for i = 1, (cl.GetNumPoints and cl:GetNumPoints() or 0) do
            local a, rel, b, x, y = cl:GetPoint(i)
            clusterSaved[i] = { a, rel, b, x, y }
        end
    end
    local cs = cl:GetEffectiveScale() or 1
    if cs <= 0 then cs = 1 end
    local ox, oy = centreOffset(cl)
    local right, up = self:RingReach()
    local m = self.MINIMAP_MARGIN
    -- the centre must sit (margin + reach) in from the right and top edges
    local x = (-m - right - ox) / cs
    local y = (-m - up - oy) / cs
    -- never past the screen's own corner
    if x > 0 then x = 0 end
    if y > 0 then y = 0 end
    cl:ClearAllPoints()
    cl:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", x, y)
    return x, y
end

-- Size, buttons and place again (after a UI scale, screen size or minimap size change).
function Q:LayoutRing()
    self:RingGeometry()
    if self.stockHidden then self:ApplyMinimapFrame(true) end
    self:PlaceMinimap(self.ringShown)
end

local layoutSig
local function checkLayout()
    local ui = UIParent
    local sig = string.format("%.4f|%.1f|%.1f|%.1f|%.4f", ui:GetEffectiveScale() or 1, ui:GetWidth() or 0,
        ui:GetHeight() or 0, mm:GetWidth() or 0, (MinimapCluster and MinimapCluster:GetEffectiveScale()) or 1)
    if sig ~= layoutSig then
        layoutSig = sig
        Q:LayoutRing()
    end
end

-- -- Compass rose: left-click tracking, right-click ring themes, Shift-click world map ------------

local rose = CreateFrame("Button", "Compass_Rose", ring)
rose:SetWidth(30)
rose:SetHeight(30)
local d45 = size / 2 * 0.72
rose:SetPoint("CENTER", ring, "CENTER", d45, d45)
rose:SetFrameLevel(ring:GetFrameLevel() + 4)
local roseTex = rose:CreateTexture(nil, "ARTWORK")
roseTex:SetAllPoints(rose)
if not W:Art(roseTex, "CompassRose", "Interface\\Icons\\INV_Misc_Map_01") then
    roseTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
end
rose:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
rose:RegisterForClicks("LeftButtonUp", "RightButtonUp")
rose:SetScript("OnClick", function()
    if arg1 == "RightButton" then
        Q:ThemeMenu(this)
    elseif IsShiftKeyDown() then
        if ToggleWorldMap then ToggleWorldMap() end
    elseif Q.TrackingMenu then
        Q:TrackingMenu(this)
    end
end)
rose:SetScript("OnEnter", function()
    GameTooltip:SetOwner(this, "ANCHOR_LEFT")
    GameTooltip:SetText("Quests", 1, 0.82, 0)
    local n = Q.CountZonePins and Q:CountZonePins() or 0
    GameTooltip:AddLine(n > 0 and (n .. " quest pin" .. (n == 1 and "" or "s") .. " in this zone") or "No quest pins in this zone", 0.85, 0.85, 0.85)
    GameTooltip:AddLine("Click: what to show on the minimap.", 0.6, 0.6, 0.6)
    GameTooltip:AddLine("Right-click: the ring's look (" .. Q:RingTheme().label .. ").", 0.6, 0.6, 0.6)
    GameTooltip:AddLine("Shift-click: the world map.", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end)
rose:SetScript("OnLeave", function() GameTooltip:Hide() end)
Q.rose = rose

-- -- Coordinates pill ----------------------------------------------------------------------------

local coords = CreateFrame("Frame", "Compass_Coords", mm)
coords:SetWidth(78)
coords:SetHeight(18)
coords:SetPoint("TOP", ring, "BOTTOM", 0, 6)
coords:SetFrameLevel(ring:GetFrameLevel() + 3)
coords:SetBackdrop(UI.THIN)
coords:SetBackdropColor(0.05, 0.05, 0.06, 0.9)
coords:SetBackdropBorderColor(0.72, 0.58, 0.30, 1)
local coordText = coords:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
coordText:SetPoint("CENTER", coords, "CENTER", 0, 0)

function Q:UpdateCoords()
    local x, y = self:PlayerPos()
    if self:Active() and self:Get("showCoords") and (x ~= 0 or y ~= 0) then
        coordText:SetText(self:CoordText(x, y))
        coords:Show()
    else
        coords:Hide()
    end
end

-- -- Markers ---------------------------------------------------------------------------------------

function Q:MinimapRadius()
    local zoom = (Minimap and Minimap.GetZoom and Minimap:GetZoom()) or 0
    local inside = false
    if GetCVar then
        local iz, oz = tonumber(GetCVar("minimapInsideZoom")), tonumber(GetCVar("minimapZoom"))
        inside = (iz == zoom and oz ~= zoom)
    end
    local t = inside and self.MINIMAP_YARDS_INSIDE or self.MINIMAP_YARDS
    return (t[zoom + 1] or t[1]) / 2
end

-- A small icon button on the ring layer; m.OnTip(m, tooltip) fills its tooltip.
function Q:NewMarker(name, w)
    local m = CreateFrame("Button", name, ring)
    m:SetWidth(w or 14)
    m:SetHeight(w or 14)
    m:SetFrameLevel(ring:GetFrameLevel() + 2)
    m.tex = m:CreateTexture(nil, "ARTWORK")
    m.tex:SetAllPoints(m)
    m:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    m:SetScript("OnEnter", function()
        if not this.OnTip then return end
        GameTooltip:SetOwner(this, "ANCHOR_LEFT")
        this:OnTip(GameTooltip)
        GameTooltip:Show()
    end)
    m:SetScript("OnLeave", function() GameTooltip:Hide() end)
    m:SetScript("OnClick", function() if this.OnClickMarker then this:OnClickMarker(arg1) end end)
    m:Hide()
    return m
end

-- Whether the minimap turns with the player (the "rotateMinimap" CVar of later clients; 1.12
-- and this client have none, so this is normally false). Checked at most once a second.
local rotCheck, rotOn = 0, false
function Q:MinimapRotates()
    local now = GetTime and GetTime() or 0
    if now >= rotCheck then
        rotCheck = now + 1
        -- 1.12 has no rotating minimap and no rotateMinimap CVar (asking for it raises
        -- "Couldn't find CVar"), so only a client that says it rotates turns this on.
        rotOn = (MinimapRotates and MinimapRotates() and true) or false
    end
    return rotOn
end

-- Screen angle (radians, 0 = east, counter-clockwise) at which a spot dx yards east and dy yards
-- south of the player shows around the minimap's centre. On a north-up minimap that is just the
-- map direction; on a rotating one north turns with the player, so the player's heading (radians
-- clockwise from north) comes off the bearing.
function Q:MarkerAngle(dx, dy)
    local bearing = atan2(dx, -dy)              -- clockwise from north
    if self:MinimapRotates() and self.Heading then
        local h = self:Heading()
        if h then bearing = bearing - h end
    end
    return math.pi / 2 - bearing
end

-- Put marker m at (x, y) on the current zone map: on the minimap when the spot is in view,
-- else on the ring at its bearing when ringOK. Both are measured from the minimap's centre (the
-- ring's centre) in the ring's units: the minimap at MAP_R per view radius, the ring exactly on
-- the middle of its band (RING_PIN_R). Returns "map", "ring" or nil; sets m.yards.
function Q:PlaceMarker(m, x, y, ringOK, zone)
    local px, py = self:PlayerPos()
    if (px == 0 and py == 0) or not x or not y then
        m:Hide()
        m.where = nil
        return nil
    end
    local yards, dx, dy = self:Yards(px, py, x, y, zone)
    m.yards = yards
    local radius = self:MinimapRadius()
    local a = self:MarkerAngle(dx, dy)
    if self:Get("minimapPins") and yards <= radius * 0.9 then
        local r = yards / radius * (self.MAP_R or 70)
        m:ClearAllPoints()
        m:SetPoint("CENTER", ring, "CENTER", math.cos(a) * r, math.sin(a) * r)
        m.where = "map"
        m:Show()
        return "map"
    end
    if ringOK then
        m:ClearAllPoints()
        m:SetPoint("CENTER", ring, "CENTER", math.cos(a) * self.RING_PIN_R, math.sin(a) * self.RING_PIN_R)
        m.where = "ring"
        m:Show()
        return "ring"
    end
    m:Hide()
    m.where = nil
    return nil
end

-- -- Refresh ------------------------------------------------------------------------------------

Q:OnRefresh(function(active)
    ring:SetFrameLevel(Q:RingLevel())
    Q:ApplyRingTheme()
    Q:RingGeometry()
    if not active then
        ring:Hide()
        Q:ApplyMinimapFrame(false)
        Q.ringShown = false
        Q:PlaceMinimap(false)
        coords:Hide()
        return
    end
    ring:Show()
    local showArt = Q:Get("showRing") and Q.hasRingArt
    if showArt then ringTex:Show() else ringTex:Hide() end
    -- the stock border goes only when the ring is really there to replace it
    Q:ApplyMinimapFrame(showArt and Q:Get("replaceBorder") and true or false)
    Q.ringShown = showArt and true or false
    Q:PlaceMinimap(Q.ringShown)
    Q:UpdateCoords()
end)

Q:Every(0.2, function() Q:UpdateCoords() end)
-- frames have their real sizes and the UI scale is set by the time the world loads; after that
-- a UI scale or window size change shows up in the poll (1.12 has no UI_SCALE_CHANGED)
Q:On("PLAYER_ENTERING_WORLD", function() layoutSig = nil; checkLayout() end)
Q:On("CVAR_UPDATE", function() checkLayout() end)
Q:Every(1, checkLayout)
