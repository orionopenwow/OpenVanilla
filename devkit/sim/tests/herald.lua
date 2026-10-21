-- Herald/Herald.lua: the orders Herald gives the realm's bot AI when he plays your character.
local T, api = ...

local function said(env, from)
    local out = {}
    for i = (from or 0) + 1, table.getn(env.__chat_sent) do table.insert(out, env.__chat_sent[i].msg) end
    return out
end
local function find(lines, text)
    for _, l in ipairs(lines) do if string.find(l, text, 1, true) then return l end end
end

T.test("Herald: playing starts with the goal, the loot strategy and the fight orders (no flee)", function()
    local env = T.addon("Herald")
    local n = table.getn(env.__chat_sent)
    api.fire(env, "CHAT_MSG_SYSTEM", "Enable player ai")
    api.tick(env, 3)
    local lines = said(env, n)
    T.ok(find(lines, " nc +grind,"), "the Level up goal")
    T.ok(find(lines, "-maintenance"), "the safety list rides with the goal")
    T.ok(find(lines, " nc +custom::herald"), "loots every kill (classicplus_herald_ai.sql)")
    T.ok(find(lines, " co -flee,+potions"), "never runs from two mobs; drinks a potion instead")
    for _, l in ipairs(lines) do T.ok(string.len(l) <= 255, "every order fits the 1.12 chat limit: " .. l) end
end)

T.test("Herald: a level-up gives the orders again (the bot AI may have reset its strategies)", function()
    local env = T.addon("Herald")
    api.fire(env, "CHAT_MSG_SYSTEM", "Enable player ai")
    api.tick(env, 3)
    local n = table.getn(env.__chat_sent)
    api.fire(env, "PLAYER_LEVEL_UP", 12)
    api.tick(env, 3)
    T.ok(find(said(env, n), " co -flee,+potions"), "fight orders again after the level-up")
    T.ok(find(said(env, n), " nc +custom::herald"), "and the loot strategy")
end)

T.test("Herald: the orders go out again every five minutes while he plays", function()
    local env = T.addon("Herald")
    api.fire(env, "CHAT_MSG_SYSTEM", "Enable player ai")
    api.tick(env, 3)
    local n = table.getn(env.__chat_sent)
    api.tick(env, 310, 1)
    T.ok(find(said(env, n), " co -flee,+potions"), "re-sent on the timer")
    api.fire(env, "CHAT_MSG_SYSTEM", "Disable player ai")
    n = table.getn(env.__chat_sent)
    api.tick(env, 310, 1)
    T.no(find(said(env, n), ".bot cmd"), "nothing once you take back control")
end)

T.test("Herald: Herald Autopilot (the desktop app) keeps its own goal; Herald sends only the fight orders", function()
    local env = T.addon("Herald")
    local n = table.getn(env.__chat_sent)
    api.fire(env, "CHAT_MSG_SYSTEM", "Enable player ai (Autopilot)")
    api.tick(env, 3)
    local lines = said(env, n)
    T.ok(find(lines, " co -flee,+potions"), "fight orders")
    T.no(find(lines, " nc "), "no goal of his own over the app's plan")
end)
