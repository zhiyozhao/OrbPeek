#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
version=${1#v}
if [ -z "$version" ]; then
    echo "usage: $0 <version>" >&2
    exit 2
fi
notes=$(awk -v heading="## $version" '
    $0 == heading || index($0, heading " - ") == 1 { found = 1; next }
    found && /^## / { exit }
    found { print }
    END { if (!found) exit 1 }
' CHANGELOG.md)
if [ -z "$notes" ]; then
    echo "error: CHANGELOG.md has no content for $version" >&2
    exit 1
fi
printf '%s\n' "$notes"
