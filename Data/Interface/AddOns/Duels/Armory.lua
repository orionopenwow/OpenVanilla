--[[
    Armory.lua  (Duels)
    The armory window: one place to gear a duel body or a raider (modes roadmap, Phase 3; art pass 3a;
    the owner's three-panel layout, 2026-10-23).
      Gear      left: a paper doll with every slot
                middle: the gear picker for the chosen slot, worn item first: where each item comes from
                  (Molten Core, Onyxia, BWL, ZG, AQ, Naxxramas, PvP rank, world drop, kit), a source filter,
                  "unlocked only" and a search; click to choose, Wear to put it on
                right: Sets & Talent Builds: your class's tier sets T0 to T3, your saved sets and your
                  talent builds; a model trying the choice on and its stats against what you wear;
                  Compare (the model shows the choice or what you wear) and Apply selection
      Enchants  the enchants offered for the chosen slot
      Loadouts & Talent Builds  your class's kits, your saved loadouts, a loadout code to share or paste,
                and your talent builds (one per tree, switched at once on this realm)
    It talks to the realm through Warfront (".wnl wf pool <slot>", "slot <slot> <item>", "ench <slot>
    <spell>", "kit <key>") and the Talents addon (specs), and reads their answers (WP, WS, WE, WK, SP),
    so it needs no server change. Item sources and the tier sets are ArmoryData.lua's
    (tools/duels/gen_armory_data.py).

    Icons: GetItemInfo's icon is its 9th answer in 1.12 (name, link, quality, min level, type, subtype,
    stack, equip location, icon). The picker read a 10th, always nil, so every row showed a grey box or
    a question mark (fixed 2026-10-23). An item the client hasn't seen yet answers nothing at all: it
    shows the question mark, a hidden tooltip asks the realm for it, and the row is drawn again a
    second later.

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
A.SHORT = { Strength = "Str", Agility = "Agi", Stamina = "Sta", Intellect = "Int", Spirit = "Spi", Armor = "Armor" }
A.STAT_ORDER = { "Strength", "Agility", "Stamina", "Intellect", "Spirit", "Armor" }
A.QUALITY = { [0] = { 0.62, 0.62, 0.62 }, [1] = { 1, 1, 1 }, [2] = { 0.12, 1, 0 }, [3] = { 0, 0.44, 0.87 },
    [4] = { 0.64, 0.21, 0.93 }, [5] = { 1, 0.5, 0 } }

-- where an item comes from (ArmoryData.lua's codes) and the source filter's choices
A.SOURCE_NAMES = { MC = "Molten Core", ONY = "Onyxia's Lair", BWL = "Blackwing Lair", ZG = "Zul'Gurub",
    AQ20 = "Ruins of Ahn'Qiraj", AQ40 = "Temple of Ahn'Qiraj", NAXX = "Naxxramas", WORLD = "World drop",
    KIT = "Starter kit", DUNGEON = "Dungeons" }
A.FILTERS = { { key = "ALL", text = "All sources" }, { key = "MC", text = "Molten Core" }, { key = "ONY", text = "Onyxia's Lair" },
    { key = "BWL", text = "Blackwing Lair" }, { key = "ZG", text = "Zul'Gurub" }, { key = "AQ20", text = "Ruins of Ahn'Qiraj" },
    { key = "AQ40", text = "Temple of Ahn'Qiraj" }, { key = "NAXX", text = "Naxxramas" }, { key = "PVP", text = "PvP ranks" },
    { key = "WORLD", text = "World drops" }, { key = "KIT", text = "Starter kits" } }

-- the equip location GetItemInfo names -> the server slot it goes in (rings and trinkets: the first)
A.EQUIP_SLOT = { INVTYPE_HEAD = 0, INVTYPE_NECK = 1, INVTYPE_SHOULDER = 2, INVTYPE_BODY = 3, INVTYPE_CHEST = 4,
    INVTYPE_ROBE = 4, INVTYPE_WAIST = 5, INVTYPE_LEGS = 6, INVTYPE_FEET = 7, INVTYPE_WRIST = 8, INVTYPE_HAND = 9,
    INVTYPE_FINGER = 10, INVTYPE_TRINKET = 12, INVTYPE_CLOAK = 14, INVTYPE_WEAPON = 15, INVTYPE_2HWEAPON = 15,
    INVTYPE_WEAPONMAINHAND = 15, INVTYPE_SHIELD = 16, INVTYPE_HOLDABLE = 16, INVTYPE_WEAPONOFFHAND = 16,
    INVTYPE_RANGED = 17, INVTYPE_RANGEDRIGHT = 17, INVTYPE_THROWN = 17, INVTYPE_RELIC = 17 }

local win
A.slot = nil          -- the chosen slot
A.search = ""
A.onlyUnlocked = false
A.source = "ALL"      -- the source filter
A.queue = nil         -- a loadout being put on, one item at a time: { { slot, id }, ... }
A.pick = nil          -- the item chosen in the picker (worn with Wear)
A.sel = nil           -- the right panel's choice: { kind = "set"|"mine"|"spec"|"item", name, items = { [slot] = id }, ... }
A.setsTab = "tier"    -- the right panel's tab: tier | mine | spec
A.compare = false     -- the model shows what you wear (true) or the choice (false)

local function send(args) return F and F.Send and F.Send(args) end
local function say(msg) if D.Say then D.Say(msg) else W.Print(msg) end end
local function status(text) if win then win.status:SetText(text or "") end end
local function myClass() local _, c = UnitClass("player"); return c or "" end

local function wornId(slot)
    local link = GetInventoryItemLink and GetInventoryItemLink("player", slot + 1)
    if not link then return nil end
    local _, _, id = strfind(link, "item:(%d+)")
    return tonumber(id)
end

-- an item's name, quality, equip location and icon; the icon falls back to the question mark (never a grey box)
function A.Info(id)
    if not (id and GetItemInfo) then return nil, 1, nil, UI.UNKNOWN_ICON end
    local name, _, quality, _, _, _, _, equip, tex = GetItemInfo(id)
    return name, quality or 1, equip, tex or UI.UNKNOWN_ICON
end
function A.Icon(id)
    local _, _, _, tex = A.Info(id)
    return tex
end

-- an item's source code (ArmoryData.lua), or nil when the realm's pool doesn't have it
function A.Source(id) return ArmorySource and ArmorySource[id] end
function A.SourceName(code)
    if not code then return "Not on this realm" end
    local _, _, rank = strfind(code, "^PVP(%d+)$")
    if rank then return "PvP rank " .. rank end
    return A.SOURCE_NAMES[code] or code
end
local function sourceMatches(code)
    if A.source == "ALL" then return true end
    if not code then return false end
    if A.source == "PVP" then return strsub(code, 1, 3) == "PVP" end
    return code == A.source
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
            local _, _, armor = strfind(t, "^(%d+) Armor$")
            if armor then out.Armor = (out.Armor or 0) + tonumber(armor) end
        end
    end
    scan:Hide()
    return out
end

-- the totals of a set of items { [slot] = id }
function A.Totals(items)
    local out = {}
    for _, id in pairs(items or {}) do
        for stat, n in pairs(A.Stats(id)) do out[stat] = (out[stat] or 0) + n end
    end
    return out
end

local function signed(d, short)
    return (d > 0 and "|cff40ff60+" or "|cffff5040") .. d .. " " .. short .. "|r"
end

-- "+13 Str  +15 Sta" against what is worn in the slot
function A.Delta(id, slot)
    local main = A.MAIN[myClass()] or "Strength"
    local new, old = A.Stats(id), A.Stats(wornId(slot))
    local out = {}
    for _, stat in ipairs({ main, "Stamina" }) do
        local d = (new[stat] or 0) - (old[stat] or 0)
        if d ~= 0 then table.insert(out, signed(d, A.SHORT[stat])) end
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
    b.label:SetHeight(12)
    b.sub = UI.Label(b, 9, UI.MUTED)
    b.sub:SetPoint("TOPLEFT", b.label, "BOTTOMLEFT", 0, -1)   -- hangs under the name: a long item name runs down, never over it
    b.sub:SetWidth(74)
    b.sub:SetHeight(11)                       -- one line: a long item name is cut, never over the slot's name
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

-- ask for what isn't known yet, at most a few rounds per view (each round redraws a second later)
local function warmMissing(ids, key)
    local missing = {}
    for _, id in ipairs(ids) do if not (GetItemInfo and GetItemInfo(id)) then table.insert(missing, id) end end
    if getn(missing) == 0 then return end
    A.warmRounds = A.warmRounds or {}
    if (A.warmRounds[key] or 0) >= 3 then return end
    A.warmRounds[key] = (A.warmRounds[key] or 0) + 1
    A.Warm(missing)
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

-- a header in the window's gold
local function header(parent, text, x, y)
    local h = UI.Label(parent, 12, UI.ACCENT)
    h:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    h:SetText(text)
    return h
end

-- an item row: icon well with the quality edge, name, a second line, something on the right
local function itemRow(row, width)
    row.box = UI.IconBox(row, 28)
    row.box:SetPoint("LEFT", row, "LEFT", 2, 0)
    row.name = UI.Label(row, 11, UI.WHITE)
    row.name:SetPoint("TOPLEFT", row.box, "TOPRIGHT", 6, -1)
    row.name:SetWidth(width - 120)
    if row.name.SetJustifyH then row.name:SetJustifyH("LEFT") end
    row.sub = UI.Label(row, 9, UI.MUTED)
    row.sub:SetPoint("BOTTOMLEFT", row.box, "BOTTOMRIGHT", 6, 1)
    row.delta = UI.Label(row, 10, UI.WHITE)
    row.delta:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row.mark = row:CreateTexture(nil, "BACKGROUND")
    row.mark:SetAllPoints(row)
    row.mark:SetTexture(1, 0.82, 0, 0.10)
    row.mark:Hide()
    row:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
end

local function paintItem(row, id)
    local name, quality, _, tex = A.Info(id)
    local q = A.QUALITY[quality] or UI.WHITE
    row.box.icon:SetTexture(tex)
    row.box.edge:SetTexture(q[1], q[2], q[3], 1)
    row.name:SetText(name or ("Item " .. id .. "  (loading...)"))
    row.name:SetTextColor(q[1], q[2], q[3])
end

local function buildGear(p)
    -- left: the doll
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

    -- middle: the gear picker
    local X = 228
    p.head = header(p, "Gear picker", X, -2)
    p.slotName = UI.Label(p, 11, UI.WHITE)
    p.slotName:SetPoint("LEFT", p.head, "RIGHT", 8, 0)
    p.slotName:SetText("pick a slot on the left")
    p.sourceBtn = UI.Button(p, "All sources", 150, 18, function() A.SourceMenu(this) end)
    p.sourceBtn:SetPoint("TOPLEFT", p, "TOPLEFT", X, -20)
    p.unlocked = UI.Button(p, "Unlocked only", 104, 18, function()
        A.onlyUnlocked = not A.onlyUnlocked
        if A.onlyUnlocked then this:LockHighlight() else this:UnlockHighlight() end
        A.Refresh()
    end)
    p.unlocked:SetPoint("LEFT", p.sourceBtn, "RIGHT", 6, 0)
    p.search = UI.SearchBox(p, { name = "DuelsArmorySearch", width = 330, placeholder = "Search items",
        onChange = function(t) A.search = strlower(t or ""); A.Refresh() end })
    p.search:SetPoint("TOPLEFT", p, "TOPLEFT", X, -42)
    p.list = UI.ScrollList(p, {
        name = "DuelsArmoryList", width = 336, height = 264, rowHeight = 33,
        build = function(row)
            itemRow(row, 330)
            row:SetScript("OnClick", function() if row.item then A.Choose(row.item) end end)
            row:SetScript("OnDoubleClick", function() if row.item then A.Wear(row.item) end end)
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
            paintItem(row, item.id)
            local locked = item.tier > (F.tier or 0)
            local code = A.Source(item.id)
            local where = code and A.SourceName(code) or ""          -- the realm sent it, so it is on this realm
            row.sub:SetText(locked and ("|cffff6040Locked: tier " .. item.tier .. "|r  " .. where) or (item.worn and ("Worn now  " .. where) or where))
            row.delta:SetText(item.worn and "|cffffd100worn|r" or A.Delta(item.id, A.slot))
            row:SetAlpha(locked and 0.55 or 1)
            if A.pick and A.pick.id == item.id then row.mark:Show() else row.mark:Hide() end
        end,
    })
    p.list:SetPoint("TOPLEFT", p, "TOPLEFT", X, -66)
    p.list:SetItems({})                       -- no grey boxes before a slot is picked
    p.hint = UI.Label(p, 11, UI.MUTED)
    p.hint:SetPoint("TOPLEFT", p.list, "TOPLEFT", 6, -10)
    p.hint:SetWidth(320)
    if p.hint.SetJustifyH then p.hint:SetJustifyH("LEFT") end
    p.hint:SetText("Pick a slot on the left: every item it can wear on this realm shows here, with where it drops.")
    p.tryBtn = UI.Button(p, "Try on", 106, 22, function() A.TryPick() end)
    p.tryBtn:SetPoint("TOPLEFT", p, "TOPLEFT", X, -340)
    p.wearBtn = UI.Button(p, "Wear", 106, 22, function() if A.pick then A.Wear(A.pick) else status("Click an item first.") end end)
    p.wearBtn:SetPoint("LEFT", p.tryBtn, "RIGHT", 6, 0)
    p.countText = UI.Label(p, 10, UI.MUTED)
    p.countText:SetPoint("LEFT", p.wearBtn, "RIGHT", 8, 0)

    -- right: sets and talent builds, the model and the stats
    local R = 576
    header(p, "Sets & Talent Builds", R, -2)
    p.setTabs = UI.Tabs(p, { skin = true, height = 18, tabs = { { key = "tier", label = "Tier sets" }, { key = "mine", label = "My sets" },
        { key = "spec", label = "Talents" } }, onSelect = function(key) A.SetsTab(key) end })
    p.setTabs:SetPoint("TOPLEFT", p, "TOPLEFT", R, -20)
    p.sets = UI.ScrollList(p, {
        name = "DuelsArmorySets", width = 264, height = 108, rowHeight = 18,
        build = function(row)
            row.icon = row:CreateTexture(nil, "ARTWORK")
            row.icon:SetWidth(14); row.icon:SetHeight(14)
            row.icon:SetPoint("LEFT", row, "LEFT", 2, 0)
            row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
            row.text = UI.Label(row, 10, UI.WHITE)
            row.text:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
            row.text:SetWidth(200)
            if row.text.SetJustifyH then row.text:SetJustifyH("LEFT") end
            row.right = UI.Label(row, 9, UI.MUTED)
            row.right:SetPoint("RIGHT", row, "RIGHT", -4, 0)
            row.mark = row:CreateTexture(nil, "BACKGROUND")
            row.mark:SetAllPoints(row)
            row.mark:SetTexture(1, 0.82, 0, 0.10)
            row.mark:Hide()
            row:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
            row:SetScript("OnClick", function() if row.entry then A.SelectEntry(row.entry) end end)
        end,
        update = function(row, e)
            row.entry = e
            row.icon:SetTexture(e.icon or UI.UNKNOWN_ICON)
            row.text:SetText(e.label)
            row.right:SetText(e.right or "")
            if A.sel and A.sel.key == e.key then row.mark:Show() else row.mark:Hide() end
        end,
    })
    p.sets:SetPoint("TOPLEFT", p, "TOPLEFT", R, -42)
    p.model = CreateFrame("DressUpModel", "DuelsArmoryModel", p)
    p.model:SetWidth(124); p.model:SetHeight(188)
    p.model:SetPoint("TOPLEFT", p, "TOPLEFT", R, -156)
    UI.Skin(p.model, "inset")
    p.selName = UI.Label(p, 11, UI.ACCENT)
    p.selName:SetPoint("TOPLEFT", p, "TOPLEFT", R + 132, -158)
    p.selName:SetWidth(132)
    if p.selName.SetJustifyH then p.selName:SetJustifyH("LEFT") end
    p.selName:SetText("Your gear")
    p.stats = {}
    for i = 1, 9 do
        local l = UI.Label(p, 10, UI.WHITE)
        l:SetPoint("TOPLEFT", p, "TOPLEFT", R + 132, -176 - (i - 1) * 16)
        l:SetWidth(132)
        if l.SetJustifyH then l:SetJustifyH("LEFT") end
        p.stats[i] = l
    end
    p.compareBtn = UI.Button(p, "Compare", 124, 22, function() A.Compare() end)
    p.compareBtn:SetPoint("TOPLEFT", p, "TOPLEFT", R, -350)
    p.applyBtn = UI.Button(p, "Apply selection", 132, 22, function() A.ApplySelection() end)
    p.applyBtn:SetPoint("LEFT", p.compareBtn, "RIGHT", 8, 0)
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
    p.list:SetItems({})
end

local function buildLoadouts(p)
    header(p, "Kits for your class", 0, -2)
    p.kits = UI.ScrollList(p, {
        name = "DuelsArmoryKits", width = 266, height = 200, rowHeight = 18,
        build = function(row)
            row.text = UI.Label(row, 11, UI.WHITE)
            row.text:SetPoint("LEFT", row, "LEFT", 4, 0)
            row:SetScript("OnClick", function() if row.kit and F.EquipKit then F:EquipKit(row.kit.key); status("Equipping the " .. row.kit.spec .. " kit...") end end)
        end,
        update = function(row, k) row.kit = k; row.text:SetText(k.spec .. " · " .. (k.role or "")) end,
    })
    p.kits:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -20)
    p.kits:SetItems({})
    header(p, "My loadouts", 280, -2)
    p.mine = UI.ScrollList(p, {
        name = "DuelsArmoryMine", width = 266, height = 200, rowHeight = 18,
        build = function(row)
            row.text = UI.Label(row, 11, UI.WHITE)
            row.text:SetPoint("LEFT", row, "LEFT", 4, 0)
            row:SetScript("OnClick", function() if row.lo then A.Apply(row.lo.code) end end)
        end,
        update = function(row, lo) row.lo = lo; row.text:SetText(lo.name) end,
    })
    p.mine:SetPoint("TOPLEFT", p, "TOPLEFT", 280, -20)
    p.mine:SetItems({})
    header(p, "Talent builds", 560, -2)
    p.builds = UI.ScrollList(p, {
        name = "DuelsArmoryBuilds", width = 266, height = 200, rowHeight = 18,
        build = function(row)
            row.text = UI.Label(row, 11, UI.WHITE)
            row.text:SetPoint("LEFT", row, "LEFT", 4, 0)
            row:SetScript("OnClick", function() if row.spec then A.SwitchSpec(row.spec.n) end end)
        end,
        update = function(row, s) row.spec = s; row.text:SetText(s.label) end,
    })
    p.builds:SetPoint("TOPLEFT", p, "TOPLEFT", 560, -20)
    p.builds:SetItems({})
    local h3 = UI.Label(p, 10, UI.MUTED)
    h3:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -232)
    h3:SetText("Loadout code (import or export): Ctrl+C to copy, or paste one and press Wear")
    p.code = UI.SearchBox(p, { name = "DuelsArmoryCode", width = 420, placeholder = "OV1-..." })
    p.code:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -248)
    p.wear = UI.Button(p, "Wear", 80, 20, function() A.Apply(p.code:GetText()) end)
    p.wear:SetPoint("LEFT", p.code, "RIGHT", 6, 0)
    p.save = UI.Button(p, "Save current", 100, 20, function() A.Save() end)
    p.save:SetPoint("LEFT", p.wear, "RIGHT", 6, 0)
end

function A.Build()
    if win then return win end
    win = UI.Window("DuelsArmoryFrame", { width = 860, height = 500, title = "Armory", skin = true,
        icon = "Interface\\Icons\\INV_Chest_Plate04", point = { "CENTER", UIParent, "CENTER", 0, 40 } })
    if UISpecialFrames then table.insert(UISpecialFrames, "DuelsArmoryFrame") end
    win:Hide()
    win.pages = {}
    win.tabs = UI.Tabs(win, { skin = true, maxWidth = 190, tabs = { { key = "gear", label = "Gear" }, { key = "ench", label = "Enchants" },
        { key = "load", label = "Loadouts & Talent Builds" } }, onSelect = function(key) A.Select(key) end })
    win.tabs:SetPoint("TOPLEFT", win, "TOPLEFT", 10, -30)
    buildGear(page("gear"))
    buildEnchants(page("ench"))
    buildLoadouts(page("load"))
    win.status = UI.Label(win, 10, UI.MUTED)
    win.status:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", 12, 12)
    win.equip = UI.Button(win, "Best kit", 90, 22, function() A.BestKit() end)
    win.equip:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -10, 8)
    win:SetScript("OnShow", function() A.UpdateDoll(); A.FillSets(); A.ShowSelection() end)
    A.Select("gear")
    A.SetsTab(A.setsTab)
    return win
