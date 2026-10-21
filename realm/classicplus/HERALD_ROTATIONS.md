# Herald solo-leveling rotations (custom strategies)

The SQL creates 27 custom strategies, named `herald_<class>_<band>` with band 1 (levels 1-19), 20 (20-39) or 40 (40-60). They are loaded into `classiccharacters.ai_playerbot_custom_strategy` with owner 0. Enable one in combat with `.bot cmd <name> co +custom::herald_<class>_<band>`. When the character changes band, swap with `co -custom::herald_<class>_<old>`.

## How the lines are read (verified in the pinned tree)

- `strategy/CustomStrategy.cpp`: the parser splits each line on `>` into a trigger and an action list. The action list splits on `,` (only outside `{}`) and each action splits on `!` into a name and a relevance. A missing relevance falls back to ACTION_NORMAL (10). The parser does not trim whitespace, so `a>b, c!5` creates an action named `" c"`, which fails silently. Every line in the SQL has no spaces around `>`, `,` and `!`.
- The names resolve through `NamedObjectFactory::Create` (`strategy/NamedObjectContext.h:158`). An unknown name returns null, and the engine skips a trigger it cannot build (`Engine.cpp` ProcessTriggers). An action whose spell is not trained fails `isPossible()`, and the engine moves on to the next-highest action. That is why fallback chains like `seal of command!15,seal of righteousness!14` work.
- The lookup checks the bot's own strategy (owner = bot guid) first and falls back to owner 0. Loaded lines are cached, so after editing rows, toggle the strategy off and on.
- No class has a multiplier that would zero out these actions (`*/…Multipliers.cpp` are empty in this tree).
- Relevance tiers (`strategy/Strategy.h:27-39`): IDLE 1, NORMAL 10, HIGH 20, MOVE 30 (flee, charge), INTERRUPT 40, DISPEL 50, LIGHT/MEDIUM/CRITICAL HEAL 60/70/80, EMERGENCY 90. Damage lines sit at 12-29, just above the class rotation. Control lines (Frost Nova, Hammer of Justice, Evasion) sit at 35-45, above moving and below dispels. Self-heals sit at 50-65, below the class critical heals. Fillers sit at 5-9, so the class rotation still beats them.

## Trigger semantics that shaped the choices

| Trigger | What it actually checks (file) |
|---|---|
| `low health` / `medium health` | HP **range** 20-50% / 50-70% (HealthTriggers.h, PlayerbotAIConfig.cpp:151-154). Neither fires below 20%; that is `critical health`. |
| `low mana` / `medium mana` / `no mana` | mana < 15% / < 40% / < 5% (GenericTriggers.cpp:13-31). `high mana` means < 65%. |
| `target critical health` | target HP < 20% (HealthTriggers.h:112) |
| `enemy five yards` / `enemy ten yards` / `enemy is close` | current target within 5 / 10 / TooCloseDistance (5) yd (RangeTriggers.h:175-215) |
| `multiple attackers` | in combat and ≥ 2 mobs attacking me (GenericTriggers.cpp:201) |
| `has attackers` | ≥ 1 attacker. Used as the "always in combat" trigger for fillers. |
| `<x> snare` / `... on snare target` | a fleeing mob, or (for ranged bots) a mob chasing me (values/SnareTargetValue.cpp). Covers "Hamstring runners". |
| `3 combo` / `4 combo` / `combo points available` | ≥ 3 / ≥ 4 / ≥ 5 CP on the target |
| rage triggers | ≥ 20 / 40 / 60 rage (light / medium / high) |
| `seal` (paladin) | no seal aura of any kind and in combat |
| `shock` (shaman) | no Frost, Earth or Flame Shock on the target |
| `no stings` (hunter) | target above 40% HP and no Serpent, Scorpid or Viper Sting |

Note: `melee light aoe` is registered as `RangedLightAoeTrigger` (TriggerContext.h:102, a copy-paste bug in the tree), so these strategies use `multiple attackers` instead.

## Warrior

### herald_warrior_1 (levels 1-19)

Priority: Battle stance. Charge in (class rotation). Battle Shout up, Rend, then Overpower whenever it lights up, Hamstring anything that runs, Thunder Clap when 2+ mobs are on you, Bloodrage for rage, Heroic Strike only as a rage dump (40+).

```
hamstring>hamstring!28
overpower>overpower!27
battle shout>battle shout!26
multiple attackers>thunder clap!25
rend>rend!24
bloodrage>bloodrage!23
medium rage available>heroic strike!15
```
Verified: `hamstring` (strategy/warrior/WarriorAiObjectContext.cpp:130); `hamstring` (strategy/warrior/WarriorAiObjectContext.cpp:200); `overpower` (strategy/warrior/WarriorAiObjectContext.cpp:150); `overpower` (strategy/warrior/WarriorAiObjectContext.cpp:189); `battle shout` (strategy/warrior/WarriorAiObjectContext.cpp:133); `battle shout` (strategy/warrior/WarriorAiObjectContext.cpp:210); `multiple attackers` (strategy/triggers/TriggerContext.h:125); `thunder clap` (strategy/warrior/WarriorAiObjectContext.cpp:212); `rend` (strategy/warrior/WarriorAiObjectContext.cpp:134); `rend` (strategy/warrior/WarriorAiObjectContext.cpp:192); `bloodrage` (strategy/warrior/WarriorAiObjectContext.cpp:136); `bloodrage` (strategy/warrior/WarriorAiObjectContext.cpp:203); `medium rage available` (strategy/triggers/TriggerContext.h:69); `heroic strike` (strategy/warrior/WarriorAiObjectContext.cpp:205)

### herald_warrior_20 (levels 20-39)

Priority: Same opener. Execute below 20%, Overpower, Hamstring runners, Battle Shout. On 2+ mobs: Sweeping Strikes (Arms 30), Thunder Clap, Demoralizing Shout. Rend on long fights, Bloodrage, Heroic Strike at 40+ rage.

