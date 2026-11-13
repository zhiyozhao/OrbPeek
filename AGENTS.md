# OrbPeek

macOS 菜单栏 app：把前台窗口停靠到屏幕边缘，悬停贴边条时滑出。SwiftPM executable + `OrbPeekCore` library，macOS 14+，无 Xcode 工程。

## 命令与完成定义

- `make check`：plist/脚本静态检查、Swift Testing、debug 构建；必须退出 0 且测试数大于 0。
- `make run`：release 组装和 DEV X 签名，启动 5 秒冒烟后只关闭本次仓库内进程。
- `make package`：复用 `Scripts/build-app.sh` 和发布 DMG 结构，产出 `OrbPeek.app`、`OrbPeek-<版本>.dmg`。
- 环境、重建、CI 见 `SETUP.md`；模块与调试说明见 `docs/DEVELOPMENT.md`。
- 核心逻辑红绿 TDD；完成前 `make check` 全绿、更新 `docs/progress.md` 并提交。测试不用固定 sleep，不删测试或加 skip 来求绿。
- 不安装全局工具，不 push、打 tag、改 GitHub 设置或读取签名证书文件；这些边界上报 Devs。

## 模块与可测试性

- `Sources/OrbPeekCore`：`ScreenLayout`、`WindowGeometry`、`DisplaySettling`、`ManagedWindow` 和依赖协议。
- `Sources/OrbPeek`：app 生命周期、菜单/设置、AX、ScreenCaptureKit、SnapshotStrip、资源。
- 屏幕、窗口、抓图、贴边条和时钟必须可注入；单元测试用 fake，不访问真实窗口，不需要辅助功能或屏幕录制权限。
- `WindowHandle` 是状态机唯一窗口接口；`AXWindow` 在 app 壳实现。跨 target 的 API 用 `package` 可见性。

## 状态机与坐标不变量

- `OrbPeekController`、`ManagedWindow`、`SliceCapturer` 和 delegate 都是 `@MainActor`；非隔离事件通过 `Task { @MainActor in ... }` 进入。
- phase 只能在 transition 中改变：idle / docking / docked / peeked。每个窗口最多一个 transition Task，新 transition 取消旧任务并检查 `Task.isCancelled`。
- AX/CG 是 top-left，原点是**主屏**左上角；AppKit 是 bottom-left。所有换算只在 `WindowGeometry`，桌面并集仅用于选择隐藏停放的左右外缘。
- 生产布局从当前 `NSScreen.screens` 构造，首项主屏。屏幕身份用 `CGDirectDisplayID`，不长期保存 `NSScreen`；回退用主屏，不用会随焦点变化的 `NSScreen.main`。
- `perp` 和 restore origin 存为相对停靠屏 quartz visibleFrame 的偏移；原屏掉线时保留 ID，不用 fallback 屏覆盖。
- CG display reconfiguration 的 begin callback 立即 settling，结束后延长 3 秒；解锁和 wake 也重新开始 3 秒 settling。
- 外部漂移释放在 AX 读取后用注入时钟计时，docked 和 peeked 都有 0.5 秒宽限；宽限中不改写 `perp`。
- 实体左键状态是拖动兜底，防止漏事件导致拖动中隐藏或 gesture 卡死。抓图后如窗口已移动或左键按下，放弃停放并留在原处。
- 拖动松手：同轴保留新位置；短拖/屏外拖立即贴回；沿边到另一屏则转移同侧停靠；向内超过 40px 取消。同轴热键 re-dock 不得用旧 restoreFrame 重置当前位置。
- 所有取消、释放、退出和信号恢复必须共用 `placeUndockedWindow`：最近屏可见区域内完整放置，过大则缩小。拔屏时 settling 内重锚到剩余屏；若最终释放也走同一保底。
- 隐藏位仍在桌面左右外缘留 1px；隐藏 re-dock 不移动回屏内抓图，使用缓存或占位条。只抓 frontmost 窗口的 display-region，禁止改成 window-filter。
- 锁屏冻结 poll，避免 AX blackout 被误判为窗口关闭；退出/信号恢复所有窗口。

## 打包与发布（不可破坏）

- bundle id `com.orbpeek.OrbPeek`、app 名 `OrbPeek.app`、DMG `OrbPeek-VERSION.dmg`、`v*` tag 发布、Homebrew cask `zhiyozhao/homebrew-tap` 的 `orbpeek` 接口保持不变。
- 本地和 CI 都只用钥匙串中的自签名 **DEV X**；找不到证书直接失败，禁止 ad-hoc 回退。release secrets 仍是 `SIGNING_P12_BASE64`、`SIGNING_P12_PASSWORD`。
- 发布仍走原 `.github/workflows/release.yml`，不要在开发循环中打 tag；版本由 CI 从 tag 写入 Info.plist。
- 依赖固定为 `zhiyozhao/KeyboardShortcuts` 的 `2.4.0-resilient-resource-bundle` 分支。其 `Contents/Resources` bundle 查找补丁是手工打包不崩溃的关键，不得直接换回 upstream。
- `Scripts/build-app.sh` 必须复制 SPM bundles 到 `Contents/Resources` 并用 `actool` 编译资产。图标只由 `Scripts/make-icon.swift` 生成，菜单图标依赖 `template-rendering-intent`。
- UI 字符串继续中英双语并通过 `tr()`；不要绕过 `L10n.swift` 的手工 bundle 加载。菜单中文文案保持中文。
