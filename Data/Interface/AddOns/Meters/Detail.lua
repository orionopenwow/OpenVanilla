--[[
    Detail.lua  -  the Meters breakdown window (Chronicle_Detail).

    Click a player in a Meters window: their spells (hits, crit rate, average, largest hit,
    misses, overhealing) and their targets. Shift-click a second player to compare the two side
    by side. Click a death (Deaths mode) for the last 10 hits and heals before it.
]]--

local W = WenillaCore
local UI = W.UI
local C = Chronicle

local floor = math.floor
local tinsert, getn = table.insert, table.getn

local DW, DH = 430, 318
local LIST_TOP, ROW_H = 84, 16

local f = UI.Window("Chronicle_Detail", {
    width = DW, height = DH, title = "Breakdown", titleAlign = "LEFT",
    icon = "Interface\\Icons\\INV_Misc_Book_09",
    point = { "RIGHT", UIParent, "RIGHT", -320, 60 },
    onClose = function() Chronicle_Detail:Hide() end,
    strata = "HIGH",
})
C.Frame(f)
C.Header(f)
f:Hide()
if UISpecialFrames then tinsert(UISpecialFrames, "Chronicle_Detail") end

local sub = UI.Label(f, 10, { 0.86, 0.80, 0.62 })
sub:SetPoint("TOPLEFT", f, "TOPLEFT", C.EDGE + 4, -(C.BAND_H + 3))
sub:SetWidth(DW - 2 * C.EDGE - 8)
f.sub = sub

local tabs = UI.Tabs(f, {
    height = 18,
    tabs = { { key = "spells", label = "Spells" }, { key = "targets", label = "Targets" } },
    onSelect = function(key)
        if C.detail then C.detail.view = key end
        C:RenderDetail()
    end,
})
C.ChromeTabs(tabs)
tabs:SetPoint("TOPLEFT", f, "TOPLEFT", C.EDGE + 1, -(C.HEADER_H + 5))
f.tabs = tabs

local inset = CreateFrame("Frame", nil, f)
UI.Skin(inset, "inset")
inset:SetPoint("TOPLEFT", f, "TOPLEFT", C.EDGE + 1, -(C.BAND_H + 18))
inset:SetWidth(DW - 2 * C.EDGE - 2)
inset:SetHeight(DH - C.BAND_H - 18 - 24)

local function column(x, justify, width)
    local l = UI.Label(inset, 9, UI.MUTED, "OUTLINE")
    if justify == "RIGHT" then
        l:SetPoint("TOPRIGHT", inset, "TOPRIGHT", -x, -5)
        l:SetJustifyH("RIGHT")
    else
        l:SetPoint("TOPLEFT", inset, "TOPLEFT", x, -5)
    end
    if width then l:SetWidth(width) end
    return l
end
local colName, colMid, colRight = column(8), column(170), column(12, "RIGHT")
f.cols = { colName, colMid, colRight }

local list = UI.ScrollList(inset, {
    width = DW - 24, height = DH - LIST_TOP - 30, rowHeight = ROW_H,
    build = function(row)
        row.bar = row:CreateTexture(nil, "BACKGROUND")
        row.bar:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -1)
        row.bar:SetHeight(ROW_H - 2)
        row.bar:SetTexture(C.ART.fill)
        row.left = UI.Label(row, 10, { 1, 1, 1 }, "OUTLINE")
        row.left:SetPoint("LEFT", row, "LEFT", 4, 0)
        row.left:SetWidth(160)
        row.mid = UI.Label(row, 9, { 0.85, 0.86, 0.90 }, "OUTLINE")
        row.mid:SetPoint("LEFT", row, "LEFT", 166, 0)
        row.right = UI.Label(row, 10, { 1, 1, 1 }, "OUTLINE")
        row.right:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        row.right:SetJustifyH("RIGHT")
    end,
    update = function(row, item)
        local frac = item.frac or 0
        if frac <= 0 then
            row.bar:Hide()
        else
            row.bar:SetWidth(math.max(1, (DW - 30) * math.min(1, frac)))
            row.bar:SetVertexColor(item.r or 0.4, item.g or 0.4, item.b or 0.45, 0.55)
            row.bar:Show()
        end
        row.left:SetText(item.left or "")
        row.mid:SetText(item.mid or "")
        row.right:SetText(item.right or "")
        local c = item.rc or { 1, 1, 1 }
        row.right:SetTextColor(c[1], c[2], c[3])
    end,
})
list:SetPoint("TOPLEFT", inset, "TOPLEFT", 4, -20)
f.list = list

