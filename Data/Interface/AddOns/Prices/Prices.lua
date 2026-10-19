--[[
    Prices.lua  -  Ledger
    Market and vendor prices at the bottom of item tooltips, with no auction scanning.

    Market price sources:
      * server  - "LG" packets: 7-day median buyout, vendor sell price, sample count.
      * local   - every auction page you browse is remembered (buyout per item, last 7 days),
                  so prices appear for what you have seen even without telemetry.
    Vendor (sell) price sources, best first. The 1.12 client has no sell-price API at all:
      * server  - the vendor field of an LG packet (the realm's own item_template.SellPrice).
      * learned - what merchants actually paid you: the buyback list (GetBuybackItemInfo gives
                  the price for the whole stack) is read whenever a merchant window updates, and
                  kept in WenillaCore_Config.vendorPrices. This covers realm-custom items.
      * shipped - SellData.lua: item_template.SellPrice of the CMaNGOS classic world database for
                  every item a merchant buys (tools/gen_sell_prices.py builds it).
    The tooltip shows the price for one and, for a stack, the stack's total. Nothing is shown
    for items with no data; Ledger never invents a price.

    LG packet: "<itemId>,<medianCopper>,<vendorCopper>,<samples>;..."
]]--

local W = WenillaCore
local UI = W.UI
local ID = "Prices"

Ledger = Ledger or {}
local L = Ledger
L.prices = {}       -- itemId -> { median, vendor, samples }  (server)
L.asked = {}

local floor, strfind = math.floor, string.find
local WEEK = 7 * 24 * 3600

local function itemId(link)
    local _, _, id = strfind(link or "", "item:(%d+)")
    return tonumber(id)
end

local function store()
    if not WenillaCore_Config then return nil end
    WenillaCore_Config.auctions = WenillaCore_Config.auctions or {}
    return WenillaCore_Config.auctions
end

-- The shipped table is one string "id:price;..."; look items up in it on demand.
local SELL = ";" .. (Ledger_SellData or "")
Ledger_SellData = nil
local sellCache = {}
local function shippedVendor(id)
    local v = sellCache[id]
    if v == nil then
        local _, _, price = strfind(SELL, ";" .. id .. ":(%d+)", 1)
        v = tonumber(price) or false
        sellCache[id] = v
    end
    return v or nil
end

local function learned()
    if not WenillaCore_Config then return nil end
    WenillaCore_Config.vendorPrices = WenillaCore_Config.vendorPrices or {}
    return WenillaCore_Config.vendorPrices
end

-- What a merchant pays for one, and where the number comes from ("server", "learned", "shipped").
function L:Vendor(id)
    local srv = self.prices[id]
    if srv and srv.vendor and srv.vendor > 0 then return srv.vendor, "server" end
    local db = learned()
    if db and db[id] and db[id] > 0 then return db[id], "learned" end
    local v = shippedVendor(id)
    if v and v > 0 then return v, "shipped" end
end

local function median(samples)
    local now = time()
    local list = {}
    for _, s in ipairs(samples) do
        if now - s[1] <= WEEK then table.insert(list, s[2]) end
    end
    local n = table.getn(list)
    if n == 0 then return nil, 0 end
    table.sort(list)
    if (math.mod or math.fmod)(n, 2) == 1 then return list[(n + 1) / 2], n end
    return floor((list[n / 2] + list[n / 2 + 1]) / 2), n
end

-- Remember one auction: buyout per unit, at most one sample per item and seller per hour.
function L:Learn(id, perUnit, seller)
    local db = store()
    if not db or not id or perUnit <= 0 then return end
    local rec = db[id]
    if not rec then
        rec = {}
        db[id] = rec
    end
    local now = time()
    for _, s in ipairs(rec) do
        if s[3] == seller and now - s[1] < 3600 and s[2] == perUnit then return end
    end
    table.insert(rec, { now, perUnit, seller })
    while table.getn(rec) > 40 do table.remove(rec, 1) end
end

function L:Market(id)
    local srv = self.prices[id]
    if srv and srv.median and srv.median > 0 then return srv.median, srv.samples, "server" end
    local db = store()
    local rec = db and db[id]
    if rec then
        local m, n = median(rec)
        if m then return m, n, "seen" end
    end
end

-- -- Tooltip -------------------------------------------------------------------

local function addLines(tooltip, link, count)
    if not link or not W:IsActive(ID) then return end
    local id = itemId(link)
    if not id then return end
    local s = W:Settings(ID)
    local market, samples, src = L:Market(id)
    local vendor = L:Vendor(id)
    if W.connected and not L.prices[id] and not L.asked[id] then
        L.asked[id] = true
        W:SendCommand("lg", tostring(id))
    end
    if market and s.showMarket == false then market = nil end
    if vendor and s.showVendor == false then vendor = nil end
    if not market and not vendor then return end
    count = count and count > 1 and count or nil
    tooltip:AddLine(" ")
    tooltip:AddLine("Pricing", 1, 0.82, 0)
    if market then
        local label = src == "server" and "Market (7d)" or "Auction (seen)"
        if s.showSamples ~= false and samples then label = label .. " |cff808080x" .. samples .. "|r" end
        tooltip:AddDoubleLine(label, UI.CoinText(market) .. (count and ("  |cff808080(" .. UI.CoinText(market * count) .. ")|r") or ""), 0.85, 0.85, 0.85, 1, 1, 1)
    end
    if vendor then
        tooltip:AddDoubleLine("Vendor", UI.CoinText(vendor) .. (count and ("  |cff808080(" .. UI.CoinText(vendor * count) .. ")|r") or ""), 0.85, 0.85, 0.85, 1, 1, 1)
    end
    tooltip:Show()
end

local function hook(method, linkOf)
    local original = GameTooltip[method]
    if not original then return end
    GameTooltip[method] = function(self, a1, a2, a3)
        local r1, r2, r3 = original(self, a1, a2, a3)
        local ok, link, count = pcall(linkOf, a1, a2, a3)
        if ok then addLines(self, link, count) end
        return r1, r2, r3
    end
end

hook("SetBagItem", function(bag, slot)
    local _, count = GetContainerItemInfo(bag, slot)
    return GetContainerItemLink(bag, slot), count
end)
hook("SetInventoryItem", function(unit, slot) return GetInventoryItemLink(unit, slot) end)
hook("SetHyperlink", function(link) return link end)
hook("SetLootItem", function(slot)
    local _, _, count = GetLootSlotInfo(slot)
    return GetLootSlotLink(slot), count
end)
hook("SetMerchantItem", function(i) return GetMerchantItemLink(i) end)
hook("SetAuctionItem", function(kind, i)
    local _, _, count = GetAuctionItemInfo(kind, i)
    return GetAuctionItemLink(kind, i), count
end)
hook("SetQuestItem", function(kind, i) return GetQuestItemLink(kind, i) end)
hook("SetQuestLogItem", function(kind, i) return GetQuestLogItemLink(kind, i) end)
hook("SetTradePlayerItem", function(i) return GetTradePlayerItemLink(i) end)
hook("SetTradeTargetItem", function(i) return GetTradeTargetItemLink(i) end)
hook("SetCraftItem", function(i, r)
    if r then return GetCraftReagentItemLink(i, r) end
    return GetCraftItemLink(i)
end)
hook("SetTradeSkillItem", function(i, r)
    if r then return GetTradeSkillReagentItemLink(i, r) end
    return GetTradeSkillItemLink(i)
end)

-- -- Learning from the auction house -------------------------------------------

local ev = CreateFrame("Frame", "Ledger_Events")
ev:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")
ev:SetScript("OnEvent", function()
    if not W:IsActive(ID) or not GetNumAuctionItems then return end
    local n = GetNumAuctionItems("list") or 0
    for i = 1, n do
        local _, _, count, _, _, _, _, _, buyout, _, _, owner = GetAuctionItemInfo("list", i)
        local id = itemId(GetAuctionItemLink("list", i))
        if id and buyout and buyout > 0 and count and count > 0 then
            L:Learn(id, floor(buyout / count), owner or "?")
        end
    end
end)

-- -- Learning from merchants -------------------------------------------------------
-- The buyback list holds what you just sold with the price paid for the whole stack.

function L:LearnBuyback()
    local db = learned()
    if not db or not (GetNumBuybackItems and GetBuybackItemInfo and GetBuybackItemLink) then return end
    for i = 1, GetNumBuybackItems() or 0 do
        local _, _, price, quantity = GetBuybackItemInfo(i)
        local id = itemId(GetBuybackItemLink(i))
        if id and price and price > 0 then
            db[id] = floor(price / ((quantity and quantity > 0) and quantity or 1) + 0.5)
        end
    end
end

local mev = CreateFrame("Frame", "Ledger_Merchant")
mev:RegisterEvent("MERCHANT_SHOW")
mev:RegisterEvent("MERCHANT_UPDATE")
mev:SetScript("OnEvent", function()
    if W:IsActive(ID) then L:LearnBuyback() end
end)

-- -- Server packets (LG) -------------------------------------------------------

W:RegisterModule("LG", function(body)
    local recs, n = W.Split(body, ";")
    for i = 1, n do
        local f = W.Split(recs[i], ",")
        local id = tonumber(f[1])
        if id then
            L.prices[id] = { median = tonumber(f[2]) or 0, vendor = tonumber(f[3]) or 0, samples = tonumber(f[4]) or 0 }
        end
    end
end)

W:RegisterAddon(ID, function() end)

SLASH_PRICES1 = "/prices"
SLASH_PRICES2 = "/ledger"
SlashCmdList["PRICES"] = function()
    local db = store()
    local items = 0
    if db then for _ in pairs(db) do items = items + 1 end end
    W.Print("Prices: " .. items .. " item price" .. (items == 1 and "" or "s") .. " remembered from the auction house"
        .. (W.connected and ", plus server market data." or ". Browse the auction house to add more."))
end
