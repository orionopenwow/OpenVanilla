--[[
    Bet.lua  (Duels)
    Betting in Duel Gold (realm/mangos/0027-openvanilla-duels-betting.patch; art pass 3a, window C):
      * the bet window: the two fighters, the pool on each side and what a win pays, 5/25/50/100 gold,
        Place, and how long bets stay open (until round one starts). It opens from Bet in the Duels panel
        while you watch a fight, or "/duels bet <fight number>" (the numbers are in "/duels fights").
      * the stake window, when a rated duel pops: offer No stake / 10 / 25 / 50; when both offer the same,
        it is taken from both and the winner gets both.
      * your Duel Gold, in the Duels panel and after every bet.
    Duel Gold is earned (a prize for each rated win, topped back up each day) and won; it can't be bought.
    Lua 5.0 rules: no #, no %, this/arg1 in scripts.
]]--

local W = WenillaCore
local UI = W.UI
local D = Duels

local B = {}
D.Bet = B
B.wallet = nil        -- Duel Gold, as the realm last said
B.CHIPS = { 5, 25, 50, 100 }
B.STAKES = { 0, 10, 25, 50 }
B.WHY = {
    off = "Betting is off on this realm.", gone = "That fight is over.", unrated = "Only rated duels take bets.",
    closed = "Bets closed: round one has started.", bad = "Pick a side and an amount.", match = "Not while you're in a match.",
    self = "Not on a fight of your own account.", address = "Not on a fight from your own network.",
    already = "You already bet on this fight.", max = "That's more than one bet may be.", daily = "That's today's betting done.",
    gold = "Not enough Duel Gold.", nomatch = "Stakes are for your own match.",
}

local win, stakeWin
local function send(args) return D and D.Send and D.Send(args) or (Warfront and Warfront.Send and Warfront.Send(args)) end
local function say(msg) if D.Say then D.Say(msg) else W.Print(msg) end end

-- what a bet on `side` pays per gold, from the pools (the losing side's burn of 5 by default)
function B.Pays(p0, p1, side, burn)
    burn = burn or 5
    local mine, theirs = side == 0 and p0 or p1, side == 0 and p1 or p0
    if mine <= 0 then return nil end
    return (mine + theirs * (100 - burn) / 100) / mine
end

local function fmtPays(x) if not x then return "-" end return "x" .. string.format("%.2f", x) end

function B.Build()
    if win then return win end
    win = UI.Window("DuelsBetFrame", { width = 340, height = 250, title = "Bet on this fight", skin = true,
        icon = "Interface\\Icons\\INV_Misc_Coin_02", point = { "CENTER", UIParent, "CENTER", 0, 80 } })
    if UISpecialFrames then table.insert(UISpecialFrames, "DuelsBetFrame") end
    win:Hide()
    win.sides = {}
    for i = 0, 1 do
        local b = CreateFrame("Button", nil, win)
        b:SetWidth(150); b:SetHeight(46)
        b:SetPoint("TOPLEFT", win, "TOPLEFT", 14 + i * 162, -34)
        UI.Skin(b, "inset")
        b.name = UI.Label(b, 12, UI.WHITE)
        b.name:SetPoint("TOP", b, "TOP", 0, -6)
        b.pays = UI.Label(b, 11, UI.ACCENT)
        b.pays:SetPoint("BOTTOM", b, "BOTTOM", 0, 6)
        b.side = i
        b:SetScript("OnClick", function() B.side = this.side; B.Paint() end)
        win.sides[i] = b
    end
    win.pool = UI.Label(win, 10, UI.MUTED)
    win.pool:SetPoint("TOPLEFT", win, "TOPLEFT", 14, -88)
    win.chips = {}
    for i, n in ipairs(B.CHIPS) do
        local c = UI.Button(win, n .. "g", 60, 20, function() B.amount = this.amount; B.Paint() end)
        c.amount = n
        c:SetPoint("TOPLEFT", win, "TOPLEFT", 14 + (i - 1) * 66, -110)
        win.chips[i] = c
    end
    win.wallet = UI.Label(win, 10, UI.MUTED)
    win.wallet:SetPoint("TOPLEFT", win, "TOPLEFT", 14, -142)
    win.closes = UI.Label(win, 10, UI.WHITE)
    win.closes:SetPoint("TOPRIGHT", win, "TOPRIGHT", -14, -142)
    win.status = UI.Label(win, 10, { 1, 0.55, 0.45 })
    win.status:SetPoint("TOPLEFT", win, "TOPLEFT", 14, -162)
    win.status:SetWidth(310)
    win.place = UI.Button(win, "Place bet", 110, 22, function() B.Place() end)
    win.place:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -12, 34)
    win.rules = UI.Label(win, 9, UI.MUTED)
    win.rules:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", 14, 12)
    win.rules:SetWidth(310)
    win.rules:SetText("The winners share the pool; 5% of the losing side is burned. No bets on your own fight.")
    win:SetScript("OnUpdate", function()
        this.t = (this.t or 0) + arg1
        if this.t < 2 then return end
        this.t = 0
        if B.match then send("q pool " .. B.match) end
    end)
    return win
