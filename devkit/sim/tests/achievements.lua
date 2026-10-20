-- Achievements: the window, the AC packets, progress maths, filters, the banner, compare,
-- chat links, the tracker, realm firsts, the saved cache and the Y binding.
local T, api = ...

local function rowNames(env)
    local out = {}
    for i = 1, 7 do
        local r = env["Achievements_Row" .. i]
        if r and r:IsVisible() then table.insert(out, r.name:GetText()) end
    end
    return out
end

local function byName(env, name)
    for _, a in ipairs(env.Achievements_Data.list) do if a.n == name then return a end end
    error("no achievement called " .. name)
end

local function open(env)
    if not env.Achievements_Frame or not env.Achievements_Frame:IsShown() then env.__slash("/ach") end
    T.shown(env.Achievements_Frame, "achievements window")
end

T.test("Achievements: the catalogue is complete and the window opens on the summary", function()
    local env = T.addon("Achievements", { name = "Aldric", race = "Human", faction = "Alliance", class = "WARRIOR", level = 60 })
    local A = env.Achievements
    T.ok(table.getn(env.Achievements_Data.list) >= 250, "about 250+ achievements")
    T.eq(table.getn(env.Achievements_Data.categories), 9)
    open(env)
    T.eq(env.Achievements_Frame.title:GetText(), "Achievements")
    T.eq(env.Achievements.header:GetText(), "Summary")
    T.shown(env.Achievements_Summary, "summary page")
    T.ok(api.screen_has(env, "Overall progress", env.Achievements_Frame))
    T.ok(api.screen_has(env, "Nothing earned yet", env.Achievements_Frame))
    T.ok(api.screen_has(env, "0 of ", env.Achievements_Frame), "overall bar text")
    -- every category button, with counts
    T.eq(env.Achievements_Cat1.label:GetText(), "Summary")
    T.eq(env.Achievements_Cat2.label:GetText(), "General")
    T.eq(env.Achievements_Cat10.label:GetText(), "Feats of Strength")
    T.ok(string.find(env.Achievements_Cat3.count:GetText(), "^0/%d+$"), "quests count")
    -- Escape closes it
    T.ok(api.press_escape(env))
    T.hidden(env.Achievements_Frame)
end)

