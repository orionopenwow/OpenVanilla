-- Meters (Chronicle): CH server snapshots, combat-log parsing, inspect drill-down.
local T, api = ...

local function rows(env) return api.visible_texts(env, env.Chronicle_Frame) end

-- A shown row's columns, "total | per second | share", found by the name on it.
local function line(env, name, f)
    f = f or env.Chronicle_Frame
    for _, r in ipairs(f.rows) do
        if r:IsShown() and r.left:GetText() == name then
            return (r.mid:GetText() or "") .. " | " .. (r.rate:GetText() or "") .. " | " .. (r.right:GetText() or "")
        end
    end
    return "(no row for " .. tostring(name) .. ")"
end

T.test("Meters: CH snapshot fills the window, sorted, with share and DPS", function()
    local env = T.addon("Meters")
    api.server_packet(env, "CH", "Brakkus,1,16000,800;Ilyndra,8,24000,1200;,3,5,5;Junk,1,x,1")
    api.tick(env, 0.6)
    T.shown(env.Chronicle_Frame)
    local text = table.concat(rows(env), "\n")
    T.eq(line(env, "Ilyndra"), "24,000 |  | ", "Damage: the total alone")
    T.eq(line(env, "Brakkus"), "16,000 |  | ")
    env.__slash("/meters dps")
    api.tick(env, 0.6)
    T.eq(line(env, "Ilyndra"), "1,200 | 24,000 | 60.0%", "DPS: the rate, the total, the share")
    env.__slash("/meters damage")
    api.tick(env, 0.6)
    T.lacks(text, "Junk", "a row with a bad total is dropped")
    T.has(text, "Fight time  0:20", "footer: the fight's length while it is on (24000/1200 s)")
    local first = api.find_text(env, "Ilyndra", env.Chronicle_Frame)
    local second = api.find_text(env, "Brakkus", env.Chronicle_Frame)
    T.ok(api.state(first).parent ~= api.state(second).parent, "two rows")
    T.eq(env.Chronicle.server.list[1].name, "Ilyndra", "sorted by total")
    T.eq(env.Chronicle.server.list[1].class, "MAGE", "class id 8 -> MAGE")
    -- server data is only trusted for 4 s: after that the local combat log takes over
    api.tick(env, 5)
    T.has(table.concat(rows(env), "\n"), "Ilyndra", "the last snapshot stays up until something changes")
    api.fire(env, "CHAT_MSG_COMBAT_SELF_HITS", "You hit Hogger for 100.")
    api.tick(env, 0.6)
    text = table.concat(rows(env), "\n")
    T.has(text, "Herald"); T.lacks(text, "Ilyndra"); T.has(text, "Last fight")
end)

T.test("Meters: combat log for you, your pet and your party; outsiders ignored", function()
    local env = T.addon("Meters", { party = { { name = "Brakkus", class = "WARRIOR" } } })
    api.set_unit(env, "pet", { name = "Wolf", isPlayer = false })
    api.fire(env, "UNIT_PET", "player")
    local C = env.Chronicle
    local lines = {
        { "CHAT_MSG_COMBAT_SELF_HITS", "You hit Defias Thug for 45." },
        { "CHAT_MSG_SPELL_SELF_DAMAGE", "Your Arcane Shot hits Defias Thug for 120 Arcane damage." },
        { "CHAT_MSG_SPELL_SELF_DAMAGE", "Your Arcane Shot crits Defias Thug for 240 Arcane damage. (12 resisted)" },
        { "CHAT_MSG_COMBAT_PET_HITS", "Wolf hits Defias Thug for 20." },
        { "CHAT_MSG_COMBAT_PARTY_HITS", "Brakkus hits Defias Thug for 30. (glancing)" },
        { "CHAT_MSG_COMBAT_FRIENDLYPLAYER_HITS", "Randomguy hits Defias Thug for 999." },
        { "CHAT_MSG_COMBAT_SELF_HITS", "You hit Brakkus for 50." },                       -- a duel
        { "CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE", "Defias Thug suffers 15 Nature damage from your Serpent Sting." },
        { "CHAT_MSG_SPELL_SELF_BUFF", "Your Mend Pet heals Wolf for 80." },
        { "CHAT_MSG_SPELL_PARTY_BUFF", "Brakkus's First Aid heals Brakkus for 100." },
        { "CHAT_MSG_SPELL_FRIENDLYPLAYER_BUFF", "Randomguy's Heal heals Randomguy for 500." },
    }
    for _, l in ipairs(lines) do api.fire(env, l[1], l[2]); api.tick(env, 0.5) end
    local P = C.fight.players
    T.eq(P.Herald.dmg, 45 + 120 + 240 + 20 + 15)
    T.eq(P.Brakkus.dmg, 30)
    T.eq(P.Randomguy, nil, "outsider not recorded")
    T.eq(P.Herald.heal, 80)
    T.eq(P.Brakkus.heal, 100)
    T.eq(P.Herald.abilities.dmg["Arcane Shot"], 360)
    T.eq(P.Herald.abilities.dmg.Wolf, 20, "pet damage credited to its owner")
    T.eq(P.Herald.class, "HUNTER")
    api.tick(env, 0.6)
    local text = table.concat(rows(env), "\n")
    T.has(text, "Herald"); T.has(text, "Brakkus"); T.has(text, "Last fight")
    env.__slash("/dps heal")
    api.tick(env, 0.6)
    T.eq(env.Chronicle_Frame.mode.label, "Healing")
    T.has(table.concat(rows(env), "\n"), "Healing")
end)

T.test("Meters: ParseLine and BuildPattern edge cases", function()
    local env = T.addon("Meters")
    local C = env.Chronicle
    local kind, src, tgt, abil, amt = C.ParseLine("Brakkus's Heroic Strike crits Defias Thug for 312 Physical damage. (30 absorbed)")
    T.eq(kind, "dmg"); T.eq(src, "Brakkus"); T.eq(tgt, "Defias Thug"); T.eq(abil, "Heroic Strike"); T.eq(amt, 312)
    kind, src, tgt, abil, amt = C.ParseLine("You gain 35 health from Ilyndra's Renew.")
    T.eq(kind, "heal"); T.eq(src, "Ilyndra"); T.eq(tgt, "Herald"); T.eq(abil, "Renew"); T.eq(amt, 35)
    T.eq(C.ParseLine("Defias Thug casts Fireball."), nil)
    local pat, order = C.BuildPattern("%2$s trifft %1$s für %3$d.")      -- positional (deDE style)
    T.eq(pat, "^(.+) trifft (.+) für (%d+)%.$")
    T.eq(table.concat(order, ","), "2,1,3")
end)

T.test("Meters: clicking a row shows the ability breakdown and asks the server", function()
    local env = T.addon("Meters")
    api.connect(env)
    api.server_packet(env, "CH", "inspect,Ilyndra;Fireball,8000,57.1%;Frostbolt,6000,42.9%")
    api.server_packet(env, "CH", "Ilyndra,8,14000,700")
    api.tick(env, 0.6)
    api.click_text(env, "Ilyndra", env.Chronicle_Frame)
    T.eq(env.__wnl[2], "ch inspect Ilyndra")
    local tip = api.tooltip_text(env)
    T.has(tip, "Ilyndra  Damage")
    T.has(tip, "Fireball  =  8,000  57.1%")
    T.has(tip, "Frostbolt  =  6,000  42.9%")
end)

