import Foundation
import Testing
@testable import OrbPeekCore

@Suite("R1-1 display changes across lock and wake")
@MainActor
struct DisplaySettlingTests {
    @Test("unlock starts a fresh settling window after locked display changes")
    func unlockSettlesAndReanchors() async {
        let fixture = await makeDockedFixture(layout: testLayout)
        var settling = DisplaySettling()
        settling.screenParametersChanged(at: fixture.clock.now)

        // Polling is frozen for six hours while macOS moves the parked window.
        fixture.clock.advance(6 * 60 * 60)
        fixture.window.storedFrame?.origin.x += 700
        settling.screenUnlocked(at: fixture.clock.now)

        #expect(settling.isSettling(at: fixture.clock.now))
        tick(fixture, settling: settling.isSettling(at: fixture.clock.now))
        #expect(fixture.delegate.removed.isEmpty)
        let screen = fixture.managed.dockScreen(in: fixture.delegate.geometry)!
        let expected = fixture.delegate.geometry.hiddenPosition(
            for: fixture.managed.edge, size: fixture.window.storedFrame!.size,
            perp: fixture.managed.perp, screen: screen
        )
        #expect(fixture.window.storedFrame?.origin == expected)
    }

    @Test("wake starts settling even when the unlock notification was lost")
    func wakeSettles() {
        var settling = DisplaySettling()
        let now = Date(timeIntervalSince1970: 10_000)
        settling.didWake(at: now)
        #expect(settling.isSettling(at: now))
        #expect(settling.isSettling(at: now.addingTimeInterval(2.9)))
        #expect(!settling.isSettling(at: now.addingTimeInterval(3.1)))
    }
}
