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

    // Which edge the window is docked to (left/right real sliver, up/down fake).
    private(set) var edge: DockEdge
    // Preserved coordinate along the perpendicular axis — never moved when docking.
    var perp: CGFloat = 0
    // The on-screen frame at dock time, used to restore on quit.
    var restoreFrame: CGRect = .zero
    // The fake snapshot strip handle, only for up/down docks.
    private var fakeStrip: SnapshotStrip?

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

    // MARK: Transitions

    // Dock (hide off the edge). `newEdge` re-docks to a different edge; nil
    // re-docks to the current edge (also how a peeked window hides again).
    func dock(to newEdge: DockEdge? = nil) {
        let t0 = Date()
        guard valid, let frame = window.frame, let delegate else { return }
        if let newEdge { edge = newEdge }
        window.unminimize()
        phase = .docked
        dwell.reset()
        if edge.isFake {
            if fakeStrip == nil { fakeStrip = SnapshotStrip() }
            showFakeStrip(frame: frame)
        } else {
            detachStrip()
        }
        moveTo(delegate.geometry.hiddenPosition(for: edge, size: frame.size, perp: perp, sliver: delegate.config.sliverPx))
        Log.info("dock applied in \(Int(Date().timeIntervalSince(t0) * 1000))ms edge=\(edge)")
    }

    // Show flush against the edge.
    func peek() {
        let t0 = Date()
        guard valid, let frame = window.frame, let delegate else { return }
        window.unminimize()
        phase = .peeked
        dwell.reset()
        dwell.shownSince = Date()
        fakeStrip?.hide()
        refreshSliceCache(frame: frame)
        window.raise()
        delegate.activate(window: window)
        moveTo(delegate.geometry.peekPosition(for: edge, size: frame.size, perp: perp))
        Log.info("peek applied in \(Int(Date().timeIntervalSince(t0) * 1000))ms edge=\(edge)")
    }

    func togglePeek() {
        phase == .peeked ? dock(to: nil) : peek()
    }

    // Stop tracking. A still-docked window is brought back flush first so it is
    // never left invisible; a peeked window stays where it is.
    func cancel() {
        guard valid else { return }
        if phase == .docked, let frame = window.frame, let delegate {
            moveTo(delegate.geometry.peekPosition(for: edge, size: frame.size, perp: perp))
        }
        detachStrip()
        valid = false
        delegate?.removeManaged(self)
    }

    // Called on drag release: pulled off the edge -> cancel; otherwise remember
    // the new parallel position.
    func checkDragOut() {
        guard phase == .peeked, let frame = window.frame, let delegate else { return }
        if let distance = delegate.geometry.distanceFromDockEdge(frame, edge: edge),
           distance > delegate.config.dockCancelPx {
            cancel()
        } else {
            perp = delegate.geometry.dockPerp(for: edge, frame: frame)
        }
    }

    // Restore on quit.
    func restore() {
        guard valid else { return }
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

    // Capture and show the fake strip handle (async — the cached slice shows
    // instantly, the fresh capture lands after). The Task inherits MainActor,
    // so the strip is only ever touched on the main thread.
    private func showFakeStrip(frame: CGRect) {
        guard let fakeStrip, let delegate else { return }
        let geometry = delegate.geometry
        let config = delegate.config
        let stripFrame = geometry.toAppKit(
            geometry.sliverRect(edge: edge, size: frame.size, perp: perp, sliver: config.sliverPx, fakeSliver: config.fakeSliverPx)
        )
        guard let pid = window.pid,
              let wid = delegate.capturer.windowID(for: pid, matching: frame) else { return }
        if let cached = delegate.capturer.cachedSlice(for: wid) {
            Log.info("strip shown from cache edge=\(edge)")
            fakeStrip.show(image: cached, frame: stripFrame)
        } else {
            Log.info("strip waiting for capture edge=\(edge)")
            // A cold capture occasionally stalls ~1s inside ScreenCaptureKit —
            // show the placeholder if the real slice doesn't land quickly.
            Task { [weak self, weak fakeStrip] in
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, let fakeStrip, self.phase == .docked, !fakeStrip.hasContent else { return }
                fakeStrip.show(image: nil, frame: stripFrame)
            }
        }
        let edge = edge
        let thickness = config.fakeSliverPx
        let capturer = delegate.capturer
        Task { [weak self, weak fakeStrip] in
            let image = await capturer.captureSlice(of: wid, frame: frame, edge: edge, sliceThickness: thickness)
            guard let self, let fakeStrip else { return }
            // A slow capture can land after the user already peeked — never
            // re-show the strip over a peeked window.
            guard self.phase == .docked else { return }
            fakeStrip.show(image: image, frame: stripFrame)
        }
    }

    // Refresh the strip image cache while the window is fully on-screen —
    // captures of a parked (1px-visible) window can stall ~1s inside
    // ScreenCaptureKit, so the cache is only trustworthy when filled here.
    private func refreshSliceCache(frame: CGRect) {
        guard edge.isFake, let delegate,
              let pid = window.pid,
              let wid = delegate.capturer.windowID(for: pid, matching: frame) else { return }
        let capturer = delegate.capturer
        let thickness = delegate.config.fakeSliverPx
        let edge = edge
        Task {
            _ = await capturer.captureSlice(of: wid, frame: frame, edge: edge, sliceThickness: thickness)
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

        switch phase {
        case .peeked:
            perp = geometry.dockPerp(for: edge, frame: frame)
            let inWin = frame.insetBy(dx: -config.edgeBuffer, dy: -config.edgeBuffer).contains(mouseQ)
            dwell.noteHover(inWin, touchDwell: config.touchDwell, now: now)
            let sliver = geometry.sliverRect(edge: edge, size: frame.size, perp: perp,
                                             sliver: config.sliverPx, fakeSliver: config.fakeSliverPx)
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
            // Snap back to the hidden position if it was moved externally.
            if let target = geometry.hiddenPosition(for: edge, size: frame.size, perp: perp, sliver: config.sliverPx),
               abs(frame.origin.x - target.x) > 2 || abs(frame.origin.y - target.y) > 2 {
                moveTo(target)
            }
            // Hover the handle to slide in (smallest window wins on overlap).
            let sliver = geometry.sliverRect(edge: edge, size: frame.size, perp: perp,
                                             sliver: config.sliverPx, fakeSliver: config.fakeSliverPx)
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
