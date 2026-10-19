--[[
    GearSets.lua  -  equipment sets for Bags
    Save what you are wearing as a named set (Tank, PvP, Fishing, ...) and put it back on with
    one click: from the Gear button on the Bags window, the one on the character window, or
    /gear <name>. Items come from your bags or from another slot (rings and trinkets swap
    places); what a set doesn't name is left alone. One move at a time, each after the last
    one landed, so nothing gets stuck on the cursor. Out of combat only: a swap asked for in
    combat happens the moment combat ends.

    Saved per character in WenillaCore_Config.gearsets["Name-Realm"] = { { name, icon, items } }.
    Setting: Bags > "Gear sets" (gearSets).
]]--

local W = WenillaCore
local UI = W.UI
local ID = "Bags"

Vault = Vault or {}
local V = Vault
local G = {}
V.Gear = G

local strfind, strlower, strsub, strlen = string.find, string.lower, string.sub, string.len
local getn = table.getn

local MAX_SETS = 12
local SLOTS = { 1, 2, 3, 15, 5, 4, 19, 9, 10, 6, 7, 8, 11, 12, 13, 14, 16, 17, 18 }
local GEAR_ICON = "Interface\\Icons\\INV_Chest_Plate06"
local STOCK_ICONS = {
    "Interface\\Icons\\Ability_Defend", "Interface\\Icons\\Ability_Warrior_DefensiveStance",
    "Interface\\Icons\\Ability_DualWield", "Interface\\Icons\\INV_Sword_27", "Interface\\Icons\\Spell_Holy_PowerWordShield",
    "Interface\\Icons\\Spell_Holy_HolyBolt", "Interface\\Icons\\Spell_Fire_FlameBolt", "Interface\\Icons\\Ability_Marksmanship",
    "Interface\\Icons\\INV_BannerPVP_02", "Interface\\Icons\\INV_Fishingpole_02", "Interface\\Icons\\INV_Misc_Bandage_15",
    "Interface\\Icons\\Ability_Mount_JungleTiger", "Interface\\Icons\\INV_Misc_Herb_07", "Interface\\Icons\\Trade_Mining",
    "Interface\\Icons\\INV_Misc_Food_15", "Interface\\Icons\\Spell_Nature_Swiftness",
}

local function enabled() return W:IsActive(ID) and W:Setting(ID, "gearSets", true) end

local function say(msg)
    if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cffffd100Gear:|r " .. msg) end
end
G.Say = say

local function charKey()
    return (UnitName("player") or "?") .. "-" .. (GetRealmName and GetRealmName() or "")
end

function G:Sets()
    if not WenillaCore_Config then WenillaCore_Config = {} end
    local c = WenillaCore_Config
    c.gearsets = c.gearsets or {}
    c.gearsets[charKey()] = c.gearsets[charKey()] or {}
    return c.gearsets[charKey()]
end

function G:Find(name)
    if not name or name == "" then return nil end
    local low = strlower(W.Trim(name))
    local prefix
    for i, s in ipairs(self:Sets()) do
        if strlower(s.name) == low then return s, i end
        if not prefix and strsub(strlower(s.name), 1, strlen(low)) == low then prefix = i end
    end
    if prefix then return self:Sets()[prefix], prefix end
    return nil
end

local function itemString(link)
    local _, _, s = strfind(link or "", "(item:[%-%d:]+)")
    return s
end
local function itemId(s)
    local _, _, id = strfind(s or "", "item:(%d+)")
    return tonumber(id)
end
local function itemName(s)
    local name = GetItemInfo and s and GetItemInfo(s)
    if name then return name end
    return "item " .. (itemId(s) or "?")
end

local function wornId(slot) return itemId(GetInventoryItemLink("player", slot)) end

-- -- Saving ------------------------------------------------------------------------------------------

function G:Snapshot()
    local items, n = {}, 0
    for _, slot in ipairs(SLOTS) do
        local s = itemString(GetInventoryItemLink("player", slot))
        if s then items[slot] = s n = n + 1 end
    end
    return items, n
end

