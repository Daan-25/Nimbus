#!/bin/bash
# Renders Nimbus's icons into build/icons: Nimbus.icns for the Mac app and ios-1024.png for
# the iPhone app. The drawing itself is in shared/NimbusIcon.swift.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/icons"

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

mkdir -p "$OUT"
swiftc -O -parse-as-library "$ROOT"/scripts/make-icons/*.swift "$ROOT/shared/NimbusIcon.swift" \
    -o "$OUT/make-icons"
"$OUT/make-icons" "$OUT"
iconutil -c icns "$OUT/Nimbus.iconset" -o "$OUT/Nimbus.icns"
# One file with both sizes, so the disk image's window is sharp on every screen.
tiffutil -cathidpicheck "$OUT/dmg-background.png" "$OUT/dmg-background@2x.png" \
    -out "$OUT/dmg-background.tiff" 2> /dev/null
