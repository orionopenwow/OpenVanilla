import os
import re
import sys
import time
import json
import shutil
import socket
import subprocess
import threading
import webbrowser
import urllib.error
import urllib.parse
import urllib.request
import xml.sax.saxutils
import tkinter as tk
from tkinter import ttk, messagebox, scrolledtext
from PIL import Image, ImageTk

try:
    import psutil
except ImportError:
    psutil = None

import server_control
import play_local as solo  # PLAY SOLO: the offline server pack, its servers and the busy-realm check
from authcheck import verify_realm_login

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
ASSETS_DIR = os.path.join(BASE_DIR, "assets")

# Buttons are drawn by the launcher's own art (launcher/launcher_art.py) so the Server Host and the launcher
# share one look: rounded pills, an embossed label, one line-icon set. Without it, a plain styled button.
sys.path.insert(0, os.path.join(BASE_DIR, "launcher"))
try:
    import launcher_art as art
    art.FONT_DIRS.insert(0, os.path.join(BASE_DIR, "launcher", "assets", "launcher", "fonts"))
except Exception:  # pragma: no cover - the server download always ships it
    art = None

# Text: Arial Rounded MT Bold (comes with Microsoft Office) when installed, else Nunito, bundled in
# launcher/assets/launcher/fonts and loaded for this program only. Numbers and logs stay Consolas.
RF = "Segoe UI"
FONTS_DIR = os.path.join(BASE_DIR, "launcher", "assets", "launcher", "fonts")


def pick_ui_font(root):
    """The rounded face for every label in the window (called once the Tk root exists)."""
    global RF
    import tkinter.font as tkfont
    fams = set(tkfont.families(root))
    if "Arial Rounded MT Bold" in fams:
        RF = "Arial Rounded MT Bold"
        return RF
    nunito = os.path.join(FONTS_DIR, "Nunito.ttf")
    if os.name == "nt" and os.path.isfile(nunito):
        try:
            import ctypes
            ctypes.windll.gdi32.AddFontResourceExW(nunito, 0x10, 0)   # FR_PRIVATE: this process only
            fams = set(tkfont.families(root))
        except Exception:
            pass
    if "Nunito" in fams:
        RF = "Nunito"
    return RF


CARD_BG = "#11131a"
PAGE_BG = "#0b0c10"
BTN_FG = {"gold": "#3b2106", "violet": "#ece6da", "danger": "#ffe9e4", "ghost": "#f0dca8"}


class PillButton(tk.Label):
    """One button style for the whole window: style gold (the main action), violet (play in the browser),
    danger (stop) or ghost (everything else); an optional line icon; hover glow; disabled = dimmed.
    Accepts config(text=..., state=..., command=...) like a tk.Button."""

    def __init__(self, parent, text, command=None, style="ghost", width=280, height=30, icon=None, size=9, bg=None):
        self._bg = bg or parent.cget("bg")
        super().__init__(parent, bg=self._bg, bd=0, highlightthickness=0, cursor="hand2")
        self._text, self._command, self._style, self._icon, self._size = text, command, style, icon, size
        self._pw, self._ph, self._state, self._imgs = width, height, "normal", {}
        self._render()
        self.bind("<Enter>", lambda e: self._show("hover"))
        self.bind("<Leave>", lambda e: self._show("normal"))
        self.bind("<Button-1>", lambda e: self._click())

    def _face(self, hover, disabled=False):
        fg = BTN_FG.get(self._style, BTN_FG["ghost"])
        ic = None
        if self._icon:
            ic = art.icon(self._icon, 15, "#d9b25f" if self._style == "ghost" else fg)
        base = art.pill(self._pw, self._ph, self._style, hover)
        im = art.button_face(base, self._text, round(self._size * 1.45) + 1, fg, engraved=(self._style == "gold"),
                             icon_img=ic, face="rounded")
        if disabled:
            alpha = im.getchannel("A").point(lambda a: a * 45 // 100)
            im.putalpha(alpha)
        page = Image.new("RGBA", im.size, self._bg)
        page.alpha_composite(im)
        return ImageTk.PhotoImage(page)

    def _render(self):
        if art is None:
            self.config(text=self._text, fg="#f0dca8", font=(RF, 9, "bold"), padx=10, pady=4)
            return
        self._imgs = {"normal": self._face(False), "hover": self._face(True), "disabled": self._face(False, True)}
        self._show("normal")

    def _show(self, which):
        if art is None:
            return
        if self._state == "disabled":
            which = "disabled"
        super().config(image=self._imgs[which])

    def _click(self):
        if self._state != "disabled" and self._command:
            self.after(10, self._command)

    def config(self, **kw):
        changed = False
        if "text" in kw:
            self._text = kw.pop("text"); changed = True
        if "state" in kw:
            self._state = kw.pop("state")
            super().config(cursor="arrow" if self._state == "disabled" else "hand2")
        if "command" in kw:
            self._command = kw.pop("command")
        if kw:
            super().config(**kw)
        if changed:
            self._render()
        else:
            self._show("normal")

    configure = config

SPP_ROOT = os.environ.get("SPP_ROOT", os.path.join(os.path.expanduser("~"), "Desktop", "Games", "SPP_Classics_V2", "SPP_Server"))
DB_DIR = os.path.join(SPP_ROOT, r"Server\Database")
DB_BIN = os.path.join(DB_DIR, r"bin\mysqld.exe")
DB_INI = os.path.join(DB_DIR, "SPP-Database.ini")

BIN64_DIR = os.path.join(SPP_ROOT, r"Server\Binaries\vanilla\Bin64")
SETTINGS_DIR = os.path.join(SPP_ROOT, r"Settings\vanilla")
REALMD_EXE = os.path.join(BIN64_DIR, "realmd.exe")
MANGOSD_EXE = os.path.join(BIN64_DIR, "mangosd.exe")

ASSET_SERVER_SCRIPT = os.path.join(BASE_DIR, "asset_server.py")
LAUNCHER_CONFIG = os.path.join(BASE_DIR, "launcher_settings.json")
CADDY_CONFIG = os.path.join(BASE_DIR, "Caddyfile")
LOCAL_WEB_PORT = 18090
WEB_LOG = os.path.join(BASE_DIR, "web-backend.log")
DETACHED_FLAGS = 0x00000008 | 0x00000200  # DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP
PUBLIC_HTTPS_PORT = 8090

def load_launcher_config():
    try:
        with open(LAUNCHER_CONFIG, "r", encoding="utf-8") as config_file:
            data = json.load(config_file)
            return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}

processes = {
    "db": None,
    "realmd": None,
    "mangosd": None,
    "web": None,
}

def is_port_open(port):
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(0.25)
        res = s.connect_ex(("127.0.0.1", port))
        s.close()
        return res == 0
    except Exception:
        return False

def get_lan_ipv4():
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect(("192.0.2.1", 1))
        return probe.getsockname()[0]
    except OSError:
        return "<this PC's LAN IP>"
    finally:
        probe.close()

def running_web_backend():
    """Return (pid, codeVersion) reported by the backend on LOCAL_WEB_PORT, or (None, None)."""
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{LOCAL_WEB_PORT}/api/status", timeout=3) as r:
            data = json.load(r)
        return data.get("pid"), data.get("codeVersion")
    except (OSError, ValueError):
        return None, None

def kill_pid(pid):
    subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)

def start_web_backend():
    """Start asset_server.py detached from this window, logging to web-backend.log."""
    log = open(WEB_LOG, "a", encoding="utf-8", errors="replace")
    log.write(f"\n===== web backend start {time.strftime('%Y-%m-%d %H:%M:%S')} =====\n")
    log.flush()
    env = dict(os.environ, PYTHONUNBUFFERED="1")
    return subprocess.Popen([sys.executable, ASSET_SERVER_SCRIPT, str(LOCAL_WEB_PORT)], cwd=BASE_DIR,
                            creationflags=DETACHED_FLAGS, stdin=subprocess.DEVNULL,
                            stdout=log, stderr=subprocess.STDOUT, env=env)

def get_process_metrics(process_name):
    """Return (cpu_percent, memory_mb) for given process name, or (None, None)."""
    if not psutil:
        return None, None
    total_cpu = 0.0
    total_rss = 0
    found = False
    try:
        for p in psutil.process_iter(['name', 'cpu_percent', 'memory_info']):
            try:
                if p.info['name'] and p.info['name'].lower() == process_name.lower():
                    found = True
                    total_cpu += p.info['cpu_percent'] or 0.0
                    if p.info['memory_info']:
                        total_rss += p.info['memory_info'].rss
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                pass
    except Exception:
        pass
    if found:
        mb = total_rss / (1024 * 1024)
        return total_cpu, mb
    return None, None


def process_start_time(process_name):
    """Epoch start time of the oldest process with this name, or None (needs psutil)."""
    if not psutil:
        return None
    times = []
    for p in psutil.process_iter(["name", "create_time"]):
        try:
            if (p.info["name"] or "").lower() == process_name.lower():
                times.append(p.info["create_time"])
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            continue
    return min(times) if times else None


def soap_command(command, user, password, port=7878):
    """Run one console command on mangosd through its SOAP listener and return the text reply."""
    import base64
    body = (
        '<?xml version="1.0" encoding="utf-8"?>'
        '<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/" '
        'xmlns:ns1="urn:MaNGOS"><SOAP-ENV:Body><ns1:executeCommand><command>'
        + xml.sax.saxutils.escape(command) +
        '</command></ns1:executeCommand></SOAP-ENV:Body></SOAP-ENV:Envelope>'
    ).encode("utf-8")
    auth = base64.b64encode(f"{user}:{password}".encode("utf-8")).decode("ascii")
    req = urllib.request.Request(f"http://127.0.0.1:{port}/", data=body, method="POST", headers={
        "Content-Type": "text/xml; charset=utf-8", "Authorization": f"Basic {auth}"})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            text = r.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as e:
        text = e.read().decode("utf-8", errors="replace")
    entities = {"&#xD;": "", "&#xA;": "\n", "&#13;": "", "&#10;": "\n", "&quot;": '"', "&apos;": "'"}
    m = re.search(r"<result>(.*?)</result>", text, re.S)
    if m:
        return xml.sax.saxutils.unescape(m.group(1), entities).strip()
    fault = re.search(r"<faultstring>(.*?)</faultstring>", text, re.S)
    raise RuntimeError(xml.sax.saxutils.unescape(fault.group(1)).strip() if fault else "unexpected SOAP reply")


