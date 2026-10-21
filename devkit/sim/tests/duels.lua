-- Duels: the Duels realm's panel (Data/Interface/AddOns/Duels), riding on the Warfront addon.
-- The server side is OpenVanilla/WarfrontArena.cpp with realm/mangos/0021-openvanilla-duels.patch.
local T, api = ...

local function duels(opts)
    opts = opts or {}
    opts.latency = false
    opts.class = opts.class or "ROGUE"
    opts.faction = opts.faction or "Horde"
    return T.addon("Duels", opts)
end

local function connect(env, hello)
    api.connect(env)
    api.tick(env, 1)
    if hello then api.server_packet(env, "WF", hello) end
end

local function sent(env) return table.concat(env.__wnl, " | ") end
local function texts(env) return table.concat(api.visible_texts(env, env.DuelsFrame), " | ") end

T.test("Duels: stays hidden on Warfront and on other realms", function()
    local env = duels()
    connect(env, "1,0,0,0,0")
    T.ok(not env.DuelsFrame or not env.DuelsFrame:IsVisible(), "Warfront without Duels: no panel")
    env.__slash("/duels")
    T.has(api.chat_text(env), "Duels realm only")
    local env2 = duels({ name = "Other" })
    connect(env2, "0")
    T.ok(not env2.DuelsFrame or not env2.DuelsFrame:IsVisible(), "no Warfront: no panel")
end)

T.test("Duels: a Duels realm opens the panel and asks for the rating and the live counts", function()
    local env = duels()
    connect(env, "1,3,0,0,0,1")
    T.shown(env.DuelsFrame)
    api.pump(env)
    T.has(sent(env), "wf q rating")
    T.has(sent(env), "wf live")
    T.has(texts(env), "Ready to duel")
    T.has(api.chat_text(env), "Welcome to Duels")
    api.server_packet(env, "WQ", "r,1500,1500,1543")
    T.has(texts(env), "Rating 1543")
    api.server_packet(env, "WC", "0,0,0,0,3,2,0,0,0,4")
    T.has(texts(env), "3 waiting to duel, 4 practising, 2 fights on")
end)

T.test("Duels: queue, pop, rounds, the result and rematch", function()
    local env = duels()
    connect(env, "1,3,0,0,0,1")
    api.click_text(env, "Practice duel", env.DuelsFrame)
    api.pump(env)
    T.has(sent(env), "wf q join u1")
    api.server_packet(env, "WQ", "q,u1,0,1")
    T.has(texts(env), "Looking for an opponent")
    T.has(texts(env), "Practice duel")
    api.server_packet(env, "WQ", "pop,u1,7,0")
    T.has(texts(env), "Round 1")
    T.has(texts(env), "You 0 - 0 Them")
    api.server_packet(env, "WQ", "prep,15")
    T.has(texts(env), "The gates open in")
    api.server_packet(env, "WQ", "go")
    api.server_packet(env, "WQ", "round,2,1,0")
    T.has(texts(env), "Round 2")
    T.has(texts(env), "You 1 - 0 Them")
    T.has(table.concat(api.visible_texts(env), " | "), "You lead")
    api.server_packet(env, "WQ", "prep,5")
    api.server_packet(env, "WQ", "go")
    api.server_packet(env, "WQ", "end,1,0,1500,2-0")
    T.has(texts(env), "Victory")
    T.has(texts(env), "2-0")
    T.has(texts(env), "1 won, 0 lost")
    api.tick(env, 2)
    api.click_text(env, "Rematch", env.DuelsFrame)
    api.pump(env)
    api.tick(env, 2)
    local n = 0
    for _, l in ipairs(env.__wnl) do if l == "wf q join u1" then n = n + 1 end end
    T.eq(n, 2, "rematch queues the same kind of duel")
end)

T.test("Duels: a rated loss shows the rating change; leaving the queue", function()
    local env = duels()
    connect(env, "1,3,0,0,0,1")
    api.click_text(env, "Duel now (rated)", env.DuelsFrame)
    api.pump(env)
    T.has(sent(env), "wf q join d1")
    api.server_packet(env, "WQ", "q,d1,0,1")
    api.click_text(env, "Leave queue", env.DuelsFrame)
    api.pump(env)
    T.has(sent(env), "wf q leave")
    api.server_packet(env, "WQ", "left")
    T.has(texts(env), "Ready to duel")
    api.server_packet(env, "WQ", "pop,d1,8,1")
    api.server_packet(env, "WQ", "end,0,-14,1486,1-2")
    T.has(texts(env), "Defeat")
    T.has(texts(env), "1-2")
    T.has(texts(env), "-14")
    T.has(texts(env), "Rating 1486")
end)

T.test("Duels: Warfront's own arena tab still gets every line", function()
    local env = duels()
    connect(env, "1,3,0,0,0,1")
    api.server_packet(env, "WQ", "pop,d1,9,0")
    T.ok(env.Warfront.Arena.match ~= nil, "Warfront saw the pop")
    api.server_packet(env, "WQ", "end,1,16,1516,2-1")
    T.ok(env.Warfront.Arena.match == nil, "and the end")
    api.server_packet(env, "WC", "1,2,3,4,5,6,7,8,9,10")
    T.eq(env.Warfront.Arena.live[6], 6, "Warfront reads its nine live fields as before")
end)

T.test("Duels: malformed lines never raise", function()
    local env = duels()
    connect(env, "1,3,0,0,0,1")
    for _, body in ipairs({ "", ",,,", "round", "round,x,y,z", "end", "end,1", "pop", "r", "err" }) do
        api.server_packet(env, "WQ", body)
    end
    api.server_packet(env, "WC", "")
    api.server_packet(env, "WF", "")
    T.eq(table.getn(env.__errors), 0, table.concat(env.__errors, "\n"))
end)
