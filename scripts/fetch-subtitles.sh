#!/bin/bash
# fetch-subtitles.sh — Download English subtitles for movies missing them
# Scans a directory for video files, downloads .srt via subliminal, checks sync.
# Designed to be called standalone or from other scripts (process-downloads.sh, auto-normalize-new.sh).
# Subtitle failures never return non-zero — safe to call without || true.
#
# Usage:
#   bash scripts/fetch-subtitles.sh "/path/to/movies"         # process all videos in dir
#   bash scripts/fetch-subtitles.sh "/path/to/movie.mkv"      # single file
#   bash scripts/fetch-subtitles.sh "/path/to/movies" --dry-run
#
# Requires: ffprobe, python3, alass-cli (brew install alass)
#   subliminal installed automatically in venv
#
# Gotchas:
# - subliminal needs a venv on macOS (PEP 668 blocks pip install --user)
# - Hash-based matching gives best sync; name-matching is fallback and less reliable
# - alass does dynamic subtitle sync — handles framerate mismatch (PAL 25fps vs NTSC 23.976fps)
#   and non-linear drift, unlike ffsubsync which only does constant offset
# - sync_subs.py wraps alass + applies technical fixes (gaps, reading speed, max duration)
# - Sync check compares last subtitle timestamp to movie duration — flags obvious mismatches
# - Never fails the caller — all errors are warnings only

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SUBLIMINAL_VENV="$SCRIPT_DIR/../.venv-subliminal"
SYNC_SUBS="$SCRIPT_DIR/sync_subs.py"
MEDIA_EXTENSIONS="mkv mp4 avi m4v mov ts wmv"

DRY_RUN=false
for arg in "$@"; do
    [ "$arg" = "--dry-run" ] && DRY_RUN=true
done

ensure_subliminal() {
    if [ -x "$SUBLIMINAL_VENV/bin/subliminal" ]; then
        return 0
    fi
    echo "  Setting up subliminal venv..."
    if python3 -m venv "$SUBLIMINAL_VENV" 2>/dev/null && \
       "$SUBLIMINAL_VENV/bin/pip" install -q subliminal 2>&1 | tail -1; then
        return 0
    else
        echo "  WARNING: Could not set up subliminal"
        return 1
    fi
}

auto_sync_subtitle() {
    local srt_file="$1"
    local video_file="$2"

    if [ ! -f "$SYNC_SUBS" ]; then
        echo "    sync_subs.py not found at $SYNC_SUBS, skipping auto-sync"
        return 0
    fi
    if ! command -v alass-cli &>/dev/null && [ ! -x /opt/homebrew/bin/alass-cli ]; then
        echo "    alass-cli not found, skipping auto-sync (brew install alass)"
        return 0
    fi

    local synced_file="${srt_file%.srt}.synced.srt"
    local output
    output=$(python3 "$SYNC_SUBS" "$video_file" "$srt_file" "$synced_file" 2>&1)

    if [ -f "$synced_file" ] && [ -s "$synced_file" ]; then
        mv "$synced_file" "$srt_file"
        echo "    Auto-synced with alass (dynamic sync + technical fixes)"
        return 0
    else
        rm -f "$synced_file"
        echo "    alass sync failed, keeping original"
    fi
    return 0
}

check_subtitle_sync() {
    local srt_file="$1"
    local video_file="$2"

    local movie_duration
    movie_duration=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$video_file" 2>/dev/null | cut -d. -f1)
    [ -z "$movie_duration" ] && return 0

    local last_ts
    last_ts=$(grep -E '^[0-9]{2}:[0-9]{2}:[0-9]{2}' "$srt_file" | tail -1 | sed 's/ .*//' | head -1)
    [ -z "$last_ts" ] && return 0

    local hrs mins secs
    hrs=$(echo "$last_ts" | cut -d: -f1 | sed 's/^0//')
    mins=$(echo "$last_ts" | cut -d: -f2 | sed 's/^0//')
    secs=$(echo "$last_ts" | cut -d: -f3 | cut -d, -f1 | sed 's/^0//')
    local sub_end=$(( (hrs * 3600) + (mins * 60) + secs ))

    local diff=$(( movie_duration - sub_end ))

    if [ "$diff" -lt -60 ]; then
        echo "  SYNC WARNING: Subtitles extend ${diff#-}s past movie end — likely wrong release"
        return 1
    elif [ "$diff" -gt 1800 ]; then
        echo "  SYNC WARNING: Subtitles end ${diff}s ($(( diff / 60 ))min) before movie ends — possibly truncated"
        return 1
    else
        echo "  Sync OK (subs end ${diff}s before credits)"
        return 0
    fi
}

fetch_for_file() {
    local filepath="$1"
    local filename
    filename=$(basename "$filepath")
    local stem="${filename%.*}"
    local filedir
    filedir=$(dirname "$filepath")

    # Skip resource forks
    [[ "$filename" == ._* ]] && return 0

    # Check if external .srt already exists
    if ls "$filedir/${stem}"*.srt &>/dev/null; then
        return 0
    fi

    # Check for embedded subtitles
    local has_embedded
    has_embedded=$(ffprobe -v error -show_entries stream=codec_type -of csv=p=0 "$filepath" 2>/dev/null | grep -c subtitle || true)

    echo "  $filename"
    if [ "$has_embedded" -gt 0 ]; then
        echo "    Embedded: $has_embedded track(s)"
    fi

    if [ "$DRY_RUN" = true ]; then
        echo "    [DRY RUN] Would download English subtitles"
        return 0
    fi

    local result
    result=$("$SUBLIMINAL_VENV/bin/subliminal" download -l en "$filepath" 2>&1)
    if echo "$result" | grep -q "Downloaded 1"; then
        local srt_file
        srt_file=$(ls "$filedir/${stem}"*.srt 2>/dev/null | head -1)
        if [ -n "$srt_file" ]; then
            echo "    Downloaded: $(basename "$srt_file")"
            auto_sync_subtitle "$srt_file" "$filepath"
            if ! check_subtitle_sync "$srt_file" "$filepath"; then
                echo "    Keeping anyway — verify during playback"
            fi
        fi
    elif [ "$has_embedded" -gt 0 ]; then
        echo "    No external found (embedded available)"
    else
        echo "    WARNING: No subtitles found anywhere"
    fi
}

# --- Main ---

TARGET=""
for arg in "$@"; do
    [ "$arg" = "--dry-run" ] && continue
    TARGET="$arg"
done

if [ -z "$TARGET" ]; then
    echo "Usage: $0 <file-or-directory> [--dry-run]"
    exit 0
fi

if ! ensure_subliminal; then
    echo "Subtitle download skipped (subliminal unavailable)"
    exit 0
fi

echo "=== Fetching subtitles ==="

if [ -f "$TARGET" ]; then
    fetch_for_file "$TARGET"
elif [ -d "$TARGET" ]; then
    FOUND=0
    DOWNLOADED=0
    for ext in $MEDIA_EXTENSIONS; do
        while IFS= read -r f; do
            stem=$(basename "${f%.*}")
            filedir=$(dirname "$f")
            # Skip if .srt already exists
            if ls "$filedir/${stem}"*.srt &>/dev/null 2>&1; then
                continue
            fi
            ((FOUND++))
            fetch_for_file "$f"
        done < <(find "$TARGET" -name "*.$ext" -not -name "._*" 2>/dev/null)
    done
    if [ "$FOUND" -eq 0 ]; then
        echo "  All movies already have subtitles"
    fi
else
    echo "Not found: $TARGET"
fi

echo "=== Subtitles done ==="
