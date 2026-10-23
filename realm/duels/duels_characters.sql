-- Open Vanilla Duels (hetzner/duels_up.sh): the characters database's results log, written by the world
-- server (realm/mangos/0021-openvanilla-duels.patch) when a match ends. The website's ladder and feed are
-- made from it and from warfront_arena_rating. Safe to run again.
CREATE TABLE IF NOT EXISTS warfront_arena_result (
  id INT UNSIGNED NOT NULL AUTO_INCREMENT,
  mode VARCHAR(4) NOT NULL,
  ended INT UNSIGNED NOT NULL,
  seconds INT UNSIGNED NOT NULL DEFAULT 0,
  winner TINYINT NOT NULL,                 -- 0 or 1 (a side), 2 a draw
  score0 TINYINT UNSIGNED NOT NULL DEFAULT 0,
  score1 TINYINT UNSIGNED NOT NULL DEFAULT 0,
  team0 VARCHAR(255) NOT NULL DEFAULT '',  -- name:class:guid[:left];...
  team1 VARCHAR(255) NOT NULL DEFAULT '',
  delta0 INT NOT NULL DEFAULT 0,
  delta1 INT NOT NULL DEFAULT 0,
  rated TINYINT UNSIGNED NOT NULL DEFAULT 0,
  PRIMARY KEY (id),
  KEY ended (ended)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

-- 0024 (realm/mangos/0024-openvanilla-duels-arena.patch): the duel ladder on Glicko-2. The shown rating
-- stays `rating`; the deviation and volatility sit next to it (warfront_characters.sql made the table).
ALTER TABLE warfront_arena_rating
  ADD COLUMN IF NOT EXISTS rd FLOAT NOT NULL DEFAULT 350,
  ADD COLUMN IF NOT EXISTS vol FLOAT NOT NULL DEFAULT 0.06;

-- Duel Points (earned only, never sold, cosmetic only), win streaks, and whether the hangout queues
-- the duelist by itself (`.wnl wf q auto on|off`).
CREATE TABLE IF NOT EXISTS duels_player (
  guid INT UNSIGNED NOT NULL,
  points INT UNSIGNED NOT NULL DEFAULT 0,
  streak INT UNSIGNED NOT NULL DEFAULT 0,
  best_streak INT UNSIGNED NOT NULL DEFAULT 0,
  wins INT UNSIGNED NOT NULL DEFAULT 0,
  losses INT UNSIGNED NOT NULL DEFAULT 0,
  auto_queue TINYINT UNSIGNED NOT NULL DEFAULT 1,
  PRIMARY KEY (guid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

-- The fights going on now, every 15 s (the website's "Fights now", and spectating):
-- <id>,<mode>,<phase>,<round>,<score0>,<score1>,<name:class:rating>,<name:class:rating>,<watchers>;...
CREATE TABLE IF NOT EXISTS duels_now (
  id TINYINT UNSIGNED NOT NULL,
  body TEXT NOT NULL,
  updated INT UNSIGNED NOT NULL DEFAULT 0,
  PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

-- 0025: the class spells were put on the character's bars once (never again, so a cleared button stays clear)
ALTER TABLE duels_player ADD COLUMN IF NOT EXISTS bars TINYINT UNSIGNED NOT NULL DEFAULT 0;

-- The hangout moved from the Lion's Pride Inn to Gurubashi Arena (2026-10-22): characters bound at the inn
-- are bound at the arena (the hangout's fence brings them there on login anyway). Re-runnable.
UPDATE `character_homebind` SET `map` = 0, `zone` = 33, `position_x` = -13217.9, `position_y` = 276.76, `position_z` = 22.4
  WHERE `map` = 0 AND `zone` = 12;

-- Betting (realm/mangos/0027-openvanilla-duels-betting.patch): Duel Gold wallets by account, and every
-- settled bet. Re-runnable.
CREATE TABLE IF NOT EXISTS `duels_wallet` (
  `account`   INT UNSIGNED NOT NULL,
  `gold`      INT UNSIGNED NOT NULL DEFAULT 100,
  `day`       INT UNSIGNED NOT NULL DEFAULT 0,          -- days since 1970: the day bet_today counts
  `bet_today` INT UNSIGNED NOT NULL DEFAULT 0,
  PRIMARY KEY (`account`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;
CREATE TABLE IF NOT EXISTS `duels_bet` (
  `id`       INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `ended`    INT UNSIGNED NOT NULL,
  `match_id` INT UNSIGNED NOT NULL,
  `account`  INT UNSIGNED NOT NULL,
  `side`     TINYINT UNSIGNED NOT NULL,
  `amount`   INT UNSIGNED NOT NULL,
  `paid`     INT UNSIGNED NOT NULL,
  PRIMARY KEY (`id`),
  KEY `account` (`account`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

-- patch 0033: the practice bots, one character per class on the bot AI's own accounts, made when first needed
CREATE TABLE IF NOT EXISTS `duels_practice_bot` (
  `guid` INT UNSIGNED NOT NULL,
  `class` TINYINT UNSIGNED NOT NULL,
  `prepared` TINYINT UNSIGNED NOT NULL DEFAULT 0,
  PRIMARY KEY (`guid`),
  KEY `class` (`class`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

-- patch 0034: the specs (three on Duels, one per talent tree) and their own action bars, as on the
-- leveling realm (realm/classicplus/classicplus_characters.sql)
CREATE TABLE IF NOT EXISTS `openvanilla_character` (
  `guid` INT UNSIGNED NOT NULL PRIMARY KEY,
  `active_spec` TINYINT UNSIGNED NOT NULL DEFAULT 1,
  `starter_pet` TINYINT UNSIGNED NOT NULL DEFAULT 0
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS `openvanilla_spec` (
  `guid` INT UNSIGNED NOT NULL,
  `spec` TINYINT UNSIGNED NOT NULL,
  `name` VARCHAR(32) NOT NULL DEFAULT '',
  `talents` TEXT NOT NULL,
  PRIMARY KEY (`guid`, `spec`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS `openvanilla_spec_action` (
  `guid` INT UNSIGNED NOT NULL,
  `spec` TINYINT UNSIGNED NOT NULL,
  `button` TINYINT UNSIGNED NOT NULL,
  `action` INT UNSIGNED NOT NULL,
  `type` TINYINT UNSIGNED NOT NULL,
  PRIMARY KEY (`guid`, `spec`, `button`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- patch 0035: the hangout's own player bots, one per class, logged in while the realm runs
CREATE TABLE IF NOT EXISTS `duels_hub_bot` (
  `slot` TINYINT UNSIGNED NOT NULL,
  `guid` INT UNSIGNED NOT NULL,
  `class` TINYINT UNSIGNED NOT NULL,
  `prepared` TINYINT UNSIGNED NOT NULL DEFAULT 0,
  PRIMARY KEY (`slot`),
  KEY `guid` (`guid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

-- The bug reports and the World chat log, as on the leveling realm (the world server writes both; without
-- them it logs ERROR 1146 every time). From realm/classicplus/classicplus_bugs.sql and classicplus_world.sql.
-- Open Vanilla: bug reports from the game (realm/mangos/0014-openvanilla-bug-reports.patch writes them,
-- Herald's bot/herald_bugs.py posts them to the Discord #bug-reports forum). Run against classicmangos
-- (the table lives in classiccharacters); safe to run twice. Undo:
--   DROP TABLE openvanilla_bug_report;   (loses the reports)
CREATE TABLE IF NOT EXISTS openvanilla_bug_report (
  id         INT UNSIGNED NOT NULL AUTO_INCREMENT,
  created    INT UNSIGNED NOT NULL,
  account    INT UNSIGNED NOT NULL,
  guid       INT UNSIGNED NOT NULL,
  name       VARCHAR(12)  NOT NULL,
  level      TINYINT UNSIGNED NOT NULL,
  class      TINYINT UNSIGNED NOT NULL,
  race       TINYINT UNSIGNED NOT NULL,
  map        SMALLINT UNSIGNED NOT NULL,
  zone       INT UNSIGNED NOT NULL,
  area       INT UNSIGNED NOT NULL,
  x          FLOAT NOT NULL,
  y          FLOAT NOT NULL,
  z          FLOAT NOT NULL,
  category   VARCHAR(16)  NOT NULL,
  text       VARCHAR(1000) NOT NULL,
  context    VARCHAR(600) NOT NULL DEFAULT '',
  posted     TINYINT UNSIGNED NOT NULL DEFAULT 0,
  discord_id BIGINT UNSIGNED NOT NULL DEFAULT 0,
  PRIMARY KEY (id),
  KEY posted (posted, id),
  KEY account (account, created)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Open Vanilla: the World channel and the Discord bridge (world server patch
-- realm/mangos/0007-openvanilla-world-channel.patch, Herald's bot/herald_bridge.py, docs/DISCORD_BRIDGE.md).
-- Run against classicmangos like the other files here; every table lives in 
-- Safe to run twice. Undo:
--   DROP TABLE openvanilla_world_log, openvanilla_world_pref,
--              openvanilla_guild_bridge, openvanilla_guild_link_code;

-- Every World line (and every line of a guild linked to Discord), newest 1,000 kept: the world server
-- trims the ring every 10 inserts (at most 1,009 rows). guid 0 = a line that came from Discord (Herald skips those).
-- class = the character's class id (1 Warrior .. 11 Druid; 0 for Discord); guild 0 = World.
CREATE TABLE IF NOT EXISTS openvanilla_world_log (
    id       INT UNSIGNED NOT NULL AUTO_INCREMENT,
    guid     INT UNSIGNED NOT NULL DEFAULT 0,
    name     VARCHAR(32)  NOT NULL DEFAULT '',
    class    TINYINT UNSIGNED NOT NULL DEFAULT 0,
    guild    INT UNSIGNED NOT NULL DEFAULT 0,
    text     VARCHAR(255) NOT NULL DEFAULT '',
    created  INT UNSIGNED NOT NULL DEFAULT 0,
    PRIMARY KEY (id),
    KEY idx_guild (guild, id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ".wnl worldoff": the character stays out of World across logins (row deleted by ".wnl worldon").
CREATE TABLE IF NOT EXISTS openvanilla_world_pref (
    guid  INT UNSIGNED NOT NULL,
    off   TINYINT UNSIGNED NOT NULL DEFAULT 1,
    PRIMARY KEY (guid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Guilds whose chat is linked to a Discord channel. Herald writes it (after the officer's in-game
-- confirmation below); the world server re-reads the guild ids once a minute and logs those guilds' chat.
CREATE TABLE IF NOT EXISTS openvanilla_guild_bridge (
    guildid          INT UNSIGNED NOT NULL,
    discord_channel  BIGINT UNSIGNED NOT NULL,
    linked_by        VARCHAR(64) NOT NULL DEFAULT '',
    created          INT UNSIGNED NOT NULL DEFAULT 0,
    PRIMARY KEY (guildid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ".wnl guildlink <code>" by a guild master or officer (rank 0/1) in game; Herald matches the code it
-- gave on Discord ("/guild discord #channel"), writes openvanilla_guild_bridge and deletes the row.
CREATE TABLE IF NOT EXISTS openvanilla_guild_link_code (
    code     CHAR(6) NOT NULL,
    guildid  INT UNSIGNED NOT NULL,
    guid     INT UNSIGNED NOT NULL,
    name     VARCHAR(12) NOT NULL DEFAULT '',
    created  INT UNSIGNED NOT NULL DEFAULT 0,
    PRIMARY KEY (code)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
