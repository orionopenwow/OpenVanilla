--[[
    Data.lua  -  Quests: static tables.

    ZONE_SIZE: each 1.12 zone map's width and height in yards (from WorldMapArea.dbc), so map
    coordinates turn into yards for distances, the arrow and minimap icons.
    ZONE_IDS: AreaTable ids the realm uses in NP / QZ packets.
]]--

local Q = Compass

Q.ZONE_SIZE = {
    -- Eastern Kingdoms
    ["Alterac Mountains"] = { 2800.00, 1866.67 }, ["Arathi Highlands"] = { 3600.00, 2400.00 },
    ["Badlands"] = { 2487.50, 1658.33 }, ["Blasted Lands"] = { 3350.00, 2233.33 },
    ["Burning Steppes"] = { 2929.17, 1952.08 }, ["Deadwind Pass"] = { 2500.00, 1666.67 },
    ["Dun Morogh"] = { 4925.00, 3283.33 }, ["Duskwood"] = { 2700.00, 1800.00 },
    ["Eastern Plaguelands"] = { 4031.25, 2687.50 }, ["Elwynn Forest"] = { 3470.83, 2314.58 },
    ["Hillsbrad Foothills"] = { 3200.00, 2133.33 }, ["Ironforge"] = { 790.63, 527.60 },
    ["Loch Modan"] = { 2758.33, 1839.58 }, ["Redridge Mountains"] = { 2170.83, 1447.92 },
    ["Searing Gorge"] = { 2231.25, 1487.50 }, ["Silverpine Forest"] = { 4200.00, 2800.00 },
    ["Stormwind City"] = { 1344.27, 896.35 }, ["Stranglethorn Vale"] = { 6381.25, 4254.17 },
    ["Swamp of Sorrows"] = { 2293.75, 1529.17 }, ["The Hinterlands"] = { 3850.00, 2566.67 },
    ["Tirisfal Glades"] = { 4518.75, 3012.50 }, ["Undercity"] = { 959.38, 640.10 },
    ["Western Plaguelands"] = { 4300.00, 2866.67 }, ["Westfall"] = { 3500.00, 2333.33 },
    ["Wetlands"] = { 4135.42, 2756.25 },
    -- Kalimdor
    ["Ashenvale"] = { 5766.67, 3843.75 }, ["Azshara"] = { 5070.83, 3381.25 },
    ["Darkshore"] = { 6550.00, 4366.67 }, ["Darnassus"] = { 1058.33, 705.73 },
    ["Desolace"] = { 4495.83, 2997.92 }, ["Durotar"] = { 5287.50, 3525.00 },
    ["Dustwallow Marsh"] = { 5250.00, 3500.00 }, ["Felwood"] = { 5750.00, 3833.33 },
    ["Feralas"] = { 6950.00, 4633.33 }, ["Moonglade"] = { 2308.33, 1539.58 },
    ["Mulgore"] = { 5137.50, 3425.00 }, ["Orgrimmar"] = { 1402.60, 935.42 },
    ["Silithus"] = { 3483.33, 2322.92 }, ["Stonetalon Mountains"] = { 4883.33, 3256.25 },
    ["Tanaris"] = { 6900.00, 4600.00 }, ["Teldrassil"] = { 5091.67, 3393.75 },
    ["The Barrens"] = { 10133.33, 6756.25 }, ["Thousand Needles"] = { 4400.00, 2933.33 },
    ["Thunder Bluff"] = { 1043.75, 695.83 }, ["Un'Goro Crater"] = { 3700.00, 2466.67 },
    ["Winterspring"] = { 7100.00, 4733.33 },
    -- battlegrounds
    ["Alterac Valley"] = { 4237.50, 2825.00 }, ["Warsong Gulch"] = { 1145.83, 764.58 },
    ["Arathi Basin"] = { 1756.25, 1170.83 },
}

Q.ZONE_IDS = {
    [1] = "Dun Morogh", [3] = "Badlands", [4] = "Blasted Lands", [8] = "Swamp of Sorrows",
    [10] = "Duskwood", [11] = "Wetlands", [12] = "Elwynn Forest", [14] = "Durotar",
    [15] = "Dustwallow Marsh", [16] = "Azshara", [17] = "The Barrens", [28] = "Western Plaguelands",
    [33] = "Stranglethorn Vale", [36] = "Alterac Mountains", [38] = "Loch Modan", [40] = "Westfall",
    [41] = "Deadwind Pass", [44] = "Redridge Mountains", [45] = "Arathi Highlands",
    [46] = "Burning Steppes", [47] = "The Hinterlands", [51] = "Searing Gorge",
    [85] = "Tirisfal Glades", [130] = "Silverpine Forest", [139] = "Eastern Plaguelands",
    [141] = "Teldrassil", [148] = "Darkshore", [215] = "Mulgore", [267] = "Hillsbrad Foothills",
    [331] = "Ashenvale", [357] = "Feralas", [361] = "Felwood", [400] = "Thousand Needles",
    [405] = "Desolace", [406] = "Stonetalon Mountains", [440] = "Tanaris", [490] = "Un'Goro Crater",
    [493] = "Moonglade", [618] = "Winterspring", [1377] = "Silithus", [1497] = "Undercity",
    [1519] = "Stormwind City", [1537] = "Ironforge", [1637] = "Orgrimmar", [1638] = "Thunder Bluff",
    [1657] = "Darnassus",
}

-- Minimap view diameter in yards for each zoom step (outdoors, indoors).
Q.MINIMAP_YARDS = { 466.67, 400, 333.33, 266.67, 200, 133.33 }
Q.MINIMAP_YARDS_INSIDE = { 300, 240, 180, 120, 80, 50 }

-- Ring themes: same size and opening, different materials. Wildwood is the default.
Q.RING_THEMES = {
    { key = "wildwood",  label = "Wildwood",        tex = "CompassRing" },
    { key = "stone",     label = "Stone & Leather", tex = "CompassRing_Stone" },
    { key = "ironoak",   label = "Iron & Oak",      tex = "CompassRing_IronOak" },
    { key = "runestone", label = "Runestone",       tex = "CompassRing_Runestone" },
    { key = "bronze",    label = "Dwarven Bronze",  tex = "CompassRing_Bronze" },
}
