-- Open Vanilla Duels: the world database's Duels changes (hetzner/duels_up.sh, after warfront_world.sql).
-- Re-runnable. With realm/mangos/0024-openvanilla-duels-arena.patch.

-- Gurubashi Arena as map 900, a party instance (one copy per match). Its Map.dbc row comes from
-- tools/duels/arena_map.py, its terrain from map 0's files (duels_up.sh arena_links). Up to 40 in a copy
-- (two duelists and their spectators); no lockout reset; a ghost walks out at the arena.
DELETE FROM `instance_template` WHERE `map` = 900;
INSERT INTO `instance_template` (`map`, `parent`, `levelMin`, `levelMax`, `maxPlayers`, `reset_delay`, `ghostEntranceMap`, `ghostEntranceX`, `ghostEntranceY`, `ScriptName`, `mountAllowed`)
  VALUES (900, 0, 0, 0, 40, 0, 0, -13226.3, 232.03, '', 0);

-- Every new character starts in the hangout, the Lion's Pride Inn in Goldshire, and is bound there.
UPDATE `playercreateinfo` SET `map` = 0, `zone` = 12, `position_x` = -9467.1, `position_y` = 24.9, `position_z` = 56.7, `orientation` = 5.18;

-- The inn's own people serve both factions (friendly to all, faction 35).
UPDATE `creature_template` SET `Faction` = 35 WHERE `Entry` IN (295, 465, 151, 3935, 1430, 6778, 917, 2329, 328, 377, 253);

-- A practice dummy by the fire: level 60, a lot of health, never fights back, never dies for long.
DROP TEMPORARY TABLE IF EXISTS `duels_tpl`;
CREATE TEMPORARY TABLE `duels_tpl` AS SELECT * FROM `creature_template` WHERE `Entry` = 2673;
UPDATE `duels_tpl` SET `Entry` = 900100, `Name` = 'Duel Dummy', `SubName` = 'Practice', `MinLevel` = 60, `MaxLevel` = 60,
  `Faction` = 7, `HealthMultiplier` = 1, `MinLevelHealth` = 300000, `MaxLevelHealth` = 300000, `Armor` = 3500,
  `MinMeleeDmg` = 0, `MaxMeleeDmg` = 0, `MeleeAttackPower` = 0,
  `RegenerateStats` = 1, `AIName` = '', `ScriptName` = '', `LootId` = 0;
DELETE FROM `creature_template` WHERE `Entry` = 900100;
INSERT INTO `creature_template` SELECT * FROM `duels_tpl`;
DROP TEMPORARY TABLE `duels_tpl`;
DELETE FROM `creature` WHERE `guid` IN (900101, 900102);
INSERT INTO `creature` (`guid`, `id`, `map`, `spawnMask`, `position_x`, `position_y`, `position_z`, `orientation`, `spawntimesecsmin`, `spawntimesecsmax`, `spawndist`, `MovementType`)
  VALUES (900101, 900100, 0, 1, -9470.6, 22.5, 56.95, 0.3, 30, 30, 0, 0),
         (900102, 900100, 0, 1, -9470.9, 16.8, 56.95, 0.3, 30, 30, 0, 0);

-- The round's consumables (OpenVanilla.Duels.Consumables) are worth nothing at a vendor.
UPDATE `item_template` SET `SellPrice` = 0 WHERE `entry` IN (13446, 13444, 14530, 11951);