function G:DefaultIcon(items)
    for _, slot in ipairs({ 5, 16, 1, 18 }) do
        if items[slot] then
            local tex = GetInventoryItemTexture("player", slot)
            if tex then return tex end
        end
    end
    return GEAR_ICON
end

function G:Save(name, quiet)
    name = W.Trim(string.gsub(name or "", "[|%c]", ""))
    if name == "" then return nil end
    if strlen(name) > 24 then name = strsub(name, 1, 24) end
    local items, n = self:Snapshot()
    if n == 0 then say("You aren't wearing anything to save.") return nil end
    local set = self:Find(name)
    if set and strlower(set.name) ~= strlower(name) then set = nil end   -- a prefix is not the same set
    if set then
        set.items = items
        if not quiet then say("Updated " .. set.name .. " with what you're wearing (" .. n .. " items).") end
    else
        if getn(self:Sets()) >= MAX_SETS then say("That's " .. MAX_SETS .. " sets already. Delete one first.") return nil end
        set = { name = name, icon = self:DefaultIcon(items), items = items }
        table.insert(self:Sets(), set)
        if not quiet then say("Saved " .. name .. " (" .. n .. " items).") end
    end
    self:Render()
    return set
end

function G:Delete(name)
    local set, i = self:Find(name)
    if not set then return end
    table.remove(self:Sets(), i)
    say("Deleted " .. set.name .. ".")
    self:Render()
end

function G:Rename(set, name)
    name = W.Trim(string.gsub(name or "", "[|%c]", ""))
    if name == "" then return end
    if strlen(name) > 24 then name = strsub(name, 1, 24) end
    set.name = name
    self:Render()
end

-- Is every item of the set on you right now?
function G:IsWorn(set)
    for slot, s in pairs(set.items) do
        if wornId(slot) ~= itemId(s) then return false end
    end
    return true
end

-- Items of the set that are neither on you nor in your bags.
function G:Missing(set)
    local out = {}
    local have = {}
    for _, slot in ipairs(SLOTS) do
        local id = wornId(slot)
        if id then have[id] = (have[id] or 0) + 1 end
    end
    for bag = 0, 4 do
        for slot = 1, (GetContainerNumSlots(bag) or 0) do
            local id = itemId(GetContainerItemLink(bag, slot))
            if id then have[id] = (have[id] or 0) + 1 end
        end
    end
    for _, slot in ipairs(SLOTS) do
        local s = set.items[slot]
        if s then
            local id = itemId(s)
            if (have[id] or 0) > 0 then have[id] = have[id] - 1 else table.insert(out, s) end
        end
    end
    return out
end

-- -- Swapping ---------------------------------------------------------------------------------------------

local function freeBagSlots()
    local n = 0
    for bag = 0, 4 do
        for slot = 1, (GetContainerNumSlots(bag) or 0) do
            if not GetContainerItemInfo(bag, slot) then n = n + 1 end
        end
    end
    return n
end

-- Where is item `id`? A bag slot (exact item string first), or another worn slot that the set
-- doesn't want it in.
local function findSource(set, id, want, target)
    for _, slot in ipairs(SLOTS) do
        if slot ~= target and wornId(slot) == id and itemId(set.items[slot]) ~= id then return "inv", slot end
    end
    local loose
    for bag = 0, 4 do
        for slot = 1, (GetContainerNumSlots(bag) or 0) do
            local link = GetContainerItemLink(bag, slot)
            if itemId(link) == id then
                if itemString(link) == want then return "bag", bag, slot end
                loose = loose or { bag, slot }
            end
        end
    end
    if loose then return "bag", loose[1], loose[2] end
    return nil
end

