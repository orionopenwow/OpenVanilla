--[[
    Raid.lua  -  Rally
    Group coordination for parties and raids: one-click raid markers, a ready check with a
    live status board, and a pull countdown everyone in the group sees.

    Group members talk over the client's addon channel (prefix "WNLR", party or raid), so it
    works on any realm; members without Classic+ simply show as "no reply".
        P:<sec>         start a pull countdown        PC     cancel it
        C:<id>          ready check started            R:<id>:<1|0>  reply
    The server can drive the same UI with "RL" packets: "pull,<sec>" / "check,<id>".
]]--

local W = WenillaCore
local UI = W.UI
local ID = "Raid"
local PREFIX = "WNLR"

Rally = Rally or {}
local R = Rally
R.status = {}      -- name -> true (ready) | false (not ready) | nil (waiting)
R.check = nil      -- { id, from, started }

-- The bundled "Raid" stub set SLASH_RAID2 = "/rally", which turned /rally into raid chat
-- and took /ra away from it. Give /ra back and keep the stub's handler out of the way.
if SLASH_RAID2 == "/rally" then SLASH_RAID2 = "/ra" end
SlashCmdList["RAID"] = nil

local function channel()
    if (GetNumRaidMembers and GetNumRaidMembers() or 0) > 0 then return "RAID" end
    if (GetNumPartyMembers and GetNumPartyMembers() or 0) > 0 then return "PARTY" end
end

local function send(msg)
    local ch = channel()
    if ch and SendAddonMessage then
        SendAddonMessage(PREFIX, msg, ch)
        return true
    end
end

local function members()
    local list = {}
    local raid = GetNumRaidMembers and GetNumRaidMembers() or 0
    if raid > 0 then
        for i = 1, raid do
            local name, _, _, _, _, class = GetRaidRosterInfo(i)
            if name then table.insert(list, { name = name, class = class }) end
        end
    else
        local _, c = UnitClass("player")
        table.insert(list, { name = UnitName("player"), class = c })
        for i = 1, (GetNumPartyMembers and GetNumPartyMembers() or 0) do
            local _, pc = UnitClass("party" .. i)
            local n = UnitName("party" .. i)
            if n then table.insert(list, { name = n, class = pc }) end
        end
    end
    return list
end

-- -- Board window --------------------------------------------------------------

local WIDTH, ROWS = 214, 10

local frame = UI.Window("Rally_Frame", {
    width = WIDTH, height = 120, title = "Raid",
    icon = "Interface\\Icons\\Ability_DualWield",
    point = { "TOPLEFT", UIParent, "TOPLEFT", 20, -110 }, skin = true,
})
frame:Hide()

-- raid target markers
local markers = {}
for i = 1, 8 do
    local m = CreateFrame("Button", nil, frame)
    m:SetWidth(20)
    m:SetHeight(20)
    m:SetPoint("TOPLEFT", frame, "TOPLEFT", 10 + (i - 1) * 24.5, -29)
    local t = m:CreateTexture(nil, "ARTWORK")
    t:SetAllPoints(m)
    t:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")
    local col = math.mod and math.mod(i - 1, 4) or math.fmod(i - 1, 4)
    local row = math.floor((i - 1) / 4)
    t:SetTexCoord(col * 0.25, col * 0.25 + 0.25, row * 0.25, row * 0.25 + 0.25)
    m:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
    m:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    m:SetScript("OnClick", function()
        if not UnitExists("target") or not SetRaidTarget then return end
        if arg1 == "RightButton" then SetRaidTarget("target", 0) else SetRaidTarget("target", i) end
    end)
    m:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_TOP")
        GameTooltip:SetText("Mark your target")
        GameTooltip:AddLine("Right-click to clear the mark.", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    m:SetScript("OnLeave", function() GameTooltip:Hide() end)
    markers[i] = m
end

local rule = frame:CreateTexture(nil, "ARTWORK")
rule:SetTexture(0.30, 0.30, 0.34, 1)
rule:SetHeight(1)
rule:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, -54)
rule:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -6, -54)

local summary = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
summary:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -60)

local rows = {}
for i = 1, ROWS do
    local r = CreateFrame("Frame", nil, frame)
    r:SetHeight(15)
    r:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -76 - (i - 1) * 16)
    r:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -10, -76 - (i - 1) * 16)
    local name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    name:SetPoint("LEFT", r, "LEFT", 0, 0)
    local state = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    state:SetPoint("RIGHT", r, "RIGHT", -18, 0)
    local check = r:CreateTexture(nil, "OVERLAY")
    check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
    check:SetWidth(16)
    check:SetHeight(16)
    check:SetPoint("RIGHT", r, "RIGHT", 2, 0)
    r.name, r.state, r.check = name, state, check
    r:Hide()
    rows[i] = r
