-- Persona: roleplay profiles between two clients over the hidden OWPersona channel, through a
-- server that trims and collapses spaces (generalised from tools/tests/persona_sim.lua).
local T, api = ...

local FIELDS = { "name", "title", "status", "bio", "appearance", "s1", "s2", "s3", "pronouns", "age", "home",
    "occur", "exp", "crest", "author", "motto", "build", "currently" }

local function pair()
    local A = T.addon("Persona", { name = "Aldric", class = "PALADIN" })
    local B = T.addon("Persona", { name = "Berra", class = "PRIEST", race = "Night Elf" })
    api.tick(A, 6)                       -- join the channel 4 s after entering the world, announce
    return A, B
end

local NASTY = "  Leading spaces,  double  spaces, under_scores, pipes |cffff0000red|r, tildes ~~, back\\slashes \\n literal,\nnew line, trailing   "

local function bio()
    local b = NASTY
    local i = 0
    while string.len(b) < 2150 do i = i + 1; b = b .. " The quick brown fox " .. i .. " jumps;" end
    return b
end

local function writeProfile(A, text)
    local P = A.Persona
    P.ShowEdit()
    local e = A.PersonaFrame.edit
    e.name:SetText("Aldric  Vane")
    e.title:SetText("Knight_of ~ the | Rose")
    e.pronouns:SetText("he/him"); e.age:SetText("34"); e.home:SetText("Stormwind"); e.build:SetText("Broad")
    e.motto:SetText("Light \\ and ~ shadow")
    e.currently:SetText("Guarding the gate")
    e.bio:SetText(text)
    e.appearance:SetText("Tall.\n\nScar over left eye.")
    e.shares:SetText("one\n\ntwo  spaced\nthree")
    e.occur:SetText("Back in 10")
    e.author:SetText("OOC: Orion")
    api.click(api.find_button(A, "Looking for RP", e))
    api.click(api.find_button(A, "Experienced", e.pages.who), nil, true)
    e.crest = "INV_Sword_04"
    api.click(api.find_button(A, "Save & share", e))
    return P.Mine()
end

T.test("Persona: a 2,100+ character profile survives the space-collapsing server intact", function()
    local A, B = pair()
    local text = bio()
    T.ok(string.len(text) > 2100)
    local mine = writeProfile(A, text)
    T.eq(mine.bio, text, "bio saved as typed")
    T.eq(mine.status, "lfrp"); T.eq(mine.exp, "3"); T.eq(mine.rev, 1)
    T.has(api.chat_text(A), "saved. Players who mouse over or target you will see it.")
    api.tick(A, 3)
    api.mouseover(B, "Aldric")           -- B has never seen A: asks with ?P
    api.tick(A, 30)
    local got = B.Persona.Get("Aldric")
    T.ok(got, "B received Aldric's profile")
    T.eq(api.tooltip_lines(B)[1], "Aldric  Vane", "the open tooltip is rebuilt when the profile arrives")
    for _, k in ipairs(FIELDS) do T.eq(got[k] or "", mine[k] or "", "field " .. k) end
    T.eq(got.rev, 1)
    local longest, lines = 0, 0
    for _, l in ipairs(A.__bus.log) do
        lines = lines + 1
        if string.len(l.msg) > longest then longest = string.len(l.msg) end
    end
    T.ok(longest <= 255, "longest channel line " .. longest)
    T.ok(lines > 10, "the profile went out in chunks (" .. lines .. " lines)")
end)

