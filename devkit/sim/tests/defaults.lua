-- Defaults.lua (in WenillaCore): first-login quality-of-life settings and /cpdefaults.
local T, api = ...

local NOTICE = "Instant quest text, auto-accept quests, auto loot, full camera zoom and floating names are on"

T.test("Defaults: first login applies the quality-of-life settings once", function()
    local env = T.addon("WenillaCore")
    T.eq(env.GetCVar("cameraDistanceMax"), "25")
    T.eq(env.GetCVar("cameraDistanceMaxFactor"), "2")
    T.eq(env.GetCVar("autoLootDefault"), "1")
    T.eq(env.QUEST_FADING_DISABLE, "1")
    T.eq(env.ClassicPlus_Defaults.version, 2)
    T.has(api.chat_text(env), NOTICE)
    -- the player turns auto loot off; a relog must not force it back
    env.__slash("/cpdefaults loot")
    T.eq(env.GetCVar("autoLootDefault"), "0")
    local again = T.relog(env)
    T.eq(again.GetCVar("autoLootDefault"), "0")
    T.lacks(api.chat_text(again), NOTICE, "applied once")
end)

T.test("Defaults: v2 re-applies once to players who had v1", function()
    local env = T.addon("WenillaCore", { saved = { ClassicPlus_Defaults = { version = 1, autoAccept = false } },
        cvars = { autoLootDefault = "0" } })
    T.eq(env.ClassicPlus_Defaults.version, 2)
    T.eq(env.GetCVar("autoLootDefault"), "1", "auto loot back on once")
    T.eq(env.ClassicPlus_Defaults.autoAccept, true)
    T.eq(env.ClassicPlus_Defaults.autoTurnIn, false, "auto turn-in starts off")
    T.has(api.chat_text(env), NOTICE)
    env.__slash("/cpdefaults accept")
    local again = T.relog(env)
    T.eq(again.ClassicPlus_Defaults.autoAccept, false, "not forced back after v2")
end)

T.test("Defaults: instant quest text comes back on every login, and follows Interface Options", function()
    local env = T.addon("WenillaCore")
    -- QUEST_FADING_DISABLE is not saved by the client: every new session starts at "0"
    local again = T.relog(env)
    T.eq(again.QUEST_FADING_DISABLE, "1", "restored from our own setting")
    -- the player unticks the box in Interface Options; we read it back at logout
    again.QUEST_FADING_DISABLE = "0"
    api.fire(again, "PLAYER_LOGOUT")
    local third = T.relog(again)
    T.eq(third.QUEST_FADING_DISABLE, "0", "their choice sticks")
    third.__slash("/cpdefaults text")
    T.eq(third.QUEST_FADING_DISABLE, "1")
    T.eq(T.relog(third).QUEST_FADING_DISABLE, "1")
end)

T.test("Defaults: floating names on for NPCs, players and yourself; /cpdefaults names toggles", function()
    local env = T.addon("WenillaCore")
    T.eq(env.GetCVar("UnitNameNPC"), "1")
    T.eq(env.GetCVar("UnitNamePlayer"), "1")
    T.eq(env.GetCVar("UnitNameOwn"), "1")
    T.eq(env.GetCVar("UnitNamePlayerGuild"), "1", "guild names stay on")
    T.eq(env.GetCVar("UnitNamePlayerPVPTitle"), "1", "titles stay on")
    env.__slash("/cpdefaults names")
    T.eq(env.GetCVar("UnitNameNPC"), "0")
    T.eq(env.GetCVar("UnitNameOwn"), "0")
    T.has(api.chat_text(env), "floating names off")
    local again = T.relog(env)
    T.eq(again.GetCVar("UnitNameNPC"), "0", "not forced back")
    again.__slash("/cpdefaults names")
    T.eq(again.GetCVar("UnitNamePlayer"), "1")
end)

