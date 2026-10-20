--[[
    Extras.lua  -  the "Achievement Earned" banner, the tracker, the unit menu entry, slash
    commands and the addon's registration with the suite.

    Tracker: up to five achievements with their progress, in a block of its own just under the
    Quests objective tracker (Compass_Tracker), which has no way yet to host another addon's
    lines. Any tracker can draw the same list instead: Achievements.Tracked(),
    Achievements.OnTrackedChanged(fn) and Achievements.UseExternalTracker(true) to hide ours.
]]--

local W = WenillaCore
local UI = W.UI
local A = Achievements
local ID = "Achievements"

local strlower, strfind = string.lower, string.find
local tinsert, tremove, getn = table.insert, table.remove, table.getn
local floor = math.floor

local function S(key, default) return W:Setting(ID, key, default) end

A.SOUND = "Sound\\Interface\\LevelUp.wav"

-- -- "Achievement Earned" banner ----------------------------------------------------------------

local TOAST_TIME, FADE, SHINE_TIME = 5, 0.6, 0.9
local toast
local queue = {}

local function buildToast()
    if toast then return toast end
    local t = CreateFrame("Button", "Achievements_Toast", UIParent)
    t:SetWidth(320)
    t:SetHeight(80)
    t:SetPoint("TOP", UIParent, "TOP", 0, -150)
    t:SetFrameStrata("HIGH")
    t:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    t.bg = t:CreateTexture(nil, "BACKGROUND")
    t.bg:SetAllPoints(t)
    t.hasArt = W:Art(t.bg, "Ach_Toast", nil)
    if not t.hasArt then
        UI.Skin(t, "raised")
        t.bg:SetTexture(0.12, 0.10, 0.05, 0.6)
    end
    t.iconBox = UI.IconBox(t, 40)
    t.iconBox:SetPoint("LEFT", t, "LEFT", 26, -2)
    t.head = UI.Label(t, 10, UI.ACCENT, "OUTLINE")
    t.head:SetPoint("TOP", t, "TOP", 0, -14)
    t.head:SetJustifyH("CENTER")
    t.name = UI.Label(t, 13, { 1, 1, 1 }, "OUTLINE")
    t.name:SetPoint("TOP", t.head, "BOTTOM", 4, -5)
    t.name:SetWidth(190)
    t.name:SetJustifyH("CENTER")
    t.shield = t:CreateTexture(nil, "ARTWORK")
    t.shield:SetWidth(34)
    t.shield:SetHeight(34)
    t.shield:SetPoint("RIGHT", t, "RIGHT", -24, -2)
    if not W:Art(t.shield, "Ach_ShieldSmall", nil) then t.shield:SetTexture(0.55, 0.42, 0.10, 1) end
    t.points = UI.Label(t, 12, { 1, 1, 1 }, "OUTLINE", "OVERLAY")
    t.points:SetPoint("CENTER", t.shield, "CENTER", 0, 1)
    t.points:SetJustifyH("CENTER")
    t.shine = t:CreateTexture(nil, "OVERLAY")
    t.shine:SetWidth(80)
    t.shine:SetHeight(76)
    if W:Art(t.shine, "Ach_Shine", nil) then
        t.shine:SetBlendMode("ADD")
    else
        t.shine:Hide()
        t.noShine = true
    end
    t:SetScript("OnClick", function()
        local a = t.a
        t:Hide()
        if arg1 ~= "RightButton" and a then A.ShowAchievement(a.id) end
    end)
    t:SetScript("OnUpdate", function()
        t.age = (t.age or 0) + (arg1 or 0)
        if not t.noShine then
            local k = t.age / SHINE_TIME
            if k <= 1 then
                t.shine:ClearAllPoints()
                t.shine:SetPoint("CENTER", t, "LEFT", -40 + k * 400, 0)
                t.shine:SetAlpha(1 - k * 0.4)
                t.shine:Show()
            else
                t.shine:Hide()
            end
        end
        if t.age > TOAST_TIME then
            t:Hide()
        elseif t.age > TOAST_TIME - FADE then
            t:SetAlpha((TOAST_TIME - t.age) / FADE)
        else
            t:SetAlpha(1)
        end
    end)
    t:SetScript("OnHide", function()
        t.a = nil
        if queue[1] then
            local nxt = tremove(queue, 1)
            A.ShowToast(nxt.a, nxt.head)
        end
    end)
    t:Hide()
    toast = t
    A.toastFrame = t
    return t
