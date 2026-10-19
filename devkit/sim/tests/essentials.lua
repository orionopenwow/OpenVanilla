-- Essentials: cooldown numbers, range/mana colours, reagent counts, auto dismount, /cast
-- conditions, keybind mode, aura timers and accessibility.
local T, api = ...

local SWP = "Interface\\Icons\\Spell_Shadow_ShadowWordPain"
local ITEMS = {
    [6265] = { name = "Soul Shard", quality = 1, icon = "Interface\\Icons\\INV_Misc_Gem_Amethyst_02", sell = 0, stack = 1 },
    [2512] = { name = "Rough Arrow", quality = 1, icon = "Interface\\Icons\\INV_Ammo_Arrow_02", sell = 0, stack = 200 },
}

local function ess(opts)
    opts = opts or {}
    opts.items = opts.items or ITEMS
    return T.addon("Essentials", opts)
end

local function cdText(env, n) return env["ActionButton" .. n].ess.cd:GetText() end

T.test("Essentials: registers with plain names, every feature a switch, defaults on", function()
    local env = ess()
    local W = env.WenillaCore
    local s = W.schemas.Essentials
    T.eq(s.title, "Essentials")
    T.eq(env.GetAddOnMetadata("Essentials", "Title"), "Essentials")
    local keys = {}
    for _, o in ipairs(s.options) do keys[o.key] = o.type or "switch" end
    for _, k in ipairs({ "cooldownText", "rangeColor", "reagentCount", "autoDismount", "macroConditions", "keybinds",
        "auraTimers", "colorBlind" }) do
        T.eq(keys[k], "switch", k)
    end
    T.eq(keys.uiScale, "slider"); T.eq(keys.fontScale, "slider")
    T.eq(W:Setting("Essentials", "cooldownText"), true)
    T.eq(W:Setting("Essentials", "colorBlind"), false, "colour-blind palette is opt-in")
    local order = {}
    for i, id in ipairs(W.ADDONS) do order[id] = i end
    T.ok(order.Essentials, "joins the Addons window")
end)

T.test("Essentials: cooldown numbers on action buttons, coloured by time left", function()
    local env = ess()
    local now = env.GetTime()
    api.set_action(env, 1, { name = "Frost Nova", cooldown = { now - 1, 25 } })
    api.set_action(env, 2, { name = "Blink", cooldown = { now, 4 } })
    api.set_action(env, 3, { name = "Fireball", cooldown = { now, 1.5 } })            -- global cooldown
    api.set_action(env, 4, { name = "Hearthstone", cooldown = { now, 3600 } })
    api.set_action(env, 5, { name = "Evocation", cooldown = { now - 10, 100 } })
    api.set_action(env, 6, { name = "Ice Block", cooldown = { now, 2.6 } })
    api.tick(env, 0.15)
    T.eq(cdText(env, 1), "24")
    T.eq(cdText(env, 2), "4")
    T.eq(cdText(env, 3), nil, "no number for the global cooldown")
    T.eq(cdText(env, 4), "60m")
    T.eq(cdText(env, 5), "2m")
    T.eq(cdText(env, 6), "2.5", "tenths in the last three seconds")
    local r, g = env.ActionButton2.ess.cd:GetTextColor()
    T.eq(r, 1); T.eq(g, 0.25, "under five seconds: red")
    _, g = env.ActionButton1.ess.cd:GetTextColor()
    T.eq(g, 0.9, "under a minute: yellow")
    api.tick(env, 25)
    T.eq(cdText(env, 1), nil, "ready: the number goes")
    T.eq(cdText(env, 7), nil, "an empty slot shows nothing")
    env.ClassicPlus_Manager:SetSetting("Essentials", "cooldownText", false)
    api.tick(env, 0.2)
    T.eq(cdText(env, 4), nil, "switched off")
end)

T.test("Essentials: cooldown numbers on bag items", function()
    local env = ess({ bags = { [0] = { size = 16, items = { { 858, 3 }, { 2589, 5 } } } } })
    env.ContainerFrame1:Show()
    api.set_bag_cooldown(env, 0, 1, env.GetTime(), 120)
    api.tick(env, 0.15)
    T.eq(env.ContainerFrame1Item1.ess.cd:GetText(), "2m")
    T.eq(env.ContainerFrame1Item2.ess.cd:GetText(), nil)
    -- another bag window registers its buttons
    local b = env.CreateFrame("Button", "OtherBagSlot", env.UIParent)
    env.Essentials.AddBagButton(b, function() return 0, 1 end)
    api.tick(env, 0.15)
    T.eq(b.ess.cd:GetText(), "2m")
end)

