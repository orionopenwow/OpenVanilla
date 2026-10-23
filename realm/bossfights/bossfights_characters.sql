-- Open Vanilla Boss Fights (hetzner/bossfights_up.sh): the characters database's tables, written by the world
-- server (realm/mangos/0050-openvanilla-bossfights.patch). Safe to run again.

-- Each character: in Boss Fights or in Duels (one hangout, two modes), the raid its window opens on, its role.
CREATE TABLE IF NOT EXISTS bossfights_player (
  guid INT UNSIGNED NOT NULL,
  mode TINYINT UNSIGNED NOT NULL DEFAULT 0,
  lobby VARCHAR(8) NOT NULL DEFAULT '',          -- the raid last picked (onyxia, mc, ...)
  role TINYINT UNSIGNED NOT NULL DEFAULT 0,      -- 0 dps, 1 tank, 2 healer
  PRIMARY KEY (guid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

-- The mode an account's next new character starts in (".wnl wf bf mode boss|duels", sent by the Boss Fights
-- addon when the site's link said Boss Fights): 1 opens that character in Boss Fights at its first login, once.
CREATE TABLE IF NOT EXISTS bossfights_account (
  account INT UNSIGNED NOT NULL,
  pending TINYINT UNSIGNED NOT NULL DEFAULT 0,
  set_at INT UNSIGNED NOT NULL DEFAULT 0,
  PRIMARY KEY (account)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

-- Tier unlocks, per account and raid: tier N+1 opens after a clear of tier N. The tier aura and Warfront's
-- armory tier come from the best tier cleared in any raid.
CREATE TABLE IF NOT EXISTS bossfights_progress (
  account INT UNSIGNED NOT NULL,
  raid VARCHAR(8) NOT NULL,
  best_tier TINYINT UNSIGNED NOT NULL DEFAULT 0,
  best_ms INT UNSIGNED NOT NULL DEFAULT 0,       -- the fastest clear at best_tier (from the first pull)
  PRIMARY KEY (account, raid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

-- Every finished run (cleared or not): the website's scoreboard and the in-game board.
CREATE TABLE IF NOT EXISTS bossfights_result (
  id INT UNSIGNED NOT NULL AUTO_INCREMENT,
  raid VARCHAR(8) NOT NULL,
  tier TINYINT UNSIGNED NOT NULL,
  size TINYINT UNSIGNED NOT NULL,
  bots TINYINT UNSIGNED NOT NULL DEFAULT 0,      -- playerbots in the run: runs with bots rank on their own board
  affixes INT UNSIGNED NOT NULL DEFAULT 0,       -- 1 fortified, 2 tyrannical, 4 enrage
  ended INT UNSIGNED NOT NULL,
  length_ms INT UNSIGNED NOT NULL DEFAULT 0,     -- first pull to the last boss (0: never pulled)
  cleared TINYINT UNSIGNED NOT NULL DEFAULT 0,
  wipes SMALLINT UNSIGNED NOT NULL DEFAULT 0,
  deaths SMALLINT UNSIGNED NOT NULL DEFAULT 0,
  members TEXT NOT NULL,                         -- name:class:role[:bot],... (the raid group's leader first)
  splits TEXT NOT NULL,                          -- <encounter index>:<ms from the pull>,...
  PRIMARY KEY (id),
  KEY board (raid, tier, cleared, length_ms),
  KEY ended (ended)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;
-- (a table made before the bots column)
ALTER TABLE bossfights_result ADD COLUMN IF NOT EXISTS bots TINYINT UNSIGNED NOT NULL DEFAULT 0 AFTER size;
-- (0051) self-test runs (hetzner/bossfights_check.sh): never on the website or the boards
ALTER TABLE bossfights_result ADD COLUMN IF NOT EXISTS test TINYINT UNSIGNED NOT NULL DEFAULT 0 AFTER bots;

-- The runs going on now (the website's "Raids now"), kept by the world server.
CREATE TABLE IF NOT EXISTS bossfights_now (
  run INT UNSIGNED NOT NULL,
  raid VARCHAR(8) NOT NULL,
  tier TINYINT UNSIGNED NOT NULL,
  size TINYINT UNSIGNED NOT NULL,
  started INT UNSIGNED NOT NULL,
  bosses TINYINT UNSIGNED NOT NULL DEFAULT 0,
  encounters TINYINT UNSIGNED NOT NULL DEFAULT 0,
  PRIMARY KEY (run)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;
-- (the world server starts with an empty table: a restart ends every run)

-- The ready raider (realm/mangos/0052-openvanilla-bossfights-ready.patch): what Boss Fights set up for a character,
-- so it never overrides the player's own choice later. spec/talents: the spec it made active and the talents it
-- spent (changed since: the player's own). kit: the gear set it put on. bars: it laid out the action bars once.
CREATE TABLE IF NOT EXISTS bossfights_ready (
  guid INT UNSIGNED NOT NULL,
  spec TINYINT UNSIGNED NOT NULL DEFAULT 0,
  talents TEXT NOT NULL,                         -- talentId:rank,... (as Boss Fights left them)
  kit VARCHAR(64) NOT NULL DEFAULT '',
  bars TINYINT UNSIGNED NOT NULL DEFAULT 0,
  readied INT UNSIGNED NOT NULL DEFAULT 0,       -- when it was first made ready
  PRIMARY KEY (guid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

-- Bot fill (realm/mangos/0054-openvanilla-bossfights-bot-fill.patch): the bots that fill raids, kept between runs.
-- Characters on the bot AI's own accounts (RNDBOT*), made the first time a role, class and faction is needed,
-- logged in only while a ticket or a run wants them. prepared: the bot factory's gear and spells done once.
CREATE TABLE IF NOT EXISTS bossfights_fill_bot (
  guid INT UNSIGNED NOT NULL,
  class TINYINT UNSIGNED NOT NULL,
  role TINYINT UNSIGNED NOT NULL,                -- 0 damage, 1 tank, 2 healer
  team TINYINT UNSIGNED NOT NULL,                -- 0 Alliance, 1 Horde
  prepared TINYINT UNSIGNED NOT NULL DEFAULT 0,
  used INT UNSIGNED NOT NULL DEFAULT 0,          -- last time in a raid (the least used is picked first)
  PRIMARY KEY (guid),
  KEY pick (role, class, team, used)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;
