--[[
    Journal.lua  (Open Vanilla)
    The three windows the modern menu bar adds (MicroMenu.lua):

      Professions      your professions and secondary skills with their rank, and a button that opens
                       each one's window (Mining opens Smelting). Retail's K.
      Collections      Mounts and Pets: what you carry, what you left in the bank (remembered from
                       your last visit) and the mounts your class summons. Click to ride or summon.
                       Appearances joins as a third tab on realms with Transmog.
      Adventure Guide  dungeons and raids: suggested for your level, then every one with its entrance,
                       a map pin, a waypoint and "Find a group". Data from the Dungeons addon.

    Lua 5.0 rules (no #, no string.match).
]]--

local W = WenillaCore
local UI = W.UI
local MM = W.MicroMenu
local getn, tinsert = table.getn, table.insert
local MUTED = { 0.62, 0.64, 0.70 }

local function window(name, title, icon, w, h)
    local f = UI.Window(name, { width = w, height = h, title = title, icon = icon, skin = true, classicFrame = true,
        point = { "TOPLEFT", UIParent, "TOPLEFT", 40, -104 } })
    f:Hide()
    if UISpecialFrames then tinsert(UISpecialFrames, name) end
    return f
end

local function toggle(f, refresh)
    if f:IsShown() then f:Hide() else refresh(); f:Show(); if PlaySound then PlaySound("igCharacterInfoOpen") end end
end

-- ==== Professions ====================================================================================

local PROF = {
    -- name = { icon, the spell that opens its window (false: a gathering skill, no window) }
    ["Alchemy"]        = { "Trade_Alchemy", "Alchemy" },
    ["Blacksmithing"]  = { "Trade_BlackSmithing", "Blacksmithing" },
    ["Enchanting"]     = { "Trade_Engraving", "Enchanting" },
    ["Engineering"]    = { "Trade_Engineering", "Engineering" },
    ["Leatherworking"] = { "INV_Misc_ArmorKit_17", "Leatherworking" },
    ["Tailoring"]      = { "Trade_Tailoring", "Tailoring" },
    ["Mining"]         = { "Trade_Mining", "Smelting" },
    ["Herbalism"]      = { "INV_Misc_Flower_02", false },
    ["Skinning"]       = { "INV_Misc_Pelt_Wolf_01", false },
    ["Cooking"]        = { "INV_Misc_Food_15", "Cooking" },
    ["First Aid"]      = { "Spell_Holy_SealOfSacrifice", "First Aid" },
    ["Fishing"]        = { "Trade_Fishing", false },
}
local RANKS = { { 75, "Apprentice" }, { 150, "Journeyman" }, { 225, "Expert" }, { 300, "Artisan" } }
local function rankName(max)
    for _, r in ipairs(RANKS) do if (max or 0) <= r[1] then return r[2] end end
    return "Artisan"
end

local P = {}
MM.Professions = P

-- Your skill lines under the Professions and Secondary Skills headers.
function P:Read()
    local out = { primary = {}, secondary = {} }
    local section
    local n = GetNumSkillLines and GetNumSkillLines() or 0
    for i = 1, n do
        local name, header, _, rank, _, mod, max = GetSkillLineInfo(i)
        if header then
            section = (name == "Professions" and "primary") or (name == "Secondary Skills" and "secondary") or nil
        elseif section and name and PROF[name] then
            tinsert(out[section], { name = name, rank = (rank or 0) + (mod or 0), max = max or 0,
                icon = "Interface\\Icons\\" .. PROF[name][1], open = PROF[name][2] })
        end
    end
    return out
end

-- A skill bar as the character sheet's Skills page draws one: a dark track, a blue fill, the stock
-- rounded rim, and the rank on it.
local function skillBar(parent)
    local b = CreateFrame("Frame", nil, parent)
    b:SetHeight(12)
    b.track = b:CreateTexture(nil, "BACKGROUND")
    b.track:SetAllPoints(b)
    b.track:SetTexture(0.03, 0.03, 0.05, 0.9)
    b.fill = b:CreateTexture(nil, "ARTWORK")
    b.fill:SetTexture("Interface\\TargetingFrame\\UI-StatusBar")
    b.fill:SetVertexColor(0.16, 0.38, 0.92)
    b.fill:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
    b.fill:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 0, 0)
    b.rim = b:CreateTexture(nil, "OVERLAY")
    b.rim:SetTexture("Interface\\PaperDollInfoFrame\\UI-Character-Skills-BarBorder")
    b.rim:SetTexCoord(2 / 256, 255 / 256, 6 / 32, 25 / 32)
    b.rim:SetPoint("TOPLEFT", b, "TOPLEFT", -4, 4)
    b.rim:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 4, -4)
    local tl = CreateFrame("Frame", nil, b)
    tl:SetAllPoints(b)
    tl:SetFrameLevel(b:GetFrameLevel() + 2)
    b.text = UI.Label(tl, 10, { 1, 1, 1 }, "OUTLINE")
    b.text:SetPoint("CENTER", b, "CENTER", 0, 0)
    function b:Set(rank, max)
        local w = (self:GetWidth() or 100)
        local f = (max and max > 0) and math.min(1, rank / max) or 0
        if f <= 0 then self.fill:Hide() else self.fill:Show(); self.fill:SetWidth(math.max(1, w * f)) end
        self.text:SetText(rank .. " / " .. max)
    end
    return b
