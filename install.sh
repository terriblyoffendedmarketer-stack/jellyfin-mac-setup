#!/bin/bash
# Install Jellyfin media server setup on a Mac.
# Run this on a fresh Mac to replicate the setup.

set -e

echo "Jellyfin Mac Setup — Installer"
echo "==============================="
echo ""

# 1. Install Jellyfin
if [ ! -d "/Applications/Jellyfin.app" ]; then
    echo "Installing Jellyfin..."
    brew install --cask jellyfin
else
    echo "Jellyfin already installed."
fi

# 2. Copy scripts to home directory
echo "Installing scripts..."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cp "$SCRIPT_DIR/jellyfin-start" ~/jellyfin-start
cp "$SCRIPT_DIR/jellyfin-url" ~/jellyfin-url
cp "$SCRIPT_DIR/jellyfin-scan" ~/jellyfin-scan
cp "$SCRIPT_DIR/jellyfin-fix" ~/jellyfin-fix
chmod +x ~/jellyfin-start ~/jellyfin-url ~/jellyfin-scan ~/jellyfin-fix

# 3. Create desktop shortcuts
cp "$SCRIPT_DIR/jellyfin-url" ~/Desktop/"Jellyfin URL.command"
cp "$SCRIPT_DIR/jellyfin-scan" ~/Desktop/"Jellyfin Scan.command"
cp "$SCRIPT_DIR/jellyfin-fix" ~/Desktop/"Jellyfin Fix.command"
chmod +x ~/Desktop/"Jellyfin URL.command" ~/Desktop/"Jellyfin Scan.command" ~/Desktop/"Jellyfin Fix.command"

# 4. Create launcher app for login item
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

# 5. Add as login item
osascript -e 'tell application "System Events" to make login item at end with properties {path:"'$HOME'/Applications/Jellyfin Launcher.app", hidden:true}' 2>/dev/null

# 6. Add shell aliases if not already present
SHELL_RC=~/.zshrc
[ -f ~/.bashrc ] && ! [ -f ~/.zshrc ] && SHELL_RC=~/.bashrc
grep -q 'alias jf=' "$SHELL_RC" 2>/dev/null || echo 'alias jf="~/jellyfin-url"' >> "$SHELL_RC"
grep -q 'alias jfs=' "$SHELL_RC" 2>/dev/null || echo 'alias jfs="~/jellyfin-scan"' >> "$SHELL_RC"
grep -q 'alias jff=' "$SHELL_RC" 2>/dev/null || echo 'alias jff="~/jellyfin-fix"' >> "$SHELL_RC"

echo ""
echo "Done! Next steps:"
echo "  1. Plug in your Seagate Backup Plus drive"
echo "  2. Open Jellyfin from Applications (or reboot — it auto-starts)"
echo "  3. Go to http://localhost:8096 to complete the setup wizard"
echo "  4. Add your movie folders as a Movies library"
echo ""
echo "Commands: jf (show URL) | jfs (scan) | jff (fix issues)"
