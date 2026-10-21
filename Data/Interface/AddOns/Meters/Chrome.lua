--[[
    Chrome.lua  -  the Meters look, from the Meters art kit: a dark mottled stone window with a thin gold
    border and gold ornaments in the bottom corners, a slim header with the mode as its title (and a
    gold arrow for the mode menu) and a red square close button, a darker strip under it holding the
    tabs and the square reset and cog buttons, a column strip fading in from both ends, flat rows packed
    together with a grained class-coloured fill, and a dark scrollbar with chevron caps and arrow buttons.

    The art is Open Vanilla's own (Meters\Art\*.tga, cut from the owner's Meters kit); nothing of
    Blizzard's ships here: class icons are the player's own game icons. Window.lua and Detail.lua call
    these after building their frames.
]]--

local W = WenillaCore
local UI = W.UI
local C = Chronicle

local ART = "Interface\\AddOns\\Meters\\Art\\"
C.ART = {
    window = ART .. "Meters_Window", close = ART .. "Meters_Close", arrow = ART .. "Meters_Arrow",
    reset = ART .. "Meters_Reset", gear = ART .. "Meters_Gear",
    tabOn = ART .. "Meters_TabOn", tabOff = ART .. "Meters_TabOff", colFade = ART .. "Meters_ColFade",
    fill = ART .. "Meters_Fill", shadow = ART .. "Meters_Shadow", innerShadow = ART .. "Meters_InnerShadow",
    scrollTop = ART .. "Meters_ScrollTop", scrollTrack = ART .. "Meters_ScrollTrack",
    scrollBottom = ART .. "Meters_ScrollBottom", thumb = ART .. "Meters_Thumb",
    up = ART .. "Meters_Up", down = ART .. "Meters_Down",
}
C.GOLD = { 1, 0.82, 0.42 }
C.PARCHMENT = { 0.95, 0.88, 0.70 }

-- Meters_Window.tga holds the kit's window (494x392 px, stored at 256x256). The window is drawn at
-- 300/494 of the kit's size: S. Its nine pieces: 44 px columns at the sides (the bottom corners carry
-- the ornaments), a 76 px top band (header and the strip under it) and a 44 px bottom band.
local KW, KH = 494, 392
local KL, KR, KT, KB = 44, 44, 76, 44
C.S = 300 / KW
local S = C.S
C.HEADER_H = math.floor(25 * S + 0.5)          -- the header bar (kit rows 4..28)
C.BAND_H = math.floor(KT * S + 0.5)            -- header + strip: where the panel starts
C.EDGE = math.floor(14 * S + 0.5)              -- the border's width: content starts this far in

local function tex(parent, layer, path)
    local t = parent:CreateTexture(nil, layer)
    t:SetTexture(path)
    return t
end

function C.Frame(f)
    f:SetBackdropColor(0, 0, 0, 0)
    f:SetBackdropBorderColor(0, 0, 0, 0)
    local us = { 0, KL / KW, (KW - KR) / KW, 1 }
    local vs = { 0, KT / KH, (KH - KB) / KH, 1 }
    f.chrome = {}
    for r = 1, 3 do
        for c = 1, 3 do
            local t = tex(f, "BORDER", C.ART.window)
            t:SetTexCoord(us[c], us[c + 1], vs[r], vs[r + 1])
            f.chrome[(r - 1) * 3 + c] = t
        end
    end
    local dl, dr = math.floor(KL * S + 0.5), math.floor(KR * S + 0.5)
    local dt, db = C.BAND_H, math.floor(KB * S + 0.5)
    local p = f.chrome
    p[1]:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0); p[1]:SetWidth(dl); p[1]:SetHeight(dt)
    p[3]:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0); p[3]:SetWidth(dr); p[3]:SetHeight(dt)
    p[7]:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0); p[7]:SetWidth(dl); p[7]:SetHeight(db)
    p[9]:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0); p[9]:SetWidth(dr); p[9]:SetHeight(db)
    p[2]:SetPoint("TOPLEFT", p[1], "TOPRIGHT", 0, 0); p[2]:SetPoint("BOTTOMRIGHT", p[3], "BOTTOMLEFT", 0, 0)
    p[8]:SetPoint("TOPLEFT", p[7], "TOPRIGHT", 0, 0); p[8]:SetPoint("BOTTOMRIGHT", p[9], "BOTTOMLEFT", 0, 0)
    p[4]:SetPoint("TOPLEFT", p[1], "BOTTOMLEFT", 0, 0); p[4]:SetPoint("BOTTOMRIGHT", p[7], "TOPRIGHT", 0, 0)
    p[6]:SetPoint("TOPLEFT", p[3], "BOTTOMLEFT", 0, 0); p[6]:SetPoint("BOTTOMRIGHT", p[9], "TOPRIGHT", 0, 0)
    p[5]:SetPoint("TOPLEFT", p[1], "BOTTOMRIGHT", 0, 0); p[5]:SetPoint("BOTTOMRIGHT", p[9], "TOPLEFT", 0, 0)
    C.OuterShadow(f)
    -- the stock window's own strip and theme painting stay out of the way
    if f.titleBar then f.titleBar:Hide() end
    if f.titleRule then f.titleRule:Hide() end
    f.paintSkin = function() end
