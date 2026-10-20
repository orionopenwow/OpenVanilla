"""Herald Autopilot — let Herald play your character on a realm that allows it, simulate gear, and
help Herald learn (if you say yes).

    Herald Autopilot.bat            (or: python autopilot/herald_autopilot.py [--demo] [--realm URL])

Pages (left): Play, Rules, Sim, Session, Settings. One big START/STOP under them.
  Play      pick a goal (Level up, Quest, Gather, Follow me, Dungeon), watch the log and the map
  Rules     plain sentences with one choice each ("Rest when health is below [35%]")
  Sim       compare two sets of stats for your class (ap_sim.py)
  Session   this run's numbers and what happened, in order
  Settings  which realm, sign-in, learning on/off and exactly what it shares

Autopilot only runs where the realm says autoplay is allowed, and the realm tags the character so
everyone can see it's on autopilot. See ap_core.py for the rules of the road.
"""
from __future__ import annotations

import argparse
import json
import os
import queue
import sys
import threading
import time
import tkinter as tk
import tkinter.font as tkfont
import webbrowser

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

from PIL import Image, ImageTk  # noqa: E402

import ap_art as art  # noqa: E402
import ap_core as core  # noqa: E402
import ap_learn  # noqa: E402
import ap_link  # noqa: E402
import ap_sim  # noqa: E402
from ap_art import L, W, H  # noqa: E402

VERSION = "1.0.0"
TICK_MS = 250
KEY = "#010203"     # on Windows this colour is see-through: it's what rounds the window's corners

# colours for Tk-drawn text
GOLD = "#e9c46a"
GOLD_DIM = "#b8995a"
PARCH = "#e2d6ba"
TEXT = "#d6dbe8"
MUTED = "#8d94a8"
GREEN = "#5fd77a"
RED = "#ee6a5a"
BLUE = "#7fb6ff"
YELLOW = "#ffd257"
ITEM_Q = {0: "#9d9d9d", 1: "#ffffff", 2: "#1eff00", 3: "#0070dd"}
LOG_COL = {"kill": "#ff9d7a", "loot": "#7fb6ff", "death": RED, "level": YELLOW, "quest": YELLOW, "rest": "#9be0b0",
           "vendor": "#c9b37a", "gather": "#8fe08f", "state": GOLD, "log": TEXT, "xp": "#9be0b0"}


def _lighten(color, t):
    """#rrggbb mixed toward white by t (the emboss highlight)."""
    try:
        c = color.lstrip("#")
        r, g, b = (int(c[i:i + 2], 16) for i in (0, 2, 4))
    except (ValueError, AttributeError):
        return "#ffffff"
    return "#%02x%02x%02x" % tuple(int(v + (255 - v) * t) for v in (r, g, b))


# ------------------------------------------------------------------------------------------ setup
def _brand_dir(base):
    """base\\OpenVanilla, or the older folder with the old name when it (from before the rename) already exists."""
    old = os.path.join(base, "OpenWoW")
    return old if os.path.isdir(old) else os.path.join(base, "OpenVanilla")


def data_dir():
    custom = os.environ.get("OPENVANILLA_DATA_DIR")
    if custom:
        return os.path.join(custom, "autopilot")
    if os.path.isdir(os.path.join(ROOT, "launcher")) and os.path.isdir(os.path.join(ROOT, ".git")):
        return os.path.join(ROOT, "_local", "autopilot")
    base = os.environ.get("LOCALAPPDATA") or os.path.join(os.path.expanduser("~"), ".local", "share")
    return os.path.join(_brand_dir(base), "autopilot")


def read_links():
    """KEY=value pairs from the repo's links.txt (the realm's web address lives there)."""
    out = {}
    for path in (os.path.join(ROOT, "links.txt"), os.path.join(ROOT, "launcher", "links.txt")):
        try:
            with open(path, encoding="utf-8") as f:
                for line in f:
                    if "=" in line and not line.lstrip().startswith("#"):
                        k, v = line.split("=", 1)
                        out.setdefault(k.strip(), v.strip())
        except OSError:
            pass
    return out


def launcher_token():
    """The Open Vanilla launcher's sign-in token, if this PC has one (never a password)."""
    try:
        sys.path.insert(0, os.path.join(ROOT, "launcher"))
        import account  # launcher/account.py
        for folder in (os.path.join(ROOT, "_local", "launcher-data"), ROOT,
                       os.path.join(os.environ.get("LOCALAPPDATA", ""), "OpenVanilla"),
                       os.path.join(os.environ.get("LOCALAPPDATA", ""), "OpenWoW")):
            p = os.path.join(folder, "settings.json")
            if os.path.isfile(p):
                with open(p, encoding="utf-8") as f:
                    s = json.load(f)
                if s.get("launcher_token"):
                    return account.unprotect(s["launcher_token"])
    except Exception:
        return None
    return None


def register_fonts():
    """Cinzel for this process only (Windows), so Tk can use it by name."""
    fonts = os.path.join(art.FONTS)
    if sys.platform == "win32":
        try:
            import ctypes
            for f in os.listdir(fonts):
                if f.lower().endswith(".ttf"):
                    ctypes.windll.gdi32.AddFontResourceExW(os.path.join(fonts, f), 0x10, 0)  # FR_PRIVATE
        except Exception:
            pass


class Settings:
    def __init__(self, folder):
        self.path = os.path.join(folder, "settings.json")
        os.makedirs(folder, exist_ok=True)
        try:
            with open(self.path, encoding="utf-8") as f:
                self.d = json.load(f)
        except (OSError, ValueError):
            self.d = {}

    def get(self, k, default=None):
        return self.d.get(k, default)

    def set(self, k, v):
        self.d[k] = v
        self.save()

    def save(self):
        tmp = self.path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(self.d, f, indent=1)
        os.replace(tmp, self.path)


