-- The menu bar beside the action bar, laid out as modern WoW's (WenillaCore/MicroMenu.lua), its hubs,
-- the Game Menu stack, and the windows it adds (WenillaCore/Journal.lua): Professions,
-- Collections and the Adventure Guide.
local T, api = ...

local MODERN = { "CharacterMicroButton", "OVProfessionsMicroButton", "SpellbookMicroButton", "OVAchievementsMicroButton",
    "QuestLogMicroButton", "SocialsMicroButton", "OVGroupFinderMicroButton", "OVCollectionsMicroButton",
    "OVAdventureGuideMicroButton", "MainMenuMicroButton" }

local function names(list)
    local out = {}
    for _, b in ipairs(list) do table.insert(out, b:GetName()) end
    return table.concat(out, ",")
end

-- x of each visible button's left edge, from the stock Character button's 546 and the chain
-- Each visible button's (left, right) on the bar, checking they're placed on the bar's art frame,
-- in order, never overlapping, with a clear gap, all inside the recess (x 548-1016).
local function xs(env)
    local MM = env.WenillaCore.MicroMenu
    local out, prevR = {}, nil
    for _, b in ipairs(MM:Visible()) do
        local p, rel, rp, x = b:GetPoint(1)
        T.eq(p, "BOTTOMLEFT"); T.eq(rel, env.MainMenuBarArtFrame, b:GetName() .. " on the bar"); T.eq(rp, "BOTTOMLEFT")
        local sc = b:GetScale() or 1
        local L, R = x * sc, x * sc + 28 * sc
        if prevR then T.near(prevR - L, 3 * sc, 1e-6, b:GetName() .. " overlaps the last by the stock 3 px") end
        T.ok(L >= 546 and R <= 806, b:GetName() .. " in the menu recess, clear of the bags")
        table.insert(out, { L, R })
        prevR = R
    end
    return out
end

T.test("Micro menu: the whole suite gets modern WoW's ten buttons in retail's order, clear of the bags", function()
    local env = T.suite({ level = 20, guild = { name = "Lantern" } })
    api.tick(env, 1)
    local MM = env.WenillaCore.MicroMenu
    T.eq(names(MM:Visible()), table.concat(MODERN, ","))
    for _, n in ipairs({ "TalentMicroButton", "WorldMapMicroButton", "HelpMicroButton" }) do
        T.hidden(env[n], n .. " folds into another button")
    end
    T.no(env.ClassicPlusMicroButton, "the old Classic+ fan is gone")
    -- the new buttons are the stock frame with our emblem on it, pressed in like the portrait
    for _, n in ipairs({ "OVProfessionsMicroButton", "OVGroupFinderMicroButton", "OVCollectionsMicroButton" }) do
        local b = env[n]
        T.has(b:GetNormalTexture():GetTexture(), "UI-MicroButtonCharacter-Up", n .. " frame")
        T.has(b:GetPushedTexture():GetTexture(), "UI-MicroButtonCharacter-Down")
        T.has(b.emblem:GetTexture(), "WenillaCore", n .. " emblem art")
    end
    local b = env.OVCollectionsMicroButton
    api.run_script(b, "OnMouseDown")
    local _, _, _, x, y = b.emblem:GetPoint(1)
    T.eq(x, -1); T.eq(y, -2)
    api.run_script(b, "OnMouseUp")
    _, _, _, x, y = b.emblem:GetPoint(1)
    T.eq(x, 0); T.eq(y, 0)
    local x = xs(env)
    T.eq(table.getn(x), 10)
    local MM = env.WenillaCore.MicroMenu
    T.eq(MM.scale, 1, "ten buttons at the stock size")
    T.eq(x[1][1], 546, "starting where the stock Character button does")
    T.eq(x[10][2], 799, "the Game Menu ends at x 799, in the key ring's old slot")
    T.shown(env.OVMicroMenuRecess, "the recess runs on over the key ring's slot")
    -- the bags stay where they are; the key ring is a tab on the backpack
    for _, n in ipairs({ "MainMenuBarBackpackButton", "CharacterBag0Slot", "CharacterBag3Slot" }) do
        T.eq(env[n]:GetParent(), env.MainMenuBarArtFrame, n .. " stays on the bar")
    end
    -- no key ring button; the key ring opens with /keyring and from the Open Vanilla list
    T.hidden(env.KeyRingButton, "no key ring button")
    env.KeyRingButton:Show()
    T.hidden(env.KeyRingButton, "and the client can't bring it back")
    local opened = 0
    env.ToggleKeyRing = function() opened = opened + 1 end
    env.__slash("/keyring")
    T.eq(opened, 1, "/keyring opens it")
    env.GameMenuFrame:Show()
    api.click(env.GameMenuButtonOVTools)
    api.click_text(env, "Key Ring", env.OVToolsFrame)
    T.eq(opened, 2, "the Open Vanilla list's Key Ring row too")
    -- the client re-showing its Talents button (1.12 does at level 10) doesn't undo the bar
    env.UpdateMicroButtons()
    T.hidden(env.TalentMicroButton)
    xs(env)
    -- tooltips name the binding
    env.__bindings.K = "OV_PROFESSIONS"
    api.enter(env.OVProfessionsMicroButton)
    T.has(api.tooltip_text(env, env.GameTooltip), "Professions")
    T.has(api.tooltip_text(env, env.GameTooltip), "(K)")
    api.enter(env.SocialsMicroButton)
    T.has(api.tooltip_text(env, env.GameTooltip), "Guild & Communities")
    api.enter(env.QuestLogMicroButton)
    T.has(api.tooltip_text(env, env.GameTooltip), "Map & Quest Log")
end)

