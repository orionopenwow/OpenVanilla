-- PvP: the arena card, enemy cooldowns from the combat log, crowd control and diminishing returns.
local T, api = ...

local function pvp(opts)
    opts = opts or {}
    opts.latency = false
    opts.class = opts.class or "ROGUE"
    local env = T.addon("PvP", opts)
    return env
end

T.test("PvP: the combat log says what an enemy used; its cooldown runs, Preparation gives the rest back", function()
    local env = pvp()
    local P = env.PvP
    T.eq(select(1, P.Parse("Kaelix casts Vanish.")), "Kaelix")
    T.eq(select(2, P.Parse("Kaelix gains Evasion.")), "Evasion")
    T.eq(select(2, P.Parse("Kaelix's Kidney Shot hits you for 0.")), "Kidney Shot")
    T.eq(P.Parse("Kaelix casts Frostbolt."), nil, "no cooldown to track")
    T.eq(P.Parse("You gain Evasion."), nil, "not your own")
    P.Used("Kaelix", "Vanish"); P.Used("Kaelix", "Kick")
    local cds = P.Cooldowns("Kaelix")
    T.eq(cds[1][1], "Vanish", "longest first")
    T.ok(cds[1][2] > 290)
    P.Used("Kaelix", "Preparation")
    T.eq(table.getn(P.Cooldowns("Kaelix")), 1, "Preparation resets Vanish and Kick")
    api.fire(env, "CHAT_MSG_SPELL_HOSTILEPLAYER_BUFF", "Mirelle gains Ice Block.")
    T.eq(P.Cooldowns("Mirelle")[1][1], "Ice Block", "from the event")
end)

T.test("PvP: a stun on the target is timed, and the next one in 18 s gets half, then a quarter, then none", function()
    local env = pvp()
    local P = env.PvP
    api.set_target(env, { name = "Brakk", class = "WARRIOR", hostile = true, isPlayer = true,
        debuffs = { { texture = "Interface\\Icons\\Ability_Rogue_KidneyShot" } } })
    P.ScanUnit("target")
    local cc = P.ActiveCC("Brakk")
    T.eq(cc.name, "Kidney Shot"); T.eq(cc.dur, 6)
    T.eq(P.DrIcons("Brakk")[1][2], "1/2", "the next stun is halved")
    env.__units.target.debuffs = {}
    P.ScanUnit("target")
    T.eq(P.ActiveCC("Brakk"), nil, "ended when the icon went")
    env.__units.target.debuffs = { { texture = "Interface\\Icons\\Ability_CheapShot" } }
    P.ScanUnit("target")
    T.eq(P.ActiveCC("Brakk").dur, 2, "Cheap Shot at half: 2 s")
    env.__units.target.debuffs = {}; P.ScanUnit("target")
    env.__units.target.debuffs = { { texture = "Interface\\Icons\\Spell_Holy_SealOfMight" } }; P.ScanUnit("target")
    T.eq(P.ActiveCC("Brakk").dur, 1.5, "a quarter of Hammer of Justice")
    T.eq(P.DrIcons("Brakk")[1][2], "immune")
    env.__units.target.debuffs = {}; P.ScanUnit("target")
    api.tick(env, 19)
    T.eq(table.getn(P.DrIcons("Brakk")), 0, "18 s later it is full again")
end)

T.test("PvP: the card shows for an enemy player only, with health, cooldowns and DR", function()
    local env = pvp()
    local P = env.PvP
    api.set_target(env, { name = "Kaelix", class = "ROGUE", hostile = true, isPlayer = true, health = 70, healthMax = 100 })
    P.Used("Kaelix", "Vanish")
    P.Paint()
    T.shown(env.PvP_ArenaCard)
    T.has(table.concat(api.visible_texts(env, env.PvP_ArenaCard), " | "), "Kaelix")
    T.shown(env.PvP_ArenaCard.cds[1], "Vanish in the cooldown row")
    api.set_target(env, { name = "Hogger", isPlayer = false, hostile = true })
    P.Paint()
    T.hidden(env.PvP_ArenaCard, "not for a mob")
end)
