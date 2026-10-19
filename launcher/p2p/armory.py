"""Community realms in the Open Vanilla armory (docs/ARMORY.md, "Community realms").

When the host turned it on (HostConfig.armory, off by default), the host agent exports its own realm
every hour with the same exporter the Open Vanilla realm runs (tools/armory_export.py --community, over the
host's mariadb client), zips the realm folder (JSON only, stored) and posts it, signed with the host
key, to the realm service:

    POST <central>/api/armory/upload
    Authorization: Bearer <directory claim token>
    X-OpenVanilla-Host-Id / X-OpenVanilla-Host-Key (hex) / X-OpenVanilla-Signature (hex Ed25519 over the body)

Characters keep their own privacy setting (public / friends with a secret link / hidden), exactly
as on the Open Vanilla realm. Nothing here ever runs unless the host opted in.
"""
import importlib.util
import io
import os
import zipfile

import ed25519

from . import P2PError, http

ARMORY_EVERY = 3600          # one export + upload per hour
ARMORY_FIRST_DELAY = 300     # the first one five minutes after the realm is up
MAX_UPLOAD = 20 * 1024 * 1024
_HERE = os.path.dirname(os.path.abspath(__file__))


def find_exporter(paths=None, extra=()):
    """tools/armory_export.py from the Solo pack's tools, else the repo checkout beside the launcher."""
    dirs = list(extra)
    if paths is not None and getattr(paths, "pytools", None):
        dirs.append(paths.pytools)
    dirs.append(os.path.join(os.path.dirname(os.path.dirname(_HERE)), "tools"))
    for d in dirs:
        f = os.path.join(d, "armory_export.py")
        if os.path.isfile(f):
            spec = importlib.util.spec_from_file_location("openvanilla_armory_export", f)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            return mod
    raise P2PError("The armory exporter (tools/armory_export.py) is not in the server pack.")


def zip_realm(folder):
    """The realm folder's JSON files as a stored zip (what the upload route accepts)."""
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_STORED) as z:
        for sub in ("", "guilds"):
            d = os.path.join(folder, sub)
            if not os.path.isdir(d):
                continue
            for fn in sorted(os.listdir(d)):
                p = os.path.join(d, fn)
                if fn.endswith(".json") and not fn.startswith(".") and os.path.isfile(p):
                    with open(p, "rb") as f:
                        z.writestr((sub + "/" if sub else "") + fn, f.read())
    return buf.getvalue()


def upload_request(central, host_id, token, secret, body):
    """(url, headers) for one signed upload."""
    headers = {
        "Authorization": "Bearer " + token,
        "Content-Type": "application/zip",
        "X-OpenVanilla-Host-Id": host_id,
        "X-OpenVanilla-Host-Key": ed25519.public_key(secret).hex(),
        "X-OpenVanilla-Signature": ed25519.sign(secret, body).hex(),
    }
    return central.rstrip("/") + "/api/armory/upload", headers


def export_and_upload(session, exporter=None, post=None, force=False):
    """One run for a HostSession. -> {"exported", "uploaded", "status", ...}; raises P2PError."""
    if not session.db:
        raise P2PError("The realm isn't running.")
    if not (session.host_id and session.p2p.get("token")):
        raise P2PError("The realm isn't registered with the Open Vanilla directory yet.")
    AE = exporter or find_exporter(session.paths)
    out = os.path.join(session.host_root, "armory")
    dbc = os.path.join(session.paths.gamedata, "dbc") if getattr(session.paths, "gamedata", None) else None
    ex = AE.Exporter(AE.CliDb(lambda sql: session.query(sql)), out, realm=session.host_id,
                     realm_name=session.cfg.name, community=True,
                     game=AE.GameData(dbc if dbc and os.path.isdir(dbc) else None),
                     skip_prefix=_bot_prefix())
    res = ex.run()
    changed = bool(res["written"] or res["deleted"])
    info = {"exported": res["exported"], "characters": res["characters"], "uploaded": False, "status": None}
    if not changed and not force and getattr(session, "armory_uploaded", False):
        session.armory_last = info
        return info
    body = zip_realm(os.path.join(out, session.host_id))
    if len(body) > MAX_UPLOAD:
        raise P2PError("The armory export is larger than 20 MB; it was not uploaded.")
    url, headers = upload_request(session.cfg.central, session.host_id, session.p2p["token"],
                                  session.host_key_secret(), body)
    status, reply, _ = (post or http)(url, "POST", headers=headers, data=body, timeout=60)
    info["status"] = status
    if status != 200:
        msg = reply.decode("utf-8", "replace")[:200] if isinstance(reply, bytes) else str(reply)[:200]
        session.armory_last = info
        raise P2PError(f"The armory upload was refused ({status}): {msg}")
    info["uploaded"] = True
    session.armory_uploaded = True
    session.armory_last = info
    return info


def _bot_prefix():
    from .host import BOT_PREFIX
    return BOT_PREFIX


def loop(session, every=ARMORY_EVERY, first=ARMORY_FIRST_DELAY):
    """The hourly thread (HostSession._loop_armory). Errors land in session.last_error."""
    if session.stopped.wait(first):
        return
    while True:
        try:
            export_and_upload(session)
        except Exception as e:  # noqa: BLE001  never let a bad export kill the host
            session.last_error = f"armory: {e}"
        if session.stopped.wait(every):
            return

