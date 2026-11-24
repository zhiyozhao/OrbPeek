import CoreGraphics
import Testing
@testable import OrbPeekCore

@Suite("display ownership across lock, sleep and unplug")
@MainActor
struct DisplayPolicyTests {
    private func poll(_ server: FakeWindowServer, seconds: Double) {
        for _ in 0..<Int(seconds * 10) {
            server.clock.advance(0.1)
            server.session.poll(mouseQ: CGPoint(x: -10_000, y: -10_000))
        }
    }

    @Test("overnight lock freezes both docks and restores their exact edge and position",
          arguments: [DockEdge.left, .right, .up, .down])
    func lockedDisplayReturns(edge: DockEdge) async {
        let server = await FakeWindowServer()
        for window in server.windows { window.redock(to: edge) }
        await drainTasks()
        let originals = server.windows
        let frames = originals.map { ($0.window as! FakeWindow).storedFrame }
        let strips = server.delegate.strips.map(\.frame)
        let writes = originals.map { ($0.window as! FakeWindow).positionWrites.count }
        server.session.lock()
        server.removeExternalDisplays()
        poll(server, seconds: 30)
        server.clock.advance(8 * 60 * 60)
        server.session.poll()
        #expect(server.delegate.removed.isEmpty)
        #expect(server.session.released.map(\.managed).isEmpty)
        #expect(originals.map { ($0.window as! FakeWindow).positionWrites.count } == writes)
        server.delegate.layoutBox.layout = server.externalLayout
        server.session.screenChanged()
        server.session.unlock()
        poll(server, seconds: 5)
        #expect(server.windows.count == 2)
        #expect(server.delegate.removed.isEmpty)
        #expect(originals.allSatisfy { $0.phase == .docked && $0.edge == edge })
        #expect(originals.allSatisfy { $0.dockScreen(in: server.delegate.geometry)?.id == 3 })
        #expect(originals.map { ($0.window as! FakeWindow).storedFrame } == frames)
        #expect(server.delegate.strips.map(\.frame) == strips)
    }

    @Test("sleep without a lock notification keeps docks when the display wakes within settling")
    func sleepWithoutLock() async {
        let server = await FakeWindowServer()
        let originals = server.windows
        let frames = originals.map { ($0.window as! FakeWindow).storedFrame }
        let strips = server.delegate.strips.map(\.frame)
        server.removeExternalDisplays()
        // No polling while the system is asleep; wake may arrive without unlock.
        server.clock.advance(180)
        server.openBuiltInDisplay()
        poll(server, seconds: 1)
        server.delegate.layoutBox.layout = server.externalLayout
        server.session.screenChanged()
        poll(server, seconds: 5)
        #expect(server.delegate.removed.isEmpty)
        #expect(server.session.released.map(\.managed).isEmpty)
        #expect(originals.allSatisfy { $0.phase == .docked && $0.edge == .down })
        #expect(originals.allSatisfy { $0.dockScreen(in: server.delegate.geometry)?.id == 3 })
        #expect(originals.map { ($0.window as! FakeWindow).storedFrame } == frames)
        #expect(server.delegate.strips.map(\.frame) == strips)
    }

    @Test("a display later than ten seconds never restores cancelled docks",
          arguments: [DockEdge.left, .right, .up, .down], [false, true])
    func slowDisplayReturns(edge: DockEdge, locked: Bool) async {
        let server = await FakeWindowServer()
        for window in server.windows { window.redock(to: edge) }
        await drainTasks()
        let originals = server.windows
        let offsets = originals.map(\.perp)
        if locked { server.session.lock() }
        server.removeExternalDisplays()
        server.clock.advance(180)
        server.openBuiltInDisplay()
        if locked { server.session.unlock() }
        poll(server, seconds: 20)
        // V2 intentionally removes the old two-minute display-return intent.
        #expect(server.windows.isEmpty)
        #expect(server.session.released.map(\.managed).count == 2)
        let releasedFrames = originals.map { $0.window.frame }
        server.delegate.layoutBox.layout = server.externalLayout
        server.session.screenChanged()
        server.session.poll()
        await drainTasks()
        poll(server, seconds: 5)
        #expect(server.windows.isEmpty)
        #expect(server.session.released.count == 2)
        #expect(originals.map(\.perp) == offsets)
        #expect(originals.map { $0.window.frame } == releasedFrames)
        #expect(server.delegate.strips.allSatisfy { !$0.isVisible })
    }