```
target critical health>execute!29
hamstring>hamstring!28
overpower>overpower!27
multiple attackers>sweeping strikes!26,thunder clap!25,demoralizing shout!24
battle shout>battle shout!25
rend>rend!23
bloodrage>bloodrage!22
medium rage available>heroic strike!15
```
Verified: `target critical health` (strategy/triggers/TriggerContext.h:48); `execute` (strategy/warrior/WarriorAiObjectContext.cpp:198); `hamstring` (strategy/warrior/WarriorAiObjectContext.cpp:130); `hamstring` (strategy/warrior/WarriorAiObjectContext.cpp:200); `overpower` (strategy/warrior/WarriorAiObjectContext.cpp:150); `overpower` (strategy/warrior/WarriorAiObjectContext.cpp:189); `multiple attackers` (strategy/triggers/TriggerContext.h:125); `sweeping strikes` (strategy/warrior/WarriorAiObjectContext.cpp:229); `thunder clap` (strategy/warrior/WarriorAiObjectContext.cpp:212); `demoralizing shout` (strategy/warrior/WarriorAiObjectContext.cpp:207); `battle shout` (strategy/warrior/WarriorAiObjectContext.cpp:133); `battle shout` (strategy/warrior/WarriorAiObjectContext.cpp:210); `rend` (strategy/warrior/WarriorAiObjectContext.cpp:134); `rend` (strategy/warrior/WarriorAiObjectContext.cpp:192); `bloodrage` (strategy/warrior/WarriorAiObjectContext.cpp:136); `bloodrage` (strategy/warrior/WarriorAiObjectContext.cpp:203); `medium rage available` (strategy/triggers/TriggerContext.h:69); `heroic strike` (strategy/warrior/WarriorAiObjectContext.cpp:205)

### herald_warrior_40 (levels 40-60)

Priority: Execute, Hamstring runners, Overpower, Mortal Strike / Bloodthirst on cooldown, Battle Shout; Sweeping Strikes + Thunder Clap + Demo Shout on packs; Bloodrage; Heroic Strike only at 60+ rage. Rend dropped (mobs die too fast).

```
target critical health>execute!29
hamstring>hamstring!28
overpower>overpower!27
light rage available>mortal strike!26,bloodthirst!25
battle shout>battle shout!24
multiple attackers>sweeping strikes!26,thunder clap!23,demoralizing shout!22
bloodrage>bloodrage!21
high rage available>heroic strike!18
```
Verified: `target critical health` (strategy/triggers/TriggerContext.h:48); `execute` (strategy/warrior/WarriorAiObjectContext.cpp:198); `hamstring` (strategy/warrior/WarriorAiObjectContext.cpp:130); `hamstring` (strategy/warrior/WarriorAiObjectContext.cpp:200); `overpower` (strategy/warrior/WarriorAiObjectContext.cpp:150); `overpower` (strategy/warrior/WarriorAiObjectContext.cpp:189); `light rage available` (strategy/triggers/TriggerContext.h:68); `mortal strike` (strategy/warrior/WarriorAiObjectContext.cpp:228); `bloodthirst` (strategy/warrior/WarriorAiObjectContext.cpp:191); `battle shout` (strategy/warrior/WarriorAiObjectContext.cpp:133); `battle shout` (strategy/warrior/WarriorAiObjectContext.cpp:210); `multiple attackers` (strategy/triggers/TriggerContext.h:125); `sweeping strikes` (strategy/warrior/WarriorAiObjectContext.cpp:229); `thunder clap` (strategy/warrior/WarriorAiObjectContext.cpp:212); `demoralizing shout` (strategy/warrior/WarriorAiObjectContext.cpp:207); `bloodrage` (strategy/warrior/WarriorAiObjectContext.cpp:136); `bloodrage` (strategy/warrior/WarriorAiObjectContext.cpp:203); `high rage available` (strategy/triggers/TriggerContext.h:70); `heroic strike` (strategy/warrior/WarriorAiObjectContext.cpp:205)

## Paladin

### herald_paladin_1 (levels 1-19)

Priority: Seal of Righteousness (Seal of Command once talented), Judgement on cooldown and re-seal, Blessing of Might up, Hammer of Justice on runners, Exorcism vs undead/demons, Holy Light at low health.

```
seal>seal of command!15,seal of righteousness!14
judgement>judgement!16
exorcism>exorcism!18
blessing of might>blessing of might!21
hammer of justice snare>hammer of justice!35
low health>holy light!65
```
Verified: `seal` (strategy/paladin/PaladinAiObjectContext.cpp:242); `seal of command` (strategy/paladin/PaladinAiObjectContext.cpp:313); `seal of righteousness` (strategy/paladin/PaladinAiObjectContext.cpp:380); `judgement` (strategy/paladin/PaladinAiObjectContext.cpp:239); `judgement` (strategy/paladin/PaladinAiObjectContext.cpp:385); `exorcism` (strategy/paladin/PaladinAiObjectContext.cpp:297); `exorcism` (strategy/paladin/PaladinAiObjectContext.cpp:384); `blessing of might` (strategy/paladin/PaladinAiObjectContext.cpp:246); `blessing of might` (strategy/paladin/PaladinAiObjectContext.cpp:329); `hammer of justice snare` (strategy/paladin/PaladinAiObjectContext.cpp:281); `hammer of justice` (strategy/paladin/PaladinAiObjectContext.cpp:391); `low health` (strategy/triggers/TriggerContext.h:51); `holy light` (strategy/paladin/PaladinAiObjectContext.cpp:393)

### herald_paladin_20 (levels 20-39)

Priority: As 1-19, plus Consecration when 2+ mobs are on you.

```
seal>seal of command!15,seal of righteousness!14
judgement>judgement!16
exorcism>exorcism!18
multiple attackers>consecration!24
blessing of might>blessing of might!21
hammer of justice snare>hammer of justice!35
low health>holy light!65
```
Verified: `seal` (strategy/paladin/PaladinAiObjectContext.cpp:242); `seal of command` (strategy/paladin/PaladinAiObjectContext.cpp:313); `seal of righteousness` (strategy/paladin/PaladinAiObjectContext.cpp:380); `judgement` (strategy/paladin/PaladinAiObjectContext.cpp:239); `judgement` (strategy/paladin/PaladinAiObjectContext.cpp:385); `exorcism` (strategy/paladin/PaladinAiObjectContext.cpp:297); `exorcism` (strategy/paladin/PaladinAiObjectContext.cpp:384); `multiple attackers` (strategy/triggers/TriggerContext.h:125); `consecration` (strategy/paladin/PaladinAiObjectContext.cpp:367); `blessing of might` (strategy/paladin/PaladinAiObjectContext.cpp:246); `blessing of might` (strategy/paladin/PaladinAiObjectContext.cpp:329); `hammer of justice snare` (strategy/paladin/PaladinAiObjectContext.cpp:281); `hammer of justice` (strategy/paladin/PaladinAiObjectContext.cpp:391); `low health` (strategy/triggers/TriggerContext.h:51); `holy light` (strategy/paladin/PaladinAiObjectContext.cpp:393)

