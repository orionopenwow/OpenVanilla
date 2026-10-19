-- Warfront: tables in the CHARACTERS database (run on the Warfront characters database only).
-- Re-runnable.
CREATE TABLE IF NOT EXISTS `warfront_character` (
  `guid` int unsigned NOT NULL,
  `welcomed` tinyint unsigned NOT NULL DEFAULT 1,
  `created` int unsigned NOT NULL DEFAULT 0,
  PRIMARY KEY (`guid`)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS `warfront_account` (
  `account` int unsigned NOT NULL,
  `best_rating` int unsigned NOT NULL DEFAULT 0,
  `max_kills` int unsigned NOT NULL DEFAULT 0,
  `gifted` tinyint unsigned NOT NULL DEFAULT 0,  -- the account's one-time welcome gold and supplies
  PRIMARY KEY (`account`)
) ENGINE=InnoDB;
ALTER TABLE `warfront_account` ADD COLUMN IF NOT EXISTS `gifted` tinyint unsigned NOT NULL DEFAULT 0;

CREATE TABLE IF NOT EXISTS `warfront_shared_set` (
  `id` int unsigned NOT NULL AUTO_INCREMENT,
  `owner_guid` int unsigned NOT NULL,
  `owner_name` varchar(12) NOT NULL,
  `account` int unsigned NOT NULL,
  `class` tinyint unsigned NOT NULL,
  `spec` varchar(24) NOT NULL,
  `name` varchar(24) NOT NULL,
  `items` varchar(400) NOT NULL,
  `votes` int unsigned NOT NULL DEFAULT 0,
  `reports` int unsigned NOT NULL DEFAULT 0,
  `hidden` tinyint unsigned NOT NULL DEFAULT 0,
  `created` int unsigned NOT NULL DEFAULT 0,
  PRIMARY KEY (`id`),
  KEY `by_class` (`class`, `hidden`, `votes`),
  KEY `by_account` (`account`)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS `warfront_set_vote` (
  `set_id` int unsigned NOT NULL,
  `account` int unsigned NOT NULL,
  PRIMARY KEY (`set_id`, `account`)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS `warfront_set_report` (
  `set_id` int unsigned NOT NULL,
  `account` int unsigned NOT NULL,
  PRIMARY KEY (`set_id`, `account`)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS `warfront_arena_rating` (
  `guid` int unsigned NOT NULL,
  `bracket` tinyint unsigned NOT NULL,           -- 2 = 2v2, 3 = 3v3, 4 = 1v1 duel ladder (WarfrontArena.cpp modes)
  `rating` int unsigned NOT NULL DEFAULT 1500,
  `best` int unsigned NOT NULL DEFAULT 1500,
  `wins` int unsigned NOT NULL DEFAULT 0,
  `losses` int unsigned NOT NULL DEFAULT 0,
  PRIMARY KEY (`guid`, `bracket`),
  KEY `ladder` (`bracket`, `rating`)
) ENGINE=InnoDB;

-- One row: the live counts mangosd writes every 15 seconds (Warfront.h, WC line): players queued per
-- arena mode (s2,s3,r2,r3,d1), arena matches, real players in battleground queues and in battles,
-- realm bots in battles. The site and Herald read it; `updated` is a unix time, stale = realm down.
CREATE TABLE IF NOT EXISTS warfront_live (
  id TINYINT UNSIGNED NOT NULL PRIMARY KEY,
  line VARCHAR(120) NOT NULL DEFAULT '',
  updated INT UNSIGNED NOT NULL DEFAULT 0
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
