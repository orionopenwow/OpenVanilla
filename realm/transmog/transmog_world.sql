-- Open Vanilla: the Transmogrifiers (run against the world database; idempotent).
-- Two NPCs, one for Alliance towns and one for Horde towns, beside the innkeeper of each capital
-- and of Booty Bay and Gadgetzan. Talking to one opens the Transmog addon's window; saving looks
-- needs one within 12 yards (OpenVanilla.Transmog.RequireNpc). Switching outfits works anywhere.
-- IDs: creatures 990300-990301, spawns 9100301-9100308. Both are copies of Magus Tirth (a friendly
-- robed caster), renamed, with gossip only.

DELETE FROM creature_template WHERE Entry IN (990300, 990301);
DROP TEMPORARY TABLE IF EXISTS ow_tmp_tm;
CREATE TEMPORARY TABLE ow_tmp_tm SELECT * FROM creature_template WHERE Entry = 6548;
UPDATE ow_tmp_tm SET Entry = 990300, Name = 'Lyriel Threadweave', SubName = 'Transmogrifier',
  MinLevel = 60, MaxLevel = 60, Faction = 35, NpcFlags = 1, VendorTemplateId = 0, GossipMenuId = 0,
  AIName = '', ScriptName = '';
INSERT INTO creature_template SELECT * FROM ow_tmp_tm;
UPDATE ow_tmp_tm SET Entry = 990301, Name = 'Morga Silkhand';
INSERT INTO creature_template SELECT * FROM ow_tmp_tm;
DROP TEMPORARY TABLE ow_tmp_tm;

DELETE FROM creature WHERE guid BETWEEN 9100301 AND 9100308;
INSERT INTO creature (guid, id, map, position_x, position_y, position_z, orientation, spawntimesecsmin, spawntimesecsmax, spawndist, MovementType) VALUES
  (9100301, 990300, 0, -8864.70, 675.31, 97.99, 5.20, 300, 300, 0, 0),   -- Stormwind, the Gilded Rose, beside the innkeeper
  (9100302, 990300, 0, -4837.21, -856.54, 502.00, 4.87, 300, 300, 0, 0),   -- Ironforge, Stonefire Tavern, beside the innkeeper
  (9100303, 990300, 1, 10125.11, 2222.67, 1328.81, 2.22, 300, 300, 0, 0),   -- Darnassus, the inn, beside the innkeeper
  (9100304, 990300, 0, -14455.10, 493.01, 15.21, 3.98, 300, 300, 0, 0),   -- Booty Bay, the inn, beside the innkeeper
  (9100305, 990301, 1, 1632.69, -4442.62, 15.52, 2.76, 300, 300, 0, 0),   -- Orgrimmar, the inn, beside the innkeeper
  (9100306, 990301, 0, 1634.36, 219.99, -43.02, 2.84, 300, 300, 0, 0),   -- Undercity, the inn, beside the innkeeper
  (9100307, 990301, 1, -1302.14, 41.46, 129.29, 0.56, 300, 300, 0, 0),   -- Thunder Bluff, the inn, beside the innkeeper
  (9100308, 990301, 1, -7162.21, -3842.91, 8.85, 1.95, 300, 300, 0, 0);   -- Gadgetzan, the inn, beside the innkeeper
