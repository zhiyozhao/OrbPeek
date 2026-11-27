# 交接日志

## 2026-11-27 — 合入稳定优先的无截图等待收起

- 合入9daa624，保留v2完整布局门禁和隐藏位指纹；原captureRace改为新窗口的首次贴边路径（peek收起已经不截图），显式断言暂停确实在capture中触发、零写入、恢复后两窗可达且零激活。
- 最终make check 141项/36套件全绿，截图分支95项/30套件全绿；日志/tmp/orbpeek-stability-v2-check.log与/tmp/orbpeek-stability-main-check.log。历史与全路径截止专项写入外部事故报告。未真实截图/替换实例，不push/发版。

## 2026-11-27 — 合入合成预览策略

- 合入ddc44ad，保留全部v2布局/写入门禁；补拍使用同一canWriteAutomatically，pause统一取消transition与preview。新增五种暂停（锁屏/睡眠/inactive/屏保/重配置）排队截图取消及恢复测试，全程fake窗口和截图。
- 首轮make check 138项/36套件通过，追加五参数门禁定向测试通过。真实验证出现系统窗口后的停止要求仍有效，不替换用户3038实例；最终合入检查/签名产物状态见外部报告。
- 最终合入353c032后make check 140项/36套件通过，plist/脚本/debug构建全绿，无Swift warning或continuation misuse；保留全局可达不变式。make check日志/tmp/orbpeek-preview-v2-check.log。

## 2026-11-27 — 合入截图修复

- 将从main独立修复的devs/capture-fix d74acbc合入本试用分支，解决事件/会话接线冲突时保留v2的全部布局与交互规则；active/屏保结束及2秒守卫发现漏通知变化同样作废截图content。增加对应接线/守卫断言。
- main修复分支make check 85项/28套件通过；合入后make check 130项/34套件通过，包含所有显示器兜底与立即解锁回归。试用签名重建和用户授权TERM/open核验另记OrbPeek-capture-1127-report.md，不push、不发版。

## 2026-11-24 — 解锁同布局立即恢复交互

- 日志两次 unlock 到首次 slam peek 为3.344/3.224秒；v2无条件3秒settle并整轮跳过evaluate。1.1.3也有3秒settle，但期间仍evaluate hover，因此整段交互冻结是v2回归。hover本来按每轮鼠标位置判断，不是mouseEntered；没有日志证据证明必须移出再进入，不把推测当根因。
- 恢复强制读取布局，与最后稳定基线完全一致且所有原屏在线/CG重配置已结束/所有会话门禁已解除时，立即无激活校正并恢复交互。不同布局、零屏、未结束重配置保留原等待与10秒离线规则。暂停清除partial hover/slam；稳定决策完成的当轮即检查鼠标占位并开始正常dwell。
- ResumeInteractionTests覆盖四种独立暂停恢复、hover延时、slam/快捷键、停留不重入、变化布局等待、系统漂移无激活校正、未结束重配置与后续拔屏。先在旧代码得到11条失败断言（4项测试中的3项失败），静止hover原已通过；修后make check 120项/31套件全绿，原锁前31/43ms竞态改为断言解锁当下即恢复。无真实锁屏/鼠标操作，试用重建与切换证据另记项目外报告。不push、不发版。

## 2026-11-24 — 更正内侧边规则，取消旧记录迁移任务

- 用户更正：每台显示器四边均可贴，包括相邻内侧边。确认既有隐藏位在桌面左右外部、条/peek在所属屏所选边；删除内边/旧停放位进入邻屏的释放判断，只有所属屏稳定离线才因显示器变动取消。相邻屏插拔重算位置、不激活；正常退出重开也不限制外缘。
- 旧记录迁移改动未提交，已完整撤掉；不新增迁移逻辑。RULES-v2第3条、README/中英官网/开发说明及项目外报告同步。
- adjacentDisplay覆盖四边×docked/peeked共8场景的邻屏插拔；新增middleAndStackedScreens覆盖中间屏及上下屏四边，检查桌面外部隐藏位/所属屏条/peek；恢复与整夜锁屏原四边断言恢复含right内边。make check 115项测试、30套件全绿；静态检查/debug构建通过。随后按用户授权重建1.1.4试用替换当前实例，核验另记试用报告；不push、不发版。

