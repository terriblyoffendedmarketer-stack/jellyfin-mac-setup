#!/bin/bash
# find-subtitles.sh — Search for subtitles matching a movie file by release markers
#
# Uses OpenSubtitles REST API and SubDL API to find subtitle files that match
# the exact release (YTS.MX, x264, x265, BluRay, etc). Does NOT auto-download.
# Prints matches ranked by relevance so you can pick the right one.
#
# Usage:
#   bash scripts/find-subtitles.sh "Movie.2020.1080p.BluRay.x264-YTS.MX.mp4"
#   bash scripts/find-subtitles.sh ~/Movies/Tenet*/Tenet*.mp4
#   bash scripts/find-subtitles.sh --setup    # save API keys
#
# Setup (one-time):
#   1. OpenSubtitles: register free at https://www.opensubtitles.com
#      → Profile → API Consumers → create key (free: 20 downloads/day)
#   2. SubDL: register free at https://subdl.com
#      → Account settings → get API key (free: search + download)
#   3. Run: bash scripts/find-subtitles.sh --setup
#
# Gotchas:
# - OpenSubtitles hash matching is most reliable but needs exact file
# - Release-name matching (YTS, FGT, RARBG etc) gives best sync results
# - subliminal was unreliable — wrong releases, PAL/NTSC framerate mismatch
# - This script FINDS subtitles and gives you links — you download manually
# - Free OpenSubtitles: 5 downloads/day without account, 20 with account

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KEYS_FILE="$SCRIPT_DIR/../.subtitle-api-keys"

# --- Setup ---
if [ "$1" = "--setup" ]; then
    echo "=== Subtitle API Key Setup ==="
    echo ""
    echo "1. OpenSubtitles (https://www.opensubtitles.com)"
    echo "   Register → Profile → API Consumers → Create key"
    read -p "   API Key (or Enter to skip): " OS_KEY
    echo ""
    echo "2. SubDL (https://subdl.com)"
    echo "   Register → Account settings → API key"
    read -p "   API Key (or Enter to skip): " SD_KEY
    echo ""

    cat > "$KEYS_FILE" << KEYEOF
OPENSUBTITLES_API_KEY="${OS_KEY}"
SUBDL_API_KEY="${SD_KEY}"
KEYEOF
    chmod 600 "$KEYS_FILE"
    echo "Saved to $KEYS_FILE"
    exit 0
fi

# Load keys
if [ -f "$KEYS_FILE" ]; then
    source "$KEYS_FILE"
fi

if [ -z "$OPENSUBTITLES_API_KEY" ] && [ -z "$SUBDL_API_KEY" ]; then
    echo "No API keys configured. Run: bash $0 --setup"
    echo ""
    echo "Or set environment variables:"
    echo "  export OPENSUBTITLES_API_KEY=your_key"
    echo "  export SUBDL_API_KEY=your_key"
    exit 1
fi

# --- Parse input ---
FILEPATH="$1"
if [ -z "$FILEPATH" ]; then
    echo "Usage: $0 <movie-file> [--lang en]"
    exit 1
fi

# Resolve globs
if [[ "$FILEPATH" == *"*"* ]]; then
    FILEPATH=$(ls $FILEPATH 2>/dev/null | head -1)
fi

if [ ! -f "$FILEPATH" ]; then
    echo "File not found: $FILEPATH"
    exit 1
fi

FILENAME=$(basename "$FILEPATH")
STEM="${FILENAME%.*}"
LANG="${2:-en}"

echo "=== Finding subtitles for: $FILENAME ==="
echo ""

# Extract release markers for matching
extract_markers() {
    local name="$1"
    # Common release markers
    echo "$name" | grep -oiE '(YTS\.MX|YIFY|RARBG|FGT|EVO|SPARKS|GECKOS|ETRG|GalaxyRG|PSA|QxR|GAZ|ION10|JYK|BRSRKR|MkvCage|Tigole|x264|x265|XviD|HEVC|BluRay|BrRip|WEB-DL|WEBRip|HDRip|DVDRip|BDRip|720p|1080p|2160p|4K|AAC|AAC5\.1|DTS|DTS-HD|AC3|FLAC|5\.1|7\.1|10bit)' | sort -u | tr '\n' ' '
}

MARKERS=$(extract_markers "$STEM")
echo "Release markers: $MARKERS"
echo ""

