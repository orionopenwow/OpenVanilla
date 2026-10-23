--[[
    Armory.lua  (Duels)
    The armory window: one place to gear a duel body (modes roadmap, Phase 3; art pass 3a).
      Gear      a paper doll with every slot; click one to browse what it can wear, worn item first,
                with a search, "unlocked only" and the change in your class's main stats
      Enchants  the enchants offered for the chosen slot
      Loadouts  your class's kits, your saved loadouts, and a loadout code to share or paste
    It talks to the realm through Warfront (".wnl wf pool <slot>", "slot <slot> <item>", "ench <slot>
    <spell>", "kit <key>") and reads its answers (WP, WS, WE, WK), so it needs no server change.

    A loadout code is "OV1" and one base-36 item id per slot, in A.SLOTS order, "-" between them
    ("0" for empty): short enough to paste in chat, and checked when read back.
    Lua 5.0 rules: no #, no %, this/arg1 in scripts.
]]--

local W = WenillaCore
local UI = W.UI
local F = Warfront
local D = Duels

local A = {}
D.Armory = A
DuelsLoadouts = DuelsLoadouts or {}

local getn, strfind, strsub, strlower, strupper = table.getn, string.find, string.sub, string.lower, string.upper

-- server equipment slots (0-based) on the doll: left column, right column, weapons
A.LEFT = { 0, 1, 2, 14, 4, 8 }
A.RIGHT = { 9, 5, 6, 7, 10, 11, 12, 13 }
A.WEAPONS = { 15, 16, 17 }
A.SLOTS = { 0, 1, 2, 14, 4, 8, 9, 5, 6, 7, 10, 11, 12, 13, 15, 16, 17 }
A.NAMES = { [0] = "Head", [1] = "Neck", [2] = "Shoulders", [14] = "Back", [4] = "Chest", [8] = "Wrist", [9] = "Hands",
    [5] = "Waist", [6] = "Legs", [7] = "Feet", [10] = "Finger", [11] = "Finger", [12] = "Trinket", [13] = "Trinket",
    [15] = "Main hand", [16] = "Off hand", [17] = "Ranged" }

-- the stats that matter most per class, for the "better or worse" column
A.MAIN = { WARRIOR = "Strength", PALADIN = "Strength", ROGUE = "Agility", HUNTER = "Agility", SHAMAN = "Intellect",
    DRUID = "Intellect", MAGE = "Intellect", PRIEST = "Intellect", WARLOCK = "Intellect" }
A.SHORT = { Strength = "Str", Agility = "Agi", Stamina = "Sta", Intellect = "Int", Spirit = "Spi" }
A.QUALITY = { [0] = { 0.62, 0.62, 0.62 }, [1] = { 1, 1, 1 }, [2] = { 0.12, 1, 0 }, [3] = { 0, 0.44, 0.87 },
    [4] = { 0.64, 0.21, 0.93 }, [5] = { 1, 0.5, 0 } }

local win
A.slot = nil          -- the chosen slot
A.search = ""
A.onlyUnlocked = false
A.queue = nil         -- a loadout being put on, one item at a time: { { slot, id }, ... }

local function send(args) return F and F.Send and F.Send(args) end
local function say(msg) if D.Say then D.Say(msg) else W.Print(msg) end end
local function status(text) if win then win.status:SetText(text or "") end end

local function wornId(slot)
    local link = GetInventoryItemLink and GetInventoryItemLink("player", slot + 1)
    if not link then return nil end
    local _, _, id = strfind(link, "item:(%d+)")
    return tonumber(id)
end

-- -- loadout codes -------------------------------------------------------------------------------

local DIGITS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
local function b36(n)
    n = math.floor(n or 0)
    if n <= 0 then return "0" end
    local s = ""
    while n > 0 do
        local d = math.mod(n, 36)
        s = strsub(DIGITS, d + 1, d + 1) .. s
        n = math.floor(n / 36)
    end
    return s
end
local function unb36(s)
    local n = 0
    s = strupper(s or "")
    if s == "" then return nil end
    for i = 1, string.len(s) do
        local d = strfind(DIGITS, strsub(s, i, i), 1, true)
        if not d then return nil end
        n = n * 36 + d - 1
    end
    return n
end

-- items { [slot] = id } -> "OV1-..."
function A.Encode(items)
    local parts = { "OV1" }
    for _, slot in ipairs(A.SLOTS) do table.insert(parts, b36(items[slot])) end
    return table.concat(parts, "-")
end

-- "OV1-..." -> { [slot] = id } or nil
function A.Decode(code)
    local p = W.Split(W.Trim(code or ""), "-")
    if strupper(p[1] or "") ~= "OV1" or getn(p) ~= getn(A.SLOTS) + 1 then return nil end
    local items = {}
    for i, slot in ipairs(A.SLOTS) do
        local id = unb36(p[i + 1])
        if not id then return nil end
        if id > 0 then items[slot] = id end
    end
    return items
end

function A.Current()
    local items = {}
    for _, slot in ipairs(A.SLOTS) do items[slot] = wornId(slot) end
    return items
end

-- -- stats (a hidden tooltip, read line by line) ---------------------------------------------------

local scan
function A.Stats(id)
    if not id then return {} end
    if not scan then
        scan = CreateFrame("GameTooltip", "DuelsArmoryScan", nil, "GameTooltipTemplate")
    end
    scan:SetOwner(WorldFrame or UIParent, "ANCHOR_NONE")
    scan:ClearLines()
    scan:SetHyperlink("item:" .. id .. ":0:0:0")
    local out = {}
    for i = 2, 30 do
        local fs = getglobal("DuelsArmoryScanTextLeft" .. i)
        local t = fs and fs:GetText()
        if t then
            local _, _, n, stat = strfind(t, "^%+(%d+) (%a+)$")
            if n and A.SHORT[stat] then out[stat] = (out[stat] or 0) + tonumber(n) end
        end
    end
    scan:Hide()
    return out
end

-- "+13 Str  +15 Sta" against what is worn in the slot
function A.Delta(id, slot)
    local _, class = UnitClass("player")
    local main = A.MAIN[class or ""] or "Strength"
    local new, old = A.Stats(id), A.Stats(wornId(slot))
    local out = {}
    for _, stat in ipairs({ main, "Stamina" }) do
        local d = (new[stat] or 0) - (old[stat] or 0)
        if d ~= 0 then
            table.insert(out, (d > 0 and "|cff40ff60+" or "|cffff5040") .. d .. " " .. A.SHORT[stat] .. "|r")
        end
    end
    return table.concat(out, "  ")
end

-- -- the window ----------------------------------------------------------------------------------

-- the stock empty-slot pictures (GetInventorySlotInfo), so an empty slot still shows what goes there
A.SLOT_NAME = { [0] = "HeadSlot", [1] = "NeckSlot", [2] = "ShoulderSlot", [14] = "BackSlot", [4] = "ChestSlot",
    [8] = "WristSlot", [9] = "HandsSlot", [5] = "WaistSlot", [6] = "LegsSlot", [7] = "FeetSlot", [10] = "Finger0Slot",
    [11] = "Finger1Slot", [12] = "Trinket0Slot", [13] = "Trinket1Slot", [15] = "MainHandSlot", [16] = "SecondaryHandSlot",
    [17] = "RangedSlot" }
local function emptyTexture(slot)
    if GetInventorySlotInfo and A.SLOT_NAME[slot] then
        local ok, _, tex = pcall(GetInventorySlotInfo, A.SLOT_NAME[slot])
        if ok and tex then return tex end
    end
    return "Interface\\PaperDoll\\UI-Backpack-EmptySlot"
end

-- a slot: its picture (worn item, or the empty slot's) and its name beside it, like the first gear picker
local function slotButton(parent, slot)
    local b = CreateFrame("Button", nil, parent)
    b:SetWidth(108); b:SetHeight(30)
    b.box = UI.IconBox(b, 28)
    b.box:SetPoint("LEFT", b, "LEFT", 0, 0)
    b.label = UI.Label(b, 10, UI.WHITE)
    b.label:SetPoint("TOPLEFT", b.box, "TOPRIGHT", 5, -2)
    b.label:SetWidth(74)
    if b.label.SetJustifyH then b.label:SetJustifyH("LEFT") end
    b.label:SetText(A.NAMES[slot] or "")
    b.sub = UI.Label(b, 9, UI.MUTED)
    b.sub:SetPoint("BOTTOMLEFT", b.box, "BOTTOMRIGHT", 5, 2)
    b.sub:SetWidth(74)
    if b.sub.SetJustifyH then b.sub:SetJustifyH("LEFT") end
    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
    b.slot = slot
    b:SetScript("OnClick", function() A.Pick(this.slot) end)
    b:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        if wornId(this.slot) then GameTooltip:SetInventoryItem("player", this.slot + 1)
        else GameTooltip:SetText((A.NAMES[this.slot] or "") .. ": empty. Click to pick an item.") end
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end

-- the item cache: 1.12 knows an item's name and icon only once it has been asked for (a tooltip asks)
local warm
function A.Warm(ids)
    if not warm then warm = CreateFrame("GameTooltip", "DuelsArmoryWarm", nil, "GameTooltipTemplate") end
    for i, id in ipairs(ids) do
        if i > 40 then break end
        if not (GetItemInfo and GetItemInfo(id)) then
            warm:SetOwner(WorldFrame or UIParent, "ANCHOR_NONE")
            warm:SetHyperlink("item:" .. id .. ":0:0:0")
        end
    end
    if warm.Hide then warm:Hide() end
    A.refreshAt = GetTime() + 1
end

local function page(key)
    local p = CreateFrame("Frame", nil, win)
    p:SetPoint("TOPLEFT", win, "TOPLEFT", 10, -56)
    p:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -10, 34)
    p:Hide()
    win.pages[key] = p
    return p
end

A.COL1 = { 0, 1, 2, 14, 4, 8, 9, 5, 6 }
A.COL2 = { 7, 10, 11, 12, 13, 15, 16, 17 }

local function buildGear(p)
    p.doll = {}
    for i, slot in ipairs(A.COL1) do
        local b = slotButton(p, slot)
        b:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -(i - 1) * 33)
        p.doll[slot] = b
    end
    for i, slot in ipairs(A.COL2) do
        local b = slotButton(p, slot)
        b:SetPoint("TOPLEFT", p, "TOPLEFT", 112, -(i - 1) * 33)
        p.doll[slot] = b
    end
    p.summary = UI.Label(p, 10, UI.MUTED)
    p.summary:SetPoint("TOPLEFT", p, "TOPLEFT", 112, -270)
    p.summary:SetWidth(108)
    p.head = UI.Label(p, 12, UI.ACCENT)
    p.head:SetPoint("TOPLEFT", p, "TOPLEFT", 226, -2)
    p.head:SetText("Pick a slot")
    p.search = UI.SearchBox(p, { name = "DuelsArmorySearch", width = 150, placeholder = "Search items",
        onChange = function(t) A.search = strlower(t or ""); A.Refresh() end })
    p.search:SetPoint("TOPRIGHT", p, "TOPRIGHT", 0, 0)
    p.unlocked = UI.Button(p, "Unlocked only", 100, 18, function()
        A.onlyUnlocked = not A.onlyUnlocked
        if A.onlyUnlocked then this:LockHighlight() else this:UnlockHighlight() end
        A.Refresh()
    end)
    p.unlocked:SetPoint("RIGHT", p.search, "LEFT", -6, 0)
    p.list = UI.ScrollList(p, {
        name = "DuelsArmoryList", width = 392, height = 264, rowHeight = 33,
        build = function(row)
            row.box = UI.IconBox(row, 28)
            row.box:SetPoint("LEFT", row, "LEFT", 2, 0)
            row.name = UI.Label(row, 11, UI.WHITE)
            row.name:SetPoint("TOPLEFT", row.box, "TOPRIGHT", 6, -1)
            row.sub = UI.Label(row, 9, UI.MUTED)
            row.sub:SetPoint("BOTTOMLEFT", row.box, "BOTTOMRIGHT", 6, 1)
            row.delta = UI.Label(row, 10, UI.WHITE)
            row.delta:SetPoint("RIGHT", row, "RIGHT", -6, 0)
            row:SetScript("OnClick", function() if row.item then A.Wear(row.item) end end)
            row:SetScript("OnEnter", function()
                if not row.item then return end
                GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
                GameTooltip:SetHyperlink("item:" .. row.item.id .. ":0:0:0")
                GameTooltip:Show()
            end)
            row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end,
        update = function(row, item)
            row.item = item
            local name, _, quality, _, _, _, _, _, _, tex = GetItemInfo(item.id)
            local q = A.QUALITY[quality or 1] or UI.WHITE
            row.box.icon:SetTexture(tex or UI.UNKNOWN_ICON)
            row.box.edge:SetTexture(q[1], q[2], q[3], 1)
            row.name:SetText(name or ("Item " .. item.id .. "  (loading...)"))
            row.name:SetTextColor(q[1], q[2], q[3])
            local locked = item.tier > (F.tier or 0)
            row.sub:SetText(locked and ("Locked: tier " .. item.tier) or (item.worn and "Worn now" or ("Tier " .. item.tier)))
            row.delta:SetText(item.worn and "|cffffd100worn|r" or A.Delta(item.id, A.slot))
            row:SetAlpha(locked and 0.5 or 1)
        end,
    })
    p.list:SetPoint("TOPLEFT", p, "TOPLEFT", 226, -24)
