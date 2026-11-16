import CoreGraphics
import Foundation
import Testing
@testable import OrbPeekCore

@MainActor
final class FakeWindowServer {
    let clock: FakeClock
    let delegate: FakeDelegate
    let session: DockSession
    var windows: [ManagedWindow] { session.windows }

    init() async {
        let external = ScreenLayout(screens: [testPrimary, testSecondary])
        let fakeClock = FakeClock()
        clock = fakeClock
        delegate = FakeDelegate(layout: external)
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
        delegate.layoutBox.layout = ScreenLayout(screens: [testPrimary])
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

        server.session.lock()
        server.removeExternalDisplays()
        server.openBuiltInDisplay()
        server.session.unlock()
        for _ in 0..<50 {
            server.clock.advance(0.1)
            server.session.poll()
        }

        let geometry = server.delegate.geometry
        let builtIn = geometry.layout.primary!
        for (index, managed) in server.windows.enumerated() {
            #expect(managed.phase == .docked)
            let screen = managed.dockScreen(in: geometry)
            #expect(screen?.id == 1)
            let fakeWindow = managed.window as! FakeWindow
            let expected = geometry.hiddenPosition(for: .down, size: fakeWindow.storedFrame!.size,
                                                    perp: managed.perp, screen: builtIn)
            #expect(fakeWindow.storedFrame?.origin == expected)

            let stripRect = geometry.sliverRect(edge: .down, size: fakeWindow.storedFrame!.size,
                                                 perp: managed.perp, screen: builtIn, thickness: 15)
            #expect(geometry.quartzVisibleFrame(of: builtIn).contains(stripRect))
            let strip = server.delegate.strips[index]
            #expect(strip.isVisible)
            #expect(strip.frame == geometry.toAppKit(stripRect))
        }
    }
}
