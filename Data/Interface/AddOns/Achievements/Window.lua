--[[
    Window.lua  -  the Achievements window (Y, /ach).

    Categories on the left (Summary first), the achievements of the chosen one on the right: icon,
    name, description, a points shield, the date earned or a progress bar ("Quests: 312/1000").
    A search box searches every category; tabs along the bottom filter All / Earned / Not earned /
    Almost there. The Summary page shows your points, the latest achievements, overall progress
    and a bar per category. Comparing (right-click a player > Compare Achievements, /ach compare
    Name, or the button with a player targeted) adds the other player's dates beside yours.

    Rows: hover for the steps, Shift-click to link in chat, right-click for Track / Link / Feature.
    Each category has a crest (Ach_Cat_*) on its button and its summary tile; tiles open the
    category. With nothing earned, the Summary shows an illustrated empty state (Ach_Empty).
    Art (tools/gen_achievements_art.py) has flat fallbacks, so the window works without it: stock
    icons for the crests, tooltip-border backdrops for the tiles.
]]--

local W = WenillaCore
local UI = W.UI
local A = Achievements
local ID = "Achievements"

local strfind, strsub, strlower, strlen = string.find, string.sub, string.lower, string.len
local tinsert, getn = table.insert, table.getn
local floor = math.floor

local WIN_W, WIN_H = 660, 470
local LEFT_W = 176
local RIGHT_X = LEFT_W + 18
local RIGHT_W = WIN_W - RIGHT_X - 10
local ROW_H = 50
local LIST_ROWS = 7
local CAT_H = 26
local TILE_H = 50
local SOLID = { 0.045, 0.048, 0.058, 0.97 }    -- opaque fill under the art (nothing shows through)

A.view = { cat = "summary", filter = "all", search = "" }
local win, list, summary, catButtons, filterTabs, searchBox, header, note, cmpButton, pointsText, pointsLabel

local FILTERS = {
    { key = "all", label = "All" }, { key = "earned", label = "Earned" },
    { key = "unearned", label = "Not earned" }, { key = "close", label = "Almost there" },
}

local function art(tex, name, fallback) return W:Art(tex, name, fallback) end

local function gold() return UI.ACCENT[1], UI.ACCENT[2], UI.ACCENT[3] end

-- Category crests (art); the stock icon from Data.lua is the fallback.
local CRESTS = {
    summary = "Ach_ShieldSmall",
    general = "Ach_Cat_General", quests = "Ach_Cat_Quests", exploration = "Ach_Cat_Exploration",
    dungeons = "Ach_Cat_Dungeons", raids = "Ach_Cat_Raids", professions = "Ach_Cat_Professions",
    reputation = "Ach_Cat_Reputation", pvp = "Ach_Cat_PvP", feats = "Ach_Cat_Feats",
}
A.CRESTS = CRESTS

-- Put a category's crest on tex, or its stock icon. Returns true when the crest loaded.
local function setCrest(tex, key, icon)
    if CRESTS[key] and art(tex, CRESTS[key], nil) then
        tex:SetTexCoord(0, 1, 0, 1)
        return true
    end
    tex:SetTexture(icon)
    tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    return false
end

-- An opaque face under a frame's art, inset from its border.
local function solidFill(f, inset, c)
    local t = f:CreateTexture(nil, "BACKGROUND")
    t:SetPoint("TOPLEFT", f, "TOPLEFT", inset, -inset)
    t:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -inset, inset)
    c = c or SOLID
    t:SetTexture(c[1], c[2], c[3], c[4])
    return t
end