T.test("Meters: local breakdown without the server; inspectOnClick off", function()
    local env = T.addon("Meters")
    api.fire(env, "CHAT_MSG_SPELL_SELF_DAMAGE", "Your Aimed Shot hits Hogger for 300.")
    api.fire(env, "CHAT_MSG_COMBAT_SELF_HITS", "You hit Hogger for 100.")
    api.tick(env, 0.6)
    api.click_text(env, "Herald", env.Chronicle_Frame)
    local tip = api.tooltip_text(env)
    T.has(tip, "Aimed Shot  =  300  75.0%")
    T.has(tip, "Melee  =  100  25.0%")
    env.ClassicPlus_Manager:SetSetting("Meters", "inspectOnClick", false)
    env.GameTooltip:ClearLines()
    api.click_text(env, "Herald", env.Chronicle_Frame)
    T.eq(api.tooltip_text(env), "")
end)

T.test("Meters: /meters toggles, reset clears, disabled addon ignores combat", function()
    local env = T.addon("Meters")
    api.fire(env, "CHAT_MSG_COMBAT_SELF_HITS", "You hit Hogger for 100.")
    env.__slash("/meters")
    T.hidden(env.Chronicle_Frame, "bare /meters closes it")
    env.__slash("/chronicle damage")
    T.shown(env.Chronicle_Frame)
    env.__slash("/meters reset")
    T.eq(env.Chronicle.fight, nil)
    env.WenillaCore:SetAddonEnabled("Meters", false)
    T.hidden(env.Chronicle_Frame)
    api.fire(env, "CHAT_MSG_COMBAT_SELF_HITS", "You hit Hogger for 100.")
    T.eq(env.Chronicle.fight, nil, "nothing recorded while disabled")
    env.WenillaCore:SetAddonEnabled("Meters", true)
    T.shown(env.Chronicle_Frame)
end)

T.test("Meters: an old server breakdown does not replace the current fight's abilities", function()
        local env = T.addon("Meters")
        api.server_packet(env, "CH", "inspect,Herald;Fireball,8000,100%")
        env.__slash("/meters reset")
        api.fire(env, "CHAT_MSG_SPELL_SELF_DAMAGE", "Your Aimed Shot hits Hogger for 300.")
        api.tick(env, 0.6)
        api.click_text(env, "Herald", env.Chronicle_Frame)
        T.has(api.tooltip_text(env), "Aimed Shot", "this fight's ability")
        T.lacks(api.tooltip_text(env), "Fireball", "last fight's server breakdown")
    end)

-- ===========================================================================================
-- Meters 1.15: the full meter (combat log totals, fights, deaths, tabs, settings, reports)
-- ===========================================================================================

local function fire(env, lines)
    for _, l in ipairs(lines) do api.fire(env, l[1], l[2]) end
end
local function combat(env, on)
    local was = env.__units.player.combat
    env.__units.player.combat = on and true or nil
    if on and not was then api.fire(env, "PLAYER_REGEN_DISABLED") end
    if was and not on then api.fire(env, "PLAYER_REGEN_ENABLED") end
end
local function slide(row, v)
    row.slider:SetValue(v)
    api.state(row.slider).scripts.OnValueChanged()
end
local function menuText(env) return table.concat(api.visible_texts(env, env.WenillaCore_Menu), "\n") end

T.test("Meters: the real 1.12 combat-log strings parse into the right kinds and roles", function()
    local env = T.addon("Meters")
    local C = env.Chronicle
    local cases = {
        -- line, kind, source, target, ability, amount
        { "Hogger hits you for 40.", "dmg", "Hogger", "Herald", nil, 40 },
        { "Hogger's Cleave crits you for 90 Physical damage.", "dmg", "Hogger", "Herald", "Cleave", 90 },
        { "You suffer 12 Shadow damage from Defias Mage's Shadow Word: Pain.", "dmg", "Defias Mage", "Herald", "Shadow Word: Pain", 12 },
        { "You fall and lose 120 health.", "dmg", "Environment", "Herald", "Falling", 120 },
        { "Brakkus is drowning and loses 30 health.", "dmg", "Environment", "Brakkus", "Drowning", 30 },
        { "You reflect 6 Holy damage to Hogger.", "dmg", nil, "Hogger", "Damage Shield", 6 },
        { "Your Hellfire Effect hits you for 70 Fire damage.", "dmg", nil, "Herald", "Hellfire Effect", 70 },
        { "You miss Hogger.", "miss", nil, "Hogger", nil, nil },
        { "You attack. Hogger parries.", "miss", nil, "Hogger", nil, nil },
        { "Your Arcane Shot was resisted by Hogger.", "miss", nil, "Hogger", "Arcane Shot", nil },
        { "Brakkus's Sunder Armor was dodged by Hogger.", "miss", "Brakkus", "Hogger", "Sunder Armor", nil },
        { "Hogger misses you.", "miss", "Hogger", "Herald", nil, nil },
        { "You interrupt Defias Pillager's Fireball.", "interrupt", nil, "Defias Pillager", "Fireball", nil },
        { "Brakkus interrupts Defias Pillager's Frostbolt.", "interrupt", "Brakkus", "Defias Pillager", "Frostbolt", nil },
        { "Ilyndra casts Remove Curse on you.", "cast", "Ilyndra", "Herald", "Remove Curse", nil },
        { "Ilyndra begins to cast Shackle Undead.", "begin", "Ilyndra", nil, "Shackle Undead", nil },
        { "You gain 20 Rage from Bloodrage.", "power", nil, "Herald", "Bloodrage", 20 },
        { "Brakkus gains 300 Mana from Ilyndra's Innervate.", "power", "Ilyndra", "Brakkus", "Innervate", 300 },
        { "You gain 1 extra attack through Sword Specialization.", "skip", nil, nil, "Sword Specialization", 1 },
        { "You gain Rapid Fire.", "aura+", nil, "Herald", "Rapid Fire", nil },
        { "You are afflicted by Curse of Weakness (2).", "aura+", nil, "Herald", "Curse of Weakness", nil },
        { "Skeleton is afflicted by Shackle Undead.", "aura+", nil, "Skeleton", "Shackle Undead", nil },
        { "Rapid Fire fades from you.", "aura-", nil, "Herald", "Rapid Fire", nil },
        { "You die.", "death", nil, "Herald", nil, nil },
        { "Brakkus dies.", "death", nil, "Brakkus", nil, nil },
        { "Hogger is slain by Brakkus!", "death", "Brakkus", "Hogger", nil, nil },
        { "You gain 35 health from Ilyndra's Renew.", "heal", "Ilyndra", "Herald", "Renew", 35 },
    }
    for _, c in ipairs(cases) do
        local kind, src, tgt, abil, amt = C.ParseLine(c[1])
        T.eq(kind, c[2], c[1] .. " kind")
        T.eq(src, c[3], c[1] .. " source")
        T.eq(tgt, c[4], c[1] .. " target")
        T.eq(abil, c[5], c[1] .. " ability")
        T.eq(amt, c[6], c[1] .. " amount")
    end
    local _, _, _, _, _, o = C.ParseLine("Your Arcane Shot crits Hogger for 240 Arcane damage.")
    T.ok(o.crit, "crit flag")
    local _, _, _, _, _, _, _, ptype = C.ParseLine("You gain 20 Rage from Bloodrage.")
    T.eq(ptype, "Rage")
end)

