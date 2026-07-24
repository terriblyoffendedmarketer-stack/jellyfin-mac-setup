Jellyfin Media Server — Quick Reference
========================================

Login:  pjdruck / 8544
Port:   8096


TERMINAL COMMANDS
-----------------
jf      Show the current Jellyfin URL (to enter on TV)
jfs     Trigger a library scan (after adding new films)
jff     Diagnose and fix issues


DESKTOP SHORTCUTS (double-click)
--------------------------------
Jellyfin URL.command     Show the current URL
Jellyfin Scan.command    Trigger a library scan
Jellyfin Fix.command     Diagnose and fix issues


HOW IT WORKS
------------
- Jellyfin auto-starts on login and scans for new films if the drive is plugged in.
- The server listens on all network interfaces, so any device on the same WiFi can connect.
- Auto-discovery is on — Jellyfin apps on TVs/phones can find the server automatically.


ADDING NEW FILMS
----------------
1. Drop the folder into the right category under /Volumes/Backup Plus/All Movies/
2. Run jfs (or double-click Jellyfin Scan.command)


CONNECTING A NEW TV / DEVICE
-----------------------------
1. Install the Jellyfin app
2. If it doesn't auto-discover, run jf on your Mac to get the address
3. Enter the address, then log in with pjdruck / 8544


COMMON ISSUES
-------------
TV says "connection timed out"
  → Make sure both devices are on the same WiFi network
  → Run jff on your Mac to check everything is working
  → Try again — sometimes the first attempt fails but retrying works

Library looks empty
  → The hard drive probably isn't plugged in or mounted
  → Plug it in, then run jfs

Films missing after adding new ones
  → Run jfs to trigger a scan

Subtitles not showing
  → The .srt file must have the same name as the video file
  → e.g. Movie.2024.720p.mp4 needs Movie.2024.720p.srt (not English.srt)

Wrong metadata on a film
  → Open Jellyfin in browser (localhost:8096), find the film,
    click the three dots menu → Edit metadata → Search to re-identify