end

local function buildEnchants(p)
    p.head = UI.Label(p, 12, UI.ACCENT)
    p.head:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -2)
    p.head:SetText("Pick a slot on the Gear tab first")
    p.list = UI.ScrollList(p, {
        name = "DuelsArmoryEnchants", width = 600, height = 280, rowHeight = 18,
        build = function(row)
            row.text = UI.Label(row, 11, UI.WHITE)
            row.text:SetPoint("LEFT", row, "LEFT", 4, 0)
            row:SetScript("OnClick", function()
                if row.ench and A.slot and send("ench " .. A.slot .. " " .. row.ench[1]) then status("Enchanting...") end
            end)
        end,
        update = function(row, e) row.ench = e; row.text:SetText(e[2]) end,
    })
    p.list:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -22)
end

local function buildLoadouts(p)
    local h1 = UI.Label(p, 12, UI.ACCENT)
    h1:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -2)
    h1:SetText("Kits for your class")
    p.kits = UI.ScrollList(p, {
        name = "DuelsArmoryKits", width = 290, height = 200, rowHeight = 18,
        build = function(row)
            row.text = UI.Label(row, 11, UI.WHITE)
            row.text:SetPoint("LEFT", row, "LEFT", 4, 0)
            row:SetScript("OnClick", function() if row.kit and F.EquipKit then F:EquipKit(row.kit.key); status("Equipping the " .. row.kit.spec .. " kit...") end end)
        end,
        update = function(row, k) row.kit = k; row.text:SetText(k.spec .. " · " .. (k.role or "")) end,
    })
    p.kits:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -20)
    local h2 = UI.Label(p, 12, UI.ACCENT)
    h2:SetPoint("TOPLEFT", p, "TOPLEFT", 310, -2)
    h2:SetText("My loadouts")
    p.mine = UI.ScrollList(p, {
        name = "DuelsArmoryMine", width = 290, height = 200, rowHeight = 18,
        build = function(row)
            row.text = UI.Label(row, 11, UI.WHITE)
            row.text:SetPoint("LEFT", row, "LEFT", 4, 0)
            row:SetScript("OnClick", function() if row.lo then A.Apply(row.lo.code) end end)
        end,
        update = function(row, lo) row.lo = lo; row.text:SetText(lo.name) end,
    })
    p.mine:SetPoint("TOPLEFT", p, "TOPLEFT", 310, -20)
    local h3 = UI.Label(p, 10, UI.MUTED)
    h3:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -232)
    h3:SetText("Loadout code: Ctrl+C to copy, or paste one and press Wear")
    p.code = UI.SearchBox(p, { name = "DuelsArmoryCode", width = 420, placeholder = "OV1-..." })
    p.code:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -248)
    p.wear = UI.Button(p, "Wear", 80, 20, function() A.Apply(p.code:GetText()) end)
    p.wear:SetPoint("LEFT", p.code, "RIGHT", 6, 0)
    p.save = UI.Button(p, "Save current", 100, 20, function() A.Save() end)
    p.save:SetPoint("LEFT", p.wear, "RIGHT", 6, 0)
