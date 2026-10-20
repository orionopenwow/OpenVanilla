-- Social: the O window (friends, guild, group, who, ignore, recent) between clients - the O
-- takeover and its setting, friend and guild toasts, menus, notes and tags, presence, the shared
-- ignore list, /who, guild invites with a rank preset, the group tab and recent people.
local T, api = ...

local function client(name, opts)
    opts = opts or {}
    opts.name = name
    return T.addon("Social", opts)
end

local function toastShown(env, text)
    return api.screen_has(env, text) ~= nil
end

local function menuClick(env, text)
    api.click_text(env, text, env.WenillaCore_Menu)
end

T.test("Social: O opens Social instead of the stock Friends window; the setting brings it back", function()
    local A = client("Aldric")
    A.ToggleFriendsFrame()
    T.shown(A.Social_Frame, "Social")
    T.hidden(A.FriendsFrame, "stock Friends frame")
    T.eq(A.Social.tab, "friends")
    A.ToggleFriendsFrame()
    T.hidden(A.Social_Frame, "O again closes it")
    A.ToggleFriendsFrame(2)
    T.eq(A.Social.tab, "who", "the stock Who tab maps to ours")
    A.ToggleFriendsFrame(3)
    T.eq(A.Social.tab, "guild")
    -- something showing the stock frame directly lands in Social too
    A.Social_Frame:Hide()
    A.FriendsFrame:Show()
    T.hidden(A.FriendsFrame)
    T.shown(A.Social_Frame)
    -- the stock window stays one click away
    api.click(api.find_button(A, "Blizzard's window", A.Social_Frame))
    T.shown(A.FriendsFrame, "Blizzard's window button")
    T.hidden(A.Social_Frame)
    A.FriendsFrame:Hide()
    -- switching "Open with O" off restores the stock frame
    A.ClassicPlus_Manager:SetSetting("Social", "replaceFriends", false)
    A.ToggleFriendsFrame()
    T.shown(A.FriendsFrame, "stock frame with the setting off")
    T.hidden(A.Social_Frame)
    A.ToggleFriendsFrame()
    A.ClassicPlus_Manager:SetSetting("Social", "replaceFriends", true)
    -- so does switching Social off
    A.WenillaCore:SetAddonEnabled("Social", false)
    A.ToggleFriendsFrame()
    T.shown(A.FriendsFrame, "stock frame with Social off")
end)

T.test("Social: friends online first with class colour, level, zone; offline friends show last seen", function()
    local B = client("Berra", { class = "HUNTER", level = 14, map = { x = 0.4, y = 0.6, zone = "Elwynn Forest" } })
    local A = client("Aldric", { friends = { "Corvin", "Berra", { name = "Dagna", level = 30, class = "MAGE" } },
        saved = { Social_DB = { people = { ["Open Vanilla"] = { Corvin = { seen = api.bus.epoch - 3 * 86400 } } } } } })
    A.__slash("/social")
    local r1, r2 = A.Social_Friend1, A.Social_Friend2
    T.has(api.visible(r1.name:GetText()), "Berra")
    T.has(r1.name:GetText(), "|c" .. "ffaad372Berra", "hunter colour")
    T.eq(r1.right:GetText(), "14 Hunter")
    T.has(r1.info:GetText(), "Elwynn Forest")
    T.has(api.visible(r2.name:GetText()), "Corvin")
    T.has(api.visible(r2.info:GetText()), "Offline")
    T.has(api.visible(r2.info:GetText()), "last seen 3 days ago")
    T.has(api.visible(A.Social_Friend3.info:GetText()), "Offline")
    T.ok(api.screen_has(A, "1 of 3 friends online", A.Social_Frame))
    -- their Persona status, once Persona knows it
    A.Persona_DB.cache[A.GetRealmName()].Berra = { name = "Berra Swiftwind", status = "lfrp", rev = 2, seen = A.time() }
    A.Social:Refresh()
    T.has(api.visible(r1.name:GetText()), "LFRP")
    -- search and sort
    api.type(A.Social_FriendSearch, "dag")
    T.has(api.visible(A.Social_Friend1.name:GetText()), "Dagna")
    T.hidden(A.Social_Friend2)
    api.type(A.Social_FriendSearch, "")
    api.click(A.Social_FriendSort)
    T.ok(api.screen_has(A, "Sort: Name", A.Social_Frame))
    T.has(api.visible(A.Social_Friend1.name:GetText()), "Berra")
    T.has(api.visible(A.Social_Friend2.name:GetText()), "Corvin")
    -- Add
    api.type(A.Social_FriendAdd, "elric")
    api.click(api.find_button(A, "Add", A.Social_Frame))
    api.pump(A)
    T.eq(A.__friends[4].name, "Elric")
    T.ok(api.screen_has(A, "1 of 4 friends online", A.Social_Frame))
end)

