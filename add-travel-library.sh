#!/bin/bash
# add-travel-library.sh — Adds "Travel" library to Jellyfin for local playback without the hard drive
# Usage: ./add-travel-library.sh
# Requires: Jellyfin running with hard drive connected (config DB lives on the drive)
#
# STATUS: ALREADY RUN (2026-08-17). The Travel library exists. This script is idempotent
#         and can be safely re-run if the library was deleted or needs re-adding.
#
# Gotchas:
# - Must run while hard drive is connected — Jellyfin's config/data DB lives on the drive via symlinks
# - Once the library is added, it persists in the DB — Jellyfin scans ~/Movies even without the drive
# - TV shows in ~/Movies will be misidentified as movies (Jellyfin's movie scanner doesn't understand
#   TV folder structures). They're still playable, just have wrong metadata. For proper TV identification,
#   structure folders as: Show Name/Season 01/S01E01.mkv — but for quick travel viewing, not worth it.
# - Duplicate handling: if a movie exists on both the hard drive and ~/Movies, Jellyfin shows two entries.
#   Use "Merge Versions" in Jellyfin UI to combine them, or just ignore it — when the drive is
#   disconnected, only the ~/Movies copy shows up.

SERVER="http://localhost:8096"
USERNAME="pjdruck"
PASSWORD="8544"
TRAVEL_PATH="$HOME/Movies"

if ! curl -s "$SERVER/System/Info/Public" >/dev/null 2>&1; then
    echo "ERROR: Jellyfin is not running at $SERVER"
    exit 1
fi

if [ ! -d "/Volumes/Backup Plus/.jellyfin-config" ]; then
    echo "ERROR: Hard drive not connected. Jellyfin config lives on the drive."
    echo "Connect the Seagate drive and try again."
    exit 1
fi

echo "Authenticating..."
AUTH_RESPONSE=$(curl -s -X POST "$SERVER/Users/AuthenticateByName" \
    -H "Content-Type: application/json" \
    -H "X-Emby-Authorization: MediaBrowser Client=\"TravelSetup\", Device=\"Mac\", DeviceId=\"travel-setup\", Version=\"1.0\"" \
    -d "{\"Username\":\"$USERNAME\",\"Pw\":\"$PASSWORD\"}")

TOKEN=$(echo "$AUTH_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['AccessToken'])" 2>/dev/null)

if [ -z "$TOKEN" ]; then
    echo "ERROR: Authentication failed"
    echo "$AUTH_RESPONSE"
    exit 1
fi

AUTH_HEADER="MediaBrowser Client=\"TravelSetup\", Device=\"Mac\", DeviceId=\"travel-setup\", Version=\"1.0\", Token=\"$TOKEN\""
echo "Authenticated."

EXISTING=$(curl -s "$SERVER/Library/VirtualFolders" \
    -H "X-Emby-Authorization: $AUTH_HEADER")

if echo "$EXISTING" | python3 -c "import sys,json; libs=json.load(sys.stdin); print(any(l['Name']=='Travel' for l in libs))" 2>/dev/null | grep -q True; then
    echo "Travel library already exists — nothing to do."
else
    echo "Adding Travel library..."
    RESULT=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        "$SERVER/Library/VirtualFolders?name=Travel&collectionType=movies&refreshLibrary=true" \
        -H "Content-Type: application/json" \
        -H "X-Emby-Authorization: $AUTH_HEADER" \
        -d "{\"LibraryOptions\":{\"Enabled\":true,\"EnableRealtimeMonitor\":true,\"PathInfos\":[{\"Path\":\"$TRAVEL_PATH\"}],\"SaveLocalMetadata\":true,\"TypeOptions\":[{\"Type\":\"Movie\",\"MetadataFetchers\":[\"TheMovieDb\",\"The Open Movie Database\"],\"ImageFetchers\":[\"TheMovieDb\",\"The Open Movie Database\",\"Embedded Image Extractor\",\"Screen Grabber\"]}]}}")

    if [ "$RESULT" = "204" ]; then
        echo "Travel library added and scanning."
    else
        echo "Failed (HTTP $RESULT)"
        exit 1
    fi
fi

echo ""
echo "Drop movies and shows into: ~/Movies/"
echo "Jellyfin will auto-detect new files."
