slug: host-mac-linux
title: Host on a Mac or Linux
kicker: Chapter 12 · Build
summary: The complete guide to ovhost, the Open Vanilla realm host for macOS and Linux: prepare your computer, set up a realm for yourself, your home or the internet, run it day to day, make GMs, update, back up, move it and fix problems.

This chapter is the full manual for **ovhost**, the tool that runs an Open Vanilla realm on a **Mac** or a **Linux** computer or server. (On Windows, realms run on SPP Classics: see [Host your own realm](hosting.html).) Everything here is also in the tool itself: run `bash host/ovhost help` for the commands, and `bash host/ovhost manual` to read this chapter in your terminal.

## What it is {#what}

ovhost runs the same server the official Open Vanilla realm runs, inside **Docker**:

| Part | What it does |
| --- | --- |
| Database | Accounts, characters and the world (MariaDB) |
| Login server | Checks accounts and lists the realm |
| World server | The game itself, with the Vanilla Remastered changes |
| Realm website | Sign-up, sign-in, your realm's admin pages and the browser game |
| HTTPS | A secure address (Caddy), which the browser game needs |

One script installs it, starts it, updates it, backs it up and stops it. Your players play **in their browser** at your realm's address; with one extra option they can also use the desktop game.

| Good to know | |
| --- | --- |
| Runs on | macOS 13 or newer (Apple Silicon or Intel), and Linux: Ubuntu, Debian, Fedora, RHEL, Rocky, Alma, Mint, Pop!_OS, Arch, openSUSE, Alpine, on x86-64 or ARM (Raspberry Pi 5 and ARM servers) |
| Needs | Docker, about 4 GB of memory for Docker, about 12 GB of free disk, your own Vanilla Client v1.3 files |
| Takes | About ten minutes of your time, plus a one-time map build: an hour or more, longer on Apple Silicon |
| Costs | Nothing. Docker Desktop is free for personal use and small companies; OrbStack is free for personal use; Colima is free and open source |

## Before you start {#before}

### On a Mac {#before-mac}

1. **Install Docker.** Pick one:
   - **OrbStack** (recommended, light and fast on Apple Silicon): `brew install --cask orbstack`, or download it from orbstack.dev. Open it once.
   - **Docker Desktop**: download it from docker.com, open it and wait for the whale to stop animating.
   - **Colima** (free, terminal only): `brew install colima docker docker-compose`, then `colima start --vm-type vz --vz-rosetta --memory 6`.
2. **Apple Silicon (M1 and newer): turn on Rosetta for Docker.** The world server is an Intel program and runs through Rosetta. Docker Desktop: **Settings → General → Use Rosetta for x86_64/amd64 emulation on Apple Silicon**. OrbStack: on already. Colima: the `--vz-rosetta` above.
3. **Give Docker memory.** Docker Desktop: **Settings → Resources → Memory**, 6 GB or more. OrbStack: **Settings → System**. Colima: `--memory 6`.
4. **Put your game somewhere Docker can read.** Anywhere under your home folder works with every Docker. An external drive (`/Volumes/...`) works with Docker Desktop and OrbStack; with Colima, keep it under your home folder.
5. **Python 3** comes with the Xcode command line tools: if `python3 --version` asks you to install them, say yes.

### On Linux {#before-linux}

1. **Docker:** nothing to do. If it's missing, the installer offers to install it with your distribution's packages (it asks first, and uses `sudo`).
2. **Your user and Docker:** if Docker needs `sudo` for you, ovhost uses `sudo` for Docker. To drop that, run `sudo usermod -aG docker $USER` and log out and back in.
3. **Python 3, curl and tar** are almost always installed. If not: `sudo apt install python3 curl` (Debian/Ubuntu), `sudo dnf install python3 curl` (Fedora), `sudo pacman -S python curl` (Arch).
4. **ARM computers** (Raspberry Pi 5, Ampere, Graviton, Hetzner CAX): the installer turns on Intel emulation for the world server, once, and keeps it on after reboots.

