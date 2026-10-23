--[[
    Rooms.lua  (Duels)
    Host your own duel world (realm/mangos/0030-openvanilla-duels-rooms.patch). "Host a server" in the
    Duels window: pick the mode, best of, sudden death, betting, and who may join (anyone with the link,
    listed publicly, or with a password). You get a code and a link (duels.openvanilla.app/?room=CODE)
    to send; whoever opens it is in your room. Room members queue among themselves (Fight in my room),
    unrated, in their own copy of the arena, and the room keeps its own ladder.
      /duels room              this window       /duels room join <code> [password]
      /duels room leave        /duels rooms      the public rooms
    Server lines (WQ): room,on,<code>,<mode>,<best of>,<sd>,<bets>,<access>,<host>,<members>,<you host>
      room,off   room,joined,<name>   room,left,<name>   room,err,<why>   roominfo;<code>;<name:w:l:here>;...
      rooms;<code>,<host>,<mode>,<members>;...
    Lua 5.0 rules: no #, no %, this/arg1 in scripts.
]]--

local W = WenillaCore
local UI = W.UI
local D = Duels

local R = {}
D.Rooms = R
R.room = nil          -- the room you're in: { code, mode, bestOf, sd, bets, access, host, members, mine }
R.ladder = {}
R.SITE = "https://duels.openvanilla.app/"
R.MODES = { { "u1", "1v1" }, { "s2", "2v2" }, { "s3", "3v3" } }
R.ACCESS = { { "link", "Anyone with the link" }, { "public", "Listed publicly" }, { "password", "Password" } }
R.WHY = {
    off = "Rooms aren't on this realm.", mode = "Pick 1v1, 2v2 or 3v3.", match = "Not while you're in a match.",
    full = "All rooms are taken right now. Try again soon.", password = "That password isn't right.",
    code = "No room has that code (rooms close 30 minutes after the last player leaves).",
    roomfull = "That room is full.", none = "You're not in a room.",
}

local function send(args) return Warfront and Warfront.Send and Warfront.Send(args) end
local function say(msg) if D.Say then D.Say(msg) else W.Print(msg) end end

function R.Link(code) return R.SITE .. "?farclip=177&room=" .. (code or "") end

local win
local opts = { mode = "u1", bestOf = 3, sd = 1, bets = 0, access = "link" }

local function choiceRow(parent, y, label, choices, key)
    local l = UI.Label(parent, 10, UI.MUTED)
    l:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, y)
    l:SetText(label)
    local btns = {}
    local x = 110
    for i, c in ipairs(choices) do
        local b = UI.Button(parent, c[2], c[3] or 64, 20, function()
            opts[key] = this.value
            for _, o in ipairs(btns) do if o.value == opts[key] then o:LockHighlight() else o:UnlockHighlight() end end
            if key == "access" and parent.pw then if opts.access == "password" then parent.pw:Show() else parent.pw:Hide() end end
        end)
        b.value = c[1]
        b:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y + 4)
        x = x + (c[3] or 64) + 4
        if c[1] == opts[key] then b:LockHighlight() end
        btns[i] = b
    end
    return btns
end

