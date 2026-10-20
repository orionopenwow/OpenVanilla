--[[
    Window.lua  (Open Vanilla staff console)
    The window: tabs, the output strip, and the Players, Actions and Armory tabs.
    Pages.lua adds Map, Everyone and Bugs. Built the first time a game master opens it.
    Lua 5.0 rules: no '#', no '%' operator, handlers read this/event/arg1.
]]--

local W = WenillaCore
local UI = W.UI
local C = OVConsole
local A = C.Act

local strfind, strsub, strlower, format = string.find, string.sub, string.lower, string.format
local getn, floor = table.getn, math.floor

local ICON = "Interface\\Icons\\INV_Misc_Book_11"
C.WIDTH, C.HEIGHT = 740, 560
C.TABS = {
    { key = "players", label = "Players" }, { key = "actions", label = "Actions" }, { key = "armory", label = "Armory" },
    { key = "map", label = "Map" }, { key = "everyone", label = "Everyone" }, { key = "bugs", label = "Bugs" },
}
C.builders = C.builders or {}     -- key -> function(page)
C.renderers = C.renderers or {}   -- key -> function() (redraw from C's data)
C.onShowPage = C.onShowPage or {} -- key -> function() (the tab was picked)
C.pages = {}

local win

-- -- small widgets ---------------------------------------------------------------------------

function C.Label(parent, size, color)
    local fs = UI.Label(parent, size or 11, color or { 0.92, 0.92, 0.95 })
    return fs
end

function C.Btn(parent, text, w, onClick)
    return UI.Button(parent, text, w or 96, 20, onClick)
end

-- a one-line edit box with a placeholder; onEnter(text) runs on Enter
function C.Edit(parent, width, placeholder, maxLetters, onEnter)
    local e = UI.SearchBox(parent, { width = width, placeholder = placeholder })
    e:SetMaxLetters(maxLetters or 200)
    e:SetScript("OnEnterPressed", function()
        if onEnter then onEnter(e:GetText() or "") else e:ClearFocus() end
    end)
    e:SetScript("OnEscapePressed", function() e:ClearFocus() end)
    return e
end

local function need()
    if C.selected then return C.selected end
    C:Echo("|cffffd100Pick a player on the Players tab first.|r")
    return nil
end
C.Need = need

-- -- the frame ---------------------------------------------------------------------------------

local function makePage(key)
    local p = CreateFrame("Frame", nil, win)
    p:SetPoint("TOPLEFT", win, "TOPLEFT", 10, -54)
    p:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -10, 84)
    p:SetWidth(C.WIDTH - 20)
    p:SetHeight(C.HEIGHT - 54 - 84)
    p:Hide()
    C.pages[key] = p
    return p
end

function C:SelectPage(key)
    for k, p in pairs(self.pages) do
        if k == key then p:Show() else p:Hide() end
    end
    self.current = key
    if self.onShowPage[key] then self.onShowPage[key]() end
end

function C:ShowTab(key)
    self:Build()
    if win.tabs then win.tabs:Select(key) else self:SelectPage(key) end
end