end

-- A soft shadow round the window (Meters_Shadow.tga: 58% black fading out over its outer 8 texels,
-- 9-sliced at 16), 8 px out from the edges and dropped 2 px, so the window lifts off the game.
function C.OuterShadow(f)
    local o, c = 8, 8
    local uv = { 0, 16 / 64, 48 / 64, 1 }
    f.shadow = {}
    for r = 1, 3 do
        for col = 1, 3 do
            local t = tex(f, "BACKGROUND", C.ART.shadow)
            t:SetTexCoord(uv[col], uv[col + 1], uv[r], uv[r + 1])
            f.shadow[(r - 1) * 3 + col] = t
        end
    end
    local p = f.shadow
    p[1]:SetPoint("TOPLEFT", f, "TOPLEFT", -o, o - 2); p[1]:SetWidth(c + o); p[1]:SetHeight(c + o)
    p[3]:SetPoint("TOPRIGHT", f, "TOPRIGHT", o, o - 2); p[3]:SetWidth(c + o); p[3]:SetHeight(c + o)
    p[7]:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", -o, -o - 2); p[7]:SetWidth(c + o); p[7]:SetHeight(c + o)
    p[9]:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", o, -o - 2); p[9]:SetWidth(c + o); p[9]:SetHeight(c + o)
    p[2]:SetPoint("TOPLEFT", p[1], "TOPRIGHT", 0, 0); p[2]:SetPoint("BOTTOMRIGHT", p[3], "BOTTOMLEFT", 0, 0)
    p[8]:SetPoint("TOPLEFT", p[7], "TOPRIGHT", 0, 0); p[8]:SetPoint("BOTTOMRIGHT", p[9], "BOTTOMLEFT", 0, 0)
    p[4]:SetPoint("TOPLEFT", p[1], "BOTTOMLEFT", 0, 0); p[4]:SetPoint("BOTTOMRIGHT", p[7], "TOPRIGHT", 0, 0)
    p[6]:SetPoint("TOPLEFT", p[3], "BOTTOMLEFT", 0, 0); p[6]:SetPoint("BOTTOMRIGHT", p[9], "TOPRIGHT", 0, 0)
    p[5]:SetPoint("TOPLEFT", p[1], "BOTTOMRIGHT", 0, 0); p[5]:SetPoint("BOTTOMRIGHT", p[9], "TOPLEFT", 0, 0)
end