end

local function slab(f)
    local t = f:CreateTexture(nil, "BACKGROUND")
    t:SetAllPoints(f)
    t:SetTexture(1, 1, 1, 0.035)
    return t
end

local function profRow(parent)
    local r = CreateFrame("Frame", nil, parent)
    r:SetHeight(42)
    r.bg = slab(r)
    r.box = UI.IconBox(r, 34)
    r.box:SetPoint("LEFT", r, "LEFT", 4, 0)
    r.name = UI.Label(r, 12, UI.GOLD)
    r.name:SetPoint("TOPLEFT", r.box, "TOPRIGHT", 8, -2)
    r.title = UI.Label(r, 10, MUTED)
    r.title:SetPoint("LEFT", r.name, "RIGHT", 6, 0)
    r.open = UI.Button(r, "Open", 64, 22)
    r.open:SetPoint("RIGHT", r, "RIGHT", -6, 0)
    r.bar = skillBar(r)
    r.bar:SetPoint("BOTTOMLEFT", r.box, "BOTTOMRIGHT", 10, 3)
    r.bar:SetWidth(176)
    return r
end

function P:Build()
    if self.frame then return self.frame end
    local f = window("OVProfessionsFrame", "Professions", "Interface\\Icons\\Trade_BlackSmithing", 330, 330)
    f.heads, f.rows = {}, {}
    f.empty = UI.Label(f, 11, MUTED)
    f.empty:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -60)
    f.empty:SetWidth(298)
    f.empty:SetJustifyH("LEFT")
    f.empty:SetText("You haven't learned a profession yet. Every capital has trainers who teach them, and the guards can point the way.")
    self.frame = f
    return f
end

function P:Refresh()
    local f = self:Build()
    local data = self:Read()
    local y, n = -32, 0
    local function head(i, text)
        local h = f.heads[i]
        if not h then
            h = UI.Label(f, 12, { 1, 1, 1 })
            h.rule = f:CreateTexture(nil, "ARTWORK")
            h.rule:SetHeight(1)
            h.rule:SetTexture(0.5, 0.42, 0.2, 0.7)
            f.heads[i] = h
        end
        h:ClearAllPoints()
        h:SetPoint("TOPLEFT", f, "TOPLEFT", 14, y)
        h:SetText(text)
        h:Show()
        h.rule:ClearAllPoints()
        h.rule:SetPoint("TOPLEFT", f, "TOPLEFT", 14, y - 16)
        h.rule:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, y - 16)
        h.rule:Show()
        y = y - 24
    end
    local function rows(list)
        for _, p in ipairs(list) do
            n = n + 1
            local r = f.rows[n] or profRow(f)
            f.rows[n] = r
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", f, "TOPLEFT", 14, y)
            r:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, y)
            r.box.icon:SetTexture(p.icon)
            r.name:SetText(p.name)
            r.title:SetText(rankName(p.max))
            r.bar:Set(p.rank, p.max)
            r.prof = p
            if p.open then
                local spell = p.open
                r.open:SetScript("OnClick", function() CastSpellByName(spell) end)
                r.open:Show()
            else
                r.open:Hide()
            end
            r:Show()
            y = y - 48
        end
    end
    for _, h in ipairs(f.heads) do h:Hide(); h.rule:Hide() end
    local hn = 0
    if getn(data.primary) > 0 then hn = hn + 1; head(hn, "Professions"); rows(data.primary) end
    if getn(data.secondary) > 0 then hn = hn + 1; head(hn, "Secondary Skills"); rows(data.secondary) end
    for i = n + 1, getn(f.rows) do f.rows[i]:Hide() end
    if n == 0 then f.empty:Show() else f.empty:Hide() end
    f:SetHeight(math.max(130, -y + 12))
    self.data = data
