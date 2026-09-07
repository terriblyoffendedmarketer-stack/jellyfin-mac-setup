#!/bin/bash
# configure-jellyfin-audio.sh — Set Jellyfin playback settings for better dialogue
#
# Configures:
# 1. User profile: prefer stereo downmix (fallback when no normalized track exists)
# 2. User profile: enable audio normalization
# 3. Shows current audio settings for verification
#
# Usage: bash scripts/configure-jellyfin-audio.sh
#
# Requires: Jellyfin running at localhost:8096
#
# Gotchas:
# - Jellyfin's "MaxAudioChannels" in user config forces server-side downmix
#   to stereo for content without a stereo track. This triggers transcoding
#   which uses CPU, but it's the best fallback when no normalized track exists.
# - These settings apply per-user, not server-wide.

JELLYFIN_URL="${JELLYFIN_URL:-http://localhost:8096}"
JELLYFIN_USER="${JELLYFIN_USER:-pjdruck}"
JELLYFIN_PASS="${JELLYFIN_PASS:-8544}"

log() { echo "$(date '+%H:%M:%S') $1"; }

# Check Jellyfin is running
if ! curl -sf "$JELLYFIN_URL/System/Ping" > /dev/null 2>&1; then
    echo "Error: Jellyfin is not running at $JELLYFIN_URL"
    echo "Start Jellyfin first, then run this script."
    exit 1
fi

# Authenticate
log "Authenticating..."
AUTH_RESPONSE=$(curl -sf "$JELLYFIN_URL/Users/authenticatebyname" \
    -H "Content-Type: application/json" \
    -H "X-Emby-Authorization: MediaBrowser Client=\"AudioConfig\", Device=\"Mac\", DeviceId=\"audio-config\", Version=\"1.0\"" \
    -d "{\"Username\":\"$JELLYFIN_USER\",\"Pw\":\"$JELLYFIN_PASS\"}" 2>/dev/null)

if [ -z "$AUTH_RESPONSE" ]; then
    echo "Error: Failed to authenticate"
    exit 1
fi

USER_ID=$(echo "$AUTH_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['User']['Id'])" 2>/dev/null)
TOKEN=$(echo "$AUTH_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['AccessToken'])" 2>/dev/null)

log "Authenticated as $JELLYFIN_USER (ID: $USER_ID)"

# Get current user configuration
log "Fetching current user config..."
USER_CONFIG=$(curl -sf "$JELLYFIN_URL/Users/$USER_ID" \
    -H "X-Emby-Token: $TOKEN" 2>/dev/null)

if [ -z "$USER_CONFIG" ]; then
    echo "Error: Could not fetch user config"
    exit 1
fi

# Update user configuration for better audio
log "Updating audio playback settings..."
UPDATED_CONFIG=$(echo "$USER_CONFIG" | python3 << 'PYEOF'
import json, sys

config = json.load(sys.stdin)

# Access the Configuration object within the user
cfg = config.get("Configuration", {})

# Enable audio normalization during playback
cfg["EnableAudioNormalization"] = True

# Set max audio channels to stereo (2) — forces downmix when transcoding
# This is the fallback for files without a normalized track
cfg["MaxAudioChannels"] = "2"

# Prefer the default audio track (which we set in the file)
cfg["PlayDefaultAudioTrack"] = True

# Enable next-up auto play
cfg["EnableNextEpisodeAutoPlay"] = True

config["Configuration"] = cfg
print(json.dumps(config))
PYEOF
)

# Apply the updated config
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "$JELLYFIN_URL/Users/$USER_ID/Configuration" \
    -H "Content-Type: application/json" \
    -H "X-Emby-Token: $TOKEN" \
    -d "$(echo "$UPDATED_CONFIG" | python3 -c 'import sys,json; print(json.dumps(json.load(sys.stdin).get("Configuration",{})))')" 2>/dev/null)

if [ "$HTTP_CODE" = "204" ] || [ "$HTTP_CODE" = "200" ]; then
    log "Audio settings updated successfully"
else
    log "Warning: Settings update returned HTTP $HTTP_CODE (may still have worked)"
fi

# Verify
log ""
log "=== Current Audio Settings ==="
echo "$UPDATED_CONFIG" | python3 << 'PYEOF'
import json, sys
config = json.load(sys.stdin).get("Configuration", {})
print(f"  Audio Normalization:  {config.get('EnableAudioNormalization', 'not set')}")
print(f"  Max Audio Channels:   {config.get('MaxAudioChannels', 'not set')}")
print(f"  Play Default Track:   {config.get('PlayDefaultAudioTrack', 'not set')}")
PYEOF

log ""
log "=== What these settings do ==="
echo "  1. Audio Normalization: ON — Jellyfin normalizes volume across content"
echo "  2. Max Audio Channels: 2 (Stereo) — forces downmix to stereo when"
echo "     transcoding, so surround content gets mixed to stereo automatically."
echo "     This is the FALLBACK for files that don't have a Normalized track."
echo "  3. Play Default Track: ON — plays the first/default audio track"
echo ""
echo "  For best results, use the normalize-audio.py script to add proper"
echo "  Normalized Stereo tracks to your files. The Jellyfin settings above"
echo "  provide immediate relief but the script gives much better dialogue"
echo "  clarity because it boosts the centre (dialogue) channel specifically."
