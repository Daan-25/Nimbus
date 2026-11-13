#!/bin/bash
# Builds Nimbus and packs it into build/Nimbus-<version>.dmg: the Mac app, which carries the
# iPhone app, next to a shortcut to Applications, in a window with its own picture.
#
#   VERSION=0.2.0 ./scripts/package.sh
#
# Finder lays out the window, so this opens a Finder window for a moment, and macOS may ask
# once whether the terminal may control Finder.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export VERSION="${VERSION:-0.1.2}"
DMG="$ROOT/build/Nimbus-$VERSION.dmg"
# Finder remembers where the draft disk image was and saves that path in the finished one.
# A temporary folder keeps this Mac's user name out of it.
WORK="$(mktemp -d)"
STAGE="$WORK/stage"
DRAFT="$WORK/draft.dmg"
VOLUME="Nimbus"

"$ROOT/scripts/build.sh"

echo "› Packing $DMG"
rm -f "$DMG"
mkdir -p "$STAGE/.background"
cp -R "$ROOT/build/Nimbus.app" "$STAGE/Nimbus.app"
ln -s /Applications "$STAGE/Applications"
# The picture behind the icons, drawn in scripts/make-icons/DiskImageBackground.swift.
cp "$ROOT/build/icons/dmg-background.tiff" "$STAGE/.background/background.tiff"

# A disk image that can still be changed, so Finder can save how its window looks.
hdiutil create -quiet -volname "$VOLUME" -srcfolder "$STAGE" -format UDRW -fs HFS+ -ov "$DRAFT"
rm -rf "$STAGE"
if [ -d "/Volumes/$VOLUME" ]; then
    hdiutil detach -quiet "/Volumes/$VOLUME" || true
fi
hdiutil attach -quiet -readwrite -noverify -noautoopen "$DRAFT"

# The icons' places have to match the landing pads in the picture. The window is a little
# lower than the picture is tall, so no edge of the picture can show.
osascript <<SCRIPT
tell application "Finder"
    tell disk "$VOLUME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {240, 160, 880, 580}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 112
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.tiff"
        set position of item "Nimbus.app" of container window to {170, 170}
        set position of item "Applications" of container window to {470, 170}
        update without registering applications
        delay 2
        close
    end tell
end tell
SCRIPT

sync
hdiutil detach -quiet "/Volumes/$VOLUME"
hdiutil convert -quiet "$DRAFT" -format UDZO -imagekey zlib-level=9 -o "$DMG"
rm -rf "$WORK"

echo "✓ $DMG"
shasum -a 256 "$DMG" | awk '{ print "  sha256 " $1 }'
