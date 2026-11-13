# 开发文档

环境、依赖与重建见 [SETUP.md](../SETUP.md)，项目约束见 [AGENTS.md](../AGENTS.md)。

## 模块与测试

- `OrbPeekCore`：`ScreenLayout` / `WindowGeometry` 坐标与位置计算、`ManagedWindow` 状态机，以及窗口、配置、抓图和贴边条的可注入接口。
- `OrbPeek` executable：AppKit 生命周期、菜单与设置、Accessibility、ScreenCaptureKit、全局事件和资源打包。
- `Tests/OrbPeekCoreTests` 使用 Swift Testing。布局用 `ScreenInfo` 值构造；窗口、抓图、贴边条和时钟用 fake 注入，测试不访问真实用户窗口，也不需要系统权限。

核心逻辑修改采用红绿 TDD：先运行能复现问题的测试并确认失败，再实现修复。不要为了通过测试而删除用例、降低断言或加入 skip。

## 坐标与屏幕身份

AX/CG 使用以主屏左上角为原点的 top-left 坐标；AppKit 使用 bottom-left 坐标。所有换算集中在 `WindowGeometry`。生产布局从当前 `NSScreen.screens` 创建，首项为主屏；测试直接提供 `ScreenLayout`。跨通知保留 `CGDirectDisplayID`，不保留 `NSScreen` 对象。

## 构建、签名与产物

`Scripts/build-app.sh` 是唯一的 app 组装入口：release 构建、复制可执行文件和 SPM resource bundles、编译 asset catalog、用 `DEV X` 签名。`KeyboardShortcuts` fork 的 resource-bundle 修复不能丢失，否则手工打包的设置页可能崩溃。

`make package` 和 release workflow 使用相同的 DMG 结构：app、`/Applications` 符号链接、UDZO。不要改变 `Info.plist` 中的 `com.orbpeek.OrbPeek`、`OrbPeek.app`、`OrbPeek-VERSION.dmg` 命名约定或 release secrets。

## 调试入口

- `OrbPeek.app/Contents/MacOS/OrbPeek --self-test`：需要辅助功能权限，会移动再恢复当前前台窗口；自动检查不运行它。
- `--debug-mouse "t:x,y ..."`：注入确定的 top-left 鼠标位置。
- `--show-settings`：启动时打开设置。
- `Scripts/test-window.swift`：手动创建测试窗口。

不要对 `/Applications/OrbPeek.app` 或用户正在管理的窗口做自动化操作。开发日志写入 `~/Library/Logs/orbpeek.log`，不要提交日志和构建产物。
