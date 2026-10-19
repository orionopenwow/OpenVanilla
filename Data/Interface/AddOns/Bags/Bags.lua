--[[
    Bags.lua  -  Vault
    Every bag in one window: a stone slot grid, live search, quality borders, coin footer.
    Opens from the B key and the bag buttons (setting "replaceBags").
    Bank: shown live under your bags while a banker is open, and remembered per character so
    the last-seen bank can be browsed anywhere with the Bank button. A server bank snapshot
    ("VT" packet) replaces the remembered one when telemetry is on.

    VT packet: "<itemId>,<count>,<quality>,<iconName>;..."   (bank contents, slot order)
]]--

local W = WenillaCore
local UI = W.UI
local ID = "Bags"

Vault = Vault or {}
local V = Vault
V.showBank = false
V.slots = {}

local COLS, SLOT, GAP = 6, 32, 4
local PAD = 14                     -- room on the left for the lanes' coloured borders
local WIDTH = PAD + 10 + COLS * SLOT + (COLS - 1) * GAP

local floor, strlower, strfind = math.floor, string.lower, string.find
local mod = math.mod or math.fmod

local QUALITY = {
    [0] = { 0.62, 0.62, 0.62 }, [1] = { 1, 1, 1 }, [2] = { 0.12, 1, 0 },
    [3] = { 0, 0.44, 0.87 }, [4] = { 0.64, 0.21, 0.93 }, [5] = { 1, 0.5, 0 },
}

-- Lanes: your bag slots grouped by what holds them, each with a label and a coloured left border.
-- A bag's family comes from the bag item itself (GetItemInfo type/subtype, or its name); "To open"
-- collects openable items (Star Pouches, lockboxes, anything whose tooltip says Right Click to Open)
-- from the ordinary bags.
V.LANES = {
    bags = { label = "Bags", color = { 1, 0.82, 0 } },
    open = { label = "To open", color = { 0.30, 0.62, 1 } },
    reagent = { label = "Reagent pouch", color = { 0.25, 0.85, 0.30 } },
    ammo = { label = "Ammo & quiver", color = { 0.82, 0.68, 0.45 } },
    soul = { label = "Soul pouch", color = { 0.66, 0.38, 0.92 } },
}
V.LANE_ORDER = { "bags", "open", "reagent", "ammo", "soul" }
V.STAR_POUCH_MIN, V.STAR_POUCH_MAX = 90100, 90105

local function charKey()
    return (UnitName("player") or "?") .. "-" .. (GetRealmName and GetRealmName() or "")
end

-- -- Window --------------------------------------------------------------------

local frame = UI.Window("Vault_Frame", {
    width = WIDTH, height = 200, title = "Bags",
    icon = "Interface\\Icons\\INV_Misc_Bag_10",
    point = { "BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -310, 100 },
    strata = "HIGH", skin = true,
})
frame:Hide()
table.insert(UISpecialFrames, "Vault_Frame")   -- Esc closes it, like the stock bags

local bankBtn = CreateFrame("Button", nil, frame)
bankBtn:SetWidth(40)
bankBtn:SetHeight(14)
bankBtn:SetPoint("RIGHT", frame.titleBar, "RIGHT", -20, 0)
local bankTxt = bankBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
bankTxt:SetPoint("CENTER", bankBtn, "CENTER", 0, 0)
bankTxt:SetText("Bank")
bankBtn:SetScript("OnClick", function()
    V.showBank = not V.showBank
    V:Render()
end)
bankBtn:SetScript("OnEnter", function()
    GameTooltip:SetOwner(this, "ANCHOR_TOP")
    GameTooltip:SetText("Bank", 1, 0.82, 0)
    local snap = V:BankSnapshot()
    if V.bankOpen then
        GameTooltip:AddLine("Live - you are at a banker.", 0.7, 0.9, 0.7)
    elseif snap then
        GameTooltip:AddLine("Last seen " .. date("%b %d %H:%M", snap.time or 0) .. ".", 0.8, 0.8, 0.8)
    else
        GameTooltip:AddLine("Visit a banker once to remember your bank here.", 0.8, 0.8, 0.8)
    end
    GameTooltip:Show()
end)
bankBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- search box
local search = CreateFrame("EditBox", "Vault_Search", frame)
search:SetHeight(18)
search:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -29)
search:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD, -29)
search:SetBackdrop(UI.THIN)
search:SetBackdropColor(0.03, 0.03, 0.04, 0.95)
search:SetBackdropBorderColor(0.42, 0.42, 0.46, 1)
search:SetFontObject(GameFontHighlightSmall)
search:SetTextInsets(18, 6, 0, 0)
search:SetAutoFocus(false)
search:SetMaxLetters(40)
local glass = search:CreateTexture(nil, "OVERLAY")
glass:SetTexture("Interface\\Icons\\INV_Misc_Spyglass_02")
glass:SetTexCoord(0.1, 0.9, 0.1, 0.9)
glass:SetWidth(11)
glass:SetHeight(11)
glass:SetPoint("LEFT", search, "LEFT", 5, 0)
glass:SetAlpha(0.7)
local hint = search:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
hint:SetPoint("LEFT", search, "LEFT", 19, 0)
hint:SetText("Search")
search:SetScript("OnEscapePressed", function() this:ClearFocus() end)
search:SetScript("OnEnterPressed", function() this:ClearFocus() end)
search:SetScript("OnTextChanged", function()
    local t = this:GetText() or ""
    if t == "" then hint:Show() else hint:Hide() end
    V.filter = strlower(t)
    V:ApplyFilter()
end)

local bankLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")

-- one label and one left border per lane
local laneParts = {}
local function lanePart(key)
    local p = laneParts[key]
    if p then return p end
    local c = V.LANES[key].color
    p = {}
    p.label = frame:CreateFontString("Vault_Lane_" .. key, "OVERLAY", "GameFontNormalSmall")
    p.label:SetTextColor(c[1], c[2], c[3])
    p.bar = frame:CreateTexture(nil, "ARTWORK")
    p.bar:SetTexture(c[1], c[2], c[3], 0.9)
    p.bar:SetWidth(3)
    laneParts[key] = p
    return p
end
V.laneParts = laneParts

local free = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
free:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD - 1, -52)
local money = UI.Money(frame)
money:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD - 2, 8)

local footRule = frame:CreateTexture(nil, "ARTWORK")
footRule:SetTexture(0.30, 0.30, 0.34, 1)
footRule:SetHeight(1)
footRule:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 6, 25)
footRule:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -6, 25)

-- -- Slots ---------------------------------------------------------------------

local function slotEnter()
    local b = this
    GameTooltip:SetOwner(b, "ANCHOR_LEFT")
    if b.bag == -1 and BankButtonIDToInvSlotID then
        GameTooltip:SetInventoryItem("player", BankButtonIDToInvSlotID(b.slot))
    elseif b.bag then
        GameTooltip:SetBagItem(b.bag, b.slot)
    elseif b.itemString then
        GameTooltip:SetHyperlink(b.itemString)
    else
        GameTooltip:Hide()
        return
    end
    GameTooltip:Show()
end

local function slotClick()
    local b = this
    if not b.bag then return end
    -- other addons (Mail: Alt-click to attach) get the click first
    for _, fn in ipairs(V.clickHooks or {}) do
        if fn(b, arg1) then return end
    end
    if arg1 == "RightButton" then
        UseContainerItem(b.bag, b.slot)
    elseif IsShiftKeyDown() and b.link and ChatFrameEditBox and ChatFrameEditBox:IsVisible() then
        ChatFrameEditBox:Insert(b.link)
    else
        PickupContainerItem(b.bag, b.slot)
    end
end

-- A slot's well in the window skin: the stock quick-slot border (Classic), the Classic+ stone slot
-- (Brass, and Slick when the art is there, as before), or flat squares.
local function styleSlot(b, th)
    local bg, inner, edge = b.bg, b.inner, b.edge
    inner:Hide()
    if th.slotBorder then
        bg:SetTexture(0, 0, 0, 0.45)
        edge:SetTexture(th.slotBorder)
        edge:SetWidth(SLOT * 64 / 37)
        edge:SetHeight(SLOT * 64 / 37)
        edge:Show()
    else
        edge:Hide()
        if not W:Art(bg, "Slot", nil) then
            bg:SetTexture(0.10, 0.10, 0.11, 1)
            inner:Show()
        end
    end
end

