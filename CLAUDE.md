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
  - Mac LaunchAgent (`com.jellyfin.librarysync.plist`) syncs every 5 min while Jellyfin is running
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

### Calendar Auto-Swap — NEEDS SETUP
- When new films are added to Jellyfin, sync-library.sh detects them and calls a Google Apps Script webhook
- The Apps Script swaps new films into upcoming calendar slots (1-2 this week, rest peppered over next 2-3 weeks)
- Displaced films get moved to the end of the calendar
- Setup: paste `calendar-swap.gs` into script.google.com, deploy as web app, save URL to `.calendar-swap-url`
- `.library-prev.json` tracks the previous library state for diff detection (seeded, gitignored)

### Audio Normalization — DONE (2026-09-07)
- **Problem:** surround audio (5.1/7.1) has huge dynamic range — dialogue whispered, explosions deafening
- **Solution:** Sidecar `.aac` files next to each movie. Jellyfin auto-detects them as extra audio tracks.
- **Layer 1 (compressor) — DONE:** 506 `.Normalized Stereo.{lang}.aac` sidecars across all folders
  - `scripts/normalize-sidecar.py` — main script, supports `--all-tracks`, `--compressor-only`, `--skip-stereo`
  - Run: `python3 scripts/normalize-sidecar.py "/Volumes/Backup Plus/All Movies" --compressor-only`
  - 9 dual-audio movies have sidecars in both languages (en+ja, en+hi, en+zh, en+ml)
- **Layer 2 (loudnorm) — ON DEMAND:** `.ldnrm Stereo.{lang}.aac` sidecars for consistent volume
  - `scripts/loudnorm-sidecar.py` — reads compressor sidecars, creates separate ldnrm files
  - Run per movie: `python3 scripts/loudnorm-sidecar.py "/Volumes/Backup Plus/All Movies/Movies in General/MovieName"`
  - Run all: `python3 scripts/loudnorm-sidecar.py "/Volumes/Backup Plus/All Movies" --workers 4`
- **Sidecar naming:** `Movie.Normalized Stereo.en.aac` (compressor), `Movie.ldnrm Stereo.en.aac` (loudnorm)
- **Process downloads → local:** `scripts/process-downloads.sh` — creates both sidecars, moves to `~/Movies` in a "Movie Name (Year)" folder, flags missing subtitles
  - Run: `bash scripts/process-downloads.sh "Movie File.mkv"` or `--all` for everything in Downloads
  - Add `--drive` to move to hard drive instead of ~/Movies
  - Add `--dry-run` to preview without processing
  - Subtitles: reports missing subs, does NOT auto-download (automated sync is unreliable across releases)
- **Find subtitles:** `scripts/find-subtitles.sh` — searches OpenSubtitles + SubDL APIs by file hash and release markers
  - Run: `bash scripts/find-subtitles.sh "Movie.2020.1080p.BluRay.x264-YTS.MX.mp4"`
  - Setup: `bash scripts/find-subtitles.sh --setup` (one-time, saves API keys to `.subtitle-api-keys`)
  - Finds matching subs, prints download links — you pick and download manually
- **Auto-process on drive:** `scripts/auto-normalize-new.sh` (also on drive at `.jellyfin-scripts/`)
  - Run: `bash "/Volumes/Backup Plus/.jellyfin-scripts/auto-normalize-new.sh"`
  - Add `--with-loudnorm` to also create ldnrm sidecars
- **New items on the drive — double-click `Normalize Hard Drive.command`** (repo root; copy in `~/Movies`, 2026-10-19)
  - Asks Movies / TV / both + mode, runs `scripts/find-unprocessed.py` (filename check only — seconds for the whole drive),
    shows new items by category / show, flags files in the wrong place, then processes ONLY those via `--files-from`.
  - Why: `normalize-sidecar.py` on a folder ffprobes every file before checking for a sidecar (= opening ~1,400 files).
  - State 2026-10-19: 17 films + 467 TV episodes had no sidecar (TV was never processed apart from ReLIFE), and
    17 sidecars were CUT SHORT (old bug: failed ffmpeg output kept if > 100 KB — fixed; 4 were from an interrupted test).
  - No confirm step: lists, then starts at once; refuses to start if a normalizer run is already going.
  - 12 Angry Men (1957) source audio is damaged from 39:57 — needs a new copy; always fails until replaced.
  - Re-downloads: video newer than its sidecar = redo (`--force`). Option 4 = redo any folder by hand. Optional audit
    (`--audit`) finds cut-short sidecars: size estimate, then exact AAC frame count. Extras folders are skipped.
  - `Normalize Audio.command` (same idea for `~/Movies`) is also kept in the repo root.
- **Scripts on drive:** All key scripts copied to `/Volumes/Backup Plus/.jellyfin-scripts/` for portability
- **Gotchas:** Use `filter_complex` not `-af`; ExFAT creates `._*` forks (ignore them); loudnorm is 2-pass (slow on HDD)

### Movies library went missing + film list stale — FIXED (2026-10-15)
- **Symptom:** new films (Dark City, the Satyajit Ray/Indian films) never appeared; film-library.html showed ~37 items.
- **Cause 1:** the "Movies" library (one library = `/Volumes/Backup Plus/All Movies`, all category folders inside) was gone.
  Library definitions live LOCALLY at `~/Library/Application Support/jellyfin/root/default/` (not on the drive), and it
  vanished around the Oct 6 travel-config work. The drive DB still had 537 old movie items + watch data.
  Fix: re-added via API: `POST /Library/VirtualFolders?name=Movies&collectionType=movies&paths=/Volumes/Backup%20Plus/All%20Movies`.
  Check with `GET /Library/VirtualFolders`: Movies, TV Shows, Travel, MasterClass, Collections should all be there.
