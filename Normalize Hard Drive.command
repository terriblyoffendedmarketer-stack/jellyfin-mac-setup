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
# - Re-downloaded film with the same name as a deleted one: its old sidecar is older than the new video, so the
#   finder lists it as "re-downloaded" and --force replaces the sidecar. Option 4 forces any folder by hand.
# - Cut-short sidecars (an interrupted run used to keep partial audio): answer y to the audit question; it reads each
#   film's length from its header and confirms suspects by counting audio frames, then they're redone.
# - No confirm prompt after the list (user: it left the window waiting after a long find). So TEST THIS FILE ONLY ON A
#   FAKE DRIVE COPY (DRIVE= replaced) — a piped test once started a real 488-item run.
# - Edit ~/Movies/<this file> only by replacing it (cp to temp + mv): bash reads a running script as it goes, so
#   editing it in place while a window runs it can make that run execute garbage.
# - 12 Angry Men (1957) always fails: its audio is damaged from 39:57 on (decoder stops even with ignore_err).
# - Expected layout: All Movies/<Category>/<Film folder>/ and TV/<Show>/. Elsewhere = Jellyfin can't see it.

set -uo pipefail

DRIVE="/Volumes/Backup Plus"
SCRIPTS="$HOME/Documents/Claude Code/Jellyfin Mac/jellyfin-mac-setup/scripts"
LIST="$(mktemp "${TMPDIR:-/tmp}/jf-todo.XXXXXX")"

pause_exit() { echo ""; read -p "Press Enter to close..."; exit "${1:-0}"; }

if [ ! -f "$SCRIPTS/find-unprocessed.py" ]; then
    echo "ERROR: Scripts not found at $SCRIPTS"; pause_exit 1
fi
# one run at a time: two runs on the same films would fight over the same temp files
if pgrep -f "normalize-sidecar.py|loudnorm-sidecar.py" >/dev/null; then
    echo "A normalizer run is already going (another window, or a background run)."
    echo "Let it finish first — check progress with:  tail -5 \"$DRIVE/normalize-sidecar.log\""
    pause_exit 1
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
echo "  4) Redo a specific film or folder (even if it already has a sidecar)"
echo ""
read -p "Choice [1]: " SCOPE_CHOICE || exit 0
case "${SCOPE_CHOICE:-1}" in
    1) ONLY=(--only movies) ;;
    2) ONLY=(--only tv) ;;
    3) ONLY=() ;;
    4) PICK=$(osascript -e "POSIX path of (choose folder with prompt \"Pick the film (or show/season) folder to redo\" default location POSIX file \"$DRIVE/All Movies\")" 2>/dev/null)
       [ -z "$PICK" ] && { echo "Cancelled."; pause_exit 0; }
       ONLY=(--force-path "${PICK%/}"); echo "Selected: ${PICK%/}" ;;
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

AUDIT=()
if [ "${SCOPE_CHOICE:-1}" != 4 ] && [ "$FIND_MODE" = compressor ]; then
    echo ""
    read -p "Also check existing sidecars for cut-short ones? Adds ~4 min. [y/N]: " AUD || AUD=n
    case "$AUD" in [Yy]*) AUDIT=(--audit) ;; esac
fi

echo ""
echo "Looking for items without sidecars (names only, no files opened)..."
echo "----------------------------------------"
python3 "$SCRIPTS/find-unprocessed.py" --drive "$DRIVE" --mode "$FIND_MODE" ${ONLY[@]+"${ONLY[@]}"} ${AUDIT[@]+"${AUDIT[@]}"} --out "$LIST" || pause_exit 1
COUNT=$(grep -c . "$LIST" 2>/dev/null || echo 0)

if [ "$COUNT" -eq 0 ]; then
    echo "Nothing new to process — everything already has its sidecar."
    rm -f "$LIST"; pause_exit 0
fi

# no "process now?" question: finding takes minutes, so a prompt here meant coming back to an idle window
echo "Starting on these $COUNT item(s) now. (Close this window to stop; re-run later to pick up where it left off.)"

echo ""
echo "----------------------------------------"
# keep the Mac awake while it works; --all-tracks = one sidecar per language (dual-audio films)
# --force: the finder already decided these need (re)doing — incl. re-downloads whose old sidecar matches by name
if [ "$MODE_CHOICE" = 1 ] || [ "$MODE_CHOICE" = 2 ]; then
    echo "=== Compressor ==="
    caffeinate -i python3 "$SCRIPTS/normalize-sidecar.py" "$DRIVE" --files-from "$LIST" --compressor-only --all-tracks --workers 4 --force
fi
if [ "$MODE_CHOICE" = 2 ] || [ "$MODE_CHOICE" = 3 ]; then
    echo ""
    echo "=== Loudnorm ==="
    caffeinate -i python3 "$SCRIPTS/loudnorm-sidecar.py" "$DRIVE" --files-from "$LIST" --workers 4 --force
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