### herald_paladin_40 (levels 40-60)

Priority: As 20-39, plus Hammer of Wrath (44) as an execute below 20%.

```
target critical health>hammer of wrath!27
seal>seal of command!15,seal of righteousness!14
judgement>judgement!16
exorcism>exorcism!18
multiple attackers>consecration!24
blessing of might>blessing of might!21
hammer of justice snare>hammer of justice!35
low health>holy light!65
```
Verified: `target critical health` (strategy/triggers/TriggerContext.h:48); `hammer of wrath` (strategy/paladin/PaladinAiObjectContext.cpp:398); `seal` (strategy/paladin/PaladinAiObjectContext.cpp:242); `seal of command` (strategy/paladin/PaladinAiObjectContext.cpp:313); `seal of righteousness` (strategy/paladin/PaladinAiObjectContext.cpp:380); `judgement` (strategy/paladin/PaladinAiObjectContext.cpp:239); `judgement` (strategy/paladin/PaladinAiObjectContext.cpp:385); `exorcism` (strategy/paladin/PaladinAiObjectContext.cpp:297); `exorcism` (strategy/paladin/PaladinAiObjectContext.cpp:384); `multiple attackers` (strategy/triggers/TriggerContext.h:125); `consecration` (strategy/paladin/PaladinAiObjectContext.cpp:367); `blessing of might` (strategy/paladin/PaladinAiObjectContext.cpp:246); `blessing of might` (strategy/paladin/PaladinAiObjectContext.cpp:329); `hammer of justice snare` (strategy/paladin/PaladinAiObjectContext.cpp:281); `hammer of justice` (strategy/paladin/PaladinAiObjectContext.cpp:391); `low health` (strategy/triggers/TriggerContext.h:51); `holy light` (strategy/paladin/PaladinAiObjectContext.cpp:393)

## Hunter

### herald_hunter_1 (levels 1-19)

Priority: Pet in first, Hunter's Mark (class), Serpent Sting, Arcane Shot (6) on cooldown, Auto Shot; Concussive Shot on a mob chasing you; in melee Wing Clip then Raptor Strike, Mongoose Bite after a dodge; Mend Pet when the pet drops below 40%. Aspect of the Monkey until Hawk (10) is trained.

```
hunters pet low health>mend pet!45
aspect of the hawk>aspect of the hawk!26,aspect of the monkey!25
mongoose bite>mongoose bite!25
enemy is close>wing clip!24,raptor strike!23
concussive shot on snare target>concussive shot!21
no stings>serpent sting!19
enemy out of melee>arcane shot!15
```
Verified: `hunters pet low health` (strategy/hunter/HunterAiObjectContext.cpp:197); `mend pet` (strategy/hunter/HunterAiObjectContext.cpp:266); `aspect of the hawk` (strategy/hunter/HunterAiObjectContext.cpp:204); `aspect of the hawk` (strategy/hunter/HunterAiObjectContext.cpp:275); `aspect of the monkey` (strategy/hunter/HunterAiObjectContext.cpp:274); `mongoose bite` (strategy/hunter/HunterAiObjectContext.cpp:232); `mongoose bite` (strategy/hunter/HunterAiObjectContext.cpp:298); `enemy is close` (strategy/triggers/TriggerContext.h:117); `wing clip` (strategy/hunter/HunterAiObjectContext.cpp:285); `raptor strike` (strategy/hunter/HunterAiObjectContext.cpp:286); `concussive shot on snare target` (strategy/hunter/HunterAiObjectContext.cpp:216); `concussive shot` (strategy/hunter/HunterAiObjectContext.cpp:255); `no stings` (strategy/hunter/HunterAiObjectContext.cpp:195); `serpent sting` (strategy/hunter/HunterAiObjectContext.cpp:259); `enemy out of melee` (strategy/triggers/TriggerContext.h:112); `arcane shot` (strategy/hunter/HunterAiObjectContext.cpp:253)

### herald_hunter_20 (levels 20-39)

Priority: Same priority; Aimed Shot (MM 20) is already in the class rotation with Arcane Shot as its fallback.

```
hunters pet low health>mend pet!45
aspect of the hawk>aspect of the hawk!26,aspect of the monkey!25
mongoose bite>mongoose bite!25
enemy is close>wing clip!24,raptor strike!23
concussive shot on snare target>concussive shot!21
no stings>serpent sting!19
enemy out of melee>arcane shot!15
```
Verified: `hunters pet low health` (strategy/hunter/HunterAiObjectContext.cpp:197); `mend pet` (strategy/hunter/HunterAiObjectContext.cpp:266); `aspect of the hawk` (strategy/hunter/HunterAiObjectContext.cpp:204); `aspect of the hawk` (strategy/hunter/HunterAiObjectContext.cpp:275); `aspect of the monkey` (strategy/hunter/HunterAiObjectContext.cpp:274); `mongoose bite` (strategy/hunter/HunterAiObjectContext.cpp:232); `mongoose bite` (strategy/hunter/HunterAiObjectContext.cpp:298); `enemy is close` (strategy/triggers/TriggerContext.h:117); `wing clip` (strategy/hunter/HunterAiObjectContext.cpp:285); `raptor strike` (strategy/hunter/HunterAiObjectContext.cpp:286); `concussive shot on snare target` (strategy/hunter/HunterAiObjectContext.cpp:216); `concussive shot` (strategy/hunter/HunterAiObjectContext.cpp:255); `no stings` (strategy/hunter/HunterAiObjectContext.cpp:195); `serpent sting` (strategy/hunter/HunterAiObjectContext.cpp:259); `enemy out of melee` (strategy/triggers/TriggerContext.h:112); `arcane shot` (strategy/hunter/HunterAiObjectContext.cpp:253)

### herald_hunter_40 (levels 40-60)

Priority: Same priority; Counterattack/Deterrence/Rapid Fire come from the class strategies.

