--[[
    Chrome.lua  -  the Meters look: an antiqued bronze frame round dark slate, a riveted header with
    the mode as its title (and a gold arrow for the mode menu), brass reset and cog buttons, a red
    close button, gold and dark tabs, textured bars tinted in class colours, and a gold scrollbar.

    The art is Open Vanilla's own (Meters\Art\*.tga, cut from the Meters design sheet); nothing of
    Blizzard's ships here. Windows.lua and Detail.lua call these after building their frames.
]]--

local W = WenillaCore
local UI = W.UI
local C = Chronicle

local ART = "Interface\\AddOns\\Meters\\Art\\"
C.ART = {
    frame = ART .. "Meters_Frame", header = ART .. "Meters_Header", close = ART .. "Meters_Close",
    reset = ART .. "Meters_Reset", gear = ART .. "Meters_Gear", arrow = ART .. "Meters_Arrow",
    tabOn = ART .. "Meters_TabOn", tabOff = ART .. "Meters_TabOff", colHead = ART .. "Meters_ColHead",
    fill = ART .. "Meters_Fill", scroll = ART .. "Meters_Scroll",
    thumb = ART .. "Meters_Thumb",
}
C.GOLD = { 1, 0.82, 0.42 }
C.BRONZE = { 0.56, 0.43, 0.22 }
C.HEADER_H = 13

-- Meters_Frame.tga is 256x128; corners 40x34 texels, drawn small (12x10 px) for a slim frame.
local FW, FH, CX, CY = 256, 128, 40, 34
local DX, DY = 12, 10
local OPACITY = 0.94

local function tex(parent, layer, path)
    local t = parent:CreateTexture(nil, layer)
    t:SetTexture(path)
    return t
end

-- Nine pieces of the frame texture round the window (corners keep their size, the rest stretches).
function C.Frame(f)
    f:SetBackdropColor(0, 0, 0, 0)
    f:SetBackdropBorderColor(0, 0, 0, 0)
    local u0, u1, u2, u3 = 0, CX / FW, (FW - CX) / FW, 1
    local v0, v1, v2, v3 = 0, CY / FH, (FH - CY) / FH, 1
    local cols = { { u0, u1 }, { u1, u2 }, { u2, u3 } }
    local rows = { { v0, v1 }, { v1, v2 }, { v2, v3 } }
    f.chrome = {}
    for r = 1, 3 do
        for c = 1, 3 do
            local t = tex(f, "BACKGROUND", C.ART.frame)
            t:SetTexCoord(cols[c][1], cols[c][2], rows[r][1], rows[r][2])
            -- the corners keep their gold brackets; the band between them is dark slate stone
            if (r == 2) ~= (c == 2) then t:SetVertexColor(0.50, 0.50, 0.55, OPACITY) else t:SetVertexColor(1, 1, 1, OPACITY) end
            f.chrome[(r - 1) * 3 + c] = t
        end
    end
    local p = f.chrome
    p[1]:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0); p[1]:SetWidth(DX); p[1]:SetHeight(DY)
    p[3]:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0); p[3]:SetWidth(DX); p[3]:SetHeight(DY)
    p[7]:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0); p[7]:SetWidth(DX); p[7]:SetHeight(DY)
    p[9]:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0); p[9]:SetWidth(DX); p[9]:SetHeight(DY)
    p[2]:SetPoint("TOPLEFT", p[1], "TOPRIGHT", 0, 0); p[2]:SetPoint("BOTTOMRIGHT", p[3], "BOTTOMLEFT", 0, 0)
    p[8]:SetPoint("TOPLEFT", p[7], "TOPRIGHT", 0, 0); p[8]:SetPoint("BOTTOMRIGHT", p[9], "BOTTOMLEFT", 0, 0)
    p[4]:SetPoint("TOPLEFT", p[1], "BOTTOMLEFT", 0, 0); p[4]:SetPoint("BOTTOMRIGHT", p[7], "TOPRIGHT", 0, 0)
    p[6]:SetPoint("TOPLEFT", p[3], "BOTTOMLEFT", 0, 0); p[6]:SetPoint("BOTTOMRIGHT", p[9], "TOPRIGHT", 0, 0)
    p[5]:SetPoint("TOPLEFT", p[1], "BOTTOMRIGHT", 0, 0); p[5]:SetPoint("BOTTOMRIGHT", p[9], "TOPLEFT", 0, 0)
    -- the stock window's own strip and theme painting stay out of the way
    if f.titleBar then f.titleBar:Hide() end
    if f.titleRule then f.titleRule:Hide() end
    f.paintSkin = function() end
