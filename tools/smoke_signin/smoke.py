"""End-to-end smoke test of the launcher's Discord sign-in against a real wenilla-realm build,
with mangosd's SOAP and Discord mocked. Drives the real launcher (Tk, Xvfb) through:
first sign-in from the account chip, restart → still signed in, switch account, sign out,
PLAY while signed out (signs in first, then plays)."""
import base64, http.cookiejar, json, os, shutil, sqlite3, subprocess, sys, tempfile, threading, time, urllib.parse, urllib.request
import mocks

ROOT = tempfile.mkdtemp(prefix="owsmoke-")
REALM = "http://127.0.0.1:18090"
results = []

def check(name, ok, detail=""):
    results.append((name, bool(ok)))
    print(("PASS " if ok else "FAIL ") + name + (f"  ({detail})" if detail else ""), flush=True)

# ---- the realm service
mocks.start()
for d in ("state", "config", "www"):
    os.makedirs(os.path.join(ROOT, d))
open(os.path.join(ROOT, "www", "wenilla.js"), "w").write("export default async function init() {}")
open(os.path.join(ROOT, "config", "mangosd.conf"), "w").write("Rate.XP.Kill = 1\nPlayerLimit = 100\nMaxPlayerLevel = 60\nMotd = \"Hi\"\n")
open(os.path.join(ROOT, "config", "aiplayerbot.conf"), "w").write("AiPlayerbot.Enabled = 0\n")
open(os.path.join(ROOT, "config", "ahbot.conf"), "w").write("AuctionHouseBot.Chance.Sell = 0\n")
env = dict(os.environ, REALM_BIND="127.0.0.1:18090", REALM_PUBLIC_URL=REALM, REALM_COOKIE_INSECURE="1",
           REALM_STATE_DIR=f"{ROOT}/state", REALM_WWW=f"{ROOT}/www", CONFIG_DIR=f"{ROOT}/config",
           CLIENT_DATA=f"{ROOT}/nodata", SOAP_URL="http://127.0.0.1:17878/",
           MARIADB_URL="mysql://nobody:nothing@127.0.0.1:1/classicrealmd", RUST_LOG="warn",
           DISCORD_CLIENT_ID="111111111111111111", DISCORD_CLIENT_SECRET="s3cret",
           DISCORD_GUILD_ID="444444444444444444", DISCORD_BOT_TOKEN="bot-token",
           DISCORD_REQUIRE_ROLE_IDS="222222222222222222", DISCORD_GRANT_ROLE_ID="333333333333333333",
           DISCORD_INVITE_URL="https://discord.gg/9KGdUDGnv9",
           DISCORD_API_BASE="http://127.0.0.1:18099/api/v10",
           DISCORD_AUTHORIZE_URL="http://127.0.0.1:18099/oauth2/authorize")
realm = subprocess.Popen([sys.argv[1]], env=env, stdout=open(f"{ROOT}/realm.log", "w"), stderr=subprocess.STDOUT)
for _ in range(100):
    try:
        urllib.request.urlopen(REALM + "/setup", timeout=1); break
    except urllib.error.HTTPError:
        break
    except Exception:
        time.sleep(0.2)
token = sqlite3.connect(f"{ROOT}/state/realm.sqlite").execute("SELECT value FROM meta WHERE key='setup_token'").fetchone()[0]
form = urllib.parse.urlencode(dict(token=token, admin_username="boss", admin_password="correct horse battery",
                                   admin_password2="correct horse battery", realm_name="Vanilla Remastered")).encode()
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a): return None
try:
    urllib.request.build_opener(NoRedirect).open(urllib.request.Request(REALM + "/setup", data=form))
    setup_status = 200
except urllib.error.HTTPError as e:
    setup_status = e.code
check("realm service up and set up", setup_status in (302, 303), f"setup answered {setup_status}")

# ---- the player's browser: follows every redirect with its own cookies
jar = http.cookiejar.CookieJar()
browser = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
opened = []
def fake_browser(url, *a, **k):
    opened.append(url)
    def go():
        try:
            r = browser.open(url, timeout=15); opened.append("landed " + r.geturl()); r.read()
        except Exception as e:
            opened.append(f"browser error {e}")
    threading.Thread(target=go, daemon=True).start()
    return True

# ---- the launcher
os.environ["HOME"] = tempfile.mkdtemp(prefix="owhome-")
os.environ["APPDATA"] = os.environ["HOME"]
sys.path.insert(0, os.path.abspath("launcher")); os.chdir("launcher")
import tkinter.messagebox as mb
mb.showinfo = mb.showwarning = mb.showerror = lambda *a, **k: None
import account
account.protect = lambda t: base64.b64encode(t.encode()).decode() if t else None   # DPAPI stand-in
account.unprotect = lambda b: base64.b64decode(b).decode() if b else None
import openvanilla_launcher as L
L.webbrowser.open = fake_browser
from PIL import ImageGrab