function C:Build()
    if win then return win end
    win = UI.Window("OVConsole_Frame", { width = C.WIDTH, height = C.HEIGHT, title = "GM Console", icon = ICON,
        skin = true, strata = "HIGH", classicFrame = true })
    win:Hide()
    C.win = win
    if UISpecialFrames then table.insert(UISpecialFrames, "OVConsole_Frame") end

    local st = C.Label(win, 10, UI.MUTED)
    st:SetPoint("TOPRIGHT", win, "TOPRIGHT", -14, -32)
    st:SetJustifyH("RIGHT")
    win.status = st

    -- output strip: the realm's answers to what you run
    local outBg = CreateFrame("Frame", nil, win)
    UI.Skin(outBg, "inset")
    outBg:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", 10, 10)
    outBg:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -10, 10)
    outBg:SetWidth(C.WIDTH - 20)
    outBg:SetHeight(68)
    local out = UI.ScrollList(outBg, { width = C.WIDTH - 32, height = 60, rowHeight = 12, wheelStep = 1,
        build = function(row)
            row.text = C.Label(row, 10, { 0.85, 0.85, 0.88 })
            row.text:SetPoint("LEFT", row, "LEFT", 0, 0)
            row.text:SetWidth(C.WIDTH - 40)
            row.text:SetHeight(12)
        end,
        update = function(row, line) row.text:SetText(line) end })
    out:SetPoint("TOPLEFT", outBg, "TOPLEFT", 6, -4)
    win.out = out

    local tabs = UI.Tabs(win, { tabs = C.TABS, skin = true, onSelect = function(k) C:SelectPage(k) end })
    tabs:SetPoint("TOPLEFT", win, "TOPLEFT", 12, -28)
    win.tabs = tabs

    for _, t in ipairs(C.TABS) do
        local p = makePage(t.key)
        if C.builders[t.key] then C.builders[t.key](p) end
    end

    -- ask for the roster every few seconds while open
    win:SetScript("OnUpdate", function()
        C.sinceAsk = (C.sinceAsk or 0) + (arg1 or 0)
        if C.sinceAsk >= C.REFRESH then
            C.sinceAsk = 0
            C:Ask("roster")
        end
    end)

    C:SelectPage("players")
    C:Render()
    C:RenderOut()
    return win
end

function C:Render()
    if not win then return end
    local n = getn(self.roster)
    local s = n .. (n == 1 and " player" or " players") .. " online"
    if self.selected then s = s .. "  |  picked: |cffffffff" .. self.selected .. "|r" end
    win.status:SetText(s)
    for _, fn in pairs(self.renderers) do
        local ok, err = pcall(fn)
        if not ok then W:Error("Console", err) end
    end
end

function C:RenderOut()
    if not win then return end
    win.out:SetItems(self.out)
    win.out:ScrollToEnd()
end

function C:Select(name)
    self.selected = name
    self:Render()
end

-- -- Players ---------------------------------------------------------------------------------

C.COLUMNS = {
    { key = "name", label = "Name", w = 96 }, { key = "level", label = "Lvl", w = 30 },
    { key = "class", label = "Class", w = 58 }, { key = "race", label = "Race", w = 64 },
    { key = "zone", label = "Zone", w = 116 }, { key = "hp", label = "Health", w = 78 },
    { key = "copper", label = "Gold", w = 58 }, { key = "account", label = "Account", w = 84 },
    { key = "latency", label = "Ping", w = 44 }, { key = "flags", label = "Flags", w = 86 },
}

local function colX(i)
    local x = 4
    for j = 1, i - 1 do x = x + C.COLUMNS[j].w end
    return x
end