```
hunters pet low health>mend pet!45
aspect of the hawk>aspect of the hawk!26,aspect of the monkey!25
mongoose bite>mongoose bite!25
enemy is close>wing clip!24,raptor strike!23
concussive shot on snare target>concussive shot!21
no stings>serpent sting!19
enemy out of melee>arcane shot!15
```
Verified: `hunters pet low health` (strategy/hunter/HunterAiObjectContext.cpp:197); `mend pet` (strategy/hunter/HunterAiObjectContext.cpp:266); `aspect of the hawk` (strategy/hunter/HunterAiObjectContext.cpp:204); `aspect of the hawk` (strategy/hunter/HunterAiObjectContext.cpp:275); `aspect of the monkey` (strategy/hunter/HunterAiObjectContext.cpp:274); `mongoose bite` (strategy/hunter/HunterAiObjectContext.cpp:232); `mongoose bite` (strategy/hunter/HunterAiObjectContext.cpp:298); `enemy is close` (strategy/triggers/TriggerContext.h:117); `wing clip` (strategy/hunter/HunterAiObjectContext.cpp:285); `raptor strike` (strategy/hunter/HunterAiObjectContext.cpp:286); `concussive shot on snare target` (strategy/hunter/HunterAiObjectContext.cpp:216); `concussive shot` (strategy/hunter/HunterAiObjectContext.cpp:255); `no stings` (strategy/hunter/HunterAiObjectContext.cpp:195); `serpent sting` (strategy/hunter/HunterAiObjectContext.cpp:259); `enemy out of melee` (strategy/triggers/TriggerContext.h:112); `arcane shot` (strategy/hunter/HunterAiObjectContext.cpp:253)

## Rogue

### herald_rogue_1 (levels 1-19)

Priority: Sinister Strike to build (Backstab if behind with a dagger), Slice and Dice at 3 CP when it is down, Eviscerate at 3+ CP; Evasion (8) when 2+ mobs are on you.

```
multiple attackers>evasion!40
slice and dice>slice and dice!26
3 combo>eviscerate!24
behind target>backstab!13
sinister strike>sinister strike!12
```
Verified: `multiple attackers` (strategy/triggers/TriggerContext.h:125); `evasion` (strategy/rogue/RogueAiObjectContext.cpp:251); `slice and dice` (strategy/rogue/RogueAiObjectContext.cpp:198); `slice and dice` (strategy/rogue/RogueAiObjectContext.cpp:248); `3 combo` (strategy/rogue/RogueAiObjectContext.cpp:209); `eviscerate` (strategy/rogue/RogueAiObjectContext.cpp:249); `behind target` (strategy/triggers/TriggerContext.h:139); `backstab` (strategy/rogue/RogueAiObjectContext.cpp:254); `sinister strike` (strategy/rogue/RogueAiObjectContext.cpp:211); `sinister strike` (strategy/rogue/RogueAiObjectContext.cpp:242)

### herald_rogue_20 (levels 20-39)

Priority: Riposte when it procs, Slice and Dice up, Eviscerate at 4+ CP (beats the class Rupture at 4 CP), Evasion + Blade Flurry on 2+ mobs, Sinister Strike / Backstab builder.

```
multiple attackers>evasion!40,blade flurry!28
riposte>riposte!27
slice and dice>slice and dice!26
4 combo>eviscerate!24
behind target>backstab!13
sinister strike>sinister strike!12
```
Verified: `multiple attackers` (strategy/triggers/TriggerContext.h:125); `evasion` (strategy/rogue/RogueAiObjectContext.cpp:251); `blade flurry` (strategy/rogue/RogueAiObjectContext.cpp:257); `riposte` (strategy/rogue/RogueAiObjectContext.cpp:219); `riposte` (strategy/rogue/RogueAiObjectContext.cpp:240); `slice and dice` (strategy/rogue/RogueAiObjectContext.cpp:198); `slice and dice` (strategy/rogue/RogueAiObjectContext.cpp:248); `4 combo` (strategy/rogue/RogueAiObjectContext.cpp:210); `eviscerate` (strategy/rogue/RogueAiObjectContext.cpp:249); `behind target` (strategy/triggers/TriggerContext.h:139); `backstab` (strategy/rogue/RogueAiObjectContext.cpp:254); `sinister strike` (strategy/rogue/RogueAiObjectContext.cpp:211); `sinister strike` (strategy/rogue/RogueAiObjectContext.cpp:242)

### herald_rogue_40 (levels 40-60)

Priority: As 20-39, plus Adrenaline Rush on packs.

```
multiple attackers>evasion!40,adrenaline rush!29,blade flurry!28
riposte>riposte!27
slice and dice>slice and dice!26
4 combo>eviscerate!24
behind target>backstab!13
sinister strike>sinister strike!12
```
Verified: `multiple attackers` (strategy/triggers/TriggerContext.h:125); `evasion` (strategy/rogue/RogueAiObjectContext.cpp:251); `adrenaline rush` (strategy/rogue/RogueAiObjectContext.cpp:258); `blade flurry` (strategy/rogue/RogueAiObjectContext.cpp:257); `riposte` (strategy/rogue/RogueAiObjectContext.cpp:219); `riposte` (strategy/rogue/RogueAiObjectContext.cpp:240); `slice and dice` (strategy/rogue/RogueAiObjectContext.cpp:198); `slice and dice` (strategy/rogue/RogueAiObjectContext.cpp:248); `4 combo` (strategy/rogue/RogueAiObjectContext.cpp:210); `eviscerate` (strategy/rogue/RogueAiObjectContext.cpp:249); `behind target` (strategy/triggers/TriggerContext.h:139); `backstab` (strategy/rogue/RogueAiObjectContext.cpp:254); `sinister strike` (strategy/rogue/RogueAiObjectContext.cpp:211); `sinister strike` (strategy/rogue/RogueAiObjectContext.cpp:242)

## Priest

### herald_priest_1 (levels 1-19)

Priority: Power Word: Shield when something is hitting you, Shadow Word: Pain, Mind Blast on cooldown, Smite filler while mana is above 40%, then wand; Renew at 50-70% health.