T.test("Persona: tooltip, view page, target badge and directory on the reader's side", function()
    local A, B = pair()
    writeProfile(A, bio())
    api.mouseover(B, "Aldric")
    api.tick(A, 30)
    api.mouseover(B, "Aldric")
    local tip = api.tooltip_lines(B)
    T.eq(tip[1], "Aldric  Vane", "roleplay name replaces the character name")
    local all = table.concat(tip, "\n")
    T.has(all, "<Knight_of ~ the | Rose>", "pipes shown literally")
    T.has(all, "Looking for roleplay")
    T.has(all, "he/him \194\183 34 \194\183 Broad \194\183 Stormwind")
    T.has(all, "Currently: Guarding the gate")
    T.has(all, "OOC: Back in 10")
    T.has(all, "/rp Aldric to read their Persona")
    T.lacks(all, "New to roleplay", "only exp 1 is shown on tooltips")
    -- view
    B.__slash("/rp aldric")
    local v = B.PersonaFrame.view
    T.shown(v)
    T.eq(api.visible(v.head:GetText()), "Aldric  Vane  (Aldric)")
    T.has(v.text:GetText(), "||cffff0000red||r", "colour codes from other players are neutralised")
    T.has(api.visible(v.text:GetText()), "\"Light \\ and ~ shadow\"")
    T.has(api.visible(v.text:GetText()), "two  spaced")
    T.has(api.visible(v.text:GetText()), "Experienced roleplayer")
    T.has(v.seen:GetText(), "updated just now")
    T.shown(v.whisper)
    api.click(v.whisper)
    T.eq(B.__opened_chat[1], "/w Aldric ")
    -- target badge
    api.set_target(B, "Aldric")
    T.shown(B.PersonaTargetBadge)
    api.enter(B.PersonaTargetBadge)
    T.has(api.tooltip_text(B), "Click to read their Persona")
    -- directory
    B.Persona.ShowList()
    T.has(B.PersonaFrame.list.info:GetText(), "1 profiles")
    T.ok(api.screen_has(B, "Aldric  Vane (Aldric)", B.PersonaFrame.list))
    api.type(B.PersonaFrame.list.search, "stormwind")
    T.has(B.PersonaFrame.list.info:GetText(), "1 profiles", "search matches home")
    api.type(B.PersonaFrame.list.search, "orgrimmar")
    T.has(B.PersonaFrame.list.info:GetText(), "0 profiles")
    api.type(B.PersonaFrame.list.search, "")
    api.click(api.find_button(B, "Looking for RP", B.PersonaFrame.list))
    T.has(B.PersonaFrame.list.info:GetText(), "1 profiles")
end)

T.test("Persona: status changes reach others through the #P announce", function()
    local A, B = pair()
    writeProfile(A, "short bio")
    api.mouseover(B, "Aldric")
    api.tick(A, 20)
    T.eq(B.Persona.Get("Aldric").status, "lfrp")
    A.__slash("/rp st")
    api.tick(A, 3)
    local p = B.Persona.Get("Aldric")
    T.eq(p.status, "st")
    T.ok(p.stale, "marked stale until the full profile is fetched again")
    T.has(api.chat_text(A), "status: Storytelling")
    -- Berra announces herself on login; Aldric already has a summary of her
    T.ok(A.Persona.Get("Berra"), "summary from Berra's #P")
    T.eq(A.Persona.Get("Berra").rev, -1, "not read yet")
    A.Persona.ShowList()
    T.ok(api.screen_has(A, "profile not read yet", A.PersonaFrame.list))
    -- the minimap button: right-click cycles, left-click opens your own
    api.click(A.PersonaMinimapButton, "RightButton")
    T.eq(A.Persona.Mine().status, "ic", "st -> ic")
    A.PersonaFrame:Hide()
    api.click(A.PersonaMinimapButton, "LeftButton")
    T.shown(A.PersonaFrame.view, "your own profile")
    api.enter(A.PersonaMinimapButton)
    T.has(api.tooltip_text(A), "Status: In character")
end)

