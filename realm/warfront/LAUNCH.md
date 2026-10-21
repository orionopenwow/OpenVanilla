# Warfront launch guide

Warfront is **built and stored, not running.** The website lists it as **SOON™** (gold) in the
realm list and on the "On the Horizon" section. Nothing on the live realm changes until you follow
this guide. Plan on about an hour, plus a few days of staging play before opening it to everyone.

Status (17 October 2026): patch 0010 was built into a private Warfront test realm (CMaNGOS
`de8f729` + playerbots `31e0f32` + 0001–0005 + 0010, classic-db `4d230bb`, the Warfront SQL) and
**bots played every feature in game**: 10 Herald Lite scenarios, 0 failures (the table in
[`README.md`](README.md#tested-in-game)). Offline: rule tests 57/57, addon sim 15/15, SQL 34/34,
Herald Lite tests 96/96. Section 4 repeats that test on the real stack, plus the by-hand checks.

---

## 1. Before launch day (decide and prepare)

| | What | Why |
|---|---|---|
| ☐ | Decide the domain (default `warfront.openvanilla.app`) | the install script and the website both use it |
| ☐ | Server room: Warfront's world server uses up to **2.5 GB RAM** on the live box | check `free -h`; resize first if under ~4 GB free |
| ☐ | Take a Hetzner snapshot of the server (Cloud Console → the server → Snapshots) | the install only adds a separate stack, but take one anyway |
| ☐ | Decide the known limits are OK for launch (section 7) | so the launch post doesn't promise them |
| ☐ | Write the launch post for Discord (what it is, `/wf`, `/arena`, rules: leaving rated = loss + 15 min lock) | players read Discord first |

## 2. Ship the code

1. On the PC, run `Ship.bat` (it pushes to the `stable` branch). Also copy
   `packaging/workflows/devkit.yml` to `.github/workflows/devkit.yml` so CI runs the Warfront tests.
2. Wait for CI to go green. It builds the `openvanilla-mangos` image with patches 0001-0010.
   Patch 0010 does nothing on other realms (`OpenVanilla.Warfront` is off by default), so the live realm
   is safe to update with it.

## 3. Install the stack (on the Hetzner server, as root)

```
cd /opt/openvanilla-classicplus/repo && git pull
bash hetzner/warfront_up.sh install warfront.openvanilla.app      # ~15 min, the world database installs
```

It then prints the steps only you can do:

1. **DNS:** an A record for `warfront.openvanilla.app` → the same IP as the live realm.
2. **Admin login:** open `https://warfront.openvanilla.app/setup` with the printed setup token.
3. **Discord sign-in:** Discord Developer Portal → OAuth2 → Redirects → add
   `https://warfront.openvanilla.app/auth/discord/callback`.
4. **Herald (the smoke-test bot):** make a login named `herald`, sign in once, create a Dwarf
   Hunter named Herald (1.12 has no Human Hunters), then:
   ```
   printf 'HL_WEB=https://warfront.openvanilla.app\nHL_USER=herald\nHL_PASS=...\n' > /opt/wenilla-warfront/heraldlite.env
   chmod 600 /opt/wenilla-warfront/heraldlite.env
   ```

Check it: `bash hetzner/warfront_up.sh status` should show every service healthy and **29 kits**.

## 4. Smoke test (the realm still shows SOON™ on the website)

### 4a. Automatic (Herald)

```
SCN=/opt/openvanilla-classicplus/repo/devkit/heraldlite/scenarios
bash hetzner/warfront_up.sh herald                      # smoke.txt + warfront_smoke.txt
bash hetzner/warfront_up.sh herald $SCN/warfront_live.txt
# these need a second account (HL_USER2 / HL_PASS2 / HL_CHAR2 in heraldlite.env):
bash hetzner/warfront_up.sh herald $SCN/warfront_sets.txt $SCN/warfront_wintrade.txt
```
Herald and its second character must be the **same class** for `warfront_sets.txt` (two Dwarf
Hunters is simplest). All scenarios must pass. The result is saved in `/opt/openvanilla-warfront/last-herald.json`.

The game-master scenarios (both Herald logins at GM level 3 in the realm's admin page, **before**
the realm opens: `.debug bg` changes every battleground while it's on):

```
bash hetzner/warfront_up.sh herald $SCN/warfront_streak.txt $SCN/warfront_crossfaction_bg.txt
```

The arena match scenarios pit Herald against its second account **from the same address**, which
the wintrade rule forbids in rated play. For this test only, set
`OpenVanilla.Warfront.Arena.SameAddressRated = 1` in the Warfront `mangosd.conf`, `bash hetzner/warfront_up.sh start`
(restarts the world server), run them, then set it back to `0` and restart again:

```
bash hetzner/warfront_up.sh herald $SCN/warfront_ringoflaw.txt $SCN/warfront_arena.txt   # arena last: it locks [b] for 15 min
```

`warfront_botfill.txt` needs realm bots on (see `README.md`); skip it if Warfront launches without them.

### 4b. By hand (you plus one friend, two accounts, both factions if you can)

Go to `https://warfront.openvanilla.app/` directly; the main site keeps it hidden until step 5.

| | Feature | What should happen |
|---|---|---|
| ☐ | Create a character | starts at 60 in its capital; welcome toast |
| ☐ | Welcome gifts | epic faction mount, riding, Onyxia Hide Backpack + bags, Engineering and First Aid 300; 2,000 gold and supplies (first character on the account only) |
| ☐ | `/wf` | the Warfront window opens with Kits, Gear, Shop, Shared sets, Arena tabs; also a row in the Classic+ menu |
| ☐ | Kits | pick a kit for your class: every slot fills, enchants are on, old white/grey gear is removed |
| ☐ | Gear picker | swap one slot; only items for your tier are offered; the swapped-out pool item is removed |
| ☐ | Shop | buy a flask; gold goes down; free gear sells for 0 at a vendor |
| ☐ | Shared sets | save a set, see it under Shared sets on the second account, vote, apply it, report it (3 reports hide it) |
| ☐ | Mall duels | duel in the mall (Gurubashi): health, mana and cooldowns reset after |
| ☐ | Bounty | get a kill streak on one character; the player who kills it collects the bounty |
| ☐ | Gurubashi chest | spawns on the hour |
| ☐ | Arena 1v1 | `/arena d1` on both: both land **inside the Ring of Law** (the spawn points are the one thing never seen in game), 60 s prep with buffs removed, "Fight!", result toast, rating changes, both home after 10 s |
| ☐ | Arena 2v2 | party queue `/arena r2` with two pairs (or skirmish `s2`) |
| ☐ | Leaver | leave a rated match: counts as a loss, queue locked 15 min |
| ☐ | Relog in a match | logging out mid-match and back in puts you at home, not in the ring |
| ☐ | Battlegrounds | Warsong Gulch pops with 6 players (Arathi 6, Alterac 20); with two people of the same faction queued, one plays for the other side (enemy-coloured name for the other team, their own faction back after) |
| ☐ | Bot fill | off-peak with few people queued: bots join, and you get "N of the players in this battle are realm bots" on entering |
| ☐ | Live counts | `/wf` → Arena: per-mode "N queued" and the bottom "Live" line; the website's Warfront section shows "Live now: …" once `WARFRONT_OPEN = 1` |
| ☐ | Other realms | log into Vanilla Remastered: no Warfront window, nothing changed |

If the Ring of Law spawn points are wrong, fix the two coordinates in `WarfrontArena.cpp`
(`SPAWN` near the top), rebuild (push → CI), then `bash hetzner/warfront_up.sh update`.

## 5. Open it

**Testing first (optional):** `WARFRONT_OPEN = test` in `www/downloads/links.txt` puts Warfront in
the website realm list marked **TESTING** (amber), playable but not announced, with a line that
characters may be wiped. Testers pick it like any realm.

Choosing Warfront (testing or online) opens the **mode screen**: Arena, Battlegrounds, Duels and
bounties, Gear up first (Contested towns and Rated battlegrounds show as Soon). The choice goes to
`warfront.openvanilla.app/?mode=arena|bg|duels|kits`; once in the world, the Warfront window opens
on that tab with a how-to-start line (a brand-new character still gets the kits first, then the line).

To open it for everyone, in `www/downloads/links.txt`:
```
WARFRONT_OPEN = 1
```
Ship it. The realm list turns Warfront green **ONLINE**, choosing it opens the mode screen and then
`warfront.openvanilla.app`, and the "On the Horizon" badge changes from SOON™ to Online by itself.
Post the Discord announcement.

## 6. Running it

| Job | Command |
|---|---|
| New Warfront files, SQL or config | `bash hetzner/warfront_up.sh update` |
| Stop / start | `bash hetzner/warfront_up.sh stop` / `start` |
| Health, kits, player count, ladder tops | `bash hetzner/warfront_up.sh status` |
| Re-run the smoke test after any change | `bash hetzner/warfront_up.sh herald` |
| Regenerate kits or the item pool | see `realm/warfront/README.md`, "Regenerating the data" |

First week: check `status` daily, watch Discord for exploit reports (gold, gear, arena), and check
the `warfront_set_report` table for hidden shared sets that need a look.

**Take it offline again (rollback):** set `WARFRONT_OPEN = 0` and ship (the site goes back to
SOON™), then `bash hetzner/warfront_up.sh stop`. Characters and ratings are kept in the Warfront
databases; `start` brings everything back.

## 7. Known limits (not in the launch post)

- The Gauntlet (5-player free-for-all) and world PvP town captures aren't built.
- Tier 1 is a shop for flasks and elixirs, not the permanent buffs in the plan.
- Mixed battleground teams: a player on the other side keeps their own race's look and racials; only
  their team and faction change for the battle. Reputation from the battle goes to the side they played.
- Rated arena never matches one network address against itself, so two people on the same home
  connection can only meet in skirmishes.
- Live counts on the website are up to 35 seconds old (mangosd every 15 s, the timer every 20 s).
