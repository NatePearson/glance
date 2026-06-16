#!/bin/bash
# Builds Glance.app from source. Re-run this any time you change Sources/*.swift.
set -e
cd "$(dirname "$0")"

APP="Glance.app"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
DEPLOY="13.0"   # minimum macOS
mkdir -p build

# Generate the app icon (AppIcon.icns) from make-icon.swift if it's missing.
if [ ! -f AppIcon.icns ]; then
    echo "→ Generating app icon…"
    swiftc -swift-version 5 -sdk "$SDK" -framework Cocoa make-icon.swift -o build/mkicon
    build/mkicon build/icon_1024.png
    SET=build/Glance.iconset; rm -rf "$SET"; mkdir -p "$SET"
    for s in 16 32 128 256 512; do
        sips -z "$s" "$s" build/icon_1024.png --out "$SET/icon_${s}x${s}.png" >/dev/null
        sips -z "$((s*2))" "$((s*2))" build/icon_1024.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$SET" -o AppIcon.icns
fi

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
