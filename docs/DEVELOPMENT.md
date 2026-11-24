# 开发文档

环境、依赖与重建见 [SETUP.md](../SETUP.md)，项目约束见 [AGENTS.md](../AGENTS.md)。

## 模块与测试

- `OrbPeekCore`：`ScreenLayout` / `WindowGeometry` 坐标与位置计算、`ManagedWindow` 状态机，以及窗口、配置、抓图和贴边条的可注入接口。
- `OrbPeek` executable：AppKit 生命周期、菜单与设置、Accessibility、ScreenCaptureKit、全局事件和资源打包。
- `Tests/OrbPeekCoreTests` 使用 Swift Testing。布局用 `ScreenInfo` 值构造；窗口、抓图、贴边条和时钟用 fake 注入，测试不访问真实用户窗口，也不需要系统权限。

核心逻辑修改采用红绿 TDD：先运行能复现问题的测试并确认失败，再实现修复。不要为了通过测试而删除用例、降低断言或加入 skip。

## 坐标与屏幕身份

AX/CG 使用以主屏左上角为原点的 top-left 坐标；AppKit 使用 bottom-left 坐标。所有换算集中在 `WindowGeometry`。每轮使用同一份不可变 `ScreenLayout`，首项为主屏；唯一 UUID 匹配同一物理屏，运行期 ID 可更新。无 UUID/UUID 重复时不按型号或尺寸猜匹配。镜像接收屏不构成独立桌面。

生产 controller 的 `DisplayLayoutCache` 保存值快照，不保存 NSScreen 对象。`DockSession` 的 screenChanged/reconfiguration begin/end、wake/unlock、会话/屏保事件通过 delegate 使缓存失效，下一次读取才重建（包括无效/零屏布局，不回退旧有效屏）；稳定基线仍由原 reconcile 流程维护。另有每2秒一次的完整布局指纹读取，比较所有字段（包括 UUID、frame、visibleFrame）防漏通知；变化后复用本次读取结果，进入原稳定等待/决策，不重复加载。门禁一次只取一份快照，稳态30Hz复用；双窗口双屏20秒600次poll实测10次采样，即0.5次布局构造/秒。原显示器规则测试也使用同一缓存；LayoutSnapshotTests 覆盖事件失效、全漏通知（含只改visibleFrame）、无效快照与计数。

「找回所有窗口」首次执行和每次排队重试都先强制刷新布局，不等待两秒守卫；新布局未稳定/会话未恢复则保留请求，允许显示条时把等待条放到在线屏，稳定后使用最新可见区域放回 managed+名单。`rescueFreshLayout` 的4组参数覆盖新请求/排队重试、managed/名单窗口。

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

`removeManaged` 只做列表、抓图缓存和贴边条清理。锁屏/睡眠/会话不活跃冻结用户窗口写入，稳定基线不被锁前瞬态覆盖。恢复时强制读取布局，与稳定基线完全一致、所有窗口原屏在线且无未结束的 CG 重配置时，立即无激活校正并恢复 hover/slam/快捷键；布局不同仍等 3 秒稳定，原屏缺失等最后相关事件后 10 秒。暂停清除未完成 hover 计时；恢复后首轮 poll 按鼠标当前位置开始正常 dwell，无需移出再进入。显示器变动只有原屏稳定消失才取消贴边并居中，不自动贴回。每台屏幕四边（含内侧边）均可贴：隐藏位选在整个桌面左侧或右侧外部，条和peek留在所属屏的所选边。相邻屏插拔、工作区边距、分辨率或主屏变化只重算位置，保留原屏原边与phase。等待期间可见贴边条保留入口，AX 写入失败不清除唯一状态。

`ReleasedWindowRecord` 保存原 handle 和实际隐藏 frame 指纹，直到关闭、手动接管或退出；每次稳定决定及之后低频检查，只有精确指纹±2pt且可见并集不足 10% 才救回，不激活/raise。用户任意其他屏外摆放不自动干预。菜单「找回所有窗口」可无视指纹手动放回 managed+名单，拖动/隐藏/AX 不可读则保留待办。

