--[[
    Log.lua  -  Quests: the two-pane quest log.

    L, the micro menu's quest button and anything else that opens the stock QuestLogFrame open
    this window instead (the classic log stays one setting away: Options > "Open with L").
      top bar   tabs (Quests, Nearby when the realm lists quests to pick up, Completed, Options),
                search, Filter, Sort and the "12/20" quest count
      left      quests grouped by zone (click a zone to fold it), level tags, difficulty colours,
                tags (Elite, Dungeon, Raid, Class), progress "3/8", a gold check when complete,
                a red cross when failed
      right     the selected quest (LogDetail.lua)
      buttons   Track, Show on map, Share, Abandon (asks first, then 10 seconds to undo)
    Keys while the pointer is over the window: Up/Down move the selection, Enter tracks,
    L or Escape close. Shift-click a quest to put its name in chat.
]]--

local W = WenillaCore
local UI = W.UI
local Q = Compass

local Log = Q.Log or {}
Q.Log = Log
Log.page = "quests"
Log.search = ""

local WIDTH, HEIGHT = 704, 474
local LIST_W, LIST_H = 262, 360

local win = UI.Window("Compass_Log", { classicFrame = true,
    width = WIDTH, height = HEIGHT, title = "Quest Log", icon = "Interface\\Icons\\INV_Misc_Book_08",
    point = { "TOPLEFT", UIParent, "TOPLEFT", 36, -104 }, titleAlign = "LEFT", skin = true,
})
win:SetFrameStrata("HIGH")
win:Hide()
table.insert(UISpecialFrames, "Compass_Log")
Log.win = win

-- -- Small flat button (house style) ----------------------------------------------------------

function Log.Flat(parent, name, text, width, onClick)
    local b = CreateFrame("Button", name, parent)
    UI.Skin(b, "raised")
    b:SetWidth(width or 70)
    b:SetHeight(20)
    b.label = UI.Label(b, 10, { 0.95, 0.93, 0.88 }, "OUTLINE")
    b.label:SetPoint("CENTER", b, "CENTER", 0, 0)
    b.label:SetJustifyH("CENTER")
    b.SetText = function(self, t) self.label:SetText(t); self.text = t end
    b:SetText(text)
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetPoint("TOPLEFT", b, "TOPLEFT", 2, -2)
    hl:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -2, 2)
    hl:SetTexture(1, 0.82, 0, 0.12)
    b.SetDisabled = function(self, off)
        if off then self:Disable(); self.label:SetTextColor(0.45, 0.45, 0.48) else self:Enable(); self.label:SetTextColor(0.95, 0.93, 0.88) end
    end
    if onClick then b:SetScript("OnClick", onClick) end
    return b
end

-- -- Top bar --------------------------------------------------------------------------------------

local TABS = {
    { key = "quests", label = "Quests" }, { key = "nearby", label = "Nearby" },
    { key = "history", label = "Completed" }, { key = "options", label = "Options" },
}

local tabs = UI.Tabs(win, { tabs = TABS, height = 20, skin = true, onSelect = function(key) Log:SetPage(key) end })
tabs:SetPoint("TOPLEFT", win, "TOPLEFT", 10, -30)
Log.tabs = tabs

local count = UI.Label(win, 11, UI.ACCENT, "OUTLINE")
count:SetPoint("TOPRIGHT", win, "TOPRIGHT", -14, -34)
count:SetJustifyH("RIGHT")
Log.count = count

local SORTS = { { "zone", "Zone" }, { "level", "Level" }, { "distance", "Distance" }, { "progress", "Progress" } }

local sortBtn = Log.Flat(win, "Compass_LogSort", "Sort: Zone", 92, function()
    local items = { { text = "Sort quests by", title = true } }
    for _, s in ipairs(SORTS) do
        local key = s[1]
        table.insert(items, { text = s[2], checked = Q:Get("sortBy") == key, func = function()
            Q:Set("sortBy", key, true)
            Log:Refresh()
        end })
    end
    UI.Menu(this, items)
end)
sortBtn:SetPoint("RIGHT", count, "LEFT", -12, 0)

