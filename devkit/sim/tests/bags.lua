-- Bags (Vault): one bag window, search, remembered bank, VT snapshots.
local T, api = ...

local BAGS = { [0] = { size = 16, items = { { 2589, 20 }, { 4306, 3 }, { 7073, 2 } } },
    [-1] = { size = 24, items = { [1] = { 2770, 10 }, [5] = { 1203, 1 } } } }

local function vault(opts)
    opts = opts or {}
    opts.bags = opts.bags or BAGS
    return T.addon("Bags", opts)
end

T.test("Bags: /bags opens one window with every slot, coins and a used count", function()
    local env = vault({ money = 123456 })
    env.__slash("/bags")
    T.shown(env.Vault_Frame)
    T.ok(api.screen_has(env, "3/16 used", env.Vault_Frame))
    T.ok(env.Vault_Slot16:IsShown(), "16 slots")
    T.eq(env.Vault_Slot17, nil, "no bank slots while away from the bank")
    T.eq(env.Vault_Slot1.icon:GetTexture(), "Interface\\Icons\\INV_Fabric_Linen_01")
    T.ok(api.screen_has(env, "20", env.Vault_Slot1), "stack count")
    local texts = table.concat(api.visible_texts(env, env.Vault_Frame), " ")
    T.has(texts, "56 34 12", "copper, silver, gold (right to left)")
    api.enter(env.Vault_Slot2)
    T.has(api.tooltip_text(env), "Silk Cloth")
    env.__slash("/vault")
    T.hidden(env.Vault_Frame)
end)

T.test("Bags: search dims everything that does not match", function()
    local env = vault()
    env.__slash("/bags")
    api.type(env.Vault_Search, "LINEN")
    T.eq(env.Vault_Slot1:GetAlpha(), 1)
    T.eq(env.Vault_Slot2:GetAlpha(), 0.22)
    T.eq(env.Vault_Slot4:GetAlpha(), 1, "empty slots are not dimmed")
    api.type(env.Vault_Search, "")
    T.eq(env.Vault_Slot2:GetAlpha(), 1)
end)

T.test("Bags: the bank is shown live at a banker and remembered afterwards", function()
    local env = vault()
    api.open_bank(env)
    T.shown(env.Vault_Frame, "a banker opens the Vault")
    api.tick(env, 0.1)
    T.ok(env.Vault_Slot40:IsShown(), "16 bag + 24 bank slots")
    T.eq(env.Vault_Slot17.icon:GetTexture(), "Interface\\Icons\\INV_Ore_Copper_01")
    T.ok(api.screen_has(env, "Bank", env.Vault_Frame))
    api.close_bank(env)
    env.__slash("/bags")
    T.hidden(env.Vault_Frame)
    env.__bags[-1] = { size = 0, items = {} }            -- away from the bank: no live bank data
    env.__slash("/bags bank")
    T.shown(env.Vault_Frame)
    T.ok(api.screen_has(env, "Bank  last seen", env.Vault_Frame), "remembered bank label")
    T.eq(env.Vault_Slot17.icon:GetTexture(), "Interface\\Icons\\INV_Ore_Copper_01", "remembered item")
    api.enter(env.Vault_Slot21)
    T.has(api.tooltip_text(env), "Aegis of Stormwind", "remembered item tooltip")
    T.ok(env.Vault_Slot21.border:IsShown(), "rare quality border")
    -- the snapshot belongs to this character only
    local snap = env.WenillaCore_Config.bank["Herald-Open Vanilla"]
    T.eq(table.getn(snap.items), 24)
end)

T.test("Bags: a VT snapshot replaces the remembered bank", function()
    local env = vault()
    api.server_packet(env, "VT", "2589,20,1,INV_Fabric_Linen_01;0;4306,5,4,INV_Fabric_Silk_01")
    env.__slash("/bags bank")
    T.eq(env.Vault_Slot17.icon:GetTexture(), "Interface\\Icons\\INV_Fabric_Linen_01")
    T.no(env.Vault_Slot18.icon:IsShown(), "id 0 is an empty slot")
    T.ok(env.Vault_Slot19.border:IsShown(), "epic border")
    T.ok(api.screen_has(env, "5", env.Vault_Slot19))
    T.eq(env.Vault_Slot20, nil, "three slots, as sent")
end)

