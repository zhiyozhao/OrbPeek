import Foundation
import Testing
@testable import OrbPeekCore

@Suite("replayd restart safeguards")
struct ReplaydRestartPolicyTests {
    private func timeout(_ policy: inout ReplaydRestartPolicy, at now: Date) -> Bool {
        policy.recordTimeout(at: now)
    }

    @Test("only the third consecutive timeout restarts replayd")
    func consecutiveThreshold() {
        var policy = ReplaydRestartPolicy()
        let now = Date(timeIntervalSince1970: 1000)
        #expect(!timeout(&policy, at: now))
        #expect(!timeout(&policy, at: now))
        #expect(timeout(&policy, at: now))
    }

    @Test("non-timeout results break the consecutive sequence")
    func otherResultResets() {
        var policy = ReplaydRestartPolicy()
        let now = Date(timeIntervalSince1970: 1000)
        #expect(!timeout(&policy, at: now))
        #expect(!timeout(&policy, at: now))
        policy.recordOtherResult()
        #expect(!timeout(&policy, at: now))
        #expect(!timeout(&policy, at: now))
        #expect(timeout(&policy, at: now))
    }

    @Test("a new timeout series inside cooldown cannot restart again")
    func cooldown() {
        var policy = ReplaydRestartPolicy()
        let now = Date(timeIntervalSince1970: 1000)
        for _ in 0..<3 { _ = timeout(&policy, at: now) }
        for _ in 0..<3 { #expect(!timeout(&policy, at: now.addingTimeInterval(60))) }
        for _ in 0..<2 { #expect(!timeout(&policy, at: now.addingTimeInterval(301))) }
        #expect(timeout(&policy, at: now.addingTimeInterval(301)))
    }
}
