#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
SRC=..
BUILD=build
APP="$BUILD/Wormod.app"
DEST="/Applications/Wormod.app"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O main.swift -o "$APP/Contents/MacOS/Wormod" \
  -framework Cocoa -framework WebKit -framework EventKit -target arm64-apple-macos13.0

if [[ ! -f AppIcon.icns ]]; then
  swift icon.swift "$BUILD/AppIcon.iconset"
  iconutil -c icns "$BUILD/AppIcon.iconset" -o AppIcon.icns
fi
cp AppIcon.icns "$APP/Contents/Resources/"
cp "$SRC/index.html" "$SRC/widget.html" "$APP/Contents/Resources/"
cp -R "$SRC/icons" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Wormod</string>
  <key>CFBundleDisplayName</key><string>Wormod</string>
  <key>CFBundleIdentifier</key><string>com.wuzhao.workspace-editor</string>
  <key>CFBundleExecutable</key><string>Wormod</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSAppleEventsUsageDescription</key><string>Wormod opens and arranges Safari windows for web modules like Overleaf and Notion.</string>
  <key>NSCalendarsUsageDescription</key><string>The Timeline widget shows today's calendar events.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>The Timeline widget shows today's calendar events.</string>
  <key>NSRemindersUsageDescription</key><string>The To-do and Due Today widgets show your reminders.</string>
  <key>NSRemindersFullAccessUsageDescription</key><string>The To-do and Due Today widgets show your reminders and let you check them off.</string>
</dict>
</plist>
PLIST

# A stable identity keeps Accessibility / Automation grants valid across rebuilds; ad-hoc signatures change every build.
IDENTITY="Workspace Editor Local Signing"
if security find-identity -p codesigning | grep -q "$IDENTITY"; then
  codesign --force --deep -s "$IDENTITY" "$APP"
else
  codesign --force --deep -s - "$APP"
fi
codesign -dr - "$APP" 2>&1 | tail -1

pkill -x WorkspaceEditor 2>/dev/null || true
pkill -x Wormod 2>/dev/null || true
sleep 0.5
rm -rf "$DEST"
cp -R "$APP" "$DEST"
touch "$DEST"
echo "Installed: $DEST"
