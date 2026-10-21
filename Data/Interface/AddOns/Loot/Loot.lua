--[[
    Loot.lua
    Our own loot window, built on the stock loot API (GetNumLootItems, GetLootSlotInfo,
    LootSlotIsCoin, LootSlot, CloseLoot). One row per item: icon, name in its quality colour,
    the stack count, and a small "x3" when the realm says it came from several corpses. The money
    from every corpse is added up on one line at the top. Take All and Close at the bottom; click
    a row to loot it, Shift-click to link it, Ctrl-click to try it on.

    How a slot is taken: in 1.12 (and in wenilla, which follows it) LootSlot(slot) does NOT take
    anything; it only answers a LOOT_BIND_CONFIRM for the row being asked about. The take is the
    hardware click of a LootButton whose slot was set with LootButton:SetSlot(slot), done by the
    client itself after OnClick (unless Shift, Ctrl or Alt is held), and a scripted :Click() on a
    LootButton does nothing. So every row, the money line and Take All are LootButtons kept slotted
    to what they show, and their OnClick never calls LootSlot (that would also confirm a
    bind-on-pickup item behind the LOOT_BIND popup's back). Take All takes one slot per click (the
    money first) and is then slotted to the next one: no Lua can take more than one per click.

    Area loot: the realm can merge the loot of nearby corpses into one window and say so with
        AL <corpses>,<copper>;<slot>,<sources>;...
    Without it (an older realm) this is simply a nicer single-corpse loot window.

    Auto loot (on by default in Open Vanilla: autoLootDefault, where Shift-looting opens the window;
    with it off, Shift-looting is auto loot): everything is taken without showing the window, and
    one chat line sums it up instead of a line per item. Anything that would not
    fit in your bags stays, and the window then opens with what is left.

    The stock LootFrame is kept quiet while this is active; the "standard loot window" setting
    gives it back. Master looters get the stock window, which has the master-loot menu.
]]--

local W = WenillaCore
local UI = W.UI
local ID = "Loot"

ClassicPlusLoot = ClassicPlusLoot or {}
local L = ClassicPlusLoot

local floor, strfind, strlower = math.floor, string.find, string.lower
local getn = table.getn

local MAX_ROWS = 10
local QUALITY_HEX = { [0] = "ff9d9d9d", [1] = "ffffffff", [2] = "ff1eff00", [3] = "ff0070dd", [4] = "ffa335ee", [5] = "ffff8000" }
local COIN_ICON = "Interface\\Icons\\INV_Misc_Coin_01"
local STOCK_EVENTS = { "LOOT_OPENED", "LOOT_SLOT_CLEARED", "LOOT_CLOSED" }
local LOOT_PANEL = "Interface\\LootFrame\\UI-LootPanel"
local NAME_FRAME = "Interface\\QuestFrame\\UI-QuestItemNameFrame"
local PENDING_NAME = RETRIEVING_ITEM_INFO or "Retrieving item information"

-- Geometry per window skin (WenillaCore UI.SKINS). Classic is the stock 1.12 LootFrame: the left
-- 188 px of its 256 px panel art with the portrait circle, quick-slot item buttons on quest-item
-- name frames, and the red panel buttons.
local LAYOUT = {
    classic = { width = 188, left = 22, rowW = 154, rowH = 34, gap = 4, icon = 30, top = -74, bottom = 42, minH = 190 },
    brass = { width = 230, left = 10, rowW = 210, rowH = 30, gap = 3, icon = 26, top = -34, bottom = 38, minH = 90 },
    slick = { width = 230, left = 8, rowW = 214, rowH = 26, gap = 2, icon = 24, top = -28, bottom = 36, minH = 60 },
}
local lay = LAYOUT.slick

L.slots = {}          -- slot -> { coin, copper, icon, name, count, quality, link, taken }
L.al = nil            -- { corpses, copper, sources = { [slot] = n }, t }

local function active() return W:IsActive(ID) end
local function useOurs() return active() and not W:Setting(ID, "keepBlizzard", false) end

-- "12 Silver\n4 Copper" (the coin slot's name) -> copper
function L.ParseCoins(text)
    if not text then return 0 end
    local total = 0
    local _, _, g = strfind(text, "(%d+) [Gg]old")
    local _, _, s = strfind(text, "(%d+) [Ss]ilver")
    local _, _, c = strfind(text, "(%d+) [Cc]opper")
    total = (tonumber(g) or 0) * 10000 + (tonumber(s) or 0) * 100 + (tonumber(c) or 0)
    return total
end

-- "1g 2s 3c" with only the parts that are not zero.
local function coins(copper)
    copper = floor(tonumber(copper) or 0)
    local g = floor(copper / 10000)
    local s = floor((copper - g * 10000) / 100)
    local c = copper - g * 10000 - s * 100
    local out = {}
    if g > 0 then table.insert(out, g .. "|cffffd700g|r") end
    if s > 0 then table.insert(out, s .. "|cffc7c7cfs|r") end
    if c > 0 or not out[1] then table.insert(out, c .. "|cffeda55fc|r") end
    return table.concat(out, " ")
end
L.Coins = coins

-- -- Window -----------------------------------------------------------------------------------

local frame = UI.Window("Loot_Frame", {
    width = lay.width, height = 120, title = "Loot", icon = "Interface\\Icons\\INV_Misc_Bag_09",
    titleAlign = "LEFT", strata = "HIGH", point = { "TOPLEFT", UIParent, "TOPLEFT", 120, -160 },
    onClose = function() L:CloseWindow() end,
})
frame:Hide()
table.insert(UISpecialFrames, "Loot_Frame")
L.frame = frame

-- The stock LootFrame art (Classic skin): panel top, a stretchable middle, the bottom, the portrait.
local chrome = {}
local function panelPiece(y0, y1, h)
    local t = frame:CreateTexture(nil, "BORDER")
    t:SetTexture(LOOT_PANEL)
    t:SetTexCoord(0, 188 / 256, y0 / 256, y1 / 256)
    t:SetWidth(188)
    if h then t:SetHeight(h) end
    return t
end
chrome.top = panelPiece(0, 96, 96)
chrome.top:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
chrome.bottom = panelPiece(176, 256, 80)
chrome.bottom:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
chrome.mid = panelPiece(96, 176)
chrome.mid:SetPoint("TOPLEFT", chrome.top, "BOTTOMLEFT", 0, 0)
chrome.mid:SetPoint("BOTTOMLEFT", chrome.bottom, "TOPLEFT", 0, 0)
chrome.portrait = frame:CreateTexture("Loot_Portrait", "BACKGROUND")
chrome.portrait:SetWidth(58)
chrome.portrait:SetHeight(58)
chrome.portrait:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -8)
chrome.portrait:SetTexture("Interface\\TargetingFrame\\TargetDead")
L.chrome = chrome