# --- OpenSubtitles API ---
search_opensubtitles() {
    [ -z "$OPENSUBTITLES_API_KEY" ] && return

    echo "--- OpenSubtitles ---"

    # Compute file hash (OpenSubtitles hash = filesize + 64-bit checksum of first/last 64KB)
    local hash
    hash=$(python3 -c "
import struct, os
def compute_hash(path):
    longlongformat = '<q'
    bytesize = struct.calcsize(longlongformat)
    f = open(path, 'rb')
    filesize = os.path.getsize(path)
    hash = filesize
    if filesize < 65536 * 2:
        return None
    for x in range(65536 // bytesize):
        buffer = f.read(bytesize)
        (l_value,) = struct.unpack(longlongformat, buffer)
        hash += l_value
        hash = hash & 0xFFFFFFFFFFFFFFFF
    f.seek(max(0, filesize - 65536), 0)
    for x in range(65536 // bytesize):
        buffer = f.read(bytesize)
        (l_value,) = struct.unpack(longlongformat, buffer)
        hash += l_value
        hash = hash & 0xFFFFFFFFFFFFFFFF
    f.close()
    return '%016x' % hash
print(compute_hash('$FILEPATH') or '')
" 2>/dev/null)

    # Search by hash first (most accurate)
    if [ -n "$hash" ]; then
        echo "  Hash: $hash"
        local result
        result=$(curl -s "https://api.opensubtitles.com/api/v1/subtitles?moviehash=$hash&languages=$LANG" \
            -H "Api-Key: $OPENSUBTITLES_API_KEY" \
            -H "User-Agent: JellyfinSubFinder v1.0" 2>/dev/null)

        local count
        count=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('total_count',0))" 2>/dev/null)

        if [ "$count" -gt 0 ] 2>/dev/null; then
            echo "  Found $count hash match(es):"
            echo "$result" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for sub in d.get('data', [])[:10]:
    attr = sub.get('attributes', {})
    release = attr.get('release', 'unknown')
    dl_count = attr.get('download_count', 0)
    fps = attr.get('fps', '')
    files = attr.get('files', [])
    file_id = files[0]['file_id'] if files else 'N/A'
    print(f'    [{dl_count} DLs] {release}  (file_id: {file_id}, fps: {fps})')
" 2>/dev/null
            return
        fi
    fi

    # Fall back to query search
    local query
    query=$(echo "$STEM" | sed -E 's/[._]/ /g' | sed -E 's/ (19|20)([0-9]{2}) .*/\1\2/')
    echo "  No hash match, searching by name: $query"

    local result
    result=$(curl -s "https://api.opensubtitles.com/api/v1/subtitles?query=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$query'))")&languages=$LANG" \
        -H "Api-Key: $OPENSUBTITLES_API_KEY" \
        -H "User-Agent: JellyfinSubFinder v1.0" 2>/dev/null)

    echo "$result" | python3 -c "
import sys, json
d = json.load(sys.stdin)
total = d.get('total_count', 0)
print(f'  Found {total} result(s):')
for sub in d.get('data', [])[:10]:
    attr = sub.get('attributes', {})
    release = attr.get('release', 'unknown')
    dl_count = attr.get('download_count', 0)
    fps = attr.get('fps', '')
    files = attr.get('files', [])
    file_id = files[0]['file_id'] if files else 'N/A'
    print(f'    [{dl_count} DLs] {release}  (file_id: {file_id}, fps: {fps})')
" 2>/dev/null
}

# --- SubDL API ---
search_subdl() {
    [ -z "$SUBDL_API_KEY" ] && return

    echo ""
    echo "--- SubDL ---"

    # Search by file_name (release-aware matching)
    local result
    result=$(curl -s "https://api.subdl.com/api/v1/subtitles?api_key=$SUBDL_API_KEY&file_name=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$STEM'))")&languages=en&type=movie&subs_per_page=10" 2>/dev/null)

    local status
    status=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status', False))" 2>/dev/null)

    if [ "$status" = "True" ]; then
        echo "$result" | python3 -c "
import sys, json
d = json.load(sys.stdin)
subs = d.get('subtitles', [])
print(f'  Found {len(subs)} result(s):')
for sub in subs:
    name = sub.get('release_name', sub.get('name', 'unknown'))
    author = sub.get('author', '')
    lang = sub.get('language', '')
    url = sub.get('url', '')
    dl_link = 'https://dl.subdl.com' + url if url else 'N/A'
    print(f'    {name}')
    print(f'      by {author} | {lang} | {dl_link}')
" 2>/dev/null
    else
        # Try by film name only
        local movie_name
        movie_name=$(echo "$STEM" | sed -E 's/[._]/ /g' | sed -E 's/ (19|20)([0-9]{2}) .*//')
        local year
        year=$(echo "$STEM" | grep -oE '(19|20)[0-9]{2}' | head -1)

        echo "  File search returned no results, trying by title: $movie_name ($year)"
        result=$(curl -s "https://api.subdl.com/api/v1/subtitles?api_key=$SUBDL_API_KEY&film_name=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$movie_name'))")&year=$year&languages=en&type=movie&subs_per_page=10" 2>/dev/null)

        echo "$result" | python3 -c "
import sys, json
d = json.load(sys.stdin)
subs = d.get('subtitles', [])
print(f'  Found {len(subs)} result(s):')
for sub in subs:
    name = sub.get('release_name', sub.get('name', 'unknown'))
    author = sub.get('author', '')
    url = sub.get('url', '')
    dl_link = 'https://dl.subdl.com' + url if url else 'N/A'
    print(f'    {name}')
    print(f'      by {author} | {dl_link}')
" 2>/dev/null
    fi
}

search_opensubtitles
search_subdl

echo ""
echo "=== Done ==="
echo ""
echo "To download from OpenSubtitles, use the file_id with the download endpoint:"
echo "  curl -X POST https://api.opensubtitles.com/api/v1/download \\"
echo "    -H 'Api-Key: \$OPENSUBTITLES_API_KEY' -H 'Content-Type: application/json' \\"
echo "    -d '{\"file_id\": FILE_ID}'"
echo ""
echo "SubDL links can be downloaded directly with curl/wget."
