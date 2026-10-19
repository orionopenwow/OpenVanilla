-- Shots of the Transmog window (Data/Interface/AddOns/Transmog) in each of its states, for a level
-- 60 Hunter in Ironforge with a typical collection. Realm lines follow Transmog.h (patch 0011).
local S, api = ...
local T = S.T

local ITEMS = {
    -- id, name, quality, icon, equip slot
    { 16465, "Field Marshal's Chain Helm", 4, "INV_Helmet_05", "INVTYPE_HEAD" },
    { 16468, "Field Marshal's Chain Spaulders", 4, "INV_Shoulder_10", "INVTYPE_SHOULDER" },
    { 16466, "Field Marshal's Chain Breastplate", 4, "INV_Chest_Chain_16", "INVTYPE_CHEST" },
    { 16462, "Marshal's Chain Boots", 4, "INV_Boots_Plate_06", "INVTYPE_FEET" },
    { 16941, "Dragonstalker's Greaves", 4, "INV_Boots_Chain_13", "INVTYPE_FEET" },
    { 16849, "Giantstalker's Boots", 4, "INV_Boots_Chain_07", "INVTYPE_FEET" },
    { 16675, "Beaststalker's Boots", 3, "INV_Boots_Chain_09", "INVTYPE_FEET" },
    { 129, "Rugged Trapper's Boots", 1, "INV_Boots_05", "INVTYPE_FEET" },
    { 9625, "Dual Reinforced Leggings", 2, "INV_Pants_03", "INVTYPE_LEGS" },
    { 16467, "Marshal's Chain Legguards", 4, "INV_Pants_Mail_15", "INVTYPE_LEGS" },
    { 16938, "Dragonstalker's Legguards", 4, "INV_Pants_Mail_03", "INVTYPE_LEGS" },
    { 16912, "Netherwind Boots", 4, "INV_Boots_Cloth_05", "INVTYPE_FEET" },
    { 19364, "Ashkandi, Greatsword of the Brotherhood", 4, "INV_Sword_50", "INVTYPE_2HWEAPON" },
    { 19361, "Ashjre'thul, Crossbow of Smiting", 4, "INV_Weapon_Crossbow_10", "INVTYPE_RANGED" },
    { 19436, "Cloak of Draconic Might", 4, "INV_Misc_Cape_08", "INVTYPE_CLOAK" },
    { 148, "Rugged Trapper's Shirt", 1, "INV_Shirt_05", "INVTYPE_BODY" },
    { 16936, "Dragonstalker's Belt", 4, "INV_Belt_28", "INVTYPE_WAIST" },
    { 16935, "Dragonstalker's Bracers", 4, "INV_Bracer_17", "INVTYPE_WRIST" },
    { 16463, "Marshal's Chain Grips", 4, "INV_Gauntlets_10", "INVTYPE_HAND" },
    -- more legs, for a full page of the collection
    { 10410, "Leggings of the Fang", 3, "INV_Pants_06", "INVTYPE_LEGS" },
    { 15057, "Stoneshield Legguards", 2, "INV_Pants_04", "INVTYPE_LEGS" },
    { 18380, "Eldritch Reinforced Legplates", 3, "INV_Pants_Plate_05", "INVTYPE_LEGS" },
    { 13170, "Skyshroud Leggings", 3, "INV_Pants_08", "INVTYPE_LEGS" },
    { 14637, "Cadaverous Leggings", 3, "INV_Pants_Leather_09", "INVTYPE_LEGS" },
    { 16847, "Giantstalker's Leggings", 4, "INV_Pants_Mail_03", "INVTYPE_LEGS" },
    { 19887, "Bloodstained Legplates", 4, "INV_Pants_Plate_17", "INVTYPE_LEGS" },
    { 11821, "Warstrife Leggings", 3, "INV_Pants_Cloth_05", "INVTYPE_LEGS" },
    { 12927, "Truestrike Shoulders", 3, "INV_Pants_Mail_12", "INVTYPE_LEGS" },
    { 9407, "Stoneweaver Leggings", 2, "INV_Pants_Mail_08", "INVTYPE_LEGS" },
    { 15382, "Dragonscale Leggings", 2, "INV_Pants_Mail_14", "INVTYPE_LEGS" },
    { 1979, "Wall of the Dead", 3, "INV_Pants_Mail_04", "INVTYPE_LEGS" },
    { 7718, "Herod's Legguards", 3, "INV_Pants_Mail_07", "INVTYPE_LEGS" },
    { 11926, "Deathdealer Breastplate", 4, "INV_Pants_Mail_16", "INVTYPE_LEGS" },
    { 16091, "Bramblewood Legguards", 2, "INV_Pants_Mail_10", "INVTYPE_LEGS" },
}

local function hunter(opts)
    opts = opts or {}
    opts.latency = false
    opts.class = "HUNTER"
    opts.race = opts.race or "Dwarf"
    local env = T.addon("Transmog", opts)
    if opts.oneRoom then env.OPENVANILLA_ONE_DRESSING_ROOM = 1 end     -- wenilla with patch 0019
    for _, it in ipairs(ITEMS) do
        api.add_item(env, it[1], { name = it[2], quality = it[3], icon = "Interface\\Icons\\" .. it[4], equip = it[5] })
    end
    local worn = { [1] = 16465, [3] = 16468, [4] = 148, [5] = 16466, [6] = 16936, [7] = 16467, [8] = 16462,
                   [9] = 16935, [10] = 16463, [15] = 19436, [16] = 19364, [18] = 19361 }
    for inv, id in pairs(worn) do env.__inventory[inv] = id end
    api.connect(env)
    api.tick(env, 1)
    api.server_packet(env, "TM", opts.hello or "on,3,50,1,20000,0")
    api.server_packet(env, "TM", "outfits;1,Ironforge Brawler,16941,0,0;2,Battleground,19364,16,1;3,Outfit 3,0,0,0")
    local known = {}
    for _, it in ipairs(ITEMS) do table.insert(known, it[1] .. "," .. (30000 + it[1])) end
    api.server_packet(env, "TM", "known;" .. table.concat(known, ";"))
    api.set_unit(env, "npc", { name = "Lyriel Threadweave" })
    api.fire(env, "GOSSIP_SHOW")                 -- at a Transmogrifier
    api.tick(env, 1)
    api.server_packet(env, "TM", "outfit,1;7:16941:0;0:-1:0")
    return env
