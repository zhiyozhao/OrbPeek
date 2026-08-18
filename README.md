# OrbPeek

A macOS menu-bar app that docks windows to any screen edge and slides them back in when you hover the edge — like auto-hiding docks, but for individual windows.

## Features

- Dock the frontmost window to the left / right / top / bottom edge with a hotkey (default `Ctrl + Shift + arrow keys`, rebindable)
- A slim snapshot strip stays at the edge as a visual handle — hover (or slam) it to slide the window back in
- The window slides back out automatically when you move on, or drag it off the edge to undock it for good
- Multiple windows per edge, per-screen docking, multi-display aware
- Survives display (un)plug, sleep and lock without losing your docked windows
- Launch at login, adjustable strip width/opacity, Chinese UI

## Install

### Homebrew

```sh
brew install --cask zhiyozhao/tap/orbpeek
```

### Manual

Download `OrbPeek-<version>.dmg` from [Releases](https://github.com/zhiyozhao/OrbPeek/releases), drag OrbPeek to Applications, then right-click → **Open** once (Gatekeeper). Updates over the same install keep your Accessibility/Screen Recording grants.

Uninstall:

```sh
brew uninstall --cask --zap orbpeek   # also removes preferences and logs
```

## Permissions

| Permission | Why | Without it |
|---|---|---|
| **Accessibility** (required) | Moving and resizing other apps' windows | App can't function |
| **Screen Recording** | Capturing the window snapshot shown in the edge strip | Strip shows a plain dark placeholder |

Both are prompted on first launch; status and re-grant shortcuts live in the menu-bar menu.

## Usage

- **Dock**: focus a window, press `Ctrl + Shift + ←/→/↑/↓` to send it to that edge
- **Peek**: hover the edge strip (or move the mouse fast toward it) — the window slides in; leave and it slides back out
- **Undock**: drag the peeked window away from the edge, or click its entry in the menu-bar menu
- Hotkeys, strip width/opacity and launch-at-login are in 设置… (Settings) in the menu

## Build from source

Requires macOS 14+ and a Swift toolchain (Xcode or Command Line Tools).

```sh
./build.sh        # swift build -c release + assemble OrbPeek.app + codesign
open OrbPeek.app
```

`build.sh` signs with a stable self-signed **"OrbPeek Dev"** certificate so macOS doesn't re-prompt for Accessibility on every rebuild (ad-hoc signing changes the code hash each build, which invalidates TCC grants). Create it once via Keychain Access → Certificate Assistant → Create a Certificate → name `OrbPeek Dev`, type **Code Signing**, or build ad-hoc with `CODESIGN_IDENTITY=- ./build.sh`.

Debug helpers:

```sh
OrbPeek.app/Contents/MacOS/OrbPeek --self-test            # verify AX trust; nudges the focused window
OrbPeek.app/Contents/MacOS/OrbPeek --debug-mouse "1:10,500 2:10,0"   # scripted cursor for testing
```

## How it works

A 30 Hz poll reconciles every managed window toward its canonical position, which is a pure function of the current display set — that's what makes docking robust across display hot-plug, sleep and lock. Docking captures a display-region snapshot (ScreenCaptureKit) of the window before parking it 1 px off the desktop's outer edge; the floating strip is that snapshot, cropped per edge. Polling freezes entirely while the screen is locked (AX calls black out during lock).

## Release

Maintainers: push a semver tag and GitHub Actions builds, signs, packages and publishes the release; the [homebrew tap](https://github.com/zhiyozhao/homebrew-tap) cask syncs automatically.

```sh
git tag v1.0.1 && git push origin v1.0.1
```

## License

[MIT](LICENSE)