-- The rows sit recessed in the stone: a soft dark edge along the inside of the rows area (strongest
-- at the top), drawn over the rows. `area` is a frame over the rows; returns the overlay.
function C.InnerShadow(area)
    local o = CreateFrame("Frame", nil, area)
    o:SetAllPoints(area)
    o:SetFrameLevel(area:GetFrameLevel() + 6)
    -- top: the gradient as it is (dark at the top); bottom: flipped; sides: turned on their side
    o.top = tex(o, "OVERLAY", C.ART.innerShadow)
    o.top:SetPoint("TOPLEFT", o, "TOPLEFT", 0, 0); o.top:SetPoint("TOPRIGHT", o, "TOPRIGHT", 0, 0); o.top:SetHeight(8)
    o.bottom = tex(o, "OVERLAY", C.ART.innerShadow)
    o.bottom:SetTexCoord(0, 1, 1, 0)
    o.bottom:SetPoint("BOTTOMLEFT", o, "BOTTOMLEFT", 0, 0); o.bottom:SetPoint("BOTTOMRIGHT", o, "BOTTOMRIGHT", 0, 0); o.bottom:SetHeight(3)
    o.left = tex(o, "OVERLAY", C.ART.innerShadow)
    o.left:SetTexCoord(0, 1, 0, 1, 1, 1, 1, 0)     -- 90 degrees: dark at the left
    o.left:SetPoint("TOPLEFT", o, "TOPLEFT", 0, 0); o.left:SetPoint("BOTTOMLEFT", o, "BOTTOMLEFT", 0, 0); o.left:SetWidth(4)
    o.right = tex(o, "OVERLAY", C.ART.innerShadow)
    o.right:SetTexCoord(1, 0, 1, 1, 0, 0, 0, 1)    -- dark at the right
    o.right:SetPoint("TOPRIGHT", o, "TOPRIGHT", 0, 0); o.right:SetPoint("BOTTOMRIGHT", o, "BOTTOMRIGHT", 0, 0); o.right:SetWidth(4)
    return o
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
        if hl.SetVertexColor then hl:SetVertexColor(1, 1, 1, 0.3) end
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

-- The square reset and cog buttons are whole pieces of the kit.
-- The reset and cog: 20 px square buttons drawn on whole pixels at the top left of a 32x32 texture.
C.TOOL_SIZE = 20
function C.ToolButton(parent, size, path, onClick, tooltip)
    local b = C.ArtButton(parent, size, path, onClick, tooltip)
    local u = C.TOOL_SIZE / 32          -- the button's texels; crisp when size is 20
    for _, t in ipairs({ b:GetNormalTexture(), b:GetPushedTexture(), b:GetHighlightTexture() }) do
        if t and t.SetTexCoord then t:SetTexCoord(0, u, 0, u) end
    end
    b.icon = b:GetNormalTexture()
    return b
end

-- The header: the title centred on the kit's header bar, a gold arrow after it, the red X at the
-- right end; the bar itself (less the X) drags the window.
function C.Header(f)
    local h = C.HEADER_H
    if f.title then
        f.title:ClearAllPoints()
        f.title:SetPoint("CENTER", f, "TOP", -4, -math.floor(16 * S + 0.5))
        UI.Font(f.title, 9, "")
        f.title:SetShadowOffset(1, -1)
        f.title:SetShadowColor(0, 0, 0, 1)
        f.title:SetTextColor(C.PARCHMENT[1], C.PARCHMENT[2], C.PARCHMENT[3])
    end
    if f.icon then f.icon:SetAlpha(0) end
    local xs = math.floor(27 * S + 0.5)
    if f.closeButton then
        local c = f.closeButton
        c:SetWidth(xs); c:SetHeight(xs)
        c:ClearAllPoints()
        c:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
        c:SetNormalTexture(C.ART.close)
        c:SetPushedTexture(C.ART.close)
        local pt = c:GetPushedTexture()
        if pt and pt.SetVertexColor then pt:SetVertexColor(0.75, 0.75, 0.75, 1) end
        c:SetHighlightTexture(C.ART.close)
        local hl = c:GetHighlightTexture()
        if hl then
            if hl.SetBlendMode then hl:SetBlendMode("ADD") end
            if hl.SetVertexColor then hl:SetVertexColor(1, 1, 1, 0.3) end
        end
        if c.SetFrameLevel and f.dragHandle then c:SetFrameLevel(f.dragHandle:GetFrameLevel() + 2) end
    end
    if f.dragHandle then
        f.dragHandle:ClearAllPoints()
        f.dragHandle:SetPoint("TOPLEFT", f, "TOPLEFT", 3, -2)
        f.dragHandle:SetPoint("BOTTOMRIGHT", f, "TOPRIGHT", -xs - 2, -h)
    end
end

