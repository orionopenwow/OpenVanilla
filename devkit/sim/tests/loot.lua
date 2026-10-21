-- Loot: our loot window over the stock loot API, AL area-loot merging, auto loot with one
-- summary line, and the stock window kept quiet (or given back by the setting).
local T, api = ...

local SLOTS = { { coin = 31204 }, { 2589, 5 }, { 1203, 1 }, { 2770, 2 } }

-- lootEngine (ext/loot_aoe.lua): loot as the wenilla engine does, where LootSlot is only the
-- bind-on-pickup confirmation and a slot is taken by a hardware click on a LootButton.
local function looter(opts)
    opts = opts or {}
    opts.latency = false
    if opts.lootEngine == nil then opts.lootEngine = true end
    return T.addon("Loot", opts)
end

-- What the user saw: one window for three corpses, no money, a Broken Fang stack from two of them.
local AOE = { { 7074, 2 }, { 7074, 1 }, { 7073, 2 }, { 7074, 1 } }

T.test("Loot: one row per item in its quality colour, the money on top, the stock window quiet", function()
    local env = looter()
    api.open_loot(env, SLOTS, { shift = true })
    T.shown(env.Loot_Frame)
    T.hidden(env.LootFrame, "the stock window stays closed")
    local texts = table.concat(api.visible_texts(env, env.Loot_Frame), " | ")
    T.has(texts, "3g 12s 4c", "money line")
    T.has(texts, "Linen Cloth")
    T.has(texts, "Aegis of Stormwind")
    T.has(env.Loot_Row2.name:GetText(), "|cff0070dd", "rare item in blue")
    T.eq(env.Loot_Row1.count:GetText(), "5", "stack count on the icon")
    T.lacks(texts, "corpses", "a single corpse says nothing about corpses")
    T.hidden(env.Loot_Row4, "three item rows")
    api.enter(env.Loot_Row1)
    T.has(api.tooltip_text(env), "Linen Cloth")
end)

T.test("Loot: click a row to loot it, the money line for the coins, Take All for the rest", function()
    local env = looter()
    local money0 = env.__money
    api.open_loot(env, SLOTS, { shift = true })
    api.click(env.Loot_Row2)                    -- the shield
    api.pump(env)
    T.eq(env.__loot_taken[1], 3)
    T.no(api.screen_has(env, "Aegis", env.Loot_Frame), "the row went away")
    api.click(env.Loot_Money)
    api.pump(env)
    T.eq(env.__money - money0, 31204)
    T.hidden(env.Loot_Money, "no money left")
    -- the client takes one slot per click: Take All is slotted to the next one each time
    api.click_text(env, "Take All", env.Loot_Frame)
    api.pump(env)
    T.shown(env.Loot_Frame, "one taken, one left")
    api.click_text(env, "Take All", env.Loot_Frame)
    api.pump(env)
    T.hidden(env.Loot_Frame, "everything taken closes the window")
    T.eq(env.__loot_open, nil)
end)

