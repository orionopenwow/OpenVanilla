--[[
    Pages.lua  (Open Vanilla staff console)
    The Map, Everyone and Bugs tabs.

    Map: the client's own continent maps (Interface\WorldMap\<continent>\<continent>1..12, a 4x3
    grid of 256 px tiles, as the world map draws them; nothing is shipped) with a dot per player.
    Dots are placed with each continent map's world bounds (WorldMapArea: the left/right edges are
    world y, the top/bottom edges world x; north is up). Click a dot to pick that player.
    Lua 5.0 rules: no '#', no '%' operator, handlers read this/event/arg1.
]]--

local W = WenillaCore
local UI = W.UI
local C = OVConsole
local A = C.Act

local strsub, strlen, format = string.sub, string.len, string.format
local getn, floor = table.getn, math.floor

-- -- Map ---------------------------------------------------------------------------------------

C.MAPS = {
    [0] = { label = "Eastern Kingdoms", folder = "Azeroth", left = 18171.97, right = -22569.21, top = 11176.34, bottom = -15973.34 },
    [1] = { label = "Kalimdor", folder = "Kalimdor", left = 17066.6, right = -19733.21, top = 12799.9, bottom = -11733.3 },
}
C.mapShown = C.mapShown or 0
local MAP_H = 380
local SCALE = MAP_H / 668            -- the world map's drawn area is 1002 x 668 of the 1024 x 768 tile grid
local MAP_W = floor(1002 * SCALE)

-- world (x, y) on a continent -> 0..1 across and down the map; nil when off the map
function C.MapPoint(map, x, y)
    local m = C.MAPS[map]
    if not m then return nil end
    local fx = (m.left - y) / (m.left - m.right)
    local fy = (m.top - x) / (m.top - m.bottom)
    if fx < 0 or fx > 1 or fy < 0 or fy > 1 then return nil end
    return fx, fy
end

C.builders.map = function(p)
    p.mapButtons = {}
    local x = 0
    for _, id in ipairs({ 0, 1 }) do
        local mid = id
        local b = C.Btn(p, C.MAPS[id].label, 130, function() C.mapShown = mid; C.renderers.map() end)
        b:SetPoint("TOPLEFT", p, "TOPLEFT", x, 0)
        p.mapButtons[id] = b
        x = x + 136
    end
    local elsewhere = C.Label(p, 10, UI.MUTED)
    elsewhere:SetPoint("LEFT", p.mapButtons[1], "RIGHT", 12, 0)
    elsewhere:SetWidth(C.WIDTH - 320)
    p.elsewhere = elsewhere

    local frame = CreateFrame("Frame", nil, p)
    frame:SetWidth(MAP_W)
    frame:SetHeight(MAP_H)
    frame:SetPoint("TOP", p, "TOP", 0, -26)
    local bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(frame)
    bg:SetTexture(0.05, 0.06, 0.08, 1)
    p.mapFrame = frame
    -- 4 x 3 tiles; the last column and row are cut to the 1002 x 668 drawn area
    p.tiles = {}
    local tile = 256 * SCALE
    for row = 0, 2 do
        for col = 0, 3 do
            local t = frame:CreateTexture(nil, "BORDER")
            local w = (col == 3) and (1002 - 768) * SCALE or tile
            local h = (row == 2) and (668 - 512) * SCALE or tile
            t:SetWidth(w)
            t:SetHeight(h)
            t:SetPoint("TOPLEFT", frame, "TOPLEFT", col * tile, -row * tile)
            t:SetTexCoord(0, (col == 3) and (234 / 256) or 1, 0, (row == 2) and (156 / 256) or 1)
            table.insert(p.tiles, t)
        end
    end
    p.dots = {}
end

