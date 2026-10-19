-- Report: the shared "Report..." dialog (WenillaCore/Report.lua) - unit menu entry, chat names,
-- the dialog, the ".wnl report" line format, the client's own chat context, rate limits, the
-- offline queue, server answers, /appeal, and the hooks in Social, Persona, Dungeons and Guilds.
local T, api = ...

local function texts(env) return "," .. table.concat(api.menu_texts(env), ",") .. "," end

local function lastReport(env)
    for i = #env.__wnl, 1, -1 do
        if string.sub(env.__wnl[i], 1, 7) == "report " then return string.sub(env.__wnl[i], 8) end
    end
end

local function reports(env)
    local n = 0
    for _, l in ipairs(env.__wnl) do if string.sub(l, 1, 7) == "report " then n = n + 1 end end
    return n
end

-- the unescaped fields of a report line: category, name, note, { lines }
local function parse(env, line)
    local R = env.WenillaCore.Report
    local f = {}
    for part in string.gmatch(line .. ",", "([^,]*),") do table.insert(f, part) end
    local lines = {}
    for l in string.gmatch((f[4] or "") .. "\\n", "(.-)\\n") do if l ~= "" then table.insert(lines, R.Unescape(l)) end end
    return f[1], f[2], R.Unescape(f[3] or ""), lines
end

local function pickAndSend(env, i, note)
    api.click(env["WenillaCore_ReportCat" .. i])
    if note then api.type(env.WenillaCore_ReportNote, note) end
    api.click(api.find_button(env, "Send report", env.WenillaCore_ReportFrame))
end

