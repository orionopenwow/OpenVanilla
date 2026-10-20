-- Open Vanilla Classic+: leveling pace, world database side. Run against classicmangos; safe to run
-- twice. Every value changed here is saved first in openvanilla_pace_backup, and
-- classicplus_pace_rollback.sql puts each one back. The world server side (faster flights, flight
-- paths by level, campfire rest, Veteran Mentor, exploration XP, starter items on abandon, the
-- dummies' script) is realm/mangos/0013-openvanilla-pace.patch; rates are in openvanilla_gameplay_conf.sh.
--
--   1. Quest drops: every quest-only creature drop below 100% becomes 100% (1,918 rows, classic-db 4d230bb).
--   2. Shared quest drops: those items become party loot (ITEM_FLAG_MULTI_DROP), so everyone in the
--      group who needs one gets their own copy instead of one person looting it.
--   3. Hearthstone: 15-minute cooldown instead of 60 (server side; see the README for the client).
--   4. Paladin Blessings: the single-target Blessings last 15 minutes (the Greater Blessings' duration).
--   5. Escorts: a scripted escort quest-giver respawns 60 s after a failed escort, not up to 24 h.
--   6. Dungeon dispatch boards: a board just inside each dungeon's entrance gives and takes every
--      quest sorted under that dungeon (19 dungeons; prerequisites and races still apply).
--   7. Training dummies: level 60, level 50 and "your level" dummies beside each capital's weapon master.
-- IDs: boards 990701-990719 (spawns 9100701-9100760), dummies 990801-990803 (spawns 9100801-9100818).

CREATE TABLE IF NOT EXISTS openvanilla_pace_backup (
  what  VARCHAR(32)  NOT NULL,
  k1    INT UNSIGNED NOT NULL,
  k2    INT UNSIGNED NOT NULL DEFAULT 0,
  val   DOUBLE       NOT NULL,
  val2  DOUBLE       NOT NULL DEFAULT 0,
  PRIMARY KEY (what, k1, k2)
);

-- 1. quest drops at 100% (a negative chance means "only while on the quest")
INSERT IGNORE INTO openvanilla_pace_backup (what, k1, k2, val)
  SELECT 'quest_drop', entry, item, ChanceOrQuestChance FROM creature_loot_template
  WHERE ChanceOrQuestChance < 0 AND ChanceOrQuestChance > -100;
UPDATE creature_loot_template SET ChanceOrQuestChance = -100
  WHERE ChanceOrQuestChance < 0 AND ChanceOrQuestChance > -100;

-- 2. shared quest drops (0x800: each eligible group member gets one)
DROP TEMPORARY TABLE IF EXISTS ov_quest_item;
CREATE TEMPORARY TABLE ov_quest_item (item INT UNSIGNED PRIMARY KEY)
  SELECT DISTINCT item FROM creature_loot_template WHERE ChanceOrQuestChance < 0;
INSERT IGNORE INTO openvanilla_pace_backup (what, k1, val)
  SELECT 'party_loot', i.entry, i.Flags FROM item_template i JOIN ov_quest_item q ON q.item = i.entry
  WHERE (i.Flags & 2048) = 0;
UPDATE item_template i JOIN ov_quest_item q ON q.item = i.entry SET i.Flags = i.Flags | 2048
  WHERE (i.Flags & 2048) = 0;
DROP TEMPORARY TABLE ov_quest_item;

-- 3. Hearthstone (spell 8690): 15 minutes
INSERT IGNORE INTO openvanilla_pace_backup (what, k1, val)
  SELECT 'hearthstone', Id, CategoryRecoveryTime FROM spell_template WHERE Id = 8690;
UPDATE spell_template SET CategoryRecoveryTime = 900000 WHERE Id = 8690;

-- 4. single-target Blessings: duration index 5 (5 min) -> 347 (15 min, as the Greater Blessings)
INSERT IGNORE INTO openvanilla_pace_backup (what, k1, val)
  SELECT 'blessing', Id, DurationIndex FROM spell_template
  WHERE SpellFamilyName = 10 AND DurationIndex = 5
    AND SpellName IN ('Blessing of Might', 'Blessing of Wisdom', 'Blessing of Kings', 'Blessing of Salvation',
                      'Blessing of Light', 'Blessing of Sanctuary');
UPDATE spell_template SET DurationIndex = 347
  WHERE Id IN (SELECT k1 FROM openvanilla_pace_backup WHERE what = 'blessing');

-- 5. escort quest-givers back in 60 s
INSERT IGNORE INTO openvanilla_pace_backup (what, k1, val, val2)
  SELECT DISTINCT 'escort_respawn', c.guid, c.spawntimesecsmin, c.spawntimesecsmax
  FROM creature c
  JOIN creature_template t ON t.Entry = c.id AND t.ScriptName <> ''
  JOIN creature_questrelation r ON r.id = c.id
  JOIN quest_template q ON q.entry = r.quest AND (q.SpecialFlags & 2)
  WHERE c.spawntimesecsmin > 60;
UPDATE creature c JOIN openvanilla_pace_backup b ON b.what = 'escort_respawn' AND b.k1 = c.guid
  SET c.spawntimesecsmin = 60, c.spawntimesecsmax = 60;

-- 6. dungeon dispatch boards
DROP TEMPORARY TABLE IF EXISTS ov_board;
CREATE TEMPORARY TABLE ov_board (entry INT UNSIGNED PRIMARY KEY, zone INT UNSIGNED, map INT UNSIGNED, name VARCHAR(100));
INSERT INTO ov_board VALUES
  (990701, 2437, 389, 'Ragefire Chasm Dispatch Board'),
  (990702,  718,  43, 'Wailing Caverns Dispatch Board'),
  (990703, 1581,  36, 'Deadmines Dispatch Board'),
  (990704,  209,  33, 'Shadowfang Keep Dispatch Board'),
  (990705,  719,  48, 'Blackfathom Deeps Dispatch Board'),
  (990706,  717,  34, 'Stockade Dispatch Board'),
  (990707,  133,  90, 'Gnomeregan Dispatch Board'),
  (990708, 1717,  47, 'Razorfen Kraul Dispatch Board'),
  (990709,  796, 189, 'Scarlet Monastery Dispatch Board'),
  (990710,  722, 129, 'Razorfen Downs Dispatch Board'),
  (990711, 1517,  70, 'Uldaman Dispatch Board'),
  (990712,  978, 209, 'Zul''Farrak Dispatch Board'),
  (990713, 2100, 349, 'Maraudon Dispatch Board'),
  (990714, 1417, 109, 'Sunken Temple Dispatch Board'),
  (990715, 1584, 230, 'Blackrock Depths Dispatch Board'),
  (990716, 1583, 229, 'Blackrock Spire Dispatch Board'),
  (990717, 2557, 429, 'Dire Maul Dispatch Board'),
  (990718, 2057, 289, 'Scholomance Dispatch Board'),
  (990719, 2017, 329, 'Stratholme Dispatch Board');

DELETE FROM gameobject_questrelation WHERE id BETWEEN 990701 AND 990719;
DELETE FROM gameobject_involvedrelation WHERE id BETWEEN 990701 AND 990719;
DELETE FROM gameobject WHERE guid BETWEEN 9100701 AND 9100760;
DELETE FROM gameobject_template WHERE entry BETWEEN 990701 AND 990719;

-- a quest board like the Wanted posters (type 2, display 17), usable by everyone (faction 0)
-- One copy of the poster per board, changed in place and inserted whole (SELECT *), so this works with
-- whatever columns this database's gameobject_template has. ov_n numbers the copies 1-19; the boards
-- are 990701-990719 in a row, so copy n becomes board 990700 + n.
DROP TEMPORARY TABLE IF EXISTS ov_tmp_go;
CREATE TEMPORARY TABLE ov_tmp_go SELECT g.* FROM ov_board b JOIN gameobject_template g ON g.entry = 68;
ALTER TABLE ov_tmp_go ADD COLUMN ov_n INT NOT NULL AUTO_INCREMENT PRIMARY KEY FIRST;
UPDATE ov_tmp_go t JOIN ov_board b ON b.entry = 990700 + t.ov_n
  SET t.entry = b.entry, t.name = b.name, t.faction = 0, t.flags = 0, t.size = 1.6, t.data0 = 0, t.data1 = 0;
ALTER TABLE ov_tmp_go DROP COLUMN ov_n;
INSERT INTO gameobject_template SELECT * FROM ov_tmp_go;
DROP TEMPORARY TABLE ov_tmp_go;

-- one board 3 yards inside every entrance (a dungeon with several doors gets one at each)
INSERT INTO gameobject (guid, id, map, spawnMask, position_x, position_y, position_z, orientation,
                        rotation0, rotation1, rotation2, rotation3, spawntimesecsmin, spawntimesecsmax)
  SELECT 9100700 + ROW_NUMBER() OVER (ORDER BY b.entry, a.id), b.entry, b.map, 1,
         a.target_position_x + 3 * COS(a.target_orientation), a.target_position_y + 3 * SIN(a.target_orientation),
         a.target_position_z, a.target_orientation + PI(),
         0, 0, SIN((a.target_orientation + PI()) / 2), COS((a.target_orientation + PI()) / 2), 0, 0
  FROM ov_board b JOIN areatrigger_teleport a ON a.target_map = b.map;

-- every quest sorted under the dungeon that someone in the world gives today (not ones only an item starts)
INSERT IGNORE INTO gameobject_questrelation (id, quest)
  SELECT b.entry, q.entry FROM ov_board b JOIN quest_template q ON q.ZoneOrSort = b.zone
  WHERE (EXISTS (SELECT 1 FROM creature_questrelation r WHERE r.quest = q.entry)
      OR EXISTS (SELECT 1 FROM gameobject_questrelation r WHERE r.quest = q.entry AND r.id NOT BETWEEN 990701 AND 990719))
    AND NOT EXISTS (SELECT 1 FROM item_template i WHERE i.startquest = q.entry);
INSERT IGNORE INTO gameobject_involvedrelation (id, quest)
  SELECT b.entry, q.entry FROM ov_board b JOIN quest_template q ON q.ZoneOrSort = b.zone
  WHERE EXISTS (SELECT 1 FROM creature_involvedrelation r WHERE r.quest = q.entry)
     OR EXISTS (SELECT 1 FROM gameobject_involvedrelation r WHERE r.quest = q.entry AND r.id NOT BETWEEN 990701 AND 990719);
DROP TEMPORARY TABLE ov_board;

-- 7. training dummies (script: npc_openvanilla_training_dummy; health 2000x a mob of their level,
--    the armor of one; rooted, never attack, neutral so guards stay out of it)
DELETE FROM creature WHERE guid BETWEEN 9100801 AND 9100818;
DELETE FROM creature_template WHERE Entry BETWEEN 990801 AND 990803;
DROP TEMPORARY TABLE IF EXISTS ov_tmp_dummy;
CREATE TEMPORARY TABLE ov_tmp_dummy SELECT * FROM creature_template WHERE Entry = 2673;
UPDATE ov_tmp_dummy SET Entry = 990801, Name = 'Training Dummy', SubName = 'Level 60', MinLevel = 60, MaxLevel = 60;
INSERT INTO creature_template SELECT * FROM ov_tmp_dummy;
UPDATE ov_tmp_dummy SET Entry = 990802, SubName = 'Level 50', MinLevel = 50, MaxLevel = 50;
INSERT INTO creature_template SELECT * FROM ov_tmp_dummy;
UPDATE ov_tmp_dummy SET Entry = 990803, SubName = 'Your level', MinLevel = 1, MaxLevel = 1;
INSERT INTO creature_template SELECT * FROM ov_tmp_dummy;
DROP TEMPORARY TABLE ov_tmp_dummy;
UPDATE creature_template SET Faction = 7, AIName = '', ScriptName = 'npc_openvanilla_training_dummy',
  HealthMultiplier = 2000, ArmorMultiplier = 1, Rank = 0, ExperienceMultiplier = 0, CorpseDecay = 0,
  MinLootGold = 0, MaxLootGold = 0, LootId = 0, PickpocketLootId = 0, SkinningLootId = 0
  WHERE Entry BETWEEN 990801 AND 990803;

-- three in a row, 5 yards in front of each capital's weapon master (60 | 50 | your level)
DROP TEMPORARY TABLE IF EXISTS ov_dummy_spot;
CREATE TEMPORARY TABLE ov_dummy_spot (n INT, map INT, x FLOAT, y FLOAT, z FLOAT, o FLOAT);
INSERT INTO ov_dummy_spot
  SELECT 1, c.map, c.position_x, c.position_y, c.position_z, c.orientation FROM creature c WHERE c.guid = 79698   -- Woo Ping, Stormwind
  UNION ALL SELECT 2, c.map, c.position_x, c.position_y, c.position_z, c.orientation FROM creature c WHERE c.guid = 90      -- Buliwyf Stonehand, Ironforge
  UNION ALL SELECT 3, c.map, c.position_x, c.position_y, c.position_z, c.orientation FROM creature c WHERE c.guid = 46349   -- Ilyenia Moonfire, Darnassus
  UNION ALL SELECT 4, c.map, c.position_x, c.position_y, c.position_z, c.orientation FROM creature c WHERE c.guid = 7446    -- Hanashi, Orgrimmar
  UNION ALL SELECT 5, c.map, c.position_x, c.position_y, c.position_z, c.orientation FROM creature c WHERE c.guid = 24775   -- Ansekhwa, Thunder Bluff
  UNION ALL SELECT 6, c.map, c.position_x, c.position_y, c.position_z, c.orientation FROM creature c WHERE c.guid = 38129;  -- Archibald, Undercity
INSERT INTO creature (guid, id, map, spawnMask, position_x, position_y, position_z, orientation,
                      spawntimesecsmin, spawntimesecsmax, spawndist, MovementType)
  SELECT 9100800 + (s.n - 1) * 3 + d.k, 990800 + d.k, s.map, 1,
         s.x + 5 * COS(s.o) + (d.k - 2) * 2.5 * COS(s.o + PI() / 2),
         s.y + 5 * SIN(s.o) + (d.k - 2) * 2.5 * SIN(s.o + PI() / 2),
         s.z, s.o + PI(), 30, 30, 0, 0
  FROM ov_dummy_spot s JOIN (SELECT 1 AS k UNION ALL SELECT 2 UNION ALL SELECT 3) d;
DROP TEMPORARY TABLE ov_dummy_spot;
