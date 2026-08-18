import AppKit
import Foundation

// What a ManagedWindow needs from the rest of the app. Implemented by
// OrbPeekController; injecting a protocol (instead of the controller directly)
// keeps the state machine decoupled and geometry/capture testable.
@MainActor
protocol WindowDockDelegate: AnyObject {
    var config: Config { get }
    var geometry: WindowGeometry { get }
    var capturer: SliceCapturer { get }
    func nameForWindow(_ window: AXWindow) -> String
    func activate(window: AXWindow)
    func isFrontmost(_ window: AXWindow) -> Bool
    func isAppHidden(_ window: AXWindow) -> Bool
    func removeManaged(_ m: ManagedWindow)
}

// Per-window state machine. Phases: `.idle` (created, never docked), `.docked`
// (hidden, handle visible), `.docking` (transitioning to docked — capture in
// flight, window still on screen), `.peeked` (shown flush against the edge).
//
// Transitions are the only places `phase` changes, and each transition resets
// the transient dwell state. A transition is at most one in-flight Task per
// window (`transition`): starting a new transition cancels the previous one,
// and superseded tasks discard themselves at the `Task.isCancelled` check —
// so rapid re-docks can't apply stale state out of order.
@MainActor
final class ManagedWindow {
    enum Phase {
        case idle, docked, docking, peeked
        var isDocked: Bool { self == .docked }
        var isPeeked: Bool { self == .peeked }
    }

    let window: AXWindow
    // Stable ordering tiebreak for overlapping slivers (same-size windows).
    let id = UUID()
    weak var delegate: WindowDockDelegate?

    // Which edge the window is docked to.
    private(set) var edge: DockEdge
    // The screen whose edge the window is docked to (stable display ID, so
    // screen hot-plug falls back gracefully). Picked from the window's frame
    // whenever the window is on-screen; kept as-is when re-docking hidden,
    // because a parked frame resolves to the wrong screen.
    private var dockScreenID: CGDirectDisplayID?
    // Preserved coordinate along the perpendicular axis — never moved when docking.
    var perp: CGFloat = 0
    // The on-screen frame at dock time, used to restore on quit.
    var restoreFrame: CGRect = .zero
    // The fake snapshot strip handle.
    private var fakeStrip: SnapshotStrip?
    // The window's CGWindowID (stable for its lifetime), resolved on first dock.
    private(set) var windowID: CGWindowID?
    // The in-flight transition task (docks are async — they capture before
    // parking). A new transition cancels it.
    private var transition: Task<Void, Never>?

    private(set) var phase: Phase = .idle

    // User is dragging the peeked window (native move/resize).
    var gesture = false
    // Consecutive ticks where the window frame could not be read (closed window).
    private var nilCount = 0
    private var valid = true

    // Transient hover/dwell timers, reset on every transition.
    private var dwell = DwellTracker()

    init(window: AXWindow, edge: DockEdge, delegate: WindowDockDelegate) {
        self.window = window
        self.edge = edge
        self.delegate = delegate
    }

    var appName: String { delegate?.nameForWindow(window) ?? "窗口" }

    // The stored dock screen, with fallbacks if it was unplugged.
    func dockScreen(in geometry: WindowGeometry) -> NSScreen? {
        if let id = dockScreenID, let s = geometry.screen(withDisplayID: id) { return s }
        return NSScreen.main ?? NSScreen.screens.first
    }

    // MARK: Transitions

    // Dock (hide off the edge). `newEdge` re-docks to a different edge; nil
    // re-docks to the current edge (also how a peeked window hides again).
    func dock(to newEdge: DockEdge? = nil) {
        let t0 = Date()
        guard valid, let frame = window.frame, let delegate else { return }
        transition?.cancel()
        // "Hidden" == parked by a previous dock. During .idle/.docking/.peeked
        // the window is on screen.
        let wasHidden = phase == .docked
        if let newEdge { edge = newEdge }
        let geometry = delegate.geometry
        // Re-pick the dock screen whenever the window is on screen.
        if phase != .docked, let screen = geometry.screen(containing: frame) {
            dockScreenID = geometry.displayID(of: screen)
        }
        guard let screen = dockScreen(in: geometry) else { return }
        window.unminimize()
        dwell.reset()
        phase = .docking
        transition = Task { [weak self] in
            await self?.finishDock(frame: frame, screen: screen, wasHidden: wasHidden)
        }
        Log.info("dock applied in \(Int(Date().timeIntervalSince(t0) * 1000))ms edge=\(edge)")
    }