local FILTERS = {
    { "filterZone", "Only this zone" }, { "filterComplete", "Only complete" },
    { "filterGroup", "Group quests" }, { "filterDungeon", "Dungeons and raids" },
}

local filterBtn = Log.Flat(win, "Compass_LogFilter", "Filter", 66, function()
    local items = { { text = "Show", title = true } }
    for _, f in ipairs(FILTERS) do
        local key = f[1]
        table.insert(items, { text = f[2], checked = Q:Get(key) and true or false, func = function()
            Q:Set(key, not Q:Get(key), true)
            Log:Refresh()
        end })
    end
    table.insert(items, { text = "Low level (grey)", title = true })
    table.insert(items, { text = "Hide grey quests", checked = Q:Get("hideGrey") and true or false, func = function()
        Q:Set("hideGrey", not Q:Get("hideGrey"))
        Log:Refresh()
    end })
    local greys = Log:GreyQuests()
    table.insert(items, { text = "Abandon all grey quests (" .. table.getn(greys) .. ")...", disabled = not greys[1],
        func = function() Log:AskAbandonGreys() end })
    UI.Menu(this, items)
end)
filterBtn:SetPoint("RIGHT", sortBtn, "LEFT", -6, 0)

local search = UI.SearchBox(win, { name = "Compass_LogSearch", width = 150, placeholder = "Search quests",
    onChange = function(t) Log.search = t or ""; Log:Refresh() end })
search:SetPoint("RIGHT", filterBtn, "LEFT", -8, 0)
search:SetScript("OnEditFocusGained", function() Log.typing = true end)
search:SetScript("OnEditFocusLost", function() Log.typing = nil end)
Log.searchBox = search

-- -- Left: the list ---------------------------------------------------------------------------------

local listBg = CreateFrame("Frame", nil, win)
UI.Skin(listBg, "inset")
listBg:SetPoint("TOPLEFT", win, "TOPLEFT", 8, -54)
listBg:SetWidth(LIST_W + 8)
listBg:SetHeight(LIST_H + 8)
Log.listBg = listBg

local empty = UI.Label(listBg, 11, UI.MUTED)
empty:SetPoint("TOP", listBg, "TOP", 0, -40)
empty:SetWidth(LIST_W - 30)
empty:SetJustifyH("CENTER")
Log.empty = empty

local function buildRow(row)
    row.sel = row:CreateTexture(nil, "BACKGROUND")
    row.sel:SetAllPoints(row)
    row.sel:SetTexture(1, 0.82, 0, 0.14)
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(row)
    hl:SetTexture(1, 1, 1, 0.06)
    row.mark = row:CreateTexture(nil, "ARTWORK")     -- tracked: a thin gold bar
    row.mark:SetWidth(2)
    row.mark:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -2)
    row.mark:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 2)
    row.mark:SetTexture(1, 0.82, 0, 0.9)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetWidth(12)
    row.icon:SetHeight(12)
    row.icon:SetPoint("LEFT", row, "LEFT", 4, 0)
    row.level = UI.Label(row, 10, nil, "OUTLINE")
    row.level:SetPoint("LEFT", row, "LEFT", 19, 0)
    row.level:SetWidth(30)
    row.title = UI.Label(row, 11, nil, nil)
    row.title:SetPoint("LEFT", row, "LEFT", 48, 0)
    row.title:SetWidth(LIST_W - 96)
    row.title:SetHeight(14)
    if row.title.SetNonSpaceWrap then row.title:SetNonSpaceWrap(false) end
    row.right = UI.Label(row, 10, nil, "OUTLINE")
    row.right:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row.right:SetJustifyH("RIGHT")
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnClick", function() Log:ClickItem(this.item, arg1) end)
end

