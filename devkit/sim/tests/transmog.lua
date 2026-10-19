-- Transmog: the Transmogrifier window, outfits, the collection, tooltips, /outfit and links.
-- The realm side is src/game/OpenVanilla/Transmog.cpp (patch 0011); the lines here follow its header.
local T, api = ...

local CHEST, ROBE, HELM, SWORD, BOOTS = 2470, 2471, 2472, 2473, 2474

local function tm(opts)
    opts = opts or {}
    opts.latency = false
    opts.class = opts.class or "WARRIOR"
    local env = T.addon("Transmog", opts)
    api.add_item(env, CHEST, { name = "Reinforced Plate Chest", quality = 2, icon = "Interface\\Icons\\INV_Chest_Plate01", equip = "INVTYPE_CHEST" })
    api.add_item(env, ROBE, { name = "Court Robe", quality = 3, icon = "Interface\\Icons\\INV_Chest_Cloth_17", equip = "INVTYPE_ROBE" })
    api.add_item(env, HELM, { name = "Plate Helm", quality = 2, icon = "Interface\\Icons\\INV_Helmet_01", equip = "INVTYPE_HEAD" })
    api.add_item(env, SWORD, { name = "Sword of Courts", quality = 4, icon = "Interface\\Icons\\INV_Sword_04", equip = "INVTYPE_WEAPON" })
    api.add_item(env, BOOTS, { name = "Old Boots", quality = 1, icon = "Interface\\Icons\\INV_Boots_01", equip = "INVTYPE_FEET" })
    env.__inventory[5] = CHEST          -- chest (equipment slot 4)
    env.__inventory[1] = HELM           -- head (slot 0)
    env.__inventory[16] = SWORD         -- main hand (slot 15)
    return env
end

local function hello(env, line)
    api.connect(env)
    api.tick(env, 1)
    api.server_packet(env, "TM", line or "on,2,50,1,10000,1")
    api.server_packet(env, "TM", "outfits;1,Outfit 1,0,0,0;2,Court,2471,4097,0")
end

