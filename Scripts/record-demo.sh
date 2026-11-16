#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${DEMO_OUT:-"$ROOT/Artifacts/orbpeek-demo"}
REGION=${DEMO_REGION:-"2560,25,1280,800"}
EDGE_X=${DEMO_EDGE_X:-3838}

still() {
    peekaboo capture live --mode area --region "$REGION" --duration 100 \
        --max-frames 1 --capture-focus background --path "$OUT/stills/$1" --no-remote
}

actions() {
    mkdir -p "$OUT/stills"
    cat > "$OUT/OrbPeekDemo.txt" <<'TEXT'
OrbPeek 演示窗口

这是一个专门录制的干净窗口，不包含个人信息。
按 Control + Shift + 右方向键，把它贴到屏幕右边。
鼠标碰到预览条，窗口就会滑出来。
TEXT
    peekaboo app launch "TextEdit" --new-instance --open "$OUT/OrbPeekDemo.txt" \
        --wait-ready --wait-for-window --foreground
    peekaboo window set-bounds --app TextEdit --window-title OrbPeekDemo \
        --x 2600 --y 100 --width 900 --height 600
    sleep 2
    still 01-before

    peekaboo press ctrl+shift+right --app TextEdit --window-title OrbPeekDemo --foreground
    sleep 2
    still 02-docked

    peekaboo move --at "$EDGE_X,400" --smooth --duration 800 --foreground
    sleep 2
    still 03-peeked

    peekaboo move --at "2400,400" --smooth --duration 800 --foreground
    sleep 2
    still 04-hidden-again

    peekaboo window close --app TextEdit --window-title OrbPeekDemo
}

if [[ ${1:-} == "--actions" ]]; then
    actions
    exit 0
fi

if [[ ${1:-} != "--record" ]]; then
    cat <<'EOF'
Real-window recording requires an agreed one-minute desktop session.
Usage: DEMO_REGION="x,y,w,h" DEMO_EDGE_X=3838 Scripts/record-demo.sh --record
No user windows or cursor are touched without --record.
EOF
    exit 2
fi

pgrep -x OrbPeek >/dev/null
mkdir -p "$OUT"
# Fail closed if any current user window intersects the recording area.
swift "$ROOT/Scripts/check-demo-region.swift" "$REGION"

peekaboo capture action --mode area --region "$REGION" --capture-focus background \
    --duration-limit 30s --pre-roll 1s --post-roll 1s --action-timeout 26s \
    --resolution-cap 1280 --max-mb 15 --path "$OUT/session" \
    --video-out "$OUT/orbpeek-demo.mp4" -- "$ROOT/Scripts/record-demo.sh" --actions

test -s "$OUT/orbpeek-demo.mp4"
ls -lh "$OUT/orbpeek-demo.mp4"
find "$OUT/stills" -name '*.png' -print | sort