local BORDER = {
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

-- A bordered box: the tooltip border in muted gold over an opaque slate face.
local function borderBox(f)
    f:SetBackdrop(BORDER)
    f.backdropInfo = BORDER
    f:SetBackdropColor(SOLID[1], SOLID[2], SOLID[3], 0.98)
    f:SetBackdropBorderColor(0.62, 0.52, 0.28, 1)
end

-- -- Tooltip ----------------------------------------------------------------------------------

function A.ShowTooltip(owner, a)
    if not (GameTooltip and a) then return end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    local done = A.earned[a.id]
    GameTooltip:SetText(a.n, done and 1 or 0.9, done and 0.82 or 0.9, done and 0 or 0.9)
    GameTooltip:AddLine(a.d, 1, 1, 1, 1)
    if a.p and a.p > 0 then
        GameTooltip:AddLine(a.p .. " points", 0.62, 0.64, 0.70)
    else
        GameTooltip:AddLine("Feat of Strength (no points)", 0.62, 0.64, 0.70)
    end
    if a.rf then
        local rf = A.realmFirsts[a.id]
        if rf then
            GameTooltip:AddLine("Claimed by " .. rf.name .. (rf.date and rf.date > 0 and (" on " .. A.Date(rf.date)) or "") .. ".", 1, 0.82, 0)
        else
            GameTooltip:AddLine("Not yet claimed on this realm.", 0.5, 0.9, 0.5)
        end
    end
    if a.cr then
        GameTooltip:AddLine(" ")
        for _, c in ipairs(a.cr) do
            local label = c.label
            if (not label or label == "") and c.meta and A.byId[c.meta] then label = A.byId[c.meta].n end
            if A.StepDone(c) or done then
                GameTooltip:AddLine("  " .. label, 0.35, 0.95, 0.40)
            else
                GameTooltip:AddLine("  " .. label, 0.55, 0.56, 0.60)
            end
        end
    end
    local text = not done and A.ProgressText(a)
    if text then GameTooltip:AddLine(text, 0.85, 0.85, 0.85) end
    if done then GameTooltip:AddLine("Earned " .. A.Date(done) .. ".", 0.35, 0.95, 0.40) end
    if A.compare then
        local t = A.compare.earned[a.id]
        GameTooltip:AddLine(A.compare.name .. ": " .. (t and ("earned " .. A.Date(t)) or "not earned"), 0.6, 0.75, 1)
    end
    GameTooltip:AddLine("Shift-click to link in chat. Right-click for more.", 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

-- -- Row menu ---------------------------------------------------------------------------------

function A.RowMenu(anchor, a)
    local items = { { text = a.n, title = true } }
    if not A.earned[a.id] then
        if A.IsTracked(a.id) then
            tinsert(items, { text = "Stop tracking", func = function() A.Untrack(a.id) end })
        else
            tinsert(items, { text = "Track", func = function() A.Track(a.id) end,
                disabled = getn(A.tracked) >= A.MAX_TRACKED })
        end
    else
        tinsert(items, { text = "Feature on your profile", checked = (A.Char().featured == a.id),
            func = function() A.SetFeatured(a.id) end })
    end
    tinsert(items, { text = "Link in chat", func = function() A.Link(a.id) end })
    UI.Menu(anchor, items)
end

-- -- Building ---------------------------------------------------------------------------------

local function catButton(parent, i, key, label, icon)
    local b = CreateFrame("Button", "Achievements_Cat" .. i, parent)
    b:SetWidth(LEFT_W)
    b:SetHeight(CAT_H)
    b.key = key
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints(b)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.crest = setCrest(b.icon, key, icon)
    local size = b.crest and 22 or 18
    b.icon:SetWidth(size)
    b.icon:SetHeight(size)
    b.icon:SetPoint("LEFT", b, "LEFT", b.crest and 4 or 6, 0)
    b.label = UI.Label(b, 11, { 0.92, 0.92, 0.95 }, "OUTLINE")
    b.label:SetPoint("LEFT", b.icon, "RIGHT", 6, 0)
    b.label:SetText(label)
    b.count = UI.Label(b, 9, UI.MUTED)
    b.count:SetPoint("RIGHT", b, "RIGHT", -6, 0)
    b.count:SetJustifyH("RIGHT")
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(b)
    hl:SetTexture(1, 0.82, 0, 0.08)
    b:SetScript("OnClick", function() A.ShowCategory(b.key) end)
    function b:Paint(selected)
        if selected then
            if not art(self.bg, "Ach_TabSel", nil) then self.bg:SetTexture(0.20, 0.17, 0.08, 0.95) end
            self.label:SetTextColor(gold())
        else
            if not art(self.bg, "Ach_Tab", nil) then self.bg:SetTexture(0.10, 0.105, 0.125, 0.92) end
            self.label:SetTextColor(0.92, 0.92, 0.95)
        end
    end
    return b
end

local function buildRow(row, i)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -1)
    row.bg:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 1)
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(row.bg)
    hl:SetTexture(1, 0.82, 0, 0.07)
    row.iconBox = UI.IconBox(row, 38)
    row.iconBox:SetPoint("LEFT", row, "LEFT", 6, 0)
    row.icon = row.iconBox.icon
    row.name = UI.Label(row, 12, { 1, 1, 1 }, "OUTLINE")
    row.name:SetPoint("TOPLEFT", row, "TOPLEFT", 52, -6)
    row.name:SetWidth(RIGHT_W - 160)
    row.desc = UI.Label(row, 10, UI.MUTED)
    row.desc:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -2)
    row.desc:SetWidth(RIGHT_W - 160)
    row.desc:SetHeight(24)
    row.desc:SetJustifyV("TOP")
    row.bar = UI.Bar(row, { width = 190, height = 11 })
    row.bar:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 52, 5)
    row.bar.left:SetText("")
    UI.Font(row.bar.right, 9, "OUTLINE")
    row.bar.right:ClearAllPoints()
    row.bar.right:SetPoint("CENTER", row.bar, "CENTER", 0, 0)
    row.shield = row:CreateTexture(nil, "ARTWORK")
    row.shield:SetWidth(30)
    row.shield:SetHeight(30)
    row.shield:SetPoint("TOPRIGHT", row, "TOPRIGHT", -14, -4)
    row.points = UI.Label(row, 11, { 1, 1, 1 }, "OUTLINE", "OVERLAY")
    row.points:SetPoint("CENTER", row.shield, "CENTER", 0, 1)
    row.points:SetJustifyH("CENTER")
    row.date = UI.Label(row, 9, UI.MUTED)
    row.date:SetPoint("TOPRIGHT", row, "TOPRIGHT", -6, -36)
    row.date:SetJustifyH("RIGHT")
    row.other = UI.Label(row, 9, { 0.6, 0.75, 1 })
    row.other:SetPoint("RIGHT", row.shield, "LEFT", -8, -4)
    row.other:SetJustifyH("RIGHT")
    row.track = row:CreateTexture(nil, "OVERLAY")
    row.track:SetWidth(14)
    row.track:SetHeight(14)
    row.track:SetPoint("TOPLEFT", row.iconBox, "TOPLEFT", -4, 4)
    row.track:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
    row:SetScript("OnClick", function()
        local a = row.item
        if not a then return end
        if arg1 == "RightButton" then
            A.RowMenu(row, a)
        elseif IsShiftKeyDown and IsShiftKeyDown() then
            A.Link(a.id)
        elseif IsControlKeyDown and IsControlKeyDown() then
            if A.IsTracked(a.id) then A.Untrack(a.id) else A.Track(a.id) end
        end
    end)
    row:SetScript("OnEnter", function() if row.item then A.ShowTooltip(row, row.item) end end)
    row:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    setglobal("Achievements_Row" .. i, row)
