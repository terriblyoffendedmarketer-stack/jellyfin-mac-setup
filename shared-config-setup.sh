#!/bin/bash
# Migrate Jellyfin data to the Seagate drive so Mac and Android share the same config.
# Run this ONCE on your Mac. After this, Jellyfin's database, users, collections,
# watch history, and metadata all live on the drive — plug it into either device
# and you get the same setup.
#
# What it does:
#   1. Copies your existing Jellyfin data from ~/Library/Application Support/jellyfin
#      to the drive (.jellyfin-data for data, .jellyfin-config for config)
#   2. Creates symlinks so Jellyfin.app still finds its data at the expected path
#
# After running this, your Mac Jellyfin works exactly the same — it just reads
# from the drive instead of the internal disk. When you plug the drive into your
# phone and start Jellyfin there, it sees the same database.

set -e

DRIVE="/Volumes/Backup Plus"
SHARED_DATA="$DRIVE/.jellyfin-data"
SHARED_CONFIG="$DRIVE/.jellyfin-config"

# macOS Jellyfin stores everything under ~/Library/Application Support/jellyfin/
# with subdirectories: data/, config/, cache/, log/, metadata/, plugins/, root/, temp/
MAC_JF="$HOME/Library/Application Support/jellyfin"
MAC_DATA="$MAC_JF/data"
MAC_CONFIG="$MAC_JF/config"

echo "Jellyfin Shared Config Migration"
echo "================================="
echo ""

# Check drive is connected
if [ ! -d "$DRIVE" ]; then
    echo "ERROR: Seagate drive not found at $DRIVE"
    echo "Plug in the drive and try again."
    exit 1
fi

# Check Jellyfin is not running
if pgrep -f "Jellyfin Server" > /dev/null 2>&1; then
    echo "ERROR: Jellyfin is currently running."
    echo "Stop Jellyfin first (use Jellyfin Control → Stop Server), then re-run this."
    exit 1
fi

# Check for existing Jellyfin directory
if [ ! -d "$MAC_JF" ]; then
    echo "WARNING: No Jellyfin directory found at $MAC_JF"
    echo "If this is a fresh install, that's fine — the directories will be"
    echo "created on the drive when you first start Jellyfin."
fi

# Already migrated?
if [ -L "$MAC_DATA" ] && [ -d "$SHARED_DATA" ]; then
    echo "Already migrated — $MAC_DATA is a symlink to $SHARED_DATA"
    echo "Nothing to do."
    exit 0
fi

echo "This will move your Jellyfin data to the Seagate drive so it's"
echo "shared between Mac and Android."
echo ""
echo "  Data:   $MAC_DATA → $SHARED_DATA"
echo "  Config: $MAC_CONFIG → $SHARED_CONFIG"
echo ""
printf "Continue? (y/n) "
read -r answer
[ "$answer" != "y" ] && echo "Cancelled." && exit 0

echo ""

# Ensure the Jellyfin directory exists
mkdir -p "$MAC_JF"

# Migrate data directory
if [ -d "$MAC_DATA" ] && [ ! -L "$MAC_DATA" ]; then
    echo "Copying Jellyfin data to drive..."
    mkdir -p "$SHARED_DATA"
    cp -a "$MAC_DATA"/* "$SHARED_DATA/" 2>/dev/null || true
    echo "  Copied data to $SHARED_DATA"

    mv "$MAC_DATA" "${MAC_DATA}.backup"
    echo "  Backed up original to ${MAC_DATA}.backup"
elif [ ! -e "$MAC_DATA" ]; then
    mkdir -p "$SHARED_DATA"
    echo "  Created fresh data directory at $SHARED_DATA"
fi

ln -sf "$SHARED_DATA" "$MAC_DATA"
echo "  Symlinked $MAC_DATA → $SHARED_DATA"

# Migrate config directory
if [ -d "$MAC_CONFIG" ] && [ ! -L "$MAC_CONFIG" ]; then
    echo "Copying Jellyfin config to drive..."
    mkdir -p "$SHARED_CONFIG"
    cp -a "$MAC_CONFIG"/* "$SHARED_CONFIG/" 2>/dev/null || true
    echo "  Copied config to $SHARED_CONFIG"

    mv "$MAC_CONFIG" "${MAC_CONFIG}.backup"
    echo "  Backed up original to ${MAC_CONFIG}.backup"
elif [ ! -e "$MAC_CONFIG" ]; then
    mkdir -p "$SHARED_CONFIG"
    echo "  Created fresh config directory at $SHARED_CONFIG"
fi

ln -sf "$SHARED_CONFIG" "$MAC_CONFIG"
echo "  Symlinked $MAC_CONFIG → $SHARED_CONFIG"

echo ""
echo "Done! Your Jellyfin data now lives on the Seagate drive."
echo ""
echo "  Data:   $SHARED_DATA"
echo "  Config: $SHARED_CONFIG"
echo ""
echo "Start Jellyfin as usual — everything works the same on Mac."
echo "When you plug this drive into your Android phone and run"
echo "termux-jellyfin-start, it will use the same database."
echo ""
if [ -d "${MAC_DATA}.backup" ] || [ -d "${MAC_CONFIG}.backup" ]; then
    echo "Backups of your original data are at:"
    [ -d "${MAC_DATA}.backup" ] && echo "  ${MAC_DATA}.backup"
    [ -d "${MAC_CONFIG}.backup" ] && echo "  ${MAC_CONFIG}.backup"
    echo "You can delete these once you've confirmed everything works."
fi
