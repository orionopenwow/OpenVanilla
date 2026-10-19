# Armory

The armory shows every realm's characters and guilds on the website, from static JSON. Nothing on
the site queries a database: the realm server exports files every ten minutes and the pages read them.

| Piece | Where |
|---|---|
| Exporter | `tools/armory_export.py` (cron: `hetzner/armory_cron.sh`, timer `hetzner/systemd/openvanilla-armory.timer`) |
| Pages | `www/armory.html` (search, realms, rankings), `www/armory/character.html?r=<realm>&n=<name>[&k=<key>]`, `www/guilds.html`, `www/guild.html` |
| Privacy setting | `classiccharacters.openvanilla_character.armory` / `armory_key` (`realm/classicplus/pending/classicplus_armory.sql`) |
| In game | Social's settings: "Armory: Public / Friends only / Hidden" → `.wnl armory <mode>` (`realm/mangos/pending/0008-openvanilla-armory.patch`) |
| Community realms | the host agent exports its own realm hourly (opt-in) and uploads it: `POST /api/armory/upload` (`realm/patches/pending/0014-openvanilla-armory-upload.patch`) |
| Guild files | `docs/ARMORY_GUILDS.md` (the exporter follows it exactly) |
| Art | `tools/gen_armory_art.py` → `www/assets/armory/` |

## Privacy

Every character is **public** unless its player changes it in game (Social → settings → Armory):

| Setting | Character file | Search, rankings, realm firsts | Guild pages |
|---|---|---|---|
| `public` (default) | `<realm>/<name>.json` | listed | everything |
| `friends` | only `<realm>/<name>~<key>.json`; the link with `&k=<key>` is shown in game to copy | not listed (a realm first says "a private player") | name, level, class, rank, `"limited": true` |
| `hidden` | none | not listed | not listed; counted in `totals.members` / `totals.private` |

The key is 20 characters `a-z0-9`, made by the world server the first time a character picks
friends-only; "New link" in game (`.wnl armory newlink`) replaces it, which retires the old link at the
next export (the old file is deleted). A friends-only setting without a valid key publishes nothing.
The server must not list directories under `/armory/` (GitHub Pages and R2 never do; Caddy only with
`file_server browse`, which the realm does not use). The daily snapshot (`--torrent`) leaves every
friends-only file out.

Never exported: account data, IPs, mail, bags and bank, money, chat, the guild MOTD, officer and public
notes, guild bank/DKP, playerbot characters (accounts named `RNDBOT…`, `--skip-accounts`), deleted characters.

## Files

All files are UTF-8 JSON with `"schema": 1`; a breaking change bumps it and the pages refuse other
numbers. `generated` is the ISO 8601 UTC time the content last changed (a file is not rewritten
when only the time would differ). Pages write every value with `textContent`, never as HTML.

| Path | What |
|---|---|
| `armory/index.json` | every realm in the folder |
| `armory/guilds.json` | every realm's guilds (`docs/ARMORY_GUILDS.md`) |
| `armory/<realm>/index.json` | one realm: its public characters and its guild rows |
| `armory/<realm>/rankings.json` | top 100 by level, achievement points, honorable kills, and per profession |
| `armory/<realm>/firsts.json` | realm-first achievements (only when the achievement tables exist) |
| `armory/<realm>/<name>.json` | one public character; `<name>` is the name in lower case |
| `armory/<realm>/<name>~<key>.json` | one friends-only character |
| `armory/<realm>/guilds/<slug>.json` | one guild (`docs/ARMORY_GUILDS.md`) |

`<realm>` is the realm's folder name (`--realm`, default: the realmlist name as a slug, rule in
`docs/ARMORY_GUILDS.md`); community realms use their 16-character directory host id.

### `armory/index.json`

```json
{ "schema": 1, "generated": "2026-10-15T12:00:00Z",
  "realms": [
    { "realm": "classicplus", "name": "Open Vanilla Classic+", "community": false, "aliases": ["vanilla-reloaded"],
      "characters": 812, "guilds": 41, "updated": "2026-10-15T12:00:00Z" },
    { "realm": "k2v7q3x9m4n8p5r6", "name": "Stormwind Nights", "community": true,
      "characters": 37, "guilds": 3, "updated": "2026-10-15T11:02:11Z" } ] }
```

