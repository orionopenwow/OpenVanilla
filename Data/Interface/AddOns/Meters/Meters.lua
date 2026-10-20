--[[
    Meters.lua  -  the data side of Meters (internal name Chronicle)
    A damage, healing and utility meter for you, your party/raid and your pets, in the spirit of
    Details!, built from what a 1.12 client can see.

    Two sources:
      * server  - "CH" packets from Wenilla telemetry (exact damage, whole group, no parsing).
      * local   - the 1.12 combat log (CHAT_MSG_* combat events), read with patterns built from
                  the client's own GlobalStrings, so other locales work too.
    Server damage wins in the current fight while it is arriving; local data is always recorded.

    What is tracked, per fight and overall:
      damage done (hits, crits, misses, average, largest), DPS, damage taken, healing done, HPS,
      overhealing (estimated from the target's missing health when we can see it), healing taken,
      deaths with the last 10 events before each, interrupts, dispels, crowd control applied,
      your buff and debuff uptime, mana/rage/energy gained, resurrects and friendly fire.

    Fights: the current one, the previous 25 (boss fights named and kept, trash fights merged
    into one "Trash" entry until the next boss) and the overall total.

    CH packet: "<name>,<classId>,<total>,<perSec>;..."         (current encounter, sorted)
               "inspect,<name>;<ability>,<amount>,<pct>;..."   (reply to "ch inspect")

    The windows, tabs, settings and reports live in Window.lua; the breakdown window in Detail.lua.
]]--

local W = WenillaCore
local UI = W.UI
local ID = "Meters"

Chronicle = Chronicle or {}
local C = Chronicle
C.ID = ID

local floor = math.floor
local strfind, strsub, strgsub, strlen = string.find, string.sub, string.gsub, string.len
local tinsert, tremove, getn = table.insert, table.remove, table.getn

C.mode = "dmg"            -- the main window's mode (kept up to date by Window.lua)
C.fight = nil             -- the current (or just finished) fight
C.overall = nil           -- everything since the last reset
C.history = {}            -- finished fights, newest first
C.server = nil            -- last server snapshot { list = {...}, t = time }
C.inspectData = {}
C.recap = {}              -- name -> the last events before a death
C.myAuras = {}            -- your buffs and debuffs that are up: name -> { since, harmful }
C.recent = {}             -- spell -> { who, t }: who last used it (crowd control credit)
C.hpEst = {}              -- name -> { raw, hp }: health after the heals we already counted

-- memory caps (finished fights are trimmed to these)
C.MAX_HISTORY = 25
C.RECAP = 10
C.MAX_DEATHS = 30
C.MAX_TARGETS = 12

local function me() return UnitName("player") end

-- -- Combat log patterns -------------------------------------------------------
-- { GlobalStrings name, enUS format, roles, kind, options }
-- roles: a ability, t target, s source, n amount, k school, p power type.
-- options: crit, me (the target is you), how (miss type), harm (harmful aura),
--          label (fixed ability name), src (fixed source).
-- Order matters: "you" lines before "%s" lines, spell lines before melee lines, crits and
-- school variants before plain ones, heals before power gains, aura gains last.

local CRIT, ME, CRITME = { crit = 1 }, { me = 1 }, { crit = 1, me = 1 }
local NONE = {}

local function env(label) return { me = 1, label = label, src = "Environment" } end
local function envo(label) return { label = label, src = "Environment" } end
local function miss(how, me1) return { how = how, me = me1 } end
local SHIELD, SHIELDME = { label = "Damage Shield" }, { label = "Damage Shield", me = 1 }

local TEMPLATES = {
    -- your own spells hitting you (Hellfire, Life Tap and friends)
    { "SPELLLOGCRITSCHOOLSELFSELF", "Your %s crits you for %d %s damage.", "a n k", "dmg", CRITME },
    { "SPELLLOGSCHOOLSELFSELF", "Your %s hits you for %d %s damage.", "a n k", "dmg", ME },
    { "SPELLLOGCRITSELFSELF", "Your %s crits you for %d.", "a n", "dmg", CRITME },
    { "SPELLLOGSELFSELF", "Your %s hits you for %d.", "a n", "dmg", ME },
    { "PERIODICAURADAMAGESELFSELF", "You suffer %d %s damage from your %s.", "n k a", "dmg", ME },
    -- you
    { "SPELLLOGCRITSCHOOLSELFOTHER", "Your %s crits %s for %d %s damage.", "a t n k", "dmg", CRIT },
    { "SPELLLOGSCHOOLSELFOTHER", "Your %s hits %s for %d %s damage.", "a t n k", "dmg" },
    { "SPELLLOGCRITSELFOTHER", "Your %s crits %s for %d.", "a t n", "dmg", CRIT },
    { "SPELLLOGSELFOTHER", "Your %s hits %s for %d.", "a t n", "dmg" },
    { "COMBATHITCRITSCHOOLSELFOTHER", "You crit %s for %d %s damage.", "t n k", "dmg", CRIT },
    { "COMBATHITSCHOOLSELFOTHER", "You hit %s for %d %s damage.", "t n k", "dmg" },
    { "COMBATHITCRITSELFOTHER", "You crit %s for %d.", "t n", "dmg", CRIT },
    { "COMBATHITSELFOTHER", "You hit %s for %d.", "t n", "dmg" },
    { "PERIODICAURADAMAGESELFOTHER", "%s suffers %d %s damage from your %s.", "t n k a", "dmg" },
    { "DAMAGESHIELDSELFOTHER", "You reflect %d %s damage to %s.", "n k t", "dmg", SHIELD },
    -- others hitting you
    { "SPELLLOGCRITSCHOOLOTHERSELF", "%s's %s crits you for %d %s damage.", "s a n k", "dmg", CRITME },
    { "SPELLLOGSCHOOLOTHERSELF", "%s's %s hits you for %d %s damage.", "s a n k", "dmg", ME },
    { "SPELLLOGCRITOTHERSELF", "%s's %s crits you for %d.", "s a n", "dmg", CRITME },
    { "SPELLLOGOTHERSELF", "%s's %s hits you for %d.", "s a n", "dmg", ME },
    { "PERIODICAURADAMAGEOTHERSELF", "You suffer %d %s damage from %s's %s.", "n k s a", "dmg", ME },
    { "COMBATHITCRITSCHOOLOTHERSELF", "%s crits you for %d %s damage.", "s n k", "dmg", CRITME },
    { "COMBATHITSCHOOLOTHERSELF", "%s hits you for %d %s damage.", "s n k", "dmg", ME },
    { "COMBATHITCRITOTHERSELF", "%s crits you for %d.", "s n", "dmg", CRITME },
    { "COMBATHITOTHERSELF", "%s hits you for %d.", "s n", "dmg", ME },
    { "DAMAGESHIELDOTHERSELF", "%s reflects %d %s damage to you.", "s n k", "dmg", SHIELDME },
    -- the world hitting you or your group
    { "VSENVIRONMENTALDAMAGE_FALLING_SELF", "You fall and lose %d health.", "n", "dmg", env("Falling") },
    { "VSENVIRONMENTALDAMAGE_DROWNING_SELF", "You are drowning and lose %d health.", "n", "dmg", env("Drowning") },
    { "VSENVIRONMENTALDAMAGE_FATIGUE_SELF", "You are exhausted and lose %d health.", "n", "dmg", env("Fatigue") },
    { "VSENVIRONMENTALDAMAGE_LAVA_SELF", "You lose %d health for swimming in lava.", "n", "dmg", env("Lava") },
    { "VSENVIRONMENTALDAMAGE_SLIME_SELF", "You lose %d health for swimming in slime.", "n", "dmg", env("Slime") },
    { "VSENVIRONMENTALDAMAGE_FIRE_SELF", "You suffer %d points of fire damage.", "n", "dmg", env("Fire") },
    { "VSENVIRONMENTALDAMAGE_FALLING_OTHER", "%s falls and loses %d health.", "t n", "dmg", envo("Falling") },
    { "VSENVIRONMENTALDAMAGE_DROWNING_OTHER", "%s is drowning and loses %d health.", "t n", "dmg", envo("Drowning") },
    { "VSENVIRONMENTALDAMAGE_FATIGUE_OTHER", "%s is exhausted and loses %d health.", "t n", "dmg", envo("Fatigue") },
    { "VSENVIRONMENTALDAMAGE_LAVA_OTHER", "%s loses %d health for swimming in lava.", "t n", "dmg", envo("Lava") },
    { "VSENVIRONMENTALDAMAGE_SLIME_OTHER", "%s loses %d health for swimming in slime.", "t n", "dmg", envo("Slime") },
    { "VSENVIRONMENTALDAMAGE_FIRE_OTHER", "%s suffers %d points of fire damage.", "t n", "dmg", envo("Fire") },
    -- others (party, raid, pets, and the creatures hitting them)
    { "SPELLLOGCRITSCHOOLOTHEROTHER", "%s's %s crits %s for %d %s damage.", "s a t n k", "dmg", CRIT },
    { "SPELLLOGSCHOOLOTHEROTHER", "%s's %s hits %s for %d %s damage.", "s a t n k", "dmg" },
    { "SPELLLOGCRITOTHEROTHER", "%s's %s crits %s for %d.", "s a t n", "dmg", CRIT },
    { "SPELLLOGOTHEROTHER", "%s's %s hits %s for %d.", "s a t n", "dmg" },
    { "PERIODICAURADAMAGEOTHEROTHER", "%s suffers %d %s damage from %s's %s.", "t n k s a", "dmg" },
    { "DAMAGESHIELDOTHEROTHER", "%s reflects %d %s damage to %s.", "s n k t", "dmg", SHIELD },
    { "COMBATHITCRITSCHOOLOTHEROTHER", "%s crits %s for %d %s damage.", "s t n k", "dmg", CRIT },
    { "COMBATHITSCHOOLOTHEROTHER", "%s hits %s for %d %s damage.", "s t n k", "dmg" },
    { "COMBATHITCRITOTHEROTHER", "%s crits %s for %d.", "s t n", "dmg", CRIT },
    { "COMBATHITOTHEROTHER", "%s hits %s for %d.", "s t n", "dmg" },
    -- healing
    { "HEALEDCRITSELFSELF", "Your %s critically heals you for %d.", "a n", "heal", CRITME },
    { "HEALEDSELFSELF", "Your %s heals you for %d.", "a n", "heal", ME },
    { "HEALEDCRITSELFOTHER", "Your %s critically heals %s for %d.", "a t n", "heal", CRIT },
    { "HEALEDSELFOTHER", "Your %s heals %s for %d.", "a t n", "heal" },
    { "HEALEDCRITOTHERSELF", "%s's %s critically heals you for %d.", "s a n", "heal", CRITME },
    { "HEALEDOTHERSELF", "%s's %s heals you for %d.", "s a n", "heal", ME },
    { "HEALEDCRITOTHEROTHER", "%s's %s critically heals %s for %d.", "s a t n", "heal", CRIT },
    { "HEALEDOTHEROTHER", "%s's %s heals %s for %d.", "s a t n", "heal" },
    { "PERIODICAURAHEALOTHERSELF", "You gain %d health from %s's %s.", "n s a", "heal", ME },
    { "PERIODICAURAHEALSELFSELF", "You gain %d health from %s.", "n a", "heal", ME },
    { "PERIODICAURAHEALOTHEROTHER", "%s gains %d health from %s's %s.", "t n s a", "heal" },
    { "PERIODICAURAHEALSELFOTHER", "%s gains %d health from your %s.", "t n a", "heal" },
    -- interrupts
    { "SPELLINTERRUPTSELFOTHER", "You interrupt %s's %s.", "t a", "interrupt" },
    { "SPELLINTERRUPTOTHEROTHER", "%s interrupts %s's %s.", "s t a", "interrupt" },
    -- your misses
    { "MISSEDSELFOTHER", "You miss %s.", "t", "miss", miss("miss") },
    { "VSDODGESELFOTHER", "You attack. %s dodges.", "t", "miss", miss("dodge") },
    { "VSPARRYSELFOTHER", "You attack. %s parries.", "t", "miss", miss("parry") },
    { "VSBLOCKSELFOTHER", "You attack. %s blocks.", "t", "miss", miss("block") },
    { "VSEVADESELFOTHER", "You attack. %s evades.", "t", "miss", miss("evade") },
    { "VSABSORBSELFOTHER", "You attack. %s absorbs all the damage.", "t", "miss", miss("absorb") },
    { "VSIMMUNESELFOTHER", "You attack but %s is immune.", "t", "miss", miss("immune") },
    { "SPELLMISSSELFOTHER", "Your %s missed %s.", "a t", "miss", miss("miss") },
    { "SPELLRESISTSELFOTHER", "Your %s was resisted by %s.", "a t", "miss", miss("resist") },
    { "SPELLDODGEDSELFOTHER", "Your %s was dodged by %s.", "a t", "miss", miss("dodge") },
    { "SPELLPARRIEDSELFOTHER", "Your %s is parried by %s.", "a t", "miss", miss("parry") },
    { "SPELLBLOCKEDSELFOTHER", "Your %s was blocked by %s.", "a t", "miss", miss("block") },
    { "SPELLEVADEDSELFOTHER", "Your %s was evaded by %s.", "a t", "miss", miss("evade") },
    { "SPELLIMMUNESELFOTHER", "Your %s failed. %s is immune.", "a t", "miss", miss("immune") },
    { "SPELLLOGABSORBSELFOTHER", "Your %s is absorbed by %s.", "a t", "miss", miss("absorb") },
    -- misses against you (recognised so they are not read as something else)
    { "MISSEDOTHERSELF", "%s misses you.", "s", "miss", miss("miss", 1) },
    { "VSDODGEOTHERSELF", "%s attacks. You dodge.", "s", "miss", miss("dodge", 1) },
    { "VSPARRYOTHERSELF", "%s attacks. You parry.", "s", "miss", miss("parry", 1) },
    { "VSBLOCKOTHERSELF", "%s attacks. You block.", "s", "miss", miss("block", 1) },
    { "VSABSORBOTHERSELF", "%s attacks. You absorb all the damage.", "s", "miss", miss("absorb", 1) },
    -- others' misses
    { "MISSEDOTHEROTHER", "%s misses %s.", "s t", "miss", miss("miss") },
    { "VSDODGEOTHEROTHER", "%s attacks. %s dodges.", "s t", "miss", miss("dodge") },
    { "VSPARRYOTHEROTHER", "%s attacks. %s parries.", "s t", "miss", miss("parry") },
    { "VSBLOCKOTHEROTHER", "%s attacks. %s blocks.", "s t", "miss", miss("block") },
    { "VSEVADEOTHEROTHER", "%s attacks. %s evades.", "s t", "miss", miss("evade") },
    { "VSABSORBOTHEROTHER", "%s attacks. %s absorbs all the damage.", "s t", "miss", miss("absorb") },
    { "VSIMMUNEOTHEROTHER", "%s attacks but %s is immune.", "s t", "miss", miss("immune") },
    { "SPELLMISSOTHEROTHER", "%s's %s missed %s.", "s a t", "miss", miss("miss") },
    { "SPELLRESISTOTHEROTHER", "%s's %s was resisted by %s.", "s a t", "miss", miss("resist") },
    { "SPELLDODGEDOTHEROTHER", "%s's %s was dodged by %s.", "s a t", "miss", miss("dodge") },
    { "SPELLPARRIEDOTHEROTHER", "%s's %s was parried by %s.", "s a t", "miss", miss("parry") },
    { "SPELLBLOCKEDOTHEROTHER", "%s's %s was blocked by %s.", "s a t", "miss", miss("block") },
    { "SPELLEVADEDOTHEROTHER", "%s's %s was evaded by %s.", "s a t", "miss", miss("evade") },
    { "SPELLIMMUNEOTHEROTHER", "%s's %s fails. %s is immune.", "s a t", "miss", miss("immune") },
    { "SPELLLOGABSORBOTHEROTHER", "%s's %s is absorbed by %s.", "s a t", "miss", miss("absorb") },
    -- mana, rage and energy (after the heals: "You gain 35 health from ..." is a heal)
    { "POWERGAINOTHERSELF", "You gain %d %s from %s's %s.", "n p s a", "power", ME },
    { "POWERGAINSELFSELF", "You gain %d %s from %s.", "n p a", "power", ME },
    { "POWERGAINSELFOTHER", "%s gains %d %s from your %s.", "t n p a", "power" },
    { "POWERGAINOTHEROTHER", "%s gains %d %s from %s's %s.", "t n p s a", "power" },
    -- extra attacks look like aura gains; recognise and skip them
    { "SPELLEXTRAATTACKSSELF", "You gain %d extra attacks through %s.", "n a", "skip" },
    { "SPELLEXTRAATTACKSSELF_SINGULAR", "You gain %d extra attack through %s.", "n a", "skip" },
    { "SPELLEXTRAATTACKSOTHER", "%s gains %d extra attacks through %s.", "t n a", "skip" },
    { "SPELLEXTRAATTACKSOTHER_SINGULAR", "%s gains %d extra attack through %s.", "t n a", "skip" },
    -- casts (dispels, resurrects, and who used a crowd-control spell)
    { "SPELLCASTGOSELFTARGETTED", "You cast %s on %s.", "a t", "cast" },
    { "SPELLPERFORMGOSELFTARGETTED", "You perform %s on %s.", "a t", "cast" },
    { "SPELLCASTGOOTHERTARGETTED", "%s casts %s on %s.", "s a t", "cast" },
    { "SPELLPERFORMGOOTHERTARGETTED", "%s performs %s on %s.", "s a t", "cast" },
    { "SPELLCASTGOSELF", "You cast %s.", "a", "cast" },
    { "SPELLPERFORMGOSELF", "You perform %s.", "a", "cast" },
    { "SPELLCASTOTHERSTART", "%s begins to cast %s.", "s a", "begin" },
    { "SPELLPERFORMOTHERSTART", "%s begins to perform %s.", "s a", "begin" },
    -- deaths
    { "UNITDIESSELF", "You die.", "", "death", ME },
    { "SELFKILLOTHER", "You have slain %s!", "t", "death" },
    { "PARTYKILLOTHER", "%s is slain by %s!", "t s", "death" },
    { "UNITDIESOTHER", "%s dies.", "t", "death" },
    -- auras (crowd control on enemies; your own buffs and debuffs for uptime)
    { "AURAADDEDSELFHARMFUL", "You are afflicted by %s.", "a", "aura+", { me = 1, harm = 1 } },
    { "AURAADDEDOTHERHARMFUL", "%s is afflicted by %s.", "t a", "aura+", { harm = 1 } },
    { "AURAREMOVEDSELF", "%s fades from you.", "a", "aura-", ME },
    { "AURAREMOVEDOTHER", "%s fades from %s.", "a t", "aura-" },
    { "AURAADDEDSELFHELPFUL", "You gain %s.", "a", "aura+", ME },
    { "AURAADDEDOTHERHELPFUL", "%s gains %s.", "t a", "aura+" },
}

-- Spells that count as dispels, resurrects and crowd control (with the class that has them).
C.DISPELS = {
    ["Dispel Magic"] = 1, ["Cleanse"] = 1, ["Purify"] = 1, ["Remove Curse"] = 1, ["Remove Lesser Curse"] = 1,
    ["Cure Poison"] = 1, ["Abolish Poison"] = 1, ["Cure Disease"] = 1, ["Abolish Disease"] = 1,
    ["Purge"] = 1, ["Devour Magic"] = 1, ["Tranquilizing Shot"] = 1,
}
C.RESURRECTS = { ["Resurrection"] = 1, ["Redemption"] = 1, ["Ancestral Spirit"] = 1, ["Rebirth"] = 1 }
C.CC = {
    ["Polymorph"] = "MAGE", ["Frost Nova"] = "MAGE",
    ["Sap"] = "ROGUE", ["Gouge"] = "ROGUE", ["Blind"] = "ROGUE", ["Kidney Shot"] = "ROGUE", ["Cheap Shot"] = "ROGUE",
    ["Freezing Trap Effect"] = "HUNTER", ["Scatter Shot"] = "HUNTER", ["Wyvern Sting"] = "HUNTER",
    ["Fear"] = "WARLOCK", ["Howl of Terror"] = "WARLOCK", ["Banish"] = "WARLOCK", ["Death Coil"] = "WARLOCK",
    ["Psychic Scream"] = "PRIEST", ["Shackle Undead"] = "PRIEST", ["Mind Control"] = "PRIEST",
    ["Hibernate"] = "DRUID", ["Entangling Roots"] = "DRUID", ["Bash"] = "DRUID",
    ["Hammer of Justice"] = "PALADIN", ["Repentance"] = "PALADIN", ["Turn Undead"] = "PALADIN",
    ["Intimidating Shout"] = "WARRIOR", ["Concussion Blow"] = "WARRIOR",
}

-- Bosses that name a fight (besides anything the client calls a "worldboss").
local BOSS_LIST = {
    -- raids
    "Lucifron", "Magmadar", "Gehennas", "Garr", "Baron Geddon", "Shazzrah", "Sulfuron Harbinger",
    "Golemagg the Incinerator", "Majordomo Executus", "Ragnaros", "Onyxia",
    "Razorgore the Untamed", "Vaelastrasz the Corrupt", "Broodlord Lashlayer", "Firemaw", "Ebonroc",
    "Flamegor", "Chromaggus", "Nefarian",
    "High Priestess Jeklik", "High Priest Venoxis", "High Priestess Mar'li", "Bloodlord Mandokir",
    "High Priest Thekal", "High Priestess Arlokk", "Jin'do the Hexxer", "Hakkar", "Gahz'ranka",
    "Kurinnaxx", "General Rajaxx", "Moam", "Buru the Gorger", "Ayamiss the Hunter", "Ossirian the Unscarred",
    "The Prophet Skeram", "Battleguard Sartura", "Fankriss the Unyielding", "Viscidus", "Princess Huhuran",
    "Emperor Vek'lor", "Emperor Vek'nilash", "Ouro", "C'Thun", "Princess Yauj", "Vem", "Lord Kri",
    "Anub'Rekhan", "Grand Widow Faerlina", "Maexxna", "Noth the Plaguebringer", "Heigan the Unclean",
    "Loatheb", "Instructor Razuvious", "Gothik the Harvester", "Patchwerk", "Grobbulus", "Gluth",
    "Thaddius", "Sapphiron", "Kel'Thuzad",
    "Lord Kazzak", "Azuregos", "Emeriss", "Lethon", "Ysondre", "Taerar",
    -- dungeons
    "Edwin VanCleef", "Archmage Arugal", "Mutanus the Devourer", "Bloodmage Thalnos", "Herod",
    "High Inquisitor Whitemane", "Scarlet Commander Mograine", "Mekgineer Thermaplugg", "Archaedas",
    "Amnennar the Coldbringer", "Princess Theradras", "Shade of Eranikus", "Emperor Dagran Thaurissan",
    "Overlord Wyrmthalak", "General Drakkisath", "Baron Rivendare", "Darkmaster Gandling",
    "King Gordok", "Prince Tortheldrin", "Immol'thar",
}
C.BOSSES = {}
for _, n in ipairs(BOSS_LIST) do C.BOSSES[n] = true end

local MAGIC = "^$()%.[]*+-?"

-- "Your %s hits %s for %d." -> "^Your (.+) hits (.+) for (%d+)%.$", {1, 2, 3}
-- Handles positional "%2$s" arguments as used by some locales.
function C.BuildPattern(fmt)
    local out, order, nextArg = { "^" }, {}, 1
    local i, n = 1, strlen(fmt)
    while i <= n do
        local ch = strsub(fmt, i, i)
        if ch == "%" then
            local _, e, pos, kind = strfind(fmt, "^%%(%d*)%$?([sd])", i)
            if e then
                local arg = tonumber(pos)
                if not arg or pos == "" then
                    arg = nextArg
                    nextArg = nextArg + 1
                end
                tinsert(out, kind == "d" and "(%d+)" or "(.+)")
                tinsert(order, arg)
                i = e + 1
            else
                tinsert(out, "%%")
                i = i + 1
            end
        else
            if strfind(MAGIC, ch, 1, 1) then tinsert(out, "%" .. ch) else tinsert(out, ch) end
            i = i + 1
        end
    end
    tinsert(out, "$")
    return table.concat(out), order
end

local PATTERNS
local function compile()
    PATTERNS = {}
    for _, t in ipairs(TEMPLATES) do
        local fmt = getglobal(t[1])
        if type(fmt) ~= "string" or fmt == "" then fmt = t[2] end
        local pat, order = C.BuildPattern(fmt)
        local roles = {}
        for w in string.gfind(t[3], "%S+") do tinsert(roles, w) end
        -- the literal text before the first argument: a cheap pre-check before strfind
        local cut = strfind(fmt, "%", 1, 1)
        local prefix = cut and strsub(fmt, 1, cut - 1) or fmt
        tinsert(PATTERNS, { pat = pat, order = order, roles = roles, kind = t[4], o = t[5] or NONE,
            prefix = prefix, plen = strlen(prefix) })
    end
end

-- Returns kind, source (nil = you), target, ability, amount, options, school, power type; or nil.
function C.ParseLine(msg)
    if not PATTERNS then compile() end
    -- trailing "(12 resisted)", "(30 absorbed)", "(glancing)", stack counts "(2)" and friends
    msg = strgsub(msg, " %b()", "")
    for _, p in ipairs(PATTERNS) do
        if p.plen == 0 or strsub(msg, 1, p.plen) == p.prefix then
            local r = { strfind(msg, p.pat) }
            if r[1] then
                local f = {}
                for ci, arg in ipairs(p.order) do
                    local role = p.roles[arg]
                    if role then f[role] = r[ci + 2] end
                end
                local o = p.o
                local target = f.t
                if o.me or target == "you" then target = me() end
                return p.kind, f.s or o.src, target, f.a or o.label, tonumber(f.n), o, f.k, f.p
            end
        end
    end
end

C.EVENTS = {
    "CHAT_MSG_COMBAT_SELF_HITS", "CHAT_MSG_COMBAT_SELF_MISSES",
    "CHAT_MSG_COMBAT_PARTY_HITS", "CHAT_MSG_COMBAT_PARTY_MISSES",
    "CHAT_MSG_COMBAT_FRIENDLYPLAYER_HITS", "CHAT_MSG_COMBAT_FRIENDLYPLAYER_MISSES",
    "CHAT_MSG_COMBAT_PET_HITS", "CHAT_MSG_COMBAT_PET_MISSES",
    "CHAT_MSG_COMBAT_CREATURE_VS_SELF_HITS", "CHAT_MSG_COMBAT_CREATURE_VS_SELF_MISSES",
    "CHAT_MSG_COMBAT_CREATURE_VS_PARTY_HITS", "CHAT_MSG_COMBAT_CREATURE_VS_PARTY_MISSES",
    "CHAT_MSG_COMBAT_HOSTILEPLAYER_HITS",
    "CHAT_MSG_COMBAT_FRIENDLY_DEATH", "CHAT_MSG_COMBAT_HOSTILE_DEATH",
    "CHAT_MSG_SPELL_SELF_DAMAGE", "CHAT_MSG_SPELL_PARTY_DAMAGE", "CHAT_MSG_SPELL_FRIENDLYPLAYER_DAMAGE",
    "CHAT_MSG_SPELL_PET_DAMAGE", "CHAT_MSG_SPELL_CREATURE_VS_SELF_DAMAGE",
    "CHAT_MSG_SPELL_CREATURE_VS_PARTY_DAMAGE", "CHAT_MSG_SPELL_HOSTILEPLAYER_DAMAGE",
    "CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE", "CHAT_MSG_SPELL_PERIODIC_HOSTILEPLAYER_DAMAGE",
    "CHAT_MSG_SPELL_PERIODIC_SELF_DAMAGE", "CHAT_MSG_SPELL_PERIODIC_PARTY_DAMAGE",
    "CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_DAMAGE",
    "CHAT_MSG_SPELL_SELF_BUFF", "CHAT_MSG_SPELL_PARTY_BUFF", "CHAT_MSG_SPELL_FRIENDLYPLAYER_BUFF",
    "CHAT_MSG_SPELL_PET_BUFF",
    "CHAT_MSG_SPELL_PERIODIC_SELF_BUFFS", "CHAT_MSG_SPELL_PERIODIC_PARTY_BUFFS",
    "CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_BUFFS",
    "CHAT_MSG_SPELL_AURA_GONE_SELF", "CHAT_MSG_SPELL_AURA_GONE_PARTY", "CHAT_MSG_SPELL_AURA_GONE_OTHER",
    "CHAT_MSG_SPELL_DAMAGESHIELDS_ON_SELF", "CHAT_MSG_SPELL_DAMAGESHIELDS_ON_OTHERS",
    "CHAT_MSG_SPELL_BREAK_AURA",
}

-- -- Group roster: who counts, their class, and whose pet is whose -------------

C.roster = {}   -- name -> { class = TOKEN, owner = name-or-nil }
C.units = {}    -- name -> unit id (health for overhealing and the death recap)

function C:UpdateRoster()
    local r, u = {}, {}
    local function add(unit, ownerUnit)
        if not UnitExists(unit) then return end
        local name = UnitName(unit)
        if not name or name == UNKNOWNOBJECT then return end
        if ownerUnit then
            local owner = UnitName(ownerUnit)
            if owner then r[name] = { owner = owner } end
        else
            local _, token = UnitClass(unit)
            r[name] = { class = token }
        end
        if not u[name] then u[name] = unit end
    end
    add("player")
    add("pet", "player")
    local raid = GetNumRaidMembers and GetNumRaidMembers() or 0
    if raid > 0 then
        for i = 1, raid do
            add("raid" .. i)
            add("raidpet" .. i, "raid" .. i)
        end
    else
        for i = 1, (GetNumPartyMembers and GetNumPartyMembers() or 0) do
            add("party" .. i)
            add("partypet" .. i, "party" .. i)
        end
    end
    self.roster, self.units = r, u
end

-- Name the meter should credit, or nil if the source is not ours.
local function credit(source)
    local mine = me()
    if not source or source == mine then return mine end
    local e = C.roster[source]
    if not e then return nil end
    return e.owner or source
end
C.Credit = credit

local function friendly(name) return name and (name == me() or C.roster[name]) and true or false end
-- a player in the group (not a pet)
local function member(name)
    if not name then return false end
    if name == me() then return true end
    local e = C.roster[name]
    return e and not e.owner and true or false
end
C.IsMember = member

-- -- Fights ----------------------------------------------------------------------

local segCounter = 0
local function newSeg(now)
    segCounter = segCounter + 1
    return { id = segCounter, start = now, last = now, players = {}, total = {}, deaths = {},
        auras = {}, enemies = {}, fights = 1 }
end

function C:Overall()
    if not self.overall then
        self.overall = newSeg(GetTime())
        self.overall.dur = 0
        self.overall.fights = 0
        self.overall.isOverall = true
    end
    return self.overall
end

-- A fight is live while it had combat in the last 6 s or you are still in combat.
function C:IsLive(f)
    f = f or self.fight
    return f and f == self.fight and (GetTime() - f.last <= 6 or UnitAffectingCombat("player")) and true or false
end

-- The end of a segment's clock: now while it is live and you are in combat, else its last event.
function C:SegEnd(f)
    if f == self.fight and UnitAffectingCombat("player") then return GetTime() end
    return f.last
end

-- how: "new" starts a fight when none is live, "soft" returns only a live fight,
-- "any" also returns the fight that just finished.
function C:Fight(how)
    local f = self.fight
    if f and (self:IsLive(f) or how == "any") then return f end
    if how ~= "new" then return nil end
    self:EndFight()
    f = newSeg(GetTime())
    self.fight = f
    self.inspectData = {}   -- the server's breakdown was for the last fight
    self:Overall().fights = self:Overall().fights + 1
    self:ScanBoss()
    return f
end

local function overlap(a1, a2, b1, b2)
    local s = (a1 > b1) and a1 or b1
    local e = (a2 < b2) and a2 or b2
    if e > s then return e - s end
    return 0
end
C.Overlap = overlap

local function addAura(seg, name, harmful, t)
    local a = seg.auras[name]
    if not a then
        a = { t = 0, harmful = harmful }
        seg.auras[name] = a
    end
    a.t = a.t + (t or 0)
end

-- numbers add up ("max" keeps the larger), tables merge, anything else is kept
local function addInto(dst, src)
    for k, v in pairs(src) do
        local t = type(v)
        if t == "number" then
            if k == "max" then
                if not dst[k] or v > dst[k] then dst[k] = v end
            else
                dst[k] = (dst[k] or 0) + v
            end
        elseif t == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            addInto(dst[k], v)
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
end

local function topEnemy(seg)
    local best, bv
    for n, v in pairs(seg.enemies) do
        if not bv or v > bv then best, bv = n, v end
    end
    return best
end

-- Keep only the biggest n entries of a name -> amount map.
local function trimMap(map, n)
    local list = {}
    for k, v in pairs(map) do tinsert(list, { k = k, v = v }) end
    if getn(list) <= n then return map end
    table.sort(list, function(a, b) return a.v > b.v end)
    local out = {}
    for i = 1, n do out[list[i].k] = list[i].v end
    return out
end

-- Trim a finished fight so 25 of them stay small.
function C:Compact(seg)
    for _, p in pairs(seg.players) do
        for k, map in pairs(p.targets) do p.targets[k] = trimMap(map, C.MAX_TARGETS) end
    end
    seg.enemies = trimMap(seg.enemies, 8)
    while getn(seg.deaths) > C.MAX_DEATHS do tremove(seg.deaths, 1) end
end

function C:EndFight()
    local f = self.fight
    if not f then return end
    self.fight = nil
    if not next(f.players) and not f.deaths[1] then return end
    f.dur = math.max(1, f.last - f.start)
    -- your buffs and debuffs still up at the end of the fight
    for name, a in pairs(self.myAuras) do addAura(f, name, a.harmful, overlap(a.since, f.last, f.start, f.last)) end
    local o = self:Overall()
    o.dur = o.dur + f.dur
    for name, a in pairs(f.auras) do addAura(o, name, a.harmful, a.t) end
    self:Compact(o)
    f.name = f.boss or topEnemy(f) or "Fight"
    f.closed = true
    self:Compact(f)
    local prev = self.history[1]
    if not f.boss and prev and not prev.boss then
        -- trash: merge into the trash entry since the last boss
        prev.fights = prev.fights + 1
        prev.dur = prev.dur + f.dur
        prev.last = f.last
        for name, p in pairs(f.players) do
            if prev.players[name] then addInto(prev.players[name], p) else prev.players[name] = p end
        end
        addInto(prev.total, f.total)
        addInto(prev.enemies, f.enemies)
        for _, d in ipairs(f.deaths) do tinsert(prev.deaths, d) end
        for name, a in pairs(f.auras) do addAura(prev, name, a.harmful, a.t) end
        prev.name = topEnemy(prev) or prev.name
        self:Compact(prev)
    else
        tinsert(self.history, 1, f)
    end
    -- over the cap: drop the oldest trash first, then the oldest boss
    while getn(self.history) > C.MAX_HISTORY do
        local drop = getn(self.history)
        for i = getn(self.history), 1, -1 do
            if not self.history[i].boss then drop = i break end
        end
        tremove(self.history, drop)
    end
end

-- "Ragnaros", "Trash - Defias Thug (3 fights)", "Current fight", "Overall"
function C:SegmentName(seg, short)
    if not seg then return "Current fight" end
    if seg.isOverall then return "Overall" end
    if seg == self.fight then
        if seg.boss then return seg.boss end
        return short and "Current fight" or ("Current fight" .. (topEnemy(seg) and (" - " .. topEnemy(seg)) or ""))
    end
    if seg.boss then return seg.boss .. (seg.killed and " (kill)" or "") end
    local n = "Trash - " .. (seg.name or "?")
    if seg.fights > 1 then n = n .. " (" .. seg.fights .. " fights)" end
    return n
end

-- sel: "current" | "overall" | a history id. Returns the segment (or nil) and the kind.
function C:Segment(sel)
    if sel == "overall" then return self.overall, "overall" end
    if sel and sel ~= "current" then
        for _, s in ipairs(self.history) do
            if s.id == sel then return s, "history" end
        end
    end
    return self.fight, "current"
end

function C:Duration(seg)
    if not seg then return 0 end
    if seg.isOverall then
        local d = seg.dur
        if self.fight then d = d + math.max(1, self:SegEnd(self.fight) - self.fight.start) end
        return math.max(1, d)
    end
    if seg.closed then return seg.dur end
    return math.max(1, self:SegEnd(seg) - seg.start)
end

function C:CheckBoss(name)
    local f = self.fight
    if f and not f.boss and name and C.BOSSES[name] then f.boss = name end
end

local SCAN_UNITS = { "target", "pettarget", "party1target", "party2target", "party3target", "party4target" }
function C:ScanBoss()
    local f = self.fight
    if not f or f.boss then return end
    for _, u in ipairs(SCAN_UNITS) do
        if UnitExists(u) and UnitCanAttack("player", u) then
            local n = UnitName(u)
            if UnitClassification(u) == "worldboss" or C.BOSSES[n or ""] then
                f.boss = n
                return
            end
        end
    end
end

function C:Reset()
    self.fight = nil
    self.overall = nil
    self.history = {}
    self.inspectData = {}
    self.server = nil
    self.recap = {}
    self.hpEst = {}
    self.dirty = true
    if self.OnReset then self:OnReset() end
    self:Render()
end

-- -- Recording -------------------------------------------------------------------

local function actor(seg, name)
    local p = seg.players[name]
    if not p then
        local e = C.roster[name]
        local cls = e and e.class
        if not cls and name == me() then
            local _, t = UnitClass("player")
            cls = t
        end
        p = { class = cls, dmg = 0, heal = 0, abilities = { dmg = {}, heal = {} }, targets = {}, stats = {} }
        seg.players[name] = p
    end
    return p
end
C.Actor = actor

local function bucket(t, k)
    local b = t[k]
    if not b then
        b = {}
        t[k] = b
    end
    return b
end

-- Add to a player's key (dmg, heal, interrupts, ...) in the current fight and overall, with the
-- ability (label) and target it was against.
function C:Add(name, key, amount, label, target)
    local segs = { self.fight, self.overall }
    for i = 1, 2 do
        local seg = segs[i]
        if seg then
            local p = actor(seg, name)
            p[key] = (p[key] or 0) + amount
            seg.total[key] = (seg.total[key] or 0) + amount
            if label then
                local a = bucket(p.abilities, key)
                a[label] = (a[label] or 0) + amount
            end
            if target then
                local tg = bucket(p.targets, key)
                tg[target] = (tg[target] or 0) + amount
            end
        end
    end
end

-- Hit statistics per ability: n hits (crits included), c crits, m misses, max, o overheal, k
-- healing whose overheal is known.
function C:Stat(name, key, label, amount, crit, missed, over)
    local segs = { self.fight, self.overall }
    for i = 1, 2 do
        local seg = segs[i]
        if seg then
            local st = bucket(bucket(actor(seg, name).stats, key), label)
            if missed then
                st.m = (st.m or 0) + 1
            else
                st.n = (st.n or 0) + 1
                if crit then st.c = (st.c or 0) + 1 end
                if not st.max or amount > st.max then st.max = amount end
                if over then
                    st.o = (st.o or 0) + over
                    st.k = (st.k or 0) + amount
                end
            end
        end
    end
end

-- "Arcane Shot", "Melee", a pet's swing ("Wolf") or a pet's spell ("Claw (Wolf)")
local function label(who, src, abil)
    if src and src ~= who then
        if abil then return abil .. " (" .. src .. ")" end
        return src
    end
    return abil or "Melee"
end

function C:Enemy(name, amount)
    local f = self.fight
    if not f or not name then return end
    f.enemies[name] = (f.enemies[name] or 0) + amount
    self:CheckBoss(name)
end

function C:Recent(abil, who)
    if abil then self.recent[abil] = { who = who, t = GetTime() } end
end

-- Health before this heal: the unit's health, less what our earlier estimates already added
-- since the client last updated it. Returns overheal, or nil when the target's health is unknown.
function C:Overheal(name, amount)
    local unit = self.units[name]
    if name == me() then unit = "player" end
    if not unit then return nil end
    local max = UnitHealthMax(unit)
    if not max or max <= 0 then return nil end
    local raw = UnitHealth(unit) or 0
    local hp = raw
    local est = self.hpEst[name]
    if est and est.raw == raw and GetTime() - est.t < 1 then hp = est.hp end
    local missing = max - hp
    if missing < 0 then missing = 0 end
    local eff = (amount < missing) and amount or missing
    self.hpEst[name] = { raw = raw, hp = hp + eff, t = GetTime() }
    return amount - eff
end

function C:Recap(name, amount, src, abil, crit)
    local r = bucket(self.recap, name)
    local unit = (name == me()) and "player" or self.units[name]
    local hp
    if unit then
        local m = UnitHealthMax(unit)
        if m and m > 0 then hp = floor(UnitHealth(unit) / m * 100 + 0.5) end
    end
    tinsert(r, { t = GetTime(), amt = amount, src = src, abil = abil, crit = crit, hp = hp })
    if getn(r) > C.RECAP then tremove(r, 1) end
end

-- Who put this crowd control on: whoever used the spell in the last 5 s, else the only
-- player in the group whose class has it.
function C:CCCaster(abil)
    local r = self.recent[abil]
    if r and GetTime() - r.t < 5 then return r.who end
    local cls = C.CC[abil]
    if not cls then return nil end
    local found, count = nil, 0
    local _, mine = UnitClass("player")
    if mine == cls then found, count = me(), 1 end
    for name, e in pairs(self.roster) do
        if not e.owner and e.class == cls and name ~= me() then
            found, count = name, count + 1
        end
    end
    if count == 1 then return found end
end

local H = {}

function H.dmg(self, src, tgt, abil, amt, o)
    local who = credit(src)
    local now = GetTime()
    local friendlyTarget = friendly(tgt)
    if who and not friendlyTarget then
        local f = self:Fight("new")
        f.last = now
        local l = label(who, src, abil)
        self:Add(who, "dmg", amt, l, tgt)
        self:Stat(who, "dmg", l, amt, o.crit)
        self:Enemy(tgt, amt)
        self:Recent(abil, who)
        self.dirty = true
        return
    end
    if who and friendlyTarget and tgt ~= who and not (self.roster[tgt] and self.roster[tgt].owner == who) then
        local f = self:Fight("new")   -- friendly fire (and duels)
        f.last = now
        self:Add(who, "ff", amt, label(who, src, abil), tgt)
        self.dirty = true
    end
    if member(tgt) then
        local f = self:Fight("new")
        f.last = now
        local from = src or me()
        self:Add(tgt, "dtaken", amt, abil or "Melee", from)
        self:Recap(tgt, -amt, from, abil or "Melee", o.crit)
        if not who then self:Enemy(src, 0) end
        self.dirty = true
    end
end

function H.heal(self, src, tgt, abil, amt, o)
    if not friendly(tgt) then return end                  -- heals on outsiders
    local who = credit(src)
    local isMember = member(tgt)
    if not who and not isMember then return end
    local f = self:Fight(UnitAffectingCombat("player") and "new" or "soft")
    if not f then return end                              -- topping up after the fight
    f.last = GetTime()
    local over = self:Overheal(tgt, amt)
    if who then
        local l = label(who, src, abil)
        self:Add(who, "heal", amt, l, tgt)
        self:Stat(who, "heal", l, amt, o.crit, nil, over)
        if over then
            self:Add(who, "overheal", over, l, tgt)
            self:Add(who, "healKnown", amt)
        end
    end
    if isMember then
        self:Add(tgt, "htaken", amt, abil, src or me())
        self:Recap(tgt, amt, src or me(), abil, o.crit)
    end
    self.dirty = true
end

function H.miss(self, src, tgt, abil, amt, o)
    local who = credit(src)
    if not who or o.me or friendly(tgt) then return end
    local f = self:Fight("new")
    f.last = GetTime()
    local l = label(who, src, abil)
    self:Add(who, "dmg", 0, l)
    self:Stat(who, "dmg", l, 0, nil, true)
    self:Enemy(tgt, 0)
    self:Recent(abil, who)
    self.dirty = true
end

function H.interrupt(self, src, tgt, abil)
    local who = credit(src)
    if not who then return end
    local f = self:Fight("new")
    f.last = GetTime()
    self:Add(who, "interrupts", 1, abil, tgt)
    self.dirty = true
end

function H.cast(self, src, tgt, abil)
    local who = credit(src)
    if not who or not abil then return end
    self:Recent(abil, who)
    if C.DISPELS[abil] then
        if self:Fight(UnitAffectingCombat("player") and "new" or "soft") then
            self:Add(who, "dispels", 1, abil, tgt or who)
            self.dirty = true
        end
    elseif C.RESURRECTS[abil] then
        if self:Fight("any") then
            self:Add(who, "res", 1, abil, tgt or who)
            self.dirty = true
        end
    end
end

function H.begin(self, src, tgt, abil)
    local who = credit(src)
    if who then self:Recent(abil, who) end
end

H["aura+"] = function(self, src, tgt, abil, amt, o)
    if not abil then return end
    if tgt == me() then
        if not self.myAuras[abil] then self.myAuras[abil] = { since = GetTime(), harmful = o.harm and true or false } end
        if self.fight then self.dirty = true end
    end
    if o.harm and C.CC[abil] and tgt and not friendly(tgt) then
        local who = self:CCCaster(abil)
        if who then
            local f = self:Fight("new")
            f.last = GetTime()
            self:Add(who, "cc", 1, abil, tgt)
            self.dirty = true
        end
    end
end

H["aura-"] = function(self, src, tgt, abil)
    if tgt ~= me() or not abil then return end
    local a = self.myAuras[abil]
    if not a then return end
    self.myAuras[abil] = nil
    local f = self.fight
    if f then
        addAura(f, abil, a.harmful, overlap(a.since, GetTime(), f.start, self:SegEnd(f)))
        self.dirty = true
    end
end

function H.power(self, src, tgt, abil, amt, o, ptype)
    if not member(tgt) or not amt then return end
    if not self:Fight("soft") then return end
    ptype = ptype or "Mana"
    self:Add(tgt, "power", amt, (abil or "?") .. " (" .. ptype .. ")", src or tgt)
    self:Add(tgt, "pw_" .. ptype, amt)
    self.dirty = true
end

function H.death(self, src, tgt)
    if not tgt then return end
    if member(tgt) then
        local f = self:Fight("any") or self:Fight("new")
        local now = GetTime()
        local e = self.roster[tgt]
        local cls = e and e.class
        if not cls and tgt == me() then
            local _, t = UnitClass("player")
            cls = t
        end
        local rec = { name = tgt, class = cls, at = now, t = now - f.start, events = self.recap[tgt] or {} }
        self.recap[tgt] = nil
        for i = getn(rec.events), 1, -1 do
            local ev = rec.events[i]
            if ev.amt < 0 then rec.blow = ev break end
        end
        local segs = { f, self.overall }
        for i = 1, 2 do
            local seg = segs[i]
            if seg then
                tinsert(seg.deaths, rec)
                while getn(seg.deaths) > C.MAX_DEATHS do tremove(seg.deaths, 1) end
            end
        end
        self:Add(tgt, "deaths", 1, rec.blow and rec.blow.abil, rec.blow and rec.blow.src)
        self.dirty = true
    elseif self.fight and self.fight.boss == tgt then
        self.fight.killed = true
    end
end

function C:OnLine(msg)
    local kind, src, tgt, abil, amt, o, school, ptype = C.ParseLine(msg or "")
    if not kind then return end
    local h = H[kind]
    if h then h(self, src, tgt, abil, amt, o or NONE, ptype) end
end

-- The old entry point (damage and healing only), kept for anything that still calls it.
function C:Record(kind, source, target, ability, amount)
    local h = H[kind]
    if h then h(self, source, target, ability, amount, NONE) end
end

-- -- Rows for a mode --------------------------------------------------------------

-- key: mode id; value: the player field it ranks; rate: show per second; sortRate: rank by it;
-- count: whole numbers; short: tab label.
C.MODES = {
    { key = "dmg", label = "Damage", short = "Damage", value = "dmg", rate = true, icon = "Interface\\Icons\\INV_Sword_04" },
    { key = "dps", label = "DPS", short = "DPS", value = "dmg", rate = true, sortRate = true, icon = "Interface\\Icons\\Ability_DualWield" },
    { key = "heal", label = "Healing", short = "Healing", value = "heal", rate = true, icon = "Interface\\Icons\\Spell_Holy_FlashHeal" },
    { key = "hps", label = "HPS", short = "HPS", value = "heal", rate = true, sortRate = true, icon = "Interface\\Icons\\Spell_Holy_Renew" },
    { key = "overheal", label = "Overhealing", short = "Overheal", value = "overheal", icon = "Interface\\Icons\\Spell_Holy_GreaterHeal" },
    { key = "dtaken", label = "Damage Taken", short = "Taken", value = "dtaken", rate = true, icon = "Interface\\Icons\\INV_Shield_04" },
    { key = "htaken", label = "Healing Taken", short = "Healed", value = "htaken", icon = "Interface\\Icons\\Spell_Holy_Heal02" },
    { key = "deaths", label = "Deaths", short = "Deaths", special = "deaths", icon = "Interface\\Icons\\Ability_Rogue_FeignDeath" },
    { key = "interrupts", label = "Interrupts", short = "Kicks", value = "interrupts", count = true, icon = "Interface\\Icons\\Ability_Kick" },
    { key = "dispels", label = "Dispels", short = "Dispels", value = "dispels", count = true, icon = "Interface\\Icons\\Spell_Holy_DispelMagic" },
    { key = "cc", label = "Crowd Control", short = "CC", value = "cc", count = true, icon = "Interface\\Icons\\Spell_Nature_Polymorph" },
    { key = "auras", label = "Buff & Debuff Uptime", short = "Uptime", special = "auras", icon = "Interface\\Icons\\Spell_Holy_WordFortitude" },
    { key = "power", label = "Resources Gained", short = "Resources", value = "power", icon = "Interface\\Icons\\INV_Potion_76" },
    { key = "res", label = "Resurrects", short = "Res", value = "res", count = true, icon = "Interface\\Icons\\Spell_Holy_Resurrection" },
    { key = "ff", label = "Friendly Fire", short = "Friendly", value = "ff", icon = "Interface\\Icons\\Spell_Fire_SelfDestruct" },
}
C.MODE = {}
for _, m in ipairs(C.MODES) do C.MODE[m.key] = m end

local BUFF_ICON, DEBUFF_ICON = "Interface\\Icons\\Spell_Holy_WordFortitude", "Interface\\Icons\\Spell_Shadow_ShadowWordPain"

-- Aura uptime (seconds) in a segment, including the time of auras still up.
function C:AuraTimes(seg)
    local out = {}
    local function add(name, harmful, t)
        local a = out[name]
        if not a then
            a = { t = 0, harmful = harmful }
            out[name] = a
        end
        a.t = a.t + t
    end
    for n, a in pairs(seg.auras) do add(n, a.harmful, a.t) end
    local live = self.fight
    if seg.isOverall and live then
        for n, a in pairs(live.auras) do add(n, a.harmful, a.t) end
    end
    if live and (seg == live or seg.isOverall) then
        local stop = self:SegEnd(live)
        for n, a in pairs(self.myAuras) do add(n, a.harmful, overlap(a.since, GetTime(), live.start, stop)) end
    end
    return out
end

-- Sorted rows for a mode and segment: { name, class, total, perSec, ... }, total, source, duration
function C:RowsFor(modeKey, seg, segKind)
    local m = C.MODE[modeKey] or C.MODE.dmg
    local now = GetTime()
    if segKind == "current" and m.value == "dmg" and self.server and now - self.server.t < 4 then
        local list = self.server.list
        if m.sortRate then
            list = {}
            for _, r in ipairs(self.server.list) do tinsert(list, r) end
            table.sort(list, function(a, b) return a.perSec > b.perSec end)
        end
        return list, self.server.total, "server", self.server.dur
    end
    if not seg then return {}, 0, "local", 0 end
    local dur = self:Duration(seg)
    local list, total = {}, 0
    if m.special == "deaths" then
        for i = getn(seg.deaths), 1, -1 do
            local d = seg.deaths[i]
            tinsert(list, { name = d.name, class = d.class, total = 1, death = d })
            total = total + 1
        end
        return list, total, "local", dur
    elseif m.special == "auras" then
        for n, a in pairs(self:AuraTimes(seg)) do
            if a.t > 0 then
                tinsert(list, { name = n, total = a.t, aura = true, harmful = a.harmful,
                    icon = a.harmful and DEBUFF_ICON or BUFF_ICON })
            end
        end
        table.sort(list, function(a, b) return a.total > b.total end)
        return list, dur, "local", dur
    end
    local key = m.value
    for name, p in pairs(seg.players) do
        local v = p[key] or 0
        if v > 0 then
            local row = { name = name, class = p.class, total = v, perSec = v / dur }
            if key == "overheal" then row.known = p.healKnown or 0 end
            if key == "power" then
                local best, bv
                for k, x in pairs(p) do
                    if type(x) == "number" and strsub(k, 1, 3) == "pw_" and (not bv or x > bv) then best, bv = strsub(k, 4), x end
                end
                row.ptype = best
            end
            tinsert(list, row)
            total = total + v
        end
    end
    if m.sortRate then
        table.sort(list, function(a, b) return a.perSec > b.perSec end)
    else
        table.sort(list, function(a, b) return a.total > b.total end)
    end
    return list, total, "local", dur
end

-- The main window's rows (the old entry point).
function C:Rows()
    local seg, kind = self:Segment("current")
    return self:RowsFor(self.mode, seg, kind)
end

-- -- Server packets (CH) -------------------------------------------------------

function C:HandlePacket(body)
    if strsub(body, 1, 8) == "inspect," then
        local parts, n = W.Split(strsub(body, 9), ";")
        local list = {}
        for i = 2, n do
            local f = W.Split(parts[i], ",")
            if f[1] ~= "" and tonumber(f[2]) then
                tinsert(list, { name = f[1], amount = tonumber(f[2]), pct = f[3] })
            end
        end
        self.inspectData[parts[1]] = list
        return
    end
    local recs, n = W.Split(body, ";")
    local list, total, dur = {}, 0, 0
    for i = 1, n do
        local f = W.Split(recs[i], ",")
        local tot = tonumber(f[3])
        if f[1] ~= "" and tot then
            local per = tonumber(f[4]) or 0
            tinsert(list, { name = f[1], class = UI.ClassToken(f[2]), total = tot, perSec = per })
            total = total + tot
            if per > 0 and tot / per > dur then dur = tot / per end
        end
    end
    table.sort(list, function(a, b) return a.total > b.total end)
    self.server = { list = list, total = total, t = GetTime(), dur = dur }
    self.dirty = true
end

W:RegisterModule("CH", function(body) C:HandlePacket(body) end)
