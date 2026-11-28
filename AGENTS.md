# OrbPeek

macOS 菜单栏 app：把前台窗口停靠到屏幕边缘，悬停预览条时显示窗口。SwiftPM executable + `OrbPeekCore` library，macOS 14+，无 Xcode 工程。

## 命令与完成定义

- `make check`：plist/脚本静态检查、Swift Testing、debug 构建；必须退出 0 且测试数大于 0。
- `make run`：release 组装和 DEV X 签名，启动 5 秒冒烟后只关闭本次仓库内进程。
- `make package`：复用 `Scripts/build-app.sh` 和发布 DMG 结构，产出 `OrbPeek.app`、`OrbPeek-<版本>.dmg`。
- 环境、重建、CI 见 `SETUP.md`；模块与调试说明见 `docs/DEVELOPMENT.md`。
- 核心逻辑红绿 TDD；完成前 `make check` 全绿、更新 `docs/progress.md` 并提交。测试不用固定 sleep，不删测试或加 skip 来求绿。
- 不安装全局工具，不 push、打 tag、改 GitHub 设置或读取签名证书文件；这些边界上报 Devs。

## 模块与可测试性

- `Sources/OrbPeekCore`：布局/坐标、`DisplaySettling`、`ManagedWindow`、原子停靠日志与崩溃恢复、依赖协议。
- `Sources/OrbPeek`：app 生命周期、菜单/设置、AX、ScreenCaptureKit、SnapshotStrip、资源。
- 屏幕、窗口、抓图、贴边条和时钟必须可注入；单元测试用 fake，不访问真实窗口，不需要辅助功能或屏幕录制权限。
- `WindowHandle` 是状态机唯一窗口接口；`AXWindow` 在 app 壳实现。跨 target 的 API 用 `package` 可见性。

## 状态机与坐标不变量

