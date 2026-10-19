--[[
    Actions.lua  (Essentials)
    On the stock action bars (and the Repack's, which are the same buttons):
        * cooldown numbers, OmniCC style: big and centred, red under 5 s, yellow under a minute
        * the icon turns red when the target is out of range and blue without enough mana
        * a count in the corner of spells that use something up: soul shards and other reagents
          (read from the spell's tooltip), arrows and bullets (the ammo slot), thrown weapons
    and cooldown numbers on the items in the stock bag windows.

    Lua 5.0 rules (1.12.1 client): no '#', no '%', handlers read this/event/arg1.
]]--

local E = Essentials
local W = WenillaCore
local UI = W.UI

local BARS = { "ActionButton", "BonusActionButton", "MultiBarBottomLeftButton", "MultiBarBottomRightButton",
    "MultiBarRightButton", "MultiBarLeftButton" }
local MIN_COOLDOWN = 2.0          -- the global cooldown (1.5 s) gets no number

local buttons = {}                -- action buttons we decorated
local bagButtons = {}             -- "ContainerFrameNItemM" -> decoration

-- -- Formatting ------------------------------------------------------------------------------

function E.FormatCooldown(rem)
    if rem >= 3600 then return math.ceil(rem / 3600) .. "h" end
    if rem >= 60 then return math.ceil(rem / 60) .. "m" end
    if rem < 3 then return string.format("%.1f", math.floor(rem * 10 + 0.5) / 10) end
    return tostring(math.ceil(rem))
end

local function urgency(rem)
    if W.Palette and W.Palette.Urgency then return W.Palette.Urgency(rem) end
    if rem < 5 then return 1, 0.25, 0.2 end
    if rem < 60 then return 1, 0.9, 0.25 end
    return 1, 1, 1
end

-- -- Decorating a button ---------------------------------------------------------------------

local function decorate(b)
    if b.ess then return b.ess end
    local d = {}
    local over = CreateFrame("Frame", nil, b)
    over:SetAllPoints(b)
    over:SetFrameLevel(b:GetFrameLevel() + 3)
    d.cd = over:CreateFontString(nil, "OVERLAY")
    local w = b:GetWidth()
    if not w or w < 20 then w = 36 end
    d.cd:SetFont(UI.FONT, math.max(11, math.floor(w * 0.45)), "OUTLINE")
    d.cd:SetPoint("CENTER", b, "CENTER", 1, 0)
    d.cd:SetShadowOffset(1, -1)
    d.cd:SetShadowColor(0, 0, 0, 1)
    d.count = over:CreateFontString(nil, "OVERLAY")
    d.count:SetFont(UI.FONT, math.max(9, math.floor(w * 0.3)), "OUTLINE")
    d.count:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -2, 2)
    d.count:SetJustifyH("RIGHT")
    d.over = over
    b.ess = d
    return d
end

local function collect()
    for _, prefix in ipairs(BARS) do
        for i = 1, 12 do
            local b = getglobal(prefix .. i)
            if b and not b.ess then
                decorate(b)
                table.insert(buttons, b)
            end
        end
    end
end

local function slotOf(b)
    if ActionButton_GetPagedID then
        local ok, id = pcall(ActionButton_GetPagedID, b)
        if ok and id then return id end
    end
    return b:GetID()
end

local function setCooldownText(d, start, duration, enable, now)
    if enable and enable ~= 0 and start and start > 0 and duration and duration > MIN_COOLDOWN then
        local rem = start + duration - now
        if rem > 0 then
            d.cd:SetText(E.FormatCooldown(rem))
            d.cd:SetTextColor(urgency(rem))
            return
        end
    end
    d.cd:SetText("")
end

-- -- Range & mana ------------------------------------------------------------------------------

local RED, BLUE, GREY, WHITE = { 0.85, 0.15, 0.15 }, { 0.25, 0.45, 1 }, { 0.4, 0.4, 0.4 }, { 1, 1, 1 }

function E.TintButton(b)
    local icon = b and b.GetName and b:GetName() and getglobal(b:GetName() .. "Icon")
    if not icon then return end
    local slot = slotOf(b)
    if not HasAction(slot) then return end
    local c = WHITE
    local usable, noMana = IsUsableAction(slot)
    if IsActionInRange(slot) == 0 then
        c = RED
        if W.Palette and W.Palette.ColorBlind and W.Palette.ColorBlind() then c = { 0.84, 0.37, 0 } end
    elseif noMana then
        c = BLUE
    elseif not usable then
        c = GREY
    end
    icon:SetVertexColor(c[1], c[2], c[3])
    b.ess = b.ess or decorate(b)
    b.ess.tinted = true
end

local function untint(b)
    local icon = b.ess and b.ess.tinted and getglobal(b:GetName() .. "Icon")
    if not icon then return end
    b.ess.tinted = nil
    local slot = slotOf(b)
    local usable, noMana = IsUsableAction(slot)
    if usable then icon:SetVertexColor(1, 1, 1)
    elseif noMana then icon:SetVertexColor(0.5, 0.5, 1)
    else icon:SetVertexColor(0.4, 0.4, 0.4) end
end

-- The stock bar recolours icons on its own events; put ours back right after.
if ActionButton_UpdateUsable then
    local stock = ActionButton_UpdateUsable
    ActionButton_UpdateUsable = function(a1, a2)
        stock(a1, a2)
        if E.On("rangeColor") and this then E.TintButton(this) end
    end
end

-- -- Reagents & ammo ---------------------------------------------------------------------------

-- Shots that use the ammo in the ammo slot (0); Throw uses the thrown weapon stack (slot 18).
local AMMO = {
    ["Auto Shot"] = 0, ["Arcane Shot"] = 0, ["Aimed Shot"] = 0, ["Multi-Shot"] = 0, ["Concussive Shot"] = 0,
    ["Distracting Shot"] = 0, ["Scatter Shot"] = 0, ["Tranquilizing Shot"] = 0, ["Serpent Sting"] = 0,
    ["Viper Sting"] = 0, ["Scorpid Sting"] = 0, ["Wyvern Sting"] = 0, ["Volley"] = 0,
    ["Shoot Bow"] = 0, ["Shoot Gun"] = 0, ["Shoot Crossbow"] = 0, ["Throw"] = 18,
}
E.AMMO_SPELLS = AMMO

local reagentCache = {}           -- slot -> { ammo = slot } | { item = "Soul Shard" } | false
local bagCounts                   -- item name -> count, rebuilt on BAG_UPDATE

local function reagentPattern()
    local fmt = SPELL_REAGENTS or "Reagents: %s"
    local p = string.gsub(fmt, "([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
    p = string.gsub(p, "%%s", "(.+)")
    return "^" .. p
end

local function needFor(slot)
    local c = reagentCache[slot]
    if c ~= nil then return c end
    c = false
    if HasAction(slot) and not (IsConsumableAction and IsConsumableAction(slot)) and not GetActionText(slot) then
        local tip = E.ScanTip()
        tip:SetAction(slot)
        local name = E.TipLine(1)
        if name and AMMO[name] then
            c = { ammo = AMMO[name] }
        else
            local pat = reagentPattern()
            for i = 2, tip:NumLines() or 0 do
                local line = E.TipLine(i)
                local _, _, list = string.find(line or "", pat)
                if list then
                    local _, _, first = string.find(list, "^([^,]+)")
                    first = string.gsub(first or list, "%s*%(%d+%)%s*$", "")
                    c = { item = W.Trim(first) }
                    break
                end
            end
        end
    end
    reagentCache[slot] = c
    return c
end

local function countBags()
    bagCounts = {}
    for bag = 0, 4 do
        for slot = 1, (GetContainerNumSlots(bag) or 0) do
            local link = GetContainerItemLink(bag, slot)
            local _, _, name = string.find(link or "", "%[(.-)%]")
            if name then
                local _, n = GetContainerItemInfo(bag, slot)
                bagCounts[name] = (bagCounts[name] or 0) + (n or 1)
            end
        end
    end
end

function E.ReagentCount(slot)
    local need = needFor(slot)
    if not need then return nil end
    if need.ammo then
        if not GetInventoryItemTexture("player", need.ammo) then return 0 end
        return GetInventoryItemCount("player", need.ammo) or 0
    end
    if not bagCounts then countBags() end
    return bagCounts[need.item] or 0
end

-- -- The update loop -----------------------------------------------------------------------------

local function updateButton(b, now, cdOn, rangeOn, countOn)
    local d = b.ess
    local slot = slotOf(b)
    if not HasAction(slot) then
        d.cd:SetText("")
        d.count:SetText("")
        return
    end
    if cdOn then
        local start, duration, enable = GetActionCooldown(slot)
        setCooldownText(d, start, duration, enable, now)
    else
        d.cd:SetText("")
    end
    if rangeOn then E.TintButton(b) elseif d.tinted then untint(b) end
    if countOn then
        local n = E.ReagentCount(slot)
        if n then
            d.count:SetText(n)
            if n == 0 then d.count:SetTextColor(1, 0.3, 0.3) else d.count:SetTextColor(1, 1, 1) end
        else
            d.count:SetText("")
        end
    else
        d.count:SetText("")
    end
end

local function updateBags(now)
    for c = 1, 12 do
        local cf = getglobal("ContainerFrame" .. c)
        if cf and cf:IsVisible() then
            local bag = cf:GetID()
            for i = 1, 36 do
                local b = getglobal("ContainerFrame" .. c .. "Item" .. i)
                if not b then break end
                local d = decorate(b)
                bagButtons[b] = d
                if b:IsVisible() then
                    local start, duration, enable = GetContainerItemCooldown(bag, b:GetID())
                    setCooldownText(d, start, duration, enable, now)
                end
            end
        end
    end
end

-- Other bag windows (the Bags addon's) can hand us their item buttons:
--     Essentials.AddBagButton(button, function() return bag, slot end)
local extraBags = {}
function E.AddBagButton(button, where)
    if button and where then extraBags[button] = where end
end
local function updateExtraBags(now)
    for b, where in pairs(extraBags) do
        local d = decorate(b)
        bagButtons[b] = d
        if b:IsVisible() then
            local bag, slot = where()
            if bag and slot then
                local start, duration, enable = GetContainerItemCooldown(bag, slot)
                setCooldownText(d, start, duration, enable, now)
            else
                d.cd:SetText("")
            end
        end
    end
end

local function clearAll()
    for _, b in ipairs(buttons) do
        b.ess.cd:SetText("")
        b.ess.count:SetText("")
        if b.ess.tinted then untint(b) end
    end
    for _, d in pairs(bagButtons) do d.cd:SetText("") end
end

local driver = CreateFrame("Frame", "EssentialsActions")
local acc = 0
driver:SetScript("OnUpdate", function()
    acc = acc + arg1
    if acc < 0.1 then return end
    acc = 0
    collect()
    local now = GetTime()
    local cdOn, rangeOn, countOn = E.On("cooldownText"), E.On("rangeColor"), E.On("reagentCount")
    for _, b in ipairs(buttons) do
        if b:IsVisible() then updateButton(b, now, cdOn, rangeOn, countOn) end
    end
    if cdOn then
        updateBags(now)
        updateExtraBags(now)
    end
end)

local ev = CreateFrame("Frame")
for _, e in ipairs({ "ACTIONBAR_SLOT_CHANGED", "ACTIONBAR_PAGE_CHANGED", "UPDATE_BONUS_ACTIONBAR", "BAG_UPDATE",
    "UNIT_INVENTORY_CHANGED", "SPELLS_CHANGED" }) do ev:RegisterEvent(e) end
ev:SetScript("OnEvent", function()
    if event == "ACTIONBAR_SLOT_CHANGED" and arg1 then
        reagentCache[arg1] = nil
    elseif event == "BAG_UPDATE" or event == "UNIT_INVENTORY_CHANGED" then
        bagCounts = nil
    else
        reagentCache = {}
    end
end)

E.OnRefresh(function(active)
    if active then
        driver:Show()
    else
        driver:Hide()
        clearAll()
    end
end)