end

local function updateRow(row, a)
    local done = A.earned[a.id]
    if not art(row.bg, done and "Ach_RowEarned" or "Ach_Row", nil) then
        if done then row.bg:SetTexture(0.16, 0.135, 0.07, 0.92) else row.bg:SetTexture(0.09, 0.095, 0.11, 0.92) end
    end
    row.icon:SetTexture(a.i)
    if done then
        row.icon:SetVertexColor(1, 1, 1)
        row.iconBox.edge:SetTexture(0.75, 0.60, 0.22, 1)
        row.name:SetTextColor(gold())
    else
        row.icon:SetVertexColor(0.45, 0.45, 0.48)
        row.iconBox.edge:SetTexture(0.35, 0.35, 0.38, 1)
        row.name:SetTextColor(0.92, 0.92, 0.95)
    end
    row.name:SetText(a.n)
    row.desc:SetText(a.d)
    -- points shield (feats show none)
    if a.p and a.p > 0 then
        if not art(row.shield, done and "Ach_ShieldSmall" or "Ach_ShieldSmallGrey", nil) then
            if done then row.shield:SetTexture(0.55, 0.42, 0.10, 1) else row.shield:SetTexture(0.25, 0.26, 0.30, 1) end
        end
        row.shield:Show()
        row.points:SetText(a.p)
        if done then row.points:SetTextColor(1, 1, 1) else row.points:SetTextColor(0.7, 0.7, 0.72) end
    else
        row.shield:Hide()
        row.points:SetText("")
    end
    -- date, realm first, or progress
    local text = ""
    if done then
        text = A.Date(done)
    elseif a.rf then
        local rf = A.realmFirsts[a.id]
        text = rf and ("Claimed by " .. rf.name) or "Unclaimed"
    end
    row.date:SetText(text)
    local v, g = A.Progress(a)
    if v and not done then
        row.bar:SetFraction(g > 0 and v / g or 0)
        row.bar:SetColor(0.22, 0.62, 0.20)
        row.bar.right:SetText(A.ProgressText(a))
        row.bar:Show()
        row.desc:SetHeight(12)
    else
        row.bar:Hide()
        row.desc:SetHeight(24)
    end
    if A.compare then
        local t = A.compare.earned[a.id]
        row.other:SetText(A.compare.name .. ": " .. (t and A.Date(t) or "-"))
        row.other:Show()
    else
        row.other:Hide()
    end
    if A.IsTracked(a.id) then row.track:Show() else row.track:Hide() end
end

