#!/bin/sh
set -eu
cd "$(dirname "$0")"
swiftc Sources/*.swift -o OrbPeek
