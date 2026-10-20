--[[
    Skin.lua  (Chat)
    The look. Styles the stock chat frames in place, never replacing them:

        panel     a themed face behind each visible ChatFrameN (opacity slider), a 1 px light top
                  edge, the theme's edge art and a soft shadow underneath. ChatFrame1's panel
                  also holds the input line, so the default frame sits 24 px higher.
        tabs      flat tabs joined to the panel's top; the active one has an accent underline and
                  new lines show a small dot (FCF_FlashTab no longer flashes).
        input     ChatFrameEditBox inset into the panel, the channel name in its own colour.
        buttons   the scroll buttons and the speech-bubble button are hidden; a thin scrollbar
                  shows on hover, a "jump to latest" arrow when scrolled up, and the emote/voice
                  menu, Copy and settings sit in a small menu on the tab bar.
        fade      after 20 s (or a minute) of quiet the frame chrome fades; hover or a new line
                  brings it back. "Never" keeps it up.
        move      drag a tab to move (stock), the corner grip to resize; both snap to a 4 px grid
                  and to the screen edges. Move Anything (/move) also lists the chat.

    Everything is undone by C:Unskin() when the addon is turned off.
]]--

local W = WenillaCore
local C = CPChat
local NOOP = function() end
local floor = math.floor

C.PAD = { left = 6, right = 8, top = 4, bottom = 6, input = 28 }
C.TAB_H = 20
C.RAISE = 72   -- the input line under the chat, plus a clear gap above the action bars, the XP bar and the gryphons
C.skinned = {}

local STOCK_TEXTURES = { "Background", "TopLeftTexture", "BottomLeftTexture", "TopRightTexture",
    "BottomRightTexture", "LeftTexture", "RightTexture", "BottomTexture", "TopTexture" }
local STOCK_BUTTONS = { "UpButton", "DownButton", "BottomButton", "TopButton" }

local function now() return GetTime and GetTime() or 0 end

-- Hide a stock region or button while the skin is on; FCF's fades call Show(), so that is muted.
local function suppress(o)
    if not o or o.cpSuppressed then return end
    o.cpSuppressed = { shown = o:IsShown() and true or false }
    o:Hide()
    o.Show = NOOP
end
local function unsuppress(o)
    local s = o and o.cpSuppressed
    if not s then return end
    o.Show = nil
    o.cpSuppressed = nil
    if s.shown then o:Show() end
end
C.Suppress, C.Unsuppress = suppress, unsuppress

local function savePoints(f)
    local pts = {}
    for i = 1, (f.GetNumPoints and f:GetNumPoints() or 0) do
        local p, rel, rp, x, y = f:GetPoint(i)
        if p then table.insert(pts, { p, rel, rp, x, y }) end
    end
    return pts
end
local function loadPoints(f, pts)
    if not pts or not pts[1] then return end
    f:ClearAllPoints()
    for _, p in ipairs(pts) do f:SetPoint(p[1], p[2], p[3], p[4], p[5]) end
end

local function artName(kind, theme)
    return "Chat_" .. kind .. (theme.suffix or "")
end

-- -- 9-slice pieces (Chat_Edge*, Chat_Shadow: 64x64, 16 px corners) -------------------------------

local SLICES = {
    { "TL", 0, 0.25, 0, 0.25 }, { "T", 0.25, 0.75, 0, 0.25 }, { "TR", 0.75, 1, 0, 0.25 },
    { "L", 0, 0.25, 0.25, 0.75 }, { "R", 0.75, 1, 0.25, 0.75 },
    { "BL", 0, 0.25, 0.75, 1 }, { "B", 0.25, 0.75, 0.75, 1 }, { "BR", 0.75, 1, 0.75, 1 },
}

local function newSlice(parent, layer)
    local s = {}
    for _, d in ipairs(SLICES) do
        local t = parent:CreateTexture(nil, layer)
        t.cpCoord = d
        s[d[1]] = t
    end
    return s
end

-- Lay the pieces around rect (outset o, corner size n, shifted dy). Returns true if the art loaded.
local function setSlice(s, rect, name, n, o, dy)
    local loaded = W:Art(s.TL, name, nil)
    for _, d in ipairs(SLICES) do
        local t = s[d[1]]
        if loaded then
            if t ~= s.TL then W:Art(t, name, nil) end
            t:SetTexCoord(d[2], d[3], d[4], d[5])
            t:Show()
        else
            t:Hide()
        end
    end
    if not loaded then return false end
    dy = dy or 0
    s.TL:ClearAllPoints(); s.TL:SetPoint("TOPLEFT", rect, "TOPLEFT", -o, o + dy); s.TL:SetWidth(n); s.TL:SetHeight(n)
    s.TR:ClearAllPoints(); s.TR:SetPoint("TOPRIGHT", rect, "TOPRIGHT", o, o + dy); s.TR:SetWidth(n); s.TR:SetHeight(n)
    s.BL:ClearAllPoints(); s.BL:SetPoint("BOTTOMLEFT", rect, "BOTTOMLEFT", -o, -o + dy); s.BL:SetWidth(n); s.BL:SetHeight(n)
    s.BR:ClearAllPoints(); s.BR:SetPoint("BOTTOMRIGHT", rect, "BOTTOMRIGHT", o, -o + dy); s.BR:SetWidth(n); s.BR:SetHeight(n)
    s.T:ClearAllPoints(); s.T:SetPoint("TOPLEFT", s.TL, "TOPRIGHT", 0, 0); s.T:SetPoint("BOTTOMRIGHT", s.TR, "BOTTOMLEFT", 0, 0)
    s.B:ClearAllPoints(); s.B:SetPoint("TOPLEFT", s.BL, "TOPRIGHT", 0, 0); s.B:SetPoint("BOTTOMRIGHT", s.BR, "BOTTOMLEFT", 0, 0)
    s.L:ClearAllPoints(); s.L:SetPoint("TOPLEFT", s.TL, "BOTTOMLEFT", 0, 0); s.L:SetPoint("BOTTOMRIGHT", s.BL, "TOPRIGHT", 0, 0)
    s.R:ClearAllPoints(); s.R:SetPoint("TOPLEFT", s.TR, "BOTTOMLEFT", 0, 0); s.R:SetPoint("BOTTOMRIGHT", s.BR, "TOPRIGHT", 0, 0)
    return true
