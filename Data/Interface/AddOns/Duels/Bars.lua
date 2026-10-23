--[[
    Bars.lua  (Duels)
    A new duel body arrives ready to fight: all four extra action bars are switched on and the class's
    PvP abilities are put on them, once per character (DuelsBars.done; the starter buttons are cleared
    first). Later only empty buttons are filled, so a player's own layout is never touched; "/duels bars"
    lays them out again on empty buttons and "/duels bars reset" clears the bars first. Spells learned
    a moment later are placed too (two minutes), and a lower rank on any bar becomes the best one.

    Buttons: main bar 1-12 (keys 1 to =), bottom left 61-72, bottom right 49-60.
    A spell the character doesn't know is skipped. The highest rank in the spellbook is used.
    Lua 5.0 rules: no #, no %.
]]--

local W = WenillaCore
local D = Duels

DuelsBars = DuelsBars or {}

D.BAR_SLOTS = { main = 1, left = 61, right = 49 }

-- the abilities each class fights with, in the order they go on the buttons
D.LAYOUTS = {
    WARRIOR = {
        main = { "Charge", "Intercept", "Mortal Strike", "Overpower", "Hamstring", "Pummel", "Shield Bash", "Execute",
                 "Whirlwind", "Intimidating Shout", "Berserker Rage", "Bloodrage" },
        left = { "Battle Stance", "Defensive Stance", "Berserker Stance", "Disarm", "Shield Wall", "Recklessness",
                 "Retaliation", "Piercing Howl", "Sweeping Strikes", "Heroic Strike", "Rend", "Death Wish" },
    },
    ROGUE = {
        main = { "Sinister Strike", "Backstab", "Eviscerate", "Kidney Shot", "Cheap Shot", "Gouge", "Kick", "Blind",
                 "Vanish", "Sprint", "Evasion", "Stealth" },
        left = { "Sap", "Ambush", "Garrote", "Slice and Dice", "Expose Armor", "Distract", "Preparation", "Cold Blood",
                 "Premeditation", "Feint", "Rupture", "Hemorrhage" },
    },
    MAGE = {
        main = { "Frostbolt", "Fire Blast", "Frost Nova", "Polymorph", "Counterspell", "Blink", "Cone of Cold",
                 "Ice Block", "Arcane Explosion", "Fireball", "Ice Barrier", "Cold Snap" },
        left = { "Mana Shield", "Frost Ward", "Fire Ward", "Arcane Intellect", "Ice Armor", "Remove Lesser Curse",
                 "Evocation", "Presence of Mind", "Arcane Power", "Scorch", "Pyroblast", "Slow Fall" },
    },
    PRIEST = {
        main = { "Flash Heal", "Greater Heal", "Power Word: Shield", "Renew", "Psychic Scream", "Shadow Word: Pain",
                 "Mind Blast", "Mana Burn", "Dispel Magic", "Fade", "Silence", "Inner Fire" },
        left = { "Power Word: Fortitude", "Mind Control", "Shadowform", "Vampiric Embrace", "Mind Flay",
                 "Abolish Disease", "Holy Fire", "Smite", "Desperate Prayer", "Inner Focus", "Power Infusion",
                 "Shadow Protection" },
    },
    WARLOCK = {
        main = { "Shadow Bolt", "Corruption", "Curse of Agony", "Immolate", "Fear", "Death Coil", "Howl of Terror",
                 "Drain Life", "Life Tap", "Shadowburn", "Curse of Exhaustion", "Curse of Tongues" },
        left = { "Siphon Life", "Conflagrate", "Demon Armor", "Health Funnel", "Create Healthstone", "Shadow Ward",
                 "Searing Pain", "Summon Felhunter", "Summon Succubus", "Summon Voidwalker", "Banish", "Drain Mana" },
    },
    HUNTER = {
        main = { "Auto Shot", "Aimed Shot", "Multi-Shot", "Arcane Shot", "Serpent Sting", "Viper Sting",
                 "Concussive Shot", "Wing Clip", "Scatter Shot", "Freezing Trap", "Feign Death", "Raptor Strike" },
        left = { "Aspect of the Hawk", "Aspect of the Cheetah", "Aspect of the Monkey", "Hunter's Mark", "Rapid Fire",
                 "Disengage", "Deterrence", "Intimidation", "Mongoose Bite", "Frost Trap", "Tranquilizing Shot",
                 "Mend Pet" },
    },
    PALADIN = {
        main = { "Holy Light", "Flash of Light", "Hammer of Justice", "Judgement", "Seal of Righteousness",
                 "Seal of Command", "Seal of the Crusader", "Cleanse", "Blessing of Freedom", "Blessing of Protection",
                 "Divine Shield", "Lay on Hands" },
        left = { "Blessing of Might", "Blessing of Wisdom", "Blessing of Kings", "Seal of Justice", "Seal of Wisdom",
                 "Holy Shock", "Consecration", "Exorcism", "Hammer of Wrath", "Repentance", "Devotion Aura",
                 "Retribution Aura" },
    },
    SHAMAN = {
        main = { "Lightning Bolt", "Chain Lightning", "Earth Shock", "Frost Shock", "Flame Shock", "Purge",
                 "Grounding Totem", "Healing Wave", "Lesser Healing Wave", "Ghost Wolf", "Windfury Weapon", "Stormstrike" },
        left = { "Earthbind Totem", "Tremor Totem", "Poison Cleansing Totem", "Windfury Totem", "Mana Spring Totem",
                 "Strength of Earth Totem", "Stoneskin Totem", "Lightning Shield", "Rockbiter Weapon",
                 "Elemental Mastery", "Nature's Swiftness", "Cure Poison" },
    },
    DRUID = {
        main = { "Wrath", "Moonfire", "Entangling Roots", "Healing Touch", "Regrowth", "Rejuvenation", "Dire Bear Form|Bear Form",
                 "Cat Form", "Travel Form", "Bash", "Hibernate", "Innervate" },
        left = { "Mark of the Wild", "Thorns", "Barkskin", "Nature's Grasp", "Remove Curse", "Abolish Poison",
                 "Faerie Fire", "Starfire", "Swiftmend", "Nature's Swiftness", "Feral Charge", "Dash" },
    },
}

