-- A brand-new player's first ten minutes with the whole suite: a fresh level-1 character logs in,
-- the welcome shows once, the common windows open and close, /bug opens the bug window, and no
-- addon raises a Lua error on the way (the harness fails a test on any error left in env.__errors).
local T, api = ...

local function fresh()
    return T.suite({ name = "Newbie", class = "WARRIOR", race = "Human", level = 1 })
end

T.test("New player: the welcome shows once a few seconds after the first login", function()
    local env = fresh()
    local Wl = env.WenillaCore.Welcome
    T.no(env.WenillaCore_Welcome and env.WenillaCore_Welcome:IsShown(), "not straight away")
    api.tick(env, 8)
    T.shown(env.WenillaCore_Welcome, "shown after the pause")
    T.has(env.WenillaCore_Welcome.lines[1]:GetText(), "World chat")
    T.has(env.WenillaCore_Welcome.lines[2]:GetText(), "/bug")
    T.has(env.WenillaCore_Welcome.lines[3]:GetText(), "discord.gg/")
    api.click(env.WenillaCore_Welcome.ok)
    T.hidden(env.WenillaCore_Welcome)
    T.ok(Wl.Seen(), "remembered for the account")
    local again = T.relog(env)
    api.tick(again, 10)
    T.no(again.WenillaCore_Welcome and again.WenillaCore_Welcome:IsShown(), "not on the next login")
    api.slash(again, "/welcome")
    T.shown(again.WenillaCore_Welcome, "/welcome shows it again")
end)

T.test("New player: a level-1 character's first ten minutes with every window, no Lua errors", function()
    local env = fresh()
    api.tick(env, 8)
    if env.WenillaCore_Welcome and env.WenillaCore_Welcome:IsShown() then api.click(env.WenillaCore_Welcome.ok) end
    local opens = {
        function() env.ToggleBackpack() end,
        function() env.OpenAllBags() end,
        function() env.ToggleQuestLog() end,
        function() env.ToggleCharacter("PaperDollFrame") end,
        function() env.ToggleSpellBook(env.BOOKTYPE_SPELL) end,
        function() env.ToggleWorldMap() end,
        function() api.slash(env, "/bug") end,
        function() api.slash(env, "/welcome") end,
    }
    for minute = 1, 10 do
        for _, open in ipairs(opens) do open() end
        api.tick(env, 30)
        for _, open in ipairs(opens) do open() end      -- and close again (toggles)
        api.press_escape(env)
        api.tick(env, 30)
    end
    T.shown(env.WenillaCore_BugButton, "the bug button is there for a new player")
    api.slash(env, "/bug")
    T.shown(env.WenillaCore_BugFrame, "/bug opens the bug window")
    T.eq(table.getn(api.pcall_errors(env) or {}), 0, "no errors swallowed by pcall either")
end)

T.test("New player: the welcome waits for the first-time setup window and comes after it", function()
    local first = fresh()
    first.WenillaCore_Config.setup = { done = false }      -- a brand-new account: the setup window is still to come
    first.WenillaCore_Config.welcomed = nil
    local env = T.relog(first)
    api.tick(env, 7)
    T.shown(env.ClassicPlusSetup, "the setup window first")
    T.no(env.WenillaCore_Welcome and env.WenillaCore_Welcome:IsShown(), "not on top of the setup window")
    env.ClassicPlusSetup:Hide()
    api.tick(env, 4)
    T.shown(env.WenillaCore_Welcome, "after the setup window is gone")
end)
