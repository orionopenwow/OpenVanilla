-- Open Vanilla Duels: the world database's Duels changes (hetzner/duels_up.sh, after warfront_world.sql).
-- Re-runnable. With realm/mangos/0024-openvanilla-duels-arena.patch.

-- Gurubashi Arena as map 900, a party instance (one copy per match). Its Map.dbc row comes from
-- tools/duels/arena_map.py, its terrain from map 0's files (duels_up.sh arena_links). Up to 40 in a copy
-- (two duelists and their spectators); no lockout reset; a ghost walks out at the arena.
DELETE FROM `instance_template` WHERE `map` = 900;
INSERT INTO `instance_template` (`map`, `parent`, `levelMin`, `levelMax`, `maxPlayers`, `reset_delay`, `ghostEntranceMap`, `ghostEntranceX`, `ghostEntranceY`, `ScriptName`, `mountAllowed`)
  VALUES (900, 0, 0, 0, 40, 0, 0, -13226.3, 232.03, '', 1);

-- Every new character starts in the hangout, Gurubashi Arena in Stranglethorn (zone 33), and is bound there.
UPDATE `playercreateinfo` SET `map` = 0, `zone` = 33, `position_x` = -13217.9, `position_y` = 276.76, `position_z` = 22.4, `orientation` = 0;

-- The inn's own people serve both factions (friendly to all, faction 35).
UPDATE `creature_template` SET `Faction` = 35 WHERE `Entry` IN (295, 465, 151, 3935, 1430, 6778, 917, 2329, 328, 377, 253);

-- Four practice dummies around the pit (east, west, north, south): level 60, never fights back, never
-- takes damage or dies (patch 0040: every hit shows its number and counts, the health bar never moves;
-- stop hitting for 6 s and it whispers your damage per second).
DROP TEMPORARY TABLE IF EXISTS `duels_tpl`;
CREATE TEMPORARY TABLE `duels_tpl` AS SELECT * FROM `creature_template` WHERE `Entry` = 2673;
UPDATE `duels_tpl` SET `Entry` = 900100, `Name` = 'Duel Dummy', `SubName` = 'Practice', `MinLevel` = 60, `MaxLevel` = 60,
  `Faction` = 7, `HealthMultiplier` = 1, `MinLevelHealth` = 300000, `MaxLevelHealth` = 300000, `Armor` = 3500,
  `MinMeleeDmg` = 0, `MaxMeleeDmg` = 0, `MeleeAttackPower` = 0,
  `RegenerateStats` = 1, `AIName` = '', `ScriptName` = 'npc_openvanilla_training_dummy', `LootId` = 0;
DELETE FROM `creature_template` WHERE `Entry` = 900100;
INSERT INTO `creature_template` SELECT * FROM `duels_tpl`;
DROP TEMPORARY TABLE `duels_tpl`;
DELETE FROM `creature` WHERE `guid` IN (900101, 900102, 900103, 900104);
INSERT INTO `creature` (`guid`, `id`, `map`, `spawnMask`, `position_x`, `position_y`, `position_z`, `orientation`, `spawntimesecsmin`, `spawntimesecsmax`, `spawndist`, `MovementType`)
  VALUES (900101, 900100, 0, 1, -13202.9, 251.8, 21.9, 1.57, 30, 30, 0, 0),
         (900102, 900100, 0, 1, -13202.9, 301.8, 21.9, 4.71, 30, 30, 0, 0),
         (900103, 900100, 0, 1, -13177.9, 276.8, 21.9, 3.14, 30, 30, 0, 0),
         (900104, 900100, 0, 1, -13227.9, 276.8, 21.9, 0.00, 30, 30, 0, 0);

-- The round's consumables (OpenVanilla.Duels.Consumables) are worth nothing at a vendor.
UPDATE `item_template` SET `SellPrice` = 0 WHERE `entry` IN (13446, 13444, 14530, 11951, 5634, 3387);

-- 0026: the practice bot (OpenVanilla.Duels.PracticeBot): a Gurubashi champion at level 60, a fair
-- melee fight for a geared duelist; no loot, no reputation.
DROP TEMPORARY TABLE IF EXISTS `duels_tpl`;
CREATE TEMPORARY TABLE `duels_tpl` AS SELECT * FROM `creature_template` WHERE `Entry` = 11356;
UPDATE `duels_tpl` SET `Entry` = 900110, `Name` = 'Gurubashi Champion', `SubName` = 'Practice bot', `MinLevel` = 60, `MaxLevel` = 60,
  `Faction` = 14, `Rank` = 0, `HealthMultiplier` = 1, `MinLevelHealth` = 16000, `MaxLevelHealth` = 16000, `Armor` = 3200,
  `MinMeleeDmg` = 380, `MaxMeleeDmg` = 560, `MeleeBaseAttackTime` = 2200, `DamageMultiplier` = 1,
  `UnitFlags` = 0, `LootId` = 0, `PickpocketLootId` = 0, `SkinningLootId` = 0, `MinLootGold` = 0, `MaxLootGold` = 0,
  `AIName` = '', `ScriptName` = '', `ExperienceMultiplier` = 0;
DELETE FROM `creature_template` WHERE `Entry` = 900110;
INSERT INTO `creature_template` SELECT * FROM `duels_tpl`;
DROP TEMPORARY TABLE `duels_tpl`;
DELETE FROM `creature_onkill_reputation` WHERE `creature_id` = 900110;

