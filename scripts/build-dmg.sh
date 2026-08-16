#!/bin/zsh

set -euo pipefail

ROOT_DIR=${0:A:h:h}
BUILD_DIR="$ROOT_DIR/build"
STAGING_DIR="$BUILD_DIR/dmg-root"
OUTPUT=${1:-"$ROOT_DIR/dist/Speaker-Alert.dmg"}

"$ROOT_DIR/scripts/build-app.sh" "$BUILD_DIR"

/bin/rm -rf "$STAGING_DIR"
/bin/mkdir -p "$STAGING_DIR" "${OUTPUT:h}"
/usr/bin/ditto "$BUILD_DIR/Speaker Alert.app" "$STAGING_DIR/Speaker Alert.app"
/usr/bin/install -m 0755 "$ROOT_DIR/Install.command" "$STAGING_DIR/Install.command"
/usr/bin/install -m 0644 \
    "$ROOT_DIR/Packaging/io.github.meteorsliu.speaker-alert.plist" \
    "$STAGING_DIR/io.github.meteorsliu.speaker-alert.plist"

/bin/rm -f "$OUTPUT"
/usr/bin/hdiutil create \
    -volname "Speaker Alert" \
    -srcfolder "$STAGING_DIR" \
    -format UDZO \
    -ov \
    "$OUTPUT"
/usr/bin/hdiutil verify "$OUTPUT"

print -r -- "$OUTPUT"
