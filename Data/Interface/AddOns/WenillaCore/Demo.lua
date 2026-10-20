--[[
    Demo.lua
    "/wnl demo" (or the Demo Data button in /addons) plays an imitation server feed through
    the real packet handlers, so every window can be seen and placed without a raid.
    Off by default: real players never see invented numbers unless they ask for them.
]]--

local W = WenillaCore
local floor, sin = math.floor, math.sin

W.demoRunning = false
local clock, castStep, castEnd = 0, 0, 0

local ROSTER = {
    { "Brakkus", 1, 1180 }, { "Ilyndra", 8, 1395 }, { "Thessaly", 4, 1260 },
    { "Vexmoor", 9, 1120 }, { "Orlen", 3, 990 }, { "Saria", 2, 640 },
    { "Mournfell", 5, 310 }, { "Kael", 11, 820 },
}
local CASTS = {
    { "Shadow Bolt", 3000, 1, "Spell_Shadow_ShadowBolt", 0 },
    { "Arcane Missiles", 5000, 1, "Spell_Nature_StarFall", 1 },
    { "Flame Breath", 2000, 0, "Spell_Fire_Fire", 0 },
}
local GUILDS = {
    { "Ashen Vanguard", "Raiding", 55, 38, "Molten Core Tue/Thu 8pm server. Need healers and a warlock." },
    { "Stormwind Watch", "Leveling", 1, 64, "Friendly levelling guild, weekly dungeon nights." },
    { "Blood and Thunder", "PvP", 40, 22, "Battleground premades every evening." },
    { "Hearth and Home", "Social", 1, 91, "Chill social guild for all levels and time zones." },
    { "Silver Hand", "Raiding", 58, 45, "Onyxia and BWL progression, loot council." },
}

