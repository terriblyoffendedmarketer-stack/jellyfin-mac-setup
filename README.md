# Jellyfin Setup

Portable Jellyfin media server with a Seagate Backup Plus external drive. Designed to be a personal home server — plug in the drive, start the script, and stream to any device on the same WiFi. Works on both Mac and Android (via Termux).

## Quick Reference

### Mac
| | |
|---|---|
| **Server URL** | `http://192.168.1.51:8096` or `http://jf.local:8096` |
| **Login** | `pjdruck` / `8544` |
| **Drive** | Seagate Backup Plus → `/Volumes/Backup Plus` |
| **Jellyfin Version** | 10.11.11 |

### Mobile (Termux)
| | |
|---|---|
| **Server URL** | `http://localhost:8096` or `http://<phone-wifi-ip>:8096` |
| **Login** | `pjdruck` / `8544` (same account — shared via drive) |
| **Drive** | Seagate Backup Plus via USB OTG → auto-detected under `/storage/` |
| **Media Path** | `/Volumes/Backup Plus/All Movies` (inside proot — matches Mac path) |

## What's Included

### Mac Scripts

| File | Purpose |
|---|---|
| `jellyfin-start` | Main launcher — starts Jellyfin, triggers library scan, starts caffeinate + watchdog |
| `jellyfin-caffeinate.sh` | LaunchAgent script — auto-starts caffeinate whenever Jellyfin is running (regardless of how it was launched) |
| `jellyfin-control.applescript` | Source for the Jellyfin Control.app — single GUI with Show URL, Scan Library, Stop Server, Troubleshoot |
| `shared-config-setup.sh` | One-time migration — moves Jellyfin data onto the Seagate drive so Mac and Android share the same config |

### Mobile Scripts (Termux)

| File | Purpose |
|---|---|
| `mobile/termux-install.sh` | Main installer — sets up proot-distro (Debian), installs Jellyfin, copies scripts |
| `mobile/termux-jellyfin-start` | Main launcher — starts Jellyfin in proot, detects USB drive, wake lock + watchdog |
| `mobile/termux-jellyfin-wakelock.sh` | Background monitor — manages wake lock while Jellyfin is running |
| `mobile/termux-jellyfin-control` | Terminal control menu — status, scan library, start/stop server, view logs |
| `mobile/boot-jellyfin.sh` | Termux:Boot auto-start — runs Jellyfin when the phone boots |

### Web Customizations

| File | Installed to | Purpose |
|---|---|---|
| `custom-overlay.js` | `Jellyfin.app/.../jellyfin-web/` | Hover overlay on movie cards showing curated comments from the Overview field |
| `themed-browse.js` | `Jellyfin.app/.../jellyfin-web/` | Custom "Themes" page — sidebar nav link that shows movies organized by collection in horizontal scrollable rows |
| `branding.css` | Jellyfin Dashboard → Branding → Custom CSS | Styles for the hover overlay (gradient, text, animation) |

### Config

| File | Purpose |
|---|---|
| `com.jellyfin.caffeinate.plist` | LaunchAgent — runs `jellyfin-caffeinate.sh` at login, restarts if it dies |

### Data

| File | Purpose |
|---|---|
| `film_comments.json` | Curated one-line comments for all movies (used as Overview field values) |

## Architecture

### Shared Config
Both Mac and Android use the same Jellyfin database stored on the Seagate drive. Plug the drive into either device — same account, same collections, same watch history, same metadata. The TV's Jellyfin app connects to whichever server is running on the network.

```
Seagate Backup Plus (the single source of truth)
├── .jellyfin-data/     ← Jellyfin database, users, metadata (shared)
├── .jellyfin-config/   ← Jellyfin settings (shared)
├── All Movies/
│   ├── Anime movies/
│   ├── Asian Movies/
│   ├── Hong Sang Soo Films/
│   ├── Indian Films/
│   ├── Movies in General/
│   ├── Andrei Tarkovsky/
│   ├── Tarantino/
│   ├── The Apu Trilogy/
│   ├── Wes Anderson/
│   └── Unsorted Get srt files/
└── TV/
```

