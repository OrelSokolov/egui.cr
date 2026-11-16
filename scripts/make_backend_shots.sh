#!/bin/sh
# Twinshot legs for the `backends` group: build the target apps under
# one sokol backend, capture every state, restore nothing (the backend
# stamp flips per call — the next leg's build flips it back).
#
#   scripts/make_backend_shots.sh gl|vulkan OUTDIR
#
# Shots land in OUTDIR with identical names on both legs (twinshot
# compares 1:1): notepad-menu-open.png + one PNG per html_gallery
# widget card. Add a state here when a backend bug is spotted.
set -e
cd "$(dirname "$0")/.."
[ $# -eq 2 ] || { echo "usage: $0 gl|vulkan OUTDIR" >&2; exit 2; }
case "$1" in gl|vulkan) ;; *) echo "backend must be gl or vulkan" >&2; exit 2 ;; esac
BACKEND="$1" rake "build:release[notepad,html_gallery]"
python3 scripts/make_notepad_menu_shots.py bin/apps/notepad "$2"
python3 scripts/make_html_widget_shots.py bin/html/html_gallery "$2"