## 2026-11-24 — 布局缓存漏通知守卫

- DisplayLayoutCache 注入时钟，每2秒完整读取布局指纹，包含 UUID/frame/visibleFrame；相同保留缓存，变化直接复用本次快照进入原稳定决策，原事件失效路径仍保留。找回所有窗口首次/排队重试均强制刷新；新布局未稳定则保留请求并把等待条放到在线屏，不用旧布局写窗口。
- 新增全漏通知的 visibleFrame/原屏消失2场景；手动找回新请求/排队请求 × managed/名单4场景；每次poll继续验证可达不变式。旧代码先出现13条失败断言；排队请求等待条缺口也先由不变式抓出2处失败，补齐后全绿。
- 600次poll/20秒、双窗口双屏的模拟计数：10次完整布局采样，稳态0.5次构造/秒，折算每秒UUID+mirror各1次（未跑真实桌面CPU探针）。make check 114项测试、30套件及静态检查/debug构建全绿；命令与证据追加项目外报告。未启动app、不操作用户进程/窗口/defaults，未push/发版。

## 2026-11-24 — 显示器规则 v2 门禁建议补强

- LegacyIncidentScenarioTests 的两个 ManagedWindow 显式注入未按鼠标，生产仍读 NSEvent.pressedMouseButtons；`swift test --skip-build --filter LegacyIncidentScenarioTests` 连续 50 次全过，日志 `/tmp/orbpeek-legacy-repeat.LtfcWl`。
- 新增独立 sleep / inactive / screensaver 三参数门禁测试：无锁屏/无重叠门禁、settling 已过，直接调用 restore/terminate/peek/add 后零写入；恢复后确认入口重新可用。逐一临时移除每个门禁时对应参数均变红（每次4条断言），全部还原后绿。
- 显示器值布局按事件缓存，display begin/end、screen parameters、wake/unlock、会话/屏保事件失效，原规则测试启用同一缓存。双窗口双屏30Hz模拟实测：改前270次布局重建/秒，改后预热稳态0次（不缓存只改门禁单读为150次）；每屏一次UUID/镜像调用折算540+540次/秒降到0+0，事件后首次读重建一次。没有运行真实桌面性能探针。
- 使用 test-triage / swiftpm-macos 技能完成定向测试、反例回退与 SwiftPM 验证。make check 111 项测试、30 个套件全绿；静态检查/debug 构建通过。未启动GUI、不操作用户进程/窗口/defaults，未push/发版。

## 2026-11-24 — 显示器规则 v2（devs/display-rules-v2）

- 从 main 9c595cc 的独立 worktree 实现 RULES-v2 第 1–7 条：稳定布局基线、独立锁屏/睡眠/会话门禁、UUID 归属、最后事件后 10 秒判离线、只释放受影响窗口。保留无动画，显示器回来不自动贴回；正常退出两分钟内重开的同窗/未移动/原屏在线例外保留。
- 释放名单只保留精确 handle 与实际隐藏位指纹；±2pt 且所有屏可见区域并集 <10% 才自动救回，不拉回用户放在其他位置的窗口。1Hz 持续检查，AX/拖动/隐藏/最小化延期；新增中英「找回所有窗口」菜单。写入失败保留所有权和在线条，取消/退出补查；重启恢复在会话和 AX 可用后重试。
- README、中英官网、开发说明同步更新。使用 swiftpm-macos / test-triage / appkit-interop 技能指导 SwiftPM 检查、fake 竞态测试及现有菜单本地化接线；未引入 UI 桥接或依赖。
- 单元测试覆盖上午完整时间线、两份评审场景、ID 重分配、31/43ms 锁屏竞态、1080→1055 visibleFrame、9.9/10.1/66.847 秒慢醒、相邻桌面暴露旧停放位、精确名单多次恢复、手动兜底、重开恢复及 poll 不变式。make check 107 项测试、28 套件及静态检查/debug 构建通过。
- 不启动 app、不触碰用户窗口/进程/defaults，不 push、不发版。规则/代码/测试与证据对照报告在 Devs 工作区 OrbPeek-display-rules-v2-report.md。

