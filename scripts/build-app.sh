#!/bin/zsh

set -euo pipefail

ROOT_DIR=${0:A:h:h}
BUILD_DIR=${1:-"$ROOT_DIR/build"}
APP_DIR="$BUILD_DIR/Speaker Alert.app"

/bin/rm -rf "$APP_DIR"
/bin/mkdir -p "$APP_DIR/Contents/MacOS"
/bin/cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

/usr/bin/xcrun swiftc \
    -warnings-as-errors \
    -O \
    -framework Accelerate \
    -framework CoreAudio \
    "$ROOT_DIR/Sources/SpeakerAlert/main.swift" \
    -o "$APP_DIR/Contents/MacOS/SpeakerAlert"

/usr/bin/codesign \
    --force \
    --deep \
    --sign - \
    --identifier io.github.meteorsliu.speaker-alert \
    "$APP_DIR"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_DIR"
/usr/bin/plutil -lint "$APP_DIR/Contents/Info.plist"

print -r -- "$APP_DIR"