end

-- A small art button; the highlight is the same art, brightened.
function C.ArtButton(parent, size, path, onClick, tooltip)
    local b = CreateFrame("Button", nil, parent)
    b:SetWidth(size)
    b:SetHeight(size)
    b:SetNormalTexture(path)
    b:SetPushedTexture(path)
    local pushed = b:GetPushedTexture()
    if pushed and pushed.SetVertexColor then pushed:SetVertexColor(0.7, 0.7, 0.7, 1) end
    b:SetHighlightTexture(path)
    local hl = b:GetHighlightTexture()
    if hl then
        if hl.SetBlendMode then hl:SetBlendMode("ADD") end
        if hl.SetVertexColor then hl:SetVertexColor(1, 1, 1, 0.35) end
    end
    b:SetScript("OnClick", onClick)
    if tooltip then
        b:SetScript("OnEnter", function()
            GameTooltip:SetOwner(this, "ANCHOR_TOP")
            GameTooltip:SetText(tooltip, 1, 1, 1, 1, 1)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    return b
end

-- The riveted header across the top: left cap, a stretched middle, right cap (Meters_Header.tga is
-- 128x32: caps of 45 and 19 texels round 37 texels of plain bronze).
function C.Header(f)
    local h = C.HEADER_H
    local s = h / 32
    local l = tex(f, "BORDER", C.ART.header)
    l:SetTexCoord(0, 45 / 128, 0, 1)
    l:SetPoint("TOPLEFT", f, "TOPLEFT", 3, -3)
    l:SetWidth(45 * s); l:SetHeight(h)
    local r = tex(f, "BORDER", C.ART.header)
    r:SetTexCoord(82 / 128, 101 / 128, 0, 1)
    r:SetPoint("TOPRIGHT", f, "TOPRIGHT", -3, -3)
    r:SetWidth(19 * s); r:SetHeight(h)
    local m = tex(f, "BORDER", C.ART.header)
    m:SetTexCoord(45 / 128, 82 / 128, 0, 1)
    m:SetPoint("TOPLEFT", l, "TOPRIGHT", 0, 0)
    m:SetPoint("BOTTOMRIGHT", r, "BOTTOMLEFT", 0, 0)
    -- a slim stone header: the bronze strip, greyed to slate
    l:SetVertexColor(0.58, 0.58, 0.62, 1); m:SetVertexColor(0.58, 0.58, 0.62, 1); r:SetVertexColor(0.58, 0.58, 0.62, 1)
    f.header3 = { l, m, r }
    f.headerAnchor = m

    -- the title in the middle of the strip, in gold
    if f.title then
        f.title:ClearAllPoints()
        f.title:SetPoint("CENTER", f, "TOP", -4, -3 - h / 2)
        UI.Font(f.title, 9, "")
        f.title:SetShadowOffset(1, -1)
        f.title:SetShadowColor(0, 0, 0, 1)
        f.title:SetTextColor(0.95, 0.88, 0.70)     -- parchment, as in the design
    end
    if f.icon then f.icon:SetAlpha(0) end

    -- the close button: red with a gold X, at the right end of the strip
    if f.closeButton then
        local c = f.closeButton
        c:SetWidth(h - 2); c:SetHeight(h - 2)
        c:ClearAllPoints()
        c:SetPoint("RIGHT", r, "RIGHT", -1, 0)
        c:SetNormalTexture(C.ART.close)
        c:SetPushedTexture(C.ART.close)
        local pt = c:GetPushedTexture()
        if pt and pt.SetVertexColor then pt:SetVertexColor(0.75, 0.75, 0.75, 1) end
        c:SetHighlightTexture(C.ART.close)
        local hl = c:GetHighlightTexture()
        if hl then
            if hl.SetBlendMode then hl:SetBlendMode("ADD") end
            if hl.SetVertexColor then hl:SetVertexColor(1, 1, 1, 0.35) end
        end
        if c.SetFrameLevel and f.dragHandle then c:SetFrameLevel(f.dragHandle:GetFrameLevel() + 2) end
    end

    -- the strip (less the buttons) drags the window
    if f.dragHandle then
        f.dragHandle:ClearAllPoints()
        f.dragHandle:SetPoint("TOPLEFT", f, "TOPLEFT", 3, -3)
        f.dragHandle:SetPoint("BOTTOMRIGHT", f, "TOPRIGHT", -3 - h, -3 - h)
    end
end

-- A square tool button for the end of the tab row: the dark tab art behind a gold icon.
function C.ToolButton(parent, size, icon, onClick, tooltip)
    local b = C.ArtButton(parent, size, C.ART.tabOff, onClick, tooltip)
    local n = b:GetNormalTexture()
    if n and n.SetTexCoord then n:SetTexCoord(0, 28 / 64, 0, 1) end
    local hl = b:GetHighlightTexture()
    if hl and hl.SetTexCoord then hl:SetTexCoord(0, 28 / 64, 0, 1) end
    local p = b:GetPushedTexture()
    if p and p.SetTexCoord then p:SetTexCoord(0, 28 / 64, 0, 1) end
    local ic = b:CreateTexture(nil, "OVERLAY")
    ic:SetTexture(icon)
    ic:SetPoint("CENTER", b, "CENTER", 0, 0)
    ic:SetWidth(size - 4); ic:SetHeight(size - 4)
    b.icon = ic
    return b
end

-- Tabs: gold when chosen, dark otherwise (Meters_TabOn/Off.tga are 64x32: 10-texel caps round an
-- 8-texel middle).
local function tabPieces(b)
    if b.ov then return b.ov end
    b.ov = {}
    local coords = { { 0, 10 / 64 }, { 10 / 64, 18 / 64 }, { 18 / 64, 28 / 64 } }
    for i = 1, 3 do
        local t = b:CreateTexture(nil, "BORDER")
        t:SetTexCoord(coords[i][1], coords[i][2], 0, 1)
        b.ov[i] = t
    end
    local h = b:GetHeight() or 18
    local cap = math.floor(h * 10 / 32 + 0.5)
    b.ov[1]:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0); b.ov[1]:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 0, 0); b.ov[1]:SetWidth(cap)
    b.ov[3]:SetPoint("TOPRIGHT", b, "TOPRIGHT", 0, 0); b.ov[3]:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 0, 0); b.ov[3]:SetWidth(cap)
    b.ov[2]:SetPoint("TOPLEFT", b.ov[1], "TOPRIGHT", 0, 0); b.ov[2]:SetPoint("BOTTOMRIGHT", b.ov[3], "BOTTOMLEFT", 0, 0)
    if b.bg then b.bg:Hide() end
    if b.edge then b.edge:Hide() end
    if b.line then b.line:Hide() end
    return b.ov