class WarcraftLauncher(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("Open Vanilla Server Host")
        self.geometry("1024x700")
        self.minsize(1010, 620)
        self.configure(bg="#0b0c10")
        pick_ui_font(self)

        self.images = {}
        self.settings = load_launcher_config()
        self.public_gateway = None
        self._starting = False
        self.start_time = time.time()
        self.all_log_entries = []
        self.active_log_filter = "ALL"

        self.spark_mysql_data = []
        self.spark_mangos_data = []
        self.online_players = None

        self.auto_start_services_var = tk.BooleanVar(value=bool(self.settings.get("auto_start_services", False)))
        self.auto_start_https_var = tk.BooleanVar(value=bool(self.settings.get("auto_start_https", False)))
        self.public_url_var = tk.StringVar(value=self.settings.get("public_url", ""))
        self.realm_addr_var = tk.StringVar(value=self.settings.get("realm_address", "127.0.0.1"))

        self._load_assets()
        self._build_ui()
        self._apply_dark_window_chrome()
        self._poll_status()
        self._poll_telemetry()
        self._poll_players()
        self.solo_session = None
        self.solo_dialog = None
        self.busy_tracker = solo.BusyTracker()
        self.busy_dismissed = None
        self.protocol("WM_DELETE_WINDOW", self._on_close)
        self.after(4000, self._poll_live_realm)
        if self.auto_start_services_var.get():
            self.after(750, self.start_all)

    def _apply_dark_window_chrome(self):
        """Removes the bright default Windows title bar and enables rounded edges."""
        try:
            import ctypes
            from ctypes import wintypes
            self.update_idletasks()
            hwnd = ctypes.windll.user32.GetParent(self.winfo_id())
            if not hwnd:
                hwnd = self.winfo_id()

            # 1. Dark Mode titlebar: DWMWA_USE_IMMERSIVE_DARK_MODE (20 on Win11/Win10 20H1+, 19 on older Win10)
            dark_val = ctypes.c_int(1)
            ctypes.windll.dwmapi.DwmSetWindowAttribute(
                wintypes.HWND(hwnd), ctypes.c_uint(20), ctypes.byref(dark_val), ctypes.sizeof(dark_val)
            )
            ctypes.windll.dwmapi.DwmSetWindowAttribute(
                wintypes.HWND(hwnd), ctypes.c_uint(19), ctypes.byref(dark_val), ctypes.sizeof(dark_val)
            )

            # 2. Window corner preference: DWMWA_WINDOW_CORNER_PREFERENCE (33) -> DWMWCP_ROUND (2)
            corner_val = ctypes.c_int(2)
            ctypes.windll.dwmapi.DwmSetWindowAttribute(
                wintypes.HWND(hwnd), ctypes.c_uint(33), ctypes.byref(corner_val), ctypes.sizeof(corner_val)
            )

            # 3. Caption background color: DWMWA_CAPTION_COLOR (35) -> #0b0c10 (BGR: 0x00100c0b)
            color_val = ctypes.c_int(0x00100c0b)
            ctypes.windll.dwmapi.DwmSetWindowAttribute(
                wintypes.HWND(hwnd), ctypes.c_uint(35), ctypes.byref(color_val), ctypes.sizeof(color_val)
            )

            # 4. Caption text color: DWMWA_TEXT_COLOR (36) -> #f3d179 (BGR: 0x0079d1f3)
            text_color_val = ctypes.c_int(0x0079d1f3)
            ctypes.windll.dwmapi.DwmSetWindowAttribute(
                wintypes.HWND(hwnd), ctypes.c_uint(36), ctypes.byref(text_color_val), ctypes.sizeof(text_color_val)
            )
        except Exception:
            pass

    def _load_assets(self):
        def load_img(name, size=None):
            path = os.path.join(ASSETS_DIR, name)
            if os.path.exists(path):
                try:
                    im = Image.open(path)
                    if size:
                        im = im.resize(size, Image.Resampling.LANCZOS)
                    return ImageTk.PhotoImage(im)
                except Exception as e:
                    print(f"Error loading {name}: {e}")
            return None

        # 1. Proportional Authentic Open Vanilla header logo (185x105)
        self.images["logo"] = load_img("openvanilla_logo_proportional.png", (185, 105))
        if not self.images["logo"]:
            self.images["logo"] = load_img("openvanilla_logo_hero.png", (185, 105))

        # 2. Status gem LEDs
        self.images["gem_green"] = load_img("gem_green_24.png", (20, 20))
        self.images["gem_amber"] = load_img("gem_amber_24.png", (20, 20))
        self.images["gem_red"] = load_img("gem_red_24.png", (20, 20))

    def pill(self, parent, text, command, style="ghost", width=280, height=30, icon=None, size=9):
        return PillButton(parent, text, command, style=style, width=width, height=height, icon=icon, size=size)

    def _create_card_header(self, parent, title):
        frame = tk.Frame(parent, bg="#11131a")
        frame.pack(fill="x", pady=(2, 6))
        tk.Frame(frame, bg="#4a3b22", height=1).pack(side="left", fill="x", expand=True, padx=(8, 6))
        tk.Label(frame, text=title, fg="#f3d179", bg="#11131a", font=(RF, 9, "bold")).pack(side="left")
        tk.Frame(frame, bg="#4a3b22", height=1).pack(side="left", fill="x", expand=True, padx=(6, 8))
        return frame

    def _build_ui(self):
        # 1. Header Frame
        header = tk.Frame(self, bg="#0b0c10")
        header.pack(fill="x", padx=16, pady=(8, 2))

        # Top-left Tutorial & Info badge
        top_left_box = tk.Frame(header, bg="#0b0c10")
        top_left_box.pack(side="left", anchor="nw", pady=(10, 0))

        self.pill(top_left_box, "Host Guide", self.open_host_tutorial, width=170, height=28, icon="help",
                  size=8).pack(anchor="w")

        def open_studio():
            # Server Studio starts with the website (asset_server.py) on its own local-only port.
            if is_port_open(18091):
                webbrowser.open("http://localhost:18091/studio/")
            else:
                messagebox.showinfo("Server Studio", "Server Studio starts together with the website.\n\n"
                                    "Press START / RESTART ALL SERVICES, wait for the web light to turn green, then try again.", parent=self)

        self.pill(top_left_box, "Server Studio", open_studio, width=170, height=28, icon="web",
                  size=8).pack(anchor="w", pady=(5, 0))

        tk.Label(top_left_box, text="Standalone Host Edition", fg="#64748b", bg="#0b0c10", font=(RF, 7)).pack(anchor="w", pady=(2, 0))

        # Center logo container
        center_box = tk.Frame(header, bg="#0b0c10")
        center_box.pack(side="left", fill="x", expand=True, padx=(30, 0))

        if self.images.get("logo"):
            lbl_logo = tk.Label(center_box, image=self.images["logo"], bg="#0b0c10", bd=0)
            lbl_logo.pack(anchor="center")
        else:
            tk.Label(center_box, text="OPEN VANILLA", fg="#f0c050", bg="#0b0c10", font=(RF, 22, "bold")).pack()

        tk.Label(center_box, text="YOUR OWN VANILLA REALM — BROWSER ENGINE",
                 fg="#c89b3c", bg="#0b0c10", font=(RF, 8, "bold")).pack(pady=(2, 4))

        # Top-right telemetry panel
        telemetry = tk.Frame(header, bg="#0b0c10")
        telemetry.pack(side="right", anchor="ne", padx=(0, 8), pady=(10, 0))

        self.lbl_uptime = tk.Label(telemetry, text="Server Uptime: 0h 00m", fg="#94a3b8", bg="#0b0c10", font=(RF, 8), anchor="e")
        self.lbl_uptime.pack(anchor="e")
        self.lbl_players = tk.Label(telemetry, text="Players online: --", fg="#94a3b8", bg="#0b0c10", font=(RF, 8), anchor="e")
        self.lbl_players.pack(anchor="e")
        self.lbl_realm_stat = tk.Label(telemetry, text="Realm: Vanilla", fg="#94a3b8", bg="#0b0c10", font=(RF, 8), anchor="e")
        self.lbl_realm_stat.pack(anchor="e")

        # Busy-realm banner (hidden until the live realm is full, slow or down): offers Play Solo.
        self.busy_banner = tk.Frame(self, bg="#2a1f0e", highlightbackground="#c89b3c", highlightthickness=1)
        self.lbl_busy = tk.Label(self.busy_banner, text="", fg="#fde7b0", bg="#2a1f0e", font=(RF, 9),
                                 anchor="w", justify="left")
        self.lbl_busy.pack(side="left", fill="x", expand=True, padx=(10, 6), pady=5)
        tk.Button(self.busy_banner, text="\u2715", command=self._dismiss_busy_banner, bg="#2a1f0e", fg="#c8b48a",
                  activebackground="#3a2b14", activeforeground="#ffffff", relief="flat", bd=0, padx=6,
                  font=(RF, 9), cursor="hand2").pack(side="right", padx=(0, 6))
        PillButton(self.busy_banner, "Play Solo now", self.play_solo, style="gold", width=150, height=28, icon="play",
                   size=8).pack(side="right", padx=4, pady=4)

        # 2. Main Content Split: 3 Columns
        body = tk.Frame(self, bg="#0b0c10")
        body.pack(fill="both", expand=True, padx=16, pady=(2, 10))
        self.body_frame = body

        # ==========================================
        # COLUMN 1: LEFT (Infrastructure & Gateway)
        # ==========================================
        col_left = tk.Frame(body, bg="#0b0c10", width=316)
        col_left.pack(side="left", fill="both", expand=False, padx=(0, 8))
        col_left.pack_propagate(False)

        # Card 1: Realm Infrastructure
        card_infra = tk.Frame(col_left, bg="#11131a", highlightbackground="#3d311d", highlightthickness=1, padx=8, pady=8)
        card_infra.pack(fill="x", pady=(0, 8))

        self._create_card_header(card_infra, "REALM INFRASTRUCTURE")

        infra_rows = tk.Frame(card_infra, bg="#11131a")
        infra_rows.pack(fill="x", padx=4, pady=(2, 2))

        def make_service_row(parent, title):
            row = tk.Frame(parent, bg="#11131a")
            row.pack(fill="x", pady=2)

            orb = tk.Label(row, image=self.images.get("gem_red"), bg="#11131a", bd=0)
            orb.pack(side="left", padx=(0, 5))

            lbl_name = tk.Label(row, text=title, fg="#e2e8f0", bg="#11131a", font=(RF, 8, "bold"), anchor="w")
            lbl_name.pack(side="left")

            lbl_tag = tk.Label(row, text="[OFFLINE]", fg="#f87171", bg="#11131a", font=("Consolas", 8, "bold"))
            lbl_tag.pack(side="right")
            return orb, lbl_tag

        # Row 1: MySQL
        self.orb_db, self.tag_db = make_service_row(infra_rows, "MySQL Database (:3310)")
        sub_db = tk.Frame(infra_rows, bg="#11131a")
        sub_db.pack(fill="x", padx=(25, 0), pady=(0, 2))
        self.lbl_db_metrics = tk.Label(sub_db, text="(-- CPU, -- RAM)", fg="#94a3b8", bg="#11131a", font=("Consolas", 7))
        self.lbl_db_metrics.pack(side="left")
        self.cv_spark_db = tk.Canvas(sub_db, width=34, height=8, bg="#11131a", highlightthickness=0)
        self.cv_spark_db.pack(side="right", padx=(0, 2))

        # Row 2: Auth Server
        self.orb_realm, self.tag_realm = make_service_row(infra_rows, "Auth Server (realmd :3724)")

        # Row 3: World Server
        self.orb_world, self.tag_world = make_service_row(infra_rows, "World Server (mangosd :8085)")
        sub_world = tk.Frame(infra_rows, bg="#11131a")
        sub_world.pack(fill="x", padx=(25, 0), pady=(0, 2))
        self.lbl_world_metrics = tk.Label(sub_world, text="(-- CPU, -- RAM)", fg="#94a3b8", bg="#11131a", font=("Consolas", 7))
        self.lbl_world_metrics.pack(side="left")
        self.cv_spark_world = tk.Canvas(sub_world, width=34, height=8, bg="#11131a", highlightthickness=0)
        self.cv_spark_world.pack(side="right", padx=(0, 2))

        # Row 4: Local Web Backend
        self.orb_web, self.tag_web = make_service_row(infra_rows, "Local web backend (:18090)")

        # Row 5: Public HTTPS Gateway
        self.orb_https, self.tag_https = make_service_row(infra_rows, "Public HTTPS listener (:8090)")

        # Card 2: HTTPS Gateway & Networking
        card_gw = tk.Frame(col_left, bg="#11131a", highlightbackground="#3d311d", highlightthickness=1, padx=8, pady=8)
        card_gw.pack(fill="both", expand=True)

        self._create_card_header(card_gw, "HTTPS GATEWAY & NETWORKING")

        gw_content = tk.Frame(card_gw, bg="#11131a")
        gw_content.pack(fill="x", padx=4)

        # Share server link button (prominent at top of networking)
        share_frame = tk.Frame(gw_content, bg="#11131a")
        share_frame.pack(fill="x", pady=(1, 5))
        self.pill(share_frame, "SHARE SERVER LINK", self.copy_share_link, style="gold", width=288, height=32,
                  icon="link").pack()

        tk.Label(gw_content, text="PUBLIC HTTPS ADDRESS", fg="#f3d179", bg="#11131a", font=(RF, 7, "bold")).pack(anchor="w")
        url_row = tk.Frame(gw_content, bg=CARD_BG)
        url_row.pack(fill="x", pady=(2, 5))
        self.public_url_entry = tk.Entry(
            url_row, textvariable=self.public_url_var, bg="#08090e", fg="#7dd3fc",
            insertbackground="#ffffff", font=("Consolas", 9), relief="sunken", bd=1,
            highlightbackground="#3d311d", highlightthickness=1
        )
        self.public_url_entry.pack(side="left", fill="x", expand=True)
        self.pill(url_row, "Save", self.save_public_url, width=64, height=26, size=8).pack(side="left", padx=(4, 0))

        # Gateway tools: one grid of equal buttons, two to a row
        def tool_row(items):
            row = tk.Frame(gw_content, bg=CARD_BG)
            row.pack(fill="x", pady=2)
            bw = (288 - 4 * (len(items) - 1)) // len(items)
            for i, (label, icon, cmd) in enumerate(items):
                self.pill(row, label, cmd, width=bw, height=26, icon=icon, size=8).pack(side="left", padx=(0 if i == 0 else 4, 0))

        tool_row([("Start HTTPS", "play", self.start_public_gateway), ("Stop HTTPS", "close", self.stop_public_gateway)])
        tool_row([("Test HTTPS", "signal", self.check_public_access), ("Open Site", "web", self.open_public_site)])
        tool_row([("Allow Ports", "shield", self.allow_https_firewall),
                  ("Get Caddy", "download", lambda: webbrowser.open("https://caddyserver.com/download"))])

        # Realm address: what the login server tells game clients to connect to (realmlist.address)
        tk.Label(gw_content, text="REALM ADDRESS (THIS PC, LAN IP OR PUBLIC IP / DOMAIN)", fg="#f3d179", bg="#11131a",
                 font=(RF, 7, "bold")).pack(anchor="w", pady=(5, 0))
        addr_row = tk.Frame(gw_content, bg="#11131a")
        addr_row.pack(fill="x", pady=(2, 2))
        tk.Entry(addr_row, textvariable=self.realm_addr_var, bg="#08090e", fg="#7dd3fc", insertbackground="#ffffff",
                 font=("Consolas", 9), relief="sunken", bd=1, highlightbackground="#3d311d",
                 highlightthickness=1).pack(side="left", fill="x", expand=True)
        self.pill(addr_row, "Save", self.save_realm_address, width=64, height=26, size=8).pack(side="left", padx=(4, 0))

        # Checkboxes
        chk_box = tk.Frame(gw_content, bg="#11131a")
        chk_box.pack(fill="x", pady=(5, 2))
        tk.Checkbutton(
            chk_box, text="Start services on launch", variable=self.auto_start_services_var,
            command=self.save_autostart_settings, fg="#cbd5e1", bg="#11131a",
            activebackground="#11131a", activeforeground="#ffffff", selectcolor="#1d2130",
            font=(RF, 7)
        ).pack(side="left", padx=(0, 6))
        tk.Checkbutton(
            chk_box, text="Start HTTPS on launch", variable=self.auto_start_https_var,
            command=self.save_autostart_settings, fg="#cbd5e1", bg="#11131a",
            activebackground="#11131a", activeforeground="#ffffff", selectcolor="#1d2130",
            font=(RF, 7)
        ).pack(side="left")

        self.lbl_public = tk.Label(
            gw_content, text=f"Forward TCP 80/443/8090 → {get_lan_ipv4()}",
            fg="#94a3b8", bg="#11131a", font=("Consolas", 7), justify="left", wraplength=290
        )
        self.lbl_public.pack(anchor="w", pady=(2, 0))

        # ==========================================
        # COLUMN 2: CENTER (Master Controls & Quick Actions)
        # ==========================================
        col_center = tk.Frame(body, bg="#0b0c10", width=314)
        col_center.pack(side="left", fill="both", expand=False, padx=(0, 8))
        col_center.pack_propagate(False)

        # Card 3: Realm Master Controls
        card_ctrl = tk.Frame(col_center, bg="#11131a", highlightbackground="#3d311d", highlightthickness=1, padx=8, pady=8)
        card_ctrl.pack(fill="x", pady=(0, 8))

        self._create_card_header(card_ctrl, "REALM MASTER CONTROLS")

        ctrl_list = tk.Frame(card_ctrl, bg="#11131a")
        ctrl_list.pack(fill="x", padx=4, pady=2)

        for label, icon, cmd in [
                ("Players & GM Accounts", "account", self.create_account_popup),
                ("Edit Config (Rates & Bots)", "settings", lambda: os.startfile(os.path.join(SETTINGS_DIR, "mangosd.conf"))),
                ("Game Data Folder", "folder", lambda: os.startfile(os.path.join(BASE_DIR, "Data"))),
                ("Backups & Database Tools", "box", self.open_db_toolset),
                ("Realm Website", "community", lambda: webbrowser.open(f"http://127.0.0.1:{LOCAL_WEB_PORT}/index.html"))]:
            self.pill(ctrl_list, label, cmd, width=284, height=32, icon=icon).pack(pady=2)

        # Card 4: Quick Actions
        card_qa = tk.Frame(col_center, bg="#11131a", highlightbackground="#3d311d", highlightthickness=1, padx=8, pady=8)
        card_qa.pack(fill="both", expand=True)

        self._create_card_header(card_qa, "QUICK ACTIONS")

        qa_list = tk.Frame(card_qa, bg="#11131a")
        qa_list.pack(fill="x", padx=4, pady=2)

        self.pill(qa_list, "START / RESTART ALL SERVICES", self.start_all, style="gold", width=284, height=36,
                  icon="refresh").pack(pady=(2, 3))
        self.pill(qa_list, "ENTER WORLD IN BROWSER", self.launch_browser, style="violet", width=284, height=34,
                  icon="web").pack(pady=3)
        self.btn_solo = self.pill(qa_list, "PLAY SOLO  ·  offline on this PC", self.play_solo, width=284, height=32,
                                  icon="play")
        self.btn_solo.pack(pady=(3, 0))
        tk.Label(qa_list, text="Your own offline world with playerbots. Solo characters\n"
                               "stay on this PC: they can't move to the live realm.",
                 fg="#7c8aa0", bg=CARD_BG, font=(RF, 7), justify="center", wraplength=280).pack(pady=(1, 3))
        self.pill(qa_list, "HERALD  ·  let Herald play here", self.open_herald, width=284, height=32,
                  icon="sparkle").pack(pady=3)
        self.pill(qa_list, "HALT ALL SERVICES", self.stop_all, style="danger", width=284, height=32,
                  icon="close").pack(pady=3)

        # ==========================================
        # COLUMN 3: RIGHT (Integrated Logs & Console)
        # ==========================================
        col_right = tk.Frame(body, bg="#0b0c10")
        col_right.pack(side="left", fill="both", expand=True)

        card_logs = tk.Frame(col_right, bg="#11131a", highlightbackground="#3d311d", highlightthickness=1, padx=8, pady=8)
        card_logs.pack(fill="both", expand=True)

        self._create_card_header(card_logs, "INTEGRATED LOGS & SYSTEM MONITOR")

        # Filter Tabs Row
        tab_row = tk.Frame(card_logs, bg="#11131a")
        tab_row.pack(fill="x", padx=4, pady=(1, 4))

        self.tab_buttons = {}
        for tab_name in ["ALL", "REALMD", "MANGOSD", "DB", "HTTP"]:
            lbl_tab = tk.Label(
                tab_row, text=tab_name if tab_name != "ALL" else "ALL LOGS",
                fg="#fbbf24" if tab_name == "ALL" else "#71717a", bg="#11131a",
                font=(RF, 8, "bold"),
                cursor="hand2", padx=5
            )
            lbl_tab.pack(side="left", padx=1)
            lbl_tab.bind("<Button-1>", lambda e, t=tab_name: self._set_log_filter(t))
            self.tab_buttons[tab_name] = lbl_tab

        # Scrolled log console
        self.txt_log = scrolledtext.ScrolledText(
            card_logs, bg="#06070a", fg="#cbd5e1", insertbackground="#4ade80",
            font=("Consolas", 8), relief="sunken", bd=1, highlightthickness=0,
            wrap="word"
        )
        self.txt_log.pack(fill="both", expand=True, padx=4, pady=2)

        # Syntax color tags
        self.txt_log.tag_config("tag_db", foreground="#38bdf8", font=("Consolas", 8, "bold"))
        self.txt_log.tag_config("tag_realm", foreground="#2dd4bf", font=("Consolas", 8, "bold"))
        self.txt_log.tag_config("tag_mangos", foreground="#fbbf24", font=("Consolas", 8, "bold"))
        self.txt_log.tag_config("tag_server", foreground="#facc15", font=("Consolas", 8, "bold"))
        self.txt_log.tag_config("tag_http", foreground="#c084fc", font=("Consolas", 8, "bold"))
        self.txt_log.tag_config("tag_error", foreground="#f87171", font=("Consolas", 8, "bold"))
        self.txt_log.tag_config("tag_success", foreground="#4ade80", font=("Consolas", 8, "bold"))
        self.txt_log.tag_config("tag_dim", foreground="#64748b")
        self.txt_log.tag_config("tag_cmd", foreground="#f43f5e", font=("Consolas", 8, "bold"))

        # GM Command input bar
        cmd_bar = tk.Frame(card_logs, bg="#11131a")
        cmd_bar.pack(fill="x", padx=4, pady=(4, 0))

        tk.Label(cmd_bar, text=">", fg="#fbbf24", bg="#11131a", font=("Consolas", 9, "bold")).pack(side="left", padx=(1, 3))
        self.cmd_entry = tk.Entry(
            cmd_bar, bg="#090a0f", fg="#f8fafc", insertbackground="#f8fafc",
            font=("Consolas", 8), relief="sunken", bd=1, highlightbackground="#3d311d", highlightthickness=1
        )
        self.cmd_entry.pack(side="left", fill="x", expand=True, padx=(0, 4))
        self.cmd_entry.bind("<Return>", lambda e: self._send_gm_cmd())

        self.pill(cmd_bar, "Send", self._send_gm_cmd, width=64, height=26, size=8).pack(side="right")

        self.log("[SERVER] Open Vanilla Launcher initialized. All assets verified.")

    def copy_share_link(self):
        """Copies the public server join link to clipboard and notifies host."""
        url = self.public_url_var.get().strip()
        if not url:
            url = f"https://{get_lan_ipv4()}:{PUBLIC_HTTPS_PORT}"
        if not url.endswith("/"):
            url += "/"

        host_only = ""
        try:
            parsed = urllib.parse.urlsplit(url)
            host_only = parsed.hostname or get_lan_ipv4()
        except Exception:
            host_only = get_lan_ipv4()

        share_text = f"{url}\n\n[For the Vanilla game client]\nset realmlist {host_only}"
        self.clipboard_clear()
        self.clipboard_append(share_text)
        self.update()

        self.log(f"[SERVER] Copied server link to clipboard: {url}")
        messagebox.showinfo(
            "Share Server Link",
            f"Server link copied to your clipboard!\n\n"
            f"Browser WebGPU link:\n{url}\n\n"
            f"Classic Client realmlist:\nset realmlist {host_only}\n\n"
            f"Send this link to friends so they can play directly in their browser or join your realm!",
            parent=self
        )

    def open_host_tutorial(self):
        """Opens the comprehensive host tutorial and guide dialog."""
        w = tk.Toplevel(self)
        w.title("Open Vanilla — Host Tutorial & Architecture Guide")
        w.geometry("640x520")
        w.configure(bg="#11131a")
        w.resizable(False, False)

        tk.Label(w, text="OPENVANILLA SERVER HOST GUIDE", fg="#f3d179", bg="#11131a", font=(RF, 13, "bold")).pack(pady=(12, 2))
        tk.Label(w, text="Complete Quickstart, Networking & GM Management", fg="#94a3b8", bg="#11131a", font=(RF, 8)).pack(pady=(0, 10))

        content = scrolledtext.ScrolledText(w, bg="#08090e", fg="#e2e8f0", font=(RF, 9), relief="sunken", bd=1, padx=12, pady=10)
        content.pack(fill="both", expand=True, padx=20, pady=(0, 10))

        tutorial_text = f"""1. QUICK START FOR HOSTS
----------------------------------------
• Click 'START / RESTART ALL SERVICES' to boot MySQL (:3310), Auth realmd (:3724), World mangosd (:8085), and Web backend (:18090).
• Once online, click 'ENTER WORLD IN BROWSER (WebGPU)' to launch and test your client.
• Create Game Master or player accounts using 'Player & GM Admin Manager'.

2. HOW PLAYERS CONNECT
----------------------------------------
• WebGPU Browser: Share your public link ({self.public_url_var.get().strip()}/) with friends. They can open it directly in Chrome, Edge, or Brave without downloading any client!
• Vanilla game client: Players set their realmlist.wtf to:
  set realmlist {self._validated_host_safe()}

3. ROUTER PORT FORWARDING
----------------------------------------
To allow players outside your local network to connect, forward these 3 TCP ports on your router to your PC's LAN IP ({get_lan_ipv4()}):
  • TCP 8090: Public HTTPS Web Portal & WebGPU Relay
  • TCP 3724: Login server (realmd)
  • TCP 8085: World Game Realm (mangosd)
  • (Optional) TCP 80 & 443: Let's Encrypt TLS certificate challenges

4. IN-GAME GM COMMANDS REFERENCE
----------------------------------------
Type in the in-game chat or log prompt:
  • .server info              - Show active players, uptime & memory
  • .lookup item <name>       - Search item database for IDs
  • .additem <id> [count]     - Spawn item directly into bags
  • .tele <location>          - Teleport to Ironforge, Orgrimmar, etc.
  • .gm on                    - Turn on Game Master invulnerability & flying
  • .kick <player>            - Disconnect a player

5. DOCUMENTATION & FILES
----------------------------------------
• Full Classic+ Architecture Guide: docs/CLASSIC_PLUS_ARCHITECTURE.md in the server folder.
• World Rates & Bot Config: mangosd.conf
• Database Backups: 'World Database Backups & Toolset' button.
"""
        content.insert(tk.END, tutorial_text)
        content.config(state="disabled")

        btn_box = tk.Frame(w, bg="#11131a")
        btn_box.pack(fill="x", padx=20, pady=(0, 12))

        PillButton(btn_box, "Architecture Guide", lambda: os.startfile(os.path.join(BASE_DIR, "docs", "CLASSIC_PLUS_ARCHITECTURE.md")),
                   width=200, height=32, icon="scroll").pack(side="left", padx=4)
        PillButton(btn_box, "Config Folder", lambda: os.startfile(SETTINGS_DIR), width=170, height=32,
                   icon="folder").pack(side="left", padx=4)
        PillButton(btn_box, "Close", w.destroy, style="gold", width=110, height=32).pack(side="right", padx=4)

    def _validated_host_safe(self):
        try:
            return self._validated_public_host()
        except Exception:
            return get_lan_ipv4()

    def _set_log_filter(self, filter_name):
        self.active_log_filter = filter_name
        for name, btn in self.tab_buttons.items():
            if name == filter_name:
                btn.config(fg="#fbbf24", font=("Consolas", 8, "bold"))
            else:
                btn.config(fg="#71717a", font=("Consolas", 8, "normal"))

        self.txt_log.delete("1.0", tk.END)
        for cat, text in self.all_log_entries:
            if filter_name == "ALL" or cat == filter_name:
                self._insert_formatted_log(cat, text)

    def _insert_formatted_log(self, cat, text):
        tag_map = {
            "DB": "tag_db",
            "REALMD": "tag_realm",
            "MANGOSD": "tag_mangos",
            "SERVER": "tag_server",
            "HTTP": "tag_http",
            "CMD": "tag_cmd"
        }
        tag = tag_map.get(cat, "tag_dim")
        match = re.match(r"^(\[[A-Z0-9_\-\s]+\])\s*(.*)", text)
        if match:
            prefix, rest = match.groups()
            self.txt_log.insert(tk.END, prefix + " ", tag)
            self.txt_log.insert(tk.END, rest + "\n")
        else:
            self.txt_log.insert(tk.END, text + "\n")
        self.txt_log.see(tk.END)

    def log(self, text):
        if threading.current_thread() is not threading.main_thread():
            self.after(0, self.log, text)
            return

        # Clean and parse Caddy JSON logs into readable server messages
        raw_text = text
        if "{" in text and "msg" in text:
            try:
                idx = text.find("{")
                json_str = text[idx:]
                data = json.loads(json_str)
                msg = data.get("msg", "")
                # Ignore noisy repetitive background maintenance logs
                if msg in ("storage cleaning happened too recently; skipping for now",
                           "finished cleaning storage units",
                           "adapted config to JSON",
                           "autosaved config (load with --resume flag)"):
                    return
                if "domains" in data:
                    msg += f" for {', '.join(data['domains'])}"
                if "address" in data:
                    msg += f" on {data['address']}"
                if msg:
                    text = f"[HTTPS] {msg}"
            except Exception:
                text = raw_text

        cat = "ALL"
        upper = text.upper()
        if "[DB]" in upper or "MYSQL" in upper:
            cat = "DB"
        elif "[REALMD]" in upper or "AUTH" in upper:
            cat = "REALMD"
        elif "[MANGOSD]" in upper or "WORLD" in upper:
            cat = "MANGOSD"
        elif "[HTTPS]" in upper or "[HTTP]" in upper or "CADDY" in upper:
            cat = "HTTP"
        elif "[SERVER]" in upper:
            cat = "SERVER"
        elif "[GM CMD]" in upper:
            cat = "CMD"

        formatted = f"[{time.strftime('%H:%M:%S')}] {text}"
        self.all_log_entries.append((cat, formatted))

        if self.active_log_filter == "ALL" or self.active_log_filter == cat:
            self._insert_formatted_log(cat, formatted)

    def _send_gm_cmd(self):
        cmd = self.cmd_entry.get().strip()
        if not cmd:
            return
        self.cmd_entry.delete(0, tk.END)
        self.log(f"[GM CMD] > {cmd}")
        if not is_port_open(8085):
            self.log("[MANGOSD] World server is offline; command not sent.")
            return
        user = self.settings.get("soap_user")
        password = self.settings.get("soap_pass")
        port = int(self.settings.get("soap_port", 7878))
        if not user or not password:
            self.log("[SERVER] GM console needs SOAP: set SOAP.Enabled = 1 in mangosd.conf, restart the world "
                     "server, and add \"soap_user\" / \"soap_pass\" (a GM 3 account) to launcher_settings.json.")
            return

        def send():
            try:
                reply = soap_command(cmd, user, password, port)
                for line in (reply or "(no output)").splitlines():
                    self.log(f"[MANGOSD] {line}")
            except Exception as error:
                self.log(f"[MANGOSD] SOAP command failed: {error}")

        threading.Thread(target=send, daemon=True).start()

    def _draw_sparkline(self, canvas, data, color):
        canvas.delete("all")
        w = int(canvas.winfo_reqwidth())
        h = int(canvas.winfo_reqheight())
        if len(data) < 2:
            return
        max_val = max(max(data), 1)
        step = w / (len(data) - 1)
        points = []
        for i, val in enumerate(data):
            x = i * step
            y = h - 2 - (val / max_val) * (h - 4)
            points.extend([x, y])
        canvas.create_line(points, fill=color, width=1.2)

    def _poll_telemetry(self):
        started = process_start_time("mangosd.exe") if is_port_open(8085) else None
        if started:
            uptime_sec = int(time.time() - started)
            self.lbl_uptime.config(text=f"World server uptime: {uptime_sec // 3600}h {(uptime_sec % 3600) // 60:02d}m")
        else:
            self.lbl_uptime.config(text="World server uptime: offline" if not is_port_open(8085) else "World server uptime: --")

        if is_port_open(3310):
            cpu, mb = get_process_metrics("mysqld.exe")
            if cpu is not None:
                self.lbl_db_metrics.config(text=f"({cpu:.1f}% CPU, {int(mb)}MB RAM)")
                self.spark_mysql_data.append(max(1, int(cpu + mb / 10)))
                if len(self.spark_mysql_data) > 10:
                    self.spark_mysql_data.pop(0)
                self._draw_sparkline(self.cv_spark_db, self.spark_mysql_data, "#4ade80")
            else:
                self.lbl_db_metrics.config(text="(pip install psutil for metrics)" if not psutil else "(-- CPU, -- RAM)")
        else:
            self.lbl_db_metrics.config(text="(-- CPU, -- RAM)")
            self.cv_spark_db.delete("all")

        if is_port_open(8085):
            cpu, mb = get_process_metrics("mangosd.exe")
            if cpu is not None:
                ram_str = f"{mb/1024:.1f}GB RAM" if mb > 1024 else f"{int(mb)}MB RAM"
                self.lbl_world_metrics.config(text=f"({cpu:.1f}% CPU, {ram_str})")
                self.spark_mangos_data.append(max(1, int(cpu + 4)))
                if len(self.spark_mangos_data) > 10:
                    self.spark_mangos_data.pop(0)
                self._draw_sparkline(self.cv_spark_world, self.spark_mangos_data, "#fbbf24")
            else:
                self.lbl_world_metrics.config(text="(pip install psutil for metrics)" if not psutil else "(-- CPU, -- RAM)")
        else:
            self.lbl_world_metrics.config(text="(-- CPU, -- RAM)")
            self.cv_spark_world.delete("all")

        self.after(2500, self._poll_telemetry)

    def _poll_players(self):
        """Characters with online=1, read from the characters DB every 15 s off the UI thread."""
        def work():
            count = None
            if is_port_open(3310) and is_port_open(8085):
                ret, out, _ = server_control.run_mysql_query(
                    "SELECT COUNT(*) FROM classiccharacters.characters WHERE online = 1;")
                if ret == 0:
                    digits = [line.strip() for line in out.splitlines() if line.strip().isdigit()]
                    count = int(digits[-1]) if digits else None
            self.after(0, lambda: self.lbl_players.config(
                text=f"Players online: {count}" if count is not None else "Players online: --"))

        threading.Thread(target=work, daemon=True).start()
        self.after(15000, self._poll_players)

    def _poll_status(self):
        db_up = is_port_open(3310)
        realm_up = is_port_open(3724)
        world_up = is_port_open(8085)
        web_up = is_port_open(LOCAL_WEB_PORT)
        https_up = is_port_open(PUBLIC_HTTPS_PORT)

        self.orb_db.config(image=self.images["gem_green"] if db_up else self.images["gem_red"])
        self.tag_db.config(text="[ONLINE]" if db_up else "[OFFLINE]", fg="#4ade80" if db_up else "#f87171")

        self.orb_realm.config(image=self.images["gem_green"] if realm_up else self.images["gem_red"])
        self.tag_realm.config(text="[ONLINE]" if realm_up else "[OFFLINE]", fg="#4ade80" if realm_up else "#f87171")

        self.orb_world.config(image=self.images["gem_green"] if world_up else self.images["gem_red"])
        self.tag_world.config(text="[ONLINE]" if world_up else "[OFFLINE]", fg="#4ade80" if world_up else "#f87171")

        self.orb_web.config(image=self.images["gem_green"] if web_up else self.images["gem_red"])
        self.tag_web.config(text="[ONLINE]" if web_up else "[OFFLINE]", fg="#4ade80" if web_up else "#f87171")

        self.orb_https.config(image=self.images["gem_green"] if https_up else self.images["gem_red"])
        self.tag_https.config(text="[ONLINE]" if https_up else "[OFFLINE]", fg="#4ade80" if https_up else "#f87171")

        self.after(2000, self._poll_status)

    def save_realm_address(self):
        addr = self.realm_addr_var.get().strip()
        if not re.fullmatch(r"[A-Za-z0-9.\-:]{1,253}", addr):
            messagebox.showerror("Realm address", "Use an IP address or a domain name, e.g. 192.168.1.20 or play.example.com.",
                                 parent=self)
            return
        self.settings["realm_address"] = addr
        try:
            with open(LAUNCHER_CONFIG, "w", encoding="utf-8") as config_file:
                json.dump(self.settings, config_file, indent=2)
        except OSError as error:
            messagebox.showerror("Launcher Settings", str(error), parent=self)
            return
        if is_port_open(3310):
            threading.Thread(target=self._prepare_realm, daemon=True).start()
            self.log(f"[REALMD] Realm address set to {addr}. Players who are signed in reconnect to see it.")
        else:
            self.log(f"[REALMD] Realm address {addr} saved; it is applied when the database starts.")

    def _prepare_realm(self):
        """realmlist -> the saved realm address, and never the well-known Play Solo login on a reachable realm."""
        addr = self.settings.get("realm_address") or "127.0.0.1"
        if not re.fullmatch(r"[A-Za-z0-9.\-:]{1,253}", addr):
            addr = "127.0.0.1"
        ret, _, err = server_control.run_mysql_query(
            f"UPDATE classicrealmd.realmlist SET address='{addr}';"
            f"DELETE FROM classicrealmd.account WHERE username='{solo.SOLO_ACCOUNT}';")
        if ret != 0:
            self.log(f"[DB] Couldn't set the realm address: {(err or '').strip()[:200]}")
        self._enable_selfbot()

    def _enable_selfbot(self):
        """Herald: let players hand their own character to the bot AI and watch it play
        (AiPlayerbot.SelfBotLevel = 2). server_settings.json "herald_selfbot": false keeps it off."""
        want = "2" if self.settings.get("herald_selfbot", True) else "0"
        path = os.path.join(SETTINGS_DIR, "aiplayerbot.conf")
        if not os.path.isfile(path):
            return
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                lines = f.read().split("\n")
            out, done = [], False
            for line in lines:
                if re.match(r"\s*#?\s*AiPlayerbot\.SelfBotLevel\s*=", line):
                    if not done:
                        out.append(f"AiPlayerbot.SelfBotLevel = {want}")
                        done = True
                    continue
                out.append(line)
            if not done:
                out.append(f"AiPlayerbot.SelfBotLevel = {want}")
            text = "\n".join(out)
            with open(path, "w", encoding="utf-8") as f:
                f.write(text)
            self.log("[HERALD] Players can let Herald play their character (self-bot on)." if want == "2"
                     else "[HERALD] Self-bot is off on this server.")
        except OSError as e:
            self.log(f"[HERALD] Couldn't update aiplayerbot.conf: {e}")

    def save_autostart_settings(self):
        self.settings["auto_start_services"] = self.auto_start_services_var.get()
        self.settings["auto_start_https"] = self.auto_start_https_var.get()
        try:
            with open(LAUNCHER_CONFIG, "w", encoding="utf-8") as config_file:
                json.dump(self.settings, config_file, indent=2)
            self.log("[SERVER] Saved server auto-start preferences.")
        except OSError as error:
            messagebox.showerror("Launcher Settings", str(error), parent=self)
            return
        if self.auto_start_https_var.get() and is_port_open(LOCAL_WEB_PORT):
            self.after(0, self.start_public_gateway)

    def _validated_public_host(self):
        raw_url = self.public_url_var.get().strip()
        parsed = urllib.parse.urlsplit(raw_url)
        if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
            raise ValueError("Enter a public HTTPS URL, such as https://203.0.113.10")
        if parsed.port not in (None, PUBLIC_HTTPS_PORT) or parsed.path not in ("", "/") or parsed.query or parsed.fragment:
            raise ValueError(f"Use only the HTTPS origin on port {PUBLIC_HTTPS_PORT} (no path, query, or fragment).")

        host = parsed.hostname
        if not re.fullmatch(r"[A-Za-z0-9.-]+", host) or host.startswith(".") or host.endswith(".") or ".." in host:
            raise ValueError("The public host must be a DNS name or IPv4 address.")
        return host.lower()

    def save_public_url(self):
        try:
            host = self._validated_public_host()
            normalized_url = f"https://{host}:{PUBLIC_HTTPS_PORT}"
            self.public_url_var.set(normalized_url)
            self.settings["public_url"] = normalized_url
            with open(LAUNCHER_CONFIG, "w", encoding="utf-8") as config_file:
                json.dump(self.settings, config_file, indent=2)
            self.log(f"[HTTPS] Saved public URL: {normalized_url}")
            self.lbl_public.config(text=f"Saved · Forward TCP 80/443/8090 → {get_lan_ipv4()}", fg="#fbbf24")
            return True
        except (ValueError, OSError) as error:
            messagebox.showerror("Public URL", str(error), parent=self)
            return False

    def check_public_access(self):
        try:
            host = self._validated_public_host()
        except ValueError as error:
            messagebox.showerror("Public URL", str(error), parent=self)
            return

        self.lbl_public.config(text="Checking public HTTPS endpoint…", fg="#fbbf24")

        def check():
            url = f"https://{host}:{PUBLIC_HTTPS_PORT}/api/status"
            try:
                with urllib.request.urlopen(url, timeout=8) as response:
                    data = json.loads(response.read().decode("utf-8"))
                realm_online = bool(data.get("realm", {}).get("online"))
                services = data.get("services", {})
                relay_ok = services.get("realmd") == "online" and services.get("mangosd") == "online"
                if realm_online and relay_ok:
                    text = "PUBLIC HTTPS ONLINE · auth, world, signup & relay reachable"
                    color = "#4ade80"
                else:
                    text = "HTTPS reachable, but auth/world services are not both ready"
                    color = "#fbbf24"
            except Exception as error:
                text = f"Public HTTPS check failed: {error}"
                color = "#f87171"
            self.after(0, lambda: self.lbl_public.config(text=text, fg=color))

        threading.Thread(target=check, daemon=True).start()

    def start_public_gateway(self):
        try:
            host = self._validated_public_host()
            if not self.save_public_url():
                return
            if not is_port_open(LOCAL_WEB_PORT):
                self.lbl_public.config(text="Start All Realm Services first; local web is offline.", fg="#f87171")
                return
            if self.public_gateway and self.public_gateway.poll() is None:
                self.lbl_public.config(text="HTTPS gateway is already running; use Test HTTPS.", fg="#fbbf24")
                return
            if is_port_open(PUBLIC_HTTPS_PORT):
                self.lbl_public.config(text=f"HTTPS listener active on :{PUBLIC_HTTPS_PORT}; use Test HTTPS.", fg="#fbbf24")
                self.log(f"[HTTPS] Port {PUBLIC_HTTPS_PORT} is already listening.")
                return

            caddy = shutil.which("caddy")
            local_caddy = os.path.join(BASE_DIR, "bin", "caddy.exe")
            if not caddy and os.path.isfile(local_caddy):
                caddy = local_caddy
            if not caddy:
                self.lbl_public.config(text="Caddy is not installed. Install Caddy 2.10.2+.", fg="#f87171")
                self.log("[HTTPS] Public HTTPS needs Caddy 2.10.2+; no Caddy found.")
                return

            caddyfile = f'''{{
    default_sni {host}
}}

https://{host}:{PUBLIC_HTTPS_PORT} {{
    tls {{
        issuer acme https://acme-v02.api.letsencrypt.org/directory {{
            profile shortlived
        }}
    }}
    reverse_proxy 127.0.0.1:{LOCAL_WEB_PORT}
}}
'''
            with open(CADDY_CONFIG, "w", encoding="utf-8", newline="\n") as config_file:
                config_file.write(caddyfile)
            self.public_gateway = subprocess.Popen(
                [caddy, "run", "--config", CADDY_CONFIG, "--adapter", "caddyfile"],
                cwd=BASE_DIR, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, encoding="utf-8", errors="replace",
                env={**os.environ, "APPDATA": os.path.join(BASE_DIR, "CaddyData")}
            )
            self.lbl_public.config(text="Starting HTTPS gateway. Check logs if it fails.", fg="#fbbf24")
            self.log(f"[HTTPS] Started Caddy reverse proxy for {host}:{PUBLIC_HTTPS_PORT} → 127.0.0.1:{LOCAL_WEB_PORT}")
            threading.Thread(target=self._read_gateway_log, args=(self.public_gateway,), daemon=True).start()
        except (ValueError, OSError) as error:
            messagebox.showerror("HTTPS Gateway", str(error), parent=self)

    def _read_gateway_log(self, process):
        if not process.stdout:
            return
        for line in process.stdout:
            line = line.strip()
            if line:
                self.log(line)

    def stop_public_gateway(self):
        if self.public_gateway and self.public_gateway.poll() is None:
            self.public_gateway.terminate()
            self.log("[HTTPS] Stopped Caddy HTTPS gateway.")
            self.lbl_public.config(text="HTTPS gateway stopped", fg="#94a3b8")
        else:
            self.lbl_public.config(text="No HTTPS gateway started by launcher", fg="#94a3b8")

    def allow_https_firewall(self):
        accepted = messagebox.askyesno(
            "Allow public HTTPS",
            "This adds inbound Windows Firewall rules for TCP ports 80, 443, and 8090 so certificate checks and the public HTTPS site can receive traffic. Continue?",
            parent=self
        )
        if not accepted:
            return
        args = (
            "advfirewall firewall add rule name=OpenVanilla-HTTPS dir=in "
            "action=allow protocol=TCP localport=80,443,8090 profile=private,public"
        )
        command = f"Start-Process -FilePath netsh.exe -Verb RunAs -Wait -ArgumentList '{args}'"
        try:
            subprocess.Popen(["powershell", "-NoProfile", "-Command", command])
            self.log("[SERVER] Requested elevated Windows Firewall rules for TCP 80, 443, and 8090.")
            self.lbl_public.config(text=f"Firewall requested. Forward TCP 80/443/8090 to {get_lan_ipv4()}.", fg="#fbbf24")
        except OSError as error:
            messagebox.showerror("Windows Firewall", str(error), parent=self)

    def start_all(self):
        if self._starting:
            return
        self._starting = True

        def run_startup():
            try:
                self._start_all_thread()
            finally:
                self.after(0, lambda: setattr(self, "_starting", False))

        threading.Thread(target=run_startup, daemon=True).start()

    def _start_all_thread(self):
        # 1. Database
        if not is_port_open(3310):
            self.log("[DB] Starting MySQL Database on port 3310...")
            if server_control.start_database():
                self.log("[DB] MySQL connected successfully.")
            else:
                self.log("[DB] Database failed to start on port 3310.")
                return
        else:
            self.log("[DB] MySQL is already running on port 3310.")
        self._prepare_realm()

        # 2. Auth Server
        if not is_port_open(3724):
            self.log("[REALMD] Starting realmd.exe on port 3724...")
            if server_control.start_realmd():
                self.log("[REALMD] Realmd listening on port 3724.")
            else:
                self.log("[REALMD] Auth server failed to start.")
                return
        else:
            self.log("[REALMD] Realmd already active.")

        # 3. World Server
        if not is_port_open(8085):
            self.log("[MANGOSD] Starting mangosd.exe on port 8085...")
            server_control.start_mangosd()
            if is_port_open(8085):
                self.log("[MANGOSD] Mangosd listening on port 8085.")
            else:
                self.log("[MANGOSD] World server did not become ready on port 8085.")
                return
        else:
            self.log("[MANGOSD] World server already active.")

        # 4. Web Backend
        if is_port_open(LOCAL_WEB_PORT):
            pid, version = running_web_backend()
            current = int(os.path.getmtime(ASSET_SERVER_SCRIPT))
            if pid and version == current:
                self.log(f"[SERVER] WebGPU portal engine initialized at http://127.0.0.1:{LOCAL_WEB_PORT}/")
            elif pid:
                self.log("[SERVER] Local web backend is outdated; restarting...")
                kill_pid(pid)
                for _ in range(20):
                    if not is_port_open(LOCAL_WEB_PORT):
                        break
                    time.sleep(0.25)
            else:
                self.log(f"[SERVER] Port {LOCAL_WEB_PORT} occupied.")
                return

        if not is_port_open(LOCAL_WEB_PORT):
            self.log(f"[SERVER] Starting local web backend (:{LOCAL_WEB_PORT})...")
            processes["web"] = start_web_backend()
            for _ in range(30):
                if is_port_open(LOCAL_WEB_PORT):
                    break
                time.sleep(0.5)
            if is_port_open(LOCAL_WEB_PORT):
                self.log(f"[SERVER] WebGPU portal engine initialized.")
            else:
                self.log(f"[SERVER] Web backend failed to start on port {LOCAL_WEB_PORT}.")

        if self.auto_start_https_var.get() and is_port_open(LOCAL_WEB_PORT):
            self.after(0, self.start_public_gateway)

    def stop_all(self):
        self.log("[SERVER] Halt requested: Terminating all realm services...")
        self.stop_public_gateway()
        server_control.stop_started_services()
        if processes["web"] and processes["web"].poll() is None:
            kill_pid(processes["web"].pid)
        else:
            pid, _ = running_web_backend()
            if pid:
                kill_pid(pid)
        processes["web"] = None
        self.log("[SERVER] All realm services successfully stopped.")

    def launch_browser(self):
        if not is_port_open(LOCAL_WEB_PORT):
            messagebox.showerror("Web Service Offline", "Start all realm services before opening the browser client.", parent=self)
            return
        url = f"http://127.0.0.1:{LOCAL_WEB_PORT}/"
        self.log(f"[SERVER] Launching default browser with WebGPU pipeline at {url}...")
        webbrowser.open(url)

    def open_public_site(self):
        try:
            host = self._validated_public_host()
            webbrowser.open(f"https://{host}:{PUBLIC_HTTPS_PORT}/")
        except ValueError as error:
            messagebox.showerror("Public URL", str(error), parent=self)

    def open_db_toolset(self):
        """Toolset popup for database management and backups."""
        w = tk.Toplevel(self)
        w.title("World Database Backups & Toolset")
        w.geometry("420x330")
        w.configure(bg="#11131a")
        w.resizable(False, False)

        tk.Label(w, text="WORLD DATABASE TOOLSET", fg="#f3d179", bg="#11131a", font=(RF, 11, "bold")).pack(pady=(14, 2))
        tk.Label(w, text="Server Host Operations & Backups", fg="#94a3b8", bg="#11131a", font=(RF, 8)).pack(pady=(0, 12))

        box = tk.Frame(w, bg="#11131a")
        box.pack(fill="x", padx=30)

        def do_backup():
            backup_dir = os.path.join(BASE_DIR, "backups")
            os.makedirs(backup_dir, exist_ok=True)
            ts = time.strftime("%Y%m%d_%H%M%S")
            target = os.path.join(backup_dir, f"accounts_characters_{ts}.sql")
            dump_bin = os.path.join(DB_DIR, r"bin\mysqldump.exe")
            if not os.path.exists(dump_bin):
                messagebox.showerror("Error", "mysqldump.exe not found.", parent=w)
                return
            if not is_port_open(3310):
                messagebox.showerror("Database Offline", "Start MySQL (port 3310) before backing up.", parent=w)
                return
            # --databases: without it mysqldump reads the second name as a table of the first DB
            cmd = [dump_bin, *server_control.db_args(),
                   "--single-transaction", "--databases", "classicrealmd", "classiccharacters"]
            with open(target, "w", encoding="utf-8") as f:
                res = subprocess.run(cmd, stdout=f, stderr=subprocess.PIPE, text=True, env=server_control.db_env())
            if res.returncode != 0 or os.path.getsize(target) == 0:
                messagebox.showerror("Backup Failed", (res.stderr or "mysqldump wrote nothing.").strip(), parent=w)
                self.log(f"[DB] Backup failed: {(res.stderr or '').strip()}")
                return
            messagebox.showinfo("Backup Complete", f"Accounts and characters dumped to:\n{target}", parent=w)
            self.log(f"[DB] Backed up classicrealmd + classiccharacters to {target}")

        PillButton(box, "BACK UP ACCOUNTS & CHARACTERS", do_backup, style="gold", width=360, height=34,
                   icon="box").pack(pady=4)
        PillButton(box, "Database Folder", lambda: os.startfile(DB_DIR), width=360, height=32,
                   icon="folder").pack(pady=4)

    def create_account_popup(self):
        w = tk.Toplevel(self)
        w.title("Create / Manage Realm Account")
        w.geometry("380x370")
        w.configure(bg="#11131a")
        w.resizable(False, False)

        tk.Label(w, text="AUTHENTIC REALM ACCOUNT", fg="#f3d179", bg="#11131a", font=(RF, 11, "bold")).pack(pady=(14, 2))
        tk.Label(w, text="SRP6 encrypted account registration", fg="#94a3b8", bg="#11131a", font=(RF, 8)).pack(pady=(0, 10))

        form = tk.Frame(w, bg="#11131a")
        form.pack(fill="x", padx=30)

        tk.Label(form, text="Username:", fg="#cbd5e1", bg="#11131a", font=(RF, 9, "bold")).pack(anchor="w")
        e_user = tk.Entry(form, bg="#1e2230", fg="#f8fafc", insertbackground="#f8fafc", relief="sunken", bd=1, font=("Consolas", 10))
        e_user.pack(fill="x", pady=(2, 8))

        tk.Label(form, text="Password:", fg="#cbd5e1", bg="#11131a", font=(RF, 9, "bold")).pack(anchor="w")
        e_pass = tk.Entry(form, show="*", bg="#1e2230", fg="#f8fafc", insertbackground="#f8fafc", relief="sunken", bd=1, font=("Consolas", 10))
        e_pass.pack(fill="x", pady=(2, 8))

        tk.Label(form, text="Security / Role:", fg="#cbd5e1", bg="#11131a", font=(RF, 9, "bold")).pack(anchor="w")
        role_var = tk.StringVar(value="Player (GM 0)")
        role_combo = ttk.Combobox(form, textvariable=role_var, state="readonly", font=(RF, 9),
                                  values=["Player (GM 0)", "Game Master (GM 1)", "Game Master (GM 2)", "Administrator (GM 3)"])
        role_combo.pack(fill="x", pady=(2, 12))

        def do_create():
            user = e_user.get().strip().upper()
            pwd = e_pass.get().strip().upper()
            if not user or not pwd:
                messagebox.showerror("Validation Error", "Both username and password are required.", parent=w)
                return
            # The name is written into SQL below; allow only what realmd accepts anyway.
            if not re.fullmatch(r"[A-Z0-9]{3,16}", user):
                messagebox.showerror("Validation Error", "Username must be 3-16 letters or digits.", parent=w)
                return
            if not 4 <= len(pwd) <= 16:
                messagebox.showerror("Validation Error", "Password must be 4-16 characters (the game client's limit).", parent=w)
                return

            if not is_port_open(3310):
                messagebox.showerror("Database Offline", "MySQL Database is offline (port 3310).\nPlease start services first.", parent=w)
                return

            role_str = role_var.get()
            if "GM 3" in role_str:
                gmlevel = 3
                gid = 3
            elif "GM 2" in role_str:
                gmlevel = 2
                gid = 2
            elif "GM 1" in role_str:
                gmlevel = 1
                gid = 2
            else:
                gmlevel = 0
                gid = 2

            try:
                s_hex, v_hex = server_control.generate_srp6(user, pwd)
                user = server_control.sql_value(user)  # raises on anything but letters/digits
                sql = f"""
                USE classicrealmd;
                INSERT INTO account (username, s, v, gmlevel)
                VALUES ('{user}', '{s_hex}', '{v_hex}', {gmlevel})
                ON DUPLICATE KEY UPDATE s='{s_hex}', v='{v_hex}', gmlevel={gmlevel};
                INSERT INTO website_accounts (account_id, display_name, registration_ip, g_id)
                VALUES (
                    (SELECT id FROM account WHERE username='{user}'),
                    '{user}',
                    '127.0.0.1',
                    {gid}
                )
                ON DUPLICATE KEY UPDATE g_id={gid};
                """
                ret, out, err = server_control.run_mysql_query(sql)
                if ret == 0:
                    role_desc = "Administrator (GM 3)" if gmlevel == 3 else f"Player (GM {gmlevel})"
                    try:
                        ok, detail = verify_realm_login(user, pwd)
                    except OSError as ex:
                        ok, detail = None, f"login server not reachable ({ex})"
                    if ok is False:
                        messagebox.showerror("Login Check Failed",
                                             f"Account '{user}' was saved, but the login server rejected it: {detail}", parent=w)
                        self.log(f"[AUTH] Account '{user}' saved but realmd login check failed: {detail}")
                        return
                    note = "\nTest login: OK." if ok else f"\nTest login skipped: {detail}."
                    messagebox.showinfo("Success", f"Account '{user}' successfully registered as {role_desc}!{note}", parent=w)
                    self.log(f"[AUTH] Account '{user}' created/updated as {role_desc} in classicrealmd.")
                    w.destroy()
                else:
                    err_msg = err.strip() if err else out.strip()
                    messagebox.showerror("Database Error", f"MySQL query failed:\n\n{err_msg}", parent=w)
                    self.log(f"[DB] Database error registering account '{user}': {err_msg}")
            except Exception as ex:
                messagebox.showerror("Error", f"Failed to compute SRP6 credentials:\n{ex}", parent=w)
                self.log(f"[AUTH] Account registration error: {ex}")

        btn_box = tk.Frame(w, bg="#11131a")
        btn_box.pack(fill="x", padx=30, pady=10)

        PillButton(btn_box, "CREATE / UPDATE ACCOUNT", do_create, style="gold", width=360, height=36,
                   icon="account").pack()

    # ----------------------------------------------------------------- PLAY SOLO

    def open_herald(self):
        """Herald Autopilot, pointed at this PC's server (autopilot/herald_autopilot.py --local-server).
        Herald Lite logs an account in by itself and plays it on 127.0.0.1."""
        here = os.path.dirname(os.path.abspath(__file__))
        script = os.path.join(here, "autopilot", "herald_autopilot.py")
        if not os.path.isfile(script):
            messagebox.showinfo("Herald", "Herald Autopilot isn't in this folder. It comes with Open Vanilla Server 1.18 and later.")
            return
        py = sys.executable
        if os.name == "nt" and py.lower().endswith("python.exe") and os.path.isfile(py[:-10] + "pythonw.exe"):
            py = py[:-10] + "pythonw.exe"
        subprocess.Popen([py, script, "--local-server"], cwd=here)
        self.log("[HERALD] Herald Autopilot opened for this server. Pick the account he plays, then START.")

    def play_solo(self):
        """Offline on this PC: download the solo pack once, then start its servers hidden, sign in, play,
        and stop everything when the game closes (play_local.SoloSession does the work)."""
        if self.solo_session is not None:
            if self.solo_dialog is not None:
                self.solo_dialog.show()
            return
        if is_port_open(3724) or is_port_open(8085):
            messagebox.showerror("Play Solo", "A realm is already running on this PC (ports 3724/8085).\n\n"
                                 "Press HALT ALL SERVICES first, then Play Solo.", parent=self)
            return
        self.btn_solo.config(state="disabled", text="Checking the solo server…")
        session = solo.SoloSession(reporter=None)

        def check():
            try:
                status, manifest = session.pack_status()
                self.after(0, lambda: self._solo_confirm(session, status, manifest, None))
            except solo.SoloError as e:
                error = e  # bound now: Python clears "e" when the except block ends
                self.after(0, lambda: self._solo_confirm(session, None, None, error))

        threading.Thread(target=check, daemon=True).start()

    def _solo_confirm(self, session, status, manifest, error):
        self.btn_solo.config(state="normal", text="PLAY SOLO  ·  offline on this PC")
        if error is not None:
            messagebox.showerror("Play Solo", str(error), parent=self)
            return
        if status == "offline":
            messagebox.showerror("Play Solo", "The solo server isn't downloaded yet and the download server can't be "
                                 "reached. Connect to the internet once and try again.", parent=self)
            return
        if status in ("missing", "update"):
            size = solo.human_size(int(manifest["size"]))
            first = status == "missing"
            ok = messagebox.askokcancel(
                "Play Solo",
                ("Play Solo runs your own Open Vanilla world on this PC: the Classic+ content, your addons and\n"
                 "playerbots to group with. No install, no admin rights.\n\n"
                 f"First it downloads the solo server ({size}, once) into the OpenVanilla\\solo folder,\n"
                 "and the first start makes the world's maps from your game client (10-20 minutes).\n\n"
                 if first else f"A new solo server is available ({manifest['version']}, {size}). Download it now?\n\n")
                + solo.SOLO_NOTE, parent=self)
            if not ok:
                return
        self.solo_session = session
        self.solo_dialog = SoloDialog(self, session)
        session.reporter = self.solo_dialog
        self.log("[SOLO] Play Solo started.")

        def work():
            err = None
            try:
                session.run()
            except solo.Cancelled:
                err = None
            except solo.SoloError as e:
                err = str(e)
            except Exception as e:  # never leave the dialog hanging on a bug
                err = f"Something went wrong: {e}"
            self.after(0, lambda: self._solo_finished(err))

        threading.Thread(target=work, daemon=True).start()

    def _solo_finished(self, err):
        self.solo_session = None
        if self.solo_dialog is not None:
            self.solo_dialog.finished(err)
            self.solo_dialog = None
        if err:
            self.log(f"[SOLO] {err}")
            messagebox.showerror("Play Solo", err, parent=self)
        else:
            self.log("[SOLO] Solo stopped. Solo characters are saved on this PC.")

    def _on_close(self):
        if self.solo_session is not None:
            if not messagebox.askyesno("Play Solo", "Solo is running. Closing stops the solo servers (your characters "
                                       "are saved first) and disconnects the game.\n\nClose anyway?", parent=self):
                return
            session = self.solo_session
            session.stop()
            self.after(200, lambda: self._close_when_solo_done(session, 0))
            return
        self.destroy()

    def _close_when_solo_done(self, session, waited):
        if self.solo_session is None or waited > 150:
            self.destroy()
            return
        self.after(1000, lambda: self._close_when_solo_done(session, waited + 1))

    # ----------------------------------------------------------------- busy live realm -> offer solo

    def _poll_live_realm(self):
        """Every minute: is the live realm full, slow or down (play_local.probe_realm on its /healthz)?"""
        def work():
            try:
                sample = solo.probe_realm(solo.official_realm())
            except Exception:
                return
            self.after(0, lambda: self._live_realm_sample(sample))

        threading.Thread(target=work, daemon=True).start()
        self.after(60000, self._poll_live_realm)

    def _live_realm_sample(self, sample):
        busy = self.busy_tracker.update(sample)
        state = self.busy_tracker.state
        if busy and self.busy_dismissed != state and self.solo_session is None:
            name = solo.official_realm().get("name", "The live realm")
            self.lbl_busy.config(text=f"{name}: {self.busy_tracker.reason}  Play offline on this PC while you wait "
                                      "(solo characters stay on this PC).")
            if not self.busy_banner.winfo_ismapped():
                self.busy_banner.pack(fill="x", padx=16, pady=(0, 4), before=self.body_frame)
        elif not busy:
            self.busy_dismissed = None
            self.busy_banner.pack_forget()

    def _dismiss_busy_banner(self):
        self.busy_dismissed = self.busy_tracker.state
        self.busy_banner.pack_forget()


class SoloDialog(solo.Reporter):
    """The Play Solo progress window. A play_local Reporter: its calls come from the worker thread
    and are moved onto Tk's thread with after()."""

    def __init__(self, app, session):
        self.app, self.session = app, session
        w = self.win = tk.Toplevel(app)
        w.title("Open Vanilla - Play Solo")
        w.geometry("500x250")
        w.configure(bg="#11131a")
        w.resizable(False, False)
        w.protocol("WM_DELETE_WINDOW", w.withdraw)  # closing the window just hides it; the button stops solo
        tk.Label(w, text="PLAY SOLO", fg="#f3d179", bg="#11131a", font=(RF, 12, "bold")).pack(pady=(14, 2))
        self.lbl_stage = tk.Label(w, text="Getting ready…", fg="#e2e8f0", bg="#11131a", font=(RF, 9),
                                  wraplength=450, justify="center")
        self.lbl_stage.pack(pady=(4, 8), padx=20)
        self.bar = ttk.Progressbar(w, length=440, mode="determinate", maximum=1000)
        self.bar.pack(padx=30)
        self.lbl_detail = tk.Label(w, text="", fg="#94a3b8", bg="#11131a", font=("Consolas", 8), wraplength=450)
        self.lbl_detail.pack(pady=(6, 4), padx=20)
        tk.Label(w, text=solo.SOLO_NOTE, fg="#c89b3c", bg="#11131a", font=(RF, 8), wraplength=450).pack(pady=(2, 6))
        self.btn = PillButton(w, "Cancel", self._cancel, width=150, height=30)
        self.btn.pack(pady=(0, 10))
        self.indeterminate = False
        self.playing = False

    def _ui(self, fn):
        try:
            self.app.after(0, fn)
        except (RuntimeError, tk.TclError):
            pass

    def show(self):
        self.win.deiconify()
        self.win.lift()

    def stage(self, key, text):
        def ui():
            self.lbl_stage.config(text=text)
            self.lbl_detail.config(text="")
            self.bar.stop()
            self.bar.config(mode="determinate", value=0)
            self.indeterminate = False
            if key == "play":
                self.playing = True
                self.btn.config(text="Stop Solo")
                self.lbl_detail.config(text=f"Account {solo.SOLO_ACCOUNT}, password {solo.SOLO_PASSWORD} "
                                            "(the launcher signs in for you). Closing the game stops solo.")
            self.app.log(f"[SOLO] {text}")
        self._ui(ui)

    def progress(self, done, total=None, text=None):
        def ui():
            if total:
                if self.indeterminate:
                    self.bar.stop()
                    self.bar.config(mode="determinate")
                    self.indeterminate = False
                self.bar.config(value=int(1000 * max(0.0, min(1.0, done / total))))
            elif not self.indeterminate:
                self.bar.config(mode="indeterminate")
                self.bar.start(15)
                self.indeterminate = True
            if text:
                self.lbl_detail.config(text=text)
        self._ui(ui)

    def info(self, text):
        self._ui(lambda: self.app.log(f"[SOLO] {text}"))

    def warn(self, text):
        self._ui(lambda: (self.lbl_detail.config(text=text), self.app.log(f"[SOLO] {text}")))

    def _cancel(self):
        if self.playing and not messagebox.askyesno(
                "Play Solo", "Stop the solo servers? The game will be disconnected (your characters are saved first).",
                parent=self.win):
            return
        self.btn.config(state="disabled", text="Stopping…")
        self.session.stop()

    def finished(self, err):
        try:
            self.bar.stop()
            if err:
                self.win.destroy()
                return
            self.lbl_stage.config(text="Solo stopped. Your solo characters are saved on this PC.")
            self.btn.config(state="normal", text="Close", command=self.win.destroy)
            self.win.after(4000, self.win.destroy)
        except tk.TclError:
            pass


if __name__ == "__main__":
    app = WarcraftLauncher()
    app.mainloop()
