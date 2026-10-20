-- Mail: Open All / Return All with the 1.12 one-request-per-update throttle, ticked letters,
-- cash on delivery, full bags, Alt-click to attach (several letters), name suggestions and the
-- attachment search.
local T, api = ...

local LETTERS = {
    { sender = "Brakkus", subject = "Spare cloth", money = 0, item = { 2589, 20 } },
    { sender = "Auction House", subject = "Auction successful: Silk Cloth", money = 31200, player = false },
    { sender = "Ilyndra", subject = "Ore for you", money = 1200, item = { 2770, 10 } },
    { sender = "Brakkus", subject = "Read this", body = "Meet me in Goldshire." },
    { sender = "Thrall", subject = "Potions", item = { 858, 5 }, cod = 15000 },
    { sender = "Ilyndra", subject = "Leather", item = { 2318, 10 } },
}

local function mailbox(opts, letters)
    opts = opts or {}
    opts.money = opts.money or 100000
    opts.latency = false
    local env = T.client(opts)
    api.load_with_deps(env, "Bags")            -- Alt-click works in the Bags window too
    api.load_with_deps(env, "Mail")
    api.login(env)
    api.open_mailbox(env, letters or LETTERS)
    return env
end

local function run(env, seconds) api.tick(env, seconds or 3, 0.05) end

T.test("Mail: the panel opens beside the mailbox with an overview and the attachment list", function()
    local env = mailbox()
    T.shown(env.Mail_Panel)
    T.ok(api.screen_has(env, "6 letters", env.Mail_Panel), "overview counts letters")
    T.ok(api.screen_has(env, "3g 24s", env.Mail_Panel), "overview adds up the money")
    T.ok(api.screen_has(env, "Linen Cloth x20", env.Mail_Panel), "attachment row")
    T.ok(api.screen_has(env, "from Thrall", env.Mail_Panel))
    T.ok(api.screen_has(env, "COD", env.Mail_Panel), "COD letters are marked")
    T.shown(env.Mail_Check1, "tick boxes on the inbox rows")
    api.close_mailbox(env)
    T.hidden(env.Mail_Panel)
end)