-- a fake nameplate in the middle of the screen (the design sheet's nameplate)
local anchor
local function demoPlate()
    if anchor then return anchor end
    local UI = W.UI
    anchor = CreateFrame("Frame", "Visage_DemoAnchor", UIParent)
    anchor:SetWidth(150)
    anchor:SetHeight(60)
    anchor:SetPoint("CENTER", UIParent, "CENTER", 0, 140)
    local name = anchor:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    name:SetPoint("TOP", anchor, "TOP", -12, 0)
    name:SetText("Defias Thug")
    name:SetTextColor(1, 0.25, 0.2)
    local icons = { "Spell_Nature_NullifyPoison", "Spell_Shadow_CurseOfSargeras", "Spell_Shadow_ShadowWordPain" }
    local colors = { { 0, 0.6, 0 }, { 0.6, 0, 1 }, { 0.2, 0.6, 1 } }
    anchor.timers = {}
    for i = 1, 3 do
        local d = CreateFrame("Frame", nil, anchor)
        d:SetWidth(20)
        d:SetHeight(20)
        d:SetPoint("TOPLEFT", anchor, "TOPLEFT", 14 + (i - 1) * 24, -14)
        local bg = d:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(d)
        bg:SetTexture(colors[i][1], colors[i][2], colors[i][3], 1)
        local ic = d:CreateTexture(nil, "ARTWORK")
        ic:SetPoint("TOPLEFT", d, "TOPLEFT", 1, -1)
        ic:SetPoint("BOTTOMRIGHT", d, "BOTTOMRIGHT", -1, 1)
        ic:SetTexture("Interface\\Icons\\" .. icons[i])
        ic:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        local t = d:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        UI.Font(t, 9, "OUTLINE")
        t:SetPoint("BOTTOM", d, "BOTTOM", 0, -1)
        anchor.timers[i] = t
    end
    local case = anchor:CreateTexture(nil, "BACKGROUND")
    case:SetPoint("TOPLEFT", anchor, "TOPLEFT", 6, -38)
    case:SetWidth(112)
    case:SetHeight(14)
    case:SetTexture(0.02, 0.02, 0.03, 0.9)
    local hb = CreateFrame("StatusBar", nil, anchor)
    hb:SetPoint("TOPLEFT", case, "TOPLEFT", 2, -2)
    hb:SetPoint("BOTTOMRIGHT", case, "BOTTOMRIGHT", -2, 2)
    hb:SetStatusBarTexture(UI.BAR)
    hb:SetStatusBarColor(0.12, 0.80, 0.22)
    hb:SetMinMaxValues(0, 100)
    anchor.hp = hb
    local hpText = hb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    UI.Font(hpText, 8, "OUTLINE")
    hpText:SetPoint("LEFT", hb, "LEFT", 3, 0)
    local lvl = anchor:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lvl:SetPoint("LEFT", case, "RIGHT", 4, 0)
    lvl:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    lvl:SetTextColor(1, 0.82, 0, 1)
    lvl:SetShadowOffset(1, -1)
    lvl:SetShadowColor(0, 0, 0, 1)
    lvl:SetText("1")
    return anchor
end

local function enc(rows)
    return table.concat(rows, ";")
end

function W:EmitDemoTick()
    if not self.demoRunning or self.isVanillaMode then return end
    local t = clock
    -- Chronicle: everyone's total grows with a little wobble per player
    local rows = {}
    for i, r in ipairs(ROSTER) do
        local per = r[3] * (0.9 + 0.12 * sin(t / 5 + i))
        local total = floor(per * (t + 1))
        table.insert(rows, r[1] .. "," .. r[2] .. "," .. total .. "," .. floor(per))
    end
    self:Dispatch("CH", enc(rows))

    -- Vanguard: a mage creeping up on the tank, you somewhere behind
    local me = UnitName("player") or "You"
    local mage = floor(72 + 40 * (0.5 + 0.5 * sin(t / 4)))
    local you = floor(55 + 25 * (0.5 + 0.5 * sin(t / 7 + 1)))
    local list = { { "Brakkus", 100, 1 }, { "Ilyndra", mage, 0 }, { me, you, 0 } }
    table.sort(list, function(a, b) return a[2] > b[2] end)
    local rank = 0
    local body = "Ragnaros"
    for i, e in ipairs(list) do
        body = body .. ";" .. e[1] .. "," .. e[2] .. "," .. e[3]
        if e[1] == me then rank = i end
    end
    self:Dispatch("VG", body .. ";S," .. rank .. "," .. you .. ",110")

    -- Castline: a cast every few seconds on your target (or a demo caster)
    local caster = UnitName("target") or "Onyxia"
    if t >= castEnd then
        castStep = castStep + 1
        local c = CASTS[castStep - floor((castStep - 1) / 3) * 3]
        self:Dispatch("CL", "target," .. caster .. "," .. c[1] .. "," .. c[2] .. "," .. c[3] .. "," .. c[4] .. "," .. c[5])
        castEnd = t + c[2] / 1000 + 1.5
        if castStep - floor(castStep / 4) * 4 == 0 and c[3] == 1 then
            self.demoKick = t + c[2] / 2000
        end
    end
    if self.demoKick and t >= self.demoKick then
        self.demoKick = nil
        self:Dispatch("CL", "stop,target," .. caster .. ",1")
    end

    -- Compass: pins around wherever you stand, like the design sheet
    local px, py = GetPlayerMapPosition("player")
    if px and (px > 0 or py > 0) then
        local pins = {}
        local spec = { { 175, "TURNIN", "WANTED: Hogger" }, { 190, "OBJ", "The Jasperlode Mine" },
            { 210, "TURNIN", "Bounty on Murlocs" }, { 295, "GIVER", "Marshal Dughan" }, { 315, "GIVER", "Smith Argus" } }
        for i, s in ipairs(spec) do
            local a = math.rad(s[1])
            table.insert(pins, (100 + i) .. "," .. string.format("%.4f", px + math.cos(a) * 0.08) .. ","
                .. string.format("%.4f", py - math.sin(a) * 0.08) .. "," .. s[2] .. "," .. s[3])
        end
        self:Dispatch("CP", enc(pins))
    end

    -- Visage demo plate
    local a = demoPlate()
    if W:IsActive("Plates") then a:Show() else a:Hide() end
    a.hp:SetValue(100 - (t * 3 - floor(t * 3 / 100) * 100))
    for i = 1, 3 do
        local period = 4 * i + 4
        local left = period - (t - floor(t / period) * period)
        a.timers[i]:SetText(math.ceil(left) .. "s")
    end

    -- Concord and Ledger only need filling once
    if not self.demoSeeded then
        self.demoSeeded = true
        local recs = {}
        for _, g in ipairs(GUILDS) do
            table.insert(recs, "L~" .. g[1] .. "~" .. g[2] .. "~" .. g[3] .. "~" .. g[4] .. "~" .. g[5])
        end
        self:Dispatch("CO", enc(recs))
        local prices = {}
        for bag = 0, 4 do
            for slot = 1, (GetContainerNumSlots(bag) or 0) do
                local _, _, id = string.find(GetContainerItemLink(bag, slot) or "", "item:(%d+)")
                if id then
                    local n = tonumber(id)
                    self.demoPriceIds = self.demoPriceIds or {}
                    self.demoPriceIds[n] = true
                    table.insert(prices, id .. "," .. (n * 37 - floor(n * 37 / 90000) * 90000 + 120) .. "," .. (n - floor(n / 900) * 900 + 5) .. ",42")
                end
            end
        end
        if prices[1] then self:Dispatch("LG", enc(prices)) end
        if Rally and Rally.StartPull and W:IsActive("Raid") then Rally:StartPull(10) end
    end
end

local driver = CreateFrame("Frame", "WenillaCore_DemoFrame")
driver:Hide()
local acc = 0
driver:SetScript("OnUpdate", function()
    clock = clock + arg1
    acc = acc + arg1
    if acc >= 0.5 then
        acc = 0
        W:EmitDemoTick()
    end
end)

function W:StartDemoStream(quiet)
    if self.isVanillaMode then return end
    self.demoRunning = true
    self.demoSeeded = false
    clock, castStep, castEnd = 0, 0, 0
    if WenillaCore_Config then WenillaCore_Config.demoMode = true end
    if Chronicle then Chronicle.userClosed = nil end
    if Vanguard then Vanguard.userClosed = nil end
    W:RefreshAll()
    driver:Show()
    self:EmitDemoTick()
    if not quiet then W.Print("demo data |cff40ff40on|r - every window shows imitation telemetry. |cffffd100/wnl demo|r again to stop.") end
    if self.UpdateManagerUI then self:UpdateManagerUI() end
end

function W:StopDemoStream(quiet)
    local was = self.demoRunning
    self.demoRunning = false
    driver:Hide()
    if WenillaCore_Config then WenillaCore_Config.demoMode = false end
    if was then
        self.isVanillaMode, self.wasVanilla = false, self.isVanillaMode
        self:Dispatch("VG", "-")
        self:Dispatch("CP", "")
        self:Dispatch("CL", "stop,target," .. (UnitName("target") or "Onyxia") .. ",0")
        self.isVanillaMode = self.wasVanilla
        if Chronicle then Chronicle.server = nil; Chronicle.dirty = true end
        if Concord then
            for k, l in pairs(Concord.listings) do if not l.poster then Concord.listings[k] = nil end end
        end
        if Ledger and self.demoPriceIds then
            for id in pairs(self.demoPriceIds) do
                Ledger.prices[id] = nil
                if Ledger.asked then Ledger.asked[id] = nil end
            end
            self.demoPriceIds = nil
        end
    end
    if anchor then anchor:Hide() end
    if was and not quiet then W.Print("demo data |cffff4040off|r.") end
    if self.UpdateManagerUI then self:UpdateManagerUI() end
end

function W:ToggleDemoStream()
    if self.demoRunning then self:StopDemoStream() else self:StartDemoStream() end
end
