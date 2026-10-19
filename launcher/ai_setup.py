"""Activate your AI (optional): help a player point an AI coding agent they already have at their own
Open Vanilla copy. Claude Code first; any agent that reads AGENTS.md works too.

    tools = detect_tools()                     which agents are on this PC (Claude Code first)
    res = install_kit(kit_source(), data_dir)  copy agent/ into the user-data folder (idempotent)
    prompts = list_prompts(kit_source())       the starter prompt library (agent/prompts/*.md)
    argv, kw = terminal_command(data_dir, tool) a terminal in the workspace running the agent

The workspace is the user-data folder (layout.Layout.data): CLAUDE.md and AGENTS.md go at its root so
the agent reads them first, the README and prompts go in Agent\\. A file the player edited is never
overwritten (Agent\\.kit.json remembers what the kit last wrote).

Open Vanilla stores no AI keys or accounts: the agent runs in its own window with the player's own account.
Nothing here touches the network. Live content can hide the feature (flag "ai").

The Tk parts (on_start, settings_section) take the launcher as `app` and import tkinter lazily, so the
rest is testable without a display. Standard library only; Python 3.10 compatible.
"""
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys

KIT_DIR = "Agent"                 # README + prompts inside the workspace
ROOT_FILES = ("CLAUDE.md", "AGENTS.md")   # these go at the workspace root
MANIFEST = ".kit.json"            # in Agent\: {version, files: {rel: sha256 the kit wrote}}
KIT_EXTS = (".md", ".txt")
MAX_KIT_FILE = 256 * 1024
FLAG = "ai"
INSTALL_URL = "https://code.claude.com/docs/en/setup"
QUICKSTART_URL = "https://code.claude.com/docs/en/quickstart"
GUIDE_PAGE = "ai.html"
OFFER_AFTER_LAUNCHES = 2          # the optional card shows once, on the launch after the first
PROMPT_ORDER = ("tour-my-install", "first-addon", "fix-addon-error", "ui-theme", "xp-rate", "custom-npc-vendor",
                "host-for-friends", "gm-commands", "backup")   # the library's order (launcher and game)

# (id, name, commands to look for, where to get it)
TOOLS = (
    ("claude", "Claude Code", ("claude",), INSTALL_URL),
    ("codex", "Codex CLI", ("codex",), "https://github.com/openai/codex"),
    ("gemini", "Gemini CLI", ("gemini",), "https://github.com/google-gemini/gemini-cli"),
    ("aider", "Aider", ("aider",), "https://aider.chat/"),
    ("cursor", "Cursor", ("cursor",), "https://cursor.com/"),
    ("code", "VS Code", ("code",), "https://code.visualstudio.com/"),
)


class KitError(Exception):
    """Something to show the player as is."""


# ---------------------------------------------------------------- detection

