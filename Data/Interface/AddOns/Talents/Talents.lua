--[[
    Talents.lua
    Talent tools that need the realm's help, plus the panel that holds them on the talent frame.

      * Reset Talents: a free reset (".wnl respec", the realm answers "RS ok" or "RS err,<why>").
        Out of combat and outside instances only; it asks first.
      * Two specs: "SP <active>,<count>;<name1>;<name2>". Two tabs on the talent frame, each with
        its own name (".wnl specname <n> <name>"), the active one marked, and a Switch button
        (".wnl spec <n>"; the realm casts for 5 seconds, a bar shows it). ".wnl specs" asks.
      * The planner (Planner.lua) for both specs.
      * Hunters' starter pets: "PG 0" means the pet acts on its own for now, so its action bar is
        hidden; "PG 1" brings it back.
      * New spell ranks learned on level up: "LL <spell (Rank n)>;..." shows a toast and a chat line.

    On a realm without these packets nothing changes: no spec tabs, and the reset button explains
    that it needs the realm update. Blizzard_TalentUI loads on demand, so the panel is added when
    it loads (ADDON_LOADED).
]]--

local W = WenillaCore
local UI = W.UI
local ID = "Talents"

ClassicPlusTalents = ClassicPlusTalents or {}
local T = ClassicPlusTalents

local floor, strfind, strlower, strsub, strlen = math.floor, string.find, string.lower, string.sub, string.len
local getn = table.getn

local SWITCH_TIME = 5          -- the realm's cast
local SWITCH_GRACE = 6         -- extra wait for its SP answer
local RESET_WAIT = 6           -- seconds to wait for RS
local NAME_MAX = 20
local ICON = "Interface\\Icons\\Ability_Marksmanship"
local RESET_ICON = "Interface\\Icons\\Spell_Holy_DispelMagic"

T.specs = nil                  -- { active = n, count = n, names = { "Raid", "PvP" } } once SP arrives
T.switching = nil              -- { to, started }
T.resetPending = nil           -- time the respec was asked
T.petGated = false

local function active() return W:IsActive(ID) end
local function opt(key) return active() and W:Setting(ID, key, true) end

function T.Say(msg)
    if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cffffd100Talents:|r " .. msg) end
end
local say = T.Say

function T.CharKey()
    return (UnitName("player") or "?") .. "-" .. (GetRealmName and GetRealmName() or "")
end

function T.DB()
    if type(ClassicPlusTalents_DB) ~= "table" then ClassicPlusTalents_DB = {} end
    local d = ClassicPlusTalents_DB
    d.builds = d.builds or {}
    d.plans = d.plans or {}
    return d
end

function T.SpecName(n)
    local s = T.specs
    local name = s and s.names[n]
    if not name or name == "" then return "Spec " .. n end
    return name
end

-- Talent points spent in the active spec.
function T.Spent()
    local n = 0
    for t = 1, (GetNumTalentTabs and GetNumTalentTabs() or 0) do
        local _, _, points = GetTalentTabInfo(t)
        n = n + (points or 0)
    end
    return n
end

local function inCombat() return UnitAffectingCombat("player") and true or false end
local function inInstance()
    if not IsInInstance then return false end
    local inside, kind = IsInInstance()
    return inside and kind ~= "none" and true or false
end

-- -- Spec switching notice (a cast-style bar, top centre) ----------------------------------------

local notice = CreateFrame("Frame", "Talents_SwitchBar", UIParent)
UI.Themed(notice, "raised")
notice:SetWidth(250)
notice:SetHeight(30)
notice:SetPoint("TOP", UIParent, "TOP", 0, -170)
notice:SetFrameStrata("HIGH")
notice:Hide()
local noticeBar = UI.Bar(notice, { width = 236, height = 18, icon = true })
noticeBar:SetPoint("CENTER", notice, "CENTER", 0, 0)
noticeBar.icon:SetTexture(ICON)
noticeBar:SetColor(UI.ACCENT[1], UI.ACCENT[2] * 0.8, 0.1)
T.noticeBar = noticeBar

local function setSwitchText(text, right)
    noticeBar.left:SetText(text)
    noticeBar.right:SetText(right or "")
end

