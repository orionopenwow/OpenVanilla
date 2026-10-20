-- WenillaCore UI kit v2: switches, tabs, the settings sheet, menus, toasts, scroll lists, and the
-- plain addon names with their old aliases.
local T, api = ...

T.test("Kit: a switch flips, animates to its end and calls set", function()
    local env = T.addon("WenillaCore")
    local UI = env.WenillaCore.UI
    local value, calls = false, 0
    local s = UI.Switch(env.UIParent, { get = function() return value end, set = function(v) value = v; calls = calls + 1 end })
    T.no(s:GetOn())
    api.click(s)
    T.ok(s:GetOn()); T.eq(value, true); T.eq(calls, 1)
    api.tick(env, 0.5)
    T.eq(s.pos, 1, "knob slid all the way")
    s:SetEnabled(false)
    api.click(s)
    T.ok(s:GetOn(), "a disabled switch ignores clicks")
    T.eq(calls, 1)
    value = false
    s:Refresh()
    T.no(s:GetOn(), "Refresh re-reads get()")
    T.eq(s.pos, 0, "Refresh places the knob at once")
end)

T.test("Kit: tabs select, mark unread, add and right-click", function()
    local env = T.addon("WenillaCore")
    local UI = env.WenillaCore.UI
    local picked, added, menu = nil, 0, nil
    local bar = UI.Tabs(env.UIParent, {
        tabs = { { key = "a", label = "General" }, { key = "b", label = "Combat" } },
        onSelect = function(k) picked = k end,
        onAdd = function() added = added + 1 end,
        onMenu = function(k) menu = k end,
    })
    T.eq(bar:Selected(), "a", "first tab selected without firing")
    T.eq(picked, nil)
    bar:SetUnread("b", true)
    T.eq(bar:Button("b").dot:GetAlpha(), 1, "unread dot on b")
    api.click(bar:Button("b"))
    T.eq(picked, "b")
    T.eq(bar:Button("b").dot:GetAlpha(), 0, "selecting clears unread")
    api.click(bar:Button("__add"))
    T.eq(added, 1, "+ tab")
    api.click(bar:Button("a"), "RightButton")
    T.eq(menu, "a", "right-click opens the tab menu")
    T.eq(picked, "b", "right-click doesn't select")
end)

T.test("Kit: the settings sheet builds rows and toggles beside its window", function()
    local env = T.addon("WenillaCore")
    local UI = env.WenillaCore.UI
    local win = UI.Window("KitTestWindow", { width = 200, height = 100, title = "Test" })
    local s = { on = true, mode = "a", size = 12 }
    local sheet = UI.Sheet(win, { title = "Settings" })
    sheet:AddHeader("Display")
    local row = sheet:AddSwitch("Show it", "A long description that wraps onto a second line in the sheet.",
        function() return s.on end, function(v) s.on = v end)
    local choice = sheet:AddChoice("Mode", { { value = "a", label = "Alpha" }, { value = "b", label = "Beta" } },
        function() return s.mode end, function(v) s.mode = v end)
    sheet:AddSlider("Size", 8, 20, 1, function() return s.size end, function(v) s.size = v end, "%d pt")
    T.hidden(sheet)
    local gear = UI.GearButton(win, function() sheet:Toggle() end)
    api.click(gear)
    T.shown(sheet)
    T.eq(choice.value:GetText(), "Alpha")
    api.click(choice.button)
    T.eq(s.mode, "b"); T.eq(choice.value:GetText(), "Beta")
    api.click(choice.button, "RightButton")
    T.eq(s.mode, "a", "right-click goes back")
    api.click(row.switch)
    T.eq(s.on, false)
    T.ok(sheet:GetHeight() > 80, "sheet grew with its rows")
    api.click(gear)
    T.hidden(sheet)
end)