local function newSlot(i)
    local b = CreateFrame("Button", "Vault_Slot" .. i, frame)
    b:SetWidth(SLOT)
    b:SetHeight(SLOT)
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetPoint("TOPLEFT", b, "TOPLEFT", -2, 2)
    bg:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 2, -2)
    b.bg = bg
    local inner = b:CreateTexture(nil, "BACKGROUND")
    inner:SetPoint("TOPLEFT", b, "TOPLEFT", 1, -1)
    inner:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -1, 1)
    inner:SetTexture(0.03, 0.03, 0.035, 1)
    b.inner = inner
    local edge = b:CreateTexture(nil, "OVERLAY")
    edge:SetPoint("CENTER", b, "CENTER", 0, -1)
    b.edge = edge
    UI.OnSkin(function(th) styleSlot(b, th) end)
    local sil = b:CreateTexture(nil, "BORDER")
    sil:SetTexture("Interface\\PaperDoll\\UI-Backpack-EmptySlot")
    sil:SetPoint("TOPLEFT", b, "TOPLEFT", 3, -3)
    sil:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -3, 3)
    sil:SetAlpha(0.28)
    b.silhouette = sil
    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", b, "TOPLEFT", 1, -1)
    icon:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -1, 1)
    icon:SetTexCoord(0.06, 0.94, 0.06, 0.94)
    b.icon = icon
    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    border:SetBlendMode("ADD")
    border:SetWidth(SLOT * 1.8)
    border:SetHeight(SLOT * 1.8)
    border:SetPoint("CENTER", b, "CENTER", 0, 0)
    border:Hide()
    b.border = border
    local count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    count:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -2, 2)
    b.count = count
    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    b:SetScript("OnClick", slotClick)
    b:SetScript("OnDragStart", function() if this.bag then PickupContainerItem(this.bag, this.slot) end end)
    b:SetScript("OnReceiveDrag", function() if this.bag then PickupContainerItem(this.bag, this.slot) end end)
    b:SetScript("OnEnter", slotEnter)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end

local function itemString(link)
    local _, _, s = strfind(link or "", "(item:[%-%d:]+)")
    return s
end

local function itemName(link)
    local _, _, n = strfind(link or "", "%[(.-)%]")
    return n and strlower(n) or ""
end

-- Fill slot b from a live container slot or a remembered item.
local function setSlot(b, bag, slot, item)
    b.bag, b.slot = bag, slot
    b.itemString = nil
    local texture, count, locked, quality, link
    if bag then
        texture, count, locked, quality = GetContainerItemInfo(bag, slot)
        link = GetContainerItemLink(bag, slot)
    elseif item then
        texture, count, quality = item.t, item.c, item.q
        b.itemString = item.s
    end
    b.link = link
    if bag then b.itemString = itemString(link) end
    b.name = link and itemName(link) or (item and item.n) or ""
    local showSil = W:Setting(ID, "showBagSilhouette", true)
    if texture then
        b.icon:SetTexture(texture)
        b.icon:Show()
        b.silhouette:Hide()
        if b.icon.SetDesaturated then b.icon:SetDesaturated(locked and 1 or nil) end
        b.count:SetText((count and count > 1) and count or "")
        local q = quality
        if (not q or q < 0) and link then
            local _, _, hex = strfind(link, "|cff(%x%x%x%x%x%x)")
            q = ({ ["9d9d9d"] = 0, ["ffffff"] = 1, ["1eff00"] = 2, ["0070dd"] = 3, ["a335ee"] = 4, ["ff8000"] = 5 })[hex or ""]
        end
        local c = q and q > 1 and QUALITY[q]
        if c then
            b.border:SetVertexColor(c[1], c[2], c[3], 0.85)
            b.border:Show()
        else
            b.border:Hide()
        end
    else
        b.icon:Hide()
        b.count:SetText("")
        b.border:Hide()
        if showSil then b.silhouette:Show() else b.silhouette:Hide() end
    end
    b:Show()
end

-- -- Bank memory ---------------------------------------------------------------

function V:BankSnapshot()
    local c = WenillaCore_Config
    return c and c.bank and c.bank[charKey()]
end

local function bankBags()
    local list = { -1 }
    for i = 5, 10 do table.insert(list, i) end
    return list
end