end

function P:Toggle() toggle(self:Build(), function() P:Refresh() end) end

-- ==== Collections ======================================================================================

-- What the 1.12 tooltips say on mounts and companion pets.
local MOUNT_TEXT = "summons and dismisses a rideable"
local PET_TEXT = "summon and dismiss your"
-- Mounts a class summons as a spell.
local MOUNT_SPELLS = {
    ["Summon Warhorse"] = "Spell_Nature_Swiftness", ["Summon Charger"] = "Ability_Mount_Charger",
    ["Summon Felsteed"] = "Spell_Nature_Swiftness", ["Summon Dreadsteed"] = "Ability_Mount_Dreadsteed",
}

local C = { page = "mounts" }
MM.Collections = C

local scan
local function tipLines(bag, slot)
    if not scan then
        scan = CreateFrame("GameTooltip", "OVCollectionsScan", UIParent, "GameTooltipTemplate")
        scan:SetOwner(UIParent, "ANCHOR_NONE")
    end
    scan:ClearLines()
    scan:SetOwner(UIParent, "ANCHOR_NONE")
    scan:SetBagItem(bag, slot)
    local text = ""
    for i = 1, (scan:NumLines() or 0) do
        local fs = getglobal("OVCollectionsScanTextLeft" .. i)
        local t = fs and fs:GetText()
        if t then text = text .. "\n" .. strlower(t) end
    end
    return text
end

local function itemId(link)
    if not link then return end
    local _, _, id = string.find(link, "item:(%d+)")
    return tonumber(id)
end
local function itemName(link)
    local _, _, name = string.find(link or "", "%[(.-)%]")
    return name
end

local function store()
    if type(OVCollections_Char) ~= "table" then OVCollections_Char = {} end
    local s = OVCollections_Char
    s.bank = s.bank or {}
    return s
end

-- One container's mounts and pets: id -> { name, icon, kind, bag, slot }.
local function scanBag(bag, out)
    local slots = GetContainerNumSlots and GetContainerNumSlots(bag) or 0
    for slot = 1, slots do
        local link = GetContainerItemLink and GetContainerItemLink(bag, slot)
        local id = itemId(link)
        if id and not out[id] then
            local text = tipLines(bag, slot)
            local kind = (string.find(text, MOUNT_TEXT, 1, true) and "mounts") or (string.find(text, PET_TEXT, 1, true) and "pets")
            if kind then
                local icon = GetContainerItemInfo(bag, slot)
                out[id] = { id = id, name = itemName(link) or ("Item " .. id), icon = icon, kind = kind, bag = bag, slot = slot }
            end
        end
    end
end

function C:ScanBags()
    local out = {}
    for bag = 0, 4 do scanBag(bag, out) end
    self.carried = out
    return out
end

-- At the bank: remember what's there, for when you're away from it.
function C:ScanBank()
    local out = {}
    scanBag(-1, out)
    for bag = 5, 10 do scanBag(bag, out) end
    local keep = {}
    for id, e in pairs(out) do keep[id] = { name = e.name, icon = e.icon, kind = e.kind } end
    store().bank = keep
end

function C:Spells()
    local out = {}
    if not (GetSpellName and BOOKTYPE_SPELL) then return out end
    local i = 1
    while true do
        local name = GetSpellName(i, BOOKTYPE_SPELL)
        if not name then break end
        if MOUNT_SPELLS[name] and not out[name] then
            out[name] = { name = name, icon = "Interface\\Icons\\" .. MOUNT_SPELLS[name],
                kind = "mounts", spell = name }
        end
        i = i + 1
    end
    return out
end