end

function A.Build()
    if win then return win end
    win = UI.Window("DuelsArmoryFrame", { width = 640, height = 400, title = "Armory", skin = true,
        icon = "Interface\\Icons\\INV_Chest_Plate04", point = { "CENTER", UIParent, "CENTER", 0, 40 } })
    if UISpecialFrames then table.insert(UISpecialFrames, "DuelsArmoryFrame") end
    win:Hide()
    win.pages = {}
    win.tabs = UI.Tabs(win, { skin = true, tabs = { { key = "gear", label = "Gear" }, { key = "ench", label = "Enchants" },
        { key = "load", label = "Loadouts" } }, onSelect = function(key) A.Select(key) end })
    win.tabs:SetPoint("TOPLEFT", win, "TOPLEFT", 10, -30)
    buildGear(page("gear"))
    buildEnchants(page("ench"))
    buildLoadouts(page("load"))
    win.status = UI.Label(win, 10, UI.MUTED)
    win.status:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", 12, 12)
    win.equip = UI.Button(win, "Best kit", 90, 22, function() A.BestKit() end)
    win.equip:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -10, 8)
    win:SetScript("OnShow", function() A.UpdateDoll() end)
    A.Select("gear")
    return win
end

function A.Select(key)
    if not win then return end
    for k, p in pairs(win.pages) do if k == key then p:Show() else p:Hide() end end
    win.tabs:Select(key, true)
    win.page = key
    if key == "load" then A.FillLoadouts() end
    if key == "ench" then A.FillEnchants() end