-- spell name -> its highest-ranked spellbook index (and that rank's text)
local function spellbook()
    local book, ranks, i = {}, {}, 1
    while true do
        local name, rank = GetSpellName(i, BOOKTYPE_SPELL)
        if not name then break end
        book[name] = i            -- later entries are higher ranks
        ranks[name] = rank or ""
        i = i + 1
    end
    return book, ranks
end

-- a hidden tooltip reads what spell (and rank) sits on an action slot
local scan
local function slotSpell(slot)
    if not scan then
        scan = CreateFrame("GameTooltip", "DuelsBarScan", UIParent, "GameTooltipTemplate")
        if scan.SetOwner then scan:SetOwner(UIParent, "ANCHOR_NONE") end
    end
    if scan.ClearLines then scan:ClearLines() end
    if scan.SetOwner then scan:SetOwner(UIParent, "ANCHOR_NONE") end
    scan:SetAction(slot)
    local l, r = getglobal("DuelsBarScanTextLeft1"), getglobal("DuelsBarScanTextRight1")
    local name = l and l:GetText()
    local rank = r and r:GetText()
    return name, rank
end

-- every action slot holding a spell at a lower rank than the spellbook's best: the best goes there
-- (1.12 leaves the old rank on the bar when you learn a new one). Returns how many changed.
function D.UpgradeRanks()
    local book, ranks = spellbook()
    local n = 0
    for slot = 1, 120 do
        if HasAction(slot) and not (GetActionText and GetActionText(slot)) then
            local name, rank = slotSpell(slot)
            local best = name and book[name]
            if best and ranks[name] ~= "" and rank and rank ~= "" and rank ~= ranks[name] then
                PickupSpell(best, BOOKTYPE_SPELL)
                PlaceAction(slot)
                ClearCursor()
                n = n + 1
            end
        end
    end
    return n
end

-- lay the class's abilities on empty buttons; returns how many were placed
function D.LayOutBars(reset)
    local _, class = UnitClass("player")
    local layout = D.LAYOUTS[class or ""]
    SetActionBarToggles(1, 1, 1, 1)
    SHOW_MULTI_ACTIONBAR_1, SHOW_MULTI_ACTIONBAR_2, SHOW_MULTI_ACTIONBAR_3, SHOW_MULTI_ACTIONBAR_4 = 1, 1, 1, 1
    if MultiActionBar_Update then MultiActionBar_Update() end
    if not layout then return 0 end
    local book, placed = spellbook(), 0
    for bar, first in pairs(D.BAR_SLOTS) do
        local list = layout[bar]
        if list then
            for i = 1, 12 do
                local slot = first + i - 1
                if reset and HasAction(slot) then PickupAction(slot); ClearCursor() end
                -- "Dire Bear Form|Bear Form": the first one the character knows
                local idx
                if list[i] then
                    for _, n in ipairs(W.Split(list[i], "|")) do
                        if not idx and book[n] then idx = book[n] end
                    end
                end
                if idx and not HasAction(slot) then
                    PickupSpell(idx, BOOKTYPE_SPELL)
                    PlaceAction(slot)
                    ClearCursor()
                    placed = placed + 1
                end
            end
        end
    end
    return placed
end

-- once per duel body, the first time the Duels realm says hello
function D.SetupBarsOnce()
    -- every gear set of the class into the bags, once per character (realm patch 0034), older ones too
    if not DuelsBars.bagged then D.bagsAt = GetTime() + 4 end
    if DuelsBars.done then return false end
    -- a new duel body's bars hold only the client's starter buttons (Attack, rank 1 spells): cleared
    local n = D.LayOutBars(true)
    D.UpgradeRanks()
    DuelsBars.done = 1
    D.barsAt = GetTime()
    -- and dressed: the class's first kit goes on by itself a few seconds later, after the panel's own
    -- asks (owner, 2026-10-22); the Armory changes it
    D.kitAt = GetTime() + 7
    if n > 0 and D.Say then D.Say("Your bars are ready: " .. n .. " abilities placed. /duels bars lays them out again.") end
    return true
end

-- spells learned after the first layout (the realm teaches the whole class at 60 a moment after
-- login): place the ones still missing for two minutes, and keep every bar at the best rank
local learn = CreateFrame("Frame")
learn:RegisterEvent("SPELLS_CHANGED")
learn:RegisterEvent("LEARNED_SPELL_IN_TAB")
learn:SetScript("OnEvent", function() this.due = GetTime() + 1 end)
learn:SetScript("OnUpdate", function()
    if not this.due or GetTime() < this.due or not D.on then return end
    this.due = nil
    if DuelsBars.done and D.barsAt and GetTime() - D.barsAt < 120 then D.LayOutBars(false) end
    D.UpgradeRanks()
end)

local kit = CreateFrame("Frame")
kit:SetScript("OnUpdate", function()
    if D.bagsAt and GetTime() >= D.bagsAt then
        D.bagsAt = nil
        if Warfront and Warfront.Send and Warfront.Send("kitbags") then DuelsBars.bagged = 1 end
    end
    if D.kitAt and GetTime() >= D.kitAt then
        D.kitAt = nil
        if D.Armory and D.Armory.BestKit then D.Armory.BestKit() end
    end
end)
