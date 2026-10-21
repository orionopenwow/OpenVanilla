# Hosting an Open Vanilla realm on macOS and Linux

Windows hosts run SPP Classics (`Host a Realm.bat`, the launcher's HOST > Dedicated server). SPP is a
Windows program, so macOS and Linux run the same stack the official realm runs instead:
wenilla-realm (CMaNGOS classic, the realm website and the browser game) in Docker, plus the Open
Vanilla images and files. One script does all of it: `host/ovhost`.

```
bash host/ovhost doctor                        what this machine has, and what it still needs
bash host/ovhost install                       guided: asks where it's played and where your game is
bash host/ovhost install --local --data DIR    this computer only (https://localhost)
bash host/ovhost install --lan --data DIR      you and people on your home network
bash host/ovhost install --domain NAME --data DIR   on the internet (a VPS, a home server)
bash host/ovhost up | down | status | logs mangosd | update | backup | restore FILE
bash host/ovhost gm ".server info"             one world-console command
bash host/ovhost make-gm WR000041 3            GM powers for a game account
bash host/ovhost uninstall [--purge]
```

On a Mac, double-click **Host a Realm.command**. `python3 openvanilla_server.py` (the Open Vanilla
Server entry point, SPP on Windows) runs `ovhost` on macOS and Linux: with no arguments the guided
install, otherwise any ovhost command (`python3 openvanilla_server.py status`).

On a server without the repository:

```
curl -fsSL https://raw.githubusercontent.com/orionopenwow/OpenVanilla/stable/host/ovhost -o ovhost
bash ovhost install --domain realm.example.org --data /srv/client/Data
```

## What you need

- **Docker with compose 2.24.4 or newer.**
  - On macOS: OrbStack, Docker Desktop or Colima.
    - Docker Desktop is free for personal use and for companies under 250 people and $10M in revenue.
    - OrbStack is free for personal, non-commercial use.
    - Colima is free and open source.
  - On Linux: Docker Engine. `ovhost install` offers to install it:
    - Ubuntu, Debian, Fedora, RHEL, Rocky and Alma get it from get.docker.com.
    - Mint and Pop!_OS get it from their own packages.
    - Arch uses pacman, openSUSE uses zypper, and Alpine uses apk.
- **Memory:** about 4 GB for Docker. The world server is capped at 3 GB, or 2.5 GB when Docker has less than 5.5 GB.
- **Disk:** about 12 GB free.
- **The game's Data folder, from your own 1.12.1 client.**
  - Nothing is downloaded for you.
  - The realm adds `patch-Z.MPQ` (the Classic+ files) to that folder.
- **python3 (3.8 or newer), curl and tar.**

## Choices it makes, and why

| Situation | What ovhost does |
|---|---|
| Apple Silicon or another ARM machine | The game server images are x86-64 only, so they run through Rosetta or QEMU (`platform: linux/amd64` in `compose.host.yaml`). MariaDB and Caddy stay native. On ARM Linux it sets up QEMU with `tonistiigi/binfmt` and a systemd unit that restores it at boot. |
| "This computer only" | Every port is published on 127.0.0.1 only, so nothing is reachable from the network. |
| Port 443 taken, or rootless Docker/Podman (no ports below 1024) | It uses 8443 and 8080, and the realm's address carries the port (`https://localhost:8443`). |
| A game folder with spaces (`World of Warcraft`) | `.env` values are quoted. realmctl writes the path unquoted, and sourcing it would break. |
| Docker on a Mac can't see the folder | It stops with the fix. Docker Desktop shares /Users, /Volumes, /private and /tmp. Colima shares only your home folder. OrbStack shares everything. |
| SELinux enforcing (Fedora, RHEL) | The realm and game folders get the `container_file_t` label. |
| ufw or firewalld active, LAN or internet mode | It opens the web ports (and 3724/8085 with `--native-ports`). Docker's published ports bypass ufw anyway: to keep something private, don't publish it. |
| SteamOS | It explains instead of installing: SteamOS has a read-only system and no Docker. |

## Files

`~/OpenVanillaRealm`, or `/opt/openvanilla-host` when run as root on Linux. Choose another place with `--dir DIR` on every command.

- `openvanilla-realm/` is the wenilla-realm checkout. It holds:
  - `.env` (secrets, mode 600; `COMPOSE_FILE` adds the next two files);
  - `compose.override.yaml` (the Open Vanilla images and mounts, written by `openvanilla_realm_up.sh`);
  - `compose.host.yaml` (this machine: platform, ports).
- `classicplus/` holds the Open Vanilla files: patch-Z, the page layer and SQL.
- `ovhost.conf` records the choices made at install.
- `ovhost.secret` is the password of the OVHOST console account that `ovhost gm` uses (made on first use).

## Community mode of openvanilla_realm_up.sh

`ovhost` runs `hetzner/openvanilla_realm_up.sh` with `OW_COMMUNITY=1`. This mode:

- needs no root, only ownership of the realm folder;
- uses no `/opt` or `/etc` paths;
- asks no Discord questions. Players sign in with a password or as a guest; to add Discord, put its keys in `.env` and re-run;
- leaves the login queue off unless `.env` turns it on;
- gives no restart countdown, because there is no Herald console account;
- works on macOS too (`shasum` stands in for `sha256sum`).

## Playing

- **The browser game:** use Chrome or Edge, Safari 26+, or Firefox 147+ on a Mac. On Linux, Chrome has WebGPU by default on newer Intel GPUs and NVIDIA on Wayland. The launcher's play window turns it on through Vulkan for other GPUs.
- **The desktop game:** use `--native-ports` and `set realmlist <address>`.
  - **Linux:** runs under Wine, Proton or Lutris (DXVK for d3d9).
  - **Apple Silicon:** only through CrossOver plus winerosetta, which is fragile.

## Launcher on macOS and Linux

- Run `bash play-open-vanilla.sh`, or double-click **Play Open Vanilla.command** on a Mac.
- It needs Python 3.10+ with Tk. Pillow goes into a private environment, so system Python is never touched (PEP 668).
- What changed:
  - folders now open in Finder or the file manager;
  - Chrome, Edge and Brave are found in `/Applications` on a Mac and under their Linux package names;
  - Linux play windows get the WebGPU flags;
  - Play Solo's SPP mode is offered only on Windows; on macOS and Linux a solo realm is `ovhost install --local`.

## Not yet

- **Native arm64 images.** They would remove emulation on Apple Silicon and ARM servers. Plan: build the mangos and realm images on GitHub's free `ubuntu-24.04-arm` runners (public repos), push each by digest, and merge with `docker buildx imagetools create`. Don't build them under QEMU: a 30-minute C++ build becomes hours. Our images are built on upstream's amd64-only base images, so their Dockerfiles first need an arm64 base, or a rebuild from source.
  - Rosetta for Linux VMs may change after macOS 27; native images are the long-term answer.
- **A signed macOS app and a Linux AppImage of the launcher.** Today it runs from source.
- **A window for hosting.** On macOS and Linux, hosting runs in a terminal (`ovhost`). A Docker panel in
  the launcher is easy to add once hosting has a place in the launcher again: its HOST page currently
  redirects to REALMS.
- **Podman.** It works through its Docker-compatible socket with docker compose v2. podman-compose is untested.
