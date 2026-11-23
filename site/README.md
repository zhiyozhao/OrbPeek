# OrbPeek 官网

静态中英双语单页，没有构建步骤、统计或第三方脚本。中文是 `index.html`，英文是 `en/index.html`，共用 `style.css` 和 `main.js`（复制安装命令）。推送到 main 且改动了 `site/` 时由 `.github/workflows/pages.yml` 发布到 GitHub Pages。

本地预览：

```sh
python3 -m http.server 4173 --bind 127.0.0.1 --directory site
```

网站仅使用 `assets/icon.png`，没有动画演示或自动播放媒体。