end

function A.UpdateDoll()
    if not win then return end
    local p = win.pages.gear
    local worn = 0
    for slot, b in pairs(p.doll) do
        local id = wornId(slot)
        local tex = GetInventoryItemTexture and GetInventoryItemTexture("player", slot + 1)
        b.box.icon:SetTexture(tex or emptyTexture(slot))
        if b.sub then
            local name = id and GetItemInfo and GetItemInfo(id)
            b.sub:SetText(id and (name or "worn") or "|cff808080empty|r")
        end
        local q = A.QUALITY[(GetInventoryItemQuality and GetInventoryItemQuality("player", slot + 1)) or -1]
        if id and q then b.box.edge:SetTexture(q[1], q[2], q[3], 1) else b.box.edge:SetTexture(0.35, 0.35, 0.38, 1) end
        if slot == A.slot then b.box.edge:SetTexture(1, 0.82, 0, 1) end
        if id then worn = worn + 1 end
    end
    p.summary:SetText(worn .. " of " .. getn(A.SLOTS) .. " slots filled")
end

function A.Pick(slot)
    A.slot = slot
    A.warmed = 0
    if F then F.slot = slot end
    local p = win.pages.gear
    p.head:SetText(A.NAMES[slot] or "")
    A.UpdateDoll()
    if F.pools and F.pools[slot] then A.Refresh()
    else
        p.list:SetItems({})
        status("Loading the items for this slot...")
        send("pool " .. slot)
    end
    if win.page == "ench" then A.FillEnchants() end