function V:SaveBank()
    if not WenillaCore_Config then return end
    local items = {}
    for _, bag in ipairs(bankBags()) do
        local n = GetContainerNumSlots(bag) or 0
        for slot = 1, n do
            local texture, count, _, quality = GetContainerItemInfo(bag, slot)
            local link = GetContainerItemLink(bag, slot)
            if texture then
                table.insert(items, { s = itemString(link), t = texture, c = count, q = quality, n = itemName(link) })
            else
                table.insert(items, false)
            end
        end
    end
    WenillaCore_Config.bank = WenillaCore_Config.bank or {}
    WenillaCore_Config.bank[charKey()] = { time = time and time() or 0, items = items }
end

-- -- Lanes ---------------------------------------------------------------------

local function lower(x) return strlower(x or "") end

-- "bags" | "reagent" | "ammo" | "soul" from a bag item's type, subtype and name.
function V.Family(itemType, subType, name)
    local t, st, n = lower(itemType), lower(subType), lower(name)
    if t == "quiver" or strfind(st, "quiver", 1, 1) or strfind(st, "ammo", 1, 1)
        or strfind(n, "quiver", 1, 1) or strfind(n, "ammo pouch", 1, 1) or strfind(n, "shot pouch", 1, 1)
        or strfind(n, "bandolier", 1, 1) then
        return "ammo"
    end
    if strfind(st, "soul", 1, 1) or strfind(n, "soul", 1, 1) or strfind(n, "felcloth bag", 1, 1) then return "soul" end
    if (st ~= "" and st ~= "bag" and t == "container") or strfind(st, "reagent", 1, 1) or strfind(st, "herb", 1, 1)
        or strfind(st, "enchant", 1, 1) or strfind(n, "reagent", 1, 1) or strfind(n, "herb", 1, 1) then
        return "reagent"
    end
    return "bags"
end

-- The family of bag 1-4 (the backpack is always "bags").
function V.BagFamily(bag)
    if not bag or bag <= 0 then return "bags" end
    local inv = ContainerIDToInventoryID and ContainerIDToInventoryID(bag) or (bag + 19)
    local link = GetInventoryItemLink and GetInventoryItemLink("player", inv)
    local name, itemType, subType
    if link then
        local _, _, s = strfind(link, "(item:[%-%d:]+)")
        local _, _, n = strfind(link, "%[(.-)%]")
        name = n
        if s then
            local nn, _, _, _, t, st = GetItemInfo(s)
            name, itemType, subType = nn or name, t, st
        end
    end
    if not name and GetBagName then name = GetBagName(bag) end
    return V.Family(itemType, subType, name)
end

-- Openable items: Star Pouches by id; others by their tooltip (<Right Click to Open>, or Locked for a
-- lockbox). Answers are remembered per item.
V.openCache = {}
local scanTip
local function tipSays(bag, slot)
    if not scanTip then
        scanTip = CreateFrame("GameTooltip", "Vault_ScanTip", UIParent, "GameTooltipTemplate")
    end
    scanTip:SetOwner(UIParent, "ANCHOR_NONE")
    scanTip:ClearLines()
    scanTip:SetBagItem(bag, slot)
    local open = lower(ITEM_OPENABLE or "<Right Click to Open>")
    local locked = lower(LOCKED or "Locked")
    for i = 1, (scanTip:NumLines() or 0) do
        local fs = getglobal("Vault_ScanTipTextLeft" .. i)
        local t = lower(fs and fs:GetText())
        if t ~= "" and (strfind(t, open, 1, 1) or strfind(t, "right click to open", 1, 1) or t == locked) then
            scanTip:Hide()
            return true
        end
    end
    scanTip:Hide()
    return false
end

function V.IsOpenable(bag, slot, link)
    if not link then return false end
    local _, _, id = strfind(link, "item:(%d+)")
    id = tonumber(id)
    if id and id >= V.STAR_POUCH_MIN and id <= V.STAR_POUCH_MAX then return true end
    local _, _, key = strfind(link, "(item:[%-%d:]+)")
    key = key or link
    local known = V.openCache[key]
    if known == nil then
        known = tipSays(bag, slot)
        V.openCache[key] = known
    end
    return known
end