```
target of attacker>power word: shield!27
shadow word: pain>shadow word: pain!25
mind blast>mind blast!23
medium health>renew!55
medium mana>shoot!9
smite>smite!8
```
Verified: `target of attacker` (strategy/triggers/TriggerContext.h:194); `power word: shield` (strategy/priest/PriestAiObjectContext.cpp:235); `shadow word: pain` (strategy/priest/PriestAiObjectContext.cpp:173); `shadow word: pain` (strategy/priest/PriestAiObjectContext.cpp:221); `mind blast` (strategy/priest/PriestAiObjectContext.cpp:208); `mind blast` (strategy/priest/PriestAiObjectContext.cpp:227); `medium health` (strategy/triggers/TriggerContext.h:52); `renew` (strategy/priest/PriestAiObjectContext.cpp:237); `medium mana` (strategy/triggers/TriggerContext.h:57); `shoot` (strategy/actions/ActionContext.h:123); `smite` (strategy/priest/PriestAiObjectContext.cpp:209); `smite` (strategy/priest/PriestAiObjectContext.cpp:226)

### herald_priest_20 (levels 20-39)

Priority: Shield, SW:Pain, Mind Blast, Mind Flay (talent) as filler above 40% mana, else wand; Smite only if no Mind Flay; Renew at 50-70%.

```
target of attacker>power word: shield!27
shadow word: pain>shadow word: pain!25
mind blast>mind blast!23
medium health>renew!55
medium mana>shoot!9
has attackers>mind flay!8
smite>smite!7
```
Verified: `target of attacker` (strategy/triggers/TriggerContext.h:194); `power word: shield` (strategy/priest/PriestAiObjectContext.cpp:235); `shadow word: pain` (strategy/priest/PriestAiObjectContext.cpp:173); `shadow word: pain` (strategy/priest/PriestAiObjectContext.cpp:221); `mind blast` (strategy/priest/PriestAiObjectContext.cpp:208); `mind blast` (strategy/priest/PriestAiObjectContext.cpp:227); `medium health` (strategy/triggers/TriggerContext.h:52); `renew` (strategy/priest/PriestAiObjectContext.cpp:237); `medium mana` (strategy/triggers/TriggerContext.h:57); `shoot` (strategy/actions/ActionContext.h:123); `has attackers` (strategy/triggers/TriggerContext.h:134); `mind flay` (strategy/priest/PriestAiObjectContext.cpp:224); `smite` (strategy/priest/PriestAiObjectContext.cpp:209); `smite` (strategy/priest/PriestAiObjectContext.cpp:226)

### herald_priest_40 (levels 40-60)

Priority: Shield, Vampiric Embrace, SW:Pain, Mind Blast, Mind Flay, wand below 40% mana. No Renew line (Renew would drop Shadowform).

```
target of attacker>power word: shield!27
shadow word: pain>shadow word: pain!25
vampiric embrace>vampiric embrace!24
mind blast>mind blast!23
medium mana>shoot!9
has attackers>mind flay!8
smite>smite!7
```
Verified: `target of attacker` (strategy/triggers/TriggerContext.h:194); `power word: shield` (strategy/priest/PriestAiObjectContext.cpp:235); `shadow word: pain` (strategy/priest/PriestAiObjectContext.cpp:173); `shadow word: pain` (strategy/priest/PriestAiObjectContext.cpp:221); `vampiric embrace` (strategy/priest/PriestAiObjectContext.cpp:186); `vampiric embrace` (strategy/priest/PriestAiObjectContext.cpp:261); `mind blast` (strategy/priest/PriestAiObjectContext.cpp:208); `mind blast` (strategy/priest/PriestAiObjectContext.cpp:227); `medium mana` (strategy/triggers/TriggerContext.h:57); `shoot` (strategy/actions/ActionContext.h:123); `has attackers` (strategy/triggers/TriggerContext.h:134); `mind flay` (strategy/priest/PriestAiObjectContext.cpp:224); `smite` (strategy/priest/PriestAiObjectContext.cpp:209); `smite` (strategy/priest/PriestAiObjectContext.cpp:226)

## Shaman

### herald_shaman_1 (levels 1-19)

Priority: Rockbiter Weapon, Lightning Shield, Lightning Bolt while the mob runs in, then melee; Flame Shock (else Earth Shock) when no shock is on the target; Earth Shock as a finisher below 20%; Frost Shock (20) on runners.

```
frost shock snare>frost shock!27
shaman weapon>rockbiter weapon!26
target critical health>earth shock!25
lightning shield>lightning shield!22
shock>flame shock!16,earth shock!15
enemy out of melee>lightning bolt!12
```
Verified: `frost shock snare` (strategy/shaman/ShamanAiObjectContext.cpp:272); `frost shock` (strategy/shaman/ShamanAiObjectContext.cpp:357); `shaman weapon` (strategy/shaman/ShamanAiObjectContext.cpp:258); `rockbiter weapon` (strategy/shaman/ShamanAiObjectContext.cpp:328); `target critical health` (strategy/triggers/TriggerContext.h:48); `earth shock` (strategy/shaman/ShamanAiObjectContext.cpp:356); `lightning shield` (strategy/shaman/ShamanAiObjectContext.cpp:260); `lightning shield` (strategy/shaman/ShamanAiObjectContext.cpp:302); `shock` (strategy/shaman/ShamanAiObjectContext.cpp:271); `flame shock` (strategy/shaman/ShamanAiObjectContext.cpp:355); `enemy out of melee` (strategy/triggers/TriggerContext.h:112); `lightning bolt` (strategy/shaman/ShamanAiObjectContext.cpp:359)

### herald_shaman_20 (levels 20-39)

Priority: Same as 1-19, but Windfury Weapon once trained (30), Rockbiter before that.

```
frost shock snare>frost shock!27
shaman weapon>windfury weapon!26,rockbiter weapon!25
target critical health>earth shock!25
lightning shield>lightning shield!22
shock>flame shock!16,earth shock!15
enemy out of melee>lightning bolt!12
```
Verified: `frost shock snare` (strategy/shaman/ShamanAiObjectContext.cpp:272); `frost shock` (strategy/shaman/ShamanAiObjectContext.cpp:357); `shaman weapon` (strategy/shaman/ShamanAiObjectContext.cpp:258); `windfury weapon` (strategy/shaman/ShamanAiObjectContext.cpp:331); `rockbiter weapon` (strategy/shaman/ShamanAiObjectContext.cpp:328); `target critical health` (strategy/triggers/TriggerContext.h:48); `earth shock` (strategy/shaman/ShamanAiObjectContext.cpp:356); `lightning shield` (strategy/shaman/ShamanAiObjectContext.cpp:260); `lightning shield` (strategy/shaman/ShamanAiObjectContext.cpp:302); `shock` (strategy/shaman/ShamanAiObjectContext.cpp:271); `flame shock` (strategy/shaman/ShamanAiObjectContext.cpp:355); `enemy out of melee` (strategy/triggers/TriggerContext.h:112); `lightning bolt` (strategy/shaman/ShamanAiObjectContext.cpp:359)

