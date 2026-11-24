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
        delegate.onOfflineRelease = session.deferPending
        let first = FakeWindow(frame: CGRect(x: 633, y: 566, width: 722, height: 496))
        first.bundleIdentifier = "com.zhao.minibrowser"
        let second = FakeWindow(frame: CGRect(x: 1500, y: 326, width: 308, height: 668))
        second.bundleIdentifier = "rednote"
        let firstManaged = session.add(window: first, edge: .down)
        firstManaged.isLeftMousePressed = { first.mouseDown }
        let secondManaged = session.add(window: second, edge: .down)
        secondManaged.isLeftMousePressed = { second.mouseDown }
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
        for _ in 0..<150 {
            server.clock.advance(0.1)
            server.session.poll()
        }

        #expect(server.delegate.removed.count == 2)
        let first = server.session.released.map(\.managed)[0].window as! FakeWindow
        let second = server.session.released.map(\.managed)[1].window as! FakeWindow
        #expect(first.storedFrame?.origin == CGPoint(x: 315, y: 208.5))
        #expect(second.storedFrame?.origin == CGPoint(x: 522, y: 122.5))
        #expect(first.raiseCount == 0)
        #expect(second.raiseCount == 0)
        #expect(server.session.unreachableWindows().isEmpty)
    }

    @Test("late original display never re-docks released windows", arguments: [14.0, 18.0, 67.0])
    func lateDisplayReturns(delay: TimeInterval) async {
        let server = await FakeWindowServer()
        server.session.lock()
        server.removeExternalDisplays()
        server.openBuiltInDisplay()
        server.session.unlock()
        for _ in 0..<Int(delay * 10) {
            server.clock.advance(0.1)
            server.session.poll()
        }
        #expect(server.delegate.removed.count == 2)
        #expect(server.session.released.map(\.managed).count == 2)

        let builtIn = server.delegate.layoutBox.layout.primary!
        let returnedBuiltIn = ScreenInfo(id: builtIn.id,
                                         frame: builtIn.frame.offsetBy(dx: 0, dy: 202),
                                         visibleFrame: builtIn.visibleFrame.offsetBy(dx: 0, dy: 202))
        server.delegate.layoutBox.layout = ScreenLayout(screens: [
            server.externalLayout.screens[0], returnedBuiltIn, server.externalLayout.screens[1],
        ])
        server.session.screenChanged()
        for _ in 0..<50 {
            server.clock.advance(0.1)
            server.session.poll()
        }
        await drainTasks()
        #expect(server.windows.isEmpty)
        #expect(server.session.released.count == 2)
        #expect(server.session.unreachableWindows().isEmpty)
    }

    @Test("primary-screen change after release never reclaims a normal window")
    func lateDisplayWithShiftedBuiltIn() async {
        let server = await FakeWindowServer()
        server.session.lock()
        server.removeExternalDisplays()
        server.openBuiltInDisplay()
        server.session.unlock()
        for _ in 0..<140 {
            server.clock.advance(0.1)
            server.session.poll()
        }
        #expect(server.session.released.map(\.managed).count == 2)
        let builtIn = server.delegate.layoutBox.layout.primary!
        for pending in server.session.released.map(\.managed) {
            (pending.window as! FakeWindow).storedFrame?.origin.x -= 1352
            (pending.window as! FakeWindow).storedFrame?.origin.y += 2
        }
        let shiftedBuiltIn = ScreenInfo(id: builtIn.id,
                                        frame: builtIn.frame.offsetBy(dx: -1352, dy: 200),
                                        visibleFrame: builtIn.visibleFrame.offsetBy(dx: -1352, dy: 200))
        server.delegate.layoutBox.layout = ScreenLayout(screens: [
            server.externalLayout.screens[0], shiftedBuiltIn, server.externalLayout.screens[1],
        ])
        server.session.screenChanged()
        server.session.poll()
        await drainTasks()
        #expect(server.windows.isEmpty)
        #expect(server.session.released.count == 2)
    }

    @Test("user edits after offline release cancel late redock")
    func userEditCancelsLateRedock() async {
        let server = await FakeWindowServer()
        server.session.lock()
        server.removeExternalDisplays()
        server.openBuiltInDisplay()
        server.session.unlock()
        for _ in 0..<140 {
            server.clock.advance(0.1)
            server.session.poll()
        }
        let edited = server.session.released.map(\.managed)[1].window as! FakeWindow
        edited.storedFrame = CGRect(x: 50, y: 60, width: 900, height: 600)
        server.delegate.layoutBox.layout = server.externalLayout
        server.session.screenChanged()
        server.session.poll()

        #expect(edited.storedFrame == CGRect(x: 50, y: 60, width: 900, height: 600))
        #expect(server.session.released.count == 2)
        #expect(server.delegate.removed.count == 2)
    }

    @Test("mouse down during display return never re-docks a released window")
    func mouseDownDefersLateRedock() async {
        let server = await FakeWindowServer()
        server.session.lock()
        server.removeExternalDisplays()
        server.openBuiltInDisplay()
        server.session.unlock()
        for _ in 0..<140 {
            server.clock.advance(0.1)
            server.session.poll()
        }
        let pending = server.session.released.map(\.managed)[0]
        (pending.window as! FakeWindow).mouseDown = true
        server.delegate.layoutBox.layout = server.externalLayout
        server.session.screenChanged()
        server.session.poll()
        #expect(server.session.released.count == 2)
        #expect(server.windows.filter { $0.window.isSameWindow(as: pending.window) }.isEmpty)
    }

    @Test("manual dock removes the same window from the release list")
    func manualDockCancelsPending() async {
        let server = await FakeWindowServer()
        server.session.lock()
        server.removeExternalDisplays()
        server.openBuiltInDisplay()
        server.session.unlock()
        for _ in 0..<140 {
            server.clock.advance(0.1)
            server.session.poll()
        }
        let window = server.session.released.map(\.managed)[0].window
        server.session.add(window: window, edge: .left)
        server.delegate.layoutBox.layout = server.externalLayout
        server.session.screenChanged()
        server.session.poll()
        await drainTasks()

        #expect(server.windows.count == 1)
        #expect(server.windows.filter { $0.window.isSameWindow(as: window) }.count == 1)
        #expect(server.windows.first { $0.window.isSameWindow(as: window) }?.edge == .left)
        #expect(server.session.released.count == 1)
    }

    @Test("adopting a released window is idempotent")
    func adoptIsIdempotent() async {
        let server = await FakeWindowServer()
        server.session.lock()
        server.removeExternalDisplays()
        server.openBuiltInDisplay()
        server.session.unlock()
        for _ in 0..<140 {
            server.clock.advance(0.1)
            server.session.poll()
        }
        let pending = server.session.released.map(\.managed)[0]
        server.session.adopt(pending)
        server.session.adopt(pending)
        #expect(server.windows.filter { $0 === pending }.count == 1)
        #expect(server.session.released.map(\.managed).filter { $0 === pending }.isEmpty)
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