end

-- open the bet window on fight `id` (names "Name (Class 1500)")
function B.Open(id, a, b)
    B.Build()
    B.match = tostring(id)
    B.names = { [0] = a or "Fighter 1", [1] = b or "Fighter 2" }
    B.side, B.amount, B.pool, B.mine = nil, 25, nil, nil
    win.status:SetText("")
    win:Show()
    send("q pool " .. B.match)
    send("q wallet")
    B.Paint()
end

function B.Paint()
    if not win then return end
    local p = B.pool or { 0, 0, false, 0 }
    for i = 0, 1 do
        local s = win.sides[i]
        s.name:SetText(B.names and B.names[i] or "")
        -- what a win would pay, counting the bet you're about to place
        local add = (B.side == i and not B.mine) and (B.amount or 0) or 0
        local p0, p1 = p[1] + (i == 0 and add or 0), p[2] + (i == 1 and add or 0)
        s.pays:SetText("pays " .. fmtPays(B.Pays(p0, p1, i)))
        if B.side == i then s:LockHighlight() else s:UnlockHighlight() end
    end
    win.pool:SetText("Pool " .. p[1] .. "g  |  " .. p[2] .. "g")
    for _, c in ipairs(win.chips) do if c.amount == B.amount then c:LockHighlight() else c:UnlockHighlight() end end
    win.wallet:SetText("Duel Gold: " .. (B.wallet and (B.wallet .. "g") or "?"))
    if B.mine then
        win.closes:SetText("Your bet: " .. B.mine[2] .. "g on " .. (B.names[B.mine[1]] or "?"))
        win.place:Disable()
    elseif p[3] then
        win.closes:SetText("Closes in " .. p[4] .. " s")
        win.place:Enable()
    else
        win.closes:SetText("Bets closed")
        win.place:Disable()
    end
end

function B.Place()
    if not B.match then return false end
    if not B.side then win.status:SetText("Click the fighter you're betting on.") return false end
    send("q bet " .. B.match .. " " .. B.side .. " " .. (B.amount or 25))
    win.status:SetText("Placing...")
    return true
end

-- -- the stake window (your own rated duel) -------------------------------------------------------

function B.BuildStake()
    if stakeWin then return stakeWin end
    stakeWin = UI.Window("DuelsStakeFrame", { width = 300, height = 140, title = "Match found: stake?", skin = true,
        icon = "Interface\\Icons\\INV_Misc_Coin_01", point = { "CENTER", UIParent, "CENTER", 0, 160 } })
    stakeWin:Hide()
    stakeWin.info = UI.Label(stakeWin, 10, UI.MUTED)
    stakeWin.info:SetPoint("TOP", stakeWin, "TOP", 0, -32)
    stakeWin.info:SetText("Both stake the same, winner takes both.")
    stakeWin.chips = {}
    for i, n in ipairs(B.STAKES) do
        local c = UI.Button(stakeWin, n == 0 and "No stake" or (n .. "g"), 64, 20, function() send("q stake " .. this.amount); B.offered = this.amount end)
        c.amount = n
        c:SetPoint("TOPLEFT", stakeWin, "TOPLEFT", 12 + (i - 1) * 70, -54)
        stakeWin.chips[i] = c
    end
    stakeWin.state = UI.Label(stakeWin, 10, UI.WHITE)
    stakeWin.state:SetPoint("TOP", stakeWin, "TOP", 0, -86)
    stakeWin.state:SetWidth(276)
    return stakeWin
end

-- -- the realm's lines ------------------------------------------------------------------------------

