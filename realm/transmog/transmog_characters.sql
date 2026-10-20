-- Open Vanilla transmog: the characters database tables (idempotent). See
-- src/game/OpenVanilla/Transmog.h (patch 0011) for what each holds and the rules.

CREATE TABLE IF NOT EXISTS transmog_account (
  account   INT UNSIGNED NOT NULL PRIMARY KEY,
  outfits   TINYINT UNSIGNED NOT NULL DEFAULT 2,     -- outfit slots unlocked (warband-wide), 2 free
  seeded    TINYINT UNSIGNED NOT NULL DEFAULT 0      -- owned gear already learned
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS transmog_source (
  account   INT UNSIGNED NOT NULL,
  item      INT UNSIGNED NOT NULL,                   -- a collected look (item entry)
  PRIMARY KEY (account, item)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS transmog_illusion (
  account   INT UNSIGNED NOT NULL,
  enchant   INT UNSIGNED NOT NULL,                   -- SpellItemEnchantment id
  PRIMARY KEY (account, enchant)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS transmog_character (
  guid      INT UNSIGNED NOT NULL PRIMARY KEY,
  active    TINYINT UNSIGNED NOT NULL DEFAULT 0,     -- outfit shown now (0 = equipped gear)
  picked    TINYINT UNSIGNED NOT NULL DEFAULT 0,     -- outfit the player chose
  free_used TINYINT UNSIGNED NOT NULL DEFAULT 0      -- the character's one free save is spent
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS transmog_outfit (
  guid       INT UNSIGNED NOT NULL,
  id         TINYINT UNSIGNED NOT NULL,              -- 1..50
  name       VARCHAR(24) NOT NULL DEFAULT '',
  icon       INT UNSIGNED NOT NULL DEFAULT 0,        -- item entry whose icon it shows
  situations INT UNSIGNED NOT NULL DEFAULT 0,        -- Transmog::Situation bits
  PRIMARY KEY (guid, id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS transmog_outfit_slot (
  guid      INT UNSIGNED NOT NULL,
  id        TINYINT UNSIGNED NOT NULL,
  slot      TINYINT UNSIGNED NOT NULL,               -- equipment slot 0-18
  look      INT NOT NULL DEFAULT 0,                  -- item entry; -1 hidden
  illusion  INT UNSIGNED NOT NULL DEFAULT 0,
  PRIMARY KEY (guid, id, slot)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS transmog_customset (
  account   INT UNSIGNED NOT NULL,
  id        INT UNSIGNED NOT NULL,
  name      VARCHAR(24) NOT NULL DEFAULT '',
  looks     VARCHAR(600) NOT NULL DEFAULT '',        -- slot:look:illusion/slot:look:illusion...
  PRIMARY KEY (account, id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
