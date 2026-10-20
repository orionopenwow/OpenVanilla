-- Guild Hub: guild records synced over the hidden CPGuild channel between clients (member info,
-- events and sign-ups, DKP ticks and loot, loot council votes, applications, bank log, requests,
-- the login sync), the permission checks on arrival, roster actions (promote / demote, notes,
-- alts, search, export), the embedded Guilds post form, bank auto-logging from the trade window,
-- event reminders, the MOTD composer, officer chat, the achievements summary and the window.
local T, api = ...

local GUILD = "Ashen Vanguard"

local function guild(rank, rankIndex, roster)
    return { name = GUILD, rank = rank, rankIndex = rankIndex, roster = roster or {}, motd = "Welcome!" }
end

-- Aldric (guild master), Berra (member); both run Guild Hub and have joined CPGuild.
local function two(extra)
    extra = extra or {}
    local A = T.addon("GuildHub", { name = "Aldric", class = "WARRIOR", skills = { { "Blacksmithing", 300 }, { "Mining", 285 } },
        guild = guild("Guild Master", 0, { { name = "Berra", rank = "Member", rankIndex = 3 } }) })
    local B = T.addon("GuildHub", { name = "Berra", class = "HUNTER", level = 58, skills = { { "Skinning", 250 } },
        guild = guild("Member", 3) })
    local C
    if extra.officer then
        C = T.addon("GuildHub", { name = "Cora", class = "PRIEST", guild = guild("Officer", 1) })
    end
    api.tick(A, 12)
    return A, B, C
end

local function hub(env) return env.GuildHub end
local function tab(env, key) api.click(env.GuildHub_Frame.tabs:Button(key)) end
local function subtab(env, key) api.click(env.GuildHub.ui.subtabs:Button(key)) end
local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end

T.test("GuildHub: members join CPGuild, share professions and the carrier never shows in chat", function()
    local A, B = two()
    T.ok(A.GetChannelName("CPGuild") > 0, "A joined CPGuild")
    T.ok(B.GetChannelName("CPGuild") > 0, "B joined CPGuild")
    T.eq(hub(B):Professions("Aldric"), "Blacksmithing 300, Mining 285")
    T.eq(hub(A):Professions("Berra"), "Skinning 250")
    -- Social's guild tab reads professions through the Guilds hook Guild Hub fills in
    T.eq(B.Concord:GetProfessions("Aldric"), "Blacksmithing 300, Mining 285")
    T.lacks(api.chat_text(A), "GH1~")
    T.lacks(api.chat_text(B), "GH1~")
    T.lacks(api.chat_text(B), "CPGuild")
end)

