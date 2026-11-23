# OrbPeek 官网

静态中英双语单页，没有构建步骤、统计或第三方脚本。中文是 `index.html`，英文是 `en/index.html`，共用 `style.css` 和 `main.js`（播放控制、复制安装命令）。推送到 main 且改动了 `site/` 时由 `.github/workflows/pages.yml` 发布到 GitHub Pages；本轮只做本地提交。

本地预览：

```sh
python3 -m http.server 4173 --bind 127.0.0.1 --directory site
```

首屏占一整屏：名称、一句介绍、仿真桌面演示、安装锚点。顶栏只留 GitHub 和「中 / EN」，底部不重复。下面依次为三个使用收益、安装方法、两项权限、三步用法。支持深色、手机布局、暂停和减少动态效果。

## 演示素材

`Scripts/demo/scene.html` 用 HTML/CSS 绘制桌面和通用 app，没有真实屏幕截图、私人数据或真实 app 商标。1440×900 逻辑桌面，下方 40 px 为演示字幕；2x 输出 2880×1880，20 秒无声循环。左聊天 380×510、右笔记 420×500、上音乐 440×272、下终端 620×310，各一个；中央写作窗口 980×668。窗口都位于桌面可用区域，预览条取相应窗口边缘切片，15 px、50% 不透明度。

每 5 秒演示一条边：鼠标过去、停留 150 ms、窗口直接出现、移入使用、移出窗口及 12 px 缓冲后直接收起。按 `ManagedWindow.peek()` / `dock(to:)` 和 `Config` 核对，不加入已移除的窗口滑动动画。桌面内容不变，首尾鼠标和窗口状态相同，可自然循环。

重新生成（本机已安装 Node、Playwright 和 ffmpeg，不安装全局工具）：

```sh
node Scripts/demo/render.mjs
node Scripts/demo/preview.mjs /absolute/path/to/preview
```

可用 `PLAYWRIGHT_CORE`、`CHROMIUM` 指定现有依赖。MP4 用于网站（自动播放、静音、循环、inline）；README 用同尺寸 GIF。海报用于加载和不可播放时。所有浏览器仅以 headless 运行，脚本退出时关闭；预览 HTTP 服务仅监听 127.0.0.1，`finally` 关闭。

## 发布前置条件

四个用户页面中的 `{{DEFAULT_MODIFIERS}}` 等待用户确认新默认值后统一替换；本轮不改变 app 默认快捷键，不把用户本机自定义设置写成默认。替换并与 app 默认保持一致后才可发布。

权限说明由 `OrbPeekController`、中英 `Localizable.strings`、`SliceCapturer` / `SnapshotStrip` 和当前 Homebrew cask 的 postflight 核对。没有启动测试副本，以免弹出规则禁止的权限框；没有操作真实 OrbPeek 或窗口。
