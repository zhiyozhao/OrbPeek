import Foundation

package struct DockSessionOptions {
    package enum OfflinePolicy { case migrate, releaseToVisible }
    package var offlinePolicy: OfflinePolicy = .releaseToVisible
    package var redockAfterUpgrade = true
    package init() {}
}

@MainActor
package final class DockSession {
    package let options: DockSessionOptions
    package private(set) var windows: [ManagedWindow] = []
    package private(set) var released: [ReleasedWindowRecord] = []
    package private(set) var screenLocked = false
    package private(set) var sleeping = false
    package private(set) var sessionActive = true
    package private(set) var screenSaverActive = false
    package private(set) var stableLayout: ScreenLayout?
    package private(set) var suspensionBaseline: ScreenLayout?
    package var settling = DisplaySettling()
    private var observedLayout: ScreenLayout?
    private var decisions = Set<UUID>()
    private var lastSafetyCheck = Date.distantPast
    private var rescueRequested = false
    private let delegate: any WindowDockDelegate
    private let clock: () -> Date
    package var log: (String) -> Void = { _ in }

    package init(delegate: any WindowDockDelegate, options: DockSessionOptions = .init(), clock: @escaping () -> Date = Date.init) {
        self.delegate = delegate
        self.options = options
        self.clock = clock
        let initial = delegate.geometry.layout
        if initial.isValid { stableLayout = initial; observedLayout = initial }
    }

    package var isSuspended: Bool { screenLocked || sleeping || !sessionActive || screenSaverActive }
    package var canWriteAutomatically: Bool {
        !isSuspended && delegate.geometry.layout.isValid && delegate.geometry.layout == observedLayout && !settling.isSettling(at: clock())
    }
    package var recoveryReady: Bool { canWriteAutomatically && decisions.isEmpty }

    @discardableResult
    package func add(window: any WindowHandle, edge: DockEdge,
                     configure: ((ManagedWindow) -> Void)? = nil) -> ManagedWindow {
        let managed = ManagedWindow(window: window, edge: edge, delegate: delegate, clock: clock)
        managed.offlinePolicyOverride = options.offlinePolicy
        managed.automaticWritesAllowed = { [weak self] in self?.canWriteAutomatically ?? false }
        managed.layoutOverride = stableLayout
        managed.log = { [weak self, weak managed] message in
            guard let managed else { return }
            self?.log("[win=\(managed.id.uuidString.prefix(6)) app=\(managed.window.bundleIdentifier ?? "unknown") wid=\(managed.windowID.map(String.init) ?? "pending")] \(message)")
        }
        cancelPending(for: window)
        configure?(managed)
        windows.append(managed)
        if canWriteAutomatically { managed.dock() }
        else { decisions.insert(managed.id); managed.pauseForLayoutDecision() }
        return managed
    }

    package func adopt(_ managed: ManagedWindow) {
        cancelPending(for: managed.window)
        if !windows.contains(where: { $0 === managed || $0.window.isSameWindow(as: managed.window) }) { windows.append(managed) }
    }
    package func remove(_ managed: ManagedWindow) {
        windows.removeAll { $0 === managed }
        decisions.remove(managed.id)
    }
    package func deferPending(_ managed: ManagedWindow) {
        if !released.contains(where: { $0.managed.window.isSameWindow(as: managed.window) }) {
            released.append(ReleasedWindowRecord(managed))
        }
        remove(managed)
    }
    package func cancelPending(for window: any WindowHandle) {
        for record in released where record.managed.window.isSameWindow(as: window) { record.managed.hideRecoveryStrip() }
        released.removeAll { $0.managed.window.isSameWindow(as: window) }
    }
    package func clearPending() {
        for record in released { record.managed.hideRecoveryStrip() }
        released.removeAll()
    }

    private func pause() {
        if suspensionBaseline == nil { suspensionBaseline = stableLayout }
        for window in windows { decisions.insert(window.id); window.pauseForLayoutDecision() }
    }
    package func lock() { pause(); screenLocked = true }
    package func unlock() { screenLocked = false; settling.screenUnlocked(at: clock()); pause() }
    package func sleep() { pause(); sleeping = true }
    package func wake() { sleeping = false; settling.didWake(at: clock()); pause() }
    package func setSessionActive(_ active: Bool) {
        pause(); sessionActive = active
        if active { settling.screenUnlocked(at: clock()) }
    }
    package func setScreenSaverActive(_ active: Bool) {
        pause(); screenSaverActive = active
        if !active { settling.screenUnlocked(at: clock()) }
    }
    package func screenChanged() { observedLayout = delegate.geometry.layout; pause(); settling.screenParametersChanged(at: clock()) }
    package func reconfigurationBegan() { pause(); settling.displayReconfigurationBegan(at: clock()) }
    package func reconfigurationEnded() { pause(); settling.displayReconfigurationEnded(at: clock()) }

    package func poll(mouseQ: CGPoint = .zero, mouseVelocity: CGPoint = .zero,
                      blockedBySmaller: ((ManagedWindow) -> Bool)? = nil) {
        let snapshot = delegate.geometry.layout
        if observedLayout != snapshot {
            observedLayout = snapshot
            screenChanged()
        }
        guard !isSuspended else { return }
        guard snapshot.isValid else { return }
        let geometry = WindowGeometry(layout: snapshot)
        for window in windows { window.layoutOverride = snapshot }
        if settling.isSettling(at: clock()) {
            for window in windows { window.showWaitingStrip(in: snapshot) }
            return
        }
        let now = clock()
        let pendingDecisions = decisions
        for window in windows where pendingDecisions.contains(window.id) {
            if window.reconcileLayout(snapshot, mayReleaseMissing: settling.mayConfirmMissingDisplay(at: now)) {
                decisions.remove(window.id)
            }
        }
        if decisions.isEmpty { stableLayout = snapshot; suspensionBaseline = nil }
        if rescueRequested { performRescueAll(geometry: geometry) }
        let current = windows
        for window in current where !pendingDecisions.contains(window.id) && !decisions.contains(window.id) {
            window.evaluate(mouseQ: mouseQ, mouseVelocity: mouseVelocity,
                            frontmost: delegate.isFrontmost(window.window),
                            blockedByPeeked: windows.contains { $0 !== window && $0.phase.isPeeked },
                            blockedBySmaller: blockedBySmaller?(window) ?? false, settling: false, now: now)
        }
        for window in windows {
            guard let frame = window.window.frame, geometry.visibleFraction(of: frame) < 0.1,
                  !window.hasReachableStrip(in: geometry) else { continue }
            window.showWaitingStrip(in: snapshot)
            if !window.hasReachableStrip(in: geometry), !window.releaseForDisplayChange() {
                decisions.insert(window.id) // A failed AX write cannot silently drop ownership.
            }
        }
        if now.timeIntervalSince(lastSafetyCheck) >= 1 || !pendingDecisions.isEmpty {
            lastSafetyCheck = now
            released.removeAll { !$0.check(geometry: geometry, capturer: delegate.capturer) }
        }
    }

    package func rescueAllWindows() {
        rescueRequested = true
        guard canWriteAutomatically else { return }
        performRescueAll(geometry: WindowGeometry(layout: delegate.geometry.layout))
    }
    private func performRescueAll(geometry: WindowGeometry) {
        var deferred = false
        for window in windows {
            window.layoutOverride = geometry.layout
            if !window.releaseForDisplayChange() { deferred = true }
        }
        for record in released {
            record.manualRescuePending = true
            if !record.rescue(geometry: geometry) { deferred = true }
        }
        rescueRequested = deferred
    }

    // Suspended/invalid desktops and explicit user-hidden/dragging windows
    // are deferred, never "fixed" by unsolicited writes.
    package func unreachableWindows() -> [ManagedWindow] {
        guard !isSuspended, delegate.geometry.layout.isValid else { return [] }
        let g = WindowGeometry(layout: delegate.geometry.layout)
        return windows.filter { managed in
            guard !managed.isLeftMousePressed(), !managed.window.isMinimized, !managed.window.isAppHidden,
                  let frame = managed.window.frame else { return false }
            return g.visibleFraction(of: frame) < 0.1 && !managed.hasReachableStrip(in: g)
        } + released.filter { $0.needsRescue(in: g) && !$0.managed.hasReachableStrip(in: g) }.map(\.managed)
    }

    @discardableResult
    package func quit() -> [ManagedWindow] {
        var exited = windows
        for window in windows { window.restore() }
        // Do not discard an already restored parking position on quit. Failed
        // rescues join the crash journal, never the clean-exit redock exception.
        let geometry = WindowGeometry(layout: delegate.geometry.layout)
        for record in released where record.manualRescuePending || record.needsRescue(in: geometry) || record.managed.window.frame == nil {
            if !canWriteAutomatically || !record.rescue(geometry: geometry) { exited.append(record.managed) }
        }
        windows.removeAll()
        decisions.removeAll()
        clearPending()
        return exited
    }
}
