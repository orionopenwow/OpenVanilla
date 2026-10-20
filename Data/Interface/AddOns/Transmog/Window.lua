--[[
    Window.lua  (Open Vanilla / Transmog)
    The Transmogrifier window, laid out as retail's since Midnight (and as Open Vanilla's mockup):

      left    Outfits (n/50): cards with the outfit's icon and name, a green "Active" pill on the
              one you wear, a shield on outfits that put themselves on (situations). Click a card
              to wear it (free, anywhere) and edit it; right-click or the cog for rename, icon,
              situations, "wear no outfit". The locked card and + New Outfit unlock the next slot.
      middle  your character on a stone dais in the dressing room of your race, the 14 slots
              around it (a chosen slot has a gold rim; on the right a bracket points at the
              collection; a changed slot glows purple; a hidden one shows a red cross), the view
              toolbar (turn, reset, slow spin, zoom on the slot, compare with your gear) and the
              labelled Main Hand / Off-Hand / Ranged slots.
      right   tabs Items (search, Filter: usable only, illusions, 3D previews; a 4 x 4 page of
              the looks collected for the slot, rimmed in their quality's colour, Hidden first),
              Sets, Custom Sets and Situations; the cost, Apply Transmog and Revert Changes.

    Art: Data/Interface/AddOns/Transmog/Art, drawn by tools/transmog/make_art.py (original).
    On wenilla only one dressing room draws at a time (OPENVANILLA_ONE_DRESSING_ROOM), so the
    collection shows icons there; the stock client can show 3D previews (Filter).
    Talk to a Transmogrifier (Lyriel Threadweave in Alliance towns, Morga Silkhand in Horde ones)
    to open it; /transmog opens it anywhere to look and to switch outfits.
]]--

local W = WenillaCore
local UI = W.UI
local T = Transmog

local strfind, strlower, format = string.find, string.lower, string.format
local getn, tinsert = table.getn, table.insert
local floor = math.floor

local WIN_W, WIN_H = 1000, 560
local LEFT_W = 220
local RIGHT_W = 303
local CELL_W, COLS, ROWS = 61, 4, 4
local PER_PAGE = COLS * ROWS
local PURPLE = { 0.72, 0.4, 1 }
local ART = "Interface\\AddOns\\Transmog\\Art\\"
local NPCS = { ["Lyriel Threadweave"] = true, ["Morga Silkhand"] = true }
T.NPCS = NPCS

T.view = nil            -- the outfit being edited
T.pending = {}          -- slot -> { look, ill } not saved yet
T.slot = 0              -- the slot whose looks the Items tab lists
T.page = 1
T.mode = "items"        -- items | illusions
T.search = ""
T.cost = 0
T.atNpc = false

local win, model, slotButtons, list, tabs, pages, cells, pageText, costMoney, costNote, applyBtn, resetBtn
local header, countText, countText2, searchBox, illBtn, statusText, viewName, situChecks, collText, emptyText

-- -- helpers -------------------------------------------------------------------------------

local function equipped(slot)
    local link = GetInventoryItemLink and GetInventoryItemLink("player", slot + 1)
    if not link then return nil end
    local _, _, id = strfind(link, "item:(%d+)")
    return tonumber(id)
end

local function saved(slot)
    local o = T.view and T.looks[T.view]
    return o and o[slot] or nil
end

-- The look a slot shows in the window: pending, else saved, else the equipped item (look 0).
local function effective(slot)
    local p = T.pending[slot]
    if p then return p.look or 0, p.ill or 0, true end
    local s = saved(slot)
    if s then return s.look or 0, s.ill or 0, false end
    return 0, 0, false
end
T.Effective = effective

local function changes()
    local out = {}
    for slot, p in pairs(T.pending) do
        local s = saved(slot) or { look = 0, ill = 0 }
        if (p.look or 0) ~= (s.look or 0) or (p.ill or 0) ~= (s.ill or 0) then out[slot] = p end
    end
    return out
end
T.Changes = changes

local function hasChanges()
    for _ in pairs(changes()) do return true end
    return false
end

local function slotTexture(slot)
    local info = T.SLOT_BY[slot]
    local _, tex = GetInventorySlotInfo(info.name)
    return tex
end

-- The stock dressing room's backdrop for the player's race (DressUpFrame.lua: gnomes use the
-- dwarven one, trolls the orcish one), four pieces that together are 318 x 383, cropped and scaled
-- to cover a w x h area without stretching.
local function raceBackdrop(parent, w, h)
    local _, race
    if UnitRace then _, race = UnitRace("player") end
    race = race or "Human"
    if race == "Gnome" then race = "Dwarf" elseif race == "Troll" then race = "Orc" end
    local file = "Interface\\DressUpFrame\\DressUpBackground-" .. race
    local CW, CH = 318, 383
    local sc = math.max(w / CW, h / CH)
    local x0 = (CW - w / sc) / 2
    local x1 = x0 + w / sc
    local y0 = (CH - h / sc) / 2
    local y1 = y0 + h / sc
    local pieces = {        -- composite rect, texture size
        { 1, 0, 256, 0, 255, 256, 256 }, { 2, 256, 318, 0, 255, 64, 256 },
        { 3, 0, 256, 255, 383, 256, 128 }, { 4, 256, 318, 255, 383, 64, 128 },
    }
    local out = {}
    for _, p in ipairs(pieces) do
        local ix0, ix1 = math.max(p[2], x0), math.min(p[3], x1)
        local iy0, iy1 = math.max(p[4], y0), math.min(p[5], y1)
        if ix1 > ix0 and iy1 > iy0 then
            local t = parent:CreateTexture(nil, "BACKGROUND")
            t:SetTexture(file .. p[1])
            t:SetTexCoord((ix0 - p[2]) / p[6], (ix1 - p[2]) / p[6], (iy0 - p[4]) / p[7], (iy1 - p[4]) / p[7])
            t:SetPoint("TOPLEFT", parent, "TOPLEFT", (ix0 - x0) * sc, -(iy0 - y0) * sc)
            t:SetWidth((ix1 - ix0) * sc)
            t:SetHeight((iy1 - iy0) * sc)
            tinsert(out, t)
        end
    end
    return out
end

