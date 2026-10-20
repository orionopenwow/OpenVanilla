--[[
    Tooltip.lua  -  Quests: quest progress on mob and item tooltips.

    Mouse over a creature or an item one of your quests asks for and the tooltip gains the quest
    and your progress:   Kobold Camp Cleanup
                           Kobold Vermin: 4/8
    Matching is by name against the quest log's objective text, so it needs no quest database;
    item ids from the realm's CP packets (OBJ:i<itemId>) also match.
]]--

local W = WenillaCore
local Q = Compass

-- Objectives whose target is `name`: { { quest, objective }, ... }
function Q:ObjectivesFor(name, itemId)
    local out = {}
    if not name or name == "" then return out end
    local low = string.lower(name)
    for _, q in ipairs(self.quests) do
        for _, o in ipairs(q.objectives) do
            local on = string.lower(o.name or "")
            if on ~= "" and (on == low or on == low .. "s" or low == on .. "s") then
                table.insert(out, { q, o })
            end
        end
        if itemId and self.itemIds[itemId] == q.title then
            local found = false
            for _, e in ipairs(out) do if e[1] == q then found = true end end
            if not found and q.objectives[1] then table.insert(out, { q, q.objectives[1] }) end
        end
    end
    return out
end

function Q:AddQuestLines(tip, name, itemId)
    if not self:Active() or not self:Get("tooltips") then return false end
    local hits = self:ObjectivesFor(name, itemId)
    if not hits[1] then return false end
    local lastQuest
    for _, h in ipairs(hits) do
        local q, o = h[1], h[2]
        if q ~= lastQuest then
            tip:AddLine(q.title, self:DiffColor(q.level))
            lastQuest = q
        end
        local text = "  " .. o.name .. ": " .. o.have .. "/" .. o.need
        if o.done then tip:AddLine(text, 0.5, 0.8, 0.5) else tip:AddLine(text, 1, 1, 1) end
    end
    tip:Show()
    return true
end

-- Creatures: the stock tooltip is filled by the engine, then UPDATE_MOUSEOVER_UNIT fires.
Q:On("UPDATE_MOUSEOVER_UNIT", function()
    if not UnitExists("mouseover") or UnitIsPlayer("mouseover") then return end
    Q:AddQuestLines(GameTooltip, UnitName("mouseover"))
end)

-- Items: wrap the tooltip's item setters (the original runs first).
local function linkInfo(link)
    if not link then return nil end
    local _, _, id = string.find(link, "item:(%d+)")
    local _, _, name = string.find(link, "%[(.-)%]")
    return name, tonumber(id)
end

local function hook(method, linkOf)
    local original = GameTooltip[method]
    if not original then return end
    GameTooltip[method] = function(self, a1, a2, a3)
        local r1, r2, r3 = original(self, a1, a2, a3)
        local link = linkOf(a1, a2, a3)
        local name, id = linkInfo(link)
        if name then Q:AddQuestLines(self, name, id) end
        return r1, r2, r3
    end
end

hook("SetBagItem", function(bag, slot) return GetContainerItemLink(bag, slot) end)
hook("SetHyperlink", function(link) return link end)
hook("SetLootItem", function(slot) return GetLootSlotLink(slot) end)
hook("SetMerchantItem", function(i) return GetMerchantItemLink(i) end)
hook("SetAuctionItem", function(kind, i) return GetAuctionItemLink(kind, i) end)
hook("SetInventoryItem", function(unit, slot) return GetInventoryItemLink(unit, slot) end)
