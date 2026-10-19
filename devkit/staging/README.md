# Staging realm

A second, small realm on the same server as the live one. Every hot update goes there first;
Herald Lite plays it, and only when it passes does the live realm get **exactly that commit**.

```
push -> hotpatch action -> promote.sh -> staging hot update -> Herald Lite -> live hot update
```

## Set it up (once, on the server, as root)

```bash
cd /opt/openvanilla-classicplus/repo/devkit/staging        # appears after the first hot update with this folder
bash staging_up.sh install staging.openvanilla.app          # ~10 minutes: the world database installs once
```

Then three things only you can do (the script prints them again):

1. **DNS**: an `A` record for `staging.openvanilla.app` pointing at the server.
2. **Admin login**: open `https://staging.openvanilla.app/setup` with the token the script printed.
3. **Herald**: in the staging admin panel make a login `herald`, sign in as it once in a browser,
   create its character **Herald, a Human Hunter**, and save its login for the bot:
   `printf 'HL_WEB=https://staging.openvanilla.app\nHL_USER=herald\nHL_PASS=...\n' > /opt/wenilla-staging/heraldlite.env`
   then `bash staging_up.sh build-heraldlite` and `bash staging_up.sh herald`.

## What it costs

| | |
|---|---|
| Disk | Its databases (~1 GB). Maps are the live realm's, shared read-only; the client's MPQs are hard links. |
| Memory | ~1.5 GB while running. It sleeps between updates: `promote.sh` wakes it and puts it back to sleep. |
| Players | None: it has its own accounts and characters, and only you make accounts. |

## Commands

| Command | Does |
|---|---|
| `staging_up.sh start` / `stop` / `status` | Wake, sleep, show health, the commit it runs and the last Herald Lite result |
| `staging_up.sh herald [scenario.txt ...]` | Run Herald Lite now (default: smoke, wallet, skills) |
| `promote.sh [--force-web]` | What the action runs: staging, Herald Lite, then live |
| `make_lite_maps.py <full> <out>` | Only for a realm on your PC: copy just the starting zones and capitals |

## How it's kept apart from live

- Its own compose project (`owstaging`), databases, passwords and volumes. `openvanilla_realm_up.sh`
  and `openvanilla_server_dbc.sh` now pick volumes by compose project, never by a name match, so the
  two stacks can't touch each other's world data.
- The live Caddy reaches it as `owstaging-realm` on the live network; it publishes no ports.
- Same images as live. A new realm image reaches both on the same pull, so image changes are only
  gated by the nightly full Herald, not by staging.
