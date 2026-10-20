-- Open Vanilla Classic+: every class starts with every weapon skill its class can ever learn,
-- already trained, on every race (every combination in playercreateinfo; run after classicplus_races.sql).
-- Racial weapon bonuses (Human sword/mace, Orc axe, Dwarf gun, Troll bow) stay race-only:
-- only the class's own weapon list is granted. Idempotent: re-running changes nothing.
-- The client agrees without a DBC change: SkillRaceClassInfo already allows each of these
-- skills to every race of the class (trainers teach them to every race).

-- Warrior
INSERT IGNORE INTO playercreateinfo_spell (race,class,Spell,Note)
  SELECT p.race, p.class, w.spell, w.note FROM playercreateinfo p
  JOIN (SELECT 0 AS spell, '' AS note UNION ALL VALUES (196,'One-Handed Axes'),(197,'Two-Handed Axes'),(198,'One-Handed Maces'),(199,'Two-Handed Maces'),(200,'Polearms'),(201,'One-Handed Swords'),(202,'Two-Handed Swords'),(227,'Staves'),(1180,'Daggers'),(15590,'Fist Weapons'),(264,'Bows'),(266,'Guns'),(5011,'Crossbows'),(2567,'Thrown'),(2480,'Shoot Bow'),(7918,'Shoot Gun'),(7919,'Shoot Crossbow'),(2764,'Throw')) w ON w.spell <> 0
  WHERE p.class = 1;
INSERT IGNORE INTO playercreateinfo_skills (raceMask,classMask,skill,step,note) VALUES (0,1,43,0,'Weapon: Swords (Warrior, Open Vanilla)'),(0,1,44,0,'Weapon: Axes (Warrior, Open Vanilla)'),(0,1,45,0,'Weapon: Bows (Warrior, Open Vanilla)'),(0,1,46,0,'Weapon: Guns (Warrior, Open Vanilla)'),(0,1,54,0,'Weapon: Maces (Warrior, Open Vanilla)'),(0,1,55,0,'Weapon: Two-Handed Swords (Warrior, Open Vanilla)'),(0,1,136,0,'Weapon: Staves (Warrior, Open Vanilla)'),(0,1,160,0,'Weapon: Two-Handed Maces (Warrior, Open Vanilla)'),(0,1,172,0,'Weapon: Two-Handed Axes (Warrior, Open Vanilla)'),(0,1,173,0,'Weapon: Daggers (Warrior, Open Vanilla)'),(0,1,176,0,'Weapon: Thrown (Warrior, Open Vanilla)'),(0,1,226,0,'Weapon: Crossbows (Warrior, Open Vanilla)'),(0,1,229,0,'Weapon: Polearms (Warrior, Open Vanilla)'),(0,1,473,0,'Weapon: Fist Weapons (Warrior, Open Vanilla)');

-- Paladin
INSERT IGNORE INTO playercreateinfo_spell (race,class,Spell,Note)
  SELECT p.race, p.class, w.spell, w.note FROM playercreateinfo p
  JOIN (SELECT 0 AS spell, '' AS note UNION ALL VALUES (196,'One-Handed Axes'),(197,'Two-Handed Axes'),(198,'One-Handed Maces'),(199,'Two-Handed Maces'),(200,'Polearms'),(201,'One-Handed Swords'),(202,'Two-Handed Swords')) w ON w.spell <> 0
  WHERE p.class = 2;
INSERT IGNORE INTO playercreateinfo_skills (raceMask,classMask,skill,step,note) VALUES (0,2,43,0,'Weapon: Swords (Paladin, Open Vanilla)'),(0,2,44,0,'Weapon: Axes (Paladin, Open Vanilla)'),(0,2,54,0,'Weapon: Maces (Paladin, Open Vanilla)'),(0,2,55,0,'Weapon: Two-Handed Swords (Paladin, Open Vanilla)'),(0,2,160,0,'Weapon: Two-Handed Maces (Paladin, Open Vanilla)'),(0,2,172,0,'Weapon: Two-Handed Axes (Paladin, Open Vanilla)'),(0,2,229,0,'Weapon: Polearms (Paladin, Open Vanilla)');

