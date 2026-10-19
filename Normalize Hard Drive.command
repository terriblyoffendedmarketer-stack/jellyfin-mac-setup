#!/bin/bash
# Normalize Hard Drive.command — Double-click to add normalized-audio sidecars to NEW films/episodes on the hard drive.
# Finds only the items without a sidecar by filename (seconds, even for 1 TB), shows them grouped as Movies / TV,
# flags anything in the wrong folder, then processes just those. Already-processed films are never opened.
#
# Usage: double-click in Finder (a copy lives in ~/Movies next to "Normalize Audio.command"),
#        or: bash ~/Movies/"Normalize Hard Drive.command"
# Requires: the Seagate drive at /Volumes/Backup Plus, ffmpeg/ffprobe, the jellyfin-mac-setup repo scripts below.
#
# Gotchas:
# - The old way (normalize-sidecar.py on "All Movies") ffprobes every file before checking for a sidecar — on the
#   USB drive that meant opening ~550 films. scripts/find-unprocessed.py checks names only, then --files-from.
# - .command files run in Terminal with cwd = home, so all paths are absolute.
# - The confirm prompt must default to NO: a test with piped/empty input once started a real 488-item run.
# - Expected layout: All Movies/<Category>/<Film folder>/ and TV/<Show>/. Elsewhere = Jellyfin can't see it.

set -uo pipefail

DRIVE="/Volumes/Backup Plus"
SCRIPTS="$HOME/Documents/Claude Code/Jellyfin Mac/jellyfin-mac-setup/scripts"
LIST="$(mktemp "${TMPDIR:-/tmp}/jf-todo.XXXXXX")"

pause_exit() { echo ""; read -p "Press Enter to close..."; exit "${1:-0}"; }

if [ ! -f "$SCRIPTS/find-unprocessed.py" ]; then
    echo "ERROR: Scripts not found at $SCRIPTS"; pause_exit 1
fi
if [ ! -d "$DRIVE/All Movies" ]; then
    echo "The hard drive isn't connected (looking for $DRIVE)."
    echo "Plug it in, wait for it to appear in Finder, then double-click this again."
    pause_exit 1
fi

echo "========================================"
echo "  Jellyfin Audio Normalizer — HARD DRIVE"
echo "  Drive: $DRIVE"
echo "========================================"
echo ""
echo "What to look at?"
echo "  1) Movies only (All Movies)"
echo "  2) TV only"
echo "  3) Both"
echo ""
read -p "Choice [1]: " SCOPE_CHOICE || exit 0
case "${SCOPE_CHOICE:-1}" in
    1) ONLY=(--only movies) ;;
    2) ONLY=(--only tv) ;;
    3) ONLY=() ;;
    *) echo "Invalid choice."; pause_exit 1 ;;
esac

echo ""
echo "Processing mode?"
echo "  1) Compressor only (fast)"
echo "  2) Compressor + Loudnorm (full normalization)"
echo "  3) Loudnorm only (add loudnorm to already-compressed items)"
echo ""
read -p "Choice [1]: " MODE_CHOICE || exit 0
MODE_CHOICE=${MODE_CHOICE:-1}
case "$MODE_CHOICE" in
    1|2) FIND_MODE=compressor ;;
    3)   FIND_MODE=loudnorm ;;
    *)   echo "Invalid choice."; pause_exit 1 ;;
esac

echo ""
echo "Looking for items without sidecars (names only, no files opened)..."
echo "----------------------------------------"
python3 "$SCRIPTS/find-unprocessed.py" --drive "$DRIVE" --mode "$FIND_MODE" ${ONLY[@]+"${ONLY[@]}"} --out "$LIST" || pause_exit 1
COUNT=$(grep -c . "$LIST" 2>/dev/null || echo 0)

if [ "$COUNT" -eq 0 ]; then
    echo "Nothing new to process — everything already has its sidecar."
    rm -f "$LIST"; pause_exit 0
fi

# only an explicit y/yes starts work (no input / closed window = cancel, never a silent start)
read -p "Process these $COUNT item(s) now? [y/N]: " GO || GO=n
case "$GO" in [Yy]*) ;; *) echo "Cancelled — nothing changed."; rm -f "$LIST"; pause_exit 0 ;; esac

echo ""
echo "----------------------------------------"
# keep the Mac awake while it works; --all-tracks = one sidecar per language (dual-audio films)
if [ "$MODE_CHOICE" = 1 ] || [ "$MODE_CHOICE" = 2 ]; then
    echo "=== Compressor ==="
    caffeinate -i python3 "$SCRIPTS/normalize-sidecar.py" "$DRIVE" --files-from "$LIST" --compressor-only --all-tracks --workers 4
fi
if [ "$MODE_CHOICE" = 2 ] || [ "$MODE_CHOICE" = 3 ]; then
    echo ""
    echo "=== Loudnorm ==="
    caffeinate -i python3 "$SCRIPTS/loudnorm-sidecar.py" "$DRIVE" --files-from "$LIST" --workers 4
fi
rm -f "$LIST"

# let Jellyfin pick up the new audio tracks (only if it's running)
TOKEN=$(curl -s -m 5 -X POST 'http://localhost:8096/Users/AuthenticateByName' \
    -H 'Content-Type: application/json' \
    -H 'X-Emby-Authorization: MediaBrowser Client="Normalizer", Device="Mac", DeviceId="normalize-drive", Version="1.0"' \
    -d '{"Username":"pjdruck","Pw":"8544"}' 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin).get("AccessToken",""))' 2>/dev/null)
echo ""
if [ -n "$TOKEN" ]; then
    curl -s -m 5 -X POST "http://localhost:8096/Library/Refresh" -H "X-Emby-Token: $TOKEN" >/dev/null && echo "Jellyfin library scan started."
else
    echo "Jellyfin isn't running — the new tracks show up next time it scans."
fi

echo ""
echo "========================================"
echo "  Done!"
echo "========================================"
pause_exit 0