-- { bags = { {bag, slot}, ... }, open = ..., reagent = ..., ammo = ..., soul = ... }
function V:Lanes()
    local lanes = {}
    for _, k in ipairs(V.LANE_ORDER) do lanes[k] = {} end
    for bag = 0, 4 do
        local fam = V.BagFamily(bag)
        for slot = 1, (GetContainerNumSlots(bag) or 0) do
            local lane = fam
            if fam == "bags" and V.IsOpenable(bag, slot, GetContainerItemLink(bag, slot)) then lane = "open" end
            table.insert(lanes[lane], { bag, slot })
        end
    end
    return lanes
end

-- -- Layout --------------------------------------------------------------------

local function place(b, index, top)
    local col = mod(index - 1, COLS)
    local row = floor((index - 1) / COLS)
    b:ClearAllPoints()
    b:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + col * (SLOT + GAP), top - row * (SLOT + GAP))
end

function V:Render()
    self.dirty = false
    local n, freeSlots, total = 0, 0, 0
    local y = -52
    local lanes = self:Lanes()
    self.lanes = lanes
    for _, key in ipairs(V.LANE_ORDER) do
        local list = lanes[key]
        local part = lanePart(key)
        if key == "bags" or list[1] then
            local labelTop = y
            local used = 0
            for _, e in ipairs(list) do
                if GetContainerItemInfo(e[1], e[2]) then used = used + 1 end
            end
            part.label:ClearAllPoints()
            part.label:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + 1, y)
            part.label:SetText(V.LANES[key].label .. ((key ~= "bags" and key ~= "open") and ("  |cff9a9a9a" .. used .. "/" .. table.getn(list) .. "|r") or ""))
            part.label:Show()
            y = y - 14
            for i, e in ipairs(list) do
                n = n + 1
                local b = self.slots[n] or newSlot(n)
                self.slots[n] = b
                setSlot(b, e[1], e[2])
                place(b, i, y)
                total = total + 1
                if not GetContainerItemInfo(e[1], e[2]) then freeSlots = freeSlots + 1 end
            end
            local rows = floor((table.getn(list) + COLS - 1) / COLS)
            y = y - rows * (SLOT + GAP)
            part.bar:ClearAllPoints()
            part.bar:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD - 5, labelTop + 1)
            part.bar:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", PAD - 5, y + GAP - 1)
            part.bar:Show()
            y = y - 4
        else
            part.label:Hide()
            part.bar:Hide()
        end
    end

    local showBank = self.bankOpen or self.showBank
    local bankStart = n
    if showBank then
        bankLabel:ClearAllPoints()
        bankLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + 1, y - 4)
        local snap = (not self.bankOpen) and self:BankSnapshot()
        bankLabel:SetText(self.bankOpen and "Bank" or (snap and ("Bank  |cff808080last seen " .. date("%b %d", snap.time or 0) .. "|r") or "Bank  |cff808080not seen yet|r"))
        bankLabel:Show()
        y = y - 18
        local i = 0
        if self.bankOpen then
            for _, bag in ipairs(bankBags()) do
                for slot = 1, (GetContainerNumSlots(bag) or 0) do
                    i = i + 1
                    n = n + 1
                    local b = self.slots[n] or newSlot(n)
                    self.slots[n] = b
                    setSlot(b, bag, slot)
                    place(b, i, y)
                end
            end
        elseif snap then
            for _, item in ipairs(snap.items) do
                i = i + 1
                n = n + 1
                local b = self.slots[n] or newSlot(n)
                self.slots[n] = b
                setSlot(b, nil, nil, item or nil)
                place(b, i, y)
            end
        end
        y = y - floor((i + COLS - 1) / COLS) * (SLOT + GAP)
    else
        bankLabel:Hide()
    end
    for k = n + 1, table.getn(self.slots) do self.slots[k]:Hide() end
    self.used = n
    self.bankStart = bankStart

    free:SetText((total - freeSlots) .. "/" .. total .. " used")
    if W:Setting(ID, "showCurrency", true) then
        money:SetMoney(GetMoney())
        money:Show()
    else
        money:Hide()
    end
    if W:Setting(ID, "searchFilter", true) then search:Show() else search:Hide() end
    frame:SetHeight(-y + 32)
    self:ApplyFilter()
end