end

-- the window's tabs (a set or a build from the right panel is a table: A.Select works for both)
function A.Select(key)
    if not win then return end
    if type(key) == "table" then return A.SelectEntry(key) end
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
        if id and not tex then tex = A.Icon(id) end
        b.box.icon:SetTexture(tex or emptyTexture(slot))
        if b.sub then
            local name = id and GetItemInfo and GetItemInfo(id)
            -- one short line under the slot's name: a long item name ran over it (owner's screenshot, 2026-10-23)
            if name and string.len(name) > 17 then name = strsub(name, 1, 16) .. "..." end
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
    A.pick = nil
    if A.warmRounds then A.warmRounds.list = 0 end
    if F then F.slot = slot end
    local p = win.pages.gear
    p.slotName:SetText(A.NAMES[slot] or "")
    p.hint:Hide()
    A.UpdateDoll()
    if F.pools and F.pools[slot] then A.Refresh()
    else
        p.list:SetItems({})
        status("Loading the items for this slot...")
        send("pool " .. slot)
    end
    if win.page == "ench" then A.FillEnchants() end
end

-- the chosen slot's items: worn first, then unlocked, then by name; source, search and "unlocked only"
function A.Items()
    local pool = A.slot and F.pools and F.pools[A.slot] or {}
    local worn = A.slot and wornId(A.slot)
    local out = {}
    for _, it in ipairs(pool) do
        local name = strlower(GetItemInfo(it.id) or "")
        local okSearch = A.search == "" or strfind(name, A.search, 1, true)
        local okLock = not A.onlyUnlocked or it.tier <= (F.tier or 0)
        if okSearch and okLock and sourceMatches(A.Source(it.id)) then
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
    if not win then return end
    if win.pages.gear:IsShown() then A.FillSets() end
    if not A.slot then return end
    local items = A.Items()
    win.pages.gear.list:SetItems(items)
    local ids = {}
    for _, it in ipairs(items) do table.insert(ids, it.id) end
    warmMissing(ids, "list")
    local text = getn(items) .. " items for " .. (A.NAMES[A.slot] or "this slot")
    if A.source ~= "ALL" then text = text .. " from " .. A.SourceName(A.source == "PVP" and "PVP" or A.source) end
    win.pages.gear.countText:SetText(getn(items) .. " shown")
    status(text .. ".")