local function rowTooltip(row)
    local p = row.item
    if not p or not GameTooltip then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    local r, g, b = UI.ClassColor(p.class)
    GameTooltip:AddLine(p.name, r, g, b)
    GameTooltip:AddLine("Level " .. p.level .. " " .. p.raceName .. " " .. p.className, 1, 1, 1)
    if p.guild ~= "" then GameTooltip:AddLine("<" .. p.guild .. ">", 0.6, 0.9, 0.6) end
    GameTooltip:AddLine(p.zoneName .. format("  (%.0f, %.0f, %.0f)", p.x, p.y, p.z), 0.8, 0.8, 0.8)
    GameTooltip:AddLine("Account " .. p.account .. (p.accountLevel > 0 and (" (GM level " .. p.accountLevel .. ")") or ""), 0.8, 0.8, 0.8)
    if p.mutedSec > 0 then GameTooltip:AddLine("Muted for " .. W.Clock(p.mutedSec), 1, 0.4, 0.4) end
    if p.ip ~= "" then GameTooltip:AddLine("Address " .. C.MaskIp(p.ip), 0.8, 0.8, 0.8) end
    if p.sameIp then GameTooltip:AddLine("Same address as " .. table.concat(p.sameIp, ", "), 1, 0.82, 0) end
    GameTooltip:AddLine("Click to pick, right-click for actions.", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end

C.builders.players = function(p)
    local filter = C.Edit(p, 200, "Filter: name, account, guild, zone, class", 40)
    filter:SetPoint("TOPLEFT", p, "TOPLEFT", 0, 0)
    filter:SetScript("OnTextChanged", function()
        local t = filter:GetText() or ""
        if t == "" then filter.placeholder:Show() else filter.placeholder:Hide() end
        C:SetFilter(t)
    end)
    p.filter = filter
    local count = C.Label(p, 10, UI.MUTED)
    count:SetPoint("LEFT", filter, "RIGHT", 10, 0)
    p.count = count

    p.heads = {}
    for i, col in ipairs(C.COLUMNS) do
        local h = CreateFrame("Button", nil, p)
        h:SetWidth(col.w)
        h:SetHeight(16)
        h:SetPoint("TOPLEFT", p, "TOPLEFT", colX(i), -24)
        h.text = C.Label(h, 10, UI.ACCENT)
        h.text:SetPoint("LEFT", h, "LEFT", 0, 0)
        h.key = col.key
        h.label = col.label
        h:SetScript("OnClick", function() C:SetSort(h.key) end)
        p.heads[i] = h
    end

    local list = UI.ScrollList(p, { width = C.WIDTH - 20, height = 340, rowHeight = 17,
        build = function(row)
            row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            row.sel = row:CreateTexture(nil, "BACKGROUND")
            row.sel:SetAllPoints(row)
            row.sel:SetTexture(0.25, 0.32, 0.48, 0.55)
            row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
            row.cells = {}
            for i, col in ipairs(C.COLUMNS) do
                if col.key == "hp" then
                    local sb = CreateFrame("StatusBar", nil, row)
                    sb:SetStatusBarTexture(UI.BAR)
                    sb:SetMinMaxValues(0, 1)
                    sb:SetWidth(col.w - 8)
                    sb:SetHeight(11)
                    sb:SetPoint("LEFT", row, "LEFT", colX(i), 0)
                    local t = C.Label(sb, 9)
                    t:SetPoint("CENTER", sb, "CENTER", 0, 0)
                    t:SetJustifyH("CENTER")
                    row.hp, row.hpText = sb, t
                else
                    local fs = C.Label(row, 10)
                    fs:SetPoint("LEFT", row, "LEFT", colX(i), 0)
                    fs:SetWidth(col.w - 4)
                    fs:SetHeight(16)
                    row.cells[col.key] = fs
                end
            end
            row:SetScript("OnClick", function()
                if not row.item then return end
                C:Select(row.item.name)
                if arg1 == "RightButton" then C:ShowTab("actions") end
            end)
            row:SetScript("OnEnter", function() rowTooltip(row) end)
            row:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
        end,
        update = function(row, q)
            local c = row.cells
            local r, g, b = UI.ClassColor(q.class)
            c.name:SetText(q.name)
            c.name:SetTextColor(r, g, b)
            c.level:SetText(q.level)
            c.class:SetText(q.className)
            c.race:SetText(q.raceName)
            c.zone:SetText(q.zoneName)
            c.copper:SetText(C.Gold(q.copper))
            c.account:SetText(q.account)
            c.latency:SetText(q.latency .. " ms")
            c.flags:SetText(C.Flags(q))
            row.hp:SetValue(q.frac)
            if q.state > 0 then row.hp:SetStatusBarColor(0.4, 0.4, 0.4)
            else row.hp:SetStatusBarColor(1 - q.frac, 0.25 + 0.6 * q.frac, 0.15) end
            row.hpText:SetText(q.state > 0 and (q.state == 2 and "Ghost" or "Dead") or (floor(q.frac * 100 + 0.5) .. "%"))
            if q.name == C.selected then row.sel:Show() else row.sel:Hide() end
        end })
    list:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -42)
    p.list = list

    local empty = C.Label(p, 11, UI.MUTED)
    empty:SetPoint("TOPLEFT", p, "TOPLEFT", 4, -48)
    p.empty = empty