notice:SetScript("OnUpdate", function()
    local s = T.switching
    if not s then
        -- a finished or failed switch lingers a moment
        notice.linger = (notice.linger or 0) - (arg1 or 0)
        if notice.linger <= 0 then notice:Hide() end
        return
    end
    local t = GetTime() - s.started
    local frac = t / SWITCH_TIME
    if frac > 1 then frac = 1 end
    noticeBar:SetFraction(frac)
    if t < SWITCH_TIME then
        setSwitchText("Switching to " .. T.SpecName(s.to), string.format("%.1f", SWITCH_TIME - t))
    else
        setSwitchText("Switching to " .. T.SpecName(s.to), "")
    end
    if t > SWITCH_TIME + SWITCH_GRACE then
        T:EndSwitch(false, "The switch didn't finish. Try again out of combat.")
    end
    if T.strip and T.strip:IsVisible() then T:UpdateStrip() end
end)

function T:EndSwitch(ok, text)
    self.switching = nil
    notice.linger = 2
    if ok then
        noticeBar:SetFraction(1)
        noticeBar:SetColor(0.25, 0.75, 0.3)
    else
        noticeBar:SetColor(0.75, 0.25, 0.2)
    end
    setSwitchText(text or "", "")
    if text then say(text) end
    self:UpdateStrip()
end

function T:Switch(n)
    if not active() then return end
    local s = self.specs
    if not s or n < 1 or n > (s.count or 0) then return end
    if self.switching then return end
    if s.active == n then
        say(T.SpecName(n) .. " is already your active spec.")
        return
    end
    if inCombat() then say("Leave combat first, then switch specs.") return end
    if not W:SendCommand("spec", tostring(n)) then
        say("Switching specs needs the realm update.")
        return
    end
    self.switching = { to = n, started = GetTime() }
    noticeBar:SetColor(UI.ACCENT[1], UI.ACCENT[2] * 0.8, 0.1)
    noticeBar:SetFraction(0)
    notice:Show()
    self:UpdateStrip()
end

-- -- Reset --------------------------------------------------------------------------------------------

StaticPopupDialogs["CLASSICPLUS_RESPEC"] = {
    text = "Reset every talent in %s? All your points come back, free.",
    button1 = "Reset", button2 = "Cancel",
    OnAccept = function() T:SendReset() end,
    timeout = 0, whileDead = 1, hideOnEscape = 1,
}

-- Why the reset can't happen now (nil when it can).
function T:ResetBlocked()
    -- the realm answers ".wnl specs" with SP only once it has the update; an older realm
    -- ignores "respec", so no SP yet means no reset button that silently does nothing
    if not W.connected or not self.specs then
        return "Free talent resets need the realm update, and this realm hasn't got it yet."
    end
    if inCombat() then return "You can't reset talents in combat." end
    if inInstance() then return "Leave the dungeon first: talents can't be reset inside an instance." end
    if self.switching then return "Wait for the spec switch to finish." end
    if (GetNumTalentTabs and GetNumTalentTabs() or 0) > 0 and T.Spent() == 0 then
        return "You haven't spent any talent points, so there is nothing to reset."
    end
    return nil
end

function T:AskReset()
    if not active() then return end
    local why = self:ResetBlocked()
    if why then say(why) return end
    local which = self.specs and T.SpecName(self.specs.active) or "your spec"
    StaticPopup_Show("CLASSICPLUS_RESPEC", which)
end

function T:SendReset()
    local why = self:ResetBlocked()
    if why then say(why) return end
    if self.Planner then self.Planner:SeedFromActual() end   -- so Learn Plan can put it back
    if W:SendCommand("respec") then self.resetPending = GetTime() end
end

local REASONS = {
    combat = "you're in combat", instance = "you're inside an instance", dead = "you're dead",
    cooldown = "you reset not long ago", nopoints = "you haven't spent any points", disabled = "free resets are off on this realm",
}

W:RegisterModule("RS", function(body)
    local f = W.Split(body or "", ",")
    local what = strlower(W.Trim(f[1] or ""))
    T.resetPending = nil
    if what == "ok" then
        if UI.Toast and opt("resetButton") then
            UI.Toast({ icon = RESET_ICON, title = "Talents reset", text = "Every point is back. Spend them again, or learn your planned build.", color = { 0.4, 0.85, 1 }, sound = "LEVELUP" })
        end
        say("Your talents have been reset. Every point is back.")
        if TalentFrame_Update and TalentFrame and TalentFrame:IsVisible() then TalentFrame_Update() end
        if T.Planner then T.Planner:Refresh() end
    elseif what == "err" then
        local reason = W.Trim(f[2] or "")
        local nice = REASONS[strlower(reason)] or ((reason ~= "") and reason) or "the realm refused"
        say("Couldn't reset your talents: " .. nice .. ".")
    end
end)