end

local btnCheck = UI.Button(frame, "Ready Check", 96, 20, function() R:StartCheck() end)
local btnPull = UI.Button(frame, "Pull 10", 96, 20, function()
    R:Pull(tonumber(W:Setting(ID, "defaultPull", 10)) or 10)
end)

function R:Render()
    local list = members()
    local s = W:Settings(ID)
    local ready, total = 0, table.getn(list)
    local shown = 0
    for i = 1, ROWS do
        local row, m = rows[i], list[i]
        if m and s.showPoll ~= false then
            shown = i
            local cr, cg, cb = UI.ClassColor(m.class)
            row.name:SetText(m.name)
            row.name:SetTextColor(cr, cg, cb)
            local st = self.status[m.name]
            if not self.check then
                row.state:SetText("")
                row.check:Hide()
            elseif st == true then
                ready = ready + 1
                row.state:SetText("|cff40ff40Ready|r")
                row.check:SetVertexColor(0.3, 1, 0.3)
                row.check:Show()
            elseif st == false then
                row.state:SetText("|cffff4040Not ready|r")
                row.check:Hide()
            else
                local late = GetTime() - self.check.started > 30
                row.state:SetText(late and "|cff808080no reply|r" or "|cffbbbbbb...|r")
                row.check:Hide()
            end
            row:Show()
        else
            row:Hide()
        end
    end
    if self.check then
        summary:SetText("Status check  " .. ready .. "/" .. total .. " ready")
    else
        summary:SetText(total > 1 and (total .. " in group") or "Not in a group")
    end
    local y = -76 - shown * 16 - 6
    btnCheck:ClearAllPoints()
    btnCheck:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, y)
    btnPull:ClearAllPoints()
    btnPull:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, y)
    btnPull:SetText("Pull " .. (tonumber(s.defaultPull) or 10))
    frame:SetHeight(-y + 28)
end

-- -- Ready check ---------------------------------------------------------------

local prompt = UI.Window("Rally_Prompt", {
    width = 230, height = 78, title = "Ready Check", icon = "Interface\\Icons\\Ability_DualWield",
    point = { "TOP", UIParent, "TOP", 0, -170 }, strata = "DIALOG", skin = true,
})
prompt:Hide()
local promptText = prompt:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
promptText:SetPoint("TOP", prompt, "TOP", 0, -32)
local function answer(ok)
    prompt:Hide()
    if R.check then
        R.status[UnitName("player")] = ok
        send("R:" .. R.check.id .. ":" .. (ok and "1" or "0"))
        R:Render()
    end
end
local yes = UI.Button(prompt, "Ready", 96, 20, function() answer(true) end)
yes:SetPoint("BOTTOMLEFT", prompt, "BOTTOMLEFT", 10, 9)
local no = UI.Button(prompt, "Not Ready", 96, 20, function() answer(false) end)
no:SetPoint("BOTTOMRIGHT", prompt, "BOTTOMRIGHT", -10, 9)

function R:BeginCheck(id, from)
    self.check = { id = id, from = from, started = GetTime() }
    self.status = {}
    if from == UnitName("player") then
        self.status[from] = true
    else
        promptText:SetText(from .. " is checking if everyone is ready.")
        prompt:Show()
        if W:Setting(ID, "soundAlert", true) then PlaySoundFile("Sound\\Interface\\ReadyCheck.wav") end
    end
    if W:IsActive(ID) and W:Setting(ID, "showPoll", true) then frame:Show() end
    self:Render()
end

function R:StartCheck()
    local id = tostring(math.floor(GetTime() * 10))
    if not send("C:" .. id) then
        W.Print("Raid: join a party or raid to run a ready check.")
        return
    end
end

-- -- Pull countdown ------------------------------------------------------------

local pull = CreateFrame("Frame", "Rally_PullBar", UIParent)
pull:SetWidth(260)
pull:SetHeight(26)
pull:SetPoint("TOP", UIParent, "TOP", 0, -200)
pull:SetBackdrop(UI.BACKDROP)
pull:SetBackdropColor(0.06, 0.06, 0.07, 0.94)
pull:SetBackdropBorderColor(0.62, 0.62, 0.66, 1)
pull:SetFrameStrata("HIGH")
pull:Hide()
local pullBar = CreateFrame("StatusBar", nil, pull)
pullBar:SetPoint("TOPLEFT", pull, "TOPLEFT", 4, -4)
pullBar:SetPoint("BOTTOMRIGHT", pull, "BOTTOMRIGHT", -4, 4)
pullBar:SetStatusBarTexture(UI.BAR)
pullBar:SetStatusBarColor(0.85, 0.32, 0.10)
local pullText = pullBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
pullText:SetPoint("CENTER", pullBar, "CENTER", 0, 0)

