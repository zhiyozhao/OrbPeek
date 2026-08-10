# OrbPeek

macOS menu-bar app that docks the frontmost window off-screen and slides it back in when hovered. No Xcode project, no `Package.swift` — plain `swiftc` over a `Sources/` directory.

## Build & run

- Build: `./build.sh` — `swift build -c release` (SPM, see `Package.swift`; depends on `sindresorhus/KeyboardShortcuts`) + assembles `OrbPeek.app` (Info.plist, LSUIElement) + ad-hoc `codesign` (keeps TCC permissions stable across rebuilds)
- Run: `open OrbPeek.app` (the .app and `.build/` are gitignored)
- Self-test: `OrbPeek.app/Contents/MacOS/OrbPeek --self-test` — verifies Accessibility trust and moves the focused window +30px, then restores it. Must keep Terminal frontmost, else it exits(1).
- Debug drivers: `--debug-mouse "t:x,y t:x,y ..."` — scripted cursor positions (t = seconds since launch, quartz top-left coords) replace the real mouse in `poll()`; `--show-settings` opens the settings window at launch. `Scripts/test-window.swift` (`swiftc` it, pass AppKit x y) creates a dedicated frontmost test window that prints its real frame; drive the dock hotkey via `osascript -e 'tell application "System Events" to key code 126 using {control down}'` (123/124/125/126 = ←/→/↓/↑).

## Source layout (`Sources/`)

- `OrbPeekController.swift` — `@main` entry + app delegate: status item, sectioned menu (permissions / docked windows / actions — Chinese UI strings, keep them that way), hotkeys via `KeyboardShortcuts.onKeyDown`, settings window, 30 Hz `poll()`, docking orchestration
- `SettingsView.swift` — SwiftUI settings window + `KeyboardShortcuts.Name` definitions (default Ctrl+arrows). Settings live in `UserDefaults` via `@AppStorage` and apply live
- `ManagedWindow.swift` — per-window state machine; talks to the app only through the `WindowDockDelegate` protocol (defined here)
- `Geometry.swift` — `DockEdge` + `WindowGeometry`: **all** coordinate conversion and dock/peek/sliver position math, in one place
- `AXWindow.swift` — `AXUIElement` wrapper (safe frame/position/title/pid access)
- `SliceCapturer.swift` — composited **display-region** captures (NOT window-filter captures); every successful capture is cached by `(windowID, edge, size)` — the cache is the fallback for the one case a live capture is impossible (hidden re-dock) and makes the strip appear instantly
- `SnapshotStrip.swift`, `Config.swift`, `Log.swift`, `SelfTest.swift` — small supporting types

## Permissions

- **Accessibility** (`AXWindow.isProcessTrusted`) — required for moving/resizing windows; prompted at launch, status shown in the status-bar menu.
- **Screen Recording** — needed for fake-strip docks: up/down always, plus left/right on screen edges that are NOT the desktop's outer edge (a window can't leave the desktop there). The strip is a captured `SnapshotStrip` handle because macOS won't let a titled window leave those edges.

## State & paths

- Settings: `UserDefaults` (edited in the settings window, applied live; legacy `~/.config/orbpeek/config.json` is imported once at first launch of the bundled app)
- Log: `~/Library/Logs/orbpeek.log` (also written to stderr). `Log.info` is the debug tracing mechanism.
- Launch-at-login uses `SMAppService.mainApp` (toggled in settings).
- Hotkeys: `Ctrl+←/→/↑/↓` by default, rebindable in settings (`KeyboardShortcuts.Recorder`).

## Code conventions

- **Main-thread model is enforced at compile time**: `OrbPeekController`, `ManagedWindow`, `SliceCapturer`, and the `WindowDockDelegate` protocol are all `@MainActor`. Nonisolated callbacks (Timer, `NSEvent` monitors, hotkey/signal handlers) hop to the main actor via `Task { @MainActor in ... }` — follow that pattern for any new callback.
- **Phase transitions are the only place `ManagedWindow.phase` changes**, and each transition resets transient dwell state (`DwellTracker`) — put phase changes in transitions, not in `evaluate`. Phases: `docked` / `docking` (fake capture in flight, window still on screen — `evaluate` does nothing) / `peeked`.
- **Transitions are serialized**: each window holds at most one in-flight `transition` Task; starting a new transition cancels it, and superseded tasks self-discard at `Task.isCancelled` checks. Never add ad-hoc generation/flag guards — extend the state machine instead.
- Coordinate gotcha: AX frames are top-left origin, `NSEvent.mouseLocation` is bottom-left. Always convert through `WindowGeometry.toQuartz`/`toAppKit`; never mix spaces (geometry functions return `CGPoint?`/`CGRect` computed from `outerScreen`, which falls back safely when no screen is found).
- Dock edges are **per-screen**: each window records its dock screen (`ManagedWindow.dockScreenID`, picked from the on-screen frame at dock time). left/right use the window's own visible sliver only on the desktop's outer edges; up/down and middle edges use the fake snapshot strip (`isFakeEdge`). `sliverRect` computes the hover hit region (thickness = `sliverPx` for real slivers and fake strips alike); `sliverLength` is the size along the sliver used to pick the smallest window on overlap.
- Re-docking a hidden window: the live frame is the parked position, so perp comes from `restoreFrame` and the dock screen is kept as-is — never derive either from the parked frame.
- Strip images come from **display-region** captures (`SCContentFilter(display:...)` of `sliceScreenRect`) so translucency/shadow/rounded corners look exactly like the real window on screen. Window-filter captures return the raw flattened surface (vibrancy loses its backdrop blend) — don't use them. Window-filter `captureImage` also **randomly stalls ~1s**; display captures don't (~50ms).
- The composited capture needs the window on screen, so ALL docks (real and fake edges alike) **capture first, park after** (the `.docking` phase — 300ms timeout parks regardless). One display capture of the whole window frame is cropped into **all four edge slices** and cached, so a hidden re-dock to any edge has content. The strip is shown only after the capture, so it can't photograph itself. A **hidden re-dock never moves the window** (a capture would flash it on screen): it re-parks at the new edge and shows the cached slice or a placeholder. Slice content mimics the window really sliding off the edge: the **opposite** edge stays visible (up → bottom slice, down → title bar, left → right edge, right → left edge — same as the real slivers' trailing 6px).
- External window mutations: a docked window moved externally is snapped back to its hidden position each tick (by design — the dock owns it); a **peeked** window displaced past `dockCancelPx` by something else (user drags set `gesture` and go through `checkDragOut`) is treated as dragged out → cancel, never re-hidden; a window whose frame becomes unreadable (closed etc.) is dropped after ~1s with a best-effort restore to `restoreFrame` so it's never left invisibly parked.
- On SIGTERM/SIGINT/terminate, docked windows are restored via `restoreAll()` before exit.