T.test("Social: a friend coming online gets one toast; mute stops it", function()
    local A = client("Aldric", { friends = { "Berra" } })
    api.tick(A, 1)
    local B = client("Berra", { class = "HUNTER", level = 14, map = { x = 0.4, y = 0.6, zone = "Elwynn Forest" } })
    api.pump(A)
    T.ok(toastShown(A, "Berra is online"), "toast")
    T.ok(toastShown(A, "Level 14 Hunter"), "toast text")
    local n = 0
    for _, t in ipairs(api.visible_texts(A)) do if t == "Berra is online" then n = n + 1 end end
    T.eq(n, 1, "one toast for one login")
    T.eq(A.Social:Person("Berra").seen ~= nil, true, "last seen tracked")
    api.tick(A, 6)
    T.no(toastShown(A, "Berra is online"), "the toast fades")
    -- mute from the menu, then Berra logs off and on again
    A.__slash("/social")
    api.click(A.Social_Friend1)
    menuClick(A, "Mute their toasts")
    T.ok(A.Social:Person("Berra").mute)
    api.log_off(B)
    api.tick(A, 70)
    T.has(api.visible(A.Social_Friend1.info:GetText()), "last seen")
    client("Berra", { class = "HUNTER", level = 14 })
    api.pump(A)
    T.no(toastShown(A, "Berra is online"), "muted")
end)

