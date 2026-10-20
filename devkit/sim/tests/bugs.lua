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