local function buildSummary(parent)
    local s = CreateFrame("Frame", "Achievements_Summary", parent)
    s:SetAllPoints(parent)
    s.recentTitle = UI.Label(s, 11, UI.ACCENT, "OUTLINE")
    s.recentTitle:SetPoint("TOPLEFT", s, "TOPLEFT", 8, -8)
    s.recentTitle:SetText("Recent achievements")
    s.tiles = {}
    local tileW = floor((RIGHT_W - 16 - 3 * 6) / 4)
    for i = 1, 4 do
        local t = CreateFrame("Button", "Achievements_Recent" .. i, s)
        t:SetWidth(tileW)
        t:SetHeight(48)
        t:SetPoint("TOPLEFT", s, "TOPLEFT", 8 + (i - 1) * (tileW + 6), -26)
        UI.Skin(t, "raised")
        t.iconBox = UI.IconBox(t, 30)
        t.iconBox:SetPoint("LEFT", t, "LEFT", 6, 0)
        t.name = UI.Label(t, 10, { 1, 1, 1 }, "OUTLINE")
        t.name:SetPoint("TOPLEFT", t.iconBox, "TOPRIGHT", 6, -1)
        t.name:SetWidth(tileW - 46)
        t.name:SetHeight(24)
        t.name:SetJustifyV("TOP")
        t.date = UI.Label(t, 9, UI.MUTED)
        t.date:SetPoint("BOTTOMLEFT", t.iconBox, "BOTTOMRIGHT", 6, 0)
        t:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        t:SetScript("OnEnter", function() if t.a then A.ShowTooltip(t, t.a) end end)
        t:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
        t:SetScript("OnClick", function()
            if not t.a then return end
            if IsShiftKeyDown and IsShiftKeyDown() then A.Link(t.a.id) else A.ShowAchievement(t.a.id) end
        end)
        s.tiles[i] = t
    end
    -- nothing earned yet: an illustration and two lines in a bordered box
    local box = CreateFrame("Frame", "Achievements_RecentEmpty", s)
    box:SetPoint("TOPLEFT", s, "TOPLEFT", 8, -24)
    box:SetWidth(RIGHT_W - 16)
    box:SetHeight(64)
    borderBox(box)
    local group = CreateFrame("Frame", nil, box)
    group:SetWidth(56 + 10 + 300)
    group:SetHeight(56)
    group:SetPoint("CENTER", box, "CENTER", 0, 0)
    box.art = group:CreateTexture(nil, "ARTWORK")
    box.art:SetWidth(56)
    box.art:SetHeight(56)
    box.art:SetPoint("LEFT", group, "LEFT", 0, 0)
    if not art(box.art, "Ach_Empty", nil) then
        -- flat fallback: a stock shield, dimmed (unlit)
        box.art:SetTexture("Interface\\Icons\\INV_Shield_05")
        box.art:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        box.art:SetWidth(40)
        box.art:SetHeight(40)
        box.art:SetPoint("LEFT", group, "LEFT", 8, 0)
        box.art:SetVertexColor(0.5, 0.5, 0.55)
    end
    box.title = UI.Label(group, 12, UI.ACCENT, "OUTLINE")
    box.title:SetPoint("TOPLEFT", group, "TOPLEFT", 66, -8)
    box.title:SetText("Your story starts here")
    s.none = UI.Label(group, 10, UI.MUTED)
    s.none:SetPoint("TOPLEFT", box.title, "BOTTOMLEFT", 0, -4)
    s.none:SetWidth(300)
    s.none:SetText("Nothing earned yet. Your first achievements are a level or a quest away.")
    s.emptyBox = box

    s.overallTitle = UI.Label(s, 11, UI.ACCENT, "OUTLINE")
    s.overallTitle:SetPoint("TOPLEFT", s, "TOPLEFT", 8, -96)
    s.overallTitle:SetText("Overall progress")
    s.overall = UI.Bar(s, { width = RIGHT_W - 16, height = 20 })
    s.overall:SetPoint("TOPLEFT", s, "TOPLEFT", 8, -114)
    s.overall:SetColor(0.85, 0.66, 0.12)
    s.overallFrame = s.overall:CreateTexture(nil, "OVERLAY")
    s.overallFrame:SetPoint("TOPLEFT", s.overall, "TOPLEFT", -6, 6)
    s.overallFrame:SetPoint("BOTTOMRIGHT", s.overall, "BOTTOMRIGHT", 6, -6)
    if not art(s.overallFrame, "Ach_BarFrame", nil) then s.overallFrame:Hide() end

    s.catTitle = UI.Label(s, 11, UI.ACCENT, "OUTLINE")
    s.catTitle:SetPoint("TOPLEFT", s, "TOPLEFT", 8, -146)
    s.catTitle:SetText("Progress by category")
    -- one bordered tile per category: crest, name, earned/total, points, a slim bar
    s.catTiles = {}
    local tileW = floor((RIGHT_W - 16 - 2 * 6) / 3)
    for i, c in ipairs(A.data.categories) do
        local t = CreateFrame("Button", "Achievements_CatTile" .. i, s)
        t:SetWidth(tileW)
        t:SetHeight(TILE_H)
        local col = math.mod(i - 1, 3)
        local line = floor((i - 1) / 3)
        t:SetPoint("TOPLEFT", s, "TOPLEFT", 8 + col * (tileW + 6), -163 - line * (TILE_H + 5))
        t.key = c.key
        t.cat = c
        t.bg = t:CreateTexture(nil, "BACKGROUND")
        t.bg:SetAllPoints(t)
        t.art = art(t.bg, "Ach_Tile", nil)
        if not t.art then
            t.bg:Hide()
            borderBox(t)
        end
        t.crest = t:CreateTexture(nil, "ARTWORK")
        t.crest:SetWidth(32)
        t.crest:SetHeight(32)
        t.crest:SetPoint("LEFT", t, "LEFT", 7, 0)
        t.hasCrest = setCrest(t.crest, c.key, c.icon)
        t.name = UI.Label(t, 10, { 1, 1, 1 }, "OUTLINE")
        t.name:SetPoint("TOPLEFT", t, "TOPLEFT", 45, -8)
        t.name:SetWidth(tileW - 51)
        t.name:SetText(c.name)
        t.count = UI.Label(t, 9, UI.MUTED)
        t.count:SetPoint("TOPLEFT", t, "TOPLEFT", 45, -22)
        t.points = UI.Label(t, 9, UI.ACCENT)
        t.points:SetPoint("TOPRIGHT", t, "TOPRIGHT", -9, -22)
        t.points:SetJustifyH("RIGHT")
        t.track = t:CreateTexture(nil, "BORDER")
        t.track:SetPoint("BOTTOMLEFT", t, "BOTTOMLEFT", 45, 9)
        t.track:SetWidth(tileW - 54)
        t.track:SetHeight(5)
        t.track:SetTexture(0, 0, 0, 0.9)
        t.bar = CreateFrame("StatusBar", nil, t)
        t.bar:SetPoint("TOPLEFT", t.track, "TOPLEFT", 1, -1)
        t.bar:SetPoint("BOTTOMRIGHT", t.track, "BOTTOMRIGHT", -1, 1)
        t.bar:SetStatusBarTexture(UI.BAR)
        t.bar:SetMinMaxValues(0, 1)
        t.bar:SetValue(0)
        local hl = t:CreateTexture(nil, "HIGHLIGHT")
        hl:SetPoint("TOPLEFT", t, "TOPLEFT", 3, -3)
        hl:SetPoint("BOTTOMRIGHT", t, "BOTTOMRIGHT", -3, 3)
        hl:SetTexture(1, 0.82, 0, 0.08)
        t:SetScript("OnClick", function() A.ShowCategory(t.key) end)
        t:SetScript("OnEnter", function()
            if not GameTooltip then return end
            local ce, ct, cp, cm = A.CategoryStats(t.key)
            GameTooltip:SetOwner(t, "ANCHOR_RIGHT")
            GameTooltip:SetText(t.cat.name, gold())
            GameTooltip:AddLine(ce .. " of " .. ct .. " achievements earned", 1, 1, 1)
            if cm > 0 then GameTooltip:AddLine(cp .. " of " .. cm .. " points", 0.62, 0.64, 0.70) end
            GameTooltip:AddLine("Click to open.", 0.5, 0.5, 0.5)
            GameTooltip:Show()
        end)
        t:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
        s.catTiles[i] = t
    end
    s.compare = UI.Label(s, 11, { 0.6, 0.75, 1 }, "OUTLINE")
    s.compare:SetPoint("TOPLEFT", s, "TOPLEFT", 8, -330)
    s.compare:SetWidth(RIGHT_W - 16)
    return s
