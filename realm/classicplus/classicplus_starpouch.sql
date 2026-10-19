-- Open Vanilla Classic+: Star Pouches, one for every level gained (the world server's StarPouch
-- hook hands out 90100 + band). Each holds gold, a potion kit, a scroll and a world-drop
-- green from the band's levels (a 25% chance of a second). Our own item ids (90100-90105),
-- cloned from item 17962's shape so the row matches this database's item_template columns.
-- Idempotent: re-running changes nothing (the last UPDATE fixes rows from older runs).

-- Star Pouch, levels 2-10
DROP TEMPORARY TABLE IF EXISTS openvanilla_pouch;
CREATE TEMPORARY TABLE openvanilla_pouch AS SELECT * FROM item_template WHERE entry = 17962;
UPDATE openvanilla_pouch SET entry = 90100, name = 'Star Pouch', displayid = 2588, Quality = 3, Flags = 4, BuyPrice = 0, SellPrice = 0, ItemLevel = 10, RequiredLevel = 0, stackable = 1, bonding = 1, description = 'A gift from the stars for reaching level 2-10. Right-click to open.', minMoneyLoot = 2500, maxMoneyLoot = 7500;
INSERT IGNORE INTO item_template SELECT * FROM openvanilla_pouch;
INSERT IGNORE INTO item_loot_template (entry,item,ChanceOrQuestChance,groupid,mincountOrRef,maxcount,condition_id,comments) VALUES
  (90100,118,100,0,3,3,0,'Star Pouch: healing potions'),
  (90100,2455,100,0,2,2,0,'Star Pouch: mana potions'),
  (90100,1181,0,1,1,2,0,'Star Pouch: one scroll'),
  (90100,3013,0,1,1,2,0,'Star Pouch: one scroll'),
  (90100,955,0,1,1,2,0,'Star Pouch: one scroll'),
  (90100,1180,0,1,1,2,0,'Star Pouch: one scroll'),
  (90100,60102,100,0,-60102,1,0,'Star Pouch: a world-drop green from the band'),
  (90100,60103,25,0,-60103,1,0,'Star Pouch: sometimes a second');

-- Star Pouch, levels 11-20
DROP TEMPORARY TABLE IF EXISTS openvanilla_pouch;
CREATE TEMPORARY TABLE openvanilla_pouch AS SELECT * FROM item_template WHERE entry = 17962;
UPDATE openvanilla_pouch SET entry = 90101, name = 'Star Pouch', displayid = 2588, Quality = 3, Flags = 4, BuyPrice = 0, SellPrice = 0, ItemLevel = 20, RequiredLevel = 0, stackable = 1, bonding = 1, description = 'A gift from the stars for reaching level 11-20. Right-click to open.', minMoneyLoot = 10000, maxMoneyLoot = 20000;
INSERT IGNORE INTO item_template SELECT * FROM openvanilla_pouch;
INSERT IGNORE INTO item_loot_template (entry,item,ChanceOrQuestChance,groupid,mincountOrRef,maxcount,condition_id,comments) VALUES
  (90101,929,100,0,3,3,0,'Star Pouch: healing potions'),
  (90101,3385,100,0,2,2,0,'Star Pouch: mana potions'),
  (90101,954,0,1,1,2,0,'Star Pouch: one scroll'),
  (90101,3012,0,1,1,2,0,'Star Pouch: one scroll'),
  (90101,1478,0,1,1,2,0,'Star Pouch: one scroll'),
  (90101,1712,0,1,1,2,0,'Star Pouch: one scroll'),
  (90101,60122,100,0,-60122,1,0,'Star Pouch: a world-drop green from the band'),
  (90101,60123,25,0,-60123,1,0,'Star Pouch: sometimes a second');

-- Star Pouch, levels 21-30
DROP TEMPORARY TABLE IF EXISTS openvanilla_pouch;
CREATE TEMPORARY TABLE openvanilla_pouch AS SELECT * FROM item_template WHERE entry = 17962;
UPDATE openvanilla_pouch SET entry = 90102, name = 'Star Pouch', displayid = 2588, Quality = 3, Flags = 4, BuyPrice = 0, SellPrice = 0, ItemLevel = 30, RequiredLevel = 0, stackable = 1, bonding = 1, description = 'A gift from the stars for reaching level 21-30. Right-click to open.', minMoneyLoot = 20000, maxMoneyLoot = 40000;
INSERT IGNORE INTO item_template SELECT * FROM openvanilla_pouch;
INSERT IGNORE INTO item_loot_template (entry,item,ChanceOrQuestChance,groupid,mincountOrRef,maxcount,condition_id,comments) VALUES
  (90102,1710,100,0,3,3,0,'Star Pouch: healing potions'),
  (90102,3827,100,0,2,2,0,'Star Pouch: mana potions'),
  (90102,1711,0,1,1,2,0,'Star Pouch: one scroll'),
  (90102,2290,0,1,1,2,0,'Star Pouch: one scroll'),
  (90102,1477,0,1,1,2,0,'Star Pouch: one scroll'),
  (90102,2289,0,1,1,2,0,'Star Pouch: one scroll'),
  (90102,60142,100,0,-60142,1,0,'Star Pouch: a world-drop green from the band'),
  (90102,60143,25,0,-60143,1,0,'Star Pouch: sometimes a second');