T.test("Mail: Open All takes everything one request at a time, skips COD and text, and sums up", function()
    local env = mailbox()
    local money0 = env.__money
    api.click_text(env, "Open All", env.Mail_Panel)
    T.ok(api.screen_has(env, "Stop", env.Mail_Panel), "the button stops a run")
    run(env, 4)
    T.eq(#env.__mail_dropped, 0, "never a second request before the server answered")
    T.eq(env.__money - money0, 32400, "auction money and the letter's money")
    T.eq(#env.__mail, 2, "the text letter and the COD letter stay")
    T.eq(env.__mail[1].subject, "Read this")
    T.eq(env.__mail[2].subject, "Potions")
    local chat = api.chat_text(env)
    T.has(chat, "Mail: Collected 3g 24s and 3 items.")
    T.has(chat, "Skipped 1 cash-on-delivery letter (1g 50s)")
    T.ok(api.screen_has(env, "Collected 3g 24s and 3 items", env.Mail_Panel), "summary on the panel too")
    T.ok(api.screen_has(env, "Open All", env.Mail_Panel), "button back to Open All")
    local found = 0
    for _, it in pairs(env.__bags[0].items) do if it.id == 2589 or it.id == 2770 or it.id == 2318 then found = found + 1 end end
    T.eq(found, 3, "items in the bags")
end)

T.test("Mail: Shift-click Open All pays for COD after confirming", function()
    local env = mailbox()
    local money0 = env.__money
    env.__keys.shift = true
    api.click_text(env, "Open All", env.Mail_Panel)
    env.__keys.shift = nil
    T.eq(env.__popups[1].which, "CLASSICPLUS_MAIL_COD")
    T.has(api.visible(env.__popups[1].text), "Pay 1g 50s to open 1 letter")
    api.popup_click(env, "CLASSICPLUS_MAIL_COD", 1)
    run(env, 4)
    T.eq(#env.__mail, 1, "only the text letter is left")
    T.eq(env.__money - money0, 32400 - 15000)
    T.has(api.chat_text(env), "Collected 3g 24s and 4 items (paid 1g 50s cash on delivery).")
end)

T.test("Mail: a full bag pauses Open All until there is room", function()
    local items = {}
    for i = 1, 15 do items[i] = { 6948, 1 } end
    local env = mailbox({ bags = { [0] = { size = 16, items = items } } })
    api.click_text(env, "Open All", env.Mail_Panel)
    run(env, 3)
    T.ok(api.screen_has(env, "Your bags are full", env.Mail_Panel), "paused")
    T.ok(env.ClassicPlusMail.job and env.ClassicPlusMail.job.paused, "the run waits")
    T.eq(#env.__mail_dropped, 0)
    -- make room: the run carries on by itself
    env.__bags[0].items[1] = nil
    env.__bags[0].items[2] = nil
    env.__bags[0].items[3] = nil
    api.fire(env, "BAG_UPDATE", 0)
    run(env, 4)
    T.eq(env.ClassicPlusMail.job, nil, "finished")
    T.has(api.chat_text(env), "Collected 3g 24s and 3 items")
end)

T.test("Mail: ticked letters open or return on their own", function()
    local env = mailbox()
    api.click(env.Mail_Check3)                 -- Ilyndra: ore + 12s
    api.click(env.Mail_Check6)                 -- Ilyndra: leather
    T.ok(api.screen_has(env, "2 ticked", env.Mail_Panel))
    api.click_text(env, "Open Ticked", env.Mail_Panel)
    run(env, 3)
    T.eq(#env.__mail, 4)
    T.has(api.chat_text(env), "Collected 12s and 2 items.")
    -- return Brakkus's cloth letter (now first)
    api.click(env.Mail_Check1)
    api.click_text(env, "Return Ticked", env.Mail_Panel)
    api.popup_click(env, "CLASSICPLUS_MAIL_RETURN", 1)
    run(env, 2)
    T.eq(#env.__mail_returned, 1)
    T.eq(env.__mail_returned[1].subject, "Spare cloth")
    T.has(api.chat_text(env), "Returned 1 letter.")
end)

T.test("Mail: Return All sends players' letters back, never the auction house's", function()
    local env = mailbox()
    api.click_text(env, "Return All", env.Mail_Panel)
    T.has(api.visible(env.__popups[1].text), "Send 5 letters back")
    api.popup_click(env, "CLASSICPLUS_MAIL_RETURN", 1)
    run(env, 4)
    T.eq(#env.__mail_returned, 5)
    T.eq(#env.__mail, 1)
    T.eq(env.__mail[1].sender, "Auction House")
    T.eq(#env.__mail_dropped, 0)
end)

T.test("Mail: clicking an attachment takes just that letter; search filters the list", function()
    local env = mailbox()
    api.type(env.Mail_Search, "leath")
    T.ok(api.screen_has(env, "Light Leather", env.Mail_Panel))
    T.no(api.screen_has(env, "Linen Cloth", env.Mail_Panel), "filtered out")
    api.click_text(env, "Light Leather", env.Mail_Panel)
    run(env, 2)
    T.eq(#env.__mail, 5)
    T.has(api.chat_text(env), "Collected 1 item.")
    api.type(env.Mail_Search, "zzz")
    T.ok(api.screen_has(env, "Nothing in your inbox matches", env.Mail_Panel))
end)

T.test("Mail: closing the mailbox stops a run with a partial summary", function()
    local env = mailbox()
    api.click_text(env, "Open All", env.Mail_Panel)
    api.tick(env, 0.2, 0.05)
    api.close_mailbox(env)
    T.eq(env.ClassicPlusMail.job, nil)
    T.has(api.chat_text(env), "Mailbox closed.")
end)

T.test("Mail: Alt-click attaches from the bags; several items go as several letters", function()
    local env = mailbox({ bags = { [0] = { size = 16, items = { { 2589, 20 }, { 4306, 5 }, { 2770, 8 } } } } }, {})
    env.__slash("/bags")
    env.__keys.alt = true
    api.click(env.Vault_Slot1)
    T.shown(env.SendMailFrame, "switches to the send tab")
    T.eq(env.GetSendMailItem(), "Linen Cloth", "first item in the stock slot")
    T.eq(env.SendMailSubjectEditBox:GetText(), "Linen Cloth x20", "subject filled in")
    api.click(env.Vault_Slot2)
    api.click(env.Vault_Slot3)
    api.click(env.Vault_Slot3)                 -- twice: still once
    env.__keys.alt = nil
    T.shown(env.Mail_Outbox)
    T.ok(api.screen_has(env, "3 letters to send", env.Mail_Outbox))
    api.type(env.SendMailNameEditBox, "Brakkus")
    env.SendMailSubjectEditBox:SetText("Mats")
    api.click(env.SendMailMailButton)
    run(env, 2)
    T.eq(#env.__mail_sent, 3)
    T.eq(env.__mail_sent[1].subject, "Mats (1/3)")
    T.eq(env.__mail_sent[3].subject, "Mats (3/3)")
    T.eq(env.__mail_sent[2].item, 4306)
    T.eq(env.__mail_sent[3].to, "Brakkus")
    T.eq(#env.__mail_dropped, 0, "one letter at a time")
    T.has(api.chat_text(env), "Sent 3 letters to Brakkus.")
    T.eq(env.__bags[0].items[1], nil, "the items left the bags")
    T.eq(env.__bags[0].items[3], nil)
end)

T.test("Mail: a single Alt-click uses the stock Send; the recipient is remembered", function()
    local env = mailbox({ bags = { [0] = { size = 16, items = { { 2589, 20 } } } } }, {})
    env.__slash("/bags")
    env.__keys.alt = true
    api.click(env.Vault_Slot1)
    env.__keys.alt = nil
    T.hidden(env.Mail_Outbox, "one item needs no queue")
    api.type(env.SendMailNameEditBox, "Ilyndra")
    api.click(env.SendMailMailButton)
    run(env, 1)
    T.eq(#env.__mail_sent, 1)
    T.eq(env.__mail_sent[1].subject, "Linen Cloth x20")
    T.eq(env.ClassicPlusMail_DB.recent["Open Vanilla"][1], "Ilyndra")
end)

T.test("Mail: name suggestions from alts, recent, friends and guild", function()
    local saved = { ClassicPlusMail_DB = { alts = { ["Open Vanilla"] = { Heraldine = { class = "MAGE" }, Hexwood = { class = "WARLOCK" } } },
        recent = { ["Open Vanilla"] = { "Hemlock" } } } }
    local env = mailbox({ saved = saved, friends = { { name = "Hector", class = "Rogue" } },
        guild = { name = "Ashen Vanguard", roster = { { name = "Helga", class = "Priest" }, { name = "Brakkus" } } } }, {})
    env.MailFrameTab_OnClick(2)
    api.type(env.SendMailNameEditBox, "he")
    T.shown(env.Mail_Suggest)
    local texts = table.concat(api.visible_texts(env, env.Mail_Suggest), " | ")
    T.has(texts, "Heraldine | your character")
    T.has(texts, "Hemlock | mailed before")
    T.has(texts, "Hector | friend")
    T.has(texts, "Helga | guild")
    T.lacks(texts, "Herald |", "not yourself")
    T.ok(string.find(texts, "Heraldine", 1, true) < string.find(texts, "Hector", 1, true), "your characters first")
    api.click_text(env, "Hexwood", env.Mail_Suggest)
    T.eq(env.SendMailNameEditBox:GetText(), "Hexwood")
    T.hidden(env.Mail_Suggest)
    api.type(env.SendMailNameEditBox, "hel")
    api.run_script(env.SendMailNameEditBox, "OnTabPressed")
    T.eq(env.SendMailNameEditBox:GetText(), "Helga", "Tab takes the first suggestion")
    -- this character is remembered for the others
    T.ok(env.ClassicPlusMail_DB.alts["Open Vanilla"].Herald, "logging in remembers the character")
end)

T.test("Mail: settings turn the panel, ticks, Alt-click and suggestions off", function()
    local env = mailbox({ bags = { [0] = { size = 16, items = { { 2589, 20 } } } } })
    local mgr = env.ClassicPlus_Manager
    mgr:SetSetting("Mail", "openAll", false)
    T.hidden(env.Mail_Panel)
    mgr:SetSetting("Mail", "checkboxes", false)
    T.hidden(env.Mail_Check1)
    mgr:SetSetting("Mail", "altClick", false)
    env.__slash("/bags")
    env.__keys.alt = true
    api.click(env.Vault_Slot1)
    env.__keys.alt = nil
    T.eq(env.GetSendMailItem(), nil, "Alt-click does nothing")
    mgr:SetSetting("Mail", "autocomplete", false)
    env.MailFrameTab_OnClick(2)
    api.type(env.SendMailNameEditBox, "Br")
    T.hidden(env.Mail_Suggest)
    env.WenillaCore:SetAddonEnabled("Mail", false)
    T.hidden(env.Mail_Panel)
end)

T.test("Mail: /mail open and the Pure Vanilla switch", function()
    local env = mailbox()
    env.__slash("/mail open")
    run(env, 4)
    T.has(api.chat_text(env), "Collected 3g 24s and 3 items.")
    api.close_mailbox(env)
    env.__slash("/mail")
    T.has(api.chat_text(env), "Open a mailbox first")
    env.__slash("/vanilla")
    api.open_mailbox(env, LETTERS)
    T.hidden(env.Mail_Panel, "nothing in Pure Vanilla")
end)

T.test("Mail: Alt-click works in the stock bags too, and Mail runs without Bags", function()
    local env = T.addon("Mail", { latency = false, bags = { [0] = { size = 16, items = { { 2589, 20 } } } } })
    api.open_mailbox(env, {})
    local bagFrame = env.CreateFrame("Frame", "ContainerFrame1", env.UIParent)
    bagFrame:SetID(0)
    local item = env.CreateFrame("Button", "ContainerFrame1Item1", bagFrame)
    item:SetID(1)
    env.__keys.alt = true
    env.this = item
    env.ContainerFrameItemButton_OnClick("LeftButton")
    env.this = nil
    env.__keys.alt = nil
    T.eq(env.GetSendMailItem(), "Linen Cloth", "attached from the stock bag button")
    T.eq(#env.__used_items, 0, "the stock click didn't run")
    -- without Alt the stock click goes through
    env.this = item
    env.ContainerFrameItemButton_OnClick("LeftButton")
    env.this = nil
    T.eq(#env.__used_items, 1)
end)
