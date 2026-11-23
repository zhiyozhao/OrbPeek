#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
if ! printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "error: Info.plist must contain a semantic release version" >&2
    exit 1
fi
if [ "${GITHUB_REF_TYPE:-}" = tag ] && [ "${GITHUB_REF_NAME:-}" != "v$version" ]; then
    echo "error: release tag does not match Info.plist version $version" >&2
    exit 1
fi
printf '%s\n' "$version"
