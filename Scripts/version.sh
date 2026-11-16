#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
tag=$(git describe --tags --abbrev=0)
version=${tag#v}
if [ -z "$version" ]; then
    echo "error: latest git tag has no version" >&2
    exit 1
fi
printf '%s\n' "$version"
