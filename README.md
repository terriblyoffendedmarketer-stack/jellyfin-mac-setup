# Jellyfin Mac Setup

Portable Jellyfin media server running on Mac with a Seagate Backup Plus external drive. Designed to be a personal home server — plug in the drive, double-click, and stream to any device on the same WiFi.

## Quick Reference

| | |
|---|---|
| **Server URL** | `http://192.168.1.51:8096` or `http://jf.local:8096` |
| **Login** | `pjdruck` / `8544` |
| **Drive** | Seagate Backup Plus → `/Volumes/Backup Plus` |
| **Jellyfin Version** | 10.11.11 |

## What's Included

### Scripts

| File | Purpose |
|---|---|
| `jellyfin-start` | Main launcher — starts Jellyfin, triggers library scan, starts caffeinate + watchdog |
| `jellyfin-caffeinate.sh` | LaunchAgent script — auto-starts caffeinate whenever Jellyfin is running (regardless of how it was launched) |
| `jellyfin-control.applescript` | Source for the Jellyfin Control.app — single GUI with Show URL, Scan Library, Stop Server, Troubleshoot |

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

```
Mac (always on / lid open)
├── Jellyfin.app (media server on port 8096)
├── caffeinate (prevents sleep/disk sleep while Jellyfin runs)
├── jellyfin-watchdog (auto-shuts down if drive disconnects)
└── Seagate Backup Plus (USB)
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
