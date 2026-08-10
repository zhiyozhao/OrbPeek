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
    func removeManaged(_ m: ManagedWindow)
}

// Per-window state machine. A managed window is either hidden (docked, handle
// visible) or shown (peeked, flush against its edge). Transitions are the only
// places `phase` changes, and each transition resets the transient dwell state.
@MainActor
final class ManagedWindow {
    enum Phase {
        case docked, peeked
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
    // Whether this dock uses the fake snapshot strip (up/down always; left/
    // right when another screen sits beyond the edge). Set on every dock.
    private(set) var isFake = false
    // Preserved coordinate along the perpendicular axis — never moved when docking.
    var perp: CGFloat = 0
    // The on-screen frame at dock time, used to restore on quit.
    var restoreFrame: CGRect = .zero
    // The fake snapshot strip handle, only for fake-edge docks.
    private var fakeStrip: SnapshotStrip?
    // A capture-then-park is in flight: the composited capture needs the window
    // on screen, so parking waits for it (bounded by a timeout). While set, the
    // poll's snap-back must not fire.
    private var parking = false

    private(set) var phase: Phase = .docked

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
        if let newEdge { edge = newEdge }
        let geometry = delegate.geometry
        if dockScreenID == nil || phase == .peeked, let screen = geometry.screen(containing: frame) {
            dockScreenID = geometry.displayID(of: screen)
        }
        guard let screen = dockScreen(in: geometry) else { return }
        isFake = geometry.isFakeEdge(edge, on: screen)
        window.unminimize()
        phase = .docked
        dwell.reset()
        if isFake {
            if fakeStrip == nil { fakeStrip = SnapshotStrip() }
            showFakeStripAndPark(frame: frame, screen: screen)
        } else {
            detachStrip()
            moveTo(geometry.hiddenPosition(for: edge, fake: false, size: frame.size, perp: perp, screen: screen, sliver: delegate.config.sliverPx))
        }
        Log.info("dock applied in \(Int(Date().timeIntervalSince(t0) * 1000))ms edge=\(edge) fake=\(isFake)")
    }