end

function C.SkinTabs(bar)
    if not bar or not bar.buttons then return end
    for _, b in ipairs(bar.buttons) do
        if b:IsShown() then
            local ov = tabPieces(b)
            local sel = (b.key == bar.selected) and b.key ~= "__add"
            local path = sel and C.ART.tabOn or C.ART.tabOff
            for i = 1, 3 do
                ov[i]:SetTexture(path)
                -- the chosen tab: a dark warm bronze, lit but not bright gold
                if sel then ov[i]:SetVertexColor(0.62, 0.52, 0.40, 1) else ov[i]:SetVertexColor(0.85, 0.85, 0.85, 1) end
            end
            if sel then b.text:SetTextColor(1, 0.96, 0.84) else b.text:SetTextColor(0.80, 0.76, 0.66) end
            if b.text.SetShadowOffset then b.text:SetShadowOffset(1, -1); b.text:SetShadowColor(0, 0, 0, 1) end
            if not b.ovHooked then
                b.ovHooked = true
                b:SetScript("OnLeave", function() C.SkinTabs(bar) end)
            end
        end
    end
end

-- The tab bar keeps its look through every select and rebuild.
function C.ChromeTabs(bar)
    local setTabs, choose = bar.SetTabs, bar.Select
    function bar:SetTabs(list) setTabs(self, list); C.SkinTabs(self) end
    function bar:Select(key, silent) choose(self, key, silent); C.SkinTabs(self) end
    C.SkinTabs(bar)
    return bar
