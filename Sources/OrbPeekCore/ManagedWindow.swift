import AppKit
import Foundation

@MainActor
package protocol WindowDockDelegate: AnyObject {
    var config: DockConfiguration { get }
    var geometry: WindowGeometry { get }
    var capturer: any SliceCapturing { get }
    var offlinePolicy: DockSessionOptions.OfflinePolicy { get }
    var slideAnimator: (any SlideAnimating)? { get }
    func offlineWindowReleased(_ managed: ManagedWindow)
    func makeStrip() -> any SnapshotStripHandling
    func nameForWindow(_ window: any WindowHandle) -> String
    func activate(window: any WindowHandle)
    func isFrontmost(_ window: any WindowHandle) -> Bool
    func dockStateDidChange()
    func removeManaged(_ managed: ManagedWindow)
}

package extension WindowDockDelegate {
    var offlinePolicy: DockSessionOptions.OfflinePolicy { .releaseToVisible }
    var slideAnimator: (any SlideAnimating)? { nil }
    func offlineWindowReleased(_ managed: ManagedWindow) {}
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
    package struct PendingRedock {
        package let screenID: CGDirectDisplayID
        package let placedScreenID: CGDirectDisplayID
        package let releasedAt: Date
        package let placedFrame: CGRect
        package let placedOffset: CGPoint
    }
    package private(set) var pendingRedock: PendingRedock?
    private var fakeStrip: (any SnapshotStripHandling)?
    private var lastStripLayout: ScreenLayout?
    private var lastStripRecoveryAt: Date?
    private var lastLogAt: [String: Date] = [:]
    package private(set) var windowID: CGWindowID?
    private var transition: Task<Void, Never>?
    private var animationGeneration = 0
    package private(set) var phase: Phase = .idle
    package var gesture = false
    package var offlinePolicyOverride: DockSessionOptions.OfflinePolicy?
    private var gestureStartFrame: CGRect?
    private var gestureStartedOnDockedEdge = false
    private var nilCount = 0
    private var valid = true
    private var bigDriftSince: Date?
    private var settlingActive = false
    private var lastActivationRetry: Date?
    private var activationSucceeded = false
    private var dwell = DwellTracker()
    package var clock: () -> Date
    package var log: (String) -> Void = { _ in }
    package var isLeftMousePressed: () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }

    package init(window: any WindowHandle, edge: DockEdge, delegate: any WindowDockDelegate,
                 clock: @escaping () -> Date = Date.init) {
        self.window = window
        self.edge = edge
        self.delegate = delegate
        self.clock = clock
    }

    package var appName: String { delegate?.nameForWindow(window) ?? "Window" }

    package func persistenceRecord(cleanExit: Bool = false, exitedAt: Date? = nil) -> DockedWindowRecord? {
        guard (valid || cleanExit), phase != .idle, let pid = window.pid else { return nil }
        return DockedWindowRecord(
            processID: pid, bundleIdentifier: window.bundleIdentifier, title: window.title,
            windowID: windowID, restoreFrame: restoreFrame,
            parkedFrame: window.frame ?? restoreFrame, dockScreenID: dockScreenID, edge: edge,
            cleanExit: cleanExit, exitedAt: exitedAt
        )
    }

    package func dockScreen(in geometry: WindowGeometry) -> ScreenInfo? {
        if let id = dockScreenID, let screen = geometry.screen(withDisplayID: id) { return screen }
        return geometry.layout.primary
    }

    private func cancelTransition() {
        animationGeneration += 1
        transition?.cancel()
        delegate?.slideAnimator?.cancel()
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

    package func dock(to newEdge: DockEdge? = nil, targetScreenID: CGDirectDisplayID? = nil) {
        let t0 = clock()
        guard valid, let frame = window.frame, let delegate else { return }
        cancelTransition()
        let wasHidden = phase == .docked
        if let newEdge { edge = newEdge }
        let geometry = delegate.geometry
        if phase == .idle && restoreSize == .zero {
            guard let screen = geometry.screen(containing: frame) else { return }
            dockScreenID = screen.id
            perp = geometry.dockPerpOffset(for: edge, frame: frame, screen: screen)
            let visible = geometry.quartzVisibleFrame(of: screen)
            restoreOffset = CGPoint(x: frame.minX - visible.minX, y: frame.minY - visible.minY)
            restoreSize = frame.size
        } else if let targetScreenID {
            dockScreenID = targetScreenID
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
        delegate.dockStateDidChange()
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
            delegate.dockStateDidChange()
            return
        }

        let sliceOnScreen = geometry.quartzFrame(of: screen)
            .contains(geometry.sliceScreenRect(edge: edge, frame: frame, thickness: config.sliverPx))
        let canCapture = sliceOnScreen && delegate.isFrontmost(window)
        let fullImage = canCapture
            ? await capturer.captureWindow(frame: frame, displayID: dockScreenID, windowID: windowID)
            : nil
        if !canCapture {
            log("capture skipped sliceOnScreen=\(sliceOnScreen) frontmost=\(delegate.isFrontmost(window))")
        }
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
        let generation = animationGeneration
        moveTo(currentHiddenPos)
        phase = .docked
        delegate.dockStateDidChange()
        guard let fakeStrip else { return }
        let fresh = fullImage.flatMap { capturer.slice(from: $0, edge: edge, windowSize: currentFrame.size, thickness: config.sliverPx) }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if let fullImage, let animator = delegate.slideAnimator, !reduceMotion {
            let plan = SlideAnimationPlan.dock(windowFrame: geometry.toAppKit(currentFrame),
                                               stripFrame: currentStripFrame, edge: edge)
            let started = animator.play(image: NSImage(cgImage: fullImage, size: currentFrame.size), plan: plan) { [weak self] _ in
                guard let self, generation == self.animationGeneration else { return }
                fakeStrip.show(image: fresh ?? cached, frame: currentStripFrame, edge: edge)
                self.log("strip show frame=\(currentStripFrame) visible=\(fakeStrip.isVisible)")
            }
            if !started { fakeStrip.show(image: fresh ?? cached, frame: currentStripFrame, edge: edge) }
        } else {
            fakeStrip.show(image: fresh ?? cached, frame: currentStripFrame, edge: edge)
            log("strip show frame=\(currentStripFrame) visible=\(fakeStrip.isVisible)")
        }
    }

    package func peek() {
        let t0 = clock()
        guard valid, let frame = window.frame, let delegate else { return }
        guard let screen = dockScreen(in: delegate.geometry) else { return }
        cancelTransition()
        transition = nil
        window.unminimize()
        phase = .peeked
        dwell.reset()
        bigDriftSince = nil
        dwell.shownSince = clock()
        lastActivationRetry = nil
        activationSucceeded = delegate.isFrontmost(window)
        fakeStrip?.hide()
        window.raise()
        delegate.activate(window: window)
        let targetPosition = delegate.geometry.peekPosition(for: edge, size: frame.size, perp: perp, screen: screen)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if let targetPosition,
           let image = windowID.flatMap({ delegate.capturer.cachedImage(for: $0) }),
           let animator = delegate.slideAnimator, !reduceMotion {
            let stripFrame = delegate.geometry.toAppKit(
                delegate.geometry.sliverRect(edge: edge, size: frame.size, perp: perp,
                                             screen: screen, thickness: delegate.config.sliverPx)
            )
            let targetFrame = delegate.geometry.toAppKit(CGRect(origin: targetPosition, size: frame.size))
            let plan = SlideAnimationPlan.peek(stripFrame: stripFrame, windowFrame: targetFrame, edge: edge)
            let generation = animationGeneration
            let started = animator.play(image: image, plan: plan) { [weak self] _ in
                guard let self, generation == self.animationGeneration else { return }
                self.moveTo(targetPosition)
            }
            if !started { moveTo(targetPosition) }
        } else {
            moveTo(targetPosition)
        }
        log("peek applied in \(Int(clock().timeIntervalSince(t0) * 1000))ms edge=\(edge)")
        delegate.dockStateDidChange()
    }

    package enum ExitPosition {
        case restore
        case leave
        case offline
    }

    package func terminate(exit: ExitPosition) {
        guard valid, let delegate else { return }
        cancelTransition()
        OrbPeekCore.placeUndockedWindow(window: window,
                                        preferredFrame: exit == .restore || exit == .offline ? restoreFrame : nil,
                                        fallbackFrame: restoreFrame, centered: exit == .offline,
                                        geometry: delegate.geometry)
        if exit == .offline {
            let placedFrame = window.frame ?? restoreFrame
            let placedScreen = dockScreen(in: delegate.geometry)
            let visible = placedScreen.map { delegate.geometry.quartzVisibleFrame(of: $0) } ?? .zero
            pendingRedock = PendingRedock(screenID: dockScreenID ?? 0,
                                          placedScreenID: placedScreen?.id ?? 0,
                                          releasedAt: clock(), placedFrame: placedFrame,
                                          placedOffset: CGPoint(x: placedFrame.minX - visible.minX,
                                                                y: placedFrame.minY - visible.minY))
            window.raise()
            delegate.offlineWindowReleased(self)
        }
        detachStrip()
        valid = false
        log("terminate edge=\(edge) exit=\(exit) after=\(window.frame as Any)")
        delegate.removeManaged(self)
    }

    package func stopActivationRetry() {
        activationSucceeded = true
        lastActivationRetry = nil
    }

    // A late display must be the same physical display ID. The window remains
    // eligible for two minutes, even though it was released to the visible area.
    package func redockIfDisplayReturns() -> Bool {
        guard let pending = pendingRedock else { return false }
        guard clock().timeIntervalSince(pending.releasedAt) <= 120,
              let delegate, let screen = delegate.geometry.screen(withDisplayID: pending.screenID) else {
            return false
        }
        if isLeftMousePressed() {
            log("defer late re-dock: mouse button is pressed")
            return false
        }
        if let frame = window.frame {
            let expected = pending.placedFrame
            var positionMatches = true
            if let placedScreen = delegate.geometry.screen(withDisplayID: pending.placedScreenID) {
                let visible = delegate.geometry.quartzVisibleFrame(of: placedScreen)
                let currentOffset = CGPoint(x: frame.minX - visible.minX, y: frame.minY - visible.minY)
                positionMatches = abs(currentOffset.x - pending.placedOffset.x) <= 2 &&
                    abs(currentOffset.y - pending.placedOffset.y) <= 2
            }
            let sizeMatches = abs(frame.width - expected.width) <= 2 && abs(frame.height - expected.height) <= 2
            if !positionMatches || !sizeMatches {
                log("skip late re-dock: user moved/resized window after release")
                pendingRedock = nil
                return false
            }
        }
        pendingRedock = nil
        valid = true
        phase = .idle
        log("display \(screen.id) returned; re-docking edge=\(edge)")
        dock(to: edge, targetScreenID: pending.screenID)
        return true
    }

    package var pendingRedockExpired: Bool {
        guard let pending = pendingRedock else { return false }
        return clock().timeIntervalSince(pending.releasedAt) > 120
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
        delegate.dockStateDidChange()
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
        delegate.dockStateDidChange()
    }

    package func restore() {
        guard valid else { return }
        cancelTransition()
        let before = window.frame
        placeUndockedWindow(preferredFrame: restoreFrame)
        detachStrip()
        valid = false
        log("restore complete before=\(before as Any) after=\(window.frame as Any)")
    }

    // The single safety net for every cancellation, release, quit and signal
    // path. A released window always ends fully inside the nearest visible
    // frame; oversized windows shrink rather than remaining partially off-screen.
    private func placeUndockedWindow(preferredFrame: CGRect?) {
        guard let delegate else { return }
        OrbPeekCore.placeUndockedWindow(window: window, preferredFrame: preferredFrame, fallbackFrame: restoreFrame,
                            geometry: delegate.geometry)
    }

    package func detachStrip() {
        if let fakeStrip { log("strip hide frame=\(fakeStrip.frame) visible=\(fakeStrip.isVisible)") }
        fakeStrip?.hide()
        fakeStrip = nil
    }

    package func setStripFloating(_ floating: Bool) {
        guard let fakeStrip else { return }
        let target: NSWindow.Level = floating ? .floating : .normal
        if fakeStrip.level != target { fakeStrip.level = target }
    }

    private func ensureStripVisible(geometry: WindowGeometry, config: DockConfiguration,
                                    capturer: any SliceCapturing, screen: ScreenInfo, size: CGSize) {
        guard let fakeStrip else { return }
        let quartz = geometry.sliverRect(edge: edge, size: size, perp: perp, screen: screen,
                                         thickness: config.sliverPx)
        let expected = geometry.toAppKit(quartz)
        let intersection = geometry.quartzVisibleFrame(of: screen).intersection(quartz)
        let onScreen = !intersection.isNull && !intersection.isEmpty
        let layoutChanged = lastStripLayout != geometry.layout
        let recoveryAllowed = lastStripRecoveryAt.map { clock().timeIntervalSince($0) >= 1 } ?? true
        if (layoutChanged || !onScreen || !fakeStrip.isVisible || fakeStrip.thickness != config.sliverPx), recoveryAllowed {
            logLimited("strip re-show frame=\(expected) onScreen=\(onScreen) wasVisible=\(fakeStrip.isVisible)")
            let image = windowID.flatMap {
                capturer.cachedSlice(for: $0, edge: edge, size: size, thickness: config.sliverPx)
            }
            fakeStrip.show(image: image, frame: expected, edge: edge)
            lastStripRecoveryAt = clock()
        } else if fakeStrip.frame != expected {
            fakeStrip.updateFrame(expected, edge: edge)
        }
        let opacity = CGFloat(config.stripOpacity)
        if fakeStrip.alphaValue != opacity { fakeStrip.alphaValue = opacity }
        lastStripLayout = geometry.layout
        if !onScreen || !fakeStrip.isVisible {
            logLimited("strip VISIBILITY FAILURE frame=\(expected) visible=\(fakeStrip.isVisible)")
        }
    }

    private func logLimited(_ message: String) {
        let now = clock()
        if let last = lastLogAt[message], now.timeIntervalSince(last) < 1 { return }
        lastLogAt[message] = now
        log(message)
    }

    private func moveTo(_ pos: CGPoint?) {
        guard let pos else { return }
        logLimited("AX move to=\(pos)")
        window.position = pos
    }

    // MARK: Poll evaluation

    package func evaluate(mouseQ: CGPoint, mouseVelocity: CGPoint, frontmost: Bool,
                          blockedByPeeked: Bool, blockedBySmaller: Bool, settling: Bool, now: Date) {
        guard valid, let delegate else { return }
        guard let frame = window.frame else {
            if nilCount == 0 { log("window frame unreadable start edge=\(edge)") }
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
        if nilCount > 0 { log("window frame readable again edge=\(edge)") }
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
        if settling && !settlingActive {
            log("settling begin frame=\(frame) screen=\(screen.id)")
        }
        settlingActive = settling
        if !settling, (offlinePolicyOverride ?? delegate.offlinePolicy) == .releaseToVisible,
           let id = dockScreenID, geometry.screen(withDisplayID: id) == nil {
            log("dock screen \(id) offline after settling; release centered and raise")
            terminate(exit: .offline)
            return
        }

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
            if frontmost { activationSucceeded = true }
            var retryingActivation = false
            if !activationSucceeded, !frontmost, let shown = dwell.shownSince, now.timeIntervalSince(shown) < 2 {
                retryingActivation = true
                if lastActivationRetry == nil || now.timeIntervalSince(lastActivationRetry!) >= 0.3 {
                    log("retry activating peeked window")
                    delegate.activate(window: window)
                    lastActivationRetry = now
                }
            }
            let inWin = frame.insetBy(dx: -config.edgeBuffer, dy: -config.edgeBuffer).contains(mouseQ)
            dwell.noteHover(inWin, touchDwell: config.touchDwell, now: now)
            let sliver = geometry.sliverRect(edge: edge, size: frame.size, perp: perp, screen: screen,
                                             thickness: config.sliverPx)
            let onSliver = sliver.insetBy(dx: -6, dy: -6).contains(mouseQ)
            if !inGrace {
                let lostFocus = !frontmost && !retryingActivation
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
            ensureStripVisible(geometry: geometry, config: config, capturer: capturer,
                               screen: screen, size: frame.size)
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