local corpsesText = UI.Label(frame, 10, UI.MUTED)
corpsesText:SetJustifyH("RIGHT")

-- the money line: a coin "item" with every corpse's money added up
local moneyRow = CreateFrame("LootButton", "Loot_Money", frame)
moneyRow:RegisterForClicks("LeftButtonUp", "RightButtonUp")
moneyRow:SetHeight(22)
local moneyBox = UI.IconBox(moneyRow, 16)
moneyBox.icon:SetTexture(COIN_ICON)
local moneyName = moneyRow:CreateTexture(nil, "BACKGROUND")
moneyName:SetTexture(NAME_FRAME)
local moneyText = UI.Label(moneyRow, 11, { 1, 1, 1 }, "OUTLINE")
local moneyFrom = UI.Label(moneyRow, 10, UI.MUTED)
local moneyHl = moneyRow:CreateTexture(nil, "HIGHLIGHT")
moneyHl:SetAllPoints(moneyRow)
moneyHl:SetTexture(1, 0.82, 0, 0.08)
local moneyHlIcon = moneyRow:CreateTexture(nil, "HIGHLIGHT")
moneyHlIcon:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
moneyHlIcon:SetBlendMode("ADD")
moneyHlIcon:SetAllPoints(moneyBox)
-- the client takes the slot set on it (L:Render); nothing to do here
moneyRow:SetScript("OnClick", function() end)
moneyRow:SetScript("OnEnter", function()
    GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
    GameTooltip:SetText("Money", 1, 0.82, 0)
    local al = L.al
    if al and al.corpses > 1 then
        GameTooltip:AddLine("Added up from " .. al.corpses .. " corpses.", 0.85, 0.85, 0.85)
    end
    GameTooltip:AddLine("Click to take it.", 0.4, 0.9, 0.4)
    GameTooltip:Show()
end)
moneyRow:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- item rows
L.rows = {}
L.offset = 0

-- The take itself is the client's (the row is a LootButton slotted in L:Render): OnClick only does
-- the stock modified clicks, which the client answers by not taking.
local function rowClick()
    local slot = this.slot
    if not slot then return end
    local s = L.slots[slot]
    local link = (s and s.link) or (GetLootSlotLink and GetLootSlotLink(slot))
    if IsControlKeyDown() then
        if link and DressUpItemLink then DressUpItemLink(link) end
    elseif IsShiftKeyDown() and link then
        if ChatFrameEditBox and ChatFrameEditBox:IsVisible() then
            ChatFrameEditBox:Insert(link)
        elseif ChatFrame_OpenChat then
            ChatFrame_OpenChat(link)
        end
    end
end

-- Fit a row (or the money row) to the skin.
local function styleRow(r, th)
    local stock = (th.key == "classic")
    r:SetWidth(lay.rowW)
    r:SetHeight(lay.rowH - lay.gap)
    r.icon:SetWidth(lay.icon)
    r.icon:SetHeight(lay.icon)
    r.icon:ClearAllPoints()
    r.icon:SetPoint("LEFT", r, "LEFT", 0, 0)
    UI.PaintIcon(r.icon, th)
    if r.bg then
        if stock then r.bg:Hide() else
            r.bg:Show()
            local c = th.flat and UI.INSET or th.insetBg
            r.bg:SetTexture(c[1], c[2], c[3], th.flat and 0.55 or 0.6)
        end
    end
    if stock then r.hl:Hide() r.hlIcon:Show() else r.hl:Show() r.hlIcon:Hide() end
    r.nameFrame:ClearAllPoints()
    r.nameFrame:SetPoint("LEFT", r.icon, "RIGHT", -6, 0)
    r.nameFrame:SetWidth(lay.rowW - lay.icon + 6)
    r.nameFrame:SetHeight(lay.icon * 62 / 37)
    if stock then r.nameFrame:Show() else r.nameFrame:Hide() end
    UI.Font(r.name, 11, stock and "" or "OUTLINE")
    r.name:ClearAllPoints()
    r.name:SetPoint("LEFT", r.icon, "RIGHT", stock and 8 or 7, 0)
end