T.test("Micro menu: a feature that's off hides its button and the bar closes up", function()
    local env = T.addon("WenillaCore", { level = 20 })
    api.tick(env, 1)
    local MM = env.WenillaCore.MicroMenu
    T.eq(names(MM:Visible()), "CharacterMicroButton,OVProfessionsMicroButton,SpellbookMicroButton,QuestLogMicroButton,"
        .. "SocialsMicroButton,OVCollectionsMicroButton,MainMenuMicroButton",
        "no Achievements, Group Finder or Adventure Guide without their addons")
    xs(env)
    -- and Achievements switched off in /addons
    local full = T.suite({ level = 20, name = "Second" })
    full.WenillaCore:SetAddonEnabled("Achievements", false)
    api.tick(full, 1)
    T.hidden(full.OVAchievementsMicroButton)
    T.lacks(names(full.WenillaCore.MicroMenu:Visible()), "Achievements")
end)

T.test("Micro menu: Talents & Spellbook opens the spellbook; Game Menu, Character and the map keep their jobs", function()
    local env = T.suite({ level = 20 })
    api.click(env.SpellbookMicroButton)
    T.has(table.concat(env.__toggles, ","), "ToggleSpellBook spell")
    api.click(env.CharacterMicroButton)
    T.shown(env.CharacterFrame, "Character still opens the character sheet")
    api.click(env.MainMenuMicroButton)
    T.shown(env.GameMenuFrame)
end)

