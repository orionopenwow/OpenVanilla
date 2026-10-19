#!/usr/bin/env python3
"""Touch lab: real touches on an emulated phone, through the play page's own touch layer, into a
stand-in that takes input the way the browser client does (see lab.html).

    python3 devkit/touchlab/run.py                  every phone profile, prints PASS/FAIL per case
    python3 devkit/touchlab/run.py --show           also saves a screenshot per case (_local/touchlab)

Needs Playwright with Chromium (pip install playwright; python -m playwright install chromium),
or CHROMIUM=/path/to/chrome. Exit code 1 when a case fails.
"""
import functools
import http.server
import json
import os
import sys
import threading

from playwright.sync_api import sync_playwright

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# phones as they report themselves: css viewport, pixel ratio; the buffer as the client draws it
PROFILES = [
    ("Android 2.625 (Pixel-class)", {"width": 914, "height": 411}, 2.625, ""),
    ("iPhone 3x", {"width": 852, "height": 393}, 3, ""),
    ("Tablet 2x", {"width": 1180, "height": 820}, 2, ""),
    ("Page-sized buffer 2x (desktop emulation)", {"width": 914, "height": 411}, 2, "&buffer=page"),
]


def serve():
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *a):
            pass
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Quiet, directory=ROOT))
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


def main():
    show = "--show" in sys.argv
    srv = serve()
    url = f"http://127.0.0.1:{srv.server_address[1]}/devkit/touchlab/lab.html?touch=1&touchdebug=1"
    exe = os.environ.get("CHROMIUM")
    failed = 0
    with sync_playwright() as p:
        browser = p.chromium.launch(**({"executable_path": exe} if exe else {}))
        for name, vp, dpr, extra in PROFILES:
            ctx = browser.new_context(viewport=vp, device_scale_factor=dpr, is_mobile=True, has_touch=True)
            page = ctx.new_page()
            errors = []
            page.on("pageerror", lambda e: errors.append(str(e)))
            page.goto(url + extra)
            page.wait_for_function("window.lab && window.lab.ready && window.lab.frames > 5", timeout=15000)
            page.wait_for_timeout(1200)                           # the button scan runs every 0.8 s
            # a phone's first tap in landscape goes full screen (touch.js), as on the real page
            page.touchscreen.tap(vp["width"] * 0.2, vp["height"] * 0.2)
            page.wait_for_timeout(900)
            cases = []
            b = page.evaluate("lab.buttonCss()")
            for label, dx, dy in (("tap on the button", 0, 0), ("tap 12 px below it (snap)", 0, 12)):
                before = page.evaluate("lab.clicks")
                page.touchscreen.tap(b["x"] + dx, b["y"] + dy)
                page.wait_for_timeout(500)
                after = page.evaluate("lab.clicks")
                cases.append((label, after - before == 1))
            info = page.evaluate("({ ignored: lab.ignored, debug: document.querySelector('#ow-touch .tdebug')?.textContent || '', "
                                 "moves: lab.events.filter(e => e.t === 'moved').length })")
            for label, ok in cases:
                failed += 0 if ok else 1
                print(f"{'PASS' if ok else 'FAIL'}  {name}: {label}")
            if errors:
                failed += 1
                print(f"FAIL  {name}: page errors: {errors[:2]}")
            if any(not ok for _, ok in cases) or "-v" in sys.argv:
                print("      presses ignored:", info["ignored"], " cursor moves the game saw:", info["moves"])
                print("      " + info["debug"].replace("\n", "\n      "))
            if show:
                os.makedirs(os.path.join(ROOT, "_local", "touchlab"), exist_ok=True)
                page.screenshot(path=os.path.join(ROOT, "_local", "touchlab", name.split(" ")[0] + ".png"))
            ctx.close()
        browser.close()
    srv.shutdown()
    print("all passed" if not failed else f"{failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