## 2026-11-27 — 稳定优先：收起不再等待截图

- 回看git历史/CHANGELOG/日志，旧注释~1秒window-filter停顿、101923d的replayd wedge与无效TaskGroup超时、b8532aa的共享服务重启节流、11-27的538656ms/缓存失效均有证据；专项历史与路径审计写入Devs工作区OrbPeek-capture-1127-report.md。
- 发现正常peek收起仍会新拍一次并等待（最坏约1.6秒），改为直接用展开期间已取得的合成缓存/身份占位，不再请求截图；独立补拍取消不join。初贴边保留一次有界拍摄，等待时条仍可hover/slam取消；不采用window-only或隐藏刷新。取舍是条记录最近一次可见快照，未必是收起瞬间最后一帧。
- hideWithoutCapture在普通失败/悬挂补拍两参数上旧代码先红（2断言，/tmp/orbpeek-hide-capture-red.log），修后与既有截图/交互测试全绿。完整检查结果见外部报告；未真实截图或替换用户实例，不push/发版。

## 2026-11-27 — 截止测试与调度延迟分离

- v2完整检查在MainActor图片测试并行时出现465ms观察延迟，原400ms墙钟断言失败，但底层仍未释放且结果为timeout。删除重复的紧墙钟阈值，独立看门狗留5秒调度余量；仍断言20ms deadline返回时worker尚未结束，并验证MainActor可执行，旧TaskGroup必等worker而失败。生产deadline没有改变。
- 临时回退TaskGroup实测红：1项1断言、5.507秒，证明仍能抓住旧join缺陷；还原后make check 94项/30套件通过。日志/tmp/orbpeek-preview-deadline-red.log与/tmp/orbpeek-preview-main-check.log。

## 2026-11-27 — 暂停时阻止已排队的补拍

- 补拍Task进入底层前也检查取消/代际/会话门禁，避免peek后同轮暂停仍启动截图。新增cancelledBeforeStart假测试。修正文档中过时的性能断言，不声称真实截图永不挂起。
- make check 94项/30套件通过；未恢复真实截图或试用切换，仍遵守系统弹窗停止要求。

## 2026-11-27 — 合成预览截图时机

- 按用户新硬要求只使用肉眼一致的display合成来源；实际CG窗口层级替代frontmost，前后检查遮挡/位置、整窗精确归属屏。初贴边和peek后可见时抓图，失败在同次可见期间1/4/15秒有限重试；最终收起再抓最后可截画面，隐藏期间只用缓存/应用图标名称占位，无定时刷新、无闪回。
- 抓图中的条已显示且支持正常hover/slam，中断旧capture/transition不会晚到隐藏；peek补拍独立于交互，只更新图片缓存。新增层级、背景未挡、启动恢复被挡、peek补拍、退避、隐藏不抓、门禁、悬挂截图交互和四边占位假测试。回退frontmost/抓图中不hover两条旧行为时，2项测试5断言失败，恢复后绿；完整check结果见外部事故报告。
- 使用SwiftPM/test-triage/build-run-debug/signing技能。真实自建窗口验证发现UserNotificationCenter系统窗口wid22278，立即停止后续真实截图/切换，无点击；探针自行退出，未启动小红书/模拟器测试。屏外AppKit/Metal图成功仅证明自建窗口可截，不代表iPad/qemu效果；window-only未采用。细节/限制写入OrbPeek-capture-1127-report.md，试用替换依用户“遇系统弹窗停止”约束暂不执行。不push、不发版。

