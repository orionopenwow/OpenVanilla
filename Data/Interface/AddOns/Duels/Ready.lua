--[[
    Ready.lua  (Duels)
    The accept window when a match is found (realm/mangos/0031-openvanilla-duels-accept.patch). Nobody is
    queued by themselves: you press a button, the realm pools you with the others in that queue, and when
    a match forms everyone in it gets this window. Accept, all of you, and you go to your own copy of the
    arena. If someone declines or doesn't answer in time, whoever accepted goes back into the queue where
    they were.
      WQ ready,<mode>,<match>,<seconds>   the window          ready,count,<match>,<yes>,<of>
      WQ ready,go,<match>   ready,back,<match>   ready,missed,<match>   ready,gone
    Lua 5.0 rules: no #, no %, this/arg1 in scripts.
]]--

local W = WenillaCore
local UI = W.UI
local D = Duels

local RD = {}
D.Ready = RD
RD.LABEL = { d1 = "Rated duel", u1 = "Practice duel", s2 = "2v2", s3 = "3v3" }

local function send(args) return Warfront and Warfront.Send and Warfront.Send(args) end
local function say(msg) if D.Say then D.Say(msg) else W.Print(msg) end end

local win
function RD.Build()
    if win then return win end
    win = UI.Window("DuelsReadyFrame", { width = 300, height = 150, title = "Match found", skin = true, close = false,
        icon = "Interface\\Icons\\Ability_Dualwield", point = { "TOP", UIParent, "TOP", 0, -150 }, strata = "DIALOG" })
    win:Hide()
    win.what = UI.Label(win, 14, UI.ACCENT)
    win.what:SetPoint("TOP", win, "TOP", 0, -34)
    win.note = UI.Label(win, 10, UI.MUTED)
    win.note:SetPoint("TOP", win.what, "BOTTOM", 0, -4)
    win.bar = UI.Bar(win, { width = 268, height = 10 })
    win.bar:SetPoint("TOP", win, "TOP", 0, -76)
    win.accept = UI.Button(win, "Accept", 120, 24, function() RD.Answer(true) end)
    win.accept:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", 16, 14)
    win.decline = UI.Button(win, "Decline", 120, 24, function() RD.Answer(false) end)
    win.decline:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -16, 14)
    win:SetScript("OnUpdate", function()
        if not RD.ends then return end
        local left = RD.ends - GetTime()
        if left < 0 then left = 0 end
        win.bar.bar:SetValue(left / (RD.total or 30))
        win.title:SetText("Match found  " .. math.ceil(left) .. "s")
    end)
    return win
end

function RD.Show(mode, id, secs)
    RD.Build()
    RD.id, RD.mode, RD.answered = id, mode, nil
    RD.total = tonumber(secs) or 30
    RD.ends = GetTime() + RD.total
    win.what:SetText(RD.LABEL[mode] or "Duel")
    win.note:SetText("Your own arena once everyone is in.")
    win.accept:Enable(); win.decline:Enable()
    win:Show()
    if PlaySound then PlaySound("PVPTHROUGHQUEUE") end
end

function RD.Answer(yes)
    if not RD.id then return end
    RD.answered = yes
    send("q " .. (yes and "accept " or "decline ") .. RD.id)
    if yes then
        win.accept:Disable()
        win.note:SetText("You're in. Waiting for the others...")
    else
        win:Hide()
        RD.id, RD.ends = nil, nil
        D.mode = nil
        if D.Refresh then D:Refresh() end
    end
end

function RD.Hide()
    if win then win:Hide() end
    RD.id, RD.ends = nil, nil
end

local function after(tag, fn)
    local prev = W.modules and W.modules[tag]
    W:RegisterModule(tag, function(body)
        if prev then prev(body) end
        local ok, err = pcall(fn, body or "")
        if not ok then W.Print("|cffff4040Duels ready:|r " .. tostring(err)) end
    end)
end

after("WQ", function(body)
    if not D.on then return end
    local p = W.Split(body, ",")
    if p[1] ~= "ready" then return end
    local kind = p[2]
    if kind == "go" then
        RD.Hide()
    elseif kind == "back" then
        RD.Hide()
        say("Someone didn't accept. You're back in the queue, where you were.")
    elseif kind == "missed" then
        RD.Hide()
        D.mode = nil
        if D.Refresh then D:Refresh() end
        say(RD.answered == false and "You declined the match." or "The match wasn't accepted in time. You're out of the queue: press a button to queue again.")
    elseif kind == "gone" then
        RD.Hide()
    elseif kind == "count" then
        if win and win:IsShown() and p[3] == RD.id then
            win.note:SetText((RD.answered and "You're in. " or "") .. (p[4] or "0") .. " of " .. (p[5] or "?") .. " ready")
        end
    elseif RD.LABEL[kind] then
        D.mode = nil
        RD.Show(kind, p[3], p[4])
        if D.Refresh then D:Refresh() end
    end
end)