end

local function sliceAlpha(s, a)
    for _, d in ipairs(SLICES) do s[d[1]]:SetAlpha(a) end
end

-- -- Which frames, which tabs ----------------------------------------------------------------------

local function tabOf(f) return f and getglobal(f:GetName() .. "Tab") end
C.TabOf = tabOf

function C:Docked()
    local out = {}
    if type(DOCKED_CHAT_FRAMES) == "table" and DOCKED_CHAT_FRAMES[1] then
        for _, f in ipairs(DOCKED_CHAT_FRAMES) do table.insert(out, f) end
        return out
    end
    for i = 1, (NUM_CHAT_WINDOWS or 7) do
        local f = getglobal("ChatFrame" .. i)
        local t = tabOf(f)
        if f and (i == 1 or (t and t:IsShown() and f.isDocked ~= false and not f.cpUndocked)) then table.insert(out, f) end
    end
    return out
end

function C:IsDocked(f)
    for _, d in ipairs(self:Docked()) do if d == f then return true end end
    return false
end

function C:Selected()
    if self.whisperView or self.worldView then return nil end
    return SELECTED_DOCK_FRAME or SELECTED_CHAT_FRAME or DEFAULT_CHAT_FRAME or ChatFrame1
end

-- -- Building the pieces ---------------------------------------------------------------------------

local function iconButton(parent, name, art, fallbackText, tip, onClick)
    local b = CreateFrame("Button", name, parent)
    b:SetWidth(18)
    b:SetHeight(18)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints(b)
    b.cpArt = art
    b.label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.label:SetPoint("CENTER", b, "CENTER", 0, 1)
    b.label:SetText(fallbackText)
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(b)
    hl:SetTexture(1, 1, 1, 0.12)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetScript("OnClick", onClick)
    b:SetScript("OnEnter", function()
        C.lastActivity = now()
        if GameTooltip then
            GameTooltip:SetOwner(b, "ANCHOR_TOP")
            GameTooltip:SetText(tip, 1, 1, 1)
            GameTooltip:Show()
        end
    end)
    b:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    return b
end

-- The tab bar's own buttons (menu, copy) and the whisper tabs live on a strip that follows
-- ChatFrame1's panel, so they stay put whichever docked tab is showing.
function C:Bar()
    if self.bar then return self.bar end
    local b = CreateFrame("Frame", "CPChatBar", UIParent)
    b:SetHeight(self.TAB_H)
    b:SetWidth(44)
    b.menu = iconButton(b, "CPChatMenuButton", "Chat_Menu", "...", "Chat menu", function() C:OpenMenu(this) end)
    b.menu:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -2, 1)
    b.copy = iconButton(b, "CPChatCopyButton", "Chat_Copy", "C", "Copy chat", function() C:OpenCopy() end)
    b.copy:SetPoint("RIGHT", b.menu, "LEFT", -2, 0)
    b:Hide()
    self.bar = b
    return b
end

function C:SkinFor(f)
    if f.cpSkin then return f.cpSkin end
    local k = { frame = f }
    local name = f:GetName()

    k.back = CreateFrame("Frame", name .. "CPShadow", f)
    k.shadow = newSlice(k.back, "BACKGROUND")

    local p = CreateFrame("Frame", name .. "CPPanel", f)
    k.panel = p
    p.face = p:CreateTexture(nil, "BACKGROUND")
    p.face:SetAllPoints(p)
    p.edge = newSlice(p, "BORDER")
    p.lines = {}
    for _, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
        local t = p:CreateTexture(nil, "BORDER")
        if side == "TOP" or side == "BOTTOM" then
            t:SetHeight(1)
            t:SetPoint(side .. "LEFT", p, side .. "LEFT", 0, 0)
            t:SetPoint(side .. "RIGHT", p, side .. "RIGHT", 0, 0)
        else
            t:SetWidth(1)
            t:SetPoint("TOP" .. side, p, "TOP" .. side, 0, 0)
            t:SetPoint("BOTTOM" .. side, p, "BOTTOM" .. side, 0, 0)
        end
        p.lines[side] = t
    end
    p.top = p:CreateTexture(nil, "ARTWORK")
    p.top:SetHeight(1)
    p.top:SetPoint("TOPLEFT", p, "TOPLEFT", 1, -1)
    p.top:SetPoint("TOPRIGHT", p, "TOPRIGHT", -1, -1)

    -- the input line's well (docked frames), with a hint while you are not typing
    p.well = p:CreateTexture(nil, "BORDER")
    p.well:SetPoint("BOTTOMLEFT", p, "BOTTOMLEFT", 4, 4)
    p.well:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -4, 4)
    p.well:SetHeight(20)
    p.wellLine = p:CreateTexture(nil, "ARTWORK")
    p.wellLine:SetHeight(1)
    p.wellLine:SetPoint("BOTTOMLEFT", p.well, "TOPLEFT", 0, 0)
    p.wellLine:SetPoint("BOTTOMRIGHT", p.well, "TOPRIGHT", 0, 0)
    p.hint = p:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    p.hint:SetPoint("LEFT", p.well, "LEFT", 8, 0)
    p.hint:SetText("Press Enter to chat")

    -- thin scrollbar on hover
    k.bar = CreateFrame("Frame", name .. "CPScrollBar", f)
    k.bar:SetWidth(3)
    k.bar:SetPoint("TOPLEFT", f, "TOPRIGHT", 2, -2)
    k.bar:SetPoint("BOTTOMLEFT", f, "BOTTOMRIGHT", 2, 2)
    k.bar.track = k.bar:CreateTexture(nil, "BACKGROUND")
    k.bar.track:SetAllPoints(k.bar)
    k.bar.thumb = k.bar:CreateTexture(nil, "ARTWORK")
    k.bar.thumb:SetWidth(3)
    k.bar:Hide()

    -- jump to latest
    k.jump = CreateFrame("Button", name .. "CPJump", f)
    k.jump:SetWidth(20)
    k.jump:SetHeight(20)
    k.jump:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 2, 0)
    k.jump.icon = k.jump:CreateTexture(nil, "ARTWORK")
    k.jump.icon:SetAllPoints(k.jump)
    k.jump:SetScript("OnClick", function()
        if f.ScrollToBottom then f:ScrollToBottom() end
        k.jump:Hide()
    end)
    k.jump:SetScript("OnEnter", function()
        if GameTooltip then
            GameTooltip:SetOwner(k.jump, "ANCHOR_LEFT")
            GameTooltip:SetText("Jump to the latest line", 1, 1, 1)
            GameTooltip:Show()
        end
    end)
    k.jump:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    k.jump:Hide()

    -- resize grip (bottom-right of the panel), shown on hover when the window is unlocked
    k.grip = CreateFrame("Button", name .. "CPGrip", p)
    k.grip:SetWidth(12)
    k.grip:SetHeight(12)
    k.grip:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -1, 1)
    k.grip.icon = k.grip:CreateTexture(nil, "OVERLAY")
    k.grip.icon:SetAllPoints(k.grip)
    k.grip:SetScript("OnMouseDown", function()
        if f.SetResizable then f:SetResizable(true) end
        if f.SetMinResize then f:SetMinResize(200, 60) end
        if f.StartSizing then f:StartSizing("BOTTOMRIGHT") end
        k.sizing = true
    end)
    k.grip:SetScript("OnMouseUp", function()
        if f.StopMovingOrSizing then f:StopMovingOrSizing() end
        k.sizing = nil
        C:Snap(f, true)
    end)
    k.grip:Hide()

    f.cpSkin = k
    table.insert(self.skinned, f)
    return k
