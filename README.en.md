# OrbPeek

[中文](README.md) | English

Dock a window to any screen edge with a shortcut, leaving a slim visual handle; touch the edge with your pointer and the window slides back out.

[![Latest release](https://img.shields.io/github/v/release/zhiyozhao/OrbPeek?label=latest)](https://github.com/zhiyozhao/OrbPeek/releases/latest)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/demo-dark.gif">
  <img alt="A window docks to the right screen edge as a slim strip; touching the strip slides the window out, and moving the pointer away slides it back" src="docs/assets/demo-light.gif" width="960">
</picture>

```bash
brew install --cask zhiyozhao/tap/orbpeek
```

Not using Homebrew? Download the DMG from [Releases](https://github.com/zhiyozhao/OrbPeek/releases/latest) and drag OrbPeek into Applications.

## Highlights

- Press `Control + Shift + an arrow key` to dock the current window to that edge: left, right, top or bottom.
- A visual handle stays at the edge. Touch it with your pointer to see and use the window without switching apps.
- Move the pointer away and the window slides back. Drag it farther into the screen to undock it.
- Dock multiple windows on the same edge, with separate docks on each display.
- Windows follow the current display layout after display changes, sleep or locking the screen.
- Customize shortcuts, strip width and opacity, or launch OrbPeek at login.
- Chinese and English interface, following your system language.

## First launch

1. Open OrbPeek. Its icon appears in the menu bar.
2. Follow the prompt to System Settings → Privacy & Security → Accessibility and turn on OrbPeek. Return to the app; if it does not respond, reopen OrbPeek.
3. Click the menu-bar icon and grant access through the Screen Recording item.

**Why Accessibility?** OrbPeek needs to read and move the windows you dock, and put them back into a visible area when you undock them or when it recovers after an unexpected exit. Without it, OrbPeek cannot move windows for you. It does not use this permission to record the text you type.

**Why Screen Recording too?** This is only used to create the visual handle for a docked window. It does not record continuously or capture audio. You can dock and reveal windows without this permission, but the edge will show a translucent placeholder instead of the window image.

You can turn off either permission at any time under System Settings → Privacy & Security. Without Accessibility, OrbPeek cannot move windows. Without Screen Recording, it cannot create new window images.

## Usage

- **Dock**: focus the window you want to put away, then press `Control + Shift + ← / → / ↑ / ↓`.
- **Peek**: move your pointer onto its edge strip. The window comes to the front; move the pointer away and it slides back.
- **Undock**: drag the revealed window farther into the screen, or click the menu-bar icon and choose the window's name.
- **Customize**: open Settings from the menu-bar icon to change the four shortcuts, strip width, opacity and Launch at Login.

## Privacy

- No continuous screen recording, audio recording or logging of the text you type.
- Window images are kept only in memory. The cached image is deleted when you undock its window.
- No networking features. Window images, window titles and settings are never uploaded.
- Preferences, shortcuts and the run log stay on your Mac. To recover windows after an unexpected exit, OrbPeek temporarily stores recovery details such as each docked window's app, title and position; these records are cleared after a normal undock or quit.

## FAQ

**Opening the app from the DMG says the developer cannot be verified.**
The app is not notarized by Apple. In Finder, right-click OrbPeek, choose Open, then confirm once more.

**Where did my windows go after OrbPeek quit unexpectedly?**
On a normal quit, OrbPeek first restores every docked window. After an unexpected exit or force quit, the next launch automatically finds eligible windows that are still off-screen and places them fully inside the nearest display's visible area, without docking them again. Keep Accessibility enabled; windows cannot be recovered if their app or the window itself has also closed.

**How do I uninstall?**
Run `brew uninstall --cask --zap orbpeek`, or drag OrbPeek from Applications to the Trash.

## License

[MIT](LICENSE)

[Changelog](CHANGELOG.md) · [Development notes (Chinese)](docs/DEVELOPMENT.md)
