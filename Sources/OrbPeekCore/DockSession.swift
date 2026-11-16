import Foundation

// Product-policy switches are explicit: offline displays release to visible,
// and a recent normal upgrade may restore docks. Alternative policies remain
// isolated here rather than being scattered through the state machine.
package struct DockSessionOptions {
    package enum OfflinePolicy { case migrate, releaseToVisible }
    package var offlinePolicy: OfflinePolicy = .releaseToVisible
    package var redockAfterUpgrade = true
    package init() {}
}

// Testable multi-window session orchestration. The app controller currently
// owns the same responsibilities; incident scenarios exercise them here with
// no real windows or permissions.
@MainActor
package final class DockSession {
    package let options: DockSessionOptions
    package private(set) var windows: [ManagedWindow] = []
    package private(set) var screenLocked = false
    package var settling = DisplaySettling()
    private let delegate: any WindowDockDelegate
    private let clock: () -> Date
    package var log: (String) -> Void = Log.info

    package init(delegate: any WindowDockDelegate, options: DockSessionOptions = .init(), clock: @escaping () -> Date = Date.init) {
        self.delegate = delegate
        self.options = options
        self.clock = clock
    }

    @discardableResult
    package func add(window: any WindowHandle, edge: DockEdge) -> ManagedWindow {
        let managed = ManagedWindow(window: window, edge: edge, delegate: delegate, clock: clock)
        managed.offlinePolicyOverride = options.offlinePolicy
        managed.log = { [weak self, weak managed] message in
            guard let managed else { return }
            let app = managed.window.bundleIdentifier ?? "unknown"
            let wid = managed.windowID.map(String.init) ?? "pending"
            self?.log("[win=\(managed.id.uuidString.prefix(6)) app=\(app) wid=\(wid)] \(message)")
        }
        windows.append(managed)
        managed.dock()
        return managed
    }

    package func lock() {
        screenLocked = true
        log("session locked")
    }

    package func unlock() {
        screenLocked = false
        settling.screenUnlocked(at: clock())
        log("session unlocked; \(layoutDescription)")
    }

    package func wake() {
        settling.didWake(at: clock())
        log("session wake; \(layoutDescription)")
    }

    package func screenChanged() {
        settling.screenParametersChanged(at: clock())
        log("screen parameters changed; \(layoutDescription)")
    }

    package func reconfigurationBegan() {
        settling.displayReconfigurationBegan(at: clock())
        log("display reconfiguration began; \(layoutDescription)")
    }

    package func reconfigurationEnded() {
        settling.displayReconfigurationEnded(at: clock())
        log("display reconfiguration ended; \(layoutDescription)")
    }

    package func poll() {
        guard !screenLocked else { return }
        let now = clock()
        let isSettling = settling.isSettling(at: now)
        for window in windows {
            window.evaluate(mouseQ: .zero, mouseVelocity: .zero,
                            frontmost: delegate.isFrontmost(window.window),
                            blockedByPeeked: false, blockedBySmaller: false,
                            settling: isSettling, now: now)
        }
    }

    package func quit() {
        log("quit restore begin count=\(windows.count)")
        for window in windows { window.restore() }
        windows.removeAll()
        log("quit restore complete")
    }

    private var layoutDescription: String {
        delegate.geometry.layout.screens.map {
            "id=\($0.id) frame=\($0.frame) visible=\($0.visibleFrame)"
        }.joined(separator: " | ")
    }
}
