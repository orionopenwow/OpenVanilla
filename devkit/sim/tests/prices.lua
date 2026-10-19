-- Prices (Ledger): LG server prices and remembered auction pages on item tooltips.
local T, api = ...

local BAGS = { [0] = { size = 16, items = { { 2589, 20 }, { 4306, 1 }, { 2770, 5 } } } }

local function tipFor(env, bag, slot)
    env.GameTooltip:SetOwner(env.UIParent)
    env.GameTooltip:SetBagItem(bag or 0, slot or 1)
    return api.tooltip_text(env)
end

T.test("Prices: LG data adds market and vendor lines, with stack totals", function()
    local env = T.addon("Prices", { bags = BAGS })
    api.server_packet(env, "LG", "2589,1500,13,42;4306,0,150,0;junk")
    local tip = tipFor(env, 0, 1)
    T.has(tip, "Linen Cloth")
    T.has(tip, "Pricing")
    T.has(tip, "Market (7d) x42  =  15s 0c  (3g 0s 0c)")
    T.has(tip, "Vendor  =  13c  (2s 60c)")
    tip = tipFor(env, 0, 2)
    T.lacks(tip, "Market", "median 0 means no market price")
    T.has(tip, "Vendor  =  1s 50c")
    T.lacks(tip, "(", "a single item has no stack total")
end)

T.test("Prices: settings hide lines; a disabled Ledger adds nothing", function()
    local env = T.addon("Prices", { bags = BAGS })
    api.server_packet(env, "LG", "2589,1500,13,42")
    env.ClassicPlus_Manager:SetSetting("Prices", "showSamples", false)
    env.ClassicPlus_Manager:SetSetting("Prices", "showVendor", false)
    local tip = tipFor(env)
    T.has(tip, "Market (7d)  =  15s 0c")
    T.lacks(tip, "Vendor")
    env.WenillaCore:SetAddonEnabled("Prices", false)
    T.lacks(tipFor(env), "Pricing")
end)

T.test("Prices: auction pages you browse are remembered (median of the last 7 days)", function()
    local env = T.addon("Prices", { bags = BAGS })
    api.browse_auctions(env, {
        { id = 4306, count = 1, buyout = 1000, owner = "Ann" },
        { id = 4306, count = 2, buyout = 6000, owner = "Bob" },     -- 3000 each
        { id = 4306, count = 1, buyout = 2000, owner = "Cid" },
        { id = 4306, count = 1, buyout = 0, owner = "Dan" },        -- bid only: ignored
    })
    T.has(tipFor(env, 0, 2), "Auction (seen) x3  =  20s 0c")
    api.browse_auctions(env, { { id = 4306, count = 1, buyout = 1000, owner = "Ann" } })   -- same page again
    T.has(tipFor(env, 0, 2), "x3", "the same seller and price within the hour counts once")
    api.browse_auctions(env, { { id = 4306, count = 1, buyout = 4000, owner = "Eve" } })
    T.has(tipFor(env, 0, 2), "Auction (seen) x4  =  25s 0c", "even count: mean of the middle two")
    env.__bus.epoch = env.__bus.epoch + 8 * 86400
    T.lacks(tipFor(env, 0, 2), "Auction (seen)", "samples older than a week are ignored")
    env.__slash("/ledger")
    T.has(api.chat_text(env), "Prices: 1 item price remembered from the auction house. Browse the auction house to add more.")
end)

T.test("Prices: server prices win over seen auctions; unknown items are asked for once", function()
    local env = T.addon("Prices", { bags = BAGS })
    api.browse_auctions(env, { { id = 2589, count = 1, buyout = 999, owner = "Ann" } })
    api.connect(env)
    api.server_packet(env, "LG", "2589,1500,13,42")
    T.has(tipFor(env, 0, 1), "Market (7d)")
    tipFor(env, 0, 3)
    tipFor(env, 0, 3)
    local asks = 0
    for _, l in ipairs(env.__wnl) do if l == "lg 2770" then asks = asks + 1 end end
    T.eq(asks, 1, "asked once for Copper Ore")
    env.__slash("/prices")
    T.has(api.chat_text(env), "plus server market data")
end)

T.test("Prices: hyperlinks, merchant items and loot get prices too", function()
    local env = T.addon("Prices", { bags = BAGS })
    api.server_packet(env, "LG", "4306,2000,150,9")
    env.GameTooltip:SetOwner(env.UIParent)
    env.GameTooltip:SetHyperlink("item:4306:0:0:0")
    T.has(api.tooltip_text(env), "Market (7d) x9  =  20s 0c")
    api.open_merchant(env, { items = { { id = 4306, price = 600 } } })
    env.GameTooltip:SetMerchantItem(1)
    T.has(api.tooltip_text(env), "Vendor  =  1s 50c")
    env.__loot = { { id = 4306, count = 3 } }
    env.GameTooltip:SetLootItem(1)
    T.has(api.tooltip_text(env), "(60s 0c)", "loot stack total")
end)

T.test("Prices: vendor prices without a server, for one and for the stack (shipped data)", function()
    local env = T.addon("Prices", { bags = BAGS })
    local tip = tipFor(env, 0, 1)
    T.has(tip, "Pricing")
    T.has(tip, "Vendor  =  13c  (2s 60c)", "20 Linen Cloth: 13c each, 2s 60c the stack")
    T.lacks(tip, "Market")
    T.has(tipFor(env, 0, 2), "Vendor  =  1s 50c")
    T.lacks(tipFor(env, 0, 2), "(", "one item: no stack total")
    T.has(tipFor(env, 0, 3), "Vendor  =  5c  (25c)")
    T.eq(env.Ledger:Vendor(19019), 123140, "Thunderfury from the shipped table (12g 31s 40c)")
    T.eq(select(2, env.Ledger:Vendor(2589)), "shipped")
    T.eq(env.Ledger:Vendor(6948), nil, "the Hearthstone cannot be sold")
    env.ClassicPlus_Manager:SetSetting("Prices", "showVendor", false)
    T.lacks(tipFor(env, 0, 1), "Pricing", "vendor line off and no market data: nothing")
end)

T.test("Prices: realm-custom items learn their price from the merchant's buyback list", function()
    local custom = { [90001] = { name = "Gilneas Trinket", quality = 1, icon = "Interface\\Icons\\INV_Misc_Gem_01", sell = 275, stack = 10 } }
    local bags = { [0] = { size = 16, items = { { 90001, 4 }, { 90001, 1 } } } }
    local env = T.addon("Prices", { bags = bags, items = custom })
    T.lacks(tipFor(env, 0, 2), "Vendor", "unknown at first")
    api.open_merchant(env, { items = {} })
    env.UseContainerItem(0, 1)                -- sell the stack of 4
    api.pump(env)
    T.eq(env.Ledger:Vendor(90001), 275)
    T.eq(select(2, env.Ledger:Vendor(90001)), "learned")
    api.close_merchant(env)
    T.has(tipFor(env, 0, 2), "Vendor  =  2s 75c")
    local again = T.relog(env)
    T.eq(again.Ledger:Vendor(90001), 275, "remembered across sessions")
    api.server_packet(again, "LG", "90001,0,300,0")
    T.eq(again.Ledger:Vendor(90001), 300, "the server's number wins")
end)

T.test("Prices: a known vendor price still asks the server once for market data", function()
    local env = T.addon("Prices", { bags = BAGS })
    api.connect(env)
    tipFor(env, 0, 1)
    tipFor(env, 0, 1)
    local asks = 0
    for _, l in ipairs(env.__wnl) do if l == "lg 2589" then asks = asks + 1 end end
    T.eq(asks, 1)
end)
