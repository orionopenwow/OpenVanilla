"""Smoke test of Herald Autopilot against a REAL autopilot API (bot/herald_autopilot_api.py, with
a stand-in database and world console), and against a realm that can't be reached.

    xvfb-run -s "-screen 0 1280x800x24" python tests/ui_autopilot_realm_smoke.py OUT_DIR
"""
import asyncio
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "autopilot"))
sys.path.insert(0, os.path.join(ROOT, "bot"))
sys.path.insert(0, HERE)

import herald_autopilot as ha  # noqa: E402
import herald_autopilot_api as api  # noqa: E402
from aiohttp import web  # noqa: E402
from test_herald_autopilot import FakeRealm  # noqa: E402

OUT = sys.argv[1] if len(sys.argv) > 1 else tempfile.mkdtemp()
os.makedirs(OUT, exist_ok=True)
errors = []


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


# a real autopilot API on localhost
os.environ["AUTOPILOT_ALLOWED"] = "1"
realm = FakeRealm()
PORT = free_port()


def serve():
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    app = api.make_app(realm, api.LearnStore(":memory:"), who=lambda tok: "ORION" if tok == "good" else None)
    runner = web.AppRunner(app)
    loop.run_until_complete(runner.setup())
    loop.run_until_complete(web.TCPSite(runner, "127.0.0.1", PORT).start())
    loop.run_forever()


threading.Thread(target=serve, daemon=True).start()
time.sleep(0.6)
ha.launcher_token = lambda: "good"     # as if the launcher were signed in

app = ha.App(realm_url=f"http://127.0.0.1:{PORT}", folder=tempfile.mkdtemp(), chrome=False)
app.report_callback_exception = lambda *a: errors.append("".join(traceback.format_exception(*a)))
app.learner.set_consent(False)


def shot(name):
    app.update()
    path = os.path.join(OUT, name + ".png")
    subprocess.run(["import", "-window", "root", "-crop", f"{ha.W}x{ha.H}+{app.winfo_rootx()}+{app.winfo_rooty()}", path], check=True)
    print(path)


def check(c, m):
    if not c:
        errors.append("CHECK FAILED: " + m)


def step1():
    shot("r1_realm_ready")
    check(app.realm.get("autoplay_allowed"), "realm says allowed")
    check([c["name"] for c in app.chars] == ["Herald", "Alt"], "characters listed from the realm")
    check(app.can_start(), "can start with an online character")
    app.start()
    check(app.running, "running")
    check(realm.commands and realm.commands[-1].startswith(".rndbot cmd Herald nc +"), "world console got the start")
    realm.chars["ORION"][0].update(level=13, money=5000, xp=200)
    app.after(3500, step2)


def step2():
    shot("r2_realm_running")
    check(any("Level 13" in t for _, _, t in app.log_lines), "level-up event reached the log")
    check(app.session and app.session.levels == 1, "session counted the level")
    app.stop()
    check(any(c.startswith(".rndbot cmd Herald nc -grind") for c in realm.commands[-2:]), "world console got the stop")
    # switch to an offline character: START must refuse with a reason
    app.settings.set("character", "Alt")
    app.show("play")
    check(not app.can_start() and "Log Alt in" in app.why_not(), "offline character can't start")
    app.start()
    check(not app.running, "didn't start an offline character")
    shot("r3_offline_character")
    # a realm that can't be reached
    app.connect("http://127.0.0.1:9")
    app.after(2500, step3)


def step3():
    app.show("play")
    shot("r4_unreachable")
    check(not app.realm.get("reachable", True) and not app.can_start(), "unreachable realm can't start")
    app.connect("demo")
    app.after(800, step4)


def step4():
    check(app.can_start(), "back on the demo")
    app.connect("heraldlite")
    app.after(800, step5)


def step5():
    app.show("settings")
    shot("r5_heraldlite_settings")
    check(not app.can_start(), "Herald Lite without a build can't start")
    check("cargo build" in app.realm.get("message", "") or "bot account" in app.realm.get("message", ""),
          "Herald Lite says what's missing")
    app.quit_app()


app.after(1800, step1)
app.mainloop()
if errors:
    print("\n".join(errors))
    sys.exit(1)
print("realm smoke test: all checks passed")
