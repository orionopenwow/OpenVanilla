--[[
    ext/mail_loot_talents.lua - more of the 1.12 client for the sim: the mailbox, the loot
    window, talents (with the on-demand Blizzard_TalentUI), equipping gear from the cursor,
    friends and guild roster, the pet action bar and the character frame.

    Test helpers added to api:
        api.open_mailbox(env, letters)    letters = { { sender=, subject=, money=, cod=, item = {id, count},
                                          body=, days=, read=, returned=, player = true (canReply) }, ... }
        api.close_mailbox(env)
        api.open_loot(env, slots, opts)   slots = { {id, count} | { coin = copper }, ... }; opts.auto = true
        api.close_loot(env)
        api.load_talent_ui(env)           the on-demand Blizzard_TalentUI: TalentFrame + ADDON_LOADED
        api.equip(env, slot, id)          put an item in an inventory slot (fires UNIT_INVENTORY_CHANGED)
        api.set_combat(env, on)           PLAYER_REGEN_DISABLED / _ENABLED and UnitAffectingCombat
        api.set_instance(env, kind)       IsInInstance() -> 1, kind ("party", "raid", ...) or nil
    State on env: __mail (inbox), __mail_sent, __mail_returned, __mail_dropped (requests the server
    ignored because the previous one had not been answered yet), __send_item, __talents,
    __loot_open, __equip_moves.
]]--

