#!/data/data/com.termux/files/usr/bin/bash
# Termux:Boot auto-start script.
# Place in ~/.termux/boot/ — runs when the phone boots (requires Termux:Boot from F-Droid).
# Waits for network, then starts Jellyfin.

LOG="$HOME/.jellyfin-launcher.log"
log() { echo "$(date '+%H:%M:%S') [boot] $1" >> "$LOG"; }

log "Boot script triggered"

# Wait for network (up to 60 seconds)
TRIES=0
until ping -c 1 -W 1 127.0.0.1 > /dev/null 2>&1; do
    TRIES=$((TRIES + 1))
    [ $TRIES -ge 30 ] && break
    sleep 2
done

# Small delay for USB drive to mount
sleep 10

log "Starting Jellyfin from boot"
exec ~/termux-jellyfin-start
