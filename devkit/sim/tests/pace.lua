-- WenillaCore/Pace.lua: the realm's own Hearthstone cooldown and Blessing duration (the PZ line)
-- in tooltips, cooldown timers and Essentials' aura timers.
local T, api = ...

local ITEMS = {
    [6948] = { name = "Hearthstone", quality = 1, icon = "Interface\\Icons\\INV_Misc_Rune_01", stack = 1,
               lines = { "Soulbound", "Unique", "Use: Returns you to Goldshire.", "Cooldown remaining: 59 min" } },
    [90001] = { name = "Blessing of Might", quality = 1, stack = 1,
                lines = { "Places a Blessing on the friendly target, increasing melee attack power by 20 for 5 min." } },
    [90002] = { name = "Blessing of Might", quality = 1, stack = 1,
                lines = { "Lasts 15 min, not 5 min." } },
}

local function line(env, i) return env.GameTooltipTextLeft1 and env["GameTooltipTextLeft" .. i]:GetText() end

T.test("Pace: nothing changes until the realm sends numbers that differ from 1.12's", function()
    local env = T.addon("Essentials", { items = ITEMS })
    api.connect(env, "1")
    env.GameTooltip:SetHyperlink("item:90001:0:0:0")
    T.has(line(env, 2), "for 5 min.")
    api.server_packet(env, "PZ", "3600000,300000")              -- a stock realm
    env.GameTooltip:SetHyperlink("item:90001:0:0:0")
    T.has(line(env, 2), "for 5 min.", "stock numbers: untouched")
    T.eq(env.Essentials.AURA_DURATIONS["Blessing of Might"], 300)
    T.no(env.WenillaCore.pace.cooldownsWrapped, "no cooldown wrappers on a stock realm")
end)

T.test("Pace: Blessing tooltips and Essentials' timers use the realm's duration", function()
    local env = T.addon("Essentials", { items = ITEMS })
    api.connect(env, "1")
    api.server_packet(env, "PZ", "900000,900000")
    env.GameTooltip:SetHyperlink("item:90001:0:0:0")
    T.has(line(env, 2), "for 15 min.")
    env.GameTooltip:SetHyperlink("item:90002:0:0:0")
    T.eq(line(env, 2), "Lasts 15 min, not 15 min.", "the 5 inside 15 is left alone")
    for _, s in ipairs({ "Blessing of Might", "Blessing of Kings", "Blessing of Sanctuary" }) do
        T.eq(env.Essentials.AURA_DURATIONS[s], 900, s)
    end
    T.eq(env.Essentials.AURA_DURATIONS["Greater Blessing of Might"], 900, "Greater Blessings were 15 min already")
    T.eq(env.Essentials.AURA_DURATIONS["Blessing of Protection"], 10, "other Blessings untouched")
end)

T.test("Pace: the Hearthstone counts the realm's cooldown, then reads ready", function()
    local env = T.addon("Essentials", { items = ITEMS })
    api.set_bag(env, 0, 16)
    local slot = api.give_item(env, 6948, 1, 0)
    local castAt = env.GetTime()
    -- the client's own idea: an hour from when it was used
    env.GetContainerItemCooldown = function(bag, s) if bag == 0 and s == slot then return castAt, 3600, 1 end return 0, 0, 1 end
    env.GetActionCooldown = function() return castAt, 3600, 1 end
    env.GetActionTexture = function(n) return n == 1 and "Interface\\Icons\\INV_Misc_Rune_01" or nil end
    api.connect(env, "1")
    api.server_packet(env, "PZ", "900000,900000")
    local s, d = env.GetContainerItemCooldown(0, slot)
    T.eq(s, castAt); T.eq(d, 900, "bag cooldown: 15 minutes")
    s, d = env.GetActionCooldown(1)
    T.eq(d, 900, "action bar cooldown: 15 minutes")
    s, d = env.GetActionCooldown(2)
    T.eq(d, 3600, "another button with an hour-long cooldown keeps it")
    env.GameTooltip:SetBagItem(0, slot)
    T.eq(line(env, 5), "Cooldown remaining: 15 min")
    api.tick(env, 600, 30)
    env.GameTooltip:SetBagItem(0, slot)
    T.eq(line(env, 5), "Cooldown remaining: 5 min")
    api.tick(env, 301, 30)
    s, d = env.GetContainerItemCooldown(0, slot)
    T.eq(s, 0); T.eq(d, 0, "past the realm's 15 minutes: ready")
    env.GameTooltip:SetBagItem(0, slot)
    T.eq(line(env, 5) or "", "", "no 'Cooldown remaining' once it is ready")
end)

T.test("Pace: a malformed PZ line changes nothing", function()
    local env = T.addon("Essentials", { items = ITEMS })
    api.connect(env, "1")
    api.server_packet(env, "PZ", "soon")
    api.server_packet(env, "PZ", "")
    T.eq(env.Essentials.AURA_DURATIONS["Blessing of Might"], 300)
    T.no(env.WenillaCore.pace.hearth)
end)