T.test("Social: friend menu - whisper, invite, Persona, show on map, note and colour tag", function()
    local B = client("Berra", { class = "HUNTER", level = 14, map = { x = 0.4, y = 0.6, zone = "Elwynn Forest" } })
    local A = client("Aldric", { friends = { "Berra" } })
    A.__slash("/social friends")
    api.click(A.Social_Friend1)
    menuClick(A, "Whisper")
    T.eq(A.__opened_chat[1], "/w Berra ")
    api.click(A.Social_Friend1)
    menuClick(A, "Invite to group")
    T.eq(A.__invites[1], "Berra")
    api.click(A.Social_Friend1)
    menuClick(A, "Show Elwynn Forest on the map")
    T.shown(A.WorldMapFrame)
    T.eq(A.__map_zoom[1] .. "," .. A.__map_zoom[2], "2,10")
    api.click(A.Social_Friend1)
    menuClick(A, "View Persona")
    T.shown(A.PersonaFrame, "Persona opens on Berra")
    -- note and tag
    api.click(A.Social_Friend1)
    menuClick(A, "Note and colour tag")
    T.shown(A.Social_NoteBar)
    api.type(A.Social_NoteBox, "Great healer, plays evenings")
    api.click(A.Social_NoteBar.swatches.green)
    api.click(api.find_button(A, "Save", A.Social_NoteBar))
    T.hidden(A.Social_NoteBar)
    T.has(api.visible(A.Social_Friend1.info:GetText()), "Note: Great healer, plays evenings")
    T.has(A.Social_Friend1.name:GetText(), "|cff40e070Berra", "the tag colours the name")
    -- the note in her tooltip, the tag on her name in chat
    api.mouseover(A, "Berra")
    T.has(api.tooltip_text(A), "Note: Great healer, plays evenings")
    B.SendChatMessage("hi there", "WHISPER", nil, "Aldric")
    api.pump(A)
    T.has(A.__chat[#A.__chat], "[|cff40e070Berra|r] whispers: hi there")
    -- notes and tags survive a relog
    A = T.relog(A)
    T.eq(A.Social:Person("Berra").note, "Great healer, plays evenings")
    T.eq(A.Social:Person("Berra").tag, "green")
end)

T.test("Social: a friend's level up shows a toast", function()
    local B = client("Berra", { class = "HUNTER", level = 14 })
    local A = client("Aldric", { friends = { "Berra" } })
    api.tick(A, 12)            -- both on the hidden channel
    T.eq(A.Social:Person("Berra").level, 14)
    api.set_level(B, 15)
    api.tick(A, 2)
    T.ok(toastShown(A, "Berra reached level 15!"), "level up toast")
    -- and from the friends list alone (no Classic+ on their side)
    api.tick(A, 10)
    B.__units.player.level = 16
    A.ShowFriends()
    api.pump(A)
    T.ok(toastShown(A, "Berra reached level 16!"))
end)

T.test("Social: presence reaches friends and the Dungeons board", function()
    local B = client("Berra", { class = "HUNTER", level = 19 })
    local A = client("Aldric", { friends = { "Berra" }, level = 20 })
    api.tick(A, 12)
    B.__slash("/social away")
    api.tick(A, 2)
    T.eq(A.Social:PresenceOf("Berra"), "away")
    A.__slash("/social")
    T.has(api.visible(A.Social_Friend1.name:GetText()), "Away")
    -- the board shows it on Berra's listing
    B.__slash("/social lfg")
    B.Dungeons.DB().prefs.dungeons.dm = true
    B.Dungeons:List()
    api.tick(A, 3)
    T.eq(A.Dungeons.listings.Berra.presence, "lfg")
    A.__slash("/lfg")
    T.has(api.visible(A.Dungeons_BoardRow1.name:GetText()), "Looking for group")
    -- the presence button cycles
    A.__slash("/social friends")
    api.click(A.Social_Presence)
    T.eq(A.Social:MyPresence(), "away")
    T.ok(api.screen_has(A, "Away", A.Social_Presence))
end)

T.test("Social: one ignore list for chat, Dungeons and Persona, with notes", function()
    local B = client("Berra", { class = "HUNTER", level = 20 })
    local A = client("Aldric", { level = 20 })
    api.tick(A, 12)
    A.__slash("/social ignore")
    api.type(A.Social_IgnoreName, "berra")
    api.type(A.Social_IgnoreNote, "Spammed trade chat")
    api.click(api.find_button(A, "Ignore", A.Social_Frame))
    local Ig = A.WenillaCore.Ignore
    T.ok(Ig.IsIgnored("Berra"), "WenillaCore.Ignore.IsIgnored")
    T.ok(Ig:IsIgnored("Berra"), "colon call works too")
    T.eq(Ig.Note("Berra"), "Spammed trade chat")
    T.eq(A.__ignores[1], "Berra", "the stock list too")
    T.has(api.visible(A.Social_Ignore1.info:GetText()), "Spammed trade chat")
    -- chat
    B.SendChatMessage("buy gold", "SAY")
    api.pump(A)
    T.lacks(api.chat_text(A), "buy gold")
    -- a Dungeons listing never shows
    B.Dungeons.DB().prefs.dungeons.dm = true
    B.Dungeons:List()
    api.tick(A, 3)
    T.eq(A.Dungeons.listings.Berra, nil, "ignored listing")
    -- Persona respects it (it reads the stock list we keep in step)
    T.ok(A.Persona and true, "Persona loaded")
    -- the API from another addon
    T.ok(Ig.Add("Corvin", "Rude in a dungeon"))
    T.ok(Ig.IsIgnored("Corvin"))
    local names = {}
    for _, e in ipairs(Ig.List()) do table.insert(names, e.name) end
    T.eq(table.concat(names, ","), "Berra,Corvin")
    -- Remove from the tab
    api.click(A.Social_Ignore1.remove)
    T.no(Ig.IsIgnored("Berra"))
    api.pump(A)
    for _, n in ipairs(A.__ignores) do T.ok(n ~= "Berra", "un-ignored in the game too") end
    -- /unignore in chat drops our entry as well
    A.DelIgnore("Corvin")
    api.pump(A)
    T.no(Ig.IsIgnored("Corvin"))
    -- notes survive a relog
    Ig.Add("Dagna", "Ninja looter")
    A = T.relog(A)
    T.eq(A.WenillaCore.Ignore.Note("Dagna"), "Ninja looter")
end)

T.test("Social: Who search with filters, sorting, rate limit, whisper and invite", function()
    local A = client("Aldric")
    api.add_world_player(A, { name = "Zed", level = 15, class = "HUNTER", race = "Dwarf", zone = "Loch Modan", guild = "Ironbound" })
    api.add_world_player(A, { name = "Ari", level = 18, class = "HUNTER", race = "Human", zone = "Westfall" })
    api.add_world_player(A, { name = "Mox", level = 18, class = "MAGE", race = "Gnome", zone = "Westfall" })
    api.add_world_player(A, { name = "Old", level = 44, class = "HUNTER", race = "Human", zone = "Tanaris" })
    A.__slash("/social who")
    api.type(A.Social_WhoMin, "10")
    api.type(A.Social_WhoMax, "20")
    api.click(A.Social_WhoClass)
    api.click(A.Social_WhoClass)
    api.click(A.Social_WhoClass)
    T.ok(api.screen_has(A, "Hunter", A.Social_WhoClass))
    api.click(api.find_button(A, "Search", A.Social_Frame))
    T.eq(A.__who_sent[1], 'c-"Hunter" 10-20')
    api.pump(A)
    T.has(api.visible(A.Social_Who1.name:GetText()), "Ari")
    T.has(api.visible(A.Social_Who2.name:GetText()), "Zed")
    T.hidden(A.Social_Who3)
    T.has(api.visible(A.Social_Who2.zone:GetText()), "<Ironbound>")
    -- rate limited
    T.ok(api.screen_has(A, "Wait", A.Social_Frame))
    T.no(A.Social:SearchWho(), "a second search right away is held back")
    T.eq(#A.__who_sent, 1)
    -- sort by level (high first), then by name again
    A.Social:SortWho("level")
    T.has(api.visible(A.Social_Who1.name:GetText()), "Ari")
    A.Social:SortWho("zone")
    T.has(api.visible(A.Social_Who1.name:GetText()), "Zed")
    -- whisper and invite
    api.click(A.Social_Who1.wsp)
    T.eq(A.__opened_chat[1], "/w Zed ")
    api.click(A.Social_Who1.inv)
    T.eq(A.__invites[1], "Zed")
    -- after the pause, a zone search
    api.tick(A, 6)
    api.type(A.Social_WhoMin, ""); api.type(A.Social_WhoMax, "")
    for _ = 1, 7 do api.click(A.Social_WhoClass) end
    api.type(A.Social_WhoZone, "Westfall")
    api.click(api.find_button(A, "Search", A.Social_Frame))
    T.eq(A.__who_sent[2], 'z-"Westfall"')
    api.pump(A)
    T.ok(api.screen_has(A, "2 found", A.Social_Frame))
end)

T.test("Social: guild roster, message of the day, last seen and online toasts", function()
    local roster = {
        { name = "Berra", rank = "Member", rankIndex = 3, level = 14, class = "HUNTER", zone = "Elwynn Forest", note = "Alt of Kael" },
        { name = "Dagna", rank = "Veteran", rankIndex = 2, level = 40, class = "MAGE", online = false, lastOnline = { 0, 0, 3, 0 } },
    }
    local guild = { name = "Ashen Vanguard", rankIndex = 1, rank = "Officer", roster = roster, members = 3, motd = "Raid Thursday 8pm" }
    local A = client("Aldric", { guild = guild })
    A.__slash("/social guild")
    T.ok(api.screen_has(A, "<Ashen Vanguard>", A.Social_Frame))
    T.ok(api.screen_has(A, "Message of the day: Raid Thursday 8pm", A.Social_Frame))
    T.has(api.visible(A.Social_Guild1.name:GetText()), "Aldric")
    T.has(api.visible(A.Social_Guild2.name:GetText()), "Dagna")
    T.has(api.visible(A.Social_Guild2.info:GetText()), "last seen 3 days ago")
    T.has(api.visible(A.Social_Guild3.info:GetText()), "Alt of Kael")
    T.ok(api.screen_has(A, "1 of 3 online", A.Social_Frame))
    api.click(api.find_button(A, "Hide offline", A.Social_Frame))
    T.hidden(A.Social_Guild2)
    -- Berra logs in: a guild toast
    local B = client("Berra", { class = "HUNTER", level = 14, guild = { name = "Ashen Vanguard", rank = "Member", rankIndex = 3 } })
    api.pump(A)
    T.ok(toastShown(A, "Berra is online"), "guild toast")
    T.ok(toastShown(A, "Guild"), "says it's a guild mate")
end)

T.test("Social: guild invite with a rank preset promotes the newcomer step by step", function()
    local guild = { name = "Ashen Vanguard", rankIndex = 1, rank = "Officer", roster = {}, members = 1 }
    local A = client("Aldric", { guild = guild })
    local B = client("Berra", { class = "HUNTER", level = 14 })
    A.__slash("/social guild")
    T.ok(api.screen_has(A, "Initiate", A.Social_GuildRank), "lowest rank by default")
    api.click(A.Social_GuildRank)
    T.ok(api.screen_has(A, "Veteran", A.Social_GuildRank), "officers can pick ranks below their own")
    api.type(A.Social_GuildInviteName, "Berra")
    api.click(api.find_button(A, "Invite", A.Social_Frame))
    T.eq(A.__guild_invites[1], "Berra")
    api.tick(A, 1)
    T.eq(B.__guild.rank, "Veteran", "promoted to the preset")
    T.has(api.chat_text(A), "Berra joined the guild as Veteran")
    T.eq(next(A.Social.pendingRank), nil)
    -- not an officer: no invite controls
    local C = client("Corvin", { guild = { name = "Ashen Vanguard", rankIndex = 3, rank = "Member" } })
    C.__slash("/social guild")
    T.no(api.find_button(C, "Invite", C.Social_Frame))
end)

T.test("Social: not in a guild points at the Guilds board", function()
    local A = T.suite({ name = "Aldric" })
    A.__slash("/social guild")
    T.ok(api.screen_has(A, "You're not in a guild", A.Social_Frame))
    api.click(api.find_button(A, "Find a guild", A.Social_Frame))
    T.shown(A.Concord_Frame, "the Guilds board")
end)

T.test("Social: group tab - members with roles, loot method, ready check, the Dungeons board", function()
    local A = client("Aldric", { class = "WARRIOR", level = 20 })
    local B = client("Berra", { class = "PRIEST", level = 20 })
    local C = client("Corvin", { class = "MAGE", level = 20 })
    api.tick(A, 12)
    A.__slash("/social group")
    T.ok(api.screen_has(A, "You're not in a group", A.Social_Frame))
    api.group({ A, B }, "party")
    A.Social:Refresh()
    T.ok(api.screen_has(A, "Party of 2", A.Social_Frame))
    T.has(api.visible(A.Social_Member1.name:GetText()), "Aldric  (leader)")
    T.has(api.visible(A.Social_Member2.name:GetText()), "Berra")
    -- set Berra's role from the row
    api.click(A.Social_Member2.role)
    T.eq(A.Social.RoleOf("Berra"), "t")
    api.click(A.Social_Member2.role)
    T.eq(A.Social.RoleOf("Berra"), "h")
    T.has(api.visible(A.Social_Member2.name:GetText()), "Healer")
    -- loot method
    T.ok(api.screen_has(A, "Loot: Free for all", A.Social_Frame))
    api.click(api.find_button(A, "Loot: Free for all", A.Social_Frame))
    api.pump(A)
    T.eq(A.__loot_method, "roundrobin")
    T.ok(api.screen_has(A, "Loot: Round robin", A.Social_Frame))
    api.click(api.find_button(A, "Loot: Round robin", A.Social_Frame))
    api.pump(A)
    T.eq(A.GetLootMethod(), "master", "master looter is you")
    T.ok(api.screen_has(A, "Loot: Master looter", A.Social_Frame))
    -- ready check goes through the Raid addon
    api.click(api.find_button(A, "Ready check", A.Social_Frame))
    local sent = A.__addon_sent[#A.__addon_sent]
    T.ok(sent and string.find(sent.msg, "^C:"), "Raid's ready check started")
    -- the Dungeons board, embedded
    C.Dungeons.DB().prefs.dungeons.dm = true
    C.Dungeons:List()
    api.tick(A, 3)
    A.Social:Refresh()
    T.shown(A.Social_BoardRow1, "a listing on the embedded board")
    T.has(api.visible(A.Social_BoardRow1.name:GetText()), "Corvin")
    T.eq(A.Social_BoardRow1.act:GetText(), "Invite")
end)

T.test("Social: Recent keeps people you grouped, traded and duelled with", function()
    local A = client("Aldric")
    local B = client("Berra", { class = "HUNTER", level = 14 })
    api.group({ A, B }, "party")
    api.set_unit(A, "npc", "Corvin")
    api.fire(A, "TRADE_SHOW")
    api.fire(A, "DUEL_REQUESTED", "Dagna")
    A.__slash("/social recent")
    T.has(api.visible(A.Social_Recent1.name:GetText()), "Dagna")
    T.has(api.visible(A.Social_Recent1.info:GetText()), "Duelled")
    T.has(api.visible(A.Social_Recent2.info:GetText()), "Traded")
    T.has(api.visible(A.Social_Recent3.name:GetText()), "Berra  14 Hunter")
    T.has(api.visible(A.Social_Recent3.info:GetText()), "Grouped")
    api.click(A.Social_Recent3.inv)
    T.eq(A.__invites[1], "Berra")
    api.click(A.Social_Recent3.add)
    api.pump(A)
    T.eq(A.__friends[1].name, "Berra")
    T.hidden(A.Social_Recent3.add, "already a friend")
end)

T.test("Social: number keys switch tabs while hovered; Escape and O close", function()
    local A = client("Aldric")
    A.__slash("/social")
    T.ok(A.Social:HandleKey("2"))
    T.eq(A.Social.tab, "guild")
    T.eq(A.Social.tabs:Selected(), "guild")
    A.Social:HandleKey("5")
    T.eq(A.Social.tab, "ignore")
    T.no(A.Social:HandleKey("W"), "other keys pass")
    A.Social:HandleKey("O")
    T.hidden(A.Social_Frame)
    A.__slash("/social")
    T.ok(api.press_escape(A))
    T.hidden(A.Social_Frame)
    -- the tabs themselves
    A.__slash("/social")
    api.click(A.Social.tabs:Button("who"))
    T.eq(A.Social.tab, "who")
end)

T.test("Social: the whole suite with Social loads and /social never errors", function()
    local A = T.suite({ name = "Aldric", friends = { "Berra" }, guild = { name = "Ashen Vanguard", members = 1 } })
    for _, arg in ipairs({ "", "friends", "guild", "group", "who", "ignore", "recent", "away", "busy", "lfg", "back", "help", "x" }) do
        A.__slash("/social " .. arg)
        api.tick(A, 0.3)
    end
    A.__slash("/vanilla")
    A.ToggleFriendsFrame()
    T.shown(A.FriendsFrame, "Pure Vanilla gives the stock window back")
end)

T.test("Social: the original Friends frame look, larger: sliced stock art, round portrait, bottom tabs", function()
    local A = client("Aldric")
    A.ToggleFriendsFrame()
    local f = A.Social_Frame
    T.ok(f.classic, "a classic frame")
    T.ok(f:GetWidth() > 352 and f:GetHeight() > 440, "bigger than the stock 352x440")
    -- the frame art covers the window exactly, built from the four stock quarters, never stretched
    local files, area = {}, 0
    for i = 1, f.cfPieces do
        local t = f.cfPool[i]
        local st = api.state(t)
        files[st.texture] = true
        T.ok(t:GetWidth() <= 140 and t:GetHeight() <= 144, "no piece larger than its source slice")
        area = area + t:GetWidth() * t:GetHeight()
    end
    T.eq(area, f:GetWidth() * f:GetHeight(), "the slices tile the whole frame")
    for _, q in ipairs({ "TopLeft", "TopRight", "BottomLeft", "BottomRight" }) do
        T.ok(files["Interface\\PaperDollInfoFrame\\UI-Character-General-" .. q], q .. " quarter used")
    end
    T.eq(api.state(f.portrait).texture, "Interface\\FriendsFrame\\FriendsFrameScrollIcon", "the stock Social portrait")
    -- tabs along the bottom, stock tab art, and they switch pages
    local b = f.tabs:Button("who")
    T.ok(b, "Who tab")
    local _, rel, rp = f.tabs:GetPoint(1)
    T.eq(rel, f); T.eq(rp, "BOTTOMLEFT", "tabs hang under the frame")
    T.eq(api.state(f.tabs:Button("friends").m).texture, "Interface\\PaperDollInfoFrame\\UI-Character-ActiveTab")
    T.eq(api.state(b.m).texture, "Interface\\PaperDollInfoFrame\\UI-Character-InActiveTab")
    api.click(b)
    T.eq(A.Social.tab, "who")
    T.eq(api.state(b.m).texture, "Interface\\PaperDollInfoFrame\\UI-Character-ActiveTab", "chosen tab lit")
    T.eq(A.Social.ui.heading:GetText(), "Who", "the header band names the tab")
    -- an empty list shows an emblem above its line, only on its own tab
    api.click(f.tabs:Button("ignore"))
    T.shown(A.Social.ui.ignore.emptyArt[1], "empty emblem")
    T.hidden(A.Social.ui.who.emptyArt[1], "other tabs' emblems hidden")
end)
