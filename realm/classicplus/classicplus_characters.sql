-- Open Vanilla Classic+: per-character gameplay tables and one-time fixes (PENDING: launch day, BEFORE the
-- world server starts on the 0003/0004 build). Run against classicmangos like the other files: the
-- tables live in classiccharacters and are named with it. Idempotent.
-- Without these tables the world server keeps running: dual spec and the starter pet switch
-- themselves off (and say so in the server log).

-- One row per character that used dual spec or got a starter pet.
CREATE TABLE IF NOT EXISTS classiccharacters.openvanilla_character (
  guid         INT UNSIGNED NOT NULL PRIMARY KEY COMMENT 'characters.guid',
  active_spec  TINYINT UNSIGNED NOT NULL DEFAULT 1 COMMENT '1 or 2',
  starter_pet  TINYINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '1 = got the hunter starter pet'
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='Open Vanilla: gameplay state per character';

-- The spec a character is NOT using right now (the active one is its live talents and bars).
CREATE TABLE IF NOT EXISTS classiccharacters.openvanilla_spec (
  guid     INT UNSIGNED NOT NULL COMMENT 'characters.guid',
  spec     TINYINT UNSIGNED NOT NULL COMMENT '1 or 2',
  name     VARCHAR(32) NOT NULL DEFAULT '' COMMENT 'player-chosen name (empty = Spec 1 / Spec 2)',
  talents  TEXT NOT NULL COMMENT '"talentId:rank,..." (rank 0-based), as of the last switch away',
  PRIMARY KEY (guid, spec)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='Open Vanilla: dual spec talents';

CREATE TABLE IF NOT EXISTS classiccharacters.openvanilla_spec_action (
  guid    INT UNSIGNED NOT NULL COMMENT 'characters.guid',
  spec    TINYINT UNSIGNED NOT NULL,
  button  TINYINT UNSIGNED NOT NULL,
  action  INT UNSIGNED NOT NULL,
  type    TINYINT UNSIGNED NOT NULL,
  PRIMARY KEY (guid, spec, button)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='Open Vanilla: dual spec action bars';

-- Night Elf and Tauren warlocks start where no warlock trainer stands (no Imp quest): new ones get
-- Summon Imp at creation (classicplus_races.sql); the ones made before get it here.
INSERT IGNORE INTO classiccharacters.character_spell (guid, spell, active, disabled)
  SELECT guid, 688, 1, 0 FROM classiccharacters.characters WHERE class = 9 AND race IN (4, 6);
