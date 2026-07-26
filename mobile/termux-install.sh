#!/data/data/com.termux/files/usr/bin/bash
# Install Jellyfin media server in Termux via proot-distro (Debian).
# Run this inside Termux on your Android phone.
#
# Prerequisites:
#   - Termux (from F-Droid, NOT Google Play — Play Store version is outdated)
#   - Termux:API (from F-Droid — for wake-lock and notifications)
#   - Termux:Boot (from F-Droid — for auto-start on boot, optional)
#   - USB OTG adapter (USB-C to USB-A)
#   - Seagate Backup Plus (must be readable by Android — exFAT, NTFS, ext4 all work)

set -e

echo "Jellyfin Mobile Setup — Termux Installer"
echo "========================================="
echo ""

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 1. Update Termux and install dependencies
echo "[1/7] Updating Termux packages..."
pkg update -y
pkg install -y proot-distro termux-api curl

# 2. Grant storage access (prompts Android permission dialog)
echo "[2/7] Setting up storage access..."
echo "  If prompted, grant Termux access to storage."
termux-setup-storage || true
sleep 2

# 3. Install Debian Bookworm via proot-distro
# Jellyfin packages need Bookworm (Debian 12) — Trixie (13) has incompatible libraries.
echo "[3/7] Installing Debian Bookworm in proot-distro..."

# proot-distro install debian:bookworm registers under the alias "debian",
# so we always login with "debian" regardless of which tag was used to install.
if proot-distro list 2>/dev/null | grep -q "debian.*Installed"; then
    echo "  Debian already installed."
else
    proot-distro install debian:bookworm
fi

# 4. Install Jellyfin inside Debian
echo "[4/7] Installing Jellyfin inside Debian Bookworm..."
proot-distro login debian -- bash -c '
set -e

# Install prerequisites
apt-get update
apt-get install -y curl gnupg2 ca-certificates apt-transport-https

# Add Jellyfin repository
if [ ! -f /etc/apt/sources.list.d/jellyfin.sources ]; then
    curl -fsSL https://repo.jellyfin.org/jellyfin_team.gpg.key | gpg --dearmor -o /usr/share/keyrings/jellyfin.gpg
    ARCH=$(dpkg --print-architecture)
    cat > /etc/apt/sources.list.d/jellyfin.sources <<EOF
Types: deb
URIs: https://repo.jellyfin.org/debian
Suites: bookworm
Components: main
Architectures: ${ARCH}
Signed-By: /usr/share/keyrings/jellyfin.gpg
EOF
    apt-get update
fi

# Install Jellyfin server and web
apt-get install -y jellyfin-server jellyfin-web jellyfin-ffmpeg6

echo "Jellyfin installed successfully inside Debian proot."
'

# 5. Copy scripts to Termux home
echo "[5/7] Installing scripts..."
cp "$SCRIPT_DIR/termux-jellyfin-start" ~/termux-jellyfin-start
cp "$SCRIPT_DIR/termux-jellyfin-wakelock.sh" ~/termux-jellyfin-wakelock.sh
cp "$SCRIPT_DIR/termux-jellyfin-control" ~/termux-jellyfin-control
chmod +x ~/termux-jellyfin-start ~/termux-jellyfin-wakelock.sh ~/termux-jellyfin-control

# 6. Install web customizations inside Debian
echo "[6/7] Installing web customizations..."
PARENT_DIR="$SCRIPT_DIR/.."
proot-distro login debian -- bash -c '
WEB_DIR="/usr/share/jellyfin/jellyfin-web"
if [ -d "$WEB_DIR" ]; then
    echo "  Web directory found at $WEB_DIR"
else
    echo "  WARNING: Jellyfin web directory not found — install JS files after first launch"
fi
'

if [ -f "$PARENT_DIR/custom-overlay.js" ] && [ -f "$PARENT_DIR/themed-browse.js" ]; then
    # Copy JS files into the proot filesystem
    PROOT_HOME="$PREFIX/var/lib/proot-distro/installed-rootfs/debian"
    PROOT_WEB="$PROOT_HOME/usr/share/jellyfin/jellyfin-web"
    if [ -d "$PROOT_WEB" ]; then
        cp "$PARENT_DIR/custom-overlay.js" "$PROOT_WEB/"
        cp "$PARENT_DIR/themed-browse.js" "$PROOT_WEB/"

        if ! grep -q "custom-overlay.js" "$PROOT_WEB/index.html" 2>/dev/null; then
            sed -i 's|</head>|<script defer="defer" src="custom-overlay.js"></script>\n<script defer="defer" src="themed-browse.js"></script>\n</head>|' "$PROOT_WEB/index.html"
            echo "  Added script tags to index.html"
        else
            echo "  Script tags already in index.html"
        fi
    fi
fi

# 7. Set up Termux:Boot auto-start (optional)
echo "[7/7] Setting up auto-start on boot..."
BOOT_DIR="$HOME/.termux/boot"
mkdir -p "$BOOT_DIR"
cp "$SCRIPT_DIR/boot-jellyfin.sh" "$BOOT_DIR/jellyfin"
chmod +x "$BOOT_DIR/jellyfin"
echo "  Auto-start script installed."
echo "  (Requires Termux:Boot from F-Droid — open it once to activate)"

# Add shell alias
grep -q 'alias jfs=' "$HOME/.bashrc" 2>/dev/null || echo 'alias jfs="~/termux-jellyfin-start"' >> "$HOME/.bashrc"

echo ""
echo "Done! Next steps:"
echo ""
echo "  FIRST TIME — run this on your Mac (one-time):"
echo "    cd jellyfin-mac-setup && bash shared-config-setup.sh"
echo "    This moves your Jellyfin data onto the Seagate drive so both"
echo "    Mac and Android share the same account, collections, and metadata."
echo ""
echo "  THEN on your phone:"
echo "  1. Plug in your Seagate Backup Plus via USB OTG adapter"
echo "  2. When Android asks, allow Termux to access the USB drive"
echo "  3. Run: ~/termux-jellyfin-start"
echo "  4. Open http://localhost:8096 on any device on your WiFi"
echo "  5. Log in as pjdruck — same account, same library, same collections"
echo ""
echo "Control menu: ~/termux-jellyfin-control"
echo "Quick start:  jfs (after restarting Termux)"
