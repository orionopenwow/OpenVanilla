-- Boss Fights: the boss warnings (BossFights/Warnings.lua) and Bot Captain (BossFights/Captain.lua).
-- The bots' own Onyxia tactics are server side (realm/mangos/0059 and 0063).
local T, api = ...

local function bf(opts)
    opts = opts or {}
    opts.latency = false
    opts.class = opts.class or "MAGE"
    opts.faction = opts.faction or "Horde"
    return T.addon("BossFights", opts)
end

local HI = "hi,1,1,onyxia,dps,0,onyxia:0:1:10"

local function connect(env)
    api.connect(env)
    api.tick(env, 1)
    api.server_packet(env, "WF", "1,0,0,0,0,1")
    api.pump(env)
    api.server_packet(env, "BF", HI)
end

-- in a run in Onyxia's Lair, with `bots` bots in it
local function inRun(env, bots)
    connect(env)
    api.server_packet(env, "BF", "pop,7,onyxia,1,none")
    api.server_packet(env, "BF", "in,7,onyxia,1,10")
    if bots then api.server_packet(env, "BF", "rbots," .. bots) end
    env.__map.zone = "Onyxia's Lair"
end

local function banner(env)
    local f = env.BossFightsWarningFrame
    if not f or not f:IsVisible() then return "" end
    return f.text:GetText() or ""
end

local function raid(env, n)
    for i = 1, n do api.set_unit(env, "raid" .. i, { name = (i == 1) and env.__name or ("Bot" .. i), class = "WARRIOR", isPlayer = true }) end
end

T.test("Boss warnings: Onyxia's pull, lift-off, Deep Breath, landing and fear, each on screen with a sound", function()
    local env = bf()
    inRun(env, 9)
    api.fire(env, "CHAT_MSG_MONSTER_YELL", "How fortuitous. Usually, I must leave my lair in order to feed.", "Onyxia")
    T.has(banner(env), "north wall")
    T.ok(table.getn(env.__sounds) >= 1, "a sound with the call")
    api.tick(env, 6)
    api.fire(env, "CHAT_MSG_MONSTER_YELL", "This meaningless exertion bores me. I'll incinerate you all from above!", "Onyxia")
    T.has(banner(env), "She's flying")
    api.tick(env, 1)
    api.fire(env, "CHAT_MSG_MONSTER_EMOTE", "Onyxia takes in a deep breath...", "Onyxia")
    T.has(banner(env), "DEEP BREATH")
    api.tick(env, 1)
    api.fire(env, "CHAT_MSG_MONSTER_YELL", "It seems you'll need another lesson, mortals!", "Onyxia")
    T.has(banner(env), "Landing")
    api.tick(env, 9)
    api.fire(env, "CHAT_MSG_SPELL_CREATURE_VS_CREATURE_DAMAGE", "Onyxia begins to cast Bellowing Roar.")
    T.has(banner(env), "FEAR")
    T.ok(table.getn(env.__errors) == 0, "no errors: " .. table.concat(env.__errors, "; "))
end)

T.test("Boss warnings: one call per mechanic (no spam), and they fade away", function()
    local env = bf()
    inRun(env, 0)
    api.fire(env, "CHAT_MSG_MONSTER_EMOTE", "Onyxia takes in a deep breath...", "Onyxia")
    local sounds = table.getn(env.__sounds)
    api.fire(env, "CHAT_MSG_MONSTER_EMOTE", "Onyxia takes in a deep breath...", "Onyxia")
    T.ok(table.getn(env.__sounds) == sounds, "the same breath, called once")
    api.tick(env, 6)
    T.ok(banner(env) == "", "faded after its time")
    api.tick(env, 2)
    api.fire(env, "CHAT_MSG_MONSTER_EMOTE", "Onyxia takes in a deep breath...", "Onyxia")
    T.has(banner(env), "DEEP BREATH")
end)

T.test("Boss warnings: whelps are called in the fight only, and a Fireball on you says spread", function()
    local env = bf()
    inRun(env, 0)
    api.fire(env, "CHAT_MSG_COMBAT_CREATURE_VS_PARTY_HITS", "Onyxian Whelp hits Grunt for 120.")
    T.ok(banner(env) == "", "a whelp in the tunnel before the pull: no call")
    api.fire(env, "CHAT_MSG_MONSTER_YELL", "How fortuitous. Usually, I must leave my lair in order to feed.", "Onyxia")
    api.tick(env, 6)
    api.fire(env, "CHAT_MSG_COMBAT_CREATURE_VS_PARTY_HITS", "Onyxian Whelp hits Grunt for 120.")
    T.has(banner(env), "Whelps")
    api.tick(env, 5)
    api.fire(env, "CHAT_MSG_SPELL_CREATURE_VS_SELF_DAMAGE", "Onyxia's Fireball hits you for 1800 Fire damage.")
    T.has(banner(env), "keep 8 yards")
end)

