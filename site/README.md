# OrbPeek 官网

静态中英双语单页，没有构建步骤、统计或第三方脚本。中文是 `index.html`，英文是 `en/index.html`，共用 `style.css` 和 `main.js`（按浅色/深色选择演示视频、复制安装命令）。推送到 main 且改动了 `site/` 时由 `.github/workflows/pages.yml` 发布到 GitHub Pages。

本地预览：

```sh
python3 -m http.server 4173 --bind 127.0.0.1 --directory site
```

`assets/` 里的演示视频、海报和预览条特写由 `Scripts/demo/render.mjs` 生成，见 `docs/DEVELOPMENT.md`。
