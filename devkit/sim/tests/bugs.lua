-- WenillaCore/Bugs.lua: the blue bug button by the chat -> ".wnl bug ..." -> the realm -> Discord.
local T, api = ...

local function last(env) return env.__wnl[table.getn(env.__wnl)] end

T.test("Bugs: a blue bug button sits right of the chat frame and opens the report window", function()
    local env = T.addon("WenillaCore")
    local b = env.WenillaCore_BugButton
    T.shown(b)
    local p, rel, rp = b:GetPoint(1)
    T.eq(p, "BOTTOMLEFT"); T.eq(rel, env.ChatFrame1); T.eq(rp, "BOTTOMRIGHT", "outside the chat, on its right")
    api.click(b)
    T.shown(env.WenillaCore_BugFrame)
    api.click(b)
    T.hidden(env.WenillaCore_BugFrame, "the button toggles the window")
end)

T.test("Bugs: nothing to send, or a realm without the channel, is said plainly", function()
    local env = T.addon("WenillaCore")
    local B = env.WenillaCore.Bugs
    B.Open()
    T.no(B.Send(), "empty text is refused")
    T.has(env.WenillaCore_BugFrame.status:GetText(), "Say what went wrong")
    api.type(env.WenillaCore_BugNote, "The door won't open")
    T.no(B.Send(), "not greeted by the realm")
    T.has(env.WenillaCore_BugFrame.status:GetText(), "#bug-reports")
    T.eq(table.getn(env.__wnl), 0, "nothing said out loud")
end)

T.test("Bugs: Send puts one escaped line up, and the realm's ok closes the window", function()
    local env = T.addon("WenillaCore")
    local B = env.WenillaCore.Bugs
    api.connect(env, "1")
    B.Open()
    api.click(env.WenillaCore_BugCat1)                       -- Quest or NPC
    api.type(env.WenillaCore_BugNote, "McBride, Marshal won't take it")
    T.ok(B.Send())
    local line = last(env)
    T.has(line, "bug quest,McBride\\c Marshal won't take it,", "category, then the text with its comma escaped")
    T.has(line, "addons ", "the context rides along")
    T.ok(string.len(".wnl " .. line) <= 255)
    api.server_packet(env, "BG", "ok")
    T.hidden(env.WenillaCore_BugFrame)
    T.has(api.chat_text(env), "Bug report sent")
end)

T.test("Bugs: one report a minute, and an over-long one is cut to one chat line", function()
    local env = T.addon("WenillaCore")
    local B = env.WenillaCore.Bugs
    api.connect(env, "1")
    B.Open()
    api.type(env.WenillaCore_BugNote, "first")
    T.ok(B.Send())
    api.server_packet(env, "BG", "ok")
    B.Open()
    api.type(env.WenillaCore_BugNote, "second")
    T.no(B.Send(), "a minute between reports")
    T.has(env.WenillaCore_BugFrame.status:GetText(), "One report a minute")
    local long = string.rep("a,", 300)
    local l = B.Line("other", long, "Elwynn Forest · 41.0, 65.2 · addons 1.1.0")
    T.ok(string.len(".wnl " .. l) <= 255, "fits one line")
    T.has(l, ",Elwynn Forest", "the context is kept whole")
end)

T.test("Bugs: no answer from the realm in 10 s says so", function()
    local env = T.addon("WenillaCore")
    local B = env.WenillaCore.Bugs
    api.connect(env, "1")
    B.Open()
    api.type(env.WenillaCore_BugNote, "lag spike in Goldshire")
    T.ok(B.Send())
    api.tick(env, 11, 0.5)
    T.has(env.WenillaCore_BugFrame.status:GetText(), "No answer from the realm")
    api.server_packet(env, "BG", "err,ratelimit")
    T.has(env.WenillaCore_BugFrame.status:GetText(), "a lot of reports today")
end)

T.test("Bugs: the note is a real text field: it has focus on open, a click anywhere in it focuses it, Enter sends", function()
    local env = T.addon("WenillaCore")
    local B = env.WenillaCore.Bugs
    api.connect(env, "1")
    B.Open()
    local e, well = env.WenillaCore_BugNote, env.WenillaCore_BugNoteWell
    T.eq(env.__focus, e, "the cursor is in the note when the window opens")
    T.eq(api.state(e).multiLine, true, "several lines")
    T.eq(e:GetParent(), env.WenillaCore_BugNoteScroll, "a scroll child, the only way 1.12 lays out a multi-line box")
    T.shown(env.WenillaCore_BugFrame.hint)
    env.__focus = nil
    api.click(well)
    T.eq(env.__focus, e, "clicking the box puts the cursor in it")
    api.type(e, "Stuck in the floor")
    T.hidden(env.WenillaCore_BugFrame.hint, "the hint goes once you type")
    T.has(env.WenillaCore_BugFrame.count:GetText(), "18 / 220")
    api.press_enter(e)
    T.has(last(env), "bug other,Stuck in the floor,", "Enter sends")
end)

T.test("Bugs: '/bug <text>' sends straight from chat, a first word picks the category", function()
    local env = T.addon("WenillaCore")
    api.connect(env, "1")
    local n = table.getn(env.__wnl)
    env.SlashCmdList["WNLBUG"]("quest Marshal McBride won't take it")
    T.eq(table.getn(env.__wnl), n + 1, "one report went up")
    T.has(env.__wnl[table.getn(env.__wnl)], "bug quest,Marshal McBride won't take it,", "category from the first word")
    env.WenillaCore.Bugs.lastSent = nil
    env.SlashCmdList["WNLBUG"]("the bank door is stuck")
    T.has(env.__wnl[table.getn(env.__wnl)], "bug other,the bank door is stuck,", "no category word: other")
    n = table.getn(env.__wnl)
    env.SlashCmdList["WNLBUG"]("")
    T.eq(table.getn(env.__wnl), n, "plain /bug only opens the window")
    T.shown(env.WenillaCore_BugFrame)
end)

T.test("Bugs: the context says the frame rate, the latency and whether Herald was playing", function()
    local env = T.addon("WenillaCore")
    env.GetFramerate = function() return 23.6 end
    env.GetNetStats = function() return 0, 0, 78 end
    local ctx = env.WenillaCore.Bugs.Context()
    T.has(ctx, "24 fps 78 ms", "for lag reports (players' reports, 2026-10-21)")
    T.lacks(ctx, "Herald")
    env.Herald_IsPlaying = function() return true end
    T.has(env.WenillaCore.Bugs.Context(), "Herald on")
    T.ok(string.len(env.WenillaCore.Bugs.Context()) <= 120)
end)