end

local function cell(env, what)
    for _, c in ipairs(env.Transmog.cells) do
        local e = c.entry
        if e and c:IsVisible() and ((what == "hide" and e.kind == "hide") or e.item == what or
            (type(what) == "table" and e.enchant == what[1])) then
            api.click(c)
            return
        end
    end
    error("no cell for " .. tostring(what))
end

local function feet(env)
    api.click(env.TransmogSlotFeetSlot)
    api.server_packet(env, "TM", "col,7;16462,32095,1;16941,34269,1;16849,34001,1;16675,33002,1;129,30129,1;16912,34044,0")
    api.tick(env, 1)
end

S.shot("transmog_items", function()
    local env = hunter()
    feet(env)
    cell(env, 16849)
    api.tick(env, 1)
    api.server_packet(env, "TM", "cost,1,4120")
    api.tick(env, 1)
    return env, env.TransmogFrame
end)

S.shot("transmog_items_wenilla", function()
    local env = hunter({ oneRoom = true, race = "Human" })
    feet(env)
    cell(env, 16941)
    cell(env, "hide")
    api.click(env.TransmogSlotLegsSlot)
    api.server_packet(env, "TM", "col,6;16467,31467,1;16938,31938,1;9625,29625,1")
    cell(env, 16938)
    api.tick(env, 1)
    api.server_packet(env, "TM", "cost,1,8300")
    api.tick(env, 1)
    return env, env.TransmogFrame
end)

S.shot("transmog_full_page", function()
    local env = hunter({ oneRoom = true })
    api.click(env.TransmogSlotLegsSlot)
    local col = {}
    for _, id in ipairs({ 16467, 16938, 9625, 10410, 15057, 18380, 13170, 14637, 16847, 19887, 11821, 12927, 9407, 15382, 1979, 7718, 11926, 16091 }) do
        table.insert(col, id .. "," .. (40000 + id) .. ",1")
    end
    api.server_packet(env, "TM", "col,6;" .. table.concat(col, ";"))
    cell(env, 16938)
    api.tick(env, 1)
    api.server_packet(env, "TM", "cost,1,8300")
    api.tick(env, 1)
    return env, env.TransmogFrame
end)

S.shot("transmog_empty_slot", function()
    local env = hunter({ race = "Orc" })
    api.click(env.TransmogSlotTabardSlot)
    api.server_packet(env, "TM", "col,18")
    api.tick(env, 1)
    return env, env.TransmogFrame
end)

S.shot("transmog_first_free", function()
    local env = hunter({ hello = "on,2,50,0,10000,1" })
    feet(env)
    cell(env, 16675)
    api.tick(env, 1)
    api.server_packet(env, "TM", "cost,1,0")
    api.tick(env, 1)
    return env, env.TransmogFrame
end)

S.shot("transmog_illusions", function()
    local env = hunter()
    api.click(env.TransmogSlotMainHandSlot)
    api.server_packet(env, "TM", "col,15;19364,34500,1")
    api.click_text(env, "Filter", env.TransmogFrame)
    api.click_text(env, "Illusions", env.WenillaCore_Menu)
    api.server_packet(env, "TM", "ill;1900,103,Crusader;2646,125,Agility +25;1898,98,Lifestealing")
    cell(env, { 1900 })
    api.tick(env, 1)
    api.server_packet(env, "TM", "cost,1,15000")
    api.tick(env, 1)
    return env, env.TransmogFrame
end)

S.shot("transmog_sets", function()
    local env = hunter()
    api.click_text(env, "Sets", env.TransmogFrame)
    api.server_packet(env, "TM", "sets;215,Dragonstalker Armor,3,8,16939/16937/16942/16940/16936/16935/16938/16941;" ..
        "1,Field Marshal's Pursuit,6,6,16465/16468/16466/16462/16463/16467;" ..
        "200,Giantstalker Armor,1,8,16846/16848/16845/16852/16851/16850/16847/16849")
    api.tick(env, 1)
    return env, env.TransmogFrame
end)

S.shot("transmog_custom_sets", function()
    local env = hunter()
    api.click_text(env, "Custom Sets", env.TransmogFrame)
    api.server_packet(env, "TM", "csets;1,Cleaver Kit,15:1292:0/7:129:0;2,Raid night,0:16465:0/7:16941:0/15:19364:1900")
    api.click_text(env, "Raid night", env.TransmogFrame)
    api.tick(env, 1)
    return env, env.TransmogFrame
end)

S.shot("transmog_situations", function()
    local env = hunter()
    api.click_text(env, "Battleground", env.TransmogFrame)
    api.server_packet(env, "TM", "outfit,2;0:-1:0;2:-1:0")
    api.click_text(env, "Situations", env.TransmogFrame)
    api.tick(env, 1)
    return env, env.TransmogFrame
end)

S.shot("transmog_browsing", function()
    local env = hunter()
    env.TransmogFrame:Hide()
    env.__slash("/transmog")                     -- away from a Transmogrifier
    api.tick(env, 1)
    return env, env.TransmogFrame
end)
