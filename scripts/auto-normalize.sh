#!/bin/bash
# auto-normalize.sh — Check for and normalize new media files on the drive
#
# Designed to run periodically via LaunchAgent. Scans media directories,
# finds files without a "Normalized Stereo" track, and processes them.
# Processes a small batch per run to avoid blocking for hours.
#
# Usage:
#   bash scripts/auto-normalize.sh                    # process up to 5 new files
#   bash scripts/auto-normalize.sh --batch-size 20    # process up to 20
#   bash scripts/auto-normalize.sh --all              # process everything (long!)
#
# Requires: ffmpeg, ffprobe, python3

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

DRIVE="/Volumes/Backup Plus"
MOVIE_DIR="$DRIVE/All Movies"
TV_DIR="$DRIVE/TV"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NORMALIZE_SCRIPT="$SCRIPT_DIR/normalize-audio.py"
LOG="$HOME/.jellyfin-normalize.log"
BATCH_SIZE=5

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG"; }

# Parse args
for arg in "$@"; do
    case "$arg" in
        --all) BATCH_SIZE=0 ;;
        --batch-size)
            shift_next=true ;;
        *)
            if [ "$shift_next" = true ]; then
                BATCH_SIZE="$arg"
                shift_next=false
            fi ;;
    esac
done

# Check drive is connected
if [ ! -d "$DRIVE" ]; then
    exit 0
fi

# Check media directories exist
DIRS_TO_SCAN=""
[ -d "$MOVIE_DIR" ] && DIRS_TO_SCAN="$MOVIE_DIR"
[ -d "$TV_DIR" ] && DIRS_TO_SCAN="$DIRS_TO_SCAN $TV_DIR"

if [ -z "$DIRS_TO_SCAN" ]; then
    exit 0
fi

log "=== Auto-normalize check ==="

# Find files that need processing by checking for the Normalized track
# This is faster than running the full Python script for scanning
NEEDS_PROCESSING=()

for dir in $DIRS_TO_SCAN; do
    while IFS= read -r -d '' file; do
        # Quick check: does ffprobe show a "Normalized Stereo" track?
        if ! ffprobe -v quiet -show_streams -print_format json "$file" 2>/dev/null | \
             python3 -c "
import sys, json
data = json.load(sys.stdin)
for s in data.get('streams', []):
    if s.get('codec_type') == 'audio' and 'normalized stereo' in s.get('tags', {}).get('title', '').lower():
        sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
            NEEDS_PROCESSING+=("$file")
        fi

        # Stop scanning if we have enough for this batch
        if [ "$BATCH_SIZE" -gt 0 ] && [ ${#NEEDS_PROCESSING[@]} -ge "$BATCH_SIZE" ]; then
            break 2
        fi
    done < <(find "$dir" -type f \( -name "*.mkv" -o -name "*.mp4" -o -name "*.avi" -o -name "*.m4v" \) -print0 2>/dev/null)
done

COUNT=${#NEEDS_PROCESSING[@]}

if [ "$COUNT" -eq 0 ]; then
    log "All files already have normalized tracks"
    exit 0
fi

log "Found $COUNT file(s) to normalize (batch size: ${BATCH_SIZE:-unlimited})"

# Process each file
DONE=0
ERRORS=0

for file in "${NEEDS_PROCESSING[@]}"; do
    BASENAME=$(basename "$file")
    log "Processing: $BASENAME"

    OUTPUT=$(python3 "$NORMALIZE_SCRIPT" "$file" 2>&1)
    EXIT_CODE=$?

    if echo "$OUTPUT" | grep -q "^Processed: *[1-9]"; then
        log "  Done: $BASENAME"
        DONE=$((DONE + 1))
    elif echo "$OUTPUT" | grep -q "Already normalized"; then
        log "  Already done: $BASENAME"
    else
        log "  Error: $BASENAME"
        echo "$OUTPUT" >> "$LOG"
        ERRORS=$((ERRORS + 1))
    fi
done

log "Batch complete: $DONE processed, $ERRORS errors"

# Trigger a Jellyfin library scan if we processed anything
if [ "$DONE" -gt 0 ]; then
    if curl -sf "http://localhost:8096/System/Ping" > /dev/null 2>&1; then
        TOKEN=$(curl -sf http://localhost:8096/Users/authenticatebyname \
            -H "Content-Type: application/json" \
            -H "X-Emby-Authorization: MediaBrowser Client=\"AutoNorm\", Device=\"Mac\", DeviceId=\"autonorm\", Version=\"1.0\"" \
            -d '{"Username":"pjdruck","Pw":"8544"}' 2>/dev/null | \
            python3 -c "import sys,json; print(json.load(sys.stdin)['AccessToken'])" 2>/dev/null)

        if [ -n "$TOKEN" ]; then
            curl -sf -X POST "http://localhost:8096/Library/Refresh" \
                -H "X-Emby-Token: $TOKEN" > /dev/null 2>&1
            log "Triggered Jellyfin library scan"
        fi
    fi
fi
