-- Live: the LIVE marks (Social/Live.lua) and Persona's listening field - the LV packet, the
-- "Show me as LIVE" opt-in (.wnl liveopt), marks in Social's lists, the Dungeons board, the player
-- tooltip and Persona's badge, /live; Persona.SetListening, the desktop shim and its expiry.
local T, api = ...

local function client(name, opts)
    opts = opts or {}
    opts.name = name
    return T.addon("Social", opts)
end

local function sent(env, prefix)
    local out = {}
    for _, l in ipairs(env.__wnl) do
        if string.sub(l, 1, string.len(prefix)) == prefix then table.insert(out, l) end
    end
    return out
end

local LIVE = "\226\128\162 LIVE"

T.test("Live: LV marks names in Social's lists; bad names are dropped; LV - clears", function()
    local A = client("Aldric", { friends = { "Berra", "Corvin" } })
    local B = client("Berra", { class = "HUNTER", level = 14 })
    api.connect(A)
    api.server_packet(A, "LV", "berra;Zed;bad name;|cffff0000Eve|r;X;Toolongnametoolongname1")
    T.eq(table.concat(A.Social.liveList, ","), "Berra,Zed")
    T.ok(A.Social:IsLive("Berra"))
    T.no(A.Social:IsLive("Corvin"))
    A.__slash("/social")
    T.has(A.Social_Friend1.name:GetText(), LIVE, "Berra's row carries the mark")
    T.has(api.visible(A.Social_Friend1.name:GetText()), "Berra")
    T.lacks(A.Social_Friend2.name:GetText(), "LIVE", "offline Corvin has none")
    -- chunked, as the server sends it
    api.server_packet(A, "LV", "7 1/1 -")
    T.eq(table.concat(A.Social.liveList, ","), "")
    T.lacks(A.Social_Friend1.name:GetText(), "LIVE", "the list redraws when the marks change")
    T.ok(B)
end)

T.test("Live: Show me as LIVE is off by default; .wnl liveopt follows connection and the switch", function()
    local A = client("Aldric")
    T.eq(A.WenillaCore:Setting("Social", "showLive", nil), false, "off by default")
    api.tick(A, 3)
    T.eq(table.getn(sent(A, "liveopt")), 0, "nothing before the server greets")
    api.connect(A)
    api.tick(A, 2)
    T.eq(table.concat(sent(A, "liveopt"), "|"), "liveopt 0", "every client asks for the list once (0 = not me)")
    api.tick(A, 5)
    T.eq(table.getn(sent(A, "liveopt")), 1, "said once, not every second")
    A.WenillaCore:Settings("Social").showLive = true
    api.tick(A, 2)
    T.eq(sent(A, "liveopt")[2], "liveopt 1")
    A.WenillaCore:SetAddonEnabled("Social", false)
    api.tick(A, 2)
    T.eq(sent(A, "liveopt")[3], "liveopt 0", "switching Social off withdraws the consent")
    -- the switch is in Social's settings sheet
    A.WenillaCore:SetAddonEnabled("Social", true)
    A.__slash("/social")
    A.Social.sheet:Toggle()
    T.ok(api.screen_has(A, "Show me as LIVE"), "the settings sheet lists it")
end)

T.test("Live: /live lists who is live with player links and where to watch", function()
    local A = client("Aldric")
    A.__slash("/live")
    T.has(api.chat_text(A), "isn't connected")
    api.server_packet(A, "LV", "Berra;Zed")
    A.__slash("/live")
    local chat = api.chat_text(A)
    T.has(chat, "LIVE")
    T.has(chat, "|Hplayer:Berra|h[Berra]|h")
    T.has(chat, "|Hplayer:Zed|h[Zed]|h")
    T.has(chat, "openvanilla.app/streamers.html")
    T.has(chat, "Show me as LIVE", "a nudge for streamers who haven't switched it on")
    api.server_packet(A, "LV", "-")
    A.__slash("/live")
    T.has(api.chat_text(A), "Nobody on the realm is live right now")
end)

