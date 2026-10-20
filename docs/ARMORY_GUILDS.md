# Armory: guild files

The guild pages of the website (`www/guilds.html` and `www/guild.html?r=<realm>&g=<guild>`) read static
JSON that the armory exporter (`tools/armory_export.py`, cron on the realm server every 10 min, see
`docs/ARMORY.md`) writes next to the character files. This document is the contract between the two:
the exporter writes exactly these shapes; the pages show "No armory data yet" when a file is missing
and ignore any key they do not know.

Everything here is public information. Never export: the message of the day, officer notes, public
notes, guild bank/DKP data (those live only in the in-game Guild Hub addon), account data, IPs.

## Files

| Path | What |
|---|---|
| `www/armory/guilds.json` | the index: every realm and its guilds (one small row each) |
| `www/armory/<realm>/guilds/<slug>.json` | one guild |

`<realm>` is the realm's directory name, the same one the character files use
(`www/armory/<realm>/<name>.json`). `<slug>` is the guild's slug (below).

### Slugs

Lowercase the name; every run of characters other than `a-z` and `0-9` becomes one `-`; strip `-`
from both ends. `"Ashen Vanguard"` -> `ashen-vanguard`, `"<Knights of Ni!>"` -> `knights-of-ni`.
Two guilds that collapse to the same slug on one realm: the older guild (lower guild id) keeps the
slug, the other gets `-<guildid>` appended. Realm directories follow the same rule.

## `www/armory/guilds.json`

```json
{
  "schema": 1,
  "generated": "2026-10-15T12:00:00Z",
  "realms": [
    {
      "realm": "classicplus",
      "name": "Open Vanilla Classic+",
      "guilds": [
        {
          "slug": "ashen-vanguard",
          "name": "Ashen Vanguard",
          "faction": "Alliance",
          "leader": "Aldric",
          "members": 38,
          "level60": 21,
          "achievementPoints": 4820,
          "created": "2026-03-02"
        }
      ]
    }
  ]
}
```

- `realms[].realm` is the directory name; `name` is the realm's display name.
- `guilds` is sorted by `members` descending, then `name`.
- `leader` is omitted (not null) when the guild master's armory setting is `hidden`.
- `members` counts every member, including hidden ones.

## `www/armory/<realm>/guilds/<slug>.json`

```json
{
  "schema": 1,
  "generated": "2026-10-15T12:00:00Z",
  "realm": "classicplus",
  "realmName": "Open Vanilla Classic+",
  "name": "Ashen Vanguard",
  "slug": "ashen-vanguard",
  "faction": "Alliance",
  "created": "2026-03-02",
  "leader": "Aldric",
  "info": "Raids MC/BWL Tue and Thu 20:00 server time. Casual levelling friendly.",
  "ranks": [
    { "index": 0, "name": "Guild Master" },
    { "index": 1, "name": "Officer" },
    { "index": 2, "name": "Veteran" },
    { "index": 3, "name": "Member" },
    { "index": 4, "name": "Initiate" }
  ],
  "members": [
    {
      "name": "Aldric",
      "level": 60,
      "class": "WARRIOR",
      "race": "Human",
      "rank": 0,
      "rankName": "Guild Master",
      "online": false,
      "lastSeen": "2026-10-14T21:40:00Z",
      "achievementPoints": 610,
      "professions": [
        { "name": "Blacksmithing", "skill": 300 },
        { "name": "Mining", "skill": 285 }
      ]
    },
    {
      "name": "Berra",
      "level": 41,
      "class": "HUNTER",
      "rank": 4,
      "rankName": "Initiate",
      "limited": true
    }
  ],
  "totals": {
    "members": 38,
    "listed": 36,
    "private": 2,
    "level60": 21,
    "averageLevel": 47.3,
    "achievementPoints": 4820,
    "classes": { "WARRIOR": 6, "PRIEST": 5, "MAGE": 7 },
    "professions": { "Alchemy": 4, "Blacksmithing": 3, "Enchanting": 5 }
  },
  "recentAchievements": [
    {
      "id": 412,
      "name": "Molten Core",
      "icon": "INV_Misc_Head_Dragon_01",
      "points": 25,
      "member": "Aldric",
      "date": "2026-10-12"
    }
  ]
}
```