end

-- the source filter: a menu of the raids, PvP, world drops and kits
function A.SourceMenu(anchor)
    local items = {}
    for _, f in ipairs(A.FILTERS) do
        local key = f.key
        table.insert(items, { text = f.text, checked = (A.source == key), func = function() A.SetSource(key) end })
    end
    if UI.Menu then UI.Menu(anchor, items) end
end

function A.SetSource(key)
    A.source = key or "ALL"
    if win then
        local label = "All sources"
        for _, f in ipairs(A.FILTERS) do if f.key == A.source then label = f.text end end
        win.pages.gear.sourceBtn:SetText(label)
    end
    A.Refresh()
end

-- click an item: chosen (marked), tried on the model, its stats against what is worn
function A.Choose(item)
    A.pick = item
    local items = A.Current()
    items[A.slot] = item.id
    A.sel = { kind = "item", key = "item:" .. item.id, name = (GetItemInfo(item.id) or ("Item " .. item.id)), items = items, one = item }
    A.compare = false
    if win then win.pages.gear.list:Refresh() end
    A.ShowSelection()
end

function A.TryPick()
    if not A.pick then status("Click an item first.") return end
    A.Choose(A.pick)
end

function A.Wear(item)
    if item.tier > (F.tier or 0) then status("|cffff4040Locked: earn it with arena rating or honorable kills.|r") return end
    if item.worn then return end
    if send("slot " .. A.slot .. " " .. item.id) then status("Equipping " .. (GetItemInfo(item.id) or "it") .. "...") end
