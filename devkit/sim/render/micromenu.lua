-- Shots of the modern menu bar (WenillaCore/MicroMenu.lua) and the windows it opens
-- (WenillaCore/Journal.lua), for a level 40 Dwarf Paladin in a guild.
local S, api = ...
local T = S.T

local function player(opts)
    opts = opts or {}
    opts.latency = false
    opts.class = opts.class or "PALADIN"
    opts.race = "Dwarf"
    opts.level = opts.level or 40
    opts.guild = opts.guild or { name = "Lantern" }
    opts.skills = opts.skills or {
        { "Professions", header = true }, { "Mining", 212, 225 }, { "Blacksmithing", 198, 225 },
        { "Secondary Skills", header = true }, { "Cooking", 150, 150 }, { "First Aid", 225, 225 }, { "Fishing", 87, 150 } }
    opts.spells = opts.spells or { "Seal of Righteousness", "Summon Warhorse" }
    local env = T.suite(opts)
    api.tick(env, 1)
    return env
end

-- the stock bar art under the buttons (Interface\MainMenuBar\UI-MainMenuBar-Dwarf, as MainMenuBar.xml cuts it)
local function barArt(env)
    local bar, art = env.MainMenuBar, env.MainMenuBarArtFrame
    bar:SetWidth(1024); bar:SetHeight(53)
    art:SetAllPoints(bar)
    local cuts = { { 0, 0.83203125, 1 }, { 256, 0.58203125, 0.75 }, { 512, 0.33203125, 0.5 }, { 768, 0.08203125, 0.25 } }
    for _, c in ipairs(cuts) do
        local t = bar:CreateTexture(nil, "BACKGROUND")
        t:SetTexture("Interface\\MainMenuBar\\UI-MainMenuBar-Dwarf")
        t:SetTexCoord(0, 1, c[2], c[3])
        t:SetWidth(256); t:SetHeight(43)
        t:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", c[1], 0)
    end
    -- the stock buttons' faces, which the client's XML gives them (the sim's buttons have none)
    local FACES = { CharacterMicroButton = "UI-MicroButtonCharacter-Up", SpellbookMicroButton = "UI-MicroButton-Spellbook-Up",
        QuestLogMicroButton = "UI-MicroButton-Quest-Up", SocialsMicroButton = "UI-MicroButton-Socials-Up",
        MainMenuMicroButton = "UI-MicroButton-MainMenu-Up" }
    for n, file in pairs(FACES) do
        local b = env[n]
        local t = b:CreateTexture(nil, "ARTWORK")
        t:SetAllPoints(b)
        t:SetTexture("Interface\\Buttons\\" .. file)
        b:SetNormalTexture(t)
    end
    -- the Character button's portrait (the client draws your face there; a stand-in here)
    local cb = env.CharacterMicroButton
    local pt = cb:CreateTexture("MicroButtonPortrait", "OVERLAY")
    pt:SetWidth(18); pt:SetHeight(25)
    pt:SetPoint("TOP", cb, "TOP", 0, -28)
    pt:SetTexture("Interface\\CharacterFrame\\TemporaryPortrait-Male-Dwarf")
    pt:SetTexCoord(0.2, 0.8, 0.0666, 0.9)
    for _, n in ipairs({ "MainMenuBarBackpackButton", "CharacterBag0Slot", "CharacterBag1Slot", "CharacterBag2Slot", "CharacterBag3Slot" }) do
        local t = env[n]:CreateTexture(nil, "ARTWORK")
        t:SetAllPoints(env[n])
        t:SetTexture(n == "MainMenuBarBackpackButton" and "Interface\\Buttons\\Button-Backpack-Up" or "Interface\\Icons\\INV_Misc_Bag_08")
    end
    local kt = env.KeyRingButton:CreateTexture(nil, "ARTWORK")
    kt:SetAllPoints(env.KeyRingButton)
    kt:SetTexture("Interface\\Buttons\\UI-Button-KeyRing")
    kt:SetTexCoord(0, 0.5625, 0, 0.609375)
end

S.shot("micromenu_bar", function()
    local env = player()
    barArt(env)
    return env, env.MainMenuBar
end)

S.shot("micromenu_professions", function()
    local env = player()
    env.OpenVanilla_Professions()
    return env, env.OVProfessionsFrame
end)

local MOUNTS = {
    [5656] = { name = "Brown Horse Bridle", quality = 3, icon = "Interface\\Icons\\Ability_Mount_RidingHorse",
        lines = { "Use: Summons and dismisses a rideable Brown Horse." } },
    [5864] = { name = "Gray Ram", quality = 3, icon = "Interface\\Icons\\Ability_Mount_MountainRam",
        lines = { "Use: Summons and dismisses a rideable Gray Ram." } },
    [8563] = { name = "Red Mechanostrider", quality = 3, icon = "Interface\\Icons\\Ability_Mount_MechaStrider",
        lines = { "Use: Summons and dismisses a rideable Red Mechanostrider." } },
    [8485] = { name = "Cat Carrier (Bombay)", quality = 1, icon = "Interface\\Icons\\INV_Box_PetCarrier_01",
        lines = { "Right Click to summon and dismiss your cat." } },
    [11023] = { name = "Ancona Chicken", quality = 1, icon = "Interface\\Icons\\Spell_Magic_PolymorphChicken",
        lines = { "Right Click to summon and dismiss your chicken." } },
}

local function collections(page)
    local env = player()
    for id, d in pairs(MOUNTS) do api.add_item(env, id, d) end
    api.give_item(env, 5864); api.give_item(env, 8485); api.give_item(env, 11023)
    api.set_bag(env, -1, 24)
    api.give_item(env, 8563, 1, -1); api.give_item(env, 5656, 1, -1)
    api.fire(env, "BANKFRAME_OPENED")
    env.__bags[-1].items = {}
    env.WenillaCore.MicroMenu:OpenHub("collections", page)
    api.tick(env, 1)
    return env, env.OVCollectionsFrame
end
S.shot("micromenu_collections_mounts", function() return collections("mounts") end)
S.shot("micromenu_collections_pets", function() return collections("pets") end)

S.shot("micromenu_guide_suggested", function()
    local env = player({ level = 34 })
    env.OpenVanilla_AdventureGuide()
    return env, env.OVAdventureGuideFrame
end)

S.shot("micromenu_guide_dungeons", function()
    local env = player({ level = 34 })
    env.OpenVanilla_AdventureGuide()
    api.click_text(env, "Dungeons", env.OVAdventureGuideFrame)
    return env, env.OVAdventureGuideFrame
end)

S.shot("micromenu_guild_hub", function()
    local env = player()
    api.click(env.SocialsMicroButton)
    api.tick(env, 1)
    return env, env.GuildHub_Frame
end)

S.shot("micromenu_tools", function()
    local env = player()
    env.GameMenuFrame:Show()
    api.click(env.GameMenuButtonOVTools)
    return env, env.OVToolsFrame
end)

S.shot("micromenu_repack", function()
    local env = T.client({ latency = false, class = "PALADIN", race = "Dwarf", level = 40, name = "Repacked" })
    api.load_suite(env)
    api.login(env)
    env.ClassicPlusUI.Elv:Apply()
    api.tick(env, 1)
    -- the stock faces (the client's XML gives them; the sim's buttons have none)
    for n, file in pairs({ CharacterMicroButton = "UI-MicroButtonCharacter-Up", SpellbookMicroButton = "UI-MicroButton-Spellbook-Up",
        QuestLogMicroButton = "UI-MicroButton-Quest-Up", SocialsMicroButton = "UI-MicroButton-Socials-Up",
        MainMenuMicroButton = "UI-MicroButton-MainMenu-Up" }) do
        local t = env[n]:CreateTexture(nil, "ARTWORK"); t:SetAllPoints(env[n]); t:SetTexture("Interface\\Buttons\\" .. file)
        env[n]:SetNormalTexture(t)
    end
    return env, env.CPElvRightPanel
end)
