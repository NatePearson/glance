#!/bin/bash
# Builds Glance.app from source. Re-run this any time you change Sources/*.swift.
set -e
cd "$(dirname "$0")"

APP="Glance.app"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
DEPLOY="13.0"   # minimum macOS
mkdir -p build

echo "→ Compiling universal binary (arm64 + x86_64)…"
swiftc -O -swift-version 5 -sdk "$SDK" -target "arm64-apple-macosx$DEPLOY" \
    -framework Cocoa -framework Carbon Sources/*.swift -o build/Glance-arm64
swiftc -O -swift-version 5 -sdk "$SDK" -target "x86_64-apple-macosx$DEPLOY" \
    -framework Cocoa -framework Carbon Sources/*.swift -o build/Glance-x86_64
lipo -create build/Glance-arm64 build/Glance-x86_64 -output build/Glance
echo "  $(lipo -archs build/Glance)"

echo "→ Assembling app bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/Glance "$APP/Contents/MacOS/Glance"
cp Info.plist "$APP/Contents/Info.plist"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns" || true

echo "→ Signing (ad-hoc)…"
codesign --force --deep --sign - "$APP"

echo "✓ Built $(pwd)/$APP"
echo "  Launch with:  open $APP        (or double-click it in Finder)"
