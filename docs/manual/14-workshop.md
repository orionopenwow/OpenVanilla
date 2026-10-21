slug: workshop
title: Publish to the Workshop
kicker: Chapter 15 · Share
summary: Install from the Workshop, then share your own: an addon, a Vanilla Remastered port, a collection, a fork of Open Vanilla, or a whole repo or project.

The **Workshop** is where players find addons for the Vanilla client: rated, reviewed, checked in a fake client before anyone installs them, and one click from the launcher. Bigger things (forks, clients, server projects, games) go in the **Projects** directory next to it.

## What goes where {#what-where}

| You made | Where it goes | How |
| --- | --- | --- |
| An addon (UI, bags, maps, quest helpers, combat, social...) | **Workshop** | [Upload it](#upload) or [send a catalogue entry](#pull-request) |
| A port of an open addon into Vanilla Remastered | **Workshop** | [Port it](#port), then upload |
| A bundle of addons for a play style | **Workshop collection** | [Collections](#collections) |
| A fork of Open Vanilla, a client, a server, a repack, a game | **Projects** directory | [List a project](#directory) |
| An addon on GitHub you want found | **Workshop**, automatically | [Tag your repo](#github-topics) |

## Install from the Workshop {#install}

- **On the website:** open [the Workshop](../workshop.html), pick an addon, press **Install**. It opens the launcher, which downloads the package, checks its fingerprint and installs it into `AddOns\Enabled`. Collections install several at once.
- **In the launcher:** **Workshop → Addons**. **Installed** lists yours, with **Enable/Disable** each.
- **From a zip:** **Workshop → Installed → Install from .zip**. It accepts plain addon zips, packs of several addons and GitHub "Download ZIP" archives, renames folders to match their `.toc`, and refuses anything that would land outside your AddOns folder.
- **From GitHub:** in Advanced mode, the **GitHub** tab searches repos (presets: Repacks, Vanilla addons) and installs a repo's default branch.

Check the label first: **Works** (loaded and logged in clean), **Partly** (uses parts of the API the checker can't test), **Needs fixes**, **Not checked**, and **Ours** for the Open Vanilla addons.

## Before you publish {#prepare}

1. **It runs on Vanilla.** `## Interface: 11200` in the `.toc`, Lua 5.0 only ([the rules](editing.html#lua50)), folder name = `.toc` name.
2. **It passes the scanner:** `python3 tools/workshop_scan.py MyAddon --json` ([details](editing.html#scan)). Aim for **works**.
3. **It has a licence that lets others share it**, as a `LICENSE` file in the folder. The Workshop can host copies only under: MIT, BSD-2-Clause, BSD-3-Clause, Apache-2.0, GPL-2.0, GPL-3.0, LGPL-2.1, LGPL-3.0, MPL-2.0, Unlicense, CC0-1.0.
4. **It's yours to share.** You wrote it, or its licence allows sharing and you credit the author.
5. **Screenshots and a one-line summary** ready. An AI agent can draft the listing: see [Connect an AI](ai.html#ideas).

> **Note:** Addons with no licence, "all rights reserved", non-commercial (CC-NC) or AGPL licences, or from CurseForge, can still be listed, but as **Get it from the author** links: the Workshop never rehosts them.

## Upload an addon {#upload}

On [the Workshop page](../workshop.html#upload), **Share an addon** (signed in):

| Field | Limit |
| --- | --- |
| Addon name | 48 characters |
| One line | 280 characters |
| Licence | One from the list above |
| Source link | Optional, https |
| Zip | The addon folder with its `.toc` and licence, up to 10 MB |

Tick **I wrote this addon, or its licence lets anyone share it, and the licence file is in the zip**, and send. You'll see "Upload #n is in the review queue". You can upload five a day, with at most five waiting.

> **Note:** Uploads open with the realm update that adds them. Until then, use a [catalogue entry](#pull-request).

## The review gate {#review}

Every upload is scanned in the fake Vanilla client before a person looks at it. The scanner flags anything that sends chat when it loads or on a timer, reads other addons' saved data, uses `os` or `io`, moves gold or items, or runs arbitrary code. Anything serious holds the upload for a moderator. Uploads are never served to players until a moderator approves them; approved ones become catalogue entries.

## Send a catalogue entry {#pull-request}

The Workshop's source is one file per addon in `workshop/catalog/<id>.yml` in the repo. Adding yours by pull request:

```
id: my-theme              # lowercase, digits, dashes; 2-48 characters
name: MyTheme
author: You
summary: A dark, minimal skin for the Vanilla Remastered windows.
description: |
  What it does, how to open it (/mytheme), what to expect.
category: interface       # interface, unitframes, combat, raid, quests, bags, maps,
                          # social, economy, professions, macros, tooltips, utility, classicplus
tags: [theme, minimal]
license: MIT
rehost: true
source_url: https://github.com/you/MyTheme
homepage: https://github.com/you/MyTheme
upstream:
  how: git
  repo: you/MyTheme
  branch: main
screenshots: []
```

Maintainers run `python3 tools/workshop_build.py --fetch --only my-theme`, which pins your current commit, scans it, zips it with a credits file and records its fingerprint. New versions: the next index run picks up your newest commit and the build re-pins it.

## Get found automatically {#github-topics}

Add one of these **topics** to your GitHub repo: `wow-vanilla-addon`, `vanilla-wow-addon` or `turtle-wow`. The indexer finds tagged repos, and a person reviews each before it's listed.

## Port an open addon into Vanilla Remastered {#port}

Vanilla Remastered addons get the suite's settings window and look. To wrap an openly licensed addon:

```
python3 tools/workshop_port.py path\to\SomeAddon --license MIT --name SomeAddonPlus --author "You" --source https://...
```

It writes `workshop/ports/<Folder>Plus/` (a `.toc`, a Lua file and `PORT_NOTES.txt`), refuses addons without an allowed licence, and never publishes anything by itself. Test it in the sim and the game, then upload it.

## Collections {#collections}

A collection is a curated list of addons for a play style (raiders, roleplayers...), installed with one click. They live in `workshop/collections/<id>.yml`: `id`, `name`, `curator`, `summary`, `description`, `banner` and `addons: [ids]`. Send one by pull request.

## Ratings and reviews {#ratings}

Signed-in players can rate and review addons on each addon's page. Moderators can hide a review's text if it breaks the rules. Install counts are anonymous.

## List a fork, repo or project {#directory}

Forks of Open Vanilla, other clients, server projects, repacks and games built on the same tech go in the **Projects** directory (`www/community/directory.json`). Each gets a page at `project.html#<id>` and a spot in the launcher's **Workshop → Projects** tab.

To be listed, [open an issue](https://github.com/orionopenwow/OpenVanilla/issues) with the name, link, a short description, the credits and a screenshot. An entry looks like this:

```
{
  "id": "my-fork",
  "name": "My Fork",
  "kind": "source",
  "client": "1.12.1",
  "version": "0.3",
  "author": "You",
  "license": "MIT",
  "tags": ["fork", "pvp"],
  "url": "https://github.com/you/my-fork",
  "homepage": "https://you.example",
  "description": "One line.",
  "about": "A paragraph: what's different and who it's for.",
  "credits": ["Open Vanilla", "benilla by samwhosung"],
  "images": ["https://..."]
}
```

`kind` is `client`, `source` or `game`.

## Fork Open Vanilla {#fork}

1. **Fork the repo** on GitHub ([orionopenwow/OpenVanilla](https://github.com/orionopenwow/OpenVanilla)) or clone it to another host.
2. **Keep the credits.** Open Vanilla is built on **benilla** (MIT / Apache-2.0); keep its licence files and credit line.
3. **Keep Blizzard's files out.** The repo's checks refuse them, and so should your fork: players bring their own Vanilla Client v1.3.
4. **Rename it.** Use your own name and art; don't present your fork as the official Open Vanilla.
5. **Point it at your own realm.** Realm addresses live in the launcher's defaults and the site's config; your fork's players should never sign in to a realm you don't run.
6. **List it** in the [Projects directory](#directory) so players can find it.

> **Warning:** The licence for Open Vanilla's own code (the launcher, site, Vanilla Remastered addons and tools) is being finalised. Until it's published in the repo, ask the maintainers before releasing a fork publicly.
