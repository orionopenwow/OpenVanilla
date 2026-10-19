#!/bin/bash
# The only thing GitHub's hotpatch key may run on the realm (installed by dev\Deploy_Key.bat as a
# forced command in root's authorized_keys, copied to /opt/openvanilla-classicplus/gh-deploy.sh so a
# push can't change it). Whatever command the workflow sends is ignored except for one flag:
# --dry-run, --world-restart or --force-web. It updates the realm's checkout to stable and runs the
# hot update (devkit/staging/promote.sh when present, else hetzner/openvanilla_hotpatch.sh).
set -euo pipefail
FLAGS=""
case "${SSH_ORIGINAL_COMMAND:-}" in
  *--dry-run*) FLAGS=--dry-run ;;
  *--world-restart*) FLAGS=--world-restart ;;
  *--force-web*) FLAGS=--force-web ;;
esac
R=/opt/openvanilla-classicplus/repo
export GIT_TERMINAL_PROMPT=0
git -C "$R" remote set-url origin https://github.com/orionopenwow/OpenVanilla
git -C "$R" fetch -q origin +refs/heads/stable:refs/remotes/origin/stable
git -C "$R" reset -q --hard origin/stable
P=$R/devkit/staging/promote.sh
S=$R/hetzner/openvanilla_hotpatch.sh
[ -f "$S" ] || S=/opt/openvanilla-classicplus/openvanilla_hotpatch.sh
if [ -f "$P" ] && [ "$FLAGS" != --world-restart ]; then exec bash "$P" $FLAGS; else exec bash "$S" $FLAGS; fi