end

-- -- the right panel: tier sets, my sets, talent builds -------------------------------------------

function A.SetsTab(key)
    A.setsTab = key or "tier"
    if not win then return end
    win.pages.gear.setTabs:Select(A.setsTab, true)
    A.FillSets()
end

-- the class's tier sets: each with how many of its pieces the realm offers and how many you wear
function A.TierSets()
    local out = {}
    local worn = {}
    for _, id in pairs(A.Current()) do worn[id] = true end
    for _, set in ipairs((ArmoryTierSets or {})[myClass()] or {}) do
        local here, on = 0, 0
        for _, id in ipairs(set.items) do
            if A.Source(id) then here = here + 1 end
            if worn[id] then on = on + 1 end
        end
        table.insert(out, { kind = "set", key = "set:" .. set.name, name = set.name, set = set,
            label = set.tier .. "  " .. set.name, icon = A.Icon(set.items[1]),
            right = (on > 0 and (on .. " worn, ") or "") .. here .. "/" .. getn(set.items) .. " here" })
    end
    return out
end

function A.MySets()
    local out = {}
    for i, lo in ipairs(DuelsLoadouts) do
        local items = A.Decode(lo.code) or {}
        local first
        for _, slot in ipairs(A.SLOTS) do if items[slot] then first = items[slot] break end end
        table.insert(out, { kind = "mine", key = "mine:" .. i, name = lo.name, code = lo.code, items = items,
            label = lo.name, icon = first and A.Icon(first) or "Interface\\Icons\\INV_Chest_Plate04", right = "saved" })
    end
    return out