T.test("Report: the unit menus offer Report... for other players (not yourself)", function()
    local env = T.addon("WenillaCore")
    local ann = T.client({ name = "Ann" })
    api.set_target(env, "Ann")
    T.ok(env.WenillaCore.UnitMenu.Open("target"))
    local t = texts(env)
    T.has(t, ",Report...,"); T.has(t, ",Cancel,")
    local m = env.UnitPopupMenus.PLAYER
    T.eq(m[#m], "CANCEL", "Cancel stays last")
    for _, which in ipairs({ "PLAYER", "PARTY", "RAID_PLAYER", "FRIEND" }) do
        local has = false
        for _, v in ipairs(env.UnitPopupMenus[which]) do if v == "WNL_REPORT" then has = true end end
        T.ok(has, which .. " has Report")
    end
    for _, v in ipairs(env.UnitPopupMenus.SELF) do T.no(v == "WNL_REPORT", "never on your own menu") end
    api.menu_click(env, "Report...")
    T.shown(env.WenillaCore_ReportFrame, "the dialog")
    T.eq(env.WenillaCore_ReportFrame.target, "Ann")
    T.ok(api.screen_has(env, "Report a player", env.WenillaCore_ReportFrame))
    T.ok(ann)
end)

T.test("Report: a chat name's right-click menu has Report... and opens the dialog", function()
    local env = T.addon("WenillaCore")
    api.right_click_name(env, "Bob")
    T.has(texts(env), ",Report...,")
    api.menu_click(env, "Report...")
    T.shown(env.WenillaCore_ReportFrame)
    T.eq(env.WenillaCore_ReportFrame.target, "Bob")
end)

T.test("Report: the dialog sends one .wnl report line with category, note and the chat it saw", function()
    local env = T.addon("WenillaCore")
    local ann = T.client({ name = "Ann" })
    api.connect(env, "1")
    ann.SendChatMessage("cheap gold, visit g0ld.example", "SAY")
    ann.SendChatMessage("hi there", "WHISPER", nil, env.__name)
    env.SendChatMessage("stop it", "WHISPER", nil, "Ann")
    ann.SendChatMessage("|cffff0000red|r and a pipe", "SAY")
    api.pump(env)
    env.WenillaCore.Report.Open("ann", "test")
    local f = env.WenillaCore_ReportFrame
    T.shown(f)
    T.eq(f.target, "Ann", "names are capitalised")
    T.has(f.lines:GetText(), "cheap gold", "the preview shows the recent lines")
    -- Send without a category: refused with a hint
    api.click(api.find_button(env, "Send report", f))
    T.shown(f)
    T.has(f.status:GetText(), "Pick what the report is about")
    T.eq(reports(env), 0)
    pickAndSend(env, 4, "spamming, all day")
    T.hidden(f, "closes after sending")
    local line = lastReport(env)
    T.ok(line, "a report line went up")
    T.ok(string.len(".wnl report " .. line) <= 255, "fits one chat line")
    T.lacks(line, "|", "no raw pipes")
    local cat, name, note, lines = parse(env, line)
    T.eq(cat, "gold-seller"); T.eq(name, "Ann")
    T.eq(note, "[test] spamming, all day", "commas survive escaping")
    T.eq(#lines, 4)
    T.eq(lines[1], "[say] Ann: cheap gold, visit g0ld.example")
    T.eq(lines[2], "[whisper] Ann > " .. env.__name .. ": hi there")
    T.eq(lines[3], "[whisper] " .. env.__name .. " > Ann: stop it")
    T.eq(lines[4], "[say] Ann: red and a pipe", "colour codes stripped")
    T.ok(api.screen_has(env, "A moderator will look"), "the thank-you toast")
end)

T.test("Report: long notes and chat are cut to one chat line, newest lines kept", function()
    local env = T.addon("WenillaCore")
    local R = env.WenillaCore.Report
    local lines = {}
    for i = 1, 8 do table.insert(lines, { kind = "say", from = "Spammer", text = "line " .. i .. " " .. string.rep("x,", 30) }) end
    local s = R.Format("spam", "spammer", string.rep("a", 300), lines)
    T.ok(string.len(".wnl report " .. s) <= 255, "fits: " .. string.len(s))
    T.eq(string.sub(s, 1, 13), "spam,Spammer,")
    T.has(s, "line 8", "the newest line survives")
    T.lacks(s, "line 1 ", "the oldest is dropped")
    local _, _, note = parse(env, s)
    T.eq(string.len(note), R.NOTE_MAX, "the note keeps NOTE_MAX characters")
    T.eq(R.Unescape(R.Escape("a,b\\c")), "a,b\\c", "escaping round-trips")
end)

T.test("Report: one per 30 seconds, ten per hour; yourself and unknown categories refused", function()
    local env = T.addon("WenillaCore")
    api.connect(env, "1")
    local R = env.WenillaCore.Report
    T.ok(R.Submit("spam", "Ann", "x"))
    local ok, why, secs = R.Submit("spam", "Bob", "x")
    T.no(ok); T.eq(why, "wait"); T.ok(secs and secs > 0 and secs <= 30)
    -- the dialog shows the wait
    R.Open("Bob")
    pickAndSend(env, 1)
    T.shown(env.WenillaCore_ReportFrame)
    T.has(env.WenillaCore_ReportFrame.status:GetText(), "Please wait")
    env.WenillaCore_ReportFrame:Hide()
    for i = 2, 10 do
        api.tick(env, 31, 1)
        T.ok(R.Submit("harassment", "Target" .. string.char(96 + i), "x"), "report " .. i)
    end
    api.tick(env, 31, 1)
    ok, why = R.Submit("spam", "Zed", "x")
    T.no(ok); T.eq(why, "hour", "the 11th in an hour")
    T.eq(reports(env), 10)
    api.tick(env, 3600, 10)
    T.ok(R.Submit("spam", "Zed", "x"), "allowed again an hour later")
    T.eq(select(2, R.Submit("spam", env.__name, "x")), "self")
    api.tick(env, 31, 1)
    T.eq(select(2, R.Submit("rude", "Ann", "x")), "category")
end)

T.test("Report: away from the server channel the report waits and goes up at the greeting", function()
    local env = T.addon("WenillaCore")
    local R = env.WenillaCore.Report
    R.Open("Ann")
    pickAndSend(env, 2, "kept following me")
    T.eq(reports(env), 0, "nothing said out loud")
    T.eq(#R.queue, 1)
    T.ok(api.screen_has(env, "Report saved"), "the toast says it is saved")
    T.ok(api.screen_has(env, "goes up when you are"))
    for _, m in ipairs(env.__chat_sent) do T.lacks(m.msg, "report", "no stray line in /say") end
    api.connect(env, "1")
    api.pump(env)
    T.eq(#R.queue, 0)
    local cat, name, note = parse(env, lastReport(env))
    T.eq(cat, "harassment"); T.eq(name, "Ann"); T.eq(note, "kept following me")
end)

T.test("Report: server answers and automatic actions; /appeal", function()
    local env = T.addon("WenillaCore")
    api.connect(env, "1")
    api.server_packet(env, "RP", "ok,17")
    T.eq(env.WenillaCore.Report.lastResult, "ok")
    api.server_packet(env, "RP", "err,ratelimit")
    T.ok(api.screen_has(env, "too many reports"))
    env.__slash("/appeal I was only trading, honest")
    T.eq(env.__wnl[#env.__wnl], "appeal I was only trading, honest")
    T.has(api.chat_text(env), "Appeal sent")
    env.__slash("/appeal")
    T.has(api.chat_text(env), "/appeal <what")
    -- /report with a target, and with a name
    local ann = T.client({ name = "Ann" })
    api.set_target(env, "Ann")
    env.__slash("/report")
    T.eq(env.WenillaCore_ReportFrame.target, "Ann")
    env.__slash("/report bob")
    T.eq(env.WenillaCore_ReportFrame.target, "Bob")
    T.ok(ann)
end)

T.test("Report: Social's person menu, Persona's profile and the Dungeons board open the dialog", function()
    local A = T.addon("Social", { name = "Aldric" })
    A.Social.PersonMenu(A.UIParent, "Berra", {})
    api.click_text(A, "Report...", A.WenillaCore_Menu)
    T.shown(A.WenillaCore_ReportFrame)
    T.eq(A.WenillaCore_ReportFrame.target, "Berra")
    T.eq(A.WenillaCore_ReportFrame.context, "social")

    local P = T.addon("Persona", { name = "Corin" })
    P.Persona.ShowView("Dara")
    T.shown(P.PersonaFrame.view.report, "a Report button on someone else's profile")
    api.click(P.PersonaFrame.view.report)
    T.eq(P.WenillaCore_ReportFrame.target, "Dara")
    P.Persona.ShowView("Corin")
    T.hidden(P.PersonaFrame.view.report, "not on your own")
end)

T.test("Report: right-clicking a Dungeons listing offers Report...", function()
    local A = T.addon("Dungeons", { name = "Brakkus", class = "WARRIOR", level = 22,
        party = { { name = "Saria", class = "PRIEST", level = 21 } }, map = { x = 0.5, y = 0.5, zone = "Westfall" } })
    local B = T.addon("Dungeons", { name = "Herald", class = "HUNTER", level = 19, map = { x = 0.4, y = 0.6, zone = "Elwynn Forest" } })
    api.tick(A, 9)
    A.__slash("/lfg list")
    for i = 1, 12 do
        local row = A["Dungeons_Pick" .. i]
        if row and row:IsVisible() and row.item and row.item.name == "The Deadmines" then api.click(row) break end
    end
    api.click(A.Dungeons.mine.listBtn)
    api.tick(A, 2)
    B.__slash("/lfg browse")
    local row = B.Dungeons_BoardRow1
    T.shown(row)
    api.click(row, "RightButton")
    api.click_text(B, "Report...", B.WenillaCore_Menu)
    T.eq(B.WenillaCore_ReportFrame.target, "Brakkus")
    T.eq(B.WenillaCore_ReportFrame.context, "dungeons")
end)

T.test("Report: right-clicking a Guilds listing card reports its poster; left click still applies", function()
    local A = T.addon("Guilds", { name = "Aldric", class = "WARRIOR", level = 60, guild = { name = "Ashen Vanguard", members = 38 } })
    local B = T.addon("Guilds", { name = "Berra", class = "HUNTER", level = 12 })
    api.tick(A, 7)
    A.__slash("/guilds")
    api.click(A.Concord_Frame.tabs:Button("mine"))
    api.type(A.Concord_PostLevel, "40")
    api.type(A.Concord_PostPitch, "Molten Core Tue/Thu 8pm")
    api.click(api.find_button(A, "Post"))
    api.pump(A)
    B.__slash("/concord")
    local c = B.Concord_Card1
    T.shown(c)
    api.click(c, "RightButton")
    T.ok(api.screen_has(B, "Report Aldric...", B.WenillaCore_Menu))
    api.click_text(B, "Report Aldric...", B.WenillaCore_Menu)
    T.eq(B.WenillaCore_ReportFrame.target, "Aldric")
    T.eq(B.WenillaCore_ReportFrame.context, "guilds")
    -- left click still applies (the stock popup)
    B.WenillaCore_ReportFrame:Hide()
    api.click(c)
    T.eq(B.Concord.applyTarget and B.Concord.applyTarget.poster, "Aldric")
end)