end

local function refreshSummary()
    local s = summary
    local recent = A.Recent(4)
    for i, t in ipairs(s.tiles) do
        local a = recent[i]
        t.a = a
        if a then
            t.iconBox.icon:SetTexture(a.i)
            t.name:SetText(a.n)
            t.date:SetText(A.Date(A.earned[a.id]))
            t:Show()
        else
            t:Hide()
        end
    end
    if recent[1] then s.emptyBox:Hide() else s.emptyBox:Show() end
    local e, total = A.CategoryStats(nil)
    s.overall:SetFraction(total > 0 and e / total or 0)
    s.overall.left:SetText(e .. " of " .. total .. " achievements")
    s.overall.right:SetText(total > 0 and (floor(e / total * 100 + 0.5) .. "%") or "")
    for _, t in ipairs(s.catTiles) do
        local ce, ct, cp, cm = A.CategoryStats(t.key)
        t.count:SetText(ce .. "/" .. ct)
        t.bar:SetValue(ct > 0 and ce / ct or 0)
        if ct > 0 and ce >= ct then
            t.bar:SetStatusBarColor(0.85, 0.66, 0.12)
            t.name:SetTextColor(gold())
        else
            t.bar:SetStatusBarColor(0.22, 0.62, 0.20)
            t.name:SetTextColor(1, 1, 1)
        end
        if cm > 0 then t.points:SetText(cp .. " pts") else t.points:SetText("") end
    end
    if A.compare then
        s.compare:SetText("Comparing with " .. A.compare.name .. ": " .. A.Commas(A.compare.points or 0)
            .. " points against your " .. A.Commas(A.Points()) .. ".")
        s.compare:Show()
    else
        s.compare:Hide()
    end
