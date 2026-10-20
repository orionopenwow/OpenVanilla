"""p2p.torrent (bencode, .torrent files, signed manifests, HTTP fallback, the libtorrent path with a
fake libtorrent) and tools/make_release_torrents.py.    python3 -m unittest tests.test_p2p_torrent -v"""
import contextlib
import hashlib
import io
import json
import os
import shutil
import sys
import tempfile
import types
import unittest
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import p2p_fakes as F  # noqa: E402
import ed25519  # noqa: E402
from p2p import P2PError, torrent as T  # noqa: E402

sys.path.insert(0, os.path.join(F.ROOT, "tools"))
import make_release_torrents as MRT  # noqa: E402

PUB_HEX = F.PUB.hex()


def signed(manifest):
    body = (json.dumps(manifest, indent=2) + "\n").encode()
    return body, (ed25519.sign(F.SEED, body).hex() + "\n").encode()


class FakeLT:
    """Just enough of libtorrent's API for Torrents: the 'swarm' hands over source bytes in 3 steps."""

    def __init__(self, sources, corrupt=False, stall=False):
        self.sources, self.corrupt, self.stall = sources, corrupt, stall
        self.sessions = []
        lt = self

        class Session:
            def __init__(self, settings):
                self.settings = dict(settings)
                self.added, self.removed = [], []
                lt.sessions.append(self)

            def apply_settings(self, s):
                self.settings.update(s)

            def add_torrent(self, atp):
                h = Handle(atp)
                self.added.append(h)
                return h

            def remove_torrent(self, h):
                self.removed.append(h)

        class Handle:
            def __init__(self, atp):
                self.atp, self.step, self.seeds = atp, 0, []
                self.name = atp.ti.info[b"info"][b"name"].decode()
                self.data = lt.sources[self.name]

            def add_url_seed(self, u):
                self.seeds.append(u)

            def status(self):
                if not lt.stall:
                    self.step = min(self.step + 1, 3)
                n = len(self.data) * self.step // 3
                if self.step == 3:
                    with open(os.path.join(self.atp.save_path, self.name), "wb") as f:
                        f.write(self.data if not lt.corrupt else b"x" + self.data[1:])
                return types.SimpleNamespace(total_wanted_done=n, total_wanted=len(self.data), num_peers=2,
                                             is_seeding=self.step == 3, is_finished=self.step == 3,
                                             progress=self.step / 3, upload_rate=0, download_rate=1024,
                                             all_time_upload=0, name=self.name)

        class TI:
            def __init__(self, d):
                self.info = d

        class ATP:
            ti = None
            save_path = None

        self.session = Session
        self.torrent_info = TI
        self.add_torrent_params = ATP
        self.bdecode = lambda b: T.bdecode(b)


class BencodeTests(unittest.TestCase):
    def test_roundtrip(self):
        x = {"b": [1, -2, b"x", "ü"], "a": {"n": 0}}
        enc = T.bencode(x)
        self.assertEqual(enc, b"d1:ad1:ni0ee1:bli1ei-2e1:x2:\xc3\xbcee")
        self.assertEqual(T.bdecode(enc), {b"a": {b"n": 0}, b"b": [1, -2, b"x", "ü".encode()]})
        for bad in (b"i1", b"5:ab", b"d1:a", b"i1ei2e"):
            with self.assertRaises((ValueError, IndexError)):
                T.bdecode(bad)

    def test_make_torrent(self):
        tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, tmp)
        p = os.path.join(tmp, "OpenVanilla-Solo-1.0.zip")
        data = os.urandom(300 * 1024)
        open(p, "wb").write(data)
        tb, ih = T.make_torrent(p, ["https://t/announce"], ["https://w/OpenVanilla-Solo-1.0.zip"], created=1)
        d = T.bdecode(tb)
        info = d[b"info"]
        self.assertEqual(info[b"length"], len(data))
        self.assertEqual(info[b"piece length"], 256 * 1024)
        self.assertEqual(info[b"pieces"][:20], hashlib.sha1(data[:256 * 1024]).digest())
        self.assertEqual(len(info[b"pieces"]), 40)
        self.assertEqual(d[b"url-list"], [b"https://w/OpenVanilla-Solo-1.0.zip"])
        self.assertEqual(ih, hashlib.sha1(T.bencode(info)).hexdigest())
        self.assertEqual(T.piece_length_for(4 << 30), 4 << 20)


class DownloadTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="p2p-torrent-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.data = os.urandom(200_000)
        self.name = "OpenVanilla-Solo-1.15.0.zip"
        src = os.path.join(self.tmp, self.name)
        open(src, "wb").write(self.data)
        self.web = F.HTTPServer(files={})
        self.addCleanup(self.web.close)
        tb, ih = T.make_torrent(src, [self.web.url("/announce")], [self.web.url("/dl/" + self.name)])
        self.torrent_bytes, self.ih = tb, ih
        self.manifest = {"format": 1, "version": "1.15.0", "url": self.web.url("/dl/" + self.name), "size": len(self.data),
                         "sha256": hashlib.sha256(self.data).hexdigest(),
                         "torrent": {"url": self.web.url("/dl/" + self.name + ".torrent"), "info_hash": ih, "name": self.name,
                                     "files": [{"path": self.name, "size": len(self.data),
                                                "sha256": hashlib.sha256(self.data).hexdigest()}],
                                     "web_seeds": [self.web.url("/dl/" + self.name)], "trackers": []}}
        self.publish(self.manifest)
        self.web.files["/dl/" + self.name] = self.data
        self.web.files["/dl/" + self.name + ".torrent"] = tb
        self.dest = os.path.join(self.tmp, "dest")

    def publish(self, m, sig=None):
        body, s = signed(m)
        self.web.files["/solo.json"] = body
        self.web.files["/solo.json.sig"] = sig if sig is not None else s

    def torrents(self, lt=None, **kw):
        return T.Torrents(os.path.join(self.tmp, "state"), kw.pop("settings", None), lt=lt, pubkey=PUB_HEX, **kw)

    def test_http_fallback_verifies_and_resumes(self):
        t = self.torrents(lt=None)
        self.assertEqual(t.backend, "http")
        self.assertFalse(t.seeding_enabled)
        prog = []
        os.makedirs(self.dest)
        open(os.path.join(self.dest, self.name + ".part"), "wb").write(self.data[:50_000])
        path = t.download(self.web.url("/solo.json"), self.dest, lambda d, n, s: prog.append((d, n)))
        self.assertEqual(open(path, "rb").read(), self.data)
        self.assertTrue(any("Range" in r[2] for r in self.web.requests if r[1].endswith(".zip")))
        self.assertEqual(prog[-1], (len(self.data), len(self.data)))
        # already there: nothing downloaded again
        n = len(self.web.requests)
        t.download(self.web.url("/solo.json"), self.dest)
        self.assertFalse(any(r[1].endswith(".zip") for r in self.web.requests[n:]))

    def test_unsigned_or_tampered_manifest_refused(self):
        t = self.torrents()
        self.publish(self.manifest, sig=b"00" * 64)
        with self.assertRaisesRegex(P2PError, "signed"):
            t.download(self.web.url("/solo.json"), self.dest)
        self.assertFalse(os.path.exists(os.path.join(self.dest, self.name)))

    def test_bad_bytes_refused(self):
        self.web.files["/dl/" + self.name] = b"evil" + self.data[4:]
        with self.assertRaisesRegex(P2PError, "failed"):
            self.torrents().download(self.web.url("/solo.json"), self.dest)
        self.assertFalse(os.path.exists(os.path.join(self.dest, self.name)))

    def test_unsafe_names_and_urls(self):
        m = dict(self.manifest, torrent=dict(self.manifest["torrent"], name="../evil.exe"))
        self.publish(m)
        with self.assertRaisesRegex(P2PError, "unsafe"):
            self.torrents().download(self.web.url("/solo.json"), self.dest)
        self.publish(dict(self.manifest, url="ftp://x/y.zip"))
        with self.assertRaisesRegex(P2PError, "https"):
            self.torrents().download(self.web.url("/solo.json"), self.dest)

    def test_libtorrent_path_without_seeding(self):
        lt = FakeLT({self.name: self.data})
        t = self.torrents(lt=lt)
        path = t.download(self.web.url("/solo.json"), self.dest)
        self.assertEqual(open(path, "rb").read(), self.data)
        s = lt.sessions[0]
        self.assertTrue(s.settings["enable_lsd"])
        self.assertFalse(s.settings["enable_dht"])
        self.assertEqual(s.settings["unchoke_slots_limit"], 0)       # not seeding: never uploads
        self.assertEqual(s.added[0].seeds, [self.web.url("/dl/" + self.name)])
        self.assertEqual(len(s.removed), 1)                          # dropped once done
        self.assertFalse(any(r[1].endswith(".zip") and r[0] == "GET" for r in self.web.requests))
        st = json.load(open(os.path.join(self.tmp, "state", "torrents.json")))
        self.assertEqual(st["seeds"][0]["info_hash"], self.ih)

    def test_libtorrent_seeding_opt_in_and_resume(self):
        lt = FakeLT({self.name: self.data})
        t = self.torrents(lt=lt)
        t.download(self.web.url("/solo.json"), self.dest)
        t.enable_seeding(upload_kbps=128)
        s = lt.sessions[0]
        self.assertEqual(s.settings["upload_rate_limit"], 128 * 1024)
        self.assertEqual(s.settings["unchoke_slots_limit"], 8)
        self.assertEqual(len(s.added), 2)                            # resumed for seeding
        self.assertEqual(t.status()["torrents"][0]["info_hash"], self.ih)
        t2 = self.torrents(lt=FakeLT({self.name: self.data}))
        self.assertTrue(t2.seeding_enabled)                          # remembered
        t2.disable_seeding()
        self.assertFalse(self.torrents(lt=None).seeding_enabled)

    def test_libtorrent_corrupt_falls_back_to_http(self):
        lt = FakeLT({self.name: self.data}, corrupt=True)
        path = self.torrents(lt=lt).download(self.web.url("/solo.json"), self.dest)
        self.assertEqual(open(path, "rb").read(), self.data)
        self.assertTrue(any(r[1].endswith(".zip") for r in self.web.requests))

    def test_wrong_info_hash_falls_back(self):
        m = dict(self.manifest, torrent=dict(self.manifest["torrent"], info_hash="0" * 40))
        self.publish(m)
        lt = FakeLT({self.name: self.data})
        self.torrents(lt=lt).download(self.web.url("/solo.json"), self.dest)
        self.assertEqual(lt.sessions, [])


class ToolTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="p2p-mrt-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.dist = os.path.join(self.tmp, "dist")
        os.makedirs(self.dist)
        with zipfile.ZipFile(os.path.join(self.dist, "OpenVanilla_1.15.0_Win64.zip"), "w") as z:
            z.writestr("OpenVanilla.exe", b"MZ")
            z.writestr("Data/patch-Z.MPQ", b"MPQ\x1a ours")
        open(os.path.join(self.dist, "OpenVanilla-Setup-1.15.0.exe"), "wb").write(b"MZ setup")
        self.solo = os.path.join(self.dist, "OpenVanilla-Solo-1.15.0.zip")
        with zipfile.ZipFile(self.solo, "w") as z:
            z.writestr("bin/mangosd.exe", b"MZ")
        base = "https://github.com/x/releases/download/v1.15.0"
        self.vj = os.path.join(self.dist, "version.json")
        json.dump({"version": "1.15.0", "url": f"{base}/OpenVanilla-Setup-1.15.0.exe", "size": 8, "sha256": "",
                   "setup": {"url": f"{base}/OpenVanilla-Setup-1.15.0.exe"}, "zip": {"url": f"{base}/OpenVanilla_1.15.0_Win64.zip"}},
                  open(self.vj, "w"))
        self.sj = os.path.join(self.dist, "solo.json")
        json.dump({"format": 1, "version": "1.15.0", "url": f"{base}/OpenVanilla-Solo-1.15.0.zip", "size": 1,
                   "sha256": hashlib.sha256(open(self.solo, "rb").read()).hexdigest(), "sql": []}, open(self.sj, "w"))
        self.patchz = os.path.join(self.tmp, "patch-Z.MPQ")
        open(self.patchz, "wb").write(b"MPQ\x1a" + os.urandom(1000))
        os.environ["OPENVANILLA_MANIFEST_KEY"] = F.SEED.hex()
        self.addCleanup(os.environ.pop, "OPENVANILLA_MANIFEST_KEY", None)

    def run_tool(self, *extra):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = MRT.main(["--dir", self.dist, "--base-url", "https://dl.example/t", "--manifest", self.vj,
                             "--manifest", self.sj, "--allow-file", os.path.join(self.dist, "torrents.allow")] + list(extra))
        return code, out.getvalue()

    def test_builds_signs_and_allows(self):
        code, out = self.run_tool("--patchz", self.patchz, "--patchz-version", "1.15.0", "--mirror", "https://m.example/o")
        self.assertEqual(code, 0, out)
        for mp in (self.vj, self.sj, os.path.join(self.dist, "patchz.json")):
            body = open(mp, "rb").read()
            sig = bytes.fromhex(open(mp + ".sig").read().strip())
            self.assertTrue(ed25519.verify(F.PUB, body, sig), mp)
        vj = json.load(open(self.vj))
        self.assertEqual(vj["zip"]["torrent"]["name"], "OpenVanilla_1.15.0_Win64.zip")
        self.assertEqual(vj["torrent"]["info_hash"], vj["setup"]["torrent"]["info_hash"])
        self.assertEqual(vj["sha256"], hashlib.sha256(b"MZ setup").hexdigest())
        sj = json.load(open(self.sj))
        t = sj["torrent"]
        self.assertEqual(t["web_seeds"], ["https://github.com/x/releases/download/v1.15.0/OpenVanilla-Solo-1.15.0.zip",
                                          "https://m.example/o/OpenVanilla-Solo-1.15.0.zip"])
        self.assertEqual(t["url"], "https://dl.example/t/OpenVanilla-Solo-1.15.0.zip.torrent")
        tb = open(os.path.join(self.dist, "OpenVanilla-Solo-1.15.0.zip.torrent"), "rb").read()
        self.assertEqual(T.info_hash(tb), t["info_hash"])
        self.assertEqual(T.bdecode(tb)[b"announce"], b"https://play.openvanilla.app/announce")
        allow = open(os.path.join(self.dist, "torrents.allow")).read().split()
        self.assertEqual(len(allow), 4)                      # setup, zip, solo, patch-Z
        self.assertEqual(self.run_tool()[0], 0)
        self.assertEqual(len(open(os.path.join(self.dist, "torrents.allow")).read().split()), 4)   # no duplicates

    def test_refuses_game_data(self):
        with zipfile.ZipFile(self.solo, "w") as z:
            z.writestr("data/terrain.MPQ", b"MPQ\x1a")
        json.dump(dict(json.load(open(self.sj)), sha256=""), open(self.sj, "w"))
        code, out = self.run_tool()
        self.assertEqual(code, 1)
        self.assertIn("terrain.MPQ", out)
        bad = os.path.join(self.tmp, "common.MPQ")
        open(bad, "wb").write(b"MPQ\x1a")
        code, out = self.run_tool("--patchz", bad)
        self.assertEqual(code, 1)
        for name, head in (("x.dbc", b""), ("y.bin", b"WDBC"), ("z.blp", b"")):
            self.assertIsNotNone(MRT.game_data_reason(name, head))
        self.assertIsNone(MRT.game_data_reason("Data/patch-Z.MPQ", b"MPQ\x1a"))

    def test_sha_mismatch_refused(self):
        json.dump(dict(json.load(open(self.sj)), sha256="0" * 64), open(self.sj, "w"))
        code, out = self.run_tool()
        self.assertEqual(code, 1)
        self.assertIn("doesn't match", out)


if __name__ == "__main__":
    unittest.main()