end

-- the chosen slot's items: worn first, then unlocked, then by name; search and "unlocked only"
function A.Items()
    local pool = A.slot and F.pools and F.pools[A.slot] or {}
    local worn = A.slot and wornId(A.slot)
    local out = {}
    for _, it in ipairs(pool) do
        local name = strlower(GetItemInfo(it.id) or "")
        local okSearch = A.search == "" or strfind(name, A.search, 1, true)
        local okLock = not A.onlyUnlocked or it.tier <= (F.tier or 0)
        if okSearch and okLock then
            table.insert(out, { id = it.id, tier = it.tier, worn = (it.id == worn) or nil })
        end
    end
    table.sort(out, function(a, b)
        if (a.worn and 1 or 0) ~= (b.worn and 1 or 0) then return a.worn ~= nil end
        local la, lb = a.tier > (F.tier or 0), b.tier > (F.tier or 0)
        if la ~= lb then return lb end
        return (GetItemInfo(a.id) or "") < (GetItemInfo(b.id) or "")
    end)
    return out
end

function A.Refresh()
    if not (win and A.slot) then return end
    local items = A.Items()
    win.pages.gear.list:SetItems(items)
    local missing = {}
    for _, it in ipairs(items) do if not (GetItemInfo and GetItemInfo(it.id)) then table.insert(missing, it.id) end end
    if getn(missing) > 0 and (A.warmed or 0) < 3 then A.warmed = (A.warmed or 0) + 1; A.Warm(missing) end
    status(getn(items) .. " items for " .. (A.NAMES[A.slot] or "this slot") .. ".")
