-- Armory: Social's "Armory: Public / Friends only / Hidden" setting (Social/Armory.lua) - the
-- ".wnl armory" query once per connection, changes from the settings sheet and /armory, the AR
-- answer, the copyable link (friends only: with the key; realm folder from the realm name), errors.
local T, api = ...

local function sent(env, prefix)
    local out = {}
    for _, l in ipairs(env.__wnl) do
        if string.sub(l, 1, string.len(prefix)) == prefix then table.insert(out, l) end
    end
    return out
end

local function client(opts)
    opts = opts or {}
    opts.name = opts.name or "Aldric"
    opts.realm = opts.realm or "Vanilla Reloaded"
    return T.addon("Social", opts)
end

T.test("Armory: asks the realm once per connection; AR sets the mode", function()
    local A = client()
    api.tick(A, 3)
    T.eq(table.getn(sent(A, "armory")), 0, "nothing before the server greets")
    api.connect(A)
    api.tick(A, 2)
    T.eq(table.concat(sent(A, "armory"), "|"), "armory", "the bare query")
    api.tick(A, 5)
    T.eq(table.getn(sent(A, "armory")), 1, "once, not every second")
    api.server_packet(A, "AR", "hidden,")
    T.eq(A.Social.armory.mode, "hidden")
    T.eq(A.Social:ArmoryLink(), nil, "hidden: no link")
    -- junk is ignored
    api.server_packet(A, "AR", "public,<b>")
    api.server_packet(A, "AR", "sneaky,abc")
    T.eq(A.Social.armory.mode, "hidden")
end)

T.test("Armory: the settings sheet has the choice; picking Friends only shows the link with the key", function()
    local A = client()
    api.connect(A)
    api.tick(A, 2)
    api.server_packet(A, "AR", "public,")
    A.__slash("/social")
    A.Social.sheet:Toggle()
    T.ok(api.screen_has(A, "Armory"), "a header and the choice")
    T.ok(api.screen_has(A, "Public"))
    T.ok(api.screen_has(A, "Copy my armory link"))
    -- the choice cycles Public -> Friends only
    local choice
    for _, r in ipairs(A.Social.sheet.rows) do if r.button and r.value and r.value:GetText() == "Public" then choice = r end end
    T.ok(choice, "the Armory choice row")
    api.click(choice.button)
    T.eq(sent(A, "armory ")[1], "armory friends")
    T.eq(choice.value:GetText(), "Friends only")
    api.server_packet(A, "AR", "friends,k3y4aldric000000000a")
    T.shown(A.WenillaCore_Prompt, "the link dialog opens")
    local url = A.WenillaCore_PromptEdit:GetText()
    T.eq(url, "https://openvanilla.app/armory/character.html?r=vanilla-reloaded&n=Aldric&k=k3y4aldric000000000a")
    T.has(api.visible(A.WenillaCore_Prompt.text:GetText()), "Friends only")
    -- right-click goes back
    api.click(choice.button, "RightButton")
    T.eq(sent(A, "armory ")[2], "armory public")
end)

T.test("Armory: /armory changes, prints and shows the link; newlink asks for a new key", function()
    local A = client({ name = "Zoë", realm = "Stormwind Nights" })
    A.__slash("/armory hidden")
    T.has(api.chat_text(A), "isn't connected")
    api.connect(A)
    api.tick(A, 2)
    api.server_packet(A, "AR", "public,")
    A.__slash("/armory")
    local chat = api.chat_text(A)
    T.has(chat, "Armory: Public")
    T.has(chat, "?r=stormwind-nights&n=Zo%C3%AB", "the name is URL-encoded")
    A.__slash("/armory friends")
    T.eq(sent(A, "armory ")[1], "armory friends")
    T.has(api.chat_text(A), "within ten minutes")
    api.tick(A, 3)
    A.__slash("/armory newlink")
    api.tick(A, 3)
    T.eq(sent(A, "armory ")[2], "armory newlink")
    api.server_packet(A, "AR", "friends,newkey00000000000000")
    T.has(A.WenillaCore_PromptEdit:GetText(), "&k=newkey00000000000000")
    A.__slash("/armory bogus")
    T.has(api.chat_text(A), "/armory public | friends | hidden | newlink | link")
end)

T.test("Armory: server errors are explained; a reconnect asks again", function()
    local A = client()
    api.connect(A)
    api.tick(A, 2)
    api.server_packet(A, "AR", "err,off")
    T.has(api.chat_text(A), "doesn't offer the armory setting")
    A.__slash("/armory public")
    api.server_packet(A, "AR", "err,rate")
    T.has(api.chat_text(A), "one change every few seconds")
    A.WenillaCore.connected = false
    api.tick(A, 2)
    api.connect(A)
    api.tick(A, 2)
    T.eq(table.getn(sent(A, "armory")), 3, "query, change, and the query again after reconnecting")
end)

T.test("Armory: the realm-folder slug follows docs/ARMORY_GUILDS.md", function()
    local A = client()
    local slug = A.Social.ArmorySlug
    T.eq(slug("Vanilla Reloaded"), "vanilla-reloaded")
    T.eq(slug("<Knights of Ni!>"), "knights-of-ni")
    T.eq(slug("Open Vanilla Classic+"), "open-vanilla-classic")
    T.eq(slug("--A  B--"), "a-b")
end)
