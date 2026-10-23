-- Shots of the Duels realm's Armory window (Data/Interface/AddOns/Duels/Armory.lua) after the 2026-10-23
-- build-out: a level 60 Warrior in Field Marshal's plate, the Head slot picked, Battlegear of Wrath chosen.
local S, api = ...
local T = S.T

local ITEMS = {
    -- id, name, quality, icon, equip slot, tooltip lines
    { 16478, "Field Marshal's Plate Helm", 4, "INV_Helmet_05", "INVTYPE_HEAD", { "Head", "706 Armor", "+28 Stamina", "+18 Strength" } },
    { 16480, "Field Marshal's Plate Shoulderguards", 4, "INV_Shoulder_29", "INVTYPE_SHOULDER", { "Shoulder", "642 Armor", "+20 Stamina", "+14 Strength" } },
    { 16477, "Field Marshal's Plate Armor", 4, "INV_Chest_Plate03", "INVTYPE_CHEST", { "Chest", "856 Armor", "+28 Stamina", "+18 Strength" } },
    { 16963, "Helm of Wrath", 4, "INV_Helmet_71", "INVTYPE_HEAD", { "Head", "740 Armor", "+40 Stamina", "+17 Strength" } },
    { 16961, "Pauldrons of Wrath", 4, "INV_Shoulder_34", "INVTYPE_SHOULDER", { "Shoulder", "666 Armor", "+27 Stamina", "+13 Strength" } },
    { 16966, "Breastplate of Wrath", 4, "INV_Chest_Plate16", "INVTYPE_CHEST", { "Chest", "910 Armor", "+40 Stamina", "+20 Strength" } },
    { 16960, "Waistband of Wrath", 4, "INV_Belt_09", "INVTYPE_WAIST", { "Waist", "499 Armor", "+27 Stamina", "+20 Strength" } },
    { 16866, "Helm of Might", 4, "INV_Helmet_09", "INVTYPE_HEAD", { "Head", "651 Armor", "+23 Stamina", "+15 Strength" } },
    { 21329, "Conqueror's Crown", 4, "INV_Crown_01", "INVTYPE_HEAD", { "Head", "771 Armor", "+29 Stamina", "+29 Strength" } },
    { 22418, "Dreadnaught Helmet", 4, "INV_Helmet_58", "INVTYPE_HEAD", { "Head", "810 Armor", "+43 Stamina", "+21 Strength" } },
    { 18817, "Crown of Destruction", 4, "INV_Crown_02", "INVTYPE_HEAD", { "Head", "571 Armor", "+23 Agility" } },
    { 19372, "Helm of Endless Rage", 4, "INV_Helmet_58", "INVTYPE_HEAD", { "Head", "868 Armor", "+26 Stamina", "+26 Strength" } },
    { 12640, "Lionheart Helm", 4, "INV_Helmet_36", "INVTYPE_HEAD", { "Head", "565 Armor", "+18 Strength" } },
    { 19364, "Ashkandi, Greatsword of the Brotherhood", 4, "INV_Sword_50", "INVTYPE_2HWEAPON", { "Two-Hand", "+33 Stamina" } },
}

S.shot("armory_gear", function()
    local env = T.addon("Duels", { latency = false, class = "WARRIOR", faction = "Alliance", name = "Kaelix" })
    for _, it in ipairs(ITEMS) do
        api.add_item(env, it[1], { name = it[2], quality = it[3], icon = "Interface\\Icons\\" .. it[4], equip = it[5], lines = it[6] })
    end
    env.__inventory[1] = 16478
    env.__inventory[3] = 16480
    env.__inventory[5] = 16477
    env.__inventory[16] = 19364
    api.connect(env)
    api.tick(env, 1)
    api.server_packet(env, "WF", "1,2,0,0,1,1")
    env.ClassicPlusTalents = { specs = { active = 1, count = 3 },
        SpecName = function(i) return ({ "Arms", "Fury", "Protection" })[i] end, Switch = function() end }
    local A = env.Duels.Armory
    A.Toggle()
    A.Pick(0)
    api.server_packet(env, "WP", "0;16478,0;16963,0;16866,0;21329,2;22418,3;18817,0;19372,0;12640,0")
    A.SetsTab("tier")
    local sets = A.TierSets()
    A.SelectEntry(sets[4])
    A.pick = { id = 16963, tier = 0 }
    env.DuelsArmoryList:Refresh()
    return env, env.DuelsArmoryFrame
end)

S.shot("armory_talents", function()
    local env = T.addon("Duels", { latency = false, class = "WARRIOR", faction = "Alliance", name = "Kaelix" })
    for _, it in ipairs(ITEMS) do
        api.add_item(env, it[1], { name = it[2], quality = it[3], icon = "Interface\\Icons\\" .. it[4], equip = it[5], lines = it[6] })
    end
    env.__inventory[1] = 16478
    api.connect(env)
    api.tick(env, 1)
    api.server_packet(env, "WF", "1,2,0,0,1,1")
    env.ClassicPlusTalents = { specs = { active = 1, count = 3 },
        SpecName = function(i) return ({ "Arms", "Fury", "Protection" })[i] end, Switch = function() end }
    table.insert(env.DuelsLoadouts, { name = "Kaelix raid", code = "OV1-CPU-0-0-0-0-0-0-0-0-0-0-0-0-0-0-0-0" })
    local A = env.Duels.Armory
    A.Toggle()
    A.Select("load")
    return env, env.DuelsArmoryFrame
end)
