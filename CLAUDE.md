# Project Instructions

## Git Workflow

When making changes: commit, push, create PR (NOT draft), squash merge it immediately, done. Never leave changes sitting on a feature branch. Never ask the user to merge manually or pull from a feature branch. The full flow is always:

1. Commit
2. Push
3. Create PR as **ready** (not draft)
4. Squash merge it right away
5. Done

## Current State (July 2026)

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

### Architecture
- One Seagate drive = one Jellyfin setup
- Plug into Mac or phone, start Jellyfin, stream to TV or any WiFi device
- Same account (pjdruck), same collections, same watch history
- Drive has: `.jellyfin-data/`, `.jellyfin-config/`, `All Movies/`, `TV/`
- Only one device runs Jellyfin at a time (drive can only be plugged into one)

### Key Paths
- Mac Jellyfin data: `~/Library/Application Support/jellyfin/` (symlinked to drive)
- Drive data: `/Volumes/Backup Plus/.jellyfin-data` (Mac mount point)
- Drive data: `/mnt/media_rw/6100-18DF/.jellyfin-data` (Android raw mount)
- Proot mount target: `/Volumes/Backup Plus` (inside Debian, matches Mac path)
- Server URL: `http://localhost:8096` or `http://192.168.1.51:8096` (Mac static IP)
- Login: pjdruck / 8544
