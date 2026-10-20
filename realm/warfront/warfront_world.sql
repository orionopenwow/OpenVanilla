-- Warfront: changes to a STOCK classic world database (the Warfront world database only; never
-- the Classic+ one). Load after warfront_kits.sql and warfront_item_pool.sql. Re-runnable.

-- New characters start in their faction's capital (and their hearthstone is bound there).
UPDATE `playercreateinfo` SET `map` = 0, `zone` = 1519, `position_x` = -8833.38, `position_y` = 628.628, `position_z` = 94.0066, `orientation` = 1.06535
  WHERE `race` IN (1, 3, 4, 7);
UPDATE `playercreateinfo` SET `map` = 1, `zone` = 1637, `position_x` = 1629.36, `position_y` = -4373.39, `position_z` = 31.2564, `orientation` = 3.54839
  WHERE `race` IN (2, 5, 6, 8);

-- Battlegrounds start with fewer players and fill as people join.
UPDATE `battleground_template` SET `MinPlayersPerTeam` = 6 WHERE `id` = 2;   -- Warsong Gulch (max 10)
UPDATE `battleground_template` SET `MinPlayersPerTeam` = 6 WHERE `id` = 3;   -- Arathi Basin (max 15)
UPDATE `battleground_template` SET `MinPlayersPerTeam` = 20 WHERE `id` = 1;  -- Alterac Valley (max 40)

-- The Gurubashi Arena chest every 60 minutes instead of every 3 hours.
UPDATE `game_event` SET `occurence` = 60 WHERE `entry` = 16;

-- Nothing Warfront hands out for free can be turned into gold: no vendor price, no disenchanting.
-- (Picker items, the shop's goods, and the welcome bags, mounts and supplies.)
UPDATE `item_template` t JOIN `warfront_item_pool` p ON p.`item` = t.`entry` SET t.`SellPrice` = 0, t.`DisenchantID` = 0;
UPDATE `item_template` t JOIN `warfront_consumable` c ON c.`item` = t.`entry` SET t.`SellPrice` = 0;
UPDATE `item_template` SET `SellPrice` = 0 WHERE `entry` IN (17966, 4500, 18776, 18797, 14530, 15993, 13446, 5634);
