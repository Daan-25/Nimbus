#!/bin/bash
# Builds Nimbus for iPhone and iPad: the SwiftUI app with the engine linked in.
#
#   ./scripts/build-ios.sh        build/Nimbus-iOS.ipa, unsigned; install it with Nimbus on your Mac
#   ./scripts/build-ios.sh sim    build/ios-simulator/Nimbus.app, for the iOS Simulator
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-0.1.2}"
MIN_IOS=17.0

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

if [ "${1:-}" = "sim" ]; then
    RUST_TARGET=aarch64-apple-ios-sim
    SWIFT_TARGET="arm64-apple-ios$MIN_IOS-simulator"
    SDK=iphonesimulator
    PLATFORM=iPhoneSimulator
    APP="$ROOT/build/ios-simulator/Nimbus.app"
else
    RUST_TARGET=aarch64-apple-ios
    SWIFT_TARGET="arm64-apple-ios$MIN_IOS"
    SDK=iphoneos
    PLATFORM=iPhoneOS
    APP="$ROOT/build/ios/Payload/Nimbus.app"
fi

echo "› Building the engine for $RUST_TARGET"
if ! rustup target list --installed | grep -qx "$RUST_TARGET"; then
    echo "  Missing Rust target. Run: rustup target add $RUST_TARGET" >&2
    exit 1
fi
# Keeps the paths of the machine that builds Nimbus, with its user name, out of the app.
export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=$HOME=~ --remap-path-prefix=$ROOT=nimbus"
# Without this, the C code in the engine is built for the newest iOS only.
export IPHONEOS_DEPLOYMENT_TARGET="$MIN_IOS"
(cd "$ROOT/core" && cargo rustc --release --lib --crate-type staticlib --target "$RUST_TARGET")

echo "› Building Nimbus"
rm -rf "$APP"
mkdir -p "$APP"
SDK_PATH="$(xcrun --sdk "$SDK" --show-sdk-path)"
INTENTS="$ROOT/build/intents-$SDK"
rm -rf "$INTENTS"
mkdir -p "$INTENTS"
# The Shortcuts app reads which actions an app offers from a description beside the app,
# not from its code. The compiler notes down what the types of these kinds say about
# themselves; appintentsmetadataprocessor, below, turns that into the description.
cat > "$INTENTS/protocols.json" <<JSON
["AppIntent", "EntityQuery", "AppEntity", "TransientEntity", "AppEnum", "AppShortcutProviding",
 "AppShortcutsProvider", "AnyResolverProviding", "AppIntentsPackage", "DynamicOptionsProvider",
 "_IntentValueRepresentable", "_AssistantIntentsProvider", "_GenerativeFunctionExtractable",
 "IntentValueQuery", "Resolver", "ExtensionPointDefining"]