-- Grid cells draw 3D models where the client can draw many dressing rooms at once (the stock
-- client), icons where it draws one (wenilla with Open Vanilla's patch says so) or by choice.
local function cellIcons()
    if OPENVANILLA_ONE_DRESSING_ROOM ~= nil then return true end
    if T.models ~= nil then return not T.models end
    return not W:Setting(T.ID, "models", false)
end
T.CellIcons = cellIcons

-- -- preview -------------------------------------------------------------------------------

function T:Dress(m, looks)
    if not m then return end
    m:SetUnit("player")
    m:Undress()
    for _, s in ipairs(T.SLOTS) do
        local look
        if looks then
            local l = looks[s.slot]
            look = l and l.look or 0
        else
            look = effective(s.slot)
        end
        if look and look > 0 then
            m:TryOn(look)
        elseif look ~= -1 then
            local real = equipped(s.slot)
            if real then m:TryOn(real) end
        end
    end
end

-- -- the cost ------------------------------------------------------------------------------

local costDue = 0
local function askCost()
    costDue = 0.3
end

local ticker = CreateFrame("Frame", "Transmog_CostTicker")
ticker:SetScript("OnUpdate", function()
    if costDue <= 0 then return end
    costDue = costDue - (arg1 or 0)
    if costDue > 0 then return end
    if T.view and T.view > 0 and hasChanges() then
        T:Send("cost " .. T.view .. " " .. T.FormatLooks(changes(), ","))
    else
        T.cost = 0
        if win then T:RefreshBottom() end
    end
end)

function T:RefreshBottom()
    if not win then return end
    local any = hasChanges()
    if not any then
        costMoney:SetText("|cff9a9aa6No changes|r")
    elseif T.firstFree or (T.cost or 0) == 0 then
        costMoney:SetText("Cost: |cff40ff40Free|r")
    else
        local enough = not GetMoney or GetMoney() >= (T.cost or 0)
        costMoney:SetText("Cost: " .. (enough and "" or "|cffff4040") .. T.CoinText(T.cost) .. (enough and "" or "|r"))
    end
    if not T.view or T.view == 0 then
        costNote:SetText("Pick or unlock an outfit to save looks to it.")
    elseif any and T.firstFree then
        costNote:SetText("|cff40ff40Free: your first saved outfit.|r")
    elseif any and not T.atNpc then
        costNote:SetText("Saving needs a Transmogrifier nearby.")
    else
        costNote:SetText("")
    end
    if any and T.view and T.view > 0 then applyBtn:Enable() else applyBtn:Disable() end
    if any then resetBtn:Enable() else resetBtn:Disable() end
end

-- -- slots ---------------------------------------------------------------------------------

local function paintSlot(b)
    local slot = b.slot
    local look, ill, pending = effective(slot)
    local tex
    if look and look > 0 then
        local _, _, t = T.ItemInfo(look)
        tex = t
    elseif look == 0 then
        tex = GetInventoryItemTexture and GetInventoryItemTexture("player", slot + 1)
    end
    if look == -1 then      -- hidden: the worn piece, greyed, under the red mark (as retail)
        tex = GetInventoryItemTexture and GetInventoryItemTexture("player", slot + 1)
    end
    b.icon:SetTexture(tex or slotTexture(slot))
    if b.icon.SetDesaturated then b.icon:SetDesaturated(look == -1 and 1 or nil) end
    if tex and look ~= -1 then b.icon:SetVertexColor(1, 1, 1) else b.icon:SetVertexColor(0.6, 0.6, 0.6) end
    if b.side == "bottom" then         -- weapon slots wear their item's quality, as the mockup
        local shown = (look and look > 0) and look or (look == 0 and equipped(slot)) or nil
        local _, q = T.ItemInfo(shown)
        local r, g, bb = 1, 1, 1
        if q and GetItemQualityColor then r, g, bb = GetItemQualityColor(q) end
        b.rim:SetVertexColor(r, g, bb)
    end
    if look == -1 then b.hidden:Show() else b.hidden:Hide() end
    if pending and changes()[slot] then b.glow:Show() else b.glow:Hide() end
    if T.slot == slot then
        b.sel:Show()
        if T.connector then
            if b.side == "right" and T.tab == "items" then
                T.connector:ClearAllPoints()
                T.connector:SetPoint("LEFT", b, "RIGHT", 2, 0)
                T.connector:Show()
            elseif b.side ~= "right" then
                T.connector:Hide()
            end
        end
    else
        b.sel:Hide()
    end
    if ill and ill > 0 then b.ill:Show() else b.ill:Hide() end
end

local function makeSlot(parent, info)
    local b = CreateFrame("Button", "TransmogSlot" .. info.name, parent)
    local big = info.weapon or info.slot == 17
    b:SetWidth(big and 42 or 38)
    b:SetHeight(big and 42 or 38)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b.slot = info.slot
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture(0.04, 0.04, 0.05, 0.92)
    bg:SetAllPoints(b)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetPoint("TOPLEFT", b, "TOPLEFT", 3, -3)
    b.icon:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -3, 3)
    b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    b.rim = b:CreateTexture(nil, "OVERLAY")
    b.rim:SetTexture("Interface\\AddOns\\Transmog\\Art\\SlotRim")
    b.rim:SetPoint("TOPLEFT", b, "TOPLEFT", -3, 3)
    b.rim:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 3, -3)
    b.hidden = b:CreateTexture(nil, "OVERLAY")
    b.hidden:SetTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
    b.hidden:SetPoint("CENTER", b, "CENTER", 0, 0)
    b.hidden:SetWidth(26)
    b.hidden:SetHeight(26)
    b.hidden:Hide()
    b.glow = b:CreateTexture(nil, "OVERLAY")
    b.glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    b.glow:SetBlendMode("ADD")
    b.glow:SetVertexColor(PURPLE[1], PURPLE[2], PURPLE[3])
    b.glow:SetPoint("CENTER", b, "CENTER", 0, 0)
    b.glow:SetWidth(68)
    b.glow:SetHeight(68)
    b.glow:Hide()
    b.sel = b:CreateTexture(nil, "OVERLAY")
    b.sel:SetTexture("Interface\\AddOns\\Transmog\\Art\\CellSel")
    b.sel:SetPoint("CENTER", b, "CENTER", 0, 0)
    b.sel:SetWidth(b:GetWidth() * 2.1)
    b.sel:SetHeight(b:GetHeight() * 2.1)
    b.sel:Hide()
    b.ill = b:CreateTexture(nil, "OVERLAY")
    b.ill:SetTexture("Interface\\Icons\\Spell_Holy_GreaterHeal")
    b.ill:SetWidth(14)
    b.ill:SetHeight(14)
    b.ill:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 2, -2)
    b.ill:Hide()
    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
    b:SetScript("OnClick", function()
        if arg1 == "RightButton" then
            T.pending[this.slot] = nil
            T.preview = nil
            T:Refresh()
            return
        end
        T:SelectSlot(this.slot)
    end)
    b:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        local look = effective(this.slot)
        GameTooltip:AddLine(info.label, 1, 0.82, 0)
        if look == -1 then
            GameTooltip:AddLine("Hidden", 0.8, 0.8, 0.8)
        elseif look and look > 0 then
            GameTooltip:AddLine(T.ItemLink(look), 1, 1, 1)
        else
            local real = equipped(this.slot)
            GameTooltip:AddLine(real and ("Equipped: " .. T.ItemLink(real)) or "Nothing equipped", 0.8, 0.8, 0.8)
        end
        if changes()[this.slot] then GameTooltip:AddLine("Changed. Right-click to undo.", PURPLE[1], PURPLE[2], PURPLE[3]) end
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end

function T:SelectSlot(slot)
    T.preview = nil
    T.slot = slot
    T.page = 1
    if not T.SLOT_BY[slot].weapon then T.mode = "items" end
    if not T.col[slot] then T:Send("col " .. slot) end
    T:Refresh()
end

-- -- the Items grid ------------------------------------------------------------------------

local SLOT_VIEW = {     -- model framing per slot: zoom toward the camera, raise or lower
    [0] = { 1.6, -0.55 }, [2] = { 1.2, -0.4 }, [14] = { 0.5, 0 }, [4] = { 0.9, -0.25 }, [3] = { 0.9, -0.25 },
    [18] = { 0.9, -0.25 }, [8] = { 1.1, 0 }, [9] = { 1.1, 0.05 }, [5] = { 1.2, 0 }, [6] = { 0.8, 0.3 },
    [7] = { 1.2, 0.6 }, [15] = { 0.4, 0 }, [16] = { 0.4, 0 }, [17] = { 0.4, 0 },
}

local function cellEntries()
    local out = {}
    local info = T.SLOT_BY[T.slot]
    if T.mode == "illusions" then
        tinsert(out, { kind = "noill" })
        for _, i in ipairs(T.ills or {}) do tinsert(out, { kind = "ill", enchant = i.enchant, name = i.name }) end
        return out
    end
    if info.hide then tinsert(out, { kind = "hide" }) end
    local seen = {}
    local q = strlower(T.search or "")
    for _, c in ipairs(T.col[T.slot] or {}) do
        -- one cell per appearance, as retail groups its sources
        if not seen[c.display] then
            local name = T.ItemInfo(c.item)
            if (q == "" or (name and strfind(strlower(name), q, 1, true))) and (c.ok or not T.usableOnly) then
                seen[c.display] = c
                tinsert(out, { kind = "look", item = c.item, display = c.display, ok = c.ok })
            end
        elseif c.ok and not seen[c.display].ok then
            seen[c.display].ok = true
        end
    end
    return out
end
T.CellEntries = cellEntries

local function paintCell(cell, e)
    cell.entry = e
    local look, ill = effective(T.slot)
    cell.model:Hide()
    cell.icon:Hide()
    cell.name:SetText("")
    cell.sel:Hide()
    cell.lock:Hide()
    cell.frame:Show()
    cell.frame:SetVertexColor(0.45, 0.45, 0.48)
    cell.name:SetTextColor(1, 1, 1)
    if not e then cell:Hide() return end
    cell:Show()
    local useIcons = cellIcons()
    if e.kind == "hide" then
        cell.icon:SetTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
        cell.icon:SetVertexColor(1, 1, 1)
        cell.icon:Show()
        cell.name:SetText("Hidden")
        if look == -1 then cell.sel:Show() end
        cell.frame:Show()
    elseif e.kind == "noill" then
        cell.icon:SetTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
        cell.icon:Show()
        cell.name:SetText("No illusion")
        if (ill or 0) == 0 then cell.sel:Show() end
        cell.frame:Show()
    elseif e.kind == "ill" then
        cell.icon:SetTexture("Interface\\Icons\\INV_Enchant_EssenceMagicLarge")
        cell.icon:Show()
        cell.name:SetText(e.name ~= "" and e.name or ("Illusion " .. e.enchant))
        if ill == e.enchant then cell.sel:Show() end
        cell.frame:Show()
    else
        local name, quality, tex = T.ItemInfo(e.item)
        if useIcons then
            cell.icon:SetTexture(tex or "Interface\\Icons\\INV_Misc_QuestionMark")
            cell.icon:Show()
        else
            local v = SLOT_VIEW[T.slot] or { 0.8, 0 }
            cell.model:Show()
            cell.model:SetUnit("player")
            cell.model:Undress()
            cell.model:TryOn(e.item)
            if cell.model.SetPosition then cell.model:SetPosition(v[1], 0, v[2]) end
        end
        local r, g, b = 1, 1, 1
        if quality and GetItemQualityColor then r, g, b = GetItemQualityColor(quality) end
        cell.frame:SetVertexColor(r, g, b)
        if not e.ok then cell.frame:SetVertexColor(0.35, 0.35, 0.35); cell.icon:SetVertexColor(0.5, 0.5, 0.5) else cell.icon:SetVertexColor(1, 1, 1) end
        cell.name:SetText(name or "")
        cell.name:SetTextColor(r, g, b)
        if not e.ok then cell.name:SetTextColor(0.6, 0.6, 0.6) end
        if look == e.item or (look and look > 0 and T.known[look] == e.display) then cell.sel:Show() end
        if not e.ok then cell.lock:Show() end
    end
end