    @Test("unplugging the owning display releases and centers both windows after settling")
    func owningDisplayUnplugged() async {
        let server = await FakeWindowServer()
        let originals = server.windows
        server.removeExternalDisplays()
        server.openBuiltInDisplay()
        poll(server, seconds: 2)
        #expect(server.delegate.removed.isEmpty)
        poll(server, seconds: 10)
        #expect(server.windows.isEmpty)
        #expect(server.delegate.removed.count == 2)
        let visible = server.delegate.geometry.quartzVisibleFrame(of: server.delegate.layoutBox.layout.primary!)
        for managed in originals {
            let window = managed.window as! FakeWindow
            let frame = window.storedFrame!
            #expect(visible.contains(frame))
            #expect(frame.midX == visible.midX)
            #expect(frame.midY == visible.midY)
            #expect(window.raiseCount == 0)
        }
        #expect(server.delegate.strips.allSatisfy { !$0.isVisible })
    }

    @Test("removing another display keeps the owning display's strips and dock offsets untouched")
    func unrelatedDisplayUnplugged() async {
        let server = await FakeWindowServer()
        let originals = server.windows
        let offsets = originals.map(\.perp)
        let strips = server.delegate.strips.map(\.frame)
        server.delegate.layoutBox.layout = ScreenLayout(screens: [server.externalLayout.screens[0]])
        server.session.screenChanged()
        poll(server, seconds: 5)
        #expect(server.delegate.removed.isEmpty)
        #expect(server.session.released.map(\.managed).isEmpty)
        #expect(originals.allSatisfy { $0.phase == .docked && $0.edge == .down })
        #expect(originals.allSatisfy { $0.dockScreen(in: server.delegate.geometry)?.id == 3 })
        #expect(originals.map(\.perp) == offsets)
        // With only one display left, hidden parking switches outer edges.
        // The user-visible strip and the next peek must keep their position.
        for managed in originals {
            let expected = server.delegate.geometry.hiddenPosition(
                for: .down, size: managed.window.frame!.size, perp: managed.perp,
                screen: server.externalLayout.screens[0])
            #expect(managed.window.frame?.origin == expected)
        }
        #expect(server.delegate.strips.map(\.frame) == strips)
    }

    @Test("closing the lid releases built-in docks while external docks keep their screen and offset")
    func lidClosesWithExternalDisplay() async {
        let clock = FakeClock()
        let builtIn = ScreenInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1352, height: 878),
                                 visibleFrame: CGRect(x: 0, y: 0, width: 1352, height: 843))
        let external = ScreenInfo(id: 3, frame: CGRect(x: 1352, y: 0, width: 1920, height: 1080),
                                  visibleFrame: CGRect(x: 1352, y: 0, width: 1920, height: 1055))
        let delegate = FakeDelegate(layout: ScreenLayout(screens: [builtIn, external]))
        let session = DockSession(delegate: delegate, clock: { clock.now })
        delegate.onOfflineRelease = session.deferPending
        let inside = FakeWindow(frame: CGRect(x: 200, y: 300, width: 400, height: 300))
        let outside = FakeWindow(frame: CGRect(x: 1700, y: 300, width: 500, height: 400))
        let builtInDock = session.add(window: inside, edge: .down) { $0.isLeftMousePressed = { false } }
        let externalDock = session.add(window: outside, edge: .down) { $0.isLeftMousePressed = { false } }
        await drainTasks()
        #expect(builtInDock.dockScreen(in: delegate.geometry)?.id == 1)
        #expect(externalDock.dockScreen(in: delegate.geometry)?.id == 3)
        let externalOffset = externalDock.perp
        let returned = ScreenInfo(id: 3, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                  visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055))
        delegate.layoutBox.layout = ScreenLayout(screens: [returned])
        session.screenChanged()
        for _ in 0..<150 {
            clock.advance(0.1)
            session.poll(mouseQ: CGPoint(x: -10_000, y: -10_000))
        }
        #expect(delegate.removed.count == 1)
        #expect(delegate.removed.first === builtInDock)
        #expect(session.windows.count == 1)
        #expect(session.windows.first === externalDock)
        let visible = delegate.geometry.quartzVisibleFrame(of: returned)
        #expect(inside.storedFrame?.midX == visible.midX)
        #expect(inside.storedFrame?.midY == visible.midY)
        #expect(inside.raiseCount == 0)
        #expect(!delegate.strips[0].isVisible)
        #expect(externalDock.phase == .docked && externalDock.edge == .down)
        #expect(externalDock.dockScreen(in: delegate.geometry)?.id == 3)
        #expect(externalDock.perp == externalOffset)
        let expectedStrip = delegate.geometry.toAppKit(delegate.geometry.sliverRect(
            edge: .down, size: outside.storedFrame!.size, perp: externalOffset,
            screen: returned, thickness: delegate.config.sliverPx))
        #expect(delegate.strips[1].frame == expectedStrip)
    }
}