    // The async half of every dock: while the window is still on screen,
    // capture all four edge slices (~50ms, 300ms timeout), then park and show
    // the strip. Even though only one slice is shown, capturing all four fills
    // the cache, so a later hidden re-dock to any edge always has content.
    // The strip is shown only after the capture, so it can never photograph
    // itself.
    //
    // A hidden re-dock takes no capture: the window is parked off-screen, and
    // capturing would require flashing it on screen. It just re-parks at the
    // new edge and shows the cached slice or a placeholder.
    //
    // Runs on the MainActor; discards itself if a newer transition cancelled it.
    private func finishDock(frame: CGRect, screen: NSScreen, wasHidden: Bool) async {
        if Task.isCancelled { return }
        guard let delegate else { return }
        let geometry = delegate.geometry
        let config = delegate.config
        let capturer = delegate.capturer
        let edge = edge
        let stripFrame = geometry.toAppKit(
            geometry.sliverRect(edge: edge, size: frame.size, perp: perp, screen: screen, thickness: config.sliverPx)
        )
        let hiddenPos = geometry.hiddenPosition(for: edge, size: frame.size, perp: perp, screen: screen)
        if windowID == nil {
            windowID = window.pid.flatMap { capturer.windowID(for: $0, matching: frame) }
        }
        let cached = windowID.flatMap { capturer.cachedSlice(for: $0, edge: edge, size: frame.size, thickness: config.sliverPx) }

        if fakeStrip == nil { fakeStrip = SnapshotStrip() }

        if wasHidden {
            moveTo(hiddenPos)
            phase = .docked
            Log.info("hidden re-dock: strip from \(cached != nil ? "cache" : "placeholder") edge=\(edge)")
            fakeStrip?.show(image: cached, frame: stripFrame, edge: edge) // cached or placeholder
            return
        }

        // Only capture when the window is frontmost — a dockBack triggered by
        // focus loss can find another window already covering the region, and
        // a composited display capture would then photograph the WRONG window.
        // Also skip when the slice's screen region is off the display —
        // off-screen pixels capture as blank.
        let sliceOnScreen = geometry.quartzFrame(of: screen)
            .contains(geometry.sliceScreenRect(edge: edge, frame: frame, thickness: config.sliverPx))
        let canCapture = sliceOnScreen && delegate.isFrontmost(window)
        let fullImage = canCapture
            ? await withTimeout(0.3) { [dockScreenID, windowID] in
                await capturer.captureWindow(frame: frame, displayID: dockScreenID, windowID: windowID)
            }
            : nil
        if Task.isCancelled { return }
        moveTo(hiddenPos)
        phase = .docked
        guard let fakeStrip else { return }
        let fresh = fullImage.flatMap { capturer.slice(from: $0, edge: edge, windowSize: frame.size, thickness: config.sliverPx) }
        fakeStrip.show(image: fresh ?? cached, frame: stripFrame, edge: edge)
    }

    // Show flush against the edge.
    func peek() {
        let t0 = Date()
        guard valid, let frame = window.frame, let delegate else { return }
        guard let screen = dockScreen(in: delegate.geometry) else { return }
        transition?.cancel()
        transition = nil
        window.unminimize()
        phase = .peeked
        dwell.reset()
        dwell.shownSince = Date()
        fakeStrip?.hide()
        window.raise()
        delegate.activate(window: window)
        moveTo(delegate.geometry.peekPosition(for: edge, size: frame.size, perp: perp, screen: screen))
        Log.info("peek applied in \(Int(Date().timeIntervalSince(t0) * 1000))ms edge=\(edge)")
    }

    // Where the window is left when tracking stops.
    enum ExitPosition {
        case restore // the original pre-dock frame (menu cancel / quit / dropped window)
        case leave // something external already put it somewhere visible
    }

    // Stop tracking. The only terminal path — every exit (menu cancel, drag
    // out, external takeover, window gone, quit) funnels through here.
    func terminate(exit: ExitPosition) {
        guard valid else { return }
        transition?.cancel()
        switch exit {
        case .restore:
            window.position = restoreFrame.origin
        case .leave:
            break
        }
        detachStrip()
        valid = false
        Log.info("terminate edge=\(edge) exit=\(exit)")
        delegate?.removeManaged(self)
    }

