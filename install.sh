#!/bin/bash
# Install Jellyfin media server setup on a Mac.
# Run this on a fresh Mac to replicate the setup.

set -e

echo "Jellyfin Mac Setup — Installer"
echo "==============================="
echo ""

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 1. Install Jellyfin
if [ ! -d "/Applications/Jellyfin.app" ]; then
    echo "Installing Jellyfin..."
    brew install --cask jellyfin
else
    echo "Jellyfin already installed."
fi

# 2. Copy scripts to home directory
echo "Installing scripts..."
cp "$SCRIPT_DIR/jellyfin-start" ~/jellyfin-start
cp "$SCRIPT_DIR/jellyfin-caffeinate.sh" ~/jellyfin-caffeinate.sh
chmod +x ~/jellyfin-start ~/jellyfin-caffeinate.sh

# 3. Install LaunchAgent for persistent caffeinate
echo "Installing LaunchAgent..."
cp "$SCRIPT_DIR/com.jellyfin.caffeinate.plist" ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.jellyfin.caffeinate.plist 2>/dev/null || true

# 4. Install web customizations
echo "Installing web customizations..."
WEB_DIR="/Applications/Jellyfin.app/Contents/Resources/jellyfin-web"
if [ -d "$WEB_DIR" ]; then
    cp "$SCRIPT_DIR/custom-overlay.js" "$WEB_DIR/"
    cp "$SCRIPT_DIR/themed-browse.js" "$WEB_DIR/"

    # Add script tags to index.html if not already present
    if ! grep -q "custom-overlay.js" "$WEB_DIR/index.html"; then
        sed -i '' 's|</head>|<script defer="defer" src="custom-overlay.js"></script>\n<script defer="defer" src="themed-browse.js"></script>\n</head>|' "$WEB_DIR/index.html"
        echo "  Added script tags to index.html"
    else
        echo "  Script tags already in index.html"
    fi
else
    echo "  WARNING: Jellyfin web directory not found — install JS files manually after first launch"
fi

# 5. Build Jellyfin Control app
echo "Building Jellyfin Control app..."
osacompile -o ~/Desktop/"Jellyfin Control.app" "$SCRIPT_DIR/jellyfin-control.applescript"
if [ -f "/Applications/Jellyfin.app/Contents/Resources/AppIcon.icns" ]; then
    cp /Applications/Jellyfin.app/Contents/Resources/AppIcon.icns \
       ~/Desktop/"Jellyfin Control.app"/Contents/Resources/applet.icns
fi

# 6. Set hostname
echo "Setting hostname to 'jf'..."
sudo scutil --set LocalHostName jf 2>/dev/null || echo "  Could not set hostname (needs sudo)"

# 7. Create launcher app for login item
mkdir -p ~/Applications/"Jellyfin Launcher.app"/Contents/MacOS
cat > ~/Applications/"Jellyfin Launcher.app"/Contents/MacOS/"Jellyfin Launcher" << 'SCRIPT'
#!/bin/bash
exec ~/jellyfin-start
SCRIPT
chmod +x ~/Applications/"Jellyfin Launcher.app"/Contents/MacOS/"Jellyfin Launcher"

cat > ~/Applications/"Jellyfin Launcher.app"/Contents/Info.plist << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Jellyfin Launcher</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.jellyfin-launcher</string>
    <key>CFBundleName</key>
    <string>Jellyfin Launcher</string>
    <key>LSBackgroundOnly</key>
    <true/>
</dict>
</plist>
PLIST

# 8. Add as login item
osascript -e 'tell application "System Events" to make login item at end with properties {path:"'$HOME'/Applications/Jellyfin Launcher.app", hidden:true}' 2>/dev/null

# 9. Add shell aliases if not already present
SHELL_RC=~/.zshrc
[ -f ~/.bashrc ] && ! [ -f ~/.zshrc ] && SHELL_RC=~/.bashrc
grep -q 'alias jfs=' "$SHELL_RC" 2>/dev/null || echo 'alias jfs="~/jellyfin-start"' >> "$SHELL_RC"

echo ""
echo "Done! Next steps:"
echo "  1. Plug in your Seagate Backup Plus drive"
echo "  2. Open Jellyfin from Applications (or reboot — it auto-starts)"
echo "  3. Go to http://localhost:8096 to complete the setup wizard"
echo "  4. Add your movie folders as a Movies library"
echo "  5. Paste branding.css into Dashboard → General → Custom CSS"
echo "  6. Set static IP: System Settings → Wi-Fi → Details → TCP/IP → Manually → 192.168.1.51"
echo "  7. Set Private Wi-Fi address to Fixed (not Rotating)"
echo "  8. Add DNS: 8.8.8.8 and 8.8.4.4"
echo ""
echo "GUI: Double-click 'Jellyfin Control' on Desktop"
echo "Terminal: jfs (start server + scan)"
