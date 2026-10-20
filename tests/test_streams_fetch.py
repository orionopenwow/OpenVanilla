"""The streams & creators fetcher (tools/streams_fetch.py) with canned Twitch / YouTube / TikTok /
realm answers: no keys, no network.

    python3 -m unittest tests.test_streams_fetch -v
"""
import datetime as dt
import json
import os
import sys
import tempfile
import unittest
import urllib.error

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import streams_fetch as sf  # noqa: E402

KEYS = {"TWITCH_CLIENT_ID": "cid", "TWITCH_CLIENT_SECRET": "secret-xyz", "YOUTUBE_API_KEY": "yt-key-123",
        "REALM_URL": "https://realm.test", "CREATOR_EXPORT_TOKEN": "staff-token-999"}
SECRETS = ("secret-xyz", "yt-key-123", "staff-token-999", "mock-app-token", "tiktok-user-token")


def rd(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


def wr(p, text):
    with open(p, "w", encoding="utf-8") as f:
        f.write(text)


def T(s):
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


class Tmp(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        d = self.dir.name
        self.out, self.creators, self.state = (os.path.join(d, n) for n in ("streams.json", "creators.yml", "state.json"))
        with open(self.creators, "w", encoding="utf-8") as f:
            f.write(sf.MOCK_CREATORS.replace("linked:\n  - name: Berra Plays", "linked:\n  - name: Old Name")
                    .split(sf.MARKER)[0] + sf.MARKER + "\nlinked: []\n")

    def tearDown(self):
        self.dir.cleanup()

    def run_pass(self, http=None, env=None, now=None):
        http = http or sf.MockHttp()
        return sf.run(dict(KEYS, **(env or {})), http, self.out, self.creators, self.state, now=now or T("2026-10-15T12:00:00Z")), http


class TestYaml(unittest.TestCase):
    def test_subset_parser_without_pyyaml(self):
        text = sf.MOCK_CREATORS
        real = sf.parse_yaml(text)
        # the fallback parser gives the same answer as PyYAML would
        import builtins
        orig = builtins.__import__

        def no_yaml(name, *a, **k):
            if name == "yaml":
                raise ImportError
            return orig(name, *a, **k)
        builtins.__import__ = no_yaml
        try:
            mine = sf.parse_yaml(text)
        finally:
            builtins.__import__ = orig
        self.assertEqual(mine, real)
        self.assertEqual(mine["curated"][0]["platforms"]["youtube"], "UCaaaaaaaaaaaaaaaaaaaaaa")
        self.assertEqual(mine["curated"][0]["topics"], ["guide", "dungeon"])
        self.assertIs(mine["linked"][0]["show_live"], True)

    def test_dump_round_trip(self):
        rows = [{"name": "A: b", "character": "Zed", "show_live": True, "platforms": {"twitch": "abc_d", "youtube": "@x.y"}}]
        back = sf.parse_yaml(sf.dump_linked(rows))["linked"]
        self.assertEqual(back[0]["name"], "A: b")
        self.assertEqual(back[0]["platforms"], {"twitch": "abc_d", "youtube": "@x.y"})
        self.assertEqual(sf.parse_yaml(sf.dump_linked([])), {"linked": []})


class TestPass(Tmp):
    def test_full_pass(self):
        doc, http = self.run_pass()
        live = {s["creator"]: s for s in doc["live"]}
        # curated twitch + linked twitch (from the realm) + the YouTube live; not the WoW stream without "Open Vanilla"
        self.assertEqual(set(live), {"Berra Plays", "Orlen Maps", "RandomRaider"})
        self.assertNotIn("Someone", json.dumps(doc))
        self.assertEqual([s["viewers"] for s in doc["live"]], sorted((s["viewers"] for s in doc["live"]), reverse=True))
        b = live["Berra Plays"]
        self.assertEqual(b["embed"], {"type": "twitch", "channel": "berraplays"})
        self.assertEqual(b["thumbnail"], "https://static-cdn.jtvnw.net/b-440x248.jpg")
        self.assertEqual(live["Orlen Maps"]["embed"], {"type": "youtube", "id": "v1"})
        self.assertEqual([s["id"] for s in doc["scheduled"]], ["yt:v2"])
        vids = {v["id"]: v for v in doc["videos"]}
        self.assertEqual(set(vids), {"yt:v3", "yt:v5"})          # "My cat" has no Open Vanilla mention
        self.assertEqual(vids["yt:v3"]["kind"], "video")
        self.assertEqual(vids["yt:v5"]["kind"], "short")
        self.assertIn("warlock", vids["yt:v3"]["classes"])
        self.assertIn("guide", vids["yt:v3"]["topics"])
        self.assertIn("dungeon", vids["yt:v3"]["topics"])
        names = {c["name"]: c for c in doc["creators"]}
        self.assertEqual(names["Berra Plays"]["badge"], "linked")
        # the Twitch channel shows its code in the About text; the TikTok one has no proof (not connected)
        self.assertEqual(names["Berra Plays"]["links"], {"twitch": "https://www.twitch.tv/berraplays"})
        self.assertTrue(names["RandomRaider"]["live"])
        self.assertEqual(doc["ingame"], [{"character": "Berra", "platform": "twitch"}])
        # the linked section was rewritten from the realm, the curated part kept as written
        text = rd(self.creators)
        self.assertIn("name: Orlen Maps", text)
        self.assertIn("character: Berra", text.split(sf.MARKER)[1])
        self.assertEqual(text.count(sf.MARKER), 1)
        # the export call carried the staff token; nothing secret reached the website file
        auth = [h.get("Authorization") for m, u, h, d in http.calls if "/api/creator/links" in u]
        self.assertEqual(auth, ["Bearer staff-token-999"])
        site = rd(self.out)
        for s in SECRETS:
            self.assertNotIn(s, site)
        for s in ("handle", "_text"):
            self.assertNotIn('"%s"' % s, site)
        # the Twitch app token is kept in the private state file only, mode 600
        self.assertEqual(json.loads(rd(self.state))["twitch_token"]["token"], "mock-app-token")
        self.assertEqual(os.stat(self.state).st_mode & 0o777, 0o600)

    def test_token_reused_and_search_throttled(self):
        _, h1 = self.run_pass(now=T("2026-10-15T12:00:00Z"))
        _, h2 = self.run_pass(now=T("2026-10-15T12:05:00Z"))
        self.assertEqual(sum("oauth2/token" in u for _, u, _, _ in h1.calls), 1)
        self.assertEqual(sum("oauth2/token" in u for _, u, _, _ in h2.calls), 0)
        self.assertEqual(sum("youtube/v3/search" in u for _, u, _, _ in h1.calls), 2)
        self.assertEqual(sum("youtube/v3/search" in u for _, u, _, _ in h2.calls), 0)     # hourly only
        self.assertEqual(sum("youtube/v3/channels" in u for _, u, _, _ in h2.calls), 0)   # uploads id cached
        _, h3 = self.run_pass(now=T("2026-10-15T13:01:00Z"))
        self.assertEqual(sum("youtube/v3/search" in u for _, u, _, _ in h3.calls), 2)

    def test_missing_keys_skip_sources(self):
        doc, http = self.run_pass(env={"TWITCH_CLIENT_ID": "", "YOUTUBE_API_KEY": "", "REALM_URL": ""})
        self.assertEqual(doc["live"], [])
        self.assertFalse(any("twitch" in u or "googleapis" in u or "/api/creator" in u for _, u, _, _ in http.calls))
        self.assertEqual(doc["leaderboard"]["rows"], [])

    def test_realm_down_keeps_last_links(self):
        self.run_pass()

        class Down(sf.MockHttp):
            def call(self, method, url, **kw):
                if "/api/creator/links" in url:
                    raise urllib.error.URLError("down")
                return super().call(method, url, **kw)
        doc, _ = self.run_pass(http=Down(), now=T("2026-10-15T12:05:00Z"))
        self.assertIn("Berra Plays", [c["name"] for c in doc["creators"]])
        self.assertEqual(doc["ingame"], [{"character": "Berra", "platform": "twitch"}])

    def test_bad_handles_and_characters_dropped(self):
        class Evil(sf.MockHttp):
            def call(self, method, url, **kw):
                if "/api/creator/links" in url:
                    return [{"user": 1, "display_name": "X", "platform": "twitch", "handle": "a b<script>", "character": "Zz", "code": "OW-XXXXX2"},
                            {"user": 2, "display_name": "Y", "platform": "myspace", "handle": "yy", "code": "OW-YYYYY2"},
                            {"user": 3, "display_name": "Z", "platform": "twitch", "handle": "zzz_ok", "character": "Bad Name1",
                             "show_live": True, "code": "OW-ZZZZZ2"}]
                if "helix/users" in url:
                    return {"data": [{"login": "zzz_ok", "description": "ow-zzzzz2"}]}
                return super().call(method, url, **kw)
        doc, _ = self.run_pass(http=Evil())
        names = [c["name"] for c in doc["creators"]]
        self.assertNotIn("X", names)
        self.assertNotIn("Y", names)
        self.assertIn("Z", names)
        self.assertNotIn("<script>", rd(self.creators))

    def test_tiktok_display_api(self):
        tok = os.path.join(self.dir.name, "tiktok.json")
        wr(tok, json.dumps({"orlenmaps": "tiktok-user-token", "bad handle!": "x"}))

        class Tik(sf.MockHttp):
            def call(self, method, url, headers=None, data=None, timeout=15):
                if "open.tiktokapis.com" in url:
                    self.calls.append((method, url, headers or {}, data))
                    assert headers["Authorization"] == "Bearer tiktok-user-token"
                    return {"data": {"videos": [
                        {"id": "71", "title": "Open Vanilla hunter pet tips", "cover_image_url": "https://p16.tiktokcdn.com/c.jpg",
                         "share_url": "https://www.tiktok.com/@orlenmaps/video/71", "create_time": int(T("2026-10-13T00:00:00Z")), "duration": 30},
                        {"id": "72", "title": "lunch", "create_time": 1}]}}
                return super().call(method, url, headers=headers, data=data, timeout=timeout)
        doc, http = self.run_pass(http=Tik(), env={"TIKTOK_TOKENS_FILE": tok})
        tt = [v for v in doc["videos"] if v["platform"] == "tiktok"]
        self.assertEqual(len(tt), 1)
        self.assertEqual(tt[0]["creator"], "Orlen Maps")
        self.assertEqual(tt[0]["embed"]["id"], "71")
        self.assertIn("hunter", tt[0]["classes"])
        self.assertEqual(sum("tiktokapis" in u for _, u, _, _ in http.calls), 1)   # the bad handle was skipped
        self.assertNotIn("tiktok-user-token", rd(self.out))

    def test_unproven_links_stay_off_the_site_and_the_game(self):
        class Claim(sf.MockHttp):
            """Someone links a channel that is not theirs: the channel never shows their code."""
            def call(self, method, url, **kw):
                if "/api/creator/links" in url:
                    return [{"user": 9, "display_name": "Impostor", "platform": "twitch", "handle": "randomraider",
                             "character": "Sneaky", "show_live": True, "code": "OW-FAKE22"}]
                return super().call(method, url, **kw)
        doc, http = self.run_pass(http=Claim())
        self.assertNotIn("Impostor", json.dumps(doc))
        self.assertEqual(doc["ingame"], [])                     # RandomRaider is live, but not as "Sneaky"
        self.assertEqual(sum("helix/users" in u for _, u, _, _ in http.calls), 1)
        # looked at again only after PROOF_RETRY
        _, h2 = self.run_pass(http=Claim(), now=T("2026-10-15T12:05:00Z"))
        self.assertEqual(sum("helix/users" in u for _, u, _, _ in h2.calls), 0)
        _, h3 = self.run_pass(http=Claim(), now=T("2026-10-15T12:20:00Z"))
        self.assertEqual(sum("helix/users" in u for _, u, _, _ in h3.calls), 1)

    def test_proof_is_remembered_per_code(self):
        self.run_pass()
        st = json.loads(rd(self.state))
        self.assertEqual(st["proofs"], {"twitch:berraplays": "OW-BERRA2"})

        class Quiet(sf.MockHttp):        # the code was taken off the About text afterwards: still proven
            def call(self, method, url, **kw):
                if "helix/users" in url:
                    self.calls.append((method, url, {}, None))
                    return {"data": []}
                return super().call(method, url, **kw)
        doc, http = self.run_pass(http=Quiet(), now=T("2026-10-15T12:05:00Z"))
        self.assertEqual(doc["ingame"], [{"character": "Berra", "platform": "twitch"}])
        self.assertEqual(sum("helix/users" in u for _, u, _, _ in http.calls), 0)

        class Moved(Quiet):              # the channel was relinked by another account (new code): proof again
            def call(self, method, url, **kw):
                if "/api/creator/links" in url:
                    return [{"user": 8, "display_name": "New Owner", "platform": "twitch", "handle": "berraplays",
                             "character": "Other", "show_live": True, "code": "OW-NEWONE"}]
                return super().call(method, url, **kw)
        doc, http = self.run_pass(http=Moved(), now=T("2026-10-15T12:10:00Z"))
        self.assertNotIn("New Owner", json.dumps(doc))
        self.assertEqual(doc["ingame"], [])
        self.assertEqual(sum("helix/users" in u for _, u, _, _ in http.calls), 1)

    def test_youtube_and_tiktok_proofs(self):
        tok = os.path.join(self.dir.name, "tiktok.json")
        wr(tok, json.dumps({"clipqueen": "tiktok-user-token"}))

        class Links(sf.MockHttp):
            def call(self, method, url, headers=None, data=None, timeout=15):
                if "/api/creator/links" in url:
                    return [{"user": 4, "display_name": "Yara", "platform": "youtube", "handle": "@YaraTube", "code": "OW-YARA22"},
                            {"user": 5, "display_name": "Clip Queen", "platform": "tiktok", "handle": "clipqueen", "code": "OW-CLIPQ2"},
                            {"user": 6, "display_name": "Kicker", "platform": "kick", "handle": "kicker", "code": "OW-KICK22"}]
                if "youtube/v3/channels" in url and "part=snippet" in url:
                    self.calls.append((method, url, headers or {}, data))
                    assert "forHandle=%40YaraTube" in url, url
                    return {"items": [{"id": "UCyyyyyyyyyyyyyyyyyyyyyy", "snippet": {"description": "Guides! ow-yara22"}}]}
                if "open.tiktokapis.com" in url:
                    self.calls.append((method, url, headers or {}, data))
                    return {"data": {"videos": []}}
                return super().call(method, url, headers=headers, data=data, timeout=timeout)
        doc, _ = self.run_pass(http=Links(), env={"TIKTOK_TOKENS_FILE": tok})
        names = {c["name"]: c for c in doc["creators"]}
        self.assertEqual(names["Yara"]["links"], {"youtube": "https://www.youtube.com/@YaraTube"})
        self.assertEqual(names["Clip Queen"]["links"], {"tiktok": "https://www.tiktok.com/@clipqueen"})
        self.assertNotIn("Kicker", names)                       # Kick: staff curate it by hand

    def test_refresh_curated_keeps_linked(self):
        self.run_pass()
        fresh = os.path.join(self.dir.name, "fresh.yml")
        wr(fresh, "curated:\n  - name: New Pick\n    platforms:\n      twitch: newpick\n")
        sf.refresh_curated(self.creators, fresh)
        data = sf.parse_yaml(rd(self.creators))
        self.assertEqual([c["name"] for c in data["curated"]], ["New Pick"])
        self.assertEqual([c["name"] for c in data["linked"]], ["Berra Plays"])
        wr(fresh, "<html>404</html>\n")
        sf.refresh_curated(self.creators, fresh)                # junk is ignored
        self.assertEqual([c["name"] for c in sf.parse_yaml(rd(self.creators))["curated"]], ["New Pick"])


class TestTikTokTokens(Tmp):
    ENV = {"TIKTOK_CLIENT_KEY": "ck", "TIKTOK_CLIENT_SECRET": "tiktok-secret", "TIKTOK_REDIRECT_URI": "https://openvanilla.app/tiktok.html"}

    class Fake:
        def __init__(self):
            self.calls = []

        def call(self, method, url, headers=None, data=None, timeout=15):
            self.calls.append((method, url, data))
            if data.get("grant_type") == "refresh_token":
                return {"access_token": "fresh-access", "expires_in": 86400, "refresh_token": "r2"}
            return {"access_token": "first-access", "expires_in": 86400, "refresh_token": "r1"}

    def test_connect_then_refresh(self):
        path = os.path.join(self.dir.name, "tt.json")
        http = self.Fake()
        url = sf.tiktok_connect(http, self.ENV, path, "@Clip.Queen")
        self.assertIn("client_key=ck", url)
        self.assertIn("scope=user.info.basic%2Cvideo.list", url)
        self.assertEqual(http.calls, [])
        sf.tiktok_connect(http, self.ENV, path, "@Clip.Queen", code="abc", now=1000)
        self.assertEqual(http.calls[0][2]["grant_type"], "authorization_code")
        self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
        stored = json.loads(rd(path))["clip.queen"]
        self.assertEqual((stored["access"], stored["refresh"], stored["expires"]), ("first-access", "r1", 1000 + 86400))
        # still valid: used as is, no refresh
        self.assertEqual(sf.tiktok_access_tokens(http, path, self.ENV, 2000), {"clip.queen": "first-access"})
        self.assertEqual(len(http.calls), 1)
        # a day later: refreshed and written back
        self.assertEqual(sf.tiktok_access_tokens(http, path, self.ENV, 1000 + 86400), {"clip.queen": "fresh-access"})
        self.assertEqual(json.loads(rd(path))["clip.queen"]["refresh"], "r2")
        # expired and no client secret configured: skipped, not used
        self.assertEqual(sf.tiktok_access_tokens(http, path, {}, 10 ** 10), {})

    def test_secrets_stay_out_of_the_site(self):
        path = os.path.join(self.dir.name, "tt.json")
        wr(path, json.dumps({"orlenmaps": {"access": "tiktok-user-token", "refresh": "refresh-secret", "expires": 0}}))

        class Tik(sf.MockHttp):
            def call(self, method, url, headers=None, data=None, timeout=15):
                if "oauth/token" in url and "tiktokapis" in url:
                    return {"access_token": "tiktok-user-token", "expires_in": 86400}
                if "open.tiktokapis.com/v2/video/list" in url:
                    return {"data": {"videos": []}}
                return super().call(method, url, headers=headers, data=data, timeout=timeout)
        self.run_pass(http=Tik(), env=dict(self.ENV, TIKTOK_TOKENS_FILE=path))
        site = rd(self.out)
        for secret in ("tiktok-user-token", "refresh-secret", "tiktok-secret"):
            self.assertNotIn(secret, site)


class TestLeaderboard(unittest.TestCase):
    def live(self, sid, who, viewers, started):
        return {"id": sid, "creator": who, "viewers": viewers, "started": started}

    def test_time_weighted_average_and_peak(self):
        st = {}
        t0 = T("2026-10-15T12:00:00Z")
        s = "2026-10-15T11:00:00Z"
        sf.accumulate(st, [self.live("tw:1", "A", 100, s)], [], t0)                 # 1 h at 100
        sf.accumulate(st, [self.live("tw:1", "A", 300, s)], [], t0 + 1800)          # 0.5 h at 300
        board = sf.accumulate(st, [self.live("tw:1", "A", 200, s)], [], t0 + 3600)  # 0.5 h at 200
        row = board["rows"][0]
        self.assertEqual(row["hours"], 2.0)
        self.assertEqual(row["peak"], 300)
        self.assertEqual(row["avg"], round((3600 * 100 + 1800 * 300 + 1800 * 200) / 7200))   # 175
        self.assertEqual(board["month"], "2026-10")

    def test_two_streams_same_creator_and_ranking(self):
        st = {}
        t = T("2026-10-15T12:00:00Z")
        sf.accumulate(st, [self.live("tw:1", "A", 10, "2026-10-15T11:00:00Z"),
                           self.live("yt:9", "A", 30, "2026-10-15T11:30:00Z"),
                           self.live("tw:2", "B", 500, "2026-10-15T11:45:00Z")], [], t)
        board = sf.leaderboard(st, "2026-10")
        self.assertEqual([r["creator"] for r in board["rows"]], ["A", "B"])        # hours first
        a = board["rows"][0]
        self.assertEqual(a["hours"], 1.5)
        self.assertEqual(a["avg"], round((3600 * 10 + 1800 * 30) / 5400))
        self.assertEqual([r["rank"] for r in board["rows"]], [1, 2])

    def test_month_boundary_and_videos(self):
        st = {}
        start = "2026-10-31T23:00:00Z"
        sf.accumulate(st, [self.live("tw:1", "A", 50, start)], [], T("2026-10-31T23:30:00Z"))
        board = sf.accumulate(st, [self.live("tw:1", "A", 50, start)],
                              [{"id": "yt:1", "creator": "A", "published": "2026-11-01T00:10:00Z"},
                               {"id": "yt:1", "creator": "A", "published": "2026-11-01T00:10:00Z"},
                               {"id": "yt:0", "creator": "A", "published": "2025-01-01T00:00:00Z"}],
                              T("2026-11-01T00:30:00Z"))
        self.assertEqual(st["months"]["2026-10"]["A"]["seconds"], 1800)
        self.assertEqual(board["month"], "2026-11")
        self.assertEqual(board["rows"][0]["hours"], 0.5)                          # only November's half hour
        self.assertEqual(board["rows"][0]["videos"], 1)                           # counted once, old one ignored
        self.assertNotIn("2025-01", st["months"])

    def test_gap_not_double_counted_and_old_months_dropped(self):
        st = {}
        s = "2026-10-15T10:00:00Z"
        sf.accumulate(st, [self.live("tw:1", "A", 5, s)], [], T("2026-10-15T11:00:00Z"))
        sf.accumulate(st, [self.live("tw:1", "A", 5, s)], [], T("2026-10-15T11:00:00Z"))   # same instant again
        self.assertEqual(st["months"]["2026-10"]["A"]["seconds"], 3600)
        st["months"].update({"2025-%02d" % m: {} for m in range(1, 13)})
        sf.accumulate(st, [], [], T("2026-10-15T12:00:00Z"))
        self.assertEqual(len(st["months"]), sf.MONTHS_KEPT)
        self.assertIn("2026-10", st["months"])

    def test_empty(self):
        self.assertEqual(sf.leaderboard({}, "2026-10"), {"month": "2026-10", "rows": []})


class TestMain(unittest.TestCase):
    def test_mock_never_touches_site_files(self):
        site = os.path.join(ROOT, "www", "community", "streams.json")
        yml = os.path.join(ROOT, "www", "community", "creators.yml")
        before = (rd(site), rd(yml))
        with tempfile.TemporaryDirectory() as d:
            env = dict(os.environ, STREAMS_STATE=os.path.join(d, "s.json"))
            old = os.environ.copy()
            os.environ.clear()
            os.environ.update(env)
            try:
                self.assertEqual(sf.main(["--mock", "--out", os.path.join(d, "o.json")]), 0)
            finally:
                os.environ.clear()
                os.environ.update(old)
            self.assertTrue(json.loads(rd(os.path.join(d, "o.json")))["live"])
        self.assertEqual(before, (rd(site), rd(yml)))


if __name__ == "__main__":
    unittest.main()