function V:ApplyFilter()
    local f = self.filter
    local on = W:Setting(ID, "searchFilter", true) and f and f ~= ""
    for i = 1, (self.used or 0) do
        local b = self.slots[i]
        if on and b.icon:IsShown() then
            local hit = strfind(b.name or "", f, 1, 1)
            b:SetAlpha(hit and 1 or 0.22)
        else
            b:SetAlpha(1)
        end
    end
end

-- -- Opening & closing ---------------------------------------------------------

local orig = {}

local function replacing()
    return W:IsActive(ID) and W:Setting(ID, "replaceBags", true)
end

function V:Open()
    if not W:IsActive(ID) then return end
    if orig.CloseAllBags then orig.CloseAllBags() end
    frame:Show()
    self:Render()
end

function V:Close()
    frame:Hide()
end

function V:Toggle()
    if frame:IsShown() then self:Close() else self:Open() end
end

local function hook(name, fn)
    if type(getglobal(name)) ~= "function" or orig[name] then return end
    orig[name] = getglobal(name)
    setglobal(name, fn)
end

hook("OpenAllBags", function(force)
    if not replacing() then return orig.OpenAllBags(force) end
    if force then V:Open() else V:Toggle() end
end)
hook("ToggleBackpack", function()
    if not replacing() then return orig.ToggleBackpack() end
    V:Toggle()
end)
hook("OpenBackpack", function()
    if not replacing() then return orig.OpenBackpack() end
    V:Open()
end)
hook("ToggleBag", function(id)
    if not replacing() or (id and id > 4) then return orig.ToggleBag(id) end
    V:Toggle()
end)
hook("CloseAllBags", function()
    if frame:IsShown() then V:Close() end
    if orig.CloseAllBags then return orig.CloseAllBags() end
end)
hook("CloseBackpack", function()
    if frame:IsShown() and replacing() then V:Close() end
    if orig.CloseBackpack then return orig.CloseBackpack() end
end)

-- -- Events --------------------------------------------------------------------

local ev = CreateFrame("Frame", "Vault_Events")
for _, e in ipairs({ "BAG_UPDATE", "ITEM_LOCK_CHANGED", "PLAYER_MONEY", "BANKFRAME_OPENED",
    "BANKFRAME_CLOSED", "PLAYERBANKSLOTS_CHANGED", "PLAYER_ENTERING_WORLD" }) do
    ev:RegisterEvent(e)
end
ev:SetScript("OnEvent", function()
    if event == "BANKFRAME_OPENED" then
        V.bankOpen = true
        V:SaveBank()
        if replacing() then V:Open() end
    elseif event == "BANKFRAME_CLOSED" then
        if V.bankOpen then V:SaveBank() end
        V.bankOpen = false
    elseif event == "PLAYERBANKSLOTS_CHANGED" or (event == "BAG_UPDATE" and V.bankOpen) then
        if V.bankOpen then V:SaveBank() end
    end
    V.dirty = true
end)
ev:SetScript("OnUpdate", function()
    if V.dirty and frame:IsShown() then V:Render() end
end)

-- -- Server bank snapshot (VT) -------------------------------------------------

W:RegisterModule("VT", function(body)
    if not WenillaCore_Config then return end
    local items = {}
    local recs, n = W.Split(body, ";")
    for i = 1, n do
        local f = W.Split(recs[i], ",")
        local id = tonumber(f[1])
        if id and id > 0 then
            table.insert(items, {
                s = "item:" .. id .. ":0:0:0", c = tonumber(f[2]) or 1, q = tonumber(f[3]) or 1,
                n = strlower(GetItemInfo(id) or ""),   -- for search; empty until the item cache knows it
                t = f[4] and f[4] ~= "" and ("Interface\\Icons\\" .. f[4]) or UI.UNKNOWN_ICON,
            })
        else
            table.insert(items, false)
        end
    end
    WenillaCore_Config.bank = WenillaCore_Config.bank or {}
    WenillaCore_Config.bank[charKey()] = { time = time and time() or 0, items = items }
    V.dirty = true
end)

W:RegisterAddon(ID, function(active)
    if not active then frame:Hide() end
    V.dirty = true
end)

SLASH_BAGS1 = "/bags"
SLASH_BAGS2 = "/vault"
SlashCmdList["BAGS"] = function(msg)
    if string.lower(W.Trim(msg)) == "bank" then V.showBank = true end
    V:Toggle()
end
