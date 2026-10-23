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