T.test("Bags: an empty remembered bank slot has no tooltip", function()
        local env = vault()
        api.server_packet(env, "VT", "2589,1,1,INV_Fabric_Linen_01")
        env.__slash("/bags bank")
        api.enter(env.Vault_Slot17)
        T.has(api.tooltip_text(env), "Linen Cloth")
        api.server_packet(env, "VT", "0;0")
        api.tick(env, 0.1)
        T.no(env.Vault_Slot17.icon:IsShown(), "slot 17 is empty now")
        env.GameTooltip:Hide()
        api.enter(env.Vault_Slot17)
        T.lacks(api.tooltip_text(env), "Linen Cloth", "the empty slot shows the item that used to be there")
    end)

T.test("Bags: B key and bag buttons open the Vault; replaceBags off gives them back", function()
    local env = vault()
    env.ToggleBackpack()
    T.shown(env.Vault_Frame)
    env.CloseAllBags()
    T.hidden(env.Vault_Frame)
    env.OpenAllBags()
    T.shown(env.Vault_Frame)
    T.ok(api.press_escape(env), "Escape closes it")
    env.ToggleBag(6)
    T.eq(env.__stock_bags, "ToggleBag", "bank bags still use the stock frames")
    env.ClassicPlus_Manager:SetSetting("Bags", "replaceBags", false)
    env.__stock_bags = nil
    env.ToggleBackpack()
    T.hidden(env.Vault_Frame)
    T.eq(env.__stock_bags, "ToggleBackpack")
end)

T.test("Bags: search finds items in a server (VT) bank snapshot", function()
        local env = vault()
        api.server_packet(env, "VT", "2589,20,1,INV_Fabric_Linen_01;4306,5,1,INV_Fabric_Silk_01")
        env.__slash("/bags bank")
        api.type(env.Vault_Search, "linen")
        T.eq(env.Vault_Slot1:GetAlpha(), 1, "bag linen matches")
        T.eq(env.Vault_Slot17:GetAlpha(), 1, "bank linen matches")
    end)

