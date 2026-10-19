-- Open Vanilla Classic+: class quests every one of the 56 race/class combos can reach (PENDING:
-- launch day, after classicplus_races.sql from this folder). Run against classicmangos; idempotent.
--
-- Already open to every combo in stock classic-db (faction race masks 77 = Alliance, 178 = Horde):
-- warlock Voidwalker / Succubus / Felhunter, warrior stances, rogue poisons, shaman totems,
-- paladin Redemption (Human/Dwarf). What this file adds:
--   Hunter    Gnome: the Dun Morogh taming chain (Grif Wildheart, Kharanos), like Dwarves.
--             Human: a new taming chain in Goldshire, Elwynn Forest (Huntsman Aldric Vale).
--             Undead: a new taming chain in Brill, Tirisfal Glades (Deathstalker Morra Quill).
--   Druid     Troll: the Tauren druid quests (Bear Form, Cure Poison, Aquatic Form; the chain
--             starts with Heeding the Call from the Orgrimmar and Thunder Bluff innkeepers).
--             All druids: the Aquatic Form chain's crossed links in classic-db are fixed.
--   Warlock   Night Elf / Tauren start where no warlock trainer stands (no Imp quest): their
--             Summon Imp comes with the character (classicplus_races.sql; existing characters
--             get it from classicplus_characters.sql).
-- The new chains work like the stock ones: each Taming Rod tames one local beast for a while
-- (the rod's spell, limited to that beast by item_required_target); the third quest teaches Tame
-- Beast, Call Pet and Dismiss Pet, the fourth Beast Training, Feed Pet and Revive Pet.
-- IDs: creatures 990601-990602, spawns 9100601-9100602, items 990611-990616, quests 90601-90608.

-- ── Gnome hunters: the Dwarf chain in Dun Morogh ──
UPDATE quest_template SET RequiredRaces = RequiredRaces | 64 WHERE entry IN (6064, 6084, 6085, 6086) AND RequiredRaces & 4;

-- ── Troll druids: the Tauren druid quests ──
UPDATE quest_template SET RequiredRaces = RequiredRaces | 128 WHERE RequiredClasses = 1024 AND RequiredRaces & 32 AND NOT RequiredRaces & 8;

-- ── Druid Aquatic Form, all druid races: classic-db links each faction's "A Lesson to Learn" to the
--    other faction's "Trial of the Lake" (26 -> 28, 27 -> 29), so neither side can go on. Uncross them.
UPDATE quest_template SET PrevQuestId = 26 WHERE entry = 29;
UPDATE quest_template SET PrevQuestId = 27 WHERE entry = 28;
UPDATE quest_template SET NextQuestInChain = 29 WHERE entry = 26;
UPDATE quest_template SET NextQuestInChain = 28 WHERE entry = 27;

-- ── The two new hunter trainers (copies of Grif Wildheart, renamed and re-dressed) ──
DELETE FROM creature_template WHERE Entry IN (990601, 990602);
DROP TEMPORARY TABLE IF EXISTS ow_tmp_npc;
CREATE TEMPORARY TABLE ow_tmp_npc SELECT * FROM creature_template WHERE Entry = 1231;
UPDATE ow_tmp_npc SET Entry = 990601, Name = 'Huntsman Aldric Vale', SubName = 'Hunter Trainer',
  DisplayId1 = 3274, DisplayId2 = 0, DisplayId3 = 0, DisplayId4 = 0, Faction = 12, MinLevel = 30, MaxLevel = 30,
  NpcFlags = 19, GossipMenuId = 0, AIName = '', ScriptName = '';
INSERT INTO creature_template SELECT * FROM ow_tmp_npc;
UPDATE ow_tmp_npc SET Entry = 990602, Name = 'Deathstalker Morra Quill', SubName = 'Hunter Trainer',
  DisplayId1 = 569, Faction = 68;
INSERT INTO creature_template SELECT * FROM ow_tmp_npc;
DROP TEMPORARY TABLE ow_tmp_npc;
-- they teach what any hunter trainer teaches (Grif's own list)
DELETE FROM npc_trainer WHERE entry IN (990601, 990602);
INSERT INTO npc_trainer (entry, spell, spellcost, reqskill, reqskillvalue, reqlevel, ReqAbility1, ReqAbility2, ReqAbility3, condition_id)
  SELECT n.id, t.spell, t.spellcost, t.reqskill, t.reqskillvalue, t.reqlevel, t.ReqAbility1, t.ReqAbility2, t.ReqAbility3, t.condition_id
  FROM npc_trainer t JOIN (SELECT 990601 AS id UNION ALL SELECT 990602) n WHERE t.entry = 1231;

DELETE FROM creature WHERE guid IN (9100601, 9100602);
INSERT INTO creature (guid, id, map, position_x, position_y, position_z, orientation, spawntimesecsmin, spawntimesecsmax, spawndist, MovementType) VALUES
  (9100601, 990601, 0, -9462.6, 70.9, 56.40, 2.40, 300, 300, 0, 0),   -- Goldshire, beside Marshal Dughan
  (9100602, 990602, 0, 2281.2, 297.9, 36.20, 3.80, 300, 300, 0, 0);   -- Brill, beside Executor Zygand

-- ── Taming Rods for the new chains (copies of the stock rods; each works on one local beast) ──
DELETE FROM item_template WHERE entry BETWEEN 990611 AND 990616;
DROP TEMPORARY TABLE IF EXISTS ow_tmp_item;
CREATE TEMPORARY TABLE ow_tmp_item SELECT * FROM item_template WHERE entry = 15911;
UPDATE ow_tmp_item SET entry = 990611, spellid_1 = 19674, description = 'Use it on a Stonetusk Boar.';
INSERT INTO item_template SELECT * FROM ow_tmp_item;
UPDATE ow_tmp_item SET entry = 990612, spellid_1 = 19548, description = 'Use it on a Young Forest Bear.';
INSERT INTO item_template SELECT * FROM ow_tmp_item;
UPDATE ow_tmp_item SET entry = 990613, spellid_1 = 19689, description = 'Use it on a Prowler.';
INSERT INTO item_template SELECT * FROM ow_tmp_item;
UPDATE ow_tmp_item SET entry = 990614, spellid_1 = 19692, description = 'Use it on a Greater Duskbat.';
INSERT INTO item_template SELECT * FROM ow_tmp_item;
UPDATE ow_tmp_item SET entry = 990615, spellid_1 = 19700, description = 'Use it on a Vampiric Duskbat.';
INSERT INTO item_template SELECT * FROM ow_tmp_item;
UPDATE ow_tmp_item SET entry = 990616, spellid_1 = 19693, description = 'Use it on a Vicious Night Web Spider.';
INSERT INTO item_template SELECT * FROM ow_tmp_item;
DROP TEMPORARY TABLE ow_tmp_item;
DELETE FROM item_required_target WHERE entry BETWEEN 990611 AND 990616;
INSERT INTO item_required_target (entry, type, targetEntry) VALUES
  (990611, 1, 113), (990612, 1, 822), (990613, 1, 118),      -- Elwynn: Stonetusk Boar, Young Forest Bear, Prowler
  (990614, 1, 1553), (990615, 1, 1554), (990616, 1, 1555);   -- Tirisfal: Greater / Vampiric Duskbat, Vicious Night Web Spider

-- ── The quests: copies of the Dun Morogh chain's rows (6064 taming, 6086 training), retold ──
-- A taming quest is done when the rod's taming takes hold (the final taming spell lands on the beast).
DELETE FROM quest_template WHERE entry BETWEEN 90601 AND 90608;
DROP TEMPORARY TABLE IF EXISTS ow_tmp_quest;
CREATE TEMPORARY TABLE ow_tmp_quest SELECT * FROM quest_template WHERE entry = 6064;
UPDATE ow_tmp_quest SET SpecialFlags = 0, ReqCreatureOrGOCount1 = 1,
  RewSpell = 0, RewSpellCast = 0, PrevQuestId = 0, NextQuestId = 0, ExclusiveGroup = 0, NextQuestInChain = 0,
  ZoneOrSort = -261, RequiredClasses = 4, StartScript = 0, CompleteScript = 0;

-- Human, Elwynn Forest
UPDATE ow_tmp_quest SET entry = 90601, RequiredRaces = 1, SrcItemId = 990611, ReqItemId1 = 990611, ReqItemCount1 = 1, ReqCreatureOrGOId1 = 113, ReqSpellCast1 = 19677, NextQuestInChain = 90602,
  Title = 'Taming the Beast',
  Details = 'So, $N, you want a companion of your own. Good. A hunter and a beast who trust each other are worth any three swords.$B$BWe start small. Take this Taming Rod and find a Stonetusk Boar in the fields around Goldshire. Use the rod on it and hold steady until the beast accepts you.',
  Objectives = 'Use the Taming Rod to tame a Stonetusk Boar, then return to Huntsman Aldric Vale in Goldshire.',
  OfferRewardText = 'Stubborn things, boars, but you held on. That is half of taming: patience.',
  RequestItemsText = 'Have you tamed a Stonetusk Boar yet, $N?', ObjectiveText1 = 'Stonetusk Boar tamed';
INSERT INTO quest_template SELECT * FROM ow_tmp_quest;
UPDATE ow_tmp_quest SET entry = 90602, SrcItemId = 990612, ReqItemId1 = 990612, ReqItemCount1 = 1, ReqCreatureOrGOId1 = 822, ReqSpellCast1 = 19597, NextQuestInChain = 90603,
  Details = 'Next, something with more bite. Young Forest Bears roam the woods east of Goldshire. Take this rod and tame one. Bears test your nerve: do not flinch.',
  Objectives = 'Use the Taming Rod to tame a Young Forest Bear, then return to Huntsman Aldric Vale in Goldshire.',
  OfferRewardText = 'A bear! You are getting the knack of this.',
  RequestItemsText = 'The bears are east of here, $N.', ObjectiveText1 = 'Young Forest Bear tamed';
INSERT INTO quest_template SELECT * FROM ow_tmp_quest;
UPDATE ow_tmp_quest SET entry = 90603, SrcItemId = 990613, ReqItemId1 = 990613, ReqItemCount1 = 1, ReqCreatureOrGOId1 = 118, ReqSpellCast1 = 19679, NextQuestInChain = 90604,
  RewSpell = 23356, RewSpellCast = 1579,
  Details = 'One more. The Prowlers of the western woods are wolves of the old kind: fast, proud and wary of people. Tame one with this rod and I will teach you to tame any beast you like.',
  Objectives = 'Use the Taming Rod to tame a Prowler, then return to Huntsman Aldric Vale in Goldshire.',
  OfferRewardText = 'Well done, $N. You are ready: from now on you can tame a beast of your own, call it to your side and send it home.',
  RequestItemsText = 'Have you tamed a Prowler yet?', ObjectiveText1 = 'Prowler tamed';
INSERT INTO quest_template SELECT * FROM ow_tmp_quest;

-- Undead, Tirisfal Glades
UPDATE ow_tmp_quest SET entry = 90605, RequiredRaces = 16, SrcItemId = 990614, ReqItemId1 = 990614, ReqItemCount1 = 1, ReqCreatureOrGOId1 = 1553, ReqSpellCast1 = 19680, NextQuestInChain = 90606,
  RewSpell = 0, RewSpellCast = 0,
  Details = 'The living think beasts flee from us. Most do. The ones that stay are worth having, $N.$B$BTake this Taming Rod and find a Greater Duskbat in the fields near Brill. Use the rod and keep your hold until it is yours.',
  Objectives = 'Use the Taming Rod to tame a Greater Duskbat, then return to Deathstalker Morra Quill in Brill.',
  OfferRewardText = 'The bat answered you. A good start.',
  RequestItemsText = 'The duskbats are all around Brill, $N.', ObjectiveText1 = 'Greater Duskbat tamed';
INSERT INTO quest_template SELECT * FROM ow_tmp_quest;
UPDATE ow_tmp_quest SET entry = 90606, SrcItemId = 990615, ReqItemId1 = 990615, ReqItemCount1 = 1, ReqCreatureOrGOId1 = 1554, ReqSpellCast1 = 19686, NextQuestInChain = 90607,
  Details = 'Vampiric Duskbats hunt south of Brill, near the old farms. They are hungrier and harder to hold. Tame one with this rod.',
  Objectives = 'Use the Taming Rod to tame a Vampiric Duskbat, then return to Deathstalker Morra Quill in Brill.',
  OfferRewardText = 'Hungry, but it listened. You have a steady will.',
  RequestItemsText = 'Have you tamed a Vampiric Duskbat?', ObjectiveText1 = 'Vampiric Duskbat tamed';
INSERT INTO quest_template SELECT * FROM ow_tmp_quest;
UPDATE ow_tmp_quest SET entry = 90607, SrcItemId = 990616, ReqItemId1 = 990616, ReqItemCount1 = 1, ReqCreatureOrGOId1 = 1555, ReqSpellCast1 = 19684, NextQuestInChain = 90608,
  RewSpell = 23356, RewSpellCast = 1579,
  Details = 'Last: the Vicious Night Web Spiders in the mine south of the Brill road. Tame one and you will have earned the right to tame any beast you wish.',
  Objectives = 'Use the Taming Rod to tame a Vicious Night Web Spider, then return to Deathstalker Morra Quill in Brill.',
  OfferRewardText = 'Well done, $N. From now on you can tame a beast of your own, call it to your side and send it home.',
  RequestItemsText = 'Have you tamed a Vicious Night Web Spider?', ObjectiveText1 = 'Vicious Night Web Spider tamed';
INSERT INTO quest_template SELECT * FROM ow_tmp_quest;
DROP TEMPORARY TABLE ow_tmp_quest;

-- The training quests (no objective: talk to the trainer), copies of "Training the Beast" (6086).
CREATE TEMPORARY TABLE ow_tmp_quest SELECT * FROM quest_template WHERE entry = 6086;
UPDATE ow_tmp_quest SET entry = 90604, RequiredRaces = 1, PrevQuestId = 90603, NextQuestId = 0, ExclusiveGroup = 0, NextQuestInChain = 0,
  ZoneOrSort = -261, StartScript = 0, CompleteScript = 0,
  Title = 'Training the Beast',
  Details = 'A beast at your side needs more than a firm hand. Let me show you how to feed it, how to bring it back when it falls, and how to teach it new tricks.',
  Objectives = 'Speak with Huntsman Aldric Vale in Goldshire.',
  OfferRewardText = 'Feed it, care for it and train it, $N, and it will never leave your side.';
INSERT INTO quest_template SELECT * FROM ow_tmp_quest;
UPDATE ow_tmp_quest SET entry = 90608, RequiredRaces = 16, PrevQuestId = 90607,
  Objectives = 'Speak with Deathstalker Morra Quill in Brill.';
INSERT INTO quest_template SELECT * FROM ow_tmp_quest;
DROP TEMPORARY TABLE ow_tmp_quest;
UPDATE quest_template SET PrevQuestId = 90601 WHERE entry = 90602;
UPDATE quest_template SET PrevQuestId = 90602 WHERE entry = 90603;
UPDATE quest_template SET PrevQuestId = 90605 WHERE entry = 90606;
UPDATE quest_template SET PrevQuestId = 90606 WHERE entry = 90607;

DELETE FROM creature_questrelation WHERE quest BETWEEN 90601 AND 90608;
DELETE FROM creature_involvedrelation WHERE quest BETWEEN 90601 AND 90608;
INSERT INTO creature_questrelation (id, quest) VALUES
  (990601, 90601), (990601, 90602), (990601, 90603), (990601, 90604),
  (990602, 90605), (990602, 90606), (990602, 90607), (990602, 90608);
INSERT INTO creature_involvedrelation (id, quest) VALUES
  (990601, 90601), (990601, 90602), (990601, 90603), (990601, 90604),
  (990602, 90605), (990602, 90606), (990602, 90607), (990602, 90608);
