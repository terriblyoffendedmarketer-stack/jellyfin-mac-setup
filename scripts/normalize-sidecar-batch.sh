#!/bin/bash
# normalize-sidecar-batch.sh — Process movie folders in order with sidecar approach
# Creates normalized stereo .aac files next to each movie (4 parallel workers)
# Order: Movies in General → Anime movies → Asian Movies
# Skips files that already have embedded normalized tracks or existing sidecars
# Pass --compressor-only for fast mode (no loudnorm), or omit for full processing

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export PYTHONUNBUFFERED=1

DRIVE="/Volumes/Backup Plus/All Movies"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NORMALIZE="$SCRIPT_DIR/normalize-sidecar.py"
WORKERS=4
EXTRA_FLAGS="$@"

if [ ! -d "$DRIVE" ]; then
    echo "Error: Drive not connected"
    exit 1
fi

echo "========================================"
echo "SIDECAR BATCH — Started: $(date)"
echo "Workers: $WORKERS parallel"
echo "Flags: $EXTRA_FLAGS"
echo "========================================"

for FOLDER in "Movies in General" "Anime movies" "Asian Movies"; do
    echo ""
    echo "========================================"
    echo ">>> FOLDER: $FOLDER — Started: $(date)"
    echo "========================================"
    python3 "$NORMALIZE" "$DRIVE" --folder "$FOLDER" --workers "$WORKERS" $EXTRA_FLAGS
    echo "========================================"
    echo "<<< FOLDER: $FOLDER — DONE: $(date)"
    echo "========================================"
done

# Jellyfin library scan
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