local function sent(env) api.tick(env, 2); api.pump(env); return table.concat(env.__wnl, " | ") end
local function texts(env) return table.concat(api.visible_texts(env, env.TransmogFrame), " | ") end
local function has(list, x) for _, v in ipairs(list) do if v == x then return true end end return false end
-- the grid cell showing an item (or "hide", or an illusion's enchantment), clicked like a player would
local function clickCell(env, what)
    for _, c in ipairs(env.Transmog.cells) do
        local e = c.entry
        if e and c:IsVisible() and ((what == "hide" and e.kind == "hide") or e.item == what or
            (type(what) == "table" and e.enchant == what[1])) then
            api.click(c)
            return c
        end
    end
    error("no visible cell for " .. tostring(what))
end

T.test("Transmog: asks the realm once connected; off realms show the window under a notice", function()
    local env = tm()
    api.connect(env)
    api.tick(env, 1)
    T.has(sent(env), "tm hi")
    api.server_packet(env, "TM", "off")
    env.__slash("/transmog")
    T.shown(env.TransmogFrame, "the window opens (it is a tab of Collections)")
    T.shown(env.TransmogOffNotice, "under the notice")
    T.ok(api.screen_has(env, "Appearances aren't on for this realm", env.TransmogFrame))
    -- the realm turns it on: the notice lifts and the window asks for what it shows
    api.server_packet(env, "TM", "on,2,50,0,0,1")
    T.hidden(env.TransmogOffNotice, "the realm said hello: the notice goes")
    T.has(sent(env), "tm known")
end)

T.test("Transmog: the window lists the outfits, the locked slot's price, and asks for what it shows", function()
    local env = tm()
    hello(env)
    env.__slash("/transmog")
    T.shown(env.TransmogFrame)
    local s = sent(env)
    T.has(s, "tm known")
    T.has(s, "tm outfit 1")
    T.has(s, "tm col 0")
    local t = texts(env)
    T.has(t, "Outfit 1")
    T.has(t, "Court")
    T.has(t, "Locked outfit slot")
    T.has(t, "Active")
    T.has(t, "Resting, Morning")      -- the Court outfit's situations, on its card
    T.has(t, "2/50")
    T.has(t, "Transmogrifier")
end)

T.test("Transmog: pick a slot, click a collected look: it previews, glows, costs, and Apply saves it", function()
    local env = tm()
    hello(env)
    env.__slash("/transmog")
    api.server_packet(env, "TM", "outfit,1")
    api.click(env.TransmogSlotChestSlot)
    T.has(sent(env), "tm col 4")
    api.server_packet(env, "TM", "col,4;" .. ROBE .. ",900,1;" .. CHEST .. ",901,1")
    local looks = 0
    for _, e in ipairs(env.Transmog.CellEntries()) do if e.kind == "look" then looks = looks + 1 end end
    T.eq(looks, 2, "two collected appearances in the grid")
    clickCell(env, ROBE)
    T.ok(has(api.model_items(env.TransmogModel), ROBE), "the model wears the robe")
    T.ok(not api.model_dressed(env.TransmogModel), "previews start undressed, so hidden slots can show")
    T.shown(env.TransmogSlotChestSlot.glow)
    api.tick(env, 1)
    T.has(sent(env), "tm cost 1 4:" .. ROBE .. ":0")
    api.server_packet(env, "TM", "cost,1,25000")
    T.has(texts(env), "Free: your first saved outfit")
    api.click_text(env, "Apply", env.TransmogFrame)
    T.has(sent(env), "tm save 1 4:" .. ROBE .. ":0")
    api.server_packet(env, "TM", "saved,1,0")
    T.has(api.chat_text(env), "Outfit saved")
    T.has(sent(env), "tm outfit 1")
    api.server_packet(env, "TM", "outfit,1;4:" .. ROBE .. ":0")
    T.hidden(env.TransmogSlotChestSlot.glow, "saved: no longer pending")
end)

T.test("Transmog: Hidden is free, right-click undoes a slot, and hidden slots aren't put on the model", function()
    local env = tm()
    hello(env, "on,2,50,1,10000,0")
    env.__slash("/transmog")
    api.server_packet(env, "TM", "outfit,1")
    api.click(env.TransmogSlotHeadSlot)
    api.server_packet(env, "TM", "col,0;" .. HELM .. ",950,1")
    clickCell(env, "hide")
    T.shown(env.TransmogSlotHeadSlot.hidden)
    T.ok(not has(api.model_items(env.TransmogModel), HELM), "the helm is off the model")
    T.ok(has(api.model_items(env.TransmogModel), CHEST), "the rest is still worn")
    api.tick(env, 1)
    T.has(sent(env), "tm cost 1 0:-1:0")
    api.click(env.TransmogSlotHeadSlot, "RightButton")
    T.hidden(env.TransmogSlotHeadSlot.hidden)
    T.ok(has(api.model_items(env.TransmogModel), HELM), "the helm is back")
end)

T.test("Transmog: outfits switch for free from the list and with /outfit, by number or name", function()
    local env = tm()
    hello(env)
    env.__slash("/transmog")
    api.click_text(env, "Court", env.TransmogFrame)
    T.has(sent(env), "tm use 2")
    env.__slash("/outfit 0")
    T.has(sent(env), "tm use 0")
    env.__slash("/outfit court")
    local n = 0
    for _, l in ipairs(env.__wnl) do if l == "tm use 2" then n = n + 1 end end
    T.eq(n, 2, "by name too")
    env.__slash("/outfit 9")
    T.has(api.chat_text(env), "/outfit 0-2")
    api.server_packet(env, "TM", "active,2,1")
    T.has(api.chat_text(env), "Situation: now wearing Court")
end)

T.test("Transmog: the Situations tab shows and saves the outfit's conditions", function()
    local env = tm()
    hello(env)
    env.__slash("/transmog")
    api.click_text(env, "Court", env.TransmogFrame)
    api.click_text(env, "Situations", env.TransmogFrame)
    T.has(texts(env), "every category you tick")
    T.has(texts(env), "Resting")
    api.click_text(env, "Save situations", env.TransmogFrame)
    T.has(sent(env), "tm situ 2 4097")      -- resting + morning, as the realm sent it
end)

T.test("Transmog: weapons get illusions; a look the class can't use is marked and refused", function()
    local env = tm()
    hello(env)
    env.__slash("/transmog")
    api.server_packet(env, "TM", "outfit,1")
    api.click(env.TransmogSlotMainHandSlot)
    api.server_packet(env, "TM", "col,15;" .. SWORD .. ",960,0")
    clickCell(env, SWORD)
    T.has(api.chat_text(env), "can't use that appearance")
    api.click_text(env, "Filter", env.TransmogFrame)
    api.click_text(env, "Illusions", env.WenillaCore_Menu)
    T.has(sent(env), "tm ill")
    api.server_packet(env, "TM", "ill;1900,26,Crusader")
    clickCell(env, { 1900 })
    T.shown(env.TransmogSlotMainHandSlot.ill)
    api.tick(env, 1)
    T.has(sent(env), "tm cost 1 15:0:1900")
end)

T.test("Transmog: tooltips say whether a look is collected", function()
    local env = tm()
    hello(env)
    api.give_item(env, BOOTS, 1, 0, 1)
    env.GameTooltip:SetOwner(env.UIParent, "ANCHOR_NONE")
    env.GameTooltip:SetBagItem(0, 1)
    T.has(sent(env), "tm look " .. BOOTS)
    api.server_packet(env, "TM", "look," .. BOOTS .. ",0,1")
    env.GameTooltip:SetBagItem(0, 1)
    T.has(table.concat(api.visible_texts(env, env.GameTooltip), " | "), "You haven't collected this appearance")
    api.server_packet(env, "TM", "look," .. BOOTS .. ",1,1")
    env.GameTooltip:SetBagItem(0, 1)
    T.has(table.concat(api.visible_texts(env, env.GameTooltip), " | "), "but not from this item")
    api.server_packet(env, "TM", "new," .. BOOTS .. ",977")
    T.has(api.chat_text(env), "Appearance added to your collection")
    env.GameTooltip:SetBagItem(0, 1)
    T.no(string.find(table.concat(api.visible_texts(env, env.GameTooltip), " | "), "collected this appearance", 1, true))
end)

T.test("Transmog: talking to a Transmogrifier opens the window; links open a preview", function()
    local env = tm()
    hello(env)
    api.set_unit(env, "npc", { name = "Morga Silkhand" })
    api.fire(env, "GOSSIP_SHOW")
    T.shown(env.TransmogFrame)
    T.no(string.find(texts(env), "Browsing", 1, true), "at a Transmogrifier: no browsing note")
    local line = env.Transmog.RewriteLink("look: " .. env.Transmog.LinkText("Court", "4:" .. ROBE .. ":0/0:-1:0"))
    T.has(line, "|Hovlook:4:" .. ROBE .. ":0/0:-1:0|h[Look: Court]|h")
    env.SetItemRef("ovlook:4:" .. ROBE .. ":0/0:-1:0", "[Look: Court]", "LeftButton")
    T.ok(has(api.model_items(env.TransmogModel), ROBE), "the linked look is on the model")
end)

T.test("Transmog: sets show how much is collected and Use puts on the collected pieces", function()
    local env = tm()
    hello(env)
    env.__slash("/transmog")
    api.server_packet(env, "TM", "outfit,1")
    api.server_packet(env, "TM", "known;" .. HELM .. ",950")
    api.click_text(env, "Sets", env.TransmogFrame)
    T.has(sent(env), "tm sets")
    api.server_packet(env, "TM", "sets;201,Battlegear of Might,1,2," .. HELM .. "/" .. BOOTS)
    T.has(texts(env), "Battlegear of Might")
    T.has(texts(env), "1/2")
    api.click_text(env, "Use", env.TransmogFrame)
    api.tick(env, 1)
    T.has(sent(env), "tm cost 1 0:" .. HELM .. ":0")
end)

T.test("Transmog: custom sets save the current look and link it", function()
    local env = tm()
    hello(env)
    env.__slash("/transmog")
    api.click_text(env, "Custom Sets", env.TransmogFrame)
    T.has(sent(env), "tm cset list")
    api.server_packet(env, "TM", "csets;3,Ball gown,4:" .. ROBE .. ":0/0:-1:0")
    api.click_text(env, "Ball gown", env.TransmogFrame)
    T.ok(has(api.model_items(env.TransmogModel), ROBE), "previewed")
    api.click_text(env, "Link", env.TransmogFrame)
    T.has(env.ChatFrameEditBox:GetText() or "", "[Look: Ball gown]{ov:4:" .. ROBE .. ":0/0:-1:0}")
end)

T.test("Transmog: unlocking a slot asks the realm and announces it", function()
    local env = tm()
    hello(env)
    env.__slash("/transmog")
    api.click_text(env, "Locked outfit slot", env.TransmogFrame)
    api.click_text(env, "Unlock for", env.WenillaCore_Menu)
    T.has(sent(env), "tm unlock")
    api.server_packet(env, "TM", "unlocked,3,20000")
    T.has(api.chat_text(env), "Outfit slot 3 unlocked")
end)

T.test("Transmog: errors are explained and malformed lines never raise", function()
    local env = tm()
    hello(env)
    env.__slash("/transmog")
    api.server_packet(env, "TM", "err,npc")
    T.has(api.chat_text(env), "Talk to a Transmogrifier")
    for _, body in ipairs({ "", "on", "outfits;;;", "outfit,x;1:2", "col", "col,4;a,b,c", "known;;", "look",
                            "ill;x", "sets;1", "csets;a", "cost", "saved", "active", "unlocked", "situ,9,9",
                            "new", "new,1", "newill", "err", "x;y;z", "1,2,3,4,5,6,7,8,9" }) do
        api.server_packet(env, "TM", body)
    end
    for _, k in ipairs({ "items", "sets", "csets", "situations" }) do env.Transmog:SelectTab(k) end
end)

T.test("Transmog: the dressing room shows the player's race backdrop and turns with the rotate buttons", function()
    local env = tm({ race = "Troll" })
    hello(env)
    env.__slash("/transmog")
    local found
    local mid = env.TransmogModel:GetParent()
    for _, t in ipairs(mid.backdrop) do
        T.has(t:GetTexture(), "DressUpBackground-Orc", "trolls use the orcish backdrop, as the stock dressing room")
        found = true
    end
    T.ok(found, "the backdrop is built")
    local right = env.Transmog.rotateButtons[2]
    api.run_script(right, "OnMouseDown")
    api.tick(env, 0.5)
    api.run_script(right, "OnMouseUp")
    local r = api.state(env.TransmogModel).rotation or 0
    T.ok(r > 0.5, "holding the right button turns the model (got " .. r .. ")")
    api.tick(env, 0.5)
    T.eq(api.state(env.TransmogModel).rotation, r, "and it stops when released")
end)

T.test("Transmog: where one dressing room draws (wenilla), the grid shows icons; empty slots say so", function()
    local env = tm()
    env.OPENVANILLA_ONE_DRESSING_ROOM = 1
    hello(env)
    env.__slash("/transmog")
    api.server_packet(env, "TM", "outfit,1")
    api.click(env.TransmogSlotChestSlot)
    api.server_packet(env, "TM", "col,4;" .. ROBE .. ",900,1")
    T.ok(env.Transmog.CellIcons(), "icon cells")
    local shownModels = 0
    for _, f in ipairs(env.__frames) do
        local s = api.state(f)
        if s.otype == "DressUpModel" and f ~= env.TransmogModel and api.is_visible(f) then shownModels = shownModels + 1 end
    end
    T.eq(shownModels, 0, "no cell models drawn")
    api.click(env.TransmogSlotTabardSlot)
    api.server_packet(env, "TM", "col,18")
    T.has(texts(env), "No appearances collected for this slot yet")
end)