-- 0061: the dummy that hits back (east and west of the pit, between the others): fights whoever hits it
-- with bolts to interrupt, a heal to kick and a crowd control every 20 s; never dies (full again at 10%),
-- whispers your damage per second, the damage it did and the casts you stopped.
DROP TEMPORARY TABLE IF EXISTS `duels_tpl`;
CREATE TEMPORARY TABLE `duels_tpl` AS SELECT * FROM `creature_template` WHERE `Entry` = 2673;
UPDATE `duels_tpl` SET `Entry` = 900105, `Name` = 'Sparring Dummy', `SubName` = 'Hits back', `MinLevel` = 60, `MaxLevel` = 60,
  `Faction` = 7, `UnitClass` = 8, `HealthMultiplier` = 1, `MinLevelHealth` = 40000, `MaxLevelHealth` = 40000,
  `PowerMultiplier` = 1, `MinLevelMana` = 100000, `MaxLevelMana` = 100000, `Armor` = 3000,
  `MinMeleeDmg` = 150, `MaxMeleeDmg` = 250, `MeleeBaseAttackTime` = 2000, `DamageMultiplier` = 1,
  `RegenerateStats` = 1, `AIName` = '', `ScriptName` = 'npc_openvanilla_sparring_dummy', `LootId` = 0,
  `ExperienceMultiplier` = 0, `MinLootGold` = 0, `MaxLootGold` = 0;
DELETE FROM `creature_template` WHERE `Entry` = 900105;
INSERT INTO `creature_template` SELECT * FROM `duels_tpl`;
DROP TEMPORARY TABLE `duels_tpl`;
DELETE FROM `creature_onkill_reputation` WHERE `creature_id` = 900105;
DELETE FROM `creature` WHERE `guid` IN (900105, 900106);
INSERT INTO `creature` (`guid`, `id`, `map`, `spawnMask`, `position_x`, `position_y`, `position_z`, `orientation`, `spawntimesecsmin`, `spawntimesecsmax`, `spawndist`, `MovementType`)
  VALUES (900105, 900105, 0, 1, -13185.2, 259.1, 21.9, 2.36, 30, 30, 0, 0),
         (900106, 900105, 0, 1, -13220.6, 294.5, 21.9, 5.50, 30, 30, 0, 0);

-- 0061: the crowd in the stands (OpenVanilla.Duels.Pit.Crowd): four spectators that look like the people
-- of Booty Bay (models of the humanoids spawned there), friendly to all, untouchable. The pit summons
-- them when someone is in the hangout and they cheer the finishes.
DROP TEMPORARY TABLE IF EXISTS `duels_models`;
CREATE TEMPORARY TABLE `duels_models` AS
  SELECT DISTINCT t.`ModelId1` AS m FROM `creature_template` t JOIN `creature` c ON c.`id` = t.`Entry`
  WHERE c.`map` = 0 AND c.`position_x` BETWEEN -14520 AND -14180 AND c.`position_y` BETWEEN 300 AND 620
    AND t.`CreatureType` = 7 AND t.`ModelId1` > 0 AND t.`Rank` = 0
  ORDER BY t.`ModelId1` LIMIT 16;
SET @m1 = COALESCE((SELECT m FROM `duels_models` ORDER BY m LIMIT 0, 1), 7102);
SET @m2 = COALESCE((SELECT m FROM `duels_models` ORDER BY m LIMIT 1, 1), @m1);
SET @m3 = COALESCE((SELECT m FROM `duels_models` ORDER BY m LIMIT 2, 1), @m1);
SET @m4 = COALESCE((SELECT m FROM `duels_models` ORDER BY m LIMIT 3, 1), @m2);
SET @m5 = COALESCE((SELECT m FROM `duels_models` ORDER BY m LIMIT 4, 1), @m3);
SET @m6 = COALESCE((SELECT m FROM `duels_models` ORDER BY m LIMIT 5, 1), @m1);
SET @m7 = COALESCE((SELECT m FROM `duels_models` ORDER BY m LIMIT 6, 1), @m2);
SET @m8 = COALESCE((SELECT m FROM `duels_models` ORDER BY m LIMIT 7, 1), @m3);
DROP TEMPORARY TABLE `duels_models`;
DROP TEMPORARY TABLE IF EXISTS `duels_tpl`;
CREATE TEMPORARY TABLE `duels_tpl` AS SELECT * FROM `creature_template` WHERE `Entry` = 2673;
UPDATE `duels_tpl` SET `Entry` = 900120, `Name` = 'Arena Spectator', `SubName` = NULL, `MinLevel` = 30, `MaxLevel` = 50,
  `ModelId1` = @m1, `ModelId2` = @m5, `ModelId3` = 0, `ModelId4` = 0, `CreatureType` = 7,
  `Faction` = 35, `NpcFlags` = 0, `UnitFlags` = 770, `HealthMultiplier` = 1, `MinLevelHealth` = 2000, `MaxLevelHealth` = 2000,
  `MinMeleeDmg` = 0, `MaxMeleeDmg` = 0, `LootId` = 0, `AIName` = '', `ScriptName` = '', `MovementType` = 0,
  `ExperienceMultiplier` = 0, `MinLootGold` = 0, `MaxLootGold` = 0, `Civilian` = 1;
DELETE FROM `creature_template` WHERE `Entry` IN (900120, 900121, 900122, 900123);
INSERT INTO `creature_template` SELECT * FROM `duels_tpl`;
UPDATE `duels_tpl` SET `Entry` = 900121, `ModelId1` = @m2, `ModelId2` = @m6;
INSERT INTO `creature_template` SELECT * FROM `duels_tpl`;
UPDATE `duels_tpl` SET `Entry` = 900122, `ModelId1` = @m3, `ModelId2` = @m7;
INSERT INTO `creature_template` SELECT * FROM `duels_tpl`;
UPDATE `duels_tpl` SET `Entry` = 900123, `ModelId1` = @m4, `ModelId2` = @m8;
INSERT INTO `creature_template` SELECT * FROM `duels_tpl`;
DROP TEMPORARY TABLE `duels_tpl`;
