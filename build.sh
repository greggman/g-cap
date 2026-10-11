#!/bin/sh
# Builds build/G-Cap.app.
#   SIGN_ID=...  sign with that identity; otherwise the app is ad-hoc signed
#                with a fixed designated requirement so macOS keeps the Screen
#                Recording / Microphone permissions across rebuilds.
set -e
cd "$(dirname "$0")"
APP=build/G-Cap.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swift build -c release
cp "$(swift build -c release --show-bin-path)/GCap" "$APP/Contents/MacOS/GCap"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [ -n "$VERSION" ]; then
  plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
fi
if [ -n "$SIGN_ID" ]; then
  codesign --force --options runtime --sign "$SIGN_ID" "$APP"
else
  codesign --force --sign - --identifier com.greggman.gcap \
    --requirements '=designated => identifier "com.greggman.gcap"' "$APP"
fi
echo "Built $APP"
