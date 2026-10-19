--[[
    Tracking.lua  -  Quests: service NPCs on the minimap and the tracking menu.

    Click the compass rose for a small menu: Repair and Sell (on by default), Flight masters,
    Innkeepers, Trainers and Bankers, plus Find Herbs / Find Minerals when you know them.
    Tracked NPCs show as icons on the minimap while they are in view (anvil: repairs, coin bag:
    buys and sells, wing: flights, tankard: inn, book: your class trainer, chest: bank); the
    nearest of each kind sits on the ring pointing the way when it is farther off. Hover an icon
    for who it is, what they do ("Repairs · Sells armour and shields") and how far away.

    Data: the realm's NP packet for your zone (asked with ".wnl np" on every zone change):
        NP <zoneId>;<npcId>,<x>,<y>,<flags>,<name>[,<subname>];...   flags R V F I T B
    Until a realm sends it, the built-in list (NpcData.lua) covers the six capitals and the six
    starting zones.
]]--

local W = WenillaCore
local UI = W.UI
local Q = Compass

Q.serverNpcs = {}       -- [zone name] = { npc, ... } from NP packets
Q.npcPool = {}

-- kind -> setting, art, stock fallback icon, label
Q.SERVICE = {
    R = { key = "trackRepair", art = "Quests_Anvil", icon = "Interface\\Icons\\Trade_BlackSmithing", label = "Repair" },
    V = { key = "trackSell", art = "Quests_CoinBag", icon = "Interface\\Icons\\INV_Misc_Bag_10", label = "Sell" },
    F = { key = "trackFlight", art = "Quests_Flight", icon = "Interface\\Icons\\Ability_Hunter_EagleEye", label = "Flight masters" },
    I = { key = "trackInn", art = "Quests_Inn", icon = "Interface\\Icons\\INV_Drink_05", label = "Innkeepers" },
    T = { key = "trackTrainer", art = "Quests_Trainer", icon = "Interface\\Icons\\INV_Misc_Book_09", label = "Trainers" },
    B = { key = "trackBank", art = "Quests_Bank", icon = "Interface\\Icons\\INV_Misc_Bag_13", label = "Bankers" },
}
Q.SERVICE_ORDER = { "R", "V", "F", "I", "T", "B" }

-- What a vendor sells, from its subname.
local GOODS = {
    { "Armorer", "armour and shields" }, { "Shield", "shields" }, { "Cloth & Leather", "cloth and leather armour" },
    { "Leather Armor", "leather armour" }, { "Mail Armor", "mail armour" }, { "Heavy Armor", "mail and plate armour" },
    { "Cloth Armor", "cloth armour" }, { "Light Armor", "light armour" }, { "Clothier", "clothes" },
    { "Robe", "robes" }, { "Blade", "blades" }, { "Axe", "axes" }, { "Staff", "staves" }, { "Stave", "staves" },
    { "Mace", "maces" }, { "Bow", "bows and arrows" }, { "Gun", "guns and ammunition" }, { "Weapon", "weapons" },
    { "Smith", "weapons" }, { "General", "general goods" }, { "Trade", "trade goods" }, { "Tradesman", "trade goods" },
    { "Food", "food and drink" }, { "Armor", "armour" }, { "Hatter", "hats" }, { "Cobbler", "boots" },
}

local CLASS_WORD = { WARRIOR = "warriors", PALADIN = "paladins", HUNTER = "hunters", ROGUE = "rogues",
    PRIEST = "priests", SHAMAN = "shamans", MAGE = "mages", WARLOCK = "warlocks", DRUID = "druids" }

function Q:Services(npc)
    local f, parts = npc.flags or "", {}
    if string.find(f, "R", 1, true) then table.insert(parts, "Repairs") end
    if string.find(f, "V", 1, true) then
        local what = "goods"
        for _, g in ipairs(GOODS) do
            if npc.sub and string.find(npc.sub, g[1], 1, true) then what = g[2] break end
        end
        table.insert(parts, "Sells " .. what)
        if not string.find(f, "R", 1, true) then table.insert(parts, "Buys your items") end
    end
    if string.find(f, "F", 1, true) then table.insert(parts, "Flights") end
    if string.find(f, "I", 1, true) then table.insert(parts, "Food, drink and your hearthstone") end
    if string.find(f, "T", 1, true) then
        table.insert(parts, "Trains " .. (CLASS_WORD[npc.class or ""] or "your class"))
    end
    if string.find(f, "B", 1, true) then table.insert(parts, "Bank") end
    return table.concat(parts, " · ")