def _claude_extra_paths(env, platform):
    """Where the Claude Code installers put `claude` when a launcher started from Explorer/Finder has an
    older PATH than a fresh terminal."""
    home = env.get("USERPROFILE") or env.get("HOME") or os.path.expanduser("~")
    if platform == "win32":
        out = [os.path.join(home, ".local", "bin", "claude.exe")]
        if env.get("APPDATA"):
            out.append(os.path.join(env["APPDATA"], "npm", "claude.cmd"))
        if env.get("LOCALAPPDATA"):
            out.append(os.path.join(env["LOCALAPPDATA"], "Microsoft", "WinGet", "Links", "claude.exe"))
        return out
    return [os.path.join(home, ".local", "bin", "claude"), "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]


def detect_tools(which=shutil.which, isfile=os.path.isfile, env=None, platform=None):
    """[{id, name, found, path, url}] for every known agent, Claude Code first."""
    env = os.environ if env is None else env
    platform = platform or sys.platform
    out = []
    for tid, name, cmds, url in TOOLS:
        path = None
        for c in cmds:
            path = which(c)
            if path:
                break
        if not path and tid == "claude":
            path = next((p for p in _claude_extra_paths(env, platform) if isfile(p)), None)
        out.append({"id": tid, "name": name, "found": bool(path), "path": path, "url": url})
    return out


def tool(tools, tid):
    return next((t for t in tools if t["id"] == tid), None)


# ---------------------------------------------------------------- the kit

def kit_candidates(frozen=None, meipass=None, here=None):
    """Where the shipped agent/ folder is: app\\agent frozen (PyInstaller data), <checkout>\\agent from source."""
    frozen = getattr(sys, "frozen", False) if frozen is None else frozen
    here = here or os.path.dirname(os.path.abspath(__file__))
    out = []
    if frozen:
        base = meipass or getattr(sys, "_MEIPASS", None) or os.path.dirname(sys.executable)
        out += [os.path.join(base, "agent"), os.path.join(os.path.dirname(base), "app", "agent")]
    out += [os.path.join(os.path.dirname(here), "agent"), os.path.join(here, "agent")]
    return out


def kit_source(candidates=None):
    """The first candidate folder that holds a kit (CLAUDE.md), or None."""
    for c in candidates or kit_candidates():
        if os.path.isfile(os.path.join(c, "CLAUDE.md")):
            return c
    return None


def _sha(data):
    return hashlib.sha256(data).hexdigest()


def safe_rel(rel):
    """A kit-relative path that stays inside its folder: no absolute paths, drives, '..' or empty parts."""
    rel = str(rel or "").replace("\\", "/")
    if not rel or rel.startswith("/") or re.match(r"^[A-Za-z]:", rel) or "\0" in rel:
        return None
    parts = rel.split("/")
    if any(p in ("", ".", "..") for p in parts):
        return None
    return "/".join(parts)


def kit_files(src):
    """{workspace-relative path: kit file} for the kit in src. Root files stay at the root; the rest goes
    under Agent/. Symlinks, hidden files, other types and large files are skipped."""
    src = os.path.abspath(src)
    files = {}
    for dirpath, dirnames, names in os.walk(src):
        dirnames[:] = sorted(d for d in dirnames if not d.startswith(".")
                             and not os.path.islink(os.path.join(dirpath, d)))
        for n in sorted(names):
            full = os.path.join(dirpath, n)
            if n.startswith(".") or os.path.islink(full) or not n.lower().endswith(KIT_EXTS):
                continue
            if os.path.getsize(full) > MAX_KIT_FILE:
                continue
            rel = safe_rel(os.path.relpath(full, src))
            if not rel:
                continue
            dest = rel if rel in ROOT_FILES else KIT_DIR + "/" + rel
            files[dest] = full
    return files


def check_workspace(workspace, home=None):
    """The workspace as an absolute path, or KitError when it is somewhere a kit must never go."""
    if not workspace:
        raise KitError("No Open Vanilla data folder is set.")
    ws = os.path.abspath(workspace)
    real = os.path.realpath(ws)
    home = os.path.realpath(home or os.path.expanduser("~"))
    if os.path.dirname(real) == real:
        raise KitError(f"Refusing to use a drive root as the AI workspace: {ws}")
    if real == home:
        raise KitError("Refusing to use your whole user folder as the AI workspace.")
    if os.path.exists(ws) and not os.path.isdir(ws):
        raise KitError(f"The data folder is not a folder: {ws}")
    return ws


def _inside(root, path):
    root = os.path.realpath(root)
    path = os.path.realpath(path)
    return path == root or path.startswith(root.rstrip(os.sep) + os.sep)


def _make_parents(ws, rel):
    """The destination for rel, creating its folders one at a time and refusing any symlink (or file) on
    the way, so nothing is ever created or written outside the workspace."""
    cur = ws
    for part in rel.split("/")[:-1]:
        cur = os.path.join(cur, part)
        if os.path.islink(cur) or (os.path.exists(cur) and not os.path.isdir(cur)):
            raise KitError(f"Refusing to write outside the data folder: {rel}")
        if not os.path.isdir(cur):
            os.mkdir(cur)
    dest = os.path.join(cur, rel.split("/")[-1])
    if os.path.islink(dest) or not _inside(ws, dest):
        raise KitError(f"Refusing to write outside the data folder: {rel}")
    return dest


def _read_manifest(ws):
    try:
        with open(os.path.join(ws, KIT_DIR, MANIFEST), encoding="utf-8") as f:
            doc = json.load(f)
        return doc if isinstance(doc, dict) and isinstance(doc.get("files"), dict) else {"files": {}}
    except (OSError, ValueError):
        return {"files": {}}


def _write_atomic(path, data):
    tmp = path + ".openvanilla-tmp"
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, path)


