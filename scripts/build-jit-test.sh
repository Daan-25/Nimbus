#!/bin/bash
# Builds build/JITTest.ipa: a tiny app that checks whether Enable JIT works on a device.
# Install it with Nimbus, then start it with Enable JIT.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCES="$ROOT/ios/JITTest"
WORK="$ROOT/build/jit-test"
APP="$WORK/Payload/JITTest.app"
MIN_IOS=17.4

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"

rm -rf "$WORK"
mkdir -p "$APP"
xcrun --sdk iphoneos clang -target "arm64-apple-ios$MIN_IOS" -isysroot "$SDK" -O1 \
    -c "$SOURCES/jit.c" -o "$WORK/jit.o"
xcrun --sdk iphoneos swiftc -target "arm64-apple-ios$MIN_IOS" -sdk "$SDK" \
    -swift-version 5 -O -parse-as-library -module-name JITTest \
    -import-objc-header "$SOURCES/jit.h" \
    "$SOURCES/JITTestApp.swift" "$WORK/jit.o" -o "$APP/JITTest"

cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>JITTest</string>
    <key>CFBundleIdentifier</key><string>io.github.daan-25.nimbus.jittest</string>
    <key>CFBundleName</key><string>JIT Test</string>
    <key>CFBundleDisplayName</key><string>JIT Test</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
    <key>MinimumOSVersion</key><string>$MIN_IOS</string>
    <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
    <key>UIRequiredDeviceCapabilities</key><array><string>arm64</string></array>
    <key>UILaunchScreen</key><dict/>
</dict>
</plist>
PLIST

IPA="$ROOT/build/JITTest.ipa"
rm -f "$IPA"
(cd "$WORK" && zip -qry "$IPA" Payload)
echo "✓ $IPA"
