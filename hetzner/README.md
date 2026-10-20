# Open Vanilla Hetzner Cloud VPS Deployment & Migration Kit

Complete, turnkey deployment kit to migrate the **Open Vanilla** stack to a single dedicated **PvE** server in the cloud on **Hetzner**, configured for custom domain **`openvanilla.app`**.

---

## Architecture Overview

```
                      [ Players / Browsers / Desktop Launcher ]
                                      │
                                      ▼
                        HTTPS (443) / DNS: openvanilla.app
                                      │
                       ┌──────────────┴──────────────┐
                       │   Caddy Reverse Proxy (TLS) │
                       │    (Auto Let's Encrypt)     │
                       └──────────────┬──────────────┘
                                      │
                 ┌────────────────────┼────────────────────┐
                 ▼                    ▼                    ▼
        Static & Downloads      WebSocket Relay      Auth & World Ports
         (www/ & downloads/)    (127.0.0.1:18090)    (Direct TCP)
                 │                    │                    │
                 ▼                    ▼                    ▼
          asset_server.py      realmd (3724)        mangosd (8085)
                 │                    │                    │
                 └────────────────────┴────────────────────┘
                                      │
                                      ▼
                          MariaDB Database (3306)
                   (classicrealmd, classiccharacters, classicmangos)
```

---

## 1. Recommended Hetzner VPS Specs

| Specification | Recommendation | Notes |
| :--- | :--- | :--- |
| **Server Type** | **Hetzner Cloud CPX31** (or CCX23 Dedicated) | 4 AMD vCPUs, 8 GB RAM, 160 GB NVMe |
| **Location** | Falkenstein / Nuremberg / Ashburn | Choose closest to your community |
| **Operating System** | **Ubuntu 24.04 LTS** (or Debian 12) | Standard 64-bit |
| **Estimated Cost** | ~€14 - €18 / month | Exceptional performance & low ping |

---

## 2. DNS Setup for `openvanilla.app`

In your domain registrar (Cloudflare, Namecheap, Google Domains, etc.), create these DNS records:

| Type | Host | Value | TTL |
| :--- | :--- | :--- | :--- |
| **A** | `@` | `<Your_Hetzner_Server_IPv4>` | Auto / 300 |
| **A** | `www` | `<Your_Hetzner_Server_IPv4>` | Auto / 300 |
| **AAAA** (Optional) | `@` | `<Your_Hetzner_Server_IPv6>` | Auto / 300 |

> **Note:** If using Cloudflare, turn proxy status to **DNS Only (Grey Cloud)** initially so Caddy can perform the initial ACME HTTP-01 challenge for automated Let's Encrypt certificates.

---

## 3. Step-by-Step Migration from Local PC

### Step A: Export Local Database
On your Windows PC in the `AdventureWorld` directory, simply double-click:
```cmd
archive\Export_Database_For_Hetzner.bat
```
*(or run `python hetzner/export_local_db.py`)*

This dumps all accounts, characters, and world database state into `hetzner/database/dumps/`:
- `classicrealmd.sql`
- `classiccharacters.sql`
- `classicmangos.sql`

### Step B: Upload Repository to Hetzner VPS
From PowerShell on your local PC:
```powershell
scp -r C:\path\to\OpenVanilla root@<HETZNER_IP>:/root/openvanilla_src
```

### Step C: Run the 1-Command Bootstrap
SSH into your Hetzner VPS and run:
```bash
ssh root@<HETZNER_IP>
cd /root/openvanilla_src/hetzner
chmod +x setup_hetzner.sh backup_cron.sh
sudo bash setup_hetzner.sh
```

The script automatically:
1. Installs Caddy, MariaDB, Python3, and security dependencies.
2. Configures the UFW firewall (SSH, HTTP/HTTPS, realmd 3724, mangosd 8085).
3. Creates user `openvanilla` and copies project files to `/opt/openvanilla`.
4. Imports your database snapshots and syncs the realm record to `openvanilla.app:8085` (PvE).
5. Deploys Caddy with automated HTTPS for `openvanilla.app`.
6. Sets up systemd daemons and the automated 04:00 UTC daily backup cron.

---

## 4. Master Link Configuration (`links.txt`)

Both the web portal and the desktop launcher read directly from `links.txt`:
```ini
DOMAIN = openvanilla.app
PORTAL_URL = https://openvanilla.app/
REALM_HOST = <HETZNER_IP>
REALM_PORT = 3724
REALM_NAME = Vanilla Remastered
REALM_TYPE = PvE

DISCORD_INVITE = https://discord.gg/r6nj5p8U4
CLIENT_DOWNLOADS = TEMP        # TEMP = setup guide links, PACKED = client zips
OPENVANILLA_CLIENT_URL = https://github.com/orionopenwow/OpenVanilla/releases/latest
```

