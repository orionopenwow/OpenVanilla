-- !Compat_112: 1.12 API shims the web client lacks, installed only when missing.
local T, api = ...

T.test("Compat: shims install only where the engine lacks the function", function()
    local env = T.addon("!Compat_112")
    T.eq(rawget(env, "UnitCanAssist"), nil, "real UnitCanAssist kept")
    local web = T.client({ name = "Web", missing = { "UnitCanAssist", "UnitIsTrivial" }, level = 60 })
    api.load_addon(web, api.repo .. "/Data/Interface/AddOns/!Compat_112")
    T.ok(rawget(web, "UnitCanAssist"), "shim installed")
    api.set_unit(web, "party1", { name = "Brakkus", class = "WARRIOR" })
    api.set_unit(web, "target", { name = "Hogger", hostile = true, isPlayer = false, level = 11 })
    T.eq(web.UnitCanAssist("player", "party1"), 1)
    T.eq(web.UnitCanAssist("player", "player"), 1)
    T.eq(web.UnitCanAssist("player", "target"), nil)
    T.eq(web.UnitCanAssist("player", "nobody"), nil)
end)

T.test("Compat: UnitIsTrivial follows the 1.12 grey-level rule", function()
    local function trivial(me, them)
        local env = T.client({ name = "P" .. me .. "_" .. them, missing = { "UnitIsTrivial" }, level = me })
        api.load_addon(env, api.repo .. "/Data/Interface/AddOns/!Compat_112")
        api.set_unit(env, "target", { name = "Mob", hostile = true, isPlayer = false, level = them })
        return env.UnitIsTrivial("target")
    end
    T.eq(trivial(60, 51), 1); T.eq(trivial(60, 52), nil)       -- 60: L - 9
    T.eq(trivial(45, 35), 1); T.eq(trivial(45, 36), nil)       -- 40..59: L - 1 - floor(L/5)
    T.eq(trivial(20, 13), 1); T.eq(trivial(20, 14), nil)       -- 6..39: L - 5 - floor(L/10)
    T.eq(trivial(5, 1), nil)                                   -- <= 5: nothing is grey
    T.eq(trivial(60, -1), nil)                                 -- skull: never trivial
end)

