--[[
    Bars.lua  (Duels)
    A new duel body arrives ready to fight: all four extra action bars are switched on and the class's
    PvP abilities are put on them, once per character (DuelsBars.done). Only empty buttons are filled,
    so a player's own layout is never touched; "/duels bars" lays them out again on empty buttons and
    "/duels bars reset" clears the bars first.

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
        main = { "Wrath", "Moonfire", "Entangling Roots", "Healing Touch", "Regrowth", "Rejuvenation", "Bear Form",
                 "Cat Form", "Travel Form", "Bash", "Hibernate", "Innervate" },
        left = { "Mark of the Wild", "Thorns", "Barkskin", "Nature's Grasp", "Remove Curse", "Abolish Poison",
                 "Faerie Fire", "Starfire", "Swiftmend", "Nature's Swiftness", "Feral Charge", "Dash" },
    },
}

-- spell name -> its highest-ranked spellbook index
local function spellbook()
    local book, i = {}, 1
    while true do
        local name = GetSpellName(i, BOOKTYPE_SPELL)
        if not name then break end
        book[name] = i            -- later entries are higher ranks
        i = i + 1
    end
    return book
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
                local idx = list[i] and book[list[i]]
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
    if DuelsBars.done then return false end
    local n = D.LayOutBars(false)
    DuelsBars.done = 1
    if n > 0 and D.Say then D.Say("Your bars are ready: " .. n .. " abilities placed. /duels bars lays them out again.") end
    return true
end