-- -- SP: dual spec state ---------------------------------------------------------------------------

W:RegisterModule("SP", function(body)
    local recs, n = W.Split(body or "", ";")
    local head = W.Split(recs[1] or "", ",")
    local act, count = tonumber(head[1]), tonumber(head[2])
    if not act or not count then return end
    act, count = floor(act), floor(count)
    if count < 1 or act < 1 or act > count or count > 2 then return end
    local names = {}
    for i = 1, count do
        local nm = W.Trim(recs[i + 1] or "")
        if strlen(nm) > 40 then nm = strsub(nm, 1, 40) end
        names[i] = nm
    end
    local was = T.specs and T.specs.active
    T.specs = { active = act, count = count, names = names }
    local s = T.switching
    if s and act == s.to then
        T:EndSwitch(true, "Now using " .. T.SpecName(act) .. ".")
        if UI.Toast and opt("specTabs") then
            UI.Toast({ icon = ICON, title = "Spec switched", text = "Now using " .. T.SpecName(act) .. ".", color = UI.ACCENT })
        end
    elseif was and was ~= act and not s then
        say("Now using " .. T.SpecName(act) .. ".")
    end
    if T.Planner then
        if was ~= act then T.Planner:OnSpecChanged() else T.Planner:Refresh() end
    end
    if TalentFrame_Update and TalentFrame and TalentFrame:IsVisible() then TalentFrame_Update() end
    T:UpdateStrip()
end)

function T:Rename(n, name)
    name = W.Trim(string.gsub(name or "", "[;,|%c]", ""))
    if strlen(name) > NAME_MAX then name = strsub(name, 1, NAME_MAX) end
    if name == "" or not self.specs then return end
    if not W:SendCommand("specname", n .. " " .. name) then
        say("Naming specs needs the realm update.")
        return
    end
    self.specs.names[n] = name           -- the realm confirms with SP
    self:UpdateStrip()
    if self.Planner then self.Planner:Refresh() end
end

function T:AskRename(n)
    UI.Prompt({
        title = "Name " .. T.SpecName(n), text = "A short name for this spec, like Raid, PvP or Tank.",
        default = (self.specs and self.specs.names[n]) or "", maxLetters = NAME_MAX, accept = "Rename",
        onAccept = function(text) T:Rename(n, text) end,
    })
end

-- Ask the realm once telemetry is up.
function T:AskSpecs()
    if self.asked or not W.connected or not active() then return end
    self.asked = true
    self.askedAt = GetTime()
    W:SendCommand("specs")
end

-- -- PG: hunter pet command gate ------------------------------------------------------------------

local function isHunter()
    local _, class = UnitClass("player")
    return class == "HUNTER"
end

local origShowPet = ShowPetActionBar
if origShowPet then
    ShowPetActionBar = function(a1, a2)
        if T.petGated and opt("petBar") then return end
        return origShowPet(a1, a2)
    end
end
if PetActionBarFrame then
    local origOnShow = PetActionBarFrame:GetScript("OnShow")
    PetActionBarFrame:SetScript("OnShow", function()
        if origOnShow then origOnShow() end
        if T.petGated and opt("petBar") then this:Hide() end
    end)
end

function T:ApplyPetGate()
    if self.petGated and opt("petBar") then
        if HidePetActionBar then HidePetActionBar() elseif PetActionBarFrame then PetActionBarFrame:Hide() end
    elseif PetHasActionBar and PetHasActionBar() and ShowPetActionBar then
        ShowPetActionBar()
    end
end

W:RegisterModule("PG", function(body)
    if not isHunter() then return end
    local v = tonumber(W.Trim(body or ""))
    if v ~= 0 and v ~= 1 then return end
    local gated = (v == 0)
    local changed = gated ~= T.petGated
    T.petGated = gated
    T:ApplyPetGate()
    if changed and opt("petBar") then
        if gated then
            say("Your pet acts on its own for now, so its action bar is hidden.")
        else
            say("Your pet takes your commands now. Its action bar is back.")
        end
    end
end)

-- -- LL: spells learned on level up ----------------------------------------------------------------

local function spellIcon(full)
    if not (GetSpellName and GetSpellTexture) then return nil end
    local _, _, base, rank = strfind(full, "^(.-) %((.-)%)$")
    base = base or full
    for i = 1, 400 do
        local name, r = GetSpellName(i, BOOKTYPE_SPELL or "spell")
        if not name then break end
        if name == base and (not rank or r == rank) then return GetSpellTexture(i, BOOKTYPE_SPELL or "spell") end
    end
    return nil
