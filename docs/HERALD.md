# Herald

Herald is Open Vanilla's bot. On the website he's presented as "a self-learning AI that tests the game
and plays on allowed realms" (`www/herald.html`). This page ties the pieces together and keeps the
claims honest: what runs today, and what is still coming.

## The pieces

| Piece | Where | What it does today |
|---|---|---|
| Discord bot | `bot/herald.py` (+ `herald_bridge.py`, `herald_mod.py`, `herald_streams.py`, `herald_support.py`) | The gate question, Arrivals, the live server-status message, the moderation desk, streams. |
| Browser check | `tools/owbot.mjs` | Signs in nightly with headless Chromium as **Herald, a Human Hunter**, checks graphics, art and frame rate, and posts a summary to Discord. |
| Herald Lite | `devkit/heraldlite` | Plays every update on staging before live (sign in, vendor, weapon skills, trade). |
| Autopilot v1 | `devkit/heraldlite` (`autopilot`), see `devkit/heraldlite/AUTOPILOT.md` | Plays a Human Hunter through Northshire, levels 1 to 5, with no human input: quests, kite cycle, loot, rest, deaths, turn-ins. Writes a JSONL run log. Hard-coded host allowlist (`src/autopilot/guard.rs`). |
| Herald Autopilot (the program) | `autopilot/` (`Herald Autopilot.bat`), see `autopilot/README.md` | The window players use: pick a goal and press START, set rules in plain sentences, simulate gear, watch the log, map and bags. Runs the offline demo, Herald Lite on a bot account, or a realm that allows autoplay (`bot/herald_autopilot_api.py`). Learns from opted-in players' anonymous run stats and turns them into better default rules. |
| Planner and simulator | `tools/autopilot` | Builds the route and the kite tactics from classic-db and our Classic+ SQL, and predicts minutes per level. |
| Bot lab | `tools/botlab` | Logs the realm's playerbots, so plans can be compared with lots of real levelling. |
| Showcase | `www/herald.html`, art from `tools/gen_herald_art.py` into `www/assets/herald/` | The page, the hero art, the banner, the avatar (also for Discord), ability icons and an **illustrated** GIF. |
| Stats | `www/community/herald.json` | Runs, quests completed, bugs found, best times, last run, status. `live: false` until real numbers are written; the page then shows placeholders. |
| Launcher card | `www/downloads/live_herald_card.json` | `{id, title, text, image, link}` for the launcher's live content. |
| In-game outfit | `realm/classicplus/pending/classicplus_herald.sql` | Pending. The Greenwood set (11 white low-level items) for the character Herald on a registered bot account, via `.send items`. Also creates `openvanilla_bot_account`, the server-side bot flag. |

## What "self-learning" means here

- **Now:** the simulator tries kite settings against each creature and keeps the winners. The
  planner orders quests into a route and predicts the pace. An autopilot run logs every decision,
  and its summary has `vs_route`, actual against predicted, by level and quest. People read those
  numbers and adjust the next plan.
- **Coming:** retuning automatically after each run, many Heralds in parallel (the "fleet"), runs
  pooled into botlab, more classes and zones, the full 1 to 60.

Don't describe anything in the "coming" list as working on the website or in Discord until it is.
The page marks those parts with a **Coming** tag.

## Where he may play

Only on our realms (`play.openvanilla.app`, `staging.openvanilla.app`) and on localhost or test hosts (the
autopilot's built-in allowlist). He always uses his own bot account and plays one character named
Herald. Never in PvP, never in the economy (no auction house, no trading for profit), never racing
for server firsts. Opt-in for community realms (off by default) and a visible in-game bot tag are
**coming**. `openvanilla_bot_account` (pending SQL) is the flag they will read.

## Updating the showcase

- Art: `python tools/gen_herald_art.py` (everything, about a minute), or `--stills-only` to keep the
  GIF. The output is deterministic.
- Real clip: `tools/herald_capture.md`.
- Numbers: write `www/community/herald.json` (keep the field names, set `live` to `true`).
  `best_times` holds seconds, keyed by route (`northshire_1_5`). Count `bugs_found` only for reports
  the team confirmed.
