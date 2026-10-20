# Herald Autopilot

The desktop program where Herald plays a character for you, simulates gear, and learns from how
people play. Double-click **`Herald Autopilot.bat`** in the repo root (it installs Pillow the first
time). Python 3.10+ on Windows, macOS or Linux.

```
python autopilot/herald_autopilot.py            # last realm used (the demo the first time)
python autopilot/herald_autopilot.py --demo     # the offline demo realm
python autopilot/herald_autopilot.py --realm https://play.openvanilla.app
```

## Watch Herald play your own character (any race, any class)

The simplest way, and the one that works everywhere the realm allows it:

1. Log in to your character in the game (the Open Vanilla client, the browser, or a stock Vanilla client
   with the Classic+ addons).
2. Click **Herald** by the minimap (or type `/herald`) and press **Let Herald play**. Pick what he
   does: Level up, Quest, Gather or Explore.
3. Watch. Your character plays on the realm's own bot AI (cmangos playerbots' self-bot: `.bot self`)
   with your camera, chat and UI as usual. Press **Take back control** (or `/herald stop`) any time.

The realm owner decides: it needs `AiPlayerbot.SelfBotLevel = 2`. Open Vanilla Server and Play Solo set
it (Open Vanilla Server: `"herald_selfbot": false` in server_settings.json turns it off). On Vanilla
Remastered: `bash hetzner/herald_selfbot.sh on`. Herald Autopilot (this program) can then change his
goal from the desktop through `bot/herald_autopilot_api.py` (`.rndbot cmd <name> nc <strategies>` over the console).

## Where it can play

Herald only plays where the realm allows it, and nothing in the program hides from a realm's staff.
It has no anti-ban features, no fake human delays, and doesn't log out when a GM whispers.
Pick the realm in **Settings**:

| Realm | What runs the character | Status |
|---|---|---|
| **Demo (offline)** | A small simulated Elwynn Forest (`ap_link.DemoLink`) | Works now. Good for trying it, tests and screenshots. |
| **Herald Lite (a bot account)** | `devkit/heraldlite`'s autopilot, a headless client that logs a **bot account** in and plays a `tools/autopilot` route | Works once Herald Lite is built (`cargo build --release` in `devkit/heraldlite`). It plays only on `play.openvanilla.app`, `staging.openvanilla.app`, `127.0.0.1`, `localhost`, `*.test` and `*.localhost`. The binary hard-codes this list and the program checks it too. |
| **Vanilla Remastered / another realm** | The realm's own bot AI, through `bot/herald_autopilot_api.py` | The realm turns it on with `hetzner/herald_selfbot.sh on` (`AiPlayerbot.SelfBotLevel = 2` and `AUTOPILOT_ALLOWED=1`). START hands the online character to the realm's bot AI from the server (`.wnl autopilot <name> on`, realm/mangos 0015), then drives it with `.rndbot cmd <name> nc <strategies>`; STOP gives it back. The player watches in game and can take control back from the Herald panel. Selling, the auction house, mail, bank, guild, PvP and chat are always off on a player's character. |

## The window

The look comes from the Herald UI kit sheet: a rounded window with the kit's gold corner flourishes, its own close and minimise buttons, glass panels under the kit's plaques, and the kit's nav bars and START/STOP button.

**Pages**

| Page | What it does |
|---|---|
| **Play** | Pick a character and a goal (Level up, Quest, Gather, Follow me, Dungeon), then press START. Shows a live log, a live map with the route, the bags, the XP, health and mana bars, and XP/hour, kills, loot, deaths and time. |
| **Rules** | One sentence per setting, each with one choice, for example *Rest when health is below [35%]*. Every class starts from sensible defaults, which the realm's learned profile can tune. Your own choices always win and are marked *yours*. |
| **Sim** | Compares two sets of stats for one class: level 60 against a raid boss, a 3-minute fight, hundreds of runs. It shows which set wins, by how much, where the damage comes from, and what each stat is worth (`ap_sim.py`). |
| **Session** | This run's numbers and a timeline of what happened. Can bring the window to the front with a chime when a run stops. |
| **Settings** | The realm, how you're signed in (the launcher's token; the program never sees a password), the Herald Lite bot account, and learning: on/off, the exact text of the next upload, and a button to delete what's queued. |

**Controls**

- One big **START**/**STOP** button.
- **PAUSE**, or press Space.
- When START isn't available, the line under it says why.

**Removed from the mock-up**

- Antiban, humanlike delays and disconnect-on-GM-whisper.
- The 3D view and the "bugs encountered" counter.
- Duplicate sliders, and the separate Pathing, Combat, Inventory and Analytics pages.

## Learning

Herald learns only if the player agrees: he asks once, on first start.

**What gets sent:** anonymous numbers, in one small gzip batch (a few KB).

- Per run: class, level band, goal, XP/hour, kills, deaths, rests, and the rules in force.
- Per death: the rest and pull rules, and the level gap.
- Per rule change: what changed, and whether it was right after a death.

**What never gets sent:** names, chat, positions or the account. A random install id is sent so
the realm can drop duplicate uploads; it changes every month.

**When it's sent**

- After a run ends, or after 5 minutes idle.
- Never during a run.
- At most once every 30 minutes, waiting longer after each failure.

**What happens on the realm** (`/api/herald/learn`)

- Every field is checked, and anything unknown is dropped.
- Each night's batches are turned into `profiles.json`. For each class and level band, it holds
  the value of each rule that gave the most XP per hour once deaths are counted against it.
- A value needs at least 5 runs, and at least two values are compared. When two values are
  within 3% of each other, the one players switch *to* more often wins.

**What Herald does with it:** he downloads `profiles.json` at start and uses it as his defaults.
It is data, checked against the rule list, never code.

## Files

| File | What it is |
|---|---|
| `herald_autopilot.py` | the window (Tk) |
| `ap_core.py` | goals, rules, class defaults, a run's numbers |
| `ap_link.py` | `DemoLink`, `HeraldLiteLink`, `RealmLink` |
| `ap_sim.py` | the Vanilla damage simulator |
| `ap_learn.py` | the opt-in learner: queue, batches, upload timing, profile download |
| `ap_art.py` | the window's art: the rounded frame, glass panels, icons, map (`python autopilot/ap_art.py` rebuilds `assets/ui/`) |
| `ap_kit.py` | pieces cut from the Herald UI kit sheet (`assets/kit/herald_kit_sheet.png`): corner flourishes, close/minimise, nav bars, the START/STOP button, plaques, toggles, checkboxes |
| `assets/` | Cinzel and Marcellus (SIL OFL), Herald's portrait, the built UI images |
| `../bot/herald_autopilot_api.py` | the realm side: autopilot API and learning (`hetzner/herald_up.sh` runs it) |

## Tests

```
python -m unittest tests.test_herald_autopilot -v                                         # 48 feature tests
xvfb-run -s "-screen 0 1280x800x24" python tests/ui_autopilot_walkthrough.py out/         # click-through, screenshots
xvfb-run -s "-screen 0 1280x800x24" python tests/ui_autopilot_realm_smoke.py out/         # against a live API
```

## What's next

1. **A visible tag.** Other players can't yet see that a character is on Autopilot (`[Autopilot]`).
2. **The map outside Elwynn Forest.** The API reports the zone, bags and quest log everywhere, and a
   map point in Elwynn Forest (the one zone map the app has). The character table is saved every few
   minutes, so these lag a little behind the game.
3. **More Herald Lite routes and classes** (`tools/autopilot`). The first route is Northshire for
   a Human Hunter.
