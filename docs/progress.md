# 交接日志

## 2026-11-13 — devs/normalize

- 已创建分支并拆出 `OrbPeekCore`；屏幕布局、窗口、抓图、贴边条与时钟可注入。
- 增加 `make check / run / package`、push/PR CI、SETUP 与开发文档。
- 正在按 `OrbPeek-bug-analysis.md` 做 R1/R2 红绿回归；R2-1 等用户确定产品语义，暂不修改。
- 未 push、未打 tag、未修改 release workflow、bundle id 或 DMG 命名。

## 2026-11-13 — 修复完成

- R1-1…R1-5、R2-1…R2-4 均有独立修复/回归提交；R2-1 按用户最终语义实现。
- 新增统一取消保底：最近屏 visibleFrame 内完整放置，必要时缩小；所有终止和退出恢复共用。
- 33 个 Swift Testing 用例覆盖坐标、锁屏/唤醒、慢 AX 漂移、原点变化、拔屏、拖动、docking 中断和全部取消路径。
- 状态机日志可注入，fake 测试不再写用户真实日志。
- 最终 `make check`、签名、DMG 和启动冒烟结果见交付回报。

## 2026-11-13 — 独立审查跟进

- 新增原子停靠日志与启动崩溃/SIGKILL 恢复；FakeWindow 覆盖杀进程后屏外窗口恢复、找不到窗口清记录。
- settling 的 begin 增加 10 秒上限；跨屏拖动按源屏边缘判定；贴边侧 resize 不再误判拖出。
- check CI 固定 Xcode 16.4（Swift 6 工具链含 Swift Testing）。
- 本轮不运行 app，不做真实权限/窗口操作；最终运行 `make check`。
- 启动恢复增加标题变化/无标题多窗口兜底：记录 app 的所有窗口若可见面积 <10%，全部经统一保底收回。
