#!/bin/bash
# auto-normalize-new.sh — Auto-process new movies when hard drive connects
# Scans for movies without compressor sidecars and creates them.
# Intended to be run manually after adding new movies, or via LaunchAgent.
#
# Usage:
#   bash scripts/auto-normalize-new.sh              # process new movies
#   bash scripts/auto-normalize-new.sh --dry-run    # preview only
#   bash scripts/auto-normalize-new.sh --with-loudnorm  # also create ldnrm sidecars
#
# Requires: python3, ffmpeg

DRIVE="/Volumes/Backup Plus/All Movies"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NORMALIZE="$SCRIPT_DIR/normalize-sidecar.py"
LOUDNORM="$SCRIPT_DIR/loudnorm-sidecar.py"

if [ ! -d "$DRIVE" ]; then
    echo "Drive not mounted at $DRIVE — exiting."
    exit 0
fi

DRY_RUN=""
WITH_LOUDNORM=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN="--dry-run" ;;
        --with-loudnorm) WITH_LOUDNORM=true ;;
    esac
done

echo "=== Auto-normalize new movies ==="
echo "Drive: $DRIVE"
echo "Time: $(date)"
echo ""

# Run compressor on all tracks (skips files that already have sidecars)
caffeinate -i python3 "$NORMALIZE" "$DRIVE" \
    --compressor-only --all-tracks --workers 4 $DRY_RUN

if [ "$WITH_LOUDNORM" = true ]; then
    echo ""
    echo "=== Creating loudnorm sidecars ==="
    caffeinate -i python3 "$LOUDNORM" "$DRIVE" \
        --workers 4 $DRY_RUN
fi

# Trigger Jellyfin library scan if not dry run
if [ -z "$DRY_RUN" ]; then
    echo ""
    echo "=== Triggering Jellyfin library scan ==="
    curl -s -X POST "http://localhost:8096/Library/Refresh" \
        -H "X-Emby-Token: $(curl -s -X POST 'http://localhost:8096/Users/AuthenticateByName' \
            -H 'Content-Type: application/json' \
            -d '{"Username":"pjdruck","Pw":"8544"}' | python3 -c 'import sys,json; print(json.load(sys.stdin).get("AccessToken",""))')" \
        && echo "Library scan triggered" || echo "Jellyfin not running or scan failed (not critical)"
fi

echo ""
echo "=== Done ==="