T.test("Meters: damage by spell with hits, crits, misses, average, largest; DPS; damage taken", function()
    local env = T.addon("Meters", { party = { { name = "Brakkus", class = "WARRIOR" } } })
    local C = env.Chronicle
    combat(env, true)
    fire(env, {
        { "CHAT_MSG_SPELL_SELF_DAMAGE", "Your Arcane Shot hits Hogger for 100 Arcane damage." },
        { "CHAT_MSG_SPELL_SELF_DAMAGE", "Your Arcane Shot crits Hogger for 250 Arcane damage." },
        { "CHAT_MSG_SPELL_SELF_DAMAGE", "Your Arcane Shot missed Hogger." },
        { "CHAT_MSG_SPELL_SELF_DAMAGE", "Your Arcane Shot was resisted by Hogger." },
        { "CHAT_MSG_COMBAT_SELF_HITS", "You hit Hogger for 50." },
        { "CHAT_MSG_COMBAT_SELF_HITS", "You crit Hogger for 110." },
        { "CHAT_MSG_COMBAT_SELF_MISSES", "You miss Hogger." },
        { "CHAT_MSG_COMBAT_SELF_MISSES", "You attack. Hogger dodges." },
        { "CHAT_MSG_COMBAT_PARTY_HITS", "Brakkus hits Hogger for 90." },
        { "CHAT_MSG_COMBAT_CREATURE_VS_SELF_HITS", "Hogger hits you for 40." },
        { "CHAT_MSG_SPELL_CREATURE_VS_SELF_DAMAGE", "Hogger's Cleave crits you for 90." },
        { "CHAT_MSG_COMBAT_CREATURE_VS_PARTY_HITS", "Hogger hits Brakkus for 30." },
        { "CHAT_MSG_COMBAT_CREATURE_VS_SELF_MISSES", "Hogger misses you." },
        { "CHAT_MSG_COMBAT_SELF_HITS", "You fall and lose 20 health." },
    })
    api.tick(env, 10)
    local P = C.fight.players
    T.eq(P.Herald.dmg, 510)
    local st = P.Herald.stats.dmg["Arcane Shot"]
    T.eq(P.Herald.abilities.dmg["Arcane Shot"], 350)
    T.eq(st.n, 2, "hits"); T.eq(st.c, 1, "crits"); T.eq(st.m, 2, "misses"); T.eq(st.max, 250, "largest")
    local melee = P.Herald.stats.dmg.Melee
    T.eq(melee.n, 2); T.eq(melee.c, 1); T.eq(melee.m, 2); T.eq(melee.max, 110)
    T.eq(P.Herald.targets.dmg.Hogger, 510)
    T.eq(P.Herald.dtaken, 150, "melee + Cleave + falling")
    T.eq(P.Herald.abilities.dtaken.Cleave, 90)
    T.eq(P.Herald.abilities.dtaken.Falling, 20)
    T.eq(P.Herald.targets.dtaken.Hogger, 130)
    T.eq(P.Herald.targets.dtaken.Environment, 20)
    T.eq(P.Brakkus.dtaken, 30)
    T.eq(C.fight.enemies.Hogger, 600)
    -- DPS: in combat the clock runs to now (10 s)
    local list, total = C:RowsFor("dps", C.fight, "current")
    T.eq(list[1].name, "Herald")
    T.near(list[1].perSec, 51, 0.6)
    T.eq(total, 600)
    T.eq(line(env, "Herald"), "510 |  | ")
    -- the breakdown window: spells with their numbers, then targets
    api.click_text(env, "Herald", env.Chronicle_Frame)
    T.shown(env.Chronicle_Detail)
    local text = table.concat(api.visible_texts(env, env.Chronicle_Detail), "\n")
    T.has(text, "Herald - Damage")
    T.has(text, "Arcane Shot")
    T.has(text, "2 hits  crit 50.0%  avg 175  max 250  2 missed")
    T.has(text, "350  68.6%")
    T.has(text, "taken 150")
    api.click(env.Chronicle_Detail.tabs:Button("targets"))
    text = table.concat(api.visible_texts(env, env.Chronicle_Detail), "\n")
    T.has(text, "Hogger"); T.has(text, "510  100.0%")
    -- damage taken mode
    env.__slash("/meters taken")
    api.tick(env, 0.6)
    text = table.concat(api.visible_texts(env, env.Chronicle_Frame), "\n")
    T.eq(env.Chronicle_Frame.mode.label, "Damage Taken")
    T.eq(env.Chronicle_Frame.title:GetText(), "Meters", "the window is Meters, whatever the tab shows")
    T.has(text, "Herald"); T.has(text, "Brakkus"); T.has(text, "83.3%")
end)

T.test("Meters: healing, HPS, estimated overhealing (unknown when health is not visible), healing taken", function()
    local env = T.addon("Meters", { party = { { name = "Brakkus", class = "WARRIOR", health = 40, healthMax = 100 } } })
    local C = env.Chronicle
    api.set_unit(env, "pet", { name = "Wolf", isPlayer = false, healthMax = 0 })
    api.fire(env, "UNIT_PET", "player")
    combat(env, true)
    fire(env, {
        { "CHAT_MSG_SPELL_SELF_BUFF", "Your Flash Heal heals Brakkus for 100." },             -- 60 useful, 40 over
        { "CHAT_MSG_SPELL_PERIODIC_PARTY_BUFFS", "Brakkus gains 20 health from your Renew." }, -- he is full now
        { "CHAT_MSG_SPELL_SELF_BUFF", "Your Flash Heal critically heals you for 50." },        -- you are full
        { "CHAT_MSG_SPELL_SELF_BUFF", "Your Mend Pet heals Wolf for 80." },                    -- pet health unknown
        { "CHAT_MSG_SPELL_PARTY_BUFF", "Brakkus's First Aid heals Brakkus for 30." },
        { "CHAT_MSG_SPELL_FRIENDLYPLAYER_BUFF", "Randomguy's Heal heals you for 70." },        -- outsider healing you
    })
    api.tick(env, 5)
    local P = C.fight.players
    T.eq(P.Herald.heal, 250)
    T.eq(P.Herald.overheal, 110, "40 + 20 + 50")
    T.eq(P.Herald.healKnown, 170, "the Mend Pet is not counted: Wolf's health is unknown")
    T.eq(P.Herald.stats.heal["Flash Heal"].c, 1)
    T.eq(P.Herald.stats.heal["Flash Heal"].max, 100)
    T.eq(P.Brakkus.heal, 30)
    T.eq(P.Brakkus.htaken, 150)
    T.eq(P.Brakkus.targets.htaken.Herald, 120)
    T.eq(P.Herald.htaken, 120, "your own heal and the outsider's")
    T.eq(P.Randomguy, nil, "outsiders are not credited")
    env.__slash("/meters overheal")
    api.tick(env, 0.6)
    local text = table.concat(api.visible_texts(env, env.Chronicle_Frame), "\n")
    T.eq(env.Chronicle_Frame.mode.label, "Overhealing"); T.has(text, "64.7%")
    env.__slash("/meters hps")
    api.tick(env, 0.6)
    text = table.concat(api.visible_texts(env, env.Chronicle_Frame), "\n")
    T.has(text, "HPS")
    local r1 = env.Chronicle_Frame.rows[1]
    T.eq(r1.rate:GetText(), "250", "HPS first, then the total beside it")
    T.near(C:RowsFor("hps", C.fight, "current")[1].perSec, 250 / C:Duration(C.fight), 0.01)
    env.__slash("/meters healed")
    api.tick(env, 0.6)
    T.has(table.concat(api.visible_texts(env, env.Chronicle_Frame), "\n"), "Brakkus")
    -- breakdown shows the overheal estimate
    env.__slash("/meters heal")
    api.tick(env, 0.6)
    api.click_text(env, "Herald", env.Chronicle_Frame)
    text = table.concat(api.visible_texts(env, env.Chronicle_Detail), "\n")
    T.has(text, "overhealing 64.7% (estimate)")
    T.has(text, "2 heals  crit 50.0%  avg 75  max 100  over 60.0%")
end)

