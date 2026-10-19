"""Run Open Vanilla Server Studio on its own (next to the wenilla-realm Docker stack, or as a demo).

    python3 studio_server.py                 # detects the host kind; docker if /opt/wenilla-realm exists
    python3 studio_server.py --demo          # a pretend realm: sign in as ADMIN / ADMIN
    python3 studio_server.py --mode docker --port 18091

It listens on 127.0.0.1 only. From your PC, tunnel to it:
    ssh -L 18091:127.0.0.1:18091 root@your-server     then open http://localhost:18091/studio/
On a Windows SPP host you don't need this file: the website (asset_server.py) starts Studio
on http://localhost:18091/studio/ by itself.
"""
import argparse
import os
import sys

from aiohttp import web

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BASE_DIR)

from studio.server import make_app as _make_app  # noqa: E402


def make_app(mode=None, state_dir=None):
    return _make_app(BASE_DIR, mode, state_dir)


def main():
    ap = argparse.ArgumentParser(description="Open Vanilla Server Studio")
    ap.add_argument("--mode", choices=["docker", "spp", "demo"], help="host kind (default: detect)")
    ap.add_argument("--demo", action="store_true", help="same as --mode demo")
    ap.add_argument("--port", type=int, default=int(os.environ.get("STUDIO_PORT", 18091)))
    ap.add_argument("--state", help="folder for Studio's history and settings (default: studio_state/)")
    a = ap.parse_args()
    app = make_app("demo" if a.demo else a.mode, a.state)
    print(f"Open Vanilla Server Studio on http://localhost:{a.port}/studio/  (this computer only)")
    web.run_app(app, host="127.0.0.1", port=a.port, print=None)


if __name__ == "__main__":
    main()
