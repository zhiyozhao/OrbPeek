#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
VARIANT=${DEMO_VARIANT:-light}
LANG=${DEMO_LANG:-zh}
EDGE_X=${DEMO_EDGE_X:-3838}
SOURCE=${DEMO_SOURCE:-"$ROOT/docs/assets/demo-source/$VARIANT"}
TRIAL=${DEMO_TRIAL_OUT:-"$ROOT/Artifacts/orbpeek-demo/trial-window"}

capture_window() {
    # Window-ID capture only: never records desktop regions or other apps.
    peekaboo see --mode window --window-id "$1" --retina --no-elements \
        --path "$2" --json >/dev/null
}

open_demo() {
    local directory=$1 filename
    mkdir -p "$directory"
    if [[ $LANG == en ]]; then
        filename="Git Cheatsheet.rtf"
        cat > "$directory/demo.html" <<'HTML'
<meta charset="utf-8"><style>body{font:14px -apple-system}h1{font-size:26px}h2{font-size:17px;margin:16px 0 6px}table{border-spacing:0}td{padding:3px 18px 3px 0}td:first-child{font-family:Menlo;font-size:13px;white-space:nowrap}</style>
<h1>Git Cheatsheet</h1>
<h2>View</h2><table><tr><td>git status</td><td>Working tree changes</td></tr><tr><td>git log --oneline</td><td>Commit history</td></tr><tr><td>git diff</td><td>Unstaged changes</td></tr></table>
<h2>Branches</h2><table><tr><td>git switch -c &lt;name&gt;</td><td>Create and switch</td></tr><tr><td>git branch -d &lt;name&gt;</td><td>Delete a branch</td></tr></table>
<h2>Undo</h2><table><tr><td>git restore &lt;file&gt;</td><td>Discard working tree changes</td></tr><tr><td>git restore --staged &lt;file&gt;</td><td>Unstage</td></tr><tr><td>git commit --amend</td><td>Amend the last commit</td></tr></table>
<h2>Remote</h2><table><tr><td>git fetch</td><td>Fetch updates</td></tr><tr><td>git pull --rebase</td><td>Pull and rebase</td></tr><tr><td>git push</td><td>Push</td></tr></table>
HTML
    else
        filename="Git 速查.rtf"
        cat > "$directory/demo.html" <<'HTML'
<meta charset="utf-8"><style>body{font:14px -apple-system}h1{font-size:26px}h2{font-size:17px;margin:16px 0 6px}table{border-spacing:0}td{padding:3px 18px 3px 0}td:first-child{font-family:Menlo;font-size:13px;white-space:nowrap}</style>
<h1>Git 速查</h1>
<h2>查看</h2><table><tr><td>git status</td><td>当前改动</td></tr><tr><td>git log --oneline</td><td>提交历史</td></tr><tr><td>git diff</td><td>未暂存的改动</td></tr></table>
<h2>分支</h2><table><tr><td>git switch -c &lt;名称&gt;</td><td>新建并切换</td></tr><tr><td>git branch -d &lt;名称&gt;</td><td>删除分支</td></tr></table>
<h2>撤销</h2><table><tr><td>git restore &lt;文件&gt;</td><td>丢弃工作区改动</td></tr><tr><td>git restore --staged &lt;文件&gt;</td><td>取消暂存</td></tr><tr><td>git commit --amend</td><td>修改上一次提交</td></tr></table>
<h2>远程</h2><table><tr><td>git fetch</td><td>获取更新</td></tr><tr><td>git pull --rebase</td><td>拉取并变基</td></tr><tr><td>git push</td><td>推送</td></tr></table>
HTML
    fi
    textutil -convert rtf "$directory/demo.html" -output "$directory/$filename"
    peekaboo app launch "TextEdit" --new-instance --open "$directory/$filename" \
        --wait-ready --wait-for-window --foreground >/dev/null
    local pid
    pid=$(pgrep -n TextEdit)
    local window_id
    window_id=$(peekaboo window list --pid "$pid" --json | DEMO_FILENAME="$filename" python3 -c \
        'import json,os,sys; data=json.load(sys.stdin); matches=[w for w in data["data"]["windows"] if w.get("window_title") == os.environ["DEMO_FILENAME"]]; assert len(matches)==1; print(matches[0]["window_id"])')
    peekaboo window set-bounds --window-id "$window_id" --x 100 --y 100 --width 900 --height 650 >/dev/null
    printf '%s\n' "$window_id"
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
  DEMO_VARIANT=light DEMO_LANG=zh DEMO_EDGE_X=3838 Scripts/capture-demo.sh --capture
Every capture uses an exact window ID. No desktop region is ever captured.
EOF
    exit 2
fi

pgrep -x OrbPeek >/dev/null
mkdir -p "$SOURCE"
WINDOW_ID=$(open_demo "$SOURCE")
capture_window "$WINDOW_ID" "$SOURCE/normal.png"

peekaboo press ctrl+shift+right --window-id "$WINDOW_ID" --foreground
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
