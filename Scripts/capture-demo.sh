#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
VARIANT=${DEMO_VARIANT:-light}
LANG=${DEMO_LANG:-zh}
EDGE_X=${DEMO_EDGE_X:-1918}
SOURCE=${DEMO_SOURCE:-"$ROOT/docs/assets/demo-source/$VARIANT"}
TRIAL=${DEMO_TRIAL_OUT:-"$ROOT/Artifacts/orbpeek-demo/trial-window"}

capture_window() {
    # Window-ID capture only: never records desktop regions or other apps.
    peekaboo see --mode window --window-id "$1" --retina --no-elements \
        --path "$2" --json >/dev/null
}

open_demo() {
    local directory=$1 binary pid title
    mkdir -p "$directory"
    binary="$ROOT/Artifacts/orbpeek-demo/demo-window"
    swiftc "$ROOT/Scripts/demo-window.swift" -o "$binary"
    "$binary" --appearance "$VARIANT" --language "$LANG" >"$directory/demo-window.log" 2>&1 &
    pid=$!
    sleep 1
    if [[ $LANG == en ]]; then title="Git Cheatsheet"; else title="Git 速查"; fi
    peekaboo window list --pid "$pid" --json | DEMO_TITLE="$title" python3 -c \
        'import json,os,sys; data=json.load(sys.stdin); matches=[w for w in data["data"]["windows"] if w.get("window_title") == os.environ["DEMO_TITLE"]]; assert len(matches)==1; print(matches[0]["window_id"])'
}

if [[ ${1:-} == "--trial" ]]; then
    WINDOW_ID=$(open_demo "$TRIAL")
    capture_window "$WINDOW_ID" "$TRIAL/normal.png"
    peekaboo window close --window-id "$WINDOW_ID" >/dev/null 2>&1 || true
    printf '%s\n' "$TRIAL/normal.png"
    exit 0
fi

if [[ ${1:-} != "--capture" ]]; then
    cat <<'EOF'
Retina trial (opens/closes only a clean demo window; no hotkey or mouse movement):
  Scripts/capture-demo.sh --trial
Formal short capture (requires an agreed desktop session):
  DEMO_VARIANT=light DEMO_LANG=zh DEMO_EDGE_X=3838 Scripts/capture-demo.sh --capture
Every capture uses an exact window ID. No desktop region is ever captured.
EOF
    exit 2
fi

pgrep -x OrbPeek >/dev/null
START=$(date +%s)
mkdir -p "$SOURCE"
ORBPID=$(pgrep -x OrbPeek)
STRIP_COUNT_BEFORE=$(swift "$ROOT/Scripts/find-orbpeek-strip.swift" "$ORBPID" --count)
WINDOW_ID=$(open_demo "$SOURCE")
capture_window "$WINDOW_ID" "$SOURCE/normal.png"

peekaboo window focus --window-id "$WINDOW_ID"
osascript -e 'tell application "System Events" to key code 124 using {control down}'
sleep 1
STRIP_ID=$(swift "$ROOT/Scripts/find-orbpeek-strip.swift" "$ORBPID")
capture_window "$STRIP_ID" "$SOURCE/docked.png"

peekaboo move --at "$EDGE_X,400" --smooth --profile linear --duration 300 --foreground &
MOVER=$!
sleep 0.2
capture_window "$WINDOW_ID" "$SOURCE/mid-peek.png"
wait "$MOVER"
sleep 0.3
capture_window "$WINDOW_ID" "$SOURCE/peeked.png"
peekaboo move --at "2400,400" --smooth --profile linear --duration 200 --foreground
sleep 1
peekaboo move --at "$EDGE_X,400" --smooth --profile linear --duration 200 --foreground
sleep 0.5
peekaboo drag --from "1500,110" --to "900,300" --duration 500 --window-id "$WINDOW_ID" --foreground
peekaboo move --at "2400,400" --smooth --profile linear --duration 200 --foreground
peekaboo window close --window-id "$WINDOW_ID" >/dev/null 2>&1 || true
rm -f "$SOURCE/demo-window.log"

STRIP_COUNT_AFTER=$(swift "$ROOT/Scripts/find-orbpeek-strip.swift" "$ORBPID" --count)
[[ $STRIP_COUNT_AFTER == "$STRIP_COUNT_BEFORE" ]] || { echo 'OrbPeek preview-strip count changed unexpectedly' >&2; exit 1; }
[[ $STRIP_COUNT_AFTER -gt $STRIP_COUNT_BEFORE ]] && { echo 'Demo strip remains' >&2; exit 1; }
printf 'capture finished in %ss; preview strips before/after=%s/%s\n' "$(( $(date +%s) - START ))" "$STRIP_COUNT_BEFORE" "$STRIP_COUNT_AFTER"
find "$SOURCE" -maxdepth 1 -name '*.png' -print | sort