T.test("Meters: deaths keep a recap of the last 10 events; the Deaths mode opens it", function()
    local env = T.addon("Meters", { party = { { name = "Brakkus", class = "WARRIOR", health = 50, healthMax = 100 } } })
    local C = env.Chronicle
    combat(env, true)
    for i = 1, 6 do
        api.fire(env, "CHAT_MSG_COMBAT_CREATURE_VS_PARTY_HITS", "Hogger hits Brakkus for " .. (10 * i) .. ".")
        api.tick(env, 0.5)
        api.fire(env, "CHAT_MSG_SPELL_SELF_BUFF", "Your Flash Heal heals Brakkus for 5.")
        api.tick(env, 0.5)
    end
    api.fire(env, "CHAT_MSG_SPELL_CREATURE_VS_PARTY_DAMAGE", "Hogger's Cleave crits Brakkus for 300.")
    api.fire(env, "CHAT_MSG_COMBAT_FRIENDLY_DEATH", "Brakkus dies.")
    api.tick(env, 0.6)
    local d = C.fight.deaths[1]
    T.ok(d, "a death was recorded")
    T.eq(d.name, "Brakkus"); T.eq(d.class, "WARRIOR")
    T.eq(table.getn(d.events), 10, "the last 10 events")
    T.eq(d.events[10].abil, "Cleave"); T.eq(d.events[10].amt, -300); T.ok(d.events[10].crit)
    T.eq(d.events[1].amt, 5, "the oldest kept is the 2nd heal")
    T.eq(d.events[2].amt, -30, "then the 3rd hit")
    T.eq(d.events[10].hp, 50, "health as the client showed it")
    T.eq(d.blow.src, "Hogger")
    T.eq(C.fight.players.Brakkus.deaths, 1)
    T.eq(C.overall.deaths[1], d, "overall keeps it too")
    -- you die as well
    api.fire(env, "CHAT_MSG_COMBAT_CREATURE_VS_SELF_HITS", "Hogger hits you for 999.")
    api.fire(env, "CHAT_MSG_COMBAT_FRIENDLY_DEATH", "You die.")
    T.eq(C.fight.deaths[2].name, "Herald")
    T.eq(C.fight.deaths[2].blow.amt, -999)
    env.__slash("/meters deaths")
    api.tick(env, 0.6)
    local text = table.concat(api.visible_texts(env, env.Chronicle_Frame), "\n")
    T.eq(env.Chronicle_Frame.mode.label, "Deaths"); T.has(text, "Cleave 300"); T.has(text, "Melee 999")
    api.click_text(env, "Brakkus", env.Chronicle_Frame)
    T.shown(env.Chronicle_Detail)
    text = table.concat(api.visible_texts(env, env.Chronicle_Detail), "\n")
    T.has(text, "Death recap - Brakkus")
    T.has(text, "Killing blow: Hogger's Cleave for 300 (critical)")
    T.has(text, "Hogger: Cleave"); T.has(text, "-300 crit"); T.has(text, "+5"); T.has(text, "50%")
end)

T.test("Meters: interrupts, dispels, crowd control, resurrects, resources and friendly fire", function()
    local env = T.addon("Meters", { party = {
        { name = "Brakkus", class = "WARRIOR" }, { name = "Ilyndra", class = "PRIEST" }, { name = "Zapp", class = "MAGE" } } })
    local C = env.Chronicle
    combat(env, true)
    fire(env, {
        { "CHAT_MSG_COMBAT_SELF_HITS", "You hit Defias Pillager for 10." },
        { "CHAT_MSG_SPELL_SELF_DAMAGE", "You interrupt Defias Pillager's Fireball." },
        { "CHAT_MSG_SPELL_PARTY_DAMAGE", "Brakkus interrupts Defias Pillager's Frostbolt." },
        { "CHAT_MSG_SPELL_PARTY_DAMAGE", "Brakkus interrupts Defias Pillager's Fireball." },
        { "CHAT_MSG_SPELL_PARTY_BUFF", "Ilyndra casts Remove Curse on Brakkus." },
        { "CHAT_MSG_SPELL_PARTY_BUFF", "Ilyndra casts Dispel Magic on you." },
        { "CHAT_MSG_SPELL_PARTY_DAMAGE", "Ilyndra begins to cast Shackle Undead." },
        { "CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE", "Skeleton is afflicted by Shackle Undead." },
        { "CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE", "Defias Pillager is afflicted by Polymorph." },   -- the only mage
        { "CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE", "Defias Thug is afflicted by Freezing Trap Effect." }, -- you, the hunter
        { "CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE", "Defias Thug is afflicted by Sap." },                -- no rogue: not ours
        { "CHAT_MSG_SPELL_PERIODIC_SELF_BUFFS", "You gain 300 Mana from Restore Mana." },
        { "CHAT_MSG_SPELL_PERIODIC_PARTY_BUFFS", "Brakkus gains 10 Rage from Brakkus's Bloodrage." },
        { "CHAT_MSG_COMBAT_PARTY_HITS", "Brakkus hits Ilyndra for 25." },
        { "CHAT_MSG_SPELL_PARTY_BUFF", "Ilyndra casts Resurrection on Brakkus." },
    })
    api.tick(env, 0.6)
    local P = C.fight.players
    T.eq(P.Herald.interrupts, 1); T.eq(P.Brakkus.interrupts, 2)
    T.eq(P.Brakkus.abilities.interrupts.Fireball, 1); T.eq(P.Brakkus.targets.interrupts["Defias Pillager"], 2)
    T.eq(P.Ilyndra.dispels, 2); T.eq(P.Ilyndra.targets.dispels.Herald, 1)
    T.eq(P.Ilyndra.cc, 1); T.eq(P.Ilyndra.abilities.cc["Shackle Undead"], 1)
    T.eq(P.Zapp.cc, 1, "Polymorph credited to the group's only mage")
    T.eq(P.Herald.cc, 1, "Freezing Trap to you")
    T.eq(C.fight.total.cc, 3, "the Sap was not ours")
    T.eq(P.Herald.power, 300); T.eq(P.Herald.pw_Mana, 300)
    T.eq(P.Brakkus.power, 10); T.eq(P.Brakkus.abilities.power["Bloodrage (Rage)"], 10)
    T.eq(P.Brakkus.ff, 25); T.eq(P.Brakkus.targets.ff.Ilyndra, 25)
    T.eq(P.Brakkus.dmg, 0, "friendly fire is not damage done")
    T.eq(P.Ilyndra.dtaken, 25)
    T.eq(P.Ilyndra.res, 1)
    local function show(cmd)
        env.__slash("/meters " .. cmd)
        api.tick(env, 0.6)
        return table.concat(api.visible_texts(env, env.Chronicle_Frame), "\n")
    end
    local text = show("interrupts")
    T.eq(env.Chronicle_Frame.mode.label, "Interrupts"); T.has(text, "66.7%")
    T.has(show("dispels"), "Ilyndra")
    text = show("cc")
    T.has(text, "Zapp"); T.eq(env.Chronicle_Frame.mode.label, "Crowd Control")
    T.has(show("power"), "300 mana")
    T.has(show("ff"), "Brakkus")
    T.has(show("res"), "Ilyndra")
end)

