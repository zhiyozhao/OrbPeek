#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
VARIANT=${DEMO_VARIANT:-light}
REGION=${DEMO_REGION:-"2560,25,1280,800"}
EDGE_X=${DEMO_EDGE_X:-3838}
SOURCE=${DEMO_SOURCE:-"$ROOT/docs/assets/demo-source/$VARIANT"}
TRIAL=${DEMO_TRIAL_OUT:-"$ROOT/Artifacts/orbpeek-demo/trial-$VARIANT"}

still() {
    local name=$1 directory=$2
    mkdir -p "$directory"
    peekaboo capture live --mode area --region "$REGION" --duration 100 \
        --max-frames 1 --resolution-cap 2560 --capture-focus background \
        --path "$directory/$name-session" --no-remote
    local image
    image=$(find "$directory/$name-session" -type f \( -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' \) | sort | tail -1)
    test -n "$image"
    cp "$image" "$directory/$name.png"
}

if [[ ${1:-} == "--trial" ]]; then
    swift "$ROOT/Scripts/check-demo-region.swift" "$REGION"
    still trial "$TRIAL"
    find "$TRIAL" -maxdepth 1 -name 'trial.png' -print
    exit 0
fi

if [[ ${1:-} != "--capture" ]]; then
    cat <<'EOF'
Privacy-safe trial (no window or cursor changes):
  DEMO_REGION="x,y,w,h" Scripts/capture-demo.sh --trial
Formal 8-second capture (requires an agreed desktop session):
  DEMO_VARIANT=light DEMO_REGION="x,y,w,h" DEMO_EDGE_X=3838 Scripts/capture-demo.sh --capture
Run once per appearance. Source images are saved under docs/assets/demo-source/.
EOF
    exit 2
fi

pgrep -x OrbPeek >/dev/null
swift "$ROOT/Scripts/check-demo-region.swift" "$REGION"
mkdir -p "$SOURCE"
still background "$SOURCE"

cat > "$SOURCE/OrbPeekDemo.txt" <<'TEXT'
OrbPeek 演示窗口

这是一个专门演示的干净窗口，不包含个人信息。
按 Control + Shift + 右方向键，把它贴到屏幕右边。
鼠标碰到预览条，窗口就会滑出来。
TEXT
peekaboo app launch "TextEdit" --new-instance --open "$SOURCE/OrbPeekDemo.txt" \
    --wait-ready --wait-for-window --foreground
peekaboo window set-bounds --app TextEdit --window-title OrbPeekDemo \
    --x 2600 --y 100 --width 900 --height 600
sleep 1
still normal "$SOURCE"

peekaboo press ctrl+shift+right --app TextEdit --window-title OrbPeekDemo --foreground
sleep 1
still docked "$SOURCE"

peekaboo move --at "$EDGE_X,400" --smooth --duration 400 --foreground
sleep 1
still peeked "$SOURCE"
peekaboo move --at "2400,400" --smooth --duration 300 --foreground
peekaboo window close --app TextEdit --window-title OrbPeekDemo

find "$SOURCE" -maxdepth 1 -name '*.png' -print | sort
