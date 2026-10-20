--[[
    ext/units_actions.lua - more of the 1.12 client for the sim: right-click unit menus
    (UIDropDownMenu + UnitPopup + the chat-name FRIEND menu), nameplate toggles and targeting by
    name, action buttons (cooldowns, range, mana, reagents, ammo), bag cooldowns, key bindings,
    casting (mounted / sitting errors), player buffs, the target frame's aura buttons and the
    tooltip methods that read them.

    Test helpers added to api:
        api.menu(env, level)            the open dropdown: { name = frame name, items = { {text, value, isTitle,
                                        hasArrow}, ... } } or nil when no menu is shown
        api.menu_texts(env, level)      the visible entries' texts (title rows included)
        api.menu_click(env, text)       click an entry of the open menu (runs its func with 'this')
        api.right_click_name(env, name) right-click a |Hplayer:Name|h chat link (SetItemRef)
        api.add_nearby(env, def)        a unit near the player that TargetByName / TargetNearestEnemy can
                                        pick (api.add_nameplate adds one for every plate it makes)
        api.set_action(env, slot, def)  def = { name, texture, spell = true, cooldown = { start, duration },
                                        range = 1|0|nil, usable = false, noMana = true, count = n,
                                        reagent = "Soul Shard", macro = "text" }
        api.set_bag_cooldown(env, bag, slot, start, duration)
        api.set_buffs(env, list)        the player's buffs: { { texture, name, desc, mount = true }, ... }
        api.set_mounted(env, on) / api.set_sitting(env, on)
        api.press_key(env, key)         OnKeyDown on every visible keyboard-enabled frame
    State on env: __dd (dropdown lists), __plates ({ enemy, friend }), __nearby, __actions, __casts,
    __used_actions, __bindings, __bindings_saved, __player_buffs, __emotes, __spell_targets.
]]--

