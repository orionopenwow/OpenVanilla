"""UI Studio - tune every Open Vanilla window by hand, without prompting.

    python devkit/uistudio/server.py [--port 18095] [--game "C:\\Games\\World of Warcraft"] [--no-browser]
    (or UI_Studio.bat in the repo root)

Draws the real addon windows the way the Lua sim builds them (devkit/sim, same code the game runs),
lets you click, drag and resize any piece and change its colour, alpha, font and size, and writes
every change to Data/Interface/AddOns/WenillaCore/Layout.lua, which the addons read at load.
Also: theme tokens (W.UI colours and text size), tunables (every W:Tune in the addons), an image
pipeline (PNG -> TGA + BLP, plain or 9-slice backdrop, swapped in for any W:Art name), and an
import of the positions you set in game with /move or by dragging a window.

Needs Pillow, and Lua 5.1: lupa (pip install lupa) or a lua5.1 on PATH. Listens on 127.0.0.1 only.
"""
import argparse
import base64
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
SIM = os.path.join(REPO, "devkit", "sim")
ADDONS = os.path.join(REPO, "Data", "Interface", "AddOns")
LAYOUT = os.path.join(ADDONS, "WenillaCore", "Layout.lua")
UI_LUA = os.path.join(ADDONS, "WenillaCore", "UI.lua")
MEDIA = os.path.join(ADDONS, "WenillaCore", "Media")
BLP_DIR = os.path.join(REPO, "Data", "Interface", "ClassicPlus")
SHOT_DIRS = [os.path.join(HERE, "shots"), os.path.join(SIM, "render")]
STATE_DIR = os.path.join(REPO, "_local", "uistudio")
SETTINGS = os.path.join(STATE_DIR, "settings.json")

sys.path.insert(0, os.path.join(SIM, "render"))
sys.path.insert(0, os.path.join(REPO, "art"))

from PIL import Image  # noqa: E402

import render as R  # noqa: E402
from blp import write_blp  # noqa: E402

FONTS = ["Fonts\\FRIZQT__.TTF", "Fonts\\ARIALN.TTF", "Fonts\\skurri.ttf", "Fonts\\MORPHEUS.ttf"]
LAYOUT_HEADER = """-- Layout.lua - written by UI Studio (devkit/uistudio, UI_Studio.bat). Edit it there; by hand works too.
-- theme: the suite's colours and text size (W.UI tokens). frames: placement, size, scale, alpha,
-- colour and text size for any window or piece, by path ("Loot_Recap", "Loot_Recap.title").
-- tune: numbers the addons ask for with W:Tune(key, default). art: swap one art name for another.
-- A position a player drags a window to in game (or with /move) still wins over the one here.
"""


# ── Lua ─────────────────────────────────────────────────────────────────────────────────────────
class Lua:
    """Runs runner.lua: in process with lupa when it's installed, else a lua5.1 on PATH."""

    def __init__(self):
        self.kind, self.exe = None, None
        try:
            from lupa import lua51  # noqa: F401
            self.kind = "lupa"
        except Exception:
            for name in ("lua5.1", "lua51", "lua", "luajit"):
                exe = shutil.which(name)
                if exe and self._is51(exe):
                    self.kind, self.exe = "native", exe
                    break
        self.lock = threading.Lock()

    @staticmethod
    def _is51(exe):
        try:
            out = subprocess.run([exe, "-v"], capture_output=True, text=True, timeout=5)
            v = (out.stdout + out.stderr)
            return "5.1" in v or "LuaJIT" in v
        except Exception:
            return False

    def run(self, studio):
        studio = dict(studio, sim=SIM, repo=REPO, here=HERE)
        with self.lock:
            if self.kind == "lupa":
                return self._lupa(studio)
            if self.kind == "native":
                return self._native(studio)
        raise RuntimeError("Lua 5.1 isn't available: pip install lupa (UI_Studio.bat does this)")

    def _lupa(self, studio):
        from lupa import lua51
        L = lua51.LuaRuntime(unpack_returned_tuples=True)

        def lister(d):
            try:
                names = sorted(os.listdir(d))
            except OSError:
                names = []
            return L.table_from(names)
        L.globals().SIM_LIST_DIR = lister
        L.execute("STUDIO = " + lua_literal(studio))
        cwd = os.getcwd()
        try:
            os.chdir(REPO)
            out = L.eval('dofile([[' + os.path.join(HERE, "runner.lua") + ']])')
        finally:
            os.chdir(cwd)
        return json.loads(out)

    def _native(self, studio):
        with tempfile.TemporaryDirectory() as tmp:
            res = os.path.join(tmp, "out.json")
            boot = os.path.join(tmp, "boot.lua")
            with open(boot, "w", encoding="utf-8") as f:
                f.write("STUDIO = " + lua_literal(studio) + "\n")
                f.write("local out = dofile(" + lua_str(os.path.join(HERE, "runner.lua")) + ")\n")
                f.write("local fh = io.open(" + lua_str(res) + ", 'wb'); fh:write(out); fh:close()\n")
            p = subprocess.run([self.exe, boot], cwd=REPO, capture_output=True, text=True, timeout=120)
            if not os.path.isfile(res):
                raise RuntimeError((p.stderr or p.stdout or "lua failed")[-2000:])
            with open(res, encoding="utf-8") as f:
                return json.load(f)


