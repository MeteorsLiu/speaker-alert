#!/bin/zsh

set -euo pipefail

SOURCE_DIR=${0:A:h}
SOURCE_APP="$SOURCE_DIR/Speaker Alert.app"
SOURCE_AGENT="$SOURCE_DIR/io.github.meteorsliu.speaker-alert.plist"
INSTALL_DIR="$HOME/Applications"
INSTALL_APP="$INSTALL_DIR/Speaker Alert.app"
INSTALL_AGENT="$HOME/Library/LaunchAgents/io.github.meteorsliu.speaker-alert.plist"
SERVICE="gui/$(/usr/bin/id -u)/io.github.meteorsliu.speaker-alert"

if [[ ! -d "$SOURCE_APP" || ! -f "$SOURCE_AGENT" ]]; then
    print -u2 "Speaker Alert installer files are incomplete."
    exit 1
fi

if /bin/launchctl print "$SERVICE" >/dev/null 2>&1; then
    /bin/launchctl bootout "$SERVICE"
fi

/bin/mkdir -p "$INSTALL_DIR" "${INSTALL_AGENT:h}"
/bin/rm -rf "$INSTALL_APP"
/usr/bin/ditto "$SOURCE_APP" "$INSTALL_APP"
/usr/bin/install -m 0644 "$SOURCE_AGENT" "$INSTALL_AGENT"
/usr/bin/plutil -replace ProgramArguments.0 \
    -string "$INSTALL_APP/Contents/MacOS/SpeakerAlert" \
    "$INSTALL_AGENT"

/usr/bin/codesign --verify --deep --strict "$INSTALL_APP"
/usr/bin/plutil -lint "$INSTALL_AGENT"
/bin/launchctl bootstrap "gui/$(/usr/bin/id -u)" "$INSTALL_AGENT"

print "Speaker Alert installed and started."
print "Allow system audio capture when macOS asks for permission."