-- Hunter
INSERT IGNORE INTO playercreateinfo_spell (race,class,Spell,Note)
  SELECT p.race, p.class, w.spell, w.note FROM playercreateinfo p
  JOIN (SELECT 0 AS spell, '' AS note UNION ALL VALUES (196,'One-Handed Axes'),(197,'Two-Handed Axes'),(200,'Polearms'),(201,'One-Handed Swords'),(202,'Two-Handed Swords'),(227,'Staves'),(1180,'Daggers'),(15590,'Fist Weapons'),(264,'Bows'),(266,'Guns'),(5011,'Crossbows'),(2567,'Thrown'),(2764,'Throw')) w ON w.spell <> 0
  WHERE p.class = 3;
INSERT IGNORE INTO playercreateinfo_skills (raceMask,classMask,skill,step,note) VALUES (0,4,43,0,'Weapon: Swords (Hunter, Open Vanilla)'),(0,4,44,0,'Weapon: Axes (Hunter, Open Vanilla)'),(0,4,45,0,'Weapon: Bows (Hunter, Open Vanilla)'),(0,4,46,0,'Weapon: Guns (Hunter, Open Vanilla)'),(0,4,55,0,'Weapon: Two-Handed Swords (Hunter, Open Vanilla)'),(0,4,136,0,'Weapon: Staves (Hunter, Open Vanilla)'),(0,4,172,0,'Weapon: Two-Handed Axes (Hunter, Open Vanilla)'),(0,4,173,0,'Weapon: Daggers (Hunter, Open Vanilla)'),(0,4,176,0,'Weapon: Thrown (Hunter, Open Vanilla)'),(0,4,226,0,'Weapon: Crossbows (Hunter, Open Vanilla)'),(0,4,229,0,'Weapon: Polearms (Hunter, Open Vanilla)'),(0,4,473,0,'Weapon: Fist Weapons (Hunter, Open Vanilla)');

-- Rogue
INSERT IGNORE INTO playercreateinfo_spell (race,class,Spell,Note)
  SELECT p.race, p.class, w.spell, w.note FROM playercreateinfo p
  JOIN (SELECT 0 AS spell, '' AS note UNION ALL VALUES (198,'One-Handed Maces'),(201,'One-Handed Swords'),(1180,'Daggers'),(15590,'Fist Weapons'),(264,'Bows'),(266,'Guns'),(5011,'Crossbows'),(2567,'Thrown'),(2480,'Shoot Bow'),(7918,'Shoot Gun'),(7919,'Shoot Crossbow'),(2764,'Throw')) w ON w.spell <> 0
  WHERE p.class = 4;
INSERT IGNORE INTO playercreateinfo_skills (raceMask,classMask,skill,step,note) VALUES (0,8,43,0,'Weapon: Swords (Rogue, Open Vanilla)'),(0,8,45,0,'Weapon: Bows (Rogue, Open Vanilla)'),(0,8,46,0,'Weapon: Guns (Rogue, Open Vanilla)'),(0,8,54,0,'Weapon: Maces (Rogue, Open Vanilla)'),(0,8,173,0,'Weapon: Daggers (Rogue, Open Vanilla)'),(0,8,176,0,'Weapon: Thrown (Rogue, Open Vanilla)'),(0,8,226,0,'Weapon: Crossbows (Rogue, Open Vanilla)'),(0,8,473,0,'Weapon: Fist Weapons (Rogue, Open Vanilla)');

-- Priest
INSERT IGNORE INTO playercreateinfo_spell (race,class,Spell,Note)
  SELECT p.race, p.class, w.spell, w.note FROM playercreateinfo p
  JOIN (SELECT 0 AS spell, '' AS note UNION ALL VALUES (198,'One-Handed Maces'),(227,'Staves'),(1180,'Daggers'),(5009,'Wands'),(5019,'Shoot')) w ON w.spell <> 0
  WHERE p.class = 5;
INSERT IGNORE INTO playercreateinfo_skills (raceMask,classMask,skill,step,note) VALUES (0,16,54,0,'Weapon: Maces (Priest, Open Vanilla)'),(0,16,136,0,'Weapon: Staves (Priest, Open Vanilla)'),(0,16,173,0,'Weapon: Daggers (Priest, Open Vanilla)'),(0,16,228,0,'Weapon: Wands (Priest, Open Vanilla)');

