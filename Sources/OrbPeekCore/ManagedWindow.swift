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
    // Parallel coordinate and restore origin are offsets from the recorded
    // screen's quartz visibleFrame, never absolute desktop coordinates.
    package var perp: CGFloat = 0
    private var restoreOffset: CGPoint = .zero
    private var restoreSize: CGSize = .zero
    package var restoreFrame: CGRect {
        guard let delegate, let screen = dockScreen(in: delegate.geometry) else {
            return CGRect(origin: restoreOffset, size: restoreSize)
        }
        let visible = delegate.geometry.quartzVisibleFrame(of: screen)
        return CGRect(x: visible.minX + restoreOffset.x, y: visible.minY + restoreOffset.y,
                      width: restoreSize.width, height: restoreSize.height)
    }
    private var fakeStrip: (any SnapshotStripHandling)?
    package private(set) var windowID: CGWindowID?
    private var transition: Task<Void, Never>?
    package private(set) var phase: Phase = .idle
    package var gesture = false
    private var gestureStartFrame: CGRect?
    private var gestureStartedOnDockedEdge = false
    private var nilCount = 0
    private var valid = true
    private var bigDriftSince: Date?
    private var dwell = DwellTracker()
    package var clock: () -> Date
    package var log: (String) -> Void = Log.info
    package var isLeftMousePressed: () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }

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

    // Explicit hotkey re-dock. Automatic hide-on-leave calls dock(to:) directly.
    package func redock(to newEdge: DockEdge) {
        if newEdge.slideAxis != edge.slideAxis,
           let delegate, let screen = dockScreen(in: delegate.geometry) {
            perp = delegate.geometry.dockPerpOffset(for: newEdge, frame: restoreFrame, screen: screen)
        }
        dock(to: newEdge)
    }

    package func dock(to newEdge: DockEdge? = nil) {
        let t0 = clock()
        guard valid, let frame = window.frame, let delegate else { return }
        transition?.cancel()
        let wasHidden = phase == .docked
        if let newEdge { edge = newEdge }
        let geometry = delegate.geometry
        if phase == .idle {
            guard let screen = geometry.screen(containing: frame) else { return }
            dockScreenID = screen.id
            perp = geometry.dockPerpOffset(for: edge, frame: frame, screen: screen)
            let visible = geometry.quartzVisibleFrame(of: screen)
            restoreOffset = CGPoint(x: frame.minX - visible.minX, y: frame.minY - visible.minY)
            restoreSize = frame.size
        } else if phase != .docked,
                  let recordedID = dockScreenID,
                  geometry.screen(withDisplayID: recordedID) != nil,
                  let currentScreen = geometry.screen(containing: frame),
                  currentScreen.id != recordedID {
            // An on-screen window may intentionally change screens, but an
            // offline recorded screen must not be replaced by its fallback.
            let oldRestoreFrame = restoreFrame
            dockScreenID = currentScreen.id
            let visible = geometry.quartzVisibleFrame(of: currentScreen)
            restoreOffset = CGPoint(x: oldRestoreFrame.minX - visible.minX,
                                    y: oldRestoreFrame.minY - visible.minY)
        }
        guard let screen = dockScreen(in: geometry) else { return }
        window.unminimize()
        dwell.reset()
        bigDriftSince = nil
        phase = .docking
        transition = Task { [weak self] in
            await self?.finishDock(frame: frame, screen: screen, wasHidden: wasHidden)
        }
        log("dock applied in \(Int(clock().timeIntervalSince(t0) * 1000))ms edge=\(edge)")
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
            log("hidden re-dock: strip from \(cached != nil ? "cache" : "placeholder") edge=\(edge)")
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
            log("capture FAILED edge=\(edge) — strip shows cache/placeholder")
        }
        if Task.isCancelled { return }
        guard let currentFrame = window.frame else {
            terminate(exit: .leave)
            return
        }
        let moved = max(max(abs(currentFrame.minX - frame.minX), abs(currentFrame.minY - frame.minY)),
                        max(abs(currentFrame.width - frame.width), abs(currentFrame.height - frame.height)))
        if isLeftMousePressed() || moved > 2 {
            log("dock capture interrupted by window movement/drag; leaving window in place edge=\(edge)")
            terminate(exit: .leave)
            return
        }
        // Capture may outlive a screen notification. Recompute against the
        // current layout rather than parking with pre-await geometry.
        guard let currentScreen = dockScreen(in: geometry) else { return }
        let currentHiddenPos = geometry.hiddenPosition(for: edge, size: currentFrame.size,
                                                       perp: perp, screen: currentScreen)
        let currentStripFrame = geometry.toAppKit(
            geometry.sliverRect(edge: edge, size: currentFrame.size, perp: perp,
                                screen: currentScreen, thickness: config.sliverPx)
        )
        moveTo(currentHiddenPos)
        phase = .docked
        guard let fakeStrip else { return }
        let fresh = fullImage.flatMap { capturer.slice(from: $0, edge: edge, windowSize: currentFrame.size, thickness: config.sliverPx) }
        fakeStrip.show(image: fresh ?? cached, frame: currentStripFrame, edge: edge)
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
        bigDriftSince = nil
        dwell.shownSince = clock()
        fakeStrip?.hide()
        window.raise()
        delegate.activate(window: window)
        moveTo(delegate.geometry.peekPosition(for: edge, size: frame.size, perp: perp, screen: screen))
        log("peek applied in \(Int(clock().timeIntervalSince(t0) * 1000))ms edge=\(edge)")
    }

    package enum ExitPosition {
        case restore
        case leave
    }

    package func terminate(exit: ExitPosition) {
        guard valid else { return }
        transition?.cancel()
        placeUndockedWindow(preferredFrame: exit == .restore ? restoreFrame : nil)
        detachStrip()
        valid = false
        log("terminate edge=\(edge) exit=\(exit)")
        delegate?.removeManaged(self)
    }

    package func beginGesture(at mouseQ: CGPoint) {
        guard let frame = window.frame, let delegate else { return }
        gestureStartFrame = frame
        let buffer = delegate.config.edgeBuffer
        switch edge {
        case .down: gestureStartedOnDockedEdge = abs(mouseQ.y - frame.maxY) <= buffer
        case .up: gestureStartedOnDockedEdge = abs(mouseQ.y - frame.minY) <= buffer
        case .left: gestureStartedOnDockedEdge = abs(mouseQ.x - frame.minX) <= buffer
        case .right: gestureStartedOnDockedEdge = abs(mouseQ.x - frame.maxX) <= buffer
        }
        gesture = true
    }

    package func endGesture() {
        gesture = false
        defer {
            gestureStartFrame = nil
            gestureStartedOnDockedEdge = false
        }
        guard let start = gestureStartFrame, let current = window.frame else {
            checkDragOut()
            return
        }
        let originDelta = max(abs(current.minX - start.minX), abs(current.minY - start.minY))
        let sizeChanged = current.size != start.size
        if sizeChanged && (gestureStartedOnDockedEdge || originDelta <= 2) {
            retainResizedFrame(current)
        } else if originDelta > 2 || sizeChanged {
            checkDragOut()
        }
        // A plain click is a no-op; do not issue a redundant AX position write.
    }

    private func retainResizedFrame(_ frame: CGRect) {
        guard phase == .peeked, let delegate,
              let screen = dockScreen(in: delegate.geometry) else { return }
        let geometry = delegate.geometry
        perp = geometry.dockPerpOffset(for: edge, frame: frame, screen: screen)
        restoreSize = frame.size
        let visible = geometry.quartzVisibleFrame(of: screen)
        switch edge.slideAxis {
        case .vertical: restoreOffset.x = frame.minX - visible.minX
        case .horizontal: restoreOffset.y = frame.minY - visible.minY
        }
        if let position = geometry.peekPosition(for: edge, size: frame.size, perp: perp, screen: screen),
           abs(frame.origin.x - position.x) > 1 || abs(frame.origin.y - position.y) > 1 {
            moveTo(position)
        }
    }

    package func checkDragOut() {
        guard phase == .peeked, let frame = window.frame, let delegate else { return }
        let geometry = delegate.geometry
        guard var screen = dockScreen(in: geometry),
              let droppedScreen = geometry.screen(containing: frame) else { return }
        let sourceDistance = geometry.distanceFromDockEdge(frame, edge: edge, screen: screen)
        if droppedScreen.id != screen.id {
            // "Along the source edge" identifies a cross-screen transfer. The
            // target's aligned edge may be dozens of pixels higher or lower.
            if sourceDistance > delegate.config.dockCancelPx {
                terminate(exit: .leave)
                return
            }
            dockScreenID = droppedScreen.id
            screen = droppedScreen
            let visible = geometry.quartzVisibleFrame(of: screen)
            restoreOffset = CGPoint(x: frame.minX - visible.minX, y: frame.minY - visible.minY)
            restoreSize = frame.size
        } else if sourceDistance > delegate.config.dockCancelPx {
            terminate(exit: .leave)
            return
        }

        perp = geometry.dockPerpOffset(for: edge, frame: frame, screen: screen)
        let visible = geometry.quartzVisibleFrame(of: screen)
        switch edge.slideAxis {
        case .vertical: restoreOffset.x = frame.minX - visible.minX
        case .horizontal: restoreOffset.y = frame.minY - visible.minY
        }
        // Retained drags snap on mouseUp, not on a later hide/peek cycle.
        moveTo(geometry.peekPosition(for: edge, size: frame.size, perp: perp, screen: screen))
    }

    package func restore() {
        guard valid else { return }
        transition?.cancel()
        placeUndockedWindow(preferredFrame: restoreFrame)
        detachStrip()
        valid = false
    }

    // The single safety net for every cancellation, release, quit and signal
    // path. A released window always ends fully inside the nearest visible
    // frame; oversized windows shrink rather than remaining partially off-screen.
    private func placeUndockedWindow(preferredFrame: CGRect?) {
        guard let delegate else { return }
        let geometry = delegate.geometry
        let candidate = preferredFrame ?? window.frame ?? restoreFrame
        guard let screen = geometry.nearestScreen(to: candidate) else { return }
        let fitted = geometry.fitting(candidate, in: screen)
        let current = window.frame
        if current?.size != fitted.size { window.resize(to: fitted.size) }
        if preferredFrame != nil || current?.origin != fitted.origin {
            window.position = fitted.origin
        }
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
                log("window frame unreadable, dropping edge=\(edge)")
                terminate(exit: .restore)
            }
            return
        }
        nilCount = 0
        let mousePressed = isLeftMousePressed()
        if gesture && !mousePressed {
            // The physical button state is authoritative if the global
            // mouseUp monitor was dropped.
            endGesture()
            guard valid else { return }
        }
        if !gesture, mousePressed, frontmost, phase == .peeked || phase == .docking {
            // Coordinate-independent fallback for offset display layouts or a
            // missed global mouseDown: never hide/re-anchor during native drag.
            beginGesture(at: mouseQ)
        }
        guard !gesture else { return }
        if window.isMinimized || window.isAppHidden {
            log("window tucked away by user, releasing edge=\(edge)")
            terminate(exit: .restore)
            return
        }

        let config = delegate.config
        let geometry = delegate.geometry
        let capturer = delegate.capturer
        guard let screen = dockScreen(in: geometry) else { return }

        switch phase {
        case .peeked:
            let inGrace = dwell.shownSince.map { now.timeIntervalSince($0) < 0.6 } ?? false
            if settling {
                bigDriftSince = nil
                if let pos = geometry.peekPosition(for: edge, size: frame.size, perp: perp, screen: screen),
                   abs(frame.origin.x - pos.x) > 1 || abs(frame.origin.y - pos.y) > 1 {
                    moveTo(pos)
                }
            } else if !inGrace,
                      geometry.distanceFromDockEdge(frame, edge: edge, screen: screen) > config.dockCancelPx {
                // Match docked-window drift handling: measure after all AX
                // reads, wait out late display notifications, and do not
                // overwrite perp with a transient macOS-arranged position.
                let observedAt = clock()
                if bigDriftSince == nil {
                    bigDriftSince = observedAt
                    log("peeked window displaced, grace before release edge=\(edge)")
                }
                if observedAt.timeIntervalSince(bigDriftSince ?? observedAt) >= 0.5 {
                    log("peeked window displaced externally, undocking edge=\(edge)")
                    terminate(exit: .leave)
                }
                return
            } else {
                bigDriftSince = nil
                perp = geometry.dockPerpOffset(for: edge, frame: frame, screen: screen)
            }
            let inWin = frame.insetBy(dx: -config.edgeBuffer, dy: -config.edgeBuffer).contains(mouseQ)
            dwell.noteHover(inWin, touchDwell: config.touchDwell, now: now)
            let sliver = geometry.sliverRect(edge: edge, size: frame.size, perp: perp, screen: screen,
                                             thickness: config.sliverPx)
            let onSliver = sliver.insetBy(dx: -6, dy: -6).contains(mouseQ)
            if !inGrace {
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
                let observedAt = clock()
                if bigDriftSince == nil {
                    bigDriftSince = observedAt
                    log("big drift \(Int(drift)) edge=\(edge), grace before release")
                }
                if observedAt.timeIntervalSince(bigDriftSince ?? observedAt) >= 0.5 {
                    log("docked window moved externally, releasing edge=\(edge)")
                    terminate(exit: .leave)
                }
                return
            }
            bigDriftSince = nil
            if drift > 2 {
                if settling && drift > config.dockCancelPx {
                    log("settling re-anchor edge=\(edge) drift=\(Int(drift))")
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
                    log("slam -> peek edge=\(edge)")
                    peek()
                } else if let since = dwell.sliverSince, now.timeIntervalSince(since) >= config.peekDwell {
                    log("hover -> peek \(Int(now.timeIntervalSince(since) * 1000))ms edge=\(edge)")
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
