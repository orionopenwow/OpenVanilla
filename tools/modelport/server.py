"""The Model Porter app: a local page (http://127.0.0.1:8765) to drop .glb/.gltf models on, preview
them as the game will draw them, and add them to Open Vanilla.

    python tools/modelport/server.py [model.glb ...]
"""
import io
import json
import os
import re
import sys
import threading
import time
import traceback
import uuid
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse


def _readb(path):
    with open(path, "rb") as f:
        return f.read()


def _writeb(path, data):
    with open(path, "wb") as f:
        f.write(data)

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
from modelport import blp, content, m2read, names  # noqa: E402
from modelport.gltf import GltfError  # noqa: E402
from modelport.port import port  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(HERE))  # the Open Vanilla folder (tools/modelport/..)
WORK = os.path.join(ROOT, "_local", "modelport")
SESSIONS = {}
LOCK = threading.Lock()
PORT = int(os.environ.get("MODELPORT_PORT", "8765"))


def anim_choices():
    common = [0, 4, 5, 13, 143, 37, 38, 39, 40, 41, 42, 1, 6, 16, 25, 9, 14, 2, 74, 94, 130, 61, 97, 100, 91, 135, 11, 12]
    rest = sorted(i for i in names.ANIMS if i not in common)
    return [{"id": i, "name": names.anim_name(i)} for i in common + rest]


