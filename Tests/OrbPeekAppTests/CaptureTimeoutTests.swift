import Foundation
import Testing
@testable import OrbPeek

// Deliberately ignores Task cancellation, like a stuck ScreenCaptureKit call.
final class SuspendedCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Int?, Never>] = []
    private var released = false
    var wasReleased: Bool { lock.withLock { released } }
    func wait() async -> Int? {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if released { return true }
                self.continuations.append(continuation)
                return false
            }
            if resumeNow { continuation.resume(returning: 7) }
        }
    }
    func release() {
        let waiting = lock.withLock {
            released = true
            let waiting = continuations
            continuations = []
            return waiting
        }
        for continuation in waiting { continuation.resume(returning: 7) }
    }
}

@Suite("bounded screenshot deadlines")
struct CaptureTimeoutTests {
    @Test("parent cancellation returns without joining the uncooperative worker")
    func cancellation() async {
        let blocked = SuspendedCapture()
        let task = Task { await withTimeoutOutcome(60) { await blocked.wait() } }
        task.cancel()
        let result = await task.value
        if case .cancelled = result {} else { Issue.record("expected cancellation") }
        #expect(!blocked.wasReleased)
        blocked.release()
    }

    @Test("timeout returns while the underlying call still ignores cancellation")
    @MainActor
    func uncooperativeCapture() async {
        let blocked = SuspendedCapture()
        // Independent watchdog makes the old task-group bug fail instead of
        // hanging the test process. Leave generous scheduler headroom for
        // concurrent MainActor image tests: the semantic assertion below is
        // that the caller returns BEFORE this worker is released.
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { blocked.release() }
        var mainActorRan = false
        let interaction = Task { @MainActor in mainActorRan = true }
        let outcome = await withTimeoutOutcome(0.02) { await blocked.wait() }
        await interaction.value
        #expect(mainActorRan)
        #expect(!blocked.wasReleased, "deadline must not wait for the watchdog to release SCK")
        if case .timedOut = outcome {} else { Issue.record("expected a timeout") }
        blocked.release() // clean up the fake background work after asserting.
    }
}