def install_kit(src, workspace, version="", home=None):
    """Copy the kit into the workspace. Returns {written, updated, unchanged, kept} (workspace-relative
    paths). Safe to run again: unchanged files are left, files the kit wrote before are refreshed, and a
    file the player edited (or wrote themselves) is kept as it is."""
    if not src or not os.path.isfile(os.path.join(src, "CLAUDE.md")):
        raise KitError("The AI starter kit is missing from this Open Vanilla build.")
    ws = check_workspace(workspace, home)
    os.makedirs(ws, exist_ok=True)
    old = _read_manifest(ws)["files"]
    res = {"written": [], "updated": [], "unchanged": [], "kept": []}
    wrote = {}
    for rel, full in sorted(kit_files(src).items()):
        dest = _make_parents(ws, rel)
        with open(full, "rb") as f:
            data = f.read()
        new = _sha(data)
        if os.path.isfile(dest):
            with open(dest, "rb") as f:
                cur = _sha(f.read())
            if cur == new:
                res["unchanged"].append(rel)
                wrote[rel] = new
                continue
            if old.get(rel) != cur:          # not what the kit wrote last time: the player's own version
                res["kept"].append(rel)
                if rel in old:
                    wrote[rel] = old[rel]
                continue
            _write_atomic(dest, data)
            res["updated"].append(rel)
        elif os.path.exists(dest):
            raise KitError(f"Something that isn't a file is in the way: {rel}")
        else:
            _write_atomic(dest, data)
            res["written"].append(rel)
        wrote[rel] = new
    _write_atomic(_make_parents(ws, KIT_DIR + "/" + MANIFEST),
                  json.dumps({"version": version, "files": wrote}, indent=1, sort_keys=True).encode("utf-8"))
    return res


def kit_installed(workspace):
    return bool(workspace) and os.path.isfile(os.path.join(workspace, "CLAUDE.md")) and \
        os.path.isfile(os.path.join(workspace, KIT_DIR, MANIFEST))


def summary(res):
    """One line for the launcher's notice bar."""
    n_new = len(res["written"]) + len(res["updated"])
    if not n_new and not res["kept"]:
        return "AI workspace is up to date"
    text = f"AI workspace ready ({n_new} file{'s' if n_new != 1 else ''} copied)" if n_new else "AI workspace checked"
    if res["kept"]:
        text += f"; {len(res['kept'])} you edited left as they are"
    return text


# ---------------------------------------------------------------- prompts

def parse_prompt(text, pid=""):
    """{id, title, summary, works, text} from one agent/prompts/*.md, or None without a ```text block."""
    title = summary_ = works = ""
    m = re.search(r"^# (.+)$", text, re.M)
    if m:
        title = m.group(1).strip()
        after = text[m.end():].strip().split("\n\n")
        summary_ = after[0].strip() if after and not after[0].startswith(("#", "```", "Works on:")) else ""
    w = re.search(r"^Works on: (.+)$", text, re.M)
    if w:
        works = w.group(1).strip()
    body = re.search(r"```text\n(.*?)\n```", text, re.S)
    if not body:
        return None
    return {"id": pid, "title": title or pid, "summary": summary_, "works": works, "text": body.group(1).strip()}


def list_prompts(src):
    """The starter prompts in src/prompts: PROMPT_ORDER first, any others after by title."""
    out = []
    folder = os.path.join(src or "", "prompts")
    try:
        names = sorted(os.listdir(folder))
    except OSError:
        return out
    for n in names:
        if not n.endswith(".md") or n.startswith("."):
            continue
        try:
            with open(os.path.join(folder, n), encoding="utf-8") as f:
                p = parse_prompt(f.read(), n[:-3])
        except (OSError, UnicodeDecodeError):
            continue
        if p:
            out.append(p)
    rank = {pid: i for i, pid in enumerate(PROMPT_ORDER)}
    out.sort(key=lambda p: (rank.get(p["id"], len(rank)), p["title"].lower()))
    return out


LUA_PROMPTS = os.path.join("Data", "Interface", "addons", "Assistant", "Prompts.lua")   # beside agent/ in a checkout


def lua_prompts(prompts):
    """Prompts.lua for the in-game Assistant addon: the same library as a Lua 5.0 table."""
    out = ["--[[",
           "    Prompts.lua  (Assistant)",
           "    The starter prompt library: the same text as agent/prompts/*.md, which the launcher ships.",
           "    Generated: edit the .md files, then run  python launcher/ai_setup.py --write-lua",
           "]]--", "", "Assistant = Assistant or {}", "Assistant.PROMPTS = {"]
    for p in prompts:
        fields = [p[k] for k in ("title", "summary", "works", "text")]
        if any("]]" in f or "[[" in f or "\n" in f for f in fields) or not re.match(r"^[a-z0-9-]+$", p["id"]):
            raise ValueError(f"prompt {p['id']} can't go into a Lua long string")
        out.append('    { id = "%s",\n      title = [[%s]],\n      summary = [[%s]],\n      works = [[%s]],\n'
                   '      text = [[%s]] },' % tuple([p["id"]] + fields))
    out.append("}")
    return "\n".join(out) + "\n"


