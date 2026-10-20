--[[
    ext/quests.lua - the quest log, quest NPC, spell book tracking, corpse and the stock minimap
    and quest frames, for the Quests addon's tests.

    State on env:
        __questlog   { { header = "Elwynn Forest", collapsed = false },
                       { title, level, tag, complete = 1|-1|nil, objectives = { { text, type, done } },
                         desc, objText, rewards = { { id, count } }, choices = { { id, count, usable } },
                         money, pushable }, ... }      (collapsed headers hide their quests, as in 1.12)
        __questnpc   the quest NPC dialog: { title, choices = { { id } }, rewards, complete }
        __abandoned, __rewards, __completed_quests, __pushed, __tracking, __corpse
    Test helpers added to api:
        api.set_quests(env, list)        replace the quest log and fire QUEST_LOG_UPDATE
        api.quest(env, title)            the log entry with that title (edit it, then fire QUEST_LOG_UPDATE)
        api.quest_npc(env, def, event)   talk to a quest NPC (event: "QUEST_PROGRESS" | "QUEST_COMPLETE" ...)
        api.set_dead(env, dead, x, y)    die with the corpse at map x, y (nil x: on another map), or revive
    opts.spells = { "Find Herbs", ... } is the spell book. The quest NPC functions fall back to
    ext/units_actions.lua's env.__quest model when no __questnpc is set.
]]--

