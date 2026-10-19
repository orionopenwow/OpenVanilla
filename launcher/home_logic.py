"""The decisions behind the launcher's HOME page, with no Tk: which PLAY modes to offer, what Solo's next
step is, what the update pill says and what the client button offers.
openvanilla_launcher.py draws them; tests/test_home_logic.py checks them.

Standard library only; Python 3.10 compatible.
"""
# (key, label on the switch, live.json flag that can hide it)
PLAY_MODES = (("online", "ONLINE", "online"), ("solo", "SOLO", "solo"), ("browser", "BROWSER", "browser_play"))


def human_size(n):
    n = float(n or 0)
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n:.0f} {unit}" if unit in ("B", "KB") or n >= 100 else f"{n:.1f} {unit}"
        n /= 1024
    return ""


def play_modes(flags, have_spp=True, have_solo_pack=False):
    """[(key, label)] for the ONLINE | SOLO | BROWSER switch. flags: live.json's flags merged over the defaults.
    Solo needs launcher/spp.py (or the older solo pack, when the maintainer turned solo_pack on). Never empty."""
    out = []
    for key, label, flag in PLAY_MODES:
        if not flags.get(flag, True):
            continue
        if key == "solo" and not (have_spp or (have_solo_pack and flags.get("solo_pack"))):
            continue
        out.append((key, label))
    return out or [("online", "ONLINE")]


def pick_mode(saved, modes):
    keys = [k for k, _ in modes]
    return saved if saved in keys else keys[0]


# Play Solo (launcher/spp.py states): what the bar says and what PLAY does next.
# (ok, headline, detail, bar style, action): ok=True means PLAY is pressable; action is what PLAY does.
def solo_step(state, have_client, running=False, size=None):
    size_txt = f" ({human_size(size)})" if size else ""
    if running:
        return (False, "PLAYING SOLO", "Close the game to stop the solo servers (your characters are saved).",
                "blue", None)
    if state == "missing":
        return (True, f"SOLO · DOWNLOAD SPP CLASSICS{size_txt}",
                "Press PLAY to download SPP Classics (CMaNGOS + playerbots) into Realms\\Solo. Once.", "amber",
                "solo_install")
    if state in ("downloaded", "unpacked"):
        return (True, "SOLO · FINISH SETTING UP SPP CLASSICS",
                "Press PLAY to unpack it and fetch its server files (about 700 MB, resumes if stopped).", "amber",
                "solo_install")
    if state == "base":
        return (True, "SOLO · ONE GUIDED STEP LEFT",
                "Press PLAY: SPP's setup window opens. Type 1, wait for the Vanilla menu, then type 0.", "amber",
                "solo_vanilla")
    if state == "ready" and not have_client:
        return (False, "SOLO · CHOOSE YOUR GAME'S DATA FOLDER",
                "Solo plays with your own Vanilla Client v1.3. Press PLAY to pick its Data folder.", "amber", "choose_install")
    if state == "ready":
        return (True, "READY · SOLO ON THIS PC", "Your own world with playerbots. Log in as SOLO / SOLO.", "blue",
                "solo_play")
    return (False, "SOLO ISN'T AVAILABLE", "This launcher build has no Play Solo module.", "red", None)


SOLO_STEPS = (("missing", "Download SPP Classics"), ("unpacked", "Unpack it and fetch the server files"),
              ("base", "Set up Vanilla (guided: type 1, wait, then 0)"), ("ready", "PLAY"))


def solo_checklist(state):
    """[(label, done, current)] for the Solo page: the four steps in order."""
    cur = {"missing": 0, "downloaded": 1, "unpacked": 1, "base": 2, "ready": 3}.get(state, 0)
    return [(label, i < cur, i == cur) for i, (_, label) in enumerate(SOLO_STEPS)]


def update_pill(update_info, update_ready, download, can_stage, auto_update=True):
    """(text, action) for the small update text beside the bar, or (None, None). The big gold
    UPDATE READY button above PLAY is shown whenever update_ready is set. Actions: apply, retry, download, page."""
    if update_ready:
        return f"Update {update_ready.get('version', '')} ready · restart", "apply"
    if download and not download.get("done"):
        pct = int(max(0.0, min(1.0, download.get("progress") or 0)) * 100)
        return f"Downloading update {pct}%", None
    if download and download.get("error"):
        return "Update failed · retry", "retry"
    if update_info:
        v = update_info.get("version", "")
        if not can_stage:
            return f"Update {v} available", "page"
        if not auto_update and not download:
            return f"Update {v} available · get it", "download"
    return None, None


def client_button(ctype, installed, has_download, busy=False, build=5875):
    """(label, style, action) for HOME's client button, in the left column under the account card.
    action: install (the game setup page), get (get_client: download, pick a folder or the setup page),
    cancel (stop the running download) or web (open the realm's browser client)."""
    if ctype == "web":
        return "OPEN IN BROWSER", "ghost", "web"
    if busy and not installed:
        return "CANCEL DOWNLOAD", "danger", "cancel"
    if ctype == "exe" and not installed:
        if int(build or 0) != 5875:
            return "SET UP CLIENT", "gold", "get"
        return ("GET VANILLA CLIENT V1.3", "gold", "install") if has_download else ("CHOOSE GAME DATA FOLDER", "gold", "install")
    if installed:
        return ("CHANGE WOW FOLDER", "ghost", "get") if ctype == "exe" else ("CLIENT DOWNLOAD", "ghost", "get")
    return ("GET CLIENT", "gold", "get") if has_download else ("SET UP CLIENT", "gold", "get")