end

-- The bar colour for a class: the game's own class colours (warrior tan, hunter green, mage blue,
-- warlock purple, ...), or the suite's when the client has none.
function C.BarColor(token)
    local rc = RAID_CLASS_COLORS and token and RAID_CLASS_COLORS[token]
    if rc and rc.r then return rc.r, rc.g, rc.b end
    return UI.ClassColor(token)
end

-- The fill colours. "Meters" (the default): warrior red, the rest the game's class colours (hunter
-- green, mage cyan-blue, warlock purple, rogue yellow, priest white, druid orange, shaman blue,
-- paladin pink). "Standard": the game's class colours for every class (warrior tan).
C.METERS_COLORS = { WARRIOR = { 0.78, 0.20, 0.20 }, SHAMAN = { 0.0, 0.44, 0.87 } }
C.FILL_ALPHA = 0.9
function C.BarColor(token)
    local palette = W:Setting("Meters", "classPalette", "meters")
    local own = palette ~= "standard" and token and C.METERS_COLORS[token]
    if own then return own[1], own[2], own[3] end
    local rc = RAID_CLASS_COLORS and token and RAID_CLASS_COLORS[token]
    if rc and rc.r then return rc.r, rc.g, rc.b end
    return UI.ClassColor(token)
end

-- A row is one flat rectangle the full width: a dark (#111) background, the fill from its left edge
-- (square ends, a faint grain, ~0.9 opaque, as long as the value), and over both the 16 px class icon
-- (1 px black border) at the left, the name in white with a black outline, and the numbers at the right.
function C.ChromeRow(row)
    row.track:SetTexture(0.067, 0.067, 0.067, 0.95)
    if row.iconBox then
        if row.iconBox.edge then row.iconBox.edge:SetTexture(0, 0, 0, 1) end
        row.iconBox:SetFrameLevel(row.bar:GetFrameLevel() + 1)
    end
    function row:SetColor(r, g, b, a)
        self.bar:SetStatusBarColor(r, g, b, a or C.FILL_ALPHA)
    end
    function row:SetFraction(frac)
        if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
        self.bar:SetValue(frac)
    end
end

-- Sizes a row for height h: background and fill the whole row, the icon 4 px in, the name 6 px after
-- it, the numbers 6 px from the right edge.
function C.LayoutRow(row, h, width)
    local icon = math.min(16, h - 2)
    row.track:ClearAllPoints()
    row.track:SetAllPoints(row)
    row.bar:ClearAllPoints()
    row.bar:SetAllPoints(row)
    if row.iconBox then
        row.iconBox:SetWidth(icon); row.iconBox:SetHeight(icon)
        row.iconBox:ClearAllPoints()
        row.iconBox:SetPoint("LEFT", row, "LEFT", 4, 0)
    end
    row.left:ClearAllPoints(); row.left:SetPoint("LEFT", row, "LEFT", 4 + icon + 6, 0)
    row.right:ClearAllPoints(); row.right:SetPoint("RIGHT", row, "RIGHT", -6, 0)
end

-- The gold scrollbar at the right edge: a rod and a knob; a click on the rod pages there.
function C.Scrollbar(f, onClick)
    local s = CreateFrame("Button", nil, f)
    s:SetWidth(6)
    local rod = tex(s, "ARTWORK", C.ART.scroll)
    rod:SetAllPoints(s)
    local knob = tex(s, "OVERLAY", C.ART.thumb)
    knob:SetWidth(6); knob:SetHeight(12)
    s.rod, s.knob = rod, knob
    s:SetScript("OnClick", function()
        local _, y = GetCursorPosition()
        local scale = (s.GetEffectiveScale and s:GetEffectiveScale()) or 1
        if scale <= 0 then scale = 1 end
        local top, bottom = s:GetTop(), s:GetBottom()
        if not top or not bottom or top <= bottom then return end
        if onClick then onClick((top - y / scale) / (top - bottom)) end
    end)
    -- frac: 0 at the top, 1 at the bottom
    function s:SetKnob(frac)
        local h = self:GetHeight() or 0
        if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
        self.knob:ClearAllPoints()
        self.knob:SetPoint("TOP", self, "TOP", 0, -math.floor((h - 12) * frac + 0.5))
    end
    s:Hide()
    return s
end