end

-- The note under the categories: offline, waiting, not supported, comparing.
local function noteText()
    local has = A.ServerHas()
    if not W.connected then
        if A.Char().synced then
            return "Not connected to the realm. Showing what you had earned when you were last online."
        end
        return "Achievements are kept by the realm. Connect to an Open Vanilla realm to earn them; the full list is shown here."
    end
    if has == false then return "This realm doesn't keep achievements yet. The full list is shown here." end
    if not A.synced then return "Loading your achievements from the realm..." end
    return nil
end

function A.RefreshWindow()
    if not win or not win:IsShown() then return end
    local pts = A.Points()
    pointsText:SetText(A.Commas(pts))
    -- categories
    for _, b in ipairs(catButtons) do
        b:Paint(b.key == A.view.cat and A.view.search == "")
        if b.key ~= "summary" then
            local e, t = A.CategoryStats(b.key)
            b.count:SetText(e .. "/" .. t)
        else
            b.count:SetText("")
        end
    end
    local msg = noteText()
    if msg then note:SetText(msg); note:Show() else note:SetText(""); note:Hide() end
    if A.compare then
        cmpButton:SetText("Stop comparing")
        cmpButton:Show()
    elseif UnitIsPlayer and UnitIsPlayer("target") and not UnitIsUnit("target", "player") then
        cmpButton:SetText("Compare: " .. (UnitName("target") or "target"))
        cmpButton:Show()
    else
        cmpButton:Hide()
    end
    -- right side
    local searching = A.view.search ~= ""
    if A.view.cat == "summary" and not searching then
        header:SetText("Summary")
        list:Hide()
        filterTabs:Hide()
        A.empty:Hide()
        summary:Show()
        refreshSummary()
        return
    end
    summary:Hide()
    list:Show()
    filterTabs:Show()
    local items = A.Filtered(A.view.cat ~= "summary" and A.view.cat or nil, A.view.filter, A.view.search)
    if searching then
        header:SetText("Search: " .. getn(items) .. (getn(items) == 1 and " result" or " results"))
    else
        local c = A.catByKey[A.view.cat]
        header:SetText(c and c.name or "")
    end
    A.shown = items
    list:SetItems(items)
    if items[1] then
        A.empty:Hide()
    else
        A.empty:SetText(searching and "No achievements match your search." or
            (A.view.filter == "earned" and "None earned here yet." or "Nothing to show with this filter."))
        A.empty:Show()
    end
end