-- One move toward the set. Returns true when it moved something, false when done.
function G:StepOnce(set, missing)
    for _, slot in ipairs(SLOTS) do
        local want = set.items[slot]
        local id = itemId(want)
        if id and wornId(slot) ~= id and not missing[slot] then
            local kind, a, b = findSource(set, id, want, slot)
            if not kind then
                missing[slot] = true
            else
                -- a two-hander pushes the off hand into your bags: it needs room there
                if slot == 16 and not set.items[17] and wornId(17) then
                    local _, _, _, _, _, _, _, loc = GetItemInfo(want)
                    if loc == "INVTYPE_2HWEAPON" and freeBagSlots() < 1 then
                        self.blocked = "Make room for your off-hand first: a two-hander needs one free bag slot."
                        return false
                    end
                end
                if CursorHasItem and CursorHasItem() then ClearCursor() end
                if kind == "inv" then PickupInventoryItem(a) else PickupContainerItem(a, b) end
                EquipCursorItem(slot)
                if CursorHasItem and CursorHasItem() then
                    -- it didn't fit there (wrong slot type); don't leave it on the cursor
                    ClearCursor()
                    missing[slot] = true
                end
                return true
            end
        end
    end
    return false
end

G.job = nil
G.pending = nil      -- a set to put on when combat ends

function G:Equip(name)
    if not enabled() then return end
    local set = type(name) == "table" and name or self:Find(name)
    if not set then say("No gear set called \"" .. tostring(name) .. "\". /gear lists yours.") return end
    if UnitAffectingCombat("player") then
        self.pending = set
        say("You're in combat: " .. set.name .. " goes on when the fight ends.")
        self:Render()
        return
    end
    if self:IsWorn(set) then say("You're already wearing " .. set.name .. ".") return end
    self.job = { set = set, missing = {}, moves = 0, next = 0 }
    self.blocked = nil
    self:Render()
    self:Continue()
end

function G:Continue()
    local job = self.job
    if not job then return end
    if UnitAffectingCombat("player") then
        self.job = nil
        self.pending = job.set
        say("Combat started: the rest of " .. job.set.name .. " goes on when it ends.")
        self:Render()
        return
    end
    if job.moves < 40 and self:StepOnce(job.set, job.missing) then
        job.moves = job.moves + 1
        job.next = GetTime() + 0.15
        return
    end
    self.job = nil
    local set = job.set
    local lost = self:Missing(set)
    if self.blocked then
        say(self.blocked)
    elseif lost[1] then
        local names = {}
        for _, s in ipairs(lost) do table.insert(names, itemName(s)) end
        say("Equipped " .. set.name .. ", except " .. table.concat(names, ", ") .. " (not in your bags).")
    else
        say("Equipped " .. set.name .. ".")
    end
    WenillaCore_Config.gearLast = WenillaCore_Config.gearLast or {}
    WenillaCore_Config.gearLast[charKey()] = set.name
    self:Render()
end

-- -- Panel ---------------------------------------------------------------------------------------------------

local panel = CreateFrame("Frame", "Bags_GearPanel", UIParent)
UI.Skin(panel, "panel")
panel:SetWidth(204)
panel:SetHeight(120)
panel:SetFrameStrata("HIGH")
panel:EnableMouse(true)
panel:Hide()
table.insert(UISpecialFrames, "Bags_GearPanel")
G.panel = panel

local strip = panel:CreateTexture(nil, "ARTWORK")
strip:SetPoint("TOPLEFT", panel, "TOPLEFT", 3, -3)
strip:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -3, -3)
strip:SetHeight(20)
UI.Gradient(strip, 0.21, 0.21, 0.23, 0.11, 0.11, 0.12)
local stripIcon = panel:CreateTexture(nil, "OVERLAY")
stripIcon:SetWidth(14)
stripIcon:SetHeight(14)
stripIcon:SetPoint("LEFT", strip, "LEFT", 4, 0)
if not W:Art(stripIcon, "Bags_GearSets", GEAR_ICON) then stripIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
local stripTitle = UI.Label(panel, 11, { 0.95, 0.93, 0.88 }, "OUTLINE")
stripTitle:SetPoint("LEFT", stripIcon, "RIGHT", 6, 0)
stripTitle:SetText("Gear Sets")
local close = UI.CloseButton(panel, function() panel:Hide() end, 20)
close:SetPoint("RIGHT", strip, "RIGHT", 3, 0)

local emptyText = UI.Label(panel, 10, UI.MUTED)
emptyText:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -30)
emptyText:SetWidth(184)
emptyText:SetText("No sets yet. Put on your tank, PvP or fishing gear and save it here.")