local function after(tag, fn)
    local prev = W.modules and W.modules[tag]
    W:RegisterModule(tag, function(body)
        if prev then prev(body) end
        local ok, err = pcall(fn, body or "")
        if not ok then W.Print("|cffff4040Duels bet:|r " .. tostring(err)) end
    end)
end

after("WQ", function(body)
    if not D.on then return end
    local p = W.Split(body, ",")
    local what = p[1]
    if what == "wallet" then
        B.wallet = tonumber(p[2])
        if D.Refresh then D:Refresh() end
        B.Paint()
    elseif what == "pool" then
        if p[2] ~= B.match then return end
        B.pool = { tonumber(p[3]) or 0, tonumber(p[4]) or 0, p[5] == "1", tonumber(p[6]) or 0 }
        local side = tonumber(p[7])
        if side and side >= 0 then B.mine = { side, tonumber(p[8]) or 0 } end
        B.Paint()
    elseif what == "bet" then
        local kind = p[2]
        if kind == "ok" then
            B.mine = { tonumber(p[4]), tonumber(p[5]) }
            B.wallet = tonumber(p[6]) or B.wallet
            if win then win.status:SetText("") end
            say("Bet placed: " .. (p[5] or "?") .. " Duel Gold. Wallet " .. (B.wallet or "?") .. "g.")
            B.Paint()
        elseif kind == "err" then
            if win then win.status:SetText(B.WHY[p[3] or ""] or ("Refused (" .. tostring(p[3]) .. ").")) end
        elseif kind == "won" or kind == "lost" or kind == "back" then
            B.wallet = tonumber(p[5]) or B.wallet
            local msg = kind == "won" and ("Your bet won: +" .. p[4] .. " Duel Gold!")
                or (kind == "lost" and ("Your bet lost (" .. p[4] .. "g).") or ("Your bet came back (" .. p[4] .. "g)."))
            say(msg .. " Wallet " .. (B.wallet or "?") .. "g.")
            if UI.Toast and kind == "won" then UI.Toast({ icon = "Interface\\Icons\\INV_Misc_Coin_02", title = "Bet won", text = "+" .. p[4] .. " Duel Gold" }) end
            if D.Refresh then D:Refresh() end
        end
    elseif what == "stake" then
        local kind = p[2]
        B.BuildStake()
        if kind == "offer" then
            local mine, theirs = tonumber(p[3]) or 0, tonumber(p[4]) or 0
            stakeWin.state:SetText("You: " .. (mine > 0 and (mine .. "g") or "no stake") .. "   They: " .. (theirs > 0 and (theirs .. "g") or "no stake")
                .. ((mine > 0 and mine == theirs) and "   |cff40ff60= on|r" or ""))
        elseif kind == "on" then
            stakeWin:Hide()
            say("Stake on: " .. p[3] .. " Duel Gold each. The winner takes " .. ((tonumber(p[3]) or 0) * 2) .. ".")
        elseif kind == "off" then
            stakeWin:Hide()
            say("No stake this time (the offers didn't match).")
        elseif kind == "won" then say("You won the stake: +" .. p[3] .. " Duel Gold.")
        elseif kind == "lost" then say("You lost the stake (" .. p[3] .. "g).")
        elseif kind == "back" then say("The stake came back (" .. p[3] .. "g).")
        elseif kind == "err" then stakeWin.state:SetText(B.WHY[p[3] or ""] or "Refused.") end
    elseif what == "pop" then
        if p[2] == "d1" then
            B.BuildStake()
            stakeWin.state:SetText("")
            stakeWin:Show()
        end
    elseif what == "go" or what == "end" or what == "left" then
        if stakeWin then stakeWin:Hide() end
    elseif what == "unwatch" then
        if win then win:Hide() end
        B.match = nil
    end
end)

-- Duel Gold a few seconds after the Duels realm says hello (not in the same burst as the panel's own asks)
local ask = CreateFrame("Frame")
ask:SetScript("OnUpdate", function()
    if not D.on then this.t = nil return end
    if D.lite then this.t = nil return end      -- the bare arena has no Duel Gold
    if B.wallet then this:Hide() return end
    this.t = (this.t or 0) + arg1
    if this.t >= 3 then this.t = -27; send("q wallet") end     -- again every 30 s until it answers
end)

-- Bet from the Duels panel while watching
function B.FromWatch()
    local w = D.watching
    if not w then say("Watch a fight first (Watch a fight), or /duels bet <fight number> from /duels fights.") return false end
    B.Open(w.id, w.a, w.b)
    return true
end
