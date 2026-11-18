#!/bin/zsh
# Builds "Container Control.app" in ./build. Pass --install to copy it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN=$(swift build -c release --show-bin-path)
APP="build/Container Control.app"
VERSION=$(git describe --tags --always 2>/dev/null || echo dev)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/ContainerControl" "$APP/Contents/MacOS/ContainerControl"
cp "$BIN/cctl" "$APP/Contents/MacOS/cctl"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Container Control</string>
    <key>CFBundleDisplayName</key><string>Container Control</string>
    <key>CFBundleIdentifier</key><string>com.josepaternina.containercontrol</string>
    <key>CFBundleExecutable</key><string>ContainerControl</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string></array>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.4.0</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP/Contents/MacOS/cctl"
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p ~/Applications
  pkill -x ContainerControl 2>/dev/null || true
  rm -rf ~/Applications/"Container Control.app"
  cp -R "$APP" ~/Applications/
  echo "Installed ~/Applications/Container Control.app"
fi