end

C.renderers.players = function()
    local p = C.pages.players
    local view = C:View()
    C.view = view
    p.list:SetItems(view)
    local total = getn(C.roster)
    if total == 0 then
        p.empty:SetText(C.rosterAt and "Nobody is in the world right now." or "Asking the realm who is online...")
        p.empty:Show()
    elseif getn(view) == 0 then
        p.empty:SetText("Nobody matches the filter.")
        p.empty:Show()
    else
        p.empty:Hide()
    end
    p.count:SetText(getn(view) == total and (total .. " online") or (getn(view) .. " of " .. total .. " shown"))
    for _, h in ipairs(p.heads) do
        local mark = ""
        if h.key == C.sortKey then mark = C.sortDesc and " v" or " ^" end
        h.text:SetText(h.label .. mark)
    end
end

-- -- Actions ---------------------------------------------------------------------------------

C.builders.actions = function(p)
    local head = C.Label(p, 13, UI.ACCENT)
    head:SetPoint("TOPLEFT", p, "TOPLEFT", 2, -2)
    head:SetWidth(C.WIDTH - 30)
    p.head = head
    local sub = C.Label(p, 10, UI.MUTED)
    sub:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 0, -3)
    sub:SetWidth(C.WIDTH - 30)
    p.sub = sub

    -- whisper
    local msg
    local function whisper()
        local n = need()
        if n and A.whisper(n, msg:GetText()) then msg:SetText(""); msg:ClearFocus() end
    end
    msg = C.Edit(p, 480, "Whisper to them", 240, whisper)
    msg:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -42)
    p.msg = msg
    local wb = C.Btn(p, "Whisper", 100, whisper)
    wb:SetPoint("LEFT", msg, "RIGHT", 8, 0)

    -- one-click commands
    local row1 = {
        { "Go to them", function(n) A.appear(n) end }, { "Bring them here", function(n) A.summon(n) end },
        { "Revive", function(n) A.revive(n) end }, { "Info", function(n) A.pinfo(n) end },
        { "Reset talents", function(n) A.resetTalents(n) end },
    }
    local x = 0
    for _, b in ipairs(row1) do
        local fn = b[2]
        local btn = C.Btn(p, b[1], 112, function() local n = need(); if n then fn(n) end end)
        btn:SetPoint("TOPLEFT", p, "TOPLEFT", x, -72)
        x = x + 118
    end

    local to = C.Label(p, 11)
    to:SetPoint("TOPLEFT", p, "TOPLEFT", 2, -110)
    to:SetText("Send them to")
    x = 0
    for _, place in ipairs(C.PLACES) do
        local key = place[1]
        local btn = C.Btn(p, place[2], 86, function() local n = need(); if n then A.tele(n, key) end end)
        btn:SetPoint("TOPLEFT", p, "TOPLEFT", x, -126)
        x = x + 90
    end

    local ml = C.Label(p, 11)
    ml:SetPoint("TOPLEFT", p, "TOPLEFT", 2, -166)
    ml:SetText("Minutes")
    local mins = C.Edit(p, 50, "", 5)
    mins:SetPoint("TOPLEFT", p, "TOPLEFT", 56, -162)
    mins:SetText("10")
    if mins.SetNumeric then mins:SetNumeric(true) end
    p.mins = mins
    local row2 = {
        { "Mute", function(n) A.mute(n, mins:GetText()) end }, { "Unmute", function(n) A.unmute(n) end },
        { "Jail", function(n) A.jail(n, mins:GetText()) end }, { "Kick", function(n) A.kick(n) end },
    }
    x = 116
    for _, b in ipairs(row2) do
        local fn = b[2]
        local btn = C.Btn(p, b[1], 96, function() local n = need(); if n then fn(n) end end)
        btn:SetPoint("TOPLEFT", p, "TOPLEFT", x, -162)
        x = x + 102
    end
    local jailNote = C.Label(p, 10, UI.MUTED)
    jailNote:SetPoint("TOPLEFT", p, "TOPLEFT", 116, -186)
    jailNote:SetText("Jail sends them to GM Island and mutes them for the minutes above. Kick and jail ask first.")

    local rule = UI.Divider(p, C.WIDTH - 24)
    rule:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -210)

    -- ban the account
    local bl = C.Label(p, 12, { 1, 0.45, 0.4 })
    bl:SetPoint("TOPLEFT", p, "TOPLEFT", 2, -222)
    p.banLabel = bl
    C.banTime = C.banTime or 4
    local dur = C.Btn(p, "", 100, function()
        C.banTime = C.banTime + 1
        if C.banTime > getn(C.BAN_TIMES) then C.banTime = 1 end
        C.renderers.actions()
    end)
    dur:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -244)
    p.dur = dur
    local reason = C.Edit(p, 420, "Reason (the player sees it)", 120)
    reason:SetPoint("LEFT", dur, "RIGHT", 8, 0)
    p.reason = reason
    local ban = C.Btn(p, "Ban account", 110, function()
        local n = need()
        if not n then return end
        local q = C.byName[n]
        if not q or q.account == "" then C:Echo("|cffffd100No account known for " .. n .. ".|r") return end
        if W.Trim(reason:GetText() or "") == "" then C:Echo("|cffffd100Give a reason for the ban.|r") return end
        A.ban(q.account, C.BAN_TIMES[C.banTime][1], reason:GetText())
    end)
    ban:SetPoint("LEFT", reason, "RIGHT", 8, 0)

    local note = C.Label(p, 10, UI.MUTED)
    note:SetPoint("TOPLEFT", p, "TOPLEFT", 2, -290)
    note:SetWidth(C.WIDTH - 30)
    note:SetText("Every button here runs an ordinary GM command, and the realm checks your rights for each one. Its answer shows in the strip at the bottom.")
