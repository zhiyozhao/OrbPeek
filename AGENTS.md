# OrbPeek

macOS menu-bar app that docks the frontmost window off-screen and slides it back in when hovered. No Xcode project, no `Package.swift` — plain `swiftc` over a `Sources/` directory.

## Build & run

- Build: `./build.sh` (runs `swiftc Sources/*.swift -o OrbPeek`; the app entry is `@main static func main()` on `OrbPeekController`, frameworks auto-link — no extra flags)
- Run: `~/Codes/OrbPeek/OrbPeek` (binary and logs are gitignored)
- Self-test: `OrbPeek --self-test` — verifies Accessibility trust and moves the focused window +30px, then restores it. Must keep Terminal frontmost, else it exits(1).
- Debug driver: `OrbPeek --debug-mouse "t:x,y t:x,y ..."` — scripted cursor positions (t = seconds since launch, quartz top-left coords) replace the real mouse in `poll()`, so dock/peek behavior can be tested while the machine is in use. `Scripts/test-window.swift` (`swiftc` it, pass AppKit x y) creates a dedicated frontmost test window that prints its real frame; drive the dock hotkey via `osascript -e 'tell application "System Events" to key code 126 using {control down}'` (123/124/125/126 = ←/→/↓/↑).

## Source layout (`Sources/`)

- `OrbPeekController.swift` — `@main` entry + app delegate: status item, menu (Chinese UI strings — keep them that way), hotkeys, 30 Hz `poll()`, docking orchestration
- `ManagedWindow.swift` — per-window state machine; talks to the app only through the `WindowDockDelegate` protocol (defined here)
- `Geometry.swift` — `DockEdge` + `WindowGeometry`: **all** coordinate conversion and dock/peek/sliver position math, in one place
- `AXWindow.swift` — `AXUIElement` wrapper (safe frame/position/title/pid access)
- `SliceCapturer.swift` — composited **display-region** captures (NOT window-filter captures) + per-window slice cache keyed by `(CGWindowID, DockEdge)` (survives cancel/re-dock)
- `SnapshotStrip.swift`, `HotkeyManager.swift`, `Config.swift`, `Log.swift`, `SelfTest.swift` — small supporting types

## Permissions

- **Accessibility** (`AXWindow.isProcessTrusted`) — required for moving/resizing windows; prompted at launch, status shown in the status-bar menu.
- **Screen Recording** — needed for fake-strip docks: up/down always, plus left/right on screen edges that are NOT the desktop's outer edge (a window can't leave the desktop there). The strip is a captured `SnapshotStrip` handle because macOS won't let a titled window leave those edges.

## State & paths

- Config: `~/.config/orbpeek/config.json` (auto-created with defaults; adjust dwells/sliver sizes there). Values are only read at launch.
- Log: `~/Library/Logs/orbpeek.log` (also written to stderr). `Log.info` is the debug tracing mechanism.
- Launch-at-login writes `~/Library/LaunchAgents/com.orbpeek.OrbPeek.plist` pointing at the current binary path.
- Hotkeys: `Ctrl+←/→/↑/↓` dock the frontmost window.

## Code conventions

- **Main-thread model is enforced at compile time**: `OrbPeekController`, `ManagedWindow`, `SliceCapturer`, and the `WindowDockDelegate` protocol are all `@MainActor`. Nonisolated callbacks (Timer, `NSEvent` monitors, hotkey/signal handlers) hop to the main actor via `Task { @MainActor in ... }` — follow that pattern for any new callback.
- **Phase transitions are the only place `ManagedWindow.phase` changes**, and each transition resets transient dwell state (`DwellTracker`) — put phase changes in transitions, not in `evaluate`.
- Coordinate gotcha: AX frames are top-left origin, `NSEvent.mouseLocation` is bottom-left. Always convert through `WindowGeometry.toQuartz`/`toAppKit`; never mix spaces (geometry functions return `CGPoint?`/`CGRect` computed from `outerScreen`, which falls back safely when no screen is found).
- Dock edges are **per-screen**: each window records its dock screen (`ManagedWindow.dockScreenID`, picked from the on-screen frame at dock time). left/right use the window's own visible sliver only on the desktop's outer edges; up/down and middle edges use the fake snapshot strip (`isFakeEdge`). `sliverRect` computes the hover hit region (thickness = `sliverPx` real / `fakeSliverPx` fake); `sliverLength` is the size along the sliver used to pick the smallest window on overlap.
- Re-docking a hidden window: the live frame is the parked position, so perp comes from `restoreFrame` and the dock screen is kept as-is — never derive either from the parked frame.
- `SliceCapturer` caches `SCShareableContent` and only refreshes when the cached window frame no longer matches — stale window lists are a known cause of slow/missing fake-strip captures.
- Strip images come from **display-region** captures (`SCContentFilter(display:...)` of `sliceScreenRect`) so translucency/shadow/rounded corners look exactly like the real window on screen. Window-filter captures return the raw flattened surface (vibrancy loses its backdrop blend) — don't use them. Window-filter `captureImage` also **randomly stalls ~1s**; display captures don't (~50ms).
- The composited capture needs the window on screen, so fake docks **capture first, park after** (`ManagedWindow.parking` suppresses the poll's snap-back meanwhile; 300ms timeout parks regardless). Slice content mimics the window really sliding off the edge: the **opposite** edge stays visible (up → bottom slice, down → title bar, left → right edge, right → left edge — same as the real slivers' trailing 6px).
- On SIGTERM/SIGINT/terminate, docked windows are restored via `restoreAll()` before exit.