### herald_shaman_40 (levels 40-60)

Priority: Windfury Weapon, Stormstrike (talent) on cooldown, then the same shock, finisher and snare logic.

```
frost shock snare>frost shock!27
shaman weapon>windfury weapon!26,rockbiter weapon!25
target critical health>earth shock!25
stormstrike>stormstrike!24
lightning shield>lightning shield!22
shock>flame shock!16,earth shock!15
enemy out of melee>lightning bolt!12
```
Verified: `frost shock snare` (strategy/shaman/ShamanAiObjectContext.cpp:272); `frost shock` (strategy/shaman/ShamanAiObjectContext.cpp:357); `shaman weapon` (strategy/shaman/ShamanAiObjectContext.cpp:258); `windfury weapon` (strategy/shaman/ShamanAiObjectContext.cpp:331); `rockbiter weapon` (strategy/shaman/ShamanAiObjectContext.cpp:328); `target critical health` (strategy/triggers/TriggerContext.h:48); `earth shock` (strategy/shaman/ShamanAiObjectContext.cpp:356); `stormstrike` (strategy/shaman/ShamanAiObjectContext.cpp:292); `stormstrike` (strategy/shaman/ShamanAiObjectContext.cpp:343); `lightning shield` (strategy/shaman/ShamanAiObjectContext.cpp:260); `lightning shield` (strategy/shaman/ShamanAiObjectContext.cpp:302); `shock` (strategy/shaman/ShamanAiObjectContext.cpp:271); `flame shock` (strategy/shaman/ShamanAiObjectContext.cpp:355); `enemy out of melee` (strategy/triggers/TriggerContext.h:112); `lightning bolt` (strategy/shaman/ShamanAiObjectContext.cpp:359)

## Mage

### herald_mage_1 (levels 1-19)

Priority: Frostbolt filler (Fireball before it is trained at 4), Frost Nova when the mob reaches you (then the ranged strategy steps back), Fire Blast in melee and as a finisher, wand below 15% mana.

```
enemy five yards>frost nova!35,fire blast!27
target critical health>fire blast!28
low mana>shoot!12
has attackers>frostbolt!6,fireball!5
```
Verified: `enemy five yards` (strategy/triggers/TriggerContext.h:121); `frost nova` (strategy/mage/MageAiObjectContext.cpp:210); `fire blast` (strategy/mage/MageAiObjectContext.cpp:225); `target critical health` (strategy/triggers/TriggerContext.h:48); `low mana` (strategy/triggers/TriggerContext.h:56); `shoot` (strategy/actions/ActionContext.h:123); `has attackers` (strategy/triggers/TriggerContext.h:134); `frostbolt` (strategy/mage/MageAiObjectContext.cpp:208); `fireball` (strategy/mage/MageAiObjectContext.cpp:222)

### herald_mage_20 (levels 20-39)

Priority: Frostbolt, Frost Nova at 10 yd then Cone of Cold, Fire Blast in melee and as a finisher, Mana Shield at 20-50% health, wand below 15% mana.

```
enemy ten yards>frost nova!35,cone of cold!27
enemy five yards>fire blast!26
target critical health>fire blast!28
low health>mana shield!25
low mana>shoot!12
has attackers>frostbolt!6
```
Verified: `enemy ten yards` (strategy/triggers/TriggerContext.h:120); `frost nova` (strategy/mage/MageAiObjectContext.cpp:210); `cone of cold` (strategy/mage/MageAiObjectContext.cpp:250); `enemy five yards` (strategy/triggers/TriggerContext.h:121); `fire blast` (strategy/mage/MageAiObjectContext.cpp:225); `target critical health` (strategy/triggers/TriggerContext.h:48); `low health` (strategy/triggers/TriggerContext.h:51); `mana shield` (strategy/mage/MageAiObjectContext.cpp:248); `low mana` (strategy/triggers/TriggerContext.h:56); `shoot` (strategy/actions/ActionContext.h:123); `has attackers` (strategy/triggers/TriggerContext.h:134); `frostbolt` (strategy/mage/MageAiObjectContext.cpp:208)

### herald_mage_40 (levels 40-60)

Priority: Ice Barrier kept up, then the same as 20-39.

```
ice barrier>ice barrier!29
enemy ten yards>frost nova!35,cone of cold!27
enemy five yards>fire blast!26
target critical health>fire blast!28
low health>mana shield!25
low mana>shoot!12
has attackers>frostbolt!6
```
Verified: `ice barrier` (strategy/mage/MageAiObjectContext.cpp:187); `ice barrier` (strategy/mage/MageAiObjectContext.cpp:247); `enemy ten yards` (strategy/triggers/TriggerContext.h:120); `frost nova` (strategy/mage/MageAiObjectContext.cpp:210); `cone of cold` (strategy/mage/MageAiObjectContext.cpp:250); `enemy five yards` (strategy/triggers/TriggerContext.h:121); `fire blast` (strategy/mage/MageAiObjectContext.cpp:225); `target critical health` (strategy/triggers/TriggerContext.h:48); `low health` (strategy/triggers/TriggerContext.h:51); `mana shield` (strategy/mage/MageAiObjectContext.cpp:248); `low mana` (strategy/triggers/TriggerContext.h:56); `shoot` (strategy/actions/ActionContext.h:123); `has attackers` (strategy/triggers/TriggerContext.h:134); `frostbolt` (strategy/mage/MageAiObjectContext.cpp:208)

## Warlock

### herald_warlock_1 (levels 1-19)

Priority: Pet tanks. Corruption, Curse of Agony, Immolate; wand below 40% mana instead of Shadow Bolt; Drain Life at 20-50% health; Life Tap and Drain Soul come from the class rotation.