-- The page's entries: spells first, then carried, then banked; by name.
function C:Items(page)
    page = page or self.page
    local list, seen = {}, {}
    if page == "mounts" then
        for _, e in pairs(self:Spells()) do e.where = "Spell"; tinsert(list, e) end
    end
    for id, e in pairs(self.carried or self:ScanBags()) do
        if e.kind == page then seen[id] = true; e.where = "bags"; tinsert(list, e) end
    end
    for id, e in pairs(store().bank) do
        if e.kind == page and not seen[id] then
            tinsert(list, { id = id, name = e.name, icon = e.icon, kind = e.kind, where = "bank" })
        end
    end
    local order = { Spell = 1, bags = 2, bank = 3 }
    table.sort(list, function(a, b)
        if order[a.where] ~= order[b.where] then return order[a.where] < order[b.where] end
        return a.name < b.name
    end)
    return list
end

function C:Use(e)
    if e.spell then CastSpellByName(e.spell) return true end
    if e.where ~= "bags" then
        W.Print(e.name .. " is in your bank.")
        return false
    end
    for bag = 0, 4 do                       -- it may have moved since the scan
        for slot = 1, (GetContainerNumSlots(bag) or 0) do
            if itemId(GetContainerItemLink(bag, slot)) == e.id then UseContainerItem(bag, slot) return true end
        end
    end
    return false
end

local PAGES = {
    mounts = { title = "Mounts", icon = "Interface\\Icons\\Ability_Mount_RidingHorse",
        empty = "No mounts yet. Riding is taught at level 40, and every race's mount vendor sells them; paladins and warlocks summon theirs." },
    pets = { title = "Pets", icon = "Interface\\Icons\\INV_Box_PetCarrier_01",
        empty = "No companion pets yet. Vendors around the world sell them, and some come from quests and rare drops." },
}

function C:Build()
    if self.frame then return self.frame end
    local f = window("OVCollectionsFrame", "Collections", PAGES.mounts.icon, 360, 340)
    f.count = UI.Label(f, 11, MUTED)
    f.count:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -32)
    f.hint = UI.Label(f, 10, MUTED)
    f.hint:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, -32)
    f.hint:SetText("Click to use")
    f.list = UI.ScrollList(f, { width = 332, height = 274, rowHeight = 36,
        build = function(row)
            row.bg = slab(row)
            row.bg:ClearAllPoints()
            row.bg:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -1)
            row.bg:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 1)
            row.box = UI.IconBox(row, 30)
            row.box:SetPoint("LEFT", row, "LEFT", 2, 0)
            row.name = UI.Label(row, 12, { 1, 1, 1 })
            row.name:SetPoint("TOPLEFT", row.box, "TOPRIGHT", 8, -2)
            row.where = UI.Label(row, 10, MUTED)
            row.where:SetPoint("BOTTOMLEFT", row.box, "BOTTOMRIGHT", 8, 2)
            row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
            row:SetScript("OnClick", function() if this.item then C:Use(this.item) end end)
        end,
        update = function(row, e)
            row.box.icon:SetTexture(e.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            row.name:SetText(e.name)
            if e.where == "bank" then
                row.name:SetTextColor(0.6, 0.6, 0.6)
                row.box.icon:SetVertexColor(0.5, 0.5, 0.5)
                row.where:SetText("In your bank")
            else
                row.name:SetTextColor(1, 1, 1)
                row.box.icon:SetVertexColor(1, 1, 1)
                row.where:SetText(e.where == "Spell" and "Class spell" or "In your bags")
            end
        end })
    f.list:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -52)
    f.empty = UI.Label(f, 11, MUTED)
    f.empty:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -60)
    f.empty:SetWidth(326)
    f.empty:SetJustifyH("LEFT")
    self.frame = f
    return f
end

function C:Refresh()
    local f = self:Build()
    local pg = PAGES[self.page] or PAGES.mounts
    f.title:SetText(pg.title)
    if f.icon then f.icon:SetTexture(pg.icon) end
    self:ScanBags()
    local items = self:Items()
    f.list:SetItems(items)
    f.count:SetText(pg.title .. ": " .. getn(items))
    if getn(items) == 0 then f.empty:SetText(pg.empty); f.empty:Show(); f.hint:Hide() else f.empty:Hide(); f.hint:Show() end
end

function C:Show(page)
    self.page = page or self.page
    self:Refresh()
    self.frame:Show()
    MM:UpdateTabs()
end

local cev = CreateFrame("Frame", "OVCollections_Events")
cev:RegisterEvent("BAG_UPDATE")
cev:RegisterEvent("BANKFRAME_OPENED")
cev:RegisterEvent("PLAYERBANKSLOTS_CHANGED")
cev:SetScript("OnEvent", function()
    if event == "BANKFRAME_OPENED" or event == "PLAYERBANKSLOTS_CHANGED" then C:ScanBank() end
    if event == "BAG_UPDATE" and BankFrame and BankFrame:IsVisible() then C:ScanBank() end
    C.carried = nil
    if C.frame and C.frame:IsVisible() then C:Refresh() end
end)

