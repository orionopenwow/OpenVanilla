--[[
    Vendor.lua  -  Scrapper
    A gold "Scrap" button on the merchant window: sells every grey item and repairs your gear.
    Auto-sell and auto-repair run the moment a merchant opens (both on by default), and one
    chat line sums up the visit: what the greys earned (measured from your purse, so it is
    exact) and what the repair cost.

    With server telemetry the whole sale is one ".wnl sc sell" command executed in a single
    server pass ("SC" reply: "<count>,<copper>"); without it the client sells item by item.
]]--

local W = WenillaCore
local UI = W.UI
local ID = "Vendor"

Scrapper = Scrapper or {}
local S = Scrapper

local function greys()
    local list = {}
    for bag = 0, 4 do
        for slot = 1, (GetContainerNumSlots(bag) or 0) do
            local link = GetContainerItemLink(bag, slot)
            local _, _, locked = GetContainerItemInfo(bag, slot)
            if link and not locked and string.find(link, "|cff9d9d9d", 1, 1) then
                table.insert(list, { bag, slot })
            end
        end
    end
    return list
end

-- -- Button --------------------------------------------------------------------

local btn = CreateFrame("Button", "Scrapper_Button", MerchantFrame or UIParent)
btn:SetWidth(78)
btn:SetHeight(22)
if MerchantFrame then
    btn:SetPoint("TOPRIGHT", MerchantFrame, "TOPRIGHT", -44, -44)
else
    btn:SetPoint("CENTER", UIParent, "CENTER", 0, -160)
end
btn:SetBackdrop(UI.THIN)
btn:SetBackdropColor(0.16, 0.12, 0.04, 0.95)
btn:SetBackdropBorderColor(0.88, 0.72, 0.28, 1)
btn:SetFrameLevel((MerchantFrame and MerchantFrame:GetFrameLevel() or 1) + 5)

local icon = btn:CreateTexture(nil, "ARTWORK")
icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_02")
icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
icon:SetWidth(14)
icon:SetHeight(14)
icon:SetPoint("LEFT", btn, "LEFT", 5, 0)

local label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
label:SetPoint("LEFT", icon, "RIGHT", 4, 0)
label:SetText("Scrap")
local countText = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
countText:SetPoint("RIGHT", btn, "RIGHT", -6, 0)

btn:SetHighlightTexture("Interface\\Buttons\\UI-Panel-Button-Highlight")

function S:UpdateButton()
    local n = table.getn(greys())
    countText:SetText(n > 0 and n or "")
    if n > 0 then label:SetTextColor(1, 0.82, 0) else label:SetTextColor(0.6, 0.6, 0.6) end
end

btn:SetScript("OnEnter", function()
    GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
    GameTooltip:SetText("Vendor", 1, 0.82, 0)
    local n = table.getn(greys())
    GameTooltip:AddLine(n > 0 and ("Sell " .. n .. " grey item" .. (n == 1 and "" or "s") .. " and repair your gear.") or "No grey items. Click to repair your gear.", 0.85, 0.85, 0.85)
    if CanMerchantRepair and CanMerchantRepair() then
        local cost = GetRepairAllCost()
        if cost and cost > 0 then GameTooltip:AddDoubleLine("Repair", UI.CoinText(cost), 0.85, 0.85, 0.85, 1, 1, 1) end
    end
    GameTooltip:Show()
end)
btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- -- Selling & repairing -------------------------------------------------------
-- One summary line per visit: "Vendor: sold 3 grey items for 22c and repaired your gear for
-- 12s 34c." The sale is measured from your purse once it settles, so it is exact.

local function plural(n) return n .. " grey item" .. (n == 1 and "" or "s") end

local function summary(count, earned, repaired)
    if not W:Setting(ID, "printSummary", true) then return end
    local parts = {}
    if count and count > 0 and earned and earned > 0 then
        table.insert(parts, "sold " .. plural(count) .. " for " .. UI.CoinText(earned))
    end
    if repaired and repaired > 0 then table.insert(parts, "repaired your gear for " .. UI.CoinText(repaired)) end
    if not parts[1] then return end
    W.Print("Vendor: " .. table.concat(parts, " and ") .. ".")