T.test("Defaults: nameplates start hidden, V is remembered, /cpdefaults plates toggles", function()
    local env = T.addon("WenillaCore")
    T.eq(env.__plates.enemy, false)
    T.eq(env.__plates.friend, false)
    T.eq(env.NAMEPLATES_ON, nil)
    -- the V binding: ShowNameplates(); NAMEPLATES_ON = 1
    env.ShowNameplates(); env.NAMEPLATES_ON = 1
    T.eq(env.ClassicPlus_Defaults.plates, true, "the player's choice is remembered")
    local again = T.relog(env)
    T.eq(again.__plates.enemy, true, "1.12 forgets plates at logout; we restore them")
    T.eq(again.NAMEPLATES_ON, 1)
    again.__slash("/cpdefaults plates")
    T.eq(again.__plates.enemy, false)
    T.eq(again.NAMEPLATES_ON, nil)
    T.has(api.chat_text(again), "nameplates off")
end)

T.test("Defaults: enemy plates only in combat (Plates setting, off by default)", function()
    local env = T.addon("Plates")
    T.eq(env.WenillaCore:Setting("Plates", "combatOnly"), false)
    env.__slash("/cpdefaults combat")
    T.eq(env.WenillaCore:Setting("Plates", "combatOnly"), true)
    T.eq(env.__plates.enemy, false)
    api.set_combat(env, true)
    T.eq(env.__plates.enemy, true, "combat shows enemy plates")
    T.eq(env.NAMEPLATES_ON, 1)
    T.eq(env.ClassicPlus_Defaults.plates, false, "not mistaken for the player pressing V")
    api.set_combat(env, false)
    T.eq(env.__plates.enemy, false, "and hides them after")
    env.ClassicPlus_Manager:SetSetting("Plates", "combatOnly", false)
    api.set_combat(env, true)
    T.eq(env.__plates.enemy, false, "setting off: combat leaves plates alone")
end)

