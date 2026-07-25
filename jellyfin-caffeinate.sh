#!/bin/bash
# Monitors for Jellyfin Server process and keeps caffeinate running while it's alive.
# Also runs the drive-disconnect watchdog.

DRIVE="/Volumes/Backup Plus"
LOG="$HOME/.jellyfin-launcher.log"
log() { echo "$(date '+%H:%M:%S') [agent] $1" >> "$LOG"; }

while true; do
    JF_PID=$(pgrep -f "Jellyfin Server" | head -1)

    if [ -n "$JF_PID" ]; then
        # Jellyfin is running — start caffeinate if not already going
        if ! pgrep -f "caffeinate.*-w.*$JF_PID" > /dev/null 2>&1; then
            pkill -f "caffeinate -s -m -i -w" 2>/dev/null
            caffeinate -s -m -i -w "$JF_PID" &
            log "caffeinate started for Jellyfin PID $JF_PID"
        fi

        # Start watchdog if not already running and drive is connected
        if [ -d "$DRIVE" ] && ! pgrep -f "jellyfin-watchdog" > /dev/null 2>&1; then
            (
                exec -a "jellyfin-watchdog" bash -c '
                DRIVE="'"$DRIVE"'"
                LOG="'"$LOG"'"
                log() { echo "$(date "+%H:%M:%S") [watchdog] $1" >> "$LOG"; }
                sleep 30
                while true; do
                    sleep 60
                    if ! pgrep -f "Jellyfin Server" > /dev/null 2>&1; then
                        log "Jellyfin stopped — watchdog exiting"
                        break
                    fi
                    if [ ! -d "$DRIVE" ]; then
                        log "Drive disconnected — shutting down Jellyfin"
                        osascript -e "display notification \"Drive disconnected — shutting down\" with title \"Jellyfin\"" 2>/dev/null
                        TOKEN=$(curl -s --max-time 5 -X POST http://localhost:8096/Users/AuthenticateByName \
                            -H "Content-Type: application/json" \
                            -H "X-Emby-Authorization: MediaBrowser Client=\"Watchdog\", Device=\"Mac\", DeviceId=\"wd1\", Version=\"1.0\"" \
                            -d "{\"Username\": \"pjdruck\", \"Pw\": \"8544\"}" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)[\"AccessToken\"])" 2>/dev/null)
                        if [ -n "$TOKEN" ]; then
                            curl -s --max-time 5 -X POST http://localhost:8096/System/Shutdown -H "X-Emby-Token: $TOKEN" 2>/dev/null
                        fi
                        sleep 5
                        pkill -f "Jellyfin Server" 2>/dev/null
                        osascript -e "tell application \"Jellyfin Server\" to quit" 2>/dev/null
                        osascript -e "tell application \"Jellyfin\" to quit" 2>/dev/null
                        log "Jellyfin shut down (drive disconnected)"
                        break
                    fi
                done
                '
            ) &
            log "watchdog started"
        fi
    fi

    sleep 30
done
