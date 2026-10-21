--[[
    Swing.lua  -  Castline's swing timer
    A thin, see-through bar just under your character that fills until your next melee swing, while
    you auto-attack. Dual wielding adds a second, thinner bar for the off hand. Hidden out of melee.

    1.12 has no swing events, so the bar follows your own combat log: every melee hit or miss of
    yours (CHAT_MSG_COMBAT_SELF_HITS / _MISSES) is a swing, and the next-melee abilities (Heroic
    Strike, Cleave, Maul, Raptor Strike, Slam) start a new main-hand swing (CHAT_MSG_SPELL_SELF_DAMAGE).
    Weapon speeds come from UnitAttackSpeed. With two weapons a swing goes to the hand whose swing
    is nearer due.
    Setting: Casting -> swingTimer (on). It can be moved with Move / UI Studio (Castline_Swing).
]]--

local W = WenillaCore
local ID = "Casting"
local CL = Castline

local strfind = string.find

local SW = {}
CL.Swing = SW
SW.W, SW.H, SW.OFF_H = 150, 4, 2
SW.NEXT_MELEE = { ["Heroic Strike"] = true, ["Cleave"] = true, ["Maul"] = true, ["Raptor Strike"] = true, ["Slam"] = true }

local f = CreateFrame("Frame", "Castline_Swing", UIParent)
f:SetWidth(SW.W)
f:SetHeight(SW.H + 2)
f.defaultPoint = { "CENTER", UIParent, "CENTER", 0, -70 }
f:SetPoint("CENTER", UIParent, "CENTER", 0, -70)
f:SetFrameStrata("LOW")
if W.TrackPosition then W:TrackPosition(f) end
f:Hide()

local function hand(parent, h, y)
    local bg = parent:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture(0, 0, 0, 0.45)
    bg:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, y)
    bg:SetWidth(SW.W)
    bg:SetHeight(h)
    local fill = parent:CreateTexture(nil, "ARTWORK")
    fill:SetTexture(1, 1, 1, 1)
    fill:SetPoint("TOPLEFT", bg, "TOPLEFT", 0, 0)
    fill:SetHeight(h)
    fill:SetWidth(1)
    fill:SetVertexColor(1, 0.86, 0.55, 0.55)
    local edge = parent:CreateTexture(nil, "OVERLAY")
    edge:SetTexture(1, 1, 1, 0.85)
    edge:SetWidth(1)
    edge:SetHeight(h)
    edge:SetPoint("TOPLEFT", fill, "TOPRIGHT", 0, 0)
    return { bg = bg, fill = fill, edge = edge, last = nil, speed = 2 }
end
SW.mh = hand(f, SW.H, -1)
SW.oh = hand(f, SW.OFF_H, -(SW.H + 2))
f.mh, f.oh = SW.mh, SW.oh

function SW:Speeds()
    local mh, oh
    if UnitAttackSpeed then mh, oh = UnitAttackSpeed("player") end
    mh = tonumber(mh)
    if not mh or mh <= 0 then mh = 2 end
    oh = tonumber(oh)
    if oh and oh <= 0 then oh = nil end
    return mh, oh
end

function SW:Enabled()
    return W:IsActive(ID) and W:Setting(ID, "swingTimer", true) ~= false
end

-- A melee swing of yours just landed (or missed): which hand?
function SW:Swung(now, mainOnly)
    now = now or GetTime()
    local mh, oh = self:Speeds()
    self.mh.speed, self.oh.speed = mh, oh or 0
    local useOff = false
    if oh and not mainOnly and self.mh.last then
        local mhDue = self.mh.last + mh
        local ohDue = self.oh.last and (self.oh.last + oh) or now   -- no off-hand swing yet: it is due
        useOff = math.abs(now - ohDue) < math.abs(now - mhDue)
    end
    if useOff then self.oh.last = now else self.mh.last = now end
    self.dual = oh and true or false
    self.seen = now
    if self:Enabled() then f:Show() end
end

local function draw(h, now)
    if not h.last or h.speed <= 0 then
        h.fill:SetWidth(1); h.edge:Hide()
        return
    end
    local k = (now - h.last) / h.speed
    if k > 1 then k = 1 end
    h.fill:SetWidth(math.max(1, SW.W * k))
    h.edge:Show()
    if k >= 1 then h.fill:SetVertexColor(1, 1, 1, 0.75) else h.fill:SetVertexColor(1, 0.86, 0.55, 0.55) end
end

f:SetScript("OnUpdate", function()
    local now = GetTime()
    if not SW:Enabled() then f:Hide(); return end
    -- out of melee for a while: fade away
    if not SW.attacking and SW.seen and now - SW.seen > 6 then
        f:Hide()
        return
    end
    draw(SW.mh, now)
    if SW.dual then
        SW.oh.bg:Show(); SW.oh.fill:Show()
        draw(SW.oh, now)
    else
        SW.oh.bg:Hide(); SW.oh.fill:Hide(); SW.oh.edge:Hide()
    end
end)

-- A line of CHAT_MSG_COMBAT_SELF_HITS / _MISSES that is a melee swing of yours: "You hit X for 12.",
-- "You crit X for 30.", "You miss X.", "X dodges.", "X parries.", "X blocks.", "X evades.",
-- "You attack. X absorbs all the damage." (not "You fall and lose 40 health.")
function SW.IsSwing(msg)
    msg = msg or ""
    if strfind(msg, "^You hit ") or strfind(msg, "^You crit ") or strfind(msg, "^You miss ") or strfind(msg, "^You attack") then return true end
    if strfind(msg, " dodges%.$") or strfind(msg, " parries%.$") or strfind(msg, " blocks%.$") or strfind(msg, " evades%.$") then return true end
    return false
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_ENTER_COMBAT")      -- auto-attack on
ev:RegisterEvent("PLAYER_LEAVE_COMBAT")      -- and off
ev:RegisterEvent("CHAT_MSG_COMBAT_SELF_HITS")
ev:RegisterEvent("CHAT_MSG_COMBAT_SELF_MISSES")
ev:RegisterEvent("CHAT_MSG_SPELL_SELF_DAMAGE")
ev:SetScript("OnEvent", function()
    if not SW:Enabled() then f:Hide(); return end
    if event == "PLAYER_ENTER_COMBAT" then
        SW.attacking = true
        SW.seen = GetTime()
        if not SW.mh.last then SW.mh.speed = SW:Speeds() end
        f:Show()
    elseif event == "PLAYER_LEAVE_COMBAT" then
        SW.attacking = false
        SW.seen = GetTime()
    elseif event == "CHAT_MSG_SPELL_SELF_DAMAGE" then
        local msg = arg1 or ""
        local _, _, spell = strfind(msg, "^Your (.-) [hcmwip]")
        if spell and SW.NEXT_MELEE[spell] then SW:Swung(GetTime(), true) end
    elseif SW.IsSwing(arg1) then
        SW:Swung(GetTime(), false)
    end
end)