-- ==== Adventure Guide =================================================================================

local G = { page = "suggested" }
MM.Guide = G

local function D() return Dungeons end

-- Up to three dungeons (raids at 60) for this level, nearest the middle of their range first; below
-- the first one, the next to open.
function G:Suggested(level)
    level = level or UnitLevel("player") or 1
    local fits = {}
    for _, d in ipairs(D().LIST) do
        if D().Fits(d, level) and (not d.raid or level >= 60) then tinsert(fits, d) end
    end
    table.sort(fits, function(a, b)
        local da, db = math.abs((a.min + a.max) / 2 - level), math.abs((b.min + b.max) / 2 - level)
        if da ~= db then return da < db end
        return a.order < b.order
    end)
    local out = {}
    for i = 1, math.min(3, getn(fits)) do tinsert(out, fits[i]) end
    if getn(out) == 0 then
        for _, d in ipairs(D().LIST) do if d.min > level then tinsert(out, d); break end end
    end
    return out
end

function G:List(raids)
    local out = {}
    for _, d in ipairs(D().LIST) do if (d.raid and true or false) == raids then tinsert(out, d) end end
    return out
end

local function findGroup(d)
    if MM:OpenHub("finder", "pve") then return end
    W.Print("Group Finder isn't on. Ask in the Looking for Group channel for " .. d.name .. ".")
end

local function actions(parent)
    local a = {}
    a.map = UI.Button(parent, "Show on map", 104, 22)
    a.way = UI.Button(parent, "Waypoint", 84, 22)
    a.find = UI.Button(parent, "Find a group", 104, 22)
    a.way:SetPoint("LEFT", a.map, "RIGHT", 4, 0)
    function a:Set(d)
        self.map:SetScript("OnClick", function() D():ShowOnMap(d) end)
        self.way:SetScript("OnClick", function() D():Waypoint(d) end)
        self.find:SetScript("OnClick", function() findGroup(d) end)
        if D():CanWaypoint() then self.way:Show() else self.way:Hide() end
        self.find:ClearAllPoints()
        self.find:SetPoint("LEFT", D():CanWaypoint() and self.way or self.map, "RIGHT", 4, 0)
    end
    return a
end

-- players a run is built for
local SIZE = { ubrs = 10, zg = 20, aq20 = 20, mc = 40, ony = 40, bwl = 40, aq40 = 40, naxx = 40 }
local function size(d) return SIZE[d.key] or 5 end

local function levels(d)
    return "Level " .. d.min .. (d.max ~= d.min and ("-" .. d.max) or "") .. (d.raid and "  |cffff8040Raid|r" or "")
end