local function cellClick(cell)
    local e = cell.entry
    if not e then return end
    T.preview = nil
    local p = T.pending[T.slot] or {}
    local look, ill = effective(T.slot)
    if e.kind == "hide" then
        T.pending[T.slot] = { look = -1, ill = 0 }
    elseif e.kind == "noill" then
        T.pending[T.slot] = { look = look, ill = 0 }
    elseif e.kind == "ill" then
        T.pending[T.slot] = { look = look, ill = e.enchant }
    else
        if not e.ok then T.Say("|cffff4040" .. T.Reason("class") .. "|r") return end
        T.pending[T.slot] = { look = e.item, ill = ill }
    end
    T:Refresh()
end

local function cellTip(cell)
    local e = cell.entry
    if not e then return end
    GameTooltip:SetOwner(cell, "ANCHOR_RIGHT")
    if e.kind == "look" then
        GameTooltip:SetHyperlink("item:" .. e.item .. ":0:0:0")
        local others = 0
        for _, c in ipairs(T.col[T.slot] or {}) do if c.display == e.display and c.item ~= e.item then others = others + 1 end end
        if others > 0 then GameTooltip:AddLine("Also collected from " .. others .. " other item" .. (others > 1 and "s" or ""), 0.53, 0.53, 0.93) end
        if not e.ok then GameTooltip:AddLine("Your class can't use this appearance.", 1, 0.25, 0.25) end
    elseif e.kind == "hide" then
        GameTooltip:AddLine("Hidden " .. T.SLOT_BY[T.slot].label, 1, 1, 1)
        GameTooltip:AddLine("Free.", 0.8, 0.8, 0.8)
    else
        GameTooltip:AddLine(cell.name:GetText() or "", 1, 1, 1)
    end
    GameTooltip:Show()
end

-- -- outfits list --------------------------------------------------------------------------

local function outfitItems()
    local items = {}
    for id = 1, T.unlocked do
        local o = T.outfits[id]
        tinsert(items, o or { id = id, name = "Outfit " .. id, icon = 0, situ = 0 })
    end
    if T.unlocked < T.max then tinsert(items, { id = -1, locked = true }) end
    return items
end

function T:ViewOutfit(id)
    T.preview = nil
    if T.view ~= id then T.pending = {} end
    T.view = id
    if id and id > 0 and not T.looks[id] then T:Send("outfit " .. id) end
    T:Refresh()
end

function T.OutfitMenu(id)
    local o = T.outfits[id]
    if not o then return end
    UI.Menu(win, {
        { text = o.name, title = true },
        { text = "Wear it", func = function() T:UseOutfit(id); T:ViewOutfit(id) end },
        { text = "Wear no outfit (your gear as it is)", func = function() T:UseOutfit(0) end },
        { text = "Rename", func = function()
            UI.Prompt({ title = "Rename outfit", default = o.name, maxLetters = 24, accept = "Rename",
                        onAccept = function(text) T:Send("name " .. id .. " " .. text) end })
        end },
        { text = "Use the chest look as its icon", func = function()
            local look = (T.looks[id] or {})[4]
            local item = (look and look.look and look.look > 0) and look.look or equipped(4)
            if item then T:Send("icon " .. id .. " " .. item) end
        end },
        { text = "Situations", func = function() T:ViewOutfit(id); T:SelectTab("situations") end },
    })
end

-- -- tabs: Sets, Custom Sets, Situations ----------------------------------------------------

local setList, csetList, csetSel
local SITU = {
    { "Location", { { 1, "Resting" }, { 2, "World" }, { 4, "Dungeons" }, { 8, "Raids" }, { 16, "Battlegrounds" } } },
    { "Movement", { { 256, "On foot" }, { 512, "Swimming" }, { 1024, "Mounted" } } },
    { "Time of day", { { 4096, "Morning" }, { 8192, "Midday" }, { 16384, "Evening" }, { 32768, "Night" } } },
    { "Weather", { { 65536, "Clear" }, { 131072, "Rain" }, { 262144, "Snow" }, { 524288, "Sandstorm" } } },
    { "Specialization", { { 1048576, "Spec 1" }, { 2097152, "Spec 2" } } },
}
T.SITU = SITU

local function slotOfEquipLoc(loc)
    local map = {
        INVTYPE_HEAD = 0, INVTYPE_SHOULDER = 2, INVTYPE_CLOAK = 14, INVTYPE_CHEST = 4, INVTYPE_ROBE = 4,
        INVTYPE_BODY = 3, INVTYPE_TABARD = 18, INVTYPE_WRIST = 8, INVTYPE_HAND = 9, INVTYPE_WAIST = 5,
        INVTYPE_LEGS = 6, INVTYPE_FEET = 7, INVTYPE_WEAPON = 15, INVTYPE_2HWEAPON = 15, INVTYPE_WEAPONMAINHAND = 15,
        INVTYPE_WEAPONOFFHAND = 16, INVTYPE_SHIELD = 16, INVTYPE_HOLDABLE = 16, INVTYPE_RANGED = 17,
        INVTYPE_RANGEDRIGHT = 17, INVTYPE_THROWN = 17,
    }
    return map[loc or ""]
end
T.SlotOfEquipLoc = slotOfEquipLoc

function T:UseSet(set)
    T.preview = nil
    for _, item in ipairs(set.items) do
        if T.known[item] then
            local _, _, _, _, loc = T.ItemInfo(item)
            local slot = slotOfEquipLoc(loc)
            if slot then T.pending[slot] = { look = item, ill = (T.pending[slot] or {}).ill or 0 } end
        end
    end
    T:Refresh()
end

-- Looks for a custom set / link: every slot not showing the equipped item.
function T:CurrentLooks()
    local out = {}
    for _, s in ipairs(T.SLOTS) do
        local look, ill = effective(s.slot)
        if (look and look ~= 0) or (ill and ill > 0) then out[s.slot] = { look = look, ill = ill } end
    end
    return out
end

function T:PreviewLooks(looks, title)
    T:Build()
    win:Show()
    T.pending = {}
    for slot, l in pairs(looks or {}) do T.pending[slot] = { look = l.look, ill = l.ill } end
    T.preview = nil
    T:SelectTab("items")
    T:Refresh()
    if title then statusText:SetText(title .. ": not yours to save until you've collected its looks.") end
end

-- -- outfit cards, the Filter menu ------------------------------------------------------------

T.SLOT_ZOOM = SLOT_VIEW

-- "Battlegrounds, Mounted": the ticked options of a situations mask, for cards and tooltips.
function T.SituText(mask)
    local out = {}
    for _, cat in ipairs(SITU) do
        for _, opt in ipairs(cat[2]) do
            if math.mod(floor((mask or 0) / opt[1]), 2) == 1 then tinsert(out, opt[2]) end
        end
    end
    return table.concat(out, ", ")
end

function T.PaintOutfitRow(row, it)
    row.badge:Hide()
    row.badgeText:Hide()
    row.auto:Hide()
    if it.locked then
        row.icon:SetTexture("Interface\\Icons\\INV_Misc_Key_03")
        row.icon:SetVertexColor(0.55, 0.55, 0.55)
        row.name:SetText("|cff8a8a8aLocked outfit slot|r")
        row.sub:SetText("")
        row.bg:SetTexture(ART .. "Card")
        row.bg:SetVertexColor(0.6, 0.6, 0.6)
        return
    end
    local tex
    if it.id == 0 then tex = "Interface\\Icons\\INV_Chest_Chain"
    elseif it.icon and it.icon > 0 then local _, _, t = T.ItemInfo(it.icon); tex = t end
    row.icon:SetTexture(tex or T.ICON)
    row.icon:SetVertexColor(1, 1, 1)
    row.name:SetText(it.name)
    local sub = ""
    if it.id == 0 then sub = "Your gear as it is"
    elseif it.situ and it.situ > 0 then sub = T.SituText(it.situ) end
    if string.len(sub) > 28 then sub = string.sub(sub, 1, 26) .. "..." end
    row.sub:SetText(sub)
    if it.id == T.active then row.badge:Show(); row.badgeText:Show() end
    if it.situ and it.situ > 0 then
        row.auto:ClearAllPoints()
        if it.id == T.active then row.auto:SetPoint("RIGHT", row.badge, "LEFT", -4, 0)
        else row.auto:SetPoint("RIGHT", row, "RIGHT", -8, 0) end
        row.auto:Show()
    end
    row.bg:SetVertexColor(1, 1, 1)
    row.bg:SetTexture(ART .. (it.id == T.view and "CardOn" or "Card"))
end

-- Filter: usable only, illusions for weapons, 3D previews or icons in the grid.
function T.FilterMenu(anchor)
    local info = T.SLOT_BY[T.slot]
    local entries = { { text = "Show", title = true } }
    tinsert(entries, { text = (T.usableOnly and "|cff40ff40v|r " or "    ") .. "Usable looks only", func = function()
        T.usableOnly = not T.usableOnly; T.page = 1; T:RefreshGrid() end })
    if info and info.weapon then
        tinsert(entries, { text = (T.mode == "illusions" and "|cff40ff40v|r " or "    ") .. "Illusions", func = function()
            T.mode = (T.mode == "illusions") and "items" or "illusions"
            if T.mode == "illusions" and not T.ills then T:Send("ill") end
            T.page = 1
            T:Refresh()
        end })
    end
    if OPENVANILLA_ONE_DRESSING_ROOM == nil then
        tinsert(entries, { text = (cellIcons() and "    " or "|cff40ff40v|r ") .. "3D previews", func = function()
            T.models = cellIcons() and true or false
            W:Settings(T.ID).models = T.models
            T:RefreshGrid() end })
    end
    UI.Menu(anchor, entries)
