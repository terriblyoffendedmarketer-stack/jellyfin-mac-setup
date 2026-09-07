#!/bin/bash
# normalize-all.sh — Process all media on the drive for audio normalization
#
# Runs normalize-audio.py on All Movies, then TV, then triggers a Jellyfin scan.
# Use caffeinate to keep Mac awake during the long run.
#
# Usage:
#   bash scripts/normalize-all.sh                  # surround files only (recommended first)
#   bash scripts/normalize-all.sh --all            # all files including stereo
#
# To run in background:
#   nohup bash scripts/normalize-all.sh > /tmp/normalize-all.log 2>&1 &

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export PYTHONUNBUFFERED=1

DRIVE="/Volumes/Backup Plus"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NORMALIZE="$SCRIPT_DIR/normalize-audio.py"

EXTRA_ARGS="--skip-stereo"
if [ "$1" = "--all" ]; then
    EXTRA_ARGS=""
    echo "Mode: processing ALL files (surround + stereo)"
else
    echo "Mode: surround files only (use --all for everything)"
fi

if [ ! -d "$DRIVE" ]; then
    echo "Error: Drive not connected at $DRIVE"
    exit 1
fi

echo ""
echo "=== Processing All Movies ==="
python3 "$NORMALIZE" "$DRIVE/All Movies" $EXTRA_ARGS

echo ""
echo "=== Processing TV Shows ==="
python3 "$NORMALIZE" "$DRIVE/TV" $EXTRA_ARGS

echo ""
echo "=== Triggering Jellyfin library scan ==="
if curl -sf "http://localhost:8096/System/Ping" > /dev/null 2>&1; then
    TOKEN=$(curl -sf http://localhost:8096/Users/authenticatebyname \
        -H "Content-Type: application/json" \
        -H "X-Emby-Authorization: MediaBrowser Client=\"Normalize\", Device=\"Mac\", DeviceId=\"norm\", Version=\"1.0\"" \
        -d '{"Username":"pjdruck","Pw":"8544"}' 2>/dev/null | \
        python3 -c "import sys,json; print(json.load(sys.stdin)['AccessToken'])" 2>/dev/null)

    if [ -n "$TOKEN" ]; then
        curl -sf -X POST "http://localhost:8096/Library/Refresh" \
            -H "X-Emby-Token: $TOKEN" > /dev/null 2>&1
        echo "Library scan triggered"
    fi
else
    echo "Jellyfin not running — scan the library manually after starting it"
fi

echo ""
echo "=== All done ==="