T.test("Boss warnings: the soon calls from her health, once each", function()
    local env = bf()
    inRun(env, 0)
    api.set_target(env, { name = "Onyxia", hostile = true, level = 63, health = 670, healthMax = 1000 })
    api.tick(env, 1)
    T.has(banner(env), "Lift-off soon")
    api.tick(env, 4)
    api.set_target(env, { name = "Onyxia", hostile = true, level = 63, health = 660, healthMax = 1000 })
    api.tick(env, 1)
    T.ok(not string.find(banner(env), "Lift-off soon", 1, true), "called once")
    api.set_target(env, { name = "Onyxia", hostile = true, level = 63, health = 420, healthMax = 1000 })
    api.tick(env, 1)
    T.has(banner(env), "Landing soon")
end)

T.test("Boss warnings: silent outside Onyxia's Lair, and /bfw turns them off", function()
    local env = bf()
    connect(env)
    api.fire(env, "CHAT_MSG_MONSTER_EMOTE", "Onyxia takes in a deep breath...", "Onyxia")
    T.ok(banner(env) == "", "not in her lair: nothing")
    env.__map.zone = "Onyxia's Lair"
    env.__slash("/bfw")
    api.fire(env, "CHAT_MSG_MONSTER_EMOTE", "Onyxia takes in a deep breath...", "Onyxia")
    T.ok(banner(env) == "", "turned off: nothing")
    T.has(api.chat_text(env), "boss warnings off")
    env.__slash("/bfw")
    api.fire(env, "CHAT_MSG_MONSTER_EMOTE", "Onyxia takes in a deep breath...", "Onyxia")
    T.has(banner(env), "DEEP BREATH")
end)

T.test("Bot Captain: shows for the leader of a run with bots, hidden without bots", function()
    local env = bf()
    raid(env, 10)
    inRun(env, 0)
    api.tick(env, 2)
    T.ok(not env.BossFightsCaptainFrame or not env.BossFightsCaptainFrame:IsVisible(), "no bots: no panel")
    api.server_packet(env, "BF", "rbots,9")
    api.tick(env, 2)
    T.shown(env.BossFightsCaptainFrame)
    local t = table.concat(api.visible_texts(env, env.BossFightsCaptainFrame), " | ")
    T.has(t, "Stack on me")
    T.has(t, "Attack my target")
    T.has(t, "Stop")
end)

T.test("Bot Captain: each button says the bots' own commands in raid chat", function()
    local env = bf()
    raid(env, 10)
    inRun(env, 9)
    api.tick(env, 2)
    local function said() local out = {} for _, s in ipairs(env.__chat_sent) do table.insert(out, s.kind .. ":" .. s.msg) end return table.concat(out, " | ") end
    api.click_text(env, "Stack on me", env.BossFightsCaptainFrame)
    T.has(said(), "RAID:follow")
    T.has(said(), "RAID:formation near")
    api.click_text(env, "Spread", env.BossFightsCaptainFrame)
    T.has(said(), "RAID:formation circle")
    api.click_text(env, "Stop", env.BossFightsCaptainFrame)
    T.has(said(), "RAID:co +passive")
    api.click_text(env, "Resume", env.BossFightsCaptainFrame)
    T.has(said(), "RAID:co -passive")
    api.click_text(env, "Stay", env.BossFightsCaptainFrame)
    T.has(said(), "RAID:stay")
end)

T.test("Bot Captain: attack needs a target, and closing it keeps it closed for the run", function()
    local env = bf()
    raid(env, 10)
    inRun(env, 9)
    api.tick(env, 2)
    local before = table.getn(env.__chat_sent)
    api.click_text(env, "Attack my target", env.BossFightsCaptainFrame)
    T.ok(table.getn(env.__chat_sent) == before, "no target: nothing sent")
    T.has(api.chat_text(env), "pick a target first")
    api.set_target(env, { name = "Onyxia", hostile = true, level = 63 })
    api.click_text(env, "Attack my target", env.BossFightsCaptainFrame)
    T.ok(table.getn(env.__chat_sent) == before + 1, "sent once")
    env.__slash("/captain")
    api.tick(env, 3)
    T.ok(not env.BossFightsCaptainFrame:IsVisible(), "closed stays closed")
    api.server_packet(env, "BF", "pop,8,onyxia,1,none")
    api.server_packet(env, "BF", "in,8,onyxia,1,10")
    api.server_packet(env, "BF", "rbots,9")
    api.tick(env, 2)
    T.shown(env.BossFightsCaptainFrame)
end)