end

-- -- look ----------------------------------------------------------------------------------
-- The window's own pieces: dark panels with a thin bronze edge, flat dark buttons, the red Apply.

local EDGE = { 0.42, 0.36, 0.24 }       -- bronze panel edge
local GOLD = { 1, 0.82, 0.3 }
local THIN = {
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 8, edgeSize = 10,
    insets = { left = 2, right = 2, top = 2, bottom = 2 },
}

local function flourish(f)
    for _, c in ipairs({ { "BOTTOMLEFT", 0, 1, 1, 0 }, { "BOTTOMRIGHT", 1, 0, 1, 0 } }) do
        local t = f:CreateTexture(nil, "OVERLAY")
        t:SetTexture(ART .. "Corner")
        t:SetWidth(22)
        t:SetHeight(22)
        t:SetPoint(c[1], f, c[1], 0, 0)
        t:SetTexCoord(c[2], c[3], c[4], c[5])
        t:SetAlpha(0.8)
    end
end

local function panel(parent, x, y, w, h, fill)
    local f = CreateFrame("Frame", nil, parent)
    f:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
    f:SetWidth(w)
    f:SetHeight(h)
    f:SetBackdrop(THIN)
    fill = fill or { 0.035, 0.035, 0.045, 0.94 }
    f:SetBackdropColor(fill[1], fill[2], fill[3], fill[4])
    f:SetBackdropBorderColor(EDGE[1], EDGE[2], EDGE[3], 1)
    return f
end

-- A flat dark button with a bronze edge (tabs, pager, Filter, Revert, New Outfit). :SetActive(on)
-- gives it the gold edge and gold text of a chosen tab.
local function darkButton(parent, text, w, h, onClick, size)
    local b = CreateFrame("Button", nil, parent)
    b:SetWidth(w)
    b:SetHeight(h)
    b.face = b:CreateTexture(nil, "BACKGROUND")
    b.face:SetAllPoints(b)
    b.face:SetTexture(ART .. "BtnStone")
    local fs = UI.Label(b, size or 11)
    fs:SetPoint("CENTER", b, "CENTER", 0, 0)
    fs:SetJustifyH("CENTER")
    b.label = fs
    b:SetFontString(fs)              -- the button's own SetText/GetText use the label
    b:SetText(text)
    b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    local hl = b:GetHighlightTexture()
    if hl and hl.SetBlendMode then hl:SetBlendMode("ADD") end
    if onClick then b:SetScript("OnClick", onClick) end
    function b:SetActive(on)
        if self.isTab then self.face:SetTexture(ART .. (on and "TabOn" or "TabOff")) end
        if on then self.label:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
        else self.label:SetTextColor(0.86, 0.84, 0.8) end
    end
    local en, dis = b.Enable, b.Disable
    function b:Enable() en(self); self.label:SetAlpha(1); self.face:SetVertexColor(1, 1, 1) end
    function b:Disable() dis(self); self.label:SetAlpha(0.32); self.face:SetVertexColor(0.62, 0.62, 0.62) end
    b:SetActive(false)
    return b
end

-- -- build ---------------------------------------------------------------------------------

function T:SelectTab(key, fromTabs)
    T.tab = key
    for k, p in pairs(pages) do if k == key then p:Show() else p:Hide() end end
    if tabs then for k, b in pairs(tabs) do b:SetActive(k == key) end end
    if key == "sets" and not T.sets then T:Send("sets") end
    if key == "csets" and not T.csets then T:Send("cset list") end
    T:Refresh()
end

-- the mockup is laid out on 1024 x 572; the window is 1000 x 560
local K = WIN_W / 1024

local function S(v) return floor(v * K + 0.5) end

