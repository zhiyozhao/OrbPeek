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
            delegate.layoutCache = DisplayLayoutCache(load: { source.read() }, clock: { clock.now })
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
        delegate.layoutCache = DisplayLayoutCache(load: { source.read() }, clock: { clock.now })
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

    @Test("missing every event still refreshes visible margins and topology within the guard period", arguments: [false, true])
    func missedEvents(topology: Bool) async {
        let h = await DisplayRulesV2Tests.Harness()
        let previous = h.delegate.geometry.layout
        let owner = DisplayRulesV2Tests.Harness.a
        let changed = topology
            ? ScreenLayout(screens: [DisplayRulesV2Tests.Harness.internalScreen])
            : ScreenLayout(screens: [
                ScreenInfo(id: owner.id, frame: owner.frame,
                           visibleFrame: CGRect(x: 0, y: 55, width: 1920, height: 1000), displayUUID: owner.displayUUID),
                DisplayRulesV2Tests.Harness.b,
            ])
        let writes = h.window.positionWrites.count
        // No screen/session/reconfiguration notification at all.
        h.delegate.layoutBox.layout = changed
        h.poll(1.9)
        #expect(h.delegate.geometry.layout == previous)
        h.poll(0.2)
        #expect(h.delegate.geometry.layout == changed)
        #expect(!h.session.canWriteAutomatically)
        #expect(h.session.stableLayout == previous)
        #expect(h.window.positionWrites.count == writes)
        h.poll(topology ? 10.1 : 3.1)
        if topology {
            #expect(h.session.windows.isEmpty)
            #expect(h.delegate.geometry.visibleFraction(of: h.window.frame!) == 1)
        } else {
            #expect(h.session.windows.count == 1)
            #expect(h.managed.hasReachableStrip(in: h.delegate.geometry))
            #expect(h.window.positionWrites.count > writes)
        }
    }

    @Test("manual rescue force-refreshes before the periodic guard and uses the new desktop", arguments: [false, true], [false, true])
    func rescueFreshLayout(listed: Bool, queued: Bool) async {
        let h = await DisplayRulesV2Tests.Harness()
        if listed { h.release() }
        let old = h.delegate.geometry.layout
        if queued {
            h.window.mouseDown = true
            h.session.rescueAllWindows()
            h.window.mouseDown = false
        }
        // A desktop disjoint from the cached one makes old-layout placement
        // visibly wrong. Also too early for a periodic refresh to help.
        let latest = ScreenLayout(screens: [ScreenInfo(id: 88,
            frame: CGRect(x: 5000, y: 0, width: 1000, height: 800),
            visibleFrame: CGRect(x: 5000, y: 0, width: 1000, height: 775), displayUUID: "new-desktop")])
        h.delegate.layoutBox.layout = latest
        h.window.storedFrame = CGRect(x: -9000, y: 200, width: 308, height: 668)
        let writes = h.window.positionWrites.count
        if queued { h.poll(0.1) }
        else { h.session.rescueAllWindows() }
        #expect(old != latest)
        #expect(h.delegate.geometry.layout == latest)
        // Keep the request pending while the newly observed layout settles.
        #expect(h.window.positionWrites.count == writes)
        h.poll(3.1)
        #expect(h.session.windows.isEmpty)
        #expect(WindowGeometry(layout: latest).visibleFraction(of: h.window.frame!) == 1)
        #expect(h.delegate.activationCount == 0)
    }

    @Test("the guard samples at half a layout build per second under sustained 30Hz polling")
    func guardBuildRate() async {
        let h = await DisplayRulesV2Tests.Harness()
        let other = FakeWindow(frame: CGRect(x: 2200, y: 200, width: 600, height: 500))
        _ = h.session.add(window: other, edge: .down) { $0.isLeftMousePressed = { false } }
        await drainTasks()
        let start = h.clock.now
        h.delegate.layoutBox.readCount = 0
        for tick in 1...600 {
            h.clock.now = start.addingTimeInterval(Double(tick) / 30)
            h.session.poll(mouseQ: CGPoint(x: -10000, y: -10000))
        }
        let builds = h.delegate.layoutBox.readCount
        print("LAYOUT_GUARD builds=\(builds) seconds=20 builds_per_second=\(Double(builds) / 20) screens=2 polls=600 windows=2")
        #expect(builds == 10)
        #expect(h.session.windows.count == 2)
    }
}
