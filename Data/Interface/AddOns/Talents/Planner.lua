--[[
    Planner.lua
    Plan a talent build without spending a point. All three trees side by side; left-click a
    talent to plan a point, right-click to take a planned point off. The usual rules apply
    (5 points per tier in that tree, the talent an arrow points from must be full, 51 points).
    Your real ranks show in white, planned points in green. Each spec has its own plan.

    Learn Plan spends your unspent points on the plan (one talent per server answer). Builds can
    be saved by name (per class, shared by your characters) and shared as a short code, written
    like the talent calculators do: "hunter/0505-0335-5" (one digit per talent, tree by tree).
]]--

local W = WenillaCore
local UI = W.UI
local T = ClassicPlusTalents
local ID = "Talents"

local P = {}
T.Planner = P

local floor, strfind, strlower, strsub, strlen = math.floor, string.find, string.lower, string.sub, string.len
local getn = table.getn

local MAX_POINTS = 51
local BTN, CELL_X, CELL_Y = 30, 36, 38
local TREE_W = 4 * CELL_X + 6
local WIDTH = 3 * TREE_W + 2 * 8 + 20
local GRID_TOP = -84

local function active() return W:IsActive(ID) and W:Setting(ID, "planner", true) end
local say = T.Say

-- -- Talent data -----------------------------------------------------------------------------------

-- trees[t] = { name, icon, file, n, talents[i] = { name, icon, tier, col, rank, max, req = i or nil } }
function P:ReadTrees()
    local trees = {}
    for t = 1, (GetNumTalentTabs and GetNumTalentTabs() or 0) do
        local name, icon, _, file = GetTalentTabInfo(t)
        local tree = { name = name or ("Tree " .. t), icon = icon, file = file, talents = {}, pos = {} }
        local n = GetNumTalents(t) or 0
        for i = 1, n do
            local tname, ticon, tier, col, rank, max = GetTalentInfo(t, i)
            tree.talents[i] = { name = tname or "?", icon = ticon, tier = tier or 1, col = col or 1, rank = rank or 0, max = max or 1 }
            tree.pos[(tier or 1) .. ":" .. (col or 1)] = i
        end
        for i = 1, n do
            if GetTalentPrereqs then
                local rt, rc = GetTalentPrereqs(t, i)
                if rt and rc then tree.talents[i].req = tree.pos[rt .. ":" .. rc] end
            end
        end
        tree.n = n
        trees[t] = tree
    end
    self.trees = trees
    return trees
end

local function classToken()
    local _, c = UnitClass("player")
    return c or "UNKNOWN"
end

-- -- The plan: target ranks per talent ------------------------------------------------------------------

-- Which spec's plan is open (the active spec unless you pick the other one).
function P:Spec()
    local s = T.specs
    if not s then return 1 end
    if self.spec and self.spec <= s.count then return self.spec end
    return s.active
end

-- True when the plan on screen belongs to the spec whose real ranks we can read.
function P:IsLive()
    local s = T.specs
    return not s or self:Spec() == s.active
end

function P:Actual(t, i)
    if not self:IsLive() then return 0 end
    local x = self.trees[t] and self.trees[t].talents[i]
    return x and x.rank or 0
end

function P:Target(t, i)
    return (self.target[t] and self.target[t][i]) or 0
end

-- What the build has: your real rank or the plan's, whichever is higher.
function P:Rank(t, i)
    local a, p = self:Actual(t, i), self:Target(t, i)
    if a > p then return a end
    return p
end

function P:TreePoints(t, belowTier)
    local n = 0
    local tree = self.trees[t]
    if not tree then return 0 end
    for i = 1, tree.n do
        if not belowTier or tree.talents[i].tier < belowTier then n = n + self:Rank(t, i) end
    end
    return n
end

function P:Total()
    local n = 0
    for t = 1, getn(self.trees) do n = n + self:TreePoints(t) end
    return n
end

function P:Planned()
    local n = 0
    for t = 1, getn(self.trees) do
        for i = 1, self.trees[t].n do
            local extra = self:Rank(t, i) - self:Actual(t, i)
            if extra > 0 then n = n + extra end
        end
    end
    return n
end