T.test("Meters: your buff and debuff uptime", function()
    local env = T.addon("Meters")
    local C = env.Chronicle
    combat(env, true)
    api.fire(env, "CHAT_MSG_COMBAT_SELF_HITS", "You hit Hogger for 10.")
    api.fire(env, "CHAT_MSG_SPELL_PERIODIC_SELF_BUFFS", "You gain Rapid Fire.")
    api.fire(env, "CHAT_MSG_SPELL_PERIODIC_SELF_DAMAGE", "You are afflicted by Curse of Weakness.")
    api.tick(env, 5)
    api.fire(env, "CHAT_MSG_SPELL_AURA_GONE_SELF", "Rapid Fire fades from you.")
    api.tick(env, 5)
    api.fire(env, "CHAT_MSG_COMBAT_SELF_HITS", "You hit Hogger for 10.")
    local up = C:AuraTimes(C.fight)
    T.near(up["Rapid Fire"].t, 5, 0.01)
    T.near(up["Curse of Weakness"].t, 10, 0.01)
    T.ok(up["Curse of Weakness"].harmful)
    env.__slash("/meters uptime")
    api.tick(env, 0.1)
    local text = table.concat(api.visible_texts(env, env.Chronicle_Frame), "\n")
    T.eq(env.Chronicle_Frame.mode.label, "Buff & Debuff Uptime"); T.has(text, "Rapid Fire"); T.eq(line(env, "Rapid Fire"), "0:05 |  | 50.0%")
    -- the fight ends; its uptime is kept with it and in the overall
    combat(env, false)
    api.tick(env, 8)
    api.fire(env, "CHAT_MSG_COMBAT_SELF_HITS", "You hit Kobold for 10.")
    local old = C.history[1]
    T.near(old.auras["Rapid Fire"].t, 5, 0.01)
    T.near(old.auras["Curse of Weakness"].t, 10, 0.01, "still up when the fight ended")
    T.near(C.overall.auras["Rapid Fire"].t, 5, 0.01)
end)

T.test("Meters: fights - bosses named and kept, trash merged, overall, 25 kept, the picker", function()
    local env = T.addon("Meters")
    local C = env.Chronicle
    local function fight(target, amount)
        combat(env, true)
        api.fire(env, "CHAT_MSG_COMBAT_SELF_HITS", "You hit " .. target .. " for " .. amount .. ".")
        api.tick(env, 1)
        api.fire(env, "CHAT_MSG_COMBAT_SELF_HITS", "You hit " .. target .. " for " .. amount .. ".")
        combat(env, false)
        api.tick(env, 7)
    end
    fight("Defias Thug", 100)
    fight("Hogger", 25)
    T.eq(table.getn(C.history), 1, "the first trash fight went to history")
    fight("Ragnaros", 500)
    T.eq(table.getn(C.history), 1, "the two trash fights merged")
    T.eq(C.history[1].fights, 2)
    T.eq(C:SegmentName(C.history[1]), "Trash - Defias Thug (2 fights)")
    T.eq(C.history[1].players.Herald.dmg, 250)
    T.eq(C.fight.boss, "Ragnaros", "named from the boss list")
    api.set_target(env, { name = "Lord Big", hostile = true, classification = "worldboss" })
    fight("Lord Big", 10)
    T.eq(C.fight.boss, "Lord Big", "a worldboss target names the fight")
    api.fire(env, "CHAT_MSG_COMBAT_HOSTILE_DEATH", "Lord Big dies.")
    T.ok(C.fight.killed)
    api.set_target(env, nil)
    fight("Kobold", 5)
    T.eq(C:SegmentName(C.history[1]), "Lord Big (kill)")
    T.eq(C:SegmentName(C.history[2]), "Ragnaros")
    T.eq(C.history[3].fights, 2)
    T.eq(C.overall.players.Herald.dmg, 2 * (100 + 25 + 500 + 10 + 5))
    T.eq(C.overall.fights, 5)
    -- the picker
    api.click(env.Chronicle_Frame.segBtn)
    local text = menuText(env)
    T.has(text, "Current fight"); T.has(text, "Overall"); T.has(text, "Ragnaros"); T.has(text, "Trash - Defias Thug (2 fights)")
    api.click_text(env, "Ragnaros", env.WenillaCore_Menu)
    text = table.concat(api.visible_texts(env, env.Chronicle_Frame), "\n")
    T.has(text, "Ragnaros  0:01"); T.has(text, "1,000")
    api.click(env.Chronicle_Frame.segBtn)
    api.click_text(env, "Overall", env.WenillaCore_Menu)
    text = table.concat(api.visible_texts(env, env.Chronicle_Frame), "\n")
    T.has(text, "Overall"); T.has(text, "1,280")
    T.eq(env.Meters_Layout.windows[1].tabs[1].seg, "overall")
    -- 25 earlier fights at most; bosses outlive trash
    for i = 1, 30 do fight("Onyxia", 1) end
    T.eq(table.getn(C.history), 25)
    -- reset clears it all and the tab falls back to the current fight
    env.__slash("/meters reset")
    T.eq(C.overall, nil); T.eq(table.getn(C.history), 0)
end)

T.test("Meters: finished fights are trimmed to keep memory low", function()
    local env = T.addon("Meters")
    local C = env.Chronicle
    combat(env, true)
    for i = 1, 20 do api.fire(env, "CHAT_MSG_COMBAT_SELF_HITS", "You hit Wolf " .. i .. " for " .. i .. ".") end
    combat(env, false)
    api.tick(env, 7)
    api.fire(env, "CHAT_MSG_COMBAT_SELF_HITS", "You hit Kobold for 1.")
    local n = 0
    for _ in pairs(C.history[1].players.Herald.targets.dmg) do n = n + 1 end
    T.eq(n, C.MAX_TARGETS)
    T.ok(C.history[1].players.Herald.targets.dmg["Wolf 20"], "the biggest are kept")
    T.eq(C.history[1].players.Herald.dmg, 210, "totals are not trimmed")
end)

T.test("Meters: tabs - add, rename, reorder, tear off, survive a relog, dock back, close", function()
    local env = T.addon("Meters")
    local f = env.Chronicle_Frame
    api.fire(env, "CHAT_MSG_COMBAT_SELF_HITS", "You hit Hogger for 100.")
    local L = env.Meters_Layout
    -- a new window starts with Damage, DPS, Healing and Deaths, Damage chosen
    T.eq(table.getn(L.windows[1].tabs), 4)
    for k, mode in ipairs({ "dmg", "dps", "heal", "deaths" }) do T.eq(L.windows[1].tabs[k].mode, mode) end
    T.eq(f.mode.label, "Damage")
    api.click(f.tabs:Button("2"))
    T.eq(f.mode.label, "DPS", "the tabs are shortcuts to the modes")
    api.click(f.tabs:Button("__add"))
    T.eq(table.getn(L.windows[1].tabs), 5)
    T.eq(L.windows[1].tabs[5].mode, "hps", "a new tab takes the next unused mode")
    T.eq(f.mode.label, "HPS")
    -- rename from the right-click menu
    api.click(f.tabs:Button("5"), "RightButton")
    api.click_text(env, "Rename", env.WenillaCore_Menu)
    T.shown(env.Meters_RenameBox)
    api.type(env.Meters_RenameBox, "Burst")
    api.press_enter(env.Meters_RenameBox)
    T.hidden(env.Meters_RenameBox)
    T.eq(L.windows[1].tabs[5].name, "Burst")
    T.has(table.concat(api.visible_texts(env, f), "\n"), "Burst")
    -- move it left
    api.click(f.tabs:Button("5"), "RightButton")
    api.click_text(env, "Move left", env.WenillaCore_Menu)
    T.eq(L.windows[1].tabs[4].id, 5)
    -- back to Damage, then the Healing tab torn off into its own window
    api.click(f.tabs:Button("1"))
    T.eq(f.mode.label, "Damage")
    api.click(f.tabs:Button("3"), "RightButton")
    api.click_text(env, "Tear off into its own window", env.WenillaCore_Menu)
    T.eq(table.getn(L.windows), 2)
    T.eq(table.getn(L.windows[1].tabs), 4)
    T.eq(L.windows[2].tabs[1].mode, "heal")
    T.shown(env.Chronicle_Frame2)
    T.eq(env.Chronicle_Frame2.mode.label, "Healing")
    -- all of it is saved per character
    env = T.relog(env)
    L = env.Meters_Layout
    T.eq(table.getn(L.windows), 2)
    T.eq(L.windows[1].tabs[3].name, "Burst")
    T.shown(env.Chronicle_Frame2, "the torn-off window comes back")
    T.eq(env.Chronicle_Frame2.mode.label, "Healing")
    T.has(table.concat(api.visible_texts(env, env.Chronicle_Frame), "\n"), "Burst")
    -- closing the torn-off window docks its tab back into the main one
    api.click(env.Chronicle_Frame2.closeButton)
    T.hidden(env.Chronicle_Frame2)
    T.eq(table.getn(L.windows), 1)
    T.eq(table.getn(L.windows[1].tabs), 5)
    -- close a tab; the last tab of the main window cannot be closed
    f = env.Chronicle_Frame
    api.click(f.tabs:Button("5"), "RightButton")
    api.click_text(env, "Close tab", env.WenillaCore_Menu)
    T.eq(table.getn(L.windows[1].tabs), 4)
    for _, t in ipairs(L.windows[1].tabs) do T.ok(t.id ~= 5) end
    for _ = 1, 4 do env.Chronicle:CloseTab(1, L.windows[1].tabs[1].id) end
    T.eq(table.getn(L.windows[1].tabs), 1, "the main window keeps one tab")
    -- a broken saved layout falls back to the four tabs
    env.Meters_Layout = { windows = { { tabs = { { mode = "nope" } } } } }
    env = T.relog(env)
    T.eq(env.Meters_Layout.windows[1].tabs[1].mode, "dmg")
    T.eq(table.getn(env.Meters_Layout.windows[1].tabs), 4)
end)