end

-- the talent builds: one per spec the realm keeps (the Talents addon's SP line), the active one marked
function A.Builds()
    local T = ClassicPlusTalents
    local out = {}
    local s = T and T.specs
    if not s then return out end
    for i = 1, s.count do
        local name = T.SpecName and T.SpecName(i) or ("Spec " .. i)
        local tex
        if GetTalentTabInfo then
            local _, icon = GetTalentTabInfo(i)
            tex = icon and ("Interface\\Icons\\" .. icon)
            if icon and strfind(icon, "\\", 1, true) then tex = icon end
        end
        table.insert(out, { kind = "spec", key = "spec:" .. i, n = i, name = name, icon = tex,
            label = name .. (i == s.active and "  |cffffd100(active)|r" or ""), right = (i == s.active) and "on" or "switch" })
    end
    return out
end

function A.FillSets()
    if not win then return end
    local list
    if A.setsTab == "mine" then list = A.MySets()
    elseif A.setsTab == "spec" then list = A.Builds()
    else
        list = A.TierSets()
        local ids = {}
        for _, e in ipairs(list) do for _, id in ipairs(e.set.items) do table.insert(ids, id) end end
        warmMissing(ids, "sets")
    end
    win.pages.gear.sets:SetItems(list)
end

-- a row of the right panel chosen: its items tried on the model, its stats against what is worn
function A.SelectEntry(e)
    if e.kind == "set" then
        local items = A.Current()
        for _, id in ipairs(e.set.items) do
            local _, _, equip = A.Info(id)
            local slot = equip and A.EQUIP_SLOT[equip]
            if slot then items[slot] = id end
        end
        A.sel = { kind = "set", key = e.key, name = e.name, items = items, set = e.set }
    elseif e.kind == "mine" then
        A.sel = { kind = "mine", key = e.key, name = e.name, items = e.items, code = e.code }
    elseif e.kind == "spec" then
        A.sel = { kind = "spec", key = e.key, name = e.name, n = e.n, items = A.Current() }
    end
    A.compare = false
    if win then win.pages.gear.sets:Refresh() end
    A.ShowSelection()
end

-- the model and the stats box
function A.ShowSelection()
    if not win then return end
    local p = win.pages.gear
    local m = p.model
    local sel = A.sel
    local showWorn = A.compare or not sel
    if m.SetUnit then m:SetUnit("player") end
    if not showWorn and sel.items and m.Undress and m.TryOn then
        m:Undress()
        for _, id in pairs(sel.items) do m:TryOn(id) end
    elseif m.Dress then
        m:Dress()
    end
    for i = 1, 9 do p.stats[i]:SetText("") end
    if not sel then
        p.selName:SetText("Your gear")
        p.compareBtn:Hide(); p.applyBtn:Hide()
        local t = A.Totals(A.Current())
        local i = 1
        for _, stat in ipairs(A.STAT_ORDER) do
            if t[stat] and i <= 9 then p.stats[i]:SetText(A.SHORT[stat] .. "  " .. t[stat]); i = i + 1 end
        end
        return
    end
    p.compareBtn:Show(); p.applyBtn:Show()
    p.selName:SetText(sel.name .. (showWorn and "  |cff9d9d9d(showing yours)|r" or ""))
    local lines = {}
    if sel.kind == "spec" then
        local T = ClassicPlusTalents
        table.insert(lines, (T and T.specs and T.specs.active == sel.n) and "Your active build" or "Switch to this build")
        if GetNumTalentTabs and GetTalentTabInfo then
            for t = 1, GetNumTalentTabs() do
                local name, _, points = GetTalentTabInfo(t)
                if name then table.insert(lines, name .. "  " .. (points or 0)) end
            end
        end
    else
        if sel.set then
            local here, n = 0, getn(sel.set.items)
            for _, id in ipairs(sel.set.items) do if A.Source(id) then here = here + 1 end end
            table.insert(lines, here .. " of " .. n .. " pieces on this realm")
            table.insert(lines, "From " .. A.SourceName(sel.set.source))
        elseif sel.one and A.Source(sel.one.id) then
            table.insert(lines, "From " .. A.SourceName(A.Source(sel.one.id)))
        end
        local new, old = A.Totals(sel.items), A.Totals(A.Current())
        local changed = false
        for _, stat in ipairs(A.STAT_ORDER) do
            local a, b = new[stat] or 0, old[stat] or 0
            if a ~= 0 or b ~= 0 then
                local d = a - b
                table.insert(lines, A.SHORT[stat] .. "  " .. a .. (d ~= 0 and ("  " .. signed(d, "")) or ""))
                if d ~= 0 then changed = true end
            end
        end
        if not changed then table.insert(lines, "|cff9d9d9dSame as what you wear|r") end
    end
    for i = 1, 9 do p.stats[i]:SetText(lines[i] or "") end
end

-- Compare: the model flips between the choice and what you wear
function A.Compare()
    if not A.sel then status("Choose a set, a saved set or an item first.") return end
    A.compare = not A.compare
    A.ShowSelection()
end

-- Apply selection: a set's pieces this realm offers and you've unlocked go on (one slot at a time), a
-- saved set as its code, a talent build is switched to
function A.ApplySelection()
    local sel = A.sel
    if not sel then status("Choose a set, a saved set or an item first.") return false end
    if sel.kind == "spec" then return A.SwitchSpec(sel.n) end
    if sel.kind == "mine" then return A.Apply(sel.code) end
    if sel.kind == "item" then A.Wear(sel.one) return true end
    local items, skipped = {}, 0
    local tiers = {}
    for _, slot in ipairs(A.SLOTS) do
        for _, it in ipairs((F.pools and F.pools[slot]) or {}) do tiers[it.id] = it.tier end
    end
    for _, id in ipairs(sel.set.items) do
        local _, _, equip = A.Info(id)
        local slot = equip and A.EQUIP_SLOT[equip]
        local tier = tiers[id]
        if slot and A.Source(id) and not (tier and tier > (F.tier or 0)) then items[slot] = id else skipped = skipped + 1 end
    end
    local ok = A.ApplyItems(items)
    if skipped > 0 then status((win and win.status:GetText() or "") .. "  " .. skipped .. " pieces skipped (not on this realm, or locked).") end
    return ok
end

function A.SwitchSpec(n)
    if D.Specs and D.Specs.Switch then
        if D.Specs.Switch(n) then status("Switching to " .. ((ClassicPlusTalents and ClassicPlusTalents.SpecName and ClassicPlusTalents.SpecName(n)) or ("spec " .. n)) .. "...") end
        return true
    end
    status("Talent builds are on their way from the realm.")
    return false
end

function A.FillEnchants()
    local p = win.pages.ench
    if not A.slot then p.list:SetItems({}) return end
    p.head:SetText((A.NAMES[A.slot] or "") .. " enchants")
    p.list:SetItems((WarfrontEnchants or {})[A.slot + 1] or {})
end

function A.Kits()
    local class = myClass()
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
    p.builds:SetItems(A.Builds())
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
    if win and A.setsTab == "mine" then A.FillSets() end
    status("Saved as " .. name .. ".")
    return name
end

-- put items { [slot] = id } on, one slot at a time (each WS answer sends the next)
function A.ApplyItems(items)
    A.queue = {}
    for _, slot in ipairs(A.SLOTS) do
        if items[slot] and items[slot] ~= wornId(slot) then table.insert(A.queue, { slot, items[slot] }) end
    end
    if getn(A.queue) == 0 then A.queue = nil; status("You're already wearing that.") return true end
    A.queueTotal = getn(A.queue)
    A.Next()
    return true
end

-- put a loadout on
function A.Apply(code)
    local items = A.Decode(code)
    if not items then status("|cffff4040That isn't a loadout code (it starts OV1-).|r") return false end
    return A.ApplyItems(items)
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

function A.Show()
    if not (UI and UI.Window) then return end
    A.Build()
    if not win:IsShown() then win:Show() end
    A.Select("gear")
    A.UpdateDoll()
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
    if win and win:IsShown() then A.UpdateDoll(); A.Refresh(); A.ShowSelection() end
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
    -- QUEUE, right under it (owner, 2026-10-23): a raider's Boss Fights queue, a dueler's Duels window
    local q = CreateFrame("Button", "DuelsQueueTab", UIParent)
    q:SetWidth(30); q:SetHeight(116)
    q:SetPoint("TOP", t, "BOTTOM", 0, -8)
    q:SetFrameStrata("MEDIUM")
    UI.Skin(q, "panel")
    local qi = q:CreateTexture(nil, "ARTWORK")
    qi:SetWidth(22); qi:SetHeight(22)
    qi:SetPoint("TOP", q, "TOP", 0, -5)
    qi:SetTexture("Interface\\Icons\\INV_Misc_Head_Dragon_Black")
    for i = 1, 5 do
        local x = UI.Label(q, 12, UI.ACCENT)
        x:SetPoint("TOP", q, "TOP", 0, -30 - (i - 1) * 16)
        x:SetText(string.sub("QUEUE", i, i))
    end
    q:SetScript("OnClick", function()
        local B = BossFights
        if B and B.on and B.Show then
            B:Show()
            if B.ShowPage then B:ShowPage("queue") end
        elseif D.Toggle then
            D:Toggle()
        end
    end)
    q:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:SetText("Queue")
        if BossFights and BossFights.on then
            GameTooltip:AddLine("Boss Fights: pick a raid, a tier and your role, then queue.", 0.9, 0.9, 0.9, 1)
        else
            GameTooltip:AddLine("The Duels window.", 0.9, 0.9, 0.9, 1)
        end
        GameTooltip:Show()
    end)
    q:SetScript("OnLeave", function() GameTooltip:Hide() end)
    q:Hide()
    A.queueTab = q
    -- LOOKS, under QUEUE: the Transmogrifier, anywhere on Duels (every look unlocked and free)
    local l = CreateFrame("Button", "DuelsLooksTab", UIParent)
    l:SetWidth(30); l:SetHeight(116)
    l:SetPoint("TOP", q, "BOTTOM", 0, -8)
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
        A.queueTab:Show()
        if D.lite then A.looksTab:Hide() else A.looksTab:Show() end     -- no transmog in the bare arena
        if A.BuildMinimap() then A.mini:Show() end
    elseif A.tab then
        A.tab:Hide(); A.queueTab:Hide(); A.looksTab:Hide()
        if A.mini then A.mini:Hide() end
    end
end)