-- Can a point go here? (nil, or why not)
function P:CanAdd(t, i)
    local x = self.trees[t].talents[i]
    if self:Rank(t, i) >= x.max then return "Already at its highest rank." end
    if self:Total() >= MAX_POINTS then return "All 51 points are planned." end
    local need = (x.tier - 1) * 5
    if self:TreePoints(t, x.tier) < need then
        return "Needs " .. need .. " points in " .. self.trees[t].name .. " first."
    end
    if x.req then
        local r = self.trees[t].talents[x.req]
        if self:Rank(t, x.req) < r.max then return "Needs " .. r.max .. " points in " .. r.name .. " first." end
    end
    return nil
end

-- Can a planned point come off? (nil, or why not)
function P:CanRemove(t, i)
    if self:Target(t, i) <= self:Actual(t, i) then
        if self:Actual(t, i) > 0 then return "That point is already learned. Reset your talents to take it back." end
        return "No planned points here."
    end
    -- everything above must still have its 5 points per tier, and nothing may hang off it
    local x = self.trees[t].talents[i]
    self.target[t][i] = self.target[t][i] - 1
    local why
    local tree = self.trees[t]
    for j = 1, tree.n do
        local y = tree.talents[j]
        if self:Rank(t, j) > 0 then
            if y.tier > x.tier and self:TreePoints(t, y.tier) < (y.tier - 1) * 5 then
                why = y.name .. " needs the points in the tiers below it."
            end
            if y.req == i and self:Rank(t, i) < x.max then why = y.name .. " needs every point in " .. x.name .. "." end
        end
    end
    self.target[t][i] = self.target[t][i] + 1
    return why
end

function P:Add(t, i)
    local why = self:CanAdd(t, i)
    if why then self:Hint(why) return false end
    self.target[t] = self.target[t] or {}
    self.target[t][i] = self:Rank(t, i) + 1
    self:Save()
    self:Render()
    return true
end

function P:Remove(t, i)
    local why = self:CanRemove(t, i)
    if why then self:Hint(why) return false end
    self.target[t][i] = self.target[t][i] - 1
    self:Save()
    self:Render()
    return true
end

function P:Clear()
    self.target = {}
    self:Save()
    self:Render()
end

-- -- Codes ---------------------------------------------------------------------------------------------

function P:Encode()
    local parts = {}
    for t = 1, getn(self.trees) do
        local s = ""
        for i = 1, self.trees[t].n do s = s .. self:Rank(t, i) end
        s = string.gsub(s, "0+$", "")
        parts[t] = s
    end
    local last = getn(parts)
    while last > 0 and parts[last] == "" do last = last - 1 end
    local body = table.concat(parts, "-", 1, math.max(last, 1))
    if last == 0 then body = "" end
    return strlower(classToken()) .. "/" .. body
end

-- Parse a code into target ranks; returns the table, or nil and why.
function P:Decode(code)
    code = W.Trim(code or "")
    local _, _, cls, rest = strfind(code, "^(%a+)/(.*)$")
    if cls then
        if strlower(cls) ~= strlower(classToken()) then
            return nil, "That build is for a " .. cls .. "."
        end
        code = rest
    end
    if strfind(code, "[^%d%-]") then return nil, "A build code has only digits and dashes." end
    local trees = W.Split(code, "-")
    if getn(trees) > getn(self.trees) then return nil, "That code has too many trees." end
    local target = {}
    local total = 0
    for t = 1, getn(self.trees) do
        target[t] = {}
        local s = trees[t] or ""
        if strlen(s) > self.trees[t].n then return nil, "That code doesn't fit your talents." end
        for i = 1, strlen(s) do
            local r = tonumber(strsub(s, i, i))
            if r > self.trees[t].talents[i].max then return nil, "That code doesn't fit your talents." end
            target[t][i] = r
            total = total + r
        end
    end
    if total > MAX_POINTS then return nil, "That build uses more than 51 points." end
    -- legal? replay the rules on the whole build
    local saved = self.target
    self.target = target
    local live = self.IsLive
    self.IsLive = function() return false end
    local bad
    for t = 1, getn(self.trees) do
        for i = 1, self.trees[t].n do
            local x = self.trees[t].talents[i]
            if (target[t][i] or 0) > 0 then
                if self:TreePoints(t, x.tier) < (x.tier - 1) * 5 then bad = x.name end
                if x.req and (target[t][x.req] or 0) < self.trees[t].talents[x.req].max then bad = x.name end
            end
        end
    end
    self.IsLive = live
    self.target = saved
    if bad then return nil, "That build breaks the talent rules at " .. bad .. "." end
    return target