```
corruption>corruption!24
no curse>curse of agony!23
immolate>immolate!22
low health>drain life!50
medium mana>shoot!9
```
Verified: `corruption` (strategy/warlock/WarlockAiObjectContext.cpp:201); `corruption` (strategy/warlock/WarlockAiObjectContext.cpp:274); `no curse` (strategy/warlock/WarlockAiObjectContext.cpp:236); `curse of agony` (strategy/warlock/WarlockAiObjectContext.cpp:279); `immolate` (strategy/warlock/WarlockAiObjectContext.cpp:222); `immolate` (strategy/warlock/WarlockAiObjectContext.cpp:273); `low health` (strategy/triggers/TriggerContext.h:51); `drain life` (strategy/warlock/WarlockAiObjectContext.cpp:296); `medium mana` (strategy/triggers/TriggerContext.h:57); `shoot` (strategy/actions/ActionContext.h:123)

### herald_warlock_20 (levels 20-39)

Priority: As 1-19, plus Siphon Life (talent 30).

```
corruption>corruption!24
no curse>curse of agony!23
immolate>immolate!22
siphon life>siphon life!21
low health>drain life!50
medium mana>shoot!9
```
Verified: `corruption` (strategy/warlock/WarlockAiObjectContext.cpp:201); `corruption` (strategy/warlock/WarlockAiObjectContext.cpp:274); `no curse` (strategy/warlock/WarlockAiObjectContext.cpp:236); `curse of agony` (strategy/warlock/WarlockAiObjectContext.cpp:279); `immolate` (strategy/warlock/WarlockAiObjectContext.cpp:222); `immolate` (strategy/warlock/WarlockAiObjectContext.cpp:273); `siphon life` (strategy/warlock/WarlockAiObjectContext.cpp:224); `siphon life` (strategy/warlock/WarlockAiObjectContext.cpp:277); `low health` (strategy/triggers/TriggerContext.h:51); `drain life` (strategy/warlock/WarlockAiObjectContext.cpp:296); `medium mana` (strategy/triggers/TriggerContext.h:57); `shoot` (strategy/actions/ActionContext.h:123)

### herald_warlock_40 (levels 40-60)

Priority: DoTs as before, then Drain Life as the filler instead of the wand (per leveling guides from ~38).

```
corruption>corruption!24
no curse>curse of agony!23
immolate>immolate!22
siphon life>siphon life!21
low health>drain life!50
has attackers>drain life!7
```
Verified: `corruption` (strategy/warlock/WarlockAiObjectContext.cpp:201); `corruption` (strategy/warlock/WarlockAiObjectContext.cpp:274); `no curse` (strategy/warlock/WarlockAiObjectContext.cpp:236); `curse of agony` (strategy/warlock/WarlockAiObjectContext.cpp:279); `immolate` (strategy/warlock/WarlockAiObjectContext.cpp:222); `immolate` (strategy/warlock/WarlockAiObjectContext.cpp:273); `siphon life` (strategy/warlock/WarlockAiObjectContext.cpp:224); `siphon life` (strategy/warlock/WarlockAiObjectContext.cpp:277); `low health` (strategy/triggers/TriggerContext.h:51); `drain life` (strategy/warlock/WarlockAiObjectContext.cpp:296); `has attackers` (strategy/triggers/TriggerContext.h:134)

## Druid

### herald_druid_1 (levels 1-19)

Priority: 1-9 caster: Moonfire then Wrath. 10-19 Bear Form: Maul at 45+ rage, Demoralizing Roar on 2+ mobs. Heals come from the class rotation (they shift out to caster form).

```
moonfire>moonfire!30
bear form>bear form!29
multiple attackers>demoralizing roar!20
medium rage available>maul!14
has attackers>wrath!6
```
Verified: `moonfire` (strategy/druid/DruidAiObjectContext.cpp:205); `moonfire` (strategy/druid/DruidAiObjectContext.cpp:278); `bear form` (strategy/druid/DruidAiObjectContext.cpp:220); `bear form` (strategy/druid/DruidAiObjectContext.cpp:255); `multiple attackers` (strategy/triggers/TriggerContext.h:125); `demoralizing roar` (strategy/druid/DruidAiObjectContext.cpp:268); `medium rage available` (strategy/triggers/TriggerContext.h:69); `maul` (strategy/druid/DruidAiObjectContext.cpp:264); `has attackers` (strategy/triggers/TriggerContext.h:134); `wrath` (strategy/druid/DruidAiObjectContext.cpp:275)

### herald_druid_20 (levels 20-39)

Priority: Cat Form: Faerie Fire (Feral, talent), Rake, Claw to build, Rip at 3+ CP when Rip is down, Ferocious Bite at 5 CP.

```
cat form>cat form!29
ferocious bite>ferocious bite!24
rip>rip!23
rake>rake!22
faerie fire (feral)>faerie fire (feral)!21
claw>claw!12
```
Verified: `cat form` (strategy/druid/DruidAiObjectContext.cpp:221); `cat form` (strategy/druid/DruidAiObjectContext.cpp:258); `ferocious bite` (strategy/druid/DruidAiObjectContext.cpp:228); `ferocious bite` (strategy/druid/DruidAiObjectContext.cpp:285); `rip` (strategy/druid/DruidAiObjectContext.cpp:230); `rip` (strategy/druid/DruidAiObjectContext.cpp:286); `rake` (strategy/druid/DruidAiObjectContext.cpp:208); `rake` (strategy/druid/DruidAiObjectContext.cpp:284); `faerie fire (feral)` (strategy/druid/DruidAiObjectContext.cpp:202); `faerie fire (feral)` (strategy/druid/DruidAiObjectContext.cpp:253); `claw` (strategy/druid/DruidAiObjectContext.cpp:229); `claw` (strategy/druid/DruidAiObjectContext.cpp:281)

### herald_druid_40 (levels 40-60)

Priority: As 20-39, plus Tiger's Fury.

