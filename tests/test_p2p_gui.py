"""The launcher's Realms / Host / Downloads pages (launcher/openvanilla_launcher.py), driven headless with a
fake p2p package (tests/p2p_fakes.py). Skips without Tk or a display (run it under xvfb-run).

    xvfb-run -a python3.12 -m unittest tests.test_p2p_gui -v
"""
import os
import subprocess
import sys
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
LAUNCHER = os.path.join(ROOT, "launcher")
sys.path.insert(0, LAUNCHER)
sys.path.insert(0, HERE)

try:
    import tkinter as tk
    _root = tk.Tk()
    _root.destroy()
    import PIL.ImageTk  # noqa: F401  (the launcher draws everything with Pillow)
    HAVE_TK = True
except Exception:  # no tkinter, no Pillow, or no display
    HAVE_TK = False

import p2p_gui_fakes as p2p_fakes


class InviteLinkTests(unittest.TestCase):
    """parse_invite needs no display."""

    @unittest.skipUnless(HAVE_TK, "the launcher module needs tkinter and Pillow")
    def test_links(self):
        import openvanilla_launcher as L
        inv = L.parse_invite("openvanilla://join/abcdefghijklmnop?i=ABCDEFGHJK&n=My%20Realm")
        self.assertEqual((inv["host_id"], inv["code"], inv["name"]), ("abcdefghijklmnop", "ABCDEFGHJK", "My Realm"))
        inv = L.parse_invite("https://play.openvanilla.app/join/ABCDEFGHIJKLMNOP?i=abcdefghjk")
        self.assertEqual((inv["host_id"], inv["code"]), ("abcdefghijklmnop", "ABCDEFGHJK"))
        for bad in ("openvanilla://join/short", "https://evil.example/join/abcdefghijklmnop", "openvanilla://join/abcdefghijklmnop?i=0OO",
                    "", "hello"):
            self.assertIsNone(L.parse_invite(bad), bad)

    @unittest.skipUnless(HAVE_TK, "the launcher module needs tkinter and Pillow")
    def test_filter_and_order(self):
        import openvanilla_launcher as L
        rs = [p2p_fakes.Realm(**{**r.__dict__}) for r in p2p_fakes.REALMS]
        names = [r.name for r in L.filter_realms(rs)]
        self.assertEqual(names, ["Vanilla Reloaded", "Stormwind Nights", "Bob's Basement"])  # official, verified, rest
        self.assertEqual([r.name for r in L.filter_realms(rs, rtype="pvp")], ["Bob's Basement"])
        self.assertEqual([r.name for r in L.filter_realms(rs, template="vanilla")], ["Bob's Basement"])