end

W:RegisterModule("LL", function(body)
    if not opt("learnToast") then return end
    local recs, n = W.Split(body or "", ";")
    local list = {}
    for i = 1, n do
        local s = W.Trim(string.gsub(recs[i], "[|%c]", ""))
        if s ~= "" and strlen(s) <= 80 then table.insert(list, s) end
    end
    local count = getn(list)
    if count == 0 then return end
    local shown = {}
    for i = 1, math.min(3, count) do shown[i] = list[i] end
    local text = table.concat(shown, ", ")
    if count > 3 then text = text .. " and " .. (count - 3) .. " more" end
    if UI.Toast then
        UI.Toast({
            icon = spellIcon(list[1]) or "Interface\\Icons\\INV_Misc_Book_11",
            title = (count == 1) and "New spell rank" or (count .. " new spell ranks"),
            text = "Learned: " .. text, color = { 0.55, 0.85, 1 }, duration = 7,
        })
    end
    say("Learned: " .. table.concat(list, ", ") .. ".")
end)

-- -- The panel on the talent frame ---------------------------------------------------------------------

local function textButton(parent, text, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(14)
    b.label = UI.Label(b, 10, UI.ACCENT)
    b.label:SetPoint("LEFT", b, "LEFT", 0, 0)
    b.label:SetText(text)
    b:SetWidth((b.label:GetStringWidth() or 40) + 4)
    b:SetScript("OnClick", onClick)
    b:SetScript("OnEnter", function() this.label:SetTextColor(1, 1, 1) end)
    b:SetScript("OnLeave", function() this.label:SetTextColor(UI.ACCENT[1], UI.ACCENT[2], UI.ACCENT[3]) end)
    return b
end

function T:BuildStrip()
    if self.strip or not TalentFrame then return end
    local f = CreateFrame("Frame", "Talents_Strip", TalentFrame)
    self.strip = f
    UI.Themed(f, "panel")
    f:SetWidth(176)
    f:SetHeight(250)
    f:SetPoint("TOPLEFT", TalentFrame, "TOPRIGHT", -34, -14)
    f:EnableMouse(true)

    local strip = f:CreateTexture(nil, "ARTWORK")
    strip:SetPoint("TOPLEFT", f, "TOPLEFT", 3, -3)
    strip:SetPoint("TOPRIGHT", f, "TOPRIGHT", -3, -3)
    strip:SetHeight(22)
    UI.Gradient(strip, 0.21, 0.21, 0.23, 0.11, 0.11, 0.12)
    local icon = f:CreateTexture(nil, "OVERLAY")
    icon:SetWidth(14)
    icon:SetHeight(14)
    icon:SetPoint("LEFT", strip, "LEFT", 5, 0)
    if not W:Art(icon, "Talents_Icon", ICON) then icon:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
    local title = UI.Label(f, 11, { 0.95, 0.93, 0.88 }, "OUTLINE")
    title:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    title:SetText("Talents")
    -- Slick: the charcoal title strip; Classic and Brass: a gold title on the stone, like the stock frames
    UI.OnSkin(function(th)
        if th.flat then
            UI.Gradient(strip, 0.21, 0.21, 0.23, 0.11, 0.11, 0.12)
            UI.Font(title, 11, "OUTLINE")
        else
            strip:SetTexture(nil)
            UI.Font(title, 12, "")
        end
        title:SetTextColor(th.title[1], th.title[2], th.title[3])
    end)

    -- specs
    local specBox = CreateFrame("Frame", "Talents_SpecBox", f)
    specBox:SetWidth(160)
    specBox:SetHeight(104)
    specBox:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -32)
    f.specBox = specBox
    f.tabs = UI.Tabs(specBox, {
        tabs = { { key = 1, label = "Spec 1" }, { key = 2, label = "Spec 2" } },
        maxWidth = 80,
        onSelect = function(key) T.viewSpec = key T:UpdateStrip() end,
        onMenu = function(key) T:AskRename(key) end,
        skin = true,
    })
    f.tabs:SetPoint("TOPLEFT", specBox, "TOPLEFT", 0, 0)
    local body = CreateFrame("Frame", nil, specBox)
    UI.Themed(body, "inset")
    body:SetPoint("TOPLEFT", specBox, "TOPLEFT", 0, -20)
    body:SetPoint("BOTTOMRIGHT", specBox, "BOTTOMRIGHT", 0, 0)
    f.specName = UI.Label(body, 12, { 1, 1, 1 }, "OUTLINE")
    f.specName:SetPoint("TOPLEFT", body, "TOPLEFT", 8, -8)
    f.specName:SetWidth(144)
    f.specState = UI.Label(body, 10, UI.MUTED)
    f.specState:SetPoint("TOPLEFT", f.specName, "BOTTOMLEFT", 0, -3)
    f.rename = textButton(body, "Rename", function() T:AskRename(T.viewSpec or 1) end)
    f.rename:SetPoint("TOPRIGHT", body, "TOPRIGHT", -8, -9)
    f.switch = UI.Button(body, "Switch to this spec", 144, 20, function() T:Switch(T.viewSpec or 1) end)
    f.switch:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", 8, 8)
    f.switchBar = UI.Bar(body, { width = 144, height = 14 })
    f.switchBar:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", 8, 11)
    f.switchBar:SetColor(UI.ACCENT[1], UI.ACCENT[2] * 0.8, 0.1)
    f.noSpecs = UI.Label(f, 10, UI.MUTED)
    f.noSpecs:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -36)
    f.noSpecs:SetWidth(156)

    -- reset & planner
    f.reset = UI.Button(f, "Reset Talents", 160, 22, function() T:AskReset() end)
    f.reset:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -146)
    f.reset:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:SetText("Reset Talents", 1, 0.82, 0)
        local why = T:ResetBlocked()
        GameTooltip:AddLine("Every point in your active spec comes back, free. Out of combat and outside instances.", 0.85, 0.85, 0.85, 1)
        if why then GameTooltip:AddLine(why, 1, 0.45, 0.4, 1) end
        GameTooltip:Show()
    end)
    f.reset:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.resetNote = UI.Label(f, 9, UI.MUTED)
    f.resetNote:SetPoint("TOPLEFT", f.reset, "BOTTOMLEFT", 2, -4)
    f.resetNote:SetWidth(158)
    f.plan = UI.Button(f, "Talent Planner", 160, 22, function() if T.Planner then T.Planner:Toggle() end end)
    f.plan:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -206)

    f:SetScript("OnShow", function() T:AskSpecs() T:UpdateStrip() end)
    self:UpdateStrip()
