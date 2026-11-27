import Testing
@testable import OrbPeekCore

@Suite("capture session invalidation wiring")
@MainActor
struct CaptureInvalidationTests {
    @Test("display begin/end, screen change, wake and unlock reach the capturer")
    func events() {
        let delegate = FakeDelegate(layout: ScreenLayout(screens: [ScreenInfo]()))
        let session = DockSession(delegate: delegate)
        session.reconfigurationBegan()
        session.reconfigurationEnded()
        session.screenChanged()
        session.wake()
        session.unlock()
        session.setSessionActive(false)
        session.setSessionActive(true)
        session.setScreenSaverActive(true)
        session.setScreenSaverActive(false)
        #expect(delegate.fakeCapturer.contentInvalidations == ["display reconfiguration begin",
            "display reconfiguration end", "screen parameters changed", "wake", "unlock",
            "session active", "screen saver stopped"])
    }
}