end

-- -- Saving --------------------------------------------------------------------------------------------

function P:Save()
    local d = T.DB()
    local key = T.CharKey()
    d.plans[key] = d.plans[key] or {}
    local s = ""
    for t = 1, getn(self.trees) do
        for i = 1, self.trees[t].n do
            local p = self:Target(t, i)
            if p > 0 then s = s .. t .. "." .. i .. "." .. p .. " " end
        end
    end
    d.plans[key][self:Spec()] = s
end

function P:Load()
    local d = T.DB()
    local plan = d.plans[T.CharKey()] and d.plans[T.CharKey()][self:Spec()]
    self.target = {}
    if not plan and self:IsLive() then
        -- no plan yet: start from the build you have, so a reset can be learned back
        self:SeedFromActual()
        return
    end
    for t, i, r in string.gfind(plan or "", "(%d+)%.(%d+)%.(%d+)") do
        t, i, r = tonumber(t), tonumber(i), tonumber(r)
        self.target[t] = self.target[t] or {}
        self.target[t][i] = r
    end
end

-- Make your current build the plan of the active spec when it has none (Reset Talents does this
-- first, so Learn Plan can put the build back afterwards).
function P:SeedFromActual()
    local d = T.DB()
    local key = T.CharKey()
    local spec = T.specs and T.specs.active or 1
    if d.plans[key] and d.plans[key][spec] then return end
    if not self.trees[1] then self:ReadTrees() end
    local was, wasSpec = self.target, self.spec
    self.spec = spec
    self.target = {}
    for t = 1, getn(self.trees) do
        for i = 1, self.trees[t].n do
            local r = self.trees[t].talents[i].rank
            if r > 0 then
                self.target[t] = self.target[t] or {}
                self.target[t][i] = r
            end
        end
    end
    self:Save()
    if wasSpec ~= nil and wasSpec ~= spec then self.target, self.spec = was, wasSpec end
end

function P:Builds()
    local d = T.DB()
    local c = classToken()
    d.builds[c] = d.builds[c] or {}
    return d.builds[c]
end

function P:SaveBuild(name)
    name = W.Trim(string.gsub(name or "", "[|%c]", ""))
    if name == "" then return end
    local list = self:Builds()
    local code = self:Encode()
    for _, b in ipairs(list) do
        if strlower(b.name) == strlower(name) then
            b.code = code
            self:Hint("Saved over " .. b.name .. ".")
            return
        end
    end
    table.insert(list, { name = name, code = code })
    self:Hint("Saved " .. name .. ".")
end

function P:LoadBuild(b)
    local target, why = self:Decode(b.code)
    if not target then self:Hint(why) return false end
    self.target = target
    self:Save()
    self:Render()
    self:Hint("Loaded " .. b.name .. ".")
    return true
end

function P:DeleteBuild(name)
    local list = self:Builds()
    for k, b in ipairs(list) do
        if b.name == name then table.remove(list, k) self:Hint("Deleted " .. name .. ".") return end
    end
end

function P:Import(code)
    local target, why = self:Decode(code)
    if not target then self:Hint(why) say(why) return false end
    self.target = target
    self:Save()
    self:Render()
    self:Hint("Build imported.")
    return true
end

-- -- Learning the plan ------------------------------------------------------------------------------------

-- The planned points in the order they can be learned (low tiers first).
function P:LearnQueue()
    local q = {}
    for tier = 1, 7 do
        for t = 1, getn(self.trees) do
            local tree = self.trees[t]
            for i = 1, tree.n do
                local x = tree.talents[i]
                if x.tier == tier then
                    for _ = 1, (self:Target(t, i) - x.rank) do table.insert(q, { t, i }) end
                end
            end
        end
    end
    return q
end

StaticPopupDialogs["CLASSICPLUS_LEARN_PLAN"] = {
    text = "Spend %s on your planned build? Learned talents stay until you reset them.",
    button1 = "Learn", button2 = "Cancel",
    OnAccept = function() P:StartLearning() end,
    timeout = 0, whileDead = 1, hideOnEscape = 1,
}

