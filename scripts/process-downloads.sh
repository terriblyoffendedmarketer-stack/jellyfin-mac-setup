#!/bin/bash
# process-downloads.sh — Process downloaded movies: create sidecars, move to target
#
# Default: creates compressor + loudnorm sidecars, moves to ~/Movies (Travel library)
# With --drive: moves to /Volumes/Backup Plus/All Movies/Movies in General/ instead
#
# Usage:
#   bash scripts/process-downloads.sh "Movie File.mkv"           # process + move to ~/Movies
#   bash scripts/process-downloads.sh "Movie File.mkv" --drive   # process + move to drive
#   bash scripts/process-downloads.sh "Movie Folder/"            # process folder + move
#   bash scripts/process-downloads.sh --all                      # process all video files in ~/Downloads
#   bash scripts/process-downloads.sh --dry-run "Movie File.mkv" # preview only
#
# Requires: ffmpeg, ffprobe (brew install ffmpeg), subliminal (in venv)
#
# Gotchas:
# - Use filter_complex with [0:a:N]...[norm] -map [norm], NOT -af (fails on surround)
# - mp4 files still downloading have no moov atom — ffprobe returns error, script skips them
# - Tenet-style folders with brackets in names need quoting — script handles this
# - ExFAT drive creates ._* resource forks — ignored during scan
# - subliminal needs a venv on macOS (PEP 668 blocks --user installs)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOWNLOADS="$HOME/Downloads"
LOCAL_TARGET="$HOME/Movies"
DRIVE_TARGET="/Volumes/Backup Plus/All Movies/Movies in General"
MEDIA_EXTENSIONS="mkv mp4 avi m4v mov ts wmv"

# Filter chains (must match normalize-sidecar.py)
COMPRESSOR="acompressor=threshold=0.089:ratio=4:attack=5:release=100:makeup=5:knee=6"
LOUDNORM="loudnorm=I=-16:TP=-1.5:LRA=11"
PAN_51="pan=stereo|FL=1.0*FC+0.707*FL+0.5*BL+0.25*LFE|FR=1.0*FC+0.707*FR+0.5*BR+0.25*LFE"
PAN_71="pan=stereo|FL=1.0*FC+0.707*FL+0.5*BL+0.5*SL+0.25*LFE|FR=1.0*FC+0.707*FR+0.5*BR+0.5*SR+0.25*LFE"

# Parse args
USE_DRIVE=false
DRY_RUN=false
PROCESS_ALL=false
TARGETS=()

for arg in "$@"; do
    case "$arg" in
        --drive) USE_DRIVE=true ;;
        --dry-run) DRY_RUN=true ;;
        --all) PROCESS_ALL=true ;;
        *) TARGETS+=("$arg") ;;
    esac
done

if [ "$USE_DRIVE" = true ]; then
    DEST="$DRIVE_TARGET"
    if [ ! -d "$DEST" ]; then
        echo "ERROR: Drive not mounted at $DRIVE_TARGET"
        exit 1
    fi
else
    DEST="$LOCAL_TARGET"
    mkdir -p "$DEST"
fi

echo "=== Process Downloads ==="
echo "Target: $DEST"
echo "Time: $(date)"
echo ""

find_video_files() {
    local dir="$1"
    for ext in $MEDIA_EXTENSIONS; do
        find "$dir" -maxdepth 2 -name "*.$ext" -not -name "._*" 2>/dev/null
    done
}

get_lang_code() {
    local lang3="$1"
    case "$lang3" in
        eng|en) echo "en" ;;
        jpn|ja) echo "ja" ;;
        hin|hi) echo "hi" ;;
        zho|zh|cmn) echo "zh" ;;
        kor|ko) echo "ko" ;;
        mal|ml) echo "ml" ;;
        spa|es) echo "es" ;;
        fra|fre|fr) echo "fr" ;;
        deu|ger|de) echo "de" ;;
        und|"") echo "en" ;;
        *) echo "${lang3:0:2}" ;;
    esac
}

fetch_subtitles_for_file() {
    local filepath="$1"
    local dry_flag=""
    [ "$DRY_RUN" = true ] && dry_flag="--dry-run"
    bash "$SCRIPT_DIR/fetch-subtitles.sh" "$filepath" $dry_flag
}