    // Called on drag release: pulled off the edge -> cancel; otherwise remember
    // the new parallel position.
    func checkDragOut() {
        guard phase == .peeked, let frame = window.frame, let delegate else { return }
        let geometry = delegate.geometry
        guard let screen = dockScreen(in: geometry) else { return }
        if geometry.distanceFromDockEdge(frame, edge: edge, screen: screen) > delegate.config.dockCancelPx {
            terminate(exit: .leave)
        } else {
            perp = geometry.dockPerp(for: edge, frame: frame)
        }
    }

    // Restore on quit (no removal — the controller tears down the list itself).
    func restore() {
        guard valid else { return }
        transition?.cancel()
        detachStrip()
        window.position = restoreFrame.origin
        valid = false
    }

    // Hide and drop the strip (when the dock is cancelled, or on quit).
    func detachStrip() {
        fakeStrip?.hide()
        fakeStrip = nil
    }

    // Strips float above normal windows so they're clickable handles — but
    // while a window is peeked it owns the edge, so strips drop to normal
    // level and can't cover it.
    func setStripFloating(_ floating: Bool) {
        guard let fakeStrip else { return }
        let target: NSWindow.Level = floating ? .floating : .normal
        if fakeStrip.level != target { fakeStrip.level = target }
    }

    private func moveTo(_ pos: CGPoint?) {
        guard let pos else { return }
        window.position = pos
    }

    // MARK: Poll evaluation

