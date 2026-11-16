import Foundation
import Testing
@testable import OrbPeekCore

@Suite("unlock peek activation recovery")
@MainActor
struct ActivationTests {
    @Test("failed activation does not immediately hide a newly peeked window")
    func retriesInsteadOfDroppingAt07Seconds() async {
        let fixture = await makeDockedFixture(layout: testLayout)
        fixture.delegate.frontmost = false
        fixture.managed.peek()
        #expect(fixture.delegate.activationCount == 1)

        fixture.clock.advance(0.7)
        tick(fixture, frontmost: false)
        #expect(fixture.managed.phase == .peeked)
        #expect(fixture.delegate.activationCount >= 2)
        #expect(fixture.delegate.removed.isEmpty)

        fixture.clock.advance(1.5)
        tick(fixture, frontmost: false)
        #expect(fixture.managed.phase != .peeked)
    }
}