## 2026-11-27 — 截图缓存失效与真实超时（devs/capture-fix）

- 从main 9c595cc独立worktree修复：旧SCShareableContent仅在缺自身PID时刷新，显示器/唤醒/会话事件不失效；失败吞SCK错误且普通失败不重取。旧TaskGroup退出等不响应取消的SCK子任务，日志538656ms与fake红测试约0.58秒均证明超时不有界。日志等待期间仍处理窗口/锁屏事件，不能称主线程阻塞；docking流程在等结果。
- CapturePipeline注入content provider、display capture、时钟、日志与replayd动作。显示器begin/end、screen parameters、wake/unlock/active强制失效；所有失败最多一次fresh retry，displayID严格匹配，无first回退；SCK错误domain/code/描述与阶段入日志。generation阻止失效/超时晚到内容或图片回写。
- continuation竞争让调用者按0.5s枚举/0.3s截图返回（最多两次），prewarm也有界；非隔离SCK适配运行在通用executor，主线程可继续交互。底层不响应取消的请求最多8个，避免无限后台堆积。三次连续逻辑截图超时、五分钟冷却不变，fresh retry成功/普通错误清零，未实际重启用户replayd。
- 新fake测试覆盖超时/取消、MainActor可运行、缓存事件失效接线、缓存失败/枚举错误恢复、错误日志、无目标屏不截图、永不响应枚举/截图、晚到结果丢弃、replayd门限/冷却及请求上限。make check 85项/28套件、静态检查/debug构建全绿，无真实截图/用户窗口操作。不push、不发版；合入试用分支及授权TERM/open核验另记OrbPeek-capture-1127-report.md。

## 2026-11-23 — 1.1.3 发布准备

- 在 main 01ea570 上依次合入 devs/default-shortcuts 与 devs/site-v3，合并提交 aa46d97，无冲突。用户确认仅改变新安装默认值，所有已保存快捷键保持不变，不添加迁移逻辑。
- 补充全新安装测试：在独立子进程中将 UserDefaults.standard 替换为随机临时 suite，先确认四个 key 均不存在，再验证四个生产 Name.shortcut 等于 Control + Command 加对应方向键。子进程退出且临时 suite 清除，不触碰用户 app 设置。
- `make check` 通过：75 项测试、25 个套件；Info.plist 为 1.1.3 / 113，CHANGELOG 增加中英文说明，修正 release notes lint 的历史版本检查。CI 保留声明的 build 113，避免流水线序号覆盖。
- `/tmp/orbpeek-build.*` 中性路径 release 构建、DEV X 严格签名核验通过；全部 25 个 app 文件 strings 无用户路径或公司标识，证书指纹与当前安装相同。

## 2026-11-23 — 已确认默认快捷键同步（devs/site-v3）

- 已 fetch 并确认历史改写后的分支基点为 `d871ffc`，将中英 README / 官网统一为用户确认的 ⌃⌘ + 方向键（Control + Command）。同步调研结论、发布说明和预览索引，移除待确认占位。
- 仿真演示源文件没有快捷键文字或按键叠层，因此 MP4 / GIF / 海报无需重新渲染；重新生成中英 × 浅深 × 桌面/手机网页截图和四组 README 截图，仍在 `../OrbPeek-site-preview/v4/orbpeek-*`。
- 全仓库文字检索无待确认占位或旧修饰键符号残留；调研内其他应用真实键位保留为文字，避免篡改研究事实。app 代码不在本轮范围，发布时须与开发侧默认值变更一同交付；不覆盖用户设置。
- `make check` 和浏览器预览检查通过；仅本地提交，未 push，预览进程退出时关闭。