function P:AskLearn()
    if not self:IsLive() then self:Hint("Switch to " .. T.SpecName(self:Spec()) .. " to learn its plan.") return end
    if UnitAffectingCombat("player") then self:Hint("Leave combat first.") return end
    self:ReadTrees()
    local unspent = UnitCharacterPoints("player") or 0
    local q = self:LearnQueue()
    if not q[1] then self:Hint("Nothing planned to learn.") return end
    if unspent <= 0 then self:Hint("You have no unspent talent points.") return end
    local n = math.min(unspent, getn(q))
    StaticPopup_Show("CLASSICPLUS_LEARN_PLAN", n .. " talent point" .. ((n == 1) and "" or "s"))
end

function P:StartLearning()
    self:ReadTrees()
    local q = self:LearnQueue()
    local unspent = UnitCharacterPoints("player") or 0
    while getn(q) > unspent do table.remove(q) end
    if not q[1] then return end
    self.learning = { queue = q, i = 0, learned = 0 }
    self:LearnNext()
end

function P:LearnNext()
    local L = self.learning
    if not L then return end
    L.i = L.i + 1
    local step = L.queue[L.i]
    if not step then
        self.learning = nil
        self:Hint("Learned " .. L.learned .. " talent point" .. ((L.learned == 1) and "" or "s") .. " from your plan.")
        say("Learned " .. L.learned .. " talent point" .. ((L.learned == 1) and "" or "s") .. " from your plan.")
        self:Refresh()
        return
    end
    L.at = GetTime()
    L.waiting = true
    LearnTalent(step[1], step[2])
end

function P:OnPointsChanged()
    local L = self.learning
    if L and L.waiting then
        L.waiting = nil
        L.learned = L.learned + 1
        L.next = true
        return
    end
    self:Refresh()
end

-- -- Window -----------------------------------------------------------------------------------------------

local win = UI.Window("Talents_Planner", { classicFrame = true,
    width = WIDTH, height = 420, title = "Talent Planner", icon = "Interface\\Icons\\INV_Misc_Book_11",
    point = { "CENTER", UIParent, "CENTER", 120, 40 }, strata = "HIGH", skin = true,
})
win:Hide()
if win.icon and W:Art(win.icon, "Talents_Icon", "Interface\\Icons\\INV_Misc_Book_11") then win.icon:SetTexCoord(0, 1, 0, 1) end
table.insert(UISpecialFrames, "Talents_Planner")
P.win = win

-- spec selector (only with two specs)
P.specTabs = UI.Tabs(win, {
    tabs = { { key = 1, label = "Spec 1" } },
    maxWidth = 120,
    onSelect = function(key) P.spec = key P:Load() P:Render() end,
    skin = true,
})
P.specTabs:SetPoint("TOPLEFT", win, "TOPLEFT", 10, -30)

local pointsText = UI.Label(win, 11, { 1, 1, 1 }, "OUTLINE")
pointsText:SetPoint("TOPRIGHT", win, "TOPRIGHT", -12, -33)
pointsText:SetJustifyH("RIGHT")
P.pointsText = pointsText

local trees = {}
P.treeFrames = trees

local function talentEnter()
    local b = this
    local tree = P.trees[b.t]
    local x = tree and tree.talents[b.i]
    if not x then return end
    GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
    if P:IsLive() and GameTooltip.SetTalent then
        GameTooltip:SetTalent(b.t, b.i)
    end
    if GameTooltip:NumLines() == 0 then GameTooltip:SetText(x.name, 1, 1, 1) end
    local actual, rank = P:Actual(b.t, b.i), P:Rank(b.t, b.i)
    GameTooltip:AddLine("Planned: " .. rank .. "/" .. x.max .. ((rank > actual) and ("  (" .. (rank - actual) .. " to learn)") or ""), 0.25, 1, 0.25)
    local why = P:CanAdd(b.t, b.i)
    if why and rank < x.max then GameTooltip:AddLine(why, 1, 0.45, 0.4, 1) end
    GameTooltip:AddLine("Left-click: plan a point.  Right-click: take one off.", 0.62, 0.64, 0.70, 1)
    GameTooltip:Show()
end

local function talentClick()
    local b = this
    if arg1 == "RightButton" then P:Remove(b.t, b.i) else P:Add(b.t, b.i) end
    if GameTooltip:IsOwned(b) then talentEnter() end
end