end

-- -- Applying a theme ---------------------------------------------------------------------------

local function col(t, a) return t[1], t[2], t[3], a or 1 end

function C:ThemeSkin(k)
    local theme = self:Theme()
    local f, p = k.frame, k.panel
    local op = (tonumber(self:Get("opacity")) or 85) / 100
    if op < 0.4 then op = 0.4 elseif op > 1 then op = 1 end
    k.opacity = op

    local docked = (f == self.whisperFrame) or self:IsDocked(f)
    k.docked = docked
    local bottom = docked and self.PAD.input or self.PAD.bottom
    p:ClearAllPoints()
    p:SetPoint("TOPLEFT", f, "TOPLEFT", -self.PAD.left, self.PAD.top)
    p:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", self.PAD.right, -bottom)
    k.back:ClearAllPoints()
    k.back:SetAllPoints(p)

    -- the face: panel art (or a flat colour) at the opacity setting
    k.art = W:Art(p.face, artName("Panel", theme), { col(theme.face, 1) })
    p.face:SetTexCoord(0, 1, 0, 1)
    p.face:SetAlpha(op * ((not k.art and theme.faceAlpha) or 1))

    -- the edge: theme art, or thin flat lines
    local edged = setSlice(p.edge, p, artName("Edge", theme), theme.edgeSize, theme.edgeOut, 0)
    k.edged = edged
    for side, t in pairs(p.lines) do
        t:SetTexture(col(theme.edge, theme.edgeAlpha or 1))
        if edged then t:Hide() else t:Show() end
    end
    if theme.topLine or not edged then
        p.top:SetTexture(col(theme.top, theme.topAlpha or 0.55))
        p.top:Show()
    else
        p.top:Hide()
    end

    -- the soft shadow underneath
    if theme.shadow and setSlice(k.shadow, p, "Chat_Shadow", 16, 10 + theme.edgeOut, -4) then
        sliceAlpha(k.shadow, 0.55 + 0.45 * op)
    else
        for _, d in ipairs(SLICES) do k.shadow[d[1]]:Hide() end
    end

    if docked then p.well:Show(); p.wellLine:Show(); p.hint:Show() else p.well:Hide(); p.wellLine:Hide(); p.hint:Hide() end
    do
        p.well:SetTexture(col(theme.inset, 1))
        p.well:SetAlpha(math.min(1, op + 0.1) * ((theme.faceAlpha and 0.8) or 1))
        p.wellLine:SetTexture(col(theme.edge, (theme.edgeAlpha or 0.8)))
        if p.hint.SetFont then p.hint:SetFont("Fonts\\FRIZQT__.TTF", 10, theme.flags) end
        p.hint:SetTextColor(col(theme.muted, 0.75))
    end
    for _, b in ipairs({ self:Bar().menu, self:Bar().copy }) do
        if W:Art(b.icon, b.cpArt, nil) then
            b.icon:SetVertexColor(col(theme.muted))
            b.label:Hide()
        else
            b.label:Show()
            b.label:SetTextColor(col(theme.muted))
        end
    end

    k.bar.track:SetTexture(col(theme.edge, 0.35))
    k.bar.thumb:SetTexture(col(theme.accent, 0.85))
    if not W:Art(k.jump.icon, "Chat_Arrow", nil) then k.jump.icon:SetTexture(col(theme.accent, 0.9)) end
    k.jump.icon:SetVertexColor(1, 1, 1)
    if not W:Art(k.grip.icon, "Chat_Grip", nil) then k.grip.icon:SetTexture(col(theme.muted, 0.5)) end

    -- text: outlined (dark ink without outline on paper), 1 px line spacing, the chosen size
    if not f.cpFont and f.GetFont then
        local path, size, flags = f:GetFont()
        f.cpFont = { path or "Fonts\\ARIALN.TTF", size or 14, flags or "" }
        f.cpSpacing = f.GetSpacing and f:GetSpacing() or 0
    end
    if f.SetFont and f.cpFont then f:SetFont(f.cpFont[1], tonumber(self:Get("fontSize")) or 13, theme.flags) end
    if f.SetSpacing then f:SetSpacing(1) end
    if f.SetShadowColor then
        if theme.ink then f:SetShadowColor(0, 0, 0, 0) else f:SetShadowColor(0, 0, 0, 0.9) end
    end
    if f.SetShadowOffset then f:SetShadowOffset(1, -1) end

    -- fading text
    if f.cpFading == nil then
        f.cpFading = (f.GetFading and f:GetFading()) and true or false
        f.cpTimeVisible = f.GetTimeVisible and f:GetTimeVisible() or 120
        if f.GetFading and f:GetFading() == nil then f.cpFading = true end
    end
    local fade = self:Get("fade")
    if fade == "never" then
        if f.SetFading then f:SetFading(false) end
    else
        if f.SetFading then f:SetFading(true) end
        if f.SetTimeVisible then f:SetTimeVisible(tonumber(fade) or 20) end
    end