end

function T:UpdateStrip()
    local f = self.strip
    if not f then return end
    if not active() then f:Hide() return end
    f:Show()
    local s = self.specs
    local showSpecs = s and opt("specTabs")
    if showSpecs then
        f.specBox:Show()
        f.noSpecs:Hide()
        local tabs = {}
        for i = 1, s.count do
            local label = T.SpecName(i)
            if i == s.active then label = "|cff40ff40*|r " .. label end
            tabs[i] = { key = i, label = label }
        end
        f.tabs:SetTabs(tabs)
        local view = self.viewSpec
        if not view or view > s.count then view = s.active end
        self.viewSpec = view
        f.tabs:Select(view, true)
        f.specName:SetText(T.SpecName(view))
        local sw = self.switching
        if view == s.active then
            f.specState:SetText("|cff40ff40Active|r  " .. T.Spent() .. " points spent")
            f.switch:Hide()
            f.switchBar:Hide()
        elseif sw and sw.to == view then
            f.specState:SetText("Switching...")
            f.switch:Hide()
            local frac = (GetTime() - sw.started) / SWITCH_TIME
            if frac > 1 then frac = 1 end
            f.switchBar:SetFraction(frac)
            f.switchBar.left:SetText(string.format("%.1f s", math.max(0, SWITCH_TIME - (GetTime() - sw.started))))
            f.switchBar:Show()
        else
            f.specState:SetText("Not active. Switching takes 5 seconds.")
            f.switch:Show()
            f.switchBar:Hide()
            if sw or inCombat() then f.switch:Disable() else f.switch:Enable() end
        end
    else
        f.specBox:Hide()
        f.noSpecs:SetText(opt("specTabs") and ((W.connected and T.askedAt and GetTime() - T.askedAt < 10) and "Asking the realm about your specs..." or "Two specs and free resets need the realm update.") or "")
        f.noSpecs:Show()
    end
    if opt("resetButton") then
        f.reset:Show()
        f.resetNote:Show()
        local why = self:ResetBlocked()
        f.resetNote:SetText(why and ("|cffff7060" .. why .. "|r") or "Free. Out of combat and outside instances.")
        if why and not (W.connected and self.specs) then f.reset:Enable() elseif why then f.reset:Disable() else f.reset:Enable() end
    else
        f.reset:Hide()
        f.resetNote:Hide()
    end
    if opt("planner") then f.plan:Show() else f.plan:Hide() end
