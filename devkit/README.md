# Open Vanilla devkit

Test a change in seconds on your PC, try it against the live realm without pushing, and let a
staging realm prove it before players get it. **Start with `devkit\Dev.bat`.**

```
your PC                                   the server
-----------------------------------       -------------------------------------------------
check.py, Lua sim, SQL tests (seconds)    push -> staging hot update -> Herald Lite -> live
dev proxy: live realm + your files        nightly: full Herald in a real browser
```

| Part | What it is | Run |
|---|---|---|
| `check.py` | Repo checks: .toc lists, Lua parses, patch-Z matches `Data/Interface`, JSON/YAML/JS/shell/Python parse, realm_up downloads every page file, version vs website links, no game data in git | `py -3 devkit\check.py` |
| `sim/` | Every Classic+ addon in a fake Vanilla game: 111 tests, ~2 s. Two fake players for Persona and Concord. | `lua5.1 devkit/sim/run_tests.lua` |
| `db/` | Our SQL applied twice to a throwaway MariaDB with stock classic-db rows; checks it's re-runnable and does its job | `py -3 devkit\db\test_sql.py` (Docker) or `--local` |
| `proxy/` | **Zero-push loop**: `http://localhost:8080` is the live realm, but `/ow/*`, `bridge.js`, the addon loader and the Classic+ addons come from your folder. Edit, `/reload` or refresh. | `Dev.bat` option 4 |
| `heraldlite/` | Headless test bot (Rust, wenilla's own protocol code): logs in, buys from a vendor, checks weapon skills, trades a Persona between two bots. JSON report, under a minute. | `Dev.bat` option 5 |
| `staging/` | The staging realm on the server and `promote.sh` (staging -> Herald Lite -> live) | see `staging/README.md` |
| `loadlab/` | Loading pass: measure load times/bytes cold and warm; service worker; prefetch at the login screen; lite textures (patch 0006); patch-Z revalidation (patch 0007) | see `loadlab/README.md` |
| `patchz/` | A Docker image that rebuilds `patch-Z.MPQ` from `Data/Interface` | `Dev.bat` option 8 |
| `mpqread.py` | Pure-Python MPQ reader (used by check.py; no StormLib) | |
| `ci/devkit.yml` | GitHub runs check.py, the Lua sim, the SQL tests, the proxy tests and Herald Lite's tests on every push (Ship.bat installs it) | |

## The loop

1. Edit addons, page files or SQL.
2. `Dev.bat` 1 and 2 (seconds). Fix what they say.
3. Addon or page change: `Dev.bat` 4 and try it in the browser against the live realm. Nothing is pushed.
4. Ship. The hotpatch action updates **staging**, Herald Lite plays it, and only then is live
   updated to that exact commit. A failed Herald Lite run stops there and live stays as it is.
5. Every night the full Herald signs in with a real browser and checks graphics, art and frame rate.

## Adding a test when you fix a bug

- Addon bug: a `T.test(...)` in `sim/tests/<addon>.lua` that fails before the fix (see `sim/README.md`).
- Server/SQL bug: a check in `db/test_sql.py`, or a scenario line in `heraldlite/scenarios/`.
- Page bug: a check in `realm/www/owdiag-checks.js`.

## Rules

- No Blizzard game data in git: the sim and SQL tests use none, and check.py refuses map, model and
  MPQ files (patch-Z, our own, is the one exception).
- Tools here are for building and testing; nothing in `devkit/` ships to players.