local saveBtn = UI.Button(panel, "Save what I'm wearing", 184, 20, function()
    UI.Prompt({ title = "Save gear set", text = "A name for what you're wearing, like Tank, PvP or Fishing. An existing name is updated.",
        maxLetters = 24, accept = "Save", onAccept = function(name) G:Save(name) end })
end)
saveBtn:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 10, 10)

G.rows = {}
local ROW_H = 32

local function rowMenu(row)
    local set = row.set
    if not set then return end
    UI.Menu(row, {
        { text = set.name, title = true },
        { text = "Put it on", func = function() G:Equip(set) end },
        { text = "Update with what I'm wearing", func = function() G:Save(set.name) end },
        { text = "Rename", func = function()
            UI.Prompt({ title = "Rename " .. set.name, default = set.name, maxLetters = 24, accept = "Rename",
                onAccept = function(name) G:Rename(set, name) end })
        end },
        { text = "Change icon", func = function() G:PickIcon(set, row) end },
        { text = "Delete", color = { 1, 0.45, 0.4 }, func = function() G:Delete(set.name) end },
    })
end

local function newRow(i)
    local r = CreateFrame("Button", "Bags_GearRow" .. i, panel)
    r:SetWidth(184)
    r:SetHeight(ROW_H - 2)
    r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local bg = r:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(r)
    bg:SetTexture(UI.INSET[1], UI.INSET[2], UI.INSET[3], 0.6)
    r.box = UI.IconBox(r, ROW_H - 4)
    r.box:SetPoint("LEFT", r, "LEFT", 1, 0)
    r.name = UI.Label(r, 11, { 1, 1, 1 }, "OUTLINE")
    r.name:SetPoint("TOPLEFT", r.box, "TOPRIGHT", 7, -2)
    r.name:SetWidth(140)
    r.sub = UI.Label(r, 9, UI.MUTED)
    r.sub:SetPoint("TOPLEFT", r.name, "BOTTOMLEFT", 0, -2)
    r.sub:SetWidth(140)
    local hl = r:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(r)
    hl:SetTexture(1, 0.82, 0, 0.10)
    r:SetScript("OnClick", function()
        if arg1 == "RightButton" then rowMenu(this) elseif this.set then G:Equip(this.set) end
    end)
    r:SetScript("OnEnter", function()
        local set = this.set
        if not set then return end
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:SetText(set.name, 1, 0.82, 0)
        for _, slot in ipairs(SLOTS) do
            local s = set.items[slot]
            if s then
                local name, _, q = GetItemInfo(s)
                local r2, g2, b2 = 1, 1, 1
                if q and GetItemQualityColor then r2, g2, b2 = GetItemQualityColor(q) end
                GameTooltip:AddLine(name or itemName(s), r2, g2, b2)
            end
        end
        local lost = G:Missing(set)
        if lost[1] then GameTooltip:AddLine(getn(lost) .. " not in your bags (bank?)", 1, 0.45, 0.4) end
        GameTooltip:AddLine("Click to put it on. Right-click for more.", 0.4, 0.9, 0.4)
        GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    G.rows[i] = r
    return r
end

function G:Render()
    if not panel:IsShown() then return end
    local sets = self:Sets()
    local n = getn(sets)
    for i = 1, n do
        local set = sets[i]
        local r = self.rows[i] or newRow(i)
        r.set = set
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -28 - (i - 1) * ROW_H)
        r.box.icon:SetTexture(set.icon or GEAR_ICON)
        r.name:SetText(set.name)
        local count = 0
        for _ in pairs(set.items) do count = count + 1 end
        local lost = self:Missing(set)
        if self.job and self.job.set == set then
            r.sub:SetText("|cffffd100Putting it on...|r")
        elseif self.pending == set then
            r.sub:SetText("|cffffd100After combat|r")
        elseif self:IsWorn(set) then
            r.sub:SetText("|cff40ff40Wearing it|r  " .. count .. " items")
            r.box.edge:SetTexture(0.25, 0.85, 0.3, 1)
        elseif lost[1] then
            r.sub:SetText("|cffff7060" .. getn(lost) .. " missing|r  " .. count .. " items")
        else
            r.sub:SetText(count .. " items")
        end
        if not self:IsWorn(set) then r.box.edge:SetTexture(0.35, 0.35, 0.38, 1) end
        r:Show()
    end
    for i = n + 1, getn(self.rows) do self.rows[i].set = nil self.rows[i]:Hide() end
    if n == 0 then emptyText:Show() else emptyText:Hide() end
    local h = (n == 0) and 64 or (n * ROW_H)
    panel:SetHeight(28 + h + 36)
    if getn(sets) >= MAX_SETS then saveBtn:Disable() else saveBtn:Enable() end
