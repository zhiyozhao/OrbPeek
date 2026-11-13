import Foundation
import Testing
@testable import OrbPeekCore

@Suite("R1-2 drift before display notification")
@MainActor
struct DriftGraceTests {
    @Test("display reconfiguration begins settling before frames move")
    func reconfigurationBeginsSettling() {
        var settling = DisplaySettling()
        let now = Date(timeIntervalSince1970: 2_000)
        settling.displayReconfigurationBegan(at: now)
        #expect(settling.isSettling(at: now))
        settling.displayReconfigurationEnded(at: now.addingTimeInterval(4))
        #expect(settling.isSettling(at: now.addingTimeInterval(6.9)))
        #expect(!settling.isSettling(at: now.addingTimeInterval(7.1)))
    }

    @Test("slow AX reads do not consume the docked drift grace")
    func dockedSlowAXRead() async {
        let fixture = await makeDockedFixture(layout: testLayout)
        fixture.window.storedFrame?.origin.x += 1919
        fixture.window.readDelay = 0.45
        var settling = DisplaySettling()

        tick(fixture) // drift is actually observed at t + 450ms
        #expect(fixture.delegate.removed.isEmpty)
        fixture.window.readDelay = 0
        fixture.clock.advance(0.05) // only 50ms of real grace has elapsed
        tick(fixture) // old poll-start timestamp reaches 0.5s and releases
        #expect(fixture.delegate.removed.isEmpty)

        fixture.clock.advance(0.28) // notification arrives 330ms after observation
        settling.screenParametersChanged(at: fixture.clock.now)
        tick(fixture, settling: settling.isSettling(at: fixture.clock.now))
        #expect(fixture.delegate.removed.isEmpty)
    }

    @Test("peeked external drift has grace and preserves perp during it")
    func peekedSlowAXRead() async {
        let fixture = await makeDockedFixture(layout: testLayout)
        fixture.managed.peek()
        let originalPerp = fixture.managed.perp
        fixture.clock.advance(1)
        fixture.window.storedFrame = CGRect(x: 500, y: 480, width: 700, height: 500)
        fixture.window.readDelay = 0.45
        var settling = DisplaySettling()

        tick(fixture)
        #expect(fixture.delegate.removed.isEmpty)
        #expect(fixture.managed.perp == originalPerp)

        settling.screenParametersChanged(at: fixture.clock.now)
        tick(fixture, settling: settling.isSettling(at: fixture.clock.now))
        #expect(fixture.delegate.removed.isEmpty)
        #expect(fixture.window.storedFrame?.origin.x == 300)
    }
}
