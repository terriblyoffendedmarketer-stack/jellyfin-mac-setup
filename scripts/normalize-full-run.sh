#!/bin/bash
# normalize-full-run.sh — Process all movies: surround first, then bad stereo files
#
# Phase 1: Process all surround (5.1/7.1) files (--skip-stereo)
# Phase 2: Process ALL remaining stereo files (no --skip-stereo)
#          The script's compressor helps any file with wide dynamic range.
#          Files already normalized get skipped automatically.
# Phase 3: Trigger Jellyfin library scan
#
# Usage:
#   nohup caffeinate -s bash scripts/normalize-full-run.sh > /tmp/normalize-full.log 2>&1 &

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export PYTHONUNBUFFERED=1

DRIVE="/Volumes/Backup Plus"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NORMALIZE="$SCRIPT_DIR/normalize-audio.py"

if [ ! -d "$DRIVE" ]; then
    echo "Error: Drive not connected at $DRIVE"
    exit 1
fi

echo "=== PHASE 1: Surround files (5.1/7.1) ==="
echo "Started: $(date)"
python3 "$NORMALIZE" "$DRIVE/All Movies" --skip-stereo
echo "Phase 1 done: $(date)"

echo ""
echo "=== PHASE 2: Stereo files with compression ==="
echo "Started: $(date)"
python3 "$NORMALIZE" "$DRIVE/All Movies"
echo "Phase 2 done: $(date)"

echo ""
echo "=== PHASE 3: Jellyfin library scan ==="
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
    echo "Jellyfin not running — scan manually when ready"
fi

echo ""
echo "=== ALL DONE ==="
echo "Finished: $(date)"