end

-- the icon picker: the set's own items, then a few common ones
local picker = CreateFrame("Frame", "Bags_GearIcons", panel)
UI.Skin(picker, "raised")
picker:SetFrameStrata("DIALOG")
picker:EnableMouse(true)
picker:Hide()
picker.buttons = {}

function G:PickIcon(set, anchor)
    local icons, seen = {}, {}
    for _, slot in ipairs(SLOTS) do
        local s = set.items[slot]
        if s then
            local _, _, _, _, _, _, _, _, tex = GetItemInfo(s)
            if tex and not seen[tex] then seen[tex] = true table.insert(icons, tex) end
        end
    end
    for _, tex in ipairs(STOCK_ICONS) do
        if not seen[tex] then seen[tex] = true table.insert(icons, tex) end
    end
    local perRow = 8
    for i, tex in ipairs(icons) do
        local b = picker.buttons[i]
        if not b then
            b = CreateFrame("Button", "Bags_GearIcon" .. i, picker)
            b:SetWidth(22)
            b:SetHeight(22)
            b.box = UI.IconBox(b, 22)
            b.box:SetPoint("CENTER", b, "CENTER", 0, 0)
            local hl = b:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints(b)
            hl:SetTexture(1, 1, 1, 0.2)
            picker.buttons[i] = b
        end
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", picker, "TOPLEFT", 6 + math.mod(i - 1, perRow) * 24, -6 - math.floor((i - 1) / perRow) * 24)
        b.box.icon:SetTexture(tex)
        b.tex = tex
        b:SetScript("OnClick", function()
            set.icon = this.tex
            picker:Hide()
            G:Render()
        end)
        b:Show()
    end
    for i = getn(icons) + 1, getn(picker.buttons) do picker.buttons[i]:Hide() end
    local rows = math.floor((getn(icons) + perRow - 1) / perRow)
    picker:SetWidth(perRow * 24 + 10)
    picker:SetHeight(rows * 24 + 10)
    picker:ClearAllPoints()
    picker:SetPoint("TOPLEFT", anchor or panel, "BOTTOMLEFT", 0, -2)
    picker:Show()
end

-- Open beside the Bags window or the character window.
function G:Open(where)
    if not enabled() then return end
    panel:ClearAllPoints()
    if where == "character" and CharacterFrame then
        panel:SetPoint("TOPLEFT", CharacterFrame, "TOPRIGHT", -30, -14)
    elseif where == "bags" and Vault_Frame then
        panel:SetPoint("TOPRIGHT", Vault_Frame, "TOPLEFT", -4, 0)
    else
        panel:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
    end
    panel.where = where
    panel.anchor = (where == "character" and CharacterFrame) or (where == "bags" and Vault_Frame) or nil
    panel:Show()
    self:Render()
end

function G:Toggle(where)
    if panel:IsShown() and panel.where == where then panel:Hide() else self:Open(where) end
end

-- the panel closes with the window it was opened from
panel:SetScript("OnUpdate", function()
    if panel.anchor and not panel.anchor:IsVisible() then panel:Hide() end
end)
panel:SetScript("OnHide", function() picker:Hide() end)

-- -- Buttons on the Bags and character windows -----------------------------------------------------------