T.test("Meters: a layout from before the four tabs gets them; a changed one is left alone", function()
    local env = T.addon("Meters")
    env.Meters_Layout = { version = 1, nextTab = 2, windows = { { tabs = { { id = 1, mode = "dmg", seg = "current" } }, active = 1 } } }
    env = T.relog(env)
    local L = env.Meters_Layout
    T.eq(table.getn(L.windows[1].tabs), 4)
    T.eq(L.windows[1].active, 1)
    T.eq(L.version, 2)
    env.Meters_Layout = { version = 1, nextTab = 3, windows = { { tabs = { { id = 1, mode = "dmg", seg = "current", name = "Mine" } }, active = 1 } } }
    env = T.relog(env)
    T.eq(table.getn(env.Meters_Layout.windows[1].tabs), 1, "a renamed tab means the player set it up")
end)

T.test("Meters: a normal window - Meters title, mode portrait, rounded tabs in the header band, outlined text in fixed columns", function()
    local env = T.addon("Meters")
    local C, f = env.Chronicle, env.Chronicle_Frame
    T.eq(env.WenillaCore:Setting("Meters", "maxRows"), 8, "eight rows by default")
    env.ClassicPlus_Manager:SetSetting("Meters", "maxRows", 5)
    api.server_packet(env, "CH", "Brakkus,1,16000,800;Ilyndra,8,24000,1200;Zapp,8,1234,61;Mol,9,900,40;Tess,3,800,40;Rook,4,700,35")
    api.tick(env, 0.6)
    -- the window: the suite's normal frame, titled Meters; no mode arrow on the title
    T.eq(f.title:GetText(), "Meters")
    T.ok(f.classicFrame, "made like the Guild Finder")
    T.eq(f.arrow, nil, "no arrow")
    T.eq(f.gear.icon:GetTexture(), C.ART.gear)
    T.eq(f.reset.icon:GetTexture(), C.ART.reset)
    -- tabs: the chosen one white with the gold line, the others grey; all in the row font, 20 px tall
    local on, off = f.tabs:Button("1"), f.tabs:Button("2")
    local r, g, b = on.text:GetTextColor()
    T.near(r, 1, 0.01); T.near(g, 1, 0.01); T.near(b, 1, 0.01)
    T.ok(on.line:GetAlpha() > 0.9, "the gold line under the chosen tab")
    T.ok(off.line:GetAlpha() < 0.1)
    local ur = off.text:GetTextColor()
    T.ok(ur < 0.8, "the others a soft grey")
    T.eq(({ on.text:GetFont() })[1], C.FONT_SANS)
    for _, bt in ipairs(f.tabs.buttons) do
        if bt:IsShown() then T.eq(bt:GetHeight(), C.TAB_H); T.eq(bt:GetWidth(), math.floor(bt:GetWidth())) end
    end
    -- every label fits its tab, and the row fits the band
    local total = 0
    for _, bt in ipairs(f.tabs.buttons) do
        if bt:IsShown() then
            T.ok(bt:GetWidth() >= (bt.text:GetStringWidth() or 0) + 8, "label not cut: " .. (bt.text:GetText() or ""))
            total = total + bt:GetWidth() + C.TAB_GAP
        end
    end
    T.ok(total - C.TAB_GAP <= f.tabs.maxTotal, "the tabs fit")
    -- the reset and cog: bare glyphs, the whole texture (no box)
    local l, rr = f.gear.icon:GetTexCoord()
    T.ok((rr or 1) == 1, "the whole glyph")
    api.click(off)
    r = off.text:GetTextColor()
    T.near(r, 1, 0.01, "a click moves the highlight")
    api.click(on)
    -- no column strip: the rows start right under the tabs; the portrait shows the mode
    T.eq(f.strip, nil)
    T.eq(f.portraitPath, "Interface\\Icons\\Ability_Warrior_SavageBlow")
    api.click(f.tabs:Button("3"))
    T.eq(f.mode.label, "Healing")
    T.eq(f.portraitPath, "Interface\\Icons\\Spell_Nature_HealingTouch", "Healing: the Healing Touch leaf")
    api.click(f.tabs:Button("1"))
    -- clicking the chosen tab again opens the mode menu
    api.click(f.tabs:Button("1"))
    T.shown(env.WenillaCore_Menu)
    env.WenillaCore_Menu:Hide()
    -- rounded tabs: three pieces of Meters_Tab, the chosen one warm
    T.eq(on.round[2]:GetTexture(), C.ART.tab)
    T.eq(on.round[1]:GetWidth(), C.TAB_CAP)
    T.eq(on.rim[2]:GetTexture(), C.ART.tabEdge, "a fine rim")
    T.ok(on.glow:GetAlpha() > 0.9 and off.glow:GetAlpha() < 0.1, "the glow under the chosen tab")
    local _, _, _, onA = on.round[2]:GetVertexColor()
    T.ok(onA and onA > 0.9)
    -- the bar frame (weathered iron with studs) is off by default: the plain bars; the setting shows it
    local rim = f.rows[1].frameRim
    T.hidden(rim, "plain bars by default")
    env.ClassicPlus_Manager:SetSetting("Meters", "barFrame", true)
    C:ApplySettings()
    T.shown(rim)
    T.eq(rim.p[1]:GetTexture(), C.ART.barFrame)
    T.ok(rim:GetFrameLevel() > f.rows[1].bar:GetFrameLevel(), "over the fill")
    env.ClassicPlus_Manager:SetSetting("Meters", "barFrame", false)
    C:ApplySettings()
    -- the title: centred on the window, 13 pt
    local tp = { f.title:GetPoint(1) }
    T.eq(tp[1], "CENTER"); T.eq(tp[3], "TOP"); T.eq(tp[4], 0)
    -- rows: the icon in its own square left of the bar; the bar starts after it
    local row = f.rows[1]
    T.eq(row.iconBox:GetWidth(), row:GetHeight())
    local p1 = { row.track:GetPoint(1) }
    T.eq(p1[1], "TOPLEFT"); T.eq(p1[4], row:GetHeight() + 2, "the bar starts 2 px after the icon")
    -- one clean sans everywhere, outlined; digits all the same width (Roboto)
    for _, fs in ipairs({ row.left, row.mid, row.rate, row.right, f.hMode, f.footer }) do
        local font = { fs:GetFont() }
        T.eq(font[1], C.FONT_SANS); T.eq(font[3], "OUTLINE", "a 1 px outline")
    end
    local fh = io.open(api.addons_dir(env) .. "/Meters/Fonts/Roboto-Medium.ttf", "rb")
    T.ok(fh ~= nil, "the font ships"); if fh then fh:close() end
    local lh = io.open(api.addons_dir(env) .. "/Meters/Fonts/LICENSE-Roboto.txt", "rb")
    T.ok(lh ~= nil, "its licence beside it"); if lh then lh:close() end
    -- the per-second figure is dimmer than the total
    local _, _, _, ta = row.mid:GetTextColor()
    local _, _, _, ra = row.rate:GetTextColor()
    T.ok(ra < (ta or 1), "DPS at 70%")
    -- Damage: the total alone, at the right edge
    T.eq(line(env, "Ilyndra"), "24,000 |  | ")
    T.eq(({ row.mid:GetPoint(1) })[4], -C.COL_SHARE)
    -- the DPS tab: fixed columns, share at the right edge, the total and the rate to its left
    api.click(f.tabs:Button("2"))
    T.eq(line(env, "Ilyndra"), "1,200 | 24,000 | 55.0%")
    T.eq(({ row.right:GetPoint(1) })[4], -C.COL_SHARE)
    T.eq(({ row.rate:GetPoint(1) })[4], -C.COL_RATE)
    T.eq(({ row.mid:GetPoint(1) })[4], -C.TotalRight(true))
    -- Show per second off: no second column, the first moves right
    env.ClassicPlus_Manager:SetSetting("Meters", "showDps", false)
    C:RefreshWindows()
    T.eq(({ row.mid:GetPoint(1) })[4], -C.TotalRight(false))
    env.ClassicPlus_Manager:SetSetting("Meters", "showDps", true)
    C:RefreshWindows()
    api.click(f.tabs:Button("1"))
    -- the other row fonts
    env.ClassicPlus_Manager:SetSetting("Meters", "rowFont", "narrow")
    C:ApplySettings()
    T.eq(({ row.left:GetFont() })[1], "Fonts\\ARIALN.TTF")
    env.ClassicPlus_Manager:SetSetting("Meters", "rowFont", "sans")
    C:ApplySettings()
    -- the footer: In combat in amber
    T.eq(C.LIVE, "|cffffb347")
    -- Minimal frame: no portrait or plaque, a thin dark border
    env.ClassicPlus_Manager:SetSetting("Meters", "frameStyle", "minimal")
    C:ApplySettings()
    if f.chrome then T.hidden(f.chrome, "no Classic frame art") end
    local br, bgc, bb = f:GetBackdropBorderColor()
    T.ok(br < 0.3 and bgc < 0.3, "a thin dark border")
    env.ClassicPlus_Manager:SetSetting("Meters", "frameStyle", "window")
    C:ApplySettings()
    -- colours: the mage cyan-blue; Standard: warrior tan
    local cr, cg, cb, ca = row.bar:GetStatusBarColor()
    local mage = env.RAID_CLASS_COLORS.MAGE
    T.near(cr, mage.r, 0.01); T.near(cg, mage.g, 0.01); T.near(cb, mage.b, 0.01); T.near(ca, C.FILL_ALPHA, 0.01)
    local wr, wg = C.BarColor("WARRIOR")
    T.near(wr, 0.78, 0.01); T.near(wg, 0.2, 0.01)
    env.ClassicPlus_Manager:SetSetting("Meters", "classPalette", "standard")
    wr, wg = C.BarColor("WARRIOR")
    T.near(wr, env.RAID_CLASS_COLORS.WARRIOR.r, 0.01)
    env.ClassicPlus_Manager:SetSetting("Meters", "classPalette", "meters")
    -- more players than rows: the scrollbar, and its click scrolls
    T.shown(f.scroll)
    f.offset = 1
    C:RenderWindow(1)
    T.has(table.concat(api.visible_texts(env, f), "\n"), "Rook")
    -- reset clears the fights
    api.click(f.reset)
    api.tick(env, 0.6)
    T.lacks(table.concat(api.visible_texts(env, f), "\n"), "Ilyndra")
end)