# ---------------------------------------------------------------- the terminal

CREATE_NEW_CONSOLE = 0x00000010


def _applescript_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def terminal_command(workspace, program=None, platform=None, which=shutil.which):
    """(argv, popen_kwargs) that open a terminal window in workspace, running program (a path) when given,
    or None when no terminal is known. Nothing is run here."""
    platform = platform or sys.platform
    ws = os.path.abspath(workspace)
    if platform == "win32":
        argv = ["cmd.exe", "/k", program] if program else ["cmd.exe", "/k"]
        return argv, {"cwd": ws, "creationflags": CREATE_NEW_CONSOLE}
    run = (f"cd {shlex.quote(ws)} && " + (shlex.quote(program) if program else "true")
           + "; exec \"${SHELL:-/bin/bash}\"")
    if platform == "darwin":
        script = f'tell application "Terminal" to do script {_applescript_str(run)}'
        return ["osascript", "-e", script, "-e", 'tell application "Terminal" to activate'], {"cwd": ws}
    if which("gnome-terminal"):
        return ["gnome-terminal", f"--working-directory={ws}", "--", "bash", "-lc", run], {"cwd": ws}
    if which("konsole"):
        return ["konsole", "--workdir", ws, "-e", "bash", "-lc", run], {"cwd": ws}
    for term in ("x-terminal-emulator", "xfce4-terminal", "xterm"):
        if which(term):
            return [term, "-e", "bash", "-lc", run], {"cwd": ws}
    return None


def open_terminal(workspace, program=None, popen=subprocess.Popen, platform=None, which=shutil.which):
    """Start the terminal. Returns True when one started."""
    cmd = terminal_command(workspace, program, platform=platform, which=which)
    if not cmd:
        return False
    argv, kw = cmd
    popen(argv, **kw)
    return True


# ---------------------------------------------------------------- the launcher side

def enabled(live):
    """live.json's "ai" flag (on unless the maintainer turns it off)."""
    try:
        return bool(live.flag(FLAG))
    except Exception:
        return True


def _ai_settings(settings):
    s = settings.get("ai")
    if not isinstance(s, dict):
        s = settings["ai"] = {}
    return s


def note_launch(settings):
    """Count this start (the offer waits for the second one). Returns the settings' ai dict."""
    s = _ai_settings(settings)
    s["launches"] = int(s.get("launches", 0) or 0) + 1
    return s


def should_offer(settings, flag_on):
    """The one-time "Activate your AI (optional)" card: flag on, second launch or later, never shown before."""
    s = _ai_settings(settings)
    return bool(flag_on) and not s.get("offered") and int(s.get("launches", 0) or 0) >= OFFER_AFTER_LAUNCHES


OFFER_TEXT = ("Open Vanilla is open source, and your copy is yours to change. If you use an AI coding agent "
              "(Claude Code works best; others work too), Open Vanilla can set it up to make addons, change your "
              "own Solo world or your Open Vanilla Server realm, and help you run it.\n\n"
              "It's optional and stays on your PC: Open Vanilla stores no AI keys or accounts (you use your own), "
              "and nothing it does can touch the official realm. You'll find it any time in Settings → AI.")


def on_start(app, data_dir):
    """Called once from the launcher's __init__: count the launch and, once, offer the optional card."""
    note_launch(app.settings)
    try:
        app.save_settings()
    except Exception:
        pass
    if should_offer(app.settings, enabled(app.live)):
        app.after(2500, lambda: offer(app, data_dir))


def offer(app, data_dir):
    if getattr(app, "_p2p_dialog", None) is not None:   # another dialog is up: ask next launch instead
        return
    _ai_settings(app.settings)["offered"] = True
    app.save_settings()
    dlg = app.p2p_dialog("ACTIVATE YOUR AI (OPTIONAL)", OFFER_TEXT, width=560)

    def go():
        dlg.close()
        app.show_page("settings", animate=False)
        app.notice("Settings → AI is at the end of this page")

    dlg.buttons(("Show me", go, True), ("No thanks", dlg.close, False))
    return dlg