local function newRow(i)
    local r = CreateFrame("LootButton", "Loot_Row" .. i, frame)
    r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    r.bg = r:CreateTexture(nil, "BACKGROUND")
    r.bg:SetAllPoints(r)
    r.icon = UI.IconBox(r, lay.icon)
    r.count = r.icon:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    r.count:SetPoint("BOTTOMRIGHT", r.icon, "BOTTOMRIGHT", -1, 1)
    r.nameFrame = r:CreateTexture(nil, "BORDER")
    r.nameFrame:SetTexture(NAME_FRAME)
    r.name = UI.Label(r, 11, nil, "OUTLINE")
    -- on the icon box, so it draws above the icon in the Classic skin
    r.sources = UI.Label(r.icon, 10, UI.MUTED)
    r.hl = r:CreateTexture(nil, "HIGHLIGHT")
    r.hl:SetAllPoints(r)
    r.hl:SetTexture(1, 0.82, 0, 0.10)
    r.hlIcon = r:CreateTexture(nil, "HIGHLIGHT")
    r.hlIcon:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
    r.hlIcon:SetBlendMode("ADD")
    r.hlIcon:SetAllPoints(r.icon)
    r:SetScript("OnClick", rowClick)
    r:SetScript("OnEnter", function()
        if not this.slot then return end
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:SetLootItem(this.slot)
        local n = L.al and L.al.sources[this.slot]
        if n and n > 1 then GameTooltip:AddLine("From " .. n .. " corpses.", 0.62, 0.64, 0.70) end
        GameTooltip:Show()
        if CursorUpdate then CursorUpdate() end
    end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() if ResetCursor then ResetCursor() end end)
    L.rows[i] = r
    L:StyleRow(r, UI.Theme())
    return r
end

function L:StyleRow(r, th)
    styleRow(r, th)
    local stock = (th.key == "classic")
    r.name:SetWidth(lay.rowW - lay.icon - (stock and 22 or 40))
    r.name:SetHeight(lay.icon)
    r.sources:ClearAllPoints()
    if stock then
        r.sources:SetPoint("TOPLEFT", r.icon, "TOPLEFT", 2, -2)
        r.sources:SetJustifyH("LEFT")
        r.sources:SetTextColor(0.55, 0.85, 1)
    else
        r.sources:SetPoint("RIGHT", r, "RIGHT", -6, 0)
        r.sources:SetJustifyH("RIGHT")
        r.sources:SetTextColor(UI.MUTED[1], UI.MUTED[2], UI.MUTED[3])
    end
end

frame:EnableMouseWheel(true)
frame:SetScript("OnMouseWheel", function()
    L.offset = L.offset - (arg1 or 0) * 2
    L:Render()
end)

-- Take All: a LootButton in the stock red button look, always slotted to the next slot to take.
local takeAll
do
    local ok, b = pcall(CreateFrame, "LootButton", "Loot_TakeAll", frame, "UIPanelButtonTemplate")
    if not ok or not b then
        b = CreateFrame("LootButton", "Loot_TakeAll", frame)
        b:SetBackdrop(UI.THIN)
        b:SetBackdropColor(0.35, 0.05, 0.03, 0.95)
        b:SetBackdropBorderColor(0.75, 0.6, 0.3, 1)
        local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("CENTER", b, "CENTER", 0, 0)
        b.label = fs
        b.SetText = function(self, t) self.label:SetText(t) end
    end
    b:SetWidth(100)
    b:SetHeight(20)
    b:SetText("Take All")
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetScript("OnClick", function()
        -- the client takes this.slot after this handler; move on so the next click takes the next
        -- one even before LOOT_SLOT_CLEARED (and past a slot that would not fit in the bags)
        if IsShiftKeyDown() or IsControlKeyDown() or IsAltKeyDown() then return end
        if this.slot then L.asked[this.slot] = GetTime() end
        L:SlotTakeAll(this.slot)
    end)
    takeAll = b
end
L.takeAll = takeAll
L.asked = {}
local closeBtn = UI.Button(frame, "Close", 100, 20, function() L:CloseWindow() end)
local more = UI.Label(frame, 9, UI.MUTED)
more:SetJustifyH("CENTER")

-- The money row is a coin "item" like the others; in the Slick skin it is the old inset strip.
local function styleMoney(th)
    local stock = (th.key == "classic")
    local slick = th.flat and true or false
    moneyRow.icon, moneyRow.nameFrame, moneyRow.name = moneyBox, moneyName, moneyText
    moneyRow.hl, moneyRow.hlIcon = moneyHl, moneyHlIcon
    if slick then
        moneyRow:SetWidth(lay.rowW)
        moneyRow:SetHeight(22)
        UI.Skin(moneyRow, "inset")
        moneyBox:SetWidth(16)
        moneyBox:SetHeight(16)
        moneyBox:ClearAllPoints()
        moneyBox:SetPoint("LEFT", moneyRow, "LEFT", 4, 0)
        UI.PaintIcon(moneyBox, th)
        moneyName:Hide()
        moneyHl:Show()
        moneyHlIcon:Hide()
        UI.Font(moneyText, 11, "OUTLINE")
        moneyText:ClearAllPoints()
        moneyText:SetPoint("LEFT", moneyBox, "RIGHT", 6, 0)
        moneyFrom:ClearAllPoints()
        moneyFrom:SetPoint("RIGHT", moneyRow, "RIGHT", -6, 0)
        moneyFrom:SetJustifyH("RIGHT")
    else
        styleRow(moneyRow, th)
        moneyRow:SetBackdrop(nil)
        if not stock then
            moneyRow:SetBackdrop(th.inset)
            moneyRow:SetBackdropColor(th.insetBg[1], th.insetBg[2], th.insetBg[3], th.insetBg[4])
            moneyRow:SetBackdropBorderColor(th.insetBorder[1], th.insetBorder[2], th.insetBorder[3], th.insetBorder[4])
        end
        moneyText:ClearAllPoints()
        moneyText:SetPoint("TOPLEFT", moneyBox, "TOPRIGHT", stock and 8 or 7, -3)
        moneyFrom:ClearAllPoints()
        moneyFrom:SetPoint("TOPLEFT", moneyText, "BOTTOMLEFT", 0, -2)
        moneyFrom:SetJustifyH("LEFT")
    end
end