end

function C:SkinFrame(f)
    local k = self:SkinFor(f)
    -- the chat frame stays above its panel and shadow
    if not f.cpLevel then
        f.cpLevel = f:GetFrameLevel() or 1
        if f.cpLevel < 3 then f:SetFrameLevel(3) end
    end
    local lvl = f:GetFrameLevel()
    k.back:SetFrameLevel(lvl - 2)
    k.panel:SetFrameLevel(lvl - 1)
    k.bar:SetFrameLevel(lvl + 1)
    k.jump:SetFrameLevel(lvl + 2)
    k.grip:SetFrameLevel(lvl + 2)
    for _, s in ipairs(STOCK_TEXTURES) do suppress(getglobal(f:GetName() .. s)) end
    for _, s in ipairs(STOCK_BUTTONS) do suppress(getglobal(f:GetName() .. s)) end
    k.back:Show()
    k.panel:Show()
    self:ThemeSkin(k)
end

function C:UnskinFrame(f)
    local k = f.cpSkin
    if not k then return end
    k.back:Hide()
    k.panel:Hide()
    k.bar:Hide()
    k.jump:Hide()
    for _, s in ipairs(STOCK_TEXTURES) do unsuppress(getglobal(f:GetName() .. s)) end
    for _, s in ipairs(STOCK_BUTTONS) do unsuppress(getglobal(f:GetName() .. s)) end
    if f.cpFont and f.SetFont then f:SetFont(f.cpFont[1], f.cpFont[2], f.cpFont[3]) end
    if f.SetSpacing then f:SetSpacing(f.cpSpacing or 0) end
    if f.SetShadowColor then f:SetShadowColor(0, 0, 0, 1) end
    if f.cpFading ~= nil then
        if f.SetFading then f:SetFading(f.cpFading) end
        if f.SetTimeVisible then f:SetTimeVisible(f.cpTimeVisible or 120) end
        f.cpFading = nil
    end
    if f.cpLevel then f:SetFrameLevel(f.cpLevel); f.cpLevel = nil end
end

-- -- Tabs --------------------------------------------------------------------------------------

