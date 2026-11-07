#!/bin/bash
# Builds build/Nimbus.app: the SwiftUI app with nimbus-helper inside it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Nimbus.app"
VERSION="${VERSION:-0.1.0}"

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

echo "› Building nimbus-helper"
cargo build --release --manifest-path "$ROOT/core/Cargo.toml"

echo "› Building Nimbus"
swift build -c release --package-path "$ROOT/mac"
SWIFT_BIN="$(swift build -c release --package-path "$ROOT/mac" --show-bin-path)"

echo "› Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SWIFT_BIN/Nimbus" "$APP/Contents/MacOS/Nimbus"
cp "$ROOT/core/target/release/nimbus-helper" "$APP/Contents/MacOS/nimbus-helper"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Nimbus</string>
    <key>CFBundleIdentifier</key><string>io.github.daan-25.nimbus</string>
    <key>CFBundleName</key><string>Nimbus</string>
    <key>CFBundleDisplayName</key><string>Nimbus</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "› Signing (ad hoc)"
codesign --force --sign - "$APP/Contents/MacOS/nimbus-helper"
codesign --force --sign - "$APP"

echo "✓ $APP"
