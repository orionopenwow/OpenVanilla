# Brand: the project is called **Open Vanilla**

Decided 17 October 2026. The project's old name is no longer used for anything a player,
creator or visitor reads.

## The rule

- Everything people see says **Open Vanilla**: the website, the game page, the launcher, the
  installer, in-game text, Discord, socials, videos, press, creator material, docs and plans.
- Write it as two words, both capitalised: **Open Vanilla**. Possessive: Open Vanilla's.
- Don't write it as one word, with a hyphen, or with the old name in anything public. File names
  are the exception: `OpenVanilla.exe`, `OpenVanilla-Setup-<v>.exe`.
- Lead with what Open Vanilla is to a player ("classic 1.12 in your browser, free, in seconds"), not
  with the engine or the stack. The Rust/WebGPU story is for the tech audience.

## Where things stand

| What | Now | Notes |
|---|---|---|
| Launcher | `OpenVanilla.exe`, "Open Vanilla" shortcuts, window and tray | Bridge releases also ship the old-named twin exe, so launchers from before the rename can update |
| Engine | `Game\Open Vanilla Game.exe` | The launcher renames the older engine file on update |
| Downloads | `OpenVanilla-Setup-<v>.exe`, `OpenVanilla_<v>_Win64.zip`, `OpenVanilla-Server.zip` | The release also publishes the server zip under its old name, for old links |
| Data folder | `%LOCALAPPDATA%\OpenVanilla` (installer), beside the exe (zip) | An existing data folder from before the rename keeps being used, never moved |
| Repository | `github.com/orionopenwow/OpenVanilla` | The old repository address redirects |

## What keeps the old name for now (and why)

These are technical names. Changing them breaks links, saved settings, installs or builds, so they
change only with a redirect or migration.

| Kept for now | Example | Why |
|---|---|---|
| Domains | `openvanilla.app`, `play.openvanilla.app`, `warfront.openvanilla.app` | Existing links, sign-in redirects, Discord OAuth |
| GitHub account | `orionopenwow` | Release URLs, raw script URLs in the guides, CI |
| World server setting keys | the Classic+, Warfront and Transmog keys in the realm's config | Existing realm config files use them; any rename keeps the old keys working |
| Code and config | `openvanilla_*` scripts and modules, `openvanilla-herald` service, `ow-*` CSS ids, `window.openvanilla*`, `OPENVANILLA_*` environment variables, addon saved-variable names, protocol headers | Internal; renaming has no player benefit and would lose saved data |
| Old-install names | the pre-rename launcher, engine and data folder names | Only used to find and migrate older installs |
| Asset files | `assets/openvanilla_logo_*.webp` | File names only; the art already says Open Vanilla |

## Still to do

1. **Socials and Discord:** server name, bot name (Herald stays), channel descriptions, profile
   names and handles. Claim `openvanilla` handles where free before any outreach.
2. **Domain:** register an Open Vanilla domain, serve the site there, and redirect `openvanilla.app`
   permanently (301) so every old link keeps working. Move sign-in redirects and Discord OAuth.
3. **Bridge:** drop the old-named twin exe once launchers from before the rename have updated.

Check before any public post: `grep -rni "openvanilla" www --include=*.html` should only show the
domain, file names, settings keys, code samples, comments and the GitHub account.