- **Cause 2:** `~/jellyfin-mac-setup` push was rejected since Oct 7 (remote had newer commits; 1,416 auto-commits piled up
  locally). Fixed by resetting the clone to origin/master (old snapshots on branch `backup/pre-reset-2026-10-15`).
- **Cause 2b:** the Movies library must have ONE LOCATION PER CATEGORY FOLDER (11 today), not `All Movies` itself:
  items are linked to their category folder (TopParentId). Pointing it at `All Movies` hid ~460 films; re-adding the
  category folders + `scripts/fix-movie-parents.py` (63 items re-linked, DB backup `jellyfin.db.pre-fix-20261015-194419`).
- **Cause 3:** sync-library.sh rebuilt the list from whatever Jellyfin returned, so travel mode wiped the drive films.
  Now it keeps the last-known drive films when the drive is unplugged or Jellyfin returns none, and merges
  laptop+drive duplicates (`locations`, `paths`, `drive_online` in library.json).

### Drive / travel modes — AUTOMATIC (2026-10-15)
- `jellyfin-mode [auto|drive|travel|status]` swaps three matched sets together (Jellyfin stopped first):
  data (DB), config, root (= which libraries exist). Drive: `/Volumes/Backup Plus/.jellyfin-{data,config,root}`.
  Travel: `~/Library/Application Support/jellyfin/{data,config,root}.travel` (libraries: Travel = ~/Movies, TV (laptop)).
- Why: libraries used to be ONE local folder shared by both modes; travel mode pointed at a missing drive and the drive
  libraries got removed/re-added → full re-import of ~520 films (the slow "recreating"). Now neither mode's libraries change.
- `~/jellyfin-start` (login launcher; source = repo `jellyfin-start`) runs `jellyfin-mode auto`, scans (incremental), syncs
  the film list; its watchdog switches modes when the drive is plugged in / unplugged (notification + restart).
- **Won't open with drive unplugged? (fixed 2026-10-19)** run `bash ~/jellyfin-mac-setup/jellyfin-mode auto --start`. Cause: cache was
  never swapped (stayed -> drive) and opening Jellyfin.app directly skips the mode switch. cache is now part of the swap.
- Travel instance setup wizard was never completed (no account) → completed with pjdruck/8544 (2026-10-15).
- Timings measured: travel→drive ready ~30-40 s (541 films, no rebuild); drive scan with nothing new ~50 s; travel start ~5 s.
- Old shared library list kept at `~/Library/Application Support/jellyfin/root.local-backup-20261015`; old launcher at
  `~/jellyfin-start.backup-20261015`.

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
- Server URL: `http://localhost:8096` or `http://192.168.1.55:8096` (Mac LAN IP)
- Login: pjdruck / 8544
- Server ID: stored in `/Volumes/Backup Plus/.jellyfin-data/device.txt`
- Current server ID: `52780cf3771445f48fb55101114f3663`

### TV Shows on Drive (Oct 2026)
- **ReLIFE:** 17 episodes (S01E01-13, S02E01-04) with normalized audio sidecars. At `/Volumes/Backup Plus/TV/ReLIFE/`
- **Monogatari Series:** 100 TV episodes + 3 Kizumonogatari movies. At `/Volumes/Backup Plus/TV/Monogatari Series/`
  - Organized to match TMDB ID 46195: S01 Bakemonogatari(12), S02 Nisemonogatari(11), S03 Second Season(23), S04 Owarimonogatari(13), Specials(41)
  - Kizumonogatari (3 movies) in subfolder with `.ignore` — separate movies on TMDB
  - Original BD download preserved at `/Volumes/Backup Plus/TV/Monogatari Series [BD]/` with `.ignore`
  - Organization script: `scripts/organize-monogatari.sh` (run with `--dry-run` to preview)

### TV Connection Troubleshooting
- **Home:** Sony Bravia (10+ years old), Jellyfin Android TV app from Play Store
- **Bangalore:** Fire Stick (not currently in use)
- **HTTPS Timeout Trap on Manual Entry:** Android TV probes HTTPS first if `http://` is omitted; Jellyfin has HTTPS disabled, causing a 20-30s timeout. Always type `http://` explicitly (`http://192.168.1.55:8096`) to bypass HTTPS probing, or wait 15-30s on the server screen for UDP Auto-Discovery.
- **Server ID Mismatch (Drive vs Travel mode):** Drive has Server ID `52780cf3...`, Travel had `9c2fa4a0...`. Switching modes triggers "Unable to connect" / "Server Mismatch" because the TV caches the ID. Fix: keep `device.txt` identical in both modes.
- **Recovery steps if stuck:**
  1. TV Settings → Apps → Jellyfin → **Clear Data**
  2. **Force-stop the app 4+ times** (Clear Data alone doesn't flush in-memory state on old Android TV)
  3. Reopen app, wait 15s for auto-discovery tile or enter `http://192.168.1.55:8096` directly.
- Mac browser "Server Mismatch": hard refresh (`Cmd+Shift+R`)
- NEVER suggest using the TV's web browser — too painful to type URLs on a remote

### CRITICAL SAFETY RULES
- **NEVER use DELETE /Items/{id}** — it deletes physical files from disk. Use POST /Items/{id}/Refresh instead.
- **NEVER delete files** without explicit user instruction
- Always launch Jellyfin via `open /Applications/Jellyfin.app`, not the binary directly
