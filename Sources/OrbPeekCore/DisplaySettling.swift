import Foundation

// Time-based suppression of external-drift release while macOS settles window
// frames after display and session transitions.
package struct DisplaySettling {
    private var until = Date.distantPast
    private var reconfiguring = false

    package init() {}

    package mutating func screenParametersChanged(at now: Date) {
        until = now.addingTimeInterval(3)
    }

    package mutating func displayReconfigurationBegan(at now: Date) {
        // This callback precedes the frame shuffle, unlike the AppKit
        // notification, which can arrive hundreds of milliseconds later.
        reconfiguring = true
    }

    package mutating func displayReconfigurationEnded(at now: Date) {
        reconfiguring = false
        screenParametersChanged(at: now)
    }

    package mutating func screenUnlocked(at now: Date) {
        // A display change may have happened while polling was frozen. Start
        // settling now; the old notification's three seconds may be long past.
        until = now.addingTimeInterval(3)
    }

    package mutating func didWake(at now: Date) {
        // Deep sleep can swallow the unlock notification.
        until = now.addingTimeInterval(3)
    }

    package func isSettling(at now: Date) -> Bool { reconfiguring || now < until }
}
