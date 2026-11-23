<p align="right"><a href="README.md">中</a> | <b>EN</b></p>

<p align="center"><img src="site/assets/icon.png" width="128" height="128" alt=""></p>

<h1 align="center">OrbPeek</h1>

<p align="center">Tuck windows into the edge of your screen and hover to see them again.</p>

<p align="center"><a href="#install"><b>Install</b></a>&emsp;&emsp;<a href="https://zhiyozhao.github.io/OrbPeek/en/">Website</a></p>

## Install

Requires macOS 14 or later.

### With Homebrew

1. Run this in Terminal:

   ```sh
   brew install --cask zhiyozhao/tap/orbpeek
   ```

2. Open OrbPeek from Applications or Spotlight. It shows only an icon in the menu bar, with no Dock icon.
3. Follow the prompt to System Settings → Privacy & Security → Accessibility and turn on OrbPeek. It works right away.
4. Optional: click the OrbPeek icon in the menu bar and choose "Screen Recording — Click to Grant". The picture in the preview strip uses it. Without it, docking still works and the strip is a plain dark bar.

To update later: `brew upgrade --cask orbpeek`.

### Download the DMG

1. Download `OrbPeek-<version>.dmg` from [Releases](https://github.com/zhiyozhao/OrbPeek/releases/latest) and drag OrbPeek into Applications.
2. Double-click it. OrbPeek is not notarized by Apple, so macOS blocks the first launch. On macOS 15, go to System Settings → Privacy & Security, click "Open Anyway" at the bottom and enter your password. On macOS 14, Control-click OrbPeek in Finder and choose Open.
3. Continue with steps 3 and 4 above.

## Usage

| Do this | What happens |
|---|---|
| <kbd>⌃</kbd><kbd>⇧</kbd> plus <kbd>←</kbd> <kbd>→</kbd> <kbd>↑</kbd> <kbd>↓</kbd> | Docks the front window to the left, right, top or bottom edge. Press another arrow on a docked window to switch edges. |
| Move the pointer onto the strip | The window appears, ready to use. Fling the pointer onto the strip and it comes out at once. |
| Move away, or switch to another app | The window hides. |
| Drag the window along the edge while it is out | When you let go, the strip stays at the new spot. Resizing keeps it docked. |
| Click the window's name in the menu bar icon | Undocks it and puts it back where it was. |
| Drag the window toward the middle (more than 40 px) while it is out | Undocks it and leaves it where you drop it. |

Minimizing the window or hiding its app with <kbd>⌘</kbd><kbd>H</kbd> also undocks it. Quitting OrbPeek puts every window back where it was.

When a window’s display disappears, OrbPeek undocks it and centers it on a remaining display. After locking or sleeping, windows keep their original display, edge and position when the same display returns. If a display wakes slowly, windows may be centered temporarily; they dock back when the display returns within 2 minutes, provided you have not moved or resized them.

Reopen OrbPeek within 2 minutes of a normal quit to dock unchanged windows again. Homebrew updates do not reopen the app automatically.

## Settings

Click the menu bar icon and choose Settings…:

- Launch at login
- A shortcut for each direction
- Preview strip width (5–50 px, 15 px by default) and opacity (20%–100%, 50% by default). If the strip is hard to see, make it wider or more opaque.

## FAQ

### A window is gone

If OrbPeek quits unexpectedly, docked windows stay off screen. Open OrbPeek again and it brings them back on screen.

### Does OrbPeek connect to the internet?

No. There is no account, analytics or upload. Screen Recording is used only to take a picture of the window you dock, and the picture stays in memory.

## Uninstall

```sh
brew uninstall --cask --zap orbpeek
```

This also removes the files OrbPeek writes. If you drag the app to the Trash instead, delete these yourself:

- `~/Library/Preferences/com.orbpeek.OrbPeek.plist`
- `~/Library/Application Support/OrbPeek/`
- `~/Library/Logs/orbpeek.log`

## License

[MIT](LICENSE)