T.test("Essentials: out of range red, out of mana blue, unusable grey", function()
    local env = ess()
    api.set_action(env, 1, { name = "Frostbolt", range = 0 })
    api.set_action(env, 2, { name = "Blizzard", range = 1, noMana = true })
    api.set_action(env, 3, { name = "Execute", usable = false })
    api.set_action(env, 4, { name = "Frostbolt", range = 1 })
    api.tick(env, 0.15)
    local function tint(n) return table.concat({ env["ActionButton" .. n .. "Icon"]:GetVertexColor() }, ",", 1, 3) end
    T.eq(tint(1), "0.85,0.15,0.15")
    T.eq(tint(2), "0.25,0.45,1")
    T.eq(tint(3), "0.4,0.4,0.4")
    T.eq(tint(4), "1,1,1")
    env.ClassicPlus_Manager:SetSetting("Essentials", "rangeColor", false)
    api.tick(env, 0.15)
    T.eq(tint(1), "1,1,1", "the stock colours return")
end)

T.test("Essentials: reagent, soul shard and ammo counts on the spells that use them", function()
    local env = ess({ class = "WARLOCK", bags = { [0] = { size = 16, items = { { 6265, 1 }, { 6265, 1 }, { 6265, 1 } } } } })
    api.set_action(env, 1, { name = "Summon Voidwalker", reagent = "Soul Shard" })
    api.set_action(env, 2, { name = "Shadow Bolt" })
    api.set_action(env, 3, { name = "Ritual of Summoning", reagent = "Soul Shard" })
    api.set_action(env, 4, { name = "Auto Shot" })
    api.set_action(env, 5, { name = "Portal: Ironforge", reagent = "Rune of Portals" })
    env.__inventory[0] = 2512
    env.__inv_counts = { [0] = 187 }
    api.tick(env, 0.15)
    local function count(n) return env["ActionButton" .. n].ess.count:GetText() end
    T.eq(count(1), "3")
    T.eq(count(2), nil, "no reagent")
    T.eq(count(4), "187", "arrows in the ammo slot")
    T.eq(count(5), "0", "none left")
    T.eq((env.ActionButton5.ess.count:GetTextColor()), 1)
    T.eq(select(2, env.ActionButton5.ess.count:GetTextColor()), 0.3, "red at zero")
    env.__bags[0].items[3] = nil
    api.fire(env, "BAG_UPDATE", 0)
    api.tick(env, 0.15)
    T.eq(count(1), "2", "follows the bags")
    env.ClassicPlus_Manager:SetSetting("Essentials", "reagentCount", false)
    api.tick(env, 0.15)
    T.eq(count(1), nil)
end)