    func evaluate(mouseQ: CGPoint, mouseVelocity: CGPoint, frontmost: Bool, blockedByPeeked: Bool, blockedBySmaller: Bool, settling: Bool, now: Date) {
        guard valid, let delegate else { return }
        guard let frame = window.frame else {
            nilCount += 1
            if nilCount > 30 {
                // AX read failure is ambiguous: window closed vs. app hung
                // (AX reads time out while the app beachballs). CGWindowList
                // is window-server level and answers either way — only drop
                // when the window is really gone, else wait the hang out.
                if let wid = windowID, delegate.capturer.windowExists(wid) {
                    nilCount = 30
                    return
                }
                Log.info("window frame unreadable, dropping edge=\(edge)")
                terminate(exit: .restore)
            }
            return
        }
        nilCount = 0
        guard !gesture else { return }
        // External window lifecycle ops (hide/minimize) can arrive in ANY
        // phase — they mean the user tucked the window away, so release it
        // with its original frame restored, regardless of state.
        if window.isMinimized || window.isAppHidden {
            Log.info("window tucked away by user (min=\(window.isMinimized) hidden=\(window.isAppHidden)), releasing edge=\(edge)")
            terminate(exit: .restore)
            return
        }

        let config = delegate.config
        let geometry = delegate.geometry
        let capturer = delegate.capturer
        guard let screen = dockScreen(in: geometry) else { return }

        switch phase {
        case .peeked:
            if settling {
                // Screen-set change: macOS may have shuffled the window —
                // re-anchor it flush to the (possibly fallback) screen edge,
                // keeping the stored perp untouched.
                if let pos = geometry.peekPosition(for: edge, size: frame.size, perp: perp, screen: screen),
                   abs(frame.origin.x - pos.x) > 1 || abs(frame.origin.y - pos.y) > 1 {
                    moveTo(pos)
                }
            } else {
                perp = geometry.dockPerp(for: edge, frame: frame)
            }
            let inWin = frame.insetBy(dx: -config.edgeBuffer, dy: -config.edgeBuffer).contains(mouseQ)
            dwell.noteHover(inWin, touchDwell: config.touchDwell, now: now)
            let sliver = geometry.sliverRect(edge: edge, size: frame.size, perp: perp, screen: screen,
                                             thickness: config.sliverPx)
            let onSliver = sliver.insetBy(dx: -6, dy: -6).contains(mouseQ)
            // A short settle window right after peeking, so none of the hide
            // conditions below fire while the user is still approaching.
            let inGrace = dwell.shownSince.map { now.timeIntervalSince($0) < 0.6 } ?? false
            if !inGrace {
                // Externally displaced (another tool moved/resized it away from
                // the edge; user drags set `gesture` and never reach here) —
                // treat like a drag-out: undock, leave the window where it is.
                // Suppressed while settling (sleep/lock/display reshuffle).
                if !settling, geometry.distanceFromDockEdge(frame, edge: edge, screen: screen) > config.dockCancelPx {
                    Log.info("peeked window displaced externally, undocking edge=\(edge)")
                    terminate(exit: .leave)
                    return
                }
                let lostFocus = !frontmost
                let touchedAndLeft = dwell.touched && !inWin
                let untouchedAndAway = !dwell.touched && !inWin && !onSliver
                if lostFocus || touchedAndLeft || untouchedAndAway {
                    dock(to: nil)
                }
            }
        case .docked:
            let target = geometry.hiddenPosition(for: edge, size: frame.size, perp: perp, screen: screen)
            let drift = max(abs(frame.origin.x - target.x), abs(frame.origin.y - target.y))
            if drift > config.dockCancelPx, !settling {
                // Something external deliberately moved the window away — the
                // user wants it there, so release the dock instead of fighting
                // over the position every tick.
                Log.info("docked window moved externally, releasing edge=\(edge)")
                terminate(exit: .leave)
                return
            }
            // Minor drift — snap back. During settling (wake / display change)
            // even large drift is macOS reshuffling windows, so always snap.
            if drift > 2 {
                moveTo(target)
            }
            // Keep the strip in sync (e.g. sliverPx changed in settings):
            // re-crop from the full-image cache at the new thickness, else
            // just update the frame.
            if let fakeStrip {
                let expected = geometry.toAppKit(
                    geometry.sliverRect(edge: edge, size: frame.size, perp: perp, screen: screen, thickness: config.sliverPx)
                )
                if fakeStrip.thickness != config.sliverPx, let wid = windowID,
                   let img = capturer.cachedSlice(for: wid, edge: edge, size: frame.size, thickness: config.sliverPx) {
                    fakeStrip.show(image: img, frame: expected, edge: edge)
                } else if fakeStrip.frame != expected {
                    fakeStrip.updateFrame(expected, edge: edge)
                }
                let opacity = CGFloat(config.stripOpacity)
                if fakeStrip.alphaValue != opacity {
                    fakeStrip.alphaValue = opacity
                }
            }
            // Hover the handle to slide in (smallest window wins on overlap).
            let sliver = geometry.sliverRect(edge: edge, size: frame.size, perp: perp, screen: screen,
                                             thickness: config.sliverPx)
            if sliver.insetBy(dx: -6, dy: -6).contains(mouseQ), !blockedByPeeked, !blockedBySmaller {
                if dwell.sliverSince == nil {
                    dwell.sliverSince = now
                    // Fast movement toward the edge = deliberate slam: skip the dwell.
                    let toward: CGFloat
                    switch edge {
                    case .up: toward = -mouseVelocity.y
                    case .down: toward = mouseVelocity.y
                    case .left: toward = -mouseVelocity.x
                    case .right: toward = mouseVelocity.x
                    }
                    dwell.slammed = toward > config.slamVelocity
                }
                if dwell.slammed {
                    Log.info("slam -> peek edge=\(edge)")
                    peek()
                } else if let since = dwell.sliverSince, now.timeIntervalSince(since) >= config.peekDwell {
                    Log.info("hover -> peek \(Int(now.timeIntervalSince(since) * 1000))ms edge=\(edge)")
                    peek()
                }
            } else {
                dwell.sliverSince = nil
                dwell.slammed = false
            }
        case .idle, .docking:
            // Never docked yet, or a transition is in flight (window still on
            // screen, strip not shown) — nothing to evaluate.
            break
        }
    }
}

// Race an async value against a timeout; nil means timeout (or the work failed).
private func withTimeout<T>(_ seconds: Double, _ work: @escaping () async -> T?) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await work() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        let result = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}

// Transient hover/dwell timers for a managed window, reset on every transition.
private struct DwellTracker {
    private(set) var touched = false
    private(set) var inWinSince: Date?
    var sliverSince: Date?
    var shownSince: Date?
    var slammed = false

    mutating func noteHover(_ inWin: Bool, touchDwell: TimeInterval, now: Date) {
        if inWin {
            if inWinSince == nil {
                inWinSince = now
            } else if !touched, let since = inWinSince, now.timeIntervalSince(since) >= touchDwell {
                touched = true
            }
        } else {
            inWinSince = nil
        }
    }

    mutating func reset() {
        touched = false
        inWinSince = nil
        sliverSince = nil
        shownSince = nil
        slammed = false
    }
}
