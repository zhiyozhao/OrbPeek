import AppKit
import Foundation

@MainActor
package protocol WindowDockDelegate: AnyObject {
    var config: DockConfiguration { get }
    var geometry: WindowGeometry { get }
    var capturer: any SliceCapturing { get }
    func makeStrip() -> any SnapshotStripHandling
    func nameForWindow(_ window: any WindowHandle) -> String
    func activate(window: any WindowHandle)
    func isFrontmost(_ window: any WindowHandle) -> Bool
    func removeManaged(_ managed: ManagedWindow)
}

// Per-window state machine. Phases: idle, docked, docking (capture in flight),
// and peeked. Transitions are serialized by one cancellable Task per window.
@MainActor
package final class ManagedWindow {
    package enum Phase {
        case idle, docked, docking, peeked
        package var isDocked: Bool { self == .docked }
        package var isPeeked: Bool { self == .peeked }
    }

    package let window: any WindowHandle
    package let id = UUID()
    package weak var delegate: (any WindowDockDelegate)?
    package private(set) var edge: DockEdge
    private var dockScreenID: CGDirectDisplayID?
    package var perp: CGFloat = 0
    package var restoreFrame: CGRect = .zero
    private var fakeStrip: (any SnapshotStripHandling)?
    package private(set) var windowID: CGWindowID?
    private var transition: Task<Void, Never>?
    package private(set) var phase: Phase = .idle
    package var gesture = false
    private var nilCount = 0
    private var valid = true
    private var bigDriftSince: Date?
    private var dwell = DwellTracker()
    package var clock: () -> Date

    package init(window: any WindowHandle, edge: DockEdge, delegate: any WindowDockDelegate,
                 clock: @escaping () -> Date = Date.init) {
        self.window = window
        self.edge = edge
        self.delegate = delegate
        self.clock = clock
    }

    package var appName: String { delegate?.nameForWindow(window) ?? "Window" }

    package func dockScreen(in geometry: WindowGeometry) -> ScreenInfo? {
        if let id = dockScreenID, let screen = geometry.screen(withDisplayID: id) { return screen }
        return geometry.layout.primary
    }

    // MARK: Transitions

    package func dock(to newEdge: DockEdge? = nil) {
        let t0 = clock()
        guard valid, let frame = window.frame, let delegate else { return }
        transition?.cancel()
        let wasHidden = phase == .docked
        if let newEdge { edge = newEdge }
        let geometry = delegate.geometry
        if phase != .docked, let screen = geometry.screen(containing: frame) {
            dockScreenID = screen.id
        }
        guard let screen = dockScreen(in: geometry) else { return }
        window.unminimize()
        dwell.reset()
        phase = .docking
        transition = Task { [weak self] in
            await self?.finishDock(frame: frame, screen: screen, wasHidden: wasHidden)
        }
        Log.info("dock applied in \(Int(clock().timeIntervalSince(t0) * 1000))ms edge=\(edge)")
    }

    private func finishDock(frame: CGRect, screen: ScreenInfo, wasHidden: Bool) async {
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

        if fakeStrip == nil { fakeStrip = delegate.makeStrip() }

        if wasHidden {
            moveTo(hiddenPos)
            phase = .docked
            Log.info("hidden re-dock: strip from \(cached != nil ? "cache" : "placeholder") edge=\(edge)")
            fakeStrip?.show(image: cached, frame: stripFrame, edge: edge)
            return
        }

        let sliceOnScreen = geometry.quartzFrame(of: screen)
            .contains(geometry.sliceScreenRect(edge: edge, frame: frame, thickness: config.sliverPx))
        let canCapture = sliceOnScreen && delegate.isFrontmost(window)
        let fullImage = canCapture
            ? await capturer.captureWindow(frame: frame, displayID: dockScreenID, windowID: windowID)
            : nil
        if canCapture && fullImage == nil {
            Log.info("capture FAILED edge=\(edge) — strip shows cache/placeholder")
        }
        if Task.isCancelled { return }
        moveTo(hiddenPos)
        phase = .docked
        guard let fakeStrip else { return }
        let fresh = fullImage.flatMap { capturer.slice(from: $0, edge: edge, windowSize: frame.size, thickness: config.sliverPx) }
        fakeStrip.show(image: fresh ?? cached, frame: stripFrame, edge: edge)
    }

    package func peek() {
        let t0 = clock()
        guard valid, let frame = window.frame, let delegate else { return }
        guard let screen = dockScreen(in: delegate.geometry) else { return }
        transition?.cancel()
        transition = nil
        window.unminimize()
        phase = .peeked
        dwell.reset()
        dwell.shownSince = clock()
        fakeStrip?.hide()
        window.raise()
        delegate.activate(window: window)
        moveTo(delegate.geometry.peekPosition(for: edge, size: frame.size, perp: perp, screen: screen))
        Log.info("peek applied in \(Int(clock().timeIntervalSince(t0) * 1000))ms edge=\(edge)")
    }

    package enum ExitPosition {
        case restore
        case leave
    }

    package func terminate(exit: ExitPosition) {
        guard valid else { return }
        transition?.cancel()
        switch exit {
        case .restore: window.position = restoreFrame.origin
        case .leave: break
        }
        detachStrip()
        valid = false
        Log.info("terminate edge=\(edge) exit=\(exit)")
        delegate?.removeManaged(self)
    }

    package func checkDragOut() {
        guard phase == .peeked, let frame = window.frame, let delegate else { return }
        let geometry = delegate.geometry
        guard let screen = dockScreen(in: geometry) else { return }
        if geometry.distanceFromDockEdge(frame, edge: edge, screen: screen) > delegate.config.dockCancelPx {
            terminate(exit: .leave)
        } else {
            perp = geometry.dockPerp(for: edge, frame: frame)
        }
    }

    package func restore() {
        guard valid else { return }
        transition?.cancel()
        detachStrip()
        window.position = restoreFrame.origin
        valid = false
    }

    package func detachStrip() {
        fakeStrip?.hide()
        fakeStrip = nil
    }

    package func setStripFloating(_ floating: Bool) {
        guard let fakeStrip else { return }
        let target: NSWindow.Level = floating ? .floating : .normal
        if fakeStrip.level != target { fakeStrip.level = target }
    }

    private func moveTo(_ pos: CGPoint?) {
        guard let pos else { return }
        window.position = pos
    }

    // MARK: Poll evaluation

    package func evaluate(mouseQ: CGPoint, mouseVelocity: CGPoint, frontmost: Bool,
                          blockedByPeeked: Bool, blockedBySmaller: Bool, settling: Bool, now: Date) {
        guard valid, let delegate else { return }
        guard let frame = window.frame else {
            nilCount += 1
            if nilCount > 30 {
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
        if window.isMinimized || window.isAppHidden {
            Log.info("window tucked away by user, releasing edge=\(edge)")
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
            let inGrace = dwell.shownSince.map { now.timeIntervalSince($0) < 0.6 } ?? false
            if !inGrace {
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
                if bigDriftSince == nil {
                    bigDriftSince = now
                    Log.info("big drift \(Int(drift)) edge=\(edge), grace before release")
                }
                if now.timeIntervalSince(bigDriftSince ?? now) >= 0.5 {
                    Log.info("docked window moved externally, releasing edge=\(edge)")
                    terminate(exit: .leave)
                }
                return
            }
            bigDriftSince = nil
            if drift > 2 {
                if settling && drift > config.dockCancelPx {
                    Log.info("settling re-anchor edge=\(edge) drift=\(Int(drift))")
                }
                moveTo(target)
            }
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
                if fakeStrip.alphaValue != opacity { fakeStrip.alphaValue = opacity }
            }
            let sliver = geometry.sliverRect(edge: edge, size: frame.size, perp: perp, screen: screen,
                                             thickness: config.sliverPx)
            if sliver.insetBy(dx: -6, dy: -6).contains(mouseQ), !blockedByPeeked, !blockedBySmaller {
                if dwell.sliverSince == nil {
                    dwell.sliverSince = now
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
            break
        }
    }
}

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