def lua_str(s):
    s = str(s)
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\r", "\\r") + '"'


IDENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
LUA_WORDS = {"and", "break", "do", "else", "elseif", "end", "false", "for", "function", "if", "in", "local",
             "nil", "not", "or", "repeat", "return", "then", "true", "until", "while"}


def lua_literal(v, indent=0, pretty=False):
    """A Python value as a Lua table constructor (sorted keys, so Layout.lua diffs stay small)."""
    pad, pad1 = "    " * indent, "    " * (indent + 1)
    if v is None:
        return "nil"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        if v == int(v) and abs(v) < 1e15:
            return str(int(v))
        return ("%.4f" % v).rstrip("0").rstrip(".")
    if isinstance(v, str):
        return lua_str(v)
    if isinstance(v, (list, tuple)):
        return "{ " + ", ".join(lua_literal(x, indent + 1) for x in v) + " }" if v else "{}"
    if isinstance(v, dict):
        if not v:
            return "{}"
        parts = []
        for k in sorted(v, key=lambda k: str(k)):
            key = k if isinstance(k, str) and IDENT.match(k) and k not in LUA_WORDS else "[" + lua_str(k) + "]"
            parts.append(key + " = " + lua_literal(v[k], indent + 1, pretty and indent < 1))
        if pretty:
            return "{\n" + "".join(pad1 + p + ",\n" for p in parts) + pad + "}"
        return "{ " + ", ".join(parts) + " }"
    return "nil"


# ── state ───────────────────────────────────────────────────────────────────────────────────────
lua = Lua()
art_cache = {"art": None, "stamp": 0}