local function makeTree(t)
    local f = CreateFrame("Frame", "Talents_PlanTree" .. t, win)
    UI.Themed(f, "inset")
    f:SetWidth(TREE_W)
    f:SetHeight(7 * CELL_Y + 6)
    f:SetPoint("TOPLEFT", win, "TOPLEFT", 10 + (t - 1) * (TREE_W + 8), GRID_TOP)
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetPoint("TOPLEFT", f, "TOPLEFT", 2, -2)
    f.bg:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)
    -- the stock talent-tree art: dimmed behind the flat look, near full in Classic and Brass
    UI.OnSkin(function(th) f.bg:SetAlpha(th.flat and 0.35 or 0.8) end)
    f.header = UI.Label(win, 11, UI.ACCENT, "OUTLINE")
    f.header:SetPoint("BOTTOMLEFT", f, "TOPLEFT", 2, 4)
    f.points = UI.Label(win, 11, { 1, 1, 1 }, "OUTLINE")
    f.points:SetPoint("BOTTOMRIGHT", f, "TOPRIGHT", -2, 4)
    f.points:SetJustifyH("RIGHT")
    f.buttons = {}
    trees[t] = f
    return f
end

local function makeButton(f, t, i)
    local b = CreateFrame("Button", "Talents_PlanBtn" .. t .. "_" .. i, f)
    b:SetWidth(BTN)
    b:SetHeight(BTN)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b.box = UI.IconBox(b, BTN)
    b.box:SetPoint("CENTER", b, "CENTER", 0, 0)
    b.badgeBg = b:CreateTexture(nil, "OVERLAY")
    b.badgeBg:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 3, -3)
    b.badgeBg:SetWidth(26)
    b.badgeBg:SetHeight(11)
    b.badgeBg:SetTexture(0, 0, 0, 0.85)
    b.badge = UI.Label(b, 9, nil, "OUTLINE")
    b.badge:SetPoint("CENTER", b.badgeBg, "CENTER", 0, 0)
    b.badge:SetJustifyH("CENTER")
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(b)
    UI.SkinIcon(b.box)
    UI.OnSkin(function(th)
        if th.flat then
            hl:SetTexture(1, 1, 1, 0.15)
            hl:SetBlendMode("BLEND")
        else
            hl:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
            hl:SetBlendMode("ADD")
        end
    end)
    b.t, b.i = t, i
    b:SetScript("OnClick", talentClick)
    b:SetScript("OnEnter", talentEnter)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.buttons[i] = b
    return b
end

-- footer
local hint = UI.Label(win, 10, UI.MUTED)
hint:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", 12, 36)
hint:SetWidth(WIDTH - 24)
P.hintText = hint
function P:Hint(text) hint:SetText(text or "") end

local x0 = 10
local function footerButton(text, w, onClick)
    local b = UI.Button(win, text, w, 20, onClick)
    b:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", x0, 10)
    x0 = x0 + w + 4
    return b
end
P.learnBtn = footerButton("Learn Plan", 86, function() P:AskLearn() end)
footerButton("Clear", 56, function() P:Clear() P:Hint("Plan cleared.") end)
footerButton("Save", 56, function()
    UI.Prompt({ title = "Save build", text = "A name for this build, like Raid or Leveling.", maxLetters = 24, accept = "Save",
        onAccept = function(name) P:SaveBuild(name) end })
end)
P.loadBtn = footerButton("Load", 56, function() P:LoadMenu(this) end)
footerButton("Export", 64, function()
    local code = P:Encode()
    UI.Prompt({ title = "Build code", text = "Copy this code (Ctrl+C) to share the build.", default = code, maxLetters = 80, accept = "Done" })
end)
footerButton("Import", 64, function()
    UI.Prompt({ title = "Import a build", text = "Paste a build code, like hunter/0505-0335-5.", maxLetters = 80, accept = "Import",
        onAccept = function(code) P:Import(code) end })
end)

function P:LoadMenu(anchor)
    local list = self:Builds()
    local items = { { text = "Saved builds", title = true } }
    if not list[1] then
        table.insert(items, { text = "None yet. Save one first.", disabled = true })
    end
    for _, b in ipairs(list) do
        local build = b
        table.insert(items, { text = build.name, func = function()
            if IsShiftKeyDown() then P:DeleteBuild(build.name) else P:LoadBuild(build) end
        end })
    end
    if list[1] then table.insert(items, { text = "Shift-click a build to delete it", disabled = true }) end
    UI.Menu(anchor, items)
end