end

-- Show the banner for an achievement (queued behind one already showing).
function A.ShowToast(a, head)
    local t = buildToast()
    if not t.hasArt then
        -- no banner art: the suite's own toast
        UI.Toast({ icon = a.i, title = head or "Achievement Earned", text = a.n .. ((a.p or 0) > 0 and ("  (" .. a.p .. " points)") or ""),
            sound = nil, duration = TOAST_TIME, onClick = function() A.ShowAchievement(a.id) end })
        A.lastToast = a
        return
    end
    if t:IsShown() and t.a then
        tinsert(queue, { a = a, head = head })
        return
    end
    t.a = a
    t.age = 0
    t.iconBox.icon:SetTexture(a.i)
    t.head:SetText(head or "Achievement Earned")
    t.name:SetText(a.n)
    if (a.p or 0) > 0 then
        t.points:SetText(a.p)
        t.shield:Show()
    else
        t.points:SetText("")
        t.shield:Hide()
    end
    t:SetAlpha(1)
    t:Show()
    A.lastToast = a
end

A.OnEarned = function(a)
    if not W:IsActive(ID) then return end
    W.Print("You earned |cffffd100" .. (A.LinkText(a.id) or a.n) .. "|r" .. ((a.p or 0) > 0 and (" (" .. a.p .. " points)") or "") .. "!")
    if S("toasts", true) then
        A.ShowToast(a)
        if PlaySoundFile then PlaySoundFile(A.SOUND) end
    end
    if S("announceGuild", false) and IsInGuild and IsInGuild() then
        SendChatMessage("I just earned " .. A.LinkText(a.id) .. "!", "GUILD")
    end
end

A.OnRealmFirst = function(a, rf)
    if not W:IsActive(ID) or not rf then return end
    if rf.name == UnitName("player") then return end      -- our own comes as "earned"
    if S("realmFirstToasts", true) then
        UI.Toast({ icon = a.i, title = "Realm First!", text = rf.name .. ": " .. a.n, duration = 6,
            onClick = function() A.ShowAchievement(a.id) end })
    end
end

A.OnCompare = function(cmp)
    W.Print("Comparing achievements with " .. cmp.name .. " (" .. A.Commas(cmp.points or 0) .. " points).")
    if not (A.window and A.window:IsShown()) then A.ShowCategory(A.view.cat) else A.RefreshWindow() end
end

-- -- Tracker ----------------------------------------------------------------------------------

local tracker
local LINE_H = 28
local TRACK_W = 232      -- as wide as the Quests tracker, which it sits under

-- Under the Quests objective tracker when that is showing (until the player drags ours).
local function placeTracker(f)
    local saved = WenillaCore_Config and WenillaCore_Config.positions and WenillaCore_Config.positions.Achievements_Tracker
    if saved or f.moved then return end
    f:ClearAllPoints()
    if Compass_Tracker and Compass_Tracker:IsShown() then
        f:SetPoint("TOPRIGHT", Compass_Tracker, "BOTTOMRIGHT", 0, -6)
    else
        f:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -26, -262)
    end
end