### Mac
```
Mac (always on / lid open)
├── Jellyfin.app (media server on port 8096)
│   ├── ~/Library/Application Support/jellyfin/data → symlink to drive's .jellyfin-data/
│   └── ~/Library/Application Support/jellyfin/config → symlink to drive's .jellyfin-config/
├── caffeinate (prevents sleep/disk sleep while Jellyfin runs)
├── jellyfin-watchdog (auto-shuts down if drive disconnects)
└── Seagate Backup Plus (USB) → /Volumes/Backup Plus
```

### Mobile (Termux)
```
Phone (Android)
├── Termux
│   ├── termux-wake-lock (prevents phone sleep while Jellyfin runs)
│   ├── proot-distro (Debian)
│   │   ├── Jellyfin Server (media server on port 8096)
│   │   │   ├── --datadir /Volumes/Backup Plus/.jellyfin-data (same DB)
│   │   │   └── --configdir /Volumes/Backup Plus/.jellyfin-config
│   │   ├── jellyfin-web/ (with custom-overlay.js + themed-browse.js)
│   │   └── /Volumes/Backup Plus → bound to USB drive (matches Mac path)
│   └── watchdog (auto-shuts down if drive disconnects)
├── Termux:API (wake lock, notifications)
├── Termux:Boot (auto-start on boot, optional)
└── USB OTG → Seagate Backup Plus
```

## Features