local function updateRow(row, item)
    row.icon:Hide()
    row.mark:Hide()
    row.sel:Hide()
    row.level:SetText("")
    row.right:SetText("")
    row.title:ClearAllPoints()
    if item.header then
        row.icon:SetTexture(item.collapsed and "Interface\\Buttons\\UI-PlusButton-Up" or "Interface\\Buttons\\UI-MinusButton-Up")
        row.icon:SetTexCoord(0, 1, 0, 1)
        row.icon:Show()
        row.title:SetPoint("LEFT", row, "LEFT", 19, 0)
        row.title:SetText(item.zone)
        row.title:SetTextColor(UI.ACCENT[1], UI.ACCENT[2], UI.ACCENT[3])
        row.right:SetText(item.count)
        row.right:SetTextColor(UI.MUTED[1], UI.MUTED[2], UI.MUTED[3])
        return
    end
    row.title:SetPoint("LEFT", row, "LEFT", 48, 0)
    if item.quest then
        local q = item.quest
        if Log.selected == q.key and Log.page == "quests" then row.sel:Show() end
        if Q:IsTracked(q.key) then row.mark:Show() end
        local r, g, b = Q:DiffColor(q.level)
        row.level:SetText("[" .. q.level .. "]")
        row.level:SetTextColor(r, g, b)
        local tagText = table.concat(Q:Tags(q), ", ")
        row.title:SetText(q.title .. (tagText ~= "" and ("  |cff8a8f9a" .. tagText .. "|r") or ""))
        row.title:SetTextColor(r, g, b)
        if Log:IsAbandoning(q.title) then
            row.right:SetText("Abandoning")
            row.right:SetTextColor(1, 0.45, 0.35)
        elseif q.failed then
            row.icon:SetTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
            row.icon:SetTexCoord(0, 1, 0, 1)
            row.icon:Show()
            row.right:SetText("Failed")
            row.right:SetTextColor(1, 0.3, 0.25)
        elseif q.complete then
            row.icon:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
            row.icon:SetTexCoord(0, 1, 0, 1)
            row.icon:Show()
            row.right:SetText("Done")
            row.right:SetTextColor(1, 0.82, 0)
        else
            row.right:SetText(q.done .. "/" .. q.total)
            row.right:SetTextColor(0.85, 0.85, 0.88)
        end
    elseif item.nearby then
        local e = item.nearby
        if Log.selected == "nearby:" .. e.title then row.sel:Show() end
        local r, g, b = Q:DiffColor(e.level)
        row.level:SetText("[" .. e.level .. "]")
        row.level:SetTextColor(r, g, b)
        row.title:SetText(e.title)
        row.title:SetTextColor(r, g, b)
        if e.dist then
            row.right:SetText(Q:YardText(e.dist))
            row.right:SetTextColor(0.85, 0.85, 0.88)
        end
    elseif item.history then
        local h = item.history
        if Log.selected == item.id then row.sel:Show() end
        row.level:SetText("[" .. (h.level or 0) .. "]")
        row.level:SetTextColor(0.7, 0.7, 0.72)
        row.title:SetText(h.title)
        if h.how == "abandoned" then row.title:SetTextColor(0.85, 0.55, 0.5) else row.title:SetTextColor(0.9, 0.9, 0.9) end
        row.right:SetText(date("%d %b", h.t or 0))
        row.right:SetTextColor(UI.MUTED[1], UI.MUTED[2], UI.MUTED[3])
    end
end

local list = UI.ScrollList(listBg, { name = "Compass_LogList", width = LIST_W, height = LIST_H, rowHeight = 18,
    build = buildRow, update = updateRow })
list:SetPoint("TOPLEFT", listBg, "TOPLEFT", 4, -4)
Log.list = list

-- -- Building the list ---------------------------------------------------------------------------