function R.Build()
    if win then return win end
    win = UI.Window("DuelsRoomFrame", { width = 420, height = 330, title = "Host a server", skin = true,
        icon = "Interface\\Icons\\INV_Misc_Note_02", point = { "CENTER", UIParent, "CENTER", 0, 60 } })
    if UISpecialFrames then table.insert(UISpecialFrames, "DuelsRoomFrame") end
    win:Hide()
    -- the form (when you're not in a room)
    local f = CreateFrame("Frame", nil, win)
    f:SetAllPoints(win)
    win.form = f
    local intro = UI.Label(f, 10, UI.MUTED)
    intro:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -32)
    intro:SetWidth(392)
    intro:SetText("Your own duel world on this realm, with your rules and your ladder. Send the link to friends.")
    choiceRow(f, -62, "Mode", { { "u1", "1v1" }, { "s2", "2v2" }, { "s3", "3v3" } }, "mode")
    choiceRow(f, -90, "Best of", { { 1, "1" }, { 3, "3" }, { 5, "5" } }, "bestOf")
    choiceRow(f, -118, "Sudden death", { { 1, "On" }, { 0, "Off" } }, "sd")
    choiceRow(f, -146, "Betting", { { 0, "Off" }, { 1, "On" } }, "bets")
    choiceRow(f, -174, "Who can join", { { "link", "Link", 60 }, { "public", "Public", 60 }, { "password", "Password", 76 } }, "access")
    f.pw = UI.SearchBox(f, { name = "DuelsRoomPassword", width = 180, placeholder = "Password" })
    f.pw:SetPoint("TOPLEFT", f, "TOPLEFT", 110, -204)
    f.pw:Hide()
    f.host = UI.Button(f, "Host it", 110, 24, function() R.Host() end)
    f.host:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 12)
    f.joinBox = UI.SearchBox(f, { name = "DuelsRoomCode", width = 120, placeholder = "Room code" })
    f.joinBox:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 14, 16)
    f.join = UI.Button(f, "Join", 70, 22, function() R.Join(f.joinBox:GetText()) end)
    f.join:SetPoint("LEFT", f.joinBox, "RIGHT", 6, 0)
    -- the room (when you're in one)
    local r = CreateFrame("Frame", nil, win)
    r:SetAllPoints(win)
    win.roomPage = r
    r.head = UI.Label(r, 13, UI.ACCENT)
    r.head:SetPoint("TOPLEFT", r, "TOPLEFT", 14, -32)
    r.rules = UI.Label(r, 10, UI.MUTED)
    r.rules:SetPoint("TOPLEFT", r, "TOPLEFT", 14, -52)
    r.rules:SetWidth(392)
    r.link = UI.SearchBox(r, { name = "DuelsRoomLink", width = 392, placeholder = "" })
    r.link:SetPoint("TOPLEFT", r, "TOPLEFT", 14, -74)
    r.board = UI.Label(r, 10, UI.WHITE)
    r.board:SetPoint("TOPLEFT", r, "TOPLEFT", 14, -104)
    r.board:SetWidth(392)
    if r.board.SetJustifyH then r.board:SetJustifyH("LEFT") end
    r.fight = UI.Button(r, "Fight in my room", 140, 24, function() send("q join room") end)
    r.fight:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", 12, 12)
    r.leave = UI.Button(r, "Leave room", 100, 24, function() send("q room leave") end)
    r.leave:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", -12, 12)
    win:SetScript("OnShow", function() if R.room then send("q room info") end end)
    R.Paint()
    return win
end

function R.Paint()
    if not win then return end
    local rm = R.room
    if not rm then win.form:Show(); win.roomPage:Hide(); if win.title then win.title:SetText("Host a server") end return end
    win.form:Hide(); win.roomPage:Show()
    if win.title then win.title:SetText("Room " .. rm.code) end
    local p = win.roomPage
    p.head:SetText(rm.host .. "'s room · " .. rm.code .. (rm.mine and "  (you host)" or ""))
    local modeName = ({ u1 = "1v1", d1 = "1v1", s2 = "2v2", s3 = "3v3" })[rm.mode] or rm.mode
    p.rules:SetText(modeName .. " · best of " .. rm.bestOf .. " · sudden death " .. (rm.sd and "on" or "off") .. " · betting " ..
        (rm.bets and "on" or "off") .. " · " .. ({ link = "join by link", public = "listed publicly", password = "password" })[rm.access] ..
        " · " .. rm.members .. " here")
    p.link:SetText(R.Link(rm.code))
    local lines = {}
    for i, e in ipairs(R.ladder) do
        if i > 10 then break end
        table.insert(lines, i .. ". " .. e.name .. "   " .. e.wins .. "-" .. e.losses .. (e.here and "" or "  |cff808080(gone)|r"))
    end
    p.board:SetText(table.getn(lines) > 0 and ("|cffffd100Room ladder|r\n" .. table.concat(lines, "\n")) or "Nobody has fought here yet. Press Fight in my room.")
end

function R.Host()
    local pw = ""
    if opts.access == "password" then
        pw = W.Trim(win.form.pw:GetText() or "")
        if pw == "" or string.find(pw, " ") then say("Pick a password (one word).") return false end
    end
    send("q room host " .. opts.mode .. " " .. opts.bestOf .. " " .. opts.sd .. " " .. opts.bets .. " " .. opts.access .. (pw ~= "" and (" " .. pw) or ""))
    return true
end

function R.Join(code, pw)
    code = string.upper(W.Trim(code or ""))
    if code == "" then say("/duels room join <code>") return false end
    send("q room join " .. code .. (pw and pw ~= "" and (" " .. pw) or ""))
    return true
end

function R.Toggle()
    R.Build()
    if win:IsShown() then win:Hide() else win:Show(); R.Paint() end
end

local function after(tag, fn)
    local prev = W.modules and W.modules[tag]
    W:RegisterModule(tag, function(body)
        if prev then prev(body) end
        local ok, err = pcall(fn, body or "")
        if not ok then W.Print("|cffff4040Duels rooms:|r " .. tostring(err)) end
    end)
end

after("WQ", function(body)
    if not D.on then return end
    if string.sub(body, 1, 9) == "roominfo;" then
        local parts = W.Split(body, ";")
        R.ladder = {}
        for i = 3, table.getn(parts) do
            local f = W.Split(parts[i], ":")
            table.insert(R.ladder, { name = f[1] or "?", wins = tonumber(f[2]) or 0, losses = tonumber(f[3]) or 0, here = f[4] == "1" })
        end
        R.Paint()
        return
    end
    if string.sub(body, 1, 6) == "rooms;" or body == "rooms" then
        local parts = W.Split(body, ";")
        if table.getn(parts) <= 1 then say("No public rooms right now. Host one: /duels room") return end
        for i = 2, table.getn(parts) do
            local f = W.Split(parts[i], ",")
            say((f[1] or "?") .. "  " .. (f[2] or "?") .. "'s room, " .. (f[3] or "") .. ", " .. (f[4] or "0") .. " here  (/duels room join " .. (f[1] or "") .. ")")
        end
        return
    end
    local p = W.Split(body, ",")
    if p[1] ~= "room" then return end
    local kind = p[2]
    if kind == "on" then
        local was = R.room and R.room.code
        R.room = { code = p[3], mode = p[4], bestOf = tonumber(p[5]) or 3, sd = p[6] == "1", bets = p[7] == "1", access = p[8] or "link",
                   host = p[9] or "?", members = tonumber(p[10]) or 1, mine = p[11] == "1" }
        if was ~= R.room.code then
            say(R.room.mine and ("Your room is open: " .. R.Link(R.room.code) .. "  Send it to friends.") or ("You're in " .. R.room.host .. "'s room (" .. R.room.code .. ")."))
            R.Build(); win:Show()
            send("q room info")
        end
        R.Paint()
    elseif kind == "off" then
        R.room, R.ladder = nil, {}
        say("You left the room.")
        R.Paint()
    elseif kind == "joined" then
        say((p[3] or "Someone") .. " joined your room.")
        if R.room then R.room.members = R.room.members + 1; send("q room info") end
    elseif kind == "left" then
        say((p[3] or "Someone") .. " left the room.")
        if R.room then R.room.members = math.max(1, R.room.members - 1); R.Paint() end
    elseif kind == "err" then
        say(R.WHY[p[3] or ""] or ("Room: " .. tostring(p[3])))
    end
end)