T.test("Defaults: auto-accept quests, Shift to read, /cpdefaults toggles", function()
    local env = T.addon("WenillaCore")
    api.fire(env, "QUEST_DETAIL")
    T.eq(#env.__accepted_quests, 1, "auto-accepted")
    env.__keys.shift = true
    api.fire(env, "QUEST_DETAIL")
    T.eq(#env.__accepted_quests, 1, "Shift held: not accepted")
    env.__keys.shift = nil
    env.__slash("/cpdefaults accept")
    api.fire(env, "QUEST_DETAIL")
    T.eq(#env.__accepted_quests, 1, "auto-accept off")
    env.__slash("/cpdefaults text")
    T.eq(env.QUEST_FADING_DISABLE, "0")
    env.__slash("/cpdefaults camera")
    T.eq(env.GetCVar("cameraDistanceMaxFactor"), "1")
    T.eq(env.GetCVar("cameraDistanceMax"), "15")
    env.__slash("/cpdefaults camera")
    T.eq(env.GetCVar("cameraDistanceMaxFactor"), "2")
    env.__slash("/cpdefaults reset")
    T.eq(env.QUEST_FADING_DISABLE, "1")
    api.fire(env, "QUEST_DETAIL")
    T.eq(#env.__accepted_quests, 2, "reset turns auto-accept back on")
    T.has(api.chat_text(env), "/cpdefaults text | accept | turnin | loot | camera | names | plates | combat")
end)

T.test("Defaults: auto turn-in (off by default) completes quests with at most one reward", function()
    local env = T.addon("WenillaCore")
    env.__quest = { completable = true, choices = 0 }
    api.fire(env, "QUEST_PROGRESS")
    api.fire(env, "QUEST_COMPLETE")
    T.eq(#env.__quest_done, 0, "off by default")
    env.__slash("/cpdefaults turnin")
    T.has(api.chat_text(env), "auto turn-in on")
    api.fire(env, "QUEST_PROGRESS")
    api.fire(env, "QUEST_COMPLETE")
    T.eq(table.concat(env.__quest_done, ","), "complete,reward 0")
    env.__quest = { completable = true, choices = 1 }
    api.fire(env, "QUEST_COMPLETE")
    T.eq(env.__quest_done[3], "reward 1", "the only reward is taken")
    env.__quest = { completable = true, choices = 3 }
    api.fire(env, "QUEST_COMPLETE")
    T.eq(#env.__quest_done, 3, "a choice of rewards waits for the player")
    env.__quest = { completable = false, choices = 0 }
    api.fire(env, "QUEST_PROGRESS")
    T.eq(#env.__quest_done, 3, "not completable yet")
    env.__keys.shift = true
    env.__quest = { completable = true, choices = 0 }
    api.fire(env, "QUEST_PROGRESS")
    T.eq(#env.__quest_done, 3, "Shift reads instead")
end)

T.test("Defaults: auto loot takes every slot; Shift loots by hand; BoP confirmed only when solo", function()
    local env = T.addon("WenillaCore", { latency = false })
    api.open_loot(env, { { 2589, 4 }, { coin = 125 }, { 2770, 2 } })
    api.pump(env)
    T.eq(#env.__loot_taken, 3, "all three slots taken")
    T.ok(env.GetContainerItemInfo(0, 1), "linen in the bag")
    api.open_loot(env, { { 2589, 1 } }, { shift = true })
    api.pump(env)
    T.eq(#env.__loot_taken, 0, "Shift: the window stays for looting by hand")
    -- bind on pickup: alone, confirm it; in a group, the stock popup asks
    env.StaticPopupDialogs.LOOT_BIND = { text = "Looting %s will bind it to you." }
    env.StaticPopup_Show("LOOT_BIND", "Aegis")
    local confirmed = {}
    local take = env.LootSlot
    env.LootSlot = function(i) table.insert(confirmed, i) return take(i) end
    api.fire(env, "LOOT_BIND_CONFIRM", 1)
    api.pump(env)
    T.eq(confirmed[1], 1, "solo: confirmed")
    T.hidden(env.StaticPopup1, "popup closed")
    env.__units.party1 = { name = "Ann", class = "MAGE", level = 60, isPlayer = true, debuffs = {}, buffs = {} }
    env.StaticPopup_Show("LOOT_BIND", "Aegis")
    api.fire(env, "LOOT_BIND_CONFIRM", 1)
    T.eq(#confirmed, 1, "grouped: left to the player")
    T.shown(env.StaticPopup1)
    -- auto loot off: nothing happens
    env.__units.party1 = nil
    env.__slash("/cpdefaults loot")
    api.open_loot(env, { { 2589, 1 } })
    api.pump(env)
    T.eq(#env.__loot_taken, 0)
end)

T.test("Defaults: the auto loot fallback stands aside while the Loot addon is on", function()
    local env = T.client({ latency = false })
    api.load_with_deps(env, "Loot")
    api.login(env)
    local calls = 0
    local take = env.LootSlot
    env.LootSlot = function(i) calls = calls + 1 return take(i) end
    api.open_loot(env, { { 2589, 4 }, { 2770, 2 } })
    api.pump(env)
    T.eq(#env.__loot_taken, 2, "everything looted")
    T.eq(calls, 2, "each slot taken once, not twice")
end)

T.test("Defaults: buff durations show under your buffs, every login, and follow Interface Options", function()
    local env = T.addon("WenillaCore")
    T.eq(env.SHOW_BUFF_DURATIONS, "1", "time left under each buff (player report #23)")
    local again = T.relog(env)
    T.eq(again.SHOW_BUFF_DURATIONS, "1", "the client doesn't keep it; we do")
    again.SHOW_BUFF_DURATIONS = "0"
    api.fire(again, "PLAYER_LOGOUT")
    T.eq(T.relog(again).SHOW_BUFF_DURATIONS, "0", "unticked in Interface Options: it stays off")
end)