def shot(app, name):
    app.update(); im = ImageGrab.grab(xdisplay=":99"); x, y = app.winfo_rootx(), app.winfo_rooty()
    im.crop((x, y, x + app.winfo_width(), y + app.winfo_height())).save(f"/tmp/claude-0/shots/{name}.png")

def drive(app, scenario):
    """Run `scenario` (a generator yielding (condition, seconds)) inside the app's own mainloop, so
    the launcher's worker threads can hand results back exactly as in real use."""
    gen = scenario()
    state = {"cond": None, "until": 0}
    def advance(value):
        try:
            cond, secs = gen.send(value)
            state["cond"], state["until"] = cond, time.time() + secs
            app.after(50, pump)
        except StopIteration:
            app.after(10, app.destroy)
    def pump():
        if state["cond"]():
            advance(True)
        elif time.time() > state["until"]:
            advance(False)
        else:
            app.after(50, pump)
    app.after(300, lambda: advance(None))
    app.mainloop()

never = lambda: False
first = {}

def run1():
    yield never, 1.5
    check("starts signed out", not app.session.get("user"))
    shot(app, "signin_0_signed_out")
    # 1. first sign-in: one click on the account chip
    app._chip_click()
    check("chip click opens Discord sign-in in the browser at once",
          opened and opened[0].startswith(REALM + "/auth/launcher?port="), opened[:1])
    ok = yield (lambda: app.session.get("via") == "discord" and app.session.get("verified")), 20
    check("signed in without typing anything", ok, f"user={app.session.get('user')}")
    check("display name from Discord", app.session.get("display") == "Thrall Warchief", app.session.get("display"))
    check("game account handed over", str(app.session.get("user", "")).startswith("WR") and len(app.session.get("password", "")) == 16)
    check("browser landed on the launcher's 'you're signed in' page",
          any(o.startswith("landed http://127.0.0.1:") and "openvanilla-signin" in o for o in opened), opened[-1:])
    check("remembered: token and password saved (encrypted)", bool(app.settings.get("launcher_token")) and bool(app.settings.get("saved_password")))
    first["user"] = app.session.get("user")
    app.show_page("account", animate=False); yield never, 1; shot(app, "signin_1_account_page")
    app.show_page("play", animate=False); yield never, 1; shot(app, "signin_2_home")

def run2():
    ok = yield (lambda: app.session.get("verified") is True), 15
    check("restart: still signed in, confirmed with the realm", ok and app.session.get("user") == first["user"])
    check("restart: no browser prompt", not opened, opened)
    # 3. browser already signed in on the site: no Discord step at all
    log_before = len(mocks.STATE["log"])
    app._sign_out_quietly(); app._paint_chip()
    app._chip_click()
    ok = yield (lambda: app.session.get("verified") is True), 20
    new_auth = [l for l in mocks.STATE["log"][log_before:] if l.startswith("authorize")]
    check("signed in on the website already → instant, no Discord page", ok and not new_auth, new_auth)
    # 4. switch account
    app.switch_account()
    ok = yield (lambda: app.session.get("display") == "Jaina Proudmoore"), 20
    check("switch account → Discord account screen → other player", ok and app.session.get("user") != first["user"],
          f"{app.session.get('display')} {app.session.get('user')}")
    check("switch used prompt=consent", "authorize prompt=consent" in mocks.STATE["log"])
    old_token = app.session.get("token")
    # 5. sign out
    app.sign_out()
    yield never, 1.5
    status, _ = account.launcher_me(REALM, old_token)
    check("sign out ends the launcher token on the realm", status == 401, status)
    check("sign out clears saved login", not app.settings.get("launcher_token") and not app.settings.get("saved_password"))
    shot(app, "signin_3_signed_out_page")
    # 6. PLAY while signed out
    played = []
    app.readiness = lambda: (True, "READY", "", "blue", None)
    app.client = lambda: {"type": "exe", "name": "Vanilla", "realmlist": "realmlist.wtf"}
    app.client_exe = lambda c: "/nonexistent/WoW.exe"
    app.play_exe = lambda c, exe, realm: played.append(app.session.get("user"))
    app.play()
    ok = yield (lambda: bool(played)), 20
    check("PLAY while signed out → Discord sign-in → game starts", ok and played and played[0], played)

setup_creates = len([l for l in mocks.STATE["log"] if l.startswith("soap account create")])
app = L.Launcher()
drive(app, run1)
opened.clear()
app = L.Launcher()
drive(app, run2)

# 7. one game account per Discord player
creates = [l.split()[3] for l in mocks.STATE["log"] if l.startswith("soap account create")][setup_creates:]
check("one game account per Discord player (2 players, 4 sign-ins, 2 accounts)", len(creates) == 2, creates)

realm.terminate()
print(f"\n{sum(ok for _, ok in results)}/{len(results)} checks passed")
sys.exit(0 if all(ok for _, ok in results) else 1)