function Log:Matches(q)
    local s = self.search or ""
    if s ~= "" then
        local hit = Q:Has(q.title, s) or Q:Has(q.zone, s)
        if not hit then
            for _, o in ipairs(q.objectives) do if Q:Has(o.text, s) then hit = true end end
        end
        if not hit then return false end
    end
    if Q:Get("filterZone") and q.zone ~= Q:Zone() then return false end
    if Q:Get("filterComplete") and not q.complete then return false end
    if Q:Get("filterGroup") and not q.group then return false end
    if Q:Get("filterDungeon") and not (q.dungeon or q.raid) then return false end
    if Q:Get("hideGrey") and Q:IsGrey(q.level) and not q.complete then return false end
    return true
end

local function questSort(by)
    return function(a, b)
        if by == "distance" then
            local da, db = a.sortDist or 1e9, b.sortDist or 1e9
            if da ~= db then return da < db end
        elseif by == "progress" then
            local pa, pb = a.complete and 2 or a.progress, b.complete and 2 or b.progress
            if pa ~= pb then return pa > pb end
        end
        if a.level ~= b.level then return a.level < b.level end
        return a.title < b.title
    end
end

function Log:QuestItems()
    local by = Q:Get("sortBy") or "zone"
    local shown = {}
    for _, q in ipairs(Q.quests) do
        if self:Matches(q) then
            if by == "distance" then
                local _, d = Q:BestNode(q.key)
                q.sortDist = d
            end
            table.insert(shown, q)
        end
    end
    local items = {}
    if by ~= "zone" then
        table.sort(shown, questSort(by))
        for _, q in ipairs(shown) do table.insert(items, { quest = q }) end
        return items, table.getn(shown)
    end
    -- grouped by zone: the zone you are in first, then alphabetical
    local zones, byZone = {}, {}
    for _, q in ipairs(shown) do
        if not byZone[q.zone] then
            byZone[q.zone] = {}
            table.insert(zones, q.zone)
        end
        table.insert(byZone[q.zone], q)
    end
    local here = Q:Zone()
    table.sort(zones, function(a, b)
        if (a == here) ~= (b == here) then return a == here end
        return a < b
    end)
    local db = Q:DB()
    local searching = (self.search or "") ~= ""
    for _, z in ipairs(zones) do
        local qs = byZone[z]
        table.sort(qs, questSort("level"))
        local collapsed = db.zones[z] and not searching
        table.insert(items, { header = true, zone = z, count = table.getn(qs), collapsed = collapsed })
        if not collapsed then
            for _, q in ipairs(qs) do table.insert(items, { quest = q }) end
        end
    end
    return items, table.getn(shown)
end

function Log:HistoryItems()
    local items = {}
    for i, h in ipairs(Q:DB().history) do
        if (self.search or "") == "" or Q:Has(h.title, self.search) or Q:Has(h.zone, self.search) then
            table.insert(items, { history = h, id = "history:" .. i })
        end
    end
    return items
end

function Log:NearbyItems()
    local items = {}
    local px, py = Q:PlayerPos()
    for _, e in ipairs(Q.nearby) do
        if (self.search or "") == "" or Q:Has(e.title, self.search) then
            e.dist = (px ~= 0 or py ~= 0) and Q:Yards(px, py, e.x, e.y, e.zone) or nil
            table.insert(items, { nearby = e })
        end
    end
    table.sort(items, function(a, b) return (a.nearby.dist or 1e9) < (b.nearby.dist or 1e9) end)
    return items
end

-- -- Refresh ------------------------------------------------------------------------------------------

function Log:SetTabs()
    local t = {}
    for _, tab in ipairs(TABS) do
        if tab.key ~= "nearby" or Q.nearby[1] then table.insert(t, tab) end
    end
    tabs:SetTabs(t)
    if self.page == "nearby" and not Q.nearby[1] then self.page = "quests" end
    tabs:Select(self.page, true)
end