-- Tabs: the kit's gold-bordered tab when chosen, the dark one otherwise. Meters_TabOn/Off.tga are drawn
-- on whole pixels for an 18 px tab: a 6-texel cap each side (rounded top corners, flat bottom) and one
-- middle column repeated between them, rows 0..17 of 32. Three pieces, so the caps never stretch; the
-- middle samples half a texel inside its run, never a neighbour.
C.TAB_H, C.TAB_CAP = 18, 6
local TV = C.TAB_H / 32
local function tabPieces(b)
    if b.ov then return b.ov end
    b.ov = {}
    local coords = { { 0, 6 / 64 }, { 16.5 / 64, 47.5 / 64 }, { 58 / 64, 1 } }
    for i = 1, 3 do
        local t = b:CreateTexture(nil, "BORDER")
        t:SetTexCoord(coords[i][1], coords[i][2], 0, TV)
        b.ov[i] = t
    end
    local cap = C.TAB_CAP
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
            for i = 1, 3 do ov[i]:SetTexture(path) end
            if b.text.SetFont and not b.ovFont then
                b.ovFont = true
                b.text:SetFont(C.TAB_FONT, C.TAB_SIZE, "")
                b.text:ClearAllPoints()
                b.text:SetPoint("CENTER", b, "CENTER", 0, 1)        -- optical centre: a pixel up off the tab's lip
            end
            local c = sel and C.TAB_GOLD or C.TAB_INK
            b.text:SetTextColor(c[1], c[2], c[3])
            if b.text.SetShadowOffset then b.text:SetShadowOffset(1, -1); b.text:SetShadowColor(0, 0, 0, 1) end
            if not b.ovHooked then
                b.ovHooked = true
                b:SetScript("OnLeave", function() C.SkinTabs(bar) end)
            end
        end
    end
end

