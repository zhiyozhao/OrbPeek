import AppKit
import Foundation

@MainActor
package protocol WindowDockDelegate: AnyObject {
    var config: DockConfiguration { get }
    var geometry: WindowGeometry { get }
    var capturer: any SliceCapturing { get }
    var offlinePolicy: DockSessionOptions.OfflinePolicy { get }
    func offlineWindowReleased(_ managed: ManagedWindow)
    func invalidateDisplayLayout()
    func makeStrip() -> any SnapshotStripHandling
    func nameForWindow(_ window: any WindowHandle) -> String
    func activate(window: any WindowHandle)
    func isFrontmost(_ window: any WindowHandle) -> Bool
    func dockStateDidChange()
    func removeManaged(_ managed: ManagedWindow)
}

package extension WindowDockDelegate {
    var offlinePolicy: DockSessionOptions.OfflinePolicy { .releaseToVisible }
    func offlineWindowReleased(_ managed: ManagedWindow) {}
    func invalidateDisplayLayout() {}
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
    private var dockScreenUUID: String?
    package var layoutOverride: ScreenLayout?
    private var geometry: WindowGeometry { WindowGeometry(layout: layoutOverride ?? delegate?.geometry.layout ?? ScreenLayout(screens: [ScreenInfo]())) }
    package var automaticWritesAllowed: () -> Bool = { true }
    package private(set) var hiddenFingerprints: [CGRect] = []
    private var layoutDecisionPending = false
    private var interruptedDock = false
    private var releaseRequested = false
    private var pendingExit: ExitPosition?
    // Parallel coordinate and restore origin are offsets from the recorded
    // screen's quartz visibleFrame, never absolute desktop coordinates.
    package var perp: CGFloat = 0
    private var restoreOffset: CGPoint = .zero
    private var restoreSize: CGSize = .zero
    package var restoreFrame: CGRect {
        guard let screen = dockScreen(in: geometry) else {
            return CGRect(origin: restoreOffset, size: restoreSize)
        }
        let visible = geometry.quartzVisibleFrame(of: screen)
        return CGRect(x: visible.minX + restoreOffset.x, y: visible.minY + restoreOffset.y,
                      width: restoreSize.width, height: restoreSize.height)
    }
    private var fakeStrip: (any SnapshotStripHandling)?
    private var lastStripLayout: ScreenLayout?
    private var lastStripRecoveryAt: Date?
    private var lastLogAt: [String: Date] = [:]
    package private(set) var windowID: CGWindowID?
    private var transition: Task<Void, Never>?
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
            cleanExit: cleanExit && !releaseRequested && automaticWritesAllowed() &&
                (window.frame.map { geometry.visibleFraction(of: $0) >= 0.99 } ?? false),
            exitedAt: exitedAt, dockScreenUUID: dockScreenUUID
        )
    }

    package func dockScreen(in geometry: WindowGeometry) -> ScreenInfo? {
        if let screen = ownedScreen(in: geometry) { return screen }
        return geometry.layout.primary
    }

    package func ownedScreen(in geometry: WindowGeometry) -> ScreenInfo? {
        geometry.layout.matchingScreen(id: dockScreenID, uuid: dockScreenUUID)
    }

    package func setRecoveredIntent(_ record: DockedWindowRecord) {
        guard let screen = geometry.layout.matchingScreen(id: record.dockScreenID, uuid: record.dockScreenUUID) else { return }
        dockScreenID = screen.id
        dockScreenUUID = screen.displayUUID
        let frame = record.restoreFrame.rect
        let visible = geometry.quartzVisibleFrame(of: screen)
        restoreOffset = CGPoint(x: frame.minX - visible.minX, y: frame.minY - visible.minY)
        restoreSize = frame.size
        perp = geometry.dockPerpOffset(for: edge, frame: frame, screen: screen)
    }

    package func pauseForLayoutDecision() {
        layoutDecisionPending = true
        if phase == .docking { interruptedDock = true }
        transition?.cancel()
        transition = nil
        stopActivationRetry()
    }

    // A visible strip remains the way to find a hidden window while we wait.
    // This touches only OrbPeek's panel, never the user's window.
    package func showWaitingStrip(in layout: ScreenLayout) {
        guard layout.isValid, let delegate, let screen = layout.primary else { return }
        let g = WindowGeometry(layout: layout)
        let requested = window.frame?.size ?? restoreSize
        let size = g.fitting(CGRect(origin: .zero, size: requested), in: screen).size
        if fakeStrip == nil { fakeStrip = delegate.makeStrip() }
        lastStripRecoveryAt = nil
        ensureStripVisible(geometry: g, config: delegate.config, capturer: delegate.capturer, screen: screen, size: size)
    }

    package func hasReachableStrip(in geometry: WindowGeometry) -> Bool {
        guard let strip = fakeStrip, strip.isVisible else { return false }
        return geometry.visibleFraction(of: geometry.toAppKit(strip.frame)) >= 0.99
    }

    // Called once per stable snapshot; retry when AX/drag or a failed write
    // prevented completing the decision. Never reinterpret a system move as user intent.
    @discardableResult
    package func reconcileLayout(_ layout: ScreenLayout, mayReleaseMissing: Bool) -> Bool {
        layoutOverride = layout
        guard valid, automaticWritesAllowed(), let delegate, layout.isValid else { return false }
        if phase == .idle {
            layoutDecisionPending = false
            dock()
            return true
        }
        guard !isLeftMousePressed(), !window.isMinimized, !window.isAppHidden, let frame = window.frame else {
            showWaitingStrip(in: layout)
            return false
        }
        gesture = false
        guard let screen = ownedScreen(in: geometry) else {
            showWaitingStrip(in: layout)
            guard mayReleaseMissing else { return false }
            return releaseForDisplayChange()
        }
        dockScreenID = screen.id
        if let pendingExit { return terminate(exit: pendingExit) }
        if releaseRequested {
            return releaseForDisplayChange()
        }
        if interruptedDock {
            interruptedDock = false
            layoutDecisionPending = false
            // Restart with current frame, without activation. The cancelled
            // capture's stale generation will never park this window.
            dock(targetScreenID: screen.id)
            return true
        }
        if fakeStrip == nil { fakeStrip = delegate.makeStrip() }
        let target = phase == .peeked
            ? geometry.peekPosition(for: edge, size: frame.size, perp: perp, screen: screen)
            : geometry.hiddenPosition(for: edge, size: frame.size, perp: perp, screen: screen)
        if let target, max(abs(frame.minX - target.x), abs(frame.minY - target.y)) > 2 { moveTo(target) }
        if phase == .docked {
            rememberHiddenFrame()
            ensureStripVisible(geometry: geometry, config: delegate.config, capturer: delegate.capturer, screen: screen, size: frame.size)
        } else {
            fakeStrip?.hide()
            dwell.reset()
            dwell.shownSince = clock()
            activationSucceeded = true
        }
        bigDriftSince = nil
        layoutDecisionPending = false
        let reachable = window.frame.map { geometry.visibleFraction(of: $0) >= 0.1 } ?? false
        if !reachable && !hasReachableStrip(in: geometry) { return releaseForDisplayChange() }
        return true
    }

    @discardableResult
    package func releaseForDisplayChange() -> Bool {
        guard valid, automaticWritesAllowed(), !isLeftMousePressed(), delegate != nil, geometry.layout.isValid,
              !window.isMinimized, !window.isAppHidden, window.frame != nil else { return false }
        releaseRequested = true
        return terminate(exit: .offline)
    }

    private func rememberHiddenFrame() {
        guard let frame = window.frame, !hiddenFingerprints.contains(where: { $0.approximatelyEquals(frame) }) else { return }
        hiddenFingerprints.append(frame)
    }

    package func hideRecoveryStrip() { detachStrip() }

    // MARK: Transitions

    // Explicit hotkey re-dock. Automatic hide-on-leave calls dock(to:) directly.
    package func redock(to newEdge: DockEdge) {
        guard automaticWritesAllowed() else { return }
        if newEdge.slideAxis != edge.slideAxis,
           let screen = dockScreen(in: geometry) {
            perp = geometry.dockPerpOffset(for: newEdge, frame: restoreFrame, screen: screen)
        }
        dock(to: newEdge)
    }

    package func dock(to newEdge: DockEdge? = nil, targetScreenID: CGDirectDisplayID? = nil) {
        let t0 = clock()
        guard valid, automaticWritesAllowed(), let frame = window.frame, let delegate else { return }
        transition?.cancel()
        let wasHidden = phase == .docked
        if let newEdge { edge = newEdge }
        let geometry = geometry
        if phase == .idle && restoreSize == .zero {
            guard let screen = geometry.screen(containing: frame) else { return }
            dockScreenID = screen.id
            dockScreenUUID = screen.displayUUID
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
            dockScreenUUID = currentScreen.displayUUID
            let visible = geometry.quartzVisibleFrame(of: currentScreen)
            restoreOffset = CGPoint(x: oldRestoreFrame.minX - visible.minX,
                                    y: oldRestoreFrame.minY - visible.minY)
        }
        guard let screen = ownedScreen(in: geometry) ?? ((offlinePolicyOverride ?? delegate.offlinePolicy) == .migrate ? geometry.layout.primary : nil) else { return }
        guard automaticWritesAllowed() else { return }
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
        if Task.isCancelled || !automaticWritesAllowed() { return }
        guard let delegate else { return }
        let geometry = geometry
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
            rememberHiddenFrame()
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
        if Task.isCancelled || !automaticWritesAllowed() { return }
        guard let currentFrame = window.frame else {
            terminate(exit: .leave)
            return
        }
        guard !Task.isCancelled, automaticWritesAllowed() else { return }
        let moved = max(max(abs(currentFrame.minX - frame.minX), abs(currentFrame.minY - frame.minY)),
                        max(abs(currentFrame.width - frame.width), abs(currentFrame.height - frame.height)))
        if isLeftMousePressed() || moved > 2 {
            log("dock capture interrupted by window movement/drag; leaving window in place edge=\(edge)")
            terminate(exit: .leave)
            return
        }
        // Capture may outlive a screen notification. Recompute against the
        // current layout rather than parking with pre-await geometry.
        let currentGeometry = self.geometry
        guard let currentScreen = ownedScreen(in: currentGeometry) ?? ((offlinePolicyOverride ?? delegate.offlinePolicy) == .migrate ? currentGeometry.layout.primary : nil) else {
            interruptedDock = true
            layoutDecisionPending = true
            return
        }
        let currentHiddenPos = currentGeometry.hiddenPosition(for: edge, size: currentFrame.size,
                                                       perp: perp, screen: currentScreen)
        let currentStripFrame = currentGeometry.toAppKit(
            currentGeometry.sliverRect(edge: edge, size: currentFrame.size, perp: perp,
                                screen: currentScreen, thickness: config.sliverPx)
        )
        moveTo(currentHiddenPos)
        phase = .docked
        rememberHiddenFrame()
        delegate.dockStateDidChange()
        guard let fakeStrip else { return }
        let fresh = fullImage.flatMap { capturer.slice(from: $0, edge: edge, windowSize: currentFrame.size, thickness: config.sliverPx) }
        fakeStrip.show(image: fresh ?? cached, frame: currentStripFrame, edge: edge)
        log("strip show frame=\(currentStripFrame) visible=\(fakeStrip.isVisible)")
    }

    package func peek() {
        guard automaticWritesAllowed(), !layoutDecisionPending else { return }
        let t0 = clock()
        guard valid, let frame = window.frame, let delegate else { return }
        guard let screen = dockScreen(in: geometry) else { return }
        guard automaticWritesAllowed(), ownedScreen(in: geometry) != nil || (offlinePolicyOverride ?? delegate.offlinePolicy) == .migrate else { return }
        transition?.cancel()
        transition = nil
        window.unminimize()
        phase = .peeked
        dwell.reset()
        bigDriftSince = nil
        dwell.shownSince = clock()
        lastActivationRetry = nil
        activationSucceeded = delegate.isFrontmost(window)
        fakeStrip?.hide()
        if automaticWritesAllowed() { window.raise() }
        if automaticWritesAllowed() { delegate.activate(window: window) }
        moveTo(geometry.peekPosition(for: edge, size: frame.size, perp: perp, screen: screen))
        log("peek applied in \(Int(clock().timeIntervalSince(t0) * 1000))ms edge=\(edge)")
        delegate.dockStateDidChange()
    }

    package enum ExitPosition {
        case restore
        case leave
        case offline
    }

    @discardableResult
    package func terminate(exit: ExitPosition) -> Bool {
        guard valid, automaticWritesAllowed(), let delegate else { return false }
        transition?.cancel()
        pendingExit = exit
        OrbPeekCore.placeUndockedWindow(window: window,
                                        preferredFrame: exit == .restore || exit == .offline ? restoreFrame : nil,
                                        fallbackFrame: restoreFrame, centered: exit == .offline,
                                        geometry: geometry, canWrite: automaticWritesAllowed)
        let placed = window.frame
        let closed = windowID.map { !delegate.capturer.windowExists($0) } ?? false
        guard automaticWritesAllowed() else { return false }
        guard closed || placed.map({ geometry.visibleFraction(of: $0) >= 0.99 }) == true else {
            showWaitingStrip(in: geometry.layout)
            return false
        }
        if exit == .offline { delegate.offlineWindowReleased(self) }
        detachStrip()
        valid = false
        log("terminate edge=\(edge) exit=\(exit) after=\(window.frame as Any)")
        delegate.removeManaged(self)
        return true
    }

    package func stopActivationRetry() {
        activationSucceeded = true
        lastActivationRetry = nil
    }

    package func beginGesture(at mouseQ: CGPoint) {
        guard automaticWritesAllowed(), !layoutDecisionPending else { return }
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
        guard automaticWritesAllowed(), !layoutDecisionPending else { return }
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
              let screen = dockScreen(in: geometry) else { return }
        let geometry = geometry
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
        guard automaticWritesAllowed(), !layoutDecisionPending else { return }
        guard phase == .peeked, let frame = window.frame, let delegate else { return }
        let geometry = geometry
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
            dockScreenUUID = droppedScreen.displayUUID
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
        guard valid, automaticWritesAllowed() else { return }
        transition?.cancel()
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
        guard delegate != nil else { return }
        OrbPeekCore.placeUndockedWindow(window: window, preferredFrame: preferredFrame, fallbackFrame: restoreFrame,
                            geometry: geometry, canWrite: automaticWritesAllowed)
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
        guard automaticWritesAllowed(), let pos else { return }
        logLimited("AX move to=\(pos)")
        window.position = pos
    }

    // MARK: Poll evaluation

    package func evaluate(mouseQ: CGPoint, mouseVelocity: CGPoint, frontmost: Bool,
                          blockedByPeeked: Bool, blockedBySmaller: Bool, settling: Bool, now: Date) {
        guard valid, automaticWritesAllowed(), !layoutDecisionPending, let delegate else { return }
        if let pendingExit { terminate(exit: pendingExit); return }
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
        guard automaticWritesAllowed(), !layoutDecisionPending else { return }
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
        let geometry = geometry
        let capturer = delegate.capturer
        guard let screen = dockScreen(in: geometry) else { return }
        if settling && !settlingActive {
            log("settling begin frame=\(frame) screen=\(screen.id)")
        }
        settlingActive = settling
        if !settling, (offlinePolicyOverride ?? delegate.offlinePolicy) == .releaseToVisible,
           ownedScreen(in: geometry) == nil {
            _ = releaseForDisplayChange()
            return
        }
        if ownedScreen(in: geometry) == nil && (offlinePolicyOverride ?? delegate.offlinePolicy) == .releaseToVisible { return }

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
                    if automaticWritesAllowed() { delegate.activate(window: window) }
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
