#!/usr/bin/env bash
# Open Vanilla launcher on macOS and Linux, from this folder (Windows: Play Open Vanilla.bat).
#   bash play-open-vanilla.sh          (macOS: double-click "Play Open Vanilla.command")
#   bash play-open-vanilla.sh debug    show what the launcher prints
# First run: finds Python 3.10+ with Tk, and puts Pillow (the launcher's image library) in a private
# environment under your user folder if the system doesn't have it. Nothing is installed system-wide.
set -u
cd "$(dirname "$0")" || exit 1
say() { printf '%s\n' "$*"; }

if [ "$(uname -s)" = Darwin ]; then STATE="$HOME/Library/Application Support/OpenVanilla"
else STATE="${XDG_DATA_HOME:-$HOME/.local/share}/OpenVanilla"; fi
VENV="$STATE/python"

ok_py() { "$1" -c 'import sys, tkinter; sys.exit(sys.version_info < (3, 10))' >/dev/null 2>&1; }
PY=""
for c in "$VENV/bin/python3" python3.13 python3.12 python3.11 python3.10 python3 \
         /opt/homebrew/bin/python3 /usr/local/bin/python3 /Library/Frameworks/Python.framework/Versions/Current/bin/python3; do
  p=$(command -v "$c" 2>/dev/null || true); [ -n "$p" ] || { [ -x "$c" ] && p="$c"; }
  if [ -n "$p" ] && ok_py "$p"; then PY="$p"; break; fi
done
if [ -z "$PY" ]; then
  say ""
  say "  Open Vanilla runs from this folder with Python 3.10 or newer, with Tk (its window toolkit)."
  if [ "$(uname -s)" = Darwin ]; then
    say "  Install it from https://www.python.org/downloads/macos/ (Tk included),"
    say "  or with Homebrew: brew install python python-tk"
  else
    say "  Install it with your package manager, for example:"
    say "    Ubuntu/Debian: sudo apt install python3 python3-tk python3-venv"
    say "    Fedora:        sudo dnf install python3 python3-tkinter"
    say "    Arch:          sudo pacman -S python tk"
  fi
  say "  Then run this again. (Or play in the browser: https://play.openvanilla.app)"
  exit 1
fi

if ! "$PY" -c 'import PIL.ImageTk' >/dev/null 2>&1; then
  say "First run: setting up Pillow, the launcher's image library (a few seconds)..."
  if [ ! -x "$VENV/bin/python3" ]; then
    mkdir -p "$STATE"
    "$PY" -m venv --system-site-packages "$VENV" >/dev/null 2>&1 || true
  fi
  if [ -x "$VENV/bin/python3" ]; then
    "$VENV/bin/python3" -m pip install --quiet --disable-pip-version-check pillow && PY="$VENV/bin/python3"
  else  # no venv module (Debian without python3-venv): the user's own site-packages
    "$PY" -m pip install --user --quiet --disable-pip-version-check pillow >/dev/null 2>&1 \
      || say "  Couldn't install Pillow. Ubuntu/Debian: sudo apt install python3-pil python3-pil.imagetk (or python3-venv)."
  fi
  "$PY" -c 'import PIL.ImageTk' >/dev/null 2>&1 || { say "  Pillow is still missing; see above."; exit 1; }
fi

if [ "${1:-}" = debug ]; then
  shift; "$PY" launcher/openvanilla_launcher.py "$@"; say "The launcher closed (exit code $?)."; exit 0
fi
nohup "$PY" launcher/openvanilla_launcher.py "$@" >/dev/null 2>&1 &
