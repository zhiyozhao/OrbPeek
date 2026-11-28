# 更新记录

## 1.1.4 - 2026-11-28

### 改进 / Improved

- 锁屏、睡眠时保持窗口原位，恢复后等待显示器就绪；只有窗口所属屏幕持续离线才取消贴边并居中，屏幕接回后不自动贴回，相邻屏插拔仍保持原边贴边。新增「找回所有窗口」菜单；预览截图更准确、更稳定，桌宠不再挡住截图，截图失败时保留旧图或显示应用图标和名称，收起不再等待截图，并降低持续贴边时的 CPU 占用。
- Windows stay in place while locked or asleep and wait for displays on resume; only a window's own display staying offline undocks and centers it, without docking again when that display returns. Connecting adjacent displays keeps docks intact. Added “Bring Back All Windows”; previews are more accurate and reliable, desktop pets no longer block them, unavailable captures keep the last image or show the app's icon and name, hiding no longer waits for a screenshot, and keeping windows docked uses less CPU.

## 1.1.3 - 2026-11-23

### 改进 / Improved

- 新安装的默认快捷键改为 ⌃⌘ + 方向键（Control + Command）；已经保存过的快捷键保持不变。
- New installations use ⌃⌘ + arrow keys (Control + Command) by default. Previously saved shortcuts stay unchanged.

### 文档 / Documentation

- 重做中英 README 和官网，新增四边贴窗演示视频。
- Redesigned the Chinese and English README and website, with new demos of windows docked to all four edges.

## 1.1.2 - 2026-11-23

### 修复 / Fixed

- 修复多显示器、锁屏、睡眠和拔掉显示器时，窗口丢失、预览条不可见或位置错乱的问题。**1.1.0 的多显示器修复并不完整**，本版补齐了晚到屏、主屏变化和不同屏幕高度等场景。
- 所在的显示器稳定离线后，取消贴边并将窗口放到剩余屏幕中间。锁屏或睡眠后，同一块屏幕回来时恢复原来的屏幕、边和位置；醒屏较慢时可能先临时居中，原屏在 2 分钟内回来且窗口未被移动或调整大小时自动贴回。
- 正常退出后 2 分钟内重开，按窗口身份与位置核对后重新贴边，避免重复管理或把用户已移动的窗口拽走。Homebrew 更新不会自动重开 app。
- Fixed lost windows, invisible preview strips and incorrect positions across multiple displays, screen locking, sleep and display disconnection. **The multi-display fixes in 1.1.0 were incomplete**; this release also handles slow displays, primary-display changes and displays of different heights.
- When the owning display stays offline, windows are undocked and centered on a remaining display. After lock or sleep, they return to their original display, edge and position. A slow display may cause temporary centering; unchanged windows dock back if it returns within 2 minutes.
- Reopening within 2 minutes of a normal quit restores docks after checking window identity and position, without duplicate managers or moving windows the user has changed. Homebrew updates do not reopen the app automatically.

### 新增 / Added

- 新增只读参数 `--login-item-status`，打印 `SMAppService.mainApp.status` 和当前 app 路径后退出；不会注册登录项、初始化窗口管理或请求权限。
- Added `--login-item-status`: prints `SMAppService.mainApp.status` and the current app path, then exits without registering a login item, initializing window management or requesting permissions.

### 文档 / Documentation

- 更新中英 README 和官网，移除滑动动画说明及演示。窗口直接显示或收起；屏幕录制只用于预览条截图。
- Updated the Chinese and English README and website; removed slide-animation descriptions and demos. Windows appear or hide directly; Screen Recording is used only for preview-strip images.

## 1.1.1 - 2026-11-16

### 改进

- 菜单显示当前版本。
- 权限说明更清楚：辅助功能授权无需重启，屏幕录制请求前说明用途，未授权快捷键会给出提示。
- 预览条连续超时后才谨慎重启系统录屏进程，并增加冷却时间。
- Homebrew zap 会清理崩溃恢复数据和旧配置。

## 1.1.0 - 2026-11-16

### 修复

- 插拔或重排显示器、解锁和唤醒后，贴边窗口会跟随当前屏幕布局，不再乱跑或被误取消。
- 拖动后保留窗口的新位置；短拖或拖到屏幕外会贴回，沿边拖到另一台显示器可继续在同侧贴边，向屏幕内拖远则取消贴边。
- 取消贴边或退出时，窗口会完整回到可见区域；窗口过大时会先缩小，不再留在屏幕外。
- 意外退出或被强制结束后，下次启动会找回仍然打开的屏外窗口；窗口标题变化后也能识别。