process_file() {
    local filepath="$1"
    local filename
    filename=$(basename "$filepath")

    echo "--- Processing: $filename ---"

    # Probe audio
    local probe
    probe=$(ffprobe -v quiet -print_format json -show_streams "$filepath" 2>&1) || {
        echo "  SKIP: Cannot probe (file may still be downloading)"
        return 1
    }

    # Find first non-commentary audio stream
    local stream_info
    stream_info=$(echo "$probe" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for s in data.get('streams', []):
    if s.get('codec_type') != 'audio':
        continue
    title = (s.get('tags', {}).get('title', '') or '').lower()
    if 'commentary' in title:
        continue
    idx = s['index']
    ch = s.get('channels', 0)
    layout = s.get('channel_layout', '')
    lang = s.get('tags', {}).get('language', 'und')
    # audio stream index within audio streams only
    audio_idx = sum(1 for x in data['streams'][:idx] if x.get('codec_type') == 'audio')
    print(f'{audio_idx}|{ch}|{layout}|{lang}')
    break
" 2>/dev/null)

    if [ -z "$stream_info" ]; then
        echo "  SKIP: No usable audio stream found"
        return 1
    fi

    local audio_idx ch layout lang lang2
    IFS='|' read -r audio_idx ch layout lang <<< "$stream_info"
    lang2=$(get_lang_code "$lang")

    echo "  Audio: ${ch}ch ($layout), lang=$lang2, stream=a:$audio_idx"

    # Build filter chain
    local pan=""
    if [ "$ch" -ge 8 ] || [[ "$layout" == *"7.1"* ]]; then
        pan="$PAN_71"
        echo "  Downmix: 7.1 → stereo"
    elif [ "$ch" -ge 6 ] || [[ "$layout" == *"5.1"* ]]; then
        pan="$PAN_51"
        echo "  Downmix: 5.1 → stereo"
    fi

    local stem="${filename%.*}"
    local filedir
    filedir=$(dirname "$filepath")

    # Compressor sidecar
    local comp_name="${stem}.Normalized Stereo.${lang2}.aac"
    local comp_path="${filedir}/${comp_name}"
    local comp_filter=""
    if [ -n "$pan" ]; then
        comp_filter="${pan},${COMPRESSOR}"
    else
        comp_filter="${COMPRESSOR}"
    fi

    if [ -f "$comp_path" ] && [ -s "$comp_path" ]; then
        echo "  Compressor sidecar already exists, skipping"
    elif [ "$DRY_RUN" = true ]; then
        echo "  [DRY RUN] Would create: $comp_name"
    else
        echo "  Creating compressor sidecar..."
        caffeinate -i ffmpeg -y -hide_banner -loglevel warning \
            -i "$filepath" \
            -filter_complex "[0:a:${audio_idx}]${comp_filter}[norm]" \
            -map '[norm]' \
            -c:a aac -b:a 192k -ac 2 -ar 48000 \
            -metadata title="Normalized Stereo" \
            -metadata language="$lang" \
            "$comp_path"

        if [ -s "$comp_path" ]; then
            echo "  OK: $(du -h "$comp_path" | cut -f1) — $comp_name"
        else
            echo "  ERROR: Compressor sidecar is empty, removing"
            rm -f "$comp_path"
            return 1
        fi
    fi

    # Loudnorm sidecar
    local ldnrm_name="${stem}.ldnrm Stereo.${lang2}.aac"
    local ldnrm_path="${filedir}/${ldnrm_name}"
    local ldnrm_filter=""
    if [ -n "$pan" ]; then
        ldnrm_filter="${pan},${COMPRESSOR},${LOUDNORM}"
    else
        ldnrm_filter="${COMPRESSOR},${LOUDNORM}"
    fi

    if [ -f "$ldnrm_path" ] && [ -s "$ldnrm_path" ]; then
        echo "  Loudnorm sidecar already exists, skipping"
    elif [ "$DRY_RUN" = true ]; then
        echo "  [DRY RUN] Would create: $ldnrm_name"
    else
        echo "  Creating loudnorm sidecar..."
        caffeinate -i ffmpeg -y -hide_banner -loglevel warning \
            -i "$filepath" \
            -filter_complex "[0:a:${audio_idx}]${ldnrm_filter}[norm]" \
            -map '[norm]' \
            -c:a aac -b:a 192k -ac 2 -ar 48000 \
            -metadata title="ldnrm Stereo" \
            -metadata language="$lang" \
            "$ldnrm_path"

        if [ -s "$ldnrm_path" ]; then
            echo "  OK: $(du -h "$ldnrm_path" | cut -f1) — $ldnrm_name"
        else
            echo "  ERROR: Loudnorm sidecar is empty, removing"
            rm -f "$ldnrm_path"
        fi
    fi

    # Download subtitles (isolated — never affects sidecar success)
    fetch_subtitles_for_file "$filepath" || true
}

guess_movie_folder_name() {
    local filename="$1"
    local stem="${filename%.*}"
    # Try to extract "Movie Name (Year)" from common naming patterns
    # Pattern: Movie.Name.2020.1080p... or Movie.Name.2020.BluRay...
    local name_year
    name_year=$(echo "$stem" | sed -E 's/[._]/ /g' | sed -E 's/ (19|20)([0-9]{2}) .*//' | sed -E 's/^ +| +$//')
    local year
    year=$(echo "$stem" | grep -oE '(19|20)[0-9]{2}' | head -1)
    if [ -n "$name_year" ] && [ -n "$year" ]; then
        echo "${name_year} (${year})"
    else
        echo "$stem"
    fi
}

move_to_target() {
    local filepath="$1"
    local filename
    filename=$(basename "$filepath")
    local stem="${filename%.*}"
    local filedir
    filedir=$(dirname "$filepath")

    # Check if file is inside a subfolder of Downloads (like Tenet's folder)
    local parent
    parent=$(basename "$filedir")
    local is_subfolder=false
    if [ "$filedir" != "$DOWNLOADS" ]; then
        is_subfolder=true
    fi

    # Determine the target folder name — always "Movie Name (Year)" format
    local folder_name
    if [ "$is_subfolder" = true ]; then
        # Already in a folder — check if it looks like "Name (Year)"
        if echo "$parent" | grep -qE '\([0-9]{4}\)'; then
            folder_name="$parent"
        else
            folder_name=$(guess_movie_folder_name "$filename")
        fi
    else
        folder_name=$(guess_movie_folder_name "$filename")
    fi

    local dest_folder="$DEST/$folder_name"

    if [ "$DRY_RUN" = true ]; then
        echo "  [DRY RUN] Would move $filename + sidecars to $dest_folder/"
        return
    fi

    mkdir -p "$dest_folder"

    if [ "$is_subfolder" = true ]; then
        # Move all files from source folder into the target folder
        echo "  Moving contents: $parent/ → $folder_name/"
        for f in "$filedir"/*; do
            [ -e "$f" ] && mv "$f" "$dest_folder/" 2>/dev/null || true
        done
        rmdir "$filedir" 2>/dev/null || true
    else
        # Move individual files (movie + sidecars + subtitles)
        echo "  Moving: $filename + sidecars → $folder_name/"
        mv "$filedir/$filename" "$dest_folder/" 2>/dev/null || true
        for sidecar in "$filedir/${stem}".*.aac "$filedir/${stem}".*.srt; do
            [ -f "$sidecar" ] && mv "$sidecar" "$dest_folder/" 2>/dev/null || true
        done
    fi

    echo "  Moved to $dest_folder/"
}

# Collect files to process
FILES=()
if [ "$PROCESS_ALL" = true ]; then
    while IFS= read -r f; do
        FILES+=("$f")
    done < <(find_video_files "$DOWNLOADS")
elif [ ${#TARGETS[@]} -gt 0 ]; then
    for target in "${TARGETS[@]}"; do
        # Resolve relative to Downloads if not absolute
        if [[ "$target" != /* ]]; then
            target="$DOWNLOADS/$target"
        fi
        # Strip trailing slash
        target="${target%/}"

        if [ -d "$target" ]; then
            while IFS= read -r f; do
                FILES+=("$f")
            done < <(find_video_files "$target")
        elif [ -f "$target" ]; then
            FILES+=("$target")
        else
            echo "WARNING: Not found: $target"
        fi
    done
else
    echo "Usage: $0 <file-or-folder> [--drive] [--dry-run]"
    echo "       $0 --all [--drive] [--dry-run]"
    exit 1
fi

if [ ${#FILES[@]} -eq 0 ]; then
    echo "No video files found to process."
    exit 0
fi

echo "Found ${#FILES[@]} file(s) to process"
echo ""

ERRORS=0
for filepath in "${FILES[@]}"; do
    if process_file "$filepath"; then
        move_to_target "$filepath"
    else
        ((ERRORS++))
    fi
    echo ""
done

# Trigger Jellyfin library scan
if [ "$DRY_RUN" != true ]; then
    echo "=== Triggering Jellyfin library scan ==="
    TOKEN=$(curl -s -X POST 'http://localhost:8096/Users/AuthenticateByName' \
        -H 'Content-Type: application/json' \
        -H 'X-Emby-Authorization: MediaBrowser Client="Claude", Device="Mac", DeviceId="claude-code", Version="1.0"' \
        -d '{"Username":"pjdruck","Pw":"8544"}' 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin).get("AccessToken",""))' 2>/dev/null)
    if [ -n "$TOKEN" ]; then
        curl -s -X POST "http://localhost:8096/Library/Refresh" \
            -H "X-Emby-Token: $TOKEN" && echo "Library scan triggered" || echo "Scan request failed"
    else
        echo "Jellyfin not running or auth failed (not critical)"
    fi
fi

echo ""
echo "=== Done ($ERRORS errors) ==="
