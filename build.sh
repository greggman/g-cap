#!/bin/sh
# Builds build/G-Cap.app.
#   UNIVERSAL=1  build for both arm64 and x86_64
#   SIGN_ID=...  sign with that identity; otherwise the app is ad-hoc signed
#                with a fixed designated requirement so macOS keeps the Screen
#                Recording / Microphone permissions across rebuilds.
set -e
cd "$(dirname "$0")"
APP=build/G-Cap.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [ -n "$UNIVERSAL" ]; then
  # Build each architecture separately and merge them. Passing several
  # --arch flags to swift build switches to the Xcode build system, which
  # mishandles some package settings on older Xcodes.
  BINS=""
  for ARCH in arm64 x86_64; do
    TRIPLE="$ARCH-apple-macosx15.0"
    swift build -c release --triple "$TRIPLE" --scratch-path ".build/$ARCH"
    BINS="$BINS $(swift build -c release --triple "$TRIPLE" --scratch-path ".build/$ARCH" --show-bin-path)/GCap"
  done
  lipo -create $BINS -output "$APP/Contents/MacOS/GCap"
else
  swift build -c release
  cp "$(swift build -c release --show-bin-path)/GCap" "$APP/Contents/MacOS/GCap"
fi
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