end

function A.Wear(item)
    if item.tier > (F.tier or 0) then status("|cffff4040Locked: earn it with arena rating or honorable kills.|r") return end
    if item.worn then return end
    if send("slot " .. A.slot .. " " .. item.id) then status("Equipping " .. (GetItemInfo(item.id) or "it") .. "...") end
end

function A.FillEnchants()
    local p = win.pages.ench
    if not A.slot then p.list:SetItems({}) return end
    p.head:SetText((A.NAMES[A.slot] or "") .. " enchants")
    p.list:SetItems((WarfrontEnchants or {})[A.slot + 1] or {})
end

function A.Kits()
    local _, class = UnitClass("player")
    local faction = UnitFactionGroup and UnitFactionGroup("player") or "Alliance"
    local out = {}
    for _, k in ipairs(WarfrontKits or {}) do
        if k.class == class and (not k.faction or k.faction == faction) then table.insert(out, k) end
    end
    -- a race and class pair with no kit of its faction (a Horde paladin, an Alliance shaman): the other
    -- faction's; the realm swaps any piece they can't wear for the nearest one they can (patch 0036)
    if getn(out) == 0 then
        for _, k in ipairs(WarfrontKits or {}) do
            if k.class == class then table.insert(out, k) end
        end
    end
    return out
end

function A.FillLoadouts()
    local p = win.pages.load
    p.kits:SetItems(A.Kits())
    p.mine:SetItems(DuelsLoadouts)
    p.code:SetText(A.Encode(A.Current()))
    if p.code.HighlightText then p.code:HighlightText() end
end

-- the kit for a spec name ("Arms", "Frost"...): the first whose spec names it, else the class's first
function A.KitFor(specName)
    local kits = A.Kits()
    local want = string.lower(specName or "")
    if want ~= "" then
        for _, k in ipairs(kits) do
            if string.find(string.lower(k.spec or ""), want, 1, 1) then return k end
        end
    end
    return kits[1]
end