function G:Build()
    if self.frame then return self.frame end
    local f = window("OVAdventureGuideFrame", "Adventure Guide", "Interface\\Icons\\INV_Misc_Book_11", 560, 400)

    -- Suggested Content: three cards
    local sug = CreateFrame("Frame", nil, f)
    sug:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -30)
    sug:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 10)
    sug.head = UI.Label(sug, 13, UI.GOLD)
    sug.head:SetPoint("TOPLEFT", sug, "TOPLEFT", 6, -4)
    sug.head:SetText("Suggested Content")
    sug.sub = UI.Label(sug, 10, MUTED)
    sug.sub:SetPoint("TOPLEFT", sug.head, "BOTTOMLEFT", 0, -3)
    sug.cards = {}
    for i = 1, 3 do
        local c = CreateFrame("Frame", nil, sug)
        c:SetWidth(170)
        c:SetHeight(270)
        c:SetPoint("TOPLEFT", sug, "TOPLEFT", 6 + (i - 1) * 178, -40)
        UI.Skin(c, "inset")
        c.art = c:CreateTexture(nil, "ARTWORK")
        c.art:SetPoint("TOPLEFT", c, "TOPLEFT", 4, -4)
        c.art:SetPoint("TOPRIGHT", c, "TOPRIGHT", -4, -4)
        c.art:SetHeight(90)
        c.icon = UI.IconBox(c, 40)
        c.icon:SetPoint("CENTER", c.art, "CENTER", 0, 0)
        c.name = UI.Label(c, 12, UI.GOLD)
        c.name:SetPoint("TOPLEFT", c.art, "BOTTOMLEFT", 6, -8)
        c.name:SetWidth(150)
        c.name:SetHeight(30)
        c.name:SetJustifyH("LEFT")
        c.name:SetJustifyV("TOP")
        c.lvl = UI.Label(c, 10, { 1, 1, 1 })
        c.lvl:SetPoint("TOPLEFT", c.art, "BOTTOMLEFT", 6, -42)
        c.zone = UI.Label(c, 10, MUTED)
        c.zone:SetPoint("TOPLEFT", c.lvl, "BOTTOMLEFT", 0, -4)
        c.zone:SetWidth(150)
        c.zone:SetJustifyH("LEFT")
        c.body = UI.Label(c, 10, { 0.82, 0.82, 0.84 })
        c.body:SetPoint("TOPLEFT", c.zone, "BOTTOMLEFT", 0, -10)
        c.body:SetWidth(150)
        c.body:SetJustifyH("LEFT")
        c.map = UI.Button(c, "Show on map", 150, 22)
        c.map:SetPoint("BOTTOM", c, "BOTTOM", 0, 36)
        c.find = UI.Button(c, "Find a group", 150, 22)
        c.find:SetPoint("BOTTOM", c, "BOTTOM", 0, 10)
        sug.cards[i] = c
    end
    f.suggested = sug

    -- Dungeons / Raids: a list and the chosen one's page
    local br = CreateFrame("Frame", nil, f)
    br:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -30)
    br:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 10)
    br.list = UI.ScrollList(br, { width = 210, height = 352, rowHeight = 22,
        build = function(row)
            row.name = UI.Label(row, 11, { 1, 1, 1 })
            row.name:SetPoint("LEFT", row, "LEFT", 6, 0)
            row.name:SetWidth(150)
            row.name:SetJustifyH("LEFT")
            row.lvl = UI.Label(row, 10, MUTED)
            row.lvl:SetPoint("RIGHT", row, "RIGHT", -4, 0)
            row.sel = row:CreateTexture(nil, "BACKGROUND")
            row.sel:SetAllPoints(row)
            row.sel:SetTexture(0.45, 0.34, 0.08, 0.45)
            row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
            row:SetScript("OnClick", function() if this.item then G:Select(this.item) end end)
        end,
        update = function(row, d)
            row.name:SetText((string.gsub(d.name, "^Scarlet Monastery: ", "Monastery: ")))
            row.lvl:SetText(d.min == d.max and d.min or (d.min .. "-" .. d.max))
            local lvl = UnitLevel("player") or 1
            if D().Fits(d, lvl) then row.name:SetTextColor(1, 0.82, 0)
            elseif d.min > lvl then row.name:SetTextColor(0.6, 0.6, 0.6)
            else row.name:SetTextColor(1, 1, 1) end
            if G.chosen == d then row.sel:Show() else row.sel:Hide() end
        end })
    br.list:SetPoint("TOPLEFT", br, "TOPLEFT", 0, -2)
    local pg = CreateFrame("Frame", nil, br)
    pg:SetPoint("TOPLEFT", br, "TOPLEFT", 220, -2)
    pg:SetPoint("BOTTOMRIGHT", br, "BOTTOMRIGHT", 0, 0)
    UI.Skin(pg, "inset")
    pg.name = UI.Label(pg, 15, UI.GOLD)
    pg.name:SetPoint("TOPLEFT", pg, "TOPLEFT", 12, -12)
    pg.lvl = UI.Label(pg, 11, { 1, 1, 1 })
    pg.lvl:SetPoint("TOPLEFT", pg.name, "BOTTOMLEFT", 0, -6)
    pg.body = UI.Label(pg, 11, { 0.86, 0.86, 0.88 })
    pg.body:SetPoint("TOPLEFT", pg.lvl, "BOTTOMLEFT", 0, -12)
    pg.body:SetWidth(290)
    pg.body:SetJustifyH("LEFT")
    pg.crest = UI.IconBox(pg, 44)
    pg.crest:SetPoint("TOPRIGHT", pg, "TOPRIGHT", -12, -12)
    pg.facts = UI.Label(pg, 11, MUTED)
    pg.facts:SetPoint("TOPLEFT", pg.body, "BOTTOMLEFT", 0, -14)
    pg.facts:SetWidth(290)
    pg.facts:SetJustifyH("LEFT")
    pg.fit = UI.Label(pg, 11, { 0.4, 0.9, 0.4 })
    pg.fit:SetPoint("TOPLEFT", pg.facts, "BOTTOMLEFT", 0, -14)
    pg.fit:SetWidth(290)
    pg.fit:SetJustifyH("LEFT")
    pg.act = actions(pg)
    pg.act.map:SetPoint("BOTTOMLEFT", pg, "BOTTOMLEFT", 12, 12)
    br.page = pg
    f.browser = br

    f.tabs = UI.ClassicTabs(f, { onSelect = function(key) G:ShowPage(key) end,
        tabs = { { key = "suggested", label = "Suggested Content" }, { key = "dungeons", label = "Dungeons" }, { key = "raids", label = "Raids" } } })
    f.tabs:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 11, 4)
    self.frame = f
    return f
