# 开发文档

环境、依赖与重建见 [SETUP.md](../SETUP.md)，项目约束见 [AGENTS.md](../AGENTS.md)。

## 模块与测试

- `OrbPeekCore`：`ScreenLayout` / `WindowGeometry` 坐标与位置计算、`ManagedWindow` 状态机，以及窗口、配置、抓图和贴边条的可注入接口。
- `OrbPeek` executable：AppKit 生命周期、菜单与设置、Accessibility、ScreenCaptureKit、全局事件和资源打包。
- `Tests/OrbPeekCoreTests` 使用 Swift Testing。布局用 `ScreenInfo` 值构造；窗口、抓图、贴边条和时钟用 fake 注入，测试不访问真实用户窗口，也不需要系统权限。

核心逻辑修改采用红绿 TDD：先运行能复现问题的测试并确认失败，再实现修复。不要为了通过测试而删除用例、降低断言或加入 skip。

## 坐标与屏幕身份

AX/CG 使用以主屏左上角为原点的 top-left 坐标；AppKit 使用 bottom-left 坐标。所有换算集中在 `WindowGeometry`。生产布局从当前 `NSScreen.screens` 创建，首项为主屏；测试直接提供 `ScreenLayout`。跨通知保留 `CGDirectDisplayID`，不保留 `NSScreen` 对象。

## 取消贴边与可见区域保底

`ManagedWindow.placeUndockedWindow` 是唯一收尾函数：用当前布局选择最近屏，将窗口完整限制在该屏的 quartz `visibleFrame`，窗口过大时先缩小再定位。

| 入口 | 路径 | 保底 |
|---|---|---|
| 菜单取消 | `cancelWindow` → `terminate(.restore)` | 是 |
| 拖离超过阈值 | `checkDragOut` → `terminate(.leave)` | 是 |
| docked 外部漂移 | `evaluate` → `terminate(.leave)` | 是 |
| peeked 外部漂移 | `evaluate` → `terminate(.leave)` | 是 |
| 抓图期间拖动/外部位移 | `finishDock` → `terminate(.leave)` | 是 |
| 最小化 / app 隐藏 | `evaluate` → `terminate(.restore)` | 是 |
| AX 读帧失败且 CGWindowList 也消失 | `evaluate` → `terminate(.restore)` | 是（best-effort） |
| SIGTERM / SIGINT | `restoreAll` → `restore` | 是 |
| 正常退出 | `applicationWillTerminate` → `restore` | 是 |

`removeManaged` 只做列表、抓图缓存和贴边条清理，不是独立取消入口。拔屏在 settling 中优先重锚到剩余屏的停靠位；若宽限后判定外部接管，则由 `.leave` 保底。

## 崩溃 / 强杀恢复

停靠意图、完成停放、peek、拖动/resize 转移和取消都会更新 `~/Library/Application Support/OrbPeek/docked-windows.json`。JSON 包含 app bundle id/pid、窗口标题、CGWindowID、恢复/停放 frame、屏幕 ID 和边；`DockStateStore` 使用 atomic write。启动时 `DockRecovery` 只处理仍存在且未完整位于任何可见屏内的窗口，并调用与正常取消相同的全局 `placeUndockedWindow`；处理后清空记录。无 AX 权限时保留记录，待权限可用后由 poll 重试。

匹配先按 bundle id 找到仍在运行的 app（支持目标 app 重启后 pid 改变），再按窗口标题和与停放 frame 的距离匹配。标题可变，因此额外把该 app 所有可见面积不足 10% 的窗口都用同一保底函数收回；无标题多窗口也走这个兜底。正常可见窗口不动。以下情况不能保证恢复：目标 app/窗口已关闭、AX 权限或 AX 写入被拒绝、磁盘写入失败。恢复不会主动重建或关闭窗口。

## 构建、签名与产物

`Scripts/build-app.sh` 是唯一的 app 组装入口：release 构建、复制可执行文件和 SPM resource bundles、编译 asset catalog、用 `DEV X` 签名。`Scripts/version.sh` 用最近 git tag 作为唯一版本来源，本地 app/DMG 和 CI 都从它取值；Info.plist 里的静态值只是模板，不再是产品版本来源。`KeyboardShortcuts` fork 的 resource-bundle 修复不能丢失，否则手工打包的设置页可能崩溃。

`make package` 和 release workflow 使用相同的 DMG 结构：app、`/Applications` 符号链接、UDZO。不要改变 `Info.plist` 中的 `com.orbpeek.OrbPeek`、`OrbPeek.app`、`OrbPeek-VERSION.dmg` 命名约定或 release secrets。

Release 说明由 `Scripts/release-notes.sh` 截取 CHANGELOG 的对应版本段，缺段或空段会失败。这个改动只替换 `gh release create` 的 notes 来源；tag 触发、DEV X 签名、DMG 资产名和 cask URL 格式均不变，因此不影响发布与 Homebrew 兼容。

发布清单：更新 CHANGELOG → `make check` → 提交并推送 main → 打 annotated `vX.Y.Z` tag 并推送 → 等 Release 和 tap 同步完成。版本无需手改 Info.plist。

## 调试入口

- `OrbPeek.app/Contents/MacOS/OrbPeek --self-test`：需要辅助功能权限，会移动再恢复当前前台窗口；自动检查不运行它。
- `--debug-mouse "t:x,y ..."`：注入确定的 top-left 鼠标位置。
- `--show-settings`：启动时打开设置。
- `Scripts/test-window.swift`：手动创建测试窗口。

不要对 `/Applications/OrbPeek.app` 或用户正在管理的窗口做自动化操作。开发日志写入 `~/Library/Logs/orbpeek.log`，不要提交日志和构建产物。

## 演示素材

演示画面全部由代码生成，不截取或录制真实桌面。`Scripts/demo/scene.html` 是一个 HTML/CSS 画的 macOS 15 场景，`Scripts/demo/render.mjs` 用 Playwright 在无头 Chromium 里按 2x 逐帧截图，再用 ffmpeg 编码。

场景里的 OrbPeek 行为按源码默认值：预览条 15 px、50% 不透明、窗口一侧 10pt 圆角、无阴影，内容是窗口对应边缘的静态截图；停 0.15 秒后出现（30Hz 轮询）；在窗口里停 0.3 秒后离开窗口外 12pt 才收回；贴边和收回前各等一次约 50ms 的抓图。滑动按 `devs/slide-anim` 的 `SlideAnimator`：截图浮层 150ms、CA easeOut，在窗口和预览条两个矩形之间缩放移动，贴边时不透明度 1→0.25、滑出时 0.65→1；真实窗口贴边时立即移走，滑出时在动画结束后到位。改了 app 行为要同步改 `scene.html` 里的常量。按键提示（⌃⇧→）和贴边后的 6 倍放大框是演示叠加层，不是 app 的界面。

```sh
node Scripts/demo/render.mjs              # 全部：zh/en × light/dark，约 20 分钟
node Scripts/demo/render.mjs dark en      # 单个变体
node Scripts/demo/shot.mjs light zh 1.5 4 # 查看某几个时间点的静帧
node Scripts/demo/preview.mjs <目录>      # 官网和 README 的预览截图，并检查安装区位置
```

输出：`site/assets/demo-<lang>-<theme>.{mp4,webm}`、`poster-*.jpg`，`docs/assets/demo-<lang>-<theme>.gif`、`hero-<lang>-<theme>.png`。中间帧在 `Artifacts/demo-frames/`（已忽略）。
