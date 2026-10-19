slug: troubleshooting
title: Troubleshooting
kicker: Chapter 16 · Help
summary: The common messages and fixes, for the launcher, the browser, the game and hosting, and where the logs are.

## Find your logs {#logs}

Launcher: **Settings → Folders → Open logs**. The files that matter are `launcher.log`, `update.log` and `web-backend.log`. Attach them to a bug report (they don't contain your password).

## Launcher messages {#launcher}

| Message | Fix |
| --- | --- |
| **CHOOSE YOUR GAME'S DATA FOLDER** | Press PLAY and pick your game's `Data` folder (or the folder with `WoW.exe`), or let it download a client |
| **Missing X.MPQ** / **X is damaged** | That client is incomplete: pick another folder or **Download & install** |
| **This is build N; Open Vanilla needs Vanilla Client v1.3 (build 5875)** | Wrong version: Open Vanilla needs Vanilla Client v1.3 (English, build 5875) |
| **Wow.exe wasn't found there** | Pick the folder that contains `WoW.exe`, not its parent |
| **SERVER OFFLINE** | The realm is down; check #server-status on Discord, or [Play Solo](solo.html) |
| **This realm has no website set** | Pick another realm, or add its portal URL on the Realms page |
| **Open Vanilla is offline** | The central services can't be reached; you can still play Solo and join friends directly |
| **That isn't an Open Vanilla invite link** | Copy the whole link again, or use **Join by address** |
| **Host key changed** | Ask your friend for a new invite link; don't join until they confirm |
| **The update couldn't be applied** | It retries next start; details in `Logs\update.log` |
| Windows says **Unknown publisher** | The launcher isn't code-signed yet: **More info → Run anyway**, or check the checksum first |

## Browser messages {#browser}

See [Playing in the browser](browser.html#trouble). The usual fix for a black screen is updating the browser and graphics driver (the client needs WebGPU).

## In the game {#in-game}

| Problem | Fix |
| --- | --- |
| A Vanilla Remastered window is lost off-screen | `/wnl reset` |
| The interface feels wrong after a change | `/setup` and pick a preset, or `/vanilla` for pure Vanilla |
| An addon errors | Turn it off in `/addons`; for your own addons ask an AI agent with the **Fix an addon error** prompt ([AI](ai.html#prompts)) |
| Stuck, dead in a bad spot, talents broken | **Help → Talk to a GM** ([Tickets](community.html#tickets)) |
| Quest pins or threat missing | Those need the realm; on some realms they're not available |

## Hosting {#hosting}

| Problem | Fix |
| --- | --- |
| "Information is not valid" at login | Reset the account's password in the server window |
| The server window closes straight away | Python isn't on PATH: reinstall Python and tick "Add to PATH" |
| The database won't start | Something else uses port 3310; close it |
| Friends can't connect | Forward TCP 3724 and 8085; check your firewall; give them your public address |

More in the Host Guidebook's [Troubleshooting](../guide.html#trouble).

## Still stuck? {#still-stuck}

Ask in the Discord **help** forum with what you did, what you expected, what happened, and your logs. Security problems: report them privately ([security.html](../security.html)).
