-- classicplus_herald.sql: Herald's "Greenwood" outfit, a Robin Hood-style set of ordinary low-level Hunter
-- items, for the character named Herald on a registered bot account and nobody else (www/herald.html,
-- docs/HERALD.md). PENDING: needs the go-ahead before it touches a live realm.
--
-- Why this file does not INSERT the items itself:
--   Items live in item_instance (+ mail / mail_items or character_inventory) and need fresh item guids. The
--   world server hands out item guids from its own counter while it runs, so rows written behind its back can
--   collide with items it creates later, and a running server never sees them anyway. The safe path is the
--   server's own GM command, `.send items` (SOAP or the server console), which makes real items and mails them.
--   In 1.12 a mail carries one item, so the outfit is 11 commands.
--   This file therefore (1) registers the bot account, and (2) PRINTS the `.send items` commands, and only for
--   items Herald doesn't already have. Running it twice after the items arrived prints nothing: idempotent.
--
-- Run (the same way as the other files here; nothing in classicmangos is changed):
--   1. Set @herald_account below to the game account Herald plays on (the owbot / Herald Lite bot account).
--   2. mariadb -uroot -N < classicplus_herald.sql > herald_send.txt
--   3. Read herald_send.txt. If it lists commands, send each line over SOAP or paste it into the world
--      server console (needs GM level 3). If it's empty: Herald already has everything, or the checks failed
--      (no character named Herald, more than one, or not on the registered bot account). Nothing is sent then.
--
-- Undo: the items are ordinary items; delete them from Herald in game (or `.send` nothing). To unregister the
-- bot account: DELETE FROM classiccharacters.openvanilla_bot_account WHERE label = 'herald';
-- To drop the registry entirely: DROP TABLE classiccharacters.openvanilla_bot_account;

SET @herald_account := 'CHANGE_ME';   -- the bot's game account name (realmd account.username)

-- (1) The bot-account registry: one row per account that Open Vanilla runs as a bot. It is the server-side "this
-- is a bot" flag that later features read (a visible bot tag in game, opt-in for community realms).
CREATE TABLE IF NOT EXISTS classiccharacters.openvanilla_bot_account (
  account INT UNSIGNED NOT NULL PRIMARY KEY COMMENT 'classicrealmd.account.id',
  label   VARCHAR(32)  NOT NULL DEFAULT '' COMMENT 'which bot: herald, herald-lite, fleet-01 ...',
  note    VARCHAR(255) NOT NULL DEFAULT '',
  added   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8 COMMENT='Open Vanilla: accounts flagged as bots (Herald)';

INSERT IGNORE INTO classiccharacters.openvanilla_bot_account (account, label, note)
SELECT a.id, 'herald', 'Herald: Open Vanilla test bot (owbot / Herald Lite). docs/HERALD.md'
FROM classicrealmd.account a
WHERE a.username = UPPER(@herald_account);

-- (2) The outfit, and the commands to send whatever Herald doesn't have yet.
--   entry  name                         slot     display  quality  req. level
--   2579   Green Linen Shirt            shirt    12864    white    0
--   4907   Woodland Tunic               chest    8701     white    0
--   4689   Hunting Cloak                back     23041    white    8
--   4690   Hunting Belt                 waist    14533    white    8
--   2303   Handstitched Leather Pants   legs     9500     white    5
--   2975   Hunting Boots                feet     14534    white    9
--   3207   Hunting Bracers              wrists   14535    white    9
--   5394   Archery Training Gloves      hands    7823     white    0
--   2506   Hornwood Recurve Bow         ranged   20722    white    3
--   7278   Light Leather Quiver         bag      21330    white    1   (8-slot quiver)
--   2512   Rough Arrow x200             ammo     5996     white    1   (re-sent only when he has none left)
-- All are white items with no class or race limit, ilvl 5-14: what a level 1-10 Hunter could wear anyway.
-- Items above his level wait in his bags until he can equip them.
SELECT CONCAT('.send items ', c.name, ' "The Greenwood set" "', o.note, '" ', o.entry, ':', o.cnt) AS command
FROM (
  SELECT 1 AS n, 2579 AS entry, 1 AS cnt, 'A shirt for the ranger of Open Vanilla.' AS note
  UNION ALL SELECT 2, 4907, 1, 'Woodland green, for the road.'
  UNION ALL SELECT 3, 4689, 1, 'A hunter''s cloak, for the night watch.'
  UNION ALL SELECT 4, 4690, 1, 'A hunter''s belt.'
  UNION ALL SELECT 5, 2303, 1, 'Leather breeches, handstitched.'
  UNION ALL SELECT 6, 2975, 1, 'Boots for long kites.'
  UNION ALL SELECT 7, 3207, 1, 'Bracers for the bowstring.'
  UNION ALL SELECT 8, 5394, 1, 'Archery gloves.'
  UNION ALL SELECT 9, 2506, 1, 'A recurve bow of hornwood.'
  UNION ALL SELECT 10, 7278, 1, 'A quiver for your arrows.'
  UNION ALL SELECT 11, 2512, 200, 'Arrows, fletched.'
) o
JOIN classiccharacters.characters c ON c.name = 'Herald' AND c.class = 3
JOIN classiccharacters.openvanilla_bot_account b ON b.account = c.account AND b.label = 'herald'
WHERE (SELECT COUNT(*) FROM classiccharacters.characters h WHERE h.name = 'Herald') = 1
  AND NOT EXISTS (SELECT 1 FROM classiccharacters.item_instance i WHERE i.owner_guid = c.guid AND i.itemEntry = o.entry)
  AND NOT EXISTS (SELECT 1 FROM classiccharacters.mail_items m WHERE m.receiver = c.guid AND m.item_template = o.entry)
ORDER BY o.n;