## 2026-11-23 — 产品首页与四边演示（devs/site-v3）

- 中英 README / 官网改为“窗口在手边，桌面有空间”：四边节省空间、悬停随时用、多显示器；不把拖动/恢复等直觉行为作为卖点。官网首屏一整屏，顶栏仅 GitHub / 中 EN，下面安装独立展开。
- 新增代码绘制仿真桌面：左聊天、右笔记、上音乐、下终端各一个，中央保留写作。四方向瞬时出现/收起，与当前源码无滑动一致；15 px / 50% 默认预览条，20 秒 2880×1880 MP4 / GIF，通用界面和虚构内容，无真实截图。
- 安装按 Homebrew / DMG 各自编号，再讲辅助功能（必需）与屏幕录制（可选）的用途、缺省后果和授权入口；Gatekeeper 只放手动路径，核对 app 字符串与 cask postflight。未启动 app 副本，避免任何授权弹框；原实例 pid 88837 未触碰。
- 快捷键调研已单独回开发管家，证据与备选见 `docs/shortcut-research.md`；用户随后确认 ⌃⌘ + 方向键，四份用户页面已统一更新，本轮不改 Sources，发布时与开发侧 app 默认值变更一同交付。
- `make check` 通过，73 项测试 / 24 套件；中英 × 浅深 × 1440/390 八组网页检查通过：无溢出/控制台错误、首屏高度、2x 视频、自动播放/暂停、减少动态效果、复制命令、安装锚点、手动安装展开和语言路径；四组 README GFM 图片检查完成。
- 2x 截图位于 `../OrbPeek-site-preview/v4/orbpeek-*`（README 为本地 GFM 仿 GitHub 渲染），已目视检查中文 README、官网首屏/整页、手机及深色版。预览/渲染进程用完即关闭。仅本地提交，不 push，不发布。

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

## 2026-11-16 — 产品化（devs/product）

- 统一“贴边 / 预览条”中英文用词；更新 macOS 15 Gatekeeper 和卸载数据说明。
- 本地与 CI 版本统一从最近 tag 读取，菜单显示版本；Release 说明从 CHANGELOG 对应段生成。
- 完成辅助功能、屏幕录制和未授权快捷键三项权限引导；replayd 连续 3 次超时才重启并冷却 5 分钟。
- tap 的 zap 已补恢复数据与旧配置；GitHub description/topics 已设置，homepage 保持空白。
- 本轮不打 tag、不发版，不操作正在运行的 /Applications/OrbPeek.app。

## 2026-11-16 — 官网与真实演示（devs/site）

- 新增 `site/` 中英静态单页，无统计或第三方脚本；Playwright 已检查 1440/768/390、浅色/深色，无横向溢出或控制台错误。截图在 `Artifacts/site/`。
- 演示改为真实 Peekaboo 截图 + Pillow/ffmpeg 合成。`capture-demo.sh` 提供隐私试拍和正式采集，`render-demo.py` 输出 2x MP4、960px GIF、高清首图。
- 当前候选区域均与用户窗口重叠，因此未执行试拍或正式采集；未生成真实素材，官网保留明确占位。

## 2026-11-16 — 真实合成演示完成

- 专用 AppKit Git 速查窗口完成浅/深色正式采集；每套约 17–29 秒，预览条按 CGWindowID 截取。所有图片逐张核对，仅含目标窗口。
- 已生成 `docs/assets/orbpeek-demo-{light,dark}.mp4`（约 0.3MB）、`demo-{light,dark}.gif`（约 0.3MB）、高清首图；官网首屏和 README 已替换。
- 结束检查：演示窗口关闭、OrbPeek 回到原有 2 个贴边窗口、鼠标移至安全位置。官网视频自动播放验证通过，无控制台错误。

## 2026-11-16 — 显示器事故修复（devs/incident-1116）

