import Foundation

// replayd is shared by screen-sharing and recording apps. Restarting it is a
// last resort: three consecutive capture timeouts, then a five-minute cooldown.
package struct ReplaydRestartPolicy {
    package private(set) var consecutiveTimeouts = 0
    private var lastRestart: Date?
    package init() {}

    package mutating func recordTimeout(at now: Date) -> Bool {
        consecutiveTimeouts += 1
        guard consecutiveTimeouts >= 3 else { return false }
        consecutiveTimeouts = 0
        if let lastRestart, now.timeIntervalSince(lastRestart) < 300 { return false }
        lastRestart = now
        return true
    }

    package mutating func recordOtherResult() {
        consecutiveTimeouts = 0
    }
}