T.test("Loot: Shift-click links the item; Close and Escape close the loot", function()
    local env = looter()
    api.open_loot(env, SLOTS, { shift = true })
    env.ChatFrameEditBox:Show()
    env.__keys.shift = true
    api.click(env.Loot_Row1)
    env.__keys.shift = nil
    T.has(env.ChatFrameEditBox:GetText(), "|Hitem:2589:", "link inserted")
    T.eq(#env.__loot_taken, 0, "linking does not loot")
    env.ChatFrameEditBox:Hide()
    api.click_text(env, "Close", env.Loot_Frame)
    api.pump(env)
    T.hidden(env.Loot_Frame)
    T.eq(env.__loot_open, nil, "CloseLoot was called")
    api.open_loot(env, SLOTS, { shift = true })
    T.ok(api.press_escape(env))
    api.pump(env)
    T.eq(env.__loot_open, nil, "Escape closes the loot too")
end)

T.test("Loot: AL merges corpses: money from all of them, x3 on items from several", function()
    local env = looter()
    api.connect(env)
    api.server_packet(env, "AL", "4,52010;2,3;3,1")
    api.open_loot(env, SLOTS, { shift = true })
    local texts = table.concat(api.visible_texts(env, env.Loot_Frame), " | ")
    T.has(texts, "5g 20s 10c", "money from every corpse")
    T.has(texts, "from 4 corpses")
    T.has(texts, "4 corpses", "title says so")
    T.eq(env.Loot_Row1.sources:GetText(), "x3", "linen from three corpses")
    T.no(env.Loot_Row2.sources:GetText(), "the shield from one")
    api.enter(env.Loot_Row1)
    T.has(api.tooltip_text(env), "From 3 corpses.")
    -- AL after the window opened works too
    api.close_loot(env)
    api.open_loot(env, SLOTS, { shift = true })
    T.no(api.screen_has(env, "corpses", env.Loot_Frame), "the old AL is forgotten")
    api.server_packet(env, "AL", "2,100;4,2")
    T.eq(env.Loot_Row3.sources:GetText(), "x2")
end)

T.test("Loot: auto loot takes everything with one summary line", function()
    local env = looter()
    local money0 = env.__money
    api.connect(env)
    api.server_packet(env, "AL", "3,31204;2,2")
    api.open_loot(env, SLOTS)
    T.hidden(env.Loot_Frame, "no window for auto loot")
    api.pump(env)
    T.eq(env.__money - money0, 31204)
    T.eq(env.__loot_open, nil)
    local chat = string.gsub(api.chat_text(env), "|H.-|h(.-)|h", "%1")
    T.has(chat, "Looted [Linen Cloth]x5, [Aegis of Stormwind], [Copper Ore]x2 and 3g 12s 4c from 3 corpses.")
end)

T.test("Loot: auto loot with full bags opens the window with what is left", function()
    local items = {}
    for i = 1, 15 do items[i] = { 6948, 1 } end
    local env = looter({ bags = { [0] = { size = 16, items = items } } })
    api.open_loot(env, { { 2589, 5 }, { 1203, 1 } }, { auto = true })
    api.tick(env, 1.5)
    T.shown(env.Loot_Frame, "what didn't fit")
    -- the engine's sweep goes in slot order: the linen took the last free slot
    T.ok(api.screen_has(env, "Aegis of Stormwind", env.Loot_Frame))
    T.no(api.screen_has(env, "Linen Cloth", env.Loot_Frame), "the linen took the last free slot")
end)

T.test("Loot: the setting gives the stock window back; master looters get it too", function()
    local env = looter()
    env.ClassicPlus_Manager:SetSetting("Loot", "keepBlizzard", true)
    api.open_loot(env, SLOTS, { shift = true })
    T.shown(env.LootFrame, "stock window")
    T.hidden(env.Loot_Frame)
    api.close_loot(env)
    T.hidden(env.LootFrame)
    env.ClassicPlus_Manager:SetSetting("Loot", "keepBlizzard", false)
    env.__loot_method = { "master", 0 }
    api.open_loot(env, SLOTS, { shift = true })
    T.shown(env.LootFrame, "master loot uses the stock window and its menu")
    T.hidden(env.Loot_Frame)
    api.close_loot(env)
    T.hidden(env.LootFrame, "and closes it")
    env.__loot_method = nil
    env.WenillaCore:SetAddonEnabled("Loot", false)
    api.open_loot(env, SLOTS, { shift = true })
    T.shown(env.LootFrame, "addon off: stock window")
end)

T.test("Loot: many items scroll; coin text parses every denomination", function()
    local env = looter()
    local slots = {}
    for i = 1, 14 do slots[i] = { (i == 3) and 1203 or 2589, i } end
    api.open_loot(env, slots, { shift = true })
    T.shown(env.Loot_Row10)
    T.eq(env.Loot_Row11, nil, "ten rows at most")
    T.ok(api.screen_has(env, "1-10 of 14", env.Loot_Frame))
    api.wheel(env.Loot_Frame, -1)
    T.ok(api.screen_has(env, "3-12 of 14", env.Loot_Frame))
    local L = env.ClassicPlusLoot
    T.eq(L.ParseCoins("1 Gold\n2 Silver\n3 Copper"), 10203)
    T.eq(L.ParseCoins("45 Copper"), 45)
    T.eq(L.ParseCoins(nil), 0)
end)

T.test("Loot: malformed AL packets never raise", function()
    local env = looter()
    api.connect(env)
    api.open_loot(env, SLOTS, { shift = true })
    for _, b in ipairs({ "", ";", "x", "0,0", "-3,5", "2,abc;x,y;,;", "3,-100;1,0;99,99", string.rep("9", 300), "1,1;;;;" }) do
        api.server_packet(env, "AL", b)
    end
    T.shown(env.Loot_Frame)
end)

T.test("Loot: with auto loot switched off, a plain loot opens the window and Shift auto-loots", function()
    local env = looter({ cvars = { autoLootDefault = "0" }, saved = { ClassicPlus_Defaults = { version = 2, lootFallback = true } } })
    api.open_loot(env, SLOTS)
    T.shown(env.Loot_Frame, "plain loot: the window")
    api.close_loot(env)
    api.open_loot(env, SLOTS, { shift = true })
    T.hidden(env.Loot_Frame, "Shift: auto loot")
    api.pump(env)
    -- the bind-on-pickup shield asks (the defaults confirm it only with auto loot on)
    T.shown(env.StaticPopup1, "LOOT_BIND for the shield")
    api.popup_click(env, "LOOT_BIND", 1)
    api.pump(env)
    T.has(api.chat_text(env), "Looted ")
end)

T.test("Loot: during auto loot the per-item loot lines are hidden, others' lines are not", function()
    local env = looter()
    api.open_loot(env, SLOTS)
    local function line(ev, text)
        env.this, env.arg1 = env.ChatFrame1, text
        env.ChatFrame_OnEvent(ev)
        env.this, env.arg1 = nil, nil
    end
    line("CHAT_MSG_LOOT", "You receive loot: [Linen Cloth]x5.")
    api.pump(env)
    line("CHAT_MSG_MONEY", "You loot 3 Gold, 12 Silver, 4 Copper")
    line("CHAT_MSG_LOOT", "Brakkus receives loot: [Copper Ore].")
    local chat = api.chat_text(env)
    T.lacks(chat, "You receive loot")
    T.lacks(chat, "You loot 3 Gold")
    T.has(chat, "Brakkus receives loot")
    api.tick(env, 2)
    line("CHAT_MSG_LOOT", "You receive loot: [Silk Cloth].")
    T.has(api.chat_text(env), "You receive loot: [Silk Cloth]", "normal again afterwards")
end)

-- The client fills in a loot slot's texture and name only once the item's data has arrived, so the
-- first loot of an item it has never seen comes in blank (GetLootSlotInfo -> nil, nil, ...).
local function coldSlots(env, cold)
    local real = env.GetLootSlotInfo
    env.GetLootSlotInfo = function(i)
        if cold[i] then return nil, nil, 1, nil end
        return real(i)
    end
end

T.test("Loot: an item whose data has not arrived yet still gets a row, and can be looted", function()
    local env = looter()
    local cold = { [3] = true }
    coldSlots(env, cold)
    api.open_loot(env, SLOTS, { shift = true })
    T.shown(env.Loot_Row3, "three item rows, the unknown one included")
    T.has(env.Loot_Row2.name:GetText(), "Retrieving item information")
    cold[3] = nil                                   -- the item's data arrives
    api.tick(env, 0.5)
    T.has(env.Loot_Row2.name:GetText(), "Aegis of Stormwind", "the row fills in by itself")
    api.click(env.Loot_Row2)
    api.pump(env)
    T.eq(env.__loot_taken[1], 3)
end)

T.test("Loot: auto loot and Take All also take items whose data has not arrived", function()
    local env = looter()
    local cold = { [2] = true, [3] = true }
    coldSlots(env, cold)
    api.open_loot(env, SLOTS)
    api.pump(env)
    T.eq(env.__loot_open, nil, "everything taken and the loot closed")
    T.hidden(env.Loot_Frame)
    env = looter({ name = "Brakkus" })
    coldSlots(env, { [2] = true, [3] = true, [4] = true })
    api.open_loot(env, SLOTS, { shift = true })
    T.no(api.screen_has(env, "Nothing left", env.Loot_Frame), "unknown items are not 'nothing'")
    for _ = 1, 4 do
        api.click_text(env, "Take All", env.Loot_Frame)
        api.pump(env)
    end
    T.eq(env.__loot_open, nil, "Take All emptied it, one click per slot")
end)

T.test("Loot: a new loot window forgets an auto loot that never closed", function()
    local env = looter()
    local L = env.ClassicPlusLoot
    L.auto = { started = env.GetTime() - 30, taken = {}, copper = 0, shown = true }
    api.open_loot(env, SLOTS, { shift = true })
    T.eq(L.auto, nil)
    T.shown(env.Loot_Frame)
    api.click(env.Loot_Row1)
    api.pump(env)
    T.eq(env.__loot_taken[1], 2)
end)

T.test("Loot: the X and Close hide the window at once and close the loot", function()
    local env = looter()
    api.open_loot(env, SLOTS, { shift = true })
    api.click(env.Loot_Frame.closeButton)
    T.hidden(env.Loot_Frame, "hidden straight away, like the stock window")
    api.pump(env)
    T.eq(env.__loot_open, nil)
    api.open_loot(env, SLOTS, { shift = true })
    T.shown(env.Loot_Frame, "and a new loot opens it again")
    api.click(env.Loot_Row1)
    api.pump(env)
    T.eq(env.__loot_taken[1], 2, "and its rows loot")
end)

T.test("Loot: Classic is the stock loot frame; Brass and Slick re-skin it live and the choice is saved", function()
    local env = looter()
    local L, UI = env.ClassicPlusLoot, env.WenillaCore.UI
    T.eq(UI.SkinKey(), "classic", "Classic by default")
    api.open_loot(env, SLOTS, { shift = true })
    T.eq(env.Loot_Frame:GetWidth(), 188, "the stock panel's width")
    T.shown(L.chrome.top)
    T.has(L.chrome.top:GetTexture(), "UI-LootPanel")
    T.has(L.chrome.portrait:GetTexture(), "TargetDead")
    T.has(env.Loot_Row1.icon.skinBorder:GetTexture(), "UI-Quickslot2", "stock item-button border")
    T.shown(env.Loot_Row1.nameFrame)
    T.ok(api.screen_has(env, "Items", env.Loot_Frame), "the stock title")
    T.ok(UI.SetSkin("slick"))
    T.eq(env.Loot_Frame:GetWidth(), 230)
    T.hidden(L.chrome.top)
    T.hidden(env.Loot_Row1.nameFrame)
    T.ok(api.screen_has(env, "Loot", env.Loot_Frame))
    T.ok(UI.SetSkin("brass"))
    T.hidden(L.chrome.top)
    T.has(env.Loot_Frame.header:GetTexture(), "Ach_TitleCrest", "the Classic+ crest")
    T.has(env.Loot_Row1.icon.skinBorder:GetTexture(), "Slot", "the Classic+ slot")
    T.eq(env.WenillaCore_Config.settings.Themes.skin, "brass", "saved in SavedVariables")
    api.click(env.Loot_Row1)
    api.pump(env)
    T.eq(env.__loot_taken[1], 2, "rows still loot after a re-skin")
    T.no(UI.SetSkin("nope"), "unknown skins are refused")
    local again = T.relog(env)
    T.eq(again.WenillaCore.UI.SkinKey(), "brass", "the skin survives a relog")
end)

T.test("Loot: the skin picker in the Addons window (Themes > Window skin) re-skins the open window", function()
    local env = looter()
    api.load_with_deps(env, "Themes")
    local W = env.WenillaCore
    local schema = W.schemas.Themes
    T.ok(schema, "Themes has a settings page")
    T.eq(schema.options[1].type, "choice")
    T.eq(schema.options[1].choices[1].label, "Classic")
    T.eq(schema.options[2] and 1 or #schema.options[1].choices, 3, "Classic, Brass, Slick")
    api.open_loot(env, SLOTS, { shift = true })
    T.eq(env.Loot_Frame:GetWidth(), 188)
    env.ClassicPlus_Manager:SetSetting("Themes", "skin", "slick")
    T.eq(W.UI.appliedSkin, "slick")
    T.eq(env.Loot_Frame:GetWidth(), 230, "re-skinned without a reload")
end)

-- -- The engine's take: a LootButton click, never LootSlot ------------------------------------

T.test("Loot: a row click loots exactly that row on the engine (LootSlot alone takes nothing)", function()
    local env = looter()
    api.open_loot(env, SLOTS, { shift = true })
    T.eq(env.Loot_Row3:GetObjectType(), "LootButton", "rows are LootButtons, the only thing the client lets a click take with")
    api.click(env.Loot_Row3)                    -- Copper Ore, slot 4
    api.pump(env)
    T.eq(env.__loot_picks[1], 4, "the clicked row's slot")
    T.eq(env.__loot_taken[1], 4)
    T.no(api.screen_has(env, "Copper Ore", env.Loot_Frame), "the row went away (LOOT_SLOT_CLEARED)")
    api.click(env.Loot_Row1, "RightButton")     -- Linen Cloth, slot 2
    api.pump(env)
    T.eq(env.__loot_taken[2], 2, "right-click loots too")
    T.eq(#env.__loot_taken, 2, "nothing else was taken")
end)

T.test("Loot: Shift-click links and Ctrl-click dresses up without looting", function()
    local env = looter()
    local dressed
    rawset(env, "DressUpItemLink", function(link) dressed = link end)
    api.open_loot(env, SLOTS, { shift = true })
    env.ChatFrameEditBox:Show()
    env.__keys.shift = true
    api.click(env.Loot_Row2)
    env.__keys.shift = nil
    T.has(env.ChatFrameEditBox:GetText(), "|Hitem:1203:", "link inserted")
    env.__keys.ctrl = true
    api.click(env.Loot_Row2)
    env.__keys.ctrl = nil
    api.pump(env)
    T.has(dressed or "", "|Hitem:1203:", "dressing room")
    T.eq(#env.__loot_picks, 0, "neither one loots")
end)

T.test("Loot: three corpses in one window (AL): every row loots its own slot, x2 included", function()
    local env = looter()
    api.connect(env)
    api.server_packet(env, "AL", "3,0;3,2")
    api.open_loot(env, AOE, { shift = true })
    T.ok(api.screen_has(env, "3 corpses", env.Loot_Frame))
    T.hidden(env.Loot_Money, "no money on these")
    T.eq(env.Loot_Row1.count:GetText(), "2")
    T.eq(env.Loot_Row3.sources:GetText(), "x2", "Broken Fang from two corpses")
    api.click(env.Loot_Row3)
    api.pump(env)
    T.eq(env.__loot_taken[1], 3, "the merged Broken Fang row takes its slot, the whole stack")
    T.ok(env.GetContainerItemInfo(0, 1), "in the bag")
    -- the rows shift up; each still takes the slot it shows
    T.has(env.Loot_Row3.name:GetText(), "Chipped Claw")
    api.click(env.Loot_Row3)
    api.pump(env)
    T.eq(env.__loot_taken[2], 4)
    api.click(env.Loot_Row1)
    api.click(env.Loot_Row2)
    api.pump(env)
    T.eq(#env.__loot_taken, 4, "all four")
    T.hidden(env.Loot_Frame, "the window closes with the loot")
    T.eq(env.__loot_open, nil)
end)

T.test("Loot: Take All on the engine takes the money and every item, one per click", function()
    local env = looter()
    local money0 = env.__money
    api.open_loot(env, SLOTS, { shift = true })
    local b = select(2, api.find_text(env, "Take All", env.Loot_Frame))
    T.eq(b:GetObjectType(), "LootButton")
    for i = 1, 8 do
        if not env.Loot_Frame:IsShown() then break end
        api.click_text(env, "Take All", env.Loot_Frame)
        api.pump(env)
    end
    T.eq(env.__money - money0, 31204, "money too")
    T.eq(#env.__loot_taken, 4, "every slot")
    T.eq(env.__loot_picks[1], 1, "the money first")
    T.hidden(env.Loot_Frame)
    T.eq(env.__loot_open, nil)
end)

T.test("Loot: a bind-on-pickup row asks first; Okay loots it, and only it", function()
    local env = looter()
    env.__units.party1 = { name = "Ann", class = "MAGE", level = 60, isPlayer = true, debuffs = {}, buffs = {} }
    api.open_loot(env, SLOTS, { shift = true })
    api.click(env.Loot_Row2)                    -- Aegis of Stormwind: binds when picked up
    api.pump(env)
    T.eq(env.__loot_bind_pending, 3)
    T.shown(env.StaticPopup1, "the LOOT_BIND popup")
    T.eq(#env.__loot_taken, 0, "not before Okay")
    env.LootSlot(2)                             -- not the row being asked about
    api.pump(env)
    T.eq(#env.__loot_taken, 0, "LootSlot takes only the pending row")
    api.popup_click(env, "LOOT_BIND", 1)
    api.pump(env)
    T.eq(env.__loot_taken[1], 3)
    T.no(api.screen_has(env, "Aegis", env.Loot_Frame))
    -- solo, the auto loot defaults confirm it for you
    env.__units.party1 = nil
    api.close_loot(env)
    api.open_loot(env, SLOTS, { shift = true })
    api.click(env.Loot_Row2)
    api.pump(env)
    T.eq(env.__loot_taken[1], 3, "solo: confirmed")
end)

T.test("Loot: rows keep their slots across scrolling", function()
    local env = looter()
    local slots = {}
    for i = 1, 14 do slots[i] = { (i == 12) and 2770 or 2589, i } end
    api.open_loot(env, slots, { shift = true })
    api.wheel(env.Loot_Frame, -1)               -- rows show slots 3-12
    T.has(env.Loot_Row10.name:GetText(), "Copper Ore")
    api.click(env.Loot_Row10)
    api.pump(env)
    T.eq(env.__loot_taken[1], 12)
end)

T.test("Loot: auto loot never answers a bind-on-pickup popup for you in a group", function()
    local env = looter()
    env.__units.party1 = { name = "Ann", class = "MAGE", level = 60, isPlayer = true, debuffs = {}, buffs = {} }
    api.open_loot(env, SLOTS)                   -- auto loot: the client sweeps, the shield asks
    api.pump(env)
    T.eq(env.__loot_bind_pending, 3, "still asking")
    T.shown(env.StaticPopup1, "the LOOT_BIND popup is up")
    for _, slot in ipairs(env.__loot_taken) do T.ok(slot ~= 3, "the shield was not taken") end
    api.popup_click(env, "LOOT_BIND", 1)
    api.pump(env)
    T.eq(env.__loot_open, nil, "Okay took it, and that emptied the loot")
end)

T.test("Loot: auto loot shows what it took for a moment, then fades", function()
    local env = looter()
    api.connect(env)
    api.server_packet(env, "AL", "3,31204;2,2")
    api.open_loot(env, SLOTS)
    api.pump(env)
    T.hidden(env.Loot_Frame, "no loot window: nothing is left to take")
    local r = env.Loot_Recap
    T.shown(r, "the recap shows")
    T.ok(api.screen_has(env, "Linen Cloth", r), "with the items")
    T.ok(api.screen_has(env, "Aegis of Stormwind", r))
    T.ok(api.screen_has(env, "x5", r), "and their counts")
    T.ok(api.screen_has(env, "Looted from 3", r), "from how many corpses")
    api.tick(env, 2)
    T.eq(r:GetAlpha(), 1, "held for a moment")
    api.tick(env, 1)
    T.ok(r:GetAlpha() < 1, "then fading")
    api.tick(env, 1.5)
    T.hidden(r, "and gone")
end)

T.test("Loot: when auto loot empties the slots before their items are known, the loot lines make the recap", function()
    local env = looter()
    api.fire(env, "LOOT_OPENED", 1)              -- the client's own auto loot: the slots are already gone
    api.fire(env, "CHAT_MSG_LOOT", "You receive loot: |cffffffff|Hitem:2589:0:0:0|h[Linen Cloth]|h|rx3.")
    api.fire(env, "LOOT_CLOSED")
    api.pump(env)
    local r = env.Loot_Recap
    T.shown(r, "the recap shows anyway")
    T.ok(api.screen_has(env, "Linen Cloth", r), "with the item from the loot line")
    T.ok(api.screen_has(env, "x3", r), "and its count")
    -- a line that arrives just after the loot closed joins it
    api.fire(env, "CHAT_MSG_LOOT", "You receive loot: |cff1eff00|Hitem:2770:0:0:0|h[Copper Ore]|h|r.")
    api.pump(env)
    T.ok(api.screen_has(env, "Copper Ore", r), "a late line is added")
    api.tick(env, 2)
    T.eq(r:GetAlpha(), 1, "held for a couple of seconds")
    api.tick(env, 2)
    T.hidden(r, "then gone")
end)

T.test("Loot: the recap can be switched off; a looted window never shows one", function()
    local env = looter()
    env.ClassicPlus_Manager:SetSetting("Loot", "autoRecap", false)
    api.open_loot(env, SLOTS, { auto = true })
    api.pump(env)
    T.hidden(env.Loot_Recap, "switched off")
    env.ClassicPlus_Manager:SetSetting("Loot", "autoRecap", true)
    api.open_loot(env, SLOTS, { shift = true })
    for i = 1, 8 do
        if not env.Loot_Frame:IsShown() then break end
        api.click_text(env, "Take All", env.Loot_Frame)
        api.pump(env)
    end
    T.hidden(env.Loot_Recap, "the window was its own recap")
end)

T.test("Loot: the recap opens beside the cursor and never over your character in the middle of the screen", function()
    local env = looter()
    api.connect(env)
    env.__cursor = { 512, 330 }                       -- you clicked the corpse at your feet, mid-screen
    api.open_loot(env, SLOTS)
    api.pump(env)
    local r = env.Loot_Recap
    T.shown(r)
    local _, _, _, x, y = r:GetPoint(1)
    local sw = env.UIParent:GetWidth()
    T.ok(x >= sw / 2 + 150 or x + 210 <= sw / 2 - 150, "clear of the middle band (x = " .. tostring(x) .. ")")
    T.ok(x + 210 <= sw, "on screen")
    T.ok(y - r:GetHeight() >= 120, "above the action bars")
end)
