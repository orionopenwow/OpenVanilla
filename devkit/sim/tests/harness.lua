-- Self-tests of the fake 1.12 API itself, so a passing addon test means something.
local T, api = ...

-- Run a snippet as if it were addon code in env; returns ok, err.
local function run(env, src)
    local chunk = assert(loadstring(src, "=snippet"))
    setfenv(chunk, env)
    return xpcall(chunk, api.traceback)
end

T.test("Harness: unknown globals fail loudly and say whose bug it is", function()
    local env = T.client()
    local ok, err = run(env, "GetFooBarBaz()")
    T.no(ok); T.has(err, "fake API missing: GetFooBarBaz (not a 1.12 global either")
    ok, err = run(env, "GetPetitionInfo()")
    T.no(ok); T.has(err, "fake API missing: GetPetitionInfo (real 1.12 engine function")
    ok, err = run(env, "hooksecurefunc('X', function() end)")
    T.no(ok); T.has(err, "1.12 has no hooksecurefunc")
    ok = run(env, "assert(hooksecurefunc == nil and select == nil and C_Timer == nil and print == nil)")
    T.ok(ok, "post-1.12 names read as nil, so feature tests take the 1.12 path")
end)

T.test("Harness: Lua 5.0 library shape and WoW globals", function()
    local env = T.client()
    T.ok(run(env, [[
        assert(string.gmatch == nil and string.match == nil and math.fmod == nil and table.maxn == nil)
        assert(string.gfind and math.mod(7, 3) == 1 and table.getn({1, 2}) == 2)
        assert(strfind("abc", "b") == 2 and strlen("abc") == 3 and strupper("a") == "A" and getn({1}) == 1)
        assert(mod(7, 3) == 1 and floor(1.5) == 1 and format("%d", 3) == "3")
        assert(math.abs(sin(90) - 1) < 1e-9, "global sin works in degrees")
        assert(bit.band(6, 3) == 2 and bit.bor(4, 1) == 5)
        for w in string.gfind("a b", "%a") do end
        local t = { "a", "b", "c", n = 1 }                 -- 5.0: an 'n' field is the size
        assert(getn(t) == 1 and table.getn({ 1, nil, 3 }) == 1)
        tinsert(t, "x")
        assert(t[2] == "x" and t.n == 2)
        assert(unpack({ 1, 2, n = 1 }) == 1 and select == nil)
        local n = 0
        for k in pairs({ 1, 2, 3 }) do n = n + 1 end
        assert(n == 3)
    ]]))
end)

T.test("Harness: string methods fail in addon code, as in Lua 5.0", function()
    local env = T.client()
    local ok, err = run(env, "local s = 'abc'; return s:upper()")
    T.no(ok); T.has(err, "Lua 5.0 strings have no methods: s:upper()")
    T.eq(("abc"):upper(), "ABC", "harness code keeps its string methods")
end)

T.test("Harness: widgets are permissive only for real 1.12 methods", function()
    local env = T.client()
    local f = env.CreateFrame("Frame", "HarnessFrame", env.UIParent)
    T.eq(env.HarnessFrame, f, "named frames become globals")
    f:SetMaxResize(400, 300)                               -- real 1.12, not modelled: no-op
    T.ok(env.__unknown_methods.SetMaxResize)
    T.eq(f.SetShown, nil, "SetShown is not 1.12: nil like the real client")
    local ok, err = run(env, "HarnessFrame:SetShown(true)")
    T.no(ok); T.has(err, "SetShown is not a 1.12 widget method")
    T.eq(f.someField, nil, "lower-case fields are plain nil")
    local ok2, err2 = pcall(env.CreateFrame, "Fraem")
    T.no(ok2); T.has(err2, "Unknown frame type")
    f:RegisterEvent("NOT_AN_EVENT")
    T.expect_error(env, "not a 1.12 event")
end)

