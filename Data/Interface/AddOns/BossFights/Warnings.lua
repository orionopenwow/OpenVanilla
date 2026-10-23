--[[
    Warnings.lua  (Open Vanilla / Boss Fights)
    Big centre-screen calls, with a sound, for the boss fight in front of you. Onyxia first (realm/bossfights/
    onyxia-strategy.md): the pull, lift-off at 65%, each Deep Breath, the whelps, the landing at 40% and its fear,
    each Bellowing Roar, a Fireball that hit you, and "soon" calls a few percent before each phase.

    It reads only what the 1.12 client shows: the boss's yells and emotes (CHAT_MSG_MONSTER_YELL / _EMOTE), the
    combat log lines (CHAT_MSG_SPELL_* / CHAT_MSG_COMBAT_*) and the boss's health when someone targets it. It works
    in any Onyxia's Lair and in a Boss Fights run there. /bfw turns the calls off and on; /bfw test shows one.
    Lua 5.0 rules: no #, no %, string.find with plain = true, this/event/arg1 in scripts.
]]--

local W = WenillaCore
local UI = W and W.UI

BossFightsWarnings = BossFightsWarnings or {}
local BW = BossFightsWarnings

BW.on = true
BW.boss = "Onyxia"
BW.last = {}            -- key -> GetTime() of the last call, so one mechanic is called once
BW.said = {}            -- "soon" calls made this fight (key -> true)
BW.fighting = false

-- the calls: text, colour, how long it stays (s), the sound, and the gap before the same call again (s)
BW.CALLS = {
    pull     = { text = "Onyxia: tank turns her to the north wall. Everyone else to her sides.", color = { 1, 0.82, 0 }, hold = 5, sound = "RaidWarning", gap = 30 },
    p2soon   = { text = "Lift-off soon (65%): get ready to spread.", color = { 1, 0.82, 0 }, hold = 3, gap = 600 },
    flying   = { text = "She's flying: spread 8 yards, stay off the line through the middle.", color = { 1, 0.5, 0.1 }, hold = 6, sound = "RaidWarning", gap = 20 },
    breath   = { text = "DEEP BREATH: move to her sides!", color = { 1, 0.15, 0.1 }, hold = 4, sound = "RaidWarning", gap = 6 },
    whelps   = { text = "Whelps! Tanks pick them up, AoE them.", color = { 1, 0.7, 0.2 }, hold = 4, sound = "RaidWarning", gap = 25 },
    p3soon   = { text = "Landing soon (40%): tank, be ready.", color = { 1, 0.82, 0 }, hold = 3, gap = 600 },
    landing  = { text = "Landing: tank, pick her up. Fear now! Hold damage a moment.", color = { 1, 0.3, 0.3 }, hold = 6, sound = "RaidWarning", gap = 20 },
    roar     = { text = "FEAR: Bellowing Roar!", color = { 0.85, 0.4, 1 }, hold = 3, sound = "RaidWarning", gap = 8 },
    fireball = { text = "Fireball hit you: keep 8 yards from everyone.", color = { 1, 0.5, 0.1 }, hold = 3, gap = 8 },
    win      = { text = "Onyxia is down!", color = { 0.4, 1, 0.4 }, hold = 5, gap = 60 },
}

-- what the boss says, what it emotes, what the combat log shows: a plain-text piece -> a call
BW.YELLS = {
    { "usually, i must leave my lair", "pull" },
    { "from above", "flying" },
    { "another lesson", "landing" },
}
BW.EMOTES = {
    { "deep breath", "breath" },
}
BW.LOG = {
    { "onyxia begins to cast bellowing roar", "roar" },
    { "onyxia's bellowing roar", "roar" },
    { "onyxia's fireball hits you", "fireball" },
    { "onyxian whelp", "whelps" },
    { "onyxia dies", "win" },
}

local function lower(s) return string.lower(s or "") end
local function has(s, piece) return string.find(s, piece, 1, true) ~= nil end

-- The banner: one line of big text in the upper middle of the screen, fading out.
function BW.Frame()
    if BW.frame then return BW.frame end
    local f = CreateFrame("Frame", "BossFightsWarningFrame", UIParent)
    f:SetWidth(760); f:SetHeight(60)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 170)
    f:SetFrameStrata("HIGH")
    local t = f:CreateFontString(nil, "OVERLAY")
    if UI and UI.Font then UI.Font(t, 22, "THICKOUTLINE") else t:SetFont("Fonts\\FRIZQT__.TTF", 22, "THICKOUTLINE") end
    t:SetPoint("CENTER", f, "CENTER", 0, 0)
    t:SetShadowOffset(2, -2)
    t:SetShadowColor(0, 0, 0, 1)
    f.text = t
    f:SetScript("OnUpdate", function()
        if not this.hideAt then return end
        local left = this.hideAt - GetTime()
        if left <= 0 then
            this.hideAt = nil
            this:Hide()
        elseif left < 1 then
            this:SetAlpha(left)
        end
    end)
    f:Hide()
    BW.frame = f
    return f
end