T.test("Live: the Dungeons board, the player tooltip and Persona's badge show the mark", function()
    local A = client("Aldric", { level = 20 })
    local B = client("Berra", { class = "HUNTER", level = 19 })
    api.tick(A, 12)
    B.Dungeons.DB().prefs.dungeons.dm = true
    B.Dungeons:List()
    api.tick(A, 3)
    api.server_packet(A, "LV", "Berra")
    A.__slash("/lfg")
    T.has(A.Dungeons_BoardRow1.name:GetText(), LIVE, "board row")
    api.enter(A.Dungeons_BoardRow1)
    T.has(api.tooltip_text(A), "LIVE")
    -- mouse over Berra in the world
    api.mouseover(A, "Berra")
    local tip = table.concat(api.tooltip_lines(A), "\n")
    T.has(tip, "streaming now")
    T.has(tip, "openvanilla.app/streamers.html")
    -- target: Persona's Live badge instead of the status gem (Berra has no Persona yet)
    api.set_target(A, "Berra")
    T.shown(A.PersonaTargetBadge)
    local liveGem = A.PersonaTargetBadge.gem:GetTexture()
    T.has(liveGem, "Live", "the Live art")
    api.enter(A.PersonaTargetBadge)
    T.has(api.tooltip_text(A), "streaming now")
    -- the profile page shows the Live plate
    A.Persona.ShowView("Berra")
    T.shown(A.PersonaFrame.view.live)
    api.server_packet(A, "LV", "-")
    T.hidden(A.PersonaFrame.view.live, "the open profile follows the list")
    api.set_target(A, "Berra")
    T.lacks(A.PersonaTargetBadge.gem:GetTexture() or "", "Live", "back to Berra's status gem")
end)

T.test("Live: marks need Social switched on", function()
    local A = client("Aldric", { friends = { "Berra" } })
    local B = client("Berra")
    api.server_packet(A, "LV", "Berra")
    A.WenillaCore:SetAddonEnabled("Social", false)
    T.no(A.Social:IsLive("Berra"))
    T.eq(A.Social:LiveTag("Berra"), "")
    T.ok(B)
end)

-- Persona: listening -------------------------------------------------------------------------------

T.test("Persona: listening reaches other players' tooltips and profile pages", function()
    local A = T.addon("Persona", { name = "Aldric" })
    local B = T.addon("Persona", { name = "Berra" })
    api.tick(A, 6)
    T.eq(A.Persona.Mine().listening or "", "", "nothing by default")
    local rev = A.Persona.Mine().rev or 0
    T.ok(A.Persona.SetListening("  Bloodborne |cffff0000OST|r - Ryan Amon  "))
    T.eq(A.Persona.Mine().listening, "Bloodborne  cffff0000OST r - Ryan Amon", "trimmed, no pipes")
    T.eq(A.Persona.Mine().rev, rev + 1, "a new revision")
    T.no(A.Persona.SetListening("Bloodborne  cffff0000OST r - Ryan Amon"), "the same song again changes nothing")
    A.Persona.SetListening("Tavern Song - Unknown Bard")
    api.tick(A, 3)
    api.mouseover(B, "Aldric")
    api.tick(A, 20)
    api.mouseover(B, "Aldric")
    T.has(table.concat(api.tooltip_lines(B), "\n"), "Listening: Tavern Song - Unknown Bard")
    B.__slash("/rp aldric")
    T.has(api.visible(B.PersonaFrame.view.text:GetText()), "Listening to: Tavern Song - Unknown Bard")
    -- 80 characters at most
    A.Persona.SetListening(string.rep("x", 120))
    T.eq(string.len(A.Persona.Mine().listening), 80)
    -- the reader can switch the line off
    B.WenillaCore = B.WenillaCore
    A.Persona.SetListening("")
    T.eq(A.Persona.Mine().listening, "")
end)

T.test("Persona: the desktop shim (Persona_NowPlaying) is read at login and expires", function()
    local epoch = api.bus.epoch
    local A = T.addon("Persona", { name = "Aldric", saved = { Persona_NowPlaying = { text = "Song A - Band", at = epoch - 30 } } })
    T.eq(A.Persona.Mine().listening, "Song A - Band", "fresh value picked up at login")
    api.tick(A, 400)
    T.eq(A.Persona.Mine().listening, "Song A - Band")
    api.tick(A, 300)
    T.eq(A.Persona.Mine().listening, "", "gone ten minutes after the launcher wrote it")
    -- a stale or missing shim clears what the last session left
    local B = T.addon("Persona", { name = "Berra", saved = { Persona_NowPlaying = { text = "Old - Song", at = epoch - 3600 },
        Persona_DB = { mine = { ["Open Vanilla"] = { Berra = { name = "", title = "", status = "ooc", rev = 4, listening = "Yesterday - Band" } } } } } })
    T.eq(B.Persona.Mine().listening, "")
    T.eq(B.Persona.Mine().rev, 5)
    local C = T.addon("Persona", { name = "Corvin", saved = { Persona_NowPlaying = { text = 5, at = "x" } } })
    T.eq(C.Persona.Mine().listening or "", "", "junk is ignored")
end)
