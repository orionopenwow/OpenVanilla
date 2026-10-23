-- Open Vanilla Boss Fights: the world database's Boss Fights changes (hetzner/bossfights_up.sh, after
-- warfront_world.sql and duels_world.sql on the shared Modes server). Re-runnable.
-- With realm/mangos/0050-openvanilla-bossfights.patch.
--
-- The lobby is Duels' hangout, Gurubashi Arena in Stranglethorn (map 0, the open world's arena: pit, stands,
-- ramps), with Duels' own arrival point and fence (OpenVanilla.Duels.Hub, .Hub.Fence). Raiders and duelers
-- hang out together; each mode keeps its own characters there. Nothing here moves the raids themselves: every run is
-- its own copy of the stock raid, scaled by the world server (tiers, the run's size).

-- Where a new character starts: duels_world.sql already puts every new character in the hangout, Gurubashi
-- Arena (map 0, zone 33). Boss Fights shares that hangout, so nothing changes here.

-- Short John Mithril (the arena's hourly chest event) talks to both factions; his chest is Warfront's anyway.
UPDATE `creature_template` SET `Faction` = 35 WHERE `Entry` = 14508;

-- Two quartermasters in the stands for what a raid uses up (both factions, stock prices):
-- reagents, ammunition and bandages. The armory itself is Warfront's window (kits, gear picker).
DROP TEMPORARY TABLE IF EXISTS `bf_tpl`;
CREATE TEMPORARY TABLE `bf_tpl` AS SELECT * FROM `creature_template` WHERE `Entry` = 14508;
UPDATE `bf_tpl` SET `Entry` = 900200, `Name` = 'Raid Quartermaster', `SubName` = 'Boss Fights', `MinLevel` = 60, `MaxLevel` = 60,
  `Faction` = 35, `NpcFlags` = 128, `AIName` = '', `ScriptName` = '', `GossipMenuId` = 0;
DELETE FROM `creature_template` WHERE `Entry` = 900200;
INSERT INTO `creature_template` SELECT * FROM `bf_tpl`;
DROP TEMPORARY TABLE `bf_tpl`;
DELETE FROM `npc_vendor` WHERE `entry` = 900200;
INSERT INTO `npc_vendor` (`entry`, `item`, `maxcount`, `incrtime`) VALUES
  (900200, 17020, 0, 0),   -- Arcane Powder
  (900200, 17028, 0, 0),   -- Holy Candle
  (900200, 17029, 0, 0),   -- Sacred Candle
  (900200, 17031, 0, 0),   -- Rune of Teleportation
  (900200, 17032, 0, 0),   -- Rune of Portals
  (900200, 17033, 0, 0),   -- Symbol of Divinity
  (900200, 17026, 0, 0),   -- Wild Thornroot
  (900200, 17030, 0, 0),   -- Ankh
  (900200, 5565, 0, 0),    -- Infernal Stone
  (900200, 16583, 0, 0),   -- Demonic Figurine
  (900200, 21177, 0, 0),   -- Symbol of Kings
  (900200, 11285, 0, 0),   -- Jagged Arrow
  (900200, 11284, 0, 0),   -- Accurate Slugs
  (900200, 14530, 0, 0);   -- Heavy Runecloth Bandage
-- guids above the stock world's (its highest is 9100308; 9002xx are stock Gnomeregan spawns)
DELETE FROM `creature` WHERE `guid` IN (9200201, 9200202);
INSERT INTO `creature` (`guid`, `id`, `map`, `spawnMask`, `position_x`, `position_y`, `position_z`, `orientation`, `spawntimesecsmin`, `spawntimesecsmax`, `spawndist`, `MovementType`)
  VALUES (9200201, 900200, 0, 1, -13219.0, 236.0, 33.2, 1.1, 30, 30, 0, 0),
         (9200202, 900200, 0, 1, -13232.0, 229.0, 33.2, 1.1, 30, 30, 0, 0);

-- What the world server gives on entering a run (OpenVanilla.BossFights.Consumables, .Consumables.mc) sells for
-- nothing: no gold from free items.
UPDATE `item_template` SET `SellPrice` = 0 WHERE `entry` IN (13446, 13444, 13510, 13511, 13512, 20452, 14530, 22754);