`aliases` are other slugs that mean this realm (the realm's display name as a slug): the game builds a
friends-only link from the realm name it shows, and the character page follows an alias to the realm.

### `armory/<realm>/index.json`

```json
{ "schema": 1, "generated": "…", "realm": "classicplus", "name": "Open Vanilla Classic+", "community": false,
  "aliases": ["vanilla-reloaded"],
  "characters": [ { "name": "Aldric", "level": 60, "class": "WARRIOR", "race": "Human", "faction": "Alliance",
                    "guild": "Ashen Vanguard", "guildSlug": "ashen-vanguard" } ],
  "guilds": [ { "slug": "ashen-vanguard", "name": "Ashen Vanguard", "faction": "Alliance", "leader": "Aldric",
                "members": 38, "level60": 21, "achievementPoints": 4820, "created": "2026-03-02" } ] }
```

`characters`: public characters only, sorted by name. `guilds`: the same rows as in `guilds.json`.

### `armory/<realm>/rankings.json`

```json
{ "schema": 1, "generated": "…", "realm": "classicplus", "realmName": "Open Vanilla Classic+",
  "level": [ { "name": "Eira", "level": 60, "class": "WARLOCK", "race": "Undead", "faction": "Horde", "guild": "…" } ],
  "achievementPoints": [ { "name": "Eira", "…": "…", "points": 75 } ],
  "honorableKills": [ { "name": "Aldric", "…": "…", "kills": 1205 } ],
  "professions": { "Mining": [ { "name": "Aldric", "…": "…", "skill": 285 } ] } }
```

Public characters only, 100 per list. Ties: level then points then name; points then name; kills then name.
Honorable kills = `characters.stored_honorable_kills` + this week's kills in `character_honor_cp`.

### `armory/<realm>/firsts.json`

`{ "schema", "generated", "realm", "realmName", "firsts": [ { "id", "name", "points", "icon", "date",
"character", "class" } ] }`, oldest first, from `openvanilla_realm_first`. A first earned by a friends-only or
hidden character has `"private": true` and no `character`/`class`.

### Character file

```json
{
  "schema": 1, "generated": "…", "realm": "classicplus", "realmName": "Open Vanilla Classic+",
  "name": "Aldric", "level": 60, "class": "WARRIOR", "race": "Human", "gender": "male", "faction": "Alliance",
  "privacy": "public", "online": false, "lastSeen": "2026-10-13T21:40:00Z",
  "guild": { "name": "Ashen Vanguard", "slug": "ashen-vanguard", "rank": 0, "rankName": "Guild Master" },
  "honor": { "honorableKills": 1205, "dishonorableKills": 3, "highestRank": 8, "highestRankName": "Knight-Captain" },
  "equipment": [
    { "slot": "head", "slotId": 0, "id": 990901, "name": "Helm of Valor", "quality": 3, "qualityName": "rare",
      "itemLevel": 58, "requiredLevel": 53, "icon": "INV_Helmet_03", "bonding": "Binds when picked up",
      "invType": "Head", "subType": "Plate", "armor": 528,
      "stats": [ { "stat": "Stamina", "value": 15 } ], "resist": { "fire": 10 },
      "damage": { "min": 229, "max": 344, "speed": 3.5, "dps": 81.9, "school": "Fire" },
      "effects": [ { "trigger": "Equip", "text": "Increased Defense" } ],
      "enchant": "+10 Stamina", "suffix": "of the Monkey", "randomStats": ["+7 Agility"],
      "set": { "id": 990, "name": "Battlegear of Valor", "equipped": 2, "pieces": 8 },
      "durability": { "current": 50, "max": 80 }, "description": "…" } ],
  "stats": { "health": 5400, "mana": 0, "strength": 210, "agility": 0, "stamina": 300, "armor": 4100,
             "dodge": 7.5, "crit": 0, "attackPower": 900, "…": "…" },
  "talents": [
    { "index": 1, "name": "Arms", "active": true, "points": [31, 20, 0],
      "trees": [ { "name": "Arms", "icon": "Ability_Rogue_Eviscerate", "points": 31,
                   "talents": [ { "id": 1001, "name": "Improved Heroic Strike", "icon": "…", "row": 0, "col": 0,
                                  "rank": 3, "max": 3 } ] } ] } ],
  "achievements": { "points": 50, "count": 2,
                    "list": [ { "id": 412, "name": "Molten Core", "description": "…", "points": 25,
                                "category": "dungeons", "icon": "INV_Misc_Head_Dragon_01", "date": "2026-10-12" } ] },
  "professions": [ { "name": "Blacksmithing", "skill": 300, "max": 300 } ],
  "reputations": [ { "id": 72, "name": "Stormwind", "value": 12600, "standing": "Honored", "progress": 3600, "max": 12000 } ]
}
```

| Key | Notes |
|---|---|
| `class` | upper-case token (`WARRIOR` … `DRUID`); `race` a display name |
| `privacy` | `public` or `friends` (hidden characters have no file) |
| `lastSeen` | `characters.logout_time`; omitted while `online` |
| `guild` | omitted when guildless |
| `honor.highestRank` | 1–14 (`honor_highest_rank` − 4), only when a rank was reached; `standing` when ranked this week |
| `equipment` | worn items only (`character_inventory` bag 0, slots 0–18), by slot: `head neck shoulder shirt chest waist legs feet wrist hands finger1 finger2 trinket1 trinket2 back mainhand offhand ranged tabard` |
| item `quality` | 0 poor … 6 artifact, `qualityName` its word; `icon` the game's icon name (`ItemDisplayInfo.dbc`), omitted without `--dbc-dir` |
| item `effects` | `spellid_N` + `spelltrigger_N`: `Use`, `Equip`, `Chance on hit`, with the spell's name (`spell_template`) |
| item `enchant` | the permanent enchantment (`item_instance.enchantments` slot 0, `SpellItemEnchantment.dbc`) |
| item `suffix`/`randomStats` | a random-property item ("of the Monkey"); `name` already carries the suffix |
| `stats` | `character_stats` when the server saves it (`PlayerSave.Stats.MinLevel`); omitted otherwise |
| `talents` | one entry per spec: the active one from `character_spell`, the other from `openvanilla_spec.talents` (dual spec); `points` per tree in tree order; needs `Talent.dbc`/`TalentTab.dbc` |
| `achievements` | `character_achievement` × `classicmangos.openvanilla_achievement`, newest first; `featOfStrength: true` for flag 4 |
| `professions` | primary and secondary, highest skill first (`[]` when none) |
| `reputations` | factions shown in the game's reputation pane (flag visible, not hidden/forced invisible), value = `Faction.dbc` base + `character_reputation.standing`, `standing` the level word, `progress`/`max` within the level |

## Item and talent icons

The JSON names icons (`INV_Helmet_03`) but the site ships no game art. The pages look for
`<iconBase>/<icon in lower case>.png`, where `iconBase` is `window.ARMORY_ICON_BASE` or, by default,
`https://play.openvanilla.app/armory-icons` (a folder the realm can fill from its own client data with
`tools/mpq_extract.py` + `tools/png_to_blp.py`'s reverse; not shipped by this change). When an icon does
not load, the slot shows the quality-coloured frame with the item's initial, so pages never break.

## Running it

```
# on the realm server (hetzner/armory_cron.sh install does all of this)
ARMORY_DB_PASSWORD=… python3 tools/armory_export.py --out /opt/openvanilla-herald/public/armory --realm classicplus \
    --realm-name "Open Vanilla Classic+" --dbc-dir /var/lib/openvanilla-armory/dbc --db-port 13306 \
    --community-dir /opt/wenilla-realm/state/armory-uploads
python3 tools/armory_export.py --out … --dry-run -v      # what would change; writes nothing
python3 tools/armory_export.py --out … --full            # ignore the state file, export everyone
```

Database: a read-only `armory` user (grants in `classicplus_armory.sql`), password in `ARMORY_DB_PASSWORD`.
State: `<out>/.armory-state-<realm>.json` (or `--state`): one summary per character (name, level,
class, race, privacy and key, points, kills, professions, guild, last 10 achievements, and the
signature that decides re-export: logout time, online, privacy, key, name, level, guild, rank).
Indexes, rankings and guild files are rebuilt from it every run; a character's own file only when its
signature changed. Characters deleted or renamed lose their old file in the same run.

### Publishing (documented, not run by the cron by default)

* `--publish git`: copies `--out` into `ARMORY_GIT_SUBDIR` (default `armory`) of the clone in
  `ARMORY_GIT_DIR`, branch `ARMORY_GIT_BRANCH` (default `gh-pages`), commits only when something changed
  and pushes. Use a deploy key with push access to the pages repository only.
* `--publish r2`: PUTs the files written this run and DELETEs the files removed, signed with AWS
  Signature V4 (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `ARMORY_R2_ENDPOINT`,
  `ARMORY_R2_BUCKET`, `ARMORY_R2_PREFIX`, default `armory/`), `Cache-Control: public, max-age=300`.
* `--torrent DIR`: once a day `armory-YYYYMMDD.zip` (public files only) plus `.torrent` with the realm's
  tracker (`ARMORY_TORRENT_BASE_URL`, `ARMORY_TORRENT_TRACKER`; the info-hash is appended to
  `ARMORY_TORRENT_ALLOW`, the tracker's allowlist), through `tools/make_release_torrents.py`'s guard.

The realm itself serves the folder at `https://play.openvanilla.app/community/armory/` (the Herald public
folder, like `community/streams.json`); the site's pages read `armory/` beside them, so the static site
needs either `--publish` or a `/armory/` route to that folder. `hetzner/armory_cron.sh install` sets all
of this up on the realm server (database login, DBC copy, env file, timer).

## Community realms

A host whose `HostConfig.armory` is on (off by default; the launcher's host settings can offer it as
"Show this realm in the Open Vanilla armory") runs the same exporter hourly on the host database (`--community --realm <host_id>`, through the mariadb client the
host agent already uses), zips the realm folder and uploads it:

```
POST /api/armory/upload            (wenilla-realm, ARMORY_UPLOAD_ENABLED=1)
Authorization: Bearer <directory claim token>
X-OpenVanilla-Host-Id: <16-character directory host id>
X-OpenVanilla-Host-Key: <hex Ed25519 public key of the host>
X-OpenVanilla-Signature: <Ed25519 over the exact body bytes, hex or base64url>
Content-Type: application/zip      body ≤ 20 MB
```

The service checks the claim token against the directory (a live, not delisted claim gives the host id),
pins the host key to the host id on the first upload (`<state>/armory-hosts.json`; staff remove a line to
re-pin), verifies the signature, then unpacks only `*.json` files (each ≤ 1 MB, names
`[a-z0-9~._-]`, at most one folder level, only `guilds/`), each parsed as JSON, into
`ARMORY_UPLOAD_DIR/<host_id>/` (replacing the previous upload as a whole). Uploads are limited to one
per 10 minutes per host. The central exporter then lists the realm in `index.json` and `guilds.json` as
`"community": true`. A delisted host's folder is left for staff to remove.

On the host this is `launcher/p2p/armory.py`: `HostConfig(armory=True)` starts `HostSession._loop_armory`
(first run 5 minutes after start, then hourly; not on LAN-only realms), which runs the exporter from the
server pack's `tools/` (or the repo's) over `HostSession.query` (`CliDb`), writes `<host>/armory/<host_id>/`,
and uploads only when something changed (or on `HostSession.armory_upload(force=True)`). Failures land
in the host status's `last_error` as `armory: ...`; the realm keeps running. Turning it on is a host
choice; each character's own setting (public / friends / hidden) still applies.

## Tests

`python3 -m unittest tests.test_armory_export -v` (SQLite fixture; plus a private MariaDB with the real
CMaNGOS DDL when `mariadbd` is installed), `tests/test_armory_host.py` (host agent hook),
`lua5.1 devkit/sim/run_tests.lua armory` (in-game setting), `cargo test -p wenilla-realm --test armory`.
