import Foundation
import Testing
@testable import OrbPeekCore

@Suite("display settling timeout")
struct SettlingTimeoutTests {
    @Test("missing end callback cannot settle forever")
    func reconfigurationHasUpperBound() {
        var settling = DisplaySettling()
        let began = Date(timeIntervalSince1970: 20_000)
        settling.displayReconfigurationBegan(at: began)
        #expect(settling.isSettling(at: began))
        #expect(settling.isSettling(at: began.addingTimeInterval(9.9)))
        #expect(!settling.isSettling(at: began.addingTimeInterval(10.1)))
    }

    @Test("a later paired end still starts the normal three-second grace")
    func endAfterTimeout() {
        var settling = DisplaySettling()
        let began = Date(timeIntervalSince1970: 20_000)
        settling.displayReconfigurationBegan(at: began)
        let ended = began.addingTimeInterval(11)
        settling.displayReconfigurationEnded(at: ended)
        #expect(settling.isSettling(at: ended.addingTimeInterval(2.9)))
        #expect(!settling.isSettling(at: ended.addingTimeInterval(3.1)))
    }
}
