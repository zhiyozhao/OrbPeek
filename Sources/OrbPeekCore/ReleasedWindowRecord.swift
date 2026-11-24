import Foundation

@MainActor
package final class ReleasedWindowRecord {
    package let managed: ManagedWindow
    package let fingerprints: [CGRect]
    private let pid: pid_t?
    private var interruptedPlacement: CGRect?
    package var manualRescuePending = false

    package init(_ managed: ManagedWindow) {
        self.managed = managed
        fingerprints = managed.hiddenFingerprints
        pid = managed.window.pid
    }
    package func needsRescue(in geometry: WindowGeometry) -> Bool {
        let window = managed.window
        guard !managed.isLeftMousePressed(), !window.isMinimized, !window.isAppHidden,
              let frame = window.frame else { return false }
        return (manualRescuePending || matchesParking(frame)) && geometry.visibleFraction(of: frame) < 0.1
    }
    private func matchesParking(_ frame: CGRect) -> Bool {
        fingerprints.contains { $0.approximatelyEquals(frame) } || interruptedPlacement?.approximatelyEquals(frame) == true
    }
    package func rescue(geometry: WindowGeometry) -> Bool {
        let window = managed.window
        guard managed.automaticWritesAllowed(), !managed.isLeftMousePressed(), !window.isMinimized, !window.isAppHidden,
              let observed = window.frame else { return false }
        // AX reads may observe a native move after check() selected this record.
        // Revalidate at each write; unrelated user positions must remain alone.
        guard manualRescuePending || (matchesParking(observed) && geometry.visibleFraction(of: observed) < 0.1),
              let screen = geometry.nearestScreen(to: observed) else { return false }
        let resized = CGRect(origin: observed.origin, size: geometry.fitting(observed, in: screen).size)
        let mayWrite = {
            guard self.managed.automaticWritesAllowed(), !self.managed.isLeftMousePressed(),
                  !window.isMinimized, !window.isAppHidden, let current = window.frame else { return false }
            return self.managed.automaticWritesAllowed() &&
                (current.approximatelyEquals(observed) || current.approximatelyEquals(resized))
        }
        guard mayWrite() else { return false }
        // Supply the observed frame so placement does not silently select a new
        // user frame as its target. The write guard still reads the current one.
        placeUndockedWindow(window: window, preferredFrame: observed, geometry: geometry, canWrite: mayWrite)
        guard let frame = window.frame, geometry.visibleFraction(of: frame) >= 0.99 else {
            if let current = window.frame, current.approximatelyEquals(resized) { interruptedPlacement = current }
            managed.showWaitingStrip(in: geometry.layout)
            return false
        }
        interruptedPlacement = nil
        managed.hideRecoveryStrip()
        manualRescuePending = false
        return true
    }
    package func check(geometry: WindowGeometry, capturer: any SliceCapturing) -> Bool {
        if let pid, let current = managed.window.pid, pid != current {
            managed.hideRecoveryStrip()
            return false
        }
        if let id = managed.windowID, !capturer.windowExists(id) {
            managed.hideRecoveryStrip()
            return false
        }
        if manualRescuePending || needsRescue(in: geometry) { _ = rescue(geometry: geometry) }
        if !needsRescue(in: geometry), !manualRescuePending { managed.hideRecoveryStrip() }
        return true
    }
}