T.test("Persona: requests are throttled and only stale copies are re-sent", function()
    local A, B = pair()
    writeProfile(A, "short bio")
    api.mouseover(B, "Aldric")
    api.tick(A, 20)
    local asks = 0
    for _ = 1, 5 do api.mouseover(B, "Aldric"); api.tick(A, 1) end
    for _, l in ipairs(A.__bus.log) do if string.sub(l.msg, 1, 2) == "?P" then asks = asks + 1 end end
    T.eq(asks, 1, "one request while the copy is fresh")
    local before = #A.__bus.log
    B.Persona.Request("Aldric")                          -- inside REQUEST_GAP: ignored
    api.tick(A, 5)
    T.eq(#A.__bus.log, before)
end)

T.test("Persona: the hidden channel never shows in chat; other channels still do", function()
    local A, B = pair()
    writeProfile(A, "short bio")
    api.mouseover(B, "Aldric")
    api.tick(A, 20)
    B.SendChatMessage("hello all", "CHANNEL", nil, B.GetChannelName("General"))
    api.pump(A)
    for _, env in ipairs({ A, B }) do
        local chat = api.chat_text(env)
        T.lacks(chat, "OWPersona", env.__name .. " chat")
        T.lacks(chat, "!P ", env.__name .. " chat")
    end
    T.has(api.chat_text(A), "[1. General] [Berra]: hello all")
end)

T.test("Persona: ignored players are left out both ways", function()
    local A, B = pair()
    writeProfile(B, "Berra's story")
    api.tick(A, 3)
    A.AddIgnore("Berra")
    api.mouseover(A, "Berra")
    T.lacks(api.tooltip_text(A), "/rp Berra", "no decoration for an ignored player")
    api.tick(A, 20)
    T.eq((A.Persona.Get("Berra") or {}).rev or -1, -1, "her profile is not fetched")
    A.Persona.ShowList()
    T.has(A.PersonaFrame.list.info:GetText(), "0 profiles", "not in the directory")
    -- and Aldric does not answer Berra's requests
    writeProfile(A, "Aldric's story")
    local sentBefore = 0
    for _, l in ipairs(A.__bus.log) do if l.from == "Aldric" and string.sub(l.msg, 1, 2) == "!P" then sentBefore = sentBefore + 1 end end
    api.mouseover(B, "Aldric")
    api.tick(A, 20)
    local sent = 0
    for _, l in ipairs(A.__bus.log) do if l.from == "Aldric" and string.sub(l.msg, 1, 2) == "!P" then sent = sent + 1 end end
    T.eq(sent, sentBefore, "no profile chunks for an ignored asker")
end)

T.test("Persona: slash commands, demo profiles, popup menu and Escape", function()
    local A = T.addon("Persona", { name = "Aldric" })
    api.tick(A, 5)
    A.__slash("/rp")
    T.shown(A.PersonaFrame.edit, "an empty profile opens the editor")
    A.__slash("/rp help")
    T.has(api.chat_text(A), "/rp ic | ooc | lfrp | st")
    A.__slash("/rp demo")
    T.has(api.chat_text(A), "sample profiles on (Directory).")
    A.__slash("/rp list")
    T.has(A.PersonaFrame.list.info:GetText(), "4 profiles")
    T.ok(api.screen_has(A, "Ilyndra Vael'shan (Ilyndra)", A.PersonaFrame.list))
    api.click_text(A, "Ilyndra Vael'shan", A.PersonaFrame.list)
    T.shown(A.PersonaFrame.view)
    T.has(api.visible(A.PersonaFrame.view.text:GetText()), "The stars remember what we forget.")
    A.__slash("/persona demo")
    T.has(api.chat_text(A), "sample profiles off.")
    -- right-click menus get "View Persona" just above Cancel
    local m = A.UnitPopupMenus.PLAYER
    T.eq(m[#m - 1], "PERSONA_VIEW"); T.eq(m[#m], "CANCEL")
    A.UIDROPDOWNMENU_INIT_MENU = "TestDropDown"
    A.TestDropDown = { name = "Berra" }
    A.this = { value = "PERSONA_VIEW" }
    A.UnitPopup_OnClick()
    T.eq(A.Persona.viewing, "Berra")
    A.this = { value = "WHISPER" }
    A.UnitPopup_OnClick()
    T.eq(A.__unitpopup_clicked, "WHISPER", "other entries reach the stock handler")
    A.this = nil
    T.ok(api.press_escape(A), "Escape closes the window")
    T.hidden(A.PersonaFrame)
    A.__slash("/rp edit")
    A.Persona.EditTab("story"); A.Persona.EditTab("ooc")
    T.shown(A.PersonaFrame.edit.pages.ooc)
    T.hidden(A.PersonaFrame.edit.pages.who)
end)

T.test("Persona: settings and the addon switch", function()
    local A, B = pair()
    writeProfile(A, "short bio")
    api.mouseover(B, "Aldric")
    api.tick(A, 20)
    B.ClassicPlus_Manager:SetSetting("Persona", "rpNames", false)
    api.mouseover(B, "Aldric")
    T.eq(api.tooltip_lines(B)[1], "Aldric", "rpNames off keeps the character name")
    B.ClassicPlus_Manager:SetSetting("Persona", "showTooltip", false)
    api.mouseover(B, "Aldric")
    T.lacks(api.tooltip_text(B), "Knight_of")
    B.ClassicPlus_Manager:SetSetting("Persona", "minimapButton", false)
    T.hidden(B.PersonaMinimapButton)
    B.ClassicPlus_Manager:SetSetting("Persona", "targetBadge", false)
    api.set_target(B, "Aldric")
    T.hidden(B.PersonaTargetBadge)
    B.WenillaCore:SetAddonEnabled("Persona", false)
    B.__slash("/rp")
    T.has(api.chat_text(B), "is switched off. Turn it on in /addons.")
end)

T.test("Persona: profiles persist across a relog; stale cache entries are pruned", function()
    local A, B = pair()
    writeProfile(A, "short bio")
    api.mouseover(B, "Aldric")
    api.tick(A, 20)
    B.Persona_DB.cache["Open Vanilla"].Ancient = { name = "Old", rev = 3, seen = B.time() - 61 * 86400 }
    local A2 = T.relog(A)
    T.eq(A2.Persona.Mine().bio, "short bio")
    T.eq(A2.Persona.Mine().rev, 1)
    local B2 = T.relog(B)
    T.ok(B2.Persona.Get("Aldric"), "cached profile kept")
    T.eq(B2.Persona_DB.cache["Open Vanilla"].Ancient, nil, "60-day-old profile pruned")
end)

T.test("Persona: a maxed-out profile still fits the wire limits", function()
    local A, B = pair()
    local P = A.Persona
    P.ShowEdit()
    local e = A.PersonaFrame.edit
    local function fill(box, n, unit) local s = ""; while string.len(s) < n do s = s .. unit end; box:SetText(s) end
    fill(e.name, 48, "Name "); fill(e.title, 60, "Title "); fill(e.pronouns, 24, "x"); fill(e.age, 24, "9")
    fill(e.build, 40, "tall "); fill(e.home, 48, "Home "); fill(e.motto, 90, "motto ")
    fill(e.currently, 120, "busy "); fill(e.occur, 120, "back soon "); fill(e.author, 200, "note ")
    fill(e.appearance, 400, "Scarred face.\n"); fill(e.bio, 2400, "A plain sentence of the bio. ")
    e.shares:SetText(string.rep(string.rep("s", 200) .. "\n", 5))
    P.Save()
    api.mouseover(B, "Aldric")
    api.tick(A, 40)
    local got = B.Persona.Get("Aldric")
    T.ok(got and got.rev == 1, "received")
    T.eq(got.bio, P.Mine().bio)
    T.eq(got.s5, P.Mine().s5)
end)

T.test("Persona: works without WenillaCore (OptionalDeps)", function()
    local env = T.client({ name = "Solo" })
    api.load_addon(env, api.repo .. "/Data/Interface/AddOns/Persona")
    api.login(env)
    T.eq(rawget(env, "WenillaCore"), nil)
    api.tick(env, 5)
    T.ok(env.GetChannelName("OWPersona") > 0, "joined the channel")
    T.eq(env.GetChannelName("OWPersona"), 4, "after General, Trade and LocalDefense")
    env.__slash("/rp edit")
    T.shown(env.PersonaFrame)
    env.Persona.Save()
    T.shown(env.PersonaFrame.view)
    T.shown(env.PersonaMinimapButton)
end)

T.test("Persona: a full-length profile full of escaped characters still arrives", function()
        local A, B = pair()
        local P = A.Persona
        P.ShowEdit()
        local e = A.PersonaFrame.edit
        e.bio:SetText(string.rep("_/\\", 800))                 -- ASCII art: 2,400 characters
        e.appearance:SetText(string.rep("|~", 200))
        e.shares:SetText(string.rep(string.rep("_", 200) .. "\n", 5))
        P.Save()
        api.mouseover(B, "Aldric")
        api.tick(A, 45)
        local got = B.Persona.Get("Aldric")
        T.ok(got and got.rev == 1, "B never receives the profile")
    end)

T.test("Persona: garbage and hostile lines on the channel are handled safely", function()
    local A, B = pair()
    local id = B.GetChannelName("OWPersona")
    local lines = { "?P", "?P Aldric", "?P Aldric x", "#P", "#P x", "#P 5", "#P 5 bogus", "#P 5 ic ~~~~~~~~",
        "!P", "!P 1", "!P 1 0/0 x", "!P 1 2/1 x", "!P 1 1/99 x", "!P 99999999999999999999 1/1 x", "hello",
        "!P 7 1/1 Evil|cff~title~lfrp~~~bio~~~~~~~~~~~~9~../../Interface\\evil~x" }
    for _, l in ipairs(lines) do
        if not string.find(l, "|", 1, true) then B.SendChatMessage(l, "CHANNEL", nil, id) end
        api.tick(A, 0.2)
    end
    -- the pipe line cannot be typed by a real client; inject it as the server would deliver it
    api.fire(A, "CHAT_MSG_CHANNEL", lines[#lines], "Berra", "", id .. ". OWPersona", "", "", 0, id, "OWPersona")
    local p = A.Persona.Get("Berra")
    T.ok(p, "the last full profile was accepted")
    T.eq(p.crest, "", "a crest that is not an icon name is dropped")
    T.eq(p.exp, "", "an unknown experience level is dropped")
    T.eq(p.status, "lfrp")
    A.__slash("/rp berra")
    T.has(api.visible(A.PersonaFrame.view.head:GetText()), "Evil|cff", "shown literally")
end)

T.test("Persona: four guided steps with Back and Next, each saying what it is for", function()
    local A = T.addon("Persona", { name = "Aldric" })
    api.tick(A, 5)
    A.__slash("/rp edit")
    local e = A.PersonaFrame.edit
    T.shown(e.pages.who); T.hidden(e.pages.story)
    T.has(e.pages.who.help:GetText(), "Every field is optional")
    api.click(e.next); T.shown(e.pages.pic)
    api.click(e.next); T.shown(e.pages.story)
    api.click(e.next); T.shown(e.pages.ooc)
    T.hidden(e.next, "no Next on the last step")
    api.click(e.back); T.shown(e.pages.story)
    A.Persona.EditTab("who")
    api.click(api.find_button(A, "Storytelling", e))
    T.has(e.statusHelp:GetText(), "running a story")
end)

T.test("Persona: a chosen picture (face, hero, emblem) reaches other players; bad ones are dropped", function()
    local A, B = pair()
    local P = A.Persona
    P.ShowEdit()
    local e = A.PersonaFrame.edit
    P.EditTab("pic")
    api.click(api.find_button(A, "Heroes & creatures", e.pages.pic))
    local hero
    for _, b in ipairs(e.picGrid) do if b.pic == "npc:INV_Misc_Head_Dragon_Black" then hero = b end end
    T.ok(hero and hero:IsShown(), "the black dragon is offered")
    api.click(hero)
    T.eq(e.picName:GetText(), "Black dragon")
    api.click(api.find_button(A, "Save & share", e))
    T.eq(P.Mine().pic, "npc:INV_Misc_Head_Dragon_Black")
    T.has(P.Mine().look, "-", "sex and race are sent with it")
    api.mouseover(B, "Aldric")
    api.tick(A, 20)
    T.eq(B.Persona.Get("Aldric").pic, "npc:INV_Misc_Head_Dragon_Black")
    -- faces: sixteen race portraits
    P.ShowEdit(); P.EditTab("pic")
    api.click(api.find_button(A, "Faces", e.pages.pic))
    local n = 0
    for _, b in ipairs(e.picGrid) do if b:IsShown() then n = n + 1 end end
    T.eq(n, 16)
    -- a hostile picture is dropped on arrival
    local id = B.GetChannelName("OWPersona")
    local fields = {}
    for i = 1, 22 do fields[i] = "" end
    fields[3] = "ic"; fields[21] = "npc:..\\..\\evil"; fields[22] = "Female-Murloc"
    api.fire(A, "CHAT_MSG_CHANNEL", "!P 9 1/1 " .. table.concat(fields, "~"), "Berra", "", id .. ". OWPersona", "", "", 0, id, "OWPersona")
    local p = A.Persona.Get("Berra")
    T.ok(p, "accepted")
    T.eq(p.pic, "", "unknown picture dropped")
    T.eq(p.look, "", "unknown race dropped")
end)