return function(api, H)
    local M, newObject, NOOP = H.M, H.newObject, H.NOOP
    local ST = api.ST

    -- Gear the equipment-set tests use (equip = GetItemInfo's equipLoc).
    local GEAR = {
        [12640] = { name = "Lionheart Helm", quality = 4, icon = "Interface\\Icons\\INV_Helmet_36", stack = 1, type = "Armor", equip = "INVTYPE_HEAD" },
        [16866] = { name = "Helm of Might", quality = 4, icon = "Interface\\Icons\\INV_Helmet_09", stack = 1, type = "Armor", equip = "INVTYPE_HEAD" },
        [19137] = { name = "Onslaught Girdle", quality = 4, icon = "Interface\\Icons\\INV_Belt_12", stack = 1, type = "Armor", equip = "INVTYPE_WAIST" },
        [17063] = { name = "Band of Accuria", quality = 4, icon = "Interface\\Icons\\INV_Jewelry_Ring_15", stack = 1, type = "Armor", equip = "INVTYPE_FINGER" },
        [18821] = { name = "Quick Strike Ring", quality = 4, icon = "Interface\\Icons\\INV_Jewelry_Ring_16", stack = 1, type = "Armor", equip = "INVTYPE_FINGER" },
        [17112] = { name = "Empyrean Demolisher", quality = 4, icon = "Interface\\Icons\\INV_Hammer_14", stack = 1, type = "Weapon", equip = "INVTYPE_WEAPONMAINHAND" },
        [12651] = { name = "Blackcrow", quality = 3, icon = "Interface\\Icons\\INV_Weapon_Crossbow_04", stack = 1, type = "Weapon", equip = "INVTYPE_RANGED" },
        [19364] = { name = "Ashkandi, Greatsword of the Brotherhood", quality = 4, icon = "Interface\\Icons\\INV_Sword_50", stack = 1, type = "Weapon", equip = "INVTYPE_2HWEAPON" },
        [19349] = { name = "Elementium Reinforced Bulwark", quality = 4, icon = "Interface\\Icons\\INV_Shield_10", stack = 1, type = "Armor", equip = "INVTYPE_SHIELD" },
        [6256] = { name = "Fishing Pole", quality = 1, icon = "Interface\\Icons\\INV_Fishingpole_01", stack = 1, type = "Weapon", equip = "INVTYPE_2HWEAPON" },
        [19972] = { name = "Lucky Fishing Hat", quality = 2, icon = "Interface\\Icons\\INV_Helmet_31", stack = 1, type = "Armor", equip = "INVTYPE_HEAD" },
    }

    -- A small hunter talent tree set: { name, icon, tier, column, max, prereq = {tier, column} }.
    local function tree(name, file, icon, list)
        local t = { name = name, file = file, icon = icon, talents = {} }
        for i, x in ipairs(list) do
            t.talents[i] = { name = x[1], icon = "Interface\\Icons\\" .. x[2], tier = x[3], column = x[4], max = x[5], rank = 0, prereq = x[6] }
        end
        return t
    end
    api.DEFAULT_TALENTS = function()
        return {
            tree("Beast Mastery", "HunterBeastMastery", "Interface\\Icons\\Ability_Hunter_BeastTaming", {
                { "Improved Aspect of the Hawk", "Spell_Nature_RavenForm", 1, 2, 5 },
                { "Endurance Training", "Spell_Nature_Reincarnation", 1, 3, 5 },
                { "Improved Eyes of the Beast", "Ability_EyeOfTheOwl", 2, 1, 2 },
                { "Improved Aspect of the Monkey", "Ability_Hunter_AspectOfTheMonkey", 2, 2, 5 },
                { "Thick Hide", "INV_Misc_Pelt_Bear_03", 2, 3, 3 },
                { "Pathfinding", "Ability_Mount_JungleTiger", 3, 2, 2 },
                { "Unleashed Fury", "Ability_BullRush", 3, 3, 5 },
                { "Intimidation", "Ability_Devour", 5, 2, 1 },
                { "Bestial Discipline", "Spell_Nature_AbolishMagic", 5, 4, 2 },
                { "Frenzy", "INV_Misc_MonsterClaw_04", 6, 3, 5, { 5, 2 } },
                { "Bestial Wrath", "Ability_Druid_FerociousBite", 7, 2, 1, { 5, 2 } },
            }),
            tree("Marksmanship", "HunterMarksmanship", "Interface\\Icons\\Ability_Marksmanship", {
                { "Improved Concussive Shot", "Spell_Frost_Stun", 1, 2, 5 },
                { "Efficiency", "Spell_Frost_WizardMark", 1, 3, 5 },
                { "Improved Hunter's Mark", "Ability_Hunter_SniperShot", 2, 2, 5 },
                { "Lethal Shots", "Ability_SearingArrow", 2, 3, 5 },
                { "Aimed Shot", "INV_Spear_07", 3, 2, 1 },
                { "Improved Arcane Shot", "Ability_ImpalingBolt", 3, 3, 5 },
                { "Mortal Shots", "Ability_PierceDamage", 4, 3, 5 },
                { "Scatter Shot", "Ability_GolemStormBolt", 5, 1, 1 },
                { "Trueshot Aura", "Ability_TrueShot", 7, 2, 1, { 3, 2 } },
            }),
            tree("Survival", "HunterSurvival", "Interface\\Icons\\Ability_Hunter_SwiftStrike", {
                { "Monster Slaying", "INV_Misc_Head_Dragon_Black", 1, 1, 3 },
                { "Humanoid Slaying", "Spell_Holy_PrayerOfHealing", 1, 2, 3 },
                { "Deflection", "Ability_Parry", 1, 3, 5 },
                { "Entrapment", "Spell_Nature_StrangleVines", 2, 1, 5 },
                { "Savage Strikes", "Ability_Racial_BloodRage", 2, 2, 2 },
                { "Surefooted", "Ability_Kick", 3, 3, 3 },
                { "Deterrence", "Ability_Whirlwind", 3, 2, 1 },
                { "Killer Instinct", "Spell_Holy_BlessingOfStamina", 4, 2, 3 },
                { "Lightning Reflexes", "Spell_Nature_Invisibilty", 5, 3, 5 },
                { "Wyvern Sting", "INV_Spear_02", 7, 2, 1, { 4, 2 } },
            }),
        }
    end

    local function later(env, fn) env.__bus:later(fn) end
    local function fire(env, ...) api.fire(env, ...) end

    -- -- Mail -------------------------------------------------------------------------------

    local function freeSlots(env)
        local n = 0
        for bag = 0, 4 do
            local b = env.__bags[bag]
            if b then for s = 1, b.size do if not b.items[s] then n = n + 1 end end end
        end
        return n
    end
    api.free_slots = freeSlots

    -- Put an item in the first bag slot it fits (stacks first). Returns false when full.
    local function store(env, id, count)
        local d = api.item(env, id) or {}
        local stack = d.stack or 1
        local left = count or 1
        if stack > 1 then
            for bag = 0, 4 do
                local b = env.__bags[bag]
                if b then
                    for s = 1, b.size do
                        local it = b.items[s]
                        if it and it.id == id and it.count < stack and left > 0 then
                            local add = math.min(stack - it.count, left)
                            it.count = it.count + add
                            left = left - add
                        end
                    end
                end
            end
        end
        if left <= 0 then fire(env, "BAG_UPDATE", 0) return true end
        for bag = 0, 4 do
            local b = env.__bags[bag]
            if b then
                for s = 1, b.size do
                    if not b.items[s] then
                        b.items[s] = { id = id, count = left }
                        fire(env, "BAG_UPDATE", bag)
                        return true
                    end
                end
            end
        end
        return false
    end
    api.store_item = store

    local function letterGone(env, i)
        table.remove(env.__mail, i)
    end

    -- The server answers one mail request at a time; a request sent before the previous one was
    -- answered is dropped with an error (what the real client does when addons spam it).
    local function mailRequest(env, what, i, fn)
        if env.__mail_busy then
            table.insert(env.__mail_dropped, { what = what, index = i })
            fire(env, "UI_ERROR_MESSAGE", "Internal mail database error.")
            return
        end
        env.__mail_busy = true
        later(env, function()
            env.__mail_busy = nil
            fn()
            fire(env, "MAIL_INBOX_UPDATE")
        end)
    end

    api.client_extensions = api.client_extensions or {}
    table.insert(api.client_extensions, function(env, B, opts)
        for id, d in pairs(GEAR) do if not env.__items[id] then env.__items[id] = d end end
        for _, k in ipairs({ "__mail", "__mail_sent", "__mail_returned", "__mail_dropped", "__equip_moves" }) do rawset(env, k, {}) end
        local F = function(t, n, p) return newObject(env, t, n, p) end
        local function hidden(f) ST[f].shown = false return f end
        B.INBOXITEMS_TO_DISPLAY = 7
        B.BOOKTYPE_SPELL, B.BOOKTYPE_PET = "spell", "pet"

        -- mailbox frames (FrameXML MailFrame.xml, reduced)
        local mf = hidden(F("Frame", "MailFrame", env.UIParent)); ST[mf].w, ST[mf].h, ST[mf].left, ST[mf].top = 384, 512, 20, 700
        local inbox = F("Frame", "InboxFrame", mf)
        rawset(inbox, "pageNum", 1)
        for i = 1, 7 do
            local row = F("Frame", "MailItem" .. i, inbox)
            local b = F("Button", "MailItem" .. i .. "Button", row)
            newObject(env, "Texture", "MailItem" .. i .. "ButtonIcon", b, true)
            newObject(env, "FontString", "MailItem" .. i .. "Sender", row, true)
            newObject(env, "FontString", "MailItem" .. i .. "Subject", row, true)
        end
        F("Button", "InboxPrevPageButton", inbox)
        F("Button", "InboxNextPageButton", inbox)
        local send = hidden(F("Frame", "SendMailFrame", mf))
        for _, n in ipairs({ "SendMailNameEditBox", "SendMailSubjectEditBox", "SendMailBodyEditBox" }) do F("EditBox", n, send) end
        F("Button", "SendMailMailButton", send)
        F("Button", "SendMailPackageButton", send)
        F("Button", "MailFrameTab1", mf)
        F("Button", "MailFrameTab2", mf)
        hidden(F("Frame", "OpenMailFrame", env.UIParent))
        B.InboxFrame_Update = function()
            local page = rawget(inbox, "pageNum") or 1
            for i = 1, 7 do
                local idx = (page - 1) * 7 + i
                local l = env.__mail[idx]
                local row = env["MailItem" .. i]
                if l then
                    M.SetText(env["MailItem" .. i .. "Sender"], l.sender)
                    M.SetText(env["MailItem" .. i .. "Subject"], l.subject)
                    row:Show()
                else
                    row:Hide()
                end
            end
        end
        B.MailFrameTab_OnClick = function(tab)
            tab = tab or (env.this and env.this:GetID()) or 1
            if tab == 2 then inbox:Hide(); send:Show() else send:Hide(); inbox:Show() end
            rawset(mf, "selectedTab", tab)
        end
        B.SendMailFrame_Update = NOOP
        -- the stock Send button (SendMailFrame.lua, reduced: money only, no COD radio)
        B.SendMailFrame_SendMail = function()
            env.SendMail(env.SendMailNameEditBox:GetText() or "", env.SendMailSubjectEditBox:GetText() or "", env.SendMailBodyEditBox:GetText() or "")
        end
        B.SendMailFrame_Reset = function()
            for _, n in ipairs({ "SendMailNameEditBox", "SendMailSubjectEditBox", "SendMailBodyEditBox" }) do M.SetText(env[n], "") end
        end
        M.SetScript(env.SendMailMailButton, "OnClick", function() env.SendMailFrame_SendMail() end)
        -- the stock bag buttons: this = item button, its parent's id = bag, its id = slot
        B.ContainerFrameItemButton_OnClick = function(button)
            local b = env.this
            local bag, slot = b:GetParent():GetID(), b:GetID()
            table.insert(env.__used_items, { bag, slot, "click", button })
            if button == "LeftButton" then env.PickupContainerItem(bag, slot) end
        end

        B.GetInboxNumItems = function() return #env.__mail end
        B.GetInboxHeaderInfo = function(i)
            local l = env.__mail[i]
            if not l then return nil end
            return "Interface\\Icons\\INV_Letter_15", "Interface\\Icons\\INV_Letter_15", l.sender, l.subject,
                l.money or 0, l.cod or 0, l.days or 30, l.item and 1 or nil, l.read and 1 or nil,
                l.returned and 1 or nil, l.body and 1 or nil, l.player ~= false and 1 or nil
        end
        B.GetInboxItem = function(i)
            local l = env.__mail[i]
            local it = l and l.item
            if not it then return nil end
            local id = it.id or it[1]
            local d = api.item(env, id) or {}
            return d.name, d.icon, it.count or it[2] or 1, d.quality or 1, 1
        end
        B.GetInboxText = function(i) local l = env.__mail[i]; if l then l.read = true; return l.body end end
        B.InboxItemCanDelete = function(i) local l = env.__mail[i]; return l and l.player == false and 1 or nil end
        B.TakeInboxMoney = function(i)
            local l = env.__mail[i]
            mailRequest(env, "money", i, function()
                if not l or (l.money or 0) <= 0 then return end
                env.__money = env.__money + l.money
                l.money = 0
                if not l.item and not l.body then letterGone(env, i) end
                fire(env, "PLAYER_MONEY")
            end)
        end
        B.TakeInboxItem = function(i)
            local l = env.__mail[i]
            mailRequest(env, "item", i, function()
                if not l or not l.item then return end
                if (l.cod or 0) > 0 then
                    if env.__money < l.cod then fire(env, "UI_ERROR_MESSAGE", "You don't have enough money.") return end
                end
                local id, count = l.item.id or l.item[1], l.item.count or l.item[2] or 1
                if not store(env, id, count) then fire(env, "UI_ERROR_MESSAGE", "Inventory is full.") return end
                if (l.cod or 0) > 0 then
                    env.__money = env.__money - l.cod
                    l.cod = 0
                    fire(env, "PLAYER_MONEY")
                end
                l.item = nil
                if (l.money or 0) <= 0 and not l.body then letterGone(env, i) end
            end)
        end
        B.ReturnInboxItem = function(i)
            local l = env.__mail[i]
            mailRequest(env, "return", i, function()
                if not l then return end
                table.insert(env.__mail_returned, l)
                for k, x in ipairs(env.__mail) do if x == l then letterGone(env, k) break end end
            end)
        end
        B.DeleteInboxItem = function(i)
            local l = env.__mail[i]
            mailRequest(env, "delete", i, function()
                for k, x in ipairs(env.__mail) do if x == l then letterGone(env, k) break end end
            end)
        end
        B.CheckInbox = function() later(env, function() fire(env, "MAIL_INBOX_UPDATE") end) end
        B.HasNewMail = function() for _, l in ipairs(env.__mail) do if not l.read then return 1 end end end

        -- sending
        env.__send = { money = 0, cod = 0 }
        B.ClickSendMailItemButton = function()
            local c = env.__cursor
            if c and c[1] then
                local it = api.bag_slot(env, c[1], c[2])
                if it then
                    env.__send_item = { bag = c[1], slot = c[2], id = it.id, count = it.count }
                    it.locked = true
                end
                env.__cursor = nil
                fire(env, "MAIL_SEND_INFO_UPDATE")
            elseif env.__send_item then
                local s = env.__send_item
                local it = api.bag_slot(env, s.bag, s.slot)
                if it then it.locked = nil end
                env.__send_item = nil
                env.__cursor = { s.bag, s.slot }
                fire(env, "MAIL_SEND_INFO_UPDATE")
            end
        end
        B.GetSendMailItem = function()
            local s = env.__send_item
            if not s then return nil end
            local d = api.item(env, s.id) or {}
            return d.name, d.icon, s.count, d.quality or 1
        end
        B.GetSendMailItemLink = nil
        B.SetSendMailMoney = function(c) env.__send.money = tonumber(c) or 0; return 1 end
        B.SetSendMailCOD = function(c) env.__send.cod = tonumber(c) or 0 end
        B.GetSendMailMoney = function() return env.__send.money end
        B.GetSendMailCOD = function() return env.__send.cod end
        B.GetSendMailPrice = function() return 30 end
        B.SendMail = function(to, subject, body)
            local item, money, cod = env.__send_item, env.__send.money, env.__send.cod
            if env.__mail_sending then
                table.insert(env.__mail_dropped, { what = "send", to = to })
                fire(env, "UI_ERROR_MESSAGE", "Internal mail database error.")
                return
            end
            env.__mail_sending = true
            later(env, function()
                env.__mail_sending = nil
                if not to or to == "" or to == env.__name or (env.__known_players and not env.__known_players[to]) then
                    fire(env, "MAIL_FAILED")
                    fire(env, "UI_ERROR_MESSAGE", "Cannot find player.")
                    return
                end
                if item then
                    local b = env.__bags[item.bag]
                    if b then b.items[item.slot] = nil end
                    fire(env, "BAG_UPDATE", item.bag)
                end
                env.__money = env.__money - 30 - (money or 0)
                table.insert(env.__mail_sent, { to = to, subject = subject, body = body, money = money, cod = cod, item = item and item.id, count = item and item.count })
                env.__send_item = nil
                env.__send = { money = 0, cod = 0 }
                fire(env, "PLAYER_MONEY")
                fire(env, "MAIL_SEND_SUCCESS")
            end)
        end

        -- friends & guild roster: opts.friends = { {name, level, class, area, connected}, ... },
        -- opts.guild.roster = { {name, rank, level, class, online}, ... }
        B.GetNumFriends = function() return #(opts.friends or {}) end
        B.GetFriendInfo = function(i)
            local f = (opts.friends or {})[i]
            if f then return f.name or f[1], f.level or 60, f.class or "Warrior", f.area or "Ironforge", f.connected and 1 or nil end
        end
        B.ShowFriends = NOOP
        B.GetGuildRosterInfo = function(i)
            local r = opts.guild and opts.guild.roster and opts.guild.roster[i]
            if r then return r.name or r[1], r.rank or "Member", 2, r.level or 60, r.class or "Warrior", "Ironforge", "", "", r.online and 1 or nil end
        end
        local origNum = B.GetNumGuildMembers
        B.GetNumGuildMembers = function()
            if opts.guild and opts.guild.roster then return #opts.guild.roster, #opts.guild.roster end
            return origNum()
        end

        -- -- Loot -----------------------------------------------------------------------------
        local lf = hidden(F("Frame", "LootFrame", env.UIParent))
        M.RegisterEvent(lf, "LOOT_OPENED"); M.RegisterEvent(lf, "LOOT_SLOT_CLEARED"); M.RegisterEvent(lf, "LOOT_CLOSED")
        M.SetScript(lf, "OnEvent", function()
            if env.event == "LOOT_OPENED" then lf:Show()
            elseif env.event == "LOOT_CLOSED" then rawset(lf, "closing", true); lf:Hide(); rawset(lf, "closing", nil) end
        end)
        M.SetScript(lf, "OnHide", function() if not rawget(lf, "closing") then env.CloseLoot() end end)
        B.GetNumLootItems = function() return #env.__loot end
        B.LootSlotIsCoin = function(i) local l = env.__loot[i]; return l and l.coin and not l.taken and 1 or nil end
        B.LootSlotIsItem = function(i) local l = env.__loot[i]; return l and not l.coin and not l.taken and 1 or nil end
        B.GetLootSlotInfo = function(i)
            local l = env.__loot[i]
            if not l or l.taken then return nil end
            if l.coin then
                local c = l.coin
                local g, s = math.floor(c / 10000), math.floor(math.fmod(c, 10000) / 100)
                local parts = {}
                if g > 0 then table.insert(parts, g .. " Gold") end
                if s > 0 then table.insert(parts, s .. " Silver") end
                if math.fmod(c, 100) > 0 then table.insert(parts, math.fmod(c, 100) .. " Copper") end
                return "Interface\\Icons\\INV_Misc_Coin_01", table.concat(parts, "\n"), 0, 0
            end
            local d = api.item(env, l.id or l[1])
            if d then return d.icon, d.name, l.count or l[2] or 1, d.quality end
        end
        -- env.__loot_method = { "master", 0 } makes you the party's master looter
        B.GetLootMethod = function()
            local m = env.__loot_method or { "freeforall" }
            return m[1], m[2], m[3]
        end
        B.GetLootSlotLink = function(i) local l = env.__loot[i]; return l and not l.coin and not l.taken and api.item_link(env, l.id or l[1]) end
        local function lootLeft()
            for _, l in ipairs(env.__loot) do if not l.taken then return true end end
        end
        B.LootSlot = function(i)
            local l = env.__loot[i]
            if not l or l.taken or not env.__loot_open then return end
            local loot = env.__loot
            later(env, function()
                if l.taken or not env.__loot_open or env.__loot ~= loot then return end
                if l.coin then
                    local _, text = B.GetLootSlotInfo(i)
                    env.__money = env.__money + l.coin
                    l.taken = true
                    fire(env, "PLAYER_MONEY")
                    fire(env, "CHAT_MSG_MONEY", "You loot " .. (string.gsub(text or "", "\n", ", ")))
                else
                    local id, count = l.id or l[1], l.count or l[2] or 1
                    if not store(env, id, count) then fire(env, "UI_ERROR_MESSAGE", "Inventory is full.") return end
                    l.taken = true
                    fire(env, "CHAT_MSG_LOOT", "You receive loot: " .. api.item_link(env, id) .. (count > 1 and ("x" .. count) or "") .. ".")
                end
                table.insert(env.__loot_taken, i)
                fire(env, "LOOT_SLOT_CLEARED", i)
                if not lootLeft() then env.__loot_closing = true; fire(env, "LOOT_CLOSED"); env.__loot_open = nil end
            end)
        end
        B.CloseLoot = function()
            if not env.__loot_open or env.__loot_closing then return end
            env.__loot_closing = true
            later(env, function()
                if env.__loot_open then env.__loot_open = nil; fire(env, "LOOT_CLOSED") end
            end)
        end

        -- -- Talents ------------------------------------------------------------------------
        rawset(env, "__talents", { tabs = opts.talents or api.DEFAULT_TALENTS(), points = opts.talentPoints or ((opts.level or 60) - 9) })
        local T = env.__talents
        local function spent(t)
            local n = 0
            for _, x in ipairs(T.tabs[t].talents) do n = n + x.rank end
            return n
        end
        local function prereqOk(t, x)
            if not x.prereq then return true end
            for _, y in ipairs(T.tabs[t].talents) do
                if y.tier == x.prereq[1] and y.column == x.prereq[2] then return y.rank >= y.max end
            end
            return true
        end
        B.GetNumTalentTabs = function() return #T.tabs end
        B.GetTalentTabInfo = function(t) local x = T.tabs[t]; if x then return x.name, x.icon, spent(t), x.file end end
        B.GetNumTalents = function(t) local x = T.tabs[t]; return x and #x.talents or 0 end
        B.GetTalentInfo = function(t, i)
            local x = T.tabs[t] and T.tabs[t].talents[i]
            if x then return x.name, x.icon, x.tier, x.column, x.rank, x.max, nil, prereqOk(t, x) and 1 or nil end
        end
        B.GetTalentPrereqs = function(t, i)
            local x = T.tabs[t] and T.tabs[t].talents[i]
            if x and x.prereq then return x.prereq[1], x.prereq[2], prereqOk(t, x) and 1 or nil end
        end
        B.UnitCharacterPoints = function() return T.points, 0 end
        B.LearnTalent = function(t, i)
            local x = T.tabs[t] and T.tabs[t].talents[i]
            later(env, function()
                if not x or T.points <= 0 or x.rank >= x.max then return end
                if spent(t) < (x.tier - 1) * 5 or not prereqOk(t, x) then return end
                x.rank = x.rank + 1
                T.points = T.points - 1
                table.insert(env.__learned_talents, { t, i })
                fire(env, "CHARACTER_POINTS_CHANGED", -1)
            end)
        end
        rawset(env, "__learned_talents", {})
        rawset(env, "__loot_taken", {})
        B.IsInInstance = function() if env.__instance then return 1, env.__instance end return nil, "none" end
        B.LoadAddOn = function(n)
            if string.lower(n or "") == "blizzard_talentui" then api.load_talent_ui(env) return 1 end
            return nil, "MISSING"
        end
        B.ToggleTalentFrame = function()
            api.load_talent_ui(env)
            local tf = env.TalentFrame
            if tf:IsShown() then tf:Hide() else tf:Show() end
        end

        -- -- Pet action bar -------------------------------------------------------------------
        local pb = F("Frame", "PetActionBarFrame", env.UIParent)
        if not opts.pet then ST[pb].shown = false end
        B.PetHasActionBar = function() return env.__units.pet and 1 or nil end
        B.ShowPetActionBar = function() if B.PetHasActionBar() then pb:Show() end end
        B.HidePetActionBar = function() pb:Hide() end
        if opts.pet then env.__units.pet = api.resolve_unit(env, { name = opts.pet, level = 60, isPlayer = false }) end

        -- -- Character frame & equipping -----------------------------------------------------
        local cf = hidden(F("Frame", "CharacterFrame", env.UIParent))
        F("Frame", "PaperDollFrame", cf)
        B.ToggleCharacter = function() if cf:IsShown() then cf:Hide() else cf:Show() end end
        local bagCursor = B.PickupContainerItem
        local function invChanged() fire(env, "UNIT_INVENTORY_CHANGED", "player") end
        -- cursor: { bag, slot } from a bag, or { inv = slot } from the paper doll
        B.PickupContainerItem = function(bag, slot)
            local c = env.__cursor
            if not c then return bagCursor(bag, slot) end
            local b = env.__bags[bag]
            if not b then return end
            if c.inv then
                local worn = env.__inventory[c.inv]
                local here = b.items[slot]
                env.__inventory[c.inv] = here and here.id or nil
                b.items[slot] = worn and { id = worn, count = 1 } or nil
                table.insert(env.__equip_moves, { "unequip", c.inv, bag, slot })
                env.__cursor = nil
                invChanged()
            else
                local from = env.__bags[c[1]]
                local a, z = from and from.items[c[2]], b.items[slot]
                if from then from.items[c[2]] = z end
                b.items[slot] = a
                env.__cursor = nil
                fire(env, "BAG_UPDATE", c[1])
            end
            fire(env, "BAG_UPDATE", bag)
        end
        B.PickupInventoryItem = function(slot)
            local c = env.__cursor
            if not c then
                if env.__inventory[slot] then env.__cursor = { inv = slot } end
                return
            end
            B.EquipCursorItem(slot)
        end
        B.EquipCursorItem = function(slot)
            local c = env.__cursor
            if not c then return end
            if c.inv then
                local a, b = env.__inventory[c.inv], env.__inventory[slot]
                env.__inventory[slot], env.__inventory[c.inv] = a, b
                table.insert(env.__equip_moves, { "swap", c.inv, slot })
            else
                local bag = env.__bags[c[1]]
                local it = bag and bag.items[c[2]]
                if it then
                    local worn = env.__inventory[slot]
                    env.__inventory[slot] = it.id
                    bag.items[c[2]] = worn and { id = worn, count = 1 } or nil
                    table.insert(env.__equip_moves, { "equip", slot, it.id })
                    -- a two-hander pushes the off hand into the bags
                    local d = api.item(env, it.id) or {}
                    if slot == 16 and d.equip == "INVTYPE_2HWEAPON" and env.__inventory[17] then
                        local off = env.__inventory[17]
                        env.__inventory[17] = nil
                        if not store(env, off, 1) then env.__inventory[17] = off end
                    end
                    fire(env, "BAG_UPDATE", c[1])
                end
            end
            env.__cursor = nil
            invChanged()
        end
        B.AutoEquipCursorItem = NOOP
        local function putIn(bags)
            local c = env.__cursor
            if not c then return end
            for _, bag in ipairs(bags) do
                local b = env.__bags[bag]
                if b then
                    for s = 1, b.size do
                        if not b.items[s] then B.PickupContainerItem(bag, s) return end
                    end
                end
            end
        end
        B.PutItemInBackpack = function() putIn({ 0 }) end
        B.PutItemInBag = function(invId) putIn({ invId - 19 }) end
        B.IsInventoryItemLocked = function() return nil end
        B.GetInventoryItemQuality = function(u, slot) local d = api.item(env, env.__inventory[slot]); return d and d.quality end
        B.ResetCursor = NOOP
        for slot, id in pairs(opts.equipped or {}) do env.__inventory[slot] = id end
    end)

    -- -- Helpers ------------------------------------------------------------------------------

    function api.open_mailbox(env, letters)
        env.__mail = {}
        for _, l in ipairs(letters or {}) do table.insert(env.__mail, api.deepcopy(l)) end
        env.InboxFrame.pageNum = 1
        env.MailFrame:Show()
        env.InboxFrame:Show()
        env.SendMailFrame:Hide()
        api.fire(env, "MAIL_SHOW")
        env.CheckInbox()
        api.pump(env)
    end
    function api.close_mailbox(env)
        env.MailFrame:Hide()
        api.fire(env, "MAIL_CLOSED")
    end

    function api.open_loot(env, slots, opts)
        opts = opts or {}
        env.__loot = {}
        for _, s in ipairs(slots or {}) do
            if s.coin then table.insert(env.__loot, { coin = s.coin })
            else table.insert(env.__loot, { id = s.id or s[1], count = s.count or s[2] or 1 }) end
        end
        env.__loot_open = true
        env.__loot_closing = nil
        env.__loot_taken = {}
        if opts.shift then env.__keys.shift = true end
        api.fire(env, "LOOT_OPENED", opts.auto and 1 or nil)
        if opts.shift then env.__keys.shift = nil end
    end
    function api.close_loot(env)
        env.CloseLoot()
        api.pump(env)
    end

    function api.load_talent_ui(env)
        if env.__addons.Blizzard_TalentUI then return end
        local tf = newObject(env, "Frame", "TalentFrame", env.UIParent)
        ST[tf].shown = false
        ST[tf].w, ST[tf].h, ST[tf].left, ST[tf].top = 384, 512, 0, 700
        newObject(env, "FontString", "TalentFrameTitleText", tf, true)
        newObject(env, "FontString", "TalentFrameSpentPoints", tf, true)
        newObject(env, "Button", "TalentFrameCloseButton", tf)
        for i = 1, 3 do newObject(env, "Button", "TalentFrameTab" .. i, tf) end
        env.__base.TalentFrame_Update = env.__base.TalentFrame_Update or function() end
        env.__addons.Blizzard_TalentUI = { meta = { Title = "Blizzard Talent UI" }, dir = "", files = {} }
        api.fire(env, "ADDON_LOADED", "Blizzard_TalentUI")
    end

    function api.equip(env, slot, id)
        env.__inventory[slot] = id
        api.fire(env, "UNIT_INVENTORY_CHANGED", "player")
    end

    function api.set_combat(env, on)
        env.__units.player.combat = on and true or nil
        api.fire(env, on and "PLAYER_REGEN_DISABLED" or "PLAYER_REGEN_ENABLED")
    end

    function api.set_instance(env, kind) env.__instance = kind end
end