function L:PaintSkin(th)
    lay = LAYOUT[th.key] or LAYOUT.slick
    self.skin = th.key
    local stock = (th.key == "classic")
    frame:SetWidth(lay.width)
    for _, t in pairs(chrome) do if stock then t:Show() else t:Hide() end end
    local title, cb, h = frame.title, frame.closeButton, frame.dragHandle
    if stock then
        frame:SetBackdrop(nil)
        frame.titleBar:SetTexture(nil)
        frame.titleRule:Hide()
        if frame.header then frame.header:Hide() end
        for _, c in ipairs(frame.corners or {}) do c:Hide() end
        if frame.icon then frame.icon:Hide() end
        title:SetText(ITEMS or "Items")
        UI.Font(title, 12, "")
        title:ClearAllPoints()
        title:SetPoint("CENTER", frame, "TOPLEFT", 116, -26)
        title:SetTextColor(1, 0.82, 0)
        cb:ClearAllPoints()
        cb:SetWidth(32)
        cb:SetHeight(32)
        cb:SetPoint("CENTER", frame, "TOPLEFT", 175, -26)
        h:ClearAllPoints()
        h:SetPoint("TOPLEFT", frame, "TOPLEFT", 72, -14)
        h:SetPoint("BOTTOMRIGHT", frame, "TOPLEFT", 158, -38)
        corpsesText:ClearAllPoints()
        corpsesText:SetPoint("TOPLEFT", frame, "TOPLEFT", 74, -46)
        corpsesText:SetWidth(100)
        corpsesText:SetJustifyH("LEFT")
        takeAll:ClearAllPoints()
        takeAll:SetWidth(74)
        takeAll:SetHeight(22)
        takeAll:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 22, 13)
        closeBtn:ClearAllPoints()
        closeBtn:SetWidth(74)
        closeBtn:SetHeight(22)
        closeBtn:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 101, 13)
    else
        title:SetText("Loot")
        UI.Font(title, 11, "OUTLINE")
        UI.PaintWindow(frame, th)
        h:ClearAllPoints()
        h:SetPoint("TOPLEFT", frame.titleBar, "TOPLEFT", 0, 0)
        h:SetPoint("BOTTOMRIGHT", frame.titleBar, "BOTTOMRIGHT", -20, 0)
        corpsesText:ClearAllPoints()
        corpsesText:SetPoint("RIGHT", frame.titleBar, "RIGHT", th.flat and -22 or -26, th.flat and 0 or -2)
        corpsesText:SetJustifyH("RIGHT")
        takeAll:ClearAllPoints()
        takeAll:SetWidth(100)
        takeAll:SetHeight(20)
        takeAll:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", lay.left, 8)
        closeBtn:ClearAllPoints()
        closeBtn:SetWidth(100)
        closeBtn:SetHeight(20)
        closeBtn:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -lay.left, 8)
    end
    more:ClearAllPoints()
    more:SetPoint("BOTTOM", frame, "BOTTOMLEFT", lay.left + lay.rowW / 2, lay.bottom - 8)
    more:SetWidth(lay.rowW)
    styleMoney(th)
    for _, r in ipairs(self.rows) do self:StyleRow(r, th) end
    self:Render()
end

-- -- Reading the loot ---------------------------------------------------------------------------

-- Every slot that still holds loot. A slot is read even when GetLootSlotInfo has no texture or
-- name yet: the client fills those in only once the item's data has arrived from the server, so the
-- first loot of an item this client has never seen comes in blank. Such a slot is kept as
-- "pending" and read again on every Render until its data is there.
function L:ReadSlot(slot)
    local icon, name, count, quality = GetLootSlotInfo(slot)
    local coin = LootSlotIsCoin and LootSlotIsCoin(slot)
    local item = LootSlotIsItem and LootSlotIsItem(slot)
    local s = self.slots[slot]
    if not (icon or name or coin or item) then return s end   -- an empty slot (or one already looted)
    if not s then
        s = { slot = slot }
        self.slots[slot] = s
    end
    s.icon, s.name = icon or s.icon, name or s.name
    s.count, s.quality = count or s.count or 1, quality or s.quality
    s.pending = not (icon and name) or nil
    if coin then
        s.coin = true
        s.copper = L.ParseCoins(name)
    else
        s.link = (GetLootSlotLink and GetLootSlotLink(slot)) or s.link
    end
    return s
end

function L:Read()
    self.slots = {}
    for slot = 1, (GetNumLootItems() or 0) do self:ReadSlot(slot) end
end

-- Items still on the corpse(s), in slot order.
function L:Items()
    local out = {}
    for slot = 1, (GetNumLootItems() or 0) do
        local s = self.slots[slot]
        if s and not s.coin and not s.taken then table.insert(out, slot) end
    end
    return out
end

function L:Money()
    local copper, any = 0, false
    for _, s in pairs(self.slots) do
        if s.coin and not s.taken then copper = copper + (s.copper or 0); any = true end
    end
    if any and self.al and self.al.copper > 0 then copper = self.al.copper end
    return any and copper or 0, any
end