### Fields

| Key | Type | Notes |
|---|---|---|
| `schema` | int | `1`. A breaking change bumps it; the pages refuse other numbers with "unsupported armory data". |
| `generated` | string | ISO 8601 UTC time of the export. |
| `realm`, `realmName` | string | directory name and display name of the realm. |
| `name`, `slug` | string | the guild's name and slug. |
| `faction` | string | `"Alliance"` or `"Horde"` (from the guild master's race). |
| `created` | string | `YYYY-MM-DD` (`guild.createdate`); omitted when unknown. |
| `leader` | string | the guild master's name; omitted when that character is `hidden`. |
| `info` | string | the public **Guild Information** text (`guild.info`), max 500 chars. **Not** the MOTD (`guild.motd`), which is members-only. Omitted when empty. |
| `ranks` | array | `{ index, name }` for every rank, `index` 0 = guild master. |
| `members` | array | sorted by `rank`, then `level` descending, then `name`. |
| `totals` | object | see below. |
| `recentAchievements` | array | the 10 most recent achievements earned by `public` members, newest first. |

### Members and privacy

Each character's armory setting (`classiccharacters.openvanilla_character.armory`, see `docs/ARMORY.md`)
decides what the guild file shows about them:

| Setting | In `members` |
|---|---|
| `public` | everything: `name, level, class, race, rank, rankName, online, lastSeen, achievementPoints, professions` |
| `friends` | only `name, level, class, rank, rankName` plus `"limited": true` |
| `hidden` | not listed at all; counted in `totals.members` and `totals.private` |

Member fields:

- `class`: the upper-case class token (`WARRIOR`, `PALADIN`, `HUNTER`, `ROGUE`, `PRIEST`, `SHAMAN`,
  `MAGE`, `WARLOCK`, `DRUID`) so the page can colour names the way the game does.
- `race`: the display name (`"Night Elf"`).
- `rank` / `rankName`: index into `ranks` and its name.
- `online`: true when the character was online at export time.
- `lastSeen`: ISO 8601 UTC of the last logout (`characters.logout_time`); omitted while `online`.
- `achievementPoints`: int, 0 when none.
- `professions`: primary and secondary professions with skill (Alchemy, Blacksmithing, Enchanting,
  Engineering, Herbalism, Leatherworking, Mining, Skinning, Tailoring, Cooking, First Aid,
  Fishing), highest skill first; `[]` when none.

### Totals

| Key | Notes |
|---|---|
| `members` | every member, hidden ones included |
| `listed` | entries in `members` |
| `private` | hidden members (not listed) |
| `level60` | members at level 60, hidden ones included |
| `averageLevel` | over every member, one decimal |
| `achievementPoints` | sum over `public` members |
| `classes` | class token -> count over every member (counts reveal no names) |
| `professions` | profession -> number of `public` members who have it |

## Page behaviour (for reference)

- `guilds.html` fetches `armory/guilds.json`; a 404 or invalid JSON shows "No armory data yet".
  It lists guilds per realm with search, faction and realm filters, linking to
  `guild.html?r=<realm>&g=<slug>`.
- `guild.html` validates `r` and `g` against `^[a-z0-9-]{1,64}$`, fetches
  `armory/<r>/guilds/<g>.json`, and shows the header, totals, class bars, roster (search, rank and
  class filters, sort), professions and recent achievements. Member names link to
  `armory/character.html?r=<realm>&n=<name>` unless `limited`.
- All text from the JSON is written with `textContent`; nothing is treated as HTML.