### Sleep Prevention
- **LaunchAgent** (`com.jellyfin.caffeinate`) runs at login and checks every 30 seconds
- If Jellyfin is running without caffeinate, it auto-starts `caffeinate -s -m -i` tied to the Jellyfin PID
- Prevents system sleep, disk sleep, and idle sleep — but NOT screen dimming (screen dimming doesn't affect the server)
- Caffeinate dies automatically when Jellyfin quits
- Closing the lid works only when plugged into power — on battery, macOS forces sleep regardless

### Drive Disconnect Watchdog
- Checks every 60 seconds if the Seagate drive is still connected
- If disconnected: shows a macOS notification, gracefully shuts down Jellyfin via API, then force-kills if needed
- Prevents serving broken library paths

### Hover Overlay (Custom JS)
- Movie cards show curated comments on hover
- Comments are stored in each movie's Overview field
- Uses MutationObserver to handle Jellyfin's SPA navigation
- CSS is injected via Jellyfin's Branding settings (no file edits needed for the CSS)
- JS files are loaded via a `<script>` tag added before `</head>` in `jellyfin-web/index.html`

### Themed Browse Page (Custom JS)
- Adds a "Themes" link to the sidebar navigation
- Renders all 21 collections as horizontal scrollable rows on a single page
- Collection IDs are hardcoded — if collections are recreated, IDs need updating

### 21 Thematic Collections
Movies are multi-tagged across collections:

| Collection | Count | Type |
|---|---|---|
| Feel-Good & Heartwarming | 64+ | Theme |
| True Stories | 55+ | Theme |
| Korean Thrillers | 43+ | Theme |
| Horror That Lingers | 43+ | Theme |
| Mind-Bending | 38+ | Theme |
| Japanese Cinema | 57+ | Region |
| Korean Romance | 32+ | Theme |
| Martial Arts & Action Cinema | 30+ | Theme |
| Slow Burns | 30+ | Theme |
| War & Conflict | 25+ | Theme |
| Anime Films | 25+ | Region |
| Coming of Age | 24+ | Theme |
| Revenge & Vengeance | 21+ | Theme |
| Visually Stunning | 30+ | Theme |
| Indian Cinema Gems | 16+ | Region |
| One-Room Tension | 16+ | Theme |
| Park Chan-wook | 8 | Director |
| Harry Potter | 8 | Franchise |
| Wong Kar-wai | 6 | Director |
| Wes Anderson | 5 | Director |
| Bong Joon-ho | 4 | Director |

### Mobile: Wake Lock (replaces caffeinate)
- `termux-wake-lock` prevents Android from sleeping while Jellyfin runs
- Acquired automatically when Jellyfin starts, released on shutdown
- Background monitor (`termux-jellyfin-wakelock.sh`) checks every 30 seconds
- Requires Termux:API from F-Droid

### Mobile: USB Drive Auto-Detection
- Scans `/storage/` and Termux storage symlinks for the "All Movies" folder
- Bind-mounts the drive at `/Volumes/Backup Plus` inside proot (matching Mac path)
- Jellyfin reads its database from `.jellyfin-data/` on the drive — same DB as Mac
- Works with any USB volume UUID — no hardcoded Android paths

### Shared Config (Mac + Android)
- Jellyfin database, users, collections, watch history, and metadata live on the drive
- `shared-config-setup.sh` migrates Mac's Jellyfin data to the drive (one-time)
- Mac uses symlinks (`~/Library/Application Support/jellyfin/data` and `config` → drive), Android points directly at the drive
- Drive is mounted at `/Volumes/Backup Plus` on both platforms so library paths match
- Only one device runs Jellyfin at a time (the drive can only be plugged into one)
- The TV's Jellyfin app connects to whichever server IP is active on the network

### Mobile: Terminal Control Menu
Interactive terminal menu (`~/termux-jellyfin-control`) with:
- **Show Status** — checks server, drive, wake lock, WiFi IP
- **Show URL** — displays server URL for phone and LAN access
- **Scan Library** — triggers library refresh via API
- **Start/Stop Server** — manages Jellyfin lifecycle
- **View Log** — shows recent launcher activity
- **Open in Browser** — launches the Jellyfin web UI

### Static IP Setup
- Mac Wi-Fi set to manual IPv4: `192.168.1.51`
- Private Wi-Fi address set to Fixed (not Rotating) to keep consistent MAC address
- DNS: `8.8.8.8`, `8.8.4.4`
- Hostname: `jf` (accessible as `jf.local` on the LAN)

### Jellyfin Control App
Single AppleScript app (`~/Desktop/Jellyfin Control.app`) with Jellyfin icon:
- **Show URL** — displays the server URL with options to open in browser or troubleshoot
- **Scan Library** — triggers a library refresh via API
- **Stop Server** — graceful API shutdown + kills watchdog + kills caffeinate
- **Troubleshoot** — checks: server running, responding, drive mounted, WiFi, caffeinate

## Installation

### Mobile Setup (Termux on Android)

#### Prerequisites
- Android phone with USB OTG support
- USB-C to USB-A OTG adapter (or USB-C hub)
- Seagate drive must be readable by Android (exFAT, NTFS, ext4 all work)
- Install from **F-Droid** (NOT Google Play):
  - [Termux](https://f-droid.org/en/packages/com.termux/) — terminal emulator
  - [Termux:API](https://f-droid.org/en/packages/com.termux.api/) — wake lock + notifications
  - [Termux:Boot](https://f-droid.org/en/packages/com.termux.boot/) — auto-start on boot (optional)

#### Install

**Step 1 — On your Mac (one-time):** Migrate Jellyfin data to the drive
```bash
cd jellyfin-mac-setup
bash shared-config-setup.sh
```
This moves your Jellyfin database, users, and collections onto the Seagate drive. Your Mac setup continues to work normally (via symlinks).

**Step 2 — On your phone:** Install Termux and run the installer
1. Open Termux and clone this repo:
   ```bash
   pkg install git
   git clone https://github.com/terriblyoffendedmarketer-stack/jellyfin-mac-setup.git
   cd jellyfin-mac-setup/mobile
   bash termux-install.sh
   ```
2. Plug in the Seagate drive via USB OTG
3. When Android prompts, allow Termux to access the USB drive
4. Start Jellyfin:
   ```bash
   ~/termux-jellyfin-start
   ```
5. Open `http://localhost:8096` on any device on your WiFi — log in as pjdruck, same account, same everything

#### Android Battery Settings
Android aggressively kills background apps. To keep Jellyfin running:
- Go to **Settings → Battery → Termux → Unrestricted** (exact path varies by phone)
- Disable battery optimization for Termux
- On Samsung: also disable "Put unused apps to sleep" for Termux
- On Xiaomi: enable "Autostart" for Termux in Security app
- Keep Termux's notification visible (it prevents Android from killing it)

#### After Phone Reboot
If Termux:Boot is installed, Jellyfin starts automatically. Otherwise:
```bash
~/termux-jellyfin-start
```

#### Power Notes
- A portable HDD may draw too much power from some phones — if the drive keeps disconnecting, use a powered USB hub between the OTG adapter and the drive
- Keep the phone plugged into power when running as a server
- Transcoding is limited on phone hardware — direct play works best (most modern clients handle this)

### Fresh Mac Setup

1. Install Jellyfin: `brew install --cask jellyfin`
2. Clone this repo
3. Copy scripts:
   ```bash
   cp jellyfin-start ~/jellyfin-start
   cp jellyfin-caffeinate.sh ~/jellyfin-caffeinate.sh
   chmod +x ~/jellyfin-start ~/jellyfin-caffeinate.sh
   ```
4. Install the LaunchAgent:
   ```bash
   cp com.jellyfin.caffeinate.plist ~/Library/LaunchAgents/
   launchctl load ~/Library/LaunchAgents/com.jellyfin.caffeinate.plist
   ```
5. Set hostname: `sudo scutil --set LocalHostName jf`
6. Install web customizations:
   ```bash
   WEB_DIR="/Applications/Jellyfin.app/Contents/Resources/jellyfin-web"
   cp custom-overlay.js "$WEB_DIR/"
   cp themed-browse.js "$WEB_DIR/"
   ```
   Then add before `</head>` in `$WEB_DIR/index.html`:
   ```html
   <script defer="defer" src="custom-overlay.js"></script>
   <script defer="defer" src="themed-browse.js"></script>
   ```
7. Paste the contents of `branding.css` into Jellyfin Dashboard → General → Custom CSS
8. Build the Control app:
   ```bash
   osacompile -o ~/Desktop/"Jellyfin Control.app" jellyfin-control.applescript
   # Copy Jellyfin icon
   cp /Applications/Jellyfin.app/Contents/Resources/AppIcon.icns \
      ~/Desktop/"Jellyfin Control.app"/Contents/Resources/applet.icns
   ```
9. Set static IP: System Settings → Wi-Fi → Details → TCP/IP → Manually → `192.168.1.51`
10. Set Private Wi-Fi address to Fixed (not Rotating)
11. Add DNS: `8.8.8.8` and `8.8.4.4`

### After Jellyfin Update
Jellyfin updates overwrite `jellyfin-web/`. Re-copy the JS files and re-add the `<script>` tags to `index.html`.

## Comment Style Guide

All movies and TV series have curated comments in their Overview field. The prompt used to generate them:

> Write a 1–3 sentence comment for a movie or TV series. Lead with what makes this worth watching — if the premise itself is the hook, open with it (as a "what if" or vivid setup). If the craft is the hook, lead with that instead. The comment should feel like a film-literate friend telling you why this is worth your time — personal, opinionated, specific. Reference craft elements where natural: direction, editing, performance, structure, cinematography, score. Capture the feeling the viewer walks away with. Never summarize the full plot. Never mention twists, surprises, or revelations — even hinting that "something unexpected happens" is a spoiler. Avoid phrases like "not what it seems," "more than meets the eye," or "takes a turn." Don't name character arcs that unfold as reveals. Write as if the reader hasn't seen it yet and should go in blind. Use present tense. One dash-separated aside per comment max.