function Log:Refresh()
    if not win:IsShown() then return end
    count:SetText(Q.numQuests .. "/" .. Q.MAX_QUESTS)
    local sortLabel = "Zone"
    for _, s in ipairs(SORTS) do if s[1] == Q:Get("sortBy") then sortLabel = s[2] end end
    sortBtn:SetText("Sort: " .. sortLabel)
    local nf = 0
    for _, f in ipairs(FILTERS) do if Q:Get(f[1]) then nf = nf + 1 end end
    if Q:Get("hideGrey") then nf = nf + 1 end
    filterBtn:SetText(nf > 0 and ("Filter (" .. nf .. ")") or "Filter")
    local items, n
    if self.page == "history" then
        items = self:HistoryItems()
        empty:SetText(items[1] and "" or "Quests you turn in or abandon are listed here, newest first.")
    elseif self.page == "nearby" then
        items = self:NearbyItems()
        empty:SetText(items[1] and "" or "The realm lists no quests to pick up here.")
    else
        items, n = self:QuestItems()
        if Q.numQuests == 0 then
            empty:SetText("Your quest log is empty.\nQuest givers have a gold ! over their heads.")
        elseif n == 0 then
            empty:SetText("No quests match. Clear the search or the filters.")
        else
            empty:SetText("")
        end
        -- keep a valid selection
        if not (self.selected and Q.byKey[self.selected]) then
            self.selected = nil
            for _, it in ipairs(items) do
                if it.quest then self.selected = it.quest.key break end
            end
        end
    end
    self.items = items
    list:SetItems(items)
    if self.UpdateDetail then self:UpdateDetail() end
end

function Log:SetPage(key)
    self.page = key
    if key == "options" then
        listBg:Hide()
        if self.detail then self.detail:Hide() end
        if self.options then self.options:Show() end
        if self.buttons then self.buttons:Hide() end
    else
        listBg:Show()
        if self.detail then self.detail:Show() end
        if self.options then self.options:Hide() end
        if self.buttons then self.buttons:Show() end
        if key == "history" or key == "nearby" then
            self.selected = nil
            local items = (key == "history") and self:HistoryItems() or self:NearbyItems()
            local first = items[1]
            if first then self.selected = first.id or ("nearby:" .. first.nearby.title) end
        else
            self.selected = nil
        end
    end
    tabs:Select(key, true)
    list.offset = 0
    self:Refresh()
end

-- -- Clicks and keys ----------------------------------------------------------------------------------

function Log:Select(key)
    self.selected = key
    self:Refresh()
    self:ScrollToSelection()
end

function Log:ScrollToSelection()
    for i, it in ipairs(self.items or {}) do
        local key = it.quest and it.quest.key or it.id or (it.nearby and ("nearby:" .. it.nearby.title))
        if key == self.selected then
            if i <= list.offset then list.offset = i - 1
            elseif i > list.offset + list.visibleRows then list.offset = i - list.visibleRows end
            list:Refresh()
            return
        end
    end
end

function Log:ClickItem(item, button)
    if not item then return end
    if item.header then
        local db = Q:DB()
        db.zones[item.zone] = (not db.zones[item.zone]) and true or nil
        self:Refresh()
        return
    end
    if item.quest then
        local q = item.quest
        if button == "RightButton" then return Q:QuestMenu(this, q.key) end
        if IsShiftKeyDown() then
            if not Q:InsertChat("[" .. q.title .. "]") then self:Select(q.key) end
            return
        end
        if IsControlKeyDown() then return Q:SetTracked(q.key, not Q:IsTracked(q.key)) end
        self:Select(q.key)
    elseif item.nearby then
        self:Select("nearby:" .. item.nearby.title)
    elseif item.history then
        if IsShiftKeyDown() and Q:InsertChat("[" .. item.history.title .. "]") then return end
        self:Select(item.id)
    end
end