def settings_section(app, inner, data_dir, section, note, buttons, width):
    """Settings > AI: detection, install link, workspace, Open in Claude Code, and the prompt library."""
    import tkinter as tk
    import webbrowser
    mod = sys.modules.get(type(app).__module__)
    col = lambda name, dflt: getattr(mod, name, dflt)
    bg, text_c, green, amber = col("PANEL", "#0f0c14"), col("TEXT", "#ece6da"), col("GREEN", "#5ee08a"), col("AMBER", "#f6c453")
    fnt = getattr(mod, "font", lambda size, weight="normal", display=False: ("Segoe UI", size, weight))

    section("AI  (optional)")
    note("Use an AI coding agent you already have to make addons and change your own Solo world or "
         "Open Vanilla Server realm. Open Vanilla stores no AI keys or accounts: the agent runs in its own window with "
         "your own account (Claude Code needs a paid Claude plan or an Anthropic Console account). Everything "
         "stays on your copy and your own servers; the official realm can't be changed from here.")
    tools = detect_tools()
    claude = tool(tools, "claude")
    line = tk.Frame(inner, bg=bg)
    line.pack(fill="x", pady=(2, 2))
    tk.Label(line, text="Claude Code", bg=bg, fg=text_c, font=fnt(9, "bold")).pack(side="left")
    tk.Label(line, text=("found  " + claude["path"]) if claude["found"] else "not found on this PC",
             bg=bg, fg=green if claude["found"] else amber, font=fnt(8)).pack(side="left", padx=8)
    others = [t["name"] for t in tools if t["found"] and t["id"] != "claude"]
    if others:
        note("Also found: " + ", ".join(others) + ". Open the workspace folder in it and ask it to read AGENTS.md.")
    src = kit_source()
    ready = kit_installed(data_dir)

    def setup():
        try:
            res = install_kit(src, data_dir, version=getattr(app, "version", ""))
        except (KitError, OSError) as e:
            app.notice(f"AI workspace: {e}", col("RED", "#f07a6e"), 8)
            return
        app.notice(summary(res), seconds=5)
        app.show_page("settings", animate=False)

    def open_agent():
        if not kit_installed(data_dir):
            setup()
        current = tool(detect_tools(), "claude")
        if not open_terminal(data_dir, current["path"] if current["found"] else None):
            app.open_path(data_dir)
            app.notice("No terminal found: opened the workspace folder instead", amber, 5)
        elif not current["found"]:
            app.notice("Terminal opened in your workspace. Install Claude Code, then type: claude", amber, 6)

    row = []
    if not claude["found"]:
        row.append(("Install Claude Code", lambda: webbrowser.open(INSTALL_URL)))
    if src:
        row.append(("Update AI workspace" if ready else "Set up AI workspace", setup))
    row.append(("Open in Claude Code" if claude["found"] else "Open terminal here", open_agent))
    buttons(*row)
    buttons(("Open workspace folder", lambda: app.open_path(data_dir)),
            ("How it works", lambda: app._open_site_page(GUIDE_PAGE)))
    note(f"Workspace: {data_dir}" + ("" if ready else "  (not set up yet)") +
         ("" if src else "  ·  this build has no starter kit"))

    prompts = list_prompts(src)
    if prompts:
        pick = tk.Frame(inner, bg=bg)
        pick.pack(fill="x", pady=(4, 2))
        tk.Label(pick, text="Starter prompt", bg=bg, fg=text_c, font=fnt(9)).pack(side="left")
        titles = [p["title"] for p in prompts]
        var = tk.StringVar(value=titles[0])
        about = tk.Label(inner, text="", bg=bg, fg=col("MUTED", "#b8ae9c"), font=fnt(8), wraplength=width - 40, justify="left")

        def show_about():
            p = prompts[titles.index(var.get())]
            about.config(text=p["summary"] + (f"  Works on: {p['works']}" if p["works"] else ""))

        app._optmenu(pick, var, titles, show_about).pack(side="left", padx=8)
        app.wbutton(pick, "Copy prompt", lambda: app._copy(prompts[titles.index(var.get())]["text"],
                                                           "Prompt copied: paste it into your AI tool")).pack(side="left")
        about.pack(anchor="w", pady=(0, 4))
        show_about()
        note("The same prompts are in the game (Esc → Assistant, or /assistant) and in Agent\\prompts\\.")


if __name__ == "__main__":   # python launcher/ai_setup.py --write-lua   (regenerate the Assistant's prompts)
    if sys.argv[1:] == ["--write-lua"]:
        root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        with open(os.path.join(root, LUA_PROMPTS), "w", encoding="utf-8", newline="\n") as f:
            f.write(lua_prompts(list_prompts(os.path.join(root, "agent"))))
        print("wrote", LUA_PROMPTS)
    else:
        print(__doc__)