function L:Render()
    if not frame:IsShown() then return end
    -- slots whose item data had not arrived yet
    self.pending = nil
    for slot, s in pairs(self.slots) do
        if s.pending and not s.taken then
            self:ReadSlot(slot)
            if s.pending then self.pending = true end
        end
    end
    local items = self:Items()
    local copper, hasMoney = self:Money()
    local al = self.al
    if al and al.corpses > 1 then corpsesText:SetText(al.corpses .. " corpses") else corpsesText:SetText("") end

    local y = lay.top
    if hasMoney then
        moneyText:SetText(coins(copper))
        moneyFrom:SetText((al and al.corpses > 1) and ("from " .. al.corpses .. " corpses") or "")
        local coinSlot = self:CoinSlot()
        moneyRow.slot = coinSlot
        moneyRow:SetSlot(coinSlot or 0)
        moneyRow:ClearAllPoints()
        moneyRow:SetPoint("TOPLEFT", frame, "TOPLEFT", lay.left, y)
        moneyRow:Show()
        y = y - ((self.skin == "slick") and 26 or lay.rowH)
    else
        moneyRow.slot = nil
        moneyRow:SetSlot(0)
        moneyRow:Hide()
    end

    local n = getn(items)
    local maxOff = math.max(0, n - MAX_ROWS)
    if self.offset > maxOff then self.offset = maxOff end
    if self.offset < 0 then self.offset = 0 end
    local shown = math.min(n, MAX_ROWS)
    for i = 1, shown do
        local slot = items[self.offset + i]
        local s = self.slots[slot]
        local r = self.rows[i] or newRow(i)
        r.slot = slot
        r:SetSlot(slot)
        r.icon.icon:SetTexture(s.icon or UI.UNKNOWN_ICON)
        r.count:SetText((s.count or 1) > 1 and tostring(s.count) or "")
        r.name:SetText("|c" .. (QUALITY_HEX[s.quality or 1] or "ffffffff") .. (s.name or PENDING_NAME) .. "|r")
        local src = al and al.sources[slot]
        r.sources:SetText((src and src > 1) and ("x" .. src) or "")
        local q = s.quality or 1
        local hex = QUALITY_HEX[q] or "ffffffff"
        local rr, gg, bb = tonumber(string.sub(hex, 3, 4), 16) / 255, tonumber(string.sub(hex, 5, 6), 16) / 255, tonumber(string.sub(hex, 7, 8), 16) / 255
        if q >= 2 then r.icon.edge:SetTexture(rr, gg, bb, 1) else r.icon.edge:SetTexture(0.35, 0.35, 0.38, 1) end
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", frame, "TOPLEFT", lay.left, y - (i - 1) * lay.rowH)
        r:Show()
    end
    for i = shown + 1, getn(self.rows) do self.rows[i].slot = nil; self.rows[i]:SetSlot(0); self.rows[i]:Hide() end
    self:SlotTakeAll()
    y = y - shown * lay.rowH
    if n > MAX_ROWS then
        more:SetText((self.offset + 1) .. "-" .. (self.offset + shown) .. " of " .. n .. "  (scroll for more)")
        more:Show()
        y = y - 14
    else
        more:Hide()
    end
    if n == 0 and not hasMoney then
        more:SetText("Nothing left.")
        more:Show()
        y = y - 14
    end
    frame:SetHeight(math.max(lay.minH, -y + lay.bottom))
end

-- -- Auto loot recap: what you got, shown for a moment, then faded ----------------------------------

local RECAP_HOLD, RECAP_FADE, RECAP_ROWS = 2.5, 1.0, 8   -- like the modern client: a few seconds, then a fade
local RECAP_OFFSET_X = W:Tune("Loot.recap.offsetX", 110)   -- from the cursor: right ...
local RECAP_OFFSET_Y = W:Tune("Loot.recap.offsetY", 70)    -- ... and up
local RECAP_CLEAR_W = W:Tune("Loot.recap.clearWidth", 300) -- the screen's middle, where your character stands, stays clear
RECAP_HOLD = W:Tune("Loot.recap.holdSeconds", RECAP_HOLD)
local recap = UI.Window("Loot_Recap", {
    width = 210, height = 60, title = "Looted", icon = "Interface\\Icons\\INV_Misc_Bag_09",
    titleAlign = "LEFT", strata = "HIGH", close = false, skin = true,
})
recap:EnableMouse(false)                -- a picture of what you got: clicks go through it
recap:Hide()
L.recap = recap
recap.rows = {}
for i = 1, RECAP_ROWS + 1 do
    local r = CreateFrame("Frame", nil, recap)
    r:SetHeight(20)
    r:SetPoint("TOPLEFT", recap, "TOPLEFT", 10, -30 - (i - 1) * 22)
    r:SetPoint("RIGHT", recap, "RIGHT", -10, 0)
    r.box = UI.IconBox(r, 18)
    r.box:SetPoint("LEFT", r, "LEFT", 0, 0)
    r.text = UI.Label(r, 11, { 1, 1, 1 })
    r.text:SetPoint("LEFT", r.box, "RIGHT", 6, 0)
    r.text:SetPoint("RIGHT", r, "RIGHT", 0, 0)
    r.text:SetJustifyH("LEFT")
    if r.text.SetShadowOffset then r.text:SetShadowColor(0, 0, 0, 1); r.text:SetShadowOffset(1, -1) end
    r:Hide()
    recap.rows[i] = r
end

