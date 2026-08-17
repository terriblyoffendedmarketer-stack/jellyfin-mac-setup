# Project Instructions

## Git Workflow

When making changes: commit, push, create PR (NOT draft), squash merge it immediately, done. Never leave changes sitting on a feature branch. Never ask the user to merge manually or pull from a feature branch. The full flow is always:

1. Commit
2. Push
3. Create PR as **ready** (not draft)
4. Squash merge it right away
5. Done

## Current State (August 2026)

### Mac Setup — DONE
- Jellyfin installed via Homebrew on Mac (hostname: `jf`, user: `apple`)
- Repo cloned at `~/jellyfin-mac-setup` on Mac
- Shared config migration complete: Jellyfin data/config moved to Seagate drive
- Symlinks confirmed working:
  - `~/Library/Application Support/jellyfin/data` → `/Volumes/Backup Plus/.jellyfin-data`
  - `~/Library/Application Support/jellyfin/config` → `/Volumes/Backup Plus/.jellyfin-config`
- Jellyfin tested and working on Mac with drive data
- Backups at `~/Library/Application Support/jellyfin/data.backup` and `config.backup`
- IMPORTANT: macOS Jellyfin stores data at `~/Library/Application Support/jellyfin/` (NOT `~/.local/share/jellyfin` which is the Linux path)

### Mobile (Termux) Setup — IN PROGRESS
- Phone: Nothing CMF 2 Pro, Android (likely 13 or 14)
- Termux installed from F-Droid, Termux:API installed
- Debian Bookworm (12.15) installed in proot-distro
- Jellyfin 10.11.11 installed inside Debian proot
- Scripts copied to ~/termux-jellyfin-start, ~/termux-jellyfin-control
- Boot auto-start configured

### BLOCKER: USB Drive Not Accessible from Termux
- Seagate Backup Plus connects via USB-C OTG adapter
- Drive is visible in Android file manager and CX Explorer
- Drive mounts at `/mnt/media_rw/6100-18DF/` (volume UUID: 6100-18DF)
- Termux CANNOT access `/mnt/media_rw/` (permission denied) or `/storage/6100-18DF/` (doesn't exist)
- `~/storage/` only shows internal storage (dcim, downloads, movies, music, pictures, shared)
- `termux-usb -l` hangs — no response
- Android's Storage Access Framework blocks direct USB access from Termux on newer Android versions

### Next Steps to Resolve USB Blocker
1. **Try MANAGE_EXTERNAL_STORAGE via ADB** (most likely to work):
   - Enable USB debugging on phone (developer options already enabled)
   - Connect phone to Mac via USB
   - Run: `adb shell appops set --uid com.termux MANAGE_EXTERNAL_STORAGE allow`
   - Then in Termux: `ls /storage/6100-18DF/`
   - If the drive shows up, run `~/termux-jellyfin-start`

2. **Try Settings path** (no ADB needed):
   - Settings > Apps > Special app access > All files access > enable for Termux
   - Or: Settings > Apps > Termux > Permissions > Files and media > Allow all files

3. **If neither works**, the drive detection in `termux-jellyfin-start` needs updating:
   - The `find_drive()` function only checks `~/storage/external-1`, `~/storage/usb`, and `/storage/*`
   - May need to add `/mnt/media_rw/*` if we can get Termux access to it
   - Or fall back to a different architecture (copy config to internal storage)

### ADB Setup on Mac
- User has enabled Developer Options on phone but hasn't set up ADB yet
- Need to: install ADB on Mac (`brew install android-platform-tools`), enable USB debugging on phone, authorize the Mac when prompted on phone

### Library Sync — DONE
- `film-library.html`: browsable/searchable HTML page with all films, works offline on any device
- `film_comments.json`: curated comments for each film (471 films, 10 categories)
- `sync-library.sh`: queries Jellyfin API, exports to `library.json`, regenerates HTML
  - Run manually: `./sync-library.sh --push`
  - Auto-runs after library scan in both `jellyfin-start` (Mac) and `termux-jellyfin-start` (phone)
  - Mac LaunchAgent (`com.jellyfin.librarysync.plist`) syncs every 30 min while Jellyfin is running
  - Script silently exits (exit 0) if Jellyfin is not running — safe for background/cron use
  - Script exports PATH at top to ensure git/python3 are found in LaunchAgent context
  - Does `git pull --rebase` before push to avoid conflicts from other devices
- View the film list anytime at `film-library.html` in the repo (GitHub), no drive/server needed
- When Jellyfin scans new content, the sync script updates the HTML and pushes to GitHub
- LaunchAgent plist includes WorkingDirectory, PATH, and HOME environment variables (required because LaunchAgents run with a bare environment that can't find git/python3 or access keychain)

### After Pulling Changes on Mac
After pulling this repo on the Mac, reload the LaunchAgent:
```bash
cd ~/jellyfin-mac-setup && git pull
launchctl unload ~/Library/LaunchAgents/com.jellyfin.librarysync.plist
cp com.jellyfin.librarysync.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.jellyfin.librarysync.plist
```
Verify it's loaded: `launchctl list | grep jellyfin` — exit code should be `0` (not `1`).
If git push from the LaunchAgent fails, the Mac keychain may need to have the git credential stored. Open Terminal and run `git push` manually once to trigger the keychain prompt — after that, background pushes will work.

### Travel Library — DONE (2026-08-17)
- **Mac:** "Travel" library (movies type) scans `~/Movies` for local content without the hard drive
  - Drop movies/shows into `~/Movies/` — Jellyfin auto-detects and scans
  - Works when hard drive is disconnected (hard-drive libraries show as unavailable, Travel works)
  - TV episodes get misidentified as movies but are still playable
  - For proper TV metadata: structure as `~/Movies/Show Name/Season 01/S01E01.mkv`
  - Duplicates: if same movie on drive + `~/Movies`, shows two entries — use "Merge Versions" or ignore
  - Setup script: `add-travel-library.sh` (already run, idempotent)
- **Phone (Nothing CMF 2 Pro):** separate travel script `mobile/termux-jellyfin-travel`
  - Uses local config at `~/.jellyfin-travel/` (NOT the hard drive config)
  - Scans `~/storage/shared/Movies` (= Android internal storage > Movies, sibling of Downloads)
  - Separate Jellyfin instance — watch history doesn't sync with drive mode
  - Auto-completes setup wizard on first run, same login: pjdruck / 8544
  - Run: `bash ~/termux-jellyfin-travel` (copy script to phone first)

### Architecture
- One Seagate drive = one Jellyfin setup
- Plug into Mac or phone, start Jellyfin, stream to TV or any WiFi device
- Same account (pjdruck), same collections, same watch history
- Drive has: `.jellyfin-data/`, `.jellyfin-config/`, `All Movies/`, `TV/`
- Only one device runs Jellyfin at a time (drive can only be plugged into one)
- Travel mode: `~/Movies` scans locally even without the drive connected

### Key Paths
- Mac Jellyfin data: `~/Library/Application Support/jellyfin/` (symlinked to drive)
- Drive data: `/Volumes/Backup Plus/.jellyfin-data` (Mac mount point)
- Drive data: `/mnt/media_rw/6100-18DF/.jellyfin-data` (Android raw mount)
- Proot mount target: `/Volumes/Backup Plus` (inside Debian, matches Mac path)
- Travel media: `~/Movies` (local Mac storage, no drive needed)
- Server URL: `http://localhost:8096` or `http://192.168.1.51:8096` (Mac static IP)
- Login: pjdruck / 8544