-- Shaman
INSERT IGNORE INTO playercreateinfo_spell (race,class,Spell,Note)
  SELECT p.race, p.class, w.spell, w.note FROM playercreateinfo p
  JOIN (SELECT 0 AS spell, '' AS note UNION ALL VALUES (196,'One-Handed Axes'),(197,'Two-Handed Axes'),(198,'One-Handed Maces'),(199,'Two-Handed Maces'),(227,'Staves'),(1180,'Daggers'),(15590,'Fist Weapons')) w ON w.spell <> 0
  WHERE p.class = 7;
INSERT IGNORE INTO playercreateinfo_skills (raceMask,classMask,skill,step,note) VALUES (0,64,44,0,'Weapon: Axes (Shaman, Open Vanilla)'),(0,64,54,0,'Weapon: Maces (Shaman, Open Vanilla)'),(0,64,136,0,'Weapon: Staves (Shaman, Open Vanilla)'),(0,64,160,0,'Weapon: Two-Handed Maces (Shaman, Open Vanilla)'),(0,64,172,0,'Weapon: Two-Handed Axes (Shaman, Open Vanilla)'),(0,64,173,0,'Weapon: Daggers (Shaman, Open Vanilla)'),(0,64,473,0,'Weapon: Fist Weapons (Shaman, Open Vanilla)');

-- Mage
INSERT IGNORE INTO playercreateinfo_spell (race,class,Spell,Note)
  SELECT p.race, p.class, w.spell, w.note FROM playercreateinfo p
  JOIN (SELECT 0 AS spell, '' AS note UNION ALL VALUES (201,'One-Handed Swords'),(227,'Staves'),(1180,'Daggers'),(5009,'Wands'),(5019,'Shoot')) w ON w.spell <> 0
  WHERE p.class = 8;
INSERT IGNORE INTO playercreateinfo_skills (raceMask,classMask,skill,step,note) VALUES (0,128,43,0,'Weapon: Swords (Mage, Open Vanilla)'),(0,128,136,0,'Weapon: Staves (Mage, Open Vanilla)'),(0,128,173,0,'Weapon: Daggers (Mage, Open Vanilla)'),(0,128,228,0,'Weapon: Wands (Mage, Open Vanilla)');

-- Warlock
INSERT IGNORE INTO playercreateinfo_spell (race,class,Spell,Note)
  SELECT p.race, p.class, w.spell, w.note FROM playercreateinfo p
  JOIN (SELECT 0 AS spell, '' AS note UNION ALL VALUES (201,'One-Handed Swords'),(227,'Staves'),(1180,'Daggers'),(5009,'Wands'),(5019,'Shoot')) w ON w.spell <> 0
  WHERE p.class = 9;
INSERT IGNORE INTO playercreateinfo_skills (raceMask,classMask,skill,step,note) VALUES (0,256,43,0,'Weapon: Swords (Warlock, Open Vanilla)'),(0,256,136,0,'Weapon: Staves (Warlock, Open Vanilla)'),(0,256,173,0,'Weapon: Daggers (Warlock, Open Vanilla)'),(0,256,228,0,'Weapon: Wands (Warlock, Open Vanilla)');

-- Druid
INSERT IGNORE INTO playercreateinfo_spell (race,class,Spell,Note)
  SELECT p.race, p.class, w.spell, w.note FROM playercreateinfo p
  JOIN (SELECT 0 AS spell, '' AS note UNION ALL VALUES (198,'One-Handed Maces'),(199,'Two-Handed Maces'),(227,'Staves'),(1180,'Daggers'),(15590,'Fist Weapons')) w ON w.spell <> 0
  WHERE p.class = 11;
INSERT IGNORE INTO playercreateinfo_skills (raceMask,classMask,skill,step,note) VALUES (0,1024,54,0,'Weapon: Maces (Druid, Open Vanilla)'),(0,1024,136,0,'Weapon: Staves (Druid, Open Vanilla)'),(0,1024,160,0,'Weapon: Two-Handed Maces (Druid, Open Vanilla)'),(0,1024,173,0,'Weapon: Daggers (Druid, Open Vanilla)'),(0,1024,473,0,'Weapon: Fist Weapons (Druid, Open Vanilla)');