local function dot(p, i)
    local d = p.dots[i]
    if d then return d end
    d = CreateFrame("Button", nil, p.mapFrame)
    d:SetWidth(9)
    d:SetHeight(9)
    d:SetFrameLevel(p.mapFrame:GetFrameLevel() + 3)
    d.ring = d:CreateTexture(nil, "BACKGROUND")
    d.ring:SetAllPoints(d)
    d.ring:SetTexture(0, 0, 0, 1)
    d.fill = d:CreateTexture(nil, "ARTWORK")
    d.fill:SetPoint("TOPLEFT", d, "TOPLEFT", 2, -2)
    d.fill:SetPoint("BOTTOMRIGHT", d, "BOTTOMRIGHT", -2, 2)
    d:SetScript("OnClick", function() if d.who then C:Select(d.who.name) end end)
    d:SetScript("OnEnter", function()
        local q = d.who
        if not (q and GameTooltip) then return end
        GameTooltip:SetOwner(d, "ANCHOR_RIGHT")
        GameTooltip:AddLine(q.name, UI.ClassColor(q.class))
        GameTooltip:AddLine("Level " .. q.level .. " " .. q.raceName .. " " .. q.className, 1, 1, 1)
        GameTooltip:AddLine(q.zoneName, 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    d:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    p.dots[i] = d
    return d
end

C.renderers.map = function()
    local p = C.pages.map
    local m = C.MAPS[C.mapShown]
    for i, t in ipairs(p.tiles) do t:SetTexture("Interface\\WorldMap\\" .. m.folder .. "\\" .. m.folder .. i) end
    for id, b in pairs(p.mapButtons) do
        if b.LockHighlight then if id == C.mapShown then b:LockHighlight() else b:UnlockHighlight() end end
    end
    local n, away = 0, {}
    p.shown = {}
    for _, q in ipairs(C.roster) do
        local fx, fy
        if q.map == C.mapShown then fx, fy = C.MapPoint(q.map, q.x, q.y) end
        if fx then
            n = n + 1
            local d = dot(p, n)
            d.who = q
            d:ClearAllPoints()
            d:SetPoint("CENTER", p.mapFrame, "TOPLEFT", fx * MAP_W, -fy * MAP_H)
            local r, g, b = UI.ClassColor(q.class)
            d.fill:SetTexture(r, g, b, 1)
            if q.name == C.selected then
                d:SetWidth(13); d:SetHeight(13); d.ring:SetTexture(1, 1, 1, 1)
            else
                d:SetWidth(9); d:SetHeight(9); d.ring:SetTexture(0, 0, 0, 1)
            end
            d:Show()
            p.shown[q.name] = d
        elseif q.map ~= 0 and q.map ~= 1 then
            table.insert(away, q.name .. " (" .. q.zoneName .. ")")
        end
    end
    for i = n + 1, getn(p.dots) do p.dots[i]:Hide(); p.dots[i].who = nil end
    p.elsewhere:SetText(getn(away) > 0 and ("In dungeons and battlegrounds: " .. table.concat(away, ", ")) or "")
end

-- -- Everyone ----------------------------------------------------------------------------------

C.builders.everyone = function(p)
    local h1 = C.Label(p, 12, UI.ACCENT)
    h1:SetPoint("TOPLEFT", p, "TOPLEFT", 2, -2)
    h1:SetText("Tell everyone")
    local text
    text = C.Edit(p, 440, "Text for everyone", 200)
    text:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -20)
    p.text = text
    local ann = C.Btn(p, "In chat", 100, function()
        if A.announce(text:GetText()) then text:SetText(""); text:ClearFocus() end
    end)
    ann:SetPoint("LEFT", text, "RIGHT", 8, 0)
    local note = C.Btn(p, "On screen", 100, function()
        if A.notify(text:GetText()) then text:SetText(""); text:ClearFocus() end
    end)
    note:SetPoint("LEFT", ann, "RIGHT", 6, 0)

    local h2 = C.Label(p, 12, UI.ACCENT)
    h2:SetPoint("TOPLEFT", p, "TOPLEFT", 2, -56)
    h2:SetText("Any GM command")
    local cmd
    local function run()
        if C:RunTyped(cmd:GetText()) then
            if cmd.AddHistoryLine then cmd:AddHistoryLine(C.history[getn(C.history)]) end
            cmd:SetText("")
            C.renderers.everyone()
        end
    end
    cmd = C.Edit(p, 548, ".command (Up arrow: the ones you ran before)", 250, run)
    cmd:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -74)
    if cmd.SetHistoryLines then cmd:SetHistoryLines(30) end
    p.cmd = cmd
    local rb = C.Btn(p, "Run", 100, run)
    rb:SetPoint("LEFT", cmd, "RIGHT", 8, 0)

    local h3 = C.Label(p, 11)
    h3:SetPoint("TOPLEFT", p, "TOPLEFT", 2, -104)
    h3:SetText("Common commands (click to put one in the box)")
    p.common = {}
    for i, c in ipairs(C.COMMON) do
        local line = c
        local col = math.mod(i - 1, 2)
        local row = floor((i - 1) / 2)
        local b = CreateFrame("Button", nil, p)
        b:SetWidth(170)
        b:SetHeight(16)
        b:SetPoint("TOPLEFT", p, "TOPLEFT", col * 176, -122 - row * 17)
        b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        b.text = C.Label(b, 10, { 0.6, 0.85, 1 })
        b.text:SetPoint("LEFT", b, "LEFT", 4, 0)
        b.text:SetText(line)
        b:SetScript("OnClick", function() cmd:SetText(line); cmd:SetFocus() end)
        p.common[i] = b
    end

    local h4 = C.Label(p, 11)
    h4:SetPoint("TOPLEFT", p, "TOPLEFT", 380, -104)
    h4:SetText("You ran recently (click to use again)")
    local recent = UI.ScrollList(p, { width = 330, height = 238, rowHeight = 16,
        build = function(row)
            row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
            row.text = C.Label(row, 10, { 0.85, 0.85, 0.88 })
            row.text:SetPoint("LEFT", row, "LEFT", 4, 0)
            row.text:SetWidth(320)
            row:SetScript("OnClick", function() if row.item then cmd:SetText(row.item); cmd:SetFocus() end end)
        end,
        update = function(row, line) row.text:SetText(line) end })
    recent:SetPoint("TOPLEFT", p, "TOPLEFT", 380, -122)
    p.recent = recent