### On a rented server (a VPS) {#before-vps}

- 2 CPU cores and **4 GB of memory** at least (8 GB for bots), 40 GB of disk, any distribution above.
- A **domain name** whose DNS **A record** points at the server's address, before you install (the certificate needs it).
- Copy your game's `Data` folder to the server first, for example: `rsync -a "Data/" you@server:/srv/client/Data/`.

### Check your computer {#doctor}

From the Open Vanilla folder (or wherever you saved `ovhost`):

```
bash host/ovhost doctor
```

It checks Docker and its memory, Rosetta or emulation, compose, Python, disk space, ports 80 and 443, and whether it can find your game. Each problem comes with the command or setting that fixes it. When it says **Ready to host**, go on.

## Set up your realm {#install}

On a Mac, double-click **Host a Realm.command** in the Open Vanilla folder. Anywhere, in a terminal:

```
bash host/ovhost install
```

It asks two things:

1. **Where the realm is played:**
   - **1 · This computer only:** `https://localhost`, for you. Nothing is reachable from the network.
   - **2 · My home network:** you and people on the same Wi-Fi or LAN, at your computer's address (for example `https://192.168.1.20`).
   - **3 · The internet:** a server with a domain name, with a real certificate.
2. **Your game's Data folder** (it looks in the usual places first, and accepts the game folder or its `Data` folder).

Then it works through eight steps, and you can leave it running:

| Step | What happens |
| --- | --- |
| 1 · Checking this machine | Docker, compose, emulation on ARM |
| 2 · Where the realm is played | Your choice, and the ports (8443 if 443 is taken) |
| 3 · Your game's Data folder | It checks the archives are there |
| 4 · Realm files | Downloads the realm's files into the realm folder and writes its settings, with random passwords |
| 5 · Server map data | Builds the server's maps from your game, **once** (the long part) |
| 6 · Starting the realm | Downloads the server (about 2 GB) and starts it |
| 7 · Open Vanilla on top | Classic+ addons, races and classes, the Vanilla Remastered changes |
| 8 · Network | Firewall and, for the internet, a DNS check |

At the end it prints your realm's address and a **setup token**.

### Skip the questions {#install-options}

Everything can be given up front, for scripts and servers:

```
bash host/ovhost install --local --data "$HOME/Games/Vanilla/Data"
bash host/ovhost install --lan --data /srv/client/Data
bash host/ovhost install --domain realm.example.org --data /srv/client/Data --yes
```