-- a = the finished auto loot: { taken = { slot info }, copper, corpses }
function L:ShowRecap(a)
    if not a or not W:Setting(ID, "autoRecap", true) then return end
    local lines, byName = {}, {}
    for _, s in ipairs(a.taken) do
        if not s.coin then
            local key = s.name or "?"
            if byName[key] then
                byName[key].count = byName[key].count + (s.count or 1)
            else
                byName[key] = { icon = s.icon, name = s.name or "?", quality = s.quality, count = s.count or 1 }
                table.insert(lines, byName[key])
            end
        end
    end
    -- The loot slots can empty before their item data arrives (the client's own auto loot is fast):
    -- then the "You receive loot" lines the server sends are the record of what was taken.
    if not lines[1] and a.chat then
        for _, e in ipairs(a.chat) do table.insert(lines, e) end
    end
    if a.copper and a.copper > 0 then table.insert(lines, { icon = COIN_ICON, money = a.copper }) end
    if not lines[1] then return end
    self.recapLines, self.recapFromChat = lines, next(byName) == nil
    self:DrawRecap(lines, a.corpses)
end

function L:DrawRecap(lines, corpses)
    local shown = math.min(getn(lines), RECAP_ROWS)
    for i, r in ipairs(recap.rows) do
        local e = lines[i]
        if i <= shown and e then
            r.box.icon:SetTexture(e.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            if e.money then
                r.text:SetText(coins(e.money))
            else
                local hex = QUALITY_HEX[e.quality or 1] or QUALITY_HEX[1]
                r.text:SetText("|c" .. hex .. e.name .. "|r" .. ((e.count > 1) and ("  |cffd0d0d0x" .. e.count .. "|r") or ""))
            end
            r:Show()
        else
            r:Hide()
        end
    end
    corpses = corpses or 1
    if recap.title then recap.title:SetText((corpses > 1) and ("Looted from " .. corpses) or "Looted") end
    recap:SetHeight(40 + shown * 22)
    -- where the loot window would have opened
    if W:Setting(ID, "atCursor", true) then
        local x, y = GetCursorPosition()
        local scale = UIParent:GetEffectiveScale() or 1
        if scale <= 0 then scale = 1 end
        local sw = UIParent:GetWidth() or 1024
        local sh = UIParent:GetHeight() or 768
        local h = recap:GetHeight() or 100
        -- beside the cursor, not on it (you clicked the corpse at your feet), and never over your
        -- character, who stands in the middle of the screen: out to the side of that band instead
        x, y = x / scale + RECAP_OFFSET_X, y / scale + RECAP_OFFSET_Y
        local band = RECAP_CLEAR_W / 2
        if x + 210 > sw / 2 - band and x < sw / 2 + band then
            x = sw / 2 + band                      -- the right-hand side: away from the bags and chat
        end
        if x < 0 then x = 0 end
        if x + 210 > sw then x = sw / 2 - band - 210 end
        if y > sh then y = sh end
        if y - h < 120 then y = 120 + h end
        recap:ClearAllPoints()
        recap:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, y)
    else
        recap:ClearAllPoints()
        recap:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    end
    recap.shownAt = GetTime()
    recap:SetAlpha(1)
    recap:Show()
end

recap:SetScript("OnUpdate", function()
    local age = GetTime() - (recap.shownAt or 0)
    if age < RECAP_HOLD then return end
    local k = (age - RECAP_HOLD) / RECAP_FADE
    if k >= 1 then recap:Hide() else recap:SetAlpha(1 - k) end
end)

-- "You receive loot: [Linen Cloth]x5." -> a recap row (name, quality, icon from the link's item).
function L.ParseLootLine(msg)
    if type(msg) ~= "string" or not strfind(msg, "^You receive loot") then return end
    local _, _, link = strfind(msg, "(|c%x+|Hitem:[^|]+|h%[[^%]]+%]|h|r)")
    local name, id
    if link then
        _, _, id = strfind(link, "|Hitem:(%d+)")
        _, _, name = strfind(link, "|h%[([^%]]+)%]|h")
    else
        _, _, name = strfind(msg, "%[([^%]]+)%]")
    end
    if not name then return end
    local _, _, count = strfind(msg, "%]|?h?|?r?x(%d+)")
    local e = { name = name, count = tonumber(count) or 1, quality = 1 }
    if id and GetItemInfo then
        local ok, _, _, q, _, _, _, _, _, tex = pcall(GetItemInfo, tonumber(id))
        if ok then e.quality = q or 1; e.icon = tex end
    end
    if link and e.quality == 1 then
        local _, _, hex = strfind(link, "^|c(%x+)")
        for q, h in pairs(QUALITY_HEX) do if h == hex then e.quality = q end end
    end
    return e
end

-- A loot line during (or just after) an auto loot: kept for the recap, and added to it when it is
-- already showing from chat lines (lines can arrive after the loot closed).
function L:OnLootLine(msg)
    local e = L.ParseLootLine(msg)
    if not e then return end
    local a = self.auto
    if a then
        a.chat = a.chat or {}
        table.insert(a.chat, e)
        return
    end
    if GetTime() < (self.quietUntil or 0) and self.recapFromChat and recap:IsShown() and self.recapLines then
        local merged
        for _, x in ipairs(self.recapLines) do
            if x.name == e.name then x.count = x.count + e.count; merged = true end
        end
        if not merged then table.insert(self.recapLines, 1, e) end
        self:DrawRecap(self.recapLines)
    elseif self.lateChat and GetTime() < (self.quietUntil or 0) and not recap:IsShown() then
        -- nothing was recorded from the slots: this line starts the recap
        self.recapLines, self.recapFromChat = { e }, true
        self:DrawRecap(self.recapLines)
    end
end

-- -- Opening, taking, closing ------------------------------------------------------------------------

function L:Place()
    if not W:Setting(ID, "atCursor", true) then return end
    local x, y = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale() or 1
    if scale <= 0 then scale = 1 end
    x, y = x / scale - 30, y / scale + 20
    local sw, sh = UIParent:GetWidth() or 1024, UIParent:GetHeight() or 768
    if x < 0 then x = 0 end
    if x + lay.width > sw then x = sw - lay.width end
    if y > sh then y = sh end
    if y < 200 then y = 200 end
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, y)
end

-- Does the client still hold loot in this slot? (Asked live, not from our copy.)
local function slotHasLoot(slot)
    if LootSlotIsItem and LootSlotIsItem(slot) then return true end
    if LootSlotIsCoin and LootSlotIsCoin(slot) then return true end
    return GetLootSlotInfo(slot) and true or false
end

-- Every slot the client still holds, including ones whose item data has not arrived yet, through
-- LootSlot: only for auto loot, where the client sweeps the slots itself and this is the fallback
-- for a client whose LootSlot takes. Uncommon or better is left to the client: its sweep may have
-- raised LOOT_BIND_CONFIRM for one, and LootSlot on that row would be the popup's Okay.
function L:TakeAll()
    for slot = GetNumLootItems() or 0, 1, -1 do
        local s = self.slots[slot]
        local take
        if s then take = not s.taken and (s.coin or (s.quality or 0) < 2) else take = slotHasLoot(slot) end
        if take then LootSlot(slot) end
    end
end

-- The first coin slot still there.
function L:CoinSlot()
    for slot = 1, (GetNumLootItems() or 0) do
        local s = self.slots[slot]
        if s and s.coin and not s.taken then return slot end
    end
end

-- The slot Take All's next click takes: the money first, then the items in order, skipping one
-- just asked for (still on its way, or it did not fit) unless nothing else is left. `after` is the
-- slot that click just asked for: the search goes on from it.
function L:SlotTakeAll(after)
    local n = GetNumLootItems() or 0
    local now = GetTime()
    local order = {}
    local coin = self:CoinSlot()
    if coin then table.insert(order, coin) end
    for _, slot in ipairs(self:Items()) do table.insert(order, slot) end
    local start = 1
    if after then
        for i, slot in ipairs(order) do if slot == after then start = i + 1 break end end
    end
    local pick, fallback
    local m = getn(order)
    for k = 0, m - 1 do
        local j = start - 1 + k
        local slot = order[j - floor(j / m) * m + 1]
        if slot ~= after or m == 1 then
            fallback = fallback or slot
            if now - (self.asked[slot] or -10) > 1 then pick = slot break end
        end
    end
    pick = pick or fallback
    takeAll.slot = pick
    takeAll:SetSlot(pick or 0)
    return pick
end

function L:TakeMoney()
    for slot = 1, (GetNumLootItems() or 0) do
        local s = self.slots[slot]
        if s and s.coin and not s.taken then LootSlot(slot) end
    end
end

-- Close: hide the window, which closes the loot (OnHide), like the stock window's close button.
function L:CloseWindow()
    if frame:IsShown() then frame:Hide() elseif CloseLoot then CloseLoot() end
end

-- Auto loot: the client's flag, or the autoLootDefault setting (which turns Shift around: with it
-- on, Shift-looting opens the window; with it off, Shift-looting takes everything).
function L.IsAutoLoot(flag)
    if flag == 1 then return true end
    local default = false
    if GetCVar then
        local ok, v = pcall(GetCVar, "autoLootDefault")
        default = ok and v == "1"
    end
    local shift = IsShiftKeyDown() and true or false
    return default ~= shift