    // Show flush against the edge.
    func peek() {
        let t0 = Date()
        guard valid, let frame = window.frame, let delegate else { return }
        guard let screen = dockScreen(in: delegate.geometry) else { return }
        parking = false
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

    func togglePeek() {
        phase == .peeked ? dock(to: nil) : peek()
    }

    // Stop tracking. A still-docked window is brought back flush first so it is
    // never left invisible; a peeked window stays where it is.
    func cancel() {
        guard valid else { return }
        parking = false
        if phase == .docked, let frame = window.frame, let delegate,
           let screen = dockScreen(in: delegate.geometry) {
            moveTo(delegate.geometry.peekPosition(for: edge, size: frame.size, perp: perp, screen: screen))
        }
        detachStrip()
        valid = false
        delegate?.removeManaged(self)
    }

    // Called on drag release: pulled off the edge -> cancel; otherwise remember
    // the new parallel position.
    func checkDragOut() {
        guard phase == .peeked, let frame = window.frame, let delegate else { return }
        let geometry = delegate.geometry
        guard let screen = dockScreen(in: geometry) else { return }
        if geometry.distanceFromDockEdge(frame, edge: edge, screen: screen) > delegate.config.dockCancelPx {
            cancel()
        } else {
            perp = geometry.dockPerp(for: edge, frame: frame)
        }
    }

    // Restore on quit.
    func restore() {
        guard valid else { return }
        parking = false
        detachStrip()
        window.position = restoreFrame.origin
        valid = false
    }

    // Hide and drop the fake handle strip (used when the dock becomes a real
    // edge, when the window is cancelled, or on quit).
    func detachStrip() {
        fakeStrip?.hide()
        fakeStrip = nil
    }

    private func moveTo(_ pos: CGPoint?) {
        guard let pos else { return }
        window.position = pos
    }

    // Capture-then-park with the strip showing the fresh slice: the composited
    // display capture needs the window on screen and is fast (~50ms), so the
    // flow is simply: capture -> park -> show strip. `parking` suppresses the
    // poll's snap-back meanwhile; the timeout is the backstop against stalls.
    // Tasks inherit MainActor, so the strip is only ever touched on the main thread.
    private func showFakeStripAndPark(frame: CGRect, screen: NSScreen) {
        guard let fakeStrip, let delegate else { return }
        let geometry = delegate.geometry
        let config = delegate.config
        let stripFrame = geometry.toAppKit(
            geometry.sliverRect(edge: edge, size: frame.size, perp: perp, screen: screen, thickness: config.sliverPx)
        )
        let hiddenPos = geometry.hiddenPosition(for: edge, fake: true, size: frame.size, perp: perp,
                                                screen: screen, sliver: config.sliverPx)
        parking = true
        let sliceRect = geometry.sliceScreenRect(edge: edge, frame: frame, thickness: config.sliverPx)
        let displayID = dockScreenID
        let edge = edge
        let capturer = delegate.capturer

        Task { [weak self, weak fakeStrip] in
            let image = await capturer.captureSlice(screenRect: sliceRect, displayID: displayID)
            guard let self, self.valid else { return }
            if self.parking {
                self.parking = false
                self.moveTo(hiddenPos)
            }
            // A capture can land after the user already peeked — never re-show
            // the strip over a peeked window.
            guard let fakeStrip, self.phase == .docked else { return }
            if let image {
                fakeStrip.show(image: image, frame: stripFrame)
            } else if !fakeStrip.hasContent {
                fakeStrip.show(image: nil, frame: stripFrame)
            }
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, self.valid, self.parking else { return }
            Log.info("park after capture timeout edge=\(edge)")
            self.parking = false
            self.moveTo(hiddenPos)
        }
    }

    // MARK: Poll evaluation

    @discardableResult
    func evaluate(mouseQ: CGPoint, frontmost: Bool, blockedByPeeked: Bool, blockedBySmaller: Bool, now: Date) -> Bool {
        guard valid, let delegate else { return false }
        guard let frame = window.frame else {
            nilCount += 1
            return nilCount > 30
        }
        nilCount = 0
        guard !gesture else { return false }

        let config = delegate.config
        let geometry = delegate.geometry
        guard let screen = dockScreen(in: geometry) else { return false }

        switch phase {
        case .peeked:
            perp = geometry.dockPerp(for: edge, frame: frame)
            let inWin = frame.insetBy(dx: -config.edgeBuffer, dy: -config.edgeBuffer).contains(mouseQ)
            dwell.noteHover(inWin, touchDwell: config.touchDwell, now: now)
            let sliver = geometry.sliverRect(edge: edge, size: frame.size, perp: perp, screen: screen,
                                             thickness: config.sliverPx)
            let onSliver = sliver.insetBy(dx: -6, dy: -6).contains(mouseQ)
            // A short settle window right after peeking, so none of the hide
            // conditions below fire while the user is still approaching.
            let inGrace = dwell.shownSince.map { now.timeIntervalSince($0) < 0.6 } ?? false
            let lostFocus = !frontmost
            let touchedAndLeft = dwell.touched && !inWin
            let untouchedAndAway = !dwell.touched && !inWin && !onSliver
            if !inGrace, lostFocus || touchedAndLeft || untouchedAndAway {
                dock(to: nil)
            }
        case .docked:
            // Snap back to the hidden position if it was moved externally
            // (but not while a capture-then-park is in flight — the window is
            // deliberately still on screen then).
            if !parking,
               let target = geometry.hiddenPosition(for: edge, fake: isFake, size: frame.size, perp: perp,
                                                    screen: screen, sliver: config.sliverPx),
               abs(frame.origin.x - target.x) > 2 || abs(frame.origin.y - target.y) > 2 {
                moveTo(target)
            }
            // Hover the handle to slide in (smallest window wins on overlap).
            let sliver = geometry.sliverRect(edge: edge, size: frame.size, perp: perp, screen: screen,
                                             thickness: config.sliverPx)
            if sliver.insetBy(dx: -6, dy: -6).contains(mouseQ), !blockedByPeeked, !blockedBySmaller {
                if dwell.sliverSince == nil {
                    dwell.sliverSince = now
                } else if let since = dwell.sliverSince, now.timeIntervalSince(since) >= config.peekDwell {
                    Log.info("hover -> peek \(Int(now.timeIntervalSince(since) * 1000))ms edge=\(edge)")
                    peek()
                }
            } else {
                dwell.sliverSince = nil
            }
        }
        return false
    }
}

// Transient hover/dwell timers for a managed window, reset on every transition.
private struct DwellTracker {
    private(set) var touched = false
    private(set) var inWinSince: Date?
    var sliverSince: Date?
    var shownSince: Date?

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
    }
}
