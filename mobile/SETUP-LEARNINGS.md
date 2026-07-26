# Mobile Jellyfin Setup — Learnings & Troubleshooting

What worked, what broke, and why — so the next setup doesn't hit the same walls.

---

## 1. Debian version matters: Bookworm, not Trixie

**Problem:** `proot-distro install debian` installs the latest Debian, which is now Trixie (13). Jellyfin's official .deb packages target Bookworm (12) and depend on specific library versions:
- `libicu72` (Trixie has libicu76)
- `libvpx7` (Trixie has libvpx9)
- `libx265-199` (Trixie has libx265-209)

The installer ran fine through apt setup but failed at `apt-get install -y jellyfin-server` with unmet dependencies.

**Fix:** Use `proot-distro install debian:bookworm` explicitly. All scripts auto-detect whether the installed alias is `debian` or `debian:bookworm` so they work either way.

**If you already installed Trixie:**
```bash
proot-distro remove debian
proot-distro install debian:bookworm
```

---

## 2. Git clone doesn't work easily in Termux

**Problem:** The repo owner uses Google sign-in for GitHub — no password exists. `git clone` prompts for credentials and fails, even with `GIT_TERMINAL_PROMPT=0`.

**Fix:** Since the repo is public, skip git entirely and use wget:
```bash
wget https://github.com/terriblyoffendedmarketer-stack/jellyfin-mac-setup/archive/refs/heads/master.zip -O jf.zip
unzip jf.zip
cd jellyfin-mac-setup-master/mobile
bash termux-install.sh
```

If the repo were private, you'd need a GitHub Personal Access Token (Settings > Developer Settings > Tokens) and clone with `https://<token>@github.com/...`.

---

## 3. Repo must actually be public for wget to work

**Problem:** After changing repo visibility to public on GitHub, the first wget attempt got a 404. GitHub's visibility change can take a moment to propagate.

**Fix:** Wait a few seconds and retry. Verify with:
```bash
wget --spider https://github.com/terriblyoffendedmarketer-stack/jellyfin-mac-setup/archive/refs/heads/master.zip
```
A `302 Found` → `200 OK` means it's working.

---

## 4. Android reads the Seagate drive as-is

**What worked:** The Seagate Backup Plus (likely exFAT or NTFS) mounts on Android without reformatting. Android's USB OTG support reads exFAT, NTFS, and ext4 natively.

No need to reformat the drive to move between Mac and Android — just plug it in.

---

## 5. Drive detection on Android

**What worked:** Android mounts USB OTG drives at:
- `/storage/<VOLUME-UUID>` (e.g., `/storage/1234-5678`)
- Termux symlinks: `~/storage/external-1`, `~/storage/usb`

The scripts scan both locations looking for the `All Movies` folder as a marker.

**Gotcha:** You must grant Termux storage permission first:
```bash
termux-setup-storage
```
This creates the `~/storage/` symlinks. Without it, Termux can't see the drive.

---

## 6. Shared config architecture

**What worked:** Storing Jellyfin's database on the drive itself (`.jellyfin-data/`, `.jellyfin-config/`) so both Mac and Android use the same users, collections, watch history, and metadata.

- Mac: symlinks `~/.local/share/jellyfin` → `/Volumes/Backup Plus/.jellyfin-data`
- Android: proot bind-mounts the drive at `/Volumes/Backup Plus` so Jellyfin sees the same absolute paths

**Important:** Run `shared-config-setup.sh` on Mac first (one time) to migrate existing data to the drive. Without this, Mac and Android would have separate databases.

---

## 7. Path matching between Mac and Android

**What worked:** Inside proot, the drive is bind-mounted at `/Volumes/Backup Plus` — the same path Mac uses. This means library paths like `/Volumes/Backup Plus/All Movies` work on both platforms without reconfiguring Jellyfin's library settings.

```bash
proot-distro login debian \
    --bind "$DRIVE_PATH:/Volumes/Backup Plus" \
    -- bash -c '...'
```

---

## 8. Termux equivalents for Mac tools

| Mac tool | Termux equivalent | Notes |
|----------|------------------|-------|
| `caffeinate` | `termux-wake-lock` | Requires Termux:API from F-Droid |
| `osascript` notifications | `termux-notification` | Requires Termux:API |
| LaunchAgent (plist) | Termux:Boot (`~/.termux/boot/`) | Requires Termux:Boot from F-Droid, open once to activate |
| Jellyfin.app | `jellyfin-server` in Debian proot | Installed via proot-distro |
| AppleScript GUI | Terminal menu (`termux-jellyfin-control`) | Interactive text menu |

---

## 9. Termux must come from F-Droid

The Google Play Store version of Termux is outdated and broken. Always install from F-Droid:
- Termux
- Termux:API (for wake-lock, notifications)
- Termux:Boot (for auto-start on boot, optional)

---

## 10. proot-distro install vs login alias

`proot-distro install debian:bookworm` registers the distro under the alias **`debian`** — the `:bookworm` is a tag that selects which version to install, not part of the login name. Always use `proot-distro login debian` for all subsequent commands. Using `debian:bookworm` as a login alias fails with "container name is not valid."

The rootfs lives at `$PREFIX/var/lib/proot-distro/installed-rootfs/debian/`.

---

## 11. Run apt full-upgrade before the installer

On a fresh or stale Termux, `pkg update` can fail because curl's SSL dependency is broken (`libngtcp2_crypto_ossl.so` can't find `SSL_set_quic_tls_transport_params`). Fix:

```bash
apt update && apt full-upgrade -y
```

Then re-run the installer. When prompted about config files (openssl.cnf, sources.list), press **Y** to take the maintainer's version.

---

## Quick reference: fresh setup from scratch

```bash
# In Termux on Android:
apt update && apt full-upgrade -y
pkg install -y wget unzip

wget https://github.com/terriblyoffendedmarketer-stack/jellyfin-mac-setup/archive/refs/heads/master.zip -O jf.zip
unzip jf.zip
cd jellyfin-mac-setup-master/mobile
bash termux-install.sh

# On Mac (one-time, if not done already):
cd jellyfin-mac-setup && bash shared-config-setup.sh

# Back on Android — plug in drive, then:
~/termux-jellyfin-start
```
