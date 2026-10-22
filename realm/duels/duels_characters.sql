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