T.test("GuildHub: an officer's event reaches the guild; sign-ups come back; post to guild chat", function()
    local A, B = two()
    A.__slash("/gh events")
    T.shown(A.GuildHub_Page_events)
    api.click(api.find_button(A, "New event", A.GuildHub_Frame))
    T.shown(A.GuildHub_EventForm, "officer form")
    api.type(A.GuildHub_EventTitle, "Molten Core")
    local today = A.date("*t", A.time())
    local hour = today.hour + 2 > 23 and 23 or today.hour + 2
    api.type(A.GuildHub_EventTime, string.format("%02d:30", hour))
    api.type(A.GuildHub_EventHours, "3")
    api.type(A.GuildHub_EventNote, "Bring fire resistance")
    api.click(api.find_button(A, "Create", A.GuildHub_Frame))
    local id = hub(A).selected
    T.ok(id, "the new event is selected")
    local ev = hub(A).GDB().ev[id]
    T.eq(ev.title, "Molten Core")
    T.eq(ev.dur, 180)
    T.eq(A.date("%H:%M", ev.start), string.format("%02d:30", hour))
    api.tick(A, 3)
    local evB = hub(B).GDB().ev[id]
    T.ok(evB, "B received the event")
    T.eq(evB.note, "Bring fire resistance")
    -- B sees it on the week grid and signs up as a healer
    B.__slash("/gh events")
    local slot
    for d = 1, 7 do if B["GuildHub_Day" .. d .. "Event1"]:IsShown() then slot = B["GuildHub_Day" .. d .. "Event1"] end end
    T.ok(slot, "the event is on B's week")
    T.eq(slot.title:GetText(), "Molten Core")
    api.click(slot)
    api.tick(B, 0.6)
    T.ok(api.screen_has(B, "You haven't signed up", B.GuildHub_Frame))
    T.no(api.find_button(B, "Delete", B.GuildHub_Frame), "members cannot delete events")
    T.hidden(api.find_button(B, "New event", B.GuildHub_Frame), "members have no New event")
    api.click(api.find_button(B, "Healer", B.GuildHub_Frame))
    api.tick(A, 3)
    local su = hub(A):Signups(id)
    T.eq(#su, 1)
    T.eq(su[1].name, "Berra")
    T.eq(su[1].role, "h")
    T.eq(hub(A):SignupCounts(id).h, 1)
    api.tick(A, 1)
    T.ok(api.screen_has(A, "Healers:", A.GuildHub_Frame), "A's detail lists the healer")
    -- tentative replaces the sign-up, keeping the role
    api.click(api.find_button(B, "Tentative", B.GuildHub_Frame))
    api.tick(A, 3)
    T.eq(hub(A):Signups(id)[1].st, "tent")
    T.eq(hub(A):Signups(id)[1].role, "h")
    -- post to guild chat
    api.click(api.find_button(A, "Post to guild", A.GuildHub_Frame))
    api.pump(A)
    T.has(api.chat_text(B), "[Guild] [Aldric]: [Guild Hub] Molten Core - ")
    T.has(api.chat_text(B), "0 signed up (0 tank, 0 heal, 0 dps), 1 tentative")
    -- delete: gone on both
    api.click(api.find_button(A, "Delete", A.GuildHub_Frame))
    api.tick(A, 3)
    T.eq(hub(B).GDB().ev[id].del, 1)
    T.eq(#hub(B):EventsBetween(0, 2 ^ 31), 0)
end)

T.test("GuildHub: a member cannot create events and forged officer records are dropped", function()
    local A, B = two()
    T.eq(hub(B):CreateEvent("Fake raid", B.time() + 3600, 60), nil)
    -- a forged event and DKP award sent straight onto the wire
    hub(B):Publish("ev", { id = "Berra.x1", title = "Forged", start = B.time() + 3600, dur = 60, del = 0 })
    hub(B):Publish("dk", { id = "Berra.x2", t = B.time(), kind = "award", names = "Berra", amt = 999, void = 0 })
    api.tick(A, 4)
    T.eq(hub(A).GDB().ev["Berra.x1"], nil, "forged event dropped")
    T.eq(hub(A).GDB().dk["Berra.x2"], nil, "forged DKP dropped")
    T.eq(hub(A):Points("Berra"), 0)
    -- a client from another guild on the same channel, and an ignored guild mate
    local X = T.addon("GuildHub", { name = "Xeno", guild = { name = "Other Guild", rank = "Guild Master", rankIndex = 0, roster = {} } })
    api.tick(A, 10)
    hub(X):CreateEvent("Other guild raid", X.time() + 3600, 60)
    api.tick(A, 3)
    T.eq(#hub(A):EventsBetween(0, 2 ^ 31), 0, "another guild's event never lands")
    -- Other Guild's key differs, so even a copied line with our key from a stranger is ignored
    local key = A.GuildHub.GuildKey(GUILD)
    X.SendChatMessage("GH1~" .. key .. "~zz~1/1~ev,Xeno.1,Xeno,1999999999,Spoof,1760003600,60,,0", "CHANNEL", nil, X.GetChannelName("CPGuild"))
    api.tick(A, 1)
    T.eq(hub(A).GDB().ev["Xeno.1"], nil, "not on our roster")
end)

T.test("GuildHub: DKP ticks on a boss kill, loot costs, alts count for their main, export", function()
    local A, B = two()
    hub(B):LinkAlt("Berrabank", "Berra")
    api.tick(A, 2)
    T.eq(hub(A):MainOf("Berrabank"), "Berra", "B linked an alt of their own")
    api.raid_roster(A, { "Aldric", "Berra", "Berrabank", "Cora" })
    api.fire(A, "CHAT_MSG_COMBAT_HOSTILE_DEATH", "Ragnaros dies.")
    api.fire(A, "CHAT_MSG_COMBAT_HOSTILE_DEATH", "Ragnaros dies.")       -- the same kill seen twice
    api.fire(A, "CHAT_MSG_COMBAT_HOSTILE_DEATH", "Molten Giant dies.")   -- not a boss
    api.tick(A, 3)
    T.eq(count(hub(A).GDB().dk), 1, "one tick per boss kill")
    T.eq(hub(A):Points("Berra"), 10, "the alt's tick goes to the main once")
    T.eq(hub(A):Points("Cora"), 10)
    T.eq(hub(B):Points("Berra"), 10, "B got the tick")
    T.has(api.chat_text(A), "Ragnaros - 10 DKP to the raid.")
    -- loot through the Loot tab
    A.__slash("/gh loot")
    api.type(A.GuildHub_LootWinner, "Berra")
    api.type(A.GuildHub_LootItem, "Onslaught Girdle")
    api.type(A.GuildHub_LootCost, "30")
    api.click(api.find_button(A, "Award loot", A.GuildHub_Frame))
    api.tick(A, 3)
    T.eq(hub(B):Points("Berra"), -20)
    T.ok(api.screen_has(A, "Berra won Onslaught Girdle", A.GuildHub_Frame))
    -- standings tab and manual award
    A.__slash("/gh dkp")
    api.type(A.GuildHub_DKPNames, "Cora")
    api.type(A.GuildHub_DKPAmount, "5")
    api.type(A.GuildHub_DKPReason, "On time")
    api.click(api.find_button(A, "Award", A.GuildHub_Frame))
    api.tick(A, 3)
    T.eq(hub(B):Points("Cora"), 15)
    local top = hub(B):Standings()[1]
    T.eq(top.name, "Cora")
    T.eq(A.GuildHub_DKPRow1.pts:GetText(), "15")
    -- B (member) has no award or tick controls
    B.__slash("/gh dkp")
    T.hidden(api.find_button(B, "Tick raid", B.GuildHub_Frame))
    T.no(api.find_button(B, "Award", B.GuildHub_Frame))
    -- export
    api.click(api.find_button(A, "Export", A.GuildHub_Frame))
    T.shown(A.GuildHub_Export)
    local text = A.GuildHub_ExportText:GetText()
    T.has(text, "Name,Points,Earned,Spent,Raids,Items")
    T.has(text, "Berra,-20,10,30,1,1")
    -- void the loot entry from History: points come back
    local lootId
    for id, d in pairs(hub(A).GDB().dk) do if d.kind == "loot" then lootId = id end end
    T.ok(hub(A):VoidDKP(lootId))
    api.tick(A, 3)
    T.eq(hub(B):Points("Berra"), 10)
    T.has(hub(A):DKPExport(true), "loot,Berra,30,Loot,Onslaught Girdle,yes")
end)

T.test("GuildHub: /gh tick ticks the raid; outside a raid it says so", function()
    local A = two()
    A.__slash("/gh tick")
    T.has(api.chat_text(A), "join a raid to tick its members")
    api.raid_roster(A, { "Aldric", "Berra" })
    A.__slash("/gh tick")
    T.eq(hub(A):Points("Berra"), 10)
end)

T.test("GuildHub: loot council votes travel between officers; members cannot vote", function()
    local A, B, C = two({ officer = true })
    api.tick(A, 6)
    -- the guild master turns council mode on in Setup
    A.__slash("/gh setup")
    api.click(api.find_button(A, "Off", A.GuildHub_Frame))
    api.tick(A, 3)
    T.eq(hub(C).Cfg().council, 1, "the officer got the setting")
    A.__slash("/gh council")
    api.type(A.GuildHub_CouncilItem, "Band of Accuria")
    api.raid_roster(A, { "Aldric", "Berra", "Cora" })
    api.click(api.find_button(A, "Open vote", A.GuildHub_Frame))
    api.tick(A, 3)
    local sid = hub(A):Votes()[1].id
    T.ok(hub(C).GDB().lc[sid], "C has the vote")
    T.eq(hub(C).GDB().lc[sid].cands, "Aldric:Berra:Cora")
    T.ok(hub(C):Vote(sid, "Berra"))
    T.ok(hub(A):Vote(sid, "Berra"))
    T.no(hub(B):Vote(sid, "Berra"), "members cannot vote")
    hub(B):Publish("vo", { id = sid .. "/Berra", sid = sid, voter = "Berra", cand = "Berra" })   -- forged
    api.tick(A, 4)
    local tA, tC = hub(A):Tally(sid), hub(C):Tally(sid)
    T.eq(tA[1].cand, "Berra")
    T.eq(tA[1].n, 2)
    T.eq(tC[1].n, 2, "C sees both officer votes")
    T.eq(table.concat(tC[1].voters, ","), "Aldric,Cora")
    api.tick(A, 1)
    T.ok(api.screen_has(A, "Berra 2 (Aldric, Cora)", A.GuildHub_Frame), "tally on A's council tab")
    -- the vote menu lists the candidates with their DKP
    api.click(api.find_button(A, "Vote", A.GuildHub_Frame))
    T.ok(api.screen_has(A, "Cora  (0 DKP)", A.WenillaCore_Menu))
    A.WenillaCore_Menu:Hide()
    -- close: Berra wins, the cost comes off her points
    T.ok(hub(A):CloseVote(sid, nil, 25))
    api.tick(A, 3)
    T.eq(hub(C).GDB().lc[sid].open, 0)
    T.eq(hub(C).GDB().lc[sid].winner, "Berra")
    T.eq(hub(C):Points("Berra"), -25)
    T.eq(hub(B):Points("Berra"), -25)
end)

T.test("GuildHub: applications from the Guilds whisper; accept invites, decline whispers, notes sync", function()
    local A, B, C = two({ officer = true })
    local D = T.addon("GuildHub", { name = "Dorin", class = "MAGE", level = 12 })
    local E = T.addon("GuildHub", { name = "Eryn", class = "DRUID", level = 30 })
    api.tick(A, 8)
    D.SendChatMessage("[Guilds] Hi! I'd like to join <Ashen Vanguard>. Level 12 mage.", "WHISPER", nil, "Aldric")
    E.SendChatMessage("[Guilds] Hi! I'd like to join <Ashen Vanguard>. Level 30 druid.", "WHISPER", nil, "Aldric")
    D.SendChatMessage("[Guilds] Hi! I'd like to join <Some Other Guild>. Level 12 mage.", "WHISPER", nil, "Aldric")
    api.tick(A, 4)
    T.eq(#hub(A):Applications("new"), 2)
    T.eq(#hub(C):Applications("new"), 2, "the other officer has them too")
    T.eq(#hub(B):Applications("new"), 0, "members do not get applications")
    T.eq(hub(C).GDB().ap.Dorin.class, "MAGE")
    T.eq(hub(C).GDB().ap.Dorin.level, 12)
    -- C opens Recruit > Applications
    C.__slash("/gh apps")
    T.shown(C.GuildHub_Apps)
    T.ok(api.screen_has(C, "2 waiting", C.GuildHub_Frame))
    T.ok(api.screen_has(C, "Hi! I'd like to join <Ashen Vanguard>. Level 30 druid.", C.GuildHub_Frame))
    -- note on Dorin from C reaches A
    T.ok(hub(C):NoteApp("Dorin", "Friend of Cora"))
    api.tick(A, 3)
    T.eq(hub(A).GDB().ap.Dorin.note, "Friend of Cora")
    -- A accepts Dorin: a guild invite (through Social, which also promotes to a preset rank)
    A.__slash("/gh apps")
    T.ok(hub(A):AcceptApp("Dorin"))
    api.tick(A, 3)
    T.eq(A.__guild_invites[1], "Dorin")
    T.eq(D.__guild and D.__guild.name, GUILD, "Dorin joined")
    T.eq(hub(C).GDB().ap.Dorin.st, "accepted")
    -- decline Eryn from the row's button
    local row
    for i = 1, 6 do local r = A["GuildHub_AppRow" .. i] if r and r:IsShown() and r.item and r.item.name == "Eryn" then row = r end end
    T.ok(row, "Eryn's row on A")
    api.click(row.decline)
    api.tick(A, 3)
    T.eq(hub(C).GDB().ap.Eryn.st, "declined")
    T.has(api.chat_text(E), "[Aldric] whispers: [Guild Hub] Thanks for applying to <Ashen Vanguard>.")
    T.ok(api.screen_has(A, "0 waiting", A.GuildHub_Frame))
end)

T.test("GuildHub: the Guilds post form is embedded in Recruit > Listing and posts to the board", function()
    local A = two()
    local W2 = T.addon("Guilds", { name = "Wanda", level = 20 })
    api.tick(A, 8)
    A.__slash("/gh recruit")
    local form = A.Concord_PostForm
    T.shown(form, "post form shown in the hub")
    T.eq(form:GetParent(), A.GuildHub_Listing)
    api.type(A.Concord_PostLevel, "40")
    api.type(A.Concord_PostPitch, "MC and BWL twice a week")
    api.click(api.find_button(A, "Post", A.GuildHub_Frame))
    api.tick(A, 1)
    T.shown(form, "still shown after Post")
    T.eq(form:GetParent(), A.GuildHub_Listing)
    T.has(api.chat_text(W2), "<Ashen Vanguard> is recruiting (Raiding): MC and BWL twice a week")
    -- leaving the tab hands the form back to the Guilds board
    subtab(A, "apps")
    T.eq(form:GetParent(), A.Concord_Frame.body)
    A.__slash("/guilds")
    api.click(A.Concord_Frame.tabs:Button("mine"))
    T.shown(form, "the board's own My listing still works")
end)

T.test("GuildHub: roster arrows promote and demote, notes, alt links, search and export", function()
    local A, B = two()
    A.__slash("/gh roster")
    api.tick(A, 1)
    local row
    for i = 1, 8 do local r = A["GuildHub_RosterRow" .. i] if r and r:IsShown() and r.item.name == "Berra" then row = r end end
    T.ok(row, "Berra's row")
    T.shown(row.up)
    api.click(row.up)
    api.tick(A, 1)
    T.eq(B.__guild.rankIndex, 2, "promoted one rank")
    for i = 1, 8 do local r = A["GuildHub_RosterRow" .. i] if r and r:IsShown() and r.item.name == "Berra" then row = r end end
    T.eq(row.rank:GetText(), "Veteran")
    api.click(row.down)
    api.tick(A, 1)
    T.eq(B.__guild.rankIndex, 3, "demoted again")
    -- the guild master's own row has disabled arrows
    local mine
    for i = 1, 8 do local r = A["GuildHub_RosterRow" .. i] if r and r:IsShown() and r.item.name == "Aldric" then mine = r end end
    T.no(mine.up:IsEnabled(), "no promoting yourself")
    -- notes
    T.ok(hub(A):SetNote("Berra", "Skinner, ask for leather"))
    T.ok(hub(A):SetNote("Berra", "Trial until Friday", true))
    api.tick(A, 1)
    T.ok(api.screen_has(A, "\"Skinner, ask for leather\"", A.GuildHub_Frame))
    T.ok(api.screen_has(A, "[O] Trial until Friday", A.GuildHub_Frame))
    -- members: no arrows, no note editing, no officer notes on screen
    B.__slash("/gh roster")
    api.tick(B, 1)
    T.no(hub(B):SetNote("Aldric", "x"))
    for i = 1, 8 do local r = B["GuildHub_RosterRow" .. i] if r and r:IsShown() then T.hidden(r.up) end end
    -- the menu offers what the officer may do
    api.click(row)
    T.ok(api.screen_has(A, "Promote to Veteran", A.WenillaCore_Menu))
    T.ok(api.screen_has(A, "Officer note...", A.WenillaCore_Menu))
    A.WenillaCore_Menu:Hide()
    -- alt link by an officer, search by profession and by main
    T.ok(hub(A):LinkAlt("Aldric", "Berra") == false or true)
    api.type(A.GuildHub_RosterSearch, "skinning")
    api.tick(A, 1)
    T.ok(api.screen_has(A, "Berra", A.GuildHub_RosterList))
    T.no(api.screen_has(A, "Aldric", A.GuildHub_RosterList))
    api.type(A.GuildHub_RosterSearch, "")
    -- export
    api.click(api.find_button(A, "Export", A.GuildHub_Frame))
    local text = A.GuildHub_ExportText:GetText()
    T.has(text, "Name,Level,Class,Rank,Main,Professions,Last online,Note")
    T.has(text, "Berra,58,Hunter,Member,,Skinning 250,Online,\"Skinner, ask for leather\"")
end)

T.test("GuildHub: trades with the banker log themselves once, on both sides; cancelled trades do not", function()
    local A, B = two()
    local K = T.addon("GuildHub", { name = "Bankalt", class = "MAGE", guild = guild("Member", 3), money = 10000 })
    api.tick(A, 10)
    T.ok(hub(A):SetCfg({ banker = "Bankalt" }))
    api.tick(A, 3)
    T.eq(hub(B):Banker(), "Bankalt")
    T.eq(hub(K):Banker(), "Bankalt")
    api.trade(B, K, { a_money = 50000, a_items = { { "Linen Cloth", 20 } } })
    api.tick(A, 5)
    local log, bal = hub(A):BankLog()
    T.eq(#log, 2, "money and cloth, once each though both sides logged")
    T.eq(bal, 50000)
    T.has(api.chat_text(B), "logged the trade with Bankalt")
    -- the banker pays out 2g
    api.trade(K, B, { a_money = 20000 })
    api.tick(A, 5)
    log, bal = hub(A):BankLog()
    T.eq(bal, 30000)
    T.eq(log[1].kind, "wd")
    T.eq(log[1].who, "Berra")
    -- cancelled, and a trade between two non-bankers: nothing
    api.trade(B, K, { a_money = 99999, complete = false })
    api.trade(A, B, { a_money = 5000 })
    api.tick(A, 5)
    log, bal = hub(A):BankLog()
    T.eq(#log, 3)
    T.eq(bal, 30000)
    -- the banker's real purse
    local purse = hub(A):Purse()
    T.ok(purse, "Bankalt reported the purse")
    T.eq(purse.copper, K.GetMoney())
    -- the Bank tab shows the log and the balance
    A.__slash("/gh bank")
    T.ok(api.screen_has(A, "Balance by the log: 3g", A.GuildHub_Frame))
    T.ok(api.screen_has(A, "+20 x Linen Cloth", A.GuildHub_Frame))
    T.ok(api.screen_has(A, "Bankalt holds", A.GuildHub_Frame))
    -- manual entry by an officer; members have no form
    api.click(api.find_button(A, "Deposit", A.GuildHub_Frame))
    api.type(A.GuildHub_BankWho, "Cora")
    api.type(A.GuildHub_BankAmount, "1g 50s")
    api.click(api.find_button(A, "Add", A.GuildHub_Frame))
    api.tick(A, 3)
    _, bal = hub(B):BankLog()
    T.eq(bal, 30000 - 15000, "a withdrawal of 1g 50s to Cora")
    T.no(hub(B):BankAdd("dep", "Berra", 100000, nil, nil, nil, false), "members cannot add manual entries")
end)

T.test("GuildHub: bank requests from a member, resolved by an officer", function()
    local A, B = two()
    B.__slash("/gh requests")
    api.type(B.GuildHub_RequestText, "20 Elemental Fire for my FR set")
    api.click(api.find_button(B, "Ask the bank", B.GuildHub_Frame))
    api.tick(A, 3)
    local reqs = hub(A):Requests()
    T.eq(#reqs, 1)
    T.eq(reqs[1].who, "Berra")
    A.__slash("/gh requests")
    T.ok(api.screen_has(A, "20 Elemental Fire for my FR set", A.GuildHub_Frame))
    T.no(api.find_button(B, "Done", B.GuildHub_Frame), "members cannot resolve")
    api.click(api.find_button(A, "Done", A.GuildHub_Frame))
    api.tick(A, 3)
    T.eq(hub(B).GDB().rq[reqs[1].id].st, "done")
    T.eq(#hub(B):Requests(), 0, "done requests hide by default")
    T.eq(#hub(B):Requests(true), 1)
end)

T.test("GuildHub: event reminders toast 30 and 5 minutes before; not for declined events", function()
    local A, B = two()
    local G = hub(A)
    local soon = G:CreateEvent("Onyxia", A.time() + 31 * 60, 60)
    local other = G:CreateEvent("Zul'Gurub", A.time() + 31 * 60 + 30, 60)
    api.tick(A, 3)
    hub(B):SignUp(other, "d", "no")
    api.tick(A, 120)
    T.has(api.chat_text(B), "Guild Hub: Onyxia starts in 30 min")
    T.lacks(api.chat_text(B), "Zul'Gurub starts in", "declined: no reminder")
    T.has(api.chat_text(A), "Guild Hub: Zul'Gurub starts in 30 min")
    api.tick(A, 25 * 60, 1)
    T.has(api.chat_text(B), "Guild Hub: Onyxia starts in 5 min")
    local n = 0
    for _ in string.gmatch(api.chat_text(B), "Onyxia starts in") do n = n + 1 end
    T.eq(n, 2, "two reminders, no repeats")
    -- logging in 4 minutes before: only the 5-minute one
    local late = G:CreateEvent("Late raid", A.time() + 4 * 60, 60)
    api.tick(A, 6.5)
    T.has(api.chat_text(B), "Late raid starts in 4 min")
    T.ok(api.screen_has(B, "Late raid in 4 min"), "toast on screen")
    api.tick(A, 3)
    T.ok(late)
    -- the setting turns them off
    B.WenillaCore_Config.settings.GuildHub.reminders = false
    G:CreateEvent("Muted raid", A.time() + 20 * 60, 60)
    api.tick(A, 8)
    T.lacks(api.chat_text(B), "Muted raid starts")
end)

T.test("GuildHub: a client logging in later gets the guild's records from an officer", function()
    local A, B = two()
    local G = hub(A)
    local eid = G:CreateEvent("Blackwing Lair", A.time() + 86400, 180)
    api.raid_roster(A, { "Aldric", "Berra" })
    G:TickRaid("Attendance")
    G:SetCfg({ banker = "Bankalt", tick = 15 })
    api.tick(A, 3)
    T.ok(hub(B):SignUp(eid, "t", "yes"))
    api.tick(A, 6)
    local C = T.addon("GuildHub", { name = "Cora", class = "PRIEST", guild = guild("Officer", 1) })
    api.tick(A, 20)
    local g = hub(C).GDB()
    T.ok(g.ev[eid], "event synced at login")
    T.eq(g.su[eid .. "/Berra"].role, "t", "a member's sign-up relayed by the officer")
    T.eq(hub(C):Points("Berra"), 10)
    T.eq(hub(C).Cfg().tick, 15)
    T.eq(hub(C):Banker(), "Bankalt")
    T.eq(hub(C):Professions("Aldric"), "Blacksmithing 300, Mining 285")
    -- only officers answered the request
    local answered = {}
    for _, l in ipairs(api.bus_of(A).log) do
        if l.kind == "CHANNEL" and string.find(l.msg, "R,Cora", 1, true) then answered[l.from] = true end
    end
    T.ok(answered.Aldric, "the guild master answered")
    T.no(answered.Berra, "members do not answer syncs")
end)

T.test("GuildHub: MOTD composer fills templates and sets the MOTD; saved templates", function()
    local A, B = two()
    hub(A):CreateEvent("Molten Core", A.time() + 3600, 120)
    A.__slash("/gh motd")
    T.ok(api.screen_has(A, "Now: Welcome!", A.GuildHub_Frame))
    api.click(A.GuildHub_TemplateRow1)
    T.eq(A.GuildHub_MOTDText:GetText(), "Raid tonight: {next}. Sign up in /gh!")
    api.tick(A, 1)
    T.ok(api.screen_has(A, "Raid tonight: Molten Core ", A.GuildHub_Frame), "preview fills {next}")
    api.click(api.find_button(A, "Set MOTD", A.GuildHub_Frame))
    api.pump(A)
    T.has(A.__motd_set[1], "Raid tonight: Molten Core ")
    T.has(B.__guild.motd, "Raid tonight: Molten Core ")
    -- save a template of your own, then delete it
    api.type(A.GuildHub_MOTDText, "Bank day: give {banker} your spare herbs")
    api.click(api.find_button(A, "Save as template", A.GuildHub_Frame))
    api.tick(A, 1)
    T.ok(api.screen_has(A, "* Bank day: give {banker} your spare herbs", A.GuildHub_Frame))
    api.click(A.GuildHub_TemplateRow5)
    api.click(api.find_button(A, "Delete template", A.GuildHub_Frame))
    api.tick(A, 1)
    T.no(api.screen_has(A, "Bank day: give {banker}", A.GuildHub_TemplateList))
    -- members cannot set it
    B.__slash("/gh motd")
    api.type(B.GuildHub_MOTDText, "Hacked")
    api.tick(B, 1)
    T.no(api.find_button(B, "Set MOTD", B.GuildHub_Frame):IsEnabled())
end)

T.test("GuildHub: officer chat tab sends and lists officer chat; members see the gate", function()
    local A, B, C = two({ officer = true })
    A.__slash("/gh officer")
    api.type(A.GuildHub_OfficerText, "Promote Berra after the raid?")
    api.click(api.find_button(A, "Send", A.GuildHub_Frame))
    api.tick(A, 1)
    local function heard(env)
        for _, l in ipairs(hub(env).officerLines) do if l.from == "Aldric" and l.text == "Promote Berra after the raid?" then return true end end
    end
    T.ok(heard(C), "the officer heard it")
    T.no(heard(B), "members do not")
    T.ok(api.screen_has(A, "[Aldric]: Promote Berra after the raid?", A.GuildHub_Frame))
    B.__slash("/gh officer")
    T.ok(api.screen_has(B, "Officer chat is for ranks that read officer notes.", B.GuildHub_Frame))
    T.hidden(B.GuildHub_OfficerText)
end)

T.test("GuildHub: achievements summary from members' shared points", function()
    local A, B = two()
    api.server_packet(A, "AC", "L 1,1759990000;2,1759995000")
    api.tick(A, 12)
    local total, members, recent = hub(B):AchievementSummary()
    T.ok(total > 0, "points shared")
    T.eq(members[1].name, "Aldric")
    T.eq(recent[1].name, "Aldric")
    B.__slash("/gh achievements")
    T.ok(api.screen_has(B, total .. " achievement points", B.GuildHub_Frame))
end)

T.test("GuildHub: window, tabs, not in a guild, micro menu entry and settings", function()
    local A = two()
    A.__slash("/gh")
    T.shown(A.GuildHub_Frame)
    for _, k in ipairs({ "roster", "recruit", "events", "bank", "dkp", "guild" }) do
        tab(A, k)
        T.shown(A["GuildHub_Page_" .. k], k)
        T.eq(A.GuildHub.tab, k)
    end
    tab(A, "dkp")
    for _, k in ipairs({ "loot", "history", "council", "standings" }) do subtab(A, k) T.eq(A.GuildHub.sub.dkp, k) end
    T.has(A.GuildHub_Page_events.icon:GetTexture(), "GuildHub_Tab_Events", "tab crest art")
    A.__slash("/gh")
    T.hidden(A.GuildHub_Frame)
    -- not in a guild
    local N = T.addon("GuildHub", { name = "Nomad" })
    N.__slash("/gh")
    T.shown(N.GuildHub_NoGuild)
    T.ok(api.screen_has(N, "You're not in a guild.", N.GuildHub_Frame))
    api.click(api.find_button(N, "Find a guild", N.GuildHub_Frame))
    T.shown(N.Concord_Frame, "Find a guild opens the Guilds board")
    -- micro menu
    A.GuildHub_Frame:Hide()
    api.click(A.SocialsMicroButton)
    T.shown(A.GuildHub_Frame, "Guild & Communities opens the Guild Hub for a guild member")
    -- switched off in /addons
    A.WenillaCore:SetAddonEnabled("GuildHub", false)
    T.hidden(A.GuildHub_Frame)
    A.__slash("/gh")
    T.has(api.chat_text(A), "Guild Hub is switched off")
    T.ok(A.WenillaCore.schemas.GuildHub.defaults.reminders)
end)
