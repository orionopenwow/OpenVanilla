"""The host agent's armory hook (launcher/p2p/armory.py + HostSession): the hourly export of a
community realm over the mariadb client's batch output, the stored zip, the Ed25519-signed upload, and
the opt-in switch.     python3 -m unittest tests.test_armory_host -v"""
import io
import json
import os
import shutil
import sys
import tempfile
import threading
import types
import unittest
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import p2p_fakes as F  # noqa: E402,F401  (puts launcher/ on sys.path)
import armory_fixture as AF  # noqa: E402
import ed25519  # noqa: E402
from p2p import P2PError, armory  # noqa: E402

HOST_ID = "abcdefghijklmnop"
TOKEN = "t" * 64
SEED = bytes(range(32))


def batch_out(rows):
    """Rows the way `mariadb --batch --skip-column-names` prints them."""
    def cell(v):
        if v is None:
            return "NULL"
        s = str(v)
        return s.replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n").replace("\0", "\\0")
    return "".join("\t".join(cell(v) for v in r) + "\n" for r in rows)


class SqliteCli:
    """HostSession.query over the SQLite fixture: MySQL literals in, batch text out."""

    def __init__(self):
        self.conn = AF.sqlite_db()
        self.calls = 0

    def __call__(self, sql, db=None):
        self.calls += 1
        sql = sql.strip()
        if sql.startswith("SET NAMES utf8mb4;"):
            sql = sql[len("SET NAMES utf8mb4;"):].strip()
        sql = sql.rstrip(";").replace("\\'", "''")
        return batch_out(self.conn.execute(sql).fetchall())


class Server:
    """The upload route's checks, as the realm service does them (signature, claim, JSON only)."""

    def __init__(self, status=200):
        self.status = status
        self.uploads = []

    def __call__(self, url, method="GET", payload=None, headers=None, timeout=10, data=None):
        assert method == "POST" and url == "https://central.test/api/armory/upload", url
        h = headers
        assert h["Authorization"] == "Bearer " + TOKEN and h["X-OpenVanilla-Host-Id"] == HOST_ID
        assert h["Content-Type"] == "application/zip"
        ok = ed25519.verify(bytes.fromhex(h["X-OpenVanilla-Host-Key"]), data, bytes.fromhex(h["X-OpenVanilla-Signature"]))
        assert ok, "bad signature"
        z = zipfile.ZipFile(io.BytesIO(data))
        files = {}
        for i in z.infolist():
            assert i.compress_type == zipfile.ZIP_STORED and i.flag_bits & 1 == 0
            files[i.filename] = json.loads(z.read(i))
        self.uploads.append(files)
        if self.status != 200:
            return self.status, b'{"error":"one upload per 10 minutes"}', {}
        return 200, json.dumps({"ok": True, "files": len(files)}).encode(), {}


def fake_session(tmp, query):
    s = types.SimpleNamespace()
    s.db = object()
    s.host_id = HOST_ID
    s.p2p = {"token": TOKEN, "host_id": HOST_ID}
    s.host_root = tmp
    s.paths = types.SimpleNamespace(pytools=None, gamedata=os.path.join(tmp, "nogamedata"))
    s.cfg = types.SimpleNamespace(name="Stormwind Nights", central="https://central.test")
    s.query = query
    s.host_key_secret = lambda: SEED
    s.stopped = threading.Event()
    s.last_error = None
    return s


class ArmoryHost(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="armory-host-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.cli = SqliteCli()
        self.addCleanup(self.cli.conn.close)

    def test_export_zip_sign_upload(self):
        s = fake_session(self.tmp, self.cli)
        srv = Server()
        res = armory.export_and_upload(s, post=srv)
        self.assertTrue(res["uploaded"])
        self.assertEqual(res["status"], 200)
        self.assertEqual(res["characters"], 6)
        files = srv.uploads[0]
        self.assertIn("index.json", files)
        self.assertTrue(files["index.json"]["community"])
        self.assertEqual(files["index.json"]["realm"], HOST_ID)
        self.assertIn("aldric.json", files)
        self.assertIn(f"berra~{AF.BERRA_KEY}.json", files, "friends-only keeps its secret-named file")
        self.assertTrue(any(n.startswith("guilds/") for n in files))
        for n in files:
            self.assertRegex(n, r"^(guilds/)?[a-z0-9~._-]+\.json$")
            self.assertFalse(n.startswith(".armory-state"))
        names = [c["name"] for c in files["index.json"]["characters"]]
        self.assertNotIn("Berra", names, "friends-only is never listed")
        # nothing changed: no second upload; force sends it anyway
        res = armory.export_and_upload(s, post=srv)
        self.assertFalse(res["uploaded"])
        self.assertEqual(len(srv.uploads), 1)
        res = armory.export_and_upload(s, post=srv, force=True)
        self.assertTrue(res["uploaded"])
        self.assertEqual(srv.uploads[1], srv.uploads[0])

    def test_refusals_and_preconditions(self):
        s = fake_session(self.tmp, self.cli)
        with self.assertRaises(P2PError) as e:
            armory.export_and_upload(s, post=Server(status=429))
        self.assertIn("429", str(e.exception))
        self.assertFalse(getattr(s, "armory_uploaded", False))
        s.p2p = {}
        with self.assertRaises(P2PError):
            armory.export_and_upload(s, post=Server())
        s.db = None
        with self.assertRaises(P2PError):
            armory.export_and_upload(s, post=Server())

    def test_loop_records_errors_and_stops(self):
        s = fake_session(self.tmp, self.cli)
        s.p2p = {}                       # not registered: every run fails, the loop keeps going
        t = threading.Thread(target=armory.loop, args=(s, 0.05, 0), daemon=True)
        t.start()
        threading.Event().wait(0.2)
        s.stopped.set()
        t.join(2)
        self.assertFalse(t.is_alive())
        self.assertIn("armory:", s.last_error)

    def test_finds_the_repo_exporter(self):
        mod = armory.find_exporter(types.SimpleNamespace(pytools=os.path.join(self.tmp, "none")))
        self.assertTrue(hasattr(mod, "Exporter") and hasattr(mod, "CliDb"))

    def test_zip_is_json_only(self):
        d = os.path.join(self.tmp, "realm")
        os.makedirs(os.path.join(d, "guilds"))
        for rel, body in (("index.json", "{}"), ("a.json", "{}"), ("x.html", "<b>"), (".armory-state-x.json", "{}"),
                          ("guilds/g.json", "{}"), ("guilds/n.txt", "x")):
            with open(os.path.join(d, rel), "w") as f:
                f.write(body)
        z = zipfile.ZipFile(io.BytesIO(armory.zip_realm(d)))
        self.assertEqual(sorted(z.namelist()), ["a.json", "guilds/g.json", "index.json"])


class HostSwitch(unittest.TestCase):
    """HostConfig.armory is off by default; on, the session starts the hourly thread."""

    def threads(self, **extra):
        from test_p2p_host import HostHarness
        h = HostHarness(self, **extra)
        h.s.start()
        return [t.name for t in h.s._threads]

    def test_off_by_default(self):
        from p2p import host
        self.assertFalse(host.HostConfig(name="Test Realm").armory)
        self.assertNotIn("_loop_armory", self.threads())

    def test_on_starts_the_loop(self):
        self.assertIn("_loop_armory", self.threads(armory=True))


if __name__ == "__main__":
    unittest.main(verbosity=1)