local function buildTracker()
    if tracker then return tracker end
    local f = CreateFrame("Frame", "Achievements_Tracker", UIParent)
    f:SetWidth(TRACK_W)
    f:SetHeight(24)
    f:SetFrameStrata("LOW")
    f:SetBackdrop(UI.THIN)
    f:SetBackdropColor(0.03, 0.035, 0.045, 0.55)
    f:SetBackdropBorderColor(UI.EDGE[1], UI.EDGE[2], UI.EDGE[3], 0.45)
    if f.SetClampedToScreen then f:SetClampedToScreen(true) end
    f.defaultPoint = { "TOPRIGHT", UIParent, "TOPRIGHT", -26, -262 }
    f:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -26, -262)
    f:SetMovable(true)
    f:EnableMouse(true)
    f.title = CreateFrame("Button", nil, f)
    f.title:SetWidth(TRACK_W - 8)
    f.title:SetHeight(16)
    f.title:SetPoint("TOPLEFT", f, "TOPLEFT", 4, -3)
    f.title:RegisterForDrag("LeftButton")
    f.title:SetScript("OnDragStart", function() f:StartMoving() end)
    f.title:SetScript("OnDragStop", function() f:StopMovingOrSizing(); W:SavePosition(f); f.moved = true end)
    f.title:SetScript("OnClick", function() A.Toggle() end)
    f.label = UI.Label(f.title, 11, UI.ACCENT, "OUTLINE")
    f.label:SetPoint("LEFT", f.title, "LEFT", 2, 0)
    f.label:SetText("Achievements")
    f.lines = {}
    for i = 1, A.MAX_TRACKED do
        local l = CreateFrame("Button", "Achievements_TrackerLine" .. i, f)
        l:SetWidth(TRACK_W - 8)
        l:SetHeight(LINE_H)
        l:SetPoint("TOPLEFT", f, "TOPLEFT", 4, -20 - (i - 1) * LINE_H)
        l:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        l.name = UI.Label(l, 10, { 1, 1, 1 }, "OUTLINE")
        l.name:SetPoint("TOPLEFT", l, "TOPLEFT", 6, 0)
        l.name:SetWidth(TRACK_W - 20)
        l.bar = UI.Bar(l, { width = TRACK_W - 30, height = 10 })
        l.bar:SetPoint("TOPLEFT", l, "TOPLEFT", 8, -13)
        l.bar:SetColor(0.22, 0.62, 0.20)
        UI.Font(l.bar.right, 9, "OUTLINE")
        l.bar.right:ClearAllPoints()
        l.bar.right:SetPoint("CENTER", l.bar, "CENTER", 0, 0)
        l.text = UI.Label(l, 9, UI.MUTED)
        l.text:SetPoint("TOPLEFT", l, "TOPLEFT", 8, -13)
        l.text:SetWidth(TRACK_W - 24)
        l:SetScript("OnClick", function()
            if not l.id then return end
            if arg1 == "RightButton" then A.Untrack(l.id)
            elseif IsShiftKeyDown and IsShiftKeyDown() then A.Link(l.id)
            else A.ShowAchievement(l.id) end
        end)
        l:SetScript("OnEnter", function() if l.id then A.ShowTooltip(l, A.byId[l.id]) end end)
        l:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
        f.lines[i] = l
    end
    W:TrackPosition(f)
    tracker = f
    A.tracker = f
    return f
end

function A.RefreshTracker()
    local items = A.Tracked()
    if not W:IsActive(ID) or not S("showTracker", true) or A.externalTracker or not items[1] then
        if tracker then tracker:Hide() end
        return
    end
    local f = buildTracker()
    for i, l in ipairs(f.lines) do
        local it = items[i]
        if it then
            l.id = it.id
            l.name:SetText(it.name)
            if it.value and it.goal then
                l.bar:SetFraction(it.goal > 0 and it.value / it.goal or 0)
                l.bar.right:SetText(it.text)
                l.bar:Show()
                l.text:Hide()
            else
                l.bar:Hide()
                l.text:SetText(it.text)
                l.text:Show()
            end
            l:Show()
        else
            l.id = nil
            l:Hide()
        end
    end
    f:SetHeight(24 + getn(items) * LINE_H)
    placeTracker(f)
    f:Show()
end

A.OnTrackedChanged(function() A.RefreshTracker() end)

-- -- Unit menus: "Compare Achievements" ----------------------------------------------------------