T.test("Essentials: casting while mounted dismounts and casts again", function()
    local env = ess()
    api.set_target(env, { name = "Defias Thug", isPlayer = false, hostile = true })
    api.set_mounted(env, true)
    env.CastSpellByName("Frostbolt")
    T.eq(#env.__casts, 0, "the server refused: mounted")
    api.pump(env)                                     -- "You are mounted" arrives
    T.eq(env.__mounted, nil, "the mount buff was cancelled")
    api.tick(env, 0.5)
    T.eq(#env.__casts, 1, "and the spell went off")
    T.eq(env.__casts[1].spell, "Frostbolt")
    -- an action button press is retried as a button press
    api.set_action(env, 5, { name = "Fireball" })
    api.set_mounted(env, true)
    env.UseAction(5)
    api.tick(env, 0.5)
    T.eq(#env.__used_actions, 2, "pressed again")
    T.eq(env.__casts[2].spell, "Fireball")
    -- only one retry per action
    api.set_mounted(env, true)
    env.Essentials.last = nil
    api.fire(env, "UI_ERROR_MESSAGE", "You are mounted")
    api.tick(env, 0.5)
    T.eq(#env.__casts, 2, "nothing to retry")
end)

T.test("Essentials: casting while sitting stands you up; a hunter's aspect is not a mount", function()
    local env = ess()
    api.set_sitting(env, true)
    env.CastSpellByName("Renew", 1)
    api.tick(env, 0.5)
    T.eq(env.__emotes[1], "STAND")
    T.eq(env.__casts[1].spell, "Renew")
    T.eq(env.__casts[1].onSelf, true)
    api.set_buffs(env, { { texture = "Interface\\Icons\\Ability_Mount_JungleTiger", name = "Aspect of the Cheetah",
        desc = "Increases movement speed by 30%." } })
    api.fire(env, "UI_ERROR_MESSAGE", "You are mounted")
    T.eq(#env.__player_buffs, 1, "the aspect stays")
    env.ClassicPlus_Manager:SetSetting("Essentials", "autoDismount", false)
    api.set_mounted(env, true)
    env.CastSpellByName("Frostbolt")
    api.tick(env, 0.5)
    T.eq(env.__mounted, true, "switched off: stays mounted")
end)

T.test("Essentials: /cast conditions pick a clause by modifier", function()
    local env = ess()
    api.set_target(env, { name = "Defias Thug", isPlayer = false, hostile = true })
    env.__slash("/cast [mod:shift] Frost Nova; Frostbolt")
    T.eq(env.__casts[1].spell, "Frostbolt")
    env.__keys.shift = true
    env.__slash("/cast [mod:shift] Frost Nova; Frostbolt")
    T.eq(env.__casts[2].spell, "Frost Nova")
    env.__slash("/cast [nomod] Arcane Missiles; [mod:ctrl/shift] Arcane Explosion")
    T.eq(env.__casts[3].spell, "Arcane Explosion", "mod:ctrl/shift: either")
    env.__keys.shift = nil
    env.__keys.alt = true
    env.__slash("/cast [mod:shift] A; [mod:alt] Counterspell")
    T.eq(env.__casts[4].spell, "Counterspell")
    env.__keys.alt = nil
    env.__slash("/cast [mod] A; [nomod:shift] Polymorph")
    T.eq(env.__casts[5].spell, "Polymorph")
    env.__slash("/cast [mod:shift] Frost Nova")
    T.eq(#env.__casts, 5, "no clause matches: nothing is cast")
    env.__slash("/cast Fireball")
    T.eq(env.__casts[6].spell, "Fireball", "a plain /cast still works")
end)

T.test("Essentials: /cast [target=mouseover,help] heals the unit under the mouse and keeps your target", function()
    local env = ess({ class = "PRIEST" })
    local ann = T.client({ name = "Ann", class = "MAGE" })
    api.set_target(env, { name = "Defias Thug", isPlayer = false, hostile = true })
    api.mouseover(env, "Ann")
    env.__slash("/cast [target=mouseover,help] Flash Heal; [harm] Smite")
    T.eq(env.__casts[1].spell, "Flash Heal")
    T.eq(env.__casts[1].target, "Ann", "cast on the mouseover")
    T.eq(env.UnitName("target"), "Defias Thug", "your target is back")
    api.mouseover(env, nil)
    env.__slash("/cast [target=mouseover,help] Flash Heal; [harm] Smite")
    T.eq(env.__casts[2].spell, "Smite", "no mouseover: the hostile target")
    env.__slash("/cast [@player] Renew")
    T.eq(env.__casts[3].onSelf, true, "@player casts on yourself")
    api.set_target(env, "Ann")
    env.__slash("/cast [help] Power Word: Shield; [harm] Smite")
    T.eq(env.__casts[4].spell, "Power Word: Shield")
    env.__slash("/cast [dead] Resurrection; [nodead,exists] Lesser Heal")
    T.eq(env.__casts[5].spell, "Lesser Heal")
    env.__slash("/cast [frobnicate] Mind Blast; Smite")
    T.eq(env.__casts[6].spell, "Smite", "unknown conditions never match")
    T.ok(ann)
end)

T.test("Essentials: /cast conditions switched off leave /cast alone", function()
    local env = ess()
    T.eq(env.Essentials.ParseCast("[mod:shift] A; B"), "B")
    T.eq(env.Essentials.ParseCast("[mod:shift] A"), nil)
    T.eq(env.Essentials.ParseCast("[] A"), "A", "an empty group always matches")
    env.ClassicPlus_Manager:SetSetting("Essentials", "macroConditions", false)
    env.__slash("/cast Frostbolt")
    T.eq(env.__casts[1].spell, "Frostbolt")
end)

T.test("Essentials: keybind mode binds the hovered button", function()
    local env = ess()
    env.__slash("/kb")
    T.shown(env.EssentialsKeybindFrame)
    T.has(api.chat_text(env), "Keybind mode: hover a button and press a key.")
    api.enter(env.ActionButton3)
    api.press_key(env, "Q")
    T.eq(env.GetBindingAction("Q"), "ACTIONBUTTON3")
    env.__keys.shift = true
    api.press_key(env, "LSHIFT")
    api.press_key(env, "E")
    env.__keys.shift = nil
    T.eq(env.GetBindingAction("SHIFT-E"), "ACTIONBUTTON3")
    T.eq(env.GetBindingAction("LSHIFT"), "", "a modifier alone binds nothing")
    T.has(env.Essentials.keybindHint:GetText(), "Action Button 3: Q, SHIFT-E")
    api.enter(env.MultiBarBottomLeftButton2)
    api.press_key(env, "2")
    T.eq(env.GetBindingAction("2"), "MULTIACTIONBAR1BUTTON2")
    api.press_key(env, "Q")
    T.eq(env.GetBindingAction("Q"), "MULTIACTIONBAR1BUTTON2", "a key moves to the new button")
    api.press_key(env, "DELETE")
    T.eq(env.GetBindingAction("2"), "")
    T.eq(env.GetBindingAction("Q"), "")
    api.leave(env.MultiBarBottomLeftButton2)
    api.press_key(env, "R")
    T.has(env.Essentials.keybindHint:GetText(), "Hover over an action button first.")
    api.press_key(env, "ESCAPE")
    T.hidden(env.EssentialsKeybindFrame)
    T.eq(env.__bindings_saved, 2, "saved to the current binding set")
    T.has(api.chat_text(env), "Keybind mode off. Your key bindings are saved.")
    env.ClassicPlus_Manager:SetSetting("Essentials", "keybinds", false)
    env.__slash("/kb")
    T.hidden(env.EssentialsKeybindFrame)
    T.has(api.chat_text(env), "Keybind mode is switched off.")
end)

T.test("Essentials: aura timers on the target frame from the combat log", function()
    local env = ess()
    api.set_target(env, { name = "Defias Thug", isPlayer = false, hostile = true,
        debuffs = { { texture = SWP, name = "Shadow Word: Pain" } } })
    api.fire(env, "CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE", "Defias Thug is afflicted by Shadow Word: Pain.")
    api.tick(env, 0.3)
    T.shown(env.TargetFrameDebuff1)
    T.eq(env.TargetFrameDebuff1.essAura:GetText(), "18")
    api.tick(env, 5)
    T.eq(env.TargetFrameDebuff1.essAura:GetText(), "13")
    -- a new debuff appears while you watch: its clock starts now
    env.__units.target.debuffs[2] = { texture = "Interface\\Icons\\Spell_Nature_Polymorph", name = "Polymorph" }
    api.fire(env, "UNIT_AURA", "target")
    api.tick(env, 0.3)
    T.eq(env.TargetFrameDebuff2.essAura:GetText(), "50")
    -- it fades
    env.__units.target.debuffs[2] = nil
    api.fire(env, "CHAT_MSG_SPELL_AURA_GONE_OTHER", "Polymorph fades from Defias Thug.")
    api.fire(env, "UNIT_AURA", "target")
    T.eq(env.Essentials.AuraRemaining("Defias Thug", "Polymorph"), nil)
    -- buffs too
    api.fire(env, "CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_BUFFS", "Ann gains Renew.")
    T.near(env.Essentials.AuraRemaining("Ann", "Renew"), 15, 0.01)
end)

T.test("Essentials: auras already up when you target something get no guess", function()
    local env = ess()
    api.set_target(env, { name = "Kobold", isPlayer = false, hostile = true,
        debuffs = { { texture = SWP, name = "Shadow Word: Pain" } } })
    api.tick(env, 0.3)
    local t = env.TargetFrameDebuff1.essAura
    T.eq(t and t:GetText() or nil, nil)
    env.ClassicPlus_Manager:SetSetting("Essentials", "auraTimers", false)
    api.fire(env, "CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE", "Kobold is afflicted by Shadow Word: Pain.")
    api.tick(env, 0.3)
    t = env.TargetFrameDebuff1.essAura
    T.eq(t and t:GetText() or nil, nil, "switched off")
end)

T.test("Essentials: durations table has the main crowd control and damage over time per class", function()
    local env = ess()
    local D = env.Essentials.AURA_DURATIONS
    for name, secs in pairs({ ["Polymorph"] = 50, ["Sap"] = 45, ["Fear"] = 20, ["Hibernate"] = 40,
        ["Freezing Trap Effect"] = 20, ["Hammer of Justice"] = 6, ["Shackle Undead"] = 50, ["Frost Nova"] = 8,
        ["Corruption"] = 18, ["Curse of Agony"] = 24, ["Immolate"] = 15, ["Rend"] = 21, ["Moonfire"] = 12,
        ["Serpent Sting"] = 15, ["Flame Shock"] = 12, ["Garrote"] = 18, ["Kidney Shot"] = 6 }) do
        T.eq(D[name], secs, name)
    end
end)

T.test("Essentials: colour-blind palette reaches class, difficulty and reaction colours", function()
    local env = ess({ level = 30 })
    local W = env.WenillaCore
    local stockHunter = W.UI.CLASS_COLORS.HUNTER[2]
    T.eq(table.concat({ W.Palette.Difficulty(36) }, ","), "1,0.1,0.1")
    env.ClassicPlus_Manager:SetSetting("Essentials", "colorBlind", true)
    T.eq(table.concat({ W.Palette.Difficulty(36) }, ","), "0.8,0.47,0.65")
    T.eq(table.concat({ W.Palette.Difficulty(26) }, ","), "0.34,0.71,0.91", "green becomes sky blue")
    T.eq(table.concat({ W.Palette.Reaction("hostile") }, ","), "0.84,0.37,0")
    T.eq(W.UI.CLASS_COLORS.HUNTER[2], 0.62, "the suite's class colours swap in place")
    T.eq((W.UI.ClassColor("HUNTER")), 0)
    env.ClassicPlus_Manager:SetSetting("Essentials", "colorBlind", false)
    T.eq(W.UI.CLASS_COLORS.HUNTER[2], stockHunter, "and come back")
end)

T.test("Essentials: the colour-blind palette reaches nameplates", function()
    local env = T.client({ level = 30 })
    api.load_with_deps(env, "Essentials")
    api.load_with_deps(env, "Plates")
    api.login(env)
    env.ClassicPlus_Manager:SetSetting("Plates", "levelDifficulty", true)   -- levels are gold unless asked
    local p = api.add_nameplate(env, { name = "Ogre", level = 36 })
    api.tick(env, 0.3)
    T.eq(table.concat({ p.visage.capText:GetTextColor() }, ",", 1, 3), "1,0.1,0.1")
    env.ClassicPlus_Manager:SetSetting("Essentials", "colorBlind", true)
    api.tick(env, 0.3)
    T.eq(table.concat({ p.visage.capText:GetTextColor() }, ",", 1, 3), "0.8,0.47,0.65")
    local _, _, name = p:GetRegions()
    T.eq((name:GetTextColor()), 0.84, "enemy name in vermillion")
end)

T.test("Essentials: interface scale and text size; the game's scale is untouched until you choose", function()
    local env = ess({ cvars = { uiScale = "0.9", useUiScale = "1" } })
    T.eq(env.WenillaCore:Setting("Essentials", "uiScale"), 0.9, "the slider shows the game's own scale")
    T.eq(env.GetCVar("uiScale"), "0.9")
    env.ClassicPlus_Manager:SetSetting("Essentials", "uiScale", 0.8)
    T.eq(env.GetCVar("uiScale"), "0.8")
    T.eq(env.GetCVar("useUiScale"), "1")
    T.eq(env.UIParent:GetScale(), 0.8)
    local _, size = env.GameFontNormal:GetFont()
    env.ClassicPlus_Manager:SetSetting("Essentials", "fontScale", 1.25)
    local _, bigger = env.GameFontNormal:GetFont()
    T.near(bigger, size * 1.25, 1e-6)
    local fs = env.UIParent:CreateFontString()
    env.WenillaCore.UI.Font(fs, 10)
    T.near(select(2, fs:GetFont()), 12.5, 1e-6, "new Classic+ text follows")
    local again = T.relog(env)
    T.eq(again.UIParent:GetScale(), 0.8, "your scale is applied at login")
    T.near(select(2, again.GameFontNormal:GetFont()), size * 1.25, 1e-6)
    again.ClassicPlus_Manager:SetSetting("Essentials", "fontScale", 1)
    T.near(select(2, again.GameFontNormal:GetFont()), size, 1e-6, "back to normal")
end)

T.test("Essentials: a fresh player keeps the default scale (nothing written)", function()
    local env = ess()
    T.eq(env.GetCVar("useUiScale"), "0")
    T.eq(env.WenillaCore:Setting("Essentials", "uiScale"), 1)
end)

T.test("Essentials: the window has a Features page and an Accessibility page", function()
    local env = ess({ level = 40 })
    env.__slash("/essentials")
    local win = env.EssentialsFrame
    T.shown(win)
    T.ok(api.screen_has(env, "Cooldown numbers", win))
    T.ok(api.screen_has(env, "Keybind mode", win))
    T.no(api.screen_has(env, "Interface scale", win), "accessibility is on its own page")
    local row = win.pages.features.rows[1]
    api.click(row.switch)
    T.eq(env.WenillaCore:Setting("Essentials", "cooldownText"), false, "the switch changes the setting")
    api.click_text(env, "Accessibility", win)
    T.ok(api.screen_has(env, "Interface scale", win))
    T.ok(api.screen_has(env, "Colour-blind friendly colours", win))
    T.ok(api.screen_has(env, "Text size", win))
    T.ok(api.screen_has(env, "1.00x", win))
    local lv = win.pages.access.preview.levels[5]
    T.eq(lv:GetText(), "46")
    T.eq(table.concat({ lv:GetTextColor() }, ",", 1, 3), "1,0.1,0.1")
    api.click(win.pages.access.rows[1].switch)
    T.eq(table.concat({ lv:GetTextColor() }, ",", 1, 3), "0.8,0.47,0.65", "the preview follows the palette")
    api.press_escape(env)
    T.hidden(win)
end)

T.test("Essentials: switched off, everything stops", function()
    local env = ess()
    api.set_action(env, 1, { name = "Frost Nova", cooldown = { env.GetTime(), 25 }, range = 0 })
    api.tick(env, 0.15)
    T.eq(cdText(env, 1), "25")
    env.WenillaCore:SetAddonEnabled("Essentials", false)
    T.eq(cdText(env, 1), nil)
    T.eq(table.concat({ env.ActionButton1Icon:GetVertexColor() }, ",", 1, 3), "1,1,1")
    env.__slash("/kb")
    T.has(api.chat_text(env), "Essentials is switched off.")
    env.__slash("/cast [mod:shift] A; Frostbolt")
    T.eq(env.__casts[1].spell, "[mod:shift] A; Frostbolt", "plain stock /cast")
end)

T.test("Essentials: aura timers and the colour-blind palette on the UI Repack's target frame", function()
    local env = T.client()
    api.load_with_deps(env, "Essentials")
    api.load_with_deps(env, "Repack")
    api.login(env)
    env.ClassicPlusUI.Elv:Apply()
    api.set_target(env, { name = "Defias Thug", isPlayer = false, hostile = true,
        debuffs = { { texture = SWP, name = "Shadow Word: Pain" } } })
    api.fire(env, "CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE", "Defias Thug is afflicted by Shadow Word: Pain.")
    api.tick(env, 0.5)
    local a = env.CPElvTarget.auras[1]
    T.shown(a)
    T.eq(a.essAura:GetText(), "18")
    T.eq(select(2, env.CPElvTarget.hp:GetStatusBarColor()), 0.2, "stock hostile red")
    env.ClassicPlus_Manager:SetSetting("Essentials", "colorBlind", true)
    api.fire(env, "UNIT_HEALTH", "target")
    T.eq((env.CPElvTarget.hp:GetStatusBarColor()), 0.84, "vermillion for enemies")
end)
