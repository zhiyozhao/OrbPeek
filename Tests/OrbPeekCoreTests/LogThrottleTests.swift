import Foundation
import Testing
@testable import OrbPeekCore

@Suite("oversized-window log throttling")
@MainActor
struct LogThrottleTests {
    @Test("oversized windows do not log or re-show at 30Hz")
    func oversizedWindowStaysQuiet() async {
        let fixture = await makeDockedFixture(
            layout: testLayout,
            frame: CGRect(x: 100, y: 100, width: 700, height: 2000),
            edge: .right
        )
        var logs: [String] = []
        fixture.managed.log = { logs.append($0) }
        fixture.delegate.strip.showCount = 0
        for _ in 0..<30 {
            fixture.clock.advance(1.0 / 30.0)
            tick(fixture)
        }
        #expect(logs.count <= 4)
        #expect(fixture.delegate.strip.showCount <= 2)
    }
}
