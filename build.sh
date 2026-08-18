#!/bin/sh
set -eu
cd "$(dirname "$0")"
swift build -c release
APP=OrbPeek.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/OrbPeek "$APP/Contents/MacOS/OrbPeek"
cp Info.plist "$APP/Contents/Info.plist"
# SPM resource bundles of dependencies (e.g. KeyboardShortcuts' Recorder
# localizations). Bundle.module fatalErrors at runtime if these are missing —
# that crash only fires when the code path (settings window) is used.
mkdir -p "$APP/Contents/Resources"
for bundle in .build/release/*.bundle; do
    [ -e "$bundle" ] || continue
    cp -R "$bundle" "$APP/Contents/Resources/"
done
# Sign with the stable self-signed "OrbPeek Dev" identity so TCC permissions
# (Accessibility / Screen Recording) survive rebuilds. Ad-hoc signing re-prompts
# every build because the code hash changes. Override with CODESIGN_IDENTITY
# (e.g. "-" for ad-hoc when the cert isn't available).
codesign --force --sign "${CODESIGN_IDENTITY:-OrbPeek Dev}" "$APP" >/dev/null
echo "built $APP"