end

C.renderers.actions = function()
    local p = C.pages.actions
    local q = C.selected and C.byName[C.selected]
    if not C.selected then
        p.head:SetText("Nobody picked")
        p.sub:SetText("Pick a player on the Players tab or the Map.")
    elseif q then
        p.head:SetText(q.name)
        p.sub:SetText("Level " .. q.level .. " " .. q.raceName .. " " .. q.className .. ", " .. q.zoneName
            .. "  |  account " .. q.account .. "  " .. C.Flags(q))
    else
        p.head:SetText(C.selected)
        p.sub:SetText("Not in the world right now.")
    end
    p.banLabel:SetText("Ban account" .. ((q and q.account ~= "") and (": " .. q.account) or ""))
    p.dur:SetText(C.BAN_TIMES[C.banTime][2])
end

-- -- Armory ----------------------------------------------------------------------------------
-- The picked player's sheet from the roster, plus their gear through the client's own inspect
-- when they are close enough (NotifyInspect, then GetInventoryItemLink("target", slot)).

C.SLOT_NAMES = {
    [1] = "Head", [2] = "Neck", [3] = "Shoulder", [4] = "Shirt", [5] = "Chest", [6] = "Waist", [7] = "Legs",
    [8] = "Feet", [9] = "Wrist", [10] = "Hands", [11] = "Finger", [12] = "Finger", [13] = "Trinket",
    [14] = "Trinket", [15] = "Back", [16] = "Main hand", [17] = "Off hand", [18] = "Ranged", [19] = "Tabard",
}
local LEFT_SLOTS = { 1, 2, 3, 15, 5, 4, 19, 9 }
local RIGHT_SLOTS = { 10, 6, 7, 8, 11, 12, 13, 14 }
local LOW_SLOTS = { 16, 17, 18 }