end

local function isMasterLooter()
    if not GetLootMethod then return false end
    local method, partyMaster, raidMaster = GetLootMethod()
    if method ~= "master" then return false end
    if raidMaster then return UnitIsUnit("raid" .. raidMaster, "player") and true or false end
    return partyMaster == 0
end

-- Let the stock LootFrame handle one event (it is unregistered while ours is in charge).
local function toStock(ev, a1)
    if not LootFrame then return end
    local fn = LootFrame:GetScript("OnEvent")
    if not fn then return end
    local sThis, sEvent, sArg1 = this, event, arg1
    this, event, arg1 = LootFrame, ev, a1
    local ok, err = pcall(fn, ev)
    this, event, arg1 = sThis, sEvent, sArg1
    if not ok then W:Error(ID, err) end
end

function L:SetStockQuiet(quiet)
    if not LootFrame then return end
    if quiet == self.stockQuiet then return end
    self.stockQuiet = quiet
    for _, e in ipairs(STOCK_EVENTS) do
        if quiet then LootFrame:UnregisterEvent(e) else LootFrame:RegisterEvent(e) end
    end
end

-- Auto loot: take everything, then one line.
function L:StartAuto()
    self.auto = { started = GetTime(), taken = {}, copper = 0 }
    self:TakeAll()
end

function L:AutoSummary()
    local a = self.auto
    self.auto = nil
    self.quietUntil = GetTime() + 1.5
    if a and not a.shown then self:ShowRecap(a) end     -- (a.shown: the window opened for leftovers)
    -- an auto loot that recorded nothing yet: its loot lines may still be on their way
    self.lateChat = a and not a.shown and not recap:IsShown() and W:Setting(ID, "autoRecap", true) or nil
    if not a or not W:Setting(ID, "autoSummary", true) then return end
    local parts = {}
    local order, byName = {}, {}
    table.sort(a.taken, function(x, y) return (x.slot or 0) < (y.slot or 0) end)
    for _, s in ipairs(a.taken) do
        if not s.coin then
            local key = s.name or "?"
            if not byName[key] then
                byName[key] = { s = s, count = 0 }
                table.insert(order, key)
            end
            byName[key].count = byName[key].count + (s.count or 1)
        end
    end
    for _, key in ipairs(order) do
        local e = byName[key]
        table.insert(parts, (e.s.link or e.s.name) .. ((e.count > 1) and ("x" .. e.count) or ""))
    end
    if a.copper > 0 then table.insert(parts, coins(a.copper)) end
    if not parts[1] then return end
    local text
    if getn(parts) == 1 then
        text = parts[1]
    else
        local last = table.remove(parts)
        text = table.concat(parts, ", ") .. " and " .. last
    end
    local corpses = a.corpses or 1
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff40c040Looted|r " .. text .. ((corpses > 1) and (" from " .. corpses .. " corpses.") or "."), 0.85, 0.85, 0.85)
    end
end

-- Hide the per-item loot lines while auto loot makes its own summary.
W.chatFilters = W.chatFilters or {}
table.insert(W.chatFilters, function(ev)
    -- the server's loot lines can arrive just after the window closed
    if not (L.auto or GetTime() < (L.quietUntil or 0)) or not W:Setting(ID, "autoSummary", true) then return false end
    if ev == "CHAT_MSG_LOOT" and arg1 and strfind(arg1, "^You receive loot") then return true end
    if ev == "CHAT_MSG_MONEY" and arg1 and strfind(arg1, "^You loot") then return true end
    return false
end)