When you edit this file in Windows Notepad, upload it to `/opt/openvanilla/links.txt`. The website and launcher reflect the new URLs immediately without recompiling.

---

## 5. Discord: the Herald

The Herald (`herald.py`) runs the Discord gate and the website's sign-up feed. Install it on the realm server with
`bash herald_up.sh` (asks for the bot token and server ID once). Turn on **Server Members Intent** in the
Developer Portal (your app → Bot → Privileged Gateway Intents) first.

- **The way in:** Outsider (just joined, sees only #welcome) → answers the Herald's rules question → Recruit
  (can make a realm account) → signs in with Discord → Adventurer (full access). Every step is logged in #gatehouse.
- **Anti-raid:** a burst of joins bars the gate and raises verification
  (`/lockdown on|off` by hand), and Outsiders who never pass the gate are removed after 48 h.
  Optional: `MIN_ACCOUNT_AGE_DAYS=3` makes brand-new Discord accounts wait (off by default).
- **Sign-ups:** `SIGNUP_MODE=open` (default) or `waves` in `/opt/wenilla-realm/.env`; re-run `openvanilla_realm_up.sh`
  and `herald_up.sh` after changing it.
- **Feed:** `https://<realm>/community/feed.json`, read by the website's Arrivals panel.

### Moderation desk (reports)

Players report from any player menu, chat name, the Dungeons board, Guilds cards, Persona profiles and the
Social window (`Report...`, WenillaCore/Report.lua). The world server (pending patch
`realm/mangos/pending/0006-openvanilla-reports.patch`, tables in `realm/classicplus/pending/classicplus_reports.sql`)
stores each report with the chat it saw between the two players. Herald (`bot/herald_mod.py`) polls the reports
every 15 s, scores them (an OpenAI-compatible model when `MOD_AI_URL`/`MOD_AI_KEY` are set, rules otherwise) and
posts a card in **#moderation** with Dismiss / Warn / Mute 1h / Mute 24h / Kick / Ban / Escalate (staff only).
The AI never kicks or bans: Herald alone only hides repeated spam (the world server does that) and mutes for
10 minutes on hard evidence, both with an Undo. Appeals: `/appeal <text>` in game, or a DM to Herald
(`appeal <character> <text>`). Untouched reports are deleted after 90 days.

Setup: run the SQL, then re-run `herald_up.sh` (it grants Herald's database login the report tables and writes a
dashboard token, `MOD_STAFF_TOKENS=name:token,...`, to `/etc/openvanilla-herald.env`; give each moderator their own).

**The web dashboard.** Herald serves it on `MOD_DASH_HOST:MOD_DASH_PORT` (default `127.0.0.1:8787`): `/mod/` is
the page (`www/mod.html`, copied to `/opt/openvanilla-herald/mod.html`) and `/mod/api/*` the JSON. Caddy runs in
Docker, so let Herald listen on the Docker host gateway instead of loopback, never on a public address:

```
# /etc/openvanilla-herald.env
MOD_DASH_HOST=172.17.0.1        # docker0: reachable from containers, not from the internet
```

and give the Caddy service `extra_hosts: ["host.docker.internal:host-gateway"]` in the compose file. Then add this
inside the realm's site block in the Caddyfile that `openvanilla_realm_up.sh` writes (before the final `handle`):

```
	# Herald's moderation dashboard: staff only (token cookie or Bearer). The page itself is public HTML
	# with no data; every /mod/api/ call is checked by Herald, and Caddy turns away calls without credentials.
	handle /mod/* {
		@modanon {
			path /mod/api/*
			not path /mod/api/login
			not header Cookie *ow_staff=*
			not header Authorization "Bearer *"
		}
		respond @modanon 401
		reverse_proxy host.docker.internal:8787 {
			header_up X-Forwarded-Proto {scheme}
		}
	}
	handle /mod {
		redir * /mod/ 308
	}
```

Open `https://<realm>/mod/`, paste your token once (it becomes an HttpOnly, SameSite=Strict, Secure cookie
scoped to `/mod`). Every write also needs the `X-OW-Staff: 1` header the page sends, and every action is logged
with your name. Firewall: keep 8787 closed to the outside (`ufw deny 8787` if ufw is on).

## 6. Daily Backups & Management Commands

### Check service status:
```bash
systemctl status openvanilla-backend.service
systemctl status caddy
systemctl status mariadb
```

### View live logs:
```bash
journalctl -u openvanilla-backend.service -f
journalctl -u caddy -f
```

### Manual backup:
```bash
/opt/openvanilla/backup_cron.sh
```
Backups are archived in `/opt/openvanilla/backups/openvanilla_backup_YYYYMMDD_HHMMSS.tar.gz` with 14-day automatic rotation.

---

## 7. Server Studio (preview)

Server Studio is Open Vanilla's admin web app: services, players and roles, bans, messages, timed restarts, backups and realm settings, with a history you can undo. On the wenilla-realm Docker stack it runs on the VPS itself and listens on `127.0.0.1:18091` only; Caddy never proxies it.

```bash
pip3 install --break-system-packages aiohttp pymysql psutil
cp /opt/openvanilla/hetzner/systemd/openvanilla-studio.service /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now openvanilla-studio
```

It reads the database password from `/opt/wenilla-realm/.env` (`DB_ROOT_PASSWORD`) and finds the `mariadb` and `mangosd` containers by their compose service names (override with `STUDIO_DB_SERVICE` / `STUDIO_WORLD_SERVICE`). Backups go to `/opt/openvanilla/studio_state/backups/`.

Use it from your PC through an SSH tunnel, then open <http://localhost:18091/studio/> and sign in with a GM 3 account:

```bash
ssh -L 18091:127.0.0.1:18091 root@<HETZNER_IP>
```

## 8. Updating without restarts (hot updates)

Most changes no longer need an image rebuild or a realm restart. Push to `main` and
`.github/workflows/hotpatch.yml` runs `hetzner/openvanilla_hotpatch.sh` on the server over SSH; it
ships only what changed, with the smallest restart each change needs:

| what changed | restart | how long |
|---|---|---|
| `realm/www/*` (page layer: account dock, boot art, owdiag), `bridge.js`, `addons-loader.js` | none, players get it on their next page load | ~1 min after the push |
| SQL on loot, gossip, vendor, trainer or quest-relation tables | none, `.reload` over SOAP | ~1 min |
| `realm/classicplus/patch-Z.MPQ` (addons, client DBCs, art), a new realm image | web service only (~5 s, world keeps running); waits for an empty realm, up to 30 min | minutes |
| `playercreateinfo` SQL, server DBC files | world restart, **queued**: run the workflow by hand with "world restart" (5-minute in-game countdown) | when it suits you |

`realm/classicplus/**` and `realm/www/**` no longer trigger the 40-minute image build; only
engine patches (`realm/patches`) and the Dockerfile do.

One-time setup: add the repository secrets `REALM_SSH_HOST` and `REALM_SSH_KEY` (see the header of
`hotpatch.yml`). By hand on the server: `bash /opt/openvanilla-classicplus/openvanilla_hotpatch.sh --dry-run`.

## 9. The test bot (owdiag / owbot)

* In any browser on the realm: open the play page with `?diag=1` (report in the console) or run
  `await owdiag.run('full')` in the console. One compact JSON report: counts for passing checks,
  a one-line reason for each failure. `owdiag.diff()` shows what broke or got fixed since the
  last run; `owdiag.bot(10)` walks around for ten minutes sampling the checks.
* Headless, against the live realm, as **Herald** (a Human Hunter): `.github/workflows/owbot.yml`
  (nightly, after each hotpatch, or by hand) runs `tools/owbot.mjs`, which signs in, enters the
  world on CPU WebGPU, runs the checks and Herald's data routines, and puts a dozen-line summary in
  the run summary (full JSON as the `owbot-report` artifact). Secrets: `REALM_URL`, `OWBOT_USER`,
  `OWBOT_PASS` (a web login made for the bot in the admin panel; sign in as it once and make its
  one character, Herald, a Human Hunter), and optionally `OWBOT_WEBHOOK` (a Discord webhook for the
  summary). From your PC: `tools\Run_Herald.bat` (reads the same names from `.env`).
* Herald's data routines (`realm/www/owdiag-capture.js`, `await owdiag.snapshot()` in the console)
  read the game into compact JSON with no screenshots: character and position, skills, gear, bags,
  spellbook, quest log, the Classic+ suite and server hook, Persona, nearby enemies and key settings. Each routine is one Lua
  round trip; a full snapshot is a few KB.
* The checks are a plain list in `realm/www/owdiag-checks.js`. Every fixed bug adds one.