end

function G:Select(d)
    self.chosen = d
    local pg = self.frame.browser.page
    pg.name:SetText(d.name)
    pg.lvl:SetText(d.zone)
    pg.crest.icon:SetTexture(d.raid and "Interface\\Icons\\INV_Misc_Head_Dragon_01" or "Interface\\Icons\\INV_Misc_Key_03")
    pg.facts:SetText((d.raid and "Raid" or "Dungeon") .. "  |cffffffff" .. size(d) .. " players|r\nRecommended level  |cffffffff"
        .. d.min .. (d.max ~= d.min and ("-" .. d.max) or "") .. "|r")
    pg.body:SetText("Entrance: " .. d.zone .. string.format(" (%.1f, %.1f)", d.x, d.y) .. "\n" .. d.stone .. ".")
    local lvl = UnitLevel("player") or 1
    if D().Fits(d, lvl) then pg.fit:SetText("Right for your level."); pg.fit:SetTextColor(0.4, 0.9, 0.4)
    elseif d.min > lvl then pg.fit:SetText("Opens to you at level " .. math.max(1, d.min - 2) .. "."); pg.fit:SetTextColor(0.62, 0.64, 0.70)
    else pg.fit:SetText("Below your level."); pg.fit:SetTextColor(0.62, 0.64, 0.70) end
    pg.act:Set(d)
    self.frame.browser.list:Refresh()
end

function G:ShowPage(key)
    local f = self:Build()
    self.page = key or self.page
    f.tabs:Select(self.page, true)
    if self.page == "suggested" then
        f.browser:Hide()
        f.suggested:Show()
        local lvl = UnitLevel("player") or 1
        local list = self:Suggested(lvl)
        local first = list[1]
        f.suggested.sub:SetText((first and first.min > lvl + 2) and ("Your first dungeon opens at level " .. (first.min - 2) .. ".")
            or ("For a level " .. lvl .. " adventurer."))
        for i, c in ipairs(f.suggested.cards) do
            local d = list[i]
            if d then
                c.name:SetText(d.name)
                c.lvl:SetText(levels(d))
                c.zone:SetText(d.zone .. string.format(" (%.0f, %.0f)", d.x, d.y))
                c.body:SetText(d.stone .. ".")
                c.icon.icon:SetTexture(d.raid and "Interface\\Icons\\INV_Misc_Head_Dragon_01" or "Interface\\Icons\\INV_Misc_Key_03")
                if d.raid then UI.Gradient(c.art, 0.36, 0.12, 0.05, 0.10, 0.04, 0.03)
                else UI.Gradient(c.art, 0.14, 0.12, 0.26, 0.05, 0.05, 0.09) end
                c.map:SetScript("OnClick", function() D():ShowOnMap(d) end)
                c.find:SetScript("OnClick", function() findGroup(d) end)
                c:Show()
            else
                c:Hide()
            end
        end
    else
        f.suggested:Hide()
        f.browser:Show()
        local list = self:List(self.page == "raids")
        f.browser.list:SetItems(list)
        local pick = list[1]
        local best = self:Suggested()[1]
        for _, d in ipairs(list) do if d == best then pick = d end end
        if self.chosen then for _, d in ipairs(list) do if d == self.chosen then pick = d end end end
        if pick then self:Select(pick) end
    end
end

function G:Toggle()
    if not (Dungeons and Dungeons.LIST) then W.Print("The Adventure Guide needs the Dungeons addon.") return end
    toggle(self:Build(), function() G:ShowPage() end)
end