T.test("Kit: menu, toast and scroll list", function()
    local env = T.addon("WenillaCore")
    local UI = env.WenillaCore.UI
    local chosen
    local m = UI.Menu(nil, { { text = "Title", title = true }, { text = "Pick me", func = function() chosen = 1 end } })
    T.shown(m)
    api.click_text(env, "Title", m)
    T.shown(m, "a title row does nothing")
    api.click_text(env, "Pick me", m)
    T.eq(chosen, 1); T.hidden(m)

    local t = UI.Toast({ title = "Achievement Earned", text = "Level 10", duration = 2 })
    T.shown(t)
    T.ok(api.screen_has(env, "Level 10", t))
    api.tick(env, 3)
    T.hidden(t, "toast fades away")

    local list = UI.ScrollList(env.UIParent, {
        height = 54, rowHeight = 18,
        build = function(row) row.text = UI.Label(row, 10) row.text:SetPoint("LEFT", row, "LEFT", 0, 0) end,
        update = function(row, item) row.text:SetText(item) end,
    })
    list:SetItems({ "one", "two", "three", "four", "five" })
    T.eq(list.rows[1].text:GetText(), "one")
    api.wheel(list, -1)
    T.eq(list.rows[1].text:GetText(), "three", "wheel scrolls two rows")
    api.wheel(list, -5)
    T.eq(list.rows[3].text:GetText(), "five", "never past the end")
    list:SetItems({ "only" })
    T.hidden(list.rows[2])
end)

T.test("Kit: plain names, old names still resolve, new addons join in order", function()
    local env = T.suite()
    local W = env.WenillaCore
    T.eq(W.Id("Chronicle"), "Meters")
    T.eq(W.Id("Vault"), "Bags")
    T.eq(W.BRAND.Meters, "Meters")
    for i, id in ipairs(W.ADDONS) do
        T.ok(W.refreshers[id], id .. " registered")
        if i > 1 then
            local function rank(x) for k, y in ipairs(W.ORDER) do if y == x then return k end end return 1000 end
            T.ok(rank(W.ADDONS[i - 1]) <= rank(id), "W.ADDONS keeps W.ORDER: " .. W.ADDONS[i - 1] .. " before " .. id)
        end
    end
    for _, toc in ipairs(api.suite_names(env)) do
        local t = api.read_toc(api.addons_dir(env) .. "/" .. toc .. "/" .. toc .. ".toc")
        T.ok(t and t.meta.Title, toc .. " has a title")
        if t and t.meta.Title then T.lacks(t.meta.Title, "Classic+", toc .. " title is plain") end
    end
end)

T.test("Kit: bottom tabs glow only on the chosen tab and under the mouse", function()
    local env = T.addon("WenillaCore")
    local UI = env.WenillaCore.UI
    local holder = env.CreateFrame("Frame", "KitTabHolder", env.UIParent)
    local bar = UI.ClassicTabs(holder, { tabs = { { key = "a", label = "Suggested Content" }, { key = "b", label = "Dungeons" }, { key = "c", label = "Raids" } } })
    local a, b, c = bar.buttons[1], bar.buttons[2], bar.buttons[3]
    T.ok(a.hl:IsShown(), "the chosen tab glows")
    T.no(b.hl:IsShown(), "the others don't"); T.no(c.hl:IsShown())
    api.enter(c)
    T.ok(c.hl:IsShown(), "hover glows")
    api.leave(c)
    T.no(c.hl:IsShown(), "and stops")
    api.click(b)
    T.ok(b.hl:IsShown()); T.no(a.hl:IsShown(), "the glow follows the choice")
end)

T.test("Kit: a faint alpha tag sits in the bottom-right corner and never takes the mouse", function()
    local env = T.addon("WenillaCore")
    local t = env.WenillaCore_AlphaTag
    T.shown(t)
    T.has(env.WenillaCore_AlphaTagText:GetText(), "Alpha test v")
    local p = t:GetPoint(1)
    T.eq(p, "BOTTOMRIGHT")
    T.ok(env.WenillaCore_AlphaTagText:GetAlpha() < 0.5, "subtle")
end)