JSON
xcrun --sdk "$SDK" swiftc \
    -target "$SWIFT_TARGET" \
    -sdk "$SDK_PATH" \
    -swift-version 5 -O -wmo -parse-as-library \
    -module-name Nimbus \
    -import-objc-header "$ROOT/core/include/nimbus_core.h" \
    -emit-const-values-path "$INTENTS/Nimbus.swiftconstvalues" \
    -Xfrontend -const-gather-protocols-file -Xfrontend "$INTENTS/protocols.json" \
    "$ROOT"/ios/Sources/*.swift "$ROOT"/shared/*.swift \
    "$ROOT/core/target/$RUST_TARGET/release/libnimbus_core.a" \
    -framework Security -framework CoreFoundation -framework SystemConfiguration -liconv \
    -o "$APP/Nimbus"

# Writes Metadata.appintents into the app, which is where Shortcuts looks.
ls "$ROOT"/ios/Sources/*.swift "$ROOT"/shared/*.swift > "$INTENTS/sources.txt"
echo "$INTENTS/Nimbus.swiftconstvalues" > "$INTENTS/const-values.txt"
xcrun appintentsmetadataprocessor \
    --output "$APP" \
    --toolchain-dir "$(dirname "$(dirname "$(dirname "$(xcrun --find swiftc)")")")" \
    --module-name Nimbus \
    --sdk-root "$SDK_PATH" \
    --xcode-version "$(xcodebuild -version | awk '/Build version/ { print $3 }')" \
    --platform-family iOS \
    --deployment-target "$MIN_IOS" \
    --target-triple "$SWIFT_TARGET" \
    --source-file-list "$INTENTS/sources.txt" \
    --swift-const-vals-list "$INTENTS/const-values.txt" \
    --force 2> /dev/null
[ -f "$APP/Metadata.appintents/extract.actionsdata" ] || {
    echo "  The Shortcuts action couldn't be described; the app would come without it." >&2
    exit 1
}

# The debugging tables name every source file with its full path, user name included.
strip -S -x "$APP/Nimbus" 2> /dev/null

cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Nimbus</string>
    <key>CFBundleIdentifier</key><string>io.github.daan-25.nimbus.ios</string>
    <key>CFBundleName</key><string>Nimbus</string>
    <key>CFBundleDisplayName</key><string>Nimbus</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleSupportedPlatforms</key><array><string>$PLATFORM</string></array>
    <key>MinimumOSVersion</key><string>$MIN_IOS</string>
    <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
    <key>UIRequiredDeviceCapabilities</key><array><string>arm64</string></array>
    <key>UILaunchScreen</key><dict/>
    <!-- nimbus://refresh opens Nimbus and refreshes every app. -->
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>io.github.daan-25.nimbus</string>
            <key>CFBundleURLSchemes</key><array><string>nimbus</string></array>
        </dict>
    </array>
    <key>UISupportedInterfaceOrientations</key>
    <array>
        <string>UIInterfaceOrientationPortrait</string>
        <string>UIInterfaceOrientationLandscapeLeft</string>
        <string>UIInterfaceOrientationLandscapeRight</string>
    </array>
    <key>UISupportedInterfaceOrientations~ipad</key>
    <array>
        <string>UIInterfaceOrientationPortrait</string>
        <string>UIInterfaceOrientationPortraitUpsideDown</string>
        <string>UIInterfaceOrientationLandscapeLeft</string>
        <string>UIInterfaceOrientationLandscapeRight</string>
    </array>
    <!-- The Mac puts the pairing file in Documents; this also shows the folder in the Files app. -->
    <key>UIFileSharingEnabled</key><true/>
    <key>LSSupportsOpeningDocumentsInPlace</key><true/>
    <!-- Lets Files, Safari and the share sheet open .ipa files with Nimbus. -->
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>iOS app</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key><array><string>com.apple.itunes.ipa</string></array>
        </dict>
    </array>
    <!-- Refreshing in the background; the identifier is BackgroundRefresh.taskID. -->
    <key>BGTaskSchedulerPermittedIdentifiers</key><array><string>io.github.daan-25.nimbus.refresh</string></array>
    <key>UIBackgroundModes</key><array><string>processing</string></array>
    <key>NSLocalNetworkUsageDescription</key><string>Nimbus connects to this device through LocalDevVPN to install and refresh your apps.</string>
</dict>
</plist>
PLIST

# The app icon: an asset catalog with one large picture, which actool cuts to size.
[ -f "$ROOT/build/icons/ios-1024.png" ] || "$ROOT/scripts/make-icons.sh"
ASSETS="$ROOT/build/icons/Assets.xcassets"
rm -rf "$ASSETS"
mkdir -p "$ASSETS/AppIcon.appiconset"
cp "$ROOT/build/icons/ios-1024.png" "$ASSETS/AppIcon.appiconset/icon.png"
cat > "$ASSETS/Contents.json" <<JSON
{ "info": { "author": "xcode", "version": 1 } }
JSON
cat > "$ASSETS/AppIcon.appiconset/Contents.json" <<JSON
{
  "images": [{ "filename": "icon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024" }],
  "info": { "author": "xcode", "version": 1 }
}
JSON
xcrun actool "$ASSETS" --compile "$APP" --platform "$SDK" \
    --minimum-deployment-target "$MIN_IOS" --target-device iphone --target-device ipad \
    --app-icon AppIcon --output-partial-info-plist "$ROOT/build/icons/icon-info.plist" \
    --output-format human-readable-text > /dev/null
# actool says which icon keys the Info.plist needs.
/usr/libexec/PlistBuddy -c "Merge $ROOT/build/icons/icon-info.plist" "$APP/Info.plist"

if [ "$SDK" = iphonesimulator ]; then
    codesign --force --sign - "$APP"
    echo "✓ $APP"
else
    IPA="$ROOT/build/Nimbus-iOS.ipa"
    rm -f "$IPA"
    (cd "$ROOT/build/ios" && zip -qry "$IPA" Payload)
    echo "✓ $IPA"
fi
