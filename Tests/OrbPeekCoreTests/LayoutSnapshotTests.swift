import Foundation
import Testing
@testable import OrbPeekCore

@Suite("display layout snapshots")
@MainActor
struct LayoutSnapshotTests {
    @Test("count layout builds in one second of two-window 30Hz polling", arguments: [false, true])
    func pollLayoutBuilds(cached: Bool) async {
        let clock = FakeClock()
        let delegate = FakeDelegate(layout: testLayout)
        if cached {
            let source = delegate.layoutBox
            delegate.layoutCache = DisplayLayoutCache(load: { source.read() })
        }
        let session = DockSession(delegate: delegate, clock: { clock.now })
        for x in [300, 2200] {
            let window = FakeWindow(frame: CGRect(x: x, y: 200, width: 600, height: 500))
            _ = session.add(window: window, edge: .down) { $0.isLeftMousePressed = { false } }
        }
        await drainTasks()
        delegate.layoutBox.readCount = 0
        for _ in 0..<30 {
            clock.advance(1.0 / 30)
            session.poll(mouseQ: CGPoint(x: -10000, y: -10000))
        }
        print("LAYOUT_BENCHMARK cached=\(cached) builds_per_second=\(delegate.layoutBox.readCount) screens=2 polls=30 windows=2")
        #expect(session.windows.count == 2)
        if cached { #expect(delegate.layoutBox.readCount == 0) }
        else { #expect(delegate.layoutBox.readCount > 0) }
    }

    @Test("every display and resume event invalidates the cached snapshot", arguments: [
        "screenChanged", "begin", "end", "wake", "unlock", "inactive", "active", "screensaverStart", "screensaverStop",
    ])
    func eventInvalidation(event: String) {
        let clock = FakeClock()
        let delegate = FakeDelegate(layout: testLayout)
        let source = delegate.layoutBox
        delegate.layoutCache = DisplayLayoutCache(load: { source.read() })
        let session = DockSession(delegate: delegate, clock: { clock.now })
        let old = delegate.geometry // Existing geometry providers must see new generations too.
        #expect(source.readCount == 1)
        let changed = ScreenLayout(screens: [DisplayRulesV2Tests.Harness.internalScreen])
        source.layout = changed
        #expect(old.layout == testLayout)
        source.readCount = 0
        switch event {
        case "screenChanged": session.screenChanged()
        case "begin": session.reconfigurationBegan()
        case "end": session.reconfigurationEnded()
        case "wake": session.wake()
        case "unlock": session.unlock()
        case "inactive": session.setSessionActive(false)
        case "active": session.setSessionActive(true)
        case "screensaverStart": session.setScreenSaverActive(true)
        default: session.setScreenSaverActive(false)
        }
        #expect(old.layout == changed)
        #expect(delegate.geometry.layout == changed)
        #expect(source.readCount == 1)
        #expect(!session.canWriteAutomatically)
        // A fresh snapshot must not overwrite the last stable dock baseline.
        #expect(session.stableLayout == testLayout)
    }

    @Test("invalid desktop replaces the cache rather than reusing an old valid screen")
    func invalidSnapshot() async {
        let h = await DisplayRulesV2Tests.Harness()
        let writes = h.window.positionWrites.count
        h.change([])
        h.poll(20)
        #expect(!h.delegate.geometry.layout.isValid)
        #expect(!h.session.canWriteAutomatically)
        #expect(h.window.positionWrites.count == writes)
        h.change([DisplayRulesV2Tests.Harness.a, DisplayRulesV2Tests.Harness.b])
        h.poll(3.1)
        #expect(h.session.canWriteAutomatically)
        #expect(h.session.windows.count == 1)
    }
}
