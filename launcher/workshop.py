"""The launcher's half of the Open Vanilla Workshop (no Tk here, so it is testable on its own).

    openvanilla://workshop/install/<id>[,<id>...]      the site's Install buttons (one addon, or a collection)

The catalogue is the site's static JSON (www/community/workshop/index.json + <id>.json, built by
tools/workshop_build.py). Only entries the builder marked installable (`install: true`: our own
Classic+ addons and addons whose licence allows rehosting) have a package; everything else is a link
to the author's page and is never downloaded here. A package is fetched from the site itself
(`community/workshop/files/<id>-<sha12>.zip`), its SHA-256 must match the catalogue, and it is
unpacked with the launcher's own install_zip (which refuses paths outside AddOns). After a good
install the launcher tells the realm (`POST /api/workshop/installs/<id>`, best effort, anonymous).
"""
import hashlib
import json
import os
import re
import tempfile
import urllib.parse
import urllib.request

SITE = "https://openvanilla.app/"
API = "https://play.openvanilla.app/api/workshop/"
UA = "OpenVanilla-Launcher (Workshop)"
ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{1,47}$")
LINK_RE = re.compile(r"^openvanilla://workshop/install/([a-z0-9,-]{2,2000})/?$")
FILE_RE = re.compile(r"^community/workshop/files/[a-z0-9][a-z0-9-]{1,47}-[0-9a-f]{12}\.zip$")
MAX_PACKAGE = 64 * 1024 * 1024
MAX_IDS = 60


def parse_link(text):
    """The addon ids in an install link, or None when it is not one."""
    m = LINK_RE.match((text or "").strip())
    if not m:
        return None
    ids = []
    for i in m.group(1).split(","):
        if i and ID_RE.match(i) and i not in ids:
            ids.append(i)
    return ids[:MAX_IDS] or None


def http_get(url, timeout=20, limit=MAX_PACKAGE):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        data = r.read(limit + 1)
    if len(data) > limit:
        raise ValueError("the download is larger than expected")
    return data


def http_post(url, timeout=8):
    req = urllib.request.Request(url, data=b"", method="POST", headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8") or "{}")


class Workshop:
    """Catalogue access + verified installs. `get(url) -> bytes` and `post(url) -> dict` are swappable."""

    def __init__(self, site=SITE, api=API, get=http_get, post=http_post):
        self.site = site.rstrip("/") + "/"
        self.api = api.rstrip("/") + "/"
        self.get = get
        self.post = post
        self.index = None

    def load_index(self):
        data = json.loads(self.get(self.site + "community/workshop/index.json", limit=8 * 1024 * 1024).decode("utf-8"))
        if not isinstance(data, dict) or not isinstance(data.get("addons"), list):
            raise ValueError("the Workshop catalogue is not in the expected shape")
        self.index = data
        return data

    def cards(self, query=""):
        """Index cards, ours first then by name; `query` words must all appear."""
        rows = list((self.index or {}).get("addons", []))
        q = (query or "").lower().split()
        if q:
            rows = [c for c in rows if all(w in " ".join(str(c.get(k, "")) for k in ("name", "author", "summary", "category")).lower()
                                             + " " + " ".join(c.get("tags") or []) for w in q)]
        return sorted(rows, key=lambda c: (not c.get("ours"), str(c.get("name", "")).lower()))

    def addon(self, addon_id):
        if not ID_RE.match(addon_id or ""):
            raise ValueError(f"not a Workshop id: {addon_id!r}")
        data = json.loads(self.get(self.site + f"community/workshop/{addon_id}.json", limit=2 * 1024 * 1024).decode("utf-8"))
        if data.get("id") != addon_id:
            raise ValueError("the catalogue answered for another addon")
        return data

    def package(self, entry, dest_dir):
        """Download the entry's package to dest_dir, check its SHA-256; returns the path."""
        if not entry.get("install"):
            raise PermissionError(f"{entry.get('name', entry.get('id'))} is not hosted by the Workshop: get it from its author")
        files = entry.get("files") or []
        if not files:
            raise ValueError(f"{entry.get('name')} has no package yet")
        f = files[0]
        rel = str(f.get("url", ""))
        if not FILE_RE.match(rel):
            raise ValueError(f"unexpected package location: {rel!r}")
        want = str(f.get("sha256", "")).lower()
        if not re.fullmatch(r"[0-9a-f]{64}", want):
            raise ValueError("the catalogue has no checksum for this package")
        data = self.get(self.site + rel)
        got = hashlib.sha256(data).hexdigest()
        if got != want:
            raise ValueError(f"checksum mismatch for {f.get('name')}: the download is not what the catalogue lists")
        os.makedirs(dest_dir, exist_ok=True)
        fd, path = tempfile.mkstemp(prefix=entry["id"] + "-", suffix=".zip", dir=dest_dir)
        with os.fdopen(fd, "wb") as out:
            out.write(data)
        return path

    def report(self, addon_id):
        try:
            return self.post(self.api + "installs/" + urllib.parse.quote(addon_id))
        except Exception:  # noqa: BLE001  (counting is best effort; offline is fine)
            return None

    def install(self, ids, addons_dir, install_zip, tmp_dir=None, progress=None):
        """Install each id. Returns [{"id", "name", "ok", "folders"|"error", "link"}]. Link-outs are
        reported with `link` (the author's page) and never downloaded."""
        out = []
        tmp_dir = tmp_dir or tempfile.gettempdir()
        for n, addon_id in enumerate(ids):
            if progress:
                progress(n, len(ids), addon_id)
            row = {"id": addon_id, "name": addon_id, "ok": False}
            try:
                entry = self.addon(addon_id)
                row["name"] = entry.get("name", addon_id)
                if not entry.get("install"):
                    row["link"] = entry.get("homepage") or entry.get("source_url")
                    row["error"] = "not hosted: get it from the author"
                    out.append(row)
                    continue
                path = self.package(entry, tmp_dir)
                try:
                    row["folders"] = install_zip(path, addons_dir)
                finally:
                    try:
                        os.remove(path)
                    except OSError:
                        pass
                row["ok"] = True
                self.report(addon_id)
            except Exception as e:  # noqa: BLE001  (one bad addon must not stop a collection)
                row["error"] = str(e) or e.__class__.__name__
            out.append(row)
        return out


def summary(results):
    """One line for the launcher's notice bar."""
    ok = [r for r in results if r["ok"]]
    linked = [r for r in results if not r["ok"] and r.get("link")]
    bad = [r for r in results if not r["ok"] and not r.get("link")]
    parts = []
    if ok:
        parts.append("Installed: " + ", ".join(r["name"] for r in ok))
    if linked:
        parts.append(f"{len(linked)} from the author's page")
    if bad:
        parts.append("Failed: " + ", ".join(f"{r['name']} ({r['error']})" for r in bad))
    return " · ".join(parts) or "Nothing to install"
