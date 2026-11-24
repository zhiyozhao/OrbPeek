import Foundation

// Time-based suppression of external-drift release while macOS settles window
// frames after display and session transitions.
package struct DisplaySettling {
    private var until = Date.distantPast
    private var reconfiguring = false
    private var reconfigurationBeganAt: Date?
    private var lastEventAt = Date.distantPast

    package init() {}

    package mutating func screenParametersChanged(at now: Date) {
        lastEventAt = now
        until = now.addingTimeInterval(3)
    }

    package mutating func displayReconfigurationBegan(at now: Date) {
        lastEventAt = now
        // This callback precedes the frame shuffle, unlike the AppKit
        // notification, which can arrive hundreds of milliseconds later.
        reconfiguring = true
        reconfigurationBeganAt = now
    }

    package mutating func displayReconfigurationEnded(at now: Date) {
        reconfiguring = false
        reconfigurationBeganAt = nil
        screenParametersChanged(at: now)
    }

    package mutating func screenUnlocked(at now: Date) {
        // A display change may have happened while polling was frozen. Start
        // settling now; the old notification's three seconds may be long past.
        until = now.addingTimeInterval(3)
        lastEventAt = now
    }

    package mutating func didWake(at now: Date) {
        // Deep sleep can swallow the unlock notification.
        until = now.addingTimeInterval(3)
        lastEventAt = now
    }

    package func mayConfirmMissingDisplay(at now: Date) -> Bool {
        !isSettling(at: now) && now.timeIntervalSince(lastEventAt) >= 10
    }

    package func isSettling(at now: Date) -> Bool {
        // A lost end callback must not permanently suppress drift release or
        // keep re-anchoring peeked windows. Ten seconds bounds a display cascade.
        let activeReconfiguration = reconfiguring &&
            (reconfigurationBeganAt.map { now.timeIntervalSince($0) < 10 } ?? false)
        return activeReconfiguration || now < until
    }
}