- 增加逐窗口 ID/app/wid、布局、AX 移动、预览条、退出和启动恢复日志；预览条 clamp + 可见性自检；peek 激活重试 2 秒。
- 离线屏稳定确认后，窗口居中置前；同屏锁屏期间回来保持贴边。正常退出后 120 秒内启动按原边自动贴回。
- 新增多窗口 fake window server 完整事故序列、同屏返回、升级过期测试；51 个测试通过。
- 官网和 README 已更新用户语义；未打 tag、未发版，未操作正在运行的 OrbPeek。

## 2026-11-13 — 用户主页与演示图

- 重写中英 README：安装、两项权限、使用、隐私和异常退出恢复说明均按代码核对；开发内容留在开发文档。
- 新增面向用户的未发布更新记录，覆盖显示器/锁屏、拖动、可见区域保底和异常恢复。
- 新增 Pillow 示意动图渲染脚本及浅色、深色 GIF；不需要屏幕录制权限，不使用生成式图片。
- `make check` 通过：42 个 Swift Testing 用例、14 个套件；两份 README 的本地图片和相对链接均存在。

## 2026-11-23 — 撤销截图浮层动画（devs/incident-1123）

- 按用户要求整体撤销 slide-anim 的六个动画提交：浮层、动画计划/状态机、全图缓存接口及 nil fallback、减少动态效果分支和动画专用测试一并移除，恢复直接定位窗口。
- 与 incident-1116 逐文件核对，全部差异均属动画；显示器修复与原有 65 项测试原样保留。预览条既有的截图缓存和占位条属于原功能，继续保留。
- 验证使用独立 worktree 和 fake 窗口；不启动 app、不操作用户窗口、不替换试用包；site-v2 的 README/官网文案仅列出，未修改。
- `make check` 全绿：65 项测试、22 个套件，静态检查与 debug 构建通过；Sources、Tests、AGENTS.md 和 DEVELOPMENT.md 与 incident-1116 完全一致，动画符号检索无残留。

## 2026-11-23 — 显示器规则核对与试用

- 按用户确认的规则补 6 项测试：整夜锁屏四边原位恢复、无解锁通知的睡眠唤醒、锁屏/睡眠后外接屏晚到 20 秒的四边精确恢复、原屏拔出后居中、其他屏拔出不改预览条、合盖后内建屏归属窗口释放而外接屏窗口保持。参数化场景共 16 组，fake 窗口与独立测试目录，不操作用户窗口。
- 原有 65 项测试一项未改，新增后 `make check` 71 项测试、23 个套件全绿；Sources 无改动，保留两分钟重启贴回及晚到屏贴回窗口。
- 已只读核对用户日志：夜间重复显示器通知时 poll 处于锁屏冻结；解锁后同一窗口仍是原屏原偏移，没有夜间释放记录。白天原归属屏离线后的三次居中释放另列，不混为夜间故障。
- 用户已授权用 DEV X release 包切换试用实例，保留旧包供恢复；面向用户的五分钟验证清单与详细证据放在项目外的 Devs 工作区。

## 2026-11-17 — README 与官网重写（devs/site-v2）

- 中英 README 和官网从零重写，所有说法按 main 源码核对；不写多显示器、插拔或锁屏相关能力。
- 演示改为 `Scripts/demo/` 的 HTML 场景 + 无头 Chromium 逐帧渲染，不操作真实桌面。参数取自源码默认值；源码没有滑动动画，画面里窗口瞬间移动。
- 输出 2880×1800 60fps MP4/WebM（约 0.8–1MB）、1600px GIF（约 2.4MB）、2x 首图和 4x 预览条特写；旧的截图采集脚本和素材已删除。
- Playwright 检查中英、浅深色、1440/390 宽：无控制台错误、无横向溢出；截图在 `../OrbPeek-site-preview/`。未推送。

## 2026-11-17 — 评审跟进（devs/site-v2）