if UnitPopupButtons and UnitPopupMenus then
    UnitPopupButtons["ACHIEVEMENTS_COMPARE"] = { text = "Compare Achievements", dist = 0 }
    for _, menu in ipairs({ "PLAYER", "PARTY", "RAID", "RAID_PLAYER", "FRIEND" }) do
        local m = UnitPopupMenus[menu]
        if m then
            local n = getn(m)
            if m[n] == "CANCEL" then tinsert(m, n, "ACHIEVEMENTS_COMPARE") else tinsert(m, "ACHIEVEMENTS_COMPARE") end
        end
    end
    local orig = UnitPopup_OnClick
    UnitPopup_OnClick = function()
        if this and this.value == "ACHIEVEMENTS_COMPARE" then
            local dd = UIDROPDOWNMENU_INIT_MENU and getglobal(UIDROPDOWNMENU_INIT_MENU)
            local name = (dd and dd.name) or (dd and dd.unit and UnitName(dd.unit))
            if name then A.Compare(name) end
            return
        end
        if orig then return orig() end
    end
end

-- -- Slash commands ---------------------------------------------------------------------------

local CAT_WORDS = { pvp = "pvp", feats = "feats", feat = "feats" }

SLASH_ACHIEVEMENTS1 = "/ach"
SLASH_ACHIEVEMENTS2 = "/achievements"
SLASH_ACHIEVEMENTS3 = "/achieve"
SlashCmdList["ACHIEVEMENTS"] = function(msg)
    msg = W.Trim(msg or "")
    local low = strlower(msg)
    if not W:IsActive(ID) then W.Print("Achievements is switched off. Turn it on in /addons.") return end
    local _, _, cmd, rest = strfind(low, "^(%S+)%s*(.*)$")
    local _, _, _, restRaw = strfind(msg, "^(%S+)%s*(.*)$")
    if msg == "" then return A.Toggle() end
    if cmd == "compare" or cmd == "inspect" then
        return A.Compare(restRaw or "")
    elseif cmd == "stop" then
        return A.StopCompare()
    elseif cmd == "list" or cmd == "sync" then
        if A.RequestList(true) then
            W.Print("Achievements: asking the realm for your achievements.")
        else
            W.Print("Achievements: not connected to an Open Vanilla realm.")
        end
        return
    elseif cmd == "points" or cmd == "status" then
        local e, t = A.CategoryStats(nil)
        W.Print("Achievements: " .. A.Commas(A.Points()) .. " points, " .. e .. " of " .. t .. " earned.")
        return
    elseif cmd == "summary" then
        return A.ShowCategory("summary")
    elseif cmd == "help" then
        W.Print("/ach  the window (or press Y)  |  /ach compare Name  |  /ach points  |  /ach list  (ask the realm again)")
        return
    end
    -- "/ach raids", "/ach pvp": open a category by name
    local want = CAT_WORDS[low] or low
    for _, c in ipairs(A.data.categories) do
        if c.key == want or strlower(c.name) == want then return A.ShowCategory(c.key) end
    end
    W.Print("/ach  the window (or press Y)  |  /ach compare Name  |  /ach points  |  /ach list  (ask the realm again)")
end

-- -- Registration -----------------------------------------------------------------------------

W:RegisterSchema(ID, {
    title = "Achievements",
    icon = "Interface\\Icons\\INV_Crown_01",
    desc = "Achievements kept by the realm, so they can't be faked: points and recognition, never power. Press Y or type /ach. Compare with anyone from their right-click menu.",
    defaults = { toasts = true, announceGuild = false, realmFirstToasts = true, showTracker = true, persona = true },
    options = {
        { key = "toasts", label = "Banner when earned", sub = "Show a banner and play a sound when you earn an achievement." },
        { key = "announceGuild", label = "Tell my guild", sub = "Say in guild chat when you earn one." },
        { key = "realmFirstToasts", label = "Realm firsts", sub = "A banner when anyone on the realm claims a realm first." },
        { key = "showTracker", label = "Tracker", sub = "Show tracked achievements on screen (up to five)." },
        { key = "persona", label = "Share with Persona", sub = "Let your profile show your points and a featured achievement." },
    },
})

W:RegisterAddon(ID, function(active)
    if not active then
        if A.window then A.window:Hide() end
        if toast then toast:Hide() end
        for i = getn(queue), 1, -1 do tremove(queue, i) end
    end
    A.RefreshTracker()
end)