- `OrbPeekController`、`ManagedWindow`、`SliceCapturer` 和 delegate 都是 `@MainActor`；非隔离事件通过 `Task { @MainActor in ... }` 进入。
- phase 只能在 transition 中改变：idle / docking / docked / peeked。每个窗口最多一个 transition Task，新 transition 取消旧任务并检查 `Task.isCancelled`。
- AX/CG 是 top-left，原点是**主屏**左上角；AppKit 是 bottom-left。所有换算只在 `WindowGeometry`，桌面并集仅用于选择隐藏停放的左右外缘。
- 生产布局从 `NSScreen.screens` 构造不可变值快照，按显示器/会话恢复事件失效后惰性重建；每2秒读完整布局指纹防漏通知，变动后走原稳定决策。「找回所有窗口」每次执行/排队重试都强制刷新。稳态 poll/写入门禁复用，不逐次查询 CG UUID/镜像关系；首项主屏，镜像接收屏不单独算桌面。屏幕身份用唯一 display UUID，CGDirectDisplayID 仅用于运行期寻屏；无可靠 UUID 时保守按 ID，不用尺寸/名称猜同屏。不长期保存 NSScreen，不用随焦点变化的 NSScreen.main。
- `perp` 和 restore origin 存为相对停靠屏 quartz visibleFrame 的偏移；原屏掉线时保留 ID，不用 fallback 屏覆盖。
- CG display reconfiguration 的 begin callback 暂停窗口自动写入，结束后等 3 秒稳定；归属屏缺失的最终决定等最后相关事件后 10 秒。锁屏/睡眠/会话 inactive 独立冻结所有自动写入，基线取最后稳定快照；恢复时强制读取布局，完全一致且原屏在线、无未完成重配置就立即恢复交互，否则继续稳定等待。暂停清除 hover 计时，恢复首轮按鼠标当前位置重新计时。原屏离线期间禁止 fallback re-anchor。零屏/无效几何不作最终决定。
- 外部漂移释放在 AX 读取后用注入时钟计时，docked 和 peeked 都有 0.5 秒宽限；宽限中不改写 `perp`。
- 实体左键状态是拖动兜底，防止漏事件导致拖动中隐藏或 gesture 卡死。抓图后如窗口已移动或左键按下，放弃停放并留在原处。
- 拖动松手：同轴保留新位置；短拖/屏外拖立即贴回；沿边到另一屏用源屏距离识别并转移同侧停靠；向内超过 40px 取消。同轴热键 re-dock 不得用旧 restoreFrame 重置当前位置。贴边侧 resize 不是 drag-out，更新大小后保持贴边。
- 所有取消、释放、退出、信号和启动崩溃恢复共用全局 placeUndockedWindow，过大则缩小。显示器变动只有原屏稳定离线才取消贴边、居中，不自动贴回。每台显示器四边（含内侧边）均可贴；其他屏插拔只重算隐藏位与条，保留原屏原边。释放名单只在精确旧隐藏位±2pt且可见面积并集<10%时救回，不激活；任意屏外位置不自动救回。菜单「找回所有窗口」手动救回 managed+名单。正常退出两分钟内重开是独立例外，须同窗/未移动/原屏在线；不做旧版记录迁移。
- 停靠状态每次变化原子写入 Application Support 的 `docked-windows.json`；正常取消/退出清除。启动恢复仍存在的屏外窗口后清除；无 AX 权限时保留记录等待恢复。找不到窗口不得误动其他窗口。
- 隐藏位仍在桌面左右外缘留 1px；隐藏 re-dock 不移动回屏内抓图，使用缓存或带应用图标/名称的占位条。只抓完整在线且实际普通窗口层级未遮挡的 display-region，抓前/后都检查；不以 frontmost 代替遮挡。layer非0/alpha0/系统装饰不阻挡且从SCK合成过滤，但明确目标windowID即使非0层也保留，同app的普通窗口保留，桌面背景保留；跨进程无法公开查询ignoresMouseEvents，不按sharingState猜透明。初贴边和peek可见时补拍，失败只在可见期间按1/4/15秒有限重试；peek收起只读缓存，绝不再请求/等待截图，隐藏期间无定时截图。禁止改成 window-filter。
- `replayd` 是共享系统录屏进程：仅连续 3 次真实抓图超时后重启，冷却 5 分钟并写日志；普通失败不得触发 `killall`。
- 锁屏冻结 poll，避免 AX blackout 被误判为窗口关闭；退出/信号恢复所有窗口。
- 条身份仅在创建时读取；AX frame/前台PID只在同步poll内缓存，写入后作废，退出poll清空，禁止跨await或下一轮复用。维持30Hz hover与全部安全门禁；性能对比区分只读重放与用户真实实例，不以模拟CPU冒充换包后CPU。previewCapture通过generation保护的defer释放槽位，旧任务不清新槽。

## 打包与发布（不可破坏）

- bundle id `com.orbpeek.OrbPeek`、app 名 `OrbPeek.app`、DMG `OrbPeek-VERSION.dmg`、`v*` tag 发布、Homebrew cask `zhiyozhao/homebrew-tap` 的 `orbpeek` 接口保持不变。
- 本地和 CI 都只用钥匙串中的自签名 **DEV X**；找不到证书直接失败，禁止 ad-hoc 回退。release secrets 仍是 `SIGNING_P12_BASE64`、`SIGNING_P12_PASSWORD`。
- 发布仍走 `.github/workflows/release.yml`，不要在开发循环中打 tag；本地与 CI 都由 `Scripts/version.sh` 读取 Info.plist 的版本，tag 必须与它一致。release 在中性临时目录构建。
- 禁止运行会弹系统密码或授权框的工具。登录项只用 `--login-item-status` 只读诊断，不注册服务、不打开设置、不请求权限。
- 依赖固定为 `zhiyozhao/KeyboardShortcuts` 的 `2.4.0-resilient-resource-bundle` 分支。其 `Contents/Resources` bundle 查找补丁是手工打包不崩溃的关键，不得直接换回 upstream。
- `Scripts/build-app.sh` 必须复制 SPM bundles 到 `Contents/Resources` 并用 `actool` 编译资产。图标只由 `Scripts/make-icon.swift` 生成，菜单图标依赖 `template-rendering-intent`。
- UI 字符串继续中英双语并通过 `tr()`；不要绕过 `L10n.swift` 的手工 bundle 加载。菜单中文文案保持中文。