local function itemString(link)
    if not link then return nil end
    local _, _, s = strfind(link, "(item:[%d:]+)")
    return s
end

function C:CanInspect(name)
    if not name or UnitName("target") ~= name then return false end
    if UnitIsPlayer and not UnitIsPlayer("target") then return false end
    if CheckInteractDistance then return CheckInteractDistance("target", 1) and true or false end
    return false
end

-- Inspect the picked player if they are near. force: target them by name first.
function C:TryInspect(force)
    local name = self.selected
    if not name then return false end
    if force and TargetByName and UnitName("target") ~= name then TargetByName(name, true) end
    if not self:CanInspect(name) then
        self.inspectFor = nil
        if C.renderers.armory then C.renderers.armory() end
        return false
    end
    self.inspectFor = name
    if NotifyInspect then NotifyInspect("target") end
    self:ReadGear()
    return true
end

function C:ReadGear()
    local name = UnitName("target")
    if not name or name ~= self.inspectFor then return end
    local gear, any = {}, false
    for slot = 1, 19 do
        local link = GetInventoryItemLink("target", slot)
        if link then
            gear[slot] = { link = link, tex = GetInventoryItemTexture and GetInventoryItemTexture("target", slot) }
            any = true
        end
    end
    if any or not self.gear[name] then self.gear[name] = gear end
    if C.renderers.armory then C.renderers.armory() end
end

C.builders.armory = function(p)
    local name = C.Label(p, 15)
    name:SetPoint("TOPLEFT", p, "TOPLEFT", 2, -2)
    p.name = name
    local info = C.Label(p, 11)
    info:SetPoint("TOPLEFT", p, "TOPLEFT", 2, -24)
    info:SetWidth(330)
    info:SetJustifyV("TOP")
    p.info = info

    p.slots = {}
    local function slot(id, x, y)
        local box = UI.IconBox(p, 30)
        box:SetPoint("TOPLEFT", p, "TOPLEFT", x, y)
        box:EnableMouse(true)
        box.slot = id
        box:SetScript("OnEnter", function()
            if not GameTooltip then return end
            GameTooltip:SetOwner(box, "ANCHOR_RIGHT")
            local g = C.selected and C.gear[C.selected]
            local it = g and g[id]
            local s = it and itemString(it.link)
            if s and GameTooltip.SetHyperlink then GameTooltip:SetHyperlink(s)
            else GameTooltip:SetText(C.SLOT_NAMES[id] .. (it and "" or ": empty or not inspected"), 1, 1, 1) end
            GameTooltip:Show()
        end)
        box:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
        p.slots[id] = box
    end
    for i, id in ipairs(LEFT_SLOTS) do slot(id, 380, -2 - (i - 1) * 34) end
    for i, id in ipairs(RIGHT_SLOTS) do slot(id, 640, -2 - (i - 1) * 34) end
    for i, id in ipairs(LOW_SLOTS) do slot(id, 474 + (i - 1) * 40, -238) end

    local gearNote = C.Label(p, 10, UI.MUTED)
    gearNote:SetPoint("TOPLEFT", p, "TOPLEFT", 420, -4)
    gearNote:SetWidth(210)
    gearNote:SetJustifyH("CENTER")
    p.gearNote = gearNote

    local status = C.Label(p, 11, UI.ACCENT)
    status:SetPoint("TOPLEFT", p, "TOPLEFT", 2, -292)
    status:SetWidth(C.WIDTH - 30)
    p.status = status

    local ins = C.Btn(p, "Inspect", 100, function() if need() then C:TryInspect(true) end end)
    ins:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -312)
    local go = C.Btn(p, "Go to them", 110, function() local n = need(); if n then A.appear(n) end end)
    go:SetPoint("LEFT", ins, "RIGHT", 6, 0)
    p.go = go
    local full = C.Btn(p, "Full inspect", 110, function()
        if C.selected and C:CanInspect(C.selected) and InspectUnit then InspectUnit("target") end
    end)
    full:SetPoint("LEFT", go, "RIGHT", 6, 0)
    p.full = full
    -- the website's armory page, from Social's armory settings when Social is loaded
    local web = C.Btn(p, "Armory page", 110, function()
        local n = need()
        if not n then return end
        local S = Social
        if not (S and S.ARMORY_SITE and S.ArmorySlug) then return end
        local url = S.ARMORY_SITE .. "?r=" .. S.ArmorySlug(GetRealmName and GetRealmName() or "") .. "&n=" .. n
        UI.Prompt({ title = n .. "'s armory page", maxLetters = 255, accept = "Done", default = url,
            text = "Shown only if they keep it public. Ctrl+C to copy.", onAccept = function() end })
    end)
    web:SetPoint("LEFT", full, "RIGHT", 6, 0)
    p.web = web