function A.BestKit()
    local T = ClassicPlusTalents
    local name = T and T.specs and T.SpecName and T.SpecName(T.specs.active) or nil
    local k = A.KitFor(name)
    if k and F.EquipKit then F:EquipKit(k.key); status("Equipping the " .. k.spec .. " kit...")
    else status("No kit for your class here.") end
end

function A.Save()
    local code = A.Encode(A.Current())
    local name = (UnitName("player") or "Loadout") .. " " .. (getn(DuelsLoadouts) + 1)
    table.insert(DuelsLoadouts, { name = name, code = code })
    if win and win.page == "load" then A.FillLoadouts() end
    status("Saved as " .. name .. ".")
    return name
end

-- put a loadout on, one slot at a time (each WS answer sends the next)
function A.Apply(code)
    local items = A.Decode(code)
    if not items then status("|cffff4040That isn't a loadout code (it starts OV1-).|r") return false end
    A.queue = {}
    for _, slot in ipairs(A.SLOTS) do
        if items[slot] and items[slot] ~= wornId(slot) then table.insert(A.queue, { slot, items[slot] }) end
    end
    if getn(A.queue) == 0 then A.queue = nil; status("You're already wearing that.") return true end
    A.queueTotal = getn(A.queue)
    A.Next()
    return true
end

function A.Next()
    if not A.queue then return end
    local nxt = table.remove(A.queue, 1)
    if not nxt then
        A.queue = nil
        status("Loadout on.")
        return
    end
    send("slot " .. nxt[1] .. " " .. nxt[2])
    status("Putting it on: " .. (A.queueTotal - getn(A.queue)) .. " of " .. A.queueTotal .. "...")
end

function A.Toggle()
    if not (UI and UI.Window) then return end
    A.Build()
    if win:IsShown() then win:Hide() else win:Show(); A.UpdateDoll() end
end

-- ride on Warfront's answers: a slot's items arrived, an item went on (the next of a loadout)
local function after(tag, fn)
    local prev = W.modules and W.modules[tag]
    W:RegisterModule(tag, function(body)
        if prev then prev(body) end
        local ok, err = pcall(fn, body or "")
        if not ok then W.Print("|cffff4040Armory:|r " .. tostring(err)) end
    end)
end
after("WP", function(body)
    local slot = tonumber(W.Split(body, ";")[1])
    if win and slot and slot == A.slot then A.Refresh() end
end)
after("WS", function(body)
    if A.queue then A.Next() end
    if win and win:IsShown() then A.UpdateDoll(); A.Refresh() end
end)
after("WK", function() if win and win:IsShown() then A.UpdateDoll(); A.Refresh() end end)

-- -- the tab on the left edge: the Armory is always one click away on the Duels realm ---------------