def load_settings():
    try:
        with open(SETTINGS, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def save_settings(s):
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(SETTINGS, "w", encoding="utf-8") as f:
        json.dump(s, f, indent=2)


def empty_layout():
    return {"theme": {}, "frames": {}, "tune": {}, "art": {}}


def clean(v):
    """JSON from Lua turns empty tables into {} and arrays into lists; keep the four sections dicts."""
    out = empty_layout()
    if isinstance(v, dict):
        for k in out:
            if isinstance(v.get(k), dict):
                out[k] = v[k]
    return out


def read_layout():
    if not os.path.isfile(LAYOUT):
        return empty_layout()
    r = lua.run({"mode": "read", "file": LAYOUT, "globals": ["WenillaCore_Layout"]})
    if r.get("error"):
        raise RuntimeError("Layout.lua: " + r["error"])
    return clean(r.get("WenillaCore_Layout"))


def write_layout(layout):
    layout = clean(layout)
    body = "WenillaCore_Layout = {\n"
    for sec in ("theme", "frames", "tune", "art"):
        body += "    " + sec + " = " + lua_literal(layout[sec], 1, pretty=True) + ",\n"
    body += "}\n"
    tmp = LAYOUT + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write(LAYOUT_HEADER + body)
    os.replace(tmp, LAYOUT)


def get_art():
    if art_cache["art"] is None:
        art_cache["art"] = R.Art(REPO)
    return art_cache["art"]


def list_shots():
    out = []
    for d in SHOT_DIRS:
        if not os.path.isdir(d):
            continue
        for f in sorted(os.listdir(d)):
            if not f.endswith(".lua") or f in ("dump.lua", "shoot.lua"):
                continue
            path = os.path.join(d, f)
            with open(path, encoding="utf-8", errors="replace") as fh:
                src = fh.read()
            names = re.findall(r'S\.shot\(\s*"([^"]+)"', src)
            if names:
                out.append({"file": os.path.relpath(path, REPO).replace("\\", "/"), "shots": names})
    return out


def theme_defaults():
    """The tokens UI.lua defines (before Layout.lua's theme), read from the source."""
    with open(UI_LUA, encoding="utf-8") as f:
        src = f.read()
    m = re.search(r"UI\.THEME_TOKENS\s*=\s*\{([^}]*)\}", src)
    names = re.findall(r'"([A-Z_]+)"', m.group(1)) if m else []
    toks = []
    for n in names:
        mm = re.search(r"^UI\." + n + r"\s*=\s*(.+?)\s*(--.*)?$", src, re.M)
        val = None
        if mm:
            raw = mm.group(1).strip()
            if raw.startswith("{"):
                nums = re.findall(r"-?\d+(?:\.\d+)?", raw)
                val = [float(x) for x in nums]
            elif raw.startswith('"'):
                val = raw.strip('"').replace("\\\\", "\\")
            else:
                try:
                    val = float(raw)
                except ValueError:
                    val = None
        kind = "color" if isinstance(val, list) else ("font" if n == "FONT" else "number")
        toks.append({"name": n, "default": val, "kind": kind})
    return toks


TUNE_RE = re.compile(r'W:Tune\(\s*"([^"]+)"\s*,\s*([^)]*)\)')
ART_RE = re.compile(r'W:Art\(\s*[^,]+,\s*"([^"]+)"')


def scan_source():
    tunables, arts = {}, {}
    for dirpath, _dirs, files in os.walk(ADDONS):
        for f in files:
            if not f.endswith(".lua") or f == "Layout.lua":
                continue
            p = os.path.join(dirpath, f)
            rel = os.path.relpath(p, ADDONS).replace("\\", "/")
            with open(p, encoding="utf-8", errors="replace") as fh:
                for i, line in enumerate(fh, 1):
                    for m in TUNE_RE.finditer(line):
                        d = m.group(2).strip()
                        try:
                            dv = float(d)
                        except ValueError:
                            dv = d.strip('"') if d.startswith('"') else None
                        tunables.setdefault(m.group(1), {"key": m.group(1), "default": dv, "where": f"{rel}:{i}"})
                    for m in ART_RE.finditer(line):
                        arts.setdefault(m.group(1), f"{rel}:{i}")
    media = sorted(os.path.splitext(f)[0] for f in os.listdir(MEDIA) if f.lower().endswith(".tga")) if os.path.isdir(MEDIA) else []
    return {"tunables": sorted(tunables.values(), key=lambda t: t["key"]),
            "artNames": [{"name": k, "where": v} for k, v in sorted(arts.items())], "media": media}


# ── rendering ───────────────────────────────────────────────────────────────────────────────────
def do_render(file, shot, scale):
    out = os.path.join(STATE_DIR, "shots")
    os.makedirs(out, exist_ok=True)
    t0 = time.time()
    res = lua.run({"mode": "shots", "shots": os.path.join(REPO, file), "out": out, "only": shot})
    if isinstance(res, dict):
        res = [res]
    r = next((x for x in res if x.get("name") == shot), res[0] if res else {"error": "no such shot"})
    if not r.get("objects"):
        return {"error": r.get("error") or "the shot drew nothing"}
    with open(os.path.join(out, shot + ".json"), encoding="utf-8") as f:
        data = json.load(f)
    t1 = time.time()
    sc = R.Scene(data, get_art(), scale)
    img = sc.render()
    root = data.get("root", 1)
    full = img
    img = sc.crop(full, root)
    # where the crop starts, to put the click boxes over the cropped picture
    ox, oy = crop_origin(sc, full, root)
    buf = io.BytesIO()
    img.convert("RGB").save(buf, "PNG")
    rects = []
    for o in data["objects"]:
        oid = o["id"]
        r_ = sc.rect(oid)
        if r_ is None or not sc.visible(oid):
            continue
        x0, y0, x1, y1 = sc.box(r_)
        if x1 - x0 < 1 or y1 - y0 < 1:
            continue
        rel_paths = []
        for p, rel, rp, x, y in o.get("points") or []:
            if rel in ("parent", "UIParent"):
                rel_paths.append([p, rel, rp, x, y])
            else:
                ro = sc.objs.get(rel)
                rel_paths.append([p, (ro or {}).get("path") or None, rp, x, y])
        rects.append({
            "id": oid, "path": o.get("path"), "name": o.get("name"), "kind": o.get("kind"),
            "parent": o.get("parent"), "x": x0 - ox, "y": y0 - oy, "w": x1 - x0, "h": y1 - y0,
            "ui": {"L": r_[0], "R": r_[1], "B": r_[2], "T": r_[3]}, "es": sc.escale(oid),
            "own": {"w": o.get("w"), "h": o.get("h"), "scale": o.get("scale"), "alpha": o.get("alpha"),
                    "text": o.get("text"), "textColor": o.get("textColor"), "fontPath": o.get("fontPath"),
                    "vertex": o.get("vertex"), "color": o.get("color"), "texture": o.get("texture"),
                    "backdropColor": o.get("backdropColor"), "backdropBorder": o.get("backdropBorder"),
                    "hasBackdrop": isinstance(o.get("backdrop"), dict)},
            "points": rel_paths, "layer": o.get("layer"), "strata": o.get("strata"), "level": o.get("level"),
            "region": o.get("region"),
        })
    return {"png": "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode(),
            "width": img.width, "height": img.height, "scale": scale, "rects": rects,
            "tunables": r.get("tunables") or {}, "error": r.get("error"), "missing": sorted(get_art().missing)[:20],
            "ms": {"lua": round((t1 - t0) * 1000), "draw": round((time.time() - t1) * 1000)}}


def crop_origin(sc, canvas, oid, margin=24):
    r = sc.rect(oid)
    if r is None:
        return 0, 0
    L, Rr, B, T = r
    for xid in sc.objs:
        if sc.visible(xid) and sc.is_under(xid, oid):
            rr = sc.rect(xid)
            if rr and rr[1] - rr[0] > 0 and rr[3] - rr[2] > 0:
                L, Rr, B, T = min(L, rr[0]), max(Rr, rr[1]), min(B, rr[2]), max(T, rr[3])
    x0, y0, _x1, _y1 = sc.box((L - margin, Rr + margin, B - margin, T + margin))
    return max(0, x0), max(0, y0)


# ── image pipeline ──────────────────────────────────────────────────────────────────────────────
def p2_up(n, cap=1024):
    v = 1
    while v < n and v < cap:
        v *= 2
    return v


def safe_name(s):
    s = re.sub(r"[^A-Za-z0-9_]+", "_", s or "").strip("_")
    return s[:60] or "Studio_Art"


def save_pair(name, img):
    """The two copies the clients load: Media/<name>.tga (1.12) and ClassicPlus/<name>.blp (web)."""
    os.makedirs(MEDIA, exist_ok=True)
    os.makedirs(BLP_DIR, exist_ok=True)
    img = img.convert("RGBA")
    img.save(os.path.join(MEDIA, name + ".tga"))
    write_blp(img, os.path.join(BLP_DIR, name + ".blp"))
    art_cache["art"] = None       # re-index so the preview finds it


def art_texture(img, name, fit, size):
    w, h = img.size
    tw, th = (size, size) if size else (p2_up(w), p2_up(h))
    if fit == "pad":
        canvas = Image.new("RGBA", (tw, th), (0, 0, 0, 0))
        s = min(tw / w, th / h)
        im = img.resize((max(1, round(w * s)), max(1, round(h * s))), Image.LANCZOS)
        canvas.paste(im, ((tw - im.width) // 2, (th - im.height) // 2))
        out = canvas
    else:
        out = img.resize((tw, th), Image.LANCZOS)
    save_pair(name, out)
    return {"files": [name], "size": [tw, th]}


def art_nineslice(img, name, edge, piece):
    """A 9-slice PNG (corners `edge` px) -> a 1.12 backdrop: <name>_Edge (8 pieces in a row:
    left, right, top, bottom, top-left, top-right, bottom-left, bottom-right; top and bottom are
    stored turned on their side, the way the client reads them) and <name>_Bg (the middle)."""
    img = img.convert("RGBA")
    w, h = img.size
    e = max(1, min(edge, w // 2 - 1, h // 2 - 1))
    n = piece or p2_up(e, 128)
    crop = img.crop
    parts = [
        crop((0, e, e, h - e)),            # left
        crop((w - e, e, w, h - e)),        # right
        crop((e, 0, w - e, e)),            # top
        crop((e, h - e, w - e, h)),        # bottom
        crop((0, 0, e, e)), crop((w - e, 0, w, e)), crop((0, h - e, e, h)), crop((w - e, h - e, w, h)),
    ]
    strip = Image.new("RGBA", (n * 8, n), (0, 0, 0, 0))
    for i, p in enumerate(parts):
        if i in (2, 3):
            p = p.rotate(90, expand=True)   # the renderer (and the client) turns these back
        strip.paste(p.resize((n, n), Image.LANCZOS), (i * n, 0))
    mid = crop((e, e, w - e, h - e))
    bs = p2_up(max(mid.width, mid.height), 256)
    save_pair(name + "_Edge", strip)
    save_pair(name + "_Bg", mid.resize((bs, bs), Image.LANCZOS))
    return {"files": [name + "_Edge", name + "_Bg"], "edgeSize": e,
            "backdrop": {"bg": name + "_Bg", "edge": name + "_Edge", "edgeSize": e, "insets": max(1, e // 3)}}


# ── game sync ───────────────────────────────────────────────────────────────────────────────────
def find_game_dirs():
    cands = []
    s = load_settings()
    if s.get("game"):
        cands.append(s["game"])
    roots = [os.environ.get(k) for k in ("ProgramFiles(x86)", "ProgramFiles", "LOCALAPPDATA", "USERPROFILE")]
    for r in filter(None, roots):
        for sub in ("World of Warcraft", "World of Warcraft 1.12", "OpenVanilla", "Games\\World of Warcraft",
                    "Desktop\\World of Warcraft", "Downloads\\World of Warcraft"):
            cands.append(os.path.join(r, sub))
    out = []
    for c in cands:
        if c and os.path.isdir(os.path.join(c, "WTF")) and c not in out:
            out.append(c)
    return out


def saved_positions(game):
    """Every window position saved in game: /move (Themes: ClassicPlus_UI.pos) and dragged
    Classic+ windows (WenillaCore_Config.positions), per account."""
    found = []
    acc_root = os.path.join(game, "WTF", "Account")
    if not os.path.isdir(acc_root):
        return {"error": "no WTF\\Account folder in " + game, "entries": []}
    for acc in sorted(os.listdir(acc_root)):
        sv = os.path.join(acc_root, acc, "SavedVariables")
        for fname, glob in (("Themes.lua", "ClassicPlus_UI"), ("WenillaCore.lua", "WenillaCore_Config")):
            p = os.path.join(sv, fname)
            if not os.path.isfile(p):
                continue
            r = lua.run({"mode": "read", "file": p, "globals": [glob]})
            data = r.get(glob) if isinstance(r, dict) else None
            if not isinstance(data, dict):
                continue
            if glob == "ClassicPlus_UI":
                for frame, v in (data.get("pos") or {}).items():
                    if isinstance(v, dict) and v.get("left") is not None and v.get("top") is not None:
                        found.append({"account": acc, "source": "/move", "frame": frame,
                                      "left": v["left"], "top": v["top"], "scale": v.get("scale")})
            else:
                for frame, v in (data.get("positions") or {}).items():
                    if isinstance(v, dict) and v.get("x") is not None:
                        found.append({"account": acc, "source": "dragged", "frame": frame,
                                      "left": v["x"], "top": v["y"], "scale": None})
    return {"entries": found}


def import_positions(layout, entries):
    for e in entries:
        ov = dict(layout["frames"].get(e["frame"]) or {})
        ov["point"] = ["TOPLEFT", "UIParent", "BOTTOMLEFT", round(float(e["left"]), 1), round(float(e["top"]), 1)]
        if e.get("scale") and abs(float(e["scale"]) - 1) > 1e-3:
            ov["scale"] = round(float(e["scale"]), 3)
        layout["frames"][e["frame"]] = ov
    return layout


def copy_to_game(game):
    dst_dir = os.path.join(game, "Interface", "AddOns", "WenillaCore")
    if not os.path.isdir(dst_dir):
        return {"error": "WenillaCore isn't installed in " + game + " (Interface\\AddOns\\WenillaCore)"}
    shutil.copy2(LAYOUT, os.path.join(dst_dir, "Layout.lua"))
    copied = ["Layout.lua"]
    lay = read_layout()
    names = set(v for v in lay["art"].values() if isinstance(v, str))
    for ov in lay["frames"].values():
        if isinstance(ov, dict):
            if isinstance(ov.get("art"), str):
                names.add(ov["art"])
            b = ov.get("backdrop")
            if isinstance(b, dict):
                names.update(x for x in (b.get("bg"), b.get("edge")) if isinstance(x, str))
    os.makedirs(os.path.join(dst_dir, "Media"), exist_ok=True)
    for n in sorted(names):
        src = os.path.join(MEDIA, n + ".tga")
        if os.path.isfile(src):
            shutil.copy2(src, os.path.join(dst_dir, "Media", n + ".tga"))
            copied.append("Media\\" + n + ".tga")
    return {"copied": copied, "to": dst_dir}


# ── HTTP ────────────────────────────────────────────────────────────────────────────────────────
class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}")

    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/", "/index.html"):
            with open(os.path.join(HERE, "index.html"), "rb") as f:
                return self.send(200, f.read(), "text/html; charset=utf-8")
        if path.startswith("/media/"):
            name = safe_name(path[7:].rsplit(".", 1)[0])
            src = os.path.join(MEDIA, name + ".tga")
            if not os.path.isfile(src):
                return self.send(404, {"error": "no such art"})
            buf = io.BytesIO()
            Image.open(src).convert("RGBA").save(buf, "PNG")
            return self.send(200, buf.getvalue(), "image/png")
        if path == "/api/state":
            try:
                return self.send(200, {
                    "lua": lua.kind, "shots": list_shots(), "layout": read_layout(), "theme": theme_defaults(),
                    "fonts": FONTS, "games": find_game_dirs(), "game": load_settings().get("game"), **scan_source()})
            except Exception as e:  # noqa: BLE001
                return self.send(500, {"error": str(e)})
        return self.send(404, {"error": "not found"})

    def do_POST(self):
        path = self.path.split("?")[0]
        try:
            b = self.body()
            if path == "/api/render":
                if isinstance(b.get("layout"), dict):
                    write_layout(b["layout"])
                return self.send(200, do_render(b["file"], b["shot"], float(b.get("scale") or 2)))
            if path == "/api/layout":
                write_layout(b["layout"])
                return self.send(200, {"ok": True})
            if path == "/api/art":
                raw = b["data"].split(",", 1)[-1]
                img = Image.open(io.BytesIO(base64.b64decode(raw))).convert("RGBA")
                name = safe_name(b.get("name"))
                if b.get("mode") == "nineslice":
                    r = art_nineslice(img, name, int(b.get("edge") or 16), int(b.get("piece") or 0))
                else:
                    r = art_texture(img, name, b.get("fit") or "stretch", int(b.get("size") or 0))
                r["note"] = "Wrote Media\\*.tga (desktop client) and ClassicPlus\\*.blp (browser: rebuild patch-Z with tools\\sync_patchz.py)."
                return self.send(200, r)
            if path == "/api/game":
                s = load_settings()
                s["game"] = b.get("game") or ""
                save_settings(s)
                return self.send(200, saved_positions(s["game"]) if s["game"] else {"entries": []})
            if path == "/api/import":
                lay = read_layout()
                write_layout(import_positions(lay, b.get("entries") or []))
                return self.send(200, {"layout": read_layout()})
            if path == "/api/copy-to-game":
                return self.send(200, copy_to_game(b.get("game") or load_settings().get("game") or ""))
            return self.send(404, {"error": "not found"})
        except Exception as e:  # noqa: BLE001
            return self.send(500, {"error": f"{type(e).__name__}: {e}"})


def main():
    ap = argparse.ArgumentParser(description="Open Vanilla UI Studio")
    ap.add_argument("--port", type=int, default=18095)
    ap.add_argument("--game", help="your 1.12 game folder (the one with WTF), for importing /move positions")
    ap.add_argument("--no-browser", action="store_true")
    a = ap.parse_args()
    if a.game:
        s = load_settings()
        s["game"] = a.game
        save_settings(s)
    if not lua.kind:
        print("Lua 5.1 isn't available. Install lupa:  python -m pip install lupa")
        sys.exit(1)
    srv = ThreadingHTTPServer(("127.0.0.1", a.port), Handler)
    url = f"http://127.0.0.1:{a.port}/"
    print(f"UI Studio: {url}   (Lua: {lua.kind}; writes {os.path.relpath(LAYOUT, REPO)})  Ctrl+C to stop")
    if not a.no_browser:
        threading.Timer(0.6, lambda: webbrowser.open(url)).start()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