end

-- -- Data -----------------------------------------------------------------------------------

local byId
local function fallbackById(id)
    if not byId then
        byId = {}
        for _, z in pairs(Q.NPC_ZONES or {}) do
            for _, r in ipairs(z.npcs) do byId[r[1]] = r end
        end
    end
    return byId[id]
end

-- The service NPCs of a zone: the realm's when it sent them, else the built-in list for that
-- zone when it belongs to the player's faction.
function Q:ZoneNpcs(zone)
    zone = zone or self:Zone()
    if self.serverNpcs[zone] then return self.serverNpcs[zone], "server" end
    local z = self.NPC_ZONES and self.NPC_ZONES[zone]
    if not z then return {}, nil end
    local faction = UnitFactionGroup and UnitFactionGroup("player")
    if faction and z.faction and faction ~= z.faction then return {}, nil end
    if not z.list then
        z.list = {}
        for _, r in ipairs(z.npcs) do
            table.insert(z.list, { id = r[1], x = r[2], y = r[3], flags = r[4], name = r[5],
                sub = (r[6] ~= "" and r[6]) or nil, class = (r[7] ~= "" and r[7]) or nil, zone = zone })
        end
    end
    return z.list, "builtin"
end

function Q:HandleNpcs(body)
    local recs, n = W.Split(body or "", ";")
    local zone = self.ZONE_IDS[tonumber(recs[1] or "")] or self:Zone()
    local list = {}
    for i = 2, n do
        local f = W.Split(recs[i], ",")
        local x, y = tonumber(f[2]), tonumber(f[3])
        if x and y and f[5] and f[5] ~= "" then
            local id = tonumber(f[1])
            local known = id and fallbackById(id)
            local npc = { id = id, x = x, y = y, flags = string.upper(f[4] or ""), name = f[5], zone = zone,
                sub = (f[6] and f[6] ~= "" and f[6]) or (known and known[6] ~= "" and known[6]) or nil,
                class = known and known[7] ~= "" and known[7] or nil }
            table.insert(list, npc)
        end
    end
    self.serverNpcs[zone] = list
    self:LayoutNpcs()
end

W:RegisterModule("NP", function(body) Q.realmPlus = true; Q:HandleNpcs(body) end)

-- -- Icons ------------------------------------------------------------------------------------

local function npcTip(self, tip)
    local npc = self.npc
    if not npc then return end
    tip:SetText(npc.name, 1, 1, 1)
    if npc.sub then tip:AddLine("<" .. npc.sub .. ">", 0.75, 0.75, 0.75) end
    local s = Q:Services(npc)
    if s ~= "" then tip:AddLine(s, 1, 0.82, 0) end
    if self.yards then tip:AddLine(Q:YardText(self.yards) .. " away", 0.7, 0.7, 0.7) end
    tip:AddLine("Click to point the arrow here.", 0.5, 0.5, 0.5)
end

local function newIcon(i)
    local m = Q:NewMarker("Compass_Npc" .. i, 14)
    m.OnTip = npcTip
    m.OnClickMarker = function(self)
        local n = self.npc
        if n then Q:SetWaypoint({ x = n.x, y = n.y, zone = n.zone, title = n.name, kind = "NPC", label = Q:Services(n) }) end
    end
    return m
end

-- Which tracked service decides an NPC's icon (repair beats sell, and so on).
function Q:NpcKind(npc)
    local f = npc.flags or ""
    local _, myClass = UnitClass("player")
    for _, k in ipairs(self.SERVICE_ORDER) do
        if string.find(f, k, 1, true) and self:Get(self.SERVICE[k].key) then
            if k ~= "T" or not npc.class or npc.class == myClass then return k end
        end
    end
end