## 崩溃 / 强杀恢复

停靠意图、停放、peek、拖动/resize 转移和取消原子写入 `docked-windows.json`，记录 UUID/运行期 ID。正常退出成功放回可见位置才写 cleanExit；120 秒内重开且同窗、未移动、原屏在线时恢复，内侧边同样允许。不做旧版记录迁移。显示器释放无 pending 自动贴回意图。启动恢复等会话可用且布局有效稳定后执行；AX 枚举不可用、读帧失败、放置失败时保留 journal 待重试，不把未知当已完成。释放名单仅本进程有效，不跨重启寻找替代 handle。

匹配先按 bundle id 找到仍在运行的 app（支持目标 app 重启后 pid 改变），再按窗口标题和与停放 frame 的距离匹配。标题可变，因此额外把该 app 所有可见面积不足 10% 的窗口都用同一保底函数收回；无标题多窗口也走这个兜底。正常可见窗口不动。以下情况不能保证恢复：目标 app/窗口已关闭、AX 权限或 AX 写入被拒绝、磁盘写入失败。恢复不会主动重建或关闭窗口。

## 构建、签名与产物

`Scripts/build-app.sh` 是唯一的 app 组装入口：release 构建、复制可执行文件和 SPM resource bundles、编译 asset catalog、用 `DEV X` 签名。`Info.plist` 的 `CFBundleShortVersionString` 是版本来源，`Scripts/version.sh` 校验并读取它，本地 app/DMG 和 CI 共用；tag 发布时还必须与 `GITHUB_REF_NAME` 一致。`KeyboardShortcuts` fork 的 resource-bundle 修复不能丢失，否则手工打包的设置页可能崩溃。

`make package` 和 release workflow 使用相同的 DMG 结构：app、`/Applications` 符号链接、UDZO。不要改变 `Info.plist` 中的 `com.orbpeek.OrbPeek`、`OrbPeek.app`、`OrbPeek-VERSION.dmg` 命名约定或 release secrets。

Release 说明由 `Scripts/release-notes.sh` 截取 CHANGELOG 的对应版本段，缺段或空段会失败。这个改动只替换 `gh release create` 的 notes 来源；tag 触发、DEV X 签名、DMG 资产名和 cask URL 格式均不变，因此不影响发布与 Homebrew 兼容。

发布清单：更新 CHANGELOG → `make check` → 提交并推送 main → 打 annotated `vX.Y.Z` tag 并推送 → 等 Release 和 tap 同步完成。准备发布时先更新 Info.plist；tag 与版本不一致会停止构建。

## 调试入口

- `OrbPeek.app/Contents/MacOS/OrbPeek --self-test`：需要辅助功能权限，会移动再恢复当前前台窗口；自动检查不运行它。
- `--debug-mouse "t:x,y ..."`：注入确定的 top-left 鼠标位置。
- `--show-settings`：启动时打开设置。
- `OrbPeek.app/Contents/MacOS/OrbPeek --login-item-status`：仅打印 `SMAppService.mainApp.status` 和当前 app 路径后退出，不创建 app、读取用户设置、注册登录项、恢复窗口或请求权限。可用于确认运行的是哪一份安装；旧版本不支持此参数时，直接在“系统设置 → 通用 → 登录项”检查。
- `Scripts/test-window.swift`：手动创建测试窗口。

不要对 `/Applications/OrbPeek.app` 或用户正在管理的窗口做自动化操作。开发日志写入 `~/Library/Logs/orbpeek.log`，不要提交日志和构建产物。

## 文档素材

README 和官网不再包含滑动动画演示；移除旧的 GIF、视频及其生成脚本，避免演示和实际的直接显示/收起行为不一致。网站保留中英正文、语言切换和安装命令复制。