T.test("Meters: the mode menu (with icons) and the Threat entry", function()
    local env = T.client()
    api.load_with_deps(env, "Meters")
    api.load_with_deps(env, "Threat")
    api.login(env)
    local f = env.Chronicle_Frame
    api.click(f.tabs:Button(f.tabs:Selected()))
    T.shown(env.WenillaCore_Menu)
    local text = menuText(env)
    for _, m in ipairs(env.Chronicle.MODES) do T.has(text, m.label) end
    T.has(text, "Threat (opens the Threat window)")
    local b = select(2, api.find_text(env, "Interrupts", env.WenillaCore_Menu))
    T.shown(b.icon, "menu entries carry their icon")
    T.eq(b.icon:GetTexture(), "Interface\\Icons\\Ability_Kick")
    api.click(b)
    T.eq(f.mode.label, "Interrupts")
    T.eq(env.Meters_Layout.windows[1].tabs[1].mode, "interrupts")
    -- Threat: no threat yet -> a hint; with threat -> its window comes up
    api.click(f.tabs:Button(f.tabs:Selected()))
    api.click_text(env, "Threat (opens", env.WenillaCore_Menu)
    T.has(api.chat_text(env), "Threat opens by itself")
    api.server_packet(env, "VG", "Hogger;Herald,100,1;S,1,100,110")
    env.Vanguard.userClosed = true
    env.Vanguard_Frame:Hide()
    api.click(f.tabs:Button(f.tabs:Selected()))
    api.click_text(env, "Threat (opens", env.WenillaCore_Menu)
    T.shown(env.Vanguard_Frame)
    T.eq(env.Vanguard.userClosed, nil)
end)

T.test("Meters: Shift-click compares two players", function()
    local env = T.addon("Meters", { party = { { name = "Brakkus", class = "WARRIOR" } } })
    fire(env, {
        { "CHAT_MSG_SPELL_SELF_DAMAGE", "Your Arcane Shot hits Hogger for 300." },
        { "CHAT_MSG_COMBAT_SELF_HITS", "You hit Hogger for 100." },
        { "CHAT_MSG_COMBAT_PARTY_HITS", "Brakkus hits Hogger for 200." },
        { "CHAT_MSG_SPELL_PARTY_DAMAGE", "Brakkus's Heroic Strike hits Hogger for 250." },
    })
    api.tick(env, 0.6)
    api.click_text(env, "Herald", env.Chronicle_Frame)
    env.__keys.shift = true
    api.click_text(env, "Brakkus", env.Chronicle_Frame)
    env.__keys.shift = nil
    local text = table.concat(api.visible_texts(env, env.Chronicle_Detail), "\n")
    T.has(text, "Herald vs Brakkus - Damage")
    T.has(text, "Heroic Strike"); T.has(text, "Arcane Shot")
    T.has(text, "Herald 400   Brakkus 450")
    T.has(text, "300  75.0%", "Herald's Arcane Shot share")
    T.has(text, "250  55.6%", "Brakkus's Heroic Strike share")
    -- a plain click leaves the comparison
    api.click_text(env, "Brakkus", env.Chronicle_Frame)
    T.has(table.concat(api.visible_texts(env, env.Chronicle_Detail), "\n"), "Brakkus - Damage")
    T.eq(env.Chronicle.detail.compare, nil)
end)