# ------------------------------------------------------------------------------------------ app
class App(tk.Tk):
    def __init__(self, demo=False, realm_url=None, folder=None, chrome=True):
        super().__init__()
        register_fonts()
        art.ensure()
        self.folder = folder or data_dir()
        self.settings = Settings(self.folder)
        self.links = read_links()
        self.title("Herald Autopilot")
        self.geometry(f"{W}x{H}+{max(0, (self.winfo_screenwidth() - W) // 2)}+{max(0, (self.winfo_screenheight() - H) // 3)}")
        self.resizable(False, False)
        self.custom_chrome = chrome
        rounded = chrome and sys.platform == "win32"
        self.base_bg = KEY if rounded else "#05070d"
        self.configure(bg=self.base_bg)
        if rounded:
            try:
                self.attributes("-transparentcolor", KEY)
            except tk.TclError:
                self.base_bg = "#05070d"
        if chrome:
            self.overrideredirect(True)
            if sys.platform == "win32":
                self.after(10, self._win_taskbar_fix)
        try:
            self._icon = ImageTk.PhotoImage(Image.open(os.path.join(art.UI, "icon.png")).resize((64, 64)))
            self.iconphoto(True, self._icon)
        except Exception:
            pass
        fams = set(tkfont.families(self))
        # Arial everywhere, bold where it reads well (Liberation Sans has Arial's shapes where Arial is missing)
        ui = next((f for f in ("Arial", "Liberation Sans", "Helvetica") if f in fams), "TkDefaultFont")
        disp = ui
        self.F = {
            "title": (disp, 24, "bold"), "h1": (disp, 15, "bold"), "h2": (disp, 12, "bold"), "h3": (disp, 10, "bold"),
            "nav": (disp, 14, "bold"), "btn": (disp, 18, "bold"), "btn_s": (disp, 10, "bold"),
            "ui": (ui, 10), "ui_b": (ui, 10, "bold"), "ui_s": (ui, 9, "bold"), "ui_l": (ui, 11, "bold"),
            "num": (disp, 17, "bold"), "log": (ui, 10),
            "mono": ("Consolas" if "Consolas" in fams else "DejaVu Sans Mono", 9),
        }
        self.EMBOSS = {"title", "h1", "h2", "h3", "nav", "btn", "btn_s", "num", "ui_l"}
        self.imgs = {}
        self.labels = {}
        self.cv = tk.Canvas(self, width=W, height=H, highlightthickness=0, bd=0, bg=self.base_bg)
        self.cv.pack()
        self.page = None
        self.page_widgets = []
        self.hover_items = {}
        self.events_q = queue.Queue()

        # realm + learning
        self.learner = ap_learn.Learner(self.folder)
        self.profiles = self.learner.profiles()
        self.link = None
        self.realm = {}
        self.chars = []
        self.state = None
        self.session = None
        self.running = False
        self.last_death = 0.0
        self.log_lines = []
        self.goal = self.settings.get("goal", "level")
        self.sim_result = None
        self.sim_busy = False
        if demo:
            self.settings.d["realm"] = "demo"
        elif realm_url:
            self.settings.d["realm"] = realm_url
        self.connect(self.settings.get("realm") or "demo", quiet=True)

        self.draw_chrome()
        self.show("play")
        self.after(TICK_MS, self.loop)
        self.after(1200, self.first_run)
        self.protocol("WM_DELETE_WINDOW", self.quit_app)

    # ------------------------------------------------------------------ images & text
    def img(self, name):
        if name not in self.imgs:
            self.imgs[name] = ImageTk.PhotoImage(Image.open(os.path.join(art.UI, name)))
        return self.imgs[name]

    def pil(self, key, make):
        if key not in self.imgs:
            self.imgs[key] = ImageTk.PhotoImage(make())
        return self.imgs[key]

    def text(self, x, y, s, font="ui", fill=TEXT, anchor="nw", tag="page", shadow=True, width=0, justify="left"):
        """Text with a drop shadow; headings, labels and numbers are embossed (a dark edge below right,
        a light edge above left)."""
        kw = dict(text=s, font=self.F[font], anchor=anchor, tags=tag, width=width, justify=justify)
        if shadow and font in self.EMBOSS and not width and "\n" not in str(s):
            item = self.cv.create_image(x, y, image=self.emboss(s, font, fill), anchor=anchor, tags=tag)
            self.labels[item] = str(s)      # what it says (tests and tools look labels up by text)
            return item
        if shadow:
            self.cv.create_text(x + 1, y + 1, fill="#000000", **kw)
        return self.cv.create_text(x, y, text=s, font=self.F[font], fill=fill, anchor=anchor, tags=tag, width=width,
                                   justify=justify)

    def emboss(self, s, font, fill):
        """The embossed image for a label (cached): Arial Bold at the font's size in pixels."""
        size = self.F[font][1]
        px = round(size * self.winfo_fpixels("1p")) if size > 0 else -size
        return self.pil(f"emb|{s}|{px}|{fill}", lambda: art.emboss_text(str(s), px, fill))

    def plaque_title(self, box, title, tag="page"):
        x0, y0, x1, _ = L[box]
        self.text((x0 + x1) // 2, y0 + 1, title.upper(), "h3", PARCH, "center", tag)

    def button(self, x, y, w, h, label, command, tag="page", tone="gold", font="btn_s", enabled=True):
        """A small gold-rimmed button on the canvas (normal / hover)."""
        n = self.pil(f"sb_{w}_{h}_{tone}", lambda: art.small_button(w, h, tone=tone))
        hv = self.pil(f"sbh_{w}_{h}_{tone}", lambda: art.small_button(w, h, True, tone=tone))
        item = self.cv.create_image(x, y, image=n, anchor="nw", tags=tag)
        t = self.text(x + w // 2, y + h // 2, label, font, GOLD if enabled else MUTED, "center", tag)
        if enabled:
            self._clickable([item, t], command, lambda on: self.cv.itemconfig(item, image=hv if on else n))
        return item

    def _clickable(self, items, command, hover=None):
        for it in items:
            self.cv.tag_bind(it, "<Button-1>", lambda e: command())
            self.cv.tag_bind(it, "<Enter>", lambda e: (self.cv.config(cursor="hand2"), hover and hover(True)))
            self.cv.tag_bind(it, "<Leave>", lambda e: (self.cv.config(cursor=""), hover and hover(False)))

    def money(self, x_right, y, copper, font="ui_b", tag="dyn", big=False):
        """Money the game's way, right-aligned at x_right: 4 (gold coin) 52 (silver coin)."""
        copper = int(copper or 0)
        g, rest = divmod(copper, 10000)
        sv, c = divmod(rest, 100)
        parts = [(g, "gold"), (sv, "silver")] if g else ([(sv, "silver"), (c, "copper")] if sv else [(c, "copper")])
        suffix = "_l" if big else ""
        x = x_right
        for value, kind in reversed(parts):
            icon = self.cv.create_image(x, y, image=self.img(f"coin_{kind}{suffix}.png"), anchor="e", tags=tag)
            x = self.cv.bbox(icon)[0] - 2
            t = self.text(x, y, str(value), font, "#ffffff", "e", tag)
            x = self.cv.bbox(t)[0] - 6
        return x

    def money_centered(self, cx, y, copper, tags):
        """Money with coin icons, centred on cx."""
        self._mc = getattr(self, "_mc", 0) + 1
        t = f"m{self._mc}"
        left = self.money(cx, y, copper, "num", tags + (t,), big=True)
        self.cv.move(t, (cx - left) / 2 - 3, 0)

    def measure(self, font, s):
        return tkfont.Font(self, font=self.F[font]).measure(s)

    def pill(self, x, y, w, label, options, on_pick, tag="page", h=26):
        """A choice pill: shows the current choice; click for a menu of the others."""
        n = self.pil(f"pill_{w}_{h}", lambda: art.choice_pill(w, h))
        hv = self.pil(f"pillh_{w}_{h}", lambda: art.choice_pill(w, h, True))
        item = self.cv.create_image(x, y, image=n, anchor="nw", tags=tag)
        t = self.cv.create_text(x + 10, y + h // 2, text=label, font=self.F["ui_b"], fill=GOLD, anchor="w", tags=tag)

        def open_menu():
            m = tk.Menu(self, tearoff=0, bg="#151b2c", fg=TEXT, activebackground="#3a4670", activeforeground=GOLD,
                        bd=1, relief="flat", font=self.F["ui"])
            for opt in options:
                m.add_command(label=opt, command=lambda o=opt: on_pick(o))
            m.tk_popup(self.winfo_rootx() + x, self.winfo_rooty() + y + h)
        self._clickable([item, t], open_menu, lambda on: self.cv.itemconfig(item, image=hv if on else n))
        return item

    def toggle(self, x, y, on, command, tag="page"):
        item = self.cv.create_image(x, y + 1, image=self.img("kit_toggle_on.png" if on else "kit_toggle_off.png"), anchor="nw", tags=tag)
        self._clickable([item], command)
        return item

    # ------------------------------------------------------------------ the frame
    def draw_chrome(self):
        cv = self.cv
        cv.delete("all")
        self.bg_item = cv.create_image(0, 0, image=self.img("bg_play.png"), anchor="nw", tags="bg")
        x0, y0, _, _ = L["portrait"]
        cv.create_image(x0 - 6, y0 - 6, image=self.img("portrait.png"), anchor="nw", tags=("chrome", "drag"))
        title = self.pil("title", lambda: art.gold_text("HERALD", 30))
        cv.create_image(118, 14, image=title, anchor="nw", tags=("chrome", "drag"))
        tx = 118 + title.width() + 6
        cv.create_line(tx, 26, tx, 52, fill="#b8995a", width=1, tags="chrome")
        self.text(tx + 12, 22, "Autopilot", "title", PARCH, tag=("chrome", "drag"))
        cv.create_image(W - 380, 22, image=self.img("wordmark.png"), anchor="nw", tags=("chrome", "drag"))
        # window buttons, inside the frame (the kit's minimise and close)
        if self.custom_chrome:
            for i, kind in enumerate(("min", "close")):
                bx = W - 150 + i * 34
                it = cv.create_image(bx, 22, image=self.img(f"kit_win_{kind}.png"), anchor="nw", tags="chrome")
                cmd = self.minimize if kind == "min" else self.quit_app
                self._clickable([it], cmd, lambda on, it=it, kind=kind: cv.itemconfig(
                    it, image=self.img(f"kit_win_{kind}_hover.png" if on else f"kit_win_{kind}.png")))
            for tag in ("bg", "drag"):
                cv.tag_bind(tag, "<ButtonPress-1>", self._drag_start)
                cv.tag_bind(tag, "<B1-Motion>", self._drag_move)
        # nav: the kit's bars, our labels
        nx0, ny0, nx1, _ = L["nav"]
        for i, name in enumerate(art.NAV):
            x, y = nx0 + 16, ny0 + 12 + i * 56
            bar = cv.create_image(x, y, image=self.img(f"knav_{name}.png"), anchor="nw", tags=("chrome", f"navbar_{name}"))
            label = self.text(x + 131, y + 27, art.NAV_LABELS[name], "nav", PARCH, "center", ("chrome", f"navlabel_{name}"))
            self._clickable([bar, label], lambda n=name: self.show(n),
                            lambda on, n=name, bar=bar: self.page != n and cv.itemconfig(
                                bar, image=self.img(f"knav_{n}_hover.png" if on else f"knav_{n}.png")))
        self.draw_dynamic()

    def _drag_start(self, e):
        if e.y > 100:
            self._drag = None
            return
        self._drag = (e.x_root - self.winfo_x(), e.y_root - self.winfo_y())

    def _drag_move(self, e):
        if getattr(self, "_drag", None):
            self.geometry(f"+{e.x_root - self._drag[0]}+{e.y_root - self._drag[1]}")

    def minimize(self):
        if self.custom_chrome:
            self.overrideredirect(False)
        self.iconify()
        self.bind("<Map>", self._on_map)

    def _on_map(self, _e=None):
        if self.custom_chrome and self.state() == "normal" and not self.overrideredirect():
            self.overrideredirect(True)
            if sys.platform == "win32":
                self.after(10, self._win_taskbar_fix)

    def _win_taskbar_fix(self):
        try:
            import ctypes
            hwnd = ctypes.windll.user32.GetParent(self.winfo_id())
            style = ctypes.windll.user32.GetWindowLongW(hwnd, -20)
            style = (style & ~0x00000080) | 0x00040000
            ctypes.windll.user32.SetWindowLongW(hwnd, -20, style)
            self.withdraw()
            self.after(10, self.deiconify)
        except Exception:
            pass

    # ------------------------------------------------------------------ realm
    def connect(self, which, quiet=False):
        """Pick the realm: 'demo' or a web address."""
        if self.running:
            self.stop()
        self.settings.set("realm", which)
        if which == "demo":
            self.link = ap_link.DemoLink(seed=int(time.time()) % 10000)
            self.learner.base = (self.links.get("BACKEND_URL") or self.links.get("PORTAL_URL") or "").rstrip("/")
        elif which == "heraldlite":
            target = self.settings.get("hl_target", "https://play.openvanilla.app")
            self.link = ap_link.HeraldLiteLink(ROOT, self.folder, target, self.settings.get("hl_user", ""),
                                               self.hl_password(), self.settings.get("hl_char") or "Herald",
                                               self.settings.get("hl_class", "Hunter"))
            self.learner.base = target.rstrip("/") if "//" in target else ""
        else:
            self.link = ap_link.RealmLink(which, launcher_token())
            self.learner.base = which.rstrip("/")
        self.realm = {"name": "…", "autoplay_allowed": False, "message": "Checking the realm…"}
        self.chars = []
        self.state = None

        def work():
            info = self.link.realm_info()
            chars = self.link.characters() if info.get("reachable", True) else []
            profiles = self.learner.fetch_profiles()
            self.events_q.put(("realm", (info, chars, profiles)))
        threading.Thread(target=work, daemon=True).start()
        if not quiet:
            self.log("state", f"Realm: {self.link.label}.")
        if which == "heraldlite":
            self.log("log", "Herald Lite plays a separate account. To watch Herald play YOUR character "
                            "(any race, any class): log in to the game and click Herald by the minimap.")

    def hl_password(self):
        """The bot account's password: kept encrypted for this Windows user, or for this session only."""
        if getattr(self, "_hl_pass", None):
            return self._hl_pass
        blob = self.settings.get("hl_pass")
        if blob:
            try:
                sys.path.insert(0, os.path.join(ROOT, "launcher"))
                import account
                return account.unprotect(blob) or os.environ.get("HL_PASS", "")
            except Exception:
                pass
        return os.environ.get("HL_PASS", "")

    def save_hl(self, target, user, password, char):
        self.settings.d.update(hl_target=target, hl_user=user.strip(), hl_char=char.strip() or "Herald")
        if password:
            self._hl_pass = password
            try:
                sys.path.insert(0, os.path.join(ROOT, "launcher"))
                import account
                blob = account.protect(password)
            except Exception:
                blob = None
            if blob:
                self.settings.d["hl_pass"] = blob
        self.settings.save()
        self.connect("heraldlite")
        self.show("settings")

    def character(self):
        name = self.settings.get("character")
        for c in self.chars:
            if c.get("name") == name:
                return c
        return self.chars[0] if self.chars else None

    def current_rules(self):
        c = self.character()
        cls = c["cls"] if c else "Hunter"
        level = (self.state or {}).get("level") or (c or {}).get("level", 1)
        chosen = self.settings.get("rules", {}).get(cls, {})
        return cls, level, core.merged_rules(cls, level, chosen, self.profiles)

    # ------------------------------------------------------------------ start / stop
    def can_start(self):
        c = self.character()
        return bool(self.realm.get("autoplay_allowed") and c and (c.get("online", True)))

    def why_not(self):
        if not self.realm.get("reachable", True):
            return self.realm.get("message") or "Can't reach the realm."
        if not self.realm.get("autoplay_allowed"):
            return self.realm.get("message") or "This realm doesn't allow autoplay."
        c = self.character()
        if not c:
            return "No characters. Sign in with the Open Vanilla launcher, then log a character in."
        if not c.get("online", True):
            return f"Log {c['name']} in first."
        return ""

    def toggle_run(self):
        if self.running:
            self.stop()
        else:
            self.start()

    def start(self):
        if not self.can_start():
            self.log("state", self.why_not())
            self.draw_dynamic()
            return
        c = self.character()
        cls, level, rules = self.current_rules()
        goal = core.GOAL_BY_ID[self.goal]
        plan = core.plan(cls, goal.id, rules)
        ok, msg = self.link.start(c["name"], plan)
        if not ok:
            self.log("state", msg)
            return
        self.running = True
        self.session = core.Session(character=c["name"], cls=cls, goal=goal.id)
        if not isinstance(self.link, ap_link.DemoLink):
            self._poller(self.link)
        self.session_level = level
        self.learner.touch()
        self.draw_dynamic()

    def stop(self, reason=""):
        if not self.running:
            return
        self.link.stop()
        self.running = False
        if reason:
            self.log("state", reason)
        self.end_session()
        self.draw_dynamic()

    def end_session(self):
        s = self.session
        if not s:
            return
        s.ended = time.time()
        cls, _level, rules = self.current_rules()
        self.learner.note_session(s.cls, self.session_level, s.goal, s.summary(), rules)
        self.learner.touch()
        self.upload_soon(session_ended=True)
        if self.settings.get("bring_front", True):
            try:
                self.deiconify()
                self.lift()
                self.bell()
            except tk.TclError:
                pass

    def pause(self):
        if not self.running or not self.session:
            return
        if self.session.paused:
            if self.link.resume() is not False:
                self.session.resume()
        elif self.link.pause() is not False:
            self.session.pause()
        self.draw_dynamic()

    def _poller(self, link):
        """A realm is polled from a thread every 1.5 s, so a slow link never freezes the window."""
        def work():
            while self.running and self.link is link:
                try:
                    events, state = link.poll()
                    self.events_q.put(("poll", (link, events, state)))
                except Exception:
                    pass
                time.sleep(1.5)
        threading.Thread(target=work, daemon=True).start()

    def upload_soon(self, session_ended=False):
        def work():
            r = self.learner.maybe_upload(self.running, session_ended)
            if r:
                self.events_q.put(("learned", r))
        threading.Thread(target=work, daemon=True).start()

    # ------------------------------------------------------------------ the loop
    def loop(self):
        try:
            self._loop()
        finally:
            self.after(TICK_MS, self.loop)

    def _loop(self):
        now = time.time()
        dt = now - getattr(self, "_last_tick", now)
        self._last_tick = now
        while True:
            try:
                kind, payload = self.events_q.get_nowait()
            except queue.Empty:
                break
            if kind == "realm":
                info, chars, profiles = payload
                self.realm, self.chars = info, chars
                if profiles:
                    self.profiles = profiles
                if self.page in ("play", "rules", "settings"):
                    self.show(self.page)
                self.draw_dynamic()
            elif kind == "sim":
                self.sim_result, self.sim_busy = payload, False
                if self.page == "sim":
                    self.show("sim")
            elif kind == "poll":
                link, events, state = payload
                if link is self.link:
                    if state:
                        self.state = state
                    for ev in events:
                        self.on_event(ev)
            elif kind == "learned":
                if self.page == "settings":
                    self.show("settings")
        if self.link:
            if isinstance(self.link, ap_link.DemoLink):   # the demo runs here; a realm is polled by _poller
                if self.running:
                    self.link.tick(dt)
                events, state = self.link.poll()
                if state:
                    self.state = state
                for ev in events:
                    self.on_event(ev)
            if self.running and self.session:
                lim = core.stop_after_seconds(self.current_rules()[2])
                if lim and self.session.elapsed() >= lim:
                    self.stop(f"Stopped after {core.clock(lim)}, as the rules say.")
            if self.running and getattr(self.link, "running", True) is False:  # the demo stopped itself
                self.running = False
                self.end_session()
        self._frame = getattr(self, "_frame", 0) + 1
        if self._frame % 2 == 0:
            self.draw_dynamic()
            if self.page == "session":
                self.refresh_session()
        if self._frame % 240 == 0 and not self.running:   # once a minute
            self.upload_soon()

    def on_event(self, ev):
        if self.session:
            self.session.apply(ev)
        if ev.kind == "death":
            self.last_death = time.time()
            if self.session:
                self.learner.note_death(self.session.cls, (self.state or {}).get("level", 1), self.session.goal, ev.data)
        if ev.kind == "level" and self.running and self.current_rules()[2].get("stop") == "ding":
            self.after(100, lambda: self.stop("New level: stopping, as the rules say."))
        if ev.text:
            self.log(ev.kind, ev.text, ev.t)

    def log(self, kind, text, t=None):
        stamp = time.strftime("%H:%M:%S", time.localtime(t or time.time()))
        self.log_lines.append((stamp, kind, text))
        del self.log_lines[:-500]
        box = getattr(self, "logbox", None)
        if box is not None and box.winfo_exists():
            self._log_insert(box, stamp, kind, text)

    def _log_insert(self, box, stamp, kind, text):
        box.configure(state="normal")
        box.insert("end", f"[{stamp}] ", "time")
        box.insert("end", text + "\n", kind if kind in LOG_COL else "log")
        n = int(box.index("end-1c").split(".")[0])
        if n > 400:
            box.delete("1.0", f"{n - 400}.0")
        box.configure(state="disabled")
        box.see("end")

    # ------------------------------------------------------------------ dynamic panels
    def draw_dynamic(self):
        cv = self.cv
        cv.delete("dyn")
        # status under the title
        if self.running and self.session and self.session.paused:
            st, col = "PAUSED", YELLOW
        elif self.running:
            st, col = "RUNNING", GREEN
        elif self.can_start():
            st, col = "READY", GOLD
        else:
            st, col = "OFF", MUTED
        x = self.text(122, 66, "STATUS:", "h2", PARCH, tag="dyn")
        bb = cv.bbox(x)
        self.text(bb[2] + 8, 66, st, "h2", col, tag="dyn")
        realm_name = self.realm.get("name") or self.link.label
        self.text(bb[2] + 8 + 110, 68, f"·  {realm_name}", "ui", MUTED, tag="dyn")
        # nav highlight
        nx0, ny0, _, _ = L["nav"]
        for i, name in enumerate(art.NAV):
            on = name == self.page
            x, y = nx0 + 16, ny0 + 12 + i * 56
            cv.itemconfig(f"navbar_{name}", image=self.img(f"knav_{name}_on.png" if on else f"knav_{name}.png"))
            cv.coords(f"navbar_{name}", (x - 10, y - 10) if on else (x, y))
            cv.itemconfig(f"navlabel_{name}", image=self.emboss(art.NAV_LABELS[name], "nav", GOLD if on else PARCH))
        self.draw_control()
        if self.page == "play":
            self.draw_map()
            self.draw_bags()
            self.draw_realm()
            self.draw_play_stats()
        if self.cv.find_withtag("modal"):
            self.cv.tag_raise("modal")

    def draw_control(self):
        x0, y0, x1, y1 = L["control"]
        cx = (x0 + x1) // 2
        if self.running:
            name, label, sub = "stop", "STOP", ("paused" if self.session and self.session.paused else
                                                f"running {core.clock(self.session.elapsed()) if self.session else ''}")
        elif self.can_start():
            name, label, sub = "start", "START", core.GOAL_BY_ID[self.goal].label.lower()
        else:
            name, label, sub = "off", "START", "not available"
        btn = self.cv.create_image(cx, y0 + 62, image=self.img(f"kit_{name}.png"), anchor="center", tags="dyn")
        t1 = self.text(cx, y0 + 54, label, "btn", "#fff6d8", "center", "dyn")
        t2 = self.text(cx, y0 + 76, sub.upper(), "ui_s", "#f2ecd2" if name != "off" else "#c0c0c0", "center", "dyn")
        if name != "off":
            self._clickable([btn, t1, t2], self.toggle_run, lambda on: self.cv.itemconfig(
                btn, image=self.img(f"kit_{name}_hover.png" if on else f"kit_{name}.png")))
        else:
            self._clickable([btn, t1, t2], lambda: (self.log("state", self.why_not()), self.show("play")))
        # pause + hint
        if self.running:
            self.button(x0 + 24, y0 + 114, 96, 28, "RESUME" if self.session and self.session.paused else "PAUSE",
                        self.pause, "dyn")
            self.text(x0 + 132, y0 + 128, "Space = pause", "ui_s", MUTED, "w", "dyn")
        else:
            why = self.why_not()
            self.text(cx, y0 + 116, why or "Pick a goal, then START.", "ui_s", MUTED if why else GOLD_DIM, "n", "dyn",
                      width=210, justify="center")

    def draw_map(self):
        x0, y0, x1, y1 = L["map"]
        mx, my = x0 + 9, y0 + 24
        st = self.state or {}
        self.cv.create_image(mx, my, image=self.img("map_elwynn.png"), anchor="nw", tags="dyn")
        mw, mh = art.MAP_SIZE
        if st.get("path"):
            pts = []
            for px, py in st["path"] + st["path"][:1]:
                pts += [mx + px * mw, my + py * mh]
            self.cv.create_line(*pts, fill="#f3e2a8", width=2, dash=(4, 3), tags="dyn")
            for px, py in st["path"]:
                self.cv.create_oval(mx + px * mw - 2, my + py * mh - 2, mx + px * mw + 2, my + py * mh + 2,
                                    fill="#f3e2a8", outline="", tags="dyn")
        if st.get("pos"):
            px, py = st["pos"]
            self.cv.create_image(mx + px * mw, my + py * mh, image=self.img("dot_herald.png"), tags="dyn")
            self.text(mx + px * mw + 10, my + py * mh - 16, st.get("name", ""), "ui_s", "#ffffff", tag="dyn")
        elif not isinstance(self.link, ap_link.DemoLink):
            self.cv.create_rectangle(mx, my, mx + mw, my + mh, fill="#05070d", outline="", stipple="gray75", tags="dyn")
            self.text(mx + mw // 2, my + mh // 2, "The map lights up when the realm\nshares where Herald is.", "ui_b",
                      PARCH, "center", "dyn", justify="center")
        status = {"travel": "On the move", "combat": "Fighting", "rest": "Resting", "vendor": "Going to sell",
                  "dead": "Dead · running back", "paused": "Paused", "idle": "Standing by"}.get(st.get("status"), "")
        tgt = st.get("target")
        if tgt and st.get("status") == "combat":
            status += f": {tgt['name']} (Lvl {tgt['level']})"
        if status:
            self.cv.create_rectangle(mx, my + mh - 22, mx + mw, my + mh, fill="#0b0f1a", outline="", stipple="gray50", tags="dyn")
            self.text(mx + 8, my + mh - 11, status, "ui_s", PARCH, "w", "dyn")

    def draw_bags(self):
        x0, y0, x1, y1 = L["bags"]
        st = self.state or {}
        bags = st.get("bags") or []
        slots = st.get("bag_slots", 16)
        for i in range(14):
            col, row = i % 7, i // 7
            sx, sy = x0 + 9 + col * 39, y0 + 24 + row * 40
            it = bags[i] if i < len(bags) else None
            q = it["quality"] if it else None
            self.cv.create_image(sx, sy, image=self.img("slot_green.png" if (q or 0) >= 2 else "slot.png"), anchor="nw", tags="dyn")
            if it:
                ic = self.cv.create_image(sx + 2, sy + 2, image=self.img(f"item_{it['icon']}.png"), anchor="nw", tags="dyn")
                if it["count"] > 1:
                    self.text(sx + 34, sy + 34, str(it["count"]), "ui_s", "#ffffff", "se", "dyn")
                self._tooltip(ic, it["name"], ITEM_Q.get(it["quality"], TEXT))
        used = len(bags)
        money = core.money(st.get("money", 0)) if st else "—"
        if st and st.get("bags") is None:
            label = "This realm doesn't share bags yet."
        else:
            label = f"{used}/{slots} slots" if st else "Bags appear when Herald plays."
        self.text(x0 + 12, y1 - 14, label, "ui_s", MUTED, "w", "dyn")
        if st:
            self.money(x1 - 12, y1 - 14, st.get("money", 0))

    def _tooltip(self, item, text, color):
        def show(_e):
            self.cv.delete("tip")
            bb = self.cv.bbox(item)
            t = self.cv.create_text(bb[0], bb[1] - 8, text=text, font=self.F["ui_b"], fill=color, anchor="sw", tags=("dyn", "tip"))
            tb = self.cv.bbox(t)
            r = self.cv.create_rectangle(tb[0] - 6, tb[1] - 3, tb[2] + 6, tb[3] + 3, fill="#0b0f1a", outline="#b8995a",
                                         tags=("dyn", "tip"))
            self.cv.tag_lower(r, t)
        self.cv.tag_bind(item, "<Enter>", show)
        self.cv.tag_bind(item, "<Leave>", lambda e: self.cv.delete("tip"))

    def draw_realm(self):
        x0, y0, x1, y1 = L["realm"]
        allowed = self.realm.get("autoplay_allowed")
        reachable = self.realm.get("reachable", True)
        tag = self.realm.get("tag", "[Autopilot]")
        learn = self.learner.consent
        rows = [
            ("on" if allowed else ("no" if reachable else "warn"),
             "Autoplay allowed here" if allowed else ("Autoplay is off here" if reachable else "Can't reach the realm")),
            ("on" if allowed else "off", f"Others see {tag} on you" if tag else "Plays on the realm's own AI"),
            ("on" if learn else ("warn" if learn is None else "off"),
             "Learning: on (anonymous)" if learn else ("Learning: not asked yet" if learn is None else "Learning: off")),
        ]
        for i, (icon, label) in enumerate(rows):
            y = y0 + 24 + i * 27
            img = {"on": "kit_check_on.png", "off": "kit_check_off.png"}.get(icon, f"check_{icon}.png")
            self.cv.create_image(x0 + 26, y + 10, image=self.img(img), anchor="center", tags="dyn")
            t = self.text(x0 + 46, y + 10, label, "ui", TEXT if icon == "on" else MUTED, "w", "dyn")
            if i == 2:
                self._clickable([t], lambda: self.show("settings"))

    def draw_play_stats(self):
        if self.page != "play":
            return
        x0, y0, x1, y1 = L["center_bottom"]
        st = self.state or {}
        s = self.session
        # XP bar
        y = y0 + 186
        lvl = st.get("level") or (self.character() or {}).get("level")
        if lvl:
            frac = (st.get("xp", 0) / st["xp_max"]) if st.get("xp_max") else 0
            bw = x1 - x0 - 48
            self.cv.create_image(x0 + 24, y, image=self.pil(f"xpbar_{int(frac * 200)}", lambda: art.bar(bw, 14, (150, 90, 220), frac)),
                                 anchor="nw", tags="dyn")
            self.text((x0 + x1) // 2, y + 7, f"Level {lvl}" + (f"  ·  {int(frac * 100)}% to {lvl + 1}" if st.get("xp_max") else ""),
                      "ui_s", "#ffffff", "center", "dyn")
            if st.get("hp_max"):
                hw = (bw - 10) // 2
                self.cv.create_image(x0 + 24, y + 20, image=self.pil(f"hp_{int(st['hp'] / st['hp_max'] * 100)}", lambda: art.bar(
                    hw, 10, (60, 190, 70), st["hp"] / st["hp_max"])), anchor="nw", tags="dyn")
                if st.get("mana_max"):
                    self.cv.create_image(x0 + 34 + hw, y + 20, image=self.pil(f"mp_{int(st['mana'] / st['mana_max'] * 100)}",
                                         lambda: art.bar(hw, 10, (60, 110, 230), st["mana"] / st["mana_max"])), anchor="nw", tags="dyn")
        # numbers
        sy = y0 + 230
        early = not s or s.elapsed() < 30
        cols = [("XP / HOUR", "…" if s and early else (f"{s.per_hour(s.xp):,}" if s else "—")), ("KILLS", f"{s.kills}" if s else "—"),
                ("LOOT", core.money(s.loot_copper) if s else "—"), ("DEATHS", f"{s.deaths}" if s else "—"),
                ("TIME", core.clock(s.elapsed()) if s else "—")]
        cw = (x1 - x0 - 40) / len(cols)
        for i, (k, v) in enumerate(cols):
            cx = x0 + 20 + cw * i + cw / 2
            self.text(cx, sy, k, "h3", GOLD_DIM, "center", "dyn")
            if k == "LOOT" and s:
                self.money_centered(cx, sy + 22, s.loot_copper, ("dyn",))
                continue
            self.text(cx, sy + 22, v, "num", GREEN if k == "XP / HOUR" and s else (RED if k == "DEATHS" and s and s.deaths else PARCH),
                      "center", "dyn")

    # ------------------------------------------------------------------ pages
    def show(self, page):
        self.page = page
        self.cv.delete("page")
        for w in self.page_widgets:
            try:
                w.destroy()
            except tk.TclError:
                pass
        self.page_widgets = []
        self.logbox = None
        self.cv.itemconfig(self.bg_item, image=self.img("bg_play.png" if page == "play" else "bg_wide.png"))
        getattr(self, f"page_{page}")()
        self.cv.tag_raise("dyn")
        self.draw_dynamic()

    def textbox(self, box, pad=(16, 22, 16, 14), height=None):
        x0, y0, x1, y1 = L[box]
        t = tk.Text(self, bg="#0c1120", fg=TEXT, insertbackground=GOLD, relief="flat", bd=0, highlightthickness=1,
                    highlightbackground="#3a3020", highlightcolor="#5e4a26", font=self.F["log"], wrap="word",
                    padx=8, pady=6, cursor="arrow")
        sb = tk.Scrollbar(self, command=t.yview, bg="#1b2236", troughcolor="#0c1120", activebackground="#5e4a26",
                          relief="flat", bd=0, width=10, highlightthickness=0, elementborderwidth=0)
        t.configure(yscrollcommand=sb.set)
        x, y = x0 + pad[0], y0 + pad[1]
        w, h = x1 - x0 - pad[0] - pad[2] - 12, (height or (y1 - y0 - pad[1] - pad[3]))
        self.cv.create_window(x, y, window=t, anchor="nw", width=w, height=h, tags="page")
        self.cv.create_window(x + w + 2, y, window=sb, anchor="nw", width=10, height=h, tags="page")
        self.page_widgets += [t, sb]
        t.tag_configure("time", foreground="#6f7790")
        for k, c in LOG_COL.items():
            t.tag_configure(k, foreground=c)
        t.tag_configure("h", foreground=GOLD, font=self.F["ui_b"])
        t.tag_configure("muted", foreground=MUTED)
        return t

    # -- Play
    def page_play(self):
        self.plaque_title("map", "Live map")
        self.plaque_title("bags", "Bags")
        self.plaque_title("realm", "This realm")
        self.plaque_title("center_top", "Live log")
        self.logbox = self.textbox("center_top", (16, 26, 16, 14))
        if not self.log_lines:
            self.log("state", "Herald is ready. Pick a goal below, then press START.")
            if isinstance(self.link, ap_link.DemoLink):
                self.log("log", "This is the offline demo: Herald levels a hunter in Elwynn Forest. "
                                "Settings switches to a real realm.")
        else:
            for stamp, kind, text in self.log_lines[-300:]:
                self._log_insert(self.logbox, stamp, kind, text)
        self.plaque_title("center_bottom", "Choose a goal")
        x0, y0, x1, y1 = L["center_bottom"]
        # character + realm row
        c = self.character()
        names = [f"{ch['name']} · {ch.get('cls', '?')} {ch.get('level', '')}" + ("" if ch.get("online", True) else " (offline)")
                 for ch in self.chars]
        self.text(x0 + 24, y0 + 32, "Character", "h3", GOLD_DIM, "w")
        if names:
            cur = next((n for n in names if c and n.startswith(c["name"] + " ")), names[0])
            self.pill(x0 + 110, y0 + 19, 230, cur, names, self.pick_character)
        else:
            self.text(x0 + 110, y0 + 32, self.why_not() or "Loading…", "ui", MUTED, "w", width=330)
        # goals: the kit's medallions, the chosen one glowing
        gx, gy = x0 + 24, y0 + 54
        for i, g in enumerate(core.GOALS):
            cx = gx + i * 88 + 44
            on = g.id == self.goal
            ic = self.cv.create_image(cx, gy + 30, image=self.img(f"kgoal_{g.id}_on.png" if on else f"kgoal_{g.id}.png"),
                                      tags="page")
            lb = self.text(cx, gy + 72, g.label, "h3", GOLD if on else PARCH, "center")
            self._clickable([ic, lb], lambda gid=g.id: self.pick_goal(gid),
                            None if on else (lambda on_, ic=ic, gid=g.id: self.cv.itemconfig(ic, image=self.img(
                                f"kgoal_{gid}_hover.png" if on_ else f"kgoal_{gid}.png"))))
        g = core.GOAL_BY_ID[self.goal]
        self.text(x0 + 24, y0 + 160, g.blurb + ("  Needs a group." if g.needs_group else ""), "ui", TEXT, "w")
        self.button(x1 - 120, y0 + 148, 96, 26, "RULES ›", lambda: self.show("rules"))

    def pick_goal(self, gid):
        self.goal = gid
        self.settings.set("goal", gid)
        if self.running:
            self.log("state", "New goal: it takes effect next time you press START.")
        self.show("play")

    def pick_character(self, label):
        name = label.split(" · ")[0]
        self.settings.set("character", name)
        self.show(self.page)

    # -- Rules
    def page_rules(self):
        self.plaque_title("center_wide", "Rules")
        x0, y0, x1, y1 = L["center_wide"]
        cls, level, rules = self.current_rules()
        chosen = self.settings.get("rules", {}).get(cls, {})
        note = core.learned_note(cls, level, self.profiles)
        self.text(x0 + 24, y0 + 30, f"{cls}, level {level}", "h1", GOLD)
        self.text(x0 + 24, y0 + 56, (note + ". " if note else "Class defaults. ") +
                  "Change anything; your choices always win.", "ui", MUTED)
        y = y0 + 88
        group = None
        for rule in core.RULES:
            if not rule.applies(cls):
                continue
            if rule.group != group:
                group = rule.group
                self.text(x0 + 24, y, group.upper(), "h3", GOLD_DIM)
                self.cv.create_line(x0 + 24 + 90, y + 8, x1 - 24, y + 8, fill="#3a3020", tags="page")
                y += 24
            value = rules[rule.key]
            mine = rule.key in chosen
            t = self.text(x0 + 36, y + 13, rule.before.strip() or " ", "ui_l", TEXT, "w")
            bx = self.cv.bbox(t)[2] + 8
            pw = max(70, min(300, self.measure("ui_b", rule.label_of(value)) + 36))
            self.pill(bx, y, pw, rule.label_of(value), rule.labels(), lambda lab, r=rule: self.set_rule(r, lab))
            if rule.after:
                self.text(bx + pw + 6, y + 13, rule.after.strip(), "ui_l", TEXT, "w")
            if mine:
                self.text(x1 - 30, y + 13, "yours", "ui_s", GREEN, "e")
            y += 34
        self.button(x0 + 24, y1 - 46, 170, 28, "RESET TO DEFAULTS", self.reset_rules)
        if self.running and not isinstance(self.link, ap_link.DemoLink):
            self.text(x0 + 210, y1 - 32, "Changes apply next time you press START.", "ui_s", MUTED, "w")

    def set_rule(self, rule, label):
        cls, level, rules = self.current_rules()
        new = rule.value_of(label)
        old = rules.get(rule.key)
        all_rules = self.settings.get("rules", {})
        all_rules.setdefault(cls, {})[rule.key] = new
        self.settings.set("rules", all_rules)
        self.learner.note_change(cls, level, rule.key, old, new, after_death=time.time() - self.last_death < 300)
        if self.running and isinstance(self.link, ap_link.DemoLink):
            self.link.rules[rule.key] = new
        self.show("rules")

    def reset_rules(self):
        cls, _, _ = self.current_rules()
        all_rules = self.settings.get("rules", {})
        all_rules.pop(cls, None)
        self.settings.set("rules", all_rules)
        if self.running and isinstance(self.link, ap_link.DemoLink):
            self.link.rules.update(self.current_rules()[2])
        self.show("rules")

    # -- Sim
    def page_sim(self):
        self.plaque_title("center_wide", "Sim")
        x0, y0, x1, y1 = L["center_wide"]
        c = self.character()
        default_cls = c["cls"] if c and c.get("cls") in ap_sim.SIMMABLE else "Hunter"
        cls = self.settings.get("sim_class", default_cls)
        self.text(x0 + 24, y0 + 30, "Compare two sets of stats", "h1", GOLD)
        self.text(x0 + 24, y0 + 56, "Level 60 against a raid boss, 3 minutes, simulated hundreds of times.", "ui", MUTED)
        self.text(x0 + 24, y0 + 92, "Class", "h3", GOLD_DIM, "w")
        self.pill(x0 + 84, y0 + 79, 130, cls, list(ap_sim.SIMMABLE), self.pick_sim_class)
        saved = self.settings.get("sim_values", {}).get(cls, {})
        fields = ap_sim.fields_for(cls)
        preset = ap_sim.PRESETS[cls]
        self.sim_entries = {"a": {}, "b": {}}
        colx = {"a": x0 + 250, "b": x0 + 350}
        self.text(colx["a"] + 40, y0 + 122, "NOW", "h3", GOLD_DIM, "center")
        self.text(colx["b"] + 40, y0 + 122, "UPGRADE", "h3", GOLD_DIM, "center")
        for i, (key, label) in enumerate(fields):
            y = y0 + 140 + i * 30
            self.text(x0 + 36, y + 11, label, "ui", TEXT, "w")
            for side in ("a", "b"):
                e = tk.Entry(self, bg="#0c1120", fg="#ffffff", insertbackground=GOLD, relief="flat", bd=0,
                             highlightthickness=1, highlightbackground="#5e4a26", highlightcolor=GOLD, font=self.F["ui_b"],
                             justify="center")
                v = saved.get(side, {}).get(key, getattr(preset, key))
                e.insert(0, f"{v:g}" if isinstance(v, (int, float)) else str(v))
                self.cv.create_window(colx[side], y, window=e, anchor="nw", width=80, height=24, tags="page")
                self.page_widgets.append(e)
                self.sim_entries[side][key] = e
        yb = y0 + 140 + len(fields) * 30 + 8
        debuffs = self.settings.get("sim_debuffs", True)
        self.toggle(x0 + 36, yb, debuffs, lambda: (self.settings.set("sim_debuffs", not debuffs), self.show("sim")))
        self.text(x0 + 88, yb + 11, "Boss armour lowered by the usual debuffs", "ui", TEXT, "w")
        self.button(x0 + 36, yb + 36, 150, 32, "SIMULATING…" if self.sim_busy else "RUN SIM", self.run_sim,
                    tone="green", font="btn_s", enabled=not self.sim_busy)
        self.button(x0 + 196, yb + 36, 120, 32, "RESET", lambda: self.reset_sim(cls))
        # results
        rx = x0 + 470
        r = self.sim_result
        if not r or r.get("cls") != cls:
            self.text(rx, y0 + 122, "RESULT", "h3", GOLD_DIM)
            self.text(rx, y0 + 146, "Put your current stats on the left\nand the upgrade's on the right,\nthen RUN SIM.",
                      "ui", MUTED)
            return
        ra, rb, pct = r["a"], r["b"], r["pct"]
        self.text(rx, y0 + 122, "RESULT", "h3", GOLD_DIM)
        col = GREEN if pct > 0.3 else (RED if pct < -0.3 else PARCH)
        self.text(rx, y0 + 140, f"{pct:+.1f}%", "title", col)
        self.text(rx, y0 + 180, "Upgrade is " + ("better" if pct > 0.3 else ("worse" if pct < -0.3 else "about the same")),
                  "ui_b", col)
        top = max(ra.dps, rb.dps) or 1
        for i, (lab, res) in enumerate((("Now", ra), ("Upgrade", rb))):
            y = y0 + 210 + i * 34
            self.text(rx, y, lab, "ui_s", MUTED)
            bw = int(240 * res.dps / top)
            self.cv.create_rectangle(rx, y + 14, rx + bw, y + 28, fill="#3b8f4f" if i else "#5a6a9a", outline="", tags="page")
            self.text(rx + bw + 6, y + 21, f"{res.dps:,.0f} DPS", "ui_b", TEXT, "w")
        y = y0 + 290
        self.text(rx, y, "WHERE IT COMES FROM (UPGRADE)", "h3", GOLD_DIM)
        for i, (name, dps) in enumerate(list(rb.by_ability.items())[:4]):
            self.text(rx, y + 22 + i * 20, name, "ui", TEXT)
            self.text(rx + 270, y + 22 + i * 20, f"{dps:,.0f}", "ui_b", PARCH, "ne")
        y += 22 + 4 * 20 + 10
        self.text(rx, y, "WHAT EACH STAT IS WORTH", "h3", GOLD_DIM)
        for i, (name, v) in enumerate(r["weights"].items()):
            self.text(rx, y + 22 + i * 20, name, "ui", TEXT)
            self.text(rx + 270, y + 22 + i * 20, f"+{v:.1f} DPS", "ui_b", GREEN, "ne")

    def pick_sim_class(self, cls):
        self.settings.set("sim_class", cls)
        self.show("sim")

    def reset_sim(self, cls):
        vals = self.settings.get("sim_values", {})
        vals.pop(cls, None)
        self.settings.set("sim_values", vals)
        self.sim_result = None
        self.show("sim")

    def run_sim(self):
        if self.sim_busy:
            return
        cls = self.settings.get("sim_class") or ((self.character() or {}).get("cls") if (self.character() or {}).get("cls") in ap_sim.SIMMABLE else "Hunter")
        raw = {side: {k: e.get() for k, e in self.sim_entries[side].items()} for side in ("a", "b")}
        vals = self.settings.get("sim_values", {})
        vals[cls] = raw
        self.settings.set("sim_values", vals)
        a, b = ap_sim.stats_from(cls, raw["a"]), ap_sim.stats_from(cls, raw["b"])
        debuffs = self.settings.get("sim_debuffs", True)
        self.sim_busy = True
        self.show("sim")

        def work():
            ra, rb, pct = ap_sim.compare(cls, a, b, debuffs=debuffs)
            weights = ap_sim.stat_weights(cls, b, iterations=300, debuffs=debuffs)
            self.events_q.put(("sim", {"cls": cls, "a": ra, "b": rb, "pct": pct, "weights": weights}))
        threading.Thread(target=work, daemon=True).start()

    # -- Session
    def page_session(self):
        self.plaque_title("center_wide", "Session")
        x0, y0, x1, y1 = L["center_wide"]
        self.session_box = self.textbox("center_wide", (16, 156, 16, 52))
        self.refresh_session(full=True)
        bf = self.settings.get("bring_front", True)
        self.toggle(x0 + 24, y1 - 40, bf, lambda: (self.settings.set("bring_front", not bf), self.show("session")))
        self.text(x0 + 76, y1 - 29, "Bring this window to the front and chime when a run stops", "ui", TEXT, "w")

    def refresh_session(self, full=False):
        x0, y0, x1, y1 = L["center_wide"]
        self.cv.delete("sess")
        s = self.session
        if not s:
            self.text((x0 + x1) // 2, y0 + 80, "No run yet. Press START and the numbers show up here.", "ui_l", MUTED,
                      "center", "sess")
        else:
            tiles = [("TIME", core.clock(s.elapsed())), ("XP / HOUR", "…" if s.elapsed() < 30 else f"{s.per_hour(s.xp):,}"), ("KILLS", f"{s.kills}"),
                     ("LOOT", core.money(s.loot_copper)), ("DEATHS", f"{s.deaths}"), ("LEVELS", f"+{s.levels}")]
            tw = (x1 - x0 - 48) / 3
            for i, (k, v) in enumerate(tiles):
                cx = x0 + 24 + (i % 3) * tw + tw / 2
                cy = y0 + 34 + (i // 3) * 58
                self.cv.create_rectangle(cx - tw / 2 + 4, cy - 4, cx + tw / 2 - 4, cy + 48, fill="#121a2e", outline="#3a3020",
                                         tags=("page", "sess"))
                self.text(cx, cy + 4, k, "h3", GOLD_DIM, "n", ("page", "sess"))
                if k == "LOOT":
                    self.money_centered(cx, cy + 32, s.loot_copper, ("page", "sess"))
                else:
                    self.text(cx, cy + 20, v, "num", RED if k == "DEATHS" and s.deaths else PARCH, "n", ("page", "sess"))
        box = getattr(self, "session_box", None)
        if box is None or not box.winfo_exists():
            return
        n = len(s.timeline) if s else 0
        if full or n != getattr(self, "_sess_n", -1):
            self._sess_n = n
            box.configure(state="normal")
            box.delete("1.0", "end")
            if not s or not s.timeline:
                box.insert("end", "What happens during a run is listed here: kills, loot worth noting, levels, deaths.\n", "muted")
            else:
                for t, kind, text in s.timeline[-300:]:
                    box.insert("end", time.strftime("%H:%M:%S  ", time.localtime(t)), "time")
                    box.insert("end", text + "\n", kind)
            box.configure(state="disabled")
            box.see("end")

    # -- Settings
    def page_settings(self):
        self.plaque_title("center_wide", "Settings")
        x0, y0, x1, y1 = L["center_wide"]
        url = self.links.get("BACKEND_URL") or self.links.get("PORTAL_URL") or ""
        realm_now = self.settings.get("realm") or "demo"
        options = (["Demo (offline)"] + ([f"Vanilla Remastered ({url.split('//')[-1].rstrip('/')})"] if url else [])
                   + ["Herald Lite (a bot account)", "Another realm…"])
        if realm_now == "heraldlite" and ap_link.hl_host(self.settings.get("hl_target", "")) in ("127.0.0.1", "localhost"):
            options[options.index("Herald Lite (a bot account)")] = "Your server (this PC)"
        if realm_now == "demo":
            cur = "Demo (offline)"
        elif realm_now == "heraldlite":
            local = ap_link.hl_host(self.settings.get("hl_target", "")) in ("127.0.0.1", "localhost")
            cur = "Your server (this PC)" if local else "Herald Lite (a bot account)"
        elif url and realm_now.rstrip("/") == url.rstrip("/"):
            cur = options[1]
        else:
            cur = realm_now.split("//")[-1]
        self.text(x0 + 24, y0 + 30, "REALM", "h3", GOLD_DIM)
        self.pill(x0 + 24, y0 + 48, 330, cur, options, lambda o: self.pick_realm(o, url))
        if realm_now == "heraldlite":
            self.heraldlite_fields(x0 + 380, y0 + 24)
            msg = self.realm.get("message", "")
            self.text(x0 + 24, y0 + 88, msg, "ui", GREEN if self.realm.get("autoplay_allowed") else MUTED, width=330)
        else:
            tok = launcher_token() if realm_now != "demo" else None
            self.text(x0 + 24, y0 + 88, ("Signed in through the Open Vanilla launcher." if tok else
                                         ("Not signed in: open the Open Vanilla launcher and sign in." if realm_now != "demo" else
                                          "The demo needs no sign-in.")), "ui", GREEN if tok else MUTED)
        # learning
        y = y0 + 124
        self.cv.create_line(x0 + 24, y, x1 - 24, y, fill="#3a3020", tags="page")
        self.text(x0 + 24, y + 14, "HELP HERALD LEARN", "h3", GOLD_DIM)
        on = self.learner.consent is True
        self.toggle(x0 + 24, y + 38, on, lambda: self.set_learning(not on))
        self.text(x0 + 78, y + 49, "Share anonymous play stats so Herald's defaults get better for everyone", "ui", TEXT, "w")
        self.text(x0 + 24, y + 72, "Shared: class, level band, goal, XP per hour, kills, deaths, rests and the rules you used. "
                  "Never names, chat, positions or your account. Sent in one small batch after a run, at most every "
                  "30 minutes. Herald downloads what everyone's runs taught him as new default rules.", "ui_s", MUTED,
                  width=x1 - x0 - 48)
        n = self.learner.pending()
        self.text(x0 + 24, y + 132, f"Queued: {n} record{'s' if n != 1 else ''}" +
                  (f"   ·   {self.learner.last_result}" if self.learner.last_result else ""), "ui_s", PARCH)
        self.button(x0 + 24, y + 150, 150, 26, "WHAT'S SHARED", self.preview_learning)
        self.button(x0 + 184, y + 150, 150, 26, "DELETE QUEUED", lambda: (self.learner.clear(), self.show("settings")))
        self.button(x0 + 344, y + 150, 110, 26, "SEND NOW", self.send_now, enabled=on and n > 0)
        self.preview_box = self.textbox("center_wide", (16, y + 188 - y0, 16, 46))
        self.preview_box.configure(font=self.F["mono"])
        self.preview_box.insert("end", "Press WHAT'S SHARED to see the exact text of the next upload.\n", "muted")
        self.preview_box.configure(state="disabled")
        self.text(x0 + 24, y1 - 30, f"Herald Autopilot {VERSION}  ·  data in {self.folder}", "ui_s", MUTED, "w",
                  width=x1 - x0 - 48)

    def heraldlite_fields(self, x, y):
        """Herald Lite's bot account: where, which account, its password, which character."""
        def entry(ex, ey, w, value="", show=""):
            e = tk.Entry(self, bg="#0c1120", fg="#ffffff", insertbackground=GOLD, relief="flat", font=self.F["ui_b"],
                         highlightthickness=1, highlightbackground="#5e4a26", highlightcolor=GOLD, show=show)
            e.insert(0, value)
            self.cv.create_window(ex, ey, window=e, anchor="nw", width=w, height=24, tags="page")
            self.page_widgets.append(e)
            return e
        targets = ["127.0.0.1", "https://play.openvanilla.app", "https://staging.openvanilla.app"]
        cur = self.settings.get("hl_target", targets[0])
        self.text(x, y + 6, "PLAYS ON", "h3", GOLD_DIM)
        self.pill(x + 90, y - 2, 250, cur, targets, lambda t: (self.settings.set("hl_target", t), self.connect("heraldlite"),
                                                             self.show("settings")))
        self.text(x, y + 38, "ACCOUNT", "h3", GOLD_DIM)
        user = entry(x + 90, y + 30, 120, self.settings.get("hl_user", ""))
        self.text(x + 218, y + 38, "PASSWORD", "h3", GOLD_DIM)
        pw = entry(x + 300, y + 30, 100, "", "•")
        self.text(x, y + 70, "CHARACTER", "h3", GOLD_DIM)
        char = entry(x + 90, y + 62, 120, self.settings.get("hl_char", "Herald"))
        self.button(x + 300, y + 61, 100, 26, "SAVE", lambda: self.save_hl(self.settings.get("hl_target", targets[0]),
                                                                          user.get(), pw.get(), char.get()))
        if self.hl_password():
            self.text(x + 350, y + 92, "password saved", "ui_s", MUTED, "n")

    def pick_realm(self, option, url):
        if option.startswith("Demo"):
            self.connect("demo")
        elif option.startswith(("Herald Lite", "Your server")):
            self.connect("heraldlite")
        elif option.startswith("Vanilla") and url:
            self.connect(url)
        else:
            self.ask_url()
            return
        self.show("settings")

    def ask_url(self):
        x0, y0, x1, y1 = L["center_wide"]
        e = tk.Entry(self, bg="#0c1120", fg="#ffffff", insertbackground=GOLD, relief="flat", font=self.F["ui_b"],
                     highlightthickness=1, highlightbackground=GOLD, highlightcolor=GOLD)
        e.insert(0, "https://")
        self.cv.create_window(x0 + 370, y0 + 48, window=e, anchor="nw", width=250, height=26, tags="page")
        self.page_widgets.append(e)
        e.focus_set()

        def go(_ev=None):
            v = e.get().strip()
            if v.startswith("http") and "." in v:
                self.connect(v.rstrip("/"))
                self.show("settings")
        e.bind("<Return>", go)

    def set_learning(self, yes):
        self.learner.set_consent(yes)
        self.show(self.page)

    def preview_learning(self):
        box = self.preview_box
        box.configure(state="normal")
        box.delete("1.0", "end")
        box.insert("end", self.learner.preview())
        box.configure(state="disabled")

    def send_now(self):
        def work():
            r = self.learner.upload()
            self.events_q.put(("learned", r))
        threading.Thread(target=work, daemon=True).start()

    # ------------------------------------------------------------------ first run
    def first_run(self):
        if self.learner.consent is not None:
            return
        cv = self.cv
        for it in cv.find_all():   # text boxes sit above the canvas: hide them under the question
            if cv.type(it) == "window":
                cv.itemconfig(it, state="hidden")
        cv.create_rectangle(0, 0, W, H, fill="#000000", stipple="gray50", outline="", tags="modal")
        bw, bh = 520, 250
        x0, y0 = (W - bw) // 2, (H - bh) // 2
        cv.create_image(x0, y0, image=self.pil("modal_panel", lambda: art.glass_panel(bw, bh, 14)), anchor="nw", tags="modal")
        cv.create_image(x0 + 20, y0 + 22, image=self.img("goal_level.png"), anchor="nw", tags="modal")
        self.text(x0 + 76, y0 + 30, "Help Herald learn?", "h1", GOLD, tag="modal")
        self.text(x0 + 24, y0 + 78, "If you say yes, Herald shares anonymous numbers from your runs (class, level band, "
                  "XP per hour, deaths and the rules you used) so everyone's defaults get smarter. No names, no chat, "
                  "no positions, nothing about your account. You can see exactly what's sent, and turn it off, in Settings.",
                  "ui", TEXT, tag="modal", width=bw - 48)
        self.button(x0 + bw - 290, y0 + bh - 52, 130, 32, "YES, SHARE", lambda: self._consent(True), "modal", "green")
        self.button(x0 + bw - 150, y0 + bh - 52, 126, 32, "NO THANKS", lambda: self._consent(False), "modal")
        cv.tag_raise("modal")

    def _consent(self, yes):
        self.learner.set_consent(yes)
        self.cv.delete("modal")
        self.show(self.page)
        self.log("state", "Thanks! Herald will learn from your runs." if yes else "Okay: nothing is shared. Settings can change it.")
        self.draw_dynamic()

    # ------------------------------------------------------------------ quit
    def quit_app(self):
        if self.running:
            self.stop("Closing: autopilot stopped.")
        self.destroy()


def main(argv=None):
    ap = argparse.ArgumentParser(description="Herald Autopilot")
    ap.add_argument("--demo", action="store_true", help="use the offline demo realm")
    ap.add_argument("--realm", help="a realm's web address (https://…)")
    ap.add_argument("--plain-window", action="store_true", help="use the system's window frame")
    ap.add_argument("--local-server", action="store_true",
                    help="play on the Open Vanilla Server running on this PC (Open Vanilla Server's HERALD button)")
    ap.add_argument("--account", help="with --local-server: the account Herald logs in with")
    a = ap.parse_args(argv)
    if a.local_server:
        s = Settings(data_dir())
        s.d.update(realm="heraldlite", hl_target="127.0.0.1")
        if a.account:
            s.d["hl_user"] = a.account.upper()
        s.save()
    app = App(demo=a.demo, realm_url=a.realm, chrome=not a.plain_window)
    app.bind("<space>", lambda e: app.pause() if not isinstance(e.widget, tk.Entry) else None)
    app.mainloop()


if __name__ == "__main__":
    main()