end

-- -- Events --------------------------------------------------------------------------------------------

local ev = CreateFrame("Frame", "Talents_Events")
for _, e in ipairs({ "ADDON_LOADED", "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
    "CHARACTER_POINTS_CHANGED", "SPELLCAST_INTERRUPTED", "SPELLCAST_FAILED", "UNIT_PET", "PET_BAR_UPDATE" }) do
    ev:RegisterEvent(e)
end
ev:SetScript("OnEvent", function()
    if event == "ADDON_LOADED" then
        if strlower(arg1 or "") == "blizzard_talentui" then T:BuildStrip() end
    elseif event == "PLAYER_ENTERING_WORLD" then
        T:BuildStrip()
    elseif event == "SPELLCAST_INTERRUPTED" or event == "SPELLCAST_FAILED" then
        local s = T.switching
        if s and GetTime() - s.started < SWITCH_TIME + 0.5 then
            T:EndSwitch(false, "Spec switch interrupted.")
        end
    elseif event == "UNIT_PET" or event == "PET_BAR_UPDATE" then
        if T.petGated and opt("petBar") then T:ApplyPetGate() end
    elseif event == "CHARACTER_POINTS_CHANGED" then
        if T.Planner then T.Planner:OnPointsChanged() end
    end
    T:UpdateStrip()
end)

-- connection watch (ask for specs once telemetry is up) and the respec answer timeout
local tick = 0
ev:SetScript("OnUpdate", function()
    tick = tick + (arg1 or 0)
    if tick < 0.5 then return end
    tick = 0
    if not T.asked and W.connected then T:AskSpecs() end
    if T.resetPending and GetTime() - T.resetPending > RESET_WAIT then
        T.resetPending = nil
        say("The realm didn't answer. Free talent resets need the realm update.")
    end
end)

-- -- Registration --------------------------------------------------------------------------------------

W:RegisterSchema(ID, {
    title = "Talents - Specs & Planner",
    icon = ICON,
    desc = "Free talent resets, two specs you can name and switch between, a planner with saved builds and share codes, and a note when you learn new spell ranks.",
    defaults = { specTabs = true, resetButton = true, planner = true, learnToast = true, petBar = true },
    options = {
        { key = "specTabs", label = "Two specs", sub = "Spec tabs on the talent window, with names and a Switch button (when the realm supports it)." },
        { key = "resetButton", label = "Reset Talents button", sub = "A free reset on the talent window, out of combat and outside instances." },
        { key = "planner", label = "Talent planner", sub = "Plan a build without spending points, save it, share it as a code. /talents" },
        { key = "learnToast", label = "New spell ranks", sub = "A note and a chat line when leveling up teaches you new ranks." },
        { key = "petBar", label = "Hide the starter pet's bar", sub = "Hunters: hide the pet action bar while your first pet acts on its own." },
    },
})

W:RegisterAddon(ID, function(on)
    if not on then
        if T.strip then T.strip:Hide() end
        if T.Planner then T.Planner:Hide() end
        notice:Hide()
    end
    T:ApplyPetGate()
    T:UpdateStrip()
end)

SLASH_CPTALENTS1 = "/talents"
SLASH_CPTALENTS2 = "/spec"
SlashCmdList["CPTALENTS"] = function(msg)
    if not active() then return end
    msg = W.Trim(msg or "")
    local low = strlower(msg)
    local _, _, n = strfind(low, "^(%d)$")
    if not n then _, _, n = strfind(low, "^spec (%d)$") end
    if not n then _, _, n = strfind(low, "^switch (%d)$") end
    if n then
        if not T.specs then say("Two specs need the realm update.") return end
        T:Switch(tonumber(n))
    elseif low == "reset" then
        T:AskReset()
    elseif low == "" or low == "plan" or low == "planner" then
        if T.Planner and opt("planner") then T.Planner:Toggle() end
    elseif low == "help" then
        say("|cffffd100/talents|r planner,  |cffffd100/talents 1|r or |cffffd100/talents 2|r switch spec,  |cffffd100/talents reset|r free reset.")
    else
        say("|cffffd100/talents|r planner,  |cffffd100/talents 1|r or |cffffd100/talents 2|r switch spec,  |cffffd100/talents reset|r free reset.")
    end
end