local function build()
    if win then return win end
    win = UI.Window("Achievements_Frame", { classicFrame = true, width = WIN_W, height = WIN_H, title = "Achievements",
        icon = "Interface\\Icons\\INV_Crown_01", point = { "CENTER", UIParent, "CENTER", 0, 30 } })
    win:SetFrameStrata("HIGH")
    -- opaque: the world (names, cast bars) must not show through the window
    win:SetBackdropColor(SOLID[1], SOLID[2], SOLID[3], 1)
    win.solid = solidFill(win, 3)
    tinsert(UISpecialFrames, "Achievements_Frame")
    win:Hide()

    -- frame bits: gold corners and a crest behind the title (art only)
    local crest = win:CreateTexture(nil, "ARTWORK")
    crest:SetWidth(256)
    crest:SetHeight(32)
    crest:SetPoint("TOP", win, "TOP", 0, 6)
    if not art(crest, "Ach_TitleCrest", nil) then crest:Hide() end
    win.crest = crest
    local corners = { { "TOPLEFT", -3, 3, 0, 1, 0, 1 }, { "TOPRIGHT", 3, 3, 1, 0, 0, 1 },
                      { "BOTTOMLEFT", -3, -3, 0, 1, 1, 0 }, { "BOTTOMRIGHT", 3, -3, 1, 0, 1, 0 } }
    for _, c in ipairs(corners) do
        local t = win:CreateTexture(nil, "BORDER")
        t:SetWidth(32)
        t:SetHeight(32)
        t:SetPoint(c[1], win, c[1], c[2], c[3])
        if art(t, "Ach_Corner", nil) then t:SetTexCoord(c[4], c[5], c[6], c[7]) else t:Hide() end
        win.corners4 = win.corners4 or {}
        tinsert(win.corners4, t)
    end
    -- the Classic skin draws the shared frame round the window (UI.ClassicChrome): no crest or gold
    -- corners then; the other skins keep this window's own look
    UI.OnSkin(function(th)
        local classic = th.key == "classic"
        if classic then
            UI.PaintWindow(win, th)
            crest:Hide()
            for _, k in ipairs(win.corners4) do k:Hide() end
        else
            if win.chrome then win.chrome:Hide() end
            if win.icon then win.icon:Show() end
            win:SetBackdrop(BORDER)
            win:SetBackdropColor(SOLID[1], SOLID[2], SOLID[3], 1)
            win:SetBackdropBorderColor(0.62, 0.52, 0.28, 1)
            if crest:GetTexture() then crest:Show() end
            for _, k in ipairs(win.corners4) do if k:GetTexture() then k:Show() end end
            if win.title then UI.Font(win.title, 11, "OUTLINE"); win.title:ClearAllPoints(); win.title:SetPoint("CENTER", win.titleBar, "CENTER", 0, 0) end
            if win.closeButton then win.closeButton:ClearAllPoints(); win.closeButton:SetWidth(22); win.closeButton:SetHeight(22); win.closeButton:SetPoint("RIGHT", win.titleBar, "RIGHT", 4, 0) end
        end
    end)

    local gear = UI.GearButton(win, function() A.sheet:Toggle() end, 14)
    gear:SetPoint("RIGHT", win.titleBar, "RIGHT", -22, 0)

    -- points shield
    local shield = win:CreateTexture(nil, "ARTWORK")
    shield:SetWidth(46)
    shield:SetHeight(46)
    shield:SetPoint("TOPLEFT", win, "TOPLEFT", 10, -28)
    if not art(shield, "Ach_Shield", nil) then
        shield:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
        shield:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end
    pointsText = UI.Label(win, 16, UI.ACCENT, "OUTLINE")
    pointsText:SetPoint("TOPLEFT", shield, "TOPRIGHT", 8, -6)
    pointsText:SetText("0")
    A.pointsText = pointsText
    pointsLabel = UI.Label(win, 10, UI.MUTED)
    pointsLabel:SetPoint("TOPLEFT", pointsText, "BOTTOMLEFT", 0, -3)
    pointsLabel:SetText("Achievement points")

    -- categories
    local left = CreateFrame("Frame", nil, win)
    left:SetWidth(LEFT_W)
    left:SetHeight(10 * (CAT_H + 2))
    left:SetPoint("TOPLEFT", win, "TOPLEFT", 10, -82)
    catButtons = {}
    local cats = { { key = "summary", name = "Summary", icon = "Interface\\Icons\\INV_Crown_01" } }
    for _, c in ipairs(A.data.categories) do tinsert(cats, c) end
    for i, c in ipairs(cats) do
        local b = catButton(left, i, c.key, c.name, c.icon)
        b:SetPoint("TOPLEFT", left, "TOPLEFT", 0, -(i - 1) * (CAT_H + 2))
        catButtons[i] = b
    end
    A.catButtons = catButtons

    note = UI.Label(win, 10, { 0.85, 0.75, 0.45 })
    note:SetPoint("TOPLEFT", left, "BOTTOMLEFT", 2, -10)
    note:SetWidth(LEFT_W - 4)
    A.note = note

    cmpButton = UI.Button(win, "Compare", LEFT_W, 20, function()
        if A.compare then A.StopCompare() else A.Compare("") end
    end)
    cmpButton:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", 10, 10)
    A.compareButton = cmpButton

    -- right side
    local right = CreateFrame("Frame", "Achievements_Right", win)
    UI.Skin(right, "inset")
    right:SetBackdropColor(0.03, 0.034, 0.042, 1)
    right.solid = solidFill(right, 2, { 0.03, 0.034, 0.042, 0.97 })
    right:SetPoint("TOPLEFT", win, "TOPLEFT", RIGHT_X, -58)
    right:SetWidth(RIGHT_W)
    right:SetHeight(LIST_ROWS * ROW_H + 8)

    header = UI.Label(win, 13, UI.ACCENT, "OUTLINE")
    header:SetPoint("BOTTOMLEFT", right, "TOPLEFT", 2, 8)
    A.header = header

    searchBox = UI.SearchBox(win, { name = "Achievements_Search", width = 170, placeholder = "Search achievements",
        onChange = function(t)
            A.view.search = W.Trim(t or "")
            if list then list.offset = 0 end
            A.RefreshWindow()
        end })
    searchBox:SetPoint("BOTTOMRIGHT", right, "TOPRIGHT", 0, 5)

    list = UI.ScrollList(right, { name = "Achievements_List", width = RIGHT_W - 6, height = LIST_ROWS * ROW_H,
        rowHeight = ROW_H, wheelStep = 1, build = buildRow, update = updateRow })
    list:SetPoint("TOPLEFT", right, "TOPLEFT", 4, -4)
    A.list = list

    A.empty = UI.Label(right, 11, UI.MUTED)
    A.empty:SetPoint("CENTER", right, "CENTER", 0, 0)
    A.empty:SetJustifyH("CENTER")
    A.empty:Hide()

    summary = buildSummary(right)
    A.summary = summary

    filterTabs = UI.Tabs(win, { tabs = FILTERS, onSelect = function(key)
        A.view.filter = key
        if list then list.offset = 0 end
        A.RefreshWindow()
    end })
    filterTabs:SetPoint("TOPLEFT", right, "BOTTOMLEFT", 0, -1)
    A.filterTabs = filterTabs

    -- settings sheet
    local sheet = UI.Sheet(win, { title = "Achievements settings", width = 236, name = "Achievements_Settings" })
    local function opt(key, def) return function() return W:Setting(ID, key, def) end end
    local function set(key) return function(v) W:Settings(ID)[key] = v; A.Changed("settings") end end
    sheet:AddSwitch("Banner when earned", "Show a banner and play a sound when you earn an achievement.", opt("toasts", true), set("toasts"))
    sheet:AddSwitch("Tell my guild", "Say in guild chat when you earn one.", opt("announceGuild", false), set("announceGuild"))
    sheet:AddSwitch("Realm firsts", "A banner when anyone on the realm claims a realm first.", opt("realmFirstToasts", true), set("realmFirstToasts"))
    sheet:AddSwitch("Tracker", "Show tracked achievements on screen (up to five).", opt("showTracker", true), set("showTracker"))
    sheet:AddSwitch("Share with Persona", "Let your profile show your points and a featured achievement.", opt("persona", true), set("persona"))
    A.sheet = sheet

    win:SetScript("OnShow", function()
        if PlaySound then PlaySound("igCharacterInfoOpen") end
        if not A.synced and W.connected then A.RequestList() end
        A.RefreshWindow()
    end)
    win:SetScript("OnHide", function()
        if PlaySound then PlaySound("igCharacterInfoClose") end
        if A.sheet then A.sheet:Hide() end
    end)
    win:RegisterEvent("PLAYER_TARGET_CHANGED")
    win:SetScript("OnEvent", function() A.RefreshWindow() end)
    A.window = win
    return win
end

-- -- Navigation -------------------------------------------------------------------------------

function A.ShowCategory(key)
    build()
    A.view.cat = key or "summary"
    if A.view.search ~= "" then
        A.view.search = ""
        searchBox:SetText("")
    end
    list.offset = 0
    if not win:IsShown() then win:Show() end
    A.RefreshWindow()
end

-- Open on one achievement's category, scrolled to it.
function A.ShowAchievement(id)
    local a = A.byId[tonumber(id) or -1]
    if not a then return end
    build()
    A.view.filter = "all"
    filterTabs:Select("all", true)
    A.ShowCategory(a.c)
    for i, x in ipairs(A.shown or {}) do
        if x.id == a.id then
            list.offset = math.max(0, i - 2)
            list:Refresh()
            break
        end
    end
end

function A.Toggle()
    if not W:IsActive(ID) then
        W.Print("Achievements is switched off. Turn it on in /addons.")
        return
    end
    build()
    if win:IsShown() then win:Hide() else win:Show() end
end

function Achievements_Toggle() A.Toggle() end

function A.Build() return build() end

local prevChanged = A.OnDataChanged
A.OnDataChanged = function(what)
    if prevChanged then prevChanged(what) end
    A.RefreshWindow()
end
