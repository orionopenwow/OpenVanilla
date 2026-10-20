--[[ devkit/sim/ext/loot_aoe.lua -- engine-faithful looting, opt-in with opts.lootEngine = true

The base sim (ext/mail_loot_talents.lua) lets LootSlot(slot) take a slot. The wenilla engine
(def2a7b), like the 1.12 client it reimplements, does not:

  * LootSlot(slot) is ONLY the LOOT_BIND confirmation (benilla-ui script/loot.rs:278): it takes
    the row a LOOT_BIND_CONFIRM is pending for, and is ignored for any other row. The engine drains
    it after Lua returns (benilla-app ui_loot/mod.rs:927), so it is modelled with bus:later.
  * The take is a LootButton's own hardware click (benilla-ui script/button.rs click_button): the
    slot set by LootButton:SetSlot(n) is read before OnClick and taken after it, whatever mouse
    button, unless Shift, Ctrl or Alt is held. A scripted :Click() on a LootButton does nothing,
    not even its OnClick.
  * A bind-on-pickup row raises LOOT_BIND_CONFIRM(row) instead of being taken.
  * LOOT_OPENED carries no argument; the engine itself sweeps every row when autoLootDefault XOR
    Shift (ui_loot/mod.rs:720), raising one LOOT_BIND_CONFIRM at most.

With opts.lootEngine the client gets those rules; without it nothing changes, except that a
LootButton behaves as the Button it is in 1.12 in every client: SetSlot exists, SetText/GetText
work, and click_text finds it.

    api.open_loot(env, slots, { shift = true, auto = true, bop = { [3] = true } })
    env.__loot_picks        rows taken by a LootButton click, in order
    env.__loot_slot_calls   every LootSlot(n) call, in order
    env.__loot_bind_pending the row a LOOT_BIND_CONFIRM is open for
]]
return function(api, helpers)
    local M = helpers.M
    local slotOf = setmetatable({}, { __mode = "k" })    -- LootButton -> 1-based slot
    local envOf = setmetatable({}, { __mode = "k" })     -- LootButton -> its client

    function M:SetSlot(index)
        if self:GetObjectType() ~= "LootButton" then error("SetSlot: 'this' is not a LootButton widget", 2) end
        local n = tonumber(index)
        if not n then error("Usage: SetSlot(index)", 2) end
        n = (n >= 0) and math.floor(n) or math.ceil(n)
        slotOf[self] = (n >= 1) and n or nil
    end

    -- A LootButton is a Button: SetText/GetText draw on its own FontString like a Button's.
    local labelOf = setmetatable({}, { __mode = "k" })
    local setText, getText = M.SetText, M.GetText
    function M:SetText(t, a, b, c)
        if self:GetObjectType() ~= "LootButton" then return setText(self, t, a, b, c) end
        local fs = labelOf[self]
        if not fs then
            fs = self:CreateFontString(nil, "OVERLAY")
            fs:SetPoint("CENTER", self, "CENTER", 0, 0)
            labelOf[self] = fs
        end
        return setText(fs, t)
    end
    function M:GetText()
        if self:GetObjectType() ~= "LootButton" then return getText(self) end
        return labelOf[self] and labelOf[self]:GetText()
    end

    local function engine(env) return env and rawget(env, "__loot_engine") end

    -- the engine's take dispatcher (0x4c2790, flag 0): a bind-on-pickup row asks first
    local function pick(env, slot)
        local l = env.__loot[slot]
        if not l or l.taken or not env.__loot_open then return end
        table.insert(env.__loot_picks, slot)
        if l.bop then
            rawset(env, "__loot_bind_pending", slot)
            api.fire(env, "LOOT_BIND_CONFIRM", slot)
            return
        end
        env.__loot_take(slot)
    end
    api.loot_engine_pick = pick

    local installed = false
    local function install()
        if installed then return end
        installed = true

        local click = api.click
        api.click = function(o, button, force)
            local env = envOf[o]
            if not engine(env) then return click(o, button, force) end
            local slot = slotOf[o]                 -- read before OnClick, as the engine does
            local k = env.__keys
            local ok = click(o, button, force)
            if ok and slot and not (k.shift or k.ctrl or k.alt) then pick(env, slot) end
            return ok
        end
        local scripted = M.Click
        M.Click = function(self, button)
            if engine(envOf[self]) then return end  -- a LootButton ignores :Click() entirely
            return scripted(self, button)
        end

        -- a LootButton is a Button (IsObjectType chain LootButton, Button, Frame): click_text and
        -- hover_text find it as the clickable frame above a text too
        local findText = api.find_text
        api.find_text = function(env, needle, root)
            local r, button = findText(env, needle, root)
            if not r then return r, button end
            local p = r:GetParent()
            while p do
                local t = p:GetObjectType()
                if t == "Button" or t == "CheckButton" or t == "LootButton" then return r, p end
                p = p:GetParent()
            end
            return r, button
        end

        local open = api.open_loot
        api.open_loot = function(env, slots, opts)
            if not engine(env) then return open(env, slots, opts) end
            opts = opts or {}
            rawset(env, "__loot_bind_pending", nil)
            rawset(env, "__loot_picks", {})
            rawset(env, "__loot_slot_calls", {})
            local shift = opts.shift and true or false
            local auto = opts.auto or ((env.GetCVar("autoLootDefault") == "1") ~= shift)
            -- LOOT_OPENED with no argument (opts.auto would pass 1)
            open(env, slots, { shift = opts.shift })
            -- bind on pickup and uncommon or better asks first (ui_loot/mod.rs:779), or opts.bop
            for i, l in ipairs(env.__loot) do
                local d = l.id and api.item(env, l.id)
                if (opts.bop and opts.bop[i]) or (d and d.binds == "Binds when picked up" and (d.quality or 0) >= 2) then
                    l.bop = true
                end
            end
            if auto and env.__loot_open then
                local asked = false
                for i = 1, #env.__loot do
                    local l = env.__loot[i]
                    if l.bop then
                        if not asked then
                            asked = true
                            rawset(env, "__loot_bind_pending", i)
                            api.fire(env, "LOOT_BIND_CONFIRM", i)
                        end
                    else
                        env.__loot_take(i)
                    end
                end
            end
        end
    end

    local newClient = api.new_client
    api.new_client = function(opts)
        install()                                  -- every ext file has loaded by now
        local env = newClient(opts)
        local B = env.__base
        local create = B.CreateFrame
        B.CreateFrame = function(ftype, ...)
            local f = create(ftype, ...)
            if ftype == "LootButton" then envOf[f] = env end
            return f
        end
        if not (opts and opts.lootEngine) then return env end
        rawset(env, "__loot_engine", true)
        rawset(env, "__loot_picks", {})
        rawset(env, "__loot_slot_calls", {})
        rawset(env, "__loot_take", B.LootSlot)    -- the base sim's take, kept for the engine paths
        B.LootSlot = function(slot)
            table.insert(env.__loot_slot_calls, slot)
            env.__bus:later(function()
                if slot and env.__loot_bind_pending == slot then
                    rawset(env, "__loot_bind_pending", nil)
                    env.__loot_take(slot)
                end
            end)
        end
        -- the stock UIParent's half of a bind confirm (UIParent.lua / StaticPopup.lua 1.12): the
        -- LOOT_BIND popup for the row, whose Okay is LootSlot(row)
        env.StaticPopupDialogs.LOOT_BIND = env.StaticPopupDialogs.LOOT_BIND or {
            text = "Looting %s will bind it to you.",
            OnAccept = function(data) env.LootSlot(data) end,
        }
        local ui = env.CreateFrame("Frame", "Sim_StockLootBind")
        ui:RegisterEvent("LOOT_BIND_CONFIRM")
        ui:SetScript("OnEvent", function()
            local _, name = env.GetLootSlotInfo(env.arg1)
            local p = env.StaticPopup_Show("LOOT_BIND", name)
            if p then p.data = env.arg1 end
        end)
        return env
    end
end
