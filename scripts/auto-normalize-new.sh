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
# Requires: python3, ffmpeg, ffprobe

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

# Check for movies missing subtitles — report only, don't auto-download
echo ""
echo "=== Checking for missing subtitles ==="
MISSING_SUBS=()
MEDIA_EXTENSIONS="mkv mp4 avi m4v mov"
for ext in $MEDIA_EXTENSIONS; do
    while IFS= read -r f; do
        stem=$(basename "${f%.*}")
        fdir=$(dirname "$f")
        # Skip if .srt exists
        ls "$fdir/${stem}"*.srt &>/dev/null 2>&1 && continue
        # Check for embedded subs
        embedded=$(ffprobe -v error -show_entries stream=codec_type -of csv=p=0 "$f" 2>/dev/null | grep -c subtitle || true)
        [ "$embedded" -gt 0 ] && continue
        MISSING_SUBS+=("$(basename "$fdir")/$stem")
    done < <(find "$DRIVE" -name "*.$ext" -not -name "._*" 2>/dev/null)
done
if [ ${#MISSING_SUBS[@]} -gt 0 ]; then
    echo "  *** ${#MISSING_SUBS[@]} movie(s) missing subtitles: ***"
    for m in "${MISSING_SUBS[@]}"; do
        echo "    - $m"
    done
else
    echo "  All movies have subtitles"
fi

# Trigger Jellyfin library scan if not dry run
if [ -z "$DRY_RUN" ]; then
    echo ""
    echo "=== Triggering Jellyfin library scan ==="
    TOKEN=$(curl -s -X POST 'http://localhost:8096/Users/AuthenticateByName' \
        -H 'Content-Type: application/json' \
        -H 'X-Emby-Authorization: MediaBrowser Client="Claude", Device="Mac", DeviceId="claude-code", Version="1.0"' \
        -d '{"Username":"pjdruck","Pw":"8544"}' | python3 -c 'import sys,json; print(json.load(sys.stdin).get("AccessToken",""))' 2>/dev/null)
    if [ -n "$TOKEN" ]; then
        curl -s -X POST "http://localhost:8096/Library/Refresh" \
            -H "X-Emby-Token: $TOKEN" && echo "Library scan triggered" || echo "Scan failed"
    else
        echo "Jellyfin not running or auth failed (not critical)"
    fi
fi

echo ""
echo "=== Done ==="
