slug: contributing
title: Contribute to Open Vanilla
kicker: Chapter 16 · Share
summary: Report bugs, fix the manual, and send changes to the project: the branches, the tests to run, and how releases ship.

## Ways to help {#ways}

- **Report bugs** in the Discord's bug-reports forum or as [GitHub issues](https://github.com/orionopenwow/OpenVanilla/issues), with your logs (`Logs\` in the launcher's data folder).
- **Make addons** and [publish them](workshop.html).
- **Stream and make videos**: [link your channel](website.html#link-channel).
- **Host a realm** or [run a node](realms.html#nodes).
- **Fix the manual** (next).
- **Send code**: see below.

## Fix the manual {#fix-the-manual}

This manual is plain text in the repo: one Markdown file per chapter in `docs/manual/`. To fix or add something:

1. Edit the chapter's `.md` file. Sections are `## Heading {#link-id}`; keep existing ids so links keep working.
2. Build it: `python tools/build_manual.py --check`. It writes the pages to `www/manual/` and fails if any link or anchor is broken.
3. Send it as a pull request, or describe the change in an issue.

An AI agent with the [workspace kit](ai.html) can do this for you: "Read CLAUDE.md. In docs/manual/, add a section about <topic> to the right chapter, then run the build with --check."

## How the code is organised {#layout}

| Folder | What's there |
| --- | --- |
| `Data/Interface/AddOns/` | The Vanilla Remastered addons |
| `launcher/` | The Windows launcher |
| `www/` | The website (and this manual in `www/manual/`) |
| `realm/` | The realm: server patches, Vanilla Remastered SQL, browser-play pages |
| `bot/` | Herald, the Discord bot |
| `tools/` | Art generators, the Workshop tools, the Model Porter, the patch builder |
| `devkit/` | The Lua sim, SQL tests, dev proxy, Herald Lite |
| `agent/` | The AI workspace kit |
| `workshop/` | The Workshop catalogue and collections |

## Branches {#branches}

- **`main`** is where work happens.
- **`stable`** is what's live: the realm, the website and the launcher's updates all follow it. Only releases move it.

## Tests to run {#tests}

```
py -3 devkit\check.py                   # repo checks (CI runs --strict)
lua5.1 devkit/sim/run_tests.lua         # addon tests
python devkit/db/test_sql.py --local    # realm database changes
py -3 -m pytest tests                   # launcher, site, bot, tools
```

When you fix a bug, add a test that would have caught it: addon bugs in `devkit/sim/tests/<addon>.lua`, server or SQL bugs in `devkit/db/test_sql.py` or a Herald Lite scenario.

## How releases ship {#releases}

A release is playtested on staging, gets a `## New in X.Y.Z` section in `CHANGELOG.md`, and is tagged by the maintainer. The build server makes the installer, the zip, their checksums and a signed update manifest; launchers pick it up by themselves.

## Rules for contributions {#rules}

- No Blizzard files, ever: checks refuse MPQs, DBCs and stock interface files.
- No secrets in commits: tokens, keys and passwords stay in `.env` files that git ignores.
- Keep it free: nothing that sells power, items or game time.
