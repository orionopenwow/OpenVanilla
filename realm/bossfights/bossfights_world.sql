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

-- The ready raider (realm/mangos/0052-openvanilla-bossfights-ready.patch): what a raider finds in its bags in the
-- hangout sells for nothing either: elixirs, food and water, reagents, poisons, ammunition, the bags.
UPDATE `item_template` SET `SellPrice` = 0 WHERE `entry` IN (13452, 9206, 13454, 8932, 8766, 17020, 17029, 21177, 17033,
  17026, 17038, 17030, 6265, 8928, 20844, 5140, 18042, 15997, 4500);

-- Onyxia's Lair without its trash (owner, 2026-10-23): Boss Fights is the boss. Only Onyxia herself stays: the
-- Onyxian Warders and the whelps in the tunnel and caves go (her phase 2 whelps are summoned by her script, so they
-- still come). The run starts in her room (mangos 0060, OpenVanilla.BossFights.StartAtBoss). bossfights_up.sh copies
-- the raids' spawns back from the live world on every update, then runs this file again, so it stays trash-free.
-- (0062) Onyxia's Lair Trigger (12758) stays too: it hatches the cave whelps of her phase 2 (Onyxian Whelps from the eggs,
-- GO 176510); without it phase 2 had only the whelps her own script calls.
DELETE FROM `creature` WHERE `map` = 249 AND `id` NOT IN (10184, 12758);

-- ── realm/mangos/0062: the run's rewards and the hangout's two new NPCs (realm/bossfights/README-run.md) ──
-- Everything here is cosmetic, soulbound and sells for nothing; nothing is ever sold for money.

-- Dragon Scales (a clear's currency), the Dragon Egg (a first clear of a tier; five hatch a whelp) and the whelp they
-- hatch: copies of stock items (their looks), soulbound, sell for nothing.
DROP TEMPORARY TABLE IF EXISTS `bf_item`;
CREATE TEMPORARY TABLE `bf_item` AS SELECT * FROM `item_template` WHERE `entry` IN (15416, 3685, 10822);
UPDATE `bf_item` SET `entry` = 900300, `name` = 'Dragon Scale', `class` = 15, `subclass` = 0, `Quality` = 2, `stackable` = 250,
  `description` = 'Boss Fights: trade with the Hoard Keeper in Gurubashi Arena.' WHERE `entry` = 15416;
UPDATE `bf_item` SET `entry` = 900301, `name` = 'Dragon Egg', `class` = 15, `subclass` = 0, `Quality` = 3, `stackable` = 5,
  `description` = 'Boss Fights: five of them hatch a whelp.' WHERE `entry` = 3685;
UPDATE `bf_item` SET `entry` = 900302, `description` = 'Hatched from five Dragon Eggs.' WHERE `entry` = 10822;
UPDATE `bf_item` SET `SellPrice` = 0, `BuyPrice` = 0, `bonding` = 1, `startquest` = 0;
DELETE FROM `item_template` WHERE `entry` IN (900300, 900301, 900302);
INSERT INTO `item_template` SELECT * FROM `bf_item`;
DROP TEMPORARY TABLE `bf_item`;

-- The Hoard Keeper's shop (OpenVanilla.BossFights.Shop: "<item>:<scales> ..."): copies of stock tabards, pets and toys,
-- soulbound, sell for nothing (the stock items themselves are untouched).
--   900310 Contest Winner's Tabard (19160)   900311 Tabard of the Scarlet Crusade (23192)   900312 Tabard of the Argent Dawn (22999)
--   900313 Parrot Cage (8494)   900314 Cat Carrier (Corrupted Kitten) (11903)   900315 Mechanical Chicken (10398)
--   900316 Green Helper Box (21301)   900317 Lil' Smoky (11826)   900318 Piccolo of the Flaming Fire (13379)
--   900319 Winter Veil Disguise Kit (17712)   900320 Orb of Deception (1973)   900321 Heavy Leather Ball (18662)
DROP TEMPORARY TABLE IF EXISTS `bf_item`;
CREATE TEMPORARY TABLE `bf_item` AS SELECT * FROM `item_template`
  WHERE `entry` IN (19160, 23192, 22999, 8494, 11903, 10398, 21301, 11826, 13379, 17712, 1973, 18662);
UPDATE `bf_item` SET `entry` = CASE `entry`
  WHEN 19160 THEN 900310 WHEN 23192 THEN 900311 WHEN 22999 THEN 900312 WHEN 8494 THEN 900313 WHEN 11903 THEN 900314
  WHEN 10398 THEN 900315 WHEN 21301 THEN 900316 WHEN 11826 THEN 900317 WHEN 13379 THEN 900318 WHEN 17712 THEN 900319
  WHEN 1973 THEN 900320 WHEN 18662 THEN 900321 END;
UPDATE `bf_item` SET `SellPrice` = 0, `BuyPrice` = 0, `bonding` = 1, `startquest` = 0, `description` = 'Boss Fights: from the Dragon\'s Hoard.';
DELETE FROM `item_template` WHERE `entry` BETWEEN 900310 AND 900321;
INSERT INTO `item_template` SELECT * FROM `bf_item`;
DROP TEMPORARY TABLE `bf_item`;

-- The Hall of Fame keeper (this week's fastest clear per raid and tier) and the Hoard Keeper (the Dragon Scales shop),
-- in the stands by the quartermasters. Both factions, gossip only (ScriptNames: OpenVanilla/BossFightsNpcs.cpp).
DROP TEMPORARY TABLE IF EXISTS `bf_tpl`;
CREATE TEMPORARY TABLE `bf_tpl` AS SELECT * FROM `creature_template` WHERE `Entry` = 14508;
INSERT INTO `bf_tpl` SELECT * FROM `creature_template` WHERE `Entry` = 14508;
UPDATE `bf_tpl` SET `Entry` = 900201 LIMIT 1;
UPDATE `bf_tpl` SET `Entry` = 900202 WHERE `Entry` = 14508;
UPDATE `bf_tpl` SET `Name` = 'Chronicler Zan\'tu', `SubName` = 'Boss Fights Hall of Fame', `ScriptName` = 'npc_openvanilla_bf_hall' WHERE `Entry` = 900201;
UPDATE `bf_tpl` SET `Name` = 'Hoard Keeper Vexna', `SubName` = 'Dragon Scales', `ScriptName` = 'npc_openvanilla_bf_hoard' WHERE `Entry` = 900202;
UPDATE `bf_tpl` SET `MinLevel` = 60, `MaxLevel` = 60, `Faction` = 35, `NpcFlags` = 1, `AIName` = '', `GossipMenuId` = 0, `VendorTemplateId` = 0;
DELETE FROM `creature_template` WHERE `Entry` IN (900201, 900202);
INSERT INTO `creature_template` SELECT * FROM `bf_tpl`;
DROP TEMPORARY TABLE `bf_tpl`;
DELETE FROM `creature` WHERE `guid` IN (9200203, 9200204);
INSERT INTO `creature` (`guid`, `id`, `map`, `spawnMask`, `position_x`, `position_y`, `position_z`, `orientation`, `spawntimesecsmin`, `spawntimesecsmax`, `spawndist`, `MovementType`)
  VALUES (9200203, 900201, 0, 1, -13225.5, 232.5, 33.2, 1.1, 30, 30, 0, 0),
         (9200204, 900202, 0, 1, -13212.5, 239.5, 33.2, 1.1, 30, 30, 0, 0);