function L:OnOpened(autoFlag)
    self.offset = 0
    -- a new loot window: nothing from an earlier one carries over (an auto loot whose
    -- LOOT_CLOSED never came would otherwise keep summarising and re-showing this one)
    self.auto = nil
    self.closing = nil
    self.asked = {}
    self.lateChat, self.recapFromChat = nil, nil
    -- an AL packet sent just before the window opened belongs to it
    if self.al and GetTime() - (self.al.t or 0) > 2 then self.al = nil end
    self:Read()
    if not useOurs() or isMasterLooter() then
        self.stockMode = true
        if self.stockQuiet then toStock("LOOT_OPENED", autoFlag) end
        return
    end
    self.stockMode = nil
    if L.IsAutoLoot(autoFlag) then
        self:StartAuto()
        return
    end
    if chrome.portrait then
        chrome.portrait:SetTexture((IsFishingLoot and IsFishingLoot()) and "Interface\\LootFrame\\FishingLoot-Icon" or "Interface\\TargetingFrame\\TargetDead")
    end
    frame:Show()
    self:Place()
    self:Render()
end

-- Nothing left in the loot (every item and the money taken)?
function L:Emptied()
    if self:Items()[1] then return false end
    local _, any = self:Money()
    if any then return false end
    for slot = 1, (GetNumLootItems() or 0) do
        local s = self.slots[slot]
        if not s and slotHasLoot(slot) then return false end
    end
    return true
end

function L:OnSlotCleared(slot)
    local s = self.slots[slot]
    if s and not s.taken then
        s.taken = true
        local a = self.auto
        if a then
            table.insert(a.taken, s)
            if s.coin then a.copper = a.copper + ((self.al and self.al.copper > 0) and self.al.copper or (s.copper or 0)) end
        end
    end
    self:Render()
    -- everything taken: close the loot, as the stock window does. The server only lets go of
    -- the loot (and spends an opened container such as a Star Pouch) when it is closed.
    if not self.stockMode and self:Emptied() then self.closeAt = GetTime() + 0.15 end
end

function L:OnClosed()
    self.closeAt = nil
    if self.auto then
        self.auto.corpses = self.al and self.al.corpses
        self:AutoSummary()
    end
    self.closing = true
    frame:Hide()
    self.closing = nil
    self.slots = {}
    self.al = nil
    self.stockMode = nil
end

frame:SetScript("OnHide", function()
    -- closing our window (Escape, the X) closes the loot like the stock window does
    if not L.closing and CloseLoot then CloseLoot() end
end)

-- -- AL: area loot merged from several corpses ----------------------------------------------------

W:RegisterModule("AL", function(body)
    local recs, n = W.Split(body or "", ";")
    local head = W.Split(recs[1] or "", ",")
    local corpses = tonumber(head[1])
    if not corpses or corpses < 1 then return end
    local al = { corpses = floor(corpses), copper = math.max(0, floor(tonumber(head[2]) or 0)), sources = {}, t = GetTime() }
    for i = 2, n do
        local f = W.Split(recs[i], ",")
        local slot, src = tonumber(f[1]), tonumber(f[2])
        if slot and src and slot >= 1 and src >= 1 then al.sources[floor(slot)] = floor(src) end
    end
    L.al = al
    if L.auto then L.auto.corpses = al.corpses end
    L:Render()
end)

-- -- Events -------------------------------------------------------------------------------------------

local ev = CreateFrame("Frame", "Loot_Events")
for _, e in ipairs({ "LOOT_OPENED", "LOOT_SLOT_CLEARED", "LOOT_CLOSED", "CHAT_MSG_LOOT" }) do ev:RegisterEvent(e) end
ev:SetScript("OnEvent", function()
    if event == "CHAT_MSG_LOOT" then
        if useOurs() then L:OnLootLine(arg1) end
    elseif event == "LOOT_OPENED" then
        L:OnOpened(arg1)
    elseif event == "LOOT_SLOT_CLEARED" then
        if L.stockMode and L.stockQuiet then toStock("LOOT_SLOT_CLEARED", arg1) end
        L:OnSlotCleared(arg1)
    elseif event == "LOOT_CLOSED" then
        if L.stockMode and L.stockQuiet then toStock("LOOT_CLOSED") end
        L:OnClosed()
    end
end)
-- auto loot that could not take everything (full bags): show what is left
ev:SetScript("OnUpdate", function()
    if L.closeAt and GetTime() >= L.closeAt then
        L.closeAt = nil
        if L:Emptied() then L:CloseWindow() end
    end
    local a = L.auto
    if a and not a.shown and GetTime() - a.started > 1 and (L:Items()[1] or L.pending) and useOurs() then
        a.shown = true
        frame:Show()
        L:Place()
        L:Render()
    end
    -- item data still on its way: look again a few times a second
    if L.pending and frame:IsShown() and GetTime() >= (L.nextPoll or 0) then
        L.nextPoll = GetTime() + 0.3
        L:Render()
    end
end)

-- -- Skin --------------------------------------------------------------------------------------------

UI.OnSkin(function(th) L:PaintSkin(th) end)

-- -- Registration -----------------------------------------------------------------------------------

W:RegisterSchema(ID, {
    title = "Loot - Loot Window",
    icon = "Interface\\Icons\\INV_Misc_Bag_09",
    desc = "A clean loot window: every item on one list, the money from every corpse added up, Take All, and one chat line for auto loot. When the realm merges nearby corpses it shows how many each item came from.",
    defaults = { keepBlizzard = false, atCursor = true, autoSummary = true, autoRecap = true },
    options = {
        { key = "keepBlizzard", label = "Use the standard loot window", sub = "Keep the game's own loot window instead of this one." },
        { key = "atCursor", label = "Open at the mouse", sub = "The window opens where you clicked, like the standard one. Off: it stays where you drag it." },
        { key = "autoRecap", label = "Show what auto loot took", sub = "The loot shows for a moment, then fades." },
        { key = "autoSummary", label = "One line for auto loot", sub = "When you Shift-loot, one chat line lists everything instead of a line per item." },
    },
})

W:RegisterAddon(ID, function(on)
    L:SetStockQuiet(useOurs())
    if not useOurs() and frame:IsShown() then
        L.closing = true
        frame:Hide()
        L.closing = nil
    end
end)
