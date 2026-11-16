#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
VARIANT=${DEMO_VARIANT:-light}
EDGE_X=${DEMO_EDGE_X:-3838}
SOURCE=${DEMO_SOURCE:-"$ROOT/docs/assets/demo-source/$VARIANT"}
TRIAL=${DEMO_TRIAL_OUT:-"$ROOT/Artifacts/orbpeek-demo/trial-window"}

capture_window() {
    # Window-ID capture only: never records desktop regions or other apps.
    peekaboo see --mode window --window-id "$1" --retina --no-elements \
        --path "$2" --json >/dev/null
}

open_demo() {
    local directory=$1
    mkdir -p "$directory"
    cat > "$directory/OrbPeekDemo.txt" <<'TEXT'
产品评审 · 会议要点

目标
让常用资料留在手边，同时减少桌面上的窗口数量。

本次进展
- 窗口可以快速贴到屏幕任意一边。
- 鼠标碰到预览条即可查看，离开后自动收回。
- 支持多台显示器分别使用。
- 异常退出后，下次启动会尝试恢复窗口。

待确认
- 调整默认快捷键，避免与其他窗口工具冲突。
- 检查较窄窗口中的文字换行。
- 验证锁屏和显示器插拔后的位置。

接口示例
GET /v1/windows/{id}
{
  "edge": "right",
  "visible": false,
  "preview": true
}

后续安排
整理公开截图，确认没有私人内容；再补齐使用说明。
TEXT
    peekaboo app launch "TextEdit" --new-instance --open "$directory/OrbPeekDemo.txt" \
        --wait-ready --wait-for-window --foreground >/dev/null
    local pid
    pid=$(pgrep -n TextEdit)
    peekaboo window list --pid "$pid" --json | python3 -c \
        'import json,sys; data=json.load(sys.stdin); matches=[w for w in data["data"]["windows"] if w.get("window_title") == "OrbPeekDemo.txt"]; assert len(matches)==1; print(matches[0]["window_id"])'
}

if [[ ${1:-} == "--trial" ]]; then
    WINDOW_ID=$(open_demo "$TRIAL")
    capture_window "$WINDOW_ID" "$TRIAL/normal.png"
    peekaboo window close --window-id "$WINDOW_ID" >/dev/null
    printf '%s\n' "$TRIAL/normal.png"
    exit 0
fi

if [[ ${1:-} != "--capture" ]]; then
    cat <<'EOF'
Retina trial (opens/closes only a clean demo window; no hotkey or mouse movement):
  Scripts/capture-demo.sh --trial
Formal short capture (requires an agreed desktop session):
  DEMO_VARIANT=light DEMO_EDGE_X=3838 Scripts/capture-demo.sh --capture
Every capture uses an exact window ID. No desktop region is ever captured.
EOF
    exit 2
fi

pgrep -x OrbPeek >/dev/null
mkdir -p "$SOURCE"
WINDOW_ID=$(open_demo "$SOURCE")
capture_window "$WINDOW_ID" "$SOURCE/normal.png"

peekaboo press ctrl+shift+right --pid "$(pgrep -n TextEdit)" --window-title OrbPeekDemo --foreground
sleep 1
STRIP_ID=$(peekaboo window list --app OrbPeek --json | python3 -c \
    'import json,sys; ws=json.load(sys.stdin)["data"]["windows"]; candidates=[w for w in ws if w.get("is_on_screen") and (w["bounds"]["width"] <= 64 or w["bounds"]["height"] <= 64)]; assert candidates, "no preview-strip window found"; print(max(candidates, key=lambda w:w["bounds"]["x"])["window_id"])')
capture_window "$STRIP_ID" "$SOURCE/docked.png"

peekaboo move --at "$EDGE_X,400" --smooth --duration 400 --foreground
sleep 1
capture_window "$WINDOW_ID" "$SOURCE/peeked.png"
peekaboo move --at "2400,400" --smooth --duration 300 --foreground
peekaboo window close --window-id "$WINDOW_ID" >/dev/null

find "$SOURCE" -maxdepth 1 -name '*.png' -print | sort