T.test("Bags: lanes - bags, pouches by bag family, and openable items in a 'To open' lane", function()
    local env = vault({ bags = {
        [0] = { size = 16, items = { { 2589, 20 }, { 90100, 1 }, { 4632, 1 }, { 5523, 1 } } },
        [1] = { size = 12, items = { { 2447, 5 } } },
        [2] = { size = 8, items = {} },
        [3] = { size = 4, items = {} },
        [4] = { size = 6, items = {} },
    } })
    api.add_item(env, 90100, { name = "Star Pouch", quality = 2, icon = "Interface\\Icons\\INV_Misc_Bag_17", type = "Miscellaneous" })
    api.add_item(env, 4632, { name = "Ornate Bronze Lockbox", quality = 1, icon = "Interface\\Icons\\INV_Box_01", type = "Miscellaneous", lines = { "Locked" } })
    api.add_item(env, 5523, { name = "Small Barnacled Clam", quality = 1, icon = "Interface\\Icons\\INV_Misc_Shell_02", type = "Miscellaneous", lines = { "<Right Click to Open>" } })
    api.add_item(env, 2447, { name = "Peacebloom", quality = 1, icon = "Interface\\Icons\\INV_Misc_Flower_02", type = "Trade Goods" })
    api.add_item(env, 22250, { name = "Herb Pouch", quality = 1, icon = "Interface\\Icons\\INV_Misc_Bag_10", type = "Container", subType = "Herb Bag" })
    api.add_item(env, 2101, { name = "Light Quiver", quality = 1, icon = "Interface\\Icons\\INV_Misc_Quiver_01", type = "Quiver", subType = "Quiver" })
    api.add_item(env, 21340, { name = "Soul Pouch", quality = 2, icon = "Interface\\Icons\\INV_Misc_Bag_EnchantedRunecloth", type = "Container", subType = "Soul Bag" })
    api.add_item(env, 4496, { name = "Small Brown Pouch", quality = 1, icon = "Interface\\Icons\\INV_Misc_Bag_10", type = "Container", subType = "Bag" })
    api.equip(env, 20, 22250)
    api.equip(env, 21, 2101)
    api.equip(env, 22, 21340)
    api.equip(env, 23, 4496)
    local V = env.Vault
    T.eq(V.Family("Container", "Herb Bag", "Herb Pouch"), "reagent")
    T.eq(V.Family("Quiver", "Ammo Pouch", "Small Ammo Pouch"), "ammo")
    T.eq(V.Family(nil, nil, "Heavy Quiver"), "ammo", "by name when the item cache has nothing")
    T.eq(V.Family("Container", "Soul Bag", "Felcloth Bag"), "soul")
    T.eq(V.Family("Container", "Bag", "Small Brown Pouch"), "bags")
    env.__slash("/bags")
    T.shown(env.Vault_Frame)
    local lanes = V.lanes
    T.eq(table.getn(lanes.open), 3, "Star Pouch, lockbox and clam")
    T.eq(lanes.open[1][2], 2, "the Star Pouch's slot")
    T.eq(table.getn(lanes.bags), 16 - 3 + 6, "backpack minus the openables, plus the plain bag")
    T.eq(table.getn(lanes.reagent), 12)
    T.eq(table.getn(lanes.ammo), 8)
    T.eq(table.getn(lanes.soul), 4)
    T.eq(env.Vault_Slot1.icon:GetTexture(), "Interface\\Icons\\INV_Fabric_Linen_01", "the Bags lane comes first")
    for _, k in ipairs({ "bags", "open", "reagent", "ammo", "soul" }) do
        T.shown(V.laneParts[k].label, k .. " label")
        T.shown(V.laneParts[k].bar, k .. " border")
    end
    T.has(V.laneParts.open.label:GetText(), "To open")
    T.has(V.laneParts.reagent.label:GetText(), "Reagent pouch")
    T.has(V.laneParts.reagent.label:GetText(), "1/12", "used/size for a pouch")
    T.has(V.laneParts.ammo.label:GetText(), "Ammo & quiver")
    T.ok(api.screen_has(env, "5/46 used", env.Vault_Frame), "the used count still covers every bag")
    -- right-clicking an item in the To open lane uses the real bag slot
    local lockbox
    for i = 1, V.used do
        local b = V.slots[i]
        if b.bag == 0 and b.slot == 3 then lockbox = b end
    end
    T.ok(lockbox, "the lockbox has a button")
    api.click(lockbox, "RightButton")
    T.eq(env.__used_items[1][3], 4632)
end)

T.test("Bags: no pouches and nothing to open shows just the Bags lane", function()
    local env = vault()
    env.__slash("/bags")
    T.shown(env.Vault.laneParts.bags.label)
    for _, k in ipairs({ "open", "reagent", "ammo", "soul" }) do
        T.ok(not env.Vault.laneParts[k] or not env.Vault.laneParts[k].label:IsShown(), k .. " lane hidden")
    end
end)

T.test("Bags: the stock window look in every skin, with the lanes kept", function()
    local env = T.addon("Bags")
    local f = env.Vault_Frame
    local function check(skin)
        local p, rel, rp = f.title:GetPoint(1)
        T.eq(p .. " " .. rp, "TOP TOP", skin .. ": the title sits in the top edge")
        T.eq(rel, f)
        T.ok(not f.header or not f.header:IsShown(), skin .. ": no plaque above the window")
        T.has(f:GetBackdrop().edgeFile, "UI-DialogBox-Border", skin .. ": the stock dialog border")
        local r, g, b = f.title:GetTextColor()
        T.near(r, 1, 1e-6); T.near(g, 0.82, 1e-6, skin .. ": gold title")
        local cp = f.closeButton:GetPoint(1)
        T.eq(cp, "TOPRIGHT", skin .. ": the red X in the corner")
    end
    check("default")
    for _, key in ipairs({ "classic", "brass", "slick" }) do
        if env.WenillaCore.UI.SetSkin then env.WenillaCore.UI.SetSkin(key) elseif env.WenillaCore.UI.ApplySkin then env.WenillaCore.UI.ApplySkin() end
        check(key)
    end
end)