end

local STATE = { [0] = "Alive", [1] = "Dead", [2] = "Ghost" }

C.renderers.armory = function()
    local p = C.pages.armory
    local n = C.selected
    local q = n and C.byName[n]
    if not n then
        p.name:SetText("Nobody picked")
        p.name:SetTextColor(1, 1, 1)
        p.info:SetText("Pick a player on the Players tab or the Map.")
    else
        p.name:SetText(n)
        p.name:SetTextColor(UI.ClassColor(q and q.class))
        if q then
            local lines = {
                "Level " .. q.level .. " " .. q.raceName .. " " .. q.className,
                q.guild ~= "" and ("Guild: <" .. q.guild .. ">") or "No guild",
                "Gold: " .. UI.CoinText(q.copper),
                "Where: " .. q.zoneName .. format(" (%.0f, %.0f, %.0f, map %d)", q.x, q.y, q.z, q.map),
                "Health: " .. q.hp .. " / " .. q.maxhp .. "    " .. (C.POWER[q.powerType] or "Power") .. ": " .. q.power .. " / " .. q.maxpower,
                "State: " .. (STATE[q.state] or "Alive") .. (q.combat == 1 and ", in combat" or "") .. (q.gmOn == 1 and ", GM mode on" or ""),
                "Account: " .. q.account .. (q.accountLevel > 0 and (" (GM level " .. q.accountLevel .. ")") or ""),
                "Ping: " .. q.latency .. " ms",
                "Muted: " .. (q.mutedSec > 0 and W.Clock(q.mutedSec) or "no"),
                "Address: " .. (q.ip ~= "" and C.MaskIp(q.ip) or "unknown") .. (q.sameIp and ("  (same as " .. table.concat(q.sameIp, ", ") .. ")") or ""),
            }
            p.info:SetText(table.concat(lines, "\n"))
        else
            p.info:SetText("Not in the world right now.")
        end
    end
    local gear = n and C.gear[n]
    for id, box in pairs(p.slots) do
        local it = gear and gear[id]
        if it and it.tex then box.icon:SetTexture(it.tex) box.icon:SetAlpha(1)
        else box.icon:SetTexture("Interface\\PaperDoll\\UI-Backpack-EmptySlot") box.icon:SetAlpha(0.35) end
    end
    local near = n and C:CanInspect(n)
    if not n then
        p.status:SetText("")
        p.gearNote:SetText("")
    elseif near then
        p.status:SetText(gear and "In range: gear from the inspect just now." or "In range: press Inspect to read their gear.")
        p.gearNote:SetText("Equipped")
    else
        p.status:SetText("Go to them to inspect (.appear)" .. (gear and "  -  the gear shown is from your last inspect." or ""))
        p.gearNote:SetText(gear and "Equipped (last inspect)" or "Not inspected yet")
    end
    if near then p.full:Show() else p.full:Hide() end
    if Social and Social.ARMORY_SITE then p.web:Show() else p.web:Hide() end
end

C.onShowPage.armory = function() C:TryInspect(false) end
C.onShowPage.players = function() C:Render() end
