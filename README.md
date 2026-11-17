<p align="center"><img src="site/assets/icon.png" width="128" height="128" alt=""></p>

<h1 align="center">OrbPeek</h1>

<p align="center">把 Mac 上的窗口贴到屏幕边上，鼠标移过去，它就滑出来。</p>

<p align="center"><a href="#安装"><b>安装</b></a> · <a href="https://zhiyozhao.github.io/OrbPeek/">官网</a> · <a href="README.en.md">English</a></p>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/demo-zh-dark.gif">
  <img src="docs/assets/demo-zh-light.gif" width="800" alt="按 ⌃⇧→，备忘录窗口滑到屏幕右边，只留一条很窄的预览条，画面放大展示这条预览条；鼠标移到预览条上，窗口滑出来；鼠标移开，窗口滑回去。">
</picture>

## 安装

需要 macOS 14 或更高版本。

### 用 Homebrew

1. 在「终端」里运行：

   ```sh
   brew install --cask zhiyozhao/tap/orbpeek
   ```

2. 在「应用程序」或聚焦搜索里打开 OrbPeek。它只在菜单栏显示一个图标，没有 Dock 图标。
3. 按提示进入「系统设置 → 隐私与安全性 → 辅助功能」，打开 OrbPeek 的开关。打开后马上可以用。
4. 可选：点菜单栏里的 OrbPeek 图标，选「屏幕录制 — 点击授权」。预览条的画面和滑动效果要用到它；不允许也能贴边，只是预览条是一条深色的空条。

以后更新：`brew upgrade --cask orbpeek`。

### 下载 DMG

1. 从 [Releases](https://github.com/zhiyozhao/OrbPeek/releases/latest) 下载 `OrbPeek-<版本>.dmg`，把 OrbPeek 拖进「应用程序」。
2. 双击打开。OrbPeek 没有经过 Apple 公证，系统会拦下它：
   - macOS 15：到「系统设置 → 隐私与安全性」，在页面底部点「仍要打开」，输入密码确认。
   - macOS 14：在「访达」里按住 Control 点 OrbPeek，选「打开」。
3. 接着做上面的第 3、4 步。

## 用法

| 操作 | 效果 |
|---|---|
| <kbd>⌃</kbd><kbd>⇧</kbd> 加 <kbd>←</kbd> <kbd>→</kbd> <kbd>↑</kbd> <kbd>↓</kbd> | 把最前面的窗口贴到左、右、上、下边。对已经贴边的窗口按另一个方向键，就换一条边。 |
| 鼠标移到预览条上 | 窗口滑出来，可以直接用。把鼠标快速甩到预览条上，它会马上出来。 |
| 鼠标移开，或切到别的 app | 窗口滑回去。 |
| 窗口滑出来时沿着边拖动 | 松手后预览条停在新位置。改窗口大小不影响贴边。 |
| 在菜单栏图标里点窗口的名字 | 取消贴边，窗口回到原来的位置。 |
| 窗口滑出来时往屏幕中间拖远（超过 40 px） | 取消贴边，窗口留在你松手的地方。 |

最小化窗口、或者用 <kbd>⌘</kbd><kbd>H</kbd> 隐藏它的 app，也会取消贴边。退出 OrbPeek 时，所有窗口都会放回原处。

## 设置

点菜单栏图标，选「设置…」：

- 开机自启动
- 四个方向的快捷键
- 预览条宽度（5–50 px，默认 15 px）和不透明度（20%–100%，默认 50%）。预览条看不清，就调宽一点、调不透明一点。

## 常见问题

**窗口不见了。** OrbPeek 意外退出时，贴边的窗口会留在屏幕外。重新打开 OrbPeek，它会把这些窗口放回屏幕上。

**OrbPeek 会联网吗？** 不会。没有账号、统计或上传。屏幕录制只用来给贴边的窗口截图，图片只留在内存里。

## 卸载

```sh
brew uninstall --cask --zap orbpeek
```

这会连同 OrbPeek 写下的文件一起删除。如果是直接把 app 拖进废纸篓，还需要手动删除：

- `~/Library/Preferences/com.orbpeek.OrbPeek.plist`
- `~/Library/Application Support/OrbPeek/`
- `~/Library/Logs/orbpeek.log`

## 许可

[MIT](LICENSE)