T.test("Micro menu: the stock latency bar no longer covers the Game Menu button; its tooltip says the latency", function()
    local env = T.suite({ level = 20 })
    api.tick(env, 1)
    -- the stock bar's hover button (HIGH strata, x 781-797) lay over the Game Menu button (x 771-799)
    -- and took its clicks (player report #12, 2026-10-21)
    local hover = env.MainMenuBarPerformanceBarFrameButton
    T.ok(not hover:IsVisible(), "the latency hover button is gone")
    T.ok(not hover:IsMouseEnabled(), "and takes no mouse")
    env.MainMenuBarPerformanceBarFrame:Show()
    T.ok(not env.MainMenuBarPerformanceBarFrame:IsVisible(), "the client showing it again doesn't bring it back")
    env.GetNetStats = function() return 0, 0, 412 end
    api.enter(env.MainMenuMicroButton)
    local t = table.concat(api.tooltip_lines(env), " | ")
    T.has(t, "Game Menu"); T.has(t, "Latency: 412 ms"); T.has(t, "fps")
    api.click(env.MainMenuMicroButton)
    T.shown(env.GameMenuFrame, "a click opens the Game Menu")
end)

T.test("Micro menu: Guild & Communities is a hub - Guild, Guild Finder, Friends - with shared bottom tabs", function()
    local env = T.suite({ level = 30, guild = { name = "Lantern" } })
    api.click(env.SocialsMicroButton)
    T.shown(env.GuildHub_Frame, "a guild member gets their guild")
    api.tick(env, 1)
    local tabs = api.visible_texts(env, env.OVHubTabs_guild)
    T.has(tabs, "My Guild"); T.has(tabs, "Guild Finder"); T.has(tabs, "Friends")
    env.GuildHub_Frame:ClearAllPoints()
    env.GuildHub_Frame:SetPoint("TOPLEFT", env.UIParent, "BOTTOMLEFT", 120, 600)
    api.click_text(env, "Guild Finder", env.OVHubTabs_guild)
    T.shown(env.Concord_Frame, "the tab opens the Guild Finder")
    T.hidden(env.GuildHub_Frame, "in place of the guild window")
    T.eq(env.Concord_Frame:GetLeft(), 120, "where the last one was")
    api.click_text(env, "Friends", env.OVHubTabs_guild)
    T.shown(env.Social_Frame)
    T.hidden(env.Concord_Frame)
    api.tick(env, 1)
    T.shown(env.OVHubTabs_guild, "the tabs follow")
    -- the button again closes it, and next time the hub opens on the last page
    api.click(env.SocialsMicroButton)
    T.hidden(env.Social_Frame)
    api.click(env.SocialsMicroButton)
    T.shown(env.Social_Frame, "reopens on Friends")
    -- without a guild there's no Guild tab
    local nomad = T.suite({ level = 30, name = "Nomad" })
    api.click(nomad.SocialsMicroButton)
    T.shown(nomad.Concord_Frame, "no guild: the Guild Finder first")
    api.tick(nomad, 1)
    T.lacks(table.concat(api.visible_texts(nomad, nomad.OVHubTabs_guild), ","), "My Guild")
end)

T.test("Micro menu: opening one hub closes another hub's window, so they never sit on top of each other", function()
    local env = T.suite({ level = 30, guild = { name = "Lantern" } })
    api.click(env.SocialsMicroButton)
    T.shown(env.GuildHub_Frame)
    api.click(env.OVCollectionsMicroButton)
    T.shown(env.OVCollectionsFrame)
    T.hidden(env.GuildHub_Frame, "Guild & Communities closes when Collections opens (player report #9)")
    api.tick(env, 1)
    T.hidden(env.OVHubTabs_guild, "and its tabs go with it")
    api.click(env.SocialsMicroButton)
    T.shown(env.GuildHub_Frame)
    T.hidden(env.OVCollectionsFrame, "and the other way round")
end)

T.test("Micro menu: Group Finder opens Dungeons & Raids; J, I, K and Shift-J are bound only when free", function()
    local env = T.suite({ level = 20, bindings = { I = "INSPECT_SOMETHING" } })
    api.click(env.OVGroupFinderMicroButton)
    T.shown(env.Dungeons_Frame)
    api.tick(env, 1)
    T.hidden(env.OVHubTabs_finder, "one page off Warfront: no tabs")
    T.eq(env.GetBindingAction("K"), "OV_PROFESSIONS")
    T.eq(env.GetBindingAction("J"), "OV_GUILD")
    T.eq(env.GetBindingAction("SHIFT-J"), "OV_ADVENTUREGUIDE")
    T.eq(env.GetBindingAction("I"), "INSPECT_SOMETHING", "a key the player uses stays theirs")
    T.eq(env.GetBindingAction("Y"), "ACHIEVEMENTS_TOGGLE")
    T.no(env.GetBindingAction("SHIFT-P") == "OV_COLLECTIONS", "Shift-P stays the pet spellbook")
    env.Dungeons_Frame:Hide()
    env.OpenVanilla_GroupFinder()
    T.shown(env.Dungeons_Frame, "the key binding's function")
    -- once only: a player who unbinds K keeps it unbound
    env.SetBinding("K")
    api.fire(env, "VARIABLES_LOADED")
    T.eq(env.GetBindingAction("K"), "")
end)

T.test("Micro menu: Professions lists professions and secondary skills; Open opens each one's window", function()
    local env = T.suite({ level = 40, skills = {
        { "Class Skills", header = true }, { "Arms" },
        { "Professions", header = true }, { "Mining", 212, 225 }, { "Herbalism", 140, 150 },
        { "Secondary Skills", header = true }, { "Cooking", 75, 75 }, { "First Aid", 300, 300 },
        { "Weapon Skills", header = true }, { "Swords", 200, 200 } } })
    api.click(env.OVProfessionsMicroButton)
    local f = env.OVProfessionsFrame
    T.shown(f)
    local t = table.concat(api.visible_texts(env, f), " | ")
    for _, s in ipairs({ "Professions", "Secondary Skills", "Mining", "Herbalism", "Cooking", "First Aid", "212 / 225",
        "Expert", "Artisan", "Apprentice" }) do T.has(t, s) end
    T.lacks(t, "Swords", "weapon skills aren't professions")
    T.lacks(t, "Arms")
    local P = env.WenillaCore.MicroMenu.Professions
    T.eq(table.getn(P.data.primary), 2)
    local rows = env.OVProfessionsFrame.rows
    api.click(rows[1].open)
    T.eq(env.__casts[table.getn(env.__casts)].spell, "Smelting", "Mining opens Smelting")
    T.hidden(rows[2].open, "Herbalism has no window")
    api.click(rows[3].open)
    T.eq(env.__casts[table.getn(env.__casts)].spell, "Cooking")
    api.click(env.OVProfessionsMicroButton)
    T.hidden(f, "the button again closes it")
    -- nothing learned
    local fresh = T.suite({ name = "Fresh", level = 5, skills = { { "Professions", header = true } } })
    fresh.OpenVanilla_Professions()
    T.ok(api.screen_has(fresh, "haven't learned a profession", fresh.OVProfessionsFrame))
end)

local MOUNTS = {
    [5656] = { name = "Brown Horse Bridle", quality = 3, icon = "Interface\\Icons\\Ability_Mount_RidingHorse",
        lines = { "Use: Summons and dismisses a rideable Brown Horse." } },
    [8563] = { name = "Red Mechanostrider", quality = 3, icon = "Interface\\Icons\\Ability_Mount_MechaStrider",
        lines = { "Use: Summons and dismisses a rideable Red Mechanostrider." } },
    [8485] = { name = "Cat Carrier (Bombay)", quality = 1, icon = "Interface\\Icons\\INV_Box_PetCarrier_01",
        lines = { "Right Click to summon and dismiss your cat." } },
    [2589] = { name = "Linen Cloth", quality = 1, icon = "Interface\\Icons\\INV_Fabric_Linen_01", lines = {} },
}

T.test("Micro menu: Collections lists mounts and pets from bags, bank and class spells; a click uses one", function()
    local env = T.suite({ level = 60, class = "PALADIN", spells = { "Seal of Righteousness", "Summon Warhorse" } })
    for id, d in pairs(MOUNTS) do api.add_item(env, id, d) end
    api.give_item(env, 5656)
    api.give_item(env, 8485)
    api.give_item(env, 2589)
    api.set_bag(env, -1, 24)
    api.give_item(env, 8563, 1, -1)
    api.fire(env, "BANKFRAME_OPENED")             -- the bank is remembered
    env.__bags[-1].items = {}
    api.click(env.OVCollectionsMicroButton)
    local f = env.OVCollectionsFrame
    T.shown(f)
    local t = table.concat(api.visible_texts(env, f), " | ")
    T.has(t, "Mounts: 3")
    T.has(t, "Summon Warhorse"); T.has(t, "Class spell")
    T.has(t, "Brown Horse Bridle"); T.has(t, "In your bags")
    T.has(t, "Red Mechanostrider"); T.has(t, "In your bank")
    T.lacks(t, "Linen Cloth"); T.lacks(t, "Cat Carrier")
    api.tick(env, 1)
    local tabs = api.visible_texts(env, env.OVHubTabs_collections)
    T.has(tabs, "Mounts"); T.has(tabs, "Pets")
    T.has(tabs, "Appearances", "always a Collections tab while the Transmog addon is on")
    api.click_text(env, "Brown Horse Bridle", f)
    local used = env.__used_items[table.getn(env.__used_items)]
    T.eq(used[3], 5656, "a click rides it")
    api.click_text(env, "Summon Warhorse", f)
    T.eq(env.__casts[table.getn(env.__casts)].spell, "Summon Warhorse")
    api.click_text(env, "Pets", env.OVHubTabs_collections)
    T.shown(f)
    t = table.concat(api.visible_texts(env, f), " | ")
    T.has(t, "Pets: 1"); T.has(t, "Cat Carrier (Bombay)")
    T.lacks(t, "Brown Horse")
    T.has(env.OVCollections_Char.bank[8563].name, "Red Mechanostrider", "saved per character")
end)

T.test("Micro menu: Appearances joins Collections on a Transmog realm, Warfront joins Group Finder", function()
    local env = T.suite({ level = 60, latency = false })
    local W = env.WenillaCore
    api.connect(env)
    api.tick(env, 1)
    api.server_packet(env, "TM", "on,3,50,1,20000,0")       -- the realm has Transmog
    api.tick(env, 1)
    api.click(env.OVCollectionsMicroButton)
    api.tick(env, 1)
    api.click_text(env, "Appearances", env.OVHubTabs_collections)
    T.shown(env.TransmogFrame)
    T.hidden(env.OVCollectionsFrame)
    api.tick(env, 1)
    T.shown(env.OVHubTabs_collections, "the tabs stay under the Transmog window")
    api.click_text(env, "Mounts", env.OVHubTabs_collections)
    T.shown(env.OVCollectionsFrame)
    T.hidden(env.TransmogFrame)
    -- any other label becomes a row in the Game Menu's Open Vanilla list
    W:MicroMenuAdd("Fishing log", "Interface\\Icons\\Trade_Fishing", "FISHLOG")
    env.GameMenuFrame:Show()
    api.click(env.GameMenuButtonOVTools)
    T.ok(api.screen_has(env, "Fishing log", env.OVToolsFrame))
end)

T.test("Micro menu: the Adventure Guide suggests dungeons for your level and finds a group", function()
    local env = T.suite({ level = 20 })
    api.click(env.OVAdventureGuideMicroButton)
    local f = env.OVAdventureGuideFrame
    T.shown(f)
    local t = table.concat(api.visible_texts(env, f), " | ")
    T.has(t, "Suggested Content")
    T.has(t, "Wailing Caverns"); T.has(t, "The Deadmines")
    T.lacks(t, "Molten Core")
    api.click_text(env, "Find a group", f)
    T.shown(env.Dungeons_Frame, "Find a group opens the Group Finder")
    api.click_text(env, "Raids", f)
    t = table.concat(api.visible_texts(env, f), " | ")
    T.has(t, "Molten Core"); T.has(t, "Naxxramas")
    api.click_text(env, "Dungeons", f)
    api.click_text(env, "Uldaman", f)
    t = table.concat(api.visible_texts(env, f), " | ")
    T.has(t, "Badlands"); T.has(t, "Opens to you at level 39")
    api.click_text(env, "Show on map", f)
    -- a level 8 is told when the first one opens
    local low = T.suite({ level = 8, name = "Lowbie" })
    low.OpenVanilla_AdventureGuide()
    T.ok(api.screen_has(low, "Your first dungeon opens at level 11", low.OVAdventureGuideFrame))
    T.ok(api.screen_has(low, "Ragefire Chasm", low.OVAdventureGuideFrame))
end)

T.test("Micro menu: the Game Menu stacks the suite's buttons under Macros and above Log Out", function()
    local env = T.suite()
    local g = env.GameMenuFrame
    g:Show()
    local want = { "GameMenuButtonAddOns", "GameMenuButtonOVEditMode", "GameMenuButtonOVTools", "GameMenuButtonOVSupport",
        "GameMenuButtonNode" }
    local above = env.GameMenuButtonMacros
    for _, n in ipairs(want) do
        local b = env[n]
        T.shown(b, n)
        local _, rel = b:GetPoint(1)
        T.eq(rel, above, n .. " under " .. above:GetName())
        above = b
    end
    local _, rel = env.GameMenuButtonLogout:GetPoint(1)
    T.eq(rel, above, "Log Out last")
    T.eq(env.GameMenuButtonOVEditMode:GetText(), "Edit Mode")
    T.eq(env.GameMenuButtonOVSupport:GetText(), "Support")
    T.no(env.GameMenuButtonAssistant and env.GameMenuButtonAssistant:IsShown(), "no Assistant button by default")
    env.Assistant.SetEscButton(true)
    local h = g:GetHeight()
    env.Assistant.SetEscButton(false)
    T.hidden(env.GameMenuButtonAssistant)
    local _, rel2 = env.GameMenuButtonNode:GetPoint(1)
    T.eq(rel2, env.GameMenuButtonOVSupport, "the menu closes up")
    T.eq(g:GetHeight(), h - 24)
    api.click(env.GameMenuButtonOVSupport)
    T.has(table.concat(env.__toggles, ","), "ToggleHelpFrame")
    g:Show()
    api.click(env.GameMenuButtonOVEditMode)
    T.hidden(g)
    g:Show()
    api.click(env.GameMenuButtonOVTools)
    local t = table.concat(api.visible_texts(env, env.OVToolsFrame), " | ")
    for _, s in ipairs({ "Meters", "Threat", "Bags", "Raid tools", "Persona", "Workshop", "Assistant", "All AddOns" }) do T.has(t, s) end
    api.click_text(env, "Meters", env.OVToolsFrame)
    T.hidden(env.OVToolsFrame)
end)

T.test("Micro menu: the UI Repack lays the same buttons out in its strip", function()
    local env = T.client({ level = 20 })
    api.load_suite(env)
    api.login(env)
    env.ClassicPlusUI.Elv:Apply()
    api.tick(env, 1)
    local vis = env.WenillaCore.MicroMenu:Visible()
    T.eq(table.getn(vis), 10)
    for i, b in ipairs(vis) do
        T.eq(b:GetParent(), env.CPElvMenuStrip, b:GetName() .. " in the strip")
        local _, rel, _, x = b:GetPoint(1)
        T.eq(rel, env.CPElvMenuStrip)
        T.near(x, (2 + (i - 1) * 18) / 0.56, 1e-6)
        T.ok(28 * b:GetScale() <= 18 - 2, "a clear gap in the strip")
    end
    T.hidden(env.TalentMicroButton)
    T.hidden(env.OVMicroMenuRecess)
    T.hidden(env.KeyRingButton)
end)

T.test("Micro menu: the client's disabled Edit Mode and Support placeholders leave the Game Menu", function()
    local env = T.suite()
    local g = env.GameMenuFrame
    local W = env.WenillaCore
    local ph = {}
    for _, n in ipairs({ "BenillaGameMenuButtonEditMode", "BenillaGameMenuButtonSupport" }) do
        ph[n] = env.CreateFrame("Button", n, g, "GameMenuButtonTemplate")
        ph[n]:SetHeight(20)
        ph[n]:Show()
    end
    local h0 = g:GetHeight()
    W.gameMenu.baseHeight = nil
    g:SetHeight(250)                     -- the client's menu before any suite button, placeholders in
    W:GameMenuLayout()
    for n, b in pairs(ph) do T.hidden(b, n) end
    local _, rel = env.GameMenuButtonMacros:GetPoint(1)
    T.eq(rel, env.GameMenuButtonOptions, "Macros hangs under Options")
    T.ok(g:GetHeight() < h0, "the menu is shorter")
    g:Show()
    T.shown(env.GameMenuButtonOVEditMode, "our working Edit Mode stays")
    T.shown(env.GameMenuButtonOVSupport, "and Support")
end)
