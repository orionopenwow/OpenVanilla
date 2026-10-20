# Trailer footage recorder

`Record_Footage.bat` (repo root) films every Open Vanilla feature on its own, without OBS, and writes one video per feature to `_local\video\raw\<date>\<scene>.mp4` (1920x1080, 60 fps, H.264), plus each shot as its own file in `<scene>\` for editing.

```
Record_Footage.bat                         every scene this PC can run
Record_Footage.bat site-home agents-demo   only those
Record_Footage.bat --list                  every scene, and what it needs
Record_Footage.bat game-world --fps 30     options: --width --height --fps --out --chrome
```

Browser scenes open a real Chrome window (your graphics card) that drives itself; they are filmed from the page's own frames, so nothing else on the desktop gets in. A soft gold cursor is drawn where a scene points at things. Hands off the mouse and keyboard while it runs.

| Scene | What it films | Needs |
|---|---|---|
| `site-home` | Home page: hero, realm list, launcher, addons, Forge, Agents, Herald, What's next | — |
| `site-forge`, `site-agents`, `site-herald` | The feature pages | — |
| `site-workshop`, `site-host` | Workshop and manual; Host a realm and Play Solo | — |
| `game-start` | Sign-in page, Play free as a guest, loading, character screens | the realm online |
| `game-world` | In the world: open world, run, addon windows, World chat, expanded chat, bug button, welcome | `OWBOT_USER` / `OWBOT_PASS` in `.env` |
| `agents-demo` | Vanilla Agents demo inn: loading, welcome, orbit, helpers at laptops (the gnome first), walk, quest log and party | Vanilla Agents in `VA_DIR` (default `Downloads\VanillaAgents\vanilla-agents`) |
| `launcher` | The desktop launcher window | Windows |
| `forge` | The Vanilla Forge window | `FORGE_EXE` or the default install path |

Settings come from `.env` or the environment: `SITE_URL` (film a local copy of the site), `REALM_URL`, `OWBOT_USER`, `OWBOT_PASS`, `VA_DIR` or `VA_URL` (an inn already running, with its `#k=` key), `FORGE_EXE`, `CHROMIUM`.

## Adding a scene

A scene is an object in `scenes/*.mjs`: `name`, `title`, optional `ready(env)` (true, or why not), optional `setup(s)` (returns a stop function), and `run(s)`. Inside, `s.shot(name, seconds, async () => { ... })` films while the function runs (at least `seconds`). Helpers: `s.goto`, `s.glide(x, y, ms)`, `s.point(selector)`, `s.click(selector)`, `s.type(text)`, `s.scrollTo(selector | y | 'bottom', ms)`, `s.cursor(on)`, `s.tidy([selectors])`, `s.sleep(ms)`, plus `s.page` (Playwright) for anything else. Desktop scenes use `kind: 'desktop'` with `s.start(cmd, args, cwd)` and `s.shot(name, windowTitle, seconds)`.

Files: `record.mjs` (runner), `encode.py` (frames to a steady 60 fps video, window capture, joins), `scenes/`.