```
cat form>cat form!29
ferocious bite>ferocious bite!24
rip>rip!23
rake>rake!22
faerie fire (feral)>faerie fire (feral)!21
tiger's fury>tiger's fury!20
claw>claw!12
```
Verified: `cat form` (strategy/druid/DruidAiObjectContext.cpp:221); `cat form` (strategy/druid/DruidAiObjectContext.cpp:258); `ferocious bite` (strategy/druid/DruidAiObjectContext.cpp:228); `ferocious bite` (strategy/druid/DruidAiObjectContext.cpp:285); `rip` (strategy/druid/DruidAiObjectContext.cpp:230); `rip` (strategy/druid/DruidAiObjectContext.cpp:286); `rake` (strategy/druid/DruidAiObjectContext.cpp:208); `rake` (strategy/druid/DruidAiObjectContext.cpp:284); `faerie fire (feral)` (strategy/druid/DruidAiObjectContext.cpp:202); `faerie fire (feral)` (strategy/druid/DruidAiObjectContext.cpp:253); `tiger's fury` (strategy/druid/DruidAiObjectContext.cpp:207); `tiger's fury` (strategy/druid/DruidAiObjectContext.cpp:298); `claw` (strategy/druid/DruidAiObjectContext.cpp:229); `claw` (strategy/druid/DruidAiObjectContext.cpp:281)

## What could not be expressed with existing names

- **No AND conditions.** `AndTrigger` and `OrTrigger` exist (`GenericTriggers.h:528-540`) but are not registered in any `creators[...]` map. Only `val::<bool value>` is registered (TriggerContext.h:245). So these are not possible:
  - Eviscerate below 20% target HP with any CP.
  - Life Tap only above 70% HP and below 65% mana. The class `life tap` trigger is fixed at mana ≤ 15% and HP ≥ 50%.
  - Heroic Strike only when Overpower or Execute is not pending.
- **Nothing can block a lower class action.** A custom line can only add actions. The class rotation still runs whenever our actions are impossible. Known conflicts:
  - **Warrior stance ping-pong at 30+.** The Arms and Fury buff strategies push `berserker stance` (10 and 30), while `charge` and `overpower` require `battle stance` (`WarriorStrategy.cpp:42-46`). A leveling warrior at 30+ will stance-dance. Fix it in the class strategy set (for example, drop `buff` for Arms while leveling); a custom line cannot fix it.
  - **Rogue Rupture** fires at 4 CP at relevance 20. Our Eviscerate at 4 CP (24) wins only because it is higher. Rupture still fires when Eviscerate is impossible.
  - **Druid cat vs. bear.** The band 20/40 lines assume the DPS-feral (cat) strategy. If the bear "tank" strategy is also on, its `bear form` trigger at relevance 39 will fight `cat form`.
- **"Pet attacks first, wait for aggro" (hunter, warlock).** No action exists for "send pet and wait N seconds". The pet engages through the pet AI and the pull strategy.
- **"Step back after Frost Nova."** This needs no new line. `RangedCombatStrategy` already pushes `flee` at ACTION_MOVE when `enemy too close for spell`, and that trigger deliberately stays false until the mob is rooted (RangeTriggers.h:28-31). The Frost Nova lines are at 35 so they come before the flee at 30.
- **Hunter melee mode.** `raptor strike` is only useful while auto-attacking in melee (`HunterActions.h:203`). The class `switch to melee` trigger handles the weapon swap. Vanilla Disengage is a threat drop, not a leap, so it is not used.
- **Out-of-combat parts** (buff armor and auras, conjure, Seal before the pull, Rockbiter before the pull) are not covered, because these strategies are enabled with `co` only. The same lines could also be added with `nc +custom::...`, but most combat lines are meaningless out of combat.
- **Seal of the Crusader → Judgement → Seal of Righteousness/Command twisting** is not expressible: there is no "target has Judgement of the Crusader" trigger usable for this. `judgement` is a generic debuff check on an aura named "judgement".
- **Mage AoE grinding at 40+** (Cone of Cold, Frost Nova, Blizzard pack pulls) is left to the class `aoe` strategy. A custom line has no way to make that kind of multi-mob pull safe.
- **Warlock Dark Pact** is already in the Affliction class strategy. Pet management (Voidwalker 10-19, Succubus 20+) is out of combat, so it is not covered.

## Names I was unsure about (all resolve, but behaviour caveats)

- `target of attacker` (priest shield): true when any attacker targets me. PW:Shield is a plain buff action with no Weakened Soul check, so while Weakened Soul is up it simply fails and falls through.
- `exorcism` (paladin) uses a cooldown-only trigger. The spell itself only works on undead and demons, so on other mobs it fails harmlessly.
- `demoralizing shout` and `thunder clap` (on `multiple attackers`): the actions may recast while the debuff is already up if the action class has no aura check. They cost rage but cannot break anything.
- `maul` in this tree requires ≥ 45 rage (`DruidActions.h:517`), so its line uses `medium rage available` (≥ 40).
- `faerie fire (feral)`, `sweeping strikes`, `blade flurry`, `adrenaline rush`, `stormstrike`, `ice barrier`, `siphon life`, `mind flay` and `vampiric embrace` are talents. They are no-ops if the build does not have them.
- `aspect of the hawk>aspect of the hawk!26,aspect of the monkey!25`: Monkey is cast only while Hawk is untrained (before 10). After that, Hawk wins and the trigger goes quiet once Hawk is up. It also replaces Aspect of the Cheetah in combat, which is intended.

## Sources

Priority logic is general Classic leveling knowledge, cross-checked against:
- Mage: https://www.warcrafttavern.com/guides/mage-leveling-guide/ (fetched: Frostbolt spam after Frostbite, Frost Nova then 1-2 casts then wand, Fire Blast, wand finish, Ice Barrier at 40+)
- Warlock: https://www.warcrafttavern.com/guides/wow-classic-warlock-leveling-guide/ (fetched: CoA/Corruption/Immolate then wand, Drain Soul finish 10-19, Siphon Life 30+, Drain Life filler from ~38)
- Warrior: https://www.warcrafttavern.com/wow-classic/guides/warrior-leveling-guide/ , https://icy-veins.com/wow-classic/fury-warrior-leveling-guide-1-60
- Hunter: https://www.wowhead.com/classic/tw/guides/hunter-dps-rotation-abilities-classic-wow
- Priest: https://warcrafttavern.com/wow-classic/guides/priest-leveling-guide
- Warlock talents: https://icy-veins.com/wow-classic/affliction-warlock-leveling-talent-build-from-1-to-60

Only the mage and warlock guides were fetched and read. The other URLs come from search results and were used only as pointers. The rogue, shaman, paladin and druid priorities come from general Vanilla knowledge, not a fetched guide.

wowsims: no rotation or APL files were present locally (`/home/claude/dl/sod` contains only `proto/apl.proto`), so nothing from wowsims was used and no credit is needed.