@unittest.skipUnless(HAVE_TK, "needs tkinter, Pillow and a display (xvfb-run)")
class P2PGuiTests(unittest.TestCase):
    def setUp(self):
        p2p_fakes.install()
        self.addCleanup(p2p_fakes.uninstall)
        import openvanilla_launcher as L
        self.L = L
        L._P2P_MODS.clear()
        L._P2P_ERRS.clear()
        self.errors, self.asks = [], []
        saved = (L.messagebox.showerror, L.messagebox.askyesno, L.SETTINGS_PATH, L.Launcher.refresh_realms,
                 L.Launcher.check_for_update, L.Launcher.load_directory, L.subprocess.Popen, list(sys.argv))
        self.addCleanup(self._restore, saved)
        L.messagebox.showerror = lambda *a, **k: self.errors.append(a)
        L.messagebox.askyesno = lambda *a, **k: self.asks.append(a) or True
        L.SETTINGS_PATH = os.path.join(self._tmpdir(), "settings.json")   # never the real settings
        L.Launcher.refresh_realms = lambda s: None                         # no network in tests
        L.Launcher.check_for_update = lambda s: None
        L.Launcher.load_directory = lambda s: None
        self.popen = []
        L.subprocess.Popen = lambda *a, **k: self.popen.append((a, k)) or __import__("types").SimpleNamespace(wait=lambda: 0)
        sys.argv = ["openvanilla_launcher.py"]
        self.app = None

    def _tmpdir(self):
        import tempfile
        d = tempfile.mkdtemp(prefix="owp2p-")
        self.addCleanup(lambda: __import__("shutil").rmtree(d, ignore_errors=True))
        return d

    def _restore(self, saved):
        L = self.L
        (L.messagebox.showerror, L.messagebox.askyesno, L.SETTINGS_PATH, L.Launcher.refresh_realms,
         L.Launcher.check_for_update, L.Launcher.load_directory, L.subprocess.Popen, sys.argv[:]) = saved
        L._P2P_MODS.clear()
        if self.app is not None:
            try:
                self.app.destroy()
            except Exception:
                pass

    def start(self, relay=True, advanced=True):
        """relay: as if live.json had switched the Open Vanilla relay on (flags.relay). advanced: Settings >
        Advanced on, which shows HOST > Downloads."""
        self.app = self.L.Launcher()
        self.app.live.doc = {"schema": 1, "flags": {"relay": relay}} if relay else {}
        self.app.settings["advanced"] = advanced
        return self.app

    def pump(self, seconds=0.5, until=None):
        end = time.monotonic() + seconds
        app = self.app

        def tick():
            if (until and until()) or time.monotonic() >= end:
                app.quit()
            else:
                app.after(20, tick)

        app.after(20, tick)
        app.mainloop()
        return until() if until else True

    def calls(self, name):
        return [c for c in p2p_fakes.CALLS if c[0] == name]

    # --------------------------------------------------------------- Realms

    def test_realm_browser_lists_groups_and_pings(self):
        app = self.start()
        app.tab_state["servers"] = "realms"
        app.show_page("servers", animate=False)
        self.assertTrue(self.pump(3, until=lambda: len(app.p2p["pings"]) == 3 and app._p2p_paint_after is None
                                  and set(app.p2p_rows) == {"oooooooooooooooo", "aaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbb"}))
        self.assertEqual(self.calls("fetch"), [("fetch", self.L.P2P_DIRECTORY_URL)])
        self.assertEqual(app.p2p["pings"]["aaaaaaaaaaaaaaaa"], 48)
        self.assertEqual(list(app.p2p_rows), ["oooooooooooooooo", "aaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbb"])

        def texts(w):
            out = [w.cget("text")] if isinstance(w, tk.Label) else []
            for c in w.winfo_children():
                out += texts(c)
            return out

        official, verified, unverified = (texts(app.p2p_rows[k]) for k in
                                          ("oooooooooooooooo", "aaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbb"))
        self.assertIn(" OFFICIAL", official)
        self.assertIn(" VERIFIED", verified)
        self.assertTrue(any("ping 48 ms" in t and "via relay" in t for t in verified))
        self.assertTrue(any("no answer" in t for t in unverified))
        self.assertEqual(app.p2p_rows["bbbbbbbbbbbbbbbb"].cget("bg"), "#121016")   # greyed

        app._p2p_filter("type", "pvp")
        self.assertEqual(list(app.p2p_rows), ["bbbbbbbbbbbbbbbb"])
        app._p2p_filter("type", "all")
        app.toggle_favourite("aaaaaaaaaaaaaaaa")
        app._p2p_filter("show", "fav")
        self.assertEqual(list(app.p2p_rows), ["aaaaaaaaaaaaaaaa"])
        self.assertEqual(app.settings["p2p_favourites"], ["aaaaaaaaaaaaaaaa"])

    def test_join_records_recent_and_launches_the_client(self):
        app = self.start()
        exe = os.path.join(self._tmpdir(), "WoW.exe")
        open(exe, "w").close()
        app.client_exe = lambda c=None: exe
        app.clients[app.client_index]["type"] = "exe"
        realm = p2p_fakes.REALMS[0]
        app.join_realm(realm, realm.name)
        self.assertTrue(self.pump(3, until=lambda: app.settings.get("p2p_recent")))
        self.assertEqual(self.calls("join"), [("join", "Stormwind Nights", None)])
        self.assertEqual(app.settings["p2p_recent"][0]["key"], "aaaaaaaaaaaaaaaa")
        self.assertEqual(len(self.popen), 1)
        with open(os.path.join(os.path.dirname(exe), "realmlist.wtf")) as f:
            rl = f.read()
        self.assertIn("set realmlist 127.0.0.1:40123", rl)
        self.assertEqual(app.clipboard_get(), "secret")   # the stock client can't be logged in for you
        app.tab_state["servers"] = "realms"
        app._p2p_filter("show", "recent")
        self.pump(1, until=lambda: "aaaaaaaaaaaaaaaa" in getattr(app, "p2p_rows", {}))
        self.assertEqual(list(app.p2p_rows), ["aaaaaaaaaaaaaaaa"])

    def test_invite_link_on_the_command_line(self):
        sys.argv = ["openvanilla_launcher.py", "openvanilla://join/cccccccccccccccc?i=ABCDEFGHJK&n=Friends"]
        app = self.start()
        app.launch_at = lambda *a, **k: object()
        self.assertTrue(self.pump(4, until=lambda: self.calls("join")))
        self.assertEqual(app.page, "servers")
        self.assertIn("Friends", self.asks[0][1])
        self.assertEqual(self.calls("join")[0][1], "openvanilla://join/cccccccccccccccc?i=ABCDEFGHJK&n=Friends")
        self.assertTrue(self.pump(2, until=lambda: app.settings.get("p2p_recent")))
        self.assertEqual(app.settings["p2p_recent"][0]["key"], "cccccccccccccccc")

    def test_bad_invite_is_refused(self):
        app = self.start()
        self.assertFalse(app.open_invite("https://example.com/join/x"))
        self.assertEqual(self.calls("join"), [])

    def test_report_needs_sign_in_then_sends(self):
        app = self.start()
        app.session.pop("token", None)
        app.settings.pop("launcher_token", None)
        self.assertIsNone(app.report_realm(p2p_fakes.REALMS[2]))   # not signed in: only a notice
        app.session["token"] = "tok"
        sent = []
        self.L.account._request, saved = (lambda url, method="GET", payload=None, token=None, timeout=15:
                                          sent.append((url, method, payload, token)) or (202, {})), self.L.account._request
        self.addCleanup(setattr, self.L.account, "_request", saved)
        dlg = app.report_realm(p2p_fakes.REALMS[2])
        dlg.button_cmds["Send report"]()
        self.assertTrue(self.pump(2, until=lambda: sent))
        url, method, payload, token = sent[0]
        self.assertTrue(url.endswith("/api/directory/report"))
        self.assertEqual((method, token, payload["host_id"]), ("POST", "tok", "bbbbbbbbbbbbbbbb"))

    # --------------------------------------------------------------- Host

    def test_host_start_live_panel_actions_stop(self):
        app = self.start()
        app.tab_state["host"] = "realm"
        app.show_page("host", animate=False)
        v = app._hostv
        v["name"].delete(0, "end")
        v["name"].insert(0, "Test Realm")
        v["visibility"].set("public")
        v["upnp"].set(True)
        app.host_start()
        sess = sys.modules["p2p.host"].HostSession.last
        self.assertEqual((sess.cfg.name, sess.cfg.visibility, sess.cfg.template), ("Test Realm", "public", "classicplus"))
        self.assertTrue(self.pump(4, until=lambda: app.p2p_host_status.get("players")))
        self.assertEqual(app.p2p_host_state, "Running")
        self.assertEqual(app.settings["p2p_host"]["upnp"], True)
        self.assertEqual(app._hostv["name"].cget("state"), "disabled")   # fixed while it runs

        app.host_player("Arthas", "kick")
        self.assertTrue(self.pump(2, until=lambda: self.calls("kick")))
        dlg = app.host_invite_dialog()
        dlg.make()
        self.assertTrue(self.pump(2, until=lambda: dlg.link.get()))
        self.assertTrue(dlg.link.get().startswith("openvanilla://join/"))
        self.assertEqual(self.calls("invite"), [("invite", 5, 24)])
        self.assertEqual(app.clipboard_get(), dlg.link.get())
        dlg.close()
        a = app.host_announce()
        a.body.winfo_children()[0].insert(0, "Server restarts in 5 minutes")
        a.button_cmds["Announce"]()
        app.host_backup()
        self.assertTrue(self.pump(2, until=lambda: self.calls("announce") and self.calls("backup")))

        app.host_stop()
        self.assertTrue(self.pump(3, until=lambda: app.p2p_host is None))
        self.assertEqual(self.calls("stop"), [("stop",)])
        self.assertEqual(self.errors, [])

    def test_host_needs_a_name(self):
        app = self.start()
        app.tab_state["host"] = "realm"
        app.show_page("host", animate=False)
        app._hostv["name"].delete(0, "end")
        app.host_start()
        self.assertIsNone(app.p2p_host)
        self.assertIn("name", self.errors[0][1])

    def test_close_while_hosting_goes_to_tray_when_asked(self):
        app = self.start()
        app.settings["p2p_host"] = {"name": "Test Realm", "tray": True}
        app.tab_state["host"] = "realm"
        app.show_page("host", animate=False)
        app.host_start()
        tray = []
        app._tray_start = lambda: tray.append(1)
        app.close_app()
        self.assertEqual(tray, [1])
        self.assertIsNotNone(app.p2p_host)

    # --------------------------------------------------------------- direct / LAN / offline

    def _host_page(self, conn):
        app = self.app or self.start()
        app.settings["p2p_host"] = {"name": "Test Realm", "connection": conn, "upnp": True}
        app.tab_state["host"] = "realm"
        app.show_page("host", animate=False)
        return app

    def test_direct_hosting_needs_the_privacy_notice_first(self):
        app = self._host_page("direct")
        self.assertEqual(app._hostv["connection"].get(), "direct")
        dlg = app.host_start()
        self.assertIsNone(app.p2p_host)                      # nothing starts before the notice is accepted
        t = dlg.text.lower()
        for words in ("ip address", "city", "3724", "8085", "unencrypted", "trust", "stop hosting", "through openvanilla"):
            self.assertIn(words, t)
        dlg.button_cmds["I understand, start"]()
        sess = sys.modules["p2p.host"].HostSession.last
        self.assertEqual((sess.cfg.connection, sess.cfg.upnp_consent), ("direct", True))
        self.assertTrue(self.pump(4, until=lambda: getattr(app, "_host_addr_lbl", None) is not None
                                  and app._host_addr_lbl.winfo_exists()))
        self.assertIn("198.51.100.23", app._host_addr_lbl.cget("text"))
        self.assertIn("sees this address", app._host_addr_lbl.tip_text)

        g = app.host_invite_dialog(guest=True)
        g.make()
        self.assertTrue(self.pump(2, until=lambda: g.link.get()))
        self.assertTrue(g.link.get().startswith("openvanilla://join/direct/198.51.100.23:3724?g="))
        g.close()
        a = app.host_account_dialog()
        a.name.insert(0, "bob")
        a.password.insert(0, "hunter22")
        a.make()
        self.assertTrue(self.pump(2, until=lambda: "BOB" in a.out.get("1.0", "end")))
        details = a.out.get("1.0", "end")
        self.assertIn("set realmlist 198.51.100.23", details)
        self.assertIn("HUNTER22", app.clipboard_get())

    def test_direct_notice_can_switch_to_relay(self):
        app = self._host_page("direct")
        dlg = app.host_start()
        dlg.button_cmds["Use Open Vanilla instead"]()
        self.assertIsNone(app.p2p_host)
        self.assertEqual(app.settings["p2p_host"]["connection"], "relay")

    def test_without_the_relay_hosting_is_direct_after_the_notice(self):
        app = self.start(relay=False)
        app.settings["p2p_host"] = {"name": "Test Realm"}          # an old "relay" default
        app.tab_state["host"] = "realm"
        app.show_page("host", animate=False)
        self.assertEqual(app._hostv["connection"].get(), "direct")
        self.assertNotIn("relay", [k for k, _ in app.host_connections()])
        dlg = app.host_start()
        self.assertIsNone(app.p2p_host)
        self.assertNotIn("Use Open Vanilla instead", dlg.button_cmds)
        dlg.button_cmds["Local network only"]()
        self.assertEqual(app.settings["p2p_host"]["connection"], "lan")

    def test_host_tabs_follow_advanced_and_flags(self):
        app = self.start(relay=False, advanced=False)
        self.assertEqual([k for k, _ in app.host_tabs()], ["realm", "server", "node"])
        app.tab_state["host"] = "downloads"
        app.show_page("host", animate=False)                       # falls back to Host for friends
        self.assertTrue(hasattr(app, "_hostv"))
        app.live.doc = {"schema": 1, "flags": {"dedicated_server": False}}
        self.assertEqual([k for k, _ in app.host_tabs()], ["realm", "node"])
        app.live.doc = {"schema": 1, "flags": {"dedicated_server": False, "host_friends": False}}
        self.assertEqual(app.host_tabs(), [], "hosting off: no Become a node tab either")

    def test_lan_hosting_starts_without_the_notice(self):
        app = self._host_page("lan")
        app.host_start()
        self.assertEqual(sys.modules["p2p.host"].HostSession.last.cfg.connection, "lan")
        self.assertEqual(sys.modules["p2p.host"].HostSession.last.cfg.visibility, "private")
        self.assertIsNotNone(app.p2p_host)

    def test_join_by_address_with_a_guest_code(self):
        app = self.start()
        app.launch_at = lambda *a, **k: object()
        dlg = app.join_address_dialog()
        dlg.fields["address"].insert(0, "198.51.100.23:3724")
        dlg.fields["guest"].insert(0, "guestcode2")
        dlg.button_cmds["Join"]()
        self.assertIn("IP address", self.asks[-1][1])          # the host will see yours
        self.assertTrue(self.pump(3, until=lambda: app.settings.get("p2p_recent")))
        self.assertEqual(self.calls("join")[0][1], "198.51.100.23:3724")
        self.assertEqual(self.calls("join_extra"), [("join_extra", "GUESTCODE2", None, None)])
        self.assertEqual(app.settings["p2p_recent"][0]["key"], "198.51.100.23:3724")

    def test_direct_and_lan_links(self):
        app = self.start()
        app.launch_at = lambda *a, **k: object()
        self.assertTrue(app.open_invite("openvanilla://join/direct/198.51.100.23:3724?g=GUESTCODE2&n=Bob"))
        self.assertIn("IP address", self.asks[-1][1])
        self.assertTrue(app.open_invite("openvanilla://join/lan/192.168.1.20:3724?g=GUESTCODE2"))
        self.assertIn("local network", self.asks[-1][1])
        inv = self.L.parse_link("openvanilla://join/lan/192.168.1.20:3724?g=guestcode2&k=abc")
        self.assertEqual((inv["kind"], inv["host"], inv["port"], inv["guest"]), ("lan", "192.168.1.20", 3724, "GUESTCODE2"))

    def test_changed_host_key_is_explained(self):
        app = self.start()
        app.join_address("changed.example:3724")
        self.assertTrue(self.pump(3, until=lambda: self.errors))
        title, body = self.errors[0][:2]
        self.assertEqual(title, "Host key changed")
        self.assertIn("new invite link", body)
        self.assertIn("pretending", body)
        self.assertFalse(app.settings.get("p2p_recent"))

    def test_offline_directory_says_you_can_still_play(self):
        def down(url):
            raise OSError("The realm list can't be reached (timed out).")
        sys.modules["p2p.directory"].fetch = down
        app = self.start()
        app.tab_state["servers"] = "realms"
        app.show_page("servers", animate=False)
        self.assertTrue(self.pump(3, until=lambda: app.p2p["error"]))
        self.assertEqual(app.p2p["error"], self.L.OFFLINE_TEXT)
        self.assertIn("host and join friends directly", self.L.OFFLINE_TEXT)

    # --------------------------------------------------------------- Downloads & seeding

    def test_seeding_is_opt_in_with_an_explainer(self):
        app = self.start()
        app.tab_state["host"] = "downloads"
        app.show_page("host", animate=False)
        self.pump(0.3)
        t = app.p2p_torrents
        self.assertFalse(t.seeding_enabled)
        self.assertEqual(self.calls("enable_seeding"), [])
        app.set_seeding(True)                         # the explainer first, nothing turned on yet
        dlg = app._p2p_dialog
        self.assertEqual(self.calls("enable_seeding"), [])
        for words in ("only openvanilla's own files", "never blizzard", "kb/s", "stop any time"):
            self.assertIn(words, dlg.text.lower())
        dlg.button_cmds["Not now"]()
        self.assertFalse(t.seeding_enabled)
        app.set_seeding(True)
        app._p2p_dialog.button_cmds["Turn on seeding"]()
        self.assertEqual(self.calls("enable_seeding"), [("enable_seeding", 512)])
        self.assertTrue(app.settings["p2p_torrent"]["seeding"])
        app.set_seeding(False)
        self.assertEqual(self.calls("disable_seeding"), [("disable_seeding",)])
        self.assertFalse(app.settings["p2p_torrent"]["seeding"])

    def test_downloads_list_shows_torrents(self):
        app = self.start()
        app.tab_state["host"] = "downloads"
        app.show_page("host", animate=False)
        self.pump(1.3)

        def texts(w):
            out = [w.cget("text")] if isinstance(w, tk.Label) else []
            for c in w.winfo_children():
                out += texts(c)
            return out

        t = " | ".join(texts(app._dl_frame))
        self.assertIn("Open Vanilla client 1.15.0", t)
        self.assertIn("42%", t)
        self.assertIn("4 peers", t)
        self.assertIn("libtorrent isn't installed", t)

    # --------------------------------------------------------------- Become a node

    def _texts(self, w):
        out = [w.cget("text")] if isinstance(w, tk.Label) else []
        for c in w.winfo_children():
            out += self._texts(c)
        return out

    def test_become_a_node_waits_for_the_test_round(self):
        app = self.start()
        app._node_board.update(data={"supporters": [], "status": "No supporters listed yet."}, loading=False)
        app.tab_state["host"] = "node"
        app.show_page("host", animate=False)
        self.pump(0.3)
        t = " | ".join(self._texts(app._node_frame))
        self.assertIn("BECOME A NODE", t)
        self.assertIn("isn't open yet", t)
        self.assertIn("COMMUNITY P2P realms", t)
        self.assertIsNone(app.node_turn_on())                    # flags.nodes off: a notice, nothing starts
        self.assertEqual(self.calls("node_accept"), [])
        self.assertIn("No supporters listed yet", " | ".join(self._texts(app._node_board_frame)))

    def test_become_a_node_is_opt_in_with_one_click_off(self):
        app = self.start()
        app.live.doc = {"schema": 1, "flags": {"relay": True, "nodes": True}}
        app._node_board.update(data={"supporters": [{"rank": 1, "name": "Ann", "relay_gb": 12.5, "uptime_pct": 99,
                                                      "badges": ["node", "seeder"]}],
                                     "network": {"nodes_verified": 1, "relay_gb": 12.5}}, loading=False)
        app.tab_state["host"] = "node"
        app.show_page("host", animate=False)
        self.pump(0.3)
        self.assertFalse(app.settings["p2p_node"]["enabled"], "off by default")
        board = " | ".join(self._texts(app._node_board_frame))
        self.assertIn("Ann", board)
        self.assertIn(" NODE", board)
        self.assertIn("12.5 GB · 99% up", board)
        app._nodev["public_url"].delete(0, "end")
        app._nodev["public_url"].insert(0, "ws://203.0.113.5:3728")
        dlg = app.node_turn_on()                                  # the explanation first
        self.assertEqual(self.calls("node_accept"), [])
        for words in ("never blizzard", "kb/s", "can see your ip", "turn off", "node rules"):
            self.assertIn(words, dlg.text.lower())
        dlg.button_cmds["Not now"]()
        self.assertEqual(self.calls("node_accept"), [])
        app.node_turn_on()
        app._p2p_dialog.button_cmds["Turn on my node"]()
        self.assertTrue(self.pump(2, until=lambda: self.calls("node_accept")))
        self.assertEqual(self.calls("node_accept")[0][1]["public_url"], "ws://203.0.113.5:3728")
        self.assertIn(("node_game_status", "pending"), p2p_fakes.CALLS, "the game's Node window hears about it")
        self.pump(0.3)
        self.assertIn("ON: BEING CHECKED", " | ".join(self._texts(app._node_frame)))
        app.node_turn_off()                                       # one click
        self.assertEqual(self.calls("node_turn_off"), [("node_turn_off",)])
        self.assertFalse(app.settings["p2p_node"]["enabled"])
        self.assertIn(("node_game_status", "off"), p2p_fakes.CALLS)


