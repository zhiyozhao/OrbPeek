#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# SwiftPM embeds the build directory in resource-bundle accessors. Build in a
# neutral location so distributable binaries never contain a user's home path.
BUILD_DIR=$(mktemp -d /tmp/orbpeek-build.XXXXXX)
trap 'rm -rf "$BUILD_DIR"' EXIT HUP INT TERM
cp Package.swift Package.resolved "$BUILD_DIR/"
cp -R Sources Tests "$BUILD_DIR/"
swift build --package-path "$BUILD_DIR" -c release
APP=OrbPeek.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BUILD_DIR/.build/release/OrbPeek" "$APP/Contents/MacOS/OrbPeek"
cp Info.plist "$APP/Contents/Info.plist"
# Info.plist declares the version; CI checks that its tag matches.
VERSION=$(Scripts/version.sh)
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
# SPM resource bundles of dependencies (e.g. KeyboardShortcuts' Recorder
# localizations) go in Contents/Resources — the only codesign-sealable place.
# Our KeyboardShortcuts fork resolves them from there (the stock SwiftPM
# accessor only probes the .app root, which codesign forbids).
mkdir -p "$APP/Contents/Resources"
for bundle in "$BUILD_DIR"/.build/release/*.bundle; do
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
# Always use the stable self-signed DEV X identity so TCC permissions survive
# rebuilds. Never silently fall back to ad-hoc: that changes the designated
# requirement and invalidates Accessibility / Screen Recording grants.
if ! security find-certificate -c "DEV X" >/dev/null 2>&1; then
    echo "error: DEV X signing certificate not found" >&2
    exit 1
fi
codesign --force --sign "DEV X" "$APP" </dev/null >/dev/null
echo "built $APP"