local hint = UI.Label(f, 9, UI.MUTED)
hint:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 10, 8)
hint:SetWidth(DW - 20)
f.hint = hint

-- -- Data --------------------------------------------------------------------------------

local Num, Pct = C.Num, C.Pct

local function sorted(map)
    local out, sum, top = {}, 0, 0
    for k, v in pairs(map or {}) do
        tinsert(out, { key = k, v = v })
        sum = sum + v
        if v > top then top = v end
    end
    table.sort(out, function(a, b)
        if a.v == b.v then return a.key < b.key end
        return a.v > b.v
    end)
    return out, sum, top
end

-- "12 hits  crit 25.0%  avg 1.2k  max 2.4k  2 missed"
local function statText(value, st, amount)
    if not st then return "" end
    local n, c, m = st.n or 0, st.c or 0, st.m or 0
    local parts = {}
    if value == "heal" then
        tinsert(parts, n .. (n == 1 and " heal" or " heals"))
    else
        tinsert(parts, n .. (n == 1 and " hit" or " hits"))
    end
    if c > 0 then tinsert(parts, "crit " .. Pct(c, n)) end
    if n > 0 then tinsert(parts, "avg " .. Num(amount / n)) end
    if st.max then tinsert(parts, "max " .. Num(st.max)) end
    if m > 0 then tinsert(parts, m .. " missed") end
    if st.k and st.k > 0 then tinsert(parts, "over " .. Pct(st.o or 0, st.k)) end
    return table.concat(parts, "  ")
end

local function classRGB(cls)
    return UI.ClassColor(UI.ClassToken(cls))
end

function C:ShowDetail(name, mode, segSel)
    local d = self.detail
    local view = (d and not d.death and d.view) or "spells"
    self.detail = { name = name, mode = mode or self.mode, seg = segSel or "current", view = view }
    f:Show()
    self:RenderDetail()
end

function C:ShowCompare(a, b, mode, segSel)
    local d = self.detail
    self.detail = { name = a, compare = b, mode = mode or (d and d.mode) or self.mode,
        seg = segSel or (d and d.seg) or "current", view = (d and d.view) or "spells" }
    f:Show()
    self:RenderDetail()
end

function C:ShowDeath(rec)
    self.detail = { death = rec }
    f:Show()
    self:RenderDetail()
end

local function renderDeath(rec)
    f.title:SetText("Death recap - " .. rec.name)
    tabs:Hide()
    local b = rec.blow
    local text = "Died " .. W.Clock(rec.t) .. " into the fight."
    if b then
        text = text .. "  Killing blow: " .. (b.src and (b.src .. "'s ") or "") .. (b.abil or "Melee") .. " for " .. Num(-b.amt)
            .. (b.crit and " (critical)" or "") .. "."
    end
    sub:SetText(text)
    colName:SetText("Last " .. getn(rec.events) .. " events")
    colMid:SetText("Health")
    colRight:SetText("Amount")
    local items = {}
    for i = getn(rec.events), 1, -1 do
        local ev = rec.events[i]
        local ago = string.format("%.1f", rec.at - ev.t)
        local who = (ev.src and ev.src ~= "") and (ev.src .. ": ") or ""
        local hit = ev.amt < 0
        tinsert(items, {
            left = "-" .. ago .. "s  " .. who .. (ev.abil or "Melee"),
            mid = ev.hp and (ev.hp .. "%") or "",
            right = (hit and "-" or "+") .. Num(math.abs(ev.amt)) .. (ev.crit and " crit" or ""),
            rc = hit and { 1, 0.35, 0.3 } or { 0.4, 1, 0.45 },
            frac = ev.hp and (ev.hp / 100) or 0,
            r = hit and 0.6 or 0.25, g = hit and 0.18 or 0.55, b = hit and 0.15 or 0.25,
        })
    end
    if not items[1] then tinsert(items, { left = "No damage or healing was seen before this death." }) end
    list.offset = 0
    list:SetItems(items)
    hint:SetText("Newest first. Health is what the client showed at that moment.")
end