@unittest.skipUnless(HAVE_TK, "needs tkinter, Pillow and a display (xvfb-run)")
class NoP2PTests(unittest.TestCase):
    """Without launcher/p2p (or with a broken one) the launcher still starts and the pages say so."""

    def test_launcher_starts_and_pages_degrade(self):
        code = r"""
import sys
class Block:  # as if launcher/p2p (and libtorrent) weren't shipped
    def find_spec(self, name, path=None, target=None):
        if name == "p2p" or name.startswith("p2p.") or name == "libtorrent":
            raise ImportError("no " + name)
sys.meta_path.insert(0, Block())
sys.argv = ["x"]
import openvanilla_launcher as L
L.Launcher.refresh_realms = L.Launcher.check_for_update = L.Launcher.load_directory = lambda s: None
L.SETTINGS_PATH = sys.argv[0] + ".json"
app = L.Launcher()
for page, tab in (("servers", "realms"), ("host", "realm"), ("host", "downloads"), ("host", "server"), ("host", "node")):
    app.tab_state[page] = tab
    app.show_page(page, animate=False)
    app.update()
assert app.torrents() is None and L.p2p_module("join") is None
app.destroy()
print("OK")
"""
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            r = subprocess.run([sys.executable, "-c", code.replace('sys.argv[0] + ".json"', repr(os.path.join(d, "s.json")))],
                               cwd=LAUNCHER, capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr[-2000:])
        self.assertIn("OK", r.stdout)
        self.assertNotIn("Traceback", r.stderr)


if __name__ == "__main__":
    unittest.main()
