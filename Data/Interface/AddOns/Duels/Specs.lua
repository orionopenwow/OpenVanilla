--[[
    Specs.lua  (Duels)
    Every class's three specs, one per talent tree, a click apart (realm patch 0034: OpenVanilla.Specs=3,
    .Templates=1, .SwitchSeconds=0). A row of spec buttons on the Duels window; the realm swaps the
    talents (a spec never used gets its tree's PvP build, points spent for you), each spec keeps its own
    bars, and here the spec's gear set goes on and, the first time, its bars are laid out at the best
    ranks.
      SN <spec>,<fresh>   just switched (fresh 1: a spec never used, no bars of its own yet)
      /duels spec <1-3 or name>
    The switch itself is the Talents addon's (ClassicPlusTalents:Switch; SP lines).
    Lua 5.0 rules: no #, no %, this/arg1 in scripts.
]]--

local W = WenillaCore
local UI = W.UI
local D = Duels

local SP = {}
D.Specs = SP

local function say(msg) if D.Say then D.Say(msg) else W.Print(msg) end end
local function talents() return ClassicPlusTalents end

function SP.Count()
    local T = talents()
    return T and T.specs and T.specs.count or 0
end

function SP.Switch(n)
    local T = talents()
    if not T or not T.specs then say("Your specs are on their way from the realm. Try again in a moment.") return false end
    n = tonumber(n)
    if not n then return false end
    if T.Switch then T:Switch(n) end
    return true
end

-- a number, or a spec's name ("fury", "Frost")
function SP.Find(arg)
    local n = tonumber(arg or "")
    if n then return n end
    local T = talents()
    local want = string.lower(W.Trim(arg or ""))
    if want == "" or not T or not T.specs then return nil end
    for i = 1, T.specs.count do
        if string.find(string.lower(T.SpecName(i)), want, 1, 1) then return i end
    end
    return nil
end

-- the row of buttons on the Duels window, under Host a server
function SP.Build()
    local win = DuelsFrame
    if not win or SP.row then return SP.row end
    local row = CreateFrame("Frame", "DuelsSpecRow", win)
    row:SetWidth(272); row:SetHeight(40)
    if D.lite and win.gear then row:SetPoint("TOPLEFT", win.gear, "BOTTOMLEFT", 0, -10)
    elseif win.host then row:SetPoint("TOPLEFT", win.host, "BOTTOMLEFT", 0, -8) else row:SetPoint("BOTTOM", win, "BOTTOM", 0, 40) end
    row.label = UI.Label(row, 10, UI.MUTED)
    row.label:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    row.label:SetText("Specialization")
    row.buttons = {}
    for i = 1, 3 do
        local b = UI.Button(row, "Spec " .. i, 88, 20, function() SP.Switch(this.spec) end)
        b.spec = i
        b:SetPoint("TOPLEFT", row, "TOPLEFT", (i - 1) * 92, -14)
        row.buttons[i] = b
    end
    SP.row = row
    SP.Paint()
    return row
end

function SP.Paint()
    local row = SP.row
    if not row then return end
    local T = talents()
    local s = T and T.specs
    if not s or s.count < 2 then row:Hide() return end
    row:Show()
    for i = 1, 3 do
        local b = row.buttons[i]
        if i <= s.count then
            b:SetText((i == s.active and "|cff40ff40" or "") .. T.SpecName(i) .. (i == s.active and "|r" or ""))
            if i == s.active then b:LockHighlight() else b:UnlockHighlight() end
            b:Show()
        else
            b:Hide()
        end
    end
end

-- SN: the spec's gear set on; the first time, its bars laid out (its own bars are kept after that)
local function after(tag, fn)
    local prev = W.modules and W.modules[tag]
    W:RegisterModule(tag, function(body)
        if prev then prev(body) end
        local ok, err = pcall(fn, body or "")
        if not ok then W.Print("|cffff4040Duels specs:|r " .. tostring(err)) end
    end)
end

SP.pending = nil
after("SN", function(body)
    if not D.on then return end
    local p = W.Split(body, ",")
    SP.pending = { spec = tonumber(p[1]), fresh = p[2] == "1", at = GetTime() + 0.5 }
end)

-- the SP line with the new spec's name comes with SN; act a moment later, when both are in
local tick = CreateFrame("Frame")
tick:SetScript("OnUpdate", function()
    this.t = (this.t or 0) + (arg1 or 0)
    if this.t > 0.5 then this.t = 0; SP.Build(); SP.Paint() end
    local p = SP.pending
    if not p or GetTime() < p.at then return end
    SP.pending = nil
    if p.fresh and D.LayOutBars then
        local n = D.LayOutBars(true)
        if n > 0 then say("Your " .. (talents() and talents().SpecName(p.spec) or "new") .. " bars are ready: " .. n .. " abilities placed.") end
    end
    if D.UpgradeRanks then D.UpgradeRanks() end
    if D.Armory and D.Armory.BestKit then D.Armory.BestKit() end
end)
