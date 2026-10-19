-- Bags gear sets: save what you wear, swap with one click (bags and slot-to-slot), combat waits,
-- missing items, the two-hander bag-space check, the panel, icons and /gear.
local T, api = ...

-- Tank: Lionheart Helm, Band of Accuria in 11, Quick Strike Ring in 12, Empyrean Demolisher +
-- Elementium Bulwark. In the bags: the DPS pieces and a fishing kit.
local EQUIPPED = { [1] = 12640, [11] = 17063, [12] = 18821, [16] = 17112, [17] = 19349, [18] = 12651 }
local BAGS = { [0] = { size = 16, items = { { 16866, 1 }, { 19364, 1 }, { 6256, 1 }, { 19972, 1 }, { 2589, 20 } } } }

local function geared(opts)
    opts = opts or {}
    opts.latency = false
    opts.equipped = opts.equipped or EQUIPPED
    opts.bags = opts.bags or BAGS
    return T.addon("Bags", opts)
end

local function settle(env) api.tick(env, 3, 0.05) end

local function worn(env, slot) return env.__inventory[slot] end

T.test("Gear: save what you wear, swap to another set and back", function()
    local env = geared()
    local G = env.Vault.Gear
    env.__slash("/gear save Tank")
    T.has(api.chat_text(env), "Gear: Saved Tank (6 items).")
    -- put on the DPS pieces by hand, save them
    env.PickupContainerItem(0, 1); env.EquipCursorItem(1)          -- Helm of Might
    env.PickupContainerItem(0, 2); env.EquipCursorItem(16)         -- Ashkandi (pushes the shield to the bags)
    T.eq(worn(env, 17), nil, "two-hander took the off hand")
    env.__slash("/gear save DPS")
    T.eq(#G:Sets(), 2)
    env.__slash("/gear tank")
    settle(env)
    T.eq(worn(env, 1), 12640, "helm back")
    T.eq(worn(env, 16), 17112, "one-hander back")
    T.eq(worn(env, 17), 19349, "shield back from the bags")
    T.has(api.chat_text(env), "Equipped Tank.")
    T.ok(G:IsWorn(G:Find("Tank")))
    env.__slash("/gear dps")
    settle(env)
    T.eq(worn(env, 16), 19364)
    T.eq(worn(env, 1), 16866)
    T.has(api.chat_text(env), "Equipped DPS.")
    env.__slash("/gear DPS")
    T.has(api.chat_text(env), "You're already wearing DPS.")
end)

T.test("Gear: rings swap places between slots without the bags", function()
    local env = geared()
    local G = env.Vault.Gear
    G:Save("Rings", true)
    local set = G:Find("Rings")
    set.items[11], set.items[12] = set.items[12], set.items[11]     -- the set wants them swapped
    G:Equip("Rings")
    settle(env)
    T.eq(worn(env, 11), 18821)
    T.eq(worn(env, 12), 17063)
    for _, m in ipairs(env.__equip_moves) do T.no(m[1] == "unequip", "nothing went through the bags") end
end)

T.test("Gear: a swap asked for in combat happens when combat ends", function()
    local env = geared()
    env.__slash("/gear save Tank")
    env.PickupContainerItem(0, 1); env.EquipCursorItem(1)
    api.set_combat(env, true)
    env.__slash("/gear Tank")
    T.has(api.chat_text(env), "goes on when the fight ends")
    settle(env)
    T.eq(worn(env, 1), 16866, "nothing moves in combat")
    api.set_combat(env, false)
    settle(env)
    T.eq(worn(env, 1), 12640, "swapped after combat")
end)

T.test("Gear: items that aren't in the bags are named; others still go on", function()
    local env = geared()
    env.__slash("/gear save Tank")
    env.PickupContainerItem(0, 1); env.EquipCursorItem(1)           -- Helm of Might on, Lionheart into the bags
    -- the Lionheart Helm goes to the bank
    for slot, it in pairs(env.__bags[0].items) do if it.id == 12640 then env.__bags[0].items[slot] = nil end end
    env.PickupInventoryItem(11); env.PickupContainerItem(0, 9)      -- a ring off into the bags
    env.__slash("/gear Tank")
    settle(env)
    T.eq(worn(env, 11), 17063, "the ring came back")
    T.has(api.chat_text(env), "Equipped Tank, except Lionheart Helm (not in your bags).")
end)

T.test("Gear: a two-hander needs a free bag slot for the off hand", function()
    local items = {}
    for i = 1, 16 do items[i] = { 6948, 1 } end
    items[1] = { 19364, 1 }
    local env = geared({ bags = { [0] = { size = 16, items = items } } })
    local G = env.Vault.Gear
    G:Save("Shield", true)
    -- a set with only the greatsword
    table.insert(G:Sets(), { name = "Big Sword", items = { [16] = "item:19364:0:0:0" } })
    env.__slash("/gear big sword")
    settle(env)
    T.eq(worn(env, 16), 17112, "nothing changed")
    T.has(api.chat_text(env), "a two-hander needs one free bag slot")
end)

T.test("Gear: the panel from the Bags window lists sets; click swaps, right-click menu", function()
    local env = geared()
    local G = env.Vault.Gear
    env.__slash("/bags")
    T.shown(env.Bags_GearButton)
    api.click(env.Bags_GearButton)
    T.shown(env.Bags_GearPanel)
    T.ok(api.screen_has(env, "No sets yet", env.Bags_GearPanel))
    api.click_text(env, "Save what I'm wearing", env.Bags_GearPanel)
    api.type(env.WenillaCore_PromptEdit, "Tank")
    api.press_enter(env.WenillaCore_PromptEdit)
    T.ok(api.screen_has(env, "Tank", env.Bags_GearPanel))
    T.ok(api.screen_has(env, "Wearing it", env.Bags_GearPanel))
    env.PickupContainerItem(0, 1); env.EquipCursorItem(1)
    api.tick(env, 0.2)
    T.ok(api.screen_has(env, "6 items", env.Bags_GearPanel))
    T.no(api.screen_has(env, "Wearing it", env.Bags_GearPanel), "not worn any more")
    api.enter(env.Bags_GearRow1)
    T.has(api.tooltip_text(env), "Lionheart Helm")
    api.click(env.Bags_GearRow1)
    settle(env)
    T.eq(worn(env, 1), 12640, "click puts it on")
    T.ok(api.screen_has(env, "Wearing it", env.Bags_GearPanel))
    -- right-click: rename, icon, delete
    api.click(env.Bags_GearRow1, "RightButton")
    api.click_text(env, "Rename", env.WenillaCore_Menu)
    api.type(env.WenillaCore_PromptEdit, "Prot")
    api.press_enter(env.WenillaCore_PromptEdit)
    T.eq(G:Sets()[1].name, "Prot")
    api.click(env.Bags_GearRow1, "RightButton")
    api.click_text(env, "Change icon", env.WenillaCore_Menu)
    T.shown(env.Bags_GearIcons)
    T.eq(env.Bags_GearIcon1.box.icon:GetTexture(), "Interface\\Icons\\INV_Helmet_36", "the set's own items first")
    api.click(env.Bags_GearIcon3)
    T.eq(G:Sets()[1].icon, env.Bags_GearIcon3.tex)
    T.eq(env.Bags_GearRow1.box.icon:GetTexture(), G:Sets()[1].icon)
    api.click(env.Bags_GearRow1, "RightButton")
    api.click_text(env, "Delete", env.WenillaCore_Menu)
    T.eq(#G:Sets(), 0)
end)

T.test("Gear: the character window has a button too; the setting turns it all off", function()
    local env = geared()
    env.ToggleCharacter()
    T.shown(env.Bags_GearCharButton)
    api.click(env.Bags_GearCharButton)
    T.shown(env.Bags_GearPanel)
    env.ClassicPlus_Manager:SetSetting("Bags", "gearSets", false)
    T.hidden(env.Bags_GearPanel)
    T.hidden(env.Bags_GearCharButton)
    env.__slash("/gear save Tank")
    T.lacks(api.chat_text(env), "Saved Tank")
    env.ClassicPlus_Manager:SetSetting("Bags", "gearSets", true)
    T.shown(env.Bags_GearCharButton)
end)

T.test("Gear: sets are per character and survive a relog; /gear list and delete", function()
    local env = geared()
    env.__slash("/gear save Tank")
    env.__slash("/gear save Fishing")
    local again = T.relog(env)
    again.__slash("/gear list")
    T.has(api.chat_text(again), "Your sets: Tank, Fishing.")
    again.__slash("/gear delete fish")
    T.has(api.chat_text(again), "Deleted Fishing.")
    again.__slash("/gear nothing")
    T.has(api.chat_text(again), "No gear set called \"nothing\"")
    local alt = T.addon("Bags", { name = "Ilyndra" })
    alt.__slash("/gear list")
    T.has(api.chat_text(alt), "No gear sets yet")
end)

T.test("Gear: generated button art, and stock icons without it", function()
    local env = geared()
    T.has(env.Bags_GearButton.icon:GetTexture(), "Bags_GearSets")
    local plain = T.addon("Bags", { name = "Ilyndra", art = false })
    T.eq(plain.Bags_GearButton.icon:GetTexture(), "Interface\\Icons\\INV_Chest_Plate06")
end)

T.test("Gear: the panel closes with the window it was opened from; /gear alone opens it", function()
    local env = geared()
    env.__slash("/bags")
    api.click(env.Bags_GearButton)
    T.shown(env.Bags_GearPanel)
    env.__slash("/bags")
    api.tick(env, 0.1)
    T.hidden(env.Bags_GearPanel, "closed with the bags")
    env.__slash("/gear")
    T.shown(env.Bags_GearPanel, "/gear opens it on its own")
    api.tick(env, 0.1)
    T.shown(env.Bags_GearPanel, "and it stays")
    env.__slash("/gear")
    T.hidden(env.Bags_GearPanel)
end)