-- -- Drawing ------------------------------------------------------------------------------------------------

function P:Render()
    if not win:IsShown() then return end
    local s = T.specs
    if s and s.count > 1 and W:Setting(ID, "specTabs", true) then
        local tabs = {}
        for n = 1, s.count do
            tabs[n] = { key = n, label = ((n == s.active) and "|cff40ff40*|r " or "") .. T.SpecName(n) }
        end
        self.specTabs:SetTabs(tabs)
        self.specTabs:Select(self:Spec(), true)
        self.specTabs:Show()
    else
        self.specTabs:Hide()
    end
    local total, planned = self:Total(), self:Planned()
    local unspent = self:IsLive() and (UnitCharacterPoints("player") or 0) or 0
    pointsText:SetText("Remaining |cffffd100" .. (MAX_POINTS - total) .. "|r   Planned |cff40ff40" .. planned .. "|r"
        .. (self:IsLive() and ("   Unspent " .. unspent) or ""))
    for t, tree in ipairs(self.trees) do
        local f = trees[t] or makeTree(t)
        f:Show()
        f.header:SetText(tree.name)
        f.points:SetText(self:TreePoints(t))
        if tree.file then
            f.bg:SetTexture("Interface\\TalentFrame\\" .. tree.file .. "-TopLeft")
            f.bg:SetTexCoord(0, 1, 0, 1)
        end
        for i = 1, tree.n do
            local x = tree.talents[i]
            local b = f.buttons[i] or makeButton(f, t, i)
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", f, "TOPLEFT", 4 + (x.col - 1) * CELL_X, -4 - (x.tier - 1) * CELL_Y)
            b.box.icon:SetTexture(x.icon or UI.UNKNOWN_ICON)
            local actual, rank = self:Actual(t, i), self:Rank(t, i)
            local open = rank > 0 or not self:CanAdd(t, i)
            if b.box.icon.SetDesaturated then b.box.icon:SetDesaturated((not open) and 1 or nil) end
            b.box.icon:SetAlpha(open and 1 or 0.45)
            local badge
            if rank > actual then
                badge = (actual > 0 and (actual .. "|cff40ff40+" .. (rank - actual) .. "|r") or ("|cff40ff40" .. rank .. "|r")) .. "/" .. x.max
            else
                badge = rank .. "/" .. x.max
            end
            b.badge:SetText(badge)
            if rank >= x.max then
                b.box.edge:SetTexture(UI.ACCENT[1], UI.ACCENT[2], UI.ACCENT[3], 1)
                b.badge:SetTextColor(1, 0.82, 0)
            elseif rank > 0 then
                b.box.edge:SetTexture(0.25, 0.85, 0.3, 1)
                b.badge:SetTextColor(1, 1, 1)
            else
                b.box.edge:SetTexture(0.35, 0.35, 0.38, 1)
                b.badge:SetTextColor(0.62, 0.64, 0.70)
            end
            b:Show()
        end
        for i = tree.n + 1, getn(f.buttons) do f.buttons[i]:Hide() end
    end
    for t = getn(self.trees) + 1, getn(trees) do trees[t]:Hide() end
    if self:IsLive() then self.learnBtn:Enable() else self.learnBtn:Disable() end
end

function P:Refresh()
    if not win:IsShown() then return end
    self:ReadTrees()
    self:Render()
end

function P:OnSpecChanged()
    self.spec = nil
    if win:IsShown() then
        self:ReadTrees()
        self:Load()
        self:Render()
    end
end

function P:Open()
    if not active() then return end
    self:ReadTrees()
    if not self.trees[1] then say("No talents to plan yet.") return end
    self:Load()
    win:Show()
    self:Render()
    T:AskSpecs()
end

function P:Hide() win:Hide() end

function P:Toggle()
    if win:IsShown() then win:Hide() else self:Open() end
end

win:SetScript("OnUpdate", function()
    local L = P.learning
    if not L then return end
    if L.next then
        L.next = nil
        P:ReadTrees()
        P:Render()
        P:LearnNext()
    elseif L.waiting and GetTime() - (L.at or 0) > 3 then
        P.learning = nil
        P:Hint("The realm didn't take that talent. Learned " .. L.learned .. ".")
        P:Refresh()
    end
end)
win:SetScript("OnHide", function()
    if P.learning then P.learning = nil end
end)

P.target = {}
P.trees = {}