T.test("Meters: the settings sheet - rows, bar height, text, texture, numbers, hide, lock, scale", function()
    local env = T.addon("Meters")
    local C, f = env.Chronicle, env.Chronicle_Frame
    api.server_packet(env, "CH", "Brakkus,1,16000,800;Ilyndra,8,24000,1200;Zapp,8,1234,61")
    api.tick(env, 0.6)
    api.click(f.gear)
    local sh = env.Meters_Settings
    T.shown(sh)
    T.has(table.concat(api.visible_texts(env, sh), "\n"), "Meters settings")
    -- number format
    T.eq(sh.numberChoice.value:GetText(), "1,234", "full numbers by default, as 12,453 | 385 | 25.6%")
    local text
    T.eq(line(env, "Ilyndra"), "24,000 |  | "); T.eq(line(env, "Zapp"), "1,234 |  | ")
    api.click(sh.numberChoice.button)
    T.eq(env.WenillaCore:Setting("Meters", "numberFormat"), "short")
    api.tick(env, 0.6)
    T.eq(line(env, "Ilyndra"), "24.0k |  | "); T.eq(line(env, "Zapp"), "1234 |  | ")
    api.click(sh.numberChoice.button)
    -- rows
    slide(sh.rowsSlider, 1)
    T.eq(env.WenillaCore:Setting("Meters", "maxRows"), 1)
    text = table.concat(api.visible_texts(env, f), "\n")
    T.has(text, "Ilyndra"); T.lacks(text, "Brakkus", "one row only")
    slide(sh.rowsSlider, 10)
    -- bar height, text size, texture
    slide(sh.heightSlider, 24)
    T.eq(f.rows[1]:GetHeight(), 24)
    api.click(sh.fontChoice.button)
    T.eq(env.WenillaCore:Setting("Meters", "fontSize"), 12, "11 pt by default, one step up")
    local tex
    f.rows[1].bar.SetStatusBarTexture = function(_, t) tex = t end
    T.eq(env.WenillaCore:Setting("Meters", "barTexture"), "bronze", "the bronze bars by default")
    api.click(sh.textureChoice.button)
    T.eq(env.WenillaCore:Setting("Meters", "barTexture"), "glossy")
    T.eq(tex, "Interface\\TargetingFrame\\UI-StatusBar", "every bar gets the new texture")
    -- class colours off: grey bars
    api.click(sh.classSwitch.switch)
    T.eq(env.WenillaCore:Setting("Meters", "classColors"), false)
    local r, g, b = f.rows[1].bar:GetStatusBarColor()
    T.near(r, 0.45, 0.01); T.near(b, 0.5, 0.01)
    -- rank numbers
    api.click(sh.rankSwitch.switch)
    T.has(table.concat(api.visible_texts(env, f), "\n"), "1. Ilyndra")
    -- scale
    slide(sh.scaleSlider, 1.2)
    T.near(f:GetScale(), 1.2, 0.001)
    -- lock: dragging the title does nothing
    api.click(sh.lockSwitch.switch)
    T.eq(env.WenillaCore:Setting("Meters", "lock"), true)
    local moved = false
    local orig = f.StartMoving
    f.StartMoving = function() moved = true end
    api.state(f.dragHandle).scripts.OnDragStart()
    T.no(moved, "locked")
    api.click(sh.lockSwitch.switch)
    api.state(f.dragHandle).scripts.OnDragStart()
    T.ok(moved, "unlocked")
    f.StartMoving = orig
    -- hide out of combat
    api.click(sh.hideSwitch.switch)
    api.tick(env, 0.6)
    T.hidden(f, "out of combat")
    combat(env, true)
    api.fire(env, "PLAYER_REGEN_DISABLED")
    T.shown(f, "back for the fight")
    combat(env, false)
    api.tick(env, 5)
    T.hidden(f)
    env.__slash("/meters")
    T.shown(f, "/meters peeks at it")
    -- the same settings are in the Addons window
    local schema = env.WenillaCore.schemas.Meters
    local keys = {}
    for _, o in ipairs(schema.options) do keys[o.key] = o.type or "switch" end
    for _, k in ipairs({ "classColors", "showDps", "inspectOnClick", "autoHide", "lock", "showRank" }) do T.eq(keys[k], "switch", k) end
    for _, k in ipairs({ "numberFormat", "barTexture", "fontSize", "reportLines" }) do T.eq(keys[k], "choice", k) end
    for _, k in ipairs({ "maxRows", "barHeight", "scale" }) do T.eq(keys[k], "slider", k) end
    env.ClassicPlus_Manager:SetSetting("Meters", "numberFormat", "short")
    api.tick(env, 0.6)
    T.eq(sh.numberChoice.value:GetText(), "1.2k", "the sheet follows the Addons window")
    api.click(f.gear)
    T.hidden(sh)
end)

T.test("Meters: reports go to chat one line per player, throttled, without colour codes", function()
    local env = T.addon("Meters", { party = { { name = "Brakkus", class = "WARRIOR" } } })
    local C, f = env.Chronicle, env.Chronicle_Frame
    combat(env, true)
    fire(env, {
        { "CHAT_MSG_SPELL_SELF_DAMAGE", "Your Arcane Shot hits Hogger for 3000." },
        { "CHAT_MSG_COMBAT_PARTY_HITS", "Brakkus hits Hogger for 1000." },
    })
    api.tick(env, 4)
    local log = env.__bus.log
    api.click(f.report)
    T.has(menuText(env), "Report Damage (top 5)")
    api.click_text(env, "Party", env.WenillaCore_Menu)
    T.eq(table.getn(log), 1, "the first line goes at once")
    api.tick(env, 0.3)
    T.eq(table.getn(log), 1, "the next waits for the throttle")
    api.tick(env, 1)
    T.eq(table.getn(log), 3)
    T.eq(log[1].kind, "PARTY")
    T.eq(log[1].msg, "Meters: Damage - Current fight - Hogger (0:04)")
    T.eq(log[2].msg, "1. Herald 3,000 (750/s, 75.0%)")
    T.eq(log[3].msg, "2. Brakkus 1,000 (250/s, 25.0%)")
    for _, l in ipairs(log) do T.no(string.find(l.msg, "|", 1, true), "no escape codes in chat") end
    -- not in a raid
    C:Report(1, "RAID")
    T.has(api.chat_text(env), "you are not in a raid")
    -- whisper your target, top 1
    api.set_target(env, { name = "Ilyndra", isPlayer = true })
    api.click(f.report)
    api.click_text(env, "Top 3", env.WenillaCore_Menu)
    T.eq(env.WenillaCore:Setting("Meters", "reportLines"), 3)
    T.shown(env.WenillaCore_Menu, "the menu stays open after picking the line count")
    api.click_text(env, "Whisper Ilyndra", env.WenillaCore_Menu)
    api.tick(env, 2)
    T.eq(log[4].kind, "WHISPER"); T.eq(log[4].target, "Ilyndra")
    -- slash: /meters report say 1 -> header + one line
    env.__slash("/meters report say 1")
    api.tick(env, 2)
    T.eq(log[7].kind, "SAY"); T.has(log[8].msg, "1. Herald 3,000 (")
    T.eq(log[9], nil)
    -- deaths report
    api.fire(env, "CHAT_MSG_COMBAT_CREATURE_VS_PARTY_HITS", "Hogger hits Brakkus for 77.")
    api.fire(env, "CHAT_MSG_COMBAT_FRIENDLY_DEATH", "Brakkus dies.")
    env.__slash("/meters deaths")
    local lines = C:ReportLines(1, 5)
    T.has(lines[2], "1. Brakkus died at 0:")
    T.has(lines[2], "- Melee (Hogger) 77")
    -- nothing to report
    env.__slash("/meters reset")
    C:Report(1, "SAY")
    T.has(api.chat_text(env), "nothing to report yet")
end)
