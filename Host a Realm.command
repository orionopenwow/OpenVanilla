#!/bin/bash
# macOS: double-click to host an Open Vanilla realm on this Mac (Docker). Linux: bash host/ovhost install
cd "$(dirname "$0")" || exit 1
bash host/ovhost install "$@"
echo
read -r -p "Press Enter to close this window." _