-- Star Pouch, levels 31-40
DROP TEMPORARY TABLE IF EXISTS openvanilla_pouch;
CREATE TEMPORARY TABLE openvanilla_pouch AS SELECT * FROM item_template WHERE entry = 17962;
UPDATE openvanilla_pouch SET entry = 90103, name = 'Star Pouch', displayid = 2588, Quality = 3, Flags = 4, BuyPrice = 0, SellPrice = 0, ItemLevel = 40, RequiredLevel = 0, stackable = 1, bonding = 1, description = 'A gift from the stars for reaching level 31-40. Right-click to open.', minMoneyLoot = 40000, maxMoneyLoot = 70000;
INSERT IGNORE INTO item_template SELECT * FROM openvanilla_pouch;
INSERT IGNORE INTO item_loot_template (entry,item,ChanceOrQuestChance,groupid,mincountOrRef,maxcount,condition_id,comments) VALUES
  (90103,3928,100,0,3,3,0,'Star Pouch: healing potions'),
  (90103,6149,100,0,2,2,0,'Star Pouch: mana potions'),
  (90103,4421,0,1,1,2,0,'Star Pouch: one scroll'),
  (90103,4424,0,1,1,2,0,'Star Pouch: one scroll'),
  (90103,4419,0,1,1,2,0,'Star Pouch: one scroll'),
  (90103,4422,0,1,1,2,0,'Star Pouch: one scroll'),
  (90103,60162,100,0,-60162,1,0,'Star Pouch: a world-drop green from the band'),
  (90103,60163,25,0,-60163,1,0,'Star Pouch: sometimes a second');

-- Star Pouch, levels 41-50
DROP TEMPORARY TABLE IF EXISTS openvanilla_pouch;
CREATE TEMPORARY TABLE openvanilla_pouch AS SELECT * FROM item_template WHERE entry = 17962;
UPDATE openvanilla_pouch SET entry = 90104, name = 'Star Pouch', displayid = 2588, Quality = 3, Flags = 4, BuyPrice = 0, SellPrice = 0, ItemLevel = 50, RequiredLevel = 0, stackable = 1, bonding = 1, description = 'A gift from the stars for reaching level 41-50. Right-click to open.', minMoneyLoot = 70000, maxMoneyLoot = 110000;
INSERT IGNORE INTO item_template SELECT * FROM openvanilla_pouch;
INSERT IGNORE INTO item_loot_template (entry,item,ChanceOrQuestChance,groupid,mincountOrRef,maxcount,condition_id,comments) VALUES
  (90104,13446,100,0,3,3,0,'Star Pouch: healing potions'),
  (90104,13443,100,0,2,2,0,'Star Pouch: mana potions'),
  (90104,4425,0,1,1,2,0,'Star Pouch: one scroll'),
  (90104,4426,0,1,1,2,0,'Star Pouch: one scroll'),
  (90104,10305,0,1,1,2,0,'Star Pouch: one scroll'),
  (90104,10306,0,1,1,2,0,'Star Pouch: one scroll'),
  (90104,60182,100,0,-60182,1,0,'Star Pouch: a world-drop green from the band'),
  (90104,60183,25,0,-60183,1,0,'Star Pouch: sometimes a second');

-- Star Pouch, levels 51-60
DROP TEMPORARY TABLE IF EXISTS openvanilla_pouch;
CREATE TEMPORARY TABLE openvanilla_pouch AS SELECT * FROM item_template WHERE entry = 17962;
UPDATE openvanilla_pouch SET entry = 90105, name = 'Star Pouch', displayid = 2588, Quality = 3, Flags = 4, BuyPrice = 0, SellPrice = 0, ItemLevel = 60, RequiredLevel = 0, stackable = 1, bonding = 1, description = 'A gift from the stars for reaching level 51-60. Right-click to open.', minMoneyLoot = 110000, maxMoneyLoot = 160000;
INSERT IGNORE INTO item_template SELECT * FROM openvanilla_pouch;
INSERT IGNORE INTO item_loot_template (entry,item,ChanceOrQuestChance,groupid,mincountOrRef,maxcount,condition_id,comments) VALUES
  (90105,13446,100,0,5,5,0,'Star Pouch: healing potions'),
  (90105,13444,100,0,3,3,0,'Star Pouch: mana potions'),
  (90105,10307,0,1,1,2,0,'Star Pouch: one scroll'),
  (90105,10308,0,1,1,2,0,'Star Pouch: one scroll'),
  (90105,10309,0,1,1,2,0,'Star Pouch: one scroll'),
  (90105,10310,0,1,1,2,0,'Star Pouch: one scroll'),
  (90105,60198,100,0,-60198,1,0,'Star Pouch: a world-drop green from the band'),
  (90105,60199,25,0,-60199,1,0,'Star Pouch: sometimes a second');

DROP TEMPORARY TABLE IF EXISTS openvanilla_pouch;

-- One pouch per slot: an emptied loot container is destroyed as a whole item, so a stack of
-- pouches would vanish together when the first is emptied. INSERT IGNORE leaves rows from an
-- earlier run (stackable = 10) as they were, so set it here too.
UPDATE item_template SET stackable = 1 WHERE entry BETWEEN 90100 AND 90105 AND stackable <> 1;