function T:Build()
    if win then return win end
    win = CreateFrame("Frame", "TransmogFrame", UIParent)
    win:SetWidth(WIN_W)
    win:SetHeight(WIN_H)
    win:SetPoint("CENTER", UIParent, "CENTER", 0, 20)
    win:SetFrameStrata("HIGH")
    win:SetToplevel(true)
    win:SetMovable(true)
    win:EnableMouse(true)
    if win.SetClampedToScreen then win:SetClampedToScreen(true) end
    win:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        tile = true, tileSize = 32, insets = { left = 6, right = 6, top = 6, bottom = 6 },
    })
    win:SetBackdropColor(0.05, 0.05, 0.06, 1)
    local edgeFrame = CreateFrame("Frame", nil, win)
    edgeFrame:SetAllPoints(win)
    edgeFrame:SetFrameLevel(win:GetFrameLevel() + 5)
    local function edgeTex(file, p1, x1, y1, p2, x2, y2, tc)
        local t = edgeFrame:CreateTexture(nil, "BORDER")
        t:SetTexture(ART .. file)
        t:SetPoint(p1, win, p1, x1, y1)
        t:SetPoint(p2, win, p2, x2, y2)
        if tc then t:SetTexCoord(tc[1], tc[2], tc[3], tc[4]) end
        return t
    end
    local E = 16
    edgeTex("EdgeH", "TOPLEFT", 0, 0, "TOPRIGHT", 0, -E)
    edgeTex("EdgeH", "BOTTOMLEFT", 0, E, "BOTTOMRIGHT", 0, 0, { 0, 1, 1, 0 })
    edgeTex("EdgeV", "TOPLEFT", 0, 0, "BOTTOMLEFT", E, 0, { 1, 0, 0, 1 })
    edgeTex("EdgeV", "TOPRIGHT", -E, 0, "BOTTOMRIGHT", 0, 0)
    for _, c in ipairs({ { "TOPLEFT", 0, 1, 0, 1 }, { "TOPRIGHT", 1, 0, 0, 1 }, { "BOTTOMLEFT", 0, 1, 1, 0 }, { "BOTTOMRIGHT", 1, 0, 1, 0 } }) do
        local t = edgeFrame:CreateTexture(nil, "ARTWORK")
        t:SetTexture(ART .. "Corner")
        t:SetWidth(40)
        t:SetHeight(40)
        t:SetPoint(c[1], win, c[1], 0, 0)
        t:SetTexCoord(c[2], c[3], c[4], c[5])
    end
    win:Hide()
    T.win = win
    if UISpecialFrames then tinsert(UISpecialFrames, "TransmogFrame") end
    win:SetScript("OnHide", function() T.atNpc = false; T.pending = {} end)
    win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", function() this:StartMoving() end)
    win:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)

    -- title plaque, portrait, close
    local plaque = edgeFrame:CreateTexture(nil, "OVERLAY")
    plaque:SetTexture(ART .. "Banner")
    plaque:SetWidth(400)
    plaque:SetHeight(50)
    plaque:SetPoint("TOP", win, "TOP", 0, 6)
    local title = UI.Label(edgeFrame, 12, { 0.95, 0.88, 0.7 })
    title:SetPoint("TOP", win, "TOP", 0, -12)
    title:SetJustifyH("CENTER")
    title:SetText("Transmogrifier")
    win.title = title
    local portrait = win:CreateTexture("TransmogFramePortrait", "BACKGROUND")
    portrait:SetWidth(54)
    portrait:SetHeight(54)
    portrait:SetPoint("TOPLEFT", win, "TOPLEFT", 6, -6)
    if not (SetPortraitToTexture and pcall(SetPortraitToTexture, "TransmogFramePortrait", T.ICON)) then
        portrait:SetTexture(T.ICON)
    end
    local ringFrame = CreateFrame("Frame", nil, win)
    ringFrame:SetAllPoints(win)
    ringFrame:SetFrameLevel(win:GetFrameLevel() + 6)
    local ring = ringFrame:CreateTexture(nil, "OVERLAY")
    ring:SetTexture(ART .. "Ring")
    ring:SetWidth(70)
    ring:SetHeight(70)
    ring:SetPoint("CENTER", portrait, "CENTER", 0, 0)
    local close = CreateFrame("Button", nil, edgeFrame)
    close:SetWidth(22)
    close:SetHeight(22)
    close:SetPoint("TOPRIGHT", win, "TOPRIGHT", -8, -8)
    close:SetNormalTexture(ART .. "Close")
    close:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
    close:SetScript("OnClick", function() win:Hide() end)

    -- left: outfits
    local left = panel(win, S(26), S(70), S(226), S(478))
    flourish(left)
    local div = left:CreateTexture(nil, "ARTWORK")
    div:SetTexture(EDGE[1], EDGE[2], EDGE[3], 0.7)
    div:SetHeight(1)
    div:SetPoint("TOPLEFT", left, "TOPLEFT", 6, -26)
    div:SetPoint("TOPRIGHT", left, "TOPRIGHT", -6, -26)
    local lh = UI.Label(left, 12, { 0.92, 0.9, 0.86 })
    lh:SetPoint("TOPLEFT", left, "TOPLEFT", 10, -10)
    countText = lh
    local gear = CreateFrame("Button", nil, left)
    gear:SetWidth(18)
    gear:SetHeight(18)
    gear:SetPoint("TOPRIGHT", left, "TOPRIGHT", -8, -7)
    gear:SetNormalTexture("Interface\\Icons\\INV_Misc_Gear_01")
    gear:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
    gear:SetScript("OnClick", function() if T.view and T.view > 0 then T.OutfitMenu(T.view) end end)
    gear:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:SetText("Outfit options")
        GameTooltip:AddLine("Rename, icon, situations. Or right-click an outfit.", 0.8, 0.8, 0.8)
        GameTooltip:AddLine(collText:GetText() or "", 1, 1, 1)
        GameTooltip:Show()
    end)
    gear:SetScript("OnLeave", function() GameTooltip:Hide() end)
    list = { rows = {}, offset = 0 }
    local ROWS_SHOWN = 9
    for i = 1, ROWS_SHOWN do
        local row = CreateFrame("Button", nil, left)
        row:SetWidth(S(210))
        row:SetHeight(S(42))
        row:SetPoint("TOPLEFT", left, "TOPLEFT", S(8), -(S(32) + (i - 1) * S(46)))
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints(row)
        row.bg:SetTexture(ART .. "Card")
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetWidth(32)
        row.icon:SetHeight(32)
        row.icon:SetPoint("LEFT", row, "LEFT", 5, 0)
        row.name = UI.Label(row, 11, { 1, 1, 1 })
        row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 8, -3)
        row.sub = UI.Label(row, 9, UI.MUTED)
        row.sub:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 8, 3)
        row.badge = row:CreateTexture(nil, "ARTWORK")
        row.badge:SetTexture(ART .. "Badge")
        row.badge:SetWidth(44)
        row.badge:SetHeight(16)
        row.badge:SetPoint("RIGHT", row, "RIGHT", -6, 4)
        row.badgeText = UI.Label(row, 9, { 0.85, 1, 0.85 })
        row.badgeText:SetPoint("CENTER", row.badge, "CENTER", 0, 0)
        row.badgeText:SetJustifyH("CENTER")
        row.badgeText:SetText("Active")
        row.auto = row:CreateTexture(nil, "ARTWORK")
        row.auto:SetTexture(ART .. "Shield")
        row.auto:SetWidth(20)
        row.auto:SetHeight(20)
        row.auto:SetPoint("RIGHT", row, "RIGHT", -8, 0)
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        row:SetScript("OnClick", function()
            local it = this.item
            if not it then return end
            if it.locked then
                UI.Menu(this, {
                    { text = "Unlock outfit slot " .. (T.unlocked + 1), title = true },
                    { text = "Unlock for " .. T.CoinText(T.nextCost), func = function() T:Send("unlock") end },
                })
                return
            end
            if arg1 == "RightButton" and it.id > 0 then T.OutfitMenu(it.id) return end
            T:UseOutfit(it.id)
            T:ViewOutfit(it.id)
        end)
        row:SetScript("OnEnter", function()
            local it = this.item
            if not it then return end
            GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
            if it.locked then
                GameTooltip:SetText("Locked outfit slot")
                GameTooltip:AddLine("Unlock: " .. T.CoinText(T.nextCost) .. " (for every character on your account)", 1, 1, 1, 1)
                GameTooltip:Show()
                return
            end
            GameTooltip:SetText(it.name)
            if it.id == T.active then GameTooltip:AddLine("You're wearing it.", 0.4, 1, 0.4) end
            if it.situ and it.situ > 0 then GameTooltip:AddLine("Puts itself on: " .. T.SituText(it.situ), 0.75, 0.6, 1, 1) end
            GameTooltip:AddLine("Click to wear and edit (free). Right-click for options.", 0.8, 0.8, 0.8, 1)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        list.rows[i] = row
    end
    left:EnableMouseWheel(true)
    left:SetScript("OnMouseWheel", function()
        list.offset = math.max(0, list.offset - (arg1 or 0))
        T:Refresh()
    end)
    function list:SetItems(items)
        local maxOff = math.max(0, getn(items) - ROWS_SHOWN)
        if self.offset > maxOff then self.offset = maxOff end
        for i, row in ipairs(self.rows) do
            local it = items[i + self.offset]
            row.item = it
            if it then row:Show(); T.PaintOutfitRow(row, it) else row:Hide() end
        end
    end
    local newOutfit = darkButton(left, "+ New Outfit", S(162), 24, function()
        if T.unlocked >= T.max then T.Say(T.Reason("full")) return end
        UI.Menu(this, {
            { text = "New outfit: slot " .. (T.unlocked + 1), title = true },
            { text = "Unlock for " .. T.CoinText(T.nextCost), func = function() T:Send("unlock") end },
        })
    end, 12)
    newOutfit:SetPoint("BOTTOM", left, "BOTTOM", 0, 8)
    T.newOutfitBtn = newOutfit

    -- middle: the character on the dais, the slots around it
    local mid = panel(win, S(258), S(40), S(424), S(508), { 0, 0, 0, 1 })
    local MW, MH = S(424), S(508)
    mid.backdrop = raceBackdrop(mid, MW - 6, MH - 6)
    for _, t in ipairs(mid.backdrop) do
        local p, rel, rp, x, y = t:GetPoint(1)
        t:ClearAllPoints()
        t:SetPoint(p, rel, rp, x + 3, y - 3)
        t:SetVertexColor(0.62, 0.58, 0.62)
    end
    local glowT = mid:CreateTexture(nil, "BORDER")
    glowT:SetTexture(ART .. "Glow")
    glowT:SetBlendMode("ADD")
    glowT:SetVertexColor(0.55, 0.42, 0.3)
    glowT:SetWidth(MW * 0.9)
    glowT:SetHeight(MH * 0.75)
    glowT:SetPoint("CENTER", mid, "TOP", 0, -MH * 0.38)
    local vig = mid:CreateTexture(nil, "BORDER")
    vig:SetTexture(ART .. "Vignette")
    vig:SetPoint("TOPLEFT", mid, "TOPLEFT", 3, -3)
    vig:SetPoint("BOTTOMRIGHT", mid, "BOTTOMRIGHT", -3, 3)
    local dais = mid:CreateTexture(nil, "ARTWORK")
    dais:SetTexture(ART .. "Pedestal")
    dais:SetWidth(S(420))
    dais:SetHeight(S(105))
    dais:SetPoint("TOP", mid, "TOP", 0, -S(322))
    model = CreateFrame("DressUpModel", "TransmogModel", mid)
    model:SetPoint("TOPLEFT", mid, "TOPLEFT", S(56), -S(14))
    model:SetPoint("BOTTOMRIGHT", mid, "TOPLEFT", MW - S(56), -S(388))
    model.rot = 0
    model:EnableMouse(true)
    model:SetScript("OnMouseDown", function() this.dragX = GetCursorPosition() end)
    model:SetScript("OnMouseUp", function() this.dragX = nil end)
    model:SetScript("OnUpdate", function()
        if this.dragX then
            local x = GetCursorPosition()
            this.rot = this.rot + (x - this.dragX) * 0.02
            this.dragX = x
            this:SetRotation(this.rot)
        elseif this.spin then
            this.rot = this.rot + (arg1 or 0) * 0.8
            this:SetRotation(this.rot)
        end
    end)
    T.model = model
    T.view3d = { zoom = false, spin = false, compare = false }

    -- the view toolbar on the dais: turn, reset, spin, zoom, compare
    local bar = CreateFrame("Frame", nil, mid)
    bar:SetWidth(S(200))
    bar:SetHeight(28)
    bar:SetPoint("TOP", mid, "TOP", 0, -S(384))
    bar:SetFrameLevel(model:GetFrameLevel() + 2)
    local barT = bar:CreateTexture(nil, "BACKGROUND")
    barT:SetTexture(ART .. "Bar")
    barT:SetAllPoints(bar)
    local function turner(dir)
        local b = CreateFrame("Button", nil, bar)
        b:SetWidth(18)
        b:SetHeight(26)
        b:SetPoint(dir < 0 and "RIGHT" or "LEFT", bar, dir < 0 and "LEFT" or "RIGHT", dir < 0 and -2 or 2, 0)
        local ch = UI.Label(b, 14, { 0.85, 0.7, 0.4 })
        ch:SetPoint("CENTER", b, "CENTER", 0, 1)
        ch:SetJustifyH("CENTER")
        ch:SetText(dir < 0 and "<" or ">")
        b:SetScript("OnMouseDown", function() this.spin = dir end)
        b:SetScript("OnMouseUp", function() this.spin = nil end)
        b:SetScript("OnHide", function() this.spin = nil end)
        b:SetScript("OnUpdate", function()
            if this.spin then
                model.rot = model.rot + this.spin * (arg1 or 0) * 3
                model:SetRotation(model.rot)
            end
        end)
        b:SetScript("OnEnter", function()
            GameTooltip:SetOwner(this, "ANCHOR_TOP")
            GameTooltip:SetText(dir < 0 and "Turn left" or "Turn right")
            GameTooltip:AddLine("Hold, or drag the character.", 0.8, 0.8, 0.8)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        return b
    end
    T.rotateButtons = { turner(-1), turner(1) }
    local tools = {
        { "IconMove", "Reset view", "Face the front, full size.", function()
            model.rot = 0; model:SetRotation(0); T.view3d.zoom = false; model.spin = nil; T.view3d.spin = false
            if model.SetPosition then model:SetPosition(0, 0, 0) end
        end },
        { "IconRotate", "Turn slowly", "Click again to stop.", function()
            T.view3d.spin = not T.view3d.spin; model.spin = T.view3d.spin or nil
        end },
        { "IconZoom", "Zoom in", "Close up on the slot you're changing.", function()
            T.view3d.zoom = not T.view3d.zoom
            local v = T.view3d.zoom and (T.SLOT_ZOOM[T.slot] or { 1.2, 0 }) or { 0, 0 }
            if model.SetPosition then model:SetPosition(v[1], 0, v[2]) end
        end },
        { "IconBrush", "Compare", "Show your gear as it is now; click again for the outfit.", function()
            T.view3d.compare = not T.view3d.compare
            T:Refresh()
        end },
    }
    T.toolButtons = {}
    for i, t in ipairs(tools) do
        local b = CreateFrame("Button", nil, bar)
        b:SetWidth(24)
        b:SetHeight(24)
        b:SetPoint("CENTER", bar, "CENTER", (i - 2.5) * 36, 0)
        b:SetNormalTexture(ART .. "Btn")
        b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
        local hl = b:GetHighlightTexture()
        if hl and hl.SetBlendMode then hl:SetBlendMode("ADD") end
        local g = b:CreateTexture(nil, "OVERLAY")
        g:SetTexture(ART .. t[1])
        g:SetWidth(18)
        g:SetHeight(18)
        g:SetPoint("CENTER", b, "CENTER", 0, 0)
        b.tip, b.tip2 = t[2], t[3]
        b:SetScript("OnClick", t[4])
        b:SetScript("OnEnter", function()
            GameTooltip:SetOwner(this, "ANCHOR_TOP")
            GameTooltip:SetText(this.tip)
            GameTooltip:AddLine(this.tip2, 0.8, 0.8, 0.8, 1)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        T.toolButtons[i] = b
    end

    slotButtons = {}
    local leftSlots = { 0, 2, 14, 4, 3, 18, 8 }
    local rightSlots = { 9, 5, 6, 7 }
    local bottom = { { 15, "Main Hand" }, { 16, "Off-Hand" }, { 17, "Ranged" } }
    for i, slot in ipairs(leftSlots) do
        local b = makeSlot(mid, T.SLOT_BY[slot])
        b:SetPoint("TOPLEFT", mid, "TOPLEFT", S(12), -(S(42) + (i - 1) * S(49)))
        b.side = "left"
        slotButtons[slot] = b
    end
    for i, slot in ipairs(rightSlots) do
        local b = makeSlot(mid, T.SLOT_BY[slot])
        b:SetPoint("TOPRIGHT", mid, "TOPRIGHT", -S(12), -(S(64) + (i - 1) * S(49)))
        b.side = "right"
        slotButtons[slot] = b
    end
    for i, s in ipairs(bottom) do
        local b = makeSlot(mid, T.SLOT_BY[s[1]])
        b:SetPoint("TOP", mid, "TOP", (i - 2) * S(72), -S(448))
        local l = UI.Label(mid, 10, { 0.9, 0.88, 0.82 })
        l:SetPoint("BOTTOM", b, "TOP", 0, 4)
        l:SetJustifyH("CENTER")
        l:SetText(s[2])
        b.side = "bottom"
        slotButtons[s[1]] = b
    end
    -- the gold bracket from a chosen right-hand slot to the collection
    local conn = win:CreateTexture(nil, "OVERLAY")
    conn:SetTexture(ART .. "Connector")
    conn:SetWidth(S(30))
    conn:SetHeight(16)
    conn:Hide()
    T.connector = conn
    viewName = UI.Label(mid, 12, UI.ACCENT)        -- kept for the browse note; the list names the outfit
    viewName:Hide()

    -- right: tabs and their pages
    local right = panel(win, S(688), S(40), S(310), S(508))
    flourish(right)
    T.rightPanel = right
    tabs = {}
    local TABS = { { "items", "Items", 56 }, { "sets", "Sets", 50 }, { "csets", "Custom Sets", 90 }, { "situations", "Situations", 80 } }
    local tx = 6
    for _, t in ipairs(TABS) do
        local key = t[1]
        local b = darkButton(right, t[2], S(t[3]), 22, function() T:SelectTab(key, true) end, 11)
        b.isTab = true
        b:SetPoint("TOPLEFT", right, "TOPLEFT", S(tx), -6)
        tx = tx + t[3] + 4
        tabs[key] = b
    end
    pages = {}
    local RW = S(310)
    local function page(key)
        local p = CreateFrame("Frame", nil, right)
        p:SetPoint("TOPLEFT", right, "TOPLEFT", 0, -34)
        p:SetWidth(RW)
        p:SetHeight(S(508) - 34 - 76)
        p:Hide()
        pages[key] = p
        return p
    end

    -- Items: search, Filter, the 4 x 4 collection, pages
    local items = page("items")
    searchBox = UI.SearchBox(items, { width = S(212), placeholder = "Search appearances...", onChange = function(t)
        T.search = t
        T.page = 1
        T:RefreshGrid()
    end })
    searchBox:SetHeight(22)
    if searchBox.SetBackdrop then searchBox:SetBackdrop(nil) end
    local fieldT = searchBox:CreateTexture(nil, "BACKGROUND")
    fieldT:SetTexture(ART .. "Field")
    fieldT:SetAllPoints(searchBox)
    searchBox:SetPoint("TOPLEFT", items, "TOPLEFT", 8, -2)
    if searchBox.placeholder then
        searchBox.placeholder:ClearAllPoints()
        searchBox.placeholder:SetPoint("LEFT", searchBox, "LEFT", 22, 0)
    end
    if searchBox.SetTextInsets then searchBox:SetTextInsets(22, 6, 0, 0) end
    local mag = searchBox:CreateTexture(nil, "OVERLAY")
    mag:SetTexture(ART .. "IconZoom")
    mag:SetWidth(14)
    mag:SetHeight(14)
    mag:SetVertexColor(0.7, 0.7, 0.7)
    mag:SetPoint("LEFT", searchBox, "LEFT", 5, 0)
    local filter = darkButton(items, "Filter", S(76), 22, function() T.FilterMenu(this) end, 11)
    filter:SetPoint("LEFT", searchBox, "RIGHT", 6, 0)
    filter.label:ClearAllPoints()
    filter.label:SetPoint("CENTER", filter, "CENTER", -6, 0)
    local arrow = filter:CreateTexture(nil, "OVERLAY")
    arrow:SetTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up")
    arrow:SetWidth(16)
    arrow:SetHeight(16)
    arrow:SetPoint("RIGHT", filter, "RIGHT", -2, 0)
    illBtn = filter                                -- the Illusions view lives in the Filter menu
    header = UI.Label(items, 1)                    -- the chosen slot is shown by its gold rim
    header:Hide()
    countText2 = UI.Label(items, 1)
    countText2:Hide()
    T.countText2 = countText2
    cells = {}
    for i = 1, PER_PAGE do
        local c = CreateFrame("Button", nil, items)
        c:SetWidth(CELL_W)
        c:SetHeight(CELL_W)
        local col = math.mod(i - 1, COLS)
        local row = floor((i - 1) / COLS)
        c:SetPoint("TOPLEFT", items, "TOPLEFT", S(12) + col * S(72), -(S(36) + row * S(86)))
        c.bg = c:CreateTexture(nil, "BACKGROUND")
        c.bg:SetTexture(0.05, 0.05, 0.06, 1)
        c.bg:SetPoint("TOPLEFT", c, "TOPLEFT", 2, -2)
        c.bg:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", -2, 2)
        c.model = CreateFrame("DressUpModel", nil, c)
        c.model:SetPoint("TOPLEFT", c, "TOPLEFT", 3, -3)
        c.model:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", -3, 3)
        c.model:EnableMouse(false)
        c.icon = c:CreateTexture(nil, "ARTWORK")
        c.icon:SetPoint("TOPLEFT", c, "TOPLEFT", 5, -5)
        c.icon:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", -5, 5)
        c.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        c.frame = c:CreateTexture(nil, "OVERLAY")       -- the quality-coloured rim
        c.frame:SetTexture(ART .. "CellRim")
        c.frame:SetAllPoints(c)
        c.name = UI.Label(c, 1)                          -- read by tooltips and tests; not drawn
        c.name:Hide()
        c.sel = c:CreateTexture(nil, "OVERLAY")
        c.sel:SetTexture(ART .. "CellSel")
        c.sel:SetWidth(CELL_W * 2)
        c.sel:SetHeight(CELL_W * 2)
        c.sel:SetPoint("CENTER", c, "CENTER", 0, 0)
        c.lock = c:CreateTexture(nil, "OVERLAY")
        c.lock:SetTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
        c.lock:SetWidth(16)
        c.lock:SetHeight(16)
        c.lock:SetPoint("TOPRIGHT", c, "TOPRIGHT", -3, -3)
        c:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
        local hl = c:GetHighlightTexture()
        if hl and hl.SetBlendMode then hl:SetBlendMode("ADD") end
        c:SetScript("OnClick", function() cellClick(this) end)
        c:SetScript("OnEnter", function() cellTip(this) end)
        c:SetScript("OnLeave", function() GameTooltip:Hide() end)
        cells[i] = c
    end
    T.cells = cells
    local pager = CreateFrame("Frame", nil, items)
    pager:SetWidth(S(150))
    pager:SetHeight(20)
    pager:SetPoint("TOP", items, "TOP", 0, -(S(36) + 4 * S(86) - S(8)))
    local prev = darkButton(pager, "<", 20, 20, function() T.page = math.max(1, T.page - 1); T:RefreshGrid() end, 11)
    prev:SetPoint("LEFT", pager, "LEFT", 0, 0)
    local nextB = darkButton(pager, ">", 20, 20, function() T.page = T.page + 1; T:RefreshGrid() end, 11)
    nextB:SetPoint("RIGHT", pager, "RIGHT", 0, 0)
    pageText = UI.Label(pager, 11, { 0.9, 0.88, 0.82 })
    pageText:SetPoint("CENTER", pager, "CENTER", 0, 0)
    pageText:SetJustifyH("CENTER")
    T.prevBtn, T.nextBtn = prev, nextB
    emptyText = UI.Label(items, 11, UI.MUTED)
    emptyText:SetPoint("TOP", items, "TOP", 0, -S(200))
    emptyText:SetWidth(RW - 40)
    emptyText:SetJustifyH("CENTER")
    emptyText:Hide()

    -- Sets
    local sets = page("sets")
    local sh = UI.Label(sets, 10, UI.MUTED)
    sh:SetPoint("TOPLEFT", sets, "TOPLEFT", 10, -6)
    sh:SetText("Click a set to preview it; the button beside it puts on the pieces you've collected.")
    sh:SetWidth(RW - 20)
    setList = UI.ScrollList(sets, {
        width = RW - 16, height = S(340), rowHeight = 32,
        build = function(row)
            row.name = UI.Label(row, 11)
            row.name:SetPoint("LEFT", row, "LEFT", 6, 0)
            row.have = UI.Label(row, 10, UI.MUTED)
            row.have:SetPoint("RIGHT", row, "RIGHT", -58, 0)
            row.use = darkButton(row, "Use", 46, 20, function() if this:GetParent().item then T:UseSet(this:GetParent().item) end end, 10)
            row.use:SetPoint("RIGHT", row, "RIGHT", -4, 0)
            row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
            row:SetScript("OnClick", function()
                local s = this.item
                if not s then return end
                local looks = {}
                for _, item in ipairs(s.items) do
                    local _, _, _, _, loc = T.ItemInfo(item)
                    local slot = T.SlotOfEquipLoc(loc)
                    if slot then looks[slot] = { look = item, ill = 0 } end
                end
                T.preview = looks
                T:Dress(model, looks)
            end)
        end,
        update = function(row, s)
            row.name:SetText(s.name)
            row.have:SetText(s.have .. "/" .. s.total)
            if s.have > 0 then row.use:Enable() else row.use:Disable() end
        end,
    })
    setList:SetPoint("TOPLEFT", sets, "TOPLEFT", 8, -34)

    -- Custom Sets
    local cs = page("csets")
    local ch = UI.Label(cs, 10, UI.MUTED)
    ch:SetPoint("TOPLEFT", cs, "TOPLEFT", 10, -2)
    ch:SetWidth(RW - 20)
    ch:SetText("Looks to keep or share: free, no outfit slot needed.")
    csetList = UI.ScrollList(cs, {
        width = RW - 16, height = S(300), rowHeight = 26,
        build = function(row)
            row.bg = row:CreateTexture(nil, "BACKGROUND")
            row.bg:SetAllPoints(row)
            row.name = UI.Label(row, 11)
            row.name:SetPoint("LEFT", row, "LEFT", 6, 0)
            row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
            row:SetScript("OnClick", function()
                csetSel = this.item
                T.preview = T.ParseLooks(this.item.looks, "/")
                T:Refresh()
            end)
        end,
        update = function(row, s)
            row.name:SetText(s.name)
            if csetSel and csetSel.id == s.id then row.bg:SetTexture(PURPLE[1], PURPLE[2], PURPLE[3], 0.18) else row.bg:SetTexture(0, 0, 0, 0) end
        end,
    })
    csetList:SetPoint("TOPLEFT", cs, "TOPLEFT", 8, -24)
    local function selLooks() return csetSel and T.ParseLooks(csetSel.looks, "/") end
    local bw = floor((RW - 16 - 8) / 3)
    local newB = darkButton(cs, "Save current", bw, 22, function()
        UI.Prompt({ title = "New custom set", default = "", maxLetters = 24, accept = "Save",
                    onAccept = function(text) T:Send("cset save 0 " .. text .. "~" .. T.FormatLooks(T:CurrentLooks(), "/")) end })
    end, 10)
    newB:SetPoint("BOTTOMLEFT", cs, "BOTTOMLEFT", 8, 32)
    local useB = darkButton(cs, "Use", bw, 22, function()
        local looks = selLooks()
        if not looks then return end
        for slot, l in pairs(looks) do
            if l.look <= 0 or T.known[l.look] then T.pending[slot] = { look = l.look, ill = l.ill } end
        end
        T.preview = nil
        T:SelectTab("items")
    end, 10)
    useB:SetPoint("LEFT", newB, "RIGHT", 4, 0)
    local linkB = darkButton(cs, "Link", bw, 22, function()
        if not csetSel then return end
        local text = T.LinkText(csetSel.name, csetSel.looks)
        if ChatFrameEditBox then
            ChatFrameEditBox:Show()
            ChatFrameEditBox:Insert(text)
        end
    end, 10)
    linkB:SetPoint("LEFT", useB, "RIGHT", 4, 0)
    local renB = darkButton(cs, "Rename", bw, 22, function()
        if not csetSel then return end
        local s = csetSel
        UI.Prompt({ title = "Rename custom set", default = s.name, maxLetters = 24, accept = "Rename",
                    onAccept = function(text) T:Send("cset save " .. s.id .. " " .. text .. "~" .. s.looks) end })
    end, 10)
    renB:SetPoint("TOPLEFT", newB, "BOTTOMLEFT", 0, -4)
    local delB = darkButton(cs, "Delete", bw, 22, function()
        if not csetSel then return end
        T:Send("cset del " .. csetSel.id)
        csetSel = nil
    end, 10)
    delB:SetPoint("LEFT", renB, "RIGHT", 4, 0)

    -- Situations
    local si = page("situations")
    local sih = UI.Label(si, 10, UI.MUTED)
    sih:SetPoint("TOPLEFT", si, "TOPLEFT", 10, -2)
    sih:SetWidth(RW - 20)
    sih:SetText("This outfit puts itself on when every category you tick here matches (any one option within a category). Free.")
    situChecks = {}
    local y = -38
    for _, cat in ipairs(SITU) do
        local l = UI.Label(si, 12, UI.ACCENT)
        l:SetPoint("TOPLEFT", si, "TOPLEFT", 10, y)
        l:SetText(cat[1])
        y = y - 16
        local colW = floor((RW - 16) / 3)
        for i, opt in ipairs(cat[2]) do
            local cb = CreateFrame("CheckButton", nil, si, "UICheckButtonTemplate")
            cb:SetWidth(20)
            cb:SetHeight(20)
            cb:SetPoint("TOPLEFT", si, "TOPLEFT", 8 + math.mod(i - 1, 3) * colW, y - floor((i - 1) / 3) * 20)
            cb.bit = opt[1]
            local t = UI.Label(si, 10)
            t:SetPoint("LEFT", cb, "RIGHT", 0, 1)
            t:SetText(opt[2])
            cb.label = t
            tinsert(situChecks, cb)
        end
        y = y - math.ceil(getn(cat[2]) / 3) * 20 - 8
    end
    local saveSitu = darkButton(si, "Save situations", S(150), 22, function()
        if not T.view or T.view == 0 then return end
        local mask = 0
        for _, cb in ipairs(situChecks) do if cb:GetChecked() then mask = mask + cb.bit end end
        T:Send("situ " .. T.view .. " " .. mask)
    end, 11)
    saveSitu:SetPoint("BOTTOMLEFT", si, "BOTTOMLEFT", 8, 6)

    -- bottom of the right panel: the cost, Apply Transmog, Revert Changes
    costMoney = UI.Label(right, 12, { 0.95, 0.93, 0.88 })
    costMoney:SetPoint("BOTTOMRIGHT", right, "BOTTOMRIGHT", -10, 44)
    costMoney:SetJustifyH("RIGHT")
    costNote = UI.Label(right, 10, UI.MUTED)
    costNote:SetPoint("BOTTOMLEFT", right, "BOTTOMLEFT", 10, 45)
    costNote:SetPoint("RIGHT", costMoney, "LEFT", -6, 0)
    local half = floor((S(310) - 18) / 2)
    applyBtn = CreateFrame("Button", nil, right)
    applyBtn:SetWidth(half)
    applyBtn:SetHeight(28)
    applyBtn:SetPoint("BOTTOMLEFT", right, "BOTTOMLEFT", 6, 8)
    applyBtn.face = applyBtn:CreateTexture(nil, "ARTWORK")
    applyBtn.face:SetTexture(ART .. "BtnRed")
    applyBtn.face:SetAllPoints(applyBtn)
    applyBtn.glow = applyBtn:CreateTexture(nil, "BACKGROUND")
    applyBtn.glow:SetTexture(ART .. "BtnGlow")
    applyBtn.glow:SetPoint("TOPLEFT", applyBtn, "TOPLEFT", -half * 0.32, 20)
    applyBtn.glow:SetPoint("BOTTOMRIGHT", applyBtn, "BOTTOMRIGHT", half * 0.32, -20)
    local al = UI.Label(applyBtn, 12, { 1, 0.86, 0.6 })
    al:SetPoint("CENTER", applyBtn, "CENTER", 0, 0)
    al:SetJustifyH("CENTER")
    al:SetText("Apply Transmog")
    applyBtn.label = al
    applyBtn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    local ahl = applyBtn:GetHighlightTexture()
    if ahl and ahl.SetBlendMode then ahl:SetBlendMode("ADD") end
    applyBtn:SetScript("OnClick", function()
        if not T.view or T.view == 0 or not hasChanges() then return end
        T:Send("save " .. T.view .. " " .. T.FormatLooks(changes(), ","))
    end)
    local aen, adis = applyBtn.Enable, applyBtn.Disable
    function applyBtn:Enable()
        aen(self)
        self.face:SetVertexColor(1, 1, 1)
        self.label:SetTextColor(1, 0.86, 0.6)
        self.glow:Show()
    end
    function applyBtn:Disable()
        adis(self)
        self.face:SetVertexColor(0.5, 0.42, 0.42)
        self.label:SetTextColor(0.62, 0.52, 0.46)
        self.glow:Hide()
    end
    applyBtn:Disable()
    resetBtn = darkButton(right, "Revert Changes", half, 28, function() T.pending = {}; T.preview = nil; T:Refresh() end, 12)
    resetBtn:SetPoint("BOTTOMRIGHT", right, "BOTTOMRIGHT", -6, 8)

    collText = UI.Label(left, 10, UI.MUTED)        -- the collection count, shown in the cog's tooltip
    collText:Hide()
    statusText = UI.Label(mid, 10, { 0.85, 0.82, 0.75 })
    statusText:SetPoint("TOP", mid, "TOP", 0, -6)
    statusText:SetJustifyH("CENTER")

    T:SelectTab("items")
    return win
end

-- -- refresh -------------------------------------------------------------------------------

function T:RefreshGrid()
    if not win then return end
    local entries = cellEntries()
    local pagesN = math.max(1, math.ceil(getn(entries) / PER_PAGE))
    if T.page > pagesN then T.page = pagesN end
    for i = 1, PER_PAGE do paintCell(cells[i], entries[(T.page - 1) * PER_PAGE + i]) end
    pageText:SetText("Page " .. T.page .. " / " .. pagesN)
    if T.page > 1 then T.prevBtn:Enable() else T.prevBtn:Disable() end
    if T.page < pagesN then T.nextBtn:Enable() else T.nextBtn:Disable() end
    local info = T.SLOT_BY[T.slot]
    if T.mode == "illusions" then
        header:SetText(info.label)
        T.countText2:SetText((T.ills and getn(T.ills) or 0) .. " illusions collected")
    else
        header:SetText(info.label)
        local n = 0
        local seen = {}
        for _, c in ipairs(T.col[T.slot] or {}) do if not seen[c.display] then seen[c.display] = true; n = n + 1 end end
        T.countText2:SetText(T.col[T.slot] and (n .. " appearances collected") or "Loading...")
    end
    if T.mode ~= "illusions" and T.col[T.slot] and getn(T.col[T.slot]) == 0 then
        emptyText:SetText("No appearances collected for this slot yet.\nItems you loot, equip or earn as quest rewards add theirs.")
        emptyText:Show()
    elseif T.mode ~= "illusions" and T.col[T.slot] and T.search ~= "" and getn(entries) <= (info.hide and 1 or 0) then
        emptyText:SetText("Nothing matches \"" .. T.search .. "\".")
        emptyText:Show()
    elseif T.mode == "illusions" and T.ills and getn(T.ills) == 0 then
        emptyText:SetText("No illusions yet.\nEnchanting one of your weapons adds its glow.")
        emptyText:Show()
    else
        emptyText:Hide()
    end
end

function T:Refresh()
    if not win or not win:IsShown() then return end
    if T.view == nil then T.view = (T.active and T.active > 0) and T.active or (T.unlocked > 0 and 1 or 0) end
    countText:SetText("Outfits (" .. (T.unlocked or 0) .. "/" .. (T.max or 50) .. ")")
    if T.newOutfitBtn then if T.unlocked < T.max then T.newOutfitBtn:Enable() else T.newOutfitBtn:Disable() end end
    if win.title then win.title:SetText(T.atNpc and "Transmogrifier" or "Appearances") end
    local nKnown, seenDisplay = 0, {}
    for _, d in pairs(T.known or {}) do
        if d == 0 or not seenDisplay[d] then nKnown = nKnown + 1; if d ~= 0 then seenDisplay[d] = true end end
    end
    collText:SetText("|cffffd100" .. nKnown .. "|r appearances collected" .. (T.ills and ("\n|cffffd100" .. getn(T.ills) .. "|r illusions") or ""))
    list:SetItems(outfitItems())
    for _, b in pairs(slotButtons) do paintSlot(b) end
    local o = T.outfits[T.view]
    viewName:SetText(T.view == 0 and "Equipped gear" or (o and o.name or ""))
    if T.view3d and T.view3d.compare then T:Dress(model, {}) else T:Dress(model, T.preview) end
    if T.connector and T.tab ~= "items" then T.connector:Hide() end
    T:RefreshGrid()
    if setList and T.sets then setList:SetItems(T.sets) end
    if csetList and T.csets then csetList:SetItems(T.csets) end
    if situChecks then
        local mask = (o and o.situ) or 0
        for _, cb in ipairs(situChecks) do
            local on = math.mod(floor(mask / cb.bit), 2) == 1
            cb:SetChecked(on)
        end
    end
    if hasChanges() then askCost() else T.cost = 0 end
    T:RefreshBottom()
    if not T.atNpc then statusText:SetText("Browsing: save changes at a Transmogrifier.")
    else statusText:SetText("") end
end

-- On a realm without transmog the window still opens (it is a tab of Collections), dimmed under a
-- notice; the realm's "hi" answer lifts it.
function T:OffNotice()
    if not win then return end
    local n = win.offNotice
    if not n then
        n = CreateFrame("Frame", "TransmogOffNotice", win)
        n:SetPoint("TOPLEFT", win, "TOPLEFT", 14, -52)
        n:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -14, 14)
        n:SetFrameLevel(win:GetFrameLevel() + 30)
        n:EnableMouse(true)                      -- nothing under it can be clicked while it shows
        local bg = n:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(n)
        bg:SetTexture(0, 0, 0, 0.82)
        local ic = n:CreateTexture(nil, "ARTWORK")
        ic:SetWidth(64); ic:SetHeight(64)
        ic:SetPoint("CENTER", n, "CENTER", 0, 56)
        ic:SetTexture(T.ICON)
        local h = n:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        h:SetPoint("TOP", ic, "BOTTOM", 0, -14)
        h:SetText("Appearances aren't on for this realm")
        local s = n:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        s:SetPoint("TOP", ic, "BOTTOM", 0, -48)          -- clear of the heading at any font size
        s:SetWidth(520)
        s:SetJustifyH("CENTER")
        s:SetText("Transmog lets you save the looks of gear you have collected into outfits and switch between them for free. " ..
            "Play on a realm with transmog (Warfront) to collect looks and use outfits; your collection is kept for your whole account.")
        win.offNotice = n
    end
    if T.on then n:Hide() else n:Show() end
end

function T:Toggle(tab)
    T:Build()
    if win:IsShown() and not tab then win:Hide() return end
    win:Show()
    T:OffNotice()
    if not T.on then T:Send("hi") return end
    if T.view == nil then T.view = (T.active and T.active > 0) and T.active or (T.unlocked > 0 and 1 or 0) end
    if not T.knownAsked then T.knownAsked = true; T:Send("known") end
    T:Send("hi")
    if T.view and T.view > 0 then T:Send("outfit " .. T.view) end
    if not T.col[T.slot] then T:Send("col " .. T.slot) end
    T:SelectTab((tab and pages[tab]) and tab or (T.tab or "items"))
end

-- the realm's answers repaint what they touch
T:Listen(function(what, a, b)
    if win then T:OffNotice() end
    -- the realm said hello while the window was open under the notice: load what it shows
    if what == "hello" and win and win:IsShown() and not T.knownAsked then
        T.knownAsked = true
        T:Send("known")
        if T.view == nil then T.view = (T.active and T.active > 0) and T.active or (T.unlocked > 0 and 1 or 0) end
        if T.view and T.view > 0 then T:Send("outfit " .. T.view) end
        if not T.col[T.slot] then T:Send("col " .. T.slot) end
    end
    if what == "cost" then
        if a == T.view then T.cost = b or 0 end
        T:RefreshBottom()
        return
    end
    if what == "saved" then T.pending = {} end
    if what == "active" and T.view == nil then T.view = a end
    if what == "new" and win and win:IsShown() and not T.col[T.slot] then T:Send("col " .. T.slot) end
    T:Refresh()
end)

-- Talking to a Transmogrifier opens the window instead of the gossip page.
local npcWatch = CreateFrame("Frame", "Transmog_NpcWatch")
npcWatch:RegisterEvent("GOSSIP_SHOW")
npcWatch:SetScript("OnEvent", function()
    if not T.on or not W:IsActive(T.ID) then return end
    local name = UnitName and UnitName("npc")
    if name and NPCS[name] then
        if CloseGossip then CloseGossip() end
        T:Toggle("items")
        T.atNpc = true
        T:Refresh()
    end
end)
