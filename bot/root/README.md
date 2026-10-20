# Open Vanilla on Root

Builds the Open Vanilla community on [Root](https://www.rootapp.com) the way `bot/discord_setup.py` builds the
Discord server: the community name and description, 24 roles, 8 channel groups, 38 channels, access rules and
the bot's pinned info posts (welcome and rules, FAQ, roadmap, support, help read-me's and more). Everything is in
`src/layout.ts`; edit it and re-run. It only adds what's missing, matched by name, and never deletes anything.

Double-click **`bot/Setup_Root.bat`**. The first time it asks for two things from the
[Root Developer Portal](https://dev.rootapp.com):

1. **Bot ID:** My bots → New bot → name it (for example "Open Vanilla Herald") → copy its ID.
2. **DEV_TOKEN:** your bot → Settings → Generate new dev token → Generate → copy it. Treat it like a password;
   it's saved in `bot/root/.env`, which git ignores.

Then it installs the Root SDK (once), builds, and runs the bot in Root's DevHost. When the window says
`DONE`, close it.

## Which community does it build in?

The DEV_TOKEN decides. The first token Root generates also creates a test community named after the bot
(your bot's name ending in `-test`) and points at it, so the first run builds there: a safe place to look the layout over.
The setup renames that community to "Open Vanilla", so it can also simply *become* the community if you invite
people to it.

To build in a community you already run instead, install the bot there (publish it to the Root Store with
`npx rootsdk build package` and `npx rootsdk upload package`, then add it from the Store in your community):
on start, the installed bot runs the same setup.

## How it maps from Discord

| Discord | Root |
|---|---|
| Gate: Outsider → Recruit → Adventurer | No gate. Root members join, read Start Here, and talk. |
| Faction and class role picker | The same roles, **self-assignable** in Root (members pick them on their profile). |
| Forums (help, bug reports, guides) | Threaded text channels. |
| Emoji channel names (`💬│general`) | Plain names (`general`). |
| Role names with spaces | Hyphens (`Game-Master`); Root role names allow letters, numbers and hyphens only. |
| Bridged #world, live server-status, alerts | Not yet: the channels exist; the live features are Discord-only for now. |

Not set by the bot: the community picture (Root needs it uploaded from the app; use
`bot/discord_assets` art or the site logo) and invite links.