class App(BaseHTTPRequestHandler):
    server_version = "OpenVanillaModelPorter/1"

    def log_message(self, fmt, *args):
        pass

    def send(self, code, body, ctype="application/json", cache=False):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        elif isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "max-age=3600" if cache else "no-store")
        self.end_headers()
        self.wfile.write(body)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n > 600 * 1024 * 1024:
            raise ValueError("file too large (600 MB max)")
        return self.rfile.read(n)

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        try:
            if u.path == "/":
                return self.send(200, _readb(os.path.join(HERE, "ui.html")), "text/html; charset=utf-8")
            m = re.match(r"^/vendor/([\w.-]+\.(?:js|txt))$", u.path)
            if m and os.path.exists(os.path.join(HERE, "vendor", m.group(1))):
                return self.send(200, _readb(os.path.join(HERE, "vendor", m.group(1))),
                                 "text/javascript; charset=utf-8", cache=True)
            if u.path == "/api/setup":
                lib = content.Library(ROOT)
                start = []
                for k, v in list(SESSIONS.items()):
                    if v.pop("startup", False):
                        start.append(v["result"])
                return self.send(200, {"anims": anim_choices(), "root": ROOT,
                                       "library": list(lib.reg["models"].values()),
                                       "sounds": list(content.SOUND_FAMILIES), "startup": start})
            if u.path == "/api/preview":
                s = SESSIONS[q["sid"][0]]
                return self.send(200, s["preview"])
            m = re.match(r"^/api/tex/(\w+)/(\d+)\.png$", u.path)
            if m:
                s = SESSIONS[m.group(1)]
                return self.send(200, s["textures"][int(m.group(2))], "image/png", cache=True)
            return self.send(404, {"error": "not found"})
        except KeyError:
            return self.send(404, {"error": "That preview has expired; drop the model again."})
        except Exception as e:  # noqa: BLE001
            traceback.print_exc()
            return self.send(500, {"error": str(e)})

    def do_POST(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        if self.headers.get("Origin") not in (None, f"http://127.0.0.1:{PORT}", f"http://localhost:{PORT}"):
            return self.send(403, {"error": "cross-site request refused"})
        try:
            if u.path == "/api/upload":
                sid = q.get("sid", [""])[0] or uuid.uuid4().hex[:12]
                name = os.path.basename(q["name"][0]).replace("..", "")
                d = os.path.join(WORK, sid)
                os.makedirs(d, exist_ok=True)
                _writeb(os.path.join(d, name), self.body())
                return self.send(200, {"sid": sid})
            if u.path == "/api/port":
                req = json.loads(self.body() or b"{}")
                return self.send(200, run_port(req["sid"], req.get("main"), req.get("options") or {}))
            if u.path == "/api/add":
                req = json.loads(self.body() or b"{}")
                s = SESSIONS[req["sid"]]
                lib = content.Library(ROOT)
                mount = req.get("mount") if s["ported"].meta["kind"] == "mount" else None
                opts = dict(s["options"])
                for k in ("title", "sound"):  # these don't change the model, only its rows
                    if req.get(k):
                        opts[k] = req[k]
                entry = lib.add(s["ported"], s["path"], opts, mount=mount)
                before, after = content.update_patch(ROOT)
                return self.send(200, {"entry": entry, "patch": [before, after],
                                       "library": list(lib.reg["models"].values())})
            if u.path == "/api/remove":
                req = json.loads(self.body() or b"{}")
                lib = content.Library(ROOT)
                ok = lib.remove(req["name"])
                content.update_patch(ROOT)
                return self.send(200, {"ok": ok, "library": list(lib.reg["models"].values())})
            if u.path == "/api/open":  # a file dropped on Model_Porter.bat while the app was already open
                req = json.loads(self.body() or b"{}")
                sid = uuid.uuid4().hex[:12]
                res = run_port(sid, None, {}, path=req["path"])
                SESSIONS[sid]["startup"] = True
                return self.send(200, {"sid": sid, "ok": True})
            if u.path == "/api/reopen":
                req = json.loads(self.body() or b"{}")
                keep = os.path.join(ROOT, "content", "models", req["name"])
                saved = json.loads(_readb(os.path.join(keep, "port.json")).decode("utf-8"))
                src = next(os.path.join(keep, f) for f in os.listdir(keep) if f.startswith("source."))
                sid = uuid.uuid4().hex[:12]
                res = run_port(sid, None, saved.get("options") or {}, path=src)
                res["mount"] = saved.get("mount")
                return self.send(200, res)
            return self.send(404, {"error": "not found"})
        except KeyError:
            return self.send(404, {"error": "That preview has expired; drop the model again."})
        except (GltfError, ValueError) as e:
            return self.send(400, {"error": str(e)})
        except Exception as e:  # noqa: BLE001
            traceback.print_exc()
            return self.send(500, {"error": f"{type(e).__name__}: {e}"})


def from_modern(path, options):
    """A modern .m2: convert it to a .glb beside it (once per settings run) and suggest the options
    it carries (the clip ids and speeds). The user's own choices win."""
    if not path.lower().endswith(".m2"):
        return path, options, []
    from modelport import m2modern
    # beside an upload in the app's own folder; never written into the folder the model came from
    if os.path.abspath(path).startswith(os.path.abspath(WORK)):
        out = os.path.splitext(path)[0] + ".converted.glb"
    else:
        os.makedirs(os.path.join(WORK, "converted"), exist_ok=True)
        out = os.path.join(WORK, "converted", os.path.splitext(os.path.basename(path))[0] + ".converted.glb")
    try:
        sugg, notes = m2modern.to_glb(path, out)
    except m2modern.M2Error as e:
        raise GltfError(str(e))
    merged = dict(sugg)
    merged.update({k: v for k, v in options.items() if k != "anims"})
    anims = dict(sugg.get("anims", {}))
    anims.update(options.get("anims") or {})
    if anims:
        merged["anims"] = anims
    return out, merged, notes


def run_port(sid, main, options, path=None):
    if path is None and sid in SESSIONS and not os.path.isdir(os.path.join(WORK, sid)):
        path = SESSIONS[sid]["path"]  # a reopened or start-up model: port the same file again
    extra = []
    shown = os.path.basename(path) if path else None
    if path is not None:
        path, options, extra = from_modern(path, options)
    else:
        d = os.path.join(WORK, sid)
        files = os.listdir(d)
        own = [f for f in files if not f.lower().endswith(".converted.glb")]
        main = main or next((f for f in own if f.lower().endswith((".glb", ".gltf"))), None) \
            or next((f for f in own if f.lower().endswith(".m2")), None)
        if not main:
            raise GltfError("drop a .glb / .gltf, or a modern .m2 with its .skin (and .skel, .anim, .blp)")
        shown = main
        path, options, extra = from_modern(os.path.join(d, main), options)
    t = time.time()
    r = port(path, options)
    r.info[:0] = extra
    m2 = next(v for k, v in r.files.items() if k.lower().endswith(".m2"))
    prev = m2read.preview_json(m2)
    texs = []
    for t_ in prev["textures"]:
        key = (f"Creature\\OpenVanilla\\{r.meta['name']}\\{r.meta['texture_variation']}.blp" if t_["type"] == 11
               else t_["file"])
        data = r.files.get(key)
        png = io.BytesIO()
        if data:
            from PIL import Image
            Image.fromarray(blp.decode_dxt_top(data), "RGBA").save(png, "PNG")
        texs.append(png.getvalue())
    prev["anim_names"] = {str(a["id"]): names.anim_name(a["id"]) for a in prev["anims"]}
    with LOCK:
        SESSIONS[sid] = {"ported": r, "path": path, "options": options, "preview": prev, "textures": texs}
    clips = []
    from modelport.gltf import Gltf
    g = Gltf(path)
    for i, a in enumerate(g.animations):
        label = a.get("name") or f"Animation {i + 1}"
        guess, _ = names.parse(label)
        ov = (options.get("anims") or {}).get(label, {})
        clips.append({"label": label, "guess": guess, "id": ov.get("id", guess), "skip": bool(ov.get("skip")),
                      "speed": ov.get("speed")})
    res = {"sid": sid, "meta": r.meta, "warnings": r.warnings, "info": r.info, "clips": clips,
           "seconds": round(time.time() - t, 1), "options": options, "file": shown or os.path.basename(path),
           "sizes": {k.split("\\")[-1]: len(v) for k, v in r.files.items()}}
    SESSIONS[sid]["result"] = res
    return res


def main():
    os.makedirs(WORK, exist_ok=True)
    for a in sys.argv[1:]:
        if os.path.isfile(a):
            sid = uuid.uuid4().hex[:12]
            try:
                run_port(sid, None, {}, path=os.path.abspath(a))
                SESSIONS[sid]["startup"] = True
            except Exception as e:  # noqa: BLE001
                print(f"{a}: {e}")
    try:
        srv = ThreadingHTTPServer(("127.0.0.1", PORT), App)
    except OSError:
        # already running: hand it the dropped files, then open a tab that shows them
        import urllib.request
        for a in sys.argv[1:]:
            if os.path.isfile(a):
                try:
                    req = urllib.request.Request(f"http://127.0.0.1:{PORT}/api/open", method="POST",
                                                 data=json.dumps({"path": os.path.abspath(a)}).encode(),
                                                 headers={"Content-Type": "application/json"})
                    urllib.request.urlopen(req, timeout=300).read()
                except Exception as e:  # noqa: BLE001
                    print(f"{a}: {e}")
        webbrowser.open(f"http://127.0.0.1:{PORT}/")
        return
    url = f"http://127.0.0.1:{PORT}/"
    print(f"Open Vanilla Model Porter is running at {url}  (close this window to stop it)")
    if not os.environ.get("MODELPORT_NO_BROWSER"):
        threading.Timer(0.6, lambda: webbrowser.open(url)).start()
    srv.serve_forever()


if __name__ == "__main__":
    main()
