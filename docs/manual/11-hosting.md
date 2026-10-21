slug: hosting
title: Host your own realm
kicker: Chapter 11 · Build
summary: Run a realm for friends with Open Vanilla Server: what you need, the first ten minutes, GM accounts, letting friends in, and Server Studio. The Host Guidebook has every detail.

This chapter is the overview. The **[Host Guidebook](../guide.html)** is the full reference, and each section here links to its chapter.

## What you need {#needs}

- Windows 10 or 11, 64-bit, about 15 GB free (an SSD helps), and Python 3 on your PATH.
- **On a Mac or Linux** (a laptop, a home server or a rented server), the realm runs in Docker instead: see [Host on a Mac or Linux](host-mac-linux.html), the full manual for that tool.
- The SPP Classics server (the launcher's Solo setup installs it, or get it by hand).
- Your own Vanilla Client v1.3 files.

Guidebook: [Before you start](../guide.html#before), [Install](../guide.html#install).

## Your first realm {#first-realm}

1. Install SPP: set up [Play Solo](solo.html#setup) once, or by hand (`Server_Update.bat`, then `Launcher.bat`: type 1, then 0).
2. Download **Open Vanilla Server** from the [host page](../host.html), unzip it, and run `Start Open Vanilla Server.bat`.
3. Press **START / RESTART ALL SERVICES**. It starts the database (port 3310), login (3724), world (8085) and the realm's website (18090, at `http://127.0.0.1:18090/`).
4. Make yourself a GM account: **Player & GM Admin Manager**, or in the server console `account create NAME PASSWORD` then `account set gmlevel NAME 3`.
5. In the launcher, **Realms → Add a server** with `127.0.0.1`, and play.

Guidebook: [Your first realm in ten minutes](../guide.html#first-realm), [The server window, part by part](../guide.html#panel).

## Accounts, GMs and rules {#accounts-rules}

- Account levels: 0 Player, 1 Moderator, 2 Game Master, 3 Administrator. [Accounts and roles](../guide.html#accounts).
- In the browser client a GM opens the **GM panel** with the **GM** button or **Ctrl+Shift+G**: toggles, kits, item and NPC browsers and the full command catalogue. [Game Master tools](../guide.html#gm).
- Rates and rules live in `mangosd.conf`; the **Live Config Editor** edits them. [Rates and rules](../guide.html#rates). The Vanilla Remastered switches (auto-learn, free respec, dual spec, AoE loot, instant mail) are covered in [Edit your own game](editing.html#realm-rules).

## Letting friends in {#friends}

- **Same network:** friends add your LAN IP.
- **Over the internet:** forward TCP **3724** and **8085** to your PC.
- **A public website** with HTTPS (needed for Discord sign-in and browser play): **Get Caddy → Public HTTPS address → Allow web ports**.

> **Never:** Never expose port 3310 (the database) or 18090 (the local admin site) to the internet.

Guidebook: [Name and address](../guide.html#identity), [Letting friends in](../guide.html#friends), [Keeping it safe](../guide.html#security).

## How many players can you host? {#capacity}

The world runs on your PC, so your PC sets the limit. Upload is rarely the problem (about 5 KB/s per player, double in cities); processor time for **playerbots** and memory for the database are. Rough guides until we publish measured ones:

| Host | Real players | Notes |
| --- | --- | --- |
| 4 cores, 8 GB, SSD | 20–40 | Keep bots few |
| 8 cores, 16 GB, SSD | 50–100 | A modest bot population |
| Rented server with dedicated cores | 100–300+ | Moving to a Linux server: [Guidebook](../guide.html#vps) |

Bots cost the most: if the realm lags, lower the random bot count first. The server's own advice for busy realms is one map-update thread per spare core (`MapUpdate.Threads` in `mangosd.conf`).

## Growing your realm {#grow}

1. **Community:** list it in the realm directory (when it opens); it shows greyed, "play at your own risk", until it has a track record.
2. **Verified:** steady uptime and a staff-approved owner get it the gold badge, and an optional Armory listing.
3. **Adopted:** when a realm outgrows your PC, export it with the backup tools and move it to a datacenter server, still run by you and your community.

Your players connect through Open Vanilla's relay or volunteer nodes, so they never see your home address and you don't need to open router ports. See [How the player network works](realms.html#p2p).

## Server Studio {#studio}

**Server Studio** is a local admin web app for your realm: dashboard, players, messages, backups, realm settings, logs and a history with undo. Sign in with a GM level 3 account; it only answers on the host PC (use an SSH tunnel for a VPS). Guidebook: [Server Studio](../guide.html#studio).

## Backups and moving to Linux {#backups-vps}

- **World Database Backups & Toolset** in the server window, or **Host → Backup** in the launcher. [Backups and restore](../guide.html#backups).
- Outgrowing your PC? A small Linux VPS runs the same realm with two scripts. [Moving to a Linux server](../guide.html#vps).

## List your realm {#list}

Community realms can be listed in the realm directory and, if you choose, in the Armory ("Show this realm in the Open Vanilla armory"). Ask in the Discord's help forum, or see [Projects](workshop.html#directory) for listing a whole project.
