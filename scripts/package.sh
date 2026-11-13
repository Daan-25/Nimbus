#!/bin/bash
# Builds Nimbus and packs it into build/Nimbus-<version>.dmg: the Mac app, which carries the
# iPhone app, next to a shortcut to Applications.
#
#   VERSION=0.2.0 ./scripts/package.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export VERSION="${VERSION:-0.1.0}"
DMG="$ROOT/build/Nimbus-$VERSION.dmg"
STAGE="$ROOT/build/dmg"

"$ROOT/scripts/build.sh"

echo "› Packing $DMG"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$ROOT/build/Nimbus.app" "$STAGE/Nimbus.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Nimbus" -srcfolder "$STAGE" -format UDZO -ov "$DMG"
rm -rf "$STAGE"

echo "✓ $DMG"
shasum -a 256 "$DMG" | awk '{ print "  sha256 " $1 }'
