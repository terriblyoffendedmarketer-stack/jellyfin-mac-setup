#!/data/data/com.termux/files/usr/bin/bash
# Monitors for Jellyfin process and manages wake lock while it's alive.
# Equivalent of the Mac's jellyfin-caffeinate.sh LaunchAgent.
# Runs in background — checks every 30 seconds.

LOG="$HOME/.jellyfin-launcher.log"
log() { echo "$(date '+%H:%M:%S') [wakelock] $1" >> "$LOG"; }

WAKE_LOCKED=false

while true; do
    # Check if Jellyfin proot is running
    if pgrep -f "proot.*debian" > /dev/null 2>&1 && curl -s -o /dev/null --max-time 3 http://localhost:8096/web/index.html 2>/dev/null; then
        # Jellyfin is running — ensure wake lock is held
        if [ "$WAKE_LOCKED" = false ]; then
            termux-wake-lock 2>/dev/null
            WAKE_LOCKED=true
            log "Wake lock acquired (Jellyfin detected)"
        fi
    else
        # Jellyfin is not running — release wake lock
        if [ "$WAKE_LOCKED" = true ]; then
            termux-wake-unlock 2>/dev/null
            WAKE_LOCKED=false
            log "Wake lock released (Jellyfin stopped)"
        fi
    fi

    sleep 30
done
