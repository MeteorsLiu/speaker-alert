# Speaker Alert

Speaker Alert monitors the actual audio samples sent to the Mac built-in
speaker. It displays a notification when the signal changes from digital
silence to non-silence and the built-in speaker is neither muted nor set to
zero volume. Raising the volume or unmuting during playback also triggers the
notification. All-zero gaps shorter than 250 milliseconds do not reset the
playback state.

It ignores headphones, USB audio devices, and other output devices. Audio
buffers are inspected locally and are never copied, recorded, or saved.

## Requirements

- macOS 14.2 or later
- Permission to capture system audio

## Install From DMG

1. Open `Speaker-Alert.dmg`.
2. Double-click `Install.command`.
3. Allow system audio capture when macOS asks.

The installer copies `Speaker Alert.app` to `~/Applications`, installs
`io.github.meteorsliu.speaker-alert.plist` in `~/Library/LaunchAgents`, and starts the
LaunchAgent immediately.

Release DMGs are ad-hoc signed because the repository does not contain a
Developer ID certificate or Apple notarization credentials. macOS may require
manual approval before running a downloaded build.

## Build

```sh
./scripts/build-dmg.sh
```

The DMG is written to `dist/Speaker-Alert.dmg`.

Pushing any Git tag builds the DMG in GitHub Actions, creates a release with
the same tag, and uploads `Speaker-Alert.dmg` as a release asset.