return function(api, H)
    local M, newObject = H.M, H.newObject
    local ST = api.ST

    local function deepcopy(v)
        if type(v) ~= "table" then return v end
        local o = {}
        for k, x in pairs(v) do o[k] = deepcopy(x) end
        return o
    end

    function api.set_quests(env, list)
        env.__questlog = deepcopy(list or {})
        env.__qsel = 0
        api.fire(env, "QUEST_LOG_UPDATE")
    end

    function api.quest(env, title)
        for _, e in ipairs(env.__questlog) do if e.title == title then return e end end
    end

    function api.quest_npc(env, def, event)
        rawset(env, "__questnpc", def)
        if event then api.fire(env, event) end
    end

    -- ghost = released spirit (the corpse arrow only shows then); dead alone = still lying there
    -- The player turns: radians counter-clockwise from north, as the client's minimap arrow.
    function api.set_facing(env, f) ST[env.__minimapArrows[9]].facing = f end
    function api.set_cursor(env, x, y) rawset(env, "__cursor", { x, y }) end

    function api.set_dead(env, dead, x, y, ghost)
        env.__units.player.dead = (dead and not ghost) and true or nil
        env.__units.player.ghost = (dead and ghost) and true or nil
        rawset(env, "__corpse", (dead and x) and { x = x, y = y } or nil)
        local wasGhost = rawget(env, "__wasGhost")
        rawset(env, "__wasGhost", env.__units.player.ghost)
        -- the client: PLAYER_DEAD on dying, PLAYER_ALIVE on releasing, PLAYER_UNGHOST on getting the body back
        if dead and ghost then api.fire(env, "PLAYER_ALIVE")
        elseif dead then api.fire(env, "PLAYER_DEAD")
        else api.fire(env, wasGhost and "PLAYER_UNGHOST" or "PLAYER_ALIVE") end
    end

    api.client_late_extensions = api.client_late_extensions or {}
    table.insert(api.client_late_extensions, function(env, B, opts)
        for _, k in ipairs({ "__questlog", "__abandoned", "__rewards", "__completed_quests" }) do rawset(env, k, {}) end
        rawset(env, "__watched", {})
        rawset(env, "__casts", rawget(env, "__casts") or {})

        -- -- quest log ------------------------------------------------------------------------
        local function qvis()
            local out, hidden = {}, false
            for _, e in ipairs(env.__questlog) do
                if e.header then
                    hidden = e.collapsed and true or false
                    table.insert(out, e)
                elseif not hidden then
                    table.insert(out, e)
                end
            end
            return out
        end
        local function qsel() return qvis()[env.__qsel or 0] end
        rawset(env, "__questlog_selected", qsel)
        local function qat(i) if i then return qvis()[i] end return qsel() end
        local function removeQuest(e)
            for k, x in ipairs(env.__questlog) do if x == e then table.remove(env.__questlog, k) break end end
            env.__qsel = 0
            api.fire(env, "QUEST_LOG_UPDATE")
        end

        B.GetNumQuestLogEntries = function()
            local n = 0
            for _, e in ipairs(env.__questlog) do if not e.header then n = n + 1 end end
            return #qvis(), n
        end
        B.GetQuestLogTitle = function(i)
            local e = qvis()[i]
            if not e then return nil end
            if e.header then return e.header, 0, nil, 1, e.collapsed and 1 or nil, nil end
            return e.title, e.level or 1, e.tag, nil, nil, e.complete
        end
        B.GetNumQuestLeaderBoards = function(i) local e = qat(i); return e and e.objectives and #e.objectives or 0 end
        B.GetQuestLogLeaderBoard = function(j, i)
            local e = qat(i)
            local o = e and e.objectives and e.objectives[j]
            if o then return o.text, o.type or "monster", o.done and 1 or nil end
        end
        B.SelectQuestLogEntry = function(i) env.__qsel = i end
        B.GetQuestLogSelection = function() return env.__qsel or 0 end
        B.GetQuestLogQuestText = function() local e = qsel(); if e then return e.desc or "", e.objText or "" end end
        B.GetQuestLogRewardMoney = function() local e = qsel(); return e and e.money or 0 end
        B.GetQuestLogRequiredMoney = function() return 0 end
        B.GetQuestLogTimeLeft = function() return nil end
        B.GetNumQuestLogRewards = function() local e = qsel(); return e and e.rewards and #e.rewards or 0 end
        B.GetNumQuestLogChoices = function() local e = qsel(); return e and e.choices and #e.choices or 0 end
        local function reward(list, i)
            local r = list and list[i]
            local d = r and api.item(env, r.id)
            if d then return d.name, d.icon, r.count or 1, d.quality or 1, (r.usable ~= false) and 1 or nil end
        end
        B.GetQuestLogRewardInfo = function(i) local e = qsel(); return reward(e and e.rewards, i) end
        B.GetQuestLogChoiceInfo = function(i) local e = qsel(); return reward(e and e.choices, i) end
        B.GetQuestLogItemLink = function(kind, i)
            local e = qsel()
            local list = e and (kind == "choice" and e.choices or e.rewards)
            return list and list[i] and api.item_link(env, list[i].id)
        end
        B.GetQuestLogPushable = function() local e = qsel(); return e and e.pushable ~= false and 1 or nil end
        B.QuestLogPushQuest = function() local e = qsel(); rawset(env, "__pushed", e and e.title) end
        local function headers(i, collapsed)
            local list = (i == 0) and env.__questlog or { qvis()[i] }
            for _, e in ipairs(list) do if e.header then e.collapsed = collapsed end end
        end
        B.ExpandQuestHeader = function(i) headers(i, false) end
        B.CollapseQuestHeader = function(i) headers(i, true) end
        B.IsQuestWatched = function(i) local e = qvis()[i]; return e and env.__watched[e] and 1 or nil end
        B.AddQuestWatch = function(i) local e = qvis()[i]; if e then env.__watched[e] = true end end
        B.RemoveQuestWatch = function(i) local e = qvis()[i]; if e then env.__watched[e] = nil end end
        B.GetNumQuestWatches = function() local n = 0; for _ in pairs(env.__watched) do n = n + 1 end; return n end
        B.SetAbandonQuest = function() rawset(env, "__abandon", qsel()) end
        B.GetAbandonQuestName = function() return env.__abandon and env.__abandon.title end
        B.AbandonQuest = function()
            local e = env.__abandon
            rawset(env, "__abandon", nil)
            if e then
                table.insert(env.__abandoned, e.title)
                removeQuest(e)
            end
        end
        B.GetQuestGreenRange = function() return 8 end

        -- -- the quest NPC dialog (falls back to units_actions' env.__quest) -------------------
        local prev = { GetNumQuestChoices = B.GetNumQuestChoices, GetQuestReward = B.GetQuestReward,
            IsQuestCompletable = B.IsQuestCompletable, CompleteQuest = B.CompleteQuest }
        B.GetTitleText = function() return env.__questnpc and env.__questnpc.title or "" end
        B.GetNumQuestChoices = function()
            local n = env.__questnpc
            if n then return n.choices and #n.choices or 0 end
            return prev.GetNumQuestChoices and prev.GetNumQuestChoices() or 0
        end
        B.GetQuestItemInfo = function(kind, i)
            local n = env.__questnpc
            return reward(n and (kind == "choice" and n.choices or n.rewards), i)
        end
        B.GetQuestItemLink = function(kind, i)
            local n = env.__questnpc
            local list = n and (kind == "choice" and n.choices or n.rewards)
            return list and list[i] and api.item_link(env, list[i].id)
        end
        B.IsQuestCompletable = function()
            if env.__questnpc then return env.__questnpc.complete and 1 or nil end
            return prev.IsQuestCompletable and prev.IsQuestCompletable()
        end
        B.CompleteQuest = function()
            if env.__questnpc then table.insert(env.__completed_quests, env.__questnpc.title) end
            if prev.CompleteQuest then prev.CompleteQuest() end
        end
        B.GetQuestReward = function(choice)
            local n = env.__questnpc
            if prev.GetQuestReward then prev.GetQuestReward(choice) end
            if not n then return end
            table.insert(env.__rewards, { title = n.title, choice = choice })
            for _, e in ipairs(env.__questlog) do
                if e.title == n.title then removeQuest(e) break end
            end
        end

        -- -- map, corpse, spell book, tracking ---------------------------------------------------
        local function where()
            local zone = env.__map.zone
            for c, list in ipairs(api.MAP_ZONES or {}) do
                for z, name in ipairs(list) do if name == zone then return c, z end end
            end
            return env.__map.continent or 2, 1
        end
        B.GetCurrentMapContinent = function() local c = where(); return c end
        B.GetCurrentMapZone = function() local _, z = where(); return z end
        if not api.MAP_ZONES then B.GetMapZones = function() return env.__map.zone end end
        B.GetCorpseMapPosition = function() local c = env.__corpse; if c then return c.x, c.y end return 0, 0 end
        B.GetNumSpellTabs = function() return 1 end
        B.GetSpellTabInfo = function() return "General", "Interface\\Icons\\INV_Misc_Book_09", 0, #(opts.spells or {}) end
        B.GetSpellName = function(i) local n = (opts.spells or {})[i]; if n then return n, "" end end
        local prevCast = B.CastSpellByName
        B.CastSpellByName = function(spell, onSelf)
            if prevCast then prevCast(spell, onSelf) else table.insert(env.__casts, { spell = spell }) end
            if spell == "Find Herbs" then rawset(env, "__tracking", "Interface\\Icons\\INV_Misc_Flower_02") end
            if spell == "Find Minerals" then rawset(env, "__tracking", "Interface\\Icons\\Spell_Nature_Earthquake") end
        end
        B.GetTrackingTexture = function() return env.__tracking end
        B.CancelTrackingBuff = function() rawset(env, "__tracking", nil) end

        -- -- stock frames: the minimap frame (Minimap.xml), quest log and watch, world map button --
        local function F(t, n, p) return newObject(env, t, n, p) end

        -- The CMinimap ctor's nine unnamed Model children, before anything else: eight
        -- Rotating-MinimapArrow (party / POI, never turned) and the player's MinimapArrow, which
        -- the client turns to the player's facing (radians counter-clockwise from north).
        if not M.GetFacing then
            function M:GetModel() return ST[self].model end
            function M:SetModel(m) ST[self].model = m end
            function M:GetFacing() return ST[self].facing or 0 end
            function M:SetFacing(f) ST[self].facing = f end
        end
        if not rawget(env, "__minimapArrows") then
            local mm, kids = env.Minimap, {}
            for i = 1, 9 do
                local m = newObject(env, "Model", nil, mm)
                ST[m].model = (i == 9) and "Interface\\Minimap\\MinimapArrow.mdx" or "Interface\\Minimap\\Rotating-MinimapArrow.mdx"
                ST[m].facing = 0
                kids[i] = m
            end
            -- engine children come first, whatever the XML or addons add later
            local ch = ST[mm].children
            for i = 1, 9 do for j = table.getn(ch), 1, -1 do if ch[j] == kids[i] then table.remove(ch, j) end end end
            for i = 9, 1, -1 do table.insert(ch, 1, kids[i]) end
            rawset(env, "__minimapArrows", kids)
        end
        local cl = env.MinimapCluster
        ST[cl].level = 1
        ST[env.Minimap].level = 2
        local bd = rawget(env, "MinimapBackdrop") or F("Frame", "MinimapBackdrop", cl)
        ST[bd].level = 2
        if not rawget(env, "MinimapBorder") then
            local border = newObject(env, "Texture", "MinimapBorder", bd, true)
            ST[border].texture = "Interface\\Minimap\\UI-Minimap-Border"
        end
        if not rawget(env, "MinimapBorderTop") then
            local top = newObject(env, "Texture", "MinimapBorderTop", cl, true)
            ST[top].texture = "Interface\\Minimap\\UI-Minimap-Border"
        end
        for _, n in ipairs({ "MinimapZoomIn", "MinimapZoomOut", "MinimapToggleButton" }) do
            if not rawget(env, n) then
                local b = F("Button", n, bd)
                M.SetPoint(b, "CENTER", bd, "CENTER", 0, 0)
            end
        end
        if not rawget(env, "MiniMapTrackingFrame") then
            local tr = F("Frame", "MiniMapTrackingFrame", bd); ST[tr].shown = false
            M.SetPoint(tr, "TOPLEFT", bd, "TOPLEFT", -15, 0)
        end
        if not rawget(env, "MiniMapMailFrame") then
            local mail = F("Frame", "MiniMapMailFrame", bd); ST[mail].shown = false
            M.SetPoint(mail, "TOPRIGHT", bd, "TOPRIGHT", 0, 0)
        end
        if not rawget(env, "MinimapZoneTextButton") then
            local zb = F("Button", "MinimapZoneTextButton", cl)
            M.SetPoint(zb, "CENTER", cl, "TOP", 8, -10)
            newObject(env, "FontString", "MinimapZoneText", zb, true)
        end
        if not rawget(env, "GameTimeFrame") then F("Button", "GameTimeFrame", cl) end
        if not rawget(env, "QuestWatchFrame") then local qw = F("Frame", "QuestWatchFrame", env.UIParent); ST[qw].shown = false end
        if not rawget(env, "QuestLogFrame") then local ql = F("Frame", "QuestLogFrame", env.UIParent); ST[ql].shown = false end
        if not rawget(env, "QuestLogMicroButton") then
            local mb = F("Button", "QuestLogMicroButton", env.UIParent)
            M.SetScript(mb, "OnClick", function() env.ToggleQuestLog() end)
        end
        if not rawget(env, "WorldMapButton") then
            local wmb = F("Button", "WorldMapButton", env.WorldMapFrame)
            ST[wmb].w, ST[wmb].h = 1002, 668
            -- the stock WorldMapButton_OnClick (zoom out / pick a zone), counted
            M.SetScript(wmb, "OnClick", function() rawset(env, "__mapClicks", (rawget(env, "__mapClicks") or 0) + 1) end)
        end
        if not rawget(env, "WorldMapDetailFrame") then F("Frame", "WorldMapDetailFrame", env.WorldMapFrame) end
        for _, k in ipairs({ "MinimapBackdrop", "MinimapBorder", "MinimapBorderTop", "MinimapZoomIn", "MinimapZoomOut",
            "MinimapToggleButton", "MiniMapTrackingFrame", "MiniMapMailFrame", "MinimapZoneTextButton", "MinimapZoneText",
            "GameTimeFrame", "QuestWatchFrame", "QuestLogFrame", "QuestLogMicroButton", "WorldMapButton", "WorldMapDetailFrame" }) do
            B[k] = rawget(env, k)
        end
        B.ToggleQuestLog = function() local f = env.QuestLogFrame; if f:IsShown() then f:Hide() else f:Show() end end
        B.QuestWatch_Update = function() if B.GetNumQuestWatches() > 0 then env.QuestWatchFrame:Show() end end
    end)
end