- 按 site-review-1117：README 安装节移到动图之前，顶部链接行加「安装」；官网导航加「安装」按钮，首屏安装区改为独立的 `#install` 一节。
- 演示在贴边后加 6 倍放大框展示预览条（标明是演示叠加层），README 预览条一节加 2 倍特写。
- 按源码改准文案：悬停而非「碰」、快捷键作用于最前面的窗口、拖开 40 px 以上才取消、甩到预览条上才立即出现、点击穿过预览条；删去自我说明和更新记录里的开发过程条目。

## 2026-11-17 — 文档按下一版重写（devs/site-v2，未推送）

- 官网：顶部只留 GitHub 和中英切换；首屏只有名字、一句介绍和演示视频，安装（分步骤）和用法在下面，去掉页脚和对比内容。
- README：大图标标题，安装分 Homebrew / DMG 两条路径逐步写；去掉与其他方案的比较。
- 文案和演示按 `devs/slide-anim` 的滑动行为写（150ms 截图浮层）；不写显示器相关能力。要和带滑动动画的版本一起发布。

## 2026-11-23 — 1.1.2 本地发布准备

- 在重建后的历史上合入 incident-1123 和 site-v2；保留全部显示器测试，按当前直接显示/收起行为重写两份 README 与中英官网，移除动画素材和生成脚本。补充拔屏居中、锁屏/睡眠恢复及晚到屏两分钟内贴回的准确说明。
- 新增 `--login-item-status`：在 app/controller 初始化前只读登录项状态和 app 路径并退出；2 项测试覆盖普通启动不读取诊断信息、四种状态和其他参数同时出现时的诊断优先级。实际 release 参数冒烟已通过，无 UI、权限请求或窗口恢复。
- Info.plist 版本设为 1.1.2 / 112，统一版本读取并增加 tag 不匹配保护；release 在中性临时目录编译，保留 SPM bundle 组装和 DEV X 签名。中英 CHANGELOG/release notes 明确 1.1.0 多显示器修复不完整及本版补齐场景。
- `make check` 73 项测试、24 个套件通过；DEV X release 签名、版本、全部 25 个 bundle 文件字符串检查通过，无个人 home 路径或已知公司身份。中英 × 浅深色 × 390/1440 八组网站无头检查通过，无动画媒体、缺图、横向溢出或控制台错误。
- 仅只读确认两项远端签名 secret 名称存在；逐步核对 workflow 并验证 shell 语法、版本/tag 保护。导入、解锁和 secret 解码没有在用户机器执行；实际远端签名需等发布阶段验证。未打 tag、未 push，未替换或重启当前试用版。

## 2026-11-23 — 默认快捷键改为 Control+Command

- 从改写后的 main（根 aa90b5b，共 137 个提交）建立 devs/default-shortcuts；四个方向的默认修饰键改为 control + command，保留 dockLeft/dockRight/dockUp/dockDown 的持久化名称，不做重置或迁移。
- KeyboardShortcuts 固定依赖的 Name 初始化只在对应 defaults key 不存在时写入默认值；自定义值、主动清空的 false 标记和已保存的旧默认值均保留。设置页 Recorder 显示当前有效配置；菜单和首次引导没有写死的方向快捷键提示，无需修改文案。产品文档由产品负责。
- 新增 app 测试 target，直接验证四个生产 Name 的新默认值及自定义值、旧默认值、清空值在首次初始化和重新构造时不被覆盖。测试使用进程内 volatile defaults 覆盖，覆盖前先保存、结束时还原，不写持久化设置、不注册全局热键、不创建 app 或窗口。
- 红绿验证：新测试在旧代码上因四个方向修饰键不符失败，修改默认值后通过；完整 make check 通过：74 项测试、25 个套件，静态检查与 debug 构建全绿，原有 73 项测试均保留。
- 未推送、未发版，未启动或替换 app，不操作用户运行中的正式版。