function Q:LayoutNpcs()
    local used = 0
    if self:Active() then
        local zone = self:Zone()
        local px, py = self:PlayerPos()
        local list = self:ZoneNpcs(zone)
        local nearest = {}
        if px ~= 0 or py ~= 0 then
            for _, npc in ipairs(list) do
                npc.kind = self:NpcKind(npc)
                if npc.kind then
                    npc.dist = self:Yards(px, py, npc.x, npc.y, zone)
                    local b = nearest[npc.kind]
                    if not b or npc.dist < b.dist then nearest[npc.kind] = npc end
                end
            end
            for _, npc in ipairs(list) do
                if npc.kind and used < 40 then
                    local m = self.npcPool[used + 1] or newIcon(used + 1)
                    self.npcPool[used + 1] = m
                    m.npc = npc
                    local where = self:PlaceMarker(m, npc.x, npc.y, nearest[npc.kind] == npc, zone)
                    if where then
                        used = used + 1
                        local sv = self.SERVICE[npc.kind]
                        m.kind = npc.kind
                        local size = (where == "map") and 14 or 13
                        m:SetWidth(size)
                        m:SetHeight(size)
                        if W:Art(m.tex, sv.art, sv.icon) then
                            m.tex:SetTexCoord(0, 1, 0, 1)
                        else
                            m.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                        end
                    end
                end
            end
        end
    end
    for i = used + 1, table.getn(self.npcPool) do
        self.npcPool[i]:Hide()
        self.npcPool[i].npc = nil
    end
    self.npcIconsShown = used
end

Q:Every(0.25, function() Q:LayoutNpcs() end)
Q:OnRefresh(function() Q:LayoutNpcs() end)

-- -- Find Herbs / Find Minerals -----------------------------------------------------------------

Q.FINDS = {
    { spell = "Find Herbs", icon = "Interface\\Icons\\INV_Misc_Flower_02" },
    { spell = "Find Minerals", icon = "Interface\\Icons\\Spell_Nature_Earthquake" },
}

function Q:KnowsSpell(name)
    if not (GetNumSpellTabs and GetSpellTabInfo and GetSpellName) then return false end
    for t = 1, GetNumSpellTabs() do
        local _, _, offset, count = GetSpellTabInfo(t)
        for i = (offset or 0) + 1, (offset or 0) + (count or 0) do
            if GetSpellName(i, BOOKTYPE_SPELL or "spell") == name then return true end
        end
    end
    return false
end

function Q:FindActive(f)
    local tex = GetTrackingTexture and GetTrackingTexture()
    return tex and string.lower(tex) == string.lower(f.icon) or false
end

function Q:ToggleFind(f)
    if self:FindActive(f) then
        if CancelTrackingBuff then CancelTrackingBuff() end
    elseif CastSpellByName then
        CastSpellByName(f.spell)
    end
end

-- -- The menu -----------------------------------------------------------------------------------

function Q:SetService(k, on)
    self:Set(self.SERVICE[k].key, on and true or false)
    self:LayoutNpcs()
end

function Q:TrackingMenu(anchor)
    local items = { { text = "Show on the minimap", title = true } }
    for _, k in ipairs(self.SERVICE_ORDER) do
        local sv, kind = self.SERVICE[k], k
        table.insert(items, { text = sv.label, checked = self:Get(sv.key) and true or false,
            func = function() Q:SetService(kind, not Q:Get(Q.SERVICE[kind].key)) end })
    end
    table.insert(items, { text = "Gathering", title = true })
    for _, f in ipairs(self.FINDS) do
        local find = f
        if self:KnowsSpell(f.spell) then
            table.insert(items, { text = f.spell, checked = self:FindActive(f), func = function() Q:ToggleFind(find) end })
        else
            table.insert(items, { text = f.spell .. " (not learned)", disabled = true })
        end
    end
    table.insert(items, { text = "Quests", title = true })
    table.insert(items, { text = "Open the quest log", func = function() if Q.Log then Q.Log:Open() end end })
    table.insert(items, { text = "Open the world map", func = function() if ToggleWorldMap then ToggleWorldMap() end end })
    table.insert(items, { text = "Ring style...", func = function() Q:ThemeMenu(anchor) end })
    return UI.Menu(anchor, items)
end
