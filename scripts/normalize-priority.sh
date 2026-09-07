#!/bin/bash
# normalize-priority.sh — Process movies in priority order
# Phase 1: Surround files in each folder
# Phase 2: All remaining files (stereo with bad dynamic range)
# Posts completion markers to log between folders

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export PYTHONUNBUFFERED=1

DRIVE="/Volumes/Backup Plus/All Movies"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NORMALIZE="$SCRIPT_DIR/normalize-audio.py"

if [ ! -d "$DRIVE" ]; then
    echo "Error: Drive not connected"
    exit 1
fi

echo "========================================"
echo "PRIORITY BATCH — Started: $(date)"
echo "========================================"

# Phase 1: Surround files per folder
for FOLDER in "Movies in General" "Anime movies" "Asian Movies"; do
    echo ""
    echo "========================================"
    echo ">>> FOLDER: $FOLDER (surround) — Started: $(date)"
    echo "========================================"
    python3 "$NORMALIZE" "$DRIVE/$FOLDER" --skip-stereo
    echo "========================================"
    echo "<<< FOLDER: $FOLDER — DONE: $(date)"
    echo "========================================"
done

# Phase 2: Stereo files — only process those with bad LRA (full audio scan)
for FOLDER in "Movies in General" "Anime movies" "Asian Movies"; do
    echo ""
    echo "========================================"
    echo ">>> FOLDER: $FOLDER (stereo, LRA check) — Started: $(date)"
    echo "========================================"
    python3 "$NORMALIZE" "$DRIVE/$FOLDER" --lra-check
    echo "========================================"
    echo "<<< FOLDER: $FOLDER (stereo, LRA check) — DONE: $(date)"
    echo "========================================"
done

# Phase 3: Remaining small folders (surround + stereo)
for FOLDER in "Tarantino" "Wes Anderson" "Indian Films" "Hong Sang Soo Films" "Andrei Tarkovsky" "The Apu Trilogy"; do
    echo ""
    echo ">>> FOLDER: $FOLDER — Started: $(date)"
    python3 "$NORMALIZE" "$DRIVE/$FOLDER"
    echo "<<< FOLDER: $FOLDER — DONE: $(date)"
done

# Jellyfin scan
echo ""
echo "=== Triggering Jellyfin library scan ==="
if curl -sf "http://localhost:8096/System/Ping" > /dev/null 2>&1; then
    TOKEN=$(curl -sf http://localhost:8096/Users/authenticatebyname \
        -H "Content-Type: application/json" \
        -H "X-Emby-Authorization: MediaBrowser Client=\"Normalize\", Device=\"Mac\", DeviceId=\"norm\", Version=\"1.0\"" \
        -d '{"Username":"pjdruck","Pw":"8544"}' 2>/dev/null | \
        python3 -c "import sys,json; print(json.load(sys.stdin)['AccessToken'])" 2>/dev/null)
    if [ -n "$TOKEN" ]; then
        curl -sf -X POST "http://localhost:8096/Library/Refresh" -H "X-Emby-Token: $TOKEN" > /dev/null 2>&1
        echo "Library scan triggered"
    fi
else
    echo "Jellyfin not running — scan manually"
fi

echo ""
echo "========================================"
echo "ALL DONE — Finished: $(date)"
echo "========================================"