local function gearButton(name, parent, size)
    local b = CreateFrame("Button", name, parent)
    b:SetWidth(size)
    b:SetHeight(size)
    local t = b:CreateTexture(nil, "ARTWORK")
    t:SetAllPoints(b)
    if not W:Art(t, "Bags_GearSets", GEAR_ICON) then t:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
    b.icon = t
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(b)
    hl:SetTexture(1, 1, 1, 0.18)
    b:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_TOP")
        GameTooltip:SetText("Gear Sets", 1, 0.82, 0)
        GameTooltip:AddLine("Save what you wear and swap with one click.", 0.85, 0.85, 0.85, 1)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end

local bagsBtn
if Vault_Frame then
    bagsBtn = gearButton("Bags_GearButton", Vault_Frame, 14)
    bagsBtn:SetPoint("RIGHT", Vault_Frame.titleBar, "RIGHT", -64, 0)
    bagsBtn:SetScript("OnClick", function() G:Toggle("bags") end)
end
local charBtn
local charParent = PaperDollFrame or CharacterFrame
if charParent then
    charBtn = gearButton("Bags_GearCharButton", charParent, 22)
    charBtn:SetPoint("TOPRIGHT", CharacterFrame or charParent, "TOPRIGHT", -44, -40)
    charBtn:SetScript("OnClick", function() G:Toggle("character") end)
end

function G:Refresh()
    local on = enabled()
    if bagsBtn then if on then bagsBtn:Show() else bagsBtn:Hide() end end
    if charBtn then if on then charBtn:Show() else charBtn:Hide() end end
    if not on then panel:Hide() picker:Hide() self.job = nil self.pending = nil end
end

-- -- Events -----------------------------------------------------------------------------------------------

local ev = CreateFrame("Frame", "Bags_GearEvents")
for _, e in ipairs({ "PLAYER_REGEN_ENABLED", "UNIT_INVENTORY_CHANGED", "BAG_UPDATE", "PLAYER_ENTERING_WORLD" }) do ev:RegisterEvent(e) end
ev:SetScript("OnEvent", function()
    if event == "PLAYER_REGEN_ENABLED" then
        local set = G.pending
        if set and enabled() then
            G.pending = nil
            G:Equip(set)
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        G:Refresh()
    elseif panel:IsShown() and not G.job then
        G.dirty = true
    end
end)
ev:SetScript("OnUpdate", function()
    local job = G.job
    if job and GetTime() >= (job.next or 0) then
        if CursorHasItem and CursorHasItem() then return end
        G:Continue()
    end
    if G.dirty then
        G.dirty = nil
        G:Render()
    end
end)

-- the Bags refresher already runs on every settings change; hang ours on it
local origRefresh = W.refreshers[ID]
W.refreshers[ID] = function(active)
    if origRefresh then origRefresh(active) end
    G:Refresh()
end

SLASH_CPGEAR1 = "/gear"
SLASH_CPGEAR2 = "/gearset"
SlashCmdList["CPGEAR"] = function(msg)
    if not enabled() then return end
    msg = W.Trim(msg or "")
    local _, _, cmd, rest = strfind(msg, "^(%S+)%s*(.*)$")
    cmd = strlower(cmd or "")
    if msg == "" then
        if Vault_Frame and Vault_Frame:IsVisible() then G:Toggle("bags")
        elseif CharacterFrame and CharacterFrame:IsVisible() then G:Toggle("character")
        else G:Toggle(nil) end
    elseif cmd == "save" and rest ~= "" then
        G:Save(rest)
    elseif (cmd == "delete" or cmd == "remove") and rest ~= "" then
        G:Delete(rest)
    elseif cmd == "list" then
        local names = {}
        for _, s in ipairs(G:Sets()) do table.insert(names, s.name) end
        say(names[1] and ("Your sets: " .. table.concat(names, ", ") .. ".") or "No gear sets yet. /gear save <name> saves what you're wearing.")
    elseif cmd == "help" then
        say("|cffffd100/gear|r sets panel,  |cffffd100/gear <name>|r put a set on,  |cffffd100/gear save <name>|r,  |cffffd100/gear delete <name>|r,  |cffffd100/gear list|r.")
    else
        G:Equip(msg)
    end
end
