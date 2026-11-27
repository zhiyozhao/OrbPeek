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

`removeManaged` 只做列表、抓图缓存和贴边条清理，不是独立取消入口。拔屏先 settling 观察；原屏稳定离线后走 `.offline`，居中放到剩余屏并 raise/activate。同屏在解锁前回来则不解除。

## 崩溃 / 强杀恢复

停靠意图、完成停放、peek、拖动/resize 转移和取消都会更新 `~/Library/Application Support/OrbPeek/docked-windows.json`。JSON 包含 app bundle id/pid、窗口标题、CGWindowID、恢复/停放 frame、屏幕 ID 和边；`DockStateStore` 使用 atomic write。崩溃启动恢复处理屏外窗口并调用全局 `placeUndockedWindow`；正常退出额外写入 `cleanExit/exitedAt`，启动在 120 秒内按原边重新 dock，过期丢弃。journal 在动作前清空，避免覆盖新写入。无 AX 权限时保留记录，待权限可用后由 poll 重试。

匹配先按 bundle id 找到仍在运行的 app（支持目标 app 重启后 pid 改变），再按窗口标题和与停放 frame 的距离匹配。标题可变，因此额外把该 app 所有可见面积不足 10% 的窗口都用同一保底函数收回；无标题多窗口也走这个兜底。正常可见窗口不动。以下情况不能保证恢复：目标 app/窗口已关闭、AX 权限或 AX 写入被拒绝、磁盘写入失败。恢复不会主动重建或关闭窗口。

## 构建、签名与产物

预览条只用display合成像素，不能用window-only替代圆角/半透明后的肉眼效果。`CaptureVisibility`按CGWindowList真实前后顺序验证完整窗口未被普通窗口遮挡（忽略并过滤自身条与装饰浮层，普通层级的半透明覆盖仍拒绝），截图前后校验frame/层级，整窗必须在精确display内。来源是最新合成图→同窗口同尺寸缓存→带应用图标与名称的身份占位。初次贴边拍可见画面，peek后独立任务补拍；peek失败只在可见时1/4/15秒有限重试。稳定优先：peek收起直接用已取得的缓存/身份条，不再为“最后一帧”请求或等待截图，取消尚未结束的补拍也不join。抓图等待中的条支持hover/slam，取消旧transition后不会晚到隐藏窗口；peek的补拍任务只更新缓存，不移动窗口。启动恢复不能为截图激活或闪现，无遮挡即可截，被挡则保留占位等首次peek；隐藏期间不定时刷新，新消息不实时更新。所有SCK调用继续走有界截止及原replayd门禁。

截图由`CapturePipeline`协调，`ScreenCaptureService`只提供非MainActor的SCK显示器区域截图适配；测试注入假content与假image闭包，不访问桌面。显示器begin/end、screen parameters及wake/unlock/会话恢复清缓存，失败重取content重试一次；displayID必须精确匹配，记录SCK错误domain/code。generation隔离失效期间的旧结果；continuation竞争的0.5秒枚举/0.3秒截图截止不等待取消失效的底层任务，最多两次尝试。底层请求预算8个，超出即失败；正常失败不重启replayd，连续3次逻辑截图最终超时才允许重启、5分钟冷却。预热同样有界但不影响重启计数。

装饰浮层不是普通遮挡：只由layer=0、alpha>0且非Dock/Control Center/SystemUIServer的普通窗口阻挡。Pets Therapy实测整屏layer3、alpha1、sharingState0，alpha不是像素透明度；sharingState是共享权限，不能判断可见性，ignoresMouseEvents无公开跨进程读取API。`CaptureFilterPlan`与门禁共用分类；每次实际截图重读当前CG列表，SCK排除相关装饰所属app并通过exceptingWindows重新包含它的普通窗口（或在无app条目时逐窗排除），避免误删同app设置窗/内容。自身始终排除，桌面backing保留；新浮层/普通例外不在旧SCK枚举里则报错走既有fresh retry。截图仍是显示器合成，只去掉浮在上面的装饰，保留目标阴影/圆角及底层背景；不声称含装饰的最终桌面逐像素一致。layer0点击穿透但alpha>0的第三方覆盖层不能可靠公开识别，保守当普通遮挡；非0层的真实浮动面板也按产品规则移除。

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