function A.BuildTab()
    if A.tab then return A.tab end
    local t = CreateFrame("Button", "DuelsArmoryTab", UIParent)
    t:SetWidth(30); t:SetHeight(132)
    t:SetPoint("LEFT", UIParent, "LEFT", 0, 60)
    t:SetFrameStrata("MEDIUM")
    UI.Skin(t, "panel")
    local icon = t:CreateTexture(nil, "ARTWORK")
    icon:SetWidth(22); icon:SetHeight(22)
    icon:SetPoint("TOP", t, "TOP", 0, -5)
    icon:SetTexture("Interface\\Icons\\INV_Chest_Plate04")
    t.icon = icon
    -- the word, one letter a line (1.12 has no rotated text)
    t.letters = {}
    local word = "ARMORY"
    for i = 1, string.len(word) do
        local l = UI.Label(t, 12, UI.ACCENT)
        l:SetPoint("TOP", t, "TOP", 0, -30 - (i - 1) * 16)
        l:SetText(string.sub(word, i, i))
        t.letters[i] = l
    end
    t:SetScript("OnClick", function() A.Toggle() end)
    t:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:SetText("Armory")
        GameTooltip:AddLine("Your gear, enchants, kits and loadouts.", 0.9, 0.9, 0.9, 1)
        GameTooltip:Show()
    end)
    t:SetScript("OnLeave", function() GameTooltip:Hide() end)
    t:Hide()
    A.tab = t
    -- LOOKS, under it: the Transmogrifier, anywhere on Duels (every look unlocked and free)
    local l = CreateFrame("Button", "DuelsLooksTab", UIParent)
    l:SetWidth(30); l:SetHeight(116)
    l:SetPoint("TOP", t, "BOTTOM", 0, -8)
    l:SetFrameStrata("MEDIUM")
    UI.Skin(l, "panel")
    local li = l:CreateTexture(nil, "ARTWORK")
    li:SetWidth(22); li:SetHeight(22)
    li:SetPoint("TOP", l, "TOP", 0, -5)
    li:SetTexture("Interface\\Icons\\INV_Misc_Bag_EnchantedRunecloth")
    for i = 1, 5 do
        local x = UI.Label(l, 12, UI.ACCENT)
        x:SetPoint("TOP", l, "TOP", 0, -30 - (i - 1) * 16)
        x:SetText(string.sub("LOOKS", i, i))
    end
    l:SetScript("OnClick", function() if Transmog and Transmog.Toggle then Transmog:Toggle() end end)
    l:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:SetText("Looks")
        GameTooltip:AddLine("Transmog: every look is unlocked and free here.", 0.9, 0.9, 0.9, 1)
        GameTooltip:Show()
    end)
    l:SetScript("OnLeave", function() GameTooltip:Hide() end)
    l:Hide()
    A.looksTab = l
    return t
end

-- the Armory on the minimap's top left too (owner, 2026-10-22): any gear, any loadout
function A.BuildMinimap()
    if A.mini then return A.mini end
    if not Minimap then return nil end
    local mm = CreateFrame("Button", "DuelsArmoryMinimapButton", Minimap)
    mm:SetWidth(31); mm:SetHeight(31)
    mm:SetFrameStrata("MEDIUM")
    mm:SetPoint("TOPLEFT", Minimap, "TOPLEFT", -10, 2)
    local icon = mm:CreateTexture(nil, "BACKGROUND")
    icon:SetTexture("Interface\\Icons\\INV_Chest_Plate04")
    icon:SetWidth(20); icon:SetHeight(20)
    icon:SetPoint("CENTER", mm, "CENTER", 0, 1)
    local ring = mm:CreateTexture(nil, "OVERLAY")
    ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    ring:SetWidth(53); ring:SetHeight(53)
    ring:SetPoint("TOPLEFT", mm, "TOPLEFT", 0, 0)
    mm:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    mm:SetScript("OnClick", function() A.Toggle() end)
    mm:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_LEFT")
        GameTooltip:SetText("Armory")
        GameTooltip:AddLine("Any gear, piece by piece, and your saved loadouts.", 0.9, 0.9, 0.9, 1)
        GameTooltip:Show()
    end)
    mm:SetScript("OnLeave", function() GameTooltip:Hide() end)
    mm:Hide()
    A.mini = mm
    return mm
end

-- shown while on the Duels realm (checked twice a second: the realm's hello may come any time)
local watch = CreateFrame("Frame")
watch:SetScript("OnUpdate", function()
    this.t = (this.t or 0) + arg1
    if this.t < 0.5 then return end
    this.t = 0
    if A.refreshAt and GetTime() >= A.refreshAt then
        A.refreshAt = nil
        if win and win:IsShown() then A.UpdateDoll(); A.Refresh() end
    end
    if D.on then
        A.BuildTab():Show()
        if D.lite then A.looksTab:Hide() else A.looksTab:Show() end     -- no transmog in the bare arena
        if A.BuildMinimap() then A.mini:Show() end
    elseif A.tab then
        A.tab:Hide(); A.looksTab:Hide()
        if A.mini then A.mini:Hide() end
    end
end)
