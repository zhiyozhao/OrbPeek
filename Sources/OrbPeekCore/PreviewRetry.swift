import Foundation

// Only while a previewed window is visible. Hidden windows never cause a
// screenshot timer or an attempt to bring them back onto the desktop.
package struct PreviewRetry {
    private var attempts = 0
    private var next: Date?
    package mutating func begin(at now: Date) { attempts = 0; next = now }
    package func due(at now: Date) -> Bool { next.map { now >= $0 } ?? false }
    package mutating func finished(success: Bool, at now: Date) {
        attempts += 1
        let delays: [TimeInterval] = [1, 4, 15]
        next = !success && attempts <= delays.count ? now.addingTimeInterval(delays[attempts - 1]) : nil
    }
}
