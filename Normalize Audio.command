#!/bin/bash
# Normalize Audio.command — Double-click to run audio normalization on ~/Movies
# Processes any new movies or shows in the local Movies folder
#
# Usage: Double-click in Finder, or: bash ~/Movies/"Normalize Audio.command"
#
# Gotchas:
# - Scripts live in the jellyfin-mac-setup repo; this file just calls them
# - .command files run in Terminal with cwd = user home

set -euo pipefail

MOVIES="$HOME/Movies"
SCRIPTS="$HOME/Documents/Claude Code/Jellyfin Mac/jellyfin-mac-setup/scripts"

# Verify scripts exist
if [ ! -f "$SCRIPTS/normalize-sidecar.py" ]; then
    echo "ERROR: Scripts not found at $SCRIPTS"
    echo "Press any key to close..."
    read -n1
    exit 1
fi

echo "========================================"
echo "  Jellyfin Audio Normalizer"
echo "  Folder: $MOVIES"
echo "========================================"
echo ""

# Step 1: Choose scope
echo "What to process?"
echo "  1) All new files in ~/Movies"
echo "  2) Select a specific folder"
echo ""
read -p "Choice [1]: " SCOPE_CHOICE
SCOPE_CHOICE=${SCOPE_CHOICE:-1}

if [ "$SCOPE_CHOICE" = "2" ]; then
    TARGET=$(osascript -e "set f to POSIX path of (choose folder with prompt \"Select folder to process\" default location POSIX file \"$MOVIES\")" 2>/dev/null)
    if [ -z "$TARGET" ]; then
        echo "Cancelled."
        exit 0
    fi
    TARGET="${TARGET%/}"
    echo "Selected: $TARGET"
else
    TARGET="$MOVIES"
fi

echo ""

# Step 2: Choose mode
echo "Processing mode?"
echo "  1) Compressor only (fast, ~4x faster than full)"
echo "  2) Compressor + Loudnorm (full normalization)"
echo "  3) Loudnorm only (add loudnorm to already-compressed files)"
echo ""
read -p "Choice [1]: " MODE_CHOICE
MODE_CHOICE=${MODE_CHOICE:-1}

echo ""
echo "----------------------------------------"

case "$MODE_CHOICE" in
    1)
        echo "Running: Compressor only on $TARGET"
        echo "----------------------------------------"
        echo ""
        python3 "$SCRIPTS/normalize-sidecar.py" "$TARGET" --compressor-only
        ;;
    2)
        echo "Running: Compressor + Loudnorm on $TARGET"
        echo "----------------------------------------"
        echo ""
        echo "=== Pass 1/2: Compressor ==="
        python3 "$SCRIPTS/normalize-sidecar.py" "$TARGET" --compressor-only
        echo ""
        echo "=== Pass 2/2: Loudnorm ==="
        python3 "$SCRIPTS/loudnorm-sidecar.py" "$TARGET"
        ;;
    3)
        echo "Running: Loudnorm only on $TARGET"
        echo "----------------------------------------"
        echo ""
        python3 "$SCRIPTS/loudnorm-sidecar.py" "$TARGET"
        ;;
    *)
        echo "Invalid choice."
        read -p "Press Enter to close..."
        exit 1
        ;;
esac

echo ""
echo "========================================"
echo "  Missing Subtitles Report"
echo "========================================"
echo ""

MISSING_COUNT=0
while IFS= read -r video; do
    DIR=$(dirname "$video")
    BASE=$(basename "$video")
    NAME="${BASE%.*}"

    HAS_SUB=false
    for ext in srt ass sub ssa vtt; do
        if ls "$DIR/$NAME".*."$ext" "$DIR/$NAME.$ext" 2>/dev/null | grep -q .; then
            HAS_SUB=true
            break
        fi
    done

    if [ "$HAS_SUB" = false ]; then
        if ls "$DIR/"*."srt" "$DIR/"*."ass" "$DIR/"*."sub" 2>/dev/null | grep -q .; then
            HAS_SUB=true
        fi
    fi

    if [ "$HAS_SUB" = false ]; then
        MISSING_COUNT=$((MISSING_COUNT + 1))
        REL="${video#$MOVIES/}"
        echo "  $REL"
    fi
done < <(find "$TARGET" -type f \( -name "*.mkv" -o -name "*.mp4" -o -name "*.avi" -o -name "*.m4v" \) ! -name "._*" 2>/dev/null | sort)

if [ "$MISSING_COUNT" -eq 0 ]; then
    echo "  All videos have subtitles!"
else
    echo ""
    echo "  $MISSING_COUNT videos missing subtitles"
fi

echo ""
echo "========================================"
echo "  Done!"
echo "========================================"
echo ""
read -p "Press Enter to close..."