function C:RenderDetail()
    local d = self.detail
    if not d then
        f:Hide()
        return
    end
    if d.death then return renderDeath(d.death) end
    local m = C.MODE[d.mode] or C.MODE.dmg
    if m.special then m = C.MODE.dmg end
    local value = m.value
    local seg = self:Segment(d.seg)
    local p = seg and seg.players[d.name]
    local q = d.compare and seg and seg.players[d.compare]
    local dur = self:Duration(seg)
    -- per second over the fight; a fight with no length yet (0 s) is 0, never 0/0
    local function perSec(x) return Num((dur and dur > 0) and x / dur or 0) end
    tabs:Show()
    tabs:Select(d.view, true)
    local targets = (d.view == "targets")
    colName:SetText(targets and ((value == "dtaken" or value == "htaken" or value == "power") and "From" or "Target") or "Spell")
    local items = {}

    if d.compare then
        f.title:SetText(d.name .. " vs " .. d.compare .. " - " .. m.label)
        local a = p and p[value] or 0
        local b = q and q[value] or 0
        local rate = m.rate and ("  (" .. perSec(a) .. " vs " .. perSec(b) .. " per second)") or ""
        sub:SetText(d.name .. " " .. Num(a) .. "   " .. d.compare .. " " .. Num(b) .. rate)
        colMid:SetText(d.name)
        colRight:SetText(d.compare)
        local mapA = p and (targets and p.targets[value] or p.abilities[value]) or {}
        local mapB = q and (targets and q.targets[value] or q.abilities[value]) or {}
        local keys, seen = {}, {}
        for k in pairs(mapA) do if not seen[k] then seen[k] = true; tinsert(keys, k) end end
        for k in pairs(mapB) do if not seen[k] then seen[k] = true; tinsert(keys, k) end end
        local top, sumA, sumB = 1, 0, 0
        for _, k in ipairs(keys) do
            local x, y = mapA[k] or 0, mapB[k] or 0
            sumA, sumB = sumA + x, sumB + y
            if x > top then top = x end
            if y > top then top = y end
        end
        table.sort(keys, function(k1, k2)
            local s1, s2 = (mapA[k1] or 0) + (mapB[k1] or 0), (mapA[k2] or 0) + (mapB[k2] or 0)
            if s1 == s2 then return k1 < k2 end
            return s1 > s2
        end)
        local r, g, bl = classRGB(p and p.class)
        for _, k in ipairs(keys) do
            local x, y = mapA[k] or 0, mapB[k] or 0
            tinsert(items, {
                left = k,
                mid = Num(x) .. "  " .. Pct(x, sumA),
                right = Num(y) .. "  " .. Pct(y, sumB),
                frac = x / top, r = r, g = g, b = bl,
                rc = (y > x) and { 0.6, 1, 0.6 } or { 1, 1, 1 },
            })
        end
        hint:SetText("Green marks who did more of each. Click a player (no Shift) to leave the comparison.")
    else
        f.title:SetText(d.name .. " - " .. m.label)
        local total = p and p[value] or 0
        local group = seg and seg.total[value] or 0
        local parts = { "Total " .. (m.count and tostring(total) or Num(total)) }
        if m.rate then tinsert(parts, perSec(total) .. " per second") end
        if group > 0 then tinsert(parts, Pct(total, group) .. " of the group") end
        if value == "heal" and p and (p.healKnown or 0) > 0 then
            tinsert(parts, "overhealing " .. Pct(p.overheal or 0, p.healKnown) .. " (estimate)")
        end
        if value == "dmg" and p and (p.dtaken or 0) > 0 then tinsert(parts, "taken " .. Num(p.dtaken)) end
        tinsert(parts, self:SegmentName(seg, true) .. " " .. W.Clock(dur))
        sub:SetText(table.concat(parts, "   "))
        colMid:SetText(targets and "" or ((m.count or value == "power" or value == "dtaken" or value == "htaken" or value == "ff") and "" or "Hits, crits and misses"))
        colRight:SetText(m.count and "Count" or "Amount")
        local map = p and (targets and p.targets[value] or p.abilities[value])
        local rows, sum, top = sorted(map)
        if top <= 0 then top = 1 end
        local r, g, bl = classRGB(p and p.class)
        local stats = p and p.stats[value]
        for _, e in ipairs(rows) do
            tinsert(items, {
                left = e.key,
                mid = (not targets and stats) and statText(value, stats[e.key], e.v) or "",
                right = (m.count and tostring(e.v) or Num(e.v)) .. "  " .. Pct(e.v, sum),
                frac = e.v / top, r = r, g = g, b = bl,
            })
        end
        if not items[1] then
            local server = (value == "dmg") and self.inspectData[d.name]
            if server and server[1] then
                for _, a in ipairs(server) do
                    tinsert(items, { left = a.name, right = Num(a.amount) .. "  " .. (a.pct or "") })
                end
            else
                tinsert(items, { left = "Nothing recorded for " .. d.name .. " in this fight yet." })
            end
        end
        hint:SetText("Shift-click another player in Meters to compare.")
    end
    list:SetItems(items)
end
