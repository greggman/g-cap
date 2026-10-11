#!/bin/sh
# Builds build/G-Cap.app.
#   UNIVERSAL=1  build for both arm64 and x86_64
#   SIGN_ID=...  sign with that identity; otherwise the app is ad-hoc signed
#                with a fixed designated requirement so macOS keeps the Screen
#                Recording / Microphone permissions across rebuilds.
set -e
cd "$(dirname "$0")"
ARCH_FLAGS=""
if [ -n "$UNIVERSAL" ]; then
  ARCH_FLAGS="--arch arm64 --arch x86_64"
fi
swift build -c release $ARCH_FLAGS
BIN_DIR=$(swift build -c release $ARCH_FLAGS --show-bin-path)
APP=build/G-Cap.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/GCap" "$APP/Contents/MacOS/GCap"
cp Resources/Info.plist "$APP/Contents/Info.plist"
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
