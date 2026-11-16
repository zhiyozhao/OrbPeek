# OrbPeek 官网

静态中英双语单页，无构建步骤、统计或第三方脚本。中文入口为 `index.html`，英文为 `en/index.html`，共用 `style.css`。

本地预览：

```sh
python3 -m http.server 4173 --bind 127.0.0.1 --directory site
```

然后打开 `http://127.0.0.1:4173/`。真实录屏尚未接入，`demo-placeholder` 是有意保留的占位；素材完成后替换该区域，不要拿示意图冒充实拍。

不部署、不绑定域名。上线需用户批准，DNS 和托管由 infra-ops 处理。
