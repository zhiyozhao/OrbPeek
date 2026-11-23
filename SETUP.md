# SETUP — OrbPeek

## 环境

- macOS 14+ 可运行，开发与 CI 使用 macOS 15。
- Xcode 16+；本机使用 Xcode 26.3 / Swift 6.2.4。
- SwiftPM 自动获取 `zhiyozhao/KeyboardShortcuts` 的 `2.4.0-resilient-resource-bundle` 分支，并提交 `Package.resolved`。
- 钥匙串必须有自签名代码签名证书 `DEV X`。本项目不保存证书或密码，不读取证书文件，也不回退 ad-hoc 签名。
- 不需要 brew、npm、Python、端口、模拟器或后台开发服务。

## 常用命令

```bash
make check       # plist/脚本语法检查 + Swift Testing + debug 构建
make run         # release .app + DEV X 签名；启动 5 秒冒烟后关闭本次进程
make package     # OrbPeek.app + OrbPeek-<版本>.dmg
make clean       # 清理构建产物
```

`make check` 不需要辅助功能或屏幕录制权限。`make run` 只启动仓库内构建的 `OrbPeek.app`，不会关闭或重启 `/Applications/OrbPeek.app`。交互功能的手动验证需要相应权限，但不属于自动测试。

## CI 与发布

- `.github/workflows/check.yml` 在分支 push 和 PR 的 `macos-15` runner 上执行 `make check`。
- `.github/workflows/release.yml` 仍由 `v*` tag 触发；secrets 为 `SIGNING_P12_BASE64`、`SIGNING_P12_PASSWORD`。
- 发布产物的 app 名、bundle id、DMG 命名和 Homebrew cask 接口不变。
- 版本来源是 Info.plist；tag 必须与该版本一致。`Scripts/build-app.sh` 在 `/tmp` 的独立目录编译，避免 SwiftPM 将用户路径写入发布二进制。
- 只读诊断：`OrbPeek.app/Contents/MacOS/OrbPeek --login-item-status` 打印登录项状态和当前安装路径后立即退出，不启动窗口管理或请求授权。

## 重建与排障

```bash
make clean
rm -rf .build       # SwiftPM 缓存损坏时才需要
make check
make package
```

- 找不到 `Testing`：确认 `xcode-select -p` 指向完整 Xcode，而非仅 Command Line Tools。
- 签名失败：`security find-certificate -c "DEV X"` 应能找到证书；缺失时停止，不要改用 ad-hoc。
- 如出现系统密码或授权弹窗，立即停止并回报，不重试、不代替用户授权。
- 运行日志在 `~/Library/Logs/orbpeek.log`。
- 崩溃恢复日志在 `~/Library/Application Support/OrbPeek/docked-windows.json`，由 app 原子写入；正常取消/退出及启动恢复后自动清除，不需要手工维护。

## 本项目额外安装

无。
