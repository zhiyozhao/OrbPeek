import Testing
@testable import OrbPeekCore

@Suite("capture session invalidation wiring")
@MainActor
struct CaptureInvalidationTests {
    @Test("each session pause cancels queued previews and permits a fresh visible capture on resume", arguments: ["lock", "sleep", "inactive", "screensaver", "layout"])
    func previewPause(gate: String) async {
        let h = await DisplayRulesV2Tests.Harness()
        let count = h.delegate.fakeCapturer.captureCount
        h.managed.peek() // Queued but not yet entered the fake capture.
        switch gate {
        case "lock": h.session.lock()
        case "sleep": h.session.sleep()
        case "inactive": h.session.setSessionActive(false)
        case "screensaver": h.session.setScreenSaverActive(true)
        default: h.session.reconfigurationBegan()
        }
        await drainTasks()
        #expect(h.delegate.fakeCapturer.captureCount == count)
        h.poll(4)
        await drainTasks()
        #expect(h.delegate.fakeCapturer.captureCount == count)
        switch gate {
        case "lock": h.session.unlock()
        case "sleep": h.session.wake()
        case "inactive": h.session.setSessionActive(true)
        case "screensaver": h.session.setScreenSaverActive(false)
        default: h.session.reconfigurationEnded(); h.clock.advance(3.1)
        }
        h.session.poll(mouseQ: h.window.frame!.origin)
        await drainTasks()
        #expect(h.delegate.fakeCapturer.captureCount == count + 1)
        #expect(h.session.unreachableWindows().isEmpty)
    }

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