R.pullEnd, R.pullLen, R.lastTick = 0, 0, nil

function R:StartPull(sec, from)
    sec = tonumber(sec) or 10
    if sec <= 0 then
        self.pullEnd = 0
        pull:Hide()
        return
    end
    self.pullEnd, self.pullLen, self.lastTick = GetTime() + sec, sec, nil
    pullBar:SetMinMaxValues(0, sec)
    if W:IsActive(ID) then pull:Show() end
    if from and from ~= UnitName("player") then W.Print("Raid: " .. from .. " started a " .. sec .. "s pull timer.") end
end

function R:Pull(sec)
    if not send("P:" .. sec) then self:StartPull(sec) end
end

pull:SetScript("OnUpdate", function()
    local left = R.pullEnd - GetTime()
    if left > 0 then
        pullBar:SetValue(left)
        pullText:SetText(string.format("Pull in %.1f", left))
        local whole = math.ceil(left)
        if whole <= 3 and whole ~= R.lastTick then
            R.lastTick = whole
            if W:Setting(ID, "soundAlert", true) then PlaySound("igMainMenuOptionCheckBoxOn") end
        end
    elseif left > -2 then
        pullBar:SetValue(0)
        pullText:SetText("|cffff3020PULL!|r")
        if R.lastTick ~= 0 then
            R.lastTick = 0
            if W:Setting(ID, "soundAlert", true) then PlaySoundFile("Sound\\Interface\\RaidWarning.wav") end
        end
    else
        this:Hide()
    end
end)

-- -- Messages ------------------------------------------------------------------

local ev = CreateFrame("Frame", "Rally_Events")
ev:RegisterEvent("CHAT_MSG_ADDON")
ev:RegisterEvent("PARTY_MEMBERS_CHANGED")
ev:RegisterEvent("RAID_ROSTER_UPDATE")
ev:SetScript("OnEvent", function()
    if event ~= "CHAT_MSG_ADDON" then
        if frame:IsShown() then R:Render() end
        return
    end
    if arg1 ~= PREFIX or not W:IsActive(ID) then return end
    local msg, from = arg2 or "", arg4 or "?"
    local f = W.Split(msg, ":")
    if f[1] == "P" then
        R:StartPull(f[2], from)
    elseif f[1] == "PC" then
        R:StartPull(0)
    elseif f[1] == "C" then
        R:BeginCheck(f[2], from)
    elseif f[1] == "R" and R.check and R.check.id == f[2] then
        R.status[from] = f[3] == "1"
        R:Render()
    end
end)

local tick = CreateFrame("Frame")
local acc = 0
tick:SetScript("OnUpdate", function()
    acc = acc + arg1
    if acc > 1 and frame:IsShown() and R.check then
        acc = 0
        R:Render()
    end
end)

W:RegisterModule("RL", function(body)
    local f = W.Split(body, ",")
    if f[1] == "pull" then R:StartPull(f[2], W.SERVER_SENDER)
    elseif f[1] == "check" then R:BeginCheck(f[2] or "srv", f[3] or W.SERVER_SENDER) end
end)

W:RegisterAddon(ID, function(active)
    if not active then
        frame:Hide()
        pull:Hide()
        prompt:Hide()
    elseif frame:IsShown() then
        R:Render()
    end
end)

SLASH_RALLYPULL1 = "/pull"
SlashCmdList["RALLYPULL"] = function(msg)
    if not W:IsActive(ID) then W.Print("Raid is switched off. Turn it on in /addons.") return end
    R:Pull(tonumber(W.Trim(msg)) or tonumber(W:Setting(ID, "defaultPull", 10)) or 10)
end

SLASH_RALLY1 = "/rally"
SlashCmdList["RALLY"] = function(msg)
    if not W:IsActive(ID) then W.Print("Raid is switched off. Turn it on in /addons.") return end
    msg = string.lower(W.Trim(msg))
    local _, _, sec = string.find(msg, "^pull%s*(%d*)")
    if sec then
        R:Pull(tonumber(sec) or tonumber(W:Setting(ID, "defaultPull", 10)) or 10)
    elseif tonumber(msg) then
        R:Pull(tonumber(msg))           -- "/rally 15"
    elseif msg == "check" or msg == "ready" then
        R:StartCheck()
    elseif msg == "cancel" then
        if not send("PC") then R:StartPull(0) end
    else
        if frame:IsShown() then frame:Hide() else R:Render() frame:Show() end
    end
end