-- The tab bar keeps its look through every select and rebuild.
-- Every tab on whole pixels (the stock bar sizes them from the text's measured width), at least two
-- caps and a pixel wide, all 18 px tall.
local function snapTabs(bar)
    local x = 0
    bar:SetHeight(C.TAB_H)
    for _, b in ipairs(bar.buttons) do
        if b:IsShown() then
            local w = math.max(2 * C.TAB_CAP + 1, math.floor((b:GetWidth() or 0) + 0.5))
            b:SetWidth(w)
            b:SetHeight(C.TAB_H)
            b:ClearAllPoints()
            b:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", x, 0)
            x = x + w + 2
        end
    end
    bar:SetWidth(math.max(1, x))
end

function C.ChromeTabs(bar)
    local setTabs, choose = bar.SetTabs, bar.Select
    function bar:SetTabs(list) setTabs(self, list); snapTabs(self); C.SkinTabs(self) end
    function bar:Select(key, silent) choose(self, key, silent); C.SkinTabs(self) end
    C.SkinTabs(bar)
    return bar
end

-- The column strip: the kit's dark strips fading in from the left ("Player") and the right ("Damage").
function C.ColumnStrip(header)
    local l = tex(header, "BACKGROUND", C.ART.colFade)
    l:SetPoint("TOPLEFT", header, "TOPLEFT", 0, 0); l:SetPoint("BOTTOMLEFT", header, "BOTTOMLEFT", 0, 0)
    l:SetWidth(90)
    local r = tex(header, "BACKGROUND", C.ART.colFade)
    r:SetTexCoord(1, 0, 0, 1)
    r:SetPoint("TOPRIGHT", header, "TOPRIGHT", 0, 0); r:SetPoint("BOTTOMRIGHT", header, "BOTTOMRIGHT", 0, 0)
    r:SetWidth(110)
    header.fadeL, header.fadeR = l, r
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

-- A row is one flat rectangle the full width, packed against the next: a dark (#111) background, the
-- fill from its left edge (the class colour, ~0.9 opaque, a faint grain, as long as the value), and
-- over both the 16 px class icon (1 px black border) 2 px in, the name and the numbers. The text is
-- a thick rounded face, off-white with a soft 1 px shadow so it sits in the bar.
-- The row font: Nunito ExtraBold (OFL, Fonts\OFL.txt), a thick rounded sans; "Arial Narrow" in the
-- settings switches to the client's own. The client resolves a font path when it draws, and an
-- unreadable one falls back to its default face, so the setting is the way back if ever needed.
local FONTS = "Interface\\AddOns\\Meters\\Fonts\\"
C.FONT_ROUNDED = FONTS .. "Nunito-ExtraBold.ttf"
-- Tabs in the Quests tracker's type: Friz Quadrata, its gold-yellow for the chosen tab and its light
-- parchment ink for the rest, with the same solid 1 px shadow.
C.TAB_FONT, C.TAB_SIZE = "Fonts\\FRIZQT__.TTF", 11
C.TAB_GOLD, C.TAB_INK = { 1, 0.82, 0 }, { 0.95, 0.92, 0.85 }
C.FONT_NARROW = "Fonts\\ARIALN.TTF"
C.ROW_FONTS = { { value = "rounded", label = "Rounded" }, { value = "narrow", label = "Arial Narrow" } }
function C.RowFontPath()
    if W:Setting("Meters", "rowFont", "rounded") == "narrow" then return C.FONT_NARROW end
    return C.FONT_ROUNDED
end
C.NAME_COLOR = { 0.92, 0.90, 0.86 }
C.NUM_COLOR = { 0.84, 0.82, 0.78 }

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

-- The row text's face, size and the shadow that sets it into the bar.
function C.RowText(fs, size)
    if fs.SetFont then fs:SetFont(C.RowFontPath(), size, "") end
    fs:SetShadowOffset(1, -1)
    fs:SetShadowColor(0, 0, 0, 0.8)
end

-- Sizes a row for height h (the icon h - 2, so 1 px above and below): background and fill the whole
-- row, the icon 2 px in, the name 5 px after it, the numbers 5 px from the right edge.
function C.LayoutRow(row, h, width)
    local icon = h - 2
    row.track:ClearAllPoints()
    row.track:SetAllPoints(row)
    row.bar:ClearAllPoints()
    row.bar:SetAllPoints(row)
    if row.iconBox then
        row.iconBox:SetWidth(icon); row.iconBox:SetHeight(icon)
        row.iconBox:ClearAllPoints()
        row.iconBox:SetPoint("LEFT", row, "LEFT", 2, 0)
    end
    row.left:ClearAllPoints(); row.left:SetPoint("LEFT", row, "LEFT", 2 + icon + 5, 0)
    row.right:ClearAllPoints(); row.right:SetPoint("RIGHT", row, "RIGHT", -5, 0)
end

-- The scrollbar: a dark track with gold chevron caps and a square thumb; a click on the track pages
-- there. onStep(-1 / 1) for the up and down arrow buttons the window puts under it.
C.SCROLL_W = 10
function C.Scrollbar(f, onClick)
    local s = CreateFrame("Button", nil, f)
    local w = C.SCROLL_W
    s:SetWidth(w)
    local top = tex(s, "ARTWORK", C.ART.scrollTop)
    top:SetPoint("TOPLEFT", s, "TOPLEFT", 0, 0); top:SetWidth(w); top:SetHeight(w)
    local bottom = tex(s, "ARTWORK", C.ART.scrollBottom)
    bottom:SetPoint("BOTTOMLEFT", s, "BOTTOMLEFT", 0, 0); bottom:SetWidth(w); bottom:SetHeight(w)
    local track = tex(s, "BACKGROUND", C.ART.scrollTrack)
    track:SetPoint("TOPLEFT", top, "BOTTOMLEFT", 0, 2); track:SetPoint("BOTTOMRIGHT", bottom, "TOPRIGHT", 0, -2)
    local knob = tex(s, "OVERLAY", C.ART.thumb)
    knob:SetWidth(w - 2); knob:SetHeight(w - 2)
    s.top, s.bottom, s.rod, s.knob = top, bottom, track, knob
    s:SetScript("OnClick", function()
        local _, y = GetCursorPosition()
        local scale = (s.GetEffectiveScale and s:GetEffectiveScale()) or 1
        if scale <= 0 then scale = 1 end
        local t, b = s:GetTop(), s:GetBottom()
        if not t or not b or t <= b then return end
        if onClick then onClick((t - y / scale) / (t - b)) end
    end)
    -- frac: 0 at the top, 1 at the bottom; the thumb runs between the two caps
    function s:SetKnob(frac)
        local h = self:GetHeight() or 0
        if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
        local run = h - 2 * w - (w - 2)
        self.knob:ClearAllPoints()
        self.knob:SetPoint("TOP", self, "TOP", 0, -(w + math.floor(math.max(0, run) * frac + 0.5)))
    end
    s:Hide()
    return s
end
