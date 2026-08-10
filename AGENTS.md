# OrbPeek

macOS menu-bar app that docks the frontmost window off-screen and slides it back in when hovered. No Xcode project, no `Package.swift` — plain `swiftc` over a `Sources/` directory.

## Build & run

- Build: `./build.sh` (runs `swiftc Sources/*.swift -o OrbPeek`; the app entry is `@main static func main()` on `OrbPeekController`, frameworks auto-link — no extra flags)
- Run: `~/Codes/OrbPeek/OrbPeek` (binary and logs are gitignored)
- Self-test: `OrbPeek --self-test` — verifies Accessibility trust and moves the focused window +30px, then restores it. Must keep Terminal frontmost, else it exits(1).

## Source layout (`Sources/`)

- `OrbPeekController.swift` — `@main` entry + app delegate: status item, menu (Chinese UI strings — keep them that way), hotkeys, 30 Hz `poll()`, docking orchestration
- `ManagedWindow.swift` — per-window state machine; talks to the app only through the `WindowDockDelegate` protocol (defined here)
- `Geometry.swift` — `DockEdge` + `WindowGeometry`: **all** coordinate conversion and dock/peek/sliver position math, in one place
- `AXWindow.swift` — `AXUIElement` wrapper (safe frame/position/title/pid access)
- `SliceCapturer.swift` — ScreenCaptureKit slice capture + cached `SCShareableContent`
- `SnapshotStrip.swift`, `HotkeyManager.swift`, `Config.swift`, `Log.swift`, `SelfTest.swift` — small supporting types

## Permissions

- **Accessibility** (`AXWindow.isProcessTrusted`) — required for moving/resizing windows; prompted at launch, status shown in the status-bar menu.
- **Screen Recording** — only needed for up/down docks (`DockEdge.isFake`), which use a captured `SnapshotStrip` handle because macOS won't let a titled window leave the top/bottom screen edge.

## State & paths

- Config: `~/.config/orbpeek/config.json` (auto-created with defaults; adjust dwells/sliver sizes there). Values are only read at launch.
- Log: `~/Library/Logs/orbpeek.log` (also written to stderr). `Log.info` is the debug tracing mechanism.
- Launch-at-login writes `~/Library/LaunchAgents/com.orbpeek.OrbPeek.plist` pointing at the current binary path.
- Hotkeys: `Ctrl+←/→/↑/↓` dock the frontmost window.

## Code conventions

- **Main-thread model is enforced at compile time**: `OrbPeekController`, `ManagedWindow`, `SliceCapturer`, and the `WindowDockDelegate` protocol are all `@MainActor`. Nonisolated callbacks (Timer, `NSEvent` monitors, hotkey/signal handlers) hop to the main actor via `Task { @MainActor in ... }` — follow that pattern for any new callback.
- **Phase transitions are the only place `ManagedWindow.phase` changes**, and each transition resets transient dwell state (`DwellTracker`) — put phase changes in transitions, not in `evaluate`.
- Coordinate gotcha: AX frames are top-left origin, `NSEvent.mouseLocation` is bottom-left. Always convert through `WindowGeometry.toQuartz`/`toAppKit`; never mix spaces (geometry functions return `CGPoint?`/`CGRect` computed from `outerScreen`, which falls back safely when no screen is found).
- Dock edges: left/right use the window's own visible sliver; up/down use the fake snapshot strip. `sliverRect` computes the hover hit region; `sliverLength` is the size along the sliver used to pick the smallest window on overlap.
- `SliceCapturer` caches `SCShareableContent` and only refreshes when the cached window frame no longer matches — stale window lists are a known cause of slow/missing fake-strip captures.
- On SIGTERM/SIGINT/terminate, docked windows are restored via `restoreAll()` before exit.