return function(api, H)
    local M, newObject, NOOP = H.M, H.newObject, H.NOOP
    local ST = api.ST

    -- real 1.12 CVars the defaults touch (Interface Options > Basic: "Show Player Guild Names" ...)
    api.CVARS.UnitNamePlayerGuild = api.CVARS.UnitNamePlayerGuild or "1"
    api.CVARS.UnitNamePlayerPVPTitle = api.CVARS.UnitNamePlayerPVPTitle or "1"

    local function fire(env, ev, ...) api.fire(env, ev, ...) end

    -- -- Widget methods the 1.12 client has and these models need ----------------------------
    function M:EnableKeyboard(on) ST[self].keyboard = on and true or nil end
    function M:IsKeyboardEnabled() return ST[self].keyboard and 1 or nil end
    local function tipAdd(tip, lines)
        M.ClearLines(tip)
        for _, l in ipairs(lines) do M.AddLine(tip, l, 1, 1, 1) end
        if lines[1] then M.Show(tip) end
    end
    function M:SetAction(slot)
        local a = ST[self].env.__actions[slot]
        local lines = {}
        if a then
            table.insert(lines, a.name or "")
            if a.reagent then table.insert(lines, "Reagents: " .. a.reagent) end
        end
        tipAdd(self, lines)
    end
    local function auraTip(tip, unit, i, kind)
        local env = ST[tip].env
        local u = api.unit(env, unit)
        local d = u and u[kind][i]
        tipAdd(tip, { d and d.name or nil })
    end
    function M:SetUnitDebuff(unit, i) auraTip(self, unit, i, "debuffs") end
    function M:SetUnitBuff(unit, i) auraTip(self, unit, i, "buffs") end
    function M:SetPlayerBuff(idx)
        local b = ST[self].env.__player_buffs[(idx or -1) + 1]
        tipAdd(self, b and { b.name, b.desc } or {})
    end

    -- Hovering records the mouse focus (GetMouseFocus).
    local enter = api.enter
    function api.enter(o)
        local s = ST[o]
        if s then s.env.__mouse_focus = o end
        return enter(o)
    end
    local leave = api.leave
    function api.leave(o)
        local s = ST[o]
        if s and s.env.__mouse_focus == o then s.env.__mouse_focus = nil end
        return leave(o)
    end

    -- Every nameplate is a unit near the player.
    local addPlate = api.add_nameplate
    function api.add_nameplate(env, def)
        def = def or {}
        local p = addPlate(env, def)
        -- the engine paints the bar by reaction (def.reaction = "hostile" (default) | "neutral" |
        -- "friendly" | "player")
        local REACTION = { hostile = { 1, 0, 0 }, neutral = { 1, 1, 0 }, friendly = { 0, 1, 0 }, player = { 0, 0, 1 } }
        local c = REACTION[def.reaction or (def.hostile == false and "friendly" or "hostile")]
        M.SetStatusBarColor((p:GetChildren()), c[1], c[2], c[3])
        api.add_nearby(env, {
            name = def.name or "Defias Thug", level = tonumber(def.level) or 10, isPlayer = def.isPlayer or false,
            hostile = def.hostile ~= false and (def.reaction or "hostile") == "hostile", health = def.health or def.healthMax or 100, healthMax = def.healthMax or 100,
            classification = def.boss and "worldboss" or nil, plate = p,
        })
        return p
    end
    function api.add_nearby(env, def) table.insert(env.__nearby, def) return def end

    -- -- Early: functions (the base defines its stand-ins before the extensions run) --------
    table.insert(api.client_extensions, function(env, B, opts)
        rawset(env, "__dd", { lists = { {}, {} }, shown = {} })
        rawset(env, "__plates", { enemy = false, friend = false })
        for _, k in ipairs({ "__nearby", "__casts", "__used_actions", "__player_buffs", "__emotes", "__spell_targets" }) do
            rawset(env, k, {})
        end
        rawset(env, "__actions", {})
        rawset(env, "__bindings", {})
        rawset(env, "__bag_cooldowns", {})
        local function G(k, v) rawset(env, k, v) end

        -- UIDropDownMenu.lua, reduced: the lists are tables, DropDownListN frames show/hide.
        B.UIDROPDOWNMENU_MENU_LEVEL = 1
        B.UIDropDownMenu_Initialize = function(frame, init, displayMode, level)
            level = level or 1
            G("UIDROPDOWNMENU_INIT_MENU", frame:GetName())
            G("UIDROPDOWNMENU_MENU_LEVEL", level)
            env.__dd.lists[level] = {}
            if displayMode then rawset(frame, "displayMode", displayMode) end
            if init then
                rawset(frame, "initialize", init)
                init(level)
            end
        end
        B.UIDropDownMenu_AddButton = function(info, level)
            level = level or 1
            local list = env.__dd.lists[level]
            if not list then list = {} env.__dd.lists[level] = list end
            local b = {}
            for k, v in pairs(info) do b[k] = v end
            table.insert(list, b)
        end
        local function setShown(level, on)
            env.__dd.shown[level] = on or nil
            local f = env["DropDownList" .. level]
            if f then if on then f:Show() else f:Hide() end end
        end
        B.HideDropDownMenu = function(level)
            for l = level or 1, 2 do setShown(l, false) end
        end
        B.CloseDropDownMenus = function(level) B.HideDropDownMenu(level or 1) end
        B.ToggleDropDownMenu = function(level, value, frame, anchor)
            level = level or 1
            frame = frame or (env.this and env.this:GetParent())
            if env.__dd.shown[level] and env.UIDROPDOWNMENU_OPEN_MENU == frame:GetName() then
                B.HideDropDownMenu(level)
                return
            end
            B.HideDropDownMenu(level)
            G("UIDROPDOWNMENU_OPEN_MENU", frame:GetName())
            G("UIDROPDOWNMENU_MENU_VALUE", value)
            env.__dd.anchor = anchor
            env.UIDropDownMenu_Initialize(frame, rawget(frame, "initialize"), nil, level)
            setShown(level, true)
        end

        -- UnitPopup.lua, reduced: UnitPopup_HideButtons' main rules.
        local function inGroup() return env.GetNumPartyMembers() > 0 or env.GetNumRaidMembers() > 0 end
        local function partyName(n)
            if not n then return false end
            for i = 1, 4 do
                local u = env.__units["party" .. i]
                if u and u.name == n then return true end
            end
            for i = 1, 40 do
                local u = env.__units["raid" .. i]
                if u and u.name == n then return true end
            end
            return false
        end
        local function hidden(value, dd)
            local unit, name = dd.unit, dd.name
            local me = env.__units.player.name
            local isSelf = (unit and env.UnitIsUnit(unit, "player")) or (name == me)
            local isPlayer = unit and env.UnitIsPlayer(unit)
            if value == "WHISPER" then return isSelf or (unit and not isPlayer) end
            if value == "INSPECT" or value == "TRADE" or value == "FOLLOW" or value == "DUEL" then
                return not unit or isSelf or not isPlayer
            end
            if value == "INVITE" then
                if isSelf or (unit and not isPlayer) or partyName(name) then return true end
                return inGroup() and not env.IsPartyLeader()
            end
            if value == "TARGET" then return not name or isSelf end
            if value == "UNINVITE" or value == "PROMOTE" or value == "LOOT_PROMOTE" then
                return not (inGroup() and env.IsPartyLeader() and partyName(name)) or isSelf
            end
            if value == "LEAVE" or value == "LOOT_METHOD" or value == "LOOT_THRESHOLD" then return not inGroup() end
            if value == "RESET_INSTANCES" then return inGroup() and not env.IsPartyLeader() end
            if string.find(value, "^PET_") then return not env.UnitExists("pet") end
            if string.find(value, "^RAID_") and value ~= "RAID_TARGET_ICON" then return env.GetNumRaidMembers() == 0 end
            if value == "GUILD_PROMOTE" or value == "GUILD_LEAVE" then return true end
            return false
        end
        B.UnitPopup_ShowMenu = function(dd, which, unit, name, userData)
            rawset(dd, "which", which)
            rawset(dd, "unit", unit)
            if unit and not name then name = env.UnitName(unit) end
            rawset(dd, "name", name)
            rawset(dd, "userData", userData)
            local level = env.UIDROPDOWNMENU_MENU_LEVEL or 1
            local buttons, menus = env.UnitPopupButtons, env.UnitPopupMenus
            if level == 2 then
                for _, v in ipairs(menus[env.UIDROPDOWNMENU_MENU_VALUE or ""] or {}) do
                    local b = buttons[v] or { text = v }
                    env.UIDropDownMenu_AddButton({ text = b.text, value = v, owner = which, func = env.UnitPopup_OnClick }, 2)
                end
                return
            end
            local list = menus[which]
            if not list then return end
            if name then env.UIDropDownMenu_AddButton({ text = name, isTitle = 1, notCheckable = 1 }) end
            for _, v in ipairs(list) do
                if not hidden(v, dd) then
                    local b = buttons[v] or { text = v }
                    env.UIDropDownMenu_AddButton({ text = b.text, value = v, owner = which, func = env.UnitPopup_OnClick,
                        hasArrow = b.nested, notCheckable = 1 })
                end
            end
            env.PlaySound("igMainMenuOpen")
        end
        B.UnitPopup_OnClick = function()
            local v = env.this and env.this.value
            env.__unitpopup_clicked = v
            local dd = env[env.UIDROPDOWNMENU_INIT_MENU or ""]
            local name = dd and dd.name
            if v == "INVITE" and env.InviteByName then env.InviteByName(name)
            elseif v == "TARGET" and name then env.TargetByName(name, 1)
            elseif v == "WHISPER" then table.insert(env.__opened_chat, "/w " .. tostring(name) .. " ") end
        end

        -- FriendsFrame.lua's chat-name menu, and ItemRef.lua's player links.
        B.FriendsFrameDropDown_Initialize = function()
            env.UnitPopup_ShowMenu(env[env.UIDROPDOWNMENU_OPEN_MENU or ""], "FRIEND", nil, env.FriendsDropDown.name)
        end
        B.FriendsFrame_ShowDropdown = function(name, connected)
            env.HideDropDownMenu(1)
            if connected then
                local d = env.FriendsDropDown
                rawset(d, "initialize", env.FriendsFrameDropDown_Initialize)
                rawset(d, "displayMode", "MENU")
                rawset(d, "name", name)
                env.ToggleDropDownMenu(1, nil, d, "cursor")
            end
        end
        B.SetItemRef = function(link, text, button)
            if string.sub(link or "", 1, 6) == "player" then
                local name = string.sub(link, 8)
                if name ~= "" then
                    if button == "RightButton" then env.FriendsFrame_ShowDropdown(name, 1)
                    else table.insert(env.__opened_chat, "/w " .. name .. " ") end
                end
                return
            end
            local tip = env.ItemRefTooltip
            tip:SetOwner(env.UIParent, "ANCHOR_PRESERVE")
            tip:SetHyperlink(link)
            tip:Show()
        end

        -- Nameplates: shown by the V / Shift-V bindings (Bindings.xml sets NAMEPLATES_ON).
        B.ShowNameplates = function() env.__plates.enemy = true end
        B.HideNameplates = function() env.__plates.enemy = false end
        B.ShowFriendNameplates = function() env.__plates.friend = true end
        B.HideFriendNameplates = function() env.__plates.friend = false end

        -- Targeting: tokens, names (nearest first) and Tab.
        local function setTargetDef(def)
            env.__prev_target = env.__units.target
            env.__units.target = def
            if def then env.TargetFrame:Show() else env.TargetFrame:Hide() end
            fire(env, "PLAYER_TARGET_CHANGED")
        end
        B.TargetUnit = function(u)
            local def = type(u) == "string" and env.__units[string.lower(u)]
            if def then setTargetDef(def) else env.__prev_target = env.__units.target; api.set_target(env, u) end
        end
        B.ClearTarget = function() if env.__units.target then setTargetDef(nil) end end
        B.TargetLastTarget = function() setTargetDef(env.__prev_target) end
        B.TargetByName = function(name, exact)
            local low = string.lower(name or "")
            for _, d in ipairs(env.__nearby) do
                local n = string.lower(d.name or "")
                if n == low or (not exact and string.sub(n, 1, string.len(low)) == low) then
                    table.insert(env.__casts, { targetByName = name })
                    return setTargetDef(api.resolve_unit(env, d))
                end
            end
            local o = env.__bus.by_name[name or ""]
            if o then setTargetDef(api.resolve_unit(env, name)) end
        end
        B.TargetNearestEnemy = function()
            local list = {}
            for _, d in ipairs(env.__nearby) do if d.hostile then table.insert(list, d) end end
            if not list[1] then return end
            env.__tab = math.fmod(env.__tab or 0, #list) + 1
            setTargetDef(api.resolve_unit(env, list[env.__tab]))
        end

        -- Action buttons.
        local function act(id) return env.__actions[id] end
        B.HasAction = function(id) return act(id) and 1 or nil end
        B.GetActionTexture = function(id) local a = act(id); return a and a.texture end
        B.GetActionText = function(id) local a = act(id); return a and a.macro end
        B.GetActionCount = function(id) local a = act(id); return a and a.count or 0 end
        B.GetActionCooldown = function(id)
            local a = act(id)
            if a and a.cooldown then return a.cooldown[1], a.cooldown[2], 1 end
            return 0, 0, 1
        end
        B.IsActionInRange = function(id) local a = act(id); return a and a.range end
        B.IsUsableAction = function(id)
            local a = act(id)
            if not a then return nil end
            if a.noMana then return nil, 1 end
            if a.usable == false then return nil, nil end
            return 1, nil
        end
        B.IsConsumableAction = function(id) local a = act(id); return a and a.consumable and 1 or nil end
        B.IsCurrentAction, B.IsAutoRepeatAction, B.IsAttackAction = NOOP, NOOP, NOOP
        B.ActionButton_GetPagedID = function(button) return rawget(button, "actionSlot") or button:GetID() end
        B.GetContainerItemCooldown = function(bag, slot)
            local c = env.__bag_cooldowns[bag .. ":" .. slot]
            if c then return c[1], c[2], 1 end
            return 0, 0, 1
        end
        B.GetInventoryItemCount = function(unit, slot)
            local c = env.__inv_counts and env.__inv_counts[slot]
            if c then return c end
            return env.__inventory[slot] and 1 or 0
        end

        -- Casting: the server answers a cast made while mounted or sitting with an error.
        local function castError(msg)
            env.__bus:later(function() fire(env, "UI_ERROR_MESSAGE", msg) end)
        end
        B.SPELL_FAILED_NOT_MOUNTED = "You are mounted"
        B.SPELL_FAILED_NOT_STANDING = "You must be standing to do that"
        B.ERR_ATTACK_MOUNTED = "Can't attack while mounted."
        B.CastSpellByName = function(spell, onSelf)
            if env.__mounted then return castError(env.SPELL_FAILED_NOT_MOUNTED) end
            if env.__sitting then return castError(env.SPELL_FAILED_NOT_STANDING) end
            local t = env.__units.target
            table.insert(env.__casts, { spell = spell, onSelf = onSelf and true or nil, target = t and t.name })
        end
        B.UseAction = function(id, cursor, onSelf)
            local a = act(id)
            table.insert(env.__used_actions, id)
            if a and a.name then env.CastSpellByName(a.name, onSelf) end
        end
        B.SpellIsTargeting = function() return env.__spell_targeting and 1 or nil end
        B.SpellTargetUnit = function(u) table.insert(env.__spell_targets, u); env.__spell_targeting = nil end
        B.SpellStopTargeting = function() env.__spell_targeting = nil end

        -- Player buffs (mounts are buffs in 1.12), standing up.
        B.GetPlayerBuff = function(i, filter)
            local b = env.__player_buffs[(i or 0) + 1]
            if b and (filter == nil or filter == "HELPFUL") then return i, 1 end
            return -1, nil
        end
        B.GetPlayerBuffTexture = function(idx) local b = env.__player_buffs[(idx or -1) + 1]; return b and b.texture end
        B.CancelPlayerBuff = function(idx)
            local b = table.remove(env.__player_buffs, (idx or -1) + 1)
            if b and b.mount then env.__mounted = nil end
            fire(env, "PLAYER_AURAS_CHANGED")
        end
        B.DoEmote = function(e)
            table.insert(env.__emotes, e)
            if string.upper(e or "") == "STAND" then env.__sitting = nil end
            if string.upper(e or "") == "SIT" then env.__sitting = true end
        end
        B.SitOrStand = function() env.__sitting = not env.__sitting or nil end

        -- Key bindings.
        B.SetBinding = function(key, action)
            if not key then return nil end
            if action == nil or action == "" then env.__bindings[key] = nil else env.__bindings[key] = action end
            return 1
        end
        B.GetBindingAction = function(key) return env.__bindings[key] or "" end
        B.GetBindingKey = function(action)
            local keys = {}
            for k, a in pairs(env.__bindings) do if a == action then table.insert(keys, k) end end
            table.sort(keys)
            return unpack(keys)
        end
        B.GetCurrentBindingSet = function() return 2 end
        B.SaveBindings = function(set) env.__bindings_saved = set end
        B.GetBindingText = function(key) return key end
        B.GetMouseFocus = function() return env.__mouse_focus end

        -- The merchant's buyback list: what you sold, priced for the whole stack.
        rawset(env, "__buyback", {})
        local use = B.UseContainerItem
        B.UseContainerItem = function(bag, slot, a3)
            local it = api.bag_slot(env, bag, slot)
            if it and env.__merchant then
                local d = api.item(env, it.id) or {}
                if (d.sell or 0) > 0 then
                    table.insert(env.__buyback, 1, { id = it.id, count = it.count or 1, price = d.sell * (it.count or 1) })
                    while #env.__buyback > 12 do table.remove(env.__buyback) end
                    env.__bus:later(function() fire(env, "MERCHANT_UPDATE") end)
                end
            end
            return use(bag, slot, a3)
        end
        B.GetNumBuybackItems = function() return #env.__buyback end
        B.GetBuybackItemInfo = function(i)
            local b = env.__buyback[i]
            local d = b and api.item(env, b.id)
            if d then return d.name, d.icon, b.price, b.count end
        end
        B.GetBuybackItemLink = function(i) local b = env.__buyback[i]; return b and api.item_link(env, b.id) end

        -- The quest giver's turn-in pages (QuestFrame): env.__quest = { completable, choices }.
        rawset(env, "__quest_done", {})
        B.IsQuestCompletable = function() return env.__quest and env.__quest.completable and 1 or nil end
        B.CompleteQuest = function() table.insert(env.__quest_done, "complete") end
        B.GetNumQuestChoices = function() return env.__quest and env.__quest.choices or 0 end
        B.GetQuestReward = function(choice) table.insert(env.__quest_done, "reward " .. tostring(choice)) end
    end)

    -- -- Late: frames and tables (after the stock UI exists) ---------------------------------
    api.client_late_extensions = api.client_late_extensions or {}
    table.insert(api.client_late_extensions, function(env, B, opts)
        local function F(t, n, p) return newObject(env, t, n, p) end
        local function hide(f) ST[f].shown = false return f end
        local function region(t, n, p) return newObject(env, t, n, p, true) end

        -- the dropdown lists
        for l = 1, 2 do B["DropDownList" .. l] = hide(F("Button", "DropDownList" .. l, env.UIParent)) end
        -- frames made from UIDropDownMenuTemplate get its named pieces
        local create = B.CreateFrame
        B.CreateFrame = function(ftype, fname, parent, template)
            if template ~= "UIDropDownMenuTemplate" then return create(ftype, fname, parent, template) end
            local f = create(ftype, fname, parent)
            if fname then
                for _, k in ipairs({ "Left", "Middle", "Right" }) do region("Texture", fname .. k, f) end
                region("FontString", fname .. "Text", f)
                local b = F("Button", fname .. "Button", f)
                region("Texture", fname .. "ButtonNormalTexture", b)
            end
            return f
        end
        B.FriendsDropDown = B.CreateFrame("Frame", "FriendsDropDown", env.FriendsFrame or env.UIParent, "UIDropDownMenuTemplate")

        -- the rest of UnitPopup.lua's buttons and menus (only those the base does not define)
        local BUTTONS = {
            INSPECT = "Inspect", INVITE = "Invite", TARGET = "Target", TRADE = "Trade", FOLLOW = "Follow",
            DUEL = "Duel", UNINVITE = "Uninvite", PROMOTE = "Promote to Party Leader", LOOT_PROMOTE = "Grant Loot",
            LEAVE = "Leave Party", LOOT_METHOD = "Loot Method", LOOT_THRESHOLD = "Loot Threshold",
            RESET_INSTANCES = "Reset all instances", PET_PAPERDOLL = "Pet Info", PET_RENAME = "Rename Pet",
            PET_ABANDON = "Abandon Pet", PET_DISMISS = "Dismiss Pet", RAID_LEADER = "Promote to Raid Leader",
            RAID_PROMOTE = "Promote to Assistant", RAID_DEMOTE = "Demote", RAID_REMOVE = "Remove from Raid",
            GUILD_PROMOTE = "Guild Leader", GUILD_LEAVE = "Leave Guild", RAID_TARGET_NONE = "None",
            RAID_TARGET_1 = "Star", RAID_TARGET_2 = "Circle", RAID_TARGET_3 = "Diamond", RAID_TARGET_4 = "Triangle",
            RAID_TARGET_5 = "Moon", RAID_TARGET_6 = "Square", RAID_TARGET_7 = "Cross", RAID_TARGET_8 = "Skull",
        }
        for k, text in pairs(BUTTONS) do
            if not B.UnitPopupButtons[k] then B.UnitPopupButtons[k] = { text = text, dist = 0 } end
        end
        if not B.UnitPopupButtons.RAID_TARGET_ICON then
            B.UnitPopupButtons.RAID_TARGET_ICON = { text = "Raid Target Icon", dist = 0, nested = 1 }
        end
        local MENUS = {
            PET = { "PET_PAPERDOLL", "PET_RENAME", "PET_ABANDON", "PET_DISMISS", "CANCEL" },
            RAID_PLAYER = { "WHISPER", "INSPECT", "TRADE", "FOLLOW", "DUEL", "RAID_TARGET_ICON", "RAID_LEADER",
                "RAID_PROMOTE", "RAID_DEMOTE", "RAID_REMOVE", "CANCEL" },
            RAID_TARGET_ICON = { "RAID_TARGET_1", "RAID_TARGET_2", "RAID_TARGET_3", "RAID_TARGET_4", "RAID_TARGET_5",
                "RAID_TARGET_6", "RAID_TARGET_7", "RAID_TARGET_8", "RAID_TARGET_NONE" },
        }
        for k, m in pairs(MENUS) do if not B.UnitPopupMenus[k] then B.UnitPopupMenus[k] = m end end

        -- action bars (ActionBarFrame.xml / MultiActionBars.xml): slot numbers per bar
        local BARS = {
            { "ActionButton", 0, "MainMenuBarArtFrame" }, { "MultiBarBottomLeftButton", 60, "MultiBarBottomLeft" },
            { "MultiBarBottomRightButton", 48, "MultiBarBottomRight" }, { "MultiBarRightButton", 24, "MultiBarRight" },
            { "MultiBarLeftButton", 36, "MultiBarLeft" },
        }
        for _, bar in ipairs(BARS) do
            local holder = env[bar[3]] or F("Frame", bar[3], env.UIParent)
            B[bar[3]] = holder
            for i = 1, 12 do
                local n = bar[1] .. i
                local b = F("CheckButton", n, holder)
                M.SetID(b, i)
                rawset(b, "actionSlot", bar[2] + i)
                ST[b].w, ST[b].h = 36, 36
                region("Texture", n .. "Icon", b)
                region("FontString", n .. "HotKey", b)
                region("FontString", n .. "Count", b)
                region("FontString", n .. "Name", b)
                F("Model", n .. "Cooldown", b)
                B[n] = b
            end
        end

        -- the backpack's container frame (ContainerFrame1, bag 0) with 16 item buttons
        for c = 1, 5 do
            local cf = hide(F("Frame", "ContainerFrame" .. c, env.UIParent))
            M.SetID(cf, c - 1)
            B["ContainerFrame" .. c] = cf
            for i = 1, 16 do
                local n = "ContainerFrame" .. c .. "Item" .. i
                local b = F("Button", n, cf)
                M.SetID(b, i)
                ST[b].w, ST[b].h = 37, 37
                region("Texture", n .. "IconTexture", b)
                region("FontString", n .. "Count", b)
                B[n] = b
            end
        end

        -- the target frame's aura buttons (TargetFrame.xml), refreshed like TargetDebuffButton_Update
        local tf = env.TargetFrame
        for i = 1, 16 do
            local b = hide(F("Button", "TargetFrameDebuff" .. i, tf))
            ST[b].w, ST[b].h = 15, 15
            region("Texture", "TargetFrameDebuff" .. i .. "Icon", b)
            region("FontString", "TargetFrameDebuff" .. i .. "Count", b)
            B["TargetFrameDebuff" .. i] = b
        end
        for i = 1, 5 do
            local b = hide(F("Button", "TargetFrameBuff" .. i, tf))
            ST[b].w, ST[b].h = 21, 21
            region("Texture", "TargetFrameBuff" .. i .. "Icon", b)
            B["TargetFrameBuff" .. i] = b
        end
        local ev = F("Frame", nil, tf)
        M.RegisterEvent(ev, "PLAYER_TARGET_CHANGED")
        M.RegisterEvent(ev, "UNIT_AURA")
        M.SetScript(ev, "OnEvent", function()
            if env.event == "UNIT_AURA" and env.arg1 ~= "target" then return end
            for i = 1, 16 do
                local tex = env.UnitDebuff("target", i)
                local b = env["TargetFrameDebuff" .. i]
                if tex then M.SetTexture(env["TargetFrameDebuff" .. i .. "Icon"], tex); M.Show(b) else M.Hide(b) end
            end
            for i = 1, 5 do
                local tex = env.UnitBuff("target", i)
                local b = env["TargetFrameBuff" .. i]
                if tex then M.SetTexture(env["TargetFrameBuff" .. i .. "Icon"], tex); M.Show(b) else M.Hide(b) end
            end
        end)
    end)

    -- -- Helpers ---------------------------------------------------------------------------

    function api.menu(env, level)
        level = level or 1
        if not env.__dd.shown[level] then return nil end
        return { name = env.UIDROPDOWNMENU_OPEN_MENU, items = env.__dd.lists[level] or {} }
    end
    function api.menu_texts(env, level)
        local m = api.menu(env, level)
        local out = {}
        for _, b in ipairs(m and m.items or {}) do table.insert(out, b.text) end
        return out
    end
    function api.menu_click(env, text, level)
        local m = api.menu(env, level)
        assert(m, "api.menu_click: no menu is open")
        for _, b in ipairs(m.items) do
            if b.text == text and not b.isTitle then
                local save = rawget(env, "this")
                rawset(env, "this", b)
                local ok, err = xpcall(function() if b.func then b.func(b.arg1, b.arg2) end end, api.traceback)
                rawset(env, "this", save)
                if not ok then table.insert(env.__errors, "menu entry " .. text .. ": " .. err) end
                env.HideDropDownMenu(1)
                return true
            end
        end
        error("api.menu_click: no entry '" .. text .. "' in the open menu", 2)
    end
    function api.right_click_name(env, name)
        local ok, err = xpcall(function()
            env.SetItemRef("player:" .. name, "|Hplayer:" .. name .. "|h[" .. name .. "]|h", "RightButton")
        end, api.traceback)
        if not ok then table.insert(env.__errors, "SetItemRef: " .. err) end
    end

    function api.set_action(env, slot, def)
        env.__actions[slot] = def
        if def and def.texture == nil then def.texture = "Interface\\Icons\\INV_Misc_QuestionMark" end
        fire(env, "ACTIONBAR_SLOT_CHANGED", slot)
    end
    function api.set_bag_cooldown(env, bag, slot, start, duration)
        env.__bag_cooldowns[bag .. ":" .. slot] = { start, duration }
        fire(env, "BAG_UPDATE_COOLDOWN")
    end
    function api.set_buffs(env, list)
        env.__player_buffs = list or {}
        env.__mounted = nil
        for _, b in ipairs(env.__player_buffs) do if b.mount then env.__mounted = true end end
        fire(env, "PLAYER_AURAS_CHANGED")
    end
    function api.set_mounted(env, on)
        if on then
            api.set_buffs(env, { { texture = "Interface\\Icons\\Ability_Mount_RidingHorse", name = "Brown Horse",
                desc = "Increases speed by 60%.", mount = true } })
        else
            api.set_buffs(env, {})
        end
    end
    function api.set_sitting(env, on) env.__sitting = on and true or nil end

    function api.press_key(env, key)
        local hit = false
        for _, f in ipairs(env.__frames) do
            local s = ST[f]
            if s.keyboard and s.scripts.OnKeyDown and api.is_visible(f) then
                api.run_script(f, "OnKeyDown", { key })
                hit = true
            end
        end
        return hit
    end
end