T.test("Achievements: offline it shows the whole catalogue, nothing earned, and a note", function()
    local env = T.addon("Achievements", { faction = "Alliance", class = "WARRIOR", level = 12 })
    open(env)
    T.has(env.Achievements.note:GetText(), "Achievements are kept by the realm")
    api.click(env.Achievements_Cat2)
    T.eq(env.Achievements.header:GetText(), "General")
    T.eq(env.Achievements_Row1.name:GetText(), "Level 10")
    T.eq(env.Achievements_Row1.date:GetText() or "", "", "nothing earned")
    T.eq(env.Achievements.pointsText:GetText(), "0")
    -- local readings still move the bars: level 12 of 20
    T.eq(env.Achievements_Row2.bar.right:GetText(), "Level: 12/20")
    T.eq(#env.__wnl, 0, "nothing is sent without a realm")
end)

T.test("Achievements: Y is bound on first login unless taken, and Bindings.xml calls the toggle", function()
    local f = io.open(api.repo .. "/Data/Interface/AddOns/Achievements/Bindings.xml")
    local xml = f:read("*a"); f:close()
    T.has(xml, 'name="ACHIEVEMENTS_TOGGLE"')
    T.has(xml, "Achievements_Toggle();")
    local env = T.addon("Achievements")
    T.eq(env.GetBindingAction("Y"), "ACHIEVEMENTS_TOGGLE")
    T.eq(env.__bindings_saved, 2, "saved to the character binding set")
    T.eq(env.BINDING_NAME_ACHIEVEMENTS_TOGGLE, "Toggle the Achievements window")
    env.Achievements_Toggle()
    T.shown(env.Achievements_Frame)
    env.Achievements_Toggle()
    T.hidden(env.Achievements_Frame)
    -- the player's own Y binding is left alone
    local other = T.client({ name = "Berra" })
    other.SetBinding("Y", "TOGGLEBACKPACK")
    api.load_with_deps(other, "Achievements")
    api.login(other)
    T.eq(other.GetBindingAction("Y"), "TOGGLEBACKPACK")
    T.eq(other.GetBindingKey("ACHIEVEMENTS_TOGGLE"), nil)
    -- and once unbound on purpose, it stays unbound after a relog
    env.SetBinding("Y", "")
    env = T.relog(env)
    T.eq(env.GetBindingAction("Y"), "")
end)

T.test("Achievements: L, E, P and C packets drive the list, points and bars", function()
    local env = T.addon("Achievements", { name = "Aldric", faction = "Alliance", class = "WARRIOR", level = 60 })
    local A = env.Achievements
    api.server_packet(env, "AC", "L 1,1767268800;2,1767355200;3,1767441600")
    T.ok(A.synced)
    T.eq(A.Points(), 30)
    open(env)
    T.eq(A.pointsText:GetText(), "30")
    T.ok(api.screen_has(env, "Level 30", env.Achievements_Summary), "recent tile")
    T.ok(api.screen_has(env, "3 of ", env.Achievements_Summary))
    api.click(env.Achievements_Cat2)
    T.eq(env.Achievements_Row1.date:GetText(), "01/01/26")
    T.eq(env.Achievements_Row1.points:GetText(), "10")
    -- just earned: the banner, the sound, a chat line
    api.server_packet(env, "AC", "E 4,1767528000")
    T.ok(A.earned[4])
    T.eq(A.Points(), 40)
    T.shown(env.Achievements_Toast, "banner")
    T.eq(env.Achievements_Toast.name:GetText(), "Level 40")
    T.eq(env.Achievements_Toast.head:GetText(), "Achievement Earned")
    T.eq(env.Achievements_Toast.points:GetText(), "10")
    T.has(env.__sounds, "Sound\\Interface\\LevelUp.wav")
    T.has(api.chat_text(env), "You earned [Achievement: Level 40] (10 points)!")
    T.eq(env.Achievements_Row4.date:GetText(), "04/01/26")
    api.tick(env, 6)
    T.hidden(env.Achievements_Toast, "the banner fades away")
    -- an E for something already earned does nothing
    local n = #env.__sounds
    api.server_packet(env, "AC", "E 4,1767528000")
    T.eq(#env.__sounds, n)
    -- P: "Quests: 312/1000"
    api.server_packet(env, "AC", "P 104,312;100,40")
    api.click(env.Achievements_Cat3)
    local rows = rowNames(env)
    T.eq(rows[1], "Fifty Quests")
    T.eq(env.Achievements_Row1.bar.right:GetText(), "Quests: 40/50")
    T.eq(env.Achievements_Row5.bar.right:GetText(), "Quests: 312/1,000")
    T.near(env.Achievements_Row5.bar.bar:GetValue(), 0.312, 1e-6)
    -- C: one of the Four Horsemen
    local fh = byName(env, "The Four Horsemen")
    api.server_packet(env, "AC", "C " .. fh.cr[1].id .. ",1;" .. fh.cr[3].id .. ",1")
    T.eq(A.ProgressText(fh), "Bosses: 2/4")
    -- a long list arrives in chunks
    local parts = {}
    for i = 300, 321 do table.insert(parts, i .. ",1767528000") end
    api.server_packet(env, "AC", "L " .. table.concat(parts, ";"), { chunk = 60 })
    T.ok(A.earned[321] and A.earned[300])
    T.eq(A.earned[1], nil, "L replaces the list")
end)

T.test("Achievements: progress maths - local readings, faction goals, steps and caps", function()
    local env = T.addon("Achievements", { name = "Grom", faction = "Horde", race = "Orc", class = "WARRIOR", level = 37, money = 1234567,
        skills = { { "Alchemy", 120, 150 }, { "Riding", 75, 75 } }, factions = { { "Orgrimmar", 8 }, { "Thunder Bluff", 7 }, { "Undercity", 8 } }, hk = 250 })
    local A = env.Achievements
    T.eq(A.ProgressText(4), "Level: 37/40")
    T.eq(A.ProgressText(13), "Gold: 100/100", "123 gold capped at the goal")
    T.eq(A.ProgressText(14), "Gold: 123/1,000")
    T.eq(A.ProgressText(byName(env, "Master Alchemist")), "Alchemy: 120/300")
    T.eq(A.ProgressText(byName(env, "Five Exalted Reputations")), "Exalted: 2/5")
    T.eq(A.ProgressText(byName(env, "1,000 Honorable Kills")), "Honorable kills: 250/1,000")
    -- the server's figure wins when it is higher, and a local one when that is
    api.server_packet(env, "AC", "P 14,500")
    T.eq(A.ProgressText(14), "Gold: 500/1,000")
    -- zone quests count to the player's side
    local barrens = byName(env, "The Barrens Quests")
    T.ok(barrens.ga ~= barrens.gh, "different goals per side")
    local v, g = A.Progress(barrens)
    T.eq(g, barrens.gh)
    -- exploration: the server sends the goal
    api.server_packet(env, "AC", "P 330,9,12")
    T.eq(A.ProgressText(330), "Areas: 9/12")
    -- metas count earned achievements
    local mc = byName(env, "Molten Core")
    T.eq(A.ProgressText(mc), "Bosses: 0/10")
    api.server_packet(env, "AC", "L 500,1;501,1;502,1")
    T.eq(A.ProgressText(mc), "Bosses: 3/10")
    -- earned means full; plain yes/no achievements have no bar
    T.eq(A.ProgressText(500), nil)
    api.server_packet(env, "AC", "E 4,1767528000")
    T.eq(A.ProgressText(4), "Level: 40/40")
    T.ok(A.IsClose(14), "500 of 1000 gold is close")
    T.no(A.IsClose(4), "earned is not close")
    T.no(A.IsClose(byName(env, "A Thousand Quests")))
end)

T.test("Achievements: filters, search and who sees what", function()
    local env = T.addon("Achievements", { name = "Grom", faction = "Horde", race = "Orc", class = "WARLOCK", level = 25 })
    local A = env.Achievements
    api.server_packet(env, "AC", "L 1,1767268800;2,1767355200")
    open(env)
    api.click(env.Achievements_Cat2)
    A.filterTabs:Select("earned")
    T.eq(table.concat(rowNames(env), ","), "Level 10,Level 20")
    A.filterTabs:Select("unearned")
    T.eq(rowNames(env)[1], "Level 30")
    A.filterTabs:Select("close")
    T.eq(rowNames(env)[1], "Level 30", "25 of 30 is close")
    T.lacks(table.concat(rowNames(env), ","), "Level 60", "25 of 60 is not")
    A.filterTabs:Select("all")
    -- search runs over every category
    api.type(env.Achievements_Search, "ragnaros")
    T.has(A.header:GetText(), "Search:")
    local found = table.concat(rowNames(env), ",")
    T.has(found, "Ragnaros")
    T.has(found, "Molten Core")
    T.has(found, "Sulfuras, Hand of Ragnaros")
    api.type(env.Achievements_Search, "zzzz nothing")
    T.shown(A.empty)
    T.eq(A.empty:GetText(), "No achievements match your search.")
    api.type(env.Achievements_Search, "")
    -- faction and class: a Horde warlock sees the Dreadsteed, not Stormwind or the Charger
    T.ok(A.Visible(byName(env, "Dreadsteed of Xoroth")))
    T.no(A.Visible(byName(env, "Summon Charger")))
    T.no(A.Visible(byName(env, "Exalted with Stormwind")))
    T.ok(A.Visible(byName(env, "Exalted with Orgrimmar")))
    T.no(A.Visible(byName(env, "Elwynn Forest Quests")), "Alliance-only zone quests")
    local e, t = A.CategoryStats("reputation")
    local all = table.getn(A.byCat.reputation)
    T.ok(t < all, "the other side's reputations are not counted")
end)

T.test("Achievements: compare with another player (slash, unit menu, I packet)", function()
    local env = T.addon("Achievements", { name = "Aldric", faction = "Alliance", class = "PALADIN" })
    local A = env.Achievements
    api.server_packet(env, "AC", "L 1,1767268800;2,1767268800")
    env.__slash("/ach compare berra")
    T.eq(env.__wnl[#env.__wnl], "ac inspect Berra")
    api.server_packet(env, "AC", "I Berra,5,35;1,1767268800;5,1767614400;560,1767700800")
    T.ok(A.compare)
    T.eq(A.compare.name, "Berra")
    T.eq(A.compare.points, 35)
    T.shown(env.Achievements_Frame, "the window opens to compare")
    T.has(env.Achievements_Summary.compare:GetText(), "Comparing with Berra: 35 points against your 20.")
    api.click(env.Achievements_Cat2)
    T.eq(env.Achievements_Row1.other:GetText(), "Berra: 01/01/26")
    T.eq(env.Achievements_Row2.other:GetText(), "Berra: -")
    api.enter(env.Achievements_Row5)
    T.has(api.tooltip_text(env), "Berra: earned 05/01/26")
    T.eq(A.compareButton:GetText(), "Stop comparing")
    api.click(A.compareButton)
    T.eq(A.compare, nil)
    T.hidden(env.Achievements_Row1.other)
    -- nobody by that name
    env.__slash("/ach inspect Nobody")
    api.server_packet(env, "AC", "I Nobody,-")
    T.has(api.chat_text(env), "nobody called Nobody was found")
    -- the right-click unit menu
    T.ok(env.UnitPopupButtons.ACHIEVEMENTS_COMPARE)
    local m = env.UnitPopupMenus.PLAYER
    T.eq(m[#m - 1], "ACHIEVEMENTS_COMPARE", "just above Cancel")
    env.ClassicPlusTestDropDown = { name = "Kael" }
    env.UIDROPDOWNMENU_INIT_MENU = "ClassicPlusTestDropDown"
    env.this = { value = "ACHIEVEMENTS_COMPARE" }
    env.UnitPopup_OnClick()
    T.eq(env.__wnl[#env.__wnl], "ac inspect Kael")
    -- other menu entries still reach the stock handler
    env.this = { value = "WHISPER" }
    env.UnitPopup_OnClick()
    T.eq(env.__unitpopup_clicked, "WHISPER")
end)

T.test("Achievements: compare needs a realm and a name", function()
    local env = T.addon("Achievements", { name = "Aldric" })
    env.__slash("/ach compare")
    T.has(api.chat_text(env), "compare with whom?")
    env.__slash("/ach compare Berra")
    T.has(api.chat_text(env), "comparing needs an Open Vanilla realm")
    T.eq(#env.__wnl, 0)
end)

T.test("Achievements: Shift-click links an achievement in chat as plain text", function()
    local env = T.addon("Achievements", { faction = "Alliance" })
    local A = env.Achievements
    T.eq(A.LinkText(1), "[Achievement: Level 10]")
    open(env)
    api.click(env.Achievements_Cat2)
    -- chat closed: it opens with the link
    env.__keys.shift = true
    api.click(env.Achievements_Row1)
    T.eq(env.__opened_chat[#env.__opened_chat], "[Achievement: Level 10]")
    -- chat open: inserted at the cursor
    env.ChatFrameEditBox:Show()
    env.ChatFrameEditBox:SetText("look: ")
    api.click(env.Achievements_Row2)
    T.eq(env.ChatFrameEditBox:GetText(), "look: [Achievement: Level 20]")
    env.__keys.shift = nil
    -- the line can be sent (no raw pipes)
    env.SendChatMessage(env.ChatFrameEditBox:GetText(), "SAY")
    -- right-click menu offers Link too
    api.click(env.Achievements_Row3, "RightButton")
    T.shown(env.WenillaCore_Menu)
    env.ChatFrameEditBox:SetText("")
    api.click_text(env, "Link in chat", env.WenillaCore_Menu)
    T.eq(env.ChatFrameEditBox:GetText(), "[Achievement: Level 30]")
end)

T.test("Achievements: tracker (up to five), the menu, and the API other trackers use", function()
    local env = T.addon("Achievements", { faction = "Alliance", class = "WARRIOR", level = 23 })
    local A = env.Achievements
    api.server_packet(env, "AC", "L 1,1767268800")
    local calls = 0
    A.OnTrackedChanged(function() calls = calls + 1 end)
    open(env)
    api.click(env.Achievements_Cat2)
    api.click(env.Achievements_Row3, "RightButton")
    api.click_text(env, "Track", env.WenillaCore_Menu)
    T.ok(A.IsTracked(3))
    T.ok(calls > 0, "listeners hear about it")
    T.shown(env.Achievements_Tracker)
    T.eq(env.Achievements_TrackerLine1.name:GetText(), "Level 30")
    T.eq(env.Achievements_TrackerLine1.bar.right:GetText(), "Level: 23/30")
    T.shown(env.Achievements_Row3.track, "tick on the row")
    -- earned ones can't be tracked; at most five
    T.no(A.Track(1))
    for _, id in ipairs({ 4, 5, 6, 13 }) do T.ok(A.Track(id)) end
    T.no(A.Track(14), "a sixth is refused")
    T.has(api.chat_text(env), "up to 5 at once")
    local list = A.Tracked()
    T.eq(table.getn(list), 5)
    T.eq(list[1].name, "Level 30")
    T.eq(list[1].value, 23)
    T.eq(list[1].goal, 30)
    -- earning one takes it off the tracker
    api.server_packet(env, "AC", "E 3,1767528000")
    T.no(A.IsTracked(3))
    T.eq(env.Achievements_TrackerLine1.name:GetText(), "Level 40")
    -- right-click a tracker line to stop tracking
    api.click(env.Achievements_TrackerLine1, "RightButton")
    T.no(A.IsTracked(4))
    -- another addon can draw the list instead
    A.UseExternalTracker(true)
    T.hidden(env.Achievements_Tracker)
    A.UseExternalTracker(false)
    T.shown(env.Achievements_Tracker)
    -- the Tracker switch hides it
    env.WenillaCore:Settings("Achievements").showTracker = false
    A.Changed("settings")
    T.hidden(env.Achievements_Tracker)
end)

T.test("Achievements: without the banner art the suite toast is used", function()
    local env = T.addon("Achievements", { art = false, faction = "Alliance" })
    api.server_packet(env, "AC", "L ")
    api.server_packet(env, "AC", "E 1,1767268800")
    T.hidden(env.Achievements_Toast)
    T.ok(api.screen_has(env, "Level 10  (10 points)"), "UI.Toast text")
    T.ok(api.screen_has(env, "Achievement Earned"))
    -- banner off in settings: no banner, no sound, still the chat line
    env.WenillaCore:Settings("Achievements").toasts = false
    local n = #env.__sounds
    api.server_packet(env, "AC", "E 2,1767268800")
    T.eq(#env.__sounds, n)
    T.has(api.chat_text(env), "You earned [Achievement: Level 20]")
end)

T.test("Achievements: banners queue, and clicking one opens the achievement", function()
    local env = T.addon("Achievements", { faction = "Alliance" })
    api.server_packet(env, "AC", "L ")
    api.server_packet(env, "AC", "E 1,1767268800;100,1767268800")
    T.eq(env.Achievements_Toast.name:GetText(), "Level 10")
    api.tick(env, 6)
    T.shown(env.Achievements_Toast, "the second banner follows")
    T.eq(env.Achievements_Toast.name:GetText(), "Fifty Quests")
    api.click(env.Achievements_Toast)
    T.hidden(env.Achievements_Toast)
    T.shown(env.Achievements_Frame)
    T.eq(env.Achievements.header:GetText(), "Quests")
end)

T.test("Achievements: guild announcement is off by default and says the link when on", function()
    local env = T.addon("Achievements", { guild = { name = "Ashen Vanguard" }, faction = "Alliance" })
    api.server_packet(env, "AC", "L ")
    api.server_packet(env, "AC", "E 1,1767268800")
    for _, s in ipairs(env.__chat_sent) do T.no(s.kind == "GUILD", "nothing said in guild") end
    env.WenillaCore:Settings("Achievements").announceGuild = true
    api.server_packet(env, "AC", "E 2,1767268800")
    local last = env.__chat_sent[#env.__chat_sent]
    T.eq(last.kind, "GUILD")
    T.eq(last.msg, "I just earned [Achievement: Level 20]!")
end)

T.test("Achievements: realm firsts - claimed list, live announcement, tooltip", function()
    local env = T.addon("Achievements", { name = "Aldric", faction = "Alliance" })
    local A = env.Achievements
    api.server_packet(env, "AC", "L ")
    api.server_packet(env, "AC", "R 1000,Kael,1767268800")
    T.eq(A.realmFirsts[1000].name, "Kael")
    open(env)
    api.click(env.Achievements_Cat10)
    T.eq(env.Achievements.header:GetText(), "Feats of Strength")
    T.eq(env.Achievements_Row1.name:GetText(), "Realm First! Level 60")
    T.eq(env.Achievements_Row1.date:GetText(), "Claimed by Kael")
    T.eq(env.Achievements_Row2.date:GetText(), "Unclaimed")
    T.hidden(env.Achievements_Row1.shield, "feats give no points")
    api.enter(env.Achievements_Row1)
    T.has(api.tooltip_text(env), "Claimed by Kael on 01/01/26.")
    api.server_packet(env, "AC", "F 1040,Berra,1767355200")
    T.eq(A.realmFirsts[1040].name, "Berra")
    T.ok(api.screen_has(env, "Berra: Realm First! Onyxia"), "realm first banner")
    -- our own realm first comes as an E, without a second banner
    api.server_packet(env, "AC", "F 1041,Aldric,1767355200")
    T.no(api.screen_has(env, "Aldric: Realm First! Ragnaros"))
    -- R replaces the list
    api.server_packet(env, "AC", "R ")
    T.eq(A.realmFirsts[1000], nil)
end)

T.test("Achievements: saved cache across a relog, and the note while offline", function()
    local env = T.addon("Achievements", { name = "Aldric", faction = "Alliance" })
    api.server_packet(env, "AC", "L 1,1767268800;2,1767268800")
    api.server_packet(env, "AC", "P 104,312")
    env.Achievements.Track(3)
    env = T.relog(env)
    local A = env.Achievements
    T.ok(A.earned[1] and A.earned[2], "earned list survives")
    T.eq(A.Points(), 20)
    T.eq(A.progress[104].v, 312)
    T.ok(A.IsTracked(3))
    T.no(A.synced, "not synced this session")
    open(env)
    T.has(A.note:GetText(), "Showing what you had earned when you were last online")
    -- another character on the account starts empty
    local other = T.addon("Achievements", { name = "Berra", saved = { Achievements_DB = env.Achievements_DB } })
    T.eq(other.Achievements.Points(), 0)
end)

T.test("Achievements: asks the realm for the list once connected, and not too often", function()
    local env = T.addon("Achievements", { faction = "Alliance" })
    local A = env.Achievements
    api.connect(env)
    open(env)
    T.has(table.concat(env.__wnl, "\n"), "ac list")
    T.has(A.note:GetText(), "Loading your achievements")
    local n = #env.__wnl
    env.Achievements_Frame:Hide()
    env.Achievements_Frame:Show()
    T.eq(#env.__wnl, n, "no second request within 30 s")
    api.on_server(env, "ac", function(rest) if rest == "list" then api.server_packet(env, "AC", "L 1,1767268800") end end)
    api.tick(env, 40)
    T.ok(A.synced, "the background retry got the list")
    T.hidden(A.note, "no note once synced")
    -- a realm that greets without Achievements in its list
    local old = T.addon("Achievements", { name = "Old" })
    api.server_packet(old, "HI", "1 Quests,Threat")
    open(old)
    T.has(old.Achievements.note:GetText(), "doesn't keep achievements yet")
end)

T.test("Achievements: Persona can show points and a featured achievement", function()
    local env = T.addon("Achievements", { faction = "Alliance" })
    local A = env.Achievements
    T.eq(A.Featured().points, 0)
    T.eq(A.Featured().id, nil)
    api.server_packet(env, "AC", "L 1,1767268800;6,1767355200;560,1767441600")
    local f = A.Featured()
    T.eq(f.points, 60)
    T.eq(f.name, "Onyxia's Lair", "most recent, most points")
    A.SetFeatured(1)
    T.eq(A.Featured().name, "Level 10")
    -- from the row menu
    open(env)
    api.click(env.Achievements_Cat2)
    api.click(env.Achievements_Row6, "RightButton")
    api.click_text(env, "Feature on your profile", env.WenillaCore_Menu)
    T.eq(A.Featured().name, "Level 60")
    env.WenillaCore:Settings("Achievements").persona = false
    T.eq(A.Featured(), nil, "sharing off")
end)

T.test("Achievements: malformed packets never raise", function()
    local env = T.addon("Achievements", { faction = "Alliance" })
    open(env)
    for _, b in ipairs({ "", " ", "L", "L ;;;", "L x,y;,", "E", "E ,", "E 99999,1", "P", "P 1", "P 1,x", "P x,1,2",
        "C", "C ,,,", "R", "R 1000", "R 1000,,", "F", "F 9,Bob,1", "I", "I ,", "I Bob", "I Bob,1,x;y,z", "Z 1,2",
        "123", string.rep("L 1,1;", 80) }) do
        api.server_packet(env, "AC", b)
        api.tick(env, 0.1)
    end
    api.click(env.Achievements_Cat2)
    api.tick(env, 7)
end)

T.test("Achievements: switching it off hides the window, banner and tracker", function()
    local env = T.addon("Achievements", { faction = "Alliance", level = 20 })
    local A = env.Achievements
    api.server_packet(env, "AC", "L ")
    A.Track(3)
    open(env)
    api.server_packet(env, "AC", "E 1,1767268800")
    env.WenillaCore:SetAddonEnabled("Achievements", false)
    T.hidden(env.Achievements_Frame)
    T.hidden(env.Achievements_Toast)
    T.hidden(env.Achievements_Tracker)
    env.__slash("/ach")
    T.hidden(env.Achievements_Frame)
    T.has(api.chat_text(env), "Achievements is switched off")
    T.eq(A.Featured(), nil)
    env.WenillaCore:SetAddonEnabled("Achievements", true)
    T.shown(env.Achievements_Tracker)
end)

T.test("Achievements: with the whole suite, Y, the menu bar and the tracker under the quest tracker", function()
    local env = T.suite({ faction = "Alliance", level = 20 })
    api.tick(env, 2)
    T.eq(env.GetBindingAction("Y"), "ACHIEVEMENTS_TOGGLE")
    env.SlashCmdList.ACHIEVEMENTS("")
    T.shown(env.Achievements_Frame)
    env.Achievements_Frame:Hide()
    api.click(env.OVAchievementsMicroButton)
    T.shown(env.Achievements_Frame, "the menu bar's Achievements button opens it")
    api.server_packet(env, "AC", "L 1,1767268800")
    env.Achievements.Track(3)
    T.shown(env.Achievements_Tracker)
    if env.Compass_Tracker and env.Compass_Tracker:IsShown() then
        local _, rel = env.Achievements_Tracker:GetPoint()
        T.eq(rel, env.Compass_Tracker, "sits under the Quests tracker")
    end
end)

T.test("Achievements: summary tiles per category with crests, counts and points; a click opens it", function()
    local env = T.addon("Achievements", { name = "Aldric", faction = "Alliance", class = "WARRIOR", level = 60 })
    local A = env.Achievements
    api.server_packet(env, "AC", "L 1,1767268800;2,1767355200;100,1767441600")
    open(env)
    T.shown(env.Achievements_Frame.solid, "an opaque face under the window")
    for i, c in ipairs(env.Achievements_Data.categories) do
        local t = env["Achievements_CatTile" .. i]
        T.shown(t, c.key .. " tile")
        T.eq(t.key, c.key)
        T.eq(t.name:GetText(), c.name)
        local e, n, p, m = A.CategoryStats(c.key)
        T.eq(t.count:GetText(), e .. "/" .. n, c.key .. " count")
        T.near(t.bar:GetValue(), n > 0 and e / n or 0, 1e-9)
        T.eq(t.points:GetText() or "", m > 0 and (p .. " pts") or "", c.key .. " points")
        T.has(t.crest:GetTexture(), "Ach_Cat_", c.key .. " crest on the tile")
        T.has(env["Achievements_Cat" .. (i + 1)].icon:GetTexture(), A.CRESTS[c.key], c.key .. " crest on the button")
        T.ok(t.art, "tile art")
    end
    T.eq(env.Achievements_CatTile1.count:GetText(), "2/" .. select(2, A.CategoryStats("general")))
    T.eq(env.Achievements_CatTile1.points:GetText(), "20 pts")
    T.eq(env.Achievements_CatTile2.count:GetText(), "1/" .. select(2, A.CategoryStats("quests")))
    T.eq(env.Achievements_CatTile9.points:GetText() or "", "", "feats have no points")
    -- hover explains, click opens the category
    api.enter(env.Achievements_CatTile5)
    T.has(api.tooltip_text(env), "Raids")
    T.has(api.tooltip_text(env), "achievements earned")
    api.click(env.Achievements_CatTile5)
    T.eq(A.header:GetText(), "Raids")
    T.hidden(env.Achievements_Summary)
    api.click(env.Achievements_Cat1)
    api.click(env.Achievements_CatTile9)
    T.eq(A.header:GetText(), "Feats of Strength")
end)

T.test("Achievements: the empty Recent state is illustrated and goes once something is earned", function()
    local env = T.addon("Achievements", { faction = "Alliance" })
    api.server_packet(env, "AC", "L ")
    open(env)
    local box = env.Achievements_RecentEmpty
    T.shown(box, "empty state box")
    T.shown(box.art, "illustration")
    T.has(box.art:GetTexture(), "Ach_Empty")
    T.eq(box.title:GetText(), "Your story starts here")
    T.ok(api.screen_has(env, "Nothing earned yet", box))
    T.hidden(env.Achievements_Recent1)
    api.server_packet(env, "AC", "E 1,1767268800")
    T.hidden(box, "gone once something is earned")
    T.shown(env.Achievements_Recent1)
    T.eq(env.Achievements_Recent1.name:GetText(), "Level 10")
    T.eq(env.Achievements_CatTile1.count:GetText(), "1/" .. select(2, env.Achievements.CategoryStats("general")))
end)

T.test("Achievements: without art the crests fall back to stock icons and tiles get a border", function()
    local env = T.addon("Achievements", { art = false, faction = "Alliance" })
    api.server_packet(env, "AC", "L 1,1767268800")
    open(env)
    for i, c in ipairs(env.Achievements_Data.categories) do
        T.eq(env["Achievements_Cat" .. (i + 1)].icon:GetTexture(), c.icon, c.key .. " stock icon on the button")
        local t = env["Achievements_CatTile" .. i]
        T.eq(t.crest:GetTexture(), c.icon, c.key .. " stock icon on the tile")
        T.no(t.art, "no tile art")
        T.has(t.backdropInfo and t.backdropInfo.edgeFile or "", "UI-Tooltip-Border", "a bordered backdrop instead")
    end
    T.eq(env.Achievements_Cat1.icon:GetTexture(), "Interface\\Icons\\INV_Crown_01")
    api.click(env.Achievements_CatTile3)
    T.eq(env.Achievements.header:GetText(), "Exploration")
    -- the empty state still shows, with a stock picture
    api.server_packet(env, "AC", "L ")
    api.click(env.Achievements_Cat1)
    T.shown(env.Achievements_RecentEmpty)
    T.eq(env.Achievements_RecentEmpty.art:GetTexture(), "Interface\\Icons\\INV_Shield_05")
    T.ok(api.screen_has(env, "Nothing earned yet", env.Achievements_Frame))
end)
