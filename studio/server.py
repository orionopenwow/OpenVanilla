"""Studio's own web app, on its own local-only port.

Studio never shares an origin with the public website or the browser game: the website on 18090
is what Caddy exposes and what runs game code and mods, so Studio listens on 127.0.0.1:18091
instead. A script there can't read Studio's pages, and Caddy never proxies to that port.

  setup_studio(app, base_dir)   used by asset_server.py: starts Studio beside the website and makes
                                /studio on the website redirect to it (local visitors only)
  make_app(base_dir)            the Studio app itself; studio_server.py runs it standalone
"""
import os

from aiohttp import web

from .app import KEY, is_local, mount_studio

STUDIO_PORT = int(os.environ.get("STUDIO_PORT", 18091))


def make_app(base_dir, mode=None, state_dir=None):
    app = web.Application(client_max_size=1024 * 1024)
    mount_studio(app, base_dir, mode=mode, state_dir=state_dir)
    app.router.add_static("/studio/", os.path.join(base_dir, "www", "studio"), show_index=False, follow_symlinks=False)

    async def favicon(request):
        return web.FileResponse(os.path.join(base_dir, "www", "favicon.ico"))

    async def root(request):
        raise web.HTTPFound("/studio/")

    app.router.add_get("/favicon.ico", favicon)
    app.router.add_get("/", root)
    return app


def setup_studio(app, base_dir, mode=None, state_dir=None, port=STUDIO_PORT):
    """Run Studio on 127.0.0.1:port alongside `app` (the public-facing website)."""
    studio_app = make_app(base_dir, mode, state_dir)
    runner = web.AppRunner(studio_app, access_log=None)

    async def start(_):
        try:
            await runner.setup()
            await web.TCPSite(runner, "127.0.0.1", port).start()
            print(f"[STUDIO] Server Studio on http://localhost:{port}/studio/ (this computer only)")
        except OSError as e:
            print(f"[STUDIO] could not listen on 127.0.0.1:{port}: {e}")

    async def stop(_):
        await runner.cleanup()

    async def to_studio(request):
        if not is_local(request):
            raise web.HTTPNotFound()
        raise web.HTTPFound(f"http://localhost:{port}/studio/")

    app.router.add_get("/studio", to_studio)
    app.router.add_get("/studio/{tail:.*}", to_studio)
    app.on_startup.append(start)
    app.on_cleanup.append(stop)
    return studio_app[KEY]
