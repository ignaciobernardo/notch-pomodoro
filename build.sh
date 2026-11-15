#!/bin/bash
# ./build.sh            → build/Pomodoro.app
# ./build.sh install    → also copies to ~/Applications and (re)launches it
# ./build.sh share      → also zips it to build/Pomodoro.zip for AirDrop
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Pomodoro.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Universal (Apple Silicon + Intel) so it runs on whoever you share it with.
for arch in arm64 x86_64; do
  swiftc -O -wmo -swift-version 5 -target $arch-apple-macos15.0 \
    -module-name NotchPomodoro \
    Sources/*.swift -o "build/Pomodoro-$arch" &
done
wait
lipo -create -output "$APP/Contents/MacOS/Pomodoro" build/Pomodoro-arm64 build/Pomodoro-x86_64
rm -f build/Pomodoro-arm64 build/Pomodoro-x86_64

[ -f assets/AppIcon.icns ] && cp assets/AppIcon.icns "$APP/Contents/Resources/"
cp assets/*.wav "$APP/Contents/Resources/"

VERSION="$(cat VERSION)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Pomodoro</string>
  <key>CFBundleDisplayName</key><string>Pomodoro</string>
  <key>CFBundleIdentifier</key><string>cl.natochi.notch-pomodoro</string>
  <key>CFBundleExecutable</key><string>Pomodoro</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Para agregar cada pomodoro terminado a tu calendario.</string>
  <key>NSLocalNetworkUsageDescription</key><string>Para hacer pomodoros junto a personas que estén cerca.</string>
  <key>NSBonjourServices</key><array><string>_notch-pomo._tcp</string><string>_notch-pomo._udp</string></array>
  <key>NSCalendarsUsageDescription</key><string>Para agregar cada pomodoro terminado a tu calendario.</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1
echo "built $APP ($(du -sh "$APP" | cut -f1))"

if [ "${1:-}" = "share" ]; then
  rm -f build/Pomodoro.zip
  ditto -c -k --keepParent "$APP" build/Pomodoro.zip
  echo "share build/Pomodoro.zip ($(du -h build/Pomodoro.zip | cut -f1))"
fi

if [ "${1:-}" = "install" ]; then
  pkill -x Pomodoro 2>/dev/null || true
  rm -rf ~/Applications/Pomodoro.app
  mkdir -p ~/Applications
  cp -R "$APP" ~/Applications/
  open ~/Applications/Pomodoro.app
  echo "installed ~/Applications/Pomodoro.app"
fi
