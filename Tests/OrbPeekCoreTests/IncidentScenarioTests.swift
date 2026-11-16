import CoreGraphics
import Foundation
import Testing
@testable import OrbPeekCore

@MainActor
final class FakeWindowServer {
    let clock: FakeClock
    let delegate: FakeDelegate
    let session: DockSession
    let externalLayout: ScreenLayout
    var windows: [ManagedWindow] { session.windows }

    init() async {
        let external = ScreenLayout(screens: [ScreenInfo(id: 3, frame: testPrimary.frame, visibleFrame: testPrimary.visibleFrame), testSecondary])
        externalLayout = external
        let fakeClock = FakeClock()
        clock = fakeClock
        delegate = FakeDelegate(layout: external)
        delegate.offlinePolicy = .releaseToVisible
        session = DockSession(delegate: delegate, clock: { fakeClock.now })
        let first = FakeWindow(frame: CGRect(x: 633, y: 566, width: 722, height: 496))
        first.bundleIdentifier = "com.zhao.minibrowser"
        let second = FakeWindow(frame: CGRect(x: 1500, y: 326, width: 308, height: 668))
        second.bundleIdentifier = "rednote"
        session.add(window: first, edge: .down)
        session.add(window: second, edge: .down)
        await drainTasks()
    }

    func removeExternalDisplays() {
        // Mi disappears first; U2790B then disappears, reproducing a real 0-screen interval.
        delegate.layoutBox.layout = ScreenLayout(screens: [externalLayout.screens[0]])
        session.screenChanged()
        (windows[0].window as! FakeWindow).storedFrame?.origin.x = 0 // pullToZero (drift=w-1 in field logs)
        delegate.layoutBox.layout = ScreenLayout(screens: [ScreenInfo]() )
        session.screenChanged()
    }

    func openBuiltInDisplay() {
        let builtIn = ScreenInfo(
            id: 1,
            frame: CGRect(x: 0, y: 0, width: 1352, height: 878),
            visibleFrame: CGRect(x: 0, y: 0, width: 1352, height: 843)
        )
        delegate.layoutBox.layout = ScreenLayout(screens: [builtIn])
        session.wake()
    }
}

@Suite("2026-11-16 multi-window display incident")
@MainActor
struct IncidentScenarioTests {
    @Test("both windows and preview strips remain usable after zero displays")
    func fullIncidentSequence() async {
        let server = await FakeWindowServer()
        #expect(server.windows.count == 2)
        #expect(server.delegate.strips.count == 2)

        var logs: [String] = []
        server.session.log = { logs.append($0) }
        server.session.lock()
        server.removeExternalDisplays()
        server.openBuiltInDisplay()
        server.session.unlock()
        for _ in 0..<50 {
            server.clock.advance(0.1)
            server.session.poll()
        }

        #expect(server.delegate.removed.count == 2)
        let first = server.windows[0].window as! FakeWindow
        let second = server.windows[1].window as! FakeWindow
        #expect(first.storedFrame?.origin == CGPoint(x: 315, y: 208.5))
        #expect(second.storedFrame?.origin == CGPoint(x: 522, y: 122.5))
        #expect(first.raiseCount > 0)
        #expect(second.raiseCount > 0)
        #expect(logs.contains { $0.contains("com.zhao.minibrowser") && $0.contains("offline after settling") })
        #expect(logs.contains { $0.contains("rednote") && $0.contains("offline after settling") })
        #expect(logs.contains { $0.contains("id=1 frame=(0.0, 0.0, 1352.0") })
    }

    @Test("same display returning during lock keeps both docks")
    func sameDisplayReturns() async {
        let server = await FakeWindowServer()
        server.session.lock()
        server.removeExternalDisplays()
        server.delegate.layoutBox.layout = server.externalLayout
        server.session.unlock()
        for _ in 0..<50 {
            server.clock.advance(0.1)
            server.session.poll()
        }
        #expect(server.delegate.removed.isEmpty)
        #expect(server.windows.allSatisfy { $0.phase == .docked })
        #expect(server.delegate.strips.allSatisfy { $0.isVisible })
    }
}