-- Show a call by key (or any text with `color`); `force` skips the gap.
function BW.Call(key, force)
    local c = BW.CALLS[key]
    if not c or not BW.on then return false end
    local now = GetTime()
    if not force and BW.last[key] and now - BW.last[key] < (c.gap or 5) then return false end
    BW.last[key] = now
    local f = BW.Frame()
    f.text:SetText(c.text)
    f.text:SetTextColor(c.color[1], c.color[2], c.color[3])
    f:SetAlpha(1)
    f.hideAt = now + (c.hold or 4)
    f:Show()
    if c.sound and PlaySound then PlaySound(c.sound) end
    BW.lastKey = key
    return true
end

-- A Boss Fights run in Onyxia's Lair, or Onyxia's Lair itself.
function BW.Active()
    if not BW.on then return false end
    local B = BossFights
    if B and B.run and B.run.raid == "onyxia" then return true end
    local zone = GetRealZoneText and GetRealZoneText() or ""
    return zone == "Onyxia's Lair"
end

local function match(list, text)
    local t = lower(text)
    for _, row in ipairs(list) do
        if has(t, row[1]) then return row[2] end
    end
    return nil
end

function BW.OnYell(text, who)
    if who and lower(who) ~= lower(BW.boss) then return nil end
    local key = match(BW.YELLS, text)
    if key == "pull" then BW.said = {}; BW.fighting = true end
    if key then BW.Call(key) end
    return key
end

function BW.OnEmote(text, who)
    local key = match(BW.EMOTES, text)
    if key then BW.Call(key) end
    return key
end

function BW.OnLog(text)
    local key = match(BW.LOG, text)
    if key == "whelps" and not BW.fighting then return nil end     -- whelps in the tunnel before the fight: no call
    if key == "win" then BW.fighting = false end
    if key then BW.Call(key) end
    return key
end

-- The "soon" calls from the boss's health (someone in the raid targets it: its health shows on the target).
function BW.OnHealth(pct)
    if not pct then return nil end
    BW.fighting = true
    if pct <= 68 and pct > 65 and not BW.said.p2soon then BW.said.p2soon = true; BW.Call("p2soon"); return "p2soon" end
    if pct <= 43 and pct > 40 and not BW.said.p3soon then BW.said.p3soon = true; BW.Call("p3soon"); return "p3soon" end
    return nil
end

local function bossHealth()
    for _, u in ipairs({ "target", "targettarget" }) do
        if UnitExists and UnitExists(u) and UnitName(u) == BW.boss and UnitHealthMax(u) and UnitHealthMax(u) > 0 then
            return math.floor(UnitHealth(u) * 100 / UnitHealthMax(u))
        end
    end
    -- the raid's targets
    local n = GetNumRaidMembers and GetNumRaidMembers() or 0
    for i = 1, n do
        local u = "raid" .. i .. "target"
        if UnitExists and UnitExists(u) and UnitName(u) == BW.boss and UnitHealthMax(u) and UnitHealthMax(u) > 0 then
            return math.floor(UnitHealth(u) * 100 / UnitHealthMax(u))
        end
    end
    return nil
end

local ev = CreateFrame("Frame", "BossFightsWarningEvents")
ev:RegisterEvent("CHAT_MSG_MONSTER_YELL")
ev:RegisterEvent("CHAT_MSG_MONSTER_EMOTE")
ev:RegisterEvent("CHAT_MSG_RAID_BOSS_EMOTE")
ev:RegisterEvent("CHAT_MSG_SPELL_CREATURE_VS_CREATURE_DAMAGE")
ev:RegisterEvent("CHAT_MSG_SPELL_CREATURE_VS_SELF_DAMAGE")
ev:RegisterEvent("CHAT_MSG_SPELL_CREATURE_VS_PARTY_DAMAGE")
ev:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_SELF_DAMAGE")
ev:RegisterEvent("CHAT_MSG_COMBAT_CREATURE_VS_SELF_HITS")
ev:RegisterEvent("CHAT_MSG_COMBAT_CREATURE_VS_PARTY_HITS")
ev:RegisterEvent("CHAT_MSG_COMBAT_HOSTILE_DEATH")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:SetScript("OnEvent", function()
    if not BW.Active() then return end
    if event == "CHAT_MSG_MONSTER_YELL" then BW.OnYell(arg1, arg2)
    elseif event == "CHAT_MSG_MONSTER_EMOTE" or event == "CHAT_MSG_RAID_BOSS_EMOTE" then BW.OnEmote(arg1, arg2)
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- out of combat (a wipe, or the end): the next pull starts over
        BW.fighting = false
        BW.said = {}
    else BW.OnLog(arg1) end
end)

local tick = CreateFrame("Frame", "BossFightsWarningTick")
local acc = 0
tick:SetScript("OnUpdate", function()
    acc = acc + (arg1 or 0)
    if acc < 0.5 then return end
    acc = 0
    if BW.Active() then BW.OnHealth(bossHealth()) end
end)

SLASH_BOSSFIGHTSWARN1 = "/bfw"
SlashCmdList["BOSSFIGHTSWARN"] = function(msg)
    msg = lower(msg)
    if msg == "test" then
        BW.Call("breath", true)
        return
    end
    BW.on = not BW.on
    if W and W.Print then
        W.Print("|cffff8000Boss Fights:|r boss warnings " .. (BW.on and "on" or "off") .. ". /bfw test shows one.")
    end
end