T.test("Harness: events, OnUpdate, OnShow/OnHide and clicks behave like 1.12", function()
    local env = T.client()
    local seen = {}
    local f = env.CreateFrame("Frame", nil, env.UIParent)
    f:RegisterEvent("BAG_UPDATE")
    f:SetScript("OnEvent", function() table.insert(seen, env.event .. ":" .. tostring(env.arg1) .. ":" .. tostring(env.this == f)) end)
    api.fire(env, "BAG_UPDATE", 3)
    T.eq(seen[1], "BAG_UPDATE:3:true")
    local child = env.CreateFrame("Frame", nil, f)
    local ticks, shows, hides = 0, 0, 0
    child:SetScript("OnUpdate", function() ticks = ticks + env.arg1 end)
    child:SetScript("OnShow", function() shows = shows + 1 end)
    child:SetScript("OnHide", function() hides = hides + 1 end)
    api.tick(env, 1)
    T.near(ticks, 1, 1e-9, "OnUpdate gets elapsed in arg1")
    f:Hide()
    T.eq(hides, 1, "hiding the parent hides the child")
    api.tick(env, 1)
    T.near(ticks, 1, 1e-9, "hidden frames do not update")
    f:Show()
    T.eq(shows, 1)
    local cb = env.CreateFrame("CheckButton", "HarnessCheck", env.UIParent, "UICheckButtonTemplate")
    local state
    cb:SetScript("OnClick", function() state = cb:GetChecked() end)
    api.click(cb)
    T.eq(state, 1, "a click ticks the box before OnClick")
    api.click(cb)
    T.eq(state, nil)
    local eb = env.CreateFrame("EditBox", nil, env.UIParent)
    eb:SetMaxLetters(5)
    local changed = 0
    eb:SetScript("OnTextChanged", function() changed = changed + 1 end)
    eb:SetText("abcdefgh")
    T.eq(eb:GetText(), "abcde"); T.eq(changed, 1)
    T.eq(env.GetTime() > 1000, true)
end)

T.test("Harness: slash parsing matches ChatEdit_ParseText", function()
    local env = T.client()
    local got
    env.SLASH_HARNESS1 = "/hx"
    env.SlashCmdList.HARNESS = function(msg) got = msg end
    T.ok(env.__slash("/HX  two  words"))
    T.eq(got, " two  words", "everything after the first space, untrimmed")
    T.ok(env.__slash("/hx"))
    T.eq(got, "")
    T.no(env.__slash("/nothing"))
end)

T.test("Harness: chat bus trims, collapses, refuses raw pipes and long lines", function()
    local A = T.client({ name = "A" })
    local B = T.client({ name = "B" })
    local got = {}
    local f = B.CreateFrame("Frame")
    f:RegisterEvent("CHAT_MSG_CHANNEL")
    f:SetScript("OnEvent", function() table.insert(got, B.arg1) end)
    A.JoinChannelByName("Test"); B.JoinChannelByName("Test")
    A.SendChatMessage("  a    b  ", "CHANNEL", nil, A.GetChannelName("Test"))
    api.pump(A)
    T.eq(got[1], "a b")
    A.SendChatMessage("x|y", "CHANNEL", nil, A.GetChannelName("Test"))
    T.expect_error(A, "raw '|'")
    A.SendChatMessage(string.rep("x", 300), "SAY")
    T.expect_error(A, "1.12 limit is 255")
    A.SendAddonMessage("P", "m", "WHISPER")
    T.expect_error(A, "not a 1.12 addon channel")
    local quiet = api.new_bus({ collapse_spaces = false, trim = false })
    T.eq(quiet:serverText("  a  b "), "  a  b ")
end)

T.test("Harness: server packets chunk and greet; relog keeps SavedVariables", function()
    local env = T.addon("WenillaCore")
    local got
    env.WenillaCore:RegisterModule("ZZ", function(b) got = b end)
    api.server_packet(env, "ZZ", string.rep("x", 50), { chunk = 20 })
    T.eq(got, string.rep("x", 50))
    T.ok(env.WenillaCore.connected, "the first packet greets with HI")
    env.WenillaCore_Config.settings.Meters = { maxRows = 3 }
    local again = T.relog(env)
    T.eq(again.WenillaCore_Config.settings.Meters.maxRows, 3)
    T.no(again.WenillaCore.connected, "a new session waits for a new HI")
end)