end

C.renderers.everyone = function()
    local p = C.pages.everyone
    local rev = {}
    for i = getn(C.history), 1, -1 do table.insert(rev, C.history[i]) end
    p.recent:SetItems(rev)
end

-- -- Bugs --------------------------------------------------------------------------------------

local function bugWhen(t)
    if not (t and t > 0 and date) then return "" end
    return date("%d %b %H:%M", t)
end

C.builders.bugs = function(p)
    local head = C.Label(p, 11, UI.MUTED)
    head:SetPoint("TOPLEFT", p, "TOPLEFT", 2, -4)
    p.head = head
    local refresh = C.Btn(p, "Refresh", 90, function() C:Ask("bugs") end)
    refresh:SetPoint("TOPRIGHT", p, "TOPRIGHT", 0, 0)

    local list = UI.ScrollList(p, { width = C.WIDTH - 20, height = 216, rowHeight = 18,
        build = function(row)
            row.sel = row:CreateTexture(nil, "BACKGROUND")
            row.sel:SetAllPoints(row)
            row.sel:SetTexture(0.25, 0.32, 0.48, 0.55)
            row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
            row.id = C.Label(row, 10, UI.MUTED)
            row.id:SetPoint("LEFT", row, "LEFT", 4, 0)
            row.when = C.Label(row, 10, UI.MUTED)
            row.when:SetPoint("LEFT", row, "LEFT", 44, 0)
            row.who = C.Label(row, 10)
            row.who:SetPoint("LEFT", row, "LEFT", 136, 0)
            row.who:SetWidth(110)
            row.where = C.Label(row, 10)
            row.where:SetPoint("LEFT", row, "LEFT", 250, 0)
            row.where:SetWidth(120)
            row.what = C.Label(row, 10)
            row.what:SetPoint("LEFT", row, "LEFT", 374, 0)
            row.what:SetWidth(330)
            row.what:SetHeight(16)
            row:SetScript("OnClick", function()
                if row.item then C.bugSelected = row.item.id; C.renderers.bugs() end
            end)
        end,
        update = function(row, b)
            row.id:SetText("#" .. b.id)
            row.when:SetText(bugWhen(b.created))
            row.who:SetText(b.name .. " (" .. b.level .. ")")
            row.who:SetTextColor(UI.ClassColor(b.class))
            row.where:SetText(C.ZoneName(b.zone, b.map))
            row.what:SetText("|cffffd100" .. (b.category ~= "" and b.category or "bug") .. ":|r " .. b.text)
            if b.id == C.bugSelected then row.sel:Show() else row.sel:Hide() end
        end })
    list:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -26)
    p.list = list

    local rule = UI.Divider(p, C.WIDTH - 24)
    rule:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -248)
    local detail = C.Label(p, 11)
    detail:SetPoint("TOPLEFT", p, "TOPLEFT", 2, -256)
    detail:SetWidth(C.WIDTH - 140)
    detail:SetJustifyV("TOP")
    p.detail = detail
    local go = C.Btn(p, "Go there", 110, function() A.go(C:Bug(C.bugSelected)) end)
    go:SetPoint("TOPRIGHT", p, "TOPRIGHT", 0, -256)
    p.go = go
    local who = C.Btn(p, "Go to reporter", 110, function()
        local b = C:Bug(C.bugSelected)
        if b then A.appear(b.name) end
    end)
    who:SetPoint("TOPRIGHT", go, "BOTTOMRIGHT", 0, -4)
    p.who = who
end

function C:Bug(id)
    for _, b in ipairs(self.bugs) do if b.id == id then return b end end
    return nil
end

C.renderers.bugs = function()
    local p = C.pages.bugs
    p.list:SetItems(C.bugs)
    local n = getn(C.bugs)
    p.head:SetText(C.bugsAsked and (n == 0 and "No bug reports." or (n .. (n == 1 and " report" or " reports") .. ", newest first. Click one to read it.")) or "")
    local b = C:Bug(C.bugSelected)
    if b then
        p.detail:SetText("|cffffd100#" .. b.id .. "  " .. (b.category ~= "" and b.category or "bug") .. "|r  from " .. b.name
            .. " (level " .. b.level .. " " .. C.ClassName(b.class) .. "), " .. bugWhen(b.created) .. "\n"
            .. C.ZoneName(b.zone, b.map) .. format("  (%.1f, %.1f, %.1f, map %d)", b.x, b.y, b.z, b.map) .. "\n\n" .. b.text)
        p.go:Show(); p.who:Show()
    else
        p.detail:SetText(n > 0 and "Pick a report to read it in full." or "")
        p.go:Hide(); p.who:Hide()
    end
end

C.RenderBugs = function(self) if C.pages.bugs then C.renderers.bugs() end end

C.onShowPage.bugs = function()
    C.bugsAsked = true
    C:Ask("bugs")
    C.renderers.bugs()
end
