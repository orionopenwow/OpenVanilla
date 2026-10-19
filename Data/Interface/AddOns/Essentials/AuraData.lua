--[[
    AuraData.lua  (Essentials)
    How long common 1.12.1 buffs and debuffs last, in seconds, by the name the tooltip shows.
    The 1.12 client tells addons nothing about other units' aura durations, so Essentials
    starts a timer when the combat log (or the aura list) shows an aura going on and counts
    down from these numbers. Values are the highest rank's base duration without talents;
    combo-point finishers use five points. In PvP, diminishing returns shorten crowd control,
    so treat the numbers as estimates.
]]--

Essentials = Essentials or {}

Essentials.AURA_DURATIONS = {
    -- Warrior
    ["Rend"] = 21, ["Hamstring"] = 15, ["Thunder Clap"] = 30, ["Demoralizing Shout"] = 30,
    ["Sunder Armor"] = 30, ["Mocking Blow"] = 6, ["Intimidating Shout"] = 8, ["Piercing Howl"] = 6,
    ["Disarm"] = 10, ["Concussion Blow"] = 5, ["Charge Stun"] = 1, ["Intercept Stun"] = 3,
    ["Mortal Strike"] = 10, ["Challenging Shout"] = 6, ["Taunt"] = 3, ["Deep Wound"] = 12,
    ["Revenge Stun"] = 3, ["Mace Stun Effect"] = 3, ["Improved Hamstring"] = 5,
    ["Battle Shout"] = 120, ["Bloodrage"] = 10, ["Berserker Rage"] = 10, ["Shield Wall"] = 10,
    ["Recklessness"] = 15, ["Retaliation"] = 15, ["Last Stand"] = 20, ["Sweeping Strikes"] = 20,
    ["Death Wish"] = 30, ["Shield Block"] = 5,
    -- Rogue
    ["Sap"] = 45, ["Gouge"] = 4, ["Blind"] = 10, ["Cheap Shot"] = 4, ["Kidney Shot"] = 6,
    ["Garrote"] = 18, ["Rupture"] = 16, ["Expose Armor"] = 30, ["Crippling Poison"] = 12,
    ["Deadly Poison"] = 12, ["Deadly Poison II"] = 12, ["Deadly Poison III"] = 12, ["Deadly Poison IV"] = 12,
    ["Deadly Poison V"] = 12, ["Mind-numbing Poison"] = 10, ["Mind-numbing Poison II"] = 12,
    ["Mind-numbing Poison III"] = 14, ["Wound Poison"] = 15, ["Hemorrhage"] = 15, ["Distract"] = 10,
    ["Riposte"] = 6, ["Kick - Silenced"] = 2, ["Slice and Dice"] = 21, ["Evasion"] = 15, ["Sprint"] = 15,
    ["Adrenaline Rush"] = 15, ["Blade Flurry"] = 15,
    -- Mage
    ["Polymorph"] = 50, ["Polymorph: Pig"] = 50, ["Polymorph: Turtle"] = 50, ["Frost Nova"] = 8,
    ["Frostbolt"] = 9, ["Cone of Cold"] = 8, ["Frostbite"] = 5, ["Counterspell - Silenced"] = 4,
    ["Fireball"] = 8, ["Pyroblast"] = 12, ["Ignite"] = 4, ["Fire Vulnerability"] = 30,
    ["Winter's Chill"] = 15, ["Impact"] = 2, ["Blast Wave"] = 6, ["Flamestrike"] = 8, ["Chilled"] = 5,
    ["Arcane Intellect"] = 1800, ["Arcane Brilliance"] = 3600, ["Dampen Magic"] = 600,
    ["Amplify Magic"] = 600, ["Ice Barrier"] = 60, ["Mana Shield"] = 60, ["Frost Armor"] = 1800,
    ["Ice Armor"] = 1800, ["Mage Armor"] = 1800, ["Ice Block"] = 10, ["Arcane Power"] = 15,
    ["Combustion"] = 15, ["Presence of Mind"] = 15, ["Fire Ward"] = 30, ["Frost Ward"] = 30,
    -- Warlock
    ["Corruption"] = 18, ["Curse of Agony"] = 24, ["Immolate"] = 15, ["Siphon Life"] = 30,
    ["Fear"] = 20, ["Howl of Terror"] = 15, ["Death Coil"] = 3, ["Curse of Weakness"] = 120,
    ["Curse of Recklessness"] = 120, ["Curse of the Elements"] = 300, ["Curse of Shadow"] = 300,
    ["Curse of Tongues"] = 30, ["Curse of Exhaustion"] = 12, ["Curse of Doom"] = 60, ["Banish"] = 30,
    ["Seduction"] = 15, ["Enslave Demon"] = 300, ["Shadow Vulnerability"] = 12, ["Spell Lock"] = 3,
    ["Inferno Effect"] = 2, ["Shadowburn"] = 5, ["Drain Life"] = 5, ["Drain Mana"] = 5, ["Drain Soul"] = 15,
    ["Hellfire Effect"] = 15, ["Demon Skin"] = 1800, ["Demon Armor"] = 1800, ["Shadow Ward"] = 30,
    ["Unending Breath"] = 600, ["Detect Invisibility"] = 600, ["Sacrifice"] = 30, ["Amplify Curse"] = 30,
    -- Priest
    ["Shadow Word: Pain"] = 18, ["Psychic Scream"] = 8, ["Mind Soothe"] = 15, ["Mind Control"] = 60,
    ["Shackle Undead"] = 50, ["Devouring Plague"] = 24, ["Vampiric Embrace"] = 60, ["Mind Flay"] = 3,
    ["Silence"] = 5, ["Blackout"] = 3, ["Hex of Weakness"] = 120, ["Weakened Soul"] = 15,
    ["Holy Fire"] = 10, ["Touch of Weakness"] = 120, ["Mind Vision"] = 60,
    ["Power Word: Shield"] = 30, ["Renew"] = 15, ["Power Word: Fortitude"] = 1800,
    ["Prayer of Fortitude"] = 3600, ["Divine Spirit"] = 1800, ["Prayer of Spirit"] = 3600,
    ["Shadow Protection"] = 600, ["Prayer of Shadow Protection"] = 1200, ["Fear Ward"] = 600,
    ["Inner Fire"] = 600, ["Power Infusion"] = 15, ["Abolish Disease"] = 20, ["Inspiration"] = 15,
    ["Elune's Grace"] = 15, ["Feedback"] = 15, ["Shadowguard"] = 600, ["Levitate"] = 120,
    -- Druid
    ["Moonfire"] = 12, ["Insect Swarm"] = 12, ["Rake"] = 9, ["Rip"] = 12, ["Entangling Roots"] = 27,
    ["Hibernate"] = 40, ["Bash"] = 4, ["Pounce"] = 2, ["Pounce Bleed"] = 18, ["Faerie Fire"] = 40,
    ["Faerie Fire (Feral)"] = 40, ["Demoralizing Roar"] = 30, ["Challenging Roar"] = 6, ["Growl"] = 3,
    ["Feral Charge Effect"] = 4, ["Soothe Animal"] = 15, ["Starfire Stun"] = 3,
    ["Rejuvenation"] = 12, ["Regrowth"] = 21, ["Abolish Poison"] = 8, ["Mark of the Wild"] = 1800,
    ["Gift of the Wild"] = 3600, ["Thorns"] = 600, ["Barkskin"] = 15, ["Innervate"] = 20,
    ["Nature's Grasp"] = 45, ["Dash"] = 15, ["Frenzied Regeneration"] = 10, ["Tiger's Fury"] = 6,
    ["Tranquility"] = 10, ["Hurricane"] = 10,
    -- Hunter
    ["Serpent Sting"] = 15, ["Viper Sting"] = 8, ["Scorpid Sting"] = 20, ["Wyvern Sting"] = 12,
    ["Hunter's Mark"] = 120, ["Concussive Shot"] = 4, ["Freezing Trap Effect"] = 20,
    ["Immolation Trap Effect"] = 15, ["Explosive Trap Effect"] = 20, ["Frost Trap Aura"] = 30,
    ["Wing Clip"] = 10, ["Improved Wing Clip"] = 5, ["Counterattack"] = 5, ["Scatter Shot"] = 4,
    ["Intimidation"] = 3, ["Scare Beast"] = 20, ["Entrapment"] = 5, ["Improved Concussive Shot"] = 3,
    ["Rapid Fire"] = 15, ["Deterrence"] = 10, ["Trueshot Aura"] = 1800, ["Bestial Wrath"] = 18,
    ["Mend Pet"] = 15, ["Eyes of the Beast"] = 60, ["Flare"] = 30,
    -- Paladin
    ["Hammer of Justice"] = 6, ["Repentance"] = 6, ["Judgement of the Crusader"] = 10,
    ["Judgement of Light"] = 10, ["Judgement of Wisdom"] = 10, ["Judgement of Justice"] = 10,
    ["Turn Undead"] = 20, ["Forbearance"] = 60, ["Stun"] = 2,
    ["Blessing of Might"] = 300, ["Blessing of Wisdom"] = 300, ["Blessing of Kings"] = 300,
    ["Blessing of Salvation"] = 300, ["Blessing of Sanctuary"] = 300, ["Blessing of Light"] = 300,
    ["Greater Blessing of Might"] = 900, ["Greater Blessing of Wisdom"] = 900,
    ["Greater Blessing of Kings"] = 900, ["Greater Blessing of Salvation"] = 900,
    ["Greater Blessing of Sanctuary"] = 900, ["Greater Blessing of Light"] = 900,
    ["Blessing of Protection"] = 10, ["Blessing of Freedom"] = 10, ["Blessing of Sacrifice"] = 30,
    ["Divine Shield"] = 12, ["Divine Protection"] = 8, ["Seal of Righteousness"] = 30,
    ["Seal of the Crusader"] = 30, ["Seal of Command"] = 30, ["Seal of Light"] = 30,
    ["Seal of Wisdom"] = 30, ["Seal of Justice"] = 30, ["Vengeance"] = 8, ["Holy Shield"] = 10,
    -- Shaman
    ["Flame Shock"] = 12, ["Frost Shock"] = 8, ["Stormstrike"] = 12, ["Healing Way"] = 15,
    ["Lightning Shield"] = 600, ["Rockbiter"] = 300, ["Water Breathing"] = 600, ["Water Walking"] = 600,
    ["Ancestral Fortitude"] = 15, ["Clearcasting"] = 15,
    -- Racials and items
    ["War Stomp"] = 2, ["Berserking"] = 10, ["Blood Fury"] = 25, ["Will of the Forsaken"] = 5,
    ["Stoneform"] = 8, ["Perception"] = 20, ["Net-o-Matic"] = 10,
    ["Tidal Charm"] = 3, ["Iron Grenade"] = 3, ["Thorium Grenade"] = 3, ["Goblin Rocket Helmet"] = 30,
    ["Reckless Charge"] = 30, ["First Aid"] = 8, ["Recently Bandaged"] = 60,
}

-- Debuffs whose duration depends on combo points: the five-point value is above; these are the
-- one- to five-point steps for reference by anyone tuning the table.
Essentials.COMBO_DURATIONS = {
    ["Kidney Shot"] = { 2, 3, 4, 5, 6 }, ["Rupture"] = { 8, 10, 12, 14, 16 },
    ["Slice and Dice"] = { 9, 12, 15, 18, 21 },
}
