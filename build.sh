#!/bin/sh
set -eu
cd "$(dirname "$0")"
swift build -c release
APP=OrbPeek.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/OrbPeek "$APP/Contents/MacOS/OrbPeek"
cp Info.plist "$APP/Contents/Info.plist"
# Ad-hoc sign so TCC permissions (Accessibility / Screen Recording) stick to a
# stable code identity across rebuilds instead of re-prompting every build.
codesign --force --sign - "$APP" >/dev/null
echo "built $APP"