function C:SkinTab(tab, f)
    if not tab then return end
    if not tab.cpBg then
        tab.cpBg = tab:CreateTexture(nil, "BACKGROUND")
        tab.cpBg:SetAllPoints(tab)
        tab.cpLine = tab:CreateTexture(nil, "ARTWORK")
        tab.cpLine:SetHeight(2)
        tab.cpLine:SetPoint("BOTTOMLEFT", tab, "BOTTOMLEFT", 3, 0)
        tab.cpLine:SetPoint("BOTTOMRIGHT", tab, "BOTTOMRIGHT", -3, 0)
        tab.cpDot = tab:CreateTexture(nil, "OVERLAY")
        tab.cpDot:SetWidth(6)
        tab.cpDot:SetHeight(6)
        tab.cpDot:SetPoint("TOPRIGHT", tab, "TOPRIGHT", -3, -3)
        tab.cpOwn = { [tab.cpBg] = true, [tab.cpLine] = true, [tab.cpDot] = true }
    end
    tab.cpFrame = f
    if not tab.cpOrig then
        local fs = getglobal(tab:GetName() .. "Text") or (tab.GetFontString and tab:GetFontString())
        local o = { w = tab:GetWidth(), h = tab:GetHeight(), points = savePoints(tab), fs = fs }
        if fs then o.fsPoints = savePoints(fs) end
        if fs and fs.GetFont then o.font = { fs:GetFont() } end
        if fs and fs.GetTextColor then o.color = { fs:GetTextColor() } end
        o.click = tab:GetScript("OnClick")
        o.dragStop = tab:GetScript("OnDragStop")
        tab.cpOrig = o
        o.regions = {}
        for _, r in ipairs({ tab:GetRegions() }) do
            if r.GetObjectType and r:GetObjectType() == "Texture" and not tab.cpOwn[r] then table.insert(o.regions, r) end
        end
        local origSetAlpha = tab.SetAlpha
        tab.cpSetAlpha = function(a) origSetAlpha(tab, a) end
        tab:SetScript("OnClick", function()
            if C.LeaveWhisper then C:LeaveWhisper() end
            if C.LeaveWorld then C:LeaveWorld() end
            if o.click then o.click() end
            C:RefreshTabs()
        end)
        tab:SetScript("OnDragStop", function()
            if o.dragStop then o.dragStop() end
            -- a docked tab moves the whole dock, which hangs off its first frame
            local target = tab.cpFrame or f
            if C:IsDocked(target) then target = C:Docked()[1] or target end
            C:Snap(target)
            C:LayoutTabs()
        end)
    end
    for _, r in ipairs(tab.cpOrig.regions) do suppress(r) end
    for _, n in ipairs({ "Left", "Middle", "Right", "Flash", "HighlightLeft", "HighlightMiddle", "HighlightRight" }) do
        suppress(getglobal(tab:GetName() .. n))
    end
    -- FCF fades the tabs out a moment after the mouse leaves; ours stay with the panel (and the
    -- tab is taken off the fade list, so the fade's "finished" step never runs either)
    tab.SetAlpha = function(self)
        if UIFrameFadeRemoveFrame then UIFrameFadeRemoveFrame(self) end
    end
    tab.cpSetAlpha(self.chromeAlpha or 1)
    tab.cpBg:Show(); tab.cpLine:Show(); tab.cpDot:Show()
    tab:SetHeight(self.TAB_H)
    if tab.cpOrig.level == nil then tab.cpOrig.level = tab:GetFrameLevel() or 1 end
    if f and f.GetFrameLevel and (tab:GetFrameLevel() or 0) <= f:GetFrameLevel() then tab:SetFrameLevel(f:GetFrameLevel() + 1) end
    local fs = tab.cpOrig.fs
    if fs and fs.SetFont then fs:SetFont("Fonts\\FRIZQT__.TTF", 10, self:Theme().flags) end
    if fs then
        fs:ClearAllPoints()
        fs:SetPoint("CENTER", tab, "CENTER", 0, 1)
        local w = (fs.GetStringWidth and fs:GetStringWidth() or 30) + 20
        if w < 40 then w = 40 end
        tab:SetWidth(w)
    end
end

function C:UnskinTab(tab)
    if not tab or not tab.cpOrig then return end
    local o = tab.cpOrig
    tab.SetAlpha = nil
    for _, r in ipairs(o.regions) do unsuppress(r) end
    for _, n in ipairs({ "Left", "Middle", "Right", "Flash", "HighlightLeft", "HighlightMiddle", "HighlightRight" }) do
        unsuppress(getglobal(tab:GetName() .. n))
    end
    tab.cpBg:Hide(); tab.cpLine:Hide(); tab.cpDot:Hide()
    tab:SetScript("OnClick", o.click)
    tab:SetScript("OnDragStop", o.dragStop)
    if o.level then tab:SetFrameLevel(o.level) end
    if o.w and o.w > 0 then tab:SetWidth(o.w) end
    if o.h and o.h > 0 then tab:SetHeight(o.h) end
    loadPoints(tab, o.points)
    local fs = o.fs
    if fs then
        if o.font and o.font[1] and fs.SetFont then fs:SetFont(o.font[1], o.font[2], o.font[3]) end
        if o.color and o.color[1] then fs:SetTextColor(o.color[1], o.color[2], o.color[3]) end
        loadPoints(fs, o.fsPoints)
    end
    tab.cpOrig = nil
    tab.cpUnread, tab.cpMention = nil, nil
end

-- Unread dot (replaces the stock tab flash).
function C:MarkUnread(f, mention)
    local tab = tabOf(f)
    if not tab then return end
    if f == self:Selected() and f:IsVisible() then return end
    tab.cpUnread = true
    if mention then tab.cpMention = true end
    self:RefreshTabs()
end

function C:StyleTab(tab, selected, theme)
    if not tab or not tab.cpBg then return end
    theme = theme or self:Theme()
    if not W:Art(tab.cpBg, artName("Tab", theme), { col(theme.tab, 1) }) then
        tab.cpBg:SetTexture(col(theme.tab, theme.faceAlpha or 1))
    end
    local op = (tonumber(self:Get("opacity")) or 85) / 100
    tab.cpBg:SetAlpha((selected and 1 or 0.72) * math.max(op, 0.55))
    tab.cpBg:SetVertexColor(selected and 1 or 0.82, selected and 1 or 0.82, selected and 1 or 0.82)
    tab.cpLine:SetTexture(col(theme.accent, 1))
    tab.cpLine:SetAlpha(selected and 1 or 0)
    if not W:Art(tab.cpDot, "Chat_Dot", nil) then tab.cpDot:SetTexture(1, 1, 1, 1) end
    if tab.cpMention then tab.cpDot:SetVertexColor(1, 0.62, 0.18) else tab.cpDot:SetVertexColor(col(theme.accent)) end
    tab.cpDot:SetAlpha((tab.cpUnread and not selected) and 1 or 0)
    local fs = tab.cpOrig and tab.cpOrig.fs or tab.label
    if fs then
        if selected then fs:SetTextColor(col(theme.text)) else fs:SetTextColor(col(theme.muted)) end
    end
end

function C:RefreshTabs()
    if not self.active then return end
    local theme = self:Theme()
    local sel = self:Selected()
    for i = 1, (NUM_CHAT_WINDOWS or 7) do
        local f = getglobal("ChatFrame" .. i)
        local tab = tabOf(f)
        if tab and tab.cpBg then
            local selected
            if self:IsDocked(f) then selected = (f == sel) else selected = not self.whisperView and not self.worldView end
            if selected then tab.cpUnread, tab.cpMention = nil, nil end
            self:StyleTab(tab, selected, theme)
        end
    end
    if self.StyleWhisperTabs then self:StyleWhisperTabs(theme) end
    if self.StyleWorldTab then self:StyleWorldTab(theme) end
end

-- Tabs sit on top of a thick frame (Wildwood's carved wood) rather than under it.
function C:TabLift()
    local out = self:Theme().edgeOut or 0
    return math.max(0, out - 2)
end

-- Docked tabs in a row on ChatFrame1's panel; an undocked frame's tab sits on its own panel.
function C:LayoutTabs()
    if not self.active then return end
    local main = ChatFrame1 and ChatFrame1.cpSkin
    if not main then return end
    local prev
    for _, f in ipairs(self:Docked()) do
        local tab = tabOf(f)
        if tab and tab.cpOrig then
            tab:ClearAllPoints()
            if prev then
                tab:SetPoint("BOTTOMLEFT", prev, "BOTTOMRIGHT", 1, 0)
            else
                tab:SetPoint("BOTTOMLEFT", self:Bar(), "BOTTOMLEFT", 2, 0)
            end
            prev = tab
        end
    end
    for _, f in ipairs(self.skinned) do
        local tab = tabOf(f)
        if f ~= ChatFrame1 and tab and tab.cpOrig and not self:IsDocked(f) and f.cpSkin then
            tab:ClearAllPoints()
            tab:SetPoint("BOTTOMLEFT", f.cpSkin.panel, "TOPLEFT", 2, self:TabLift())
        end
    end
    self.lastTab = prev
    if self.LayoutWhisperTabs then self:LayoutWhisperTabs() end
    if self.LayoutWorldTab then self:LayoutWorldTab() end
end

-- -- The input line -------------------------------------------------------------------------------

function C:SkinEditBox()
    local eb = ChatFrameEditBox
    local main = ChatFrame1 and ChatFrame1.cpSkin
    if not eb or not main then return end
    local theme = self:Theme()
    if not eb.cpOrig then
        local o = { points = savePoints(eb), h = eb:GetHeight(), regions = {} }
        if eb.GetFont then o.font = { eb:GetFont() } end
        eb.cpBg = eb:CreateTexture(nil, "BACKGROUND")
        eb.cpBg:SetAllPoints(eb)
        eb.cpEdge = eb:CreateTexture(nil, "BORDER")
        eb.cpEdge:SetHeight(1)
        eb.cpEdge:SetPoint("TOPLEFT", eb, "TOPLEFT", 0, 0)
        eb.cpEdge:SetPoint("TOPRIGHT", eb, "TOPRIGHT", 0, 0)
        local own = { [eb.cpBg] = true, [eb.cpEdge] = true }
        for _, r in ipairs({ eb:GetRegions() }) do
            if r.GetObjectType and r:GetObjectType() == "Texture" and not own[r] then table.insert(o.regions, r) end
        end
        o.header = getglobal(eb:GetName() .. "Header")
        if o.header and o.header.GetFont then o.headerFont = { o.header:GetFont() } end
        eb.cpOrig = o
    end
    for _, r in ipairs(eb.cpOrig.regions) do suppress(r) end
    eb.cpBg:Show()
    eb.cpEdge:Show()
    eb.cpBg:SetTexture(col(theme.inset, 1))
    eb.cpBg:SetAlpha(math.min(1, (main.opacity or 0.85) + 0.15))
    eb.cpEdge:SetTexture(col(theme.accent, 0.55))
    eb:ClearAllPoints()
    eb:SetPoint("BOTTOMLEFT", ChatFrame1, "BOTTOMLEFT", -self.PAD.left + 4, -self.PAD.input + 4)
    eb:SetPoint("BOTTOMRIGHT", ChatFrame1, "BOTTOMRIGHT", self.PAD.right - 4, -self.PAD.input + 4)
    eb:SetHeight(20)
    local size = tonumber(self:Get("fontSize")) or 13
    if eb.SetFont and eb.cpOrig.font then eb:SetFont(eb.cpOrig.font[1] or "Fonts\\ARIALN.TTF", size, theme.flags) end
    if eb.SetTextColor then eb:SetTextColor(col(theme.text)) end
    local h = eb.cpOrig.header
    if h and h.SetFont then h:SetFont("Fonts\\FRIZQT__.TTF", size - 2, theme.flags) end
    self:ColourHeader(eb)
end

function C:UnskinEditBox()
    local eb = ChatFrameEditBox
    if not eb or not eb.cpOrig then return end
    local o = eb.cpOrig
    for _, r in ipairs(o.regions) do unsuppress(r) end
    eb.cpBg:Hide()
    eb.cpEdge:Hide()
    loadPoints(eb, o.points)
    if o.h and o.h > 0 then eb:SetHeight(o.h) end
    if o.font and o.font[1] and eb.SetFont then eb:SetFont(o.font[1], o.font[2], o.font[3]) end
    if o.header and o.headerFont and o.headerFont[1] then o.header:SetFont(o.headerFont[1], o.headerFont[2], o.headerFont[3]) end
    eb.cpOrig = nil
    if ChatEdit_UpdateHeader and eb:IsShown() then ChatEdit_UpdateHeader(eb) end
end

-- "Say:", "Guild:", "2. Trade:" in the colour of the channel being typed into.
function C:ColourHeader(eb)
    if not self.active or not eb or not eb.cpOrig then return end
    local h = eb.cpOrig.header
    if not h or not ChatTypeInfo then return end
    local t = eb.chatType or "SAY"
    local info = ChatTypeInfo[t]
    if t == "CHANNEL" and eb.channelTarget then info = ChatTypeInfo["CHANNEL" .. eb.channelTarget] or info end
    if info then
        local r, g, b = info.r or 1, info.g or 1, info.b or 1
        if self.inked then r, g, b = C.InkRGB(r, g, b) end
        h:SetTextColor(r, g, b)
        if eb.SetTextColor then eb:SetTextColor(r, g, b) end
    end
end

-- -- Menu on the tab bar -------------------------------------------------------------------------

function C:OpenMenu(anchor)
    local UI = W.UI
    if not UI or not UI.Menu then return end
    local f = self:Selected() or ChatFrame1
    local items = { { text = "Chat", title = true } }
    if ChatFrame_OpenMenu or ChatMenu then
        table.insert(items, { text = "Emotes and speech", func = function()
            if ChatFrame_OpenMenu then ChatFrame_OpenMenu() elseif ChatMenu then ChatMenu:Show() end
            if ChatMenu then
                ChatMenu:ClearAllPoints()
                ChatMenu:SetPoint("BOTTOMRIGHT", anchor, "TOPRIGHT", 0, 2)
            end
        end })
    end
    table.insert(items, { text = "Copy chat", func = function() C:OpenCopy((self.whisperView or self.worldView) and nil or f) end })
    if not self.whisperView and not self.worldView then
        table.insert(items, { text = "Highlight my name in this tab", checked = self:MentionsOn(f), func = function()
            local s = W:Settings(C.ID)
            if type(s.mentionOff) ~= "table" then s.mentionOff = {} end
            local key = f:GetName()
            if s.mentionOff[key] then s.mentionOff[key] = nil else s.mentionOff[key] = true end
        end })
    end
    table.insert(items, { text = "Theme", title = true })
    for _, key in ipairs(self.THEME_ORDER) do
        local k = key
        table.insert(items, { text = self.THEMES[k].label, checked = (self:Get("theme") == k), func = function() C:SetOption("theme", k) end })
    end
    table.insert(items, { text = "All chat settings...", func = function() C:OpenSettings() end })
    self.menu = UI.Menu(anchor, items)
    if self.menu then
        self.menu:ClearAllPoints()
        self.menu:SetPoint("BOTTOMRIGHT", anchor, "TOPRIGHT", 0, 2)
    end
    return self.menu
end

-- -- Moving and resizing: snap to a 4 px grid and the screen edges ------------------------------

function C:Snap(f, sized)
    if not f or not f.GetLeft or not self.active then return end
    local l, b = f:GetLeft(), f:GetBottom()
    if not l or not b then return end
    local w, h = f:GetWidth() or 0, f:GetHeight() or 0
    local sw = UIParent and UIParent:GetWidth() or 1024
    local sh = UIParent and UIParent:GetHeight() or 768
    local function grid(v) return floor(v / 4 + 0.5) * 4 end
    if sized then w, h = grid(w), grid(h) end
    l, b = grid(l), grid(b)
    local edge, near = 12, 16
    local bottomPad = (f == ChatFrame1) and self.PAD.input or self.PAD.bottom
    if l - self.PAD.left < near then l = self.PAD.left + 4 end
    if b - bottomPad < near then b = bottomPad + 4 end
    if sw - (l + w + self.PAD.right) < near then l = sw - w - self.PAD.right - 4 end
    if sh - (b + h + self.PAD.top + self.TAB_H) < near then b = sh - h - self.PAD.top - self.TAB_H - 4 end
    f:ClearAllPoints()
    f:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", l, b)
    if w > 0 and h > 0 then f:SetWidth(w); f:SetHeight(h) end
    if f.SetUserPlaced then f:SetUserPlaced(true) end
    self.snapped = { l, b, w, h, edge }
    return l, b
end

-- The default chat frame moves up to make room for the input line (unless the player, Move
-- Anything or an interface pack placed it).
function C:Raise(on)
    local f = ChatFrame1
    if not f then return end
    if on then
        if self.raised then return end
        if f.IsUserPlaced and f:IsUserPlaced() then return end
        if ClassicPlusUI and ClassicPlusUI.IsAdded and ClassicPlusUI:IsAdded("repack") then return end
        if type(ClassicPlus_UI) == "table" and type(ClassicPlus_UI.pos) == "table" and ClassicPlus_UI.pos.ChatFrame1 then return end
        local p, rel, rp, x, y = f:GetPoint(1)
        if p ~= "BOTTOMLEFT" or (f.GetNumPoints and f:GetNumPoints() > 1) or not y or y > 200 then return end
        self.raised = { p, rel, rp, x, y }
        f:ClearAllPoints()
        f:SetPoint(p, rel, rp, x, y + self.RAISE)
    elseif self.raised then
        local r = self.raised
        self.raised = nil
        local p, _, _, x, y = f:GetPoint(1)
        -- only put it back if it is still where we left it
        if p == r[1] and x == r[4] and y == r[5] + self.RAISE then
            f:ClearAllPoints()
            f:SetPoint(r[1], r[2], r[3], r[4], r[5])
        end
    end
end

-- -- Hooks into the stock chat code ---------------------------------------------------------------

local hooked = false
function C:HookStock()
    if hooked then return end
    hooked = true
    if type(FCF_FlashTab) == "function" then
        local orig = FCF_FlashTab
        FCF_FlashTab = function(a1, a2)
            if C.active then
                local f = this
                if f and f.GetName and tabOf(f) then C:MarkUnread(f) end
                return
            end
            return orig(a1, a2)
        end
    end
    if type(FCF_DockUpdate) == "function" then
        local orig = FCF_DockUpdate
        FCF_DockUpdate = function(a1, a2)
            local r = orig(a1, a2)
            if C.active and C.skinOn then C:Skin() end
            return r
        end
    end
    -- the stock code re-places the default chat frame when action bars appear; keep it raised
    if type(FCF_UpdateDockPosition) == "function" then
        local orig = FCF_UpdateDockPosition
        FCF_UpdateDockPosition = function(a1, a2)
            local r = orig(a1, a2)
            local f = ChatFrame1
            if C.active and C.raised and f and not (f.IsUserPlaced and f:IsUserPlaced()) then
                local p, rel, rp, x, y = f:GetPoint(1)
                if p == "BOTTOMLEFT" and y then
                    C.raised = { p, rel, rp, x, y }
                    f:SetPoint(p, rel, rp, x, y + C.RAISE)
                end
            end
            return r
        end
    end
    if type(ChatEdit_UpdateHeader) == "function" then
        local orig = ChatEdit_UpdateHeader
        ChatEdit_UpdateHeader = function(eb, a2)
            local r = orig(eb, a2)
            C:ColourHeader(eb)
            return r
        end
    end
end

-- -- Apply / undo ----------------------------------------------------------------------------------

function C:SkinAllTabs()
    for i = 1, (NUM_CHAT_WINDOWS or 7) do
        local f = getglobal("ChatFrame" .. i)
        local tab = tabOf(f)
        if f and tab and (f:IsShown() or tab:IsShown() or self:IsDocked(f)) then self:SkinTab(tab, f) end
    end
end

function C:Skin()
    self:HookStock()
    for i = 1, (NUM_CHAT_WINDOWS or 7) do
        local f = getglobal("ChatFrame" .. i)
        if f then self:SkinFrame(f) end
    end
    self:SkinAllTabs()
    suppress(ChatFrameMenuButton)
    self:SkinEditBox()
    local bar = self:Bar()
    bar:ClearAllPoints()
    bar:SetPoint("BOTTOMRIGHT", ChatFrame1, "TOPRIGHT", self.PAD.right, self.PAD.top + self:TabLift())
    bar:SetPoint("BOTTOMLEFT", ChatFrame1, "TOPLEFT", -self.PAD.left, self.PAD.top + self:TabLift())
    bar:SetFrameLevel((ChatFrame1:GetFrameLevel() or 3) + 1)
    bar:Show()
    self:LayoutTabs()
    self:RefreshTabs()
    if self.entered then self:Raise(true) end
    self.skinOn = true
end

function C:Unskin()
    if not self.skinOn then return end
    self.skinOn = nil
    for _, f in ipairs(self.skinned) do self:UnskinFrame(f) end
    for i = 1, (NUM_CHAT_WINDOWS or 7) do self:UnskinTab(tabOf(getglobal("ChatFrame" .. i))) end
    unsuppress(ChatFrameMenuButton)
    if self.bar then self.bar:Hide() end
    self:UnskinEditBox()
    self:Raise(false)
    if FCF_DockUpdate then FCF_DockUpdate() end
end

function C:ApplySkin()
    -- an interface theme can ask for a chat theme (ClassicPlusUI.chatTheme, or C:FollowTheme)
    local want = ClassicPlusUI and ClassicPlusUI.chatTheme
    if want and self.THEMES[want] then
        local s = W:Settings(self.ID)
        if s.followed ~= want then s.followed = want; s.theme = want end
    end
    if self.active then self:Skin() else self:Unskin() end
end

function C:FollowTheme(key)
    if not self.THEMES[key] then return end
    local s = W:Settings(self.ID)
    s.theme = key
    if W.Refresh then W:Refresh(self.ID) end
end

function C:OnEnterWorld()
    self.entered = true
    if ClassicPlusUI and ClassicPlusUI.Register then ClassicPlusUI:Register("ChatFrame1", "Chat") end
end

-- -- Per-frame upkeep: scrollbar, jump arrow, grip, fade, tab styles --------------------------------

local function over(fr)
    return fr and fr:IsVisible() and MouseIsOver and MouseIsOver(fr) and true or false
end
C.Over = over

C.chromeAlpha = 1
C.lastActivity = 0

function C:Hovered()
    for _, f in ipairs(self.skinned) do
        local k = f.cpSkin
        if k and f:IsVisible() and (over(k.panel) or over(tabOf(f)) or k.sizing) then return true end
    end
    if self.whisperFrame and over(self.whisperFrame) then return true end
    if self.worldFrame and over(self.worldFrame) then return true end
    return false
end

function C:UpdateScroll(f)
    local k = f.cpSkin
    if not k then return end
    local atBottom = C.AtBottom(f)
    if atBottom then k.jump:Hide() elseif f:IsVisible() then k.jump:Show() end
    local hovered = over(k.panel)
    local n = f.GetNumMessages and f:GetNumMessages() or 0
    local size = tonumber(self:Get("fontSize")) or 13
    local fit = floor((f:GetHeight() or 100) / (size + 1))
    if hovered and n > fit and fit > 0 then
        local off = (f.GetCurrentScroll and f:GetCurrentScroll()) or 0
        local h = k.bar:GetHeight() or (f:GetHeight() or 100)
        local th = math.max(10, h * fit / n)
        local range = math.max(1, n - fit)
        local pos = (h - th) * (1 - math.min(off, range) / range)
        k.bar.thumb:SetHeight(th)
        k.bar.thumb:ClearAllPoints()
        k.bar.thumb:SetPoint("TOPLEFT", k.bar, "TOPLEFT", 0, -pos)
        k.bar:Show()
    else
        k.bar:Hide()
    end
    local locked = f.isLocked or (FCF_Get_ChatLocked and FCF_Get_ChatLocked())
    if (hovered or k.sizing) and not locked then k.grip:Show() else k.grip:Hide() end
end

function C:SetChrome(a)
    self.chromeAlpha = a
    for _, f in ipairs(self.skinned) do
        local k = f.cpSkin
        if k then
            k.panel:SetAlpha(a)
            k.back:SetAlpha(a)
        end
        local tab = tabOf(f)
        if tab and tab.cpSetAlpha and tab.cpOrig then tab.cpSetAlpha(a) end
    end
    if self.bar then self.bar:SetAlpha(a) end
    if self.SetWhisperChrome then self:SetWhisperChrome(a) end
end

function C:Update(elapsed)
    self.ctxEvent, self.ctxFrame = nil, nil       -- a stale chat context never outlives a frame
    if not self.active or not self.skinOn then return end
    local t = now()
    local typing = ChatFrameEditBox and ChatFrameEditBox:IsVisible()
    if typing or self:Hovered() then self.lastActivity = t end
    for _, f in ipairs(self.skinned) do
        if f:IsVisible() then self:UpdateScroll(f) end
    end
    local fade = self:Get("fade")
    local target = 1
    if fade ~= "never" and t - (self.lastActivity or 0) > (tonumber(fade) or 20) then target = 0 end
    local a = self.chromeAlpha or 1
    if a ~= target then
        local step = (elapsed or 0.05) * ((target > a) and 5 or 0.8)
        if target > a then a = math.min(target, a + step) else a = math.max(target, a - step) end
        self:SetChrome(a)
    end
    self.tick = (self.tick or 0) + (elapsed or 0)
    if self.tick > 0.25 then
        self.tick = 0
        local sel = self:Selected()
        if sel ~= self.lastSelected then
            self.lastSelected = sel
            self:RefreshTabs()
        end
    end
end

local upkeep = CreateFrame("Frame", "CPChatUpkeep", UIParent)
upkeep:SetScript("OnUpdate", function() C:Update(arg1) end)