end

-- Returns what the repair cost (0 when nothing needed repairing or it could not be afforded).
function S:Repair()
    if not (CanMerchantRepair and CanMerchantRepair()) then return 0 end
    local cost, canRepair = GetRepairAllCost()
    if not (canRepair and cost and cost > 0) then return 0 end
    if GetMoney() < cost then
        if W:Setting(ID, "printSummary", true) then
            W.Print("Vendor: repairs cost " .. UI.CoinText(cost) .. "; you have " .. UI.CoinText(GetMoney()) .. ".")
        end
        return 0
    end
    RepairAllItems()
    return cost
end

-- purseBefore: the purse before any repair this run (the repair debit can arrive after the sales),
-- so the summary counts only what the greys earned. Returns true when a sale started.
function S:Sell(purseBefore, repaired)
    if not (MerchantFrame and MerchantFrame:IsVisible()) then return false end
    local list = greys()
    if table.getn(list) == 0 then return false end
    -- only a realm that lists Vendor in its greeting sells server-side; older realms ignore "sc"
    if W:ServerHas("Vendor") and W:SendCommand("sc sell") then
        self.pending = { t = GetTime(), server = true, repaired = repaired }
        return true
    end
    self.pending = { t = GetTime(), money = purseBefore or GetMoney(), count = table.getn(list), repaired = repaired }
    for _, s in ipairs(list) do UseContainerItem(s[1], s[2]) end
    return true
end

function S:Run(auto)
    local s = W:Settings(ID)
    -- repair first so the sale summary measures only what the greys earned
    local before, cost = GetMoney(), 0
    if not auto or s.autoRepair ~= false then cost = self:Repair() or 0 end
    local selling = false
    if not auto or s.autoSell ~= false then selling = self:Sell(before - cost, cost) end
    if not selling then summary(0, 0, cost) end
end

btn:SetScript("OnClick", function() S:Run(false) end)

-- the purse settles a moment after the last sale; report then
local watcher = CreateFrame("Frame")
watcher:SetScript("OnUpdate", function()
    local p = S.pending
    if not p or p.server then return end
    if GetTime() - p.t > 1.5 then
        S.pending = nil
        summary(p.count, GetMoney() - p.money, p.repaired)
        S:UpdateButton()
    end
end)

W:RegisterModule("SC", function(body)
    local f = W.Split(body, ",")
    local p = S.pending
    S.pending = nil
    summary(tonumber(f[1]) or 0, tonumber(f[2]) or 0, p and p.repaired)
    S:UpdateButton()
end)

-- -- Events --------------------------------------------------------------------

local ev = CreateFrame("Frame", "Scrapper_Events")
ev:RegisterEvent("MERCHANT_SHOW")
ev:RegisterEvent("MERCHANT_CLOSED")
ev:RegisterEvent("BAG_UPDATE")
ev:SetScript("OnEvent", function()
    if not W:IsActive(ID) then return end
    if event == "MERCHANT_SHOW" then
        S:UpdateButton()
        if W:Setting(ID, "showButton", true) then btn:Show() else btn:Hide() end
        S:Run(true)
    elseif event == "BAG_UPDATE" and btn:IsVisible() then
        S:UpdateButton()
    end
end)

W:RegisterAddon(ID, function(active)
    if active and W:Setting(ID, "showButton", true) then btn:Show() else btn:Hide() end
end)

SLASH_VENDOR1 = "/vendor"
SLASH_VENDOR2 = "/junk"
SLASH_VENDOR3 = "/scrap"
SlashCmdList["VENDOR"] = function()
    if not W:IsActive(ID) then W.Print("Vendor is switched off. Turn it on in /addons.") return end
    if MerchantFrame and MerchantFrame:IsVisible() then
        S:Run(false)
    else
        local n = table.getn(greys())
        W.Print("Vendor: " .. n .. " grey item" .. (n == 1 and "" or "s") .. " in your bags. Open a merchant to sell.")
    end
end