-- Move the selection among the selectable rows (headers are skipped).
function Log:Move(delta)
    local keys = {}
    local at
    for _, it in ipairs(self.items or {}) do
        local key = it.quest and it.quest.key or it.id or (it.nearby and ("nearby:" .. it.nearby.title))
        if key then
            table.insert(keys, key)
            if key == self.selected then at = table.getn(keys) end
        end
    end
    if not keys[1] then return end
    local n = table.getn(keys)
    local nxt = at and (at + delta) or 1
    if nxt < 1 then nxt = 1 elseif nxt > n then nxt = n end
    self:Select(keys[nxt])
end

function Log:OnKey(key)
    if key == "UP" then self:Move(-1)
    elseif key == "DOWN" then self:Move(1)
    elseif key == "PAGEUP" then self:Move(-10)
    elseif key == "PAGEDOWN" then self:Move(10)
    elseif key == "ENTER" then
        local q = self.page == "quests" and Q.byKey[self.selected or ""]
        if q then Q:SetTracked(q.key, not Q:IsTracked(q.key)); self:Refresh() end
    elseif key == "ESCAPE" or key == "L" then
        self:Close()
    end
end

-- The keyboard is taken only while the pointer is over the window, so walking keys still work
-- with the log open.
win:SetScript("OnKeyDown", function() Log:OnKey(arg1) end)
win:SetScript("OnUpdate", function()
    local over = MouseIsOver and MouseIsOver(win) and not Log.typing
    if over ~= Log.keyboard then
        Log.keyboard = over
        win:EnableKeyboard(over and true or false)
    end
end)
win:SetScript("OnShow", function()
    if PlaySound then PlaySound("igQuestLogOpen") end
    Log:SetTabs()
    Log:Refresh()
end)
win:SetScript("OnHide", function()
    if PlaySound then PlaySound("igQuestLogClose") end
    win:EnableKeyboard(false)
    Log.keyboard = nil
end)

-- -- Open / close / takeover --------------------------------------------------------------------------

function Log:Open(key)
    if not Q:Active() then return end
    Q:ScanLog()
    if key and self.page ~= "quests" then self:SetPage("quests") end
    if key then self.selected = key end
    if win:IsShown() then
        self:SetTabs()
        self:Refresh()
    else
        win:Show()          -- OnShow refreshes
    end
    if key then self:ScrollToSelection() end
end

function Log:Close() win:Hide() end

function Log:Toggle()
    if win:IsShown() then self:Close() else self:Open() end
end

function Log:IsOpen() return win:IsShown() and true or false end

function Q:LogTakesOver() return self:Active() and self:Get("replaceLog") and not self.allowStock end

-- Open Blizzard's own quest log once (the Options page has a button for it).
function Q:OpenStockLog()
    self.allowStock = true
    Log:Close()
    if QuestLogFrame then
        if ShowUIPanel then ShowUIPanel(QuestLogFrame) else QuestLogFrame:Show() end
    end
    self.allowStock = nil
end

local stockToggle = ToggleQuestLog
function ToggleQuestLog()
    if Q:LogTakesOver() then
        Log:Toggle()
    elseif stockToggle then
        stockToggle()
    end
end

if QuestLogFrame then
    local stockShow = QuestLogFrame:GetScript("OnShow")
    QuestLogFrame:SetScript("OnShow", function()
        if Q:LogTakesOver() then
            local sel = GetQuestLogSelection and GetQuestLogSelection()
            if HideUIPanel then HideUIPanel(QuestLogFrame) else QuestLogFrame:Hide() end
            local title = sel and sel > 0 and GetQuestLogTitle(sel)
            Log:Open(title and Q:FindQuest(title) and Q:FindQuest(title).key or nil)
            return
        end
        if stockShow then stockShow() end
    end)
end

Q:Listen("QuestsChanged", function() Log:Refresh() end)
Q:Listen("TrackingChanged", function() Log:Refresh() end)
Q:Listen("NearbyChanged", function() if win:IsShown() then Log:SetTabs(); Log:Refresh() end end)
Q:OnRefresh(function(active)
    if not active then Log:Close() elseif win:IsShown() then Log:Refresh() end
end)
