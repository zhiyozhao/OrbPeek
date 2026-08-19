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
# localizations) go in Contents/Resources — the only codesign-sealable place.
# Our KeyboardShortcuts fork resolves them from there (the stock SwiftPM
# accessor only probes the .app root, which codesign forbids).
mkdir -p "$APP/Contents/Resources"
for bundle in .build/release/*.bundle; do
    [ -e "$bundle" ] || continue
    cp -R "$bundle" "$APP/Contents/Resources/"
done
# Compile the asset catalog (app icon + menu-bar template icon) into
# Assets.car — the canonical Apple pipeline; icon scale/template metadata
# lives in the catalog, not in code. --app-icon + --output-partial-info-plist
# are REQUIRED or actool silently skips the appiconset entirely.
xcrun actool --compile "$APP/Contents/Resources" --platform macosx \
    --minimum-deployment-target 14.0 --app-icon AppIcon \
    --output-partial-info-plist /dev/null Resources/Assets.xcassets >/dev/null
# Sign with the stable self-signed "OrbPeek Dev" identity so TCC permissions
# (Accessibility / Screen Recording) survive rebuilds. Ad-hoc signing re-prompts
# every build because the code hash changes. Override with CODESIGN_IDENTITY
# (e.g. "-" for ad-hoc when the cert isn't available).
codesign --force --sign "${CODESIGN_IDENTITY:-OrbPeek Dev}" "$APP" >/dev/null
echo "built $APP"
