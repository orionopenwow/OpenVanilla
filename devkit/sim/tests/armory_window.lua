-- The Duels realm's Armory window (Data/Interface/AddOns/Duels/Armory.lua, ArmoryData.lua): the three-panel
-- layout of 2026-10-23 (the doll, the gear picker with sources, Sets & Talent Builds with a model and stats)
-- and the icon fix (GetItemInfo's icon is its 9th answer in 1.12).
local T, api = ...

local function duels(opts)
    opts = opts or {}
    opts.latency = false
    opts.class = opts.class or "WARRIOR"
    opts.faction = opts.faction or "Alliance"
    return T.addon("Duels", opts)
end

local function connect(env, hello)
    api.connect(env)
    api.tick(env, 1)
    if hello then api.server_packet(env, "WF", hello) end
end

local function sent(env) return table.concat(env.__wnl, " | ") end
local function shownRows(list)
    local n = 0
    for _, r in ipairs(list.rows) do if r:IsShown() then n = n + 1 end end
    return n
end

local WRATH = {
    { 16963, "Helm of Wrath", "INVTYPE_HEAD", "Interface\\Icons\\INV_Helmet_71", { "Head", "740 Armor", "+40 Stamina", "+17 Strength" } },
    { 16961, "Pauldrons of Wrath", "INVTYPE_SHOULDER", "Interface\\Icons\\INV_Shoulder_34", { "Shoulder", "666 Armor", "+27 Stamina", "+13 Strength" } },
    { 16966, "Breastplate of Wrath", "INVTYPE_CHEST", "Interface\\Icons\\INV_Chest_Plate16", { "Chest", "910 Armor", "+40 Stamina", "+20 Strength" } },
    { 16960, "Waistband of Wrath", "INVTYPE_WAIST", "Interface\\Icons\\INV_Belt_09", { "Waist", "499 Armor", "+27 Stamina", "+20 Strength" } },
}

local function addWrath(env)
    for _, w in ipairs(WRATH) do
        api.add_item(env, w[1], { name = w[2], quality = 4, icon = w[4], equip = w[3], lines = w[5] })
    end
end

T.test("Armory icons: picker rows show each item's own icon, a question mark until the item is known, no grey boxes before a slot", function()
    local env = duels()
    api.add_item(env, 16963, { name = "Helm of Wrath", quality = 4, icon = "Interface\\Icons\\INV_Helmet_71", equip = "INVTYPE_HEAD" })
    connect(env, "1,2,0,0,1,1")
    local A = env.Duels.Armory
    A.Toggle()
    T.shown(env.DuelsArmoryFrame)
    local list = env.DuelsArmoryList
    T.eq(shownRows(list), 0, "no empty rows (the grey boxes) before a slot is picked")
    T.has(table.concat(api.visible_texts(env, env.DuelsArmoryFrame), " | "), "Pick a slot on the left")
    A.Pick(0)
    T.has(sent(env), "wf pool 0")
    api.server_packet(env, "WP", "0;16963,0;99999,0")
    T.eq(shownRows(list), 2)
    local icons = {}
    for _, r in ipairs(list.rows) do if r:IsShown() then icons[r.item.id] = r.box.icon:GetTexture() end end
    T.eq(icons[16963], "Interface\\Icons\\INV_Helmet_71", "the item's own icon (the 9th answer)")
    T.eq(icons[99999], "Interface\\Icons\\INV_Misc_QuestionMark", "unknown yet: the question mark, never a grey box")
    T.has(table.concat(api.visible_texts(env, env.DuelsArmoryFrame), " | "), "Onyxia's Lair", "where it drops")
end)

T.test("Armory picker: the source filter, choosing an item tries it on and shows the stat change, Wear puts it on", function()
    local env = duels()
    addWrath(env)
    api.add_item(env, 16478, { name = "Field Marshal's Plate Helm", quality = 4, icon = "Interface\\Icons\\INV_Helmet_05", equip = "INVTYPE_HEAD",
        lines = { "Head", "706 Armor", "+28 Stamina", "+18 Strength" } })
    env.__inventory[1] = 16478
    connect(env, "1,2,0,0,1,1")
    local A = env.Duels.Armory
    A.Toggle()
    A.Pick(0)
    api.server_packet(env, "WP", "0;16963,0;16478,0")
    T.eq(table.getn(A.Items()), 2)
    A.SetSource("ONY")
    local items = A.Items()
    T.eq(table.getn(items), 1, "Onyxia's Lair only")
    T.eq(items[1].id, 16963)
    A.SetSource("KIT")
    T.eq(A.Items()[1].id, 16478, "starter kits only")
    A.SetSource("ALL")
    A.Choose({ id = 16963, tier = 0 })
    local tried = api.model_items(env.DuelsArmoryModel)
    T.ok(table.getn(tried) > 0, "the model tries the choice on")
    local stats = table.concat(api.visible_texts(env, env.DuelsArmoryFrame), " | ")
    T.has(stats, "Helm of Wrath")
    T.has(stats, "Sta  40", "the choice's stamina")
    T.has(stats, "+12", "and its change against the worn helm")
    A.Compare()
    T.ok(api.model_dressed(env.DuelsArmoryModel), "Compare: the model shows what you wear")
    A.ApplySelection()
    T.has(sent(env), "wf slot 0 16963", "Apply selection wears the chosen item")
end)

T.test("Armory sets: the class's tier sets T0 to T3, pieces on this realm counted, Apply selection wears what's here and unlocked", function()
    local env = duels()
    addWrath(env)
    connect(env, "1,2,0,0,1,1")
    local A = env.Duels.Armory
    A.Toggle()
    A.SetsTab("tier")
    local sets = A.TierSets()
    T.eq(table.getn(sets), 6, "T0, T0.5, T1, T2, T2.5, T3")
    T.eq(sets[3].label, "T1  Battlegear of Might")
    local wrath = sets[4]
    T.eq(wrath.name, "Battlegear of Wrath")
    T.has(wrath.right, "6/8 here", "6 of its 8 pieces are in the realm's pool")
    T.ok(env.DuelsArmorySets.rows[4]:IsShown(), "the set list is drawn")
    A.SelectEntry(wrath)
    T.ok(table.getn(api.model_items(env.DuelsArmoryModel)) >= 4, "the set is tried on")
    local box = table.concat(api.visible_texts(env, env.DuelsArmoryFrame), " | ")
    T.has(box, "6 of 8 pieces on this realm")
    T.has(box, "From Blackwing Lair")
    A.ApplySelection()
    T.has(sent(env), "wf slot 0 16963", "one slot at a time: the helm first")
    api.server_packet(env, "WS", "ok,0,16963")
    T.has(sent(env), "wf slot 2 16961", "then the shoulders")
    T.ok(not string.find(sent(env), "16966", 1, true), "the breastplate isn't in this realm's pool: skipped")
end)

T.test("Armory talent builds and my sets: listed, the active build marked, applying switches the build or wears the set", function()
    local env = duels({ class = "WARRIOR" })
    connect(env, "1,2,0,0,1,1")
    local switched
    env.ClassicPlusTalents = { specs = { active = 1, count = 3 },
        SpecName = function(i) return ({ "Arms", "Fury", "Protection" })[i] end,
        Switch = function(_, n) switched = n end }
    local A = env.Duels.Armory
    A.Toggle()
    A.SetsTab("spec")
    local builds = A.Builds()
    T.eq(table.getn(builds), 3)
    T.has(builds[1].label, "(active)")
    A.SelectEntry(builds[2])
    A.ApplySelection()
    T.eq(switched, 2, "Apply selection switches to Fury")
    -- my sets
    api.add_item(env, 16963, { name = "Helm of Wrath", quality = 4, icon = "Interface\\Icons\\INV_Helmet_71", equip = "INVTYPE_HEAD" })
    table.insert(env.DuelsLoadouts, { name = "Raid", code = A.Encode({ [0] = 16963 }) })
    A.SetsTab("mine")
    local mine = A.MySets()
    T.eq(mine[1].name, "Raid")
    T.eq(mine[1].icon, "Interface\\Icons\\INV_Helmet_71", "a saved set shows its first piece's icon")
    A.SelectEntry(mine[1])
    A.ApplySelection()
    T.has(sent(env), "wf slot 0 16963")
    -- the third tab lists the builds too
    A.Select("load")
    T.has(table.concat(api.visible_texts(env, env.DuelsArmoryFrame), " | "), "Talent builds")
end)