| Option | What it does |
| --- | --- |
| `--local` | This computer only (`https://localhost`) |
| `--lan` | Your home network (your computer's LAN address) |
| `--domain NAME` | The internet, at NAME (its DNS must point here) |
| `--data DIR` | Your game folder or its `Data` folder |
| `--dir DIR` | Where the realm lives (default `~/OpenVanillaRealm`; `/opt/openvanilla-host` as root on Linux). Give the same `--dir` to every later command |
| `--https-port N`, `--http-port N` | Other ports than 443 and 80, when they're taken |
| `--native-ports` | Also open the login and world ports (3724, 8085) for the desktop game |
| `--datapack DIR` | Use server maps (`dbc/ maps/ vmaps/ mmaps/`) you built elsewhere, instead of building them here |
| `--yes` | No questions: take the defaults |

### The map build {#maps}

The world server needs maps made from your game: terrain, buildings and **movement maps** (how creatures walk). Building them takes about an hour on a fast computer, several hours on a small server, and longer on Apple Silicon because the builder runs through Rosetta. It only happens once, and running `install` again picks up where it stopped.

To save time on a slow machine, build them on a fast one and copy them over:

1. On the fast computer, install a realm (any mode) and let the maps finish.
2. Copy the maps out: `docker run --rm -v openvanilla-realm_gamedata:/data -v "$PWD:/out" debian:bookworm-slim tar -C /data -cf /out/maps.tar dbc maps vmaps mmaps`
3. On the slow one: unpack `maps.tar` into a folder, then `bash host/ovhost install --datapack /path/to/that/folder`.

## Your first visit {#first-visit}

1. Open the address it printed, for example `https://localhost` or `https://localhost:8443`.
2. On your own computer or home network the browser warns about the certificate **once**: it's your own realm's certificate, not a public one. Choose **Advanced → Continue** (Chrome/Edge), **Show details → visit this website** (Safari) or **Accept the risk** (Firefox).
3. Go to **/setup** (for example `https://localhost/setup`), paste the **setup token**, name your realm and make your admin login.
4. Wait for the world server: the first start takes a few minutes. `bash host/ovhost status` shows it as **healthy** when it's ready.
5. Make a game account on the realm's site (or play as a guest), and play.

Lost the token? `bash host/ovhost token` shows it again.

## Become a GM {#gm}

Your game account's name is on your realm's account page (it looks like `WR000041`). Give it GM powers:

```
bash host/ovhost make-gm WR000041 3
```

Levels: **0** player, **1** moderator, **2** game master, **3** administrator. Log out of the game and back in. In the game, `.gm on` turns GM mode on; the [GM tools](hosting.html#accounts-rules) chapter has the rest.

Run one server command from your terminal, without logging in:

```
bash host/ovhost gm ".server info"
bash host/ovhost gm ".announce The realm restarts at 9pm"
```

The first `gm` makes a console account called **OVHOST** for itself, with a random password kept in `ovhost.secret` in the realm folder.

## Let people in {#players}

| Mode | Who can play | What to give them |
| --- | --- | --- |
| This computer only | You | Nothing: open `https://localhost` |
| Home network | Anyone on your Wi-Fi or LAN | Your address, for example `https://192.168.1.20` (they accept the certificate once) |
| Internet | Anyone | `https://your.domain` (a real certificate, no warning) |

- **Browsers:** Chrome and Edge everywhere; Safari 26 or newer and Firefox 147 or newer on a Mac. On Linux, Chrome has the game's graphics (WebGPU) by default on newer Intel and NVIDIA graphics; for others, turn on `chrome://flags/#enable-unsafe-webgpu`. The Open Vanilla launcher's play window does this for you.
- **Home network from outside:** to let friends in over the internet from home, either use a domain (mode 3) and forward TCP **80** and **443** on your router to this computer, or stay on mode 2 and use a VPN such as Tailscale.
- **The desktop game:** install with `--native-ports`, then players set `realmlist` to your address. Desktop players on a Mac need a Windows compatibility layer; Linux players can use Wine, Proton or Lutris.

> **Never:** Never forward or publish the database. ovhost never publishes it; keep it that way.

## Every day {#daily}

| Command | What it does |
| --- | --- |
| `bash host/ovhost status` | Each part and whether it's healthy, with restart counts |
| `bash host/ovhost up` | Start the realm (it also starts by itself after a reboot, as long as Docker starts) |
| `bash host/ovhost down` | Stop it. The world server saves every character first (up to 5 minutes) |
| `bash host/ovhost logs` | Follow every log; `logs mangosd` for the world server, `logs realm` for the website. Ctrl+C stops following |
| `bash host/ovhost restart-web` | Restart the website and HTTPS only (after a DNS change) |
| `bash host/ovhost token` | The setup token again |
| `bash host/ovhost gm "..."` | One server command |
| `bash host/ovhost make-gm ACCOUNT LEVEL` | GM powers |
| `bash host/ovhost help` | The command list; `help install` and the like for one command |
| `bash host/ovhost manual [SECTION]` | This chapter, in your terminal (`manual trouble` for one section) |

**After a reboot:** on Linux, Docker starts with the computer and the realm comes back by itself. On a Mac, set Docker Desktop or OrbStack to **start at login**.

## Update {#update}

```
bash host/ovhost update
```

It downloads the newest realm files and server, then reapplies Open Vanilla on top. Players are disconnected for a minute or two while the world server restarts; characters are saved first. Update when it's quiet, and back up first.

## Back up and restore {#backup}

```
bash host/ovhost backup
```

A backup holds every account, character and the realm's settings, in `openvanilla-realm/backups/` inside the realm folder. The newest 14 are kept. Copy them somewhere else now and then (another disk, cloud storage).

Back up every night on Linux: `cd ~/OpenVanillaRealm/openvanilla-realm && ./realmctl install-cron`.

Restore one from anywhere on this computer (it stops the game first, then starts it again):

```
bash host/ovhost restore ~/Downloads/realm-YYYYMMDD-HHMMSS.tar.gz
```

## Move to another computer {#move}

1. On the old one: `bash host/ovhost backup`, then copy the newest backup file and (to skip the map build) the maps, see [The map build](#maps).
2. On the new one: `bash host/ovhost install` (with `--datapack` if you copied the maps).
3. Then `bash host/ovhost restore path/to/the/backup.tar.gz`.
4. If the address changed, tell your players the new one.

## Stop for good {#uninstall}

```
bash host/ovhost uninstall           stop and remove the server; characters, accounts and maps are kept
bash host/ovhost uninstall --purge   also delete them (it asks first)
```

The realm folder and your backups stay where they are; delete the folder yourself when you no longer need them. Your game folder keeps the one file the realm added, `patch-Z.MPQ` (the Classic+ files); delete it if you don't want Classic+ in your own game.

## Where things are {#files}

Everything lives in the realm folder: `~/OpenVanillaRealm` (or what you gave with `--dir`).

| Path | What it is |
| --- | --- |
| `ovhost.conf` | The choices made at install (mode, address, ports, game folder) |
| `ovhost.secret` | The OVHOST console account's password (only readable by you) |
| `openvanilla-realm/.env` | The realm's settings and database passwords. Never share or post it |
| `openvanilla-realm/compose.host.yaml` | What this computer needs (ports, Intel emulation on ARM) |
| `openvanilla-realm/compose.override.yaml` | The Open Vanilla server and files |
| `openvanilla-realm/backups/` | Your backups |
| `classicplus/` | The Open Vanilla files the realm serves |

The characters, accounts and maps live in Docker volumes named `openvanilla-realm_db`, `_state` and `_gamedata`, not in the folder.

## Settings you can change {#settings}

Edit `openvanilla-realm/.env`, then `bash host/ovhost up`:

| Setting | What it does |
| --- | --- |
| `MANGOSD_MEM` | The world server's memory limit (`3g` by default; raise it on a big machine) |
| `QUEUE_ENABLED`, `QUEUE_WORLD` | A login queue: `1` and how many may play at once |
| `OPENVANILLA_GUESTS` | `0` turns guest play off |

Game rules (XP rates, bots, the message of the day) are in the world server's own settings, the same as on Windows: see [Rates and rules](hosting.html#accounts-rules) and [Edit your own game](editing.html#realm-rules). To change the address or the mode, run `bash host/ovhost install` again with the new choice.

## Keep it safe {#security}

- Use **This computer only** unless other people need to play.
- On the internet, keep the server updated (`sudo apt upgrade` or your distribution's equivalent) and use SSH keys, not passwords.
- `.env` and `ovhost.secret` hold passwords: never post them in chat or screenshots.
- Make GMs only of people you trust; GM level 3 can do anything on the realm.
- Docker's published ports go around the `ufw` firewall: ovhost publishes only the web ports (and 3724/8085 with `--native-ports`), so the database stays private.

## How big can it get? {#capacity}

Rough guides, not measurements yet:

| Computer | Players | Notes |
| --- | --- | --- |
| Laptop, 8 GB | You and a few friends | Keep random bots off |
| Apple Silicon Mac, 16 GB | 10–20 | Rosetta costs speed; bots few |
| VPS, 2 cores, 4 GB | 10–30 | The cheapest public realm |
| VPS, 4 cores, 8 GB | 30–80 | A modest bot population |

Random bots cost the most memory (about 20 MB each). If the realm lags, lower the bots first, then give Docker more memory.

## Troubleshooting {#trouble}

Run `bash host/ovhost doctor` first: it names most problems and the fix. The messages you may see:

| Message | Fix |
| --- | --- |
| **Docker isn't installed** | Mac: install OrbStack or Docker Desktop. Linux: run `install`, which offers to install it |
| **Docker is installed but not running** | Mac: open Docker Desktop or OrbStack (or `colima start`). Linux: `sudo systemctl enable --now docker` |
| **this ARM machine can't run x86-64 containers yet** | Mac: turn on Rosetta in Docker's settings ([Before you start](#before-mac)). Linux: run `install`, which sets it up |
| **Docker can use only N MB of memory** | Give Docker 6 GB in its settings, or use a bigger server |
| **docker compose ... is too old** | Update Docker Desktop or OrbStack; on Linux update the compose plugin |
| **port 443 is already in use** | Another web server runs here. Install with `--https-port 8443 --http-port 8080`, or stop the other one |
| **rootless Docker/Podman can't use ports 80 and 443** | Use the 8443/8080 options, or `sudo sysctl net.ipv4.ip_unprivileged_port_start=80` |
| **Docker on this Mac can't see** (or **can't read**) a folder | Move the game under your home folder, or add its folder in Docker's file sharing settings |
| **no .MPQ archives under that folder** | Pick your game folder or its `Data` folder (it holds files ending in `.MPQ`) |
| **N GB free ... it needs about 12 GB** | Free disk space, or install on another disk with `--dir` |
| **SteamOS has a read-only system** | Host from a regular Linux install or another computer |
| **DOMAIN points at ..., this server is ...** | Set the domain's A record to the server's address, wait a few minutes, then `bash host/ovhost restart-web` |
| **the world server isn't running** | `bash host/ovhost status`; if it isn't healthy, `bash host/ovhost logs mangosd` |
| **no game account named ...** | Use the account name from your realm's account page, not your character's name |
| **the Open Vanilla step stopped** | The realm itself runs. Read the lines above it, fix that, then run `install` again |

Other problems:

| Problem | Fix |
| --- | --- |
| The world server stays **starting** for a long time | The first start loads for several minutes; on Apple Silicon longer. If it still isn't healthy after 15 minutes, check `logs mangosd` |
| It says the world server is waiting for maps | The map build hasn't finished: run `install` again to continue it |
| The page shows **502** | The website is restarting or the world server is down: `status`, then `up` |
| A black screen in the browser | The browser has no WebGPU: use Chrome or Edge, update it and your graphics driver ([Playing in the browser](browser.html)) |
| Friends at home can't connect | Install in **My home network** mode; check they use your computer's address and accepted the certificate; check the computer's firewall |
| Everything is slow on a Mac | Apple Silicon runs the world server through Rosetta: give Docker more memory and keep bots few |
| I lost the setup token | `bash host/ovhost token` |

Still stuck? Post the output of `bash host/ovhost doctor` and `bash host/ovhost status` in the Discord's #bug-reports (it holds no passwords).

## FAQ {#faq}

**Do I need to know Docker?** No. ovhost runs every Docker command for you. Knowing `status` and `logs` is enough.

**Does it download the game?** No. The realm uses your own Vanilla Client v1.3 files and never sends them anywhere.

**Can I run it next to my Windows realm?** Yes: they're separate. Characters don't move between realms.

**Can I run two realms on one computer?** Yes: give the second one its own `--dir` and other ports (`--https-port 8443 --http-port 8080`).

**Why is the browser warning me?** On your own computer or home network nobody can issue your realm a public certificate, so it makes its own. Accept it once. A realm on the internet with a domain gets a real one.

**Is it the same as the official realm?** The same server and the same Open Vanilla changes, without the official realm's Discord sign-in and login queue. You can turn those on with keys of your own in `.env`.

**Where's the GM console window?** On Mac and Linux it's the terminal: `bash host/ovhost gm "..."`, or GM commands typed in the game.
